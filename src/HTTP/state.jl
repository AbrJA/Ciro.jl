# ══════════════════════════════════════════════════════════════════════════════
# HTTP connection state machine
#
# Entry points called by an adapter (via the AbstractIO seam):
#   http_on_read(io, st, src, n)
#   http_on_write(io, st, n)
#   http_retire(io, st) / http_finalize(io, st) / http_expired(st, now)
#   http_deliver_response(io, st, response)   # async executors only
#
# The machine only touches the outside world through `io_*` methods; it has no
# knowledge of fds, rings, or pools.
# ══════════════════════════════════════════════════════════════════════════════

# ── Entry points ────────────────────────────────────────────────────────────

"""Bytes `n`..end of a completed read are at `src` (adapter-owned memory)."""
function http_on_read(io::AbstractIO, st::HTTPConn, src::Ptr{UInt8}, n::Int)
    if n <= 0
        http_retire(io, st)
        return
    end
    t = io_telemetry(io)
    if telemetry_active(t)
        telemetry_read!(t, n)
        st.rlen == 0 && (st.t_start = time())
    end
    _append_read!(st, src, n)
    _set_deadline!(io, st)
    _pump(io, st)
    return
end

"""Append `n` bytes. `rbuf` length always equals `rlen` (capacity reserved with
`sizehint!`), so the parser and stored header offsets never move under them."""
function _append_read!(st::HTTPConn, src::Ptr{UInt8}, n::Int)
    need = st.rlen + n
    if need > length(st.rbuf)
        sizehint!(st.rbuf, max(need, 2 * st.rlen, _INITIAL_RBUF))
        resize!(st.rbuf, need)
    end
    GC.@preserve st unsafe_copyto!(pointer(st.rbuf, st.rlen + 1), src, n)
    st.rlen = need
    return
end

"""Queue another read while the request is incomplete; retire on failure."""
function _pump(io::AbstractIO, st::HTTPConn)
    result = _process(io, st)
    if result === :need_more && !st.retired && st.inflight == :none
        _set_deadline!(io, st)
        io_read(io, st) != 0 && http_retire(io, st)
    end
    return
end

function _set_deadline!(io::AbstractIO, st::HTTPConn)
    cfg = io_config(io)
    if st.phase == :body
        st.deadline = time() + _effective_body_timeout(io, st) / 1000
    elseif st.rlen == 0
        st.deadline = time() + cfg.idle_timeout_ms / 1000
    else
        st.deadline = time() + cfg.header_timeout_ms / 1000
    end
    return
end

# ── Per-route limits (early routing) ────────────────────────────────────────

"""Route the request as soon as its head is parsed, so per-route limits apply
before the body is read. The result is reused by dispatch (routing once)."""
@inline function _early_route(io::AbstractIO, st::HTTPConn)
    method = Methods.from_string(request_method(st.hbuf, st.rbuf))
    target = request_target(st.hbuf, st.rbuf)
    path, _ = Interface._split_target(target)
    return io_route(io, method, path, st.captures)
end

@inline function _route_limits(io::AbstractIO, st::HTTPConn)::Union{Nothing,RouteLimits}
    result = st.route
    result === nothing && return nothing
    return route_limits(result.handler)
end

@inline function _effective_max_body(io::AbstractIO, st::HTTPConn)::Int
    limits = _route_limits(io, st)
    cfg = io_config(io)
    return (limits === nothing || limits.max_body_size < 0) ?
           cfg.max_body_size : limits.max_body_size
end

@inline function _effective_body_timeout(io::AbstractIO, st::HTTPConn)::Int
    limits = _route_limits(io, st)
    cfg = io_config(io)
    return (limits === nothing || limits.body_timeout_ms < 0) ?
           cfg.body_timeout_ms : limits.body_timeout_ms
end

"""Whether the connection is past its phase deadline and must be retired."""
@inline http_expired(st::HTTPConn, now::Float64)::Bool =
    !st.retired && st.deadline != 0.0 && now > st.deadline

# ── Telemetry ───────────────────────────────────────────────────────────────

"""Start observing the request whose head was just parsed."""
@inline function _telemetry_begin(io::AbstractIO, st::HTTPConn)
    t = io_telemetry(io)
    telemetry_active(t) || return
    st.t_method = Methods.from_string(request_method(st.hbuf, st.rbuf))
    st.t_start == 0.0 && (st.t_start = time())
    st.t_bytes = 0
    st.t_reported = false
    st.t_streaming = false
    target = request_target(st.hbuf, st.rbuf)
    telemetry_capture_path(t) && (st.t_path = String(target))
    telemetry_request!(t, st.t_method, target, UInt8(minor_version(st.hbuf)))
    return
end

"""Report the completed response once, with total bytes and elapsed time."""
@inline function _telemetry_report(io::AbstractIO, st::HTTPConn, status::Int, bytes::Int)
    t = io_telemetry(io)
    telemetry_active(t) || return
    st.t_reported && return
    st.t_reported = true
    elapsed = st.t_start == 0.0 ? 0.0 : time() - st.t_start
    telemetry_response!(t, st.t_method, st.t_path, status, bytes, elapsed)
    return
end

"""A completed write. Returns nothing; may retire or finalize the connection."""
function http_on_write(io::AbstractIO, st::HTTPConn, n::Int)
    result = io_on_write(io, st, n)

    if result === :error
        http_retire(io, st)
        return
    elseif result === :partial
        return
    end

    if st.phase == :streaming
        # Release the worker waiting on this chunk; a terminal chunk ends the
        # response and returns the connection to request handling.
        _put_ack!(st.stream_ack, true)
        st.stream_ack = nothing
        st.stream_final && _resume_connection(io, st)
        return
    end

    _resume_connection(io, st)
    return
end

"""Return the connection to request handling after a response is complete."""
function _resume_connection(io::AbstractIO, st::HTTPConn)
    st.stream_ack = nothing
    st.stream_final = false
    st.stream_chunked = false
    st.stream_head = false

    if st.close_after || !io_running(io)
        http_finalize(io, st)
        return
    end

    st.phase = :headers
    st.hdr_scanned = 0
    if st.rlen > 0
        _pump(io, st)   # pipelined request(s)
    else
        _set_deadline!(io, st)
        io_read(io, st) != 0 && http_retire(io, st)
    end
    return
end

# ── Response delivery ───────────────────────────────────────────────────────

"""
    http_deliver_response(io, st, response)

Deliver the response for a request dispatched through `io_dispatch_async`.
Adapters call this on the event-loop thread once an asynchronous executor
reports back; it is a no-op when the connection was retired in the meantime.
"""
function http_deliver_response(io::AbstractIO, st::HTTPConn, response::Response)
    st.retired && return
    st.close_after && set_connection_close!(response.headers)
    st.phase = :writing
    _queue_response(io, st, response)
    return
end

# Default async dispatch: backends without deferred execution answer inline.
# Async backends override this; see `AbstractIO` in io.jl.
function io_dispatch_async(io::AbstractIO, st::HTTPConn, req::Request)::Bool
    http_deliver_response(io, st, io_dispatch(io, req, st.captures, st.route))
    return false
end

# ── Streaming ───────────────────────────────────────────────────────────────

"""Release a worker blocked on a stream handshake (`false` if it already left)."""
@inline function _put_ack!(ack::Union{Nothing, Channel{Bool}}, ok::Bool)
    ack === nothing && return
    isopen(ack) || return
    try
        put!(ack, ok)
    catch
    end
    return
end

"""Fail the stream handshake held by this connection, unblocking its worker."""
function _fail_stream!(st::HTTPConn)
    ack = st.stream_ack
    st.stream_ack = nothing
    ack !== nothing && isopen(ack) && close(ack)
    return
end

@inline function _has_header(headers::Vector{Pair{String,String}}, name::String)::Bool
    for (k, _) in headers
        hdr_key_eq_ci(k, name) && return true
    end
    return false
end

"""
    http_stream_begin(io, st, stream, ack)

Open a streaming response: serialize status line and headers (chunked when the
length is unknown and the protocol allows it) and queue the head write. The
worker is acked once the head is flushed.
"""
function http_stream_begin(io::AbstractIO, st::HTTPConn, stream::Stream,
                           ack::Channel{Bool})
    st.stream_ack = ack
    st.stream_final = false
    # Frame ourselves only when the body length is unknown and the user did not
    # already provide framing headers.
    st.stream_chunked = st.http11 && !st.stream_head &&
                        !_has_header(stream.headers, "Content-Length") &&
                        !_has_header(stream.headers, "Transfer-Encoding")
    st.http11 || (st.close_after = true)
    st.deadline = 0.0
    st.phase = :streaming

    out = io_acquire_buffer(io)
    n = serialize_head!(out, stream.status, stream.headers,
                        st.stream_chunked, st.close_after)
    st.t_status = stream.status
    st.t_bytes = n
    st.t_streaming = true
    if io_write(io, st, out, n) != 0
        http_finalize(io, st)
    end
    return
end

"""
    http_stream_chunk(io, st, bytes, ack)

Frame and queue one body chunk; `ack` receives `true` when it is flushed, or
`false` when the stream is gone (retired, already terminal, or HEAD).
"""
function http_stream_chunk(io::AbstractIO, st::HTTPConn, bytes::Vector{UInt8},
                           ack::Channel{Bool})
    if st.retired || st.phase != :streaming || st.stream_final
        _put_ack!(ack, false)
        return
    end
    if isempty(bytes) || st.stream_head
        _put_ack!(ack, true)
        return
    end
    st.stream_ack = ack
    out = io_acquire_buffer(io)
    n = st.stream_chunked ? serialize_chunk!(out, bytes) : serialize_raw!(out, bytes)
    if io_write(io, st, out, n) != 0
        http_finalize(io, st)
    end
    st.t_bytes += n
    return
end

"""
    http_stream_end(io, st)

Terminate a streaming response: queue the last chunk (or finish immediately for
HEAD/`Content-Length` streams) and resume request handling.
"""
function http_stream_end(io::AbstractIO, st::HTTPConn)
    st.retired && return
    st.phase == :streaming || return
    st.stream_final = true

    if st.stream_chunked && !st.stream_head
        out = io_acquire_buffer(io)
        n = serialize_last_chunk!(out)
        if io_write(io, st, out, n) != 0
            http_finalize(io, st)
            return
        end
        st.t_bytes += n
        _telemetry_report(io, st, st.t_status, st.t_bytes)
        st.t_streaming = false
        return
    end

    _telemetry_report(io, st, st.t_status, st.t_bytes)
    st.t_streaming = false
    st.inflight == :none && _resume_connection(io, st)
    return
end

"""Close immediately if idle; otherwise shut the socket down (which wakes the
in-flight operation and FINs the peer) and wait for the completion before
recycling the connection state."""
function http_retire(io::AbstractIO, st::HTTPConn)
    if st.inflight == :none
        http_finalize(io, st)
        return
    end
    st.retired = true
    io_shutdown(io, st)
    return
end

function http_finalize(io::AbstractIO, st::HTTPConn)
    st.retired = true   # guards in-flight dispatch against the recycled state
    if st.t_streaming && !st.t_reported
        _telemetry_report(io, st, st.t_status, st.t_bytes)   # stream cut short
        st.t_streaming = false
    end
    _fail_stream!(st)
    io_close(io, st)
    io_release(io, st)
    return
end

# ── Parsing state machine ───────────────────────────────────────────────────

"""Returns `:need_more` when more input is required, `:done` otherwise."""
function _process(io::AbstractIO, st::HTTPConn)
    if st.phase == :headers
        status = parse_request_head!(st.hbuf, st.rbuf, st.hdr_scanned)
        if status === :partial
            if st.rlen > io_config(io).max_header_bytes
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
        st.route = _early_route(io, st)
        _telemetry_begin(io, st)
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
function _prepare_body(io::AbstractIO, st::HTTPConn)
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
        if contains_token_ci(te, "chunked")
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
        if cl > _effective_max_body(io, st)
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
function _feed_chunked!(io::AbstractIO, st::HTTPConn)
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

    if st.bodylen > _effective_max_body(io, st)
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

function _complete_request(io::AbstractIO, st::HTTPConn)
    req = _build_request(st)
    st.close_after = wants_close(req)
    st.http11 = req.minor_version >= 1
    st.stream_head = req.method == "HEAD"
    st.stream_chunked = false
    st.stream_final = false
    st.stream_ack = nothing

    # An async executor retains the request past this call, and the views die
    # at the next buffer advance: hand it an owned copy (copy-on-escape).
    io_isasync(io) && (req = copy(req))

    # Dispatch while the request views are still valid; a synchronous backend
    # serializes the response here, an asynchronous one only queues the job.
    st.phase = :writing
    deferred = io_dispatch_async(io, st, req)
    st.retired && return   # a failed synchronous write may have finalized us

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

    if deferred
        # Deferred: no read is armed and the phase deadline is disabled until
        # the executor reports back through `http_deliver_response`.
        st.phase = :awaiting
        st.deadline = 0.0
    end
    return
end

function _build_request(st::HTTPConn)
    hb = st.hbuf
    buf = st.rbuf
    method = request_method(hb, buf)   # views into `buf`; valid during dispatch
    target = request_target(hb, buf)
    path, query = Interface._split_target(target)

    headers = Headers(hb, buf, length(hb))

    body = if st.chunked
        view(st.body, 1:st.bodylen)
    else
        view(buf, st.header_len + 1:st.header_len + st.body_need)
    end

    return Request(method, target, path, query, headers, body,
                   UInt8(minor_version(hb)))
end

"""Serialize and queue a response. Returns `false` if it could not be queued."""
function _queue_response(io::AbstractIO, st::HTTPConn, response::Response)
    out_buf = io_acquire_buffer(io)
    nbytes = serialize_response!(out_buf, response)

    if io_write(io, st, out_buf, nbytes) != 0
        http_finalize(io, st)
        return false
    end
    _telemetry_report(io, st, response.status, nbytes)
    return true
end

function _respond_and_close(io::AbstractIO, st::HTTPConn, response::Response)
    st.close_after = true
    st.phase = :writing
    _queue_response(io, st, response)
    return
end

# ── Connection close detection ──────────────────────────────────────────────

@inline wants_close(req::PicoHTTPParser.Request)::Bool = wants_close(Request(req))
@inline wants_close(::Nothing)::Bool = true

@inline function wants_close(req::Request)::Bool
    http11_or_newer = req.minor_version >= 1

    conn_val = nothing
    for (k, v) in req.headers
        ncodeunits(k) != 10 && continue
        hdr_key_eq_ci(k, "connection") || continue
        conn_val = v
        break
    end

    conn_val === nothing && return !http11_or_newer
    contains_token_ci(conn_val, "close") && return true
    !http11_or_newer && !contains_token_ci(conn_val, "keep-alive") && return true
    return false
end

@inline function set_connection_close!(headers::Vector{Pair{String,String}})
    for i in eachindex(headers)
        hdr_key_eq_ci(headers[i].first, "connection") || continue
        headers[i] = "Connection" => "close"
        return
    end
    push!(headers, "Connection" => "close")
    return
end

"""Zero-allocation case-insensitive ASCII string comparison."""
@inline function hdr_key_eq_ci(a, b::String)::Bool
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
@inline function contains_token_ci(v, token::String)::Bool
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

# Source-level aliases while Core/tests migrate to the unprefixed names.
const _wants_close = wants_close
const _set_connection_close! = set_connection_close!
