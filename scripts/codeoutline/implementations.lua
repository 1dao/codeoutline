-- Query-owned interface/virtual relationships over existing names and bases.
-- These are possible implementations, not evidence of a particular runtime type.
local M = { MAX_CANDIDATES = 512, MAX_TARGETS = 64, MAX_DEPTH = 16, MAX_HIERARCHY = 1024 }
local control = require('codeoutline.control')
local languages = { csharp = true, java = true, kotlin = true, typescript = true }
local types = { class = true, interface = true, struct = true, record = true, enum = true }
local callable = { method = true, ['function'] = true, constructor = true }
local function base_names(n)
    if n.bases then return n.bases end
    local result = {}
    for _, base in ipairs(n.extends or {}) do result[#result + 1] = base end
    for _, base in ipairs(n.implements or {}) do result[#result + 1] = base end
    return result
end
local function name(s)
    if not s then return nil end
    s = s:gsub('%s+', ''):gsub('^@', '')
    return s:match('^[%a_$][%w_$.]*$') and s or nil
end
local function owner(G, id)
    local f, n = G.node_file[id], G.nodes[id]
    return n.parent and types[G.files[f].nodes[n.parent].kind] and G.id_of[f][n.parent] or nil
end

-- Only ordinary named parameter types are accepted. Unsupported syntax is a
-- barrier; it must not degrade into matching by method name or argument count.
local function parameters(T, first, last, language)
    local result, a, i = {}, first, first
    while i <= last + 1 do
        local s = T:text(i)
        if i == last + 1 or s == ',' then
            if a < i then
                local b = i - 1
                for j = a, b do if T:text(j) == '=' then b = j - 1; break end end
                local text
                if language == 'kotlin' then
                    if T:text(a + 1) ~= ':' then return nil end
                    text = T.src:sub(T.s[a + 2], T.e[b])
                else
                    if T.k[b] ~= 'id' then return nil end
                    text = b > a and T.src:sub(T.s[a], T.e[b - 1]) or ''
                    text = text:gsub('^final%s+', '')
                end
                local mode = text:match('^(%w+)%s+')
                if mode == 'ref' or mode == 'out' or mode == 'in' then text = mode .. '|' .. text:sub(#mode + 1) end
                text = text:gsub('%s+', '')
                if text == '' or text:find('[<>()@]') then return nil end
                result[#result + 1] = text
            end
            a = i + 1
        elseif T.m[i] and T.m[i] > i then i = T.m[i] end
        i = i + 1
    end
    return result
end

function M.collect(r, T)
    if r.language == 'cpp' then return require('codeoutline.cpp_implementations').collect(r, T) end
    if r.language == 'typescript' then return require('codeoutline.ts_implementations').collect(r, T) end
    if not languages[r.language] then return end
    local evidence = {}
    for index, n in ipairs(r.nodes) do
        if index % 128 == 0 then control.check() end
        if types[n.kind] or n.kind == 'method' then
            local d = { at = T.s[n.ti] - 1 }
            if types[n.kind] then d.hierarchy_bases = require('codeoutline.type_bases').collect(T, n, r.language) end
            local opening, ni
            for i = n.ti, n.tj do
                local s = T:text(i)
                if s == '{' then break end
                if s == '<' then d.generic = true end
                if s == 'static' or s == 'private' or s == 'public' or s == 'protected' or s == 'internal'
                    or s == 'virtual' or s == 'abstract' or s == 'override' or s == 'open'
                    or s == 'final' or s == 'sealed' or s == 'new' then d[s] = true end
                if s == n.name and T:text(i + 1) == '(' and n.kind == 'method' then ni, opening = i, i + 1; break end
            end
            if opening and T.m[opening] then
                d.params = parameters(T, opening + 1, T.m[opening] - 1, r.language)
                if r.language == 'csharp' and T:text(ni - 1) == '.' then
                    local first = ni - 2
                    while T:text(first - 1) == '.' and T.k[first - 2] == 'id' do first = first - 2 end
                    d.explicit = name(T.src:sub(T.s[first], T.e[ni - 2]))
                end
            end
            evidence[index] = d
        end
    end
    r.implementation_evidence = evidence
    if r.language == 'csharp' then return end
    -- Java and Kotlin receiver declarations use the same lexical barriers as
    -- C#/C++ bindings. No assignment flow or factory-return inference is done.
    local wanted, stack, scopes, bindings = {}, {}, {}, {}
    for _, ref in ipairs(r.refs) do if (ref.kind == 'member_call' or ref.kind == 'ref') and ref.recv then wanted[ref.recv] = true end end
    if not next(wanted) then return end
    for i = 1, T.n do
        if T:text(i) == '{' and T.m[i] then stack[#stack + 1] = i end
        scopes[i] = stack[#stack] or 0
        if stack[#stack] and T.m[stack[#stack]] == i then stack[#stack] = nil end
    end
    local endings = { [')'] = true, [','] = true, [';'] = true, ['='] = true, ['{'] = true }
    local forbidden = { ['return'] = true, ['new'] = true, ['throw'] = true, ['package'] = true, ['import'] = true }
    for i = 1, T.n do
        if i % 4096 == 0 then control.check() end
        if T.k[i] == 'id' and wanted[T:text(i)] then
            local ty, declared
            if r.language == 'kotlin' then
                if T:text(i + 1) == ':' then
                    local last = i + 2
                    while T:text(last + 1) == '.' and T.k[last + 2] == 'id' do last = last + 2 end
                    if T:text(last + 1) == '?' then last = last + 1 end
                    ty = name(T.src:sub(T.s[i + 2], T.e[last]):gsub('%?$', ''))
                    if T:text(last + 1) == '<' then ty = nil end
                    declared = true
                elseif T:text(i - 1) == 'val' or T:text(i - 1) == 'var' then
                    declared = true
                    if T:text(i + 1) == '=' and T.k[i + 2] == 'id' and T:text(i + 3) == '(' then ty = T:text(i + 2) end
                end
            elseif endings[T:text(i + 1)] and not forbidden[T:text(i - 1)]
                and (T.k[i - 1] == 'id' or T.k[i - 1] == 'kw' or T:text(i - 1) == '>' or T:text(i - 1) == ']') then
                local first = i - 1
                while T:text(first - 1) == '.' and T.k[first - 2] == 'id' do first = first - 2 end
                ty, declared = name(T.src:sub(T.s[first], T.e[i - 1])), true
                if ty == 'var' then ty = T:text(i + 1) == '=' and T:text(i + 2) == 'new' and name(T:text(i + 3)) or nil end
            end
            if declared then
                local a, b = scopes[i], scopes[i] > 0 and T.m[scopes[i]] or T.n
                for _, n in ipairs(r.nodes) do
                    if (callable[n.kind] or types[n.kind]) and n.ti <= i and i <= n.tj and n.ti > a then a, b = n.ti, n.tj end
                end
                local key = T:text(i)
                bindings[key] = bindings[key] or {}
                bindings[key][#bindings[key] + 1] = { type = ty or false, token = i, first = a, last = b }
            end
        end
    end
    for _, ref in ipairs(r.refs) do
        if (ref.kind == 'member_call' or ref.kind == 'ref') and ref.recv then
            local best
            for _, b in ipairs(bindings[ref.recv] or {}) do
                if b.first <= ref.tok and ref.tok <= b.last and b.token < ref.tok
                    and (not best or b.first > best.first or b.first == best.first and b.token > best.token) then best = b end
            end
            if best then
                ref.binding = best.type and 'jvm:type:' .. best.type .. '\0' .. (T.s[best.token] - 1) or 'jvm:?'
                if T:text(ref.tok - 3) == '.' or T:text(ref.tok - 3) == '?.' then ref.binding = 'jvm:?' end
            elseif ref.recv == 'this' or ref.recv == 'super' then ref.binding = 'jvm:self:' .. ref.recv end
            r.has_bindings = true
        end
    end
end

function M.types(G, f, written, ctx, scope, at)
    if G.files[f].language == 'typescript' then
        return require('codeoutline.ts_implementations').types(G, f, written, ctx)
    end
    if G.files[f].language == 'csharp' then
        return require('codeoutline.csharp_bindings').types(G, f, written, at or 0, ctx, { scope = scope })
    end
    written = name(written)
    if not written then return {} end
    local rec = G.files[f]
    local function exact(q)
        local ids = {}
        for _, id in ipairs(G.by_name[q:match('([^.]+)$')] or {}) do
            local n = G.nodes[id]
            if types[n.kind] and n.qualified == q and G.files[G.node_file[id]].language == rec.language then ids[#ids + 1] = id end
        end
        return ids
    end
    local current = scope
    while current and current ~= '' and current ~= rec.package do
        local found = exact(current .. '.' .. written)
        if #found > 0 then return found end
        current = current:match('^(.*)%.[^.]+$')
    end
    local imported, wildcard, seen, seen_wildcard = {}, {}, {}, {}
    for _, imp in ipairs(rec.imports) do
        local alias = imp.alias or imp.path:match('([^.]+)$')
        local q
        if alias == written:match('^([^.]+)') then q = imp.path .. written:sub(#alias + 1)
        elseif imp.path:sub(-2) == '.*' then
            for _, id in ipairs(exact(imp.path:sub(1, -2) .. written)) do
                if not seen_wildcard[id] then seen_wildcard[id] = true; wildcard[#wildcard + 1] = id end
            end
        end
        if q then
            for _, id in ipairs(exact(q)) do
                if not seen[id] then seen[id] = true; imported[#imported + 1] = id end
            end
        end
    end
    if #imported > 0 then return imported end
    local found = exact((rec.package and rec.package ~= '' and rec.package .. '.' or '') .. written)
    if #found > 0 then return found end
    if written:find('.', 1, true) then
        found = exact(written)
        if #found > 0 then return found end
    end
    return wildcard
end

function M.resolve(G, f, src, method, evidence, ctx)
    if not evidence or evidence:sub(1, 4) ~= 'jvm:' then return nil end
    local ty, at = evidence:match('^jvm:type:(.-)%z(%d+)$')
    local cls = src and owner(G, src)
    local ids
    if ty then ids = M.types(G, f, ty, ctx, cls and G.nodes[cls].qualified or G.files[f].package, tonumber(at))
    elseif evidence == 'jvm:self:this' and cls then ids = { cls }
    elseif evidence == 'jvm:self:super' and cls then
        ids = {}
        for _, base in ipairs(base_names(G.nodes[cls])) do
            for _, id in ipairs(M.types(G, f, base, ctx, G.nodes[cls].qualified)) do ids[#ids + 1] = id end
        end
    else return {} end
    if #ids ~= 1 then return {} end
    local result, visited = {}, {}
    local function members(id, depth)
        if visited[id] or depth > M.MAX_DEPTH then return end
        visited[id] = true
        local found = false
        for _, mid in ipairs(G.by_name[method] or {}) do
            if owner(G, mid) == id and G.nodes[mid].kind == 'method' then result[#result + 1] = mid; found = true end
        end
        if not found then
            for _, base in ipairs(base_names(G.nodes[id])) do
                for _, bid in ipairs(M.types(G, G.node_file[id], base, ctx, G.nodes[id].qualified)) do members(bid, depth + 1) end
            end
        end
    end
    members(ids[1], 0)
    return result
end

function M.context(G, ctx, report)
    local C = { incomplete = false, stats = { candidates = 0, links = 0, hierarchy = 0 } }
    local cpp
    local function cpp_context()
        if not cpp then cpp = require('codeoutline.cpp_implementations').context(G, ctx, report, M, C) end
        return cpp
    end
    local details, ancestors, outgoing, incoming = {}, {}, {}, {}
    local function info(id)
        if details[id] then return details[id] end
        local f = G.node_file[id]
        local data = ctx.ordinary and ctx.ordinary.data(f) or G.files[f]
        local d = (data.implementation_evidence or {})[id - G.id_of[f][1] + 1] or {}
        details[id] = d; return d
    end
    local function bases(id, seen, depth, path)
        control.check()
        if path[id] then C.incomplete = true; return false end
        if seen[id] then return true end
        if depth > M.MAX_DEPTH or C.stats.hierarchy >= M.MAX_HIERARCHY then C.incomplete = true; return false end
        C.stats.hierarchy = C.stats.hierarchy + 1
        seen[id], path[id] = true, true
        local n, f = G.nodes[id], G.node_file[id]
        if G.files[f].language == 'typescript' and (n.parent or info(id).generic or info(id).declare) then path[id] = nil; return false end
        local valid = true
        for _, base in ipairs(base_names(n)) do
            local at = G.files[f].language == 'csharp' and info(id).at or nil
            local ids = M.types(G, f, base, ctx, n.qualified, at)
            if G.files[f].language == 'typescript' and #ids ~= 1 then valid = false end
            if #ids == 1 and not bases(ids[1], seen, depth + 1, path) then valid = false end
        end
        path[id] = nil
        return valid
    end
    local function ancestry(id)
        if not ancestors[id] then
            local found = {}
            if not bases(id, found, 0, {}) then found = {} end
            found[id] = nil; ancestors[id] = found
        end
        return ancestors[id]
    end
    local primitive = { csharp = { int = 'System.Int32', string = 'System.String', bool = 'System.Boolean',
        long = 'System.Int64', void = 'System.Void', object = 'System.Object', byte = 'System.Byte',
        sbyte = 'System.SByte', short = 'System.Int16', ushort = 'System.UInt16', uint = 'System.UInt32',
        ulong = 'System.UInt64', char = 'System.Char', double = 'System.Double', float = 'System.Single', decimal = 'System.Decimal' },
        java = { String = 'java.lang.String', int = 'int', boolean = 'boolean', long = 'long', Object = 'java.lang.Object',
            byte = 'byte', short = 'short', char = 'char', double = 'double', float = 'float' },
        typescript = { string = 'string', number = 'number', boolean = 'boolean', void = 'void', bigint = 'bigint', symbol = 'symbol', never = 'never' },
        kotlin = { Int = 'kotlin.Int', String = 'kotlin.String', Boolean = 'kotlin.Boolean', Long = 'kotlin.Long',
            Any = 'kotlin.Any', Unit = 'kotlin.Unit', Byte = 'kotlin.Byte', Short = 'kotlin.Short', Char = 'kotlin.Char',
            Double = 'kotlin.Double', Float = 'kotlin.Float' } }
    local function signature(id)
        local d, cls = info(id), owner(G, id)
        if not cls or not d.params or d.generic or info(cls).generic then return nil end
        local out, f = {}, G.node_file[id]
        local lang = G.files[f].language
        local written_types = d.params
        if lang == 'typescript' then
            if not d.returns or d.declare or d.accessor or G.nodes[cls].parent then return nil end
            written_types = {}; for _, p in ipairs(d.params) do written_types[#written_types + 1] = p end
            written_types[#written_types + 1] = d.returns
        end
        for _, written in ipairs(written_types) do
            local mode, rest = written:match('^(%w+)|(.+)$')
            mode, written = mode or '', rest or written
            local raw, suffix = written:match('^(.-)([%[%]%?]*)$')
            local canonical = primitive[lang][raw]
            if canonical and lang ~= 'csharp' and raw:match('^%u') then
                local ids = M.types(G, f, raw, ctx, G.nodes[cls].qualified, d.at)
                if #ids > 1 then return nil end
                if #ids == 1 then canonical = G.nodes[ids[1]].qualified end
            end
            if not canonical and lang ~= 'typescript' and (raw:match('^System%.') or raw:match('^java%.lang%.') or raw:match('^kotlin%.')) then canonical = raw end
            if not canonical then
                local ids = M.types(G, f, raw, ctx, G.nodes[cls].qualified, d.at)
                if #ids ~= 1 then return nil end
                if lang == 'typescript' and info(ids[1]).generic then return nil end
                canonical = lang == 'typescript' and ('node:' .. ids[1]) or G.nodes[ids[1]].qualified
            end
            out[#out + 1] = mode .. ':' .. canonical .. suffix
        end
        return table.concat(out, ',')
    end
    local function contract(id)
        local cls = owner(G, id)
        if not cls or G.nodes[id].kind ~= 'method' or not languages[G.files[G.node_file[id]].language] then return false end
        local d, lang = info(id), G.files[G.node_file[id]].language
        if d.static or d.private or d.final or d.sealed or d.new or d.explicit or d.declare or d.accessor then return false end
        if lang == 'typescript' then return G.nodes[cls].kind == 'interface' or d.abstract end
        return G.nodes[cls].kind == 'interface' or G.nodes[id].abstract or d.virtual or d.abstract or d.open or d.override or lang == 'java'
    end
    local function matches(base, candidate)
        local cls, parent = owner(G, candidate), owner(G, base)
        if not cls or not parent or not ancestry(cls)[parent] then return false end
        local d, language = info(candidate), G.files[G.node_file[candidate]].language
        if G.nodes[candidate].abstract or d.abstract or d.static or d.private and not d.explicit or d.new then return false end
        if language == 'typescript' and (not d.body or d.protected and G.nodes[parent].kind == 'interface') then return false end
        if language == 'kotlin' and not d.override then return false end
        if language == 'csharp' then
            if d.explicit then
                local ids = M.types(G, G.node_file[candidate], d.explicit, ctx, G.nodes[cls].qualified, d.at)
                if #ids ~= 1 or ids[1] ~= parent then return false end
            elseif G.nodes[parent].kind == 'interface' then if not d.public then return false end
            elseif not d.override then return false end
        end
        if language == 'java' and G.nodes[parent].kind == 'interface' and not d.public and G.nodes[cls].kind ~= 'interface' then return false end
        if language == 'java' and G.nodes[parent].kind ~= 'interface' and not info(base).public and not info(base).protected
            and G.files[G.node_file[base]].package ~= G.files[G.node_file[candidate]].package then return false end
        local a, b = signature(base), signature(candidate)
        return a ~= nil and a == b
    end
    function C.outgoing(id)
        if G.files[G.node_file[id]].language == 'cpp' and G.nodes[id].kind == 'method' then return cpp_context().outgoing(id) end
        if outgoing[id] then return outgoing[id] end
        local result = {}
        if contract(id) then
            local checked, language = 0, G.files[G.node_file[id]].language
            for _, candidate in ipairs(G.by_name[G.nodes[id].name] or {}) do
                control.check()
                local cls = owner(G, candidate)
                if candidate ~= id and cls and G.nodes[candidate].kind == 'method'
                    and G.files[G.node_file[candidate]].language == language and #base_names(G.nodes[cls]) > 0 then
                    if checked >= M.MAX_CANDIDATES or #result >= M.MAX_TARGETS then C.incomplete = true; break end
                    checked = checked + 1; C.stats.candidates = C.stats.candidates + 1
                    if matches(id, candidate) then
                        result[#result + 1] = candidate; C.stats.links = C.stats.links + 1
                        if report then report:add({ source = id, target = candidate, line = G.nodes[id].line, kind = 'possible implementation (declared inheritance and parameter types)' }) end
                    end
                end
            end
        end
        outgoing[id] = result; return result
    end
    function C.incoming(id)
        if G.files[G.node_file[id]].language == 'cpp' and G.nodes[id].kind == 'method' then return cpp_context().incoming(id) end
        if incoming[id] then return incoming[id] end
        local result, cls = {}, owner(G, id)
        if cls and languages[G.files[G.node_file[id]].language] then
            local parents, checked = ancestry(cls), 0
            for _, base in ipairs(G.by_name[G.nodes[id].name] or {}) do
                control.check()
                if parents[owner(G, base)] then
                    if checked >= M.MAX_CANDIDATES or #result >= M.MAX_TARGETS then C.incomplete = true; break end
                    checked = checked + 1
                    if contract(base) and matches(base, id) then
                        result[#result + 1] = base
                        if report then report:add({ source = base, target = id, line = G.nodes[base].line, kind = 'possible implementation (declared inheritance and parameter types)' }) end
                    end
                end
            end
        end
        incoming[id] = result; return result
    end
    return C
end

return M
