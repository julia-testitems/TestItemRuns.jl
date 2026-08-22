@testitem "event stream is ordered and complete" setup=[Fixtures] begin
    close_default_session!()
    events = RunEvent[]
    lk = ReentrantLock()
    sink = ev -> lock(() -> push!(events, ev), lk)
    result = run_tests(Fixtures.APP_PKG; Fixtures.RUN_KW..., on_event = sink)

    @test events[1] isa DiscoveryFinished
    @test length(events[1].discovery) == 2
    @test events[2] isa RunStarted
    @test events[2].n_items == 2 && events[2].n_units == 2 && events[2].n_profiles == 1
    # `RunFinished` is the last run-scoped event; only process teardown follows it.
    i_fin = findfirst(e -> e isa RunFinished, events)
    @test i_fin !== nothing
    fin = events[i_fin]
    @test fin.status == :completed
    @test fin.result === result   # the same object run_tests returns
    @test fin.run isa TestRun
    @test fin.run.status == :completed
    @test all(e isa Union{ProcessStatusChanged,ProcessTerminated,ProcessOutput} for e in events[i_fin+1:end])

    finished = [e for e in events if e isa TestItemFinished]
    @test length(finished) == 2
    @test Set(e.item.name for e in finished) == Set(["passing item", "failing item"])
    @test all(e.profile == "Default" for e in finished)
    f = only(e for e in finished if e.status == :failed)
    @test f.messages !== nothing && !isempty(f.messages)
    @test f.duration isa Float64
    p = only(e for e in finished if e.status == :passed)
    @test p.messages === nothing

    # Every item starts before it finishes and produces some output.
    for name in ("passing item", "failing item")
        i_start = findfirst(e -> e isa TestItemStarted && e.item.name == name, events)
        i_end = findfirst(e -> e isa TestItemFinished && e.item.name == name, events)
        @test i_start !== nothing && i_end !== nothing && i_start < i_end
        @test any(e -> e isa OutputAppended && e.item.name == name, events)
    end

    # Process lifecycle events are present and reference launched processes.
    created = [e for e in events if e isa ProcessCreated]
    @test !isempty(created)
    @test all(e.package_name == "AppTestPkg" for e in created)
    @test all(e.profile == "Default" for e in created)
    @test any(e -> e isa ProcessStatusChanged && e.status == "Launching", events)
    # `run_tests` leaves the session it ran on open, so its test processes are still alive
    # and available to the next run; they are terminated when the session is closed.
    ids = Set(e.id for e in created)
    @test isempty(Set(e.id for e in events if e isa ProcessTerminated))
    subscribe!(sink)                # the default session `run_tests` just used
    close_default_session!()
    @test Set(e.id for e in events if e isa ProcessTerminated) == ids
end

@testitem "a throwing sink does not break the run" setup=[Fixtures] begin
    import Logging
    n = Ref(0)
    # The sink's failures are logged at error level; silence them for the suite.
    result = run_tests(Fixtures.APP_PKG; filter = i -> i.name == "passing item", Fixtures.RUN_KW...,
        log_min_level=Logging.AboveMaxLevel,
        on_event = ev -> begin
            n[] += 1
            error("sink failure")
        end)
    @test Fixtures.status_of(result, "passing item") == :passed
    @test n[] > 2
end
