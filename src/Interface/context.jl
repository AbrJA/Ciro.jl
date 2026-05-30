# ══════════════════════════════════════════════════════════════════════════════
# Context — the single argument passed to every handler
# ══════════════════════════════════════════════════════════════════════════════

"""
    Context

Encapsulates a single HTTP request and the route parameters captured during
dispatch. Every handler receives exactly one `Context` argument.

```julia
function my_handler(ctx::Context)
    id   = param(ctx, Int, :id)           # typed route param
    ua   = header(ctx, "User-Agent")      # request header
    data = body(ctx)                       # body as String
    qp   = queryparams(ctx)               # Dict{String,String}
    sess = cookie(ctx, "session")         # cookie value
    ctx.req                               # raw PicoHTTPParser.Request
end
```
"""
struct Context
    req    :: Request
    params :: Vector{Pair{Symbol,String}}
end

"""Construct a `Context` with no route parameters (for middleware and tests)."""
Context(req::Request) = Context(req, Pair{Symbol,String}[])

export Context
