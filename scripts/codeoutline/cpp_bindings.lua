-- Bounded declared receiver types. Source evidence is compact; lookup uses the
-- same symbol tables and include visibility as ordinary graph queries.
local M = {}
local control = require('codeoutline.control')
local types = { class = true, struct = true, union = true }
local qualifiers = { const = true, volatile = true, static = true, mutable = true, struct = true, class = true }
local boundary = { [';'] = true, ['{'] = true, ['}'] = true, ['('] = true, [','] = true, [':'] = true }
local primitive = { auto = true, int = true, double = true, float = true, char = true, bool = true,
    long = true, short = true, unsigned = true, signed = true, void = true }

function M.collect(r, T)
    if r.language ~= 'cpp' and r.language ~= 'c' then return end
    require('codeoutline.cpp_types').collect(r, T)
    local wanted = {}
    for _, ref in ipairs(r.refs) do
        if ref.kind == 'type' and not ref.recv then wanted[ref.name] = true
        elseif r.language == 'c' then -- ordinary C call resolution is unchanged
        elseif ref.kind == 'call' or ref.kind == 'ref' or ref.kind == 'member_call' and T:text(ref.tok - 1) == '::' then
            if T:text(ref.tok) == ref.name then
                ref.binding = require('codeoutline.cpp_types').evidence(T, ref.tok)
                r.has_bindings = true
                if ref.kind == 'call' or ref.kind == 'ref' then wanted[ref.name] = true end
            end
        elseif ref.kind == 'member_call' and ref.recv and ref.recv ~= 'this' then wanted[ref.recv] = true end
    end
    if not next(wanted) then return end
    r.has_bindings = true
    local scopes, stack = {}, {}
    for i = 1, T.n do
        if T:text(i) == '{' and T.m[i] then stack[#stack + 1] = i end
        scopes[i] = stack[#stack] or 0
        if stack[#stack] and T.m[stack[#stack]] == i then stack[#stack] = nil end
    end
    local bindings = {}
    for i = 1, T.n do
        if i % 4096 == 0 then control.check() end
        if T.k[i] == 'id' and wanted[T:text(i)] then
            local after = T:text(i + 1)
            if after == ')' or after == ',' or after == ';' or after == '=' or after == '{' then
                local j = i - 1
                while T:text(j) == '*' or T:text(j) == '&' or T:text(j) == '&&' or qualifiers[T:text(j)] do j = j - 1 end
                if T.k[j] == 'id' or primitive[T:text(j)] then
                    local ty = T:text(j)
                    j = j - 1
                    while T:text(j) == '::' and T.k[j - 1] == 'id' do
                        ty = T:text(j - 1) .. '::' .. ty; j = j - 2
                    end
                    if T:text(j) == '::' then ty = '::' .. ty; j = j - 1 end
                    while qualifiers[T:text(j)] do j = j - 1 end
                    while primitive[T:text(j)] do j = j - 1 end
                    if j == 0 or boundary[T:text(j)] then
                        local a = scopes[i]
                        local b = a > 0 and T.m[a] or T.n
                        for _, n in ipairs(r.nodes) do
                            if (n.kind == 'function' or n.kind == 'method' or n.kind == 'constructor')
                                and n.ti <= i and i <= n.tj and n.ti > a then a, b = n.ti, n.tj end
                        end
                        bindings[T:text(i)] = bindings[T:text(i)] or {}
                        bindings[T:text(i)][#bindings[T:text(i)] + 1] = { token = i, a = a, b = b, type = ty }
                    end
                end
            end
        end
    end
    for _, ref in ipairs(r.refs) do
        local bare = (r.language == 'cpp' and (ref.kind == 'call' or ref.kind == 'ref')) or ref.kind == 'type' and not ref.recv
        if bare or ref.kind == 'member_call' and ref.recv and T:text(ref.tok - 1) ~= '::' then
            local best
            for _, b in ipairs(bindings[bare and ref.name or ref.recv] or {}) do
                if b.a <= ref.tok and ref.tok <= b.b and b.token < ref.tok
                    and (not best or b.a > best.a or b.a == best.a and b.token > best.token) then best = b end
            end
            if best then
                if ref.kind == 'type' then ref.type_use.value_shadowed = true
                else ref.binding = bare and 'cpp:?' or 'cpp:type:' .. best.type .. '\0' .. (T.s[best.token] - 1) end
                -- A chain's tail is not the simple local sharing that name.
                if T:text(ref.tok - 3) == '.' or T:text(ref.tok - 3) == '->' then ref.binding = 'cpp:?' end
            end
        end
    end
end

function M.resolve(G, f, src, name, evidence, deps, ctx, accept)
    if G.files[f].language ~= 'cpp' or not evidence or evidence:sub(1, 4) ~= 'cpp:' then return nil end
    local written, position = evidence:match('^cpp:name:(.-)%z(%d+)$')
    if written then
        local scope = src and G.nodes[src].qualified
        if src and (G.nodes[src].kind == 'function' or G.nodes[src].kind == 'method') then scope = scope:match('^(.*)::[^:]+$') end
        local ids, known = require('codeoutline.cpp_types').resolve(G, f, written,
            { scope = scope, at = tonumber(position), deps = deps, context = ctx, accept = accept, definitions = true })
        return ids, not known and 'unresolved c++ name' or nil
    end
    local ty = evidence:match('^cpp:type:(.+)$')
    if not ty then return {} end
    local written, at = ty:match('^(.-)%z(%d+)$')
    ty = written or ty
    local function classes(written, scope, file, position)
        return require('codeoutline.cpp_types').resolve(G, file or f, written,
            { scope = scope, at = position, deps = deps, context = ctx })
    end
    local scope = src and G.nodes[src].qualified:match('^(.*)::[^:]+$')
    local result, seen, emitted = {}, {}, {}
    local definition_owners = {}
    local configured = require('codeoutline.cpp_includes').policy(G, f, ctx).configured
    local function belongs(id, cls)
        if definition_owners[id] == nil then
            definition_owners[id] = require('codeoutline.cpp_types').owner(G, G.node_file[id], G.nodes[id], ctx) or false
        end
        if definition_owners[id] == cls then return true end
        -- Keep legacy class-outside hints when there is no configured policy
        -- and the defining file provides no class evidence (e.g. forced includes).
        local node = G.nodes[id]
        local parent = node.parent and G.files[G.node_file[id]].nodes[node.parent]
        return not configured and definition_owners[id] == false and (not parent or not types[parent.kind])
    end
    local function members(cls, depth)
        control.check()
        if seen[cls] or depth > 8 then return end
        seen[cls] = true
        local q = G.nodes[cls].qualified .. '::' .. name
        local matches, has_definition = {}, false
        for _, id in ipairs(G.by_name[name] or {}) do
            local n = G.nodes[id]
            if n.qualified == q and G.files[G.node_file[id]].language == 'cpp'
                and belongs(id, cls) then
                matches[#matches + 1] = id
                if not n.decl and n.kind ~= 'prototype' then has_definition = true end
            end
        end
        for _, id in ipairs(matches) do
            local n = G.nodes[id]
            if not emitted[id] and (not has_definition or not n.decl and n.kind ~= 'prototype') then
                emitted[id] = true; result[#result + 1] = id
            end
        end
        if #matches == 0 then
            for _, base in ipairs(G.nodes[cls].bases or {}) do
                for _, id in ipairs(classes(base, G.nodes[cls].qualified:match('^(.*)::[^:]+$'), G.node_file[cls])) do members(id, depth + 1) end
            end
        end
    end
    for _, cls in ipairs(classes(ty, scope, f, tonumber(at))) do members(cls, 0) end
    return result
end

return M
