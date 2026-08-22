# default_session.jl — the simple tier: a process-wide session so a REPL user can run
# tests and manage test processes without owning a `TestSession`.

const _DEFAULT_SESSION = Ref{Union{Nothing,TestSession}}(nothing)
# The session-level settings the current default session was built with, so `run_tests`
# can tell when it is being asked for a session it cannot serve.
const _DEFAULT_SESSION_CONFIG = Ref{Any}(nothing)
const _DEFAULT_SESSION_LOCK = ReentrantLock()
const _ATEXIT_REGISTERED = Ref(false)

# What a default session may be configured with. `reactor_pool = :interactive` keeps the
# controller's reactor scheduled while user code saturates the default thread pool, which
# is what a REPL host needs; `log_min_level = Warn` hides the controller's info-level
# lifecycle chatter, matching `run_tests`.
const _DEFAULT_SESSION_DEFAULTS = (; schedule = :duration, reactor_pool = :interactive,
    log_min_level = Logging.Warn, activation_timeout_seconds = nothing,
    shutdown_grace_seconds = nothing)

function _close_default_session_quietly()
    try
        s = _DEFAULT_SESSION[]
        s === nothing || close(s)
    catch
        # atexit hooks must not throw; a session that cannot be closed cleanly is not
        # worth failing the process over.
    end
    return nothing
end

# Assumes `_DEFAULT_SESSION_LOCK` is held.
function _new_default_session!(config)
    s = TestSession(; config...)
    _DEFAULT_SESSION[] = s
    _DEFAULT_SESSION_CONFIG[] = config
    if !_ATEXIT_REGISTERED[]
        _ATEXIT_REGISTERED[] = true
        atexit(_close_default_session_quietly)
    end
    return s
end

"""
    default_session() -> TestSession

The process-wide [`TestSession`](@ref) that the session-less methods operate on, created
on first use and reused afterwards — so its pool of test processes stays warm between
calls and a second run of the same package revises the running processes instead of
launching new ones.

```julia
using TestItemRuns
run_tests(".")             # the default session, created here
list_processes()           # still alive, ready for the next run
terminate_all_processes!()
```

It is created with `reactor_pool = :interactive` and `log_min_level = Logging.Warn`, and
is closed at process exit. [`close_default_session!`](@ref) closes it early; the next call
transparently creates a new one. Use [`set_default_session!`](@ref) to install a session
you configured yourself.

Applications should own an explicit `TestSession` rather than share this one.
"""
function default_session()
    lock(_DEFAULT_SESSION_LOCK) do
        s = _DEFAULT_SESSION[]
        (s !== nothing && isopen(s)) && return s
        return _new_default_session!(_DEFAULT_SESSION_DEFAULTS)
    end
end

"""
    has_default_session() -> Bool

Whether a default session exists and is open — without creating one, unlike
[`default_session`](@ref).
"""
function has_default_session()
    lock(_DEFAULT_SESSION_LOCK) do
        s = _DEFAULT_SESSION[]
        return s !== nothing && isopen(s)
    end
end

"""
    set_default_session!(session::TestSession) -> Union{Nothing,TestSession}

Make `session` the one [`default_session`](@ref) returns, and hand back the previous one
**without closing it** — whoever created it still owns it.
"""
function set_default_session!(session::TestSession)
    lock(_DEFAULT_SESSION_LOCK) do
        previous = _DEFAULT_SESSION[]
        _DEFAULT_SESSION[] = session
        # An externally built session's settings are unknown, so record something no
        # `run_tests` request can match: it must not silently reuse it for a run that
        # asked for particular session settings.
        _DEFAULT_SESSION_CONFIG[] = nothing
        return previous
    end
end

"""
    close_default_session!()

Close the default session, shutting its test processes down. Idempotent, and safe when
there is none: the next session-less call simply creates a fresh one.
"""
function close_default_session!()
    s = lock(_DEFAULT_SESSION_LOCK) do
        s = _DEFAULT_SESSION[]
        _DEFAULT_SESSION[] = nothing
        _DEFAULT_SESSION_CONFIG[] = nothing
        return s
    end
    s === nothing || close(s)
    return nothing
end

# Return a default session built with `config`, rebuilding the existing one when it was
# built with something else. Session-level settings are fixed when the controller is
# built, so there is no way to apply them to a session that already exists.
function _default_session_for(config)
    lock(_DEFAULT_SESSION_LOCK) do
        s = _DEFAULT_SESSION[]
        if s !== nothing && isopen(s)
            _DEFAULT_SESSION_CONFIG[] == config && return s
            close(s)
        end
        return _new_default_session!(config)
    end
end

"""
    run_async!(testitems; kwargs...) -> TestRun
    run!(testitems; kwargs...) -> TestrunResult
    list_runs() / get_run(id)
    list_processes() / terminate_process!(id) / terminate_all_processes!() / process_output(id)
    subscribe!(f) / unsubscribe!(f)

The session-less forms of the session API: each operates on [`default_session`](@ref).

```julia
run!(discover_testitems())      # everything under the current folder
list_processes()
```
"""
run_async!(testitems; kwargs...) = run_async!(default_session(), testitems; kwargs...)
run!(testitems; kwargs...) = run!(default_session(), testitems; kwargs...)
list_runs() = list_runs(default_session())
get_run(id::AbstractString) = get_run(default_session(), id)
list_processes() = list_processes(default_session())
terminate_process!(id::AbstractString) = terminate_process!(default_session(), id)
terminate_all_processes!() = terminate_all_processes!(default_session())
process_output(id::AbstractString) = process_output(default_session(), id)
subscribe!(f) = subscribe!(default_session(), f)
unsubscribe!(f) = unsubscribe!(default_session(), f)

# `subscribe!(session)` reads as "subscribe to this session" but would land on the
# session-less method above and register the session itself as an event sink, which then
# fails once per event. Catch the typo instead.
subscribe!(::TestSession) = throw(ArgumentError(
    "subscribe!(session, f) takes an event sink; subscribe!(f) uses the default session"))
unsubscribe!(::TestSession) = throw(ArgumentError(
    "unsubscribe!(session, f) takes an event sink; unsubscribe!(f) uses the default session"))
