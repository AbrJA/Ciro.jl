"""Route endpoint with an optional compile-time-visible metadata value."""

struct Endpoint{H,M,L}
    handler  :: H
    metadata :: M
    limits   :: L
end

Endpoint(handler; metadata=nothing, limits=nothing) = Endpoint(handler, metadata, limits)

@inline (endpoint::Endpoint)(context::RequestContext) = endpoint.handler(context)

"""
    RouteLimits(; max_body_size=-1, body_timeout_ms=-1)

Per-route overrides for the server-wide limits. `-1` means "inherit the server
value". Attach at registration:

```julia
post!(router, "/upload", upload_handler; limits=RouteLimits(max_body_size=1_000_000))
```

`max_body_size` is enforced from the framing headers, before the body is read
(a `Content-Length` over the limit is answered with 413 immediately; a chunked
body is rejected as soon as the decoded size passes it). `body_timeout_ms`
replaces the server body deadline for this route.
"""
struct RouteLimits
    max_body_size   :: Int
    body_timeout_ms :: Int
    function RouteLimits(; max_body_size::Int=-1, body_timeout_ms::Int=-1)
        max_body_size >= -1 ||
            throw(ArgumentError("max_body_size must be >= -1, got $max_body_size"))
        body_timeout_ms >= -1 ||
            throw(ArgumentError("body_timeout_ms must be >= -1, got $body_timeout_ms"))
        return new(max_body_size, body_timeout_ms)
    end
end

"Limits of a matched handler, if it carries any."
@inline route_limits(handler)::Union{Nothing,RouteLimits} =
    handler isa Endpoint ? handler.limits : nothing

export Endpoint, RouteLimits, route_limits
