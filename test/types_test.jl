module TypesTests
using Test
using Ciro

@testset "Response Creation" begin
    # Test text response
    resp = text("Hello World")
    @test resp.status == 200
    @test resp.headers == ["Content-Type" => "text/plain"]
    @test String(resp.body) == "Hello World"

    # Test text with custom status
    resp = text("Not Found"; status=404)
    @test resp.status == 404

    # Test Response constructor with string body
    resp = Response(201, "Created")
    @test resp.status == 201
    @test String(resp.body) == "Created"
    @test isempty(resp.headers)

    # Test Response constructor with custom headers
    resp = Response(200, "OK", ["X-Custom" => "value"])
    @test resp.headers == ["X-Custom" => "value"]
end

@testset "JSON Response (Extension)" begin
    using JSON
    data = Dict("key" => "value", "number" => 42)
    resp = json(data)

    @test resp.status == 200
    @test resp.headers == ["Content-Type" => "application/json"]

    body_str = String(resp.body)
    @test occursin("\"key\"", body_str)
    @test occursin("\"value\"", body_str)
    @test occursin("42", body_str)
end

@testset "hasheader" begin
    resp = text("test")
    @test Ciro.Types.hasheader(resp, "Content-Type") == true
    @test Ciro.Types.hasheader(resp, "X-Missing") == false
end

end # module
