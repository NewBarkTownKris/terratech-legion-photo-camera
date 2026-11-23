-- Model a renderer whose color depends on the exact point on the final grid.
-- Check guard columns, phase interleaving, sRGB codes and staged cleanup.
local photo=dofile("mod/Scripts/photo.lua")
local lin,lib,writer,world={},{},{},{}
local function valid() return true end
lib.IsValid,writer.IsValid=valid,valid
local class={IsValid=valid}
local objects={["/Script/Engine.SceneCapture2D"]=class,["/Script/Engine.SceneCaptureComponent2D"]=class,
    ["/Script/Engine.Default__KismetRenderingLibrary"]=lib,
    ["/Script/ImageWriteQueue.Default__ImageWriteBlueprintLibrary"]=writer}
local env=setmetatable({StaticFindObject=function(path) return objects[path] end,
    dofile=function(path) return path:match("/linear.lua$") and lin or dofile(path) end},{__index=_G})
local shift=assert(loadfile("mod/Scripts/shiftpng.lua","t",env))()
local session={world=world,pose={x=5,y=2,z=9,pitch=3,yaw=27,roll=1},
    locationKeys={x="X",y="Y",z="Z"},angleKeys={pitch="pitch",yaw="Yaw",roll="Roll"},
    lens={PostProcessSettings={marker=1},PostProcessBlendWeight=0.85}}
local captures,actors,targets,refs,creationFails,readFails
local function reset() captures,actors,targets,refs,creationFails,readFails={},{},{},0,nil,false end
function lin.writeOptions(format) assert(format==2); return {} end
local expectedWidth,expectedHeight
function lin.projection(s,crop,_,renderWidth,shiftedLeft,logicalWidth,logicalHeight,shiftedY,ph)
    local n=math.floor(expectedWidth/logicalWidth+0.5)
    local pw=math.ceil(logicalWidth)
    local left=(renderWidth-pw)//2
    local x=(left-shiftedLeft+0.5)*n-0.5
    local y=(shiftedY+0.5)*n-0.5
    assert(math.abs(x-math.floor(x+0.5))<1e-8 and math.abs(y-math.floor(y+0.5))<1e-8)
    assert(logicalHeight==expectedHeight/n and ph==math.ceil(logicalHeight))
    assert(renderWidth%32==0 and n>=2)
    return {n=n,x=math.floor(x+0.5),y=math.floor(y+0.5),left=left},60
end
function world:SpawnActor()
    local a,c={IsValid=valid},{IsValid=valid}
    actors[#actors+1]=a
    function a:GetComponentByClass() return c end
    function a:K2_SetActorLocationAndRotation(pos,ang)
        assert(pos.X==5 and pos.Y==2 and pos.Z==9 and ang.pitch==3 and ang.Yaw==27)
        return true
    end
    function a:K2_DestroyActor() assert(not self.destroyed); self.destroyed=true end
    function c:CaptureScene()
        local rt=self.TextureTarget
        assert(self.CaptureSource==2 and self.bUseCustomProjectionMatrix and rt.TargetGamma==2.2)
        assert(not self.bCaptureEveryFrame and not self.bCaptureOnMovement and self.bAlwaysPersistRenderingState)
        assert(self.PostProcessSettings==session.lens.PostProcessSettings and self.PostProcessBlendWeight==0.85)
        assert(not rt.released and self.bCameraCutThisFrame)
        rt.proj=self.CustomProjectionMatrix
        captures[#captures+1]=rt
    end
    return a
end
function lib:CreateRenderTarget2D(_,w,h,fmt)
    assert(fmt==2 and w*h<=2048*1024)
    if creationFails==#targets+1 then error("allocation failed") end
    local t={IsValid=valid,SizeX=w,SizeY=h}
    targets[#targets+1]=t; return t
end
function lib:ReleaseRenderTarget2D(rt) assert(not rt.released); rt.released=true end
function lib:ReadRenderTargetRawPixel(_,rt) assert(rt.proj) end
local function color(x,y) return (97*x+y)%256,(255-11*y+x)%256,(3*x+49*y)%256 end
local function value(rt,x,y)
    return color((x-rt.proj.left)*rt.proj.n+rt.proj.x,y*rt.proj.n+rt.proj.y)
end
local mode
function writer:ExportToDisk(rt,path)
    assert(#captures>=1 and #actors==1 and #targets==1)
    if mode=="silent" then return end
    local f <close> = assert(io.open(path,"wb"))
    if mode=="truncated" then f:write("BM"); return end
    if mode=="wrongsize" then f:write("BM",string.rep("X",80)); return end
    local w,h=rt.SizeX,rt.SizeY
    local bottom=mode~="top"
    local bpp=(rt.proj.x+rt.proj.y)%2==0 and 3 or 4
    local stride=((w*bpp+3)//4)*4
    local bitfields=mode=="top" and bpp==4
    local offset=bitfields and 66 or 54
    f:write("BM",string.pack("<I4I4I4I4i4i4I2I2I4I4I4I4I4I4",offset+stride*h,0,offset,40,
        w,bottom and h or -h,1,bpp*8,bitfields and 3 or 0,stride*h,0,0,0,0))
    if bitfields then f:write(string.pack("<I4I4I4",0xff0000,0xff00,0xff)) end
    for i=0,h-1 do
        local y=bottom and h-i-1 or i
        local row={}
        for x=0,w-1 do
            local r,g,b=value(rt,x,y)
            row[#row+1]=string.char(b,g,r)..(bpp==4 and "\0" or "")
        end
        f:write(table.concat(row),string.rep("\0",stride-w*bpp))
    end
end
local rawType
local function channel(v)
    if rawType=="byte" then return v end
    if rawType=="normalized" then return v/255 end
    v=v/255
    return v<=0.04045 and v/12.92 or ((v+0.055)/1.055)^2.4
end
function lib:ReadRenderTargetPixel(_,rt,x,y)
    refs=refs+1
    local r,g,b=value(rt,x,y); return {R=r,G=g,B=b}
end
function lib:ReadRenderTargetRawPixelArea(_,rt,x,y,w,h,norm)
    assert(not norm and w*h<=65536 and x==rt.proj.left)
    if readFails then return {} end
    local result={}
    for row=y,y+h-1 do
        for col=x,x+w-1 do
            local r,g,b=value(rt,col,row)
            local sample={R=channel(r),G=channel(g),B=channel(b)}
            result[#result+1]={get=function() return sample end}
        end
    end
    return result
end
local function request(w,h,withRaw)
    local path=os.tmpname()
    os.remove(path)
    expectedWidth,expectedHeight=w or 37,h or 23
    local req={crop={x=1,y=2,w=19,h=11},output={w=w or 37,h=h or 23},path=path..".png"}
    if withRaw then req.linear={path=path..".exr",crop=req.crop} end
    return req
end
local function validateClean(job)
    for _,p in ipairs(job.phases) do assert(not io.open(p.bmp) and not io.open(p.raw)) end
    assert(not io.open(job.partial))
    for _,rt in ipairs(targets) do assert(rt.released) end
    for _,a in ipairs(actors) do assert(a.destroyed) end
end
local function pixels(path)
    local f <close> = assert(io.open(path,"rb"))
    local image=f:read("a")
    local pos,blocks=9,{}
    assert(image:find("sRGB\0",1,true))
    while pos<=#image do
        local n,tag,first=string.unpack(">I4c4",image,pos)
        if tag=="IDAT" then blocks[#blocks+1]=image:sub(first,first+n-1) end
        pos=first+n+4
    end
    local data=table.concat(blocks)
    assert(data:sub(1,2)=="\120\1")
    pos,blocks=3,{}
    while true do
        local last,n,inv,first=string.unpack("<BI2I2",data,pos)
        assert(inv==65535-n)
        blocks[#blocks+1]=data:sub(first,first+n-1); pos=first+n
        if last==1 then break end
    end
    return table.concat(blocks)
end
for _,test in ipairs({{"bmp"},{"top"},{"silent","normalized"},{"truncated","linear"},{"wrongsize","byte"}}) do
    reset()
    mode,rawType=table.unpack(test)
    local req=request(37,23,true)
    assert(shift.start(session,req))
    local j=assert(req.shiftPNGJob)
    assert(j.grid==2 and #captures==0 and #actors==1 and #targets==1)
    assert(shift.progress(req):find("1/4",1,true))
    for i=1,30 do
        local done,why=shift.step(session,req,i)
        assert(not why,why)
        if done then break end
    end
    assert(not req.shiftPNGJob and photo.checkFile(req) and not io.open(req.linear.path))
    local expected={}
    for y=0,req.output.h-1 do
        expected[#expected+1]="\0"
        for x=0,req.output.w-1 do expected[#expected+1]=string.char(color(x,y)) end
    end
    assert(pixels(req.path)==table.concat(expected))
    assert(#captures==4 and #actors==1 and #targets==1)
    assert((rawType~=nil)==(refs~=0))
    assert(refs<=3)
    validateClean(j)
    assert(os.remove(req.path))
end
reset(); mode,rawType="silent","byte"
local failed=request()
creationFails=1
local ok,why=shift.start(session,failed)
assert(not ok and why:find("allocation failed",1,true) and not failed.shiftPNGJob)
for _,rt in ipairs(targets) do assert(rt.released) end
for _,a in ipairs(actors) do assert(a.destroyed) end

reset()
local broken=request()
assert(shift.start(session,broken))
local job=broken.shiftPNGJob
readFails=true
shift.step(session,broken,0)
local _,issue=shift.step(session,broken,2)
assert(issue:find("Incomplete print PNG readback",1,true))
assert(not broken.shiftPNGJob and not io.open(broken.path))
validateClean(job)

reset()
local big=request(15308,6020)
assert(shift.start(session,big))
local bigJob=big.shiftPNGJob
assert(bigJob.grid>=7 and #targets==1 and bigJob.renderW*bigJob.ph<=2048*1024 and #captures==0)
assert(shift.cancel(big))
validateClean(bigJob)

reset(); mode="bmp"
local occupied=request()
assert(shift.start(session,occupied))
local j=occupied.shiftPNGJob
local final=assert(io.open(occupied.path,"wb")); final:write("keep"); final:close()
for i=1,9 do
    local _,err=shift.step(session,occupied,i)
    if err then assert(err:find("occupied",1,true)); break end
end
assert(not occupied.shiftPNGJob)
local keep=assert(io.open(occupied.path)); assert(keep:read("a")=="keep"); keep:close()
validateClean(j); os.remove(occupied.path)
reset(); mode="bmp"
local interrupted=request()
assert(shift.start(session,interrupted))
local j=interrupted.shiftPNGJob
assert(select(3,shift.step(session,interrupted,0)) and #captures==1 and not targets[1].released)
assert(shift.cancel(interrupted) and shift.cancel(interrupted))
assert(#captures==1 and not io.open(interrupted.path))
validateClean(j)

-- A 4× shutter on a 4K viewport now asks the driver for one HD-sized
-- render surface and does not perform a native full-resolution capture.
reset()
local fourK=request(15360,8640)
assert(shift.start(session,fourK))
local j=fourK.shiftPNGJob
assert(j.grid==8 and j.renderW==1920 and j.ph==1080 and #targets==1)
assert(shift.cancel(fourK)); validateClean(j)
print("Single-target print PNG phases, BMP and sRGB fallback, odd rasters, failure and cancellation passed.")
