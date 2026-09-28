"""
    Interface

Core abstractions for the Ciro web framework.

All concrete types are defined here so that downstream modules get a single,
type-stable contract. Extension points use abstract types + function stubs.
"""
module Interface

import PicoHTTPParser

include("request_type.jl")
export Request

include("context.jl")
include("endpoint.jl")
include("methods.jl")
include("response.jl")
include("stream.jl")
include("types.jl")
include("telemetry.jl")
include("request.jl")

end # module Interface
