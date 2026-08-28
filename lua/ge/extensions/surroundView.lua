local M = {}

-- v1.2.0 REAR CAMERA - OEM STYLE
-- Narrower/more natural rear-camera view plus yellow trajectory rails and a curved red near-limit bar.
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
  -- Camera is mounted near the rear bumper and looks slightly downward.
  x = fp(-2.20),
  y = fp(0.00),
  z = fp(0.78),
  yaw = fp(180.0),
  pitch = fp(-11.0),
  roll = fp(0.0),

  -- Lower than the old 118deg view: less fisheye / more OEM-looking zoom.
  fov = fp(92.0),

  -- Yellow rail geometry in screen-space perspective.
  guideNearHalf = fp(0.32),
  guideFarHalf = fp(0.135),
  guideSteerGain = fp(0.22),
  guideCurvePower = fp(1.65),
  steeringSmoothing = fp(0.20),
  guideThickness = fp(2.5),

  -- Vertical placement of the guide area.
  guideNearY = fp(0.88),
  guideFarY = fp(0.47),
  redBow = fp(0.018)
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
      mode='rear-camera-oem-guides',
      version='1.2.0'
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
  local p,d,u = v:getPosition(),v:getDirectionVector(),v:getDirectionVectorUp()
  if not p or not d or not u then return nil end
  d,u = norm(d),norm(u)
  local r
  local ok = pcall(function() r=d:cross(u) end)
  if not ok or not r then r=vec3(-d.y,d.x,0) end
  return p,d,u,norm(r)
end

local function localCameraBasis()
  local yaw = math.rad(cfg.yaw[0])
  local pitch = math.rad(cfg.pitch[0])
  local cp = math.cos(pitch)
  local f = {x=cp*math.cos(yaw),y=cp*math.sin(yaw),z=math.sin(pitch)}
  local fl = math.sqrt(f.x*f.x+f.y*f.y+f.z*f.z)
  f.x,f.y,f.z=f.x/fl,f.y/fl,f.z/fl

  local rr={x=-f.y,y=f.x,z=0}
  local rl=math.sqrt(rr.x*rr.x+rr.y*rr.y)
  if rl<1e-6 then rr={x=0,y=1,z=0} else rr.x,rr.y=rr.x/rl,rr.y/rl end

  local up={x=-f.z*rr.y,y=f.z*rr.x,z=f.x*rr.y-f.y*rr.x}
  local ul=math.sqrt(up.x*up.x+up.y*up.y+up.z*up.z)
  up.x,up.y,up.z=up.x/ul,up.y/ul,up.z/ul

  local roll=math.rad(cfg.roll[0])
  local c,s=math.cos(roll),math.sin(roll)
  local rr2={x=rr.x*c+up.x*s,y=rr.y*c+up.y*s,z=rr.z*c+up.z*s}
  local up2={x=up.x*c-rr.x*s,y=up.y*c-rr.y*s,z=up.z*c-rr.z*s}
  return f,rr2,up2
end

local function toWorld(d,r,u,v)
  return d*v.x+r*v.y+u*v.z
end

local function updateCamera()
  local veh=getVehicle()
  if not veh then return false,'No player vehicle found' end
  local p,d,u,r=vehicleBasis(veh)
  if not p then return false,'Vehicle transform unavailable' end

  local ok,err=pcall(function()
    local lf,_,lu=localCameraBasis()
    local pos=p+d*cfg.x[0]+r*cfg.y[0]+u*cfg.z[0]
    local dir=toWorld(d,r,u,lf)
    local up=toWorld(d,r,u,lu)
    local q=quatFromDir(norm(dir),norm(up))
    rear.quat.x,rear.quat.y,rear.quat.z,rear.quat.w=q.x,q.y,q.z,q.w
    rear.matrix:setFromQuatF(rear.quat)
    rear.matrix:setPosition(pos)
    rear.renderView.cameraMatrix=rear.matrix
    rear.renderView.frustum=Frustum.construct(false,math.rad(cfg.fov[0]),ASPECT,NEAR_CLIP,FAR_CLIP)
  end)

  if not ok then return false,'Rear camera transform failed: '..tostring(err) end
  return true
end

local function createView()
  if not RenderViewManagerInstance or not RenderViewManagerInstance.getOrCreateView then
    return false,'RenderViewManagerInstance unavailable'
  end

  local ok,err=pcall(function()
    rear.renderView=RenderViewManagerInstance:getOrCreateView(rear.view)
    rear.renderView.renderCubemap=false
    rear.renderView.cameraMatrix=rear.matrix
    rear.renderView.resolution=resolution
    rear.renderView.viewPort=viewport
    rear.renderView.namedTexTargetColor=rear.tex
    rear.renderView.frustum=Frustum.construct(false,math.rad(cfg.fov[0]),ASPECT,NEAR_CLIP,FAR_CLIP)
  end)

  if not ok then return false,'Rear RenderView setup failed: '..tostring(err) end
  return true
end

local function textureId()
  local o=imUtils.texObj('#'..rear.tex)
  return o and o.texId or nil
end

function M.setSteeringValue(value)
  steeringRaw=clamp(tonumber(value) or 0,-1,1)
end

local function requestSteeringFromVehicle(dt)
  steeringPollTimer=steeringPollTimer+(dt or 0)
  if steeringPollTimer<STEERING_POLL_INTERVAL then return end
  steeringPollTimer=steeringPollTimer-STEERING_POLL_INTERVAL

  local veh=getVehicle()
  if not veh or not veh.queueLuaCommand then return end

  local cmd=[[
    local s=0
    if electrics and electrics.values then
      s=electrics.values.steering_input or electrics.values.steering or 0
    end
    if (not s or s==0) and input then s=input.steering or 0 end
    obj:queueGameEngineLua('extensions.surroundView.setSteeringValue('..tostring(s or 0)..')')
  ]]
  pcall(function() veh:queueLuaCommand(cmd) end)
end

local function displayedSteering()
  -- Preserve the direction that already matched the user's vehicle.
  return steeringSmooth
end

local function guidePoint(p0,w,h,t,side)
  -- t=0: near bumper. t=1: far away.
  local nearY=p0.y+h*cfg.guideNearY[0]
  local farY =p0.y+h*cfg.guideFarY[0]
  local y=nearY+(farY-nearY)*t

  -- Near is wider, far is narrower, matching perspective.
  local half=w*(cfg.guideNearHalf[0]*(1-t)+cfg.guideFarHalf[0]*t)

  -- Dynamic reverse trajectory.
  local curve=displayedSteering()*w*cfg.guideSteerGain[0]*math.pow(t,cfg.guideCurvePower[0])
  local cx=p0.x+w*0.5+curve
  return im.ImVec2(cx+side*half,y)
end

local function drawRail(dl,p0,w,h,side,color,thickness)
  local segments=36
  local prev=guidePoint(p0,w,h,0,side)
  for i=1,segments do
    local cur=guidePoint(p0,w,h,i/segments,side)
    dl:AddLine(prev,cur,color,thickness)
    prev=cur
  end
end

local function drawCurvedRedBar(dl,p0,w,h,color,thickness)
  local left=guidePoint(p0,w,h,0,-1)
  local right=guidePoint(p0,w,h,0,1)
  local segments=28
  local prev=left
  for i=1,segments do
    local t=i/segments
    local x=left.x+(right.x-left.x)*t
    -- Slight downward bow in the middle, like many OEM rear-camera limit markers.
    local bow=math.sin(math.pi*t)*h*cfg.redBow[0]
    local y=left.y+bow
    local cur=im.ImVec2(x,y)
    dl:AddLine(prev,cur,color,thickness)
    prev=cur
  end
end

local function drawGuides(dl,p0,p1)
  local w,h=p1.x-p0.x,p1.y-p0.y
  local yellow=im.GetColorU322(im.ImVec4(1.00,0.78,0.02,0.98))
  local red=im.GetColorU322(im.ImVec4(0.95,0.10,0.08,0.98))
  local thickness=cfg.guideThickness[0]

  -- OEM-style design: yellow rails + one red near-limit bar.
  drawRail(dl,p0,w,h,-1,yellow,thickness)
  drawRail(dl,p0,w,h, 1,yellow,thickness)
  drawCurvedRedBar(dl,p0,w,h,red,thickness+0.4)
end

local function slider(label,ptr,a,b,fmt)
  im.SetNextItemWidth(280)
  im.SliderFloat(label,ptr,a,b,fmt or '%.2f')
end

local function drawCalibration()
  im.Text('REAR CAMERA OEM-STYLE CALIBRATION v1.2.0')
  slider('X Forward##rear',cfg.x,-4.0,1.0,'%.2f m')
  slider('Y Right##rear',cfg.y,-2.0,2.0,'%.2f m')
  slider('Z Height##rear',cfg.z,0.2,2.5,'%.2f m')
  slider('Yaw##rear',cfg.yaw,120,240,'%.1f deg')
  slider('Pitch##rear',cfg.pitch,-60,10,'%.1f deg')
  slider('Roll##rear',cfg.roll,-30,30,'%.1f deg')
  slider('Camera zoom / FOV##rear',cfg.fov,60,130,'%.1f deg')

  im.Separator()
  im.Text(string.format('Live steering: %.3f | displayed: %.3f',steeringRaw,displayedSteering()))
  slider('Guide NEAR half-width##rear',cfg.guideNearHalf,0.15,0.45,'%.3f')
  slider('Guide FAR half-width##rear',cfg.guideFarHalf,0.06,0.30,'%.3f')
  slider('Guide near vertical##rear',cfg.guideNearY,0.68,0.96,'%.3f')
  slider('Guide far vertical##rear',cfg.guideFarY,0.30,0.65,'%.3f')
  slider('Steering curve gain##rear',cfg.guideSteerGain,-0.60,0.60,'%.3f')
  slider('Curve progression##rear',cfg.guideCurvePower,1.0,3.0,'%.2f')
  slider('Steering smoothing##rear',cfg.steeringSmoothing,0.05,0.80,'%.2f')
  slider('Line thickness##rear',cfg.guideThickness,1.0,6.0,'%.1f px')
  slider('Red bar bow##rear',cfg.redBow,0.0,0.05,'%.3f')

  if im.Button('RESET OEM CAMERA + GUIDES') then
    cfg.x[0],cfg.y[0],cfg.z[0]=-2.20,0.00,0.78
    cfg.yaw[0],cfg.pitch[0],cfg.roll[0],cfg.fov[0]=180,-11,0,92
    cfg.guideNearHalf[0],cfg.guideFarHalf[0]=0.32,0.135
    cfg.guideSteerGain[0],cfg.guideCurvePower[0],cfg.steeringSmoothing[0]=0.22,1.65,0.20
    cfg.guideThickness[0],cfg.guideNearY[0],cfg.guideFarY[0],cfg.redBow[0]=2.5,0.88,0.47,0.018
  end
end

local function drawWindow()
  if not im or not running or (showWindow and not showWindow[0]) then return end

  im.SetNextWindowSize(im.ImVec2(900,650),im.Cond_FirstUseEver)
  local open=im.Begin('Rear Camera##surroundView360',showWindow,bit.bor(im.WindowFlags_NoCollapse,im.WindowFlags_NoScrollbar))
  if open then
    im.Text(string.format('REAR CAMERA v1.2.0 - OEM view / dynamic yellow rails | steer %.2f',displayedSteering()))
    im.Separator()

    if im.BeginTabBar('rearTabs') then
      if im.BeginTabItem('CAMERA') then
        local avail=im.GetContentRegionAvail()
        local drawW=math.min(avail.x,860)
        local drawH=drawW/ASPECT
        local p0=im.GetCursorScreenPos()
        local id=textureId()
        if id then
          im.Image(id,im.ImVec2(drawW,drawH),uvMirror0,uvMirror1)
          drawGuides(im.GetWindowDrawList(),p0,im.ImVec2(p0.x+drawW,p0.y+drawH))
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
  running=false
  local ok,err=createView(); if not ok then emitStatus('error',err); return false end
  local cok,cerr=updateCamera(); if not cok then emitStatus('error',cerr); return false end
  running=true
  steeringRaw,steeringSmooth,steeringPollTimer=0,0,STEERING_POLL_INTERVAL
  if showWindow then showWindow[0]=true end
  emitStatus('live','REAR CAMERA OEM STYLE LIVE v1.2.0')
  return true
end

function M.startSurroundView() return M.startRearCamera() end
function M.stopRearCamera() running=false; emitStatus('stopped','Rear camera stopped') end
function M.stopSurroundView() return M.stopRearCamera() end
function M.onInit() if setExtensionUnloadMode then setExtensionUnloadMode(M,'manual') end end

function M.onPreRender(dt)
  if running then
    requestSteeringFromVehicle(dt or 0)
    local response=clamp(cfg.steeringSmoothing[0],0.01,1)
    steeringSmooth=steeringSmooth+(steeringRaw-steeringSmooth)*response
    local ok,err=updateCamera()
    if not ok then running=false; emitStatus('error',err) end
  end
end

function M.onUpdate(dtReal,dtSim,dtRaw) drawWindow() end

function M.onExtensionUnloaded()
  running=false
  if rear.renderView and RenderViewManagerInstance and RenderViewManagerInstance.destroyView then
    pcall(function() RenderViewManagerInstance:destroyView(rear.renderView) end)
  end
  rear.renderView=nil
end

return M