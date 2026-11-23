local pc,world={},{}
local component,actor,rt,lib={},{},{},{}
local objects={
    ["/Script/Engine.Default__KismetRenderingLibrary"]=lib,
    ["/Script/Engine.SceneCapture2D"]={},
    ["/Script/Engine.SceneCaptureComponent2D"]={},
}
for _,obj in pairs(objects) do obj.IsValid=function() return true end end
for _,obj in ipairs({actor,rt,component}) do obj.IsValid=function() return true end end
local crop={x=4,y=369,w=3835,h=1416}
local matrix={}
local projection={workingChromaticities=function() end, projection=function(session,frame,library,w,left)
    assert(session.pc==pc and frame==crop and w==frame.w and left==0 and library==lib)
    return matrix,60
end}
local env=setmetatable({StaticFindObject=function(path) return objects[path] end,
    dofile=function(path) assert(path:match("/linear.lua$"));return projection end},{__index=_G})
local meter=assert(loadfile("mod/Scripts/meter.lua","t",env))()
local dark={}
for i=1,100 do dark[i]={R=0,G=0,B=0} end
assert(meter.luminance(dark,100)>0)
for i=1,10 do dark[i]={R=0.18,G=0.18,B=0.18} end
assert(math.abs(meter.luminance(dark,100)-0.18)<1e-7)
local session={world=world,pc=pc,pose={x=42,y=0,z=50,pitch=17,yaw=0,roll=5},
    locationKeys={x="x",y="Y",z="z"},angleKeys={pitch="pitch",yaw="Yaw",roll="Roll"}}
function world:SpawnActor(_,p,r) assert(p.X==42 and r.Pitch==17);return actor end
function actor:GetComponentByClass() return component end
function actor:K2_SetActorLocationAndRotation(p,r) assert(p.x==session.pose.x and r.pitch==17);return true end
function actor:K2_DestroyActor() self.destroyed=true end
function lib:CreateRenderTarget2D(wld,w,h,f,_,mip,uav)
    assert(wld==world and w==32 and h==w and f==6 and not mip and not uav);return rt
end
local n=0
local expectedFov=60
function component:CaptureScene()
    n=n+1
    assert(self.TextureTarget==rt and self.CaptureSource==1 and self.CustomProjectionMatrix==matrix)
    assert(self.bUseCustomProjectionMatrix and math.abs(self.FOVAngle-expectedFov)<1e-8 and not self.bCaptureEveryFrame)
end
function lib:ReadRenderTargetRawPixelArea(wld,t,x,y,w,h,normalized)
    assert(wld==world and t==rt and x==0 and y==0 and w==32 and h==32 and normalized==false)
    local pixels={}
    for i=1,w*h do
        local value=i<=20 and 400 or i<=90 and 0 or 0.18
        pixels[i]={get=function() return {R=value,G=value,B=value} end}
    end
    return pixels
end
function lib:ReleaseRenderTarget2D(t) assert(t==rt); t.released=true end
assert(not meter.poll(session,0,crop) and n==1)
assert(not meter.poll(session,0.001,crop) and n==1)
session.pose.yaw=12
local lum, submitted=meter.poll(session,0.016,crop)
assert(math.abs(lum-0.18)<1e-7 and submitted.yaw==0 and not meter.matches(submitted,session,crop))
assert(not meter.poll(session,0.4,crop) and n==1)
session.pose.x=99
assert(not meter.poll(session,0.8,crop) and n==2)
local _, fresh=meter.readForShot(session,0.801,crop)
assert(meter.matches(fresh,session,crop) and n==2, "re-rendered an already queued matching view")
session.pose.x=109
assert(not meter.poll(session,1.7,crop) and n==3)
session.pose.x=120
local _, reframed=meter.readForShot(session,1.701,crop)
assert(n==4 and reframed.x==120 and meter.matches(reframed,session,crop))
-- A 2:3 projection on the square meter still includes the portrait frame's top and bottom.
crop={x=600,y=0,w=720,h=1080}
expectedFov=math.deg(2*math.atan(math.tan(math.rad(30))*1.5))
local _, portrait=meter.readForShot(session,1.71,crop)
assert(n==5 and meter.matches(portrait,session,crop))
assert(meter.close(session) and actor.destroyed and rt.released and session.photoMeter==nil)
assert(meter.close(session))
print("Frozen-scene HDR metering uses the camera crop, bounded sampling and explicit resource teardown.")
