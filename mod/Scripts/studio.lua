-- The Studio edits the same exposure and film controls as the finder.
-- Only dial selections are persisted; metered values belong to the current view.
local studio = {}
local controls = {
    {"mode", "Exposure mode"}, {"aperture", "Aperture"}, {"shutter", "Shutter speed"},
    {"iso", "ISO"}, {"autoISO", "Auto ISO"}, {"compensation", "EV compensation"}, {"isoMin", "Auto ISO minimum"},
    {"isoMax", "Auto ISO maximum"}, {"preferredShutter", "Preferred min. shutter"},
    {"chromatic", "Chromatic aberration"}, {"look", "Film look"}, {"grain", "ISO grain"},
}
local filmControls = {chromatic=true, look=true, grain=true}
local cameraRows = {
    {"frame", "Frame", "index"}, {"orientation", "Orientation", "boolean"},
    {"captureScale", "Capture scale", "scale"}, {"lens", "Lens", "index"},
    {"dof", "Depth of field", "boolean"}, {"strength", "DOF multiplier", "index"}, {"focusMode", "Focus mode"},
    {"reticle", "Reticle", "index"},
    {"grid", "Thirds grid", "boolean"}, {"folder", "Screenshot folder"},
}
local allControls = {table.unpack(controls)}
local cameraFields = {}
for _, row in ipairs(cameraRows) do
    allControls[#allControls+1] = row
    cameraFields[row[1]] = row[3] or "session"
end

local function configPath()
    local dir = os.getenv("LOCALAPPDATA")
    if dir and dir ~= "" then
        return dir .. "/TerraTech_Legion/Saved/TerraTechLegionPhotoStudio.ini"
    end
end

local function parse(path)
    local file = io.open(path, "rb")
    if not file then return end
    local data = file:read(4097)
    file:close()
    if not data or #data > 4096 then return end
    data = data:gsub("\r\n", "\n")
    if not data:match("^version=1\n") or not data:match("\nend=1\n$") then return end
    local selected, film, camera = {}, {}, {}
    for key, value in data:gmatch("([%w]+)=([^\n]+)\n") do
        if cameraFields[key] then
            if cameraFields[key] == "scale" then
                local scale = math.tointeger(tonumber(value))
                if scale and scale >= 1 and scale <= 4 then camera[key] = scale end
            elseif cameraFields[key] == "index" then
                local index = math.tointeger(tonumber(value))
                if index and index >= 0 then camera[key] = index end
            elseif cameraFields[key] == "boolean" and (value == "true" or value == "false") then
                camera[key] = value == "true"
            end
        elseif key == "chromatic" then
            if value == "Game" or value == "Off" then film.chromatic = value end
        elseif key == "look" then film.look = tonumber(value)
        elseif key == "grain" then
            if value == "true" or value == "false" then film.grain = value == "true" end
        elseif key == "mode" or (key == "iso" and value == "Auto") then selected[key] = value
        elseif key ~= "version" and key ~= "end" then selected[key] = tonumber(value) end
    end
    return selected, film, camera
end

local function serialize(session)
    local st = session.studio
    local exp, film = st.exposure.options(session), st.film.options(session)
    local camera = st.camera and st.camera.options(session) or {}
    local lines = {"version=1"}
    for _, control in ipairs(st.controls) do
        local key = control[1]
        local value = exp[key]
        if filmControls[key] then value = film[key]
        elseif cameraFields[key] == "session" then value = nil
        elseif cameraFields[key] then value = camera[key] end
        if value ~= nil then
            local text = type(value) == "number" and ("%.17g"):format(value) or tostring(value)
            assert(not text:find("[\r\n]"), "Invalid Studio setting")
            lines[#lines+1] = key .. "=" .. text
        end
    end
    return table.concat(lines, "\n") .. "\nend=1\n"
end

function studio.open(session, exposure, film, path, camera)
    local st = {visible=false, selected=1, exposure=exposure, film=film, path=path or configPath(),
        camera=camera, controls=camera and allControls or controls}
    session.studio = st
    if st.path then
        local values, look, composition = parse(st.path)
        if not values then values, look, composition = parse(st.path .. ".bak") end
        if values then
            local ok, reason = pcall(function()
                exposure.restore(session, values)
                film.restore(session, look)
                if camera and next(composition) then camera.restore(session, composition) end
            end)
            if not ok then return nil, reason end
        end
    end
    st.persisted = serialize(session)
    return true
end

local function writeSettings(path, data)
    local temp = path .. "." .. tostring({}):gsub("[^%w]", "") .. ".tmp"
    local file, err = io.open(temp, "wb")
    if not file then return nil, err end
    local written, writeErr = file:write(data)
    local closed, closeErr = file:close()
    if not written or not closed then
        os.remove(temp)
        return nil, writeErr or closeErr
    end
    -- Windows rename cannot replace an existing file. A previous valid
    -- generation stays readable if the process exits between the two renames.
    local ok, why = os.rename(temp, path)
    if ok then return true end
    local existing = io.open(path, "rb")
    if not existing then os.remove(temp); return nil, why end
    existing:close()
    local backup = path .. ".bak"
    os.remove(backup)
    ok, why = os.rename(path, backup)
    if not ok then os.remove(temp); return nil, why end
    ok, why = os.rename(temp, path)
    if not ok then
        os.rename(backup, path)
        os.remove(temp)
    end
    return ok, why
end

function studio.save(session)
    local st = session.studio
    local data = serialize(session)
    if st.persisted == data then return true end
    if not st.path then return nil, "Could not locate the Studio settings folder" end
    local ok, reason = writeSettings(st.path, data)
    if ok then st.persisted = data end
    return ok, reason
end

function studio.toggle(session)
    session.studio.visible = not session.studio.visible
    return session.studio.visible
end

function studio.navigate(session, delta)
    local st = session.studio
    if st.visible then st.selected = (st.selected - 1 + delta) % #st.controls + 1 end
end

local function automatic(field, opts, film)
    local game = opts.mode == "Game"
    if field == "aperture" then return opts.mode == "Shutter Priority" end
    if field == "shutter" then return game or opts.mode == "Aperture Priority" end
    if field == "iso" then
        if game then return not film.grain end
        return opts.iso == "Auto"
    end
    if field == "autoISO" or field == "compensation" then return game end
    if field == "isoMin" or field == "isoMax" then return game or opts.iso ~= "Auto" end
    if field == "preferredShutter" then return opts.mode ~= "Aperture Priority" or opts.iso ~= "Auto" end
    return false
end

function studio.dial(session, field, delta)
    local st = session.studio
    local opts = st.exposure.options(session)
    if automatic(field, opts, st.film.options(session)) then return end
    local message
    if cameraFields[field] then
        message = st.camera.adjust(session, field, delta)
    elseif field == "iso" and opts.mode == "Game" then
        -- The scene stays at game exposure. A previous Auto ISO selection
        -- supplies the starting sensitivity until the player turns this dial.
        if opts.iso == "Auto" then
            opts.iso = st.exposure.snapshot(session).iso
            st.exposure.restore(session, opts)
        end
        if delta > 0 or opts.iso > 100 then st.exposure.adjust(session, "iso", delta) end
        message = "Grain ISO " .. st.exposure.options(session).iso
    else
        local api = filmControls[field] and st.film or st.exposure
        if field ~= "iso" or delta > 0 or opts.iso ~= 100 then message = api.adjust(session, field, delta) end
    end
    local ok, reason = studio.save(session)
    if not ok then return "Studio settings could not be saved: " .. tostring(reason) end
    return message
end

function studio.adjust(session, delta)
    local st = session.studio
    if st.visible then return studio.dial(session, st.controls[st.selected][1], delta) end
end

local function fstop(value)
    return value and ("f/%g"):format(value) or "—"
end

local function ev(value)
    return type(value) == "number" and ("%+.1f EV"):format(value) or "—"
end

function studio.model(session)
    local st = session.studio
    if not st or not st.visible then return end
    local options, photo = st.exposure.options(session), st.exposure.snapshot(session)
    local film = st.film.options(session)
    local game = options.mode == "Game"
    local speed = st.exposure.shutterText
    local actualSpeed = photo.seconds and speed(photo.seconds) or "—"
    local summary = game and "Game exposure" or ("%s    %s    ISO %s"):format(
        fstop(photo.aperture), actualSpeed, tostring(photo.iso or "—"))
    local meter = game and "Meter    Game" or (photo.evError and ("Meter    " .. ev(photo.evError))
        or "Meter    Reading scene…")
    if not game and type(photo.meteredEV) == "number" then
        meter = meter .. ("     Scene EV %.1f"):format(photo.meteredEV)
    end
    local preset = st.film.looks[film.look]
    local camera = st.camera and st.camera.values(session) or {}
    local values = {
        mode = options.mode,
        aperture = options.mode == "Shutter Priority" and ("Auto  " .. fstop(photo.aperture)) or fstop(options.aperture),
        shutter = game and "Game" or (options.mode == "Aperture Priority" and ("Auto  " .. actualSpeed)
            or speed(options.shutter)),
        iso = game and (film.grain and photo.iso or "Game")
            or (options.iso == "Auto" and ("Auto  " .. tostring(photo.iso or "—")) or options.iso),
        autoISO = game and "Game" or (options.iso == "Auto" and "On" or "Off"),
        isoMin = options.isoMin, isoMax = options.isoMax,
        preferredShutter = speed(options.preferredShutter), compensation = ev(options.compensation),
        chromatic = film.chromatic or "Game", look = preset and preset.name or "—", grain = film.grain and "On" or "Off",
    }
    local rows = {}
    local key = {summary, meter, tostring(st.selected)}
    for i, control in ipairs(st.controls) do
        local field = control[1]
        local locked = automatic(field, options, film)
        local value = field == "folder" and "Choose…" or tostring(values[field] or camera[field] or "—")
        local label = field == "iso" and game and film.grain and "Grain ISO" or control[2]
        rows[i] = {label=label, value=value, locked=locked}
        key[#key+1] = value .. (locked and "*" or "")
    end
    return {summary=summary, meter=meter, rows=rows, selected=st.selected, key=table.concat(key, "|")}
end

return studio
