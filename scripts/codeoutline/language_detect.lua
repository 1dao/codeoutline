-- Conservative, query-only language selection for unknown filenames.
local M = { MAX_SAMPLE = 65536 }
local aliases = { ['c++'] = 'cpp', ['c#'] = 'csharp', javascriptreact = 'javascript',
    typescriptreact = 'typescript', jsx = 'javascript', tsx = 'typescript', ets = 'arkts' }
local supported = { c = true, cpp = true, lua = true, python = true, java = true,
    kotlin = true, go = true, javascript = true, typescript = true, arkts = true,
    csharp = true, rust = true }

-- Ignore strings and comments so embedded examples cannot choose a parser.
local function code(source)
    local parts, i, first = {}, 1, 1
    local function mask(last)
        parts[#parts + 1] = source:sub(first, i - 1)
        parts[#parts + 1] = source:sub(i, last):gsub('[^\r\n]', ' ')
        i, first = last + 1, last + 1
    end
    while i <= #source do
        if i % 4096 == 0 then require('codeoutline.control').check() end
        local pair, c = source:sub(i, i + 1), source:sub(i, i)
        local lua_comment = pair == '--' and source:match('^%-%-(%[=*%[)', i)
        if lua_comment then
            local ending = lua_comment:gsub('%[', ']')
            local close = source:find(ending, i + 2 + #lua_comment, true)
            mask(close and close + #ending - 1 or #source)
        elseif pair == '/*' then
            local close = source:find('*/', i + 2, true); mask(close and close + 1 or #source)
        elseif pair == '//' or pair == '--' then
            mask((source:find('\n', i + 2, true) or (#source + 1)) - 1)
        elseif c == '#' and not source:match('^#%s*include%f[%W]', i)
            and not source:match('^#%s*define%f[%W]', i) then
            mask((source:find('\n', i + 1, true) or (#source + 1)) - 1)
        elseif c == '"' or c == "'" or c == '`' then
            local triple = source:sub(i, i + 2) == string.rep(c, 3)
            local j = i + (triple and 3 or 1)
            local ending = triple and string.rep(c, 3) or c
            while j <= #source do
                if source:sub(j, j) == '\\' then j = j + 2
                elseif source:sub(j, j + #ending - 1) == ending then j = j + #ending; break
                else j = j + 1 end
            end
            mask(math.min(#source, j - 1))
        elseif c == '[' and source:match('^%[=*%[', i) then
            local open = source:match('^(%[=*%[)', i)
            local ending = open:gsub('%[', ']')
            local close = source:find(ending, i + #open, true)
            mask(close and close + #ending - 1 or #source)
        else i = i + 1 end
    end
    parts[#parts + 1] = source:sub(first)
    return '\n' .. table.concat(parts)
end

function M.resolve(source, hint, detect)
    local language = type(hint) == 'string' and hint:lower()
    language = aliases[language] or language
    if supported[language] then return language, 'editor' end
    if not detect or source:find('%z') then return nil end
    local sample = source:sub(1, M.MAX_SAMPLE)
    local shebang = sample:match('^#!([^\r\n]+)')
    if shebang then
        if shebang:find('python', 1, true) then return 'python', 'syntax' end
        if shebang:find('lua', 1, true) then return 'lua', 'syntax' end
        if shebang:find('node', 1, true) then return 'javascript', 'syntax' end
        return nil
    end
    if sample:find('```', 1, true) or sample:lower():find('<!doctype', 1, true)
        or sample:lower():find('<html', 1, true) then return nil end
    local s, choices = code(sample), {}
    local function add(lang, yes) if yes then choices[lang] = true end end
    add('lua', s:find('%f[%w_]local%s+function%s+[%w_]+%s*%(')
        or s:find('%f[%w_]local%s+[%w_]+%s*=%s*function%s*%(') and s:find('%f[%w_]end%f[%W]')
        or s:find('%f[%w_]function%s+[%w_%.:]+%s*%(') and s:find('%f[%w_]end%f[%W]'))
    add('python', s:find('\n%s*def%s+[%w_]+%s*%([^\n]-%)%s*[:%-]')
        or s:find('\n%s*class%s+[%w_]+[^\n]-:%s*\n'))
    add('rust', s:find('%f[%w_]fn%s+[%w_]+%s*[<(]') and s:find('{', 1, true))
    add('go', s:find('\n%s*package%s+[%w_]+') and s:find('%f[%w_]func%s+[%w_(]'))
    add('kotlin', s:find('%f[%w_]fun%s+[%w_]+%s*[<(]'))
    add('java', (s:find('%f[%w_]package%s+[%w_%.]+%s*;') or s:find('%f[%w_]import%s+java%.'))
        and (s:find('%f[%w_]class%s+') or s:find('%f[%w_]interface%s+')))
    add('csharp', s:find('%f[%w_]using%s+System[%s%.;]')
        and (s:find('%f[%w_]class%s+') or s:find('%f[%w_]namespace%s+')))
    local js = s:find('%f[%w_]function%s+[%w_$]+%s*%([^)]*%)%s*{')
        or s:find('%f[%w_]const%s+[%w_$]+[^\n]-=>')
        or s:find('%f[%w_]export%s+default%f[%W]')
    local ts = s:find('%f[%w_]interface%s+[%w_$]+%s*{') and not choices.java
            and (s:find('%f[%w_]export%s+interface%f[%W]') or s:find(':%s*[%w_$]+'))
        or js and s:find(':%s*number%f[%W]')
    if s:find('@Component%f[%W]') and s:find('%f[%w_]struct%s+') then choices.arkts = true
    elseif ts then choices.typescript = true
    elseif js then choices.javascript = true end
    local cpp = s:find('%f[%w_]std%s*::') or s:find('%f[%w_]template%s*<')
        or s:find('%f[%w_]public%s*:') or s:find('%f[%w_]extern%s+%s*{')
    local c = s:find('#%s*include%f[%W]') or s:find('%f[%w_]typedef%s+struct%f[%W]')
    if cpp then choices.cpp = true elseif c then choices.c = true end
    local found
    for lang in pairs(choices) do if found then return nil end; found = lang end
    return found, found and 'syntax' or nil
end

return M
