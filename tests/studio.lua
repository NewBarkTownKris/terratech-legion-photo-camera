local studio = dofile("mod/Scripts/studio.lua")
local exposure = dofile("mod/Scripts/exposure.lua")
local film = dofile("mod/Scripts/film.lua")
local function session()
    local s = {pose={fov=75}, lens={IsValid=function() return true end, PostProcessSettings={
        AutoExposureMethod=0, AutoExposureApplyPhysicalCameraExposure=true, AutoExposureBias=1,
        bOverride_AutoExposureMethod=false, bOverride_AutoExposureApplyPhysicalCameraExposure=false,
        bOverride_AutoExposureBias=false,
        SceneFringeIntensity=2, bOverride_SceneFringeIntensity=false,
        ChromaticAberrationStartOffset=0, bOverride_ChromaticAberrationStartOffset=false,
    }}}
    return s
end

local file = os.tmpname()
os.remove(file)
local function read()
    local f = io.open(file, "rb")
    if not f then return end
    local data = f:read("a")
    f:close()
    return data
end
local function selectRow(s, name)
    local view = studio.model(s)
    for i, row in ipairs(view.rows) do
        if row.label == name then
            studio.navigate(s, i - view.selected)
            return studio.model(s).rows[i]
        end
    end
    error(name)
end

local s = session()
assert(studio.open(s, exposure, film, file))
assert(not studio.model(s) and not read())
studio.adjust(s, 1)
assert(studio.toggle(s))
local view = studio.model(s)
assert(view.selected == 1 and view.summary == "Game exposure")
assert(selectRow(s, "Shutter speed").locked)
studio.adjust(s, 1)
assert(not read(), "opening, navigating and locked controls must not save defaults")
local ca = selectRow(s, "Chromatic aberration")
assert(not ca.locked and ca.value == "Game")
local caIndex = studio.model(s).selected
assert(studio.model(s).rows[caIndex + 1].label == "Film look")
studio.adjust(s, 1)
assert(film.options(s).chromatic == "Off" and read():find("chromatic=Off", 1, true))
assert(exposure.options(s).mode == "Game" and film.options(s).look == 1 and not film.options(s).grain)
assert(selectRow(s, "ISO").locked)
selectRow(s, "ISO grain")
studio.adjust(s, 1)
assert(not selectRow(s, "Grain ISO").locked)
studio.adjust(s, -1)
assert(exposure.options(s).iso == 100, "Game-mode grain has a fixed ISO floor")
studio.adjust(s, 1)
assert(exposure.snapshot(s).iso == 125 and exposure.snapshot(s).gain == 1)
local options = exposure.options(s)
options.iso, options.isoMin = "Auto", 400
exposure.restore(s, options)
assert(selectRow(s, "Grain ISO").value == "400")
studio.adjust(s, 1)
assert(exposure.options(s).iso == 500 and exposure.snapshot(s).gain == 1)
options.iso, options.isoMin = 100, 100
exposure.restore(s, options)
selectRow(s, "ISO grain")
studio.adjust(s, 1)
assert(selectRow(s, "ISO").locked and film.options(s).chromatic == "Off")
selectRow(s, "Exposure mode")
studio.adjust(s, 1)
assert(exposure.options(s).mode == "Manual")
assert(read():find("mode=Manual",1,true))
selectRow(s, "Aperture")
studio.adjust(s, 1)
assert(exposure.options(s).aperture == 3.2)
selectRow(s, "Auto ISO")
studio.adjust(s, 1)
assert(exposure.options(s).iso == "Auto" and selectRow(s, "ISO").locked)
assert(not selectRow(s, "Auto ISO minimum").locked)
studio.adjust(s, 1)
selectRow(s, "Exposure mode")
studio.adjust(s, 1)
assert(exposure.options(s).mode == "Aperture Priority")
assert(selectRow(s, "Shutter speed").locked)
assert(not selectRow(s, "Preferred min. shutter").locked)
studio.adjust(s, 1)
selectRow(s, "Film look")
studio.adjust(s, 1)
selectRow(s, "ISO grain")
studio.adjust(s, 1)
assert(film.options(s).look == 2 and film.options(s).grain)
local settings = read()
assert(settings:find("iso=Auto") and settings:find("isoMin=125") and settings:find("grain=true"))
assert(not settings:find("meteredEV") and not settings:find("selected") and not settings:find("gain="))
-- Effective metered values are displayed, without changing the selected dials on disk.
s.exposure.result = exposure.solve(exposure.options(s), .36)
view = studio.model(s)
assert(view.meter:find("Scene EV") and view.summary:find("ISO"))
assert(studio.save(s) and read() == settings)
assert(not studio.toggle(s) and not studio.model(s))
local reopened = session()
assert(studio.open(reopened, exposure, film, file))
assert(exposure.options(reopened).aperture == 3.2 and film.options(reopened).look == 2
    and film.options(reopened).grain and exposure.options(reopened).iso == "Auto")
assert(film.options(reopened).chromatic == "Off")
assert(not reopened.studio.visible and reopened.studio.selected == 1)
assert(os.rename(file, file .. ".bak"))
local bad = assert(io.open(file, "wb"))
bad:write("version=1\nmode=Game\n")
bad:close()
local recovered = session()
assert(studio.open(recovered, exposure, film, file))
assert(exposure.options(recovered).mode == "Aperture Priority" and film.options(recovered).grain)
assert(film.options(recovered).chromatic == "Off")
for _, line in ipairs({"", "chromatic=unknown\n"}) do
    local legacy = assert(io.open(file, "wb"))
    legacy:write("version=1\n", line, "look=2\nend=1\n")
    legacy:close()
    local old = session()
    assert(studio.open(old, exposure, film, file))
    assert(film.options(old).chromatic == "Game" and film.options(old).look == 2)
end
os.remove(file)
os.remove(file .. ".bak")
-- Composition callbacks share the same panel; only durable dials belong in
-- the INI. The shell chooser and the subject focus mode stay session-local.
local restores, folders = 0, 0
local camera = {
    options=function(s) return s.camera end,
    values=function(s) return {lens=s.camera.lens == 0 and "Game FOV" or "16 mm",
        focusMode=s.camera.focusMode, grid=s.camera.grid and "On" or "Off",
        captureScale=("%d× %d×%d"):format(s.camera.captureScale, 3835*s.camera.captureScale, 1416*s.camera.captureScale)} end,
    adjust=function(s, field, delta)
        if field == "folder" then folders = folders + 1
        elseif field == "focusMode" then s.camera.focusMode = "AF-C"
        elseif field == "grid" then s.camera.grid = not s.camera.grid
        else s.camera[field] = s.camera[field] + delta end
    end,
    restore=function(s, options)
        restores = restores + 1
        assert(options.focusMode == nil and options.folder == nil)
        for key,v in pairs(options) do s.camera[key] = v end
    end,
}
local function composed()
    local sess = session()
    sess.camera={lens=0, frame=1, orientation=false, dof=false, strength=1, grid=false, reticle=1,
        focusMode="Manual", captureScale=1}
    assert(studio.open(sess, exposure, film, file, camera))
    studio.toggle(sess)
    return sess
end
local comp = composed()
assert(restores==0 and not read())
assert(selectRow(comp, "Capture scale").value == "1× 3835×1416")
for scale = 2,4 do
    studio.adjust(comp, 1)
    assert(selectRow(comp, "Capture scale").value == ("%d× %d×%d"):format(scale, 3835*scale, 1416*scale))
    assert(read():find("captureScale=" .. scale .. "\n", 1, true))
end
assert(selectRow(comp, "Lens").value == "Game FOV")
studio.adjust(comp, 1)
assert(selectRow(comp, "Lens").value == "16 mm")
selectRow(comp, "Focus mode"); studio.adjust(comp, 1)
assert(selectRow(comp, "Focus mode").value == "AF-C")
selectRow(comp, "Thirds grid"); studio.adjust(comp, 1)
assert(selectRow(comp, "Screenshot folder").value == "Choose…")
studio.adjust(comp, 1)
local compData = read()
assert(folders==1 and not compData:find("focusMode") and not compData:find("folder"))
local nextComp = composed()
assert(restores==1 and nextComp.camera.lens==1 and nextComp.camera.grid)
assert(nextComp.camera.focusMode=="Manual" and nextComp.camera.orientation==false)
assert(nextComp.camera.captureScale == 4)
selectRow(nextComp, "Capture scale"); studio.adjust(nextComp, -1)
assert(composed().camera.captureScale == 3)
-- Old and malformed settings leave the 1x default and preserve the other dials.
for _, entry in ipairs({"", "captureScale=0\n", "captureScale=5\n", "captureScale=1.5\n", "captureScale=large\n"}) do
    local legacy = assert(io.open(file, "wb"))
    legacy:write("version=1\n", entry, "lens=1\nend=1\n")
    legacy:close()
    local loaded = composed()
    assert(loaded.camera.captureScale == 1 and loaded.camera.lens == 1)
end
os.remove(file)
os.remove(file .. ".bak")
print("Photo Studio navigation, priority controls, meter readout, film selection and saved capture scales passed.")
