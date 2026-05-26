using Test

# Run all test suites
@testset "Ciro POC Test Suite" begin
    include("backend_test.jl")
    include("interfaces_test.jl")
    include("router_test.jl")
    include("middleware_test.jl")
    include("core_test.jl")
end
