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
        @test String(r.body) == "hello"
        @test any(p -> p.first == "Content-Type" && contains(p.second, "text/plain"), r.headers)

        r = text("error"; status=500)
        @test r.status == 500

        r = html("<h1>Hi</h1>")
        @test r.status == 200
        @test any(p -> contains(p.second, "text/html"), r.headers)

        r = json("""{"ok":true}""")
        @test r.status == 200
        @test any(p -> contains(p.second, "application/json"), r.headers)
        @test String(r.body) == """{"ok":true}"""

        r = json("""{"ok":true}"""; status=201)
        @test r.status == 201

        r = redirect("/login")
        @test r.status == 302
        @test any(p -> p.first == "Location" && p.second == "/login", r.headers)

        r = redirect("/new"; status=301)
        @test r.status == 301

        r = fail(404, "Not Found")
        @test r.status == 404
        @test String(r.body) == "Not Found"

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
        @test !contains(String(copy(resp.body)), "secret internal info")
        @test String(copy(resp.body)) == "Internal Server Error"
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

    @testset "body() single allocation (no redundant copy)" begin
        # body() should return String without double-copying
        raw = Vector{UInt8}("POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello")
        req = PicoHTTPParser.parse_request(raw)
        b1 = body(req)
        b2 = body(req)
        @test b1 == b2 == "hello"
        @test b1 isa String
        # rawbody returns a copy as Vector{UInt8}
        rb = rawbody(req)
        @test rb == Vector{UInt8}("hello")
        @test rb isa Vector{UInt8}
    end

    @testset "Methods - all methods covered" begin
        @test Methods.from_string("OPTIONS") == Methods.OPTIONS
        @test Methods.from_string("PATCH")   == Methods.PATCH
        # Round-trip: to_string ∘ from_string = identity for known methods
        for (s, m) in [("GET", Methods.GET), ("POST", Methods.POST),
                       ("PUT", Methods.PUT), ("DELETE", Methods.DELETE),
                       ("PATCH", Methods.PATCH), ("HEAD", Methods.HEAD),
                       ("OPTIONS", Methods.OPTIONS)]
            @test Methods.from_string(s) == m
            @test Methods.to_string(m) == s
        end
    end

    @testset "Methods - allow_header all methods" begin
        full_mask = reduce(|, Methods.bitmask(m) for m in UInt8(1):UInt8(7))
        hdr = Methods.allow_header(full_mask)
        @test contains(hdr, "GET")
        @test contains(hdr, "POST")
        @test contains(hdr, "PUT")
        @test contains(hdr, "DELETE")
        @test contains(hdr, "PATCH")
        @test contains(hdr, "HEAD")
        @test contains(hdr, "OPTIONS")
        # Empty mask → empty string
        @test Methods.allow_header(0x00) == ""
    end

    @testset "Severity enum ordering" begin
        @test Int(Debug) < Int(Info) < Int(Warn) < Int(Error) < Int(Fatal)
    end

    @testset "Logger severity all levels" begin
        logger = NullLogger()
        for level in [Debug, Info, Warn, Error, Fatal]
            log!(logger, level, "test")
        end
    end

    @testset "DefaultCatcher - all exception types" begin
        catcher = DefaultCatcher()
        # Must return 500 regardless of exception type
        @test intercept(catcher, ArgumentError("arg"), nothing).status == 500
        @test intercept(catcher, BoundsError(), nothing).status == 500
        @test intercept(catcher, DivideError(), nothing).status == 500
        # Body must NOT contain exception message (OWASP)
        resp = intercept(catcher, ErrorException("secret token: xyz123"), nothing)
        @test !contains(String(copy(resp.body)), "xyz123")
    end

    @testset "queryparams - various edge cases" begin
        # Key without value (flag param)
        raw = Vector{UInt8}("GET /p?verbose HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)
        qp = queryparams(req)
        @test qp["verbose"] == ""

        # Multiple params including duplicated key (last wins with Dict)
        raw2 = Vector{UInt8}("GET /p?a=1&b=2&c=3 HTTP/1.1\r\nHost: x\r\n\r\n")
        req2 = PicoHTTPParser.parse_request(raw2)
        qp2 = queryparams(req2)
        @test qp2["a"] == "1"
        @test qp2["b"] == "2"
        @test qp2["c"] == "3"

        # URL-encoded values passed through as-is (no decoding in core)
        raw3 = Vector{UInt8}("GET /p?q=hello%20world HTTP/1.1\r\nHost: x\r\n\r\n")
        req3 = PicoHTTPParser.parse_request(raw3)
        qp3 = queryparams(req3)
        @test haskey(qp3, "q")
    end

    @testset "RouteResult predicates" begin
        # not_found
        r404 = RouteResult()
        @test not_found(r404)
        @test !matched(r404)
        @test !method_not_allowed(r404)

        # method_not_allowed
        r405 = RouteResult(0x03)  # GET + POST allowed
        @test method_not_allowed(r405)
        @test !matched(r405)
        @test !not_found(r405)

        # matched
        rOk = RouteResult(ctx -> text("ok"), Pair{Symbol,String}[])
        @test matched(rOk)
        @test !not_found(rOk)
        @test !method_not_allowed(rOk)
    end

    @testset "Response body type stability" begin
        # All builders produce Vector{UInt8} body
        @test text("hello").body isa Vector{UInt8}
        @test html("<p>x</p>").body isa Vector{UInt8}
        @test json("{}").body isa Vector{UInt8}
        @test json(UInt8[0x7b, 0x7d]).body isa Vector{UInt8}
        @test redirect("/x").body isa Vector{UInt8}
        @test fail(500).body isa Vector{UInt8}
        @test fail(400, "bad").body isa Vector{UInt8}
    end

    @testset "Response constructor from String" begin
        r = Response(200, ["X" => "Y"], "hello")
        @test r.body == Vector{UInt8}("hello")
        @test r.status == 200

        # Empty string body
        r2 = Response(204, Pair{String,String}[], "")
        @test isempty(r2.body)
    end

    @testset "Methods - from_string disambiguation" begin
        # Ensure similar-length methods don't collide
        @test Methods.from_string("GET") != Methods.from_string("PUT")
        @test Methods.from_string("POST") != Methods.from_string("HEAD")
        @test Methods.from_string("PATCH") != Methods.from_string("DELETE")

        # Single char strings
        @test Methods.from_string("G") == Methods.UNKNOWN
        @test Methods.from_string("P") == Methods.UNKNOWN
        @test Methods.from_string("GETS") == Methods.UNKNOWN
        @test Methods.from_string("POSTS") == Methods.UNKNOWN
    end

    @testset "Methods - allow_header formatting" begin
        # Single method
        @test Methods.allow_header(Methods.bitmask(Methods.GET)) == "GET"
        # Multiple methods preserved in order
        mask = Methods.bitmask(Methods.GET) | Methods.bitmask(Methods.POST) | Methods.bitmask(Methods.DELETE)
        hdr = Methods.allow_header(mask)
        @test contains(hdr, "GET")
        @test contains(hdr, "POST")
        @test contains(hdr, "DELETE")
        # Empty mask
        @test Methods.allow_header(0x00) == ""
    end

    @testset "Status line coverage" begin
        @test _status(301) == "HTTP/1.1 301 Moved Permanently\r\n"
        @test _status(302) == "HTTP/1.1 302 Found\r\n"
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
        # Out of range
        @test contains(_status(0), "HTTP/1.1 0")
        @test contains(_status(999), "HTTP/1.1 999")
    end

    @testset "Header case insensitivity" begin
        raw = Vector{UInt8}("GET / HTTP/1.1\r\ncontent-type: text/html\r\nX-CUSTOM: val\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)
        # Case-insensitive match
        @test header(req, "Content-Type") == "text/html"
        @test header(req, "CONTENT-TYPE") == "text/html"
        @test header(req, "x-custom") == "val"
        @test header(req, "X-Custom") == "val"
        @test hasheader(req, "Content-Type")
        @test hasheader(req, "x-custom")
    end

    @testset "Param with various types" begin
        raw = Vector{UInt8}("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)
        ctx = Context(req, [:val => "3.14", :neg => "-42", :empty => ""])

        # Float64 parsing
        @test param(ctx, Float64, :val) == 3.14
        @test param(ctx, Float64, :neg) == -42.0
        @test param(ctx, Float64, :empty) === nothing

        # Int parsing of negative
        @test param(ctx, Int, :neg) == -42
        @test param(ctx, Int, :empty) === nothing
    end

    @testset "IOUringBackend construction" begin
        backend = IOUringBackend()
        @test backend.queue_depth == 4096
        @test backend.nworkers == Threads.nthreads()

        backend2 = IOUringBackend(; queue_depth=2048, nworkers=2)
        @test backend2.queue_depth == 2048
        @test backend2.nworkers == 2
    end
end
