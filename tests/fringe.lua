local fringe = dofile("mod/Scripts/fringe.lua")
local original={SceneFringeIntensity=4.25, bOverride_SceneFringeIntensity=false,
    ChromaticAberrationStartOffset=0.35, bOverride_ChromaticAberrationStartOffset=true,
    BloomIntensity=1.9, bOverride_BloomIntensity=true}
local values={}
for k,v in pairs(original) do values[k]=v end
local writes,failNext=0,nil
local pp=setmetatable({}, {__index=values,__newindex=function(_,key,value)
    assert(key:match("SceneFringeIntensity$") or key:match("ChromaticAberrationStartOffset$"))
    if key==failNext then failNext=nil; error("reflected write failed") end
    values[key]=value
    writes=writes+1
end})
local active=true
local s={lens={PostProcessSettings=pp,IsValid=function()return active end}}
local function same()
    for k,v in pairs(original) do assert(values[k]==v, "Did not preserve " .. k) end
end
assert(fringe.set(s,true) and writes==0)
failNext="bOverride_SceneFringeIntensity"
assert(not fringe.set(s,false))
same()
assert(not s.fringeOriginal)
assert(fringe.set(s,false) and fringe.set(s,false))
assert(values.SceneFringeIntensity==0 and values.bOverride_SceneFringeIntensity)
assert(values.ChromaticAberrationStartOffset==0 and values.bOverride_ChromaticAberrationStartOffset)
assert(fringe.set(s,true)); same()
assert(fringe.set(s,false))
values.ChromaticAberrationStartOffset=0.8
assert(fringe.close(s))
assert(values.ChromaticAberrationStartOffset==0.8 and not s.fringeOriginal)
values.ChromaticAberrationStartOffset=original.ChromaticAberrationStartOffset
same()
assert(fringe.set(s,false))
active=false
assert(fringe.close(s) and not s.fringeOriginal)
assert(not fringe.set(s,false))
print("Camera chromatic aberration override, rollback and restoration passed.")
