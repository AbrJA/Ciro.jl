# ══════════════════════════════════════════════════════════════════════════════
# Server — Parametric, trimable server struct
# ══════════════════════════════════════════════════════════════════════════════

"""
    Server{R, L, C}

Composable HTTP server. All components are type parameters → monomorphized:
- `R <: AbstractRouter`       — Request routing
- `L <: AbstractLogger`       — System logging
- `C <: AbstractCatcher`      — Error → Response conversion

AOT-compatible: all types are concrete, no dynamic dispatch.
"""
struct Server{
    R <: AbstractRouter,
    L <: AbstractLogger,
    C <: AbstractCatcher,
}
    router        :: R
    logger        :: L
    catcher       :: C
    host          :: String
    port          :: Int
    backlog       :: Int
    max_body_size :: Int
    _running      :: Threads.Atomic{Bool}
end

"""
    Server(; router, logger=NullLogger(), catcher=DefaultCatcher(), ...)

Create a server. Only `router` is required.
"""
function Server(;
    router::AbstractRouter,
    logger::AbstractLogger = NullLogger(),
    catcher::AbstractCatcher = DefaultCatcher(),
    host::String  = "0.0.0.0",
    port::Int     = 8080,
    backlog::Int  = 8192,
    max_body_size::Int = 1_048_576,
)
    Server(router, logger, catcher, host, port, backlog, max_body_size,
           Threads.Atomic{Bool}(false))
end

"""
    start!(server; queue_depth=4096, nworkers=nthreads())

Start the server using io_uring. Blocks until `stop!()` or interrupt.
Uses one io_uring engine per worker (SO_REUSEPORT load balancing).
"""
function start!(server::Server; queue_depth::Int=4096, nworkers::Int=nthreads())
    server._running[] = true
    write(server.logger, Info, "Ciro starting on $(server.host):$(server.port)")
    _start_workers(server, queue_depth, nworkers)
end

"""Stop the server gracefully."""
function stop!(server::Server)
    server._running[] = false
    write(server.logger, Info, "Ciro stopping")
end
