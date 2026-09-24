@testitem "session reuses processes across runs" setup=[Fixtures] begin
    d = discover_testitems(Fixtures.APP_PKG)
    session = TestSession()
    try
        @test isopen(session)
        @test isempty(list_runs(session))
        @test isempty(list_processes(session))

        r1 = run!(session, d; Fixtures.RUN_KW...)
        @test Fixtures.status_of(r1, "passing item") == :passed
        procs1 = list_processes(session)
        @test !isempty(procs1)   # pooled, idle
        @test all(p.package_name == "AppTestPkg" for p in procs1)
        @test all(p.profile == "Default" for p in procs1)

        r2 = run!(session, d; Fixtures.RUN_KW...)
        @test Fixtures.status_of(r2, "failing item") == :failed
        procs2 = list_processes(session)
        @test Set(p.id for p in procs2) == Set(p.id for p in procs1)   # same processes, revised

        runs = list_runs(session)
        @test length(runs) == 2
        @test runs[1].started_at >= runs[2].started_at   # newest first
        @test all(r.status == :completed for r in runs)
        @test all(r.result !== nothing for r in runs)
        @test all(r.finished_at !== nothing for r in runs)
        @test get_run(session, runs[1].id) === runs[1]
        @test get_run(session, first(runs[1].id, 8)) === runs[1]
        @test get_run(session, "no-such-run") === nothing
        @test runs[1].params.max_workers == default_max_workers()
        @test runs[1].params.timeout == 300
        @test occursin("completed", sprint(show, runs[1]))
        @test occursin("2 runs", sprint(show, session))

        # Process output was captured.
        @test any(!isempty(process_output(session, p.id)) for p in procs2)
    finally
        close(session)
    end
    @test !isopen(session)
    close(session)   # idempotent
    @test_throws ArgumentError run_async!(session, d)
end

@testitem "run_async!, run_progress, snapshot and cancel!" setup=[Fixtures] begin
    d = discover_testitems(Fixtures.SLOW_PKG)
    session = TestSession()
    try
        started = Channel{String}(Inf)
        run = run_async!(session, d; max_workers=1, Fixtures.RUN_KW...,
            metadata=Dict{String,Any}("path" => Fixtures.SLOW_PKG),
            on_event = ev -> ev isa TestItemStarted && put!(started, ev.item.name))
        @test run isa TestRun
        @test run.status == :running
        @test !istaskdone(run)
        @test run.metadata["path"] == Fixtures.SLOW_PKG
        @test get_run(session, run.id) === run
        p = run_progress(run)
        @test p.total == 2 && p.done == 0

        # Wait until the slow item is executing, then cancel.
        names = String[]
        while !("slow item" in names)
            push!(names, take!(started))
        end
        # `quick item` may or may not have finished by now depending on scheduling; the
        # snapshot must work either way.
        snap = snapshot(run)
        @test snap isa TestrunResult
        @test !iscancelled(run)
        cancel!(run)
        @test iscancelled(run)
        result = fetch(run)
        @test run.status == :cancelled
        @test istaskdone(run)
        @test run.result === result
        @test snapshot(run) === result
        s = Fixtures.statuses(result)
        @test s["slow item"] == [:errored] || s["slow item"] == [:skipped]
        p = run_progress(run)
        @test p.done == p.total == 2
    finally
        close(session)
    end
end

@testitem "subscribe! and unsubscribe! while a run is in flight" setup=[Fixtures] begin
    d = discover_testitems(Fixtures.SLOW_PKG)
    session = TestSession()
    try
        started = Channel{Any}(Inf)
        run = run_async!(session, d; max_workers=1, Fixtures.RUN_KW..., on_event = ev -> put!(started, ev))
        # Wait for the slow item to start, then attach a second sink.
        while true
            ev = take!(started)
            ev isa TestItemStarted && ev.item.name == "slow item" && break
        end
        late = RunEvent[]
        sink = ev -> push!(late, ev)
        subscribe!(run, sink)
        cancel!(run)
        wait(run)
        @test any(e -> e isa RunFinished, late)
        @test !any(e -> e isa RunStarted, late)   # attached after the start
        unsubscribe!(run, sink)
        @test length(run.sinks) == 1   # only the original on_event sink remains
    finally
        close(session)
    end
end

@testitem "terminate_process! and terminate_all_processes!" setup=[Fixtures] begin
    d = discover_testitems(Fixtures.APP_PKG)
    session = TestSession()
    try
        run!(session, d; Fixtures.RUN_KW...)
        procs = list_processes(session)
        @test !isempty(procs)
        terminated = Channel{String}(Inf)
        subscribe!(session, ev -> ev isa ProcessTerminated && put!(terminated, ev.id))
        terminate_process!(session, procs[1].id)
        @test take!(terminated) == procs[1].id
        @test !any(p.id == procs[1].id for p in list_processes(session))

        run!(session, d; Fixtures.RUN_KW...)   # relaunches what it needs
        @test !isempty(list_processes(session))
        terminate_all_processes!(session)
        while !isempty(list_processes(session))
            take!(terminated)
        end
        @test isempty(list_processes(session))
        # The session is still usable.
        r = run!(session, select(d; names=["passing item"]); Fixtures.RUN_KW...)
        @test Fixtures.status_of(r, "passing item") == :passed
    finally
        close(session)
    end
end

@testitem "concurrent runs do not cross-contaminate" setup=[Fixtures] begin
    d_app = discover_testitems(Fixtures.APP_PKG)
    d_skip = discover_testitems(Fixtures.SKIP_PKG)
    session = TestSession()
    try
        r1 = run_async!(session, d_app; Fixtures.RUN_KW...)
        r2 = run_async!(session, d_skip; Fixtures.RUN_KW...)
        res1 = fetch(r1)
        res2 = fetch(r2)
        @test Set(t.name for t in res1.testitems) == Set(["passing item", "failing item"])
        @test Set(t.name for t in res2.testitems) == Set(["skipped by literal", "skipped by expression", "not skipped"])
        @test length(list_runs(session)) == 2
        @test_throws ArgumentError run_async!(session, d_app; id=r1.id)
    finally
        close(session)
    end
end

@testitem "history is pruned to max_history" setup=[Fixtures] begin
    d = discover_testitems(Fixtures.APP_PKG; filter = i -> i.name == "passing item")
    session = TestSession(; max_history=2)
    try
        ids = [run_async!(session, d; Fixtures.RUN_KW...) |> r -> (wait(r); r.id) for _ in 1:3]
        runs = list_runs(session)
        @test length(runs) == 2
        @test [r.id for r in runs] == reverse(ids[2:3])
        @test get_run(session, ids[1]) === nothing
    finally
        close(session)
    end
end

@testitem "close cancels active runs" setup=[Fixtures] begin
    d = discover_testitems(Fixtures.SLOW_PKG; filter = i -> i.name == "slow item")
    session = TestSession()
    started = Channel{Any}(Inf)
    run = run_async!(session, d; Fixtures.RUN_KW..., on_event = ev -> ev isa TestItemStarted && put!(started, ev))
    take!(started)
    close(session)
    @test run.status == :cancelled
    @test istaskdone(run)
end

@testitem "run_async! options" setup=[Fixtures] begin
    d = discover_testitems(Fixtures.APP_PKG)
    session = TestSession(; schedule=:contiguous, reactor_pool=:interactive)
    try
        r = run!(session, d; gc_between_testitems=true, memory_threshold=1.0,
            julia_num_threads="1", check_bounds="auto", Fixtures.RUN_KW...)
        @test length(r.testitems) == 2
        # A vector of items works as well as a Discovery.
        r = run!(session, [d[1]]; setups=d.setups, Fixtures.RUN_KW...)
        @test [t.name for t in r.testitems] == ["passing item"]
        # An empty selection completes immediately.
        r = run!(session, TestItem[]; Fixtures.RUN_KW...)
        @test isempty(r.testitems)
    finally
        close(session)
    end
    @test_throws ArgumentError TestSession(; schedule=:random)
    @test_throws ArgumentError TestSession(; reactor_pool=:default)
end

@testitem "session sinks have seen RunFinished when fetch returns" setup=[Fixtures] begin
    d = discover_testitems(Fixtures.APP_PKG; filter = i -> i.name == "passing item")
    seen = RunEvent[]
    session = TestSession(; on_event = ev -> push!(seen, ev))
    try
        for _ in 1:3
            r = run!(session, d; Fixtures.RUN_KW...)
            # No sleeping, no polling: the guarantee is that this already holds.
            @test any(e -> e isa RunFinished && e.result === r, seen)
        end
    finally
        close(session)
    end
end

@testitem "failfast stops the run at the first failure" setup=[Fixtures] begin
    d = discover_testitems(Fixtures.FAILFAST_PKG)
    session = TestSession()
    try
        # Every item in the fixture fails, so "the first to run fails, the rest are
        # skipped" holds whichever order the controller picks.
        run = run_async!(session, d; failfast=true, max_workers=1, Fixtures.RUN_KW...)
        result = fetch(run)
        st = [p.status for t in result.testitems for p in t.profiles]
        @test count(==(:failed), st) == 1
        @test count(==(:skipped), st) == 2
        # Cancelled underneath, but reported as a completed run: a failfast stop is a test
        # failure, not a user interruption.
        @test run.status == :completed
        @test stop_reason(run) === :failfast
        @test iscancelled(run)
    finally
        close(session)
    end
end

@testitem "failfast off runs every item" setup=[Fixtures] begin
    d = discover_testitems(Fixtures.FAILFAST_PKG)
    session = TestSession()
    try
        run = run_async!(session, d; max_workers=1, Fixtures.RUN_KW...)
        result = fetch(run)
        @test all(p.status == :failed for t in result.testitems for p in t.profiles)
        @test length(result.testitems) == 3
        @test run.status == :completed
        @test stop_reason(run) === nothing
        @test !iscancelled(run)
    finally
        close(session)
    end
end

@testitem "failfast leaves a caller token alone, a cancelled one wins" setup=[Fixtures] begin
    using TestItemRuns.CancellationTokens: CancellationTokenSource, get_token, cancel,
        is_cancellation_requested

    session = TestSession()
    try
        # Failfast cancels the run, which is linked to the caller's token — it must not
        # cancel the caller's source, which the caller may be using for other runs too.
        cts = CancellationTokenSource()
        run = run_async!(session, discover_testitems(Fixtures.FAILFAST_PKG);
            failfast=true, max_workers=1, token=get_token(cts), Fixtures.RUN_KW...)
        fetch(run)
        @test stop_reason(run) === :failfast
        @test run.status == :completed
        @test !is_cancellation_requested(get_token(cts))

        # An outside cancellation wins over failfast: this run stopped because the caller
        # said so, so it must report :cancelled and exit codes stay meaningful.
        cts2 = CancellationTokenSource()
        cancel(cts2)
        run2 = run_async!(session, discover_testitems(Fixtures.FAILFAST_PKG);
            failfast=true, token=get_token(cts2), Fixtures.RUN_KW...)
        fetch(run2)
        @test run2.status == :cancelled
        @test stop_reason(run2) === :user
    finally
        close(session)
    end
end

@testitem "log_level reaches the code under test" setup=[Fixtures] begin
    d = discover_testitems(Fixtures.LOGLEVEL_PKG)
    session = TestSession()
    try
        output = (level) -> begin
            chunks = String[]
            run!(session, d; log_level=level, on_event = ev -> ev isa OutputAppended && push!(chunks, ev.output),
                Fixtures.RUN_KW...)
            join(chunks)
        end
        @test occursin("LogLevelPkg computing a sum", output(:Debug))
        @test !occursin("LogLevelPkg computing a sum", output(:Info))
    finally
        close(session)
    end
end

@testitem "coverage is reported for src, not test" setup=[Fixtures] begin
    d = discover_testitems(Fixtures.APP_PKG)
    session = TestSession()
    try
        result = run!(session, d; profiles=[RunProfile("cov"; coverage=true)], Fixtures.RUN_KW...)
        @test result.coverage !== nothing
        uris = [f.uri for f in result.coverage]
        @test any(occursin("/src/", u) for u in uris)
        # The regression this guards: a package's own test files counted as covered source.
        @test !any(occursin("/test/", u) for u in uris)
    finally
        close(session)
    end
end

@testitem "run params round-trip the new options" setup=[Fixtures] begin
    d = discover_testitems(Fixtures.APP_PKG)
    session = TestSession()
    try
        run = run_async!(session, d; failfast=false, log_level=:Warn,
            coverage_source_subdirs=("src",), Fixtures.RUN_KW...)
        fetch(run)
        @test run.params.failfast == false
        @test run.params.log_level == :Warn
        @test run.params.coverage_source_subdirs == ("src",)
        # Every kwarg in `params` must be accepted back by `run_async!`.
        fetch(run_async!(session, d; run.params...))
    finally
        close(session)
    end
end

@testitem "log_level and activation_timeout_seconds are validated" setup=[Fixtures] begin
    d = discover_testitems(Fixtures.APP_PKG)
    session = TestSession()
    try
        @test_throws ArgumentError run_async!(session, d; log_level=:Verbose)
    finally
        close(session)
    end
    @test_throws ArgumentError TestSession(; activation_timeout_seconds=0)
end
