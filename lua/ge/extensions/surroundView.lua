local M = {}

-- v1.0.0 REAR CAMERA ONLY
-- One persistent rear RenderView. No surround stitching, no projection cache, no four-camera rendering.
local im = extensions.ui_imgui or ui_imgui
local imUtils = require('ui/imguiUtils')

local WIDTH, HEIGHT = 960, 540
local ASPECT = WIDTH / HEIGHT
local NEAR_CLIP, FAR_CLIP = 0.05, 250

local rear = {
  view = 'svRearOnlyView',
  tex = 'svRearOnlyTex',
  matrix = MatrixF(true),
  quat = QuatF(0,0,0,1),
  renderView = nil
}

local function fp(v) return im and im.FloatPtr and im.FloatPtr(v) or {[0]=v} end
local cfg = {
  x = fp(-2.15),      -- vehicle-local: +X forward
  y = fp(0.00),       -- +Y right
  z = fp(0.88),       -- +Z up
  yaw = fp(180.0),
  pitch = fp(-16.0),
  roll = fp(0.0),
  fov = fp(118.0),
  guideWidth = fp(1.95),
  guideNear = fp(0.18),
  guideFar = fp(0.40)
}

local running = false
local showWindow = im and im.BoolPtr and im.BoolPtr(true) or nil
local resolution = Point2I(WIDTH, HEIGHT)
local viewport = RectI(0, 0, WIDTH, HEIGHT)
local uvMirror0 = im and im.ImVec2(1,0) or nil
local uvMirror1 = im and im.ImVec2(0,1) or nil

local function emitStatus(state,msg)
  if guihooks and guihooks.trigger then
    guihooks.trigger('SurroundViewStatus',{
      state=state,
      message=msg or state or 'UNKNOWN',
      mode='rear-camera-only',
      version='1.0.0'
    })
  end
end

local function getVehicle()
  if be and be.getPlayerVehicle then
    local ok,v = pcall(function() return be:getPlayerVehicle(0) end)
    if ok and v then return v end
  end
  if getPlayerVehicle then
    local ok,v = pcall(function() return getPlayerVehicle(0) end)
    if ok and v then return v end
  end
end

local function norm(v)
  local ok,o = pcall(function() return v:normalized() end)
  if ok and o then return o end
  pcall(function() v:normalize() end)
  return v
end

local function vehicleBasis(v)
  local p,d,u = v:getPosition(), v:getDirectionVector(), v:getDirectionVectorUp()
  if not p or not d or not u then return nil end
  d,u = norm(d), norm(u)
  local r
  local ok = pcall(function() r = d:cross(u) end)
  if not ok or not r then r = vec3(-d.y,d.x,0) end
  return p,d,u,norm(r)
end

local function localCameraBasis()
  local yaw = math.rad(cfg.yaw[0])
  local pitch = math.rad(cfg.pitch[0])
  local cp = math.cos(pitch)
  local f = {x=cp*math.cos(yaw), y=cp*math.sin(yaw), z=math.sin(pitch)}
  local fl = math.sqrt(f.x*f.x + f.y*f.y + f.z*f.z)
  f.x,f.y,f.z = f.x/fl,f.y/fl,f.z/fl

  local rr = {x=-f.y, y=f.x, z=0}
  local rl = math.sqrt(rr.x*rr.x + rr.y*rr.y)
  if rl < 1e-6 then rr={x=0,y=1,z=0} else rr.x,rr.y=rr.x/rl,rr.y/rl end

  local up = {x=-f.z*rr.y, y=f.z*rr.x, z=f.x*rr.y-f.y*rr.x}
  local ul = math.sqrt(up.x*up.x + up.y*up.y + up.z*up.z)
  up.x,up.y,up.z = up.x/ul,up.y/ul,up.z/ul

  local roll = math.rad(cfg.roll[0])
  local c,s = math.cos(roll),math.sin(roll)
  local rr2 = {x=rr.x*c+up.x*s, y=rr.y*c+up.y*s, z=rr.z*c+up.z*s}
  local up2 = {x=up.x*c-rr.x*s, y=up.y*c-rr.y*s, z=up.z*c-rr.z*s}
  return f,rr2,up2
end

local function toWorld(d,r,u,v)
  return d*v.x + r*v.y + u*v.z
end

local function updateCamera()
  local veh = getVehicle()
  if not veh then return false,'No player vehicle found' end
  local p,d,u,r = vehicleBasis(veh)
  if not p then return false,'Vehicle transform unavailable' end

  local ok,err = pcall(function()
    local lf,_,lu = localCameraBasis()
    local pos = p + d*cfg.x[0] + r*cfg.y[0] + u*cfg.z[0]
    local dir = toWorld(d,r,u,lf)
    local up = toWorld(d,r,u,lu)
    local q = quatFromDir(norm(dir),norm(up))
    rear.quat.x,rear.quat.y,rear.quat.z,rear.quat.w = q.x,q.y,q.z,q.w
    rear.matrix:setFromQuatF(rear.quat)
    rear.matrix:setPosition(pos)
    rear.renderView.cameraMatrix = rear.matrix
    rear.renderView.frustum = Frustum.construct(false,math.rad(cfg.fov[0]),ASPECT,NEAR_CLIP,FAR_CLIP)
  end)

  if not ok then return false,'Rear camera transform failed: '..tostring(err) end
  return true
end

local function createView()
  if not RenderViewManagerInstance or not RenderViewManagerInstance.getOrCreateView then
    return false,'RenderViewManagerInstance unavailable'
  end

  local ok,err = pcall(function()
    rear.renderView = RenderViewManagerInstance:getOrCreateView(rear.view)
    rear.renderView.renderCubemap = false
    rear.renderView.cameraMatrix = rear.matrix
    rear.renderView.resolution = resolution
    rear.renderView.viewPort = viewport
    rear.renderView.namedTexTargetColor = rear.tex
    rear.renderView.frustum = Frustum.construct(false,math.rad(cfg.fov[0]),ASPECT,NEAR_CLIP,FAR_CLIP)
  end)

  if not ok then return false,'Rear RenderView setup failed: '..tostring(err) end
  return true
end

local function textureId()
  local o = imUtils.texObj('#'..rear.tex)
  return o and o.texId or nil
end

local function drawGuides(dl,p0,p1)
  local w = p1.x-p0.x
  local h = p1.y-p0.y
  local cx = p0.x+w*0.5
  local nearY = p0.y+h*0.78
  local farY  = p0.y+h*0.48

  local nearHalf = w*cfg.guideNear[0]
  local farHalf  = w*cfg.guideFar[0]

  local green = im.GetColorU322(im.ImVec4(0.20,1.00,0.25,0.95))
  local yellow = im.GetColorU322(im.ImVec4(1.00,0.88,0.18,0.95))
  local red = im.GetColorU322(im.ImVec4(1.00,0.20,0.15,0.95))

  dl:AddLine(im.ImVec2(cx-nearHalf,nearY),im.ImVec2(cx-farHalf,farY),green,3)
  dl:AddLine(im.ImVec2(cx+nearHalf,nearY),im.ImVec2(cx+farHalf,farY),green,3)

  dl:AddLine(im.ImVec2(cx-nearHalf,nearY),im.ImVec2(cx+nearHalf,nearY),red,3)
  local midY = p0.y+h*0.63
  local t = (nearY-midY)/(nearY-farY)
  local midHalf = nearHalf*(1-t)+farHalf*t
  dl:AddLine(im.ImVec2(cx-midHalf,midY),im.ImVec2(cx+midHalf,midY),yellow,3)
  dl:AddLine(im.ImVec2(cx-farHalf,farY),im.ImVec2(cx+farHalf,farY),green,3)
end

local function slider(label,ptr,a,b,fmt)
  im.SetNextItemWidth(260)
  im.SliderFloat(label,ptr,a,b,fmt or '%.2f')
end

local function drawCalibration()
  im.Text('REAR CAMERA CALIBRATION')
  slider('X Forward##rear',cfg.x,-4.0,1.0,'%.2f m')
  slider('Y Right##rear',cfg.y,-2.0,2.0,'%.2f m')
  slider('Z Height##rear',cfg.z,0.2,2.5,'%.2f m')
  slider('Yaw##rear',cfg.yaw,120,240,'%.1f deg')
  slider('Pitch##rear',cfg.pitch,-60,10,'%.1f deg')
  slider('Roll##rear',cfg.roll,-30,30,'%.1f deg')
  slider('FOV##rear',cfg.fov,70,150,'%.1f deg')
  slider('Guide near width##rear',cfg.guideNear,0.08,0.35,'%.2f')
  slider('Guide far width##rear',cfg.guideFar,0.18,0.48,'%.2f')

  if im.Button('RESET REAR CAMERA') then
    cfg.x[0],cfg.y[0],cfg.z[0] = -2.15,0.00,0.88
    cfg.yaw[0],cfg.pitch[0],cfg.roll[0],cfg.fov[0] = 180,-16,0,118
    cfg.guideNear[0],cfg.guideFar[0] = 0.18,0.40
  end
end

local function drawWindow()
  if not im or not running or (showWindow and not showWindow[0]) then return end

  im.SetNextWindowSize(im.ImVec2(900,650),im.Cond_FirstUseEver)
  local open = im.Begin('Rear Camera##surroundView360',showWindow,bit.bor(im.WindowFlags_NoCollapse,im.WindowFlags_NoScrollbar))

  if open then
    im.Text('REAR CAMERA ONLY v1.0.0 - 1 RenderView / no 360 processing')
    im.Separator()

    if im.BeginTabBar('rearTabs') then
      if im.BeginTabItem('CAMERA') then
        local avail = im.GetContentRegionAvail()
        local drawW = math.min(avail.x,860)
        local drawH = drawW / ASPECT
        local p0 = im.GetCursorScreenPos()
        local id = textureId()
        if id then
          im.Image(id,im.ImVec2(drawW,drawH),uvMirror0,uvMirror1)
          local dl = im.GetWindowDrawList()
          drawGuides(dl,p0,im.ImVec2(p0.x+drawW,p0.y+drawH))
        else
          im.Dummy(im.ImVec2(drawW,drawH))
          im.Text('Rear camera texture unavailable')
        end
        im.EndTabItem()
      end

      if im.BeginTabItem('CALIBRATION') then
        drawCalibration()
        im.EndTabItem()
      end
      im.EndTabBar()
    end
  end
  im.End()
end

function M.startRearCamera()
  running = false
  local ok,err = createView()
  if not ok then emitStatus('error',err); return false end
  local cok,cerr = updateCamera()
  if not cok then emitStatus('error',cerr); return false end
  running = true
  if showWindow then showWindow[0] = true end
  emitStatus('live','REAR CAMERA LIVE v1.0.0')
  return true
end

-- Compatibility with the existing UI app button.
function M.startSurroundView() return M.startRearCamera() end

function M.stopRearCamera()
  running = false
  emitStatus('stopped','Rear camera stopped')
end
function M.stopSurroundView() return M.stopRearCamera() end

function M.onInit()
  if setExtensionUnloadMode then setExtensionUnloadMode(M,'manual') end
end

function M.onPreRender(dt)
  if running then
    local ok,err = updateCamera()
    if not ok then
      running = false
      emitStatus('error',err)
    end
  end
end

function M.onUpdate(dtReal,dtSim,dtRaw)
  drawWindow()
end

function M.onExtensionUnloaded()
  running = false
  if rear.renderView and RenderViewManagerInstance and RenderViewManagerInstance.destroyView then
    pcall(function() RenderViewManagerInstance:destroyView(rear.renderView) end)
  end
  rear.renderView = nil
end

return M