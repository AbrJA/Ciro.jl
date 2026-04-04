module ServerUtilsTests
using Test
using Ciro

@testset "_write_int! - Zero Allocation Integer Conversion" begin
    buf = Vector{UInt8}(undef, 32)

    # Test positive integers
    cursor = Ciro.Servers._write_int!(buf, 1, 200)
    @test String(buf[1:cursor-1]) == "200"

    cursor = Ciro.Servers._write_int!(buf, 1, 404)
    @test String(buf[1:cursor-1]) == "404"

    cursor = Ciro.Servers._write_int!(buf, 1, 12345)
    @test String(buf[1:cursor-1]) == "12345"

    # Test zero
    cursor = Ciro.Servers._write_int!(buf, 1, 0)
    @test String(buf[1:cursor-1]) == "0"

    # Test single digit
    cursor = Ciro.Servers._write_int!(buf, 1, 5)
    @test String(buf[1:cursor-1]) == "5"

    # Test large number
    cursor = Ciro.Servers._write_int!(buf, 1, 1234567)
    @test String(buf[1:cursor-1]) == "1234567"
end

@testset "ndigits" begin
    @test Ciro.Servers.ndigits(0) == 1
    @test Ciro.Servers.ndigits(1) == 1
    @test Ciro.Servers.ndigits(9) == 1
    @test Ciro.Servers.ndigits(10) == 2
    @test Ciro.Servers.ndigits(999) == 3
    @test Ciro.Servers.ndigits(1000) == 4
end

@testset "_write_str! - Buffer Writing" begin
    buf = Vector{UInt8}(undef, 64)

    cursor = Ciro.Servers._write_str!(buf, 1, "HTTP/1.1 ")
    @test String(buf[1:cursor-1]) == "HTTP/1.1 "

    cursor = Ciro.Servers._write_str!(buf, cursor, "200")
    @test String(buf[1:cursor-1]) == "HTTP/1.1 200"
end

@testset "serialize_response" begin
    resp = text("Hello")
    pool = Vector{Vector{UInt8}}()
    buf = Ciro.Servers.serialize_response(resp, pool)
    output = String(buf)

    @test startswith(output, "HTTP/1.1 200 OK\r\n")
    @test occursin("Content-Type: text/plain; charset=utf-8\r\n", output)
    @test occursin("Content-Length: 5\r\n", output)
    @test endswith(output, "\r\n\r\nHello")
end

@testset "PendingWrites" begin
    pw = Ciro.Servers.PendingWrites(128)

    buf1 = UInt8[1, 2, 3]
    Ciro.Servers.pw_set!(pw, 5, buf1)
    result = Ciro.Servers.pw_pop!(pw, 5)
    @test result === buf1

    # After pop, should be nothing
    @test Ciro.Servers.pw_pop!(pw, 5) === nothing

    # Out of range fd
    @test Ciro.Servers.pw_pop!(pw, 99999) === nothing
end

end # module
