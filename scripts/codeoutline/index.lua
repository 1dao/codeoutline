-- index.lua — per-project symbol index: which files exist, what each one
-- defines and calls, kept fresh incrementally and cached on disk.
--
--   local index = require('codeoutline.index')
--   local idx = index.open('C:/src/proj')        -- loads the cache if present
--   local stats = idx:refresh()                   -- reparses only changed files
--   idx:save()
--   idx:watch()                                   -- long-lived hosts: later
--                                                 -- refreshes visit only changes
--
-- Change detection trusts an unchanged size + mtime once the file was last
-- read strictly after that mtime second, skipping the read entirely; otherwise
-- it reads the file and compares size + CRC-32, which still skips the parse.
-- Tools that restore an older mtime at the same size are not detected by a
-- full refresh; a watcher reports them.

local ci = require('codeoutline.parse')
local paths = require('codeoutline.path')
local control = require('codeoutline.control')

local M = {}
local INDEX_PARSE = { ranges = false }

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
    return 'p5-compact-nodes-' .. xutils.sha256_hex(table.concat(parts))
end)()
-- Generated amalgamations (sqlite3.c, minified bundles) cost more to index
-- than they give back; skip files above this size unless configured.
M.MAX_FILE_BYTES = 1500000
-- Caches are deflated: msgpack records shrink to ~1/6. Level 1 is within a
-- few percent of level 6 at under half the time; inflating is cheap next to
-- unpacking, and the checksum then covers the smaller compressed bytes.
M.CACHE_COMPRESSION_LEVEL = 1

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
    if not data or not cmsgpack or not (xcompress and xcompress.inflate) then return false end
    local ok, files = pcall(function()
        local envelope = cmsgpack.unpack(data)
        assert(type(envelope) == 'table' and type(envelope.payload) == 'string')
        assert(envelope.sha256 == xutils.sha256_hex(envelope.payload))
        -- Older uncompressed caches have no codec and are rebuilt.
        assert(envelope.codec == 'deflate')
        local size = envelope.size
        assert(type(size) == 'number' and size >= 1 and size % 1 == 0)
        local payload = assert(xcompress.inflate(envelope.payload, size))
        assert(#payload == size)
        local t = cmsgpack.unpack(payload)
        assert(t.version == M.VERSION and t.root == paths.key(self.root) and type(t.files) == 'table')
        local records = {}
        for _, rec in ipairs(t.files) do
            control.check()
            assert(type(rec) == 'table' and type(rec.path) == 'string')
            assert(not rec.path:find('[\\:%z]') and rec.path:sub(1, 1) ~= '/')
            for part in rec.path:gmatch('[^/]+') do assert(part ~= '..' and part ~= '.') end
            assert(type(rec.nodes) == 'table' and type(rec.refs) == 'table' and type(rec.imports) == 'table')
            assert(type(rec.size) == 'number' and type(rec.language) == 'string')
            assert(rec.encoding == nil or rec.encoding == 'utf-8' or rec.encoding == 'utf-8-bom' or rec.encoding == 'gbk')
            for i, n in ipairs(rec.nodes) do
                if i % 128 == 0 then control.check() end
                assert(type(n.name) == 'string' and type(n.qualified) == 'string' and type(n.kind) == 'string')
                assert(type(n.line) == 'number' and type(n.end_line) == 'number' and n.line >= 1 and n.end_line >= n.line)
            end
            local refs = rec.refs
            assert(type(refs.name) == 'table' and type(refs.from) == 'table' and type(refs.kind) == 'table'
                and type(refs.line) == 'table' and type(refs.recv) == 'table')
            local nrefs = #refs.name
            assert(#refs.from == nrefs and #refs.kind == nrefs and #refs.line == nrefs and #refs.recv == nrefs)
            for i = 1, nrefs do
                if i % 128 == 0 then control.check() end
                assert(type(refs.name[i]) == 'string' and type(refs.from[i]) == 'number'
                    and type(refs.kind[i]) == 'string' and type(refs.line[i]) == 'number')
                local recv = refs.recv[i]
                assert(recv == false or type(recv) == 'string')
            end
            for _, imp in ipairs(rec.imports) do assert(type(imp.path) == 'string') end
            records[rec.path] = rec
        end
        return records
    end)
    if not ok then
        if control.is_interrupted(files) then error(files, 0) end
        self.cache_error = 'invalid or stale cache; rebuilding'; return false
    end
    self.files = files
    self.generation = self.generation + 1
    self.saved_generation = self.generation
    return true
end

-- Whether the cache file lags the records. Refresh metadata (mtime, checked)
-- alone does not count: unchanged files are re-verified by checksum anyway.
function Index:needs_save()
    return self.saved_generation ~= self.generation or self.encoding_dirty == true
end

function Index:save()
    if not (cmsgpack and xcompress and xcompress.deflate and xutils.temp_file and xutils.replace_file) then
        return false, 'runtime requires cmsgpack, xcompress, temp_file and replace_file'
    end
    local list = {}
    for _, rec in pairs(self.files) do list[#list + 1] = rec end
    table.sort(list, function(a, b) return a.path < b.path end)
    local payload = cmsgpack.pack({ version = M.VERSION, root = paths.key(self.root), files = list })
    local packed = xcompress.deflate(payload, M.CACHE_COMPRESSION_LEVEL)
    local blob = cmsgpack.pack({ codec = 'deflate', size = #payload, sha256 = xutils.sha256_hex(packed), payload = packed })
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
    self.saved_generation = self.generation
    self.encoding_dirty = false
    return true
end

function Index:set_file(rel, rec)
    if self.changes and self.changes[rel] == nil then self.changes[rel] = self.files[rel] or false end
    self.files[rel] = rec
end

-- Record replacements, not full copies of the tree. Readers retain the last
-- complete index when refresh, decoding or graph construction is cancelled.
function Index:transaction(fn)
    assert(not self.changes, 'nested index transaction')
    local generation, dirty, saved = self.generation, self.encoding_dirty, self.saved_generation
    self.changes = {}
    local ok, result = pcall(fn)
    local changes = self.changes
    self.changes = nil
    if not ok then
        for rel, rec in pairs(changes) do self.files[rel] = rec or nil end
        self.generation, self.encoding_dirty, self.saved_generation = generation, dirty, saved
        -- Watch events may already have been drained; reconcile on the next pass.
        self.watch_ready = false
        error(result, 0)
    end
    return result
end

-- Only query-selected files are decoded. This cache lasts for one query and
-- holds the exact snapshot used for both reparsing and source rendering.
function Index:query_source(rel)
    control.check()
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
        if not src then
            local reason = tostring(encoding)
            -- Minimal EL8/EL9 installs and containers omit the GBK module.
            local hint = reason:find('does not provide GBK', 1, true)
                and ' (install the system GBK converter, e.g. glibc-gconv-extra on EL8/EL9)' or ''
            error(rel .. ': ' .. reason .. hint, 0)
        end
    end
    local changed = false
    if not rec.encoding then
        if encoding == 'gbk' then
            local parsed = assert(ci.parse(rel, src, INDEX_PARSE), 'cannot parse decoded source: ' .. rel)
            parsed.size, parsed.crc, parsed.mtime, parsed.checked = rec.size, rec.crc, rec.mtime, rec.checked
            self:set_file(rel, parsed)
            rec = parsed
            self.generation = self.generation + 1
            changed = true
        end
        local updated = {}
        for key, value in pairs(rec) do updated[key] = value end
        updated.encoding = encoding
        self:set_file(rel, updated)
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
            if not ok and control.is_interrupted(p) then error(p, 0) end
            if ok and p then
                has_rg = (p:read('a') or ''):find('ripgrep', 1, true) ~= nil
                p:close()
            end
        end
    end
    return has_rg
end
M.rg_available = rg_available

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
-- Also returns each file's stat fields when the runtime lists them.
function Index:walk_files()
    local out, meta = {}, {}
    assert(xutils and xutils.list_dir, 'file enumeration unavailable: install rg or use a runtime with list_dir')
    local rules = load_ignore(self.root)
    local dirs = { '' }
    local visited = 0
    while #dirs > 0 do
        control.check()
        local rel_dir = table.remove(dirs)
        local entries, truncated = xutils.list_dir(rel_dir == '' and self.root or (self.root .. '/' .. rel_dir),
            M.MAX_WALK_FILES + 1, true)
        assert(entries, 'cannot enumerate directory: ' .. rel_dir .. ': ' .. tostring(truncated))
        assert(not truncated, 'directory enumeration limit exceeded')
        for _, e in ipairs(entries) do
            visited = visited + 1
            assert(visited <= M.MAX_WALK_FILES, 'directory enumeration limit exceeded')
            local name = e.name
            local rel = rel_dir == '' and name or (rel_dir .. '/' .. name)
            local st = e.type and e or xutils.stat(self.root .. '/' .. rel)
            if st and st.type ~= 'link' and name:sub(1, 1) ~= '.' and not ignored(rules, rel, name, e.dir) then
                if e.dir then
                    if not M.WALK_SKIP[name] then dirs[#dirs + 1] = rel end
                elseif ci.language(name) then
                    out[#out + 1] = rel
                    meta[rel] = st
                end
            end
        end
    end
    table.sort(out)
    return out, meta
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

local MISSING = { exists = false }

-- Stat fields for every listed file, read one directory at a time:
-- list_dir reports them per entry, so a tree costs a call per directory
-- rather than a stat per file. Older runtimes fall back to stat.
function Index:stat_listing(list)
    local by_dir = {}
    for _, rel in ipairs(list) do
        local dir, name = rel:match('^(.*)/([^/]*)$')
        if not dir then dir, name = '', rel end
        local names = by_dir[dir]
        if not names then names = {}; by_dir[dir] = names end
        names[#names + 1] = name
    end
    local meta = {}
    for dir, names in pairs(by_dir) do
        control.check()
        local entries = xutils.list_dir(dir == '' and self.root or (self.root .. '/' .. dir), nil, true)
        local by_name
        if entries and (entries[1] == nil or entries[1].size ~= nil) then
            by_name = {}
            for _, e in ipairs(entries) do by_name[e.name] = e end
        end
        for _, name in ipairs(names) do
            local rel = dir == '' and name or (dir .. '/' .. name)
            meta[rel] = by_name and (by_name[name] or MISSING) or xutils.stat(self:abs(rel))
        end
    end
    return meta
end

local function new_stats(mode)
    return { parsed = 0, unchanged = 0, removed = 0, skipped = 0, failed = 0, mode = mode }
end

-- Bring one listed file in line with the tree, given its stat fields (nil
-- when the runtime has no stat). Returns false when it no longer belongs in
-- the index: gone, too large, unreadable or unparsable.
function Index:sync_file(rel, st, stats)
    local rec = self.files[rel]
    if st and (st.exists == false or st.type ~= 'file') then
        return false
    elseif st and st.size and st.size > self.max_bytes then
        stats.skipped = stats.skipped + 1
        return false
    elseif st and rec and st.mtime and rec.size == st.size and rec.mtime == st.mtime
        and (rec.checked or 0) > st.mtime + 1 then
        -- (size, mtime) proves "unchanged" only once the content was read
        -- strictly after that mtime second: an edit within the same second
        -- keeps both equal forever (the "racy git" problem).
        stats.unchanged = stats.unchanged + 1
        return true
    end
    local src = slurp(self:abs(rel))
    if not src or #src > self.max_bytes then
        stats.skipped = stats.skipped + 1
        return false
    end
    local crc = checksum(src)
    if rec and rec.size == #src and rec.crc == crc then
        local updated = {}
        for key, value in pairs(rec) do updated[key] = value end
        updated.mtime = st and st.mtime or rec.mtime
        updated.checked = os.time()
        self:set_file(rel, updated)
        stats.unchanged = stats.unchanged + 1
        return true
    end
    local ok, r = pcall(ci.parse, rel, src, INDEX_PARSE)
    if not ok and control.is_interrupted(r) then error(r, 0) end
    control.check()
    -- A parser exception must not permanently hide a GBK file.
    -- Successful speculative parsing does not scan encoding here.
    if not ok or not r then
        if xutils.to_utf8 then
            local decoded, encoding = xutils.to_utf8(src)
            if decoded then
                ok, r = pcall(ci.parse, rel, decoded, INDEX_PARSE)
                if not ok and control.is_interrupted(r) then error(r, 0) end
                if ok and r then r.encoding = encoding end
            end
        end
    end
    if not (ok and r) then
        stats.failed = stats.failed + 1
        return false
    end
    r.size, r.crc, r.mtime = #src, crc, st and st.mtime or nil
    r.checked = os.time()
    self:set_file(rel, r)
    stats.parsed = stats.parsed + 1
    return true
end

-- Start change notification so later refreshes visit only what changed.
-- Call it before the next refresh: that one stays a full pass, and anything
-- changing while it runs is reported to the pass after. Returns false when
-- the runtime or the filesystem cannot watch the root.
function Index:watch()
    if not (xwatch and xwatch.open) then return false end
    self.watching = true
    return self.watcher ~= nil or self:open_watcher()
end

-- A root that cannot be watched (inotify limit, network share) stays on full
-- refreshes; retry now and then rather than paying a failed open per query.
M.WATCH_RETRY_SECONDS = 300

function Index:open_watcher()
    local w, err = xwatch.open(self.root, { skip_hidden = true })
    self.watcher, self.watch_error, self.watch_ready = w, err, false
    if not w then self.watch_retry = os.time() + M.WATCH_RETRY_SECONDS end
    return w ~= nil
end

function Index:close()
    if self.watcher then self.watcher:close() end
    self.watcher, self.watch_ready, self.watching = nil, false, false
end

-- rg reads these anywhere in the tree; a change can admit or hide files.
local IGNORE_FILES = { ['.gitignore'] = true, ['.ignore'] = true, ['.rgignore'] = true }

-- Changed paths that can matter, or nil when only a full refresh is safe.
-- Hidden paths are never listed (rg and the walk both skip them).
local function relevant(paths)
    local changed = {}
    for _, rel in ipairs(paths) do
        if IGNORE_FILES[rel:match('[^/]*$')] then return nil end
        if rel:sub(1, 1) ~= '.' and not rel:find('/.', 1, true) then changed[rel] = true end
    end
    return changed
end

-- Apply watcher-reported changes. Creations, removals and renames re-run the
-- listing (only rg decides what .gitignore admits) but still visit only the
-- files that differ from the index.
function Index:refresh_changed(changed, structural)
    local stats = new_stats('changes')
    if not structural then
        -- A supported file the index lacks may have shrunk under the size
        -- limit or been fixed after a failed parse: let the listing decide.
        for rel in pairs(changed) do
            if not self.files[rel] and ci.language(rel) then structural = true; break end
        end
    end
    local listed
    if structural then
        stats.mode = 'relisted'
        listed = {}
        for _, rel in ipairs(self:list_files()) do
            listed[rel] = true
            if not self.files[rel] then changed[rel] = true end
        end
        for rel in pairs(self.files) do
            if not listed[rel] then changed[rel] = true end
        end
    end
    local has_stat = xutils and xutils.stat
    for rel in pairs(changed) do
        control.check()
        local known = self.files[rel] ~= nil
        if listed and listed[rel] or (not listed and known) then
            if not self:sync_file(rel, has_stat and xutils.stat(self:abs(rel)) or nil, stats) and known then
                self:set_file(rel, nil)
                stats.removed = stats.removed + 1
            end
        elseif known then
            self:set_file(rel, nil)         -- no longer listed
            stats.removed = stats.removed + 1
        end
    end
    local total = 0
    for _ in pairs(self.files) do total = total + 1 end
    stats.unchanged = total - stats.parsed
    return stats
end

-- Bring the index in line with the tree. Returns counts of what changed.
-- With a watcher (see Index:watch) only reported paths are visited; an
-- overflow or an ignore-file change falls back to a full pass, and a failed
-- watcher is reopened before one.
function Index:refresh()
    if self.watcher and self.watch_ready then
        local paths, structural, overflow = self.watcher:read()
        local changed = paths and not overflow and relevant(paths)
        if changed then
            -- Not ready again until this pass completes: the events are
            -- drained, so a pass that fails midway leaves a full one next.
            self.watch_ready = false
            local stats = self:refresh_changed(changed, structural)
            if stats.parsed > 0 or stats.removed > 0 then self.generation = self.generation + 1 end
            self.watch_ready = true
            return stats
        end
        if not paths then
            -- A watcher that worked and then failed (root moved, queue
            -- error) is reopened right away.
            self.watcher:close()
            self.watcher, self.watch_error, self.watch_retry = nil, structural, 0
        end
    end
    if self.watching and not self.watcher and os.time() >= (self.watch_retry or 0) then self:open_watcher() end
    if self.watcher then self.watch_ready = false end
    local stats = self:refresh_all()
    if self.watcher then self.watch_ready = true end
    return stats
end

function Index:refresh_all()
    local stats = new_stats('full')
    local seen = {}
    local list, meta = self:list_files()
    if not meta and xutils and xutils.stat then meta = self:stat_listing(list) end
    for _, rel in ipairs(list) do
        control.check()
        if self:sync_file(rel, meta and meta[rel], stats) then seen[rel] = true end
    end
    for rel in pairs(self.files) do
        if not seen[rel] then
            self:set_file(rel, nil)
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
