-- Query-only traversal of a closed, same-file local callback collection.
local M = { MAX_FILES = 128, MAX_LOOPS = 128, MAX_TARGETS = 64, MAX_LINKS = 512 }
local control = require('codeoutline.control')
local iterators = { pairs = true, ipairs = true }
local function loop_header(T, i)
    return T:text(i) == 'for' and T.k[i + 1] == 'id' and T:text(i + 2) == ',' and T.k[i + 3] == 'id'
        and T:text(i + 4) == 'in' and iterators[T:text(i + 5)] and T:text(i + 6) == '('
        and T.k[i + 7] == 'id' and T:text(i + 8) == ')' and T:text(i + 9) == 'do'
end

function M.candidate(rec)
    if rec.language ~= 'lua' then return false end
    for _, name in ipairs(rec.dispatch_calls or {}) do if iterators[name] then return true end end
    return false
end

function M.tokens_candidate(T)
    for i = 1, T.n do
        if i % 4096 == 0 then control.check() end
        if loop_header(T, i) then return true end
    end
    return false
end

function M.collect(r, T, E)
    local result = { sites = {}, handled = {}, weight = 0 }
    r.lua_callback_loops = result
    local functions = {}
    for id, n in ipairs(r.nodes) do
        if n.kind == 'function' or n.kind == 'method' then
            for i = n.ti, n.tj do
                if T:text(i) == 'function' then functions[i] = id; break end
                if T:text(i) == '(' then break end
            end
        end
    end
    local function function_owner(scope)
        while scope and scope > 0 do
            if T:text(scope) == 'function' then return functions[scope] end
            scope = E.scopes[scope]
        end
    end
    local function root(b)
        for _ = 1, 9 do
            if not b then return nil end
            if b.slots then return b end
            b = b.alias and E.binding(b.alias, b.token - 1) or nil
        end
    end
    local collections, uses, wanted, count = {}, {}, {}, 0
    for i = 1, T.n do
        if i % 4096 == 0 then control.check() end
        if loop_header(T, i) then
            if count >= M.MAX_LOOPS then result.incomplete = true; break end
            count = count + 1
            local b = root(E.binding(T:text(i + 7), i + 7))
            if b then wanted[b] = true end
        end
    end
    local function target(at)
        local id = T.k[at] == 'id' and E.binding(T:text(at), at) and E.function_target(T:text(at), at)
        local n = id and r.nodes[id]
        return n and n['local'] and n.kind == 'function' and id or nil
    end
    local function entry(c, at, line)
        if c.invalid then return end
        if #c.entries >= M.MAX_TARGETS then c.invalid = true; result.incomplete = true; return end
        local id = target(at)
        if not id then c.invalid = true; return end
        c.entries[#c.entries + 1] = { index = id, token = at, line = T:line(line) }
    end
    for b in pairs(wanted) do
        local c = { binding = b, entries = {}, invalid = b.invalid }
        collections[b] = c
        for _, span in ipairs(E.parts(b.open + 1, T.m[b.open] - 1, ',')) do
            if span[1] ~= span[2] then c.invalid = true else entry(c, span[1], span[1]) end
        end
    end
    local poisoned = {}
    for i = 1, T.n do
        if i % 4096 == 0 then control.check() end
        local word = T:text(i)
        if word == '_ENV' or word == '_G' then poisoned.environment = true end
        -- Passing/aliasing the mutable library table can hide insert overrides.
        if word == 'table' and not E.binding(word, i) and T:text(i + 1) ~= '.' then poisoned.table = true end
        if (iterators[word] or word == 'table') and not E.binding(word, i)
            and (E.assignment_end(i) or T:text(i - 1) == 'function') then poisoned[word] = true end
    end
    -- Only direct two-argument table.insert calls in the collection's block.
    for i = 1, T.n do
        if i % 4096 == 0 then control.check() end
        if T:text(i) == 'table' and T:text(i + 1) == '.' and T:text(i + 2) == 'insert' and T:text(i + 3) == '('
            and T.k[i + 4] == 'id' then
            local b = E.binding(T:text(i + 4), i + 4)
            local c = collections[root(b)]
            if c then
                uses[i + 4] = true
                if E.binding('table', i) or poisoned.table or T:text(i + 5) ~= ',' or T.m[i + 3] ~= i + 7
                    or E.scopes[i] ~= c.binding.scope then c.invalid = true
                else entry(c, i + 6, i) end
            end
        end
    end
    local loops = {}
    for i = 1, T.n do
        if i % 4096 == 0 then control.check() end
        if loop_header(T, i) then
            local b = E.binding(T:text(i + 7), i + 7)
            local c = collections[root(b)]
            if c then uses[i + 7] = true end
            if #loops >= M.MAX_LOOPS then result.incomplete = true; break end
            loops[#loops + 1] = { collection = c, token = i, body = i + 9, value = i + 3,
                iterator = T:text(i + 5), valid = not E.binding(T:text(i + 5), i + 5) and not poisoned[T:text(i + 5)] }
        end
    end
    -- Reject escapes, unsupported writes/reads and invalid aliases of a collection.
    for i = 1, T.n do
        if i % 4096 == 0 then control.check() end
        if T.k[i] == 'id' then
            local b = E.binding(T:text(i), i)
            local c = collections[root(b)]
            if c then
                local alias = T:text(i - 3) == 'local' and T:text(i - 1) == '='
                    and T.k[i - 2] == 'id' and E.binding(T:text(i - 2), i - 2)
                local alias_use = alias and alias.alias == T:text(i) and root(alias) == c.binding
                if i ~= b.token and not uses[i] and not alias_use then c.invalid = true end
                local current, depth = b, 0
                while current do
                    if current.invalid or depth > 8 then c.invalid = true; break end
                    depth = depth + 1
                    current = current.alias and E.binding(current.alias, current.token - 1) or nil
                end
            end
        end
    end
    for _, loop in ipairs(loops) do
        local c, name = loop.collection, T:text(loop.value)
        local original = E.binding(name, loop.body)
        local last = E.ends[loop.body] or loop.body
        for ri, ref in ipairs(r.refs) do
            if ri % 128 == 0 then control.check() end
            if ref.kind == 'call' and ref.name == name and ref.tok > loop.body and ref.tok < last then
                local current = E.binding(name, ref.tok)
                if current == original or original and original.invalid then
                    result.handled[ri] = true; result.weight = result.weight + 32
                    if E.scopes[ref.tok] ~= loop.body or ref.from == 0
                        or function_owner(E.scopes[loop.body]) ~= ref.from then goto next_ref end
                    local site = { from = ref.from, line = ref.line, recv = name, iterator = loop.iterator, registrations = {} }
                    result.sites[#result.sites + 1] = site
                    if loop.valid and not poisoned.environment and c and not c.invalid and original and not original.invalid then
                        for _, registration in ipairs(c.entries) do
                            if registration.token < loop.token then
                                if #site.registrations >= M.MAX_TARGETS or result.weight >= M.MAX_LINKS * 512 then result.incomplete = true; break end
                                site.registrations[#site.registrations + 1] = registration; result.weight = result.weight + 512
                            end
                        end
                    end
                    if #result.sites >= M.MAX_LINKS then result.incomplete = true; return end
                end
            end
            ::next_ref::
        end
    end
end

function M.context(G, ctx, report)
    local C = { incomplete = false, stats = { files = 0, sites = 0, links = 0 } }
    local cache, empty = {}, { sites = {}, handled = {} }
    local function data(f)
        if cache[f] then return cache[f] end
        if not M.candidate(G.files[f]) then cache[f] = empty; return empty end
        if C.stats.files >= M.MAX_FILES then C.incomplete = true; cache[f] = empty; return empty end
        C.stats.files = C.stats.files + 1
        local found = ctx.ordinary.data(f).lua_callback_loops or { sites = {}, handled = {} }
        if found.incomplete then C.incomplete = true end
        C.stats.sites = C.stats.sites + #found.sites; cache[f] = found; return found
    end
    local function scan(f, only, wanted, out)
        for _, site in ipairs(data(f).sites) do
            local src, seen = G.id_of[f][site.from], {}
            if not only or src == only then
                for _, registration in ipairs(site.registrations) do
                    local id = G.id_of[f][registration.index]
                    if not seen[id] and (not wanted or wanted[id]) then
                        seen[id] = true; C.stats.links = C.stats.links + 1
                        out[src] = out[src] or {}; out[src][#out[src] + 1] = { target = id, line = site.line, kind = 'automatic:callback-loop' }
                        if report then report:add({ source = src, target = id, line = site.line, call = site.recv,
                            kind = 'possible callback traversal (same local collection and builtin ' .. site.iterator .. ')',
                            registered_at = G.files[f].path .. ':' .. registration.line }) end
                    end
                end
                if report and only and not next(seen) then report:add({ source = src, line = site.line, call = site.recv,
                    reason = 'callback collection is empty, mutated, escaped, shadowed or unsupported' }) end
            end
        end
    end
    function C.outgoing(id)
        local out = {}; scan(G.node_file[id], id, nil, out); return out[id] or {}
    end
    function C.incoming(wanted)
        local out, files = {}, {}
        for id in pairs(wanted) do local f = G.node_file[id]; if G.files[f].language == 'lua' then files[f] = true end end
        for f in pairs(files) do control.check(); scan(f, nil, wanted, out) end
        return out
    end
    function C.handles(f, i) return data(f).handled[i] == true end
    return C
end

return M
