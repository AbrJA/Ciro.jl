# ══════════════════════════════════════════════════════════════════════════════
# Ciro REST API — Production-ready benchmark application
# ══════════════════════════════════════════════════════════════════════════════
#
# Build:
#   juliac --trim=safe --project=. --output-exe ciro_api examples/api/server.jl
#
# Run:
#   julia -t$(nproc) --project=. examples/api/server.jl
#   # or compiled:
#   ./ciro_api
#
# Test:
#   curl http://localhost:8080/
#   curl http://localhost:8080/json
#   curl http://localhost:8080/users/42
#   curl -X POST -H "Content-Type: application/json" -d '{"name":"test"}' http://localhost:8080/users
#   curl -X PUT -H "Content-Type: application/json" -d '{"name":"new"}' http://localhost:8080/users/1
#   curl -X DELETE http://localhost:8080/users/1
#   curl "http://localhost:8080/search?q=hello&page=2"
#   curl http://localhost:8080/headers -H "X-Custom: test"
#   curl http://localhost:8080/health
#   curl http://localhost:8080/nonexistent
# ══════════════════════════════════════════════════════════════════════════════

using CiroCore
using CiroRouter
using CiroMiddleware

# ── Route Handlers ──────────────────────────────────────────────────────────

# Plaintext — TechEmpower benchmark style
function handle_plaintext(req::Request)::Response
    text("Hello, World!")
end

# JSON — TechEmpower benchmark style
function handle_json(req::Request)::Response
    json_response("{\"message\":\"Hello, World!\"}")
end

# Health check
function handle_health(req::Request)::Response
    json_response("{\"status\":\"ok\"}")
end

# GET user by ID
function handle_get_user(req::Request)::Response
    id = route_param(:id)
    json_response("{\"id\":$id,\"name\":\"User $id\",\"email\":\"user$id@example.com\"}")
end

# POST create user
function handle_create_user(req::Request)::Response
    body = String(copy(req.body))
    Response(201,
        ["Content-Type" => "application/json; charset=utf-8"],
        Vector{UInt8}("{\"created\":true,\"data\":$body}"))
end

# PUT update user
function handle_update_user(req::Request)::Response
    id = route_param(:id)
    body = String(copy(req.body))
    json_response("{\"updated\":true,\"id\":$id,\"data\":$body}")
end

# DELETE user
function handle_delete_user(req::Request)::Response
    id = route_param(:id)
    Response(204, Pair{String,String}[], UInt8[])
end

# PATCH partial update
function handle_patch_user(req::Request)::Response
    id = route_param(:id)
    json_response("{\"patched\":true,\"id\":$id}")
end

# Search with query params
function handle_search(req::Request)::Response
    qs = query_string(req)
    json_response("{\"query\":\"$qs\",\"results\":[]}")
end

# Echo headers back
function handle_headers(req::Request)::Response
    pairs = String[]
    for (k, v) in req.headers
        push!(pairs, "\"$(String(k))\":\"$(String(v))\"")
    end
    json_response("{" * join(pairs, ",") * "}")
end

# Calc — nested params
function handle_calc(req::Request)::Response
    op = route_param(:op)
    a = parse(Float64, route_param(:a))
    b = parse(Float64, route_param(:b))
    result = if op == "add"
        a + b
    elseif op == "sub"
        a - b
    elseif op == "mul"
        a * b
    elseif op == "div"
        b == 0.0 ? NaN : a / b
    else
        return error_response(400, "Unknown operation: $op")
    end
    json_response("{\"op\":\"$op\",\"a\":$a,\"b\":$b,\"result\":$result}")
end

# Items CRUD (in-memory store for demo)
function handle_list_items(req::Request)::Response
    json_response("[{\"id\":1,\"name\":\"item1\"},{\"id\":2,\"name\":\"item2\"}]")
end

function handle_get_item(req::Request)::Response
    id = route_param(:id)
    json_response("{\"id\":$id,\"name\":\"item$id\"}")
end

function handle_create_item(req::Request)::Response
    body = String(copy(req.body))
    Response(201,
        ["Content-Type" => "application/json; charset=utf-8"],
        Vector{UInt8}("{\"created\":true,\"item\":$body}"))
end

function handle_update_item(req::Request)::Response
    id = route_param(:id)
    body = String(copy(req.body))
    json_response("{\"updated\":true,\"id\":$id,\"item\":$body}")
end

function handle_delete_item(req::Request)::Response
    id = route_param(:id)
    Response(204, Pair{String,String}[], UInt8[])
end

# ── Router Setup ────────────────────────────────────────────────────────────

function build_router()::Router
    r = Router()

    # Core benchmark routes
    route_get!(r, "/", handle_plaintext)
    route_get!(r, "/plaintext", handle_plaintext)
    route_get!(r, "/json", handle_json)
    route_get!(r, "/health", handle_health)

    # Users CRUD
    route_get!(r, "/users/:id", handle_get_user)
    route_post!(r, "/users", handle_create_user)
    route_put!(r, "/users/:id", handle_update_user)
    route_delete!(r, "/users/:id", handle_delete_user)
    route_patch!(r, "/users/:id", handle_patch_user)

    # Search
    route_get!(r, "/search", handle_search)

    # Headers echo
    route_get!(r, "/headers", handle_headers)

    # Calculator
    route_get!(r, "/calc/:op/:a/:b", handle_calc)

    # Items CRUD
    route_get!(r, "/items", handle_list_items)
    route_get!(r, "/items/:id", handle_get_item)
    route_post!(r, "/items", handle_create_item)
    route_put!(r, "/items/:id", handle_update_item)
    route_delete!(r, "/items/:id", handle_delete_item)

    return r
end

# ── Entry Point ─────────────────────────────────────────────────────────────

function (@main)(ARGS)
    router = build_router()
    server = CiroServer(; router, port=8080)

    # Use ccall write to avoid abstract IO dispatch (trim=safe compatible)
    msg = b"Ciro API server starting on http://0.0.0.0:8080\n  Routes: 16\n  Press Ctrl+C to stop\n"
    @ccall write(1::Cint, msg::Ptr{UInt8}, length(msg)::Csize_t)::Cssize_t

    start!(server)
    return 0
end
