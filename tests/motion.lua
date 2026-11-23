-- Drive the real shutter recorder/renderer through its frame lifecycle.
-- The mock scene maps camera X to a pixel. Averaging first/last viewport
-- stills or rendering the same pose twice would both fail the sample checks.
local photo=dofile("mod/Scripts/photo.lua")
local lib,writer,world={}, {}, {}
local allocations,actors,targets,poses = 0, {}, {}, {}
local gpuError, writerSilent, lastPNG, lastRAW
local function valid() return true end
lib.IsValid,writer.IsValid=valid,valid
local class={IsValid=valid}
local objects={["/Script/Engine.Default__KismetRenderingLibrary"]=lib,
    ["/Script/ImageWriteQueue.Default__ImageWriteBlueprintLibrary"]=writer,
    ["/Script/Engine.SceneCapture2D"]=class,["/Script/Engine.SceneCaptureComponent2D"]=class}
local function pose(x,yaw) return {x=x,y=0,z=12,yaw=yaw or 0,pitch=0,roll=0,fov=55} end
local s={world=world,pc={},pose=pose(0,179),lens={PostProcessSettings={look=true},PostProcessBlendWeight=1},
    locationKeys={x="X",y="Y",z="Z"},angleKeys={pitch="pitch",yaw="Yaw",roll="Roll"}}
function world:SpawnActor(c)
    assert(c==class)
    local actor={IsValid=valid}
    local comp={IsValid=valid}
    actors[#actors+1]=actor
    function actor:GetComponentByClass() return comp end
    function actor:K2_SetActorLocationAndRotation(p,r)
        self.x,self.yaw=p.X,r.Yaw
        return true
    end
    function comp:CaptureScene()
        assert(not self.bCaptureEveryFrame and self.bUseCustomProjectionMatrix)
        assert(self.CaptureSource==1 or self.CaptureSource==2)
        if self.CaptureSource==2 then assert(self.PostProcessSettings==s.lens.PostProcessSettings) end
        self.TextureTarget.value=(self.CaptureSource==1 and 100 or 0)+actor.x
        self.TextureTarget.top=self.CustomProjectionMatrix.top
        poses[#poses+1]={self.CaptureSource,actor.x,actor.yaw}
    end
    function actor:K2_DestroyActor() self.destroyed=true end
    return actor
end
function lib:CreateRenderTarget2D(_,w,h,fmt)
    allocations=allocations+1
    if gpuError and allocations==gpuError then error("out of video memory") end
    local rt={IsValid=valid,w=w,h=h,SizeX=w,SizeY=h,format=fmt}
    targets[#targets+1]=rt
    return rt
end
function lib:ClearRenderTarget2D(_,rt) rt.value=0 end
function lib:ReleaseRenderTarget2D(rt) assert(not rt.released); rt.released=true end
function lib:ReadRenderTargetRawPixel() return {} end
function lib:BeginDrawCanvasToRenderTarget(_,dst,out,size,ctx)
    assert(not lib.drawing); lib.drawing=dst; ctx.RenderTarget=dst
    out.Canvas={IsValid=valid,K2_DrawTexture=function(_,src,_,_,offset,uv,weight,blend)
        if blend==5 then assert(weight.A==0 and uv.X==1); dst.value=dst.value+src.value; dst.top=src.top
        else assert(blend==0 and offset.X>=0); dst.value=weight.R*src.value end
    end}
end
function lib:EndDrawCanvasToRenderTarget(_,ctx) assert(lib.drawing==ctx.RenderTarget); lib.drawing=nil end
function writer:ExportToDisk(rt,path)
    lastPNG=rt.value
    if writerSilent then return end
    local f <close> = assert(io.open(path,"wb"))
    f:write("\137PNG\r\n\26\n",string.pack(">I4",13),"IHDR",string.pack(">I4I4",rt.w,rt.h),"\0\0\0\0IEND\174\66\96\130")
end
local lin={writeOptions=function(v) assert(v==0); return {} end,projection=function(s,c,_,p,l,w,h,top,rows)
    assert(p%32==0 and l==(p-w)//2)
    if top then assert(top>=0 and top+rows<=h) end
    return {top=top},55
end,fromTarget=function(_,req,rt,_,_,count,divisor)
    assert(rt.format==9 and count==divisor and count>=2); req.linearJob={}
    lastRAW=rt.value/divisor*req.exposure.gain; return true
end,checkFile=function(req) req.linearJob=nil; return true end,cancel=function(req) req.linearJob=nil; return true end}
local env=setmetatable({StaticFindObject=function(k) return objects[k] end,
    dofile=function(path) return path:match("linear.lua$") and lin or dofile(path) end}, {__index=_G})
local motion=assert(loadfile("mod/Scripts/motion.lua","t",env))()
local tmp=os.tmpname(); os.remove(tmp)
local function request(raw)
    local r={path=tmp..".png",crop={x=0,y=3,w=3835,h=1416},exposure={mode="Manual",seconds=1/15,gain=2}}
    if raw then r.linear={path=tmp..".exr",crop=r.crop} end
    return r
end
local req=request(true)
assert(motion.start(s,req,100))
s.pose=pose(4,-180)
assert(not motion.step(s,req,100+1/60))
s.pose=pose(16,-177)
assert(not motion.step(s,req,100+1/15))
assert(not req.motionJob.open)
for i=1,10 do
    local done,why=motion.step(s,req,100.1+i*.01)
    assert(not why,why)
    if done then break end
end
assert(not req.motionJob and photo.checkFile(req))
assert(#poses==4 and poses[1][1]==2 and poses[2][1]==1 and poses[3][1]==2 and poses[4][1]==1)
for i=1,4 do
    assert(math.abs(poses[i][2]-(i<=2 and 4 or 12))<1e-7)
    local yaw=poses[i][3]; assert(math.abs(yaw)>175, "cross yaw wrap along the short arc")
end
assert(math.abs(lastPNG-8)<1e-7 and math.abs(lastRAW-216)<1e-7)
os.remove(req.path)
for _,a in ipairs(actors) do assert(a.destroyed) end
for _,t in ipairs(targets) do assert(t.released) end

local cancelled=request(false)
assert(motion.start(s,cancelled,0)); assert(motion.cancel(cancelled) and not cancelled.motionJob)
local failed=request(false)
assert(motion.start(s,failed,0))
motion.step(s,failed,1)
gpuError=allocations+2
local _,why=motion.step(s,failed,1.01)
assert(why:find("out of video memory",1,true) and not failed.motionJob)
for _,a in ipairs(actors) do assert(a.destroyed) end
for _,t in ipairs(targets) do assert(t.released) end
assert(not io.open(failed.path,"rb"))

-- A long shutter bounds both replay count and output size.
local long=request(false); long.exposure.seconds=8; long.crop={x=0,y=0,w=7680,h=4320}
assert(motion.start(s,long,0)); motion.step(s,long,10); assert(#long.motionJob.poses==64)
motion.step(s,long,10.01); assert(long.output.w==3840 and long.output.h==2160 and long.crop.w==7680)
assert(motion.cancel(long))
print("Real-time shutter midpoint sampling, mixed PNG/EXR rendering, highlight gain, yaw wrap, bounds and cleanup passed.")

-- A silent native image writer falls back to crop-correct opaque sRGB and
-- still advances to the matched RAW companion.
local repair=request(true)
repair.crop={x=2,y=0,w=7,h=6}
writerSilent=true
function lib:ReadRenderTargetRawPixelArea(_,rt,x,y,w,h,normalize)
    assert(x==12 and y==0 and w==7 and h==6 and not normalize)
    local out={}
    for i=1,w*h do out[i]={R=.36,G=2,B=0,A=0} end
    return out
end
assert(motion.start(s,repair,0)); motion.step(s,repair,1)
for i=1,16 do
    local done,why=motion.step(s,repair,i+1)
    assert(not why,why)
    if done then break end
end
assert(not repair.motionJob and photo.checkFile(repair))
local f=assert(io.open(repair.path,"rb")); local data=f:read("a"); f:close()
assert(data:byte(26)==2 and data:find("sRGB",1,true))
os.remove(repair.path)

-- Replay a narrow 4x portrait over two overscanned bands. The renderer
-- produces a row-dependent red stripe and a column-dependent green stripe.
-- Decode the actual stored PNG blocks to catch repeated overlap and gaps.
local function portrait()
    local r=request(true)
    r.crop={x=25,y=7,w=2,h=1001}
    r.linear.crop=r.crop
    r.output={w=8,h=4004}
    return r
end
local finishedRows, finishedBands, rawFails
function lin.beginBands(_,r,n,d)
    assert(n==2 and n==d and not r.linearJob and r.crop.h==1001 and r.output.h==4004)
    finishedRows,finishedBands=0,0
    r.linearJob={}
    return true
end
function lin.writeBand(r,target,left,first,rows,sourceY)
    assert(r.linearJob and target.top+sourceY==first and left==12 and finishedRows==first)
    if rawFails then return false,"simulated band error" end
    if not r.linearJob.reading then r.linearJob.reading=true; return false end
    r.linearJob.reading=false
    finishedRows,finishedBands=first+rows,finishedBands+1
    return true
end
function lin.finishBands(r)
    assert(r.linearJob and finishedRows==r.output.h and finishedBands==2)
    r.linearJob=nil
    return true
end
function lib:ReadRenderTargetRawPixelArea(_,rt,x,y,w,h,normalize)
    assert(not normalize and rt.top and x==12 and w==8 and y+h<=rt.h and w*h<=65536)
    local pixels={}
    for dy=0,h-1 do for dx=0,w-1 do
        pixels[#pixels+1]={R=(rt.top+y+dy)%3==0 and 2 or 0,G=dx%2*2,B=0}
    end end
    return pixels
end
local function runPortrait(r)
    assert(motion.start(s,r,0))
    assert(#r.motionJob.bands==2 and r.motionJob.height<r.output.h)
    for i=1,32 do
        local done,err=motion.step(s,r,i)
        if done or err then return done,err end
    end
    error("Band rendering stalled")
end
local printed=portrait()
assert(runPortrait(printed))
assert(printed.crop.h==1001 and photo.checkFile(printed))
local p=assert(io.open(printed.path,"rb"))
local image=p:read("a"); p:close()
local blocks={}
local offset=9
while offset<=#image do
    local size,kind,start=string.unpack(">I4c4",image,offset)
    if kind=="IDAT" then blocks[#blocks+1]=image:sub(start,start+size-1) end
    offset=start+size+4
end
local deflated=table.concat(blocks)
assert(deflated:sub(1,2)=="\120\1")
local data={}
offset=3
while true do
    local last,len,inverse,start=string.unpack("<BI2I2",deflated,offset)
    assert(len+inverse==65535 and (last==0 or last==1))
    data[#data+1]=deflated:sub(start,start+len-1)
    offset=start+len
    if last==1 then break end
end
assert(offset+3==#deflated)
local raw=table.concat(data)
assert(#raw==4004*25)
for y=0,4003 do
    assert(raw:byte(y*25+1)==0)
    for x=0,7 do
        local r,g,b=raw:byte(y*25+x*3+2,y*25+x*3+4)
        assert(r==(y%3==0 and 255 or 0) and g==x%2*255 and b==0)
    end
end
os.remove(printed.path)
rawFails=true
local incomplete=portrait()
local done,err=runPortrait(incomplete)
assert(not done and err:find("PNG saved. EXR failed:",1,true))
assert(photo.checkFile(incomplete) and not incomplete.motionJob and not incomplete.linear.linearJob)
os.remove(incomplete.path)
rawFails=false

local midway=portrait()
assert(motion.start(s,midway,0))
for i=1,8 do
    local _,issue=motion.step(s,midway,i)
    assert(not issue,issue)
    if midway.linear.linearJob then break end
end
local partial=midway.motionJob.recovery
local stageFile=assert(io.open(partial,"rb")); stageFile:close()
assert(midway.linear.linearJob and motion.cancel(midway))
assert(not io.open(partial,"rb") and not midway.linear.linearJob)

-- Plan a full 4x 4K shutter without performing gigapixel readbacks.
local huge=request(true)
huge.crop={w=3840,h=2160,x=0,y=0}; huge.output={w=15360,h=8640}
assert(motion.start(s,huge,0))
motion.step(s,huge,1); motion.step(s,huge,2)
local j=assert(huge.motionJob)
assert(#j.bands>1 and j.width*j.height<=3840*2160)
for _, t in ipairs(j.targets) do assert(t.w*t.h<=3840*2160) end
assert(motion.cancel(huge) and not io.open(huge.path,"rb"))
local square=request(false)
square.crop={w=1080,h=1080,x=420,y=0}; square.output={w=3240,h=3240}
assert(motion.start(s,square,0))
assert(square.motionJob.bands and square.motionJob.width*square.motionJob.height<=3840*2160)
assert(motion.cancel(square))

-- Drive the same moving shutter through the production EXR scanline writer.
-- Verify each global row from its real file offset after photographic gain.
objects["/Script/Engine.Default__RendererSettings"]={IsValid=valid,WorkingColorSpaceChoice=0}
objects["/Script/Engine.EWorkingColorSpace"]={IsValid=valid,GetNameByValue=function()
    return {ToString=function() return "EWorkingColorSpace::sRGB" end}
end}
local actual=assert(loadfile("mod/Scripts/linear.lua","t",env))()
lin.beginBands,lin.writeBand,lin.finishBands,lin.cancel=actual.beginBands,actual.writeBand,actual.finishBands,actual.cancel
local pair=portrait()
assert(runPortrait(pair))
assert(photo.checkFile(pair) and actual.checkFile(pair.linear))
local exr=assert(io.open(pair.linear.path,"rb")); local master=exr:read("a"); exr:close()
local pos=9
local attrs={}
while master:byte(pos)~=0 do
    local name,kind,size,dataStart=string.unpack("<zzI4",master,pos)
    attrs[name]=master:sub(dataStart,dataStart+size-1)
    pos=dataStart+size
end
assert(string.unpack("<i4",attrs.terraTechLegionShutterSamples)==2)
for y=0,4003 do
    local offset=string.unpack("<I8",master,pos+1+y*8)
    local yy,n,first=string.unpack("<i4I4",master,offset+1)
    assert(yy==y and n==8*12)
    for x=0,7 do
        assert(string.unpack("<f",master,first+x*4)==0) -- B
        assert(string.unpack("<f",master,first+32+x*4)==2*(x%2)) -- G
        assert(string.unpack("<f",master,first+64+x*4)==(y%3==0 and 2 or 0)) -- R
    end
end
os.remove(pair.path); os.remove(pair.linear.path)
print("4x timed PNG and EXR pixel contents, band projection ordering, bounded 4K print targets and cleanup passed.")
