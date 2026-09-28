using Test
using Ciro
using Sockets

# Sandbox the example in its own module so its helpers cannot collide.
const Playground = Module()
Base.include(Playground, joinpath(@__DIR__, "..", "examples", "playground", "server.jl"))

const _PLAYGROUND_BACKEND = (Sys.islinux() && isfile(Ciro.Backend._LIB)) ? :uring : :sockets

"""Yielding in-process client; `nothing` on timeout. Use `Connection: close`
with `full=true` so the body is read to EOF."""
function _preq(port::Integer, data::AbstractString; full::Bool=false, timeout::Float64=10.0)
    sock = try
        Sockets.connect(Sockets.IPv4("127.0.0.1"), port)
    catch
        return nothing          # not listening yet / refused
    end
    try
        write(sock, data)
        result = Ref("")
        task = @async begin
            head = readuntil(sock, "\r\n\r\n"; keep=true)
            rest = full ? read(sock) : UInt8[]
            result[] = String(head) * String(rest)
        end
        timedwait(() -> istaskdone(task), timeout) == :ok || return nothing
        return result[]
    finally
        close(sock)
    end
end

"""Read from an SSE socket until `needle` (delimiter kept)."""
function _read_until(sock, needle::String; timeout::Float64=10.0)
    result = Ref("")
    task = @async (result[] = String(readuntil(sock, needle; keep=true)))
    timedwait(() -> istaskdone(task), timeout) == :ok ||
        error("timed out waiting for $(repr(needle))")
    return result[]
end

_req(port, method, path; body::String="", full::Bool=false, timeout::Float64=10.0) =
    _preq(port,
          "$method $path HTTP/1.1\r\nHost: x\r\n" *
          (isempty(body) ? "" : "Content-Length: $(sizeof(body))\r\n") *
          "Connection: close\r\n\r\n" * body;
          full, timeout)

_status(resp) = resp === nothing ? 0 : parse(Int, split(resp, " ")[2])

_body(resp::AbstractString) = begin
    i = findfirst("\r\n\r\n", resp)
    i === nothing ? "" : resp[i.stop+1:end]
end

"""Decode an HTTP/1.1 chunked body (browsers do this for us)."""
function _dechunk(raw::AbstractString)
    io = IOBuffer(String(raw))
    out = IOBuffer()
    while !eof(io)
        line = readline(io)
        isempty(line) && continue
        n = tryparse(Int, split(line, ";")[1], base = 16)
        (n === nothing || n == 0) && break
        write(out, read(io, n))
        readline(io)   # CRLF after chunk data
    end
    return String(take!(out))
end

@testset "Example: playground worker budget" begin
    # Both servers share the process; leave room for the sync engine and handlers.
    @test Playground.async_worker_budget(8, 8) == 6
    @test Playground.async_worker_budget(4, 8) == 4
    @test Playground.async_worker_budget(1, 1) == 1
    @test Playground.async_worker_budget(8, 2) == 1
end

@testset "Example: playground (in-process, $(_PLAYGROUND_BACKEND))" begin
    aport = 20000 + (getpid() % 10000) + 800
    sport = aport + 1
    backend = _PLAYGROUND_BACKEND

    async_server = Playground.build_playground(;
        port = aport, backend, executor = AsyncExecutor(worker_threads = 8, max_pending = 24),
        admin_token = "demo-token", token_ms = 10, think_s = 0.5,
        log_io = devnull, ports = (aport, sport))
    sync_server = Playground.build_playground(;
        port = sport, backend, executor = SyncExecutor(),
        admin_token = "demo-token", token_ms = 10, think_s = 0.5,
        log_io = devnull, ports = (aport, sport))

    async_task = Threads.@spawn start!(async_server; nworkers = 1)
    sync_task = Threads.@spawn start!(sync_server; nworkers = 1)
    try
        for (name, port) in (("async", aport), ("sync", sport))
            ready = false
            for _ in 1:200
                if _status(_req(port, "GET", "/healthz"; full = true, timeout = 2.0)) == 200
                    ready = true
                    break
                end
                sleep(0.05)
            end
            @test ready
        end

        # Page, assets, traversal guard; both servers advertise the same ports
        for port in (aport, sport)
            r = _req(port, "GET", "/"; full = true)
            @test startswith(r, "HTTP/1.1 200") && occursin("Playground", r)
            @test occursin("\"async\":$aport,\"sync\":$sport", r)
        end
        r = _req(aport, "GET", "/static/app.js"; full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("EventSource", r)
        @test _status(_req(aport, "GET", "/static/../server.jl"; full = true)) == 404

        # Probes and extension points
        r = _req(aport, "GET", "/healthz"; full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("\"status\":\"ok\"", r)
        @test occursin("X-Service: mock-model", r)
        @test _status(_req(aport, "GET", "/readyz"; full = true)) == 200

        # CORS: the UI switches between two origins, so every response and the
        # OPTIONS preflight must allow it (admin/DELETE trigger preflight).
        r = _req(aport, "GET", "/api/v1/models"; full = true)
        @test occursin("Access-Control-Allow-Origin: *", r)
        r = _req(aport, "OPTIONS", "/api/v1/predict"; full = true)
        @test startswith(r, "HTTP/1.1 204")
        @test occursin("Access-Control-Allow-Methods:", r) && occursin("POST", r)
        @test occursin("Access-Control-Allow-Headers:", r) && occursin("X-Admin-Token", r)

        # SSE token stream: several ordered deltas, then the full text
        sse = Sockets.connect(Sockets.IPv4("127.0.0.1"), aport)
        try
            write(sse, "GET /api/v1/generate?prompt=ping&style=plain HTTP/1.1\r\nHost: x\r\n\r\n")
            head = String(readuntil(sse, "\r\n\r\n"))
            @test startswith(head, "HTTP/1.1 200") && occursin("text/event-stream", head)
            @test occursin("Access-Control-Allow-Origin: *", head)   # cross-origin SSE
            t0 = time()
            raw = _read_until(sse, "event: done")
            elapsed = time() - t0
            @test count("event: delta", raw) >= 5          # incremental, not one blob
            @test occursin("event: delta\ndata: ", raw)    # well-formed framing
            @test !occursin("data: event:", raw)
            @test occursin("ping", raw)
            @test elapsed >= 0.05                          # ~20 tokens * 10 ms
        finally
            close(sse)
        end

        # Chunked text variant of the same generation
        r = _req(aport, "GET", "/api/v1/generate.txt?prompt=ping&style=haiku"; full = true)
        @test startswith(r, "HTTP/1.1 200")
        @test occursin("Transfer-Encoding: chunked", r)
        @test occursin("Tokens arrive one at a time", _dechunk(_body(r)))

        # Async executor: the loop stays responsive during a slow handler
        slow = @async _req(aport, "POST", "/api/v1/predict?model=2"; body = "1,2,3")
        sleep(0.05)
        t0 = time()
        health = _req(aport, "GET", "/healthz"; full = true, timeout = 3.0)
        ping_ms = (time() - t0) * 1000
        @test _status(health) == 200
        @test ping_ms < 250
        @test _status(fetch(slow)) == 200

        # Sync executor: with one engine a slow handler blocks other requests
        slow = @async _req(sport, "POST", "/api/v1/predict?model=2"; body = "1,2,3")
        sleep(0.05)
        t0 = time()
        health = _req(sport, "GET", "/healthz"; full = true, timeout = 0.2)
        blocked_ms = (time() - t0) * 1000
        if backend === :uring
            @test health === nothing || blocked_ms >= 300   # blocked behind the handler
        else
            @test _status(health) == 200                    # sockets: task per connection
        end
        @test _status(fetch(slow)) == 200

        # Streaming requires the async executor: the sync server answers 500 JSON
        r = _req(sport, "GET", "/api/v1/generate?prompt=x"; full = true)
        @test startswith(r, "HTTP/1.1 500")
        @test occursin("\"error\":\"internal_server_error\"", r)

        # Routing: typed params, 404, 405 + Allow, redirect, HEAD, wildcard, echo
        r = _req(aport, "GET", "/api/v1/models"; full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("linear", r)
        r = _req(aport, "GET", "/api/v1/models/2"; full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("\"mlp\"", r)
        @test _status(_req(aport, "GET", "/api/v1/models/99"; full = true)) == 404
        r = _req(aport, "DELETE", "/api/v1/predict"; full = true)
        @test startswith(r, "HTTP/1.1 405") && occursin("Allow:", r) && occursin("POST", r)
        r = _req(aport, "GET", "/old"; full = true)
        @test startswith(r, "HTTP/1.1 302") && occursin("Location: /", r)
        r = _req(aport, "HEAD", "/api/v1/models/1"; full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("Content-Length:", r)
        r = _req(aport, "GET", "/api/v1/files/a/b/c"; full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("\"path\":\"a/b/c\"", r)
        r = _req(aport, "GET", "/api/v1/echo?q=hi&n=2"; full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("\"q\":\"hi\"", r)
        @test _status(_req(aport, "GET", "/missing"; full = true)) == 404

        # Custom catcher returns JSON 500 with the exception type
        r = _req(aport, "GET", "/api/v1/boom"; full = true)
        @test startswith(r, "HTTP/1.1 500") && occursin("\"type\":", r)

        # copy(ctx) retention demo
        @test _status(_req(aport, "GET", "/api/v1/audit"; full = true)) == 200

        # Per-route upload limit
        r = _req(aport, "POST", "/api/v1/upload"; body = "x"^100, full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("\"received\":100", r)
        @test _status(_req(aport, "POST", "/api/v1/upload"; body = "x"^8000, full = true)) == 413

        # Admin token, log tail, metrics (401 still carries CORS so the UI can
        # show the status instead of a network error)
        r = _req(aport, "GET", "/admin/stats"; full = true)
        @test startswith(r, "HTTP/1.1 401")
        @test occursin("Access-Control-Allow-Origin: *", r)
        r = _preq(aport,
            "GET /admin/stats HTTP/1.1\r\nHost: x\r\nX-Admin-Token: demo-token\r\n" *
            "Connection: close\r\n\r\n"; full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("\"active_connections\"", r)
        r = _preq(aport,
            "GET /admin/log/tail HTTP/1.1\r\nHost: x\r\nX-Admin-Token: demo-token\r\n" *
            "Connection: close\r\n\r\n"; full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("GET /healthz", r)
        r = _req(aport, "GET", "/metrics"; full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("ciro_requests_total", r)

        # Maintenance drain flips readiness
        r = _preq(aport,
            "POST /admin/maintenance HTTP/1.1\r\nHost: x\r\nX-Admin-Token: demo-token\r\n" *
            "Content-Length: 2\r\nConnection: close\r\n\r\non"; full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("\"maintenance\":true", r)
        @test _status(_req(aport, "GET", "/readyz"; full = true)) == 503
        _preq(aport,
            "POST /admin/maintenance HTTP/1.1\r\nHost: x\r\nX-Admin-Token: demo-token\r\n" *
            "Content-Length: 3\r\nConnection: close\r\n\r\noff"; full = true)
        @test _status(_req(aport, "GET", "/readyz"; full = true)) == 200

        # Concurrency: 10 simultaneous predictions on the async server
        tasks = [@async _req(aport, "POST", "/api/v1/predict"; body = "1,2,3") for _ in 1:10]
        @test all(_status(fetch(t)) == 200 for t in tasks)

        # Overload shedding: 48 requests against 8 workers + 24 pending → some 503
        results = Channel{Int}(96)
        for _ in 1:48
            @async put!(results, _status(_req(aport, "POST", "/api/v1/predict"; body = "1,2,3")))
        end
        codes = [take!(results) for _ in 1:48]
        @test count(==(200), codes) >= 1
        @test count(==(503), codes) >= 1

        # Abort mid-stream, then a fresh generation still works
        sse = Sockets.connect(Sockets.IPv4("127.0.0.1"), aport)
        write(sse, "GET /api/v1/generate?prompt=abort&style=plain HTTP/1.1\r\nHost: x\r\n\r\n")
        readuntil(sse, "\r\n\r\n")
        _read_until(sse, "event: delta")
        close(sse)
        sleep(0.3)
        sse2 = Sockets.connect(Sockets.IPv4("127.0.0.1"), aport)
        try
            write(sse2, "GET /api/v1/generate?prompt=again&style=plain HTTP/1.1\r\nHost: x\r\n\r\n")
            readuntil(sse2, "\r\n\r\n")
            @test occursin("event: done", _read_until(sse2, "event: done"))
        finally
            close(sse2)
        end
    finally
        stop!(async_server)
        stop!(sync_server)
        timedwait(() -> istaskdone(async_task), 5.0)
        timedwait(() -> istaskdone(sync_task), 5.0)
    end
end
