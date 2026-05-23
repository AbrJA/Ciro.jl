using Test
using CiroRouter
using CiroInterfaces

@testset "CiroRouter" begin

    @testset "Static routes" begin
        r = Router()
        route_get!(r, "/", req -> text("root"))
        route_get!(r, "/about", req -> text("about"))
        route_post!(r, "/items", req -> text("created"))

        # Match
        h = route(r, Methods.GET, "/")
        @test h !== nothing

        h = route(r, Methods.GET, "/about")
        @test h !== nothing

        h = route(r, Methods.POST, "/items")
        @test h !== nothing

        # No match
        @test route(r, Methods.GET, "/missing") === nothing
        @test route(r, Methods.DELETE, "/") === nothing
        @test route(r, Methods.POST, "/") === nothing
    end

    @testset "Path parameters" begin
        r = Router()
        route_get!(r, "/users/:id", req -> text("user"))
        route_get!(r, "/users/:id/posts/:post_id", req -> text("post"))

        # Single param
        h = route(r, Methods.GET, "/users/42")
        @test h !== nothing
        # Call the handler — it should set task-local params
        using PicoHTTPParser
        raw = Vector{UInt8}("GET /users/42 HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)
        resp = h(req)
        @test resp.status == 200
        @test route_param(:id) == "42"

        # Multiple params
        h2 = route(r, Methods.GET, "/users/7/posts/99")
        @test h2 !== nothing
        resp2 = h2(req)
        @test route_param(:id) == "7"
        @test route_param(:post_id) == "99"

        # No match — wrong depth
        @test route(r, Methods.GET, "/users") === nothing
        @test route(r, Methods.GET, "/users/1/posts") === nothing
    end

    @testset "Wildcard routes" begin
        r = Router()
        route_get!(r, "/files/*", req -> text("wildcard"))
        route_get!(r, "/exact", req -> text("exact"))

        @test route(r, Methods.GET, "/files/a") !== nothing
        @test route(r, Methods.GET, "/files/a/b/c") !== nothing
        @test route(r, Methods.GET, "/exact") !== nothing
        @test route(r, Methods.GET, "/other") === nothing
    end

    @testset "Priority: static > param > wildcard" begin
        r = Router()
        route_get!(r, "/items/special", req -> text("static"))
        route_get!(r, "/items/:id", req -> text("param"))
        route_get!(r, "/items/*", req -> text("wildcard"))

        using PicoHTTPParser
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
        r = Router()
        route_get!(r, "/resource", req -> text("get"))
        route_post!(r, "/resource", req -> text("post"))
        route_put!(r, "/resource", req -> text("put"))
        route_delete!(r, "/resource", req -> text("delete"))

        using PicoHTTPParser
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

    @testset "Handler invocation" begin
        r = Router()
        route_get!(r, "/hello/:name", req -> text("Hello, $(route_param(:name))!"))

        using PicoHTTPParser
        raw = Vector{UInt8}("GET /hello/Julia HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)

        h = route(r, Methods.GET, "/hello/Julia")
        resp = h(req)
        @test resp.status == 200
        @test String(copy(resp.body)) == "Hello, Julia!"
    end

    @testset "Trailing slashes" begin
        r = Router()
        route_get!(r, "/path", req -> text("no-slash"))

        # Trailing slash is normalized — matches (lenient mode)
        @test route(r, Methods.GET, "/path/") !== nothing
        @test route(r, Methods.GET, "/path") !== nothing
    end
end
