using Ciro

# --- Handlers ---

function index(req)
    return text("Welcome to Ciro!")
end

function hello(req)
    return text("Hello from Ciro!")
end

function get_user(req, id)
    # id is a SubString (zero-copy from the request path)
    return text("User ID: " * String(id))
end

function post_data(req)
    return text("Data received!")
end

# --- Define routes (compile-time dispatch) ---

@routes App begin
    ("GET", "/") => index
    ("GET", "/hello") => hello
    ("GET", "/user/:id") => get_user
    ("POST", "/data") => post_data
end

# --- Start server ---

println("Starting Ciro on port 8080...")
start_server(App(), 8080)
