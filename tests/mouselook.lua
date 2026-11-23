local mouse = dofile("mod/Scripts/mouselook.lua")
local pc = {MouseX=0, MouseY=0, reads=0}
local function readAnalog(controller, name)
    assert(controller == pc)
    controller.reads = controller.reads + 1
    if controller.unavailable then error("player input unavailable") end
    return controller[name]
end

local read = mouse.reader(pc, readAnalog)
pc.MouseX, pc.MouseY = 24, 12
local function expect(time, x, y)
    local yaw, pitch = read(time)
    assert(math.abs(yaw - x) < 1e-10 and math.abs(pitch - y) < 1e-10)
end
expect(4, 0, 0)
expect(4 + 1/60, 18, 9)
expect(4 + 1/60, 0, 0)
expect(4 + 1/60 + 1/144, 18, 9)
assert(pc.reads == 4)
pc.MouseX, pc.MouseY = -10, -20
expect(6, 0, 0)
expect(6.02, -7.5, -15)
pc.MouseX, pc.MouseY = 0, 0
expect(6.03, 0, 0)
pc.MouseX, pc.MouseY = 0/0, math.huge
expect(6.04, 0, 0)
pc.MouseX, pc.MouseY = nil, -2
expect(6.05, 0, -1.5)
pc.unavailable = true
expect(6.06, 0, 0)
local attempts = pc.reads
expect(6.07, 0, 0)
assert(pc.reads == attempts)
pc.unavailable = false
expect(7.08, 0, 0)
expect(7.09, 0, -1.5)
print("Relative mouse look preserves direction, frame-independent motion and session-entry behavior.")
