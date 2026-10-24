-- Include-driven admission of unknown suffixes from the normal file listing.
local paths = require('codeoutline.path')
local parse = require('codeoutline.parse')
local includes = require('codeoutline.cpp_includes')
local control = require('codeoutline.control')
local M = { MAX_FILES = 4096, MAX_BYTES = 67108864, MAX_DEPTH = 32 }
local function c_family(rec) return rec and (rec.language == 'c' or rec.language == 'cpp') end

function M.inventory(root)
    return { root = root, files = {}, file_index = {}, by_base = {}, count = 0 }
end

function M.policy_key(root)
    local policy = includes.context({ root = root })
    local parts = { tostring(policy.configured) }
    for _, dir in ipairs(policy.defaults) do parts[#parts + 1] = 'path:' .. dir end
    for _, rule in ipairs(policy.rules) do
        parts[#parts + 1] = 'rule:' .. rule.directory
        for _, dir in ipairs(rule.paths) do parts[#parts + 1] = 'path:' .. dir end
    end
    return table.concat(parts, '\0')
end

function M.add(G, rel)
    if parse.language(rel) then return end
    local key = paths.key(rel)
    if G.file_index[key] then return end
    G.count = G.count + 1
    G.files[rel] = { path = rel }
    G.file_index[rel], G.file_index[key] = rel, rel
    local base = rel:match('([^/]*)$')
    local key_base = paths.key(base)
    G.by_base[key_base] = G.by_base[key_base] or {}
    G.by_base[key_base][#G.by_base[key_base] + 1] = rel
    G.by_base[base] = G.by_base[key_base]
end

-- sync(batch, seen) uses the regular index loader and parse worker path.
-- Parents, macro environments and detailed bindings stay query-owned.
function M.refresh(idx, stats, seen, sync, changed)
    local G = idx.fragment_inventory
    if not G or G.count == 0 then return end
    local ctx, frontier = {}, {}
    for rel, rec in pairs(idx.files) do
        if seen[rel] and not rec.cpp_fragment and c_family(rec) then frontier[#frontier + 1] = rel end
    end
    table.sort(frontier)
    if #frontier == 0 then return end
    local admitted, canonical, count, bytes = {}, {}, 0, 0
    local function target(rel)
        local old = canonical[rel]
        if old ~= nil then return old or nil end
        local real = xutils.realpath(idx:abs(rel))
        local found
        if real and paths.contains(idx.root, real) then
            real = paths.normalize(real)
            local relative = real:sub(#idx.root + (idx.root:sub(-1) == '/' and 1 or 2))
            found = G.file_index[paths.key(relative)]
        end
        canonical[rel] = found or false
        return found
    end
    local function dependency(rel, imp)
        if parse.language(imp.path) then return end
        local ids = includes.resolve(G, rel, imp, ctx)
        if #ids == 1 then return target(ids[1]) end
    end
    local metadata = {}
    local function stat(rel)
        if metadata[rel] == nil then metadata[rel] = xutils.stat(idx:abs(rel)) or false end
        return metadata[rel] or nil
    end
    -- Settle C++ precedence through unchanged cached includes before loading a
    -- batch. Otherwise a shared fragment can flip C -> C++ on every refresh
    -- when the C++ includer is reached a round later than the C includer.
    local cpp_hints, queue, queued = {}, {}, {}
    for _, rel in ipairs(frontier) do
        queued[rel] = idx.files[rel].language == 'cpp'
        queue[#queue + 1] = { rel, queued[rel] }
    end
    local at, limit = 1, #queue + 2 * M.MAX_FILES
    while at <= #queue and at <= limit do
        control.check()
        local rel, cpp = queue[at][1], queue[at][2]
        local rec = idx.files[rel]; G.files[rel] = rec
        cpp = cpp or rec.cpp_fragment_cpp or false
        for _, imp in ipairs(rec.imports) do
            local p = dependency(rel, imp)
            if p then
                if cpp then cpp_hints[p] = true end
                local cached, st = idx.files[p], stat(p)
                if cached and cached.cpp_fragment and not (changed and changed[p]) and st
                    and cached.size == st.size and cached.mtime == st.mtime then
                    local mode = cpp or cached.cpp_fragment_cpp or false
                    if queued[p] == nil or mode and not queued[p] then
                        queued[p] = mode; queue[#queue + 1] = { p, mode }
                    end
                end
            end
        end
        at = at + 1
    end
    for depth = 1, M.MAX_DEPTH do
        local pending = {}
        for _, rel in ipairs(frontier) do
            control.check()
            local rec = idx.files[rel]
            G.files[rel] = rec
            for _, imp in ipairs(rec.imports) do
                local p = dependency(rel, imp)
                if p then
                    local desired = cpp_hints[p] and 'cpp' or rec.language
                    local language = pending[p] or admitted[p]
                    if not language or language == 'c' and desired == 'cpp' then pending[p] = desired end
                end
            end
        end
        local ordered = {}; for p in pairs(pending) do ordered[#ordered + 1] = p end
        table.sort(ordered)
        local batch = {}
        for _, p in ipairs(ordered) do
            local st = stat(p)
            if st and st.type == 'file' and st.size <= idx.max_bytes then
                if not admitted[p] and (count >= M.MAX_FILES or bytes + st.size > M.MAX_BYTES) then stats.fragment_limited = true
                else
                    if not admitted[p] then count, bytes = count + 1, bytes + st.size end
                    admitted[p] = pending[p]
                    batch[#batch + 1] = { rel = p, language = pending[p], stat = st }
                end
            end
        end
        if #batch == 0 then break end
        frontier = sync(batch, seen)
        table.sort(frontier)
        if #frontier == 0 then break end
        if depth == M.MAX_DEPTH then stats.fragment_limited = true end
    end
    local retained = 0
    for rel in pairs(admitted) do if seen[rel] then retained = retained + 1 end end
    stats.fragment_files = retained
end

return M
