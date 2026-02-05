module Tries

import Base: insert!
export RadixTrie, insert!, lookup

mutable struct TrieNode
    part::String
    children::Vector{TrieNode}
    is_param::Bool
    handler::Union{Function,Nothing}
end

function TrieNode(part::AbstractString="", is_param::Bool=false)
    return TrieNode(part, TrieNode[], is_param, nothing)
end

struct RadixTrie
    root::TrieNode
end

function RadixTrie()
    return RadixTrie(TrieNode("", false))
end

function insert!(trie::RadixTrie, method::AbstractString, path::AbstractString, handler::Function)
    # Combine method and path? Or have separate trees?
    # Let's route on path first, then check method, or compound key.
    # Standard way: Method mapping in the leaf, or just treat "METHOD /path" as the string to route.
    # Let's simple: use path, store helper map in leaf?
    # Or, insert "METHOD" + "PATH"?
    # Let's simplify: The trie will store "PATH" parts. The leaf will hold a Dict{Method, Handler}.
    # But for now, let's just make the key "METHOD/path/..." effectively.
    # Actually, simpler: Split path by '/'. First part could be Method if we want.
    # Let's stick to Path routing, and leaf stores the handler for specific method.
    # Or just keep it simple: insert!(trie, ["GET", "user", ":id"], handler)

    parts = split(strip(path, '/'), '/')
    if path == "/"
        parts = [""]
    end
    # Prepend method to parts for unique routing per method
    # parts = [method; parts]
    # Use explicit method node at root?

    # Let's just traverse.
    node = trie.root

    # We want to support Method + Path.
    # Let's make the first part the Method.
    full_parts = AbstractString[method]
    append!(full_parts, parts)

    for part in full_parts
        if isempty(part)
            continue
        end

        # Find child
        found = nothing
        for child in node.children
            if child.part == part
                found = child
                break
            end
        end

        if found === nothing
            is_param = startswith(part, ":")
            new_node = TrieNode(part, is_param)
            push!(node.children, new_node)
            node = new_node
        else
            node = found
        end
    end

    node.handler = handler
end

function lookup(trie::RadixTrie, method::AbstractString, path::AbstractString)
    node = trie.root
    params = Dict{String,String}()

    # 1. Match Method (First layer)
    found_method = nothing
    for child in node.children
        if child.part == method
            found_method = child
            break
        end
    end

    if found_method === nothing
        # Method not found (and we assume method is never a param for now, or fallback)
        return nothing, Dict{String,String}()
    end
    node = found_method

    # 2. Iterate Path
    # We iterate manually to avoid 'split' allocation
    len = lastindex(path)
    i = firstindex(path)

    while i <= len
        # Skip slashes
        if path[i] == '/'
            i = nextind(path, i)
            continue
        end

        # Find end of this segment
        # We can't use findnext easily with AbstractString/StringView in a generic way that is zero-alloc
        # if the underlying type doesn't support optimized search.
        # But 'findnext' on StringView should be fine?
        # Let's simple loop until '/' or end.
        start_idx = i
        end_idx = i

        # Scan for separator
        found_sep = false
        while i <= len
            c = path[i]
            if c == '/'
                end_idx = prevind(path, i)
                found_sep = true
                break
            end
            end_idx = i
            i = nextind(path, i)
        end

        # Current segment is path[start_idx:end_idx]
        # We use a view to avoid allocation
        part = view(path, start_idx:end_idx)

        # Match Part
        found = nothing
        # A. Exact Match
        for child in node.children
            if child.part == part
                found = child
                break
            end
        end

        # B. Param Match
        if found === nothing
            for child in node.children
                if child.is_param
                    found = child
                    # Extract param
                    key = child.part[2:end] # remove ':'
                    # verify implicit conversion or keep as SubString
                    params[key] = String(part) # Allocate only when storing param (unavoidable for Dict{String,String})
                    break
                end
            end
        end

        if found === nothing
            return nothing, Dict{String,String}()
        end

        node = found

        if found_sep
            i = nextind(path, end_idx) # Move past the last char we read
            # Actually our outer loop 'i' is already at the '/' because of the inner while loop break
            # just need to advance past '/'
            i = nextind(path, i)
        end
    end

    return node.handler, params
end

end
