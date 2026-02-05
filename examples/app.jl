import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
include(joinpath(@__DIR__, "../src/Ciro.jl"))
using .Ciro

println("Setting up routes...")

# Use Middleware
#Ciro.use(Ciro.Logger)

Ciro.get("/") do req::Ciro.Request
    return Ciro.text("Welcome to the User Defined Router!")
end

Ciro.get("/hello") do req::Ciro.Request
    return Ciro.text("Hello from the new API!")
end

Ciro.get("/large") do req::Ciro.Request
    # Test Zero-Copy with 5MB payload
    data = repeat("A", 5 * 1024 * 1024)
    return Senciro.text(data)
end


Ciro.post("/data") do req::Ciro.Request
    return Ciro.text("Data received!")
end

Ciro.get("/json") do req::Ciro.Request
    # Test JSON serialization
    return Ciro.json(Dict("status" => "ok", "message" => "This is JSON"))
end

Ciro.get("/user/:id") do req::Ciro.Request
    id = Base.get(req.params, "id", "unknown")
    return Ciro.json(Dict("user_id" => id))
end

println("Starting server on port 8080...")
Ciro.start_server(8080)
