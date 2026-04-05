module HTTP2

export H2Frame, h2_parse_frame, h2_encode_frame, h2_settings_frame,
       h2_goaway_frame, h2_headers_frame, h2_data_frame,
       is_h2_preface, H2_PREFACE

# --- HTTP/2 Connection Preface (RFC 7540 §3.5) ---
const H2_PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

# --- Frame Types (RFC 7540 §6) ---
const FRAME_DATA          = UInt8(0x0)
const FRAME_HEADERS       = UInt8(0x1)
const FRAME_PRIORITY      = UInt8(0x2)
const FRAME_RST_STREAM    = UInt8(0x3)
const FRAME_SETTINGS      = UInt8(0x4)
const FRAME_PUSH_PROMISE  = UInt8(0x5)
const FRAME_PING          = UInt8(0x6)
const FRAME_GOAWAY        = UInt8(0x7)
const FRAME_WINDOW_UPDATE = UInt8(0x8)
const FRAME_CONTINUATION  = UInt8(0x9)

# --- Frame Flags ---
const FLAG_ACK        = UInt8(0x1)
const FLAG_END_STREAM = UInt8(0x1)
const FLAG_END_HEADERS = UInt8(0x4)
const FLAG_PADDED     = UInt8(0x8)
const FLAG_PRIORITY_F = UInt8(0x20)

# --- Settings Parameters (RFC 7540 §6.5.2) ---
const SETTINGS_HEADER_TABLE_SIZE      = UInt16(0x1)
const SETTINGS_ENABLE_PUSH            = UInt16(0x2)
const SETTINGS_MAX_CONCURRENT_STREAMS = UInt16(0x3)
const SETTINGS_INITIAL_WINDOW_SIZE    = UInt16(0x4)
const SETTINGS_MAX_FRAME_SIZE         = UInt16(0x5)
const SETTINGS_MAX_HEADER_LIST_SIZE   = UInt16(0x6)

# --- Frame Structure ---
struct H2Frame
    length::UInt32   # 24-bit payload length
    type::UInt8
    flags::UInt8
    stream_id::UInt32  # 31-bit
    payload::Vector{UInt8}
end

"""
    is_h2_preface(data) -> Bool

Check if the bytes start with the HTTP/2 connection preface.
"""
function is_h2_preface(data::AbstractVector{UInt8})::Bool
    length(data) < length(H2_PREFACE) && return false
    for i in 1:length(H2_PREFACE)
        @inbounds data[i] != H2_PREFACE[i] && return false
    end
    return true
end

"""
    h2_parse_frame(data) -> Union{Nothing, Tuple{H2Frame, Int}}

Parse an HTTP/2 frame from raw bytes.
Returns `(frame, bytes_consumed)` or `nothing` if not enough data.
Frame header is 9 bytes: length(3) + type(1) + flags(1) + stream_id(4).
"""
function h2_parse_frame(data::AbstractVector{UInt8})::Union{Nothing, Tuple{H2Frame, Int}}
    length(data) < 9 && return nothing

    plen = (UInt32(data[1]) << 16) | (UInt32(data[2]) << 8) | UInt32(data[3])
    ftype = data[4]
    flags = data[5]
    sid = (UInt32(data[6]) << 24) | (UInt32(data[7]) << 16) |
          (UInt32(data[8]) << 8) | UInt32(data[9])
    sid &= 0x7FFFFFFF  # Clear reserved bit

    total = 9 + Int(plen)
    length(data) < total && return nothing

    payload = plen > 0 ? Vector{UInt8}(data[10:9+plen]) : UInt8[]
    return (H2Frame(plen, ftype, flags, sid, payload), total)
end

"""
    h2_encode_frame(type, flags, stream_id, payload) -> Vector{UInt8}

Encode an HTTP/2 frame.
"""
function h2_encode_frame(ftype::UInt8, flags::UInt8, stream_id::UInt32,
                         payload::Vector{UInt8}=UInt8[])::Vector{UInt8}
    plen = length(payload)
    frame = Vector{UInt8}(undef, 9 + plen)
    frame[1] = UInt8((plen >> 16) & 0xFF)
    frame[2] = UInt8((plen >> 8) & 0xFF)
    frame[3] = UInt8(plen & 0xFF)
    frame[4] = ftype
    frame[5] = flags
    sid = stream_id & 0x7FFFFFFF
    frame[6] = UInt8((sid >> 24) & 0xFF)
    frame[7] = UInt8((sid >> 16) & 0xFF)
    frame[8] = UInt8((sid >> 8) & 0xFF)
    frame[9] = UInt8(sid & 0xFF)
    plen > 0 && copyto!(frame, 10, payload, 1, plen)
    return frame
end

# --- Convenience Frame Builders ---

function h2_settings_frame(; ack::Bool=false,
                            settings::Vector{Pair{UInt16,UInt32}}=Pair{UInt16,UInt32}[])
    flags = ack ? FLAG_ACK : UInt8(0)
    payload = UInt8[]
    for (id, val) in settings
        append!(payload, [UInt8((id >> 8) & 0xFF), UInt8(id & 0xFF),
                          UInt8((val >> 24) & 0xFF), UInt8((val >> 16) & 0xFF),
                          UInt8((val >> 8) & 0xFF), UInt8(val & 0xFF)])
    end
    return h2_encode_frame(FRAME_SETTINGS, flags, UInt32(0), payload)
end

function h2_goaway_frame(last_stream_id::UInt32, error_code::UInt32=UInt32(0))
    payload = Vector{UInt8}(undef, 8)
    payload[1] = UInt8((last_stream_id >> 24) & 0x7F)
    payload[2] = UInt8((last_stream_id >> 16) & 0xFF)
    payload[3] = UInt8((last_stream_id >> 8) & 0xFF)
    payload[4] = UInt8(last_stream_id & 0xFF)
    payload[5] = UInt8((error_code >> 24) & 0xFF)
    payload[6] = UInt8((error_code >> 16) & 0xFF)
    payload[7] = UInt8((error_code >> 8) & 0xFF)
    payload[8] = UInt8(error_code & 0xFF)
    return h2_encode_frame(FRAME_GOAWAY, UInt8(0), UInt32(0), payload)
end

"""
    h2_data_frame(stream_id, data; end_stream=true) -> Vector{UInt8}

Build an HTTP/2 DATA frame.
"""
function h2_data_frame(stream_id::UInt32, data::Vector{UInt8}; end_stream::Bool=true)
    flags = end_stream ? FLAG_END_STREAM : UInt8(0)
    return h2_encode_frame(FRAME_DATA, flags, stream_id, data)
end

# --- Minimal HPACK (RFC 7541) — Static Table Only ---
# For production use, integrate libnghttp2 for full HPACK with dynamic table.

const HPACK_STATIC_TABLE = [
    (":authority", ""),         # 1
    (":method", "GET"),        # 2
    (":method", "POST"),       # 3
    (":path", "/"),            # 4
    (":path", "/index.html"),  # 5
    (":scheme", "http"),       # 6
    (":scheme", "https"),      # 7
    (":status", "200"),        # 8
    (":status", "204"),        # 9
    (":status", "206"),        # 10
    (":status", "304"),        # 11
    (":status", "400"),        # 12
    (":status", "404"),        # 13
    (":status", "500"),        # 14
    ("accept-charset", ""),    # 15
    ("accept-encoding", "gzip, deflate"),  # 16
    ("accept-language", ""),   # 17
    ("accept-ranges", ""),     # 18
    ("accept", ""),            # 19
    ("content-length", ""),    # 31
    ("content-type", ""),      # 31
]

"""
    hpack_encode_headers(headers) -> Vector{UInt8}

Encode HTTP headers using minimal HPACK (literal with indexing disabled).
This is a simplified encoder — use libnghttp2 for full HPACK in production.
"""
function hpack_encode_headers(headers::Vector{Pair{String,String}})::Vector{UInt8}
    buf = UInt8[]
    for (name, value) in headers
        # Literal header field without indexing (RFC 7541 §6.2.2)
        push!(buf, 0x00)  # prefix 0000
        _hpack_encode_string!(buf, name)
        _hpack_encode_string!(buf, value)
    end
    return buf
end

function _hpack_encode_string!(buf::Vector{UInt8}, s::String)
    n = sizeof(s)
    if n < 127
        push!(buf, UInt8(n))  # No Huffman, 7-bit length
    else
        push!(buf, UInt8(0x7F))
        _encode_varint!(buf, n - 127)
    end
    append!(buf, codeunits(s))
end

function _encode_varint!(buf::Vector{UInt8}, val::Int)
    while val >= 128
        push!(buf, UInt8((val & 0x7F) | 0x80))
        val >>= 7
    end
    push!(buf, UInt8(val))
end

"""
    h2_headers_frame(stream_id, headers; end_stream=false) -> Vector{UInt8}

Build an HTTP/2 HEADERS frame with HPACK-encoded headers.
"""
function h2_headers_frame(stream_id::UInt32, headers::Vector{Pair{String,String}};
                          end_stream::Bool=false)
    hpack_data = hpack_encode_headers(headers)
    flags = FLAG_END_HEADERS
    end_stream && (flags |= FLAG_END_STREAM)
    return h2_encode_frame(FRAME_HEADERS, flags, stream_id, hpack_data)
end

end
