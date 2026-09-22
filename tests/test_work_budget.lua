-- Synthetic supported image and weapon tables; all Windows calls are stubs.
local source=assert(arg[1])
local ffi=require('ffi')
local GAME, REGION, SIZE = 0x100000, 0x10000000, 0x120000
local TRIGGER, CHARGE, ENTITIES, FLAGS, CHARGED, ENTRIES = 0x20000,0x30000,0x40000,0x50000,0x60000,0x70000
local WEAPON, SECOND = 0x80000,0x81000
local fingerprint='\x0f\xd7\xd6\x1a\x96\xfb\xa2\x29\xa9\x31\xee\x67\x0e\x04\x95\x41'
local resource='\xe6\x06\x73\x0f\xd5\x9c\xde\x96'
local signature='\x48\x89\x4c\x24\x08\x53\x55\x56\x57\x41\x57\x48\x83\xec\x20'
local region=ffi.new('uint8_t[?]',SIZE)
-- The fingerprint straddles the first 64 KiB boundary.
local record=65536-8-168
local function putf(buffer,offset,value)
    local v=ffi.new('float[1]',value);ffi.copy(buffer+offset,v,4)
end
putf(region,record,1);putf(region,record+24,1.1);putf(region,record+48,1.2)
putf(region,record+72,0.7);putf(region,record+76,1.4)
ffi.copy(region+record+168,fingerprint,#fingerprint)
local function integer(value,kind)
    local x=ffi.new((kind or 'uint64_t')..'[1]',value)
    return ffi.string(x,ffi.sizeof(x))
end
local function blob(size,values)
    local b=ffi.new('uint8_t[?]',size)
    for offset,bytes in pairs(values) do ffi.copy(b+offset,bytes,#bytes) end
    return ffi.string(b,size)
end
local clock,down,weapon,second,charge=0,false,'ordinary',false,0.5
local reads,queries,bytes,charge_reads,writes,patches,logs,updates,renders=0,0,0,0,0,0,0,0,0
local mode=arg[2] or 'normal'
local max_read, cost = 0, mode=='normal' and 0 or 1200
local function memory(address,size)
    if address>=REGION and address+size<=REGION+SIZE then
        return ffi.string(region+address-REGION,size)
    end
    if address==GAME+0x74DDF0 then return signature end
    if address==GAME+0x276C390 then return integer(TRIGGER) end
    if address==GAME+0x276C940 then charge_reads=charge_reads+1;return integer(CHARGE) end
    if address==TRIGGER+24 then
        return blob(72,{[0]=integer(2,'uint32_t'),[40]=integer(ENTITIES),[64]=integer(FLAGS)})
    end
    if address==FLAGS then return second and '\0\1' or '\1\0' end
    if address==ENTITIES then return integer(WEAPON)..integer(SECOND) end
    if address==WEAPON or address==SECOND then
        return blob(24,{[0]=(weapon=='arc' and resource or 'ordinary'),[20]='\1'})
    end
    if address==CHARGE+16 then
        return blob(56,{[0]=integer(512,'uint32_t'),[40]=integer(CHARGED),[48]=integer(ENTRIES)})
    end
    if address==CHARGED then return string.rep('\0',510*8)..integer(SECOND)..integer(WEAPON) end
    if address==ENTRIES+511*40 or address==ENTRIES+510*40 then
        local b=ffi.new('uint8_t[40]');putf(b,4,charge);putf(b,8,1.2);b[12]=1
        return ffi.string(b,40)
    end
    return nil
end
local kernel={}
function kernel.GetModuleHandleA() return ffi.cast('void *',GAME) end
function kernel.GetCurrentProcess() return ffi.cast('void *',1) end
function kernel.QueryPerformanceFrequency(p) p[0]=1000000;return 1 end
function kernel.QueryPerformanceCounter(p) p[0]=clock;return 1 end
function kernel.GetTickCount64() return math.floor(clock/1000) end
function kernel.ReadProcessMemory(_,address,buffer,size,count)
    address,size=tonumber(ffi.cast('uintptr_t',address)),tonumber(size)
    reads,bytes=reads+1,bytes+size;max_read=math.max(max_read,size);clock=clock+cost
    local data=memory(address,size)
    if mode=='stale' and size>216 and data and data:find(fingerprint,1,true) then
        ffi.fill(region+record+168,#fingerprint,0) -- allocation changed after the scan snapshot
    end
    if not data or #data~=size then return 0 end
    ffi.copy(buffer,data,size);count[0]=size;return 1
end
function kernel.VirtualQueryEx(_,address,info)
    queries=queries+1;clock=clock+cost
    address=tonumber(ffi.cast('uintptr_t',address))
    if address==0 then info.BaseAddress=ffi.cast('void *',0);info.RegionSize=REGION;info.State=0;return 48 end
    if address==REGION then
        info.BaseAddress=ffi.cast('void *',REGION);info.RegionSize=SIZE
        info.State=0x1000;info.Protect=2;info.Type=0x20000;return 48
    end
    return 0
end
function kernel.VirtualProtectEx(_,address,size,protection,previous)
    assert(tonumber(ffi.cast('uintptr_t',address))==REGION+record+184 and size==1)
    previous[0]=2;return 1
end
function kernel.WriteProcessMemory(_,address,data,size,written)
    address=tonumber(ffi.cast('uintptr_t',address))
    assert(size==1 and ffi.string(data,1)=='\1')
    if address==REGION+record+184 then patches=patches+1
    else
        assert(address==ENTRIES+(second and 510 or 511)*40+12,'wrong weapon entry')
        writes=writes+1
    end
    written[0]=size;return 1
end
local bindings=setmetatable({load=function(name)
    if name=='kernel32' then return kernel end
    assert(name=='user32');return {GetAsyncKeyState=function() return down and -32768 or 0 end}
end},{__index=ffi})
local env=setmetatable({},{__index=_G});env._G=env
env.require=function(name) return name=='ffi' and bindings or require(name) end
env.CowboyBingusModLoader={api=1,open_log=function()
    return {write=function(_,text)
        assert(not text:find('error #',1,true),text);logs=logs+1
    end,flush=function() end}
end}
env.update=function(_,marker) assert(marker=='original');updates=updates+1;return 1,nil,3 end
env.render=function() renders=renders+1;return 4,nil,6 end
local render=env.render
setfenv(assert(loadfile(source)),env)()
assert(env.render==render,'render must not run a second assist')
local function tick()
    clock=clock+10000
    local old_bytes,old_queries=bytes,queries
    local a,b,c=env.update(.01,'original');assert(a==1 and b==nil and c==3)
    assert(bytes-old_bytes<=262144+16384,'one update exceeded the scan/read budget')
    assert(queries-old_queries<=16,'one update exceeded the region-query budget')
    local old_reads,old_writes=reads,writes
    local x,y,z=env.render();assert(x==4 and y==nil and z==6)
    assert(reads==old_reads and writes==old_writes,'render duplicated native work')
end
for _=1,20 do tick() end
if mode=='stale' then
    assert(patches==0,'a stale fingerprint must never authorize a write')
    print('PASS: stale scan snapshot revalidated before writing')
    return
end
assert(patches==1 and max_read<=65536,'bounded scan must find a split fingerprint and patch exactly once')
local baseline_logs=logs
down=true
local before=reads
for _=1,100 do tick() end
assert(charge_reads==0 and writes==0,'ordinary weapons must not enumerate charged weapons or write')
assert(reads-before<=80,'held ordinary fire must throttle discovery instead of scanning every frame')
assert(logs==baseline_logs,'ordinary clicks must not write idle diagnostics')
down=false;tick();weapon='arc';down=true
before=writes;tick()
assert(writes==before+1 and charge_reads==1,'first Arc press must resolve the active weapon and assist immediately')
for _=1,50 do tick() end
assert(writes==before+51,'one charge write per update, with continuous hold preserved')
down=false;before=writes;for _=1,50 do tick() end
assert(writes==before,'release stops writes')
second=true;down=true;tick()
assert(writes==before+1 and charge_reads==2,'next press follows a second Arc Thrower')
assert(logs==baseline_logs,'normal holds and release must not flush verbose logs')
weapon='ordinary';before=writes;for _=1,20 do tick() end
assert(writes==before,'changed weapon identity cancels the cached entry')
print('PASS: bounded incremental scan, split fingerprint, throttled non-Arc discovery, continuous firing, second weapon, release, no render duplication or routine log IO')
