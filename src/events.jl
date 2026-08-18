# events.jl — the typed event stream a run produces

"""
    RunEvent

Abstract supertype of everything an `on_event` callback receives. Events are delivered off
the controller's reactor task, in order, one at a time per sink; a slow sink delays only
its own delivery, never test execution.

Run-scoped events (`RunStarted`, `TestItemStarted`, `TestItemFinished`, `OutputAppended`,
`RunFinished`) carry the [`TestRun`](@ref) they belong to. Process events
(`ProcessCreated`, `ProcessStatusChanged`, `ProcessTerminated`, `ProcessOutput`) are
session-scoped — a pooled process serves many runs — and are delivered to the session's
`on_event` and to every run active at that moment.
"""
abstract type RunEvent end

"""
    DiscoveryFinished(discovery)

Emitted by [`run_tests`](@ref) once discovery is done, before anything runs.
"""
struct DiscoveryFinished <: RunEvent
    discovery::Discovery
end

"""
    RunStarted(run, n_items, n_units, n_profiles)

The first event of a run. `n_units == n_items * n_profiles` is the number of
`TestItemFinished` events to expect.
"""
struct RunStarted <: RunEvent
    run::Any   # ::TestRun — declared later
    n_items::Int
    n_units::Int
    n_profiles::Int
end

"""
    TestItemStarted(run, item, profile)

A test item started executing under the named profile.
"""
struct TestItemStarted <: RunEvent
    run::Any
    item::TestItem
    profile::String
end

"""
    TestItemFinished(run, item, profile, status, duration, messages, perf, skip_reason)

The terminal event of one (item, profile) unit. `status` is `:passed`, `:failed`,
`:errored` or `:skipped`; `duration` is milliseconds or `nothing` when the controller
synthesised the result (timeout, crash); `messages` is `nothing` or a vector of
`TestItemControllers.TestMessage`; `perf` is `nothing` or a `TestItemControllers.PerfStats`;
`skip_reason` is `nothing` or a String.
"""
struct TestItemFinished <: RunEvent
    run::Any
    item::TestItem
    profile::String
    status::Symbol
    duration::Union{Nothing,Float64}
    messages::Any
    perf::Any
    skip_reason::Union{Nothing,String}
end

"""
    OutputAppended(run, item, profile, output)

A chunk of output captured while `item` was running. Output is always also accumulated
into the result; this event exists for live streaming.
"""
struct OutputAppended <: RunEvent
    run::Any
    item::TestItem
    profile::String
    output::String
end

"""
    ProcessCreated(id, package_name, package_uri, project_uri, profile, test_env_id)

A test process was launched (for the given package/profile environment).
"""
struct ProcessCreated <: RunEvent
    id::String
    package_name::String
    package_uri::String
    project_uri::Union{Nothing,String}
    profile::Union{Nothing,String}
    test_env_id::String
end

"""
    ProcessStatusChanged(id, status)

A test process changed status (`"Launching"`, `"Revising"`, `"Idle"`, … — the
TestItemControllers status strings).
"""
struct ProcessStatusChanged <: RunEvent
    id::String
    status::String
end

"""
    ProcessTerminated(id)
"""
struct ProcessTerminated <: RunEvent
    id::String
end

"""
    ProcessOutput(id, output)

Output a test process wrote outside of any test item (startup, precompilation, …).
"""
struct ProcessOutput <: RunEvent
    id::String
    output::String
end

"""
    RunFinished(run, status, result)

The last event of a run. `status` is `:completed`, `:cancelled` or `:errored`; `result`
is the (possibly partial) [`TestrunResult`](@ref).
"""
struct RunFinished <: RunEvent
    run::Any
    status::Symbol
    result::TestrunResult
end
