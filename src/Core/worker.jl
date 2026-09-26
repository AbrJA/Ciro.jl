# ══════════════════════════════════════════════════════════════════════════════
# UringIO — the io_uring adapter
#
# Owns the ring, the connection/buffer pools, per-connection pending writes, and
# the handle→state tables. The HTTP state machine lives in `HTTP` and only
# touches this through the `io_*` seam.
# ══════════════════════════════════════════════════════════════════════════════

const _MAX_POOLED_STATES = 256
const _SWEEP_INTERVAL    = 0.1   # seconds

"""Response bytes queued for one connection until the kernel reports them sent."""
mutable struct PendingWrite
    buf :: Vector{UInt8}
    len :: Int
    sent:: Int
end

"""Backend-side state for one accepted connection (fd + queued write)."""
mutable struct ConnEntry
    fd      :: Cint
    fd_open :: Bool
    pending :: Union{Nothing, PendingWrite}
end

"""
    UringIO <: AbstractIO

io_uring adapter: owns the ring, pools, pending writes, and the handle→state
tables. One per worker thread, never shared.
"""
mutable struct UringIO{S <: Server} <: AbstractIO
    server    :: S
    engine    :: Engine
    conn_pool :: ConnectionPool
    buf_pool  :: BufferPool
    cfg       :: HTTPConfig
    states    :: Dict{Ptr{Cvoid}, HTTPConn{Connection}}
    entries   :: Dict{Ptr{Cvoid}, ConnEntry}
    free      :: Vector{HTTPConn{Connection}}
    last_sweep:: Float64
    stop_time :: Float64
    replies   :: Channel{Tuple{HTTPConn{Connection},UInt64,Response}}
end

function UringIO(server::S, engine::Engine) where {S <: Server}
    cfg = HTTPConfig(server.config.max_header_bytes, server.config.max_body_size,
                     server.config.header_timeout_ms, server.config.body_timeout_ms,
                     server.config.idle_timeout_ms)
    return UringIO{S}(server, engine, ConnectionPool(), BufferPool(), cfg,
                      Dict{Ptr{Cvoid}, HTTPConn{Connection}}(),
                      Dict{Ptr{Cvoid}, ConnEntry}(),
                      HTTPConn{Connection}[], 0.0, 0.0,
                      Channel{Tuple{HTTPConn{Connection},UInt64,Response}}(Inf))
end

# ── AbstractIO implementation ───────────────────────────────────────────────

io_config(io::UringIO)          = io.cfg
io_running(io::UringIO)::Bool   = io.server.runtime.running[]
io_acquire_buffer(io::UringIO)  = acquire!(io.buf_pool)

function io_read(io::UringIO, st::HTTPConn)::Int
    if queue_read_reuse!(io.engine, st.handle) != 0
        return -1
    end
    st.inflight = :read
    return 0
end

function io_write(io::UringIO, st::HTTPConn, buf::Vector{UInt8}, len::Int)::Int
    entry = io.entries[st.handle.ptr]
    entry.pending = PendingWrite(buf, len, 0)
    if queue_write!(io.engine, st.handle, pointer(buf), len) != 0
        entry.pending = nothing
        release!(io.buf_pool, buf)
        return -1
    end
    st.inflight = :write
    return 0
end

function io_on_write(io::UringIO, st::HTTPConn, n::Int)::Symbol
    entry = io.entries[st.handle.ptr]
    pw = entry.pending
    pw === nothing && return :error
    n <= 0 && return :error

    sent = pw.sent + n
    if sent < pw.len
        pw.sent = sent
        if queue_write!(io.engine, st.handle, pointer(pw.buf, sent + 1), pw.len - sent) != 0
            return :error
        end
        st.inflight = :write
        return :partial
    end

    entry.pending = nothing
    release!(io.buf_pool, pw.buf)
    return :done
end

function io_shutdown(io::UringIO, st::HTTPConn)
    entry = get(io.entries, st.handle.ptr, nothing)
    entry === nothing && return
    entry.fd_open && shutdown_fd!(entry.fd)
    return
end

function io_close(io::UringIO, st::HTTPConn)
    entry = pop!(io.entries, st.handle.ptr, nothing)
    entry === nothing && return
    entry.pending !== nothing && release!(io.buf_pool, entry.pending.buf)
    if entry.fd_open
        close_fd!(entry.fd)
        entry.fd_open = false
    end
    return
end

function io_release(io::UringIO, st::HTTPConn)
    delete!(io.states, st.handle.ptr)
    release!(io.conn_pool, st.handle)
    Threads.atomic_sub!(io.server.runtime.conn_count, 1)
    if length(io.free) < _MAX_POOLED_STATES
        _shrink_buffers!(st)
        push!(io.free, st)
    end
    return
end

function io_dispatch(io::UringIO, req::Request)::Response
    return dispatch(io.server.router, io.server.executor, io.server.catcher, req)
end

io_isasync(io::UringIO)::Bool = isasync(io.server.executor)

"""Async handlers run away from this thread; their replies are posted to
`io.replies` and delivered from `_worker_tick!` (generation-checked, so a
reply for a recycled connection is dropped)."""
function io_dispatch_async(io::UringIO, st::HTTPConn, req::Request)::Bool
    if isasync(io.server.executor)
        gen = st.gen
        dispatch_async(io.server.router, io.server.executor, io.server.catcher,
                       req, r -> put!(io.replies, (st, gen, r)))
        return true
    end
    http_deliver_response(io, st, io_dispatch(io, req))
    return false
end

function _shrink_buffers!(st::HTTPConn)
    length(st.rbuf) > 65_536 && (st.rbuf = Vector{UInt8}(undef, 0))
    length(st.body) > 65_536 && (st.body = Vector{UInt8}(undef, 0))
    length(st.chunkbuf) > 65_536 && (st.chunkbuf = Vector{UInt8}(undef, 0))
    length(st.carry) > 65_536 && (st.carry = Vector{UInt8}(undef, 0))
    resize!(st.rbuf, 0)
    resize!(st.body, 0)
    resize!(st.chunkbuf, 0)
    resize!(st.carry, 0)
    st.rlen = 0
    st.bodylen = 0
    st.chunklen = 0
    st.fed = 0
    st.carrylen = 0
    return
end

# ── Worker startup ──────────────────────────────────────────────────────────

function _start_workers(server::Server, queue_depth::Int, nworkers::Int)
    if server.config.backend === :sockets
        return _start_sockets_workers(server, nworkers)
    end
    return _start_uring_workers(server, queue_depth, nworkers)
end

function _start_uring_workers(server::Server, queue_depth::Int, nworkers::Int)
    log!(server.logger, Info, "io_uring backend with $nworkers worker(s)")
    backend = IOUringBackend(; queue_depth, nworkers,
                             host=server.config.host, backlog=server.config.backlog)

    factory = function (engine, tid)
        log!(server.logger, Info, "[Thread $tid] io_uring engine ready")
        io = UringIO(server, engine)
        accept_conn = create_connection()
        status = queue_multishot_accept!(engine, accept_conn)
        status != 0 && error("[Thread $tid] failed to arm multishot accept")

        handler = event -> _handle_event(io, event, accept_conn)
        tick = () -> _worker_tick!(io)
        drain = () -> _drain_complete(io)
        return handler, tick, drain
    end

    start_backend!(backend, factory, server.config.port; running=server.runtime.running)
end

# ── Event pump ──────────────────────────────────────────────────────────────

@inline function _handle_event(io::UringIO, event::CompletionEvent,
                               accept_conn::Connection)
    conn = Connection(event.conn)
    res = event.result

    if conn == accept_conn
        res < 0 && return
        _on_accept(io, Cint(res))
        return
    end

    st = get(io.states, conn.ptr, nothing)
    st === nothing && return          # completion for a dead connection

    if st.retired
        http_finalize(io, st)         # awaited completion of a retired conn
        return
    end

    # The completing operation is done; the state machine re-arms as needed.
    st.inflight = :none

    if res < 0
        http_retire(io, st)
        return
    end

    if event.op_type == READ
        http_on_read(io, st, conn_buffer(st.handle), Int(res))
    elseif event.op_type == WRITE
        http_on_write(io, st, Int(res))
    end
    nothing
end

function _on_accept(io::UringIO, client_fd::Cint)
    if Threads.atomic_add!(io.server.runtime.conn_count, 1) + 1 > io.server.config.max_connections
        Threads.atomic_sub!(io.server.runtime.conn_count, 1)
        close_fd!(client_fd)
        return
    end

    c = acquire!(io.conn_pool)
    st = isempty(io.free) ? HTTPConn(c) : pop!(io.free)
    st.handle = c
    http_reset!(st)
    st.deadline = time() + io.cfg.header_timeout_ms / 1000
    io.states[c.ptr] = st
    io.entries[c.ptr] = ConnEntry(client_fd, true, nothing)

    if accept_and_queue_read!(io.engine, c, client_fd) != 0
        http_finalize(io, st)
        return
    end
    st.inflight = :read
    return
end

# ── Tick: drain and deadline sweep ──────────────────────────────────────────

"""Reply delivery, connection draining and deadline sweep, once per tick."""
function _worker_tick!(io::UringIO)
    _drain_replies!(io)
    if !io.server.runtime.running[]
        io.stop_time == 0.0 && (io.stop_time = time())
        _drain_connections!(io)
    end
    _sweep_expired!(io)
    return
end

"""Deliver responses produced by async executors on the event-loop thread."""
function _drain_replies!(io::UringIO)
    while isready(io.replies)
        st, gen, response = take!(io.replies)
        get(io.states, st.handle.ptr, nothing) === st || continue
        st.gen == gen || continue
        http_deliver_response(io, st, response)
    end
    return
end

"""Close connections during shutdown so the worker can exit: in-flight writes
and in-flight async handlers are allowed to finish, everything else is
retired. After `shutdown_timeout` even those are dropped."""
function _drain_connections!(io::UringIO)
    forced = time() - io.stop_time > io.server.config.shutdown_timeout
    for st in collect(values(io.states))
        st.retired && continue
        (forced || (st.inflight != :write && st.phase != :awaiting)) && http_retire(io, st)
    end
    return
end

"""Drain predicate for the event loop: true once every connection is released."""
_drain_complete(io::UringIO)::Bool = isempty(io.states)

"""Close connections past their phase deadline (idle, headers or body timeout)."""
function _sweep_expired!(io::UringIO)
    now = time()
    now - io.last_sweep < _SWEEP_INTERVAL && return
    io.last_sweep = now

    expired = HTTPConn{Connection}[]
    for (_, st) in io.states
        http_expired(st, now) && push!(expired, st)
    end

    for st in expired
        st.retired && continue
        http_retire(io, st)
    end
    return
end

# ── Request Dispatch ────────────────────────────────────────────────────────
# Delegates to the single Runtime pipeline (shared with Application/FakeTransport).

@inline _dispatch(server::Server, req::Request)::Response =
    dispatch(server.router, server.executor, server.catcher, req)

# Internal adapter for parser-level tests and backend code.
@inline _dispatch(server::Server, req::PicoHTTPParser.Request)::Response =
    _dispatch(server, Request(req))
