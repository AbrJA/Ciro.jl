using Test
using Ciro

@testset "Telemetry" begin

    @testset "NullTelemetry is inert" begin
        t = NullTelemetry()
        @test telemetry_active(t) == false
        @test telemetry_capture_path(t) == false
        @test telemetry_request!(t, Methods.GET, "/x", UInt8(1)) === nothing
        @test telemetry_response!(t, Methods.GET, "/x", 200, 1, 0.0) === nothing
        @test telemetry_read!(t, 1) === nothing
        @test telemetry_exception!(t) === nothing
    end

    @testset "ServerMetrics counters" begin
        m = ServerMetrics()
        @test telemetry_active(m) == true
        @test telemetry_capture_path(m) == false

        telemetry_request!(m, Methods.GET, "/a", UInt8(1))
        telemetry_request!(m, Methods.POST, "/b", UInt8(1))
        telemetry_read!(m, 120)
        telemetry_response!(m, Methods.GET, "/a", 204, 10, 0.001)
        telemetry_response!(m, Methods.POST, "/b", 404, 20, 0.002)
        telemetry_response!(m, Methods.POST, "/b", 500, 30, 0.003)
        telemetry_exception!(m)

        s = metrics_snapshot(m)
        @test s.requests == 2
        @test s.responses == 3
        @test s.status_1xx == 0 && s.status_2xx == 1 && s.status_3xx == 0
        @test s.status_4xx == 1 && s.status_5xx == 1
        @test s.exceptions == 1
        @test s.bytes_in == 120 && s.bytes_out == 60
    end

    @testset "AccessLog format" begin
        buf = IOBuffer()
        log = AccessLog(buf)
        @test telemetry_active(log) == true
        @test telemetry_capture_path(log) == true

        telemetry_response!(log, Methods.GET, "/hello?x=1", 200, 123, 0.001234)
        out = String(take!(buf))
        @test occursin("\"GET /hello?x=1\" 200 123 1.234ms", out)

        telemetry_response!(log, Methods.UNKNOWN, "", 400, 9, 0.0)
        @test occursin("\"UNKNOWN \" 400 9 0.0ms", String(take!(buf)))
    end

    @testset "catcher wrapper counts and delegates" begin
        m = ServerMetrics()
        c = Ciro.Interface._TelemetryCatcher(DefaultCatcher(), m)
        resp = intercept(c, ErrorException("boom"), nothing)
        @test resp.status == 500
        @test metrics_snapshot(m).exceptions == 1
    end
end
