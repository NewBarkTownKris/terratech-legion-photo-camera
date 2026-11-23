local photo = {}

photo.frames = {
    {name = "Viewport"}, {name = "3:2", 3, 2}, {name = "4:3", 4, 3},
    {name = "1:1", 1, 1}, {name = "16:9", 16, 9}, {name = "5:4", 5, 4},
    {name = "21:9", 21, 9}, {name = "65:24", 65, 24},
}
photo.lenses = {16, 24, 35, 50, 85, 135, 200, 600}
photo.maxRenderDimension = 16384 -- Win64 D3D texture dimension limit

-- HighResShot allocates the entire scaled viewport before cropping. Keep
-- native backing rasters within the 2× UHD size tested on this renderer.
function photo.requiresStream(width, height, scale)
    return width * height * scale * scale > 7680 * 4320
end

function photo.frame(index, portrait)
    local frame = photo.frames[index]
    if portrait then return frame[2], frame[1] end
    return frame[1], frame[2]
end

-- Center the largest integer-pixel rectangle with exactly the chosen ratio.
function photo.crop(width, height, a, b)
    width, height = math.floor(width), math.floor(height)
    assert(width > 0 and height > 0, "Viewport has no image")
    local w, h = width, height
    if a then
        local scale = math.floor(math.min(width / a, height / b))
        assert(scale >= 1, "Viewport is too small for this frame")
        w, h = a * scale, b * scale
    end
    return {x = (width - w) // 2, y = (height - h) // 2, w = w, h = h}
end

-- The gate always uses viewport pixels. Only the captured raster is scaled.
function photo.output(crop, scale, timed)
    assert(math.type(scale) == "integer" and scale >= 1 and scale <= 4, "Choose a capture scale from 1× to 4×")
    local w, h = crop.w, crop.h
    assert(math.tointeger(w) and math.tointeger(h) and w > 0 and h > 0, "Invalid photo dimensions")
    if timed and math.max(w, h) > 3840 then
        local ratio = 3840 / math.max(w, h)
        w, h = math.max(1, math.floor(w*ratio + 0.5)), math.max(1, math.floor(h*ratio + 0.5))
    end
    return {w=w*scale, h=h*scale}
end

function photo.lensFov(mm)
    return math.deg(2 * math.atan(36 / (2 * mm)))
end

local function clamp(value, low, high)
    return math.min(high, math.max(low, value))
end

-- Unreal's axes are X forward, Y right, Z up. Up/down follows gravity even
-- when the photographer banks the frame or looks straight down.
function photo.move(pose, dt, axes)
    local f, r, u = axes.forward, axes.right, axes.up
    local mouseYaw, mousePitch = axes.mouseYaw or 0, axes.mousePitch or 0
    local stickYaw, stickPitch = axes.stickYaw or 0, axes.stickPitch or 0
    if f == 0 and r == 0 and u == 0 and axes.pitch == 0 and axes.yaw == 0
            and axes.roll == 0 and axes.zoom == 0 and mouseYaw == 0 and mousePitch == 0
            and stickYaw == 0 and stickPitch == 0 then return end
    dt = clamp(dt, 0, 0.1)
    -- Long lenses need a smaller angular change to cover the same portion
    -- of the frame. Arrow keys retain their fixed turn rates.
    local aimScale = math.min(1, math.tan(math.rad(pose.fov / 2)))
    local pitchRate = clamp(axes.pitch + stickPitch * aimScale, -1, 1)
    local yawRate = clamp(axes.yaw + stickYaw * aimScale, -1, 1)
    local pitch = clamp(pose.pitch + pitchRate * 65 * dt + mousePitch * aimScale, -89.9, 89.9)
    local yaw = (pose.yaw + yawRate * 80 * dt + mouseYaw * aimScale + 180) % 360 - 180
    local roll = (pose.roll + axes.roll * 55 * dt + 180) % 360 - 180
    local p, y = math.rad(pitch), math.rad(yaw)
    local cp, sp, cy, sy = math.cos(p), math.sin(p), math.cos(y), math.sin(y)
    local dx, dy, dz = f * cp * cy - r * sy, f * cp * sy + r * cy, f * sp + u
    local step = 800 * axes.speed * dt / math.max(1, math.sqrt(dx * dx + dy * dy + dz * dz))
    return {x = pose.x + dx * step, y = pose.y + dy * step, z = pose.z + dz * step,
        yaw = yaw, pitch = pitch, roll = roll, fov = clamp(pose.fov + axes.zoom * 30 * dt, 2, 155)}
end

local sequence = 0
local function exists(path)
    local file = io.open(path, "rb")
    if file then file:close(); return true end
    return false
end

-- Native high-resolution captures are published only after checking their size.
function photo.stagePNG(request)
    local path = request.path:gsub("([^/]+)%.png$", ".%1.print.png")
    assert(path ~= request.path and not exists(path), "Another print capture is using this filename")
    request.stagedPNG = path
end

function photo.cancelPNG(request)
    if request.stagedPNG and exists(request.stagedPNG) then return os.remove(request.stagedPNG) end
    return true
end

function photo.request(dir, crop, withLinear)
    assert(type(dir) == "string" and dir ~= "", "Screenshot directory unavailable")
    local base = os.date("TerraTechLegion_%Y%m%d_%H%M%S")
    repeat
        sequence = sequence + 1
        local filename = string.format("%s_%04d.png", base, sequence)
        local path = dir:gsub("[/\\]+$", "") .. "/" .. filename
        local existing = io.open(path, "rb")
        if existing then
            existing:close()
        else
            local request = {filename = filename, path = path, crop = crop}
            if not withLinear then return request end
            local exrPath = path:gsub("%.png$", ".exr")
            local exr = io.open(exrPath, "rb")
            if not exr then
                request.linear = {filename = filename:gsub("%.png$", ".exr"), path = exrPath, crop = crop}
                return request
            end
            exr:close()
        end
    until false
end

-- Screenshot writes are asynchronous. Wait for the final PNG chunk and check
-- the stored dimensions before reporting success or restoring the game view.
function photo.checkFile(request)
    local file = io.open(request.stagedPNG or request.path, "rb")
    if not file then return false end
    local header = file:read(24)
    local size = file:seek("end")
    local tail = size and size >= 12 and file:seek("set", size - 12) and file:read(12)
    file:close()
    if not header or #header < 24 or tail ~= "\0\0\0\0IEND\174\66\96\130" then
        local growing = size and size > (request.lastPNGSize or 0)
        request.lastPNGSize = size
        return false, nil, growing
    end
    if header:sub(1, 8) ~= "\137PNG\r\n\26\n" or header:sub(13, 16) ~= "IHDR" then
        return false, "Capture has an unexpected file format"
    end
    local w, h = string.unpack(">I4I4", header, 17)
    local output = request.output or request.crop
    if w ~= output.w or h ~= output.h then
        return false, ("Capture is %dx%d, expected %dx%d: %s"):format(w, h, output.w, output.h, request.path)
    end
    if request.stagedPNG then
        if exists(request.path) then return false, "Another image already occupies " .. request.path end
        local published, reason = os.rename(request.stagedPNG, request.path)
        if not published then return false, "Could not publish the print PNG: " .. tostring(reason) end
        request.stagedPNG = nil
    end
    return true
end

return photo
