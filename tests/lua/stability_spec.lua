package.path = 'scripts/?.lua;' .. package.path
local spec = dofile('tests/lua/spec_helper.lua')
local service = require('codeoutline.service')
local index = require('codeoutline.index')
local paths = require('codeoutline.path')
local text = require('codeoutline.text')
local root = assert(xutils.temp_file(os.getenv('TEMP') or os.getenv('TMPDIR') or '/tmp')):gsub('\\', '/')
os.remove(root)
assert(xutils.mkdir_p(root .. '/中文 项目'))
local project = root .. '/中文 项目'
local cache = root .. '/cache.idx'
local opts = { cache_path = cache, lister = 'walk' }
local function write(path, data)
    local f = assert(io.open(path, 'wb')); assert(f:write(data)); assert(f:close())
end
local function read(path)
    local f = assert(io.open(path, 'rb')); local data = f:read('a'); f:close(); return data
end
write(project .. '/中文.lua', 'function original() return "你好" end\n')

spec.describe('service stability', function()
    spec.it('throttles unwatchable roots and refreshes save hints without enumerating', function()
        local idx = index.open(project, { cache_path = root .. '/interval.idx', lister = 'walk', rebuild = true })
        idx:refresh({ full_interval = 45 })
        local original = idx.list_files
        idx.list_files = function() error('unexpected full enumeration') end
        spec.equal(idx:refresh({ full_interval = 45 }).mode, 'idle')
        write(project .. '/中文.lua', 'function hinted() end\n')
        local stats = idx:refresh({ paths = { project .. '/中文.lua' } })
        spec.equal(stats.parsed, 1); spec.equal(idx.files['中文.lua'].nodes[1].name, 'hinted')
        local ok = pcall(function()
            idx:transaction(function() error(require('codeoutline.control').cancelled(), 0) end)
        end)
        spec.equal(ok, false); spec.equal(idx.next_full, nil)
        idx.list_files = original
        spec.equal(idx:refresh({ full_interval = 45 }).mode, 'full')
        write(project .. '/中文.lua', 'function original() return "你好" end\n')
        idx:close()
    end)

    spec.it('canonicalizes dot, parent, separators and Windows casing', function()
        local a = service.get(project, opts)
        local b = service.get(project .. '/./../中文 项目/', opts)
        spec.equal(a, b)
        if paths.windows then spec.equal(a, service.get(project:upper():gsub('/', '\\'), opts)) end
        spec.truthy(a.root:match('^%a:/') or a.root:sub(1, 1) == '/')
        spec.truthy(service.explore(project, 'original', opts):find('你好', 1, true))
    end)
    spec.it('preserves filesystem roots', function()
        spec.equal(paths.normalize('/'), '/')
        spec.equal(paths.normalize('C:\\'), 'C:/')
        local drive = paths.windows and project:sub(1, 3) or '/'
        spec.truthy(paths.canonical(drive))
    end)
    spec.it('hashes formerly colliding paths to distinct cache names', function()
        assert(xutils.mkdir_p(root .. '/a-b')); assert(xutils.mkdir_p(root .. '/a_b'))
        spec.truthy(index.open(root .. '/a-b').cache_path ~= index.open(root .. '/a_b').cache_path)
    end)
    spec.it('keeps projects isolated', function()
        write(root .. '/a-b/other.lua', 'function other_project() end\n')
        local _, a = service.get(project, opts)
        local _, b = service.get(root .. '/a-b', { cache_path = root .. '/other.idx' })
        spec.nil_value(a.by_name.other_project)
        spec.truthy(b.by_name.other_project)
        spec.nil_value(b.by_name.original)
    end)
    spec.it('forget reloads cache while rebuild reparses every file', function()
        service.forget(project)
        local status = service.status(project, opts)
        spec.truthy(status.cacheLoaded)
        spec.equal(status.refresh.parsed, 0)
        local rebuilt = service.rebuild(project)
        spec.equal(rebuilt.cacheLoaded, false)
        spec.equal(rebuilt.refresh.parsed, 1)
    end)
    spec.it('does not rewrite an unchanged cache after loading it', function()
        -- The first query persists its encoding confirmation once.
        service.forget(project)
        service.explore(project, 'original', opts)
        service.forget(project)
        local replace, published = xutils.replace_file, 0
        xutils.replace_file = function(...) published = published + 1; return replace(...) end
        local ok, status = pcall(service.status, project, opts)
        local explored = ok and pcall(service.explore, project, 'original', opts)
        xutils.replace_file = replace
        spec.truthy(ok and explored)
        spec.truthy(status.cacheLoaded)
        spec.equal(status.refresh.parsed, 0)
        spec.nil_value(status.refresh.cache_saved)
        spec.equal(published, 0)
    end)
    spec.it('stores the cache deflated and rebuilds uncompressed caches', function()
        local envelope = cmsgpack.unpack(read(cache))
        spec.equal(envelope.codec, 'deflate')
        spec.equal(envelope.sha256, xutils.sha256_hex(envelope.payload))
        local payload = assert(xcompress.inflate(envelope.payload, envelope.size))
        spec.equal(#payload, envelope.size)
        spec.truthy(#envelope.payload < #payload)
        service.forget(project)
        write(cache, cmsgpack.pack({ sha256 = xutils.sha256_hex(payload), payload = payload }))
        local status = service.status(project, opts)
        spec.equal(status.cacheLoaded, false)
        spec.equal(status.refresh.parsed, 1)
        spec.equal(cmsgpack.unpack(read(cache)).codec, 'deflate')
    end)
    spec.it('rejects compressed caches with a wrong size or unknown codec', function()
        local good = read(cache)
        local envelope = cmsgpack.unpack(good)
        for _, bad in ipairs({ { size = envelope.size - 1 }, { size = 'x' }, { codec = 'zstd' } }) do
            local e = { codec = envelope.codec, size = envelope.size, payload = envelope.payload, sha256 = envelope.sha256 }
            for k, v in pairs(bad) do e[k] = v end
            service.forget(project); write(cache, cmsgpack.pack(e))
            local status = service.status(project, opts)
            spec.equal(status.cacheLoaded, false)
            spec.equal(status.refresh.parsed, 1)
        end
        service.forget(project); write(cache, good)
        spec.truthy(service.status(project, opts).cacheLoaded)
    end)
    spec.it('recovers corrupt and structurally invalid caches', function()
        for _, blob in ipairs({ '\0broken', cmsgpack.pack({ payload = 'invalid', sha256 = 'bad' }) }) do
            service.forget(project); write(cache, blob)
            local status = service.status(project, opts)
            spec.equal(status.cacheLoaded, false)
            spec.equal(status.refresh.parsed, 1)
        end
    end)
    spec.it('preserves old cache when replacement fails, then retries', function()
        local before = read(cache)
        write(project .. '/中文.lua', 'function modified() return "再见" end\n')
        local replace = xutils.replace_file
        xutils.replace_file = function() return nil, 'injected replacement failure' end
        local ok, status = pcall(service.status, project, opts)
        xutils.replace_file = replace
        spec.truthy(ok)
        spec.equal(status.refresh.cache_saved, false)
        spec.contains(status.refresh.cache_error, 'injected')
        spec.equal(read(cache), before)
        spec.truthy(service.status(project, opts).refresh.cache_saved)
        spec.truthy(read(cache) ~= before)
    end)
    spec.it('reports cache directory/write errors without losing query results', function()
        service.forget(project)
        write(root .. '/blocker', 'file')
        local status = service.status(project, { cache_path = root .. '/blocker/no.idx' })
        spec.equal(status.refresh.cache_saved, false)
        spec.truthy(status.refresh.cache_error)
        spec.equal(status.files, 1)
        service.forget(project)
    end)
    spec.it('fails enumeration without silently deleting cached records', function()
        local idx = index.open(project, opts)
        idx:refresh()
        local saved = xutils.list_dir
        xutils.list_dir = function() return nil, 'permission denied' end
        local ok, err = pcall(idx.refresh, idx)
        xutils.list_dir = saved
        spec.equal(ok, false)
        spec.contains(err, 'permission denied')
        spec.truthy(idx.files['中文.lua'])
        xutils.list_dir = nil
        ok = pcall(idx.walk_files, idx)
        xutils.list_dir = saved
        spec.equal(ok, false)
    end)
    spec.it('bounds resident projects and evicts idle indexes', function()
        service.configure({ max_projects = 1 })
        service.get(project, opts)
        service.get(root .. '/a-b', { cache_path = root .. '/other.idx' })
        spec.equal(service.sweep(), 1)
        spec.equal(service.sweep(os.time() + 901), 0)
        service.configure({ max_projects = 8 })
    end)
    spec.it('rg respects ignored extensions and negations outside a git repository', function()
        if not index.rg_available() then print('SKIP ripgrep is unavailable'); return end
        write(project .. '/.gitignore', '*.lua\n!keep.lua\n')
        write(project .. '/keep.lua', 'function kept() end\n')
        local ok, err = pcall(function()
            local idx = index.open(project, { lister = 'rg', cache_path = cache })
            local files = idx:list_files()
            spec.equal(#files, 1)
            spec.equal(files[1], 'keep.lua')
        end)
        -- Later cases share the fixture; clean up even when rg fails.
        os.remove(project .. '/.gitignore'); os.remove(project .. '/keep.lua')
        if not ok then error(err, 0) end
    end)
    spec.it('validates query and budgets before indexing', function()
        for _, query in ipairs({ '', '  ', 'a\0b', '\255', string.rep('x', 4097) }) do
            spec.equal(pcall(service.explore, project, query), false)
        end
        for _, budget in ipairs({ 0, -1, 255, 262145, 1.5, math.huge, '1000', false }) do
            spec.equal(pcall(service.explore, project, 'modified', { budget = budget }), false)
        end
    end)
    spec.it('keeps truncated Chinese output valid and within a strict byte budget', function()
        local out, truncated = text.limit(string.rep('你好世界', 100), 257)
        spec.truthy(truncated)
        spec.truthy(#out <= 257)
        spec.truthy(utf8.len(out))
        spec.contains(out, 'truncated')
        local output, info = service.explore(project, 'modified', { cache_path = cache, budget = 256 })
        spec.truthy(#output <= 256)
        spec.truthy(utf8.len(output))
        spec.truthy(info.truncated)
        spec.truthy(utf8.len(text.valid('\255\192\128\237\160\128你好')))
    end)
    spec.it('sees deletion on the next query', function()
        os.remove(project .. '/中文.lua')
        local status = service.status(project)
        spec.equal(status.files, 0)
        spec.equal(status.refresh.removed, 1)
    end)
end)

assert(xutils.rmtree(root))
do
    local svc = require('codeoutline.service')
    local root = assert(xutils.temp_file(os.getenv('TEMP') or os.getenv('TMPDIR') or '/tmp')):gsub('\\', '/')
    os.remove(root)
    assert(xutils.mkdir_p(root .. '/project'))
    local project = root .. '/project'
    local opts = { cache_path = root .. '/cache.idx', lister = 'walk' }
    local function write(name, bytes)
        local f = assert(io.open(project .. '/' .. name, 'wb'))
        assert(f:write(bytes)); assert(f:close())
    end
    local chinese = '\214\208\206\196'
    -- GBK decoding uses the system converter (glibc-gconv-extra on EL8/EL9);
    -- without it the GBK cases are skipped, like the rg case above.
    local gbk_available = (pcall(xutils.to_utf8, chinese, 'gbk')) and xutils.to_utf8(chinese, 'gbk') == '中文'
    local function gbk_or_skip()
        if not gbk_available then print('SKIP system iconv has no GBK converter') end
        return gbk_available
    end
    write('gbk.lua', 'function abc()\r\n -- ' .. chinese .. '\r\n return "' .. chinese .. '"\r\nend\r\n')
    write('unused.lua', 'function unused() return "' .. chinese .. '" end\n')
    write('bom.lua', '\239\187\191function bom() return "中文" end\n')
    write('utf.lua', 'function plain() return "中文😀" end\n')

    spec.describe('on-demand source encoding', function()
        spec.it('initial indexing does not call the decoder', function()
            local original = xutils.to_utf8
            xutils.to_utf8 = function() error('unexpected eager decode') end
            local ok, idx = pcall(svc.get, project, opts)
            xutils.to_utf8 = original
            assert(ok, idx)
            spec.equal(idx.files['gbk.lua'].encoding, nil)
            spec.equal(idx.files['unused.lua'].encoding, nil)
        end)
        spec.it('finds ASCII functions and decodes comments and strings only on demand', function()
            if not gbk_or_skip() then return end
            local output = svc.explore(project, 'abc', opts)
            spec.contains(output, '2\t -- 中文')
            spec.contains(output, '3\t return "中文"')
            assert(utf8.len(output))
            local idx = svc.get(project, opts)
            spec.equal(idx.files['gbk.lua'].encoding, 'gbk')
            for _, node in ipairs(idx.files['gbk.lua'].nodes) do
                spec.equal(node.start_byte, nil); spec.equal(node.name_start, nil)
                spec.equal(node.end_byte, nil); spec.equal(node.name_end, nil)
            end
            spec.equal(idx.files['unused.lua'].encoding, nil)
            spec.equal(idx.query_sources, nil)
        end)
        spec.it('handles UTF-8 with and without BOM and reuses confirmed metadata', function()
            spec.contains(svc.explore(project, 'bom plain', opts), '中文')
            local idx = svc.get(project, opts)
            spec.equal(idx.files['bom.lua'].encoding, 'utf-8-bom')
            spec.equal(idx.files['utf.lua'].encoding, 'utf-8')
            local original = xutils.to_utf8
            xutils.to_utf8 = function() error('already confirmed UTF-8') end
            local ok, output = pcall(svc.explore, project, 'bom plain', opts)
            xutils.to_utf8 = original
            assert(ok, output)
        end)
        spec.it('persists repaired records and invalidates encoding after editing', function()
            if not gbk_or_skip() then return end
            svc.forget(project)
            local idx = svc.get(project, opts)
            spec.truthy(idx.cache_loaded)
            spec.equal(idx.files['gbk.lua'].encoding, 'gbk')
            for _, node in ipairs(idx.files['gbk.lua'].nodes) do
                spec.equal(node.start_byte, nil); spec.equal(node.name_start, nil)
                spec.equal(node.end_byte, nil); spec.equal(node.name_end, nil)
            end
            spec.contains(svc.explore(project, 'abc', opts), '中文')
            write('gbk.lua', 'function abc() return "现在是 UTF-8" end\n')
            idx = svc.get(project, opts)
            spec.equal(idx.files['gbk.lua'].encoding, nil)
            spec.contains(svc.explore(project, 'abc', opts), '现在是 UTF-8')
            spec.equal(idx.files['gbk.lua'].encoding, 'utf-8')
        end)
        spec.it('retries GBK repairs with symbol-only tables in lazy explore', function()
            if not gbk_or_skip() then return end
            write('lazy_tail.lua', 'function lazy_tail()\n local s = "\129\92"\n return lazy_helper()\nend\nfunction lazy_helper() return 1 end\n')
            local lazy = svc.explore(project, 'lazy_tail lazy_helper', { cache_path = opts.cache_path,
                lister = opts.lister, relationships = 'lazy' })
            spec.contains(lazy, 'lazy_tail -> lazy_helper')
            local _, symbols = svc.resident(project)
            spec.truthy(symbols.symbols_only); spec.equal(symbols.out, nil)
            spec.equal(lazy, svc.explore(project, 'lazy_tail lazy_helper', opts))
        end)
        spec.it('repairs GBK backslash-tail strings and discovers swallowed calls', function()
            if not gbk_or_skip() then return end
            write('tail.lua', 'function tail()\n local s = "\129\92"\n return helper()\nend\nfunction helper() return 1 end\n')
            local output = svc.explore(project, 'tail.lua', opts)
            spec.contains(output, 'helper')
            output = svc.explore(project, 'tail helper', opts)
            spec.contains(output, 'tail -> helper')
            spec.contains(output, '乗')
        end)
        spec.it('rejects invalid bytes instead of silently replacing comments', function()
            write('bad.lua', 'function bad()\n -- \255\nend\n')
            local ok, err = pcall(svc.explore, project, 'bad', opts)
            spec.equal(ok, false)
            spec.contains(tostring(err), 'bad.lua: Invalid GBK')
            write('bad.lua', 'function bad() return "fixed" end\n')
            spec.contains(svc.explore(project, 'bad', opts), 'fixed')
        end)
        spec.it('rejects a file changed between refresh and deferred decoding', function()
            local idx = svc.get(project, opts)
            write('utf.lua', 'function plain() return 42 end\n')
            local ok, err = pcall(idx.query_source, idx, 'utf.lua')
            spec.equal(ok, false)
            spec.contains(tostring(err), 'source changed during query')
            idx.query_sources = nil
            spec.contains(svc.explore(project, 'plain', opts), '42')
        end)
    end)
    svc.forget(project)
    assert(xutils.rmtree(root))
end

return { __init = function()
    if spec.finish() > 0 then os.exit(1) end
    xthread.stop(0)
end }
