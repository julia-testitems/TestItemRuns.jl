@testitem "run_tests on the fixture package" setup=[Fixtures] begin
    result = run_tests(Fixtures.APP_PKG; Fixtures.RUN_KW...)
    @test result isa TestrunResult
    @test isempty(result.definition_errors)
    @test length(result.testitems) == 2
    @test Fixtures.status_of(result, "passing item") == :passed
    @test Fixtures.status_of(result, "failing item") == :failed

    failing = only(t for t in result.testitems if t.name == "failing item")
    prof = only(failing.profiles)
    @test prof.profile_name == "Default"
    @test prof.duration isa Float64
    @test prof.messages !== nothing && !isempty(prof.messages)
    @test any(occursin("Test Failed", m.message) || occursin("==", m.message) for m in prof.messages)
    @test startswith(failing.id, "AppTestPkg@")
    @test endswith(failing.id, "/test/app_tests.jl::failing item")
    @test result.coverage === nothing

    # JSON round trip through the TestItemControllers writers.
    path = tempname() * ".json"
    write_json(path, result)
    back = read_json(path)
    @test length(back.testitems) == 2
    @test Fixtures.statuses(back) == Fixtures.statuses(result)
    @test !write_lcov(tempname() * ".info", result)
end

@testitem "run_tests collects coverage and perf stats" setup=[Fixtures] begin
    result = run_tests(Fixtures.APP_PKG; profiles=[RunProfile("cov"; coverage=true)], Fixtures.RUN_KW...)
    @test result.coverage !== nothing
    @test any(endswith(fc.uri, "AppTestPkg.jl") for fc in result.coverage)
    @test any(c !== nothing && c > 0 for fc in result.coverage for c in fc.coverage)
    lcov = tempname() * ".info"
    @test write_lcov(lcov, result)
    text = read(lcov, String)
    @test occursin("SF:", text) && occursin("end_of_record", text)

    passing = only(t for t in result.testitems if t.name == "passing item")
    prof = only(passing.profiles)
    @test prof.profile_name == "cov"
    @test prof.perf !== nothing
    @test prof.perf.bytes > 0
end

@testitem "run_tests filter selects items" setup=[Fixtures] begin
    result = run_tests(Fixtures.APP_PKG; filter = i -> i.name == "passing item", Fixtures.RUN_KW...)
    @test [t.name for t in result.testitems] == ["passing item"]
end

@testitem "run_tests honours skip" setup=[Fixtures] begin
    result = run_tests(Fixtures.SKIP_PKG; Fixtures.RUN_KW...)
    s = Fixtures.statuses(result)
    @test s["skipped by literal"] == [:skipped]
    @test s["skipped by expression"] == [:skipped]
    @test s["not skipped"] == [:passed]
end

@testitem "run_tests runs every profile and merges per item" setup=[Fixtures] begin
    profiles = [RunProfile("A"), RunProfile("B"; env=Dict{String,Any}("TIR_TEST_VAR" => "1"))]
    result = run_tests(Fixtures.APP_PKG; profiles=profiles, filter = i -> i.name == "passing item", Fixtures.RUN_KW...)
    t = only(result.testitems)
    @test [p.profile_name for p in t.profiles] == ["A", "B"]
    @test all(p.status == :passed for p in t.profiles)
end

@testitem "run_tests and definition errors" setup=[Fixtures] begin
    result = run_tests(Fixtures.BROKEN_PKG; Fixtures.RUN_KW...)
    @test length(result.definition_errors) == 2
    @test isempty(result.testitems)   # nothing ran
    e = result.definition_errors[1]
    @test e.line == 5 && occursin("more than once", e.message)

    result = run_tests(Fixtures.BROKEN_PKG; fail_on_definition_error=false, Fixtures.RUN_KW...)
    @test length(result.definition_errors) == 2
    # The two "duplicate" items merge by (name, uri), so 3 units become 2 entries.
    @test length(result.testitems) == 2
    @test sum(length(t.profiles) for t in result.testitems) == 3
end

@testitem "run_tests returns the partial result when cancelled up front" setup=[Fixtures] begin
    using TestItemRuns.CancellationTokens
    cts = CancellationTokenSource()
    cancel(cts)
    finished = Ref{Any}(nothing)
    result = run_tests(Fixtures.APP_PKG; token=get_token(cts), Fixtures.RUN_KW...,
        on_event = ev -> ev isa RunFinished && (finished[] = ev))
    @test result isa TestrunResult
    @test finished[] !== nothing
    @test finished[].status == :cancelled
    @test all(p.status == :skipped for t in result.testitems for p in t.profiles)
end

@testitem "run_tests prints nothing" setup=[Fixtures] begin
    # Output comes from the reactor task as well as the calling task, so a real pipe is needed.
    pipe = Pipe()
    Base.link_pipe!(pipe; reader_supports_async=true, writer_supports_async=true)
    reader = @async read(pipe, String)
    try
        redirect_stdout(pipe) do
            run_tests(Fixtures.APP_PKG; filter = i -> i.name == "passing item", Fixtures.RUN_KW...)
            # The test processes outlive the call and inherited the redirected stdout, so
            # the pipe only reaches EOF once they are gone.
            close_default_session!()
        end
    finally
        close(pipe.in)
    end
    @test fetch(reader) == ""
end

@testitem "run_tests rejects bad options" setup=[Fixtures] begin
    @test_throws ArgumentError run_tests(Fixtures.APP_PKG; schedule=:random)
    @test_throws ArgumentError run_tests(Fixtures.APP_PKG; max_workers=0)
    @test_throws ArgumentError run_tests(Fixtures.APP_PKG; profiles=RunProfile[])
    @test_throws ArgumentError run_tests(Fixtures.APP_PKG; profiles=[RunProfile("x"), RunProfile("x")])
end
