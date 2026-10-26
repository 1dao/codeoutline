package.path = 'scripts/?.lua;' .. package.path
local spec = dofile('tests/lua/spec_helper.lua')
local parse, graph = require('codeoutline.parse'), require('codeoutline.graph')
local headers, paths = require('codeoutline.external_headers'), require('codeoutline.path')
local root = assert(xutils.temp_file(os.getenv('TEMP') or '/tmp')):gsub('\\', '/')
os.remove(root); assert(xutils.mkdir_p(root)); root = assert(paths.canonical(root))
local sdk = root .. '-sdk'; assert(xutils.mkdir_p(sdk))
local function write(file, source)
    assert(xutils.mkdir_p(file:match('^(.*)/[^/]+$')))
    local f = assert(io.open(file, 'wb')); f:write(source); f:close()
end
local function project(source)
    local rec = parse.parse('app.c', source, { ranges = false })
    local G = graph.build({ root = root, files = { ['app.c'] = rec } })
    return G, G.file_index['app.c']
end
local function site(name, extra)
    local value = { name = name, kind = 'call', reason = 'no indexed target', line = 20 }
    for key, v in pairs(extra or {}) do value[key] = v end
    return value
end
spec.describe('on-demand external header declarations', function()
    spec.it('follows forwarding headers and returns exact declaration ranges without extending the graph', function()
        write(sdk .. '/stdlib.h', '#include "detail/alloc.h"\n')
        write(sdk .. '/detail/alloc.h', '/* 😀 */\nvoid free(void* pointer);\n')
        local G, f = project('#include <stdlib.h>\nvoid run(void* p) { free(p); }\n')
        local original, count = parse.parse, 0
        parse.parse = function(...) count = count + 1; return original(...) end
        local ok, err = pcall(function()
            for round = 1, 2 do
                local found = headers.find(G, f, site('free'), { include_paths = { sdk } })
                spec.equal(#found, 1)
                spec.equal(found[1].file, sdk .. '/detail/alloc.h')
                spec.equal(found[1].source:sub(found[1].node.name_start + 1, found[1].node.name_end), 'free')
                spec.truthy(found[1].declaration)
            end
            spec.equal(count, 1, 'cached declarations must not reparse on repeated queries')
            spec.equal(#G.file_order, 1); spec.equal(G.by_name.free, nil)
        end)
        parse.parse = original
        if not ok then error(err, 0) end
    end)
    spec.it('invalidates cached declarations after same-size header edits', function()
        local G, f = project('#include <stdlib.h>\nvoid run(void* p) { free(p); }\n')
        write(sdk .. '/detail/alloc.h', 'void free(void* pointer);\n')
        spec.equal(#headers.find(G, f, site('free'), { include_paths = { sdk } }), 1)
        write(sdk .. '/detail/alloc.h', 'void fr_e(void* pointer);\n')
        spec.equal(#headers.find(G, f, site('free'), { include_paths = { sdk } }), 0)
    end)
    spec.it('keeps the first selected header authoritative and tolerates empty headers', function()
        local other = sdk .. '/other'; write(other .. '/stdlib.h', 'void free(void* pointer);\n')
        write(sdk .. '/stdlib.h', '')
        local G, f = project('#include <stdlib.h>\nvoid run(void* p) { free(p); }\n')
        spec.equal(#headers.find(G, f, site('free'), { include_paths = { sdk, other } }), 0)
        spec.equal(#headers.find(G, f, site('free'), { include_paths = { other, sdk } }), 1)
    end)
    spec.it('requires a reachable include and respects configured misses and binding barriers', function()
        local G, f = project('void run(void* p) { free(p); }\n')
        spec.equal(#headers.find(G, f, site('free'), {}, { sdk .. '/other' }), 0)
        G, f = project('#include <stdlib.h>\nvoid run(void* p) { free(p); }\n')
        spec.equal(#headers.find(G, f, site('free'), { include_paths = { root .. '/missing' } }, { sdk .. '/other' }), 0)
        spec.equal(#headers.find(G, f, site('free', { evidence = 'cpp:?' }), { include_paths = { sdk .. '/other' } }), 0)
        spec.equal(#headers.find(G, f, site('free', { recv = 'object' }), { include_paths = { sdk .. '/other' } }), 0)
    end)
    spec.it('does not turn comments, calls or class members into global declarations', function()
        write(sdk .. '/fake.h', '/* void fake_api(); */\n'
            .. 'struct Box { void fake_api(); };\nvoid wrapper() { fake_api(); }\n')
        local G, f = project('#include <fake.h>\nvoid run() { fake_api(); }\n')
        spec.equal(#headers.find(G, f, site('fake_api'), { include_paths = { sdk } }), 0)
    end)
    spec.it('honors quoted relative includes, cycles and file budgets', function()
        write(sdk .. '/entry.h', '#include "entry.h"\n#include "nested/leaf.h"\n')
        write(sdk .. '/nested/leaf.h', 'void bounded_api();\n')
        local G, f = project('#include <entry.h>\nvoid run() { bounded_api(); }\n')
        spec.equal(#headers.find(G, f, site('bounded_api'), { include_paths = { sdk } }), 1)
        local old = headers.MAX_FILES; headers.MAX_FILES = 1
        local ok, found, info = pcall(headers.find, G, f, site('bounded_api'), { include_paths = { sdk } })
        headers.MAX_FILES = old
        spec.truthy(ok, found); spec.equal(#found, 0); spec.equal(info.truncated, true)
    end)
    spec.it('does not follow quoted traversal outside the include roots', function()
        write(root .. '/outside.h', 'void outside_api();\n')
        write(sdk .. '/traversal.h', '#include "../' .. root:match('([^/]+)$') .. '/outside.h"\n')
        local G, f = project('#include <traversal.h>\nvoid run() { outside_api(); }\n')
        spec.equal(#headers.find(G, f, site('outside_api'), { include_paths = { sdk } }), 0)
    end)
    spec.it('preserves cancellation identity', function()
        local control = require('codeoutline.control')
        local G, f = project('#include <entry.h>\nvoid run() { bounded_api(); }\n')
        control.callback = function() error(control.cancelled(), 0) end
        local ok, err = pcall(headers.find, G, f, site('bounded_api'), { include_paths = { sdk } })
        control.callback = nil
        spec.equal(ok, false); spec.truthy(control.is_interrupted(err))
    end)
end)
return { __init = function()
    xutils.rmtree(root); xutils.rmtree(sdk)
    if spec.finish() > 0 then os.exit(1) end
    xthread.stop(0)
end }
