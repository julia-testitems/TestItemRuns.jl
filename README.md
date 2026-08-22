# TestItemRuns.jl

The public Julia API for discovering and running `@testitem`s.

Discovery is done by [JuliaWorkspaces](https://github.com/julia-vscode/JuliaWorkspaces.jl),
execution by [TestItemControllers](https://github.com/julia-testitems/TestItemControllers.jl)
(isolated, reusable test processes with parallelism, per-item timeouts, coverage and
cancellation). TestItemRuns glues the two together and adds run, process and result
management on top. It prints nothing by itself — front ends such as the
[`juliati`](https://github.com/julia-testitems/TestItemApp.jl) CLI, DevREPL and JuliaMCP
render its event stream.

## One call

```julia
using TestItemRuns

result = run_tests("path/to/MyPackage"; max_workers=4, timeout=600)

for t in result.testitems, p in t.profiles
    println(t.name, " → ", p.status)
end

write_json("results.json", result)
write_junit_xml("junit.xml", result; root=abspath("path/to/MyPackage"))
```

`run_tests` discovers every test item under the path, runs them and returns a
`TestrunResult` (the `TestItemControllers.Results` type; `write_json`/`read_json`,
`write_junit_xml` and `write_lcov` are re-exported).

The run happens on the [default session](#the-default-session), whose test processes stay
alive afterwards, so a second `run_tests` of the same package reuses them. An application
that wants to own that lifetime passes its own session, which `run_tests` never closes:

```julia
session = TestSession(; activation_timeout_seconds=300)
try
    result = run_tests(session, "path/to/MyPackage")
finally
    close(session)
end
```

Keyword arguments: `filter` (a `TestItem -> Bool`), `profiles`, `max_workers`, `timeout`
(seconds per item), `julia_cmd`, `julia_args`, `julia_num_threads`, `check_bounds`,
`gc_between_testitems`, `memory_threshold`, `schedule`, `fail_on_definition_error`,
`failfast`, `log_level` (for the code under test), `coverage_source_subdirs`,
`activation_timeout_seconds`, `shutdown_grace_seconds`, `token` (a `CancellationToken`),
`on_event`, `log_min_level`, `store_path`, `active_project`.

`failfast=true` stops at the first failing item and reports the rest as skipped. The run
still finishes with `status == :completed` — `stop_reason(run)` is `:failfast` — so a
front end can keep treating `:cancelled` as "the user interrupted this".

## Discovery

```julia
d = discover_testitems("path/to/MyPackage")      # or a Vector of paths, or a JuliaWorkspace
d.testitems                                        # Vector{TestItem}
d.setups                                           # @testmodule / @testsnippet definitions
d.definition_errors                                # items that could not be parsed

for item in d
    item.name, item.filename, item.line, item.tags, item.package_name, item.id, item.skip
end

quick = select(d; tags=[:quick], file_pattern="test/unit")   # AND of every criterion
mine  = filter(i -> startswith(i.name, "parser"), d)
```

Ids are package-scoped, so `(item.id, item.package_uri)` — `TestItemRuns.key(item)` — is
what uniquely identifies an item.

`discover_testitems(jw::JuliaWorkspaces.JuliaWorkspace)` works on a workspace you own and
keep up to date yourself (the returned `Discovery` is a plain snapshot; the workspace is
not retained or locked).

## Profiles

A `RunProfile` is one named configuration; a run executes every item once per profile and
merges the results per item:

```julia
profiles = [
    RunProfile("default"),
    RunProfile("coverage"; coverage=true),
    RunProfile("nightly"; julia_cmd="julia +nightly", env=Dict("JULIA_DEBUG" => "MyPackage")),
]
run_tests("."; profiles)
```

`env` values of `nothing` remove a variable from the test process environment.
`JULIA_LOAD_PATH`, `JULIA_PROJECT` and `JULIA_DEPOT_PATH` are always cleared so test
processes resolve their own environment.

## Sessions

A `TestSession` owns a controller and a pool of test processes that stays alive across
runs — the second run of the same package revises the running processes instead of
launching new ones.

```julia
session = TestSession()

d = discover_testitems(".")
result = run!(session, d)                                  # blocking
run = run_async!(session, select(d; tags=[:slow]))         # returns a TestRun immediately

run_progress(run)      # (; total, done, passed, failed, errored, skipped)
snapshot(run)          # partial TestrunResult while it is in flight
cancel!(run)           # remaining items are skipped, processes killed, status == :cancelled
result = fetch(run)    # or wait(run)

list_runs(session)     # newest first
get_run(session, "3f2a")            # by id or unique prefix
list_processes(session)             # ProcessInfo: id, package, profile, status, …
process_output(session, id)
terminate_process!(session, id)
terminate_all_processes!(session)   # keep the session, drop the pool

close(session)
```

`run_async!` accepts the same keyword arguments as `run_tests` (except discovery ones) plus
`setups`, `id`, `metadata` and `on_event`. `run.params` holds the settings for re-running.

## The default session

Every session function has a session-less form that operates on a process-wide
`default_session()`, created on first use — so a REPL needs no setup:

```julia
run_tests(".")                 # runs, and leaves its test processes warm
list_processes()               # the pool the next run will reuse
run!(select(discover_testitems(); tags=[:quick]))
list_runs()

terminate_all_processes!()     # drop the pool, keep the session
close_default_session!()       # shut it down (process exit does this too)
```

`run_async!`, `run!`, `list_runs`, `get_run`, `list_processes`, `terminate_process!`,
`terminate_all_processes!`, `process_output`, `subscribe!` and `unsubscribe!` all have
one. `set_default_session!(session)` installs a session you configured yourself and hands
back the previous one without closing it.

Because the session outlives each call, `run_tests` keyword arguments that configure a
*session* — `schedule`, `reactor_pool`, `log_min_level`, `activation_timeout_seconds`,
`shutdown_grace_seconds` — rebuild the default session when it was built with something
else, losing its warm processes. Passing one alongside an explicit session is an error.

Applications should own an explicit `TestSession` rather than share this one.

## Events

Pass `on_event` to `run_tests`, `TestSession` or `run_async!`, or `subscribe!(run_or_session, f)`
at any time. Every event is a small struct:

| Event | When |
|---|---|
| `DiscoveryFinished(discovery)` | `run_tests` only, before running |
| `RunStarted(run, n_items, n_units, n_profiles)` | first event of a run |
| `TestItemStarted(run, item, profile)` | |
| `OutputAppended(run, item, profile, output)` | live output of an item |
| `TestItemFinished(run, item, profile, status, duration, messages, perf, skip_reason)` | terminal event per (item, profile) |
| `ProcessCreated` / `ProcessStatusChanged` / `ProcessTerminated` / `ProcessOutput` | test process lifecycle (session-scoped) |
| `RunFinished(run, status, result)` | last event; `status` is `:completed`, `:cancelled` or `:errored` |

Events are delivered off the controller's reactor task, in order per sink; a slow sink
delays only its own delivery.

## Cancellation

```julia
using TestItemRuns.CancellationTokens
cts = CancellationTokenSource()
@async (sleep(30); cancel(cts))
result = run_tests("."; token=get_token(cts))     # returns normally with the partial result
```

`TestItemRuns.CancellationTokens` is the module TestItemControllers vendors, so tokens are
interchangeable with every other consumer of that package.

## Related packages

- **TestItemApp** (`juliati`) — the CLI; a thin front end over `run_tests` with progress bar,
  console reporting and result files.
- **DevREPL**, **JuliaMCP** — interactive front ends built on the session API.
- **TestItemRunner** — runs test items in-process from `test/runtests.jl`; no worker
  processes, no JuliaWorkspaces. Use it inside `Pkg.test`, use TestItemRuns everywhere else.
