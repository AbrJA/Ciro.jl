using Test
using Ciro
using Sockets

# The example defines `build_console`; `main()` is guarded by `PROGRAM_FILE`,
# so including it does not start a server.
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

@testset "Example: ops console (in-process sockets)" begin
    port = 20000 + (getpid() % 10000) + 600
    server = build_console(; port, backend = :sockets, nworkers = 1,
                           admin_token = "demo-token", log_io = devnull)
    task = Threads.@spawn start!(server; nworkers = 1)
    try
        ready = false
        for _ in 1:200
            try
                _ex_request(port, "GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                            full = true)
                ready = true
                break
            catch
                sleep(0.05)
            end
        end
        @test ready

        r = _ex_request(port, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"; full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("Ops Console", r)

        # Probes: liveness answers, readiness reflects maintenance.
        r = _ex_request(port, "GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                        full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("\"status\":\"ok\"", r)
        @test occursin("X-Service: mock-linear", r)
        r = _ex_request(port, "GET /readyz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                        full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("\"status\":\"ready\"", r)

        # Metrics: Prometheus text and JSON.
        r = _ex_request(port, "GET /metrics HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                        full = true)
        @test startswith(r, "HTTP/1.1 200")
        @test occursin("text/plain; version=0.0.4", r)
        @test occursin("ciro_requests_total", r)
        r = _ex_request(port, "GET /api/metrics HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                        full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("\"requests\"", r)

        # Service info: typed param and 404.
        r = _ex_request(port, "GET /api/v1/models HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                        full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("linear", r)
        r = _ex_request(port, "GET /api/v1/models/2 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                        full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("\"mlp\"", r)
        r = _ex_request(port, "GET /api/v1/models/99 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                        full = true)
        @test startswith(r, "HTTP/1.1 404")

        # Per-route upload limit.
        r = _ex_request(port,
            "POST /api/v1/upload HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n" *
            "Connection: close\r\n\r\n" * "x"^10, full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("\"received\":10", r)
        r = _ex_request(port,
            "POST /api/v1/upload HTTP/1.1\r\nHost: x\r\nContent-Length: 8000\r\n" *
            "Connection: close\r\n\r\n" * "x"^8000, full = true)
        @test startswith(r, "HTTP/1.1 413")

        # Admin endpoints require the token.
        r = _ex_request(port, "GET /admin/stats HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                        full = true)
        @test startswith(r, "HTTP/1.1 401")
        r = _ex_request(port,
            "GET /admin/stats HTTP/1.1\r\nHost: x\r\nX-Admin-Token: demo-token\r\n" *
            "Connection: close\r\n\r\n", full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("\"active_connections\"", r)
        r = _ex_request(port,
            "GET /admin/config HTTP/1.1\r\nHost: x\r\nX-Admin-Token: demo-token\r\n" *
            "Connection: close\r\n\r\n", full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("\"backend\":\"sockets\"", r)
        @test occursin("\"admin_token\":\"***\"", r)

        # Access log tail captured the requests above.
        r = _ex_request(port,
            "GET /admin/log/tail HTTP/1.1\r\nHost: x\r\nX-Admin-Token: demo-token\r\n" *
            "Connection: close\r\n\r\n", full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("\"lines\"", r)
        @test occursin("GET /healthz", r)

        # Maintenance drain: readiness flips to 503 and back.
        r = _ex_request(port,
            "POST /admin/maintenance HTTP/1.1\r\nHost: x\r\nX-Admin-Token: demo-token\r\n" *
            "Content-Length: 2\r\nConnection: close\r\n\r\non", full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("\"maintenance\":true", r)
        r = _ex_request(port, "GET /readyz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                        full = true)
        @test startswith(r, "HTTP/1.1 503") && occursin("\"maintenance\"", r)
        r = _ex_request(port,
            "POST /admin/maintenance HTTP/1.1\r\nHost: x\r\nX-Admin-Token: demo-token\r\n" *
            "Content-Length: 3\r\nConnection: close\r\n\r\noff", full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("\"maintenance\":false", r)
        r = _ex_request(port, "GET /readyz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                        full = true)
        @test startswith(r, "HTTP/1.1 200")
        r = _ex_request(port,
            "POST /admin/maintenance HTTP/1.1\r\nHost: x\r\nX-Admin-Token: demo-token\r\n" *
            "Content-Length: 5\r\nConnection: close\r\n\r\nbogus", full = true)
        @test startswith(r, "HTTP/1.1 400")

        # Static files via wildcard, with traversal rejection.
        r = _ex_request(port, "GET /static/app.js HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                        full = true)
        @test startswith(r, "HTTP/1.1 200") && occursin("maintenance", r)
        r = _ex_request(port, "GET /static/../server.jl HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                        full = true)
        @test startswith(r, "HTTP/1.1 404")
        r = _ex_request(port, "GET /missing HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                        full = true)
        @test startswith(r, "HTTP/1.1 404")
    finally
        stop!(server)
        timedwait(() -> istaskdone(task), 5.0)
    end
end
