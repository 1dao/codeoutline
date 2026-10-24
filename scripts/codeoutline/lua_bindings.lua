-- Static Lua module return bindings. Never execute indexed source.
local M = {}
local control = require('codeoutline.control')
local loaders = { require = true, dofile = true, loadfile = true }
local EXPORT_OWNER = '__exports'
-- Loader call at token j: a known loader name, or any dotted/plain name whose
-- last segment ends in `import` (`ks.import`, `skynet_import`). Returns the
-- kind recorded in lua_imports, the callee's last token, and the base name
-- used for shadow checks.
local function loader_call(T, j)
    if T.k[j] ~= 'id' then return nil end
    local k = j
    while T.k[k + 1] == 'op' and T:text(k + 1) == '.' and T.k[k + 2] == 'id' do k = k + 2 end
    local name = T:text(k)
    if k == j and loaders[name] then return name, k, name end
    if name:sub(-6) ~= 'import' then return nil end
    local parts = {}
    for x = j, k, 2 do parts[#parts + 1] = T:text(x) end
    return table.concat(parts, '.'), k, T:text(j)
end
local function literal(T, i)
    if T.k[i] ~= 'str' then return nil end
    local s = T:text(i)
    local long = s:match('^%[(=*)%[')
    if long then return s:sub(#long + 3, -#long - 3):gsub('^\r?\n', '', 1) end
    if s:find('\\', 1, true) then return nil end
    return s:sub(2, -2)
end

local function value_end(T, i)
    local tail = T:text(i)
    return (T.k[i] ~= 'op' or tail == ';' or tail == ',') and tail ~= 'and' and tail ~= 'or'
end

-- Shared lexical table-member lookup for normal references and query-only
-- configured callback aliases. Results are local parser node indices.
function M.local_members(nodes, scopes, name, token, scope, finish)
    local members = {}
    for index, n in ipairs(nodes) do
        if n.ti >= token and n.ti <= finish and scopes[n.ti] == scope
            and (n.qualified == name .. '.' .. n.name or n.qualified == name .. ':' .. n.name) then
            members[n.name] = index
        end
    end
    return members
end

function M.collect(r, T, bm)
    r.lua_imports, r.lua_exports, r.lua_locals = {}, {}, {}
    local scopes, stack, params, bindings, function_scopes = {}, {}, {}, {}, {}
    for i = 1, T.n do
        if stack[#stack] and bm[stack[#stack]] == i then stack[#stack] = nil end
        scopes[i] = stack[#stack] or 0
        if bm[i] and bm[i] > i then
            function_scopes[i] = T:text(i) == 'function' or function_scopes[scopes[i]]
            stack[#stack + 1] = i
        end
        if T:text(i) == 'function' and T.k[i] == 'kw' then
            local p = i + 1
            while p < (bm[i] or i) and T:text(p) ~= '(' do p = p + 1 end
            for j = p + 1, (T.m[p] or p) - 1 do if T.k[j] == 'id' then params[j] = i end end
        end
    end
    local function add(name, token, scope, hint, imported)
        bindings[name] = bindings[name] or {}
        -- Reassignment/parameter shadowing must not revive a global name
        -- after a loader value was bound under this lexical name.
        if hint == '?' and not imported and T:text(token + 2) ~= 'function' then
            for _, b in ipairs(bindings[name]) do
                if b.imported and b.token < token and b.a <= token and b.b >= token then imported = true end
            end
        end
        bindings[name][#bindings[name] + 1] = { token = token, a = scope, b = bm[scope] or T.n, hint = hint, imported = imported }
    end
    for i = 1, T.n do
        if i % 4096 == 0 then control.check() end
        if T.k[i] == 'id' then
            local prev, next = T:text(i - 1), T:text(i + 1)
            if params[i] then add(T:text(i), i, params[i], '?')
            elseif prev == 'function' and T:text(i - 2) == 'local' then add(T:text(i), i, scopes[i - 2], '')
            elseif prev == 'local' or (next == '=' and prev ~= '.' and prev ~= ':' and prev ~= '{' and prev ~= ',') then
                local hint = '?'
                if next == '=' and T:text(i + 2) == '{' then hint = 'lua-local:' .. T:text(i) end
                local kind, call, base
                if next == '=' then kind, call, base = loader_call(T, i + 2) end
                local imported = kind ~= nil
                if kind then
                    local arg = T:text(call + 1) == '(' and call + 2 or call + 1
                    local path = literal(T, arg)
                    local close = T:text(call + 1) == '(' and T.m[call + 1] or arg
                    if close and ((close == arg) or (close == arg + 1)
                        or (close > arg and T:text(arg + 1) == ',')) and path then
                        local member = T:text(close + 1) == '.' and T.k[close + 2] == 'id' and close + 2
                        -- One selected member is a value alias. Calls, nested
                        -- selectors and operations produce a different value.
                        if value_end(T, (member or close) + 1) then
                            local shadowed = false
                            for _, b in ipairs(bindings[base] or {}) do
                                if b.token < call and b.a <= call and b.b >= call then shadowed = true end
                            end
                            if not shadowed then
                                r.lua_imports[#r.lua_imports + 1] = { path = path, kind = kind,
                                    member = member and T:text(member) or nil }
                                hint = (member and 'lua-value:' or 'lua:') .. #r.lua_imports
                                if kind == 'loadfile' then hint = '?' end
                                if member and kind ~= 'loadfile' then
                                    r.refs[#r.refs + 1] = { tok = member, name = T:text(member), kind = 'ref',
                                        line = T:line(member), lua_binding = hint }
                                end
                            end
                        end
                    end
                end
                -- Keep ordinary local function/table lookup; block unknown imported receivers.
                add(T:text(i), i, scopes[i], hint, imported)
            end
        end
    end
    -- Query-only lexical bindings travel with the cached tokens, not the index.
    T.lua_bindings = bindings
    for name, list in pairs(bindings) do
        for _, b in ipairs(list) do
            if b.hint:match('^lua%-local:') then
                local members = M.local_members(r.nodes, scopes, name, b.token, b.a, b.b)
                r.lua_locals[#r.lua_locals + 1] = members
                b.hint = 'lua-local:' .. #r.lua_locals
            end
        end
    end
    for _, ref in ipairs(r.refs) do
        if not ref.lua_binding then
            local best
            for _, b in ipairs(bindings[ref.recv or ref.name] or {}) do
                if b.token <= ref.tok and b.a <= ref.tok and b.b >= ref.tok
                    and (not best or b.a > best.a or (b.a == best.a and b.token > best.token)) then best = b end
            end
            if best and (ref.recv or best.imported) then
                local value = best.hint:match('^lua%-value:')
                ref.lua_binding = value and (not ref.recv and best.hint or '?') or (ref.recv and best.hint or '?')
            end
            if ref.recv and (T:text(ref.tok - 3) == '.' or T:text(ref.tok - 3) == ':') then ref.lua_binding = '?' end
        end
    end

    local function alias(into, key, target, token)
        local bound
        if token then
            for _, b in ipairs(bindings[target] or {}) do
                if b.token <= token and b.a <= token and b.b >= token
                    and (not bound or b.a > bound.a or b.a == bound.a and b.token > bound.token) then bound = b end
            end
        end
        for index, n in ipairs(r.nodes) do
            local scope = scopes[n.ti]
            local visible = not token or n.ti < token and (bound
                and bound.token >= n.ti and bound.token <= n.tj and bound.a == scope
                or not bound and (scope == 0 or scope <= token and bm[scope] >= token))
            if visible and not n.parent and n.name == target and n.qualified == target and (n.kind == 'function' or n.kind == 'method') then
                into[key] = index
            end
        end
    end
    -- A global alias is a statement of its own: the right-hand side is a bare
    -- identifier and nothing but a separator follows it on that line. The key
    -- is dotted (`g_exports.name`) or a literal (`g_exports['name']`).
    local globals, definitions = {}, {}
    for index, n in ipairs(r.nodes) do
        local owner, key = n.qualified:match('^([%a_][%w_]*)[.:]([%a_][%w_]*)$')
        if owner and not bindings[owner] and not n.parent and (n.kind == 'function' or n.kind == 'method') then
            definitions[n.ti] = { owner = owner, key = key, index = index }
        end
    end
    for i = 1, T.n - 4 do
        if i % 4096 == 0 then control.check() end
        local owner = T:text(i)
        if T.k[i] == 'id' and not bindings[owner] and T:text(i - 1) ~= '.' and T:text(i - 1) ~= ':' then
            local key, eq
            if T:text(i + 1) == '.' and T.k[i + 2] == 'id' then key, eq = T:text(i + 2), i + 3
            elseif T:text(i + 1) == '[' and T.m[i + 1] == i + 3 and T.k[i + 2] == 'str' then key, eq = literal(T, i + 2), i + 4 end
            local target = key and T:text(eq) == '=' and T.k[eq + 1] == 'id' and T:text(eq + 1)
            if key and T:text(eq) == '=' then
                globals[owner] = globals[owner] or {}
                globals[owner][key] = nil
            end
            if target and value_end(T, eq + 2) and (T.l[eq + 2] ~= T.l[eq + 1] or T:text(eq + 2) == ';') then
                alias(globals[owner], key, target, eq + 1)
            end
        end
        -- Direct definitions participate in the same ordered overwrite rules
        -- as named aliases, without requiring another name-index entry.
        local definition = definitions[i]
        if definition then
            globals[definition.owner] = globals[definition.owner] or {}
            globals[definition.owner][definition.key] = definition.index
        end
    end
    -- Keep candidates independent of project configuration, including in caches.
    for owner, exports in pairs(globals) do
        for name, index in pairs(exports) do
            local node = r.nodes[index]
            node.lua_aliases = node.lua_aliases or {}
            node.lua_aliases[owner] = node.lua_aliases[owner] or {}
            node.lua_aliases[owner][#node.lua_aliases[owner] + 1] = name
        end
    end
    -- A single unconditional top-level return is the supported module contract.
    -- Files with no module-level return may use the `__exports` contract below;
    -- conditional or multiple returns invalidate both contracts. Function depth
    -- comes from token blocks, so returns inside anonymous callbacks (which are
    -- not nodes) do not pose as module-level returns.
    local fn_close, depth = {}, 0
    for i = 1, T.n do
        if T.k[i] == 'kw' and T:text(i) == 'function' and bm[i] then fn_close[bm[i]] = true end
    end
    local ret
    for i = 1, T.n do
        if T.k[i] == 'kw' and T:text(i) == 'function' then depth = depth + 1 end
        if T:text(i) == 'return' and T.k[i] == 'kw' and depth == 0 then
            if ret or scopes[i] ~= 0 then ret = false else ret = i end
        end
        if fn_close[i] then depth = depth - 1 end
        if ret == false then break end
    end
    if not ret then
        -- Return-less module (kslua-style): top-level `__exports` members are the
        -- contract, unless the file defines `__exports` itself.
        if ret == false or bindings[EXPORT_OWNER] and #bindings[EXPORT_OWNER] > 0 then return end
        local count = 0
        for _, n in ipairs(r.nodes) do
            if not n.parent and (n.kind == 'function' or n.kind == 'method')
                and (n.qualified == EXPORT_OWNER .. '.' .. n.name or n.qualified == EXPORT_OWNER .. ':' .. n.name) then
                count = count + 1
            end
        end
        if count == 0 then return end
        for index, n in ipairs(r.nodes) do
            if not n.parent and (n.kind == 'function' or n.kind == 'method')
                and (n.qualified == EXPORT_OWNER .. '.' .. n.name or n.qualified == EXPORT_OWNER .. ':' .. n.name) then
                r.lua_exports[n.name] = index
            end
        end
        for i = 1, T.n - 4 do
            if scopes[i] == 0 and T.k[i] == 'id' and T:text(i) == EXPORT_OWNER and T:text(i + 1) == '.' and T.k[i + 2] == 'id'
                and T:text(i + 3) == '=' and T:text(i + 4) ~= 'function' then
                r.lua_exports[T:text(i + 2)] = nil
                if T.k[i + 4] == 'id' and (T.l[i + 5] ~= T.l[i + 4] or T:text(i + 5) == ';') then alias(r.lua_exports, T:text(i + 2), T:text(i + 4)) end
            end
        end
        return
    end
    local owner, table_start, first = nil, nil, 1
    local function shadowed_owner(token)
        for _, b in ipairs(bindings[owner] or {}) do
            if b.a ~= 0 and b.token <= token and b.b >= token
                and (params[b.token] or T:text(b.token - 1) == 'local'
                    or T:text(b.token - 1) == 'function' and T:text(b.token - 2) == 'local') then return true end
        end
        return false
    end
    if T.k[ret + 1] == 'id' and (ret + 1 == T.n or T:text(ret + 2) == ';') then
        owner = T:text(ret + 1)
        -- A returned object need not originate in a literal table: cached or
        -- factory-provided objects can receive definite members afterwards.
        -- Any possible replacement outside a function invalidates older fields.
        for _, b in ipairs(bindings[owner] or {}) do
            if b.token < ret and not function_scopes[b.a] and not shadowed_owner(b.token) then
                first = b.token + 1
                table_start = b.a == 0 and T:text(b.token + 1) == '=' and T:text(b.token + 2) == '{'
                    and b.token + 2 or nil
            end
        end
    elseif T:text(ret + 1) == '{' and T.m[ret + 1] then
        table_start = ret + 1
        first = table_start
        owner = r.path:match('([^/\\]+)%.lua$') or r.path
    else return end
    local writes = {}
    local finish = table_start == ret + 1 and T.m[table_start] or ret
    if owner then
        if table_start and not T.m[table_start] then return end
        r.lua_owner = owner
        for index, n in ipairs(r.nodes) do
            if not n.parent and n.ti >= first and n.ti < finish and not function_scopes[scopes[n.ti]]
                and (n.qualified == owner .. '.' .. n.name or n.qualified == owner .. ':' .. n.name)
                and (n.kind == 'function' or n.kind == 'method') and not shadowed_owner(n.ti) then
                writes[n.name] = n.ti
                r.lua_exports[n.name] = scopes[n.ti] == 0 and index or nil
            end
        end
    end
    if table_start then
        local i, close = table_start + 1, T.m[table_start]
        while i < close do
            if T.k[i] == 'id' and T:text(i + 1) == '=' and T.k[i + 2] == 'id'
                and (T:text(i + 3) == ',' or T:text(i + 3) == ';' or i + 3 == close) then
                local key = T:text(i)
                if not writes[key] or writes[key] < i then
                    alias(r.lua_exports, key, T:text(i + 2)); writes[key] = i
                end
            end
            if T.m[i] and T.m[i] > i then i = T.m[i]
            elseif bm[i] and bm[i] > i then i = bm[i] end
            i = i + 1
        end
    end
    for i = first, ret - 1 do
        if not function_scopes[scopes[i]] and T:text(i) == owner and T:text(i + 1) == '.' and T.k[i + 2] == 'id'
            and T:text(i + 3) == '=' and not shadowed_owner(i) then
            local key = T:text(i + 2)
            if not writes[key] or writes[key] < i then
                r.lua_exports[key], writes[key] = nil, i
                if scopes[i] == 0 and T.k[i + 4] == 'id'
                    and (T.l[i + 5] ~= T.l[i + 4] or T:text(i + 5) == ';') then
                    alias(r.lua_exports, key, T:text(i + 4))
                end
            end
        end
    end
end

local function normalize(p)
    local parts = {}
    for s in p:gsub('\\', '/'):gmatch('[^/]+') do
        if s == '..' and #parts > 0 and parts[#parts] ~= '..' then parts[#parts] = nil
        elseif s ~= '.' then parts[#parts + 1] = s end
    end
    return table.concat(parts, '/')
end
function M.context(G)
    local ctx = { directory = '', modules = {}, global_export_tables = { 'g_exports' } }
    local f = G.root and io.open(G.root .. '/.codeoutline.json', 'rb')
    if f then
        local raw = f:read(65537); f:close()
        assert(#raw <= 65536, '.codeoutline.json exceeds 64 KiB')
        local ok, config = pcall(xutils.json_unpack, raw)
        assert(ok and type(config) == 'table', 'invalid .codeoutline.json')
        local owners = config.luaGlobalExportTables
        if owners ~= nil then
            assert(type(owners) == 'table', 'luaGlobalExportTables must be an array of Lua identifiers')
            local seen, names = {}, {}
            for key, name in pairs(owners) do
                assert(type(key) == 'number' and key >= 1 and key <= #owners and key % 1 == 0
                    and type(name) == 'string' and name:match('^[%a_][%w_]*$'),
                    'luaGlobalExportTables must be an array of Lua identifiers')
                if not seen[name] then names[#names + 1], seen[name] = name, true end
            end
            table.sort(names)
            ctx.global_export_tables = names
        end
        local value = config.luaRuntimeDirectory
        if value ~= nil then
            assert(type(value) == 'string' and not value:match('^[/\\]') and not value:find(':', 1, true), 'luaRuntimeDirectory must be project-relative')
            ctx.directory = normalize(value)
            assert(not ctx.directory:match('^%.%.'), 'luaRuntimeDirectory must stay inside project')
        end
    end
    return ctx
end
-- Project-selected aliases share the normal name index and overlay path.
local EMPTY = {}
function M.aliases(node, owners)
    if not node.lua_aliases then return EMPTY end
    local names, seen = {}, {}
    for _, owner in ipairs(owners) do
        for _, name in ipairs((node.lua_aliases or {})[owner] or {}) do
            -- The ordinary name already has one entry. Retain same-name
            -- publication metadata without duplicating resident/draft IDs.
            if name ~= node.name and not seen[name] then names[#names + 1], seen[name] = name, true end
        end
    end
    return names
end
function M.exported(node, name, owners)
    if not node.lua_aliases then return false end
    for _, owner in ipairs(owners) do
        for _, alias in ipairs(node.lua_aliases[owner] or EMPTY) do if alias == name then return true end end
    end
    return false
end
function M.modules(G, imp, ctx)
    ctx = ctx or M.context(G)
    local key = imp.kind .. '\0' .. imp.path
    if ctx.modules[key] then return ctx.modules[key] end
    local result = {}
    if imp.kind == 'require' then
        for _, f in ipairs(M.native_modules(G, imp.path, ctx)) do result[#result + 1] = f end
        local sub = imp.path:gsub('%.', '/')
        for _, want in ipairs({ sub .. '.lua', sub .. '/init.lua' }) do
            local candidates = {}
            for _, f in ipairs(G.by_base[want:match('([^/]+)$')] or {}) do candidates[#candidates + 1] = f end
            for _, f in ipairs(G.new_files or {}) do candidates[#candidates + 1] = f end
            for _, f in ipairs(candidates) do
                local rec = G.files[f]
                if rec.language == 'lua' and (rec.path == want or rec.path:sub(-#want - 1) == '/' .. want) then result[#result + 1] = f end
            end
        end
    elseif not imp.path:match('^[/\\]') and not imp.path:find(':', 1, true) then
        local path = normalize(ctx.directory .. '/' .. imp.path)
        local f = G.file_index[path]
        if f and G.files[f].language == 'lua' then result[1] = f end
        if not result[1] then
            -- No file at that exact path: bind any indexed Lua file whose path
            -- ends with the quoted one, however deep the workspace root sits
            -- above the Lua tree (`dofile('scripts/x.lua')` opened from a parent).
            local want = normalize(imp.path)
            local base = want:match('([^/]+)$')
            if base then
                local candidates, seen = {}, {}
                for _, g in ipairs(G.by_base[base] or {}) do candidates[#candidates + 1] = g end
                for _, g in ipairs(G.new_files or {}) do candidates[#candidates + 1] = g end
                for _, g in ipairs(candidates) do
                    local rec = G.files[g]
                    if rec and rec.language == 'lua' and not seen[g]
                        and (rec.path == want or rec.path:sub(-#want - 1) == '/' .. want) then
                        seen[g] = true
                        result[#result + 1] = g
                    end
                end
            end
        end
    end
    ctx.modules[key] = result
    return result
end
function M.native_modules(G, name, ctx)
    return require('codeoutline.foreign').modules(G, 'lua', name, ctx)
end

-- Shared query-time receiver resolution for completion and navigation. Reuse
-- the parser's lexical bindings and loader contracts; never execute Lua.
function M.member(G, target, name)
    local result = {}
    for _, f in ipairs(target and target.modules or {}) do
        local rec = G.files[f]
        local exports = require('codeoutline.foreign').exports(rec, 'lua', target.module_name) or rec.lua_exports
        local n = exports and exports[name]
        if n then result[#result + 1] = { node = rec.nodes[n], file = f, index = n } end
    end
    return result
end

function M.return_target(G, node, ctx)
    local name = require('codeoutline.foreign').returns(node, 'lua')
    local files = name and M.native_modules(G, name, ctx)
    if files and #files > 0 then return { modules = files, module_name = name } end
end

function M.receiver(G, rec, T, name, offset, ctx, depth)
    depth = depth or 0
    if depth >= 6 then return nil, true end
    local best
    for _, b in ipairs((T.lua_bindings or {})[name] or {}) do
        if T.s[b.token] - 1 < offset and (b.a == 0 or T.s[b.a] - 1 <= offset)
            and (b.a == 0 or not T.e[b.b] or offset < T.e[b.b])
            and (not best or b.a > best.a or b.a == best.a and b.token > best.token) then best = b end
    end
    if not best then
        local files = M.native_modules(G, name, ctx)
        return #files > 0 and { modules = files, module_name = name } or nil, (T.lua_bindings or {})[name] ~= nil
    end
    local imported = tonumber(best.hint:match('^lua:(%d+)$'))
    if imported then
        local imp = rec.lua_imports[imported]
        return { modules = M.modules(G, imp, ctx), module_name = imp.path }, true
    end
    local i = best.token + 2
    if best.imported or T:text(best.token + 1) ~= '=' or T.k[i] ~= 'id' then return nil, true end
    local target = M.receiver(G, rec, T, T:text(i), T.s[best.token] - 1, ctx, depth + 1)
    i = i + 1
    while target and (T:text(i) == '.' or T:text(i) == ':') and T.k[i + 1] == 'id' do
        local close = T:text(i + 2) == '(' and T.m[i + 2]
        if not close then return nil, true end
        local next_target
        for _, entry in ipairs(M.member(G, target, T:text(i + 1))) do
            local value = M.return_target(G, entry.node, ctx)
            if not value or next_target and next_target.module_name ~= value.module_name then return nil, true end
            next_target = value
        end
        target, i = next_target, close + 1
    end
    -- Reject expressions whose value is not the simple receiver/call chain.
    local tail = T:text(i)
    if T.k[i] == 'op' and tail ~= ';' and tail ~= ')' and tail ~= ','
        or tail == 'and' or tail == 'or' then return nil, true end
    return target, true
end

function M.resolve(G, f, name, hint, ctx, recv)
    if G.files[f].language ~= 'lua' then return nil end
    if not hint or hint == '' then
        local result = {}
        for _, target in ipairs(M.native_modules(G, recv, ctx)) do
            local n = require('codeoutline.foreign').exports(G.files[target], 'lua', recv)[name]
            if n then result[#result + 1] = G.id_of[target][n] end
        end
        return #result > 0 and result or nil
    end
    if hint == '?' then return {} end
    local local_index = tonumber(hint:match('^lua%-local:(%d+)$'))
    if local_index then
        local n = ((G.files[f].lua_locals or {})[local_index] or {})[name]
        return n and { G.id_of[f][n] } or {}
    end
    local value = tonumber(hint:match('^lua%-value:(%d+)$'))
    local index = value or tonumber(hint:match('^lua:(%d+)$'))
    local imp = index and (G.files[f].lua_imports or {})[index]
    if not imp then return nil end
    if value then name = imp.member end
    local result = {}
    for _, target in ipairs(M.modules(G, imp, ctx)) do
        local rec = G.files[target]
        local exports = require('codeoutline.foreign').exports(rec, 'lua', imp.path) or rec.lua_exports
        local n = (exports or {})[name]
        if n then result[#result + 1] = G.id_of[target][n] end
    end
    return result
end
return M
