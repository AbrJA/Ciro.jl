module WebSockets

using SHA
using Base64
using ..Types

export ws_upgrade, ws_encode_text, ws_encode_binary, ws_encode_close,
       ws_encode_ping, ws_encode_pong, ws_decode_frame, WSFrame,
       WS_TEXT, WS_BINARY, WS_CLOSE, WS_PING, WS_PONG

# --- Opcodes (RFC 6455 §5.2) ---
const WS_CONTINUATION = UInt8(0x0)
const WS_TEXT         = UInt8(0x1)
const WS_BINARY       = UInt8(0x2)
const WS_CLOSE        = UInt8(0x8)
const WS_PING         = UInt8(0x9)
const WS_PONG         = UInt8(0xA)

const WS_MAGIC = "258EAFA5-E914-47DA-95CA-5AB5DC76E00B"

# --- Handshake ---

"""
    ws_upgrade(req) -> Response

Generate a WebSocket upgrade response (HTTP 101).
Returns 400 if the request is not a valid WebSocket upgrade.
"""
function ws_upgrade(req)::Response
    ws_key = ""
    upgrade = false
    for (k, v) in req.headers
        sk = String(k)
        if sk == "Sec-WebSocket-Key"
            ws_key = String(v)
        elseif lowercase(sk) == "upgrade" && lowercase(String(v)) == "websocket"
            upgrade = true
        end
    end

    (!upgrade || isempty(ws_key)) && return Response(400, "Bad WebSocket Request")

    accept = base64encode(sha1(ws_key * WS_MAGIC))
    return Response(101, [
        "Upgrade" => "websocket",
        "Connection" => "Upgrade",
        "Sec-WebSocket-Accept" => accept,
    ], UInt8[])
end

# --- Frame Encoding ---

function _encode_frame(opcode::UInt8, payload::AbstractVector{UInt8}; fin::Bool=true)::Vector{UInt8}
    len = length(payload)
    # Calculate header size
    hdr = 2
    if len > 65535
        hdr += 8
    elseif len > 125
        hdr += 2
    end

    frame = Vector{UInt8}(undef, hdr + len)
    frame[1] = (fin ? 0x80 : 0x00) | opcode

    if len <= 125
        frame[2] = UInt8(len)
    elseif len <= 65535
        frame[2] = 0x7E
        frame[3] = UInt8((len >> 8) & 0xFF)
        frame[4] = UInt8(len & 0xFF)
    else
        frame[2] = 0x7F
        for i in 0:7
            frame[3+i] = UInt8((len >> (56 - 8i)) & 0xFF)
        end
    end

    len > 0 && copyto!(frame, hdr + 1, payload, 1, len)
    return frame
end

ws_encode_text(msg::String) = _encode_frame(WS_TEXT, Vector{UInt8}(msg))
ws_encode_binary(data::Vector{UInt8}) = _encode_frame(WS_BINARY, data)
ws_encode_ping(data::Vector{UInt8}=UInt8[]) = _encode_frame(WS_PING, data)
ws_encode_pong(data::Vector{UInt8}=UInt8[]) = _encode_frame(WS_PONG, data)

function ws_encode_close(code::UInt16=UInt16(1000), reason::String="")
    payload = UInt8[UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
    !isempty(reason) && append!(payload, Vector{UInt8}(reason))
    return _encode_frame(WS_CLOSE, payload)
end

# --- Frame Decoding ---

struct WSFrame
    fin::Bool
    opcode::UInt8
    payload::Vector{UInt8}
end

"""
    ws_decode_frame(data) -> Union{Nothing, Tuple{WSFrame, Int}}

Decode a WebSocket frame from raw bytes.
Returns `(frame, bytes_consumed)` or `nothing` if not enough data.
"""
function ws_decode_frame(data::AbstractVector{UInt8})::Union{Nothing, Tuple{WSFrame, Int}}
    length(data) < 2 && return nothing

    @inbounds fin    = (data[1] & 0x80) != 0
    @inbounds opcode = data[1] & 0x0F
    @inbounds masked = (data[2] & 0x80) != 0
    @inbounds plen   = Int(data[2] & 0x7F)

    offset = 3
    if plen == 126
        length(data) < 4 && return nothing
        plen = Int(data[3]) << 8 | Int(data[4])
        offset = 5
    elseif plen == 127
        length(data) < 10 && return nothing
        plen = 0
        for i in 0:7
            plen |= Int(data[3+i]) << (56 - 8i)
        end
        offset = 11
    end

    if masked
        length(data) < offset + 3 && return nothing
        mask = @view data[offset:offset+3]
        offset += 4
    end

    total = offset - 1 + plen
    length(data) < total && return nothing

    payload = Vector{UInt8}(undef, plen)
    plen > 0 && copyto!(payload, 1, data, offset, plen)

    # Unmask (RFC 6455 §5.3)
    if masked
        for i in 1:plen
            @inbounds payload[i] ⊻= mask[((i-1) & 3) + 1]
        end
    end

    return (WSFrame(fin, opcode, payload), total)
end

end
