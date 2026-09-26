"""
    HTTP

Transport-agnostic HTTP/1.1 layer: the byte-transport contract (`AbstractIO`),
per-connection state, framing/limits/timeouts, pipelining, and response
serialization. This module knows nothing about fds, io_uring, or worker pools.
"""
module HTTP

using Dates: DateFormat, format, unix2datetime
import PicoHTTPParser
import ..Interface
using ..Interface
using ..Interface: Request, Response, status, hasheader, fail, Headers
using PicoHTTPParser: HeaderBuffer, ChunkedDecoder, decode_chunked!,
                      parse_request_head!, head_length, request_method,
                      request_target, minor_version, header_name, header_value,
                      content_length, HTTPParseError

export AbstractIO,
       io_config, io_running, io_read, io_acquire_buffer, io_write, io_on_write,
       io_shutdown, io_close, io_release, io_dispatch
export serialize_response!

include("config.jl")
include("io.jl")
include("conn.jl")
include("serialize.jl")
include("state.jl")

end # module HTTP
