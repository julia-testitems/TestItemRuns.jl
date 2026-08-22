# run.jl — the one-call API

# Settings that are fixed when a session's controller is built, so they cannot be applied
# to a session that already exists.
const _SESSION_LEVEL_KWARGS = (:schedule, :reactor_pool, :log_min_level,
    :activation_timeout_seconds, :shutdown_grace_seconds)

"""
    run_tests(path; kwargs...) -> TestrunResult
    run_tests(session::TestSession, path; kwargs...) -> TestrunResult

Discover every `@testitem` under `path` (a package or workspace folder), run them all and
return the aggregated [`TestrunResult`](@ref). Nothing is printed; observe progress via
`on_event`, and write reports with [`write_json`](@ref), [`write_junit_xml`](@ref) or
[`write_lcov`](@ref).

```julia
using TestItemRuns
result = run_tests("."; max_workers=4, timeout=600)
all(p.status == :passed for t in result.testitems for p in t.profiles) || exit(1)
```

Without a session the run happens on [`default_session`](@ref), so its test processes stay
alive afterwards and a second `run_tests` of the same package reuses them — call
[`close_default_session!`](@ref) to shut them down early (process exit does it anyway).
An application that wants to control that lifetime passes its own [`TestSession`](@ref),
which this function never closes:

```julia
session = TestSession(; activation_timeout_seconds=300)
try
    result = run_tests(session, ".")
finally
    close(session)
end
```

# Keyword arguments
- `filter` — a `TestItem -> Bool` predicate; only matching items run.
- `store_path`, `active_project` — see [`discover_testitems`](@ref).
- `on_event` — receives a [`DiscoveryFinished`](@ref) and then every [`RunEvent`](@ref).
  It is attached to the session for the duration of the call, so on a shared session it
  can also observe process events caused by concurrent runs.
- `schedule`, `reactor_pool`, `activation_timeout_seconds`, `shutdown_grace_seconds` —
  see [`TestSession`](@ref). These are fixed when a session is built, so passing one
  *with* a session is an error, and passing one *without* rebuilds the default session
  when it does not already match (its warm test processes are lost).
- `log_min_level` — minimum level for log records emitted while the run is active
  (default `Logging.Warn`, which hides the controller's info-level lifecycle messages;
  `nothing` leaves the current logger in place). Without a session this is a session
  setting too, since the controller's reactor task keeps the logger it was started with.
- Everything else (`profiles`, `max_workers`, `timeout`, `julia_cmd`, `julia_args`,
  `julia_num_threads`, `check_bounds`, `gc_between_testitems`, `memory_threshold`,
  `fail_on_definition_error`, `failfast`, `log_level`, `coverage_source_subdirs`,
  `token`, `metadata`) is passed to [`run_async!`](@ref).

Cancellation (through `token`) makes the call return normally with the partial result;
check `is_cancellation_requested(token)` — or watch for `RunFinished(status = :cancelled)`.
"""
function run_tests(path; log_min_level=Logging.Warn, kwargs...)
    # The controller logs its lifecycle with @info from the reactor task and the tasks it
    # spawns; tasks inherit the logger at spawn time, so the logger must be in place before
    # the session is created, i.e. around the whole run.
    _with_log_level(log_min_level) do
        _run_tests(nothing, path; log_min_level=log_min_level, kwargs...)
    end
end

function run_tests(session::TestSession, path; log_min_level=Logging.Warn, kwargs...)
    for k in _SESSION_LEVEL_KWARGS
        k === :log_min_level && continue     # only wraps this call's logger here
        haskey(kwargs, k) && throw(ArgumentError(
            "$k configures a session and cannot be set per run; pass it to TestSession instead"))
    end
    _with_log_level(log_min_level) do
        _run_tests(session, path; kwargs...)
    end
end

_with_log_level(f, level) = level === nothing ? f() :
    Logging.with_logger(f, Logging.ConsoleLogger(stderr, level))

function _run_tests(session::Union{Nothing,TestSession}, path;
        filter=nothing,
        store_path::Union{Nothing,String}=nothing,
        active_project::Union{Nothing,String}=nothing,
        on_event=nothing,
        schedule::Symbol=_DEFAULT_SESSION_DEFAULTS.schedule,
        reactor_pool::Union{Nothing,Symbol}=_DEFAULT_SESSION_DEFAULTS.reactor_pool,
        log_min_level=_DEFAULT_SESSION_DEFAULTS.log_min_level,
        activation_timeout_seconds::Union{Nothing,Real}=nothing,
        shutdown_grace_seconds::Union{Nothing,Real}=nothing,
        kwargs...)
    d = discover_testitems(String(path); filter=filter, store_path=store_path, active_project=active_project)
    on_event === nothing || _safe_call(on_event, DiscoveryFinished(d))

    if session === nothing
        session = _default_session_for((; schedule, reactor_pool, log_min_level,
            activation_timeout_seconds, shutdown_grace_seconds))
    end

    # The sink is attached to the session rather than the run so that it also sees process
    # events, which are session-scoped. It is removed again on the way out: the session
    # outlives this call and must not keep calling a sink nobody is listening to.
    on_event === nothing || subscribe!(session, on_event)
    try
        return run!(session, d; kwargs...)
    finally
        if on_event !== nothing
            _flush!(session.events)
            unsubscribe!(session, on_event)
        end
    end
end
