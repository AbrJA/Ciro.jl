"""
    Middleware

Zero-cost functor middlewares for the Ciro ecosystem.

Each middleware is a callable struct that wraps a handler.
Julia's compiler monomorphizes the entire chain into one inlined function.

```julia
# This becomes a SINGLE function at compile time — zero virtual dispatch:
handler = WithCORS(WithTiming(my_endpoint))
```

# Creating Your Own (30 seconds):
```julia
struct MyAuth{H}; handler::H; token::String; end
function (m::MyAuth)(req)
    req_header(req, "Authorization") == "Bearer \$(m.token)" || return error_response(401)
    m.handler(req)
end
# Use: get!(router, "/admin", MyAuth(my_handler, "secret"))
```
"""
module Middleware

using ..Interfaces
using ..Interfaces: Request, Response, Methods, text, fail, header

export WithLogger, WithCORS, WithTiming, WithRequestId, cors

# ══════════════════════════════════════════════════════════════════════════════
# Logger
# ══════════════════════════════════════════════════════════════════════════════

"""Log request method, path, status, and timing to stdout."""
struct WithLogger{H}
    handler :: H
end

function (m::WithLogger)(req::Request)::Response
    start = time_ns()
    response = m.handler(req)
    elapsed_us = (time_ns() - start) / 1_000

    ts = Libc.strftime("[%Y-%m-%d %H:%M:%S]", Libc.TmStruct(time()))
    method_str = String(req.method)
    path_str = String(req.path)

    if elapsed_us < 1000.0
        println(ts, ' ', method_str, ' ', path_str, " -> ", response.status,
                " (", round(elapsed_us; digits=1), "μs)")
    else
        println(ts, ' ', method_str, ' ', path_str, " -> ", response.status,
                " (", round(elapsed_us / 1000; digits=2), "ms)")
    end
    return response
end

# ══════════════════════════════════════════════════════════════════════════════
# CORS
# ══════════════════════════════════════════════════════════════════════════════

"""Add CORS headers. Handles preflight OPTIONS automatically."""
struct WithCORS{H}
    handler :: H
    origins :: String
    methods :: String
    headers :: String
    max_age :: String
end

function WithCORS(handler; origins="*",
                  methods="GET, POST, PUT, DELETE, PATCH, OPTIONS",
                  headers="Content-Type, Authorization, X-Requested-With",
                  max_age=86400)
    WithCORS(handler, origins, methods, headers, string(max_age))
end

function (m::WithCORS)(req::Request)::Response
    if Methods.from_string(req.method) == Methods.OPTIONS
        return Response(204, [
            "Access-Control-Allow-Origin"  => m.origins,
            "Access-Control-Allow-Methods" => m.methods,
            "Access-Control-Allow-Headers" => m.headers,
            "Access-Control-Max-Age"       => m.max_age,
        ], UInt8[])
    end

    response = m.handler(req)
    push!(response.headers, "Access-Control-Allow-Origin" => m.origins)
    return response
end

# ══════════════════════════════════════════════════════════════════════════════
# Timing
# ══════════════════════════════════════════════════════════════════════════════

"""Add `X-Response-Time` header."""
struct WithTiming{H}
    handler :: H
end

function (m::WithTiming)(req::Request)::Response
    start = time_ns()
    response = m.handler(req)
    elapsed_ms = (time_ns() - start) / 1_000_000
    push!(response.headers, "X-Response-Time" => string(round(elapsed_ms; digits=3), "ms"))
    return response
end

# ══════════════════════════════════════════════════════════════════════════════
# Request ID
# ══════════════════════════════════════════════════════════════════════════════

"""Add unique `X-Request-Id` header."""
struct WithRequestId{H}
    handler :: H
end

function (m::WithRequestId)(req::Request)::Response
    response = m.handler(req)
    id = string(Threads.threadid(), '-', time_ns())
    push!(response.headers, "X-Request-Id" => id)
    return response
end

# ══════════════════════════════════════════════════════════════════════════════
# CORS Factory
# ══════════════════════════════════════════════════════════════════════════════

"""
    cors(; origins="*", methods=..., headers=..., max_age=86400)

Returns a function that wraps any handler with CORS headers.

```julia
protected = cors(origins="https://mysite.com")(my_handler)
```
"""
function cors(; origins="*",
               methods="GET, POST, PUT, DELETE, PATCH, OPTIONS",
               headers="Content-Type, Authorization, X-Requested-With",
               max_age=86400)
    return handler -> WithCORS(handler; origins, methods, headers, max_age)
end

end # module Middleware
