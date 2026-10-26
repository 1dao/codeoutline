package.path = 'scripts/?.lua;' .. package.path
local spec = dofile('tests/lua/spec_helper.lua')
local parse = require('codeoutline.parse')
local docs = require('codeoutline.documents')
local lsp = require('codeoutline.lsp')
local service = require('codeoutline.service')
local control = require('codeoutline.control')
local graph = require('codeoutline.graph')
local root = assert(xutils.temp_file(os.getenv('TEMP') or os.getenv('TMPDIR') or '/tmp')):gsub('\\', '/')
-- TMPDIR may end in a slash; temp_file can then return a doubled separator.
root = assert(docs.path(docs.uri(root)))
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
        { 'sample.kt', 'class Box { fun sample(sample: Int): Int = sample }', 'sample' },
        { 'sample.lua', 'function Box:sample(sample) return sample end', 'sample' },
        { 'sample.go', 'package main\nfunc sample(sample int) int { return sample }', 'sample' },
        { 'sample.ts', 'export function sample(sample: number) { return sample; }', 'sample' },
        { 'sample.ets', '@Component\nstruct Box { @State sample: number = 0; build() { Text(this.sample) } }', 'sample' },
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
        { 'calls.kt', 'class A { fun f() = g<Int>(1) + B().h() }', { 'g', 'B', 'h' } },
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
                if rec.refs.kind[i] ~= 'type' then names[#names + 1] = ref_name end
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
    spec.it('runs query RPC waits in separate coroutines and cleans up transport failures', function()
        local output, waits, cancelled = {}, {}, {}
        local session = lsp.new({}, function(msg) output[#output + 1] = msg end, fake_submit,
            function(id) cancelled[id] = true end, function() end,
            function(req, started)
                local co, main = coroutine.running()
                spec.truthy(co); spec.truthy(not main)
                waits[#waits + 1] = co
                started(tostring(#waits))
                return coroutine.yield()
            end)
        local function send(method, params, id)
            session:accept(xutils.json_pack({ jsonrpc = '2.0', method = method, params = params or {}, id = id }))
        end
        send('initialize', { capabilities = {} }, 1); send('initialized')
        send('workspace/symbol', { query = '' }, 2)
        send('workspace/symbol', { query = '' }, 3)
        spec.equal(#waits, 2)
        spec.truthy(waits[1] ~= waits[2])
        send('$/cancelRequest', { id = 2 })
        spec.truthy(cancelled['1'])
        local before = #output
        assert(coroutine.resume(waits[1], true, {}))
        spec.equal(#output, before)
        assert(coroutine.resume(waits[2], false, 'rpc timeout'))
        spec.equal(output[#output].id, 3)
        spec.equal(output[#output].error.code, -32603)
        spec.equal(next(session.pending), nil)
        send('workspace/symbol', { query = '' }, 4)
        assert(coroutine.resume(waits[3], true, {}))
        spec.equal(output[#output].id, 4)
        spec.equal(#output[#output].result, 0)
    end)
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
        local real, second = session.roots[1], assert(require('codeoutline.path').canonical(other))
        session.roots = { real, second }; session.ready[real] = true
        local before = #jobs
        send('workspace/symbol', { query = 'immediate' }, 2)
        spec.equal(#jobs, before)
        spec.equal(output[#output].result[1].name, 'immediate_draft')
        spec.equal(next(session.pending), nil)
        session.ready[second] = true
        send('workspace/symbol', { query = 'immediate' }, 3)
        spec.equal(#jobs, before + 1); spec.equal(jobs[#jobs].req.method, 'lsp_symbols')
        jobs[#jobs].done(true, {})
        spec.equal(output[#output].result[1].name, 'immediate_draft')
    end)
    spec.it('maps a workspace named through a directory link to canonical paths and back', function()
        local paths = require('codeoutline.path')
        local real, link = assert(paths.canonical(root)), root .. '-link'
        if paths.windows then os.execute('mklink /J "' .. link:gsub('/', '\\') .. '" "' .. real:gsub('/', '\\') .. '" >NUL')
        else os.execute("ln -s '" .. real .. "' '" .. link .. "'") end
        if xutils.realpath(link) == nil then print('SKIP cannot create a directory link'); return end
        local ok, err = pcall(function()
            local output, jobs = {}, {}
            local session = lsp.new({}, function(msg) output[#output + 1] = msg end,
                function(req, done) jobs[#jobs + 1] = { req = req, done = done }; return tostring(#jobs) end,
                function() end, function() end)
            local function send(method, params, id)
                session:accept(xutils.json_pack({ jsonrpc = '2.0', method = method, params = params or {}, id = id }))
            end
            send('initialize', { rootUri = docs.uri(link), capabilities = {} }, 1)
            send('initialized')
            spec.equal(session.roots[1], real)
            jobs[#jobs].done(true, true)
            local uri, canonical = docs.uri(link .. '/linked.lua'), docs.uri(real .. '/linked.lua')
            send('textDocument/didOpen', { textDocument = { uri = uri, languageId = 'lua', version = 1,
                text = 'function linked() end' } })
            send('textDocument/definition', { textDocument = { uri = uri }, position = { line = 0, character = 10 } }, 2)
            local req = jobs[#jobs].req
            spec.equal(req.root, real); spec.equal(req.uri, canonical); spec.equal(req.open[canonical], 1)
            spec.truthy(req.changed[canonical])
            local range = { start = { line = 0, character = 9 }, ['end'] = { line = 0, character = 15 } }
            jobs[#jobs].done(true, { result = { { uri = canonical, range = range } } })
            spec.equal(output[#output].id, 2); spec.equal(output[#output].result[1].uri, uri)
            send('workspace/symbol', { query = 'linked' }, 3)
            spec.equal(jobs[#jobs].req.exclude[paths.key(real .. '/linked.lua')], true)
            send('textDocument/didSave', { textDocument = { uri = uri } })
            spec.equal(jobs[#jobs].req.method, 'lsp_refresh')
            spec.equal(jobs[#jobs].req.paths[1], real .. '/linked.lua')
        end)
        if paths.windows then os.execute('rmdir "' .. link:gsub('/', '\\') .. '"') else os.remove(link) end
        if not ok then error(err, 0) end
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
    spec.it('prepares symbol tables before navigation readiness while keeping symbol-only clients lazy', function()
        for _, enabled in ipairs({ true, false }) do
            local submitted
            local session = lsp.new({}, function() end, function(req)
                submitted = req; return 'scan'
            end, function() end, function() end)
            local features = {}
            for _, name in ipairs(lsp.FEATURES) do
                features[name] = enabled or name == 'documentSymbol' or name == 'workspaceSymbol'
            end
            session:accept(xutils.json_pack({ jsonrpc = '2.0', id = 1, method = 'initialize', params = {
                rootUri = docs.uri(root), capabilities = {}, initializationOptions = { features = features } } }))
            session:accept(xutils.json_pack({ jsonrpc = '2.0', method = 'initialized', params = {} }))
            spec.equal(submitted.method, 'lsp_refresh'); spec.equal(submitted.prepare_navigation, enabled)
            spec.equal(next(session.ready), nil, 'readiness waits for symbol preparation to finish')
        end
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
            -- Sessions send the worker canonical roots and paths.
            local real = assert(require('codeoutline.path').canonical(root))
            local function run(id, req)
                req.projectPath, req.allowedRoots, req.deadline = real, { real }, xtimer.now_ms() + 10000
                worker.__thread_handle(1, 'run', id, req)
                spec.truthy(results[id], 'worker must complete directly without a continuation')
                return results[id]
            end
            spec.truthy(run('initial', { method = 'lsp_refresh' }).ok)
            local _, G = service.resident(root); spec.equal(G, nil)
            write(root .. '/a.lua', 'function worker_only() end\n')
            spec.truthy(run('save', { method = 'lsp_refresh', paths = { real .. '/a.lua' } }).ok)
            local symbols = run('symbols', { method = 'lsp_symbols', roots = { real },
                query = 'worker_only', exclude = {}, limit = 200 })
            spec.truthy(symbols.ok); spec.equal(#symbols.result, 1)
            spec.equal(symbols.result[1].name, 'worker_only')
            spec.equal(symbols.result[1].location.range.start.character, 9)
            local cancelled = run('cancelled', { method = 'lsp_refresh' })
            spec.equal(cancelled.ok, false); spec.contains(cancelled.result, 'cancelled')
            spec.equal(control.callback, nil)
            graph.build = saved.build
            spec.truthy(run('navigation-ready', { method = 'lsp_refresh', prepare_navigation = true }).ok)
            local _, prepared = service.resident(root); spec.truthy(prepared)
            spec.contains(service.explore(root, 'worker_only'), 'worker_only')
            local _, built = service.resident(root); spec.truthy(built)
            spec.equal(built, prepared, 'navigation reuses symbol tables prepared before readiness')
            graph.build = function() error('built symbol tables are updated per file, not rebuilt') end
            write(root .. '/a.lua', 'function after_graph() end\n')
            spec.truthy(run('changed', { method = 'lsp_refresh', paths = { real .. '/a.lua' } }).ok)
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
    spec.it('navigates indexed include fragments without an editor language hint', function()
        nav_write('IndexedFragment.cpp', '#include "IndexedFragment.piece"\nint IndexedFragmentCall() { return IndexedPiece(); }')
        nav_write('IndexedFragment.piece', '#include "IndexedLeaf.piece"\nstatic int IndexedPiece() { return IndexedLeaf(); }')
        nav_write('IndexedLeaf.piece', 'static int IndexedLeaf() { return 7; }')
        local idx = service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        spec.truthy(idx.files['IndexedFragment.piece']); spec.truthy(idx.files['IndexedLeaf.piece'])
        local function jump(path, name)
            local doc = docs.read(nav_root .. '/' .. path)
            local offset = assert(doc.source:find(name, 1, true)) - 1
            return nav({ method = 'lsp_definition', uri = doc.uri, position = doc:position(offset) })
        end
        local found = jump('IndexedFragment.cpp', 'IndexedPiece()')
        spec.equal(#found, 1); spec.equal(found[1].uri, nav_uri('IndexedFragment.piece'))
        found = jump('IndexedFragment.piece', 'IndexedLeaf()')
        spec.equal(#found, 1); spec.equal(found[1].uri, nav_uri('IndexedLeaf.piece'))
        local text, info = service.explore(nav_root, 'IndexedFragmentCall', { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        spec.contains(text, 'IndexedFragment.piece:2'); spec.equal(#(info.on_demand_files or {}), 0)
    end)
    spec.it('shares Go method sets across definitions, implementations, completion and draft changes', function()
        local prefix = 'go-method-sets/'
        assert(xutils.mkdir_p(nav_root .. '/' .. prefix))
        nav_write(prefix .. 'types.go', [[package methods
type GoReader interface { Read([]byte) (int, error) }
type GoBase struct {}
type GoWrapper struct { *GoBase }
type GoOther struct {}
func (GoOther) Read(int) string { return "" }
]])
        nav_write(prefix .. 'methods.go', 'package methods\nfunc (b *GoBase) Read(p []byte) (int, error) { return 0, nil }')
        local source = 'package methods\nfunc GoMethodUse(r GoReader, w GoWrapper) { r.Read(nil); w.Read(nil) }'
        nav_write(prefix .. 'use.go', source)
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local doc = docs.read(nav_root .. '/' .. prefix .. 'use.go')
        local function request(symbol, method, session)
            return nav({ method = method or 'lsp_definition', session = session, uri = doc.uri,
                position = doc:position(assert(source:find(symbol, 1, true)) + 1) })
        end
        local result = request('r.Read')
        spec.equal(#result, 1); spec.equal(result[1].uri, nav_uri(prefix .. 'types.go'))
        result = request('w.Read')
        spec.equal(#result, 1); spec.equal(result[1].uri, nav_uri(prefix .. 'methods.go'))
        result = request('r.Read', 'lsp_implementation')
        spec.equal(#result, 1); spec.equal(result[1].uri, nav_uri(prefix .. 'methods.go'))
        result = request('GoReader', 'lsp_implementation')
        spec.equal(#result, 2)
        local completion = require('codeoutline.completion').complete({ root = nav_root, uri = doc.uri,
            position = doc:position(assert(source:find('w.Read', 1, true)) + 1) })
        local labels = {}; for _, item in ipairs(completion.items) do labels[item.label] = true end
        spec.truthy(labels.Read); spec.truthy(labels.GoBase)
        local target = nav_uri(prefix .. 'methods.go')
        navigation.sync({ session = 'go-method-draft', open = { [target] = 1 }, changed = {
            [target] = { language = 'go', version = 1, source = 'package methods\n\nfunc (b *GoBase) Read(p []byte) (int, error) { return 1, nil }' } } })
        result = request('w.Read', 'lsp_definition', 'go-method-draft')
        spec.equal(#result, 1); spec.equal(result[1].range.start.line, 2)
        navigation.sync({ session = 'go-method-draft', open = { [target] = 2 }, changed = {
            [target] = { language = 'go', version = 2, source = 'package methods\nfunc (b *GoBase) Read(p []byte) string { return "" }' } } })
        result = request('r.Read', 'lsp_implementation', 'go-method-draft')
        spec.equal(#result, 0)
        navigation.close('go-method-draft')
        result = request('r.Read', 'lsp_implementation'); spec.equal(#result, 1)
    end)
    spec.it('navigates Go range variables through imported multi-result methods and draft return changes', function()
        local prefix = 'go-range-results/'
        assert(xutils.mkdir_p(nav_root .. '/' .. prefix .. 'ssh'))
        nav_write(prefix .. 'go.mod', 'module example.test/range\ngo 1.22\n')
        local api = [[package ssh
type NewChannel interface { Accept() (Channel, <-chan *Request, error) }
type Channel interface {}
type Request struct {}
func (*Request) Reply(ok bool, payload []byte) error { return nil }
type Other struct {}
func (*Other) Reply(ok bool, payload []byte) error { return nil }
]]
        nav_write(prefix .. 'ssh/channel.go', api)
        local source = [[package main
import gossh "example.test/range/ssh"
func Handle(newChan gossh.NewChannel) {
    channel, reqs, err := newChan.Accept()
    for req := range reqs { _ = req.Reply(false, nil) }
}
]]
        nav_write(prefix .. 'server.go', source)
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local doc = docs.read(nav_root .. '/' .. prefix .. 'server.go')
        local position = doc:position(assert(source:find('req.Reply', 1, true)) + 3)
        local function definition(session)
            return nav({ method = 'lsp_definition', session = session, uri = doc.uri, position = position })
        end
        local result = definition()
        spec.equal(#result, 1); spec.equal(result[1].uri, nav_uri(prefix .. 'ssh/channel.go'))
        spec.equal(result[1].range.start.line, 4)
        local completion = require('codeoutline.completion').complete({ root = nav_root, uri = doc.uri,
            position = doc:position(assert(source:find('req.Reply', 1, true)) + 3) })
        local found = false; for _, item in ipairs(completion.items) do if item.label == 'Reply' then found = true end end
        spec.truthy(found)
        local target = nav_uri(prefix .. 'ssh/channel.go')
        navigation.sync({ session = 'go-range-draft', open = { [target] = 1 }, changed = {
            [target] = { language = 'go', version = 1, source = api:gsub('<%-chan %*Request', '<-chan *Other') } } })
        result = definition('go-range-draft')
        spec.equal(#result, 1); spec.equal(result[1].range.start.line, 6)
        navigation.close('go-range-draft')
        result = definition(); spec.equal(#result, 1); spec.equal(result[1].range.start.line, 4)
    end)
    spec.it('shares Go call-result receivers across navigation, completion and draft changes', function()
        local prefix = 'go-call-chains/'
        assert(xutils.mkdir_p(nav_root .. '/' .. prefix))
        local api = [[package chains
type Manager struct {}
func GetManager() *Manager { return nil }
func (*Manager) IsChild() bool { return false }
type Other struct {}
func (*Other) IsChild() bool { return true }
]]
        nav_write(prefix .. 'manager.go', api)
        local source = 'package chains\nfunc NewServer() { if GetManager().IsChild() {} }\n'
        nav_write(prefix .. 'server.go', source)
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local doc = docs.read(nav_root .. '/' .. prefix .. 'server.go')
        local position = doc:position(assert(source:find('.IsChild', 1, true)) + 1)
        local function definition(session)
            return nav({ method = 'lsp_definition', session = session, uri = doc.uri, position = position })
        end
        local result = definition()
        spec.equal(#result, 1); spec.equal(result[1].uri, nav_uri(prefix .. 'manager.go'))
        spec.equal(result[1].range.start.line, 3)
        local completion = require('codeoutline.completion').complete({ root = nav_root, uri = doc.uri, position = position })
        local found = false; for _, item in ipairs(completion.items) do if item.label == 'IsChild' then found = true end end
        spec.truthy(found)
        local target = nav_uri(prefix .. 'manager.go')
        navigation.sync({ session = 'go-chain-draft', open = { [target] = 1 }, changed = {
            [target] = { language = 'go', version = 1, source = api:gsub('GetManager%(%) %*Manager', 'GetManager() *Other') } } })
        result = definition('go-chain-draft')
        spec.equal(#result, 1); spec.equal(result[1].range.start.line, 5)
        navigation.close('go-chain-draft')
        result = definition(); spec.equal(#result, 1); spec.equal(result[1].range.start.line, 3)
    end)
    spec.it('shares C++ factory-result types across definitions, completion and draft changes', function()
        local prefix = 'cpp-call-results/'
        assert(xutils.mkdir_p(nav_root .. '/' .. prefix))
        local api = [[namespace picked {
struct Manager { void Run() {} int state; };
struct Other { void Run() {} };
Manager* Factory();
}
]]
        nav_write(prefix .. 'api.hpp', api)
        local source = '#include "api.hpp"\nvoid Use() { picked::Factory()->Run(); }\n'
        nav_write(prefix .. 'use.cpp', source)
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local doc = docs.read(nav_root .. '/' .. prefix .. 'use.cpp')
        local position = doc:position(assert(source:find('->Run', 1, true)) + 2)
        local function definition(session)
            return nav({ method = 'lsp_definition', session = session, uri = doc.uri, position = position })
        end
        local result = definition()
        spec.equal(#result, 1); spec.equal(result[1].uri, nav_uri(prefix .. 'api.hpp')); spec.equal(result[1].range.start.line, 1)
        local completion = require('codeoutline.completion').complete({ root = nav_root, uri = doc.uri, position = position })
        local labels = {}; for _, item in ipairs(completion.items) do labels[item.label] = true end
        spec.truthy(labels.Run); spec.truthy(labels.state)
        local target = nav_uri(prefix .. 'api.hpp')
        navigation.sync({ session = 'cpp-result-draft', open = { [target] = 1 }, changed = {
            [target] = { language = 'cpp', version = 1, source = api:gsub('Manager%* Factory', 'Other* Factory') } } })
        result = definition('cpp-result-draft')
        spec.equal(#result, 1); spec.equal(result[1].range.start.line, 2)
        navigation.close('cpp-result-draft')
        result = definition(); spec.equal(#result, 1); spec.equal(result[1].range.start.line, 1)
    end)
    spec.it('narrows C returned-structure fields without changing unrelated same-name declarations', function()
        local prefix = 'c-call-results/'
        assert(xutils.mkdir_p(nav_root .. '/' .. prefix))
        nav_write(prefix .. 'api.h', 'struct Record { int value; };\nstruct Other { int value; };\nstruct Record* Factory(void);\n')
        local source = '#include "api.h"\nvoid Use(void) { int n = Factory()->value; }\n'
        nav_write(prefix .. 'use.c', source)
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local doc = docs.read(nav_root .. '/' .. prefix .. 'use.c')
        local result = nav({ method = 'lsp_definition', uri = doc.uri,
            position = doc:position(assert(source:find('->value', 1, true)) + 2) })
        spec.equal(#result, 1); spec.equal(result[1].uri, nav_uri(prefix .. 'api.h')); spec.equal(result[1].range.start.line, 0)
    end)
    spec.it('warms navigation caches without bypassing source validation or dependency limits', function()
        nav_write('WarmTarget.lua', 'local M = {}\nfunction M.warm_save() end\nreturn M\n')
        local source = "local api = dofile('WarmTarget.lua')\napi.warm_save()\n"
        nav_write('WarmClient.lua', source)
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local uri = nav_uri('WarmClient.lua')
        local ignored = nav_uri('WarmIgnored.lua')
        navigation.sync({ session = 'warm-cache', open = { [uri] = 1, [ignored] = 1 }, changed = {
            [uri] = { version = 1, language = 'lua', source = source },
            [ignored] = { version = 1, language = 'lua', source = 'function unrelated_warm_document() end' } } })
        local original, parses, idle = parse.parse_tokens, 0, true
        parse.parse_tokens = function(path, ...)
            if idle then spec.truthy(not path:match('WarmIgnored'), 'idle warming must not parse unrelated open drafts') end
            if path:match('Warm[CT]') then parses = parses + 1 end
            return original(path, ...)
        end
        local ok, err = pcall(function()
            local warmed = nav({ method = 'lsp_warm', session = 'warm-cache', uri = uri })
            idle = false
            spec.equal(warmed.files, 2)
            local before = parses
            local result = nav({ method = 'lsp_definition', session = 'warm-cache', uri = uri,
                position = { line = 1, character = 6 } })
            spec.equal(#result, 1); spec.equal(result[1].uri, nav_uri('WarmTarget.lua'))
            spec.equal(parses, before, 'the first definition must reuse the warmed source and target')
            nav_write('WarmTarget.lua', '\nlocal M = {}\nfunction M.warm_save() end\nreturn M\n')
            local fresh, failure = pcall(nav, { method = 'lsp_definition', session = 'warm-cache', uri = uri,
                position = { line = 1, character = 6 } })
            spec.equal(fresh, false); spec.contains(failure, 'source changed')
        end)
        parse.parse_tokens = original
        navigation.close('warm-cache')
        if not ok then error(err, 0) end
        local imports = {}
        for i = 1, 5 do
            nav_write('WarmLimit' .. i .. '.lua', 'return { warm_limit = function() end }\n')
            imports[i] = "local m" .. i .. " = dofile('WarmLimit" .. i .. ".lua')"
        end
        nav_write('WarmLimited.lua', table.concat(imports, '\n'))
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        spec.equal(nav({ method = 'lsp_warm', uri = nav_uri('WarmLimited.lua') }).files, 4)
    end)
    spec.it('shares binding evidence across overlays while validating source and evicting old entries', function()
        local ordinary = require('codeoutline.ordinary_bindings')
        local storage = { entries = {}, order = {}, bytes = 0 }
        local source = 'namespace A {} namespace B {} namespace Alias = A;\n'
        nav_write('SharedBinding.cpp', source)
        nav_write('OtherBinding.cpp', 'namespace Other {} namespace Alias = Other;\n')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local G = service.resident(nav_root):symbols()
        local f, other = G.file_index['SharedBinding.cpp'], G.file_index['OtherBinding.cpp']
        local function context(graph, loader)
            return ordinary.context(graph, {}, loader, { cache = storage, max_files = 1 })
        end
        local first = context(G)
        local expected = first.data(f)
        spec.equal(first.stats.parses, 1)
        local second = context(G)
        spec.equal(second.data(f), expected); spec.equal(second.stats.parses, 0)
        -- Overlay wrappers are rebuilt per navigation request; their parsed
        -- node identity and validated source still identify the same evidence.
        local copied = {}; for key, value in pairs(G.files[f]) do copied[key] = value end
        local overlay = { files = { [f] = copied } }
        local reads = 0
        local third = context(overlay, function() reads = reads + 1; return source end)
        spec.equal(third.data(f), expected); spec.equal(reads, 1); spec.equal(third.stats.parses, 0)
        nav_write('SharedBinding.cpp', source:gsub('Alias = A', 'Alias = B'))
        local ok, err = pcall(function() context(G).data(f) end)
        spec.equal(ok, false); spec.truthy(tostring(err):find('source changed', 1, true))
        nav_write('SharedBinding.cpp', source)
        context(G).data(other)
        spec.equal(#storage.order, 1); spec.truthy(storage.bytes <= 8 * 1024 * 1024)
        local evicted = context(G)
        evicted.data(f); spec.equal(evicted.stats.parses, 1)
        os.remove(nav_root .. '/SharedBinding.cpp'); os.remove(nav_root .. '/OtherBinding.cpp')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
    end)
    spec.it('reuses fallback cursor tokens until the open document version changes', function()
        local source = 'void token_cursor(int parameter) { int local_value = parameter; }\n'
        nav_write('TokenCursor.cpp', source)
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local uri = nav_uri('TokenCursor.cpp')
        navigation.sync({ session = 'cursor-tokens', open = { [uri] = 1 }, changed = {
            [uri] = { version = 1, language = 'cpp', source = source } } })
        local original, parses = parse.parse_tokens, 0
        parse.parse_tokens = function(path, ...)
            if path:match('TokenCursor%.cpp$') then parses = parses + 1 end
            return original(path, ...)
        end
        local ok, err = pcall(function()
            local req = { session = 'cursor-tokens', method = 'lsp_definition', uri = uri,
                position = { line = 0, character = source:find('local_value', 1, true) - 1 } }
            nav(req)
            local cold = parses
            spec.truthy(cold > 0)
            nav(req); spec.equal(parses, cold, 'a second parameter/local lookup must reuse tokens and binding evidence')
            navigation.sync({ session = 'cursor-tokens', open = { [uri] = 2 }, changed = {
                [uri] = { version = 2, language = 'cpp', source = source:gsub('local_value', 'fresh_local') } } })
            nav(req); spec.truthy(parses > cold)
        end)
        parse.parse_tokens = original
        navigation.close('cursor-tokens')
        os.remove(nav_root .. '/TokenCursor.cpp')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        if not ok then error(err, 0) end
    end)
    spec.it('reuses target positions while validating disk edits and isolating drafts', function()
        nav_write('PositionCache.h', 'int position_cache_target(void);\n')
        nav_write('PositionCache.c', '#include "PositionCache.h"\nint position_cache_target(void) { return 1; }\n')
        nav_write('PositionCaller.c', '#include "PositionCache.h"\nint position_caller(void) { return position_cache_target(); }\n')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local req = { method = 'lsp_definition', uri = nav_uri('PositionCaller.c'), position = { line = 1, character = 40 } }
        local original, parses = parse.parse, 0
        parse.parse = function(path, ...)
            if path:match('PositionCache%.c$') then parses = parses + 1 end
            return original(path, ...)
        end
        local ok, err = pcall(function()
            local first = nav(req)
            spec.equal(#first, 1); spec.equal(first[1].uri, nav_uri('PositionCache.c'))
            spec.equal(first[1].range.start.line, 1)
            local second = nav(req)
            spec.equal(second[1].range.start.line, 1); spec.equal(parses, 1)
            -- Position-only entries must still upgrade to tokens for completion.
            local V = navigation.view('spec', nav_root)
            local rec, T = navigation.full(V, V.file_index['PositionCache.c'])
            spec.truthy(T); spec.equal(rec.nodes[1].name, 'position_cache_target')
            local edited = '\n#include "PositionCache.h"\nint position_cache_target(void) { return 2; }\n'
            nav_write('PositionCache.c', edited)
            local fresh, failure = pcall(nav, req)
            spec.equal(fresh, false); spec.truthy(tostring(failure):find('source changed', 1, true))
            service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
            local moved = nav(req)
            spec.equal(moved[1].range.start.line, 2)
            local uri = nav_uri('PositionCache.c')
            navigation.sync({ session = 'position-draft', open = { [uri] = 1 }, changed = {
                [uri] = { version = 1, language = 'c', source = '\n' .. edited } } })
            local draft = nav({ method = req.method, uri = req.uri, position = req.position, session = 'position-draft' })
            spec.equal(draft[1].range.start.line, 3)
            spec.equal(nav(req)[1].range.start.line, 2)
        end)
        parse.parse = original
        navigation.close('position-draft')
        for _, file in ipairs({ 'PositionCache.h', 'PositionCache.c', 'PositionCaller.c' }) do os.remove(nav_root .. '/' .. file) end
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        if not ok then error(err, 0) end
    end)
    spec.it('evicts target position parses through the existing file cache limit', function()
        nav_write('PositionEvictA.lua', 'function position_evict_a() end\n')
        nav_write('PositionEvictB.lua', 'function position_evict_b() end\n')
        nav_write('PositionEvictCaller.lua', 'position_evict_a()\nposition_evict_b()\n')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local original, limit, parses = parse.parse, navigation.CACHE_FILES, 0
        navigation.CACHE_FILES = 1
        parse.parse = function(path, ...)
            if path:match('PositionEvictA%.lua$') then parses = parses + 1 end
            return original(path, ...)
        end
        local ok, err = pcall(function()
            local req = { method = 'lsp_definition', uri = nav_uri('PositionEvictCaller.lua'), position = { line = 0, character = 2 } }
            spec.equal(nav(req)[1].uri, nav_uri('PositionEvictA.lua'))
            req.position.line = 1
            spec.equal(nav(req)[1].uri, nav_uri('PositionEvictB.lua'))
            req.position.line = 0
            spec.equal(nav(req)[1].uri, nav_uri('PositionEvictA.lua'))
            spec.equal(parses, 2)
        end)
        parse.parse, navigation.CACHE_FILES = original, limit
        for _, file in ipairs({ 'PositionEvictA.lua', 'PositionEvictB.lua', 'PositionEvictCaller.lua' }) do os.remove(nav_root .. '/' .. file) end
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        if not ok then error(err, 0) end
    end)
    spec.it('ArkTS imports and this calls resolve with exact ranges and draft overlays', function()
        nav_write('ArkHelper.ets', 'export function arkSave(value: number) {}\n')
        local source = "import { arkSave } from './ArkHelper';\n@Component\nstruct ArkPage {\n"
            .. '  @State count: number = 0;\n  click() { arkSave(this.count); }\n'
            .. '  build() { Column() { Button("go").onClick(() => { this.click(); }) } }\n}'
        nav_write('ArkPage.ets', source)
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local uri = nav_uri('ArkPage.ets')
        local doc = docs.new(uri, source, 1, 'arkts')
        local at = source:find('this.click', 1, true) + #'this.' - 1
        local found = nav({ method = 'lsp_definition', uri = uri, position = doc:position(at) })
        spec.equal(#found, 1); spec.equal(range_text('ArkPage.ets', found[1].range), 'click')
        found = nav({ method = 'lsp_definition', uri = uri, position = { line = 4, character = 13 } })
        spec.equal(#found, 1); spec.equal(found[1].uri, nav_uri('ArkHelper.ets'))
        spec.equal(range_text('ArkHelper.ets', found[1].range), 'arkSave')
        local edited = source:gsub('click', 'tap')
        local edited_doc = docs.new(uri, edited, 2, 'arkts')
        navigation.sync({ session = 'arkts-draft', open = { [uri] = 1 }, changed = {
            [uri] = { version = 2, language = 'arkts', source = edited } } })
        local draft = nav({ method = 'lsp_definition', session = 'arkts-draft', uri = uri,
            position = edited_doc:position(edited:find('this.tap', 1, true) + #'this.' - 1) })
        spec.equal(#draft, 1); spec.equal(draft[1].range.start.line, 4)
        navigation.close('arkts-draft')
        spec.equal(docs.new('untitled:ArkTS', '@Component struct View { build() {} }', 1, 'arkts'):parse().nodes[1].name, 'View')
    end)
    spec.it('Kotlin definitions, aliased references, signatures and draft overlays', function()
        nav_write('Service.kt', 'package sample\nfun execute(value: Int, label: String): Int = value\n')
        nav_write('Client.kt', 'package client\nimport sample.execute as dispatch\nfun run() = dispatch(1, "x")\n')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local uri = nav_uri('Client.kt')
        local found = nav({ method = 'lsp_definition', uri = uri, position = { line = 2, character = 14 } })
        spec.equal(#found, 1); spec.equal(found[1].uri, nav_uri('Service.kt'))
        spec.equal(range_text('Service.kt', found[1].range), 'execute')
        local sig = nav({ method = 'lsp_signature', uri = uri, position = { line = 2, character = 24 } })
        spec.equal(#sig.signatures[1].parameters, 2)
        spec.equal(sig.activeParameter, 1)
        local uses = nav({ method = 'lsp_references', uri = nav_uri('Service.kt'), position = { line = 1, character = 6 },
            includeDeclaration = false })
        spec.equal(#uses, 1); spec.equal(range_text('Client.kt', uses[1].range), 'dispatch')
        navigation.sync({ session = 'kotlin-draft', open = { [uri] = 1 }, changed = {
            [uri] = { version = 1, language = 'kotlin', source = 'package client\nfun fresh() = 1\nfun run() = fresh()' } } })
        local draft = nav({ method = 'lsp_definition', session = 'kotlin-draft', uri = uri,
            position = { line = 2, character = 14 } })
        spec.equal(#draft, 1); spec.equal(draft[1].range.start.line, 1)
        navigation.close('kotlin-draft')
        local untitled = docs.new('untitled:Kotlin', 'fun untitledFun() = 1', 1, 'kotlin')
        spec.equal(untitled:parse().nodes[1].name, 'untitledFun')
    end)
    spec.it('Kotlin generic signatures keep type-argument commas inside one parameter', function()
        local source = 'fun <T> lookup(values: Map<String, T>, fallback: T): T = fallback\n'
            .. 'fun run() = lookup<Int>(emptyMap(), 1)\n'
        nav_write('Generic.kt', source)
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local doc = docs.read(nav_root .. '/Generic.kt')
        local sig = nav({ method = 'lsp_signature', uri = doc.uri,
            position = doc:position(assert(source:find(', 1)', 1, true))) })
        spec.equal(#sig.signatures[1].parameters, 2)
        spec.equal(sig.signatures[1].parameters[1].label, 'values: Map<String, T>')
        spec.equal(sig.activeParameter, 1)
    end)
    spec.it('resolves JS imported aliases and typed receivers in unsaved overlays', function()
        nav_write('StoreA.ts', 'export class Store { save() {} }\nexport function persist() {}\n')
        nav_write('StoreB.ts', 'export class Store { save() {} }\nexport function persist() {}\n')
        local source = "import { Store as Selected, persist as write } from './StoreB';\nfunction run(s: Selected) { s.save(); write(); }\n"
        nav_write('TypedClient.ts', source)
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local doc = docs.read(nav_root .. '/TypedClient.ts')
        local function definition(text, session)
            return nav({ method = 'lsp_definition', uri = doc.uri, session = session,
                position = doc:position(assert(source:find(text, 1, true)) - 1) })
        end
        local found = definition('save()')
        spec.equal(#found, 1); spec.equal(found[1].uri, nav_uri('StoreB.ts'))
        found = definition('write()')
        spec.equal(#found, 1); spec.equal(found[1].uri, nav_uri('StoreB.ts'))
        local uses = nav({ method = 'lsp_references', uri = nav_uri('StoreB.ts'), position = { line = 1, character = 18 },
            includeDeclaration = false })
        spec.equal(#uses, 1); spec.equal(range_text('TypedClient.ts', uses[1].range), 'write')
        local target = nav_uri('StoreB.ts')
        navigation.sync({ session = 'js-typed', open = { [target] = 1 }, changed = {
            [target] = { version = 1, language = 'typescript', source = '\n\nexport class Store { save() {} }\nexport function persist() {}' } } })
        found = definition('save()', 'js-typed')
        spec.equal(#found, 1); spec.equal(found[1].range.start.line, 2)
        navigation.close('js-typed')
    end)
    spec.it('shares Cargo package aliases, module paths, references and completion after manifest and draft changes', function()
        local prefix = 'cargo-workspace-lsp/'
        for _, path in ipairs({ 'app/src', 'first', 'second' }) do assert(xutils.mkdir_p(nav_root .. '/' .. prefix .. path)) end
        nav_write(prefix .. 'Cargo.toml', '[workspace]\nmembers=["app","first"]\n'
            .. '[workspace.dependencies]\nchosen={path="first",package="library"}\n')
        nav_write(prefix .. 'app/Cargo.toml', '[package]\nname="app"\n[dependencies]\nchosen.workspace=true\n')
        for _, folder in ipairs({ 'first', 'second' }) do
            nav_write(prefix .. folder .. '/Cargo.toml', '[package]\nname="library"\n[lib]\npath="api.rs"\n')
            nav_write(prefix .. folder .. '/nested.rs', 'pub fn flush() {}')
        end
        nav_write(prefix .. 'first/api.rs', 'pub fn cargo_save() {}\npub mod nested;\nfn hidden() {}')
        nav_write(prefix .. 'second/api.rs', '\npub fn cargo_save() {}\npub mod nested;')
        local source = 'use chosen::{cargo_save as persist, nested};\n'
            .. 'fn CargoLspRun() { persist(); chosen::cargo_save(); nested::flush(); }\n'
        local client = prefix .. 'app/src/main.rs'; nav_write(client, source)
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local doc = docs.read(nav_root .. '/' .. client)
        local function check(folder, line, session)
            local found
            for _, name in ipairs({ 'persist();', 'cargo_save();', 'flush();' }) do
                local response
                found, response = nav({ method = 'lsp_definition', session = session, uri = doc.uri,
                    position = doc:position(assert(source:find(name, 1, true))) })
                spec.equal(#found, 1, name); spec.equal(response.incomplete, false)
                spec.equal(found[1].uri, nav_uri(prefix .. folder .. '/' .. (name == 'flush();' and 'nested.rs' or 'api.rs')))
                if name ~= 'flush();' then spec.equal(found[1].range.start.line, line) end
            end
            for _, case in ipairs({ { 'chosen::cargo_save', 7, 'cargo_save' }, { 'nested::flush', 7, 'flush' } }) do
                local result = require('codeoutline.completion').complete({ root = nav_root, uri = doc.uri, session = session,
                    position = doc:position(assert(source:find(case[1], 1, true)) + case[2]) })
                local labels = {}; for _, item in ipairs(result.items) do labels[item.label] = true end
                spec.truthy(labels[case[3]]); spec.nil_value(labels.hidden); spec.equal(result.incomplete or false, false)
            end
            found = nav({ method = 'lsp_references', session = session, uri = nav_uri(prefix .. folder .. '/api.rs'),
                position = { line = line, character = 8 }, includeDeclaration = false })
            spec.equal(#found, 2)
        end
        check('first', 0)
        nav_write(prefix .. 'Cargo.toml', '[workspace]\nmembers=["app","second"]\n'
            .. '[workspace.dependencies]\nchosen={path="second",package="library"}\n')
        check('second', 1)
        local target = nav_uri(prefix .. 'second/api.rs')
        navigation.sync({ session = 'cargo-draft', open = { [target] = 1 }, changed = {
            [target] = { version = 1, language = 'rust', source = '\n\npub fn cargo_save() {}\npub mod nested;' } } })
        check('second', 2, 'cargo-draft'); navigation.close('cargo-draft')
        local cargo = require('codeoutline.rust_packages')
        local limit = cargo.MAX_CONFIGS; cargo.MAX_CONFIGS = 1
        local ok, err = pcall(function()
            local found, response = nav({ method = 'lsp_definition', uri = doc.uri,
                position = doc:position(assert(source:find('persist();', 1, true))) })
            spec.equal(#found, 0); spec.truthy(response.incomplete)
        end)
        cargo.MAX_CONFIGS = limit; assert(ok, err)
        local own = 'pub struct CargoBox { width: i32 }\nimpl CargoBox { fn read(&self) { self.width; } }'
        nav_write(prefix .. 'app/src/lib.rs', own)
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local own_doc = docs.read(nav_root .. '/' .. prefix .. 'app/src/lib.rs')
        local completion = require('codeoutline.completion').complete({ root = nav_root, uri = own_doc.uri,
            position = own_doc:position(assert(own:find('self.width', 1, true)) + 4) })
        local names = {}; for _, item in ipairs(completion.items) do names[item.label] = true end
        spec.truthy(names.width); spec.nil_value(names.nested)
    end)
    spec.it('shares Go workspace imports across navigation, completion, references and draft/configuration changes', function()
        local prefix = 'go-workspace-lsp/'
        for _, path in ipairs({ 'app', 'first', 'second', 'unrelated' }) do
            assert(xutils.mkdir_p(nav_root .. '/' .. prefix .. path))
        end
        nav_write(prefix .. 'go.work', 'use (\n ./app\n ./first\n)\n')
        nav_write(prefix .. 'app/go.mod', 'module example.test/client\n')
        nav_write(prefix .. 'first/go.mod', 'module example.test/api/v2\n')
        nav_write(prefix .. 'second/go.mod', 'module example.test/api/v2\n')
        nav_write(prefix .. 'first/api.go', 'package actual\nfunc GoWorkspaceSave() {}\nfunc FirstOnly() {}\nfunc hidden() {}')
        nav_write(prefix .. 'second/api.go', 'package actual\n\nfunc GoWorkspaceSave() {}\nfunc SecondOnly() {}')
        nav_write(prefix .. 'unrelated/api.go', 'package actual\nfunc GoWorkspaceSave() {}\nfunc Unrelated() {}')
        nav_write(prefix .. 'app/peer.go', 'package main\nfunc PeerOnly() {}')
        local source = 'package main\nimport "example.test/api/v2"\n'
            .. 'func GoWorkspaceRun() { actual.GoWorkspaceSave() }\n'
        local client = prefix .. 'app/main.go'
        nav_write(client, source)
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local doc = docs.read(nav_root .. '/' .. client)
        local function check(folder, line, label, session)
            local found, response = nav({ method = 'lsp_definition', session = session, uri = doc.uri,
                position = doc:position(assert(source:find('GoWorkspaceSave()', 1, true))) })
            spec.equal(#found, 1); spec.equal(found[1].uri, nav_uri(prefix .. folder .. '/api.go'))
            spec.equal(found[1].range.start.line, line); spec.equal(response.incomplete, false)
            local completion = require('codeoutline.completion').complete({ root = nav_root, session = session, uri = doc.uri,
                position = doc:position(assert(source:find('actual.GoWorkspaceSave', 1, true)) + 6) })
            local labels = {}; for _, item in ipairs(completion.items) do labels[item.label] = true end
            spec.truthy(labels.GoWorkspaceSave and labels[label]); spec.nil_value(labels.PeerOnly)
            spec.nil_value(labels.Unrelated); spec.nil_value(labels.hidden); spec.equal(completion.incomplete or false, false)
            local uses = nav({ method = 'lsp_references', session = session, uri = found[1].uri,
                position = found[1].range.start, includeDeclaration = false })
            spec.equal(#uses, 1); spec.equal(uses[1].uri, doc.uri)
            found = nav({ method = 'lsp_definition', session = session, uri = doc.uri,
                position = { line = 1, character = 12 } })
            spec.equal(#found, 1); spec.equal(found[1].uri, nav_uri(prefix .. folder .. '/api.go'))
        end
        check('first', 1, 'FirstOnly')
        nav_write(prefix .. 'go.work', 'use (\n ./app\n ./second\n)\n')
        check('second', 2, 'SecondOnly')
        local target = nav_uri(prefix .. 'second/api.go')
        navigation.sync({ session = 'go-workspace-draft', open = { [target] = 1 }, changed = {
            [target] = { version = 1, language = 'go', source = 'package actual\n\n\nfunc GoWorkspaceSave() {}\nfunc DraftOnly() {}' } } })
        check('second', 3, 'DraftOnly', 'go-workspace-draft')
        navigation.close('go-workspace-draft')
        local go = require('codeoutline.go_modules')
        local limit = go.MAX_CONFIGS; go.MAX_CONFIGS = 1
        local ok, err = pcall(function()
            local found, response = nav({ method = 'lsp_definition', uri = doc.uri, position = { line = 1, character = 12 } })
            spec.equal(#found, 0); spec.truthy(response.incomplete)
            local completion = require('codeoutline.completion').complete({ root = nav_root, uri = doc.uri,
                position = doc:position(assert(source:find('actual.GoWorkspaceSave', 1, true)) + 6) })
            spec.equal(#completion.items, 0); spec.truthy(completion.incomplete)
        end)
        go.MAX_CONFIGS = limit; assert(ok, err)
    end)
    spec.it('shares workspace packages across navigation, completion, references, drafts and manifest edits', function()
        local prefix = 'workspace-lsp/'
        assert(xutils.mkdir_p(nav_root .. '/' .. prefix .. 'packages/core'))
        nav_write(prefix .. 'package.json', '{"workspaces":["packages/*"]}')
        local manifest = prefix .. 'packages/core/package.json'
        nav_write(manifest, '{"name":"@navigation/core","exports":"./a.ts"}')
        nav_write(prefix .. 'packages/core/a.ts', 'export function workspaceSave() {}\nexport class WorkspaceStore { workspaceFlush() {} }\n')
        nav_write(prefix .. 'packages/core/b.ts', '\nexport function workspaceSave() {}\nexport class WorkspaceStore { workspaceFlush() {} }\n')
        local source = "import { workspaceSave as persist, WorkspaceStore } from '@navigation/core';\n"
            .. "import * as api from '@navigation/core';\n"
            .. 'function workspaceRun(s: WorkspaceStore) { persist(); s.workspaceFlush(); api.workspaceSave(); }\n'
        local client = prefix .. 'client.ts'
        nav_write(client, source)
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local doc = docs.read(nav_root .. '/' .. client)
        local function check(target, line, session)
            local definitions = {}
            for _, text in ipairs({ 'persist();', 'workspaceFlush();', 'workspaceSave();', '@navigation/core' }) do
                local found, response = nav({ method = 'lsp_definition', session = session, uri = doc.uri,
                    position = doc:position(assert(source:find(text, 1, true))) })
                spec.equal(#found, 1, text); spec.equal(found[1].uri, nav_uri(prefix .. 'packages/core/' .. target), text)
                spec.equal(response.incomplete, false)
                definitions[text] = found[1]
            end
            spec.equal(definitions['persist();'].range.start.line, line)
            for _, text in ipairs({ 's.workspaceFlush', 'api.workspaceSave' }) do
                local result = require('codeoutline.completion').complete({ root = nav_root, uri = doc.uri, session = session,
                    position = doc:position(assert(source:find(text, 1, true)) + #text:match('^(.-)%.')) })
                local labels = {}; for _, item in ipairs(result.items) do labels[item.label] = true end
                spec.truthy(labels[text:match('%.(.+)$')]); spec.equal(result.incomplete or false, false)
            end
            local uses = nav({ method = 'lsp_references', session = session, uri = definitions['persist();'].uri,
                position = definitions['persist();'].range.start, includeDeclaration = false })
            local calls = 0
            for _, ref in ipairs(uses) do
                if ref.uri == doc.uri and ref.range.start.line == 2 then calls = calls + 1 end
            end
            spec.equal(calls, 2)
        end
        check('a.ts', 0)
        -- Configuration changes take effect without refreshing indexed sources.
        nav_write(manifest, '{"name":"@navigation/core","exports":"./b.ts"}')
        check('b.ts', 1)
        local uri = nav_uri(prefix .. 'packages/core/b.ts')
        navigation.sync({ session = 'workspace-draft', open = { [uri] = 1 }, changed = {
            [uri] = { version = 1, language = 'typescript', source = '\n\nexport function workspaceSave() {}\n'
                .. 'export class WorkspaceStore { workspaceFlush() {} }\n' } } })
        check('b.ts', 2, 'workspace-draft')
        navigation.close('workspace-draft')
        for _, rec in pairs(service.resident(nav_root).files) do
            spec.nil_value(rec.workspace); spec.nil_value(rec.ordinary_bindings)
        end
    end)
    spec.it('reports workspace discovery limits in navigation, completion and references', function()
        local prefix = 'workspace-limits/'
        assert(xutils.mkdir_p(nav_root .. '/' .. prefix .. 'packages/core'))
        nav_write(prefix .. 'package.json', '{"workspaces":["packages/*"]}')
        nav_write(prefix .. 'packages/core/package.json', '{"name":"@limits/core","main":"index.ts"}')
        nav_write(prefix .. 'packages/core/index.ts', 'export function budgetSave() {}')
        local source = "import * as api from '@limits/core';\nfunction budgetRun() { api.budgetSave(); }"
        nav_write(prefix .. 'client.ts', source)
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local doc = docs.read(nav_root .. '/' .. prefix .. 'client.ts')
        local workspace = require('codeoutline.js_workspace')
        local limit = workspace.MAX_CONFIGS; workspace.MAX_CONFIGS = 1
        local ok, err = pcall(function()
            local found, response = nav({ method = 'lsp_definition', uri = doc.uri,
                position = doc:position(assert(source:find('@limits/core', 1, true))) })
            spec.equal(#found, 0); spec.truthy(response.incomplete)
            local completion = require('codeoutline.completion').complete({ root = nav_root, uri = doc.uri,
                position = doc:position(assert(source:find('api.budgetSave', 1, true)) + 3) })
            spec.equal(#completion.items, 0); spec.truthy(completion.incomplete)
            found, response = nav({ method = 'lsp_references', uri = nav_uri(prefix .. 'packages/core/index.ts'),
                position = { line = 0, character = 18 }, includeDeclaration = false })
            spec.equal(#found, 0); spec.truthy(response.incomplete)
        end)
        workspace.MAX_CONFIGS = limit; assert(ok, err)
    end)
    spec.it('connects Lua native module exports to C definitions, hover and completion', function()
        local native = [[static int native_save(lua_State *L) { int id = luaL_checkinteger(L, 1); luaL_checkstring(L, 2); int count = luaL_optinteger(L, 3, 10); return 0; }
static int hidden(lua_State *L) { return 0; }
static const luaL_Reg api[] = { {"save", native_save}, {NULL, NULL} };
static const luaL_Reg methods[] = { {"hidden", hidden}, {NULL, NULL} };
int luaopen_native_test(lua_State *L) { luaL_setfuncs(L, methods, 0); luaL_newlib(L, api); return 1; }
]]
        nav_write('NativeTest.c', native)
        local source = "local m = require('native_test')\nm.save()\nnative_test.save()\nm.save(1, 'value', 3)\n"
        nav_write('NativeClient.lua', source)
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local doc = docs.read(nav_root .. '/NativeClient.lua')
        for _, line in ipairs({1, 2}) do
            local character = line == 1 and 3 or 13
            local found = nav({ method = 'lsp_definition', uri = doc.uri, position = { line = line, character = character } })
            spec.equal(#found, 1)
            spec.equal(found[1].uri, nav_uri('NativeTest.c'))
            spec.equal(range_text('NativeTest.c', found[1].range), 'native_save')
            local hover = nav({ method = 'lsp_hover', uri = doc.uri, position = { line = line, character = character } })
            spec.contains(hover.contents.value, 'native_save')
            spec.contains(hover.contents.value, 'save(id:int, arg2:string, count?:int = 10)')
            spec.nil_value(hover.contents.value:find('lua_State', 1, true))
            local result = nav({ method = 'lsp_completion', uri = doc.uri,
                position = { line = line, character = line == 1 and 2 or 12 } })
            spec.equal(#result.items, 1)
            spec.equal(result.items[1].label, 'save')
            spec.equal(result.items[1].detail, 'save(id:int, arg2:string, count?:int = 10)')
            local sig = nav({ method = 'lsp_signature', uri = doc.uri,
                position = { line = line, character = line == 1 and 7 or 17 } })
            spec.equal(sig.signatures[1].label, result.items[1].detail)
            spec.equal(#sig.signatures[1].parameters, 3)
        end
        local host_hover = nav({ method = 'lsp_hover', uri = nav_uri('NativeTest.c'), position = { line = 0, character = 13 } })
        spec.contains(host_hover.contents.value, 'lua_State')
        local active = nav({ method = 'lsp_signature', uri = doc.uri, position = { line = 3, character = 10 } })
        spec.equal(active.activeParameter, 1)
        spec.equal(active.signatures[1].parameters[2].label, 'arg2:string')
        local target = nav_uri('NativeTest.c')
        navigation.sync({ session = 'native-overlay', open = { [target] = 1 }, changed = {
            [target] = { version = 1, language = 'c', source = '\n' .. native:gsub('luaL_checkinteger', 'luaL_checknumber') } } })
        local found = nav({ method = 'lsp_definition', uri = doc.uri, session = 'native-overlay', position = { line = 1, character = 3 } })
        spec.equal(found[1].range.start.line, 1)
        local hover = nav({ method = 'lsp_hover', uri = doc.uri, session = 'native-overlay', position = { line = 1, character = 3 } })
        spec.contains(hover.contents.value, 'save(id:number, arg2:string, count?:int = 10)')
        navigation.close('native-overlay')
    end)
    spec.it('shares ordinary bindings with definitions, references and unsaved targets', function()
        local cases = {
            { file = 'Ordinary.ts', target = 'OrdinaryTarget.ts', language = 'typescript',
                source = "import { alias } from './OrdinaryTarget'; const cb = alias;\nfunction run() { cb(); }",
                declaration = 'export function ordinary_target() {}\nexport const alias = ordinary_target;',
                call = 'cb();', name = 'ordinary_target' },
            { file = 'Ordinary.py', target = 'OrdinaryTarget.py', language = 'python',
                source = 'from OrdinaryTarget import ordinary_target as cb\ndef run():\n    cb()\n',
                declaration = 'def ordinary_target():\n    pass\n', call = 'cb()', name = 'ordinary_target' },
            { file = 'Ordinary.cpp', target = 'OrdinaryTarget.hpp', language = 'cpp',
                source = '#include "OrdinaryTarget.hpp"\nvoid run(Ordinary* a) { a->ordinary_target(); }',
                declaration = 'class Ordinary { public: void ordinary_target() {} };',
                call = 'ordinary_target();', name = 'ordinary_target' },
        }
        for _, case in ipairs(cases) do
            nav_write(case.file, case.source); nav_write(case.target, case.declaration)
        end
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        for _, case in ipairs(cases) do
            local doc = docs.read(nav_root .. '/' .. case.file)
            local req = { method = 'lsp_definition', uri = doc.uri,
                position = doc:position(assert(case.source:find(case.call, 1, true)) - 1) }
            local found = nav(req)
            spec.equal(#found, 1, case.file); spec.equal(found[1].uri, nav_uri(case.target))
            spec.equal(range_text(case.target, found[1].range), case.name)
            local target_doc = docs.read(nav_root .. '/' .. case.target)
            local refs = nav({ method = 'lsp_references', uri = target_doc.uri, includeDeclaration = false,
                position = target_doc:position(assert(case.declaration:find(case.name, 1, true)) - 1) })
            local hit = false
            for _, ref in ipairs(refs) do if ref.uri == doc.uri then hit = true end end
            spec.truthy(hit, case.file .. ' reverse references')
            navigation.sync({ session = 'ordinary-binding-draft', open = { [target_doc.uri] = 1 }, changed = {
                [target_doc.uri] = { version = 1, language = case.language, source = '\n' .. case.declaration } } })
            req.session = 'ordinary-binding-draft'
            found = nav(req)
            spec.equal(#found, 1, case.file .. ' overlay'); spec.equal(found[1].range.start.line, 1)
            navigation.close('ordinary-binding-draft')
            -- The caller's unsaved bytes also supply query evidence, with the
            -- original resident reference indices replaced by the overlay's.
            navigation.sync({ session = 'ordinary-caller-draft', open = { [doc.uri] = 1 }, changed = {
                [doc.uri] = { version = 1, language = case.language, source = '\n' .. case.source } } })
            local draft = docs.new(doc.uri, '\n' .. case.source, 1, case.language)
            req.session = 'ordinary-caller-draft'
            req.position = draft:position(assert(draft.source:find(case.call, 1, true)) - 1)
            found = nav(req)
            spec.equal(#found, 1, case.file .. ' caller overlay'); spec.equal(found[1].uri, nav_uri(case.target))
            navigation.close('ordinary-caller-draft')
        end
    end)
    spec.it('shares C++ alias lookup across completion, definitions, references and edited headers', function()
        local header = 'namespace AliasTest {\n'
            .. 'class A { public: void save() {} void only_a() {} };\n'
            .. 'class B { public: void save() {} void only_b() {} };\n'
            .. 'using Actual = A; typedef const Actual* Ptr;\n}\n'
        local source = '#include "AliasTypes.hpp"\nvoid alias_run(AliasTest::Ptr p) { p->save(); }\n'
        nav_write('AliasTypes.hpp', header); nav_write('AliasClient.cpp', source)
        local options = { cache_path = nav_root .. '/cache.idx', lister = 'walk' }
        service.refresh(nav_root, options)
        local idx = service.resident(nav_root)
        idx:save(); service.forget(nav_root); service.refresh(nav_root, options)
        local doc = docs.read(nav_root .. '/AliasClient.cpp')
        local position = doc:position(assert(source:find('p->save', 1, true)) + 2)
        local function check(session, line, included, excluded)
            local req = { uri = doc.uri, root = nav_root, session = session, position = position }
            local result = require('codeoutline.completion').complete(req)
            local labels = {}
            for _, item in ipairs(result.items) do labels[item.label] = true end
            spec.truthy(labels[included]); spec.nil_value(labels[excluded])
            req.method = 'lsp_definition'
            local found = nav(req)
            spec.equal(#found, 1); spec.equal(found[1].uri, nav_uri('AliasTypes.hpp'))
            spec.equal(found[1].range.start.line, line)
            local refs = nav({ method = 'lsp_references', session = session, uri = found[1].uri,
                position = found[1].range.start, includeDeclaration = false })
            local hit = false
            for _, ref in ipairs(refs) do if ref.uri == doc.uri then hit = true end end
            spec.truthy(hit)
        end
        check('alias-types', 1, 'only_a', 'only_b')
        local uri = nav_uri('AliasTypes.hpp')
        local changed = header:gsub('Actual = A', 'Actual = B')
        navigation.sync({ session = 'alias-types', open = { [uri] = 1 }, changed = {
            [uri] = { version = 1, language = 'cpp', source = changed } } })
        check('alias-types', 2, 'only_b', 'only_a')
        navigation.close('alias-types')
        nav_write('AliasTypes.hpp', changed); service.refresh(nav_root, options)
        check('alias-types-disk', 2, 'only_b', 'only_a')
        for _, rec in pairs(service.resident(nav_root).files) do
            spec.nil_value(rec.cpp_aliases); spec.nil_value(rec.ordinary_bindings)
        end
    end)
    spec.it('keeps local C++ alias shadowing consistent in completion and navigation', function()
        local source = 'class LocalAliasA { public: void save() {} void only_a() {} };\n'
            .. 'class LocalAliasB { public: void save() {} void only_b() {} };\n'
            .. 'using LocalItem = LocalAliasA;\n'
            .. 'void local_alias_run() { LocalItem a; { using LocalItem = LocalAliasB; LocalItem b; b.save(); a.save(); } }\n'
            .. 'void unknown_alias() { using LocalItem = MissingType; LocalItem c; c.save(); }\n'
        nav_write('LocalAliases.cpp', source)
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local doc = docs.read(nav_root .. '/LocalAliases.cpp')
        for _, case in ipairs({ { 'a.save', 'only_a', 'only_b', 0 }, { 'b.save', 'only_b', 'only_a', 1 }, { 'c.save' } }) do
            local req = { uri = doc.uri, root = nav_root, session = 'local-alias',
                position = doc:position(assert(source:find(case[1], 1, true)) + 1) }
            local labels = {}
            for _, item in ipairs(require('codeoutline.completion').complete(req).items) do labels[item.label] = true end
            req.method = 'lsp_definition'
            local found = nav(req)
            if case[2] then
                spec.truthy(labels[case[2]]); spec.nil_value(labels[case[3]])
                spec.equal(#found, 1); spec.equal(found[1].range.start.line, case[4])
            else
                spec.nil_value(next(labels)); spec.equal(#found, 0)
            end
        end
    end)
    spec.it('shares C++ namespace imports across completion, definitions and references with header overlays', function()
        local header = 'namespace NamespaceTest {\n'
            .. 'namespace A { class Store { public: void save() {} void only_a() {} }; void run() {} }\n'
            .. 'namespace B { class Store { public: void save() {} void only_b() {} }; void run() {} }\n'
            .. '}\nnamespace api = NamespaceTest::A;\n'
        local source = '#include "NamespaceImports.h"\n'
            .. 'void namespace_run(Store* p) { p->save(); run(); api::run(); }\n'
        nav_write('NamespaceTypes.hpp', header)
        nav_write('NamespaceImports.h', '#include "NamespaceTypes.hpp"\nusing api::Store;\nusing api::run;\n')
        nav_write('NamespaceClient.cpp', source)
        nav_write('NamespaceUnrelated.hpp', 'namespace NamespaceTest { namespace A { class Store { public: void unrelated() {} }; } }')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local doc = docs.read(nav_root .. '/NamespaceClient.cpp')
        local function check(line, included, excluded)
            local req = { uri = doc.uri, root = nav_root, session = 'cpp-namespace',
                position = doc:position(assert(source:find('p->save', 1, true)) + 2) }
            local labels = {}
            for _, item in ipairs(require('codeoutline.completion').complete(req).items) do labels[item.label] = true end
            spec.truthy(labels[included]); spec.nil_value(labels[excluded]); spec.nil_value(labels.unrelated)
            req.method = 'lsp_definition'
            for _, name in ipairs({ 'save', 'run', 'api::run', 'Store' }) do
                local first = name == 'run' and assert(source:find(' run();', 1, true)) + 1 or assert(source:find(name, 1, true))
                if name == 'api::run' then first = first + 5 end
                req.position = doc:position(first)
                local found = nav(req)
                spec.equal(#found, 1, name); spec.equal(found[1].uri, nav_uri('NamespaceTypes.hpp'))
                spec.equal(found[1].range.start.line, line, name)
                if name == 'run' then
                    local refs = nav({ method = 'lsp_references', session = req.session, uri = found[1].uri,
                        position = found[1].range.start, includeDeclaration = false })
                    local hits = 0
                    for _, ref in ipairs(refs) do if ref.uri == doc.uri then hits = hits + 1 end end
                    spec.equal(hits, 2)
                end
            end
        end
        check(1, 'only_a', 'only_b')
        local uri = nav_uri('NamespaceTypes.hpp')
        navigation.sync({ session = 'cpp-namespace', open = { [uri] = 1 }, changed = {
            [uri] = { version = 1, language = 'cpp', source = header:gsub('api = NamespaceTest::A', 'api = NamespaceTest::B') } } })
        check(2, 'only_b', 'only_a')
        navigation.close('cpp-namespace')
    end)
    spec.it('completes C++ namespace aliases and imported names without unrelated namespace members', function()
        nav_write('NamespaceCompletion.hpp', 'namespace CompletionImpl { class Store { public: void save() {} }; void run() {} }\n'
            .. 'namespace CompletionLib { using namespace CompletionImpl; }')
        nav_write('NamespaceCompletionOther.hpp', 'namespace CompletionLib { void hidden() {} }')
        local source = '#include "NamespaceCompletion.hpp"\nnamespace short_api = CompletionLib;\n'
            .. 'using namespace short_api;\nvoid completion_entry() { short_api::run(); Store p; p.save(); }\n'
        nav_write('NamespaceCompletion.cpp', source)
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local doc = docs.read(nav_root .. '/NamespaceCompletion.cpp')
        for _, case in ipairs({ { 'short_api::run', 10, 'Store', 'run' }, { 'Store p', 0, 'Store', 'run' }, { 'p.save', 1, 'save' } }) do
            local req = { uri = doc.uri, root = nav_root, session = 'cpp-namespace-completion',
                position = doc:position(assert(source:find(case[1], 1, true)) + case[2]) }
            local labels = {}
            for _, item in ipairs(require('codeoutline.completion').complete(req).items) do labels[item.label] = true end
            spec.truthy(labels[case[3]], case[1]); if case[4] then spec.truthy(labels[case[4]], case[1]) end
            spec.nil_value(labels.hidden)
        end
    end)
    spec.it('blocks C++ ambiguous types and expired local using declarations in LSP queries', function()
        local source = 'namespace ImportA { class Item { public: void save() {} }; void work() {} }\n'
            .. 'namespace ImportB { class Item { public: void save() {} }; void work() {} }\n'
            .. 'void ambiguity() { using namespace ImportA; using namespace ImportB; Item p; p.save(); work(); }\n'
            .. 'void local_import() { { using ImportA::work; using ImportA::Item; work(); } work(); Item q; q.save(); }\n'
        nav_write('NamespaceAmbiguity.cpp', source)
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local doc = docs.read(nav_root .. '/NamespaceAmbiguity.cpp')
        for _, name in ipairs({ 'p.save', 'work(); }\n', '} work();' }) do
            local first = assert(source:find(name, 1, true)) + (name == 'p.save' and 1 or name == '} work();' and 2 or 0)
            local found = nav({ method = 'lsp_definition', uri = doc.uri, root = nav_root, session = 'cpp-ambiguity',
                position = doc:position(first) })
            spec.equal(#found, 0)
        end
        local labels = {}
        for _, item in ipairs(require('codeoutline.completion').complete({ uri = doc.uri, root = nav_root,
            session = 'cpp-ambiguity', position = doc:position(assert(source:find('p.save', 1, true)) + 1) }).items) do labels[item.label] = true end
        spec.nil_value(labels.save)
        local outside = require('codeoutline.completion').complete({ uri = doc.uri, root = nav_root,
            session = 'cpp-ambiguity', position = doc:position(assert(source:find('q.save', 1, true)) + 1) })
        spec.equal(#outside.items, 0)
    end)
    spec.it('finds C#, Java and Kotlin method implementations with imported receivers and draft edits', function()
        local cases = {
            { 'Contract.cs', 'namespace ImplementationCs { public interface I { void Save(int value); } }',
                'Concrete.cs', 'using ImplementationCs; class ImplementationStore : I { public void Save(int item) {} }',
                'UseImplementation.cs', 'using ImplementationCs; class ImplementationUse { void Run(I value) { value.Save(1); } }', 'Save' },
            { 'Contract.java', 'package implementationjava; public interface I { void save(int value); }',
                'Concrete.java', 'package implementationjava; class Store implements I { public void save(int item) {} }',
                'UseImplementation.java', 'package implementationapp; import implementationjava.I; class Use { void run(I value) { value.save(1); } }', 'save' },
            { 'Contract.kt', 'package implementationkt\ninterface I { fun save(value: Int) }',
                'Concrete.kt', 'package implementationkt\nclass Store : I { override fun save(item: Int) {} }',
                'UseImplementation.kt', 'package implementationapp\nimport implementationkt.I as Contract\nfun run(value: Contract) { value.save(1) }', 'save' },
        }
        for _, case in ipairs(cases) do
            nav_write(case[1], case[2]); nav_write(case[3], case[4]); nav_write(case[5], case[6])
        end
        local options = { cache_path = nav_root .. '/cache.idx', lister = 'walk' }
        service.refresh(nav_root, options)
        local idx = service.resident(nav_root); idx:save(); service.forget(nav_root); service.refresh(nav_root, options)
        for _, case in ipairs(cases) do
            local doc = docs.read(nav_root .. '/' .. case[5])
            local req = { method = 'lsp_implementation', session = 'implementations', uri = doc.uri,
                position = doc:position(assert(case[6]:find('value.' .. case[7], 1, true)) + 5) }
            local result = nav(req)
            spec.equal(#result, 1, case[1]); spec.equal(result[1].uri, nav_uri(case[3]))
            req.method = 'lsp_definition'
            local definition = nav(req)
            spec.equal(#definition, 1); spec.equal(definition[1].uri, nav_uri(case[1]))
            req.method = 'lsp_implementation'
            local contract = docs.read(nav_root .. '/' .. case[1])
            local from_decl = nav({ method = 'lsp_implementation', session = req.session, uri = contract.uri,
                position = contract:position(assert(case[2]:find(case[7], 1, true))) })
            spec.equal(#from_decl, 1)
        end
        local uri = nav_uri('Concrete.cs')
        navigation.sync({ session = 'implementations', open = { [uri] = 1 }, changed = {
            [uri] = { version = 1, language = 'csharp', source = cases[1][4]:gsub('int item', 'string item') } } })
        local doc = docs.read(nav_root .. '/Contract.cs')
        local changed = nav({ method = 'lsp_implementation', session = 'implementations', uri = doc.uri,
            position = doc:position(assert(cases[1][2]:find('Save', 1, true))) })
        spec.equal(#changed, 0)
        navigation.close('implementations')
        for _, rec in pairs(service.resident(nav_root).files) do spec.nil_value(rec.implementation_evidence) end
    end)
    spec.it('finds TS implementations through imports and revalidates unsaved signatures', function()
        local contract = 'export interface TsImplementation { save(value: number): void; }'
        local concrete = "import { TsImplementation } from './TsImplementation';\nclass TsImplementationStore implements TsImplementation { save(item: number): void {} }"
        local use = "import { TsImplementation } from './TsImplementation';\nfunction tsImplementationUse(value: TsImplementation) { value.save(1); }"
        nav_write('TsImplementation.ts', contract); nav_write('TsImplementationStore.ts', concrete); nav_write('TsImplementationUse.ts', use)
        local options = { cache_path = nav_root .. '/cache.idx', lister = 'walk' }
        service.refresh(nav_root, options); service.resident(nav_root):save(); service.forget(nav_root); service.refresh(nav_root, options)
        local doc = docs.read(nav_root .. '/TsImplementationUse.ts')
        local req = { method = 'lsp_implementation', session = 'ts-implementations', uri = doc.uri,
            position = doc:position(assert(use:find('value.save', 1, true)) + 5) }
        local result = nav(req); spec.equal(#result, 1); spec.equal(result[1].uri, nav_uri('TsImplementationStore.ts'))
        req.method = 'lsp_definition'; result = nav(req); spec.equal(#result, 1); spec.equal(result[1].uri, nav_uri('TsImplementation.ts'))
        local uri = nav_uri('TsImplementationStore.ts')
        navigation.sync({ session = req.session, open = { [uri] = 1 }, changed = {
            [uri] = { version = 1, language = 'typescript', source = concrete:gsub('item: number', 'item: string') } } })
        req.method = 'lsp_implementation'; result = nav(req); spec.equal(#result, 0)
        navigation.sync({ session = req.session, open = { [uri] = 1 }, changed = {
            [uri] = { version = 2, language = 'typescript', source = concrete } } })
        result = nav(req); spec.equal(#result, 1)
        navigation.close(req.session)
        for _, rec in pairs(service.resident(nav_root).files) do spec.nil_value(rec.implementation_evidence) end
    end)
    spec.it('finds C++ virtual implementations in out-of-line bodies and revalidates draft signatures', function()
        local header = 'namespace CppImplementation {\n'
            .. 'struct Base { virtual void save(int) const = 0; };\n'
            .. 'struct Store : Base { void save(int) const override; };\n}\n'
        local body = '#include "CppImplementation.hpp"\nvoid CppImplementation::Store::save(int item) const {}\n'
        local use = '#include "CppImplementation.hpp"\nvoid CppImplementationRun(CppImplementation::Base *value) { value->save(1); }'
        nav_write('CppImplementation.hpp', header); nav_write('CppImplementationBody.cpp', body)
        nav_write('CppImplementationUse.cpp', use)
        local options = { cache_path = nav_root .. '/cache.idx', lister = 'walk' }
        service.refresh(nav_root, options)
        local idx = service.resident(nav_root); idx:save(); service.forget(nav_root); service.refresh(nav_root, options)
        local doc = docs.read(nav_root .. '/CppImplementationUse.cpp')
        local req = { method = 'lsp_implementation', session = 'cpp-implementations', uri = doc.uri,
            position = doc:position(assert(use:find('save', 1, true))) }
        local result = nav(req)
        spec.equal(#result, 1); spec.equal(result[1].uri, nav_uri('CppImplementationBody.cpp'))
        req.method = 'lsp_definition'
        local definition = nav(req)
        spec.equal(#definition, 1); spec.equal(definition[1].uri, nav_uri('CppImplementation.hpp'))
        local decl = docs.read(nav_root .. '/CppImplementation.hpp')
        local from_decl = nav({ method = 'lsp_implementation', session = req.session, uri = decl.uri,
            position = decl:position(assert(header:find('save', 1, true))) })
        spec.equal(#from_decl, 1); spec.equal(from_decl[1].uri, result[1].uri)
        local uri = nav_uri('CppImplementation.hpp')
        local edited = header:gsub('void save%(int%) const override', 'void save(long) const override')
        navigation.sync({ session = req.session, open = { [uri] = 1 }, changed = {
            [uri] = { version = 1, language = 'cpp', source = edited } } })
        -- The stale body no longer matches the class declaration. It must not
        -- restore the old override merely because its qualified name agrees.
        req.method = 'lsp_implementation'
        local changed = nav(req)
        spec.equal(#changed, 0)
        navigation.close(req.session)
        for _, rec in pairs(service.resident(nav_root).files) do spec.nil_value(rec.implementation_evidence) end
    end)
    spec.it('shares C# aliases, namespaces and static usings across completion and navigation', function()
        local library = 'namespace CSharpFeature {\n'
            .. 'public class StoreA { public void Save() {} public void OnlyA() {} public static void Flush() {} }\n'
            .. 'public class StoreB { public void Save() {} public void OnlyB() {} public static void Flush() {} }\n}\n'
        local source = 'namespace AliasClient;\nusing S = global::CSharpFeature.StoreA;\n'
            .. 'using D = global::CSharpFeature;\nusing static global::CSharpFeature.StoreA;\n'
            .. 'class App { void Run(S store, Shared shared) { store.Save(); shared.Save(); S.Flush(); D.StoreA.Flush(); D::StoreA.Flush(); Flush(); } }'
        nav_write('CSharpFeature.cs', library); nav_write('CSharpClient.cs', source)
        nav_write('CSharpUsings.cs', 'global using Shared = CSharpFeature.StoreA;')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local doc = docs.read(nav_root .. '/CSharpClient.cs')
        local function definitions(fragment, skip, session)
            return nav({ method = 'lsp_definition', uri = doc.uri, session = session or 'cs-alias',
                position = doc:position(assert(source:find(fragment, 1, true)) - 1 + skip) })
        end
        local function labels(fragment, skip, session)
            local result = require('codeoutline.completion').complete({ root = nav_root, uri = doc.uri,
                session = session or 'cs-alias', position = doc:position(assert(source:find(fragment, 1, true)) - 1 + skip) })
            local names = {}
            for _, item in ipairs(result.items) do names[item.label] = true end
            return names
        end
        for _, fragment in ipairs({ 'store.Save', 'shared.Save' }) do
            local found = definitions(fragment, #fragment - 4)
            spec.equal(#found, 1); spec.equal(found[1].uri, nav_uri('CSharpFeature.cs')); spec.equal(found[1].range.start.line, 1)
        end
        local instance = labels('store.Save', 6)
        spec.truthy(instance.Save); spec.truthy(instance.OnlyA); spec.nil_value(instance.OnlyB); spec.nil_value(instance.Flush)
        local static = labels('S.Flush', 2)
        spec.truthy(static.Flush); spec.nil_value(static.Save)
        local namespace = labels('D.StoreA', 2)
        spec.truthy(namespace.StoreA); spec.truthy(namespace.StoreB)
        spec.truthy(labels('D.StoreA.Flush', 9).Flush)
        spec.truthy(labels('D::StoreA.Flush', 10).Flush)
        local bare = labels('Flush(); }', 0)
        spec.truthy(bare.S); spec.truthy(bare.D); spec.truthy(bare.Shared); spec.truthy(bare.Flush)
        local target = definitions('store.Save', 6)[1]
        local refs = nav({ method = 'lsp_references', uri = target.uri, position = target.range.start, session = 'cs-alias' })
        spec.equal(#refs, 2)
        local alias = definitions('S store', 0)
        spec.equal(#alias, 1); spec.equal(range_text('CSharpFeature.cs', alias[1].range), 'StoreA')
        for _, fragment in ipairs({ 'S.Flush', 'D.StoreA.Flush', 'D::StoreA.Flush', 'Flush(); }' }) do
            local skip = fragment:find('Flush', 1, true) - 1
            local found = definitions(fragment, skip)
            spec.equal(#found, 1); spec.equal(found[1].range.start.line, 1)
        end
        local uri = nav_uri('CSharpUsings.cs')
        navigation.sync({ session = 'cs-alias', open = { [uri] = 1 }, changed = {
            [uri] = { version = 1, language = 'csharp', source = 'global using Shared = CSharpFeature.StoreB;' } } })
        local changed = definitions('shared.Save', 7)
        spec.equal(#changed, 1); spec.equal(changed[1].range.start.line, 2)
        local members = labels('shared.Save', 7)
        spec.truthy(members.OnlyB); spec.nil_value(members.OnlyA)
        spec.equal(definitions('store.Save', 6)[1].range.start.line, 1)
        navigation.close('cs-alias')
        for _, rec in pairs(service.resident(nav_root).files) do
            spec.nil_value(rec.csharp_usings); spec.nil_value(rec.csharp_scopes); spec.nil_value(rec.csharp_statics)
        end
    end)
    spec.it('does not suggest or navigate through invalid same-scope C# alias chains', function()
        local source = 'using First = CSharpFeature.StoreA; using Broken = First;\n'
            .. 'class InvalidAliases { void Run(Broken item) { item.Save(); } }'
        nav_write('CSharpInvalidAliases.cs', source)
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local doc = docs.read(nav_root .. '/CSharpInvalidAliases.cs')
        local req = { root = nav_root, uri = doc.uri, session = 'cs-invalid',
            position = doc:position(assert(source:find('item.Save', 1, true)) + 4) }
        local result = require('codeoutline.completion').complete(req)
        spec.equal(#result.items, 0)
        req.method = 'lsp_definition'
        spec.equal(#nav(req), 0)
    end)
    spec.it('finds C# constructor references through type and namespace aliases', function()
        local library = 'namespace CSharpCtor { public class Store { public Store() {} } }'
        local source = 'using S = CSharpCtor.Store; using N = CSharpCtor;\n'
            .. 'class Creator { void Run() { var a = new S(); var b = new N.Store(); } }'
        nav_write('CSharpCtor.cs', library); nav_write('CSharpCreator.cs', source)
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local doc = docs.read(nav_root .. '/CSharpCreator.cs')
        local req = { method = 'lsp_definition', uri = doc.uri, session = 'cs-constructor',
            position = doc:position(assert(source:find('new S', 1, true)) + 3) }
        local found = nav(req)
        spec.equal(#found, 1); spec.equal(found[1].uri, nav_uri('CSharpCtor.cs'))
        req.method = 'lsp_references'
        local refs = nav(req)
        spec.equal(#refs, 2)
    end)
    spec.it('resolves Lua dofile returned members and unsaved export aliases', function()
        nav_write('LuaModule.lua', 'local M = {}\nlocal function actual() end\nM.save = actual\nreturn M')
        nav_write('LuaWrong.lua', 'local M = {}\nfunction M.save() end\nreturn M')
        local source = "local m = dofile('./LuaModule.lua')\nfunction use_module() m.save() end"
        nav_write('LuaClient.lua', source)
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local doc = docs.read(nav_root .. '/LuaClient.lua')
        local function definition(session)
            return nav({ method = 'lsp_definition', uri = doc.uri, session = session,
                position = doc:position(assert(source:find('save()', 1, true)) - 1) })
        end
        local found = definition()
        spec.equal(#found, 1); spec.equal(found[1].uri, nav_uri('LuaModule.lua'))
        spec.equal(range_text('LuaModule.lua', found[1].range), 'actual')
        local uses = nav({ method = 'lsp_references', uri = nav_uri('LuaModule.lua'), position = { line = 1, character = 16 }, includeDeclaration = false })
        spec.equal(#uses, 1); spec.equal(range_text('LuaClient.lua', uses[1].range), 'save')
        local target = nav_uri('LuaModule.lua')
        navigation.sync({ session = 'lua-module', open = { [target] = 1 }, changed = {
            [target] = { version = 1, language = 'lua', source = '\n\nreturn { save = function() end }' } } })
        found = definition('lua-module')
        spec.equal(#found, 1); spec.equal(found[1].range.start.line, 2)
        navigation.close('lua-module')
    end)
    spec.it('navigates cached module members and extracted dofile values through cache reload and drafts', function()
        local module = "local M = rawget(_G, 'router')\nif type(M) ~= 'table' then M = {} end\n"
            .. 'function M.set_log_prefix(prefix) return M end\nreturn M\n'
        nav_write('CachedRouter.lua', module)
        nav_write('ExtractedMisc.lua', 'local M = {}\nfunction M.to_bool(value) return value end\nreturn M\n')
        nav_write('WrongExtracted.lua', 'function to_bool() end\nfunction set_log_prefix() end\n')
        local source = "local router = dofile('CachedRouter.lua')\n"
            .. "local to_bool = dofile('ExtractedMisc.lua').to_bool\n"
            .. "local convert = require('ExtractedMisc').to_bool\n"
            .. "router.set_log_prefix('MAIN')\nlocal enabled = to_bool(true)\nlocal also = convert(false)\n"
        nav_write('ExtractedClient.lua', source)
        local options = { cache_path = nav_root .. '/cache.idx', lister = 'walk' }
        service.refresh(nav_root, options); service.resident(nav_root):save(); service.forget(nav_root)
        service.refresh(nav_root, options)
        local doc = docs.read(nav_root .. '/ExtractedClient.lua')
        local function definition(fragment, skip)
            return nav({ method = 'lsp_definition', session = 'extracted-values', uri = doc.uri,
                position = doc:position(assert(source:find(fragment, 1, true)) - 1 + (skip or 0)) })
        end
        local router = definition('router.set_log_prefix', 7)
        spec.equal(#router, 1); spec.equal(router[1].uri, nav_uri('CachedRouter.lua'))
        spec.equal(range_text('CachedRouter.lua', router[1].range), 'set_log_prefix')
        for _, item in ipairs({ { ').to_bool', 2 }, { 'to_bool(true)', 0 }, { 'convert(false)', 0 } }) do
            local found = definition(item[1], item[2])
            spec.equal(#found, 1); spec.equal(found[1].uri, nav_uri('ExtractedMisc.lua'))
            spec.equal(range_text('ExtractedMisc.lua', found[1].range), 'to_bool')
        end
        local refs = nav({ method = 'lsp_references', session = 'extracted-values', uri = nav_uri('ExtractedMisc.lua'),
            position = { line = 1, character = 12 }, includeDeclaration = false })
        spec.equal(#refs, 4, 'both imported values and both calls refer to the exported function')
        local uri = nav_uri('ExtractedMisc.lua')
        navigation.sync({ session = 'extracted-values', open = { [uri] = 1 }, changed = {
            [uri] = { version = 1, language = 'lua', source = '\nlocal M = {}\nfunction M.to_bool(value) return value end\nreturn M\n' } } })
        spec.equal(definition('to_bool(true)')[1].range.start.line, 2)
        navigation.sync({ session = 'extracted-values', open = { [uri] = 2 }, changed = {
            [uri] = { version = 2, language = 'lua', source = 'return {}\n' } } })
        spec.equal(#definition('to_bool(true)'), 0)
        spec.equal(#definition(').to_bool', 2), 0)
        navigation.close('extracted-values')
    end)
    spec.it('resolves g_exports aliases as bare globals', function()
        local module = 'do\n\tlocal function design_list(player) return player end\n'
            .. '\tg_exports.phantom_get_design_list = design_list\n'
            .. '\tg_exports.phantom_called = design_list()\nend\n'
        nav_write('PhantomModule.lua', module)
        local source = 'function use_globals(player)\n\treturn phantom_get_design_list(player) + phantom_called(player)\nend\n'
        nav_write('PhantomClient.lua', source)
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local doc = docs.read(nav_root .. '/PhantomClient.lua')
        local function definition(text)
            return nav({ method = 'lsp_definition', uri = doc.uri,
                position = doc:position(assert(source:find(text, 1, true)) - 1) })
        end
        local found = definition('phantom_get_design_list(')
        spec.equal(#found, 1); spec.equal(found[1].uri, nav_uri('PhantomModule.lua'))
        spec.equal(range_text('PhantomModule.lua', found[1].range), 'design_list')
        spec.equal(#definition('phantom_called('), 0)
        local mdoc = docs.read(nav_root .. '/PhantomModule.lua')
        local uses = nav({ method = 'lsp_references', uri = nav_uri('PhantomModule.lua'), includeDeclaration = false,
            position = mdoc:position(assert(module:find('design_list', 1, true)) - 1) })
        spec.equal(#uses, 2); spec.equal(range_text('PhantomClient.lua', uses[1].range), 'phantom_get_design_list')
        spec.equal(uses[2].uri, nav_uri('PhantomModule.lua'))
        spec.equal(range_text('PhantomModule.lua', uses[2].range), 'design_list')
        local uri = nav_uri('PhantomModule.lua')
        navigation.sync({ session = 'global-draft', open = { [uri] = 1 }, changed = {
            [uri] = { version = 1, language = 'lua', source = module:gsub('phantom_get_design_list', 'renamed_global') } } })
        local missing = nav({ method = 'lsp_definition', session = 'global-draft', uri = doc.uri,
            position = doc:position(assert(source:find('phantom_get_design_list', 1, true)) - 1) })
        spec.equal(#missing, 0)
        navigation.sync({ session = 'global-draft', open = { [uri] = 2 }, changed = {
            [uri] = { version = 2, language = 'lua', source = '\n' .. module } } })
        local moved = nav({ method = 'lsp_definition', session = 'global-draft', uri = doc.uri,
            position = doc:position(assert(source:find('phantom_get_design_list', 1, true)) - 1) })
        spec.equal(#moved, 1); spec.equal(moved[1].range.start.line, 2)
        navigation.close('global-draft')
    end)
    spec.it('reloads configured global export tables for disk and unsaved definitions', function()
        local module = 'local function configured_impl() end\ncustom_exports.configured_global = configured_impl\n'
        nav_write('ConfiguredExports.lua', module)
        nav_write('ConfiguredClient.lua', 'configured_global()\n')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local req = { method = 'lsp_definition', uri = nav_uri('ConfiguredClient.lua'), position = { line = 0, character = 2 } }
        spec.equal(#nav(req), 0)
        nav_write('.codeoutline.json', '{"luaGlobalExportTables":["custom_exports"]}')
        local found = nav(req)
        spec.equal(#found, 1); spec.equal(found[1].uri, nav_uri('ConfiguredExports.lua'))
        local uri = nav_uri('ConfiguredExports.lua')
        navigation.sync({ session = 'configured-global', open = { [uri] = 1 }, changed = {
            [uri] = { version = 1, language = 'lua', source = '\n' .. module } } })
        req.session = 'configured-global'
        found = nav(req)
        spec.equal(#found, 1); spec.equal(found[1].range.start.line, 1)
        nav_write('.codeoutline.json', '{"luaGlobalExportTables":[]}')
        spec.equal(#nav(req), 0)
        navigation.close('configured-global')
        os.remove(nav_root .. '/.codeoutline.json')
    end)
    spec.it('shares configured export navigation across private collisions, cache reloads and drafts', function()
        assert(xutils.mkdir_p(nav_root .. '/GlobalPublic'))
        assert(xutils.mkdir_p(nav_root .. '/GlobalPrivate'))
        local owners = { 'g_exports', '__global_exports', 'custom_exports' }
        local config = xutils.json_pack({ luaGlobalExportTables = { '__global_exports', 'custom_exports' } })
        for ordinal, owner in ipairs(owners) do
            nav_write('.codeoutline.json', config)
            local name = 'configured_export_' .. ordinal
            local public = 'GlobalPublic/api_' .. ordinal .. '.lua'
            local private = 'GlobalPrivate/hidden_' .. ordinal .. '.lua'
            local client = 'SameNameGlobalClient_' .. ordinal .. '.lua'
            local module = 'local ' .. name .. ' = function() end; ' .. owner .. '.' .. name .. ' = ' .. name .. '\n'
            local source = 'function same_name_global_use_' .. ordinal .. '() ' .. name .. '() end\n'
            nav_write(public, module)
            nav_write(private, 'local ' .. name .. ' = function() end\n')
            nav_write(client, source)
            local options = { cache_path = nav_root .. '/cache.idx', lister = 'walk' }
            service.refresh(nav_root, options); service.resident(nav_root):save(); service.forget(nav_root)
            service.refresh(nav_root, options)
            local doc = docs.read(nav_root .. '/' .. client)
            local req = { method = 'lsp_definition', session = 'same-name-exports-' .. ordinal, uri = doc.uri,
                position = doc:position(assert(source:find(name .. '()', 1, true))) }
            local found = nav(req)
            spec.equal(#found, 1); spec.equal(found[1].uri, nav_uri(public))
            spec.equal(range_text(public, found[1].range), name)
            local uri = nav_uri(public)
            local exported = docs.read(nav_root .. '/' .. public)
            local key = nav({ method = 'lsp_definition', uri = uri,
                position = exported:position(assert(module:find(owner .. '.' .. name, 1, true)) + #owner) })
            spec.equal(#key, 1); spec.equal(key[1].range.start.character, 6)
            local refs = nav({ method = 'lsp_references', uri = uri, position = { line = 0, character = 7 }, includeDeclaration = false })
            spec.equal(#refs, 1); spec.equal(refs[1].uri, req.uri)
            navigation.sync({ session = req.session, open = { [uri] = 1 }, changed = {
                [uri] = { version = 1, language = 'lua', source = '\n' .. module } } })
            spec.equal(nav(req)[1].range.start.line, 1)
            nav_write('.codeoutline.json', '{"luaGlobalExportTables":[]}')
            spec.equal(#nav(req), owner == 'g_exports' and 1 or 0)
            nav_write('.codeoutline.json', config)
            spec.equal(#nav(req), 1)
            navigation.sync({ session = req.session, open = { [uri] = 2 }, changed = {
                [uri] = { version = 2, language = 'lua', source = owner .. '.' .. name .. ' = function() end\n' } } })
            spec.equal(#nav(req), 1, 'direct global definitions retain the same collision handling')
            navigation.close(req.session)
            spec.equal(#service.resident(nav_root):symbols().by_name[name], 2)
        end
        os.remove(nav_root .. '/.codeoutline.json')
    end)
    spec.it('resolves native objects through the metatable a C call returns', function()
        nav_write('pool.c', '#define POOL_META "demo.pool"\n'
            .. 'static int pool_read(lua_State *L) { luaL_checkinteger(L, 2); return 0; }\n'
            .. 'static int push_pool(lua_State *L) { lua_newuserdata(L, 8); luaL_setmetatable(L, POOL_META); return 1; }\n'
            .. 'static int pool_open(lua_State *L) { return push_pool(L); }\n'
            .. 'static const luaL_Reg pool_methods[] = {{"read", pool_read}, {NULL, NULL}};\n'
            .. 'static const luaL_Reg pool_funcs[] = {{"open", pool_open}, {NULL, NULL}};\n'
            .. 'int luaopen_pool(lua_State *L) {\n'
            .. '  luaL_newmetatable(L, POOL_META);\n  luaL_setfuncs(L, pool_methods, 0);\n  lua_pop(L, 1);\n'
            .. '  luaL_newlib(L, pool_funcs);\n  return 1;\n}\n')
        local source = 'local w = pool.open()\nfunction use()\n\treturn w:read(1)\nend\n'
        nav_write('watcher.lua', source)
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local doc = docs.read(nav_root .. '/watcher.lua')
        local at = assert(source:find('w:read(', 1, true)) - 1 + #'w:read('
        local sig = nav({ method = 'lsp_signature', uri = doc.uri, position = doc:position(at) })
        spec.equal(sig.signatures[1].label, 'read(arg1:int)')
        local found = nav({ method = 'lsp_definition', uri = doc.uri, position = doc:position(at - 2) })
        spec.equal(#found, 1); spec.equal(found[1].uri, nav_uri('pool.c'))
        spec.equal(range_text('pool.c', found[1].range), 'pool_read')
    end)
    spec.it('shares native receiver bindings across completion and navigation', function()
        local file = assert(io.open('xnet2lua/xlua/lua_xrecord.c', 'rb'))
        nav_write('native_record.c', file:read('a')); file:close()
        local prefix = "local xr = require('xrecord')\nlocal schema = xr.schema({})\nlocal items = schema:new(4)\n"
        local cases = {
            { prefix .. 'items:has(1)', true },
            { prefix .. 'function use() return items:has(1) end', true },
            { prefix .. 'function use(items) return items:has(1) end', false },
            { prefix .. 'items = {}\nitems:has(1)', false },
            { 'function other()\n' .. prefix .. 'end\nitems:has(1)', false },
            { 'do\n' .. prefix .. 'end\nitems:has(1)', false },
            { prefix .. 'do local items = {} end\nitems:has(1)', true },
            { prefix .. 'local items = items\nitems:has(1)', true },
            { "local xr = require('xrecord')\nlocal xr = {}\nlocal items = xr.create({})\nitems:has(1)", false },
            { prefix .. 'local items = schema:new(4) or {}\nitems:has(1)', false },
        }
        local completion = require('codeoutline.completion')
        for i, case in ipairs(cases) do
            nav_write('native_case.lua', case[1])
            service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
            local doc = docs.read(nav_root .. '/native_case.lua')
            local offset = assert(case[1]:find('items:has', 1, true)) - 1 + #'items:'
            local req = { method = 'lsp_definition', uri = doc.uri, position = doc:position(offset) }
            local found = nav(req)
            spec.equal(#found > 0, case[2], 'definition case ' .. i)
            local has = false
            for _, item in ipairs(completion.complete(req).items) do if item.label == 'has' then has = true end end
            spec.equal(has, case[2], 'completion case ' .. i)
        end
        local uri = nav_uri('native_case.lua')
        for version, source in ipairs({ prefix .. 'items:has(1)', prefix .. 'local items = {}\nitems:has(1)' }) do
            navigation.sync({ session = 'native-draft', open = { [uri] = version },
                changed = { [uri] = { version = version, language = 'lua', source = source } } })
            local doc = docs.new(uri, source, version, 'lua')
            local offset = assert(source:find('items:has', 1, true)) - 1 + #'items:'
            local req = { session = 'native-draft', method = 'lsp_definition', uri = uri, position = doc:position(offset) }
            spec.equal(#nav(req) > 0, version == 1, 'draft definition')
            local has = false
            for _, item in ipairs(completion.complete(req).items) do if item.label == 'has' then has = true end end
            spec.equal(has, version == 1, 'draft completion')
        end
        navigation.close('native-draft')
    end)
    spec.it('loads native contracts on demand without changing saved index records', function()
        local source = 'static int lazy_read(lua_State *L) { luaL_checkinteger(L, 1); return 0; }\n'
            .. 'static const luaL_Reg funcs[] = {{"read", lazy_read}, {NULL, NULL}};\n'
            .. 'int luaopen_lazy_contract(lua_State *L) { luaL_newlib(L, funcs); return 1; }\n'
        nav_write('lazy_contract.c', source)
        nav_write('lazy_user.lua', "local lib = require('lazy_contract')\nlib.read(1)\n")
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local idx = service.resident(nav_root)
        local function check_records(files)
            for _, rec in pairs(files) do
                spec.nil_value(rec.foreign_exports)
                for _, node in ipairs(rec.nodes) do
                    spec.nil_value(node.foreign_signatures)
                    if rec.size <= 1048576 then spec.nil_value(node.sig) end
                end
            end
        end
        check_records(idx.files)
        local doc = docs.read(nav_root .. '/lazy_user.lua')
        local req = { method = 'lsp_signature', uri = doc.uri, position = { line = 1, character = 9 } }
        local foreign = require('codeoutline.foreign')
        local G = idx:symbols()
        local ctx = require('codeoutline.lua_bindings').context(G)
        spec.truthy(foreign.has_candidates(G, ctx))
        local rec = idx.files['lazy_contract.c']
        spec.nil_value(foreign.exports(rec, 'lua', 'lazy_contract'))
        spec.equal(nav(req).signatures[1].label, 'read(arg1:int)')
        local exports = foreign.exports(rec, 'lua', 'lazy_contract')
        spec.truthy(exports.read)
        spec.equal(nav(req).signatures[1].label, 'read(arg1:int)')
        spec.equal(foreign.exports(rec, 'lua', 'lazy_contract'), exports)
        check_records(idx.files)
        assert(idx:save())
        local file = assert(io.open(idx.cache_path, 'rb'))
        local envelope = cmsgpack.unpack(file:read('a')); file:close()
        local saved = cmsgpack.unpack(xcompress.inflate(envelope.payload, envelope.size))
        check_records(saved.files)
        local loaded = require('codeoutline.index').open(nav_root, { cache_path = idx.cache_path })
        local reloaded = loaded:symbols()
        local files = foreign.modules(reloaded, 'lua', 'lazy_contract', require('codeoutline.lua_bindings').context(reloaded))
        spec.equal(#files, 1)
        spec.truthy(foreign.exports(reloaded.files[files[1]], 'lua', 'lazy_contract').read)
        check_records(loaded.files)
        -- Unsaved C changes replace the query contract without touching disk/index.
        local uri = nav_uri('lazy_contract.c')
        navigation.sync({ session = 'lazy-draft', open = { [uri] = 1 }, changed = {
            [uri] = { version = 1, language = 'c', source = source:gsub('checkinteger', 'checkstring') } } })
        req.session = 'lazy-draft'
        spec.equal(nav(req).signatures[1].label, 'read(arg1:string)')
        navigation.close('lazy-draft')
        req.session = 'spec'
        spec.equal(nav(req).signatures[1].label, 'read(arg1:int)')
        check_records(idx.files)
        nav_write('lazy_contract.c', source:gsub('checkinteger', 'checkstring'))
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        spec.equal(nav(req).signatures[1].label, 'read(arg1:string)')
        check_records(idx.files)
    end)
    spec.it('restores ordinary signatures for MCP outlines without retaining them in the index', function()
        nav_write('lazy_outline.cpp', 'class LazyOutline {\npublic:\n    int compute(int amount);\n'
            .. string.rep('// padding\n', 180) .. '};\n')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local idx = service.resident(nav_root)
        local G = idx:symbols()
        local f = G.file_index['lazy_outline.cpp']
        local method
        for _, node in ipairs(G.files[f].nodes) do if node.name == 'compute' then method = node end end
        spec.truthy(method)
        spec.nil_value(method.sig)
        local detail = navigation.detail(G, f, method)
        spec.contains(detail.sig, 'int amount')
        spec.equal(navigation.detail(G, f, method), detail)
        local output = service.explore(nav_root, 'LazyOutline', { budget = 12000 })
        spec.contains(output, 'compute(int amount)')
        spec.nil_value(method.sig)
    end)
    spec.it('retries lazy signature reads and parses after transient failures', function()
        for _, failure in ipairs({ 'read', 'parse' }) do
            local rel = 'retry_detail_' .. failure .. '.lua'
            nav_write(rel, 'function retry_detail(alpha) return alpha end\n')
            service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
            local idx = service.resident(nav_root)
            local G = idx:symbols()
            local f = G.file_index[rel]
            local node = G.files[f].nodes[1]
            local read, tokenize = docs.read, parse.parse_tokens
            local reads, parses = 0, 0
            docs.read = function(path, ...)
                if path:sub(-#rel) == rel then
                    reads = reads + 1
                    if failure == 'read' and reads == 1 then return nil end
                end
                return read(path, ...)
            end
            parse.parse_tokens = function(path, ...)
                if path == rel then
                    parses = parses + 1
                    if failure == 'parse' and parses == 1 then return nil end
                end
                return tokenize(path, ...)
            end
            local ok, err = pcall(function()
                spec.nil_value(navigation.detail(G, f, node).sig)
                local detail = navigation.detail(G, f, node)
                spec.contains(detail.sig, 'alpha')
                spec.equal(navigation.detail(G, f, node), detail)
                spec.equal(reads, 2)
                spec.equal(parses, failure == 'parse' and 2 or 1)
                spec.nil_value(node.sig)
            end)
            docs.read, parse.parse_tokens = read, tokenize
            assert(ok, err)
        end
    end)
    spec.it('retries native metadata in later queries after a failed source read', function()
        local rel = 'retry_contract.c'
        nav_write(rel, 'static int retry_read(lua_State *L) { luaL_checkinteger(L, 1); return 0; }\n'
            .. 'static const luaL_Reg funcs[] = {{"read", retry_read}, {NULL, NULL}};\n'
            .. 'int luaopen_retry_contract(lua_State *L) { luaL_newlib(L, funcs); return 1; }\n')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local idx = service.resident(nav_root)
        local G = idx:symbols()
        local foreign = require('codeoutline.foreign')
        local ctx = require('codeoutline.lua_bindings').context(G)
        local read, reads = docs.read, 0
        docs.read = function(path, ...)
            if path:sub(-#rel) == rel then
                reads = reads + 1
                if reads == 1 then return nil end
            end
            return read(path, ...)
        end
        local ok, err = pcall(function()
            spec.equal(#foreign.modules(G, 'lua', 'retry_contract', ctx), 0)
            spec.equal(#foreign.modules(G, 'lua', 'retry_contract', ctx), 0)
            spec.equal(reads, 1) -- do not repeat failed I/O inside one query
            ctx = require('codeoutline.lua_bindings').context(G)
            local files = foreign.modules(G, 'lua', 'retry_contract', ctx)
            spec.equal(#files, 1)
            local exports = foreign.exports(G.files[files[1]], 'lua', 'retry_contract')
            spec.truthy(exports.read)
            spec.equal(#foreign.modules(G, 'lua', 'retry_contract', ctx), 1)
            spec.equal(reads, 2)
            spec.nil_value(G.files[files[1]].foreign_exports)
        end)
        docs.read = read
        assert(ok, err)
    end)
    spec.it('rejects same-size source changes before restoring signatures or native metadata', function()
        local cases = {
            { rel = 'stale_detail.lua', before = 'function stale_detail(alpha) return alpha end\n',
                after = 'function stale_detail(bravo) return bravo end\n' },
            { rel = 'stale_contract.c', native = true,
                before = 'static int stale_read(lua_State *L) { luaL_checknumber(L, 1); return 0; }\n'
                    .. 'static const luaL_Reg funcs[] = {{"read", stale_read}, {NULL, NULL}};\n'
                    .. 'int luaopen_stale_contract(lua_State *L) { luaL_newlib(L, funcs); return 1; }\n' },
        }
        cases[2].after = cases[2].before:gsub('checknumber', 'checkstring')
        cases[#cases + 1] = { rel = 'stale_bom.lua', before = '\239\187\191function stale_bom(alpha) return alpha end\n',
            after = '\239\187\191function stale_bom(bravo) return bravo end\n' }
        for _, case in ipairs(cases) do
            spec.equal(#case.before, #case.after)
            nav_write(case.rel, case.before)
            service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
            local idx = service.resident(nav_root)
            local G = idx:symbols()
            local f = G.file_index[case.rel]
            local foreign = require('codeoutline.foreign')
            local ctx = require('codeoutline.lua_bindings').context(G)
            if case.native then navigation.full(G, f) end -- native upgrade of a cached ordinary parse
            nav_write(case.rel, case.after)
            local ok, err
            if case.native then ok, err = pcall(foreign.modules, G, 'lua', 'stale_contract', ctx)
            else ok, err = pcall(navigation.detail, G, f, G.files[f].nodes[1]) end
            spec.equal(ok, false)
            spec.contains(err, 'source changed during query')
            -- A rejected load must not poison the cache or mark native metadata loaded.
            nav_write(case.rel, case.before)
            if case.native then spec.equal(#foreign.modules(G, 'lua', 'stale_contract', ctx), 1)
            else spec.contains(navigation.detail(G, f, G.files[f].nodes[1]).sig, 'alpha') end
        end
    end)
    spec.it('keeps successful empty native parses cached across queries', function()
        local rel = 'empty_lazy_contract.c'
        nav_write(rel, 'int luaopen_empty_lazy_contract(lua_State *L) { return 0; }\n')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local idx = service.resident(nav_root)
        local G = idx:symbols()
        local foreign = require('codeoutline.foreign')
        local read, reads = docs.read, 0
        docs.read = function(path, ...)
            if path:sub(-#rel) == rel then reads = reads + 1 end
            return read(path, ...)
        end
        local ok, err = pcall(function()
            for _ = 1, 2 do
                local ctx = require('codeoutline.lua_bindings').context(G)
                spec.equal(#foreign.modules(G, 'lua', 'empty_lazy_contract', ctx), 0)
            end
            spec.equal(reads, 1)
        end)
        docs.read = read
        assert(ok, err)
    end)
    spec.it('reuses a verified source snapshot within one navigation request', function()
        local rel = 'detail_snapshot.lua'
        nav_write(rel, 'function detail_snapshot(alpha) return alpha end\n')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local idx = service.resident(nav_root)
        local G = idx:symbols()
        local f = G.file_index[rel]
        local V = setmetatable({ idx = idx, disk = {} }, { __index = G })
        local doc = navigation.source_doc(V, f)
        nav_write(rel, 'function detail_snapshot(bravo) return bravo end\n')
        spec.equal(navigation.source_doc(V, f), doc)
        spec.contains(navigation.detail(V, f, G.files[f].nodes[1]).sig, 'alpha')
        local other = setmetatable({ idx = idx, disk = {} }, { __index = G })
        local ok, err = pcall(navigation.source_doc, other, f)
        spec.equal(ok, false); spec.contains(err, 'source changed during query')
    end)
    spec.it('opens a quoted Lua path that lives deeper than the workspace root', function()
        assert(xutils.mkdir_p(nav_root .. '/deep/scripts'))
        nav_write('deep/scripts/mod.lua', 'local M = {}\nfunction M.save() end\nreturn M\n')
        local source = "local m = dofile('scripts/mod.lua')\nfunction use() m.save() end\n"
        nav_write('deep/user.lua', source)
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local doc = docs.read(nav_root .. '/deep/user.lua')
        local found = nav({ method = 'lsp_definition', uri = doc.uri,
            position = doc:position(assert(source:find('mod.lua', 1, true))) })
        spec.equal(#found, 1); spec.equal(found[1].uri, nav_uri('deep/scripts/mod.lua'))
    end)
    spec.it('shares event rules and aliases between navigation and relationship queries', function()
        local config = nav_root .. '/.codeoutline.json'
        local source = 'local api = require("unified_bus")\nlocal key = "unified_tick"\nfunction unified_send() api.emit(key) end\n'
        local target = 'local api = unified_bus\nlocal event = "unified_tick"\nlocal function unified_done() end\nlocal cb = unified_done\napi.on(event, cb)\n'
        nav_write('unified_send.lua', source); nav_write('unified_target.lua', target)
        write(config, '{"rules":[{"kind":"event","language":"lua","call":"unified_bus.emit","argument":1,'
            .. '"register":"unified_bus.on","keyArgument":1,"handlerArgument":2}]}')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local ok, err = pcall(function()
            local doc = docs.read(nav_root .. '/unified_send.lua')
            local req = { method = 'lsp_definition', uri = doc.uri, position = doc:position(assert(source:find('key)', 1, true)) - 1) }
            local found = nav(req)
            spec.equal(#found, 1); spec.equal(found[1].uri, nav_uri('unified_target.lua'))
            spec.equal(range_text('unified_target.lua', found[1].range), 'event')
            local _, info = service.callers(nav_root, 'unified_done', { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
            spec.equal(#info.callers, 1); spec.equal(info.callers[1].name, 'unified_send')
            -- Navigation still finds a registration whose callback is anonymous.
            nav_write('unified_target.lua', target:gsub('api.on%(event, cb%)', 'api.on(event, function() end)'))
            service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
            found = nav(req); spec.equal(#found, 1)
            _, info = service.callers(nav_root, 'unified_done', { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
            spec.equal(#info.callers, 0)
            write(config, '{"rules":[]}')
            found = nav(req)
            for _, loc in ipairs(found) do spec.truthy(loc.uri ~= nav_uri('unified_target.lua')) end
        end)
        os.remove(config); if not ok then error(err, 0) end
    end)
    spec.it('navigates shared callbacks and RPC targets in other languages', function()
        local config = nav_root .. '/.codeoutline.json'
        local cases = {
            { 'js', 'function shared_js_done() {} const cb = shared_js_done; function shared_js_run() { schedule(1, cb); }', 'shared_js_done', 'cb)' },
            { 'ts', 'function shared_ts_done() {} const cb: Handler = shared_ts_done; function shared_ts_run() { schedule(1, cb); }', 'shared_ts_done', 'cb)' },
            { 'py', 'def shared_py_done():\n    pass\ncb = shared_py_done\ndef shared_py_run():\n    schedule(1, cb)\n', 'shared_py_done', 'cb)' },
            { 'c', 'void shared_c_done(void) {} void shared_c_run(void) { void (*cb)(void) = &shared_c_done; schedule(1, cb); }', 'shared_c_done', 'cb);' },
        }
        write(config, '{"rules":[{"kind":"callback","call":"schedule","argument":2}]}')
        local ok, err = pcall(function()
            for _, case in ipairs(cases) do
                local rel = 'shared_callback.' .. case[1]
                nav_write(rel, case[2])
                service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
                local doc = docs.read(nav_root .. '/' .. rel)
                local found = nav({ method = 'lsp_definition', uri = doc.uri,
                    position = doc:position(assert(case[2]:find(case[4], 1, true)) - 1) })
                spec.equal(#found, 1, case[1]); spec.equal(found[1].uri, doc.uri, case[1])
                spec.equal(range_text(rel, found[1].range), case[3], case[1])
            end
            nav_write('shared_target.lua', 'function shared_rpc_done() end\nfunction shared_rpc_run() worker.post(2, "shared_rpc_done") end\n')
            write(config, '{"rules":[{"kind":"target","call":"worker.post","argument":2}]}')
            service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
            local doc = docs.read(nav_root .. '/shared_target.lua')
            local found = nav({ method = 'lsp_definition', uri = doc.uri, position = { line = 1, character = 51 } })
            spec.equal(#found, 1); spec.equal(range_text('shared_target.lua', found[1].range), 'shared_rpc_done')
        end)
        os.remove(config); if not ok then error(err, 0) end
    end)
    spec.it('navigates shared imported event aliases in TS and Python', function()
        local config = nav_root .. '/.codeoutline.json'
        write(config, '{"rules":[{"kind":"event","call":"shared_bus.emit","argument":1,'
            .. '"register":"shared_bus.on","keyArgument":1,"handlerArgument":2}]}')
        local cases = {
            { 'ts', 'import {emit as publish} from "shared_bus"; function event_run() { publish("shared_cross_tick"); }',
                'import {on as subscribe} from "shared_bus"; subscribe("shared_cross_tick", () => {});' },
            { 'py', 'from shared_bus import emit as publish\ndef event_run():\n    publish("shared_cross_tick")\n',
                'from shared_bus import on as subscribe\nsubscribe("shared_cross_tick", unknown_callback)\n' },
        }
        local ok, err = pcall(function()
            for _, case in ipairs(cases) do
                nav_write('shared_event_send.' .. case[1], case[2]); nav_write('shared_event_target.' .. case[1], case[3])
                service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
                local doc = docs.read(nav_root .. '/shared_event_send.' .. case[1])
                local found = nav({ method = 'lsp_definition', uri = doc.uri,
                    position = doc:position(assert(case[2]:find('shared_cross_tick', 1, true))) })
                spec.equal(#found, 1, case[1]); spec.equal(found[1].uri, nav_uri('shared_event_target.' .. case[1]))
                spec.equal(range_text('shared_event_target.' .. case[1], found[1].range), '"shared_cross_tick"')
            end
        end)
        os.remove(config); if not ok then error(err, 0) end
    end)
    spec.it('uses shared rules in unsaved new registration documents', function()
        local config = nav_root .. '/.codeoutline.json'
        write(config, '{"rules":[{"kind":"event","call":"draft_bus.emit","argument":1,'
            .. '"register":"draft_bus.on","keyArgument":1,"handlerArgument":2}]}')
        local source = 'function draft_send() draft_bus.emit("draft_rule_tick") end'
        nav_write('shared_draft_send.lua', source)
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local target = nav_uri('shared_unsaved_registration.lua')
        navigation.sync({ session = 'shared-rules', open = { [target] = 1 }, changed = {
            [target] = { version = 1, language = 'lua', source = 'local api = draft_bus\napi.on("draft_rule_tick", function() end)' } } })
        local ok, err = pcall(function()
            local doc = docs.read(nav_root .. '/shared_draft_send.lua')
            local found = nav({ method = 'lsp_definition', session = 'shared-rules', uri = doc.uri,
                position = doc:position(assert(source:find('draft_rule_tick', 1, true))) })
            spec.equal(#found, 1); spec.equal(found[1].uri, target); spec.equal(found[1].range.start.line, 1)
        end)
        navigation.close('shared-rules'); os.remove(config); if not ok then error(err, 0) end
    end)
    spec.it('does not collect shared dispatch sites for unrelated definition requests', function()
        local config = nav_root .. '/.codeoutline.json'
        write(config, '{"rules":[{"kind":"event","call":"unused.emit","argument":1,'
            .. '"register":"unused.on","keyArgument":1,"handlerArgument":2}]}')
        local source = 'local function ordinary_leaf() end\nfunction ordinary_run() ordinary_leaf() end\nunused.emit("unrelated")'
        nav_write('shared_ordinary.lua', source)
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local doc = docs.read(nav_root .. '/shared_ordinary.lua')
        local methods = getmetatable(doc)
        local original, count = methods.dispatch, 0
        methods.dispatch = function(...) count = count + 1; return original(...) end
        local ok, err = pcall(function()
            local found = nav({ method = 'lsp_definition', uri = doc.uri, position = { line = 1, character = 26 } })
            spec.equal(#found, 1); spec.equal(count, 0)
        end)
        methods.dispatch = original; os.remove(config); if not ok then error(err, 0) end
    end)
    spec.it('uses configurable literal argument rules and ignores unrelated strings and comments', function()
        local config = nav_root .. '/.codeoutline.json'
        nav_write('messages.lua', "xthread.post(nested(1, 2), 'xmysql_business_done', false)\n")
        nav_write('handlers.lua', 'xthread.register("xmysql_business_done", function(a, b) end)\n'
            .. '-- xthread.register("xmysql_business_done", function() end)\n'
            .. 'other.register("xmysql_business_done", function() end)\n')
        write(config, '{"definitionRules":[{"language":"lua","call":"xthread.post","argument":2,'
            .. '"target":"xthread.register","targetArgument":1}]}')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local ok, err = pcall(function()
            local result = nav({ method = 'lsp_definition', uri = nav_uri('messages.lua'), position = { line = 0, character = 31 } })
            spec.equal(#result, 1); spec.equal(result[1].uri, nav_uri('handlers.lua'))
            spec.equal(range_text('handlers.lua', result[1].range), '"xmysql_business_done"')
            spec.equal(#nav({ method = 'lsp_definition', uri = nav_uri('messages.lua'), position = { line = 0, character = 23 } }), 0)
        end)
        os.remove(config)
        if not ok then error(err, 0) end
    end)
    spec.it('supports changed argument positions, long strings and nested anonymous function arguments', function()
        local config = nav_root .. '/.codeoutline.json'
        nav_write('custom_send.lua', 'Bus.send(function(a, b) if a then return a, b end end, {1, 2}, [=[事件😀]=])\n')
        nav_write('custom_target.lua', 'Bus.on(function(a, b) return a, b end, "事件😀")\n')
        write(config, '{"definitionRules":[{"call":"Bus.send","argument":3,"target":"Bus.on","targetArgument":2}]}')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local ok, err = pcall(function()
            local doc = docs.read(nav_root .. '/custom_send.lua')
            local result = nav({ method = 'lsp_definition', uri = doc.uri,
                position = doc:position(doc.source:find('事件', 1, true) - 1) })
            spec.equal(#result, 1); spec.equal(result[1].uri, nav_uri('custom_target.lua'))
            spec.equal(range_text('custom_target.lua', result[1].range), '"事件😀"')
            -- Editing configuration takes effect without touching source or index.
            write(config, '{"definitionRules":[]}')
            spec.equal(#nav({ method = 'lsp_definition', uri = doc.uri,
                position = doc:position(doc.source:find('事件', 1, true) - 1) }), 0)
        end)
        os.remove(config)
        if not ok then error(err, 0) end
    end)
    spec.it('matches decoded escapes and honors unsaved registration replacements', function()
        local config = nav_root .. '/.codeoutline.json'
        nav_write('escaped_send.lua', 'Bus.send("done")\n')
        nav_write('escaped_target.lua', "Bus.on('d\\111ne', function() end)\n")
        write(config, '{"definitionRules":[{"call":"Bus.send","argument":1,"target":"Bus.on","targetArgument":1}]}')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local ok, err = pcall(function()
            local req = { method = 'lsp_definition', session = 'message-draft', uri = nav_uri('escaped_send.lua'),
                position = { line = 0, character = 12 } }
            local result = nav(req)
            spec.equal(#result, 1); spec.equal(result[1].uri, nav_uri('escaped_target.lua'))
            local uri = nav_uri('escaped_target.lua')
            navigation.sync({ session = req.session, open = { [uri] = 1 }, changed = {
                [uri] = { source = 'Bus.on("different", function() end)', version = 1, language = 'lua' } } })
            spec.equal(#nav(req), 0, 'draft hides disk registration')
            navigation.sync({ session = req.session, open = {} })
            spec.equal(#nav(req), 1, 'closing draft restores disk registration')
        end)
        navigation.close('message-draft'); os.remove(config)
        if not ok then error(err, 0) end
    end)
    spec.it('resolves declaration targets with optional qualifiers and colon call names', function()
        local config = nav_root .. '/.codeoutline.json'
        nav_write('rpc_call.lua', 'dservice.send(pool, "raw_execute_n", sql)\n'
            .. 'local ret = self:callCluster(node, "FriendSrv", "req_friend", 1)\n')
        nav_write('rpc_impl.lua', 'function Ntf.raw_execute_n(sql) end\n'
            .. 'function friMgr:req_friend(uid) end\nfunction raw_execute_n() end\n')
        write(config, '{"definitionRules":[{"call":"dservice.send","argument":2,"targetKind":"declaration",'
            .. '"qualifiers":["Ntf"]},{"call":"callCluster","argument":3,"targetKind":"declaration"}]}')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local ok, err = pcall(function()
            local doc = docs.read(nav_root .. '/rpc_call.lua')
            local result = nav({ method = 'lsp_definition', uri = doc.uri,
                position = { line = 0, character = 29 } })
            spec.equal(#result, 1, 'qualified declaration only, bare function excluded')
            spec.equal(result[1].uri, nav_uri('rpc_impl.lua'))
            spec.equal(range_text('rpc_impl.lua', result[1].range), 'raw_execute_n')
            local colon = nav({ method = 'lsp_definition', uri = doc.uri, position = { line = 1, character = 53 } })
            spec.equal(#colon, 1, 'self:callCluster binds the callCluster rule')
            spec.equal(range_text('rpc_impl.lua', colon[1].range), 'req_friend')
            write(config, '{"rules":[{"kind":"definition","call":"dservice.send","argument":2,'
                .. '"targetKind":"declaration","qualifiers":["Ntf"]},{"kind":"definition",'
                .. '"call":"callCluster","argument":3,"targetKind":"declaration"}]}')
            spec.equal(#nav({ method = 'lsp_definition', uri = doc.uri,
                position = { line = 0, character = 29 } }), 1, 'definition-only migration retains qualifiers')
            colon = nav({ method = 'lsp_definition', uri = doc.uri, position = { line = 1, character = 53 } })
            spec.equal(#colon, 1, 'definition-only migration retains method shorthand')
        end)
        os.remove(config)
        if not ok then error(err, 0) end
    end)
    spec.it('preserves cross-service table declarations when migrating to unified target rules', function()
        local config = nav_root .. '/.codeoutline.json'
        nav_write('rpc_migrated_call.lua', 'local dservice = require "dservice"\n'
            .. 'dservice.send(mysqlpool, "rpc_migrated_execute", sql)\n')
        nav_write('rpc_migrated_impl.lua', 'local Ntf = {}\nfunction Ntf.rpc_migrated_execute(sql) end\n')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local ok, err = pcall(function()
            local req = { method = 'lsp_definition', uri = nav_uri('rpc_migrated_call.lua'),
                position = { line = 1, character = 30 } }
            write(config, '{"definitionRules":[{"language":"lua","call":"dservice.send",'
                .. '"argument":2,"targetKind":"declaration"}]}')
            local before = nav(req)
            spec.equal(#before, 1)
            write(config, '{"rules":[{"language":"lua","call":"dservice.send","argument":2,"kind":"target"}]}')
            local after = nav(req)
            spec.equal(#after, #before, 'migration retains remote table declarations')
            spec.equal(after[1].uri, before[1].uri)
            spec.equal(range_text('rpc_migrated_impl.lua', after[1].range), 'rpc_migrated_execute')
        end)
        os.remove(config)
        if not ok then error(err, 0) end
    end)
    spec.it('keeps Lua literal forms and argument positions in shared target rules', function()
        local config = nav_root .. '/.codeoutline.json'
        nav_write('audit_rpc_impl.lua', 'local CMD = {}\nfunction CMD.audit_rpc_done() end\n')
        local lines = { 'worker.post(1, "audit_rpc_\\100one")',
            'worker.post(1, [=[audit_rpc_done]=])',
            'worker.post(function() local a, b = 1, 2; return a, b end, "audit_rpc_done")' }
        local source = table.concat(lines, '\n') .. '\n'
        nav_write('audit_rpc_call.lua', source)
        write(config, '{"rules":[{"kind":"target","language":"lua","call":"worker.post","argument":2}]}')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local ok, err = pcall(function()
            local doc = docs.read(nav_root .. '/audit_rpc_call.lua')
            for line, text in ipairs(lines) do
                local found = nav({ method = 'lsp_definition', uri = doc.uri,
                    position = { line = line - 1, character = assert(text:find('audit_rpc_', 1, true)) } })
                spec.equal(#found, 1, 'literal/anonymous-function case ' .. line)
                spec.equal(found[1].uri, nav_uri('audit_rpc_impl.lua'))
            end
        end)
        os.remove(config); if not ok then error(err, 0) end
    end)
    spec.it('honors qualifiers on shared declaration navigation', function()
        local config = nav_root .. '/.codeoutline.json'
        nav_write('audit_qualified.lua', 'worker.post(1, "audit_qualified")\n'
            .. 'function CMD.audit_qualified() end\nfunction Ntf.audit_qualified() end\n')
        write(config, '{"rules":[{"kind":"target","language":"lua","call":"worker.post",'
            .. '"argument":2,"qualifiers":["CMD"]}]}')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local ok, err = pcall(function()
            local found = nav({ method = 'lsp_definition', uri = nav_uri('audit_qualified.lua'),
                position = { line = 0, character = 20 } })
            spec.equal(#found, 1); spec.equal(found[1].range.start.line, 1)
        end)
        os.remove(config); if not ok then error(err, 0) end
    end)
    spec.it('combines matching shared and legacy navigation rules', function()
        local config = nav_root .. '/.codeoutline.json'
        nav_write('audit_mixed.lua', 'audit_emit("audit_mixed")\naudit_on("audit_mixed", function() end)\n'
            .. 'function audit_mixed() end\n')
        write(config, '{"rules":[{"kind":"event","call":"audit_emit","argument":1,"register":"audit_on",'
            .. '"keyArgument":1,"handlerArgument":2}],"definitionRules":[{"call":"audit_emit",'
            .. '"argument":1,"targetKind":"declaration"}]}')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local ok, err = pcall(function()
            local found = nav({ method = 'lsp_definition', uri = nav_uri('audit_mixed.lua'),
                position = { line = 0, character = 14 } })
            spec.equal(#found, 2, 'registration and declaration both survive migration')
        end)
        os.remove(config); if not ok then error(err, 0) end
    end)
    spec.it('retains the legacy matcher when shared and legacy rules deduplicate', function()
        local config = nav_root .. '/.codeoutline.json'
        nav_write('audit_dedup.lua', 'local transport = make_transport()\ntransport.send("audit_dedup")\n'
            .. 'transport.on("audit_dedup", function() end)\n')
        write(config, '{"rules":[{"kind":"event","language":"lua","call":"transport.send","argument":1,'
            .. '"register":"transport.on","keyArgument":1,"handlerArgument":2}],'
            .. '"definitionRules":[{"language":"lua","call":"transport.send","argument":1,'
            .. '"target":"transport.on","targetArgument":1}]}')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local ok, err = pcall(function()
            local found = nav({ method = 'lsp_definition', uri = nav_uri('audit_dedup.lua'),
                position = { line = 1, character = 19 } })
            spec.equal(#found, 1); spec.equal(found[1].range.start.line, 2)
        end)
        os.remove(config); if not ok then error(err, 0) end
    end)
    spec.it('navigates explicit Lua target APIs without inferring unknown receivers', function()
        local config = nav_root .. '/.codeoutline.json'
        nav_write('audit_receiver.lua', 'local dservice\nif active then dservice = require "dservice" end\n'
            .. 'dservice.send(1, "audit_receiver")\nlocal CMD = {}\nfunction CMD.audit_receiver() end\n')
        write(config, '{"rules":[{"kind":"target","language":"lua","call":"dservice.send","argument":2}]}')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local ok, err = pcall(function()
            local found = nav({ method = 'lsp_definition', uri = nav_uri('audit_receiver.lua'),
                position = { line = 2, character = 21 } })
            spec.equal(#found, 1); spec.equal(found[1].range.start.line, 4)
        end)
        os.remove(config); if not ok then error(err, 0) end
    end)
    spec.it('keeps explicit Lua event registration navigation with unknown receivers', function()
        local config = nav_root .. '/.codeoutline.json'
        nav_write('audit_event_receiver.lua', 'local bus = make_bus()\nbus.emit([=[audit_event_receiver]=])\n')
        nav_write('audit_event_registration.lua', 'local bus = make_bus()\nbus.on("audit_event_receiver", function() end)\n')
        write(config, '{"rules":[{"kind":"event","language":"lua","call":"bus.emit","argument":1,'
            .. '"register":"bus.on","keyArgument":1,"handlerArgument":2}]}')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local ok, err = pcall(function()
            local found = nav({ method = 'lsp_definition', uri = nav_uri('audit_event_receiver.lua'),
                position = { line = 1, character = 15 } })
            spec.equal(#found, 1); spec.equal(found[1].uri, nav_uri('audit_event_registration.lua'))
        end)
        os.remove(config); if not ok then error(err, 0) end
    end)
    spec.it('narrows Lua RPC target navigation by known service provenance', function()
        local config = nav_root .. '/.codeoutline.json'
        nav_write('audit_redis_service.lua', 'local CMD = {}\nfunction CMD.service_scope_init() end\n')
        nav_write('audit_other_service.lua', 'local CMD = {}\nfunction CMD.service_scope_init() end\n')
        local cases = {
            { 'local redis = skynet.uniqueservice("audit_redis_service")\ndservice.call(redis, "service_scope_init")', 'dservice.call', 2 },
            { 'local redis = kernel.newservice("audit_redis_service", 1)\nlocal alias = redis\ndservice.call(alias, "service_scope_init")', 'dservice.call', 2 },
            { 'local redis = skynet.uniqueservice("audit_redis_service")\nskynet.call(redis, "lua", "service_scope_init")', 'skynet.call', 3 },
            { 'dservice.call("audit_redis_service", "service_scope_init")', 'dservice.call', 2 },
            { 'cluster.call("node", "audit_redis_service", "service_scope_init")', 'cluster.call', 3 },
            { 'custom.request("audit_redis_service", 0, "mode", "service_scope_init")', 'custom.request', 4, 1 },
        }
        local ok, err = pcall(function()
            for _, case in ipairs(cases) do
                local source = 'local skynet = require "skynet"\nlocal kernel = skynet\nlocal dservice = require "dservice"\n' .. case[1]
                nav_write('audit_service_caller.lua', source)
                write(config, xutils.json_pack({ rules = { { kind = 'target', language = 'lua', call = case[2],
                    argument = case[3], serviceArgument = case[4] } } }))
                service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
                local doc = docs.read(nav_root .. '/audit_service_caller.lua')
                local found = nav({ method = 'lsp_definition', uri = doc.uri,
                    position = doc:position(assert(source:find('service_scope_init', 1, true))) })
                spec.equal(#found, 1, case[1]); spec.equal(found[1].uri, nav_uri('audit_redis_service.lua'))
            end
        end)
        os.remove(config); if not ok then error(err, 0) end
    end)
    spec.it('tracks a single service assignment to a previously declared or global variable', function()
        local config = nav_root .. '/.codeoutline.json'
        write(config, '{"rules":[{"kind":"target","language":"lua","call":"dservice.call","argument":2}]}')
        local cases = {
            'local cservice = nil\nfunction boot() cservice = skynet.uniqueservice("audit_redis_service", skynet.self())\ndservice.call(cservice, "service_scope_init") end',
            'function boot() assigned_service = skynet.newservice("audit_redis_service")\ndservice.call(assigned_service, "service_scope_init") end',
            'local cservice\nfunction boot() local redis = skynet.uniqueservice("audit_redis_service")\ncservice = redis\nlocal target = cservice\ndservice.call(target, "service_scope_init") end',
        }
        local ok, err = pcall(function()
            for _, body in ipairs(cases) do
                local source = 'local skynet = require "skynet"\nlocal dservice = require "dservice"\n' .. body
                nav_write('audit_assigned_service.lua', source)
                service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
                local doc = docs.read(nav_root .. '/audit_assigned_service.lua')
                local found = nav({ method = 'lsp_definition', uri = doc.uri,
                    position = doc:position(assert(source:find('service_scope_init', 1, true))) })
                spec.equal(#found, 1, body); spec.equal(found[1].uri, nav_uri('audit_redis_service.lua'))
            end
        end)
        os.remove(config); if not ok then error(err, 0) end
    end)
    spec.it('does not narrow RPC targets through reassigned or shadowed service bindings', function()
        local config = nav_root .. '/.codeoutline.json'
        write(config, '{"rules":[{"kind":"target","language":"lua","call":"dservice.call","argument":2}]}')
        local cases = {
            'local redis = skynet.uniqueservice("audit_redis_service")\nredis = other\ndservice.call(redis, "service_scope_init")',
            'local redis = skynet.uniqueservice("audit_redis_service")\nfunction run(redis) dservice.call(redis, "service_scope_init") end',
            'local skynet = {}\nfunction skynet.uniqueservice(name) end\nlocal redis = skynet.uniqueservice("audit_redis_service")\ndservice.call(redis, "service_scope_init")',
            'local redis = skynet.uniqueservice("not_indexed_service")\ndservice.call(redis, "service_scope_init")',
            'local skynet = require "./fake_skynet"\nlocal redis = skynet.uniqueservice("audit_redis_service")\ndservice.call(redis, "service_scope_init")',
            'local redis = skynet.uniqueservice("audit_redis_service") or other\ndservice.call(redis, "service_scope_init")',
            'local redis\nif active then redis = skynet.uniqueservice("audit_redis_service") end\ndservice.call(redis, "service_scope_init")',
            'local redis\nredis = skynet.uniqueservice("audit_redis_service")\nredis = other\ndservice.call(redis, "service_scope_init")',
            'local redis\nfunction assign() redis = skynet.uniqueservice("audit_redis_service") end\ndservice.call(redis, "service_scope_init")',
            'local redis\ndservice.call(redis, "service_scope_init")\nredis = skynet.uniqueservice("audit_redis_service")',
            'local redis\nfunction first() redis = skynet.uniqueservice("audit_redis_service") end\nfunction second() redis = other end\ndservice.call(redis, "service_scope_init")',
        }
        local ok, err = pcall(function()
            for _, body in ipairs(cases) do
                local source = 'local skynet = require "skynet"\nlocal dservice = require "dservice"\n' .. body
                nav_write('audit_service_caller.lua', source)
                service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
                local doc = docs.read(nav_root .. '/audit_service_caller.lua')
                local found = nav({ method = 'lsp_definition', uri = doc.uri,
                    position = doc:position(assert(source:find('service_scope_init', 1, true))) })
                spec.equal(#found, 2, body)
            end
        end)
        os.remove(config); if not ok then error(err, 0) end
    end)
    spec.it('does not fall back to unrelated declarations when a known service lacks a handler', function()
        local config = nav_root .. '/.codeoutline.json'
        nav_write('audit_empty_service.lua', 'local CMD = {}\nfunction CMD.other_handler() end\n')
        nav_write('audit_missing_handler.lua', 'local skynet = require "skynet"\n'
            .. 'local redis = skynet.uniqueservice("audit_empty_service")\ndservice.call(redis, "service_scope_init")\n')
        write(config, '{"rules":[{"kind":"target","language":"lua","call":"dservice.call","argument":2}]}')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local ok, err = pcall(function()
            local found = nav({ method = 'lsp_definition', uri = nav_uri('audit_missing_handler.lua'), position = { line = 2, character = 26 } })
            spec.equal(#found, 0)
        end)
        os.remove(config); if not ok then error(err, 0) end
    end)
    spec.it('retains every exact service filename match without unrelated handlers', function()
        local config = nav_root .. '/.codeoutline.json'
        assert(xutils.mkdir_p(nav_root .. '/service_one')); assert(xutils.mkdir_p(nav_root .. '/service_two'))
        nav_write('service_one/ambiguous_rpc.lua', 'function CMD.ambiguous_rpc_init() end\n')
        nav_write('service_two/ambiguous_rpc.lua', 'function CMD.ambiguous_rpc_init() end\n')
        nav_write('audit_ambiguous_rpc.lua', 'local skynet = require "skynet"\nlocal target = skynet.newservice("ambiguous_rpc")\n'
            .. 'dservice.call(target, "ambiguous_rpc_init")\nfunction unrelated.ambiguous_rpc_init() end\n')
        write(config, '{"rules":[{"kind":"target","language":"lua","call":"dservice.call","argument":2}]}')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local ok, err = pcall(function()
            local found = nav({ method = 'lsp_definition', uri = nav_uri('audit_ambiguous_rpc.lua'), position = { line = 2, character = 26 } })
            spec.equal(#found, 2)
            for _, loc in ipairs(found) do spec.truthy(loc.uri:find('/ambiguous_rpc.lua', 1, true)) end
        end)
        os.remove(config); if not ok then error(err, 0) end
    end)
    spec.it('resolves string key targets in assignments and table constructors', function()
        local config = nav_root .. '/.codeoutline.json'
        nav_write('key_call.lua', 'update_message_time("login.KeyResp", "login.KeyResp")\n')
        nav_write('key_def.lua', 'local protocols = {}\nprotocols["login.KeyResp"] = 1004\n'
            .. 'local wait_log = { ["login.KeyResp"] = true }\n')
        nav_write('key_read.lua', 'local t = protocols["login.KeyResp"]\n')
        write(config, '{"definitionRules":[{"call":"update_message_time","argument":1,"targetKind":"key",'
            .. '"qualifiers":["protocols"]}]}')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local ok, err = pcall(function()
            local doc = docs.read(nav_root .. '/key_call.lua')
            local req = { method = 'lsp_definition', uri = doc.uri, position = { line = 0, character = 25 } }
            local result = nav(req)
            spec.equal(#result, 1, 'qualifier keeps the assignment only')
            spec.equal(result[1].uri, nav_uri('key_def.lua'))
            spec.equal(range_text('key_def.lua', result[1].range), '"login.KeyResp"')
            write(config, '{"definitionRules":[{"call":"update_message_time","argument":1,"targetKind":"key"}]}')
            spec.equal(#nav(req), 2, 'without qualifiers the constructor key matches too')
            -- Reads and table lookups never bind; only the written key does.
            spec.equal(#nav({ method = 'lsp_definition', uri = nav_uri('key_read.lua'),
                position = { line = 0, character = 23 } }), 0)
        end)
        os.remove(config)
        if not ok then error(err, 0) end
    end)
    spec.it('matches decoded keys and restricts qualifiers to plain table names', function()
        local config = nav_root .. '/.codeoutline.json'
        nav_write('decoded_call.lua', 'lookup("foo")\n')
        nav_write('decoded_key.lua', 'protocols["\\102oo"] = 1\n'
            .. 'protocols["\\x66oo"] = 2\nprotocols[ [=[foo]=] ] = 3\n')
        nav_write('qualified_key.lua', 'other.protocols["foo"] = 4\n'
            .. 'local keys = { ["foo"] = 5 }\n')
        local rule = '{"call":"lookup","argument":1,"targetKind":"key","qualifiers":["protocols"]}'
        write(config, '{"definitionRules":[' .. rule .. ',' .. rule .. ']}')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local ok, err = pcall(function()
            local req = { method = 'lsp_definition', uri = nav_uri('decoded_call.lua'),
                position = { line = 0, character = 9 } }
            local result = nav(req)
            spec.equal(#result, 3, 'decoded keys match once each; qualified tables and constructors are excluded')
            for _, loc in ipairs(result) do spec.equal(loc.uri, nav_uri('decoded_key.lua')) end
            write(config, '{"definitionRules":[{"call":"lookup","argument":1,"targetKind":"key"}]}')
            spec.equal(#nav(req), 5, 'without qualifiers all written keys match')
        end)
        os.remove(config)
        if not ok then error(err, 0) end
    end)
    spec.it('validates rule argument positions', function()
        local config = nav_root .. '/.codeoutline.json'
        write(config, '{"definitionRules":[{"call":"Bus.send","argument":0,"target":"Bus.on","targetArgument":1}]}')
        local ok, err = pcall(nav, { method = 'lsp_definition', uri = nav_uri('escaped_send.lua'),
            position = { line = 0, character = 12 } })
        os.remove(config)
        spec.equal(ok, false); spec.contains(tostring(err), 'argument must be an integer')
    end)
    spec.it('falls back to bounded exact-name definitions without changing strict navigation consumers', function()
        for _, dir in ipairs({ 'candidateA', 'candidateB', 'candidateUse' }) do assert(xutils.mkdir_p(nav_root .. '/' .. dir)) end
        nav_write('candidateA/lib.c', 'int CandidateFar(void) { return 1; }\n')
        nav_write('candidateB/lib.c', 'int CandidateFar(void) { return 2; }\n')
        nav_write('candidateB/private.c', 'static int CandidateFar(void) { return 3; }\n')
        nav_write('candidateB/other.lua', 'function CandidateFar() end\n')
        local source = 'int CandidateUse(void) { return CandidateFar(); }\n'
        nav_write('candidateUse/use.c', source); nav_write('candidateUse/use.cpp', source)
        local options = { cache_path = nav_root .. '/cache.idx', lister = 'walk' }
        service.refresh(nav_root, options)
        local ok, err = pcall(function()
            for _, extension in ipairs({ 'c', 'cpp' }) do
                local doc = docs.read(nav_root .. '/candidateUse/use.' .. extension)
                local req = { method = 'lsp_definition', uri = doc.uri,
                    position = doc:position(assert(source:find('CandidateFar', 1, true)) - 1) }
                local result = nav(req)
                spec.equal(#result, 2)
                spec.equal(result[1].uri, nav_uri('candidateA/lib.c')); spec.equal(result[2].uri, nav_uri('candidateB/lib.c'))
                for _, target in ipairs(result) do spec.equal(range_text(target.uri == result[1].uri and 'candidateA/lib.c' or 'candidateB/lib.c', target.range), 'CandidateFar') end
                for _, method in ipairs({ 'lsp_references', 'lsp_prepare_calls', 'lsp_implementation' }) do
                    req.method = method
                    local strict = nav(req)
                    spec.truthy(strict == false or #strict == 0, method .. ' must not use navigation candidates')
                end
                req.method = 'lsp_hover'; spec.equal(nav(req), false)
                req.method = 'lsp_definition'; req.includePaths = { 'candidateA' }
                spec.equal(#nav(req), 0, 'explicit include policy is authoritative')
            end
            local uri = nav_uri('candidateA/lib.c')
            navigation.sync({ session = 'candidate-draft', open = { [uri] = 1 }, changed = {
                [uri] = { source = '\n\nint CandidateFar(void) { return 4; }\n', version = 1, language = 'c' } } })
            local doc = docs.read(nav_root .. '/candidateUse/use.cpp')
            local result = nav({ method = 'lsp_definition', session = 'candidate-draft', uri = doc.uri,
                position = doc:position(assert(source:find('CandidateFar', 1, true)) - 1) })
            spec.equal(#result, 2); spec.equal(result[1].range.start.line, 2)
            navigation.close('candidate-draft')
        end)
        navigation.close('candidate-draft')
        for _, dir in ipairs({ 'candidateA', 'candidateB', 'candidateUse' }) do assert(xutils.rmtree(nav_root .. '/' .. dir)) end
        service.refresh(nav_root, options); assert(ok, err)
    end)
    spec.it('limits candidate sources and preserves Lua import, local and receiver barriers', function()
        for _, dir in ipairs({ 'candidateLua', 'candidateCpp', 'candidateCaller' }) do assert(xutils.mkdir_p(nav_root .. '/' .. dir)) end
        for i = 1, 10 do nav_write('candidateCpp/f' .. i .. '.c', 'int CandidateMany(void) { return 1; }\n') end
        nav_write('candidateCaller/use.cpp', 'void UseMany() { CandidateMany(); }\n')
        nav_write('candidateLua/a.lua', 'function remote.CandidateLua() end\nlocal function CandidatePrivate() end\n')
        nav_write('candidateLua/b.lua', 'function remote.CandidateLua() end\nlocal function CandidatePrivate() end\n')
        nav_write('candidateLua/module.lua', 'local M = {}\nreturn M\n')
        local lua = 'remote.CandidateLua()\nunknown.CandidateLua()\nCandidatePrivate()\n'
            .. 'local remote = dofile("../candidateLua/module.lua")\nremote.CandidateLua()\n'
        nav_write('candidateCaller/use.lua', lua)
        local options = { cache_path = nav_root .. '/cache.idx', lister = 'walk' }
        service.refresh(nav_root, options)
        local ok, err = pcall(function()
            local doc = docs.read(nav_root .. '/candidateCaller/use.cpp')
            local result, out = nav({ method = 'lsp_definition', uri = doc.uri, position = { line = 0, character = 19 } })
            spec.equal(#result, 4); spec.equal(out.incomplete, true, 'candidate sources are bounded')
            local lua_doc = docs.read(nav_root .. '/candidateCaller/use.lua')
            for _, case in ipairs({ { 0, 8, 2 }, { 1, 9, 0 }, { 2, 3, 0 }, { 4, 8, 0 } }) do
                result = nav({ method = 'lsp_definition', uri = lua_doc.uri, position = { line = case[1], character = case[2] } })
                spec.equal(#result, case[3], 'Lua line ' .. case[1])
            end
        end)
        for _, dir in ipairs({ 'candidateLua', 'candidateCpp', 'candidateCaller' }) do assert(xutils.rmtree(nav_root .. '/' .. dir)) end
        service.refresh(nav_root, options); assert(ok, err)
    end)
    spec.it('keeps inferred language across unknown-suffix bindings, tokens, positions and drafts', function()
        local source = '#include "util.h"\nint UnknownSuffixUse() { return helper(1); }\n'
        nav_write('unknown.fragment', source)
        local uri = nav_uri('unknown.fragment')
        local function jump(session)
            return nav({ method = 'lsp_definition', session = session, uri = uri,
                position = { line = 1, character = 36 } })
        end
        local result = jump('unknown-disk')
        spec.equal(#result, 1); spec.equal(result[1].uri, nav_uri('util.c'))
        for _, hint in ipairs({ 'c', 'cpp', 'plaintext' }) do
            navigation.sync({ session = 'unknown-hint', open = { [uri] = 1 }, changed = {
                [uri] = { source = source, version = 1, language = hint } } })
            result = jump('unknown-hint'); spec.equal(#result, 1); spec.equal(result[1].uri, nav_uri('util.c'))
            navigation.close('unknown-hint')
        end
        local edited = 'int UnknownDraft() { return 1; }\nint UnknownSuffixUse() { return UnknownDraft(); }\n'
        navigation.sync({ session = 'unknown-hint', open = { [uri] = 2 }, changed = {
            [uri] = { source = edited, version = 2, language = 'cpp' } } })
        result = nav({ method = 'lsp_definition', session = 'unknown-hint', uri = uri, position = { line = 1, character = 36 } })
        spec.equal(#result, 1); spec.equal(result[1].uri, uri); spec.equal(result[1].range.start.line, 0)
        navigation.close('unknown-hint')
        spec.nil_value(service.resident(nav_root).files['unknown.fragment'])
        local branches = '#include "util.h"\n#if PLATFORM\nvoid ActiveUnknown() {}\n#else\nvoid InactiveUnknown() { helper(1); }\n#endif\n'
        navigation.sync({ session = 'unknown-branches', open = { [uri] = 1 }, changed = {
            [uri] = { source = branches, version = 1, language = 'cpp' } } })
        result = nav({ method = 'lsp_definition', session = 'unknown-branches', uri = uri, position = { line = 4, character = 27 } })
        spec.equal(#result, 1); spec.equal(result[1].uri, nav_uri('util.c'))
        navigation.close('unknown-branches')
        os.remove(nav_root .. '/unknown.fragment')
    end)
    spec.it('goes to the definition across files and from a prototype to its body', function()
        local result = nav({ method = 'lsp_definition', uri = nav_uri('main.c'), position = { line = 1, character = 35 } })
        spec.equal(#result, 1)
        spec.equal(result[1].uri, nav_uri('util.c'))
        spec.equal(range_text('util.c', result[1].range), 'helper')
        local from_decl = nav({ method = 'lsp_definition', uri = nav_uri('util.h'), position = { line = 0, character = 5 } })
        spec.equal(from_decl[1].uri, nav_uri('util.c'))
        spec.equal(#nav({ method = 'lsp_definition', uri = nav_uri('main.c'), position = { line = 1, character = 1 } }), 0)
    end)
    spec.it('goes from import lines to the files they load', function()
        for _, dir in ipairs({ 'mods/core', 'pyp', 'web', 'csrc', 'sysinc/sys' }) do assert(xutils.mkdir_p(nav_root .. '/' .. dir)) end
        nav_write('mods/core/util.lua', 'local M = {}\nreturn M\n')
        nav_write('mods/main.lua', 'local util = require("mods.core.util")\nlocal again = dofile("mods/core/util.lua")\n'
            .. 'local function dofile() end\n')
        nav_write('pyp/__init__.py', '')
        nav_write('pyp/store.py', 'class Store:\n    pass\n')
        nav_write('pyp/api.py', 'from . import store\n')
        nav_write('web/lib.ts', 'export function lib() {}\n')
        nav_write('web/app.ts', "import { lib } from './lib';\n")
        nav_write('csrc/local.h', 'int local_fn(void);\n')
        nav_write('csrc/main.c', '#include "local.h"\n#include <sys/codeoutline_test.h>\n#include <codeoutline_absent.h>\n')
        local system = nav_root .. '/sysinc'
        nav_write('sysinc/sys/codeoutline_test.h', '/* system header */\n')
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local ok, err = pcall(function()
            local function jump(rel, line, character, extra)
                local req = { method = 'lsp_definition', uri = nav_uri(rel), position = { line = line, character = character } }
                for k, v in pairs(extra or {}) do req[k] = v end
                local result = nav(req)
                local out = {}
                for _, loc in ipairs(result) do out[#out + 1] = loc.uri .. '#' .. loc.range.start.line end
                return table.concat(out, ' ')
            end
            local util = nav_uri('mods/core/util.lua') .. '#0'
            spec.equal(jump('mods/main.lua', 0, 28), util, 'require string')
            spec.equal(jump('mods/main.lua', 0, 15), util, 'require call name')
            spec.equal(jump('mods/main.lua', 1, 15), util, 'dofile beats a same-named project function')
            spec.equal(jump('mods/main.lua', 1, 25), util, 'dofile path')
            spec.equal(jump('pyp/api.py', 0, 16), nav_uri('pyp/store.py') .. '#0', 'python relative module')
            spec.equal(jump('web/app.ts', 0, 24), nav_uri('web/lib.ts') .. '#0', 'typescript module string')
            spec.equal(jump('csrc/main.c', 0, 12), nav_uri('csrc/local.h') .. '#0', 'quoted include')
            spec.equal(jump('csrc/main.c', 1, 12, { includePaths = { system } }),
                docs.uri(system .. '/sys/codeoutline_test.h') .. '#0', 'system include from includePaths')
            spec.equal(jump('csrc/main.c', 2, 12, { includePaths = { system } }), '', 'missing system header')
        end)
        assert(xutils.rmtree(nav_root .. '/mods')); assert(xutils.rmtree(nav_root .. '/pyp'))
        assert(xutils.rmtree(nav_root .. '/web')); assert(xutils.rmtree(nav_root .. '/csrc')); assert(xutils.rmtree(system))
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        if not ok then error(err, 0) end
    end)
    spec.it('validates includePaths and passes them with navigation requests', function()
        local jobs = {}
        local session = lsp.new({}, function() end, function(req, done)
            jobs[#jobs + 1] = req; return 'job' end, function() end, function() end)
        session:accept(xutils.json_pack({ jsonrpc = '2.0', id = 1, method = 'initialize', params = { rootUri = docs.uri(nav_root),
            capabilities = {}, initializationOptions = { includePaths = { 'C:/inc', '/usr/include' } } } }))
        session:accept(xutils.json_pack({ jsonrpc = '2.0', method = 'initialized', params = {} }))
        session.ready[nav_root] = true
        session:accept(xutils.json_pack({ jsonrpc = '2.0', id = 2, method = 'textDocument/definition', params = {
            textDocument = { uri = nav_uri('main.c') }, position = { line = 0, character = 0 } } }))
        spec.equal(table.concat(jobs[#jobs].includePaths, ','), 'C:/inc,/usr/include')
        local replies = {}
        local bad = lsp.new({}, function(msg) replies[#replies + 1] = msg end, fake_submit, function() end, function() end)
        bad:accept(xutils.json_pack({ jsonrpc = '2.0', id = 1, method = 'initialize', params = { capabilities = {},
            initializationOptions = { includePaths = { 1 } } } }))
        spec.equal(replies[1].error.code, -32602)
    end)
    spec.it('navigates shared emitter literal events and invalidates changed bus and event drafts', function()
        assert(xutils.mkdir_p(nav_root .. '/sharedEvents'))
        local bus = "import { EventEmitter } from 'node:events'; export const bus = new EventEmitter();\n"
        local sub = "import { bus } from './bus'; export function eventHandled() {} bus.on('saved', eventHandled);\n"
        local pub = "import { bus } from './bus';\nexport function eventPublish() { bus.emit('saved'); }\n"
        nav_write('sharedEvents/bus.ts', bus); nav_write('sharedEvents/sub.ts', sub); nav_write('sharedEvents/pub.ts', pub)
        local options = { cache_path = nav_root .. '/cache.idx', lister = 'walk' }
        service.refresh(nav_root, options)
        local uri = nav_uri('sharedEvents/pub.ts')
        local function jump(text, extra)
            local doc = docs.new(uri, text, 1, 'typescript')
            local req = { method = 'lsp_definition', uri = uri, session = 'shared-events',
                position = doc:position(assert(text:find('saved', 1, true)) - 1) }
            for k, v in pairs(extra or {}) do req[k] = v end
            return nav(req)
        end
        local ok, err = pcall(function()
            local found = jump(pub); spec.equal(#found, 1); spec.equal(found[1].uri, nav_uri('sharedEvents/sub.ts'))
            spec.equal(range_text('sharedEvents/sub.ts', found[1].range), 'eventHandled')
            local provider = nav_uri('sharedEvents/bus.ts')
            navigation.sync({ session = 'shared-events', open = { [provider] = 1 }, changed = {
                [provider] = { version = 1, language = 'typescript', source = 'export const bus = custom();\n' } } })
            spec.equal(#jump(pub), 0)
            navigation.close('shared-events'); spec.equal(#jump(pub), 1)
            local draft = pub:gsub("emit%('saved'%)", "emit('other')")
            navigation.sync({ session = 'shared-events', open = { [uri] = 1 }, changed = {
                [uri] = { version = 2, language = 'typescript', source = draft } } })
            -- Same byte offset, now a different event string.
            spec.equal(#jump(pub), 0)
        end)
        navigation.close('shared-events')
        assert(xutils.rmtree(nav_root .. '/sharedEvents')); service.refresh(nav_root, options)
        assert(ok, err)
    end)
    spec.it('navigates conditional macro declarations without weakening execution barriers', function()
        local source = [[void MACRO_NAV(int x);
#define MACRO_NAV(x) 0
void MacroNavUse(void) { MACRO_NAV(1); }
#undef MACRO_NAV
void MacroNavAfter(void) { MACRO_NAV(2); }
#if UNKNOWN_FLAG
#define MACRO_NAV(x) 1
#endif
void MacroNavUnknown(void) { MACRO_NAV(3); }
]]
        nav_write('macro-nav.c', source)
        service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
        local doc = assert(docs.read(nav_root .. '/macro-nav.c'))
        local function jump(value, session)
            return nav({ method = 'lsp_definition', session = session, uri = doc.uri,
                position = doc:position(assert(source:find(value, 1, true)) - 1) })
        end
        local found = jump('MACRO_NAV(1)'); spec.equal(#found, 1); spec.equal(found[1].range.start.line, 1)
        found = jump('MACRO_NAV(2)'); spec.equal(#found, 1); spec.equal(found[1].range.start.line, 0)
        found = jump('MACRO_NAV(3)'); spec.equal(#found, 1); spec.equal(found[1].range.start.line, 6)
        local V = navigation.view('spec', nav_root)
        local f = V.file_index['macro-nav.c']
        local ids, handled = require('codeoutline.cpp_macros').context(V, V.js_context).resolve(f, 'MACRO_NAV', 9)
        spec.equal(#ids, 0); spec.equal(handled, true, 'unknown branches must still block graph execution binding')
        navigation.sync({ session = 'macro-nav', open = { [doc.uri] = 1 }, changed = {
            [doc.uri] = { version = 1, language = 'c', source = source:gsub('#undef MACRO_NAV', '#define MACRO_NAV(x) 0') } } })
        found = jump('MACRO_NAV(2)', 'macro-nav'); spec.equal(#found, 1); spec.equal(found[1].range.start.line, 3)
        navigation.close('macro-nav')
    end)
    spec.it('returns macro definitions without API call sites and keeps undef and include barriers', function()
        for _, dir in ipairs({ 'macroDef1', 'macroDef2', 'macroDef3', 'macroDef4', 'macroUse' }) do assert(xutils.mkdir_p(nav_root .. '/' .. dir)) end
        for i = 1, 4 do nav_write('macroDef' .. i .. '/api.h', '#define MissingContextMacro(L,n) use_stack(L,n)\n') end
        local calls = {}
        for i = 1, 80 do calls[i] = 'void OtherMacroUse' .. i .. '() { MissingContextMacro(0,1); }\n' end
        nav_write('macroUse/calls.cpp', table.concat(calls))
        local source = 'void MissingContextUse() { MissingContextMacro(0,1); }\n'
        nav_write('macroUse/use.fragment', source)
        local options = { cache_path = nav_root .. '/cache.idx', lister = 'walk' }
        service.refresh(nav_root, options)
        local uri = nav_uri('macroUse/use.fragment')
        local function jump(text, extra, method)
            local doc = docs.new(uri, text, 1, 'cpp')
            navigation.sync({ session = 'missing-macro-context', open = { [uri] = 1 }, changed = {
                [uri] = { source = text, version = 1, language = 'cpp' } } })
            local req = { method = method or 'lsp_definition', session = 'missing-macro-context', uri = uri,
                position = doc:position(assert(text:find('MissingContextMacro(0', 1, true)) - 1) }
            for k,v in pairs(extra or {}) do req[k] = v end
            return nav(req)
        end
        local ok, err = pcall(function()
            local found, out = jump(source)
            spec.equal(#found, 4); spec.equal(out.incomplete, false)
            for _, target in ipairs(found) do
                spec.truthy(target.uri:find('/macroDef', 1, true)); spec.equal(target.range.start.line, 0)
            end
            spec.equal(#jump(source, nil, 'lsp_references'), 0, 'candidates cannot turn calls into definition sites or reference edges')
            spec.equal(#jump('#undef MissingContextMacro\n' .. source), 0)
            spec.equal(#jump('#if FLAG\n#undef MissingContextMacro\n#endif\n' .. source), 0)
            spec.equal(#jump(source, { includePaths = {} }), 4, 'an empty client path list is not an explicit project policy')
            spec.equal(#jump(source, { includePaths = { 'macroDef1' } }), 0, 'configured visibility cannot be bypassed')
            found = jump('#include "../macroDef1/api.h"\n' .. source)
            spec.equal(#found, 1); spec.equal(found[1].uri, nav_uri('macroDef1/api.h'))
            found = jump(source .. '#define MissingContextMacro(L,n) later(L,n)\n')
            for _, target in ipairs(found) do spec.truthy(target.uri ~= uri, 'the same-file definition after the call is excluded') end
        end)
        navigation.close('missing-macro-context')
        for _, dir in ipairs({ 'macroDef1', 'macroDef2', 'macroDef3', 'macroDef4', 'macroUse' }) do assert(xutils.rmtree(nav_root .. '/' .. dir)) end
        service.refresh(nav_root, options); assert(ok, err)
    end)
    spec.it('falls back to ordinary definitions after uncertain macros without leaking proxy macros or call edges', function()
        for _, dir in ipairs({ 'fallbackOne', 'fallbackTwo', 'fallbackOther', 'fallbackUse' }) do
            assert(xutils.mkdir_p(nav_root .. '/' .. dir))
        end
        nav_write('fallbackOne/api.h', 'void FallbackOrdinary();\nvoid FallbackDeclaration();\n')
        nav_write('fallbackTwo/api.h', 'void FallbackOrdinary();\nvoid FallbackDeclaration();\n')
        nav_write('fallbackOther/proxy.h', '#define FallbackOrdinary proxy->call\n#define FallbackDeclaration proxy->decl\n')
        nav_write('fallbackOther/body.c', 'void FallbackOrdinary() {}\nstatic void FallbackDeclaration() {}\n')
        local source = '#include <api.h>\nvoid FallbackCaller() { FallbackOrdinary(); FallbackDeclaration(); }\n'
        for _, extension in ipairs({ 'c', 'cpp' }) do nav_write('fallbackUse/use.' .. extension, source) end
        local options = { cache_path = nav_root .. '/cache.idx', lister = 'walk' }
        service.refresh(nav_root, options)
        local ok, err = pcall(function()
            for _, extension in ipairs({ 'c', 'cpp' }) do
                local doc = docs.read(nav_root .. '/fallbackUse/use.' .. extension)
                local function jump(name, extra)
                    local req = { method = 'lsp_definition', uri = doc.uri,
                        position = doc:position(assert(source:find(name .. '();', 1, true)) - 1) }
                    for k, v in pairs(extra or {}) do req[k] = v end
                    return nav(req)
                end
                local found, out = jump('FallbackOrdinary')
                spec.equal(#found, 1); spec.equal(out.incomplete, false)
                spec.equal(found[1].uri, nav_uri('fallbackOther/body.c'))
                spec.equal(range_text('fallbackOther/body.c', found[1].range), 'FallbackOrdinary')
                found = jump('FallbackDeclaration')
                spec.equal(#found, 2, 'keep declarations when no eligible implementation exists')
                spec.equal(found[1].uri, nav_uri('fallbackOne/api.h'))
                spec.equal(found[2].uri, nav_uri('fallbackTwo/api.h'))
                spec.equal(#jump('FallbackOrdinary', { method = 'lsp_references' }), 0)
                found = jump('FallbackDeclaration', { includePaths = { 'fallbackTwo' } })
                spec.equal(#found, 1, 'a configured visible declaration still resolves normally')
                found = jump('FallbackOrdinary', { includePaths = { 'missing-explicit-path' } })
                spec.equal(#found, 0, 'an explicit include policy must not be bypassed')
                local macros = require('codeoutline.cpp_macros')
                local before = macros.MAX_FILES; macros.MAX_FILES = 0
                local success, limited, response = pcall(jump, 'FallbackOrdinary')
                macros.MAX_FILES = before; assert(success, limited)
                spec.equal(#limited, 1); spec.equal(limited[1].uri, nav_uri('fallbackOther/body.c'))
                spec.equal(response.incomplete, true, 'tag fallback must preserve exhausted macro evidence')
            end
        end)
        for _, dir in ipairs({ 'fallbackOne', 'fallbackTwo', 'fallbackOther', 'fallbackUse' }) do
            assert(xutils.rmtree(nav_root .. '/' .. dir))
        end
        service.refresh(nav_root, options); assert(ok, err)
    end)
    spec.it('prefers actual implementations over repeated API declarations before limiting candidate sources', function()
        for _, dir in ipairs({ 'bodyOne', 'bodyTwo', 'bodyUse' }) do assert(xutils.mkdir_p(nav_root .. '/' .. dir)) end
        nav_write('bodyOne/api.c', 'int CandidateBodyFirst() { return 1; }\n')
        nav_write('bodyTwo/api.c', 'int CandidateBodyFirst() { return 2; }\n')
        for i = 1, 10 do nav_write('bodyUse/decl' .. i .. '.h', 'int CandidateBodyFirst();\n') end
        nav_write('bodyUse/use.cpp', 'int BodyUse() { return CandidateBodyFirst(); }\n')
        local options = { cache_path = nav_root .. '/cache.idx', lister = 'walk' }
        service.refresh(nav_root, options)
        local ok, err = pcall(function()
            local found, out = nav({ method = 'lsp_definition', uri = nav_uri('bodyUse/use.cpp'), position = { line = 0, character = 26 } })
            spec.equal(#found, 2); spec.equal(out.incomplete, false)
            spec.equal(found[1].uri, nav_uri('bodyOne/api.c')); spec.equal(found[2].uri, nav_uri('bodyTwo/api.c'))
        end)
        for _, dir in ipairs({ 'bodyOne', 'bodyTwo', 'bodyUse' }) do assert(xutils.rmtree(nav_root .. '/' .. dir)) end
        service.refresh(nav_root, options); assert(ok, err)
    end)
    spec.it('navigates proxy macros in ambiguous headers without asserting execution targets', function()
        for _, dir in ipairs({ 'proxyOne', 'proxyTwo', 'proxyUse' }) do assert(xutils.mkdir_p(nav_root .. '/' .. dir)) end
        local options = { cache_path = nav_root .. '/cache.idx', lister = 'walk' }
        local header = '#ifndef PROXY_API_H\n#define PROXY_API_H\n'
            .. '#define PROXY_NAV __proxy__(PROXY_NAV)\n#if 0\n#define PROXY_NAV hidden\n#endif\n#endif\n'
        nav_write('proxyOne/api.h', header)
        nav_write('proxyTwo/api.h', header)
        local source = '#include <api.h>\nvoid ProxyUse() { PROXY_NAV(1); }\n'
            .. '#undef PROXY_NAV\nvoid ProxyAfter() { PROXY_NAV(2); }\n'
            .. '#define PROXY_NAV current\nvoid ProxyNew() { PROXY_NAV(3); }\n'
        nav_write('proxyUse/main.cpp', source)
        service.refresh(nav_root, options)
        local doc = assert(docs.read(nav_root .. '/proxyUse/main.cpp'))
        local function jump(value, extra)
            local req = { method = 'lsp_definition', uri = doc.uri,
                position = doc:position(assert(source:find(value, 1, true)) - 1) }
            for k, v in pairs(extra or {}) do req[k] = v end
            return nav(req)
        end
        local ok, err = pcall(function()
            local found = jump('PROXY_NAV(1)')
            spec.equal(#found, 2, 'both alternative headers survive their shared include guard')
            spec.equal(found[1].uri, nav_uri('proxyOne/api.h')); spec.equal(found[2].uri, nav_uri('proxyTwo/api.h'))
            for _, loc in ipairs(found) do spec.equal(loc.range.start.line, 2) end
            local V = navigation.view('spec', nav_root)
            local f = V.file_index['proxyUse/main.cpp']
            local C = require('codeoutline.cpp_macros').context(V, V.js_context)
            local ids, handled, sites = C.resolve(f, 'PROXY_NAV', 2)
            spec.equal(#ids, 0); spec.equal(handled, true); spec.equal(#sites, 0)
            ids, handled, sites = C.resolve(f, 'PROXY_NAV', 2, true)
            spec.equal(#ids, 0); spec.equal(handled, true); spec.equal(#sites, 2)
            ids, handled, sites = C.resolve(f, 'PROXY_NAV', 2)
            spec.equal(#ids, 0); spec.equal(#sites, 0, 'navigation alternatives cannot pollute graph results')
            found = jump('PROXY_NAV(1)', { includePaths = { 'proxyTwo', 'proxyOne' } })
            spec.equal(#found, 1); spec.equal(found[1].uri, nav_uri('proxyTwo/api.h'))
            spec.equal(#jump('PROXY_NAV(1)', { includePaths = {} }), 2)
            spec.equal(#jump('PROXY_NAV(2)'), 0, 'a later undef clears the alternatives')
            found = jump('PROXY_NAV(3)'); spec.equal(#found, 1); spec.equal(found[1].uri, doc.uri)
            spec.equal(found[1].range.start.line, 4)
            local macros = require('codeoutline.cpp_macros')
            local before = macros.MAX_FILES; macros.MAX_FILES = 2
            local bounded = navigation.view('spec', nav_root)
            local limited = macros.context(bounded, bounded.js_context)
            local success, _, _, partial = pcall(limited.resolve, bounded.file_index['proxyUse/main.cpp'], 'PROXY_NAV', 2, true)
            macros.MAX_FILES = before
            spec.truthy(success); spec.truthy(limited.incomplete)
            spec.equal(#partial, 0, 'a budget failure must not publish a partial alternative list')
        end)
        for _, dir in ipairs({ 'proxyOne', 'proxyTwo', 'proxyUse' }) do assert(xutils.rmtree(nav_root .. '/' .. dir)) end
        service.refresh(nav_root, options); assert(ok, err)
    end)
    spec.it('shares scoped include order across header jumps, definitions, implementations, completion and drafts', function()
        for _, dir in ipairs({ 'searchOne', 'searchTwo', 'searchUse' }) do assert(xutils.mkdir_p(nav_root .. '/' .. dir)) end
        for _, name in ipairs({ 'One', 'Two' }) do
            nav_write('search' .. name .. '/api.hpp', 'namespace IncludeSearch { struct Base { virtual void save(int) = 0; }; '
                .. 'struct Store { void only' .. name .. '() {} void out' .. name .. '(); void shared(); }; }')
            nav_write('search' .. name .. '/impl.cpp', '#include "api.hpp"\nstruct IncludeSearch' .. name
                .. ' : IncludeSearch::Base { void save(int) {} };\nvoid IncludeSearch::Store::out' .. name
                .. '() {}\nvoid IncludeSearch::Store::shared() {}')
        end
        local source = '#include <api.hpp>\nvoid IncludeSearchUse(IncludeSearch::Base *p, IncludeSearch::Store *s) { p->save(1); s->onlyOne(); }'
        nav_write('searchUse/main.cpp', source)
        local config_path = nav_root .. '/.codeoutline.json'
        local options = { cache_path = nav_root .. '/cache.idx', lister = 'walk' }
        local function configure(name)
            nav_write('.codeoutline.json', xutils.json_pack({ includePathRules = {
                { directory = 'searchUse', paths = { 'search' .. name } } } }))
        end
        configure('One'); service.refresh(nav_root, options)
        local idx = service.resident(nav_root); idx:save(); service.forget(nav_root); service.refresh(nav_root, options)
        local doc = docs.read(nav_root .. '/searchUse/main.cpp')
        local function query(method, offset, extra)
            local req = { method = method, session = 'include-search', uri = doc.uri, position = doc:position(offset) }
            for k, v in pairs(extra or {}) do req[k] = v end
            return nav(req)
        end
        local ok, err = pcall(function()
            for _, name in ipairs({ 'One', 'Two' }) do
                configure(name)
                local header = query('lsp_definition', (assert(source:find('api.hpp', 1, true))))
                spec.equal(#header, 1); spec.equal(header[1].uri, nav_uri('search' .. name .. '/api.hpp'))
                local definition = query('lsp_definition', (assert(source:find('save', 1, true))))
                spec.equal(#definition, 1); spec.equal(definition[1].uri, header[1].uri)
                local implementation = query('lsp_implementation', (assert(source:find('save', 1, true))))
                spec.equal(#implementation, 1); spec.equal(implementation[1].uri, nav_uri('search' .. name .. '/impl.cpp'))
                local labels = {}
                for _, item in ipairs(require('codeoutline.completion').complete({ uri = doc.uri, root = nav_root,
                    session = 'include-search', position = doc:position(assert(source:find('s->', 1, true)) + 2) }).items) do
                    labels[item.label] = true
                end
                spec.truthy(labels['only' .. name]); spec.nil_value(labels['only' .. (name == 'One' and 'Two' or 'One')])
                spec.truthy(labels['out' .. name]); spec.nil_value(labels['out' .. (name == 'One' and 'Two' or 'One')])
                local declaration = docs.read(nav_root .. '/search' .. name .. '/api.hpp')
                local bodies = nav({ method = 'lsp_definition', session = 'include-search', uri = declaration.uri,
                    position = declaration:position(assert(declaration.source:find('shared', 1, true))) })
                spec.equal(#bodies, 1); spec.equal(bodies[1].uri, nav_uri('search' .. name .. '/impl.cpp'))
            end
            os.remove(config_path)
            local from_client = query('lsp_definition', assert(source:find('save', 1, true)), { includePaths = { 'searchOne' } })
            spec.equal(#from_client, 1); spec.equal(from_client[1].uri, nav_uri('searchOne/api.hpp'))
            configure('One')
            local edited = source:gsub('<api.hpp>', '"../searchTwo/api.hpp"')
            navigation.sync({ session = 'include-search', open = { [doc.uri] = 1 }, changed = {
                [doc.uri] = { version = 1, language = 'cpp', source = edited } } })
            local draft = docs.new(doc.uri, edited, 1, 'cpp')
            local changed = nav({ method = 'lsp_implementation', session = 'include-search', uri = doc.uri,
                position = draft:position(assert(edited:find('save', 1, true))) })
            spec.equal(#changed, 1); spec.equal(changed[1].uri, nav_uri('searchTwo/impl.cpp'))
            spec.nil_value(service.resident(nav_root):symbols().cpp_includes)
        end)
        navigation.close('include-search'); os.remove(config_path)
        for _, dir in ipairs({ 'searchOne', 'searchTwo', 'searchUse' }) do assert(xutils.rmtree(nav_root .. '/' .. dir)) end
        service.refresh(nav_root, options); assert(ok, err)
    end)
    spec.it('keeps configured C prototype navigation and references inside the selected header project', function()
        for _, dir in ipairs({ 'cSearchOne', 'cSearchTwo', 'cSearchUse' }) do assert(xutils.mkdir_p(nav_root .. '/' .. dir)) end
        for _, name in ipairs({ 'One', 'Two' }) do
            nav_write('cSearch' .. name .. '/api.h', 'int include_search_c(void);')
            nav_write('cSearch' .. name .. '/api.c', '#include "api.h"\nint include_search_c(void) { return 1; }')
        end
        local source = '#include <api.h>\nvoid IncludeSearchCUse(void) { include_search_c(); }'
        nav_write('cSearchUse/main.c', source)
        nav_write('.codeoutline.json', '{"includePaths":["cSearchOne"]}')
        local options = { cache_path = nav_root .. '/cache.idx', lister = 'walk' }
        service.refresh(nav_root, options)
        local ok, err = pcall(function()
            local header = docs.read(nav_root .. '/cSearchOne/api.h')
            local body = nav({ method = 'lsp_definition', uri = header.uri,
                position = header:position(assert(header.source:find('include_search_c', 1, true))) })
            spec.equal(#body, 1); spec.equal(body[1].uri, nav_uri('cSearchOne/api.c'))
            local doc = docs.read(nav_root .. '/cSearchUse/main.c')
            local result = nav({ method = 'lsp_references', uri = doc.uri,
                position = doc:position(assert(source:find('include_search_c', 1, true))), includeDeclaration = true })
            spec.truthy(#result > 0)
            for _, location in ipairs(result) do spec.truthy(not location.uri:find('/cSearchTwo/', 1, true)) end
        end)
        os.remove(nav_root .. '/.codeoutline.json')
        for _, dir in ipairs({ 'cSearchOne', 'cSearchTwo', 'cSearchUse' }) do assert(xutils.rmtree(nav_root .. '/' .. dir)) end
        service.refresh(nav_root, options); assert(ok, err)
    end)
    spec.it('opens a configured external header without binding indexed same-name symbols', function()
        local external = nav_root .. '-external-includes'
        assert(xutils.mkdir_p(external)); assert(xutils.mkdir_p(nav_root .. '/externalSearch'))
        local f = assert(io.open(external .. '/external_api.hpp', 'wb'))
        f:write('namespace ExternalInclude { struct Store { void save() {} }; }'); f:close()
        nav_write('externalSearch/external_api.hpp', 'namespace ExternalInclude { struct Store { void save() {} }; }')
        local source = '#include <external_api.hpp>\nvoid ExternalIncludeUse(ExternalInclude::Store *p) { p->save(); }'
        nav_write('externalSearch/main.cpp', source)
        local options = { cache_path = nav_root .. '/cache.idx', lister = 'walk' }
        service.refresh(nav_root, options)
        local doc = docs.read(nav_root .. '/externalSearch/main.cpp')
        local ok, err = pcall(function()
            local header = nav({ method = 'lsp_definition', uri = doc.uri, includePaths = { external },
                position = doc:position(assert(source:find('external_api.hpp', 1, true))) })
            spec.equal(#header, 1); spec.equal(header[1].uri, docs.uri(external .. '/external_api.hpp'))
            local definition = nav({ method = 'lsp_definition', uri = doc.uri, includePaths = { external },
                position = doc:position(assert(source:find('save', 1, true))) })
            spec.equal(#definition, 0)
        end)
        assert(xutils.rmtree(external)); assert(xutils.rmtree(nav_root .. '/externalSearch'))
        service.refresh(nav_root, options); assert(ok, err)
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
    spec.it('does not leak outer signature help into Lua callback bodies', function()
        local header = 'local function signature_start(callback, rest) end\nlocal function signature_inner(value) end\n'
        local cases = {
            { 'signature_start(function() ', false },
            { 'signature_start(function() local a, b = 1, 2; ', false },
            { 'signature_start(function() if true then ', false },
            { 'signature_start(function() if true then signature_inner(1) end; ', false },
            { 'signature_start(function() local function nested() ', false },
            { 'signature_start(function() signature_inner(', 'signature_inner', 0 },
            { 'signature_start(function() signature_inner(1) ', false },
            { 'signature_start(function() if true then signature_inner(1) end end, ', 'signature_start', 1 },
        }
        for _, case in ipairs(cases) do
            local source = header .. case[1]
            nav_write('signature_callback.lua', source)
            service.refresh(nav_root, { cache_path = nav_root .. '/cache.idx', lister = 'walk' })
            local doc = docs.read(nav_root .. '/signature_callback.lua')
            local out = nav({ method = 'lsp_signature', uri = doc.uri, position = doc:position(#source) })
            if case[2] == false then spec.equal(out, false, case[1])
            else
                spec.contains(out.signatures[1].label, case[2])
                spec.equal(out.activeParameter, case[3], case[1])
            end
        end
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
        spec.contains(refused.error, 'Type references')
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

local function session_with(submit, init, cancel)
    local output = {}
    local session = lsp.new({}, function(msg) output[#output + 1] = msg end, submit, cancel or function() end, function() end)
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
    spec.it('coalesces idle file warming and cancels it before capturing foreground drafts', function()
        local clock, now = xtimer.now_ms, 100
        xtimer.now_ms = function() return now end
        local ok, err = pcall(function()
            local jobs, cancelled = {}, {}
            local session, send, output = session_with(function(req, done)
                jobs[#jobs + 1] = { req = req, done = done }; return tostring(#jobs)
            end, nil, function(id) cancelled[id] = true end)
            jobs[1].done(true, true)
            local first, second = nav_uri('WarmFirst.lua'), nav_uri('WarmSecond.lua')
            for _, uri in ipairs({ first, second }) do
                send('textDocument/didOpen', { textDocument = { uri = uri, languageId = 'lua', version = 1,
                    text = 'function warm_idle() end\n' } })
            end
            now = 249; session:poll(); spec.equal(#jobs, 1)
            now = 250; session:poll(); spec.equal(#jobs, 2)
            spec.equal(jobs[2].req.method, 'lsp_warm'); spec.equal(jobs[2].req.uri, second)
            spec.nil_value(jobs[2].req.changed[first], 'idle submission only transfers its selected draft')
            send('textDocument/documentSymbol', { textDocument = { uri = second } }, 19)
            send('codeoutline/visibleDocument', { textDocument = { uri = second, version = 1 } })
            spec.nil_value(cancelled['2']); session:poll(); spec.equal(#jobs, 2)
            send('textDocument/definition', { textDocument = { uri = second }, position = { line = 0, character = 10 } }, 20)
            spec.truthy(cancelled['2']); spec.equal(#jobs, 3)
            spec.truthy(jobs[3].req.changed[first]); spec.truthy(jobs[3].req.changed[second])
            jobs[2].done(true, { result = { files = 1 } })
            jobs[3].done(true, { result = {} }); spec.equal(output[#output].id, 20)
            send('codeoutline/visibleDocument', { textDocument = { uri = first, version = 1 } })
            now = 400; session:poll(); spec.equal(jobs[4].req.uri, first)
            send('textDocument/didClose', { textDocument = { uri = first } })
            spec.truthy(cancelled['4']); jobs[4].done(true, {})
            send('textDocument/didChange', { textDocument = { uri = second, version = 2 },
                contentChanges = { { text = 'function edited_idle() end\n' } } })
            now = 899; session:poll(); spec.equal(#jobs, 4)
            now = 900; session:poll(); spec.equal(jobs[5].req.changed[second].version, 2)
            send('textDocument/didChange', { textDocument = { uri = second, version = 3 },
                contentChanges = { { text = 'function latest_idle() end\n' } } })
            spec.truthy(cancelled['5']); jobs[5].done(true, {})
            now = 1400; session:poll(); spec.equal(jobs[6].req.changed[second].version, 3)
            local replies = #output
            jobs[6].done(false, 'idle deadline'); spec.equal(#output, replies)
            send('textDocument/definition', { textDocument = { uri = second }, position = { line = 0, character = 10 } }, 21)
            spec.equal(jobs[7].req.changed[second].version, 3)
            jobs[7].done(true, { result = {} }); spec.equal(output[#output].id, 21)
            session:close()
        end)
        xtimer.now_ms = clock
        if not ok then error(err, 0) end
    end)
    spec.it('skips idle warming for auxiliary sessions and oversized documents', function()
        local clock, now = xtimer.now_ms, 100
        xtimer.now_ms = function() return now end
        local ok, err = pcall(function()
            for _, auxiliary in ipairs({ true, false }) do
                local jobs = {}
                local features = {}
                for _, name in ipairs(lsp.FEATURES) do features[name] = not auxiliary or name == 'workspaceSymbol' end
                local session, send = session_with(function(req, done)
                    jobs[#jobs + 1] = { req = req, done = done }; return tostring(#jobs)
                end, { initializationOptions = { features = features } })
                jobs[1].done(true, true)
                local uri = nav_uri('WarmSkipped.lua')
                send('textDocument/didOpen', { textDocument = { uri = uri, languageId = 'lua', version = 1,
                    text = auxiliary and 'function unused_idle() end' or '--' .. string.rep('x', 1048576) } })
                now = now + 150; session:poll(); spec.equal(#jobs, 1)
                session:close()
            end
        end)
        xtimer.now_ms = clock
        if not ok then error(err, 0) end
    end)
    spec.it('shares in-flight identifier navigation and keeps cancellation per request', function()
        local jobs, cancelled = {}, {}
        local session, send, output = session_with(function(req, done)
            if req.method == 'lsp_refresh' then return 'scan' end
            jobs[#jobs + 1] = { req = req, done = done }; return 'job' .. #jobs
        end, nil, function(id) cancelled[#cancelled + 1] = id end)
        local uri = nav_uri('m.lua')
        send('textDocument/didOpen', { textDocument = { uri = uri, languageId = 'lua', version = 1, text = 'shared_symbol()' } })
        local function definition(id, character)
            send('textDocument/definition', { textDocument = { uri = uri }, position = { line = 0, character = character } }, id)
        end
        definition(2, 0); definition(3, 3); definition(4, 8)
        spec.equal(#jobs, 1)
        send('$/cancelRequest', { id = 2 }) -- Cancelling the transport owner must not cancel its followers.
        spec.equal(#cancelled, 0)
        jobs[1].done(true, { result = {}, incomplete = false })
        local replies = {}
        for _, msg in ipairs(output) do if msg.id then replies[msg.id] = msg end end
        spec.equal(replies[2].error.code, -32800)
        spec.equal(#replies[3].result, 0); spec.equal(#replies[4].result, 0)
        spec.equal(next(session.pending), nil)
        definition(5, 0); definition(6, 2)
        spec.equal(#jobs, 2, 'completed results are never reused')
        send('$/cancelRequest', { id = 6 }); spec.equal(#cancelled, 0)
        send('$/cancelRequest', { id = 5 }); spec.equal(cancelled[1], 'job2')
        definition(7, 0); spec.equal(#jobs, 3, 'a cancelled flight must not capture new requests')
        jobs[2].done(false, 'cancelled')
        jobs[3].done(true, { result = {}, incomplete = false })
        spec.equal(next(session.pending), nil)
    end)
    spec.it('separates navigation by document changes, method and reference options', function()
        local jobs = {}
        local session, send, output = session_with(function(req, done)
            if req.method == 'lsp_refresh' then return 'scan' end
            jobs[#jobs + 1] = { req = req, done = done }; return 'job' .. #jobs
        end)
        local uri = nav_uri('m.lua')
        send('textDocument/didOpen', { textDocument = { uri = uri, languageId = 'lua', version = 1, text = 'shared_symbol()' } })
        local params = { textDocument = { uri = uri }, position = { line = 0, character = 0 } }
        send('textDocument/definition', params, 2)
        send('textDocument/hover', params, 3)
        send('textDocument/references', params, 4)
        send('textDocument/references', { textDocument = params.textDocument, position = params.position,
            context = { includeDeclaration = true } }, 5)
        spec.equal(#jobs, 4)
        send('textDocument/didChange', { textDocument = { uri = uri, version = 2 }, contentChanges = { { text = 'changed_symbol()' } } })
        send('textDocument/definition', params, 6)
        spec.equal(#jobs, 5)
        send('textDocument/definition', params, 7); spec.equal(#jobs, 5)
        jobs[5].done(false, 'query failed')
        local errors = {}
        for _, msg in ipairs(output) do if msg.error then errors[msg.id] = msg.error.message end end
        spec.equal(errors[6], 'query failed'); spec.equal(errors[7], 'query failed')
        for i = 1, 4 do jobs[i].done(true, { result = {}, incomplete = false }) end
        spec.equal(next(session.pending), nil)
    end)
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
        done_with.lsp_definition = { result = {}, incomplete = true }
        warned = #replies
        send('textDocument/definition', position, 7)
        spec.contains(replies[warned + 1], 'definition lookup')
        spec.equal(replies[warned + 1]:find('too many matching references', 1, true), nil)
        done_with.lsp_references = { result = {}, incomplete = true }
        warned = #replies
        send('textDocument/references', position, 8)
        spec.contains(replies[warned + 1], 'too many matching references')
    end)
    spec.it('applies drafts in the worker even when the request is cancelled', function()
        local saved = { xthread = xthread, xshared = xshared, replys = _thread_replys }
        local ok, err = pcall(function()
            local results = {}
            local flags = { ['cancel:nav-cancelled'] = true }
            xshared = { dict = function() return {
                get = function(_, key) return flags[key] end,
                delete = function(_, key) flags[key] = nil end } end }
            xthread = { post = function(_, _, id, success, result) results[id] = { ok = success, result = result }; return true end }
            _thread_replys = { ['xthread:1'] = function(co, sk, method, success, result)
                spec.equal(co, 123); spec.equal(sk, 0); spec.equal(method, 'run_rpc')
                results['nav-cancelled'] = { ok = success, result = result }
                return true
            end }
            local worker = dofile('scripts/codeoutline/index_worker.lua')
            local lua = nav_uri('m.lua')
            local base = { method = 'lsp_definition', session = 'worker', root = nav_root, uri = lua,
                position = { line = 0, character = 24 }, deadline = xtimer.now_ms() + 10000 }
            local first = {}
            for k, v in pairs(base) do first[k] = v end
            first.open = { [lua] = 2 }
            first.changed = { [lua] = { version = 2, language = 'lua',
                source = 'function M_go() return renamed() end\nfunction renamed() return 1 end\n' } }
            worker.__thread_handle('xthread:1', 123, 0, 'run_rpc', 'nav-cancelled', first)
            spec.equal(results['nav-cancelled'].ok, false)
            base.open, base.changed = { [lua] = 2 }, {}
            worker.__thread_handle(1, 'run', 'nav-next', base)
            spec.truthy(results['nav-next'].ok, tostring(results['nav-next'].result))
            spec.equal(results['nav-next'].result.result[1].range.start.line, 1)
            worker.__thread_handle(1, 'run', 'nav-close', { method = 'lsp_close', session = 'worker',
                deadline = xtimer.now_ms() + 10000, projectPath = nav_root, allowedRoots = { nav_root } })
            spec.truthy(results['nav-close'].ok)
        end)
        xthread, xshared, _thread_replys = saved.xthread, saved.xshared, saved.replys
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
    ['KBox.kt'] = 'package model\nclass KBox(val width: Int) { fun next(): KBox = this }\n',
    ['KUse.kt'] = 'package model\nfun use(box: KBox) { box.@@; val x = KBox(1); x.next().@@ }\n',
    ['KAlias.kt'] = 'package client\nimport model.KBox as Alias\nfun use() { val x: Alias = Alias(1); x.@@ }\n',
    ['KExtension.kt'] = 'package model\nfun KBox.inspect() { this.@@ }\n',
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
    ['pool.c'] = '#define POOL_META "demo.pool"\n'
        .. 'static int pool_get(lua_State *L) { luaL_checkinteger(L, 2); return 0; }\n'
        .. 'static int push_pool(lua_State *L) { lua_newuserdata(L, 8); luaL_setmetatable(L, POOL_META); return 1; }\n'
        .. 'static int pool_open(lua_State *L) { return push_pool(L); }\n'
        .. 'static const luaL_Reg pool_methods[] = {{"get", pool_get}, {NULL, NULL}};\n'
        .. 'static const luaL_Reg pool_funcs[] = {{"open", pool_open}, {NULL, NULL}};\n'
        .. 'int luaopen_pool(lua_State *L) {\n'
        .. '  luaL_newmetatable(L, POOL_META);\n  luaL_setfuncs(L, pool_methods, 0);\n  lua_pop(L, 1);\n'
        .. '  luaL_newlib(L, pool_funcs);\n  return 1;\n}\n',
    ['core/pool.lua'] = 'local p = pool.open()\nreturn p.@@ + p:@@\n',
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
        { 'KUse.kt', 1, 'next,width', 'Kotlin typed parameters and constructor properties' },
        { 'KUse.kt', 2, 'next,width', 'Kotlin val constructors and return type chains' },
        { 'KAlias.kt', 1, 'next,width', 'Kotlin imported type aliases' },
        { 'KExtension.kt', 1, 'next,width', 'Kotlin explicit extension receivers' },
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
        { 'core/pool.lua', 1, 'get', 'Lua local typed by the metatable a C call returns' },
        { 'core/pool.lua', 2, 'get', 'Lua colon call on a native object' },
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
    spec.it('advertises method implementations and honours its feature switch', function()
        local session, output = comp_session()
        spec.truthy(output[1].result.capabilities.implementationProvider)
        session:accept(xutils.json_pack({ jsonrpc = '2.0', id = 2, method = 'textDocument/implementation', params = {
            textDocument = { uri = docs.uri(comp_root .. '/box.cpp') }, position = { line = 0, character = 0 } } }))
        spec.equal(output.request.method, 'lsp_implementation')
        local disabled, messages = comp_session({ features = { implementation = false } })
        spec.nil_value(messages[1].result.capabilities.implementationProvider)
        disabled:accept(xutils.json_pack({ jsonrpc = '2.0', id = 2, method = 'textDocument/implementation', params = {
            textDocument = { uri = docs.uri(comp_root .. '/box.cpp') }, position = { line = 0, character = 0 } } }))
        spec.equal(messages[#messages].error.code, -32601)
    end)
    spec.it('advertises and dispatches signature help with an independent feature switch', function()
        local session, output = comp_session()
        local provider = output[1].result.capabilities.signatureHelpProvider
        spec.equal(table.concat(provider.triggerCharacters, ''), '(,')
        session:accept(xutils.json_pack({ jsonrpc = '2.0', id = 2, method = 'textDocument/signatureHelp', params = {
            textDocument = { uri = docs.uri(comp_root .. '/p.c') }, position = { line = 3, character = 12 } } }))
        spec.equal(output.request.method, 'lsp_signature')
        local disabled, messages = comp_session({ features = { signatureHelp = false } })
        spec.equal(messages[1].result.capabilities.signatureHelpProvider, nil)
        disabled:accept(xutils.json_pack({ jsonrpc = '2.0', id = 2, method = 'textDocument/signatureHelp', params = {
            textDocument = { uri = docs.uri(comp_root .. '/p.c') }, position = { line = 3, character = 12 } } }))
        spec.equal(messages[#messages].error.code, -32601)
    end)
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
