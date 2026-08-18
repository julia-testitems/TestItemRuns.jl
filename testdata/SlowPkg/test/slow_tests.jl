@testitem "quick item" begin
    @test true
end

@testitem "slow item" begin
    sleep(60)
    @test true
end
