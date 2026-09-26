"""
    Ciro

A minimal, blazing-fast, extensible HTTP framework for Julia.
Built on Linux io_uring for maximum throughput with thread-per-core scaling.

# Quick Start
```julia
using Ciro

router = Trie()
get!(router, "/hello", ctx -> text("Hello, World!"))

server = Server(; router)
start!(server)
```

# Extension
- Low-level io_uring: `using Ciro.Backend`
"""
module Ciro

# Strict include order: each layer only depends on the ones above it.
# Runtime must precede Core (Core delegates to the Runtime pipeline).
include("Interface/Interface.jl")
include("Backend/Backend.jl")
include("Router/Router.jl")
include("Runtime/Runtime.jl")
include("HTTP/HTTP.jl")
include("Core/Core.jl")

using .Interface
using .Core
using .Router
using .Runtime
using .Backend: IOUringBackend
import PicoHTTPParser

# ── Public API ──────────────────────────────────────────────────────────────
# Types
export RequestContext, Context, Request, Response, Endpoint, RouteResult, Methods

# Response builders
export text, html, json, redirect, fail
export Stream, StreamWriter, StreamClosedError, stream, sse

# Request access
export header, hasheader, body, rawbody, content_type
export path, query, queryparams, param

# Routing
export Trie, register!, route, freeze!
export matched, not_found, method_not_allowed
export get!, post!, put!, delete!, patch!, head!, options!, group!

# Server
export Server, start!, stop!

# Extension points (abstract types + functions)
export AbstractRouter, AbstractLogger, AbstractCatcher, AbstractBackend
export AbstractExecutor, SyncExecutor, AsyncExecutor, execute!
export isasync, start_executor!, stop_executor!
export IOUringBackend
export NullLogger, DefaultCatcher
export Severity, Debug, Info, Warn, Error, Fatal
export log!, intercept, start_backend!, stop_backend!

# Runtime (transport-independent)
export Application, AbstractTransport, TransportToken, FakeTransport
export dispatch, dispatch_async, handle, run_once!, serve!, enqueue!, response_for
export send_response!, close!, transport_state

# ── Precompilation ──────────────────────────────────────────────────────────
using PrecompileTools

@setup_workload begin
    @compile_workload begin
        router = Trie()
        register!(router, Methods.GET, "/", ctx -> text("ok"))
        register!(router, Methods.GET, "/users/:id::Int", ctx -> json("{\"id\":1}"))
        register!(router, Methods.POST, "/data", ctx -> text("created"; status=201))

        # Simulate dispatch hot path
        raw = Vector{UInt8}("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)
        server = Server(; router, port=19999)
        resp = Core._dispatch(server, req)

        # Serialize response
        buf = Vector{UInt8}(undef, 4096)
        Core.serialize_response!(buf, resp)

        # Route with params
        raw2 = Vector{UInt8}("GET /users/42 HTTP/1.1\r\nHost: localhost\r\n\r\n")
        req2 = PicoHTTPParser.parse_request(raw2)
        Core._dispatch(server, req2)
    end
end

end
