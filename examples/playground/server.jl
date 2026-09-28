#!/usr/bin/env julia
# Ciro.jl playground — one app that exercises the library end to end.
#
# Run:
#   julia --project=. --threads=8 examples/playground/server.jl [port] [backend]
#
# Two servers start from the same routes so you can see the difference:
#   async executor  http://localhost:<port>       (streaming, slow work off-loop)
#   sync executor   http://localhost:<port+1>     (streaming 500s; slow work blocks)
#
# The UI can switch between them. Stop with Ctrl-C (graceful drain).
#
# Configuration (environment variables):
#   CIRO_PORT=8080  CIRO_BACKEND=uring|sockets  CIRO_WORKERS=<threads>
#   CIRO_TOKEN_MS=40  CIRO_THINK_MS=400  CIRO_ADMIN_TOKEN=demo-token
#   CIRO_WORKER_THREADS=32

using Ciro
using Dates

# Extend Ciro's extension points (explicit imports add methods to Ciro's funcs).
import Ciro: log!, telemetry_capture_path, telemetry_request!, telemetry_response!,
             telemetry_read!, telemetry_exception!

# Service identity and mock model

const SERVICE = (name = "mock-model", version = "0.1.0")

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
                  ",\"status_3xx\":", s.status_3xx,
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
        ("ciro_requests_total",   "Parsed HTTP requests.", s.requests),
        ("ciro_responses_total",  "HTTP responses queued.", s.responses),
        ("ciro_status_2xx_total", "Responses with 2xx status.", s.status_2xx),
        ("ciro_status_3xx_total", "Responses with 3xx status.", s.status_3xx),
        ("ciro_status_4xx_total", "Responses with 4xx status.", s.status_4xx),
        ("ciro_status_5xx_total", "Responses with 5xx status.", s.status_5xx),
        ("ciro_exceptions_total", "Handler exceptions intercepted.", s.exceptions),
        ("ciro_bytes_in_total",   "Bytes read from connections.", s.bytes_in),
        ("ciro_bytes_out_total",  "Bytes written to connections.", s.bytes_out),
    )
        print(io, "# HELP ", name, " ", help, "\n# TYPE ", name, " counter\n",
                  name, " ", value, "\n")
    end
    return String(take!(io))
end

# Telemetry: metrics + access log with an in-memory tail

struct PlaygroundTelemetry <: AbstractTelemetry
    metrics  :: ServerMetrics
    io       :: IO
    lock     :: ReentrantLock
    tail     :: Vector{String}
    max_tail :: Int
end

PlaygroundTelemetry(io::IO = stdout; max_tail::Int = 50) =
    PlaygroundTelemetry(ServerMetrics(), io, ReentrantLock(), String[], max_tail)

telemetry_capture_path(::PlaygroundTelemetry)::Bool = true

telemetry_request!(t::PlaygroundTelemetry, m::UInt8, p, v::UInt8) =
    telemetry_request!(t.metrics, m, p, v)
telemetry_read!(t::PlaygroundTelemetry, n::Int) = telemetry_read!(t.metrics, n)
telemetry_exception!(t::PlaygroundTelemetry) = telemetry_exception!(t.metrics)

function telemetry_response!(t::PlaygroundTelemetry, m::UInt8, p, s::Int, b::Int, e::Float64)
    telemetry_response!(t.metrics, m, p, s, b, e)
    line = string(Dates.now(), " \"", Methods.to_string(m), " ", p, "\" ", s, " ", b,
                  " ", round(e * 1000; digits = 2), "ms")
    lock(t.lock) do
        println(t.io, line)
        flush(t.io)
        push!(t.tail, line)
        length(t.tail) > t.max_tail && popfirst!(t.tail)
    end
    return nothing
end

tail_lines(t::PlaygroundTelemetry) = lock(t.lock) do
    copy(t.tail)
end

# Extension points: logger, catcher, middleware

struct ConsoleLogger <: AbstractLogger end
log!(::ConsoleLogger, level::Severity, msg::String) =
    println(stderr, "[", level, "] ", msg)

"""Custom catcher: JSON errors, with the exception type but never the message."""
struct JsonCatcher <: AbstractCatcher end
function Ciro.Interface.intercept(::JsonCatcher, err::Exception, _)
    return json("{\"error\":\"internal_server_error\"," *
                "\"type\":\"$(nameof(typeof(err)))\"}"; status = 500)
end

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

# The async and sync servers are different origins (different ports), so the UI
# needs CORS to switch between them. This is an example-level middleware; a
# built-in `Cors` helper is a candidate for the library backlog.
const CORS_ORIGIN = "Access-Control-Allow-Origin" => "*"

struct WithCORS{H}
    handler :: H
end
function (m::WithCORS)(ctx::Context)
    resp = m.handler(ctx)
    if resp isa Response
        push!(resp.headers, CORS_ORIGIN)
    elseif resp isa Stream
        push!(resp.headers, CORS_ORIGIN)   # serialized with the stream head
    end
    return resp
end

"""Answer `OPTIONS` preflight for any path (admin token/DELETE need it)."""
function cors_preflight(_::Context)
    return Response(204, ["Access-Control-Allow-Origin" => "*",
                          "Access-Control-Allow-Methods" =>
                              "GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS",
                          "Access-Control-Allow-Headers" =>
                              "X-Admin-Token, Content-Type",
                          "Access-Control-Max-Age" => "600"], UInt8[])
end

# Static files (traversal-guarded wildcard)

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

# Mock model

function generate_text(prompt::String, style::String)::String
    base = isempty(prompt) ? "Hello from the Ciro playground." : "You asked: \"$prompt\"."
    body = style == "haiku" ?
               "Tokens arrive one at a time, the event loop stays free, workers hum along." :
           style == "json" ?
               "{\"answer\":\"streamed\",\"mock\":true,\"style\":\"json\"}" :
           "Here is a streamed answer, token by token, so you can watch SSE and " *
           "chunked delivery while the server keeps serving other requests."
    return base * " " * body
end

function parse_features(text::String)::Vector{Float64}
    features = Float64[]
    for part in split(text, ',')
        v = tryparse(Float64, strip(part))
        v === nothing || push!(features, v)
    end
    return features
end

# Application factory

"""
    build_playground(; port, backend, executor, ...) -> Server

Build (but do not start) a playground server. Called once with an
`AsyncExecutor` and once with a `SyncExecutor` so the same UI can show the
difference.
"""
function build_playground(;
    port::Int = 8080,
    backend::Symbol = :uring,
    executor::AbstractExecutor = AsyncExecutor(),
    admin_token::String = "demo-token",
    token_ms::Int = 40,
    think_s::Float64 = 0.4,
    log_io::IO = stdout,
    max_body_size::Int = 1_048_576,
    max_connections::Int = 1024,
    catcher::AbstractCatcher = JsonCatcher(),
    ports::Tuple{Int,Int},          # (async, sync) advertised to the UI
)
    telemetry = PlaygroundTelemetry(log_io)
    maintenance = Threads.Atomic{Bool}(false)
    started = time()
    router = Trie()

    # Every route is wrapped in CORS: the async and sync servers are different
    # origins, and the UI switches between them from either page.
    _get!(path, h; kw...)  = get!(router, path, WithCORS(h); kw...)
    _post!(path, h; kw...) = post!(router, path, WithCORS(h); kw...)
    _options!(path)        = options!(router, path, cors_preflight)

    # Page (with both ports and the think time injected) and assets
    page = replace(read(joinpath(PUBLIC_DIR, "index.html"), String),
                   "__CIRO_PORTS__"    => "{\"async\":$(ports[1]),\"sync\":$(ports[2])}",
                   "__CIRO_THINK_MS__" => string(round(Int, think_s * 1000)))
    _get!("/", _ -> html(page))
    _get!("/static/*", serve_static)

    _get!("/healthz", WithServiceHeader(_ ->
        json("{\"status\":\"ok\",\"service\":\"$(SERVICE.name)\"," *
             "\"uptime_s\":$(round(time() - started; digits = 1))}")))
    _get!("/readyz", _ -> maintenance[] ?
        Response(503, ["Content-Type" => "application/json"],
                 "{\"status\":\"maintenance\"}") :
        json("{\"status\":\"ready\",\"version\":\"$(SERVICE.version)\"}"))
    _get!("/metrics", _ -> Response(200,
        ["Content-Type" => "text/plain; version=0.0.4; charset=utf-8"],
        prometheus_text(telemetry.metrics)))
    _get!("/api/metrics", _ -> json(metrics_json(telemetry.metrics)))

    _get!("/api/v1/models", _ -> json(models_json()))
    _get!("/api/v1/models/:id::Int", ctx -> begin
        id = param(ctx, Int, :id)
        (1 <= id <= length(MODELS)) || return fail(404, "Unknown model")
        return json(model_json(MODELS[id]))
    end)
    _get!("/api/v1/files/*", ctx -> begin
        target = String(path(ctx))
        rest = startswith(target, "/api/v1/files/") ? target[15:end] : ""
        return json("{\"path\":\"$(json_escape(rest))\"}")
    end)
    _get!("/old", _ -> redirect("/"))
    _post!("/api/v1/predict", ctx -> begin
        features = parse_features(body(ctx))
        isempty(features) && return fail(422, "Expected comma-separated features")
        qp = queryparams(ctx)
        model_id = clamp(something(tryparse(Int, get(qp, "model", "1")), 1), 1, length(MODELS))
        t0 = time()
        sleep(think_s)                          # simulated inference
        score = sum(features) / length(features) + 0.01 * model_id
        return json("{\"model\":\"$(MODELS[model_id].name)\"," *
                    "\"prediction\":$(round(score; digits = 4))," *
                    "\"features\":$(length(features))," *
                    "\"latency_ms\":$(round((time() - t0) * 1000; digits = 1))}")
    end)

    _get!("/api/v1/echo", ctx -> begin
        qp = queryparams(ctx)
        pairs = join(("\"$(json_escape(k))\":\"$(json_escape(v))\"" for (k, v) in qp), ",")
        return json("{\"path\":\"$(json_escape(String(path(ctx))))\",\"query\":{$pairs}," *
                    "\"user_agent\":\"$(json_escape(header(ctx, "User-Agent", "")))\"," *
                    "\"host\":\"$(json_escape(header(ctx, "Host", "")))\"}")
    end)
    _post!("/api/v1/upload",
         ctx -> json("{\"received\":$(length(rawbody(ctx))),\"limit\":4096}");
         limits = RouteLimits(max_body_size = 4096))

    # Retention rule: copy(ctx) before handing to another task
    _get!("/api/v1/audit", ctx -> begin
        saved = copy(ctx)
        Threads.@spawn begin
            sleep(0.05)
            println("[audit] $(saved.request.method) $(saved.request.path) " *
                    "ua=$(header(saved.request, "User-Agent", "unknown"))")
        end
        return json("{\"audited\":true}")
    end)

    _get!("/api/v1/boom", _ -> error("intentional playground failure"))

    _get!("/api/v1/generate", ctx -> begin
        qp = queryparams(ctx)
        text = generate_text(get(qp, "prompt", ""), get(qp, "style", "plain"))
        words = split(text)
        return sse() do send
            for word in words
                send("{\"text\":\"$(json_escape(word)) \"}"; event = "delta")
                sleep(token_ms / 1000)
            end
            send("{\"text\":\"$(json_escape(text))\"}"; event = "done")
        end
    end)
    _get!("/api/v1/generate.txt", ctx -> begin
        qp = queryparams(ctx)
        text = generate_text(get(qp, "prompt", ""), get(qp, "style", "plain"))
        words = split(text)
        return stream(; content_type = "text/plain; charset=utf-8") do w
            for (i, word) in enumerate(words)
                print(w, word)
                i < length(words) && print(w, ' ')
                sleep(token_ms / 1000)
            end
        end
    end)

    _get!("/admin/config", RequireToken(admin_token, _ -> json(
        "{\"service\":\"$(SERVICE.name)\",\"version\":\"$(SERVICE.version)\"," *
        "\"port\":$port,\"backend\":\"$backend\"," *
        "\"executor\":\"$(nameof(typeof(executor)))\"," *
        "\"max_body_size\":$max_body_size,\"max_connections\":$max_connections," *
        "\"admin_token\":\"***\"}")))
    _get!("/admin/log/tail", RequireToken(admin_token, _ ->
        json("{\"lines\":[" *
             join(("\"" * json_escape(l) * "\"" for l in tail_lines(telemetry)), ",") *
             "]}")))
    _post!("/admin/maintenance", RequireToken(admin_token, ctx -> begin
        state = String(strip(body(ctx)))
        if state == "on"
            maintenance[] = true
        elseif state == "off"
            maintenance[] = false
        else
            return fail(400, "expected body 'on' or 'off'")
        end
        return json("{\"maintenance\":$(maintenance[])}")
    end))

    # CORS preflight only where the UI sends non-simple requests: `DELETE`
    # (routes card) and the `X-Admin-Token` header. A root `OPTIONS` wildcard
    # would make every unknown path a 405, so register these explicitly.
    _options!("/api/v1/predict")
    _options!("/admin/stats")
    _options!("/admin/config")
    _options!("/admin/log/tail")
    _options!("/admin/maintenance")

    server = Server(; router, port, backend, executor, telemetry, catcher,
                    logger = ConsoleLogger(),
                    max_body_size, max_connections, idle_timeout_ms = 120_000)

    _get!("/admin/stats", RequireToken(admin_token, _ -> json(
        metrics_json(telemetry.metrics)[1:end-1] * "," *
        "\"active_connections\":$(server.runtime.conn_count[])," *
        "\"max_connections\":$max_connections," *
        "\"maintenance\":$(maintenance[])}")))

    return server
end

# Environment configuration

function _env_int(key::String, default::Int)::Int
    raw = get(ENV, key, "")
    isempty(raw) && return default
    value = tryparse(Int, raw)
    value === nothing && error("$key must be an integer, got $(repr(raw))")
    return value
end

"""
Event-loop workers for the async server. The sync server adds one engine to the
same process, so leave at least one thread free for the async handlers (engine
loops that occupy every thread starve the executor's tasks).
"""
async_worker_budget(requested::Int, nthreads::Int)::Int =
    max(1, min(requested, nthreads - 2))

function main()
    # Positional args override the environment: `server.jl [port] [backend]`.
    port        = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : _env_int("CIRO_PORT", 8080)
    backend     = length(ARGS) >= 2 ? Symbol(ARGS[2]) :
                  Symbol(get(ENV, "CIRO_BACKEND", "uring"))
    nworkers    = _env_int("CIRO_WORKERS", Threads.nthreads())
    token_ms    = _env_int("CIRO_TOKEN_MS", 40)
    think_ms    = _env_int("CIRO_THINK_MS", 400)
    admin_token = get(ENV, "CIRO_ADMIN_TOKEN", "demo-token")
    pool        = _env_int("CIRO_WORKER_THREADS", 32)

    ports = (port, port + 1)     # advertised to the UI by both servers
    async_server = build_playground(; port, backend, admin_token, token_ms, ports,
        think_s = think_ms / 1000,
        executor = AsyncExecutor(worker_threads = pool, max_pending = 2 * pool))
    sync_server = build_playground(; port = port + 1, backend, admin_token, token_ms, ports,
        think_s = think_ms / 1000, executor = SyncExecutor())

    async_workers = async_worker_budget(nworkers, Threads.nthreads())
    println("""
    Ciro.jl playground
      async executor  http://localhost:$port      backend=:$backend  workers=$async_workers
      sync executor   http://localhost:$(port + 1)      (same routes, SyncExecutor, 1 worker)

      Generate streams tokens over SSE and chunked text; Predict is a slow handler.
      On the async server other requests stay responsive; on the sync server a slow
      handler blocks the engine. Streaming requires the async executor, so the sync
      server answers 500 for /generate.

      token: $admin_token   ·   stop: Ctrl-C (graceful drain)
    """)

    sync_task = Threads.@spawn start!(sync_server; nworkers = 1)
    try
        start!(async_server; nworkers = async_workers)
    finally
        stop!(sync_server)
        try
            wait(sync_task)
        catch
        end
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
