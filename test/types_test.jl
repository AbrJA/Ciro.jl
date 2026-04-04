module TypesTests
using Test
using Ciro

@testset "Response Creation" begin
    # Test text response
    resp = text("Hello World")
    @test resp.status == 200
    @test resp.headers == ["Content-Type" => "text/plain; charset=utf-8"]
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

    # Test html response
    resp = html("<h1>Hi</h1>")
    @test resp.status == 200
    @test resp.headers == ["Content-Type" => "text/html; charset=utf-8"]
    @test String(resp.body) == "<h1>Hi</h1>"
end

@testset "JSON Response (Extension)" begin
    using JSON
    data = Dict("key" => "value", "number" => 42)
    resp = json(data)

    @test resp.status == 200
    @test resp.headers == ["Content-Type" => "application/json; charset=utf-8"]

    body_str = String(resp.body)
    @test occursin("\"key\"", body_str)
    @test occursin("\"value\"", body_str)
    @test occursin("42", body_str)
end

@testset "hasheader & getheader" begin
    resp = text("test")
    @test Ciro.Types.hasheader(resp, "Content-Type") == true
    @test Ciro.Types.hasheader(resp, "X-Missing") == false
    @test Ciro.Types.getheader(resp, "Content-Type") == "text/plain; charset=utf-8"
    @test Ciro.Types.getheader(resp, "X-Missing", "default") == "default"
end

@testset "Status Lines" begin
    @test Ciro.Types.status_line(200) == "HTTP/1.1 200 OK\r\n"
    @test Ciro.Types.status_line(404) == "HTTP/1.1 404 Not Found\r\n"
    @test Ciro.Types.status_line(500) == "HTTP/1.1 500 Internal Server Error\r\n"

    # Unknown status code
    @test Ciro.Types.status_line(999) == "HTTP/1.1 999 Unknown\r\n"

    # Zero allocation for common codes (returns same const reference)
    @test Ciro.Types.status_line(200) === Ciro.Types.status_line(200)
end

@testset "Methods Enum" begin
    @test Ciro.Types.Methods.from_string("GET") == Ciro.Types.Methods.GET
    @test Ciro.Types.Methods.from_string("POST") == Ciro.Types.Methods.POST
    @test Ciro.Types.Methods.from_string("PUT") == Ciro.Types.Methods.PUT
    @test Ciro.Types.Methods.from_string("DELETE") == Ciro.Types.Methods.DELETE
    @test Ciro.Types.Methods.from_string("PATCH") == Ciro.Types.Methods.PATCH
    @test Ciro.Types.Methods.from_string("HEAD") == Ciro.Types.Methods.HEAD
    @test Ciro.Types.Methods.from_string("OPTIONS") == Ciro.Types.Methods.OPTIONS
    @test Ciro.Types.Methods.from_string("TRACE") == Ciro.Types.Methods.UNKNOWN
end

end # module
