# profiles.jl — one named configuration under which test items run

"""
    RunProfile(name="Default"; coverage=false, env=Dict{String,Any}(), julia_cmd=nothing,
               julia_args=nothing, julia_num_threads=nothing, check_bounds=nothing)
    RunProfile(name, coverage, env)

One named configuration under which every test item of a run is executed. A run with
several profiles executes every item once per profile; the results are merged per item
(see [`TestrunResultTestitem`](@ref)).

# Fields
- `name::String` — profile name, recorded in the results
  (e.g. `"Julia 1.12.0~x64:ubuntu-latest"`).
- `coverage::Bool` — run in coverage mode.
- `env::Dict{String,Any}` — environment variables for the test processes. A `nothing`
  value removes the variable from the child environment.
- `julia_cmd`, `julia_args`, `julia_num_threads`, `check_bounds` — per-profile overrides
  of the corresponding run-level settings; `nothing` means "use the run-level value".
"""
struct RunProfile
    name::String
    coverage::Bool
    env::Dict{String,Any}
    julia_cmd::Union{Nothing,String}
    julia_args::Union{Nothing,Vector{String}}
    julia_num_threads::Union{Nothing,String}
    check_bounds::Union{Nothing,String}
end

RunProfile(name::AbstractString, coverage::Bool, env::AbstractDict) =
    RunProfile(String(name), coverage, Dict{String,Any}(env), nothing, nothing, nothing, nothing)

RunProfile(name::AbstractString="Default"; coverage::Bool=false, env=Dict{String,Any}(),
           julia_cmd=nothing, julia_args=nothing, julia_num_threads=nothing, check_bounds=nothing) =
    RunProfile(String(name), coverage, Dict{String,Any}(env),
        julia_cmd === nothing ? nothing : String(julia_cmd),
        julia_args === nothing ? nothing : String[string(a) for a in julia_args],
        julia_num_threads === nothing ? nothing : String(julia_num_threads),
        check_bounds === nothing ? nothing : String(check_bounds))

# Test processes must not inherit the environment the host was launched with: a Pkg
# app shim (and the GitHub Action runner) pins JULIA_LOAD_PATH/JULIA_PROJECT/
# JULIA_DEPOT_PATH to the host's own environment, which would prevent the test
# process from resolving its own. Profile-provided values override these defaults.
function _child_env(profile::RunProfile)
    env_vars = Dict{String,Union{String,Nothing}}(
        "JULIA_LOAD_PATH" => nothing,
        "JULIA_PROJECT" => nothing,
        "JULIA_DEPOT_PATH" => nothing,
    )
    for (k, v) in profile.env
        env_vars[k] = v === nothing ? nothing : string(v)
    end
    return env_vars
end
