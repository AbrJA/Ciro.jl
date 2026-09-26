using Test
using Ciro
using PicoHTTPParser

@testset "Runtime" begin

    @testset "Application construction" begin
        router = Trie()
        get!(router, "/ping", _ -> text("pong"))
        app = Application(; router)
        @test app.router === router
        @test app.executor isa SyncExecutor
        @test app.transport isa FakeTransport
        @test !app.frozen
        @test !app.running
    end

    @testset "Dispatch" begin
        router = Trie()
        get!(router, "/ok", _ -> text("fine"))
        get!(router, "/users/:id", ctx -> text(param(ctx, :id)))
        post!(router, "/submit", _ -> text("accepted"; status=201))
        app = Application(; router)

        r1 = dispatch(app, Request("GET", "/ok"))
        @test r1.status == 200
        @test String(r1.body) == "fine"

        r2 = dispatch(app, Request("GET", "/users/7"))
        @test r2.status == 200
        @test String(r2.body) == "7"

        r3 = dispatch(app, Request("GET", "/missing"))
        @test r3.status == 404

        r4 = dispatch(app, Request("PUT", "/ok"))
        @test r4.status == 405
        @test contains(header(r4, "Allow"), "GET")

        r5 = dispatch(app, Request("POST", "/submit"))
        @test r5.status == 201
    end

    @testset "Handler errors intercepted" begin
        router = Trie()
        get!(router, "/boom", _ -> error("internal"))
        app = Application(; router)
        resp = dispatch(app, Request("GET", "/boom"))
        @test resp.status == 500
        @test !contains(String(resp.body), "internal")
    end

    @testset "Non-Response handler returns text" begin
        router = Trie()
        get!(router, "/num", _ -> 42)
        app = Application(; router)
        resp = dispatch(app, Request("GET", "/num"))
        @test resp.status == 200
        @test String(resp.body) == "42"
    end

    @testset "Custom executor in runtime" begin
        struct TaggingExecutor <: AbstractExecutor end
        Ciro.Interface.execute!(::TaggingExecutor, endpoint, ctx) =
            text("tagged:$(String(rawbody(ctx)))")
        router = Trie()
        post!(router, "/echo", _ -> text("raw"))
        app = Application(; router, executor=TaggingExecutor())
        resp = dispatch(app, Request("POST", "/echo"; body=Vector{UInt8}("hello")))
        @test String(resp.body) == "tagged:hello"
    end

    @testset "Custom router contract" begin
        struct SingleRouteRouter <: AbstractRouter end
        Ciro.Interface.route(::SingleRouteRouter, method::UInt8, path::AbstractString) =
            (method == Methods.GET && path == "/only") ?
                RouteResult(Endpoint(_ -> text("only")), Pair{Symbol,String}[]) :
                RouteResult()
        app = Application(; router=SingleRouteRouter())
        @test dispatch(app, Request("GET", "/only")).status == 200
        @test dispatch(app, Request("GET", "/other")).status == 404
    end

    @testset "Freeze semantics" begin
        router = Trie()
        app = Application(; router)
        get!(router, "/before", _ -> text("ok"))
        freeze!(app)
        @test app.frozen
        @test_throws ArgumentError register!(app, Methods.GET, "/after", _ -> text("late"))
        @test freeze!(app) === app  # idempotent
    end

    @testset "FakeTransport" begin
        t = FakeTransport()
        @test transport_state(t) == :created

        token = enqueue!(t, Request("GET", "/x"))
        @test token.owner == t.owner
        @test !isempty(t.pending)

        router = Trie()
        get!(router, "/x", _ -> text("ok"))
        app = Application(; router, transport=t)
        @test run_once!(app)
        resp = response_for(t, token)
        @test resp !== nothing
        @test resp.status == 200
        @test !run_once!(app)
    end

    @testset "FakeTransport ownership and lifecycle" begin
        t1 = FakeTransport()
        t2 = FakeTransport()
        token = enqueue!(t1, Request("GET", "/x"))
        @test_throws ArgumentError send_response!(t2, token, text("bad"))
        @test_throws ArgumentError close!(t2, token)
        send_response!(t1, token, text("ok"))
        @test_throws ArgumentError send_response!(t1, token, text("duplicate"))
        close!(t1, token)
        token2 = enqueue!(t1, Request("GET", "/y"))
        close!(t1, token2)
        @test_throws ArgumentError send_response!(t1, token2, text("late"))
    end

    @testset "run_once! skips closed tokens" begin
        t = FakeTransport()
        token = enqueue!(t, Request("GET", "/x"))
        close!(t, token)
        router = Trie()
        get!(router, "/x", _ -> text("ok"))
        app = Application(; router, transport=t)
        @test run_once!(app)
        @test response_for(t, token) === nothing
    end

    @testset "serve! drains fake transport and stops" begin
        t = FakeTransport()
        router = Trie()
        get!(router, "/a", _ -> text("a"))
        get!(router, "/b", _ -> text("b"))
        app = Application(; router, transport=t)
        t1 = enqueue!(t, Request("GET", "/a"))
        t2 = enqueue!(t, Request("GET", "/b"))
        serve!(app)
        @test String(response_for(t, t1).body) == "a"
        @test String(response_for(t, t2).body) == "b"
        @test transport_state(t) == :stopped
        @test !app.running
        @test app.frozen
    end

    @testset "serve! freezes configuration" begin
        t = FakeTransport()
        router = Trie()
        get!(router, "/fixed", _ -> text("ok"))
        app = Application(; router, transport=t)
        serve!(app)
        @test_throws ArgumentError register!(app, Methods.GET, "/late", _ -> text("late"))
    end

    @testset "Duplicate response rejected" begin
        t = FakeTransport()
        token = enqueue!(t, Request("GET", "/x"))
        t.state = :running
        send_response!(t, token, text("first"))
        @test_throws ArgumentError send_response!(t, token, text("second"))
    end

    @testset "stop! is shared by Server and Application" begin
        router = Trie()
        get!(router, "/x", _ -> text("ok"))

        app = Application(; router)
        @test stop!(app) === app
        @test !app.running

        server = Server(; router)
        @test stop!(server) === server
        @test !server._running[]
    end

    @testset "Application and Server share one pipeline" begin
        router = Trie()
        get!(router, "/ok", _ -> text("fine"))
        get!(router, "/users/:id::Int", ctx -> json("{\"id\":$(param(ctx, Int, :id))}"))
        post!(router, "/only", _ -> text("posted"))

        app = Application(; router)
        server = Server(; router)

        for (m, target) in [("GET", "/ok"), ("GET", "/users/7"), ("GET", "/missing"),
                            ("GET", "/users/abc"), ("PUT", "/ok"), ("POST", "/only")]
            req = Request(m, target)
            a = dispatch(app, req)
            b = Ciro.Core._dispatch(server, req)
            @test a.status == b.status
            @test String(a.body) == String(b.body)
            @test header(a, "Allow") == header(b, "Allow")
        end
    end
end
