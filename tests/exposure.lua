local function near(a,b) assert(math.abs(a-b)<1e-6, ("%g != %g"):format(a,b)) end
local meter = {calls=0, closes=0}
function meter.poll(s,now,crop)
    meter.calls = meter.calls + 1
    if meter.failed then error("GPU readback unavailable") end
    return meter.light,{fov=s.pose.fov,w=crop.w,at=now}
end
function meter.matches(sample,s,crop) return sample and sample.fov==s.pose.fov and sample.w==crop.w end
function meter.readForShot(s,now,crop)
    meter.shutters=(meter.shutters or 0)+1
    return meter.poll(s,now,crop)
end
function meter.close() meter.closes=meter.closes+1; return true end
local env = setmetatable({dofile=function(path)
    if path:match("/meter.lua$") then return meter end
    return dofile(path)
end}, {__index=_G})
local exposure = assert(loadfile("mod/Scripts/exposure.lua","t",env))()
local baseline = {AutoExposureMethod=1, bOverride_AutoExposureMethod=false,
    AutoExposureBias=-2, bOverride_AutoExposureBias=true,
    AutoExposureApplyPhysicalCameraExposure=true, bOverride_AutoExposureApplyPhysicalCameraExposure=false}
local pp = {}
for k,v in pairs(baseline) do pp[k]=v end
local session = {pose={fov=60}, lens={PostProcessSettings=pp, IsValid=function() return true end}}
assert(exposure.snapshot(session).mode=="Game" and exposure.snapshot(session).gain==1)
exposure.tick(session,0,{})
assert(meter.calls==0)
exposure.adjust(session,"aperture",1)
assert(exposure.snapshot(session).aperture==3.2 and session.optics.aperture==11)
for k,v in pairs(baseline) do assert(pp[k]==v) end

local function knobs(mode, shutter, iso)
    return {mode=mode,shutter=shutter,aperture=4,iso=iso,
        isoMin=100,isoMax=6400,preferredShutter=1/125,compensation=0}
end
local manual=knobs("Manual",1/125,100)
exposure.restore(session,manual)
assert(exposure.snapshot(session).ready and exposure.snapshot(session).meteredEV==nil)
meter.light=0.18
exposure.tick(session,1,{})
local m=exposure.snapshot(session)
near(m.meteredEV,10)
near(m.gain, 1024/2000)
near(pp.AutoExposureBias, math.log(m.gain,2))
assert(pp.AutoExposureMethod==2 and pp.bOverride_AutoExposureMethod and not pp.AutoExposureApplyPhysicalCameraExposure)
manual.iso=200
exposure.restore(session,manual)
near(exposure.snapshot(session).gain, m.gain*2)
near(pp.AutoExposureBias, math.log(m.gain,2)+1)
manual.iso,manual.shutter=100,1/60
exposure.restore(session,manual)
near(exposure.snapshot(session).gain / m.gain, 125/60)
manual.compensation=1
exposure.restore(session,manual)
near(exposure.snapshot(session).gain / m.gain, 2*125/60)
exposure.adjust(session,"autoISO",1)
assert(exposure.options(session).iso=="Auto" and exposure.snapshot(session).iso==200)
exposure.adjust(session,"autoISO",1)
assert(exposure.options(session).iso==100)

local a=knobs("Aperture Priority",1/200,100)
local a1=exposure.solve(a,0.18)
local a2=exposure.solve(a,0.36)
assert(a1.aperture==4 and a2.aperture==4 and a1.seconds>a2.seconds)
assert(math.abs(a1.evError)<0.2 and math.abs(a2.evError)<0.2)
a.iso="Auto"
local auto=exposure.solve(a,0.18)
assert(auto.iso==200 and auto.seconds==1/125)
local boundary=exposure.solve(a,0.18*195.3125/205)
assert(boundary.iso==250 and boundary.seconds<=a.preferredShutter)
a.isoMax=400
local dim=exposure.solve(a,0.18/16)
assert(dim.iso==400 and dim.seconds>1/125)
assert(math.abs(dim.evError)<0.2)
a.compensation=1
assert(exposure.solve(a,0.18).gain>auto.gain*1.8)
local s=knobs("Shutter Priority",1/125,100)
assert(exposure.solve(s,0.18).aperture==2.8)
assert(exposure.solve(s,0.36).aperture==4)
s.iso,s.isoMax="Auto",400
local dark=exposure.solve(s,0.0001)
assert(dark.iso==400 and dark.aperture==1 and dark.seconds==1/125 and dark.evError<0)

exposure.restore(session,{mode="Game",iso=999,isoMin=6400,isoMax=100,shutter=-1})
assert(exposure.snapshot(session).gain==1 and exposure.snapshot(session).meteredEV==nil)
for k,v in pairs(baseline) do assert(pp[k]==v) end
local opts=exposure.options(session)
assert(opts.iso==100 and opts.isoMin==100 and opts.isoMax==6400 and opts.shutter==1/125)
opts.iso=500
assert(exposure.options(session).iso==100)
exposure.restore(session,s)
assert(not exposure.snapshot(session).ready)
meter.failed=true
assert(exposure.tick(session,10,{}):match("GPU readback unavailable"))
local calls=meter.calls
exposure.tick(session,11,{})
assert(meter.calls==calls and not exposure.snapshot(session).ready)
meter.failed=false
exposure.tick(session,14,{})
assert(exposure.snapshot(session).ready)
local a=exposure.prepareShot(session,14.1,{})
assert(a.ready and meter.shutters==nil, "unchanged composition stalled")
session.pose.fov=35
meter.light=0.36
local b=exposure.prepareShot(session,14.2,{})
assert(b.ready and meter.shutters==1 and b.meteredEV>a.meteredEV+0.9)
assert(exposure.prepareShot(session,14.25,{}).meteredEV==b.meteredEV and meter.shutters==1)
assert(exposure.prepareShot(session,14.3,{w=200}).ready and meter.shutters==2)
assert(exposure.prepareShot(session,20,{w=200}).ready and meter.shutters==3)
exposure.restore(session,manual)
local fixed=exposure.prepareShot(session,20.1,{w=400})
assert(fixed.ready and fixed.meteredEV==nil and meter.shutters==3)
exposure.restore(session,s)
meter.failed=true
local failed,why=exposure.prepareShot(session,20.2,{w=400})
assert(not failed and why:match("GPU readback") and meter.shutters==4)
assert(exposure.close(session))
for k,v in pairs(baseline) do assert(pp[k]==v) end
print("Exposure stops, meter calibration, Auto ISO limits, priority programs and preview restoration passed.")
