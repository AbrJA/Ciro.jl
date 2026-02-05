module Tries

import Base: insert!
export RadixTrie, RouterTrie, insert!, lookup

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

struct RouterTrie
    get_trie::RadixTrie
    post_trie::RadixTrie
    put_trie::RadixTrie
    delete_trie::RadixTrie
    patch_trie::RadixTrie
    options_trie::RadixTrie
    head_trie::RadixTrie
end

function RouterTrie()
    RouterTrie(
        RadixTrie(), RadixTrie(), RadixTrie(),
        RadixTrie(), RadixTrie(), RadixTrie(), RadixTrie()
    )
end

function insert!(router::RouterTrie, method::AbstractString, path::AbstractString, handler::Function)
    trie = if method == "GET"
        router.get_trie
    elseif method == "POST"
        router.post_trie
    elseif method == "PUT"
        router.put_trie
    elseif method == "DELETE"
        router.delete_trie
    elseif method == "PATCH"
        router.patch_trie
    elseif method == "OPTIONS"
        router.options_trie
    elseif method == "HEAD"
        router.head_trie
    else
        error("Unsupported method: $method")
    end

    insert!(trie, path, handler)
end

function insert!(trie::RadixTrie, path::AbstractString, handler::Function)
    # Split path
    parts = split(strip(path, '/'), '/')
    if path == "/"
        parts = [""]
    end

    node = trie.root
    for part in parts
        if isempty(part)
            continue
        end

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

function lookup(router::RouterTrie, method::AbstractString, path::AbstractString)
    trie = if method == "GET"
        router.get_trie
    elseif method == "POST"
        router.post_trie
    elseif method == "PUT"
        router.put_trie
    elseif method == "DELETE"
        router.delete_trie
    elseif method == "PATCH"
        router.patch_trie
    elseif method == "OPTIONS"
        router.options_trie
    elseif method == "HEAD"
        router.head_trie
    else
        return nothing, Dict{String,String}()
    end

    return lookup(trie, path)
end

function lookup(trie::RadixTrie, path::AbstractString)
    node = trie.root
    params = Dict{String,String}()

    len = lastindex(path)
    i = firstindex(path)

    while i <= len
        if path[i] == '/'
            i = nextind(path, i)
            continue
        end

        start_idx = i
        end_idx = i
        found_sep = false

        # Scan for separator
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
                    key = child.part[2:end]
                    params[key] = String(part)
                    break
                end
            end
        end

        if found === nothing
            return nothing, Dict{String,String}()
        end

        node = found

        if found_sep
            i = nextind(path, end_idx)
            i = nextind(path, i) # Skip '/'
        end
    end

    return node.handler, params
end

end
