-- HD2-Addon: mods/cowboybingus/arc_thrower_auto

-- ARC-3 Arc Thrower: hold the fire button and the weapon keeps firing.
-- Vanilla fires once per press and release; this addon lets the engine's own
-- charge -> fire cycle repeat while the button stays down. Nothing else is
-- changed: charge times, cadence, damage and arc settings stay stock.

local ffi = require('ffi')
local bit = require('bit')

ffi.cdef [[
typedef unsigned char uint8_t;
typedef unsigned short uint16_t;
typedef unsigned int uint32_t;
typedef unsigned long long uint64_t;
typedef struct {
    void *BaseAddress;
    void *AllocationBase;
    uint32_t AllocationProtect;
    uint16_t PartitionId;
    uint16_t Padding1;
    size_t RegionSize;
    uint32_t State;
    uint32_t Protect;
    uint32_t Type;
    uint32_t Padding2;
} MEMORY_BASIC_INFORMATION;
void *GetCurrentProcess(void);
int ReadProcessMemory(void *process, const void *base, void *buffer, size_t size, size_t *read);
int WriteProcessMemory(void *process, void *base, const void *buffer, size_t size, size_t *written);
int VirtualProtectEx(void *process, void *address, size_t size, uint32_t protect, uint32_t *previous);
int VirtualQueryEx(void *process, const void *address, MEMORY_BASIC_INFORMATION *info, size_t length);
short GetAsyncKeyState(int key);
uint64_t GetTickCount64(void);
int QueryPerformanceCounter(int64_t *count);
int QueryPerformanceFrequency(int64_t *frequency);
void *GetModuleHandleA(const char *name);
]]

local kernel = ffi.load('kernel32')
local user32 = ffi.load('user32')

-- Build 24826606 anchors. The charge manager holds one 40-byte entry per
-- weapon; entry + 4 is the charge, + 8 its full-charge time, + 12 the flag the
-- engine's charge updater advances while set.
local CHARGE_MANAGER = 0x276C940
local TRIGGER_MANAGER = 0x276C390
local FIRE_MODE_SETTER = 0x74DDF0
local FIRE_MODE_SIGNATURE = '\x48\x89\x4c\x24\x08\x53\x55\x56\x57\x41\x57\x48\x83\xec\x20'
local ARC_FINGERPRINT = '\x0f\xd7\xd6\x1a\x96\xfb\xa2\x29\xa9\x31\xee\x67\x0e\x04\x95\x41'
local ARC_RESOURCE = '\xe6\x06\x73\x0f\xd5\x9c\xde\x96'
local AUTO_FIRE_FLAG = 184
local ENTRY_SIZE = 40
local POINTER_SIZE = 8
local MEM_COMMIT, MEM_PRIVATE, PAGE_READONLY, PAGE_READWRITE = 0x1000, 0x20000, 0x02, 0x04
local VK_LBUTTON = 0x01

local process = kernel.GetCurrentProcess()
local state = {armed = false, patched = false, record = nil, scans = 0,
               checked = false, supported = false, resolved = nil,
               previous = nil, shots = {}, last_shot = nil, status = nil,
               status_charge = nil, errors = 0, reason = nil, reason_log = nil,
               reason_time = nil, drove_since = nil, drove_peak = 0, rescans = 0}

local performance_frequency = ffi.new('int64_t[1]')
kernel.QueryPerformanceFrequency(performance_frequency)
local performance_counter = ffi.new('int64_t[1]')

local function seconds()
    kernel.QueryPerformanceCounter(performance_counter)
    return tonumber(performance_counter[0]) / tonumber(performance_frequency[0])
end

local loader = rawget(_G, 'CowboyBingusModLoader')
local log = nil
if loader and type(loader.open_log) == 'function' then
    log = loader.open_log('ArcThrowerAuto.log')
end

local function note(message)
    if log then log:write(message .. '\n'); log:flush() end
end

local function log_line(message)
    note(string.format('[%8.3f] %s', tonumber(kernel.GetTickCount64()) / 1000 % 100000,
                       message))
end

local function read(address, size)
    local buffer = ffi.new('uint8_t[?]', size)
    local got = ffi.new('size_t[1]')
    if kernel.ReadProcessMemory(process, ffi.cast('void *', address), buffer, size,
                                got) == 0 then
        return nil
    end
    if got[0] ~= size then return nil end
    return ffi.string(buffer, size)
end

local function write(address, data)
    local written = ffi.new('size_t[1]')
    return kernel.WriteProcessMemory(process, ffi.cast('void *', address),
                                     ffi.cast('const void *', data), #data,
                                     written) ~= 0
end

local function write_protected(address, data)
    local previous = ffi.new('uint32_t[1]')
    if kernel.VirtualProtectEx(process, ffi.cast('void *', address), #data,
                               PAGE_READWRITE, previous) == 0 then
        return false
    end
    local ok = write(address, data)
    local restored = ffi.new('uint32_t[1]')
    kernel.VirtualProtectEx(process, ffi.cast('void *', address), #data,
                            previous[0], restored)
    return ok
end

local function unpack(blob, fmt, offset)
    local value = ffi.new(fmt .. '[1]')
    ffi.copy(value, blob:sub(offset + 1, offset + ffi.sizeof(value)), ffi.sizeof(value))
    return tonumber(value[0])
end

local function u32(blob, offset) return unpack(blob, 'uint32_t', offset) end
local function u64(blob, offset) return unpack(blob, 'uint64_t', offset) end
local function f32(blob, offset) return unpack(blob, 'float', offset) end

local function pointer(address)
    local blob = read(address, POINTER_SIZE)
    if not blob then return nil end
    return u64(blob, 0)
end

local function supported_build()
    if state.checked then return state.supported end
    state.checked = true
    local game = kernel.GetModuleHandleA('game.dll')
    if game == nil then return false end
    local base = tonumber(ffi.cast('uint64_t', game))
    state.supported = read(base + FIRE_MODE_SETTER, #FIRE_MODE_SIGNATURE)
        == FIRE_MODE_SIGNATURE
    return state.supported
end

-- The weapon data library is one large read-only private allocation. The arc
-- thrower's charge record is located by its animation-variable fingerprint;
-- auto_fire_in_safety tells the engine it may complete the shot itself.
local function patch_charge_record()
    local information = ffi.new('MEMORY_BASIC_INFORMATION')
    local address = 0
    local limit = 0x7FFFFFFFFFFF
    while address < limit do
        if kernel.VirtualQueryEx(process, ffi.cast('const void *', address),
                                 information, ffi.sizeof(information)) == 0 then
            return false, 'VirtualQueryEx failed'
        end
        local base = tonumber(ffi.cast('uint64_t', information.BaseAddress))
        local size = tonumber(information.RegionSize)
        if information.State == MEM_COMMIT and information.Protect == PAGE_READONLY
           and information.Type == MEM_PRIVATE and size >= 0x100000 then
            local offset = 0
            while offset < size do
                local span = math.min(0x100000, size - offset)
                local blob = read(base + offset, span)
                if blob then
                    local start = 1
                    while true do
                        local found = blob:find(ARC_FINGERPRINT, start, true)
                        if not found then break end
                        local record = base + offset + found - 1 - 168
                        local charge = read(record, 216)
                        if charge
                           and math.abs(f32(charge, 0) - 1.0) < 1e-3
                           and math.abs(f32(charge, 24) - 1.1) < 1e-3
                           and math.abs(f32(charge, 48) - 1.2) < 1e-3
                           and math.abs(f32(charge, 72) - 0.7) < 1e-3
                           and math.abs(f32(charge, 76) - 1.4) < 1e-3 then
                            state.record = record
                            if write_protected(record + AUTO_FIRE_FLAG, '\x01') then
                                state.patched = true
                                return true
                            end
                            return false, 'charge record write failed'
                        end
                        start = found + 1
                    end
                end
                offset = offset + span
            end
        end
        address = base + size
        if address <= 0 then break end
    end
    return false, 'charge record not found'
end

-- A player can own more than one arc thrower (a second one called down later
-- keeps its own entity and charge entry), so all of them are collected.
local function arc_candidates()
    local game = kernel.GetModuleHandleA('game.dll')
    if game == nil then return {} end
    local manager = pointer(tonumber(ffi.cast('uint64_t', game)) + CHARGE_MANAGER)
    if not manager then return {} end
    local count_blob = read(manager + 16, 4)
    if not count_blob then return {} end
    local count = u32(count_blob, 0)
    if count < 1 or count > 512 then return {} end
    local entities = pointer(manager + 56)
    local entries = pointer(manager + 64)
    if not entities or not entries then return {} end
    local list = {}
    for index = 0, count - 1 do
        local entity = pointer(entities + index * POINTER_SIZE)
        if entity then
            local record = read(entity, 24)
            if record and record:sub(1, 8) == ARC_RESOURCE then
                list[#list + 1] = {entity = entity, index = index,
                                   entry = entries + index * ENTRY_SIZE,
                                   active = bit.band(record:byte(21), 1) == 1}
            end
        end
    end
    return list
end

-- The engine sets a per-weapon fire command byte only for the weapon the
-- player is actually firing, which identifies the wielded thrower.
local function fire_command_address(entity)
    local game = kernel.GetModuleHandleA('game.dll')
    if game == nil then return nil end
    local manager = pointer(tonumber(ffi.cast('uint64_t', game)) + TRIGGER_MANAGER)
    if not manager then return nil end
    local count_blob = read(manager + 24, 4)
    local entities = pointer(manager + 64)
    local held = pointer(manager + 88)
    if not count_blob or not entities or not held then return nil end
    local count = math.min(u32(count_blob, 0), 64)
    for slot = 0, count - 1 do
        if pointer(entities + slot * POINTER_SIZE) == entity then
            return held + slot
        end
    end
    return nil
end

local failure_logged = false
local resolved = nil

local function step(dt)
    if not supported_build() then
        if not failure_logged then
            failure_logged = true
            note('Unsupported game build; the addon is disabled.')
        end
        return
    end
    if not state.patched then
        state.scans = state.scans + 1
        if state.scans <= 1 or state.scans % 512 == 0 then
            local ok, reason = patch_charge_record()
            if ok then
                note('Charge record patched at ' .. string.format('%#x', state.record))
            elseif reason and state.scans == 1 then
                note('Charge record not ready yet: ' .. tostring(reason))
            end
        end
    end

    local now = seconds()
    local down = bit.band(user32.GetAsyncKeyState(VK_LBUTTON), 0x8000) ~= 0
    if not down then
        if state.armed then
            local intervals = {}
            for index = 2, #state.shots do
                local interval = state.shots[index]
                if interval then intervals[#intervals + 1] = interval end
            end
            local summary = 'released after ' .. tostring(#state.shots) .. ' shot(s)'
            if #intervals > 0 then
                local total, minimum, maximum = 0, intervals[1], intervals[1]
                for _, interval in ipairs(intervals) do
                    total = total + interval
                    minimum = math.min(minimum, interval)
                    maximum = math.max(maximum, interval)
                end
                summary = summary .. string.format(
                    '; interval min %.3f mean %.3f max %.3f (%d)',
                    minimum, total / #intervals, maximum, #intervals)
            end
            log_line(summary)
        end
        state.armed = false
        state.resolved = nil
        state.previous = nil
        state.shots = {}
        state.last_shot = nil
        state.reason = nil
        return
    end

    if resolved then
        local identity = read(resolved.entity, 24)
        if not identity or identity:sub(1, 8) ~= ARC_RESOURCE then
            resolved = nil
            state.armed = false
            state.previous = nil
            state.reason = 'weapon entity changed'
            return
        end
    end

    -- Only assist after the engine issued a fire command for an arc thrower, so
    -- holding the button for another weapon stays untouched.
    if not state.armed then
        local chosen = nil
        for _, candidate in ipairs(arc_candidates()) do
            if candidate.active then
                local command = fire_command_address(candidate.entity)
                if command then
                    local value = read(command, 1)
                    if value and value:byte(1) ~= 0 then
                        candidate.held = command
                        chosen = candidate
                        break
                    end
                end
            end
        end
        if not chosen then
            state.reason = 'waiting for the engine fire command'
            return
        end
        resolved = chosen
        state.armed = true
        state.shots = {}
        state.last_shot = nil
        state.reason = nil
        state.drove_since = nil
        state.drove_peak = 0
        log_line(string.format('assist armed entity=%#x entry=%#x',
                               chosen.entity, chosen.entry))
    end

    local blob = read(resolved.entry, ENTRY_SIZE)
    if not blob then
        state.reason = 'charge entry unreadable'
        return
    end
    local value = f32(blob, 4)
    local full = f32(blob, 8)
    local flag = blob:byte(13)
    if full <= 0.1 then
        state.reason = 'invalid full-charge time'
        return
    end

    -- A second arc thrower called down later gets its own charge entry. If the
    -- entry being driven never charges, follow the new one on the next press.
    if not state.drove_since then
        state.drove_since = now
        state.drove_peak = value
    end
    state.drove_peak = math.max(state.drove_peak or 0, value)
    if (now - state.drove_since) > 1.2 and state.drove_peak < full * 0.25 then
        state.rescans = state.rescans + 1
        log_line(string.format(
            'entry %#x never charged (peak %.3f) - re-arming on the next press (#%d)',
            resolved.entry, state.drove_peak, state.rescans))
        resolved = nil
        state.armed = false
        state.drove_since = nil
        state.drove_peak = 0
        return
    end

    local previous = state.previous
    state.previous = value
    if previous and previous > full * 0.5 and value < full * 0.05 then
        local interval = state.last_shot and (now - state.last_shot) or nil
        state.last_shot = now
        state.shots[#state.shots + 1] = interval
        log_line(string.format('shot %d (charge %.3f -> %.3f, interval %s)',
                               #state.shots, previous, value,
                               interval and string.format('%.3f', interval) or 'n/a'))
    end

    -- The engine's charge updater advances the charge by the frame delta while
    -- the charging flag is set and fires when it crosses the full-charge time,
    -- so keeping that flag asserted is the whole job.
    if not write(resolved.entry + 12, '\x01') then
        state.reason = 'charge flag write failed'
        return
    end

    if (not state.status) or (now - state.status >= 0.25) then
        local window = now - (state.status or now)
        local delta = value - (state.status_charge or value)
        state.status = now
        state.status_charge = value
        log_line(string.format(
            'hold entry=%#x charge=%.3f full=%.3f flag=%d rate=%.2f/s',
            resolved.entry, value, full, flag, window > 0 and delta / window or 0))
    end
end

local previous_update = rawget(_G, 'update')
local function assist(dt)
    if type(dt) ~= 'number' then dt = 0 end
    local ok, reason = pcall(step, dt)
    if not ok then
        state.errors = state.errors + 1
        if state.errors <= 20 then
            log_line('error #' .. tostring(state.errors) .. ': ' .. tostring(reason))
        end
    elseif state.reason then
        local now = seconds()
        if state.reason_log ~= state.reason or (now - (state.reason_time or 0) > 2) then
            state.reason_log = state.reason
            state.reason_time = now
            log_line('idle: ' .. state.reason)
        end
    else
        state.reason_log = nil
    end
end

local function wrapped_update(dt)
    assist(dt)
    if type(previous_update) == 'function' then
        return previous_update(dt)
    end
end

update = wrapped_update

-- The engine also drives a per-frame render callback; running the assist there
-- too gives the writes a second chance each frame.
local previous_render = rawget(_G, 'render')
if type(previous_render) == 'function' then
    function render(...)
        assist(0)
        return previous_render(...)
    end
end

note('Arc Thrower Revamped initialised (loader API ' ..
     tostring(loader and loader.api or '?') .. ')')
