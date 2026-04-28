module TypesTests
using Test

include(joinpath(@__DIR__, "../src/Ciro.jl"))
using .Ciro.Types

@testset "Response Creation" begin
    # Test text response
    resp = text("Hello World")
    @test resp.status == 200
    @test resp.headers["Content-Type"] == "text/plain"
    @test String(resp.body) == "Hello World"

    # Test text with custom status
    resp = text("Not Found"; status=404)
    @test resp.status == 404

    # Test Response constructor
    resp = Response(201, "Created")
    @test resp.status == 201
    @test String(resp.body) == "Created"
end

@testset "JSON Response" begin
    data = Dict("key" => "value", "number" => 42)
    resp = json(data)

    @test resp.status == 200
    @test resp.headers["Content-Type"] == "application/json"

    # Parse the body back
    body_str = String(resp.body)
    @test occursin("\"key\"", body_str)
    @test occursin("\"value\"", body_str)
    @test occursin("42", body_str)
end

end # module
