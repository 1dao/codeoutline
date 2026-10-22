-- Ordinary binding evidence belongs to one query, never to the resident index.
local M = {}
local control = require('codeoutline.control')
local function js(rec) return rec.language == 'javascript' or rec.language == 'typescript' or rec.language == 'arkts' end
local function evidence(rec, i)
    local refs = rec.refs
    return refs.binding and refs.binding[i] or refs.lua_binding and refs.lua_binding[i]
        or refs.js_receiver and refs.js_receiver[i]
end

function M.context(G, ctx, source, options)
    options = options or {}
    local cache, order, bytes = {}, {}, 0
    local max_files, max_bytes = options.max_files or 16, options.max_bytes or 8 * 1024 * 1024
    local C = { stats = { parses = 0, files = 0, bytes = 0 } }
    local hints = {}
    local function alias_hints(f)
        if hints[f] and hints[f].record == G.files[f] then return hints[f].roots end
        local result = {}
        for _, name in ipairs(G.files[f].dispatch_calls or {}) do
            if name:sub(1, 1) == '@' then result[name:sub(2):match('^([%w_$]+)')] = true end
        end
        hints[f] = { record = G.files[f], roots = result }
        return result
    end
    function C.data(f)
        local rec = G.files[f]
        if rec.ordinary_bindings then return rec end -- explicit in-memory parse
        if cache[f] and cache[f].record == rec then return cache[f].data end
        if not G.root and not source then return rec end
        control.check()
        local raw = source and source(f)
        if not raw then
            local file = assert(io.open(G.root .. '/' .. rec.path, 'rb'), 'cannot read binding source: ' .. rec.path)
            raw = file:read('a'); file:close()
            local crc = xcompress and xcompress.crc32 and xcompress.crc32(raw) or xutils.sha256_hex(raw)
            assert(#raw == rec.size and crc == rec.crc, 'source changed during query; retry: ' .. rec.path)
            if rec.encoding ~= 'utf-8' and rec.encoding ~= 'utf-8-bom' then
                raw = assert(xutils.to_utf8(raw, rec.encoding == 'gbk' and 'gbk' or 'auto'))
            end
        end
        local parsed = assert(require('codeoutline.parse').parse(rec.path, raw,
            { ranges = false, ordinary_bindings = true }))
        local function check(ok) assert(ok, 'source changed; refresh index before binding query: ' .. rec.path) end
        check(#parsed.nodes == #rec.nodes and #parsed.refs.name == #rec.refs.name)
        for i, n in ipairs(parsed.nodes) do
            check(n.qualified == rec.nodes[i].qualified and n.line == rec.nodes[i].line)
        end
        for i, name in ipairs(parsed.refs.name) do
            check(name == rec.refs.name[i] and parsed.refs.from[i] == rec.refs.from[i]
                and parsed.refs.line[i] == rec.refs.line[i] and parsed.refs.kind[i] == rec.refs.kind[i])
        end
        -- Keep only compact query evidence; source, tokens, and duplicate symbols die here.
        local data = { refs = { binding = parsed.refs.binding, js_receiver = parsed.refs.js_receiver },
            js_exports = parsed.js_exports, python_imports = parsed.python_imports, cpp_aliases = parsed.cpp_aliases,
            csharp_usings = parsed.csharp_usings, csharp_statics = parsed.csharp_statics,
            csharp_scopes = parsed.csharp_scopes, csharp_parameters = parsed.csharp_parameters, csharp_access = parsed.csharp_access }
        data.implementation_evidence = parsed.implementation_evidence
        data.automatic_events = parsed.automatic_events
        data.rust_imports, data.rust_public = parsed.rust_imports, parsed.rust_public
        local weight = #raw + #parsed.refs.name * 128 + #(parsed.js_exports or {}) * 256
            + #(parsed.python_imports or {}) * 256 + #(parsed.cpp_aliases or {}) * 256
            + #(parsed.csharp_usings or {}) * 256 + #(parsed.csharp_scopes or {}) * 256
            + #(parsed.csharp_parameters or {}) * 128 + #parsed.nodes * (parsed.implementation_evidence and 256 or 0)
            + #(parsed.rust_imports or {}) * 256 + #(parsed.rust_public or {}) * 32
            + #(parsed.automatic_events or {}) * 512
        if cache[f] then
            bytes = bytes - cache[f].weight; cache[f] = nil
            for i, old in ipairs(order) do if old == f then table.remove(order, i); break end end
        end
        while #order > 0 and (#order >= max_files or bytes + weight > max_bytes) do
            local old = table.remove(order, 1); bytes = bytes - cache[old].weight; cache[old] = nil
        end
        if weight <= max_bytes then
            cache[f] = { record = rec, data = data, weight = weight }
            order[#order + 1] = f; bytes = bytes + weight
        end
        C.stats.parses, C.stats.files, C.stats.bytes = C.stats.parses + 1, #order, bytes
        return data
    end
    function C.evidence(f, i)
        local rec = G.files[f]
        local value = evidence(rec, i)
        local kind = rec.refs.kind[i]
        if kind ~= 'call' and kind ~= 'member_call' and not (rec.language == 'csharp' and kind == 'new')
            and not (rec.language == 'cpp' and kind == 'ref') then return value end
        -- JS already keeps receiver barriers. Only a bare blocked call can be
        -- a newly supported lexical alias; typed/member calls need no reparse.
        if js(rec) and (kind ~= 'call' or value ~= '?') then return value end
        if js(rec) and not next(alias_hints(f)) then return value end
        local recv = rec.refs.recv[i]
        if rec.language == 'python' and (recv == 'self' or recv == 'cls') then return value end
        if rec.language == 'cpp' and recv == 'this' then return value end
        if rec.language == 'rust' and require('codeoutline.rust_packages').owner(G, f, ctx) then
            return require('codeoutline.rust_packages').guard(ctx, function() return evidence(C.data(f), i) or value end) or value
        end
        if js(rec) or rec.language == 'python' or rec.language == 'csharp' or rec.language == 'cpp'
            or (rec.language == 'java' or rec.language == 'kotlin') and kind == 'member_call' then
            return evidence(C.data(f), i) or value
        end
        return value
    end

    -- Renamed calls can only originate in the target file or an import chain
    -- leading to it. Build this cheap reverse map from existing import records.
    -- No indexed source is opened; workspace lookup may read package manifests.
    local reverse
    function C.candidates(wanted)
        local found, queue = {}, {}
        for id in pairs(wanted) do
            local f = G.node_file[id]
            if (js(G.files[f]) or G.files[f].language == 'python') and not found[f] then
                found[f] = true; queue[#queue + 1] = f
            end
        end
        if #queue == 0 then return found end
        if not reverse then
            reverse = {}
            local function add(f, target)
                if target then reverse[target] = reverse[target] or {}; reverse[target][f] = true end
            end
            local files = {}
            for _, f in ipairs(G.file_order) do files[#files + 1] = f end
            for _, f in ipairs(G.new_files or {}) do files[#files + 1] = f end
            for _, f in ipairs(files) do
                local rec = G.files[f]
                control.check()
                if js(rec) then
                    for _, imp in ipairs(rec.imports) do add(f, require('codeoutline.js_resolution').module(G, f, imp.path, ctx, imp.kind)) end
                elseif rec.language == 'python' then
                    local module = require('codeoutline.python_bindings').module
                    for _, imp in ipairs(rec.imports) do
                        add(f, module(G, f, imp.path))
                        for _, name in ipairs(imp.names or {}) do
                            local path = imp.path
                            if path:sub(-1) ~= '.' then path = path .. '.' end
                            add(f, module(G, f, path .. name))
                        end
                    end
                end
            end
        end
        local at = 1
        while at <= #queue do
            control.check()
            for f in pairs(reverse[queue[at]] or {}) do
                if not found[f] then found[f] = true; queue[#queue + 1] = f end
            end
            at = at + 1
        end
        return found
    end
    function C.aliases(f, wanted, candidates)
        if G.files[f].language == 'csharp' then
            return require('codeoutline.csharp_bindings').incoming_aliases(G, f, wanted, ctx)
        end
        if not candidates[f] then return {} end
        local rec, hits, resolved = G.files[f], {}, {}
        local imports = {}
        local relevant = false
        for id in pairs(wanted) do if G.node_file[id] == f then relevant = true; break end end
        local function matches(ids)
            for _, id in ipairs(ids) do if wanted[id] then return true end end
            return false
        end
        if js(rec) then
            local resolver = require('codeoutline.js_resolution')
            for _, imp in ipairs(rec.js_imports or {}) do
                local target = resolver.module(G, f, imp.path, ctx)
                if target and candidates[target] and (imp.imported == '*'
                    or matches(resolver.imported(G, f, imp.path, imp.imported, ctx))) then
                    relevant = true; imports[imp.local_name] = true
                end
            end
        elseif not relevant and rec.language == 'python' then
            local resolver = require('codeoutline.python_bindings')
            for _, imp in ipairs(rec.imports) do
                local target = resolver.module(G, f, imp.path)
                if target and candidates[target] then
                    if not imp.names then relevant = true; break end
                    for _, name in ipairs(imp.names) do
                        if matches(resolver.imported(G, f, imp.path, name, ctx)) then relevant = true; break end
                        local path = imp.path .. (imp.path:sub(-1) == '.' and '' or '.') .. name
                        local sub = resolver.module(G, f, path)
                        if sub and candidates[sub] then relevant = true; break end
                    end
                end
                if relevant then break end
            end
        end
        if not relevant then return hits end
        local analyze = not js(rec)
        if js(rec) then
            local roots = alias_hints(f)
            for id in pairs(wanted) do
                if G.node_file[id] == f and roots[G.nodes[id].name] then analyze = true; break end
            end
            for name in pairs(imports) do if roots[name] then analyze = true; break end end
        end
        for i, kind in ipairs(rec.refs.kind) do
            if kind == 'call' or kind == 'member_call' or imports[rec.refs.name[i]] or imports[rec.refs.recv[i]] then
                local value = analyze and C.evidence(f, i) or evidence(rec, i)
                local path = value and (value:match('^import:(.-)%z') or value:match('^py:import:(.-)%z'))
                if path then
                    local resolver = js(rec) and require('codeoutline.js_resolution') or require('codeoutline.python_bindings')
                    local target = resolver.module(G, f, path, ctx)
                    if not target or not candidates[target] then goto next_ref end
                end
                if value and (value:match('^node:') or value:match('^import:') or value:match('^py:'))
                    or imports[rec.refs.name[i]] or imports[rec.refs.recv[i]] then
                    if value == '' then value = nil end
                    local key = value or rec.refs.name[i] .. '\0' .. (rec.refs.recv[i] or '')
                    local targets = resolved[key]
                    if not targets then
                        if js(rec) then targets = require('codeoutline.js_resolution').resolve(G, f,
                            rec.refs.name[i], kind, rec.refs.recv[i], value, ctx)
                        else targets = require('codeoutline.python_bindings').resolve(G, f, value, ctx) end
                        targets = targets or {}; resolved[key] = targets
                    end
                    for _, id in ipairs(targets) do if wanted[id] then hits[i] = true; break end end
                end
            end
            ::next_ref::
        end
        return hits
    end
    return C
end

return M
