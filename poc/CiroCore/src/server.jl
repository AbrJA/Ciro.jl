# ══════════════════════════════════════════════════════════════════════════════
# CiroServer — Parametric, trimable server struct
# ══════════════════════════════════════════════════════════════════════════════

"""
    CiroServer{R, L, E}

Composable HTTP server. All components are type parameters → monomorphized:
- `R <: AbstractRouter`       — Request routing
- `L <: AbstractLogger`       — System logging
- `E <: AbstractErrorHandler` — Error → Response conversion

AOT-compatible: all types are concrete, no dynamic dispatch.
"""
struct CiroServer{
    R <: AbstractRouter,
    L <: AbstractLogger,
    E <: AbstractErrorHandler,
}
    router        :: R
    logger        :: L
    error_handler :: E
    host          :: String
    port          :: Int
    backlog       :: Int
    max_body_size :: Int
    _running      :: Threads.Atomic{Bool}
end

"""
    CiroServer(; router, logger=NullLogger(), error_handler=DefaultErrorHandler(), ...)

Create a server. Only `router` is required.
"""
function CiroServer(;
    router::AbstractRouter,
    logger::AbstractLogger       = NullLogger(),
    error_handler::AbstractErrorHandler = DefaultErrorHandler(),
    host::String  = "0.0.0.0",
    port::Int     = 8080,
    backlog::Int  = 8192,
    max_body_size::Int = 1_048_576,
)
    CiroServer(router, logger, error_handler, host, port, backlog, max_body_size,
               Threads.Atomic{Bool}(false))
end

"""
    start!(server; queue_depth=4096, nworkers=nthreads())

Start the server using io_uring. Blocks until `stop!()` or interrupt.
Uses one io_uring engine per worker (SO_REUSEPORT load balancing).
"""
function start!(server::CiroServer; queue_depth::Int=4096, nworkers::Int=nthreads())
    server._running[] = true
    log_event(server.logger, INFO, "Ciro starting on $(server.host):$(server.port)")
    _start_workers(server, queue_depth, nworkers)
end

"""Stop the server gracefully."""
function stop!(server::CiroServer)
    server._running[] = false
    log_event(server.logger, INFO, "Ciro stopping")
end
