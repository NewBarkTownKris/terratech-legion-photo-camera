local gamepad = dofile("mod/Scripts/gamepad.lua")
local photo = dofile("mod/Scripts/photo.lua")
local pad = {}

local function readAnalog(device, name)
    assert(device == pad)
    return device[name]
end

local function keyboard()
    return {forward=0, right=0, yaw=0, pitch=0, up=0, roll=0, zoom=0, speed=1}
end

local function poll(axes)
    return gamepad.apply(axes or keyboard(), readAnalog, pad)
end

local function close(a, b)
    assert(math.abs(a-b) < 0.000001, ("expected %.6f, got %.6f"):format(b, a))
end

local pose = {x=0, y=0, z=0, pitch=0, yaw=0, roll=0, fov=50}
assert(not photo.move(pose, 0.1, poll())) -- No pad connected.
pad.Gamepad_LeftX, pad.Gamepad_LeftY = 0.05, -0.05
pad.Gamepad_RightX, pad.Gamepad_RightY = -0.05, 0.05
local idle = poll()
assert(idle.stickYaw == 0 and idle.stickPitch == 0)
assert(not photo.move(pose, 0.1, idle)) -- Idle drift on both sticks.

pad.Gamepad_LeftX, pad.Gamepad_LeftY = 0, 0.09
pad.Gamepad_RightX, pad.Gamepad_RightY = 0.09, 0
local fine = poll()
close(fine.forward, 0.01 / 0.92)
close(fine.stickYaw, fine.forward)

pad.Gamepad_LeftX, pad.Gamepad_LeftY = 0, 0.54
pad.Gamepad_RightX, pad.Gamepad_RightY = 0, -0.54
local half = poll()
close(half.forward, 0.5)
close(half.stickPitch, 0.5)
assert(half.pitch == 0)
local moved = photo.move(pose, 0.1, half)
close(math.sqrt(moved.x^2 + moved.z^2), 40)

pad.Gamepad_LeftX, pad.Gamepad_LeftY = 1, -1
pad.Gamepad_RightX, pad.Gamepad_RightY = -1, 1
local diag = poll()
close(diag.right, 1 / math.sqrt(2))
close(diag.forward, -diag.right)
close(diag.stickYaw, -diag.right)
close(diag.stickPitch, -diag.right)

pad.Gamepad_LeftX, pad.Gamepad_LeftY = 0, 1
pad.Gamepad_RightX, pad.Gamepad_RightY = -1, 0
local mixed = keyboard()
mixed.forward, mixed.yaw = 1, 1
poll(mixed)
assert(mixed.forward == 1 and mixed.yaw == 1 and mixed.stickYaw == -1)

pad.Gamepad_LeftX, pad.Gamepad_LeftY = nil, math.huge
pad.Gamepad_RightX, pad.Gamepad_RightY = 0/0, nil
assert(not photo.move(pose, 0.1, poll()))
local arrows = keyboard()
arrows.pitch, arrows.stickPitch = 1, -1
gamepad.apply(arrows, function() error("analog API unavailable") end, pad)
assert(arrows.pitch == 1 and arrows.forward == 0 and arrows.stickPitch == 0)
print("Gamepad movement, look, deadzones, mixed controls and disconnection passed")
