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

spec.describe('native Lua exports', function()
    local function native_parse(path, source, opts)
        opts = opts or {}; opts.foreign = true
        return ci.parse(path, source, opts)
    end
    spec.it('infers the real xthread guest signature without changing its C signature', function()
        local f = assert(io.open('xnet2lua/xlua/lua_xthread.c', 'rb'))
        local source = f:read('a'); f:close()
        local rec = native_parse('lua_xthread.c', source, { ranges = false })
        local node = rec.nodes[rec.foreign_exports.lua.xthread.create_thread]
        local signature = require('codeoutline.foreign').signature(node, 'lua', 'create_thread')
        spec.equal(signature.label, 'create_thread(id:int, name:string, script_path:string)')
        spec.contains(node.sig, 'lua_State')
        spec.nil_value(require('codeoutline.foreign').signature(node, 'c', 'create_thread'))
    end)
    spec.it('retains positional gaps, checked types, defaults and unknown dynamic indices', function()
        local rec = native_parse('native.c', [[
static int call(lua_State *state) {
    luaL_checkinteger(state, lua_upvalueindex(1));
    luaL_checkstring(state, -1);
    luaL_checkinteger(other, 7);
    luaL_checktype(state, 2, LUA_TTABLE);
    const char *text = luaL_optstring(state, 3, "hello");
    luaL_checknumber(state, index);
    return 0;
}
static const luaL_Reg api[] = {{"call", call}, {NULL, NULL}};
int luaopen_test(lua_State *L) { luaL_newlib(L, api); return 1; }
]])
        local node = rec.nodes[rec.foreign_exports.lua.test.call]
        spec.equal(require('codeoutline.foreign').signature(node, 'lua', 'call').label,
            'call(arg1:unknown, arg2:table, text?:string = "hello", ...:unknown)')
    end)
    spec.it('keeps modules separate and ignores unregistered C functions in C and C++', function()
        local source = [[
static int first(lua_State *L) { return 0; }
static int second(lua_State *L) { return 0; }
static const luaL_Reg one[] = {{"run", first}, {NULL, NULL}};
static const luaL_Reg two[] = {{"run", second}, {NULL, NULL}};
int luaopen_one(lua_State *L) { luaL_newlib(L, one); return 1; }
int luaopen_two(lua_State *L) { lua_newtable(L); luaL_setfuncs(L, two, 0); return 1; }
int luaopen_old(lua_State *L) { luaL_register(L, "old", one); return 1; }
]]
        for _, ext in ipairs({ 'c', 'cpp' }) do
            local rec = native_parse('native.' .. ext, source, { ranges = false })
            spec.equal(rec.nodes[rec.foreign_exports.lua.one.run].name, 'first')
            spec.equal(rec.nodes[rec.foreign_exports.lua.two.run].name, 'second')
            spec.equal(rec.nodes[rec.foreign_exports.lua.old.run].name, 'first')
            spec.nil_value(rec.foreign_exports.lua.one.first)
        end
    end)
    spec.it('extracts the real xscan module without leaking metatable methods', function()
        local f = assert(io.open('xnet2lua/xlua/lua_xscan.c', 'rb'))
        local source = f:read('a'); f:close()
        local rec = native_parse('lua_xscan.c', source)
        local exports = assert(rec.foreign_exports.lua.xscan)
        spec.truthy(exports.lang)
        spec.nil_value(exports.tokenize)
        spec.nil_value(exports.text)
    end)
    spec.it('rejects discarded and conflicting native constructor results', function()
        local rec = native_parse('constructors.c', [[
static int push_a(lua_State *L) { lua_newuserdata(L, 8); luaL_setmetatable(L, "a"); return 1; }
static int push_b(lua_State *L) { lua_newuserdata(L, 8); luaL_setmetatable(L, "b"); return 1; }
static int discarded(lua_State *L) { push_a(L); lua_pop(L, 1); return 0; }
static int popped(lua_State *L) { push_a(L); lua_pop(L, 1); return 1; }
static int conditional(lua_State *L) { if (flag) { push_a(L); } return 1; }
static int called(lua_State *L) { push_a(L); lua_call(L, 0, 0); return 1; }
static int changed(lua_State *L) { push_a(L); lua_pushinteger(L, 2); return 1; }
static int conflict(lua_State *L) { if (flag) return push_a(L); return push_b(L); }
static int mixed(lua_State *L) { if (flag) return 0; return push_a(L); }
static int consistent(lua_State *L) { if (flag) return push_a(L); return push_a(L); }
static int wrapper(lua_State *L) { return push_a(L); }
static const luaL_Reg funcs[] = {
 {"discarded", discarded}, {"popped", popped}, {"changed", changed},
 {"conditional", conditional}, {"called", called}, {"conflict", conflict}, {"mixed", mixed}, {"consistent", consistent}, {"wrapper", wrapper}, {NULL, NULL}};
int luaopen_test(lua_State *L) { luaL_newlib(L, funcs); return 1; }
]])
        local foreign = require('codeoutline.foreign')
        for _, name in ipairs({ 'discarded', 'popped', 'changed', 'conflict', 'mixed', 'conditional', 'called' }) do
            spec.nil_value(foreign.returns(rec.nodes[rec.foreign_exports.lua.test[name]], 'lua'), name)
        end
        for _, name in ipairs({ 'consistent', 'wrapper' }) do
            spec.equal(foreign.returns(rec.nodes[rec.foreign_exports.lua.test[name]], 'lua'), 'a', name)
        end
    end)
    spec.it('types native objects by the metatable the implementation returns', function()
        local f = assert(io.open('xnet2lua/xlua/lua_xrecord.c', 'rb'))
        local source = f:read('a'); f:close()
        local rec = native_parse('lua_xrecord.c', source, { ranges = false })
        local foreign = require('codeoutline.foreign')
        local handle = assert(rec.foreign_exports.lua['xrecord.handle'])
        local schema = assert(rec.foreign_exports.lua['xrecord.schema'])
        spec.truthy(handle.get)
        spec.truthy(schema.new)
        spec.nil_value(rec.foreign_exports.lua.xrecord.get)
        -- A method's self is implicit for the guest, and the pool a schema
        -- creates is named by the metatable the C helper puts on the stack.
        spec.equal(foreign.signature(rec.nodes[schema.new], 'lua', 'new').label, 'new(capacity:int) -> xrecord.handle')
        spec.equal(foreign.signature(rec.nodes[handle.set], 'lua', 'set').label, 'set(id:int, field:string, arg3:unknown)')
        spec.equal(foreign.returns(rec.nodes[rec.foreign_exports.lua.xrecord.schema], 'lua'), 'xrecord.schema')
        spec.equal(foreign.returns(rec.nodes[rec.foreign_exports.lua.xrecord.create], 'lua'), 'xrecord.handle')
        spec.nil_value(foreign.returns(rec.nodes[handle.get], 'lua'))
    end)
end)

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

spec.describe('kotlin', function()
    spec.it('extracts packages, primary properties, objects, interfaces and expression functions', function()
        local r = ci.parse('Box.kt', [[package demo.model
import demo.api.load as fetch
import demo.shared.*
@Serializable
data class Box<T>(val value: T, private var size: Int = initial()) : Base(), Sized {
    companion object { fun create(): Box<Int> = Box(1) }
    override fun count(): Int = size
    fun work(n: Int = initial()): Int {
        fun localHelper() = fetch()
        return localHelper() + count()
    }
    val label: String
        get() = render()
}
interface Sized { fun count(): Int }
sealed class Base
object Registry { val box = Box(2) }
typealias Identifier = String
fun String.trimmed(): String = trim()
]])
        local n = names(r)
        spec.contains(n, 'class demo.model.Box@4')
        spec.contains(n, 'property demo.model.Box.value@5')
        spec.contains(n, 'class demo.model.Box.Companion@6')
        spec.contains(n, 'method demo.model.Box.Companion.create@6')
        spec.equal(r.package, 'demo.model')
        spec.equal(r.imports[1].alias, 'fetch')
        spec.equal(r.imports[2].path, 'demo.shared.*')
        spec.contains(n, 'function demo.model.Box.work.localHelper@9')
        spec.contains(n, 'interface demo.model.Sized@15')
        spec.contains(n, 'class demo.model.Base@16')
        spec.contains(n, 'class demo.model.Registry@17')
        spec.contains(n, 'typedef demo.model.Identifier@18')
        spec.contains(n, 'function demo.model.trimmed@19')
        spec.contains(refs(r), 'localHelper->fetch')
        spec.contains(refs(r), 'label->render')
        spec.contains(refs(r), 'work->initial')
    end)
    spec.it('keeps multiline expressions, generic calls, lambdas and escaped identifiers', function()
        local src = [[/* outer /* fun phantom() {} */ still comment */
fun <T> collect(block: () -> T): T = block()
fun `odd name`(): String = """fun fake() { }"""
fun run() = collect<String> {
    helper()
}
fun more(): Int =
    first() +
    second()
val text = "fake()"
enum class State { OPEN, CLOSED; fun label() = name }
]]
        local r = ci.parse('script.kts', src)
        spec.contains(names(r), 'function collect@2')
        spec.contains(names(r), 'function odd name@3')
        spec.contains(names(r), 'function more@7')
        spec.contains(names(r), 'enum_member State.CLOSED@11')
        spec.contains(refs(r), 'run->collect')
        spec.contains(refs(r), 'run->helper')
        spec.contains(refs(r), 'more->second')
        spec.truthy(not names(r):find('phantom') and not names(r):find('fake'))
        spec.truthy(not refs(r):find('fake'))
        for _, n in ipairs(r.nodes) do
            if n.name == 'odd name' then spec.equal(src:sub(n.name_start + 1, n.name_end), n.name) end
        end
    end)
    spec.it('does not let nested template quotes or accessor syntax swallow following declarations', function()
        local src = [==[val label = "${render("}", "${nested("{")}")}"
val raw = """${render("\"", "}")} fun phantom() {}"""
val String.last: Char get() = get(lastIndex)
typealias Callback<T> = (T) -> Unit
class Item(val size: Int) {
    init { register() }
    constructor() : this(1) { finish() }
}
fun real() = label
]==]
        local r = ci.parse('Templates.kt', src)
        spec.contains(names(r), 'variable last@3')
        spec.contains(names(r), 'typedef Callback@4')
        spec.contains(names(r), 'constructor Item.Item@7')
        spec.contains(names(r), 'function real@9')
        spec.truthy(not names(r):find('phantom'))
        spec.truthy(not refs(r):find('render') and not refs(r):find('%->init'))
        spec.contains(refs(r), 'Item->register')
        spec.contains(refs(r), 'Item->finish')
        for _, node in ipairs(r.nodes) do spec.truthy(node.end_byte <= #src) end
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
        local Q = graph_mod.query(G)
        for id in pairs(G.nodes) do
            local list = Q.out[id]
            for i = 1, #list, graph_mod.EDGE do es[#es + 1] = G.nodes[id].qualified .. '->' .. G.nodes[list[i]].qualified end
        end
        table.sort(es)
        return table.concat(es, ' ')
    end

    spec.it('Kotlin package, explicit, wildcard and aliased imports connect both directions', function()
        local G = build({
            ['model/Service.kt'] = 'package api\nfun execute() = helper()\nfun helper() = 1',
            ['client/Main.kt'] = 'package client\nimport api.execute as dispatch\nfun run() = dispatch()',
            ['client/Other.kt'] = 'package client\nimport api.*\nfun other() = execute()',
            ['unrelated/False.kt'] = 'package unrelated\nfun dispatch() = 0\nfun execute() = 0',
        })
        local Q = graph_mod.query(G)
        local id = G.by_qualified['api.execute'][1]
        local run = G.by_qualified['client.run'][1]
        spec.equal(Q.out[run][1], id)
        spec.equal(Q.out[G.by_qualified['client.other'][1]][1], id)
        spec.equal(#Q.inn[id], 2 * graph_mod.EDGE)
        spec.equal(Q.out[id][1], G.by_qualified['api.helper'][1])
    end)
    spec.it('C++ static members stay callable from other files', function()
        local G = build({ ['api.hpp'] = 'struct Api { static void work() {} };',
            ['main.cpp'] = '#include "api.hpp"\nvoid run() { Api::work(); }' })
        spec.equal(all_edges(G), 'run->Api::work')
    end)
    spec.it('resolves relative C includes against the including file', function()
        local G = build({ ['3rd/mini.h'] = 'int push(int b) { return b; }',
            ['other/mini.h'] = 'int push(int b) { return -b; }',
            ['xlua/net.c'] = '#include "../3rd/mini.h"\nint run(void) { return push(1); }' })
        local Q = graph_mod.query(G)
        local out = Q.out[G.by_name.run[1]]
        spec.equal(#out, graph_mod.EDGE)
        spec.equal(G.files[G.node_file[out[1]]].path, '3rd/mini.h')
    end)
    spec.it('static inline helpers in an included header are visible to the includer', function()
        local G = build({ ['queue.h'] = 'static inline void queue_init(int *q) { *q = 0; }',
            ['other.h'] = 'static inline void queue_init(int *q) { *q = 1; }',
            ['thread.c'] = '#include "queue.h"\nvoid start(void) { int q; queue_init(&q); }' })
        local Q = graph_mod.query(G)
        local out = Q.out[G.by_name.start[1]]
        spec.equal(#out, graph_mod.EDGE)
        spec.equal(G.files[G.node_file[out[1]]].path, 'queue.h')
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
    local Q = graph.query(G)
    for _, id in ipairs(G.by_name[name] or {}) do
        local list = Q.out[id] or {}
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

-- Symbol tables with ids replaced by path#node and path, for comparing tables
-- maintained per file against a fresh build of the same records.
local function canonical_tables(G)
    local function node(id) return G.files[G.node_file[id]].path .. '#' .. (id - G.id_of[G.node_file[id]][1] + 1) end
    local function file(f) return G.files[f].path end
    local out = {}
    local function dump(label, t, map)
        local keys = {}
        for key in pairs(t) do keys[#keys + 1] = tostring(key) end
        table.sort(keys)
        for _, key in ipairs(keys) do
            local list, names = t[key] or t[tonumber(key)], {}
            for i, v in ipairs(list) do names[i] = map(v) end
            out[#out + 1] = label .. '[' .. key .. ']=' .. table.concat(names, ',')
        end
    end
    for _, name in ipairs({ 'by_name', 'by_lname', 'by_qualified', 'by_owner' }) do dump(name, G[name], node) end
    for _, name in ipairs({ 'by_base', 'by_stem', 'dir_files', 'pkg_files', 'ns_files' }) do dump(name, G[name], file) end
    dump('dir_by_base', G.dir_by_base, function(d) return d end)
    local children = {}
    for parent, list in pairs(G.children) do children[node(parent)] = list end
    dump('children', children, node)
    local order, dirs = {}, {}
    for i, f in ipairs(G.file_order) do order[i] = file(f) end
    out[#out + 1] = 'order=' .. table.concat(order, ',')
    for _, f in ipairs(G.file_order) do
        local same = {}
        for _, g in ipairs(G.file_order) do if G.file_dir[g] == G.file_dir[f] then same[#same + 1] = file(g) end end
        dirs[#dirs + 1] = file(f) .. ':' .. table.concat(same, '|')
    end
    out[#out + 1] = 'dirs=' .. table.concat(dirs, ',')
    out[#out + 1] = 'counts=' .. G.file_count .. '/' .. G.node_count
    return table.concat(out, '\n')
end

spec.describe('query-time relationships', function()
    spec.it('batches all caller names into one scan and caches per query', function()
        local _, symbols = svc.get(tmp_root, { cache_path = cache })
        local lazy = graph.query(symbols)
        spec.equal(symbols.out, nil); spec.equal(symbols.inn, nil); spec.equal(symbols.deps, nil)
        local ids = {}
        for id in pairs(symbols.nodes) do ids[#ids + 1] = id end
        lazy:load_incoming(ids)
        lazy:load_incoming(ids)
        spec.equal(lazy.stats.incoming_scans, 1)
        local net_send = symbols.by_name.net_send
        local callers = {}
        for _, id in ipairs(net_send) do
            local inn = lazy.inn[id]
            for i = 1, #inn, graph.EDGE do callers[#callers + 1] = symbols.nodes[inn[i]].name end
        end
        table.sort(callers)
        spec.equal(table.concat(callers, ','), 'area,run')
        spec.equal(symbols.out, nil)
        local fresh = graph.query(symbols)
        spec.equal(next(fresh.out), nil); spec.equal(next(fresh.inn), nil)
    end)
    spec.it('resolves calls in every parser language', function()
        local samples = {
            ['calls.c'] = 'int target(void) { return 1; } int entry(void) { return target(); }',
            ['calls.cpp'] = 'struct Box { int target() { return 1; } int entry() { return this->target(); } };',
            ['calls.py'] = 'def target():\n    return 1\ndef entry():\n    return target()\n',
            ['calls.lua'] = 'function target() return 1 end function entry() return target() end',
            ['calls.java'] = 'class Box { int target() { return 1; } int entry() { return target(); } }',
            ['calls.go'] = 'package main\nfunc target() int { return 1 }\nfunc entry() int { return target() }',
            ['calls.ts'] = 'function target() { return 1; } function entry() { return target(); }',
            ['calls.cs'] = 'class Box { int target() { return 1; } int entry() { return this.target(); } }',
            ['calls.rs'] = 'fn target() -> i32 { 1 } fn entry() -> i32 { target() }',
        }
        for path, source in pairs(samples) do
            local G = graph.build({ generation = 1, files = { [path] = ci.parse(path, source) } })
            local Q, entry = graph.query(G), nil
            for _, id in ipairs(G.by_name.entry) do entry = id end
            local out = Q.out[entry]
            spec.equal(#out, graph.EDGE, path)
            spec.equal(G.nodes[out[1]].name, 'target', path)
            local inn = Q.inn[out[1]]
            spec.equal(inn[1], entry, path)
        end
    end)
    spec.it('keeps per-file symbol tables identical to a fresh build', function()
        local function rec(path, source) return ci.parse(path, source, { ranges = false }) end
        local idx = { generation = 0, files = {
            ['b/m.lua'] = rec('b/m.lua', 'function shared() end function b_only() end'),
            ['d/x.cs'] = rec('d/x.cs', 'namespace N { class C { void M() {} } }'),
            ['a.c'] = rec('a.c', 'int shared(void) { return 0; }'),
        } }
        local G = graph.build(idx)
        local steps = {
            { 'c/new.py', 'def shared():\n    pass\nclass K:\n    def m(self):\n        return shared()\n' },
            { 'a.c', 'int renamed(void) { return 0; } int shared(void) { return renamed(); }' },
            { 'b/m.lua', nil },
            { 'aa/first.java', 'package p; class Shared { void shared() {} }' },
            { 'd/y.cs', 'namespace N { class D {} } namespace N { class E {} }' },
            { 'd/x.cs', nil },
            { 'b/m.lua', 'function back() end' },
            { 'c/new.py', 'def shared():\n    pass\n' },
        }
        for _, step in ipairs(steps) do
            local path, source = step[1], step[2]
            if idx.files[path] then graph.remove_file(G, path) end
            idx.files[path] = source and rec(path, source) or nil
            if source then graph.add_file(G, path, idx.files[path]) end
            spec.equal(canonical_tables(G), canonical_tables(graph.build(idx)), 'after ' .. path)
        end
        spec.equal(graph.before(G, G.by_name.shared[1], G.by_name.shared[2]), true)
    end)
    spec.it('commits index files with their symbol tables and no cancellation checkpoint', function()
        local idx = svc.refresh(tmp_root, { cache_path = cache })
        local G = idx:symbols()
        local generation = idx.generation
        local control = require('codeoutline.control')
        control.callback = function() error(control.cancelled(), 0) end
        local ok, err = pcall(function()
            idx:commit('commit_probe.lua', ci.parse('commit_probe.lua', 'function commit_probe() end', { ranges = false }))
        end)
        control.callback = nil
        assert(ok, err)
        spec.equal(idx.generation, generation + 1); spec.equal(G.generation, idx.generation)
        spec.truthy(G.by_name.commit_probe); spec.equal(idx:symbols(), G)
        spec.equal(canonical_tables(G), canonical_tables(graph.build(idx)))
        idx:commit('commit_probe.lua', nil)
        spec.nil_value(G.by_name.commit_probe)
        -- A failed table update drops the tables; the next use rebuilds them.
        local add = graph.add_file
        graph.add_file = function() error('broken tables') end
        idx:commit('commit_probe.lua', ci.parse('commit_probe.lua', 'function commit_probe() end', { ranges = false }))
        graph.add_file = add
        spec.nil_value(idx.symbol_tables)
        spec.truthy(idx:symbols().by_name.commit_probe)
        idx:commit('commit_probe.lua', nil)
    end)
    spec.it('updates symbol tables in place after an edit', function()
        local path = tmp_root .. '/lazy_change.lua'
        write(path, 'function lazy_caller() return previous() end function previous() end')
        local before = svc.explore(tmp_root, 'lazy_caller previous', { cache_path = cache })
        spec.contains(before, 'lazy_caller -> previous')
        local idx, old = svc.resident(tmp_root)
        write(path, 'function lazy_caller() return replacement() end function replacement() end')
        local after = svc.explore(tmp_root, 'lazy_caller replacement', { cache_path = cache })
        spec.contains(after, 'lazy_caller -> replacement')
        spec.truthy(not after:find('previous', 1, true))
        local _, current = svc.resident(tmp_root)
        spec.equal(current, old); spec.equal(current.out, nil); spec.nil_value(current.by_name.previous)
        spec.equal(canonical_tables(current), canonical_tables(graph.build(idx)))
        os.remove(path)
    end)
    spec.it('reports expansion limits and never publishes cancelled caller scans', function()
        local idx = svc.refresh(tmp_root, { cache_path = cache })
        local symbols = graph.build(idx)
        local output, info = explore.run(symbols, idx, 'run net_send', { max_expanded = 1 })
        spec.truthy(info.relationships_incomplete); spec.truthy(info.truncated)
        spec.contains(output, 'relationships are incomplete')
        local lazy = graph.query(symbols)
        local control = require('codeoutline.control')
        control.callback = function() error(control.cancelled(), 0) end
        local ok, err = pcall(lazy.load_incoming, lazy, { symbols.by_name.net_send[1] })
        control.callback = nil
        spec.equal(ok, false); spec.truthy(control.is_interrupted(err))
        spec.equal(next(lazy.inn), nil)
        lazy:load_incoming({ symbols.by_name.net_send[1] })
        spec.truthy(#lazy.inn[symbols.by_name.net_send[1]] > 0)
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

spec.describe('JS module and receiver resolution', function()
    local function build(files, root)
        local records = {}
        for path, source in pairs(files) do records[path] = ci.parse(path, source) end
        return graph.build({ root = root, files = records })
    end
    spec.it('binds renamed, default and namespace imports through explicit exports', function()
        local G = build({
            ['a.ts'] = 'export function save() {}\nexport default function main() {}',
            ['barrel.ts'] = "export { save as store, default } from './a';",
            ['b.ts'] = 'export function save() {}\nexport function store() {}\nexport function main() {}',
            ['use.ts'] = "import boot, { store as persist } from './barrel';\nimport * as api from './a';\nfunction run() { persist(); boot(); api.save(); }",
        })
        spec.equal(edges_from(G, 'run'), 'main@a.ts save@a.ts save@a.ts')
        local Q = graph.query(G)
        spec.equal(#Q.inn[G.by_name.save[1]], 6)
    end)
    spec.it('uses constructor and parameter types instead of same-named methods', function()
        local G = build({
            ['a.ts'] = 'export class Store { save() {} }',
            ['b.ts'] = 'export class Store { save() {} }',
            ['use.ts'] = "import { Store as Chosen } from './b';\nfunction run() { const s = new Chosen(); s.save(); }\nfunction typed(s: Chosen) { s.save(); }",
        })
        spec.contains(edges_from(G, 'run'), 'save@b.ts')
        spec.truthy(not edges_from(G, 'run'):find('save@a.ts', 1, true))
        spec.equal(edges_from(G, 'typed'), 'save@b.ts')
    end)
    spec.it('resolves default classes, namespace types and local export aliases', function()
        local G = build({
            ['lib.ts'] = 'class Store { save() {} }\nfunction actual() {}\nexport { Store as default, Store as Other, actual as renamed };',
            ['use.ts'] = "import Selected from './lib'; import * as api from './lib';\nfunction run(s: Selected, t: api.Other) { s.save(); t.save(); api.renamed(); }",
        })
        spec.equal(edges_from(G, 'run'), 'actual@lib.ts save@lib.ts save@lib.ts')
        spec.equal(#graph.query(G).inn[G.by_name.actual[1]], 3)
    end)
    spec.it('rejects unresolved imports, missing members, shadowing and reassignment', function()
        local G = build({
            ['a.ts'] = 'export class Store { save() {} }\nexport function absent() {}',
            ['use.ts'] = [[import { Store } from './a';
import { absent } from './missing';
function run() { absent(); const s = new Store(); s.missing(); s = unknown; s.save(); }
function shadow(Store) { Store.save(); }
function block() { const s = new Store(); { const s = unknown; s.save(); } }
function chained() { const s = new Store(); other.s.save(); factory().save(); }
]],
            ['false.ts'] = 'export function missing() {}\nexport class Wrong { save() {} }',
        })
        spec.equal(edges_from(G, 'run'), 'Store@a.ts')
        spec.equal(edges_from(G, 'shadow'), '')
        spec.equal(edges_from(G, 'block'), 'Store@a.ts')
        spec.equal(edges_from(G, 'chained'), 'Store@a.ts')
    end)
    spec.it('retains ambiguous star exports and terminates export cycles', function()
        local G = build({
            ['a.ts'] = 'export function save() {}', ['b.ts'] = 'export function save() {}',
            ['barrel.ts'] = "export * from './a'; export * from './b'; export * from './cycle';",
            ['cycle.ts'] = "export * from './barrel';",
            ['use.ts'] = "import { save } from './barrel'; function run() { save(); }",
        })
        spec.equal(edges_from(G, 'run'), 'save@a.ts save@b.ts')
    end)
    spec.it('preserves local callable bindings and nested function shadowing', function()
        local G = build({
            ['lib.ts'] = 'export function work() {}',
            ['use.ts'] = [[import { work } from './lib';
const arrow = () => {};
function run() { arrow(); function work() {} work(); }
function elsewhere() { work(); }
]],
        })
        spec.equal(edges_from(G, 'run'), 'arrow@use.ts work@use.ts')
        spec.equal(edges_from(G, 'elsewhere'), 'work@lib.ts')
    end)
    spec.it('resolves inherited JSONC paths and reloads config without reparsing', function()
        local root = tmp_root .. '/js_aliases'
        write(root .. '/config/base.json', [[{ // paths are relative to this config
          "compilerOptions": { "paths": { "@/*": ["../src/*"], "@/special": ["../alternate"], }, },
        }]])
        write(root .. '/tsconfig.json', '{"extends":"./config/base"}')
        local G = build({
            ['src/api.ts'] = 'export function save() {}',
            ['alternate.ts'] = 'export function save() {}',
            ['use.ts'] = "import { save as chosen } from '@/api'; function run() { chosen(); }",
            ['special.ts'] = "import { save } from '@/special'; function special() { save(); }",
        }, root)
        spec.equal(edges_from(G, 'run'), 'save@src/api.ts')
        spec.equal(edges_from(G, 'special'), 'save@alternate.ts')
        write(root .. '/tsconfig.json', '{"compilerOptions":{"paths":{"@/*":["alternate.ts"]}}}')
        spec.equal(edges_from(G, 'run'), 'save@alternate.ts')
    end)
    spec.it('keeps bindings through cache reload and updates changed export targets', function()
        local root = tmp_root .. '/js_cache'
        write(root .. '/a.ts', 'export function save() {}')
        write(root .. '/b.ts', 'export function save() {}')
        write(root .. '/barrel.ts', "export { save as persist } from './a';")
        write(root .. '/use.ts', "import { persist } from './barrel'; function run() { persist(); }")
        local options = { cache_path = root .. '/cache.bin', lister = 'walk' }
        local idx, G = svc.get(root, options); idx:save(); svc.forget(root)
        idx, G = svc.get(root, options)
        spec.equal(edges_from(G, 'run'), 'save@a.ts')
        write(root .. '/barrel.ts', "export { save as persist } from './b';")
        idx, G = svc.get(root, options)
        spec.equal(edges_from(G, 'run'), 'save@b.ts')
        svc.forget(root)
    end)
end)

spec.describe('Lua module return bindings', function()
    local function build(files, root)
        local records = {}
        for path, source in pairs(files) do records[path] = ci.parse(path, source) end
        return graph.build({ root = root, files = records })
    end
    spec.it('pins dofile receivers to returned tables, including normalized paths', function()
        local G = build({
            ['a.lua'] = 'local M = {}\nfunction M.save() end\nreturn M',
            ['b.lua'] = 'local M = {}\nfunction M.save() end\nreturn M',
            ['nested/main.lua'] = "local a = dofile('./folder/../a.lua')\nlocal b = dofile('b.lua')\nfunction run() a.save() end\nfunction other() b:save() end",
        })
        spec.equal(edges_from(G, 'run'), 'save@a.lua')
        spec.equal(edges_from(G, 'other'), 'save@b.lua')
        spec.equal(#graph.query(G).inn[G.by_name.save[1]], 3)
    end)
    spec.it('resolves require and returned table aliases to their actual functions', function()
        local G = build({
            ['scripts/lib.lua'] = 'local function actual() end\nreturn { save = actual, close = function() end }',
            ['main.lua'] = "local lib = require 'lib'\nfunction run() lib.save(); lib.close() end",
        })
        spec.equal(edges_from(G, 'run'), 'actual@scripts/lib.lua close@scripts/lib.lua')
        spec.equal(#graph.query(G).inn[G.by_name.actual[1]], 3)
    end)
    spec.it('does not infer dynamic paths, loadfile tables or shadowed loaders and receivers', function()
        local G = build({
            ['a.lua'] = 'local M = {}\nfunction M.save() end\nreturn M',
            ['main.lua'] = [[local a = dofile('a.lua')
local dynamic = dofile('a.lua' .. suffix)
local chunk = loadfile('a.lua')
function run(a) a.save() end
function unknown() dynamic.save(); chunk.save() end
function shadow() local a = {}; a.save() end
function replaced() local a = dofile('a.lua'); a = other; a.save() end
function custom(dofile) local a = dofile('a.lua'); a.save() end
]],
        })
        for _, name in ipairs({ 'run', 'unknown', 'shadow', 'replaced', 'custom' }) do spec.equal(edges_from(G, name), '') end
    end)
    spec.it('rejects conditional returns and replaced module tables', function()
        local G = build({
            ['a.lua'] = 'local M = {}\nfunction M.save() end\nif flag then return M end\nreturn M',
            ['b.lua'] = 'local M = {}\nfunction M.save() end\nM = factory()\nreturn M',
            ['main.lua'] = "local a = dofile('a.lua')\nlocal b = dofile('b.lua')\nfunction run() a.save(); b.save() end",
        })
        spec.equal(edges_from(G, 'run'), '')
    end)
    spec.it('does not reset invalid return state or fall back to __exports', function()
        for _, source in ipairs({
            'local M = {}\nfunction M.save() end\nif flag then return M end',
            'local M = {}\nfunction M.save() end\nif flag then return M end\nreturn M',
            'local M = {}\nfunction M.save() end\nreturn M\nreturn M',
            'function __exports.save() end\nif flag then return {} end',
        }) do
            local parsed = ci.parse('a.lua', source)
            spec.equal(next(parsed.lua_exports or {}), nil)
            local G = build({
                ['a.lua'] = source,
                ['main.lua'] = "local a = dofile('a.lua')\nfunction run() a.save() end",
            })
            spec.equal(edges_from(G, 'run'), '')
        end
    end)
    spec.it('reloads the configured runtime directory and preserves cache bindings', function()
        local root = tmp_root .. '/lua_bindings'
        write(root .. '/a.lua', 'local M = {}\nlocal function actual() end\nM.save = actual\nreturn M')
        write(root .. '/sub/a.lua', 'return { save = function() end }')
        write(root .. '/main.lua', "local a = dofile('a.lua')\nfunction run() a.save() end")
        local options = { cache_path = root .. '/cache.bin', lister = 'walk' }
        local idx, G = svc.get(root, options); idx:save(); svc.forget(root)
        idx, G = svc.get(root, options)
        spec.equal(edges_from(G, 'run'), 'actual@a.lua')
        write(root .. '/.codeoutline.json', '{"luaRuntimeDirectory":"sub"}')
        spec.equal(edges_from(G, 'run'), 'save@sub/a.lua')
        write(root .. '/sub/a.lua', 'return {}')
        idx, G = svc.get(root, options)
        spec.equal(edges_from(G, 'run'), '')
        svc.forget(root)
    end)
    spec.it('keeps same-file local table scopes separate and tolerates incomplete tables', function()
        local G = build({ ['main.lua'] = [[local M = {}
function M.save() end
function run() local M = {}; M.save() end
function valid() M.save() end
return M
]] })
        spec.equal(edges_from(G, 'run'), '')
        spec.equal(edges_from(G, 'valid'), 'save@main.lua')
        local incomplete = ci.parse('broken.lua', 'local M = {\nreturn M')
        spec.equal(next(incomplete.lua_exports), nil)
    end)
    spec.it('binds a member defined directly after a sibling block closes', function()
        local G = build({
            ['main.lua'] = 'local M = {}\nfunction M.save(x) return M.helper(x) end\nfunction M.helper(x) return x end\nreturn M\n',
        })
        spec.equal(edges_from(G, 'save'), 'helper@main.lua')
        local nested = build({
            ['other.lua'] = 'local M = {}\nfunction M.first() do local x = 1 end end\nfunction M.save() M.first() end\nreturn M\n',
        })
        spec.equal(edges_from(nested, 'save'), 'first@other.lua')
        local shadowed = build({
            ['deep.lua'] = 'local M = {}\nfunction M.save() end\n'
                .. 'function run() local M = {} do local x = 1 end function M.save() end M.save() end\nreturn M\n',
        })
        spec.equal(edges_from(shadowed, 'run'), 'save@deep.lua')
    end)
    spec.it('publishes g_exports aliases as bare global names', function()
        local G = build({
            ['modules/phantom.lua'] = 'do\n\tlocal function design_list(p) return p end\n'
                .. '\tg_exports.phantom_get_design_list = design_list\n'
                .. '\tg_exports.phantom_called = design_list()\n'
                .. '\t__exports.phantom_module_only = design_list\nend\n',
            ['client.lua'] = 'function use(p) return phantom_get_design_list(p) + phantom_called(p)'
                .. ' + phantom_module_only(p) end\n',
        })
        spec.equal(edges_from(G, 'use'), 'design_list@modules/phantom.lua')
        spec.equal(#G.by_name.phantom_get_design_list, 1)
        spec.equal(G.by_name.phantom_called, nil)
        spec.equal(G.by_name.phantom_module_only, nil)
        local shadow = build({
            ['stub.lua'] = 'local function empty_func() end\ng_exports.app_on_windows = empty_func\n',
            ['real.lua'] = 'function app_on_windows() end\n',
            ['main.lua'] = 'function run() app_on_windows() end\n',
        })
        spec.equal(edges_from(shadow, 'run'), 'app_on_windows@real.lua')
        local literal_key = build({
            ['server/redis.lua'] = "local function sync_call() end\ng_exports['__game_redis_call'] = sync_call\n",
            ['server/task.lua'] = 'function query() return __game_redis_call() end\n',
        })
        spec.equal(edges_from(literal_key, 'query'), 'sync_call@server/redis.lua')
    end)
    spec.it('drops overwritten global aliases and removes them with their file', function()
        local G = build({
            ['exports.lua'] = 'local function impl() end\ng_exports.kept = impl\n'
                .. 'g_exports.removed = impl\ng_exports.removed = nil\n',
            ['private.lua'] = 'local g_exports = {}\nlocal function impl() end\ng_exports.private_alias = impl\n',
        })
        spec.equal(#G.by_name.kept, 1)
        spec.equal(G.by_name.removed, nil)
        spec.equal(G.by_name.private_alias, nil)
        graph.remove_file(G, 'exports.lua')
        spec.equal(G.by_name.kept, nil)
        graph.add_file(G, 'exports.lua', ci.parse('exports.lua', 'local function impl() end\ng_exports.replaced = impl\n'))
        spec.equal(#G.by_name.replaced, 1)
        spec.equal(G.by_name.kept, nil)
    end)
    spec.it('configures global export tables across cached and resident indexes', function()
        local root = tmp_root .. '/global_export_config'
        write(root .. '/exports.lua', 'local function impl() end\ncustom_exports.custom_export = impl\n'
            .. 'g_exports.default_export = impl\nother_exports.custom_export = impl\n')
        write(root .. '/main.lua', 'function run() custom_export() end\n')
        local options = { cache_path = root .. '/cache.bin', lister = 'walk' }
        local idx, G = svc.get(root, options)
        spec.equal(G.by_name.custom_export, nil)
        spec.equal(#G.by_name.default_export, 1)
        assert(idx:save()); svc.forget(root)
        write(root .. '/.codeoutline.json', '{"luaGlobalExportTables":["custom_exports","other_exports","custom_exports"]}')
        idx, G = svc.get(root, options)
        spec.equal(idx.cache_loaded, true)
        spec.equal(#G.by_name.custom_export, 1)
        spec.equal(G.by_name.default_export, nil)
        spec.equal(edges_from(G, 'run'), 'impl@exports.lua')
        write(root .. '/.codeoutline.json', '{"luaGlobalExportTables":[]}')
        G = idx:symbols()
        spec.equal(G.by_name.custom_export, nil)
        spec.equal(G.by_name.default_export, nil)
        for _, value in ipairs({ '"g_exports"', '[1]', '["g.exports"]', '{"bad":"g_exports"}' }) do
            write(root .. '/.codeoutline.json', '{"luaGlobalExportTables":' .. value .. '}')
            local ok, err = pcall(function() idx:symbols() end)
            spec.equal(ok, false)
            spec.truthy(tostring(err):find('luaGlobalExportTables', 1, true))
        end
        os.remove(root .. '/.codeoutline.json')
        G = idx:symbols()
        spec.equal(#G.by_name.default_export, 1)
        spec.equal(G.by_name.custom_export, nil)
        svc.forget(root)
    end)
    spec.it('binds a quoted loader path that lives deeper than the workspace root', function()
        local G = build({
            ['vendor/lib/a.lua'] = 'local M = {}\nfunction M.save() end\nreturn M\n',
            ['app/main.lua'] = "local a = dofile('lib/a.lua')\nfunction run() a.save() end",
        })
        spec.equal(edges_from(G, 'run'), 'save@vendor/lib/a.lua')
        local missing = build({
            ['vendor/other/a.lua'] = 'local M = {}\nfunction M.save() end\nreturn M\n',
            ['app/main.lua'] = "local a = dofile('lib/a.lua')\nfunction run() a.save() end",
        })
        spec.equal(edges_from(missing, 'run'), '')
    end)
    spec.it('prefers exact loader paths before suffix candidates', function()
        local G = build({
            ['lib/a.lua'] = 'local M = {}\nfunction M.save() end\nreturn M',
            ['vendor/lib/a.lua'] = 'local M = {}\nfunction M.save() end\nreturn M',
            ['app.lua'] = "local a = dofile('lib/a.lua')\nfunction run() a.save() end",
        })
        spec.equal(edges_from(G, 'run'), 'save@lib/a.lua')
    end)
    spec.it('does not retain members from a replaced table or overwritten export', function()
        local G = build({
            ['a.lua'] = 'local M = {}\nfunction M.save() end\nM = {}\nreturn M',
            ['b.lua'] = 'local M = {}\nfunction M.save() end\nM.save = nil\nreturn M',
            ['main.lua'] = "local a = dofile('a.lua')\nlocal b = dofile('b.lua')\nfunction run() a.save(); b.save() end",
        })
        spec.equal(edges_from(G, 'run'), '')
    end)
    spec.it('binds *import pattern loaders to existing files, by suffix when needed', function()
        local G = build({
            ['mods/lib.lua'] = 'local M = {}\nfunction M.save() end\nreturn M',
            ['pub/deep/other.lua'] = 'local M = {}\nfunction M.close() end\nreturn M',
            ['main.lua'] = "local a = ks.import('mods/lib.lua')\nlocal b = skynet_import('deep/other.lua')\n"
                .. "local missing = qq.import('nope/lib.lua')\n"
                .. "function run() a.save(); b.close(); missing.save() end",
        })
        spec.equal(edges_from(G, 'run'), 'close@pub/deep/other.lua save@mods/lib.lua')
    end)
    spec.it('resolves return-less __exports modules through pattern loaders', function()
        local G = build({
            ['svc.lua'] = 'local function impl() end\n__exports.direct = function() end\nfunction __exports.named() end\n'
                .. '__exports.plain = impl\n__exports.value = 5\n',
            ['main.lua'] = "local svc = ks.import('svc.lua')\nfunction run() svc.direct(); svc.named(); svc.plain(); svc.value() end",
        })
        spec.equal(edges_from(G, 'run'), 'direct@svc.lua impl@svc.lua named@svc.lua')
    end)
    spec.it('does not apply the __exports contract when the file owns the name or returns a table', function()
        local G = build({
            ['a.lua'] = 'local __exports = {}\nfunction __exports.save() end\n',
            ['b.lua'] = 'local M = {}\nfunction M.save() end\n__exports.other = function() end\nreturn M',
            ['main.lua'] = "local a = dofile('a.lua')\nlocal b = dofile('b.lua')\nfunction run() a.save(); b.other() end",
        })
        spec.equal(edges_from(G, 'run'), '')
    end)
end)

spec.describe('configured indirect dispatch', function()
    spec.it('preserves dispatch sites and node identities in query-only parsing', function()
        local sources = {
            ['a.lua'] = "local m = require('mod')\nfunction outer() local function inner() schedule(1, done) end; bus.emit('tick'); pcall(m.run) end\nbus.on('tick', outer)",
            ['a.ts'] = "import {done} from './mod'; function outer() { schedule(1, done); const inner = () => bus.emit('tick'); } bus.on('tick', outer);",
            ['a.c'] = "void done(void) {}\nvoid run(void) { schedule(1, &done); schedule(2, choose()); }",
            ['a.py'] = "def run():\n    schedule(1, done)\nbus.on('tick', run)\n",
            ['a.kt'] = "fun run() { schedule(1, done); bus.emit(\"tick\") }",
        }
        local function signature(r)
            local rows = { names(r) }
            for _, site in ipairs(r.dispatch_sites or {}) do
                local row = { site.call, tostring(site.from), tostring(site.line) }
                for _, arg in ipairs(site.args) do
                    row[#row + 1] = arg and (arg.literal and 'literal:' .. arg.literal or 'symbol:' .. arg.symbol) or 'false'
                end
                rows[#rows + 1] = table.concat(row, '|')
            end
            return table.concat(rows, '\n')
        end
        for path, source in pairs(sources) do
            local full = ci.parse(path, source, { ranges = false, dispatch = true })
            local fast = ci.parse(path, source, { ranges = false, dispatch = true, dispatch_only = true })
            spec.equal(signature(fast), signature(full), path)
            spec.equal(fast.lua_imports, nil)
            spec.equal(fast.js_imports, nil)
        end
    end)
    spec.it('parses each candidate once across callback rules beyond the FIFO limit', function()
        local root = tmp_root .. '/dispatch_batch'
        for i = 1, 20 do
            write(root .. '/' .. i .. '.lua', 'function handler' .. i .. '() end\nfunction run' .. i .. '() first(handler' .. i .. '); second(handler' .. i .. ') end')
        end
        local _, G = svc.get(root, { cache_path = root .. '/cache.bin' })
        local original, count = ci.parse, 0
        ci.parse = function(...) count = count + 1; return original(...) end
        local ok, err = pcall(function()
            local Q = graph.query(G, { dispatch_rules = {
                { kind = 'callback', call = 'first', argument = 1 },
                { kind = 'callback', call = 'second', argument = 1 },
            } })
            local ids = {}
            for i = 1, 20 do ids[i] = G.by_name['handler' .. i][1] end
            Q:load_incoming(ids)
            for _, id in ipairs(ids) do spec.equal(#Q.inn[id], 6) end
            spec.equal(count, 20)
        end)
        ci.parse = original
        svc.forget(root)
        assert(ok, err)
    end)
    local rules = {
        { kind = 'event', language = 'lua', call = 'bus.emit', argument = 1,
            register = 'bus.on', keyArgument = 1, handlerArgument = 2 },
        { kind = 'callback', call = 'schedule', argument = 2 },
        { kind = 'target', call = 'worker.post', argument = 2 },
    }
    local function dispatch_parse(path, source)
        return ci.parse(path, source, { dispatch = true })
    end
    local function symbols()
        return graph.build({ files = {
            ['send.lua'] = dispatch_parse('send.lua', [[
function send() bus.emit('tick'); other.emit('tick'); bus.emit(dynamic) end
function later() schedule(make(1, 2), handle) end
function post() worker.post(1, 'handle') end
function ignored() schedule(1, object.factory()); worker.post(1, handle) end
]]),
            ['receive.lua'] = dispatch_parse('receive.lua', [[
function handle() finish() end
function finish() end
bus.on('tick', handle)
bus.on('other', finish)
]]),
        } })
    end
    spec.it('connects messages, callbacks and named dispatch in both directions', function()
        local G = symbols()
        local Q = graph.query(G, { dispatch_rules = rules })
        local handle = G.by_name.handle[1]
        for _, name in ipairs({ 'send', 'later', 'post' }) do
            local edges = Q.out[G.by_name[name][1]]
            spec.equal(edges[1], handle)
            spec.contains(edges[3], 'indirect:')
        end
        spec.equal(#Q.inn[handle], 9)
        local ignored = Q.out[G.by_name.ignored[1]]
        for i = 3, #ignored, graph.EDGE do spec.truthy(not ignored[i]:match('^indirect:')) end
        spec.equal(#graph.query(G).out[G.by_name.send[1]], 0)
    end)
    spec.it('shows dispatch evidence and traverses through handlers in explore', function()
        local G = symbols()
        local text = explore.run(G, { root = tmp_root, query_source = function() return '', false end }, 'send handle', { dispatch_rules = rules })
        spec.contains(text, 'indirect:event#1')
        spec.contains(text, 'send -> handle')
        spec.contains(text, 'configured event via bus.emit')
        spec.contains(text, 'registered at receive.lua:3')
        spec.contains(text, 'dispatch argument is dynamic, unsupported or missing')
    end)
    spec.it('keeps explanations query-owned and preserves edges when enabled', function()
        local G = symbols()
        local plain = graph.query(G, { dispatch_rules = rules })
        local explained = graph.query(G, { dispatch_rules = rules, explain = true })
        for _, id in ipairs({ G.by_name.send[1], G.by_name.later[1], G.by_name.ignored[1] }) do
            spec.equal(table.concat(plain.out[id], '|'), table.concat(explained.out[id], '|'))
        end
        spec.equal(plain.report, nil)
        spec.equal(G.report, nil)
        spec.truthy(#explained.report.entries > 0)
        local output = require('codeoutline.query_report').render(explained.report, G)
        spec.contains(output, 'configured callback via schedule')
        spec.contains(output, 'no indexed target')
    end)
    spec.it('reports missing event registrations without inventing an edge', function()
        local G = graph.build({ files = { ['a.lua'] = dispatch_parse('a.lua', "function publish() bus.emit('missing') end") } })
        local Q = graph.query(G, { dispatch_rules = rules, explain = true })
        spec.equal(#Q.out[G.by_name.publish[1]], 0)
        spec.contains(require('codeoutline.query_report').render(Q.report, G), 'no resolved registration for event key')
    end)
    spec.it('reports evidence and path limits independently of output size', function()
        local calls = {}
        for i = 1, 70 do calls[#calls + 1] = 'unknown' .. i .. '()' end
        local source = 'function entry() ' .. table.concat(calls, '; ') .. ' end\n'
            .. 'function alpha() bravo() end\nfunction bravo() charlie() end\n'
            .. 'function charlie() delta() end\nfunction delta() echo() end\n'
            .. 'function echo() foxtrot() end\nfunction foxtrot() end'
        local G = graph.build({ files = { ['a.lua'] = ci.parse('a.lua', source) } })
        local idx = { root = tmp_root, query_source = function() return source, false end }
        local output, info = explore.run(G, idx, 'entry', { budget = 262144 })
        spec.equal(#info.evidence, 64)
        spec.truthy(info.evidence_truncated)
        spec.contains(output, 'Relationship explanations omitted')
        output, info = explore.run(G, idx, 'alpha foxtrot')
        spec.truthy(info.path_search_limited)
        spec.contains(output, 'no path found is not proof')
        output, info = explore.run(G, idx, 'entry', { budget = 256 })
        spec.truthy(#output <= 256); spec.truthy(info.truncated)
        spec.equal(pcall(explore.run, G, { root = tmp_root, query_source = function() return nil end }, 'entry'), false)
    end)
    spec.it('isolates event buses and reads project rules on every query', function()
        local root = tmp_root .. '/dispatch'
        xutils.mkdir_p(root)
        local G = symbols(); G.root = root
        write(root .. '/.codeoutline.json', xutils.json_pack({ dispatchRules = rules }))
        spec.equal(#graph.query(G).out[G.by_name.send[1]], 3)
        write(root .. '/.codeoutline.json', '{"dispatchRules":[]}')
        spec.equal(#graph.query(G).out[G.by_name.send[1]], 0)
        spec.equal(pcall(graph.query, G, { dispatch_rules = {{ kind = 'callback', call = '*.on', argument = 1 }} }), false)
    end)
    spec.it('refreshes registrations without retaining stale edges', function()
        local G = symbols()
        graph.remove_file(G, 'receive.lua')
        graph.add_file(G, 'receive.lua', dispatch_parse('receive.lua', "function replacement() end\nbus.on('tick', replacement)"))
        local Q = graph.query(G, { dispatch_rules = rules })
        spec.equal(Q.out[G.by_name.send[1]][1], G.by_name.replacement[1])
    end)
    spec.it('keeps compact candidates through disk cache and parses sites only on demand', function()
        local root = tmp_root .. '/dispatch_cache'
        write(root .. '/send.lua', "function publish() bus.emit('tick') end")
        write(root .. '/receive.lua', "function consume() return 42 end\nbus.on('tick', consume)")
        write(root .. '/.codeoutline.json', xutils.json_pack({ dispatchRules = rules }))
        local options = { cache_path = root .. '/cache.bin' }
        local idx, G = svc.get(root, options)
        idx:save()
        svc.forget(root)
        idx, G = svc.get(root, options)
        for _, rec in pairs(idx.files) do spec.equal(rec.dispatch_sites, nil) end
        spec.equal(idx.files['send.lua'].dispatch_calls[1], 'bus.emit')
        local output = explore.run(G, idx, 'publish consume')
        spec.contains(output, 'publish -> consume')
        spec.contains(output, 'return 42')
        spec.contains(output, 'indirect:event#1')
        local Q = graph.query(G)
        spec.equal(#Q.inn[G.by_name.consume[1]], 3)
        write(root .. '/receive.lua', "function replacement() return 7 end\nbus.on('tick', replacement)")
        idx, G = svc.get(root, options)
        Q = graph.query(G)
        spec.equal(Q.out[G.by_name.publish[1]][1], G.by_name.replacement[1])
        svc.forget(root)
    end)
    spec.it('does not read sources without rules and fails explicitly for stale candidates', function()
        local root = tmp_root .. '/lazy_sources'
        write(root .. '/a.lua', "function send() bus.emit('tick') end\nfunction handle() end\nbus.on('tick', handle)")
        local idx, G = svc.get(root, { cache_path = root .. '/cache.bin' })
        os.remove(root .. '/a.lua')
        spec.truthy(graph.query(G, { dispatch_rules = {} }).out[G.by_name.send[1]])
        local Q = graph.query(G, { dispatch_rules = rules }) -- construction does not read candidates
        spec.equal(pcall(function() return Q.out[G.by_name.send[1]] end), false)
        svc.forget(root)
    end)
    spec.it('keeps all cross-file event edges after the query cache evicts files', function()
        local root = tmp_root .. '/dispatch_eviction'
        for i = 1, 20 do
            write(root .. '/' .. i .. '.lua', "function send" .. i .. "() bus.emit('tick') end\nfunction handle" .. i .. "() end\nbus.on('tick', handle" .. i .. ")")
        end
        local _, G = svc.get(root, { cache_path = root .. '/cache.bin' })
        local Q = graph.query(G, { dispatch_rules = rules })
        for i = 1, 20 do
            spec.equal(#Q.out[G.by_name['send' .. i][1]], 60)
            spec.equal(#Q.inn[G.by_name['handle' .. i][1]], 60)
        end
        svc.forget(root)
    end)
    spec.it('recognizes C function addresses without inventing dynamic callbacks', function()
        local G = graph.build({ files = { ['cb.c'] = dispatch_parse('cb.c', [[
void done(void) {}
void run(void) { schedule(1, &done); }
void dynamic(void) { schedule(1, choose()); }
]]) } })
        local Q = graph.query(G, { dispatch_rules = { rules[2] } })
        local edges = Q.out[G.by_name.run[1]]
        spec.equal(edges[1], G.by_name.done[1])
        spec.equal(edges[3], 'indirect:callback#1')
        spec.equal(#Q.out[G.by_name.dynamic[1]], 0)
    end)
end)

xutils.rmtree(tmp_root)
os.remove(cache)

spec.describe('recursive callers', function()
    local callers = require('codeoutline.callers')
    spec.it('finds shortest reverse paths, handles cycles and reports depth and node limits', function()
        local sources = {
            ['a.lua'] = 'function leaf() loop() end\nfunction first() leaf() end\nfunction loop() first() end',
            ['b.lua'] = 'function second() first() end\nfunction third() second() end\nfunction fourth() third() end',
        }
        local files = {}
        for path, source in pairs(sources) do files[path] = ci.parse(path, source) end
        local G = graph.build({ files = files })
        local idx = { query_source = function(_, path) return sources[path], false end }
        local output, info = callers.run(G, idx, 'leaf')
        spec.equal(#info.callers, 4) -- first, loop, second, third; leaf is a seed
        spec.equal(info.query_stats.incoming_scans, 3)
        spec.truthy(info.depth_limit_reached)
        spec.equal(#info.files, 2)
        spec.contains(output, 'Depth 3: third')
        spec.truthy(not output:find('fourth', 1, true))
        for _, entry in ipairs(info.callers) do
            spec.equal(#entry.path, entry.depth + 1)
            spec.equal(entry.path[#entry.path].name, 'leaf')
        end
        output, info = callers.run(G, idx, 'leaf', { max_nodes = 1 })
        spec.equal(#info.callers, 1); spec.truthy(info.node_limit_reached)
        spec.contains(output, 'Node limit reached')
        output, info = callers.run(G, idx, 'leaf', { budget = 256 })
        spec.truthy(#output <= 256); spec.truthy(info.truncated)
        spec.equal(G.inn, nil)
        spec.equal(pcall(callers.run, G, idx, 'leaf', { depth = false }), false)
        spec.equal(pcall(callers.run, G, idx, 'leaf', { max_nodes = 0 }), false)
    end)
    spec.it('includes configured event callers and refreshes after edits', function()
        local root = tmp_root .. '/recursive_callers'
        write(root .. '/a.lua', "function handler() end\nbus.on('tick', handler)\nfunction publish() bus.emit('tick') end\nfunction outer() publish() end")
        write(root .. '/.codeoutline.json', xutils.json_pack({ dispatchRules = {
            { kind = 'event', call = 'bus.emit', argument = 1, register = 'bus.on', keyArgument = 1, handlerArgument = 2 },
        } }))
        local opts = { cache_path = root .. '/cache.bin' }
        local output, info = svc.callers(root, 'handler', opts)
        spec.equal(#info.callers, 2)
        spec.contains(output, 'indirect:event#1')
        spec.contains(output, 'Depth 2: outer')
        write(root .. '/a.lua', 'function handler() end\nfunction outer() end')
        output, info = svc.callers(root, 'handler', opts)
        spec.equal(#info.callers, 0)
        output, info = svc.callers(root, 'missing', opts)
        spec.equal(#info.targets, 0); spec.contains(output, 'No exact symbol matched')
        svc.forget(root)
    end)
end)

spec.describe('call-path breakpoints', function()
    local function project(files, opts)
        local records = {}
        for path, source in pairs(files) do records[path] = ci.parse(path, source, opts or { static_dispatch = true }) end
        return graph.build({ files = records }), { root = tmp_root,
            query_source = function(_, path) return assert(files[path]), false end }
    end
    spec.it('attaches dynamic dispatch evidence to a searched prefix without inferring an edge', function()
        local G, idx = project({ ['boundary.lua'] = [[local function final_handler() end
local handlers = { go = final_handler }
function dispatch_path(key) handlers[key]() end
function start_path() dispatch_path(runtime_key) end
]] })
        local output, info = explore.run(G, idx, 'start_path final_handler')
        spec.equal(#info.path_breakpoints, 1)
        local e = info.path_breakpoints[1]
        spec.equal(e.status, 'unresolved'); spec.equal(e.reason, 'dynamic registry key')
        spec.equal(G.nodes[e.from].name, 'start_path'); spec.equal(G.nodes[e.goal].name, 'final_handler')
        spec.equal(#e.path, 2); spec.equal(G.nodes[e.path[2]].name, 'dispatch_path')
        spec.equal(e.line, 3)
        spec.contains(output, '## Call-path breakpoints')
        spec.contains(output, 'start_path (boundary.lua:4) -> dispatch_path (boundary.lua:3)')
        spec.contains(output, 'continuation toward final_handler')
        spec.contains(output, 'not proven causes of disconnection')
        spec.equal(#info.flows, 0)
        local Q = graph.query(G)
        spec.equal(#Q.out[G.by_name.dispatch_path[1]], 0)
        spec.equal(#Q.inn[G.by_name.final_handler[1]], 0)
        spec.nil_value(G.out); spec.nil_value(G.inn)
    end)
    spec.it('does not invent a reverse-direction breakpoint for connected symbols', function()
        local G, idx = project({ ['connected.lua'] = 'function connected_start() connected_end() end\n'
            .. 'function connected_end() external_call() end\n' })
        local output, info = explore.run(G, idx, 'connected_start connected_end')
        spec.equal(info.flows[1], 'connected_start -> connected_end')
        spec.equal(#info.path_breakpoints, 0)
        spec.equal(output:find('## Call-path breakpoints', 1, true), nil)
        spec.contains(output, 'no indexed target') -- ordinary evidence remains available
    end)
    spec.it('keeps single-symbol explanations local and ignores unrelated functions', function()
        local G, idx = project({ ['local.lua'] = 'function local_entry() external_call() end\n'
            .. 'function unrelated() other_unknown() end\nfunction isolated() end\n' })
        local _, info = explore.run(G, idx, 'local_entry')
        spec.equal(#info.path_breakpoints, 1)
        spec.equal(info.path_breakpoints[1].goal, nil)
        spec.equal(info.path_breakpoints[1].call, 'external_call')
        local output
        output, info = explore.run(G, idx, 'isolated')
        spec.equal(#info.path_breakpoints, 0)
        spec.equal(output:find('## Call-path breakpoints', 1, true), nil)
    end)
    spec.it('distinguishes search limits from unresolved call sites', function()
        local G, idx = project({ ['limit.lua'] = 'function limit_start() hop_one() end\n'
            .. 'function hop_one() hop_two() end\nfunction hop_two() hop_three() end\n'
            .. 'function hop_three() hop_four() end\nfunction hop_four() limit_end() end\nfunction limit_end() end\n' })
        local output, info = explore.run(G, idx, 'limit_start limit_end')
        spec.truthy(info.path_search_limited)
        spec.equal(#info.flows, 0)
        spec.equal(info.path_breakpoints[1].status, 'search_limit')
        spec.contains(output, 'path depth/frontier limit reached')
        spec.contains(output, 'continuation was not checked completely')
        output, info = explore.run(G, idx, 'limit_start limit_end', { max_expanded = 1 })
        spec.truthy(info.relationships_incomplete)
        spec.equal(info.path_breakpoints[1].reason, 'relationship expansion limit reached')
    end)
    spec.it('caps sites and reports omitted explanations under small output budgets', function()
        local calls = {}
        for i = 1, 12 do calls[i] = 'unknown_' .. i .. '()' end
        local G, idx = project({ ['many.lua'] = 'function many_calls() ' .. table.concat(calls, '; ') .. ' end\n' })
        local output, info = explore.run(G, idx, 'many_calls', { budget = 262144 })
        spec.equal(#info.path_breakpoints, 4)
        spec.truthy(info.path_breakpoints_truncated)
        spec.contains(output, 'Additional sites or relationship evidence were omitted')
        output, info = explore.run(G, idx, 'many_calls', { budget = 256 })
        spec.truthy(#output <= 256); spec.truthy(info.truncated)
        spec.truthy(info.path_breakpoints_truncated)
    end)
    spec.it('does not blame an earlier completed search for a later expansion limit', function()
        local G, idx = project({ ['separate.lua'] = 'function done_start() external_call() end\n'
            .. 'function busy_start() busy_next() end\nfunction busy_next() busy_end() end\nfunction busy_end() end\n' })
        local _, info = explore.run(G, idx, 'done_start busy_start', { max_expanded = 2 })
        spec.truthy(info.relationships_incomplete)
        local limits = 0
        for _, e in ipairs(info.path_breakpoints) do
            if e.status == 'search_limit' then
                limits = limits + 1
                spec.equal(G.nodes[e.from].name, 'busy_start')
            end
        end
        spec.equal(limits, 1)
    end)
    spec.it('checks source snapshots for intermediate files named by a breakpoint', function()
        local G, idx = project({
            ['first.c'] = 'void trace_start(void) { step_one(); }',
            ['second.c'] = 'void step_one(void) { step_two(); }',
            ['third.c'] = 'void step_two(void) { trace_stop(); }',
            ['fourth.c'] = 'void trace_stop(void) { missing_runtime(); }',
            ['goal.c'] = 'void trace_goal(void) {}',
        })
        local query_source, checked = idx.query_source, {}
        idx.query_source = function(self, path) checked[path] = true; return query_source(self, path) end
        local _, info = explore.run(G, idx, 'trace_start trace_goal')
        spec.equal(#info.path_breakpoints, 1)
        spec.equal(#info.path_breakpoints[1].path, 4)
        spec.truthy(checked['third.c']); spec.truthy(checked['fourth.c'])
        idx.query_source = function(self, path)
            if path == 'fourth.c' then error('source changed during query; retry: fourth.c') end
            return query_source(self, path)
        end
        local ok, err = pcall(explore.run, G, idx, 'trace_start trace_goal')
        spec.equal(ok, false); spec.contains(err, 'source changed during query')
    end)
    spec.it('uses existing evidence without reparsing or expanding additional nodes', function()
        local G, idx = project({ ['reuse.lua'] = 'function reuse_start() reuse_middle() end\n'
            .. 'function reuse_middle() missing_runtime() end\nfunction reuse_goal() end\n' })
        local original, parses = ci.parse, 0
        ci.parse = function(...) parses = parses + 1; return original(...) end
        local ok, err = pcall(function()
            local _, info = explore.run(G, idx, 'reuse_start reuse_goal')
            spec.equal(#info.path_breakpoints, 1)
            spec.equal(parses, 0)
            spec.equal(info.query_stats.expanded, 3)
        end)
        ci.parse = original
        assert(ok, err)
    end)
    spec.it('identifies the configured rule and argument at an unresolved dispatch site', function()
        local G, idx = project({ ['rule.lua'] = 'function rule_entry() enqueue(10, make_callback()) end\n'
            .. 'function rule_goal() end\n' }, { dispatch = true })
        local output, info = explore.run(G, idx, 'rule_entry rule_goal', {
            dispatch_rules = {{kind = 'callback', call = 'enqueue', argument = 2}},
        })
        local found
        for _, e in ipairs(info.path_breakpoints) do if e.call == 'enqueue' then found = e end end
        spec.truthy(found); spec.equal(found.rule, 1); spec.equal(found.argument, 2)
        spec.contains(found.reason, 'dispatch argument is dynamic')
        spec.contains(output, 'rule #1, argument 2')
        spec.equal(#info.flows, 0)
    end)
end)

spec.describe('static registry dispatch', function()
    spec.it('skips detailed collection without matching declarations and calls', function()
        for _, input in ipairs({
            { 'a.lua', 'local function save() end\nlocal t = { go = save }\nfunction run() other.go() end' },
            { 'a.lua', 'local function save() end\nM.go = save\nfunction run() M.go() end' },
            { 'a.c', 'struct Ops { void (*call)(void); };\nvoid run(void) { other.work(); }' },
            { 'a.c', 'void run(void) { (*ops->call)(); }' },
        }) do
            local parsed = ci.parse(input[1], input[2], { static_dispatch = true })
            spec.equal(parsed.static_dispatch_candidate, nil)
            spec.equal(parsed.static_dispatch, nil)
        end
    end)
    local function build(path, source)
        return graph.build({ files = { [path] = ci.parse(path, source, { static_dispatch = true }) } })
    end
    local function targets(G, name)
        local Q, result = graph.query(G, { explain = true }), {}
        local edges = Q.out[G.by_name[name][1]]
        for i = 1, #edges, graph.EDGE do
            if edges[i + 2]:match('^indirect:') then result[#result + 1] = G.nodes[edges[i]].name end
        end
        table.sort(result)
        return table.concat(result, ','), Q
    end
    spec.it('connects literal Lua registry keys in both directions with evidence', function()
        local G = build('registry.lua', [[
local function save() end
local function load() end
local handlers = { save = save, ['load'] = load }
function run() handlers['save'](); handlers.load() end
]])
        local found, Q = targets(G, 'run')
        spec.equal(found, 'load,save')
        local incoming = Q.inn[G.by_name.save[1]]
        spec.equal(#incoming, 3)
        spec.equal(G.nodes[incoming[1]].name, 'run')
        spec.equal(Q.report.entries[1].registered_at, 'registry.lua:3')
    end)
    spec.it('accepts explicit Lua field registration and rejects dynamic or overwritten slots', function()
        local G = build('registry.lua', [[
local function save() end
local handlers = {}
handlers.save = save
handlers['load'] = save
handlers.load = nil
function run(key) handlers.save(); handlers['load'](); handlers[key]() end
]])
        local found, Q = targets(G, 'run')
        spec.equal(found, 'save')
        local reasons = {}
        for _, e in ipairs(Q.report.entries) do reasons[#reasons + 1] = e.reason or '' end
        spec.contains(table.concat(reasons, '|'), 'dynamic registry key')
    end)
    spec.it('does not cross Lua table scopes, parameters, replacement or computed writes', function()
        for _, body in ipairs({
            'function run(handlers) handlers.save() end',
            'function run() local handlers = {}; handlers.save() end',
            'handlers = {}\nfunction run() handlers.save() end',
            'handlers[key] = other\nfunction run() handlers.save() end',
        }) do
            local G = build('registry.lua', 'local function save() end\nlocal handlers = { save = save }\n' .. body)
            spec.equal(targets(G, 'run'), '')
        end
    end)
    spec.it('connects C and C++ typed function-pointer tables and field assignments', function()
        for _, ext in ipairs({ 'c', 'cpp' }) do
            local G = build('registry.' .. ext, [[
struct Ops { const char *name; void (*call)(void); };
void save(void) {}
void load(void) {}
static struct Ops entries[] = { { "save", save }, { "load", load } };
void run(struct Ops *ops) { ops->call(); }
]])
            spec.equal(targets(G, 'run'), 'load,save', ext)
            local Q = graph.query(G)
            spec.equal(G.nodes[Q.inn[G.by_name.save[1]][1]].name, 'run')
        end
        local G = build('registry.c', [[
struct Ops { void (*call)(void); };
void save(void) {}
static struct Ops ops = { .call = save };
void run(void) { ops.call(); }
]])
        spec.equal(targets(G, 'run'), 'save')
        G = build('registry.c', [[
struct Ops { void (*call)(void); };
void save(void) {}
void setup(struct Ops *ops) { ops->call = &save; }
void run(struct Ops *ops) { ops->call(); }
]])
        spec.equal(targets(G, 'run'), 'save')
    end)
    spec.it('isolates C function-pointer fields by declared structure type', function()
        local G = build('registry.c', [[
struct A { void (*call)(void); };
struct B { void (*call)(void); };
void first(void) {}
void second(void) {}
static struct A a = { first };
static struct B b = { second };
void run(struct A *ops) { ops->call(); }
]])
        spec.equal(targets(G, 'run'), 'first')
    end)
    spec.it('includes registrations immediately after C switch labels', function()
        local G = build('registry.c', [[
struct Ops { void (*call)(void); };
void first(void) {}
void second(void) {}
void setup(struct Ops *ops, int mode) {
    switch (mode) { case 0: ops->call = first; break;
    case 1: ops->call = second; break; default: ops->call = first; }
}
void run(struct Ops *ops) { (*ops->call)(); }
]])
        spec.equal(targets(G, 'run'), 'first,second')
    end)
    spec.it('filters unrelated targets and parses each candidate once across traversals', function()
        local root = tmp_root .. '/registry_once'
        for i = 1, 20 do
            write(root .. '/' .. i .. '.lua', 'local function handler() end\nlocal t = { go = handler }\nfunction run' .. i .. '() t.go() end')
        end
        local _, G = svc.get(root, { cache_path = root .. '/cache.bin' })
        local parser = require('codeoutline.parse')
        local original, count = parser.parse, 0
        parser.parse = function(...) count = count + 1; return original(...) end
        local ok, err = pcall(function()
            local dispatch = require('codeoutline.static_dispatch').query(G)
            dispatch.incoming({ [G.by_name.run1[1]] = true })
            spec.equal(count, 0)
            local wanted = {}; for _, id in ipairs(G.by_name.handler) do wanted[id] = true end
            dispatch.incoming(wanted)
            spec.equal(count, 20)
            dispatch.incoming(wanted)
            for i = 1, 20 do dispatch.outgoing(G.by_name['run' .. i][1]) end
            spec.equal(count, 20)
            local static = require('codeoutline.static_dispatch')
            static.max_query_entries = 1
            local bounded, message = pcall(function() static.query(G).incoming(wanted) end)
            static.max_query_entries = nil
            spec.equal(bounded, false)
            spec.contains(message, 'static dispatch query limit exceeded')
        end)
        parser.parse = original
        svc.forget(root)
        assert(ok, err)
    end)
    spec.it('handles direct C array dispatch and parenthesized function pointers', function()
        local G = build('registry.c', [[
struct Ops { void (*call)(void); };
void save(void) {}
static struct Ops table[] = { { save } };
void run(int i) { table[i].call(); }
void indirect(struct Ops *ops) { (*ops->call)(); }
]])
        spec.equal(targets(G, 'run'), 'save')
        spec.equal(targets(G, 'indirect'), 'save')
    end)
    spec.it('rejects shadowed C receivers and Lua callback names', function()
        for _, body in ipairs({
            'void run(void *ops) { ops->call(); }',
            'void run(void) { void *ops = other; ops->call(); }',
        }) do
            local G = build('registry.c', 'struct Ops { void (*call)(void); };\nvoid save(void) {}\nstatic struct Ops ops = { save };\n' .. body)
            spec.equal(targets(G, 'run'), '')
        end
        for _, body in ipairs({
            'local save = unknown\nlocal handlers = { save = save }\nfunction run() handlers.save() end',
            'save = unknown\nlocal handlers = { save = save }\nfunction run() handlers.save() end',
            'local handlers = { save = save, save = other }\nfunction run() handlers.save() end',
        }) do
            local G = build('registry.lua', 'local function save() end\n' .. body)
            spec.equal(targets(G, 'run'), '')
        end
    end)
    spec.it('preserves callers across query cache eviction and file removal', function()
        local root = tmp_root .. '/registry_eviction'
        for i = 1, 20 do
            write(root .. '/' .. i .. '.lua', 'local function handler() end\nlocal t = { go = handler }\nfunction run' .. i .. '() t["go"]() end')
        end
        local opts = { cache_path = root .. '/cache.bin' }
        local _, info = svc.callers(root, 'handler', opts)
        spec.equal(#info.callers, 20)
        os.remove(root .. '/1.lua')
        _, info = svc.callers(root, 'handler', opts)
        spec.equal(#info.callers, 19)
        svc.forget(root)
    end)
    spec.it('preserves existing Lua table-function calls in resident project queries', function()
        local root = tmp_root .. '/registry_ordinary'
        write(root .. '/a.lua', [[
local M = { inline = function() end }
function M.named() end
M.assigned = function() end
function run() M.inline(); M.named(); M.assigned() end
]])
        local opts = { cache_path = root .. '/cache.bin' }
        for _, name in ipairs({ 'inline', 'named', 'assigned' }) do
            local _, info = svc.callers(root, name, opts)
            spec.equal(#info.callers, 1, name)
            spec.equal(info.callers[1].name, 'run')
        end
        svc.forget(root)
    end)
    spec.it('selects the lexical Lua handler when nested functions reuse a name', function()
        local G = build('registry.lua', [[
local function save() end
function outer()
    local function save() end
    local handlers = { save = save }
    handlers['save']()
end
]])
        local Q = graph.query(G)
        local edges = Q.out[G.by_name.outer[1]]
        spec.equal(#edges, 3)
        spec.equal(G.nodes[edges[1]].qualified, 'outer.save')
    end)
    spec.it('keeps registrations query-owned and refreshes cached callers after edits', function()
        local root = tmp_root .. '/static_registry'
        local source = "local function save() end\nlocal handlers = { save = save }\nfunction run() handlers['save']() end"
        write(root .. '/a.lua', source)
        local opts = { cache_path = root .. '/cache.bin' }
        local idx, G = svc.get(root, opts)
        spec.equal(idx.files['a.lua'].static_dispatch, nil)
        spec.truthy(idx.files['a.lua'].static_dispatch_candidate)
        local output, info = svc.callers(root, 'save', opts)
        spec.equal(#info.callers, 1)
        spec.contains(output, 'indirect:registry')
        local explored = svc.explore(root, 'run save', opts)
        spec.contains(explored, 'registered at a.lua:2')
        idx:save(); svc.forget(root)
        output, info = svc.callers(root, 'save', opts)
        spec.equal(#info.callers, 1)
        local _, stale = svc.get(root, opts)
        write(root .. '/a.lua', source:gsub('save = save', 'save = nil'))
        local ok, err = pcall(function() return graph.query(stale).out[stale.by_name.run[1]] end)
        spec.equal(ok, false); spec.contains(err, 'source changed during query')
        output, info = svc.callers(root, 'save', opts)
        spec.equal(#info.callers, 0)
        svc.forget(root)
    end)
end)

return {
    __init = function()
        local failed = spec.finish()
        if failed > 0 then os.exit(1) end
        xthread.stop(0)
    end,
}
