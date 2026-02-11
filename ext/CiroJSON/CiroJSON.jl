module CiroJSON

using JSON
using Ciro.Types

"""
    json(data; status::Int=200) -> Response

Create a JSON response by serializing `data` to JSON.

Requires `using JSON` alongside `using Ciro` to activate this extension.

# Example
```julia
using Ciro, JSON
json(Dict("key" => "value"))
```
"""
function Types.json(data; status::Int=200)
    body_str = JSON.json(data)
    return Response(status, ["Content-Type" => "application/json"], Vector{UInt8}(body_str))
end

end
