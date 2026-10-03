-- Unit specs for codeoutline (the index behind the CodeExplore tool):
-- tokenizer, per-language parsers, cross-file graph, index refresh, explore.
-- Run from repository root: xnet tests/lua/codeoutline_spec.lua

package.path = 'scripts/?.lua;' .. package.path

local spec = dofile('tests/lua/spec_helper.lua')
local xscan = require('codeoutline.xscan')
local ci = require('codeoutline.parse')

-- "kind qualified@line" for each node, for compact assertions.
local function names(r)
    local out = {}
    for _, n in ipairs(r.nodes) do out[#out + 1] = n.kind .. ' ' .. n.qualified .. '@' .. n.line end
    return table.concat(out, '\n')
end

-- refs as "container->name" (container '<file>' for file scope).
local function refs(r)
    local out = {}
    for i, name in ipairs(r.refs.name) do
        local from = r.refs.from[i]
        out[#out + 1] = (from > 0 and r.nodes[from].name or '<file>') .. '->' .. name
    end
    return table.concat(out, ' ')
end

spec.describe('xscan', function()
    local L = xscan.lang({ keywords = { 'if' }, ops = { '->', '>>=' }, line_comment = { '//' },
        block_comment = { { '/*', '*/' } }, strings = { { '"', '"', escape = '\\' } } })
    spec.it('tokenizes with lines and longest-match ops', function()
        local t = L:tokenize('a->b /* x\ny */ >>= "s\\"t"\nif')
        spec.equal(t.n, 6)
        spec.equal(t:text(2), '->')
        spec.equal(t:text(4), '>>=')
        spec.equal(t:kind(5), 'str')
        spec.equal(t:line(6), 3)
        spec.equal(t:kind(6), 'kw')
    end)
    spec.it('matches brackets and leaves strays unmatched', function()
        local t = L:tokenize('f(a[1]) }')
        spec.equal(t:match(2), 7)
        spec.equal(t:match(4), 6)
        spec.nil_value(t:match(8))
    end)
    spec.it('finds call sites', function()
        local t = L:tokenize('x = f(1) + g (2) + h')
        local c = t:calls(1, t.n)
        spec.equal(#c, 2)
        spec.equal(t:text(c[1]), 'f')
        spec.equal(t:text(c[2]), 'g')
    end)
    spec.it('indent mode pairs indent/dedent', function()
        local P = xscan.lang({ indent = true, line_comment = { '#' } })
        local t = P:tokenize('a\n  b\n  # c\n\n  d\ne\n')
        local kinds = {}
        for i = 1, t.n do kinds[#kinds + 1] = t:kind(i) end
        spec.equal(table.concat(kinds, ' '), 'id nl indent id nl id nl dedent id nl')
        spec.equal(t:match(3), 8)
    end)
end)

spec.describe('c', function()
    spec.it('extracts functions, structs, typedefs, macros, globals', function()
        local r = ci.parse('x.c', table.concat({
            '#include "x.h"',
            '#define MAX(a, b) ((a) > (b) ? (a) : (b))',
            '#define LIMIT 10',
            'typedef struct Node { int v; struct Node *next; } Node;',
            'typedef int (*cb_t)(int);',
            'enum Color { RED, GREEN = 2 };',
            'static int g_count = 0;',
            'static const luaL_Reg lib[] = { {"f", l_f}, {NULL, NULL} };',
            'int helper(int x);',
            'static int l_f(lua_State *L) {',
            '    return helper(MAX(1, 2)) + g_count;',
            '}',
            'LUA_API int (lua_gettop) (lua_State *L) { return 0; }',
        }, '\n'))
        local n = names(r)
        spec.contains(n, 'macro MAX@2')
        spec.contains(n, 'macro LIMIT@3')
        spec.contains(n, 'struct Node@4')
        spec.contains(n, 'field Node.next@4')
        spec.contains(n, 'typedef cb_t@5')
        spec.contains(n, 'enum_member Color.GREEN@6')
        spec.contains(n, 'variable g_count@7')
        spec.contains(n, 'variable lib@8')
        spec.contains(n, 'prototype helper@9')
        spec.contains(n, 'function l_f@10')
        spec.contains(n, 'function lua_gettop@13')
        spec.contains(refs(r), 'l_f->helper')
        spec.contains(refs(r), 'l_f->MAX')
        spec.contains(refs(r), 'lib->l_f', 'callback registered in a table')
        spec.equal(r.imports[1].path, 'x.h')
    end)
    spec.it('keeps both #ifdef arms at file scope, first arm inside bodies', function()
        local r = ci.parse('x.c', table.concat({
            '#ifdef _WIN32',
            'int plat(void) { return 1; }',
            '#else',
            'int plat(void) { return 2; }',
            '#endif',
            'int f(int a) {',
            '#ifdef X',
            '    if (a) {',
            '#else',
            '    if (!a) {',
            '#endif',
            '        g();',
            '    }',
            '    return 0;',
            '}',
            'int after(void) { return 0; }',
        }, '\n'))
        local n = names(r)
        spec.contains(n, 'function plat@2')
        spec.contains(n, 'function plat@4')
        spec.contains(n, 'function f@6')
        spec.contains(n, 'function after@16', 'braces stay balanced after the split if')
        spec.contains(refs(r), 'f->g')
    end)
    spec.it('does not treat a file-scope macro call as a declaration', function()
        local r = ci.parse('x.c', 'DEFINE_THING(foo);\nstatic void __attribute__((unused)) h(void) {}\n')
        spec.contains(refs(r), '<file>->DEFINE_THING')
        spec.contains(names(r), 'function h@2')
    end)
end)

spec.describe('python', function()
    spec.it('extracts classes, methods, decorators, imports, calls', function()
        local r = ci.parse('m.py', table.concat({
            'import os, sys as system',
            'from .pkg import (a, b as c)',
            'LIMIT = 3',
            '@dataclass',
            'class A(Base, mod.Mixin):',
            '    x: int = 1',
            '    def m(self):',
            '        def inner():',
            '            return helper()',
            '        return self.other(inner())',
            'async def run():',
            '    """doc with def fake():"""',
            '    await go()',
            'if TYPE_CHECKING:',
            '    def typed(): pass',
        }, '\n'))
        local n = names(r)
        spec.contains(n, 'variable LIMIT@3')
        spec.contains(n, 'class A@4', 'decorator starts the range')
        spec.contains(n, 'field A.x@6')
        spec.contains(n, 'method A.m@7')
        spec.contains(n, 'function A.m.inner@8')
        spec.contains(n, 'function run@11')
        spec.contains(n, 'function typed@15')
        spec.truthy(not n:find('fake'), 'strings are not parsed')
        local rf = refs(r)
        spec.contains(rf, 'inner->helper')
        spec.contains(rf, 'm->other')
        spec.contains(rf, 'run->go')
        spec.equal(r.imports[2].path, 'sys')
        spec.equal(r.imports[3].path, '.pkg')
        local cls
        for _, x in ipairs(r.nodes) do if x.kind == 'class' then cls = x end end
        spec.equal(table.concat(cls.bases, ','), 'Base,mod.Mixin')
    end)
end)

spec.describe('java', function()
    spec.it('extracts types, members, enum constants, supertypes', function()
        local r = ci.parse('A.java', table.concat({
            'package com.x;',
            'import java.util.List;',
            '@Service',
            'public class A<T> extends B<T> implements C, D.E {',
            '    private final Map<String, List<T>> cache = new HashMap<>(), other;',
            '    static final String[] NAMES = { "a" };',
            '    public A() { super(); init(); }',
            '    @Override',
            '    public <R> R apply(Function<T, R> f) throws IOException { return f.apply(null); }',
            '    abstract void hook();',
            '    enum Dir { UP(1), DOWN(2) { void x() {} }; Dir(int v) {} Dir flip() { return UP; } }',
            '    record P(int x, int y) {}',
            '}',
        }, '\n'))
        local n = names(r)
        spec.contains(n, 'class com.x.A@3')
        spec.contains(n, 'field com.x.A.cache@5')
        spec.contains(n, 'field com.x.A.other@5')
        spec.contains(n, 'field com.x.A.NAMES@6')
        spec.truthy(not n:find('A%.String'), 'array type is not a field name')
        spec.contains(n, 'constructor com.x.A.A@7')
        spec.contains(n, 'method com.x.A.apply@8')
        spec.contains(n, 'method com.x.A.hook@10')
        spec.contains(n, 'enum_member com.x.A.Dir.DOWN@11')
        spec.contains(n, 'constructor com.x.A.Dir.Dir@11')
        spec.contains(n, 'method com.x.A.Dir.flip@11')
        spec.contains(n, 'record com.x.A.P@12')
        spec.contains(n, 'field com.x.A.P.y@12')
        spec.contains(refs(r), 'A->init')
        spec.contains(refs(r), 'apply->apply')
        local a = r.nodes[1]
        spec.equal(table.concat(a.extends, ','), 'B')
        spec.equal(table.concat(a.implements, ','), 'C,D.E')
    end)
end)

spec.describe('lua', function()
    spec.it('extracts every named function form with exact spans', function()
        local r = ci.parse('pkg/tool.lua', table.concat({
            'local text = require("core.text")',
            'local M = {}',
            '--[==[ function fake() end ]==]',
            'local function helper(x) return x end',
            'function M.run(a)',
            '    local s = [[ function also_fake() end ]]',
            '    return helper(a) .. text.trim(s)',
            'end',
            'function M:method() return self:run(1) end',
            'M.cb = function() end',
            'M.stubs["@reload"] = function() end',
            'return {',
            '    name = "Tool",',
            '    call = function(input) return M.run(input) end,',
            '}',
        }, '\n'))
        local n = names(r)
        spec.contains(n, 'variable text@1')
        spec.contains(n, 'function helper@4')
        spec.contains(n, 'function M.run@5')
        spec.contains(n, 'method M:method@9')
        spec.contains(n, 'function M.cb@10')
        spec.contains(n, 'function M.stubs.@reload@11')
        spec.contains(n, 'function tool.call@14')
        spec.truthy(not n:find('fake'), 'long strings and comments are not code')
        local rf = refs(r)
        spec.contains(rf, 'run->helper')
        spec.contains(rf, 'run->trim')
        spec.contains(rf, 'method->run')
        spec.contains(rf, 'call->run')
        spec.truthy(not rf:find('run->run'), 'definition name is not a call')
        spec.equal(r.imports[1].path, 'core.text')
        local run
        for _, x in ipairs(r.nodes) do if x.qualified == 'M.run' then run = x end end
        spec.equal(run.end_line, 8)
    end)
end)

spec.describe('cpp', function()
    spec.it('extracts namespaces, classes, members, and out-of-line definitions', function()
        local r = ci.parse('w.cpp', table.concat({
            'namespace app::net {',
            'class API_EXPORT Widget final : public Base, private ns::Mixin<int> {',
            'public:',
            '    Widget(int id) : id_(id), name_{"w"} {}',
            '    virtual ~Widget();',
            '    int id() const noexcept { return id_; }',
            '    Widget& operator=(const Widget&) = default;',
            '    explicit operator bool() const { return id_ != 0; }',
            '    auto twice() const -> int { return helper(id_) * 2; }',
            '    template <typename T> T as() const { return T(id_); }',
            '    static int count_;',
            'private:',
            '    int id_;',
            '    enum class Mode : int { Off, On } mode_;',
            '};',
            'int Widget::count_ = 0;',
            'Widget::~Widget() { release(); }',
            'template <typename T>',
            'T clamp_to(T v) { return v; }',
            'using Id = int;',
            '}',
        }, '\n'))
        local n = names(r)
        spec.contains(n, 'namespace app::net@1')
        spec.contains(n, 'class app::net::Widget@2')
        spec.contains(n, 'constructor app::net::Widget::Widget@4')
        spec.contains(n, 'destructor app::net::Widget::~Widget@5')
        spec.contains(n, 'method app::net::Widget::id@6')
        spec.contains(n, 'method app::net::Widget::operator=@7')
        spec.contains(n, 'method app::net::Widget::operator bool@8')
        spec.contains(n, 'method app::net::Widget::twice@9')
        spec.contains(n, 'method app::net::Widget::as@10')
        spec.contains(n, 'field app::net::Widget::count_@11')
        spec.contains(n, 'field app::net::Widget::id_@13')
        spec.contains(n, 'enum_member app::net::Widget::Mode::On@14')
        spec.contains(n, 'field app::net::Widget::count_@16')
        spec.contains(n, 'destructor app::net::Widget::~Widget@17')
        spec.contains(n, 'function app::net::clamp_to@18')
        spec.contains(n, 'typedef app::net::Id@20')
        spec.truthy(not n:find('API_EXPORT', 1, true), 'export macro is not the class name')
        local w
        for _, x in ipairs(r.nodes) do if x.qualified == 'app::net::Widget' then w = x end end
        spec.equal(table.concat(w.bases, ','), 'Base,ns::Mixin')
        local rf = refs(r)
        spec.contains(rf, 'twice->helper')
        spec.contains(rf, '~Widget->release')
    end)
    spec.it('routes .h to C++ only when it uses C++ syntax', function()
        spec.equal(ci.parse('a.h', 'int f(int new);\n').language, 'c')
        spec.equal(ci.parse('b.h', 'namespace x { int f(); }\n').language, 'cpp')
    end)
end)

spec.describe('go', function()
    spec.it('extracts funcs, methods, types, fields, interface methods, values', function()
        local r = ci.parse('s.go', table.concat({
            'package server',
            'import (',
            '    "fmt"',
            '    log "github.com/x/log"',
            ')',
            'const Max = 3',
            'var (',
            '    handler = func() {',
            '        notAVar()',
            '    }',
            '    a, b int',
            ')',
            'type Server struct {',
            '    Name, Addr string `json:"name"`',
            '    *log.Logger',
            '    sync.Mutex',
            '}',
            'type Handler interface {',
            '    Serve(w Writer) error',
            '}',
            'type ID = int',
            'func (s *Server) Start() error { return s.listen(fmt.Sprint(1)) }',
            'func Map[T any](xs []T) struct{ n int } { return struct{ n int }{len(xs)} }',
        }, '\n'))
        local n = names(r)
        spec.contains(n, 'constant Max@6')
        spec.contains(n, 'variable handler@8')
        spec.contains(n, 'variable b@11')
        spec.truthy(not n:find('notAVar'), 'func literal body lines are not specs')
        spec.contains(n, 'struct Server@13')
        spec.contains(n, 'field Server.Addr@14')
        spec.contains(n, 'field Server.Logger@15')
        spec.contains(n, 'field Server.Mutex@16')
        spec.contains(n, 'interface Handler@18')
        spec.contains(n, 'method Handler.Serve@19')
        spec.contains(n, 'typedef ID@21')
        spec.contains(n, 'method Server.Start@22')
        spec.contains(n, 'function Map@23')
        spec.contains(refs(r), 'Start->listen')
        spec.contains(refs(r), 'Start->Sprint')
        spec.equal(r.imports[2].path, 'github.com/x/log')
    end)
end)

spec.describe('javascript / typescript', function()
    spec.it('extracts functions, classes, members, TS types, and skips JSX class=', function()
        local r = ci.parse('m.tsx', table.concat({
            "import { a } from './a'",
            'export const VERSION = `v${1 + /x/.test(`y${"}"}`) ? 1 : 0}`',
            'export async function load<T>(url: string): Promise<{ ok: T }> {',
            '  const parse = (s) => JSON.parse(s)',
            '  return parse(await fetch(url))',
            '}',
            'export default class Store<T> extends Base implements IStore {',
            '  private items: T[] = []',
            '  static get size(): number { return 0 }',
            '  constructor(private id: string) { super() }',
            '  get<K>(key: K): T { return this.lookup(key) }',
            '  handle = async (e) => { this.save(e) }',
            '}',
            'interface IStore { size: number; get(k: string): unknown }',
            'type Id = string | number',
            'enum Color { Red, Green }',
            'exports.helper = function () {}',
            'const server = Bun.serve({ fetch(req) { return route(req) } })',
            'const View = () => <div class="box">{items.map(i => <b>{i}</b>)}</div>',
        }, '\n'), 'typescript')
        local n = names(r)
        spec.contains(n, 'variable VERSION@2')
        spec.contains(n, 'function load@3')
        spec.contains(n, 'function load.parse@4')
        spec.contains(n, 'class Store@7')
        spec.contains(n, 'field Store.items@8')
        spec.contains(n, 'method Store.size@9')
        spec.contains(n, 'constructor Store.constructor@10')
        spec.contains(n, 'method Store.get@11')
        spec.contains(n, 'method Store.handle@12')
        spec.contains(n, 'interface IStore@14')
        spec.contains(n, 'method IStore.get@14')
        spec.contains(n, 'typedef Id@15')
        spec.contains(n, 'enum_member Color.Green@16')
        spec.contains(n, 'function exports.helper@17')
        spec.contains(n, 'method fetch@18')
        spec.contains(n, 'function View@19')
        spec.truthy(not n:find('class box') and not n:find('default'), 'JSX class= is an attribute')
        local rf = refs(r)
        spec.contains(rf, 'get->lookup')
        spec.contains(rf, 'handle->save')
        spec.contains(rf, 'fetch->route')
        spec.equal(r.imports[1].path, './a')
    end)
end)

spec.describe('csharp', function()
    spec.it('extracts namespaces, types, members, properties, operators', function()
        local r = ci.parse('C.cs', table.concat({
            'using System.Text;',
            'namespace App.Core;',
            '[Serializable]',
            'public sealed partial class Vec<T> : Base, IEquatable<Vec<T>> where T : struct {',
            '    public int X { get; private set; } = 1;',
            '    public int Len => X * 2;',
            '    private readonly Dictionary<string, List<int>> map = new(), other;',
            '    public Vec(int x) : base(x) { Init(); }',
            '    ~Vec() { }',
            '    public (int, string) Pair() => (1, "a");',
            '    public static Vec<T> operator +(Vec<T> a, Vec<T> b) => a;',
            '    public static bool operator >(Vec<T> a, Vec<T> b) => true;',
            '    public event EventHandler Changed;',
            '    public delegate void Cb(int x);',
            '    enum Mode { Off, On }',
            '    public record Point(int A, int B);',
            '}',
        }, '\n'))
        local n = names(r)
        spec.contains(n, 'namespace App.Core@2')
        spec.contains(n, 'class App.Core.Vec@4')
        spec.contains(n, 'property App.Core.Vec.X@5')
        spec.contains(n, 'property App.Core.Vec.Len@6')
        spec.contains(n, 'field App.Core.Vec.map@7')
        spec.contains(n, 'field App.Core.Vec.other@7')
        spec.contains(n, 'constructor App.Core.Vec.Vec@8')
        spec.contains(n, 'destructor App.Core.Vec.~Vec@9')
        spec.contains(n, 'method App.Core.Vec.Pair@10')
        spec.contains(n, 'method App.Core.Vec.operator+@11')
        spec.contains(n, 'method App.Core.Vec.operator>@12')
        spec.contains(n, 'field App.Core.Vec.Changed@13')
        spec.contains(n, 'typedef App.Core.Vec.Cb@14')
        spec.contains(n, 'enum_member App.Core.Vec.Mode.On@15')
        spec.contains(n, 'record App.Core.Vec.Point@16')
        spec.contains(n, 'property App.Core.Vec.Point.B@16')
        spec.contains(refs(r), 'Vec->Init')
        spec.equal(r.imports[1].path, 'System.Text')
    end)
end)

spec.describe('rust', function()
    spec.it('extracts items, impl methods, traits, modules, macros', function()
        local r = ci.parse('lib.rs', table.concat({
            'use crate::net::{Conn, Addr};',
            'mod util;',
            '#[derive(Debug)]',
            'pub struct Point<\'a> { pub x: i32, name: &\'a str }',
            'pub enum Shape { Circle(f32), Rect { w: f32, h: f32 } }',
            'pub trait Area { fn area(&self) -> f32; fn twice(&self) -> f32 { self.area() * 2.0 } }',
            'impl<\'a> Area for &\'a Point<\'a> {',
            '    fn area(&self) -> f32 { helper(r#"raw { str"#) }',
            '}',
            'impl Point<\'_> { pub const unsafe fn new() -> Self { todo!() } }',
            'impl Area for () { fn area(&self) -> f32 { 0.0 } }',
            'macro_rules! square { ($x:expr) => { $x * $x }; }',
            'pub(crate) static COUNT: usize = 0;',
            'mod tests { fn t() {} }',
        }, '\n'))
        local n = names(r)
        spec.contains(n, 'namespace util@2')
        spec.contains(n, 'struct Point@4')                    -- attributes are not part of the item
        spec.contains(n, 'field Point::x@4')
        spec.contains(n, 'enum_member Shape::Rect@5')
        spec.contains(n, 'interface Area@6')
        spec.contains(n, 'method Area::twice@6')
        spec.contains(n, 'method Point::area@8')
        spec.contains(n, 'method Point::new@10')
        spec.contains(n, 'method ()::area@11')
        spec.contains(n, 'macro square@12')
        spec.contains(n, 'variable COUNT@13')
        spec.contains(n, 'function tests::t@14')
        local rf = refs(r)
        spec.contains(rf, 'area->helper')
        spec.contains(rf, 'new->todo')
        spec.contains(rf, 'twice->area')
    end)
end)

-- Regressions from the 2026-09-25 review: each case is checked against what
-- the language actually means, not against the other xscan implementation.
spec.describe('review regressions', function()
    local graph_mod = require('codeoutline.graph')
    local function build(files)
        local idx = { files = {}, generation = 1 }
        for p, s in pairs(files) do idx.files[p] = ci.parse(p, s) end
        return graph_mod.build(idx)
    end
    local function all_edges(G)
        local es = {}
        for id, list in pairs(G.out) do
            for i = 1, #list, graph_mod.EDGE do es[#es + 1] = G.nodes[id].qualified .. '->' .. G.nodes[list[i]].qualified end
        end
        table.sort(es)
        return table.concat(es, ' ')
    end

    spec.it('C++ static members stay callable from other files', function()
        local G = build({ ['api.hpp'] = 'struct Api { static void work() {} };',
            ['main.cpp'] = '#include "api.hpp"\nvoid run() { Api::work(); }' })
        spec.equal(all_edges(G), 'run->Api::work')
    end)
    spec.it('file-scope C statics stay file-local', function()
        local G = build({ ['a.c'] = 'static int h(void) { return 0; }',
            ['b.c'] = 'int run(void) { return h(); }' })
        spec.equal(all_edges(G), '')
    end)
    spec.it('a same-named definition in another language does not hide a C prototype', function()
        local G = build({ ['api.h'] = 'void work(void);', ['main.c'] = '#include "api.h"\nvoid run(void) { work(); }',
            ['other.py'] = 'def work():\n    pass\n' })
        spec.equal(all_edges(G), 'run->work')
    end)
    spec.it('a regex after a JS control condition keeps the function range', function()
        local r = ci.parse('a.js', 'function first(x) {\n  if (x) /}/.test(x);\n  target();\n}\nfunction target() {}\n')
        spec.contains(names(r), 'function first@1')
        spec.equal(r.nodes[1].end_line, 4)
        spec.contains(refs(r), 'first->target')
    end)
    spec.it('comments inside template substitutions do not open braces', function()
        local r = ci.parse('a.js', 'const x = `${1 /* { */}`;\nfunction second() {}')
        spec.contains(names(r), 'function second@2')
    end)
    spec.it('Rust block comments nest', function()
        local r = ci.parse('a.rs', '/* outer /* inner */ fn ghost() {} */\nfn real() {}')
        spec.equal(names(r), 'function real@2')
    end)
    spec.it('Python blocks end on their own last line, across continuations', function()
        local r = ci.parse('a.py', 'def first():\n    x = 1 + \\\n        2\n    def inner():\n        pass\n    return x\ndef second():\n    pass\n')
        local ends = {}
        for _, n in ipairs(r.nodes) do if n.kind ~= 'variable' then ends[#ends + 1] = n.qualified .. ':' .. n.line .. '-' .. n.end_line end end
        spec.equal(table.concat(ends, ' '), 'first:1-6 first.inner:4-5 second:7-8')
    end)
    spec.it('rejects roots that would be interpreted by the shell', function()
        local index = require('codeoutline.index')
        for _, bad in ipairs({ '" & echo PWNED & rem "', 'C:/x%PATH%', '/tmp/$(id)', '--pre=calc' }) do
            local ok = pcall(index.open, bad, { cache_path = (os.getenv('TEMP') or '.') .. '/never.idx' })
            spec.equal(ok, false, 'rejected: ' .. bad)
        end
    end)
end)

-- A throwaway project on disk for the index / graph / explore layers.
local function write(path, text)
    local d = path:match('^(.*)/[^/]*$')
    xutils.mkdir_p(d)
    local f = assert(io.open(path, 'wb'))
    f:write(text)
    f:close()
end

local tmp_root = (os.getenv('TEMP') or os.getenv('TMPDIR') or '/tmp'):gsub('\\', '/') .. '/codeindex_spec_' .. os.time()
local cache = tmp_root .. '.idx'
write(tmp_root .. '/net.h', 'int net_send(int fd);\n')
write(tmp_root .. '/net.c', table.concat({
    '#include "net.h"',
    'static int helper(int x) { return x; }',
    'int net_send(int fd) {',
    '    return helper(fd);',
    '}',
}, '\n'))
write(tmp_root .. '/app.c', table.concat({
    '#include "net.h"',
    'static int helper(int x) { return x + 1; }',
    'static int on_tick(void) { return 0; }',
    'static const struct { const char *n; int (*f)(void); } handlers[] = { {"tick", on_tick} };',
    'int run(void) {',
    '    helper(1);',
    '    return net_send(3);',
    '}',
}, '\n'))
write(tmp_root .. '/pkg/store.py', table.concat({
    'class Store:',
    '    def save(self, item):',
    '        return self._write(item)',
    '    def _write(self, item):',
    '        return item',
}, '\n'))
write(tmp_root .. '/pkg/api.py', table.concat({
    'from .store import Store',
    'def handle(req):',
    '    s = Store()',
    '    return s.save(req)',
}, '\n'))

write(tmp_root .. '/scripts/core/text.lua', 'local M = {}\nfunction M.trim(s) return s end\nreturn M\n')
write(tmp_root .. '/scripts/app/main.lua', table.concat({
    'local text = require("core.text")',
    'local util = dofile("scripts/core/text.lua")',
    'local function go(s) return text.trim(s) end',
    'return go',
}, '\n'))

write(tmp_root .. '/cc/shape.hpp', 'namespace geo {\nclass Shape {\npublic:\n    double area() const;\n    double scaled(double k) const { return this->area() * k; }\n};\n}\n')
write(tmp_root .. '/cc/shape.cpp', '#include "shape.hpp"\n#include "../net.h"\nnamespace geo {\ndouble Shape::area() const { return net_send(1); }\n}\n')

local svc = require('codeoutline.service')
local explore = require('codeoutline.explore')
local graph = require('codeoutline.graph')

local function edges_from(G, name)
    local out = {}
    for _, id in ipairs(G.by_name[name] or {}) do
        local list = G.out[id] or {}
        for i = 1, #list, graph.EDGE do
            out[#out + 1] = G.nodes[list[i]].name .. '@' .. G.files[G.node_file[list[i]]].path
        end
    end
    table.sort(out)
    return table.concat(out, ' ')
end

spec.describe('mcp roots', function()
    spec.it('maps file URIs to local paths', function()
        local uri_path = require('codeoutline.mcp').uri_path
        spec.equal(uri_path('file:///C:/src/%E4%B8%AD%E6%96%87%20app'), 'C:/src/中文 app')
        spec.equal(uri_path('file:///c%3A/src'), 'c:/src')
        spec.equal(uri_path('file:///home/me/app'), '/home/me/app')
        spec.equal(uri_path('file://localhost/srv/app'), '/srv/app')
        spec.equal(uri_path('file://server/share/app'), '//server/share/app')
        spec.equal(uri_path('https://example.com/app'), nil)
        spec.equal(uri_path(nil), nil)
    end)
    spec.it('limits projects to allowed roots unless access is unrestricted', function()
        local paths = require('codeoutline.path')
        spec.equal(paths.allowed(false, 'F:/any/project'), true)
        spec.equal(paths.allowed({ 'C:/', 'D:/src' }, 'D:/src/app'), true)
        spec.equal(paths.allowed({ 'C:/', 'D:/src' }, 'D:/srcx'), false)
        spec.equal(paths.allowed({ 'C:/', 'D:/src' }, 'E:/app'), false)
        spec.equal(paths.allowed({}, 'C:/app'), false)
    end)
end)

spec.describe('graph', function()
    local _, G = svc.get(tmp_root, { cache_path = cache })
    spec.it('binds calls across #include to the defining .c file', function()
        spec.contains(edges_from(G, 'run'), 'net_send@net.c')
    end)
    spec.it('keeps static functions file-local', function()
        spec.contains(edges_from(G, 'run'), 'helper@app.c')
        spec.truthy(not edges_from(G, 'run'):find('helper@net.c', 1, true))
        spec.equal(edges_from(G, 'net_send'), 'helper@net.c')
    end)
    spec.it('links callbacks registered in tables', function()
        spec.contains(edges_from(G, 'handlers'), 'on_tick@app.c')
    end)
    spec.it('binds this-> calls to out-of-line C++ methods and C++ to C', function()
        spec.contains(edges_from(G, 'scaled'), 'area@cc/shape.cpp')
        spec.contains(edges_from(G, 'area'), 'net_send@net.c')
    end)
    spec.it('resolves Lua module calls through require', function()
        spec.contains(edges_from(G, 'go'), 'trim@scripts/core/text.lua')
    end)
    spec.it('resolves Python imports and self calls', function()
        spec.contains(edges_from(G, 'handle'), 'Store@pkg/store.py')
        spec.contains(edges_from(G, 'save'), '_write@pkg/store.py')
    end)
end)

spec.describe('explore', function()
    spec.it('returns source, call paths, and callers for named symbols', function()
        local text = svc.explore(tmp_root, 'run net_send', { cache_path = cache })
        spec.contains(text, 'run -> net_send')
        spec.contains(text, '## app.c')
        spec.contains(text, '7\t    return net_send(3);')
        spec.contains(text, '## net.c')
        spec.contains(text, 'called by: run (app.c:7)')
    end)
    spec.it('outlines oversized classes and ignores plain English words', function()
        local idx, G = svc.get(tmp_root, { cache_path = cache })
        explore.SEED_FULL_LINES = 2
        local text = explore.run(G, idx, 'how does the Store save work')
        explore.SEED_FULL_LINES = 160
        spec.contains(text, 'class body of 5 lines outlined')
        spec.contains(text, '2\t    def save(self, item):')
    end)
    spec.it('picks up edits and deletions on the next query', function()
        write(tmp_root .. '/app.c', 'int run(void) { return 0; }\nint fresh_fn(void) { return run(); }\n')
        os.remove(tmp_root .. '/pkg/api.py')
        local _, G, stats = svc.get(tmp_root, { cache_path = cache })
        spec.equal(stats.parsed, 1)
        spec.equal(stats.removed, 1)
        spec.truthy(G.by_name.fresh_fn, 'new symbol indexed')
        spec.nil_value(G.by_name.handle, 'deleted file dropped')
    end)
    spec.it('sees a same-second, same-size edit (racy mtime)', function()
        local path = tmp_root .. '/racy.lua'
        write(path, 'function oldname() end\n')
        svc.get(tmp_root, { cache_path = cache })
        write(path, 'function newname() end\n')           -- same size, same second
        local _, G = svc.get(tmp_root, { cache_path = cache })
        spec.truthy(G.by_name.newname, 'new content indexed')
        spec.nil_value(G.by_name.oldname, 'stale symbol dropped')
        os.remove(path)
    end)
    spec.it('skips reading files whose size and mtime predate the last read', function()
        local path = tmp_root .. '/settled.lua'
        write(path, 'function settled() end\n')
        local deadline = os.time() + 2
        while os.time() <= deadline do end                  -- let mtime fall behind the next read
        svc.get(tmp_root, { cache_path = cache })             -- reads it: checked > mtime + 1
        local opened, raw_open = {}, io.open
        io.open = function(p, ...) opened[p] = true; return raw_open(p, ...) end
        local ok, err = pcall(svc.get, tmp_root, { cache_path = cache })
        io.open = raw_open
        assert(ok, err)
        for p in pairs(opened) do spec.truthy(not p:find('settled.lua', 1, true), 'settled file re-read') end
        os.remove(path)
    end)
    spec.it('walks the tree without rg, honoring .gitignore and hidden dirs', function()
        local index = require('codeoutline.index')
        local wr = tmp_root .. '_walk'          -- its own tree: the shared one feeds other cases
        write(wr .. '/net.c', 'int net(void) { return 0; }\n')
        write(wr .. '/.gitignore', 'gen/\n*.pb.go\n/only_root.c\n')
        write(wr .. '/gen/x.c', 'int gen(void) { return 0; }\n')
        write(wr .. '/api.pb.go', 'package api\n')
        write(wr .. '/only_root.c', 'int r(void) { return 0; }\n')
        write(wr .. '/sub/only_root.c', 'int s(void) { return 0; }\n')
        write(wr .. '/.hidden/h.c', 'int h(void) { return 0; }\n')
        local idx = index.open(wr, { cache_path = wr .. '.idx', lister = 'walk' })
        local listed = ' ' .. table.concat(idx:list_files(), ' ') .. ' '
        spec.contains(listed, ' net.c ')
        spec.contains(listed, ' sub/only_root.c ', 'an anchored rule matches only at the root')
        for _, gone in ipairs({ ' gen/x.c ', ' api.pb.go ', ' .hidden/h.c ', ' only_root.c ' }) do
            spec.truthy(not listed:find(gone, 1, true), 'excluded:' .. gone)
        end
        os.remove(wr .. '.idx')
        xutils.rmtree(wr)
    end)
    spec.it('reloads from the on-disk cache without reparsing', function()
        svc.forget(tmp_root)
        local _, _, stats = svc.get(tmp_root, { cache_path = cache })
        spec.equal(stats.parsed, 0)
        spec.truthy(stats.unchanged >= 4)
    end)
end)

spec.describe('watched refresh', function()
    local index = require('codeoutline.index')
    local wr = tmp_root .. '_watch'         -- its own tree: the shared one feeds other cases
    write(wr .. '/a.c', 'int a(void) { return 0; }\n')
    write(wr .. '/b.c', 'int b(void) { return a(); }\n')
    local idx = index.open(wr, { cache_path = wr .. '.idx' })
    -- A scripted stand-in for the native watcher: each read returns q.next.
    local q = {}
    idx.watching = true
    idx.watcher = {
        read = function()
            local r = q.next or { {}, false, false }
            q.next = nil
            return r[1], r[2], r[3]
        end,
        close = function() q.closed = true end,
    }
    local listings = 0
    local list_files = idx.list_files
    idx.list_files = function(self) listings = listings + 1; return list_files(self) end

    spec.it('starts with a full pass', function()
        local stats = idx:refresh()
        spec.equal(stats.mode, 'full'); spec.equal(stats.parsed, 2)
        spec.equal(idx.watch_ready, true)
    end)
    spec.it('skips the listing when nothing changed', function()
        listings = 0
        local gen = idx.generation
        local stats = idx:refresh()
        spec.equal(stats.mode, 'changes'); spec.equal(stats.parsed, 0); spec.equal(stats.unchanged, 2)
        spec.equal(listings, 0); spec.equal(idx.generation, gen)
    end)
    spec.it('reparses only the reported files', function()
        listings = 0
        write(wr .. '/a.c', 'int a(void) { return 1; }\nint a2(void) { return 2; }\n')
        q.next = { { 'a.c', 'a.c' }, false, false }
        local stats = idx:refresh()
        spec.equal(stats.mode, 'changes'); spec.equal(stats.parsed, 1); spec.equal(listings, 0)
        spec.equal(#idx.files['a.c'].nodes, 2)
    end)
    spec.it('relists on creation and drops removed files', function()
        write(wr .. '/c.c', 'int c(void) { return 0; }\n')
        q.next = { { 'c.c' }, true, false }
        local stats = idx:refresh()
        spec.equal(stats.mode, 'relisted'); spec.equal(stats.parsed, 1)
        spec.truthy(idx.files['c.c'])
        os.remove(wr .. '/c.c')
        q.next = { { 'c.c' }, true, false }
        stats = idx:refresh()
        spec.equal(stats.removed, 1); spec.equal(idx.files['c.c'], nil)
    end)
    spec.it('relists when a reported supported file is not indexed', function()
        write(wr .. '/d.c', 'int d(void) { return 0; }\n')
        q.next = { { 'd.c' }, false, false }
        local stats = idx:refresh()
        spec.equal(stats.mode, 'relisted'); spec.truthy(idx.files['d.c'])
    end)
    spec.it('ignores hidden paths', function()
        listings = 0
        write(wr .. '/.hidden/x.c', 'int x(void) { return 0; }\n')
        q.next = { { '.hidden/x.c', 'sub/.cache/y.c' }, false, false }
        local stats = idx:refresh()
        spec.equal(stats.mode, 'changes'); spec.equal(listings, 0)
        spec.equal(idx.files['.hidden/x.c'], nil)
    end)
    spec.it('falls back to a full pass on overflow or an ignore-file change', function()
        q.next = { {}, false, true }
        spec.equal(idx:refresh().mode, 'full')
        q.next = { { 'sub/.gitignore' }, false, false }
        spec.equal(idx:refresh().mode, 'full')
    end)
    spec.it('replaces a failed watcher and rescans', function()
        q.next = { nil, 'watch failed' }
        local stats = idx:refresh()
        spec.equal(stats.mode, 'full'); spec.equal(q.closed, true)
        if xwatch and xwatch.open then
            spec.truthy(idx.watcher and idx.watcher.read ~= nil, 'native watcher reopened')
        else
            spec.equal(idx.watch_error, 'watch failed')
        end
        idx:close()
    end)

    if xwatch and xwatch.open then
        spec.it('applies edits reported by the native watcher', function()
            local nr = tmp_root .. '_native'
            write(nr .. '/x.lua', 'function before() end\n')
            assert(xutils.mkdir_p(nr .. '_idle'))
            -- Reading a watcher on a directory nobody touches blocks for
            -- the full timeout: a sleep that works on every platform.
            local idle = assert(xwatch.open(nr .. '_idle'))
            local live = index.open(nr, { cache_path = nr .. '.idx' })
            spec.equal(live:watch(), true)
            spec.equal(live:refresh().mode, 'full')
            write(nr .. '/x.lua', 'function after() end\nfunction more() end\n')
            local stats
            for _ = 1, 40 do
                idle:read(50)
                stats = live:refresh()
                if stats.parsed > 0 then break end
            end
            spec.equal(stats.parsed, 1)
            spec.truthy(stats.mode ~= 'full', 'refreshed from events, not a full pass')
            spec.equal(#live.files['x.lua'].nodes, 2)
            live:close(); idle:close()
            xutils.rmtree(nr); xutils.rmtree(nr .. '_idle')
            os.remove(nr .. '.idx')
        end)
    end

    os.remove(wr .. '.idx')
    xutils.rmtree(wr)
end)

xutils.rmtree(tmp_root)
os.remove(cache)

return {
    __init = function()
        local failed = spec.finish()
        if failed > 0 then os.exit(1) end
        xthread.stop(0)
    end,
}
