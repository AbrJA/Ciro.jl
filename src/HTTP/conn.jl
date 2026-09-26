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
end

HTTPConn(handle::H) where {H} =
    HTTPConn{H}(handle, Vector{UInt8}(undef, 0), 0, 0,
                HeaderBuffer(64), ChunkedDecoder(), Vector{UInt8}(undef, 0), 0, 0,
                Vector{UInt8}(undef, 0), 0, Vector{UInt8}(undef, 0), 0,
                :headers, 0, 0, false, false, 0.0, :none, false, 0)

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
    d = st.decoder
    d.bytes_left_in_chunk = 0
    d.consume_trailer = 1
    d._hex_count = 0
    d._state = 0
    d._total_read = 0
    d._total_overhead = 0
    return st
end
