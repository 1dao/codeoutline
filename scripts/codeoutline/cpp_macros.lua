-- Query-owned project macro visibility. No expansion or compiler execution.
local M = { MAX_FILES = 128, MAX_BYTES = 8 * 1024 * 1024, MAX_SUMMARY_BYTES = 1024 * 1024, MAX_EVENTS = 20000,
    MAX_DIRECTIVES = 4096, MAX_DEPTH = 32, MAX_RESULTS = 4096 }
local control = require('codeoutline.control')
local scanners = {}
local UNKNOWN = {}
local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end
local function conjunction(a, b) if a == false or b == false then return false end; if a == true and b == true then return true end end
local function disjunction(a, b) if a == true or b == true then return true end; if a == false and b == false then return false end end
local function negate(a) if a ~= nil then return not a end end
local function defined(env, name)
    local value = env[name]
    if value == false then return false end
    if value and value ~= UNKNOWN then return true end
end

local function condition(expr, env, depth)
    depth = (depth or 0) + 1
    if depth > 16 then return nil end
    expr = trim(expr)
    local level, split_or, split_and = 0
    for i = 1, #expr do
        local c = expr:sub(i, i)
        if c == '(' then level = level + 1 elseif c == ')' then level = level - 1 end
        if level == 0 then
            local op = expr:sub(i, i + 1)
            if op == '||' then split_or = i elseif op == '&&' then split_and = i end
        end
        if level < 0 then return nil end
    end
    if level ~= 0 then return nil end
    local at = split_or or split_and
    if at then
        local a, b = condition(expr:sub(1, at - 1), env, depth), condition(expr:sub(at + 2), env, depth)
        if split_or then return disjunction(a, b) end
        return conjunction(a, b)
    end
    if expr:sub(1, 1) == '(' and expr:sub(-1) == ')' then return condition(expr:sub(2, -2), env, depth) end
    if expr:sub(1, 1) == '!' then return negate(condition(expr:sub(2), env, depth)) end
    local name = expr:match('^defined%s*%(%s*([%a_][%w_]*)%s*%)$') or expr:match('^defined%s+([%a_][%w_]*)$')
    if name then return defined(env, name) end
    local number = tonumber((expr:gsub('[uUlL]+$', '')))
    if number then return number ~= 0 end
    if expr:match('^[%a_][%w_]*$') then
        local value = env[expr]
        if value == false then return false end
        if value and value ~= UNKNOWN and value.number then return value.number ~= 0 end
    end
end

local function scanner_for(language)
    local scanner = scanners[language]
    if not scanner then
        local config = {}
        for k, v in pairs(require('codeoutline.lang.' .. language).config) do config[k] = v end
        config.pp_first_branch = false
        scanner = require('codeoutline.xscan').lang(config); scanners[language] = scanner
    end
    return scanner
end

function M.collect(r, T, all_branches)
    if r.language ~= 'c' and r.language ~= 'cpp' then return end
    local result = {}; r.cpp_macros = result
    if not T.src:find('#', 1, true) then return end
    local scanner = scanner_for(r.language)
    local source = T.src
    if r.language == 'cpp' and source:find('R"', 1, true) then
        local starts = {}
        for i = 1, T.n do
            if T.k[i] == 'str' then
                local prefix = T:text(i):match('^([LuU8]*R)"')
                if prefix then starts[T.s[i] + #prefix - 1] = true end
            elseif T.k[i] == 'id' and T:text(i) == 'u8R' and T.s[i + 1] == T.e[i] + 1 and T:text(i + 1):sub(1, 1) == '"' then
                starts[T.e[i]] = true -- scanners accepting at most two prefix characters
            end
        end
        local parts, at = {}, 1
        while true do
            local first, last, delimiter = source:find('R"([^%s%(%)"\\]*)%(', at)
            if not first then break end
            if not starts[first] or #delimiter > 16 then at = last + 1
            else
                local close = source:find(')' .. delimiter .. '"', last + 1, true)
                if not close then result.incomplete = true; return end
                parts[#parts + 1] = { first = first, last = close + #delimiter + 1 }
                at = close + #delimiter + 2
            end
        end
        local pieces, previous = {}, 1
        for _, span in ipairs(parts) do
            pieces[#pieces + 1] = source:sub(previous, span.first - 1)
            pieces[#pieces + 1] = source:sub(span.first, span.last):gsub('[^\r\n]', ' ')
            previous = span.last + 1
        end
        pieces[#pieces + 1] = source:sub(previous)
        source = table.concat(pieces)
    end
    local full = source == T.src and (all_branches or not source:find('#%s*if')) and T or scanner:tokenize(source)
    local nodes = {}
    for i, n in ipairs(r.nodes) do
        if n.kind == 'macro' then nodes[n.line .. '\0' .. n.name] = i end
    end
    for i = 1, full.n do
        if i % 4096 == 0 then control.check() end
        if full.k[i] == 'dir' then
            if #result >= M.MAX_DIRECTIVES then result.incomplete = true; break end
            local raw = full:text(i):gsub('\\\r?\n', ' ')
            local kind, rest = raw:match('^#%s*(%a+)%s*(.*)$')
            local e = { kind = kind, line = full:line(i) }
            if kind == 'include' then
                e.path = rest:match('^"([^"]+)"') or rest:match('^<([^>]+)>')
                e.system = rest:sub(1, 1) == '<'
            else
                rest = trim(rest:gsub('/%*.-%*/', ' '):gsub('//[^\n]*', ''))
                e.name = rest:match('^([%a_][%w_]*)')
                if kind == 'define' and e.name then
                    local body = rest:sub(#e.name + 1)
                    e.callable = body:sub(1, 1) == '('
                    e.number = not e.callable and tonumber((trim(body):gsub('[uUlL]+$', ''))) or nil
                    e.node = nodes[e.line .. '\0' .. e.name]
                    -- Recursive wrapper expansion needs expansion semantics.
                    e.recursive = e.callable and body:find('%f[%w_]' .. e.name .. '%f[^%w_]') ~= nil
                elseif kind == 'if' or kind == 'elif' then e.expression = rest
                elseif kind == 'pragma' then e.once = trim(rest) == 'once' end
            end
            result[#result + 1] = e
        end
    end
    if result[1] and result[2] and result[1].kind == 'ifndef' and result[2].kind == 'define'
        and result[1].name == result[2].name then result.guard = result[1].name end
end

function M.summary(rec, source)
    if source:sub(1, 3) == '\239\187\191' then source = source:sub(4) end
    local r = { language = rec.language, nodes = rec.nodes }
    M.collect(r, scanner_for(rec.language):tokenize(source), true)
    return r.cpp_macros
end

function M.context(G, ctx)
    if ctx.cpp_macro_context then return ctx.cpp_macro_context end
    local C = { stats = { files = 0, bytes = 0, summary_bytes = 0, events = 0, checks = 0 }, incomplete = false }
    ctx.cpp_macro_context = C
    local summaries, results, result_count = {}, {}, 0
    local function limited() C.incomplete = true; return nil end
    local function data(f)
        if summaries[f] then return summaries[f] end
        local rec = G.files[f]
        if C.stats.files >= M.MAX_FILES or C.stats.bytes + (rec.size or 0) > M.MAX_BYTES then return limited() end
        local value = ctx.ordinary.macros(f)
        if not value or value.incomplete then return limited() end
        local weight = #value * 192
        for _, e in ipairs(value) do weight = weight + #(e.name or '') + #(e.expression or '') + #(e.path or '') end
        if C.stats.summary_bytes + weight > M.MAX_SUMMARY_BYTES then return limited() end
        C.stats.summary_bytes = C.stats.summary_bytes + weight
        summaries[f] = value; C.stats.files = C.stats.files + 1; C.stats.bytes = C.stats.bytes + (rec.size or 0)
        return value
    end
    -- Only definition navigation opts into ambiguous include alternatives;
    -- execution queries keep their own strict, separately cached result.
    function C.resolve(f, name, line, declarations)
        local key = f .. '\0' .. name .. '\0' .. line .. (declarations and '\0declarations' or '')
        if results[key] then return results[key][1], results[key][2], results[key][3] end
        if result_count >= M.MAX_RESULTS then limited(); return {}, true end
        C.stats.checks = C.stats.checks + 1
        local env, once, active_files, definitions = {}, {}, {}, {}
        local failed = false
        local function walk(file, cutoff, parent, depth)
            control.check()
            if depth > M.MAX_DEPTH then limited(); failed = true; return end
            if active_files[file] or once[file] then return end
            local events = data(file)
            if not events then failed = true; return end
            -- Conventional include guards are initially absent unless a source
            -- directive established their state. Arbitrary build flags stay unknown.
            if events.guard and env[events.guard] == nil and parent == true then env[events.guard] = false end
            active_files[file] = true
            local stack, active = {}, parent
            for _, e in ipairs(events) do
                if e.line > cutoff then break end
                C.stats.events = C.stats.events + 1
                if C.stats.events % 128 == 0 then control.check() end
                if C.stats.events > M.MAX_EVENTS then limited(); failed = true; break end
                local kind = e.kind
                if kind == 'if' or kind == 'ifdef' or kind == 'ifndef' then
                    local test
                    if kind == 'if' then test = condition(e.expression, env)
                    else test = defined(env, e.name); if kind == 'ifndef' then test = negate(test) end end
                    stack[#stack + 1] = { parent = active, taken = test }
                    active = conjunction(active, test)
                elseif kind == 'elif' or kind == 'else' then
                    local frame = stack[#stack]
                    if not frame then failed = true; break end
                    local test = kind == 'else' and true or condition(e.expression, env)
                    active = conjunction(frame.parent, conjunction(negate(frame.taken), test))
                    frame.taken = disjunction(frame.taken, test)
                elseif kind == 'endif' then
                    local frame = table.remove(stack)
                    if not frame then failed = true; break end
                    active = frame.parent
                elseif active ~= false then
                    if (kind == 'define' or kind == 'undef') and e.name then
                        if e.name == name then
                            if active == true then definitions = {} end
                            if kind == 'define' and e.node then definitions[G.id_of[file][e.node]] = true end
                        end
                        if active == nil then env[e.name] = UNKNOWN
                        elseif kind == 'undef' then env[e.name] = false
                        else env[e.name] = { callable = e.callable, number = e.number, node = e.node,
                            file = file, recursive = e.recursive } end
                    elseif kind == 'pragma' and e.once and active == true then once[file] = true
                    elseif kind == 'include' then
                        if not e.path then env[name] = UNKNOWN
                        else
                            local targets = require('codeoutline.cpp_includes').resolve(G, file, e, ctx)
                            if #targets == 1 then walk(targets[1], math.huge, active, depth + 1)
                            elseif #targets > 1 then
                                if declarations then
                                    -- F12 may show alternatives without choosing a
                                    -- build's include path. Evaluate each header
                                    -- independently: sibling include guards, undef
                                    -- and pragma once must not affect each other.
                                    local original_env, original_once, original_definitions = env, once, definitions
                                    local candidates = {}
                                    local function copy(values)
                                        local result = {}; for k, v in pairs(values) do result[k] = v end; return result
                                    end
                                    for _, target in ipairs(targets) do
                                        env, once, definitions = copy(original_env), copy(original_once), copy(original_definitions)
                                        walk(target, math.huge, active, depth + 1)
                                        for id in pairs(definitions) do candidates[id] = true end
                                        if failed then break end
                                    end
                                    env, once, definitions = original_env, original_once, candidates
                                end
                                env[name] = UNKNOWN
                            end
                            -- External/unindexed headers are not interpreted.
                        end
                    end
                end
            end
            active_files[file] = nil
        end
        walk(f, line, true, 1)
        local value, ids, handled = env[name], {}, true
        if not failed and (value == false or value == nil) then handled = false
        elseif not failed and value ~= UNKNOWN and value and value.callable and value.node and not value.recursive then
            ids[1] = G.id_of[value.file][value.node]
        end
        -- Definition navigation may inspect the declarations reached on an
        -- unknown branch without asserting an execution edge. An unconditional
        -- redefine/undef clears older candidates; directives after the call and
        -- known-false branches never contribute. Graph resolution stays strict.
        local sites = {}
        if not failed then for id in pairs(definitions) do sites[#sites + 1] = id end end
        table.sort(sites)
        result_count = result_count + 1; results[key] = { ids, handled, sites }
        return ids, handled, sites
    end
    return C
end

function M.resolve(G, f, name, line, ctx, declarations)
    if not line or not ctx or (G.files[f].language ~= 'c' and G.files[f].language ~= 'cpp') then return nil end
    local candidate = false
    for i, id in ipairs(G.by_name[name] or {}) do
        if i % 128 == 0 then control.check() end
        if G.nodes[id].kind == 'macro' then candidate = true; break end
    end
    if not candidate then return nil end
    local ids, handled, definitions = M.context(G, ctx).resolve(f, name, line, declarations)
    return handled and ids or false, definitions
end

return M
