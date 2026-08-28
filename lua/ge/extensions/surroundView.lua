local M = {}

-- v0.9.0 REAL AVM PROJECTION
-- Rebuilt around ground-plane inverse projection instead of hand-authored quads.
-- Each bird's-eye cell represents a real vehicle-local ground coordinate (X,Y,0),
-- which is projected into the four camera images using their position/orientation/FOV.
local im = extensions.ui_imgui or ui_imgui
local imUtils = require('ui/imguiUtils')

local WIDTH, HEIGHT = 960, 540
local ASPECT = WIDTH / HEIGHT
local FOV_DEG = 105
local FOV = math.rad(FOV_DEG)
local NEAR_CLIP, FAR_CLIP = 0.05, 250
local GRID_X, GRID_Y = 44, 56

local cameras = {
  front={view='svFrontView',tex='svFrontTex',label='FRONT'},
  rear ={view='svRearView', tex='svRearTex', label='REAR'},
  left ={view='svLeftView', tex='svLeftTex', label='LEFT'},
  right={view='svRightView',tex='svRightTex',label='RIGHT'}
}

-- Vehicle-local coordinates: +X forward, +Y right, +Z up.
-- yaw: 0 front, +90 right, -90 left, 180 rear. pitch: negative looks down.
local defaults = {
  front={x= 2.10,y= 0.00,z=0.82,yaw=   0,pitch=-36},
  rear ={x=-2.10,y= 0.00,z=0.82,yaw= 180,pitch=-36},
  left ={x= 0.20,y=-1.02,z=1.10,yaw= -90,pitch=-48},
  right={x= 0.20,y= 1.02,z=1.10,yaw=  90,pitch=-48}
}

local function fp(v) return im and im.FloatPtr and im.FloatPtr(v) or {[0]=v} end
local controls = {}
for n,d in pairs(defaults) do
  controls[n]={x=fp(d.x),y=fp(d.y),z=fp(d.z),yaw=fp(d.yaw),pitch=fp(d.pitch)}
end

-- Bird's-eye physical coverage in meters around vehicle center.
local mapControls = {
  front=fp(5.8), rear=fp(4.8), side=fp(3.6), carLength=fp(4.5), carWidth=fp(1.9)
}

local running=false
local showWindow=im and im.BoolPtr and im.BoolPtr(true) or nil
local resolution=Point2I(WIDTH,HEIGHT)
local viewport=RectI(0,0,WIDTH,HEIGHT)
local frustum=Frustum.construct(false,FOV,ASPECT,NEAR_CLIP,FAR_CLIP)
local uv0=im and im.ImVec2(0,0) or nil
local uv1=im and im.ImVec2(1,1) or nil

for _,cam in pairs(cameras) do
  cam.matrix=MatrixF(true)
  cam.quat=QuatF(0,0,0,1)
  cam.renderView=nil
end

local function emitStatus(state,msg)
  if guihooks and guihooks.trigger then
    guihooks.trigger('SurroundViewStatus',{state=state,message=msg or state or 'UNKNOWN',mode='ground-plane-inverse-projection',version='0.9.0'})
  end
end

local function getVehicle()
  if be and be.getPlayerVehicle then local ok,v=pcall(function() return be:getPlayerVehicle(0) end); if ok and v then return v end end
  if getPlayerVehicle then local ok,v=pcall(function() return getPlayerVehicle(0) end); if ok and v then return v end end
end

local function norm(v)
  local ok,o=pcall(function() return v:normalized() end)
  if ok and o then return o end
  pcall(function() v:normalize() end)
  return v
end

local function basis(v)
  local p,d,u=v:getPosition(),v:getDirectionVector(),v:getDirectionVectorUp()
  if not p or not d or not u then return nil end
  d,u=norm(d),norm(u)
  local r
  local ok=pcall(function() r=d:cross(u) end)
  if not ok or not r then r=vec3(-d.y,d.x,0) end
  return p,d,u,norm(r)
end

local function localCameraBasis(c)
  local yaw=math.rad(c.yaw[0])
  local pitch=math.rad(c.pitch[0])
  local cp=math.cos(pitch)
  local f={x=cp*math.cos(yaw),y=cp*math.sin(yaw),z=math.sin(pitch)}
  local fl=math.sqrt(f.x*f.x+f.y*f.y+f.z*f.z); f.x,f.y,f.z=f.x/fl,f.y/fl,f.z/fl
  -- right = worldUp x forward
  local rr={x=-f.y,y=f.x,z=0}
  local rl=math.sqrt(rr.x*rr.x+rr.y*rr.y); if rl<1e-6 then rr={x=0,y=1,z=0} else rr.x,rr.y=rr.x/rl,rr.y/rl end
  -- camera up = forward x right
  local up={x=-f.z*rr.y,y=f.z*rr.x,z=f.x*rr.y-f.y*rr.x}
  local ul=math.sqrt(up.x*up.x+up.y*up.y+up.z*up.z); up.x,up.y,up.z=up.x/ul,up.y/ul,up.z/ul
  return f,rr,up
end

local function toWorldVec(d,r,u,v)
  return d*v.x+r*v.y+u*v.z
end

local function setCam(cam,pos,dir,up)
  local q=quatFromDir(norm(dir),norm(up))
  cam.quat.x,cam.quat.y,cam.quat.z,cam.quat.w=q.x,q.y,q.z,q.w
  cam.matrix:setFromQuatF(cam.quat)
  cam.matrix:setPosition(pos)
  cam.renderView.cameraMatrix=cam.matrix
end

local function updateCams()
  local veh=getVehicle(); if not veh then return false,'No player vehicle found' end
  local p,d,u,r=basis(veh); if not p then return false,'Vehicle transform unavailable' end
  local ok,err=pcall(function()
    for name,cam in pairs(cameras) do
      local c=controls[name]
      local lf,_,lu=localCameraBasis(c)
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
    for _,cam in pairs(cameras) do
      cam.renderView=RenderViewManagerInstance:getOrCreateView(cam.view)
      cam.renderView.renderCubemap=false
      cam.renderView.cameraMatrix=cam.matrix
      cam.renderView.resolution=resolution
      cam.renderView.viewPort=viewport
      cam.renderView.namedTexTargetColor=cam.tex
      cam.renderView.frustum=frustum
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

local tanV=math.tan(FOV*0.5)
local tanH=tanV*ASPECT

-- Project one vehicle-local ground point into one source camera.
-- Returns normalized image UV and a score. No hand-authored bird's-eye quad is involved.
local function projectGround(name,X,Y)
  local c=controls[name]
  local f,rr,up=localCameraBasis(c)
  local rx=X-c.x[0]; local ry=Y-c.y[0]; local rz=-c.z[0]
  local zc=rx*f.x+ry*f.y+rz*f.z
  if zc<=0.06 then return nil end
  local xc=rx*rr.x+ry*rr.y+rz*rr.z
  local yc=rx*up.x+ry*up.y+rz*up.z
  local U=0.5+xc/(2*zc*tanH)
  local V=0.5-yc/(2*zc*tanV)
  if U<0.003 or U>0.997 or V<0.003 or V>0.997 then return nil end
  local dist=math.sqrt(rx*rx+ry*ry+rz*rz)
  local score=zc/math.max(dist,0.001)
  return U,V,score
end

local cameraOrder={'front','rear','left','right'}

local function chooseCamera(X,Y)
  local best,bU,bV,bScore=nil,nil,nil,-1e9
  for _,name in ipairs(cameraOrder) do
    local U,V,score=projectGround(name,X,Y)
    if U and score>bScore then best,bU,bV,bScore=name,U,V,score end
  end
  return best,bU,bV
end

-- Bird's-eye output pixel -> actual ground coordinate.
local function groundAt(gx,gy)
  local nx=gx/GRID_X
  local ny=gy/GRID_Y
  local Y=(nx*2-1)*mapControls.side[0]
  local X=mapControls.front[0]-(mapControls.front[0]+mapControls.rear[0])*ny
  return X,Y
end

local function drawProjectedGround(dl,o,w,h)
  local white=im.GetColorU322(im.ImVec4(1,1,1,1))
  local cellW=w/GRID_X
  local cellH=h/GRID_Y

  for gy=0,GRID_Y-1 do
    for gx=0,GRID_X-1 do
      local Xc,Yc=groundAt(gx+0.5,gy+0.5)
      local name=chooseCamera(Xc,Yc)
      if name then
        local X0,Y0=groundAt(gx,gy)
        local X1,Y1=groundAt(gx+1,gy+1)
        local u0,v0=projectGround(name,X0,Y0)
        local u1,v1=projectGround(name,X1,Y1)
        if u0 and u1 then
          local id=tex(cameras[name])
          if id then
            local px=o.x+gx*cellW
            local py=o.y+gy*cellH
            -- Small overlap removes raster cracks; inverse projection supplies the UVs.
            dl:AddImage(id,im.ImVec2(px-0.18,py-0.18),im.ImVec2(px+cellW+0.18,py+cellH+0.18),im.ImVec2(u0,v0),im.ImVec2(u1,v1),white)
          end
        end
      end
    end
  end
end

local function drawVehicleMask(dl,o,w,h)
  local totalX=mapControls.front[0]+mapControls.rear[0]
  local totalY=mapControls.side[0]*2
  local carW=w*(mapControls.carWidth[0]/totalY)
  local carH=h*(mapControls.carLength[0]/totalX)
  local centerY=o.y+h*(mapControls.front[0]/totalX)
  local cx=o.x+w*0.5
  local c0=im.ImVec2(cx-carW*0.5,centerY-carH*0.5)
  local c1=im.ImVec2(cx+carW*0.5,centerY+carH*0.5)
  dl:AddRectFilled(c0,c1,im.GetColorU322(im.ImVec4(0.10,0.13,0.16,1)),carW*0.22,0)
  dl:AddRect(c0,c1,im.GetColorU322(im.ImVec4(0.83,0.89,0.94,1)),carW*0.22,0,2)
  local glass0=im.ImVec2(cx-carW*0.30,centerY-carH*0.25)
  local glass1=im.ImVec2(cx+carW*0.30,centerY+carH*0.18)
  dl:AddRectFilled(glass0,glass1,im.GetColorU322(im.ImVec4(0.04,0.08,0.11,1)),carW*0.12,0)
end

local function surround()
  local a=im.GetContentRegionAvail()
  local h=math.max(380,math.min(a.y,760))
  local physicalAspect=(mapControls.side[0]*2)/(mapControls.front[0]+mapControls.rear[0])
  local w=math.min(a.x,h*physicalAspect)
  h=w/physicalAspect
  local p=im.GetCursorScreenPos()
  local o=im.ImVec2(p.x+math.max(0,(a.x-w)*0.5),p.y)
  local dl=im.GetWindowDrawList()
  dl:AddRectFilled(o,im.ImVec2(o.x+w,o.y+h),im.GetColorU322(im.ImVec4(0.025,0.03,0.035,1)),12,0)
  drawProjectedGround(dl,o,w,h)
  drawVehicleMask(dl,o,w,h)
  dl:AddRect(o,im.ImVec2(o.x+w,o.y+h),im.GetColorU322(im.ImVec4(0.15,0.55,1,0.9)),12,0,2)
  im.SetCursorScreenPos(o); im.Dummy(im.ImVec2(w,h))
end

local function resetCamera(name)
  local d=defaults[name]; local c=controls[name]
  c.x[0],c.y[0],c.z[0],c.yaw[0],c.pitch[0]=d.x,d.y,d.z,d.yaw,d.pitch
end

local function slider(label,ptr,a,b,fmt)
  im.SetNextItemWidth(280); im.SliderFloat(label,ptr,a,b,fmt or '%.2f')
end

local function cameraEditor(name)
  local c=controls[name]
  im.Separator(); im.Text(string.upper(name)..' CAMERA')
  slider('X Forward##'..name,c.x,-4,4,'%.2f m')
  slider('Y Right##'..name,c.y,-2.5,2.5,'%.2f m')
  slider('Z Height##'..name,c.z,0.2,2.5,'%.2f m')
  slider('Yaw##'..name,c.yaw,-180,180,'%.1f deg')
  slider('Pitch##'..name,c.pitch,-85,10,'%.1f deg')
  if im.Button('Reset '..string.upper(name)) then resetCamera(name) end
end

local function calibrationTab()
  im.Text('REAL GROUND-PLANE CALIBRATION v0.9.0')
  im.Text('Camera position/orientation is used directly by the bird-eye projection math.')
  im.Text('No manual trapezoid/quad calibration is used anymore.')
  cameraEditor('front'); cameraEditor('rear'); cameraEditor('left'); cameraEditor('right')
  im.Separator(); im.Text('BIRD-EYE PHYSICAL COVERAGE')
  slider('Forward coverage',mapControls.front,2.5,10,'%.2f m')
  slider('Rear coverage',mapControls.rear,2.5,10,'%.2f m')
  slider('Side coverage',mapControls.side,2.0,7,'%.2f m')
  slider('Vehicle length mask',mapControls.carLength,3.0,6.5,'%.2f m')
  slider('Vehicle width mask',mapControls.carWidth,1.4,2.8,'%.2f m')
  if im.Button('RESET ALL CAMERAS') then for n,_ in pairs(controls) do resetCamera(n) end end
end

local function drawWindow()
  if not im or not running or (showWindow and not showWindow[0]) then return end
  im.SetNextWindowSize(im.ImVec2(1040,900),im.Cond_FirstUseEver)
  local open=im.Begin('Surround View - Real Ground Projection##surroundView360',showWindow,bit.bor(im.WindowFlags_NoCollapse,im.WindowFlags_NoScrollbar))
  if open then
    im.Text('4-camera AVM / inverse ground-plane projection v0.9.0'); im.Separator()
    if im.BeginTabBar('svTabs') then
      if im.BeginTabItem('360 VIEW') then
        im.Text('Every output cell is projected from a real ground coordinate into the source cameras.')
        local ok,err=pcall(surround)
        if not ok then im.TextColored(im.ImVec4(1,0.35,0.35,1),'360 draw error: '..tostring(err)); emitStatus('error','360 draw error: '..tostring(err)) end
        im.EndTabItem()
      end
      if im.BeginTabItem('4 CAMERAS') then
        local aw=im.GetContentRegionAvail().x; local tw=math.max(240,(aw-16)*0.5); local th=tw*HEIGHT/WIDTH
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
  running=true; if showWindow then showWindow[0]=true end
  emitStatus('live','GROUND PROJECTION SURROUND LIVE v0.9.0')
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