#!/usr/bin/env julia
# ══════════════════════════════════════════════════════════════════════════════
# Ciro.jl — real-world example: a production-style ops console
#
# A small model service with the things you actually deploy: liveness and
# readiness probes, Prometheus metrics, an access log (stdout or a file),
# token-protected admin endpoints, a maintenance/drain switch, per-route body
# limits, and graceful shutdown.
#
# Run:
#   julia --project=. examples/ml_dashboard/server.jl
#
# Configuration (environment variables):
#   CIRO_PORT=8080  CIRO_BACKEND=uring|sockets  CIRO_WORKERS=<threads>
#   CIRO_LOG=/path/access.log   CIRO_ADMIN_TOKEN=demo-token
#   CIRO_MAX_BODY=1048576       CIRO_MAX_CONNECTIONS=1024
#
# Then open http://localhost:8080 — the console polls the API, shows the access
# log tail, and can flip the service into maintenance (readyz -> 503).
# ══════════════════════════════════════════════════════════════════════════════

using Ciro
using Dates

# Extend Ciro's extension points (explicit imports are required to add methods
# to another module's functions).
import Ciro: log!, telemetry_capture_path, telemetry_request!, telemetry_response!,
             telemetry_read!, telemetry_exception!

# ── Service identity ────────────────────────────────────────────────────────

const SERVICE = (name = "mock-linear", version = "0.1.0")

const MODELS = [
    (id = 1, name = "linear",   kind = "regression", params = 1_024),
    (id = 2, name = "mlp",      kind = "classifier", params = 65_536),
    (id = 3, name = "tiny-llm", kind = "generation", params = 1_048_576),
]

model_json(m) = "{\"id\":$(m.id),\"name\":\"$(m.name)\",\"kind\":\"$(m.kind)\"," *
                "\"params\":$(m.params)}"
models_json() = "{\"models\":[" * join(model_json.(MODELS), ",") * "]}"

json_escape(s::AbstractString) = sprint() do io
    for c in s
        if c == '"' || c == '\\'
            print(io, '\\', c)
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\r'
            print(io, "\\r")
        elseif c == '\t'
            print(io, "\\t")
        else
            print(io, c)
        end
    end
end

function metrics_json(m::ServerMetrics)
    s = metrics_snapshot(m)
    return string("{\"requests\":", s.requests,
                  ",\"responses\":", s.responses,
                  ",\"status_2xx\":", s.status_2xx,
                  ",\"status_4xx\":", s.status_4xx,
                  ",\"status_5xx\":", s.status_5xx,
                  ",\"exceptions\":", s.exceptions,
                  ",\"bytes_in\":", s.bytes_in,
                  ",\"bytes_out\":", s.bytes_out, "}")
end

"""Prometheus text exposition of the HTTP counters."""
function prometheus_text(m::ServerMetrics)
    s = metrics_snapshot(m)
    io = IOBuffer()
    for (name, help, value) in (
        ("ciro_requests_total",     "Parsed HTTP requests.", s.requests),
        ("ciro_responses_total",    "HTTP responses queued.", s.responses),
        ("ciro_status_2xx_total",   "Responses with 2xx status.", s.status_2xx),
        ("ciro_status_3xx_total",   "Responses with 3xx status.", s.status_3xx),
        ("ciro_status_4xx_total",   "Responses with 4xx status.", s.status_4xx),
        ("ciro_status_5xx_total",   "Responses with 5xx status.", s.status_5xx),
        ("ciro_exceptions_total",   "Handler exceptions intercepted.", s.exceptions),
        ("ciro_bytes_in_total",     "Bytes read from connections.", s.bytes_in),
        ("ciro_bytes_out_total",    "Bytes written to connections.", s.bytes_out),
    )
        print(io, "# HELP ", name, " ", help, "\n# TYPE ", name, " counter\n",
                  name, " ", value, "\n")
    end
    return String(take!(io))
end

# ── Telemetry: metrics + access log with an in-memory tail ──────────────────

struct OpsTelemetry <: AbstractTelemetry
    metrics  :: ServerMetrics
    io       :: IO
    lock     :: ReentrantLock
    tail     :: Vector{String}
    max_tail :: Int
end

OpsTelemetry(io::IO = stdout; max_tail::Int = 50) =
    OpsTelemetry(ServerMetrics(), io, ReentrantLock(), String[], max_tail)

telemetry_capture_path(::OpsTelemetry)::Bool = true

telemetry_request!(t::OpsTelemetry, m::UInt8, p, v::UInt8) =
    telemetry_request!(t.metrics, m, p, v)
telemetry_read!(t::OpsTelemetry, n::Int) = telemetry_read!(t.metrics, n)
telemetry_exception!(t::OpsTelemetry) = telemetry_exception!(t.metrics)

function telemetry_response!(t::OpsTelemetry, m::UInt8, p, s::Int, b::Int, e::Float64)
    telemetry_response!(t.metrics, m, p, s, b, e)
    line = string(Dates.now(), " \"", Methods.to_string(m), " ", p, "\" ", s, " ", b,
                  " ", round(e * 1000; digits = 2), "ms")
    lock(t.lock) do
        println(t.io, line)
        flush(t.io)                     # keep file logs current for tailing
        push!(t.tail, line)
        length(t.tail) > t.max_tail && popfirst!(t.tail)
    end
    return nothing
end

tail_lines(t::OpsTelemetry) = lock(t.lock) do
    copy(t.tail)
end

# ── System logger (AbstractLogger extension point) ──────────────────────────

struct ConsoleLogger <: AbstractLogger end

log!(::ConsoleLogger, level::Severity, msg::String) =
    println(stderr, "[", level, "] ", msg)

# ── Middleware (callable structs) ───────────────────────────────────────────

struct WithServiceHeader{H}
    handler :: H
end

function (m::WithServiceHeader)(ctx::Context)
    resp = m.handler(ctx)
    resp isa Response && push!(resp.headers, "X-Service" => SERVICE.name)
    return resp
end

struct RequireToken{H}
    token   :: String
    handler :: H
end

function (m::RequireToken)(ctx::Context)
    header(ctx, "X-Admin-Token") == m.token || return fail(401, "Unauthorized")
    return m.handler(ctx)
end

# ── Static files (traversal-guarded wildcard) ───────────────────────────────

const PUBLIC_DIR = joinpath(@__DIR__, "public")

function serve_static(ctx::Context)
    target = String(path(ctx))
    rel = startswith(target, "/static/") ? target[9:end] : ""
    (isempty(rel) || startswith(rel, '/') || occursin("..", rel)) &&
        return fail(404, "Not Found")
    file = joinpath(PUBLIC_DIR, rel)
    isfile(file) || return fail(404, "Not Found")
    ctype = endswith(rel, ".html") ? "text/html; charset=utf-8" :
            endswith(rel, ".js")   ? "application/javascript; charset=utf-8" :
            endswith(rel, ".css")  ? "text/css; charset=utf-8" :
            endswith(rel, ".svg")  ? "image/svg+xml" : "application/octet-stream"
    return Response(200, ["Content-Type" => ctype, "Cache-Control" => "no-cache"],
                    read(file))
end

# ── Application ─────────────────────────────────────────────────────────────

"""
    build_console(; port, backend, nworkers, admin_token, log_io, ...) -> Server

Build (but do not start) the ops-console server. Kept separate from `main` so
tests can start it in-process.
"""
function build_console(;
    port::Int = 8080,
    backend::Symbol = :uring,
    nworkers::Int = Threads.nthreads(),
    admin_token::String = "demo-token",
    log_io::IO = stdout,
    max_body_size::Int = 1_048_576,
    max_connections::Int = 1024,
)
    telemetry = OpsTelemetry(log_io)
    maintenance = Threads.Atomic{Bool}(false)
    started = time()

    router = Trie()

    # Console page and assets
    get!(router, "/", _ -> html(read(joinpath(PUBLIC_DIR, "index.html"), String)))
    get!(router, "/static/*", serve_static)

    # Probes: liveness always answers; readiness reflects maintenance.
    get!(router, "/healthz", WithServiceHeader(_ ->
        json("{\"status\":\"ok\",\"uptime_s\":$(round(time() - started; digits = 1))}")))
    get!(router, "/readyz", _ -> maintenance[] ?
        Response(503, ["Content-Type" => "application/json"],
                 "{\"status\":\"maintenance\"}") :
        json("{\"status\":\"ready\",\"service\":\"$(SERVICE.name)\",\"version\":\"$(SERVICE.version)\"}"))

    # Metrics: Prometheus text for scrapers, JSON for the console UI.
    get!(router, "/metrics", _ -> Response(200,
        ["Content-Type" => "text/plain; version=0.0.4; charset=utf-8"],
        prometheus_text(telemetry.metrics)))
    get!(router, "/api/metrics", _ -> json(metrics_json(telemetry.metrics)))

    # Service info (typed param + 404)
    get!(router, "/api/v1/models", _ -> json(models_json()))
    get!(router, "/api/v1/models/:id::Int", ctx -> begin
        id = param(ctx, Int, :id)
        (1 <= id <= length(MODELS)) || return fail(404, "Unknown model")
        return json(model_json(MODELS[id]))
    end)

    # Diagnostics upload with a small per-route limit (server default is 1 MiB)
    post!(router, "/api/v1/upload",
         ctx -> json("{\"received\":$(length(rawbody(ctx))),\"limit\":4096}");
         limits = RouteLimits(max_body_size = 4096))

    # Admin: token-protected ops endpoints
    get!(router, "/admin/config", RequireToken(admin_token, _ -> json(
        "{\"service\":\"$(SERVICE.name)\",\"version\":\"$(SERVICE.version)\"," *
        "\"port\":$port,\"backend\":\"$backend\",\"nworkers\":$nworkers," *
        "\"max_body_size\":$max_body_size,\"max_connections\":$max_connections," *
        "\"admin_token\":\"***\"}")))
    get!(router, "/admin/log/tail", RequireToken(admin_token, _ ->
        json("{\"lines\":[" *
             join(("\"" * json_escape(l) * "\"" for l in tail_lines(telemetry)), ",") *
             "]}")))
    post!(router, "/admin/maintenance", RequireToken(admin_token, ctx -> begin
        state = strip(body(ctx))
        if state == "on"
            maintenance[] = true
        elseif state == "off"
            maintenance[] = false
        else
            return fail(400, "expected body 'on' or 'off'")
        end
        return json("{\"maintenance\":$(maintenance[])}")
    end))

    server = Server(; router, port, backend, logger = ConsoleLogger(), telemetry,
                    max_body_size, max_connections, idle_timeout_ms = 120_000)

    # Registered after construction so it can read the live connection count.
    get!(router, "/admin/stats", RequireToken(admin_token, _ -> json(
        metrics_json(telemetry.metrics)[1:end-1] * "," *
        "\"active_connections\":$(server.runtime.conn_count[])," *
        "\"max_connections\":$max_connections," *
        "\"maintenance\":$(maintenance[])}")))

    return server
end

# ── Environment configuration ───────────────────────────────────────────────

function _env_int(key::String, default::Int)::Int
    raw = get(ENV, key, "")
    isempty(raw) && return default
    value = tryparse(Int, raw)
    value === nothing && error("$key must be an integer, got $(repr(raw))")
    return value
end

function main()
    # Positional args override the environment: `server.jl [port] [backend]`.
    port            = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : _env_int("CIRO_PORT", 8080)
    backend         = length(ARGS) >= 2 ? Symbol(ARGS[2]) :
                      Symbol(get(ENV, "CIRO_BACKEND", "uring"))
    nworkers        = _env_int("CIRO_WORKERS", Threads.nthreads())
    admin_token     = get(ENV, "CIRO_ADMIN_TOKEN", "demo-token")
    log_path        = get(ENV, "CIRO_LOG", "")
    max_body_size   = _env_int("CIRO_MAX_BODY", 1_048_576)
    max_connections = _env_int("CIRO_MAX_CONNECTIONS", 1024)

    log_io = isempty(log_path) ? stdout : open(log_path, "a")
    server = build_console(; port, backend, nworkers, admin_token, log_io,
                           max_body_size, max_connections)

    println("""
    Ciro.jl ops console
      http://localhost:$port   backend=:$backend   workers=$nworkers
      log: $(isempty(log_path) ? "stdout" : log_path)

      GET  /healthz   GET /readyz                (probes; readyz 503 while draining)
      GET  /metrics (Prometheus)                 GET /api/metrics (JSON)
      GET  /admin/stats|config|log/tail          POST /admin/maintenance ("on"/"off")
      POST /api/v1/upload                        (4 KB per-route limit)

      token: $admin_token   ·   stop: Ctrl-C (graceful drain)
    """)
    start!(server; nworkers)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
