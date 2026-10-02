local M = {}
local u = require('xutils')
function M.id(s)
    return type(s) == 'string' and #s <= 64 and s:match('^[a-z][a-z0-9_-]*$') ~= nil
end
function M.version(s)
    return type(s) == 'string' and #s <= 64 and s:match('^%d+%.%d+%.%d+$') ~= nil
end
function M.read(path, limit)
    local f = io.open(path, 'rb'); if not f then return nil end
    local data, err = f:read((limit or 67108864) + 1); f:close()
    if err then return nil end
    data = data or ''
    if #data > (limit or 67108864) then return nil end
    return data
end
function M.write(path, data)
    assert(u.mkdir_p(assert(path:match('^(.*)/[^/]+$'))))
    local f = assert(io.open(path, 'wb')); assert(f:write(data)); assert(f:close())
end
function M.atomic(path, data)
    local temp = assert(u.temp_file(assert(path:match('^(.*)/[^/]+$'))))
    local ok, err = pcall(function() M.write(temp, data); assert(u.replace_file(temp, path)) end)
    if not ok then os.remove(temp); error(err) end
end
function M.path(s)
    if type(s) ~= 'string' or #s == 0 or #s > 240 or s:find('[^%w_./-]') or s:sub(1,1) == '/' then return false end
    for part in s:gmatch('[^/]+') do
        if part == '.' or part == '..' or part:sub(-1) == '.' then return false end
        local stem = part:match('^([^.]*)'):upper()
        if stem == 'CON' or stem == 'PRN' or stem == 'AUX' or stem == 'NUL' or stem:match('^COM[1-9]$') or stem:match('^LPT[1-9]$') then return false end
    end
    return not s:find('//',1,true) and s:sub(-1) ~= '/'
end
function M.decode_json(s)
    local ok, v = pcall(u.json_unpack, s or '')
    if ok and type(v) == 'table' then return v end
end
function M.manifest(envelope, public_key)
    assert(type(envelope) == 'table' and type(envelope.payload) == 'string' and #envelope.payload <= 1048576, 'invalid signed envelope')
    assert(type(envelope.signature) == 'string' and #envelope.signature <= 1024, 'invalid signature')
    local sig = u.base64_decode(envelope.signature)
    assert(require('xupgate.signature').verify(public_key, envelope.payload, sig), 'manifest signature invalid')
    local m = assert(M.decode_json(envelope.payload), 'invalid manifest JSON')
    assert(m.schema == 1 and M.id(m.project) and M.version(m.version) and M.id(m.platform), 'invalid manifest identity')
    assert(m.minUpdater == 1, 'unsupported updater version')
    assert(type(m.sha256) == 'string' and #m.sha256 == 64 and m.sha256:match('^[0-9a-f]+$'), 'invalid package hash')
    assert(type(m.size) == 'number' and m.size > 0 and m.size <= 50331648 and m.size % 1 == 0, 'invalid package size')
    assert(type(m.sequence) == 'number' and m.sequence >= 1 and m.sequence % 1 == 0, 'invalid release sequence')
    assert(type(m.entry) == 'string' and M.path(m.entry), 'invalid entry')
    assert(m.notes==nil or (type(m.notes)=='string' and #m.notes<=16384),'invalid notes')
    assert(m.runtime==nil or M.path(m.runtime),'invalid runtime')
    return m
end
function M.bundle(data, manifest)
    assert(#data == manifest.size and u.sha256_hex(data) == manifest.sha256, 'package checksum mismatch')
    local b = assert(M.decode_json(data), 'invalid bundle')
    assert(b.schema == 1 and type(b.files) == 'table' and #b.files > 0 and #b.files <= 10000, 'invalid files')
    local seen, decoded, total, entry = {}, {}, 0, false
    for _, f in ipairs(b.files) do
        assert(type(f) == 'table' and M.path(f.path) and type(f.data) == 'string', 'unsafe file')
        local key = f.path:lower(); assert(not seen[key], 'duplicate file'); seen[key] = true
        local bytes = assert(u.base64_decode(f.data), 'bad base64')
        total = total + #bytes; assert(total <= 50331648, 'expanded package too large')
        decoded[#decoded+1] = { path = f.path, data = bytes, executable = f.executable == true }
        if f.path == manifest.entry then entry = true end
    end
    for key in pairs(seen) do
        local prefix = key:match('^(.*)/[^/]+$')
        while prefix do assert(not seen[prefix], 'file/directory collision'); prefix = prefix:match('^(.*)/[^/]+$') end
    end
    assert(entry, 'entry missing from bundle')
    assert(not manifest.runtime or seen[manifest.runtime:lower()], 'runtime missing from bundle')
    return decoded
end
return M
