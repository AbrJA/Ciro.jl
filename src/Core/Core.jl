"""
    Core

HTTP server engine. Provides:
- `Server{R,L,C}` — parametric server struct (fully monomorphized)
- Zero-copy response serialization
- Thread-per-core request dispatch
- Graceful shutdown with request draining
"""
module Core

using ..Interfaces
using ..Interfaces: Response, RouteResult, matched, not_found, method_not_allowed, status, hasheader, write
using ..Backend
using PicoHTTPParser
using Base.Threads: @threads, nthreads

include("server.jl")
include("serialize.jl")
include("worker.jl")

export Server, start!, stop!

end # module Core
