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
            for key, column in pairs(rec.refs) do
                spec.equal(#compact.refs[key], #column)
                for i, value in ipairs(column) do spec.equal(compact.refs[key][i], value) end
            end
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
    spec.it('rolls back a refresh interrupted during graph construction', function()
        local idx, G = service.get(root, opts)
        local rec, generation = idx.files['a.lua'], idx.generation
        write(root .. '/a.lua', 'function renamed() end\n')
        local build = graph.build
        graph.build = function() error(control.cancelled(), 0) end
        local ok, err = pcall(service.get, root, opts)
        graph.build = build
        spec.equal(ok, false); spec.equal(err.code, 'cancelled')
        spec.equal(idx.files['a.lua'], rec); spec.equal(idx.generation, generation)
        local still, refreshed = service.get(root, opts)
        spec.equal(still, idx); spec.truthy(refreshed ~= G)
        spec.truthy(refreshed.by_name.renamed)
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

spec.describe('LSP sessions', function()
    spec.it('handles progress responses independently from client request IDs', function()
        local output = {}
        local session = lsp.new({}, function(msg) output[#output + 1] = msg end, function() end, function() end)
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
            return lsp.new({}, function(msg) output[#output + 1] = msg end, function() end, function() end)
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

service.forget(root)
assert(xutils.rmtree(root))
local failed = spec.finish()
return { __init = function() xthread.stop(failed > 0 and 1 or 0) end, __thread_handle = function() end }
