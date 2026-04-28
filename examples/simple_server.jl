using Ciro
using Ciro.Servers
using Ciro.Routers: get, post
using Ciro.Types

# Define routes
get("/hello") do req, params
    return text("Hello, World!")
end

get("/user/:id") do req, params
    return text("User $(params["id"])")
end

post("/echo") do req, params
    return text("You sent: " * String(req.body))
end

# Start server
println("Starting server on 8080...")
start_server(8080)
