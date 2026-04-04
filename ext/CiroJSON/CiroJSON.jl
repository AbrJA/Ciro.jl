module CiroJSON

using JSON
using Ciro.Types

function Types.json(data; status::Int=200)
    io = IOBuffer(; sizehint=256)
    JSON.print(io, data)
    return Response(status, ["Content-Type" => "application/json; charset=utf-8"], take!(io))
end

end
