# ══════════════════════════════════════════════════════════════════════════════
# Zero-copy response serialization
# ══════════════════════════════════════════════════════════════════════════════

using Dates: DateFormat, format, unix2datetime

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
    sl = Interface.status(response.status)
    sl_len = sizeof(sl)

    # Body length
    body_data = response.body
    body_len = length(body_data)

    # Calculate total size needed
    headers_len = 0
    for (k, v) in response.headers
        headers_len += sizeof(k) + 2 + sizeof(v) + 2  # "key: value\r\n"
    end

    has_cl = Interface.hasheader(response, "Content-Length")
    has_date = Interface.hasheader(response, "Date")
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
