# ══════════════════════════════════════════════════════════════════════════════
# HTTPConfig — HTTP-level limits and deadlines
#
# Validated by the Server at construction; the HTTP layer only reads it.
# ══════════════════════════════════════════════════════════════════════════════

"""
    HTTPConfig

Limits and deadlines the HTTP layer enforces. Immutable; built once by the
`Server` (which validates it) and exposed to the state machine through
`io_config(io)`.
"""
struct HTTPConfig
    max_header_bytes  :: Int
    max_body_size     :: Int
    header_timeout_ms :: Int
    body_timeout_ms   :: Int
    idle_timeout_ms   :: Int
end
