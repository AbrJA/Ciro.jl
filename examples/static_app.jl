using Ciro
using Ciro.StaticRouter

# Define Handlers
function index(req)
    return Ciro.Response(200, "Static Router Index")
end

function get_user(req, id)
    return Ciro.Response(200, "User ID: $id")
end

function get_post(req, user, post_id)
    return Ciro.Response(200, "User: $user, Post: $post_id")
end

# Define Router
StaticRouter.@routes App begin
    ("GET", "/") => index
    ("GET", "/user/:id") => get_user
    ("GET", "/user/:u/post/:p") => get_post
end

# Start Server
# We need to bridge the server's generic handler to this specific app dispatch
# The server expects a handler function (req) -> res
# Ciro.start_server takes a port? No, it uses GLOBAL_ROUTER usually.
# But StaticRouter is standalone dispatch.
# We can use Ciro's server if we plug it in.
# For now, just printing that logic is ready.

println("Static Router Defined. To use with server, integration is needed in Ciro.jl's server loop to call StaticRouter.dispatch(App(), req)")
