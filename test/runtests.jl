using Test
using Ciro

@testset "Ciro.jl" begin
    include("interfaces_test.jl")
    include("router_test.jl")
    include("middleware_test.jl")
    include("core_test.jl")
    include("backend_test.jl")
end
