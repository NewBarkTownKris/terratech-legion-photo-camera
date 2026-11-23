-- Run from the project root with Lua 5.4.
local photo = dofile("mod/Scripts/photo.lua")
local function near(x, y) assert(math.abs(x - y) < 0.000001) end

for _, size in ipairs({{3840, 2160}, {3440, 1440}, {1281, 801}}) do
    for index = 1, #photo.frames do
        for _, portrait in ipairs({false, true}) do
            local a, b = photo.frame(index, portrait)
            local c = photo.crop(size[1], size[2], a, b)
            if a then assert(c.w * b == c.h * a) end
            assert(c.x >= 0 and c.y >= 0)
            assert(math.abs(size[1] - c.w - 2 * c.x) <= 1)
            assert(math.abs(size[2] - c.h - 2 * c.y) <= 1)
            for scale = 1, 4 do
                local output = photo.output(c, scale, false)
                assert(output.w == scale * c.w and output.h == scale * c.h)
            end
        end
    end
end
local panorama = photo.output(photo.crop(3840,2160,65,24), 4, false)
assert(panorama.w == 15340 and panorama.h == 5664)
local big = {w=7680, h=4320}
assert(photo.output(big, 4, true).w == 15360 and photo.output(big, 4, true).h == 8640)
for _, invalid in ipairs({0, 5, 2.5}) do assert(not pcall(photo.output, big, invalid, true)) end

local pose = {x=0, y=0, z=0, pitch=0, yaw=90, roll=0, fov=90}
local axes = {forward=1, right=0, up=0, pitch=0, yaw=0, roll=0, zoom=0, speed=1}
local moved = photo.move(pose, 0.1, axes)
near(moved.x, 0); near(moved.y, 80); near(moved.z, 0)
for multiplier, centimeters in pairs({[0.2]=16, [4]=320}) do
    axes.speed = multiplier
    near(photo.move(pose, 0.1, axes).y, centimeters)
end
axes.speed = 1
axes.right = 1
moved = photo.move(pose, 0.1, axes)
near(math.sqrt(moved.x^2 + moved.y^2), 80)
near(photo.lensFov(18), 90)
assert(photo.lensFov(600) < photo.lensFov(200))

-- Mouse reports angular displacement. Keys and sticks report rates.
local aim = {forward=0, right=0, up=0, yaw=0, pitch=0, roll=0, zoom=0, speed=1,
    mouseYaw=12, mousePitch=-4}
local mouse60, mouse144 = photo.move(pose, 1/60, aim), photo.move(pose, 1/144, aim)
near(mouse60.yaw, 102); near(mouse60.pitch, -4)
near(mouse144.yaw, mouse60.yaw); near(mouse144.pitch, mouse60.pitch)
aim.yaw, aim.pitch = 1, 1
local mixed = photo.move(pose, 0.05, aim)
near(mixed.yaw, 106); near(mixed.pitch, -0.75)
aim.yaw, aim.pitch = 0, 0
local tele = {x=0, y=0, z=0, pitch=89, yaw=179, roll=0, fov=photo.lensFov(135)}
aim.mousePitch = 30
local reframed = photo.move(tele, 0.05, aim)
near(reframed.yaw, -179.4); near(reframed.pitch, 89.9)
aim.mousePitch, aim.mouseYaw, aim.stickYaw = 0, 0, 0.75
near(photo.move(tele, 0.1, aim).yaw, 179.8)
aim.yaw = 1
near(photo.move(tele, 0.1, aim).yaw, -173)

-- Drive main.lua through the same callbacks that the keyboard bindings use.
local actions, tick, mapChange, requested, problem
local clock, opens, closes, shutters, rolls = 0, 0, 0, 0, 0
local alive, failLoop = true, false
local imagePath = os.tmpname()
local messages = {}
local finderShown, finderClosed, lastDisplay, rejectShutter
local exrCalls, exrSaves = 0, 0
local exrFailure
local exposureShot = {mode="Game", iso=100}
local motionSteps, motionCancelled, motionRequest = 0, 0, nil
local expiredCapture
local pickerRequests, pickerError, displayDir = 0, nil, nil
local currentSession, viewWidth, viewHeight = nil, 1920, 1080
local lastAspect
local streamRequest, streamError, resizeOnPublish
local writeHeader
local finder = {
    reticles = {"optical", "square", "circle", "off"},
    open = function() return {} end,
    update = function(_, model) lastDisplay = model; return true end,
    visible = function(_, show) finderShown = show; return true end,
    close = function() finderShown = false; finderClosed = true; return true end,
}
local ue = {
    open = function() opens = opens + 1; currentSession = {pose=pose, pc={}}; return currentSession end,
    alive = function() return alive end, time = function() return clock end,
    close = function() closes = closes + 1; return true end,
    viewport = function() return viewWidth, viewHeight end,
    screenshotDir = function() return "/tmp", nil, displayDir end,
    requestDirectoryPicker = function()
        pickerRequests = pickerRequests + 1
        if pickerError then return nil, pickerError end
        return true
    end,
    frame = function(_, ratio) lastAspect = ratio; return true end,
    apply = function() rolls = rolls + 1; return true end,
    capture = function(_, req)
        assert(not finderShown)
        if rejectShutter then return false, "shutter declined" end
        shutters = shutters + 1
        req.path = imagePath
        requested = req
        return true, req
    end,
}
local input = {
    install = function(a) actions = a end,
    start = function(_, callback, onError)
        if failLoop then error("scheduler unavailable") end
        tick, problem = callback, onError
        return {}
    end,
    stop = function() end, flush = function() end,
}
local env = setmetatable({
    dofile = function(path)
        if path:match("unreal.lua$") then return ue end
        if path:match("input.lua$") then return input end
        if path:match("finder.lua$") then return finder end
        if path:match("exposure.lua$") then return {
            tick=function() end, close=function() return true end,
            snapshot=function() return exposureShot end, prepareShot=function() return exposureShot end,
            status=function() return "" end,
            options=function() return {mode=exposureShot.mode} end,
        } end
        if path:match("motion.lua$") then return {
            start=function(_, r)
                assert(not finderShown and r.exposure == r.linear.exposure)
                r.motionJob = {open=true}
                motionRequest = r
                return true
            end,
            step=function() motionSteps = motionSteps + 1; return motionSteps >= 2, nil, true end,
            cancel=function(r)
                if expiredCapture then error("expired capture resource") end
                motionCancelled = motionCancelled + 1
                r.motionJob = nil
                return true
            end,
        } end
        if path:match("shiftpng.lua$") then return {
            start=function(_, request)
                assert(not finderShown and request.streamPNG)
                request.shiftPNGJob = {steps=0}
                request.path = imagePath
                streamRequest = request
                return true
            end,
            progress=function() return "Developing PNG" end,
            step=function(_, request)
                local job = assert(request.shiftPNGJob)
                job.steps = job.steps + 1
                if streamError then return false, streamError end
                if job.steps == 1 then return false, nil, true end
                writeHeader(request.output.w, true, request.path, request.output.h)
                request.shiftPNGJob = nil
                if resizeOnPublish then viewWidth = viewWidth - 2 end
                return true, nil, true
            end,
            cancel=function(request) request.shiftPNGJob = nil; return true end,
        } end
        if path:match("linear.lua$") then return {
            capture=function(session, request)
                assert(request.filename:match("%.exr$"))
                if session.pending.streamPNG then
                    assert(photo.checkFile(session.pending), "the HDR render started before PNG publication")
                else
                    assert(not finderShown)
                end
                exrCalls = exrCalls + 1
                if exrFailure then return false, exrFailure end
                return true
            end,
            checkFile=function() exrSaves = exrSaves + 1; return true end,
            cancel=function() return true end,
        } end
        if path:match("optics.lua$") then return {
            status=function() return "DOF off" end, refresh=function() end, track=function() end,
        } end
        return dofile(path)
    end,
    RegisterLoadMapPreHook = function(callback) mapChange = callback end,
    print = function(message) messages[#messages+1] = message end,
}, {__index = _G})
assert(loadfile("mod/Scripts/main.lua", "t", env))()

local still = {forward=0,right=0,up=0,pitch=0,yaw=0,roll=0,zoom=0}
actions.directory()
assert(pickerRequests == 0)
actions.toggle(); assert(finderShown and not lastDisplay.grid and lastDisplay.reticle == "optical")
actions.grid(); tick(0, still)
assert(lastDisplay.grid)
for _, expected in ipairs({"square", "circle", "off", "optical"}) do
    actions.reticle(); tick(0, still)
    assert(lastDisplay.reticle == expected and lastDisplay.grid)
end
actions.directory(); tick(0, still)
assert(pickerRequests == 1 and lastDisplay.hint == "Choose a folder on your desktop")
pickerError = "Desktop folder picker unavailable"
actions.directory(); tick(0, still)
assert(pickerRequests == 2 and lastDisplay.hint == pickerError)
displayDir = "/home/test/Photo album/"
actions.frame(); actions.lens(); actions.capture(); actions.capture()
near(lastAspect, 3/2)
actions.directory(); actions.reticle()
assert(pickerRequests == 2 and lastDisplay.reticle == "optical")
assert(not finderShown and shutters == 0)
clock = 0.1; tick(0.01, axes); assert(shutters == 0)
clock = 0.2; tick(0.01, axes)
assert(opens == 1 and shutters == 1 and rolls == 1)
assert(requested.crop.w == 1620 and requested.crop.h == 1080)
assert(requested.filename:match("^TerraTechLegion_%d+_%d+_%d+%.png$"))
assert(requested.displayPath == "/home/test/Photo album/" .. requested.filename)
actions.toggle(); clock = 0.5; tick(0.01, axes)
assert(closes == 0, "must hold the photographic view during a pending write")

-- Simulate the signature, dimensions and final chunk observed by the polling
-- code. An incomplete write must leave the pending request in place.
function writeHeader(width, withEnd, path, height)
    local f = assert(io.open(path or imagePath, "wb"))
    f:write("\137PNG\r\n\26\n", string.pack(">I4", 13), "IHDR", string.pack(">I4I4", width, height or 1080))
    if withEnd then f:write("\0\0\0\0IEND\174\66\96\130") end
    f:close()
end
writeHeader(1620, false); clock = 1; tick(0.01, axes); assert(closes == 0)
writeHeader(1620, true); clock = 2; tick(0.01, axes)
assert(closes == 1 and finderClosed and table.concat(messages, "\n"):find("Saved " .. requested.displayPath, 1, true))
writeHeader(1920, true); assert(select(2, photo.checkFile(requested)):find("expected"))
os.remove(imagePath)

actions.toggle(); actions.capture(); actions.toggle()
clock = 2.1; tick(0.01, axes); clock = 2.2; tick(0.01, axes); clock = 11; tick(0.01, axes)
assert(closes == 2 and table.concat(messages, "\n"):find("Timed out", 1, true))
actions.toggle(); mapChange(); assert(closes == 3)
actions.toggle(); alive = false; tick(0.01, axes); assert(closes == 4)
alive = true; actions.toggle()
actions.capture()
rejectShutter = true; clock = 11.1; tick(0.01, axes); clock = 11.2; tick(0.01, axes)
assert(finderShown and table.concat(messages, "\n"):find("shutter declined", 1, true))
actions.finder(); assert(not finderShown)
actions.capture(); clock = 11.3; tick(0.01, axes); clock = 11.4; tick(0.01, axes)
assert(not finderShown, "honor the photographer's hidden finder after a capture")
problem("lost controller"); assert(closes == 5)
failLoop = true; actions.toggle(); assert(closes == 6)
failLoop, rejectShutter = false, false
actions.toggle(); actions.frame(); actions.gradingCapture(); actions.capture(); actions.toggle()
clock = 12; tick(0.01, axes); clock = 12.1; tick(0.01, axes)
assert(requested.linear and requested.filename:gsub("%.png$", ".exr") == requested.linear.filename)
assert(requested.linear.displayPath == "/home/test/Photo album/" .. requested.linear.filename)
assert(exrCalls == 0)
writeHeader(1620, true); clock = 13; tick(0.01, axes); assert(exrCalls == 1 and closes == 6)
clock = 13.1; tick(0.01, axes); assert(exrSaves == 1 and closes == 7 and not finderShown)
assert(table.concat(messages, "\n"):find("Saved " .. requested.linear.displayPath, 1, true))
os.remove(imagePath)
alive, failLoop = true, false
exposureShot = {mode="Manual", seconds=1, iso=800, ready=true, gain=2}
actions.toggle(); actions.gradingCapture()
clock = 20; tick(0.01, axes); clock = 20.1; tick(0.01, axes)
assert(motionRequest and finderShown and lastDisplay.readout:find("Exposing"))
local beforeMoves = rolls
clock = 20.2; tick(0.01, axes); clock = 20.3; tick(0.01, axes)
assert(rolls == beforeMoves + 2 and motionSteps == 2 and motionCancelled == 1 and finderShown)
actions.gradingCapture(); clock = 21; tick(0.01, axes); clock = 21.1; tick(0.01, axes)
actions.toggle(); assert(motionCancelled == 2)
-- The Studio dial applies to the normal shutter, and a wrong-size write
-- never becomes a visible print master or triggers the paired EXR.
exposureShot = {mode="Game", iso=100}
actions.toggle()
local composition = currentSession.studio.camera
for i = 1, 3 do composition.adjust(currentSession, "captureScale", 1) end
assert(composition.values(currentSession).captureScale == "4×  7680×4320")
actions.gradingCapture()
clock = 23; tick(0.01, still); clock = 23.1; tick(0.01, still)
local stage = assert(requested.stagedPNG)
writeHeader(1920, true, stage)
clock = 24; tick(0.01, still)
assert(not io.open(stage, "rb") and not io.open(imagePath, "rb") and exrCalls == 1)
actions.gradingCapture()
clock = 25; tick(0.01, still); clock = 25.1; tick(0.01, still)
assert(requested.output == requested.linear.output and requested.crop.w == 1920)
writeHeader(7680, true, requested.stagedPNG, 4320)
clock = 26; tick(0.01, still)
assert(exrCalls == 2 and not requested.stagedPNG and photo.checkFile(requested))
assert(finderShown and lastDisplay.readout:find("7680 × 4320"))
clock = 27; tick(0.01, still)
os.remove(imagePath)
viewWidth = 5120
actions.gradingCapture()
assert(not currentSession.pending and table.concat(messages):find("16384%-pixel renderer limit"))
viewWidth = 1920
actions.gradingCapture()
viewWidth = 1918
clock = 28; tick(0.01, still); clock = 28.1; tick(0.01, still)
assert(not currentSession.pending and table.concat(messages):find("Viewport changed before capture"))
actions.toggle()
actions.toggle()
local lens = currentSession.studio.camera
local entryFov = currentSession.pose.fov
lens.restore(currentSession, {lens=8})
assert(currentSession.pose.fov == entryFov and lens.options(currentSession).lens == 8)
actions.lens()
near(currentSession.pose.fov, photo.lensFov(600))
actions.lens()
near(currentSession.pose.fov, photo.lensFov(16))
actions.toggle()
-- A map/view change can invalidate the pending capture before the next tick.
-- Exercise throwing finalizers and confirm later steps still restore gameplay.
actions.toggle()
local closedBeforeCleanup = closes
currentSession.pending = {timed=true, motionJob={}}
expiredCapture = true
local closeFinder = finder.close
finder.close = function() error("expired finder resource") end
actions.toggle()
finder.close = closeFinder
assert(closes == closedBeforeCleanup + 1)
assert(table.concat(messages):find("expired capture resource", 1, true))
assert(table.concat(messages):find("expired finder resource", 1, true))
actions.toggle()
alive = false
local shutterCount = shutters
actions.capture()
assert(not currentSession.pending and shutters == shutterCount and closes == closedBeforeCleanup + 2,
    "a stale key bind must restore gameplay before the next tick")
alive = true
actions.toggle()
currentSession.lens = {PostProcessBlendWeight=.4}
currentSession.gameplayBlendWeight = .4
currentSession.optics = {enabled=true, mode="Manual"}
clock = 35; tick(0, still)
assert(currentSession.lens.PostProcessBlendWeight == 1, "a manual DOF override must apply at full weight")
currentSession.optics.enabled = false
clock = 36; tick(0, still)
assert(currentSession.lens.PostProcessBlendWeight == .4, "Neutral returns to the camera's original blend")
actions.toggle()

-- Regress the 4× shutter at a 4K viewport through its normal F9 and F3
-- bindings. The 24:65 crop fits the native area budget as an output image,
-- but a native HighResShot would still allocate 15360 × 8640.
viewWidth, viewHeight = 3840, 2160
exposureShot = {mode="Game", iso=100}
local function advance(count)
    for _ = 1, count do
        clock = clock + 0.2
        tick(0, still)
    end
end
local function enterPrintSession(scale, narrow)
    actions.toggle()
    currentSession.studio.camera.restore(currentSession,
        {captureScale=scale, frame=narrow and #photo.frames or 1, orientation=narrow})
end
local function startStream(withLinear)
    local nativeBefore, exrBefore = shutters, exrCalls
    streamRequest = nil
    if withLinear then actions.gradingCapture() else actions.capture() end
    advance(2)
    assert(streamRequest and streamRequest == currentSession.pending and streamRequest.shiftPNGJob)
    assert(not streamRequest.timed and shutters == nativeBefore and exrCalls == exrBefore)
    return streamRequest
end
local function exists(path)
    local file = io.open(path, "rb")
    if file then file:close(); return true end
    return false
end
for _, narrow in ipairs({false, true}) do
    enterPrintSession(4, narrow)
    for _, withLinear in ipairs({false, true}) do
        local before = exrCalls
        local png = startStream(withLinear)
        local expected = narrow and photo.crop(3840, 2160, 24, 65) or {w=3840,h=2160}
        assert(png.output.w == 4 * expected.w and png.output.h == 4 * expected.h)
        if narrow then assert(png.output.w * png.output.h < 3840 * 2160 * 4) end
        advance(1)
        assert(not exists(imagePath) and exrCalls == before and png == currentSession.pending)
        advance(1)
        assert(photo.checkFile(png))
        if withLinear then
            assert(currentSession.pending == png.linear and png.linear.output == png.output and exrCalls == before + 1)
            local closed = closes
            actions.toggle()
            assert(closes == closed + 1 and exists(imagePath), "canceling the EXR removed the published PNG")
        else
            assert(not currentSession.pending and exrCalls == before and finderShown)
        end
        assert(os.remove(imagePath))
    end
end

enterPrintSession(4, true)
local interrupted = startStream(true)
local closed, before = closes, exrCalls
advance(1)
actions.toggle()
assert(closes == closed + 1 and not interrupted.shiftPNGJob and not exists(imagePath) and exrCalls == before)
enterPrintSession(4, false)
streamError = "readback failed in the bounded PNG writer"
local failed = startStream(true)
advance(1)
assert(not currentSession.pending and not failed.shiftPNGJob and not exists(imagePath) and exrCalls == before)
assert(table.concat(messages):find(streamError, 1, true) and finderShown)
streamError = nil
local resized = startStream(true)
viewWidth = 3838
advance(1)
assert(not currentSession.pending and not resized.shiftPNGJob and not exists(imagePath) and exrCalls == before)
viewWidth = 3840
local published = startStream(true)
resizeOnPublish = true
advance(2)
resizeOnPublish = false
assert(photo.checkFile(published) and not currentSession.pending and exrCalls == before,
    "resize after PNG publication must retain the PNG and suppress the mismatched EXR")
assert(os.remove(imagePath))
viewWidth = 3840
exrFailure = "HDR target unavailable"
local partialPair = startStream(true)
advance(2)
assert(photo.checkFile(partialPair) and not currentSession.pending and exrCalls == before + 1)
assert(table.concat(messages):find("PNG saved. EXR failed: " .. exrFailure, 1, true))
assert(os.remove(imagePath))
exrFailure = nil
actions.toggle()
enterPrintSession(2, false)
streamRequest = nil
local nativeBefore = shutters
actions.capture()
advance(2)
assert(shutters == nativeBefore + 1 and not streamRequest, "4K at 2× should keep the tested native shutter")
writeHeader(7680, true, requested.stagedPNG, 4320)
advance(1)
assert(photo.checkFile(requested) and not currentSession.pending)
assert(os.remove(imagePath))
actions.toggle()
print("Passed camera movement, optics, crop, native and streamed print, timed shutter, cancellation and session cleanup checks.")
