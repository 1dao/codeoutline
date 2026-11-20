local M = {}
local foreign = require('codeoutline.analysis.foreign')

local function lua_base_symbol(source, name, runtime)
    if source:match('#%s*define%s+LJLIB_MODULE_base%f[^%w_]') then
        if runtime ~= 'embedded' then
            return nil, source:match('\n[ \t]*LJLIB_CF%([ \t]*()' .. name .. '[ \t]*%)[ \t\r]*\n')
        end
    elseif runtime ~= 'luajit' then
        local loader = source:match('luaopen_base%s*%([^)]*%)%s*{([^}]+)}')
        local entries = source:match('luaL_Reg%s+base_funcs%s*%[%s*%]%s*=%s*{(.-)}%s*;')
        if entries and loader and loader:match('lua_pushglobaltable%s*%([^)]*%)[^;]*;%s*luaL_setfuncs%s*%([^,]+,%s*base_funcs%s*,') then
            return entries:match('{%s*"' .. name .. '"%s*,%s*([%a_][%w_]*)%s*}')
        end
    end
end

local function python_extension_symbol(source, name, loader, module)
    local init = source:match('%f[%w_]' .. loader .. '%s*%([^)]*%)%s*{([^}]+)}')
    local definition = init and init:match('return%s+PyModule_Create%s*%(%s*&%s*([%a_][%w_]*)%s*%)')
    local body = definition and source:match('PyModuleDef%s+' .. definition .. '%s*=%s*{(.-)}%s*;')
    if not body then return end
    local declared = body:match('%.m_name%s*=%s*"([^"]+)"') or body:match('PyModuleDef_HEAD_INIT%s*,%s*"([^"]+)"')
    if declared ~= module then return end
    local methods = body:match('%.m_methods%s*=%s*([%a_][%w_]*)')
        or body:match('PyModuleDef_HEAD_INIT%s*,[^,]+,[^,]+,[^,]+,%s*([%a_][%w_]*)')
    local entries = methods and source:match('PyMethodDef%s+' .. methods .. '%s*%[[^%]]*%]%s*=%s*{(.-)}%s*;')
    return entries and entries:match('{%s*"' .. name .. '"%s*,%s*([%a_][%w_]*)%s*,')
end

local function python_extension_import(doc, c, offset, max_bytes)
    -- Use explicit, single-name imports at module scope. Without Python scope
    -- analysis, an import outside the call's scope may be shadowed.
    if c.from ~= 0 or #doc.source > max_bytes then return end
    local binding = c.recv or c.name
    local module, member
    local line_start = doc.lines[doc:position(offset).line + 1]
    if c.recv then
        local prefix = doc.source:sub(line_start + 1, c.first)
        local before = prefix:match('^(.-)%f[%w_]' .. binding .. '%s*%.%s*$')
        if not before or before:match('%.%s*$') then return end
    end
    local imports = {}
    for _, imp in ipairs(doc:parse().imports) do imports[imp.line] = true end
    local line_number = 0
    for line in doc.source:sub(1, line_start):gmatch('([^\n]*)\n') do
        line_number = line_number + 1
        local path, symbol, alias
        if imports[line_number] and c.recv then
            path, alias = line:match('^import%s+([%a_][%w_]*)%s+as%s+([%a_][%w_]*)%s*$')
            if not path then path = line:match('^import%s+([%a_][%w_]*)%s*$') end
        elseif imports[line_number] then
            path, symbol, alias = line:match('^from%s+([%a_][%w_]*)%s+import%s+([%a_][%w_]*)%s+as%s+([%a_][%w_]*)%s*$')
            if not path then path, symbol = line:match('^from%s+([%a_][%w_]*)%s+import%s+([%a_][%w_]*)%s*$') end
        end
        if path and (alias or symbol or path) == binding then
            if module then return end
            module, member = path, symbol or c.name
        elseif module and line:match('%f[%w_]' .. binding .. '%f[^%w_]')
            and not line:match('^' .. binding .. (c.recv and '%.[%w_]+%s*%(' or '%s*%(')) then
            return
        end
    end
    return module, member
end

local function directory(path)
    return path:match('^(.*)/') or ''
end

local jni_primitives = {
    boolean = 'Z', byte = 'B', char = 'C', short = 'S', int = 'I',
    long = 'J', float = 'F', double = 'D', void = 'V', unit = 'V',
}

local function jni_signature(signature, name, language)
    local prefix, params, suffix = signature:match('^(.-)%f[%w_]' .. name .. '%s*%(([^()]*)%)(.*)$')
    if not params then return end
    local return_type = language == 'java' and prefix:match('([%a]+)%s*$') or suffix:match('^%s*:%s*([%a]+)%s*$')
    if not return_type or not jni_primitives[return_type:lower()] then return end
    local types = {}
    if not params:match('^%s*$') then
        for param in (params .. ','):gmatch('(.-),') do
            local kind = language == 'java' and param:match('^%s*([%a]+)%s+[%w_]+%s*$')
                or param:match('^%s*[%w_]+%s*:%s*([%a]+)%s*$')
            local code = kind and jni_primitives[kind:lower()]
            if not code or code == 'V' then return end
            types[#types + 1] = code
        end
    end
    return '%(' .. table.concat(types) .. '%)' .. jni_primitives[return_type:lower()]
end

local function jni_registered_symbol(source, owner, method, descriptor)
    local class_name = owner:gsub('%.', '/')
    local load = source:match('%f[%w_]JNI_OnLoad%s*%([^)]*%)%s*{(.-)\n}')
    if not load then return end
    local class = load:match('jclass%s+([%a_][%w_]*)%s*=%s*[%w_]+%s*%-%>%s*FindClass%s*%(%s*"'
        .. class_name .. '"%s*%)')
        or load:match('jclass%s+([%a_][%w_]*)%s*=%s*%(%*[%w_]+%)%s*%-%>%s*FindClass%s*%([^,]+,%s*"'
            .. class_name .. '"%s*%)')
    if not class then return end
    local entries = load:match('RegisterNatives%s*%(%s*' .. class .. '%s*,%s*([%a_][%w_]*)%s*,')
        or load:match('RegisterNatives%s*%([^,]+,%s*' .. class .. '%s*,%s*([%a_][%w_]*)%s*,')
    local table_body = entries and source:match('JNINativeMethod%s+' .. entries .. '%s*%[[^%]]*%]%s*=%s*{(.-)}%s*;')
    if not table_body then return end
    local result
    for target in table_body:gmatch('{%s*"' .. method .. '"%s*,%s*"' .. descriptor
        .. '"%s*,%s*%(void%s*%*%)%s*&?%s*([%a_][%w_]*)%s*}') do
        if result then return end
        result = target
    end
    return result
end

local function declared_native(V, doc, c, targets, f, source_doc, locate, max_bytes)
    local language = V.files[f].language
    local result, seen, limited = {}, {}, false
    local declarations = c.decl and { V.id_of[f][c.decl] } or targets
    for _, id in ipairs(declarations) do
        local guest = V.node_file[id]
        local node = V.nodes[id]
        local guest_doc = guest == f and doc or ((V.files[guest].size or 0) <= max_bytes and source_doc(V, guest))
        if guest_doc and #guest_doc.source <= max_bytes and node.kind == 'method' then
            local source = guest_doc.source
            local line = guest_doc.lines[node.line]
            local prefix = line and source:sub(math.max(1, line - 2048), guest_doc.lines[node.line + 1] or #source):gsub('%s+$', '')
            local symbol, library, jni_owner
            if prefix and language == 'csharp' then
                local lib, options, declaration = prefix:match('%[%s*DllImport%s*%(%s*"([^"]+)"([^%]]-)%)%s*%]([^;{}]*);?$')
                if not lib then
                    lib, options, declaration = prefix:match('%[%s*LibraryImport%s*%(%s*"([^"]+)"([^%]]-)%)%s*%]([^;{}]*);?$')
                end
                if lib and declaration:match('%f[%w_]' .. c.name .. '%s*%(') then
                    symbol = options:match('EntryPoint%s*=%s*"([%a_][%w_]*)"')
                    if not symbol and not options:find('EntryPoint', 1, true) then symbol = c.name end
                    library = lib:gsub('%.dll$', ''):gsub('%.so$', ''):gsub('%.dylib$', '')
                end
            elseif prefix and (language == 'java' or language == 'kotlin') then
                local modifier = language == 'java' and 'native' or 'external'
                local declaration = prefix:match('([^;{}\n]+);?$') or ''
                if declaration:match('%f[%w_]' .. modifier .. '%f[^%w_]')
                    and declaration:match('%f[%w_]' .. c.name .. '%s*%(') then
                    local package = source:match('^%s*package%s+([%a][%w%.]*)')
                        or source:match('\n%s*package%s+([%a][%w%.]*)')
                    local owner = node.qualified:sub(1, -#c.name - 2)
                    local class = package and owner:sub(#package + 2) or owner
                    if class:match('^[%a_][%w_]*$') and owner == (package and package .. '.' or '') .. class then
                        local overloads = 0
                        for _, other in ipairs(V.files[guest].nodes) do
                            if other.qualified == node.qualified then overloads = overloads + 1 end
                        end
                        if overloads == 1 then
                            jni_owner = owner
                            symbol = 'Java_' .. owner:gsub('_', '_1'):gsub('%.', '_') .. '_' .. c.name:gsub('_', '_1')
                        end
                    end
                end
            end
            for _, target in ipairs(symbol and foreign.entrypoints(V, symbol) or {}) do
                local host = V.node_file[target]
                local basename = V.files[host].path:match('([^/]+)%.[^./]+$')
                if not seen[target] and (not library or basename == library or basename == 'lib' .. library) then
                    seen[target] = true
                    if #result == 4 then limited = true; break end
                    if (V.files[host].size or 0) <= max_bytes and source_doc(V, host) then
                        result[#result + 1] = (locate(V, target))
                    else
                        limited = true
                    end
                end
            end
            local descriptor = jni_owner and jni_signature(node.sig or '', c.name, language)
            if descriptor then
                local hosts = {}
                for i, loader in ipairs(foreign.entrypoints(V, 'JNI_OnLoad')) do
                    if i > 4 then limited = true; break end
                    local host = V.node_file[loader]
                    if not hosts[host] then
                        hosts[host] = true
                        local host_doc = (V.files[host].size or 0) <= max_bytes and source_doc(V, host)
                        if not host_doc or #host_doc.source > max_bytes then
                            limited = true
                        else
                            local registered = jni_registered_symbol(host_doc.source, jni_owner, c.name, descriptor)
                            for _, target in ipairs(registered and V.by_name[registered] or {}) do
                                if not seen[target] and V.node_file[target] == host and V.nodes[target].kind == 'function' then
                                    if #result == 4 then limited = true; break end
                                    seen[target] = true
                                    result[#result + 1] = (locate(V, target))
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if #result > 0 then return result, limited end
end

local function go_definition(V, doc, c, f, source_doc, locate, max_bytes)
    if c.kind ~= 'member_call' or c.recv ~= 'C' or #doc.source > max_bytes then return end
    local imports_c = false
    for _, imp in ipairs(doc:parse().imports) do
        if imp.path == 'C' then
            local prefix = doc.source:sub(1, doc.lines[imp.line])
            local preamble = prefix:match('/%*(.-)%*/%s*$') or prefix:match('//([^\n]*)\r?\n%s*$')
            imports_c = preamble and preamble:match('%f[%w_]' .. c.name .. '%s*%([^;]*%)%s*;')
            if imports_c then break end
        end
    end
    if not imports_c then return end
    local result, limited = {}, false
    for _, id in ipairs(foreign.entrypoints(V, c.name)) do
        local host = V.node_file[id]
        local rec = V.files[host]
        if rec.language == 'c' and rec.path:match('%.c$') and directory(rec.path) == directory(V.files[f].path) then
            if #result == 4 then limited = true; break end
            if (rec.size or 0) <= max_bytes and source_doc(V, host) then
                result[#result + 1] = (locate(V, id))
            else
                limited = true
            end
        end
    end
    if #result > 0 then return result, limited end
end

local function node_definition(V, doc, c, f, source_doc, locate, max_bytes)
    if c.from ~= 0 or c.kind ~= 'member_call' or not c.recv or not c.recv:match('^[%a_][%w_]*$')
        or #doc.source > max_bytes then return end
    local line_start = doc.lines[doc:position(c.first).line + 1]
    local prefix = doc.source:sub(line_start + 1, c.first)
    if not prefix:match('^%s*' .. c.recv .. '%s*%.%s*$') then return end
    local files = {}
    for _, imp in ipairs(doc:parse().imports) do
        if imp.path:match('^%./[%w_%-]+%.node$') then files[imp.line] = imp.path end
    end
    local addon, line_number
    line_number = 0
    for line in doc.source:sub(1, line_start):gmatch('([^\n]*)\n') do
        line_number = line_number + 1
        if line:match('%f[%w_]' .. c.recv .. '%f[^%w_]') then
            local bound = files[line_number] and line:match('^const%s+' .. c.recv .. '%s*=%s*require%s*%(')
            if not bound or addon then return end
            addon = files[line_number]:sub(3, -6)
        end
    end
    if not addon then return end
    local dir = directory(V.files[f].path)
    local stem = (dir == '' and '' or dir .. '/') .. addon
    local result = {}
    for _, extension in ipairs({ '.c', '.cc', '.cpp', '.cxx' }) do
        local host = V.file_index[stem .. extension]
        local host_doc = host and (V.files[host].size or 0) <= max_bytes and source_doc(V, host)
        if host_doc and #host_doc.source <= max_bytes then
            local source = host_doc.source
            local init = source:match('%f[%w_]NAPI_MODULE%s*%(%s*NODE_GYP_MODULE_NAME%s*,%s*([%a_][%w_]*)%s*%)')
            local body = init and source:match('%f[%w_]' .. init .. '%s*%([^)]*%)%s*{(.-)\n}')
            local callback, value
            if body then
                callback, value = body:match('napi_create_function%s*%([^,]+,%s*"' .. c.name
                    .. '"%s*,[^,]+,%s*([%a_][%w_]*)%s*,[^,]+,%s*&%s*([%a_][%w_]*)%s*%)')
                if callback and not body:match('napi_set_named_property%s*%([^,]+,%s*exports%s*,%s*"' .. c.name
                    .. '"%s*,%s*' .. value .. '%s*%)') then callback = nil end
                if not callback then
                    local descriptors = body:match('napi_define_properties%s*%([^,]+,%s*exports%s*,[^,]+,%s*([%a_][%w_]*)%s*%)')
                    local entries = descriptors and source:match('napi_property_descriptor%s+' .. descriptors .. '%s*%[[^%]]*%]%s*=%s*{(.-)}%s*;')
                    callback = entries and entries:match('{%s*"' .. c.name .. '"%s*,%s*NULL%s*,%s*([%a_][%w_]*)%s*,')
                end
            end
            if callback then
                for _, id in ipairs(V.by_name[callback] or {}) do
                    if V.node_file[id] == host and V.nodes[id].kind == 'function' then
                        result[#result + 1] = (locate(V, id))
                    end
                end
            end
        end
    end
    if #result > 0 then return result end
end

function M.resolve(V, doc, c, targets, f, offset, deps, source_doc, locate, max_bytes)
    if not c or not c.name:match('^[%a_][%w_]*$') then return end
    local language = V.files[f].language
    if language == 'java' or language == 'kotlin' or language == 'csharp' then
        return declared_native(V, doc, c, targets, f, source_doc, locate, max_bytes)
    end
    if language == 'go' then return go_definition(V, doc, c, f, source_doc, locate, max_bytes) end
    if language == 'javascript' or language == 'typescript' then
        return node_definition(V, doc, c, f, source_doc, locate, max_bytes)
    end
    if c.decl or (c.kind ~= 'call' and c.kind ~= 'member_call') then return end
    local loader, name, module
    if language == 'lua' then
        if c.kind ~= 'call' or c.evidence and c.evidence ~= '' then return end
        local bindings = require('codeoutline.analysis.lua.lua_bindings')
        if bindings.has_local_receiver(doc:tokens(), c.name, offset) then return end
        loader, name = 'luaopen_base', c.name
    elseif language == 'python' then
        module, name = python_extension_import(doc, c, offset, max_bytes)
        if not module then return end
        loader = 'PyInit_' .. module
    else
        return
    end
    local direct = deps(V, f)
    for _, id in ipairs(targets) do
        local target = V.node_file[id]
        if (language ~= 'lua' or not V.nodes[id]['local']) and (target == f or direct[target]) then return end
    end
    local result, seen, count, limited = {}, {}, 0, false
    for _, id in ipairs(foreign.entrypoints(V, loader)) do
        local host = V.node_file[id]
        if not seen[host] then
            seen[host], count = true, count + 1
            if count > 4 then limited = true; break end
            if (V.files[host].size or 0) <= max_bytes then
                local host_doc = source_doc(V, host)
                if host_doc and #host_doc.source <= max_bytes then
                    local symbol, start
                    if language == 'lua' then
                        symbol, start = lua_base_symbol(host_doc.source, name, V.js_context.lua.runtime)
                    else
                        symbol = python_extension_symbol(host_doc.source, name, loader, module)
                    end
                    if start then
                        result[#result + 1] = { uri = host_doc.uri, range = host_doc:range(start - 1, start - 1 + #name) }
                    end
                    for _, target in ipairs(symbol and V.by_name[symbol] or {}) do
                        if V.node_file[target] == host and V.nodes[target].kind == 'function' then
                            result[#result + 1] = (locate(V, target))
                        end
                    end
                else
                    limited = true
                end
            else
                limited = true
            end
        end
    end
    if #result > 0 then return result, limited end
end

return M
