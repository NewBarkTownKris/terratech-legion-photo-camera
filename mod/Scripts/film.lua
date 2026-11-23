-- Display-referred creative controls on the detached camera. The HDR shutter
-- has its own scene-color component and does not use these grading settings.
local film = {}
local folder = assert(debug.getinfo(1, "S").source:match("^@(.+[/\\])"))
local fringe = dofile(folder .. "fringe.lua")
film.looks = {
    {name="Neutral"},
    {name="Daylight negative", saturation=1.06, contrast=0.99, gain={1.055,1.01,0.94}},
    {name="Pastel negative", saturation=0.76, contrast=0.89, gain={1.04,1.0,0.98}},
    {name="Chrome slide", saturation=1.31, contrast=1.13, gain={1.01,1.045,1.0}},
    {name="Color print", saturation=1.17, contrast=1.06, gain={1.045,0.985,1.01}},
    {name="Instant print", saturation=0.83, contrast=0.86, gain={1.05,1.012,0.96}},
    {name="Tungsten negative", saturation=0.88, contrast=1.045, gain={0.89,1.01,1.14}},
    {name="Cross process", saturation=1.16, contrast=1.15, gain={1.04,1.065,0.91}},
    {name="Fine monochrome", saturation=0, contrast=0.97},
    {name="Silver print", saturation=0, contrast=1.12},
    {name="Hard monochrome", saturation=0, contrast=1.28},
}

local vectors = {"ColorSaturation", "ColorContrast", "ColorGain"}
local function vec(x,y,z)
    return {X=x, Y=y or x, Z=z or x, W=1}
end

local function state(s)
    if not s.film then s.film = {look=1, grain=false, chromatic="Game"} end
    return s.film
end

function film.options(s)
    local f = state(s)
    return {look=f.look, grain=f.grain, chromatic=f.chromatic}
end

local function baseline(pp)
    local saved = {}
    for _, name in ipairs(vectors) do
        local v = pp[name]
        saved[name] = {X=v.X,Y=v.Y,Z=v.Z,W=v.W}
        saved["bOverride_" .. name] = pp["bOverride_" .. name]
    end
    for _, name in ipairs({"FilmGrainIntensity", "FilmGrainTexelSize"}) do
        saved[name] = pp[name]
        saved["bOverride_" .. name] = pp["bOverride_" .. name]
    end
    return saved
end

function film.apply(s, snapshot)
    local f = state(s)
    if f.chromatic ~= (f.appliedChromatic or "Game") then
        local ok, reason = fringe.set(s, f.chromatic == "Game")
        if not ok then
            f.chromatic = f.appliedChromatic or "Game"
            return reason
        end
        f.appliedChromatic = f.chromatic
    end
    local iso = snapshot and snapshot.iso or 100
    local signature = f.look .. "/" .. tostring(f.grain and iso or false)
    if signature == f.applied or (not f.original and f.look == 1 and not f.grain) then return end
    local pp = s.lens.PostProcessSettings
    f.original = f.original or baseline(pp)
    local look = film.looks[f.look]
    local values = {ColorSaturation=vec(look.saturation or 1), ColorContrast=vec(look.contrast or 1),
        ColorGain=look.gain and vec(table.unpack(look.gain)) or vec(1)}
    for _, name in ipairs(vectors) do
        pp[name] = f.look ~= 1 and values[name] or f.original[name]
        pp["bOverride_" .. name] = f.look ~= 1 or f.original["bOverride_" .. name]
    end
    -- Use the engine film-grain pass at display resolution. Increase grain
    -- strength and size in photographic stops, using the resolved Auto ISO.
    local stops = math.max(0, math.min(6, math.log(iso / 100, 2)))
    pp.FilmGrainIntensity = f.grain and (0.065 + stops * 0.052) or f.original.FilmGrainIntensity
    pp.FilmGrainTexelSize = f.grain and (1.0 + stops * 0.095) or f.original.FilmGrainTexelSize
    pp.bOverride_FilmGrainIntensity = f.grain or f.original.bOverride_FilmGrainIntensity
    pp.bOverride_FilmGrainTexelSize = f.grain or f.original.bOverride_FilmGrainTexelSize
    f.applied = signature
end

function film.restore(s, options)
    local f = state(s)
    if options and math.type(options.look) == "integer" and film.looks[options.look] then
        f.look = options.look
    end
    if options and type(options.grain) == "boolean" then f.grain = options.grain end
    if options and (options.chromatic == "Game" or options.chromatic == "Off") then f.chromatic = options.chromatic end
end

function film.adjust(s, field, step)
    local f = state(s)
    if field == "look" then
        f.look = (f.look - 1 + step) % #film.looks + 1
        return film.looks[f.look].name
    elseif field == "grain" then
        f.grain = not f.grain
        return f.grain and "ISO film grain on" or "ISO film grain off"
    elseif field == "chromatic" then
        local enabled = f.chromatic == "Off"
        local ok, why = fringe.set(s, enabled)
        if not ok then return why end
        f.chromatic = enabled and "Game" or "Off"
        f.appliedChromatic = f.chromatic
        return enabled and "Game chromatic aberration" or "Chromatic aberration off"
    end
end

function film.close(s)
    if s.film and s.film.appliedChromatic == "Off" then return fringe.set(s, true) end
    return true
end

return film
