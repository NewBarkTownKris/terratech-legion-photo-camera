-- Supply two rows of GPU readback to the same writer used by timed shutters.
local linear = dofile("mod/Scripts/linear.lua")
local function valid() return true end
local world, target = {}, {SizeX = 4, SizeY = 3, IsValid = valid}
local rows = {
    {{R=0.5, G=0.25, B=0.125}, {R=1, G=0.5, B=0.25}},
    {{R=0.25, G=0.5, B=2}, {R=0.125, G=0.25, B=0.5}},
}
local library = {IsValid = valid}
function library:ReadRenderTargetRawPixelArea(context, rt, x, y, width, height, normalized)
    assert(context == world and rt == target and x == 1 and width == 2 and height == 1 and not normalized)
    return assert(rows[y]) -- the first source row follows a row of padding
end
local objects = {
    ["/Script/Engine.Default__KismetRenderingLibrary"] = library,
    ["/Script/Engine.Default__RendererSettings"] = {IsValid = valid, WorkingColorSpaceChoice = 0},
    ["/Script/Engine.EWorkingColorSpace"] = {IsValid = valid, GetNameByValue = function()
        return {ToString = function() return "EWorkingColorSpace::sRGB" end}
    end},
}
function StaticFindObject(path) return assert(objects[path]) end

local adapter = dofile("mod/Scripts/unreal.lua")
local destination = assert(adapter.screenshotDir({}))
local shot = {path = destination .. "/shot.exr", crop = {x=0, y=0, w=2, h=2},
    exposure = {mode="Manual", seconds=1/8, iso=400, aperture=4, gain=4}}
assert(linear.beginBands({world=world}, shot, 2, 2))
assert(linear.writeBand(shot, target, 1, 0, 1, 1))
assert(linear.writeBand(shot, target, 1, 1, 1, 2))
assert(linear.finishBands(shot))
