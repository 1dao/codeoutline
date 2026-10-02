-- Update commands and bootstrap selection. Installation stays in Lua.
local source=assert(xutils.realpath(debug.getinfo(1,'S').source:sub(2))):gsub('\\','/')
local install=assert(source:match('^(.*)/scripts/codeoutline/[^/]+$'))
package.path=install .. '/scripts/?.lua;' .. package.path
local c,u=require('xupgate.common'),require('xutils')
local M={}
local function config(options)
    options=options or {}
    local build=c.decode_json(c.read(install .. '/build-info.json')) or {}
    local home=os.getenv('USERPROFILE') or os.getenv('HOME')
    local target=os.getenv('CODEOUTLINE_UPDATE_TARGET') or build.target
    if not target then target=package.config:sub(1,1)=='\\' and 'win32-x64' or 'linux-x64' end
    local cfg={
        project=os.getenv('CODEOUTLINE_UPDATE_PROJECT') or 'codeoutline',
        platform=target,url=os.getenv('CODEOUTLINE_UPDATE_URL') or 'https://43.133.255.193:51215',
        channel=options.channel or os.getenv('CODEOUTLINE_UPDATE_CHANNEL') or 'stable',
        publicKey=assert(c.read(os.getenv('CODEOUTLINE_UPDATE_PUBLIC_KEY') or install .. '/keys/update-public.pem'),'update public key missing'),
        caFile=os.getenv('CODEOUTLINE_UPDATE_CA') or install .. '/keys/update-ca.crt',
        directory=os.getenv('CODEOUTLINE_UPDATE_DIR') or assert(home,'set CODEOUTLINE_UPDATE_DIR') .. '/.codeoutline/updates',
        minimumSequence=tonumber(os.getenv('CODEOUTLINE_UPDATE_MIN_SEQUENCE')) or build.updateSequence or 0,
        http=require('xupgate.http_client'),
    }
    cfg.validate=function(root,m)
        local info=c.decode_json(c.read(root .. '/build-info.json'))
        assert(info and info.target==cfg.platform and info.version==m.version and info.updateSequence==m.sequence,'package platform/version/sequence mismatch')
        assert(m.entry=='scripts/codeoutline/command.lua','invalid CodeOutline entry')
        local expected=cfg.platform=='win32-x64' and 'bin/xnet.exe' or 'bin/xnet'
        assert(m.runtime==expected,'package runtime missing')
        local function quote(s)
            assert(not s:find('[\r\n"%!&|<>^$;()]') and not s:find(string.char(96),1,true),'unsafe install path')
            if package.config:sub(1,1)=='\\' then return '"' .. s .. '"' end
            assert(not s:find("'",1,true),'unsafe install path');return "'" .. s .. "'"
        end
        local command=quote(root .. '/' .. m.runtime) .. ' ' .. quote(root .. '/' .. m.entry) .. ' LOG_STDERR=1 LOG_FILE=0 LOG_LEVEL=ERROR --version'
        if package.config:sub(1,1)=='\\' then command='"' .. command .. '"' end
        local pipe=assert(io.popen(command));local output=pipe:read('a');local ok=pipe:close()
        assert(ok and output:match('^%s*(.-)%s*$')==m.version,'updated runtime health check failed')
        return true
    end
    return cfg
end
function M.run(action,options)
    local api=require('xupgate.client').open(config(options))
    local function selected()
        local ok,current=pcall(api.current)
        if not ok then io.stderr:write('codeoutline: installed update invalid; using initial version\n')end
        return ok and current and current.root or install
    end
    local function finish(err,result)
        if action=='select' then
            if err then io.stderr:write('codeoutline: update unavailable; using local version\n')end
            io.write(selected(),'\n');io.stdout:flush();xthread.stop(0)
        else
            io.write(assert(u.json_pack({ok=not err,error=err,result=result})),'\n');io.stdout:flush();xthread.stop(err and 1 or 0)
        end
    end
    return {__init=function()
        assert(xnet.init());xtimer.init(16)
        if action=='select' and os.getenv('CODEOUTLINE_AUTO_UPDATE')~='1' then finish(nil)
        elseif action=='rollback' then
            local ok,result=pcall(api.rollback)
            if not ok and tostring(result):find('no previous version',1,true)then ok,result=pcall(api.use_initial)end
            finish(not ok and tostring(result) or nil,ok and result or nil)
        elseif action=='current' then local ok,result=pcall(api.current);finish(not ok and tostring(result) or nil,ok and result or nil)
        elseif action=='check' then api.check(finish)
        else api.update(finish)end
    end,__uninit=function()xnet.uninit()end,__thread_handle=function()end}
end
if ...=='codeoutline.updater' then return M end
local action='select'
for _,arg in ipairs(arg or {})do local v=arg:match('^ACTION=(.+)$');if v then action=v end end
return M.run(action)
