local exposure = {}
local folder = assert(debug.getinfo(1, "S").source:match("^@(.+[/\\])"))
local optics = dofile(folder .. "optics.lua")
local meter = dofile(folder .. "meter.lua")
local modes = {"Game", "Manual", "Aperture Priority", "Shutter Priority"}
local isos = {100,125,160,200,250,320,400,500,640,800,1000,1250,1600,2000,2500,3200,4000,5000,6400}
local isoOptions = {"Auto", table.unpack(isos)}
local shutters = {8,6,5,4,3.2,2.5,2,1.6,1.3,1,0.8,0.6,0.5,0.4,0.3,0.25,0.2}
for _, denominator in ipairs({6,8,10,13,15,20,25,30,40,50,60,80,100,125,160,200,250,320,
        400,500,640,800,1000,1250,1600,2000,2500,3200,4000,5000,6400,8000,10000,12500,16000,
        20000,25000,32000}) do
    shutters[#shutters+1] = 1 / denominator
end
local choices = {mode=modes, aperture=optics.apertures, shutter=shutters, preferredShutter=shutters,
    iso=isoOptions, isoMin=isos, isoMax=isos}
-- The title uses relative light units. Place linear middle gray at a
-- photographic EV100 of 10 (approximately f/2.8, 1/125 s, ISO 100).
local calibrationEV = 10
local function defaults()
    return {mode="Game", aperture=2.8, shutter=1/125, iso=100, isoMin=100, isoMax=6400,
        preferredShutter=1/125, compensation=0}
end

local function copy(value)
    local result = {}
    for k,v in pairs(value) do result[k] = v end
    return result
end

local function clamp(value, low, high) return math.max(low, math.min(value, high)) end

local function nearest(list, desired, low, high)
    local best, distance = nil, math.huge
    for _, v in ipairs(list) do
        if (not low or v >= low) and (not high or v <= high) then
            local d = math.abs(math.log(v/desired, 2))
            if d < distance then best, distance = v, d end
        end
    end
    return assert(best)
end

local function isoForPreferredShutter(desired, low, high)
    for _, iso in ipairs(isos) do
        if iso >= low and iso >= desired then return math.min(iso, high) end
    end
    return high
end

function exposure.shutterText(t)
    if t >= 0.3 then return ("%g s"):format(t) end
    return ("1/%d s"):format(math.floor(1/t + 0.5))
end

function exposure.solve(o, luminance)
    local aperture, seconds = o.aperture, o.shutter
    local auto = o.iso == "Auto"
    local iso = auto and o.isoMin or o.iso
    local metered = luminance and (calibrationEV + math.log(luminance / 0.18, 2))
    local targetEV = metered and metered - o.compensation
    local priorityA, priorityS = o.mode == modes[3], o.mode == modes[4]
    if targetEV and o.mode ~= "Game" then
        local light = 2 ^ targetEV
        if priorityA then
            if auto then
                iso = isoForPreferredShutter(100 * aperture^2 / (light * o.preferredShutter), o.isoMin, o.isoMax)
            end
            seconds = nearest(shutters, 100 * aperture^2 / (light * iso))
        elseif priorityS then
            if auto then
                -- Start at base ISO and raise sensitivity once the lens is wide open.
                iso = nearest(isos, 100 * optics.apertures[1]^2 / (light * seconds), o.isoMin, o.isoMax)
            end
            aperture = nearest(optics.apertures, math.sqrt(light * seconds * iso / 100))
        elseif auto then
            iso = nearest(isos, 100 * aperture^2 / (light * seconds), o.isoMin, o.isoMax)
        end
    end
    local cameraEV = math.log(aperture^2 / seconds * 100 / iso, 2)
    local fixedManual = o.mode == "Manual" and not auto
    local gainEV = calibrationEV - cameraEV + (fixedManual and o.compensation or 0)
    local game = o.mode == "Game"
    return {mode=o.mode, aperture=aperture, seconds=seconds, iso=iso, autoISO=auto, cameraEV=cameraEV,
        compensation=o.compensation, meteredEV=metered, evError=not game and metered and
            (metered-cameraEV+(fixedManual and o.compensation or 0)-o.compensation) or nil,
        gain=game and 1 or 2^gainEV, ready=game or fixedManual or metered ~= nil}
end

local function state(session)
    if not session.exposure then
        local options = defaults()
        options.aperture = optics.fNumber(session)
        session.exposure = {options=options, result=exposure.solve(options)}
    end
    return session.exposure
end

local previewFields = {"AutoExposureMethod", "AutoExposureApplyPhysicalCameraExposure", "AutoExposureBias"}
local function readPreview(pp)
    local snapshot = {}
    for _, k in ipairs(previewFields) do
        local flag = "bOverride_" .. k
        assert(pp[k] ~= nil and pp[flag] ~= nil, "Missing camera exposure property " .. k)
        snapshot[k], snapshot[flag] = pp[k], pp[flag]
    end
    return snapshot
end

local function writePreview(pp, values)
    for _, k in ipairs(previewFields) do
        local flag = "bOverride_" .. k
        pp[k], pp[flag] = values[k], values[flag]
    end
end

local function apply(session, s)
    local shot = exposure.solve(s.options, s.luminance)
    local gain = shot.mode ~= "Game" and shot.gain or nil
    if s.previewGain ~= gain then
        local pp = session.lens.PostProcessSettings
        local before = readPreview(pp)
        local baseline = s.original or before
        local wanted = gain and {
            AutoExposureMethod=2, bOverride_AutoExposureMethod=true, -- AEM_Manual
            AutoExposureApplyPhysicalCameraExposure=false, bOverride_AutoExposureApplyPhysicalCameraExposure=true,
            AutoExposureBias=math.log(gain, 2), bOverride_AutoExposureBias=true,
        } or baseline
        local ok, why = pcall(writePreview, pp, wanted)
        if not ok then
            local restored, issue = pcall(writePreview, pp, before)
            if not restored then error(tostring(why) .. "; restore failed: " .. tostring(issue)) end
            error(why)
        end
        s.previewGain, s.original = gain, gain and baseline or nil
    end
    optics.setFNumber(session, shot.aperture)
    s.result = shot
end

function exposure.options(session) return copy(state(session).options) end
function exposure.snapshot(session) return copy(state(session).result) end

function exposure.status(session)
    local r = state(session).result
    if r.mode == "Game" then return "Game exposure" end
    local mode = r.mode == modes[3] and "A" or r.mode == modes[4] and "S" or "M"
    local reading = r.evError and ("%+.1f EV"):format(r.evError) or "Meter pending"
    return ("%s   f/%g   %s   %sISO %d   %s"):format(mode, r.aperture, exposure.shutterText(r.seconds),
        r.autoISO and "Auto " or "", r.iso, reading)
end

local function matches(list, value)
    for i,v in ipairs(list) do
        if v == value or (type(v) == "number" and tonumber(value)
                and math.abs(v - tonumber(value)) <= v * 1e-6) then return i end
    end
end

local function changeOptions(session, s, nextOptions)
    local previous = s.options
    s.options = nextOptions
    local ok, err = pcall(apply, session, s)
    if not ok then
        s.options = previous
        pcall(apply, session, s)
        error(err)
    end
    if nextOptions.mode == "Game" and previous.mode ~= "Game" then
        local closed, why = meter.close(session)
        assert(closed, why)
        s.luminance, s.sample, s.retryAt = nil, nil, nil
        s.result = exposure.solve(nextOptions)
    end
end

function exposure.restore(session, options)
    local restored = defaults()
    for field, list in pairs(choices) do
        local i = matches(list, options and options[field])
        if i then restored[field] = list[i] end
    end
    if restored.isoMin > restored.isoMax then restored.isoMin, restored.isoMax = 100, 6400 end
    local ec = tonumber(options and options.compensation)
    if ec and ec >= -5 and ec <= 5 then restored.compensation = math.floor(ec*3+0.5)/3 end
    changeOptions(session, state(session), restored)
end

function exposure.adjust(session, field, direction)
    local s = state(session)
    local o = copy(s.options)
    direction = direction >= 0 and 1 or -1
    if field == "compensation" then
        o.compensation = clamp(math.floor(o.compensation*3+0.5)+direction, -15, 15)/3
    elseif field == "autoISO" then
        if o.iso == "Auto" then o.iso = s.lastISO or 100
        else s.lastISO, o.iso = o.iso, "Auto" end
    else
        local list = assert(choices[field], "Unknown exposure control")
        local index = assert(matches(list, o[field]))
        if field == "mode" then index = (index - 1 + direction) % #list + 1
        else index = clamp(index+direction, 1, #list) end
        o[field] = list[index]
        if field == "isoMin" then o.isoMin = math.min(o.isoMin, o.isoMax) end
        if field == "isoMax" then o.isoMax = math.max(o.isoMin, o.isoMax) end
    end
    changeOptions(session, s, o)
    if field == "aperture" and o.mode == "Game" then return optics.status(session) end
    return exposure.status(session)
end

function exposure.tick(session, now, crop)
    local s = state(session)
    if s.options.mode == "Game" or (s.retryAt and now < s.retryAt) then return end
    local ok, value, sample = pcall(meter.poll, session, now, crop)
    if not ok then
        meter.close(session)
        s.luminance, s.sample, s.retryAt = nil, nil, now+3
        apply(session, s)
        return "Exposure meter unavailable: " .. tostring(value)
    end
    if value then
        s.luminance, s.sample, s.retryAt = value, sample, nil
        apply(session, s)
    end
end

function exposure.prepareShot(session, now, crop)
    local s = state(session)
    local shot = exposure.snapshot(session)
    if shot.mode == "Game" then return shot end
    if meter.matches(s.sample, session, crop) and now >= s.sample.at and now-s.sample.at <= 1.5 then return shot end
    if shot.mode == "Manual" and not shot.autoISO then
        -- Fixed controls don't need the meter. Omit a reading from another
        -- composition from this shot's metadata.
        shot.evError, shot.meteredEV = nil, nil
        return shot
    end
    local ok, value, sample = pcall(meter.readForShot, session, now, crop)
    if not ok then
        meter.close(session)
        s.luminance, s.sample, s.retryAt = nil, nil, now+3
        apply(session, s)
        return nil, "Exposure meter unavailable: " .. tostring(value)
    end
    s.luminance, s.sample, s.retryAt = value, sample, nil
    apply(session, s)
    return exposure.snapshot(session)
end

function exposure.close(session)
    local s = session.exposure
    local ok, why = meter.close(session)
    if s and s.original and session.lens and session.lens:IsValid() then
        local restored, issue = pcall(writePreview, session.lens.PostProcessSettings, s.original)
        if not restored then return false, tostring(issue) end
    end
    if ok then session.exposure = nil end
    return ok, why
end

return exposure
