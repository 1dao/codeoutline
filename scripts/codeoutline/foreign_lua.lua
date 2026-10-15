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

local function parameters(T, node)
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
                if api == 'luaL_checkudata' or api == 'luaL_testudata' then kind = literal(T, i + 6) or kind end
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
    for i = 1, highest do
        local p = slots[i] or { types = {} }
        p.types.unknown = nil
        local types = {}
        for kind in pairs(p.types) do types[#types + 1] = kind end
        table.sort(types)
        local name = not p.ambiguous and p.name or nil
        if name and used[name] then name = nil end
        if name then used[name] = true end
        result.parameters[i] = { name = name, type = #types > 0 and table.concat(types, '|') or 'unknown',
            optional = p.optional or nil, default = p.optional and p.default or nil }
    end
    return result
end

-- Only explicit registration tables wired inside luaopen_* are exports.
-- Keep the original C nodes, including their source ranges and signatures.
function M.collect(r, T)
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
    for _, node in ipairs(r.nodes) do
        local module = node.kind == 'function' and node.name:match('^luaopen_(.+)$')
        if module then
            local exports = {}
            for i = node.ti, node.tj do
                local call = T:text(i)
                -- A fresh table replaces registrations for earlier metatables.
                if T:text(i + 1) == '(' and (call == 'luaL_newlib' or call == 'lua_newtable'
                    or call == 'lua_createtable' or call == 'luaL_newmetatable') then exports = {} end
                if T:text(i + 1) == '(' and T:text(i + 3) == ',' then
                    local arg = (call == 'luaL_newlib' or call == 'luaL_setfuncs') and i + 4
                    if call == 'luaL_register' and T:text(i + 5) == ',' then arg = i + 6 end
                    for name, n in pairs(tables[arg and T:text(arg)] or {}) do exports[name] = n end
                end
            end
            if next(exports) then
                require('codeoutline.foreign').register(r, 'lua', module, exports)
                for _, n in pairs(exports) do
                    local target = r.nodes[n]
                    target.foreign_signatures = target.foreign_signatures or {}
                    target.foreign_signatures.lua = target.foreign_signatures.lua or parameters(T, target)
                end
            end
        end
    end
end

return M
