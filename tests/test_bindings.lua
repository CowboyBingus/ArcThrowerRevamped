-- Exercise the first callbacks with real Windows FFI, outside the game.
local path, scenario = assert(arg[1]), assert(arg[2])
local ffi = require('ffi')
assert(ffi.os == 'Windows' and ffi.arch == 'x64', 'Windows x64 LuaJIT required')
assert(scenario == 'clean' or scenario == 'predeclared' or scenario == 'game-present')
if scenario == 'predeclared' then
    ffi.cdef [[void *GetModuleHandleA(const char *name);]]
    local kernel = ffi.load('kernel32')
    assert(type(kernel.GetModuleHandleA) == 'cdata')
    assert(kernel.GetModuleHandleA(nil) ~= nil, 'native binding must be callable')
end

local bindings, lookups = ffi, {}
local fixture, module_handle
if scenario == 'game-present' then
    -- Only the game handle is synthetic. Native process, timer and memory-read
    -- calls operate on this process and its zero-filled, unsupported image.
    fixture = ffi.new('uint8_t[?]', 0x755f90 + 16)
    module_handle = ffi.cast('void *(*)(const char *)', function(name)
        assert(ffi.string(name) == 'game.dll')
        return fixture
    end)
    bindings = setmetatable({load = function(name)
        local native = ffi.load(name)
        if name ~= 'kernel32' then return native end
        return setmetatable({}, {__index = function(_, symbol)
            local resolved = native[symbol] -- Requires a real declaration.
            lookups[symbol] = (lookups[symbol] or 0) + 1
            if symbol == 'GetModuleHandleA' then
                assert(type(resolved) == 'cdata' and resolved(nil) ~= nil)
                assert(resolved('game.dll') == nil, 'run outside the game')
                return module_handle
            end
            return resolved
        end})
    end}, {__index = ffi})
end

local lines, updates, renders = {}, 0, 0
local env = setmetatable({}, {__index = _G})
env._G = env
env.require = function(name)
    if name == 'ffi' then return bindings end
    return require(name)
end
env.CowboyBingusModLoader = {api = 1, open_log = function(name)
    assert(name == 'ArcThrowerAuto.log')
    return {write = function(_, text) lines[#lines + 1] = text end,
            flush = function() end}
end}
env.update = function(dt)
    assert(dt == 0.016); updates = updates + 1
    return 1, nil, 3
end
env.render = function(value)
    assert(value == 'frame'); renders = renders + 1
    return 'rendered', nil, 7
end
local function load_addon() setfenv(assert(loadfile(path)), env)() end
load_addon()
assert(#lines == 1 and lines[1]:find('initialised', 1, true))
for _ = 1, 2 do
    local a, b, c = env.update(0.016)
    assert(a == 1 and b == nil and c == 3)
    local x, y, z = env.render('frame')
    assert(x == 'rendered' and y == nil and z == 7)
end
assert(updates == 2 and renders == 2)
assert(#lines == 2, table.concat(lines))
local expected = scenario == 'game-present' and 'Unsupported game build; the addon is disabled.'
    or 'game.dll not loaded'
assert(lines[2]:find(expected, 1, true), table.concat(lines))
assert(not lines[2]:find('kernel32 bindings unavailable', 1, true))
assert(not lines[2]:find('missing declaration', 1, true))
if scenario == 'game-present' then
    assert(lookups.GetCurrentProcess == 1, 'initialize process once')
    assert(lookups.QueryPerformanceFrequency == 1, 'initialize timer once')
    assert(lookups.ReadProcessMemory == 1, 'retain the native game-build check')
    assert(not lookups.WriteProcessMemory and not lookups.VirtualProtectEx,
           'unsupported image must not be patched')
end
local update, render = env.update, env.render
load_addon()
assert(env.update == update and env.render == render and #lines == 2,
       'standalone and megapack copies must share the re-entry guard')
if module_handle then module_handle:free() end
print('PASS: arc thrower native bindings (' .. scenario .. '), callbacks and duplicate guard')
