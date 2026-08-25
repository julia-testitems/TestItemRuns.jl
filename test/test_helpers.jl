@testmodule Fixtures begin
    const TESTDATA = joinpath(@__DIR__, "..", "testdata")
    const APP_PKG = joinpath(TESTDATA, "AppTestPkg")
    const SKIP_PKG = joinpath(TESTDATA, "SkipPkg")
    const SLOW_PKG = joinpath(TESTDATA, "SlowPkg")
    const BROKEN_PKG = joinpath(TESTDATA, "BrokenPkg")
    const FAILFAST_PKG = joinpath(TESTDATA, "FailfastPkg")
    const LOGLEVEL_PKG = joinpath(TESTDATA, "LogLevelPkg")
    # One test item under `test/` and one under `test/special/`, which is a project in its
    # own right (Project + Manifest) and `dev`s the package back — so the two items resolve
    # to different environments.
    const NESTED_PKG = joinpath(TESTDATA, "NestedProjectPkg")

    # Every run in this suite pins the Julia that runs the suite, so the test processes
    # never depend on what `julia` resolves to on PATH.
    const JULIA = joinpath(Sys.BINDIR, "julia")
    const RUN_KW = (; julia_cmd=JULIA, timeout=300)

    status_of(result, name) = only(only(t for t in result.testitems if t.name == name).profiles).status
    statuses(result) = Dict(t.name => [p.status for p in t.profiles] for t in result.testitems)
end
