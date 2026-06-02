# ══════════════════════════════════════════════════════════════════════════════
# HTTP Worker — built on Backend's event loop
# ══════════════════════════════════════════════════════════════════════════════

function _start_workers(server::Server, queue_depth::Int, nworkers::Int)
    log!(server.logger, Info, "io_uring backend with $nworkers worker(s)")

    run_eventloop_threaded!(server.port; nthreads=nworkers, queue_depth, running=server._running) do engine, tid
        log!(server.logger, Info, "[Thread $tid] io_uring engine ready")

        conn_pool = ConnectionPool()
        buf_pool  = BufferPool()
        pending   = PendingWrites()

        accept_conn = create_connection()
        queue_multishot_accept!(engine, accept_conn)

        return function(event::CompletionEvent)
            _handle_http_event(server, engine, event, accept_conn,
                               conn_pool, buf_pool, pending)
        end
    end
end

# ── Event Dispatch ──────────────────────────────────────────────────────────

@inline function _handle_http_event(server, engine, event::CompletionEvent,
                                    accept_conn::Connection,
                                    conn_pool::ConnectionPool,
                                    buf_pool::BufferPool,
                                    pending::PendingWrites)
    conn = Connection(event.conn)
    res = event.result

    if conn == accept_conn
        res < 0 && return
        client_fd = res
        new_conn = acquire!(conn_pool)
        accept_and_queue_read!(engine, new_conn, client_fd)
        return
    end

    if res < 0
        fd = conn_fd(conn)
        fd > 0 && close_fd!(fd)
        release!(conn_pool, conn)
        return
    end

    op = event.op_type

    if op == READ
        _handle_read(server, engine, conn, res, conn_pool, buf_pool, pending)
    elseif op == WRITE
        _handle_write(engine, conn, res, conn_pool, buf_pool, pending)
    end
    nothing
end

# ── Read Handler ────────────────────────────────────────────────────────────

function _handle_read(server, engine, conn::Connection, bytes_read::Cint,
                      conn_pool::ConnectionPool, buf_pool::BufferPool,
                      pending::PendingWrites)
    if bytes_read <= 0
        fd = conn_fd(conn)
        fd > 0 && close_fd!(fd)
        release!(conn_pool, conn)
        return
    end

    # Track in-flight request
    Threads.atomic_add!(server._in_flight, 1)

    buf_ptr = conn_buffer(conn)
    raw_data = unsafe_wrap(Array, buf_ptr, Int(bytes_read))

    req = try
        PicoHTTPParser.parse_request(raw_data)
    catch
        nothing
    end

    response = if req === nothing
        fail(400, "Bad Request")
    elseif bytes_read > server.max_body_size
        fail(413, "Content Too Large")
    else
        _dispatch(server, req)
    end

    should_close = _wants_close(req)

    # Add Connection: close header per RFC 9110 when closing
    if should_close
        _set_connection_close!(response.headers)
    end

    out_buf = acquire!(buf_pool)
    nbytes = serialize_response!(out_buf, response)
    fd = conn_fd(conn)

    set_pending!(pending, fd, out_buf, nbytes)
    should_close && mark_close!(pending, fd)

    set_conn_op!(conn, WRITE)
    queue_write!(engine, conn, pointer(out_buf), nbytes)

    Threads.atomic_sub!(server._in_flight, 1)
    nothing
end

@inline function _wants_close(req)::Bool
    req === nothing && return true

    # PicoHTTPParser minor_version: 0 => HTTP/1.0, 1 => HTTP/1.1
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
        k = headers[i].first
        _hdr_key_eq_ci(k, "connection") || continue
        headers[i] = "Connection" => "close"
        return
    end
    push!(headers, "Connection" => "close")
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

# ── Write Handler ───────────────────────────────────────────────────────────

function _handle_write(engine, conn::Connection, bytes_written::Cint,
                       conn_pool::ConnectionPool, buf_pool::BufferPool,
                       pending::PendingWrites)
    fd = conn_fd(conn)

    total, sent, done = advance_pending!(pending, fd, bytes_written)
    if !done
        ptr, remaining = pending_slice(pending, fd)
        if ptr == C_NULL || remaining <= 0 || sent < 0 || total <= 0
            buf = pop_pending!(pending, fd)
            buf !== nothing && release!(buf_pool, buf)
            close_fd!(fd)
            release!(conn_pool, conn)
            return
        end
        queue_write!(engine, conn, ptr, remaining)
        return
    end

    buf = pop_pending!(pending, fd)
    buf !== nothing && release!(buf_pool, buf)

    if should_close!(pending, fd)
        close_fd!(fd)
        release!(conn_pool, conn)
        return
    end

    queue_read_reuse!(engine, conn)
    nothing
end

# ── Request Dispatch (type-stable via RouteResult) ──────────────────────────

@inline function _dispatch(server::Server, req::Request)::Response
    path = req.path
    path_end = ncodeunits(path)
    for i in 1:path_end
        @inbounds codeunit(path, i) == UInt8('?') && (path_end = i - 1; break)
    end
    clean = SubString(String(path), 1, path_end)

    method = Methods.from_string(req.method)
    result = route(server.router, method, clean)

    if not_found(result)
        return fail(404, "Not Found")
    end

    if method_not_allowed(result)
        allow_str = Methods.allow_header(result.allowed)
        return Response(405, ["Allow" => allow_str, "Content-Type" => "text/plain"],
                        "Method Not Allowed")
    end

    ctx = Context(req, result.params)
    return _invoke_handler(server, result.handler, ctx)
end

"""Isolated handler invocation — @noinline keeps try/catch off the hot path."""
@noinline function _invoke_handler(server::Server, handler, ctx::Context)::Response
    try
        response = handler(ctx)
        return response isa Response ? response : text(string(response))
    catch err
        return intercept(server.catcher, err isa Exception ? err : ErrorException(string(err)), ctx.req)
    end
end
