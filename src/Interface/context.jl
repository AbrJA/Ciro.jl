# ══════════════════════════════════════════════════════════════════════════════
# RequestContext — the single argument passed to every handler
# ══════════════════════════════════════════════════════════════════════════════

"""
    RequestContext

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
struct RequestContext{R,P}
    request :: R
    params  :: P
end

"""
    copy(context::RequestContext) -> RequestContext

Owned copy of the request and its params. The context a handler receives
holds views into the connection buffer (and, for route params, ranges into the
request path) that are only valid until the handler returns; use this to
retain or hand them to another task.
"""
Base.copy(ctx::RequestContext) = RequestContext(copy(ctx.request), _materialize_params(ctx))

"""Construct a `RequestContext` with no route parameters."""
RequestContext(request::Request) = RequestContext(request, ())
RequestContext(request::PicoHTTPParser.Request, params) =
    RequestContext(Request(request), params)
RequestContext(request::PicoHTTPParser.Request) = RequestContext(Request(request))

# Kept as a source-level alias while the internal modules are migrated. New
# code should use RequestContext.
const Context = RequestContext

export RequestContext, Context
