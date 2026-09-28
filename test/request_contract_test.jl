using Test
using Ciro
using PicoHTTPParser

function _request_contract_tests()
    @testset "Request contract" begin
        raw = Vector{UInt8}(
            "POST /predict?model=small HTTP/1.1\r\n" *
            "Host: localhost\r\n" *
            "Content-Type: application/octet-stream\r\n" *
            "Content-Length: 3\r\n\r\nabc")
        parsed = PicoHTTPParser.parse_request(raw)
        request = Ciro.Request(parsed)

        @test request isa Ciro.Request
        @test request.method == "POST"
        @test request.target == "/predict?model=small"
        @test request.path == "/predict"
        @test request.query == "model=small"
        @test header(request, "content-type") == "application/octet-stream"
        @test rawbody(request) == UInt8[0x61, 0x62, 0x63]
        @test query(request) == "model=small"
    end

    @testset "copy(ctx) materializes views" begin
        raw = Vector{UInt8}("POST /x?a=1 HTTP/1.1\r\nHost: h\r\nContent-Length: 2\r\n\r\nhi")
        request = Ciro.Request(PicoHTTPParser.parse_request(raw))
        context = RequestContext(request, [:id => "1"])

        copied = copy(context)
        @test copied.request.method isa String
        @test copied.request.path isa String
        @test copied.request.headers isa Vector{Pair{String,String}}
        @test String(copied.request.body) == "hi"
        @test copied.params !== context.params
        @test header(copied.request, "Host") == "h"
    end

    @testset "RequestContext contract" begin
        request = Ciro.Request("GET", "/models/42";
                               headers=["Host" => "localhost"],
                               body=UInt8[])
        context = RequestContext(request, [:id => "42"])

        @test context.request === request
        @test param(context, :id) == "42"
        @test path(context) == "/models/42"
        @test header(context, "HOST") == "localhost"
        @test rawbody(context) == UInt8[]
    end
end

_request_contract_tests()
