module TLS

export TLSConfig

"""
    TLSConfig(certfile, keyfile; [options...])

TLS configuration for HTTPS support.

Pass to `start_server` to enable TLS:

```julia
tls = TLSConfig("cert.pem", "key.pem")
start_server(App(), 8443; tls=tls)
```

Requires OpenSSL (`libssl.so`) on the system.
"""
struct TLSConfig
    certfile::String
    keyfile::String
    protocols::UInt32  # bitmask: TLS 1.2 = 0x1, TLS 1.3 = 0x2
end

function TLSConfig(certfile::String, keyfile::String;
                   tls12::Bool=true, tls13::Bool=true)
    isfile(certfile) || error("TLS certificate file not found: $certfile")
    isfile(keyfile)  || error("TLS key file not found: $keyfile")
    proto = UInt32(0)
    tls12 && (proto |= 0x1)
    tls13 && (proto |= 0x2)
    return TLSConfig(certfile, keyfile, proto)
end

# --- OpenSSL C Bindings ---

const libssl = "libssl.so"
const libcrypto = "libcrypto.so"

const SSL_FILETYPE_PEM = Cint(1)

# These functions are called from the C layer or server integration
# They wrap OpenSSL's libssl for TLS socket operations

function ssl_ctx_new()
    method = ccall((:TLS_server_method, libssl), Ptr{Cvoid}, ())
    ctx = ccall((:SSL_CTX_new, libssl), Ptr{Cvoid}, (Ptr{Cvoid},), method)
    ctx == C_NULL && error("SSL_CTX_new failed")
    return ctx
end

function ssl_ctx_use_certificate!(ctx::Ptr{Cvoid}, certfile::String)
    ret = ccall((:SSL_CTX_use_certificate_chain_file, libssl), Cint,
                (Ptr{Cvoid}, Cstring), ctx, certfile)
    ret != 1 && error("Failed to load TLS certificate: $certfile")
end

function ssl_ctx_use_key!(ctx::Ptr{Cvoid}, keyfile::String)
    ret = ccall((:SSL_CTX_use_PrivateKey_file, libssl), Cint,
                (Ptr{Cvoid}, Cstring, Cint), ctx, keyfile, SSL_FILETYPE_PEM)
    ret != 1 && error("Failed to load TLS private key: $keyfile")
end

function ssl_ctx_check_key(ctx::Ptr{Cvoid})
    ret = ccall((:SSL_CTX_check_private_key, libssl), Cint, (Ptr{Cvoid},), ctx)
    ret != 1 && error("TLS private key does not match certificate")
end

function ssl_ctx_free(ctx::Ptr{Cvoid})
    ccall((:SSL_CTX_free, libssl), Cvoid, (Ptr{Cvoid},), ctx)
end

function ssl_new(ctx::Ptr{Cvoid})
    ssl = ccall((:SSL_new, libssl), Ptr{Cvoid}, (Ptr{Cvoid},), ctx)
    ssl == C_NULL && error("SSL_new failed")
    return ssl
end

function ssl_set_fd!(ssl::Ptr{Cvoid}, fd::Cint)
    ccall((:SSL_set_fd, libssl), Cint, (Ptr{Cvoid}, Cint), ssl, fd)
end

function ssl_accept(ssl::Ptr{Cvoid})::Cint
    return ccall((:SSL_accept, libssl), Cint, (Ptr{Cvoid},), ssl)
end

function ssl_read(ssl::Ptr{Cvoid}, buf::Ptr{UInt8}, len::Cint)::Cint
    return ccall((:SSL_read, libssl), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Cint), ssl, buf, len)
end

function ssl_write(ssl::Ptr{Cvoid}, buf::Ptr{UInt8}, len::Cint)::Cint
    return ccall((:SSL_write, libssl), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Cint), ssl, buf, len)
end

function ssl_shutdown(ssl::Ptr{Cvoid})
    ccall((:SSL_shutdown, libssl), Cint, (Ptr{Cvoid},), ssl)
end

function ssl_free(ssl::Ptr{Cvoid})
    ccall((:SSL_free, libssl), Cvoid, (Ptr{Cvoid},), ssl)
end

"""
    create_ssl_context(config::TLSConfig) -> Ptr{Cvoid}

Create and configure an OpenSSL SSL_CTX from a TLSConfig.
"""
function create_ssl_context(config::TLSConfig)::Ptr{Cvoid}
    ctx = ssl_ctx_new()
    try
        ssl_ctx_use_certificate!(ctx, config.certfile)
        ssl_ctx_use_key!(ctx, config.keyfile)
        ssl_ctx_check_key(ctx)
    catch
        ssl_ctx_free(ctx)
        rethrow()
    end
    return ctx
end

end
