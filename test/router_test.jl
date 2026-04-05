module RouterGroupTests
using Test
using Ciro
using StringViews

# --- Helper ---

function mock_request(method::String, path::String)
    method_bytes = Vector{UInt8}(method)
    path_bytes = Vector{UInt8}(path)
    method_sv = StringView(@view method_bytes[1:end])
    path_sv = StringView(@view path_bytes[1:end])
    body = @view UInt8[][1:0]
    headers = Pair{typeof(method_sv),typeof(method_sv)}[]
    return Ciro.Types.Request(method_sv, path_sv, 1, headers, body)
end

# --- Route Group Handlers ---

list_users(req) = text("users list")
create_user(req) = text("user created")
get_user(req, id) = text("user:" * String(id))
root_handler(req) = text("root")

# --- App with Route Groups ---

@routes GroupApp begin
    ("GET", "/") => root_handler
    group("/api/v1",
        ("GET", "/users") => list_users,
        ("POST", "/users") => create_user,
        ("GET", "/users/:id") => get_user,
    )
end

@testset "Route Groups - Basic" begin
    resp = dispatch(GroupApp(), mock_request("GET", "/"))
    @test resp.status == 200
    @test String(resp.body) == "root"

    resp = dispatch(GroupApp(), mock_request("GET", "/api/v1/users"))
    @test resp.status == 200
    @test String(resp.body) == "users list"

    resp = dispatch(GroupApp(), mock_request("POST", "/api/v1/users"))
    @test resp.status == 200
    @test String(resp.body) == "user created"

    resp = dispatch(GroupApp(), mock_request("GET", "/api/v1/users/42"))
    @test resp.status == 200
    @test String(resp.body) == "user:42"
end

@testset "Route Groups - 404 for ungrouped" begin
    resp = dispatch(GroupApp(), mock_request("GET", "/users"))
    @test resp.status == 404

    resp = dispatch(GroupApp(), mock_request("GET", "/api/v1"))
    @test resp.status == 404
end

# --- Query String Stripping in Router ---

hello_handler(req) = text("hello")

@routes QueryStripApp begin
    ("GET", "/hello") => hello_handler
    ("GET", "/users/:id") => get_user
end

@testset "Router - Query String Stripping" begin
    # Route should match even with query string
    resp = dispatch(QueryStripApp(), mock_request("GET", "/hello?foo=bar"))
    @test resp.status == 200
    @test String(resp.body) == "hello"

    resp = dispatch(QueryStripApp(), mock_request("GET", "/users/42?expand=true"))
    @test resp.status == 200
    @test String(resp.body) == "user:42"

    # Just question mark
    resp = dispatch(QueryStripApp(), mock_request("GET", "/hello?"))
    @test resp.status == 200
    @test String(resp.body) == "hello"
end

end # module
