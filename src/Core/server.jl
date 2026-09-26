# ══════════════════════════════════════════════════════════════════════════════
# Server — immutable Config + mutable Runtime + collaborators
# ══════════════════════════════════════════════════════════════════════════════

"""
    ServerConfig

Everything that is decided once and never changes while serving: bind address,
limits, deadlines, and shutdown budget. Validated at construction, so config
errors are startup errors.
"""
struct ServerConfig
    backend           :: Symbol
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
end

function ServerConfig(;
    backend::Symbol             = :uring,
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
    backend in (:uring, :sockets) ||
        throw(ArgumentError("backend must be :uring or :sockets, got :$backend"))
    isempty(host_str) && throw(ArgumentError("host must not be empty"))
    1 <= port <= 65535 || throw(ArgumentError("port must be in 1:65535, got $port"))
    backlog > 0 || throw(ArgumentError("backlog must be positive, got $backlog"))
    max_body_size >= 0 || throw(ArgumentError("max_body_size must be >= 0, got $max_body_size"))
    max_header_bytes > 0 || throw(ArgumentError("max_header_bytes must be positive, got $max_header_bytes"))
    header_timeout_ms > 0 || throw(ArgumentError("header_timeout_ms must be positive, got $header_timeout_ms"))
    body_timeout_ms > 0 || throw(ArgumentError("body_timeout_ms must be positive, got $body_timeout_ms"))
    idle_timeout_ms > 0 || throw(ArgumentError("idle_timeout_ms must be positive, got $idle_timeout_ms"))
    max_connections > 0 || throw(ArgumentError("max_connections must be positive, got $max_connections"))
    shutdown_timeout >= 0 || throw(ArgumentError("shutdown_timeout must be >= 0, got $shutdown_timeout"))
    return ServerConfig(backend, host_str, port, backlog, max_body_size, max_header_bytes,
                        header_timeout_ms, body_timeout_ms, idle_timeout_ms,
                        max_connections, shutdown_timeout)
end

"""Mutable per-process state: whether we are serving and how many connections
are open. Shared by the workers through the `Server` object."""
struct ServerRuntime
    running    :: Threads.Atomic{Bool}
    conn_count :: Threads.Atomic{Int}
end

ServerRuntime() = ServerRuntime(Threads.Atomic{Bool}(false), Threads.Atomic{Int}(0))

struct Server{
    R <: AbstractRouter,
    L <: AbstractLogger,
    C <: AbstractCatcher,
    E <: AbstractExecutor,
}
    router   :: R
    logger   :: L
    catcher  :: C
    executor :: E
    config   :: ServerConfig
    runtime  :: ServerRuntime
end

function Server(;
    router::AbstractRouter,
    logger::AbstractLogger      = NullLogger(),
    catcher::AbstractCatcher    = DefaultCatcher(),
    executor::AbstractExecutor  = SyncExecutor(),
    backend::Symbol             = :uring,
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
    config = ServerConfig(; backend, host, port, backlog, max_body_size, max_header_bytes,
                          header_timeout_ms, body_timeout_ms, idle_timeout_ms,
                          max_connections, shutdown_timeout)
    return Server(router, logger, catcher, executor, config, ServerRuntime())
end

"""
    start!(server; queue_depth=4096, nworkers=nthreads())

Start the server. Blocks until [`stop!`](@ref) is called or an interrupt
(SIGINT / Ctrl-C) is received. Shutdown is graceful: accepting stops
immediately, in-flight writes are flushed, idle keep-alive connections are
closed, and workers exit once every connection is released (or after
`config.shutdown_timeout` seconds).

!!! note
    SIGTERM cannot be intercepted by ordinary Julia code; send SIGINT instead
    (`docker stop --signal=SIGINT`, systemd `KillSignal=SIGINT`) or call
    [`stop!`](@ref) from another task.
"""
function start!(server::Server; queue_depth::Int=4096, nworkers::Int=nthreads())
    freeze!(server.router)
    server.runtime.running[] = true
    if isasync(server.executor) && nthreads() <= nworkers
        log!(server.logger, Warn,
             "async handlers share threads with $nworkers event loop(s); " *
             "run Julia with more threads than workers (e.g. --threads=$(nworkers + 1))")
    end
    start_executor!(server.executor)
    log!(server.logger, Info, "Ciro starting on $(server.config.host):$(server.config.port)")
    try
        _start_workers(server, queue_depth, nworkers)
    catch e
        e isa InterruptException || rethrow(e)
    finally
        server.runtime.running[] = false
        stop_executor!(server.executor)
        log!(server.logger, Info, "Ciro stopped")
    end
end

"""Request a graceful stop; `start!` drains and returns."""
function stop!(server::Server)
    server.runtime.running[] = false
    log!(server.logger, Info, "Ciro stop requested")
    return server
end
