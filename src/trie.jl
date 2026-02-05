module Tries

import Base: insert!
export RadixTrie, insert!, lookup

mutable struct TrieNode
    part::String
    children::Vector{TrieNode}
    is_param::Bool
    handler::Union{Function,Nothing}
end

function TrieNode(part::String="", is_param::Bool=false)
    return TrieNode(part, TrieNode[], is_param, nothing)
end

struct RadixTrie
    root::TrieNode
end

function RadixTrie()
    return RadixTrie(TrieNode("", false))
end

function insert!(trie::RadixTrie, method::String, path::String, handler::Function)
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
    full_parts = [method]
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

function lookup(trie::RadixTrie, method::String, path::String)
    parts = split(strip(path, '/'), '/')
    if path == "/"
        parts = [""]
    end

    full_parts = [method]
    append!(full_parts, parts)

    node = trie.root
    params = Dict{String,String}()

    for part in full_parts
        if isempty(part)
            continue
        end

        found = nothing
        # 1. Exact match
        for child in node.children
            if child.part == part
                found = child
                break
            end
        end

        # 2. Param match
        if found === nothing
            for child in node.children
                if child.is_param
                    found = child
                    # Extract param
                    key = child.part[2:end] # remove ':'
                    params[key] = part
                    break
                end
            end
        end

        if found === nothing
            return nothing, Dict{String,String}()
        end

        node = found
    end

    return node.handler, params
end

end
