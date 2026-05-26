#!/usr/bin/env julia
# End-to-end integration test.
# Starts a real server, sends HTTP requests via Sockets, verifies responses.

using Ciro
using Sockets

# Build app
router = Router()
get!(router, "/", req -> text("Hello, World!"))
get!(router, "/json", req -> json("""{"status":"ok","version":"0.1.0"}"""))
get!(router, "/users/:id", req -> text("User: $(route_param(:id))"))
post!(router, "/echo", req -> text(String(copy(req.body))))
get!(router, "/timed", WithTiming(req -> text("fast")))
get!(router, "/cors", WithCORS(req -> text("cors")))
options!(router, "/cors", WithCORS(req -> text("cors")))
get!(router, "/headers", req -> begin
    host = header(req, "Host")
    text("Host: $host")
end)

server = Server(; router, port=19876)

# Start in background (1 worker leaves main thread free for test client)
task = Threads.@spawn start!(server; nworkers=1)

# Wait for server to be ready (retry connect)
function wait_for_server(port, timeout=5.0)
    deadline = time() + timeout
    while time() < deadline
        try
            sock = Sockets.connect("127.0.0.1", port)
            close(sock)
            return true
        catch
            sleep(0.05)
        end
    end
    return false
end

if !wait_for_server(19876)
    println("ERROR: Server failed to start!")
    exit(1)
end

# ── HTTP Client Helper ──────────────────────────────────────────────────────

function http_request(method::String, path::String; body::String="", headers::Dict{String,String}=Dict{String,String}())
    sock = Sockets.connect("127.0.0.1", 19876)
    try
        # Build request
        req = "$method $path HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
        for (k, v) in headers
            req *= "$k: $v\r\n"
        end
        if !isempty(body)
            req *= "Content-Length: $(sizeof(body))\r\n"
        end
        req *= "\r\n$body"

        write(sock, req)

        # Read response (eof blocks until data or close)
        response_data = UInt8[]
        try
            while !eof(sock)
                append!(response_data, readavailable(sock))
            end
        catch e
            e isa Base.IOError || rethrow()
        end
        return String(response_data)
    finally
        try close(sock) catch end
    end
end

function get_status(response::String)::Int
    m = match(r"HTTP/1\.1 (\d+)", response)
    m === nothing && return 0
    return parse(Int, m.captures[1])
end

function get_body(response::String)::String
    idx = findfirst("\r\n\r\n", response)
    idx === nothing && return ""
    return response[last(idx)+1:end]
end

function get_header_value(response::String, key::String)::String
    for line in split(response, "\r\n")
        if startswith(lowercase(line), lowercase(key) * ":")
            return strip(split(line, ":"; limit=2)[2])
        end
    end
    return ""
end

# ── Run Tests ───────────────────────────────────────────────────────────────

println("Running end-to-end tests...")
errors = 0
total = 0

function check(description, condition::Bool)
    global errors, total
    total += 1
    if condition
        println("  ✓ $description")
    else
        println("  ✗ $description")
        errors += 1
    end
end

# Basic GET
resp = http_request("GET", "/")
check("GET / -> 200 Hello World", get_status(resp) == 200 && get_body(resp) == "Hello, World!")

# JSON response
resp = http_request("GET", "/json")
check("GET /json -> JSON body", get_body(resp) == """{"status":"ok","version":"0.1.0"}""")

# Path parameters
resp = http_request("GET", "/users/42")
check("GET /users/:id -> param extraction", get_body(resp) == "User: 42")

resp = http_request("GET", "/users/hello-world")
check("GET /users/:id -> string param", get_body(resp) == "User: hello-world")

# POST with body
resp = http_request("POST", "/echo"; body="test body content")
check("POST /echo -> echoes body", get_body(resp) == "test body content")

# Timing middleware
resp = http_request("GET", "/timed")
check("GET /timed -> body ok", get_body(resp) == "fast")
check("GET /timed -> X-Response-Time header", !isempty(get_header_value(resp, "X-Response-Time")))

# CORS middleware
resp = http_request("GET", "/cors")
check("GET /cors -> body ok", get_body(resp) == "cors")
check("GET /cors -> CORS header", get_header_value(resp, "Access-Control-Allow-Origin") == "*")

# OPTIONS preflight
resp = http_request("OPTIONS", "/cors")
check("OPTIONS /cors -> 204", get_status(resp) == 204)
check("OPTIONS /cors -> Allow-Methods header", !isempty(get_header_value(resp, "Access-Control-Allow-Methods")))

# 404
resp = http_request("GET", "/nonexistent")
check("GET /nonexistent -> 404", get_status(resp) == 404)

# Custom headers passed through
resp = http_request("GET", "/headers")
check("GET /headers -> reads Host header", contains(get_body(resp), "Host: localhost"))

# Method mismatch
resp = http_request("DELETE", "/")
check("DELETE / -> 404 (only GET registered)", get_status(resp) == 404)

# Stop server
stop!(server)
sleep(0.2)

# Summary
println()
if errors == 0
    println("═══════════════════════════════════")
    println("  ALL $total E2E TESTS PASSED ✓")
    println("═══════════════════════════════════")
else
    println("═══════════════════════════════════")
    println("  $errors/$total TESTS FAILED ✗")
    println("═══════════════════════════════════")
    exit(1)
end
