local folder = assert(debug.getinfo(1, "S").source:match("^@(.+[/\\])"))
local gamepad = dofile(folder .. "gamepad.lua")
local mouselook = dofile(folder .. "mouselook.lua")
local input = {}
local active
local actions

local bindings = {
    help = "F1", directory = "F2", gradingCapture = "F3", studio = "F4",
    frame = "F5", portrait = "F6", lens = "F7",
    toggle = "F8", capture = "F9", level = "P",
    finder = "H", grid = "G", reticle = "R", chromatic = "C", dof = "B", autofocus = "N", tracking = "T",
    nearer = "J", farther = "K", fineFocus = "L", wider = "U", narrower = "I", strength = "Y",
}

local keys = {}
local function key(name)
    if not keys[name] then
        keys[name] = { KeyName = FName(name) }
    end
    return keys[name]
end

local function held(controller, name)
    return controller:IsInputKeyDown(key(name))
end

local function readAnalog(controller, name)
    return controller:GetInputAnalogKeyState(key(name))
end

local function axis(controller, positive, negative)
    return (held(controller, positive) and 1 or 0) - (held(controller, negative) and 1 or 0)
end

local padButtons = {
    {"Gamepad_FaceButton_Bottom", "capture"}, {"Gamepad_FaceButton_Top", "gradingCapture"},
    {"Gamepad_RightThumbstick", "autofocus"}, {"Gamepad_LeftThumbstick", "studio"},
}

local function buttonDown(pc, name)
    local ok, value = pcall(held, pc, name)
    if ok and type(value) == "boolean" then return value end
end

local function padAxis(pc, positive, negative)
    return (buttonDown(pc, positive) and 1 or 0) - (buttonDown(pc, negative) and 1 or 0)
end

local chordButtons = {
    "Gamepad_FaceButton_Left", "Gamepad_FaceButton_Right", "Gamepad_Special_Right",
    "Gamepad_DPad_Up", "Gamepad_DPad_Down", "Gamepad_DPad_Left", "Gamepad_DPad_Right",
    "Gamepad_LeftShoulder", "Gamepad_RightShoulder", "Gamepad_LeftTrigger", "Gamepad_RightTrigger",
    "LeftMouseButton", "MiddleMouseButton", "RightMouseButton",
}
local chordAxes = {
    "Gamepad_LeftX", "Gamepad_LeftY", "Gamepad_RightX", "Gamepad_RightY",
    "Gamepad_LeftTriggerAxis", "Gamepad_RightTriggerAxis",
}

local function otherChordInput(pc)
    for _, name in ipairs(chordButtons) do
        if buttonDown(pc, name) then return true end
    end
    for _, name in ipairs(chordAxes) do
        local ok, value = pcall(readAnalog, pc, name)
        if ok and type(value) == "number" and math.abs(value) > 0.2 then return true end
    end
    return false
end

-- Poll these only on the photo loop. Seed each button from the current
-- state so that holding a gameplay button across F8 cannot trip the shutter.
local function padShortcut(pc, state)
    local pressed, edges, otherHeld = nil, 0, false
    for _, binding in ipairs(padButtons) do
        local name, action = binding[1], binding[2]
        local down = buttonDown(pc, name)
        if down then
            otherHeld = true
            if state[name] == false then
                pressed, edges = action, edges + 1
            end
        end
        state[name] = down
    end
    local back, previous = buttonDown(pc, "Gamepad_Special_Left"), state.back
    if back or previous then
        otherHeld = otherHeld or otherChordInput(pc)
    end
    local resume = back == false and previous == true and state.resumeArmed and not otherHeld
    if back and previous ~= true then state.resumeArmed = previous == false end
    if not back or otherHeld then state.resumeArmed = false end
    state.back = back
    if resume then return "toggle" end
    if not back and not previous and edges == 1 then return pressed end
end

local function mouseShortcut(pc, state, enabled)
    local left, middle = buttonDown(pc, "LeftMouseButton"), buttonDown(pc, "MiddleMouseButton")
    local action
    if enabled and state.finderInput and not state.back then
        if left and state.left == false and not middle then action = "capture"
        elseif middle and state.middle == false and not left then action = "autofocus" end
    end
    state.left, state.middle, state.finderInput = left, middle, enabled
    return action
end

local function pressed(pc, name)
    return pc:WasInputKeyJustPressed(key(name))
end

local function wheelDirection(pc, state)
    local ok, value = pcall(readAnalog, pc, "MouseWheelAxis")
    local sign = 0
    if ok and type(value) == "number" and math.abs(value) > 0.01 and math.abs(value) < math.huge then
        sign = value > 0 and 1 or -1
    end
    local previous = state.wheel
    state.wheel = sign
    if previous == nil then return 0 end
    local okUp, up = pcall(pressed, pc, "MouseScrollUp")
    local okDown, down = pcall(pressed, pc, "MouseScrollDown")
    if okUp and okDown and up ~= down then return up and 1 or -1 end
    -- Some builds expose only the analog wheel. A held/stale value must
    -- not step focus every frame when the mouse is still.
    if sign ~= previous then return sign end
    return 0
end

local function cameraAxes(pc, readMouse, now, editing)
    local speed = 1
    if held(pc, "LeftControl") or held(pc, "RightControl") then
        speed = 0.2
    elseif held(pc, "LeftShift") or held(pc, "RightShift") then
        speed = 4
    end
    local axes = {
        forward = axis(pc, "W", "S"), right = axis(pc, "D", "A"), up = axis(pc, "E", "Q"),
        yaw = axis(pc, "Right", "Left"), pitch = axis(pc, "Up", "Down"), roll = axis(pc, "X", "Z"),
        zoom = axis(pc, "RightBracket", "LeftBracket"), speed = speed,
    }
    gamepad.apply(axes, readAnalog, pc)
    axes.mouseYaw, axes.mousePitch = readMouse(now)
    if editing then
        axes.menuX = axes.yaw + padAxis(pc, "Gamepad_DPad_Right", "Gamepad_DPad_Left")
        axes.menuY = -axes.pitch + padAxis(pc, "Gamepad_DPad_Down", "Gamepad_DPad_Up")
    else
        axes.up = math.max(-1, math.min(1, axes.up + padAxis(pc, "Gamepad_RightShoulder", "Gamepad_LeftShoulder")))
    end
    return axes
end

-- One-shot actions use UE4SS's foreground key binds. Movement is read from
-- the local player's Unreal input state only while the photo session exists.
function input.install(callbacks)
    assert(EngineTickAvailable or ProcessEventAvailable, "UE4SS has no game-thread scheduler available")
    actions = callbacks
    for action, name in pairs(bindings) do
        local invoke = assert(callbacks[action], "Missing photo camera action: " .. action)
        RegisterKeyBind(Key[name], function()
            local origin = active
            if not origin and action ~= "toggle" then return end
            local function dispatch()
                if active == origin then invoke() end
            end
            local method = EngineTickAvailable and EGameThreadMethod.EngineTick
                or EGameThreadMethod.ProcessEvent
            ExecuteInGameThread(dispatch, method)
        end)
    end
end

-- Call on the game thread. stop() is idempotent, including when called from tick.
function input.stop(loop)
    if not loop or active ~= loop then return end
    active = nil
    CancelDelayedAction(loop.handle)
end

-- tick(seconds, axes) runs even when all axes are neutral. Return false to
-- stop polling. Errors stop the loop before handing control to onError.
function input.start(pc, tick, onError, studioOpen, finderVisible)
    assert(not active, "Photo camera input loop already started")
    assert(pc and pc:IsValid(), "Local player controller is unavailable")
    local clock = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    assert(clock and clock:IsValid(), "Gameplay clock is unavailable")
    local previousTime = clock:GetRealTimeSeconds(pc)
    local readMouse = mouselook.reader(pc, readAnalog)
    local loop = {}
    local buttons = {}
    padShortcut(pc, buttons)
    wheelDirection(pc, buttons)
    local function clicksEnabled(editing)
        return not editing and (not finderVisible or finderVisible())
    end
    mouseShortcut(pc, buttons, clicksEnabled(studioOpen and studioOpen()))
    local function step()
        assert(pc:IsValid(), "Photo camera player controller expired")
        local now = clock:GetRealTimeSeconds(pc)
        local seconds = math.min(0.1, math.max(0, now - previousTime))
        local editing = studioOpen and studioOpen()
        if now ~= previousTime then
            local action = padShortcut(pc, buttons)
            local wheel = wheelDirection(pc, buttons)
            local click = mouseShortcut(pc, buttons, clicksEnabled(editing))
            if action then
                actions[action]()
                if active ~= loop then return false end
                editing = studioOpen and studioOpen()
            elseif click then
                actions[click]()
            elseif wheel ~= 0 and not editing then
                local ctrl = held(pc, "LeftControl") or held(pc, "RightControl")
                local alt = held(pc, "LeftAlt") or held(pc, "RightAlt")
                local shift = held(pc, "LeftShift") or held(pc, "RightShift")
                if ctrl and alt then action = wheel > 0 and "isoUp" or "isoDown"
                elseif alt then action = wheel > 0 and "faster" or "slower"
                elseif ctrl or shift then action = wheel > 0 and "wider" or "narrower"
                else action = wheel > 0 and "farther" or "nearer" end
                actions[action]()
            end
        end
        previousTime = now
        return tick(seconds, cameraAxes(pc, readMouse, now, editing))
    end
    local function update()
        if active ~= loop then return end
        local ok, keepGoing = pcall(step)
        if ok and keepGoing ~= false then return end
        local stopped, issue = pcall(input.stop, loop)
        if not ok then
            onError(stopped and keepGoing or (tostring(keepGoing) .. " / " .. tostring(issue)))
        elseif not stopped then
            onError(issue)
        end
    end
    -- UE4SS's engine frame counter continues when the UWorld is paused.
    -- Older configurations can dispatch wall-clock delayed actions instead.
    if EngineTickAvailable then
        loop.handle = LoopInGameThreadAfterFrames(1, update)
    else
        loop.handle = LoopInGameThreadWithDelay(16, update)
    end
    assert(loop.handle, "Failed to schedule the photo camera input loop")
    active = loop
    return loop
end

-- Flush pressed keys before restoring gameplay input. Some games omit the
-- Enhanced Input library, so an unavailable flush must allow cleanup to finish.
function input.flush(pc)
    if not pc or not pc:IsValid() then return false end
    local library = StaticFindObject("/Script/EnhancedInput.Default__EnhancedInputLibrary")
    if not library or not library:IsValid() then return false end
    return pcall(function() library:FlushPlayerInput(pc) end)
end

return input
