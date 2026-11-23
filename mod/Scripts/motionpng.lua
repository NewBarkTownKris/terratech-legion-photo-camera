-- Recover a timed PNG straight from the display-linear GPU sum. A few rows
-- per frame keep readback bounded. PNG stored DEFLATE blocks need no DLL or
-- external converter, and discard the accumulator's unused alpha channel.
local png={}
local signature="\137PNG\r\n\26\n"
local crcTable={}
for n=0,255 do
    local c=n
    for _=1,8 do c=(c&1==1) and ((c>>1)~0xedb88320) or (c>>1) end
    crcTable[n]=c
end

local function chunk(file,kind,data)
    local crc=0xffffffff
    local body=kind..data
    for i=1,#body do crc=crcTable[(crc~body:byte(i))&255]~(crc>>8) end
    assert(file:write(string.pack(">I4",#data),body,string.pack(">I4",crc~0xffffffff)))
end

local function srgbCache(count)
    return setmetatable({}, {__index=function(cache,value)
        assert(value==value and math.abs(value)<math.huge, "Invalid display color in shutter readback")
        local v=math.max(0,math.min(1,value/count))
        local code=v <= 0.0031308 and 12.92*v or 1.055*v^(1/2.4)-0.055
        local byte=math.floor(255*code+0.5)
        cache[value]=byte
        return byte
    end})
end

local function deflate(file,state,raw,last)
    local a,b=state.adlerA,state.adlerB
    for i=1,#raw do a=a+raw:byte(i); b=b+a end
    a,b=a%65521,b%65521
    state.adlerA,state.adlerB=a,b
    local blocks={state.row==0 and "\120\1" or ""}
    for start=1,#raw,65535 do
        local block=raw:sub(start,start+65534)
        local final=last and start+#block>#raw
        blocks[#blocks+1]=string.pack("<BI2I2",final and 1 or 0,#block,65535-#block)..block
    end
    if last then blocks[#blocks+1]=string.pack(">I4",(b<<16)|a) end
    chunk(file,"IDAT",table.concat(blocks))
end

-- The caller supplies top-down RGB scanlines, each prefixed by filter byte 0.
function png.begin(file,w,h)
    assert(file:write(signature))
    chunk(file,"IHDR",string.pack(">I4I4BBBBB",w,h,8,2,0,0,0))
    chunk(file,"sRGB","\0")
    return {width=w,height=h,row=0,adlerA=1,adlerB=0}
end

function png.writeRows(file,state,raw,rows)
    assert(rows > 0 and #raw == rows*(1+3*state.width) and state.row+rows <= state.height,
        "Invalid PNG scanlines")
    local last = state.row+rows == state.height
    deflate(file,state,raw,last)
    if last then chunk(file,"IEND","") end
    state.row=state.row+rows
end

function png.step(job,request,band)
    local output = request.output or request.crop
    local w,h = output.w,output.h
    if not job.pngRead then
        local out <close> = assert(io.open(job.recovery,"wb"))
        job.pngRead=png.begin(out,w,h)
        job.pngRead.byte=srgbCache(job.count)
    end
    local state=job.pngRead
    local stop = band and band.first+band.rows or h
    local sourceY = band and band.sourceY+state.row-band.first or state.row
    local rows = math.min(stop-state.row,math.max(1,65536//w))
    assert(rows > 0 and sourceY >= 0, "Timed PNG bands are out of sequence")
    local colors=job.lib:ReadRenderTargetRawPixelArea(job.world,job.displaySum.rt,job.left,sourceY,w,rows,false)
    assert(#colors==w*rows,"Incomplete rectangle in timed PNG readback")
    local wrapped=colors[1].R==nil and type(colors[1].get)=="function"
    local lines,pixels,read={}, {}, 1
    for y=1,rows do
        for x=1,w do
            local c=colors[read]
            if wrapped then c=c:get() end
            pixels[x]=string.char(state.byte[c.R],state.byte[c.G],state.byte[c.B])
            read=read+1
        end
        lines[y]="\0"..table.concat(pixels)
    end
    local out <close> = assert(io.open(job.recovery,"ab"))
    png.writeRows(out,state,table.concat(lines),rows)
    return state.row==stop
end

return png
