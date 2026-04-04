using Ciro
using JSON  # Activates CiroJSON extension

# --- Handlers ---

function index(req)
    return text("Welcome to Ciro!")
end

function hello(req)
    return text("Hello from the API!")
end

function large_payload(req)
    data = repeat("A", 5 * 1024 * 1024)
    return text(data)
end

function post_data(req)
    return text("Data received!")
end

function json_response(req)
    return json(Dict("status" => "ok", "message" => "This is JSON"))
end

function get_user(req, id)
    return json(Dict("user_id" => String(id)))
end

function health(req)
    return json(Dict("status" => "healthy"))
end

# --- Define routes ---

@routes App begin
    middleware(Logger)
    ("GET", "/") => index
    ("GET", "/hello") => hello
    ("GET", "/large") => large_payload
    ("GET", "/health") => health
    ("POST", "/data") => post_data
    ("GET", "/json") => json_response
    ("GET", "/user/:id") => get_user
end

# --- Start server ---

println("Starting Ciro on port 8080...")
start_server(App(), 8080)
