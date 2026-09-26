# ══════════════════════════════════════════════════════════════════════════════
# Streaming responses — chunked bodies and Server-Sent Events
#
# A `Stream` is produced incrementally by a `Stream` body running on an
# async-executor worker. Bytes written to the `StreamWriter` are framed as
# HTTP/1.1 chunks (or sent raw when the user supplies a Content-Length) and
# flushed to the connection with backpressure.
# ══════════════════════════════════════════════════════════════════════════════

"""
    Stream(body; status=200, headers=Pair{String,String}[])

A response produced incrementally. `body` is called with a
[`StreamWriter`](@ref); each write becomes a response chunk. Only
`AsyncExecutor` can serve a `Stream`: a synchronous executor would block the
event loop for the whole body. Returning a `Stream` from a sync handler is an
error (500).

Prefer [`stream`](@ref) or [`sse`](@ref) over constructing this directly.
"""
struct Stream{F}
    status  :: Int
    headers :: Vector{Pair{String,String}}
    body    :: F
end

function Stream(body::F; status::Int=200,
                headers::AbstractVector{<:Pair}=Pair{String,String}[]) where {F}
    return Stream{F}(status,
                     Pair{String,String}[String(k) => String(v) for (k, v) in headers],
                     body)
end

"""
    stream(body; status=200, headers=..., content_type=nothing) -> Stream

Build a chunked streaming response. `body` receives a [`StreamWriter`](@ref)
and runs on an async-executor worker:

```julia
server = Server(; router, executor=AsyncExecutor())
get!(router, "/ticks", ctx -> stream() do w
    for i in 1:10
        println(w, "tick ", i)
        sleep(0.5)
    end
end)   # the response ends when `body` returns
```

`close(w)` ends the response early; writing after the client leaves throws
[`StreamClosedError`](@ref). If `headers` include `Content-Length`, bytes are
sent raw instead of chunked (the byte count is the caller's responsibility).
"""
function stream(body::F; status::Int=200,
                headers::AbstractVector{<:Pair}=Pair{String,String}[],
                content_type::Union{Nothing,AbstractString}=nothing) where {F}
    hs = Pair{String,String}[String(k) => String(v) for (k, v) in headers]
    content_type === nothing || pushfirst!(hs, "Content-Type" => String(content_type))
    return Stream{F}(status, hs, body)
end

"""
    StreamWriter <: IO

Write-only handle passed to a [`Stream`](@ref) body. Writes block until the
chunk is flushed to the socket, which provides backpressure; `close(w)` ends
the response. `print`/`println`/`write` work as on any `IO`.

Writing after the peer disconnected (or during shutdown) throws
[`StreamClosedError`](@ref), which unwinds the body and ends the stream.
"""
mutable struct StreamWriter <: IO
    send   :: Function   # (Vector{UInt8}) -> Bool
    finish :: Function   # () -> Nothing
    state  :: Symbol     # :open | :closed
end

"""Raised when writing to a [`StreamWriter`](@ref) whose peer is gone."""
struct StreamClosedError <: Exception end

Base.showerror(io::IO, ::StreamClosedError) =
    print(io, "stream closed: the client disconnected or the server is shutting down")

function Base.unsafe_write(w::StreamWriter, p::Ptr{UInt8}, n::UInt)::Int
    w.state === :closed && throw(StreamClosedError())
    n == 0 && return 0
    len = Int(n)
    bytes = Vector{UInt8}(undef, len)
    GC.@preserve bytes unsafe_copyto!(pointer(bytes), p, len)
    w.send(bytes) || throw(StreamClosedError())
    return len
end

function Base.close(w::StreamWriter)
    w.state === :closed && return
    w.state = :closed
    w.finish()
    return
end

Base.isopen(w::StreamWriter) = w.state === :open

"""
    SSESender

Callable passed to an [`sse`](@ref) body. `send(data; event=..., id=..., retry=...)`
writes one Server-Sent Event; `data` may contain newlines, each becoming its own
`data:` line.
"""
struct SSESender{W}
    io :: W
end

function (s::SSESender)(data::AbstractString;
                        event::Union{Nothing,AbstractString}=nothing,
                        id::Union{Nothing,AbstractString}=nothing,
                        retry::Union{Nothing,Integer}=nothing)
    buf = IOBuffer()
    id === nothing    || print(buf, "id: ", id, "\n")
    event === nothing || print(buf, "event: ", event, "\n")
    retry === nothing || print(buf, "retry: ", retry, "\n")
    for line in split(data, '\n')
        line = endswith(line, '\r') ? line[1:prevind(line, lastindex(line))] : line
        print(buf, "data: ", line, "\n")
    end
    print(buf, "\n")
    write(s.io, take!(buf))
    return nothing
end

"""
    sse(body; status=200, headers=...) -> Stream

Build a Server-Sent Events response (`Content-Type: text/event-stream`).
`body` receives an [`SSESender`](@ref):

```julia
get!(router, "/events", ctx -> sse() do send
    send("connected"; event="open")
    while true
        send("tick"; event="tick")
        sleep(1)
    end
end)
```
"""
function sse(body::F; status::Int=200,
             headers::AbstractVector{<:Pair}=Pair{String,String}[]) where {F}
    hs = Pair{String,String}[
        "Content-Type" => "text/event-stream",
        "Cache-Control" => "no-cache",
    ]
    for (k, v) in headers
        push!(hs, String(k) => String(v))
    end
    framed = w -> body(SSESender(w))
    return Stream(status, hs, framed)
end

export Stream, StreamWriter, StreamClosedError, stream, sse, SSESender
