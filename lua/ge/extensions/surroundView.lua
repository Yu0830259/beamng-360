local M = {}

-- v1.1.1 REAR CAMERA ONLY + CORRECTED DYNAMIC GUIDELINES
-- Fixes perspective direction (near = wide, far = narrow) and mirrors steering
-- direction to match the mirrored rear-camera image.
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
  x = fp(-2.15),
  y = fp(0.00),
  z = fp(0.88),
  yaw = fp(180.0),
  pitch = fp(-16.0),
  roll = fp(0.0),
  fov = fp(118.0),

  -- Screen-space perspective: the guide is wider near the bumper and narrower far away.
  guideNearHalf = fp(0.36),
  guideFarHalf = fp(0.20),
  guideSteerGain = fp(0.25),
  guideCurvePower = fp(1.75),
  steeringSmoothing = fp(0.22),
  mirrorSteering = true
}

local running = false
local showWindow = im and im.BoolPtr and im.BoolPtr(true) or nil
local resolution = Point2I(WIDTH, HEIGHT)
local viewport = RectI(0, 0, WIDTH, HEIGHT)
local uvMirror0 = im and im.ImVec2(1,0) or nil
local uvMirror1 = im and im.ImVec2(0,1) or nil

local steeringRaw = 0
local steeringSmooth = 0
local steeringPollTimer = 0
local STEERING_POLL_INTERVAL = 0.05

local function clamp(v,a,b)
  if type(v) ~= 'number' or v ~= v then return a end
  return math.max(a,math.min(b,v))
end

local function emitStatus(state,msg)
  if guihooks and guihooks.trigger then
    guihooks.trigger('SurroundViewStatus',{
      state=state,
      message=msg or state or 'UNKNOWN',
      mode='rear-camera-dynamic-guides-corrected',
      version='1.1.1'
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

function M.setSteeringValue(value)
  steeringRaw = clamp(tonumber(value) or 0,-1,1)
end

local function requestSteeringFromVehicle(dt)
  steeringPollTimer = steeringPollTimer + (dt or 0)
  if steeringPollTimer < STEERING_POLL_INTERVAL then return end
  steeringPollTimer = steeringPollTimer - STEERING_POLL_INTERVAL

  local veh = getVehicle()
  if not veh or not veh.queueLuaCommand then return end

  local cmd = [[
    local s = 0
    if electrics and electrics.values then
      s = electrics.values.steering_input or electrics.values.steering or 0
    end
    if (not s or s == 0) and input then s = input.steering or 0 end
    obj:queueGameEngineLua('extensions.surroundView.setSteeringValue(' .. tostring(s or 0) .. ')')
  ]]
  pcall(function() veh:queueLuaCommand(cmd) end)
end

local function displayedSteering()
  -- The camera image itself is horizontally mirrored, so the guide needs the same transform.
  return cfg.mirrorSteering and -steeringSmooth or steeringSmooth
end

local function guidePoint(p0,w,h,t,side)
  -- t=0: closest to bumper (bottom). t=1: farthest away (top).
  local nearY = p0.y + h*0.79
  local farY  = p0.y + h*0.42
  local y = nearY + (farY-nearY)*t

  -- Correct perspective: near is visually wider, far is narrower.
  local half = w*(cfg.guideNearHalf[0]*(1-t) + cfg.guideFarHalf[0]*t)

  -- Steering curvature grows with distance, because the future path diverges farther away.
  local steer = displayedSteering()
  local curve = steer * w * cfg.guideSteerGain[0] * math.pow(t,cfg.guideCurvePower[0])
  local cx = p0.x + w*0.5 + curve
  return im.ImVec2(cx + side*half,y)
end

local function drawCurve(dl,p0,w,h,side,color,thickness)
  local segments = 32
  local prev = guidePoint(p0,w,h,0,side)
  for i=1,segments do
    local t = i/segments
    local cur = guidePoint(p0,w,h,t,side)
    dl:AddLine(prev,cur,color,thickness)
    prev = cur
  end
end

local function drawCrossBar(dl,p0,w,h,t,color,thickness)
  local a = guidePoint(p0,w,h,t,-1)
  local b = guidePoint(p0,w,h,t, 1)
  dl:AddLine(a,b,color,thickness)
end

local function drawGuides(dl,p0,p1)
  local w = p1.x-p0.x
  local h = p1.y-p0.y

  local green = im.GetColorU322(im.ImVec4(0.20,1.00,0.25,0.95))
  local yellow = im.GetColorU322(im.ImVec4(1.00,0.88,0.18,0.95))
  local red = im.GetColorU322(im.ImVec4(1.00,0.20,0.15,0.95))

  drawCurve(dl,p0,w,h,-1,green,3)
  drawCurve(dl,p0,w,h, 1,green,3)

  -- Red is nearest, yellow mid-distance, green farthest.
  drawCrossBar(dl,p0,w,h,0.00,red,3)
  drawCrossBar(dl,p0,w,h,0.42,yellow,3)
  drawCrossBar(dl,p0,w,h,1.00,green,3)
end

local function slider(label,ptr,a,b,fmt)
  im.SetNextItemWidth(280)
  im.SliderFloat(label,ptr,a,b,fmt or '%.2f')
end

local function drawCalibration()
  im.Text('REAR CAMERA + DYNAMIC GUIDE CALIBRATION v1.1.1')
  slider('X Forward##rear',cfg.x,-4.0,1.0,'%.2f m')
  slider('Y Right##rear',cfg.y,-2.0,2.0,'%.2f m')
  slider('Z Height##rear',cfg.z,0.2,2.5,'%.2f m')
  slider('Yaw##rear',cfg.yaw,120,240,'%.1f deg')
  slider('Pitch##rear',cfg.pitch,-60,10,'%.1f deg')
  slider('Roll##rear',cfg.roll,-30,30,'%.1f deg')
  slider('FOV##rear',cfg.fov,70,150,'%.1f deg')

  im.Separator()
  im.Text(string.format('Live steering: %.3f | smoothed: %.3f | displayed: %.3f',steeringRaw,steeringSmooth,displayedSteering()))
  slider('Guide NEAR half-width##rear',cfg.guideNearHalf,0.15,0.48,'%.2f')
  slider('Guide FAR half-width##rear',cfg.guideFarHalf,0.08,0.35,'%.2f')
  slider('Steering curve gain##rear',cfg.guideSteerGain,-0.60,0.60,'%.3f')
  slider('Curve progression##rear',cfg.guideCurvePower,1.0,3.0,'%.2f')
  slider('Steering smoothing##rear',cfg.steeringSmoothing,0.05,0.80,'%.2f')

  if im.Button('RESET REAR CAMERA + GUIDES') then
    cfg.x[0],cfg.y[0],cfg.z[0] = -2.15,0.00,0.88
    cfg.yaw[0],cfg.pitch[0],cfg.roll[0],cfg.fov[0] = 180,-16,0,118
    cfg.guideNearHalf[0],cfg.guideFarHalf[0] = 0.36,0.20
    cfg.guideSteerGain[0],cfg.guideCurvePower[0],cfg.steeringSmoothing[0] = 0.25,1.75,0.22
  end
end

local function drawWindow()
  if not im or not running or (showWindow and not showWindow[0]) then return end

  im.SetNextWindowSize(im.ImVec2(900,650),im.Cond_FirstUseEver)
  local open = im.Begin('Rear Camera##surroundView360',showWindow,bit.bor(im.WindowFlags_NoCollapse,im.WindowFlags_NoScrollbar))

  if open then
    im.Text(string.format('REAR CAMERA v1.1.1 - corrected perspective + mirrored steering | steer %.2f',displayedSteering()))
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
  steeringRaw,steeringSmooth,steeringPollTimer = 0,0,STEERING_POLL_INTERVAL
  if showWindow then showWindow[0] = true end
  emitStatus('live','REAR CAMERA + CORRECTED DYNAMIC GUIDES LIVE v1.1.1')
  return true
end

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
    requestSteeringFromVehicle(dt or 0)
    local response = clamp(cfg.steeringSmoothing[0],0.01,1)
    steeringSmooth = steeringSmooth + (steeringRaw-steeringSmooth)*response

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