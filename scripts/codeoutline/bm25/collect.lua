-- Internal lexical document extraction. Base index records stay unchanged.
local control = require('codeoutline.shared.control')
local M = { weights = {3, 2, 1, 1} }

local stop_words = {}
for word in ([[
a an and are as at be by can could do does during for from had has have how
i if in is it of on or that the their them this to was were when where which
who will with would you your
]]):gmatch('%S+') do
    stop_words[word] = true
end

function M.tokenize(text)
    text = text:gsub('([A-Z])([A-Z][a-z])', '%1 %2')
    text = text:gsub('([a-z0-9])([A-Z])', '%1 %2'):lower()
    local counts, length = {}, 0
    for group in text:gmatch('[a-z0-9]+') do
        local pos = 1
        while pos <= #group do
            local token = group:match('^[a-z]+', pos) or group:match('^[0-9]+', pos)
            pos = pos + #token
            if not stop_words[token] then
                local ending = token:sub(-2)
                if #token > 4 and token:sub(-1) == 's'
                    and ending ~= 'ss' and ending ~= 'us' and ending ~= 'is' then
                    token = token:sub(1, -2)
                end
                counts[token] = (counts[token] or 0) + 1
                length = length + 1
            end
        end
    end
    return counts, length
end

local function line_offsets(source)
    local offsets, pos = {1}, 1
    while true do
        local eol = source:find('\n', pos, true)
        if not eol then return offsets end
        pos = eol + 1
        offsets[#offsets + 1] = pos
    end
end

-- Scan only the lexical gap above the declaration. The tokenizer excludes
-- comments but keeps string spans, including Lua long strings.
local function leading_lua_doc(tokens, start, previous_end)
    local gap = tokens.src:sub(previous_end + 1, start - 1)
    if not gap:find('--', 1, true) then return '' end
    local comments, pos, standalone = {}, 1, previous_end == 0
    while pos <= #gap do
        local space = gap:match('^%s*', pos)
        pos = pos + #space
        local _, breaks = space:gsub('\n', '')
        if breaks > 1 then comments = {} end
        if breaks > 0 then standalone = true end
        if pos > #gap then break end
        if gap:sub(pos, pos + 1) ~= '--' then return '' end
        local _, open_end, equals = gap:find('^%-%-%[(=*)%[', pos)
        local first, last
        if open_end then
            local close_start, close_end = gap:find(']' .. equals .. ']', open_end + 1, true)
            if not close_start then return '' end
            first, last, pos = open_end + 1, close_start - 1, close_end + 1
        else
            local eol = gap:find('\n', pos, true) or #gap + 1
            first, last, pos = pos + 2, eol - 1, eol
        end
        if standalone then comments[#comments + 1] = gap:sub(first, last) end
        standalone = false
    end
    return table.concat(comments, '\n'):sub(1, 512)
end

function M.file(abs, rel, size, crc, language, documents)
    control.check()
    local file = assert(io.open(abs, 'rb'))
    local raw = file:read(size + 1) or ''
    assert(file:close())
    local actual = xcompress and xcompress.crc32 and xcompress.crc32(raw) or xutils.sha256_hex(raw)
    assert(#raw == size and actual == crc, 'source changed during BM25 build: ' .. rel)
    -- The tokenizer only indexes ASCII. Retaining raw bytes if decoding is
    -- unavailable keeps ASCII terms and the base index's line coordinates.
    local source = xutils.to_utf8(raw) or raw
    if source:sub(1, 3) == '\239\187\191' then source = source:sub(4) end
    local offsets = line_offsets(source)
    local tokens = language == 'lua' and require('codeoutline.lang.lua').lang:tokenize(source)
    local totals, encoded, comment_count = {0, 0, 0, 0}, {}, 0
    local token = 1
    for i, document in ipairs(documents) do
        if i % 128 == 0 then control.check() end
        local id, name, line, end_line = table.unpack(document)
        local first = assert(offsets[line], 'invalid BM25 source line: ' .. rel)
        local last = math.min((offsets[end_line + 1] or #source + 1) - 1,
            (offsets[line + 40] or #source + 1) - 1, first + 2047)
        local doc = ''
        if tokens then
            while token <= tokens.n and tokens.s[token] < first do token = token + 1 end
            doc = leading_lua_doc(tokens, first, tokens.e[token - 1] or 0)
            if doc:find('%S') then comment_count = comment_count + 1 end
        end
        local fields = {}
        for field, value in ipairs({name, rel, source:sub(first, last), doc}) do
            local terms, length = M.tokenize(value)
            fields[field] = {terms, length}
            totals[field] = totals[field] + length
        end
        encoded[i] = {id, fields}
    end
    return {status = 'parsed', terms = cmsgpack.pack(encoded), totals = totals, comments = comment_count}
end

return M
