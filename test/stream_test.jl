using Test
using Ciro

@testset "Streaming" begin

    @testset "Stream builders" begin
        s = stream() do w
            write(w, "x")
        end
        @test s isa Ciro.Stream
        @test s.status == 200
        @test isempty(s.headers)

        s2 = stream(; status=201, headers=["X-Test" => "1"], content_type="text/plain") do w
            write(w, "x")
        end
        @test s2.status == 201
        @test ("Content-Type" => "text/plain") in s2.headers
        @test ("X-Test" => "1") in s2.headers

        e = sse() do send
            send("hi")
        end
        @test ("Content-Type" => "text/event-stream") in e.headers
        @test ("Cache-Control" => "no-cache") in e.headers
    end

    @testset "sync executor rejects Stream" begin
        router = Trie()
        get!(router, "/s", _ -> stream() do w
            write(w, "x")
        end)
        app = Application(; router)
        @test dispatch(app, Request("GET", "/s")).status == 500
    end

    @testset "SSE framing" begin
        io = IOBuffer()
        strm = sse() do send
            send("one"; event="tick", id="1")
            send("two\nlines"; retry=1000)
        end
        w = Ciro.StreamWriter(b -> (write(io, b); true), () -> nothing, :open)
        strm.body(w)
        out = String(take!(io))
        @test out == "id: 1\nevent: tick\ndata: one\n\nretry: 1000\ndata: two\ndata: lines\n\n"
    end

    @testset "StreamWriter contract" begin
        sent = Vector{UInt8}[]
        closed = Ref(false)
        w = Ciro.StreamWriter(b -> (push!(sent, b); true), () -> (closed[] = true), :open)
        println(w, "hello")
        @test !closed[]
        @test String(reduce(vcat, sent)) == "hello\n"
        close(w)
        @test closed[]
        @test !isopen(w)
        @test_throws Ciro.StreamClosedError write(w, "late")

        failing = Ciro.StreamWriter(_ -> false, () -> nothing, :open)
        @test_throws Ciro.StreamClosedError write(failing, "x")
    end

    @testset "worker/loop stream protocol" begin
        st = Ciro.HTTP.HTTPConn(nothing)
        outbound = Channel{Ciro.Core._Outbound}(Inf)
        strm = stream() do w
            write(w, "a")
            write(w, "b")
            close(w)
        end
        task = Threads.@spawn Ciro.Core._run_stream(outbound, st, st.gen, strm)

        msg = take!(outbound)
        @test msg isa Ciro.Core._StreamBegin
        @test msg.stream === strm
        put!(msg.ack, true)

        msg = take!(outbound)
        @test msg isa Ciro.Core._StreamChunk && String(msg.bytes) == "a"
        put!(msg.ack, true)

        msg = take!(outbound)
        @test msg isa Ciro.Core._StreamChunk && String(msg.bytes) == "b"
        put!(msg.ack, true)

        msg = take!(outbound)
        @test msg isa Ciro.Core._StreamEnd
        @test timedwait(() -> istaskdone(task), 5.0) == :ok
    end

    @testset "client disconnect stops the worker" begin
        st = Ciro.HTTP.HTTPConn(nothing)
        outbound = Channel{Ciro.Core._Outbound}(Inf)
        strm = stream() do w
            for _ in 1:1000
                write(w, "x")
            end
        end
        task = Threads.@spawn Ciro.Core._run_stream(outbound, st, st.gen, strm)

        msg = take!(outbound)   # stream head
        put!(msg.ack, true)
        msg = take!(outbound)   # first chunk
        @test msg isa Ciro.Core._StreamChunk
        close(msg.ack)          # peer went away: next flush fails

        @test timedwait(() -> istaskdone(task), 5.0) == :ok
    end

    @testset "chunk framing helpers" begin
        buf = Vector{UInt8}(undef, 64)
        n = Ciro.HTTP.serialize_chunk!(buf, Vector{UInt8}("hello"))
        @test String(buf[1:n]) == "5\r\nhello\r\n"
        n = Ciro.HTTP.serialize_chunk!(buf, Vector{UInt8}(repeat("x", 255)))
        @test startswith(String(buf[1:n]), "ff\r\n")
        n = Ciro.HTTP.serialize_last_chunk!(buf)
        @test String(buf[1:n]) == "0\r\n\r\n"
        n = Ciro.HTTP.serialize_head!(buf, 200, Pair{String,String}[], true, false)
        head = String(buf[1:n])
        @test startswith(head, "HTTP/1.1 200 OK\r\n")
        @test occursin("Transfer-Encoding: chunked", head)
        @test endswith(head, "\r\n\r\n")
    end
end
