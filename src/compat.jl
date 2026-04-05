module Compat

using Sockets
using ..Types
using ..Router: AbstractApp, dispatch

export fallback_server

"""
    fallback_server(app, port=8080; max_connections=1024)

Portable HTTP server using Julia's `Sockets` stdlib.
Works on Linux, macOS, and Windows — no io_uring required.

Slower than the io_uring backend but fully cross-platform.
Useful for development, testing, and non-Linux deployments.
"""
function fallback_server(app::AbstractApp, port::Int=8080;
                         max_connections::Int=1024)
    server = Sockets.listen(Sockets.IPv4(0), port)
    println("🚀 Ciro (fallback) listening on port $port")

    try
        while true
            sock = Sockets.accept(server)
            Threads.@spawn _handle_connection(app, sock)
        end
    catch e
        e isa InterruptException || rethrow(e)
    finally
        close(server)
        println("🛑 Server stopped")
    end
end

function _handle_connection(app::AbstractApp, sock)
    try
        while isopen(sock)
            data = _read_request(sock)
            isempty(data) && break

            # Lazy import — PicoHTTPParser is available via the parent module
            req = _try_parse(data)
            if req === nothing
                _write_response(sock, Response(400, "Bad Request"))
                break
            end

            resp = dispatch(app, req)
            _write_response(sock, resp)

            # Check Connection: close
            for (k, v) in req.headers
                if String(k) == "Connection" && String(v) == "close"
                    return
                end
            end
        end
    catch e
        e isa Base.IOError || @error "Connection error" exception=e
    finally
        close(sock)
    end
end

function _read_request(sock; timeout_s::Float64=30.0)::Vector{UInt8}
    buf = UInt8[]
    deadline = time() + timeout_s
    while time() < deadline
        if bytesavailable(sock) > 0
            append!(buf, readavailable(sock))
            # Simple heuristic: look for end of headers
            _has_complete_headers(buf) && return buf
        else
            isopen(sock) || break
            sleep(0.001)
        end
    end
    return buf
end

function _has_complete_headers(data::Vector{UInt8})::Bool
    n = length(data)
    n < 4 && return false
    for i in 1:n-3
        @inbounds if data[i] == UInt8('\r') && data[i+1] == UInt8('\n') &&
                     data[i+2] == UInt8('\r') && data[i+3] == UInt8('\n')
            return true
        end
    end
    return false
end

function _try_parse(data::Vector{UInt8})
    try
        return Main.PicoHTTPParser.parse_request(data)
    catch
        return nothing
    end
end

function _write_response(sock, resp::Response)
    sl = Types.status_line(resp.status)
    write(sock, sl)
    for (k, v) in resp.headers
        write(sock, k, ": ", v, "\r\n")
    end
    if !Types.hasheader(resp, "Content-Length")
        write(sock, "Content-Length: ", string(length(resp.body)), "\r\n")
    end
    write(sock, "\r\n")
    !isempty(resp.body) && write(sock, resp.body)
end

end
