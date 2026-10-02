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
    local function verified(envelope)
        local m=c.manifest(envelope,config.publicKey)
        assert(m.project==config.project and m.platform==config.platform,'manifest target mismatch')
        return m
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
        return {version=m.version,sequence=m.sequence,root=dir .. '/files',entry=m.entry,runtime=m.runtime,sha256=m.sha256}
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
                c.write(dir .. '/bundle.json',data)
                c.write(dir .. '/manifest.json',assert(u.json_pack(envelope)))
                c.atomic(dir .. '/complete','1\n')
            end
            if config.validate then assert(config.validate(dir .. '/files',m),'project health validation failed')end
            save({schema=1,highSequence=math.max(s.highSequence,m.sequence),previous=s.current,current=identity})
            local ok,result=pcall(api.current)
            if not ok then save(s);error(result)end
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
                callback(not ok and tostring(result) or nil,ok and result or nil)
            end)
        end)
    end
    return api
end
return M
