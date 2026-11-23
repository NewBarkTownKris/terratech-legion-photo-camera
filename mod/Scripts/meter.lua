-- The same crop rays used by the EXR shutter map the entire composition
-- onto a small square target. Each sample represents equal image area.
local meter = {}
local folder = assert(debug.getinfo(1, "S").source:match("^@(.+[/\\])"))
local linear = dofile(folder .. "linear.lua")
local side = 32

local function valid(obj)
    return obj and obj:IsValid()
end

local function object(path)
    local result = StaticFindObject(path)
    assert(valid(result), "Unavailable meter object " .. path)
    return result
end

-- Trim in log space so tiny emissives and ink-black outlines do not
-- dominate the reflected-light reading.
function meter.luminance(colors, count)
    assert(#colors == count and count > 0, "Incomplete meter readback")
    local stops = {}
    for i = 1, count do
        local pixel = colors[i]
        if pixel.R == nil then pixel = pixel:get() end
        local y = 0.2126 * pixel.R + 0.7152 * pixel.G + 0.0722 * pixel.B
        assert(y == y and math.abs(y) < math.huge, "Invalid HDR meter sample")
        -- Unlit areas in an HDR source can be exactly black across
        -- most of the crop. Like an ignored black histogram bucket, those
        -- pixels carry no reflected-light reading. Retain real dark detail.
        if y > 0 then stops[#stops+1] = math.log(y, 2) end
    end
    local lit = #stops
    if lit == 0 then return 2^-16 end
    table.sort(stops)
    local dark, bright = math.floor(lit * 0.10), math.floor(lit * 0.05)
    local sum = 0
    for i = dark + 1, lit - bright do sum = sum + stops[i] end
    return 2 ^ (sum / (lit - dark - bright))
end

function meter.close(session)
    local m = session.photoMeter
    if not m then return true end
    local errors = {}
    if valid(m.actor) then
        local ok, why = pcall(function() m.actor:K2_DestroyActor() end)
        if ok then m.actor = nil else errors[#errors+1] = tostring(why) end
    end
    if valid(m.target) then
        local ok, why = pcall(function() m.lib:ReleaseRenderTarget2D(m.target) end)
        if ok then m.target = nil else errors[#errors+1] = tostring(why) end
    end
    if #errors > 0 then return false, table.concat(errors, " / ") end
    session.photoMeter = nil
    return true
end

local function open(session, m)
    local p = session.pose
    linear.workingChromaticities()
    m.lib = object("/Script/Engine.Default__KismetRenderingLibrary")
    m.actor = session.world:SpawnActor(object("/Script/Engine.SceneCapture2D"),
        {X=p.x,Y=p.y,Z=p.z}, {Pitch=p.pitch,Yaw=p.yaw,Roll=p.roll})
    assert(valid(m.actor), "Could not spawn the exposure meter")
    m.component = m.actor:GetComponentByClass(object("/Script/Engine.SceneCaptureComponent2D"))
    assert(valid(m.component), "Missing exposure meter component")
    m.component.bCaptureEveryFrame, m.component.bCaptureOnMovement = false, false
    m.component.bAlwaysPersistRenderingState = false
    m.target = m.lib:CreateRenderTarget2D(session.world, side, side, 6, {R=0,G=0,B=0,A=0}, false, false)
    assert(valid(m.target), "Could not allocate the HDR meter")
    m.target.TargetGamma = 1
    m.component.CaptureSource, m.component.TextureTarget = 1, m.target
end

local function resources(session)
    local m = session.photoMeter
    if not m then
        m = {}
        session.photoMeter = m
        open(session, m)
    end
    return m
end

-- Preserve the view at submission. A delayed GPU read may finish after a
-- move, roll, focal-length change or switch to another crop.
local function view(session, crop)
    local p = session.pose
    return {x=p.x,y=p.y,z=p.z,pitch=p.pitch,yaw=p.yaw,roll=p.roll,fov=p.fov,
        left=crop.x,top=crop.y,width=crop.w,height=crop.h}
end

function meter.matches(sample, session, crop)
    if not sample then return false end
    local p = session.pose
    return sample.x==p.x and sample.y==p.y and sample.z==p.z and sample.pitch==p.pitch and sample.yaw==p.yaw
        and sample.roll==p.roll and sample.fov==p.fov
        and sample.left==crop.x and sample.top==crop.y and sample.width==crop.w and sample.height==crop.h
end

local function submit(m, session, now, crop)
    local p, k, r = session.pose, session.locationKeys, session.angleKeys
    assert(m.actor:K2_SetActorLocationAndRotation({[k.x]=p.x,[k.y]=p.y,[k.z]=p.z},
        {[r.pitch]=p.pitch,[r.yaw]=p.yaw,[r.roll]=p.roll}, false, {}, true), "Could not aim the meter")
    local matrix, fov = linear.projection(session, crop, m.lib, crop.w, 0)
    -- Custom projection selects the meter's rays. UE culls against the
    -- component's square target, which must also cover the taller portrait gate.
    if crop.h > crop.w then
        local verticalTangent = math.tan(math.rad(fov) / 2) * crop.h / crop.w
        fov = math.min(179.99, math.deg(2 * math.atan(verticalTangent)))
    end
    m.component.FOVAngle, m.component.CustomProjectionMatrix = fov, matrix
    m.component.bUseCustomProjectionMatrix = true
    m.component:CaptureScene()
    m.queued, m.nextCapture = view(session, crop), now + 0.75
    m.queued.at = now
end

local function read(m, session)
    local pixels = m.lib:ReadRenderTargetRawPixelArea(session.world, m.target, 0, 0, side, side, false)
    local luminance, sample = meter.luminance(pixels, side * side), m.queued
    m.queued = nil
    return luminance, sample
end

function meter.poll(session, now, crop)
    local m = resources(session)
    if m.queued then
        if now - m.queued.at >= 0.015 then return read(m, session) end
    elseif not m.nextCapture or now >= m.nextCapture then
        submit(m, session, now, crop)
    end
end

-- At the shutter, a 32x32 synchronous read fences the queued SceneCapture
-- render. Only a priority/Auto shot whose current view is unmetered needs it.
function meter.readForShot(session, now, crop)
    local m = resources(session)
    if not meter.matches(m.queued, session, crop) then submit(m, session, now, crop) end
    return read(m, session)
end

return meter
