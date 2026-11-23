-- Run from the repository root with lua tests/finder.lua.
local methods = {}
local function widget()
    return setmetatable({}, {__index = methods})
end

function methods:IsValid() return true end
function methods:AddChildToCanvas(child)
    local slot = widget()
    slot.child = child
    return slot
end
function methods:AddChildToVerticalBox() return widget() end
function methods:SetPosition(value) self.position = value end
function methods:SetSize(value) self.size = value end
function methods:SetVisibility(value) self.visibility = value end
function methods:SetRenderTransformAngle(value) self.angle = value end
function methods:SetWidthOverride(value) self.widthOverride = value end
function methods:SetText(value)
    self.text = value
    self.textChanges = (self.textChanges or 0) + 1
end
for _, name in ipairs({"SetBrushColor", "SetClipping", "SetPadding", "SetContent", "SetFont",
    "SetColorAndOpacity", "SetAutoWrapText", "SetAutoSize", "SetAlignment", "SetDesiredSizeInViewport",
    "SetPositionInViewport", "SetZOrder", "SetHeightOverride", "SetJustification"}) do
    methods[name] = function() end
end

local pc, blueprint, layout = widget(), widget(), widget()
local host, rejectAdd
function blueprint:Create(context, class, owner)
    assert(context == pc and owner == pc and class.path == "/Script/LevelSequence.LevelSequenceBurnIn")
    host = widget()
    host.WidgetTree = widget()
    function host:AddToViewport(z) self.attached = not rejectAdd and z > 0 end
    function host:IsInViewport() return self.attached end
    function host:RemoveFromParent() self.attached, self.removed = false, true end
    return host
end
function layout:GetViewportScale(context) assert(context == pc) return self.dpi end
layout.dpi = 2
local env = setmetatable({
    StaticFindObject = function(path)
        if path == "/Script/UMG.Default__WidgetBlueprintLibrary" then return blueprint end
        if path == "/Script/UMG.Default__WidgetLayoutLibrary" then return layout end
        local result = widget()
        result.path = path
        return result
    end,
    StaticConstructObject = function(_, outer)
        assert(outer == host.WidgetTree)
        return widget()
    end,
    FName = function(value) return value end,
    FText = function(value) return value end,
}, {__index = _G})
local finder = assert(loadfile("mod/Scripts/finder.lua", "t", env))()
local session = {pc = pc}
local handle = assert(finder.open(session))
assert(host.attached and host.visibility == 2)
local model = {width = 2400, height = 1200, crop = {x = 800, y = 0, w = 800, h = 1200},
    readout = "50 mm   2:3", hint = "F9  Shutter", grid = true}
assert(finder.update(handle, model))
assert(handle.gridSlot.position.X == 400 and handle.gridSlot.size.X == 400)
assert(math.abs(handle.guides[1].front.position.X - 400 / 3) < 0.001)
assert(handle.guides[3].front.position.Y == 200 and handle.guides[3].front.size.X == 400)
local function midpoint(slot)
    return slot.position.X + slot.size.X / 2, slot.position.Y + slot.size.Y / 2
end
local function near(a, b) return math.abs(a - b) < 0.00001 end
assert(table.concat(finder.reticles, "/") == "optical/square/circle/off")
assert(handle.reticle == "optical" and handle.marksSlot.position.X == 400)
local dotX, dotY = midpoint(handle.dot.front)
assert(dotX == 200 and dotY == 300)
assert(handle.layers.dot.panel.visibility == 3 and handle.layers.gaps.panel.visibility == 2)
assert(handle.layers.corners.panel.visibility == 3 and handle.layers.outer.panel.visibility == 3)
assert(handle.layers.brackets.panel.visibility == 3 and handle.layers.inner.panel.visibility == 2)
local topLeft, topRight = handle.corners[1].front, handle.corners[3].front
assert(topLeft.position.X == 2 and topLeft.position.Y == 2)
assert(near(topRight.position.X + topRight.size.X, 398))
local first, opposite = handle.rings[1].outer.front, handle.rings[17].outer.front
assert(first.child.angle == 90 and opposite.child.angle == 270)
assert(near(midpoint(first) + midpoint(opposite), 2 * dotX))
assert(host.visibility == 2 and handle.grid.visibility == 3)
assert(handle.readout.text == model.readout and handle.hint.text == model.hint)
assert(finder.visible(handle, true) and host.visibility == 3)

-- Relayout with the same physical pixels and a different viewport DPI. A
-- status change during capture must leave the root hidden until restoration.
assert(finder.visible(handle, false))
layout.dpi, model.grid, model.hint = 1, false, "Saved photo"
assert(finder.update(handle, model))
assert(handle.gridSlot.position.X == 800 and handle.gridSlot.size.X == 800)
assert(host.visibility == 2 and handle.grid.visibility == 2)
assert(handle.readout.textChanges == 1 and handle.hint.text == model.hint)

-- Modes operate inside the physical capture gate independently of G and H.
model.grid, model.reticle = true, "square"
assert(finder.update(handle, model))
assert(handle.layers.corners.panel.visibility == 2 and handle.layers.outer.panel.visibility == 2)
assert(handle.layers.dot.panel.visibility == 2 and handle.layers.brackets.panel.visibility == 3)
assert(handle.brackets[1].front.position.X == 340 and handle.grid.visibility == 3)
model.reticle, model.grid = "circle", false
assert(finder.update(handle, model))
assert(handle.layers.inner.panel.visibility == 3 and handle.layers.outer.panel.visibility == 3)
assert(handle.layers.gaps.panel.visibility == 3 and handle.layers.brackets.panel.visibility == 2)
assert(midpoint(handle.rings[1].outer.front) > midpoint(handle.rings[1].inner.front))
assert(handle.grid.visibility == 2 and host.visibility == 2)
model.reticle, model.grid = "off", true
assert(finder.update(handle, model))
assert(handle.marks.visibility == 2 and handle.grid.visibility == 3 and host.visibility == 2)

-- Long AF readouts keep their full row after the hidden shutter frame at 4K.
model.width, model.height, layout.dpi = 3840, 2160, 2
model.crop = {x = 2, y = 372, w = 3835, h = 1416}
model.reticle = "optical"
model.readout = "135 mm   Viewport   AF lock | 1000.00 m | f/5.6 equiv. | 8x DOF"
model.hint = "F9 Shutter   H Finder   G Grid   N Focus"
assert(finder.update(handle, model) and finder.visible(handle, true))
assert(handle.bounds.widthOverride == 650)
assert(handle.marks.visibility == 3 and handle.marksSlot.position.Y == 186)
dotX, dotY = midpoint(handle.dot.front)
assert(near(dotX, 3835 / 4) and near(dotY, 1416 / 4))
assert(finder.visible(handle, false))
model.hint = "Saved photo"
assert(finder.update(handle, model) and finder.visible(handle, true))
assert(handle.bounds.widthOverride == 650)
-- A small window still has room for both margins and the panel padding.
model.width, model.height, layout.dpi = 500, 300, 1
model.crop = {x = 0, y = 0, w = 500, h = 300}
assert(finder.update(handle, model))
assert(handle.bounds.widthOverride == 500 - 2 * 18 - 24)
local studio = {summary="f/8    1/125 s    ISO 200", meter="Meter    +0.0 EV",
    selected=10, key="page", rows={}}
for i = 1, 10 do studio.rows[i] = {label="Setting " .. i, value=tostring(i), locked=false} end
model.studio = studio
assert(finder.update(handle, model))
local panel = handle.studio
assert(panel.panel.visibility == 3 and handle.panel.visibility == 2)
assert(panel.summary.text == studio.summary and panel.meter.text == studio.meter)
assert(panel.capacity < 10 and panel.items[panel.capacity].value.text == "10")
assert(panel.items[panel.capacity+1].box.visibility == 1)
assert(finder.visible(handle, false) and host.visibility == 2)
studio.selected, studio.key = 1, "page 1"
assert(finder.update(handle, model))
assert(panel.items[1].label.text == "Setting 1" and host.visibility == 2)
model.studio = nil
assert(finder.update(handle, model) and panel.panel.visibility == 2 and handle.panel.visibility == 3)
model.meterEV = -1
assert(finder.update(handle, model) and handle.meter.panel.visibility == 3)
assert(near(handle.meter.indicator.position.X + 2, handle.meter.halfWidth * 2/3))
model.meterEV = 5
assert(finder.update(handle, model) and near(handle.meter.indicator.position.X + 2, 2*handle.meter.halfWidth))
model.meterEV = nil
assert(finder.update(handle, model) and handle.meter.panel.visibility == 2)
assert(finder.close(handle) and not host.attached)
assert(finder.close(handle))
rejectAdd = true
local failed, err = finder.open(session)
assert(not failed and err:match("attach the viewfinder") and host.removed)
print("Viewfinder reticles, crop geometry, DPI layout, visibility and teardown passed")
