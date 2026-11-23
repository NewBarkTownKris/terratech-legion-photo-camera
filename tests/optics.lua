local function near(a, b)
    assert(math.abs(a - b) <= 1e-6 * math.max(1, math.abs(b)), ("%g != %g"):format(a, b))
end

local camera, world, vehicle = {}, {}, {}
local trace = {calls = 0}
function trace:IsValid() return true end
function trace:LineTraceSingle(context, start, finish, channel, complex, ignore, draw, hit, ignoreSelf, _, _, duration)
    self.calls = self.calls + 1
    assert(context == camera and context ~= vehicle and #ignore == 0 and ignoreSelf)
    assert(channel == 0 and complex and draw == 0 and duration == 0)
    -- Shipping FNames are case preserving. Use mixed-case keys like a reflected call.
    assert(start.x == -203000 and start.Y == 40 and start.z == 120)
    near(finish.x, start.x)
    near(finish.Y - start.Y, 1000000 * math.cos(math.rad(30)))
    near(finish.z - start.z, 500000)
    if self.unavailable then error("trace unavailable") end
    hit.distance = self.distance
    return self.distance ~= nil
end
local env = setmetatable({StaticFindObject = function(path)
    assert(path == "/Script/Engine.Default__KismetSystemLibrary")
    return trace
end}, {__index = _G})
local optics = assert(loadfile("mod/Scripts/optics.lua", "t", env))()

local properties = {
    DepthOfFieldSensorWidth = 24.576, bOverride_DepthOfFieldSensorWidth = true,
    DepthOfFieldFocalDistance = 73, bOverride_DepthOfFieldFocalDistance = false,
    DepthOfFieldFstop = 4, CameraISO = 250, AutoExposureBias = -1,
}
local failNextDistance = false
local pp = setmetatable({}, {__index = properties, __newindex = function(_, key, value)
    assert(key:match("DepthOfFieldSensorWidth$") or key:match("DepthOfFieldFocalDistance$"),
        "unexpected change to " .. key)
    if key == "DepthOfFieldFocalDistance" and failNextDistance then
        failNextDistance = false
        error("rejected reflected write")
    end
    properties[key] = value
end})
local s = {camera = camera, world = world, pawn = vehicle, lens = {PostProcessSettings = pp},
    locationKeys = {x = "x", y = "Y", z = "z"},
    pose = {x = -203000, y = 40, z = 120, pitch = 30, yaw = 90, roll = 70, fov = 45}}

assert(optics.status(s):find("Photo DOF off"))
optics.track(s, 0)
assert(trace.calls == 0, "idle camera traced while photo DOF was off")
assert(optics.autofocus(s):find("no focusable surface"))
assert(not s.optics.enabled and properties.DepthOfFieldFocalDistance == 73)
trace.distance = 123.45
assert(optics.autofocus(s):find("AF lock"))
assert(pp.DepthOfFieldFocalDistance == 123.45 and pp.bOverride_DepthOfFieldFocalDistance)

-- Compare the sensor-normalized blur circle at infinity for the renderer and the
-- equivalent 36 mm aperture. The same factor also applies at finite subject depths.
local function blurCircle(width, fstop, fov, distanceCm)
    local focalMm = width / (2 * math.tan(math.rad(fov) / 2))
    return focalMm ^ 2 / (width * fstop * (distanceCm * 10 - focalMm))
end
local function checkBlur(expected)
    near(blurCircle(pp.DepthOfFieldSensorWidth, pp.DepthOfFieldFstop, s.pose.fov, pp.DepthOfFieldFocalDistance),
        blurCircle(36, expected, s.pose.fov, pp.DepthOfFieldFocalDistance))
end
checkBlur(2.8)
local distance = pp.DepthOfFieldFocalDistance
trace.distance = 0
assert(optics.autofocus(s):find("no focusable surface") and pp.DepthOfFieldFocalDistance == distance)
trace.distance = nil
assert(optics.autofocus(s):find("AF lock") and pp.DepthOfFieldFocalDistance == distance)

assert(optics.manual(s, -1, false):find("Manual"))
near(pp.DepthOfFieldFocalDistance, distance / 1.20)
optics.manual(s, 1, true)
near(pp.DepthOfFieldFocalDistance, distance / 1.20 * 1.01)
assert(optics.aperture(s, 1):find("f/3.2", 1, true))
checkBlur(3.2)
for _, multiplier in ipairs({2, 4, 8, 1}) do
    assert(optics.strength(s):find(multiplier .. "x DOF", 1, true))
    checkBlur(3.2 / multiplier)
end
s.pose.fov = 3
optics.refresh(s)
checkBlur(3.2)
assert(trace.calls == 4, "changing lenses or dials triggered another focus trace")

local beforeText, beforeWidth = optics.status(s), pp.DepthOfFieldSensorWidth
failNextDistance = true
assert(not pcall(optics.aperture, s, 1))
assert(optics.status(s) == beforeText and pp.DepthOfFieldSensorWidth == beforeWidth)
assert(optics.toggle(s):find("Photo DOF off"))
assert(pp.DepthOfFieldFocalDistance == 73 and not pp.bOverride_DepthOfFieldFocalDistance)
assert(pp.DepthOfFieldSensorWidth == 24.576 and pp.bOverride_DepthOfFieldSensorWidth)
optics.aperture(s, -1)
optics.refresh(s)
assert(pp.DepthOfFieldFocalDistance == 73)

trace.distance = 1
optics.autofocus(s)
assert(pp.DepthOfFieldFocalDistance > 36 / (20 * math.tan(math.rad(s.pose.fov) / 2)))
assert(pp.DepthOfFieldFstop == 4 and pp.CameraISO == 250 and pp.AutoExposureBias == -1)

assert(optics.toggleTracking(s):find("AF%-C"))
trace.distance = 500
optics.track(s, 1)
near(pp.DepthOfFieldFocalDistance, 500)
assert(optics.status(s):find("Subject 5.00 m | Aligned", 1, true))
trace.distance = 700
local calls = trace.calls
optics.track(s, 1.10)
assert(trace.calls == calls and pp.DepthOfFieldFocalDistance == 500)
optics.track(s, 1.125)
near(pp.DepthOfFieldFocalDistance, 700)
trace.distance = nil
optics.track(s, 1.25)
assert(optics.status(s):find("No center target") and pp.DepthOfFieldFocalDistance == 700)

-- Refocus at the shutter even if the previous sample is very recent;
-- once capture is pending, every camera pose uses that same plane.
trace.distance = 900
optics.track(s, 1.26, true)
near(pp.DepthOfFieldFocalDistance, 900)
s.pending = {timed=true}
trace.distance = 1100
calls = trace.calls
optics.track(s, 2)
optics.track(s, 2, true)
assert(trace.calls == calls and pp.DepthOfFieldFocalDistance == 900)
s.pending = nil
assert(optics.toggleTracking(s):find("AF lock"))
optics.track(s, 2)
assert(optics.status(s):find("Focus farther") and pp.DepthOfFieldFocalDistance == 900)
trace.distance = 800
optics.track(s, 2.15)
assert(optics.status(s):find("Focus nearer") and pp.DepthOfFieldFocalDistance == 900)

-- The same focus error is sharp on a wide-angle lens and visibly blurred
-- on the telephoto. A stronger DOF effect also narrows the aligned region.
s.pose.fov = 60
optics.refresh(s)
assert(optics.status(s):find("Aligned"))
trace.distance = 520
optics.track(s, 2.30)
assert(optics.status(s):find("Aligned"))
assert(optics.setStrength(s,4):find("Focus nearer"))
assert(optics.setStrength(s,1):find("Aligned"))
assert(not pcall(optics.setStrength, s, 0))

optics.toggleTracking(s)
optics.manual(s, 1, true)
trace.distance = 450
optics.track(s, 2.50)
near(pp.DepthOfFieldFocalDistance, 909)
assert(s.optics.mode == "Manual" and s.optics.subject == 450)
optics.toggleTracking(s)
assert(optics.autofocus(s):find("AF lock"))
trace.distance = 300
optics.track(s, 2.75)
near(pp.DepthOfFieldFocalDistance, 450)

-- A transient trace or reflected lens write failure cannot close photo mode.
optics.toggleTracking(s)
trace.unavailable = true
optics.track(s, 3)
assert(optics.status(s):find("Focus range unavailable"))
trace.unavailable = false
calls = trace.calls
optics.track(s, 4.90)
assert(trace.calls == calls and pp.DepthOfFieldFocalDistance == 450)
failNextDistance = true
optics.track(s, 5)
assert(optics.status(s):find("Focus adjustment unavailable") and pp.DepthOfFieldFocalDistance == 450)
optics.track(s, 7)
assert(optics.status(s):find("Aligned") and pp.DepthOfFieldFocalDistance == 300)
optics.toggle(s)
calls = trace.calls
optics.track(s, 8)
assert(trace.calls == calls and pp.DepthOfFieldFocalDistance == 73)
print("Photo optics checks passed")
