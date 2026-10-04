-- completion.lua — LSP completion inside the INDEX worker.
--
-- No global names: without a member operator the items are the current
-- file's locals, parameters, definitions and imports, plus members of the
-- enclosing class. After `.`, `->`, `::`, `?.` or Lua `:` the receiver chain
-- is typed from `self`/`this`, declared types of locals, parameters, fields
-- and return types (read from signatures), initializers (`new T`, `T(`,
-- `T{`, `T::new(`), imports and static names, then its members are listed:
-- children, out-of-line definitions, assigned attributes and base classes.
-- Items are unsorted and unfiltered by case; the editor filters them. Type
-- files are reparsed on demand within a time budget; running out of it, or
-- of items, marks the list incomplete.
local graph = require('codeoutline.graph')
local parse = require('codeoutline.parse')
local navigation = require('codeoutline.navigation')
local control = require('codeoutline.control')
local M = { MAX_ITEMS = 500, BUDGET_SECONDS = 0.3, MAX_FILE_BYTES = 524288, MAX_DEPTH = 6, CACHE_FILES = 64 }

local ITEM = { ['function'] = 3, method = 2, constructor = 4, destructor = 4, field = 5, variable = 6,
    property = 10, class = 7, struct = 22, union = 22, record = 22, interface = 8, enum = 13, enum_member = 20,
    constant = 21, namespace = 9, impl = 9, macro = 3, prototype = 3, typedef = 7, annotation_type = 8 }
local TYPES = { class = true, struct = true, union = true, interface = true, enum = true, record = true,
    typedef = true, namespace = true, impl = true, annotation_type = true }
local LUA_TYPES = setmetatable({ variable = true }, { __index = TYPES })
local CALLABLE = { ['function'] = true, method = true, constructor = true, prototype = true, macro = true, destructor = true }
local MEMBER = { ['.'] = true, ['->'] = true, ['::'] = true, ['?.'] = true }
local LUA_MEMBER = { ['.'] = true, [':'] = true }
local SELF = { self = true, this = true, cls = true }
-- Methods conventionally returning their receiver's type when no type is declared.
local FACTORY = { new = true, create = true, make = true, of = true, instance = true, getInstance = true,
    get_instance = true, New = true, Create = true, Instance = true }
local MODIFIERS = {}
for word in ([[static const constexpr volatile virtual inline extern explicit friend public private protected
    internal final abstract override sealed readonly async unsafe new partial synchronized native transient
    struct class enum union typename mut dyn impl ref out in params let var auto def function func pub]]):gmatch('%S+') do
    MODIFIERS[word] = true
end
local WRAPPERS = {}
for word in ([[Option Box Rc Arc RefCell Cell Mutex RwLock Weak unique_ptr shared_ptr weak_ptr Ptr Ref
    Optional Nullable Promise Future Lazy]]):gmatch('%S+') do WRAPPERS[word] = true end
local TYPE_AFTER = { go = true, rust = true, typescript = true, javascript = true, python = true }
local DYNAMIC = { lua = true, python = true, javascript = true, typescript = true }

-- Full parses of type files, keyed by the index record they correspond to.
local cache, cache_order = setmetatable({}, { __mode = 'k' }), {}

local function text_of(T, i) return T.s[i] and T:text(i) or '' end
local function is(T, i, s) return T.k[i] == 'op' and text_of(T, i) == s end
local function kw(T, i, s) return T.k[i] == 'kw' and text_of(T, i) == s end
-- Token texts of [a, b] joined by spaces (enough for declared types).
local function span(T, a, b)
    if a > b then return nil end
    local parts = {}
    for i = a, b do parts[#parts + 1] = text_of(T, i) end
    return table.concat(parts, ' ')
end

-- Type name for a declared type text: modifiers, pointers, references,
-- arrays, namespaces and well-known wrappers removed.
local function normalize(text)
    if type(text) ~= 'string' then return nil end
    text = text:gsub('^%s+', ''):gsub('%s+$', '')
    for _ = 1, 8 do
        local first, rest = text:match('^([%a_]+)%s+(.+)$')
        if first and MODIFIERS[first] then text = rest else break end
    end
    text = text:gsub('^[%*&%[%]]+', ''):gsub('[%*&%?!%s]+$', ''):gsub('%[%]$', '')
    text = text:gsub('^%[%d*%]', ''):gsub('^map%b[]', '')
    local outer, inner = text:match('^([%w_:%.]+)%s*<(.*)>$')
    if outer then
        local last = outer:match('([%w_]+)$')
        if WRAPPERS[last] then
            local depth, arg = 0, ''
            for c in inner:gmatch('.') do
                if c == '<' then depth = depth + 1 elseif c == '>' then depth = depth - 1 end
                if c == ',' and depth == 0 then break end
                arg = arg .. c
            end
            return normalize(arg)
        end
        return last
    end
    return text:match('([%a_][%w_]*)$')
end

local function strip_name(prefix, name)
    -- `Box::name` in an out-of-line definition, or a trailing `*`/`&`.
    prefix = prefix:gsub('[%w_]+%s*::%s*$', '')
    return prefix
end

-- Declared type of a node from its signature (or the full-parse `type`).
local function declared(node, language)
    if node.type then return normalize(node.type) end
    local sig, name = node.sig, node.name
    if not sig then return nil end
    if node.kind == 'constructor' then return nil end
    local callable = CALLABLE[node.kind]
    if callable then
        if language == 'rust' or language == 'python' then
            local after = sig:match('%->%s*([^:{]+)')
            return after and normalize(after)
        elseif language == 'go' then
            local at = sig:find(name .. '%s*%(')
            if not at then return nil end
            local rest = sig:sub(at + #name)
            local params = rest:match('^%s*%b()')
            if not params then return nil end
            rest = rest:sub(#params + 1):gsub('^%s+', '')
            if rest:sub(1, 1) == '(' then rest = rest:match('^%((.-)[,%)]') or '' end
            return normalize(rest)
        elseif language == 'typescript' or language == 'javascript' then
            local after = sig:match('%)%s*:%s*([^{=]+)$')
            return after and normalize(after)
        elseif language == 'lua' then
            return nil
        end
        local at = sig:find('[%w_]*' .. name .. '%s*%(')
        if not at then return nil end
        return normalize(strip_name(sig:sub(1, at - 1), name))
    end
    if language == 'go' then
        return normalize(sig:match('^%s*' .. name .. '%s+(.+)$'))
    elseif TYPE_AFTER[language] then
        local after = sig:match(name .. '%s*%??%s*:%s*([^=]+)')
        return after and normalize(after)
    elseif language == 'lua' then
        return nil
    end
    local at
    for position in sig:gmatch('()' .. name .. '%f[^%w_]') do at = position end
    if not at or at == 1 then return nil end
    return normalize(sig:sub(1, at - 1))
end

-- Full record and tokens of file f: the overlay document, else a cached
-- reparse of the indexed file (nil when too large or unreadable).
local function full(V, f)
    local draft = V.drafts[f]
    if draft then
        draft.completion = draft.completion or {}
        local entry = draft.completion
        if not entry.rec then entry.rec, entry.tokens = parse.parse_tokens(draft.path or V.files[f].path, draft.source) end
        return entry.rec, entry.tokens, draft
    end
    local key = V.files[f]
    local entry = cache[key]
    if entry == nil then
        if (key.size or 0) > M.MAX_FILE_BYTES then cache[key] = false; return nil end
        local doc = navigation.source_doc(V, f)
        entry = false
        if doc then
            local rec, tokens = parse.parse_tokens(key.path, doc.source)
            entry = rec and { rec = rec, tokens = tokens } or false
        end
        cache[key] = entry
        cache_order[#cache_order + 1] = key
        if #cache_order > M.CACHE_FILES then cache[table.remove(cache_order, 1)] = nil end
    end
    if not entry then return nil end
    return entry.rec, entry.tokens
end

-- Parameters inside parentheses [a, b] of a function header.
local function parameters(T, a, b, language, out)
    local segments, start, depth = {}, a, 0
    for i = a, b + 1 do
        local closing = i == b + 1
        if not closing then
            local s = text_of(T, i)
            if T.k[i] == 'op' and (s == '(' or s == '[' or s == '{' or s == '<') then depth = depth + 1
            elseif T.k[i] == 'op' and (s == ')' or s == ']' or s == '}' or s == '>') then depth = depth - 1 end
        end
        if closing or (depth == 0 and is(T, i, ',')) then
            if start <= i - 1 then segments[#segments + 1] = { start, i - 1 } end
            start = i + 1
        end
    end
    local pending = {}
    for _, seg in ipairs(segments) do
        local x, y = seg[1], seg[2]
        local eq = x
        while eq <= y and not is(T, eq, '=') do eq = eq + 1 end
        y = eq - 1
        if language == 'go' then
            local names, k = {}, x
            if T.k[k] == 'id' then names[1] = text_of(T, k); k = k + 1 end
            local type = span(T, k, y)
            if type then
                for _, name in ipairs(pending) do out[#out + 1] = { name = name, type = normalize(type) } end
                pending = {}
                for _, name in ipairs(names) do out[#out + 1] = { name = name, type = normalize(type) } end
            else
                for _, name in ipairs(names) do pending[#pending + 1] = name end
            end
        elseif TYPE_AFTER[language] or language == 'lua' then
            local k = x
            while k <= y and T.k[k] ~= 'id' and not kw(T, k, 'self') and not kw(T, k, 'this') do k = k + 1 end
            if k <= y then
                local colon = k + 1
                while colon <= y and not is(T, colon, ':') do colon = colon + 1 end
                out[#out + 1] = { name = text_of(T, k), type = colon < y and normalize(span(T, colon + 1, y)) or nil }
            end
        else
            local name
            for k = y, x, -1 do if T.k[k] == 'id' then name = k; break end end
            if name and name > x then out[#out + 1] = { name = text_of(T, name), type = normalize(span(T, x, name - 1)) } end
        end
    end
    for _, name in ipairs(pending) do out[#out + 1] = { name = name } end
end

-- Initializer starting at token j: a type name, a module path, or a call chain.
local function initializer(T, j, stop)
    if not j or j > stop then return {} end
    if kw(T, j, 'new') or (T.k[j] == 'id' and text_of(T, j) == 'new') then
        local k, last = j + 1, nil
        while k <= stop and (T.k[k] == 'id' or is(T, k, '::') or is(T, k, '.')) do
            if T.k[k] == 'id' then last = text_of(T, k) end
            k = k + 1
        end
        return { type = last }
    end
    if is(T, j, '&') then j = j + 1 end
    if T.k[j] == 'id' and text_of(T, j) == 'require' then
        local k = is(T, j + 1, '(') and j + 2 or j + 1
        if T.k[k] == 'str' then return { module = text_of(T, k):gsub('^[%a]*["\'%[=]+', ''):gsub('["\'%]=]+$', '') } end
    end
    local chain, k = {}, j
    while k <= stop and (T.k[k] == 'id' or (T.k[k] == 'kw' and SELF[text_of(T, k)])) do
        local item = { name = text_of(T, k) }
        chain[#chain + 1] = item
        k = k + 1
        if is(T, k, '<') and T.m[k] then k = T.m[k] + 1 end
        if is(T, k, '(') and T.m[k] then item.call = true; k = T.m[k] + 1
        elseif is(T, k, '{') and #chain == 1 then return { type = item.name } end
        if k <= stop and T.k[k] == 'op' and (MEMBER[text_of(T, k)] or text_of(T, k) == ':') then k = k + 1 else break end
    end
    if #chain == 1 and chain[1].call and chain[1].name:match('^%u') then return { type = chain[1].name } end
    if #chain > 0 then return { chain = chain } end
    return {}
end

-- Local declarations in tokens [a, b], skipping excluded ranges.
local function declarations(T, a, b, language, skip, out)
    local function skipped(i)
        for _, r in ipairs(skip) do if i >= r[1] and i <= r[2] then return r[2] end end
    end
    local function statement_end(j)
        local depth = 0
        for k = j, b do
            local s = text_of(T, k)
            if T.k[k] == 'op' and (s == '(' or s == '[' or s == '{') then depth = depth + 1
            elseif T.k[k] == 'op' and (s == ')' or s == ']' or s == '}') then
                if depth == 0 then return k - 1 end
                depth = depth - 1
            elseif depth == 0 and (s == ';' or T.k[k] == 'nl') then return k - 1 end
        end
        return b
    end
    local function add(name_tok, type, init)
        local entry = { name = text_of(T, name_tok), type = normalize(type), at = name_tok }
        if init then
            local stop = statement_end(init)
            local value = initializer(T, init, stop)
            entry.type = entry.type or normalize(value.type)
            entry.module, entry.chain = value.module, value.chain
        end
        out[#out + 1] = entry
    end
    local i = a
    while i <= b do
        local jump = skipped(i)
        if jump then i = jump + 1
        else
            local s = text_of(T, i)
            if language == 'lua' then
                if kw(T, i, 'local') then
                    if kw(T, i + 1, 'function') and T.k[i + 2] == 'id' then add(i + 2)
                    else
                        local names, k = {}, i + 1
                        while T.k[k] == 'id' do
                            names[#names + 1] = k
                            if is(T, k + 1, ',') then k = k + 2 else k = k + 1; break end
                        end
                        local init = is(T, k, '=') and k + 1 or nil
                        for n, tok in ipairs(names) do add(tok, nil, n == 1 and init or nil) end
                    end
                elseif kw(T, i, 'for') then
                    local k = i + 1
                    while T.k[k] == 'id' do add(k); if is(T, k + 1, ',') then k = k + 2 else break end end
                end
            elseif language == 'python' then
                local starts = i == a or T.k[i - 1] == 'nl' or T.k[i - 1] == 'indent' or T.k[i - 1] == 'dedent'
                if starts and T.k[i] == 'id' then
                    local k, names = i, {}
                    while T.k[k] == 'id' do
                        names[#names + 1] = k
                        if is(T, k + 1, ',') then k = k + 2 else k = k + 1; break end
                    end
                    local type
                    if is(T, k, ':') then
                        local e = k + 1
                        while e <= b and not is(T, e, '=') and T.k[e] ~= 'nl' do e = e + 1 end
                        type = span(T, k + 1, e - 1); k = e
                    end
                    if is(T, k, '=') then
                        for n, tok in ipairs(names) do add(tok, type, n == 1 and k + 1 or nil) end
                    end
                elseif kw(T, i, 'for') then
                    local k = i + 1
                    while T.k[k] == 'id' do add(k); if is(T, k + 1, ',') then k = k + 2 else break end end
                elseif kw(T, i, 'as') and T.k[i + 1] == 'id' then add(i + 1) end
            elseif language == 'javascript' or language == 'typescript' then
                if (kw(T, i, 'let') or kw(T, i, 'const') or kw(T, i, 'var')) and T.k[i + 1] == 'id' then
                    local k, type = i + 2, nil
                    if is(T, k, ':') then
                        local e = k + 1
                        while e <= b and not is(T, e, '=') and not is(T, e, ';') and not is(T, e, ',') do e = e + 1 end
                        type = span(T, k + 1, e - 1); k = e
                    end
                    add(i + 1, type, is(T, k, '=') and k + 1 or nil)
                end
            elseif language == 'go' then
                if T.k[i] == 'id' and (i == a or not (T.k[i - 1] == 'op' and MEMBER[text_of(T, i - 1)])) then
                    local k, names = i, {}
                    while T.k[k] == 'id' do
                        names[#names + 1] = k
                        if is(T, k + 1, ',') then k = k + 2 else k = k + 1; break end
                    end
                    if is(T, k, ':=') then
                        for n, tok in ipairs(names) do add(tok, nil, n == 1 and k + 1 or nil) end
                        i = k
                    end
                elseif kw(T, i, 'var') and T.k[i + 1] == 'id' then
                    local e = i + 2
                    while e <= b and not is(T, e, '=') and T.k[e] ~= 'nl' and not is(T, e, ';') do e = e + 1 end
                    add(i + 1, span(T, i + 2, e - 1), is(T, e, '=') and e + 1 or nil)
                end
            elseif language == 'rust' then
                if kw(T, i, 'let') then
                    local k = kw(T, i + 1, 'mut') and i + 2 or i + 1
                    if T.k[k] == 'id' then
                        local type, e = nil, k + 1
                        if is(T, e, ':') then
                            local t = e + 1
                            while t <= b and not is(T, t, '=') and not is(T, t, ';') do t = t + 1 end
                            type = span(T, e + 1, t - 1); e = t
                        end
                        add(k, type, is(T, e, '=') and e + 1 or nil)
                    end
                elseif kw(T, i, 'for') and T.k[i + 1] == 'id' then add(i + 1) end
            else
                -- C family, Java, C#: `Type name =|;|,|:` after a statement boundary.
                local nx = text_of(T, i + 1)
                if T.k[i] == 'id' and T.k[i + 1] == 'op' and (nx == '=' or nx == ';' or nx == ',' or nx == ':' or nx == '[') then
                    local k = i - 1
                    while k >= a and (T.k[k] == 'id' or (T.k[k] == 'kw' and not ({ ['return'] = 1, ['case'] = 1,
                        ['goto'] = 1, ['else'] = 1, ['throw'] = 1, ['delete'] = 1, ['typedef'] = 1 })[text_of(T, k)])
                        or is(T, k, '*') or is(T, k, '&') or is(T, k, '::') or is(T, k, '<') or is(T, k, '>')
                        or is(T, k, '[') or is(T, k, ']')) do
                        k = k - 1
                    end
                    local boundary = k < a or is(T, k, ';') or is(T, k, '{') or is(T, k, '}') or is(T, k, '(')
                        or T.k[k] == 'dir'
                    local type = boundary and span(T, k + 1, i - 1)
                    if type and type:find('[%w_]') then
                        local init = nx == '=' and i + 2 or nil
                        if type == 'auto' or type == 'var' or type == 'const auto' then type = nil end
                        add(i, type, init)
                    end
                end
            end
            i = i + 1
        end
    end
end

-- Imports usable as module receivers, from the current document's tokens.
local function module_aliases(T, language)
    local out = {}
    for i = 1, T.n do
        if language == 'lua' and kw(T, i, 'local') and T.k[i + 1] == 'id' and is(T, i + 2, '=') then
            local value = initializer(T, i + 3, math.min(T.n, i + 6))
            if value.module then out[text_of(T, i + 1)] = { kind = 'require', path = value.module } end
        elseif language == 'python' and kw(T, i, 'import') then
            local from, k = nil, i - 1
            while k >= 1 and T.k[k] ~= 'nl' and not kw(T, k, 'from') do k = k - 1 end
            if kw(T, k, 'from') then from = (span(T, k + 1, i - 1) or ''):gsub('%s+', '') end
            local j = i + 1
            while j <= T.n and T.k[j] ~= 'nl' do
                if T.k[j] == 'id' then
                    local first = j
                    while is(T, j + 1, '.') and T.k[j + 2] == 'id' do j = j + 2 end
                    local path = span(T, first, j):gsub('%s+', '')
                    local alias = path
                    if kw(T, j + 1, 'as') and T.k[j + 2] == 'id' then alias = text_of(T, j + 2); j = j + 2 end
                    if from then out[alias] = { kind = 'import', path = from, names = { path }, member = path }
                    elseif alias ~= path or not path:find('.', 1, true) then out[alias] = { kind = 'import', path = path } end
                end
                j = j + 1
            end
        elseif (language == 'javascript' or language == 'typescript') then
            if kw(T, i, 'import') and is(T, i + 1, '*') and T.k[i + 3] == 'id' and T.k[i + 5] == 'str' then
                out[text_of(T, i + 3)] = { kind = 'import', path = text_of(T, i + 5):sub(2, -2) }
            elseif kw(T, i, 'import') and T.k[i + 1] == 'id' and T.k[i + 3] == 'str' then
                out[text_of(T, i + 1)] = { kind = 'import', path = text_of(T, i + 3):sub(2, -2) }
            elseif (kw(T, i, 'const') or kw(T, i, 'let') or kw(T, i, 'var')) and T.k[i + 1] == 'id' and is(T, i + 2, '=') then
                local value = initializer(T, i + 3, math.min(T.n, i + 6))
                if value.module then out[text_of(T, i + 1)] = { kind = 'import', path = value.module } end
            end
        elseif language == 'go' and kw(T, i, 'import') then
            local first, last = i + 1, i + 2
            if is(T, i + 1, '(') and T.m[i + 1] then first, last = i + 2, T.m[i + 1] - 1 end
            for j = first, last do
                if T.k[j] == 'str' then
                    local path = text_of(T, j):sub(2, -2)
                    local alias = (j > first and T.k[j - 1] == 'id') and text_of(T, j - 1) or path:match('([^/]+)$')
                    out[alias] = { kind = 'import', path = path }
                end
            end
        end
    end
    return out
end

-- Files an import resolves to, through the graph's dependency rules.
local import_files
function import_files(V, f, alias)
    if alias.member and alias.path:sub(1, 1) ~= '.' then
        -- `from pkg import mod`: try the submodule first.
        local files = import_files(V, f, { kind = alias.kind, path = alias.path .. '.' .. alias.member })
        if #files > 0 then return files end
    end
    local files = navigation.import_files(V, f, { path = alias.path, kind = alias.kind, names = alias.names })
    if alias.member then
        -- `from pkg import name`: a module file named like the import, else a symbol.
        local modules = {}
        for _, g in ipairs(files) do
            local stem = V.files[g].path:match('([^/]+)%.[^./]+$')
            if stem == alias.member or V.files[g].path:match('([^/]+)/__init__%.py$') == alias.member then modules[#modules + 1] = g end
        end
        return modules
    end
    return files
end

local Completion = {}
Completion.__index = Completion

-- Type nodes named name, as seen from file f.
function Completion:types(name, f)
    if not name then return {} end
    f = f or self.f
    local accept = self.language == 'lua' and LUA_TYPES or TYPES
    local direct, paired = navigation.deps(self.V, f)
    local found = graph.resolve(self.V, f, nil, name, 'call', nil, direct, paired, accept) or {}
    if #found == 0 then
        local family = graph.family(self.V.files[f].language)
        for _, id in ipairs(self.V.by_name[name] or {}) do
            local node = self.V.nodes[id]
            if accept[node.kind] and graph.family(self.V.files[self.V.node_file[id]].language) == family then
                found[#found + 1] = id
                if #found >= 3 then break end
            end
        end
    end
    -- Partial declarations: impl blocks, forward declarations, C# partial classes.
    local set, list = {}, {}
    for _, id in ipairs(found) do
        local q = self.V.nodes[id].qualified
        local family = graph.family(self.V.files[self.V.node_file[id]].language)
        for _, cid in ipairs(self.V.by_name[name] or {}) do
            local c = self.V.nodes[cid]
            if not set[cid] and accept[c.kind] and c.qualified == q
                and graph.family(self.V.files[self.V.node_file[cid]].language) == family then
                set[cid] = true; list[#list + 1] = cid
            end
        end
    end
    return list
end

function Completion:expired()
    if os.clock() > self.deadline then self.incomplete = true; return true end
    return false
end

-- Member entries { name, kind, node, file } of the type ids, with bases.
function Completion:members(ids, depth, seen)
    depth, seen = depth or 0, seen or {}
    local V, out = self.V, {}
    local function add(name, kind, node, f)
        out[#out + 1] = { name = name, kind = kind, node = node, file = f }
    end
    for _, id in ipairs(ids) do
        if seen[id] or self:expired() then break end
        seen[id] = true
        control.check()
        local f = V.node_file[id]
        local n = id - V.id_of[f][1] + 1
        local node = V.nodes[id]
        local rec, T = full(V, f)
        local nodes = rec and rec.nodes or V.files[f].nodes
        local target = nodes[n]
        if not (target and target.qualified == node.qualified) then nodes, target = V.files[f].nodes, node end
        local language = V.files[f].language
        for _, c in ipairs(nodes) do
            if c.parent == n then add(c.name, c.kind, c, f) end
        end
        -- Out-of-line members anywhere: `Box::area`, Go methods, Lua `M.f` / `M:f`.
        for _, entry in ipairs(self:owned(node.qualified, graph.family(language))) do out[#out + 1] = entry end
        -- Attributes assigned in methods (Python, JS) or on Lua tables.
        if T and (language == 'python' or language == 'javascript' or language == 'typescript' or language == 'lua') then
            local first, last = 1, T.n
            if target.start_byte and language ~= 'lua' then
                first, last = nil, nil
                for i = 1, T.n do
                    if T.s[i] - 1 >= target.start_byte and not first then first = i end
                    if T.e[i] <= target.end_byte then last = i end
                end
            end
            local receivers = language == 'lua' and { [node.name] = true, self = true } or { self = true, this = true }
            for i = first or 1, (last or 0) - 3 do
                if T.k[i] == 'id' or T.k[i] == 'kw' then
                    if receivers[text_of(T, i)] and T.k[i + 1] == 'op' and (text_of(T, i + 1) == '.')
                        and T.k[i + 2] == 'id' and is(T, i + 3, '=') then
                        add(text_of(T, i + 2), 'field', { name = text_of(T, i + 2), kind = 'field' }, f)
                    end
                end
            end
        end
        -- Base classes.
        if depth < 3 and node.bases then
            for _, base in ipairs(node.bases) do
                local base_ids = self:types(normalize(base), f)
                for _, entry in ipairs(self:members(base_ids, depth + 1, seen)) do out[#out + 1] = entry end
            end
        end
    end
    return out
end

-- Members recorded under qualifier q (by_owner), with open documents
-- replacing their files' resident nodes.
function Completion:owned(q, family)
    local V, out = self.V, {}
    for _, id in ipairs(V.by_owner[q] or {}) do
        local g = V.node_file[id]
        if not V.drafts[g] and graph.family(V.files[g].language) == family then
            local node = V.nodes[id]
            out[#out + 1] = { name = node.name, kind = node.kind, node = node, file = g }
        end
    end
    for g, _ in pairs(V.drafts) do
        if graph.family(V.files[g].language) == family then
            for _, node in ipairs(V.files[g].nodes) do
                if graph.owner(node.qualified) == q then
                    out[#out + 1] = { name = node.name, kind = node.kind, node = node, file = g }
                end
            end
        end
    end
    return out
end

-- Fields assigned to name in the current file (`name.x = ...`), and the keys
-- of a table/object literal it is initialized with.
function Completion:assigned(name)
    local T, out = self.T, {}
    for i = 1, T.n - 3 do
        if T.k[i] == 'id' and text_of(T, i) == name and is(T, i + 1, '.') and T.k[i + 2] == 'id' and is(T, i + 3, '=')
            and not (i > 1 and T.k[i - 1] == 'op' and MEMBER[text_of(T, i - 1)]) then
            out[#out + 1] = { name = text_of(T, i + 2), kind = 'field' }
        elseif T.k[i] == 'id' and text_of(T, i) == name and is(T, i + 1, '=') and is(T, i + 2, '{') and T.m[i + 2] then
            local depth = 0
            for k = i + 3, T.m[i + 2] - 1 do
                if T.k[k] == 'op' and (text_of(T, k) == '{' or text_of(T, k) == '(' or text_of(T, k) == '[') then
                    depth = depth + 1
                elseif T.k[k] == 'op' and (text_of(T, k) == '}' or text_of(T, k) == ')' or text_of(T, k) == ']') then
                    depth = depth - 1
                elseif depth == 0 and T.k[k] == 'id' and (is(T, k + 1, '=') or is(T, k + 1, ':'))
                    and (is(T, k - 1, '{') or is(T, k - 1, ',') or is(T, k - 1, ';')) then
                    out[#out + 1] = { name = text_of(T, k), kind = 'field' }
                end
            end
        end
    end
    return out
end

-- Top-level members of module files.
function Completion:module_members(files)
    local out = {}
    for _, g in ipairs(files) do
        if self:expired() then break end
        local rec = self.V.files[g]
        local language = rec.language
        local exported
        if language == 'lua' then
            -- The table a Lua module returns names its members.
            local _, T = full(self.V, g)
            if T then
                for i = T.n - 1, 1, -1 do
                    if kw(T, i, 'return') and T.k[i + 1] == 'id' then exported = text_of(T, i + 1); break end
                end
            end
        end
        for _, node in ipairs(rec.nodes) do
            if exported then
                local member = node.qualified:match('^' .. exported:gsub('%p', '%%%0') .. '[%.:]([%w_]+)$')
                if member then out[#out + 1] = { name = member, kind = node.kind, node = node, file = g } end
            elseif not node.parent and not node.qualified:find('[%.:]') and (language ~= 'go' or node.name:match('^%u')) then
                out[#out + 1] = { name = node.name, kind = node.kind, node = node, file = g }
            end
        end
        if exported then
            local ids = self.V.id_of[g]
            for n, node in ipairs(rec.nodes) do
                if node.name == exported and not node.parent then
                    for _, entry in ipairs(self:members({ ids[n] })) do out[#out + 1] = entry end
                    break
                end
            end
        end
    end
    return out
end

-- Innermost function-like node and enclosing type of the cursor, in the full record.
function Completion:scope()
    local fn, owner
    local best
    for n, node in ipairs(self.rec.nodes) do
        if node.start_byte and node.start_byte <= self.offset and self.offset <= node.end_byte then
            if CALLABLE[node.kind] and (not best or node.end_byte - node.start_byte < best) then
                fn, best = n, node.end_byte - node.start_byte
            end
        end
    end
    local p = fn and self.rec.nodes[fn].parent
    while p do
        if TYPES[self.rec.nodes[p].kind] then owner = p; break end
        p = self.rec.nodes[p].parent
    end
    if not owner then
        local start = fn or 0
        local best_type
        for n, node in ipairs(self.rec.nodes) do
            if TYPES[node.kind] and node.start_byte and node.start_byte <= self.offset and self.offset <= node.end_byte
                and (not best_type or node.end_byte - node.start_byte < best_type) and n ~= start then
                owner, best_type = n, node.end_byte - node.start_byte
            end
        end
    end
    return fn, owner
end

-- Type ids of the enclosing class for self/this.
function Completion:self_types()
    local fn, owner = self.fn, self.owner
    if owner then return { self.V.id_of[self.f][owner] } end
    if not fn then return {} end
    local node = self.rec.nodes[fn]
    local prefix = node.qualified:match('^(.*)::[%w_]+$') or node.qualified:match('^(.*)[%.:][%w_]+$')
    if not prefix and self.language == 'go' then
        prefix = (node.sig or ''):match('^func%s*%(%s*[%w_]*%s*%*?%s*([%w_]+)')
    end
    return prefix and self:types(prefix:match('([%w_]+)$')) or {}
end

-- Locals and parameters visible at the cursor.
function Completion:locals()
    if self.locals_cache then return self.locals_cache end
    local T, rec, out = self.T, self.rec, {}
    local fn = self.fn and rec.nodes[self.fn]
    local a, b = 1, 0
    for i = 1, T.n do
        if T.s[i] - 1 < self.offset then b = i end
        if fn and T.s[i] - 1 < fn.start_byte then a = i + 1 end
    end
    -- Nested functions that end before the cursor keep their locals.
    local skip = {}
    for n, node in ipairs(rec.nodes) do
        if n ~= self.fn and CALLABLE[node.kind] and node.start_byte and node.end_byte <= self.offset
            and (not fn or node.start_byte >= fn.start_byte) then
            local first, last
            for i = a, b do
                if not first and T.s[i] - 1 >= node.start_byte then first = i end
                if T.e[i] <= node.end_byte then last = i end
            end
            if first and last then skip[#skip + 1] = { first, last } end
        end
    end
    if fn then
        local open
        for i = a, b do
            if is(T, i, '(') and T.m[i] and T.s[i] - 1 >= (fn.name_end or fn.start_byte) then open = i; break end
        end
        if self.language == 'go' and is(T, a + 1, '(') and T.m[a + 1] then
            parameters(T, a + 2, T.m[a + 1] - 1, 'go', out)
        end
        if open then
            parameters(T, open + 1, T.m[open] - 1, self.language, out)
            a = T.m[open] + 1
        end
        for _, param in ipairs(out) do param.kind = 'parameter' end
    end
    declarations(T, a, b, self.language, skip, out)
    self.locals_cache = out
    return out
end

local function find_local(locals, name)
    local hit
    for _, entry in ipairs(locals) do if entry.name == name then hit = entry end end
    return hit
end

-- A receiver: { types = ids } or { modules = files }.
function Completion:receiver(item, depth)
    local name = item.name
    if SELF[name] or (self.language == 'rust' and name == 'self') then
        local ids = self:self_types()
        if #ids > 0 then return { types = ids } end
    end
    local entry = find_local(self:locals(), name)
    if entry then
        if entry.module then
            return { modules = import_files(self.V, self.f, { kind = 'require', path = entry.module }) }
        elseif entry.type then
            local ids = self:types(entry.type)
            if #ids > 0 then return { types = ids } end
        elseif entry.chain and depth < M.MAX_DEPTH then
            return self:chain(entry.chain, depth + 1)
        end
        if not DYNAMIC[self.language] then return nil end
        -- An untyped local: only this file's assignments describe it.
        if not self.aliases[name] then return { owner = name, local_only = true } end
    end
    local alias = self.aliases[name]
    if alias then
        local files = import_files(self.V, self.f, alias)
        if #files > 0 then return { modules = files } end
    end
    local ids = self:types(name)
    if #ids > 0 then return { types = ids, static = true } end
    -- Dynamic languages: a global table with members defined elsewhere, or a
    -- local table whose fields this file assigns.
    if DYNAMIC[self.language] then return { owner = name } end
    return nil
end

function Completion:entries(target)
    if not target then return {} end
    if target.modules then return self:module_members(target.modules) end
    if target.owner then
        local out = target.local_only and {} or self:owned(target.owner, graph.family(self.language))
        for _, entry in ipairs(self:assigned(target.owner)) do out[#out + 1] = entry end
        return out
    end
    return self:members(target.types)
end

-- Type of a receiver chain, element by element.
function Completion:chain(chain, depth)
    depth = depth or 0
    local target = self:receiver(chain[1], depth)
    for k = 2, #chain do
        if not target or self:expired() then return nil end
        local element, next_ids = chain[k], {}
        for _, entry in ipairs(self:entries(target)) do
            if entry.name == element.name then
                local node = entry.node
                if TYPES[node.kind] then
                    for _, id in ipairs(self:types(node.name, entry.file)) do next_ids[#next_ids + 1] = id end
                else
                    local type = declared(node, self.V.files[entry.file].language)
                    if not type and element.call and FACTORY[element.name] and target.types then
                        for _, id in ipairs(target.types) do next_ids[#next_ids + 1] = id end
                    elseif type then
                        for _, id in ipairs(self:types(type, entry.file)) do next_ids[#next_ids + 1] = id end
                    end
                end
            end
        end
        target = #next_ids > 0 and { types = next_ids } or nil
    end
    return target
end

-- Receiver chain ending at member operator token op.
local function receiver_chain(T, op, member)
    local chain, i = {}, op - 1
    while i >= 1 and #chain < M.MAX_DEPTH do
        local call = false
        if is(T, i, ')') and T.m[i] then call = true; i = T.m[i] - 1 end
        if is(T, i, '>') and T.m[i] then i = T.m[i] - 1 end
        if not (T.k[i] == 'id' or (T.k[i] == 'kw' and SELF[text_of(T, i)])) then
            if call or #chain == 0 then return nil end
            break
        end
        table.insert(chain, 1, { name = text_of(T, i), call = call })
        local p = i - 1
        if p >= 1 and T.k[p] == 'op' and member[text_of(T, p)] then i = p - 1 else break end
    end
    return #chain > 0 and chain or nil
end

local function item_for(entry, language)
    local node = entry.node
    return { label = entry.name, kind = ITEM[entry.kind] or 6,
        detail = node and (node.sig or (node.type and (node.type .. ' ' .. entry.name))) or entry.detail }
end

-- Completion items at the cursor of req.uri.
function M.complete(req)
    local doc = navigation.request_doc(req)
    if not doc then return { items = {} } end
    local V = navigation.view(req.session, req.root)
    local f = V.add(doc)
    if not f then return { items = {} } end
    local self = setmetatable({ V = V, f = f, doc = doc, deadline = os.clock() + M.BUDGET_SECONDS,
        incomplete = false }, Completion)
    self.rec, self.T = full(V, f)
    if not self.rec or not self.T then return { items = {} } end
    self.language = self.rec.language
    self.offset = doc:offset(req.position)
    local T, offset = self.T, self.offset
    local t
    for i = 1, T.n do if T.s[i] - 1 < offset then t = i else break end end
    if t and T.k[t] == 'str' and offset < T.e[t] then return { items = {} } end
    local member = self.language == 'lua' and LUA_MEMBER or MEMBER
    local op = t
    if t and (T.k[t] == 'id' or T.k[t] == 'kw') and T.e[t] >= offset then op = t - 1 end
    local is_member = op and op >= 1 and T.k[op] == 'op' and member[text_of(T, op)] and T.e[op] <= offset
    if req.trigger and not is_member then return { items = {} } end
    self.fn, self.owner = self:scope()
    self.aliases = module_aliases(T, self.language)
    local entries = {}
    if is_member then
        local chain = receiver_chain(T, op, member)
        local target = chain and self:chain(chain)
        entries = self:entries(target)
        if self.language == 'lua' and text_of(T, op) == ':' then
            local methods = {}
            for _, entry in ipairs(entries) do if CALLABLE[entry.kind] then methods[#methods + 1] = entry end end
            entries = methods
        end
    else
        for _, entry in ipairs(self:locals()) do
            entries[#entries + 1] = { name = entry.name, kind = 'variable',
                detail = entry.type and (entry.type .. ' ' .. entry.name) or nil }
        end
        for alias in pairs(self.aliases) do entries[#entries + 1] = { name = alias, kind = 'namespace', detail = 'module' } end
        for _, node in ipairs(self.rec.nodes) do
            if not node.parent and not node.qualified:find('[%.:]') then
                entries[#entries + 1] = { name = node.name, kind = node.kind, node = node, file = f }
            end
        end
        if self.owner or self.fn then
            local ids = self:self_types()
            for _, entry in ipairs(self:members(ids)) do entries[#entries + 1] = entry end
        end
    end
    local items, seen = {}, {}
    for _, entry in ipairs(entries) do
        if not seen[entry.name] then
            seen[entry.name] = true
            if #items >= M.MAX_ITEMS then self.incomplete = true; break end
            items[#items + 1] = item_for(entry, self.language)
        end
    end
    return { items = items, incomplete = self.incomplete }
end

navigation.register('lsp_completion', function(req)
    local result = M.complete(req)
    return { isIncomplete = result.incomplete or false, items = result.items }, false
end)

M.normalize, M.declared = normalize, declared
return M
