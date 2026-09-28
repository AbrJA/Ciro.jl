using Test
using Ciro
using Sockets

# Sandboxed so the example's helpers cannot collide with the other examples.
const ChatExample = Module()
Base.include(ChatExample, joinpath(@__DIR__, "..", "examples", "ai_chat", "server.jl"))

"""Yielding in-process client (the server shares this process)."""
function _chat_request(port::Integer, data::AbstractString; full::Bool=false)
    sock = Sockets.connect(Sockets.IPv4("127.0.0.1"), port)
    try
        write(sock, data)
        result = Ref("")
        task = @async begin
            head = readuntil(sock, "\r\n\r\n")
            rest = full ? read(sock) : UInt8[]
            result[] = String(head) * String(rest)
        end
        timedwait(() -> istaskdone(task), 10.0) == :ok ||
            error("chat request to port $port timed out")
        return result[]
    finally
        close(sock)
    end
end

function _read_until(sock, needle::String; timeout::Float64=8.0)
    result = Ref("")
    # keep=true so the returned text includes the needle we assert on.
    task = @async (result[] = String(readuntil(sock, needle; keep=true)))
    timedwait(() -> istaskdone(task), timeout) == :ok ||
        error("timed out waiting for $(repr(needle))")
    return result[]
end

@testset "Example: AI chat (in-process sockets)" begin
    port = 20000 + (getpid() % 10000) + 700
    server = ChatExample.build_chat(; port, backend = :sockets,
                                    admin_token = "demo-token", think_s = 0.25,
                                    worker_threads = 4, max_pending = 4)
    task = Threads.@spawn start!(server; nworkers = 1)
    try
        ready = false
        for _ in 1:200
            try
                _chat_request(port, "GET /api/v1/rooms HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                              full = true)
                ready = true
                break
            catch
                sleep(0.05)
            end
        end
        @test ready

        r = _chat_request(port, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"; full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("AI Chat", r)

        r = _chat_request(port, "GET /api/v1/rooms HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                          full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("general", r)
        r = _chat_request(port,
            "GET /api/v1/rooms/1/messages HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
            full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("\"messages\":[]", r)
        r = _chat_request(port,
            "GET /api/v1/rooms/99/messages HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
            full = true)
        @test startswith(r, "HTTP/1.1 404")

        # Open an SSE subscriber, then post a message and watch it fan out.
        sse = Sockets.connect(Sockets.IPv4("127.0.0.1"), port)
        try
            write(sse, "GET /api/v1/rooms/1/events HTTP/1.1\r\nHost: x\r\n\r\n")
            head = String(readuntil(sse, "\r\n\r\n"))
            @test startswith(head, "HTTP/1.1 200")
            @test occursin("text/event-stream", head)
            # The first presence event confirms the subscriber is registered
            # (headers are written before the stream body runs) and is
            # well-formed: `event: presence` followed by `data: `, never a
            # double-prefixed `data: event:` line.
            pres = _read_until(sse, "event: presence\ndata: ")
            @test occursin("event: presence\ndata: ", pres)
            @test !occursin("data: event:", pres)

            r = _chat_request(port,
                "POST /api/v1/rooms/1/messages?as=test HTTP/1.1\r\nHost: x\r\n" *
                "Content-Length: 11\r\nConnection: close\r\n\r\nhello there", full = true)
            @test startswith(r, "HTTP/1.1 200") && occursin("\"reply\"", r)

            msg = _read_until(sse, "event: message\ndata: ")
            @test occursin("event: message\ndata: ", msg)
            @test !occursin("data: event:", msg)
            @test occursin("hello there", _read_until(sse, "hello there"))
            @test occursin("event: typing\ndata: ", _read_until(sse, "event: typing\ndata: "))
            reply = _read_until(sse, "event: message\ndata: ")
            @test occursin("event: message\ndata: ", reply)
            @test !occursin("data: event:", reply)
            @test occursin("How can I help", _read_until(sse, "How can I help"))
        finally
            close(sse)
        end

        # Chunked transcript download.
        r = _chat_request(port,
            "GET /api/v1/rooms/1/transcript HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
            full = true)
        @test startswith(r, "HTTP/1.1 200")
        @test occursin("Transfer-Encoding: chunked", r)
        @test occursin("# transcript", r)
        @test occursin("hello there", r)

        # Import with a per-route limit (8 KB).
        r = _chat_request(port,
            "POST /api/v1/rooms/1/import HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n" *
            "Connection: close\r\n\r\n" * "x"^100, full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("\"imported\"", r)
        r = _chat_request(port,
            "POST /api/v1/rooms/1/import HTTP/1.1\r\nHost: x\r\nContent-Length: 9000\r\n" *
            "Connection: close\r\n\r\n" * "x"^9000, full = true)
        @test startswith(r, "HTTP/1.1 413")

        # Admin stats require the token.
        r = _chat_request(port, "GET /admin/stats HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                          full = true)
        @test startswith(r, "HTTP/1.1 401")
        r = _chat_request(port,
            "GET /admin/stats HTTP/1.1\r\nHost: x\r\nX-Admin-Token: demo-token\r\n" *
            "Connection: close\r\n\r\n", full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("\"rooms\"", r)

        # Overload shedding: 20 concurrent asks against a 4-worker/4-pending pool
        # must serve some and shed some with 503.
        results = Channel{Int}(40)
        for _ in 1:20
            @async begin
                resp = _chat_request(port,
                    "POST /api/v1/rooms/3/messages?as=load HTTP/1.1\r\nHost: x\r\n" *
                    "Content-Length: 2\r\nConnection: close\r\n\r\nhi", full = true)
                m = match(r"HTTP/1\.1 (\d+)", resp)
                put!(results, m === nothing ? 0 : parse(Int, m.captures[1]))
            end
        end
        codes = [take!(results) for _ in 1:20]
        @test count(==(200), codes) >= 1
        @test count(==(503), codes) >= 1
    finally
        stop!(server)
        timedwait(() -> istaskdone(task), 5.0)
    end
end
