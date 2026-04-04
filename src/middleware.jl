module Middlewares

using ..Types
using ..Types: Methods

export Logger, CORS, cors

# --- Logger Middleware ---

function Logger(req, next)
    start = time_ns()
    response = next(req)
    elapsed_us = (time_ns() - start) / 1_000

    # Safe timestamp via Julia's Libc (no buffer overflow risk)
    ts = Libc.strftime("[%Y-%m-%d %H:%M:%S]", Libc.TmStruct(time()))

    m = String(req.method)
    p = String(req.path)
    if elapsed_us < 1000.0
        println(ts, ' ', m, ' ', p, " -> ", response.status,
                " (", round(elapsed_us; digits=1), "μs)")
    else
        println(ts, ' ', m, ' ', p, " -> ", response.status,
                " (", round(elapsed_us / 1000; digits=2), "ms)")
    end
    return response
end

# --- CORS Middleware (default: permissive) ---

function CORS(req, next)
    if Methods.from_string(req.method) == Methods.OPTIONS
        return Response(204, [
            "Access-Control-Allow-Origin" => "*",
            "Access-Control-Allow-Methods" => "GET, POST, PUT, DELETE, PATCH, OPTIONS",
            "Access-Control-Allow-Headers" => "Content-Type, Authorization, X-Requested-With",
            "Access-Control-Max-Age" => "86400",
        ], UInt8[])
    end
    response = next(req)
    push!(response.headers, "Access-Control-Allow-Origin" => "*")
    return response
end

# Configurable CORS factory — returns a middleware function
function cors(;
    origins::String="*",
    methods::String="GET, POST, PUT, DELETE, PATCH, OPTIONS",
    headers::String="Content-Type, Authorization, X-Requested-With",
    max_age::Int=86400
)
    origin_hdr = "Access-Control-Allow-Origin" => origins
    preflight_hdrs = [
        origin_hdr,
        "Access-Control-Allow-Methods" => methods,
        "Access-Control-Allow-Headers" => headers,
        "Access-Control-Max-Age" => string(max_age),
    ]
    return function(req, next)
        if Methods.from_string(req.method) == Methods.OPTIONS
            return Response(204, copy(preflight_hdrs), UInt8[])
        end
        response = next(req)
        push!(response.headers, origin_hdr)
        return response
    end
end

end
