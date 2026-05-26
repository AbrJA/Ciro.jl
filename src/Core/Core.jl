"""
    Core

HTTP server engine built on Backend (io_uring).
Provides:
- `Server{R,L,E}` — parametric server struct (fully monomorphized)
- Zero-copy response serialization
- Thread-per-core request dispatch

trim=safe: no eval, no reflection, all concrete types.
"""
module Core

using ..Interfaces
using ..Interfaces: write
using ..Backend
using PicoHTTPParser
using Base.Threads: @threads, nthreads

include("server.jl")
include("serialize.jl")
include("worker.jl")

export Server, start!, stop!

end # module Core
