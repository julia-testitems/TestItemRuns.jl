# One test item, not many: these all mutate the process-wide default session, and the
# items of this suite run in parallel inside one test process.
@testitem "the default session and the session-less methods" setup=[Fixtures] begin
    close_default_session!()   # other items in this process may have left one
    @test !has_default_session()
    try
        s = default_session()
        @test s isa TestSession
        @test default_session() === s          # created once, reused
        @test has_default_session()
        @test isempty(list_processes())

        d = discover_testitems(Fixtures.APP_PKG)
        r1 = run!(d; Fixtures.RUN_KW...)
        @test Fixtures.status_of(r1, "passing item") == :passed
        procs1 = list_processes()
        @test !isempty(procs1)                 # left warm for the next run

        # The whole point of a process-wide session: the second run revises the same test
        # processes instead of launching new ones.
        run!(d; Fixtures.RUN_KW...)
        @test Set(p.id for p in list_processes()) == Set(p.id for p in procs1)

        runs = list_runs()
        @test length(runs) == 2
        @test get_run(first(runs[1].id, 8)) === runs[1]
        @test process_output(procs1[1].id) isa String

        # Termination is asynchronous: the reactor reports each process as it goes.
        terminated = Channel{String}(Inf)
        sink = ev -> ev isa ProcessTerminated && put!(terminated, ev.id)
        subscribe!(sink)
        terminate_all_processes!()
        while !isempty(list_processes())
            take!(terminated)
        end
        @test isempty(list_processes())
        # Terminating the pool leaves the session usable.
        @test Fixtures.status_of(run!(d; Fixtures.RUN_KW...), "passing item") == :passed
        one_id = list_processes()[1].id
        terminate_process!(one_id)
        while any(p.id == one_id for p in list_processes())
            take!(terminated)
        end
        unsubscribe!(sink)

        # A closed default session is replaced transparently rather than throwing.
        close_default_session!()
        @test !has_default_session()
        @test isempty(list_processes())
        @test has_default_session()

        # An installed session is handed back, not closed — its creator still owns it.
        mine = TestSession()
        try
            previous = set_default_session!(mine)
            @test default_session() === mine
            @test previous !== nothing && isopen(previous)
            close_default_session!()           # closes `mine`, which we installed
            @test !isopen(mine)
            close(previous)
        finally
            close(mine)
        end

        # `subscribe!(session)` would otherwise register the session as an event sink.
        @test_throws ArgumentError subscribe!(default_session())
        @test_throws ArgumentError unsubscribe!(default_session())
    finally
        close_default_session!()
    end
end

@testitem "run_tests without a session keeps its processes warm" setup=[Fixtures] begin
    close_default_session!()   # other items in this process may have left one
    @test !has_default_session()
    try
        r = run_tests(Fixtures.APP_PKG; Fixtures.RUN_KW...)
        @test Fixtures.status_of(r, "passing item") == :passed
        procs = list_processes()
        @test !isempty(procs)

        run_tests(Fixtures.APP_PKG; Fixtures.RUN_KW...)
        @test Set(p.id for p in list_processes()) == Set(p.id for p in procs)
        @test length(list_runs()) == 2

        # A session-level setting the default session was not built with rebuilds it.
        run_tests(Fixtures.APP_PKG; schedule=:contiguous, Fixtures.RUN_KW...)
        @test Set(p.id for p in list_processes()) != Set(p.id for p in procs)

        # An explicit session is used and left open, and does not touch the default one.
        before = default_session()
        session = TestSession()
        try
            @test Fixtures.status_of(run_tests(session, Fixtures.APP_PKG; Fixtures.RUN_KW...),
                "passing item") == :passed
            @test !isempty(list_processes(session))
            @test isopen(session)
            @test default_session() === before
            # Session-level settings cannot be applied to a session that already exists.
            @test_throws ArgumentError run_tests(session, Fixtures.APP_PKG; schedule=:contiguous)
        finally
            close(session)
        end
    finally
        close_default_session!()
    end
end

@testitem "run_tests does not leave its sink attached to the session" setup=[Fixtures] begin
    session = TestSession()
    try
        seen = Ref(0)
        run_tests(session, Fixtures.APP_PKG; on_event = _ -> (seen[] += 1), Fixtures.RUN_KW...)
        @test seen[] > 0
        after = seen[]
        # The session outlives the call, so the sink must have been removed again.
        run!(session, discover_testitems(Fixtures.APP_PKG); Fixtures.RUN_KW...)
        @test seen[] == after
    finally
        close(session)
    end
end
