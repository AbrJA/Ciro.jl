# ══════════════════════════════════════════════════════════════════════════════
# Zero-copy response serialization
# ══════════════════════════════════════════════════════════════════════════════

# ── Cached Date Header (refreshed every second, RFC 5322 format) ────────────
# Thread-safety: _DATE_SEC is an Atomic so the stale-check is race-free.
# _DATE_LOCK serialises the string update; after the lock the new string is
# visible to all threads because `lock` issues a memory barrier.

const _HTTP_DATE_FMT = DateFormat("e, dd u yyyy HH:MM:SS")  # stdlib Dates
const _DATE_LOCK     = ReentrantLock()
const _DATE_STR      = Ref{String}("")
const _DATE_SEC      = Threads.Atomic{Int}(0)

"""Get the current HTTP Date header value (cached per-second, thread-safe)."""
@inline function _http_date()::String
    sec = round(Int, time())
    _DATE_SEC[] == sec && return _DATE_STR[]      # fast path — no lock
    lock(_DATE_LOCK) do
        if _DATE_SEC[] != sec                     # double-checked
            _DATE_STR[] = format(unix2datetime(sec), _HTTP_DATE_FMT) * " GMT"
            _DATE_SEC[] = sec                     # write AFTER string is ready
        end
    end
    return _DATE_STR[]
end

"""
    serialize_response!(buf::Vector{UInt8}, response::Response) -> Int

Serialize HTTP response into pre-allocated buffer. Returns bytes written.
Zero-allocation for the common path (status line is a const String).
"""
function serialize_response!(buf::Vector{UInt8}, response::Response)::Int
    sl = status(response.status)
    sl_len = sizeof(sl)

    # Body length
    body_data = response.body
    body_len = length(body_data)

    # Calculate total size needed
    headers_len = 0
    for (k, v) in response.headers
        headers_len += sizeof(k) + 2 + sizeof(v) + 2  # "key: value\r\n"
    end

    has_cl = hasheader(response, "Content-Length")
    has_date = hasheader(response, "Date")
    date_str = has_date ? "" : _http_date()

    if !has_cl
        headers_len += 16 + _ndigits(body_len) + 2  # "Content-Length: N\r\n"
    end
    if !has_date
        headers_len += 6 + sizeof(date_str) + 2  # "Date: ...\r\n"
    end
    headers_len += 2  # final "\r\n"

    total = sl_len + headers_len + body_len

    # Ensure buffer is large enough
    length(buf) < total && resize!(buf, total)

    cursor = 1

    # Status line
    cursor = _write_str!(buf, cursor, sl)

    # Headers
    for (k, v) in response.headers
        cursor = _write_str!(buf, cursor, k)
        cursor = _write_lit!(buf, cursor, ": ")
        cursor = _write_str!(buf, cursor, v)
        cursor = _write_lit!(buf, cursor, "\r\n")
    end

    if !has_cl
        cursor = _write_lit!(buf, cursor, "Content-Length: ")
        cursor = _write_int!(buf, cursor, body_len)
        cursor = _write_lit!(buf, cursor, "\r\n")
    end

    if !has_date
        cursor = _write_lit!(buf, cursor, "Date: ")
        cursor = _write_str!(buf, cursor, date_str)
        cursor = _write_lit!(buf, cursor, "\r\n")
    end

    cursor = _write_lit!(buf, cursor, "\r\n")

    # Body
    if body_len > 0
        GC.@preserve body_data begin
            unsafe_copyto!(pointer(buf, cursor), pointer(body_data), body_len)
        end
        cursor += body_len
    end

    return cursor - 1  # bytes written
end

# ── Streaming serialization ─────────────────────────────────────────────────

"""
    serialize_head!(buf, code, headers, chunked, close) -> Int

Serialize a status line and header section only (no body, no Content-Length),
adding `Transfer-Encoding: chunked` when `chunked` and `Connection: close` when
`close` (and not already present). Used to open a streaming response.
"""
function serialize_head!(buf::Vector{UInt8}, code::Int,
                         headers::Vector{Pair{String,String}},
                         chunked::Bool, close::Bool)::Int
    sl = status(code)
    sl_len = sizeof(sl)

    headers_len = 0
    for (k, v) in headers
        headers_len += sizeof(k) + 2 + sizeof(v) + 2
    end

    has_date = false
    has_connection = false
    for (k, _) in headers
        k == "Date" && (has_date = true)
        k == "Connection" && (has_connection = true)
    end
    date_str = has_date ? "" : _http_date()

    if chunked
        headers_len += 18 + 2   # "Transfer-Encoding: chunked\r\n"
    end
    if close && !has_connection
        headers_len += 10 + 5 + 2   # "Connection: close\r\n"
    end
    if !has_date
        headers_len += 6 + sizeof(date_str) + 2
    end
    headers_len += 2

    total = sl_len + headers_len
    length(buf) < total && resize!(buf, total)

    cursor = 1
    cursor = _write_str!(buf, cursor, sl)

    for (k, v) in headers
        cursor = _write_str!(buf, cursor, k)
        cursor = _write_lit!(buf, cursor, ": ")
        cursor = _write_str!(buf, cursor, v)
        cursor = _write_lit!(buf, cursor, "\r\n")
    end

    if chunked
        cursor = _write_lit!(buf, cursor, "Transfer-Encoding: chunked\r\n")
    end
    if close && !has_connection
        cursor = _write_lit!(buf, cursor, "Connection: close\r\n")
    end
    if !has_date
        cursor = _write_lit!(buf, cursor, "Date: ")
        cursor = _write_str!(buf, cursor, date_str)
        cursor = _write_lit!(buf, cursor, "\r\n")
    end
    cursor = _write_lit!(buf, cursor, "\r\n")

    return cursor - 1
end

"""
    serialize_chunk!(buf, data) -> Int

Frame `data` as one HTTP/1.1 chunk: `<hex-size>\\r\\n<data>\\r\\n`.
"""
function serialize_chunk!(buf::Vector{UInt8}, data::Vector{UInt8})::Int
    n = length(data)
    total = _hexdigits(n) + 2 + n + 2
    length(buf) < total && resize!(buf, total)
    cursor = _write_hex!(buf, 1, n)
    cursor = _write_lit!(buf, cursor, "\r\n")
    if n > 0
        GC.@preserve data unsafe_copyto!(pointer(buf, cursor), pointer(data), n)
        cursor += n
    end
    cursor = _write_lit!(buf, cursor, "\r\n")
    return cursor - 1
end

"""Write the terminating zero-length chunk (`0\\r\\n\\r\\n`)."""
function serialize_last_chunk!(buf::Vector{UInt8})::Int
    length(buf) < 5 && resize!(buf, 5)
    @inbounds begin
        buf[1] = UInt8('0')
        buf[2] = UInt8('\r')
        buf[3] = UInt8('\n')
        buf[4] = UInt8('\r')
        buf[5] = UInt8('\n')
    end
    return 5
end

"""Copy `data` for a raw streaming write (user supplied `Content-Length`)."""
function serialize_raw!(buf::Vector{UInt8}, data::Vector{UInt8})::Int
    n = length(data)
    length(buf) < n && resize!(buf, n)
    GC.@preserve data unsafe_copyto!(pointer(buf), pointer(data), n)
    return n
end

# ── Zero-copy write helpers ─────────────────────────────────────────────────

@inline function _write_str!(buf::Vector{UInt8}, cursor::Int, s::String)::Int
    n = sizeof(s)
    GC.@preserve s unsafe_copyto!(pointer(buf, cursor), pointer(s), n)
    return cursor + n
end

@inline function _write_str!(buf::Vector{UInt8}, cursor::Int, s::SubString{String})::Int
    n = sizeof(s)
    GC.@preserve s unsafe_copyto!(pointer(buf, cursor), pointer(s), n)
    return cursor + n
end

@inline _write_lit!(buf::Vector{UInt8}, cursor::Int, s::String) = _write_str!(buf, cursor, s)

@inline function _write_int!(buf::Vector{UInt8}, cursor::Int, val::Int)::Int
    val == 0 && (@inbounds buf[cursor] = UInt8('0'); return cursor + 1)
    n = _ndigits(val)
    pos = cursor + n - 1
    v = val
    while v > 0
        @inbounds buf[pos] = UInt8('0') + UInt8(v % 10)
        v = div(v, 10)
        pos -= 1
    end
    return cursor + n
end

@inline function _ndigits(n::Int)::Int
    n <= 0 && return 1
    d = 0
    v = n
    while v > 0
        v = div(v, 10)
        d += 1
    end
    return d
end

@inline function _hexdigits(n::Int)::Int
    d = 1
    v = n
    while v >= 16
        v >>= 4
        d += 1
    end
    return d
end

"""Write `n` as lowercase hex digits (chunk-size encoding)."""
@inline function _write_hex!(buf::Vector{UInt8}, cursor::Int, n::Int)::Int
    d = _hexdigits(n)
    pos = cursor + d - 1
    v = n
    @inbounds for _ in 1:d
        digit = v & 0xf
        buf[pos] = digit < 10 ? (UInt8('0') + digit) : (UInt8('a') + digit - 10)
        v >>= 4
        pos -= 1
    end
    return cursor + d
end
