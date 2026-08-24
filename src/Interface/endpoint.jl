"""Route endpoint with an optional compile-time-visible metadata value."""

struct Endpoint{H,M}
    handler  :: H
    metadata :: M
end

Endpoint(handler; metadata=nothing) = Endpoint(handler, metadata)

@inline (endpoint::Endpoint)(context::RequestContext) = endpoint.handler(context)

export Endpoint
