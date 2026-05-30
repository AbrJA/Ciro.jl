using Test
using Ciro
using Ciro.Backend: IOUringBackend
using PicoHTTPParser

@testset "Interfaces" begin

    @testset "Methods" begin
        @test Methods.from_string("GET") == Methods.GET
        @test Methods.from_string("POST") == Methods.POST
        @test Methods.from_string("PUT") == Methods.PUT
        @test Methods.from_string("DELETE") == Methods.DELETE
        @test Methods.from_string("PATCH") == Methods.PATCH
        @test Methods.from_string("HEAD") == Methods.HEAD
        @test Methods.from_string("OPTIONS") == Methods.OPTIONS
        @test Methods.from_string("INVALID") == Methods.UNKNOWN
        @test Methods.from_string("") == Methods.UNKNOWN

        @test Methods.to_string(Methods.GET) == "GET"
        @test Methods.to_string(Methods.POST) == "POST"
        @test Methods.to_string(Methods.UNKNOWN) == "UNKNOWN"
    end

    @testset "Response builders" begin
        r = text("hello")
        @test r.status == 200
        @test String(copy(r.body)) == "hello"
        @test any(p -> p.first == "Content-Type" && contains(p.second, "text/plain"), r.headers)

        r = text("error"; status=500)
        @test r.status == 500

        r = html("<h1>Hi</h1>")
        @test r.status == 200
        @test any(p -> contains(p.second, "text/html"), r.headers)

        r = json("""{"ok":true}""")
        @test r.status == 200
        @test any(p -> contains(p.second, "application/json"), r.headers)
        @test String(copy(r.body)) == """{"ok":true}"""

        r = json("""{"ok":true}"""; status=201)
        @test r.status == 201

        r = redirect("/login")
        @test r.status == 302
        @test any(p -> p.first == "Location" && p.second == "/login", r.headers)

        r = redirect("/new"; status=301)
        @test r.status == 301

        r = fail(404, "Not Found")
        @test r.status == 404
        @test String(copy(r.body)) == "Not Found"

        r = fail(500)
        @test r.status == 500
        @test isempty(r.body)
    end

    @testset "Response header utilities" begin
        r = Response(200, ["Content-Type" => "text/plain", "X-Custom" => "val"], UInt8[])
        @test hasheader(r, "Content-Type")
        @test !hasheader(r, "X-Missing")
        @test header(r, "X-Custom") == "val"
        @test header(r, "X-Missing", "default") == "default"
    end

    @testset "Status lines" begin
        @test status(200) == "HTTP/1.1 200 OK\r\n"
        @test status(404) == "HTTP/1.1 404 Not Found\r\n"
        @test status(500) == "HTTP/1.1 500 Internal Server Error\r\n"
        @test status(201) == "HTTP/1.1 201 Created\r\n"
        @test status(204) == "HTTP/1.1 204 No Content\r\n"
        @test contains(status(418), "HTTP/1.1 418")
    end

    @testset "Request header access" begin
        raw = Vector{UInt8}("GET /test HTTP/1.1\r\nHost: localhost\r\nX-Custom: hello\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)
        @test header(req, "Host") == "localhost"
        @test header(req, "X-Custom") == "hello"
        @test header(req, "Missing", "nope") == "nope"
    end

    @testset "Path/query utilities" begin
        raw = Vector{UInt8}("GET /path?foo=bar&baz=1 HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)
        @test path(req) == "/path"
        @test query(req) == "foo=bar&baz=1"

        raw2 = Vector{UInt8}("GET /noquery HTTP/1.1\r\nHost: x\r\n\r\n")
        req2 = PicoHTTPParser.parse_request(raw2)
        @test path(req2) == "/noquery"
        @test query(req2) == ""
    end

    @testset "NullLogger" begin
        logger = NullLogger()
        log!(logger, Info, "test")
        log!(logger, Error, "error")
    end

    @testset "DefaultCatcher" begin
        catcher = DefaultCatcher()
        resp = intercept(catcher, ErrorException("secret internal info"), nothing)
        @test resp.status == 500
        body_str = String(copy(resp.body))
        @test !contains(body_str, "secret internal info")
        @test body_str == "Internal Server Error"
    end

    @testset "Context construction" begin
        raw = Vector{UInt8}("GET /hello?x=1 HTTP/1.1\r\nHost: localhost\r\nX-Foo: bar\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)

        # No-param constructor
        ctx = Context(req)
        @test isempty(ctx.params)
        @test ctx.req === req

        # With params
        params = [:id => "42", :name => "Julia"]
        ctx2 = Context(req, params)
        @test length(ctx2.params) == 2
    end

    @testset "Context param access" begin
        raw = Vector{UInt8}("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)
        ctx = Context(req, [:id => "99", :score => "3.14", :tag => "hello"])

        # String param
        @test param(ctx, :id) == "99"
        @test param(ctx, :missing) == ""
        @test param(ctx, :missing, "default") == "default"

        # Typed param — Int
        @test param(ctx, Int, :id) == 99
        @test param(ctx, Int, :score) === nothing  # not a valid Int
        @test param(ctx, Int, :missing) === nothing

        # Typed param — Float64
        @test param(ctx, Float64, :score) == 3.14
    end

    @testset "Context request utility forwarding" begin
        raw = Vector{UInt8}("GET /path?a=1&b=2 HTTP/1.1\r\nHost: x\r\nX-Key: val\r\nCookie: session=abc\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)
        ctx = Context(req)

        @test header(ctx, "X-Key") == "val"
        @test header(ctx, "Missing", "def") == "def"
        @test hasheader(ctx, "Host")
        @test !hasheader(ctx, "Ghost")
        @test path(ctx) == "/path"
        @test query(ctx) == "a=1&b=2"
        qp = queryparams(ctx)
        @test qp["a"] == "1"
        @test qp["b"] == "2"
        @test cookie(ctx, "session") == "abc"
        @test cookie(ctx, "missing", "x") == "x"
    end

    @testset "Body utilities" begin
        raw = Vector{UInt8}("POST /data HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"key\":\"val\"}")
        req = PicoHTTPParser.parse_request(raw)
        ctx = Context(req)

        @test body(ctx) == "{\"key\":\"val\"}"
        @test body(req) == "{\"key\":\"val\"}"
        @test rawbody(ctx) == Vector{UInt8}("{\"key\":\"val\"}")
        @test rawbody(req) == Vector{UInt8}("{\"key\":\"val\"}")
        @test content_type(ctx) == "application/json"
        @test content_type(req) == "application/json"
    end

    @testset "Cookie utilities - multiple cookies" begin
        raw = Vector{UInt8}("GET / HTTP/1.1\r\nHost: x\r\nCookie: a=1; b=2; session=xyz\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)
        ctx = Context(req)

        @test cookie(ctx, "a") == "1"
        @test cookie(ctx, "b") == "2"
        @test cookie(ctx, "session") == "xyz"
        @test cookie(ctx, "missing", "nope") == "nope"

        all = cookies(ctx)
        @test length(all) == 3
        @test all["a"] == "1"
        @test all["session"] == "xyz"
    end

    @testset "Cookie utilities - no cookies" begin
        raw = Vector{UInt8}("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)
        @test cookies(req) == Dict{String,String}()
        @test cookie(req, "anything", "fallback") == "fallback"
    end

    @testset "setcookie" begin
        sc = setcookie("token", "abc123"; path="/api", max_age=3600, httponly=true, secure=true, samesite="Strict")
        @test sc.first == "Set-Cookie"
        @test contains(sc.second, "token=abc123")
        @test contains(sc.second, "Path=/api")
        @test contains(sc.second, "Max-Age=3600")
        @test contains(sc.second, "HttpOnly")
        @test contains(sc.second, "Secure")
        @test contains(sc.second, "SameSite=Strict")

        # Default options
        sc2 = setcookie("s", "v")
        @test contains(sc2.second, "Path=/")
        @test contains(sc2.second, "SameSite=Lax")
        @test contains(sc2.second, "HttpOnly")
        @test !contains(sc2.second, "Secure")
        @test !contains(sc2.second, "Max-Age")
    end

    @testset "Query params - edge cases" begin
        # Key without value
        raw = Vector{UInt8}("GET /p?flag&k=v HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)
        qp = queryparams(req)
        @test qp["flag"] == ""
        @test qp["k"] == "v"

        # Empty query
        raw2 = Vector{UInt8}("GET /p? HTTP/1.1\r\nHost: x\r\n\r\n")
        req2 = PicoHTTPParser.parse_request(raw2)
        @test queryparams(req2) == Dict{String,String}()
    end

    @testset "Methods - bitmask operations" begin
        @test Methods.bitmask(Methods.GET) == 0x01
        @test Methods.bitmask(Methods.POST) == 0x02
        @test Methods.bitmask(Methods.PUT) == 0x04
        @test Methods.bitmask(Methods.DELETE) == 0x08
        @test Methods.bitmask(Methods.UNKNOWN) == 0x00

        # allow_header
        mask = Methods.bitmask(Methods.GET) | Methods.bitmask(Methods.POST)
        hdr = Methods.allow_header(mask)
        @test contains(hdr, "GET")
        @test contains(hdr, "POST")
        @test !contains(hdr, "DELETE")
    end

    @testset "Methods - to_string edge cases" begin
        @test Methods.to_string(UInt8(99)) == "UNKNOWN"
        @test Methods.to_string(Methods.PUT) == "PUT"
        @test Methods.to_string(Methods.DELETE) == "DELETE"
        @test Methods.to_string(Methods.PATCH) == "PATCH"
        @test Methods.to_string(Methods.HEAD) == "HEAD"
        @test Methods.to_string(Methods.OPTIONS) == "OPTIONS"
    end

    @testset "Status lines - all codes" begin
        @test status(302) == "HTTP/1.1 302 Found\r\n"
        @test status(301) == "HTTP/1.1 301 Moved Permanently\r\n"
        @test status(304) == "HTTP/1.1 304 Not Modified\r\n"
        @test status(400) == "HTTP/1.1 400 Bad Request\r\n"
        @test status(401) == "HTTP/1.1 401 Unauthorized\r\n"
        @test status(403) == "HTTP/1.1 403 Forbidden\r\n"
        @test status(405) == "HTTP/1.1 405 Method Not Allowed\r\n"
        @test status(408) == "HTTP/1.1 408 Request Timeout\r\n"
        @test status(413) == "HTTP/1.1 413 Content Too Large\r\n"
        @test status(422) == "HTTP/1.1 422 Unprocessable Entity\r\n"
        @test status(429) == "HTTP/1.1 429 Too Many Requests\r\n"
        @test status(502) == "HTTP/1.1 502 Bad Gateway\r\n"
        @test status(503) == "HTTP/1.1 503 Service Unavailable\r\n"
        # Unknown status code
        @test contains(status(999), "HTTP/1.1 999")
        @test contains(status(0), "HTTP/1.1 0")
    end

    @testset "RouteResult constructors" begin
        # Empty (404)
        r = RouteResult()
        @test r.handler === nothing
        @test isempty(r.params)
        @test r.allowed == 0x00
        @test not_found(r)
        @test !matched(r)
        @test !method_not_allowed(r)

        # Method not allowed (405)
        r2 = RouteResult(UInt8(0x03))
        @test r2.handler === nothing
        @test r2.allowed == 0x03
        @test method_not_allowed(r2)
        @test !matched(r2)
        @test !not_found(r2)

        # Matched
        handler = ctx -> text("ok")
        r3 = RouteResult(handler, Pair{Symbol,String}[])
        @test matched(r3)
        @test !not_found(r3)
        @test !method_not_allowed(r3)
    end

    @testset "Severity enum" begin
        @test Int(Debug) == 1
        @test Int(Info) == 2
        @test Int(Warn) == 3
        @test Int(Error) == 4
        @test Int(Fatal) == 5
    end

    @testset "Response with binary body" begin
        body_bytes = UInt8[0x89, 0x50, 0x4E, 0x47]  # PNG header
        r = Response(200, ["Content-Type" => "image/png"], body_bytes)
        @test r.status == 200
        @test r.body == body_bytes
    end

    @testset "json with byte vector body" begin
        data = Vector{UInt8}("{\"a\":1}")
        r = json(data; status=201)
        @test r.status == 201
        @test r.body == data
        @test any(p -> contains(p.second, "application/json"), r.headers)
    end

    @testset "Case-insensitive header matching" begin
        raw = Vector{UInt8}("GET / HTTP/1.1\r\nhost: example.com\r\ncontent-type: text/plain\r\nX-Custom-Header: value\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)

        # Case-insensitive key lookup
        @test header(req, "Host") == "example.com"
        @test header(req, "host") == "example.com"
        @test header(req, "HOST") == "example.com"
        @test header(req, "Content-Type") == "text/plain"
        @test header(req, "content-type") == "text/plain"
        @test header(req, "X-Custom-Header") == "value"
        @test header(req, "x-custom-header") == "value"

        @test hasheader(req, "Host")
        @test hasheader(req, "HOST")
        @test hasheader(req, "host")
        @test !hasheader(req, "X-Missing")
    end

    @testset "Cookie boundary checking (no false match)" begin
        raw = Vector{UInt8}("GET / HTTP/1.1\r\nHost: x\r\nCookie: my_session=xyz; session=abc; data=123\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)

        # Should NOT false-match "session" inside "my_session"
        @test cookie(req, "session") == "abc"
        @test cookie(req, "my_session") == "xyz"
        @test cookie(req, "data") == "123"
        @test cookie(req, "missing", "nope") == "nope"

        # Edge case: cookie at start
        raw2 = Vector{UInt8}("GET / HTTP/1.1\r\nHost: x\r\nCookie: token=abc123\r\n\r\n")
        req2 = PicoHTTPParser.parse_request(raw2)
        @test cookie(req2, "token") == "abc123"

        # Edge case: cookie name is a prefix of another
        raw3 = Vector{UInt8}("GET / HTTP/1.1\r\nHost: x\r\nCookie: id=1; user_id=2; myid=3\r\n\r\n")
        req3 = PicoHTTPParser.parse_request(raw3)
        @test cookie(req3, "id") == "1"
        @test cookie(req3, "user_id") == "2"
        @test cookie(req3, "myid") == "3"
    end

    @testset "AbstractBackend trait" begin
        @test IOUringBackend <: AbstractBackend
        backend = IOUringBackend(; queue_depth=2048, nworkers=2)
        @test backend.queue_depth == 2048
        @test backend.nworkers == 2

        # Default constructor
        default_backend = IOUringBackend()
        @test default_backend.queue_depth == 4096
        @test default_backend.nworkers == Threads.nthreads()
    end
end
