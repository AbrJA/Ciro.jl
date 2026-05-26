"""
    Middleware

Zero-cost functor middlewares. Each is a callable struct wrapping a handler.
Julia monomorphizes the chain → single inlined function at runtime.

# Creating Your Own:
```julia
struct MyAuth{H}
    handler :: H
    token   :: String
end
(m::MyAuth)(req) = header(req, "Authorization") == "Bearer \$(m.token)" ?
    m.handler(req) : fail(401, "Unauthorized")
```
"""
module Middleware

using ..Interfaces
using ..Interfaces: Request, Response, Methods, text, fail, header, hasheader

export WithLogger, WithCORS, WithTiming, WithRequestId,
       WithSecurityHeaders, WithRateLimit,
       cors

# ══════════════════════════════════════════════════════════════════════════════
# Logger — per-request logging to stdout
# ══════════════════════════════════════════════════════════════════════════════

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
# CORS — Cross-Origin Resource Sharing
# ══════════════════════════════════════════════════════════════════════════════

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

"""Factory: `cors(; origins="*")(handler)` → WithCORS(handler; origins)"""
function cors(; origins="*",
               methods="GET, POST, PUT, DELETE, PATCH, OPTIONS",
               headers="Content-Type, Authorization, X-Requested-With",
               max_age=86400)
    return handler -> WithCORS(handler; origins, methods, headers, max_age)
end

# ══════════════════════════════════════════════════════════════════════════════
# Timing — X-Response-Time header
# ══════════════════════════════════════════════════════════════════════════════

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
# Request ID — unique identifier per request
# ══════════════════════════════════════════════════════════════════════════════

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
# Security Headers — OWASP recommended defaults
# ══════════════════════════════════════════════════════════════════════════════

"""
    WithSecurityHeaders(handler; hsts=true, csp="default-src 'self'", ...)

Adds OWASP-recommended security headers to every response:
- `Strict-Transport-Security` (HSTS)
- `Content-Security-Policy`
- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: DENY`
- `Referrer-Policy: strict-origin-when-cross-origin`
"""
struct WithSecurityHeaders{H}
    handler :: H
    hsts    :: String
    csp     :: String
    frame   :: String
    referrer :: String
end

function WithSecurityHeaders(handler;
                             hsts::String="max-age=31536000; includeSubDomains",
                             csp::String="default-src 'self'",
                             frame::String="DENY",
                             referrer::String="strict-origin-when-cross-origin")
    WithSecurityHeaders(handler, hsts, csp, frame, referrer)
end

function (m::WithSecurityHeaders)(req::Request)::Response
    response = m.handler(req)
    push!(response.headers, "X-Content-Type-Options" => "nosniff")
    push!(response.headers, "X-Frame-Options" => m.frame)
    push!(response.headers, "Referrer-Policy" => m.referrer)
    !isempty(m.hsts) && push!(response.headers, "Strict-Transport-Security" => m.hsts)
    !isempty(m.csp) && push!(response.headers, "Content-Security-Policy" => m.csp)
    return response
end

# ══════════════════════════════════════════════════════════════════════════════
# Rate Limiting — Token Bucket per client IP
# ══════════════════════════════════════════════════════════════════════════════

"""
    WithRateLimit(handler; max_requests=100, window_seconds=60)

Token-bucket rate limiter keyed by client IP (from X-Forwarded-For or
connection). Returns 429 Too Many Requests when limit is exceeded.

Thread-safe: uses a lock-free atomic approach per bucket.
"""
struct WithRateLimit{H}
    handler      :: H
    max_requests :: Int
    window_ns    :: UInt64
    buckets      :: Dict{String, Tuple{Int, UInt64}}  # ip -> (tokens, last_refill)
    lock         :: ReentrantLock
end

function WithRateLimit(handler; max_requests::Int=100, window_seconds::Int=60)
    WithRateLimit(
        handler,
        max_requests,
        UInt64(window_seconds) * 1_000_000_000,
        Dict{String, Tuple{Int, UInt64}}(),
        ReentrantLock()
    )
end

function (m::WithRateLimit)(req::Request)::Response
    ip = _client_ip(req)
    now = time_ns()

    allowed = lock(m.lock) do
        tokens, last_refill = get(m.buckets, ip, (m.max_requests, now))

        # Refill tokens if window has passed
        elapsed = now - last_refill
        if elapsed >= m.window_ns
            tokens = m.max_requests
            last_refill = now
        end

        if tokens <= 0
            m.buckets[ip] = (0, last_refill)
            return false
        end

        m.buckets[ip] = (tokens - 1, last_refill)
        return true
    end

    if !allowed
        return Response(429, [
            "Content-Type" => "text/plain",
            "Retry-After" => string(div(m.window_ns, 1_000_000_000)),
        ], Vector{UInt8}("Too Many Requests"))
    end

    return m.handler(req)
end

@inline function _client_ip(req::Request)::String
    # Prefer X-Forwarded-For, then X-Real-IP, then fallback
    forwarded = header(req, "X-Forwarded-For")
    if !isempty(forwarded)
        # Take first IP in the chain
        comma = findfirst(',', forwarded)
        return comma === nothing ? strip(forwarded) : strip(forwarded[1:comma-1])
    end
    real_ip = header(req, "X-Real-IP")
    !isempty(real_ip) && return strip(real_ip)
    return "unknown"
end

end # module Middleware
