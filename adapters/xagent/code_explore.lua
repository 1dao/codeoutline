-- xagent/tools/code_explore.lua — the CodeExplore tool: symbol-level code
-- lookup over a per-project index (scripts/codeoutline/), returning the
-- verbatim source of the named definitions, the call paths between them, and
-- their callers/callees in one call instead of a Grep + Read loop.

local svc = require('codeoutline.service')

return {
    name = 'CodeExplore',
    description =
        'Find code by symbol and return its verbatim, line-numbered source in one call: ' ..
        'the definitions the query names, the call paths between them, and their callers ' ..
        'and callees. Use it BEFORE Grep/Read when locating or understanding code; name ' ..
        'functions, methods, classes, or files in the query (e.g. "xtimer_poll xtimer_add", ' ..
        '"Session.save", "how does xpoll.c dispatch events"). Source it returns is current ' ..
        'and can be edited directly without re-reading. Supports C, C++, Lua, Python, Java, Go, JavaScript/TypeScript, C#, Rust.',
    input_schema = {
        type = 'object',
        properties = {
            query = { type = 'string', description = 'Symbol names, qualified names, or file names to explore; a short question naming them also works' },
            path = { type = 'string', description = 'Project root to search (default: the working directory)' },
            budget = { type = 'number', description = 'Max output bytes (default 16000)' },
        },
        required = { 'query' },
    },
    is_read_only = function() return true end,

    call = function(input, ctx)
        local query = input.query
        if type(query) ~= 'string' or query == '' then
            return { content = 'Error: query is required', is_error = true }
        end
        local root = input.path or (ctx and ctx.cwd) or '.'
        local ok, text = pcall(svc.explore, root, query, { budget = tonumber(input.budget) })
        if not ok then
            return { content = 'Error: ' .. tostring(text), is_error = true }
        end
        return { content = text }
    end,
}
