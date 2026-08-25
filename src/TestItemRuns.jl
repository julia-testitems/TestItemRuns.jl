"""
    TestItemRuns

The public Julia API for discovering and running `@testitem`s.

Discovery is done by JuliaWorkspaces, execution by TestItemControllers; this package
glues the two together and adds run/process/result management on top.

Two tiers:

- **One call:** [`run_tests`](@ref) discovers everything under a path, runs it and returns
  a [`TestrunResult`](@ref). Silent by default; pass `on_event` to observe progress.
- **Fine-grained:** [`discover_testitems`](@ref) → [`Discovery`](@ref) (list, `filter`,
  [`select`](@ref)), a long-lived [`TestSession`](@ref) with a reusable pool of test
  processes, [`run_async!`](@ref)/[`run!`](@ref) returning a [`TestRun`](@ref),
  [`cancel!`](@ref), [`snapshot`](@ref), [`run_progress`](@ref), and process management
  ([`list_processes`](@ref), [`terminate_process!`](@ref), [`process_output`](@ref)).

Every session function also has a session-less form that operates on a process-wide
[`default_session`](@ref), created on first use, so nothing has to be built to run tests
or manage test processes from a REPL:

```julia
run_tests(".")             # discovers, runs, and leaves its test processes warm
list_processes()
run!(select(discover_testitems(); tags=[:quick]))
terminate_all_processes!()
```

Applications should own an explicit `TestSession` and pass it — `run_tests(session, path)`,
`run!(session, items)` — rather than share the default one.
"""
module TestItemRuns

import JuliaWorkspaces, TestItemControllers, UUIDs, Dates, Logging

using TestItemControllers: TestItemController, ControllerCallbacks, execute_testrun,
    shutdown, wait_for_shutdown, terminate_test_process
using TestItemControllers.Results
using TestItemControllers.Results: write_json, read_json
using TestItemControllers: write_junit_xml, write_lcov

"""
The `CancellationTokens` module used throughout (the one vendored by TestItemControllers,
so tokens are interchangeable with every other consumer of that package).
"""
const CancellationTokens = TestItemControllers.CancellationTokens
using .CancellationTokens: CancellationTokenSource, CancellationToken, get_token,
    is_cancellation_requested, cancel

# Re-exported result types and writers from TestItemControllers.
export TestrunResult, TestrunResultTestitem, TestrunResultTestitemProfile,
    TestrunResultMessage, TestrunResultStackFrame, TestrunResultDefinitionError,
    TestrunResultPerfStats, TestrunResultFileCoverage
export write_json, read_json, write_junit_xml, write_lcov

# Profiles and discovery.
export RunProfile, TestItem, DefinitionError, Discovery, discover_testitems, select,
    filename, package_envs, packages
# Events.
export RunEvent, DiscoveryFinished, RunStarted, TestItemStarted, TestItemFinished,
    OutputAppended, ProcessCreated, ProcessStatusChanged, ProcessTerminated, ProcessOutput,
    RunFinished
# Session and runs.
export TestSession, TestRun, ProcessInfo, run_async!, run!, cancel!, iscancelled, snapshot,
    run_progress, stop_reason, subscribe!, unsubscribe!, list_runs, get_run, list_processes,
    terminate_process!, terminate_all_processes!, process_output
# The default session behind the session-less methods.
export default_session, has_default_session, set_default_session!, close_default_session!
# One-shot.
export run_tests

const DEFAULT_MAX_WORKERS = min(Sys.CPU_THREADS, 8)

# The folders of a package whose coverage a report is about. Everything else under the
# package — `test`, `docs`, loose scripts — is instrumented too, but reporting it would
# count a package's own test files as covered source.
const COVERAGE_SOURCE_SUBDIRS = ("src", "ext")

include("profiles.jl")
include("discovery.jl")
include("events.jl")
include("results.jl")
include("session.jl")
include("default_session.jl")
include("run.jl")

end # module TestItemRuns
