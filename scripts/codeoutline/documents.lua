local parse = require('codeoutline.parse')
local paths = require('codeoutline.path')
local text = require('codeoutline.text')
local M = { MAX_BYTES = 1500000 }
local Doc = {}
Doc.__index = Doc

function M.path(uri)
    assert(type(uri) == 'string' and not uri:find('[%z\r\n]'), 'invalid document URI')
    local host, path = uri:match('^file://([^/?#]*)(/[^?#]*)$')
    if not path then return nil end
    assert(not path:gsub('%%(%x%x)', ''):find('%%'), 'invalid URI escape')
    path = path:gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end)
    assert(not path:find('[%z\r\n]'), 'invalid file path')
    if host ~= '' and host:lower() ~= 'localhost' then path = '//' .. host .. path
    else path = path:match('^/(%a:.*)$') or path end
    path = paths.normalize(path)
    local prefix, rest
    if path:match('^%a:/') then prefix, rest = path:sub(1, 3), path:sub(4)
    elseif path:sub(1, 2) == '//' then prefix, rest = '//', path:sub(3)
    else prefix, rest = '/', path:sub(2) end
    local parts = {}
    for part in rest:gmatch('[^/]+') do
        if part == '..' then assert(#parts > 0, 'path escapes its root'); parts[#parts] = nil
        elseif part ~= '.' then parts[#parts + 1] = part end
    end
    return prefix .. table.concat(parts, '/')
end

function M.uri(path)
    path = paths.normalize(path)
    local host = ''
    if path:sub(1, 2) == '//' then host, path = assert(path:match('^//([^/]+)(/.*)$')) end
    if path:match('^%a:/') then path = '/' .. path end
    local escaped = path:gsub('[^%w%-%._~/:]', function(c) return string.format('%%%02X', c:byte()) end)
    return 'file://' .. host .. escaped
end

function M.new(uri, source, version, language)
    assert(type(source) == 'string' and #source <= M.MAX_BYTES, 'document exceeds size limit')
    assert(text.valid(source) == source, 'document is not valid UTF-8')
    if source:sub(1, 3) == '\239\187\191' then source = source:sub(4) end
    local self = setmetatable({ uri = uri, path = M.path(uri), source = source,
        version = version, language = language, lines = { 0 }, line_units = { 0 },
        checkpoints = { offsets = { 0 }, units = { 0 } } }, Doc)
    local p, units, checkpoint = 1, 0, 0
    while p <= #source do
        local b = source:byte(p)
        if b == 13 then
            if source:byte(p + 1) == 10 then p = p + 1; units = units + 1 end
            units = units + 1
            self.lines[#self.lines + 1] = p
            self.line_units[#self.line_units + 1] = units
        elseif b == 10 then
            units = units + 1
            self.lines[#self.lines + 1] = p
            self.line_units[#self.line_units + 1] = units
        else
            local width = b < 128 and 1 or b < 224 and 2 or b < 240 and 3 or 4
            p, units = p + width - 1, units + (width == 4 and 2 or 1)
        end
        -- Sparse prefix counts keep repeated positions on long lines bounded.
        if p - checkpoint >= 512 then
            local points = self.checkpoints
            points.offsets[#points.offsets + 1], points.units[#points.units + 1] = p, units
            checkpoint = p
        end
        p = p + 1
    end
    return self
end

function Doc:position(offset)
    assert(type(offset) == 'number' and offset >= 0 and offset <= #self.source, 'invalid byte offset')
    local lo, hi = 1, #self.lines
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if self.lines[mid] <= offset then lo = mid else hi = mid - 1 end
    end
    local line = lo
    local next_line = self.lines[line + 1]
    if next_line then
        local last = next_line - 1
        if self.source:byte(next_line) == 10 and self.source:byte(last) == 13 then last = last - 1 end
        offset = math.min(offset, last)
    end
    local points = self.checkpoints
    lo, hi = 1, #points.offsets
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if points.offsets[mid] <= offset then lo = mid else hi = mid - 1 end
    end
    local units, p = points.units[lo], points.offsets[lo] + 1
    while p <= offset do
        local b = self.source:byte(p)
        local width = b < 128 and 1 or b < 224 and 2 or b < 240 and 3 or 4
        assert(p + width - 1 <= offset, 'offset splits a UTF-8 character')
        units, p = units + (width == 4 and 2 or 1), p + width
    end
    return { line = line - 1, character = units - self.line_units[line] }
end

function Doc:range(first, last)
    return { start = self:position(first), ['end'] = self:position(last) }
end

local extensions = { javascript = 'js', typescript = 'ts', python = 'py', csharp = 'cs', rust = 'rs', cpp = 'cpp' }
function Doc:parse()
    if self.parsed then return self.parsed end
    local name = self.path or ('document.' .. (extensions[self.language] or self.language or 'txt'))
    if not parse.language(name) and self.language then name = 'document.' .. (extensions[self.language] or self.language) end
    self.parsed = parse.parse(name, self.source) or { nodes = {} }
    return self.parsed
end

function M.read(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local raw = f:read(M.MAX_BYTES + 1); f:close()
    if not raw or #raw > M.MAX_BYTES then return nil end
    local source = xutils.to_utf8(raw)
    if not source then return nil end
    return M.new(M.uri(path), source)
end

return M
