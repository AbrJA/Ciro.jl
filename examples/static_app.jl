using Ciro

# --- Handlers ---

function index(req)
    return Response(200, "Static Router Index")
end

function get_user(req, id)
    return Response(200, "User ID: " * String(id))
end

function get_post(req, user, post_id)
    return Response(200, "User: " * String(user) * ", Post: " * String(post_id))
end

# --- Middleware ---

function TimingMiddleware(req, next)
    t = time_ns()
    resp = next(req)
    elapsed = (time_ns() - t) / 1_000_000
    println("Request took ", round(elapsed, digits=2), "ms")
    return resp
end

# --- Define routes with middleware ---

@routes App begin
    middleware(TimingMiddleware)
    ("GET", "/") => index
    ("GET", "/user/:id") => get_user
    ("GET", "/user/:u/post/:p") => get_post
end

# --- Start server ---

println("Starting Ciro with middleware on port 8080...")
start_server(App(), 8080)
