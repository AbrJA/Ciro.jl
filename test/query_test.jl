module QueryTests
using Test
using Ciro
using StringViews

@testset "parse_query" begin
    # Basic parsing
    d = Ciro.QueryParsing.parse_query("foo=bar&baz=123")
    @test d["foo"] == "bar"
    @test d["baz"] == "123"

    # Empty query
    d = Ciro.QueryParsing.parse_query("")
    @test isempty(d)

    # Key without value
    d = Ciro.QueryParsing.parse_query("flag&key=val")
    @test d["flag"] == ""
    @test d["key"] == "val"

    # URL-encoded values
    d = Ciro.QueryParsing.parse_query("name=hello%20world&q=a%26b")
    @test d["name"] == "hello world"
    @test d["q"] == "a&b"

    # Plus as space
    d = Ciro.QueryParsing.parse_query("q=hello+world")
    @test d["q"] == "hello world"

    # Percent-encoded special chars
    d = Ciro.QueryParsing.parse_query("path=%2Ffoo%2Fbar")
    @test d["path"] == "/foo/bar"
end

@testset "urldecode" begin
    @test Ciro.QueryParsing.urldecode("hello%20world") == "hello world"
    @test Ciro.QueryParsing.urldecode("foo+bar") == "foo bar"
    @test Ciro.QueryParsing.urldecode("100%25") == "100%"
    @test Ciro.QueryParsing.urldecode("noencode") == "noencode"
    @test Ciro.QueryParsing.urldecode("") == ""
    # Invalid percent encoding passed through
    @test Ciro.QueryParsing.urldecode("%ZZ") == "%ZZ"
end

# Mock request helper
function mock_request(method::String, path::String)
    method_bytes = Vector{UInt8}(method)
    path_bytes = Vector{UInt8}(path)
    method_sv = StringView(@view method_bytes[1:end])
    path_sv = StringView(@view path_bytes[1:end])
    body = @view UInt8[][1:0]
    headers = Pair{typeof(method_sv),typeof(method_sv)}[]
    return Ciro.Types.Request(method_sv, path_sv, 1, headers, body)
end

@testset "query_params" begin
    req = mock_request("GET", "/search?q=julia&page=2")
    params = query_params(req)
    @test params["q"] == "julia"
    @test params["page"] == "2"

    # No query string
    req = mock_request("GET", "/users")
    params = query_params(req)
    @test isempty(params)
end

@testset "clean_path" begin
    req = mock_request("GET", "/search?q=julia")
    @test String(clean_path(req)) == "/search"

    req = mock_request("GET", "/users")
    @test String(clean_path(req)) == "/users"

    req = mock_request("GET", "/path?")
    @test String(clean_path(req)) == "/path"
end

end # module
