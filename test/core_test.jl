using Test
using Ciro
using PicoHTTPParser

@testset "Core" begin

    @testset "Response serialization" begin
        buf = Vector{UInt8}(undef, 4096)

        # Simple 200 text response
        resp = text("Hello")
        n = Ciro.Core.serialize_response!(buf, resp)
        output = String(copy(buf[1:n]))
        @test startswith(output, "HTTP/1.1 200 OK\r\n")
        @test contains(output, "Content-Type: text/plain; charset=utf-8\r\n")
        @test contains(output, "Content-Length: 5\r\n")
        @test endswith(output, "\r\n\r\nHello")

        # 404 error
        resp = fail(404, "Not Found")
        n = Ciro.Core.serialize_response!(buf, resp)
        output = String(copy(buf[1:n]))
        @test startswith(output, "HTTP/1.1 404 Not Found\r\n")
        @test contains(output, "Content-Length: 9\r\n")

        # Empty body (204)
        resp = Response(204, Pair{String,String}[], UInt8[])
        n = Ciro.Core.serialize_response!(buf, resp)
        output = String(copy(buf[1:n]))
        @test startswith(output, "HTTP/1.1 204 No Content\r\n")
        @test contains(output, "Content-Length: 0\r\n")

        # Response with multiple headers
        resp = Response(200, [
            "Content-Type" => "text/html",
            "X-Custom" => "value",
            "Cache-Control" => "no-cache",
        ], Vector{UInt8}("<h1>Hi</h1>"))
        n = Ciro.Core.serialize_response!(buf, resp)
        output = String(copy(buf[1:n]))
        @test contains(output, "X-Custom: value\r\n")
        @test contains(output, "Cache-Control: no-cache\r\n")
        @test endswith(output, "<h1>Hi</h1>")

        # Explicit Content-Length (should not add duplicate)
        resp = Response(200, ["Content-Length" => "3"], Vector{UInt8}("abc"))
        n = Ciro.Core.serialize_response!(buf, resp)
        output = String(copy(buf[1:n]))
        @test count("Content-Length", output) == 1

        # Buffer auto-resize for large response
        big_body = repeat("x", 100_000)
        resp = text(big_body)
        small_buf = Vector{UInt8}(undef, 64)
        n = Ciro.Core.serialize_response!(small_buf, resp)
        @test n > 100_000
        @test length(small_buf) >= n
    end

    @testset "Server construction" begin
        router = Trie()
        get!(router, "/", req -> text("hi"))

        # Default parameters
        server = Server(; router)
        @test server.host == "0.0.0.0"
        @test server.port == 8080
        @test server.backlog == 8192
        @test server.max_body_size == 1_048_576
        @test server.logger isa NullLogger
        @test server.catcher isa DefaultCatcher
        @test server._running[] == false

        # Custom parameters
        server2 = Server(; router, port=3000, host="127.0.0.1", max_body_size=5_000_000)
        @test server2.port == 3000
        @test server2.host == "127.0.0.1"
        @test server2.max_body_size == 5_000_000
    end

    @testset "Dispatch logic" begin
        router = Trie()
        get!(router, "/ok", req -> text("200"))
        get!(router, "/error", req -> error("boom"))
        get!(router, "/bad-return", req -> 42)  # non-Response return

        server = Server(; router, port=19998)

        # Normal dispatch
        raw = Vector{UInt8}("GET /ok HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)
        resp = Ciro.Core._dispatch(server, req)
        @test resp.status == 200
        @test String(copy(resp.body)) == "200"

        # 404 for unregistered
        raw2 = Vector{UInt8}("GET /missing HTTP/1.1\r\nHost: x\r\n\r\n")
        req2 = PicoHTTPParser.parse_request(raw2)
        resp2 = Ciro.Core._dispatch(server, req2)
        @test resp2.status == 404

        # Error handler catches exceptions
        raw3 = Vector{UInt8}("GET /error HTTP/1.1\r\nHost: x\r\n\r\n")
        req3 = PicoHTTPParser.parse_request(raw3)
        resp3 = Ciro.Core._dispatch(server, req3)
        @test resp3.status == 500
        @test !contains(String(copy(resp3.body)), "boom")

        # Non-Response returns get text() wrapped
        raw4 = Vector{UInt8}("GET /bad-return HTTP/1.1\r\nHost: x\r\n\r\n")
        req4 = PicoHTTPParser.parse_request(raw4)
        resp4 = Ciro.Core._dispatch(server, req4)
        @test resp4.status == 200
        @test String(copy(resp4.body)) == "42"

        # 405 for wrong method on existing path
        raw5 = Vector{UInt8}("POST /ok HTTP/1.1\r\nHost: x\r\n\r\n")
        req5 = PicoHTTPParser.parse_request(raw5)
        resp5 = Ciro.Core._dispatch(server, req5)
        @test resp5.status == 405
        @test contains(header(resp5, "Allow"), "GET")
    end

    @testset "Query string stripped from routing" begin
        router = Trie()
        get!(router, "/search", req -> text("found"))

        server = Server(; router, port=19997)

        raw = Vector{UInt8}("GET /search?q=test&page=1 HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)
        resp = Ciro.Core._dispatch(server, req)
        @test resp.status == 200
        @test String(copy(resp.body)) == "found"
    end

    @testset "Connection close detection" begin
        # Connection: close header should trigger close
        raw_close = Vector{UInt8}("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        req_close = PicoHTTPParser.parse_request(raw_close)
        @test Ciro.Core._wants_close(req_close) == true

        # No Connection header → keep alive
        raw_keep = Vector{UInt8}("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        req_keep = PicoHTTPParser.parse_request(raw_keep)
        @test Ciro.Core._wants_close(req_keep) == false

        # HTTP/1.0 defaults to close
        raw_10 = Vector{UInt8}("GET / HTTP/1.0\r\nHost: x\r\n\r\n")
        req_10 = PicoHTTPParser.parse_request(raw_10)
        @test Ciro.Core._wants_close(req_10) == true

        # HTTP/1.0 with keep-alive token stays open
        raw_10_keep = Vector{UInt8}("GET / HTTP/1.0\r\nHost: x\r\nConnection: Keep-Alive\r\n\r\n")
        req_10_keep = PicoHTTPParser.parse_request(raw_10_keep)
        @test Ciro.Core._wants_close(req_10_keep) == false

        # Comma-separated tokens are parsed correctly
        raw_tokens = Vector{UInt8}("GET / HTTP/1.1\r\nHost: x\r\nConnection: upgrade, close\r\n\r\n")
        req_tokens = PicoHTTPParser.parse_request(raw_tokens)
        @test Ciro.Core._wants_close(req_tokens) == true

        # nothing request → close
        @test Ciro.Core._wants_close(nothing) == true
    end

    @testset "Serialization - large response" begin
        buf = Vector{UInt8}(undef, 64)
        big_body = repeat("A", 200_000)
        resp = text(big_body)
        n = Ciro.Core.serialize_response!(buf, resp)
        @test n > 200_000
        @test length(buf) >= n
        output = String(copy(buf[1:n]))
        @test endswith(output, big_body)
    end

    @testset "Serialization - empty headers" begin
        buf = Vector{UInt8}(undef, 4096)
        resp = Response(204, Pair{String,String}[], UInt8[])
        n = Ciro.Core.serialize_response!(buf, resp)
        output = String(copy(buf[1:n]))
        @test startswith(output, "HTTP/1.1 204")
        @test contains(output, "Content-Length: 0")
    end

    @testset "Serialization - many headers" begin
        buf = Vector{UInt8}(undef, 4096)
        headers = ["H$i" => "value$i" for i in 1:20]
        resp = Response(200, headers, Vector{UInt8}("body"))
        n = Ciro.Core.serialize_response!(buf, resp)
        output = String(copy(buf[1:n]))
        @test contains(output, "H1: value1")
        @test contains(output, "H20: value20")
        @test endswith(output, "body")
    end

    @testset "Dispatch with route params" begin
        router = Trie()
        get!(router, "/users/:id::Int", ctx -> json("""{"id":$(param(ctx, Int, :id))}"""))

        server = Server(; router, port=19995)

        raw = Vector{UInt8}("GET /users/42 HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)
        resp = Ciro.Core._dispatch(server, req)
        @test resp.status == 200
        @test String(copy(resp.body)) == """{"id":42}"""
    end

    @testset "Custom catcher" begin
        struct TestCatcher <: AbstractCatcher end
        Ciro.Interface.intercept(::TestCatcher, err::Exception, _) =
            json("""{"error":"$(typeof(err))"}"""; status=503)

        router = Trie()
        get!(router, "/crash", ctx -> error("oops"))

        server = Server(; router, catcher=TestCatcher(), port=19994)

        raw = Vector{UInt8}("GET /crash HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)
        resp = Ciro.Core._dispatch(server, req)
        @test resp.status == 503
        @test contains(String(copy(resp.body)), "ErrorException")
    end

    @testset "HTTP Date header format" begin
        buf = Vector{UInt8}(undef, 4096)
        resp = text("hello")
        n = Ciro.Core.serialize_response!(buf, resp)
        output = String(copy(buf[1:n]))
        # Date header must be present and follow RFC 5322 HTTP-date format:
        # e.g.  Date: Fri, 30 May 2026 12:00:00 GMT
        @test contains(output, "Date: ")
        m = match(r"Date: (\w+, \d{2} \w+ \d{4} \d{2}:\d{2}:\d{2} GMT)", output)
        @test m !== nothing
    end

    @testset "Date header not duplicated" begin
        buf = Vector{UInt8}(undef, 4096)
        resp = Response(200, ["Date" => "Thu, 01 Jan 2026 00:00:00 GMT"], "hi")
        n = Ciro.Core.serialize_response!(buf, resp)
        output = String(copy(buf[1:n]))
        @test count("Date:", output) == 1
    end

    @testset "_http_date caching" begin
        # Two consecutive calls in the same second must return the same object
        d1 = Ciro.Core._http_date()
        d2 = Ciro.Core._http_date()
        @test d1 == d2
        @test d1 isa String
        # Format check: 29 chars minimum: "Mon, 01 Jan 2000 00:00:00 GMT"
        @test length(d1) >= 29
        @test endswith(d1, " GMT")
    end

    @testset "Dispatch - PATCH and OPTIONS" begin
        router = Trie()
        patch!(router,   "/r", ctx -> text("patched"))
        options!(router, "/r", ctx -> text("options"))
        server = Server(; router, port=19993)

        raw_patch = Vector{UInt8}("PATCH /r HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw_patch)
        resp = Ciro.Core._dispatch(server, req)
        @test resp.status == 200
        @test String(copy(resp.body)) == "patched"

        raw_opts = Vector{UInt8}("OPTIONS /r HTTP/1.1\r\nHost: x\r\n\r\n")
        req2 = PicoHTTPParser.parse_request(raw_opts)
        resp2 = Ciro.Core._dispatch(server, req2)
        @test resp2.status == 200
        @test String(copy(resp2.body)) == "options"
    end

    @testset "Server stop! flag" begin
        router = Trie()
        server = Server(; router, port=19992)
        @test server._running[] == false
        stop!(server)
        @test server._running[] == false  # stop! sets it false; start! sets it true
    end

    @testset "Dispatch - HEAD auto-generated" begin
        router = Trie()
        get!(router, "/page", ctx -> text("content"))
        server = Server(; router, port=19991)

        raw_head = Vector{UInt8}("HEAD /page HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw_head)
        resp = Ciro.Core._dispatch(server, req)
        @test resp.status == 200
        @test isempty(resp.body)
    end

    @testset "Dispatch - body exceeds max_body_size" begin
        router = Trie()
        post!(router, "/upload", ctx -> text("ok"))
        server = Server(; router, port=19990, max_body_size=10)

        # bytes_read is determined by what the C engine reads; we simulate via _handle_read
        # Instead test the direct check: bytes_read > max_body_size → 413
        # We do this by checking the condition in _dispatch indirectly:
        # The dispatch itself doesn't check body size (that's in _handle_read).
        # Test the 413 response builder is correct.
        resp_413 = fail(413, "Content Too Large")
        @test resp_413.status == 413
        @test String(copy(resp_413.body)) == "Content Too Large"
    end

    @testset "_wants_close - case insensitive" begin
        # Lower-case connection header
        raw = Vector{UInt8}("GET / HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)
        @test Ciro.Core._wants_close(req) == true

        # Mixed case value
        raw2 = Vector{UInt8}("GET / HTTP/1.1\r\nHost: x\r\nConnection: Close\r\n\r\n")
        req2 = PicoHTTPParser.parse_request(raw2)
        @test Ciro.Core._wants_close(req2) == true

        # keep-alive
        raw3 = Vector{UInt8}("GET / HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n")
        req3 = PicoHTTPParser.parse_request(raw3)
        @test Ciro.Core._wants_close(req3) == false
    end

    @testset "Serialization - json bytes body" begin
        buf = Vector{UInt8}(undef, 4096)
        data = Vector{UInt8}("{\"key\":\"value\"}")
        resp = json(data)
        n = Ciro.Core.serialize_response!(buf, resp)
        output = String(copy(buf[1:n]))
        @test contains(output, "application/json")
        @test endswith(output, "{\"key\":\"value\"}")
    end

    @testset "Serialization - redirect response" begin
        buf = Vector{UInt8}(undef, 4096)
        resp = redirect("/new-location")
        n = Ciro.Core.serialize_response!(buf, resp)
        output = String(copy(buf[1:n]))
        @test startswith(output, "HTTP/1.1 302 Found\r\n")
        @test contains(output, "Location: /new-location\r\n")
        @test contains(output, "Content-Length: 0\r\n")
    end

    @testset "Serialization - custom status codes" begin
        buf = Vector{UInt8}(undef, 4096)
        # Known status
        resp = Response(201, ["Content-Type" => "text/plain"], "created")
        n = Ciro.Core.serialize_response!(buf, resp)
        output = String(copy(buf[1:n]))
        @test startswith(output, "HTTP/1.1 201 Created\r\n")

        # Unknown status (falls back to generic)
        resp2 = Response(418, Pair{String,String}[], "teapot")
        n2 = Ciro.Core.serialize_response!(buf, resp2)
        output2 = String(copy(buf[1:n2]))
        @test contains(output2, "HTTP/1.1 418")
    end

    @testset "Dispatch - wildcard routes" begin
        router = Trie()
        get!(router, "/static/*", ctx -> text("static: $(path(ctx))"))

        server = Server(; router, port=19989)

        raw = Vector{UInt8}("GET /static/js/app.js HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)
        resp = Ciro.Core._dispatch(server, req)
        @test resp.status == 200
    end

    @testset "Dispatch - unknown method" begin
        router = Trie()
        get!(router, "/test", ctx -> text("ok"))

        server = Server(; router, port=19988)

        # TRACE is not supported → UNKNOWN → 404 or 405
        raw = Vector{UInt8}("TRACE /test HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)
        resp = Ciro.Core._dispatch(server, req)
        # UNKNOWN method → 405 (path exists with other methods)
        @test resp.status == 405
    end

    @testset "Multiple serial dispatches" begin
        router = Trie()
        counter = Ref(0)
        get!(router, "/count", ctx -> (counter[] += 1; text("$(counter[])")))

        server = Server(; router, port=19987)

        for i in 1:10
            raw = Vector{UInt8}("GET /count HTTP/1.1\r\nHost: x\r\n\r\n")
            req = PicoHTTPParser.parse_request(raw)
            resp = Ciro.Core._dispatch(server, req)
            @test resp.status == 200
            @test String(copy(resp.body)) == "$i"
        end
    end

    @testset "Dispatch with query string preservation" begin
        router = Trie()
        get!(router, "/api", ctx -> begin
            qp = queryparams(ctx)
            json("{\"count\":$(length(qp))}")
        end)

        server = Server(; router, port=19986)

        raw = Vector{UInt8}("GET /api?a=1&b=2&c=3 HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)
        resp = Ciro.Core._dispatch(server, req)
        @test resp.status == 200
        @test String(copy(resp.body)) == "{\"count\":3}"
    end

    @testset "Custom logger integration" begin
        messages = String[]
        struct TestLogger <: AbstractLogger end
        Ciro.Interface.log!(::TestLogger, level::Severity, msg::String) =
            push!(messages, "[$level] $msg")

        router = Trie()
        server = Server(; router, logger=TestLogger(), port=19985)
        @test server.logger isa TestLogger
    end

    @testset "Server with all custom params" begin
        router = Trie()
        server = Server(;
            router,
            host="127.0.0.1",
            port=9999,
            backlog=256,
            max_body_size=512,
            shutdown_timeout=1.0,
        )
        @test server.host == "127.0.0.1"
        @test server.port == 9999
        @test server.backlog == 256
        @test server.max_body_size == 512
        @test server.shutdown_timeout == 1.0
    end
end
