local M = {}

-- v0.10.0 PERFORMANCE REBUILD
-- Cached inverse ground projection, boundary-only blending, larger exclusion mask.
local im = extensions.ui_imgui or ui_imgui
local imUtils = require('ui/imguiUtils')

local WIDTH, HEIGHT = 800, 450
local ASPECT = WIDTH / HEIGHT
local NEAR_CLIP, FAR_CLIP = 0.05, 250
local GRID_X, GRID_Y = 36, 46
local cameraOrder = {'front','rear','left','right'}

local cameras = {
  front={view='svFrontView',tex='svFrontTex',label='FRONT'},
  rear ={view='svRearView', tex='svRearTex', label='REAR'},
  left ={view='svLeftView', tex='svLeftTex', label='LEFT'},
  right={view='svRightView',tex='svRightTex',label='RIGHT'}
}

local defaults = {
  front={x= 2.10,y= 0.00,z=0.82,yaw=   0,pitch=-36,roll=0,fov=105,cx=0.50,cy=0.50,k1=0,k2=0},
  rear ={x=-2.10,y= 0.00,z=0.82,yaw= 180,pitch=-36,roll=0,fov=105,cx=0.50,cy=0.50,k1=0,k2=0},
  left ={x= 0.20,y=-1.02,z=1.10,yaw= -90,pitch=-48,roll=0,fov=105,cx=0.50,cy=0.50,k1=0,k2=0},
  right={x= 0.20,y= 1.02,z=1.10,yaw=  90,pitch=-48,roll=0,fov=105,cx=0.50,cy=0.50,k1=0,k2=0}
}

local function fp(v) return im and im.FloatPtr and im.FloatPtr(v) or {[0]=v} end
local controls={}
for n,d in pairs(defaults) do
  controls[n]={x=fp(d.x),y=fp(d.y),z=fp(d.z),yaw=fp(d.yaw),pitch=fp(d.pitch),roll=fp(d.roll),fov=fp(d.fov),cx=fp(d.cx),cy=fp(d.cy),k1=fp(d.k1),k2=fp(d.k2)}
end

local mapControls={
  front=fp(5.8),rear=fp(4.8),side=fp(3.6),
  carLength=fp(4.5),carWidth=fp(1.9),
  maskLength=fp(4.95),maskWidth=fp(2.20),blend=fp(0.16)
}

local running=false
local showWindow=im and im.BoolPtr and im.BoolPtr(true) or nil
local resolution=Point2I(WIDTH,HEIGHT)
local viewport=RectI(0,0,WIDTH,HEIGHT)
local uv0=im and im.ImVec2(0,0) or nil
local uv1=im and im.ImVec2(1,1) or nil
local projectionCache={cells={},signature=nil}

for _,cam in pairs(cameras) do
  cam.matrix=MatrixF(true); cam.quat=QuatF(0,0,0,1); cam.renderView=nil
end

local function emitStatus(state,msg)
  if guihooks and guihooks.trigger then
    guihooks.trigger('SurroundViewStatus',{state=state,message=msg or state or 'UNKNOWN',mode='cached-ground-projection',version='0.10.0'})
  end
end

local function getVehicle()
  if be and be.getPlayerVehicle then local ok,v=pcall(function() return be:getPlayerVehicle(0) end); if ok and v then return v end end
  if getPlayerVehicle then local ok,v=pcall(function() return getPlayerVehicle(0) end); if ok and v then return v end end
end

local function norm(v)
  local ok,o=pcall(function() return v:normalized() end); if ok and o then return o end
  pcall(function() v:normalize() end); return v
end

local function basis(v)
  local p,d,u=v:getPosition(),v:getDirectionVector(),v:getDirectionVectorUp(); if not p or not d or not u then return nil end
  d,u=norm(d),norm(u); local r
  local ok=pcall(function() r=d:cross(u) end)
  if not ok or not r then r=vec3(-d.y,d.x,0) end
  return p,d,u,norm(r)
end

local function rotateAroundForward(rr,up,roll)
  local c,s=math.cos(roll),math.sin(roll)
  return {x=rr.x*c+up.x*s,y=rr.y*c+up.y*s,z=rr.z*c+up.z*s},
         {x=up.x*c-rr.x*s,y=up.y*c-rr.y*s,z=up.z*c-rr.z*s}
end

local function localCameraBasis(c)
  local yaw,pitch=math.rad(c.yaw[0]),math.rad(c.pitch[0])
  local cp=math.cos(pitch)
  local f={x=cp*math.cos(yaw),y=cp*math.sin(yaw),z=math.sin(pitch)}
  local fl=math.sqrt(f.x*f.x+f.y*f.y+f.z*f.z); f.x,f.y,f.z=f.x/fl,f.y/fl,f.z/fl
  local rr={x=-f.y,y=f.x,z=0}
  local rl=math.sqrt(rr.x*rr.x+rr.y*rr.y)
  if rl<1e-6 then rr={x=0,y=1,z=0} else rr.x,rr.y=rr.x/rl,rr.y/rl end
  local up={x=-f.z*rr.y,y=f.z*rr.x,z=f.x*rr.y-f.y*rr.x}
  local ul=math.sqrt(up.x*up.x+up.y*up.y+up.z*up.z); up.x,up.y,up.z=up.x/ul,up.y/ul,up.z/ul
  return f,rotateAroundForward(rr,up,math.rad(c.roll[0]))
end

local function getCameraBasis(c)
  local f,rr,up=localCameraBasis(c)
  if type(rr)=='table' and rr.x then return f,rr,up end
  return f,rr,up
end

local function toWorldVec(d,r,u,v) return d*v.x+r*v.y+u*v.z end

local function setCam(cam,pos,dir,up)
  local q=quatFromDir(norm(dir),norm(up))
  cam.quat.x,cam.quat.y,cam.quat.z,cam.quat.w=q.x,q.y,q.z,q.w
  cam.matrix:setFromQuatF(cam.quat); cam.matrix:setPosition(pos); cam.renderView.cameraMatrix=cam.matrix
end

local function updateCams()
  local veh=getVehicle(); if not veh then return false,'No player vehicle found' end
  local p,d,u,r=basis(veh); if not p then return false,'Vehicle transform unavailable' end
  local ok,err=pcall(function()
    for name,cam in pairs(cameras) do
      local c=controls[name]
      local lf,lrr,lu=getCameraBasis(c)
      local pos=p+d*c.x[0]+r*c.y[0]+u*c.z[0]
      setCam(cam,pos,toWorldVec(d,r,u,lf),toWorldVec(d,r,u,lu))
    end
  end)
  if not ok then return false,'camera transform failed: '..tostring(err) end
  return true
end

local function createViews()
  if not RenderViewManagerInstance or not RenderViewManagerInstance.getOrCreateView then return false,'RenderViewManagerInstance unavailable' end
  local ok,err=pcall(function()
    for name,cam in pairs(cameras) do
      cam.renderView=RenderViewManagerInstance:getOrCreateView(cam.view)
      cam.renderView.renderCubemap=false; cam.renderView.cameraMatrix=cam.matrix
      cam.renderView.resolution=resolution; cam.renderView.viewPort=viewport
      cam.renderView.namedTexTargetColor=cam.tex
      cam.renderView.frustum=Frustum.construct(false,math.rad(controls[name].fov[0]),ASPECT,NEAR_CLIP,FAR_CLIP)
    end
  end)
  if not ok then return false,'RenderView setup failed: '..tostring(err) end
  return true
end

local function tex(cam)
  local o=imUtils.texObj('#'..cam.tex)
  return o and o.texId or nil
end

local function image(cam,size)
  local id=tex(cam); if not id then im.Dummy(size); return false end
  im.Image(id,size,uv0,uv1); return true
end

local function tile(cam,w,h)
  im.BeginGroup(); im.Text(cam.label); image(cam,im.ImVec2(w,h)); im.EndGroup()
end

local function distortUV(c,U,V)
  local x=(U-c.cx[0])*2; local y=(V-c.cy[0])*2
  local r2=x*x+y*y; local f=1+c.k1[0]*r2+c.k2[0]*r2*r2
  return c.cx[0]+x*f*0.5,c.cy[0]+y*f*0.5
end

local function projectGround(name,X,Y)
  local c=controls[name]
  local f,rr,up=getCameraBasis(c)
  local rx,ry,rz=X-c.x[0],Y-c.y[0],-c.z[0]
  local zc=rx*f.x+ry*f.y+rz*f.z
  if zc<=0.06 then return nil end
  local xc=rx*rr.x+ry*rr.y+rz*rr.z
  local yc=rx*up.x+ry*up.y+rz*up.z
  local tanV=math.tan(math.rad(c.fov[0])*0.5)
  local tanH=tanV*ASPECT
  local U=c.cx[0]+xc/(2*zc*tanH)
  local V=c.cy[0]-yc/(2*zc*tanV)
  U,V=distortUV(c,U,V)
  if U<0.01 or U>0.99 or V<0.01 or V>0.99 then return nil end
  local dist=math.sqrt(rx*rx+ry*ry+rz*rz)
  local viewScore=zc/math.max(dist,0.001)
  local edge=math.min(U,1-U,V,1-V)*2
  local score=viewScore*(0.35+0.65*math.max(0,math.min(1,edge)))
  return U,V,score
end

local function groundAt(gx,gy)
  local nx,ny=gx/GRID_X,gy/GRID_Y
  return mapControls.front[0]-(mapControls.front[0]+mapControls.rear[0])*ny,(nx*2-1)*mapControls.side[0]
end

local function controlsSignature()
  local t={}
  for _,name in ipairs(cameraOrder) do
    local c=controls[name]
    t[#t+1]=string.format('%.3f,%.3f,%.3f,%.2f,%.2f,%.2f,%.2f,%.3f,%.3f,%.4f,%.4f',c.x[0],c.y[0],c.z[0],c.yaw[0],c.pitch[0],c.roll[0],c.fov[0],c.cx[0],c.cy[0],c.k1[0],c.k2[0])
  end
  t[#t+1]=string.format('%.2f,%.2f,%.2f,%.2f',mapControls.front[0],mapControls.rear[0],mapControls.side[0],mapControls.blend[0])
  return table.concat(t,'|')
end

local function buildProjectionCache()
  local cells={}
  for gy=0,GRID_Y-1 do
    for gx=0,GRID_X-1 do
      local Xc,Yc=groundAt(gx+0.5,gy+0.5)
      local ranked={}
      for _,name in ipairs(cameraOrder) do
        local U,V,S=projectGround(name,Xc,Yc)
        if U then ranked[#ranked+1]={name=name,s=S} end
      end
      table.sort(ranked,function(a,b) return a.s>b.s end)
      local a,b=ranked[1],ranked[2]
      if a then
        local X0,Y0=groundAt(gx,gy); local X1,Y1=groundAt(gx+1,gy+1)
        local au0,av0=projectGround(a.name,X0,Y0); local au1,av1=projectGround(a.name,X1,Y1)
        if au0 and au1 then
          local cell={gx=gx,gy=gy,a={name=a.name,u0=au0,v0=av0,u1=au1,v1=av1,alpha=1}}
          if b and mapControls.blend[0]>0 then
            local ratio=b.s/math.max(a.s,1e-5)
            local blend=math.max(0,math.min(0.42,(ratio-(1-mapControls.blend[0]))/math.max(mapControls.blend[0],0.001)*0.42))
            if blend>0.04 then
              local bu0,bv0=projectGround(b.name,X0,Y0); local bu1,bv1=projectGround(b.name,X1,Y1)
              if bu0 and bu1 then cell.b={name=b.name,u0=bu0,v0=bv0,u1=bu1,v1=bv1,alpha=blend} end
            end
          end
          cells[#cells+1]=cell
        end
      end
    end
  end
  projectionCache.cells=cells
  projectionCache.signature=controlsSignature()
end

local function ensureProjectionCache()
  local sig=controlsSignature()
  if projectionCache.signature~=sig then buildProjectionCache() end
end

local function drawSample(dl,s,px,py,cw,ch)
  local id=tex(cameras[s.name]); if not id then return end
  local tint=im.GetColorU322(im.ImVec4(1,1,1,s.alpha or 1))
  dl:AddImage(id,im.ImVec2(px-0.12,py-0.12),im.ImVec2(px+cw+0.12,py+ch+0.12),im.ImVec2(s.u0,s.v0),im.ImVec2(s.u1,s.v1),tint)
end

local function drawProjectedGround(dl,o,w,h)
  ensureProjectionCache()
  local cw,ch=w/GRID_X,h/GRID_Y
  for _,cell in ipairs(projectionCache.cells) do
    local px=o.x+cell.gx*cw; local py=o.y+cell.gy*ch
    drawSample(dl,cell.a,px,py,cw,ch)
    if cell.b then drawSample(dl,cell.b,px,py,cw,ch) end
  end
end

local function drawVehicleMasks(dl,o,w,h)
  local totalX=mapControls.front[0]+mapControls.rear[0]
  local totalY=mapControls.side[0]*2
  local cx=o.x+w*0.5
  local centerY=o.y+h*(mapControls.front[0]/totalX)

  local maskW=w*(mapControls.maskWidth[0]/totalY)
  local maskH=h*(mapControls.maskLength[0]/totalX)
  local m0=im.ImVec2(cx-maskW*0.5,centerY-maskH*0.5)
  local m1=im.ImVec2(cx+maskW*0.5,centerY+maskH*0.5)
  dl:AddRectFilled(m0,m1,im.GetColorU322(im.ImVec4(0.025,0.03,0.035,1)),maskW*0.20,0)

  local carW=w*(mapControls.carWidth[0]/totalY)
  local carH=h*(mapControls.carLength[0]/totalX)
  local c0=im.ImVec2(cx-carW*0.5,centerY-carH*0.5)
  local c1=im.ImVec2(cx+carW*0.5,centerY+carH*0.5)
  dl:AddRectFilled(c0,c1,im.GetColorU322(im.ImVec4(0.10,0.13,0.16,1)),carW*0.22,0)
  dl:AddRect(c0,c1,im.GetColorU322(im.ImVec4(0.83,0.89,0.94,1)),carW*0.22,0,2)
  dl:AddRectFilled(im.ImVec2(cx-carW*0.30,centerY-carH*0.25),im.ImVec2(cx+carW*0.30,centerY+carH*0.18),im.GetColorU322(im.ImVec4(0.04,0.08,0.11,1)),carW*0.12,0)
end

local function surround()
  local a=im.GetContentRegionAvail()
  local h=math.max(360,math.min(a.y,720))
  local physicalAspect=(mapControls.side[0]*2)/(mapControls.front[0]+mapControls.rear[0])
  local w=math.min(a.x,h*physicalAspect); h=w/physicalAspect
  local p=im.GetCursorScreenPos(); local o=im.ImVec2(p.x+math.max(0,(a.x-w)*0.5),p.y)
  local dl=im.GetWindowDrawList()
  dl:AddRectFilled(o,im.ImVec2(o.x+w,o.y+h),im.GetColorU322(im.ImVec4(0.025,0.03,0.035,1)),12,0)
  drawProjectedGround(dl,o,w,h)
  drawVehicleMasks(dl,o,w,h)
  dl:AddRect(o,im.ImVec2(o.x+w,o.y+h),im.GetColorU322(im.ImVec4(0.15,0.55,1,0.9)),12,0,2)
  im.SetCursorScreenPos(o); im.Dummy(im.ImVec2(w,h))
end

local function resetCamera(name)
  local d,c=defaults[name],controls[name]
  for k,v in pairs(d) do c[k][0]=v end
  projectionCache.signature=nil
end

local function slider(label,ptr,a,b,fmt)
  im.SetNextItemWidth(270)
  if im.SliderFloat(label,ptr,a,b,fmt or '%.2f') then projectionCache.signature=nil end
end

local function cameraEditor(name)
  local c=controls[name]
  im.Separator(); im.Text(string.upper(name)..' CAMERA')
  slider('X##'..name,c.x,-4,4,'%.2f m'); slider('Y##'..name,c.y,-2.5,2.5,'%.2f m'); slider('Z##'..name,c.z,0.2,2.5,'%.2f m')
  slider('Yaw##'..name,c.yaw,-180,180,'%.1f deg'); slider('Pitch##'..name,c.pitch,-85,10,'%.1f deg'); slider('Roll##'..name,c.roll,-45,45,'%.1f deg')
  slider('FOV##'..name,c.fov,70,140,'%.1f deg'); slider('cx##'..name,c.cx,0.40,0.60,'%.3f'); slider('cy##'..name,c.cy,0.40,0.60,'%.3f')
  slider('k1##'..name,c.k1,-0.35,0.35,'%.4f'); slider('k2##'..name,c.k2,-0.20,0.20,'%.4f')
  if im.Button('Reset '..string.upper(name)) then resetCamera(name) end
end

local function calibrationTab()
  im.Text('v0.10.0 PERFORMANCE / CACHED AVM')
  im.Text('Projection UV map rebuilds only when calibration changes.')
  cameraEditor('front'); cameraEditor('rear'); cameraEditor('left'); cameraEditor('right')
  im.Separator(); im.Text('BIRD-EYE / MASK')
  slider('Front coverage',mapControls.front,2.5,10,'%.2f m'); slider('Rear coverage',mapControls.rear,2.5,10,'%.2f m'); slider('Side coverage',mapControls.side,2,7,'%.2f m')
  slider('Vehicle length',mapControls.carLength,3,6.5,'%.2f m'); slider('Vehicle width',mapControls.carWidth,1.4,2.8,'%.2f m')
  slider('Exclusion mask length',mapControls.maskLength,3.5,6.8,'%.2f m'); slider('Exclusion mask width',mapControls.maskWidth,1.6,3.2,'%.2f m')
  slider('Seam blend',mapControls.blend,0,0.40,'%.2f')
  if im.Button('RESET ALL CAMERAS') then for n,_ in pairs(controls) do resetCamera(n) end end
end

local function drawWindow()
  if not im or not running or (showWindow and not showWindow[0]) then return end
  im.SetNextWindowSize(im.ImVec2(980,860),im.Cond_FirstUseEver)
  local open=im.Begin('Surround View - Performance AVM##surroundView360',showWindow,bit.bor(im.WindowFlags_NoCollapse,im.WindowFlags_NoScrollbar))
  if open then
    im.Text('Cached 4-camera AVM v0.10.0'); im.Separator()
    if im.BeginTabBar('svTabs') then
      if im.BeginTabItem('360 VIEW') then
        im.Text('Cached inverse projection - lower CPU cost')
        local ok,err=pcall(surround)
        if not ok then im.TextColored(im.ImVec4(1,0.35,0.35,1),'360 draw error: '..tostring(err)) end
        im.EndTabItem()
      end
      if im.BeginTabItem('4 CAMERAS') then
        local aw=im.GetContentRegionAvail().x; local tw=math.max(220,(aw-16)*0.5); local th=tw*HEIGHT/WIDTH
        tile(cameras.front,tw,th); im.SameLine(); tile(cameras.rear,tw,th)
        tile(cameras.left,tw,th); im.SameLine(); tile(cameras.right,tw,th)
        im.EndTabItem()
      end
      if im.BeginTabItem('CALIBRATION') then calibrationTab(); im.EndTabItem() end
      im.EndTabBar()
    end
  end
  im.End()
end

function M.startSurroundView()
  running=false
  local ok,err=createViews(); if not ok then emitStatus('error',err); return false end
  local cok,cerr=updateCams(); if not cok then emitStatus('error',cerr); return false end
  buildProjectionCache()
  running=true; if showWindow then showWindow[0]=true end
  emitStatus('live','PERFORMANCE AVM LIVE v0.10.0')
  return true
end
function M.startRearCamera() return M.startSurroundView() end
function M.stopSurroundView() running=false; emitStatus('stopped','Surround View stopped') end
function M.stopRearCamera() return M.stopSurroundView() end
function M.onInit() if setExtensionUnloadMode then setExtensionUnloadMode(M,'manual') end end
function M.onPreRender(dt)
  if running then local ok,err=updateCams(); if not ok then running=false; emitStatus('error',err) end end
end
function M.onUpdate(dtReal,dtSim,dtRaw) drawWindow() end
function M.onExtensionUnloaded()
  running=false
  if RenderViewManagerInstance and RenderViewManagerInstance.destroyView then
    for _,cam in pairs(cameras) do
      if cam.renderView then pcall(function() RenderViewManagerInstance:destroyView(cam.renderView) end) end
      cam.renderView=nil
    end
  end
end

return M