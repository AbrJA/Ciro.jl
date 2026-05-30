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
        handler = WithTiming(ctx -> text("ok"))
        req = make_request()
        resp = handler(Context(req))

        @test resp.status == 200
        @test String(copy(resp.body)) == "ok"
        timing_hdr = filter(p -> p.first == "X-Response-Time", resp.headers)
        @test length(timing_hdr) == 1
        @test endswith(timing_hdr[1].second, "ms")
    end

    @testset "WithRequestId" begin
        handler = WithRequestId(ctx -> text("ok"))
        req = make_request()
        resp = handler(Context(req))

        @test resp.status == 200
        id_hdr = filter(p -> p.first == "X-Request-Id", resp.headers)
        @test length(id_hdr) == 1
        @test !isempty(id_hdr[1].second)

        # Each call produces different ID
        resp2 = handler(Context(req))
        id_hdr2 = filter(p -> p.first == "X-Request-Id", resp2.headers)
        @test id_hdr[1].second != id_hdr2[1].second
    end

    @testset "WithCORS - normal request" begin
        handler = WithCORS(ctx -> text("data"))
        req = make_request()
        resp = handler(Context(req))

        @test resp.status == 200
        @test String(copy(resp.body)) == "data"
        cors_hdr = filter(p -> p.first == "Access-Control-Allow-Origin", resp.headers)
        @test length(cors_hdr) == 1
        @test cors_hdr[1].second == "*"
    end

    @testset "WithCORS - preflight OPTIONS" begin
        handler = WithCORS(ctx -> text("should not reach"))
        req = make_options_request()
        resp = handler(Context(req))

        @test resp.status == 204
        @test isempty(resp.body)
        @test any(p -> p.first == "Access-Control-Allow-Origin" && p.second == "*", resp.headers)
        @test any(p -> p.first == "Access-Control-Allow-Methods", resp.headers)
        @test any(p -> p.first == "Access-Control-Allow-Headers", resp.headers)
        @test any(p -> p.first == "Access-Control-Max-Age", resp.headers)
    end

    @testset "WithCORS - custom config" begin
        handler = WithCORS(ctx -> text("ok"); origins="https://mysite.com", max_age=3600)
        req = make_request()
        resp = handler(Context(req))

        cors_hdr = filter(p -> p.first == "Access-Control-Allow-Origin", resp.headers)
        @test cors_hdr[1].second == "https://mysite.com"

        # Preflight
        req_opts = make_options_request()
        resp_opts = handler(Context(req_opts))
        age_hdr = filter(p -> p.first == "Access-Control-Max-Age", resp_opts.headers)
        @test age_hdr[1].second == "3600"
    end

    @testset "cors() factory" begin
        make_cors = cors(origins="https://api.example.com")
        handler = make_cors(ctx -> text("factory"))
        req = make_request()
        resp = handler(Context(req))

        cors_hdr = filter(p -> p.first == "Access-Control-Allow-Origin", resp.headers)
        @test cors_hdr[1].second == "https://api.example.com"
    end

    @testset "WithLogger" begin
        handler = WithLogger(ctx -> text("logged"))
        req = make_request()
        resp = handler(Context(req))
        @test resp.status == 200
        @test String(copy(resp.body)) == "logged"
    end

    @testset "Middleware composition" begin
        composed = WithTiming(WithRequestId(ctx -> text("composed")))
        req = make_request()
        resp = composed(Context(req))

        @test resp.status == 200
        @test String(copy(resp.body)) == "composed"
        @test any(p -> p.first == "X-Response-Time", resp.headers)
        @test any(p -> p.first == "X-Request-Id", resp.headers)
    end

    @testset "Deep composition (3+ layers)" begin
        deep = WithCORS(WithTiming(WithRequestId(ctx -> json("""{"ok":true}"""))))
        req = make_request()
        resp = deep(Context(req))

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

        function (m::WithAuth)(ctx::Context)::Response
            auth = header(ctx, "Authorization")
            auth == "Bearer $(m.token)" || return fail(401, "Unauthorized")
            return m.handler(ctx)
        end

        protected = WithAuth(ctx -> text("secret"), "mytoken")
        req_no_auth = make_request()
        resp_no = protected(Context(req_no_auth))
        @test resp_no.status == 401

        # With auth header
        raw_auth = Vector{UInt8}("GET / HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer mytoken\r\n\r\n")
        req_auth = PicoHTTPParser.parse_request(raw_auth)
        resp_auth = protected(Context(req_auth))
        @test resp_auth.status == 200
        @test String(copy(resp_auth.body)) == "secret"
    end

    @testset "WithSecurityHeaders - defaults" begin
        handler = WithSecurityHeaders(ctx -> text("secure"))
        req = make_request()
        resp = handler(Context(req))

        @test resp.status == 200
        @test any(p -> p.first == "X-Content-Type-Options" && p.second == "nosniff", resp.headers)
        @test any(p -> p.first == "X-Frame-Options" && p.second == "DENY", resp.headers)
        @test any(p -> p.first == "Referrer-Policy" && p.second == "strict-origin-when-cross-origin", resp.headers)
        @test any(p -> p.first == "Strict-Transport-Security", resp.headers)
        @test any(p -> p.first == "Content-Security-Policy" && p.second == "default-src 'self'", resp.headers)
    end

    @testset "WithSecurityHeaders - custom" begin
        handler = WithSecurityHeaders(ctx -> text("ok");
            hsts="", csp="", frame="SAMEORIGIN", referrer="no-referrer")
        req = make_request()
        resp = handler(Context(req))

        @test any(p -> p.first == "X-Frame-Options" && p.second == "SAMEORIGIN", resp.headers)
        @test any(p -> p.first == "Referrer-Policy" && p.second == "no-referrer", resp.headers)
        @test !any(p -> p.first == "Strict-Transport-Security", resp.headers)
        @test !any(p -> p.first == "Content-Security-Policy", resp.headers)
    end

    @testset "WithRateLimit - basic allow" begin
        handler = WithRateLimit(ctx -> text("ok"); max_requests=3, window_seconds=60)
        req = make_request()

        # First 3 should pass
        for _ in 1:3
            resp = handler(Context(req))
            @test resp.status == 200
        end
    end

    @testset "WithRateLimit - exhaustion" begin
        handler = WithRateLimit(ctx -> text("ok"); max_requests=2, window_seconds=60)

        raw = Vector{UInt8}("GET / HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: 1.2.3.4\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)

        handler(Context(req))
        handler(Context(req))
        resp = handler(Context(req))  # 3rd should fail
        @test resp.status == 429
        @test any(p -> p.first == "Retry-After", resp.headers)
    end

    @testset "WithRateLimit - different IPs" begin
        handler = WithRateLimit(ctx -> text("ok"); max_requests=1, window_seconds=60)

        raw1 = Vector{UInt8}("GET / HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: 10.0.0.1\r\n\r\n")
        raw2 = Vector{UInt8}("GET / HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: 10.0.0.2\r\n\r\n")
        req1 = PicoHTTPParser.parse_request(raw1)
        req2 = PicoHTTPParser.parse_request(raw2)

        handler(Context(req1))
        # Different IP should still be allowed
        resp = handler(Context(req2))
        @test resp.status == 200
    end

    @testset "WithRateLimit - X-Real-IP fallback" begin
        handler = WithRateLimit(ctx -> text("ok"); max_requests=1, window_seconds=60)

        raw = Vector{UInt8}("GET / HTTP/1.1\r\nHost: x\r\nX-Real-IP: 192.168.1.1\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)

        resp = handler(Context(req))
        @test resp.status == 200
    end

    @testset "Full middleware stack" begin
        composed = WithRateLimit(
            WithSecurityHeaders(
                WithCORS(
                    WithRequestId(
                        WithTiming(
                            WithLogger(ctx -> json("""{"ok":true}"""))
                        )
                    )
                )
            );
            max_requests=100
        )

        req = make_request()
        resp = composed(Context(req))

        @test resp.status == 200
        @test any(p -> p.first == "X-Response-Time", resp.headers)
        @test any(p -> p.first == "X-Request-Id", resp.headers)
        @test any(p -> p.first == "Access-Control-Allow-Origin", resp.headers)
        @test any(p -> p.first == "X-Content-Type-Options", resp.headers)
    end
end
