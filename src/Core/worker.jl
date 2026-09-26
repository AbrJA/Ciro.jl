# ══════════════════════════════════════════════════════════════════════════════
# UringIO — io_uring adapter + per-connection HTTP state
#
# This file is deliberately split by ownership:
#   - `UringIO` and the `io_*` methods implement HTTP's `AbstractIO` seam;
#   - the `HTTPConn` state machine (parse → frame → dispatch → write) still
#     lives here for now and will move into the `HTTP` module in the next
#     slice; it only touches the backend through `io.*` fields and `io_*`
#     methods.
#
# Connection structs are only returned to the pool after every in-flight
# io_uring operation for them has completed (`retired`), so a recycled struct
# can never receive a stale completion.
# ══════════════════════════════════════════════════════════════════════════════

const _INITIAL_RBUF      = 4096
const _MAX_POOLED_STATES = 256
const _SWEEP_INTERVAL    = 0.1   # seconds

mutable struct HTTPConn
    conn        :: Connection
    fd          :: Cint
    fd_open     :: Bool
    rbuf        :: Vector{UInt8}
    rlen        :: Int
    hdr_scanned :: Int          # last_len progress for request-head parsing
    hbuf        :: HeaderBuffer
    decoder     :: ChunkedDecoder
    chunkbuf    :: Vector{UInt8}  # raw chunked bytes for the current decode call
    chunklen    :: Int
    fed         :: Int            # rbuf bytes already handed to the chunk decoder
    body        :: Vector{UInt8}  # decoded chunked body accumulator
    bodylen     :: Int
    carry       :: Vector{UInt8}  # bytes after a chunked message (next request)
    carrylen    :: Int
    phase       :: Symbol         # :headers | :body | :writing
    header_len  :: Int
    body_need   :: Int
    chunked     :: Bool
    close_after :: Bool
    deadline    :: Float64
    inflight    :: Symbol         # :none | :read | :write
    retired     :: Bool
end

HTTPConn(conn::Connection) =
    HTTPConn(conn, Cint(-1), false, Vector{UInt8}(undef, 0), 0, 0,
             HeaderBuffer(64), ChunkedDecoder(), Vector{UInt8}(undef, 0), 0, 0,
             Vector{UInt8}(undef, 0), 0, Vector{UInt8}(undef, 0), 0,
             :headers, 0, 0, false, false, 0.0, :none, false)

"""Response bytes queued for one connection until the kernel reports them sent."""
mutable struct PendingWrite
    buf :: Vector{UInt8}
    len :: Int
    sent:: Int
end

"""
    UringIO <: AbstractIO

io_uring adapter: owns the ring, the connection/buffer pools, per-connection
pending writes, and the handle→state table. One per worker thread, never shared.
"""
mutable struct UringIO{S <: Server} <: AbstractIO
    server    :: S
    engine    :: Engine
    conn_pool :: ConnectionPool
    buf_pool  :: BufferPool
    states    :: Dict{Ptr{Cvoid}, HTTPConn}
    free      :: Vector{HTTPConn}
    pending   :: Dict{Ptr{Cvoid}, PendingWrite}
    last_sweep:: Float64
    stop_time :: Float64
end

UringIO(server::S, engine::Engine) where {S <: Server} =
    UringIO{S}(server, engine, ConnectionPool(), BufferPool(),
               Dict{Ptr{Cvoid}, HTTPConn}(), HTTPConn[],
               Dict{Ptr{Cvoid}, PendingWrite}(), 0.0, 0.0)

function _reset!(st::HTTPConn)
    st.fd = Cint(-1)
    st.fd_open = false
    st.rlen = 0
    st.hdr_scanned = 0
    st.chunklen = 0
    st.fed = 0
    st.bodylen = 0
    st.carrylen = 0
    resize!(st.rbuf, 0)
    resize!(st.chunkbuf, 0)
    resize!(st.body, 0)
    resize!(st.carry, 0)
    st.phase = :headers
    st.header_len = 0
    st.body_need = 0
    st.chunked = false
    st.close_after = false
    st.deadline = 0.0
    st.inflight = :none
    st.retired = false
    d = st.decoder
    d.bytes_left_in_chunk = 0
    d.consume_trailer = 1
    d._hex_count = 0
    d._state = 0
    d._total_read = 0
    d._total_overhead = 0
    return st
end

# ── AbstractIO implementation ───────────────────────────────────────────────

function io_read(io::UringIO, st::HTTPConn)::Int
    if queue_read_reuse!(io.engine, st.conn) != 0
        return -1
    end
    st.inflight = :read
    return 0
end

function io_write(io::UringIO, st::HTTPConn, buf::Vector{UInt8}, len::Int)::Int
    io.pending[st.conn.ptr] = PendingWrite(buf, len, 0)
    if queue_write!(io.engine, st.conn, pointer(buf), len) != 0
        delete!(io.pending, st.conn.ptr)
        release!(io.buf_pool, buf)
        return -1
    end
    st.inflight = :write
    return 0
end

function io_on_write(io::UringIO, st::HTTPConn, n::Int)::Symbol
    pw = get(io.pending, st.conn.ptr, nothing)
    pw === nothing && return :error
    n <= 0 && return :error

    sent = pw.sent + n
    if sent < pw.len
        pw.sent = sent
        if queue_write!(io.engine, st.conn, pointer(pw.buf, sent + 1), pw.len - sent) != 0
            return :error
        end
        st.inflight = :write
        return :partial
    end

    delete!(io.pending, st.conn.ptr)
    release!(io.buf_pool, pw.buf)
    return :done
end

function io_shutdown(io::UringIO, st::HTTPConn)
    st.fd_open && shutdown_fd!(st.fd)
    return
end

function io_close(io::UringIO, st::HTTPConn)
    pw = pop!(io.pending, st.conn.ptr, nothing)
    pw !== nothing && release!(io.buf_pool, pw.buf)
    if st.fd_open
        close_fd!(st.fd)
        st.fd_open = false
    end
    return
end

function io_release(io::UringIO, st::HTTPConn)
    delete!(io.states, st.conn.ptr)
    release!(io.conn_pool, st.conn)
    Threads.atomic_sub!(io.server._conn_count, 1)
    _park_state(io, st)
    return
end

function io_dispatch(io::UringIO, req::Request)::Response
    return dispatch(io.server.router, io.server.executor, io.server.catcher, req)
end

# ── Worker startup ──────────────────────────────────────────────────────────

function _start_workers(server::Server, queue_depth::Int, nworkers::Int)
    log!(server.logger, Info, "io_uring backend with $nworkers worker(s)")
    backend = IOUringBackend(; queue_depth, nworkers,
                             host=server.host, backlog=server.backlog)

    factory = function (engine, tid)
        log!(server.logger, Info, "[Thread $tid] io_uring engine ready")
        io = UringIO(server, engine)
        accept_conn = create_connection()
        status = queue_multishot_accept!(engine, accept_conn)
        status != 0 && error("[Thread $tid] failed to arm multishot accept")

        handler = event -> _handle_http_event(io, event, accept_conn)
        tick = () -> _worker_tick!(io)
        drain = () -> _drain_complete(io)
        return handler, tick, drain
    end

    start_backend!(backend, factory, server.port; running=server._running)
end

# ── Event dispatch ──────────────────────────────────────────────────────────

@inline function _handle_http_event(io::UringIO, event::CompletionEvent,
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
        _finalize!(io, st)            # awaited completion of a retired conn
        return
    end

    # The completing operation is done; handlers re-arm as needed.
    st.inflight = :none

    if res < 0
        _retire!(io, st)
        return
    end

    if event.op_type == READ
        _on_read(io, st, Int(res))
    elseif event.op_type == WRITE
        _on_write(io, st, Int(res))
    end
    nothing
end

function _on_accept(io::UringIO, client_fd::Cint)
    if Threads.atomic_add!(io.server._conn_count, 1) + 1 > io.server.max_connections
        Threads.atomic_sub!(io.server._conn_count, 1)
        close_fd!(client_fd)
        return
    end

    c = acquire!(io.conn_pool)
    st = _acquire_state(io, c)
    st.fd = client_fd
    st.fd_open = true
    st.deadline = time() + io.server.header_timeout_ms / 1000
    io.states[c.ptr] = st

    status = accept_and_queue_read!(io.engine, c, client_fd)
    if status != 0
        _finalize!(io, st)
        return
    end
    st.inflight = :read
    return
end

# ── Reads ───────────────────────────────────────────────────────────────────

function _on_read(io::UringIO, st::HTTPConn, n::Int)
    if n <= 0
        _retire!(io, st)
        return
    end
    _append_read!(st, n)
    _set_deadline!(io, st)
    _pump(io, st)
    return
end

"""Append `n` bytes from the native read buffer. `rbuf` length always equals
`rlen` (spare capacity is reserved with `sizehint!`), so the parser and all
stored header pointers see a buffer that never moves under them."""
function _append_read!(st::HTTPConn, n::Int)
    need = st.rlen + n
    if need > length(st.rbuf)
        sizehint!(st.rbuf, max(need, 2 * st.rlen, _INITIAL_RBUF))
        resize!(st.rbuf, need)
    end
    GC.@preserve st begin
        unsafe_copyto!(pointer(st.rbuf, st.rlen + 1), conn_buffer(st.conn), n)
    end
    st.rlen = need
    return
end

"""Queue another read while the request is incomplete; retire on failure."""
function _pump(io::UringIO, st::HTTPConn)
    result = _process(io, st)
    if result === :need_more && !st.retired && st.fd_open && st.inflight == :none
        _set_deadline!(io, st)
        if io_read(io, st) != 0
            _retire!(io, st)
        end
    end
    return
end

function _set_deadline!(io::UringIO, st::HTTPConn)
    if st.phase == :body
        st.deadline = time() + io.server.body_timeout_ms / 1000
    elseif st.rlen == 0
        st.deadline = time() + io.server.idle_timeout_ms / 1000
    else
        st.deadline = time() + io.server.header_timeout_ms / 1000
    end
    return
end

# ── Parsing state machine ───────────────────────────────────────────────────

"""Returns `:need_more` when more input is required, `:done` otherwise."""
function _process(io::UringIO, st::HTTPConn)
    if st.phase == :headers
        status = parse_request_head!(st.hbuf, st.rbuf, st.hdr_scanned)
        if status === :partial
            if st.rlen > io.server.max_header_bytes
                _respond_and_close(io, st, fail(431, "Request Header Fields Too Large"))
                return :done
            end
            st.hdr_scanned = st.rlen
            return :need_more
        elseif status === :error
            _respond_and_close(io, st, fail(400, "Bad Request"))
            return :done
        end
        st.header_len = head_length(st.hbuf)
        _prepare_body(io, st) || return :done
        st.phase = :body
    end

    if st.phase == :body
        if st.chunked
            decoded = _feed_chunked!(io, st)
            decoded === :error && return :done
            decoded === :partial && return :need_more
        elseif st.rlen < st.header_len + st.body_need
            return :need_more
        end
        st.phase = :writing
    end

    if st.phase == :writing
        _complete_request(io, st)
    end
    return :done
end

"""Parse framing headers. Returns `false` (and answers) on an invalid request."""
function _prepare_body(io::UringIO, st::HTTPConn)
    # Obs-fold continuation lines surface as empty header names (picohttpparser
    # reports them with a NULL name). RFC 9112 allows only reject or replace;
    # reject rather than implicitly re-frame the message.
    for i in 1:length(st.hbuf)
        if isempty(header_name(st.hbuf, i, st.rbuf))
            _respond_and_close(io, st, fail(400, "Bad Request"))
            return false
        end
    end

    te = PicoHTTPParser.header(st.hbuf, st.rbuf, "transfer-encoding")
    cl = try
        content_length(st.hbuf, st.rbuf)
    catch err
        err isa HTTPParseError || rethrow(err)
        _respond_and_close(io, st, fail(400, "Bad Request"))
        return false
    end

    if te !== nothing && cl !== nothing
        # RFC 9112 smuggling defense: never accept both.
        _respond_and_close(io, st, fail(400, "Bad Request"))
        return false
    end

    if te !== nothing
        if _contains_token_ci(te, "chunked")
            st.chunked = true
            st.body_need = 0
            st.bodylen = 0
            st.chunklen = 0
            st.fed = st.header_len
            return true
        end
        _respond_and_close(io, st, fail(501, "Not Implemented"))
        return false
    end

    if cl !== nothing
        if cl > io.server.max_body_size
            _respond_and_close(io, st, fail(413, "Content Too Large"))
            return false
        end
        st.body_need = cl
    else
        st.body_need = 0
    end
    return true
end

"""Feed newly arrived raw bytes to the chunked decoder.
Returns `:partial`, `:done` or `:error` (error already answered)."""
function _feed_chunked!(io::UringIO, st::HTTPConn)
    if st.rlen > st.fed
        n = st.rlen - st.fed
        old = st.chunklen
        st.chunklen += n
        length(st.chunkbuf) < st.chunklen &&
            resize!(st.chunkbuf, max(st.chunklen, 2 * length(st.chunkbuf), 1024))
        GC.@preserve st begin
            unsafe_copyto!(pointer(st.chunkbuf, old + 1), pointer(st.rbuf, st.fed + 1), n)
        end
        st.fed = st.rlen
    end

    resize!(st.chunkbuf, st.chunklen)
    result = decode_chunked!(st.decoder, st.chunkbuf)

    if result.status === :error
        _respond_and_close(io, st, fail(400, "Bad Request"))
        return :error
    end

    if result.decoded_len > 0
        old = st.bodylen
        st.bodylen += result.decoded_len
        length(st.body) < st.bodylen &&
            resize!(st.body, max(st.bodylen, 2 * length(st.body), 1024))
        GC.@preserve st begin
            unsafe_copyto!(pointer(st.body, old + 1), pointer(st.chunkbuf), result.decoded_len)
        end
    end

    if st.bodylen > io.server.max_body_size
        _respond_and_close(io, st, fail(413, "Content Too Large"))
        return :error
    end

    if result.status === :partial
        st.chunklen = 0
        resize!(st.chunkbuf, 0)
        return :partial
    end

    # :done — leftover bytes are the start of the next (pipelined) request.
    # Keep them in `carry`, not `rbuf`: the request head still has to be read
    # from `rbuf` by `_complete_request`, and overwriting it here would corrupt
    # the method/target views.
    leftover = result.leftover
    st.carrylen = leftover
    if leftover > 0
        length(st.carry) < leftover &&
            resize!(st.carry, max(leftover, 2 * length(st.carry), _INITIAL_RBUF))
        GC.@preserve st begin
            unsafe_copyto!(pointer(st.carry), pointer(st.chunkbuf, result.decoded_len + 1), leftover)
        end
    end
    st.hdr_scanned = 0
    st.chunklen = 0
    resize!(st.chunkbuf, 0)
    return :done
end

# ── Request completion and response ─────────────────────────────────────────

function _complete_request(io::UringIO, st::HTTPConn)
    req = _build_request(st)
    response = io_dispatch(io, req)
    close_after = _wants_close(req)
    close_after && _set_connection_close!(response.headers)

    if st.chunked
        # The head was materialized above; now make the stream start with the
        # carried bytes of the next (pipelined) request.
        n = st.carrylen
        st.carrylen = 0
        if n > 0
            length(st.rbuf) < n && resize!(st.rbuf, max(n, _INITIAL_RBUF))
            GC.@preserve st unsafe_copyto!(pointer(st.rbuf), pointer(st.carry), n)
        end
        st.rlen = n
    else
        consumed = st.header_len + st.body_need
        leftover = st.rlen - consumed
        leftover > 0 && copyto!(st.rbuf, 1, st.rbuf, consumed + 1, leftover)
        st.rlen = max(leftover, 0)
    end

    st.hdr_scanned = 0
    st.header_len = 0
    st.body_need = 0
    st.chunked = false
    st.close_after = close_after
    st.phase = :writing

    _queue_response(io, st, response)
    return
end

function _build_request(st::HTTPConn)
    hb = st.hbuf
    buf = st.rbuf
    method = String(request_method(hb, buf))
    target = String(request_target(hb, buf))
    path, query = Interface._split_target(target)

    n = length(hb)
    headers = Vector{Pair{String,String}}(undef, n)
    for i in 1:n
        headers[i] = String(header_name(hb, i, buf)) => String(header_value(hb, i, buf))
    end

    body = if st.chunked
        copy(view(st.body, 1:st.bodylen))
    else
        copy(view(buf, st.header_len + 1:st.header_len + st.body_need))
    end

    return Request(method, target, path, query, headers, body,
                   UInt8(minor_version(hb)))
end

"""Serialize and queue a response. Returns `false` if it could not be queued."""
function _queue_response(io::UringIO, st::HTTPConn, response::Response)
    out_buf = acquire!(io.buf_pool)
    nbytes = serialize_response!(out_buf, response)

    if io_write(io, st, out_buf, nbytes) != 0
        _finalize!(io, st)
        return false
    end
    return true
end

function _respond_and_close(io::UringIO, st::HTTPConn, response::Response)
    st.close_after = true
    st.phase = :writing
    _queue_response(io, st, response)
    return
end

# ── Writes ──────────────────────────────────────────────────────────────────

function _on_write(io::UringIO, st::HTTPConn, n::Int)
    result = io_on_write(io, st, n)

    if result === :error
        _retire!(io, st)
        return
    elseif result === :partial
        return
    end

    if st.close_after || !io.server._running[]
        _finalize!(io, st)
        return
    end

    st.phase = :headers
    st.hdr_scanned = 0
    if st.rlen > 0
        _pump(io, st)   # pipelined request(s)
    else
        _set_deadline!(io, st)
        if io_read(io, st) != 0
            _retire!(io, st)
        end
    end
    return
end

# ── Lifecycle ───────────────────────────────────────────────────────────────

"""Close immediately if idle; otherwise shut the socket down (which wakes the
in-flight io_uring operation and FINs the peer) and wait for the completion
before recycling the connection struct."""
function _retire!(io::UringIO, st::HTTPConn)
    if st.inflight == :none
        _finalize!(io, st)
        return
    end
    st.retired = true
    io_shutdown(io, st)
    return
end

function _finalize!(io::UringIO, st::HTTPConn)
    io_close(io, st)
    io_release(io, st)
    return
end

function _acquire_state(io::UringIO, conn::Connection)
    st = isempty(io.free) ? HTTPConn(conn) : pop!(io.free)
    st.conn = conn
    _reset!(st)
    return st
end

function _park_state(io::UringIO, st::HTTPConn)
    if length(io.free) < _MAX_POOLED_STATES
        # Release oversized buffers instead of retaining them in the pool.
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
        push!(io.free, st)
    end
    return
end

"""Connection draining and deadline sweep, once per tick."""
function _worker_tick!(io::UringIO)
    if !io.server._running[]
        io.stop_time == 0.0 && (io.stop_time = time())
        _drain_connections!(io)
    end
    _sweep_expired!(io)
    return
end

"""Close connections during shutdown so the worker can exit: in-flight writes
are allowed to flush, everything else is retired. After `shutdown_timeout`
even pending writes are dropped."""
function _drain_connections!(io::UringIO)
    forced = time() - io.stop_time > io.server.shutdown_timeout
    for st in collect(values(io.states))
        st.retired && continue
        (forced || st.inflight != :write) && _retire!(io, st)
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

    expired = HTTPConn[]
    for (_, st) in io.states
        (st.retired || st.deadline == 0.0) && continue
        now > st.deadline && push!(expired, st)
    end

    for st in expired
        st.retired && continue
        _retire!(io, st)
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

# ── Connection close detection ──────────────────────────────────────────────

@inline _wants_close(req::PicoHTTPParser.Request)::Bool = _wants_close(Request(req))
@inline _wants_close(::Nothing)::Bool = true

@inline function _wants_close(req::Request)::Bool
    http11_or_newer = req.minor_version >= 1

    conn_val = nothing
    for (k, v) in req.headers
        ncodeunits(k) != 10 && continue
        _hdr_key_eq_ci(k, "connection") || continue
        conn_val = v
        break
    end

    conn_val === nothing && return !http11_or_newer
    _contains_token_ci(conn_val, "close") && return true
    !http11_or_newer && !_contains_token_ci(conn_val, "keep-alive") && return true
    return false
end

@inline function _set_connection_close!(headers::Vector{Pair{String,String}})
    for i in eachindex(headers)
        _hdr_key_eq_ci(headers[i].first, "connection") || continue
        headers[i] = "Connection" => "close"
        return
    end
    push!(headers, "Connection" => "close")
    return
end

"""Zero-allocation case-insensitive ASCII string comparison."""
@inline function _hdr_key_eq_ci(a, b::String)::Bool
    ncodeunits(a) != ncodeunits(b) && return false
    for i in 1:ncodeunits(b)
        ca = @inbounds codeunit(a, i)
        cb = @inbounds codeunit(b, i)
        ca_lower = (UInt8('A') <= ca <= UInt8('Z')) ? (ca | 0x20) : ca
        cb_lower = (UInt8('A') <= cb <= UInt8('Z')) ? (cb | 0x20) : cb
        ca_lower != cb_lower && return false
    end
    return true
end

"""ASCII token match for comma-separated header values (no allocations)."""
@inline function _contains_token_ci(v, token::String)::Bool
    n = ncodeunits(v)
    tlen = ncodeunits(token)
    i = 1
    while i <= n
        while i <= n
            c = @inbounds codeunit(v, i)
            ((c == UInt8(',')) | (c == UInt8(' ')) | (c == UInt8('\t'))) || break
            i += 1
        end
        start = i
        while i <= n
            c = @inbounds codeunit(v, i)
            ((c == UInt8(',')) | (c == UInt8(' ')) | (c == UInt8('\t'))) && break
            i += 1
        end
        seglen = i - start
        if seglen == tlen
            matched = true
            @inbounds for j in 1:tlen
                ca = codeunit(v, start + j - 1)
                cb = codeunit(token, j)
                ca_lower = (UInt8('A') <= ca <= UInt8('Z')) ? (ca | 0x20) : ca
                cb_lower = (UInt8('A') <= cb <= UInt8('Z')) ? (cb | 0x20) : cb
                if ca_lower != cb_lower
                    matched = false
                    break
                end
            end
            matched && return true
        end
    end
    return false
end
