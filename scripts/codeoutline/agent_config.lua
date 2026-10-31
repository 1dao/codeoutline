-- Small, lossless JSON/JSONC editor for MCP entries. No reserialization of
-- surrounding settings: comments, key order and unrelated bytes survive.
local M = {}
local function encode(value) return assert(xutils.json_pack(value)) end

local function parse(text)
    local pos, size = text:sub(1, 3) == '\239\187\191' and 4 or 1, #text
    local function skip()
        while pos <= size do
            if text:sub(pos, pos):match('%s') then pos = pos + 1
            elseif text:sub(pos, pos + 1) == '//' then
                pos = (text:find('\n', pos + 2, true) or size) + 1
            elseif text:sub(pos, pos + 1) == '/*' then
                pos = assert(text:find('*/', pos + 2, true), 'unterminated JSON comment') + 2
            else break end
        end
    end
    local function string_value()
        local start = pos
        assert(text:sub(pos, pos) == '"', 'expected JSON string')
        pos = pos + 1
        while pos <= size do
            local char = text:sub(pos, pos)
            if char == '\\' then pos = pos + 2
            elseif char == '"' then
                pos = pos + 1
                local value = xutils.json_unpack(text:sub(start, pos - 1))
                assert(type(value) == 'string', 'invalid JSON string')
                return value
            else pos = pos + 1 end
        end
        error('unterminated JSON string')
    end
    local value
    value = function(depth)
        assert(depth <= 100, 'JSON nesting exceeds 100')
        skip()
        local node = { start = pos, children = {}, kind = text:sub(pos, pos) }
        if node.kind == '{' or node.kind == '[' then
            local close = node.kind == '{' and '}' or ']'
            pos = pos + 1; skip()
            while text:sub(pos, pos) ~= close do
                local key, property_start
                if node.kind == '{' then
                    property_start = pos; key = string_value(); skip()
                    assert(text:sub(pos, pos) == ':', 'expected JSON colon'); pos = pos + 1
                    assert(node.children[key] == nil, 'duplicate JSON key: ' .. key)
                else key = #node.children + 1 end
                local child = value(depth + 1)
                child.property_start = property_start or child.start
                node.children[key] = child
                skip()
                if text:sub(pos, pos) == close then break end
                assert(text:sub(pos, pos) == ',', 'expected JSON comma')
                child.comma = pos; pos = pos + 1; skip()
            end
            node.close = pos; pos = pos + 1
        elseif node.kind == '"' then node.value = string_value()
        else
            local token = text:sub(pos):match('^[^%s,%]%}/]+')
            assert(token, 'expected JSON value')
            local decoded = xutils.json_unpack(token)
            assert(token == 'null' or decoded ~= nil, 'invalid JSON value')
            node.value = decoded; pos = pos + #token
        end
        node.finish = pos - 1
        return node
    end
    local root = value(0); skip(); assert(pos > size, 'unexpected text after JSON')
    assert(root.kind == '{', 'MCP config must be a JSON object')
    return root
end

local function same(node, expected)
    if type(expected) ~= 'table' then return node.value == expected end
    if node.kind ~= '{' and node.kind ~= '[' then return false end
    for key, val in pairs(expected) do
        if not node.children[key] or not same(node.children[key], val) then return false end
    end
    for key in pairs(node.children) do if expected[key] == nil then return false end end
    return true
end

function M.json(text, path, entry, remove, force)
    if text == '' then text = '{}\n' end
    local root = parse(text)
    local node = root
    for i, key in ipairs(path) do
        assert(node.kind == '{', 'MCP config parent must be an object')
        local child = node.children[key]
        if i == #path and child then
            if remove then
                local start, finish = child.property_start, child.finish
                if child.comma then finish = child.comma
                else
                    -- Only the immediately preceding comma belongs to this entry.
                    local nearest
                    for _, previous in pairs(node.children) do
                        if previous.comma and previous.comma < child.property_start then nearest = math.max(nearest or 0, previous.comma) end
                    end
                    if nearest then
                        return text:sub(1, nearest - 1) .. text:sub(nearest + 1, child.property_start - 1) .. text:sub(finish + 1), true
                    end
                end
                return text:sub(1, start - 1) .. text:sub(finish + 1), true
            end
            if same(child, entry) then return text, false end
            assert(force, 'codeoutline entry already exists with different settings; use --force to replace it')
            return text:sub(1, child.start - 1) .. encode(entry) .. text:sub(child.finish + 1), true
        elseif not child then
            if remove then return text, false end
            local nested = entry
            for j = #path, i + 1, -1 do nested = { [path[j]] = nested } end
            local last
            for _, previous in pairs(node.children) do
                if not last or previous.finish > last.finish then last = previous end
            end
            local prefix = text:sub(1, node.close - 1)
            if last and not last.comma then
                prefix = text:sub(1, last.finish) .. ',' .. text:sub(last.finish + 1, node.close - 1)
            end
            local nl = text:find('\r\n', 1, true) and '\r\n' or '\n'
            return prefix .. nl .. '  ' .. encode(key) .. ': ' .. encode(nested) .. nl .. text:sub(node.close), true
        end
        node = child
    end
end

function M.has(text, path)
    if text == '' then return false end
    local node = parse(text)
    for _, key in ipairs(path) do
        if node.kind ~= '{' or not node.children[key] then return false end
        node = node.children[key]
    end
    return true
end

-- TOML keeps all unrelated tables verbatim. Reject ambiguous inline/dotted
-- definitions rather than risk producing a duplicate table.
function M.toml(text, url, remove, force)
    local headers, multiline, parent_mcp = {}, nil, false
    local function classify_header(value)
        local parts, i = {}, 1
        while i <= #value do
            while value:sub(i, i):match('%s') do i = i + 1 end
            local char, part = value:sub(i, i)
            if char == '"' or char == "'" then
                local quote, start = char, i
                i = i + 1
                while i <= #value do
                    char = value:sub(i, i); i = i + 1
                    if quote == '"' and char == '\\' then i = i + 1
                    elseif char == quote then break end
                end
                assert(value:sub(i - 1, i - 1) == quote, 'invalid TOML table header')
                part = quote == '"' and xutils.json_unpack(value:sub(start, i - 1)) or value:sub(start + 1, i - 2)
            else
                part = value:sub(i):match('^[%w_-]+')
                assert(part, 'invalid TOML table header'); i = i + #part
            end
            parts[#parts + 1] = part
            while value:sub(i, i):match('%s') do i = i + 1 end
            if i <= #value then assert(value:sub(i, i) == '.', 'invalid TOML table header'); i = i + 1 end
        end
        return parts[1] == 'mcp_servers' and parts[2] == 'codeoutline', #parts == 2,
            parts[1] == 'mcp_servers' and #parts == 1
    end
    local pos = 1
    for line in (text .. '\n'):gmatch('(.-)\n') do
        local original_size = #line
        local bom = pos == 1 and line:sub(1, 3) == '\239\187\191' and 3 or 0
        if bom > 0 then line = line:sub(4) end
        if not multiline then
            local array_header = line:match('^%s*%[%[([^%[%]]+)%]%]%s*#?.*$')
            local header = array_header or line:match('^%s*%[([^%[%]]+)%]%s*#?.*$')
            assert(header or not line:match('^%s*%['), 'complex TOML table header requires manual editing')
            if header then
                local ours, base, parent = classify_header(header)
                parent_mcp = parent
                assert(not (array_header and ours), 'codeoutline cannot be a TOML array table')
                headers[#headers + 1] = { ours = ours, base = base, start = pos + bom }
            end
            local key_line = line:gsub('["\']', '')
            assert(not key_line:match('^%s*mcp_servers%s*=') and not key_line:match('^%s*mcp_servers%s*%.%s*codeoutline[%s%.=]')
                and not (parent_mcp and key_line:match('^%s*codeoutline[%s%.=]')),
                'inline or dotted MCP tables require manual editing; use --print codex')
        end
        -- Scan quoted strings so table-looking text in multiline prompts is ignored.
        local i = 1
        while i <= #line do
            if multiline then
                local close = line:find(multiline, i, true)
                if not close then break end
                multiline = nil; i = close + 3
            else
                local char, triple = line:sub(i, i), line:sub(i, i + 2)
                if char == '#' then break
                elseif triple == '"""' or triple == "'''" then multiline = triple; i = i + 3
                elseif char == '"' or char == "'" then
                    local quote = char; i = i + 1
                    while i <= #line do
                        char = line:sub(i, i); i = i + 1
                        if quote == '"' and char == '\\' then i = i + 1
                        elseif char == quote then break end
                    end
                else i = i + 1 end
            end
        end
        pos = pos + original_size + 1
    end
    assert(not multiline, 'unterminated TOML multiline string')
    local start, finish
    for i, header in ipairs(headers) do
        if header.ours and header.base then
            assert(not start, 'duplicate codeoutline TOML table')
            start = header.start; finish = #text + 1
            for j = i + 1, #headers do
                if not headers[j].ours then finish = headers[j].start; break end
            end
        end
    end
    local nl = text:find('\r\n', 1, true) and '\r\n' or '\n'
    local block = '[mcp_servers.codeoutline]' .. nl .. 'url = ' .. encode(url) .. nl
    if start then
        local old = text:sub(start, finish - 1)
        if not remove and old:gsub('%s+$', '') == block:gsub('%s+$', '') then return text, false end
        assert(remove or force, 'codeoutline entry already exists with different settings; use --force to replace it')
        return text:sub(1, start - 1) .. (remove and '' or block .. nl) .. text:sub(finish), true
    end
    for _, header in ipairs(headers) do
        assert(not header.ours, 'codeoutline TOML subtables require manual editing')
    end
    if remove then return text, false end
    return text .. (text == '' and '' or nl) .. block, true
end

-- Hermes uses a YAML block mapping. Keep other sections and servers byte for
-- byte, and decline flow/anchor/quoted-key forms that need a full YAML parser.
function M.yaml(text, url, remove, force)
    local lines, offsets, pos = {}, {}, 1
    for line in (text .. '\n'):gmatch('(.-)\n') do
        lines[#lines + 1] = line; offsets[#offsets + 1] = pos; pos = pos + #line + 1
    end
    local parent, finish, indent
    for i, line in ipairs(lines) do
        if line:match('^mcp_servers%s*:') then
            assert(not parent, 'duplicate YAML mcp_servers mapping')
            local rest = line:match('^mcp_servers%s*:%s*(.-)%s*\r?$'):gsub('%s*#.*$', '')
            assert(rest == '' or rest == '{}' or rest == 'null', 'inline YAML mcp_servers requires manual editing')
            parent = i
        elseif parent and not finish and line:match('^%S') and not line:match('^#') then finish = i end
    end
    local nl = text:find('\r\n', 1, true) and '\r\n' or '\n'
    if not parent then
        assert(not text:find('mcp_servers', 1, true), 'nonstandard YAML MCP mapping requires manual editing')
        if remove then return text, false end
        return text .. (text == '' and '' or nl) .. 'mcp_servers:' .. nl .. '  codeoutline:' .. nl
            .. '    url: ' .. encode(url) .. nl, true
    end
    finish = finish or #lines + 1
    local start, stop
    for i = parent + 1, finish - 1 do
        local spaces = lines[i]:match('^( +)%S')
        if spaces and not lines[i]:match('^%s*#') then indent = math.min(indent or #spaces, #spaces) end
    end
    indent = indent or 2
    for i = parent + 1, finish - 1 do
        local spaces = lines[i]:match('^( *)codeoutline%s*:')
        if spaces and #spaces == indent then
            assert(not start, 'duplicate YAML codeoutline entry'); start = i
        elseif start and not stop and lines[i]:match('^%s*%S') and not lines[i]:match('^%s*#') then
            local leading = lines[i]:match('^( *)')
            if #leading <= indent then stop = i end
        end
    end
    local block = string.rep(' ', indent) .. 'codeoutline:' .. nl .. string.rep(' ', indent + 2) .. 'url: ' .. encode(url) .. nl
    if start then
        local begin_at, end_at = offsets[start], offsets[stop or finish] or #text + 1
        local old = text:sub(begin_at, end_at - 1)
        if not remove and old:gsub('%s+$', '') == block:gsub('%s+$', '') then return text, false end
        assert(remove or force, 'codeoutline entry already exists with different settings; use --force to replace it')
        return text:sub(1, begin_at - 1) .. (remove and '' or block) .. text:sub(end_at), true
    end
    if remove then return text, false end
    local parent_end = offsets[parent] + #lines[parent]
    local parent_line = lines[parent]:gsub(':%s*{}', ':'):gsub(':%s*null', ':')
    return text:sub(1, offsets[parent] - 1) .. parent_line .. nl .. block .. text:sub(parent_end + 1), true
end

return M
