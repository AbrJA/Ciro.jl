"""
    Interface

Core abstractions for the Ciro web framework.

All concrete types are defined here so that downstream modules get a single,
type-stable contract. Extension points use abstract types + function stubs.
"""
module Interface

using PicoHTTPParser

const Request = PicoHTTPParser.Request
export Request

include("context.jl")
include("methods.jl")
include("response.jl")
include("types.jl")
include("request.jl")

end # module Interface
