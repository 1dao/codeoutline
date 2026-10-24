-- codeoutline/parse.lua — per-file symbol extraction for the code index
-- behind the CodeExplore tool.
--   local parse = require('codeoutline.parse')
--   local result = parse.parse(path, source)   -- nil for unsupported files
--
-- Tokenizing lives in xscan.lua (the runtime's native `xscan` module when
-- present, else the pure-Lua implementation); each language is one file
-- under lang/.

local M = {}

local parsers = {}
local function parser(name)
    if not parsers[name] then parsers[name] = require('codeoutline.lang.' .. name) end
    return parsers[name]
end

M.EXTENSIONS = {
    c = 'c', h = 'c',
    py = 'python', pyi = 'python',
    java = 'java',
    kt = 'kotlin', kts = 'kotlin',
    lua = 'lua',
    cpp = 'cpp', cc = 'cpp', cxx = 'cpp', hpp = 'cpp', hh = 'cpp', hxx = 'cpp', ipp = 'cpp',
    go = 'go',
    js = 'javascript', jsx = 'javascript', mjs = 'javascript', cjs = 'javascript',
    ts = 'typescript', tsx = 'typescript', mts = 'typescript', cts = 'typescript',
    ets = 'arkts',
    cs = 'csharp',
    rs = 'rust',
}

-- Languages sharing one parser module; the language name is passed along.
local MODULE = { javascript = 'js', typescript = 'js', arkts = 'js' }

function M.language(path)
    local ext = path:match('%.([%w]+)$')
    return ext and M.EXTENSIONS[ext:lower()]
end

-- Returns the record and its tokens; positions in both exclude a UTF-8 BOM.
function M.parse_tokens(path, src, opts)
    local lang = M.language(path)
    local inferred, cpp_syntax
    if not lang and opts and (opts.language or opts.detect) then
        lang, inferred = require('codeoutline.language_detect').resolve(src, opts.language, opts.detect)
    end
    if not lang then return nil end
    if opts and opts.cpp_fragment then
        assert(not M.language(path) and (opts.cpp_fragment == 'c' or opts.cpp_fragment == 'cpp'))
        if src:find('\0', 1, true) then return nil end
        local detected = require('codeoutline.language_detect').resolve(src, nil, true)
        if detected and detected ~= 'c' and detected ~= 'cpp' then return nil end
        cpp_syntax = not not parser('cpp').looks_cpp(src)
        if lang == 'c' and cpp_syntax then lang = 'cpp' end
    end
    -- Strip a UTF-8 BOM so it is not read as part of the first token.
    if src:sub(1, 3) == '\239\187\191' then src = src:sub(4) end
    -- .h is shared by C and C++: sniff for C++-only syntax.
    if lang == 'c' and path:match('%.[hH]$') and parser('cpp').looks_cpp(src) then lang = 'cpp' end
    local rec, tokens = parser(MODULE[lang] or lang).parse(path, src, lang, opts)
    if opts and opts.cpp_fragment then rec.cpp_fragment, rec.cpp_fragment_cpp = opts.cpp_fragment, cpp_syntax or nil
    elseif inferred then rec.on_demand, rec.language_source = true, inferred end
    return rec, tokens
end

-- opts.ranges=false emits compact index nodes; default parsing retains positions.
-- opts.dispatch_only=true is transient query data, not an index record: it
-- retains parser nodes/refs and skips binding evidence and record packing.
function M.parse(path, src, opts)
    return (M.parse_tokens(path, src, opts))
end

return M
