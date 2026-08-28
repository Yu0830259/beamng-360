local M = {}

-- v0.8.1: OEM top-down surround + live camera calibration controls.
local im = extensions.ui_imgui or ui_imgui
local imUtils = require('ui/imguiUtils')

local WIDTH, HEIGHT = 960, 540
local FOV = math.rad(105)
local NEAR_CLIP, FAR_CLIP = 0.05, 250
local GRID = 32

local cameras = {
  front={view='svFrontView',tex='svFrontTex',label='FRONT'},
  rear ={view='svRearView', tex='svRearTex', label='REAR'},
  left ={view='svLeftView', tex='svLeftTex', label='LEFT'},
  right={view='svRightView',tex='svRightTex',label='RIGHT'}
}

local calibration = {
  front={k1=-0.05,k2=0.010,flipU=false,flipV=false,rotate=0,crop={u0=0.07,v0=0.10,u1=0.93,v1=0.92},quad={{0.20,0.00},{0.80,0.00},{0.62,0.35},{0.38,0.35}}},
  rear ={k1=-0.05,k2=0.010,flipU=true, flipV=false,rotate=0,crop={u0=0.07,v0=0.10,u1=0.93,v1=0.92},quad={{0.38,0.65},{0.62,0.65},{0.80,1.00},{0.20,1.00}}},
  left ={k1=-0.05,k2=0.010,flipU=false,flipV=false,rotate=-90,crop={u0=0.07,v0=0.10,u1=0.93,v1=0.92},quad={{0.00,0.12},{0.38,0.35},{0.38,0.65},{0.00,0.88}}},
  right={k1=-0.05,k2=0.010,flipU=true, flipV=false,rotate=90,crop={u0=0.07,v0=0.10,u1=0.93,v1=0.92},quad={{0.62,0.35},{1.00,0.12},{1.00,0.88},{0.62,0.65}}}
}

local defaults = {
  front={long= 2.15, lateral=0.00, height=1.45, down=2.20, outward=0.10},
  rear ={long=-2.15, lateral=0.00, height=1.45, down=2.20, outward=0.10},
  left ={long= 0.00, lateral=-1.12,height=1.35, down=2.20, outward=0.10},
  right={long= 0.00, lateral= 1.12,height=1.35, down=2.20, outward=0.10}
}

local controls = {}
local function fp(v) return im and im.FloatPtr and im.FloatPtr(v) or {[0]=v} end
local function makeControls(src)
  return {long=fp(src.long),lateral=fp(src.lateral),height=fp(src.height),down=fp(src.down),outward=fp(src.outward)}
end
for n,d in pairs(defaults) do controls[n]=makeControls(d) end

local running=false
local showWindow=im and im.BoolPtr and im.BoolPtr(true) or nil
local resolution=Point2I(WIDTH,HEIGHT)
local viewport=RectI(0,0,WIDTH,HEIGHT)
local frustum=Frustum.construct(false,FOV,WIDTH/HEIGHT,NEAR_CLIP,FAR_CLIP)
local uv0=im and im.ImVec2(0,0) or nil
local uv1=im and im.ImVec2(1,1) or nil
local uvm0=im and im.ImVec2(1,0) or nil
local uvm1=im and im.ImVec2(0,1) or nil

for _,cam in pairs(cameras) do cam.matrix=MatrixF(true); cam.quat=QuatF(0,0,0,1); cam.renderView=nil end

local function emitStatus(state,msg)
  if guihooks and guihooks.trigger then guihooks.trigger('SurroundViewStatus',{state=state,message=msg or state or 'UNKNOWN',mode='interactive-camera-calibration',version='0.8.1'}) end
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

local function setCam(cam,p,d,u)
  local q=quatFromDir(norm(d),u)
  cam.quat.x,cam.quat.y,cam.quat.z,cam.quat.w=q.x,q.y,q.z,q.w
  cam.matrix:setFromQuatF(cam.quat)
  cam.matrix:setPosition(p)
  cam.renderView.cameraMatrix=cam.matrix
end

local function updateCams()
  local v=getVehicle(); if not v then return false,'No player vehicle found' end
  local p,d,u,r=basis(v); if not p then return false,'Vehicle transform unavailable' end

  local f=controls.front; local b=controls.rear; local l=controls.left; local rr=controls.right
  local ok,err=pcall(function()
    local fp0=p+d*f.long[0]+r*f.lateral[0]+u*f.height[0]
    local rp0=p+d*b.long[0]+r*b.lateral[0]+u*b.height[0]
    local lp0=p+d*l.long[0]+r*l.lateral[0]+u*l.height[0]
    local rp1=p+d*rr.long[0]+r*rr.lateral[0]+u*rr.height[0]

    setCam(cameras.front,fp0, d*f.outward[0]-u*f.down[0],u)
    setCam(cameras.rear, rp0,-d*b.outward[0]-u*b.down[0],u)
    setCam(cameras.left, lp0,-r*l.outward[0]-u*l.down[0],u)
    setCam(cameras.right,rp1, r*rr.outward[0]-u*rr.down[0],u)
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

local function tex(cam) local o=imUtils.texObj('#'..cam.tex); return o and o.texId or nil end
local function image(cam,size,mirror)
  local id=tex(cam); if not id then im.Dummy(size); return false end
  im.Image(id,size,mirror and uvm0 or uv0,mirror and uvm1 or uv1); return true
end
local function tile(cam,w,h,mirror) im.BeginGroup(); im.Text(cam.label); image(cam,im.ImVec2(w,h),mirror); im.EndGroup() end

local function rotateUV(c,u,v)
  if c.rotate==90 then return 1-v,u end
  if c.rotate==-90 then return v,1-u end
  return u,v
end
local function lensUV(c,u,v)
  u,v=rotateUV(c,u,v)
  if c.flipU then u=1-u end
  if c.flipV then v=1-v end
  local cr=c.crop
  u=cr.u0+(cr.u1-cr.u0)*u; v=cr.v0+(cr.v1-cr.v0)*v
  local x,y=(u-0.5)*2,(v-0.5)*2; local r2=x*x+y*y; local f=1+c.k1*r2+c.k2*r2*r2
  return math.max(0,math.min(1,0.5+x*f*0.5)),math.max(0,math.min(1,0.5+y*f*0.5))
end
local function proj(c,u,v,o,w,h)
  local q=c.quad
  local xt=q[1][1]*(1-u)+q[2][1]*u; local yt=q[1][2]*(1-u)+q[2][2]*u
  local xb=q[4][1]*(1-u)+q[3][1]*u; local yb=q[4][2]*(1-u)+q[3][2]*u
  return o.x+(xt*(1-v)+xb*v)*w,o.y+(yt*(1-v)+yb*v)*h
end
local function warpCells(dl,cam,c,o,w,h)
  local id=tex(cam); if not id then return end
  local white=im.GetColorU322(im.ImVec4(1,1,1,1))
  for gy=0,GRID-1 do local v0,v1=gy/GRID,(gy+1)/GRID
    for gx=0,GRID-1 do local u0,u1=gx/GRID,(gx+1)/GRID
      local x1,y1=proj(c,u0,v0,o,w,h); local x2,y2=proj(c,u1,v0,o,w,h); local x3,y3=proj(c,u1,v1,o,w,h); local x4,y4=proj(c,u0,v1,o,w,h)
      local minx=math.min(x1,x2,x3,x4)-0.35; local maxx=math.max(x1,x2,x3,x4)+0.35
      local miny=math.min(y1,y2,y3,y4)-0.35; local maxy=math.max(y1,y2,y3,y4)+0.35
      local su0,sv0=lensUV(c,u0,v0); local su1,sv1=lensUV(c,u1,v1)
      dl:AddImage(id,im.ImVec2(minx,miny),im.ImVec2(maxx,maxy),im.ImVec2(su0,sv0),im.ImVec2(su1,sv1),white)
    end
  end
end

local function drawVehicleAndGuides(dl,o,w,h)
  local cx,cy=o.x+w*0.5,o.y+h*0.5; local cw,ch=w*0.24,h*0.44
  local guide=im.GetColorU322(im.ImVec4(0.86,0.93,0.96,0.90))
  local lx,rx=cx-cw*0.82,cx+cw*0.82; local ty,by=cy-ch*0.72,cy+ch*0.72
  dl:AddLine(im.ImVec2(lx,ty),im.ImVec2(lx,by),guide,2); dl:AddLine(im.ImVec2(rx,ty),im.ImVec2(rx,by),guide,2)
  local c0=im.ImVec2(cx-cw*0.5,cy-ch*0.5); local c1=im.ImVec2(cx+cw*0.5,cy+ch*0.5)
  dl:AddRectFilled(c0,c1,im.GetColorU322(im.ImVec4(0.10,0.13,0.16,1)),cw*0.32,0)
  dl:AddRect(c0,c1,im.GetColorU322(im.ImVec4(0.80,0.87,0.92,1)),cw*0.32,0,2)
  dl:AddRectFilled(im.ImVec2(cx-cw*0.31,cy-ch*0.27),im.ImVec2(cx+cw*0.31,cy+ch*0.20),im.GetColorU322(im.ImVec4(0.04,0.08,0.11,1)),cw*0.17,0)
end

local function surround()
  local a=im.GetContentRegionAvail(); local s=math.max(300,math.min(a.x,a.y,760)); local w,h=s*0.72,s
  local p=im.GetCursorScreenPos(); local o=im.ImVec2(p.x+math.max(0,(a.x-w)*0.5),p.y); local dl=im.GetWindowDrawList()
  dl:AddRectFilled(o,im.ImVec2(o.x+w,o.y+h),im.GetColorU322(im.ImVec4(0.035,0.04,0.04,1)),18,0)
  warpCells(dl,cameras.front,calibration.front,o,w,h); warpCells(dl,cameras.rear,calibration.rear,o,w,h)
  warpCells(dl,cameras.left,calibration.left,o,w,h); warpCells(dl,cameras.right,calibration.right,o,w,h)
  drawVehicleAndGuides(dl,o,w,h)
  dl:AddRect(o,im.ImVec2(o.x+w,o.y+h),im.GetColorU322(im.ImVec4(0.18,0.48,0.75,0.9)),18,0,2)
  im.SetCursorScreenPos(o); im.Dummy(im.ImVec2(w,h))
end

local function resetCamera(name)
  local d=defaults[name]; local c=controls[name]
  c.long[0]=d.long; c.lateral[0]=d.lateral; c.height[0]=d.height; c.down[0]=d.down; c.outward[0]=d.outward
end

local function slider(label,ptr,minv,maxv,fmt)
  im.SetNextItemWidth(260)
  im.SliderFloat(label,ptr,minv,maxv,fmt or '%.2f')
end

local function cameraControls(name)
  local c=controls[name]
  im.Separator()
  im.Text(string.upper(name)..' CAMERA')
  slider('Forward / Back##'..name,c.long,-4.0,4.0,'%.2f m')
  slider('Left / Right##'..name,c.lateral,-2.5,2.5,'%.2f m')
  slider('Height##'..name,c.height,0.20,3.0,'%.2f m')
  slider('Downward##'..name,c.down,0.10,4.0,'%.2f')
  slider('Outward##'..name,c.outward,-1.0,1.0,'%.2f')
  if im.Button('Reset '..string.upper(name)) then resetCamera(name) end
end

local function calibrationTab()
  im.Text('LIVE CAMERA POSITION EDITOR v0.8.1')
  im.Text('Move sliders while watching the 4 CAMERAS tab. Changes apply immediately.')
  im.Text('Forward/Back and Left/Right are relative to the vehicle.')
  cameraControls('front'); cameraControls('rear'); cameraControls('left'); cameraControls('right')
  im.Separator()
  if im.Button('RESET ALL CAMERAS') then for n,_ in pairs(controls) do resetCamera(n) end end
end

local function drawWindow()
  if not im or not running or (showWindow and not showWindow[0]) then return end
  im.SetNextWindowSize(im.ImVec2(980,900),im.Cond_FirstUseEver)
  local open=im.Begin('Surround View - OEM Top Down##surroundView360',showWindow,bit.bor(im.WindowFlags_NoCollapse,im.WindowFlags_NoScrollbar))
  if open then
    im.Text('OEM top-down + live camera editor v0.8.1'); im.Separator()
    if im.BeginTabBar('svTabs') then
      if im.BeginTabItem('360 VIEW') then
        local ok,err=pcall(surround); if not ok then im.TextColored(im.ImVec4(1,0.35,0.35,1),'360 draw error: '..tostring(err)) end
        im.EndTabItem()
      end
      if im.BeginTabItem('4 CAMERAS') then
        local aw=im.GetContentRegionAvail().x; local tw=math.max(220,(aw-16)*0.5); local th=tw*HEIGHT/WIDTH
        tile(cameras.front,tw,th,false); im.SameLine(); tile(cameras.rear,tw,th,true)
        tile(cameras.left,tw,th,false); im.SameLine(); tile(cameras.right,tw,th,true)
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
  emitStatus('live','INTERACTIVE CAMERA CALIBRATION v0.8.1'); return true
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
    for _,cam in pairs(cameras) do if cam.renderView then pcall(function() RenderViewManagerInstance:destroyView(cam.renderView) end) end; cam.renderView=nil end
  end
end

return M