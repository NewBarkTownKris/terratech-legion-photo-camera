local fallback = dofile("mod/Scripts/exrfallback.lua")
local width, height, left = 3835, 22, 2
local maxFinite = {R=65504, G=-2, B=2^-24}
local zero = {R=0, G=1, B=-0.0}
local outside = {R=99, G=99, B=99}
local function header(w, h, chroma)
    assert(w == width and h == height and chroma == "Rec709")
    return "header"
end

for _, wrapped in ipairs({true, false}) do
    local path = os.tmpname()
    local tx = {partial=path, left=left, world={}, target={}, library={}, chroma="Rec709"}
    local crop = {w=width,h=height}
    function tx.library:ReadRenderTargetRawPixelArea(world, target, x, y, numCols, numRows, normalize)
        assert(world == tx.world and target == tx.target and not normalize)
        local pixels = {}
        for row = y, y + numRows - 1 do
            for col = x, x + numCols - 1 do
                local pixel = outside
                if col >= left and col < left + width then
                    pixel = ((col - left + row) % 2 == 0) and maxFinite or zero
                end
                pixels[#pixels + 1] = wrapped and {get = function() return pixel end} or pixel
            end
        end
        assert(#pixels <= 65536)
        return pixels
    end
    assert(not fallback.step(tx, {crop=crop}, header))
    assert(tx.fallbackRow > 0 and tx.fallbackRow < height)
    assert(fallback.step(tx, {crop=crop}, header) and tx.fallbackRow == height)
    do
        local f <close> = assert(io.open(path, "rb"))
        local data = f:read("a")
        local stride = 8 + width * 6
        local first = #"header" + 8 * height
        assert(#data == first + height * stride)
        for y = 0, height - 1 do
            local offset = string.unpack("<I8", data, 7 + y * 8)
            local line, bytes, pos = string.unpack("<i4I4", data, offset + 1)
            assert(offset == first + y * stride and line == y and bytes == width * 6)
            for _, x in ipairs({1, 2, width}) do
                local target = (x-1+y)%2 == 0
                local p = pos + (x-1) * 2
                assert(string.unpack("<I2", data, p) == (target and 0x0001 or 0x8000))
                assert(string.unpack("<I2", data, p + 2*width) == (target and 0xc000 or 0x3c00))
                assert(string.unpack("<I2", data, p + 4*width) == (target and 0x7bff or 0))
            end
        end
    end
    os.remove(path)
end

print("EXR fallback preserves cropped HALF scanlines, subnormals and signed zero in bounded bands.")
