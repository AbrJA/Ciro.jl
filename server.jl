#!/usr/bin/env julia
# ══════════════════════════════════════════════════════════════════════════════
# Ciro.jl — ML Model Serving Example
# Run: julia --threads=auto --project=. server.jl
# Test: curl http://localhost:8080/health
#       curl -X POST http://localhost:8080/api/v1/predict -d '{"features":[1.0,2.0,3.0]}'
# Deps: Pkg.add("JSON") — JSON is not bundled with Ciro (keeps core lightweight)
# ══════════════════════════════════════════════════════════════════════════════
using Ciro
using JSON

# ══════════════════════════════════════════════════════════════════════════════
# "Model" — simulates a loaded ML model (replace with your real model)
# ══════════════════════════════════════════════════════════════════════════════

struct MockModel
    weights :: Vector{Float64}
    bias    :: Float64
end

"""Simulate inference: dot(weights, features) + bias"""
function predict!(model::MockModel, features::Vector{Float64})::Float64
    length(features) != length(model.weights) && error("dimension mismatch")
    s = model.bias
    @inbounds for i in eachindex(model.weights)
        s += model.weights[i] * features[i]
    end
    return s
end

# Load model once at startup (const for type stability)
const MODEL = MockModel([0.5, -0.3, 0.8], 0.1)
const MODEL_VERSION = "mock-linear-v1"

# ══════════════════════════════════════════════════════════════════════════════
# Handlers
# ══════════════════════════════════════════════════════════════════════════════

function handle_health(ctx::Context)
    json("""{"status":"healthy","model":"$MODEL_VERSION","threads":$(Threads.nthreads())}""")
end

function handle_predict(ctx::Context)
    payload = body(ctx)
    isempty(payload) && return fail(400, """{"error":"empty body"}""")

    data = try
        JSON.parse(payload)
    catch e
        return fail(400, """{"error":"invalid JSON: $(e.msg)"}""")
    end

    features_raw = get(data, "features", nothing)
    features_raw === nothing && return fail(400, """{"error":"missing 'features' array"}""")
    features_raw isa Vector || return fail(400, """{"error":"'features' must be an array"}""")

    features = try
        Float64[Float64(x) for x in features_raw]
    catch
        return fail(400, """{"error":"'features' must contain numbers"}""")
    end

    result = try
        predict!(MODEL, features)
    catch e
        return fail(422, """{"error":"$(e.msg)"}""")
    end

    json("""{"prediction":$result,"model":"$MODEL_VERSION"}""")
end

function handle_batch_predict(ctx::Context)
    payload = body(ctx)
    isempty(payload) && return fail(400, """{"error":"empty body"}""")

    data = try
        JSON.parse(payload)
    catch e
        return fail(400, """{"error":"invalid JSON: $(e.msg)"}""")
    end

    batch = get(data, "batch", nothing)
    batch === nothing && return fail(400, """{"error":"missing 'batch' array"}""")
    batch isa Vector || return fail(400, """{"error":"'batch' must be an array of feature vectors"}""")

    predictions = Float64[]
    sizehint!(predictions, length(batch))

    for (i, item) in enumerate(batch)
        item isa Vector || return fail(400, """{"error":"batch[$i] must be an array"}""")
        features = try
            Float64[Float64(x) for x in item]
        catch
            return fail(400, """{"error":"batch[$i] contains non-numeric values"}""")
        end
        push!(predictions, predict!(MODEL, features))
    end

    preds_str = join(predictions, ",")
    json("""{"predictions":[$preds_str],"count":$(length(predictions)),"model":"$MODEL_VERSION"}""")
end

function handle_model_info(ctx::Context)
    json("""{
  "name":"$MODEL_VERSION",
  "input_dim":$(length(MODEL.weights)),
  "type":"linear",
  "weights":$(JSON.json(MODEL.weights)),
  "bias":$(MODEL.bias)
}""")
end

function handle_echo(ctx::Context)
    ct = content_type(ctx)
    payload = body(ctx)
    isempty(payload) && return fail(400, "Empty body")
    json("""{"content_type":"$ct","body_length":$(length(payload)),"echo":$(JSON.json(payload))}""")
end

function handle_root(ctx::Context)
    text("""Ciro.jl ML Server — v0.1.0
Endpoints:
  GET  /health                → Server health check
  GET  /api/v1/model          → Model metadata
  POST /api/v1/predict        → Single prediction
  POST /api/v1/batch          → Batch predictions
  POST /api/v1/echo           → Echo request body
""")
end

# ══════════════════════════════════════════════════════════════════════════════
# Custom Error Catcher — returns JSON errors (never leaks internals)
# ══════════════════════════════════════════════════════════════════════════════

struct JsonCatcher <: AbstractCatcher end

function Ciro.Interfaces.intercept(::JsonCatcher, err::Exception, _)
    @error "Unhandled exception" exception=err
    json("""{"error":"internal_server_error"}"""; status=500)
end

# ══════════════════════════════════════════════════════════════════════════════
# Middleware Stack
# ══════════════════════════════════════════════════════════════════════════════

const STACK = handler -> WithCORS(
    WithRequestId(
        WithTiming(
            WithLogger(handler)
        )
    )
)

# ══════════════════════════════════════════════════════════════════════════════
# Router
# ══════════════════════════════════════════════════════════════════════════════

router = Trie()

get!(router, "/", STACK(handle_root))
get!(router, "/health", STACK(handle_health))

group!(router, "/api/v1") do g
    get!(g, "/model", STACK(handle_model_info))
    post!(g, "/predict", STACK(handle_predict))
    post!(g, "/batch", STACK(handle_batch_predict))
    post!(g, "/echo", STACK(handle_echo))
end

# ══════════════════════════════════════════════════════════════════════════════
# Server
# ══════════════════════════════════════════════════════════════════════════════

server = Server(;
    router,
    catcher = JsonCatcher(),
    port    = 8080,
    host    = "0.0.0.0",
    max_body_size = 10 * 1_048_576,  # 10 MiB (batch payloads can be large)
    shutdown_timeout = 10.0,
)

println("""
╔══════════════════════════════════════════════════════════════╗
║  Ciro.jl ML Server                                          ║
║  http://localhost:8080                                       ║
║  Threads: $(lpad(Threads.nthreads(), 2))  |  Model: $MODEL_VERSION              ║
╠══════════════════════════════════════════════════════════════╣
║  Test with:                                                  ║
║  curl localhost:8080/health                                  ║
║  curl -X POST localhost:8080/api/v1/predict \\                ║
║       -H 'Content-Type: application/json' \\                  ║
║       -d '{"features":[1.0,2.0,3.0]}'                        ║
║  curl -X POST localhost:8080/api/v1/batch \\                  ║
║       -H 'Content-Type: application/json' \\                  ║
║       -d '{"batch":[[1,2,3],[4,5,6],[7,8,9]]}'               ║
╚══════════════════════════════════════════════════════════════╝
""")

start!(server)
