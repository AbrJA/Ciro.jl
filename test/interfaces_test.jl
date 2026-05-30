using Test
using Ciro
using Ciro.Backend: IOUringBackend
using PicoHTTPParser

const _status = Ciro.Interface.status

@testset "Interface" begin

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
        @test r.body == "hello"
        @test any(p -> p.first == "Content-Type" && contains(p.second, "text/plain"), r.headers)

        r = text("error"; status=500)
        @test r.status == 500

        r = html("<h1>Hi</h1>")
        @test r.status == 200
        @test any(p -> contains(p.second, "text/html"), r.headers)

        r = json("""{"ok":true}""")
        @test r.status == 200
        @test any(p -> contains(p.second, "application/json"), r.headers)
        @test r.body == """{"ok":true}"""

        r = json("""{"ok":true}"""; status=201)
        @test r.status == 201

        r = redirect("/login")
        @test r.status == 302
        @test any(p -> p.first == "Location" && p.second == "/login", r.headers)

        r = redirect("/new"; status=301)
        @test r.status == 301

        r = fail(404, "Not Found")
        @test r.status == 404
        @test r.body == "Not Found"

        r = fail(500)
        @test r.status == 500
        @test isempty(r.body)
    end

    @testset "Response header utilities" begin
        r = Response(200, ["Content-Type" => "text/plain", "X-Custom" => "val"], "")
        @test hasheader(r, "Content-Type")
        @test !hasheader(r, "X-Missing")
        @test header(r, "X-Custom") == "val"
        @test header(r, "X-Missing", "default") == "default"
    end

    @testset "Status lines" begin
        @test _status(200) == "HTTP/1.1 200 OK\r\n"
        @test _status(404) == "HTTP/1.1 404 Not Found\r\n"
        @test _status(500) == "HTTP/1.1 500 Internal Server Error\r\n"
        @test _status(201) == "HTTP/1.1 201 Created\r\n"
        @test _status(204) == "HTTP/1.1 204 No Content\r\n"
        @test contains(_status(418), "HTTP/1.1 418")
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
        @test !contains(resp.body, "secret internal info")
        @test resp.body == "Internal Server Error"
    end

    @testset "Context construction" begin
        raw = Vector{UInt8}("GET /hello?x=1 HTTP/1.1\r\nHost: localhost\r\nX-Foo: bar\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)

        ctx = Context(req)
        @test isempty(ctx.params)
        @test ctx.req === req

        params = [:id => "42", :name => "Julia"]
        ctx2 = Context(req, params)
        @test length(ctx2.params) == 2
    end

    @testset "Context param access" begin
        raw = Vector{UInt8}("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)
        ctx = Context(req, [:id => "99", :score => "3.14", :tag => "hello"])

        @test param(ctx, :id) == "99"
        @test param(ctx, :missing) == ""
        @test param(ctx, :missing, "default") == "default"

        @test param(ctx, Int, :id) == 99
        @test param(ctx, Int, :score) === nothing
        @test param(ctx, Int, :missing) === nothing

        @test param(ctx, Float64, :score) == 3.14
    end

    @testset "Context request utility forwarding" begin
        raw = Vector{UInt8}("GET /path?a=1&b=2 HTTP/1.1\r\nHost: x\r\nX-Key: val\r\n\r\n")
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

    @testset "Query params - edge cases" begin
        raw = Vector{UInt8}("GET /p?flag&k=v HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)
        qp = queryparams(req)
        @test qp["flag"] == ""
        @test qp["k"] == "v"

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
        @test _status(302) == "HTTP/1.1 302 Found\r\n"
        @test _status(301) == "HTTP/1.1 301 Moved Permanently\r\n"
        @test _status(304) == "HTTP/1.1 304 Not Modified\r\n"
        @test _status(400) == "HTTP/1.1 400 Bad Request\r\n"
        @test _status(401) == "HTTP/1.1 401 Unauthorized\r\n"
        @test _status(403) == "HTTP/1.1 403 Forbidden\r\n"
        @test _status(405) == "HTTP/1.1 405 Method Not Allowed\r\n"
        @test _status(408) == "HTTP/1.1 408 Request Timeout\r\n"
        @test _status(413) == "HTTP/1.1 413 Content Too Large\r\n"
        @test _status(422) == "HTTP/1.1 422 Unprocessable Entity\r\n"
        @test _status(429) == "HTTP/1.1 429 Too Many Requests\r\n"
        @test _status(502) == "HTTP/1.1 502 Bad Gateway\r\n"
        @test _status(503) == "HTTP/1.1 503 Service Unavailable\r\n"
        @test contains(_status(999), "HTTP/1.1 999")
        @test contains(_status(0), "HTTP/1.1 0")
    end

    @testset "RouteResult constructors" begin
        r = RouteResult()
        @test r.handler === nothing
        @test isempty(r.params)
        @test r.allowed == 0x00
        @test not_found(r)
        @test !matched(r)
        @test !method_not_allowed(r)

        r2 = RouteResult(UInt8(0x03))
        @test r2.handler === nothing
        @test r2.allowed == 0x03
        @test method_not_allowed(r2)
        @test !matched(r2)
        @test !not_found(r2)

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
        body_bytes = UInt8[0x89, 0x50, 0x4E, 0x47]
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

    @testset "AbstractBackend trait" begin
        @test IOUringBackend <: AbstractBackend
        backend = IOUringBackend(; queue_depth=2048, nworkers=2)
        @test backend.queue_depth == 2048
        @test backend.nworkers == 2

        default_backend = IOUringBackend()
        @test default_backend.queue_depth == 4096
        @test default_backend.nworkers == Threads.nthreads()
    end
end
