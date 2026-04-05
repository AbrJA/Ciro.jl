using Ciro

# Handlers matching the Rust server
index(req) = text("Welcome!")
hello(req) = text("Hello!")

function json_handler(req)
    return Response(200, [
        "Content-Type" => "application/json; charset=utf-8"
    ], Vector{UInt8}("""{"message":"Hello, JSON!","status":"ok"}"""))
end

get_user(req, id) = text("User: " * String(id))

@routes BenchApp begin
    ("GET", "/") => index
    ("GET", "/hello") => hello
    ("GET", "/json") => json_handler
    ("GET", "/user/:id") => get_user
end

println("Starting Ciro benchmark server on port 8080...")
start_server(BenchApp(), 8080)
