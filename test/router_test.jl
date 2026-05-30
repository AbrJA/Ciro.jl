using Test
using Ciro
using PicoHTTPParser


@testset "Router" begin

    @testset "Static routes" begin
        r = Trie()
        get!(r, "/", req -> text("root"))
        get!(r, "/about", req -> text("about"))
        post!(r, "/items", req -> text("created"))

        @test matched(route(r, Methods.GET, "/"))
        @test matched(route(r, Methods.GET, "/about"))
        @test matched(route(r, Methods.POST, "/items"))

        # No match — 404
        @test not_found(route(r, Methods.GET, "/missing"))

        # Method not allowed — 405
        result = route(r, Methods.DELETE, "/")
        @test method_not_allowed(result)
        @test result.allowed & Methods.bitmask(Methods.GET) != 0

        result2 = route(r, Methods.POST, "/")
        @test method_not_allowed(result2)
    end

    @testset "Path parameters" begin
        r = Trie()
        get!(r, "/users/:id", req -> text("user"))
        get!(r, "/users/:id/posts/:post_id", req -> text("post"))

        # Single param
        result = route(r, Methods.GET, "/users/42")
        @test matched(result)
        raw = Vector{UInt8}("GET /users/42 HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)
        ctx = Context(req, result.params)
        resp = result.handler(ctx)
        @test resp.status == 200
        @test param(ctx, :id) == "42"

        # Multiple params
        result2 = route(r, Methods.GET, "/users/7/posts/99")
        @test matched(result2)
        ctx2 = Context(req, result2.params)
        resp2 = result2.handler(ctx2)
        @test param(ctx2, :id) == "7"
        @test param(ctx2, :post_id) == "99"

        # No match — wrong depth
        @test not_found(route(r, Methods.GET, "/users"))
        @test not_found(route(r, Methods.GET, "/users/1/posts"))
    end

    @testset "Wildcard routes" begin
        r = Trie()
        get!(r, "/files/*", req -> text("wildcard"))
        get!(r, "/exact", req -> text("exact"))

        @test matched(route(r, Methods.GET, "/files/a"))
        @test matched(route(r, Methods.GET, "/files/a/b/c"))
        @test matched(route(r, Methods.GET, "/exact"))
        @test not_found(route(r, Methods.GET, "/other"))
    end

    @testset "Priority: static > param > wildcard" begin
        r = Trie()
        get!(r, "/items/special", req -> text("static"))
        get!(r, "/items/:id", req -> text("param"))
        get!(r, "/items/*", req -> text("wildcard"))

        raw = Vector{UInt8}("GET /items/special HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)

        # Static wins over param
        result = route(r, Methods.GET, "/items/special")
        @test matched(result)
        resp = result.handler(Context(req, result.params))
        @test resp.body == "static"

        # Param for other values
        result2 = route(r, Methods.GET, "/items/123")
        @test matched(result2)
        resp2 = result2.handler(Context(req, result2.params))
        @test resp2.body == "param"

        # Wildcard for deeper paths
        result3 = route(r, Methods.GET, "/items/a/b")
        @test matched(result3)
        resp3 = result3.handler(Context(req, result3.params))
        @test resp3.body == "wildcard"
    end

    @testset "Multiple methods same path" begin
        r = Trie()
        get!(r, "/resource", req -> text("get"))
        post!(r, "/resource", req -> text("post"))
        put!(r, "/resource", req -> text("put"))
        delete!(r, "/resource", req -> text("delete"))

        raw = Vector{UInt8}("GET /resource HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)

        r1 = route(r, Methods.GET, "/resource")
        @test r1.handler(Context(req, r1.params)).body == "get"

        r2 = route(r, Methods.POST, "/resource")
        @test r2.handler(Context(req, r2.params)).body == "post"

        r3 = route(r, Methods.PUT, "/resource")
        @test r3.handler(Context(req, r3.params)).body == "put"

        r4 = route(r, Methods.DELETE, "/resource")
        @test r4.handler(Context(req, r4.params)).body == "delete"
    end

    @testset "Handler invocation with params" begin
        r = Trie()
        get!(r, "/hello/:name", ctx -> text("Hello, $(param(ctx, :name))!"))

        raw = Vector{UInt8}("GET /hello/Julia HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)

        result = route(r, Methods.GET, "/hello/Julia")
        resp = result.handler(Context(req, result.params))
        @test resp.status == 200
        @test resp.body == "Hello, Julia!"
    end

    @testset "Trailing slashes normalized" begin
        r = Trie()
        get!(r, "/path", req -> text("no-slash"))

        @test matched(route(r, Methods.GET, "/path/"))
        @test matched(route(r, Methods.GET, "/path"))
    end

    @testset "Typed parameters (:id::Int)" begin
        r = Trie()
        get!(r, "/users/:id::Int", ctx -> text("user $(param(ctx, :id))"))
        get!(r, "/files/:name", ctx -> text("file $(param(ctx, :name))"))

        raw = Vector{UInt8}("GET /users/42 HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)

        # Valid integer
        result = route(r, Methods.GET, "/users/42")
        @test matched(result)
        ctx = Context(req, result.params)
        resp = result.handler(ctx)
        @test resp.body == "user 42"
        @test param(ctx, Int, :id) == 42

        # Invalid integer → no match on this param, falls through
        @test not_found(route(r, Methods.GET, "/users/abc"))

        # Negative integer
        result2 = route(r, Methods.GET, "/users/-5")
        @test matched(result2)

        # Untyped param accepts anything
        result3 = route(r, Methods.GET, "/files/report.pdf")
        @test matched(result3)
        resp3 = result3.handler(Context(req, result3.params))
        @test resp3.body == "file report.pdf"
    end

    @testset "Route groups" begin
        r = Trie()
        group!(r, "/api/v1") do g
            get!(g, "/users", req -> text("users list"))
            post!(g, "/users", req -> text("user created"))
            get!(g, "/items/:id", ctx -> text("item $(param(ctx, :id))"))
        end

        raw = Vector{UInt8}("GET /api/v1/users HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)

        result = route(r, Methods.GET, "/api/v1/users")
        @test matched(result)
        @test result.handler(Context(req, result.params)).body == "users list"

        result2 = route(r, Methods.POST, "/api/v1/users")
        @test matched(result2)
        @test result2.handler(Context(req, result2.params)).body == "user created"

        result3 = route(r, Methods.GET, "/api/v1/items/77")
        @test matched(result3)
        @test result3.handler(Context(req, result3.params)).body == "item 77"

        # Outside group → 404
        @test not_found(route(r, Methods.GET, "/api/v1/other"))
    end

    @testset "405 with Allow header in dispatch" begin
        router = Trie()
        get!(router, "/api/items", req -> text("list"))
        post!(router, "/api/items", req -> text("create"))

        server = Server(; router, port=19996)

        # PUT /api/items → 405
        raw = Vector{UInt8}("PUT /api/items HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)
        resp = Ciro.Core._dispatch(server, req)
        @test resp.status == 405
        allow_hdr = header(resp, "Allow")
        @test contains(allow_hdr, "GET")
        @test contains(allow_hdr, "POST")

        # GET /nonexistent → 404
        raw2 = Vector{UInt8}("GET /nonexistent HTTP/1.1\r\nHost: x\r\n\r\n")
        req2 = PicoHTTPParser.parse_request(raw2)
        resp2 = Ciro.Core._dispatch(server, req2)
        @test resp2.status == 404
    end

    @testset "HEAD auto-generated from GET" begin
        r = Trie()
        get!(r, "/page", req -> text("hello"))

        raw = Vector{UInt8}("HEAD /page HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)

        result = route(r, Methods.HEAD, "/page")
        @test matched(result)
        resp = result.handler(Context(req, result.params))
        @test resp.status == 200
        @test isempty(resp.body)  # HEAD = no body
    end

    @testset "Typed parameters - Float64" begin
        r = Trie()
        get!(r, "/scores/:val::Float64", ctx -> text("score: $(param(ctx, :val))"))

        # Valid float
        result = route(r, Methods.GET, "/scores/3.14")
        @test matched(result)

        # Integer is valid float
        result2 = route(r, Methods.GET, "/scores/42")
        @test matched(result2)

        # Negative float
        result3 = route(r, Methods.GET, "/scores/-1.5")
        @test matched(result3)

        # Invalid float
        @test not_found(route(r, Methods.GET, "/scores/abc"))

        # Double dot invalid
        @test not_found(route(r, Methods.GET, "/scores/1.2.3"))
    end

    @testset "Typed parameters - UUID" begin
        r = Trie()
        get!(r, "/items/:uuid::UUID", ctx -> text("uuid"))

        # Valid UUID length (36 chars)
        result = route(r, Methods.GET, "/items/550e8400-e29b-41d4-a716-446655440000")
        @test matched(result)

        # Invalid UUID length
        @test not_found(route(r, Methods.GET, "/items/short"))
        @test not_found(route(r, Methods.GET, "/items/too-long-string-that-is-not-a-valid-uuid"))
    end

    @testset "Nested route groups" begin
        r = Trie()
        group!(r, "/api") do api
            group!(api, "/v2") do v2
                get!(v2, "/items", ctx -> text("nested items"))
                get!(v2, "/items/:id::Int", ctx -> text("item $(param(ctx, :id))"))
            end
        end

        @test matched(route(r, Methods.GET, "/api/v2/items"))
        @test matched(route(r, Methods.GET, "/api/v2/items/5"))
        @test not_found(route(r, Methods.GET, "/api/v2/items/abc"))
        @test not_found(route(r, Methods.GET, "/api/v3/items"))
    end

    @testset "Empty path segments handled" begin
        r = Trie()
        get!(r, "/a/b/c", ctx -> text("abc"))

        # Double slashes are treated as empty segments (skipped)
        @test matched(route(r, Methods.GET, "/a/b/c"))
        @test matched(route(r, Methods.GET, "//a//b//c"))
    end

    @testset "All HTTP methods" begin
        r = Trie()
        get!(r, "/r", ctx -> text("get"))
        post!(r, "/r", ctx -> text("post"))
        put!(r, "/r", ctx -> text("put"))
        delete!(r, "/r", ctx -> text("delete"))
        patch!(r, "/r", ctx -> text("patch"))
        head!(r, "/r", ctx -> text("head"))
        options!(r, "/r", ctx -> text("options"))

        @test matched(route(r, Methods.GET, "/r"))
        @test matched(route(r, Methods.POST, "/r"))
        @test matched(route(r, Methods.PUT, "/r"))
        @test matched(route(r, Methods.DELETE, "/r"))
        @test matched(route(r, Methods.PATCH, "/r"))
        @test matched(route(r, Methods.HEAD, "/r"))
        @test matched(route(r, Methods.OPTIONS, "/r"))
    end

    @testset "Wildcard at root" begin
        r = Trie()
        get!(r, "/*", ctx -> text("catch-all"))

        @test matched(route(r, Methods.GET, "/anything"))
        @test matched(route(r, Methods.GET, "/deep/nested/path"))
    end

    @testset "Prefix normalization in groups" begin
        r = Trie()
        # Without leading slash
        group!(r, "api") do g
            get!(g, "/test", ctx -> text("ok"))
        end
        @test matched(route(r, Methods.GET, "/api/test"))

        # With trailing slash
        group!(r, "/v1/") do g
            get!(g, "/data", ctx -> text("data"))
        end
        @test matched(route(r, Methods.GET, "/v1/data"))
    end
end
