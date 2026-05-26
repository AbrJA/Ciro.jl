# ══════════════════════════════════════════════════════════════════════════════
# HTTP Worker — built on Backend's event loop
# ══════════════════════════════════════════════════════════════════════════════
#
# Each thread runs one io_uring engine. The worker provides the HTTP protocol
# handler that Backend's event loop calls on each completion.
# ══════════════════════════════════════════════════════════════════════════════

function _start_workers(server::Server, queue_depth::Int, nworkers::Int)
    write(server.logger, Info, "io_uring backend with $nworkers worker(s)")

    run_eventloop_threaded!(server.port; nthreads=nworkers, queue_depth, running=server._running) do engine, tid
        write(server.logger, Info, "[Thread $tid] io_uring engine ready")

        # Thread-local state (zero cross-thread sharing)
        conn_pool = ConnectionPool()
        buf_pool  = BufferPool()
        pending   = PendingWrites()

        # Kick off multishot accept
        accept_conn = create_connection()
        queue_multishot_accept!(engine, accept_conn)

        # Return the per-event handler (closure captures thread-local state)
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

    # Accept completion — multishot reuses the same conn
    if conn == accept_conn
        res < 0 && return  # Error in accept, ignore
        client_fd = res

        # Individual calls (proven path) — no TCP_NODELAY (saves 1 syscall)
        new_conn = acquire!(conn_pool)
        set_conn_fd!(new_conn, client_fd)
        set_conn_op!(new_conn, READ)
        queue_read!(engine, new_conn)
        return
    end

    # Error on this fd — check if it's a close completion (flags & 1)
    if res < 0
        fd = conn_fd(conn)
        if fd > 0
            close_fd!(fd)
        end
        release!(conn_pool, conn)
        return
    end

    op = event.op_type

    if op == READ
        _handle_read(server, engine, conn, res, conn_pool, buf_pool, pending)
    elseif op == WRITE
        _handle_write(engine, conn, conn_pool, buf_pool, pending)
    end
    nothing
end

# ── Read Handler ────────────────────────────────────────────────────────────

function _handle_read(server, engine, conn::Connection, bytes_read::Cint,
                      conn_pool::ConnectionPool, buf_pool::BufferPool,
                      pending::PendingWrites)
    if bytes_read <= 0
        # Connection closed by client or error
        fd = conn_fd(conn)
        fd > 0 && close_fd!(fd)
        release!(conn_pool, conn)
        return
    end

    # Read raw data from connection's C buffer
    buf_ptr = conn_buffer(conn)
    raw_data = unsafe_wrap(Array, buf_ptr, Int(bytes_read))

    # Parse HTTP request (zero-copy via PicoHTTPParser)
    req = try
        PicoHTTPParser.parse_request(raw_data)
    catch
        nothing
    end

    # Dispatch
    response = if req === nothing
        fail(400, "Bad Request")
    elseif bytes_read > server.max_body_size
        fail(413, "Content Too Large")
    else
        _dispatch(server, req)
    end

    # Detect Connection: close (scan bytes directly, no String allocation)
    should_close = _wants_close(req)

    # Serialize response into pooled buffer
    out_buf = acquire!(buf_pool)
    nbytes = serialize_response!(out_buf, response)
    fd = conn_fd(conn)

    # Track pending write (keeps buffer alive until io_uring write completion)
    set_pending!(pending, fd, out_buf)
    should_close && mark_close!(pending, fd)

    # Queue write
    GC.@preserve out_buf begin
        set_conn_op!(conn, WRITE)
        queue_write!(engine, conn, pointer(out_buf), nbytes)
    end
    nothing
end

# Check Connection: close without String allocation (byte-scan headers)
@inline function _wants_close(req)::Bool
    req === nothing && return true
    for (k, v) in req.headers
        # Check if header key is "Connection" (case-insensitive first byte check)
        if length(k) == 10
            b = @inbounds codeunit(k, 1)
            if b == UInt8('C') || b == UInt8('c')
                # Now check value for "close"
                if length(v) == 5
                    vb = @inbounds codeunit(v, 1)
                    (vb == UInt8('c') || vb == UInt8('C')) && return true
                end
            end
        end
    end
    return false
end

# ── Write Handler ───────────────────────────────────────────────────────────

function _handle_write(engine, conn::Connection,
                       conn_pool::ConnectionPool, buf_pool::BufferPool,
                       pending::PendingWrites)
    fd = conn_fd(conn)

    # Return buffer to pool
    buf = pop_pending!(pending, fd)
    buf !== nothing && release!(buf_pool, buf)

    # Close if Connection: close was set
    if should_close!(pending, fd)
        close_fd!(fd)
        release!(conn_pool, conn)
        return
    end

    # Keep-alive: queue next read (single ccall)
    queue_read_reuse!(engine, conn)
    nothing
end

# ── Request Dispatch ────────────────────────────────────────────────────────

"""Dispatch request through router with error handling."""
@inline function _dispatch(server::Server, req::Request)::Response
    try
        # Strip query string from path (zero-alloc scan)
        path = req.path
        path_end = ncodeunits(path)
        for i in 1:path_end
            @inbounds codeunit(path, i) == UInt8('?') && (path_end = i - 1; break)
        end
        clean = SubString(String(path), 1, path_end)

        method = Methods.from_string(req.method)
        result = route(server.router, method, clean)

        # 404 — no route matches this path
        result === nothing && return fail(404, "Not Found")

        # 405 — path exists but method not allowed
        if result isa MethodNotAllowed
            allowed_str = join(Methods.to_string.(result.allowed), ", ")
            return Response(405, ["Allow" => allowed_str, "Content-Type" => "text/plain"],
                           Vector{UInt8}("Method Not Allowed"))
        end

        # Invoke handler
        handler = result
        response = handler(req)
        return response isa Response ? response : text(string(response))
    catch err
        return intercept(server.catcher, err isa Exception ? err : ErrorException(string(err)), req)
    end
end
