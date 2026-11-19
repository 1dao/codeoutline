-- Public API: build(index, file) and search(index, file, query, options).
-- Pass a refreshed CodeOutline index. The file is a lexical snapshot of that
-- project's source records and must be rebuilt when those records change.
local indexing = require('codeoutline.indexing.index')
local pool = require('codeoutline.indexing.parse_pool')
local collect = require('codeoutline.bm25.collect')
local control = require('codeoutline.shared.control')
local paths = require('codeoutline.shared.path')
local text_util = require('codeoutline.shared.text')
local snapshot = require('codeoutline.bm25.snapshot')

local M = {}
local TRAILER_SIZE = 80
local PASSAGE_BLOCK = 32
local GC_BATCH_BYTES = 512 * 1024
local GC_STEP_KB = 512
local cached_digest, cached_header

-- Drive GC by completed work so temporary batches can be reclaimed while the
-- live postings grow. Keep the collector settings of the calling Lua state.
local function build_gc()
    local processed = 0
    return function(bytes)
        processed = processed + bytes
        if processed >= GC_BATCH_BYTES then
            processed = 0
            collectgarbage('step', GC_STEP_KB)
        end
    end
end

local function plan(index, source_paths)
    local jobs, files, locations = {}, {}, {}
    for _, path in ipairs(source_paths) do
        control.check()
        local file = index.files[path]
        local documents = {}
        for _, node in ipairs(file.nodes) do
            if node.kind == 'function' or node.kind == 'method' then
                documents[#documents + 1] = {false, text_util.valid(node.qualified or node.name),
                    node.line, math.max(node.line, node.end_line or node.line), node.kind}
            end
        end
        if #documents > 0 then
            table.sort(documents, function(a, b)
                if a[3] ~= b[3] then return a[3] < b[3] end
                if a[2] ~= b[2] then return a[2] < b[2] end
                if a[4] ~= b[4] then return a[4] < b[4] end
                return a[5] < b[5]
            end)
            local file_id = #files + 1
            files[file_id] = path
            for _, doc in ipairs(documents) do
                doc[1] = #locations + 1
                locations[doc[1]] = {file_id, doc[2], doc[3], doc[4], doc[5]}
            end
            jobs[#jobs + 1] = {rel = path, abs = index:abs(path), size = file.size, crc = file.crc,
                language = file.language, documents = documents, weight = file.size + indexing.FILE_WEIGHT}
        end
    end
    return jobs, files, locations
end

local function collect_terms(index, jobs, spool, gc_step)
    local totals, lengths, comments = {0, 0, 0, 0}, {}, 0
    local function accept(_, result)
        local encoded = result.terms
        assert(spool:write(encoded))
        lengths[#lengths + 1] = #encoded
        comments = comments + result.comments
        for i, length in ipairs(result.totals) do totals[i] = totals[i] + length end
        gc_step(#encoded)
    end
    if #jobs >= indexing.PARALLEL_MIN_FILES and pool.ready() then
        pool.run(jobs, index.max_bytes, accept, 'bm25_collect')
    else
        for _, entry in ipairs(jobs) do
            accept(entry.rel, collect.file(entry.abs, entry.rel, entry.size, entry.crc, entry.language, entry.documents))
        end
    end
    assert(#lengths == #jobs, 'incomplete BM25 source pass')
    return totals, lengths, comments
end

local function read_at(file, offset, length)
    assert(file:seek('set', offset) == offset, 'cannot seek BM25 index')
    local data = assert(file:read(length), 'truncated BM25 index')
    assert(#data == length, 'truncated BM25 index')
    return data
end

local function merge_terms(spool, totals, lengths, count, write_passages, gc_step)
    local postings, averages = {}, {}
    for i, total in ipairs(totals) do averages[i] = count > 0 and total / count or 0 end
    assert(spool:seek('set', 0) == 0)
    for _, length in ipairs(lengths) do
        control.check()
        gc_step(length)
        local data = assert(spool:read(length), 'truncated BM25 staging file')
        assert(#data == length, 'truncated BM25 staging file')
        local batch = cmsgpack.unpack(data)
        if #batch > 0 then write_passages(batch) end
        for _, doc in ipairs(batch) do
            local id, fields = table.unpack(doc)
            for i, field in ipairs(fields) do
                if averages[i] > 0 then
                    local terms, length = table.unpack(field)
                    local normalization = 1.2 * (0.25 + 0.75 * length / averages[i])
                    local weight = collect.weights[i]
                    for word, frequency in pairs(terms) do
                        local matches = postings[word]
                        if not matches then matches = {}; postings[word] = matches end
                        local tf = weight * 2.2 * frequency / (frequency + normalization)
                        matches[id] = (matches[id] or 0) + tf
                    end
                end
            end
        end
    end
    return postings
end

local function exact_keys(files, locations)
    local exact = {}
    for id, location in ipairs(locations) do
        if id % 128 == 0 then control.check() end
        local path = files[location[1]]:lower()
        local name = location[2]:lower()
        for _, key in ipairs({path, path:match('[^/]+$'), name, name:match('[^.:]+$') or name}) do
            local matches = exact[key]
            if not matches then matches = {}; exact[key] = matches end
            matches[id] = true
        end
    end
    return exact
end

local function write_index(output, spool, totals, lengths, header, gc_step)
    local prefix = snapshot.prefix(header.version) .. header.stamp
    assert(output:write(prefix))
    local offset, count = #prefix, #header.locations
    local function write_data(data)
        local location = {offset, #data, xcompress.crc32(data)}
        assert(output:write(data))
        offset = offset + #data
        return location
    end
    local function write_block(matches)
        return write_data(cmsgpack.pack(matches))
    end
    local compressor = xcompress.new_compressor(1)
    local function write_passages(batch)
        local first_id = batch[1][1]
        local blocks = {first_id}
        header.passages[header.locations[first_id][1]] = blocks
        for start = 1, #batch, PASSAGE_BLOCK do
            control.check()
            local passages = {}
            for i = start, math.min(start + PASSAGE_BLOCK - 1, #batch) do
                passages[#passages + 1] = {batch[i][3], batch[i][4]}
            end
            local data = cmsgpack.pack(passages)
            local entry = write_data(assert(compressor:deflate(data)))
            entry[4] = #data
            blocks[#blocks + 1] = entry
        end
    end
    local postings = merge_terms(spool, totals, lengths, count, write_passages, gc_step)
    compressor:close()
    local records = 0
    for word, matches in pairs(postings) do
        control.check()
        local frequency = 0
        for _ in pairs(matches) do frequency = frequency + 1 end
        local entry = write_block(matches)
        entry[4] = math.log(1 + (count - frequency + 0.5) / (frequency + 0.5))
        header.words[word] = entry
        records = records + frequency
        postings[word] = nil
        matches = nil
        gc_step(entry[2])
    end
    postings = nil
    local exact = exact_keys(header.files, header.locations)
    for key, matches in pairs(exact) do
        control.check()
        local entry = write_block(matches)
        header.exact[key] = entry
        exact[key] = nil
        matches = nil
        gc_step(entry[2])
    end
    exact = nil
    local encoded = cmsgpack.pack(header)
    assert(output:write(encoded, xutils.sha256_hex(encoded), string.format('%016d', #encoded)))
    return records, offset + #encoded + TRAILER_SIZE
end

local function output_path(file)
    assert(type(file) == 'string' and file ~= '' and not file:find('%z'), 'BM25 index file is required')
    return paths.normalize(file)
end

local function check_destination(file)
    local existing = io.open(file, 'rb')
    if not existing then return end
    local magic = existing:read(#snapshot.magic)
    existing:close()
    assert(magic == snapshot.magic, 'refusing to replace a non-BM25 file: ' .. file)
end

function M.build(index, file)
    file = output_path(file)
    assert(not index.cache_path or paths.key(file) ~= paths.key(index.cache_path),
        'BM25 must use a separate file from the base index')
    check_destination(file)
    local parent = file:match('^(.*)/[^/]+$') or '.'
    if parent == '' or parent:match('^%a:$') then parent = parent .. '/' end
    assert(xutils.mkdir_p(parent))
    local generation = index.generation
    local stamp, source_paths = snapshot.stamp(index)
    local jobs, files, locations = plan(index, source_paths)
    local spool_name, staged, spool, output
    local ok, result = pcall(function()
        spool_name = assert(xutils.temp_file(parent))
        spool = assert(io.open(spool_name, 'w+b'))
        local gc_step = build_gc()
        local totals, lengths, comments = collect_terms(index, jobs, spool, gc_step)
        jobs = nil
        staged = assert(xutils.temp_file(parent))
        output = assert(io.open(staged, 'wb'))
        local records, bytes = write_index(output, spool, totals, lengths, {version = snapshot.version,
            stamp = stamp, files = files, locations = locations, words = {}, exact = {}, passages = {}}, gc_step)
        assert(spool:close()); spool = nil
        assert(output:close()); output = nil
        control.check()
        assert(index.generation == generation, 'base index changed during BM25 build')
        check_destination(file)
        assert(xutils.replace_file(staged, file))
        staged = nil
        return {files = #files, functions = #locations, comments = comments, postings = records, bytes = bytes}
    end)
    if spool then spool:close() end
    if output then output:close() end
    if spool_name then os.remove(spool_name) end
    if staged then os.remove(staged) end
    if not ok then error(result, 0) end
    return result
end

local function open_header(file)
    local size = assert(file:seek('end'))
    local magic = snapshot.magic
    assert(size > #magic + TRAILER_SIZE and read_at(file, 0, #magic) == magic, 'invalid BM25 index')
    local trailer = read_at(file, size - TRAILER_SIZE, TRAILER_SIZE)
    local digest, length = trailer:sub(1, 64), tonumber(trailer:sub(65))
    assert(length and length % 1 == 0 and length > 0 and length <= size - #magic - TRAILER_SIZE,
        'invalid BM25 header length')
    local offset = size - TRAILER_SIZE - length
    if digest ~= cached_digest then
        local encoded = read_at(file, offset, length)
        assert(xutils.sha256_hex(encoded) == digest, 'corrupt BM25 header')
        local header = cmsgpack.unpack(encoded)
        assert(header.version == 1 or header.version == 2 or header.version == snapshot.version,
            'unsupported BM25 index version; rebuild it')
        cached_digest, cached_header = digest, header
    end
    local first = #magic
    if cached_header.version >= 2 then
        local prefix = snapshot.prefix(cached_header.version) .. cached_header.stamp
        assert(offset >= #prefix and read_at(file, 0, #prefix) == prefix, 'corrupt BM25 snapshot prefix')
        first = #prefix
    end
    return cached_header, first, offset
end

local function read_data(file, entry, first, boundary)
    local offset, length = entry[1], entry[2]
    assert(offset >= first and length > 0 and offset + length <= boundary, 'invalid BM25 block range')
    local encoded = read_at(file, offset, length)
    assert(xcompress.crc32(encoded) == entry[3], 'corrupt BM25 postings')
    return encoded
end

local function read_block(file, entry, first, boundary)
    return cmsgpack.unpack(read_data(file, entry, first, boundary))
end

local function scope_key(index, path)
    if path == nil or path == '' or path == '.' then return nil end
    assert(type(path) == 'string', 'BM25 path filter must be a string')
    path = paths.key(path):gsub('^%./', '')
    if path:match('^/') or path:match('^%a:/') then
        local root = paths.key(index.root)
        assert(paths.contains(root, path), 'BM25 path filter is outside the project')
        if root == path then return nil end
        return path:sub(#root + (root:sub(-1) == '/' and 1 or 2))
    end
    return path
end

local function rank(scores, exact, literal, limit)
    local function better(a, b)
        if exact[a] ~= exact[b] then return exact[a] == true end
        if literal[a] ~= literal[b] then return literal[a] == true end
        if scores[a] ~= scores[b] then return scores[a] > scores[b] end
        return a < b
    end
    -- The root of the bounded heap is the worst retained candidate.
    local heap, visited = {}, 0
    for id in pairs(scores) do
        visited = visited + 1
        if visited % 1024 == 0 then control.check() end
        if #heap < limit then
            local i = #heap + 1
            while i > 1 do
                local parent = math.floor(i / 2)
                if not better(heap[parent], id) then break end
                heap[i], i = heap[parent], parent
            end
            heap[i] = id
        elseif better(id, heap[1]) then
            local i, child = 1, 2
            while child <= #heap do
                if child < #heap and better(heap[child], heap[child + 1]) then child = child + 1 end
                if not better(id, heap[child]) then break end
                heap[i], i = heap[child], child
                child = i * 2
            end
            heap[i] = id
        end
    end
    table.sort(heap, better)
    return heap
end

local function score_terms(file, entries, words, first, boundary, accepts, match)
    local scores = {}
    local counts = match ~= 'all' and #words > 1 and {} or nil
    local rarest, seed
    if match == 'all' and #words > 1 then
        for _, word in ipairs(words) do
            local entry = entries[word]
            if not entry then return scores end
            -- IDF decreases as the number of documents for a word increases.
            if not rarest or entry[4] > entries[rarest][4] then rarest = word end
        end
        seed = read_block(file, entries[rarest], first, boundary)
        local scanned = 0
        for id in pairs(seed) do
            scanned = scanned + 1
            if scanned % 1024 == 0 then control.check() end
            if accepts(id) then scores[id] = 0 end
        end
    end
    -- Accumulate terms in the same order for union and intersection searches,
    -- so a surviving document keeps the same BM25 score and tie-breaking.
    for _, word in ipairs(words) do
        control.check()
        if rarest and not next(scores) then break end
        local entry = entries[word]
        if entry then
            local matches = word == rarest and seed or read_block(file, entry, first, boundary)
            local scanned = 0
            if rarest then
                for id, score in pairs(scores) do
                    scanned = scanned + 1
                    if scanned % 1024 == 0 then control.check() end
                    local tf = matches[id]
                    scores[id] = tf and (score + entry[4] * tf) or nil
                end
                if word == rarest then seed = nil end
            else
                for id, tf in pairs(matches) do
                    scanned = scanned + 1
                    if scanned % 1024 == 0 then control.check() end
                    if accepts(id) then
                        scores[id] = (scores[id] or 0) + entry[4] * tf
                        if counts then counts[id] = (counts[id] or 0) + 1 end
                    end
                end
            end
        end
    end
    return scores, counts
end

local function contains_literal(text, literal, left_boundary, right_boundary)
    if text == '' then return false end
    text = text:lower()
    local offset = 1
    while true do
        local first, last = text:find(literal, offset, true)
        if not first then return false end
        if (not left_boundary or first == 1 or not text:sub(first - 1, first - 1):match('[%w_$]'))
            and (not right_boundary or not text:sub(last + 1, last + 1):match('[%w_$]')) then
            return true
        end
        offset = first + 1
    end
end

local function boost_candidates(file, header, first, boundary, scores, counts, words, terms, literal)
    local exact = {}
    if not header.passages or #words == 0 or literal == '' or not next(scores) then return exact end
    local strength = 0
    for _, word in ipairs(words) do
        local entry = header.words[word]
        if not entry then return exact end
        strength = strength + entry[4]
    end
    -- Group by block so each compressed passage is read at most once per query.
    local groups, scanned = {}, 0
    for id in pairs(scores) do
        scanned = scanned + 1
        if scanned % 128 == 0 then control.check() end
        if not counts or counts[id] == #words then
            local blocks = header.passages[header.locations[id][1]]
            local offset = id - blocks[1]
            local entry = blocks[2 + math.floor(offset / PASSAGE_BLOCK)]
            local group = groups[entry]
            if not group then group = {}; groups[entry] = group end
            group[#group + 1] = id
        end
    end
    if not next(groups) then return exact end
    local decoder = xcompress.new_decompressor()
    local left_boundary, right_boundary = literal:sub(1, 1):match('[%w_$]'), literal:sub(-1):match('[%w_$]')
    for entry, ids in pairs(groups) do
        control.check()
        local data = read_data(file, entry, first, boundary)
        local passages = cmsgpack.unpack(assert(decoder:deflate(data, entry[4]), 'corrupt BM25 passages'))
        for _, id in ipairs(ids) do
            local location = header.locations[id]
            local offset = id - header.passages[location[1]][1]
            local passage = passages[1 + offset % PASSAGE_BLOCK]
            local best
            for _, text in ipairs({location[2], header.files[location[1]], passage[1], passage[2]}) do
                if not exact[id] and contains_literal(text, literal, left_boundary, right_boundary) then exact[id] = true end
                if #words > 1 and best ~= 0 and text ~= '' then
                    local gap = collect.gap(text, terms, #words)
                    if gap and (not best or gap < best) then best = gap end
                end
            end
            if best then scores[id] = scores[id] + strength / (1 + best) end
        end
    end
    decoder:close()
    return exact
end

-- Use the existing symbol and path tables. Prefix hints change ranking only.
local function boost_prefix(header, scores, words, prefix)
    if not prefix or prefix == '' then return end
    prefix = prefix:lower()
    local strength = 0
    for _, word in ipairs(words) do
        local entry = header.words[word]
        if entry then strength = strength + entry[4] end
    end
    strength = math.max(strength, 1)
    local path_scores, scanned = {}, 0
    local directory = '/' .. prefix .. '/'
    for id, score in pairs(scores) do
        scanned = scanned + 1
        if scanned % 128 == 0 then control.check() end
        local location = header.locations[id]
        local file_id = location[1]
        local weight = path_scores[file_id]
        if not weight then
            local path = header.files[file_id]:lower()
            local stem = path:match('[^/]+$'):gsub('%.[^%.]+$', '')
            if stem == prefix then weight = 4
            elseif ('/' .. path):find(directory, 1, true) then weight = 3
            elseif stem:sub(1, #prefix) == prefix and stem:sub(#prefix + 1, #prefix + 1):match('[_%.%-]') then
                weight = 1
            else weight = 0 end
            path_scores[file_id] = weight
        end
        local owner = location[2]:match('([^.:]+)[.:]+[^.:]+$')
        if owner and owner:lower() == prefix then weight = 5 end
        if weight > 0 then scores[id] = score + weight * strength end
    end
end

local function search_file(index, file, query, options, limit)
    local header, first, boundary = open_header(file)
    assert(header.stamp == snapshot.stamp(index), 'BM25 index is stale; rebuild it')
    local scope, allowed = scope_key(index, options.path), {}
    local function in_scope(id)
        if not scope then return true end
        local file_id = header.locations[id][1]
        if allowed[file_id] == nil then allowed[file_id] = paths.contains(scope, header.files[file_id]) end
        return allowed[file_id]
    end
    local accepts = in_scope
    if options.accept then
        local accepted = {}
        accepts = function(id)
            if accepted[id] == nil then
                local location = header.locations[id]
                accepted[id] = not not (in_scope(id)
                    and options.accept(header.files[location[1]], location[2], location[5]))
            end
            return accepted[id]
        end
    end
    local words, terms = {}, collect.tokenize(query)
    for token in pairs(terms) do words[#words + 1] = token end
    table.sort(words)
    local scores, counts = score_terms(file, header.words, words, first, boundary, accepts, options.match)
    local mark = string.char(96)
    local literal = query:match('^%s*(.-)%s*$'):gsub('^' .. mark .. '+', ''):gsub(mark .. '+$', ''):lower()
    local key = literal:gsub('\\', '/')
    local entry = header.exact[key]
    local exact = entry and read_block(file, entry, first, boundary) or {}
    local literal_matches = boost_candidates(file, header, first, boundary, scores, counts, words, terms, literal)
    if options.match ~= 'all' or #words == 0 then
        for id in pairs(exact) do if accepts(id) then scores[id] = scores[id] or 0 end end
    end
    boost_prefix(header, scores, words, options.prefix)
    local results = {}
    for rank_number, id in ipairs(rank(scores, exact, literal_matches, limit)) do
        local location = header.locations[id]
        results[rank_number] = {path = header.files[location[1]], symbol = location[2],
            start_line = location[3], end_line = location[4], score = scores[id], kind = location[5]}
    end
    return results
end

function M.search(index, file, query, options)
    assert(type(query) == 'string', 'BM25 query must be a string')
    options = options or {}
    assert(options.match == nil or options.match == 'any' or options.match == 'all',
        'BM25 match must be any or all')
    assert(options.prefix == nil or type(options.prefix) == 'string', 'BM25 prefix hint must be a string')
    local limit = options.limit == nil and 20 or options.limit
    assert(type(limit) == 'number' and limit >= 0 and limit < math.huge and limit % 1 == 0,
        'BM25 limit must be a nonnegative integer')
    if limit == 0 then return {} end
    local input = assert(io.open(output_path(file), 'rb'))
    local ok, result = pcall(search_file, index, input, query, options, limit)
    input:close()
    if not ok then error(result, 0) end
    return result
end

return M
