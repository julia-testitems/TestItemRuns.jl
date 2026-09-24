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
using TestItemControllers: write_junit_xml, write_lcov, write_cobertura

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
export write_json, read_json, write_junit_xml, write_lcov, write_cobertura

# Profiles and discovery.
export RunProfile, TestItem, DefinitionError, Discovery, discover_testitems, select,
    filename, packages
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
# Defaults.
export default_max_workers

"""
Memory budgeted per test process by [`default_max_workers`](@ref), in bytes (3 GiB).
"""
const MEMORY_PER_WORKER = Int64(3) * 2^30  # Int64: 3 GiB overflows a 32-bit Int

"""
    default_max_workers(; total_memory=Sys.total_memory(), cpu_threads=Sys.CPU_THREADS) -> Int

The number of parallel test processes used when `max_workers` is not given: the smallest
of

- `cpu_threads`, the number of CPU threads,
- 8, and
- one process per 3 GiB of `total_memory`,

but at least 1.

Memory matters because each test process running a typical package's test suite, together
with the Julia processes it spawns, needs roughly 2–3 GB on Julia 1.12 and later, and
running out of memory (swapping or memory-compressor thrashing) is far slower than running
fewer processes. On a 3-CPU, 7 GiB machine such as GitHub's macOS arm64 runners this gives
2 rather than 3.

`Sys.total_memory()` respects cgroup memory limits, so containers get a value based on
the memory they may actually use. The value is computed when called, not when the package
is precompiled; the keyword arguments exist for testing.
"""
function default_max_workers(; total_memory::Integer=Sys.total_memory(),
        cpu_threads::Integer=Sys.CPU_THREADS)
    return Int(max(1, min(cpu_threads, 8, fld(total_memory, MEMORY_PER_WORKER))))
end

"""
Superseded by [`default_max_workers`](@ref) and no longer used as the default for
`max_workers`. Kept for backward compatibility (TestItemApp 1.3 references it); note that
its value is fixed when the package is precompiled and ignores available memory.
"""
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
