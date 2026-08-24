# session.jl — long-lived test session: controller + process pool + runs

abstract type AbstractSession end

"""
    ProcessInfo

A test process managed by a [`TestSession`](@ref): `id`, `package_name`, `package_uri`,
`project_uri`, `profile` (the profile it was launched for), `status` (the
TestItemControllers status string, e.g. `"Launching"`, `"Running"`, `"Idle"`),
`created_at`, `test_env_id`.
"""
mutable struct ProcessInfo
    const id::String
    const package_name::String
    const package_uri::String
    const project_uri::Union{Nothing,String}
    const profile::Union{Nothing,String}
    status::String
    const created_at::Dates.DateTime
    const test_env_id::String
end

Base.show(io::IO, p::ProcessInfo) = print(io, "ProcessInfo(", p.id, ", ", p.package_name, ", ", p.status, ")")

"""
    TestRun

One execution of a set of test items under one or more profiles, created by
[`run_async!`](@ref)/[`run!`](@ref).

# Fields (read-only from the outside)
- `id::String`
- `session::TestSession`
- `items::Vector{TestItem}`, `profiles::Vector{RunProfile}`
- `params::NamedTuple` — the run settings, for re-running (`run_async!(session, items; run.params...)`)
- `metadata::Dict{String,Any}` — free-form, for the caller (e.g. the path that was run)
- `status::Symbol` — `:running`, `:completed`, `:cancelled` or `:errored`
- `started_at`, `finished_at::Union{Nothing,DateTime}`
- `result::Union{Nothing,TestrunResult}` — set once finished (partial when cancelled/errored)
- `error` — the exception when `status == :errored`
- `failfast::Bool`, `stop_reason::Union{Nothing,Symbol}` — see [`stop_reason`](@ref)

`wait(run)` blocks until finished; `fetch(run)` additionally returns the result (rethrowing
the error of an errored run). See also [`cancel!`](@ref), [`snapshot`](@ref),
[`run_progress`](@ref), [`subscribe!`](@ref).
"""
mutable struct TestRun
    const id::String
    const session::AbstractSession
    const items::Vector{TestItem}
    const profiles::Vector{RunProfile}
    const params::NamedTuple
    const metadata::Dict{String,Any}
    const started_at::Dates.DateTime
    finished_at::Union{Nothing,Dates.DateTime}
    status::Symbol
    result::Union{Nothing,TestrunResult}
    error::Any
    const cts::CancellationTokenSource
    task::Union{Nothing,Task}
    const failfast::Bool
    stop_reason::Union{Nothing,Symbol}
    # The caller's token, when one was passed; `run.cts` is linked to it, so it is what
    # distinguishes an outside cancellation from a failfast-triggered one.
    const external_token::Union{Nothing,CancellationToken}
    # private
    const state::RunState
    const events::Channel{RunEvent}
    const sinks::Vector{Any}
    drain_task::Union{Nothing,Task}
    const done::Threads.Event
end

function Base.show(io::IO, run::TestRun)
    p = run_progress(run)
    print(io, "TestRun(", first(run.id, 8), ", ", run.status, ", ", p.done, "/", p.total, ")")
end

"""
    TestSession(; schedule=:duration, on_event=nothing, max_history=50, reactor_pool=nothing,
                log_min_level=nothing, shutdown_grace_seconds=nothing,
                activation_timeout_seconds=nothing)

A long-lived test session: one `TestItemControllers.TestItemController` with its reactor
task and a pool of test processes that is reused across runs (processes are revised
between runs, restarted when the environment changes).

- `schedule` — `:duration` (default) or `:contiguous`, see `TestItemController`.
- `on_event` — a callback receiving every [`RunEvent`](@ref) of every run plus all process
  events (also `subscribe!(session, f)` later).
- `max_history` — how many finished runs [`list_runs`](@ref) retains; `nothing` = unbounded.
- `reactor_pool` — `nothing` runs the reactor as an `@async` task of the constructing task;
  `:interactive` uses `Threads.@spawn :interactive` so it keeps being scheduled while
  user code saturates the default thread pool (REPL front ends).
- `log_min_level` — when given, the controller's own log records (emitted from the reactor
  task) go to a `ConsoleLogger(stderr, log_min_level)`; `nothing` inherits the current logger.
- `shutdown_grace_seconds` — how long `close` waits for test processes to exit before
  killing them.
- `activation_timeout_seconds` — bound how long a test process may spend activating and
  precompiling its environment; items of an environment that exceeds it are errored
  instead of hanging. `nothing` (default) does not bound it.

These settings are fixed when the controller is built, so they belong on the session
rather than on an individual run.

Close with `close(session)`; test processes are shut down then.
"""
mutable struct TestSession <: AbstractSession
    const controller::TestItemController
    const reactor_task::Task
    const lock::ReentrantLock
    const runs::Dict{String,TestRun}
    const history::Vector{TestRun}                          # oldest first
    const env_info::Dict{String,EnvInfo}                    # test_env_id → env (all runs)
    const processes::Dict{String,ProcessInfo}
    const process_outputs::Dict{String,Vector{String}}
    const sinks::Vector{Any}
    const events::Channel{RunEvent}
    drain_task::Union{Nothing,Task}
    const max_history::Union{Nothing,Int}
    closed::Bool
end

function Base.show(io::IO, s::TestSession)
    n_runs, n_procs = lock(s.lock) do
        length(s.history), length(s.processes)
    end
    print(io, "TestSession(", s.closed ? "closed" : "open", ", ", n_runs, " runs, ", n_procs, " processes)")
end

_or(a, b) = a === nothing ? b : a

# `invokelatest`: sinks are routinely defined after the drain task started (REPL sessions,
# `subscribe!` mid-run) and would otherwise be too new for the task's world age.
function _safe_call(f, ev)
    try
        Base.invokelatest(f, ev)
    catch err
        @error "TestItemRuns: event callback threw" exception = (err, catch_backtrace()) event = typeof(ev)
    end
    return nothing
end

function _try_put!(ch::Channel, ev)
    try
        put!(ch, ev)
        return true
    catch err
        err isa InvalidStateException || rethrow()   # closed channel: late event, drop it
        return false
    end
end

# A barrier in an event stream: never delivered to sinks, only signals that every event
# queued before it has been delivered.
struct _Flush <: RunEvent
    done::Threads.Event
end

function _flush!(events::Channel{RunEvent})
    f = _Flush(Threads.Event())
    _try_put!(events, f) && wait(f.done)
    return nothing
end

# Deliver a run-scoped event: to the run's sinks and to the session's sinks.
function _emit_run!(session::TestSession, run::TestRun, ev::RunEvent)
    _try_put!(run.events, ev)
    _try_put!(session.events, ev)
    return nothing
end

# Deliver a session-scoped (process) event: to the session's sinks and every active run.
function _emit_session!(session::TestSession, ev::RunEvent)
    active = lock(session.lock) do
        TestRun[r for r in values(session.runs) if r.status === :running]
    end
    for r in active
        _try_put!(r.events, ev)
    end
    _try_put!(session.events, ev)
    return nothing
end

function _drain(events::Channel{RunEvent}, sinks::Vector{Any}, lk::ReentrantLock)
    for ev in events
        if ev isa _Flush
            notify(ev.done)
            continue
        end
        current = lock(lk) do
            copy(sinks)
        end
        for f in current
            _safe_call(f, ev)
        end
    end
    return nothing
end

# Resolve (run, env, item) from what the controller hands us; `nothing` for anything unknown.
function _resolve(session::TestSession, run_id, item_id, env_id)
    lock(session.lock) do
        run = get(session.runs, run_id, nothing)
        run === nothing && return nothing
        env = get(run.state.env_info, env_id, nothing)
        env === nothing && return nothing
        item = get(run.state.items_by_key, (item_id, env.package_uri), nothing)
        item === nothing && return nothing
        return (run, env, item)
    end
end

function _finish_unit!(session::TestSession, run_id, item_id, env_id, status, duration, messages, perf, reason)
    r = _resolve(session, run_id, item_id, env_id)
    r === nothing && return nothing
    run, env, item = r
    outcome = lock(session.lock) do
        _record_outcome!(run.state, item, env_id, env.profile, status, duration, messages, perf)
    end
    outcome === nothing && return nothing
    _emit_run!(session, run, TestItemFinished(run, item, env.profile, status, outcome.duration, messages, perf,
        reason === nothing ? nothing : string(reason)))
    # The controller is what actually stops a failfast run: it is told `failfast=true` up
    # front and acts on the failure inside the same reactor step that reported it, which is
    # the only place the decision can be made in time — a worker is handed its test items as
    # a batch, so a cancellation requested from here is merely appended to the reactor queue
    # and can land behind a result the worker has already sent for the next item.
    #
    # This still records the reason and cancels `run.cts`, which keeps `stop_reason` and
    # `iscancelled` meaningful and remains a backstop if the run outlives the controller's
    # own stop. The event above is emitted first so a sink sees the failure before the skip
    # cascade.
    if run.failfast && (status === :failed || status === :errored)
        _request_stop!(run, :failfast)
    end
    return nothing
end

# Record why a run is being stopped and cancel it. The first reason wins: a failfast that
# lands while the user is already cancelling must not overwrite `:user`.
function _request_stop!(run::TestRun, reason::Symbol)
    lock(run.session.lock) do
        run.stop_reason === nothing && (run.stop_reason = reason)
    end
    cancel(run.cts)
    return nothing
end

function _make_callbacks(session_ref::Ref{TestSession})
    return ControllerCallbacks(
        on_testitem_started = (run_id, item_id, env_id) -> begin
            session = session_ref[]
            r = _resolve(session, run_id, item_id, env_id)
            r === nothing && return nothing
            run, env, item = r
            _emit_run!(session, run, TestItemStarted(run, item, env.profile))
            nothing
        end,
        on_testitem_passed = (run_id, item_id, env_id, duration, perf=nothing) ->
            _finish_unit!(session_ref[], run_id, item_id, env_id, :passed, duration, nothing, perf, nothing),
        on_testitem_failed = (run_id, item_id, env_id, messages, duration, perf=nothing) ->
            _finish_unit!(session_ref[], run_id, item_id, env_id, :failed, duration, messages, perf, nothing),
        on_testitem_errored = (run_id, item_id, env_id, messages, duration, perf=nothing) ->
            _finish_unit!(session_ref[], run_id, item_id, env_id, :errored, duration, messages, perf, nothing),
        on_testitem_skipped = (run_id, item_id, env_id, reason=nothing) ->
            _finish_unit!(session_ref[], run_id, item_id, env_id, :skipped, nothing, nothing, nothing, reason),
        on_append_output = (run_id, item_id, env_id, output) -> begin
            item_id === nothing && return nothing   # process-level output arrives via on_process_output
            session = session_ref[]
            r = _resolve(session, run_id, item_id, env_id)
            r === nothing && return nothing
            run, env, item = r
            lock(session.lock) do
                push!(get!(Vector{String}, run.state.outputs, (item.id, item.package_uri, env_id)), output)
            end
            _emit_run!(session, run, OutputAppended(run, item, env.profile, output))
            nothing
        end,
        on_attach_debugger = (run_id, debug_pipename) -> nothing,
        on_process_created = (id, env_id) -> begin
            session = session_ref[]
            info = lock(session.lock) do
                env = get(session.env_info, env_id, nothing)
                p = ProcessInfo(id,
                    env === nothing ? "" : env.package_name,
                    env === nothing ? "" : env.package_uri,
                    env === nothing ? nothing : env.project_uri,
                    env === nothing ? nothing : env.profile,
                    "Created", Dates.now(), env_id)
                session.processes[id] = p
                p
            end
            _emit_session!(session, ProcessCreated(id, info.package_name, info.package_uri, info.project_uri,
                info.profile, env_id))
            nothing
        end,
        on_process_terminated = id -> begin
            session = session_ref[]
            lock(session.lock) do
                delete!(session.processes, id)
            end
            _emit_session!(session, ProcessTerminated(id))
            nothing
        end,
        on_process_status_changed = (id, status) -> begin
            session = session_ref[]
            lock(session.lock) do
                p = get(session.processes, id, nothing)
                p === nothing || (p.status = status)
            end
            _emit_session!(session, ProcessStatusChanged(id, status))
            nothing
        end,
        on_process_output = (id, output) -> begin
            session = session_ref[]
            lock(session.lock) do
                push!(get!(Vector{String}, session.process_outputs, id), output)
                for r in values(session.runs)
                    r.status === :running || continue
                    push!(get!(Vector{String}, r.state.process_outputs, id), output)
                end
            end
            _emit_session!(session, ProcessOutput(id, output))
            nothing
        end,
    )
end

function TestSession(; schedule::Symbol=:duration, on_event=nothing, max_history::Union{Nothing,Int}=50,
                     reactor_pool::Union{Nothing,Symbol}=nothing, log_min_level=nothing,
                     shutdown_grace_seconds::Union{Nothing,Real}=nothing,
                     activation_timeout_seconds::Union{Nothing,Real}=nothing)
    schedule in (:duration, :contiguous) || throw(ArgumentError("schedule must be :duration or :contiguous"))
    reactor_pool in (nothing, :interactive) || throw(ArgumentError("reactor_pool must be nothing or :interactive"))
    activation_timeout_seconds === nothing || activation_timeout_seconds > 0 ||
        throw(ArgumentError("activation_timeout_seconds must be positive"))

    session_ref = Ref{TestSession}()
    callbacks = _make_callbacks(session_ref)

    make = () -> begin
        kw = shutdown_grace_seconds === nothing ? (;) : (; shutdown_grace_seconds=Float64(shutdown_grace_seconds))
        controller = TestItemController(callbacks; schedule=schedule,
            activation_timeout_seconds=activation_timeout_seconds === nothing ? nothing : Float64(activation_timeout_seconds),
            kw...)
        body = () -> try
            run(controller)
        catch err
            @error "TestItemRuns: controller reactor failed" exception = (err, catch_backtrace())
        end
        reactor_task = reactor_pool === :interactive ? Threads.@spawn(:interactive, body()) : @async(body())
        (controller, reactor_task)
    end
    controller, reactor_task = log_min_level === nothing ? make() :
        Logging.with_logger(make, Logging.ConsoleLogger(stderr, log_min_level))

    session = TestSession(controller, reactor_task, ReentrantLock(), Dict{String,TestRun}(), TestRun[],
        Dict{String,EnvInfo}(), Dict{String,ProcessInfo}(), Dict{String,Vector{String}}(),
        Any[], Channel{RunEvent}(Inf), nothing, max_history, false)
    on_event === nothing || push!(session.sinks, on_event)
    session.drain_task = @async _drain(session.events, session.sinks, session.lock)
    session_ref[] = session
    return session
end

Base.isopen(session::TestSession) = !session.closed

"""
    subscribe!(x::Union{TestSession,TestRun}, f)
    unsubscribe!(x::Union{TestSession,TestRun}, f)

Add/remove an event sink. A run's sinks receive that run's events (and process events
while it is active); a session's sinks receive everything. Sinks can be added and removed
while a run is in flight.
"""
function subscribe!(x::Union{TestSession,TestRun}, f)
    lk = x isa TestSession ? x.lock : x.session.lock
    lock(lk) do
        push!(x.sinks, f)
    end
    return x
end

function unsubscribe!(x::Union{TestSession,TestRun}, f)
    lk = x isa TestSession ? x.lock : x.session.lock
    lock(lk) do
        Base.filter!(s -> s !== f, x.sinks)
    end
    return x
end

"""
    run_async!(session, testitems; kwargs...) -> TestRun

Start running `testitems` — a [`Discovery`](@ref) or a vector of [`TestItem`](@ref)s — on
`session` and return immediately. `wait(run)`/`fetch(run)` block until it is finished.

# Keyword arguments
- `setups` — the `TestSetupDetail`s the items may reference; defaults to the discovery's.
- `profiles::Vector{RunProfile}` — every item runs once per profile (default: one
  `RunProfile("Default")`).
- `max_workers::Int` — maximum number of parallel test processes for this run.
- `timeout` — per-test-item timeout in seconds, or `nothing`.
- `julia_cmd`, `julia_args`, `julia_num_threads`, `check_bounds` — how to launch test
  processes (per-profile fields override these). `julia_num_threads` is the `--threads`
  value (`"4"`, `"auto"`, `"4,1"`); `check_bounds` is `nothing`/`"auto"` or `"yes"`.
- `gc_between_testitems::Union{Nothing,Bool}` — `nothing` (default) turns it on when more
  than one test process is used.
- `memory_threshold::Union{Nothing,Float64}` — recycle a test process once system memory
  use exceeds this fraction.
- `fail_on_definition_error::Bool` — when `true` (default) and the discovery has
  definition errors, nothing runs; the errors are reported in the result either way.
- `failfast::Bool` — stop the run at the first failing or errored item; the rest are
  reported as skipped and the run still finishes with `status == :completed`, see
  [`stop_reason`](@ref).
- `log_level::Symbol` — minimum log level for the *code under test* (`:Debug`, `:Info`
  (default), `:Warn` or `:Error`). Unrelated to `log_min_level`, which is about this
  package's own logging.
- `coverage_source_subdirs` — which folders of a package coverage is reported for
  (default `("src", "ext")`, so a package's own `test/` is not counted as covered
  source). An empty collection instruments the whole package folder.
- `token` — a `CancellationToken` from a caller-owned source; [`cancel!`](@ref) works too.
- `on_event` — an event sink for this run (see [`subscribe!`](@ref)).
- `id` — the run id (default: a fresh UUID); must be unique within the session.
- `metadata::Dict{String,Any}` — stored on the run untouched.
"""
function run_async!(session::TestSession, testitems;
        setups=nothing,
        profiles::Vector{RunProfile}=[RunProfile()],
        max_workers::Int=DEFAULT_MAX_WORKERS,
        timeout=nothing,
        julia_cmd::String="julia",
        julia_args::Vector{String}=String[],
        julia_num_threads::Union{Nothing,String}=nothing,
        check_bounds::Union{Nothing,String}=nothing,
        gc_between_testitems::Union{Nothing,Bool}=nothing,
        memory_threshold::Union{Nothing,Float64}=nothing,
        fail_on_definition_error::Bool=true,
        failfast::Bool=false,
        log_level::Symbol=:Info,
        coverage_source_subdirs=COVERAGE_SOURCE_SUBDIRS,
        token::Union{Nothing,CancellationToken}=nothing,
        on_event=nothing,
        id::String=string(UUIDs.uuid4()),
        metadata::Dict{String,Any}=Dict{String,Any}(),
    )
    session.closed && throw(ArgumentError("the session is closed"))
    max_workers >= 1 || throw(ArgumentError("max_workers must be at least 1"))
    isempty(profiles) && throw(ArgumentError("at least one profile is required"))
    length(unique(p.name for p in profiles)) == length(profiles) ||
        throw(ArgumentError("profile names must be unique"))
    log_level in (:Debug, :Info, :Warn, :Error) ||
        throw(ArgumentError("log_level must be :Debug, :Info, :Warn or :Error"))

    items = testitems isa Discovery ? testitems.testitems : collect(TestItem, testitems)
    setups = setups === nothing ? (testitems isa Discovery ? testitems.setups : TestItemControllers.TestSetupDetail[]) :
        collect(TestItemControllers.TestSetupDetail, setups)
    definition_errors = testitems isa Discovery ? testitems.definition_errors : DefinitionError[]

    if fail_on_definition_error && !isempty(definition_errors)
        items = TestItem[]
    end

    # Test items are addressed by (id, package_uri); a duplicate is one item listed twice.
    items_by_key = Dict{Tuple{String,String},TestItem}()
    unique_items = TestItem[]
    for i in items
        haskey(items_by_key, key(i)) && continue
        items_by_key[key(i)] = i
        push!(unique_items, i)
    end
    items = unique_items

    params = (; profiles, max_workers, timeout, julia_cmd, julia_args, julia_num_threads, check_bounds,
        gc_between_testitems, memory_threshold, fail_on_definition_error, failfast, log_level,
        coverage_source_subdirs)

    # ── Translation to controller types ───────────────────────────────
    test_envs = TestItemControllers.TestEnvironment[]
    env_info = Dict{String,EnvInfo}()
    work_units = TestItemControllers.TestRunItem[]
    item_timeout = timeout === nothing ? nothing : Float64(timeout)
    pkgs = packages(items)
    for profile in profiles
        env_vars = _child_env(profile)
        mode = profile.coverage ? "Coverage" : "Normal"
        for pkg in pkgs
            env = TestItemControllers.TestEnvironment(
                string(UUIDs.uuid4()),
                _or(profile.julia_cmd, julia_cmd),
                _or(profile.julia_args, julia_args),
                _or(profile.julia_num_threads, julia_num_threads),
                env_vars,
                mode,
                pkg.package_name,
                pkg.package_uri,
                pkg.project_uri,
                pkg.env_content_hash,
                _or(profile.check_bounds, check_bounds),
            )
            push!(test_envs, env)
            env_info[env.id] = EnvInfo(profile.name, pkg.package_name, pkg.package_uri, pkg.project_uri)
            for i in items
                i.package_uri == pkg.package_uri || continue
                push!(work_units, TestItemControllers.TestRunItem(i.id, env.id, item_timeout, log_level))
            end
        end
    end

    # Coverage instrumentation is harvested per test item, but only for files under these
    # roots — without them the test process has nothing to filter against and collects
    # nothing at all.
    #
    # `package_uri` is the folder holding Project.toml, so naming the source folders
    # explicitly is what keeps a package's own `test/` out of the report. Plain
    # concatenation, not `joinpath`: these are URIs, and `src`/`ext` need no escaping. A
    # root naming a folder that does not exist simply matches nothing.
    coverage_root_uris = if !any(p.coverage for p in profiles)
        nothing
    elseif isempty(coverage_source_subdirs)
        String[p.package_uri for p in pkgs if !isempty(p.package_uri)]
    else
        String[string(p.package_uri, '/', sub) for p in pkgs for sub in coverage_source_subdirs
               if !isempty(p.package_uri)]
    end

    state = RunState(definition_errors, length(work_units))
    merge!(state.items_by_key, items_by_key)
    merge!(state.env_info, env_info)
    for (n, i) in enumerate(items)
        state.item_order[key(i)] = n
    end
    for (n, p) in enumerate(profiles)
        state.profile_order[p.name] = n
    end

    cts = token === nothing ? CancellationTokenSource() : CancellationTokenSource(token)
    run = TestRun(id, session, items, profiles, params, metadata, Dates.now(), nothing, :running, nothing, nothing,
        cts, nothing, failfast, nothing, token, state, Channel{RunEvent}(Inf), Any[], nothing, Threads.Event())
    on_event === nothing || push!(run.sinks, on_event)

    lock(session.lock) do
        haskey(session.runs, id) && throw(ArgumentError("a run with id '$id' already exists in this session"))
        session.runs[id] = run
        push!(session.history, run)
        merge!(session.env_info, env_info)
        _prune_history!(session)
    end

    run.drain_task = @async _drain(run.events, run.sinks, session.lock)
    _emit_run!(session, run, RunStarted(run, length(items), length(work_units), length(profiles)))

    details = TestItemControllers.TestItemDetail[i.detail for i in items]
    run.task = Threads.@spawn _execute_run!(session, run, test_envs, details, work_units, setups, max_workers,
        coverage_root_uris, gc_between_testitems, memory_threshold)
    return run
end

function _execute_run!(session::TestSession, run::TestRun, test_envs, details, work_units, setups, max_workers,
                       coverage_root_uris, gc_between_testitems, memory_threshold)
    coverage = nothing
    err = nothing
    try
        try
            if !isempty(work_units)
                coverage = execute_testrun(session.controller, run.id, test_envs, details, work_units, setups,
                    max_workers, get_token(run.cts);
                    coverage_root_uris=coverage_root_uris,
                    gc_between_testitems=gc_between_testitems,
                    memory_threshold=memory_threshold,
                    failfast=run.failfast)
            end
        catch e
            err = e
            @debug "TestItemRuns: run errored" run_id = run.id exception = (e, catch_backtrace())
        end
        lock(session.lock) do
            run.state.coverage = coverage
            run.error = err
            run.status = _final_status(run, err)
            run.result = assemble_result(run.state)
            run.finished_at = Dates.now()
            _prune_history!(session)
        end
        _emit_run!(session, run, RunFinished(run, run.status, run.result))
    finally
        # `wait`/`fetch` must not return before every sink — the run's and the session's —
        # has seen `RunFinished`.
        close(run.events)
        run.drain_task === nothing || wait(run.drain_task)
        _flush!(session.events)
        notify(run.done)
    end
    return nothing
end

# A failfast run is cancelled underneath, but it stopped because the tests failed, not
# because anyone interrupted it — reporting `:cancelled` would make a CLI that maps
# cancellation to exit 130 mask an ordinary test failure. An outside cancellation still
# wins: if the caller's own token is cancelled, that is what happened, whatever else did.
# Called with the session lock held.
function _final_status(run::TestRun, err)
    err !== nothing && return :errored
    is_cancellation_requested(get_token(run.cts)) || return :completed
    externally_cancelled = run.external_token !== nothing && is_cancellation_requested(run.external_token)
    (run.stop_reason === :failfast && !externally_cancelled) && return :completed
    # A caller token cancelled from the outside never went through `_request_stop!`.
    run.stop_reason = :user
    return :cancelled
end

function _prune_history!(session::TestSession)
    session.max_history === nothing && return
    finished = [r for r in session.history if r.status !== :running]
    excess = length(finished) - session.max_history
    excess <= 0 && return
    for r in finished[1:excess]
        delete!(session.runs, r.id)
    end
    Base.filter!(r -> haskey(session.runs, r.id), session.history)
    return nothing
end

"""
    run!(session, testitems; kwargs...) -> TestrunResult

Run `testitems` on `session` and block until finished; see [`run_async!`](@ref) for the
keyword arguments. Returns the [`TestrunResult`](@ref) (partial when cancelled); rethrows
when the run errored.
"""
run!(session::TestSession, testitems; kwargs...) = fetch(run_async!(session, testitems; kwargs...))

Base.wait(run::TestRun) = (wait(run.done); nothing)

function Base.fetch(run::TestRun)
    wait(run.done)
    run.error === nothing || throw(run.error)
    return run.result
end

Base.istaskdone(run::TestRun) = run.status !== :running

"""
    cancel!(run::TestRun)

Request cancellation. Items not yet started are reported as skipped, running processes are
killed, and the run finishes normally with `status == :cancelled` and a partial result.
"""
cancel!(run::TestRun) = _request_stop!(run, :user)

"""
    stop_reason(run::TestRun) -> Union{Nothing,Symbol}

Why the run stopped early: `:user` (a [`cancel!`](@ref) or a cancelled caller token),
`:failfast` (a failing item under `failfast=true`), or `nothing` when it ran to completion.

A failfast run is *cancelled* underneath — items that never started are reported as
skipped — but its `status` is `:completed`, so a CLI can keep mapping `:cancelled` to
"the user interrupted this" and a failfast run to an ordinary test failure.
"""
stop_reason(run::TestRun) = run.stop_reason

"""
    iscancelled(run::TestRun) -> Bool
"""
iscancelled(run::TestRun) = is_cancellation_requested(get_token(run.cts))

"""
    run_progress(run::TestRun) -> (; total, done, passed, failed, errored, skipped)

Live counters of a run; `total` is the number of (item, profile) units.
"""
function run_progress(run::TestRun)
    lock(run.session.lock) do
        s = run.state
        (; total=s.n_total, done=_done(s), passed=s.passed, failed=s.failed, errored=s.errored, skipped=s.skipped)
    end
end

"""
    snapshot(run::TestRun) -> TestrunResult

The result so far — usable while the run is in flight. Once finished this is `run.result`.
"""
function snapshot(run::TestRun)
    lock(run.session.lock) do
        run.result === nothing ? assemble_result(run.state) : run.result
    end
end

"""
    list_runs(session) -> Vector{TestRun}

All runs the session remembers, newest first (running runs are never pruned).
"""
list_runs(session::TestSession) = lock(session.lock) do
    reverse(session.history)
end

"""
    get_run(session, id) -> Union{TestRun,Nothing}

Look up a run by id or unique id prefix; `nothing` when unknown, `ArgumentError` when the
prefix is ambiguous.
"""
function get_run(session::TestSession, id::AbstractString)
    lock(session.lock) do
        r = get(session.runs, id, nothing)
        r === nothing || return r
        matches = [r for r in session.history if startswith(r.id, id)]
        isempty(matches) && return nothing
        length(matches) == 1 && return matches[1]
        throw(ArgumentError("run id prefix '$id' is ambiguous"))
    end
end

"""
    list_processes(session) -> Vector{ProcessInfo}

The test processes currently alive (pooled idle ones included), oldest first.
"""
list_processes(session::TestSession) = lock(session.lock) do
    sort!(collect(values(session.processes)); by=p -> p.created_at)
end

"""
    terminate_process!(session, id)

Kill one test process. If it is running a test item, that item is reported as errored.
"""
terminate_process!(session::TestSession, id::AbstractString) = (terminate_test_process(session.controller, String(id)); nothing)

"""
    terminate_all_processes!(session)

Kill every test process while keeping the session usable; the next run launches fresh ones.
"""
function terminate_all_processes!(session::TestSession)
    ids = lock(session.lock) do
        collect(keys(session.processes))
    end
    for id in ids
        terminate_test_process(session.controller, id)
    end
    return nothing
end

"""
    process_output(session, id) -> String

Everything a test process wrote outside of test items so far.
"""
process_output(session::TestSession, id::AbstractString) = lock(session.lock) do
    join(get(session.process_outputs, id, String[]))
end

"""
    close(session::TestSession)

Cancel active runs, shut every test process down and stop the reactor. Idempotent.
"""
function Base.close(session::TestSession)
    active = lock(session.lock) do
        session.closed && return nothing
        session.closed = true
        TestRun[r for r in values(session.runs) if r.status === :running]
    end
    active === nothing && return nothing
    for r in active
        cancel!(r)
    end
    for r in active
        wait(r)
    end
    shutdown(session.controller)
    wait_for_shutdown(session.controller, session.reactor_task)
    close(session.events)
    session.drain_task === nothing || wait(session.drain_task)
    return nothing
end
