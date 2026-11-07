-- One project-local contract, two consumers. Legacy arrays keep their scope.
local M = {}
local function copy(value)
    local result = {}; for k, v in pairs(value) do result[k] = v end; return result
end
local function array(value, label)
    if value == nil then value = {} end
    assert(type(value) == 'table' and #value <= 32, label .. ' must contain at most 32 rules')
    local count = 0
    for k in pairs(value) do
        assert(type(k) == 'number' and k >= 1 and k <= #value and k % 1 == 0, label .. ' must be an array')
        count = count + 1
    end
    assert(count == #value, label .. ' must be an array')
    return value
end
local function position(r, key, label)
    local n = r[key]
    assert(type(n) == 'number' and n >= 1 and n <= 32 and n % 1 == 0,
        label .. '.' .. key .. ' must be an integer from 1 to 32')
end
local function call(r, key, label)
    assert(type(r[key]) == 'string' and r[key]:match('^[%a_][%w_%.:>%-]*$'), 'invalid ' .. label .. '.' .. key)
end
local function qualifiers(r, label)
    if r.qualifiers == nil then return nil end
    local result = {}
    assert(type(r.qualifiers) == 'table', label .. '.qualifiers must be an array of names')
    local count = 0
    for k, q in pairs(r.qualifiers) do
        assert(type(k) == 'number' and k >= 1 and k <= #r.qualifiers and k % 1 == 0,
            label .. '.qualifiers must be an array of names')
        assert(type(q) == 'string' and q:match('^[%a_][%w_]*$'), label .. '.qualifiers must contain plain names')
        result[q], count = true, count + 1
    end
    assert(count == #r.qualifiers, label .. '.qualifiers must be an array of names')
    return result
end
local function dispatch(r, label)
    assert(type(r) == 'table', 'invalid ' .. label .. ' rule')
    call(r, 'call', label); position(r, 'argument', label)
    assert(r.language == nil or type(r.language) == 'string', 'invalid ' .. label .. '.language')
    assert(r.kind == 'target' or r.kind == 'callback' or r.kind == 'event', 'invalid ' .. label .. '.kind')
    if r.serviceArgument ~= nil then
        assert(r.kind == 'target', 'serviceArgument requires a target rule')
        position(r, 'serviceArgument', label)
    end
    if r.kind == 'event' then
        call(r, 'register', label); position(r, 'keyArgument', label); position(r, 'handlerArgument', label)
    end
    local result = copy(r)
    -- Declaration qualifiers restrict editor candidates, not graph inference.
    result.qualifiers = nil
    return result
end
local function definition(r, label)
    assert(type(r) == 'table', 'invalid ' .. label .. ' rule')
    assert(r.language == nil or r.language == 'lua', label .. ' currently support language lua')
    call(r, 'call', label); position(r, 'argument', label)
    local result = copy(r)
    result.targetKind = r.targetKind or 'call'
    assert(result.targetKind == 'call' or result.targetKind == 'declaration' or result.targetKind == 'key',
        "invalid " .. label .. '.targetKind')
    if result.targetKind == 'call' then
        call(r, 'target', label); position(r, 'targetArgument', label)
    else
        assert(r.target == nil and r.targetArgument == nil, 'declaration and key rules must not set target or targetArgument')
        result.qualifiers = qualifiers(r, label)
    end
    return result
end
function M.read(root)
    local f = root and io.open(root .. '/.codeoutline.json', 'rb')
    if not f then return {} end
    local raw = f:read(65537); f:close()
    assert(#raw <= 65536, '.codeoutline.json exceeds 64 KiB')
    local ok, config = pcall(xutils.json_unpack, raw)
    assert(ok and type(config) == 'table', 'invalid .codeoutline.json')
    return config
end
function M.normalize(config)
    local result = { definitions = {}, dispatch = {} }
    local seen = { definitions = {}, dispatch = {} }
    local function add(consumer, r)
        local fields = consumer == 'dispatch' and { 'kind', 'language', 'call', 'argument', 'register', 'keyArgument', 'handlerArgument', 'serviceArgument' }
            or { 'language', 'call', 'argument', 'targetKind', 'target', 'targetArgument', 'serviceArgument' }
        local key = {}
        for _, f in ipairs(fields) do key[#key + 1] = tostring(r[f]) end
        if r.qualifiers then
            local q = {}; for name in pairs(r.qualifiers) do q[#q + 1] = name end; table.sort(q)
            key[#key + 1] = table.concat(q, ',')
        end
        key = table.concat(key, '\0')
        if not seen[consumer][key] then
            seen[consumer][key] = r
            result[consumer][#result[consumer] + 1] = r
            assert(#result[consumer] <= 32, 'combined ' .. consumer .. ' rules must contain at most 32 rules')
        elseif consumer == 'definitions' and not r.shared then
            -- Keep the legacy literal/method matcher when an equivalent shared
            -- contract is also configured; their alias semantics differ.
            seen[consumer][key].legacy = true
        end
    end
    for _, r in ipairs(array(config.rules, 'rules')) do
        assert(type(r) == 'table', 'invalid rules rule')
        if r.kind == 'definition' then add('definitions', definition(r, 'rules'))
        else
            local d = dispatch(r, 'rules')
            add('dispatch', d)
            local n = copy(d); n.shared = true
            if d.kind == 'event' then n.targetKind, n.target, n.targetArgument = 'call', d.register, d.keyArgument
            elseif d.kind == 'target' then n.targetKind, n.qualifiers = 'declaration', qualifiers(r, 'rules')
            else n.targetKind = 'callback' end
            add('definitions', n)
        end
    end
    for _, r in ipairs(array(config.definitionRules, 'definitionRules')) do add('definitions', definition(r, 'definitionRules')) end
    for _, r in ipairs(array(config.dispatchRules, 'dispatchRules')) do add('dispatch', dispatch(r, 'dispatchRules')) end
    return result
end
function M.load(root) return M.normalize(M.read(root)) end
function M.dispatch(rules)
    local result = {}
    for _, r in ipairs(array(rules, 'dispatchRules')) do result[#result + 1] = dispatch(r, 'dispatchRules') end
    return result
end
return M
