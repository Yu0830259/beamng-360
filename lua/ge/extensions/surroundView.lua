local M = {}

-- v0.7.1: four persistent GPU RenderViews + calibrated bird's-eye mesh.
local im = extensions.ui_imgui or ui_imgui
local imUtils = require('ui/imguiUtils')

local WIDTH, HEIGHT = 512, 288
local FOV = math.rad(118)
local NEAR_CLIP, FAR_CLIP = 0.05, 500
local GRID = 8

local cameras = {
  front = {view='svFrontView', tex='svFrontTex', label='FRONT'},
  rear  = {view='svRearView',  tex='svRearTex',  label='REAR'},
  left  = {view='svLeftView',  tex='svLeftTex',  label='LEFT'},
  right = {view='svRightView', tex='svRightTex', label='RIGHT'}
}

local calibration = {
  front = {k1=-0.22,k2=0.055,flipU=false,flipV=false,crop={u0=0.05,v0=0.36,u1=0.95,v1=0.99},quad={{0.30,0.00},{0.70,0.00},{0.62,0.40},{0.38,0.40}}},
  rear  = {k1=-0.22,k2=0.055,flipU=true, flipV=false,crop={u0=0.05,v0=0.36,u1=0.95,v1=0.99},quad={{0.38,0.60},{0.62,0.60},{0.70,1.00},{0.30,1.00}}},
  left  = {k1=-0.25,k2=0.070,flipU=false,flipV=false,crop={u0=0.04,v0=0.24,u1=0.96,v1=0.99},quad={{0.00,0.20},{0.38,0.40},{0.38,0.60},{0.00,0.80}}},
  right = {k1=-0.25,k2=0.070,flipU=true, flipV=false,crop={u0=0.04,v0=0.24,u1=0.96,v1=0.99},quad={{0.62,0.40},{1.00,0.20},{1.00,0.80},{0.62,0.60}}}
}

local running = false
local showWindow = im and im.BoolPtr and im.BoolPtr(true) or nil
local resolution = Point2I(WIDTH, HEIGHT)
local viewport = RectI(0, 0, WIDTH, HEIGHT)
local frustum = Frustum.construct(false, FOV, WIDTH / HEIGHT, NEAR_CLIP, FAR_CLIP)
local uvNormal0 = im and im.ImVec2(0,0) or nil
local uvNormal1 = im and im.ImVec2(1,1) or nil
local uvMirror0 = im and im.ImVec2(1,0) or nil
local uvMirror1 = im and im.ImVec2(0,1) or nil

for _, cam in pairs(cameras) do
  cam.matrix = MatrixF(true)
  cam.quat = QuatF(0,0,0,1)
  cam.renderView = nil
end

local function emitStatus(state, message)
  if guihooks and guihooks.trigger then
    guihooks.trigger('SurroundViewStatus', {
      state = state,
      message = message or state or 'UNKNOWN',
      mode = 'calibrated-four-camera-renderview',
      version = '0.7.1'
    })
  end
end

local function getPlayerVehicleSafe()
  if be and be.getPlayerVehicle then
    local ok, veh = pcall(function() return be:getPlayerVehicle(0) end)
    if ok and veh then return veh end
  end
  if getPlayerVehicle then
    local ok, veh = pcall(function() return getPlayerVehicle(0) end)
    if ok and veh then return veh end
  end
  return nil
end

local function safeNormalized(v)
  local ok, out = pcall(function() return v:normalized() end)
  if ok and out then return out end
  pcall(function() v:normalize() end)
  return v
end

local function getBasis(veh)
  local pos, dir, up = veh:getPosition(), veh:getDirectionVector(), veh:getDirectionVectorUp()
  if not pos or not dir or not up then return nil end
  dir, up = safeNormalized(dir), safeNormalized(up)
  local right
  local ok = pcall(function() right = dir:cross(up) end)
  if not ok or not right then right = vec3(-dir.y, dir.x, 0) end
  return pos, dir, up, safeNormalized(right)
end

local function setCameraTransform(cam, cameraPos, lookDir, up)
  local q = quatFromDir(safeNormalized(lookDir), up)
  cam.quat.x, cam.quat.y, cam.quat.z, cam.quat.w = q.x, q.y, q.z, q.w
  cam.matrix:setFromQuatF(cam.quat)
  cam.matrix:setPosition(cameraPos)
  cam.renderView.cameraMatrix = cam.matrix
end

local function updateCameraMatrices()
  local veh = getPlayerVehicleSafe()
  if not veh then return false, 'No player vehicle found' end
  local pos, dir, up, right = getBasis(veh)
  if not pos then return false, 'Vehicle transform unavailable' end
  local ok, err = pcall(function()
    setCameraTransform(cameras.front, pos + dir*2.20 + up*0.70,  dir - up*0.32, up)
    setCameraTransform(cameras.rear,  pos - dir*2.20 + up*0.76, -dir - up*0.30, up)
    setCameraTransform(cameras.left,  pos - right*1.18 + up*0.76, -right - up*0.34, up)
    setCameraTransform(cameras.right, pos + right*1.18 + up*0.76,  right - up*0.34, up)
  end)
  if not ok then return false, 'camera transform failed: '..tostring(err) end
  return true
end

local function createViews()
  if not RenderViewManagerInstance or not RenderViewManagerInstance.getOrCreateView then
    return false, 'RenderViewManagerInstance unavailable'
  end
  local ok, err = pcall(function()
    for _, cam in pairs(cameras) do
      cam.renderView = RenderViewManagerInstance:getOrCreateView(cam.view)
      cam.renderView.renderCubemap = false
      cam.renderView.cameraMatrix = cam.matrix
      cam.renderView.resolution = resolution
      cam.renderView.viewPort = viewport
      cam.renderView.namedTexTargetColor = cam.tex
      cam.renderView.frustum = frustum
    end
  end)
  if not ok then return false, 'RenderView setup failed: '..tostring(err) end
  return true
end

local function tex(cam)
  local obj = imUtils.texObj('#'..cam.tex)
  return obj and obj.texId or nil
end

local function image(cam, size, mirror)
  local id = tex(cam)
  if not id then im.Dummy(size); return false end
  im.Image(id, size, mirror and uvMirror0 or uvNormal0, mirror and uvMirror1 or uvNormal1)
  return true
end

local function drawCameraTile(cam, w, h, mirror)
  im.BeginGroup()
  im.Text(cam.label)
  image(cam, im.ImVec2(w,h), mirror)
  im.EndGroup()
end

local function lensUV(cal,u,v)
  if cal.flipU then u = 1-u end
  if cal.flipV then v = 1-v end
  local c = cal.crop
  u = c.u0 + (c.u1-c.u0)*u
  v = c.v0 + (c.v1-c.v0)*v
  local x, y = (u-0.5)*2, (v-0.5)*2
  local r2 = x*x + y*y
  local radial = 1 + cal.k1*r2 + cal.k2*r2*r2
  return math.max(0,math.min(1,0.5+x*radial*0.5)), math.max(0,math.min(1,0.5+y*radial*0.5))
end

local function projectQuad(cal,u,v,origin,w,h)
  local q = cal.quad
  local xTop = q[1][1]*(1-u)+q[2][1]*u
  local yTop = q[1][2]*(1-u)+q[2][2]*u
  local xBot = q[4][1]*(1-u)+q[3][1]*u
  local yBot = q[4][2]*(1-u)+q[3][2]*u
  return im.ImVec2(origin.x+(xTop*(1-v)+xBot*v)*w, origin.y+(yTop*(1-v)+yBot*v)*h)
end

local function drawWarpedCamera(dl, cam, cal, origin, w, h)
  local id = tex(cam)
  if not id then return end
  for gy=0,GRID-1 do
    local v0, v1 = gy/GRID, (gy+1)/GRID
    for gx=0,GRID-1 do
      local u0, u1 = gx/GRID, (gx+1)/GRID
      local p1 = projectQuad(cal,u0,v0,origin,w,h)
      local p2 = projectQuad(cal,u1,v0,origin,w,h)
      local p3 = projectQuad(cal,u1,v1,origin,w,h)
      local p4 = projectQuad(cal,u0,v1,origin,w,h)
      local a1,b1 = lensUV(cal,u0,v0)
      local a2,b2 = lensUV(cal,u1,v0)
      local a3,b3 = lensUV(cal,u1,v1)
      local a4,b4 = lensUV(cal,u0,v1)
      local ok = pcall(function()
        dl:AddImageQuad(id,p1,p2,p3,p4,im.ImVec2(a1,b1),im.ImVec2(a2,b2),im.ImVec2(a3,b3),im.ImVec2(a4,b4))
      end)
      if not ok then return end
    end
  end
end

local function drawSurroundComposite()
  local avail = im.GetContentRegionAvail()
  local size = math.max(280, math.min(avail.x, avail.y, 700))
  local w, h = size*0.72, size
  local p = im.GetCursorScreenPos()
  local origin = im.ImVec2(p.x+math.max(0,(avail.x-w)*0.5), p.y)
  local dl = im.GetWindowDrawList()

  local bg = im.GetColorU322(im.ImVec4(0.035,0.045,0.055,1))
  dl:AddRectFilled(origin, im.ImVec2(origin.x+w,origin.y+h), bg, 22, 0)

  drawWarpedCamera(dl,cameras.front,calibration.front,origin,w,h)
  drawWarpedCamera(dl,cameras.rear, calibration.rear, origin,w,h)
  drawWarpedCamera(dl,cameras.left, calibration.left, origin,w,h)
  drawWarpedCamera(dl,cameras.right,calibration.right,origin,w,h)

  local carW, carH = w*0.24, h*0.42
  local cx, cy = origin.x+w*0.5, origin.y+h*0.5
  local car0 = im.ImVec2(cx-carW*0.5, cy-carH*0.5)
  local car1 = im.ImVec2(cx+carW*0.5, cy+carH*0.5)
  dl:AddRectFilled(car0,car1,im.GetColorU322(im.ImVec4(0.12,0.15,0.18,1)),carW*0.30,0)
  dl:AddRect(car0,car1,im.GetColorU322(im.ImVec4(0.78,0.86,0.94,1)),carW*0.30,0,2)
  local glass0 = im.ImVec2(cx-carW*0.31,cy-carH*0.28)
  local glass1 = im.ImVec2(cx+carW*0.31,cy+carH*0.22)
  dl:AddRectFilled(glass0,glass1,im.GetColorU322(im.ImVec4(0.08,0.13,0.17,1)),carW*0.18,0)
  dl:AddRect(origin,im.ImVec2(origin.x+w,origin.y+h),im.GetColorU322(im.ImVec4(0.12,0.55,1,0.95)),22,0,2)

  im.SetCursorScreenPos(origin)
  im.Dummy(im.ImVec2(w,h))
end

local function drawCalibrationPanel()
  im.Text('Calibration: radial distortion + projected mesh')
  im.Separator()
  for name,cal in pairs(calibration) do
    im.Text(string.format('%s  k1 %.3f  k2 %.3f',string.upper(name),cal.k1,cal.k2))
  end
end

local function drawLiveWindow()
  if not im or not running then return end
  if showWindow and not showWindow[0] then return end
  im.SetNextWindowSize(im.ImVec2(980,820),im.Cond_FirstUseEver)
  local flags = bit.bor(im.WindowFlags_NoCollapse,im.WindowFlags_NoScrollbar)
  local visible = im.Begin('Surround View - Calibrated 360 Camera##surroundView360',showWindow,flags)
  if visible then
    im.Text('4x GPU cameras / lens calibration / bird\'s-eye projection v0.7.1')
    im.Separator()
    if im.BeginTabBar('svTabs') then
      if im.BeginTabItem('360 VIEW') then
        im.Text('Calibrated live bird\'s-eye composite')
        local ok,err = pcall(drawSurroundComposite)
        if not ok then
          im.TextColored(im.ImVec4(1,0.35,0.35,1),'360 draw error: '..tostring(err))
          emitStatus('error','360 draw error: '..tostring(err))
        end
        im.EndTabItem()
      end
      if im.BeginTabItem('4 CAMERAS') then
        local aw = im.GetContentRegionAvail().x
        local tileW = math.max(220,(aw-16)*0.5)
        local tileH = tileW*HEIGHT/WIDTH
        drawCameraTile(cameras.front,tileW,tileH,false); im.SameLine(); drawCameraTile(cameras.rear,tileW,tileH,true)
        drawCameraTile(cameras.left,tileW,tileH,false);  im.SameLine(); drawCameraTile(cameras.right,tileW,tileH,true)
        im.EndTabItem()
      end
      if im.BeginTabItem('CALIBRATION') then
        drawCalibrationPanel()
        im.EndTabItem()
      end
      im.EndTabBar()
    end
  end
  im.End()
end

function M.startSurroundView()
  running = false
  local ok,err = createViews()
  if not ok then emitStatus('error','360 init failed: '..tostring(err)); return false end
  local cameraOk,cameraErr = updateCameraMatrices()
  if not cameraOk then emitStatus('error','360 camera failed: '..tostring(cameraErr)); return false end
  running = true
  if showWindow then showWindow[0] = true end
  emitStatus('live','CALIBRATED 4 CAMERA SURROUND LIVE v0.7.1')
  return true
end

function M.startRearCamera() return M.startSurroundView() end
function M.stopSurroundView() running=false; emitStatus('stopped','Surround View stopped') end
function M.stopRearCamera() return M.stopSurroundView() end
function M.onInit() if setExtensionUnloadMode then setExtensionUnloadMode(M,'manual') end end
function M.onPreRender(dt)
  if not running then return end
  local ok,err = updateCameraMatrices()
  if not ok then running=false; emitStatus('error','360 update failed: '..tostring(err)) end
end
function M.onUpdate(dtReal,dtSim,dtRaw) drawLiveWindow() end
function M.onExtensionUnloaded()
  running = false
  if RenderViewManagerInstance and RenderViewManagerInstance.destroyView then
    for _,cam in pairs(cameras) do
      if cam.renderView then pcall(function() RenderViewManagerInstance:destroyView(cam.renderView) end) end
      cam.renderView = nil
    end
  end
end

return M