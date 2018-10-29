module PkgCacher

import Pkg.TOML
using Pkg
using Pkg.Types: UUID, PackageSpec, VersionSpec, SHA1

import LibGit2
import BinaryProvider

const WORKDIR = Ref(@__DIR__)
function setdir(path)
    WORKDIR[] = path
end

registries(path = depot_path()) = map(readdir(joinpath(path, "registries"))) do r
    abspath(path, "registries", r)
end
depot_path(path = WORKDIR[]) = joinpath(path, "depot")


function read_all_pkgs(filter = Set{UUID}())
    pkgs = Tuple{PackageSpec, SHA1}[]
    for path in registries() 
        tomlpath = joinpath(path, "Registry.toml")
        isfile(tomlpath) || error("$path does not exist")
        registry = TOML.parsefile(tomlpath)
        haskey(registry, "packages") || error("Registry at $path has no packages")

        packages = registry["packages"]

        for (uuid, pkg) in packages
            name = pkg["name"]
            uuid = UUID(uuid)
            if uuid ∉ filter
                continue
            end
            name == "julia" && continue
            versions_file = abspath(path, pkg["path"], "Versions.toml")
            if !isfile(versions_file) 
                @warn "$name has no Versions.toml file, skipping"
                continue
            end

            versions = TOML.parsefile(versions_file)

            for (version, hash) in versions
                push!(pkgs, (PackageSpec(name, uuid, VersionSpec(version)), SHA1(hash)))
            end
        end
    end
    pkgs
end

function read_project(path)
    pkgs = Tuple{PackageSpec, SHA1}[]
    isfile(path) || error("$path does not exist")
    project = TOML.parsefile(path)
    haskey(project, "deps") || error("Project at $path has no deps")

    uuids = Set{UUID}()
    for (name, uuid) in project["deps"]
        push!(uuids, UUID(uuid))
    end
    uuids
end


function cache(pkg)
    try
        # If a pkg got deleted this will hang.
        Pkg.add(pkg)
        # TODO: Does adding automatically rebuild?
        #       CUDAnative et.al could get stale and would need to rebuild
        #       regularly.
        Pkg.rm(pkg)
    catch
    end
end

function cache_all(filter_uuids)
    old_depot = copy(Base.DEPOT_PATH)
    empty!(Base.DEPOT_PATH)
    push!(Base.DEPOT_PATH, depot_path())

    ctx = Pkg.API.Context()
    Pkg.API.update_registry(ctx)
    BinaryProvider.probe_platform_engines!()

    pkgs=read_all_pkgs(filter_uuids)

    pkgs_to_install = Tuple{PackageSpec, SHA1, String}[]
    for (pkg, hash) in pkgs
        pkg.uuid in keys(ctx.stdlibs) && continue
        pkg.path == nothing || continue
        pkg.repo == nothing || continue
        path = Pkg.Operations.find_installed(pkg.name, pkg.uuid, hash)
        if !ispath(path)
            push!(pkgs_to_install, (pkg, hash, path))
        end
    end

    widths = [textwidth(pkg.name) for (pkg, _) in pkgs_to_install]
    max_name = length(widths) == 0 ? 0 : maximum(widths)

    ########################################
    # Install from archives asynchronously #
    ########################################
    jobs = Channel(ctx.num_concurrent_downloads);
    results = Channel(ctx.num_concurrent_downloads);
    @async begin
        for pkg in pkgs_to_install
            put!(jobs, pkg)
        end
    end

    for i in 1:ctx.num_concurrent_downloads
        @async begin
            for (pkg, hash, path) in jobs
                try
                    success = Pkg.Operations.install_archive(urls[pkg.uuid], hash, path)
                    if ctx.use_only_tarballs_for_downloads && !success
                        pkgerror("failed to get tarball from $(urls[pkg.uuid])")
                    end
                    put!(results, (pkg, success, path))
                catch err
                    put!(results, (pkg, err, catch_backtrace()))
                end
            end
        end
    end

    missed_packages = Tuple{PackageSpec, String}[]
    for i in 1:length(pkgs_to_install)
        pkg, exc_or_success, bt_or_path = take!(results)
        exc_or_success isa Exception && pkgerror("Error when installing packages:\n", sprint(Base.showerror, exc_or_success, bt_or_path))
        success, path = exc_or_success, bt_or_path
        if success
            vstr = pkg.version != nothing ? "v$(pkg.version)" : "[$h]"
            printpkgstyle(ctx, :Installed, string(rpad(pkg.name * " ", max_name + 2, "─"), " ", vstr))
        else
            push!(missed_packages, (pkg, path))
        end
    end

    ##################################################
    # Use LibGit2 to download any remaining packages #
    ##################################################
    for (pkg, path) in missed_packages
        uuid = pkg.uuid
        if !ctx.preview
            install_git(ctx, pkg.uuid, pkg.name, hashes[uuid], urls[uuid], pkg.version::VersionNumber, path)
        end
        vstr = pkg.version != nothing ? "v$(pkg.version)" : "[$h]"
        @info "Installed $(rpad(pkg.name * " ", max_name + 2, "─")) $vstr"
    end

    # Cleanup
    rm(joinpath(depot_path(), "environments"), recursive=true)

    empty!(Base.DEPOT_PATH)
    append!(Base.DEPOT_PATH, old_depot)
end

function install(target)
    rmdir(target, recursive=true)
    cp(depot_path(), target, recursive=true)
    rm(joinpath(target, "environments"), recursive=true)
    # Fix a Julia 1.0.0 bug that we attempt to update global registries
    for path in registries(target)
        rm(joinpath(path, ".git"), recursive=true)
    end
end

end