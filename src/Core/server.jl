# ══════════════════════════════════════════════════════════════════════════════
# Server — Parametric, fully monomorphized
# ══════════════════════════════════════════════════════════════════════════════

struct Server{
    R <: AbstractRouter,
    L <: AbstractLogger,
    C <: AbstractCatcher,
    E <: AbstractExecutor,
}
    router            :: R
    logger            :: L
    catcher           :: C
    executor          :: E
    host              :: String
    port              :: Int
    backlog           :: Int
    max_body_size     :: Int
    max_header_bytes  :: Int
    header_timeout_ms :: Int
    body_timeout_ms   :: Int
    idle_timeout_ms   :: Int
    max_connections   :: Int
    shutdown_timeout  :: Float64
    _running          :: Threads.Atomic{Bool}
    _in_flight        :: Threads.Atomic{Int}
    _conn_count       :: Threads.Atomic{Int}
end

function _validate_config(host::String, port::Int, backlog::Int, max_body_size::Int,
                          max_header_bytes::Int, header_timeout_ms::Int,
                          body_timeout_ms::Int, idle_timeout_ms::Int,
                          max_connections::Int, shutdown_timeout::Float64)
    isempty(host) && throw(ArgumentError("host must not be empty"))
    1 <= port <= 65535 || throw(ArgumentError("port must be in 1:65535, got $port"))
    backlog > 0 || throw(ArgumentError("backlog must be positive, got $backlog"))
    max_body_size >= 0 || throw(ArgumentError("max_body_size must be >= 0, got $max_body_size"))
    max_header_bytes > 0 || throw(ArgumentError("max_header_bytes must be positive, got $max_header_bytes"))
    header_timeout_ms > 0 || throw(ArgumentError("header_timeout_ms must be positive, got $header_timeout_ms"))
    body_timeout_ms > 0 || throw(ArgumentError("body_timeout_ms must be positive, got $body_timeout_ms"))
    idle_timeout_ms > 0 || throw(ArgumentError("idle_timeout_ms must be positive, got $idle_timeout_ms"))
    max_connections > 0 || throw(ArgumentError("max_connections must be positive, got $max_connections"))
    shutdown_timeout >= 0 || throw(ArgumentError("shutdown_timeout must be >= 0, got $shutdown_timeout"))
    return nothing
end

function Server(;
    router::AbstractRouter,
    logger::AbstractLogger      = NullLogger(),
    catcher::AbstractCatcher    = DefaultCatcher(),
    executor::AbstractExecutor  = SyncExecutor(),
    host::AbstractString        = "0.0.0.0",
    port::Int                   = 8080,
    backlog::Int                = 8192,
    max_body_size::Int          = 1_048_576,
    max_header_bytes::Int       = 65_536,
    header_timeout_ms::Int      = 5_000,
    body_timeout_ms::Int        = 30_000,
    idle_timeout_ms::Int        = 60_000,
    max_connections::Int        = 1024,
    shutdown_timeout::Float64   = 5.0,
)
    host_str = String(host)
    _validate_config(host_str, port, backlog, max_body_size, max_header_bytes,
                     header_timeout_ms, body_timeout_ms, idle_timeout_ms,
                     max_connections, shutdown_timeout)
    Server(router, logger, catcher, executor, host_str, port, backlog,
           max_body_size, max_header_bytes, header_timeout_ms, body_timeout_ms,
           idle_timeout_ms, max_connections, shutdown_timeout,
           Threads.Atomic{Bool}(false), Threads.Atomic{Int}(0), Threads.Atomic{Int}(0))
end

"""
    start!(server; queue_depth=4096, nworkers=nthreads())

Start the server. Blocks until `stop!()` is called or an interrupt is received.
On interrupt, performs graceful shutdown: stops accepting new connections and
drains in-flight requests up to `shutdown_timeout` seconds.
"""
function start!(server::Server; queue_depth::Int=4096, nworkers::Int=nthreads())
    freeze!(server.router)
    server._running[] = true
    log!(server.logger, Info, "Ciro starting on $(server.host):$(server.port)")
    try
        _start_workers(server, queue_depth, nworkers)
    catch e
        e isa InterruptException || rethrow(e)
    finally
        log!(server.logger, Info, "Ciro shutting down (draining in-flight requests)...")
        server._running[] = false
        _drain(server)
        log!(server.logger, Info, "Ciro stopped")
    end
end

"""Stop the server gracefully."""
function stop!(server::Server)
    server._running[] = false
    log!(server.logger, Info, "Ciro stop requested")
end

"""Wait for in-flight requests to complete (up to timeout)."""
function _drain(server::Server)
    deadline = time() + server.shutdown_timeout
    while server._in_flight[] > 0 && time() < deadline
        sleep(0.01)
    end
    remaining = server._in_flight[]
    remaining > 0 && log!(server.logger, Warn,
        "Shutdown timeout: $remaining request(s) still in-flight")
end
