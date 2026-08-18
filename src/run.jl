# run.jl — the one-call API

"""
    run_tests(path; kwargs...) -> TestrunResult

Discover every `@testitem` under `path` (a package or workspace folder), run them all and
return the aggregated [`TestrunResult`](@ref). Nothing is printed; observe progress via
`on_event`, and write reports with [`write_json`](@ref), [`write_junit_xml`](@ref) or
[`write_lcov`](@ref).

```julia
using TestItemRuns
result = run_tests("."; max_workers=4, timeout=600)
all(p.status == :passed for t in result.testitems for p in t.profiles) || exit(1)
```

# Keyword arguments
- `filter` — a `TestItem -> Bool` predicate; only matching items run.
- `store_path`, `active_project` — see [`discover_testitems`](@ref).
- `on_event` — receives a [`DiscoveryFinished`](@ref) and then every [`RunEvent`](@ref).
- `schedule` — `:duration` (default) or `:contiguous`.
- `log_min_level` — minimum level for log records emitted while the run is active
  (default `Logging.Warn`, which hides the controller's info-level lifecycle messages;
  `nothing` leaves the current logger in place).
- Everything else (`profiles`, `max_workers`, `timeout`, `julia_cmd`, `julia_args`,
  `julia_num_threads`, `check_bounds`, `gc_between_testitems`, `memory_threshold`,
  `fail_on_definition_error`, `token`, `metadata`) is passed to [`run_async!`](@ref).

Cancellation (through `token`) makes the call return normally with the partial result;
check `is_cancellation_requested(token)` — or watch for `RunFinished(status = :cancelled)`.
"""
function run_tests(path; log_min_level=Logging.Warn, kwargs...)
    # The controller logs its lifecycle with @info from the reactor task and the tasks it
    # spawns; tasks inherit the logger at spawn time, so the logger must be in place before
    # the session is created, i.e. around the whole run.
    if log_min_level === nothing
        return _run_tests(path; kwargs...)
    else
        return Logging.with_logger(Logging.ConsoleLogger(stderr, log_min_level)) do
            _run_tests(path; kwargs...)
        end
    end
end

function _run_tests(path;
        filter=nothing,
        store_path::Union{Nothing,String}=nothing,
        active_project::Union{Nothing,String}=nothing,
        on_event=nothing,
        schedule::Symbol=:duration,
        kwargs...)
    d = discover_testitems(String(path); filter=filter, store_path=store_path, active_project=active_project)
    on_event === nothing || _safe_call(on_event, DiscoveryFinished(d))
    # The sink is attached to the session rather than the run so that it also sees the
    # process teardown that happens after `RunFinished`.
    session = TestSession(; schedule=schedule, on_event=on_event)
    try
        return run!(session, d; kwargs...)
    finally
        close(session)
    end
end
