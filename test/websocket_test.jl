module WebSocketTests
using Test
using Ciro
using Ciro: ws_encode_text, ws_encode_binary, ws_encode_close,
            ws_encode_pong, ws_decode_frame, WSFrame, ws_upgrade,
            WS_TEXT, WS_BINARY, WS_CLOSE, WS_PING, WS_PONG
using StringViews
using SHA
using Base64

@testset "WebSocket Frame Encoding - Text" begin
    frame = ws_encode_text("Hello")
    @test frame[1] == 0x81  # FIN + TEXT opcode
    @test frame[2] == 0x05  # payload length = 5
    @test String(frame[3:end]) == "Hello"
end

@testset "WebSocket Frame Encoding - Binary" begin
    data = UInt8[1, 2, 3, 4]
    frame = ws_encode_binary(data)
    @test frame[1] == 0x82  # FIN + BINARY opcode
    @test frame[2] == 0x04
    @test frame[3:end] == data
end

@testset "WebSocket Frame Encoding - Close" begin
    frame = ws_encode_close(UInt16(1000), "Normal")
    @test frame[1] == 0x88  # FIN + CLOSE opcode
    payload_len = frame[2]
    @test payload_len == 8  # 2 bytes code + 6 bytes "Normal"
    @test frame[3] == 0x03  # 1000 >> 8
    @test frame[4] == 0xE8  # 1000 & 0xFF
    @test String(frame[5:end]) == "Normal"
end

@testset "WebSocket Frame Encoding - Medium Payload (126-65535)" begin
    payload = repeat(UInt8[0x41], 300)
    frame = Ciro.WebSockets._encode_frame(WS_TEXT, payload)
    @test frame[1] == 0x81
    @test frame[2] == 0x7E  # Extended payload indicator
    @test (Int(frame[3]) << 8 | Int(frame[4])) == 300
    @test length(frame) == 4 + 300
end

@testset "WebSocket Frame Decoding - Unmasked" begin
    # Encode then decode
    original = "Hello, WebSocket!"
    encoded = ws_encode_text(original)
    result = ws_decode_frame(encoded)
    @test result !== nothing
    frame, consumed = result
    @test frame.fin == true
    @test frame.opcode == WS_TEXT
    @test String(frame.payload) == original
    @test consumed == length(encoded)
end

@testset "WebSocket Frame Decoding - Masked (Client-to-Server)" begin
    # Build a masked frame manually
    payload = Vector{UInt8}("Hi")
    mask = UInt8[0x37, 0xfa, 0x21, 0x3d]
    masked_payload = similar(payload)
    for i in eachindex(payload)
        masked_payload[i] = payload[i] ⊻ mask[((i-1) % 4) + 1]
    end
    frame = UInt8[
        0x81,  # FIN + TEXT
        0x82,  # MASK bit + length 2
        mask...,
        masked_payload...,
    ]
    result = ws_decode_frame(frame)
    @test result !== nothing
    decoded, consumed = result
    @test decoded.fin == true
    @test decoded.opcode == WS_TEXT
    @test String(decoded.payload) == "Hi"
end

@testset "WebSocket Frame Decoding - Insufficient Data" begin
    @test ws_decode_frame(UInt8[]) === nothing
    @test ws_decode_frame(UInt8[0x81]) === nothing
end

@testset "WebSocket Upgrade Handshake" begin
    # Build a valid WebSocket upgrade request
    method_bytes = Vector{UInt8}("GET")
    path_bytes = Vector{UInt8}("/ws")
    method_sv = StringView(@view method_bytes[1:end])
    path_sv = StringView(@view path_bytes[1:end])

    ws_key = "dGhlIHNhbXBsZSBub25jZQ=="
    expected_accept = base64encode(sha1(ws_key * "258EAFA5-E914-47DA-95CA-5AB5DC76E00B"))

    hdr_keys = [Vector{UInt8}("Upgrade"), Vector{UInt8}("Sec-WebSocket-Key"), Vector{UInt8}("Connection")]
    hdr_vals = [Vector{UInt8}("websocket"), Vector{UInt8}(ws_key), Vector{UInt8}("Upgrade")]
    headers = [StringView(@view hdr_keys[i][1:end]) => StringView(@view hdr_vals[i][1:end]) for i in 1:3]

    body = @view UInt8[][1:0]
    req = Ciro.Types.Request(method_sv, path_sv, 1, headers, body)

    resp = ws_upgrade(req)
    @test resp.status == 101

    # Check Sec-WebSocket-Accept header
    accept_found = false
    for (k, v) in resp.headers
        if k == "Sec-WebSocket-Accept"
            @test v == expected_accept
            accept_found = true
        end
    end
    @test accept_found
end

@testset "WebSocket Upgrade - Bad Request" begin
    method_bytes = Vector{UInt8}("GET")
    path_bytes = Vector{UInt8}("/ws")
    method_sv = StringView(@view method_bytes[1:end])
    path_sv = StringView(@view path_bytes[1:end])
    body = @view UInt8[][1:0]
    headers = Pair{StringView{SubArray{UInt8, 1, Vector{UInt8}, Tuple{UnitRange{Int64}}, true}},
                   StringView{SubArray{UInt8, 1, Vector{UInt8}, Tuple{UnitRange{Int64}}, true}}}[]
    req = Ciro.Types.Request(method_sv, path_sv, 1, headers, body)

    resp = ws_upgrade(req)
    @test resp.status == 400
end

end # module
