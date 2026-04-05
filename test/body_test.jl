module BodyTests
using Test
using Ciro
using StringViews

function mock_request_with_body(method::String, path::String, body_data::String;
                                content_type::String="application/x-www-form-urlencoded")
    method_bytes = Vector{UInt8}(method)
    path_bytes = Vector{UInt8}(path)
    body_bytes = Vector{UInt8}(body_data)
    method_sv = StringView(@view method_bytes[1:end])
    path_sv = StringView(@view path_bytes[1:end])
    ct_key = Vector{UInt8}("Content-Type")
    ct_val = Vector{UInt8}(content_type)
    headers = [StringView(@view ct_key[1:end]) => StringView(@view ct_val[1:end])]
    body = @view body_bytes[1:end]
    return Ciro.Types.Request(method_sv, path_sv, 1, headers, body)
end

@testset "body_string" begin
    req = mock_request_with_body("POST", "/data", "hello world")
    @test body_string(req) == "hello world"
end

@testset "body_bytes" begin
    req = mock_request_with_body("POST", "/data", "abc")
    bytes = body_bytes(req)
    @test bytes == UInt8[0x61, 0x62, 0x63]
    @test bytes isa Vector{UInt8}
end

@testset "parse_form" begin
    req = mock_request_with_body("POST", "/submit", "name=Alice&age=30")
    form = parse_form(req)
    @test form["name"] == "Alice"
    @test form["age"] == "30"

    # URL-encoded values
    req = mock_request_with_body("POST", "/submit", "msg=hello+world&path=%2Ffoo")
    form = parse_form(req)
    @test form["msg"] == "hello world"
    @test form["path"] == "/foo"

    # Wrong content type
    req = mock_request_with_body("POST", "/submit", "not form data"; content_type="text/plain")
    form = parse_form(req)
    @test isempty(form)

    # Empty form body
    req = mock_request_with_body("POST", "/submit", "")
    form = parse_form(req)
    @test isempty(form)
end

end # module
