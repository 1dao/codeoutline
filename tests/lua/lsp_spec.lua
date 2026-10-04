package.path = 'scripts/?.lua;' .. package.path
local spec = dofile('tests/lua/spec_helper.lua')
local parse = require('codeoutline.parse')
local docs = require('codeoutline.documents')
local lsp = require('codeoutline.lsp')
local service = require('codeoutline.service')
local control = require('codeoutline.control')
local graph = require('codeoutline.graph')
local root = assert(xutils.temp_file(os.getenv('TEMP') or os.getenv('TMPDIR') or '/tmp')):gsub('\\', '/')
os.remove(root); assert(xutils.mkdir_p(root))
local function write(path, source)
    local f = assert(io.open(path, 'wb')); assert(f:write(source)); assert(f:close())
end
local opts = { cache_path = root .. '/cache.idx', lister = 'walk' }
write(root .. '/a.lua', 'function original() end\n')

spec.describe('symbol byte ranges', function()
    local examples = {
        { 'sample.c', 'int sample(int sample) { return sample; }', 'sample' },
        { 'sample.cpp', 'int Box::sample(int sample) { return sample; }', 'sample' },
        { 'sample.py', '@decorate\ndef sample(sample):\n    return sample\n', 'sample' },
        { 'sample.java', 'class Box { int sample(int sample) { return sample; } }', 'sample' },
        { 'sample.lua', 'function Box:sample(sample) return sample end', 'sample' },
        { 'sample.go', 'package main\nfunc sample(sample int) int { return sample }', 'sample' },
        { 'sample.ts', 'export function sample(sample: number) { return sample; }', 'sample' },
        { 'sample.cs', 'class Box { int sample(int sample) { return sample; } }', 'sample' },
        { 'sample.rs', 'fn sample(sample: i32) -> i32 { sample }', 'sample' },
    }
    for _, example in ipairs(examples) do
        spec.it('selects the declaration name in ' .. example[1], function()
            local source, name = example[2], example[3]
            local rec, found = parse.parse(example[1], source), false
            for _, node in ipairs(rec.nodes) do
                spec.truthy(node.start_byte <= node.name_start and node.name_end <= node.end_byte)
                spec.truthy(node.end_byte <= #source)
                if node.name == name then
                    found = true
                    spec.equal(source:sub(node.name_start + 1, node.name_end), name)
                    spec.equal(node.name_start, source:find(name, 1, true) - 1)
                end
            end
            spec.truthy(found)
            local compact = parse.parse(example[1], source, { ranges = false })
            spec.equal(#compact.nodes, #rec.nodes)
            for i, node in ipairs(compact.nodes) do
                for _, key in ipairs({ 'start_byte', 'end_byte', 'name_start', 'name_end' }) do
                    spec.equal(node[key], nil)
                end
                for key, value in pairs(node) do
                    if type(value) ~= 'table' then spec.equal(value, rec.nodes[i][key]) end
                end
            end
            spec.equal(compact.refs.start, nil)
            for key, column in pairs(compact.refs) do
                spec.equal(#rec.refs[key], #column)
                for i, value in ipairs(column) do spec.equal(rec.refs[key][i], value) end
            end
        end)
    end
    local calls = {
        { 'calls.c', 'int f(void) { return g(1) + obj->h(); }', { 'g', 'h' } },
        { 'calls.cpp', 'int f() { return ns::g(1) + obj.h(); }', { 'g', 'h' } },
        { 'calls.py', 'def f():\n    return g(1) + self.h()\n', { 'g', 'h' } },
        { 'calls.java', 'class A { int f() { return g(1) + new B().h(); } }', { 'g', 'B', 'h' } },
        { 'calls.lua', 'function f() return g(1) + obj:h() + M.k "s" end', { 'g', 'h', 'k' } },
        { 'calls.go', 'package main\nfunc f() int { return g(1) + obj.H() }', { 'g', 'H' } },
        { 'calls.ts', 'function f() { return g(1) + this.h(); }', { 'g', 'h' } },
        { 'calls.cs', 'class A { int f() { return g(1) + this.h(); } }', { 'g', 'h' } },
        { 'calls.rs', 'fn f() -> i32 { g(1) + obj.h() }', { 'g', 'h' } },
    }
    for _, example in ipairs(calls) do
        spec.it('records exact call name ranges in ' .. example[1], function()
            local source = example[2]
            local rec = parse.parse(example[1], source)
            local names = {}
            for i, ref_name in ipairs(rec.refs.name) do
                local a = rec.refs.start[i]
                spec.truthy(a, 'missing range for ' .. ref_name)
                spec.equal(source:sub(a + 1, rec.refs.stop[i]), ref_name)
                names[#names + 1] = ref_name
            end
            spec.equal(table.concat(names, ','), table.concat(example[3], ','))
        end)
    end
    spec.it('handles macro directives, anonymous typedefs and operators', function()
        local source = '#define MACRO(x) (x)\ntypedef struct { int value; } Alias;\n'
        local rec = parse.parse('special.c', source)
        for _, node in ipairs(rec.nodes) do
            spec.equal(source:sub(node.name_start + 1, node.name_end), node.name)
            spec.truthy(node.name_end <= node.end_byte)
        end
        local cpp = 'struct Box { int operator()(int v) { return v; } ~Box() {} };'
        for _, node in ipairs(parse.parse('special.cpp', cpp).nodes) do
            if node.kind == 'method' or node.kind == 'destructor' then
                spec.equal(cpp:sub(node.name_start + 1, node.name_end), node.name)
            end
        end
    end)
    spec.it('ends Python blocks before the next statement', function()
        local source = 'def first():\n    return 1\ndef second():\n    return 2\n'
        local doc = docs.new('file:///sample.py', source)
        local symbols = lsp.document_symbols(doc, true)
        spec.equal(symbols[1].range['end'].line, 1)
        spec.equal(symbols[2].selectionRange.start.line, 2)
    end)
    spec.it('keeps out-of-line methods outside lexical class ranges', function()
        local source = 'struct Box { int first(); int second(); };\nint Box::first() { return 1; }\nint Box::second() { return 2; }'
        local symbols = lsp.document_symbols(docs.new('file:///sample.cpp', source), true)
        local methods = 0
        for _, symbol in ipairs(symbols) do
            if symbol.name == 'Box' then spec.equal(symbol.range['end'].line, 0)
            else methods = methods + 1 end
        end
        spec.equal(methods, 2)
    end)
    spec.it('selects C# generic names, destructors and operator tokens', function()
        local source = 'class Box { T sample<T>(T x) { return x; } ~Box() {} public static Box operator +(Box a, Box b) { return a; } }'
        local found = {}
        for _, node in ipairs(parse.parse('sample.cs', source).nodes) do
            local name = source:sub(node.name_start + 1, node.name_end)
            if node.name == 'sample' then spec.equal(name, 'sample'); found.sample = true end
            if node.name == '~Box' then spec.equal(name, '~Box'); found.destructor = true end
            if node.name == 'operator+' then spec.equal(name:gsub('%s', ''), 'operator+'); found.operator = true end
        end
        spec.truthy(found.sample and found.destructor and found.operator)
    end)
end)

spec.describe('document positions and transport', function()
    spec.it('converts UTF-8 bytes to UTF-16 columns and handles CRLF', function()
        local source = '中😀x\r\nnext\rlast\n'
        local doc = docs.new('file:///sample.lua', source)
        spec.equal(doc:position(#'中😀').character, 3)
        spec.equal(doc:position(#'中😀x\r\n').line, 1)
        spec.equal(doc:position(#'中😀x\r\nnext\r').line, 2)
        spec.equal(doc:position(#source).line, 3)
        spec.equal(pcall(function() doc:position(1) end), false)
    end)
    spec.it('converts UTF-16 positions back to byte offsets and clamps past the end', function()
        local source = '中😀x\r\nnext\rlast'
        local doc = docs.new('file:///sample.lua', source)
        for _, offset in ipairs({ 0, #'中', #'中😀', #'中😀x', #'中😀x\r\n' + 2, #'中😀x\r\nnext\r' + 1 }) do
            spec.equal(doc:offset(doc:position(offset)), offset)
        end
        spec.equal(doc:offset({ line = 0, character = 99 }), #'中😀x')
        spec.equal(doc:offset({ line = 9, character = 0 }), #source)
        spec.equal(pcall(function() doc:offset({ line = -1, character = 0 }) end), false)
    end)
    spec.it('normalizes BOM offsets for both disk and draft documents', function()
        local source = '\239\187\191function test() end'
        local doc = docs.new('file:///sample.lua', source)
        local symbol = lsp.document_symbols(doc, true)[1]
        spec.equal(symbol.selectionRange.start.character, 9)
    end)
    spec.it('uses languageId for extensionless documents', function()
        local doc = docs.new('file:///extensionless', 'function sample() end', 1, 'lua')
        spec.equal(lsp.document_symbols(doc, true)[1].name, 'sample')
    end)
    spec.it('indexes UTF-16 prefixes on long lines without splitting characters', function()
        local source = string.rep('中😀', 500) .. '\r\n' .. string.rep('x', 800) .. '\nlast'
        local doc = docs.new('file:///sample.lua', source)
        spec.truthy(#doc.checkpoints.offsets > 1)
        spec.equal(doc:position(3500).character, 1500)
        spec.equal(doc:position(3501).character, 1500)
        spec.equal(doc:position(3502).line, 1)
        spec.equal(doc:position(4302).character, 800)
        spec.equal(doc:position(#source).character, 4)
        spec.equal(pcall(function() doc:position(3499) end), false)
    end)
    spec.it('round trips escaped local and UNC paths and normalizes dot segments', function()
        for _, path in ipairs({ 'C:/中文 空格/#name.lua', '//server/share/中文.lua', '/tmp/a%b.lua' }) do
            spec.equal(docs.path(docs.uri(path)), path)
        end
        spec.equal(docs.path('file:///C:/work/sub/../new.lua'), 'C:/work/new.lua')
        spec.equal(pcall(docs.path, 'file:///tmp/%00'), false)
        spec.equal(pcall(docs.path, 'file:///tmp/%zz'), false)
    end)
    spec.it('frames UTF-8 JSON by bytes and accepts split and concatenated frames', function()
        local reader, bodies = lsp.reader(), {}
        local framed = lsp.frame({ jsonrpc = '2.0', id = 1, result = '中😀' })
        local all = framed .. framed
        for i = 1, #all do reader:feed(all:sub(i, i), function(body) bodies[#bodies + 1] = body end) end
        spec.equal(#bodies, 2); spec.truthy(reader:complete())
        spec.equal(xutils.json_unpack(bodies[1]).result, '中😀')
        spec.equal(pcall(function() lsp.reader():feed('Content-Length: -1\r\n\r\n', function() end) end), false)
        spec.equal(pcall(function() lsp.reader():feed('Content-Length: 1\r\nContent-Length: 1\r\n\r\nx', function() end) end), false)
    end)
end)

spec.describe('resident state and cancellation', function()
    spec.it('persists compact nodes and recovers exact positions by reparsing', function()
        local index = require('codeoutline.index')
        local idx = index.open(root, opts)
        idx:refresh(); idx:save()
        local loaded = index.open(root, opts)
        spec.truthy(loaded.cache_loaded)
        local rec = loaded.files['a.lua']
        for _, node in ipairs(rec.nodes) do
            spec.equal(node.start_byte, nil); spec.equal(node.name_start, nil)
            spec.equal(node.end_byte, nil); spec.equal(node.name_end, nil)
        end
        local source = loaded:query_source('a.lua')
        local node = parse.parse('a.lua', source).nodes[1]
        spec.equal(node.name, rec.nodes[1].name)
        spec.equal(source:sub(node.name_start + 1, node.name_end), 'original')
        spec.equal(node.name_start, 9)
    end)

    spec.it('propagates a one-shot parser cancellation instead of treating it as invalid source', function()
        local idx, G = service.get(root, opts)
        write(root .. '/a.lua', 'function parser_cancelled() end\n')
        local original = parse.parse
        parse.parse = function()
            control.callback = nil
            error(control.cancelled(), 0)
        end
        local ok, err = pcall(service.get, root, opts)
        parse.parse = original
        spec.equal(ok, false); spec.equal(err.code, 'cancelled')
        write(root .. '/a.lua', 'function original() end\n')
        local still, same = service.get(root, opts)
        spec.equal(still, idx); spec.equal(same, G)
    end)
    spec.it('does not swallow cancellation while validating a cached index', function()
        local index = require('codeoutline.index')
        service.get(root, opts)
        control.callback = function() control.callback = nil; error(control.cancelled(), 0) end
        local ok, err = pcall(index.open, root, opts)
        control.callback = nil
        spec.equal(ok, false); spec.equal(err.code, 'cancelled')
    end)
    spec.it('keeps committed files when building symbol tables is interrupted', function()
        local idx = service.get(root, opts)
        idx.symbol_tables = nil
        write(root .. '/a.lua', 'function renamed() end\n')
        local build = graph.build
        graph.build = function() error(control.cancelled(), 0) end
        local ok, err = pcall(service.get, root, opts)
        graph.build = build
        spec.equal(ok, false); spec.equal(err.code, 'cancelled')
        spec.equal(idx.files['a.lua'].nodes[1].name, 'renamed'); spec.nil_value(idx.symbol_tables)
        local still, refreshed = service.get(root, opts)
        spec.equal(still, idx); spec.truthy(refreshed.by_name.renamed)
        spec.equal(refreshed.generation, idx.generation)
    end)
    spec.it('preserves the resident index when a read-only query is cancelled', function()
        local idx, G = service.get(root, opts)
        local explore = require('codeoutline.explore')
        local run = explore.run
        explore.run = function() error(control.cancelled(), 0) end
        local ok, err = pcall(service.explore, root, 'renamed', opts)
        explore.run = run
        spec.equal(ok, false); spec.equal(err.code, 'cancelled')
        spec.nil_value(idx.query_sources)
        local still, same = service.get(root, opts)
        spec.equal(still, idx); spec.equal(same, G)
    end)
end)

local function fake_submit(req, done)
    done(true, req.method == 'lsp_symbols' and {} or true)
    return 'test-job'
end

spec.describe('LSP sessions', function()
    spec.it('cancels immediately and discards a late result even when an ID is reused', function()
        local output, jobs, cancelled = {}, {}, {}
        local session = lsp.new({}, function(msg) output[#output + 1] = msg end,
            function(req, done) jobs[#jobs + 1] = done; return tostring(#jobs) end,
            function(id) cancelled[id] = true end, function() end)
        local function send(method, params, id)
            session:accept(xutils.json_pack({ jsonrpc = '2.0', method = method, params = params or {}, id = id }))
        end
        send('initialize', { capabilities = {} }, 1); send('initialized')
        send('workspace/symbol', { query = '' }, 2)
        send('$/cancelRequest', { id = 2 })
        spec.equal(output[#output].error.code, -32800); spec.truthy(cancelled['1'])
        send('workspace/symbol', { query = '' }, 2)
        local before = #output
        jobs[1](true, { { name = 'late' } })
        spec.equal(#output, before)
        jobs[2](true, {})
        spec.equal(output[#output].id, 2); spec.equal(#output[#output].result, 0)
    end)
    spec.it('returns drafts without worker submission when any workspace root is unready', function()
        local output, jobs = {}, {}
        local session = lsp.new({}, function(msg) output[#output + 1] = msg end,
            function(req, done) jobs[#jobs + 1] = { req = req, done = done }; return tostring(#jobs) end,
            function() end, function() end)
        local function send(method, params, id)
            session:accept(xutils.json_pack({ jsonrpc = '2.0', method = method, params = params or {}, id = id }))
        end
        local other = root .. '/second-root'
        assert(xutils.mkdir_p(other))
        send('initialize', { rootUri = docs.uri(root), capabilities = {} }, 1)
        send('initialized')
        send('textDocument/didOpen', { textDocument = { uri = docs.uri(root .. '/draft.lua'),
            languageId = 'lua', version = 1, text = 'function immediate_draft() end' } })
        -- A ready root must not cause a query to queue behind another unready root.
        session.roots = { root, other }; session.ready[root] = true
        local before = #jobs
        send('workspace/symbol', { query = 'immediate' }, 2)
        spec.equal(#jobs, before)
        spec.equal(output[#output].result[1].name, 'immediate_draft')
        spec.equal(next(session.pending), nil)
        session.ready[other] = true
        send('workspace/symbol', { query = 'immediate' }, 3)
        spec.equal(#jobs, before + 1); spec.equal(jobs[#jobs].req.method, 'lsp_symbols')
        jobs[#jobs].done(true, {})
        spec.equal(output[#output].result[1].name, 'immediate_draft')
    end)
    spec.it('reports busy navigation and incomplete completion until initial indexing finishes', function()
        local output, complete
        local session = lsp.new({}, function(msg) output = msg end,
            function(req, done) complete = done; return 'scan' end, function() end, function() end)
        local function send(method, id)
            session:accept(xutils.json_pack({ jsonrpc = '2.0', method = method, id = id,
                params = { rootUri = docs.uri(root), capabilities = {} } }))
        end
        send('initialize', 1); send('initialized')
        send('textDocument/definition', 2); spec.equal(output.error.code, -32803)
        send('textDocument/completion', 3); spec.truthy(output.result.isIncomplete)
        complete(true, true)
        send('textDocument/rename', 4); spec.equal(output.error.code, -32601)
    end)

    spec.it('handles progress responses independently from client request IDs', function()
        local output = {}
        local session = lsp.new({}, function(msg) output[#output + 1] = msg end, fake_submit, function() end, function() end)
        local function send(msg) msg.jsonrpc = '2.0'; session:accept(xutils.json_pack(msg)) end
        send({ id = 1, method = 'initialize', params = { rootUri = docs.uri(root), capabilities = { window = { workDoneProgress = true } } } })
        send({ method = 'initialized' })
        session:begin_index(root)
        local create = output[#output]
        spec.equal(create.method, 'window/workDoneProgress/create')
        session:end_index(root, 'done')
        send({ id = create.id, method = 'workspace/symbol', params = { query = 'renamed' } })
        spec.equal(output[#output].id, create.id)
        spec.truthy(output[#output].result)
        send({ id = create.id, result = xutils.json_null })
        spec.equal(output[#output - 1].params.value.kind, 'begin')
        spec.equal(output[#output].params.value.kind, 'end')
    end)
    spec.it('isolates drafts between sessions without changing disk state', function()
        local output = {}
        local function make()
            return lsp.new({}, function(msg) output[#output + 1] = msg end, fake_submit, function() end, function() end)
        end
        local function send(session, method, params, id)
            session:accept(xutils.json_pack({ jsonrpc = '2.0', method = method, params = params, id = id }))
        end
        local a, b = make(), make()
        local uri = docs.uri(root .. '/new.lua')
        for _, session in ipairs({ a, b }) do
            send(session, 'initialize', { rootUri = docs.uri(root), capabilities = {} }, 1)
            send(session, 'initialized', {})
        end
        send(a, 'textDocument/didOpen', { textDocument = { uri = uri, languageId = 'lua', version = 1, text = 'function draft() end' } })
        send(a, 'workspace/symbol', { query = 'draft' }, 3)
        spec.equal(#output[#output].result, 1)
        send(b, 'workspace/symbol', { query = 'draft' }, 3)
        spec.equal(#output[#output].result, 0)
        spec.nil_value(io.open(root .. '/new.lua', 'rb'))
    end)
end)

spec.describe('shared entry and worker lifecycle', function()
    spec.it('defers installed-update exit for an LSP connection but retains MCP idle exit', function()
        local saved = { arg = arg, xthread = xthread, xnet = xnet, xshared = xshared,
            read = xutils.read_stdin, stdout = io.stdout, stderr = io.stderr, getenv = os.getenv }
        local ok, err = pcall(function()
            local input, stopped
            local shared = { set = function() end }
            xshared = { create = function() return shared end }
            xnet = { init = function() return true end, uninit = function() end }
            xthread = { create_thread = function() return true end, post = function() return true end,
                stop = function(code) stopped = code end, shutdown_thread = function() end }
            io.stdout = { write = function() end, flush = function() end }
            io.stderr = io.stdout
            os.getenv = function(name)
                if name == 'CODEOUTLINE_AUTO_UPDATE' then return '0' end
                if name == 'CODEOUTLINE_EXIT_ON_UPDATE' then return '1' end
                return saved.getenv(name)
            end
            xutils.read_stdin = function() local value = input or ''; input = nil; return value end
            arg = { 'STDIO=1', 'LSP=1' }
            local entry = dofile('scripts/codeoutline/main.lua')
            entry.__init(); entry.__thread_handle(2, 'worker_ready')
            entry.__thread_handle(3, 'update_result', nil, 'test-update')
            entry.__update(); spec.equal(stopped, nil)
            input = lsp.frame({ jsonrpc = '2.0', id = 1, method = 'initialize', params = { capabilities = {} } })
                .. lsp.frame({ jsonrpc = '2.0', id = 2, method = 'shutdown' })
            entry.__update(); spec.equal(stopped, nil)
            input = lsp.frame({ jsonrpc = '2.0', method = 'exit' })
            entry.__update(); spec.equal(stopped, 0)
            entry.__uninit()
            stopped = nil; arg = { 'STDIO=1' }
            entry = dofile('scripts/codeoutline/main.lua')
            entry.__init(); entry.__thread_handle(2, 'worker_ready')
            entry.__thread_handle(3, 'update_result', nil, 'test-update')
            entry.__update(); spec.equal(stopped, 0)
            entry.__uninit()
        end)
        arg, xthread, xnet, xshared = saved.arg, saved.xthread, saved.xnet, saved.xshared
        xutils.read_stdin, io.stdout, io.stderr, os.getenv = saved.read, saved.stdout, saved.stderr, saved.getenv
        if not ok then error(err, 0) end
    end)
    spec.it('refreshes and queries LSP without a graph, and executes cancellation directly', function()
        local saved = { xthread = xthread, xshared = xshared, build = graph.build }
        local ok, err = pcall(function()
            local results = {}
            local flags = { ['cancel:cancelled'] = true }
            xshared = { dict = function() return {
                get = function(_, key) return flags[key] end,
                delete = function(_, key) flags[key] = nil end } end }
            xthread = { post = function(thread, op, id, success, result)
                spec.equal(thread, 1); spec.equal(op, 'worker_result')
                results[id] = { ok = success, result = result }
                return true
            end }
            service.forget(root)
            graph.build = function() error('LSP must not build a call graph') end
            local worker = dofile('scripts/codeoutline/index_worker.lua')
            local function run(id, req)
                req.projectPath, req.allowedRoots, req.deadline = root, { root }, xtimer.now_ms() + 10000
                worker.__thread_handle(1, 'run', id, req)
                spec.truthy(results[id], 'worker must complete directly without a continuation')
                return results[id]
            end
            spec.truthy(run('initial', { method = 'lsp_refresh' }).ok)
            local _, G = service.resident(root); spec.equal(G, nil)
            write(root .. '/a.lua', 'function worker_only() end\n')
            spec.truthy(run('save', { method = 'lsp_refresh', paths = { root .. '/a.lua' } }).ok)
            local symbols = run('symbols', { method = 'lsp_symbols', roots = { root },
                query = 'worker_only', exclude = {}, limit = 200 })
            spec.truthy(symbols.ok); spec.equal(#symbols.result, 1)
            spec.equal(symbols.result[1].name, 'worker_only')
            spec.equal(symbols.result[1].location.range.start.character, 9)
            local cancelled = run('cancelled', { method = 'lsp_refresh' })
            spec.equal(cancelled.ok, false); spec.contains(cancelled.result, 'cancelled')
            spec.equal(control.callback, nil)
            graph.build = saved.build
            spec.contains(service.explore(root, 'worker_only'), 'worker_only')
            local _, built = service.resident(root); spec.truthy(built)
            graph.build = function() error('built symbol tables are updated per file, not rebuilt') end
            write(root .. '/a.lua', 'function after_graph() end\n')
            spec.truthy(run('changed', { method = 'lsp_refresh', paths = { root .. '/a.lua' } }).ok)
            local idx, current = service.resident(root)
            spec.equal(current, built); spec.truthy(current.by_name.after_graph)
            spec.nil_value(current.by_name.worker_only); spec.equal(current.generation, idx.generation)
        end)
        xthread, xshared, graph.build = saved.xthread, saved.xshared, saved.build
        service.configure({ watch = false, max_projects = 8 })
        if not ok then error(err, 0) end
    end)

end)

local navigation = require('codeoutline.navigation')
local nav_root = root .. '-nav'
assert(xutils.mkdir_p(nav_root))
nav_root = assert(require('codeoutline.path').canonical(nav_root))
local function nav_write(rel, source) write(nav_root .. '/' .. rel, source) end
nav_write('util.h', 'int helper(int x);\n')
nav_write('util.c', '#include "util.h"\nint helper(int x) { return x + 1; }\n')
nav_write('main.c', '#include "util.h"\nstatic int twice(int v) { return helper(helper(v)); }\n'
    .. 'int main(void) { return twice(1); }\n')
nav_write('m.lua', 'local M = {}\nfunction M.go(n)\n  if n > 0 then return M.go(n - 1) end\n  return leaf()\nend\n'
    .. 'function leaf() return 1 end\nM.go(3)\nreturn M\n')
nav_write('shape.py', 'class Shape:\n    def area(self):\n        return self.side() * 2\n'
    .. '    def side(self):\n        return 1\n')
local nav_uri = function(rel) return docs.uri(nav_root .. '/' .. rel) end

local function nav(req)
    req.session, req.root = req.session or 'spec', nav_root
    local out = navigation.execute(req)
    return out.result, out
end
local function range_text(rel, range)
    local doc = docs.read(nav_root .. '/' .. rel)
    return doc.source:sub(doc:offset(range.start) + 1, doc:offset(range['end']))
end

spec.describe('LSP navigation', function()
    service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
    spec.it('goes to the definition across files and from a prototype to its body', function()
        local result = nav({ method = 'lsp_definition', uri = nav_uri('main.c'), position = { line = 1, character = 35 } })
        spec.equal(#result, 1)
        spec.equal(result[1].uri, nav_uri('util.c'))
        spec.equal(range_text('util.c', result[1].range), 'helper')
        local from_decl = nav({ method = 'lsp_definition', uri = nav_uri('util.h'), position = { line = 0, character = 5 } })
        spec.equal(from_decl[1].uri, nav_uri('util.c'))
        spec.equal(nav({ method = 'lsp_definition', uri = nav_uri('main.c'), position = { line = 1, character = 1 } }), false)
    end)
    spec.it('falls back to a visible prototype when definitions are ambiguous', function()
        for _, dir in ipairs({ 'api', 'impl_a', 'impl_b', 'user' }) do assert(xutils.mkdir_p(nav_root .. '/' .. dir)) end
        nav_write('api/proto.h', 'int ambiguous_fn(int x);\n')
        nav_write('impl_a/a.c', 'int ambiguous_fn(int x) { return x; }\n')
        nav_write('impl_b/b.c', 'int ambiguous_fn(int x) { return -x; }\n')
        nav_write('user/use.c', '#include "../api/proto.h"\nint use_it(void) { return ambiguous_fn(1); }\n')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local ok, err = pcall(function()
            local proto = nav({ method = 'lsp_definition', uri = nav_uri('user/use.c'), position = { line = 1, character = 30 } })
            spec.equal(#proto, 1); spec.equal(proto[1].uri, nav_uri('api/proto.h'))
            local defs = nav({ method = 'lsp_definition', uri = nav_uri('api/proto.h'), position = { line = 0, character = 6 } })
            spec.equal(#defs, 2)
        end)
        for _, rel in ipairs({ 'api/proto.h', 'impl_a/a.c', 'impl_b/b.c', 'user/use.c' }) do os.remove(nav_root .. '/' .. rel) end
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        if not ok then error(err, 0) end
    end)
    spec.it('resolves recursion, file-scope calls and self members', function()
        local recursion = nav({ method = 'lsp_definition', uri = nav_uri('m.lua'), position = { line = 2, character = 25 } })
        spec.equal(recursion[1].range.start.line, 1)
        local top = nav({ method = 'lsp_definition', uri = nav_uri('m.lua'), position = { line = 6, character = 3 } })
        spec.equal(range_text('m.lua', top[1].range), 'go')
        local member = nav({ method = 'lsp_definition', uri = nav_uri('shape.py'), position = { line = 2, character = 22 } })
        spec.equal(member[1].range.start.line, 3)
    end)
    spec.it('hovers with the signature and location of the target', function()
        local hover = nav({ method = 'lsp_hover', uri = nav_uri('main.c'), position = { line = 1, character = 35 } })
        spec.contains(hover.contents.value, 'int helper(int x)')
        spec.contains(hover.contents.value, 'util.c:2')
        spec.equal(hover.contents.kind, 'markdown')
        spec.equal(range_text('main.c', hover.range), 'helper')
    end)
    spec.it('finds references of a function including declarations', function()
        local refs = nav({ method = 'lsp_references', uri = nav_uri('util.c'), position = { line = 1, character = 5 },
            includeDeclaration = true })
        local seen = {}
        for _, loc in ipairs(refs) do seen[#seen + 1] = loc.uri:match('[^/]*$') .. ':' .. loc.range.start.line end
        spec.equal(table.concat(seen, ','), 'util.h:0,util.c:1,main.c:1,main.c:1')
        local only = nav({ method = 'lsp_references', uri = nav_uri('util.c'), position = { line = 1, character = 5 } })
        spec.equal(#only, 2)
        local _, refused = nav({ method = 'lsp_references', uri = nav_uri('shape.py'), position = { line = 0, character = 7 } })
        spec.contains(refused.error, 'functions')
    end)
    spec.it('walks incoming and outgoing calls with exact call ranges', function()
        local items = nav({ method = 'lsp_prepare_calls', uri = nav_uri('util.c'), position = { line = 1, character = 5 } })
        spec.equal(items[1].name, 'helper')
        local incoming = nav({ method = 'lsp_incoming', data = items[1].data })
        spec.equal(#incoming, 1)
        spec.equal(incoming[1].from.name, 'twice')
        spec.equal(#incoming[1].fromRanges, 2)
        spec.equal(range_text('main.c', incoming[1].fromRanges[2]), 'helper')
        local outgoing = nav({ method = 'lsp_outgoing', data = incoming[1].from.data })
        spec.equal(#outgoing, 1)
        spec.equal(outgoing[1].to.name, 'helper')
        local go = nav({ method = 'lsp_prepare_calls', uri = nav_uri('m.lua'), position = { line = 1, character = 12 } })
        local callers = nav({ method = 'lsp_incoming', data = go[1].data })
        local names = {}
        for _, call in ipairs(callers) do names[#names + 1] = call.from.name .. '/' .. call.from.kind end
        table.sort(names)
        spec.equal(table.concat(names, ','), 'go/12,m.lua/1')
        local file = nil
        for _, call in ipairs(callers) do if call.from.kind == 1 then file = call.from end end
        local from_file = nav({ method = 'lsp_outgoing', data = file.data })
        spec.equal(from_file[1].to.name, 'go')
        spec.equal(#nav({ method = 'lsp_incoming', data = { path = 'missing.c', index = 1 } }), 0)
    end)
    spec.it('lets session drafts hide disk symbols and resolve unsaved files', function()
        local lua = nav_uri('m.lua')
        local fresh = nav_uri('fresh.lua')
        navigation.sync({ session = 'drafts', open = { [lua] = 2, [fresh] = 1 }, changed = {
            [lua] = { version = 2, language = 'lua', source = 'function M_go() return renamed() + made() end\n'
                .. 'function renamed() return 1 end\n' },
            [fresh] = { version = 1, language = 'lua', source = 'function made() return 2 end\n' } } })
        local renamed = nav({ session = 'drafts', method = 'lsp_definition', uri = lua, position = { line = 0, character = 24 } })
        spec.equal(renamed[1].range.start.line, 1)
        local made = nav({ session = 'drafts', method = 'lsp_definition', uri = lua, position = { line = 0, character = 37 } })
        spec.equal(made[1].uri, fresh)
        -- Another session still sees the disk file, where leaf exists and renamed does not.
        local leaf = nav({ method = 'lsp_definition', uri = lua, position = { line = 3, character = 10 } })
        spec.equal(leaf[1].range.start.line, 5)
        local gone = nav({ session = 'drafts', method = 'lsp_prepare_calls', uri = nav_uri('m.lua'),
            position = { line = 0, character = 10 } })
        spec.equal(gone[1].name, 'M_go')
        navigation.sync({ session = 'drafts', open = {} })
        local disk = nav({ session = 'drafts', method = 'lsp_definition', uri = lua, position = { line = 3, character = 10 } })
        spec.equal(disk[1].range.start.line, 5)
        navigation.close('drafts')
    end)
    spec.it('reads maintained symbol tables without rebuilding or modifying them', function()
        local idx = service.resident(nav_root)
        local G = idx:symbols()
        local before = { G.file_count, G.node_count, #G.file_order, #G.by_name.helper, G.next_node }
        local build = graph.build
        graph.build = function() error('navigation must reuse the maintained tables') end
        local ok, err = pcall(function()
            local lua = nav_uri('m.lua')
            navigation.sync({ session = 'readonly', open = { [lua] = 9, [nav_uri('extra.lua')] = 1 }, changed = {
                [lua] = { version = 9, language = 'lua', source = 'function helper() return helper() end\n' },
                [nav_uri('extra.lua')] = { version = 1, language = 'lua', source = 'function helper() end\n' } } })
            nav({ session = 'readonly', method = 'lsp_references', uri = lua, position = { line = 0, character = 10 } })
            spec.equal(table.concat({ G.file_count, G.node_count, #G.file_order, #G.by_name.helper, G.next_node }, ','),
                table.concat(before, ','))
            navigation.close('readonly')
            nav_write('later.c', 'int later_fn(void) { return helper(1); }\n')
            service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
            spec.equal(idx:symbols(), G); spec.truthy(G.by_name.later_fn)
            local def = nav({ method = 'lsp_definition', uri = nav_uri('later.c'), position = { line = 0, character = 30 } })
            spec.equal(def[1].uri, nav_uri('util.c'))
        end)
        graph.build = build
        os.remove(nav_root .. '/later.c')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        if not ok then error(err, 0) end
    end)
    spec.it('stops reference scans at the time budget and reports truncation', function()
        local budget = navigation.SCAN_SECONDS
        navigation.SCAN_SECONDS = -1
        local refs, out = nav({ method = 'lsp_references', uri = nav_uri('util.c'), position = { line = 1, character = 5 } })
        navigation.SCAN_SECONDS = budget
        spec.equal(#refs, 0); spec.truthy(out.incomplete)
    end)
    spec.it('relocates call items by name after edits and rejects stale ones', function()
        local items = nav({ method = 'lsp_prepare_calls', uri = nav_uri('util.c'), position = { line = 1, character = 5 } })
        local data = items[1].data
        data.index = 7
        spec.equal(nav({ method = 'lsp_incoming', data = data })[1].from.name, 'twice')
        data.qualified, data.name = 'vanished', 'vanished'
        spec.equal(#nav({ method = 'lsp_incoming', data = data }), 0)
    end)
end)

local function session_with(submit, init)
    local output = {}
    local session = lsp.new({}, function(msg) output[#output + 1] = msg end, submit, function() end, function() end)
    local function send(method, params, id)
        session:accept(xutils.json_pack({ jsonrpc = '2.0', method = method, params = params or {}, id = id }))
        return output[#output]
    end
    local init_params = init or {}
    init_params.rootUri, init_params.capabilities = docs.uri(nav_root), init_params.capabilities or {}
    send('initialize', init_params, 1)
    send('initialized')
    session.ready[nav_root] = true
    return session, send, output
end

spec.describe('LSP navigation requests', function()
    spec.it('advertises navigation and honours disabled features', function()
        local _, _, output = session_with(fake_submit)
        local caps = output[1].result.capabilities
        spec.truthy(caps.definitionProvider and caps.hoverProvider and caps.referencesProvider and caps.callHierarchyProvider)
        local session, send, assisted = session_with(fake_submit,
            { initializationOptions = { features = { definition = false, hover = false, documentSymbol = false } } })
        caps = assisted[1].result.capabilities
        spec.equal(caps.definitionProvider, nil); spec.equal(caps.hoverProvider, nil)
        spec.equal(caps.documentSymbolProvider, nil); spec.truthy(caps.referencesProvider)
        local reply = send('textDocument/definition', { textDocument = { uri = nav_uri('main.c') },
            position = { line = 0, character = 0 } }, 2)
        spec.equal(reply.error.code, -32601)
        spec.equal(session.state, 'ready')
    end)
    spec.it('sends draft text once per version and keeps empty results as arrays', function()
        local jobs = {}
        local session, send = session_with(function(req, done)
            if req.method == 'lsp_refresh' then return 'scan' end
            jobs[#jobs + 1] = { req = req, done = done }; return tostring(#jobs)
        end)
        local uri = nav_uri('m.lua')
        send('textDocument/didOpen', { textDocument = { uri = uri, languageId = 'lua', version = 1, text = 'x()' } })
        local position = { textDocument = { uri = uri }, position = { line = 0, character = 0 } }
        send('textDocument/definition', position, 2)
        spec.equal(jobs[1].req.method, 'lsp_definition'); spec.equal(jobs[1].req.root, nav_root)
        spec.equal(jobs[1].req.changed[uri].source, 'x()'); spec.equal(jobs[1].req.open[uri], 1)
        jobs[1].done(true, { result = {}, incomplete = false })
        send('textDocument/references', { textDocument = { uri = uri }, position = position.position,
            context = { includeDeclaration = true } }, 3)
        spec.equal(next(jobs[2].req.changed), nil); spec.truthy(jobs[2].req.includeDeclaration)
        send('textDocument/didChange', { textDocument = { uri = uri, version = 2 }, contentChanges = { { text = 'y()' } } })
        send('textDocument/hover', position, 4)
        spec.equal(jobs[3].req.changed[uri].version, 2)
        jobs[3].done(false, 'worker failed')
        send('textDocument/hover', position, 5)
        spec.equal(jobs[4].req.changed[uri].version, 2, 'a failed request resends drafts')
        jobs[4].done(true, { result = false, incomplete = false })
        jobs[2].done(true, { error = 'References currently support functions only' })
        send('callHierarchy/incomingCalls', { item = { data = { root = 'C:/elsewhere', path = 'a.c', index = 1 } } }, 6)
        spec.equal(#jobs, 4)
        send('callHierarchy/outgoingCalls', { item = { data = { root = nav_root, path = 'main.c', index = 1 } } }, 7)
        spec.equal(jobs[5].req.method, 'lsp_outgoing')
        jobs[5].done(true, { result = { { to = { name = 'x' }, fromRanges = {} } }, incomplete = true })
    end)
    spec.it('serializes empty navigation results as JSON arrays and null', function()
        local replies = {}
        local done_with = {}
        local session = lsp.new({}, function(msg) replies[#replies + 1] = xutils.json_pack(msg) end,
            function(req, done) done(true, done_with[req.method]); return 'job' end, function() end, function() end)
        local function send(method, params, id)
            session:accept(xutils.json_pack({ jsonrpc = '2.0', method = method, params = params or {}, id = id }))
            return replies[#replies]
        end
        send('initialize', { rootUri = docs.uri(nav_root), capabilities = {} }, 1); send('initialized')
        session.ready[nav_root] = true
        local position = { textDocument = { uri = nav_uri('main.c') }, position = { line = 0, character = 0 } }
        done_with.lsp_definition = { result = {}, incomplete = false }
        spec.contains(send('textDocument/definition', position, 2), '"result":[]')
        done_with.lsp_hover = { result = false, incomplete = false }
        spec.contains(send('textDocument/hover', position, 3), '"result":null')
        done_with.lsp_outgoing = { result = { { to = { name = 'x' }, fromRanges = {} } }, incomplete = true }
        local warned = #replies
        local reply = send('callHierarchy/outgoingCalls', { item = { data = { root = nav_root, path = 'main.c', index = 1 } } }, 4)
        spec.contains(reply, '"fromRanges":[]')
        spec.contains(replies[warned + 1], 'window/showMessage')
        done_with.lsp_references = { error = 'References currently support functions only' }
        spec.contains(send('textDocument/references', position, 5), '-32803')
        spec.contains(send('textDocument/definition', { textDocument = { uri = 'file:///outside/x.c' },
            position = { line = 0, character = 0 } }, 6), '"result":[]')
    end)
    spec.it('applies drafts in the worker even when the request is cancelled', function()
        local saved = { xthread = xthread, xshared = xshared }
        local ok, err = pcall(function()
            local results = {}
            local flags = { ['cancel:nav-cancelled'] = true }
            xshared = { dict = function() return {
                get = function(_, key) return flags[key] end,
                delete = function(_, key) flags[key] = nil end } end }
            xthread = { post = function(_, _, id, success, result) results[id] = { ok = success, result = result }; return true end }
            local worker = dofile('scripts/codeoutline/index_worker.lua')
            local lua = nav_uri('m.lua')
            local base = { method = 'lsp_definition', session = 'worker', root = nav_root, uri = lua,
                position = { line = 0, character = 24 }, deadline = xtimer.now_ms() + 10000 }
            local first = {}
            for k, v in pairs(base) do first[k] = v end
            first.open = { [lua] = 2 }
            first.changed = { [lua] = { version = 2, language = 'lua',
                source = 'function M_go() return renamed() end\nfunction renamed() return 1 end\n' } }
            worker.__thread_handle(1, 'run', 'nav-cancelled', first)
            spec.equal(results['nav-cancelled'].ok, false)
            base.open, base.changed = { [lua] = 2 }, {}
            worker.__thread_handle(1, 'run', 'nav-next', base)
            spec.truthy(results['nav-next'].ok, tostring(results['nav-next'].result))
            spec.equal(results['nav-next'].result.result[1].range.start.line, 1)
            worker.__thread_handle(1, 'run', 'nav-close', { method = 'lsp_close', session = 'worker',
                deadline = xtimer.now_ms() + 10000, projectPath = nav_root, allowedRoots = { nav_root } })
            spec.truthy(results['nav-close'].ok)
        end)
        xthread, xshared = saved.xthread, saved.xshared
        service.configure({ watch = false, max_projects = 8 })
        if not ok then error(err, 0) end
    end)
end)

local completion = require('codeoutline.completion')
local comp_root = root .. '-complete'
assert(xutils.mkdir_p(comp_root .. '/pkg')); assert(xutils.mkdir_p(comp_root .. '/core'))
comp_root = assert(require('codeoutline.path').canonical(comp_root))
-- `@@` marks completion positions; marks[path] lists their byte offsets.
local comp_files = {
    ['p.h'] = 'struct Q { int depth; };\nstruct P { int x; struct Q *next; };\n',
    ['p.c'] = '#include "p.h"\nint use(struct P *p, int n) {\n  struct P local;\n  return p->@@ + local.@@ + p->next->@@;\n}\n',
    ['box.hpp'] = 'class Box { public: int w; Box* next; int name() const; static Box make(int k); };\n',
    ['box.cpp'] = '#include "box.hpp"\nint Box::name() const { return this->@@; }\nint other() { Box b; return b.next->@@; }\n'
        .. 'int st() { return Box::@@; }\n',
    ['Box.java'] = 'class Box { int w; Box next() { return null; } static Box of(int k) { return new Box(); } }\n',
    ['Use.java'] = 'class Use { void run() { var x = Box.of(1); x.next().@@ } }\n',
    ['pkg/store.py'] = 'class Store:\n    def __init__(self):\n        self.items = []\n    def save(self, item):\n        return self.@@\n',
    ['pkg/api.py'] = 'from pkg import store\nfrom .store import Store\ndef handle(req):\n    s = Store()\n    s.@@\n    store.@@\n'
        .. 'def later():@@\n    return "a.@@"\n',
    ['core/text.lua'] = 'local M = {}\nM.limit = 10\nfunction M.trim(s) return s end\nfunction M:split() return self.@@ end\nreturn M\n',
    ['core/main.lua'] = 'local text = require("core.text")\nlocal function go(s, count)\n  local tmp = 1\n  return text.@@ or text:@@\nend\n',
    ['box.go'] = 'package main\ntype Box struct { W int; Next *Box }\nfunc (b *Box) Area() int { return b.@@ }\n'
        .. 'func use() { v := &Box{}; v.Next.@@ }\n',
    ['boxy.rs'] = 'struct Boxy { w: i32, next: Option<Box<Boxy>> }\nimpl Boxy { fn new(k: i32) -> Boxy { Boxy { w: k, next: None } }\n'
        .. '    fn area(&self) -> i32 { self.@@ } }\nfn f() { let b = Boxy::new(1); b.next.@@ }\n',
    ['box.ts'] = 'class Box { w: number = 0; next?: Box; area(): number { return this.@@; } }\n'
        .. 'function f() { const b = new Box(); b.next.@@ }\n',
    ['Box.cs'] = 'class Box { public int W; public string Name { get; set; } Box Next() => null; void Run() { var b = new Box(); b.Next().@@ } }\n',
    ['core/registry.lua'] = 'Registry = Registry or {}\nfunction Registry.add(x) end\nfunction Registry:size() return 0 end\n',
    ['core/script.lua'] = 'local function run()\n  local opts = { depth = 1, mode = "a" }\n  opts.extra = true\n'
        .. '  Registry.add(1)\n  return Registry.@@, opts.@@\nend\n',
    ['shape.cpp'] = 'class Shape { public: int sides; };\n',
    ['shape_ops.cpp'] = 'class Shape;\nint Shape::perimeter() { return 0; }\nint use(Shape *s) { return s->@@; }\n',
    ['scope.c'] = 'static int counter;\nint helper(int a);\nint work(int alpha, char *beta) {\n  int gamma = 2;\n  @@\n}\n'
        .. 'int after(void) { int hidden = 1; return hidden; }\n',
}
local comp_marks = {}
for path, source in pairs(comp_files) do
    local clean, offsets, rest = '', {}, source
    while true do
        local at = rest:find('@@', 1, true)
        if not at then clean = clean .. rest; break end
        clean = clean .. rest:sub(1, at - 1)
        offsets[#offsets + 1] = #clean
        rest = rest:sub(at + 2)
    end
    write(comp_root .. '/' .. path, clean)
    comp_marks[path] = offsets
end

local function complete(path, mark, extra)
    local doc = docs.read(comp_root .. '/' .. path)
    local req = { method = 'lsp_completion', session = 'complete', root = comp_root, uri = docs.uri(comp_root .. '/' .. path),
        position = doc:position(comp_marks[path][mark]) }
    for k, v in pairs(extra or {}) do req[k] = v end
    local result = navigation.execute(req).result
    local labels = {}
    for _, item in ipairs(result.items) do labels[#labels + 1] = item.label end
    table.sort(labels)
    return table.concat(labels, ','), result
end

spec.describe('LSP completion', function()
    service.refresh(comp_root, { cache_path = comp_root .. '/cache.idx', lister = 'walk' })
    local cases = {
        { 'p.c', 1, 'next,x', 'C pointer members from a parameter type' },
        { 'p.c', 2, 'next,x', 'C members of a struct local' },
        { 'p.c', 3, 'depth', 'C field chains through full-parse field types' },
        { 'box.cpp', 1, 'make,name,next,w', 'C++ this in an out-of-line method' },
        { 'box.cpp', 2, 'make,name,next,w', 'C++ pointer field chains' },
        { 'box.cpp', 3, 'make,name,next,w', 'C++ static access' },
        { 'Use.java', 1, 'next,of,w', 'Java var initializers and method return types' },
        { 'pkg/store.py', 1, '__init__,items,save', 'Python self with assigned attributes' },
        { 'pkg/api.py', 1, '__init__,items,save', 'Python constructor calls' },
        { 'pkg/api.py', 2, 'Store', 'Python submodule imports' },
        { 'core/text.lua', 1, 'limit,split,trim', 'Lua self in a table method' },
        { 'core/main.lua', 1, 'limit,split,trim', 'Lua require aliases' },
        { 'core/main.lua', 2, 'split,trim', 'Lua colon calls list functions only' },
        { 'box.go', 1, 'Area,Next,W', 'Go method receivers' },
        { 'box.go', 2, 'Area,Next,W', 'Go composite literals and pointer fields' },
        { 'boxy.rs', 1, 'area,new,next,w', 'Rust self inside impl' },
        { 'boxy.rs', 2, 'area,new,next,w', 'Rust constructors and wrapped field types' },
        { 'box.ts', 1, 'area,next,w', 'TypeScript this' },
        { 'box.ts', 2, 'area,next,w', 'TypeScript optional field chains' },
        { 'Box.cs', 1, 'Name,Next,Run,W', 'C# properties and method returns' },
        { 'scope.c', 1, 'after,alpha,beta,counter,gamma,helper,work', 'locals, parameters and file definitions' },
        { 'core/script.lua', 1, 'add,size', 'Lua global tables defined in other files' },
        { 'core/script.lua', 2, 'depth,extra,mode', 'Lua local table literals and assignments' },
        { 'shape_ops.cpp', 1, 'perimeter,sides', 'C++ members defined out of line in other files' },
    }
    for _, case in ipairs(cases) do
        spec.it('completes ' .. case[4], function()
            spec.equal((complete(case[1], case[2])), case[3])
        end)
    end
    spec.it('answers trigger characters only after member operators and never inside strings', function()
        spec.equal((complete('pkg/api.py', 3, { trigger = true })), '')
        spec.equal((complete('pkg/api.py', 4)), '')
        spec.equal((complete('pkg/api.py', 1, { trigger = true })), '__init__,items,save')
    end)
    spec.it('completes from session drafts and reports exhausted budgets as incomplete', function()
        local uri = docs.uri(comp_root .. '/core/text.lua')
        navigation.sync({ session = 'complete', open = { [uri] = 1 }, changed = { [uri] = { version = 1, language = 'lua',
            source = 'local M = {}\nfunction M.fresh() end\nfunction M:split() return self. end\nreturn M\n' } } })
        local labels = complete('core/main.lua', 1)
        spec.equal(labels, 'fresh,split')
        local budget = completion.BUDGET_SECONDS
        completion.BUDGET_SECONDS = -1
        local _, result = complete('core/main.lua', 1)
        completion.BUDGET_SECONDS = budget
        spec.truthy(result.isIncomplete)
        navigation.sync({ session = 'complete', open = {} })
    end)
    spec.it('reads declared types from signatures', function()
        local cases = {
            { { kind = 'field', name = 'names', sig = 'private List<String> names' }, 'java', 'List' },
            { { kind = 'method', name = 'make', sig = 'static std::unique_ptr<Box> make(int k)' }, 'cpp', 'Box' },
            { { kind = 'method', name = 'Area', sig = 'func (b *Box) Area() (*Shape, error)' }, 'go', 'Shape' },
            { { kind = 'field', name = 'Next', sig = 'Next *Box' }, 'go', 'Box' },
            { { kind = 'method', name = 'new', sig = 'fn new(k: i32) -> Option<Rc<Boxy>>' }, 'rust', 'Boxy' },
            { { kind = 'field', name = 'next', sig = 'next?: Box' }, 'typescript', 'Box' },
            { { kind = 'method', name = 'make', sig = 'static make(k: number): Promise<Box>' }, 'typescript', 'Box' },
            { { kind = 'method', name = 'area', sig = 'def area(self) -> Shape:' }, 'python', 'Shape' },
            { { kind = 'field', name = 'next', type = 'struct Q *' }, 'c', 'Q' },
        }
        for _, case in ipairs(cases) do spec.equal(completion.declared(case[1], case[2]), case[3], case[1].sig) end
    end)
end)

local function comp_session(extra)
    local output = {}
    local session = lsp.new({}, function(msg) output[#output + 1] = msg end, function(req, done)
        if req.method == 'lsp_refresh' then return 'scan' end
        output.request = req
        done(true, { result = { isIncomplete = false, items = {} }, incomplete = false })
        return 'job'
    end, function() end, function() end)
    session:accept(xutils.json_pack({ jsonrpc = '2.0', id = 1, method = 'initialize',
        params = { rootUri = docs.uri(comp_root), capabilities = {}, initializationOptions = extra } }))
    session:accept(xutils.json_pack({ jsonrpc = '2.0', method = 'initialized', params = {} }))
    session.ready[comp_root] = true
    return session, output
end

spec.describe('LSP completion requests', function()
    spec.it('advertises member trigger characters and passes trigger context to the worker', function()
        local session, output = comp_session()
        local provider = output[1].result.capabilities.completionProvider
        spec.equal(table.concat(provider.triggerCharacters, ''), '.:>')
        session:accept(xutils.json_pack({ jsonrpc = '2.0', id = 2, method = 'textDocument/completion', params = {
            textDocument = { uri = docs.uri(comp_root .. '/p.c') }, position = { line = 3, character = 12 },
            context = { triggerKind = 2, triggerCharacter = '.' } } }))
        spec.equal(output.request.method, 'lsp_completion'); spec.equal(output.request.trigger, true)
        local reply = xutils.json_pack(output[#output])
        spec.contains(reply, '"items":[]'); spec.contains(reply, '"isIncomplete":false')
        local _, disabled = comp_session({ features = { completion = false } })
        spec.equal(disabled[1].result.capabilities.completionProvider, nil)
    end)
end)

service.forget(comp_root)
assert(xutils.rmtree(comp_root))
service.forget(nav_root)
assert(xutils.rmtree(nav_root))
service.forget(root)
assert(xutils.rmtree(root))
local failed = spec.finish()
return { __init = function() xthread.stop(failed > 0 and 1 or 0) end, __thread_handle = function() end }
