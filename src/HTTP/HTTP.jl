"""
    HTTP

Transport-agnostic HTTP/1.1 layer: the byte-transport contract
(`AbstractIO`), response serialization, and (next slice) the per-connection
connection state machine. This module knows nothing about fds, io_uring, or
worker pools.
"""
module HTTP

using Dates: DateFormat, format, unix2datetime
using ..Interface
using ..Interface: Response, status, hasheader

export AbstractIO,
       io_read, io_write, io_on_write, io_shutdown, io_close, io_release, io_dispatch
export serialize_response!

include("io.jl")
include("serialize.jl")

end # module HTTP
