-- index.lua — per-project symbol index: which files exist, what each one
-- defines and calls, kept fresh incrementally and cached on disk.
--
--   local index = require('codeoutline.index')
--   local idx = index.open('C:/src/proj')        -- loads the cache if present
--   local stats = idx:refresh()                   -- reparses only changed files
--   idx:save()
--
-- Change detection uses xutils.stat (size + mtime) when the runtime has it;
-- otherwise it reads the file and compares size + CRC-32, which still skips
-- the parse (the expensive part) for unchanged files.

local ci = require('codeoutline.parse')

local M = {}

-- Cache version: a checksum of the parser sources, so any parser change
-- rebuilds stale caches instead of silently reusing old parse results.
M.VERSION = (function()
    local parts = {}
    for _, m in ipairs({ 'xscan', 'common', 'parse', 'lang.c', 'lang.cpp', 'lang.lua', 'lang.python',
        'lang.java', 'lang.go', 'lang.js', 'lang.csharp', 'lang.rust' }) do
        local file = package.searchpath and package.searchpath('codeoutline.' .. m, package.path)
        local h = file and io.open(file, 'rb')
        if h then parts[#parts + 1] = h:read('a'); h:close() end
    end
    local blob = table.concat(parts)
    local sum = #blob
    for i = 1, #blob, 7 do sum = (sum * 33 + blob:byte(i)) % 2147483647 end
    return 'p' .. sum
end)()
-- Generated amalgamations (sqlite3.c, minified bundles) cost more to index
-- than they give back; skip files above this size unless configured.
M.MAX_FILE_BYTES = 1500000

local Index = {}
Index.__index = Index

local function norm(p)
    p = p:gsub('\\', '/')
    if #p > 1 then p = p:gsub('/+$', '') end
    return p
end

local function home()
    return os.getenv('USERPROFILE') or os.getenv('HOME') or '.'
end

-- Cache file name derived from the root so projects don't collide.
local function cache_path_for(root)
    local slug = root:gsub('^%a:', function(d) return d:lower() end):gsub('[^%w]+', '_'):gsub('^_+', '')
    return norm(home()) .. '/.codeoutline/cache/' .. slug .. '.idx'
end

local function slurp(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end

local function checksum(s)
    if xcompress and xcompress.crc32 then return xcompress.crc32(s) end
    -- Fallback when xcompress is missing: a cheap rolling hash of the ends
    -- plus the length. Weaker, but only decides whether to reparse.
    local h = #s
    for i = 1, math.min(#s, 4096) do h = (h * 31 + s:byte(i)) % 4294967296 end
    for i = math.max(1, #s - 4095), #s do h = (h * 31 + s:byte(i)) % 4294967296 end
    return h
end

-- Characters a shell interprets even inside double quotes (cmd: %VAR%,
-- !VAR!, the quote itself; sh: $, backtick, backslash) plus newlines. The
-- file listing runs `rg` through io.popen -- the runtime has no argv spawn on
-- Windows -- so a root is only accepted when quoting it is inert.
-- (backslashes are normalized to / first, so any left came from elsewhere)
local UNSAFE = '["%%!$`\\\r\n]'

-- Validate a project root: an existing directory whose path is safe to quote.
-- Returns the normalized root, or nil and a reason.
function M.check_root(root)
    if type(root) ~= 'string' or root == '' then return nil, 'root must be a non-empty path' end
    local r = norm(root)
    if r:find(UNSAFE) then
        return nil, 'root contains characters that are unsafe in a shell command: ' .. root
    end
    if xutils and xutils.stat then
        local st = xutils.stat(r)
        if not st or st.type ~= 'directory' then return nil, 'root is not a directory: ' .. root end
    elseif xutils and xutils.list_dir then
        if not xutils.list_dir(r, 1) then return nil, 'root is not a directory: ' .. root end
    end
    return r
end

function M.open(root, opts)
    opts = opts or {}
    local checked, why = M.check_root(root)
    if not checked then error(why, 2) end
    root = checked
    local self = setmetatable({
        root = norm(root),
        cache_path = opts.cache_path or cache_path_for(norm(root)),
        max_bytes = opts.max_file_bytes or M.MAX_FILE_BYTES,
        lister = opts.lister,       -- 'rg' | 'walk' | nil (rg when it runs here)
        files = {},          -- rel path -> record
        generation = 0,      -- bumped on every change; graph caches key on it
    }, Index)
    self:load()
    return self
end

function Index:load()
    local data = slurp(self.cache_path)
    if not data or not cmsgpack then return false end
    local ok, t = pcall(cmsgpack.unpack, data)
    if not ok or type(t) ~= 'table' or t.version ~= M.VERSION or t.root ~= self.root then return false end
    for _, rec in ipairs(t.files or {}) do self.files[rec.path] = rec end
    self.generation = self.generation + 1
    return true
end

function Index:save()
    if not cmsgpack then return false end
    local list = {}
    for _, rec in pairs(self.files) do list[#list + 1] = rec end
    table.sort(list, function(a, b) return a.path < b.path end)
    local blob = cmsgpack.pack({ version = M.VERSION, root = self.root, files = list })
    local d = self.cache_path:match('^(.*)/[^/]*$')
    if d and xutils and xutils.mkdir_p then xutils.mkdir_p(d) end
    local tmp = self.cache_path .. '.tmp'
    local f = io.open(tmp, 'wb')
    if not f then return false end
    f:write(blob)
    f:close()
    os.remove(self.cache_path)
    return os.rename(tmp, self.cache_path) ~= nil
end

-- Supported source files under the root, honoring .gitignore via ripgrep.
-- ripgrep lists files honoring every .gitignore; probe once whether it runs
-- here (Android has no rg, and there a Lua walk takes over).
local has_rg
local function rg_available()
    if has_rg == nil then
        has_rg = false
        if io.popen then
            local ok, p = pcall(io.popen, 'rg --version' .. (package.config:sub(1, 1) == '\\' and ' 2>nul' or ' 2>/dev/null'))
            if ok and p then
                has_rg = (p:read('a') or ''):find('ripgrep', 1, true) ~= nil
                p:close()
            end
        end
    end
    return has_rg
end

-- Directories the walk never enters, besides hidden ones (like rg's default).
M.WALK_SKIP = { node_modules = true, __pycache__ = true }
M.MAX_WALK_FILES = 100000

-- Root .gitignore, the common subset: `name`, `*.ext`, `dir/`, `/anchored`,
-- `a/b` (anchored), `**`. Negations are ignored (keep the file listed).
local function load_ignore(root)
    local rules = {}
    local f = io.open(root .. '/.gitignore', 'rb')
    if not f then return rules end
    for raw in f:lines() do
        local line = raw:gsub('\r$', ''):gsub('%s+$', '')
        if line ~= '' and not line:match('^#') and not line:match('^!') then
            local dir_only = line:sub(-1) == '/'
            if dir_only then line = line:sub(1, -2) end
            local anchored = line:sub(1, 1) == '/' or line:find('/', 1, true) ~= nil
            line = line:gsub('^/', '')
            local pat = line:gsub('[%^%$%(%)%%%.%[%]%+%-]', '%%%0')
                :gsub('%*%*/', '\1'):gsub('%*%*', '\2'):gsub('%*', '[^/]*'):gsub('%?', '[^/]')
                :gsub('\1', '.-'):gsub('\2', '.*')
            rules[#rules + 1] = { pat = '^' .. pat .. '$', dir_only = dir_only, anchored = anchored }
        end
    end
    f:close()
    return rules
end

local function ignored(rules, rel, name, is_dir)
    for _, r in ipairs(rules) do
        if (is_dir or not r.dir_only) and (r.anchored and rel or name):find(r.pat) then return true end
    end
    return false
end

-- Supported files under the root without a subprocess (xutils.list_dir).
function Index:walk_files()
    local out = {}
    if not (xutils and xutils.list_dir) then return out end
    local rules = load_ignore(self.root)
    local dirs = { '' }
    while #dirs > 0 and #out < M.MAX_WALK_FILES do
        local rel_dir = table.remove(dirs)
        local entries = xutils.list_dir(rel_dir == '' and self.root or (self.root .. '/' .. rel_dir))
        for _, e in ipairs(entries or {}) do
            local name = e.name
            local rel = rel_dir == '' and name or (rel_dir .. '/' .. name)
            if name:sub(1, 1) ~= '.' and not ignored(rules, rel, name, e.dir) then
                if e.dir then
                    if not M.WALK_SKIP[name] then dirs[#dirs + 1] = rel end
                elseif ci.language(name) then
                    out[#out + 1] = rel
                end
            end
        end
    end
    table.sort(out)
    return out
end

function Index:list_files()
    if self.lister == 'walk' or (self.lister ~= 'rg' and not rg_available()) then
        return self:walk_files()
    end
    local globs = {}
    local exts = {}
    for ext in pairs(ci.EXTENSIONS) do exts[#exts + 1] = ext end
    table.sort(exts)
    for _, ext in ipairs(exts) do globs[#globs + 1] = '-g "*.' .. ext .. '"' end
    -- self.root passed check_root() in open(); `--` stops rg from reading a
    -- root that starts with '-' as an option (`--pre=<cmd>` runs a command).
    assert(M.check_root(self.root), 'unsafe root')
    local cmd = 'rg --files --no-messages ' .. table.concat(globs, ' ') .. ' -- "' .. self.root .. '"'
    local p = io.popen(cmd .. (package.config:sub(1, 1) == '\\' and ' 2>nul' or ' 2>/dev/null'))
    if not p then return {} end
    local out = {}
    local prefix = self.root .. '/'
    for line in p:lines() do
        local path = norm(line)
        if path:sub(1, #prefix) == prefix then path = path:sub(#prefix + 1) end
        out[#out + 1] = path
    end
    p:close()
    table.sort(out)
    return out
end

-- Bring the index in line with the tree. Returns counts of what changed.
function Index:refresh()
    local stats = { parsed = 0, unchanged = 0, removed = 0, skipped = 0, failed = 0 }
    local seen = {}
    local has_stat = xutils and xutils.stat
    for _, rel in ipairs(self:list_files()) do
        seen[rel] = true
        local abs = self.root .. '/' .. rel
        local rec = self.files[rel]
        local st = has_stat and xutils.stat(abs) or nil
        if st and st.exists == false then
            seen[rel] = nil
        elseif st and rec and rec.size == st.size and rec.mtime == st.mtime and (rec.checked or 0) > st.mtime + 1 then
            -- (size, mtime) is only proof of "unchanged" once the content was
            -- read strictly after that mtime second: an edit within the same
            -- second keeps both equal forever (the "racy git" problem)
            stats.unchanged = stats.unchanged + 1
        elseif st and st.size and st.size > self.max_bytes then
            stats.skipped = stats.skipped + 1
            seen[rel] = nil
        else
            local src = slurp(abs)
            if not src or #src > self.max_bytes then
                stats.skipped = stats.skipped + 1
                seen[rel] = nil
            else
                local crc = checksum(src)
                if rec and rec.size == #src and rec.crc == crc then
                    rec.mtime = st and st.mtime or rec.mtime
                    rec.checked = os.time()
                    stats.unchanged = stats.unchanged + 1
                else
                    local ok, r = pcall(ci.parse, rel, src)
                    if ok and r then
                        r.size, r.crc, r.mtime = #src, crc, st and st.mtime or nil
                        r.checked = os.time()
                        self.files[rel] = r
                        stats.parsed = stats.parsed + 1
                    else
                        stats.failed = stats.failed + 1
                        seen[rel] = nil
                    end
                end
            end
        end
    end
    for rel in pairs(self.files) do
        if not seen[rel] then
            self.files[rel] = nil
            stats.removed = stats.removed + 1
        end
    end
    if stats.parsed > 0 or stats.removed > 0 then self.generation = self.generation + 1 end
    return stats
end

-- Absolute path for a record's relative path.
function Index:abs(rel)
    return self.root .. '/' .. rel
end

return M
