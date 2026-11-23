-- Game-thread adapter for TerraTech Legion and UE4SS.
local unreal = {}
local folder = assert(debug.getinfo(1, "S").source:match("^@(.+[/\\])"))
local photo = dofile(folder .. "photo.lua")
local pendingRestore

local function valid(object)
    return object ~= nil and object:IsValid()
end

local function requireObject(object, description)
    assert(valid(object), description)
    return object
end

local function same(first, second)
    return valid(first) and valid(second) and first:GetAddress() == second:GetAddress()
end

local function object(path)
    return requireObject(StaticFindObject(path), "Missing Unreal object " .. path)
end

local function position(pose)
    return {X = pose.x, Y = pose.y, Z = pose.z}
end

local function rotation(pose)
    return {Pitch = pose.pitch, Yaw = pose.yaw, Roll = pose.roll}
end

local function fields(value, names)
    local result, keys = {}, {}
    -- Shipping FNames may have different display casing. UE4SS 4 serializes
    -- struct returns with those exact keys and uses rawget when writing them.
    if type(value) == "table" then
        for key in pairs(value) do
            if type(key) == "string" then
                keys[key:lower()] = key
            end
        end
    end
    for _, name in ipairs(names) do
        local lower = name:lower()
        local key = keys[lower] or name
        local item = value and value[key]
        if type(item) ~= "number" or item ~= item or math.abs(item) == math.huge then return nil end
        result[lower], keys[lower] = item, key
    end
    return result, keys
end

local function readPose(session, manager)
    local locNames, rotNames = {"X", "Y", "Z"}, {"Pitch", "Yaw", "Roll"}
    local location, locationKeys = fields(manager:GetCameraLocation(), locNames)
    local angles, angleKeys = fields(manager:GetCameraRotation(), rotNames)
    if not location or not angles then
        -- Read the manager's evaluated POV directly if the convenience
        -- functions returned an incomplete struct on this loader/build.
        local pov = manager.CameraCachePrivate.POV
        if not location then location, locationKeys = fields(pov.Location, locNames) end
        if not angles then angles, angleKeys = fields(pov.Rotation, rotNames) end
    end
    assert(location and angles, "The engine returned an incomplete camera transform")
    local fov = manager:GetFOVAngle()
    assert(type(fov) == "number" and fov > 0 and fov < 180, "The engine returned an invalid camera FOV")
    session.locationKeys, session.angleKeys = locationKeys, angleKeys
    return {x = location.x, y = location.y, z = location.z, pitch = angles.pitch,
        yaw = angles.yaw, roll = angles.roll, fov = fov}
end

local function applyPose(session, pose)
    local location, angles = session.locationKeys, session.angleKeys
    local xyz = {[location.x] = pose.x, [location.y] = pose.y, [location.z] = pose.z}
    local pyr = {[angles.pitch] = pose.pitch, [angles.yaw] = pose.yaw, [angles.roll] = pose.roll}
    local moved = session.camera:K2_SetActorLocationAndRotation(xyz, pyr, false, {}, true)
    assert(moved, "Could not move the detached camera")
    if session.lens.FieldOfView ~= pose.fov then session.lens:SetFieldOfView(pose.fov) end
end

local function viewTarget(pc, actor)
    pc:SetViewTargetWithBlend(actor, 0, 0, 0, false)
end

local function viewField(view, name)
    local value = view[name]
    if value ~= nil or type(view) ~= "table" then return value end
    for key, field in pairs(view) do
        if type(key) == "string" and key:lower() == name:lower() then return field end
    end
end

-- The finder and exporters use the full viewport as their initial gate.
-- Check the evaluated view before taking ownership of pause or input.
local function gameplayAspect(session, manager)
    local ok, view = pcall(function() return manager.CameraCachePrivate.POV end)
    if not ok or not view then
        ok, view = pcall(function() return manager:GetCameraCachePOV() end)
    end
    assert(ok and view, "Could not read the gameplay camera projection")
    local mode = viewField(view, "ProjectionMode")
    assert(type(mode) == "number", "Gameplay camera projection mode is unavailable")
    assert(mode == 0, "Photo mode requires a perspective gameplay view")
    local offset = fields(viewField(view, "OffCenterProjectionOffset"), {"X", "Y"})
    assert(offset, "Gameplay camera projection offset is unavailable")
    assert(math.abs(offset.x) < 1e-6 and math.abs(offset.y) < 1e-6,
        "Photo mode requires a centered gameplay view")
    local constrained = viewField(view, "bConstrainAspectRatio")
    local aspect = viewField(view, "AspectRatio")
    assert(type(constrained) == "boolean" and type(aspect) == "number" and aspect > 0 and aspect < math.huge,
        "Gameplay camera aspect ratio is unavailable")
    if constrained then
        local w, h = unreal.viewport(session)
        assert(w, h)
        assert(math.abs(w - h * aspect) <= math.max(1, aspect),
            "Photo mode requires a gameplay view that fills the viewport")
    end
    return aspect
end

local function postProcessLayer(view)
    local weight = view.PostProcessBlendWeight
    if type(weight) ~= "number" or not (weight >= 0 and weight <= 1) then return end
    if weight == 0 then return 0 end
    local settings = view.PostProcessSettings
    if settings then return weight, settings end
end

local function inheritCameraLook(session, manager, original, cameraClass)
    local ok, weight, settings = pcall(function()
        return postProcessLayer(manager.CameraCachePrivate.POV)
    end)
    if not ok or weight == nil then
        ok, weight, settings = pcall(function()
            if not original:IsA(cameraClass) then return end
            local activeLens = original.CameraComponent
            if valid(activeLens) and activeLens:IsActive() then return postProcessLayer(activeLens) end
        end)
    end
    if not ok or weight == nil then return end
    if weight == 0 then
        -- No camera-local layer contributed. Leave the new lens's override
        -- flags at their defaults and allow later photographic overrides.
        session.lens.PostProcessBlendWeight = 1
        return
    end
    -- UE4SS copies matching reflected structs with CopyCompleteValue. Write
    -- to the detached component only, before switching the view target.
    session.lens.PostProcessSettings = settings
    session.lens.PostProcessBlendWeight = weight
    if weight < 1 then session.gameplayBlendWeight = weight end
end

-- Each successful change registers its inverse. An invalidated UObject needs
-- no restoration. Retry failed operations if close() is called again.
local function defer(session, label, undo)
    table.insert(session.undos, {label = label, undo = undo})
end
unreal.defer = defer

function unreal.close(session)
    if not session then return true end
    local errors = {}
    for index = #session.undos, 1, -1 do
        local entry = session.undos[index]
        local ok, err = pcall(entry.undo)
        if ok then
            table.remove(session.undos, index)
        else
            table.insert(errors, entry.label .. ": " .. tostring(err))
        end
    end
    session.closed = true
    if #errors > 0 then
        pendingRestore = session
        return false, table.concat(errors, "; ")
    end
    if pendingRestore == session then pendingRestore = nil end
    return true
end

-- Legion also hosts labels and health bars in the world. Hide only components
-- carrying one of its UI types so that other in-world displays remain visible.
local markerClasses = {"TTEnemyHealthBarWidget", "TTHealthBarsWidget", "TTPlayerTechLabelWidget",
    "TTDamageIndicatorWidget", "TTDamageTextManagerWidget", "TTDamageTextEntryWidget"}

local function localWidget(widget, session)
    local owner = widget:GetOwningPlayer()
    if valid(owner) then return same(owner, session.pc) end
    local ok, world = pcall(function() return widget:GetWorld() end)
    return ok and same(world, session.world)
end

local function hideHud(session)
    local hud = session.pc:GetHUD()
    if valid(hud) and hud.bShowHUD then
        defer(session, "restore canvas HUD", function()
            if valid(hud) and valid(session.pc) and same(session.pc:GetHUD(), hud) and not hud.bShowHUD then hud.bShowHUD = true end
        end)
        hud.bShowHUD = false
    end

    for _, widget in ipairs(FindAllOf("UserWidget") or {}) do
        if valid(widget) and widget:IsInViewport() and localWidget(widget, session) then
            local visibility = widget:GetVisibility()
            if visibility ~= 1 and visibility ~= 2 then
                defer(session, "restore viewport widget", function()
                    if valid(widget) and widget:GetVisibility() == 2 and localWidget(widget, session) then
                        widget:SetVisibility(visibility)
                    end
                end)
                widget:SetVisibility(2)
            end
        end
    end

    local classes = {}
    for _, name in ipairs(markerClasses) do
        local class = StaticFindObject("/Script/TT2." .. name)
        if valid(class) then classes[#classes + 1] = class end
    end
    for _, component in ipairs(FindAllOf("WidgetComponent") or {}) do
        if valid(component) and component.bHiddenInGame == false then
            local owner = component:GetOwner()
            if valid(owner) and same(owner:GetWorld(), session.world) then
                local widget = component:GetUserWidgetObject()
                if valid(widget) then
                    for _, class in ipairs(classes) do
                        if widget:IsA(class) then
                            defer(session, "restore world-space indicator", function()
                                if valid(owner) and valid(component) and same(component:GetOwner(), owner)
                                        and same(owner:GetWorld(), session.world) and component.bHiddenInGame then
                                    component:SetHiddenInGame(false, false)
                                end
                            end)
                            component:SetHiddenInGame(true, false)
                            break
                        end
                    end
                end
            end
        end
    end
end

-- The title scene also possesses a TTPlayerPawn. These are the cooked
-- persistent worlds for the title, front end and loading screen on this build.
local menuMaps = {frontend=true, l_titlescreen=true, loadingscreen=true}

local function start(session)
    session.stage = "find gameplay controller and camera"
    local game = requireObject(FindFirstOf("GameEngine"), "Game engine is not ready")
    local viewport = requireObject(game.GameViewport, "The game has no viewport")
    local api = object("/Script/Engine.Default__GameplayStatics")
    local pc = requireObject(api:GetPlayerController(viewport, 0), "Enter a level before using the camera")
    local pawn = requireObject(pc:K2_GetPawn(), "The local player has no pawn")
    local world = requireObject(pc:GetWorld(), "The level has no active world")
    assert(api:GetNumLocalPlayerControllers(world) == 1
        and object("/Script/Engine.Default__KismetSystemLibrary"):IsStandalone(world),
        "Photo mode requires one local player in a standalone run")
    assert(not api:IsGamePaused(world), "Close the game's pause menu before entering photo mode")
    session.pc, session.world, session.pawn = pc, world, pawn
    assert(pc:IsA(object("/Script/TT2.TTPlayerController")) and pawn:IsA(object("/Script/TT2.TTPlayerPawn")),
        "Enter a run and take control of a Tech before using photo mode")
    local previous = requireObject(pc:GetViewTarget(), "The game has no active view target")
    session.stage = "identify playable world"
    local level = api:GetCurrentLevelName(world, true)
    if type(level) ~= "string" then level = level:ToString() end
    assert(type(level) == "string" and level ~= "", "Could not identify the current level")
    print(("[TerraTechLegionPhoto] Entry world=%s controller=%s pawn=%s view=%s\n"):format(level,
        pc:GetClass():GetFName():ToString(), pawn:GetClass():GetFName():ToString(),
        previous:GetClass():GetFName():ToString()))
    assert(not menuMaps[level:lower()], "Enter a run before using photo mode (" .. level .. ")")
    local manager = requireObject(pc.PlayerCameraManager, "The player has no camera manager")
    session.stage = "read rendered camera transform"
    local pose = readPose(session, manager)
    session.pose, session.api, session.viewportClient = pose, api, viewport
    session.stage = "read gameplay camera projection"
    local aspect = gameplayAspect(session, manager)

    session.stage = "pause simulation"
    defer(session, "release world pause", function()
        -- The retained world context prevents unpausing a different map on travel.
        if valid(world) and api:IsGamePaused(world) then
            assert(api:SetGamePaused(world, false), "The game declined the resume request")
        end
    end)
    assert(api:SetGamePaused(world, true), "The game declined the pause request")
    assert(api:IsGamePaused(world), "World pause did not take effect")

    session.stage = "spawn detached camera"
    local cameraClass = object("/Script/Engine.CameraActor")
    local camera = requireObject(world:SpawnActor(cameraClass,
        position(pose), rotation(pose)), "Could not spawn the photo camera")
    session.camera = camera
    defer(session, "remove camera actor", function()
        if valid(camera) then
            assert(not (valid(pc) and same(pc:GetWorld(), world) and same(pc:GetViewTarget(), camera)),
                "The player is still using the photo camera")
            camera:K2_DestroyActor()
        end
    end)
    local lensClass = object("/Script/Engine.CameraComponent")
    local lens = requireObject(camera:GetComponentByClass(lensClass),
        "The detached camera has no camera component")
    session.lens = lens
    session.stage = "inherit gameplay camera look"
    inheritCameraLook(session, manager, previous, cameraClass)
    session.stage = "set initial camera transform"
    applyPose(session, pose)
    lens:SetAspectRatio(aspect)
    lens:SetConstraintAspectRatio(false)

    -- Input still reaches the player input device for polling. The camera's
    -- empty input component blocks lower gameplay bindings while it is active.
    session.stage = "take camera input"
    camera.bBlockInput = true
    camera.InputPriority = 100000
    camera:EnableInput(pc)
    defer(session, "remove photo input", function()
        if valid(pc) and valid(camera) then
            camera:DisableInput(pc)
        end
    end)
    -- These APIs stack ignore requests. Balance only our increments so that
    -- lock-on, cutscene and other pre-existing input restrictions survive.
    pc:SetIgnoreMoveInput(true)
    defer(session, "release movement input block", function()
        if valid(pc) then pc:SetIgnoreMoveInput(false) end
    end)
    pc:SetIgnoreLookInput(true)
    defer(session, "release look input block", function()
        if valid(pc) then pc:SetIgnoreLookInput(false) end
    end)
    session.stage = "enable paused camera updates"
    local tickPaused = pc.PrimaryActorTick.bTickEvenWhenPaused
    if not tickPaused then
        pc:SetTickableWhenPaused(true)
        defer(session, "restore controller tick", function()
            if valid(pc) then pc:SetTickableWhenPaused(false) end
        end)
    end
    if not pc.bShouldPerformFullTickWhenPaused then
        pc.bShouldPerformFullTickWhenPaused = true
        defer(session, "restore paused camera updates", function()
            if valid(pc) then pc.bShouldPerformFullTickWhenPaused = false end
        end)
    end

    session.stage = "hide gameplay HUD"
    hideHud(session)
    session.stage = "switch view target"
    defer(session, "restore game view", function()
        if valid(pc) and same(pc:GetWorld(), world) and same(pc:GetViewTarget(), camera) then
            local target = valid(previous) and previous or pc:K2_GetPawn()
            assert(valid(target), "Gameplay view target is unavailable")
            viewTarget(pc, target)
            assert(not same(pc:GetViewTarget(), camera), "The photo camera is still active")
        end
    end)
    viewTarget(pc, camera)
    assert(same(pc:GetViewTarget(), camera), "The game kept control of its camera")
end

function unreal.open()
    if pendingRestore then
        local ok, err = unreal.close(pendingRestore)
        if not ok then return nil, "Gameplay restore still pending: " .. err end
        return nil, "Gameplay restored. Press F8 again to enter photo mode"
    end
    local session = {undos = {}}
    local ok, err = xpcall(start, function(err)
        return debug.traceback((session.stage or "enter photo mode") .. ": " .. tostring(err), 2)
    end, session)
    if not ok then
        local restored, cleanupError = unreal.close(session)
        if not restored then err = tostring(err) .. " (cleanup: " .. cleanupError .. ")" end
        return nil, err
    end
    return session
end

function unreal.alive(session)
    if not session or session.closed then return false, "Photo session is closed" end
    local ok, active = pcall(function()
        return valid(session.pc) and valid(session.viewportClient) and valid(session.camera)
            and valid(session.lens) and same(session.pc:GetWorld(), session.world)
            and same(session.api:GetPlayerController(session.viewportClient, 0), session.pc)
            and same(session.pc:K2_GetPawn(), session.pawn)
            and session.api:IsGamePaused(session.world)
            and same(session.pc:GetViewTarget(), session.camera)
    end)
    if not ok then return false, active end
    if not active then return false, "The game changed world, pause, pawn, or view target" end
    return true
end

function unreal.time(session)
    return session.api:GetRealTimeSeconds(session.world)
end

function unreal.apply(session, pose)
    return pcall(applyPose, session, pose)
end

function unreal.frame(session, ratio)
    return pcall(function()
        if ratio ~= nil then
            assert(type(ratio) == "number" and ratio > 0 and ratio < math.huge, "Invalid frame ratio")
            session.lens:SetAspectRatio(ratio)
        end
        session.lens:SetConstraintAspectRatio(ratio ~= nil)
    end)
end

function unreal.viewport(session)
    local ok, width, height = pcall(function()
        local size = object("/Script/UMG.Default__WidgetLayoutLibrary"):GetViewportSize(session.pc)
        assert(size.X >= 1 and size.Y >= 1, "Game viewport has no drawable area")
        return math.floor(size.X), math.floor(size.Y)
    end)
    if not ok then return nil, width end
    return width, height
end

local function savedDirectory()
    local appData = os.getenv("LOCALAPPDATA")
    if appData and appData ~= "" then
        return appData:gsub("\\", "/"):gsub("/+$", "") .. "/TerraTech_Legion/Saved"
    end
end

function unreal.requestDirectoryPicker()
    local saved = savedDirectory()
    if not saved then return nil, "Could not locate the photo settings" end
    local ready = io.open(saved .. "/TerraTechLegionPhotoDirectoryPicker.ready", "rb")
    local heartbeat = ready and tonumber(ready:read(20))
    if ready then ready:close() end
    if not heartbeat or math.abs(os.time() - heartbeat) > 10 then
        return nil, "Start the camera launcher or run photo_directory.py on your desktop"
    end
    local marker, why = io.open(saved .. "/TerraTechLegionPhotoDirectoryPicker.request", "wb")
    if not marker then return nil, why end
    return marker:close()
end

function unreal.screenshotDir(session)
    local saved = savedDirectory()
    if saved then
        local config, why, errno = io.open(saved .. "/TerraTechLegionPhotoDirectory.txt", "rb")
        if config then
            local key, displayPath, extra = config:read("l", "l", 1)
            config:close()
            local absolute = displayPath and (displayPath:match("^/") or displayPath:match("^%a:[/\\]"))
            if not key or #key ~= 64 or not key:match("^[0-9a-f]+$") or not absolute
                    or displayPath:find("[\r\n%z]") or extra then
                return nil, "Invalid photo folder setting. Choose the folder again"
            end
            local alias = saved .. "/TerraTechLegionPhotoFolders/" .. key
            local ok, exists = pcall(function()
                return object("/Script/Engine.Default__BlueprintPathsLibrary"):DirectoryExists(alias)
            end)
            if not ok or not exists then return nil, "Photo folder unavailable: " .. displayPath end
            return alias, nil, displayPath
        elseif errno ~= 2 then
            return nil, why
        end
        -- Both host installers, launchers and the offline exporter use this
        -- same profile location, including for direct-to-disk timed shots.
        return saved .. "/Screenshots/Windows"
    end
    if session.photoDir then return session.photoDir end
    local ok, dir = pcall(function()
        local paths = object("/Script/Engine.Default__BlueprintPathsLibrary")
        local dirName = paths:ScreenShotDir():ToString()
        return paths:ConvertRelativePathToFull(dirName, ""):ToString()
    end)
    if not ok or not dir or dir == "" then return nil, "Could not locate the screenshot directory" end
    session.photoDir = dir:gsub("\\", "/"):gsub("/+$", "")
    return session.photoDir
end

function unreal.capture(session, request)
    local alive, reason = unreal.alive(session)
    if not alive then return false, reason end
    return pcall(function()
        local filename = request.filename
        assert(type(filename) == "string" and filename:match("^[%w_%-]+%.png$"), "Invalid photo filename")
        local width, height = unreal.viewport(session)
        assert(width, height)
        assert(not request.viewport or (request.viewport.w == width and request.viewport.h == height),
            "Viewport changed during capture. Reframe and press the shutter again")
        local crop = request.crop or {x = 0, y = 0, w = width, h = height}
        assert(math.tointeger(crop.x) and math.tointeger(crop.y) and math.tointeger(crop.w)
            and math.tointeger(crop.h) and crop.x >= 0 and crop.y >= 0 and crop.w >= 1 and crop.h >= 1
            and crop.x + crop.w <= width and crop.y + crop.h <= height, "Invalid photo crop")
        local path = request.path
        assert(type(path) == "string" and path:sub(-#filename - 1) == "/" .. filename, "Invalid photo path")
        path = request.stagedPNG or path
        assert(not path:find('[%c"|]'), "Unreal cannot quote the screenshot path")
        local scale = request.scale or 1
        assert(math.type(scale) == "integer" and scale >= 1 and scale <= 4, "Invalid PNG capture scale")
        assert(math.max(width, height) * scale <= photo.maxRenderDimension
            and not photo.requiresStream(width, height, scale), "Print exceeds the native screenshot budget")
        request.width, request.height = crop.w * scale, crop.h * scale
        -- An explicit backing raster keeps the engine's resolution multiplier
        -- at one. The capture rectangle is expressed in that raster's pixels.
        local resolution = scale == 1 and "1" or ("%dx%d"):format(width * scale, height * scale)
        local command = string.format('HighResShot filename="%s" %s %d %d %d %d 0 0 0 0',
            path, resolution, crop.x * scale, crop.y * scale, request.width, request.height)
        object("/Script/Engine.Default__KismetSystemLibrary"):ExecuteConsoleCommand(session.pc, command, session.pc)
        return request
    end)
end

return unreal
