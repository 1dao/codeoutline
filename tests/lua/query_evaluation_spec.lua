package.path = 'tools/?.lua;' .. package.path
local spec = dofile('tests/lua/spec_helper.lua')
local eval = require('query-evaluation')
local a = { file = 'a.lua', name = 'save' }
local b = { file = 'b.lua', name = 'save' }
local case = { expected = { a }, forbidden = { b } }
spec.describe('query evaluation verdicts', function()
    spec.it('rejects same-name results from a different file', function()
        local s = eval.score(case, { matched = 1, nodes = { b } })
        spec.equal(s.pass, false); spec.equal(#s.missing, 1); spec.equal(#s.forbidden, 1)
    end)
    spec.it('fails missing roots even for negative cases', function()
        spec.equal(eval.score({expected = {}, forbidden = {a}}, {matched = 0, nodes = {}}).pass, false)
    end)
    spec.it('does not call unreviewed extra results false positives', function()
        local extra = {file = 'c.lua', name = 'other'}
        local s = eval.score(case, {matched = 1, nodes = {a, extra}})
        spec.equal(s.pass, true); spec.equal(#s.unjudged, 1)
        s = eval.score({expected = {a}, forbidden = {}, exhaustive = true}, {matched = 1, nodes = {a, extra}})
        spec.equal(s.pass, false); spec.equal(#s.unexpected, 1)
    end)
    spec.it('never passes a truncated or failed query', function()
        for _, run in ipairs({{matched = 1, nodes = {a}, incomplete = true}, {matched = 1, nodes = {a}, error = 'timeout'}}) do
            spec.equal(eval.score(case, run).pass, false)
        end
    end)
    spec.it('supports optional line disambiguation', function()
        spec.equal(eval.matches({file='a.lua',name='save',line=4},{file='a.lua',name='save',line=5}), false)
    end)
    spec.it('renders engine verdicts without confusing incomplete comparisons with failures', function()
        local run = {round=1,matched=1,nodes={a},ms=2,parses=1,output_bytes=20}
        run.score = eval.score(case, run)
        local ref = {round=1,matched=2,nodes={},incomplete=true,ms=10}
        ref.score = eval.score(case, ref)
        local md = eval.markdown({passed=1,failed=0,cases={{id='example',runs={run},codegraph={runs={ref}}}},codegraph={}})
        spec.contains(md, '1 cases'); spec.contains(md, 'PASS'); spec.contains(md, 'INCOMPLETE')
    end)
end)
local failed = spec.finish()
return { __init = function() xthread.stop(failed == 0 and 0 or 1) end }
