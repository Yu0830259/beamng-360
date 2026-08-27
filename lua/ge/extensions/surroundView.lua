local M = {}

-- v0.6.0: four persistent GPU RenderViews + live surround preview.
local im = extensions.ui_imgui or ui_imgui
local imUtils = require('ui/imguiUtils')

local WIDTH = 512
local HEIGHT = 288
local FOV = math.rad(105)
local NEAR_CLIP = 0.05
local FAR_CLIP = 500

local cameras = {
  front = {view='svFrontView', tex='svFrontTex', label='FRONT'},
  rear  = {view='svRearView',  tex='svRearTex',  label='REAR'},
  left  = {view='svLeftView',  tex='svLeftTex',  label='LEFT'},
  right = {view='svRightView', tex='svRightTex', label='RIGHT'}
}

local running = false
local showWindow = im and im.BoolPtr and im.BoolPtr(true) or nil
local resolution = Point2I(WIDTH, HEIGHT)
local viewport = RectI(0, 0, WIDTH, HEIGHT)
local frustum = Frustum.construct(false, FOV, WIDTH / HEIGHT, NEAR_CLIP, FAR_CLIP)
local uvNormal0 = im and im.ImVec2(0, 0) or nil
local uvNormal1 = im and im.ImVec2(1, 1) or nil
local uvMirror0 = im and im.ImVec2(1, 0) or nil
local uvMirror1 = im and im.ImVec2(0, 1) or nil

for _, cam in pairs(cameras) do
  cam.matrix = MatrixF(true)
  cam.quat = QuatF(0, 0, 0, 1)
  cam.renderView = nil
end

local function emitStatus(state, message)
  if guihooks and guihooks.trigger then
    guihooks.trigger('SurroundViewStatus', {
      state = state,
      message = message or state or 'UNKNOWN',
      mode = 'four-camera-gpu-renderview',
      version = '0.6.0'
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
  local pos = veh:getPosition()
  local dir = veh:getDirectionVector()
  local up = veh:getDirectionVectorUp()
  if not pos or not dir or not up then return nil end

  dir = safeNormalized(dir)
  up = safeNormalized(up)

  -- BeamNG vehicle local basis. Try cross products in a guarded way.
  local right
  local ok = pcall(function() right = dir:cross(up) end)
  if not ok or not right then
    right = vec3(-dir.y, dir.x, 0)
  end
  right = safeNormalized(right)

  return pos, dir, up, right
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
    -- Positions are intentionally a little outside the body to avoid clipping.
    setCameraTransform(cameras.front,
      pos + dir * 2.15 + up * 0.72,
      dir - up * 0.22,
      up)

    setCameraTransform(cameras.rear,
      pos - dir * 2.15 + up * 0.78,
      -dir - up * 0.20,
      up)

    setCameraTransform(cameras.left,
      pos - right * 1.15 + up * 0.78,
      -right - up * 0.28,
      up)

    setCameraTransform(cameras.right,
      pos + right * 1.15 + up * 0.78,
      right - up * 0.28,
      up)
  end)

  if not ok then return false, 'camera transform failed: ' .. tostring(err) end
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

  if not ok then return false, 'RenderView setup failed: ' .. tostring(err) end
  return true
end

local function tex(cam)
  local obj = imUtils.texObj('#' .. cam.tex)
  return obj and obj.texId or nil
end

local function image(cam, size, mirror)
  local id = tex(cam)
  if not id then
    im.Dummy(size)
    return false
  end
  if mirror then
    im.Image(id, size, uvMirror0, uvMirror1)
  else
    im.Image(id, size, uvNormal0, uvNormal1)
  end
  return true
end

local function drawCameraTile(cam, w, h, mirror)
  im.BeginGroup()
  im.Text(cam.label)
  image(cam, im.ImVec2(w, h), mirror)
  im.EndGroup()
end

local function drawSurroundComposite()
  -- Pseudo bird's-eye layout: cropped live camera textures surround a vehicle block.
  -- This is GPU-live and stable; true lens calibration/warping can be layered on next.
  local avail = im.GetContentRegionAvail()
  local totalW = math.min(avail.x, 760)
  local totalH = math.min(avail.y, 620)
  local sideW = totalW * 0.23
  local centerW = totalW - sideW * 2
  local topH = totalH * 0.24
  local midH = totalH - topH * 2

  local frontId = tex(cameras.front)
  local rearId = tex(cameras.rear)
  local leftId = tex(cameras.left)
  local rightId = tex(cameras.right)

  local dl = im.GetWindowDrawList()
  local p = im.GetCursorScreenPos()

  -- Front strip: use lower part of the front camera to emphasize ground near bumper.
  if frontId then
    im.Image(frontId, im.ImVec2(centerW, topH), im.ImVec2(0.05, 0.43), im.ImVec2(0.95, 1.00))
  else im.Dummy(im.ImVec2(centerW, topH)) end

  -- Middle row begins aligned under front strip, with side feeds around vehicle block.
  local midY = p.y + topH
  local leftX = p.x - sideW
  local centerX = p.x
  local rightX = p.x + centerW

  if leftId then
    dl:AddImage(leftId, im.ImVec2(leftX, midY), im.ImVec2(centerX, midY + midH), im.ImVec2(0.10, 0.15), im.ImVec2(0.95, 0.95))
  end
  if rightId then
    dl:AddImage(rightId, im.ImVec2(rightX, midY), im.ImVec2(rightX + sideW, midY + midH), im.ImVec2(0.90, 0.15), im.ImVec2(0.05, 0.95))
  end

  -- Central vehicle placeholder, intentionally opaque like OEM surround-view systems.
  local c0 = im.ImVec2(centerX, midY)
  local c1 = im.ImVec2(centerX + centerW, midY + midH)
  dl:AddRectFilled(c0, c1, im.GetColorU322(im.ImVec4(0.07, 0.09, 0.11, 1)), 12)
  local carMarginX = centerW * 0.33
  local carMarginY = midH * 0.12
  local car0 = im.ImVec2(centerX + carMarginX, midY + carMarginY)
  local car1 = im.ImVec2(centerX + centerW - carMarginX, midY + midH - carMarginY)
  dl:AddRectFilled(car0, car1, im.GetColorU322(im.ImVec4(0.78, 0.82, 0.86, 1)), 22)
  dl:AddRect(car0, car1, im.GetColorU322(im.ImVec4(0.95, 0.97, 1.00, 1)), 22, 0, 2)

  -- Rear strip below the middle row.
  local rearY = midY + midH
  if rearId then
    dl:AddImage(rearId, im.ImVec2(centerX, rearY), im.ImVec2(centerX + centerW, rearY + topH), im.ImVec2(0.95, 0.43), im.ImVec2(0.05, 1.00))
  end

  -- Seam / parking outline.
  local outline = im.GetColorU322(im.ImVec4(0.18, 0.55, 1.00, 0.90))
  dl:AddRect(im.ImVec2(leftX, p.y), im.ImVec2(rightX + sideW, rearY + topH), outline, 28, 0, 2)

  -- Reserve the full drawn area in ImGui layout.
  im.SetCursorScreenPos(im.ImVec2(leftX, p.y))
  im.Dummy(im.ImVec2(totalW, totalH))
end

local function drawLiveWindow()
  if not im or not running then return end
  if showWindow and not showWindow[0] then return end

  im.SetNextWindowSize(im.ImVec2(980, 780), im.Cond_FirstUseEver)
  local flags = bit.bor(im.WindowFlags_NoCollapse, im.WindowFlags_NoScrollbar)
  local visible = im.Begin('Surround View - 360 Camera##surroundView360', showWindow, flags)

  if visible then
    im.Text('4x GPU RenderView / live surround prototype v0.6.0')
    im.Separator()

    if im.BeginTabBar('svTabs') then
      if im.BeginTabItem('360 VIEW') then
        im.Text('Pseudo bird\'s-eye composite - live 4 camera feeds')
        drawSurroundComposite()
        im.EndTabItem()
      end

      if im.BeginTabItem('4 CAMERAS') then
        local aw = im.GetContentRegionAvail().x
        local tileW = math.max(220, (aw - 16) * 0.5)
        local tileH = tileW * HEIGHT / WIDTH
        drawCameraTile(cameras.front, tileW, tileH, false)
        im.SameLine()
        drawCameraTile(cameras.rear, tileW, tileH, true)
        drawCameraTile(cameras.left, tileW, tileH, false)
        im.SameLine()
        drawCameraTile(cameras.right, tileW, tileH, true)
        im.EndTabItem()
      end
      im.EndTabBar()
    end
  end

  im.End()
end

function M.startSurroundView()
  running = false
  local ok, err = createViews()
  if not ok then
    emitStatus('error', '360 init failed: ' .. tostring(err))
    return false
  end

  local cameraOk, cameraErr = updateCameraMatrices()
  if not cameraOk then
    emitStatus('error', '360 camera failed: ' .. tostring(cameraErr))
    return false
  end

  running = true
  if showWindow then showWindow[0] = true end
  emitStatus('live', '4 CAMERA SURROUND LIVE v0.6.0')
  return true
end

-- Backward-compatible entry point used by older app.js versions.
function M.startRearCamera()
  return M.startSurroundView()
end

function M.stopSurroundView()
  running = false
  emitStatus('stopped', 'Surround View stopped')
end

function M.stopRearCamera()
  return M.stopSurroundView()
end

function M.onInit()
  if setExtensionUnloadMode then setExtensionUnloadMode(M, 'manual') end
end

function M.onPreRender(dt)
  if not running then return end
  local ok, err = updateCameraMatrices()
  if not ok then
    running = false
    emitStatus('error', '360 update failed: ' .. tostring(err))
  end
end

function M.onUpdate(dtReal, dtSim, dtRaw)
  drawLiveWindow()
end

function M.onExtensionUnloaded()
  running = false
  if RenderViewManagerInstance and RenderViewManagerInstance.destroyView then
    for _, cam in pairs(cameras) do
      if cam.renderView then
        pcall(function() RenderViewManagerInstance:destroyView(cam.renderView) end)
      end
      cam.renderView = nil
    end
  end
end

return M
