package.path = 'scripts/?.lua;' .. package.path
local spec = dofile('tests/lua/spec_helper.lua')
local parse, graph = require('codeoutline.parse'), require('codeoutline.graph')
local types, service = require('codeoutline.type_references'), require('codeoutline.service')
local root = (os.getenv('TEMP') or '/tmp'):gsub('\\', '/') .. '/codeoutline_types_' .. os.time() .. '_' .. math.random(1000000)
assert(xutils.mkdir_p(root))
local function write(path, source)
    local parent = (root .. '/' .. path):match('^(.*)/[^/]+$'); assert(xutils.mkdir_p(parent))
    local f = assert(io.open(root .. '/' .. path, 'wb')); f:write(source); f:close()
end
local function project(files)
    local records = {}
    for path, source in pairs(files) do records[path] = parse.parse(path, source, { ordinary_bindings = true }) end
    return graph.build({ files = records }), { root = root, query_source = function(_, path) return assert(files[path]), false end }
end
spec.describe('explicit type references', function()
    for _, case in ipairs({
        { 'a.cpp', 'struct User {}; User run(User arg) { User local; return arg; }', 3 },
        { 'A.java', 'class User {} class Work { User run(User arg) { User local; return arg; } }', 3 },
        { 'a.cs', 'class User {} class Work { User Run(User arg) { User local; return arg; } }', 3 },
        { 'A.kt', 'class User {}\nfun run(arg: User): User { val local: User = arg; return arg }', 3 },
        { 'a.ts', 'export class User {}\nexport function run(arg: User): User { let local: User = arg; return new User(); }', 4 },
        { 'a.go', 'package app\ntype User struct {}\nfunc Run(arg *User) *User { var local *User; return arg }', 3 },
        { 'a.rs', 'struct User {}\nfn run(arg: User) -> User { let local: User = arg; return arg; }', 3 },
    }) do
        spec.it('resolves declared positions in ' .. case[1], function()
            local G, idx = project({ [case[1]] = case[2] })
            local _, info = types.run(G, idx, 'User')
            spec.equal(#info.references, case[3]); spec.equal(info.incomplete, false)
            local Q = graph.query(G)
            local edges = Q.out[G.by_name.run and G.by_name.run[1] or G.by_name.Run[1]]
            for i = 1, #edges, graph.EDGE do spec.truthy(edges[i] ~= G.by_name.User[1] or case[1] == 'a.ts', 'type sites are not call edges') end
        end)
    end
    spec.it('separates qualified C++ identities and comments from real type sites', function()
        local G, idx = project({ ['a.cpp'] = [[namespace one { struct User {}; } namespace two { struct User {}; }
one::User run(two::User wrong) { one::User local; const char* text = "one::User"; return local; }
// one::User ignored;
]] })
        local output, info = types.run(G, idx, 'one::User')
        spec.equal(#info.references, 2); spec.contains(output, '[return] one::User')
        for _, ref in ipairs(info.references) do spec.equal(ref.written, 'one::User') end
    end)
    spec.it('does not borrow a global type shadowed by a generic parameter or local value', function()
        for _, case in ipairs({
            { 'a.cpp', 'struct User {}; template<class User> void run(User arg) {}' },
            { 'a.cpp', 'struct User {}; void run(int User) { User * value; }' },
            { 'a.ts', 'class User {} function run<User>(arg: User): User { return arg; }' },
            { 'A.java', 'class User {} class Work { public <User> User run(User arg) { return arg; } }' },
        }) do
            local G, idx = project({ [case[1]] = case[2] })
            local _, info = types.run(G, idx, 'User')
            spec.equal(#info.references, 0, case[2])
        end
    end)
    spec.it('labels fields, inheritance, explicit construction and casts', function()
        local G, idx = project({ ['a.cpp'] = 'struct User {}; struct Work : User { User field; };\n'
            .. 'void run(void* p) { User* x = new User(); auto y = static_cast<User*>(p); }' })
        local _, info = types.run(G, idx, 'User')
        local roles = {}; for _, ref in ipairs(info.references) do roles[ref.role] = true end
        for _, role in ipairs({ 'field', 'inheritance', 'variable', 'construction', 'cast' }) do spec.truthy(roles[role], role) end
    end)
    spec.it('follows imported TypeScript aliases without treating import aliases as casts', function()
        local G, idx = project({ ['model.ts'] = 'export class User {}',
            ['use.ts'] = "import { User as Account } from './model'; export function run(arg: Account): Account { return arg; }",
            ['other.ts'] = 'class Account {} function wrong(arg: Account) {}' })
        local _, info = types.run(G, idx, 'User')
        spec.equal(#info.references, 2)
        for _, ref in ipairs(info.references) do spec.equal(ref.file, 'use.ts'); spec.truthy(ref.role ~= 'cast') end
    end)
    spec.it('checks include visibility and follows explicit C++ aliases', function()
        local G, idx = project({ ['model.hpp'] = 'struct User {};',
            ['use.cpp'] = '#include "model.hpp"\nusing Account = User;\nAccount run(Account arg) { return arg; }',
            ['outside.cpp'] = 'User wrong(User arg) { return arg; }' })
        local _, info = types.run(G, idx, 'User')
        spec.equal(#info.references, 3)
        for _, ref in ipairs(info.references) do spec.equal(ref.file, 'use.cpp') end
    end)
    spec.it('follows default TypeScript imports through a re-export', function()
        local G, idx = project({ ['model.ts'] = 'export class User {}',
            ['public.ts'] = "export { User as default } from './model';",
            ['use.ts'] = "import Account from './public'; function run(arg: Account): Account { return arg; }" })
        local _, info = types.run(G, idx, 'User'); spec.equal(#info.references, 2)
        for _, ref in ipairs(info.references) do spec.equal(ref.file, 'use.ts') end
    end)
    spec.it('bounds target selection and validates source snapshots before returning targets', function()
        local G, idx = project({ ['one.cpp'] = 'struct User {}; User run(User arg) { return arg; }',
            ['two.cpp'] = 'struct User {}; User make(User arg) { return arg; }' })
        local _, info = types.run(G, idx, 'User', { max_nodes = 1 })
        spec.equal(#info.targets, 1); spec.equal(info.seed_limit_reached, true)
        spec.equal(info.query_stats.incomplete_reasons.type_reference_target_limit, true)
        idx.query_source = function() error('source snapshot changed', 0) end
        local ok, err = pcall(types.run, G, idx, 'User')
        spec.equal(ok, false); spec.contains(tostring(err), 'source snapshot changed')
    end)
    spec.it('visits the target file before unrelated candidates consume the source budget', function()
        local G, idx = project({ ['a.c'] = 'typedef int User; User other(User arg) { return arg; }',
            ['z.c'] = 'typedef int User; User run(User arg) { return arg; }' })
        local old = types.MAX_FILES; types.MAX_FILES = 1
        local ok, output, info = pcall(types.run, G, idx, 'path:z.c User')
        types.MAX_FILES = old
        spec.truthy(ok, output); spec.equal(#info.references, 2)
        for _, ref in ipairs(info.references) do spec.equal(ref.file, 'z.c') end
    end)
    spec.it('reports limits and preserves cancellation identity', function()
        local G, idx = project({ ['a.cpp'] = 'struct User {}; User run(User arg) { User local; return arg; }' })
        local _, info = types.run(G, idx, 'User', { max_nodes = 1 })
        spec.equal(#info.references, 1); spec.equal(info.node_limit_reached, true)
        local control = require('codeoutline.control')
        control.callback = function() error(control.cancelled(), 0) end
        local ok, err = pcall(types.run, G, idx, 'User'); control.callback = nil
        spec.equal(ok, false); spec.truthy(control.is_interrupted(err))
        idx.query_source = function() return '', true end
        local output; output, info = types.run(G, idx, 'User')
        spec.equal(output, nil); spec.equal(info.encoding_retry, true)
    end)
    spec.it('keeps C tags distinct from typedefs and supports explicit elaborated types', function()
        local G, idx = project({ ['a.c'] = 'struct User {}; typedef struct User Account;\n'
            .. 'void run(int User) { struct User* value; }\nAccount make(Account arg) { return arg; }' })
        local _, info = types.run(G, idx, 'User')
        spec.equal(#info.references, 4)
    end)
    spec.it('queries a TypeScript alias and its uses as an explicit type', function()
        local G, idx = project({ ['a.ts'] = 'class User {}\ntype Account = User;\nfunction run(arg: Account): Account { return arg; }' })
        local _, info = types.run(G, idx, 'User'); spec.equal(#info.references, 3)
        _, info = types.run(G, idx, 'Account'); spec.equal(#info.references, 2)
    end)
    spec.it('does not equate distinct Go defined types with their underlying type', function()
        local G, idx = project({ ['a.go'] = 'package app\ntype User struct {}\ntype Other User\nfunc Run(arg Other) Other { return arg }' })
        local _, info = types.run(G, idx, 'User'); spec.equal(#info.references, 1)
    end)
    spec.it('does not equate compound aliases with their element type', function()
        for _, case in ipairs({
            { 'a.ts', 'class User {}\ntype Accounts = User[];\nfunction run(arg: Accounts): Accounts { return arg; }' },
            { 'a.cpp', 'struct User {}; template<class T> struct List {}; using Accounts = List<User>; Accounts run(Accounts arg) { return arg; }' },
        }) do
            local G, idx = project({ [case[1]] = case[2] })
            local _, info = types.run(G, idx, 'User'); spec.equal(#info.references, 1, case[1])
            spec.equal(info.references[1].role, 'alias')
        end
    end)
    spec.it('resolves C# using aliases and generic type arguments', function()
        local G, idx = project({ ['a.cs'] = 'using Account = App.User; namespace App { class User {} class Work { Account Run(Account arg) { return new Account(); } } }' })
        local _, info = types.run(G, idx, 'App.User'); spec.equal(#info.references, 3)
    end)
    spec.it('keeps query evidence out of saved records and refreshes after edits', function()
        local folder = root .. '/disk'; write('disk/model.hpp', 'struct User {};\n')
        write('disk/use.cpp', '#include "model.hpp"\nUser run(User arg) { return arg; }\n')
        local opts = { cache_path = folder .. '/cache.idx', lister = 'walk' }
        for round = 1, 2 do
            local _, info = service.type_references(folder, 'User', opts)
            spec.equal(#info.references, 2)
            local idx = service.resident(folder)
            for _, record in pairs(idx.files) do spec.equal(record.type_sites, nil); spec.equal(record.type_parameters, nil) end
            idx:save(); service.forget(folder)
        end
        write('disk/use.cpp', '#include "model.hpp"\nvoid run() {}\n')
        local _, info = service.type_references(folder, 'User', opts); spec.equal(#info.references, 0)
        service.forget(folder)
    end)
    spec.it('keeps lightweight inheritance summaries separate from full binding evidence', function()
        local source = 'struct User {}; using Account = User; struct Work : Account { User Run(User arg) { return arg; } };'
        local record = parse.parse('a.cpp', source, { ranges = false })
        local G = graph.build({ files = { ['a.cpp'] = record } })
        local f = G.file_index['a.cpp']
        local context = require('codeoutline.ordinary_bindings').context(G, {}, function() return source end)
        local summary = context.hierarchy(f)
        spec.equal(summary.cpp_aliases_only, true); spec.equal(summary.type_sites, nil)
        local work = G.by_name.Work[1] - G.id_of[f][1] + 1
        spec.equal(summary.implementation_evidence[work].hierarchy_bases[1].written, 'Account')
        local full = context.data(f)
        spec.truthy(full.type_sites); spec.equal(full.cpp_aliases_only, nil)
        local method = G.by_name.Run[1] - G.id_of[f][1] + 1
        spec.truthy(full.implementation_evidence[method].params)
    end)
    spec.it('preserves include aliases and generic barriers in disk-backed inheritance queries', function()
        local folder = root .. '/hierarchy'
        write('hierarchy/model.hpp', 'struct Root {};\n')
        write('hierarchy/alias.hpp', '#include "model.hpp"\nusing Contract = Root;\n')
        write('hierarchy/use.cpp', '#include "alias.hpp"\nstruct Child : Contract {};\ntemplate<class T> struct Generic : Root {};\n')
        local _, info = service.type_hierarchy(folder, 'Root', { lister = 'walk' })
        spec.equal(#info.descendants, 1); spec.equal(info.descendants[1].name, 'Child')
        spec.truthy(info.query_stats.reverse_unresolved > 0)
        service.forget(folder)
    end)
    spec.it('resolves Go package aliases and Rust use aliases in real project roots', function()
        write('go/go.mod', 'module example.test/app\n\ngo 1.20\n')
        write('go/model/model.go', 'package model\ntype User struct {}\n')
        write('go/use.go', 'package app\nimport account "example.test/app/model"\nfunc Run(arg account.User) account.User { return arg }\n')
        write('rust/Cargo.toml', '[package]\nname = "types_test"\nversion = "0.1.0"\nedition = "2021"\n')
        write('rust/src/lib.rs', 'pub mod model;\nmod work;\n')
        write('rust/src/model.rs', 'pub struct User {}\n')
        write('rust/src/work.rs', 'use crate::model::User as Account;\nfn run(arg: Account) -> Account { arg }\n')
        for _, language in ipairs({ 'go', 'rust' }) do
            local folder = root .. '/' .. language
            local _, info = service.type_references(folder, 'User', { lister = 'walk' })
            spec.equal(#info.references, 2, language)
            service.forget(folder)
        end
    end)
end)
return { __init = function()
    xutils.rmtree(root)
    if spec.finish() > 0 then os.exit(1) end
    xthread.stop(0)
end }
