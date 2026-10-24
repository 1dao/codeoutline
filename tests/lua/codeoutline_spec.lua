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

spec.describe('ArkTS components', function()
    spec.it('keeps decorated members and UI calls without inventing UI methods', function()
        local source = table.concat({
            '@Entry', '@Component', 'struct Index {',
            "  @State message: string = 'hello';",
            '  @StorageLink("count") count: number = 0;',
            '  @Builder', '  content() { Column() { Text(this.message) } }',
            '  increment() { this.count++; }',
            '  build() {',
            '    Column({ space: 16 }) {',
            '      Row() { Button("add").onClick(() => { this.increment(); }) }',
            '      this.content()', '    }', '  }', '}',
            'const options = { fetch(req) { return load(req); } };',
        }, '\n')
        local r = ci.parse('Index.ets', source)
        spec.equal(r.language, 'arkts')
        spec.equal(ci.language('INDEX.ETS'), 'arkts')
        local n = names(r)
        for _, expected in ipairs({ 'class Index@3', 'field Index.message@4', 'field Index.count@5',
            'method Index.content@7', 'method Index.increment@8', 'method Index.build@9', 'method fetch@16' }) do
            spec.contains(n, expected)
        end
        for _, node in ipairs(r.nodes) do
            spec.truthy(node.name ~= 'Column' and node.name ~= 'Row' and node.name ~= 'State')
            spec.equal(source:sub(node.name_start + 1, node.name_end), node.name)
        end
        local calls = refs(r)
        for _, expected in ipairs({ 'content->Column', 'content->Text', 'build->Column',
            'build->Row', 'build->increment', 'build->content' }) do spec.contains(calls, expected) end
        spec.truthy(not calls:find('->StorageLink', 1, true))
        local ts = ci.parse('plain.ts', 'const struct = 1; class Box { @State value: number = 0; }')
        spec.contains(names(ts), 'field Box.value@1')
        spec.truthy(not names(ts):find('class struct', 1, true))
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

spec.describe('C++ declared receiver bindings', function()
    spec.it('generates ordinary bindings only in queries after cache reload and incremental changes', function()
        local root = tmp_root .. '/ordinary_bindings'
        write(root .. '/store.py', 'def save():\n    pass\n')
        write(root .. '/other.py', 'def save():\n    pass\n')
        write(root .. '/app.py', 'from store import save as persist\ndef python_run():\n    persist()\n')
        write(root .. '/lib.ts', 'export const save = () => {};\nexport const alias = save;')
        write(root .. '/app.ts', "import { alias } from './lib'; const cb = alias; function js_run() { cb(); }")
        write(root .. '/app.cpp', 'class A { public: void save() {} }; class B { public: void save() {} };\nvoid cpp_run(A* a) { a->save(); }')
        local options = { cache_path = root .. '/cache.idx', lister = 'walk' }
        local idx, G = svc.get(root, options)
        idx:save(); svc.forget(root)
        idx, G = svc.get(root, options)
        local function no_evidence()
            for _, rec in pairs(idx.files) do
                spec.nil_value(rec.ordinary_bindings)
                spec.nil_value(rec.refs.binding)
                spec.nil_value(rec.python_imports)
                spec.nil_value(rec.cpp_aliases)
                for _, export in ipairs(rec.js_exports or {}) do spec.nil_value(export.binding) end
            end
        end
        no_evidence()
        local resident = xutils.json_pack(idx.files)
        spec.equal(edges_from(G, 'python_run'), 'save@store.py')
        spec.equal(edges_from(G, 'js_run'), 'save@lib.ts')
        local function cpp_target(symbols)
            return symbols.nodes[graph.query(symbols).out[symbols.by_name.cpp_run[1]][1]].qualified
        end
        spec.equal(cpp_target(G), 'A::save')
        spec.equal(xutils.json_pack(idx.files), resident, 'queries must not mutate resident records')
        no_evidence()
        write(root .. '/app.py', 'from other import save as persist\ndef python_run():\n    persist()\n')
        write(root .. '/lib.ts', 'export const replacement = () => {};\nexport const alias = replacement;')
        write(root .. '/app.cpp', 'class A { public: void save() {} }; class B { public: void save() {} };\nvoid cpp_run(B* a) { a->save(); }')
        idx, G = svc.get(root, options)
        spec.equal(edges_from(G, 'python_run'), 'save@other.py')
        spec.equal(edges_from(G, 'js_run'), 'replacement@lib.ts')
        spec.equal(cpp_target(G), 'B::save')
        local rebuilt = graph.build(idx)
        for _, name in ipairs({ 'python_run', 'js_run', 'cpp_run' }) do
            spec.equal(edges_from(G, name), edges_from(rebuilt, name), name)
        end
        spec.equal(cpp_target(rebuilt), cpp_target(G))
        svc.forget(root)
    end)
    spec.it('selects declared classes, inherited methods and lexical shadowing', function()
        local source = [[class Base { public: void save() {} };
class A : public Base {};
class B { public: void save() {} };
void run(A* a) { a->save(); }
void nested(A* a) { { B a; a.save(); } a->save(); }
void unknown(A* a) { { int a; a.save(); } }
]]
        local G = graph.build({ files = { ['a.cpp'] = ci.parse('a.cpp', source, { ordinary_bindings = true }) } })
        local function qualified(name)
            local out, Q = {}, graph.query(G)
            for i = 1, #Q.out[G.by_name[name][1]], graph.EDGE do out[#out + 1] = G.nodes[Q.out[G.by_name[name][1]][i]].qualified end
            table.sort(out); return table.concat(out, ',')
        end
        spec.equal(qualified('run'), 'Base::save')
        spec.equal(qualified('nested'), 'B::save,Base::save')
        spec.equal(qualified('unknown'), '')
        spec.equal(#graph.query(G).inn[G.by_qualified['Base::save'][1]], 2 * graph.EDGE)
    end)
    spec.it('uses namespace and include visibility without unrelated method fallback', function()
        local files = {
            ['a.hpp'] = 'namespace chosen { class A { public: void save() {} }; }',
            ['b.hpp'] = 'namespace wrong { class A { public: void save() {} }; }',
            ['app.cpp'] = '#include "a.hpp"\nvoid run(chosen::A& a) { a.save(); }\n'
                .. 'void missing(chosen::A* a) { a->other(); }\n',
            ['other.cpp'] = 'void other() {}',
        }
        local records = {}
        for path, source in pairs(files) do records[path] = ci.parse(path, source, { ordinary_bindings = true }) end
        local G = graph.build({ files = records })
        spec.equal(edges_from(G, 'run'), 'save@a.hpp')
        spec.equal(edges_from(G, 'missing'), '')
    end)
end)

spec.describe('C# using and member bindings', function()
    local function build(files)
        local records = {}
        for path, source in pairs(files) do records[path] = ci.parse(path, source, { ordinary_bindings = true }) end
        return graph.build({ files = records })
    end
    local function targets(G, name)
        local result, edges = {}, graph.query(G).out[G.by_name[name][1]]
        for i = 1, #edges, graph.EDGE do
            local node = G.nodes[edges[i]]
            if node.kind == 'method' then result[#result + 1] = node.qualified end
        end
        table.sort(result); return table.concat(result, ',')
    end
    local library = [[namespace Data {
public class Store { public void Save() {} public static void Flush() {} }
public class Other { public void Save() {} public static void Flush() {} }
}]]
    spec.it('resolves type and namespace aliases, qualified names, new and static imports', function()
        local G = build({ ['lib.cs'] = library, ['app.cs'] = [[
using S = global::Data.Store;
using D = Data;
using static global::Data.Store;
class App {
void Typed(S s) { s.Save(); }
void Created() { var s = new S(); s.Save(); }
void StaticCalls() { S.Flush(); D.Store.Flush(); D::Store.Flush(); global::Data.Store.Flush(); Flush(); }
void Shadow(object S) { S.Save(); }
}]] })
        spec.equal(targets(G, 'Typed'), 'Data.Store.Save')
        spec.equal(targets(G, 'Created'), 'Data.Store.Save')
        spec.equal(targets(G, 'StaticCalls'), string.rep('Data.Store.Flush,', 4) .. 'Data.Store.Flush')
        spec.equal(targets(G, 'Shadow'), '')
        spec.equal(#graph.query(G).inn[G.by_qualified['Data.Store.Save'][1]], 2 * graph.EDGE)
        spec.equal(#graph.query(G).inn[G.by_qualified['Data.Other.Save'][1]], 0)
    end)
    spec.it('honors file/namespace scope and excludes same-scope using alias chains', function()
        local G = build({ ['lib.cs'] = library, ['app.cs'] = [[
using S = Data.Store;
using Broken = S;
namespace Outer {
using Local = Data.Store;
namespace Inner { using Nested = Local; class App { void NestedRun(Nested s) { s.Save(); } } }
}
namespace Twice { using Local = Data.Store; class App { void First(Local s) { s.Save(); } } }
namespace Twice { class SecondApp { void Second(Local s) { s.Save(); } } }
class App { void NoChain(Broken s) { s.Save(); } }
]], ['other.cs'] = 'class OtherApp { void NoLeak(S s) { s.Save(); } }' })
        spec.equal(targets(G, 'NestedRun'), 'Data.Store.Save')
        spec.equal(targets(G, 'First'), 'Data.Store.Save')
        for _, name in ipairs({ 'NoChain', 'NoLeak', 'Second' }) do spec.equal(targets(G, name), '', name) end
    end)
    spec.it('blocks unsupported alias targets and limits static imports to static members', function()
        local G = build({ ['lib.cs'] = library, ['app.cs'] = [[
using Missing = Absent.Store;
using Tuple = (int x, int y);
using Generic = Data.Store<int>;
using static Data.Store;
class App {
void NoMissing(Missing s) { s.Save(); }
void NoTuple(Tuple s) { s.Save(); }
void NoGeneric(Generic s) { s.Save(); }
void NoInstance() { Save(); }
void NoStatic(Data.Store s) { s.Flush(); }
}]] })
        for _, name in ipairs({ 'NoMissing', 'NoTuple', 'NoGeneric', 'NoInstance', 'NoStatic' }) do spec.equal(targets(G, name), '', name) end
    end)
    spec.it('prefers nested types and generic parameters over outer aliases', function()
        local G = build({ ['lib.cs'] = library, ['app.cs'] = [[
using S = Data.Store;
class Nested {
class S { public void Save() {} }
void Own(S s) { s.Save(); }
}
class Generic<S> { void Unknown(S s) { s.Save(); } }
class Methods { void GenericMethod<S>(S s) { s.Save(); } }
]] })
        spec.equal(targets(G, 'Own'), 'Nested.S.Save')
        spec.equal(targets(G, 'Unknown'), '')
        spec.equal(targets(G, 'GenericMethod'), '')
    end)
    spec.it('uses namespace-relative imports and nested types from using static', function()
        local G = build({ ['lib.cs'] = [[
namespace Parent.Model { public class Store { public void Save() {} } }
namespace NestedTypes { public class Owner { public class Item { public void Save() {} } } }
]], ['app.cs'] = [[
using static NestedTypes.Owner;
namespace Parent {
using Model;
class App { void Relative(Store s) { s.Save(); } void NestedStatic(Item s) { s.Save(); } }
}]] })
        spec.equal(targets(G, 'Relative'), 'Parent.Model.Store.Save')
        spec.equal(targets(G, 'NestedStatic'), 'NestedTypes.Owner.Item.Save')
    end)
    spec.it('resolves alias constructors in both directions and prefers own members over static imports', function()
        local G = build({ ['a.cs'] = [[
using Alias = Constructors.Store;
using D = Constructors;
using static Constructors.Store;
namespace Constructors { public class Store {
public Store() {} public static void Flush() {} private static void Hidden() {}
} }
class App {
void Flush() {} void Own() { Flush(); }
void Create() { var a = new Alias(); var b = new D.Store(); }
void PrivateImport() { Hidden(); }
}]] })
        spec.equal(targets(G, 'Own'), 'App.Flush')
        spec.equal(targets(G, 'PrivateImport'), '')
        local ctor = G.by_qualified['Constructors.Store.Store'][1]
        local Q = graph.query(G)
        local edges = Q.out[G.by_name.Create[1]]
        spec.equal(#edges, 2 * graph.EDGE); spec.equal(edges[1], ctor); spec.equal(edges[4], ctor)
        spec.equal(#Q.inn[ctor], 2 * graph.EDGE)
    end)
    spec.it('rejects conflicting global and file aliases while allowing nested namespace shadowing', function()
        local G = build({ ['lib.cs'] = library, ['global.cs'] = 'global using S = Data.Store;',
            ['app.cs'] = 'using S = Data.Other; class App { void Conflict(S s) { s.Save(); } }',
            ['namespace.cs'] = 'namespace N { using S = Data.Other; class App { void Scoped(S s) { s.Save(); } } }' })
        spec.equal(targets(G, 'Conflict'), '')
        spec.equal(targets(G, 'Scoped'), 'Data.Other.Save')
    end)
    spec.it('loads global usings on demand within csproj boundaries and refreshes edits', function()
        local root = tmp_root .. '/csharp_alias_projects'
        for _, project in ipairs({ 'P1', 'P2' }) do
            write(root .. '/' .. project .. '/App.csproj', '<Project Sdk="Microsoft.NET.Sdk" />')
            write(root .. '/' .. project .. '/lib.cs', library)
            write(root .. '/' .. project .. '/app.cs', 'class App { void Run' .. project .. '(Shared s) { s.Save(); } '
                .. 'void Static' .. project .. '() { Flush(); } void Using' .. project .. '(Store s) { s.Save(); } }')
        end
        write(root .. '/P1/global.cs', 'global using Shared = Data.Store; global using static Data.Store; global using Data;')
        write(root .. '/P2/global.cs', 'global using Shared = Data.Other; global using static Data.Other; global using Data;')
        local options = { cache_path = root .. '/cache.idx', lister = 'walk' }
        local idx, G = svc.get(root, options)
        idx:save(); svc.forget(root); idx, G = svc.get(root, options)
        local function check(caller, qualified, file)
            local Q = graph.query(G)
            local edges = Q.out[G.by_name[caller][1]]
            spec.equal(#edges, graph.EDGE)
            spec.equal(G.nodes[edges[1]].qualified, qualified)
            spec.equal(G.files[G.node_file[edges[1]]].path, file)
        end
        check('RunP1', 'Data.Store.Save', 'P1/lib.cs')
        check('RunP2', 'Data.Other.Save', 'P2/lib.cs')
        check('StaticP1', 'Data.Store.Flush', 'P1/lib.cs')
        check('StaticP2', 'Data.Other.Flush', 'P2/lib.cs')
        check('UsingP1', 'Data.Store.Save', 'P1/lib.cs')
        check('UsingP2', 'Data.Store.Save', 'P2/lib.cs')
        write(root .. '/P1/global.cs', 'global using Shared = Data.Other;')
        idx, G = svc.get(root, options)
        check('RunP1', 'Data.Other.Save', 'P1/lib.cs')
        for _, rec in pairs(idx.files) do
            spec.nil_value(rec.csharp_usings); spec.nil_value(rec.csharp_scopes)
            spec.nil_value(rec.csharp_statics); spec.nil_value(rec.csharp_access)
            spec.nil_value(rec.csharp_parameters); spec.nil_value(rec.refs.binding)
        end
        svc.forget(root)
    end)
    spec.it('preserves global-alias callers after query cache eviction', function()
        local root = tmp_root .. '/csharp_alias_eviction'
        write(root .. '/library.cs', 'namespace Eviction { public class Store { public void Save() {} } }')
        write(root .. '/global.cs', 'global using Shared = Eviction.Store;')
        for i = 1, 20 do
            write(root .. '/app' .. i .. '.cs', 'class App' .. i .. ' { void Run' .. i .. '(Shared s) { s.Save(); } }')
        end
        local idx, G = svc.get(root, { cache_path = root .. '/cache.idx', lister = 'walk' })
        local resident = xutils.json_pack(idx.files)
        local Q = graph.query(G)
        spec.equal(#Q.inn[G.by_qualified['Eviction.Store.Save'][1]], 20 * graph.EDGE)
        spec.truthy(Q.stats.ordinary.parses > 16)
        spec.truthy(Q.stats.ordinary.files <= 16 and Q.stats.ordinary.bytes <= 8 * 1024 * 1024)
        spec.equal(#Q.out[G.by_name.Run1[1]], graph.EDGE)
        spec.equal(xutils.json_pack(idx.files), resident)
        svc.forget(root)
    end)
end)

spec.describe('C++ query-time type aliases', function()
    local function build(files)
        local records = {}
        for path, source in pairs(files) do records[path] = ci.parse(path, source, { ordinary_bindings = true }) end
        return graph.build({ files = records })
    end
    local function targets(G, name)
        local out, edges = {}, graph.query(G).out[G.by_name[name][1]]
        for i = 1, #edges, graph.EDGE do out[#out + 1] = G.nodes[edges[i]].qualified end
        table.sort(out); return table.concat(out, ',')
    end
    spec.it('follows named aliases, qualified aliases and pointer/reference chains', function()
        local G = build({ ['a.cpp'] = [[
class A { public: void save() {} class Inner { public: void save() {} }; };
class B { public: void save() {} };
namespace chosen { using Item = ::A; typedef const Item* Ptr; using Ref = Item&; }
using Owner = A;
void pointer(chosen::Ptr a) { a->save(); }
void reference(chosen::Ref a) { a.save(); }
void nested(Owner::Inner* a) { a->save(); }
]] })
        spec.equal(targets(G, 'pointer'), 'A::save')
        spec.equal(targets(G, 'reference'), 'A::save')
        spec.equal(targets(G, 'nested'), 'A::Inner::save')
        spec.equal(#graph.query(G).inn[G.by_qualified['A::save'][1]], 2 * graph.EDGE)
    end)
    spec.it('uses lexical scope and the receiver declaration position', function()
        local G = build({ ['a.cpp'] = [[
class A { public: void save() {} };
class B { public: void save() {} };
using Item = A;
void local_scope() { Item a; { using Item = B; Item b; b.save(); a.save(); } Item c; c.save(); }
void before() { Item a; using Item = B; a.save(); Item b; b.save(); }
class Box { public: using Item = B; void member(Item* a) { a->save(); } };
namespace N { using Item = B; void qualified(::Item* a) { a->save(); } }
]] })
        spec.equal(targets(G, 'local_scope'), 'A::save,A::save,B::save')
        spec.equal(targets(G, 'before'), 'A::save,B::save')
        spec.equal(targets(G, 'member'), 'B::save')
        spec.equal(targets(G, 'qualified'), 'A::save')
    end)
    spec.it('does not revive outer names for unsupported, missing or cyclic aliases', function()
        local G = build({ ['a.cpp'] = [[
class A { public: void save() {} };
class Item { public: void save() {} };
namespace N { using Item = Missing; void missing(Item* a) { a->save(); } }
void primitive() { using Item = int; Item a; a.save(); }
void cyclic() { using Loop = Loop; Loop* a; a->save(); }
using Generic = Box<A>;
void templated(Generic* a) { a->save(); }
typedef void (*Callback)();
void function_pointer(Callback a) { a->save(); }
]] })
        for _, name in ipairs({ 'missing', 'primitive', 'cyclic', 'templated', 'function_pointer' }) do
            spec.equal(targets(G, name), '', name)
        end
    end)
    spec.it('resolves header aliases in their declaration scope and keeps metadata query-only', function()
        local source = 'namespace N { class A { public: void save() {} }; using Item = A; }'
        local compact = ci.parse('types.hpp', source, { ranges = false, omit_signatures = true })
        spec.nil_value(compact.cpp_aliases)
        local G = build({ ['types.hpp'] = source,
            ['app.cpp'] = '#include "types.hpp"\nclass A { public: void save() {} };\nvoid run(N::Item* a) { a->save(); }' })
        spec.equal(targets(G, 'run'), 'N::A::save')
    end)
    spec.it('bounds alias chains without guessing past unresolved types', function()
        local source = 'class A { public: void save() {} };\nusing T0 = A;\n'
        for i = 1, 9 do source = source .. 'using T' .. i .. ' = T' .. (i - 1) .. ';\n' end
        source = source .. 'void bounded(T7* a) { a->save(); }\nvoid too_deep(T9* a) { a->save(); }'
        local G = build({ ['a.cpp'] = source })
        spec.equal(targets(G, 'bounded'), 'A::save')
        spec.equal(targets(G, 'too_deep'), '')
    end)
    spec.it('shares lazy aliases with explore and callers after reload and incremental edits', function()
        local root = tmp_root .. '/cpp_alias_queries'
        local header = 'class AliasA { public: void save() {} };\nclass AliasB { public: void save() {} };\nusing Selected = AliasA;\n'
        write(root .. '/types.hpp', header)
        write(root .. '/app.cpp', '#include "types.hpp"\nvoid alias_entry(Selected* p) { p->save(); }\n')
        local options = { cache_path = root .. '/cache.idx', lister = 'walk' }
        local idx, G = svc.get(root, options)
        idx:save(); svc.forget(root); idx, G = svc.get(root, options)
        local function check(which)
            local text = explore.run(G, idx, 'alias_entry ' .. which .. '::save')
            spec.contains(text, 'alias_entry -> ' .. which .. '::save')
            local _, info = require('codeoutline.callers').run(G, idx, which .. '::save')
            spec.equal(#info.callers, 1); spec.equal(info.callers[1].name, 'alias_entry')
            for _, rec in pairs(idx.files) do spec.nil_value(rec.cpp_aliases) end
        end
        check('AliasA')
        write(root .. '/types.hpp', header:gsub('Selected = AliasA', 'Selected = AliasB'))
        idx, G = svc.get(root, options)
        check('AliasB')
        local _, info = require('codeoutline.callers').run(G, idx, 'AliasA::save')
        spec.equal(#info.callers, 0)
        svc.forget(root)
    end)
end)

spec.describe('query-owned C/C++ call-result receivers', function()
    local receivers = require('codeoutline.cpp_receivers')
    local function build(files)
        local records = {}
        for path, source in pairs(files) do records[path] = ci.parse(path, source, { ordinary_bindings = true }) end
        return graph.build({ files = records })
    end
    local function targets(G, name)
        local Q, result = graph.query(G), {}
        for i = 1, #Q.out[G.by_name[name][1]], graph.EDGE do result[#result + 1] = G.nodes[Q.out[G.by_name[name][1]][i]].qualified end
        table.sort(result); return table.concat(result, ','), Q
    end
    spec.it('narrows pointer, value, reference and chained method results to their declared class', function()
        local G = build({ ['a.cpp'] = [[struct Manager {
 void Run() {}
 Manager* Next();
};
struct Other { void Run() {} };
Manager* Factory();
Manager Value();
Manager& Reference();
void Use() { Factory()->Run(); Value().Run(); Reference().Run(); Factory()->Next()->Run(); }
]] })
        spec.equal(targets(G, 'Use'), 'Factory,Factory,Manager::Next,Manager::Run,Manager::Run,Manager::Run,Manager::Run,Reference,Value')
    end)
    spec.it('respects namespace and include visibility for function return types', function()
        local G = build({ ['chosen.hpp'] = 'namespace chosen { struct Manager { void Run() {} }; Manager* Factory(); }',
            ['wrong.hpp'] = 'namespace wrong { struct Manager { void Run() {} }; Manager* Factory(); }',
            ['use.cpp'] = '#include "chosen.hpp"\nvoid Use() { chosen::Factory()->Run(); }' })
        spec.equal(targets(G, 'Use'), 'chosen::Factory,chosen::Manager::Run')
    end)
    spec.it('follows C structure tags and ordinary typedefs to fields', function()
        local source = [[struct Record { int value; };
typedef struct Record Record;
struct Other { int value; };
Record* Factory(void);
Record Value(void);
void Use(void) { int a = Factory()->value; int b = Value().value; }
]]
        local G = build({ ['a.c'] = source }); local ctx = {}
        ctx.ordinary = require('codeoutline.ordinary_bindings').context(G, ctx)
        local C = receivers.context(G, ctx)
        for _, fragment in ipairs({ 'Factory()->value', 'Value().value' }) do
            local at = assert(source:find(fragment, 1, true)) + #fragment - #'value' - 1
            local ids = C.resolve(1, G.by_name.Use[1], 'value', 'cxx:expr:' .. at)
            spec.equal(#ids, 1); spec.equal(G.nodes[ids[1]].qualified, 'Record.value')
        end
    end)
    spec.it('requires all visible overload return types to agree and preserves pointer levels', function()
        local G = build({ ['a.cpp'] = [[struct A { void Run() {} };
struct B { void Run() {} };
A* Ambiguous(int);
B* Ambiguous(char);
A* Agreed(int);
A* Agreed(char);
A** Double();
auto Unknown();
void Bad() { Ambiguous(1)->Run(); Double()->Run(); Unknown()->Run(); }
void Good() { Agreed(1)->Run(); }
]] })
        local bad = targets(G, 'Bad'); spec.truthy(not bad:find('::Run', 1, true))
        spec.contains(targets(G, 'Good'), 'A::Run')
    end)
    spec.it('keeps shadowed function pointers and unsupported expressions from same-name fallback', function()
        local G = build({ ['a.cpp'] = [[struct Manager { void Run() {} };
Manager* Factory();
template<class T> Manager* Generic();
void Shadow(Manager* (*Factory)()) { Factory()->Run(); }
void Unsupported(Manager* item, Manager** items) { items[0]->Run(); static_cast<Manager*>(item)->Run(); Generic<int>()->Run(); }
]] })
        local shadow = targets(G, 'Shadow'); spec.truthy(not shadow:find('::Run', 1, true))
        local unsupported = targets(G, 'Unsupported'); spec.truthy(not unsupported:find('::Run', 1, true))
    end)
    spec.it('selects const methods for const returned objects and supports trailing return types', function()
        local G = build({ ['a.cpp'] = [[struct Manager {
 void Run() {}
 void Run() const {}
};
const Manager* ConstFactory();
auto Trailing() -> Manager*;
void UseConst() { ConstFactory()->Run(); }
void UseTrailing() { Trailing()->Run(); }
]] })
        local text, Q = targets(G, 'UseConst'); spec.equal(text, 'ConstFactory,Manager::Run')
        for i = 1, #Q.out[G.by_name.UseConst[1]], graph.EDGE do
            local n = G.nodes[Q.out[G.by_name.UseConst[1]][i]]
            if n.name == 'Run' then spec.equal(n.line, 3) end
        end
        spec.contains(targets(G, 'UseTrailing'), 'Manager::Run')
    end)
    spec.it('bounds source evidence and propagates cancellation', function()
        local G = build({ ['api.hpp'] = 'struct Manager { void Run() {} }; Manager* Factory();',
            ['use.cpp'] = '#include "api.hpp"\nvoid Use() { Factory()->Run(); }' })
        for _, field in ipairs({ 'MAX_FILES', 'MAX_BYTES', 'MAX_TIME_MS' }) do
            local old = receivers[field]; receivers[field] = field == 'MAX_TIME_MS' and -1 or 1
            local ok, err = pcall(function()
                local text, Q = targets(G, 'Use'); spec.truthy(not text:find('::Run', 1, true)); spec.truthy(Q.incomplete)
            end)
            receivers[field] = old; assert(ok, err)
        end
        local control = require('codeoutline.control'); local stopped = control.cancelled()
        control.callback = function() error(stopped, 0) end
        local ok, err = pcall(targets, G, 'Use'); control.callback = nil
        spec.equal(ok, false); spec.equal(err, stopped)
    end)
    spec.it('keeps return evidence out of saved indexes and refreshes changed declarations', function()
        local root = tmp_root .. '/cpp_return_refresh'
        write(root .. '/api.hpp', 'struct A { void Run() {} }; struct B { void Run() {} };\nA* Factory();')
        write(root .. '/use.cpp', '#include "api.hpp"\nvoid Use() { Factory()->Run(); }')
        local options = { cache_path = root .. '/cache.idx', lister = 'walk' }
        local idx, G = svc.get(root, options)
        local before = xutils.json_pack(idx.files)
        spec.contains(targets(G, 'Use'), 'A::Run'); spec.equal(xutils.json_pack(idx.files), before)
        for _, rec in pairs(idx.files) do spec.nil_value(rec.cpp_receivers); spec.nil_value(rec.cpp_declaration_tokens) end
        idx:save(); svc.forget(root); idx, G = svc.get(root, options); spec.truthy(idx.cache_loaded)
        spec.contains(targets(G, 'Use'), 'A::Run')
        write(root .. '/api.hpp', 'struct A { void Run() {} }; struct B { void Run() {} };\nB* Factory();')
        idx, G = svc.get(root, options); spec.contains(targets(G, 'Use'), 'B::Run')
        svc.forget(root)
    end)
    spec.it('upgrades lightweight alias evidence before full bindings and still reads macro summaries', function()
        local root = tmp_root .. '/cpp_alias_summary'
        write(root .. '/a.hpp', '#define READY 1\nnamespace n { struct A { void Run() {} }; }\nusing Alias = n::A;\nAlias* Factory();\n')
        local idx, G = svc.get(root, { cache_path = root .. '/cache.idx', lister = 'walk' })
        local f = G.file_index['a.hpp']
        local storage = { entries = {}, order = {}, bytes = 0 }
        local C = require('codeoutline.ordinary_bindings').context(G, {}, nil, { cache = storage })
        local aliases = C.cpp_aliases(f)
        spec.equal(#aliases, 1); spec.equal(aliases[1].name, 'Alias')
        spec.truthy(storage.entries[G.files[f].nodes].data.cpp_aliases_only)
        spec.truthy(#C.macros(f) > 0)
        local detail = C.data(f)
        spec.truthy(detail.cpp_receivers); spec.nil_value(detail.cpp_aliases_only)
        spec.equal(C.cpp_aliases(f), detail.cpp_aliases)
        spec.equal(#storage.order, 1); spec.truthy(storage.bytes <= 8388608)
        write(root .. '/a.hpp', '#define READY 0\nnamespace n { struct B { void Run() {} }; }\nusing Alias = n::B;\nAlias* Factory();\n')
        local fresh = require('codeoutline.ordinary_bindings').context(G, {}, nil, { cache = storage })
        local ok, err = pcall(fresh.cpp_aliases, f)
        spec.equal(ok, false); spec.contains(err, 'source changed')
        svc.forget(root)
    end)
    spec.it('preserves const qualification when continuing through returned-object fields', function()
        local G = build({ ['a.cpp'] = [[struct Leaf { void Run() {} };
struct Holder { Leaf child; Leaf* pointer; };
const Holder* Factory();
void ValueChild() { Factory()->child.Run(); }
void PointerChild() { Factory()->pointer->Run(); }
]] })
        local text = targets(G, 'ValueChild'); spec.truthy(not text:find('Leaf::Run', 1, true))
        spec.contains(targets(G, 'PointerChild'), 'Leaf::Run')
    end)
    spec.it('includes class using-overloads when proving an intermediate return type', function()
        local G = build({ ['a.cpp'] = [[struct A { void Run() {} };
struct B { void Run() {} };
struct Base { B* Next(char); };
struct Provider : Base { using Base::Next; A* Next(int); };
Provider* Factory();
void Use() { Factory()->Next(1)->Run(); }
]] })
        local text = targets(G, 'Use'); spec.truthy(not text:find('::Run', 1, true))
    end)
    spec.it('retains imported namespace directives while skipping unrelated alias headers', function()
        local G = build({ ['types.hpp'] = 'namespace api { struct Manager { void Run() {} }; }',
            ['using.hpp'] = '#include "types.hpp"\nusing namespace api;',
            ['use.cpp'] = '#include "using.hpp"\nManager* Factory();\nvoid Use() { Factory()->Run(); }' })
        spec.truthy(G.files[G.file_index['using.hpp']].cpp_using_directives)
        spec.contains(targets(G, 'Use'), 'api::Manager::Run')
    end)
    spec.it('limits failed nested-class lookup to the enclosing class source', function()
        local source = '#include "api.hpp"\n#include "aliases.hpp"\nstruct Maker { void Use() { Global::Get()->Run(); } };'
        local G = build({ ['api.hpp'] = 'struct Global { static Global* Get(); void Run() {} };',
            ['aliases.hpp'] = 'using Irrelevant = Global;', ['use.cpp'] = source })
        local ctx, read = {}, {}
        ctx.ordinary = require('codeoutline.ordinary_bindings').context(G, ctx)
        local aliases = ctx.ordinary.cpp_aliases
        ctx.ordinary.cpp_aliases = function(f) read[G.files[f].path] = true; return aliases(f) end
        local f = G.file_index['use.cpp']
        local at = assert(source:find('->Run', 1, true)) + 1
        local ids = receivers.context(G, ctx).resolve(f, G.by_qualified['Maker::Use'][1], 'Run', 'cxx:expr:' .. at)
        spec.equal(#ids, 1); spec.equal(G.nodes[ids[1]].qualified, 'Global::Run')
        spec.nil_value(read['aliases.hpp'])
    end)
end)

spec.describe('C++ namespace and using lookup', function()
    local function build(files)
        local records = {}
        for path, source in pairs(files) do records[path] = ci.parse(path, source, { ordinary_bindings = true }) end
        return graph.build({ files = records })
    end
    local function targets(G, name)
        local out, edges = {}, graph.query(G).out[G.by_name[name][1]]
        for i = 1, #edges, graph.EDGE do out[#out + 1] = G.nodes[edges[i]].qualified end
        table.sort(out); return table.concat(out, ',')
    end
    spec.it('shares namespace aliases and using declarations between types and functions', function()
        local G = build({ ['library.hpp'] = [[
namespace library { class Store { public: void save() {} }; void run() {} }
]], ['app.cpp'] = [[
#include "library.hpp"
namespace api = library;
namespace chained = api;
using api::Store;
using chained::run;
void imported(Store* p) { p->save(); run(); api::run(); chained::run(); }
void qualified(chained::Store* p) { p->save(); }
]] })
        spec.equal(targets(G, 'imported'), 'library::Store::save,library::run,library::run,library::run')
        spec.equal(targets(G, 'qualified'), 'library::Store::save')
        spec.equal(#graph.query(G).inn[G.by_qualified['library::run'][1]], 3 * graph.EDGE)
    end)
    spec.it('respects local import ranges and the receiver declaration position', function()
        local G = build({ ['app.cpp'] = [[
namespace A { class Store { public: void save() {} }; void run() {} }
namespace B { class Store { public: void save() {} }; void run() {} }
using A::Store;
void scoped() { Store a; { using B::Store; Store b; b.save(); a.save(); } Store c; c.save(); }
void local_call() { { using B::run; run(); } }
void outside() { run(); }
void before() { run(); using A::run; run(); }
void local_directive() { using namespace B; Store p; p.save(); run(); }
void hidden() { using A::run; { auto run = unknown; run(); } run(); }
]] })
        spec.equal(targets(G, 'scoped'), 'A::Store::save,A::Store::save,B::Store::save')
        spec.equal(targets(G, 'local_call'), 'B::run')
        spec.equal(targets(G, 'outside'), '')
        spec.equal(targets(G, 'before'), 'A::run')
        spec.equal(targets(G, 'hidden'), 'A::run')
        -- A::Store and the directive's B::Store are ambiguous; run is unique.
        spec.equal(targets(G, 'local_directive'), 'B::run')
    end)
    spec.it('follows indirect headers and prefers the actual relative include', function()
        local G = build({ ['lib/types.hpp'] = 'namespace A { class Store { public: void save() {} }; void run(); }',
            ['lib/types.cpp'] = '#include "types.hpp"\nvoid A::run() {}',
            ['lib/imports.h'] = '#include "types.hpp"\nnamespace api = A;\nusing api::Store;\nusing api::run;',
            ['app.cpp'] = '#include "lib/imports.h"\nvoid entry(Store* p) { p->save(); run(); }',
            ['other/types.hpp'] = 'namespace A { class Store { public: void wrong() {} }; void run() {} }' })
        spec.equal(G.files[G.file_index['lib/imports.h']].language, 'cpp')
        spec.equal(targets(G, 'entry'), 'A::Store::save,A::run')
        local Q = graph.query(G)
        local edges = Q.out[G.by_name.entry[1]]
        for i = 1, #edges, graph.EDGE do
            spec.truthy(G.files[G.node_file[edges[i]]].path ~= 'other/types.hpp')
        end
        local found = false
        for i = 1, #edges, graph.EDGE do if G.files[G.node_file[edges[i]]].path == 'lib/types.cpp' then found = true end end
        spec.truthy(found, 'prefer the paired implementation after the visible declaration')
    end)
    spec.it('blocks ambiguous imports, missing namespace targets and alias cycles', function()
        local G = build({ ['app.cpp'] = [[
namespace A { class Store { public: void save() {} }; void run() {} }
namespace B { class Store { public: void save() {} }; void run() {} }
void ambiguous() { using namespace A; using namespace B; Store p; p.save(); run(); }
void missing() { namespace invalid = Missing; invalid::Store p; p.save(); invalid::run(); }
namespace loop = loop;
void cyclic() { loop::run(); }
]] })
        for _, name in ipairs({ 'ambiguous', 'missing', 'cyclic' }) do spec.equal(targets(G, name), '', name) end
    end)
    spec.it('follows namespace using chains and terminates circular directives', function()
        local G = build({ ['app.cpp'] = [[
namespace A { class Store { public: void save() {} }; void run() {} }
namespace B { using namespace A; }
namespace C { using namespace B; }
namespace X { }
namespace Y { using namespace X; }
namespace X { using namespace Y; }
using namespace C;
void chained(Store* p) { p->save(); run(); C::run(); }
void cycle() { X::missing(); }
]] })
        spec.equal(targets(G, 'chained'), 'A::Store::save,A::run,A::run')
        spec.equal(targets(G, 'cycle'), '')
    end)
    spec.it('bounds cyclic include traversal and reports truncated call relationships', function()
        local G = build({ ['a.cpp'] = '#include "a.hpp"\nvoid entry() { run(); }',
            ['a.hpp'] = '#include "b.hpp"\n', ['b.hpp'] = '#include "c.hpp"\n',
            ['c.hpp'] = '#include "a.hpp"\nvoid run() {}' })
        spec.equal(targets(G, 'entry'), 'run')
        local limit = graph.MAX_INCLUDES
        graph.MAX_INCLUDES = 2
        local ok, err = pcall(function()
            local Q = graph.query(G)
            spec.equal(#Q.out[G.by_name.entry[1]], 0)
            spec.truthy(Q.incomplete)
        end)
        graph.MAX_INCLUDES = limit
        assert(ok, err)
    end)
    spec.it('reloads query-only namespace imports and refreshes callers after header edits', function()
        local root = tmp_root .. '/cpp_namespace_queries'
        local header = 'namespace A { class Store { public: void save() {} }; void run() {} }\n'
            .. 'namespace B { class Store { public: void save() {} }; void run() {} }\nnamespace api = A;\n'
        write(root .. '/types.hpp', header)
        write(root .. '/imports.hpp', '#include "types.hpp"\nusing api::Store;\nusing api::run;')
        write(root .. '/app.cpp', '#include "imports.hpp"\nvoid namespace_entry(Store* p) { p->save(); run(); }')
        local options = { cache_path = root .. '/cache.idx', lister = 'walk' }
        local idx, G = svc.get(root, options)
        idx:save(); svc.forget(root); idx, G = svc.get(root, options)
        local function check(ns)
            local text = explore.run(G, idx, 'namespace_entry ' .. ns .. '::run')
            spec.contains(text, 'namespace_entry -> ' .. ns .. '::run')
            local _, info = require('codeoutline.callers').run(G, idx, ns .. '::run')
            spec.equal(#info.callers, 1)
            spec.equal(targets(G, 'namespace_entry'), ns .. '::Store::save,' .. ns .. '::run')
            for _, rec in pairs(idx.files) do spec.nil_value(rec.cpp_aliases); spec.nil_value(rec.refs.binding) end
        end
        check('A')
        write(root .. '/types.hpp', header:gsub('api = A', 'api = B'))
        idx, G = svc.get(root, options); check('B')
        local _, info = require('codeoutline.callers').run(G, idx, 'A::run')
        spec.equal(#info.callers, 0); svc.forget(root)
    end)
    spec.it('skips include sources that cannot introduce unindexed imports', function()
        local root, includes = tmp_root .. '/cpp_import_hints', {}
        for i = 1, 24 do
            local file = 'noise' .. i .. '.hpp'
            write(root .. '/' .. file, 'namespace Noise' .. i .. ' { class Store { public: void save() {} }; }')
            includes[#includes + 1] = '#include "' .. file .. '"'
        end
        write(root .. '/types.hpp', 'namespace Selected { class Store { public: void save() {} }; }')
        write(root .. '/imports.hpp', '#include "types.hpp"\nnamespace api = Selected;\nusing api::Store;')
        write(root .. '/app.cpp', table.concat(includes, '\n') .. '\n#include "imports.hpp"\nvoid entry(Store* p) { p->save(); }')
        local idx, G = svc.get(root, { cache_path = root .. '/cache.idx', lister = 'walk' })
        for i = 1, 24 do write(root .. '/noise' .. i .. '.hpp', 'changed but irrelevant to this lookup') end
        local Q = graph.query(G)
        spec.equal(G.nodes[Q.out[G.by_name.entry[1]][1]].qualified, 'Selected::Store::save')
        spec.equal(Q.stats.ordinary.parses, 2)
        spec.truthy(idx.files['imports.hpp'].cpp_imports)
        spec.nil_value(idx.files['noise1.hpp'].cpp_imports)
        svc.forget(root)
    end)
end)

spec.describe('query-time implementation relationships', function()
    local function build(files)
        local records = {}
        for path, source in pairs(files) do records[path] = ci.parse(path, source, { ordinary_bindings = true }) end
        return graph.build({ files = records })
    end
    local function links(G, qualified)
        local result, Q = {}, graph.query(G, { explain = true })
        for i = 1, #Q.out[G.by_qualified[qualified][1]], graph.EDGE do
            local edges = Q.out[G.by_qualified[qualified][1]]
            if edges[i + 2] == 'implementation' then result[#result + 1] = G.nodes[edges[i]].qualified end
        end
        table.sort(result); return table.concat(result, ','), Q
    end
    spec.it('links TS imported contracts, abstract bases and namespace imports in both directions', function()
        local G = build({ ['api.ts'] = 'export interface TsItem {}\nexport interface TsContract { save(value: TsItem): void; }',
            ['barrel.ts'] = "export { TsContract as Contract, TsItem as Item } from './api';",
            ['store.ts'] = [[import type { Contract as C, Item } from './barrel';
abstract class TsBase implements C { abstract save(value: Item): void; }
class TsStore extends TsBase { save(item: Item): void {} }
]], ['other.ts'] = [[import * as api from './api';
class TsOther implements api.TsContract { save(item: api.TsItem): void {} }
]], ['use.ts'] = "import { TsContract } from './api';\nfunction tsUse(value: TsContract) { value.save(item); }" })
        spec.equal(links(G, 'TsContract.save'), 'TsOther.save,TsStore.save')
        spec.equal(links(G, 'TsBase.save'), 'TsStore.save')
        local Q = graph.query(G)
        spec.equal(G.nodes[Q.out[G.by_qualified.tsUse[1]][1]].qualified, 'TsContract.save')
        local contracts = {}; for i = 1, #Q.inn[G.by_qualified['TsStore.save'][1]], graph.EDGE do
            contracts[G.nodes[Q.inn[G.by_qualified['TsStore.save'][1]][i]].qualified] = true
        end
        spec.truthy(contracts['TsContract.save'] and contracts['TsBase.save'])
    end)
    spec.it('rejects TS incompatible signatures, inaccessible methods and unrelated structural matches', function()
        local G = build({ ['types.ts'] = [[interface TsI { run(value: number): string; }
class TsGood implements TsI { run(item: number): string { return ''; } }
class TsWrong implements TsI { run(item: string): string { return ''; } }
class TsReturn implements TsI { run(item: number): number { return 0; } }
class TsStatic implements TsI { static run(item: number): string { return ''; } }
class TsPrivate implements TsI { private run(item: number): string { return ''; } }
class TsProtected implements TsI { protected run(item: number): string { return ''; } }
class TsUnrelated { run(item: number): string { return ''; } }
class TsInferred implements TsI { run(item: number) { return ''; } }
class TsOptional implements TsI { run(item?: number): string { return ''; } }
class TsDefault implements TsI { run(item: number = 1): string { return ''; } }
class TsUnion implements TsI { run(item: number | string): string { return ''; } }
class TsAny implements TsI { run(item: any): string { return ''; } }
declare class TsDeclared implements TsI { run(item: number): string; }
]] })
        spec.equal(links(G, 'TsI.run'), 'TsGood.run')
    end)
    spec.it('keeps TS named parameter identity local to its module and rejects ambiguous declarations', function()
        local G = build({ ['api.ts'] = 'export class Item {}\nexport interface TsI { run(value: Item): void; }',
            ['good.ts'] = "import { Item, TsI } from './api'; class TsGood implements TsI { run(value: Item): void {} }",
            ['wrong.ts'] = "import { TsI } from './api'; class Item {} class TsWrong implements TsI { run(value: Item): void {} }",
            ['alias.ts'] = "import { TsI } from './api'; type Item = number; class TsAlias implements TsI { run(value: Item): void {} }",
            ['merged.ts'] = 'interface TsMerged { go(): void; }\ninterface TsMerged { other(): void; }\nclass TsMergedStore implements TsMerged { go(): void {} }' })
        spec.equal(links(G, 'TsI.run'), 'TsGood.run')
        spec.equal(links(G, 'TsMerged.go'), '')
    end)
    spec.it('rejects TS generic heritage, aliases, nested types and unsupported signatures', function()
        local G = build({ ['types.ts'] = [[interface TsGeneric<T> { run(): void; }
class TsGenericStore implements TsGeneric<string> { run(): void {} }
interface TsPlain { go(): void; }
class TsGenericChild<T> implements TsPlain { go(): void {} }
type TsAlias = TsPlain;
class TsAliasStore implements TsAlias { go(): void {} }
namespace TsNested { export interface TsPlain { go(): void; } export class Store implements TsPlain { go(): void {} } }
interface TsComplex { union(x: string | number): void; generic<T>(x: T): void; rest(...x: number[]): void; optional?(): void; }
class TsComplexStore implements TsComplex { union(x: string | number): void {} generic<T>(x: T): void {} rest(...x: number[]): void {} optional(): void {} }
interface TsFakeBuiltin { work(x: System.Item): void; }
class TsFakeStore implements TsFakeBuiltin { work(x: System.Item): void {} }
class TsParameter<T = string> {}
interface TsGenericParameter { work(x: TsParameter): void; }
class TsParameterStore implements TsGenericParameter { work(x: TsParameter): void {} }
]] })
        for _, q in ipairs({ 'TsGeneric.run', 'TsPlain.go', 'TsComplex.union', 'TsComplex.generic', 'TsComplex.rest', 'TsComplex.optional', 'TsFakeBuiltin.work', 'TsGenericParameter.work' }) do spec.equal(links(G, q), '', q) end
    end)
    spec.it('bounds TS hierarchy cycles and target lists using shared implementation limits', function()
        local G = build({ ['types.ts'] = [[interface TsI { run(): void; }
class TsA implements TsI { run(): void {} }
class TsB implements TsI { run(): void {} }
class TsCycleA extends TsCycleB implements TsI { run(): void {} }
class TsCycleB extends TsCycleA { run(): void {} }
]] })
        local found, Q = links(G, 'TsI.run'); spec.equal(found, 'TsA.run,TsB.run'); spec.truthy(Q.incomplete)
        local impl = require('codeoutline.implementations'); local previous = impl.MAX_TARGETS; impl.MAX_TARGETS = 1
        local ok, err = pcall(function() local _, limited = links(G, 'TsI.run'); spec.truthy(limited.incomplete) end)
        impl.MAX_TARGETS = previous; assert(ok, err)
    end)
    spec.it('does not treat TS overload declarations as abstract contracts and preserves array signatures', function()
        local G = build({ ['types.ts'] = [[class TsOverload { run(value: number): void;
run(value: number): void {} }
class TsOverride extends TsOverload { run(value: number): void {} }
interface TsArray { save(value: number[]): string[]; }
class TsArrays implements TsArray { save(value: number[]): string[] { return []; } }
class TsScalar implements TsArray { save(value: number): string[] { return []; } }
class TsUnknown extends Missing implements TsArray { save(value: number[]): string[] { return []; } }
]] })
        for _, id in ipairs(G.by_qualified['TsOverload.run']) do spec.equal(#graph.query(G).out[id], 0) end
        spec.equal(links(G, 'TsArray.save'), 'TsArrays.save')
    end)
    spec.it('uses workspace package exports for TS interface and parameter identities', function()
        local root = tmp_root .. '/ts_implementation_workspace'
        write(root .. '/package.json', '{"workspaces":["packages/*"]}')
        write(root .. '/packages/api/package.json', '{"name":"@ts-impl/api","exports":{".":"./index.ts"}}')
        write(root .. '/packages/api/index.ts', 'export class TsWorkspaceItem {}\nexport default interface TsWorkspaceContract { save(value: TsWorkspaceItem): void; }')
        write(root .. '/app.ts', "import Contract, { TsWorkspaceItem as Item } from '@ts-impl/api';\nclass TsWorkspaceStore implements Contract { save(value: Item): void {} }")
        local idx, G = svc.get(root, { cache_path = root .. '/cache.idx', lister = 'walk' })
        spec.equal(links(G, 'TsWorkspaceContract.save'), 'TsWorkspaceStore.save')
        for _, rec in pairs(idx.files) do spec.nil_value(rec.implementation_evidence) end
        svc.forget(root)
    end)
    spec.it('keeps TS implementation evidence query-only across compact reload and source edits', function()
        local root = tmp_root .. '/ts_implementations'
        write(root .. '/api.ts', 'export interface TsI { run(value: number): void; }')
        write(root .. '/store.ts', "import { TsI } from './api'; export class TsStore implements TsI { run(value: number): void {} }")
        write(root .. '/use.ts', "import { TsI } from './api'; export function tsRun(value: TsI) { value.run(1); }")
        local options = { cache_path = root .. '/cache.idx', lister = 'walk' }
        local idx, G = svc.get(root, options); idx:save(); svc.forget(root); idx, G = svc.get(root, options)
        spec.equal(links(G, 'TsI.run'), 'TsStore.run')
        local output, info = explore.run(G, idx, 'tsRun TsStore.run', { explain = true })
        spec.contains(output, 'TsI.run -> TsStore.run'); spec.equal(info.relationships_incomplete, false)
        local _, result = require('codeoutline.callers').run(G, idx, 'TsStore.run')
        local names = {}; for _, item in ipairs(result.callers) do names[item.name] = true end
        spec.truthy(names['TsI.run'] and names.tsRun)
        for _, rec in pairs(idx.files) do spec.nil_value(rec.implementation_evidence) end
        write(root .. '/store.ts', "import { TsI } from './api'; export class TsStore implements TsI { run(value: string): void {} }")
        idx, G = svc.get(root, options); spec.equal(links(G, 'TsI.run'), '')
        svc.forget(root)
    end)
    spec.it('links C# interface methods to public and explicit implementations by parameter types', function()
        local G = build({ ['contract.cs'] = 'namespace Api { public interface IStore { void Save(int value); } }',
            ['store.cs'] = [[using Api;
class Store : IStore { public void Save(int item) {} public void Save(string text) {} }
class Explicit : IStore { void IStore.Save(int item) {} }
class Wrong : IStore { private void Save(int item) {} }
class Unrelated { public void Save(int item) {} }
class Use { void Run(IStore value) { value.Save(1); } }
]] })
        local found, Q = links(G, 'Api.IStore.Save')
        spec.equal(found, 'Explicit.Save,Store.Save')
        spec.equal(G.nodes[Q.out[G.by_qualified['Use.Run'][1]][1]].qualified, 'Api.IStore.Save')
        spec.equal(#Q.inn[G.by_qualified['Store.Save'][1]], graph.EDGE)
        spec.equal(Q.inn[G.by_qualified['Store.Save'][1]][3], 'implementation')
        spec.contains(require('codeoutline.query_report').render(Q.report, G), 'possible implementation')
    end)
    spec.it('links C# abstract and virtual methods without linking hidden, static or private members', function()
        local G = build({ ['types.cs'] = [[
abstract class Base { public abstract void Run(); public virtual void Work(int x) {} public void Plain() {} }
class Derived : Base { public override void Run() {} public override void Work(int y) {} public new void Plain() {} }
class Hidden : Base { public new void Work(int x) {} public static void Run() {} }
class Closed : Base { public sealed override void Work(int x) {} }
class Further : Closed { public void Work(int x) {} }
]] })
        spec.equal(links(G, 'Base.Run'), 'Derived.Run')
        spec.equal(links(G, 'Base.Work'), 'Closed.Work,Derived.Work')
        spec.equal(links(G, 'Base.Plain'), '')
        spec.equal(links(G, 'Closed.Work'), '')
    end)
    spec.it('resolves Java imported receiver types and transitive interface implementations', function()
        local G = build({ ['api/I.java'] = 'package api; public interface I { void save(int value); }',
            ['impl/Store.java'] = [[package impl; import api.I;
abstract class Base implements I { public abstract void save(int value); }
class Store extends Base { public void save(int item) {} public void save(String item) {} }
class Private implements I { private void save(int item) {} }
class Static implements I { public static void save(int item) {} }
]], ['app/Use.java'] = [[package app; import api.I;
class Use { void run(I value) { value.save(1); } }
]], ['other/I.java'] = 'package other; interface I { void save(int value); }' })
        spec.equal(links(G, 'api.I.save'), 'impl.Store.save')
        spec.equal(links(G, 'impl.Base.save'), 'impl.Store.save')
        local Q = graph.query(G)
        spec.equal(G.nodes[Q.out[G.by_qualified['app.Use.run'][1]][1]].qualified, 'api.I.save')
    end)
    spec.it('resolves Kotlin import aliases, receiver types and open overrides', function()
        local G = build({ ['api/I.kt'] = 'package api\ninterface I { fun save(value: Int) }',
            ['impl/Store.kt'] = [[package impl
import api.I as Contract
abstract class Base : Contract { abstract override fun save(value: Int) }
class Store : Base() { override fun save(item: Int) {} }
class Hidden : Base() { fun save(item: Int) {} }
open class Open { open fun work(value: String) {} fun closed() {} }
class Override : Open() { override fun work(item: String) {} fun closed() {} }
]], ['app/Use.kt'] = [[package app
import api.I as Contract
fun run(value: Contract) { value.save(1) }
]] })
        spec.equal(links(G, 'api.I.save'), 'impl.Store.save')
        spec.equal(links(G, 'impl.Open.work'), 'impl.Override.work')
        spec.equal(links(G, 'impl.Open.closed'), '')
        local Q = graph.query(G)
        spec.equal(G.nodes[Q.out[G.by_qualified['app.run'][1]][1]].qualified, 'api.I.save')
    end)
    spec.it('rejects mismatched overloads, generic contracts, shadowed receivers and cross-language names', function()
        local G = build({ ['types.java'] = [[
interface I { void run(int n); }
class Wrong implements I { public void run(String n) {} }
interface Generic<T> { void work(); }
class Concrete implements Generic<String> { public void work() {} }
class Use { void call(I value) { { Object value = unknown; value.run(1); } value.run(1); } }
]], ['types.cs'] = 'interface I { void run(int n); } class Store : I { public void run(int n) {} }' })
        spec.equal(links(G, 'Generic.work'), '')
        local Q = graph.query(G)
        local java_i
        for _, id in ipairs(G.by_qualified['I.run']) do if G.files[G.node_file[id]].language == 'java' then java_i = id end end
        spec.equal(#Q.out[java_i], 0)
        spec.equal(#Q.out[G.by_qualified['Use.call'][1]], graph.EDGE)
    end)
    spec.it('keeps implementation evidence query-only across reloads, edits and candidate limits', function()
        local root = tmp_root .. '/implementation_queries'
        write(root .. '/contract.cs', 'public interface I { void Save(int value); }')
        write(root .. '/store.cs', 'class Store : I { public void Save(int value) {} }')
        write(root .. '/other.cs', 'class Other : I { public void Save(int value) {} }')
        write(root .. '/use.cs', 'class Use { void Run(I value) { value.Save(1); } }')
        local options = { cache_path = root .. '/cache.idx', lister = 'walk' }
        local idx, G = svc.get(root, options)
        idx:save(); svc.forget(root); idx, G = svc.get(root, options)
        spec.equal(links(G, 'I.Save'), 'Other.Save,Store.Save')
        local output, info = explore.run(G, idx, 'Use.Run Store.Save', { explain = true })
        spec.contains(output, 'I.Save -> Store.Save')
        spec.contains(output, 'possible implementation')
        spec.equal(info.relationships_incomplete, false)
        local _, callers = require('codeoutline.callers').run(G, idx, 'Store.Save')
        local names = {}; for _, caller in ipairs(callers.callers) do names[caller.name] = true end
        spec.truthy(names['I.Save'] and names['Use.Run'])
        for _, rec in pairs(idx.files) do spec.nil_value(rec.implementation_evidence); spec.nil_value(rec.refs.binding) end
        local implementations = require('codeoutline.implementations')
        local limit = implementations.MAX_TARGETS
        implementations.MAX_TARGETS = 1
        local ok, err = pcall(function()
            local _, limited = links(G, 'I.Save'); spec.truthy(limited.incomplete)
            local _, result = explore.run(G, idx, 'I.Save'); spec.truthy(result.relationships_incomplete)
        end)
        implementations.MAX_TARGETS = limit; assert(ok, err)
        write(root .. '/store.cs', 'class Store : I { public void Save(string value) {} }')
        idx, G = svc.get(root, options)
        spec.equal(links(G, 'I.Save'), 'Other.Save')
        local _, changed = require('codeoutline.callers').run(G, idx, 'Store.Save')
        spec.equal(#changed.callers, 0)
        svc.forget(root)
    end)
    spec.it('keeps C# project boundaries and resolves aliased parameter types in their declaring files', function()
        local root = tmp_root .. '/implementation_projects'
        write(root .. '/app/app.csproj', '<Project />')
        write(root .. '/other/other.csproj', '<Project />')
        write(root .. '/app/contract.cs', 'using Model = Data.Item; namespace Data { public class Item {} }\n'
            .. 'namespace Api { public interface I { void Save(Model value); } }')
        write(root .. '/app/store.cs', 'using Api; class Store : I { public void Save(Data.Item value) {} }')
        write(root .. '/other/contract.cs', 'namespace Api { public interface I { void Save(Data.Item value); } }\n'
            .. 'namespace Data { public class Item {} }')
        write(root .. '/other/store.cs', 'using Api; class Other : I { public void Save(Data.Item value) {} }')
        local _, G = svc.get(root, { cache_path = root .. '/cache.idx', lister = 'walk' })
        local id = G.by_qualified['Api.I.Save'][1]
        spec.equal(G.files[G.node_file[id]].path, 'app/contract.cs')
        local Q = graph.query(G)
        spec.equal(#Q.out[id], graph.EDGE)
        spec.equal(G.nodes[Q.out[id][1]].qualified, 'Store.Save')
        svc.forget(root)
    end)
    spec.it('respects Java import precedence, package access and cyclic inheritance barriers', function()
        local G = build({ ['a/I.java'] = 'package a; public interface I { void run(int value); }',
            ['b/I.java'] = 'package b; public interface I { void run(int value); }',
            ['b/Store.java'] = 'package b; import a.*; import a.I; class Store implements I { public void run(int value) {} }',
            ['a/Base.java'] = 'package a; public class Base { void work() {} }',
            ['b/Derived.java'] = 'package b; import a.Base; class Derived extends Base { public void work() {} }',
            ['cycle.java'] = 'class A extends B { void loop() {} } class B extends A { void loop() {} }' })
        spec.equal(links(G, 'a.I.run'), 'b.Store.run')
        spec.equal(links(G, 'b.I.run'), '')
        spec.equal(links(G, 'a.Base.work'), '')
        local found, Q = links(G, 'A.loop')
        spec.equal(found, ''); spec.truthy(Q.incomplete)
    end)
end)

spec.describe('include-driven C/C++ source fragments', function()
    local index = require('codeoutline.index')
    local serial = 0
    local function project(files, lister)
        serial = serial + 1
        local root = tmp_root .. '/fragments/' .. serial
        for path, source in pairs(files) do write(root .. '/' .. path, source) end
        return index.open(root, { cache_path = root .. '.idx', lister = lister or 'walk' }), root
    end
    for _, lister in ipairs({ 'walk', 'rg' }) do
        spec.it('indexes only reachable fragments, static calls and cycles with ' .. lister, function()
            if lister == 'rg' and not index.rg_available() then return end
            local idx = project({ ['main.c'] = '#include "parts/one.fragment"\nint FragmentEntry(void) { return FragmentPart(); }',
                ['other.c'] = 'int FragmentUnrelated(void) { return FragmentLeaf(); }',
                ['parts/one.fragment'] = '#include "two.bits"\nstatic inline int FragmentPart(void) { return FragmentLeaf(); }',
                ['parts/two.bits'] = '#include "one.fragment"\nstatic inline int FragmentLeaf(void) { return 7; }',
                ['unused.fragment'] = 'int FragmentUnused(void) { return 9; }' }, lister)
            local stats = idx:refresh_all()
            spec.equal(stats.parsed, 4); spec.equal(stats.failed, 0)
            spec.equal(idx.files['parts/two.bits'].cpp_fragment, 'c')
            spec.nil_value(idx.files['unused.fragment']); spec.nil_value(ci.language('parts/two.bits'))
            local G = idx:symbols(); local Q = graph.query(G)
            local entry, part, leaf = G.by_name.FragmentEntry[1], G.by_name.FragmentPart[1], G.by_name.FragmentLeaf[1]
            spec.equal(Q.out[entry][1], part); spec.equal(Q.out[part][1], leaf)
            spec.equal(#Q.out[G.by_name.FragmentUnrelated[1]], 0)
            spec.truthy(idx:save())
            local loaded = index.open(idx.root, { cache_path = idx.cache_path, lister = lister })
            spec.truthy(loaded.cache_loaded); spec.truthy(loaded.files['parts/two.bits'])
            spec.equal(loaded:refresh_all().parsed, 0)
            spec.truthy(loaded.files['parts/two.bits'])
        end)
    end
    spec.it('discovers late dependencies and removes orphaned fragment cycles incrementally', function()
        local idx, root = project({ ['main.c'] = '#include "late.bits"\nint FragmentRoot(void) { return LatePart(); }' })
        spec.equal(idx:refresh_all().parsed, 1)
        write(root .. '/late.bits', '#include "child.bits"\nint LatePart(void) { return ChildPart(); }')
        write(root .. '/child.bits', '#include "late.bits"\nint ChildPart(void) { return 1; }')
        local stats = idx:refresh_changed({ ['late.bits'] = true, ['child.bits'] = true }, true)
        spec.equal(stats.parsed, 2); spec.truthy(idx.files['child.bits'])
        local before = idx.files['child.bits'].crc
        idx.files['child.bits'].checked = (idx.files['child.bits'].mtime or os.time()) + 5
        write(root .. '/child.bits', '#include "late.bits"\nint ChildPart(void) { return 2; }')
        stats = idx:refresh_changed({ ['child.bits'] = true }, false)
        spec.equal(stats.parsed, 1); spec.truthy(idx.files['child.bits'].crc ~= before)
        local G = idx:symbols()
        write(root .. '/main.c', 'int FragmentRoot(void) { return 0; }')
        stats = idx:refresh_changed({ ['main.c'] = true }, false)
        spec.equal(stats.removed, 2); spec.nil_value(idx.files['late.bits']); spec.nil_value(idx.files['child.bits'])
        spec.nil_value(G.by_name.LatePart)
    end)
    spec.it('honors include paths, ambiguity, ignored shadows and configuration refresh', function()
        local idx, root = project({ ['main.cpp'] = '#include <api.part>\nvoid FragmentConfigured() {}',
            ['one/api.part'] = 'void FragmentOne() {}', ['two/api.part'] = 'void FragmentTwo() {}' })
        idx:refresh_all(); spec.nil_value(idx.files['one/api.part']); spec.nil_value(idx.files['two/api.part'])
        write(root .. '/.codeoutline.json', '{"includePaths":["one"]}')
        idx:refresh({ paths = { root .. '/.codeoutline.json' } })
        spec.truthy(idx.files['one/api.part']); spec.nil_value(idx.files['two/api.part'])
        write(root .. '/.codeoutline.json', '{"includePaths":["two"]}')
        -- Hidden config files need not be reported by the native watcher.
        idx.next_full = os.time() + 300
        idx:refresh({ full_interval = 300 })
        spec.nil_value(idx.files['one/api.part']); spec.truthy(idx.files['two/api.part'])
        write(root .. '/.gitignore', 'api.part\n')
        idx:refresh_all(); spec.nil_value(idx.files['two/api.part'])
        local shadow = project({ ['main.c'] = '#include "api.part"\nvoid FragmentShadow() {}',
            ['api.part'] = 'void HiddenFragment() {}', ['lib/api.part'] = 'void WrongFragment() {}',
            ['.gitignore'] = '/api.part\n', ['.codeoutline.json'] = '{"includePaths":["lib"]}' })
        shadow:refresh_all(); spec.nil_value(shadow.files['api.part']); spec.nil_value(shadow.files['lib/api.part'])
    end)
    spec.it('keeps supported language boundaries and skips binary or foreign-language fragments', function()
        local idx = project({ ['main.c'] = '#include "blob.part"\n#include "foreign.part"\n#include "real.lua"\nvoid FragmentBinary() {}',
            ['blob.part'] = 'int Blob;\0binary', ['foreign.part'] = 'local function foreign_lua() return 1 end',
            ['real.lua'] = 'function ExistingLua() end', ['loader.lua'] = 'dofile("unused.part")',
            ['unused.part'] = 'int NotIncluded(void) { return 0; }' })
        local stats = idx:refresh_all()
        spec.equal(stats.failed, 0); spec.nil_value(idx.files['blob.part']); spec.nil_value(idx.files['foreign.part'])
        spec.equal(idx.files['real.lua'].language, 'lua'); spec.nil_value(idx.files['unused.part'])
    end)
    spec.it('retains C++ hints and GBK source repair across cache reload and reindex', function()
        local idx, root = project({ ['main.cpp'] = '#include "box.part"\nvoid FragmentCpp() {}',
            ['box.part'] = '// \214\208\206\196\nclass FragmentBox { public: int size() { return 1; } };' })
        idx:refresh_all()
        local rec = idx.files['box.part']; spec.equal(rec.language, 'cpp'); spec.equal(rec.cpp_fragment, 'cpp')
        local source = idx:query_source('box.part'); spec.contains(source, 'FragmentBox')
        spec.equal(idx.files['box.part'].encoding, 'gbk'); spec.equal(idx.files['box.part'].cpp_fragment, 'cpp')
        spec.truthy(idx:save())
        local loaded = index.open(root, { cache_path = idx.cache_path, lister = 'walk' })
        spec.truthy(loaded.cache_loaded); spec.equal(loaded.files['box.part'].cpp_fragment, 'cpp')
        spec.equal(loaded:refresh_all().parsed, 0)
    end)
    spec.it('bounds additional files and reports a limited include closure', function()
        local fragments = require('codeoutline.cpp_fragments')
        local idx = project({ ['main.c'] = '#include "a.part"', ['a.part'] = '#include "b.part"\nvoid FragmentA() {}',
            ['b.part'] = 'void FragmentB() {}' })
        local cap = fragments.MAX_FILES; fragments.MAX_FILES = 1
        local ok, stats = pcall(function() return idx:refresh_all() end)
        fragments.MAX_FILES = cap; spec.truthy(ok, tostring(stats))
        spec.truthy(stats.fragment_limited); spec.truthy(idx.files['a.part']); spec.nil_value(idx.files['b.part'])
        for _, field in ipairs({ 'MAX_BYTES', 'MAX_DEPTH' }) do
            local limit = fragments[field]; fragments[field] = 1
            local ok, stats = pcall(function() return idx:refresh_all() end)
            fragments[field] = limit; spec.truthy(ok, tostring(stats)); spec.truthy(stats.fragment_limited)
            if field == 'MAX_BYTES' then spec.nil_value(idx.files['a.part']) end
        end
    end)
    spec.it('rejects external dependencies and honors directory-specific include rules', function()
        local idx, root = project({ ['app/main.cpp'] = '#include <chosen.piece>',
            ['one/chosen.piece'] = 'void FragmentRuleOne() {}', ['two/chosen.piece'] = 'void FragmentRuleTwo() {}',
            ['.codeoutline.json'] = '{"includePaths":["one"],"includePathRules":[{"directory":"app","paths":["two"]}]}' })
        idx:refresh_all(); spec.truthy(idx.files['two/chosen.piece']); spec.nil_value(idx.files['one/chosen.piece'])
        write(root .. '_external/outside.piece', 'void FragmentExternal() {}')
        write(root .. '/app/main.cpp', '#include <outside.piece>')
        write(root .. '/.codeoutline.json', '{"includePaths":["../' .. root:match('([^/]+)$') .. '_external"]}')
        idx:refresh_all(); spec.nil_value(idx.files['two/chosen.piece'])
        for path in pairs(idx.files) do spec.truthy(not path:find('outside.piece', 1, true)) end
    end)
    spec.it('settles mixed C/C++ hints through nested cached includes without repeated parsing', function()
        local idx, root = project({ ['a.c'] = '#include "shared.part"', ['b.cpp'] = '#include "bridge.part"',
            ['bridge.part'] = '#include "shared.part"\nvoid MixedBridge() {}',
            ['shared.part'] = 'int MixedShared(void) { return 1; }' })
        idx:refresh_all(); spec.equal(idx.files['shared.part'].cpp_fragment, 'cpp')
        local stats = idx:refresh_all(); spec.equal(stats.parsed, 0)
        write(root .. '/b.cpp', 'void MixedCppRemoved() {}')
        stats = idx:refresh_changed({ ['b.cpp'] = true }, false)
        spec.nil_value(idx.files['bridge.part']); spec.equal(idx.files['shared.part'].cpp_fragment, 'c')
        spec.equal(idx:refresh_all().parsed, 0)
        write(root .. '/shared.part', '#include "bridge.part"\nclass SyntaxCppPart {};')
        idx:refresh_changed({ ['shared.part'] = true }, false)
        spec.truthy(idx.files['shared.part'].cpp_fragment_cpp)
        spec.equal(idx:refresh_all().parsed, 0)
    end)
end)

spec.describe('query-owned C/C++ include search paths', function()
    local serial = 0
    local function build(files, config)
        serial = serial + 1
        local root, records = tmp_root .. '/include_paths/' .. serial, {}
        for path, source in pairs(files) do
            write(root .. '/' .. path, source)
            records[path] = ci.parse(path, source, { ordinary_bindings = true })
        end
        if config then write(root .. '/.codeoutline.json', xutils.json_pack(config)) end
        return graph.build({ root = root, files = records })
    end
    local store = 'namespace Include { struct Store { void save() {} }; }'
    spec.it('uses ordered includePaths and reloads configuration without rebuilding symbol tables', function()
        local G = build({ ['one/api.hpp'] = store, ['two/api.hpp'] = store,
            ['app/main.cpp'] = '#include <api.hpp>\nvoid IncludeEntry(Include::Store *value) { value->save(); }' },
            { includePaths = { 'two', 'one' } })
        spec.equal(edges_from(G, 'IncludeEntry'), 'save@two/api.hpp')
        write(G.root .. '/.codeoutline.json', '{"includePaths":["one","two"]}')
        spec.equal(edges_from(G, 'IncludeEntry'), 'save@one/api.hpp')
        write(G.root .. '/.codeoutline.json', '{"includePaths":["one/../two/.","two"]}')
        spec.equal(edges_from(G, 'IncludeEntry'), 'save@two/api.hpp')
        if require('codeoutline.path').windows then
            write(G.root .. '/.codeoutline.json', '{"includePaths":["TWO"]}')
            spec.equal(edges_from(G, 'IncludeEntry'), 'save@two/api.hpp')
        end
    end)
    spec.it('prefers quoted local headers and blocks suffix guesses after explicit search misses', function()
        local G = build({ ['one/api.hpp'] = store, ['app/api.hpp'] = store, ['other/missing.hpp'] = store,
            ['app/quoted.cpp'] = '#include "api.hpp"\nvoid Quoted(Include::Store *p) { p->save(); }',
            ['app/angle.cpp'] = '#include <api.hpp>\nvoid Angled(Include::Store *p) { p->save(); }',
            ['app/missing.cpp'] = '#include <missing.hpp>\nvoid MissingInclude(Include::Store *p) { p->save(); }' },
            { includePaths = { 'one' } })
        spec.equal(edges_from(G, 'Quoted'), 'save@app/api.hpp')
        spec.equal(edges_from(G, 'Angled'), 'save@one/api.hpp')
        spec.equal(edges_from(G, 'MissingInclude'), '')
        write(G.root .. '/.codeoutline.json', '{"includePaths":[]}')
        spec.equal(edges_from(G, 'Quoted'), 'save@app/api.hpp')
        spec.equal(edges_from(G, 'Angled'), '')
        os.remove(G.root .. '/.codeoutline.json')
        local found = graph.dependencies(G, G.file_index['app/angle.cpp'], { include_paths = { 'one' } })
        spec.truthy(found[G.file_index['one/api.hpp']]); spec.nil_value(found[G.file_index['app/api.hpp']])
    end)
    spec.it('selects the longest directory rule with component boundaries and shared default paths', function()
        local files = { ['one/api.hpp'] = store, ['two/api.hpp'] = store, ['fallback/api.hpp'] = store,
            ['fallback/shared.hpp'] = 'namespace Include { struct Shared { void common() {} }; }' }
        for name, dir in pairs({ Aur = 'aur', Nested = 'aur/nested', Server = 'server', Boundary = 'aurora' }) do
            files[dir .. '/client.cpp'] = '#include <api.hpp>\n#include <shared.hpp>\nvoid ' .. name
                .. '(Include::Store *p, Include::Shared *s) { p->save(); s->common(); }'
        end
        local G = build(files, { includePaths = { 'fallback' }, includePathRules = {
            { directory = 'aur', paths = { 'one' } }, { directory = 'aur/nested', paths = { 'two' } },
            { directory = 'server', paths = { 'two' } } } })
        spec.equal(edges_from(G, 'Aur'), 'common@fallback/shared.hpp save@one/api.hpp')
        spec.equal(edges_from(G, 'Nested'), 'common@fallback/shared.hpp save@two/api.hpp')
        spec.equal(edges_from(G, 'Server'), 'common@fallback/shared.hpp save@two/api.hpp')
        spec.equal(edges_from(G, 'Boundary'), 'common@fallback/shared.hpp save@fallback/api.hpp')
    end)
    spec.it('shares indirect includes and pairs the selected header with its own directory implementation', function()
        local G = build({ ['one/api.hpp'] = 'namespace Include { struct Store { void save(); }; }',
            ['one/api.cpp'] = '#include "api.hpp"\nvoid Include::Store::save() {}',
            ['one/bridge.hpp'] = '#include "api.hpp"\n',
            ['two/api.hpp'] = 'namespace Include { struct Store { void save(); }; }',
            ['two/api.cpp'] = '#include "api.hpp"\nvoid Include::Store::save() {}',
            ['app/main.cpp'] = '#include <bridge.hpp>\nvoid IndirectInclude(Include::Store *p) { p->save(); }' },
            { includePaths = { 'one', 'two' } })
        spec.equal(edges_from(G, 'IndirectInclude'), 'save@one/api.cpp')
        local deps, paired = graph.visible_dependencies(G, G.file_index['app/main.cpp'])
        spec.truthy(deps[G.file_index['one/api.hpp']]); spec.nil_value(deps[G.file_index['two/api.hpp']])
        spec.truthy(paired[G.file_index['one/api.cpp']]); spec.nil_value(paired[G.file_index['two/api.cpp']])
        local _, own_paired = graph.visible_dependencies(G, G.file_index['one/api.cpp'])
        spec.nil_value(own_paired[G.file_index['two/api.cpp']])
    end)
    spec.it('stops at existing unindexed headers without falling through to an indexed duplicate', function()
        local G = build({ ['two/api.hpp'] = store,
            ['app/main.cpp'] = '#include <api.hpp>\nvoid UnindexedInclude(Include::Store *p) { p->save(); }' },
            { includePaths = { 'hidden', 'two' } })
        spec.equal(edges_from(G, 'UnindexedInclude'), 'save@two/api.hpp')
        write(G.root .. '/hidden/api.hpp', store)
        spec.equal(edges_from(G, 'UnindexedInclude'), '')
        local files, selected, path = require('codeoutline.cpp_includes').resolve(G, G.file_index['app/main.cpp'],
            G.files[G.file_index['app/main.cpp']].imports[1], {})
        spec.equal(#files, 0); spec.truthy(selected); spec.equal(path, G.root .. '/hidden/api.hpp')
    end)
    spec.it('pairs configured C headers with sources in separate directories without crossing projects', function()
        local G = build({ ['one/include/entry.h'] = 'int separate_include_target(void);',
            ['two/include/entry.h'] = 'int separate_include_target(void);',
            ['one/src/entry.c'] = '#include "../include/entry.h"\nint separate_include_target(void) { return 1; }',
            ['two/src/entry.c'] = '#include "../include/entry.h"\nint separate_include_target(void) { return 2; }',
            ['app/main.c'] = '#include <entry.h>\nvoid SeparateIncludeEntry(void) { separate_include_target(); }' },
            { includePaths = { 'one/include', 'two/include' } })
        spec.equal(edges_from(G, 'SeparateIncludeEntry'), 'separate_include_target@one/src/entry.c')
    end)
    spec.it('uses include scopes for C declarations and C++ virtual implementation relationships', function()
        local G = build({ ['one/api.hpp'] = 'namespace Include { struct Base { virtual void run() = 0; }; }',
            ['two/api.hpp'] = 'namespace Include { struct Base { virtual void run() = 0; }; }',
            ['app/impl.cpp'] = '#include <api.hpp>\nstruct IncludeStore : Include::Base { void run() {} };',
            ['one/capi.h'] = 'int include_c_target(void);', ['two/capi.h'] = 'int include_c_target(void);',
            ['one/capi.c'] = '#include "capi.h"\nint include_c_target(void) { return 1; }',
            ['two/capi.c'] = '#include "capi.h"\nint include_c_target(void) { return 2; }',
            ['app/main.c'] = '#include <capi.h>\nvoid CIncludeEntry(void) { include_c_target(); }' },
            { includePaths = { 'one', 'two' } })
        spec.equal(edges_from(G, 'CIncludeEntry'), 'include_c_target@one/capi.c')
        local Q, count = graph.query(G), 0
        for _, id in ipairs(G.by_qualified['Include::Base::run']) do
            local expected = G.files[G.node_file[id]].path == 'one/api.hpp' and graph.EDGE or 0
            spec.equal(#Q.out[id], expected); count = count + #Q.out[id]
        end
        spec.equal(count, graph.EDGE)
    end)
    spec.it('validates include configuration, limits, root boundaries and cancellation', function()
        local includes = require('codeoutline.cpp_includes')
        local G = build({ ['main.cpp'] = '#include <api.hpp>\n', ['one/api.hpp'] = store })
        local invalid = { { includePaths = 'one' }, { includePaths = false }, { includePaths = { 1 } }, { includePaths = { ['x'] = 'one' } },
            { includePaths = { 'C:relative' } }, { includePathRules = 'one' }, { includePathRules = false }, { includePathRules = { false } },
            { includePathRules = { { directory = '../outside', paths = {} } } },
            { includePathRules = { { directory = '/absolute', paths = {} } } },
            { includePathRules = { { directory = '.', typo = {} } } },
            { includePathRules = { { directory = 'one', paths = {} }, { directory = './one', paths = {} } } } }
        for _, config in ipairs(invalid) do
            write(G.root .. '/.codeoutline.json', xutils.json_pack(config))
            spec.equal(pcall(includes.context, G), false)
        end
        write(G.root .. '/.codeoutline.json', '{"includePaths":["one"]}')
        local limit = includes.MAX_PATHS; includes.MAX_PATHS = 0
        local ok = pcall(includes.context, G); includes.MAX_PATHS = limit; spec.equal(ok, false)
        local control = require('codeoutline.control'); local previous = control.callback
        control.callback = function() error(control.cancelled('cancel include search')) end
        local err; ok, err = pcall(graph.visible_dependencies, G, G.file_index['main.cpp'], {})
        control.callback = previous
        spec.equal(ok, false); spec.truthy(control.is_interrupted(err))
    end)
    spec.it('preserves renamed Lua native callers while filtering Lua bindings for ordinary C++ targets', function()
        local root = tmp_root .. '/include_native_callers'
        write(root .. '/native.c', [[static int native_saved(lua_State *L) { return 0; }
static const luaL_Reg funcs[] = {{"run", native_saved}, {NULL, NULL}};
int luaopen_native(lua_State *L) { luaL_newlib(L, funcs); return 1; }]])
        write(root .. '/use.lua', 'local api = require("native")\nfunction NativeIncludeCaller() api.run() end')
        write(root .. '/plain.cpp', 'struct PlainInclude { void run() {} };')
        local options = { cache_path = root .. '/cache.idx', lister = 'walk' }
        local idx, G = svc.get(root, options)
        idx:save(); svc.forget(root); idx, G = svc.get(root, options)
        local Q = graph.query(G)
        local callers = Q.inn[G.by_name.native_saved[1]]
        local found = false
        for i = 1, #callers, graph.EDGE do if G.nodes[callers[i]].qualified == 'NativeIncludeCaller' then found = true end end
        spec.truthy(found)
        spec.equal(#Q.inn[G.by_qualified['PlainInclude::run'][1]], 0)
        svc.forget(root)
    end)
end)

spec.describe('query-time C++ virtual implementations', function()
    local function build(files)
        local records = {}
        for path, source in pairs(files) do records[path] = ci.parse(path, source, { ordinary_bindings = true }) end
        return graph.build({ files = records })
    end
    local function targets(G, qualified, pick)
        local id = G.by_qualified[qualified][pick or 1]
        local Q, result = graph.query(G, { explain = true }), {}
        local edges = Q.out[id]
        for i = 1, #edges, graph.EDGE do
            if edges[i + 2] == 'implementation' then
                result[#result + 1] = G.nodes[edges[i]].qualified .. '@' .. G.files[G.node_file[edges[i]]].path
            end
        end
        table.sort(result); return table.concat(result, ','), Q
    end
    spec.it('links private pure virtual declarations to transitive unmarked overrides and out-of-line definitions', function()
        local G = build({ ['api.hpp'] = [[namespace Api {
class Base { virtual void save(int value) const & = 0; public: virtual void plain() {} };
class Middle : public Base { public: void save(int item) const & = 0; };
class Store : public Middle { public: void save(int item) const & override; void plain() {} };
}]], ['implementation.cpp'] = '#include "api.hpp"\nvoid Api::Store::save(int item) const & {}',
            ['use.cpp'] = '#include "api.hpp"\nvoid Run(Api::Base *value) { value->save(1); }' })
        spec.equal(targets(G, 'Api::Base::save'), 'Api::Store::save@implementation.cpp')
        spec.equal(targets(G, 'Api::Middle::save'), 'Api::Store::save@implementation.cpp')
        spec.equal(targets(G, 'Api::Base::plain'), 'Api::Store::plain@api.hpp')
        local Q = graph.query(G)
        local found = {}
        for _, id in ipairs(G.by_qualified['Api::Store::save']) do
            for i = 1, #Q.inn[id], graph.EDGE do found[G.nodes[Q.inn[id][i]].qualified] = true end
        end
        spec.truthy(found['Api::Base::save'] and found['Api::Middle::save'])
        spec.equal(G.nodes[Q.out[G.by_name.Run[1]][1]].qualified, 'Api::Base::save')
    end)
    spec.it('distinguishes overloads, pointee cv, member cv and ref qualifiers and return types', function()
        local G = build({ ['types.cpp'] = [[
struct Item {};
struct Base { virtual int work(const Item *item, unsigned int count) const & = 0; };
struct Good : Base { int work(Item const *item, const unsigned int count) const & {} };
struct WrongPointee : Base { int work(Item *item, unsigned int count) const & {} };
struct WrongConst : Base { int work(const Item *item, unsigned int count) & {} };
struct WrongRef : Base { int work(const Item *item, unsigned int count) const && {} };
struct WrongReturn : Base { long work(const Item *item, unsigned int count) const & {} };
struct WrongArity : Base { int work(const Item *item) const & {} };
struct Other { int work(const Item *item, unsigned int count) const & {} };
]] })
        spec.equal(targets(G, 'Base::work'), 'Good::work@types.cpp')
    end)
    spec.it('respects final methods and classes, ordinary nonvirtual methods and intermediate overrides', function()
        local G = build({ ['types.cpp'] = [[
struct Base { virtual void run() {} void plain() {} };
struct Middle : Base { void run() {} void plain() {} };
struct Closed : Middle { void run() final {} };
struct Invalid : Closed { void run() {} };
struct Leaf final : Base { void run() {} };
struct InvalidLeaf : Leaf { void run() {} };
]] })
        spec.equal(targets(G, 'Base::run'), 'Closed::run@types.cpp,Leaf::run@types.cpp,Middle::run@types.cpp')
        spec.equal(targets(G, 'Middle::run'), 'Closed::run@types.cpp')
        spec.equal(targets(G, 'Closed::run'), '')
        spec.equal(targets(G, 'Base::plain'), '')
    end)
    spec.it('reuses namespace aliases, using imports and indirect includes without crossing duplicate type boundaries', function()
        local G = build({ ['one/api.hpp'] = 'namespace N { struct Item {}; struct Base { virtual void save(const Item&) = 0; }; }',
            ['one/bridge.hpp'] = '#include "api.hpp"\nnamespace A = N; using N::Item; using Contract = A::Base;',
            ['one/store.cpp'] = '#include "bridge.hpp"\nstruct Store : Contract { void save(const Item&) {} };',
            ['two/api.hpp'] = 'namespace N { struct Item {}; struct Base { virtual void save(const Item&) = 0; }; }',
            ['two/store.cpp'] = '#include "api.hpp"\nstruct Other : N::Base { void save(const N::Item&) {} };' })
        for _, id in ipairs(G.by_qualified['N::Base::save']) do
            local expected = G.files[G.node_file[id]].path == 'one/api.hpp' and 'Store::save@one/store.cpp' or 'Other::save@two/store.cpp'
            local pick = G.by_qualified['N::Base::save'][1] == id and 1 or 2
            spec.equal(targets(G, 'N::Base::save', pick), expected)
        end
    end)
    spec.it('treats templates, multiple and virtual inheritance, function pointers and decorated aliases as barriers', function()
        local G = build({ ['barriers.cpp'] = [[
struct Item {}; using Ptr = Item*;
struct Base { virtual void run() = 0; virtual void ptr(Item*) = 0; virtual void cb(void (*fn)(int)) = 0; };
struct Extra {};
struct Multiple : Base, Extra { void run() {} };
struct Virtual : virtual Base { void run() {} };
template<class T> struct Generic : Base { void run() {} };
struct Alias : Base { void ptr(Ptr) {} };
struct Callback : Base { void cb(void (*fn)(int)) {} };
struct Ordinary : Base { template<class T> void run() {} };
template<class T> struct Outer { struct Nested : Base { void run() {} }; };
]] })
        spec.equal(targets(G, 'Base::run'), '')
        spec.equal(targets(G, 'Base::ptr'), '')
        spec.equal(targets(G, 'Base::cb'), '')
    end)
    spec.it('keeps virtual evidence query-only after reloads and edits and marks candidate limits', function()
        local root = tmp_root .. '/cpp_implementations'
        write(root .. '/api.hpp', 'struct Base { virtual void Save(int) = 0; };\nstruct Store : Base { void Save(int); };')
        write(root .. '/body.cpp', '#include "api.hpp"\nvoid Store::Save(int item) {}')
        write(root .. '/use.cpp', '#include "api.hpp"\nvoid Run(Base *value) { value->Save(1); }')
        local options = { cache_path = root .. '/cache.idx', lister = 'walk' }
        local idx, G = svc.get(root, options)
        idx:save(); svc.forget(root); idx, G = svc.get(root, options)
        spec.equal(targets(G, 'Base::Save'), 'Store::Save@body.cpp')
        local output, result = explore.run(G, idx, 'Run Store::Save', { explain = true })
        spec.contains(output, 'possible implementation')
        spec.equal(result.relationships_incomplete, false)
        local _, callers = require('codeoutline.callers').run(G, idx, 'Store::Save')
        local names = {}; for _, caller in ipairs(callers.callers) do names[caller.name] = true end
        spec.truthy(names['Base::Save'] and names.Run)
        for _, rec in pairs(idx.files) do spec.nil_value(rec.implementation_evidence); spec.nil_value(rec.cpp_aliases) end
        local impl = require('codeoutline.implementations'); local limit = impl.MAX_CANDIDATES
        impl.MAX_CANDIDATES = 1
        local ok, err = pcall(function() local _, Q = targets(G, 'Base::Save'); spec.truthy(Q.incomplete) end)
        impl.MAX_CANDIDATES = limit; assert(ok, err)
        write(root .. '/body.cpp', '#include "api.hpp"\nvoid Store::Save(long item) {}')
        write(root .. '/api.hpp', 'struct Base { virtual void Save(int) = 0; };\nstruct Store : Base { void Save(long); };')
        idx, G = svc.get(root, options)
        spec.equal(targets(G, 'Base::Save'), '')
        svc.forget(root)
    end)
    spec.it('reports C++ hierarchy, target and alias budgets and preserves cancellation', function()
        local G = build({ ['api.hpp'] = 'struct Base { virtual void run() = 0; };',
            ['impl.cpp'] = '#include "api.hpp"\nstruct A : Base { void run() {} }; struct B : Base { void run() {} };' })
        local impl, cpp = require('codeoutline.implementations'), require('codeoutline.cpp_implementations')
        local targets_limit, depth_limit, aliases_limit = impl.MAX_TARGETS, impl.MAX_DEPTH, cpp.MAX_ALIAS_FILES
        local ok, err = pcall(function()
            impl.MAX_TARGETS = 1
            local found, Q = targets(G, 'Base::run'); spec.truthy(found ~= ''); spec.truthy(Q.incomplete)
            impl.MAX_TARGETS, impl.MAX_DEPTH = targets_limit, 0
            found, Q = targets(G, 'Base::run'); spec.equal(found, ''); spec.truthy(Q.incomplete)
            impl.MAX_DEPTH, cpp.MAX_ALIAS_FILES = depth_limit, 0
            found, Q = targets(G, 'Base::run'); spec.equal(found, ''); spec.truthy(Q.incomplete)
        end)
        impl.MAX_TARGETS, impl.MAX_DEPTH, cpp.MAX_ALIAS_FILES = targets_limit, depth_limit, aliases_limit
        assert(ok, err)
        local control = require('codeoutline.control'); local previous = control.callback
        control.callback = function() error(control.cancelled('cancel C++ implementation query')) end
        ok, err = pcall(function() targets(G, 'Base::run') end)
        control.callback = previous
        spec.equal(ok, false); spec.truthy(control.is_interrupted(err))
    end)
    spec.it('avoids expanding same-name candidates for a nonvirtual root method', function()
        local files = { ['base.cpp'] = 'struct Plain { void run() {} };' }
        for i = 1, 20 do files['other' .. i .. '.cpp'] = 'struct Unrelated' .. i .. ' { void run() {} };' end
        local G = build(files)
        local impl = require('codeoutline.implementations'); local limit = impl.MAX_CANDIDATES
        impl.MAX_CANDIDATES = 1
        local ok, err = pcall(function()
            local found, Q = targets(G, 'Plain::run')
            spec.equal(found, ''); spec.equal(Q.incomplete, false); spec.equal(Q.stats.implementations.candidates, 0)
        end)
        impl.MAX_CANDIDATES = limit; assert(ok, err)
    end)
end)

spec.describe('query-owned Cargo packages', function()
    local cargo = require('codeoutline.rust_packages')
    local function build(files, root)
        local records = {}
        for path, source in pairs(files) do records[path] = ci.parse(path, source, { ordinary_bindings = true }) end
        return graph.build({ files = records, root = root })
    end
    spec.it('resolves path dependencies, renamed crates and custom library entry names without sibling guesses', function()
        local root = tmp_root .. '/cargo_paths'
        write(root .. '/app/Cargo.toml', '[package]\nname="app"\n[dependencies]\nselected={path="../actual", package="actual-package"}\n'
            .. 'actual-package={path="../actual"}\nremote="1"\n')
        write(root .. '/actual/Cargo.toml', '[package]\nname="actual-package"\n[lib]\nname="custom_api"\npath="code/entry.rs"\n')
        write(root .. '/unrelated/Cargo.toml', '[package]\nname="remote"\n')
        local G = build({ ['app/src/main.rs'] = 'fn CargoRun() { selected::save(); custom_api::save(); remote::save(); actual_package::save(); }',
            ['actual/code/entry.rs'] = 'pub fn save() {} fn hidden() {}',
            ['unrelated/src/lib.rs'] = 'pub fn save() {}' }, root)
        spec.equal(edges_from(G, 'CargoRun'), 'save@actual/code/entry.rs save@actual/code/entry.rs')
        local ctx = {}; local crates = cargo.crates(G, G.file_index['app/src/main.rs'], ctx)
        spec.equal(crates.selected, G.file_index['actual/code/entry.rs']); spec.truthy(crates.custom_api)
        spec.nil_value(crates.actual_package); spec.nil_value(crates.remote)
    end)
    spec.it('inherits workspace dependencies from root paths and reloads changed manifests per query', function()
        local root = tmp_root .. '/cargo_workspace'
        write(root .. '/Cargo.toml', '[workspace]\nmembers=[\n"crates/*",\n]\nexclude=["crates/excluded"]\n'
            .. '[workspace.dependencies]\napi={path="lib",package="lib-package"}\n')
        write(root .. '/crates/app/Cargo.toml', '[package]\nname="app"\n[dependencies]\napi.workspace=true\n')
        write(root .. '/crates/excluded/Cargo.toml', '[package]\nname="excluded"\n[dependencies.api]\nworkspace=true\n')
        write(root .. '/lib/Cargo.toml', '[package]\nname="lib-package"\n')
        write(root .. '/other/Cargo.toml', '[package]\nname="lib-package"\n')
        local G = build({ ['crates/app/src/main.rs'] = 'fn WorkspaceRun() { api::save(); }',
            ['crates/excluded/src/main.rs'] = 'fn ExcludedRun() { api::save(); }',
            ['lib/src/lib.rs'] = 'pub fn save() {}', ['other/src/lib.rs'] = 'pub fn save() {}' }, root)
        spec.equal(edges_from(G, 'WorkspaceRun'), 'save@lib/src/lib.rs')
        spec.equal(edges_from(G, 'ExcludedRun'), '')
        write(root .. '/Cargo.toml', '[workspace]\nmembers=["crates/*"]\n[workspace.dependencies.api]\npath="other"\npackage="lib-package"\n')
        spec.equal(edges_from(G, 'WorkspaceRun'), 'save@other/src/lib.rs')
    end)
    spec.it('resolves grouped use aliases, declared file modules, inline modules and public re-exports', function()
        local root = tmp_root .. '/cargo_modules'
        write(root .. '/app/Cargo.toml', '[package]\nname="app"\n[dependencies]\napi={path="../lib", package="library"}\n')
        write(root .. '/lib/Cargo.toml', '[package]\nname="library"\n')
        local G = build({ ['app/src/main.rs'] = 'use api::{save as persist, public::flush};\nfn ModulesRun() { persist(); flush(); api::nested::work(); api::hidden(); api::secret::hidden(); }',
            ['lib/src/lib.rs'] = 'pub mod public; pub mod nested { pub fn work() {} } mod secret { pub fn hidden() {} }\n'
                .. 'pub use crate::public::save; fn hidden() {}',
            ['lib/src/public.rs'] = 'pub fn save() {} pub fn flush() {}',
            ['unrelated/public.rs'] = 'pub fn save() {} pub fn flush() {}' }, root)
        spec.equal(edges_from(G, 'ModulesRun'), 'flush@lib/src/public.rs save@lib/src/public.rs work@lib/src/lib.rs')
        local Q = graph.query(G); local save = G.by_name.save[1]
        for _, id in ipairs(G.by_name.save) do if G.files[G.node_file[id]].path == 'lib/src/public.rs' then save = id end end
        spec.equal(#Q.inn[save], graph.EDGE)
        spec.equal(Q.incomplete, false)
    end)
    spec.it('tracks renamed re-exports across packages and resolves declared associated functions', function()
        local root = tmp_root .. '/cargo_reexport'
        write(root .. '/app/Cargo.toml', '[package]\nname="app"\n[dependencies]\napi={path="../wrapper"}\n')
        write(root .. '/wrapper/Cargo.toml', '[package]\nname="api"\n[dependencies]\nbase={path="../base"}\n')
        write(root .. '/base/Cargo.toml', '[package]\nname="base"\n')
        local G = build({ ['app/src/main.rs'] = 'use api::persist as dispatch; fn ReexportRun() { dispatch(); api::Store::new(); }',
            ['wrapper/src/lib.rs'] = 'pub use base::{save as persist, Store};',
            ['base/src/lib.rs'] = 'pub fn save() {} pub struct Store {} impl Store { pub fn new() {} }' }, root)
        spec.equal(edges_from(G, 'ReexportRun'), 'new@base/src/lib.rs save@base/src/lib.rs')
        local Q = graph.query(G)
        spec.equal(#Q.inn[G.by_name.save[1]], graph.EDGE)
        spec.equal(Q.incomplete, false)
    end)
    spec.it('keeps missing library targets, nested packages and mismatched names unresolved', function()
        local root = tmp_root .. '/cargo_barriers'
        write(root .. '/Cargo.toml', '[package]\nname="root"\n[dependencies]\nmissing={path="missing"}\nwrong={path="library"}\n')
        write(root .. '/missing/Cargo.toml', '[package]\nname="missing"\n[lib]\npath="dist/lib.rs"\n')
        write(root .. '/library/Cargo.toml', '[package]\nname="different"\n')
        write(root .. '/nested/Cargo.toml', '[package]\nname="nested"\n')
        local G = build({ ['src/main.rs'] = 'fn BarriersRun() { missing::save(); wrong::save(); crate::nested::save(); }\nmod nested;',
            ['missing/src/lib.rs'] = 'pub fn save() {}', ['library/src/lib.rs'] = 'pub fn save() {}',
            ['src/nested.rs'] = 'pub fn save() {}', ['nested/src/lib.rs'] = 'pub fn save() {}' }, root)
        spec.equal(edges_from(G, 'BarriersRun'), 'save@src/nested.rs')
        local ctx = {}; spec.nil_value(cargo.crates(G, G.file_index['src/main.rs'], ctx).missing)
    end)
    spec.it('resolves physical and inline parent modules while respecting nested package boundaries', function()
        local root = tmp_root .. '/cargo_parents'
        write(root .. '/Cargo.toml', '[package]\nname="parents"\n')
        write(root .. '/src/private/Cargo.toml', '[package]\nname="private"\n')
        local G = build({ ['src/lib.rs'] = 'pub mod outer; mod private; pub fn base() {} fn RootRun() { private::secret(); }',
            ['src/outer.rs'] = 'pub mod inner; pub fn helper() { super::base(); }\n'
                .. 'pub mod inline { pub fn InlineRun() { super::helper(); } }',
            ['src/outer/inner.rs'] = 'pub fn InnerRun() { super::helper(); super::super::base(); }',
            ['src/private/mod.rs'] = 'pub fn secret() {}' }, root)
        spec.equal(edges_from(G, 'helper'), 'base@src/lib.rs')
        spec.equal(edges_from(G, 'InlineRun'), 'helper@src/outer.rs')
        spec.equal(edges_from(G, 'InnerRun'), 'base@src/lib.rs helper@src/outer.rs')
        spec.equal(edges_from(G, 'RootRun'), '')
    end)
    spec.it('rejects duplicate TOML assignments, malformed data and paths outside the indexed project', function()
        local root = tmp_root .. '/cargo_invalid'
        local G = build({ ['src/main.rs'] = 'fn InvalidRun() { api::save(); }' }, root)
        for _, raw in ipairs({ '[package]\nname="root"\nname="duplicate"\n',
            '[package]\nversion="0.1.0"\n',
            '[package]\nname="root"\n[dependencies]\napi={path="../../outside"}\n',
            '[package]\nname="root"\n[dependencies]\napi={path="missing"\n' }) do
            write(root .. '/Cargo.toml', raw)
            local Q = graph.query(G, { explain = true })
            spec.equal(#Q.out[G.by_name.InvalidRun[1]], 0); spec.truthy(Q.incomplete)
        end
    end)
    spec.it('reports configuration limits and propagates cancellation without persistent Rust evidence', function()
        local root = tmp_root .. '/cargo_limits'
        write(root .. '/Cargo.toml', '[package]\nname="root"\n[dependencies]\napi={path="library"}\n')
        write(root .. '/library/Cargo.toml', '[package]\nname="api"\n')
        local G = build({ ['src/main.rs'] = 'fn LimitedCargoRun() { api::save(); }', ['library/src/lib.rs'] = 'pub fn save() {}' }, root)
        local limit = cargo.MAX_CONFIGS; cargo.MAX_CONFIGS = 1
        local ok, err = pcall(function()
            local Q = graph.query(G, { explain = true })
            spec.equal(#Q.out[G.by_name.LimitedCargoRun[1]], 0); spec.truthy(Q.incomplete)
        end)
        cargo.MAX_CONFIGS = limit; assert(ok, err)
        local control = require('codeoutline.control'); local cancelled = control.cancelled()
        control.callback = function() error(cancelled, 0) end
        ok, err = pcall(edges_from, G, 'LimitedCargoRun')
        control.callback = nil; spec.equal(ok, false); spec.equal(err, cancelled)
        local compact = ci.parse('plain.rs', 'use api::save as persist; fn run() { persist(); }', { ranges = false })
        spec.nil_value(compact.rust_imports); spec.nil_value(compact.rust_public); spec.nil_value(compact.refs.binding)
    end)
    spec.it('reports module and alias-source limits without presenting partial results as complete', function()
        local root = tmp_root .. '/cargo_source_limits'
        write(root .. '/Cargo.toml', '[package]\nname="app"\n[dependencies]\napi={path="library"}\n')
        write(root .. '/library/Cargo.toml', '[package]\nname="api"\n')
        local G = build({ ['src/main.rs'] = 'use api::save as persist; fn AliasLimitRun() { persist(); }',
            ['library/src/lib.rs'] = 'pub fn save() {}' }, root)
        local resolver = require('codeoutline.rust_resolution')
        local node_limit, alias_limit = resolver.MAX_NODES, resolver.MAX_ALIAS_FILES
        local ok, err = pcall(function()
            resolver.MAX_NODES = 0
            local Q = graph.query(G)
            spec.equal(#Q.out[G.by_name.AliasLimitRun[1]], 0); spec.truthy(Q.incomplete)
            resolver.MAX_NODES, resolver.MAX_ALIAS_FILES = node_limit, 0
            Q = graph.query(G)
            spec.equal(#Q.inn[G.by_name.save[1]], 0); spec.truthy(Q.incomplete)
        end)
        resolver.MAX_NODES, resolver.MAX_ALIAS_FILES = node_limit, alias_limit; assert(ok, err)
    end)
end)

spec.describe('query-owned Go modules', function()
    local go = require('codeoutline.go_modules')
    local function build(files, root)
        local records = {}
        for path, source in pairs(files) do records[path] = ci.parse(path, source) end
        return graph.build({ files = records, root = root })
    end
    local function files(G, path, name, ctx)
        local found, reason = go.files(G, G.file_index[path], name, ctx)
        local result = {}; for _, f in ipairs(found) do result[#result + 1] = G.files[f].path end
        table.sort(result); return table.concat(result, ','), reason
    end
    spec.it('uses declared module paths and package names for imports, aliases and same-package calls', function()
        local root = tmp_root .. '/go_module'
        write(root .. '/go.mod', 'module example.test/product/v2\n\ngo 1.23\n')
        local G = build({
            ['cmd/main.go'] = 'package main\nimport (\n selected "example.test/product/v2/util"\n "example.test/product/v2/other"\n)\n'
                .. 'func RunGo() { selected.Save(); actual.Save(); Peer() }',
            ['cmd/peer.go'] = 'package main\nfunc Peer() {}',
            ['cmd/external_test.go'] = 'package main_test\nfunc Peer() {}',
            ['cmd/internal_test.go'] = 'package main\nfunc TestOnly() {}',
            ['util/api.go'] = 'package utility\nfunc Save() {}\nfunc hidden() {}',
            ['util/second.go'] = 'package utility\nfunc Second() {}',
            ['util/api_test.go'] = 'package utility_test\nfunc Save() {}',
            ['util/notgo.ts'] = 'export function Save() {}',
            ['other/api.go'] = 'package actual\nfunc Save() {}',
            ['unrelated/util/api.go'] = 'package utility\nfunc Save() {}',
        }, root)
        spec.equal(files(G, 'cmd/main.go', 'example.test/product/v2/util'), 'util/api.go,util/second.go')
        local Q = graph.query(G)
        spec.equal(#Q.out[G.by_name.RunGo[1]], 3 * graph.EDGE)
        spec.equal(edges_from(G, 'RunGo'), 'Peer@cmd/peer.go Save@other/api.go Save@util/api.go')
        local aliases = go.aliases(G, G.file_index['cmd/main.go'], {})
        spec.truthy(aliases.actual and aliases.selected); spec.nil_value(aliases.other)
        spec.equal(files(G, 'cmd/main.go', 'unrelated.test/util'), '')
        spec.equal(Q.stats.go.reads, 1); spec.equal(Q.incomplete, false)
        spec.equal(#go.resolve(G, G.file_index['cmd/main.go'], 'TestOnly', nil), 0)
        spec.equal(#go.resolve(G, G.file_index['cmd/main.go'], 'hidden', 'selected'), 0)
    end)
    spec.it('honours go.work use lists, module root packages and nested workspace ownership', function()
        local root = tmp_root .. '/go_work'
        write(root .. '/go.work', 'go 1.23\nuse (\n ./app // client\n "./unusual directory"\n)\n')
        write(root .. '/app/go.mod', 'module example.test/app\n')
        write(root .. '/unusual directory/go.mod', 'module example.test/library/v2\n')
        write(root .. '/ignored/go.mod', 'module example.test/ignored\n')
        write(root .. '/nested/go.work', 'use ./client\n')
        write(root .. '/nested/client/go.mod', 'module example.test/nested\n')
        local G = build({ ['app/main.go'] = 'package main', ['unusual directory/api.go'] = 'package lib\nfunc Save() {}',
            ['ignored/api.go'] = 'package ignored', ['nested/client/api.go'] = 'package main' }, root)
        spec.equal(files(G, 'app/main.go', 'example.test/library/v2'), 'unusual directory/api.go')
        spec.equal(files(G, 'ignored/api.go', 'example.test/library/v2'), '')
        spec.equal(files(G, 'nested/client/api.go', 'example.test/library/v2'), '')
        spec.equal(files(G, 'app/main.go', 'example.test/ignored'), '')
    end)
    spec.it('resolves local replacements, preserves version constraints and reloads work overrides per query', function()
        local root = tmp_root .. '/go_replace'
        write(root .. '/app/go.mod', 'module example.test/app\nrequire (\n example.test/lib v1.2.0\n)\n'
            .. 'replace (\n example.test/lib v1.2.0 => ../first\n example.test/unused => ../first\n)\n')
        write(root .. '/first/go.mod', 'module example.test/lib\n')
        write(root .. '/second/go.mod', 'module example.test/lib\n')
        local G = build({ ['app/main.go'] = 'package main', ['first/pkg/api.go'] = 'package lib',
            ['second/pkg/api.go'] = 'package lib' }, root)
        spec.equal(files(G, 'app/main.go', 'example.test/lib/pkg'), 'first/pkg/api.go')
        spec.equal(files(G, 'app/main.go', 'example.test/unused/pkg'), '')
        write(root .. '/go.work', 'use ./app\nreplace example.test/lib => ./second\n')
        spec.equal(files(G, 'app/main.go', 'example.test/lib/pkg'), 'second/pkg/api.go')
        write(root .. '/go.work', 'use ./app\nreplace example.test/lib => example.test/fork v1.0.0\n')
        spec.equal(files(G, 'app/main.go', 'example.test/lib/pkg'), '')
        os.remove(root .. '/go.work')
        write(root .. '/app/go.mod', 'module example.test/app\nrequire example.test/lib v1.3.0\n'
            .. 'replace example.test/lib v1.2.0 => ../first\n')
        spec.equal(files(G, 'app/main.go', 'example.test/lib/pkg'), '')
    end)
    spec.it('blocks nested module leakage, ambiguous replacements and undeclared packages', function()
        local root = tmp_root .. '/go_boundaries'
        write(root .. '/go.work', 'use (\n app\n other\n)\n')
        write(root .. '/app/go.mod', 'module example.test/app\nrequire example.test/lib v1.0.0\nreplace example.test/lib => ../first\n')
        write(root .. '/other/go.mod', 'module example.test/other\nreplace example.test/lib => ../second\n')
        write(root .. '/app/nested/go.mod', 'module example.test/private\n')
        write(root .. '/first/go.mod', 'module example.test/lib\n')
        write(root .. '/second/go.mod', 'module example.test/lib\n')
        local G = build({ ['app/main.go'] = 'package main', ['other/api.go'] = 'package main',
            ['app/nested/api.go'] = 'package nested', ['first/api.go'] = 'package lib', ['second/api.go'] = 'package lib' }, root)
        spec.equal(files(G, 'app/main.go', 'example.test/app/nested'), '')
        local found, reason = files(G, 'app/main.go', 'example.test/lib')
        spec.equal(found, ''); spec.contains(reason, 'conflicting')
        write(root .. '/go.work', 'use (\n app\n other\n)\nreplace example.test/lib => ./second\n')
        spec.equal(files(G, 'app/main.go', 'example.test/lib'), 'second/api.go')
        write(root .. '/other/go.mod', 'module example.test/app\n')
        local ctx = {}
        found, reason = files(G, 'app/main.go', 'example.test/app', ctx)
        spec.equal(found, ''); spec.contains(reason, 'ambiguous'); spec.truthy(ctx.go_incomplete)
    end)
    spec.it('keeps legacy suffix matching unique and restricted to Go package files', function()
        local G = build({ ['app.go'] = 'package main', ['a/util/api.go'] = 'package util',
            ['b/util/api.go'] = 'package util', ['a/util/other.ts'] = 'export function Save() {}' })
        spec.equal(files(G, 'app.go', 'example.test/a/util'), 'a/util/api.go')
        local found, reason = files(G, 'app.go', 'unmatched.test/util')
        spec.equal(found, ''); spec.contains(reason, 'ambiguous')
    end)
    spec.it('bounds configuration work, rejects escapes and preserves cancellation identity', function()
        local root = tmp_root .. '/go_limits'
        write(root .. '/go.mod', 'module example.test/app\n')
        local G = build({ ['main.go'] = 'package main\nimport selected "example.test/app/pkg"\nfunc GoRun() { selected.Save() }',
            ['pkg/api.go'] = 'package pkg\nfunc Save() {}' }, root)
        local limit = go.MAX_CONFIGS; go.MAX_CONFIGS = 1
        local ok, err = pcall(function()
            local Q = graph.query(G, { explain = true })
            spec.equal(#Q.out[G.by_name.GoRun[1]], 0); spec.truthy(Q.incomplete)
            spec.contains(require('codeoutline.query_report').render(Q.report, G), 'Go configuration probe limit')
        end)
        go.MAX_CONFIGS = limit; assert(ok, err)
        write(root .. '/go.work', 'use ../outside\n')
        local ctx = {}; local found, reason = files(G, 'main.go', 'example.test/app/pkg', ctx)
        spec.equal(found, ''); spec.contains(reason, 'escapes'); spec.truthy(ctx.go_incomplete)
        os.remove(root .. '/go.work')
        local control = require('codeoutline.control'); local cancelled = control.cancelled()
        control.callback = function() error(cancelled, 0) end
        ok, err = pcall(files, G, 'main.go', 'example.test/app/pkg')
        control.callback = nil; spec.equal(ok, false); spec.equal(err, cancelled)
    end)
    spec.it('reports file and node limits without returning partial package targets', function()
        local root = tmp_root .. '/go_package_limits'
        write(root .. '/go.mod', 'module example.test/app\n')
        local G = build({ ['main.go'] = 'package main\nimport api "example.test/app/pkg"\nfunc LimitedRun() { api.Save() }',
            ['pkg/a.go'] = 'package api\nfunc First() {}\nfunc Save() {}',
            ['pkg/b.go'] = 'package api\nfunc Another() {}' }, root)
        local file_limit, node_limit = go.MAX_FILES, go.MAX_NODES
        local ok, err = pcall(function()
            go.MAX_FILES = 1
            local ctx = {}; local found, reason = files(G, 'main.go', 'example.test/app/pkg', ctx)
            spec.equal(found, ''); spec.truthy(ctx.go_incomplete); spec.contains(reason, 'file limit')
            go.MAX_FILES, go.MAX_NODES = file_limit, 1
            local Q = graph.query(G, { explain = true })
            spec.equal(#Q.out[G.by_name.LimitedRun[1]], 0); spec.truthy(Q.incomplete)
            spec.contains(require('codeoutline.query_report').render(Q.report, G), 'node limit')
        end)
        go.MAX_FILES, go.MAX_NODES = file_limit, node_limit; assert(ok, err)
    end)
end)

spec.describe('query-owned JS workspace packages', function()
    local function build(files, root)
        local records = {}
        for path, source in pairs(files) do records[path] = ci.parse(path, source, { ordinary_bindings = true }) end
        return graph.build({ files = records, root = root })
    end
    local function target(G, path, specifier, mode)
        local id, reason = require('codeoutline.js_resolution').module(G, G.file_index[path], specifier, nil, mode)
        return id and G.files[id].path or nil, reason
    end
    spec.it('resolves scoped workspace packages, cross-package re-exports and imported receiver methods', function()
        local root = tmp_root .. '/workspace_packages'
        write(root .. '/package.json', '{"private":true,"workspaces":["packages/*"]}')
        write(root .. '/packages/core/package.json', '{"name":"@repo/core","exports":"./src/index.js"}')
        write(root .. '/packages/api/package.json', '{"name":"@repo/api","main":"src/index.ts"}')
        local G = build({
            ['packages/core/src/index.ts'] = 'export function save() {} export class Store { flush() {} }',
            ['packages/api/src/index.ts'] = "export { save as persist, Store } from '@repo/core';",
            ['app.ts'] = "import { persist, Store } from '@repo/api'; function run() { persist(); const s = new Store(); s.flush(); }",
        }, root)
        spec.equal(target(G, 'app.ts', '@repo/core'), 'packages/core/src/index.ts')
        local Q, hit = graph.query(G), {}
        for i = 1, #Q.out[G.by_name.run[1]], graph.EDGE do hit[G.nodes[Q.out[G.by_name.run[1]][i]].name] = true end
        spec.truthy(hit.save and hit.flush)
        spec.equal(#Q.inn[G.by_name.save[1]], graph.EDGE)
        spec.equal(Q.stats.workspace.packages, 2)
    end)
    spec.it('honours export condition order, import modes and explicit unindexed targets', function()
        local root = tmp_root .. '/workspace_conditions'
        write(root .. '/package.json', '{"workspaces":{"packages":["packages/*"]}}')
        write(root .. '/packages/ordered/package.json', '{"name":"ordered","exports":{"default":"./default.ts","types":"./types.ts"}}')
        write(root .. '/packages/dual/package.json', '{"name":"dual","exports":{"types":"./types.ts","import":"./import.ts","require":"./require.ts"}}')
        write(root .. '/packages/missing/package.json', '{"name":"missing","exports":"./dist/index.js","main":"./index.ts"}')
        local G = build({ ['app.ts'] = '', ['app.js'] = '',
            ['packages/ordered/default.ts'] = '', ['packages/ordered/types.ts'] = '',
            ['packages/dual/import.ts'] = '', ['packages/dual/require.ts'] = '', ['packages/dual/types.ts'] = '',
            ['packages/missing/index.ts'] = '',
        }, root)
        spec.equal(target(G, 'app.ts', 'ordered'), 'packages/ordered/default.ts')
        spec.equal(target(G, 'app.ts', 'dual'), 'packages/dual/types.ts')
        spec.equal(target(G, 'app.js', 'dual'), 'packages/dual/import.ts')
        spec.equal(target(G, 'app.js', 'dual', 'require'), 'packages/dual/require.ts')
        local id, reason = target(G, 'app.ts', 'missing')
        spec.nil_value(id); spec.contains(reason, 'not indexed')
    end)
    spec.it('enforces exports, wildcard specificity, exclusions and duplicate package barriers', function()
        local root = tmp_root .. '/workspace_exports'
        write(root .. '/package.json', '{"workspaces":["packages/*","!packages/legacy"]}')
        write(root .. '/packages/core/package.json', [[{"name":"@repo/core","exports":{
            "./feature/*":"./src/*.ts", "./feature/special/*":"./special/*.ts", "./feature/private":null}}]])
        write(root .. '/packages/legacy/package.json', '{"name":"@repo/core","main":"index.ts"}')
        write(root .. '/packages/dup1/package.json', '{"name":"duplicate","main":"index.ts"}')
        write(root .. '/packages/dup2/package.json', '{"name":"duplicate","main":"index.ts"}')
        local G = build({ ['app.ts'] = '', ['packages/core/src/save.ts'] = '', ['packages/core/special/save.ts'] = '',
            ['packages/core/src/private.ts'] = '', ['packages/legacy/index.ts'] = '',
            ['packages/dup1/index.ts'] = '', ['packages/dup2/index.ts'] = '',
        }, root)
        spec.equal(target(G, 'app.ts', '@repo/core/feature/save'), 'packages/core/src/save.ts')
        spec.equal(target(G, 'app.ts', '@repo/core/feature/special/save'), 'packages/core/special/save.ts')
        for _, name in ipairs({ '@repo/core', '@repo/core/src/save', '@repo/core/feature/private',
            '@repo/core/feature/../src/save', '@repo/core/feature/%2e%2e/save', 'duplicate' }) do
            spec.nil_value(target(G, 'app.ts', name), name)
        end
    end)
    spec.it('reads pnpm package globs and keeps nested workspace boundaries separate', function()
        local root = tmp_root .. '/workspace_pnpm'
        write(root .. '/package.json', '{"workspaces":["ignored/*"]}')
        write(root .. '/pnpm-workspace.yaml', "packages:\n  - 'packages/**'\n  - '!**/test/**'\ncatalog:\n  other: 1\n")
        write(root .. '/packages/core/package.json', '{"name":"core","main":"index.ts"}')
        write(root .. '/packages/test/hidden/package.json', '{"name":"hidden","main":"index.ts"}')
        write(root .. '/nested/package.json', '{"workspaces":["libs/*"]}')
        write(root .. '/nested/libs/core/package.json', '{"name":"core","main":"index.ts"}')
        local G = build({ ['app.ts'] = '', ['packages/core/index.ts'] = '', ['packages/test/hidden/index.ts'] = '',
            ['nested/app.ts'] = '', ['nested/libs/core/index.ts'] = '' }, root)
        spec.equal(target(G, 'app.ts', 'core'), 'packages/core/index.ts')
        spec.equal(target(G, 'nested/app.ts', 'core'), 'nested/libs/core/index.ts')
        spec.nil_value(target(G, 'app.ts', 'hidden'))
        write(root .. '/pnpm-workspace.yaml', 'packages: ["packages/core"]\n')
        spec.equal(target(G, 'app.ts', 'core'), 'packages/core/index.ts')
    end)
    spec.it('reloads changed manifests and preserves tsconfig paths precedence', function()
        local root = tmp_root .. '/workspace_reload'
        write(root .. '/package.json', '{"workspaces":["packages/*"]}')
        write(root .. '/packages/core/package.json', '{"name":"core","main":"a.ts"}')
        local G = build({ ['app.ts'] = '', ['packages/core/a.ts'] = '', ['packages/core/b.ts'] = '', ['override.ts'] = '' }, root)
        spec.equal(target(G, 'app.ts', 'core'), 'packages/core/a.ts')
        write(root .. '/packages/core/package.json', '{"name":"core","main":"b.ts"}')
        spec.equal(target(G, 'app.ts', 'core'), 'packages/core/b.ts')
        write(root .. '/tsconfig.json', '{"compilerOptions":{"paths":{"core":["override.ts"]}}}')
        spec.equal(target(G, 'app.ts', 'core'), 'override.ts')
        write(root .. '/packages/core/package.json', 'invalid json')
        spec.equal(target(G, 'app.ts', 'core'), 'override.ts')
    end)
    spec.it('bounds manifest discovery, reports incomplete queries and preserves cancellation', function()
        local root = tmp_root .. '/workspace_limits'
        write(root .. '/package.json', '{"workspaces":["packages/*"]}')
        write(root .. '/packages/core/package.json', '{"name":"core","main":"index.ts"}')
        local G = build({ ['app.ts'] = "import { save } from 'core'; function run() { save(); }",
            ['packages/core/index.ts'] = 'export function save() {}' }, root)
        local workspace = require('codeoutline.js_workspace')
        local limit = workspace.MAX_CONFIGS; workspace.MAX_CONFIGS = 1
        local ok, err = pcall(function()
            local Q = graph.query(G, { explain = true })
            spec.equal(#Q.out[G.by_name.run[1]], 0); spec.truthy(Q.incomplete)
            spec.contains(require('codeoutline.query_report').render(Q.report, G), 'configuration limit')
            Q = graph.query(G)
            spec.equal(#Q.inn[G.by_name.save[1]], 0); spec.truthy(Q.incomplete)
            local js = require('codeoutline.js_resolution')
            local ctx = js.context(G)
            js.module(G, G.file_index['app.ts'], 'core', ctx)
            local probes = ctx.workspace.probes
            js.module(G, G.file_index['app.ts'], 'another-package', ctx)
            spec.equal(ctx.workspace.probes, probes)
        end)
        workspace.MAX_CONFIGS = limit; assert(ok, err)
        local control = require('codeoutline.control')
        local interrupted = control.cancelled()
        control.callback = function() error(interrupted, 0) end
        ok, err = pcall(target, G, 'app.ts', 'core')
        control.callback = nil
        spec.equal(ok, false); spec.equal(err, interrupted)
    end)
    spec.it('rejects malformed configuration without inventing workspace targets', function()
        local root = tmp_root .. '/workspace_invalid'
        write(root .. '/packages/core/package.json', '{"name":"core","main":"index.ts"}')
        local G = build({ ['app.ts'] = '', ['packages/core/index.ts'] = '' }, root)
        for _, yaml in ipairs({ 'packages: {}\n', 'packages:\n  - "packages/*" trailing\n',
            "packages:\n  - 'packages/*' trailing\n", 'packages:\n  - &alias packages/*\n' }) do
            write(root .. '/pnpm-workspace.yaml', yaml)
            local id, reason = target(G, 'app.ts', 'core')
            spec.nil_value(id); spec.contains(reason, 'unsupported')
        end
        os.remove(root .. '/pnpm-workspace.yaml')
        write(root .. '/package.json', '{"workspaces":["packages/*"]}')
        write(root .. '/packages/core/package.json', '{"name":"core","exports":{"node":{"browser":"./missing.ts"},"default":"./index.ts"}}')
        spec.equal(target(G, 'app.ts', 'core'), 'packages/core/index.ts')
        write(root .. '/packages/core/package.json', '{"name":"core","main":"index.ts","main":"missing.ts"}')
        local id, reason = target(G, 'app.ts', 'core')
        spec.nil_value(id); spec.contains(reason, 'duplicate')
    end)
end)

spec.describe('query-owned ordinary bindings', function()
    spec.it('uses existing hints for lazy JS aliases and excludes unrelated imported bindings', function()
        local root = tmp_root .. '/lazy_js_aliases'
        write(root .. '/lib.ts', 'export function save() {}\nexport function unused() {}\nexport const alias = save;')
        write(root .. '/barrel.ts', "import { alias } from './lib'; export const renamed = alias;")
        write(root .. '/app.ts', "import { renamed as imported } from './barrel'; const cb = imported;\n"
            .. 'function local_save() {} const local_cb = local_save; function run() { cb(); local_cb(); }')
        write(root .. '/unrelated.ts', "import { unused } from './lib'; function other() { unused(); }")
        local idx, G = svc.get(root, { cache_path = root .. '/cache.idx', lister = 'walk' })
        write(root .. '/unrelated.ts', 'function changed() {}')
        local Q = graph.query(G)
        -- Alias initializers now retain reference dependencies as well as calls.
        spec.equal(#Q.inn[G.by_name.save[1]], 4 * graph.EDGE)
        spec.equal(#Q.inn[G.by_name.local_save[1]], 2 * graph.EDGE)
        spec.equal(#Q.out[G.by_name.run[1]], 2 * graph.EDGE)
        for _, rec in pairs(idx.files) do
            spec.nil_value(rec.ordinary_bindings)
            for _, export in ipairs(rec.js_exports or {}) do spec.nil_value(export.binding) end
        end
        svc.forget(root)
    end)
    spec.it('filters unrelated files, reuses evidence and rejects stale candidate sources', function()
        local root = tmp_root .. '/lazy_bindings'
        write(root .. '/store.py', 'def save():\n    pass\n')
        write(root .. '/barrel.py', 'from store import save as alias\n')
        write(root .. '/app.py', 'from barrel import alias as cb\ndef run():\n    cb()\n    cb()\n')
        write(root .. '/unrelated.py', 'def unrelated():\n    elsewhere()\n')
        local idx, G = svc.get(root, { cache_path = root .. '/cache.idx', lister = 'walk' })
        local Q = graph.query(G)
        spec.equal(Q.stats.ordinary.parses, 0)
        write(root .. '/unrelated.py', 'def changed():\n    elsewhere()\n')
        local target, caller = G.by_name.save[1], G.by_name.run[1]
        spec.equal(#Q.inn[target], 2 * graph.EDGE)
        local parsed = Q.stats.ordinary.parses
        spec.truthy(parsed > 0 and parsed < 4, 'only relevant files need binding analysis')
        spec.equal(#Q.out[caller], 2 * graph.EDGE)
        spec.equal(Q.stats.ordinary.parses, parsed, 'forward and reverse queries share evidence')
        write(root .. '/app.py', 'from barrel import alias as cb\ndef run():\n    pass\n')
        local ok, err = pcall(function() return graph.query(G).out[caller] end)
        spec.equal(ok, false); spec.contains(tostring(err), 'source changed during query')
        svc.forget(root)
    end)
    spec.it('keeps reverse alias edges after query cache eviction', function()
        local root = tmp_root .. '/lazy_eviction'
        write(root .. '/store.py', 'def save():\n    pass\n')
        for i = 1, 20 do
            write(root .. '/app' .. i .. '.py', 'from store import save as cb\ndef run' .. i .. '():\n    cb()\n')
        end
        local idx, G = svc.get(root, { cache_path = root .. '/cache.idx', lister = 'walk' })
        local Q = graph.query(G)
        spec.equal(#Q.inn[G.by_name.save[1]], 20 * graph.EDGE)
        spec.truthy(Q.stats.ordinary.files <= 16 and Q.stats.ordinary.bytes <= 8 * 1024 * 1024)
        spec.equal(#Q.out[G.by_name.run1[1]], graph.EDGE)
        spec.equal(#graph.query(G).inn[G.by_name.save[1]], 20 * graph.EDGE)
        for _, rec in pairs(idx.files) do spec.nil_value(rec.refs.binding) end
        svc.forget(root)
    end)
end)

spec.describe('Python import bindings', function()
    local function build(files)
        local records = {}
        for path, source in pairs(files) do records[path] = ci.parse(path, source, { ordinary_bindings = true }) end
        return graph.build({ files = records })
    end
    spec.it('follows renamed, module and relative package re-exports', function()
        local G = build({
            ['store.py'] = 'def save():\n    pass\n',
            ['pkg/__init__.py'] = 'from .impl import save as persist\n',
            ['pkg/impl.py'] = 'def save():\n    pass\n',
            ['pkg/app.py'] = 'from . import persist as chosen\nimport store as api\n'
                .. 'from store import save as renamed\n'
                .. 'def run():\n    chosen()\n    api.save()\n    renamed()\n',
        })
        spec.equal(edges_from(G, 'run'), 'save@pkg/impl.py save@store.py save@store.py')
        for _, id in ipairs(G.by_name.save) do spec.truthy(#graph.query(G).inn[id] > 0) end
    end)
    spec.it('rejects missing imports, shadowed and reassigned import names', function()
        local G = build({
            ['store.py'] = 'def save():\n    pass\n',
            ['app.py'] = 'from absent import save\nfrom store import save as cb\n'
                .. 'def missing():\n    save()\n'
                .. 'def shadow(cb):\n    cb()\n'
                .. 'def changed():\n    cb()\n'
                .. 'cb = other\n',
        })
        for _, name in ipairs({ 'missing', 'shadow', 'changed' }) do spec.equal(edges_from(G, name), '', name) end
    end)
    spec.it('does not revive deleted re-exports and terminates cyclic package imports', function()
        local G = build({
            ['store.py'] = 'def save():\n    pass\n',
            ['barrel.py'] = 'from store import save\ndel save\n',
            ['cycle.py'] = 'from loop import save\n',
            ['loop.py'] = 'from cycle import save\n',
            ['app.py'] = 'from barrel import save as gone\nfrom cycle import save as cyclic\n'
                .. 'def run():\n    gone()\n    cyclic()\n',
        })
        spec.equal(edges_from(G, 'run'), '')
    end)
end)

spec.describe('JS module and receiver resolution', function()
    local function build(files, root)
        local records = {}
        for path, source in pairs(files) do records[path] = ci.parse(path, source, { ordinary_bindings = true }) end
        return graph.build({ root = root, files = records })
    end
    spec.it('resolves ArkTS component imports, directory barrels and TS helpers', function()
        local G = build({
            ['Widget.ets'] = '@Component\nexport struct Widget { build() {} }',
            ['parts/index.ets'] = "export { Widget as Card } from '../Widget';",
            ['helper.ts'] = 'export function save() {}',
            ['Page.ets'] = "import { Card } from './parts'; import { save as persist } from './helper';\n"
                .. '@Component\nstruct Page {\n  click() { persist(); }\n  build() { Column() { Card() } this.click(); }\n}',
        })
        spec.equal(edges_from(G, 'click'), 'save@helper.ts')
        spec.equal(edges_from(G, 'build'), 'Widget@Widget.ets click@Page.ets')
    end)
    spec.it('follows lexical function aliases and imported alias exports in both directions', function()
        local G = build({
            ['lib.ts'] = 'export function save() {}\nexport const persist = save;',
            ['barrel.ts'] = "import { persist } from './lib'; export const stored = persist;",
            ['use.ts'] = "import { stored } from './barrel'; function local_save() {}\n"
                .. 'const one = local_save; const two = one; const imported = stored;\n'
                .. 'function run() { two(); imported(); }',
        })
        spec.equal(edges_from(G, 'run'), 'local_save@use.ts save@lib.ts')
        spec.equal(#graph.query(G).inn[G.by_name.save[1]], 4 * graph.EDGE)
        spec.equal(#graph.query(G).inn[G.by_name.local_save[1]], 3 * graph.EDGE)
    end)
    spec.it('does not follow reassigned, shadowed, cyclic or computed function aliases', function()
        local G = build({
            ['use.ts'] = [[function save() {}
let cb = save;
function run() { cb(); }
cb = unknown;
const original = save;
function shadow(original) { original(); }
function block() { const original = unknown; original(); }
const cycle = cycle;
function cyclic() { cycle(); }
const computed = save || unknown;
function dynamic() { computed(); }
]],
        })
        for _, name in ipairs({ 'run', 'shadow', 'block', 'cyclic', 'dynamic' }) do
            spec.equal(edges_from(G, name), '', name)
        end
    end)
    spec.it('bounds alias chains and respects destructuring and var function scope', function()
        local G = build({
            ['use.ts'] = [[function save() {}
const cb = save;
function shadow() { { var cb = unknown; } cb(); }
function overwritten() { cb(); }
({ cb } = other);
const a0 = save;
const a1 = a0; const a2 = a1; const a3 = a2; const a4 = a3;
const a5 = a4; const a6 = a5; const a7 = a6; const a8 = a7; const a9 = a8;
function bounded() { a9(); }
]],
        })
        for _, name in ipairs({ 'shadow', 'overwritten', 'bounded' }) do spec.equal(edges_from(G, name), '', name) end
    end)
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
    spec.it('exports unconditional members attached after cached module initialization', function()
        local G = build({
            ['router.lua'] = "local M = rawget(_G, 'router')\nif type(M) ~= 'table' then M = {} end\n"
                .. 'function M.set_log_prefix(prefix) return M end\nreturn M',
            ['other.lua'] = 'local M = {}\nfunction M.set_log_prefix() end\nreturn M',
            ['main.lua'] = "local router = dofile('router.lua')\nfunction run() router.set_log_prefix('MAIN') end",
        })
        spec.equal(edges_from(G, 'run'), 'set_log_prefix@router.lua')
        local shadowed = ci.parse('shadowed.lua', 'local M = factory()\nfunction M.save() end\n'
            .. 'do local M = {} function M.save() end M.save = other end\nreturn M')
        spec.equal(shadowed.nodes[shadowed.lua_exports.save].line, 2, 'an inner local table does not replace the returned object')
        for _, source in ipairs({
            'local M = factory()\nfunction M.save() end\nM = other\nreturn M',
            'local M = factory()\nif flag then function M.save() end end\nreturn M',
            'local M = factory()\nfunction M.save() end\nif flag then M.save = other end\nreturn M',
            'local M = factory()\nfunction M.save() end\nif flag then M = other end\nreturn M',
        }) do
            spec.equal(next(ci.parse('invalid.lua', source).lua_exports), nil)
        end
    end)
    spec.it('binds extracted loader members and renamed calls without guessing call results', function()
        local G = build({
            ['misc.lua'] = 'local M = {}\nfunction M.to_bool() end\nreturn M',
            ['wrong.lua'] = 'function to_bool() end',
            ['main.lua'] = "local to_bool = dofile('misc.lua').to_bool\n"
                .. "local convert = require('misc').to_bool\n"
                .. 'function run() to_bool() end\nfunction renamed() convert() end\n'
                .. 'function shadow(to_bool) to_bool() end\n'
                .. "function replaced() local to_bool = dofile('misc.lua').to_bool; to_bool = other; to_bool() end\n"
                .. "function called() local to_bool = dofile('misc.lua').to_bool(); to_bool() end\n"
                .. "function chain() local to_bool = dofile('misc.lua').to_bool.nested; to_bool() end\n"
                .. "function custom(dofile) local to_bool = dofile('misc.lua').to_bool; to_bool() end\n",
        })
        spec.equal(edges_from(G, 'run'), 'to_bool@misc.lua')
        spec.equal(edges_from(G, 'renamed'), 'to_bool@misc.lua')
        for _, name in ipairs({ 'shadow', 'called', 'chain', 'custom' }) do
            -- called() executes the exported function in its initializer; it
            -- must not treat the function's unknown result as another alias.
            spec.equal(edges_from(G, name), '', name)
        end
        local Q = graph.query(G)
        local replaced = Q.out[G.by_name.replaced[1]]
        spec.equal(#replaced, 3); spec.equal(replaced[3], 'ref', 'the initializer references a function but the reassigned call is blocked')
        local target
        for _, id in ipairs(G.by_name.to_bool) do
            if G.files[G.node_file[id]].path == 'misc.lua' then target = id; break end
        end
        spec.equal(#Q.inn[assert(target)], 9)
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
    spec.it('shares global publication behavior across every configured Lua export table', function()
        local root = tmp_root .. '/export_table_contract'
        local owners = { 'g_exports', '__global_exports', 'custom_exports' }
        write(root .. '/.codeoutline.json', xutils.json_pack({ luaGlobalExportTables = { '__global_exports', 'custom_exports' } }))
        for _, owner in ipairs(owners) do
            for _, form in ipairs({
                { 'local aaa = function() end;', 'aaa' },
                { 'local function aaa() end', 'aaa' },
                { 'local impl = function() end;', 'impl' },
            }) do
                local declaration, implementation = form[1], form[2]
                local G = build({
                    ['exports/api.lua'] = declaration .. '\n' .. owner .. '.aaa = ' .. implementation .. '\n',
                    ['helpers/private.lua'] = 'local aaa = function() end\n',
                    ['client.lua'] = 'function run() aaa() end\n',
                    ['local_client.lua'] = 'local aaa = function() end\nfunction private_run() aaa() end\n',
                }, root)
                spec.equal(#G.by_name.aaa, 3, 'same-name exports do not duplicate name-index entries')
                spec.equal(edges_from(G, 'run'), implementation .. '@exports/api.lua', owner)
                spec.equal(edges_from(G, 'private_run'), 'aaa@local_client.lua')
                local exported = G.files[G.file_index['exports/api.lua']].nodes[1]
                spec.equal(exported.lua_aliases[owner][1], 'aaa')
                graph.remove_file(G, 'exports/api.lua'); spec.equal(#G.by_name.aaa, 2)
                graph.add_file(G, 'exports/api.lua', ci.parse('exports/api.lua', declaration .. '\n' .. owner .. "['aaa'] = " .. implementation .. '\n'))
                spec.equal(#G.by_name.aaa, 3)
                spec.equal(edges_from(G, 'run'), implementation .. '@exports/api.lua', owner)
            end
            local direct = build({
                ['exports/direct.lua'] = owner .. '.aaa = function() end\n',
                ['private.lua'] = 'local aaa = function() end\n',
                ['client.lua'] = 'function run() aaa() end\n',
            }, root)
            spec.equal(edges_from(direct, 'run'), 'aaa@exports/direct.lua', owner)
            local private = ci.parse('private_table.lua', 'local ' .. owner .. ' = {}\nfunction ' .. owner .. '.aaa() end\n')
            spec.nil_value(private.nodes[2].lua_aliases)
            local scoped = ci.parse('scoped.lua', 'local aaa = function() end\n'
                .. 'do local aaa = function() end end\n' .. owner .. '.aaa = aaa\n')
            spec.equal(scoped.nodes[1].lua_aliases[owner][1], 'aaa')
            spec.nil_value(scoped.nodes[2].lua_aliases)
            local replaced = ci.parse('replaced.lua', 'local aaa = function() end\naaa = unknown\n' .. owner .. '.aaa = aaa\n')
            spec.nil_value(replaced.nodes[1].lua_aliases)
        end
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
        write(root .. '/.codeoutline.json', '{"luaGlobalExportTables":["custom_exports","other_exports","custom_exports","g_exports","g_exports"]}')
        idx, G = svc.get(root, options)
        spec.equal(idx.cache_loaded, true)
        spec.equal(#G.by_name.custom_export, 1)
        spec.equal(#G.by_name.default_export, 1)
        spec.equal(#G.lua_global_export_tables, 3, 'configured names extend and deduplicate the built-in export table')
        spec.equal(edges_from(G, 'run'), 'impl@exports.lua')
        write(root .. '/.codeoutline.json', '{"luaGlobalExportTables":[]}')
        G = idx:symbols()
        spec.equal(G.by_name.custom_export, nil)
        spec.equal(#G.by_name.default_export, 1, 'an empty extension list preserves g_exports')
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

spec.describe('unified project rules', function()
    local config_rules = require('codeoutline.rules')
    local event = { kind = 'event', language = 'lua', call = 'bus.emit', argument = 1,
        register = 'bus.on', keyArgument = 1, handlerArgument = 2 }
    spec.it('normalizes one contract for both consumers without mutating configuration', function()
        local config = { rules = { event } }
        local normalized = config_rules.normalize(config)
        spec.equal(#normalized.dispatch, 1); spec.equal(#normalized.definitions, 1)
        spec.equal(normalized.definitions[1].target, 'bus.on')
        spec.equal(normalized.definitions[1].targetArgument, 1)
        spec.equal(normalized.definitions[1].shared, true)
        spec.equal(event.target, nil); spec.equal(event.shared, nil)
    end)
    spec.it('deduplicates shared and legacy contracts while preserving legacy scope', function()
        local normalized = config_rules.normalize({ rules = { event, event }, dispatchRules = { event },
            definitionRules = { { language = 'lua', call = 'bus.emit', argument = 1, target = 'bus.on', targetArgument = 1 } } })
        spec.equal(#normalized.dispatch, 1); spec.equal(#normalized.definitions, 1)
        spec.equal(normalized.definitions[1].shared, true)
        normalized = config_rules.normalize({ dispatchRules = { event } })
        spec.equal(#normalized.definitions, 0)
        normalized = config_rules.normalize({ definitionRules = {
            { call = 'bus.emit', argument = 1, target = 'bus.on', targetArgument = 1 } } })
        spec.equal(#normalized.dispatch, 0)
    end)
    spec.it('keeps definition-only contracts out of graph inference', function()
        local normalized = config_rules.normalize({ rules = {
            { kind = 'definition', call = 'lookup', argument = 1, targetKind = 'key', qualifiers = { 'Items' } } } })
        spec.equal(#normalized.dispatch, 0)
        spec.equal(normalized.definitions[1].qualifiers.Items, true)
    end)
    spec.it('validates optional RPC service argument positions', function()
        local r = { kind = 'target', call = 'rpc.send', argument = 4, serviceArgument = 1 }
        local n = config_rules.normalize({ rules = { r } })
        spec.equal(n.definitions[1].serviceArgument, 1)
        for _, value in ipairs({ 0, 33, 1.5, '1' }) do
            r.serviceArgument = value
            spec.equal(pcall(config_rules.normalize, { rules = { r } }), false)
        end
        r.kind, r.serviceArgument = 'callback', 1
        spec.equal(pcall(config_rules.normalize, { rules = { r } }), false)
    end)
    spec.it('preserves navigation qualifiers and legacy matching on duplicate shared contracts', function()
        local target = { kind = 'target', language = 'lua', call = 'rpc.send', argument = 2, qualifiers = { 'CMD' } }
        local normalized = config_rules.normalize({ rules = { target }, definitionRules = {
            { language = 'lua', call = 'rpc.send', argument = 2, targetKind = 'declaration', qualifiers = { 'CMD' } } } })
        spec.equal(#normalized.definitions, 1)
        spec.equal(normalized.definitions[1].legacy, true)
        spec.equal(normalized.definitions[1].qualifiers.CMD, true)
        spec.equal(target.qualifiers[1], 'CMD', 'configuration stays unchanged')
        for _, q in ipairs({ { CMD = true }, { 'CMD', false }, { 'other.CMD' } }) do
            target.qualifiers = q
            spec.equal(pcall(config_rules.normalize, { rules = { target } }), false)
        end
    end)
    spec.it('rejects invalid arrays, positions and excessive combined contracts', function()
        for _, config in ipairs({ { rules = { bad = event } }, { rules = { { kind = 'event', call = 'bus.emit', argument = 1 } } },
            { rules = { { kind = 'callback', call = 'schedule', argument = 0 } } } }) do
            spec.equal(pcall(config_rules.normalize, config), false)
        end
        local unified, legacy = {}, {}
        for i = 1, 32 do unified[i] = { kind = 'callback', call = 'call' .. i, argument = 1 } end
        legacy[1] = { kind = 'callback', call = 'extra', argument = 1 }
        spec.equal(pcall(config_rules.normalize, { rules = unified, dispatchRules = legacy }), false)
    end)
end)

spec.describe('automatic Node EventEmitter delivery', function()
    local function build(files)
        local records = {}; for path, source in pairs(files) do records[path] = ci.parse(path, source, { ordinary_bindings = true }) end
        return graph.build({ files = records })
    end
    local function events(G, name)
        local Q, result = graph.query(G, { explain = true }), {}
        local edges = Q.out[G.by_qualified[name][1]]
        for i = 1, #edges, graph.EDGE do if edges[i + 2] == 'automatic:event' then result[#result + 1] = G.nodes[edges[i]].qualified end end
        table.sort(result); return table.concat(result, ','), Q
    end
    spec.it('pairs literal events by local object identity and preserves registration evidence', function()
        local G = build({ ['events.ts'] = [[import { EventEmitter as E } from 'node:events';
const first = new E(); const second = new E();
const ready = () => {}; function other() {} function wrong() {} const alias = other;
first.on('ready', ready); second.on('ready', wrong); first.once('other', alias);
function publish() { first.emit('ready'); first.emit('other'); }
function separate() { second.emit('ready'); }
]] })
        local found, Q = events(G, 'publish'); spec.equal(found, 'other,ready')
        spec.equal(events(G, 'separate'), 'wrong')
        spec.contains(require('codeoutline.query_report').render(Q.report, G), 'same local Node EventEmitter')
        local incoming = Q.inn[G.by_qualified.ready[1]]; local seen = false
        for i = 1, #incoming, graph.EDGE do if incoming[i + 2] == 'automatic:event' then spec.equal(G.nodes[incoming[i]].qualified, 'publish'); seen = true end end
        spec.truthy(seen)
    end)
    spec.it('resolves imported handlers and default or namespace EventEmitter constructors', function()
        local G = build({ ['handler.js'] = 'export function delivered() {}',
            ['barrel.js'] = "export { delivered as handler } from './handler';",
            ['default.js'] = [[import E from 'events'; import { handler as listener } from './barrel';
const bus = new E(); bus.addListener('go', listener); function runDefault() { bus.emit('go', 1); }
]], ['namespace.js'] = [[import * as events from 'node:events'; import { delivered } from './handler';
const bus = new events.EventEmitter(); bus.on('go', delivered); function runNamespace() { bus.emit('go'); }
]] })
        spec.equal(events(G, 'runDefault'), 'delivered'); spec.equal(events(G, 'runNamespace'), 'delivered')
        local Q = graph.query(G); local incoming = Q.inn[G.by_qualified.delivered[1]]; local hits = {}
        for i = 1, #incoming, graph.EDGE do if incoming[i + 2] == 'automatic:event' then hits[G.nodes[incoming[i]].name] = true end end
        spec.truthy(hits.runDefault and hits.runNamespace)
    end)
    spec.it('blocks receiver shadows and unknown anonymous function scopes', function()
        local source = [[import { EventEmitter } from 'events'; const bus = new EventEmitter();
function handler() {} bus.on('go', handler);
function shadow(bus) { bus.emit('go'); }
function outer() { { const bus = unknown; bus.emit('go'); } }
function publish() { bus.emit('go'); }
]]
        local G = build({ ['events.js'] = source })
        spec.equal(events(G, 'shadow'), ''); spec.equal(events(G, 'outer'), ''); spec.equal(events(G, 'publish'), 'handler')
        G = build({ ['events.js'] = source .. "some((bus) => bus.emit('go'));" })
        spec.equal(events(G, 'publish'), '')
    end)
    spec.it('rejects lookalike emitters, local constructor shadows and dynamic event keys', function()
        for _, setup in ipairs({ "class EventEmitter {}", "import { EventEmitter } from './custom';",
            "import { EventEmitter } from 'events'; class EventEmitter {}" }) do
            local G = build({ ['events.js'] = setup .. "const bus = new EventEmitter(); function handler() {} bus.on('go', handler); function run() { bus.emit('go'); }" })
            spec.equal(events(G, 'run'), '')
        end
        local G = build({ ['events.js'] = [[import { EventEmitter } from 'events'; const bus = new EventEmitter();
function handler() {} bus.on('go', handler); function run() { bus.emit(key); }
]] }); spec.equal(events(G, 'run'), '')
        for _, continuation in ipairs({ '.other', '[0]', '()' }) do
            G = build({ ['events.js'] = "import E from 'events'; const bus = new E()\n" .. continuation .. ";\n"
                .. "function handler() {} bus.on('go', handler); function run() { bus.emit('go'); }" })
            spec.equal(events(G, 'run'), '', continuation)
        end
    end)
    spec.it('poisons receiver reassignment, aliases, escapes, member writes and listener removal', function()
        for _, mutation in ipairs({ 'bus = other;', 'const copy = bus;', 'unknown(bus);', "bus.off('go', handler);",
            "bus.removeAllListeners();", "bus.on('other', handler).removeAllListeners();", "unknown(bus.on('other', handler));",
            "const escaped = bus.on('other', handler); unknown(escaped);", 'bus.emit = other;', '({ bus } = other);' }) do
            local G = build({ ['events.js'] = "import { EventEmitter } from 'events'; const bus = new EventEmitter();\n"
                .. "function handler() {} bus.on('go', handler); " .. mutation .. " function run() { bus.emit('go'); }" })
            spec.equal(events(G, 'run'), '', mutation)
        end
    end)
    spec.it('keeps local registration order and rejects cross-function setup assumptions', function()
        local G = build({ ['events.js'] = [[import { EventEmitter } from 'events';
function handler() {}
function ordered() { const bus = new EventEmitter(); bus.on('go', handler); bus.emit('go'); }
function before() { const bus = new EventEmitter(); bus.emit('go'); bus.on('go', handler); }
const shared = new EventEmitter();
function setup() { shared.on('go', handler); }
function publish() { shared.emit('go'); }
]] })
        spec.equal(events(G, 'ordered'), 'handler'); spec.equal(events(G, 'before'), ''); spec.equal(events(G, 'publish'), '')
    end)
    spec.it('blocks exported receivers and class shadows of imported handler names', function()
        local G = build({ ['handler.js'] = 'export function handler() {}', ['events.js'] = [[import { EventEmitter } from 'events';
import { handler } from './handler'; const bus = new EventEmitter();
function run() { class handler {} bus.on('go', handler); bus.emit('go'); }
]] }); spec.equal(events(G, 'run'), '')
        G = build({ ['events.js'] = [[import { EventEmitter } from 'events'; export const bus = new EventEmitter();
function handler() {} bus.on('go', handler); function run() { bus.emit('go'); }
]] }); spec.equal(events(G, 'run'), '')
    end)
    spec.it('reuses query evidence across compact reloads, import aliases, edits and callers', function()
        local root = tmp_root .. '/automatic_events'
        local source = "import { EventEmitter } from 'node:events'; import { handled } from './handler';\n"
            .. "const bus = new EventEmitter(); bus.on('ready', handled); export function eventPublish() { bus.emit('ready'); }"
        write(root .. '/handler.ts', 'export function handled() {}'); write(root .. '/publisher.ts', source)
        local options = { cache_path = root .. '/cache.idx', lister = 'walk' }
        local idx, G = svc.get(root, options); idx:save(); svc.forget(root); idx, G = svc.get(root, options)
        spec.equal(events(G, 'eventPublish'), 'handled')
        local output, info = explore.run(G, idx, 'eventPublish handled', { explain = true })
        spec.truthy(#info.flows > 0); spec.contains(output, 'possible event delivery'); spec.equal(info.relationships_incomplete, false)
        local _, incoming = require('codeoutline.callers').run(G, idx, 'handled')
        local found = false; for _, caller in ipairs(incoming.callers) do if caller.name == 'eventPublish' then found = true end end
        spec.truthy(found)
        for _, rec in pairs(idx.files) do spec.nil_value(rec.automatic_events); spec.nil_value(rec.ordinary_bindings) end
        write(root .. '/publisher.ts', source:gsub("bus.emit%('ready'%)", "bus.emit('other')"))
        idx, G = svc.get(root, options); spec.equal(events(G, 'eventPublish'), '')
        svc.forget(root)
    end)
    spec.it('reports automatic event candidate and target limits', function()
        local G = build({ ['events.js'] = [[import { EventEmitter } from 'events'; const bus = new EventEmitter();
function one() {} function two() {} bus.on('go', one); bus.on('go', two); function run() { bus.emit('go'); }
]] })
        local module = require('codeoutline.automatic_events'); local previous = module.MAX_TARGETS; module.MAX_TARGETS = 1
        local ok, err = pcall(function() local _, Q = events(G, 'run'); spec.truthy(Q.incomplete) end)
        module.MAX_TARGETS = previous; assert(ok, err)
        previous = module.MAX_FILES; module.MAX_FILES = 0
        ok, err = pcall(function() local found, Q = events(G, 'run'); spec.equal(found, ''); spec.truthy(Q.incomplete) end)
        module.MAX_FILES = previous; assert(ok, err)
        previous = module.MAX_SITES; module.MAX_SITES = 1
        ok, err = pcall(function()
            local limited = build({ ['events.js'] = "import E from 'events'; const bus = new E(); function handler() {} bus.on('x', handler); function run() { bus.emit('x'); }" })
            local found, Q = events(limited, 'run'); spec.equal(found, ''); spec.truthy(Q.incomplete)
        end)
        module.MAX_SITES = previous; assert(ok, err)
    end)
end)

spec.describe('configured indirect dispatch', function()
    spec.it('does not turn identity module imports into broad dispatch hints', function()
        local rec = ci.parse('hint.lua', 'local skynet = require "skynet"\nfunction run() skynet.start(function() end) end')
        for _, name in ipairs(rec.dispatch_calls or {}) do spec.truthy(name ~= '@skynet') end
        rec = ci.parse('hint.lua', 'local skynet = require "skynet"\nlocal api = skynet\nfunction run() api.call(1, "lua", "go") end')
        local found = false
        for _, name in ipairs(rec.dispatch_calls or {}) do if name == '@skynet' then found = true end end
        spec.truthy(found, 'real module aliases retain conservative candidates')
    end)
    spec.it('filters incoming target literals without losing escaped aliases or caching negatives', function()
        local root = tmp_root .. '/incoming_literal_filter'
        write(root .. '/handlers.lua', 'function filter_first() end\nfunction filter_second() end\nfunction other() end\n')
        write(root .. '/first.lua', 'local api = require "filter_rpc"\nlocal key = "filter_\\102irst"\nfunction run_first() api.post(1, key) end\n')
        write(root .. '/second.lua', 'local api = require "filter_rpc"\nfunction run_second() api.post(1, "filter_second") end\n')
        write(root .. '/negative.lua', 'local api = require "filter_rpc"\nlocal escaped = "\\120"\nfunction run_other() api.post(1, "other") end\n')
        local _, G = svc.get(root, { cache_path = root .. '/cache.bin' })
        local original, parsed = ci.parse, {}
        ci.parse = function(path, ...)
            parsed[path] = (parsed[path] or 0) + 1
            return original(path, ...)
        end
        local ok, err = pcall(function()
            local I = require('codeoutline.indirect').query(G, { { kind = 'target', language = 'lua', call = 'filter_rpc.post', argument = 2 } })
            local first = I.incoming({ [G.by_name.filter_first[1]] = true })
            spec.equal(#first[G.by_name.run_first[1]], 1)
            spec.equal(parsed['negative.lua'], nil)
            spec.equal(parsed['second.lua'], nil)
            local second = I.incoming({ [G.by_name.filter_second[1]] = true })
            spec.equal(#second[G.by_name.run_second[1]], 1)
            spec.equal(parsed['second.lua'], 1)
            local outgoing = I.outgoing(G.by_name.run_other[1])
            spec.equal(#outgoing, 1)
            spec.equal(G.nodes[outgoing[1].target].name, 'other')
        end)
        ci.parse = original
        assert(ok, err)
    end)
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

spec.describe('query-time declared type hierarchy', function()
    local hierarchy = require('codeoutline.type_hierarchy')
    local function build(sources)
        local files = {}
        for path, source in pairs(sources) do files[path] = ci.parse(path, source, { ordinary_bindings = true }) end
        return graph.build({ files = files })
    end
    local function listed(entries)
        local out = {}; for _, entry in ipairs(entries) do out[#out + 1] = entry.name .. ':' .. entry.depth end
        table.sort(out); return table.concat(out, ',')
    end
    spec.it('returns direct and transitive C# bases and implementations with declaration evidence', function()
        local G = build({ ['types.cs'] = [[namespace Demo {
interface IRoot {} interface ILeft : IRoot {} interface IRight : IRoot {}
abstract class Base : ILeft, IRight {} class Store : Base {} class Other {}
}]] })
        local output, info = hierarchy.run(G, nil, 'Demo.Base')
        spec.equal(listed(info.ancestors), 'Demo.ILeft:1,Demo.IRight:1,Demo.IRoot:2')
        spec.equal(listed(info.descendants), 'Demo.Store:1')
        spec.equal(#info.edges, 5); spec.equal(info.cycle_detected, false)
        spec.equal(info.relationships_incomplete, false)
        spec.contains(output, 'declared implements ILeft at types.cs:3')
        spec.equal(info.ancestors[1].via.kind, 'implements')
        spec.equal(info.ancestors[1].path[1].name, 'Demo.Base')
        spec.nil_value(G.type_hierarchy); spec.nil_value(G.out)
    end)
    spec.it('resolves Java packages and Kotlin import aliases without same-name cross-links', function()
        local G = build({ ['api/Root.java'] = 'package api; public interface Root {}',
            ['impl/Base.java'] = 'package impl; import api.Root; public class Base implements Root {}',
            ['impl/Store.java'] = 'package impl; public class Store extends Base {}',
            ['other/Root.java'] = 'package other; public interface Root {}',
            ['root.kt'] = 'package kapi\ninterface KRoot {}',
            ['base.kt'] = 'package kimpl\nimport kapi.KRoot as Contract\nopen class KBase : Contract {}',
            ['store.kt'] = 'package kimpl\nclass KStore : KBase() {}' })
        local _, info = hierarchy.run(G, nil, 'api.Root')
        spec.equal(listed(info.descendants), 'impl.Base:1,impl.Store:2')
        _, info = hierarchy.run(G, nil, 'kapi.KRoot')
        spec.equal(listed(info.descendants), 'kimpl.KBase:1,kimpl.KStore:2')
        spec.equal(info.relationships_incomplete, false)
        _, info = hierarchy.run(G, nil, 'Root')
        spec.equal(#info.targets, 2)
    end)
    spec.it('follows TS import aliases, barrels and explicit multiple interface bases', function()
        local G = build({ ['root.ts'] = 'export interface Root {} export interface Extra {}',
            ['barrel.ts'] = "export { Root as Contract, Extra } from './root';",
            ['store.ts'] = "import type { Contract as R, Extra } from './barrel';\ninterface Mid extends R, Extra {}\nclass Store implements Mid {}",
            ['other.ts'] = 'interface Root {} class Other implements Root {}' })
        local _, info = hierarchy.run(G, nil, 'Store')
        spec.equal(listed(info.ancestors), 'Extra:2,Mid:1,Root:2')
        spec.equal(info.relationships_incomplete, false)
        _, info = hierarchy.run(G, nil, 'Mid', { direction = 'descendants' })
        spec.equal(listed(info.descendants), 'Store:1'); spec.equal(#info.ancestors, 0)
        for _, entry in ipairs(info.descendants) do spec.equal(entry.file, 'store.ts') end
    end)
    spec.it('supports C++ includes, namespace and type aliases, multiple and virtual inheritance', function()
        local G = build({ ['api.hpp'] = 'namespace api { struct Root {}; struct Extra {}; }',
            ['aliases.hpp'] = '#include "api.hpp"\nnamespace ns = api; using Contract = ns::Root;',
            ['types.cpp'] = '#include "aliases.hpp"\nstruct Mid : virtual public Contract, private api::Extra {};\nstruct Store : Mid {};',
            ['other.cpp'] = 'namespace api { struct Root {}; } struct Other : api::Root {};' })
        local _, info = hierarchy.run(G, nil, 'Store')
        spec.equal(listed(info.ancestors), 'Mid:1,api::Extra:2,api::Root:2')
        spec.equal(info.relationships_incomplete, false)
        _, info = hierarchy.run(G, nil, 'api::Root', { direction = 'descendants' })
        spec.equal(#info.targets, 2)
        spec.equal(listed(info.descendants), 'Mid:1,Other:1,Store:2')
    end)
    spec.it('reports unresolved, ambiguous, generic and structural-only relationships without guessing', function()
        local G = build({ ['a.cs'] = 'namespace A { interface Root {} } namespace B { interface Root {} }',
            ['b.cs'] = 'using A; using B; class Ambiguous : Root {} class Missing : External {} class Generic<T> : A.Root {}',
            ['a.ts'] = 'interface Contract {} class Generic<T> implements Contract {} class Shape {}\nclass Derived extends Missing {}' })
        local _, info = hierarchy.run(G, nil, 'Ambiguous', { direction = 'ancestors' })
        spec.equal(#info.ancestors, 0); spec.equal(info.unresolved[1].reason, 'ambiguous type')
        _, info = hierarchy.run(G, nil, 'Missing', { direction = 'ancestors' })
        spec.equal(info.unresolved[1].written, 'External'); spec.truthy(info.relationships_incomplete)
        _, info = hierarchy.run(G, nil, 'A.Root', { direction = 'descendants' })
        spec.equal(#info.descendants, 0); spec.truthy(info.query_stats.reverse_unresolved > 0)
        _, info = hierarchy.run(G, nil, 'Contract')
        spec.equal(#info.descendants, 0); spec.truthy(info.relationships_incomplete)
        _, info = hierarchy.run(G, nil, 'Shape')
        spec.equal(#info.descendants, 0)
        local cpp = build({ ['a.cpp'] = 'struct Root {}; template<class T> struct Generic : Root {}; struct Child : Generic<int> {};' })
        _, info = hierarchy.run(cpp, nil, 'Child', { direction = 'ancestors' })
        spec.equal(#info.ancestors, 0); spec.equal(info.unresolved[1].reason, 'unsupported declaration')
    end)
    spec.it('bounds cycles, depth, total nodes and output without treating leaves or diamonds as truncated', function()
        local G = build({ ['a.cs'] = 'class Root {} class Mid : Root {} class Leaf : Mid {} class X : Y {} class Y : X {}' })
        local _, info = hierarchy.run(G, nil, 'Root', { depth = 2 })
        spec.equal(listed(info.descendants), 'Leaf:2,Mid:1'); spec.equal(info.depth_limit_reached, false)
        _, info = hierarchy.run(G, nil, 'Root', { depth = 1 })
        spec.equal(listed(info.descendants), 'Mid:1'); spec.truthy(info.depth_limit_reached)
        _, info = hierarchy.run(G, nil, 'Leaf', { max_nodes = 2 })
        spec.equal(#info.ancestors, 1); spec.truthy(info.node_limit_reached)
        _, info = hierarchy.run(G, nil, 'X')
        spec.truthy(info.cycle_detected); spec.truthy(info.relationships_incomplete)
        _, info = hierarchy.run(G, nil, 'X', { depth = 1, direction = 'ancestors' })
        spec.truthy(info.cycle_detected)
        local output; output, info = hierarchy.run(G, nil, 'Root', { budget = 256 })
        spec.truthy(#output <= 256); spec.truthy(info.truncated)
        _, info = hierarchy.run(G, nil, 'missing'); spec.equal(#info.targets, 0)
        for _, opts in ipairs({ { depth = 0 }, { max_nodes = false }, { direction = 'parents' }, { budget = 12 } }) do
            spec.equal(pcall(hierarchy.run, G, nil, 'Root', opts), false)
        end
    end)
    spec.it('verifies original base syntax rather than erased generic or dynamic expressions', function()
        local G = build({ ['a.ts'] = 'class Factory {} class Wrong extends Factory() {} class Wrong2 extends (Factory) {}',
            ['a.kt'] = 'interface Root {}\nclass Delegated : Root by delegate {}',
            ['a.cs'] = 'namespace A { interface Root {} } namespace B { interface Root {} class Child : global::A.Root {} }' })
        for _, name in ipairs({ 'Wrong', 'Wrong2', 'Delegated' }) do
            local _, info = hierarchy.run(G, nil, name, { direction = 'ancestors' })
            spec.equal(#info.ancestors, 0, name); spec.truthy(info.relationships_incomplete, name)
        end
        local _, info = hierarchy.run(G, nil, 'B.Child', { direction = 'ancestors' })
        spec.equal(listed(info.ancestors), 'A.Root:1')
        spec.equal(info.ancestors[1].via.written, 'global::A.Root')
    end)
    spec.it('reports declaration and source budgets and preserves cancellation', function()
        local G = build({ ['a.cs'] = 'interface Root {} class A : Root {} class B : Root {}' })
        local saved = { hierarchy.MAX_CANDIDATES, hierarchy.MAX_FILES, hierarchy.MAX_SCAN_NODES }
        local ok, err = pcall(function()
            hierarchy.MAX_CANDIDATES = 1
            local _, info = hierarchy.run(G, nil, 'Root')
            spec.equal(#info.descendants, 1); spec.truthy(info.candidate_limit_reached)
            hierarchy.MAX_CANDIDATES = saved[1]; hierarchy.MAX_SCAN_NODES = 1
            _, info = hierarchy.run(G, nil, 'Root'); spec.truthy(info.candidate_limit_reached)
            hierarchy.MAX_SCAN_NODES = saved[3]; hierarchy.MAX_FILES = 0
            _, info = hierarchy.run(G, nil, 'Root'); spec.truthy(info.candidate_limit_reached)
        end)
        hierarchy.MAX_CANDIDATES, hierarchy.MAX_FILES, hierarchy.MAX_SCAN_NODES = saved[1], saved[2], saved[3]
        assert(ok, err)
        local ctl = require('codeoutline.control'); local old = ctl.callback
        ctl.callback = function() error(ctl.cancelled(), 0) end
        local success, failure = pcall(hierarchy.run, G, nil, 'Root'); ctl.callback = old
        spec.equal(success, false); spec.truthy(ctl.is_interrupted(failure))
    end)
    spec.it('reuses compact saved records and updates hierarchy after source edits and deletion', function()
        local root = tmp_root .. '/type_hierarchy'
        write(root .. '/root.cs', 'namespace Demo { interface Root {} }')
        write(root .. '/child.cs', 'using Contract = Demo.Root; class Child : Contract {}')
        local opts = { cache_path = root .. '/cache.bin' }
        local _, info = svc.type_hierarchy(root, 'Demo.Root', opts)
        spec.equal(listed(info.descendants), 'Child:1'); spec.equal(info.query_stats.ordinary.parses, 2)
        local idx = svc.resident(root)
        for _, rec in pairs(idx.files) do spec.nil_value(rec.implementation_evidence); spec.nil_value(rec.type_hierarchy) end
        svc.forget(root)
        _, info = svc.type_hierarchy(root, 'Demo.Root', opts)
        spec.equal(info.refresh.parsed, 0); spec.equal(#info.descendants, 1)
        write(root .. '/child.cs', 'class Child {}')
        _, info = svc.type_hierarchy(root, 'Demo.Root', opts)
        spec.equal(#info.descendants, 0)
        os.remove(root .. '/child.cs')
        _, info = svc.type_hierarchy(root, 'Child', opts); spec.equal(#info.targets, 0)
        svc.forget(root)
    end)
    spec.it('handles source-byte, base and edge limits explicitly', function()
        local G = build({ ['a.cs'] = 'interface A {} interface B {} class Child : A, B {}' })
        local saved = { hierarchy.MAX_BYTES, hierarchy.MAX_BASES, hierarchy.MAX_EDGES }
        local ok, err = pcall(function()
            hierarchy.MAX_BASES = 1
            local _, info = hierarchy.run(G, nil, 'Child', { direction = 'ancestors' })
            spec.equal(#info.ancestors, 1); spec.truthy(info.candidate_limit_reached)
            hierarchy.MAX_BASES = saved[2]; hierarchy.MAX_EDGES = 1
            _, info = hierarchy.run(G, nil, 'Child', { direction = 'ancestors' })
            spec.equal(#info.edges, 1); spec.truthy(info.candidate_limit_reached)
            hierarchy.MAX_EDGES = saved[3]; hierarchy.MAX_BYTES = 1
            G.files[1].size = 100
            _, info = hierarchy.run(G, nil, 'Child')
            spec.equal(#info.targets, 0); spec.truthy(info.candidate_limit_reached)
        end)
        hierarchy.MAX_BYTES, hierarchy.MAX_BASES, hierarchy.MAX_EDGES = saved[1], saved[2], saved[3]
        assert(ok, err)
    end)
    spec.it('retries encoding repairs and rejects changed source snapshots', function()
        local source = 'class Root {} class Child : Root {}'
        local G = graph.build({ files = { ['a.cs'] = ci.parse('a.cs', source) } })
        local output, info = hierarchy.run(G, { query_source = function()
            graph.remove_file(G, 'a.cs') -- encoding repairs replace the old file and IDs
            graph.add_file(G, 'a.cs', ci.parse('a.cs', source))
            return source, true
        end }, 'Root')
        spec.nil_value(output); spec.truthy(info.encoding_retry)
        local root = tmp_root .. '/hierarchy_snapshot'
        write(root .. '/a.cs', source)
        local idx, symbols = svc.get(root, { cache_path = root .. '/cache.bin' })
        write(root .. '/a.cs', source .. '\nclass Changed {}')
        local ok, err = pcall(hierarchy.run, symbols, idx, 'Root')
        spec.equal(ok, false); spec.contains(tostring(err), 'source changed during query')
        svc.forget(root)
    end)
    spec.it('does not publish C++ bases from truncated include visibility', function()
        local G = build({ ['types.cpp'] = '#include "a.hpp"\nstruct Child : Root {};',
            ['a.hpp'] = '#include "b.hpp"', ['b.hpp'] = 'struct Root {};' })
        local previous = graph.MAX_INCLUDES; graph.MAX_INCLUDES = 1
        local ok, err = pcall(function()
            local _, info = hierarchy.run(G, nil, 'Child', { direction = 'ancestors' })
            spec.equal(#info.ancestors, 0); spec.truthy(info.candidate_limit_reached)
        end)
        graph.MAX_INCLUDES = previous; assert(ok, err)
    end)
    spec.it('preserves aliases across ordinary FIFO eviction and scopes source limits', function()
        local root = tmp_root .. '/hierarchy_fifo'
        write(root .. '/root.cs', 'namespace Demo { interface Root {} }')
        for i = 1, 24 do
            write(root .. '/child' .. i .. '.cs', 'using Contract = Demo.Root; class Child' .. i .. ' : Contract {}')
        end
        local opts = { cache_path = root .. '/cache.bin' }
        local _, info = svc.type_hierarchy(root, 'Demo.Root', opts)
        spec.equal(#info.descendants, 24); spec.equal(info.relationships_incomplete, false)
        spec.equal(info.query_stats.source_files, 25); spec.truthy(info.query_stats.ordinary.files <= 16)
        local previous = hierarchy.MAX_FILES; hierarchy.MAX_FILES = 2
        local ok, err = pcall(function()
            local _, limited = svc.type_hierarchy(root, 'Demo.Root', opts)
            spec.truthy(limited.candidate_limit_reached); spec.equal(limited.query_stats.source_files, 2)
            spec.truthy(#limited.descendants < 24)
        end)
        hierarchy.MAX_FILES = previous; svc.forget(root); assert(ok, err)
    end)
end)

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

spec.describe('query-time unknown suffixes', function()
    spec.it('selects supported language hints or strong syntax without learning an extension', function()
        local cases = {
            { 'lua', 'local function save() end' },
            { 'python', 'def save():\n    pass\n' },
            { 'cpp', '#include "api.h"\nstruct Box { public: void save() {} };' },
            { 'c', '#include "api.h"\nstatic int save(void) { return 1; }' },
            { 'rust', 'pub fn save() {}' },
            { 'go', 'package main\nfunc save() {}' },
            { 'kotlin', 'fun save() = 1' },
            { 'java', 'package sample; public class Store { void save() {} }' },
            { 'csharp', 'using System; class Store { public void Save() {} }' },
            { 'javascript', 'function save() {}' },
            { 'typescript', 'function save(value: number) {}' },
            { 'arkts', '@Component struct Store { build() {} }' },
        }
        for _, case in ipairs(cases) do
            local rec = ci.parse('source.unmapped', case[2], { detect = true })
            spec.truthy(rec, case[1]); spec.equal(rec.language, case[1]); spec.equal(rec.language_source, 'syntax')
            spec.equal(rec.on_demand, true)
        end
        spec.nil_value(ci.language('source.unmapped'))
        spec.nil_value(ci.parse('source.unmapped', cases[1][2]), 'ordinary indexing must not infer unknown files')
        spec.equal(ci.parse('source.unmapped', 'int save() {}', { language = 'c++' }).language, 'cpp')
        spec.equal(ci.parse('source.unmapped', 'int save() {}', { language = 'unsupported', detect = true }), nil)
        for _, source in ipairs({ '/* function fake() {} */', '"function fake() {}"',
            '--[[\nfunction fake() {}\n]]', '#!/bin/bash\nfunction fake() {}',
            '```js\nfunction fake() {}\n```', '\0function fake() {}', 'ordinary prose',
            'local function a() end\nfunction b() {}' }) do
            spec.nil_value(ci.parse('source.unmapped', source, { detect = true }), source)
        end
    end)
    spec.it('explores explicit files in isolated overlays and never persists inferred records', function()
        local root = tmp_root .. '/unknown_suffixes'
        write(root .. '/base.lua', 'function resident_symbol() end\n')
        write(root .. '/part.fragment', '#include "api.h"\nstatic int dynamic_fragment(void) { return 7; }\n')
        write(root .. '/other.fragment', 'local function dynamic_lua() return 8 end\n')
        write(root .. '/unclear.fragment', 'ordinary prose')
        local opts = { cache_path = root .. '/cache.idx', lister = 'walk' }
        local idx, G = svc.get(root, opts)
        local files, nodes = G.file_count, G.node_count
        local output, info = svc.explore(root, 'part.fragment dynamic_fragment', opts)
        spec.contains(output, 'return 7'); spec.contains(output, 'On-demand source: part.fragment (c, syntax)')
        spec.equal(#info.on_demand_files, 1); spec.equal(info.on_demand_files[1].language, 'c')
        output, info = svc.explore(root, 'other.fragment dynamic_lua', opts)
        spec.contains(output, 'return 8'); spec.equal(info.on_demand_files[1].language, 'lua')
        output, info = svc.explore(root, 'unclear.fragment', opts)
        spec.equal(#info.on_demand_files, 0); spec.equal(#info.on_demand_rejected, 1)
        write(root .. '/other.fragment', '#include "api.h"\nint dynamic_c(void) { return 9; }\n')
        output, info = svc.explore(root, 'other.fragment dynamic_c', opts)
        spec.contains(output, 'return 9'); spec.equal(info.on_demand_files[1].language, 'c')
        spec.equal(idx:symbols(), G); spec.equal(G.file_count, files); spec.equal(G.node_count, nodes)
        spec.nil_value(idx.files['part.fragment']); spec.nil_value(G.by_name.dynamic_fragment)
        spec.nil_value(G.by_name.dynamic_c); spec.nil_value(G.file_index['other.fragment'])
        write(root .. '/part.fragment', '#include "api.h"\nint resident_symbol(void) { return 10; }\n')
        svc.explore(root, 'part.fragment resident_symbol', opts)
        spec.equal(#G.by_name.resident_symbol, 1); spec.equal(#G.by_lname.resident_symbol, 1)
        spec.equal(#G.by_qualified.resident_symbol, 1, 'copy-on-write lists must not leak overlay IDs')
        write(root .. '-outside.fragment', '#include "api.h"\nvoid OutsideUnknown() {}')
        output, info = svc.explore(root, '../unknown_suffixes-outside.fragment OutsideUnknown', opts)
        spec.equal(#info.on_demand_files, 0); spec.nil_value(output:find('void OutsideUnknown', 1, true))
        write(root .. '/large.fragment', '#include "api.h"\n' .. string.rep(' ', 1048576))
        output, info = svc.explore(root, 'large.fragment', opts)
        spec.equal(#info.on_demand_files, 0); spec.equal(info.on_demand_truncated, true)
        idx:save(); svc.forget(root); idx = svc.refresh(root, opts)
        spec.nil_value(idx.files['other.fragment']); svc.forget(root)
    end)
end)

spec.describe('unconfirmed exploration candidates', function()
    local function project(files)
        local records = {}
        for path, source in pairs(files) do records[path] = ci.parse(path, source, { ordinary_bindings = true }) end
        return graph.build({ files = records }), { root = tmp_root,
            query_source = function(_, path) return assert(files[path]), false end }
    end
    spec.it('shows distant candidate sources without adding seeds, paths or execution edges', function()
        local G, idx = project({
            ['use/start.cpp'] = 'void AgentFallbackStart() { AgentFallbackTarget(); }\n',
            ['one/lib.c'] = 'int AgentFallbackTarget() { return 11; }\n',
            ['two/lib.c'] = 'int AgentFallbackTarget() { return 22; }\n',
            ['three/private.c'] = 'static int AgentFallbackTarget() { return 33; }\n',
            ['four/other.lua'] = 'function AgentFallbackTarget() end\n',
        })
        local output, info = explore.run(G, idx, 'AgentFallbackStart')
        spec.equal(#info.seeds, 1); spec.equal(#info.flows, 0)
        spec.equal(#info.unresolved_candidates, 1)
        local group = info.unresolved_candidates[1]
        spec.equal(group.status, 'unconfirmed'); spec.equal(group.path, 'use/start.cpp')
        spec.equal(group.call, 'AgentFallbackTarget'); spec.equal(#group.candidates, 2)
        spec.equal(group.candidates[1].path, 'one/lib.c'); spec.equal(group.candidates[2].path, 'two/lib.c')
        for _, candidate in ipairs(group.candidates) do
            spec.equal(candidate.status, 'unconfirmed'); spec.equal(candidate.line, 1)
            spec.contains(candidate.reason, 'binding unconfirmed')
        end
        spec.contains(output, '## Unconfirmed definition candidates'); spec.contains(output, 'not call edges or verified bindings')
        spec.contains(output, 'return 11'); spec.contains(output, 'return 22')
        spec.nil_value(output:find('return 33', 1, true))
        local Q = graph.query(G)
        spec.equal(#Q.out[G.by_name.AgentFallbackStart[1]], 0)
        for _, id in ipairs(G.by_name.AgentFallbackTarget) do spec.equal(#Q.inn[id], 0) end
        spec.nil_value(G.out); spec.nil_value(G.inn)
        for _, rec in pairs(G.files) do spec.nil_value(rec.unresolved_candidates) end
        local original = idx.query_source
        idx.query_source = function(self, path)
            if path == 'one/lib.c' then error('candidate source changed') end
            return original(self, path)
        end
        local ok, err = pcall(explore.run, G, idx, 'AgentFallbackStart')
        spec.equal(ok, false); spec.contains(tostring(err), 'candidate source changed')
    end)
    spec.it('retains known Lua bindings and C++ receiver barriers', function()
        local G, idx = project({
            ['use/start.lua'] = 'local api = require("lib.api")\nfunction AgentBlockedImport() api.AgentMissing() end\n',
            ['lib/api.lua'] = 'local M = {}\nreturn M\n',
            ['elsewhere/free.lua'] = 'function AgentMissing() end\n',
            ['types.hpp'] = 'class AgentA {}; class AgentB { public: void AgentMethod() {} };\n',
            ['use/types.cpp'] = '#include "../types.hpp"\nvoid AgentBlockedReceiver(AgentA *p) { p->AgentMethod(); }\n',
        })
        for _, name in ipairs({ 'AgentBlockedImport', 'AgentBlockedReceiver' }) do
            local output, info = explore.run(G, idx, name)
            spec.equal(#info.unresolved_candidates, 0)
            spec.nil_value(output:find('## Unconfirmed definition candidates', 1, true))
        end
    end)
    spec.it('offers alternative proxy macro declarations without treating them as calls', function()
        local header = '#ifndef AGENT_PROXY_H\n#define AGENT_PROXY_H\n#define AgentProxy proxy->call\n#endif\n'
        local G, idx = project({ ['one/proxy.h'] = header, ['two/proxy.h'] = header,
            ['use/start.cpp'] = '#include <proxy.h>\nvoid AgentProxyStart() { AgentProxy(); }\n' })
        local output, info = explore.run(G, idx, 'AgentProxyStart')
        spec.equal(#info.unresolved_candidates, 1)
        local group = info.unresolved_candidates[1]
        spec.equal(#group.candidates, 2)
        for _, candidate in ipairs(group.candidates) do
            spec.equal(candidate.kind, 'macro'); spec.equal(candidate.line, 3)
            spec.contains(candidate.reason, 'possible macro declaration')
        end
        spec.contains(output, '#define AgentProxy proxy->call'); spec.equal(#info.flows, 0)
        spec.equal(#graph.query(G).out[G.by_name.AgentProxyStart[1]], 0)
    end)
    spec.it('suggests unseen macro definitions without turning API uses into graph edges', function()
        local G, idx = project({ ['use/start.cpp'] = 'void AgentMacroOnlyStart() { AgentMacroOnly(); }\n',
            ['one/api.h'] = '#define AgentMacroOnly() api_call()\n',
            ['two/api.h'] = '#define AgentMacroOnly() api_call()\n',
            ['other/calls.cpp'] = 'void AgentOtherUse() { AgentMacroOnly(); }\n' })
        local output, info = explore.run(G, idx, 'AgentMacroOnlyStart')
        spec.equal(#info.unresolved_candidates, 1); spec.equal(#info.unresolved_candidates[1].candidates, 2)
        for _, candidate in ipairs(info.unresolved_candidates[1].candidates) do
            spec.equal(candidate.kind, 'macro'); spec.truthy(candidate.path:match('/api%.h$'))
        end
        spec.contains(output, '#define AgentMacroOnly'); spec.equal(#info.flows, 0)
        spec.equal(#graph.query(G).out[G.by_name.AgentMacroOnlyStart[1]], 0)
    end)
    spec.it('bounds candidate lookup and reports source and output omissions', function()
        local files = { ['use/start.cpp'] = 'void AgentBudgetStart() { AgentBudgetTarget(); }\n' }
        for i = 1, 300 do files['lib' .. i .. '/api.c'] = 'int AgentBudgetTarget() { return 1; }\n' end
        local G, idx = project(files)
        local output, info = explore.run(G, idx, 'AgentBudgetStart')
        spec.equal(#info.unresolved_candidates, 1)
        spec.equal(#info.unresolved_candidates[1].candidates, 4)
        spec.equal(info.query_stats.definition_candidates.scanned, 256)
        spec.equal(info.query_stats.definition_candidates.files, 4)
        spec.equal(info.unresolved_candidates_truncated, true)
        output, info = explore.run(G, idx, 'AgentBudgetStart', { budget = 256 })
        spec.truthy(#output <= 256); spec.equal(info.unresolved_candidates_truncated, true)
        spec.contains(output, 'not call edges')
    end)
    spec.it('keeps a separate bounded suggestion budget after graph macro exhaustion', function()
        local header = '#ifndef AGENT_PROXY_BUDGET\n#define AGENT_PROXY_BUDGET\n#define AgentProxyBudget proxy->call\n#endif\n'
        local G, idx = project({ ['one/proxy.h'] = header, ['two/proxy.h'] = header,
            ['use/start.cpp'] = '#include <proxy.h>\nvoid AgentProxyBudgetStart() {\n'
                .. string.rep('AgentProxyBudget();\n', 30) .. '}\n' })
        local macros = require('codeoutline.cpp_macros')
        local before = macros.MAX_EVENTS; macros.MAX_EVENTS = 20
        local ok, output, info = pcall(explore.run, G, idx, 'AgentProxyBudgetStart')
        macros.MAX_EVENTS = before; assert(ok, output)
        spec.equal(info.relationships_incomplete, true)
        spec.truthy(#info.unresolved_candidates > 0)
        spec.equal(#info.unresolved_candidates[1].candidates, 2)
        spec.equal(info.unresolved_candidates_truncated, true)
        spec.contains(output, 'Unconfirmed definition candidates')
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

spec.describe('configured dispatch aliases across languages', function()
    local rules = {
        { kind = 'event', call = 'bus.emit', argument = 1, register = 'bus.on', keyArgument = 1, handlerArgument = 2 },
        { kind = 'callback', call = 'schedule', argument = 2 },
        { kind = 'target', call = 'worker.post', argument = 2 },
        { kind = 'callback', call = 'net->send', argument = 2 },
    }
    local function build(files)
        local parsed = {}
        for path, source in pairs(files) do parsed[path] = ci.parse(path, source, { dispatch = true }) end
        return graph.build({ files = parsed })
    end
    local function indirect(G, name, opts)
        local Q = graph.query(G, { dispatch_rules = opts or rules, explain = true })
        local result, edges = {}, Q.out[G.by_name[name][1]]
        for i = 1, #edges, graph.EDGE do
            if edges[i + 2]:match('^indirect:') then result[#result + 1] = G.nodes[edges[i]].name end
        end
        table.sort(result)
        return table.concat(result, ','), Q
    end
    spec.it('expands API, callback and literal aliases in Lua, JS, TS and Python', function()
        local sources = {
            lua = [[local function done() end
local api = bus
local cb = done
local event = 'tick'
local later = schedule
local rpc = worker
local target = 'done'
api.on(event, cb)
function run() api.emit(event); later(1, cb); rpc.post(1, target) end]],
            js = [[function done() {}
const api = bus; const cb = done; const event = 'tick'; const later = schedule;
const rpc = worker; const target = 'done';
api.on(event, cb);
function run() { api.emit(event); later(1, cb); rpc.post(1, target); }]],
            ts = [[function done() {}
const api = bus; const cb: Handler = done; const event = 'tick'; const later = schedule;
const rpc = worker; const target = 'done';
api.on(event, cb);
function run() { api.emit(event); later(1, cb); rpc.post(1, target); }]],
            py = 'def done():\n    pass\napi = bus\ncb = done\nevent = "tick"\nlater = schedule\n'
                .. 'rpc = worker\ntarget = "done"\napi.on(event, cb)\ndef run():\n'
                .. '    api.emit(event)\n    later(1, cb)\n    rpc.post(1, target)\n',
        }
        for ext, source in pairs(sources) do
            local G = build({ ['a.' .. ext] = source })
            local found, Q = indirect(G, 'run')
            spec.equal(found, 'done,done,done', ext)
            spec.equal(#Q.inn[G.by_name.done[1]], ext == 'lua' and 9 or 12, ext)
        end
    end)
    spec.it('rejects overwritten, shadowed and computed dispatch aliases', function()
        local cases = {
            { 'a.lua', 'local function done() end\nlocal cb = done\ncb = other\nfunction run() schedule(1, cb) end' },
            { 'a.lua', 'local function done() end\nlocal cb = done\ncb, other = other, done\nfunction run() schedule(1, cb) end' },
            { 'a.lua', 'local api = bus\nfunction run(api) api.emit("tick") end' },
            { 'a.lua', 'local self = bus\nlocal M = {}\nfunction M:run() self.emit("tick") end' },
            { 'a.lua', 'local api = bus\nfunction run() for api in values() do api.emit("tick") end end' },
            { 'a.lua', 'local function done() end\nlocal cb = done\nfunction run() local x, cb = values(); schedule(1, cb) end' },
            { 'a.js', 'function done() {} const cb = done; cb = other; function run() { schedule(1, cb); }' },
            { 'a.js', 'function done() {} const schedule = "text"; function run() { schedule(1, done); }' },
            { 'a.js', 'function done() {} let cb = done; [cb] = other; function run() { schedule(1, cb); }' },
            { 'a.js', 'const api = bus; function run(api) { api.emit("tick"); }' },
            { 'a.js', 'import * as api from "bus"; function run() { try {} catch(api) { api.emit("tick"); } }' },
            { 'a.js', 'import * as api from "bus"; function run() { const {api} = object; api.emit("tick"); }' },
            { 'a.js', 'const api = bus; api.emit = other; function run() { api.emit("tick"); }' },
            { 'a.ts', 'function done() {} const cb = done; function run(cb: Handler) { schedule(1, cb); }' },
            { 'a.py', 'def done():\n    pass\ncb = done\ncb = other\ndef run():\n    schedule(1, cb)\n' },
            { 'a.py', 'def done():\n    pass\ncb = done\ncb, other = other, done\ndef run():\n    schedule(1, cb)\n' },
            { 'a.py', 'import bus as api\ndef run(api):\n    api.emit("tick")\n' },
            { 'a.py', 'import bus as api\ndef run():\n    with context as api:\n        api.emit("tick")\n' },
            { 'a.py', 'def done():\n    pass\ncb = done\ndef run():\n    schedule(1, cb)\n    cb = other\n' },
            { 'a.py', 'import bus as api\ndef run():\n    for api in values:\n        api.emit("tick")\n' },
            { 'a.cpp', 'void done() {} void run(void (*cb)()) { schedule(1, cb); }' },
            { 'a.cpp', 'void done() {} void run() { auto cb = done; cb = other; schedule(1, cb); }' },
        }
        for _, case in ipairs(cases) do
            local source = case[2]
            -- Every event case has a real registration to expose false matches.
            if case[1]:match('%.lua$') then source = 'local function leaf() end\nbus.on("tick", leaf)\n' .. source
            elseif case[1]:match('%.py$') then source = 'def leaf():\n    pass\nbus.on("tick", leaf)\n' .. source
            elseif case[1]:match('%.js$') or case[1]:match('%.ts$') then source = 'function leaf() {} bus.on("tick", leaf);\n' .. source end
            spec.equal(indirect(build({ [case[1]] = source }), 'run'), '', case[2])
        end
        -- Explicit in-memory parsing must retain an empty site result rather
        -- than trying to read a project root when every API binding is rejected.
        spec.equal(indirect(build({ ['a.js'] = 'function done() {} const schedule = "text"; function run() { schedule(1, done); }' }), 'run'), '')
    end)
    spec.it('resolves C and C++ function-pointer callback variables', function()
        for _, ext in ipairs({ 'c', 'cpp' }) do
            local G = build({ ['a.' .. ext] = [[void done(void) {}
void run(void) {
    void (*cb)(void) = &done;
    schedule(1, cb);
}]] })
            spec.equal(indirect(G, 'run'), 'done', ext)
        end
    end)
    spec.it('resolves imported Lua, ES module and Python callbacks through aliases', function()
        local cases = {
            { files = { ['handler.lua'] = 'local M = {}\nfunction M.done() end\nreturn M\n',
                ['a.lua'] = "local m = require('handler')\nlocal api = require('bus')\nlocal cb = m.done\napi.on('tick', cb)\nfunction run() api.emit('tick') end\n" } },
            { files = { ['handler.js'] = 'export function done() {}',
                ['a.js'] = "import { done as handler } from './handler'; import * as api from 'bus';\nconst cb = handler; api.on('tick', cb);\nfunction run() { api.emit('tick'); }" } },
            { files = { ['handler.ts'] = 'export function done() {}',
                ['a.ts'] = "import * as handlers from './handler'; import {on as register, emit as publish} from 'bus';\nconst cb = handlers.done; register('tick', cb);\nfunction run() { publish('tick'); }" } },
            { files = { ['handler.py'] = 'def done():\n    pass\n',
                ['a.py'] = "from handler import done as handler\nimport bus as api\ncb = handler\napi.on('tick', cb)\ndef run():\n    api.emit('tick')\n" } },
        }
        for i, case in ipairs(cases) do spec.equal(indirect(build(case.files), 'run'), 'done', 'import case ' .. i) end
        local G = build({ ['a.lua'] = 'local M = {}\nfunction M.done() end\nlocal N = M\nlocal cb = N.done\nfunction run() schedule(1, M.done); schedule(1, cb); schedule(1, N.done) end' })
        spec.equal(indirect(G, 'run'), 'done,done,done')
    end)
    spec.it('uses exact imported targets and bounds callback alias chains', function()
        local G = build({
            ['right.js'] = 'export function done() {}', ['wrong.js'] = 'export function done() {}',
            ['a.js'] = "import {done as handler} from './right'; const cb = handler; function run() { schedule(1, cb); }",
        })
        local _, Q = indirect(G, 'run')
        for i = 1, #Q.out[G.by_name.run[1]], graph.EDGE do
            local id = Q.out[G.by_name.run[1]][i]
            if G.nodes[id].name == 'done' then spec.equal(G.files[G.node_file[id]].path, 'right.js') end
        end
        G = build({ ['wrong.py'] = 'def done():\n    pass\n',
            ['a.py'] = 'from missing import done as handler\ncb = handler\ndef run():\n    schedule(1, cb)\n' })
        spec.equal(indirect(G, 'run'), '')
        for _, count in ipairs({ 8, 9 }) do
            local source = 'function done() {}\n'
            for i = 1, count do source = source .. 'const cb' .. i .. ' = ' .. (i == 1 and 'done' or 'cb' .. (i - 1)) .. ';\n' end
            source = source .. 'function run() { schedule(1, cb' .. count .. '); }'
            spec.equal(indirect(build({ ['a.js'] = source }), 'run'), count == 8 and 'done' or '')
        end
    end)
    spec.it('persists conservative alias roots and resolves them after reload and edits', function()
        local cases = {
            lua = 'local function done() end\nlocal api = bus\nlocal cb = done\napi.on("tick", cb)\nfunction run() api.emit("tick") end\n',
            js = 'function done() {} const api = bus; const cb = done; api.on("tick", cb); function run() { api.emit("tick"); }',
            ts = 'function done() {} import {on as register, emit as publish} from "bus"; const cb = done; register("tick", cb); function run() { publish("tick"); }',
            py = 'def done():\n    pass\nimport bus as api\ncb = done\napi.on("tick", cb)\ndef run():\n    api.emit("tick")\n',
            c = 'void done(void) {}\nvoid run(void) { void (*cb)(void) = &done; Rpc *api = net; api->send(1, cb); }',
        }
        for ext, source in pairs(cases) do
            local root = tmp_root .. '/dispatch_alias_' .. ext
            write(root .. '/a.' .. ext, source)
            write(root .. '/.codeoutline.json', xutils.json_pack({ dispatchRules = rules }))
            local opts = { cache_path = root .. '/cache.bin' }
            local idx, G = svc.get(root, opts)
            spec.equal(idx.files['a.' .. ext].dispatch_sites, nil)
            spec.equal(indirect(G, 'run'), 'done', ext)
            idx:save(); svc.forget(root)
            local _, info = svc.callers(root, 'done', opts)
            spec.equal(#info.callers, (ext == 'lua' or ext == 'c') and 1 or 2, ext)
            -- A successful on-disk query must not leave full alias/site data.
            idx = svc.get(root, opts)
            spec.equal(idx.files['a.' .. ext].dispatch_sites, nil)
            write(root .. '/a.' .. ext, source:gsub('cb = done', 'cb = unknown'):gsub('&done', '&unknown'))
            _, info = svc.callers(root, 'done', opts)
            spec.equal(#info.callers, 0, ext)
            svc.forget(root)
        end
    end)
end)

spec.describe('query-time Lua callback collection traversal', function()
    local function build(source)
        return graph.build({ files = { ['callbacks.lua'] = ci.parse('callbacks.lua', source, { ordinary_bindings = true }) } })
    end
    local function callbacks(G, name)
        local Q, found = graph.query(G, { explain = true }), {}
        for i = 1, #Q.out[G.by_name[name][1]], graph.EDGE do
            local edges = Q.out[G.by_name[name][1]]
            if edges[i + 2] == 'automatic:callback-loop' then found[#found + 1] = G.nodes[edges[i]].name end
        end
        table.sort(found); return table.concat(found, ','), Q
    end
    spec.it('connects array initializers through builtin pairs and ipairs in both directions', function()
        for _, iterator in ipairs({ 'pairs', 'ipairs' }) do
            local G = build('local function save() end\nlocal function load() end\nlocal callbacks = { save, load }\n'
                .. 'function run() for _, cb in ' .. iterator .. '(callbacks) do cb() end end')
            local found, Q = callbacks(G, 'run'); spec.equal(found, 'load,save')
            spec.equal(G.nodes[Q.inn[G.by_name.save[1]][1]].name, 'run')
            spec.contains(require('codeoutline.query_report').render(Q.report, G), 'possible callback traversal')
        end
    end)
    spec.it('shares collection aliases and known local callback aliases with table.insert registrations', function()
        local G = build([[
local function first() end
local function second() end
local handler = second
local callbacks = { first }
local active = callbacks
table.insert(active, handler)
function run() for _, cb in ipairs(active) do cb() end end
]])
        spec.equal(callbacks(G, 'run'), 'first,second')
    end)
    spec.it('keeps local collections separate and respects registration order', function()
        local G = build([[
local function save() end
local function other() end
local callbacks = { save }
local unrelated = { other }
function run() for _, cb in pairs(callbacks) do cb() end end
function ordered()
    local callbacks = {}
    table.insert(callbacks, save)
    for _, cb in ipairs(callbacks) do cb() end
end
function before()
    local callbacks = {}
    for _, cb in ipairs(callbacks) do cb() end
    table.insert(callbacks, other)
end
]])
        spec.equal(callbacks(G, 'run'), 'save'); spec.equal(callbacks(G, 'ordered'), 'save'); spec.equal(callbacks(G, 'before'), '')
    end)
    spec.it('blocks collection replacement, escapes, mutations and unknown registrations', function()
        for _, mutation in ipairs({ 'callbacks = {}', 'callbacks[1] = unknown', 'callbacks[key] = save',
            'table.remove(callbacks)', 'unknown(callbacks)', 'setmetatable(callbacks, {})',
            'function export() return callbacks end', 'table.insert(callbacks, unknown)',
            'function setup() table.insert(callbacks, save) end', 'local active = callbacks\nactive = {}',
            'local active = callbacks\nactive[key] = save' }) do
            local G = build('local function save() end\nlocal callbacks = { save }\n' .. mutation
                .. '\nfunction run() for _, cb in ipairs(callbacks) do cb() end end')
            spec.equal(callbacks(G, 'run'), '', mutation)
        end
    end)
    spec.it('blocks iterator/library shadows, environment writes and callback reassignment', function()
        for _, body in ipairs({ 'local ipairs = custom', 'ipairs = custom', 'function ipairs() end',
            '_G.ipairs = custom', "rawset(_G, 'ipairs', custom)", 'local _ENV = custom' }) do
            local G = build('local function save() end\nlocal callbacks = { save }\n' .. body
                .. '\nfunction run() for _, cb in ipairs(callbacks) do cb() end end')
            spec.equal(callbacks(G, 'run'), '', body)
        end
        for _, body in ipairs({ 'local table = custom', 'table.insert = custom', 'local lib = table\nlib.insert = custom',
            "rawset(table, 'insert', custom)" }) do
            local G = build('local function save() end\nlocal callbacks = {}\n' .. body
                .. '\ntable.insert(callbacks, save)\nfunction run() for _, cb in ipairs(callbacks) do cb() end end')
            spec.equal(callbacks(G, 'run'), '', body)
        end
        local G = build('local function save() end\nlocal callbacks = { save }\nfunction cb() end\n'
            .. 'function run() for _, cb in ipairs(callbacks) do cb = unknown; cb() end end')
        local found, Q = callbacks(G, 'run'); spec.equal(found, ''); spec.equal(#Q.out[G.by_name.run[1]], 0)
    end)
    spec.it('does not turn loop value variables into unrelated global calls or infer nested scopes', function()
        local G = build([[
function cb() end
local function save() end
local callbacks = { save }
function unknown(items) for _, cb in ipairs(items) do cb() end end
function conditional() for _, cb in ipairs(callbacks) do if true then cb() end end end
function nested() for _, cb in ipairs(callbacks) do local function later() cb() end end end
function deferred()
    unknown(function()
        local callbacks = { save }
        for _, cb in ipairs(callbacks) do cb() end
    end)
end
]])
        for _, name in ipairs({ 'unknown', 'conditional', 'later' }) do
            local _, Q = callbacks(G, name); spec.equal(#Q.out[G.by_name[name][1]], 0, name)
        end
        spec.equal(callbacks(G, 'deferred'), '')
    end)
    spec.it('rejects nonlocal, keyed, sparse, computed and mixed collection entries', function()
        for _, initial in ipairs({ '{ global }', '{ [1] = save }', '{ save, nil }', '{ go = save }',
            '{ save, factory() }', '{ function() end }' }) do
            local G = build('local function save() end\nfunction global() end\nlocal callbacks = ' .. initial
                .. '\nfunction run() for _, cb in ipairs(callbacks) do cb() end end')
            spec.equal(callbacks(G, 'run'), '', initial)
        end
    end)
    spec.it('keeps callback evidence query-only through cache reload, callers and source edits', function()
        local root = tmp_root .. '/callback_collection'
        local source = 'local function collected_handler() end\nlocal callbacks = {}\ntable.insert(callbacks, collected_handler)\n'
            .. 'function collection_run() for _, cb in ipairs(callbacks) do cb() end end'
        write(root .. '/callbacks.lua', source)
        local options = { cache_path = root .. '/cache.idx', lister = 'walk' }
        local idx, G = svc.get(root, options); idx:save(); svc.forget(root); idx, G = svc.get(root, options)
        spec.equal(callbacks(G, 'collection_run'), 'collected_handler')
        local output, info = explore.run(G, idx, 'collection_run collected_handler', { explain = true })
        spec.truthy(#info.flows > 0); spec.contains(output, 'possible callback traversal'); spec.equal(info.relationships_incomplete, false)
        local _, incoming = require('codeoutline.callers').run(G, idx, 'collected_handler')
        spec.equal(#incoming.callers, 1); spec.equal(incoming.callers[1].name, 'collection_run')
        for _, rec in pairs(idx.files) do spec.nil_value(rec.lua_callback_loops); spec.nil_value(rec.ordinary_bindings) end
        write(root .. '/callbacks.lua', source:gsub('table.insert%(callbacks, collected_handler%)', 'unknown(callbacks)'))
        idx, G = svc.get(root, options); spec.equal(callbacks(G, 'collection_run'), '')
        svc.forget(root)
    end)
    spec.it('reports collection and query limits explicitly', function()
        local module = require('codeoutline.lua_callback_loops'); local previous = module.MAX_TARGETS
        module.MAX_TARGETS = 1
        local ok, err = pcall(function()
            local G = build('local function first() end\nlocal function second() end\nlocal callbacks = { first, second }\n'
                .. 'function run() for _, cb in ipairs(callbacks) do cb() end end')
            local found, Q = callbacks(G, 'run'); spec.equal(found, ''); spec.truthy(Q.incomplete)
        end)
        module.MAX_TARGETS = previous; assert(ok, err)
        previous = module.MAX_FILES; module.MAX_FILES = 0
        ok, err = pcall(function()
            local G = build('local function save() end\nlocal callbacks = { save }\nfunction run() for _, cb in ipairs(callbacks) do cb() end end')
            local found, Q = callbacks(G, 'run'); spec.equal(found, ''); spec.truthy(Q.incomplete)
        end)
        module.MAX_FILES = previous; assert(ok, err)
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
    spec.it('follows lexical Lua registry and registration-target alias chains', function()
        local G = build('registry.lua', [[
local function save() end
local callback = save
local next_callback = callback
local handlers = { go = next_callback }
local active = handlers
local current = active
function run() current['go']() end
]])
        local found, Q = targets(G, 'run')
        spec.equal(found, 'save')
        spec.equal(Q.report.entries[1].registered_at, 'registry.lua:4')
        spec.equal(G.nodes[Q.inn[G.by_name.save[1]][1]].name, 'run')
    end)
    spec.it('shares explicit registrations and invalidation across Lua registry aliases', function()
        for _, write in ipairs({ 'active.go = save', "active['go'] = save", 'handlers.go = save' }) do
            local G = build('registry.lua', 'local function save() end\nlocal handlers = {}\nlocal active = handlers\n'
                .. write .. '\nfunction run() active.go() end')
            spec.equal(targets(G, 'run'), 'save', write)
        end
        for _, write in ipairs({ 'active.go = nil', 'active[key] = save', 'handlers[key] = save',
            'handlers.go = save', 'active.go, other = nil, nil',
            'active.go, other[key] = nil, nil', 'other, active.go = save, nil',
            'function change() active.go = save end' }) do
            local G = build('registry.lua', 'local function save() end\nlocal handlers = { go = save }\nlocal active = handlers\n'
                .. write .. '\nfunction run() active.go(); handlers.go() end')
            spec.equal(targets(G, 'run'), '', write)
        end
    end)
    spec.it('rejects reassigned, shadowed and computed Lua aliases', function()
        for _, body in ipairs({
            'local active = handlers\nactive = other\nfunction run() active.go() end',
            'local active = handlers\nactive, other = other, nil\nfunction run() active.go() end',
            'local active = handlers\nactive, other.go = other, nil\nfunction run() active.go() end',
            'local active = handlers\nother[key], active = nil, other\nfunction run() active.go() end',
            'local active = handlers\nother, active = nil, other\nfunction run() active.go() end',
            'local active = handlers\nfunction active() end\nfunction run() active.go() end',
            'local active = handlers\nhandlers = {}\nfunction run() active.go() end',
            'local active = handlers\nfunction run(active) active.go() end',
            'local active = handlers\nfunction run() for active in iterate() do active.go() end end',
            'local active = handlers\nfunction run() for _, active in iterate() do active.go() end end',
            'local active = handlers\nfunction run() local active = {}; active.go() end',
            'local active = factory(handlers)\nfunction run() active.go() end',
            'local active = handlers or other\nfunction run() active.go() end',
            'local active = handlers\n    .other\nfunction run() active.go() end',
            'local active = handlers\n    [key]\nfunction run() active.go() end',
            'local callback = save\ncallback = other\nlocal active = { go = callback }\nfunction run() active.go() end',
            'local callback = save\nsave = other\nlocal active = { go = callback }\nfunction run() active.go() end',
            'local callback = save\nsave, other = other, nil\nlocal active = { go = callback }\nfunction run() active.go() end',
            'local callback = save\nfunction save() end\nlocal active = { go = callback }\nfunction run() active.go() end',
        }) do
            local G = build('registry.lua', 'local function save() end\nlocal handlers = { go = save }\n' .. body)
            spec.equal(targets(G, 'run'), '', body)
        end
    end)
    spec.it('resolves Lua alias initializers before their own local binding', function()
        local G = build('registry.lua', [[
local function save() end
local handlers = { go = save }
function run()
    local handlers = handlers
    local save = save
    local active = { again = save }
    handlers.go(); active.again()
end
]])
        spec.equal(targets(G, 'run'), 'save,save')
    end)
    spec.it('bounds Lua alias chains and rejects forward or cyclic aliases', function()
        for _, body in ipairs({
            'local a = b\nlocal b = handlers\nfunction run() a.go() end',
            'local a = b\nlocal b = a\nfunction run() a.go() end',
            'local a = handlers\nlocal b = a\nlocal c = b\nlocal d = c\nlocal e = d\nlocal f = e\n'
                .. 'local g = f\nlocal h = g\nlocal i = h\nlocal j = i\nfunction run() j.go() end',
        }) do
            local G = build('registry.lua', 'local function save() end\nlocal handlers = { go = save }\n' .. body)
            spec.equal(targets(G, 'run'), '', body)
        end
    end)
    spec.it('persists compact alias hints and refreshes alias callers after edits', function()
        local root = tmp_root .. '/registry_alias'
        local source = 'local function alias_handler() end\nlocal callback = alias_handler\n'
            .. 'local handlers = { go = callback }\nlocal active = handlers\nfunction alias_run() active.go() end\n'
        write(root .. '/a.lua', source)
        local opts = { cache_path = root .. '/cache.bin' }
        local idx = svc.get(root, opts)
        local hint = idx.files['a.lua'].static_dispatch_candidate
        spec.truthy(hint.targets.alias_handler)
        spec.equal(hint.targets.callback, nil)
        spec.equal(idx.files['a.lua'].static_dispatch, nil)
        local _, info = svc.callers(root, 'alias_handler', opts)
        spec.equal(#info.callers, 1)
        spec.equal(info.callers[1].name, 'alias_run')
        idx:save(); svc.forget(root)
        local output = svc.explore(root, 'alias_run alias_handler', opts)
        spec.contains(output, 'alias_run -> alias_handler')
        _, info = svc.callers(root, 'alias_handler', opts)
        spec.equal(#info.callers, 1)
        write(root .. '/a.lua', source:gsub('local active = handlers', 'local active = {}'))
        _, info = svc.callers(root, 'alias_handler', opts)
        spec.equal(#info.callers, 0)
        svc.forget(root)
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

spec.describe('function values as reference dependencies', function()
    local function edges(G, source, target)
        local Q, hits = graph.query(G), 0
        local src, dst = G.by_name[source][1], G.by_name[target][1]
        local out = Q.out[src]
        for i = 1, #out, graph.EDGE do
            if out[i] == dst and out[i + 2] == 'ref' then hits = hits + 1 end
        end
        return hits, Q, src, dst
    end
    spec.it('resolves imported JS function values, aliases and namespace members in both directions', function()
        local root = tmp_root .. '/function_values_js'
        write(root .. '/lib.ts', 'export function saved() {}')
        write(root .. '/app.ts', "import { saved as cb } from './lib'; import * as api from './lib';\n"
            .. 'const alias = cb; function register() {}\nfunction run() { register(alias); register(api.saved); }\n'
            .. 'function blocked(cb: number) { register(cb); }')
        local opts = { cache_path = root .. '/cache.idx', lister = 'walk' }
        local idx, G = svc.get(root, opts)
        local count, Q, src, dst = edges(G, 'run', 'saved')
        spec.equal(count, 2)
        spec.equal(edges(G, 'blocked', 'saved'), 0)
        local incoming = Q.inn[dst]; local seen = 0
        for i = 1, #incoming, graph.EDGE do if incoming[i] == src and incoming[i + 2] == 'ref' then seen = seen + 1 end end
        spec.equal(seen, 2)
        idx:save(); svc.forget(root)
        idx, G = svc.get(root, opts); spec.truthy(idx.cache_loaded)
        spec.equal(edges(G, 'run', 'saved'), 2)
        write(root .. '/app.ts', "import { saved as cb } from './lib'; function run(cb: number) { register(cb); }")
        _, G = svc.get(root, opts); spec.equal(edges(G, 'run', 'saved'), 0)
        svc.forget(root)
    end)
    spec.it('resolves Python imported callback values and honors parameter shadowing', function()
        local root = tmp_root .. '/function_values_py'
        write(root .. '/lib.py', 'def saved():\n    pass\n')
        write(root .. '/app.py', 'from lib import saved as cb\nimport lib as api\n'
            .. 'def run():\n    register(cb)\n    register(api.saved)\n'
            .. 'def blocked(cb):\n    register(cb)\n')
        local _, G = svc.get(root, { cache_path = root .. '/cache.idx', lister = 'walk' })
        spec.equal(edges(G, 'run', 'saved'), 2)
        spec.equal(edges(G, 'blocked', 'saved'), 0)
        svc.forget(root)
    end)
    spec.it('resolves Java and Kotlin typed method references without guessing unknown receivers', function()
        for _, ext in ipairs({ 'java', 'kt' }) do
            local root = tmp_root .. '/function_values_' .. ext
            local source = ext == 'java' and [[class Store { void saved() {} }
class App { void run(Store s) { register(s::saved); register(Store::saved); }
void blocked(Object s) { register(s::saved); } }]] or [[class Store { fun saved() {} }
class App { fun run(s: Store) { register(s::saved); register(Store::saved) }
fun blocked(s: Any) { register(s::saved) } }]]
            write(root .. '/app.' .. ext, source)
            local _, G = svc.get(root, { cache_path = root .. '/cache.idx', lister = 'walk' })
            spec.equal(edges(G, 'run', 'saved'), 2)
            spec.equal(edges(G, 'blocked', 'saved'), 0)
            svc.forget(root)
        end
    end)
    spec.it('rejects value names that are not callable and unknown or chained member receivers', function()
        local root = tmp_root .. '/function_values_negative'
        write(root .. '/app.ts', 'function saved() {} const ordinary = 42; class Store { saved() {} }\n'
            .. 'function run(unknown: any) { register(ordinary); register(unknown.saved); register(unknown.field.saved); }')
        local _, G = svc.get(root, { cache_path = root .. '/cache.idx', lister = 'walk' })
        local Q = graph.query(G); local out = Q.out[G.by_name.run[1]]
        for i = 1, #out, graph.EDGE do spec.truthy(G.nodes[out[i]].name ~= 'saved' and G.nodes[out[i]].name ~= 'ordinary') end
        svc.forget(root)
    end)
    spec.it('does not borrow outer bindings inside unrepresented anonymous scopes', function()
        for _, item in ipairs({ { 'js', 'function saved() {} function run() { register((saved) => register(saved)); }' },
            { 'py', 'def saved():\n    pass\ndef run():\n    register(lambda saved: register(saved))\n' } }) do
            local root = tmp_root .. '/function_values_anonymous_' .. item[1]
            write(root .. '/app.' .. item[1], item[2])
            local _, G = svc.get(root, { cache_path = root .. '/cache.idx', lister = 'walk' })
            spec.equal(edges(G, 'run', 'saved'), 0)
            svc.forget(root)
        end
    end)
end)

spec.describe('explicit query seed filters', function()
    spec.it('parses quoted values, aliases and unknown prefixes without treating them as filters', function()
        local filters = require('codeoutline.query_filters')
        local parsed = filters.parse('lang:js language:py kind:function path:"Apps/My Code" name:SAVE strange:value run')
        spec.equal(parsed.text, 'strange:value run')
        spec.equal(parsed.languages[1], 'javascript'); spec.equal(parsed.languages[2], 'python')
        spec.truthy(filters.node(parsed, { language = 'python', path = 'apps/my code/a.py' }, { kind = 'function', qualified = 'store.save' }))
        spec.equal(filters.node(parsed, { language = 'lua', path = 'apps/my code/a.lua' }, { kind = 'function', qualified = 'store.save' }), false)
        for _, query in ipairs({ 'lang:unknown run', 'path:', 'name:"unterminated', 'name:"x"tail' }) do
            spec.equal(pcall(explore.validate, query), false, query)
        end
    end)
    spec.it('filters explore seeds and callers targets while retaining Lua to C relationships', function()
        local root = tmp_root .. '/query_filters_foreign'
        write(root .. '/native.c', [[static int native_saved(lua_State *L) { return 0; }
static const luaL_Reg funcs[] = {{"run", native_saved}, {NULL, NULL}};
int luaopen_native(lua_State *L) { luaL_newlib(L, funcs); return 1; }]])
        write(root .. '/use.lua', 'local api = require("native")\nfunction NativeFilterCaller() api.run() end')
        write(root .. '/other.py', 'def NativeFilterCaller():\n    pass\n')
        local opts = { cache_path = root .. '/cache.idx', lister = 'walk', budget = 65536 }
        local idx, G = svc.get(root, opts)
        local output, info = svc.explore(root, 'lang:lua path:use.lua kind:function NativeFilterCaller', opts)
        spec.equal(#info.seeds, 1); spec.equal(G.files[G.node_file[info.seeds[1]]].language, 'lua')
        spec.contains(output, 'native_saved'); spec.contains(output, 'native.c')
        output, info = svc.callers(root, 'lang:c path:native.c native_saved', opts)
        spec.equal(#info.targets, 1)
        local found = false; for _, caller in ipairs(info.callers) do if caller.file == 'use.lua' then found = true end end
        spec.truthy(found, 'a C seed must retain incoming Lua callers')
        output, info = svc.callers(root, 'lang:python native_saved', opts); spec.equal(#info.targets, 0)
        svc.forget(root)
    end)
    spec.it('filters before seed caps and leaves type ancestry outside the selected path visible', function()
        local root = tmp_root .. '/query_filters_types'
        write(root .. '/base.ts', 'export interface Root {}')
        write(root .. '/child.ts', "import {Root} from './base'; export class Child implements Root {}")
        write(root .. '/other.cs', 'class Child {}')
        local opts = { cache_path = root .. '/cache.idx', lister = 'walk' }
        local _, info = svc.type_hierarchy(root, 'lang:ts path:child.ts Child', opts)
        spec.equal(#info.targets, 1); spec.equal(#info.ancestors, 1); spec.equal(info.ancestors[1].file, 'base.ts')
        local _, filtered = svc.explore(root, 'lang:ts name:Child', opts)
        spec.equal(#filtered.seeds, 1)
        svc.forget(root)
    end)
    spec.it('reports bounded filter-only selection and supports quoted file paths', function()
        local root = tmp_root .. '/query_filters_limits'
        local source = {}; for i = 1, 514 do source[i] = 'function item' .. i .. '() {}' end
        write(root .. '/with space/app.ts', table.concat(source, '\n'))
        local opts = { cache_path = root .. '/cache.idx', lister = 'walk' }
        local output, info = svc.explore(root, 'lang:ts path:"with space" kind:function', opts)
        spec.truthy(info.seed_limit_reached); spec.contains(output, '512 matching candidates')
        spec.equal(pcall(svc.callers, root, 'lang:ts', opts), false)
        spec.equal(pcall(svc.type_hierarchy, root, 'lang:ts', opts), false)
        svc.forget(root)
    end)
end)

spec.describe('query-time C and C++ macro visibility', function()
    spec.it('extracts the same directive summaries without a full syntax or binding parse', function()
        local macros = require('codeoutline.cpp_macros')
        local cases = {
            { 'summary.c', '\239\187\191#ifndef HEADER\n#define HEADER\n/* #define FAKE(x) 0 */\n'
                .. '#if FEATURE\n#define LIVE(x) helper(x)\n#else\n#undef LIVE\n#endif\n#include "dep.h"\n#endif\n' },
            { 'summary.cpp', 'const char* value = R"tag(\n#define FAKE(x) 0\n)tag";\n'
                .. '#define REAL(x) \\\n helper(x)\n#pragma once\n#if 0\n#define HIDDEN(x) 1\n#endif\n' },
        }
        for _, example in ipairs(cases) do
            local expected = ci.parse(example[1], example[2], { ordinary_bindings = true }).cpp_macros
            local rec = ci.parse(example[1], example[2], { ranges = false })
            local original, tokens = ci.parse, ci.parse_tokens
            ci.parse, ci.parse_tokens = function() error('unexpected syntax parse') end, function() error('unexpected syntax parse') end
            local ok, actual = pcall(macros.summary, rec, example[2])
            ci.parse, ci.parse_tokens = original, tokens
            if not ok then error(actual, 0) end
            spec.equal(#actual, #expected); spec.equal(actual.guard, expected.guard)
            spec.equal(actual.incomplete, expected.incomplete)
            for i, event in ipairs(expected) do
                for key, value in pairs(event) do spec.equal(actual[i][key], value) end
                for key, value in pairs(actual[i]) do spec.equal(event[key], value) end
            end
        end
    end)
    local function kinds(G, source, wanted)
        local Q, result = graph.query(G), {}
        for _, src in ipairs(G.by_name[source] or {}) do
            local out = Q.out[src]
            for i = 1, #out, graph.EDGE do
                local n = G.nodes[out[i]]
                if n.name == wanted then result[#result + 1] = n.kind .. '@' .. G.files[G.node_file[out[i]]].path end
            end
        end
        table.sort(result); return table.concat(result, ','), Q
    end
    spec.it('honors define and undef order and preserves calls inside macro bodies', function()
        local root = tmp_root .. '/macros_order'
        write(root .. '/a.c', [[void TRACE(int x); void real(int x);
void before(void) { TRACE(1); }
#define TRACE(x) real(x)
void during(void) { TRACE(2); }
#undef TRACE
void after(void) { TRACE(3); }
]])
        local opts = { cache_path = root .. '/cache.idx', lister = 'walk' }
        local idx, G = svc.get(root, opts)
        spec.equal(kinds(G, 'before', 'TRACE'), 'prototype@a.c')
        spec.equal(kinds(G, 'during', 'TRACE'), 'macro@a.c')
        spec.equal(kinds(G, 'after', 'TRACE'), 'prototype@a.c')
        spec.equal(kinds(G, 'TRACE', 'real'), 'prototype@a.c')
        local Q = graph.query(G); local macro
        for _, id in ipairs(G.by_name.TRACE) do if G.nodes[id].kind == 'macro' then macro = id end end
        spec.truthy(macro); spec.equal(#Q.inn[macro], graph.EDGE)
        spec.equal(G.nodes[Q.inn[macro][1]].name, 'during')
        spec.nil_value(idx.files['a.c'].cpp_macros)
        idx:save(); svc.forget(root); _, G = svc.get(root, opts)
        spec.equal(kinds(G, 'during', 'TRACE'), 'macro@a.c')
        write(root .. '/a.c', 'void TRACE(int x);\nvoid during(void) { TRACE(2); }\n')
        local ok, err = pcall(kinds, G, 'during', 'TRACE')
        spec.equal(ok, false); spec.contains(tostring(err), 'source changed during query')
        _, G = svc.get(root, opts); spec.equal(kinds(G, 'during', 'TRACE'), 'prototype@a.c')
        svc.forget(root)
    end)
    spec.it('walks includes in translation-unit order and honors guards and pragma once', function()
        for _, guard in ipairs({ 'guard', 'once' }) do
            local root = tmp_root .. '/macros_include_' .. guard
            local head = guard == 'guard' and '#ifndef API_H\n#define API_H\n' or '#pragma once\n'
            write(root .. '/api.h', head .. '#define TRACE(x) real(x)\n' .. (guard == 'guard' and '#endif\n' or ''))
            write(root .. '/a.cpp', [[void TRACE(int x); void real(int x);
#include "api.h"
void first() { TRACE(1); }
#undef TRACE
#include "api.h"
void second() { TRACE(2); }
]])
            local _, G = svc.get(root, { cache_path = root .. '/cache.idx', lister = 'walk' })
            spec.equal(kinds(G, 'first', 'TRACE'), 'macro@api.h')
            spec.equal(kinds(G, 'second', 'TRACE'), 'prototype@a.cpp')
            svc.forget(root)
        end
    end)
    spec.it('evaluates finite conditions and blocks uncertain macro names without same-name guesses', function()
        local root = tmp_root .. '/macros_conditions'
        write(root .. '/a.c', [[void TRACE(int x);
#undef ENABLED
#if defined(ENABLED)
#define TRACE(x) wrong(x)
#elif !defined(ENABLED) && (1 || UNKNOWN_FLAG)
#define TRACE(x) right(x)
#endif
void certain(void) { TRACE(1); }
#if UNKNOWN_FLAG
#undef TRACE
#endif
void uncertain(void) { TRACE(2); }
]])
        local _, G = svc.get(root, { cache_path = root .. '/cache.idx', lister = 'walk' })
        spec.equal(kinds(G, 'certain', 'TRACE'), 'macro@a.c')
        spec.equal(kinds(G, 'uncertain', 'TRACE'), '')
        svc.forget(root)
    end)
    spec.it('does not make unrelated macros visible or read directives in comments and strings', function()
        local root = tmp_root .. '/macros_unrelated'
        write(root .. '/unrelated.h', '#define TRACE(x) other(x)\n')
        write(root .. '/a.cpp', [[void TRACE(int x);
/*
#define TRACE(x) wrong(x)
*/
const char *s = R"raw(
#define TRACE(x) wrong(x)
)raw";
void run() { TRACE(1); }
]])
        local _, G = svc.get(root, { cache_path = root .. '/cache.idx', lister = 'walk' })
        spec.equal(kinds(G, 'run', 'TRACE'), 'prototype@a.cpp')
        svc.forget(root)
    end)
    spec.it('reports source and event budgets rather than falling back to unproven calls', function()
        local root = tmp_root .. '/macros_limits'
        write(root .. '/a.c', '#define TRACE(x) real(x)\nvoid run(void) { TRACE(1); }\n')
        local _, G = svc.get(root, { cache_path = root .. '/cache.idx', lister = 'walk' })
        local macros = require('codeoutline.cpp_macros'); local before = macros.MAX_EVENTS; macros.MAX_EVENTS = 0
        local ok, value, Q = pcall(kinds, G, 'run', 'TRACE'); macros.MAX_EVENTS = before
        spec.truthy(ok); spec.equal(value, ''); spec.truthy(Q.incomplete)
        svc.forget(root)
    end)
    spec.it('does not start raw strings at markers inside comments', function()
        local root = tmp_root .. '/macros_raw_comment'
        write(root .. '/a.cpp', [[void TRACE(int x);
/* R"tag( */
#define TRACE(x) real(x)
/* )tag" */
void run() { TRACE(1); }
]])
        local _, G = svc.get(root, { cache_path = root .. '/cache.idx', lister = 'walk' })
        spec.equal(kinds(G, 'run', 'TRACE'), 'macro@a.cpp')
        svc.forget(root)
    end)
    spec.it('keeps forward macro-body dependencies rather than evaluating them at definition time', function()
        local root = tmp_root .. '/macros_body_forward'
        write(root .. '/a.c', '#define OUTER(x) INNER(x)\n#define INNER(x) real(x)\nvoid run(void) { OUTER(1); }\n')
        local _, G = svc.get(root, { cache_path = root .. '/cache.idx', lister = 'walk' })
        spec.equal(kinds(G, 'run', 'OUTER'), 'macro@a.c')
        spec.equal(kinds(G, 'OUTER', 'INNER'), 'macro@a.c')
        svc.forget(root)
    end)
    spec.it('does not assume the queried macro is undefined when a source condition reads it', function()
        local root = tmp_root .. '/macros_self_condition'
        write(root .. '/a.c', 'void TRACE(int x);\n#ifdef TRACE\n#define TRACE(x) real(x)\n#endif\nvoid run(void) { TRACE(1); }\n')
        local _, G = svc.get(root, { cache_path = root .. '/cache.idx', lister = 'walk' })
        spec.equal(kinds(G, 'run', 'TRACE'), '')
        svc.forget(root)
    end)
    spec.it('masks standard C++ raw string prefixes in directive evidence', function()
        for _, prefix in ipairs({ 'R', 'LR', 'uR', 'UR', 'u8R' }) do
            local root = tmp_root .. '/macros_raw_' .. prefix
            write(root .. '/unrelated.h', '#define TRACE(x) other(x)\n')
            write(root .. '/a.cpp', 'void TRACE(int x);\nconst char *s = ' .. prefix .. '"tag(\n#define TRACE(x) wrong(x)\n)tag";\nvoid run() { TRACE(1); }\n')
            local _, G = svc.get(root, { cache_path = root .. '/cache.idx', lister = 'walk' })
            spec.equal(kinds(G, 'run', 'TRACE'), 'prototype@a.cpp', prefix)
            svc.forget(root)
        end
    end)
end)

spec.describe('changed file impact', function()
    local affected = require('codeoutline.affected')
    local function project(sources)
        local records = {}
        for path, source in pairs(sources) do records[path] = ci.parse(path, source, { foreign = true }) end
        return graph.build({ files = records }), { root = 'C:/impact', query_source = function(_, path) return sources[path], false end }
    end
    spec.it('batches file seeds, merges shared callers, keeps shortest paths and identifies changed tests', function()
        local G, idx = project({
            ['a.lua'] = 'function alpha() end', ['b.lua'] = 'function beta() end',
            ['run.lua'] = 'function run() alpha() beta() end',
            ['tests/run_spec.lua'] = 'function check() run() end', ['tests/empty.lua'] = '-- empty',
        })
        local output, info = affected.run(G, idx, { './b.lua', 'a.lua', 'a.lua', 'tests/empty.lua' })
        spec.equal(#info.changed_files, 3); spec.equal(#info.targets, 2)
        spec.equal(#info.callers, 2); spec.equal(info.callers[1].name, 'run')
        spec.equal(info.callers[2].path[1].name, 'check')
        spec.equal(#info.callers[2].path, 3)
        spec.equal(info.query_stats.incoming_scans, 3)
        spec.equal(table.concat(info.tests, ','), 'tests/empty.lua,tests/run_spec.lua')
        spec.equal(table.concat(info.files, ','), 'a.lua,b.lua,run.lua,tests/empty.lua,tests/run_spec.lua')
        spec.truthy(info.incomplete); spec.contains(output, 'No indexed symbols: tests/empty.lua')
        spec.nil_value(G.inn); spec.nil_value(G.out)
    end)
    spec.it('reports missing files, bounded seeds, depth, nodes and output without inventing history', function()
        local G, idx = project({ ['a.lua'] = 'function a() end\nfunction b() end',
            ['b.lua'] = 'function c() a() end\nfunction d() c() end\nfunction e() d() end' })
        local output, info = affected.run(G, idx, { 'a.lua', 'old.lua' }, { max_nodes = 1 })
        spec.truthy(info.seed_limit_reached); spec.truthy(info.node_limit_reached); spec.truthy(info.incomplete)
        spec.equal(info.unresolved_files[1], 'old.lua'); spec.contains(output, 'deleted, renamed')
        _, info = affected.run(G, idx, { 'a.lua' }, { depth = 1 })
        spec.truthy(info.depth_limit_reached)
        output, info = affected.run(G, idx, { 'a.lua' }, { budget = 256 })
        spec.truthy(info.truncated); spec.truthy(#output <= 256)
        _, info = affected.run(G, idx, { 'missing.lua' })
        spec.equal(info.query_stats.incoming_scans, 0); spec.truthy(info.incomplete)
    end)
    spec.it('normalizes exact paths, rejects traversal and malformed file arrays', function()
        local G, idx = project({ ['dir/a.lua'] = 'function a() end' })
        local _, info = affected.run(G, idx, { 'dir/../dir/a.lua', 'C:/impact/dir/a.lua', 'dir\\a.lua' })
        spec.equal(#info.changed_files, 1)
        for _, files in ipairs({ {}, { '../a.lua' }, { '/outside/a.lua' }, { 'a\0.lua' }, { 'a\nb' }, { false }, { file = 'a.lua' } }) do
            spec.equal(pcall(affected.run, G, idx, files), false)
        end
        spec.equal(pcall(affected.run, G, idx, { 'dir/a.lua' }, { depth = 0 }), false)
    end)
    spec.it('returns explicit time limits and restores cancellation callbacks without swallowing cancellation', function()
        local G, idx = project({ ['a.lua'] = 'function a() end', ['b.lua'] = 'function b() a() end' })
        local ctrl = require('codeoutline.control')
        local previous, limit = ctrl.callback, affected.TIME_LIMIT_MS
        local calls = 0
        local callback = function() calls = calls + 1 end
        ctrl.callback, affected.TIME_LIMIT_MS = callback, 0
        local ok, err = pcall(function()
            local output, info = affected.run(G, idx, { 'a.lua' })
            spec.truthy(info.time_limit_reached); spec.truthy(info.incomplete)
            spec.contains(output, 'Time limit reached'); spec.equal(ctrl.callback, callback); spec.truthy(calls > 0)
            ctrl.callback = function() error(ctrl.cancelled(), 0) end
            local success, failure = pcall(affected.run, G, idx, { 'a.lua' })
            spec.equal(success, false); spec.truthy(ctrl.is_interrupted(failure))
        end)
        ctrl.callback, affected.TIME_LIMIT_MS = previous, limit
        assert(ok, err)
    end)
    spec.it('retains renamed Lua to native dependencies when the changed file is C', function()
        local root = tmp_root .. '/affected_native'
        write(root .. '/native.c', 'static int native_save(lua_State *L) { return 0; }\nstatic const luaL_Reg api[] = {{"save", native_save}, {NULL, NULL}};\nint luaopen_store(lua_State *L) { luaL_newlib(L, api); return 1; }')
        write(root .. '/run.lua', 'local store = require("store")\nfunction run() store.save() end')
        local _, info = svc.affected(root, { 'native.c' }, { cache_path = root .. '/cache.idx', lister = 'walk' })
        local found = false
        for _, caller in ipairs(info.callers) do if caller.name == 'run' then found = true end end
        spec.truthy(found); svc.forget(root)
    end)
    spec.it('keeps verified scan-prefix paths on timeout without publishing partial incoming lists', function()
        local G, idx = project({ ['a.lua'] = 'function a() end', ['b.lua'] = 'function b() a() end' })
        local query, now, clock = graph.query, xtimer.now_ms, 0
        xtimer.now_ms = function() return clock end
        local Q
        graph.query = function(symbols, opts)
            Q = query(symbols, opts)
            Q.load_incoming = function(_, ids, progress)
                local incoming = { [ids[1]] = { G.by_name.b[1], 1, 'call' } }
                progress(incoming)
                clock = 1000; require('codeoutline.control').check()
            end
            return Q
        end
        local ok, err = pcall(function()
            local output, info = affected.run(G, idx, { 'a.lua' })
            spec.truthy(info.time_limit_reached); spec.equal(#info.callers, 1)
            spec.contains(output, 'Depth 1: b'); spec.nil_value(rawget(Q.inn, G.by_name.a[1]))
        end)
        graph.query, xtimer.now_ms = query, now; assert(ok, err)
    end)
    spec.it('keeps C header statics, C to C++ callers and JavaScript to TypeScript callers', function()
        local G, idx = project({
            ['a.h'] = 'static inline void kept() {}', ['b.cpp'] = '#include "a.h"\nvoid caller() { kept(); }',
            ['a.c'] = 'void common_c() {}', ['c.cpp'] = 'void cpp_caller() { common_c(); }',
            ['leaf.ts'] = 'export function ts_leaf() {}', ['use.js'] = 'import { ts_leaf } from "./leaf"; function js_caller() { ts_leaf(); }',
        })
        for _, pair in ipairs({ { 'a.h', 'caller' }, { 'a.c', 'cpp_caller' }, { 'leaf.ts', 'js_caller' } }) do
            local _, info = affected.run(G, idx, { pair[1] })
            local found = false
            for _, caller in ipairs(info.callers) do if caller.name == pair[2] then found = true end end
            spec.truthy(found, pair[1])
        end
    end)
    spec.it('retries both file and symbol queries when source repair renumbers nodes', function()
        local G, idx = project({ ['a.lua'] = 'function a() end', ['b.lua'] = 'function b() a() end' })
        idx.query_source = function() return 'decoded source', true end
        local output, info = affected.run(G, idx, { 'a.lua' })
        spec.nil_value(output); spec.truthy(info.encoding_retry)
        output, info = require('codeoutline.callers').run(G, idx, 'a')
        spec.nil_value(output); spec.truthy(info.encoding_retry)
    end)
    spec.it('refreshes service queries after reload, edits, renames and removal without serializing impact state', function()
        local root = tmp_root .. '/affected'
        write(root .. '/a.lua', 'function leaf() end')
        write(root .. '/b.lua', 'function outer() leaf() end')
        local opts = { cache_path = root .. '/cache.idx', lister = 'walk' }
        local _, info = svc.affected(root, { 'a.lua' }, opts)
        spec.equal(#info.callers, 1)
        svc.forget(root)
        _, info = svc.affected(root, { 'a.lua' }, opts); spec.equal(#info.callers, 1)
        write(root .. '/b.lua', 'function outer() end')
        _, info = svc.affected(root, { 'a.lua' }, opts); spec.equal(#info.callers, 0)
        assert(os.rename(root .. '/a.lua', root .. '/renamed.lua'))
        _, info = svc.affected(root, { 'a.lua', 'renamed.lua' }, opts)
        spec.equal(info.unresolved_files[1], 'a.lua'); spec.equal(info.changed_files[1], 'renamed.lua')
        assert(os.remove(root .. '/renamed.lua'))
        _, info = svc.affected(root, { 'renamed.lua' }, opts); spec.equal(#info.targets, 0)
        local idx, G = svc.resident(root)
        spec.nil_value(G.inn); for _, rec in pairs(idx.files) do spec.nil_value(rec.affected) end
        svc.forget(root)
    end)
end)

spec.describe('project search ranking', function()
    local ranking = require('codeoutline.search_ranking')
    local function config(root, value) write(root .. '/.codeoutline.json', value) end
    local function files(root)
        for i = 1, 3 do write(root .. '/generated/' .. i .. '.lua', 'function ranked_save() return ' .. i .. ' end') end
        write(root .. '/src/main.lua', 'function ranked_save() return 99 end')
        return { cache_path = root .. '/cache.idx', lister = 'walk' }
    end
    local function first(root, opts, query)
        local output, info = svc.explore(root, query or 'ranked_save', opts)
        local _, G = svc.resident(root)
        return G.files[G.node_file[info.seeds[1]]].path, info, output
    end
    spec.it('prefers business definitions over configured directories without changing the index', function()
        local root = tmp_root .. '/search_ranking'; local opts = files(root)
        local path = first(root, opts); spec.equal(path, 'generated/1.lua')
        local idx, G = svc.resident(root); local generation = idx.generation
        config(root, '{"deprioritize":["generated/"]}')
        local info, output; path, info, output = first(root, opts)
        spec.equal(path, 'src/main.lua'); spec.equal(#info.seeds, 3)
        spec.equal(info.query_stats.ranking.rules, 1); spec.equal(info.query_stats.ranking.matched_files, 3)
        spec.equal(info.refresh.parsed, 0); spec.equal(idx.generation, generation)
        spec.equal(G.node_count, 4); spec.nil_value(G.search_ranking)
        for _, rec in pairs(idx.files) do spec.nil_value(rec.deprioritize); spec.nil_value(rec.search_ranking) end
        config(root, '{"deprioritize":["src/"]}')
        spec.equal(first(root, opts), 'generated/1.lua')
        svc.forget(root)
        spec.equal(first(root, opts), 'generated/1.lua'); svc.forget(root)
    end)
    spec.it('matches literal root-relative directory boundaries and normalizes redundant separators', function()
        local root = tmp_root .. '/ranking_prefixes'
        config(root, '{"deprioritize":["./generated\\\\","generated/./","space (v1)/","gen[1]/"]}')
        local policy = ranking.policy(root)
        spec.equal(policy.stats.rules, 3)
        for _, path in ipairs({ 'generated/a.lua', 'generated/sub/b.lua', 'space (v1)/a.lua', 'gen[1]/x.lua' }) do
            spec.equal(policy.penalty(path), 6, path)
            spec.equal(policy.penalty(path), 6, 'cached penalty must not stack')
        end
        for _, path in ipairs({ 'generated_extra/a.lua', 'nested/generated/a.lua', 'space v1/a.lua', 'gen1/x.lua', 'Generated/a.lua' }) do
            spec.equal(policy.penalty(path), 0, path)
        end
        spec.equal(policy.penalty('generated/a.lua', true), 0)
    end)
    spec.it('keeps legacy defaults when omitted and lets an explicit empty array disable directory penalties', function()
        local root = tmp_root .. '/ranking_defaults'
        write(root .. '/vendor/a.lua', 'function ranked_save() end')
        write(root .. '/z_app.lua', 'function ranked_save() end')
        local opts = { cache_path = root .. '/cache.idx', lister = 'walk' }
        spec.equal(first(root, opts), 'z_app.lua')
        config(root, '{"deprioritize":[]}')
        local path, info = first(root, opts)
        spec.equal(path, 'vendor/a.lua'); spec.equal(info.query_stats.ranking.rules, 0)
        config(root, '{}'); spec.equal(first(root, opts), 'z_app.lua'); svc.forget(root)
    end)
    spec.it('retains explicit file, qualified-symbol and path-filter requests in deprioritized directories', function()
        local root = tmp_root .. '/ranking_explicit'; local opts = files(root)
        write(root .. '/generated/special.lua', 'function Generated.ranked_special() return 7 end')
        config(root, '{"deprioritize":["generated/"]}')
        local path, info, output = first(root, opts, 'Generated.ranked_special')
        spec.equal(path, 'generated/special.lua'); spec.equal(info.query_stats.ranking.matched_files, 0)
        output, info = svc.explore(root, 'generated/special.lua', opts)
        spec.contains(output, 'Generated.ranked_special')
        path, info = first(root, opts, 'path:generated/ ranked_save')
        spec.equal(path, 'generated/1.lua'); spec.equal(#info.seeds, 3); svc.forget(root)
    end)
    spec.it('fills filter-only candidate windows from preferred files before generated matches', function()
        local root = tmp_root .. '/ranking_window'
        local lines = {}; for i = 1, 513 do lines[#lines + 1] = 'function generated_' .. i .. '() end' end
        write(root .. '/a_generated/all.lua', table.concat(lines, '\n'))
        write(root .. '/z_app.lua', 'function preferred_business() end')
        config(root, '{"deprioritize":["a_generated/"]}')
        local opts = { cache_path = root .. '/cache.idx', lister = 'walk', budget = 65536 }
        local path, info = first(root, opts, 'lang:lua kind:function')
        spec.equal(path, 'z_app.lua'); spec.truthy(info.seed_limit_reached)
        local _, G = svc.resident(root); spec.equal(G.node_count, 514); svc.forget(root)
    end)
    spec.it('isolates policies between projects and refreshes paths after rename or deletion', function()
        local a, b = tmp_root .. '/ranking_a', tmp_root .. '/ranking_b'
        local oa, ob = files(a), files(b)
        config(a, '{"deprioritize":["generated/"]}'); config(b, '{"deprioritize":["src/"]}')
        spec.equal(first(a, oa), 'src/main.lua'); spec.equal(first(b, ob), 'generated/1.lua')
        spec.equal(first(a, oa), 'src/main.lua')
        assert(os.rename(a .. '/src/main.lua', a .. '/preferred.lua'))
        spec.equal(first(a, oa), 'preferred.lua')
        assert(os.remove(a .. '/preferred.lua')); spec.equal(first(a, oa), 'generated/1.lua')
        svc.forget(a); svc.forget(b)
    end)
    spec.it('preserves Lua to C expansion, incoming Lua callers and file impact', function()
        local root = tmp_root .. '/ranking_native'
        write(root .. '/native/store.c', 'static int native_saved(lua_State *L) { return 0; }\nstatic const luaL_Reg api[] = {{"save", native_saved}, {NULL, NULL}};\nint luaopen_store(lua_State *L) { luaL_newlib(L, api); return 1; }')
        write(root .. '/app.lua', 'local store = require("store")\nfunction RankedNativeCaller() store.save() end')
        local opts = { cache_path = root .. '/cache.idx', lister = 'walk' }
        local before_callers = svc.callers(root, 'native_saved', opts)
        local before_impact = svc.affected(root, { 'native/store.c' }, opts)
        config(root, '{"deprioritize":["native/"]}')
        local output, info = svc.explore(root, 'RankedNativeCaller', opts)
        spec.contains(output, 'native_saved'); spec.contains(output, 'native/store.c')
        output, info = svc.callers(root, 'native_saved', opts)
        spec.equal(output, before_callers); spec.contains(output, 'RankedNativeCaller (app.lua:')
        output, info = svc.affected(root, { 'native/store.c' }, opts)
        spec.equal(output, before_impact)
        local found = false
        for _, caller in ipairs(info.callers) do if caller.name == 'RankedNativeCaller' and caller.file == 'app.lua' then found = true end end
        spec.truthy(found); svc.forget(root)
    end)
    spec.it('rejects invalid policy shapes, traversal, globs and excessive rules without changing resident symbols', function()
        local root = tmp_root .. '/ranking_invalid'; local opts = files(root)
        local _, G = svc.get(root, opts)
        for _, value in ipairs({ 'false', '"generated/"', '{"path":"generated/"}', '[false]', '[1]', '[""]',
            '["../generated/"]', '["a/../b/"]', '["/generated/"]', '["C:/generated/"]', '["**/generated/**"]',
            '["."]', '["a\\u0000b/"]', '["a\\nb/"]', '["' .. string.rep('a', 1025) .. '"]' }) do
            config(root, '{"deprioritize":' .. value .. '}')
            local ok, err = pcall(svc.explore, root, 'ranked_save', opts)
            spec.equal(ok, false, value); spec.contains(tostring(err), 'deprioritize')
            spec.equal(G.node_count, 4)
        end
        local values = {}; for i = 1, 33 do values[i] = '"p' .. i .. '/"' end
        config(root, '{"deprioritize":[' .. table.concat(values, ',') .. ']}')
        spec.equal(pcall(svc.explore, root, 'ranked_save', opts), false)
        config(root, '{}'); spec.equal(first(root, opts), 'generated/1.lua'); svc.forget(root)
    end)
end)

spec.describe('query-owned Go method sets and implicit implementations', function()
    local methods = require('codeoutline.go_methods')
    local function build(files)
        local records = {}
        for path, source in pairs(files) do records[path] = ci.parse(path, source, { ordinary_bindings = true }) end
        local G = graph.build({ files = records })
        local ctx = {}; ctx.ordinary = require('codeoutline.ordinary_bindings').context(G, ctx)
        return G, methods.context(G, ctx)
    end
    local function type_id(G, name, file)
        for _, id in ipairs(G.by_name[name] or {}) do
            if G.nodes[id].kind ~= 'field' and (not file or G.files[G.node_file[id]].path == file) then return id end
        end
    end
    local function edge_names(G, id, kind, incoming)
        local Q, names = graph.query(G, { explain = true }), {}
        if incoming then Q:load_incoming({ id }) end
        local edges = incoming and Q.inn[id] or Q.out[id]
        for i = 1, #edges, graph.EDGE do
            if not kind or edges[i + 2] == kind then names[#names + 1] = G.nodes[edges[i]].qualified end
        end
        table.sort(names); return table.concat(names, ','), Q
    end
    spec.it('distinguishes value and pointer method sets while promoting pointer embeddings', function()
        local G, C = build({ ['p/a.go'] = [[package p
type Reader interface { Read([]byte) (int, error) }
type Base struct {}
type Value struct { Base }
type Pointer struct { *Base }
func (b *Base) Read(data []byte) (n int, err error) { return 0, nil }
func Use(r Reader, b Base, v Value, p Pointer) { r.Read(nil); b.Read(nil); v.Read(nil); p.Read(nil) }
]] })
        local reader, base = type_id(G, 'Reader'), type_id(G, 'Base')
        spec.equal(C.satisfies(base, reader, false), false); spec.truthy(C.satisfies(base, reader, true))
        spec.equal(C.satisfies(type_id(G, 'Value'), reader, false), false)
        spec.truthy(C.satisfies(type_id(G, 'Value'), reader, true))
        spec.truthy(C.satisfies(type_id(G, 'Pointer'), reader, false))
        spec.equal(edge_names(G, G.by_qualified['Reader.Read'][1], 'implementation'), 'Base.Read')
        spec.equal(edge_names(G, type_id(G, 'Use')), 'Base.Read,Base.Read,Base.Read,Reader.Read')
        spec.equal(edge_names(G, G.by_qualified['Base.Read'][1], 'implementation', true), 'Reader.Read')
    end)
    spec.it('requires exact complete signatures including results, grouped names and variadics', function()
        local G, C = build({ ['a.go'] = [[package p
type I interface { Copy(a, b []byte) (n int, err error); Send(...string) }
type Good struct {}
func (Good) Copy(first []uint8, second []byte) (int, error) { return 0, nil }
func (Good) Send(items ...string) {}
type WrongResult struct {}
func (WrongResult) Copy(a, b []byte) (string, error) { return "", nil }
func (WrongResult) Send(...string) {}
type WrongVariadic struct {}
func (WrongVariadic) Copy([]byte, []byte) (int, error) { return 0, nil }
func (WrongVariadic) Send([]string) {}
type Missing struct {}
func (Missing) Copy([]byte, []byte) (int, error) { return 0, nil }
]] })
        local contract = type_id(G, 'I')
        spec.truthy(C.satisfies(type_id(G, 'Good'), contract, false))
        for _, name in ipairs({ 'WrongResult', 'WrongVariadic', 'Missing' }) do spec.equal(C.satisfies(type_id(G, name), contract, true), false, name) end
        spec.equal(edge_names(G, G.by_qualified['I.Copy'][1], 'implementation'), 'Good.Copy')
    end)
    spec.it('rejects same-depth promotions and fields while honoring shallower declarations', function()
        local G, C = build({ ['a.go'] = [[package p
type I interface { Run() }
type A struct {}
func (A) Run() {}
type B struct {}
func (B) Run() {}
type Diamond struct { A; B }
type Hidden struct { A; Run int }
type Nested struct { A }
type Shallow struct { B; Nested }
type Override struct { A; B }
func (Override) Run() {}
]] })
        local contract = type_id(G, 'I')
        spec.equal(C.satisfies(type_id(G, 'Diamond'), contract, false), false)
        spec.equal(C.satisfies(type_id(G, 'Hidden'), contract, false), false)
        spec.truthy(C.satisfies(type_id(G, 'Shallow'), contract, false))
        spec.truthy(C.satisfies(type_id(G, 'Override'), contract, false))
        local set = C.method_set(type_id(G, 'Shallow'), false)
        spec.equal(G.nodes[set.entries.Run.ids[1]].qualified, 'B.Run')
    end)
    spec.it('merges embedded interface methods and rejects conflicting signatures at any depth', function()
        local G, C = build({ ['a.go'] = [[package p
type I interface { Read() int }
type J interface { Read() string }
type Deep interface { J }
type Both interface { I; Read() int }
type Conflict interface { I; Deep }
type Box struct {}
func (Box) Read() int { return 0 }
type ViaInterface struct { I }
type BadPointer struct { *I }
]] })
        spec.truthy(C.satisfies(type_id(G, 'Box'), type_id(G, 'Both'), false))
        spec.equal(C.satisfies(type_id(G, 'Box'), type_id(G, 'Conflict'), false), false)
        spec.truthy(C.satisfies(type_id(G, 'ViaInterface'), type_id(G, 'I'), false))
        spec.equal(C.satisfies(type_id(G, 'BadPointer'), type_id(G, 'I'), false), false)
        spec.equal(edge_names(G, G.by_qualified['I.Read'][1], 'implementation'), 'Box.Read')
    end)
    spec.it('keeps private methods and named parameter types scoped to their Go package', function()
        local G, C = build({ ['one/a.go'] = [[package same
type Item struct {}
type I interface { hidden(Item) }
type Local struct {}
func (Local) hidden(Item) {}
]], ['two/a.go'] = [[package same
type Item struct {}
type Other struct {}
func (Other) hidden(Item) {}
]] })
        local contract = type_id(G, 'I')
        spec.truthy(C.satisfies(type_id(G, 'Local'), contract, false))
        spec.equal(C.satisfies(type_id(G, 'Other'), contract, false), false)
        spec.equal(edge_names(G, G.by_qualified['I.hidden'][1], 'implementation'), 'Local.hidden')
    end)
    spec.it('resolves cross-file methods, aliases and composite signature types conservatively', function()
        local G, C = build({ ['p/types.go'] = [[package p
type Bytes = []byte
type Number int
type I interface { Pack(map[string]Bytes, [3]int, chan<- int) Number }
type Box struct {}
]], ['p/methods.go'] = [[package p
func (Box) Pack(m map[string][]uint8, a [3]int, c chan<- int) Number { return 0 }
]], ['p/wrong.go'] = [[package p
type Wrong struct {}
func (Wrong) Pack(map[string][]byte, [4]int, <-chan int) int { return 0 }
]] })
        spec.truthy(C.satisfies(type_id(G, 'Box'), type_id(G, 'I'), false))
        spec.equal(C.satisfies(type_id(G, 'Wrong'), type_id(G, 'I'), false), false)
        spec.equal(edge_names(G, G.by_qualified['I.Pack'][1], 'implementation'), 'Box.Pack')
    end)
    spec.it('binds declarations and literals while preserving lexical and local-type barriers', function()
        local G = build({ ['a.go'] = [[package p
type Good struct {}
func (Good) Run() {}
type Other struct {}
func (Other) Run() {}
func Known() { var v Good; v.Run(); p := &Good{}; p.Run(); q := new(Good); q.Run() }
func Scoped(v Good) { { var v Other; v.Run() }; v.Run(); func(v Other) { v.Run() }(Other{}) }
func Block(v Good) { { v := factory(); v.Run() }; { type Good Other; var v Good; v.Run() } }
func Generic[Good any](v Good) { v.Run() }
func Unknown() { unknown.Run(); factory().Run(); items[0].Run() }
]] })
        spec.equal(edge_names(G, type_id(G, 'Known')), 'Good.Run,Good.Run,Good.Run')
        spec.equal(edge_names(G, type_id(G, 'Scoped')), 'Good.Run,Other.Run,Other.Run')
        spec.equal(edge_names(G, type_id(G, 'Block')), '')
        spec.equal(edge_names(G, type_id(G, 'Generic')), '')
        spec.equal(edge_names(G, type_id(G, 'Unknown')), '')
    end)
    spec.it('skips empty, constrained, generic and recursive interface matches', function()
        local G, C = build({ ['a.go'] = [[package p
type Empty interface {}
type Constraint interface { ~int; Run() }
type Generic[T any] interface { Run(T) }
type Cycle interface { Cycle; Run() }
type Box struct {}
func (Box) Run() {}
]] })
        for _, name in ipairs({ 'Empty', 'Constraint', 'Generic', 'Cycle' }) do
            spec.equal(C.satisfies(type_id(G, 'Box'), type_id(G, name), true), false, name)
        end
    end)
    spec.it('follows method result slots through channel ranges in the declaring package', function()
        local G = build({ ['app/server.go'] = [[package app
import gossh "crypto/ssh"
func Handle(newChan gossh.NewChannel) {
    channel, reqs, err := newChan.Accept()
    for req := range reqs { req.Reply(false, nil) }
}
]], ['crypto/ssh/channel.go'] = [[package ssh
type NewChannel interface { Accept() (Channel, <-chan *Request, error) }
type Channel interface {}
type Request struct {}
func (r *Request) Reply(ok bool, payload []byte) error { return nil }
]], ['app/other.go'] = [[package app
type Request struct {}
func (r *Request) Reply(ok bool, payload []byte) error { return nil }
]] })
        spec.equal(edge_names(G, type_id(G, 'Handle')), 'NewChannel.Accept,Request.Reply')
        local Q = graph.query(G); local id = type_id(G, 'Handle')
        for i = 1, #Q.out[id], graph.EDGE do
            local target = Q.out[id][i]
            if G.nodes[target].name == 'Reply' then spec.equal(G.files[G.node_file[target]].path, 'crypto/ssh/channel.go') end
        end
    end)
    spec.it('derives range keys and values from slices, arrays, maps and named collections', function()
        local G = build({ ['a.go'] = [[package p
type Item struct {}
func (*Item) Run() {}
type Items []*Item
type Alias = Items
type Key struct {}
func (Key) KeyRun() {}
func Slice(items []*Item) { for _, item := range items { item.Run() } }
func Array(items *[3]*Item) { for _, item := range items { item.Run() } }
func Mapping(items map[Key]*Item) { for key, item := range items { key.KeyRun(); item.Run() } }
func Named(items Alias) { for _, item := range items { item.Run() } }
func Indices(items []*Item) { for index := range items { index.Run() } }
]] })
        for _, name in ipairs({ 'Slice', 'Array', 'Named' }) do spec.equal(edge_names(G, type_id(G, name)), 'Item.Run', name) end
        spec.equal(edge_names(G, type_id(G, 'Mapping')), 'Item.Run,Key.KeyRun')
        spec.equal(edge_names(G, type_id(G, 'Indices')), '')
    end)
    spec.it('follows direct factory results and aliases while keeping loop bindings scoped', function()
        local G = build({ ['a.go'] = [[package p
type Item struct {}
func (*Item) Run() {}
type Other struct {}
func (Other) Run() {}
func Items() <-chan *Item { return nil }
func Pair() (int, *Item) { return 0, nil }
func Use(item Other) {
    items := Items()
    copy := items
    for item := range copy { item.Run() }
    item.Run()
    _, value := Pair()
    value.Run()
    var _, another = Pair()
    another.Run()
    for direct := range Items() { direct.Run() }
    first, second := &Item{}, &Other{}
    first.Run(); second.Run()
}
]] })
        spec.equal(edge_names(G, type_id(G, 'Use')), 'Item.Run,Item.Run,Item.Run,Item.Run,Item.Run,Items,Items,Other.Run,Other.Run,Pair,Pair')
    end)
    spec.it('blocks unresolved, send-only, wrong-arity and shadowed range sources', function()
        local G = build({ ['a.go'] = [[package p
type Item struct {}
func (*Item) Run() {}
func Items() <-chan *Item { return nil }
func Generic[T any]() <-chan *Item { return nil }
func Missing() { items := unknown(); for item := range items { item.Run() } }
func Send(items chan<- *Item) { for item := range items { item.Run() } }
func Arity(items <-chan *Item) { for _, item := range items { item.Run() } }
func Wrong() { _, items := Items(); for item := range items { item.Run() } }
func Shadow(Items func() <-chan *Item) { items := Items(); for item := range items { item.Run() } }
func Unsupported() { items := Generic[int](); for item := range items { item.Run() } }
func Local(items <-chan *Item) { { items := unknown(); for item := range items { item.Run() } } }
]] })
        for _, name in ipairs({ 'Missing', 'Send', 'Arity', 'Shadow', 'Local' }) do spec.equal(edge_names(G, type_id(G, name)), '', name) end
        spec.equal(edge_names(G, type_id(G, 'Wrong')), 'Items')
        -- Generic calls remain deliberately unresolved by the return-type path.
        local _, Q = edge_names(G, type_id(G, 'Unsupported'))
        for i = 1, #Q.out[type_id(G, 'Unsupported')], graph.EDGE do
            spec.truthy(G.nodes[Q.out[type_id(G, 'Unsupported')][i]].name ~= 'Run')
        end
    end)
    spec.it('resolves package factories and promoted result methods without confusing builtin indices', function()
        local G = build({ ['app/a.go'] = [[package app
import api "lib"
type int struct {}
func (int) Run() {}
func Packages() { items := api.Items(); for item := range items { item.Run() } }
func Promoted(c api.Wrapper) { items := c.Items(); for item := range items { item.Run() } }
func Index(items []*api.Item) { for index := range items { index.Run() } }
func String(text string) { for _, char := range text { char.Run() } }
]], ['lib/a.go'] = [[package lib
type Item struct {}
func (*Item) Run() {}
type Base struct {}
func (Base) Items() <-chan *Item { return nil }
type Wrapper struct { Base }
func Items() <-chan *Item { return nil }
]] })
        spec.equal(edge_names(G, type_id(G, 'Packages')), 'Item.Run,Items')
        spec.equal(edge_names(G, type_id(G, 'Promoted')), 'Base.Items,Item.Run')
        spec.equal(edge_names(G, type_id(G, 'Index')), '')
        spec.equal(edge_names(G, type_id(G, 'String')), '')
    end)
    spec.it('follows direct and chained call receivers using declared return types', function()
        local G = build({ ['p/types.go'] = [[package p
type Manager struct {}
func GetManager() *Manager { return nil }
func (*Manager) IsChild() bool { return false }
func (*Manager) Next() *Manager { return nil }
func (*Manager) Pair() (int, *Manager) { return 0, nil }
]], ['p/use.go'] = [[package p
func Direct() { if GetManager().IsChild() {} }
func Chain() { GetManager().Next().IsChild(); (GetManager()).IsChild() }
func Assign() { _, m := GetManager().Pair(); m.IsChild() }
]] })
        spec.equal(edge_names(G, type_id(G, 'Direct')), 'GetManager,Manager.IsChild')
        spec.equal(edge_names(G, type_id(G, 'Chain')), 'GetManager,GetManager,Manager.IsChild,Manager.IsChild,Manager.Next')
        spec.equal(edge_names(G, type_id(G, 'Assign')), 'GetManager,Manager.IsChild,Manager.Pair')
    end)
    spec.it('keeps call-result method sets non-addressable and package-specific', function()
        local G = build({ ['lib/a.go'] = [[package lib
type Manager struct {}
func GetManager() *Manager { return nil }
func Value() Manager { return Manager{} }
func (*Manager) PointerOnly() {}
func (Manager) ValueOnly() {}
]], ['app/a.go'] = [[package app
import api "lib"
type Manager struct {}
func (*Manager) PointerOnly() {}
func Use() { api.GetManager().PointerOnly(); api.Value().ValueOnly(); api.Value().PointerOnly() }
]] })
        spec.equal(edge_names(G, type_id(G, 'Use')), 'GetManager,Manager.PointerOnly,Manager.ValueOnly,Value,Value')
        local Q, id = graph.query(G), type_id(G, 'Use')
        for i = 1, #Q.out[id], graph.EDGE do
            spec.equal(G.files[G.node_file[Q.out[id][i]]].path, 'lib/a.go')
        end
    end)
    spec.it('blocks shadowed, generic, ambiguous and unsupported receiver chains', function()
        local G = build({ ['a.go'] = [[package p
type Manager struct {}
func (*Manager) IsChild() bool { return false }
func GetManager() *Manager { return nil }
func Many() (*Manager, error) { return nil, nil }
func Shadow(GetManager func() *Manager) { GetManager().IsChild() }
func Tuple() { Many().IsChild() }
func Field(m Manager) { m.Field().IsChild() }
func Indexed(items []func() *Manager) { items[0]().IsChild() }
func Assertion(m any) { m.(*Manager).IsChild() }
func Generic[T any]() *Manager { return nil }
func Unresolved() { Generic[int]().IsChild(); unknown().IsChild() }
]] })
        for _, name in ipairs({ 'Shadow', 'Field', 'Indexed', 'Assertion' }) do spec.equal(edge_names(G, type_id(G, name)), '', name) end
        spec.equal(edge_names(G, type_id(G, 'Tuple')), 'Many')
        local Q, id = graph.query(G), type_id(G, 'Unresolved')
        for i = 1, #Q.out[id], graph.EDGE do spec.truthy(G.nodes[Q.out[id][i]].name ~= 'IsChild') end
    end)
    spec.it('bounds receiver-expression depth and leaves compact indexes unchanged', function()
        local source = [[package p
type Manager struct {}
func GetManager() *Manager { return nil }
func (*Manager) Next() *Manager { return nil }
func (*Manager) IsChild() bool { return false }
func Deep() { ]] .. 'GetManager()' .. string.rep('.Next()', 40) .. '.IsChild() }'
        local G = build({ ['a.go'] = source })
        local Q, id = graph.query(G), type_id(G, 'Deep')
        for i = 1, #Q.out[id], graph.EDGE do spec.truthy(G.nodes[Q.out[id][i]].name ~= 'IsChild') end
        local compact = ci.parse('a.go', source, { ranges = false })
        spec.nil_value(compact.go_methods); spec.nil_value(compact.refs.binding)
    end)
    spec.it('checks function types and blocks shadowed builtins or local callables', function()
        local G, C = build({ ['a.go'] = [[package p
type I interface { Apply(func(int) error) }
type Good struct {}
func (Good) Apply(callback func(value int) error) {}
type Wrong struct {}
func (Wrong) Apply(func(string) error) {}
func (Good) Run() {}
func new(value any) Good { return Good{} }
func fn() {}
func Shadow() { p := new(Good{}); p.Run() }
func Local(fn func()) { fn() }
]] })
        spec.truthy(C.satisfies(type_id(G, 'Good'), type_id(G, 'I'), false))
        spec.equal(C.satisfies(type_id(G, 'Wrong'), type_id(G, 'I'), false), false)
        spec.equal(edge_names(G, type_id(G, 'Shadow')), 'new')
        spec.equal(edge_names(G, type_id(G, 'Local')), '')
    end)
    spec.it('keeps own methods reliable when an external embedding is unavailable', function()
        local G, C = build({ ['a.go'] = [[package p
import "sync"
type I interface { Run() }
type Base struct {}
func (Base) Run() {}
type Own struct { sync.Mutex }
func (Own) Run() {}
type Promoted struct { sync.Mutex; Base }
]] })
        spec.truthy(C.satisfies(type_id(G, 'Own'), type_id(G, 'I'), false))
        spec.equal(C.satisfies(type_id(G, 'Promoted'), type_id(G, 'I'), false), false)
    end)
    spec.it('keeps unsupported parameter and result syntax from reviving package aliases', function()
        local G = build({ ['p/a.go'] = [[package p
import r "other"
type Good struct {}
func (Good) Run() {}
func Inline(r interface { Run() }) { r.Run() }
func Return(r Good) interface { Run() } { r.Run(); return nil }
func Closure() { func(r interface { Run() }) { r.Run() }(nil) }
func TypeShadow() { type r int; r.Run() }
func GroupedTypeShadow() { type (r int); r.Run() }
func Generic[r interface { Run() }](v r) { r.Run(v) }
]], ['other/a.go'] = 'package other\nfunc Run() {}' })
        spec.equal(edge_names(G, type_id(G, 'Inline')), '')
        spec.equal(edge_names(G, type_id(G, 'Return')), 'Good.Run')
        spec.equal(edge_names(G, type_id(G, 'Closure')), '')
        spec.equal(edge_names(G, type_id(G, 'TypeShadow')), '')
        spec.equal(edge_names(G, type_id(G, 'GroupedTypeShadow')), '')
        spec.equal(edge_names(G, type_id(G, 'Generic')), '')
    end)
    spec.it('bounds candidates and reports incomplete results without persistent evidence', function()
        local source = { 'package p', 'type I interface { Run() }' }
        for i = 1, 12 do source[#source + 1] = 'type Box' .. i .. ' struct {}\nfunc (Box' .. i .. ') Run() {}' end
        local G = build({ ['a.go'] = table.concat(source, '\n') })
        local cap = methods.MAX_CANDIDATES; methods.MAX_CANDIDATES = 3
        local ok, err = pcall(function()
            local names, Q = edge_names(G, G.by_qualified['I.Run'][1], 'implementation')
            spec.truthy(Q.incomplete); spec.truthy(#names > 0)
        end)
        methods.MAX_CANDIDATES = cap; assert(ok, err)
        local compact = ci.parse('a.go', table.concat(source, '\n'), { ranges = false })
        spec.nil_value(compact.go_methods); spec.nil_value(compact.refs.binding)
    end)
    spec.it('bounds source evidence and preserves cancellation identity', function()
        local G = build({ ['i.go'] = 'package p\ntype I interface { Run() }',
            ['box.go'] = 'package p\ntype Box struct {}\nfunc (Box) Run() {}' })
        for _, field in ipairs({ 'MAX_FILES', 'MAX_BYTES', 'MAX_TIME_MS' }) do
            local old = methods[field]; methods[field] = field == 'MAX_TIME_MS' and -1 or 1
            local ok, err = pcall(function()
                local names, Q = edge_names(G, G.by_qualified['I.Run'][1], 'implementation')
                spec.equal(names, ''); spec.truthy(Q.incomplete)
            end)
            methods[field] = old; assert(ok, err)
        end
        local control = require('codeoutline.control'); local stopped = control.cancelled()
        control.callback = function() error(stopped, 0) end
        local ok, err = pcall(edge_names, G, G.by_qualified['I.Run'][1])
        control.callback = nil; spec.equal(ok, false); spec.equal(err, stopped)
    end)
    spec.it('revalidates cached Go source after edits and keeps evidence out of disk records', function()
        local root = tmp_root .. '/go_method_refresh'
        write(root .. '/types.go', 'package p\ntype I interface { Run() int }\ntype Box struct {}')
        write(root .. '/methods.go', 'package p\nfunc (Box) Run() int { return 1 }')
        local options = { cache_path = root .. '/cache.idx', lister = 'walk' }
        local idx, G = svc.get(root, options)
        spec.equal(edge_names(G, G.by_qualified['I.Run'][1], 'implementation'), 'Box.Run')
        local text = svc.explore(root, 'I.Run Box.Run', options)
        spec.contains(text, 'possible Go implementation')
        for _, rec in pairs(idx.files) do spec.nil_value(rec.go_methods); spec.nil_value(rec.refs.binding) end
        idx:save(); svc.forget(root); idx, G = svc.get(root, options); spec.truthy(idx.cache_loaded)
        spec.equal(edge_names(G, G.by_qualified['I.Run'][1], 'implementation'), 'Box.Run')
        write(root .. '/methods.go', 'package p\nfunc (Box) Run() string { return "" }')
        idx, G = svc.get(root, options)
        spec.equal(edge_names(G, G.by_qualified['I.Run'][1], 'implementation'), '')
        svc.forget(root)
    end)
    spec.it('keeps proven implementation entries when the set budget is exhausted', function()
        local G = build({ ['a.go'] = [[package p
type I interface { Read(); Write() }
type Box struct {}
func (Box) Read() {}
func (Box) Write() {}
]] })
        local cap = methods.MAX_TYPES; methods.MAX_TYPES = 2
        local ok, err = pcall(function()
            spec.equal(edge_names(G, G.by_qualified['I.Read'][1], 'implementation'), 'Box.Read')
        end)
        methods.MAX_TYPES = cap; assert(ok, err)
    end)
    spec.it('does not mutate cached base interfaces while merging embedded declarations', function()
        local G, C = build({ ['a.go'] = [[package p
type I interface { Read() int }
type J interface { Read() int }
type Combined interface { I; J }
]] })
        local base = C.method_set(type_id(G, 'I'), false)
        spec.equal(#base.entries.Read.ids, 1)
        spec.equal(#C.method_set(type_id(G, 'Combined'), false).entries.Read.ids, 2)
        spec.equal(#base.entries.Read.ids, 1)
        spec.equal(G.nodes[base.entries.Read.ids[1]].qualified, 'I.Read')
    end)
end)

return {
    __init = function()
        local failed = spec.finish()
        if failed > 0 then os.exit(1) end
        xthread.stop(0)
    end,
}
