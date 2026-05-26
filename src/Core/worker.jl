# ══════════════════════════════════════════════════════════════════════════════
# HTTP Worker — built on Backend's event loop
# ══════════════════════════════════════════════════════════════════════════════

function _start_workers(server::Server, queue_depth::Int, nworkers::Int)
    write(server.logger, Info, "io_uring backend with $nworkers worker(s)")

    run_eventloop_threaded!(server.port; nthreads=nworkers, queue_depth, running=server._running) do engine, tid
        write(server.logger, Info, "[Thread $tid] io_uring engine ready")

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
        set_conn_fd!(new_conn, client_fd)
        set_conn_op!(new_conn, READ)
        queue_read!(engine, new_conn)
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
        _handle_write(engine, conn, conn_pool, buf_pool, pending)
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

    out_buf = acquire!(buf_pool)
    nbytes = serialize_response!(out_buf, response)
    fd = conn_fd(conn)

    set_pending!(pending, fd, out_buf)
    should_close && mark_close!(pending, fd)

    GC.@preserve out_buf begin
        set_conn_op!(conn, WRITE)
        queue_write!(engine, conn, pointer(out_buf), nbytes)
    end

    Threads.atomic_sub!(server._in_flight, 1)
    nothing
end

@inline function _wants_close(req)::Bool
    req === nothing && return true
    for (k, v) in req.headers
        if length(k) == 10
            b = @inbounds codeunit(k, 1)
            if b == UInt8('C') || b == UInt8('c')
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
    try
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
            return Response(405, ["Allow" => allow_str, "Content-Type" => "text/plain"], Vector{UInt8}("Method Not Allowed"))
        end

        # Invoke handler
        response = result.handler(req)
        return response isa Response ? response : text(string(response))
    catch err
        return intercept(server.catcher, err isa Exception ? err : ErrorException(string(err)), req)
    end
end
