local M = {}

-- v0.8.0 OEM TOP-DOWN: four near-vertical cameras, narrow ground strips and parking guides.
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

-- OEM-style top-down layout: each feed occupies only the ground band around the car.
-- The camera views are almost vertical, so far-away perspective is deliberately cropped out.
local calibration = {
  front={k1=-0.05,k2=0.010,flipU=false,flipV=false,rotate=0,
    crop={u0=0.07,v0=0.10,u1=0.93,v1=0.92},
    quad={{0.20,0.00},{0.80,0.00},{0.62,0.35},{0.38,0.35}}},
  rear ={k1=-0.05,k2=0.010,flipU=true,flipV=false,rotate=0,
    crop={u0=0.07,v0=0.10,u1=0.93,v1=0.92},
    quad={{0.38,0.65},{0.62,0.65},{0.80,1.00},{0.20,1.00}}},
  left ={k1=-0.05,k2=0.010,flipU=false,flipV=false,rotate=-90,
    crop={u0=0.07,v0=0.10,u1=0.93,v1=0.92},
    quad={{0.00,0.12},{0.38,0.35},{0.38,0.65},{0.00,0.88}}},
  right={k1=-0.05,k2=0.010,flipU=true,flipV=false,rotate=90,
    crop={u0=0.07,v0=0.10,u1=0.93,v1=0.92},
    quad={{0.62,0.35},{1.00,0.12},{1.00,0.88},{0.62,0.65}}}
}

local running=false
local showWindow=im and im.BoolPtr and im.BoolPtr(true) or nil
local resolution=Point2I(WIDTH,HEIGHT)
local viewport=RectI(0,0,WIDTH,HEIGHT)
local frustum=Frustum.construct(false,FOV,WIDTH/HEIGHT,NEAR_CLIP,FAR_CLIP)
local uv0=im and im.ImVec2(0,0) or nil
local uv1=im and im.ImVec2(1,1) or nil
local uvm0=im and im.ImVec2(1,0) or nil
local uvm1=im and im.ImVec2(0,1) or nil

for _,cam in pairs(cameras) do
  cam.matrix=MatrixF(true)
  cam.quat=QuatF(0,0,0,1)
  cam.renderView=nil
end

local function emitStatus(state,msg)
  if guihooks and guihooks.trigger then
    guihooks.trigger('SurroundViewStatus',{state=state,message=msg or state or 'UNKNOWN',mode='oem-flat-topdown',version='0.8.0'})
  end
end

local function getVehicle()
  if be and be.getPlayerVehicle then
    local ok,v=pcall(function() return be:getPlayerVehicle(0) end)
    if ok and v then return v end
  end
  if getPlayerVehicle then
    local ok,v=pcall(function() return getPlayerVehicle(0) end)
    if ok and v then return v end
  end
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
  local v=getVehicle()
  if not v then return false,'No player vehicle found' end
  local p,d,u,r=basis(v)
  if not p then return false,'Vehicle transform unavailable' end

  local ok,err=pcall(function()
    -- All four feeds are now almost straight-down. A tiny outward component preserves orientation.
    setCam(cameras.front,p+d*2.15+u*1.45,  d*0.10-u*2.20,u)
    setCam(cameras.rear, p-d*2.15+u*1.45, -d*0.10-u*2.20,u)
    setCam(cameras.left, p-r*1.12+u*1.35, -r*0.10-u*2.20,u)
    setCam(cameras.right,p+r*1.12+u*1.35,  r*0.10-u*2.20,u)
  end)
  if not ok then return false,'camera transform failed: '..tostring(err) end
  return true
end

local function createViews()
  if not RenderViewManagerInstance or not RenderViewManagerInstance.getOrCreateView then
    return false,'RenderViewManagerInstance unavailable'
  end
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

local function image(cam,size,mirror)
  local id=tex(cam)
  if not id then im.Dummy(size); return false end
  im.Image(id,size,mirror and uvm0 or uv0,mirror and uvm1 or uv1)
  return true
end

local function tile(cam,w,h,mirror)
  im.BeginGroup(); im.Text(cam.label); image(cam,im.ImVec2(w,h),mirror); im.EndGroup()
end

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
  u=cr.u0+(cr.u1-cr.u0)*u
  v=cr.v0+(cr.v1-cr.v0)*v
  local x,y=(u-0.5)*2,(v-0.5)*2
  local r2=x*x+y*y
  local f=1+c.k1*r2+c.k2*r2*r2
  return math.max(0,math.min(1,0.5+x*f*0.5)),math.max(0,math.min(1,0.5+y*f*0.5))
end

local function proj(c,u,v,o,w,h)
  local q=c.quad
  local xt=q[1][1]*(1-u)+q[2][1]*u
  local yt=q[1][2]*(1-u)+q[2][2]*u
  local xb=q[4][1]*(1-u)+q[3][1]*u
  local yb=q[4][2]*(1-u)+q[3][2]*u
  return o.x+(xt*(1-v)+xb*v)*w,o.y+(yt*(1-v)+yb*v)*h
end

local function warpCells(dl,cam,c,o,w,h)
  local id=tex(cam)
  if not id then return end
  local white=im.GetColorU322(im.ImVec4(1,1,1,1))
  for gy=0,GRID-1 do
    local v0,v1=gy/GRID,(gy+1)/GRID
    for gx=0,GRID-1 do
      local u0,u1=gx/GRID,(gx+1)/GRID
      local x1,y1=proj(c,u0,v0,o,w,h)
      local x2,y2=proj(c,u1,v0,o,w,h)
      local x3,y3=proj(c,u1,v1,o,w,h)
      local x4,y4=proj(c,u0,v1,o,w,h)
      local minx=math.min(x1,x2,x3,x4)-0.35
      local maxx=math.max(x1,x2,x3,x4)+0.35
      local miny=math.min(y1,y2,y3,y4)-0.35
      local maxy=math.max(y1,y2,y3,y4)+0.35
      local su0,sv0=lensUV(c,u0,v0)
      local su1,sv1=lensUV(c,u1,v1)
      dl:AddImage(id,im.ImVec2(minx,miny),im.ImVec2(maxx,maxy),im.ImVec2(su0,sv0),im.ImVec2(su1,sv1),white)
    end
  end
end

local function drawVehicleAndGuides(dl,o,w,h)
  local cx,cy=o.x+w*0.5,o.y+h*0.5
  local cw,ch=w*0.24,h*0.44

  -- Parking-space guide similar to OEM surround systems.
  local guide=im.GetColorU322(im.ImVec4(0.86,0.93,0.96,0.90))
  local leftX=cx-cw*0.82
  local rightX=cx+cw*0.82
  local topY=cy-ch*0.72
  local botY=cy+ch*0.72
  dl:AddLine(im.ImVec2(leftX,topY),im.ImVec2(leftX,botY),guide,2)
  dl:AddLine(im.ImVec2(rightX,topY),im.ImVec2(rightX,botY),guide,2)
  dl:AddLine(im.ImVec2(leftX,topY),im.ImVec2(cx-cw*0.52,topY),guide,2)
  dl:AddLine(im.ImVec2(cx+cw*0.52,topY),im.ImVec2(rightX,topY),guide,2)
  dl:AddLine(im.ImVec2(leftX,botY),im.ImVec2(cx-cw*0.52,botY),guide,2)
  dl:AddLine(im.ImVec2(cx+cw*0.52,botY),im.ImVec2(rightX,botY),guide,2)

  -- Central car mask. It hides the unusable area occupied by the real vehicle.
  local c0=im.ImVec2(cx-cw*0.5,cy-ch*0.5)
  local c1=im.ImVec2(cx+cw*0.5,cy+ch*0.5)
  dl:AddRectFilled(c0,c1,im.GetColorU322(im.ImVec4(0.10,0.13,0.16,1)),cw*0.32,0)
  dl:AddRect(c0,c1,im.GetColorU322(im.ImVec4(0.80,0.87,0.92,1)),cw*0.32,0,2)
  dl:AddRectFilled(im.ImVec2(cx-cw*0.31,cy-ch*0.27),im.ImVec2(cx+cw*0.31,cy+ch*0.20),im.GetColorU322(im.ImVec4(0.04,0.08,0.11,1)),cw*0.17,0)
end

local function surround()
  local a=im.GetContentRegionAvail()
  local s=math.max(300,math.min(a.x,a.y,760))
  local w,h=s*0.72,s
  local p=im.GetCursorScreenPos()
  local o=im.ImVec2(p.x+math.max(0,(a.x-w)*0.5),p.y)
  local dl=im.GetWindowDrawList()

  dl:AddRectFilled(o,im.ImVec2(o.x+w,o.y+h),im.GetColorU322(im.ImVec4(0.035,0.04,0.04,1)),18,0)
  warpCells(dl,cameras.front,calibration.front,o,w,h)
  warpCells(dl,cameras.rear,calibration.rear,o,w,h)
  warpCells(dl,cameras.left,calibration.left,o,w,h)
  warpCells(dl,cameras.right,calibration.right,o,w,h)
  drawVehicleAndGuides(dl,o,w,h)
  dl:AddRect(o,im.ImVec2(o.x+w,o.y+h),im.GetColorU322(im.ImVec4(0.18,0.48,0.75,0.9)),18,0,2)

  im.SetCursorScreenPos(o)
  im.Dummy(im.ImVec2(w,h))
end

local function drawWindow()
  if not im or not running or (showWindow and not showWindow[0]) then return end
  im.SetNextWindowSize(im.ImVec2(900,860),im.Cond_FirstUseEver)
  local open=im.Begin('Surround View - OEM Top Down##surroundView360',showWindow,bit.bor(im.WindowFlags_NoCollapse,im.WindowFlags_NoScrollbar))
  if open then
    im.Text('OEM-style flat bird\'s-eye surround v0.8.0')
    im.Separator()
    if im.BeginTabBar('svTabs') then
      if im.BeginTabItem('360 VIEW') then
        im.Text('Near-vertical 4-camera ground composite')
        local ok,err=pcall(surround)
        if not ok then im.TextColored(im.ImVec4(1,0.35,0.35,1),'360 draw error: '..tostring(err)) end
        im.EndTabItem()
      end
      if im.BeginTabItem('4 CAMERAS') then
        local aw=im.GetContentRegionAvail().x
        local tw=math.max(220,(aw-16)*0.5)
        local th=tw*HEIGHT/WIDTH
        tile(cameras.front,tw,th,false); im.SameLine(); tile(cameras.rear,tw,th,true)
        tile(cameras.left,tw,th,false); im.SameLine(); tile(cameras.right,tw,th,true)
        im.EndTabItem()
      end
      if im.BeginTabItem('CALIBRATION') then
        im.Text('v0.8.0 OEM TOP-DOWN')
        im.Text('960x540 x4 / 32x32 warp / near-vertical cameras')
        im.Text('Goal: flat parking-space view instead of perspective walls')
        im.EndTabItem()
      end
      im.EndTabBar()
    end
  end
  im.End()
end

function M.startSurroundView()
  running=false
  local ok,err=createViews(); if not ok then emitStatus('error',err); return false end
  local cok,cerr=updateCams(); if not cok then emitStatus('error',cerr); return false end
  running=true
  if showWindow then showWindow[0]=true end
  emitStatus('live','OEM TOP-DOWN SURROUND LIVE v0.8.0')
  return true
end
function M.startRearCamera() return M.startSurroundView() end
function M.stopSurroundView() running=false; emitStatus('stopped','Surround View stopped') end
function M.stopRearCamera() return M.stopSurroundView() end
function M.onInit() if setExtensionUnloadMode then setExtensionUnloadMode(M,'manual') end end
function M.onPreRender(dt)
  if running then
    local ok,err=updateCams()
    if not ok then running=false; emitStatus('error',err) end
  end
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