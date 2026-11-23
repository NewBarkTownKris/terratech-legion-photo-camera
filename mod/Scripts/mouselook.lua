-- Relative mouse axes come from the local player's viewport capture. No
-- cursor warping or input-mode change is needed when entering the finder.
local mouselook = {}
local degreesPerUnit = 0.75

local function mouseAxes(pc, readAnalog)
    return readAnalog(pc, "MouseX"), readAnalog(pc, "MouseY")
end

local function degrees(value)
    if type(value) == "number" and math.abs(value) < math.huge then
        return value * degreesPerUnit
    end
    return 0
end

function mouselook.reader(pc, readAnalog)
    local previousTime
    local retryAfter = 0

    return function(now)
        local elapsed = previousTime and now - previousTime
        previousTime = now
        -- A delayed callback may run twice within a single rendered frame.
        -- Ignore that duplicate, the entry frame, and accumulated motion
        -- after a long interruption (e.g. tabbing back into the game).
        if not elapsed or elapsed <= 0 or elapsed > 0.25 or now < retryAfter then return 0, 0 end
        local ok, x, y = pcall(mouseAxes, pc, readAnalog)
        if not ok then
            retryAfter = now + 1
            return 0, 0
        end
        -- Unreal's relative axes point right and up. Their values are the
        -- movement for this frame, so sensitivity is independent of dt.
        return degrees(x), degrees(y)
    end
end

return mouselook
