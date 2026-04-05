module H2Tests
using Test
using Ciro

@testset "HTTP/2 Preface Detection" begin
    preface = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
    @test is_h2_preface(preface) == true
    @test is_h2_preface(UInt8[0x00]) == false
    @test is_h2_preface(UInt8[]) == false

    # Preface followed by more data
    extra = vcat(Vector{UInt8}(preface), UInt8[0x00, 0x00, 0x00])
    @test is_h2_preface(extra) == true
end

@testset "HTTP/2 Frame Encode/Decode Roundtrip" begin
    # SETTINGS frame
    settings = h2_settings_frame()
    result = h2_parse_frame(settings)
    @test result !== nothing
    frame, consumed = result
    @test frame.type == 0x04  # SETTINGS
    @test frame.stream_id == 0
    @test consumed == length(settings)

    # SETTINGS ACK
    ack = h2_settings_frame(ack=true)
    result = h2_parse_frame(ack)
    @test result !== nothing
    frame, _ = result
    @test frame.flags & 0x01 != 0  # ACK flag

    # DATA frame
    payload = Vector{UInt8}("Hello HTTP/2")
    data_frame = h2_data_frame(UInt32(1), payload; end_stream=true)
    result = h2_parse_frame(data_frame)
    @test result !== nothing
    frame, consumed = result
    @test frame.type == 0x00  # DATA
    @test frame.stream_id == 1
    @test frame.payload == payload
    @test frame.flags & 0x01 != 0  # END_STREAM
    @test consumed == length(data_frame)
end

@testset "HTTP/2 GOAWAY Frame" begin
    goaway = h2_goaway_frame(UInt32(5), UInt32(0))
    result = h2_parse_frame(goaway)
    @test result !== nothing
    frame, _ = result
    @test frame.type == 0x07  # GOAWAY
    @test frame.stream_id == 0
    @test length(frame.payload) == 8
end

@testset "HTTP/2 HEADERS Frame" begin
    headers = ["content-type" => "text/plain", "x-custom" => "value"]
    hdr_frame = h2_headers_frame(UInt32(1), headers; end_stream=true)
    result = h2_parse_frame(hdr_frame)
    @test result !== nothing
    frame, _ = result
    @test frame.type == 0x01  # HEADERS
    @test frame.stream_id == 1
    @test frame.flags & 0x04 != 0  # END_HEADERS
    @test frame.flags & 0x01 != 0  # END_STREAM
    @test !isempty(frame.payload)
end

@testset "HTTP/2 Frame Parse - Insufficient Data" begin
    @test h2_parse_frame(UInt8[]) === nothing
    @test h2_parse_frame(UInt8[0x00, 0x00]) === nothing
    # Frame header says 100 bytes payload but only 9 bytes total
    short = UInt8[0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    @test h2_parse_frame(short) === nothing
end

@testset "HPACK Encode" begin
    headers = ["content-type" => "text/plain"]
    encoded = Ciro.HTTP2.hpack_encode_headers(headers)
    @test !isempty(encoded)
    @test encoded[1] == 0x00  # Literal without indexing
end

@testset "HTTP/2 SETTINGS with Parameters" begin
    settings = h2_settings_frame(
        settings=[
            UInt16(0x3) => UInt32(100),  # MAX_CONCURRENT_STREAMS
            UInt16(0x4) => UInt32(65535), # INITIAL_WINDOW_SIZE
        ]
    )
    result = h2_parse_frame(settings)
    @test result !== nothing
    frame, _ = result
    @test length(frame.payload) == 12  # 2 settings × 6 bytes each
end

end # module
