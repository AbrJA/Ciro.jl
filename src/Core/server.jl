# ══════════════════════════════════════════════════════════════════════════════
# Server — Parametric, fully monomorphized
# ══════════════════════════════════════════════════════════════════════════════

struct Server{
    R <: AbstractRouter,
    L <: AbstractLogger,
    C <: AbstractCatcher,
}
    router          :: R
    logger          :: L
    catcher         :: C
    host            :: String
    port            :: Int
    backlog         :: Int
    max_body_size   :: Int
    shutdown_timeout:: Float64
    _running        :: Threads.Atomic{Bool}
    _in_flight      :: Threads.Atomic{Int}
end

function Server(;
    router::AbstractRouter,
    logger::AbstractLogger      = NullLogger(),
    catcher::AbstractCatcher    = DefaultCatcher(),
    host::String                = "0.0.0.0",
    port::Int                   = 8080,
    backlog::Int                = 8192,
    max_body_size::Int          = 1_048_576,
    shutdown_timeout::Float64   = 5.0,
)
    Server(router, logger, catcher, host, port, backlog, max_body_size,
           shutdown_timeout, Threads.Atomic{Bool}(false), Threads.Atomic{Int}(0))
end

"""
    start!(server; queue_depth=4096, nworkers=nthreads())

Start the server. Blocks until `stop!()` is called or an interrupt is received.
On interrupt, performs graceful shutdown: stops accepting new connections and
drains in-flight requests up to `shutdown_timeout` seconds.
"""
function start!(server::Server; queue_depth::Int=4096, nworkers::Int=nthreads())
    server._running[] = true
    write(server.logger, Info, "Ciro starting on $(server.host):$(server.port)")
    try
        _start_workers(server, queue_depth, nworkers)
    catch e
        e isa InterruptException || rethrow(e)
    finally
        write(server.logger, Info, "Ciro shutting down (draining in-flight requests)...")
        server._running[] = false
        _drain(server)
        write(server.logger, Info, "Ciro stopped")
    end
end

"""Stop the server gracefully."""
function stop!(server::Server)
    server._running[] = false
    write(server.logger, Info, "Ciro stop requested")
end

"""Wait for in-flight requests to complete (up to timeout)."""
function _drain(server::Server)
    deadline = time() + server.shutdown_timeout
    while server._in_flight[] > 0 && time() < deadline
        sleep(0.01)
    end
    remaining = server._in_flight[]
    remaining > 0 && write(server.logger, Warn,
        "Shutdown timeout: $remaining request(s) still in-flight")
end
