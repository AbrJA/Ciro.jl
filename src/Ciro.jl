module Ciro

# Core types
include("types.jl")

# Query & body parsing
include("query.jl")
include("body.jl")

# Middleware (Logger, CORS, RequestId, Timing)
include("middleware.jl")

# Router (compile-time trie dispatch + route groups)
include("router.jl")

# Server (io_uring backend)
include("server.jl")

# Static file serving
include("static_files.jl")

# WebSocket protocol (RFC 6455)
include("websocket.jl")

# Multi-process clustering
include("cluster.jl")

# TLS support (OpenSSL)
include("tls.jl")

# HTTP/2 frames (h2c)
include("h2.jl")

# Cross-platform fallback
include("compat.jl")

# --- Re-export public API ---

using .Types
export Request, Response, text, json, html, Methods

using .QueryParsing
export query_params, clean_path, parse_query

using .BodyParsing
export body_string, body_bytes, parse_form

using .Middlewares
export Logger, CORS, cors, RequestId, Timing

using .Router
export @routes, dispatch, AbstractApp

using .Servers
export start_server, stop_server

using .StaticFiles
export static_handler, serve_file

using .WebSockets
export ws_upgrade, ws_encode_text, ws_encode_binary, ws_encode_close,
       ws_decode_frame, WSFrame, WS_TEXT, WS_BINARY

using .Clustering
export cluster_server

using .TLS
export TLSConfig

using .HTTP2
export H2Frame, h2_parse_frame, h2_encode_frame, h2_settings_frame,
       h2_data_frame, h2_headers_frame, h2_goaway_frame, is_h2_preface

using .Compat
export fallback_server

end
