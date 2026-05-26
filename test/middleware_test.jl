using Test
using Ciro
using PicoHTTPParser

function make_request(method::String="GET", path::String="/")
    raw = Vector{UInt8}("$method $path HTTP/1.1\r\nHost: localhost\r\n\r\n")
    PicoHTTPParser.parse_request(raw)
end

function make_options_request(path::String="/")
    raw = Vector{UInt8}("OPTIONS $path HTTP/1.1\r\nHost: localhost\r\nOrigin: http://example.com\r\n\r\n")
    PicoHTTPParser.parse_request(raw)
end

@testset "Middleware" begin

    @testset "WithTiming" begin
        handler = WithTiming(req -> text("ok"))
        req = make_request()
        resp = handler(req)

        @test resp.status == 200
        @test String(copy(resp.body)) == "ok"
        timing_hdr = filter(p -> p.first == "X-Response-Time", resp.headers)
        @test length(timing_hdr) == 1
        @test endswith(timing_hdr[1].second, "ms")
    end

    @testset "WithRequestId" begin
        handler = WithRequestId(req -> text("ok"))
        req = make_request()
        resp = handler(req)

        @test resp.status == 200
        id_hdr = filter(p -> p.first == "X-Request-Id", resp.headers)
        @test length(id_hdr) == 1
        @test !isempty(id_hdr[1].second)

        # Each call produces different ID
        resp2 = handler(req)
        id_hdr2 = filter(p -> p.first == "X-Request-Id", resp2.headers)
        @test id_hdr[1].second != id_hdr2[1].second
    end

    @testset "WithCORS - normal request" begin
        handler = WithCORS(req -> text("data"))
        req = make_request()
        resp = handler(req)

        @test resp.status == 200
        @test String(copy(resp.body)) == "data"
        cors_hdr = filter(p -> p.first == "Access-Control-Allow-Origin", resp.headers)
        @test length(cors_hdr) == 1
        @test cors_hdr[1].second == "*"
    end

    @testset "WithCORS - preflight OPTIONS" begin
        handler = WithCORS(req -> text("should not reach"))
        req = make_options_request()
        resp = handler(req)

        @test resp.status == 204
        @test isempty(resp.body)
        @test any(p -> p.first == "Access-Control-Allow-Origin" && p.second == "*", resp.headers)
        @test any(p -> p.first == "Access-Control-Allow-Methods", resp.headers)
        @test any(p -> p.first == "Access-Control-Allow-Headers", resp.headers)
        @test any(p -> p.first == "Access-Control-Max-Age", resp.headers)
    end

    @testset "WithCORS - custom config" begin
        handler = WithCORS(req -> text("ok"); origins="https://mysite.com", max_age=3600)
        req = make_request()
        resp = handler(req)

        cors_hdr = filter(p -> p.first == "Access-Control-Allow-Origin", resp.headers)
        @test cors_hdr[1].second == "https://mysite.com"

        # Preflight
        req_opts = make_options_request()
        resp_opts = handler(req_opts)
        age_hdr = filter(p -> p.first == "Access-Control-Max-Age", resp_opts.headers)
        @test age_hdr[1].second == "3600"
    end

    @testset "cors() factory" begin
        make_cors = cors(origins="https://api.example.com")
        handler = make_cors(req -> text("factory"))
        req = make_request()
        resp = handler(req)

        cors_hdr = filter(p -> p.first == "Access-Control-Allow-Origin", resp.headers)
        @test cors_hdr[1].second == "https://api.example.com"
    end

    @testset "WithLogger" begin
        handler = WithLogger(req -> text("logged"))
        req = make_request()
        resp = handler(req)
        @test resp.status == 200
        @test String(copy(resp.body)) == "logged"
    end

    @testset "Middleware composition" begin
        composed = WithTiming(WithRequestId(req -> text("composed")))
        req = make_request()
        resp = composed(req)

        @test resp.status == 200
        @test String(copy(resp.body)) == "composed"
        @test any(p -> p.first == "X-Response-Time", resp.headers)
        @test any(p -> p.first == "X-Request-Id", resp.headers)
    end

    @testset "Deep composition (3+ layers)" begin
        deep = WithCORS(WithTiming(WithRequestId(req -> json("""{"ok":true}"""))))
        req = make_request()
        resp = deep(req)

        @test resp.status == 200
        @test String(copy(resp.body)) == """{"ok":true}"""
        @test any(p -> p.first == "Access-Control-Allow-Origin", resp.headers)
        @test any(p -> p.first == "X-Response-Time", resp.headers)
        @test any(p -> p.first == "X-Request-Id", resp.headers)
    end

    @testset "Custom user middleware pattern" begin
        struct WithAuth{H}
            handler :: H
            token   :: String
        end

        function (m::WithAuth)(req::PicoHTTPParser.Request)::Response
            auth = header(req, "Authorization")
            auth == "Bearer $(m.token)" || return fail(401, "Unauthorized")
            return m.handler(req)
        end

        protected = WithAuth(req -> text("secret"), "mytoken")
        req_no_auth = make_request()
        resp_no = protected(req_no_auth)
        @test resp_no.status == 401

        # With auth header
        raw_auth = Vector{UInt8}("GET / HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer mytoken\r\n\r\n")
        req_auth = PicoHTTPParser.parse_request(raw_auth)
        resp_auth = protected(req_auth)
        @test resp_auth.status == 200
        @test String(copy(resp_auth.body)) == "secret"
    end
end
