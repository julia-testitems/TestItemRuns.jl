# results.jl — per-run accumulator and TestrunResult assembly

# What a run knows about one of its test environments.
struct EnvInfo
    profile::String
    package_name::String
    package_uri::String
    project_uri::Union{Nothing,String}
end

struct Outcome
    item::TestItem
    test_env_id::String
    profile::String
    status::Symbol
    duration::Union{Nothing,Float64}
    messages::Any
    perf::Any
end

# Everything a run accumulates while it is executing. Mutated only under the session lock.
mutable struct RunState
    const items_by_key::Dict{Tuple{String,String},TestItem}      # (id, package_uri) → item
    const env_info::Dict{String,EnvInfo}                        # test_env_id → env
    const outcomes::Vector{Outcome}                             # in arrival order
    const seen::Set{Tuple{String,String,String}}                # (id, package_uri, env_id)
    const outputs::Dict{Tuple{String,String,String},Vector{String}}
    const process_outputs::Dict{String,Vector{String}}
    const definition_errors::Vector{DefinitionError}
    const item_order::Dict{Tuple{String,String},Int}            # key → position in the run
    const profile_order::Dict{String,Int}                       # profile name → position
    coverage::Any                                               # Vector{FileCoverage} or nothing
    n_total::Int
    passed::Int
    failed::Int
    errored::Int
    skipped::Int
end

RunState(definition_errors::Vector{DefinitionError}, n_total::Int) = RunState(
    Dict{Tuple{String,String},TestItem}(), Dict{String,EnvInfo}(), Outcome[],
    Set{Tuple{String,String,String}}(), Dict{Tuple{String,String,String},Vector{String}}(),
    Dict{String,Vector{String}}(), definition_errors, Dict{Tuple{String,String},Int}(), Dict{String,Int}(),
    nothing, n_total, 0, 0, 0, 0)

_convert_stack_frames(frames) = frames === nothing ? nothing :
    TestrunResultStackFrame[
        TestrunResultStackFrame(f.label, something(f.uri, ""), something(f.line, 0), something(f.column, 0))
        for f in frames
    ]

_convert_perf(perf) = perf === nothing ? nothing :
    TestrunResultPerfStats(perf.elapsed, perf.bytes, perf.allocs, perf.gctime, perf.compile_time, perf.recompile_time)

_convert_coverage(coverage) = coverage === nothing ? nothing :
    TestrunResultFileCoverage[
        TestrunResultFileCoverage(fc.uri, Union{Nothing,Int}[c for c in fc.coverage]) for fc in coverage
    ]

_convert_messages(messages) = messages === nothing ? nothing :
    TestrunResultMessage[
        TestrunResultMessage(m.message, m.expected_output, m.actual_output, something(m.uri, ""),
            something(m.line, 0), something(m.column, 0), _convert_stack_frames(m.stack_trace))
        for m in messages
    ]

# Record one terminal outcome. Returns the Outcome, or `nothing` when it was a duplicate
# (the controller promises one terminal callback per unit; this guards the accumulator anyway).
function _record_outcome!(state::RunState, item::TestItem, test_env_id::String, profile::String,
                          status::Symbol, duration, messages, perf)
    k = (item.id, item.package_uri, test_env_id)
    k in state.seen && return nothing
    push!(state.seen, k)
    status === :passed && (state.passed += 1)
    status === :failed && (state.failed += 1)
    status === :errored && (state.errored += 1)
    status === :skipped && (state.skipped += 1)
    o = Outcome(item, test_env_id, profile, status,
        duration === nothing ? nothing : Float64(duration), messages, perf)
    push!(state.outcomes, o)
    return o
end

_done(state::RunState) = state.passed + state.failed + state.errored + state.skipped

# Build the TestrunResult from the accumulator. Grouping is by `(name, uri)`, which is what
# merges an item's results across profiles. The discovery id rides along rather than being
# derived later: it carries a package qualifier that cannot be recovered from a path, and it
# is what the JUnit report and anything keyed on test identity actually want. Items appear
# in run order and profiles in profile order, whatever the order of completion was.
function assemble_result(state::RunState)
    order = Tuple{String,String}[]
    profiles_by_item = Dict{Tuple{String,String},Vector{Tuple{Int,TestrunResultTestitemProfile}}}()
    id_by_item = Dict{Tuple{String,String},String}()
    position_by_item = Dict{Tuple{String,String},Int}()
    for o in state.outcomes
        k = (o.item.name, o.item.uri)
        haskey(profiles_by_item, k) || push!(order, k)
        get!(id_by_item, k, o.item.id)
        pos = get(state.item_order, key(o.item), typemax(Int))
        position_by_item[k] = min(get(position_by_item, k, typemax(Int)), pos)
        output_key = (o.item.id, o.item.package_uri, o.test_env_id)
        push!(get!(Vector{Tuple{Int,TestrunResultTestitemProfile}}, profiles_by_item, k),
            (get(state.profile_order, o.profile, typemax(Int)), TestrunResultTestitemProfile(
                o.profile,
                o.status,
                o.duration,
                _convert_messages(o.messages),
                haskey(state.outputs, output_key) ? join(state.outputs[output_key]) : nothing,
                _convert_perf(o.perf),
            )))
    end
    sort!(order; by = k -> position_by_item[k])
    profiles_sorted(k) = TestrunResultTestitemProfile[p for (_, p) in sort(profiles_by_item[k]; by=first)]

    return TestrunResult(
        TestrunResultDefinitionError[
            TestrunResultDefinitionError(e.message, e.uri, e.line, e.column) for e in state.definition_errors
        ],
        TestrunResultTestitem[
            TestrunResultTestitem(k[1], k[2], profiles_sorted(k), get(id_by_item, k, "")) for k in order
        ],
        Dict{String,String}(id => join(chunks) for (id, chunks) in state.process_outputs),
        _convert_coverage(state.coverage),
    )
end
