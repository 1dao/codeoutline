-- Lua C API adapter for the language-neutral foreign interface model.
local M = {}
local control = require('codeoutline.control')
local function literal(T, i)
    local s = T:text(i)
    if T.k[i] ~= 'str' or s:find('\\', 1, true) then return nil end
    return s:sub(2, -2)
end

local READ = {
    luaL_checkinteger = 'int', luaL_optinteger = 'int', lua_tointeger = 'int', lua_tointegerx = 'int',
    luaL_checknumber = 'number', luaL_optnumber = 'number', lua_tonumber = 'number', lua_tonumberx = 'number',
    luaL_checkstring = 'string', luaL_checklstring = 'string', luaL_optstring = 'string', luaL_optlstring = 'string',
    lua_tostring = 'string', lua_tolstring = 'string', lua_toboolean = 'boolean',
    luaL_checkudata = 'userdata', luaL_testudata = 'userdata', lua_touserdata = 'userdata',
    luaL_checkany = 'unknown', luaL_checktype = 'unknown',
    lua_isinteger = 'int', lua_isnumber = 'number', lua_isstring = 'string', lua_isboolean = 'boolean',
    lua_istable = 'table', lua_isfunction = 'function', lua_isthread = 'thread', lua_isuserdata = 'userdata',
}
local TYPES = { LUA_TNUMBER = 'number', LUA_TSTRING = 'string', LUA_TBOOLEAN = 'boolean',
    LUA_TTABLE = 'table', LUA_TFUNCTION = 'function', LUA_TTHREAD = 'thread',
    LUA_TUSERDATA = 'userdata', LUA_TLIGHTUSERDATA = 'lightuserdata', LUA_TNIL = 'nil' }

-- offset: leading C arguments the guest never passes (a method's self).
local function parameters(T, node, macros, offset)
    local state
    for i = node.ti, node.tj - 2 do
        if T:text(i) == 'lua_State' and T:text(i + 1) == '*' and T.k[i + 2] == 'id' then
            state = T:text(i + 2); break
        end
    end
    local slots, highest, unknown = {}, 0, false
    for i = node.ti, node.tj do
        if i % 4096 == 0 then control.check() end
        local api = T:text(i)
        if READ[api] and T:text(i + 1) == '(' and T:text(i + 2) == state and T:text(i + 3) == ',' then
            local position = tonumber(T:text(i + 4))
            local ending = T:text(i + 5)
            if position and position > 0 and position <= 64 and position == math.floor(position)
                and (ending == ',' or ending == ')') then
                highest = math.max(highest, position)
                local p = slots[position] or { types = {} }
                slots[position] = p
                local kind = READ[api]
                if api == 'luaL_checktype' then kind = TYPES[T:text(i + 6)] or 'unknown' end
                if api == 'luaL_checkudata' or api == 'luaL_testudata' then
                    kind = literal(T, i + 6) or (macros and T.k[i + 6] == 'id' and macros[T:text(i + 6)]) or kind
                end
                p.types[kind] = true
                local optional = api:match('^luaL_opt') ~= nil
                if p.optional == nil then p.optional = optional else p.optional = p.optional and optional end
                if optional then
                    local close = T.m[i + 1]
                    local last = close and close - 1
                    if last and api == 'luaL_optlstring' then
                        last = i + 6
                        while last < close and T:text(last) ~= ',' do last = last + 1 end
                        last = last - 1
                    end
                    if last and last >= i + 6 then p.default = T.src:sub(T.s[i + 6], T.e[last]) end
                end
                -- Only a direct assignment supplies a public argument name.
                -- Casts between '=' and the API call are harmless; expressions aren't.
                local j = i - 1
                while j >= node.ti and T:text(j) ~= ';' and T:text(j) ~= '{' and T:text(j) ~= '}' do
                    if T:text(j) == '=' then
                        local direct = j == i - 1 or (T:text(j + 1) == '(' and T.m[j + 1] == i - 1)
                        if direct and not api:match('^lua_is') and api ~= 'luaL_checktype'
                            and T.k[j - 1] == 'id' and T:text(j - 2) ~= '.' and T:text(j - 2) ~= '->' then
                            local name = T:text(j - 1)
                            if not p.name then p.name = name elseif p.name ~= name then p.ambiguous = true end
                        end
                        break
                    end
                    j = j - 1
                end
            elseif T:text(i + 4) ~= '-' and T:text(i + 4) ~= 'lua_upvalueindex' then
                unknown = true
            end
        end
    end
    local result, used = { parameters = {}, unknown_tail = unknown }, {}
    offset = offset or 0
    for i = 1 + offset, highest do
        local p = slots[i] or { types = {} }
        p.types.unknown = nil
        local types = {}
        for kind in pairs(p.types) do types[#types + 1] = kind end
        table.sort(types)
        local name = not p.ambiguous and p.name or nil
        if name and used[name] then name = nil end
        if name then used[name] = true end
        result.parameters[i - offset] = { name = name, type = #types > 0 and table.concat(types, '|') or 'unknown',
            optional = p.optional or nil, default = p.optional and p.default or nil }
    end
    return result
end

-- `#define NAME "value"`: metatable names are usually macros, not literals.
local function string_macros(T)
    local map = {}
    for i = 1, T.n do
        if T.k[i] == 'dir' then
            local name, value = T:text(i):match('^#%s*define%s+([%a_][%w_]*)%s+"([^"]*)"%s*$')
            if name then map[name] = value end
        end
    end
    return map
end

-- Metatable name at argument token i.
local function meta_name(T, i, macros)
    if T.k[i] == 'str' then return literal(T, i) end
    if T.k[i] == 'id' then return macros[T:text(i)] end
end

-- Recognize constructor tails with a small symbolic stack, not C dataflow.
-- Unknown stack mutations invalidate the tail. All normal returns must agree;
-- luaL_error paths do not return to the guest. Void push helpers are supported.
local function returned_meta(T, r, functions, macros, cache, index, depth)
    local node = r.nodes[index]
    if not node or not node.ti then return nil end
    depth = depth or 6
    if depth <= 0 then return nil end
    if cache[index] ~= nil then return cache[index] or nil end
    cache[index] = false
    local stack, result, returns, invalid = {}, nil, 0, false
    local function accept(meta)
        returns = returns + 1
        if not meta or result and result ~= meta then invalid = true end
        result = result or meta
    end
    local i, block_depth = node.ti, 0
    while i <= node.tj do
        if i % 4096 == 0 then control.check() end
        local word = T:text(i)
        if word == '{' then block_depth = block_depth + 1 end
        if word == '}' then block_depth = block_depth - 1 end
        if word == 'return' then
            local value = T:text(i + 1)
            if value == '1' and T:text(i + 2) == ';' then
                accept(stack[#stack])
            elseif value == 'luaL_error' then
                -- This API raises, so it is not a competing normal return.
            elseif functions[value] and T:text(i + 2) == '(' and T.m[i + 2]
                and T:text(T.m[i + 2] + 1) == ';' then
                accept(returned_meta(T, r, functions, macros, cache, functions[value], depth - 1))
            else accept(nil) end
        elseif T:text(i + 1) == '(' and T.m[i + 1] and i > node.ti
            and T:text(i - 1) ~= 'return' then
            local close = T.m[i + 1]
            local conditional = block_depth > 1 or T:text(i - 1) == ')' and T.m[i - 1]
                and T:text(T.m[i - 1] - 1) == 'if'
            if word == 'lua_newuserdata' or word == 'lua_newuserdatauv' then
                stack[#stack + 1] = false
            elseif word == 'luaL_setmetatable' then
                if conditional then invalid = true end
                if #stack > 0 then stack[#stack] = meta_name(T, i + 4, macros) or false end
            elseif word == 'lua_pushvalue' then
                stack[#stack + 1] = false
            elseif word == 'luaL_ref' then
                stack[#stack] = nil
            elseif word == 'lua_pop' or word == 'lua_settop' or word == 'lua_remove'
                or word == 'lua_replace' or word == 'lua_insert' or word == 'lua_rotate' then
                stack = {}
            elseif word:match('^lua_push') or word:match('^lua_get') and word ~= 'lua_gettop'
                or word == 'lua_newtable' or word == 'lua_createtable' then
                stack[#stack + 1] = false
            elseif functions[word] and functions[word] ~= index then
                local meta = returned_meta(T, r, functions, macros, cache, functions[word], depth - 1)
                if meta then
                    if conditional then invalid = true end
                    stack[#stack + 1] = meta
                elseif #stack > 0 then stack = {} end
            elseif word:match('^lua_') and word ~= 'lua_gettop'
                and not word:match('^lua_to') and not word:match('^lua_is')
                and word ~= 'lua_type' then
                stack = {}
            end
            -- Arguments are not independent statements or constructor results.
            i = close
        end
        i = i + 1
    end
    if returns == 0 and (node.sig or ''):match('^%s*static%s+void%s') then result = stack[#stack] end
    if invalid then result = nil end
    cache[index] = result or false
    return result
end

-- Only explicit registration tables wired inside luaopen_* are exports. A
-- metatable's methods are exported under the metatable name, which is the type
-- guests see, so `handle:get(...)` completes and tips without hand-written
-- metadata. Keep the original C nodes, ranges and signatures.
function M.collect(r, T)
    local macros = string_macros(T)
    local tables, functions = {}, {}
    for n, node in ipairs(r.nodes) do
        if node.kind == 'function' then functions[node.name] = n end
    end
    for i = 1, T.n do
        if i % 4096 == 0 then control.check() end
        if T:text(i) == 'luaL_Reg' and T.k[i + 1] == 'id' then
            local j = i + 2
            if T:text(j) == '[' and T.m[j] then j = T.m[j] + 1 end
            if T:text(j) == '=' and T:text(j + 1) == '{' and T.m[j + 1] then
                local entries = {}
                for k = j + 2, T.m[j + 1] - 1 do
                    if T:text(k) == '{' and T.k[k + 1] == 'str' and T:text(k + 2) == ',' then
                        local name, target = literal(T, k + 1), functions[T:text(k + 3)]
                        if name and target and T:text(k + 4) == '}' then entries[name] = target end
                    end
                end
                tables[T:text(i + 1)] = entries
            end
        end
    end
    local cache = {}
    local function signature(n, method_of)
        local target = r.nodes[n]
        target.foreign_signatures = target.foreign_signatures or {}
        if target.foreign_signatures.lua then return end
        local contract = parameters(T, target, macros, method_of and 1 or 0)
        contract.returns = returned_meta(T, r, functions, macros, cache, n)
        target.foreign_signatures.lua = contract
    end
    for _, node in ipairs(r.nodes) do
        local module = node.kind == 'function' and node.name:match('^luaopen_(.+)$')
        if module then
            local exports, metas, meta, discard = {}, {}, nil, {}
            for i = node.ti, node.tj do
                local call = T:text(i)
                if T:text(i + 1) == '(' then
                    local into
                    if call == 'luaL_newmetatable' then
                        meta = meta_name(T, i + 4, macros)
                        if meta then metas[meta] = metas[meta] or {} end
                        into = meta and metas[meta] or discard
                    else
                        -- `lua_pop` finishes a metatable; a fresh library table
                        -- starts the module. A plain table inside a metatable
                        -- block is that metatable's `__index`, not the module.
                        if call == 'luaL_newlib' then
                            meta, exports = nil, {}
                        elseif call == 'lua_pop' then
                            meta = nil
                        elseif not meta and (call == 'lua_newtable' or call == 'lua_createtable') then
                            exports = {}
                        end
                        into = meta and metas[meta] or exports
                    end
                    if T:text(i + 3) == ',' then
                        local arg = (call == 'luaL_newlib' or call == 'luaL_setfuncs') and i + 4
                        if call == 'luaL_register' and T:text(i + 5) == ',' then arg = i + 6 end
                        for name, n in pairs(tables[arg and T:text(arg)] or {}) do into[name] = n end
                    end
                end
            end
            for name, entries in pairs(metas) do
                if next(entries) then
                    require('codeoutline.foreign').register(r, 'lua', name, entries)
                    for _, n in pairs(entries) do signature(n, name) end
                end
            end
            if next(exports) then
                require('codeoutline.foreign').register(r, 'lua', module, exports)
                for _, n in pairs(exports) do signature(n, nil) end
            end
        end
    end
end

return M
