using Test
using Ciro
using PicoHTTPParser

@testset "Router" begin

    @testset "Static routes" begin
        r = Trie()
        get!(r, "/", req -> text("root"))
        get!(r, "/about", req -> text("about"))
        post!(r, "/items", req -> text("created"))

        @test route(r, Methods.GET, "/") !== nothing
        @test !(route(r, Methods.GET, "/") isa MethodNotAllowed)
        @test route(r, Methods.GET, "/about") !== nothing
        @test route(r, Methods.POST, "/items") !== nothing

        # No match — 404
        @test route(r, Methods.GET, "/missing") === nothing

        # Method not allowed — 405
        result = route(r, Methods.DELETE, "/")
        @test result isa MethodNotAllowed
        @test Methods.GET in result.allowed

        result2 = route(r, Methods.POST, "/")
        @test result2 isa MethodNotAllowed
    end

    @testset "Path parameters" begin
        r = Trie()
        get!(r, "/users/:id", req -> text("user"))
        get!(r, "/users/:id/posts/:post_id", req -> text("post"))

        # Single param
        h = route(r, Methods.GET, "/users/42")
        @test h !== nothing
        raw = Vector{UInt8}("GET /users/42 HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)
        resp = h(req)
        @test resp.status == 200
        @test param(:id) == "42"

        # Multiple params
        h2 = route(r, Methods.GET, "/users/7/posts/99")
        @test h2 !== nothing
        resp2 = h2(req)
        @test param(:id) == "7"
        @test param(:post_id) == "99"

        # No match — wrong depth
        @test route(r, Methods.GET, "/users") === nothing
        @test route(r, Methods.GET, "/users/1/posts") === nothing
    end

    @testset "Wildcard routes" begin
        r = Trie()
        get!(r, "/files/*", req -> text("wildcard"))
        get!(r, "/exact", req -> text("exact"))

        @test route(r, Methods.GET, "/files/a") !== nothing
        @test route(r, Methods.GET, "/files/a/b/c") !== nothing
        @test route(r, Methods.GET, "/exact") !== nothing
        @test route(r, Methods.GET, "/other") === nothing
    end

    @testset "Priority: static > param > wildcard" begin
        r = Trie()
        get!(r, "/items/special", req -> text("static"))
        get!(r, "/items/:id", req -> text("param"))
        get!(r, "/items/*", req -> text("wildcard"))

        raw = Vector{UInt8}("GET /items/special HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)

        # Static wins over param
        h = route(r, Methods.GET, "/items/special")
        @test h !== nothing
        resp = h(req)
        @test String(copy(resp.body)) == "static"

        # Param for other values
        h2 = route(r, Methods.GET, "/items/123")
        @test h2 !== nothing
        resp2 = h2(req)
        @test String(copy(resp2.body)) == "param"

        # Wildcard for deeper paths
        h3 = route(r, Methods.GET, "/items/a/b")
        @test h3 !== nothing
        resp3 = h3(req)
        @test String(copy(resp3.body)) == "wildcard"
    end

    @testset "Multiple methods same path" begin
        r = Trie()
        get!(r, "/resource", req -> text("get"))
        post!(r, "/resource", req -> text("post"))
        put!(r, "/resource", req -> text("put"))
        delete!(r, "/resource", req -> text("delete"))

        raw = Vector{UInt8}("GET /resource HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)

        h1 = route(r, Methods.GET, "/resource")
        @test String(copy(h1(req).body)) == "get"

        h2 = route(r, Methods.POST, "/resource")
        @test String(copy(h2(req).body)) == "post"

        h3 = route(r, Methods.PUT, "/resource")
        @test String(copy(h3(req).body)) == "put"

        h4 = route(r, Methods.DELETE, "/resource")
        @test String(copy(h4(req).body)) == "delete"
    end

    @testset "Handler invocation with params" begin
        r = Trie()
        get!(r, "/hello/:name", req -> text("Hello, $(param(:name))!"))

        raw = Vector{UInt8}("GET /hello/Julia HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)

        h = route(r, Methods.GET, "/hello/Julia")
        resp = h(req)
        @test resp.status == 200
        @test String(copy(resp.body)) == "Hello, Julia!"
    end

    @testset "Trailing slashes normalized" begin
        r = Trie()
        get!(r, "/path", req -> text("no-slash"))

        @test route(r, Methods.GET, "/path/") !== nothing
        @test route(r, Methods.GET, "/path") !== nothing
    end

    @testset "Typed parameters (:id::Int)" begin
        r = Trie()
        get!(r, "/users/:id::Int", req -> text("user $(param(:id))"))
        get!(r, "/files/:name", req -> text("file $(param(:name))"))

        raw = Vector{UInt8}("GET /users/42 HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)

        # Valid integer
        h = route(r, Methods.GET, "/users/42")
        @test h !== nothing
        @test !(h isa MethodNotAllowed)
        resp = h(req)
        @test String(copy(resp.body)) == "user 42"
        @test param(Int, :id) == 42

        # Invalid integer → no match on this param, falls through
        @test route(r, Methods.GET, "/users/abc") === nothing

        # Negative integer
        h2 = route(r, Methods.GET, "/users/-5")
        @test h2 !== nothing

        # Untyped param accepts anything
        h3 = route(r, Methods.GET, "/files/report.pdf")
        @test h3 !== nothing
        resp3 = h3(req)
        @test String(copy(resp3.body)) == "file report.pdf"
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
end
