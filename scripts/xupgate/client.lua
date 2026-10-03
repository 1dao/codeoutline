-- Async calls must originate from a network-active MAIN state.
-- Public key is pinned by the application, never fetched from the update server.
local c,u=require('xupgate.common'),require('xutils')
local M={}
local function shell_path(path)
    assert(not path:find('[\r\n"%!&|<>^$;()]') and not path:find(string.char(96),1,true),'installation path contains shell metacharacters')
    if package.config:sub(1,1)=='\\' then return '"' .. path .. '"' end
    assert(not path:find("'",1,true),'unsupported installation path')
    return "'" .. path .. "'"
end
local function command_ok(command)
    local ok=os.execute(command);return ok==true or ok==0
end
-- A running process renews its lease; pruning keeps leased versions. A lease
-- left by a crashed process expires.
local LEASE_TTL,LEASE_RENEW,LEGACY_GRACE=3*86400,600,7*86400
local function token()
    return u.sha256_hex(tostring(os.time()) .. tostring(os.clock()) .. tostring({}) .. tostring(math.random())):sub(1,16)
end
-- Returns nil outside an update directory (the initial installation is never pruned).
function M.lease(files_root)
    local root,identity=files_root:gsub('\\','/'):match('^(.*)/versions/(%x+)/files/?$')
    if not root or #identity~=64 then return nil end
    local path=root .. '/leases/' .. identity .. '-' .. token()
    local renewed,lease=0,{}
    function lease.renew(force)
        local now=os.time()
        if force or now-renewed>=LEASE_RENEW then renewed=now;pcall(c.write,path,now .. '\n')end
    end
    function lease.release()os.remove(path)end
    lease.renew(true)
    return lease
end
function M.open(config)
    assert(c.id(config.project) and c.id(config.platform),'invalid project/platform')
    assert(type(config.publicKey)=='string','pinned publicKey required')
    assert(config.minimumSequence==nil or (type(config.minimumSequence)=='number' and config.minimumSequence>=0 and config.minimumSequence%1==0),'invalid minimumSequence')
    local base=assert(config.url):gsub('/+$','')
    assert(base:match('^https://') or (config.allowLocalHttp and (base:match('^http://127%.0%.0%.1:%d+$') or base:match('^http://localhost:%d+$'))),'HTTPS required outside explicit loopback development')
    assert(c.id(config.channel or 'stable'),'invalid channel')
    assert(u.mkdir_p(config.directory))
    local root=assert(u.realpath(config.directory)):gsub('\\','/') .. '/' .. config.project
    assert(u.mkdir_p(root .. '/versions'))
    local api={}
    local function state()
        local data=c.read(root .. '/current.json',1048576)
        if not data then
            assert(not u.stat(root .. '/current.json').exists,'local state unreadable')
            return {schema=1,highSequence=config.minimumSequence or 0}
        end
        local value=assert(c.decode_json(data),'corrupt local state')
        assert(value.schema==1 and type(value.highSequence)=='number' and value.highSequence>=0 and value.highSequence%1==0,'invalid local state')
        value.highSequence=math.max(value.highSequence,config.minimumSequence or 0)
        assert(not value.current or (type(value.current)=='string' and #value.current==64 and value.current:match('^[0-9a-f]+$')),'invalid current')
        assert(not value.previous or (type(value.previous)=='string' and #value.previous==64 and value.previous:match('^[0-9a-f]+$')),'invalid previous')
        return value
    end
    local function save(value)c.atomic(root .. '/current.json',assert(u.json_pack(value)))end
    local function locked(fn)
        local lock=root .. '/update.lock'
        local command='mkdir ' .. shell_path(lock)
        command=command .. (package.config:sub(1,1)=='\\' and ' 2>nul' or ' 2>/dev/null')
        assert(command_ok(command),'another update is running; inspect stale update.lock after a crashed updater')
        local ok,result=pcall(fn)
        assert(u.rmtree(lock))
        if not ok then error(result) end
        return result
    end
    -- Remove versions other than keep that no live process leases, then the
    -- runtime cache, which only feeds installation.
    local function prune(keep)
        local now,busy=os.time(),{}
        for _,entry in ipairs(u.list_dir(root .. '/leases') or {})do
            local path=root .. '/leases/' .. entry.name
            local identity=entry.name:match('^(%x+)%-%x+$')
            local info=u.stat(path)
            if identity and info and info.exists and now-(info.mtime or 0)<LEASE_TTL then busy[identity]=true
            else os.remove(path)end
        end
        for _,entry in ipairs(u.list_dir(root .. '/versions') or {})do
            local removable=entry.dir and not keep[entry.name] and not busy[entry.name]
            -- Versions predating leases may still run unseen: delete them only
            -- after a grace period counted from the first prune that saw them.
            if removable and config.leased and not config.leased(root .. '/versions/' .. entry.name .. '/files') then
                local marker=root .. '/retired/' .. entry.name
                local info=u.stat(marker)
                if not (info and info.exists) then c.write(marker,now .. '\n');removable=false
                else removable=now-(info.mtime or now)>=(config.legacyGrace or LEGACY_GRACE) end
            end
            if removable then
                -- Moving first keeps a half-deleted tree out of versions/.
                assert(u.mkdir_p(root .. '/trash'))
                os.rename(root .. '/versions/' .. entry.name,root .. '/trash/' .. entry.name .. '-' .. token())
            end
        end
        for _,entry in ipairs(u.list_dir(root .. '/trash') or {})do u.rmtree(root .. '/trash/' .. entry.name)end
        for _,entry in ipairs(u.list_dir(root .. '/retired') or {})do
            if not u.stat(root .. '/versions/' .. entry.name).exists then os.remove(root .. '/retired/' .. entry.name)end
        end
        if u.stat(root .. '/runtime-cache').exists then u.rmtree(root .. '/runtime-cache')end
    end
    local function verified(envelope)
        local m=c.manifest(envelope,config.publicKey)
        assert(m.project==config.project and m.platform==config.platform,'manifest target mismatch')
        return m
    end
    function api.cache_runtime(envelope, data, scripts)
        local full = verified(envelope)
        local reference = assert(scripts.runtimeRelease, 'runtime release reference missing')
        assert(scripts.kind == 'scripts' and full.kind ~= 'scripts' and full.version == reference.version
            and full.sequence == reference.sequence and full.sha256 == reference.sha256, 'runtime release mismatch')
        local source_files = {}
        for _, file in ipairs(c.bundle(data, full)) do source_files[file.path] = file.data end
        for path, hash in pairs(scripts.runtimeFiles) do
            assert(source_files[path] and u.sha256_hex(source_files[path]) == hash, 'runtime release file mismatch')
        end
        return locked(function()
            local directory = root .. '/runtime-cache/' .. reference.sha256 .. '/files'
            for path in pairs(scripts.runtimeFiles) do c.write(directory .. '/' .. path, source_files[path]) end
            return directory
        end)
    end
    function api.current()
        local s=state();if not s.current then return nil end
        local dir=root .. '/versions/' .. s.current
        local envelope=c.decode_json(assert(c.read(dir .. '/manifest.json',1048576)))
        local m=verified(envelope)
        assert(u.stat(dir .. '/complete').exists,'installation incomplete')
        assert(u.sha256_hex(envelope.payload)==s.current,'invalid active identity')
        local files=c.bundle(assert(c.read(dir .. '/bundle.json')),m)
        for _,f in ipairs(files)do assert(c.read(dir .. '/files/' .. f.path)==f.data,'installed file changed')end
        for path, hash in pairs(m.runtimeFiles or {}) do
            assert(u.sha256_hex(assert(c.read(dir .. '/files/' .. path), 'runtime file missing')) == hash, 'installed runtime changed')
        end
        return {version=m.version,sequence=m.sequence,root=dir .. '/files',entry=m.entry,runtime=m.runtime,sha256=m.sha256,kind=m.kind or 'full'}
    end
    function api.install(envelope,data)
        local m=verified(envelope);local files=c.bundle(data,m)
        local identity=u.sha256_hex(envelope.payload)
        return locked(function()
            local s=state()
            assert(m.sequence>=s.highSequence,'downgrade/replay rejected; use explicit local rollback')
            if s.current==identity then return api.current()end
            if m.sequence==s.highSequence and s.current then assert(s.previous==identity,'different content at previously accepted sequence')end
            local dir=root .. '/versions/' .. identity
            if not u.stat(dir .. '/complete').exists then
                assert(u.mkdir_p(dir .. '/files'))
                for _,f in ipairs(files)do
                    c.write(dir .. '/files/' .. f.path,f.data)
                    if f.executable and package.config:sub(1,1)~='\\' then assert(command_ok('chmod 755 ' .. shell_path(dir .. '/files/' .. f.path)),'chmod failed')end
                end
                if m.kind == 'scripts' then
                    local candidates = { config.runtimeDirectory }
                    if s.current then candidates[#candidates + 1] = root .. '/versions/' .. s.current .. '/files' end
                    if s.previous then candidates[#candidates + 1] = root .. '/versions/' .. s.previous .. '/files' end
                    if m.runtimeRelease then candidates[#candidates + 1] = root .. '/runtime-cache/' .. m.runtimeRelease.sha256 .. '/files' end
                    local runtime_root
                    for _, candidate in ipairs(candidates) do
                        local matches = true
                        for path, hash in pairs(m.runtimeFiles) do
                            local bytes = c.read(candidate .. '/' .. path)
                            if not bytes or u.sha256_hex(bytes) ~= hash then matches = false; break end
                        end
                        if matches then runtime_root = candidate; break end
                    end
                    assert(runtime_root, 'compatible local runtime missing; install a full update first')
                    for path, hash in pairs(m.runtimeFiles) do
                        local bytes = assert(c.read(runtime_root .. '/' .. path))
                        assert(u.sha256_hex(bytes) == hash, 'runtime changed during installation')
                        c.write(dir .. '/files/' .. path, bytes)
                        if package.config:sub(1,1) ~= '\\' and (path == m.runtime or path:match('^bin/')) then
                            assert(command_ok('chmod 755 ' .. shell_path(dir .. '/files/' .. path)), 'chmod failed')
                        end
                    end
                end
                c.write(dir .. '/bundle.json',data)
                c.write(dir .. '/manifest.json',assert(u.json_pack(envelope)))
                c.atomic(dir .. '/complete','1\n')
            end
            if config.validate then assert(config.validate(dir .. '/files',m),'project health validation failed')end
            local previous=config.keepPrevious~=false and s.current or nil
            save({schema=1,highSequence=math.max(s.highSequence,m.sequence),previous=previous,current=identity})
            local ok,result=pcall(api.current)
            if not ok then save(s);error(result)end
            -- Cleanup never fails an installation that is already active.
            if config.prune then pcall(prune,{[identity]=true,[previous or identity]=true})end
            return result
        end)
    end
    function api.use_initial()
        return locked(function()
            local s=state()
            save({schema=1,highSequence=s.highSequence,previous=s.current})
            return {initial=true}
        end)
    end
    function api.rollback()
        return locked(function()
            local s=state();assert(s.previous,'no previous version')
            save({schema=1,highSequence=s.highSequence,current=s.previous,previous=s.current})
            local ok,result=pcall(api.current)
            if not ok then save(s);error(result)end
            return result
        end)
    end
    function api.check(callback)
        local http=config.http or dofile('scripts/core/share/xhttp_client.lua')
        http.request({url=base .. '/api/v1/projects/' .. config.project .. '/channels/' .. (config.channel or 'stable') .. '/' .. config.platform,timeout_ms=15000,max_redirects=0,verify=true,ca_file=config.caFile},function(err,resp)
            if err then callback(err);return end
            if resp.status==404 then callback(nil,nil);return end
            if resp.status~=200 then callback('update check HTTP ' .. resp.status);return end
            local ok,m=pcall(function()return verified(assert(c.decode_json(resp.body)))end)
            if not ok then callback(tostring(m));return end
            local loaded,s=pcall(state)
            if not loaded then callback(tostring(s));return end
            if m.sequence<=s.highSequence then callback(nil,nil);return end
            callback(nil,{manifest=m,envelope=c.decode_json(resp.body)})
        end)
    end
    function api.update(callback)
        api.check(function(err,update)
            if err or not update then callback(err,update);return end
            local http=config.http or dofile('scripts/core/share/xhttp_client.lua')
            http.request({url=base .. '/packages/' .. update.manifest.sha256 .. '.json',timeout_ms=120000,max_redirects=0,verify=true,ca_file=config.caFile,decompress=false},function(download_error,resp)
                if download_error then callback(download_error);return end
                if resp.status~=200 then callback('package HTTP ' .. resp.status);return end
                local ok,result=pcall(api.install,update.envelope,resp.body)
                if not ok and update.manifest.runtimeRelease and tostring(result):find('compatible local runtime missing', 1, true) then
                    local scripts_data = resp.body
                    local reference = update.manifest.runtimeRelease
                    http.request({url=base .. '/api/v1/projects/' .. config.project .. '/releases/' .. reference.version .. '/' .. config.platform,
                        timeout_ms=15000,max_redirects=0,verify=true,ca_file=config.caFile},function(reference_error,reference_response)
                        if reference_error then callback(reference_error);return end
                        if reference_response.status~=200 then callback('runtime reference HTTP ' .. reference_response.status);return end
                        local valid, envelope = pcall(function()
                            local envelope = assert(c.decode_json(reference_response.body))
                            local full = verified(envelope)
                            assert(full.kind ~= 'scripts' and full.version == reference.version and full.sequence == reference.sequence
                                and full.sha256 == reference.sha256, 'runtime reference mismatch')
                            return envelope
                        end)
                        if not valid then callback(tostring(envelope));return end
                        http.request({url=base .. '/packages/' .. reference.sha256 .. '.json',timeout_ms=120000,max_redirects=0,
                            verify=true,ca_file=config.caFile,decompress=false},function(runtime_error,runtime_response)
                            if runtime_error then callback(runtime_error);return end
                            if runtime_response.status~=200 then callback('runtime package HTTP ' .. runtime_response.status);return end
                            local cached, failure = pcall(api.cache_runtime, envelope, runtime_response.body, update.manifest)
                            if not cached then callback(tostring(failure));return end
                            local installed, current = pcall(api.install, update.envelope, scripts_data)
                            callback(not installed and tostring(current) or nil, installed and current or nil)
                        end)
                    end)
                    return
                end
                callback(not ok and tostring(result) or nil,ok and result or nil)
            end)
        end)
    end
    return api
end
return M
