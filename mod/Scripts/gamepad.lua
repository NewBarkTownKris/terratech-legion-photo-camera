local gamepad = {}
-- Unreal already conditions stick travel before the raw-key query.
local deadzone = 0.08

local function bounded(value)
    return math.max(-1, math.min(value, 1))
end

local function axis(value)
    if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then return 0 end
    return bounded(value)
end

local function stick(x, y)
    x, y = axis(x), axis(y)
    local radius = math.sqrt(x * x + y * y)
    if radius <= deadzone then return 0, 0 end
    -- Preserve direction and remap the usable travel continuously to 0..1.
    local scale = (math.min(radius, 1) - deadzone) / ((1 - deadzone) * radius)
    return x * scale, y * scale
end

local function sample(readAnalog, pc)
    local right, forward = stick(readAnalog(pc, "Gamepad_LeftX"), readAnalog(pc, "Gamepad_LeftY"))
    local yaw, rightY = stick(readAnalog(pc, "Gamepad_RightX"), readAnalog(pc, "Gamepad_RightY"))
    -- Unreal's Windows gamepad keys report right-stick up as negative Y.
    return right, forward, yaw, -rightY
end

function gamepad.apply(axes, readAnalog, pc)
    local ok, right, forward, yaw, pitch = pcall(sample, readAnalog, pc)
    if ok then
        axes.right = bounded(axes.right + right)
        axes.forward = bounded(axes.forward + forward)
    end
    -- The lens scales right-stick aim separately from the fixed arrow-key rates.
    axes.stickYaw, axes.stickPitch = ok and yaw or 0, ok and pitch or 0
    return axes
end

return gamepad
