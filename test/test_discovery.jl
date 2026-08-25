@testitem "discover_testitems finds items, tags, positions and ids" setup=[Fixtures] begin
    d = discover_testitems(Fixtures.APP_PKG)
    @test d isa Discovery
    @test length(d) == 2
    @test isempty(d.definition_errors)
    @test isempty(d.setups)
    @test d.roots == [abspath(Fixtures.APP_PKG)]

    names = [i.name for i in d]
    @test names == ["passing item", "failing item"]   # file order

    failing = only(i for i in d if i.name == "failing item")
    @test failing.tags == [:failing]
    @test failing.line == 5
    @test failing.package_name == "AppTestPkg"
    @test startswith(failing.id, "AppTestPkg@")
    @test endswith(failing.id, "/test/app_tests.jl::failing item")
    @test endswith(failing.filename, joinpath("test", "app_tests.jl"))
    @test filename(failing) == failing.filename
    @test TestItemRuns.key(failing) == (failing.id, failing.package_uri)
    @test !isempty(failing.package_uri)
    @test failing.project_uri === nothing   # the fixture has no Manifest, so no project
    @test failing.skip == false
    @test occursin("add(1, 2) == 4", failing.code)
    @test failing.detail isa TestItemRuns.TestItemControllers.TestItemDetail
    @test :name in propertynames(failing)
    @test_throws ArgumentError failing.nonexistent

    pkgs = package_envs(d)
    @test length(pkgs) == 1
    @test pkgs[1].package_name == "AppTestPkg"
    @test sprint(show, d) == "Discovery(2 test items in 1 files, 0 setups, 0 definition errors)"
end

@testitem "discover_testitems records skip options" setup=[Fixtures] begin
    d = discover_testitems(Fixtures.SKIP_PKG)
    skips = Dict(i.name => i.skip for i in d)
    @test skips["skipped by literal"] == true
    @test skips["not skipped"] == false
    @test skips["skipped by expression"] isa String   # evaluated in the test process
end

@testitem "discover_testitems reports definition errors with ranges" setup=[Fixtures] begin
    d = discover_testitems(Fixtures.BROKEN_PKG)
    @test length(d.definition_errors) == 2
    e = d.definition_errors[1]
    @test e isa DefinitionError
    @test occursin("used more than once", e.message)
    @test e.name == "duplicate"
    @test (e.line, e.column) == (5, 1)
    @test (e.end_line, e.end_column) == (7, 3)
    @test endswith(filename(e), joinpath("test", "broken_tests.jl"))
    # The items are still discovered; running is what `fail_on_definition_error` gates.
    @test length(d) == 3
end

@testitem "filter keyword and Base.filter keep setups and errors" setup=[Fixtures] begin
    d = discover_testitems(Fixtures.APP_PKG; filter = i -> :failing in i.tags)
    @test [i.name for i in d] == ["failing item"]

    d = discover_testitems(Fixtures.BROKEN_PKG)
    f = filter(i -> i.name == "fine item", d)
    @test length(f) == 1
    @test f.definition_errors == d.definition_errors
    @test f.roots == d.roots
end

@testitem "select narrows by every criterion" setup=[Fixtures] begin
    d = discover_testitems(Fixtures.APP_PKG)
    passing = d[1]
    @test [i.name for i in select(d; ids=[passing.id])] == ["passing item"]
    @test [i.name for i in select(d; keys=[TestItemRuns.key(passing)])] == ["passing item"]
    @test [i.name for i in select(d; names=["failing item"])] == ["failing item"]
    @test [i.name for i in select(d; name_pattern=r"^pass")] == ["passing item"]
    @test [i.name for i in select(d; name_pattern="fail")] == ["failing item"]
    @test length(select(d; file_pattern="app_tests")) == 2
    @test isempty(select(d; file_pattern="nope"))
    @test [i.name for i in select(d; tags=["failing"])] == ["failing item"]
    @test [i.name for i in select(d; tags=[:failing, :other])] == ["failing item"]
    @test length(select(d; packages=["AppTestPkg"])) == 2
    @test isempty(select(d; packages=["Other"]))
    @test [i.name for i in select(d; predicate = i -> i.line > 1)] == ["failing item"]
    # Criteria combine with AND.
    @test isempty(select(d; tags=[:failing], name_pattern="pass"))
    @test select(d).testitems == d.testitems
end

@testitem "discover_testitems on a caller-owned workspace" setup=[Fixtures] begin
    import JuliaWorkspaces
    jw = JuliaWorkspaces.workspace_from_folders([Fixtures.APP_PKG])
    d = discover_testitems(jw)
    @test length(d) == 2
    @test d.roots == String[]
    d2 = discover_testitems(jw; roots=[Fixtures.APP_PKG], filter = i -> i.name == "passing item")
    @test length(d2) == 1
    @test d2.roots == [Fixtures.APP_PKG]
    # A vector of paths works too.
    d3 = discover_testitems([Fixtures.APP_PKG, Fixtures.SKIP_PKG])
    @test length(d3) == 5
    @test length(package_envs(d3)) == 2
end

@testitem "package_envs splits a package across nested projects" setup=[Fixtures] begin
    d = discover_testitems(Fixtures.NESTED_PKG)
    @test length(d) == 2

    by_name = Dict(i.name => i for i in d)
    base, special = by_name["base item"], by_name["special item"]

    # Same package, different project: nothing above `test/base_tests.jl` is a project (the
    # package folder has no manifest), while `test/special/` has both a project file and a
    # manifest that `dev`s the package back.
    @test base.package_uri == special.package_uri
    @test base.project_uri === nothing
    @test special.project_uri !== nothing
    @test endswith(special.project_uri, "special")
    @test base.env_content_hash != special.env_content_hash

    # Grouping on `package_uri` alone collapsed these two into one, and every item ran
    # against whichever project happened to be discovered first.
    envs = package_envs(d)
    @test length(envs) == 2
    @test length(unique(e.package_uri for e in envs)) == 1
    @test Set(e.project_uri for e in envs) == Set([nothing, special.project_uri])
    @test all(e.package_name == "NestedProjectPkg" for e in envs)
end
