
import .ExpressionExplorer: external_package_names
import .PkgCompat
import .PkgCompat: select, is_stdlib, write_semver_compat_entries!, clear_semver_compat_entries!

const tiers = [
	Pkg.PRESERVE_ALL,
	Pkg.PRESERVE_DIRECT,
	Pkg.PRESERVE_SEMVER,
	Pkg.PRESERVE_NONE,
]

const pkg_token = Token()


function use_plutopkg(topology::NotebookTopology)
    !any(values(topology.nodes)) do node
        Symbol("Pkg.activate") ∈ node.references ||
        Symbol("Pkg.API.activate") ∈ node.references ||
        Symbol("Pkg.add") ∈ node.references ||
        Symbol("Pkg.API.add") ∈ node.references
    end
end

function external_package_names(topology::NotebookTopology)::Set{Symbol}
    union!(Set{Symbol}(), external_package_names.(c.module_usings_imports for c in values(topology.codes))...)
end


PkgCompat.project_file(notebook::Notebook) = PkgCompat.project_file(PkgCompat.env_dir(notebook.nbpkg_ctx))
PkgCompat.manifest_file(notebook::Notebook) = PkgCompat.manifest_file(PkgCompat.env_dir(notebook.nbpkg_ctx))


"""
```julia
update_nbpkg(notebook::Notebook, old::NotebookTopology, new::NotebookTopology; on_terminal_output::Function=((args...) -> nothing))
```

Update the notebook package environment to match the notebook's code. This will:
- Add packages that should be added (because they are imported in a cell).
- Remove packages that are no longer needed.
- Make sure that the environment is instantiated.
- Detect the use of `Pkg.activate` and enable/disabled nbpkg accordingly.
"""
function update_nbpkg(notebook::Notebook, old::NotebookTopology, new::NotebookTopology; on_terminal_output::Function=((args...) -> nothing))
    ctx = notebook.nbpkg_ctx

    👺 = false

    use_plutopkg_old = ctx !== nothing
    use_plutopkg_new = use_plutopkg(new)
    
    if !use_plutopkg_old && use_plutopkg_new
        @info "Started using PlutoPkg!! HELLO reproducibility!"

        👺 = true
        ctx = notebook.nbpkg_ctx = PkgCompat.create_empty_ctx()
    end
    if use_plutopkg_old && !use_plutopkg_new
        @info "Stopped using PlutoPkg 💔😟😢"

        no_packages_loaded_yet = (
            notebook.nbpkg_restart_required_msg === nothing &&
            notebook.nbpkg_restart_recommended_msg === nothing &&
            all(PkgCompat.is_stdlib, keys(PkgCompat.project(ctx).dependencies))
        )
        👺 = !no_packages_loaded_yet
        ctx = notebook.nbpkg_ctx = nothing
    end
    

    if ctx !== nothing
        PkgCompat.mark_original!(ctx)

        old_packages = String.(keys(PkgCompat.project(ctx).dependencies))
        new_packages = String.(external_package_names(new)) # search all cells for imports and usings
        
        removed = setdiff(old_packages, new_packages)
        added = setdiff(new_packages, old_packages)

        iolistener = let
            busy_packages = notebook.nbpkg_ctx_instantiated ? added : new_packages
            IOListener(callback=(s -> on_terminal_output(busy_packages, s)))
        end
        
        # We remember which Pkg.Types.PreserveLevel was used. If it's too low, we will recommend/require a notebook restart later.
        local used_tier = Pkg.PRESERVE_ALL
        
        if !isready(pkg_token)
            println(iolistener.buffer, "Waiting for other notebooks to finish Pkg operations...")
            trigger(iolistener)
        end

        can_skip = isempty(removed) && isempty(added) && notebook.nbpkg_ctx_instantiated

        if !can_skip
            return withtoken(pkg_token) do
                PkgCompat.refresh_registry_cache()

                if !notebook.nbpkg_ctx_instantiated
                    PkgCompat.withio(ctx, IOContext(iolistener.buffer, :color => true)) do
                        Pkg.resolve(ctx)
                    end
                end

                to_remove = filter(removed) do p
                    haskey(PkgCompat.project(ctx).dependencies, p)
                end
                if !isempty(to_remove)
                    @show to_remove
                    # See later comment
                    mkeys() = filter(!is_stdlib, [m.name for m in values(PkgCompat.dependencies(ctx))])
                    old_manifest_keys = mkeys()

                    Pkg.rm(ctx, [
                        Pkg.PackageSpec(name=p)
                        for p in to_remove
                    ])

                    # We record the manifest before and after, to prevent recommending a reboot when nothing got removed from the manifest (e.g. when removing GR, but leaving Plots), or when only stdlibs got removed.
                    new_manifest_keys = mkeys()
                    
                    # TODO: we might want to upgrade other packages now that constraints have loosened? Does this happen automatically?
                end

                
                # TODO: instead of Pkg.PRESERVE_ALL, we actually want:
                # "Pkg.PRESERVE_DIRECT, but preserve exact verisons of Base.loaded_modules"

                to_add = filter(PkgCompat.package_exists, added)
                
                if !isempty(to_add)
                    @show to_add
                    startlistening(iolistener)

                    PkgCompat.withio(ctx, IOContext(iolistener.buffer, :color => true)) do
                        # We temporarily clear the "semver-compatible" [deps] entries, because Pkg already respects semver, unless it doesn't, in which case we don't want to force it.
                        clear_semver_compat_entries!(ctx)

                        for tier in [
                            Pkg.PRESERVE_ALL,
                            Pkg.PRESERVE_DIRECT,
                            Pkg.PRESERVE_SEMVER,
                            Pkg.PRESERVE_NONE,
                        ]
                            used_tier = tier

                            try
                                Pkg.add(ctx, [
                                    Pkg.PackageSpec(name=p)
                                    for p in to_add
                                ]; preserve=used_tier)
                                
                                break
                            catch e
                                if used_tier == Pkg.PRESERVE_NONE
                                    # give up
                                    rethrow(e)
                                end
                            end
                        end

                        write_semver_compat_entries!(ctx)

                        # Now that Pkg is set up, the notebook process will call `using Package`, which can take some time. We write this message to the io, to notify the user.
                        println(iolistener.buffer, "\e[32m\e[1mLoading\e[22m\e[39m packages...")
                    end

                    @info "PlutoPkg done"
                end

                should_instantiate = !notebook.nbpkg_ctx_instantiated || !isempty(to_add) || !isempty(to_remove)
                if should_instantiate
                    startlistening(iolistener)
                    PkgCompat.withio(ctx, IOContext(iolistener.buffer, :color => true)) do
                        # @info "Resolving"
                        # Pkg.resolve(ctx)
                        @info "Instantiating"
                        
                        # Pkg.instantiate assumes that the environment to be instantiated is active, so we will have to modify the LOAD_PATH of this Pluto server
                        # We could also run the Pkg calls on the notebook process, but somehow I think that doing it on the server is more charming, though it requires this workaround.
                        env_dir = PkgCompat.env_dir(notebook.nbpkg_ctx)
                        pushfirst!(LOAD_PATH, env_dir)

                        # update registries if this is the first time
                        PkgCompat.update_registries(ctx)
                        # instantiate without forcing registry update
                        PkgCompat.instantiate(ctx; update_registry=false)
                        
                        @assert LOAD_PATH[1] == env_dir
                        popfirst!(LOAD_PATH)
                    end
                    notebook.nbpkg_ctx_instantiated = true
                end

                stoplistening(iolistener)

                return (
                    did_something=👺 || (
                        should_instantiate || (use_plutopkg_old != use_plutopkg_new)
                    ),
                    used_tier=used_tier,
                    # changed_versions=Dict{String,Pair}(),
                    restart_recommended=👺 || (
                        (!isempty(to_remove) && old_manifest_keys != new_manifest_keys) ||
                        used_tier != Pkg.PRESERVE_ALL
                    ),
                    restart_required=👺 || (
                        used_tier ∈ [Pkg.PRESERVE_SEMVER, Pkg.PRESERVE_NONE]
                    ),
                )
            end
        end
    end
    return (
        did_something=👺 || (use_plutopkg_old != use_plutopkg_new),
        used_tier=Pkg.PRESERVE_ALL,
        # changed_versions=Dict{String,Pair}(),
        restart_recommended=👺 || false,
        restart_required=👺 || false,
    )
end

function reset_nbpkg(notebook::Notebook; backup::Bool=true, save::Bool=true)
    if backup && save
        backup_path = backup_filename(notebook.path)
        Pluto.readwrite(notebook.path, backup_path)

        @info "Backup saved to" backup_path
    end

    notebook.nbpkg_ctx = use_plutopkg(notebook.topology) ? PkgCompat.create_empty_ctx() : nothing

    save && save_notebook(notebook)
end

"A polling system to watch for writes to an IOBuffer. Up-to-date content will be passed as string to the `callback` function."
Base.@kwdef struct IOListener
    callback::Function
    buffer::IOBuffer=IOBuffer()
    interval::Real=1.0/60
    running::Ref{Bool}=Ref(false)
    last_size::Ref{Int}=Ref(-1)
end
function trigger(listener::IOListener)
    new_size = listener.buffer.size
    if new_size > listener.last_size[]
        listener.last_size[] = new_size
        new_contents = String(listener.buffer.data[1:new_size])
        listener.callback(new_contents)
    end
end
function startlistening(listener::IOListener)
    if !listener.running[]
        listener.running[] = true
        @async while listener.running[]
            trigger(listener)
            sleep(listener.interval)
        end
    end
end
function stoplistening(listener::IOListener)
    if listener.running[]
        listener.running[] = false
        trigger(listener)
    end
end
