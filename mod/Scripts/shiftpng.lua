-- Keep the entire view in each shadow pass. Each rendered pixel samples a
-- separate location in the final print. Store the phases and weave their
-- existing sRGB bytes directly into top-down RGB scanlines.
local shift = {}
local folder = assert(debug.getinfo(1,"S").source:match("^@(.+[/\\])"))
local linear = dofile(folder.."linear.lua")
local maxPhasePixels = 2048 * 1024
local png = dofile(folder.."motionpng.lua")
local photo = dofile(folder.."photo.lua")

local function object(path)
    local value = StaticFindObject(path)
    assert(value and value:IsValid(), "Missing print capture object "..path)
    return value
end

local function exists(path)
    local file = io.open(path,"rb")
    if file then file:close(); return true end
    return false
end

local function remove(path)
    if exists(path) then assert(os.remove(path)) end
end

-- The padded view also consumes render memory. Grow the grid until the
-- actual GPU dimensions fit, including the final partial row or column.
local function phaseGrid(w,h)
    local grid=2
    while true do
        local pw,ph=(w+grid-1)//grid,(h+grid-1)//grid
        local padded=((pw+31)//32)*32
        if padded*ph<=maxPhasePixels then return grid,pw,ph,padded end
        grid=grid+1
    end
end

local function releaseGPU(job)
    -- Clearing the texture before destroying the actor keeps a deferred
    -- component teardown from sampling a released surface. Older UE4SS
    -- builds may only permit clearing that reference through actor teardown.
    if job.component and job.component:IsValid() then
        pcall(function() job.component.TextureTarget=nil end)
    end
    if job.actor and job.actor:IsValid() then
        assert(job.actor:K2_DestroyActor()~=false, "Could not destroy print PNG camera")
    end
    job.actor,job.component=nil,nil
    if job.target and job.target:IsValid() then job.lib:ReleaseRenderTarget2D(job.target) end
    job.target=nil
end

function shift.cancel(request)
    local job = request and request.shiftPNGJob
    if not job then return true end
    local issues = {}
    local function release(f,...)
        local ok,why = pcall(f,...)
        if not ok then issues[#issues+1]=tostring(why) end
    end
    release(releaseGPU,job)
    for _,p in ipairs(job.phases) do
        if p.file then release(p.file.close,p.file); p.file=nil end
        if p.bmpOwned then release(remove,p.bmp) end
        if p.rawOwned then release(remove,p.raw) end
    end
    if job.partialOwned then release(remove,job.partial) end
    if #issues>0 then return false,table.concat(issues," / ") end
    request.shiftPNGJob = nil
    return true
end

local function createCamera(s,job)
    job.lib=object("/Script/Engine.Default__KismetRenderingLibrary")
    job.writer=object("/Script/ImageWriteQueue.Default__ImageWriteBlueprintLibrary")
    job.options=linear.writeOptions(2) -- synchronous 8-bit BMP
    local actorClass=object("/Script/Engine.SceneCapture2D")
    local componentClass=object("/Script/Engine.SceneCaptureComponent2D")
    local pose,k,r=s.pose,s.locationKeys,s.angleKeys
    local xyz={[k.x]=pose.x,[k.y]=pose.y,[k.z]=pose.z}
    local angles={[r.pitch]=pose.pitch,[r.yaw]=pose.yaw,[r.roll]=pose.roll}
    job.actor=s.world:SpawnActor(actorClass,{X=pose.x,Y=pose.y,Z=pose.z},
        {Pitch=pose.pitch,Yaw=pose.yaw,Roll=pose.roll})
    assert(job.actor and job.actor:IsValid(),"Could not spawn print PNG camera")
    local c=job.actor:GetComponentByClass(componentClass)
    assert(c and c:IsValid(),"Missing print PNG capture component")
    job.component=c
    c.bCaptureEveryFrame,c.bCaptureOnMovement,c.bAlwaysPersistRenderingState=false,false,true
    assert(job.actor:K2_SetActorLocationAndRotation(xyz,angles,false,{},true),"Could not position print PNG camera")
    -- One RGBA8 target serves the entire print. FinalColorLDR contains the
    -- display codes, including the locked lens's photographic look.
    job.target=job.lib:CreateRenderTarget2D(s.world,job.renderW,job.ph,2,{R=0,G=0,B=0,A=1},false,false)
    assert(job.target and job.target:IsValid() and job.target.SizeX==job.renderW and job.target.SizeY==job.ph,
        "Unreal could not allocate the print PNG target")
    job.target.TargetGamma=2.2
    c.TextureTarget,c.CaptureSource=job.target,2
    c.PostProcessSettings,c.PostProcessBlendWeight=s.lens.PostProcessSettings,s.lens.PostProcessBlendWeight
    c.bUseCustomProjectionMatrix=true
end

local function renderPhase(session,request,job,p)
    local offsetX=(p.x+0.5)/job.grid-0.5
    local offsetY=(p.y+0.5)/job.grid-0.5
    local c=job.component
    c.CustomProjectionMatrix,c.FOVAngle=linear.projection(session,request.crop,job.lib,job.renderW,
        job.left-offsetX,job.w/job.grid,job.h/job.grid,offsetY,job.ph)
    c.bCameraCutThisFrame=true
    c:CaptureScene()
    p.captured=true
end

function shift.start(session,request)
    if request.shiftPNGJob then return false,"Print PNG is already active" end
    local name=request.path and request.path:match("([^/\\]+)%.png$")
    if not name then return false,"Expected a PNG path" end
    local output=request.output or request.crop
    local w,h=output.w,output.h
    if not math.tointeger(w) or not math.tointeger(h) or math.min(w,h)<1 or math.max(w,h)>16384 then
        return false,"Unsupported print PNG dimensions"
    end
    local n,pw,ph,padded=phaseGrid(w,h)
    local base=request.path:sub(1,-#name-5).."."..name..".print"
    local job={world=session.world,w=w,h=h,grid=n,pw=pw,ph=ph,renderW=padded,left=(padded-pw)//2,
        phases={},partial=base..".png.partial",index=1}
    if exists(job.partial) or exists(request.path) or (request.linear and exists(request.linear.path)) then
        return false,"Print filename already in use"
    end
    for y=0,n-1 do
        for x=0,n-1 do
            local prefix=("%s.%d.%d"):format(base,x,y)
            local p={x=x,y=y,bmp=prefix..".bmp",raw=prefix..".rgb"}
            if exists(p.bmp) or exists(p.raw) then return false,"Print phase filename already in use" end
            job.phases[#job.phases+1]=p
        end
    end
    request.shiftPNGJob=job
    local ok,why=pcall(createCamera,session,job)
    if not ok then
        local _,cleanup=shift.cancel(request)
        return false,tostring(why)..(cleanup and " / "..cleanup or "")
    end
    return true
end

-- Windows DIB scanlines are DWORD-aligned BGR or BGRA. Accept a top-down
-- bitmap as well as the usual bottom-up encoding. Fall back on other layouts.
local function bitmap(file,w,h)
    local length=assert(file:seek("end"))
    assert(file:seek("set"))
    local bytes=file:read(54)
    if not bytes or #bytes~=54 or bytes:sub(1,2)~="BM" then return end
    local offset,dib=string.unpack("<I4I4",bytes,11)
    local width,height,planes,bits,compression=string.unpack("<i4i4I2I2I4",bytes,19)
    if dib<40 or offset<14+dib or width~=w or math.abs(height)~=h or planes~=1
            or (bits~=24 and bits~=32) then return end
    if compression==3 and bits==32 and offset>=66 then
        local masks=file:read(12)
        if masks~=string.pack("<I4I4I4",0xff0000,0xff00,0xff) then return end
    elseif compression~=0 then return end
    local bpp=bits//8
    local stride=((w*bpp+3)//4)*4
    if length<offset+h*stride then return end
    return {offset=offset,stride=stride,bpp=bpp,bottomUp=height>0}
end

-- UE's FColor single-pixel read is defined to return sRGB bytes. Use it as
-- a reference for this build's FLinearColor area read. Raw 8-bit surfaces
-- may expose integer codes, normalized codes or decoded linear values.
local function byte(v) return math.max(0,math.min(255,math.floor(v+0.5))) end
local function fromLinear(v)
    return byte(255*(v<=0.0031308 and 12.92*v or 1.055*v^(1/2.4)-0.055))
end
local function unwrap(c)
    return c.R==nil and c:get() or c
end

local function colorBytes(job,p,c,x,y)
    local choices=job.encodings
    local first=choices[1]
    local r,g,b=first(c.R),first(c.G),first(c.B)
    for i=2,#choices do
        local f=choices[i]
        if r~=f(c.R) or g~=f(c.G) or b~=f(c.B) then
            local ref=unwrap(job.lib:ReadRenderTargetPixel(job.world,job.target,x,y))
            for j=#choices,1,-1 do
                f=choices[j]
                if f(c.R)~=ref.R or f(c.G)~=ref.G or f(c.B)~=ref.B then table.remove(choices,j) end
            end
            assert(#choices>0,"Could not match print readback to the target's sRGB bytes")
            return string.char(ref.R,ref.G,ref.B)
        end
    end
    return string.char(r,g,b)
end

local function readRaw(job,p)
    if not p.rawRow then
        p.rawRow=0
        if not job.encodings then
            job.encodings={byte,function(v) return byte(255*v) end,fromLinear}
        end
    end
    local rows=math.min(job.ph-p.rawRow,math.max(1,65536//job.pw))
    local data=job.lib:ReadRenderTargetRawPixelArea(job.world,job.target,job.left,p.rawRow,job.pw,rows,false)
    assert(#data==job.pw*rows,"Incomplete print PNG readback")
    local f <close> = assert(io.open(p.raw,p.rawRow==0 and "wb" or "ab"))
    p.rawOwned=true
    local values={}
    for i=1,#data do
        local c=unwrap(data[i])
        values[i]=colorBytes(job,p,c,job.left+(i-1)%job.pw,p.rawRow+(i-1)//job.pw)
    end
    assert(f:write(table.concat(values)))
    p.rawRow=p.rawRow+rows
    if p.rawRow==job.ph then
        p.layout={offset=0,stride=job.pw*3,bpp=3,rgb=true}
        return true
    end
    return false
end

local function savePhase(job,p,now)
    if not p.submittedAt then
        p.bmpOwned=true
        local ok=pcall(job.writer.ExportToDisk,job.writer,job.target,p.bmp,job.options)
        job.lib:ReadRenderTargetRawPixel(job.world,job.target,0,0,false)
        p.submittedAt=now
        if not ok then p.fallback=true end
    end
    if not p.fallback then
        local f=io.open(p.bmp,"rb")
        if f then
            local layout=bitmap(f,job.renderW,job.ph)
            if layout then p.layout,p.file=layout,f; return true,true end
            f:close()
        end
        if now-p.submittedAt<1 then return false,false end
        p.fallback=true
    end
    if readRaw(job,p) then p.file=assert(io.open(p.raw,"rb")); return true,true end
    return false,true
end

local function phaseRow(job,p,y)
    local m=p.layout
    local inY=m.bottomUp and job.ph-1-y or y
    local left=m.rgb and 0 or job.left
    assert(p.file:seek("set",m.offset+inY*m.stride+left*m.bpp))
    local data=p.file:read(job.pw*m.bpp)
    assert(data and #data==job.pw*m.bpp,"Truncated print phase scanline")
    if m.rgb then return data end
    return (data:gsub(m.bpp==3 and "(.)(.)(.)" or "(.)(.)(.).","%3%2%1"))
end

local function assemble(job,request)
    if not job.png then
        local file <close> = assert(io.open(job.partial,"wb"))
        job.partialOwned=true
        job.png=png.begin(file,job.w,job.h)
    end
    local rows=math.min(job.h-job.png.row,math.max(1,262144//job.w))
    local lines={}
    for i=1,rows do
        local y=job.png.row+i-1
        local phaseStart=(y%job.grid)*job.grid
        local parts={}
        for phaseX=1,job.grid do
            local data=phaseRow(job,job.phases[phaseStart+phaseX],y//job.grid)
            local offset=1
            for x=phaseX,job.w,job.grid do
                parts[x]=data:sub(offset,offset+2)
                offset=offset+3
            end
        end
        lines[i]="\0"..table.concat(parts)
    end
    local out <close> = assert(io.open(job.partial,"ab"))
    png.writeRows(out,job.png,table.concat(lines),rows)
    assert(out:close())
    if job.png.row==job.h then
        assert(photo.checkFile({path=job.partial,output={w=job.w,h=job.h}}),"Incomplete assembled print PNG")
        assert(not exists(request.path),"PNG destination is already occupied")
        assert(os.rename(job.partial,request.path))
        job.partialOwned=false
        return true
    end
    return false
end

function shift.progress(request)
    local j=request and request.shiftPNGJob
    if not j then return end
    if j.index<=#j.phases then return ("Reading PNG phase %d/%d"):format(j.index,#j.phases) end
    return ("Writing PNG   %d%%"):format(100*(j.png and j.png.row or 0)//j.h)
end

function shift.step(session,request,now)
    local job=request.shiftPNGJob
    if not job then return false,"No active print PNG" end
    local ok,done,advanced=pcall(function()
        local p=job.phases[job.index]
        if p then
            if not p.captured then renderPhase(session,request,job,p) end
            local ready,didWork=savePhase(job,p,now)
            if ready then
                job.index=job.index+1
                if job.index>#job.phases then releaseGPU(job) end
            end
            return false,didWork
        end
        return assemble(job,request),true
    end)
    if not ok or done then
        local cleaned,why=shift.cancel(request)
        if not ok then return false,tostring(done)..(why and " / "..why or "") end
        if not cleaned then return false,why end
    end
    return done,nil,advanced
end

return shift
