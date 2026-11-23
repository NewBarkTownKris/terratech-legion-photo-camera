local fringe = {}
-- Apply fringe overrides only to the detached camera and its capture settings.
local clean = {
    SceneFringeIntensity=0, bOverride_SceneFringeIntensity=true,
    ChromaticAberrationStartOffset=0, bOverride_ChromaticAberrationStartOffset=true,
}
local fields = {"SceneFringeIntensity", "ChromaticAberrationStartOffset",
    "bOverride_SceneFringeIntensity", "bOverride_ChromaticAberrationStartOffset"}

local function read(pp)
    local values = {}
    for _,field in ipairs(fields) do
        values[field] = pp[field]
        assert(type(values[field]) == type(clean[field]), "Missing camera property " .. field)
    end
    return values
end

local function write(pp, values)
    for _,field in ipairs(fields) do pp[field] = values[field] end
end

function fringe.set(session, enabled)
    local original = session.fringeOriginal
    if enabled and not original then return true, "Chromatic aberration follows the game" end
    local ok, issue = pcall(function()
        local lens = session.lens
        if enabled and (not lens or not lens:IsValid()) then
            session.fringeOriginal = nil
            return
        end
        assert(lens and lens:IsValid(), "Detached camera is unavailable")
        local pp = lens.PostProcessSettings
        local before = read(pp)
        local want = {}
        for _,field in ipairs(fields) do
            if enabled then
                -- Leave a newer edit from another camera tool in place.
                want[field] = before[field]
                if before[field] == clean[field] then want[field] = original[field] end
            else
                want[field] = clean[field]
            end
        end
        local changed, why = pcall(write, pp, want)
        if not changed then
            local restored, rollback = pcall(write, pp, before)
            if not restored then
                session.fringeOriginal = original or before
                error(tostring(why) .. " (could not restore camera settings: " .. tostring(rollback) .. ")")
            end
            error(why)
        end
        if enabled then session.fringeOriginal = nil else session.fringeOriginal = original or before end
    end)
    if not ok then return false, tostring(issue) end
    return true, enabled and "Chromatic aberration follows the game" or "Chromatic aberration off"
end

function fringe.close(session)
    return fringe.set(session,true)
end

return fringe
