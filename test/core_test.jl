using Test
using CiroCore
using CiroInterfaces
using PicoHTTPParser

@testset "CiroCore" begin

    @testset "Response serialization" begin
        buf = Vector{UInt8}(undef, 4096)

        # Simple 200 text response
        resp = text("Hello")
        n = CiroCore.serialize_response!(buf, resp)
        output = String(copy(buf[1:n]))
        @test startswith(output, "HTTP/1.1 200 OK\r\n")
        @test contains(output, "Content-Type: text/plain; charset=utf-8\r\n")
        @test contains(output, "Content-Length: 5\r\n")
        @test endswith(output, "\r\n\r\nHello")

        # 404 error
        resp = error_response(404, "Not Found")
        n = CiroCore.serialize_response!(buf, resp)
        output = String(copy(buf[1:n]))
        @test startswith(output, "HTTP/1.1 404 Not Found\r\n")
        @test contains(output, "Content-Length: 9\r\n")

        # Empty body (204)
        resp = Response(204, Pair{String,String}[], UInt8[])
        n = CiroCore.serialize_response!(buf, resp)
        output = String(copy(buf[1:n]))
        @test startswith(output, "HTTP/1.1 204 No Content\r\n")
        @test contains(output, "Content-Length: 0\r\n")

        # Response with multiple headers
        resp = Response(200, [
            "Content-Type" => "text/html",
            "X-Custom" => "value",
            "Cache-Control" => "no-cache",
        ], Vector{UInt8}("<h1>Hi</h1>"))
        n = CiroCore.serialize_response!(buf, resp)
        output = String(copy(buf[1:n]))
        @test contains(output, "X-Custom: value\r\n")
        @test contains(output, "Cache-Control: no-cache\r\n")
        @test endswith(output, "<h1>Hi</h1>")

        # Explicit Content-Length (should not add duplicate)
        resp = Response(200, ["Content-Length" => "3"], Vector{UInt8}("abc"))
        n = CiroCore.serialize_response!(buf, resp)
        output = String(copy(buf[1:n]))
        @test count("Content-Length", output) == 1

        # Buffer auto-resize for large response
        big_body = repeat("x", 100_000)
        resp = text(big_body)
        small_buf = Vector{UInt8}(undef, 64)
        n = CiroCore.serialize_response!(small_buf, resp)
        @test n > 100_000
        @test length(small_buf) >= n
    end

    @testset "CiroServer construction" begin
        using CiroRouter
        router = Router()
        route_get!(router, "/", req -> text("hi"))

        # Default parameters
        server = CiroServer(; router)
        @test server.host == "0.0.0.0"
        @test server.port == 8080
        @test server.backlog == 8192
        @test server.max_body_size == 1_048_576
        @test server.logger isa NullLogger
        @test server.error_handler isa DefaultErrorHandler
        @test server._running[] == false

        # Custom parameters
        server2 = CiroServer(; router, port=3000, host="127.0.0.1", max_body_size=5_000_000)
        @test server2.port == 3000
        @test server2.host == "127.0.0.1"
        @test server2.max_body_size == 5_000_000
    end

    @testset "Custom logger integration" begin
        using CiroRouter
        router = Router()
        route_get!(router, "/", req -> text("ok"))

        messages = String[]
        struct TestLogger <: AbstractLogger end
        CiroInterfaces.log_event(::TestLogger, level::LogLevel, msg::String) = push!(messages, msg)

        server = CiroServer(; router, logger=TestLogger(), port=19999)
        @test server.logger isa TestLogger
    end

    @testset "Dispatch logic" begin
        using CiroRouter
        router = Router()
        route_get!(router, "/ok", req -> text("200"))
        route_get!(router, "/error", req -> error("boom"))
        route_get!(router, "/bad-return", req -> 42)  # non-Response return

        server = CiroServer(; router, port=19998)

        # Test dispatch directly
        raw = Vector{UInt8}("GET /ok HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)
        resp = CiroCore._dispatch(server, req)
        @test resp.status == 200
        @test String(copy(resp.body)) == "200"

        # 404 for unregistered
        raw2 = Vector{UInt8}("GET /missing HTTP/1.1\r\nHost: x\r\n\r\n")
        req2 = PicoHTTPParser.parse_request(raw2)
        resp2 = CiroCore._dispatch(server, req2)
        @test resp2.status == 404

        # Error handler catches exceptions
        raw3 = Vector{UInt8}("GET /error HTTP/1.1\r\nHost: x\r\n\r\n")
        req3 = PicoHTTPParser.parse_request(raw3)
        resp3 = CiroCore._dispatch(server, req3)
        @test resp3.status == 500
        # Must not expose "boom" to client
        @test !contains(String(copy(resp3.body)), "boom")

        # Non-Response returns get text() wrapped
        raw4 = Vector{UInt8}("GET /bad-return HTTP/1.1\r\nHost: x\r\n\r\n")
        req4 = PicoHTTPParser.parse_request(raw4)
        resp4 = CiroCore._dispatch(server, req4)
        @test resp4.status == 200
        @test String(copy(resp4.body)) == "42"
    end

    @testset "Query string stripped from routing" begin
        using CiroRouter
        router = Router()
        route_get!(router, "/search", req -> text("found"))

        server = CiroServer(; router, port=19997)

        raw = Vector{UInt8}("GET /search?q=test&page=1 HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)
        resp = CiroCore._dispatch(server, req)
        @test resp.status == 200
        @test String(copy(resp.body)) == "found"
    end
end
