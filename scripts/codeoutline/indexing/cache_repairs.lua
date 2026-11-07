-- Small atomic overlays for query-discovered encoding repairs. Bound to the
-- exact base cache payload; ordinary saves merge them and invalidate the sidecar.
local M = { MAX_RECORDS = 256, MAX_BYTES = 8 * 1024 * 1024 }

function M.load(path, hash, version, root)
    local f = io.open(path .. '.repairs', 'rb')
    if not f then return {} end
    local raw = f:read(M.MAX_BYTES + 1); f:close()
    local ok, records = pcall(function()
        assert(#raw <= M.MAX_BYTES)
        local e = cmsgpack.unpack(raw)
        assert(e.base == hash and e.version == version and e.root == root)
        assert(type(e.payload) == 'string' and e.sha256 == xutils.sha256_hex(e.payload))
        local entries = cmsgpack.unpack(e.payload)
        assert(type(entries) == 'table')
        local count = 0
        for key, rec in pairs(entries) do
            count = count + 1
            assert(count <= M.MAX_RECORDS and type(key) == 'string' and type(rec) == 'table' and rec.path == key)
        end
        return entries
    end)
    return ok and records or {}
end

function M.save(path, hash, version, root, records)
    local count = 0
    for _ in pairs(records) do count = count + 1 end
    if count > M.MAX_RECORDS then return false, 'encoding repair cache record limit reached; a normal index save is required' end
    local payload = cmsgpack.pack(records)
    local blob = cmsgpack.pack({ base = hash, version = version, root = root,
        payload = payload, sha256 = xutils.sha256_hex(payload) })
    if #blob > M.MAX_BYTES then return false, 'encoding repair cache byte limit reached; a normal index save is required' end
    local dir = path:match('^(.*)/[^/]*$') or '.'
    local tmp, err = xutils.temp_file(dir)
    if not tmp then return false, err end
    local f; f, err = io.open(tmp, 'wb')
    if not f then os.remove(tmp); return false, err end
    local wrote, write_err = f:write(blob)
    local closed, close_err = f:close()
    if not wrote or not closed then os.remove(tmp); return false, write_err or close_err end
    local published; published, err = xutils.replace_file(tmp, path .. '.repairs')
    if not published then os.remove(tmp); return false, err end
    return true
end

return M
