# ══════════════════════════════════════════════════════════════════════════════
# SocketsIO — portable blocking-socket adapter
#
# The second `AbstractIO` implementation, and the proof that the HTTP seam is
# transport-agnostic: no C, no io_uring, runs anywhere `Sockets` does. One
# connection task blocks on `readavailable`, drives the HTTP state machine, and
# performs blocking writes; all tasks are `@async` (single-threaded), so the
# handle tables are plain Dicts without locks.
# ══════════════════════════════════════════════════════════════════════════════

mutable struct SocketsEntry
    sock     :: Sockets.TCPSocket
    wrote    :: Int          # bytes of the last response written synchronously
    released :: Bool
    reply    :: Channel{_Outbound}  # async replies/chunks; closed to wake the task
end

mutable struct SocketsIO{S <: Server} <: AbstractIO
    server   :: S
    listener :: Sockets.TCPServer
    cfg      :: HTTPConfig
    states   :: Dict{UInt64, HTTPConn{Sockets.TCPSocket}}
    entries  :: Dict{UInt64, SocketsEntry}
    free     :: Vector{HTTPConn{Sockets.TCPSocket}}
    stop_time:: Float64
end

function SocketsIO(server::S, listener::Sockets.TCPServer) where {S <: Server}
    cfg = HTTPConfig(server.config.max_header_bytes, server.config.max_body_size,
                     server.config.header_timeout_ms, server.config.body_timeout_ms,
                     server.config.idle_timeout_ms)
    return SocketsIO{S}(server, listener, cfg,
                        Dict{UInt64, HTTPConn{Sockets.TCPSocket}}(),
                        Dict{UInt64, SocketsEntry}(),
                        HTTPConn{Sockets.TCPSocket}[], 0.0)
end

# ── AbstractIO implementation ───────────────────────────────────────────────

io_config(io::SocketsIO)        = io.cfg
io_running(io::SocketsIO)::Bool = io.server.runtime.running[]
io_acquire_buffer(::SocketsIO)  = Vector{UInt8}(undef, 4096)

# The connection task is already blocked in `readavailable`; arming is a no-op.
function io_read(::SocketsIO, st::HTTPConn)::Int
    st.inflight = :read
    return 0
end

function io_write(io::SocketsIO, st::HTTPConn, buf::Vector{UInt8}, len::Int)::Int
    entry = get(io.entries, objectid(st.handle), nothing)
    entry === nothing && return -1
    try
        write(entry.sock, view(buf, 1:len))
        flush(entry.sock)
    catch
        return -1
    end
    entry.wrote = len
    st.inflight = :write
    return 0
end

# The write already happened synchronously; completion is a no-op.
io_on_write(::SocketsIO, ::HTTPConn, ::Int)::Symbol = :done

io_shutdown(io::SocketsIO, st::HTTPConn) = (_sockets_close(io, st); nothing)
io_close(io::SocketsIO, st::HTTPConn)    = (_sockets_close(io, st); nothing)

function _sockets_close(io::SocketsIO, st::HTTPConn)
    entry = get(io.entries, objectid(st.handle), nothing)
    entry === nothing && return
    isopen(entry.sock) && close(entry.sock)
    # Fail queued stream handshakes so workers blocked on a flush wake up,
    # then close the channel to wake the connection task itself.
    while isready(entry.reply)
        _close_ack(take!(entry.reply))
    end
    isopen(entry.reply) && close(entry.reply)
    return
end

function io_release(io::SocketsIO, st::HTTPConn)
    id = objectid(st.handle)
    haskey(io.states, id) || return
    delete!(io.states, id)
    delete!(io.entries, id)
    Threads.atomic_sub!(io.server.runtime.conn_count, 1)
    if length(io.free) < _MAX_POOLED_STATES
        _shrink_buffers!(st)
        push!(io.free, st)
    end
    return
end

io_dispatch(io::SocketsIO, req::Request)::Response =
    dispatch(io.server.router, io.server.executor, io.server.catcher, req)

io_isasync(io::SocketsIO)::Bool = isasync(io.server.executor)

"""Async handlers reply from another thread through the connection's channel;
only this connection task touches `st`, so no state is shared."""
function io_dispatch_async(io::SocketsIO, st::HTTPConn, req::Request)::Bool
    if isasync(io.server.executor)
        entry = io.entries[objectid(st.handle)]
        gen = st.gen
        reply = payload -> begin
            if payload isa Stream
                _run_stream(entry.reply, st, gen, payload)
            else
                put!(entry.reply, _Reply(st, gen, payload))
            end
        end
        dispatch_async(io.server.router, io.server.executor, io.server.catcher,
                       req, reply)
        return true
    end
    http_deliver_response(io, st, io_dispatch(io, req))
    return false
end

"""Handle one worker→loop message for a connection under this task's control."""
function _sockets_deliver(io::SocketsIO, st::HTTPConn, msg::_Outbound)
    st.gen == msg.gen || (_close_ack(msg); return)
    if msg isa _Reply
        http_deliver_response(io, st, msg.payload)
    elseif msg isa _StreamBegin
        http_stream_begin(io, st, msg.stream, msg.ack)
    elseif msg isa _StreamChunk
        http_stream_chunk(io, st, msg.bytes, msg.ack)
    else
        http_stream_end(io, st)
    end
    return
end

# ── Per-connection task ─────────────────────────────────────────────────────

function _sockets_connection(io::SocketsIO, st::HTTPConn, entry::SocketsEntry)
    id = objectid(st.handle)
    try
        while !st.retired && io.server.runtime.running[]
            if st.phase == :streaming
                # Consume the next head/chunk/terminal message; the write below
                # completes it and acks the worker.
                _sockets_deliver(io, st, take!(entry.reply))
            elseif st.phase != :awaiting
                data = try
                    readavailable(entry.sock)
                catch
                    break
                end
                isempty(data) && break

                st.inflight = :none
                http_on_read(io, st, pointer(data), length(data))
            end

            # A handler may run on a worker thread; wait for its reply before
            # touching this connection's state again.
            if st.phase == :awaiting && !st.retired
                _sockets_deliver(io, st, take!(entry.reply))
            end

            # Drain synchronous write completions, including pipelined responses.
            while entry.wrote > 0 && !st.retired
                n = entry.wrote
                entry.wrote = 0
                http_on_write(io, st, n)
            end
        end
    catch
    finally
        if !entry.released && haskey(io.states, id)
            entry.released = true
            http_finalize(io, st)
        end
    end
    return
end

# ── Driver ──────────────────────────────────────────────────────────────────

function _sockets_accept_loop(io::SocketsIO)
    while io.server.runtime.running[]
        sock = try
            Sockets.accept(io.listener)
        catch
            break
        end

        if Threads.atomic_add!(io.server.runtime.conn_count, 1) + 1 >
           io.server.config.max_connections
            Threads.atomic_sub!(io.server.runtime.conn_count, 1)
            close(sock)
            continue
        end

        st = isempty(io.free) ? HTTPConn(sock) : pop!(io.free)
        st.handle = sock
        http_reset!(st)
        st.deadline = time() + io.cfg.header_timeout_ms / 1000
        st.inflight = :read

        id = objectid(sock)
        entry = SocketsEntry(sock, 0, false, Channel{_Outbound}(1))
        io.states[id] = st
        io.entries[id] = entry
        @async _sockets_connection(io, st, entry)
    end
    return
end

"""Sweeps deadlines, then on shutdown stops accepting, retires every
connection, and waits for release (forced after `shutdown_timeout`)."""
function _sockets_drain_loop(io::SocketsIO)
    while io.server.runtime.running[]
        now = time()
        for (_, st) in collect(io.states)
            (st.retired || !http_expired(st, now)) || http_retire(io, st)
        end
        sleep(0.1)
    end

    isopen(io.listener) && close(io.listener)
    io.stop_time = time()
    deadline = io.stop_time + io.server.config.shutdown_timeout

    # Retire everything except handlers/streams still running on an async
    # executor; those get until the deadline to report back.
    while !isempty(io.states) && time() < deadline
        for (_, st) in collect(io.states)
            (st.retired || st.phase == :awaiting || st.phase == :streaming) && continue
            http_retire(io, st)
        end
        sleep(0.05)
    end
    for (_, st) in collect(io.states)
        st.retired || http_finalize(io, st)
    end
    return
end

function _start_sockets_workers(server::Server, nworkers::Int)
    nworkers > 1 && log!(server.logger, Warn,
        "sockets backend ignores nworkers=$nworkers (single accept loop)")
    addr = try
        parse(Sockets.IPAddr, server.config.host)
    catch
        error("sockets backend requires an IP-literal host, got $(server.config.host)")
    end
    listener = try
        Sockets.listen(addr, server.config.port; backlog=server.config.backlog)
    catch e
        error("sockets backend failed to listen on " *
              "$(server.config.host):$(server.config.port): $e")
    end
    log!(server.logger, Info,
         "sockets backend listening on $(server.config.host):$(server.config.port)")

    io = SocketsIO(server, listener)
    accept_task = @async _sockets_accept_loop(io)
    drain_task = @async _sockets_drain_loop(io)
    wait(accept_task)
    wait(drain_task)
    return
end
