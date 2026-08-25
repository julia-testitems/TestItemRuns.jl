# discovery.jl — JuliaWorkspaces → TestItemControllers bridge

# `position_at` returned a `(line, column)` tuple in older JuliaWorkspaces versions
# and now returns a `Position`. Accept either.
_line(pos) = hasproperty(pos, :line) ? pos.line : pos[1]
_column(pos) = hasproperty(pos, :column) ? pos.column : pos[2]

function _display_path(uri::AbstractString)
    path = try
        TestItemControllers.uri2filepath(uri)
    catch
        nothing
    end
    return path === nothing ? uri : path
end

"""
    TestItem

One discovered `@testitem`, ready to be run. Wraps the
`TestItemControllers.TestItemDetail` in `detail` and adds what discovery knows on top.

Convenience properties: `id`, `name`, `uri`, `filename` (a file system path when the uri
is a `file:` uri), `package_name`, `package_uri`, `project_uri`, `env_content_hash`,
`tags`, `setups`, `line`, `column`, `code`, `skip`.

Ids are scoped to their package (`"<Package>@<uuid8>/<relpath>::<name>"`) — two checkouts
of the same package mint the same ids — so a test item is uniquely identified by
`(id, package_uri)`; see [`key`](@ref TestItemRuns.key).
"""
struct TestItem
    detail::TestItemControllers.TestItemDetail
    tags::Vector{Symbol}
    project_uri::Union{Nothing,String}
    env_content_hash::Union{Nothing,String}
end

function Base.getproperty(item::TestItem, name::Symbol)
    name === :detail && return getfield(item, :detail)
    name === :tags && return getfield(item, :tags)
    name === :project_uri && return getfield(item, :project_uri)
    name === :env_content_hash && return getfield(item, :env_content_hash)
    d = getfield(item, :detail)
    name === :id && return d.id
    name === :name && return d.label
    name === :uri && return d.uri
    name === :filename && return _display_path(d.uri)
    name === :package_name && return d.package_name
    name === :package_uri && return d.package_uri
    name === :setups && return d.test_setups
    name === :line && return d.line
    name === :column && return d.column
    name === :code && return d.code
    name === :skip && return d.option_skip
    throw(ArgumentError("TestItem has no property $name"))
end

Base.propertynames(::TestItem) = (:detail, :tags, :project_uri, :env_content_hash, :id, :name,
    :uri, :filename, :package_name, :package_uri, :setups, :line, :column, :code, :skip)

Base.show(io::IO, item::TestItem) = print(io, "TestItem(", repr(item.name), " @ ", item.filename, ":", item.line, ")")

"""
    key(item::TestItem) -> (id, package_uri)

The tuple that uniquely identifies a test item within a workspace.
"""
key(item::TestItem) = (item.id, item.package_uri)

"""
    filename(item::TestItem)

The file system path of the file defining `item` (or its uri when it is not a `file:` uri).
"""
filename(item::TestItem) = item.filename

"""
    DefinitionError

A `@testitem`/`@testsetup` that could not be parsed. `line`/`column` and
`end_line`/`end_column` delimit the offending source range (1-based).
"""
struct DefinitionError
    uri::String
    id::String
    name::Union{Nothing,String}
    line::Int
    column::Int
    end_line::Int
    end_column::Int
    message::String
end

filename(e::DefinitionError) = _display_path(e.uri)

"""
    Discovery

The result of [`discover_testitems`](@ref): a plain snapshot, independent of the workspace
it was taken from.

# Fields
- `roots::Vector{String}` — the folders that were scanned (empty when discovery ran on a
  caller-owned workspace and no `roots` were given).
- `testitems::Vector{TestItem}`
- `setups::Vector{TestItemControllers.TestSetupDetail}` — every `@testmodule`/`@testsnippet`,
  needed by the test processes regardless of which items are selected.
- `definition_errors::Vector{DefinitionError}`

`filter(f, d)`, [`select`](@ref), `length(d)`, iteration and indexing act on `testitems`;
`setups` and `definition_errors` are carried along unchanged.
"""
struct Discovery
    roots::Vector{String}
    testitems::Vector{TestItem}
    setups::Vector{TestItemControllers.TestSetupDetail}
    definition_errors::Vector{DefinitionError}
end

Base.length(d::Discovery) = length(d.testitems)
Base.iterate(d::Discovery, args...) = iterate(d.testitems, args...)
Base.getindex(d::Discovery, i) = d.testitems[i]
Base.eltype(::Type{Discovery}) = TestItem
Base.isempty(d::Discovery) = isempty(d.testitems)
Base.filter(f, d::Discovery) = Discovery(d.roots, Base.filter(f, d.testitems), d.setups, d.definition_errors)
function Base.show(io::IO, d::Discovery)
    n_files = length(unique(i.uri for i in d.testitems))
    print(io, "Discovery(", length(d.testitems), " test items in ", n_files, " files, ",
        length(d.setups), " setups, ", length(d.definition_errors), " definition errors)")
end

"""
    package_envs(d::Discovery)

The distinct test environments the items need, as
`(package_name, package_uri, project_uri, env_content_hash)` named tuples.

One entry per distinct combination, not per package: a package whose items resolve to
different projects yields more than one. That happens whenever a `Project.toml` +
`Manifest.toml` pair sits below the package folder — say `test/special/` — and `dev`s the
package, which is how different groups of test items get their versions from different
manifests. Grouping by `package_uri` alone would give all of them whichever project the
first discovered item happened to select.
"""
function package_envs(d::Union{Discovery,AbstractVector{TestItem}})
    items = d isa Discovery ? d.testitems : d
    Key = Tuple{String,Union{Nothing,String},Union{Nothing,String}}
    seen = Dict{Key,NamedTuple}()
    order = Key[]
    for i in items
        k = (i.package_uri, i.project_uri, i.env_content_hash)
        haskey(seen, k) && continue
        push!(order, k)
        seen[k] = (package_name=i.package_name, package_uri=i.package_uri,
            project_uri=i.project_uri, env_content_hash=i.env_content_hash)
    end
    return [seen[k] for k in order]
end

"""
    packages(d::Discovery)

Deprecated alias for [`package_envs`](@ref).

The old name described what the function was meant to return rather than what it has to:
grouping by package alone gave every test item of a package the environment of whichever
item was discovered first, which is wrong as soon as two of them resolve to different
projects.
"""
function packages(d::Union{Discovery,AbstractVector{TestItem}})
    Base.depwarn("`packages` is deprecated, use `package_envs` instead.", :packages)
    return package_envs(d)
end

_matches(pattern::Regex, s) = occursin(pattern, s)
_matches(pattern::AbstractString, s) = occursin(pattern, s)

"""
    select(d::Discovery; ids=nothing, keys=nothing, names=nothing, name_pattern=nothing,
           file_pattern=nothing, tags=nothing, packages=nothing, predicate=nothing)

Return a [`Discovery`](@ref) restricted to the test items matching every given criterion:

- `ids` — item ids (`item.id`); `keys` — `(id, package_uri)` tuples (see [`key`](@ref TestItemRuns.key)).
- `names` — exact names; `name_pattern` — a `Regex` or substring matched against the name.
- `file_pattern` — a `Regex` or substring matched against [`filename`](@ref).
- `tags` — an item matches when it carries *any* of the given tags (Symbols or Strings).
- `packages` — package names.
- `predicate` — an arbitrary `TestItem -> Bool`.

Setups and definition errors are kept unchanged.
"""
function select(d::Discovery; ids=nothing, keys=nothing, names=nothing, name_pattern=nothing,
                file_pattern=nothing, tags=nothing, packages=nothing, predicate=nothing)
    id_set = ids === nothing ? nothing : Set{String}(string.(ids))
    key_set = keys === nothing ? nothing : Set{Tuple{String,String}}((string(k[1]), string(k[2])) for k in keys)
    name_set = names === nothing ? nothing : Set{String}(string.(names))
    tag_set = tags === nothing ? nothing : Set{Symbol}(Symbol.(tags))
    pkg_set = packages === nothing ? nothing : Set{String}(string.(packages))
    return Base.filter(d) do item
        id_set !== nothing && !(item.id in id_set) && return false
        key_set !== nothing && !(key(item) in key_set) && return false
        name_set !== nothing && !(item.name in name_set) && return false
        name_pattern !== nothing && !_matches(name_pattern, item.name) && return false
        file_pattern !== nothing && !_matches(file_pattern, item.filename) && return false
        tag_set !== nothing && !any(t -> t in tag_set, item.tags) && return false
        pkg_set !== nothing && !(item.package_name in pkg_set) && return false
        predicate !== nothing && !predicate(item) && return false
        return true
    end
end

"""
    discover_testitems([path]; filter=nothing, store_path=nothing, active_project=nothing) -> Discovery
    discover_testitems(paths::Vector{String}; kwargs...) -> Discovery
    discover_testitems(jw::JuliaWorkspaces.JuliaWorkspace; filter=nothing, roots=String[]) -> Discovery

Discover every `@testitem`, `@testmodule`/`@testsnippet` and definition error under
`path(s)` (a fresh JuliaWorkspaces workspace is created), or in a caller-owned workspace
`jw`. `path` defaults to the current working directory.

- `filter` — a `TestItem -> Bool` predicate; only matching items are kept (setups and
  definition errors are always kept).
- `store_path` — JuliaWorkspaces on-disk store (only for path-based discovery).
- `active_project` — a project folder or file used as the fallback environment for files
  outside any project (only for path-based discovery).

The workspace overload does not lock or retain `jw`: callers that mutate their workspace
concurrently (file watchers) must hold their own lock around the call. The returned
[`Discovery`](@ref) is a plain snapshot.
"""
discover_testitems(; kwargs...) = discover_testitems(pwd(); kwargs...)

function discover_testitems(path::AbstractString; kwargs...)
    return discover_testitems(String[String(path)]; kwargs...)
end

function discover_testitems(paths::Vector{String}; filter=nothing, store_path::Union{Nothing,String}=nothing,
                            active_project::Union{Nothing,String}=nothing)
    roots = String[abspath(p) for p in paths]
    # `scope=:testitems` makes the folder walk itself honour `JuliaTestItems.toml`,
    # so a directory its globs exclude is never read from disc. Without it a
    # repository holding a large tree of test data under an excluded folder pays
    # to list and read all of it before discovery throws it away again. Only the
    # test-item config has a say here: a wider `include` in `JuliaFormat.toml` or
    # `JuliaLint.toml` must not drag extra directories into a test run.
    jw = JuliaWorkspaces.workspace_from_folders(roots; store_path=store_path, scope=:testitems)
    if active_project !== nothing
        proj = abspath(active_project)
        proj_dir = isdir(proj) ? proj : dirname(proj)
        JuliaWorkspaces.set_active_project!(jw, JuliaWorkspaces.filepath2uri(proj_dir))
    end
    return discover_testitems(jw; filter=filter, roots=roots)
end

function discover_testitems(jw::JuliaWorkspaces.JuliaWorkspace; filter=nothing, roots::Vector{String}=String[])
    testitems = TestItem[]
    setups = TestItemControllers.TestSetupDetail[]
    errors = DefinitionError[]

    for (uri, file_info) in pairs(JuliaWorkspaces.get_test_items(jw))
        env = JuliaWorkspaces.get_test_env(jw, uri)
        textfile = JuliaWorkspaces.get_text_file(jw, uri)
        package_name = something(env.package_name, "")
        package_uri = env.package_uri === nothing ? "" : string(env.package_uri)
        project_uri = env.project_uri === nothing ? nothing : string(env.project_uri)
        env_content_hash = env.env_content_hash === nothing ? nothing : string(env.env_content_hash)

        for item in file_info.testitems
            item_pos = JuliaWorkspaces.position_at(textfile.content, first(item.range))
            code_pos = JuliaWorkspaces.position_at(textfile.content, first(item.code_range))
            detail = TestItemControllers.TestItemDetail(
                item.id,
                string(item.uri),
                item.name,
                package_name,
                package_uri,
                item.option_default_imports,
                String[string(s) for s in item.option_setup],
                _line(item_pos),
                _column(item_pos),
                textfile.content.content[item.code_range],
                _line(code_pos),
                _column(code_pos),
                # `skip` is recorded by discovery; the test process must be told about it or
                # skipped items silently run.
                item.option_skip,
            )
            ti = TestItem(detail, Symbol[item.option_tags...], project_uri, env_content_hash)
            (filter === nothing || filter(ti)) && push!(testitems, ti)
        end

        for e in file_info.testerrors
            start_pos = JuliaWorkspaces.position_at(textfile.content, first(e.range))
            stop_pos = JuliaWorkspaces.position_at(textfile.content, last(e.range))
            push!(errors, DefinitionError(string(e.uri), e.id, e.name, _line(start_pos), _column(start_pos),
                _line(stop_pos), _column(stop_pos), e.message))
        end

        for setup in file_info.testsetups
            env.package_uri === nothing && continue
            pos = JuliaWorkspaces.position_at(textfile.content, first(setup.code_range))
            push!(setups, TestItemControllers.TestSetupDetail(
                package_uri,
                string(setup.name),
                string(setup.kind),
                string(uri),
                _line(pos),
                _column(pos),
                textfile.content.content[setup.code_range],
            ))
        end
    end

    # Deterministic order: by file, then position.
    sort!(testitems; by=i -> (i.uri, i.line, i.column))
    sort!(errors; by=e -> (e.uri, e.line, e.column))

    return Discovery(roots, testitems, setups, errors)
end
