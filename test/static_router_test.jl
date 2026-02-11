module StaticRouterTests
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

# --- Test Handlers ---

function index_handler(req)
    return text("Welcome!")
end

function hello_handler(req)
    return text("Hello!")
end

function get_user(req, id)
    return text("User: " * String(id))
end

function get_user_post(req, user_id, post_id)
    return text("User " * String(user_id) * " Post " * String(post_id))
end

function post_data(req)
    return text("Data received")
end

# --- Middleware for testing ---

function TestMiddleware(req, next)
    resp = next(req)
    push!(resp.headers, "X-Middleware" => "applied")
    return resp
end

# --- Define test apps ---

@routes BasicApp begin
    ("GET", "/") => index_handler
    ("GET", "/hello") => hello_handler
    ("POST", "/data") => post_data
end

@routes ParamApp begin
    ("GET", "/user/:id") => get_user
    ("GET", "/user/:uid/post/:pid") => get_user_post
end

@routes MiddlewareApp begin
    middleware(TestMiddleware)
    ("GET", "/") => index_handler
end

# --- Tests ---

@testset "StaticRouter Basic Routes" begin
    resp = dispatch(BasicApp(), mock_request("GET", "/"))
    @test resp.status == 200
    @test String(resp.body) == "Welcome!"

    resp = dispatch(BasicApp(), mock_request("GET", "/hello"))
    @test resp.status == 200
    @test String(resp.body) == "Hello!"

    resp = dispatch(BasicApp(), mock_request("POST", "/data"))
    @test resp.status == 200
    @test String(resp.body) == "Data received"

    # 404 for unknown route
    resp = dispatch(BasicApp(), mock_request("GET", "/nonexistent"))
    @test resp.status == 404

    # 404 for method mismatch
    resp = dispatch(BasicApp(), mock_request("POST", "/hello"))
    @test resp.status == 404
end

@testset "StaticRouter Param Routes" begin
    resp = dispatch(ParamApp(), mock_request("GET", "/user/42"))
    @test resp.status == 200
    @test String(resp.body) == "User: 42"

    resp = dispatch(ParamApp(), mock_request("GET", "/user/10/post/99"))
    @test resp.status == 200
    @test String(resp.body) == "User 10 Post 99"
end

@testset "StaticRouter Middleware" begin
    resp = dispatch(MiddlewareApp(), mock_request("GET", "/"))
    @test resp.status == 200
    @test String(resp.body) == "Welcome!"

    # Verify middleware was applied
    found_mw = false
    for (k, v) in resp.headers
        if k == "X-Middleware" && v == "applied"
            found_mw = true
            break
        end
    end
    @test found_mw
end

end # module
