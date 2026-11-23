-- Game-thread UMG finder. The detached camera and screenshot share the pixel
-- crop supplied by main.lua. Convert it to viewport Slate units only here.
local finder = {reticles = {"optical", "square", "circle", "off"}}
local hidden, hitTestInvisible = 2, 3
local cardContentWidth = 650
local ringSegments = 32

local function requireObject(value, description)
    assert(value and value:IsValid(), "Missing " .. description)
    return value
end

local function object(path)
    return requireObject(StaticFindObject(path), path)
end

local function xy(x, y)
    return {X = x, Y = y}
end

local function color(r, g, b, a)
    return {R = r, G = g, B = b, A = a}
end

local function rect(slot, x, y, w, h)
    slot:SetPosition(xy(x, y))
    slot:SetSize(xy(w, h))
end

local function build(handle, pc)
    -- The native burn-in class provides an empty, concrete UUserWidget. It
    -- owns the widget tree for the lifetime of the viewport overlay.
    local library = object("/Script/UMG.Default__WidgetBlueprintLibrary")
    local host = library:Create(pc, object("/Script/LevelSequence.LevelSequenceBurnIn"), pc)
    handle.host = requireObject(host, "viewfinder host")
    local tree = requireObject(host.WidgetTree, "viewfinder widget tree")
    local classes = {}
    local function make(kind)
        classes[kind] = classes[kind] or object("/Script/UMG." .. kind)
        return requireObject(StaticConstructObject(classes[kind], tree), kind)
    end
    local canvas = make("CanvasPanel")
    tree.RootWidget = canvas
    local grid = make("CanvasPanel")
    grid:SetClipping(1)
    handle.grid, handle.gridSlot = grid, canvas:AddChildToCanvas(grid)

    local function stroke(parent, alpha, angle)
        local back, front = make("Border"), make("Border")
        back:SetBrushColor(color(0, 0, 0, 0.45))
        front:SetBrushColor(color(1, 1, 1, alpha))
        if angle then
            back:SetRenderTransformAngle(angle)
            front:SetRenderTransformAngle(angle)
        end
        local slots = {back = parent:AddChildToCanvas(back), front = parent:AddChildToCanvas(front)}
        slots.front:SetZOrder(1)
        return slots
    end
    handle.guides = {stroke(grid, 0.42), stroke(grid, 0.42), stroke(grid, 0.42), stroke(grid, 0.42)}
    handle.marks = make("CanvasPanel")
    handle.marks:SetClipping(1)
    handle.marksSlot = canvas:AddChildToCanvas(handle.marks)
    handle.layers = {}
    for _, name in ipairs({"outer", "gaps", "inner", "brackets", "corners", "dot"}) do
        local layer = make("CanvasPanel")
        handle.layers[name] = {panel = layer, slot = handle.marks:AddChildToCanvas(layer)}
    end
    local function corners(layer, alpha)
        local strokes = {}
        for i = 1, 8 do strokes[i] = stroke(layer, alpha) end
        return strokes
    end
    handle.corners = corners(handle.layers.corners.panel, 0.70)
    handle.brackets = corners(handle.layers.brackets.panel, 0.92)
    handle.dot = stroke(handle.layers.dot.panel, 0.95)
    handle.rings = {}
    for i = 0, ringSegments - 1 do
        local degrees = i * 360 / ringSegments
        local radians = math.rad(degrees)
        -- Four short gaps divide the optical ring into arcs. Fill them in
        -- circle mode, where the same outer ring surrounds a second ring.
        local outer = i % (ringSegments / 4) == 0 and handle.layers.gaps or handle.layers.outer
        handle.rings[i + 1] = {
            x = math.cos(radians), y = math.sin(radians),
            outer = stroke(outer.panel, 0.72, degrees + 90),
            inner = stroke(handle.layers.inner.panel, 0.86, degrees + 90)
        }
    end

    local panel, bounds, rows = make("Border"), make("SizeBox"), make("VerticalBox")
    panel:SetBrushColor(color(0.012, 0.017, 0.020, 0.88))
    panel:SetPadding({Left = 12, Top = 7, Right = 12, Bottom = 7})
    panel:SetContent(bounds)
    bounds:SetContent(rows)
    local fontPath = "/Engine/EngineFonts/Roboto.Roboto"
    local font = StaticFindObject(fontPath)
    if not font or not font:IsValid() then
        LoadAsset(fontPath)
        font = object(fontPath)
    end
    local function label(size, face, tint)
        local text = make("TextBlock")
        text:SetFont({FontObject = font, TypefaceFontName = FName(face), Size = size})
        text:SetColorAndOpacity({SpecifiedColor = tint, ColorUseRule = 0})
        text:SetAutoWrapText(true)
        return text
    end
    local scale = {panel=make("CanvasPanel"), ticks={}}
    handle.meter = scale
    scale.slot = canvas:AddChildToCanvas(scale.panel)
    for i = -9, 9 do
        local tick = make("Border")
        tick:SetBrushColor(color(1, 1, 1, i % 3 == 0 and 0.9 or 0.55))
        scale.ticks[i] = scale.panel:AddChildToCanvas(tick)
    end
    local indicator = make("Border")
    indicator:SetBrushColor(color(1, 0.62, 0.14, 1))
    scale.indicator = scale.panel:AddChildToCanvas(indicator)
    scale.panel:SetVisibility(hidden)
    handle.readout = label(16, "Medium", color(1, 1, 1, 1))
    handle.hint = label(12, "Regular", color(0.68, 0.83, 0.85, 1))
    rows:AddChildToVerticalBox(handle.readout)
    rows:AddChildToVerticalBox(handle.hint)
    handle.panel = panel
    handle.bounds = bounds
    handle.card = canvas:AddChildToCanvas(panel)
    handle.card:SetAutoSize(true)
    handle.card:SetAlignment(xy(0, 1))
    local studio = {items={}}
    handle.studio = studio
    studio.panel, studio.bounds = make("Border"), make("SizeBox")
    local column = make("VerticalBox")
    studio.panel:SetBrushColor(color(0.014, 0.021, 0.025, 0.96))
    studio.panel:SetPadding({Left=14, Top=10, Right=14, Bottom=10})
    studio.panel:SetContent(studio.bounds)
    studio.bounds:SetContent(column)
    local white, secondary = color(0.96, 0.98, 1, 1), color(0.69, 0.79, 0.82, 1)
    local function field(text, size, face, tint)
        local widget = label(size, face, tint)
        widget:SetText(FText(text))
        column:AddChildToVerticalBox(widget)
        return widget
    end
    field("Photo Studio", 18, "Medium", white)
    studio.summary = field("", 13, "Medium", white)
    studio.meter = field("", 12, "Regular", secondary)
    for i = 1, 11 do
        local item = {box=make("SizeBox"), border=make("Border"), label=label(12, "Regular", white),
            value=label(12, "Medium", white)}
        item.box:SetHeightOverride(26)
        local line = make("CanvasPanel")
        item.border:SetPadding({Left=0, Top=0, Right=0, Bottom=0})
        item.border:SetContent(line)
        item.box:SetContent(item.border)
        item.value:SetJustification(2)
        item.label:SetAutoWrapText(false)
        item.value:SetAutoWrapText(false)
        item.labelSlot = line:AddChildToCanvas(item.label)
        item.valueSlot = line:AddChildToCanvas(item.value)
        column:AddChildToVerticalBox(item.box)
        studio.items[i] = item
    end
    studio.help = field("↑ ↓  Select     ← →  Adjust     F4  Close", 12, "Regular", secondary)
    studio.slot = canvas:AddChildToCanvas(studio.panel)
    studio.panel:SetVisibility(hidden)
    handle.layout = object("/Script/UMG.Default__WidgetLayoutLibrary")
    handle.pc = pc
    host:SetVisibility(hidden)
    host:AddToViewport(100)
    assert(host:IsInViewport(), "Unreal could not attach the viewfinder")
end

function finder.close(handle)
    return pcall(function()
        if handle and handle.host and handle.host:IsValid() then
            handle.host:RemoveFromParent()
            handle.host = nil
        end
    end)
end

function finder.open(session)
    local handle = {}
    local ok, err = pcall(build, handle, session.pc)
    if ok then return handle end
    finder.close(handle)
    return nil, err
end

function finder.visible(handle, show)
    return pcall(function()
        requireObject(handle.host, "active viewfinder"):SetVisibility(show and hitTestInvisible or hidden)
    end)
end

local function placeStroke(stroke, x, y, w, h, pixel)
    rect(stroke.back, x - pixel, y - pixel, w + 2 * pixel, h + 2 * pixel)
    rect(stroke.front, x, y, w, h)
end

local function placeCorners(strokes, cx, cy, halfW, halfH, arm, weight, outline)
    local i = 1
    for _, sy in ipairs({-1, 1}) do
        for _, sx in ipairs({-1, 1}) do
            local x, y = cx + sx * halfW, cy + sy * halfH
            placeStroke(strokes[i], x - (sx > 0 and arm or 0),
                y - (sy > 0 and weight or 0), arm, weight, outline)
            placeStroke(strokes[i + 1], x - (sx > 0 and weight or 0),
                y - (sy > 0 and arm or 0), weight, arm, outline)
            i = i + 2
        end
    end
end

local function layoutReticle(handle, w, h, pixel, mode)
    local optical, square, circle = mode == "optical", mode == "square", mode == "circle"
    handle.marks:SetVisibility(mode == "off" and hidden or hitTestInvisible)
    if mode == "off" then return end
    local shown = {outer = optical or circle, gaps = circle, inner = circle,
        brackets = optical or square, corners = optical, dot = optical}
    for name, layer in pairs(handle.layers) do
        layer.panel:SetVisibility(shown[name] and hitTestInvisible or hidden)
        rect(layer.slot, 0, 0, w, h)
    end
    local cx, cy, short = w / 2, h / 2, math.min(w, h)
    local weight = math.min(short / 32, math.max(pixel, short * 0.0012))
    local outline = math.min(weight, pixel)
    if optical then
        local inset = math.min(short * 0.04, 4 * pixel)
        placeCorners(handle.corners, cx, cy, cx - inset, cy - inset,
            short * 0.036, weight, outline)
        placeStroke(handle.dot, cx - weight, cy - weight, 2 * weight, 2 * weight, outline)
    end
    if optical or square then
        local halfW = short * (optical and 0.021 or 0.075)
        placeCorners(handle.brackets, cx, cy, halfW, halfW * 0.72, halfW * 0.40, weight, outline)
    end
    if optical or circle then
        local halfAngle = math.pi / ringSegments
        local function placeChord(stroke, dx, dy, radius)
            local distance = radius * math.cos(halfAngle)
            local length = 2 * radius * math.sin(halfAngle) + outline * 0.5
            placeStroke(stroke, cx + dx * distance - length / 2,
                cy + dy * distance - weight / 2, length, weight, outline)
        end
        for _, segment in ipairs(handle.rings) do
            placeChord(segment.outer, segment.x, segment.y, short * (optical and 0.10 or 0.12))
            if circle then placeChord(segment.inner, segment.x, segment.y, short * 0.091) end
        end
    end
end

local function layout(handle, model, dpi)
    local crop = model.crop
    local pixel = 1 / dpi
    local width, height = model.width * pixel, model.height * pixel
    local x, y, w, h = crop.x * pixel, crop.y * pixel, crop.w * pixel, crop.h * pixel
    handle.host:SetDesiredSizeInViewport(xy(width, height))
    handle.host:SetPositionInViewport(xy(0, 0), false)
    rect(handle.gridSlot, x, y, w, h)
    for i = 1, 2 do
        placeStroke(handle.guides[i], w * i / 3, 0, pixel, h, pixel)
        placeStroke(handle.guides[i + 2], 0, h * i / 3, w, pixel, pixel)
    end
    rect(handle.marksSlot, x, y, w, h)
    local scale = handle.meter
    scale.halfWidth = math.min(84, w * 0.25)
    rect(scale.slot, x + w/2 - scale.halfWidth, y + math.min(16, h/16), scale.halfWidth * 2, 18)
    for i = -9, 9 do
        local height = i == 0 and 10 or (i % 3 == 0 and 7 or 4)
        rect(scale.ticks[i], scale.halfWidth * (1 + i/9) - 0.5, 10-height, 1, height)
    end
    local margin = math.min(18, width / 16, height / 16)
    handle.card:SetPosition(xy(margin, height - margin))
    -- Auto-wrapped text measures against its last allotted width. Give the
    -- rows a stable width after shutter visibility and status changes, while
    -- allowing the card height to follow wrapped text on narrower displays.
    handle.bounds:SetWidthOverride(math.max(1, math.min(cardContentWidth, width - 2 * margin - 24)))
    local studio = handle.studio
    studio.width = math.max(1, math.min(320, width - 2 * margin - 28))
    studio.capacity = math.max(1, math.min(#studio.items, math.floor((height - 2 * margin - 122) / 26)))
    studio.bounds:SetWidthOverride(studio.width)
    studio.slot:SetAutoSize(true)
    studio.slot:SetPosition(xy(margin, margin))
    local split = math.floor(studio.width * 0.53)
    for _, item in ipairs(studio.items) do
        rect(item.labelSlot, 6, 3, math.max(1, split - 6), 22)
        rect(item.valueSlot, split, 3, math.max(1, studio.width - split - 6), 22)
    end
end

local function updateStudio(handle, model, resized)
    local view = handle.studio
    if not model then
        if view.key then
            view.panel:SetVisibility(hidden)
            handle.panel:SetVisibility(hitTestInvisible)
            view.key = nil
        end
        return
    end
    if view.key == model.key and not resized then return end
    view.key = model.key
    handle.panel:SetVisibility(hidden)
    view.panel:SetVisibility(hitTestInvisible)
    view.summary:SetText(FText(model.summary))
    view.meter:SetText(FText(model.meter))
    local limit = math.min(view.capacity, #model.rows)
    local start = math.max(1, math.min(model.selected - limit // 2, #model.rows - limit + 1))
    for i, item in ipairs(view.items) do
        local index = start + i - 1
        if i > limit then
            item.box:SetVisibility(1) -- Collapsed rows release their vertical space.
        else
            local row = model.rows[index]
            local selected = index == model.selected
            item.box:SetVisibility(hitTestInvisible)
            item.border:SetBrushColor(selected and color(0.07, 0.22, 0.25, 1) or color(0, 0, 0, 0))
            local tint = row.locked and color(0.60, 0.67, 0.69, 1) or color(0.96, 0.98, 1, 1)
            local slateColor = {SpecifiedColor=tint, ColorUseRule=0}
            item.label:SetColorAndOpacity(slateColor)
            item.value:SetColorAndOpacity(slateColor)
            item.label:SetText(FText(row.label))
            item.value:SetText(FText(row.value))
        end
    end
end

function finder.update(handle, model)
    return pcall(function()
        requireObject(handle.host, "active viewfinder")
        local crop = model.crop
        assert(model.width > 0 and model.height > 0 and crop.w > 0 and crop.h > 0, "Invalid finder dimensions")
        local dpi = handle.layout:GetViewportScale(handle.pc)
        assert(dpi > 0, "Invalid viewport DPI scale")
        local resized = handle.width ~= model.width or handle.height ~= model.height or handle.dpi ~= dpi
            or handle.x ~= crop.x or handle.y ~= crop.y or handle.w ~= crop.w or handle.h ~= crop.h
        if resized then
            layout(handle, model, dpi)
            handle.width, handle.height, handle.dpi = model.width, model.height, dpi
            handle.x, handle.y, handle.w, handle.h = crop.x, crop.y, crop.w, crop.h
        end
        local reticle = model.reticle or "optical"
        if resized or handle.reticle ~= reticle then
            layoutReticle(handle, crop.w / dpi, crop.h / dpi, 1 / dpi, reticle)
            handle.reticle = reticle
        end
        local gridShown = model.grid == true
        if gridShown ~= handle.gridShown then
            handle.grid:SetVisibility(gridShown and hitTestInvisible or hidden)
            handle.gridShown = gridShown
        end
        updateStudio(handle, model.studio, resized)
        local ev = not model.studio and model.meterEV
        if ev ~= handle.meter.ev or resized then
            local scale = handle.meter
            scale.ev = ev
            scale.panel:SetVisibility(type(ev) == "number" and hitTestInvisible or hidden)
            if type(ev) == "number" then
                local x = scale.halfWidth * (1 + math.max(-3, math.min(3, ev))/3)
                rect(scale.indicator, x-2, 11, 4, 5)
            end
        end
        for _, key in ipairs({"readout", "hint"}) do
            local value = model[key] or ""
            local previous = key .. "Value"
            if handle[previous] ~= value then
                handle[key]:SetText(FText(value))
                handle[previous] = value
            end
        end
    end)
end

return finder
