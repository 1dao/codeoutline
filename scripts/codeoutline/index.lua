-- index.lua — per-project symbol index: which files exist, what each one
-- defines and calls, kept fresh incrementally and cached on disk.
--
--   local index = require('codeoutline.index')
--   local idx = index.open('C:/src/proj')        -- loads the cache if present
--   local stats = idx:refresh()                   -- reparses only changed files
--   idx:save()
--
-- Change detection reads size + CRC-32, skipping parsing for unchanged files
-- even when editors preserve or restore modification timestamps.

local ci = require('codeoutline.parse')
local paths = require('codeoutline.path')
local control = require('codeoutline.control')

local M = {}

-- Cache version: a checksum of the parser sources, so any parser change
-- rebuilds stale caches instead of silently reusing old parse results.
M.VERSION = (function()
    local parts = {}
    for _, m in ipairs({ 'xscan', 'text', 'common', 'parse', 'lang.c', 'lang.cpp', 'lang.lua', 'lang.python',
        'lang.java', 'lang.go', 'lang.js', 'lang.csharp', 'lang.rust' }) do
        local file = package.searchpath and package.searchpath('codeoutline.' .. m, package.path)
        local h = file and io.open(file, 'rb')
        if h then parts[#parts + 1] = h:read('a'); h:close() end
    end
    return 'p3-lazy-encoding-' .. xutils.sha256_hex(table.concat(parts))
end)()
-- Generated amalgamations (sqlite3.c, minified bundles) cost more to index
-- than they give back; skip files above this size unless configured.
M.MAX_FILE_BYTES = 1500000

local Index = {}
Index.__index = Index

local norm = paths.normalize

local function home()
    return os.getenv('USERPROFILE') or os.getenv('HOME') or '.'
end

-- Cache file name derived from the root so projects don't collide.
local function cache_path_for(root)
    assert(xutils and xutils.sha256_hex, 'runtime requires SHA-256')
    return norm(home()) .. '/.codeoutline/cache/' .. xutils.sha256_hex(paths.key(root)) .. '.idx'
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
    return xutils.sha256_hex(s)
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
    local r, err = paths.canonical(root)
    if not r then return nil, err end
    if r:find(UNSAFE) then
        return nil, 'root contains characters that are unsafe in a shell command: ' .. root
    end
    return r
end

function M.open(root, opts)
    opts = opts or {}
    local checked, why = M.check_root(root)
    if not checked then error(why, 2) end
    root = checked
    if opts.lister ~= nil and opts.lister ~= 'rg' and opts.lister ~= 'walk' then error('invalid lister', 2) end
    local max_bytes = opts.max_file_bytes or M.MAX_FILE_BYTES
    assert(type(max_bytes) == 'number' and max_bytes >= 1 and max_bytes < math.huge and max_bytes % 1 == 0,
        'max_file_bytes must be a positive integer')
    local self = setmetatable({
        root = norm(root),
        cache_path = opts.cache_path and norm(opts.cache_path) or cache_path_for(root),
        max_bytes = max_bytes,
        lister = opts.lister,       -- 'rg' | 'walk' | nil (rg when it runs here)
        files = {},          -- rel path -> record
        generation = 0,      -- bumped on every change; graph caches key on it
    }, Index)
    self.cache_loaded = not opts.rebuild and self:load() or false
    return self
end

function Index:load()
    local data = slurp(self.cache_path)
    if not data or not cmsgpack then return false end
    local ok, files = pcall(function()
        local envelope = cmsgpack.unpack(data)
        assert(type(envelope) == 'table' and type(envelope.payload) == 'string')
        assert(envelope.sha256 == xutils.sha256_hex(envelope.payload))
        local t = cmsgpack.unpack(envelope.payload)
        assert(t.version == M.VERSION and t.root == paths.key(self.root) and type(t.files) == 'table')
        local records = {}
        for _, rec in ipairs(t.files) do
            assert(type(rec) == 'table' and type(rec.path) == 'string')
            assert(not rec.path:find('[\\:%z]') and rec.path:sub(1, 1) ~= '/')
            for part in rec.path:gmatch('[^/]+') do assert(part ~= '..' and part ~= '.') end
            assert(type(rec.nodes) == 'table' and type(rec.refs) == 'table' and type(rec.imports) == 'table')
            assert(type(rec.size) == 'number' and type(rec.language) == 'string')
            assert(rec.encoding == nil or rec.encoding == 'utf-8' or rec.encoding == 'utf-8-bom' or rec.encoding == 'gbk')
            for _, n in ipairs(rec.nodes) do
                assert(type(n.name) == 'string' and type(n.qualified) == 'string' and type(n.kind) == 'string')
                assert(type(n.line) == 'number' and type(n.end_line) == 'number' and n.line >= 1 and n.end_line >= n.line)
            end
            for _, r in ipairs(rec.refs) do assert(type(r.name) == 'string' and type(r.from) == 'number') end
            for _, imp in ipairs(rec.imports) do assert(type(imp.path) == 'string') end
            records[rec.path] = rec
        end
        return records
    end)
    if not ok then self.cache_error = 'invalid or stale cache; rebuilding'; return false end
    self.files = files
    self.generation = self.generation + 1
    return true
end

function Index:save()
    if not (cmsgpack and xutils.temp_file and xutils.replace_file) then
        return false, 'runtime requires cmsgpack, temp_file and replace_file'
    end
    local list = {}
    for _, rec in pairs(self.files) do list[#list + 1] = rec end
    table.sort(list, function(a, b) return a.path < b.path end)
    local payload = cmsgpack.pack({ version = M.VERSION, root = paths.key(self.root), files = list })
    local blob = cmsgpack.pack({ sha256 = xutils.sha256_hex(payload), payload = payload })
    local d = self.cache_path:match('^(.*)/[^/]*$') or '.'
    local made, err = xutils.mkdir_p(d)
    if not made then return false, err end
    local tmp
    tmp, err = xutils.temp_file(d)
    if not tmp then return false, err end
    local f
    f, err = io.open(tmp, 'wb')
    if not f then os.remove(tmp); return false, err end
    local wrote, write_err = f:write(blob)
    local closed, close_err = f:close()
    if not wrote or not closed then os.remove(tmp); return false, write_err or close_err end
    local published
    published, err = xutils.replace_file(tmp, self.cache_path)
    if not published then os.remove(tmp); return false, err end
    self.encoding_dirty = false
    return true
end

-- Only query-selected files are decoded. This cache lasts for one query and
-- holds the exact snapshot used for both reparsing and source rendering.
function Index:query_source(rel)
    self.query_sources = self.query_sources or {}
    if self.query_sources[rel] then return self.query_sources[rel], false end
    local rec = assert(self.files[rel], 'source is not indexed: ' .. rel)
    local raw = assert(slurp(self:abs(rel)), 'cannot read source: ' .. rel)
    assert(#raw == rec.size and checksum(raw) == rec.crc,
        'source changed during query; retry: ' .. rel)
    assert(xutils.to_utf8, 'rebuild xnet2lua: missing xutils.to_utf8')
    local src, encoding
    if rec.encoding == 'utf-8' then
        src, encoding = raw, rec.encoding
    elseif rec.encoding == 'utf-8-bom' then
        src, encoding = raw:sub(4), rec.encoding
    else
        src, encoding = xutils.to_utf8(raw, rec.encoding == 'gbk' and 'gbk' or 'auto')
        assert(src, rel .. ': ' .. tostring(encoding))
    end
    local changed = false
    if not rec.encoding then
        if encoding == 'gbk' then
            local parsed = assert(ci.parse(rel, src), 'cannot parse decoded source: ' .. rel)
            parsed.size, parsed.crc, parsed.mtime, parsed.checked = rec.size, rec.crc, rec.mtime, rec.checked
            self.files[rel], rec = parsed, parsed
            self.generation = self.generation + 1
            changed = true
        end
        rec.encoding = encoding
        self.encoding_dirty = true
    end
    self.query_sources[rel] = src
    return src, changed
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
    assert(xutils and xutils.list_dir, 'file enumeration unavailable: install rg or use a runtime with list_dir')
    local rules = load_ignore(self.root)
    local dirs = { '' }
    local visited = 0
    while #dirs > 0 do
        control.check()
        local rel_dir = table.remove(dirs)
        local entries, truncated = xutils.list_dir(rel_dir == '' and self.root or (self.root .. '/' .. rel_dir), M.MAX_WALK_FILES + 1)
        assert(entries, 'cannot enumerate directory: ' .. rel_dir .. ': ' .. tostring(truncated))
        assert(not truncated, 'directory enumeration limit exceeded')
        for _, e in ipairs(entries) do
            visited = visited + 1
            assert(visited <= M.MAX_WALK_FILES, 'directory enumeration limit exceeded')
            local name = e.name
            local rel = rel_dir == '' and name or (rel_dir .. '/' .. name)
            local st = xutils.stat(self.root .. '/' .. rel)
            if st and st.type ~= 'link' and name:sub(1, 1) ~= '.' and not ignored(rules, rel, name, e.dir) then
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
        self.enumerator = 'walk'
        return self:walk_files()
    end
    assert(rg_available(), 'rg file enumeration requested but ripgrep is unavailable')
    self.enumerator = 'rg'
    -- self.root passed check_root() in open(); `--` stops rg from reading a
    -- root that starts with '-' as an option (`--pre=<cmd>` runs a command).
    assert(M.check_root(self.root), 'unsafe root')
    -- Filter extensions afterward: positive -g globs override .gitignore.
    local cmd = 'rg --files --null --no-require-git --no-messages -- "' .. self.root .. '"'
    local p = io.popen(cmd .. (package.config:sub(1, 1) == '\\' and ' 2>nul' or ' 2>/dev/null'))
    assert(p, 'cannot start rg file enumeration')
    local out = {}
    local prefix = self.root:sub(-1) == '/' and self.root or self.root .. '/'
    local listing = p:read('a')
    local ok, _, code = p:close()
    assert(ok or code == 1, 'rg file enumeration failed: ' .. tostring(code))
    for line in listing:gmatch('([^%z]+)%z') do
        local path = norm(line)
        if path:sub(1, #prefix) == prefix then path = path:sub(#prefix + 1) end
        if ci.language(path) then
            out[#out + 1] = path
            assert(#out <= M.MAX_WALK_FILES, 'file enumeration limit exceeded')
        end
    end
    table.sort(out)
    return out
end

-- Bring the index in line with the tree. Returns counts of what changed.
function Index:refresh()
    local stats = { parsed = 0, unchanged = 0, removed = 0, skipped = 0, failed = 0 }
    local seen = {}
    local has_stat = xutils and xutils.stat
    for _, rel in ipairs(self:list_files()) do
        control.check()
        seen[rel] = true
        local abs = self:abs(rel)
        local rec = self.files[rel]
        local st = has_stat and xutils.stat(abs) or nil
        if st and (st.exists == false or st.type ~= 'file') then
            seen[rel] = nil
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
                    control.check()
                    -- A parser exception must not permanently hide a GBK file.
                    -- Successful speculative parsing does not scan encoding here.
                    if not ok or not r then
                        if xutils.to_utf8 then
                            local decoded, encoding = xutils.to_utf8(src)
                            if decoded then
                                ok, r = pcall(ci.parse, rel, decoded)
                                if ok and r then r.encoding = encoding end
                            end
                        end
                    end
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
