module MiddlewareTests
using Test
using Ciro
using StringViews

function mock_request(method::String, path::String)
    method_bytes = Vector{UInt8}(method)
    path_bytes = Vector{UInt8}(path)
    method_sv = StringView(@view method_bytes[1:end])
    path_sv = StringView(@view path_bytes[1:end])
    body = @view UInt8[][1:0]
    headers = Pair{typeof(method_sv),typeof(method_sv)}[]
    return Ciro.Types.Request(method_sv, path_sv, 1, headers, body)
end

@testset "RequestId Middleware" begin
    req = mock_request("GET", "/")
    resp = RequestId(req, function(r)
        text("OK")
    end)
    @test resp.status == 200
    id_found = false
    for (k, v) in resp.headers
        if k == "X-Request-Id"
            id_found = true
            @test !isempty(v)
        end
    end
    @test id_found
end

@testset "Timing Middleware" begin
    req = mock_request("GET", "/")
    resp = Timing(req, function(r)
        text("OK")
    end)
    @test resp.status == 200
    timing_found = false
    for (k, v) in resp.headers
        if k == "X-Response-Time"
            timing_found = true
            @test endswith(v, "ms")
        end
    end
    @test timing_found
end

@testset "CORS Middleware - Preflight" begin
    opts_bytes = Vector{UInt8}("OPTIONS")
    path_bytes = Vector{UInt8}("/api")
    opts_sv = StringView(@view opts_bytes[1:end])
    path_sv = StringView(@view path_bytes[1:end])
    body = @view UInt8[][1:0]
    headers = Pair{typeof(opts_sv),typeof(opts_sv)}[]
    req = Ciro.Types.Request(opts_sv, path_sv, 1, headers, body)

    resp = CORS(req, r -> text("should not reach"))
    @test resp.status == 204

    origin_found = false
    for (k, v) in resp.headers
        if k == "Access-Control-Allow-Origin"
            origin_found = true
            @test v == "*"
        end
    end
    @test origin_found
end

@testset "CORS Middleware - Regular Request" begin
    req = mock_request("GET", "/api")
    resp = CORS(req, r -> text("OK"))
    @test resp.status == 200

    origin_found = false
    for (k, v) in resp.headers
        if k == "Access-Control-Allow-Origin"
            origin_found = true
        end
    end
    @test origin_found
end

@testset "cors() Factory" begin
    custom = cors(origins="https://example.com", max_age=600)
    req = mock_request("GET", "/api")
    resp = custom(req, r -> text("OK"))
    @test resp.status == 200

    for (k, v) in resp.headers
        if k == "Access-Control-Allow-Origin"
            @test v == "https://example.com"
        end
    end
end

end # module
