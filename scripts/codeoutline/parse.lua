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
    lua = 'lua',
    cpp = 'cpp', cc = 'cpp', cxx = 'cpp', hpp = 'cpp', hh = 'cpp', hxx = 'cpp', ipp = 'cpp',
    go = 'go',
    js = 'javascript', jsx = 'javascript', mjs = 'javascript', cjs = 'javascript',
    ts = 'typescript', tsx = 'typescript', mts = 'typescript', cts = 'typescript',
    cs = 'csharp',
    rs = 'rust',
}

-- Languages sharing one parser module; the language name is passed along.
local MODULE = { javascript = 'js', typescript = 'js' }

function M.language(path)
    local ext = path:match('%.([%w]+)$')
    return ext and M.EXTENSIONS[ext:lower()]
end

-- opts.ranges=false emits compact index nodes; default parsing retains positions.
function M.parse(path, src, opts)
    local lang = M.language(path)
    if not lang then return nil end
    -- Strip a UTF-8 BOM so it is not read as part of the first token.
    if src:sub(1, 3) == '\239\187\191' then src = src:sub(4) end
    -- .h is shared by C and C++: sniff for C++-only syntax.
    if lang == 'c' and path:match('%.[hH]$') and parser('cpp').looks_cpp(src) then lang = 'cpp' end
    return (parser(MODULE[lang] or lang).parse(path, src, lang, opts))
end

return M
