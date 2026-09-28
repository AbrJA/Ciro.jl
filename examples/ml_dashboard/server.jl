#!/usr/bin/env julia
# ══════════════════════════════════════════════════════════════════════════════
# Ciro.jl — real-world example: an ML inference dashboard
#
# Run:
#   julia --project=. --threads=8 examples/ml_dashboard/server.jl [port] [backend]
#   # e.g. julia --project=. --threads=8 examples/ml_dashboard/server.jl 8080 uring
#   #      julia --project=. --threads=8 examples/ml_dashboard/server.jl 8080 sockets
#
# Then open http://localhost:8080 — the page polls the API, streams live metrics
# over SSE, and exercises the async executor with simulated inference.
# ══════════════════════════════════════════════════════════════════════════════

using Ciro
using Dates

# Extend telemetry callbacks for the custom observer (explicit imports are
# required on Julia 1.10 to add methods to another module's functions).
import Ciro: telemetry_capture_path, telemetry_request!, telemetry_response!,
             telemetry_read!, telemetry_exception!

# ── Domain data ─────────────────────────────────────────────────────────────

const MODELS = [
    (id = 1, name = "linear",   kind = "regression", params = 1_024),
    (id = 2, name = "mlp",      kind = "classifier", params = 65_536),
    (id = 3, name = "tiny-llm", kind = "generation", params = 1_048_576),
]

model_json(m) = "{\"id\":$(m.id),\"name\":\"$(m.name)\",\"kind\":\"$(m.kind)\"," *
                "\"params\":$(m.params)}"

models_json() = "{\"models\":[" * join(model_json.(MODELS), ",") * "]}"

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

# ── Custom telemetry: one observer feeding both metrics and an access log ───

struct DemoTelemetry <: AbstractTelemetry
    metrics :: ServerMetrics
    io      :: IO
    lock    :: ReentrantLock
end

DemoTelemetry(io::IO=stdout) = DemoTelemetry(ServerMetrics(), io, ReentrantLock())

telemetry_capture_path(::DemoTelemetry)::Bool = true

telemetry_request!(t::DemoTelemetry, m::UInt8, p, v::UInt8) =
    telemetry_request!(t.metrics, m, p, v)
telemetry_read!(t::DemoTelemetry, n::Int) = telemetry_read!(t.metrics, n)
telemetry_exception!(t::DemoTelemetry) = telemetry_exception!(t.metrics)

function telemetry_response!(t::DemoTelemetry, m::UInt8, p, s::Int, b::Int, e::Float64)
    telemetry_response!(t.metrics, m, p, s, b, e)
    line = string(Dates.now(), " \"", Methods.to_string(m), " ", p, "\" ", s, " ", b,
                  " ", round(e * 1000; digits = 2), "ms")
    lock(t.lock) do
        println(t.io, line)
    end
    return nothing
end

# ── Middleware (callable structs) ───────────────────────────────────────────

struct WithServerHeader{H}
    handler :: H
end

function (m::WithServerHeader)(ctx::Context)
    resp = m.handler(ctx)
    resp isa Response && push!(resp.headers, "X-Server" => "Ciro")
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

# ── Static files (a small, traversal-safe wildcard handler) ─────────────────

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

# ── Handlers ────────────────────────────────────────────────────────────────

function predict(ctx::Context)
    features = Float64[]
    for part in split(body(ctx), ',')
        v = tryparse(Float64, strip(part))
        v === nothing || push!(features, v)
    end
    isempty(features) && return fail(422, "Expected comma-separated features")

    qp = queryparams(ctx)
    model_id = clamp(something(tryparse(Int, get(qp, "model", "1")), 1), 1, length(MODELS))

    t0 = time()
    sleep(0.05 + 0.1 * rand())          # simulated inference, off the event loop
    score = sum(features) / length(features) + 0.01 * model_id
    return json("{\"model\":\"$(MODELS[model_id].name)\"," *
                "\"prediction\":$(round(score; digits = 4))," *
                "\"features\":$(length(features))," *
                "\"latency_ms\":$(round((time() - t0) * 1000; digits = 1))}")
end

function audit(ctx::Context)
    saved = copy(ctx)                   # owned request: safe to hand to a task
    Threads.@spawn begin
        sleep(0.2)
        println("[audit] $(saved.request.method) $(saved.request.path) " *
                "ua=$(header(saved.request, "User-Agent", "unknown"))")
    end
    return json("{\"audited\":true}")
end

function events(ctx::Context, metrics::ServerMetrics)
    return sse() do send
        try
            while true
                s = metrics_snapshot(metrics)
                send("{\"tick\":$(round(time(); digits = 2))," *
                     "\"requests\":$(s.requests),\"responses\":$(s.responses)," *
                     "\"errors\":$(s.status_4xx + s.status_5xx)}"; event = "metrics")
                sleep(1)
            end
        catch err
            err isa StreamClosedError || rethrow(err)
        end
    end
end

# ── Application ─────────────────────────────────────────────────────────────

"""
    build_dashboard(; port=8080, backend=:uring, executor=..., telemetry=...)

Build (but do not start) the example server. Kept separate from `main` so the
test suite can start it in-process.
"""
function build_dashboard(;
    port::Int = 8080,
    backend::Symbol = :uring,
    # Each open SSE stream holds one worker for its lifetime, so size the pool
    # for the number of concurrent streams you expect (one per dashboard tab).
    executor::AbstractExecutor = AsyncExecutor(worker_threads = 32, max_pending = 128),
    telemetry::AbstractTelemetry = DemoTelemetry(),
)
    started = time()
    router = Trie()

    # Dashboard page and assets
    get!(router, "/", _ -> html(read(joinpath(PUBLIC_DIR, "index.html"), String)))
    get!(router, "/static/*", serve_static)

    # Health (middleware adds a header)
    get!(router, "/api/health", WithServerHeader(_ -> json(
        "{\"status\":\"ok\",\"uptime_s\":$(round(time() - started; digits = 1))}")))

    # Models: collection, typed param, 404
    get!(router, "/api/v1/models", _ -> json(models_json()))
    get!(router, "/api/v1/models/:id::Int", ctx -> begin
        id = param(ctx, Int, :id)
        (1 <= id <= length(MODELS)) || return fail(404, "Unknown model")
        return json(model_json(MODELS[id]))
    end)

    # Simulated inference on the async executor
    post!(router, "/api/v1/predict", predict)

    # Live metrics over SSE (requires AsyncExecutor)
    get!(router, "/api/v1/events", ctx -> events(ctx, telemetry.metrics))

    # Upload with a small per-route body limit (server-wide default is 1 MiB)
    post!(router, "/api/v1/upload",
         ctx -> json("{\"received\":$(length(rawbody(ctx))),\"limit\":4096}");
         limits = RouteLimits(max_body_size = 4096))

    # Retention rule: copy(ctx) before crossing a task boundary
    get!(router, "/api/v1/audit", audit)

    # Metrics for the dashboard, and admin stats behind a token middleware
    get!(router, "/api/metrics", _ -> json(metrics_json(telemetry.metrics)))
    get!(router, "/admin/stats",
         RequireToken("demo-token", _ -> json(metrics_json(telemetry.metrics))))

    return Server(; router, port, backend, executor, telemetry,
                  host = "0.0.0.0",
                  max_body_size = 1_048_576,
                  idle_timeout_ms = 120_000)
end

function main()
    port = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 8080
    backend = length(ARGS) >= 2 ? Symbol(ARGS[2]) : :uring
    server = build_dashboard(; port, backend)

    println("""
    ╭──────────────────────────────────────────────────────────────╮
    │  Ciro.jl ML dashboard                                        │
    │    http://localhost:$(lpad(port, 5))  (backend=:$backend)        │
    │                                                              │
    │  API:  GET  /api/health          GET  /api/v1/models         │
    │        GET  /api/v1/models/:id   POST /api/v1/predict        │
    │        GET  /api/v1/events (SSE) POST /api/v1/upload         │
    │        GET  /api/metrics         GET  /admin/stats (token)   │
    │                                                              │
    │  Admin token: demo-token      Stop: Ctrl-C (graceful)        │
    ╰──────────────────────────────────────────────────────────────╯
    """)
    start!(server; nworkers = min(Threads.nthreads(), 8))
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
