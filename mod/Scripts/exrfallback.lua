-- Recover scanlines directly from the frozen RGBA16f target when Unreal's
-- image writer returns without producing a source file.
local fallback = {}
local maxSamples = 65536
local packed = {}

-- Raw, unnormalized readback promotes an IEEE half to a Lua number without
-- changing its value. Cache the two-byte representation for repeated colors.
local function half(value)
    if value == 0 then return 1 / value < 0 and "\0\128" or "\0\0" end
    local bytes = packed[value]
    if bytes then return bytes end
    local magnitude = math.abs(value)
    assert(magnitude <= 65504, "Invalid scene color in EXR readback")
    local bits
    if magnitude < 2^-14 then
        bits = math.tointeger(magnitude * 2^24)
    else
        local single = string.unpack("<I4", string.pack("<f", magnitude))
        -- Half normals have ten mantissa bits and use an exponent bias of 15.
        assert(single & 0x1fff == 0, "Readback contains a non-HALF color")
        bits = (single >> 13) - 0x1c000
    end
    assert(bits, "Unexpected fractional half subnormal")
    if value < 0 then bits = bits | 0x8000 end
    bytes = string.pack("<I2", bits)
    packed[value] = bytes
    return bytes
end

-- Writes to tx.partial. The caller publishes the completed file and handles
-- cancellation with the same lifecycle used by the native writer.
function fallback.step(tx, request, rgbHeader, band)
    local output = request.output or request.crop
    local w, h = output.w, output.h
    local first = tx.fallbackRow or 0
    local limit = band and band.first + band.rows or h
    if band then
        assert(band.first <= first and first < limit and limit <= h, "Out-of-order EXR band")
    end
    if tx.fallbackRow == nil then
        local hdr = rgbHeader(w, h, tx.chroma, tx.exposure, tx.samples)
        local out <close> = assert(io.open(tx.partial, "wb"))
        assert(out:write(hdr))
        local first = #hdr + h * 8
        local stride = 8 + w * (tx.exposure and 12 or 6)
        for y = 0, h - 1 do assert(out:write(string.pack("<I8", first + y * stride))) end
        assert(out:flush())
        tx.fallbackRow = 0
    end
    if first == limit then return true end
    local rows = math.min(limit - first, math.max(1, maxSamples // w))
    -- The UE 5.6.1 reference readback takes extents despite the reflected
    -- names MaxX and MaxY. Validate the returned size on this build.
    local left = band and band.left or tx.left or 0
    local sourceY = band and (band.sourceY + first - band.first) or first
    local target = band and band.target or tx.target
    local colors = tx.library:ReadRenderTargetRawPixelArea(tx.world, target, left, sourceY, w, rows, false)
    assert(#colors == w * rows, "Incomplete rectangle in EXR scene color readback")
    local firstPixel = colors[1]
    local unwrap = firstPixel.R == nil and type(firstPixel.get) == "function"
    local sample = unwrap and firstPixel:get() or firstPixel
    assert(type(sample.R) == "number", "Could not read the reflected LinearColor")
    local out <close> = assert(io.open(tx.partial, "ab"))
    local blue, green, red = {}, {}, {}
    local encode = half
    if tx.exposure then
        encode = function(v)
            assert(v == v and math.abs(v) < math.huge, "Invalid scene color in EXR readback")
            return string.pack("<f", v * tx.gain)
        end
    end
    local index = 1
    for y = first, first + rows - 1 do
        for x = 1, w do
            local pixel = colors[index]
            if unwrap then pixel = pixel:get() end
            blue[x], green[x], red[x] = encode(pixel.B), encode(pixel.G), encode(pixel.R)
            index = index + 1
        end
        assert(out:write(string.pack("<i4I4", y, (tx.exposure and 12 or 6) * w),
            table.concat(blue), table.concat(green), table.concat(red)))
    end
    assert(out:flush())
    tx.fallbackRow = first + rows
    return tx.fallbackRow == limit
end

return fallback
