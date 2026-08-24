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
