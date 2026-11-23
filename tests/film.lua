local film = dofile("mod/Scripts/film.lua")
local s = {}
film.apply(s, nil)  -- Untouched sessions leave the gameplay grade in control.
local pp = {FilmGrainIntensity=0.02, FilmGrainTexelSize=0.8,
    bOverride_FilmGrainIntensity=false, bOverride_FilmGrainTexelSize=false}
for _, name in ipairs({"ColorSaturation", "ColorContrast", "ColorGain"}) do
    pp[name] = {X=0.95,Y=0.98,Z=1,W=1}
    pp["bOverride_" .. name] = false
end
s.lens = {PostProcessSettings=pp}
film.restore(s, {look=9,grain=true})
film.apply(s, {iso=100})
assert(pp.ColorSaturation.X == 0 and pp.bOverride_ColorSaturation)
local low = pp.FilmGrainIntensity
film.apply(s, {iso=3200})
assert(pp.FilmGrainIntensity > low and pp.bOverride_FilmGrainIntensity)
film.restore(s, {look=1,grain=false})
film.apply(s, {iso=3200})
assert(pp.ColorGain.X == 0.95 and not pp.bOverride_ColorGain)
assert(pp.FilmGrainIntensity == 0.02 and not pp.bOverride_FilmGrainIntensity)
assert(film.adjust(s, "look", -1) == film.looks[#film.looks].name)
assert(film.adjust(s, "look", 1) == "Neutral")
print("Looks, ISO-dependent film grain and restoration passed.")
