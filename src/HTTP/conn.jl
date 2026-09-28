# ══════════════════════════════════════════════════════════════════════════════
# Per-connection HTTP state
#
# `HTTPConn` is transport-agnostic: `handle` is opaque to this module and is
# only ever passed back to the adapter (`io_*` methods). No fds, rings, or
# pools appear here.
# ══════════════════════════════════════════════════════════════════════════════

const _INITIAL_RBUF = 4096

mutable struct HTTPConn{H}
    handle      :: H
    rbuf        :: Vector{UInt8}
    rlen        :: Int
    hdr_scanned :: Int          # last_len progress for request-head parsing
    hbuf        :: HeaderBuffer
    decoder     :: ChunkedDecoder
    chunkbuf    :: Vector{UInt8}  # raw chunked bytes for the current decode call
    chunklen    :: Int
    fed         :: Int            # rbuf bytes already handed to the chunk decoder
    body        :: Vector{UInt8}  # decoded chunked body accumulator
    bodylen     :: Int
    carry       :: Vector{UInt8}  # bytes after a chunked message (next request)
    carrylen    :: Int
    phase       :: Symbol         # :headers | :body | :writing
    header_len  :: Int
    body_need   :: Int
    chunked     :: Bool
    close_after :: Bool
    deadline    :: Float64
    inflight    :: Symbol         # :none | :read | :write
    retired     :: Bool
    gen         :: UInt64         # bumped on reuse; stale async replies are dropped
    http11      :: Bool           # request minor_version >= 1
    stream_head :: Bool           # HEAD: stream body is suppressed
    stream_chunked :: Bool        # frame chunks (no Content-Length, HTTP/1.1)
    stream_final   :: Bool        # terminal chunk queued; finish on completion
    stream_ack     :: Union{Nothing, Channel{Bool}}
    captures       :: Vector{Pair{Symbol,UnitRange{Int}}}  # route-param scratch
    route          :: Union{Nothing,RouteResult}  # early route (per-route limits)
    t_method       :: UInt8       # telemetry: method of the current request
    t_path         :: String      # telemetry: request target, when captured
    t_start        :: Float64     # telemetry: first byte of the current request
    t_bytes        :: Int         # telemetry: response bytes so far (streams)
    t_status       :: Int         # telemetry: stream status
    t_reported     :: Bool        # telemetry: current response already reported
    t_streaming    :: Bool        # telemetry: an unfinished stream is open
end

HTTPConn(handle::H) where {H} =
    HTTPConn{H}(handle, Vector{UInt8}(undef, 0), 0, 0,
                HeaderBuffer(64), ChunkedDecoder(), Vector{UInt8}(undef, 0), 0, 0,
                Vector{UInt8}(undef, 0), 0, Vector{UInt8}(undef, 0), 0,
                :headers, 0, 0, false, false, 0.0, :none, false, 0,
                false, false, false, false, nothing,
                Pair{Symbol,UnitRange{Int}}[], nothing,
                UInt8(0), "", 0.0, 0, 0, false, false)

"""Reset every field for a new connection, reusing the allocated buffers."""
function http_reset!(st::HTTPConn)
    st.gen += 1
    st.rlen = 0
    st.hdr_scanned = 0
    st.chunklen = 0
    st.fed = 0
    st.bodylen = 0
    st.carrylen = 0
    resize!(st.rbuf, 0)
    resize!(st.chunkbuf, 0)
    resize!(st.body, 0)
    resize!(st.carry, 0)
    st.phase = :headers
    st.header_len = 0
    st.body_need = 0
    st.chunked = false
    st.close_after = false
    st.deadline = 0.0
    st.inflight = :none
    st.retired = false
    st.http11 = false
    st.stream_head = false
    st.stream_chunked = false
    st.stream_final = false
    st.stream_ack = nothing
    empty!(st.captures)
    st.route = nothing
    st.t_method = UInt8(0)
    st.t_path = ""
    st.t_start = 0.0
    st.t_bytes = 0
    st.t_status = 0
    st.t_reported = false
    st.t_streaming = false
    d = st.decoder
    d.bytes_left_in_chunk = 0
    d.consume_trailer = 1
    d._hex_count = 0
    d._state = 0
    d._total_read = 0
    d._total_overhead = 0
    return st
end
