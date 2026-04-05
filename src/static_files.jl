module StaticFiles

using ..Types

export static_handler, serve_file

const MIME_TYPES = Dict{String,String}(
    ".html"  => "text/html; charset=utf-8",
    ".htm"   => "text/html; charset=utf-8",
    ".css"   => "text/css; charset=utf-8",
    ".js"    => "application/javascript; charset=utf-8",
    ".mjs"   => "application/javascript; charset=utf-8",
    ".json"  => "application/json; charset=utf-8",
    ".xml"   => "application/xml; charset=utf-8",
    ".txt"   => "text/plain; charset=utf-8",
    ".csv"   => "text/csv; charset=utf-8",
    ".md"    => "text/markdown; charset=utf-8",
    ".png"   => "image/png",
    ".jpg"   => "image/jpeg",
    ".jpeg"  => "image/jpeg",
    ".gif"   => "image/gif",
    ".webp"  => "image/webp",
    ".svg"   => "image/svg+xml",
    ".ico"   => "image/x-icon",
    ".avif"  => "image/avif",
    ".woff"  => "font/woff",
    ".woff2" => "font/woff2",
    ".ttf"   => "font/ttf",
    ".otf"   => "font/otf",
    ".eot"   => "application/vnd.ms-fontobject",
    ".pdf"   => "application/pdf",
    ".zip"   => "application/zip",
    ".gz"    => "application/gzip",
    ".tar"   => "application/x-tar",
    ".wasm"  => "application/wasm",
    ".mp3"   => "audio/mpeg",
    ".mp4"   => "video/mp4",
    ".webm"  => "video/webm",
    ".ogg"   => "audio/ogg",
)

@inline function guess_mime(path::String)::String
    dot = findlast('.', path)
    dot === nothing && return "application/octet-stream"
    ext = lowercase(path[dot:end])
    return get(MIME_TYPES, ext, "application/octet-stream")
end

"""
    static_handler(root; prefix="/static", index="index.html", max_age=3600)

Return a middleware that serves static files from `root` directory
when the request path starts with `prefix`.

Falls through to `next` handler for non-matching or missing files.
"""
function static_handler(root::String; prefix::String="/static",
                        index::String="index.html", max_age::Int=3600)
    abs_root = abspath(root)
    cache_hdr = "public, max-age=$max_age"
    prefix_bytes = Vector{UInt8}(prefix)
    prefix_len = length(prefix_bytes)

    return function(req, next)
        path = String(req.path)
        # Strip query string
        qi = findfirst('?', path)
        qi !== nothing && (path = path[1:qi-1])

        startswith(path, prefix) || return next(req)

        rel = path[prefix_len+1:end]
        isempty(rel) || rel == "/" ? (rel = index) : (rel = lstrip(rel, '/'))

        file_path = normpath(joinpath(abs_root, rel))
        # Directory traversal protection
        startswith(file_path, abs_root) || return Response(403, "Forbidden")
        isfile(file_path) || return next(req)

        mime = guess_mime(file_path)
        data = read(file_path)
        return Response(200, [
            "Content-Type" => mime,
            "Cache-Control" => cache_hdr,
            "Content-Length" => string(length(data)),
        ], data)
    end
end

"""
    serve_file(root, req) -> Response

Serve a single file request from `root` directory using `req.path`.
"""
function serve_file(root::String, req)::Response
    abs_root = abspath(root)
    path = String(req.path)
    qi = findfirst('?', path)
    qi !== nothing && (path = path[1:qi-1])
    rel = lstrip(path, '/')
    isempty(rel) && (rel = "index.html")

    file_path = normpath(joinpath(abs_root, rel))
    startswith(file_path, abs_root) || return Response(403, "Forbidden")
    isfile(file_path) || return Response(404, "Not Found")

    mime = guess_mime(file_path)
    data = read(file_path)
    return Response(200, [
        "Content-Type" => mime,
        "Content-Length" => string(length(data)),
    ], data)
end

end
