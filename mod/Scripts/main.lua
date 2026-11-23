local folder = assert(debug.getinfo(1, "S").source:match("^@(.+[/\\])"))
local ue = dofile(folder .. "unreal.lua")
local input = dofile(folder .. "input.lua")
local photo = dofile(folder .. "photo.lua")
local finder = dofile(folder .. "finder.lua")
local optics = dofile(folder .. "optics.lua")
local linear = dofile(folder .. "linear.lua")
local exposure = dofile(folder .. "exposure.lua")
local film = dofile(folder .. "film.lua")
local studio = dofile(folder .. "studio.lua")
local motion = dofile(folder .. "motion.lua")
local shiftPNG = dofile(folder .. "shiftpng.lua")
local current
local composition = {}

local function log(message)
    print("[TerraTechLegionPhoto] " .. tostring(message) .. "\n")
end

-- A stale UObject can throw during teardown, including in a finalizer's own
-- validity check. Keep restoring the rest of the session in that case.
local function cleanup(label, operation, ...)
    local called, ok, reason = pcall(operation, ...)
    if called and ok then return true end
    log(label .. ": " .. tostring(reason or ok))
end

local function releaseCapture(request)
    if request and request.shiftPNGJob then
        cleanup("Print PNG cleanup", shiftPNG.cancel, request)
    end
    if request and request.stagedPNG then
        cleanup("PNG cleanup", photo.cancelPNG, request)
    end
    if request and request.motionJob then
        cleanup("Long exposure cleanup", motion.cancel, request)
    elseif request and request.isLinear then
        cleanup("EXR cleanup", linear.cancel, request)
    end
end

local function finish(session)
    if current ~= session then return end
    current = nil
    if session.loop then
        local ok, err = pcall(input.stop, session.loop)
        if not ok then log(err) end
    end
    releaseCapture(session.pending)
    if session.studio then cleanup("Studio settings", studio.save, session) end
    cleanup("Lens effects cleanup", film.close, session)
    cleanup("Exposure cleanup", exposure.close, session)
    if session.finder then
        cleanup("Finder cleanup", finder.close, session.finder)
        session.finder = nil
    end
    pcall(input.flush, session.pc)
    if cleanup("Gameplay restore", ue.close, session) then
        log("Gameplay view restored")
    end
end

local function apply(session, pose)
    local oldFov = session.pose.fov
    local ok, reason = ue.apply(session, pose)
    assert(ok, reason)
    session.pose = pose
    if oldFov ~= pose.fov then
        session.lensIndex, session.preferredLens = 0, nil
        optics.refresh(session)
    end
end

local function showFinder(s, show)
    if not s.finder then return end
    local ok, reason = finder.visible(s.finder, show)
    assert(ok, reason)
end

local function drawFinder(s)
    if not s.finder or not s.showFinder then return end
    local w, h = ue.viewport(s)
    if not w then return end
    local a, b = photo.frame(s.frameIndex, s.portrait)
    local frame = a and ("%d:%d"):format(a, b) or "Viewport"
    local reticle = finder.reticles[s.reticleIndex]
    local mm = 18 / math.tan(math.rad(s.pose.fov / 2))
    local info = ("%g mm   %s   %s"):format(math.floor(mm * 10 + 0.5) / 10, frame, optics.status(s))
    local meterText = exposure.status(s)
    if meterText and meterText ~= "" then info = info .. "   " .. meterText end
    local timed = s.pending and s.pending.timed
    local printPNG = s.pending and s.pending.streamPNG
    local printEXR = s.pending and s.pending.isLinear and s.pending.scale > 1
    local panel = not timed and not printPNG and not printEXR and studio.model(s)
    local reading = exposure.snapshot(s)
    local meterEV = reading.mode ~= "Game" and not timed and reading.evError or nil
    local hint = s.notice or "F9 PNG   F3 PNG + EXR   F4 Studio   F2 Folder   F1 Controls"
    if timed then
        local job = s.pending.motionJob
        if job and job.open then
            info = ("Exposing   %.1f s remaining"):format(math.max(0, (job.start or 0) + (job.duration or 0) - ue.time(s)))
            hint = "Move or pan the camera     F8 cancels"
        else
            info, hint = "Developing photo", "F8 cancels"
        end
    elseif printPNG then
        info = ("Developing %d × %d PNG   %s"):format(s.pending.output.w, s.pending.output.h,
            shiftPNG.progress(s.pending))
        hint = "F8 cancels"
    elseif printEXR then
        info = ("Developing %d × %d EXR"):format(s.pending.output.w, s.pending.output.h)
        hint = "PNG saved     F8 keeps the PNG and cancels the EXR"
    elseif s.help and not s.notice then
        hint = "WASD / Left stick Move   Mouse / Arrows / Right stick Aim\n"
            .. "E/Q Height   Z/X Roll   P Level\n"
            .. "F5 Frame   F6 Rotate   F7 Lens   [ ] Zoom   H Finder   G Grid   R Reticle\n"
            .. "N Focus lock   T Continuous AF   J/K Manual   L Fine   U/I Aperture   B DOF   Y Strength\n"
            .. "F4 Studio   C Chromatic aberration   F9 PNG   F3 PNG + EXR   F8 Resume"
    end
    local key = table.concat({w, h, frame, tostring(s.grid), reticle, info, hint, meterEV or "", panel and panel.key or ""}, "|")
    if key == s.lastFinder then return end
    local ok, reason = finder.update(s.finder, {width=w, height=h, crop=photo.crop(w, h, a, b),
        readout=info, hint=hint, grid=s.grid, reticle=reticle, studio=panel, meterEV=meterEV})
    if not ok then
        log("Finder unavailable: " .. tostring(reason))
        local removed, problem = finder.close(s.finder)
        assert(removed, problem)
        s.finder = nil
        return
    end
    s.lastFinder = key
end

local function completeShot(s, message)
    log(message)
    releaseCapture(s.pending)
    local notice = message
    if message:match("^Saved ") then
        notice = (s.pending.isLinear or (s.pending.timed and s.pending.linear)) and "PNG + EXR saved" or "PNG saved"
    end
    s.notice, s.noticeUntil, s.nextDraw = notice, ue.time(s) + 6, 0
    s.pending = nil
    if s.exitRequested then finish(s); return false end
    drawFinder(s)
    showFinder(s, s.showFinder)
    return true
end

local function meterCamera(s, now, crop)
    if not crop then
        local w,h = ue.viewport(s)
        if not w then return end
        local a,b = photo.frame(s.frameIndex, s.portrait)
        crop = photo.crop(w,h,a,b)
    end
    if s.gameplayBlendWeight then
        -- UE has one blend weight for this entire camera layer. Preserve its
        -- fractional gameplay weight in Neutral/Game. Explicit photographic
        -- overrides need full weight for calibrated exposure, DOF and color.
        local look = film.options(s)
        local creative = exposure.options(s).mode ~= "Game" or (s.optics and s.optics.enabled)
            or look.look ~= 1 or look.grain or look.chromatic == "Off"
        local weight = creative and 1 or s.gameplayBlendWeight
        if s.lens.PostProcessBlendWeight ~= weight then s.lens.PostProcessBlendWeight = weight end
    end
    local issue = exposure.tick(s, now, crop)
    if issue and issue ~= s.lastMeterIssue then log(issue) end
    s.lastMeterIssue = issue
    local filmIssue = film.apply(s, exposure.snapshot(s))
    if filmIssue then log(filmIssue); s.notice, s.noticeUntil = filmIssue, now + 4 end
end

local function navigateStudio(s, axes, now)
    local x, y = axes.menuX or 0, axes.menuY or 0
    if x == 0 and y == 0 then s.studioHeld = nil; return end
    local key = y ~= 0 and (y > 0 and "down" or "up") or (x > 0 and "right" or "left")
    local first = s.studioHeld ~= key
    if not first and now < s.studioRepeat then return end
    s.studioHeld, s.studioRepeat, s.nextDraw = key, now + (first and 0.4 or 0.14), 0
    if y ~= 0 then studio.navigate(s, y > 0 and 1 or -1)
    else
        local ok, message = pcall(studio.adjust, s, x > 0 and 1 or -1)
        if message then
            if not ok then log(message) end
            s.notice, s.noticeUntil = tostring(message), now + 2
        end
    end
end

local function sameViewport(session, request)
    local w, h = ue.viewport(session)
    return request.viewport.w == w and request.viewport.h == h
end

local function update(session, dt, axes)
    if current ~= session then return false end
    local alive, why = ue.alive(session)
    if not alive then
        log(why or "Camera session ended")
        finish(session)
        return false
    end
    if session.pending then
        local now = ue.time(session)
        local request = session.pending
        if request.frames then
            request.frames = request.frames - 1
            if request.frames > 0 or now - session.requestTime < 0.05 then return true end
            request.frames = nil
            if not sameViewport(session, request) then
                return completeShot(session, "Viewport changed before capture. Reframe and press the shutter again")
            end
            local ok, reason
            if request.streamPNG then ok, reason = shiftPNG.start(session, request)
            elseif request.timed then ok, reason = motion.start(session, request, now)
            else ok, reason = ue.capture(session, request) end
            if not ok then return completeShot(session, "Shutter failed: " .. tostring(reason)) end
            if request.timed or request.streamPNG then
                drawFinder(session)
                showFinder(session, session.showFinder)
            end
            session.requestTime, session.nextCheck = now, now + 0.1
            return true
        end
        if request.timed then
            if request.motionJob and request.motionJob.open then
                axes.zoom = 0
                local pose = photo.move(session.pose, dt, axes)
                if pose then apply(session, pose) end
            end
            local done, err, progress = motion.step(session, request, now)
            if done then
                if request.linear then log("Saved " .. (request.linear.displayPath or request.linear.path)) end
                return completeShot(session, "Saved " .. (request.displayPath or request.path))
            end
            if progress then session.requestTime = now end
            if err or now - session.requestTime > 90 then
                return completeShot(session, tostring(err or "Timed out developing the long exposure"))
            end
            if now >= session.nextDraw then
                drawFinder(session)
                session.nextDraw = now + 0.1
            end
            return true
        end
        if now < session.nextCheck then return true end
        local saved, problem, madeProgress
        if request.streamPNG then
            if not sameViewport(session, request) then
                return completeShot(session, "Print canceled because the viewport changed")
            end
            saved, problem, madeProgress = shiftPNG.step(session, request, now)
            if not saved and not problem and now >= session.nextDraw then
                drawFinder(session)
                session.nextDraw = now + 0.25
            end
        else
            session.nextCheck = request.isLinear and request.scale > 1 and now or now + 0.1
            local checkFile = request.isLinear and linear.checkFile or photo.checkFile
            saved, problem, madeProgress = checkFile(request, now)
        end
        if madeProgress then session.requestTime = now end
        if saved and request.linear then
            log("Saved " .. (request.displayPath or request.path))
            local exr = request.linear
            if not sameViewport(session, exr) then
                return completeShot(session, "PNG saved. EXR canceled because the viewport changed")
            end
            local ok, reason = linear.capture(session, exr)
            if not ok then return completeShot(session, "PNG saved. EXR failed: " .. tostring(reason)) end
            exr.isLinear = true
            session.pending = exr
            session.requestTime = ue.time(session)
            session.nextCheck = session.requestTime
            if exr.scale > 1 then
                drawFinder(session)
                showFinder(session, session.showFinder)
            end
            return true
        end
        -- A 4× PNG has sixteen times the pixels to encode. Only idle time
        -- counts here; a growing file or advancing EXR strip resets the clock.
        local timeout = request.isLinear and 30 or (8 * request.scale * request.scale)
        if saved or problem or now - session.requestTime >= timeout then
            local displayPath = request.displayPath or request.path
            if saved then return completeShot(session, "Saved " .. displayPath) end
            local errorMessage = problem or ("Timed out waiting for " .. displayPath)
            if request.isLinear then errorMessage = "PNG saved. EXR failed: " .. errorMessage end
            return completeShot(session, errorMessage)
        end
        return true
    end
    local now = ue.time(session)
    if session.studio and session.studio.visible then navigateStudio(session, axes, now)
    else
        local pose = photo.move(session.pose, dt, axes)
        if pose then apply(session, pose) end
    end
    optics.track(session, now)
    if session.noticeUntil and now >= session.noticeUntil then session.notice, session.noticeUntil = nil, nil end
    if now >= session.nextDraw then
        meterCamera(session, now)
        drawFinder(session)
        session.nextDraw = now + 0.2
    end
    return true
end

local function toggle()
    if current then
        if current.pending and (current.pending.timed or current.pending.streamPNG
                or (current.pending.isLinear and current.pending.scale > 1)) then finish(current)
        elseif current.pending then current.exitRequested = true
        else finish(current) end
        return
    end
    local session, reason = ue.open()
    if not session then log(reason); return end
    current = session
    session.frameIndex, session.lensIndex, session.portrait = 1, 0, false
    session.captureScale = 1
    session.grid, session.showFinder, session.nextDraw, session.reticleIndex = false, true, 0, 1
    local _, settingsIssue = studio.open(session, exposure, film, nil, composition)
    if settingsIssue then log(settingsIssue) end
    session.finder, reason = finder.open(session)
    if session.finder then
        drawFinder(session)
        showFinder(session, true)
    else log("Finder unavailable: " .. tostring(reason)) end
    local ok, loop = pcall(input.start, session.pc, function(dt, axes)
        return update(session, dt, axes)
    end, function(err)
        log(err)
        finish(session)
    end, function() return session.studio and session.studio.visible and not session.pending end,
    function() return session.showFinder and not session.pending end)
    if not ok then log(loop); finish(session); return end
    session.loop = loop
    log("Photo mode active. F9 saves PNG, F3 saves PNG + linear EXR. F8 resumes driving.")
end

local function isTimed(settings)
    return settings.mode ~= "Game" and settings.seconds and settings.seconds >= 1/15 - 1e-7
end

local function capture(session, withLinear)
    local w, h = ue.viewport(session)
    assert(w, h)
    local a, b = photo.frame(session.frameIndex, session.portrait)
    local crop = photo.crop(w, h, a, b)
    local dir, why, displayDir = ue.screenshotDir(session)
    assert(dir, why)
    local request = photo.request(dir, crop, withLinear)
    optics.track(session, ue.time(session), true)
    meterCamera(session, ue.time(session), crop)
    local settings, meterError = exposure.prepareShot(session, ue.time(session), crop)
    assert(settings, meterError)
    film.apply(session, settings)
    if settings and settings.mode ~= "Game" then
        assert(settings.ready ~= false, session.lastMeterIssue or "Waiting for the first light-meter reading")
        request.exposure = settings
        if request.linear then request.linear.exposure = settings end
        request.timed = isTimed(settings)
    end
    local scale = session.captureScale
    if not request.timed and math.max(w, h) * scale > photo.maxRenderDimension then
        return ("A %d× capture exceeds the %d-pixel renderer limit. Choose a smaller capture scale"):format(scale, photo.maxRenderDimension)
    end
    request.scale, request.viewport = scale, {w=w, h=h}
    request.output = photo.output(crop, scale, request.timed)
    request.streamPNG = not request.timed and photo.requiresStream(w, h, scale)
    if request.linear then
        request.linear.scale, request.linear.viewport, request.linear.output = scale, request.viewport, request.output
    end
    if scale > 1 and not request.timed and not request.streamPNG then photo.stagePNG(request) end
    if displayDir then
        local native = displayDir:match("^%a:\\")
        local prefix = native and (displayDir:gsub("\\+$", "") .. "\\")
            or (displayDir:gsub("/+$", "") .. "/")
        request.displayPath = prefix .. request.filename
        if request.linear then request.linear.displayPath = prefix .. request.linear.filename end
    end
    showFinder(session, false)
    request.frames = 2
    session.pending, session.requestTime = request, ue.time(session)
    log(("Requested %s%s at %d× (%d × %d)%s"):format(request.filename, withLinear and " + scene-linear EXR" or "",
        scale, request.output.w, request.output.h, request.streamPNG and " (streamed print)" or ""))
end

local function setFrame(session, index, portrait)
    local a, b = photo.frame(index, portrait)
    local ratio
    if a then ratio = a / b end
    local ok, reason = ue.frame(session, ratio)
    assert(ok, reason)
    session.frameIndex, session.portrait = index, portrait
    log(a and ("Frame %d:%d"):format(a, b) or "Frame follows viewport")
end

local function setLens(s, index)
    local pose = {}
    for key, value in pairs(s.pose) do pose[key] = value end
    pose.fov = photo.lensFov(photo.lenses[index])
    apply(s, pose)
    s.lensIndex, s.preferredLens = index, index
    log(("Lens %d mm"):format(photo.lenses[index]))
end

function composition.options(s)
    local o = s.optics or {}
    return {frame=s.frameIndex, orientation=s.portrait, lens=s.preferredLens or s.lensIndex, reticle=s.reticleIndex,
        grid=s.grid, strength=o.strength or 1, dof=o.enabled or false, captureScale=s.captureScale}
end

function composition.restore(s, o)
    local frame = photo.frames[o.frame] and o.frame or s.frameIndex
    local portrait = s.portrait
    if type(o.orientation) == "boolean" then portrait = o.orientation end
    if frame ~= s.frameIndex or portrait ~= s.portrait then setFrame(s, frame, portrait) end
    -- Enter at the gameplay camera's actual FOV. The first lens command recalls
    -- the saved preset, even when the previous session used a long lens.
    if photo.lenses[o.lens] then s.preferredLens = o.lens end
    if finder.reticles[o.reticle] then s.reticleIndex = o.reticle end
    if type(o.grid) == "boolean" then s.grid = o.grid end
    if math.type(o.captureScale) == "integer" and o.captureScale >= 1 and o.captureScale <= 4 then
        s.captureScale = o.captureScale
    end
    if math.type(o.strength) == "integer" and o.strength >= 1 and o.strength <= 4 then optics.setStrength(s, o.strength) end
    if type(o.dof) == "boolean" and o.dof ~= (s.optics and s.optics.enabled or false) then optics.toggle(s) end
end

function composition.values(s)
    local o = composition.options(s)
    local mm = 18 / math.tan(math.rad(s.pose.fov / 2))
    local scaleText = ("%d×"):format(s.captureScale)
    local width, height = ue.viewport(s)
    if width then
        local a, b = photo.frame(s.frameIndex, s.portrait)
        local timed = isTimed(exposure.snapshot(s))
        local output = photo.output(photo.crop(width, height, a, b), s.captureScale, timed)
        if not timed and math.max(width, height) * s.captureScale > photo.maxRenderDimension then
            scaleText = scaleText .. "  Over limit"
        else
            scaleText = ("%s  %d×%d"):format(scaleText, output.w, output.h)
            if not timed and photo.requiresStream(width, height, s.captureScale) then
                scaleText = scaleText .. "  Multi-pass"
            end
        end
    end
    return {frame=photo.frames[o.frame].name, orientation=o.orientation and "Portrait" or "Landscape",
        captureScale=scaleText,
        lens=("%.1f mm"):format(mm), dof=o.dof and "On" or "Off", strength=("%dx"):format(2^(o.strength-1)),
        focusMode=o.dof and s.optics.mode or "Off",
        reticle=finder.reticles[o.reticle], grid=o.grid and "On" or "Off"}
end

function composition.adjust(s, key, delta)
    if key == "captureScale" then
        s.captureScale = math.max(1, math.min(4, s.captureScale + delta))
    elseif key == "frame" then
        setFrame(s, (s.frameIndex - 1 + delta) % #photo.frames + 1, s.portrait)
    elseif key == "orientation" then
        -- Rotating the native viewport starts with the 35 mm gate.
        setFrame(s, s.frameIndex == 1 and 2 or s.frameIndex, not s.portrait)
    elseif key == "lens" then
        local i = s.lensIndex == 0 and (s.preferredLens or (delta > 0 and 1 or #photo.lenses))
            or ((s.lensIndex - 1 + delta) % #photo.lenses + 1)
        setLens(s, i)
    elseif key == "dof" then return optics.toggle(s)
    elseif key == "strength" then return optics.setStrength(s, ((s.optics and s.optics.strength or 1)-1+delta)%4+1)
    elseif key == "focusMode" then return optics.toggleTracking(s)
    elseif key == "reticle" then
        s.reticleIndex = (s.reticleIndex - 1 + delta) % #finder.reticles + 1
        return "Reticle " .. finder.reticles[s.reticleIndex]
    elseif key == "grid" then s.grid = not s.grid
    elseif key == "folder" then
        local ok, reason = ue.requestDirectoryPicker()
        return ok and "Choose a folder on your desktop" or reason
    end
end

local function adjustComposition(key)
    return function(s)
        local message = composition.adjust(s, key, 1)
        local ok, issue = studio.save(s)
        if not ok then return issue end
        return message
    end
end

local function dial(field, direction)
    return function(s) return studio.dial(s, field, direction) end
end

local handlers = {
    capture = capture,
    gradingCapture = function(s) return capture(s, true) end,
    studio = function(s)
        assert(s.finder, "Finder unavailable")
        studio.toggle(s)
        s.studioHeld, s.notice, s.noticeUntil = nil, nil, nil
        s.showFinder = true
        showFinder(s, true)
    end,
    directory = function(s) return composition.adjust(s, "folder", 1) end,
    help = function(s)
        s.help = not s.help
        if s.help and not s.showFinder then
            s.showFinder = true
            showFinder(s, true)
        end
    end,
    finder = function(s)
        assert(s.finder, "Finder unavailable")
        if s.studio.visible then studio.toggle(s) end
        s.showFinder = not s.showFinder
        drawFinder(s)
        showFinder(s, s.showFinder)
    end,
    grid = adjustComposition("grid"),
    chromatic = dial("chromatic", 1),
    reticle = adjustComposition("reticle"),
    dof = adjustComposition("dof"), autofocus = optics.autofocus, strength = adjustComposition("strength"),
    tracking = optics.toggleTracking,
    nearer = function(s) return optics.manual(s, -1, s.fineFocus) end,
    farther = function(s) return optics.manual(s, 1, s.fineFocus) end,
    fineFocus = function(s)
        s.fineFocus = not s.fineFocus
        return s.fineFocus and "Manual focus step 1%" or "Manual focus step 20%"
    end,
    wider = dial("aperture", -1), narrower = dial("aperture", 1),
    faster = dial("shutter", 1), slower = dial("shutter", -1),
    isoUp = dial("iso", 1), isoDown = dial("iso", -1),
    frame = adjustComposition("frame"), portrait = adjustComposition("orientation"), lens = adjustComposition("lens"),
    level = function(s)
        local pose = {}
        for key, value in pairs(s.pose) do pose[key] = value end
        pose.roll = 0
        apply(s, pose)
    end,
}

local actions = {toggle = function()
    local ok, reason = pcall(toggle)
    if not ok then log(reason); if current then finish(current) end end
end}
for key, handler in pairs(handlers) do
    actions[key] = function()
        local s = current
        if not s or s.pending then return end
        -- A key callback can arrive between a world/view change and the next
        -- polling tick. Check ownership before changing the camera or taking a shot.
        local alive, why = ue.alive(s)
        if not alive then
            log(why or "Camera session ended")
            finish(s)
            return
        end
        local ok, reason = pcall(handler, s)
        if current ~= s then return end
        if reason then
            log(reason)
            if ok and reason == optics.status(s) then
                s.notice, s.noticeUntil = nil, nil
            else
                s.notice, s.noticeUntil = tostring(reason), ue.time(s) + 3
            end
        end
        if not s.pending then s.nextDraw = 0 end
    end
end
input.install(actions)

RegisterLoadMapPreHook(function()
    if current then finish(current) end
end)
log("Camera loaded. Press F8 while driving a Tech.")
