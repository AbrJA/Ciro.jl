module ServerUtilsTests
using Test
using Ciro

@testset "write_int! - Zero Allocation Integer Conversion" begin
    buf = Vector{UInt8}(undef, 32)

    # Test positive integers
    cursor = Ciro.Servers.write_int!(buf, 1, 200)
    @test String(buf[1:cursor-1]) == "200"

    cursor = Ciro.Servers.write_int!(buf, 1, 404)
    @test String(buf[1:cursor-1]) == "404"

    cursor = Ciro.Servers.write_int!(buf, 1, 12345)
    @test String(buf[1:cursor-1]) == "12345"

    # Test zero
    cursor = Ciro.Servers.write_int!(buf, 1, 0)
    @test String(buf[1:cursor-1]) == "0"

    # Test single digit
    cursor = Ciro.Servers.write_int!(buf, 1, 5)
    @test String(buf[1:cursor-1]) == "5"

    # Test large number
    cursor = Ciro.Servers.write_int!(buf, 1, 1234567)
    @test String(buf[1:cursor-1]) == "1234567"
end

@testset "get_status_text - HTTP Status Lookup" begin
    @test Ciro.Servers.get_status_text(200) == "OK"
    @test Ciro.Servers.get_status_text(201) == "Created"
    @test Ciro.Servers.get_status_text(400) == "Bad Request"
    @test Ciro.Servers.get_status_text(404) == "Not Found"
    @test Ciro.Servers.get_status_text(500) == "Internal Server Error"
    @test Ciro.Servers.get_status_text(999) == "Unknown"  # Fallback
end

@testset "write_bytes! - Buffer Writing" begin
    buf = Vector{UInt8}(undef, 64)

    cursor = Ciro.Servers.write_bytes!(buf, 1, "HTTP/1.1 ")
    @test String(buf[1:cursor-1]) == "HTTP/1.1 "

    cursor = Ciro.Servers.write_bytes!(buf, cursor, "200")
    @test String(buf[1:cursor-1]) == "HTTP/1.1 200"
end

end # module
