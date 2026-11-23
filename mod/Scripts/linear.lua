-- SceneColor HDR is sampled before the display transform in an independent,
-- one-shot view. A fresh capture has no persistent eye-adaptation history.
local linear = {}
local folder = assert(debug.getinfo(1, "S").source:match("^@(.+[/\\])"))
local fallback = dofile(folder .. "exrfallback.lua")
local magic = "\118\047\049\001" .. string.pack("<I4", 2)
local nativePixels = 3840 * 2160
local bandPixels = 1024 * 1024
local overlap = 64

local function valid(o)
    return o and o:IsValid()
end

local function object(path)
    local o = StaticFindObject(path)
    assert(valid(o), "Unavailable Unreal object " .. path)
    return o
end

local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

local function attribute(name, kind, bytes)
    return name .. "\0" .. kind .. "\0" .. string.pack("<I4", #bytes) .. bytes
end

local function readExact(f, count)
    local b = f:read(count)
    assert(b and #b == count, "Incomplete EXR")
    return b
end

local function name(f)
    local result = {}
    for i = 1, 256 do
        local ch = readExact(f, 1)
        if ch == "\0" then return table.concat(result) end
        result[i] = ch
    end
    error("Overlong EXR name")
end

local function header(f, w, h)
    assert(readExact(f, 8) == magic, "Expected a single-part scanline OpenEXR")
    local attrs = {}
    for i = 1, 100 do
        local key = name(f)
        if key == "" then break end
        local kind = name(f)
        local len = string.unpack("<I4", readExact(f, 4))
        assert(len < 65536, "Unexpectedly large EXR attribute")
        attrs[key] = {kind=kind, bytes=readExact(f, len)}
    end
    assert(attrs.dataWindow and attrs.dataWindow.bytes == string.pack("<i4i4i4i4", 0, 0, w-1, h-1),
        "EXR dimensions do not match the selected frame")
    assert(attrs.compression and attrs.compression.bytes == "\0", "Expected uncompressed EXR scanlines")
    assert(attrs.channels and attrs.channels.kind == "chlist", "Missing EXR channels")
    local list, sampleType = {}, nil
    local pos, data = 1, attrs.channels.bytes
    while data:byte(pos) ~= 0 do
        local channel, pixel, _, x, y
        channel, pixel, _, x, y, pos = string.unpack("<zI4I4i4i4", data, pos)
        assert((pixel == 1 or pixel == 2) and (not sampleType or pixel == sampleType) and x == 1 and y == 1,
            "Expected matching full-resolution HALF or FLOAT channels")
        sampleType = pixel
        list[#list + 1] = channel
    end
    local channels = table.concat(list)
    assert(channels == "ABGR" or channels == "BGR", "Unexpected EXR channels: " .. channels)
    return channels, sampleType
end

function linear.workingChromaticities()
    local settings = object("/Script/Engine.Default__RendererSettings")
    local enum = object("/Script/Engine.EWorkingColorSpace")
    local selected = enum:GetNameByValue(settings.WorkingColorSpaceChoice):ToString()
    assert(selected:match("sRGB$"), "Linear photography requires Rec.709/sRGB working primaries. Renderer uses " .. selected)
    return string.pack("<ffffffff", 0.64, 0.33, 0.30, 0.60, 0.15, 0.06, 0.3127, 0.3290)
end

local function rgbHeader(w, h, chroma, exposure, samples)
    local entries = {}
    for _, ch in ipairs({"B", "G", "R"}) do
        entries[#entries + 1] = string.pack("<zI4I4i4i4", ch, exposure and 2 or 1, 0, 1, 1)
    end
    local box = string.pack("<i4i4i4i4", 0, 0, w-1, h-1)
    local metadata = ""
    if exposure then
        metadata = attribute("terraTechLegionExposureMode", "string", exposure.mode)
        for _, pair in ipairs({{"aperture","aperture"}, {"expTime","seconds"}, {"isoSpeed","iso"},
                {"terraTechLegionExposureGain","gain"}, {"terraTechLegionMeteredEV","meteredEV"},
                {"terraTechLegionEVCompensation","compensation"}, {"terraTechLegionEVError","evError"}}) do
            local value = exposure[pair[2]]
            if type(value) == "number" then
                metadata = metadata .. attribute(pair[1], "float", string.pack("<f", value))
            end
        end
        metadata = metadata .. attribute("terraTechLegionShutterSamples", "int", string.pack("<i4", samples or 1))
    end
    return magic .. attribute("channels", "chlist", table.concat(entries) .. "\0")
        .. attribute("compression", "compression", "\0")
        .. attribute("dataWindow", "box2i", box) .. attribute("displayWindow", "box2i", box)
        .. attribute("lineOrder", "lineOrder", "\0") .. attribute("pixelAspectRatio", "float", string.pack("<f", 1))
        .. attribute("screenWindowCenter", "v2f", string.pack("<ff", 0, 0))
        .. attribute("screenWindowWidth", "float", string.pack("<f", 1))
        .. attribute("chromaticities", "chromaticities", chroma)
        .. metadata .. attribute("comments", "string", "TerraTech Legion Photo Mode (scene-linear Rec.709/D65)") .. "\0"
end

-- Convert each distinct source HALF once for an exposed master. FLOAT retains
-- bright emitters that can exceed 65504 after photographic exposure.
local function scaledHalf(gain)
    return setmetatable({}, {__index=function(cache, bytes)
        local bits = string.unpack("<I2", bytes)
        local exp, fraction = (bits >> 10) & 31, bits & 1023
        assert(exp ~= 31, "Invalid scene color in EXR")
        local value = exp == 0 and fraction * 2^-24 or (1 + fraction / 1024) * 2^(exp - 15)
        if bits >= 32768 then value = -value end
        local packed = string.pack("<f", value * gain)
        cache[bytes] = packed
        return packed
    end})
end

-- Strip unused alpha and guard columns. Bound the more expensive FLOAT
-- conversion to a band per poll, keeping the game thread responsive at 4K.
local function publishRGB(tx, request)
    local output = request.output or request.crop
    local w, h = output.w, output.h
    local f <close> = assert(io.open(tx.source, "rb"), "Unreal did not produce the EXR")
    if not tx.writeRow then
        tx.channels, tx.pixelType = header(f, tx.renderWidth, h)
        assert(tx.exposure or tx.pixelType == 1, "Expected a HALF source for the Game exposure")
        tx.indices = readExact(f, h * 8)
        local out <close> = assert(io.open(tx.partial, "wb"))
        local hdr = rgbHeader(w, h, tx.chroma, tx.exposure, tx.samples)
        assert(out:write(hdr))
        local stride = 8 + (tx.exposure and 12 or 6) * w
        for y = 0, h-1 do assert(out:write(string.pack("<I8", #hdr + h * 8 + y * stride))) end
        tx.writeRow = 0
        if tx.exposure and tx.pixelType == 1 then tx.lookup = scaledHalf(tx.gain) end
    end
    local out <close> = assert(io.open(tx.partial, "ab"))
    local bytes = tx.pixelType == 1 and 2 or 4
    local planeSize = tx.renderWidth * bytes
    local budget = tx.exposure and 262144 or 2097152
    local stop = math.min(h, tx.writeRow + math.max(1, budget // w))
    for y = tx.writeRow, stop-1 do
        assert(f:seek("set", string.unpack("<I8", tx.indices, y * 8 + 1)))
        local line, size = string.unpack("<i4I4", readExact(f, 8))
        assert(line == y and size == #tx.channels * planeSize, "Invalid EXR scanline")
        if tx.channels == "ABGR" then assert(f:seek("cur", planeSize)) end
        local rgb = readExact(f, 3 * planeSize)
        assert(out:write(string.pack("<i4I4", y, (tx.exposure and 12 or 6) * w)))
        for plane = 0, 2 do
            local start = plane * planeSize + tx.left * bytes
            local data = rgb:sub(start + 1, start + w * bytes)
            if tx.lookup then
                data = data:gsub("..", tx.lookup)
            elseif tx.pixelType == 2 and tx.gain ~= 1 then
                data = data:gsub("....", function(v) return string.pack("<f", string.unpack("<f", v) * tx.gain) end)
            end
            assert(out:write(data))
        end
    end
    tx.writeRow = stop
    return stop == h
end

-- Use the active game's projection at the selected crop boundaries. This
-- handles the project's axis constraint, including portrait and native gates.
local function gateTangent(session, crop)
    local y = crop.y + crop.h / 2
    local function ray(x)
        local direction = {}
        assert(session.pc:DeprojectScreenPositionToWorld(x, y, {}, direction), "Could not read viewfinder projection")
        local k = session.locationKeys
        return {direction[k.x], direction[k.y], direction[k.z]}
    end
    local a, b = ray(crop.x), ray(crop.x + crop.w)
    local dot = a[1]*b[1] + a[2]*b[2] + a[3]*b[3]
    local fov = math.deg(math.acos(math.max(-1, math.min(1, dot))))
    assert(fov > 0 and fov < 180, "Invalid viewfinder field of view")
    return math.tan(math.rad(fov)/2)
end

local function bandProjection(gate, library, renderWidth, left, outputWidth, outputHeight, bandY, bandHeight)
    -- Extend the frustum by one original pixel footprint per guard column.
    -- For an odd guard count, shift the principal point by half a pixel so
    -- each retained texel still represents the same viewfinder ray.
    local tangent = gate * renderWidth / outputWidth
    local paddedFov = math.deg(2 * math.atan(tangent))
    local right = renderWidth - outputWidth - left
    local view = {FOV=paddedFov, AspectRatio=renderWidth/bandHeight, ProjectionMode=0,
        OffCenterProjectionOffset={X=(right-left)/renderWidth, Y=(outputHeight-2*bandY-bandHeight)/bandHeight}}
    -- A custom projection can coexist with a centered frustum used for
    -- component culling. Keep the latter wide enough to cover the whole gate.
    local cullingFov = bandHeight == outputHeight and paddedFov
        or math.min(179.99, math.deg(2 * math.atan(tangent * outputHeight / bandHeight)))
    return library:CalculateProjectionMatrix(view), cullingFov
end

function linear.projection(session, crop, library, renderWidth, left, outputWidth, outputHeight, bandY, bandHeight)
    return bandProjection(gateTangent(session,crop), library, renderWidth, left, outputWidth or crop.w,
        outputHeight or crop.h, bandY or 0, bandHeight or outputHeight or crop.h)
end

-- UE4SS serializes struct arguments with the exact display spelling of
-- reflected names. A project's cooked FName casing may differ from the SDK.
local function structArgs(path, values)
    local fields, n = {}, 0
    object(path):ForEachProperty(function(prop)
        local key = prop:GetFName():ToString()
        local v = values[key:lower()]
        if v ~= nil then fields[key], n = v, n + 1 end
    end)
    local count = 0
    for _ in pairs(values) do count = count + 1 end
    assert(n == count, "Missing reflected properties on " .. path)
    return fields
end

function linear.writeOptions(format)
    return structArgs("/Script/ImageWriteQueue.ImageWriteOptions",
        {format=format, compressionquality=format == 3 and 1 or 100, boverwritefile=false, basync=false})
end

function linear.cancel(request)
    local tx = request and request.linearJob
    if not tx then return true end
    local errors = {}
    local function release(task)
        local ok, err = pcall(task)
        if not ok then errors[#errors + 1] = tostring(err) end
    end
    if valid(tx.actor) then release(function() tx.actor:K2_DestroyActor(); tx.actor = nil end) end
    if not tx.borrowed and valid(tx.target) then release(function() tx.library:ReleaseRenderTarget2D(tx.target); tx.target = nil end) end
    for _, path in ipairs({tx.source, tx.partial}) do
        if exists(path) then release(function() assert(os.remove(path)) end) end
    end
    if #errors > 0 then return false, table.concat(errors, " / ") end
    request.linearJob = nil
    return true
end

local function submitBand(tx, firstRow)
    local start = math.min(math.max(0, firstRow - overlap), tx.height - tx.renderHeight)
    local matrix, fov = bandProjection(tx.gate, tx.library, tx.renderWidth, tx.left,
        tx.width, tx.height, start, tx.renderHeight)
    tx.band = {target=tx.target, left=tx.left, first=firstRow,
        rows=math.min(tx.bandRows, tx.height-firstRow), sourceY=firstRow-start}
    tx.component.CustomProjectionMatrix, tx.component.FOVAngle = matrix, fov
    tx.component:CaptureScene()
end

local function capture(session, request, supplied, renderWidth, left, samples, divisor, externalBands)
    local path, crop = request.path, request.crop
    if not path or not path:match("%.exr$") then return false, "Expected an EXR path" end
    local source, partial = path:sub(1, -5) .. ".source.exr", path .. ".partial"
    if request.linearJob or exists(path) or exists(source) or exists(partial) then return false, "EXR filename is already in use" end
    local exposure = request.exposure and request.exposure.mode ~= "Game" and request.exposure
    local tx = {source=source, partial=partial, world=session.world, exposure=exposure, samples=samples}
    tx.gain = (exposure and exposure.gain or 1) / (divisor or 1)
    request.linearJob = tx
    local ok, issue = pcall(function()
        local output = request.output or crop
        local w, h = output.w, output.h
        assert(math.tointeger(w) and w >= 1 and w <= 16384 and math.tointeger(h) and h >= 1 and h <= 16384,
            "EXR dimensions must be between 1 and 16384 pixels per axis")
        tx.width, tx.height = w, h
        tx.chroma = linear.workingChromaticities()
        tx.library = object("/Script/Engine.Default__KismetRenderingLibrary")
        if externalBands then tx.externalBands = true; return end
        -- DX12 readback aligns RGBA16F rows to 256 bytes. Include guard
        -- columns when deciding if a single render target fits the budget.
        tx.renderWidth = ((w + 31) // 32) * 32
        tx.left = (tx.renderWidth - w) // 2
        if not supplied and tx.renderWidth * h > nativePixels then
            -- Keep one strip of the image on the GPU. Overscan on each side
            -- gives neighboring rows to the renderer before cropping.
            tx.bandRows = math.max(1, bandPixels // w)
            tx.renderHeight = math.min(h, tx.bandRows + 2*overlap)
        else
            tx.writer = object("/Script/ImageWriteQueue.Default__ImageWriteBlueprintLibrary")
            tx.options = linear.writeOptions(3)
            tx.renderHeight = h
        end
        if supplied then
            assert(valid(supplied) and renderWidth >= w and left >= 0 and left + w <= renderWidth,
                "Invalid accumulated HDR target")
            tx.target, tx.renderWidth, tx.left, tx.borrowed = supplied, renderWidth, left, true
            return
        end
        local p = session.pose
        tx.actor = session.world:SpawnActor(object("/Script/Engine.SceneCapture2D"),
            {X=p.x, Y=p.y, Z=p.z}, {Pitch=p.pitch, Yaw=p.yaw, Roll=p.roll})
        assert(valid(tx.actor), "Could not spawn EXR capture")
        local component = tx.actor:GetComponentByClass(object("/Script/Engine.SceneCaptureComponent2D"))
        assert(valid(component), "Missing scene capture component")
        component.bCaptureEveryFrame, component.bCaptureOnMovement = false, false
        component.bAlwaysPersistRenderingState = false
        local k, r = session.locationKeys, session.angleKeys
        assert(tx.actor:K2_SetActorLocationAndRotation({[k.x]=p.x, [k.y]=p.y, [k.z]=p.z},
            {[r.pitch]=p.pitch, [r.yaw]=p.yaw, [r.roll]=p.roll}, false, {}, true), "Could not position EXR camera")
        tx.target = tx.library:CreateRenderTarget2D(session.world, tx.renderWidth, tx.renderHeight, 6, {R=0,G=0,B=0,A=0}, false, false)
        assert(valid(tx.target), "Could not create RGBA16f render target")
        assert(tx.target.SizeX == tx.renderWidth and tx.target.SizeY == tx.renderHeight, "Unreal resized the EXR render target")
        tx.target.TargetGamma = 1
        component.bUseCustomProjectionMatrix = true
        component.CaptureSource, component.TextureTarget = 1, tx.target -- SCS_SceneColorHDRNoAlpha
        if tx.bandRows then
            tx.component, tx.gate = component, gateTangent(session, crop)
            submitBand(tx, 0)
        else
            local matrix, fov = linear.projection(session, crop, tx.library, tx.renderWidth, tx.left, w, h)
            component.FOVAngle, component.CustomProjectionMatrix = fov, matrix
            component:CaptureScene()
        end
    end)
    if not ok then
        local _, cleanup = linear.cancel(request)
        return false, tostring(issue) .. (cleanup and " / " .. cleanup or "")
    end
    return true
end

function linear.capture(session, request)
    return capture(session, request)
end

-- The motion integrator owns this render target until verification completes.
function linear.fromTarget(session, request, target, width, left, samples, divisor)
    return capture(session, request, target, width, left, samples, divisor)
end

-- Timed exposures keep their accumulator alive until every retained row of
-- the current band has been read. Only the EXR staging file belongs to us.
function linear.beginBands(session, request, samples, divisor)
    return capture(session, request, nil, nil, nil, samples, divisor, true)
end

function linear.writeBand(request, target, left, firstRow, rowCount, sourceY)
    local tx = request.linearJob
    local ok, done = pcall(function()
        assert(tx and tx.externalBands and valid(target), "Missing EXR band or accumulator")
        assert(math.tointeger(firstRow) and math.tointeger(rowCount) and firstRow >= 0 and rowCount > 0
            and firstRow + rowCount <= tx.height, "Invalid EXR band bounds")
        assert(math.tointeger(sourceY) and math.tointeger(left) and sourceY >= 0 and left >= 0
            and sourceY + rowCount <= target.SizeY and left + tx.width <= target.SizeX, "EXR band exceeds its source")
        if not tx.band then
            assert(firstRow == (tx.fallbackRow or 0), "Out-of-order EXR band")
            tx.band = {target=target, left=left, first=firstRow, rows=rowCount, sourceY=sourceY}
        else
            assert(tx.band.first == firstRow and tx.band.rows == rowCount and tx.band.sourceY == sourceY
                and tx.band.left == left and tx.band.target == target, "EXR band changed before readback finished")
        end
        if fallback.step(tx, request, rgbHeader, tx.band) then tx.band = nil; return true end
        return false
    end)
    if not ok then return false, tostring(done) end
    return done
end

local function verifyFile(path, request)
    local f <close> = assert(io.open(path, "rb"))
    local output = request.output or request.crop
    local w, h = output.w, output.h
    local channels, sampleType = header(f, w, h)
    assert(channels == "BGR", "Expected RGB EXR")
    local endOfHeader = assert(f:seek())
    assert(f:seek("end") == endOfHeader + h * (16 + w * (sampleType == 1 and 6 or 12)), "Incomplete RGB EXR")
end

local function publish(request, tx)
    verifyFile(tx.partial, request)
    assert(not exists(request.path), "EXR filename is already in use")
    assert(os.rename(tx.partial, request.path))
    local cleaned, why = linear.cancel(request)
    assert(cleaned, why)
end

function linear.finishBands(request)
    local ok, why = pcall(function()
        local tx = request.linearJob
        assert(tx and tx.externalBands and not tx.band and tx.fallbackRow == tx.height, "Incomplete EXR bands")
        publish(request, tx)
    end)
    if not ok then return false, tostring(why) end
    return true
end

function linear.checkFile(request, now)
    local tx = request.linearJob
    if tx then
        now = now or os.clock()
        local previousRow, previousWrite, previousSize = tx.fallbackRow, tx.writeRow, tx.lastSize
        local ok, err = pcall(function()
            if tx.externalBands then return end
            if tx.band then
                if fallback.step(tx, request, rgbHeader, tx.band) then
                    if tx.fallbackRow == tx.height then publish(request, tx)
                    else submitBand(tx, tx.fallbackRow) end
                end
                return
            end
            if not tx.submittedAt then
                -- CaptureScene queues the render. Keep the actor and target
                -- alive across an engine frame before requesting GPU readback.
                tx.writer:ExportToDisk(tx.target, tx.source, tx.options)
                -- ExportToDisk can return before its render command executes,
                -- even with bAsync=false. A one-pixel read fences previous
                -- work and keeps the render target alive through readback.
                tx.library:ReadRenderTargetRawPixel(tx.world, tx.target, 0, 0, false)
                tx.submittedAt = now
                return
            end
            if tx.fallbackRow or not exists(tx.source) then
                if now - tx.submittedAt < 2 then return end
                if not tx.fallbackRow then
                    print("[TerraTechLegionPhoto] EXR writer produced no file. Reading scene RGB directly.\n")
                end
                if not fallback.step(tx, request, rgbHeader) then return end
            else
                local f <close> = assert(io.open(tx.source, "rb"))
                local size = assert(f:seek("end"))
                if not tx.lastSize or tx.lastSize ~= size then tx.lastSize = size; return end
                f:close()
                if not publishRGB(tx, request) then return end
            end
            publish(request, tx)
        end)
        if not ok then
            local _, cleanup = linear.cancel(request)
            return false, tostring(err) .. (cleanup and " / " .. cleanup or "")
        end
        if request.linearJob then
            return false, nil, previousRow ~= tx.fallbackRow or previousWrite ~= tx.writeRow or previousSize ~= tx.lastSize
        end
    end
    if not exists(request.path) then return false end
    local ok, err = pcall(verifyFile, request.path, request)
    if not ok then return false, tostring(err) end
    return true
end

return linear
