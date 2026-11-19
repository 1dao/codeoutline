-- Internal source identity shared by readers and the background builder.
local indexing = require('codeoutline.indexing.index')
local paths = require('codeoutline.shared.path')
local control = require('codeoutline.shared.control')
local M = {magic = 'CODEOUTLINE-BM25\n'}
M.prefix = M.magic .. '2\n'
local cache = setmetatable({}, {__mode = 'k'})

function M.stamp(index)
    local cached = cache[index]
    if cached and cached.generation == index.generation then return cached.stamp, cached.files end
    local files, records = {}, {}
    for path in pairs(index.files) do files[#files + 1] = path end
    table.sort(files)
    for i, path in ipairs(files) do
        if i % 128 == 0 then control.check() end
        local file = index.files[path]
        records[i] = {path, file.size, file.crc, file.language, file.cpp_fragment or false}
    end
    local stamp = xutils.sha256_hex(cmsgpack.pack({indexing.VERSION, paths.key(index.root), records}))
    cache[index] = {generation = index.generation, stamp = stamp, files = files}
    return stamp, files
end

function M.current(path, stamp)
    local file = io.open(path, 'rb')
    if not file then return false end
    local prefix = file:read(#M.prefix + #stamp)
    file:close()
    return prefix == M.prefix .. stamp
end

-- The background reader validates the disk snapshot against the foreground
-- index's identity without loading a second copy of its base records.
function M.reader(root, stamp)
    local index = {root = root}
    cache[index] = {stamp = stamp}
    return index
end

return M
