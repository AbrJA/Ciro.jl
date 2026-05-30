# ══════════════════════════════════════════════════════════════════════════════
# Zero-copy response serialization
# ══════════════════════════════════════════════════════════════════════════════

using Dates: unix2datetime, dayofweek, year, month, day, hour, minute, second

# ── Cached Date Header (refreshed every second, RFC 5322 format) ────────────

const _DAY_ABBR = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
const _MON_ABBR = ("Jan", "Feb", "Mar", "Apr", "May", "Jun",
                   "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
const _DATE_STR = Ref{String}("")
const _DATE_SEC = Ref{Int}(0)

"""Get the current HTTP Date header value (cached, refreshed per-second)."""
@inline function _http_date()::String
    sec = round(Int, time())
    if sec != _DATE_SEC[]
        _DATE_SEC[] = sec
        dt = unix2datetime(sec)
        dow = dayofweek(dt)  # 1=Monday
        _DATE_STR[] = string(
            _DAY_ABBR[dow], ", ",
            lpad(day(dt), 2, '0'), " ",
            _MON_ABBR[month(dt)], " ",
            year(dt), " ",
            lpad(hour(dt), 2, '0'), ":",
            lpad(minute(dt), 2, '0'), ":",
            lpad(second(dt), 2, '0'), " GMT")
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

    # Body length (sizeof for String, length for Vector{UInt8})
    body_data = response.body
    body_len = body_data isa String ? sizeof(body_data) : length(body_data)

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

    # Body (handles both String and Vector{UInt8})
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
