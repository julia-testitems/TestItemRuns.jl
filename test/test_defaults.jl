@testitem "default_max_workers" begin
    GiB = 2^30
    # Capped by memory: 3 CPUs, 7 GiB (GitHub's macOS arm64 runners).
    @test default_max_workers(; total_memory=7GiB, cpu_threads=3) == 2
    # Capped by CPU threads.
    @test default_max_workers(; total_memory=14GiB, cpu_threads=4) == 4
    @test default_max_workers(; total_memory=16GiB, cpu_threads=4) == 4
    # Capped at 8.
    @test default_max_workers(; total_memory=128GiB, cpu_threads=36) == 8
    # Never below 1.
    @test default_max_workers(; total_memory=2GiB, cpu_threads=8) == 1
    @test default_max_workers(; total_memory=0, cpu_threads=8) == 1
    # `Sys.total_memory()` is a `UInt64`; the result is still an `Int`.
    @test default_max_workers(; total_memory=UInt64(7GiB), cpu_threads=3) === 2
    # The real machine.
    n = default_max_workers()
    @test n isa Int
    @test 1 <= n <= min(Sys.CPU_THREADS, 8)
end
