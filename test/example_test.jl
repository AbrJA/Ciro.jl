using Test
using Ciro
using Sockets

# The example defines `build_dashboard` and a custom telemetry; `main()` is
# guarded by `PROGRAM_FILE`, so including it does not start a server.
include(joinpath(@__DIR__, "..", "examples", "ml_dashboard", "server.jl"))

"""Yielding in-process client (the server shares this process)."""
function _ex_request(port::Integer, data::AbstractString; full::Bool=false)
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
            error("example request to port $port timed out")
        return result[]
    finally
        close(sock)
    end
end

@testset "Example: ML dashboard (in-process sockets)" begin
    port = 20000 + (getpid() % 10000) + 500
    server = build_dashboard(; port, backend = :sockets,
                             telemetry = DemoTelemetry(devnull))
    task = Threads.@spawn start!(server; nworkers = 1)
    try
        ready = false
        for _ in 1:200
            try
                _ex_request(port, "GET /api/health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                            full = true)
                ready = true
                break
            catch
                sleep(0.05)
            end
        end
        @test ready

        r = _ex_request(port, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"; full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("ML Dashboard", r)

        r = _ex_request(port, "GET /api/health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                        full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("\"status\":\"ok\"", r)
        @test occursin("X-Server: Ciro", r)                 # middleware

        r = _ex_request(port, "GET /api/v1/models HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                        full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("linear", r)

        r = _ex_request(port, "GET /api/v1/models/2 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                        full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("\"mlp\"", r)
        r = _ex_request(port, "GET /api/v1/models/99 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                        full = true)
        @test startswith(r, "HTTP/1.1 404")

        # Async executor: simulated inference off the event loop
        r = _ex_request(port,
            "POST /api/v1/predict?model=2 HTTP/1.1\r\nHost: x\r\nContent-Length: 9\r\n" *
            "Connection: close\r\n\r\n1.0,2.0,3", full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("\"prediction\"", r)
        @test occursin("\"model\":\"mlp\"", r)

        # Per-route limit: 4 KB on /api/v1/upload
        r = _ex_request(port,
            "POST /api/v1/upload HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n" *
            "Connection: close\r\n\r\n" * "x"^10, full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("\"received\":10", r)
        r = _ex_request(port,
            "POST /api/v1/upload HTTP/1.1\r\nHost: x\r\nContent-Length: 5000\r\n" *
            "Connection: close\r\n\r\n" * "x"^5000, full = true)
        @test startswith(r, "HTTP/1.1 413")

        # Middleware: token-protected admin endpoint
        r = _ex_request(port, "GET /admin/stats HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                        full = true)
        @test startswith(r, "HTTP/1.1 401")
        r = _ex_request(port,
            "GET /admin/stats HTTP/1.1\r\nHost: x\r\nX-Admin-Token: demo-token\r\n" *
            "Connection: close\r\n\r\n", full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("\"requests\"", r)

        # Static files via wildcard, with traversal rejection
        r = _ex_request(port, "GET /static/app.js HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                        full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("EventSource", r)
        r = _ex_request(port, "GET /static/../server.jl HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                        full = true)
        @test startswith(r, "HTTP/1.1 404")

        # Retention rule: copy(ctx) handed to another task
        r = _ex_request(port, "GET /api/v1/audit HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                        full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("\"audited\":true", r)

        # SSE: headers arrive immediately (body is an infinite stream)
        r = _ex_request(port, "GET /api/v1/events HTTP/1.1\r\nHost: x\r\n\r\n")
        @test startswith(r, "HTTP/1.1 200")
        @test occursin("Content-Type: text/event-stream", r)
    finally
        stop!(server)
        timedwait(() -> istaskdone(task), 5.0)
    end
end
