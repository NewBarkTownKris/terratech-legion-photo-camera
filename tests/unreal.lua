-- Run from the repository root with lua tests/unreal.lua.
local function object(properties)
    local value = properties or {}
    function value:IsValid() return not self.destroyed end
    function value:GetAddress() return self end
    return value
end

local function widget(visibility, inViewport, baseClass)
    return object({
        visibility = visibility,
        GetVisibility = function(self) return self.visibility end,
        SetVisibility = function(self, setting) self.visibility = setting end,
        IsInViewport = function() return inViewport end,
        IsA = function(_, class) return class.name == baseClass end,
    })
end

local viewport, world, pawn, original = object(), object(), object(), object()
local engine = object({GameViewport = viewport})
local hud = object({bShowHUD = true})
local visible = widget(3, true)
local nested = widget(0, false)
local collapsed = widget(1, true)
local cursor = widget(4, true, "TTDamageIndicatorWidget")
local foreign = widget(0, true)
local healthBar = widget(0, false, "TTEnemyHealthBarWidget")
local pc = object({view = original, PrimaryActorTick = {bTickEvenWhenPaused = false}})
function pc:IsA(class) return class.name == "TTPlayerController" and not world.menuController end
function pawn:IsA(class) return class.name == "TTPlayerPawn" and not world.menuPawn end
function visible:GetOwningPlayer() return pc end
function collapsed:GetOwningPlayer() return pc end
function cursor:GetOwningPlayer() return pc end
function foreign:GetOwningPlayer() return original end
local function component(hosted, owningWorld, hidden)
    local owner = object({GetWorld=function() return owningWorld end})
    local value = object({bHiddenInGame = hidden})
    function value:GetUserWidgetObject() return hosted end
    function value:GetOwner() return owner end
    function value:SetHiddenInGame(setting, propagate)
        assert(propagate == false)
        self.bHiddenInGame = setting
    end
    return value
end
local gauge = component(healthBar, world, false)
local hostedCursor = component(cursor, world, false)
local preHidden = component(cursor, world, true)
local otherWorld = component(healthBar, object(), false)
local unrelatedComponent = component(nested, world, false)
local activeWidgets = {visible, nested, collapsed, cursor, foreign}
local gameplay = object()
pc.moveBlocks, pc.lookBlocks = 1, 0
function pc:SetIgnoreMoveInput(state) self.moveBlocks = self.moveBlocks + (state and 1 or -1) end
function pc:SetIgnoreLookInput(state) self.lookBlocks = self.lookBlocks + (state and 1 or -1) end
function gameplay:GetPlayerController() return pc end
function gameplay:GetCurrentLevelName(w, removePrefix)
    assert(w == world and removePrefix == true)
    return {ToString=function() return world.map or "Alpha_Survival" end}
end
for obj, className in pairs({[pc]="BP_TTPlayerController_C", [pawn]="BP_TTPlayerPawn_C", [original]="CameraActor"}) do
    function obj:GetClass() return {GetFName=function() return {ToString=function() return className end} end} end
end
function gameplay:GetNumLocalPlayerControllers() return world.numPlayers or 1 end
function gameplay:IsGamePaused(w) return w.paused end
function gameplay:SetGamePaused(w, value) w.paused = value return true end
function pc:K2_GetPawn() return pawn end
function pc:GetWorld() return world end
function pc:GetHUD() return hud end
function pc:GetViewTarget() return self.view end
function pc:SetTickableWhenPaused(value) self.PrimaryActorTick.bTickEvenWhenPaused = value end
function pc:SetViewTargetWithBlend(target)
    if target == original and self.refuseRestore then return end
    if target ~= original then
        assert(target.applied, "view was switched before applying the complete camera pose")
        assert(target.angle.pitch == -24.25)
        assert(target.lens.FieldOfView == 100)
    end
    self.view = target
end
pc.PlayerCameraManager = object({
    GetCameraLocation = function() return {X = -2312044.25, Y = -13990, Z = 252535} end,
    -- UE4SS can expose a mixture of lowercase and uppercase fields.
    GetCameraRotation = function() return {pitch = -24.25, Yaw = 71, Roll = -14} end,
    GetFOVAngle = function() return 100 end,
})
local gameLook = {DepthOfFieldFstop=4, DepthOfFieldFocalDistance=1200, DepthOfFieldSensorWidth=24,
    bOverride_DepthOfFieldSensorWidth=false, bOverride_DepthOfFieldFocalDistance=true, BloomIntensity=.8}
local pov = {PostProcessSettings=gameLook, PostProcessBlendWeight=.4, ProjectionMode=0,
    bConstrainAspectRatio=false, AspectRatio=16/9, OffCenterProjectionOffset={X=0,Y=0}}
pc.PlayerCameraManager.CameraCachePrivate = {POV=pov}
function pc.PlayerCameraManager:GetCameraCachePOV() return pov end
local sourceLens = object({PostProcessBlendWeight=1, PostProcessSettings={BloomIntensity=.2},
    IsActive=function() return true end})
function original:IsA() return true end
original.CameraComponent = sourceLens
function world:SpawnActor(_, xyz, angle)
    -- UE4SS native SpawnActor parses canonical keys. Reflected setters use
    -- the game-specific spelling returned by GetCameraRotation.
    assert(xyz.X == -2312044.25 and xyz.Y == -13990 and xyz.Z == 252535)
    assert(angle.Pitch == -24.25 and angle.Yaw == 71 and angle.Roll == -14)
    local camera = object({lens = object({FieldOfView = 90})})
    -- The native FStructProperty setter makes a value copy in the destination.
    setmetatable(camera.lens, {__newindex=function(self, field, value)
        if field == "PostProcessSettings" then
            local copy = {}
            for k,v in pairs(value) do copy[k] = v end
            value = copy
        end
        rawset(self, field, value)
    end})
    function camera:GetComponentByClass() return self.lens end
    function camera.lens:SetFieldOfView(value) self.FieldOfView = value end
    function camera.lens:SetAspectRatio(value) self.AspectRatio = value end
    function camera.lens:SetConstraintAspectRatio(value) self.constrain = value end
    function camera:K2_SetActorLocationAndRotation(location, rot)
        assert(type(rot.pitch) == "number" and rot.Pitch == nil)
        assert(rot.Yaw == 71 and rot.Roll == -14)
        self.applied, self.location, self.angle = true, location, rot
        return not world.rejectTransform
    end
    function camera:EnableInput() self.input = true end
    function camera:DisableInput() self.input = false end
    function camera:K2_DestroyActor() self.destroyed = true end
    self.lastCamera = camera
    return camera
end

local screenshotCommand, mounted
local viewportWidth, viewportHeight = 1920, 1080
local env = setmetatable({
    FindFirstOf = function(name) assert(name == "GameEngine") return engine end,
    FindAllOf = function(name)
        if name == "UserWidget" then return activeWidgets end
        if name == "WidgetComponent" then return {gauge, hostedCursor, preHidden, otherWorld, unrelatedComponent} end
        error(name)
    end,
    StaticFindObject = function(path)
        local name = path:match("^/Script/TT2%.(.+)$")
        if name then return object({name=name}) end
        if path == "/Script/Engine.Default__GameplayStatics" then return gameplay end
        if path == "/Script/Engine.Default__BlueprintPathsLibrary" then
            return object({DirectoryExists = function(_, dir)
                assert(dir:find("/Saved/TerraTechLegionPhotoFolders/", 1, true))
                return mounted
            end})
        end
        if path == "/Script/UMG.Default__WidgetLayoutLibrary" then
            return object({GetViewportSize = function() return {X=viewportWidth, Y=viewportHeight} end})
        end
        if path == "/Script/Engine.Default__KismetSystemLibrary" then
            return object({ExecuteConsoleCommand = function(_, _, cmd) screenshotCommand = cmd end,
                IsStandalone = function(_, w) return w == world and not world.network end})
        end
        assert(path == "/Script/Engine.CameraComponent" or path == "/Script/Engine.CameraActor")
        return object()
    end,
}, {__index = _G})
local adapter = assert(loadfile("mod/Scripts/unreal.lua", "t", env))()

-- Title/menu and driving scenes possess the same controller and pawn classes.
for _, menu in ipairs({"FrontEnd", "L_TitleScreen", "LoadingScreen"}) do
    world.map = menu
    local result, err = adapter.open()
    assert(not result and err:find("Enter a run before using photo mode (" .. menu .. ")", 1, true))
    assert(not world.paused and not world.lastCamera and hud.bShowHUD and visible.visibility == 3)
end
world.map = nil
local function refuseProjection(field, unsupported, message)
    local saved = pov[field]
    pov[field] = unsupported
    local result, err = adapter.open()
    assert(not result and err:find(message, 1, true), err)
    assert(not world.paused and not world.lastCamera and pc.moveBlocks == 1 and hud.bShowHUD)
    pov[field] = saved
end
refuseProjection("ProjectionMode", 1, "perspective gameplay view")
refuseProjection("OffCenterProjectionOffset", {x=.1,Y=0}, "centered gameplay view")
pov.bConstrainAspectRatio = true
refuseProjection("AspectRatio", 4/3, "fills the viewport")
-- A 16:9 constraint already fills this 1920x1080 viewport.
local session = assert(adapter.open())
assert(session.lens.AspectRatio == 16/9 and session.lens.constrain == false)
pov.bConstrainAspectRatio = false
assert(session.gameplayBlendWeight == .4 and session.lens.PostProcessBlendWeight == .4)
assert(session.lens.PostProcessSettings.BloomIntensity == .8, "the evaluated POV wins over the view target")
local optics = dofile("mod/Scripts/optics.lua")
optics.toggle(session)
assert(gameLook.DepthOfFieldFocalDistance == 1200 and session.lens.PostProcessSettings.DepthOfFieldFocalDistance == 300)
optics.toggle(session)
assert(session.lens.PostProcessSettings.DepthOfFieldFocalDistance == 1200)
assert(world.paused and pc.view == session.camera and pc.PrimaryActorTick.bTickEvenWhenPaused)
assert(pc.moveBlocks == 2 and pc.lookBlocks == 1)
assert(not hud.bShowHUD and visible.visibility == 2 and nested.visibility == 0 and collapsed.visibility == 1)
assert(cursor.visibility == 2 and foreign.visibility == 0)
assert(gauge.bHiddenInGame and hostedCursor.bHiddenInGame and preHidden.bHiddenInGame)
assert(not otherWorld.bHiddenInGame and not unrelatedComponent.bHiddenInGame)
session.pose.pitch, session.pose.z = -12, 252540
assert(adapter.apply(session, session.pose))
assert(session.camera.angle.pitch == -12 and session.camera.location.Z == 252540)

local saved = "C:/users/steamuser/AppData/Local/TerraTech_Legion/Saved"
env.os = setmetatable({getenv = function(name)
    assert(name == "LOCALAPPDATA")
    return "C:\\users\\steamuser\\AppData\\Local"
end}, {__index = os})
local contents, heartbeat, pickerRequested
env.io = {open = function(path, mode)
    if path == saved .. "/TerraTechLegionPhotoDirectoryPicker.ready" then
        if not heartbeat then return nil, "missing", 2 end
        local file = assert(io.tmpfile())
        file:write(heartbeat)
        file:seek("set")
        return file
    end
    if path == saved .. "/TerraTechLegionPhotoDirectoryPicker.request" then
        assert(mode == "wb")
        pickerRequested = true
        return io.tmpfile()
    end
    assert(path == saved .. "/TerraTechLegionPhotoDirectory.txt" and mode == "rb")
    if not contents then return nil, "missing", 2 end
    local file = assert(io.tmpfile())
    file:write(contents)
    file:seek("set")
    return file
end}
assert(adapter.screenshotDir(session) == saved .. "/Screenshots/Windows")
local first, second = string.rep("a", 64), string.rep("b", 64)
mounted = true
contents = first .. "\n/home/test/Pictures/café | shots\n"
local dir, _, display = adapter.screenshotDir(session)
assert(dir == saved .. "/TerraTechLegionPhotoFolders/" .. first and display == "/home/test/Pictures/café | shots")
contents = first .. "\nD:\\Photos\\撮影\n"
local native, _, nativeDisplay = adapter.screenshotDir(session)
assert(native == dir and nativeDisplay == "D:\\Photos\\撮影")
contents = first .. "\nD:relative\n"
assert(not adapter.screenshotDir(session))
local request = {path=dir .. "/portrait.png", filename="portrait.png"}
contents = second .. "\n/media/new drive\n"
assert(adapter.screenshotDir(session) == saved .. "/TerraTechLegionPhotoFolders/" .. second)
assert(adapter.capture(session, request))
assert(screenshotCommand:find(request.path, 1, true), "finish an in-flight shot in its original folder")
viewportWidth, viewportHeight = 3840, 2160
request.viewport = {w=3840, h=2160}
request.crop = {x=2, y=372, w=3835, h=1416}
request.stagedPNG = dir .. "/.portrait.print.png"
for scale = 1, 2 do
    request.scale = scale
    assert(adapter.capture(session, request))
    local backing = scale == 1 and "1" or ("%dx%d"):format(3840 * scale, 2160 * scale)
    assert(screenshotCommand == ('HighResShot filename="%s" %s %d %d %d %d 0 0 0 0'):format(
        request.stagedPNG, backing, 2*scale, 372*scale, 3835*scale, 1416*scale))
    assert(request.width == 3835*scale and request.height == 1416*scale)
end
-- HighResShot allocates the whole scaled viewport before cropping. Even a
-- tiny output rectangle cannot make a 4K × 3 or 4K × 4 native call safe.
request.crop = {x=1800, y=0, w=240, h=2160}
for scale = 3, 4 do
    request.scale = scale
    screenshotCommand = nil
    local ok, why = adapter.capture(session, request)
    assert(not ok and why and not screenshotCommand, "oversized native PNG reached HighResShot")
end
-- A narrow viewport can exceed a single texture axis before the area limit.
viewportWidth, viewportHeight = 4200, 100
request.viewport, request.crop = {w=4200, h=100}, {x=0, y=0, w=100, h=100}
assert(not adapter.capture(session, request) and not screenshotCommand)
viewportWidth, viewportHeight = 3840, 2160
request.viewport = {w=3840, h=2160}
viewportWidth = 1920
assert(not adapter.capture(session, request), "a resized window cannot reinterpret the original crop")
mounted = false
assert(not adapter.screenshotDir(session))
contents = "../elsewhere\n/home/test\n"
assert(not adapter.screenshotDir(session))
contents = nil
assert(adapter.screenshotDir(session) == saved .. "/Screenshots/Windows")
assert(not adapter.requestDirectoryPicker() and not pickerRequested)
heartbeat = os.time() - 20
assert(not adapter.requestDirectoryPicker() and not pickerRequested)
heartbeat = os.time()
assert(adapter.requestDirectoryPicker() and pickerRequested)
assert(adapter.close(session))
assert(not world.paused and pc.view == original and session.camera.destroyed and not session.camera.input)
assert(pc.moveBlocks == 1 and pc.lookBlocks == 0)
assert(hud.bShowHUD and visible.visibility == 3 and nested.visibility == 0 and collapsed.visibility == 1)
assert(cursor.visibility == 4 and foreign.visibility == 0)
assert(not gauge.bHiddenInGame and not hostedCursor.bHiddenInGame and preHidden.bHiddenInGame)
assert(not pc.PrimaryActorTick.bTickEvenWhenPaused and not pc.bShouldPerformFullTickWhenPaused)

pov.PostProcessBlendWeight = 0
local zeroWeight = assert(adapter.open())
assert(zeroWeight.lens.PostProcessSettings == nil and zeroWeight.lens.PostProcessBlendWeight == 1,
    "an inactive override or fallback camera must not influence a later manual shot")
assert(adapter.close(zeroWeight))
pc.PlayerCameraManager.CameraCachePrivate = nil
local fallback = assert(adapter.open())
assert(fallback.lens.PostProcessSettings.BloomIntensity == .2 and fallback.lens.PostProcessBlendWeight == 1)
assert(adapter.close(fallback))
sourceLens.destroyed = true
local noSource = assert(adapter.open())
assert(noSource.lens.PostProcessSettings == nil and noSource.gameplayBlendWeight == nil)
assert(adapter.close(noSource))

world.rejectTransform = true
local failed, err = adapter.open()
assert(not failed and err:find("set initial camera transform", 1, true))
assert(not world.paused and pc.view == original and world.lastCamera.destroyed)
assert(hud.bShowHUD and visible.visibility == 3)

world.rejectTransform = false
local hideCursor = cursor.SetVisibility
function cursor:SetVisibility(value)
    hideCursor(self, value)
    if value == 2 then error("failed after hiding damage indicator") end
end
local failedHud, hudError = adapter.open()
assert(not failedHud and hudError:find("hide gameplay HUD", 1, true))
assert(cursor.visibility == 4 and visible.visibility == 3 and hud.bShowHUD)
assert(not world.paused and pc.moveBlocks == 1 and pc.lookBlocks == 0)
cursor.SetVisibility = hideCursor
local retrySession = assert(adapter.open())
pc.refuseRestore = true
assert(not adapter.close(retrySession))
assert(pc.view == retrySession.camera and not retrySession.camera.destroyed)
pc.refuseRestore = false
assert(adapter.close(retrySession))
assert(pc.view == original and retrySession.camera.destroyed and not world.paused)
for _, condition in ipairs({"paused", "network", "numPlayers", "menuController", "menuPawn"}) do
    world[condition] = condition == "numPlayers" and 2 or true
    local previousCamera = world.lastCamera
    local refused, reason = adapter.open()
    assert(not refused and reason and world.lastCamera == previousCamera and pc.view == original)
    assert(not gauge.bHiddenInGame and visible.visibility == 3)
    world[condition] = nil
end
activeWidgets = {foreign}
local lastSession = assert(adapter.open())
assert(gauge.bHiddenInGame)
-- Another view owner or a destroyed widget must keep its own state on close.
pc.view = object()
gauge.destroyed = true
assert(adapter.close(lastSession))
assert(pc.view ~= original and not world.paused)
print("Unreal adapter checks passed")
