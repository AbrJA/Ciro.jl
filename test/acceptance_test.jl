# ══════════════════════════════════════════════════════════════════════════════
# Wire-level acceptance tests
#
# These tests talk to a real server over real sockets. They are the executable
# specification for the transport contract. Known P0 defects are pinned with
# @test_broken: when a fix lands, the test flips to a failure and must be
# promoted to @test.
#
# Requirements: Linux + lib/ciro.so built. Tests are skipped when lib is absent.
#
# The server runs in a separate Julia process. Two reasons:
#   1. It mirrors production deployment (`julia server.jl`).
#   2. The current event loop never yields, so an in-process worker can occupy
#      the thread Julia's scheduler needs, deadlocking an in-process client.
#      (Tracked as a Stage 1 defect; the subprocess keeps this suite deterministic
#      while the client itself also uses raw blocking libc sockets, not libuv.)
# ══════════════════════════════════════════════════════════════════════════════

using Test
using Ciro
using Sockets

const _LIB_OK = Sys.islinux() && isfile(Ciro.Backend._LIB)

if !_LIB_OK
    @info "Skipping wire acceptance tests" linux=Sys.islinux() lib_available=_LIB_OK
end

# ── raw blocking socket test client ─────────────────────────────────────────

const _AF_INET = Cint(2)
const _SOCK_STREAM = Cint(1)
const _SOL_SOCKET = Cint(1)
const _SO_RCVTIMEO = Cint(20)   # Linux x86_64
const _SO_SNDTIMEO = Cint(21)   # Linux x86_64

struct _TimeVal
    sec::Clong
    usec::Clong
end

struct _SockAddrIn
    family::UInt16
    port::UInt16
    addr::UInt32
    zero::NTuple{8,UInt8}
end

mutable struct TestClient
    fd::Cint
end

function TestClient(port::Integer; timeout::Float64=2.0)
    fd = ccall(:socket, Cint, (Cint, Cint, Cint), _AF_INET, _SOCK_STREAM, 0)
    fd < 0 && error("socket() failed")
    tv = _TimeVal(Clong(floor(Int, timeout)), Clong(round(Int, (timeout - floor(timeout)) * 1e6)))
    for opt in (_SO_RCVTIMEO, _SO_SNDTIMEO)
        ccall(:setsockopt, Cint, (Cint, Cint, Cint, Ref{_TimeVal}, UInt32),
              fd, _SOL_SOCKET, opt, tv, UInt32(sizeof(_TimeVal)))
    end
    addr = _SockAddrIn(UInt16(_AF_INET),   # sin_family is host byte order
                       ccall(:htons, UInt16, (UInt16,), UInt16(port)),
                       ccall(:inet_addr, UInt32, (Cstring,), "127.0.0.1"),
                       ntuple(_ -> UInt8(0), 8))
    r = ccall(:connect, Cint, (Cint, Ref{_SockAddrIn}, UInt32), fd, addr, UInt32(sizeof(_SockAddrIn)))
    if r != 0
        ccall(:close, Cint, (Cint,), fd)
        error("connect to port $port failed")
    end
    return TestClient(fd)
end

function _close(c::TestClient)
    c.fd >= 0 && ccall(:close, Cint, (Cint,), c.fd)
    c.fd = -1
    return nothing
end

function _send(c::TestClient, data::AbstractString)
    bytes = Vector{UInt8}(codeunits(data))
    off = 0
    while off < length(bytes)
        n = ccall(:send, Cssize_t, (Cint, Ptr{UInt8}, Csize_t, Cint),
                  c.fd, pointer(bytes, off + 1), length(bytes) - off, 0)
        n <= 0 && error("send failed")
        off += Int(n)
    end
    return nothing
end

"""Receive up to `n` bytes; returns short data on timeout or peer close."""
function _recv(c::TestClient, n::Integer)
    buf = Vector{UInt8}(undef, n)
    got = 0
    while got < n
        r = ccall(:recv, Cssize_t, (Cint, Ptr{UInt8}, Csize_t, Cint),
                  c.fd, pointer(buf, got + 1), n - got, 0)
        r <= 0 && break
        got += Int(r)
    end
    return buf[1:got]
end

function _recv_until_headers(c::TestClient)
    buf = UInt8[]
    while length(buf) < 65536
        chunk = _recv(c, 1)
        isempty(chunk) && break
        append!(buf, chunk)
        length(buf) >= 4 && buf[end-3:end] == UInt8['\r', '\n', '\r', '\n'] && break
    end
    return buf
end

"""Read one HTTP response (headers + Content-Length body). `nothing` on timeout."""
function read_response(c::TestClient; expect_body::Bool=true)
    head = _recv_until_headers(c)
    isempty(head) && return nothing
    head_str = String(copy(head))
    expect_body || return head_str
    m = match(r"(?i)content-length:\s*(\d+)", head_str)
    n = m === nothing ? 0 : parse(Int, m.captures[1])
    n == 0 && return head_str
    body = _recv(c, n)
    return head_str * String(copy(body))
end

"""Read one CRLF-terminated line (without the CRLF)."""
function _recv_line(c::TestClient)
    buf = UInt8[]
    while length(buf) < 8192
        ch = _recv(c, 1)
        isempty(ch) && break
        push!(buf, ch[1])
        if length(buf) >= 2 && buf[end-1] == UInt8('\r') && buf[end] == UInt8('\n')
            return String(copy(buf[1:end-2]))
        end
    end
    return String(copy(buf))
end

"""Read a chunked response body (headers must already be consumed)."""
function _read_chunked_body(c::TestClient)
    body = UInt8[]
    while true
        line = _recv_line(c)
        isempty(line) && break
        n = try
            parse(Int, split(line, ";")[1], base=16)
        catch
            break
        end
        if n == 0
            while !isempty(_recv_line(c))   # trailers
            end
            break
        end
        append!(body, _recv(c, n))
        _recv(c, 2)   # CRLF after chunk data
    end
    return String(copy(body))
end

"""
Blocking (yielding) client for in-process servers. The raw `TestClient` would
stall the Julia scheduler while the server shares this process, so in-process
tests use libuv sockets, which yield while the server tasks run.
"""
function _julia_request(port::Integer, data::AbstractString)
    sock = Sockets.connect(Sockets.IPv4("127.0.0.1"), port)
    try
        write(sock, data)
        result = Ref("")
        task = @async (result[] = String(readuntil(sock, "\r\n\r\n")))
        timedwait(() -> istaskdone(task), 10.0) == :ok ||
            error("in-process request to port $port timed out")
        return result[]
    finally
        close(sock)
    end
end

"""Send a full request on a fresh connection and read one response."""
function roundtrip(port::Integer, data::AbstractString; timeout::Float64=2.0, expect_body::Bool=true)
    c = TestClient(port; timeout)
    try
        _send(c, data)
        return read_response(c; expect_body)
    finally
        _close(c)
    end
end

function _fd_count()::Int
    Sys.islinux() || return 0
    return length(readdir("/proc/self/fd"))
end

function _wait_ready(port::Integer)
    for _ in 1:400
        try
            _close(TestClient(port; timeout=0.5))
            return
        catch
            sleep(0.05)
        end
    end
    error("wire test server did not become ready on port $port")
end

# ── server subprocess ───────────────────────────────────────────────────────

const _SERVER_SRC = raw"""
using Ciro
router = Trie()
get!(router, "/hello", _ -> text("hello"))
get!(router, "/head", _ -> text("content"))
post!(router, "/echo", ctx -> text(body(ctx)))
get!(router, "/inject", _ -> redirect("/x\r\nX-Injected: yes"))
get!(router, "/slow", _ -> (sleep(0.3); text("slow")))
get!(router, "/hold", _ -> (sleep(0.6); text("held")))
get!(router, "/stream", _ -> stream() do w
    for i in 1:3
        println(w, "chunk", i)
        sleep(0.05)
    end
end)
get!(router, "/events", _ -> sse() do send
    send("one"; event="tick", id="1")
    send("two\nlines"; event="tick", id="2")
end)
get!(router, "/stream-cl", _ -> stream(; headers=["Content-Length" => "5"]) do w
    write(w, "hello")
end)
get!(router, "/forever", _ -> stream() do w
    while true
        write(w, "tick")
        sleep(0.05)
    end
end)
post!(router, "/tiny", ctx -> text(body(ctx)); limits=RouteLimits(max_body_size=8))
post!(router, "/big", ctx -> text(body(ctx)); limits=RouteLimits(max_body_size=1024))
post!(router, "/quick", ctx -> text(body(ctx)); limits=RouteLimits(body_timeout_ms=150))
start!(Server(; router, port=PORT EXTRA); nworkers=2)
"""

function _start_server(port::Integer; extra::AbstractString="", threads::Int=2)
    project = Base.active_project()
    project === nothing && error("no active project; cannot start test server")
    src = replace(_SERVER_SRC, "PORT" => string(port), "EXTRA" => extra)
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$project --threads=$threads -e $src`
    return run(pipeline(cmd; stdout=devnull, stderr=devnull); wait=false)
end

function _kill_server(proc)
    proc === nothing && return
    kill(proc, 9)
    try
        wait(proc)
    catch
    end
    return
end

# ── suite ───────────────────────────────────────────────────────────────────

@testset "Wire acceptance" begin
    if !_LIB_OK
        @test_skip true
    else
        port = 20000 + (getpid() % 20000)
        proc = _start_server(port)

        try
            _wait_ready(port)

            @testset "routing anchors" begin
                @test startswith(roundtrip(port, "GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"),
                                 "HTTP/1.1 200")
                @test startswith(roundtrip(port, "GET /missing HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"),
                                 "HTTP/1.1 404")
                resp405 = roundtrip(port, "DELETE /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                @test startswith(resp405, "HTTP/1.1 405")
                @test occursin("Allow:", resp405)
                @test occursin("GET", resp405)
                # streaming needs AsyncExecutor; the sync server answers 500
                @test startswith(roundtrip(port, "GET /stream HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"),
                                 "HTTP/1.1 500")
            end

            @testset "keep-alive" begin
                c = TestClient(port)
                try
                    _send(c, "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n")
                    r1 = read_response(c)
                    _send(c, "GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                    r2 = read_response(c)
                    @test startswith(r1, "HTTP/1.1 200")
                    @test occursin("hello", r1)
                    @test startswith(r2, "HTTP/1.1 200")
                    @test occursin("hello", r2)
                finally
                    _close(c)
                end
            end

            @testset "complete POST in one segment" begin
                resp = roundtrip(port,
                    "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nConnection: close\r\n\r\n12345")
                @test startswith(resp, "HTTP/1.1 200")
                @test endswith(resp, "12345")
            end

            @testset "malformed framing rejected" begin
                # obs-fold continuation lines must not be silently re-framed
                @test startswith(roundtrip(port,
                    "GET /hello HTTP/1.1\r\nHost: x\r\nX-A: 1\r\n\tcontinued\r\nConnection: close\r\n\r\n"),
                    "HTTP/1.1 400")

                # duplicate / invalid Content-Length and CL+TE are smuggling hazards
                @test startswith(roundtrip(port,
                    "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nContent-Length: 1\r\nConnection: close\r\n\r\na"),
                    "HTTP/1.1 400")
                @test startswith(roundtrip(port,
                    "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: abc\r\nConnection: close\r\n\r\n"),
                    "HTTP/1.1 400")
                @test startswith(roundtrip(port,
                    "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Length: 1\r\nConnection: close\r\n\r\na"),
                    "HTTP/1.1 400")
            end

            @testset "chunked request bodies" begin
                # Complete chunked body in one segment.
                resp = roundtrip(port,
                    "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" *
                    "5\r\nhello\r\n0\r\n\r\n")
                @test startswith(resp, "HTTP/1.1 200")
                @test endswith(resp, "hello")

                # Chunks split across writes.
                c = TestClient(port)
                try
                    _send(c, "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
                    _send(c, "5\r\nhel")
                    sleep(0.1)
                    _send(c, "lo\r\n0\r\n\r\n")
                    resp = read_response(c)
                    @test startswith(resp, "HTTP/1.1 200")
                    @test endswith(resp, "hello")
                finally
                    _close(c)
                end

                # Trailer section is consumed, body is complete.
                resp = roundtrip(port,
                    "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" *
                    "3\r\nabc\r\n0\r\nX-Trailer: v\r\n\r\n")
                @test startswith(resp, "HTTP/1.1 200")
                @test endswith(resp, "abc")

                # A pipelined request follows the chunked message in the same buffer.
                c = TestClient(port)
                try
                    _send(c, "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" *
                             "2\r\nhi\r\n0\r\n\r\n" *
                             "GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                    r1 = read_response(c)
                    r2 = read_response(c)
                    @test startswith(r1, "HTTP/1.1 200") && endswith(r1, "hi")
                    @test startswith(r2, "HTTP/1.1 200") && occursin("hello", r2)
                finally
                    _close(c)
                end
            end

            @testset "split headers (P0: must buffer incrementally)" begin
                c = TestClient(port)
                try
                    _send(c, "GET /hello HTTP/1.1\r\nHo")
                    sleep(0.1)
                    _send(c, "st: x\r\nConnection: close\r\n\r\n")
                    resp = read_response(c)
                    @test startswith(resp, "HTTP/1.1 200")
                finally
                    _close(c)
                end
            end

            @testset "split body (P0: must wait for Content-Length)" begin
                c = TestClient(port)
                try
                    _send(c, "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\nConnection: close\r\n\r\n12345")
                    sleep(0.1)
                    _send(c, "67890")
                    resp = read_response(c)
                    @test startswith(resp, "HTTP/1.1 200")
                finally
                    _close(c)
                end
            end

            @testset "body larger than one read buffer (P0)" begin
                payload = repeat("a", 70_000)
                c = TestClient(port; timeout=5.0)
                try
                    _send(c, "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 70000\r\nConnection: close\r\n\r\n" * payload)
                    resp = read_response(c)
                    @test startswith(resp, "HTTP/1.1 200")
                finally
                    _close(c)
                end
            end

            @testset "pipelining (P0: must carry leftover bytes)" begin
                c = TestClient(port; timeout=1.0)
                try
                    _send(c, "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n" *
                             "GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                    r1 = read_response(c)
                    r2 = read_response(c)
                    got = (r1 !== nothing && occursin("HTTP/1.1 200", r1)) +
                          (r2 !== nothing && occursin("HTTP/1.1 200", r2))
                    @test got == 2
                finally
                    _close(c)
                end
            end

            @testset "HEAD reports GET entity length (P0)" begin
                resp = roundtrip(port, "HEAD /head HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                                 expect_body=false)
                @test startswith(resp, "HTTP/1.1 200")
                @test !occursin("content", resp)
                @test occursin("Content-Length: 7", resp)
            end

            @testset "CRLF header injection (P0 security)" begin
                resp = roundtrip(port, "GET /inject HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                @test !occursin("X-Injected", resp)
            end

            @testset "no fd growth across closed connections" begin
                GC.gc()
                before = _fd_count()
                for _ in 1:20
                    c = TestClient(port)
                    try
                        _send(c, "GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                        read_response(c)
                    finally
                        _close(c)
                    end
                end
                sleep(0.2)
                GC.gc()
                @test _fd_count() - before <= 5
            end

            @testset "limits and timeouts" begin
                limited_port = port + 1
                limited = _start_server(limited_port;
                    extra=", max_header_bytes=1024, max_body_size=64, " *
                          "header_timeout_ms=400, body_timeout_ms=400, idle_timeout_ms=400")
                try
                    _wait_ready(limited_port)

                    @testset "431 header limit" begin
                        c = TestClient(limited_port; timeout=3.0)
                        try
                            _send(c, "GET / HTTP/1.1\r\nX-Big: " * "a"^2000)
                            resp = read_response(c)
                            @test startswith(resp, "HTTP/1.1 431")
                        finally
                            _close(c)
                        end
                    end

                    @testset "413 body limit" begin
                        @test startswith(roundtrip(limited_port,
                            "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 1000\r\nConnection: close\r\n\r\n"),
                            "HTTP/1.1 413")
                    end

                    @testset "413 chunked body limit" begin
                        chunk = repeat("a", 50)   # 0x32 bytes; two chunks exceed max_body_size=64
                        resp = roundtrip(limited_port,
                            "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" *
                            "32\r\n" * chunk * "\r\n32\r\n" * chunk * "\r\n0\r\n\r\n")
                        @test startswith(resp, "HTTP/1.1 413")
                    end

                    @testset "per-route body limit" begin
                        # Stricter than the server-wide 64: rejected early.
                        @test startswith(roundtrip(limited_port,
                            "POST /tiny HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nConnection: close\r\n\r\n12345"),
                            "HTTP/1.1 200")
                        @test startswith(roundtrip(limited_port,
                            "POST /tiny HTTP/1.1\r\nHost: x\r\nContent-Length: 9\r\nConnection: close\r\n\r\n123456789"),
                            "HTTP/1.1 413")
                        chunk = repeat("a", 32)
                        @test startswith(roundtrip(limited_port,
                            "POST /tiny HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" *
                            "20\r\n" * chunk * "\r\n0\r\n\r\n"),
                            "HTTP/1.1 413")
                        # Looser than the server-wide 64: accepted for this route.
                        @test startswith(roundtrip(limited_port,
                            "POST /big HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\nConnection: close\r\n\r\n" *
                            repeat("b", 100)),
                            "HTTP/1.1 200")
                    end

                    @testset "per-route body timeout" begin
                        c = TestClient(limited_port; timeout=3.0)
                        try
                            _send(c, "POST /quick HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n12345")
                            t0 = time()
                            resp = read_response(c)
                            @test resp === nothing
                            @test time() - t0 < 0.35   # route timeout 150ms vs server 400ms
                        finally
                            _close(c)
                        end
                    end

                    @testset "header timeout" begin
                        c = TestClient(limited_port; timeout=3.0)
                        try
                            _send(c, "GET / HTTP/1.1\r\nHos")
                            t0 = time()
                            resp = read_response(c)
                            @test resp === nothing
                            @test time() - t0 < 2.0
                        finally
                            _close(c)
                        end
                    end

                    @testset "body timeout" begin
                        c = TestClient(limited_port; timeout=3.0)
                        try
                            _send(c, "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n12345")
                            t0 = time()
                            resp = read_response(c)
                            @test resp === nothing
                            @test time() - t0 < 2.0
                        finally
                            _close(c)
                        end
                    end

                    @testset "idle timeout" begin
                        c = TestClient(limited_port; timeout=3.0)
                        try
                            _send(c, "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n")
                            @test startswith(read_response(c), "HTTP/1.1 200")
                            t0 = time()
                            resp = read_response(c)
                            @test resp === nothing
                            @test time() - t0 < 2.0
                        finally
                            _close(c)
                        end
                    end
                finally
                    _kill_server(limited)
                end
            end

            @testset "sockets backend (portable seam proof)" begin
                sock_port = port + 3
                sp = _start_server(sock_port; extra=", backend=:sockets")
                try
                    _wait_ready(sock_port)

                    @test startswith(roundtrip(sock_port,
                        "GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"; timeout=10.0),
                        "HTTP/1.1 200")

                    # keep-alive then a split-header request on the same connection
                    c = TestClient(sock_port; timeout=10.0)
                    try
                        _send(c, "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n")
                        @test startswith(read_response(c), "HTTP/1.1 200")
                        _send(c, "GET /head HTTP/1.1\r\nHo")
                        sleep(0.1)
                        _send(c, "st: x\r\nConnection: close\r\n\r\n")
                        @test startswith(read_response(c), "HTTP/1.1 200")
                    finally
                        _close(c)
                    end

                    # chunked body
                    resp = roundtrip(sock_port,
                        "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" *
                        "5\r\nhello\r\n0\r\n\r\n")
                    @test startswith(resp, "HTTP/1.1 200")
                    @test endswith(resp, "hello")

                    # framing defenses hold on this backend too
                    @test startswith(roundtrip(sock_port,
                        "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nContent-Length: 1\r\nConnection: close\r\n\r\na"),
                        "HTTP/1.1 400")

                    # ... and so do per-route limits
                    @test startswith(roundtrip(sock_port,
                        "POST /tiny HTTP/1.1\r\nHost: x\r\nContent-Length: 9\r\nConnection: close\r\n\r\n123456789"),
                        "HTTP/1.1 413")
                finally
                    _kill_server(sp)
                end
            end

            @testset "async executor (both backends)" begin
                for backend in (:uring, :sockets)
                    async_port = port + (backend === :uring ? 4 : 5)
                    ap = _start_server(async_port; threads=4,
                        extra=", executor=AsyncExecutor(worker_threads=2, max_pending=8), backend=:$backend")
                    try
                        _wait_ready(async_port)

                        # A slow handler is answered correctly, off the loop.
                        t0 = time()
                        resp = roundtrip(async_port,
                            "GET /slow HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                            timeout=10.0)
                        @test startswith(resp, "HTTP/1.1 200")
                        @test endswith(resp, "slow")
                        @test time() - t0 >= 0.25

                        # ... and does not block other connections.
                        cslow = TestClient(async_port; timeout=10.0)
                        cfast = TestClient(async_port; timeout=10.0)
                        try
                            _send(cslow, "GET /slow HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                            sleep(0.05)
                            _send(cfast, "GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                            t0 = time()
                            fast = read_response(cfast)
                            elapsed = time() - t0
                            slow = read_response(cslow)
                            @test startswith(fast, "HTTP/1.1 200") && endswith(fast, "hello")
                            @test startswith(slow, "HTTP/1.1 200") && endswith(slow, "slow")
                            @test elapsed < 0.25
                        finally
                            _close(cslow)
                            _close(cfast)
                        end

                        # Keep-alive and pipelining after a deferred response.
                        c = TestClient(async_port; timeout=10.0)
                        try
                            _send(c, "GET /slow HTTP/1.1\r\nHost: x\r\n\r\n" *
                                     "GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                            r1 = read_response(c)
                            r2 = read_response(c)
                            @test startswith(r1, "HTTP/1.1 200") && endswith(r1, "slow")
                            @test startswith(r2, "HTTP/1.1 200") && endswith(r2, "hello")
                        finally
                            _close(c)
                        end

                        # Chunked streaming: incremental body, chunked framing.
                        c = TestClient(async_port; timeout=10.0)
                        try
                            _send(c, "GET /stream HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                            hs = String(copy(_recv_until_headers(c)))
                            @test startswith(hs, "HTTP/1.1 200")
                            @test occursin("Transfer-Encoding: chunked", hs)
                            @test _read_chunked_body(c) == "chunk1\nchunk2\nchunk3\n"
                        finally
                            _close(c)
                        end

                        # Server-Sent Events.
                        c = TestClient(async_port; timeout=10.0)
                        try
                            _send(c, "GET /events HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                            hs = String(copy(_recv_until_headers(c)))
                            @test occursin("Content-Type: text/event-stream", hs)
                            body = _read_chunked_body(c)
                            @test occursin("id: 1\nevent: tick\ndata: one\n\n", body)
                            @test occursin("data: two\ndata: lines\n\n", body)
                        finally
                            _close(c)
                        end

                        # A user-supplied Content-Length switches off chunking.
                        c = TestClient(async_port; timeout=10.0)
                        try
                            _send(c, "GET /stream-cl HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                            hs = String(copy(_recv_until_headers(c)))
                            @test occursin("Content-Length: 5", hs)
                            @test !occursin("chunked", hs)
                            @test String(copy(_recv(c, 5))) == "hello"
                        finally
                            _close(c)
                        end

                        # A pipelined request is answered after the stream ends.
                        c = TestClient(async_port; timeout=10.0)
                        try
                            _send(c, "GET /stream HTTP/1.1\r\nHost: x\r\n\r\n" *
                                     "GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                            _recv_until_headers(c)
                            @test _read_chunked_body(c) == "chunk1\nchunk2\nchunk3\n"
                            r = read_response(c)
                            @test startswith(r, "HTTP/1.1 200") && endswith(r, "hello")
                        finally
                            _close(c)
                        end
                    finally
                        _kill_server(ap)
                    end
                end
            end

            @testset "async executor shedding (both backends)" begin
                for backend in (:uring, :sockets)
                    shed_port = port + (backend === :uring ? 6 : 7)
                    sp = _start_server(shed_port; threads=4,
                        extra=", executor=AsyncExecutor(worker_threads=1, max_pending=1), backend=:$backend")
                    try
                        _wait_ready(shed_port)
                        c1 = TestClient(shed_port; timeout=10.0)
                        c2 = TestClient(shed_port; timeout=10.0)
                        try
                            _send(c1, "GET /hold HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                            _send(c2, "GET /hold HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                            r1 = read_response(c1)
                            r2 = read_response(c2)
                            codes = sort([parse(Int, split(r, " ")[2]) for r in (r1, r2)])
                            @test codes == [200, 503]
                            shed_resp = startswith(r1, "HTTP/1.1 503") ? r1 : r2
                            @test occursin("Retry-After: 1", shed_resp)
                        finally
                            _close(c1)
                            _close(c2)
                        end

                        # A client that vanishes mid-stream releases its worker:
                        # with max_pending=1 the next request would be shed if
                        # the interrupted stream still held the only slot.
                        c = TestClient(shed_port; timeout=10.0)
                        try
                            _send(c, "GET /forever HTTP/1.1\r\nHost: x\r\n\r\n")
                            hs = String(copy(_recv_until_headers(c)))
                            @test startswith(hs, "HTTP/1.1 200")
                        finally
                            _close(c)
                        end
                        sleep(0.5)
                        @test startswith(roundtrip(shed_port,
                            "GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"; timeout=10.0),
                            "HTTP/1.1 200")
                    finally
                        _kill_server(sp)
                    end
                end
            end

            @testset "telemetry (in-process sockets)" begin
                metrics = ServerMetrics()
                mport = port + 8
                mrouter = Trie()
                get!(mrouter, "/hello", _ -> text("hello"))
                get!(mrouter, "/boom", _ -> error("kaboom"))
                mserver = Server(; router=mrouter, port=mport, backend=:sockets,
                                 telemetry=metrics)
                mtask = Threads.@spawn start!(mserver; nworkers=1)
                try
                    _wait_ready(mport)
                    @test startswith(_julia_request(mport,
                        "GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"),
                        "HTTP/1.1 200")
                    @test startswith(_julia_request(mport,
                        "GET /missing HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"),
                        "HTTP/1.1 404")
                    @test startswith(_julia_request(mport,
                        "GET /boom HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"),
                        "HTTP/1.1 500")
                    @test startswith(_julia_request(mport, "BAD REQUEST\r\n\r\n"),
                                     "HTTP/1.1 400")

                    @test timedwait(() -> metrics_snapshot(metrics).responses >= 4, 5.0) == :ok
                    s = metrics_snapshot(metrics)
                    @test s.requests == 3      # the malformed head never became a request
                    @test s.responses == 4
                    @test s.status_2xx == 1 && s.status_4xx == 2 && s.status_5xx == 1
                    @test s.exceptions == 1    # /boom, counted by the catcher wrapper
                    @test s.bytes_in > 0 && s.bytes_out > 0
                finally
                    stop!(mserver)
                    timedwait(() -> istaskdone(mtask), 5.0)
                end

                logbuf = IOBuffer()
                lport = port + 9
                lrouter = Trie()
                get!(lrouter, "/hello", _ -> text("hello"))
                lserver = Server(; router=lrouter, port=lport, backend=:sockets,
                                 telemetry=AccessLog(logbuf))
                ltask = Threads.@spawn start!(lserver; nworkers=1)
                try
                    _wait_ready(lport)
                    @test startswith(_julia_request(lport,
                        "GET /hello?x=1 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"),
                        "HTTP/1.1 200")
                    @test timedwait(() ->
                        occursin("\"GET /hello?x=1\" 200", String(copy(logbuf.data))), 5.0) == :ok
                    line = String(take!(logbuf))
                    @test occursin("\"GET /hello?x=1\" 200", line)
                    @test occursin("ms", line)
                finally
                    stop!(lserver)
                    timedwait(() -> istaskdone(ltask), 5.0)
                end
            end

            @testset "stop! drains and returns" begin
                # Exercise the supported API directly: start a server, then
                # stop it from another task and require start! to return after
                # the drain. Wire behavior itself is covered by the subprocess
                # servers above; keeping this test socket-free makes it
                # deterministic under Pkg.test's bounds-checked scheduler.
                drain_port = port + 2
                router = Trie()
                get!(router, "/hello", _ -> text("hello"))
                server = Server(; router, port=drain_port, backend=:sockets)
                task = Threads.@spawn start!(server; nworkers=1)
                try
                    _wait_ready(drain_port)
                    stop!(server)
                    @test timedwait(() -> istaskdone(task), 8.0) == :ok
                    @test !server.runtime.running[]
                finally
                    stop!(server)
                    timedwait(() -> istaskdone(task), 5.0)
                end
            end
        finally
            _kill_server(proc)
        end
    end
end
