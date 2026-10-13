-- Static Lua module return bindings. Never execute indexed source.
local M = {}
local control = require('codeoutline.control')
local loaders = { require = true, dofile = true, loadfile = true }
local function literal(T, i)
    if T.k[i] ~= 'str' then return nil end
    local s = T:text(i)
    local long = s:match('^%[(=*)%[')
    if long then return s:sub(#long + 3, -#long - 3):gsub('^\r?\n', '', 1) end
    if s:find('\\', 1, true) then return nil end
    return s:sub(2, -2)
end

function M.collect(r, T, bm)
    r.lua_imports, r.lua_exports, r.lua_locals = {}, {}, {}
    local scopes, stack, params, bindings = {}, {}, {}, {}
    for i = 1, T.n do
        if bm[i] and bm[i] > i then stack[#stack + 1] = i end
        scopes[i] = stack[#stack] or 0
        if stack[#stack] and bm[stack[#stack]] == i then stack[#stack] = nil end
        if T:text(i) == 'function' and T.k[i] == 'kw' then
            local p = i + 1
            while p < (bm[i] or i) and T:text(p) ~= '(' do p = p + 1 end
            for j = p + 1, (T.m[p] or p) - 1 do if T.k[j] == 'id' then params[j] = i end end
        end
    end
    local function add(name, token, scope, hint, imported)
        bindings[name] = bindings[name] or {}
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
                local imported = next == '=' and loaders[T:text(i + 2)]
                if next == '=' and loaders[T:text(i + 2)] then
                    local kind, call = T:text(i + 2), i + 2
                    local arg = T:text(call + 1) == '(' and call + 2 or call + 1
                    local path = literal(T, arg)
                    local close = T:text(call + 1) == '(' and T.m[call + 1] or arg
                    if close and ((close == arg) or (close == arg + 1)) and path then
                        -- A concatenation/operation after the loader is not its return value.
                        local tail = T:text(close + 1)
                        if tail ~= '..' and tail ~= '.' and tail ~= ':' and tail ~= 'or' and tail ~= 'and'
                            and tail ~= '(' and tail ~= '[' and tail ~= '+' and tail ~= '-' and tail ~= '*' and tail ~= '/' then
                            local shadowed = false
                            for _, b in ipairs(bindings[kind] or {}) do
                                if b.token < call and b.a <= call and b.b >= call then shadowed = true end
                            end
                            if not shadowed then
                                r.lua_imports[#r.lua_imports + 1] = { path = path, kind = kind }
                                hint = 'lua:' .. #r.lua_imports
                                if kind == 'loadfile' then hint = '?' end
                            end
                        end
                    end
                end
                -- Keep ordinary local function/table lookup; block unknown imported receivers.
                add(T:text(i), i, scopes[i], hint, imported)
            end
        end
    end
    for name, list in pairs(bindings) do
        for _, b in ipairs(list) do
            if b.hint:match('^lua%-local:') then
                local members = {}
                for index, n in ipairs(r.nodes) do
                    local scope = T:text(n.ti) == 'function' and scopes[n.ti - 1] or scopes[n.ti]
                    if n.ti >= b.token and n.ti <= b.b and scope == b.a
                        and (n.qualified == name .. '.' .. n.name or n.qualified == name .. ':' .. n.name) then members[n.name] = index end
                end
                r.lua_locals[#r.lua_locals + 1] = members
                b.hint = 'lua-local:' .. #r.lua_locals
            end
        end
    end
    for _, ref in ipairs(r.refs) do
        do
            local best
            for _, b in ipairs(bindings[ref.recv or ref.name] or {}) do
                if b.token <= ref.tok and b.a <= ref.tok and b.b >= ref.tok
                    and (not best or b.a > best.a or (b.a == best.a and b.token > best.token)) then best = b end
            end
            if best and (ref.recv or best.imported) then ref.lua_binding = ref.recv and best.hint or '?' end
            if ref.recv and (T:text(ref.tok - 3) == '.' or T:text(ref.tok - 3) == ':') then ref.lua_binding = '?' end
        end
    end

    -- A single unconditional top-level return is the supported module contract.
    local ret
    for i = 1, T.n do
        if T:text(i) == 'return' and T.k[i] == 'kw' then
            local in_function = false
            for _, n in ipairs(r.nodes) do
                if (n.kind == 'function' or n.kind == 'method') and n.ti <= i and n.tj >= i then in_function = true; break end
            end
            if not in_function then
                if ret or scopes[i] ~= 0 then r.lua_exports = {}; return end
                ret = i
            end
        end
    end
    if not ret then return end
    local owner, table_start
    if T.k[ret + 1] == 'id' and (ret + 1 == T.n or T:text(ret + 2) == ';') then
        owner = T:text(ret + 1)
        for i = 1, ret - 1 do
            if T:text(i) == owner and T:text(i + 1) == '=' and T:text(i + 2) == '{' and scopes[i] == 0 then table_start = i + 2 end
        end
    elseif T:text(ret + 1) == '{' and T.m[ret + 1] then
        table_start = ret + 1
        owner = r.path:match('([^/\\]+)%.lua$') or r.path
    else return end
    if owner then
        if not table_start or not T.m[table_start] then return end
        for i = table_start + 1, ret - 1 do
            if scopes[i] == 0 and T:text(i) == owner and T:text(i + 1) == '=' then r.lua_exports = {}; return end
        end
        for index, n in ipairs(r.nodes) do
            if not n.parent and n.ti >= table_start and (n.qualified == owner .. '.' .. n.name or n.qualified == owner .. ':' .. n.name)
                and (n.kind == 'function' or n.kind == 'method') then r.lua_exports[n.name] = index end
        end
    end
    local function alias(key, target)
        for index, n in ipairs(r.nodes) do
            if not n.parent and n.name == target and n.qualified == target and (n.kind == 'function' or n.kind == 'method') then
                r.lua_exports[key] = index
            end
        end
    end
    if table_start then
        local i, close = table_start + 1, T.m[table_start]
        while i < close do
            if T.k[i] == 'id' and T:text(i + 1) == '=' and T.k[i + 2] == 'id'
                and (T:text(i + 3) == ',' or T:text(i + 3) == ';' or i + 3 == close) then alias(T:text(i), T:text(i + 2)) end
            if T.m[i] and T.m[i] > i then i = T.m[i]
            elseif bm[i] and bm[i] > i then i = bm[i] end
            i = i + 1
        end
    end
    for i = 1, ret - 1 do
        if scopes[i] == 0 and T:text(i) == owner and T:text(i + 1) == '.' and T.k[i + 2] == 'id'
            and T:text(i + 3) == '=' and T:text(i + 4) ~= 'function' then
            r.lua_exports[T:text(i + 2)] = nil
            if T.k[i + 4] == 'id' and (T.l[i + 5] ~= T.l[i + 4] or T:text(i + 5) == ';') then alias(T:text(i + 2), T:text(i + 4)) end
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
    local ctx = { directory = '', modules = {} }
    local f = G.root and io.open(G.root .. '/.codeoutline.json', 'rb')
    if f then
        local raw = f:read(65537); f:close()
        assert(#raw <= 65536, '.codeoutline.json exceeds 64 KiB')
        local ok, config = pcall(xutils.json_unpack, raw)
        assert(ok and type(config) == 'table', 'invalid .codeoutline.json')
        local value = config.luaRuntimeDirectory
        if value ~= nil then
            assert(type(value) == 'string' and not value:match('^[/\\]') and not value:find(':', 1, true), 'luaRuntimeDirectory must be project-relative')
            ctx.directory = normalize(value)
            assert(not ctx.directory:match('^%.%.'), 'luaRuntimeDirectory must stay inside project')
        end
    end
    return ctx
end
function M.modules(G, imp, ctx)
    ctx = ctx or M.context(G)
    local key = imp.kind .. '\0' .. imp.path
    if ctx.modules[key] then return ctx.modules[key] end
    local result = {}
    if imp.kind == 'require' then
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
    end
    ctx.modules[key] = result
    return result
end
function M.resolve(G, f, name, hint, ctx)
    if G.files[f].language ~= 'lua' or not hint or hint == '' then return nil end
    if hint == '?' then return {} end
    local local_index = tonumber(hint:match('^lua%-local:(%d+)$'))
    if local_index then
        local n = ((G.files[f].lua_locals or {})[local_index] or {})[name]
        return n and { G.id_of[f][n] } or {}
    end
    local index = tonumber(hint:match('^lua:(%d+)$'))
    local imp = index and (G.files[f].lua_imports or {})[index]
    if not imp then return nil end
    local result = {}
    for _, target in ipairs(M.modules(G, imp, ctx)) do
        local n = (G.files[target].lua_exports or {})[name]
        if n then result[#result + 1] = G.id_of[target][n] end
    end
    return result
end
return M
