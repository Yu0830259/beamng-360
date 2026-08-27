local M = {}

-- v0.5.3: persistent offscreen RenderView, based on working BeamNG mirror code.
local im = extensions.ui_imgui or ui_imgui
local imUtils = require('ui/imguiUtils')

local VIEW_NAME = 'surroundViewRearLive'
local TEXTURE_NAME = 'surroundViewRearTexture'
local WIDTH = 640
local HEIGHT = 360
local FOV = math.rad(78)
local NEAR_CLIP = 0.08
local FAR_CLIP = 800

local running = false
local renderView = nil
local showWindow = im and im.BoolPtr and im.BoolPtr(true) or nil
local cameraMatrix = MatrixF(true)
local tempQuat = QuatF(0, 0, 0, 1)
local resolution = Point2I(WIDTH, HEIGHT)
local viewport = RectI(0, 0, WIDTH, HEIGHT)
local frustum = Frustum.construct(false, FOV, WIDTH / HEIGHT, NEAR_CLIP, FAR_CLIP)

-- RenderView textures do not need vertical inversion here. Match the proven
-- BeamNG mirror implementation: horizontal mirror only, upright image.
local uv0 = im and im.ImVec2(1, 0) or nil
local uv1 = im and im.ImVec2(0, 1) or nil

local function emitStatus(state, message)
  if guihooks and guihooks.trigger then
    guihooks.trigger('SurroundViewStatus', {
      state = state,
      message = message or state or 'UNKNOWN',
      mode = 'persistent-renderview',
      viewName = VIEW_NAME,
      textureName = TEXTURE_NAME,
      width = WIDTH,
      height = HEIGHT
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

local function updateCameraMatrix()
  if not renderView then return false, 'RenderView is nil' end

  local veh = getPlayerVehicleSafe()
  if not veh then return false, 'No player vehicle found' end

  local pos = veh:getPosition()
  local dir = veh:getDirectionVector()
  local up = veh:getDirectionVectorUp()
  if not pos or not dir or not up then
    return false, 'Vehicle transform unavailable'
  end

  local cameraPos = pos - (dir * 2.25) + (up * 1.15)
  local lookDir = (dir * -1.0) - (up * 0.04)
  local q = quatFromDir(lookDir, up)

  -- quatFromDir returns cdata. MatrixF:setFromQuatF requires QuatF userdata.
  tempQuat.x, tempQuat.y, tempQuat.z, tempQuat.w = q.x, q.y, q.z, q.w

  local ok, err = pcall(function()
    cameraMatrix:setFromQuatF(tempQuat)
    cameraMatrix:setPosition(cameraPos)
    renderView.cameraMatrix = cameraMatrix
  end)

  if not ok then
    return false, 'camera matrix update failed: ' .. tostring(err)
  end
  return true
end

local function createPersistentView()
  if not RenderViewManagerInstance or not RenderViewManagerInstance.getOrCreateView then
    return false, 'RenderViewManagerInstance unavailable'
  end

  local ok, err = pcall(function()
    renderView = RenderViewManagerInstance:getOrCreateView(VIEW_NAME)
    renderView.renderCubemap = false
    renderView.cameraMatrix = cameraMatrix
    renderView.resolution = resolution
    renderView.viewPort = viewport
    renderView.namedTexTargetColor = TEXTURE_NAME
    renderView.frustum = frustum
  end)

  if not ok or not renderView then
    return false, 'RenderView setup failed: ' .. tostring(err)
  end

  return true
end

local function drawLiveWindow()
  if not im or not running then return end
  if showWindow and not showWindow[0] then return end

  im.SetNextWindowSize(im.ImVec2(660, 405), im.Cond_FirstUseEver)
  local flags = bit.bor(im.WindowFlags_NoCollapse, im.WindowFlags_NoScrollbar)
  local visible = im.Begin('Surround View - GPU Rear Camera##surroundViewGpu', showWindow, flags)

  if visible then
    im.Text('Persistent GPU RenderView - no PNG')
    im.Separator()

    local texObj = imUtils.texObj('#' .. TEXTURE_NAME)
    if texObj and texObj.texId then
      local available = im.GetContentRegionAvail()
      local h = math.min(available.y, available.x * HEIGHT / WIDTH)
      local w = h * WIDTH / HEIGHT
      im.Image(texObj.texId, im.ImVec2(w, h), uv0, uv1)
    else
      im.Text('Waiting for #' .. TEXTURE_NAME)
    end
  end

  im.End()
end

function M.startRearCamera()
  running = false

  local ok, err = createPersistentView()
  if not ok then
    emitStatus('error', 'GPU RenderView init failed: ' .. tostring(err))
    return false
  end

  local cameraOk, cameraErr = updateCameraMatrix()
  if not cameraOk then
    emitStatus('error', 'GPU RenderView camera failed: ' .. tostring(cameraErr))
    return false
  end

  running = true
  if showWindow then showWindow[0] = true end
  emitStatus('live', 'GPU RENDERVIEW LIVE v0.5.3')
  return true
end

function M.stopRearCamera()
  running = false
  emitStatus('stopped', 'GPU RenderView stopped')
end

function M.onInit()
  if setExtensionUnloadMode then setExtensionUnloadMode(M, 'manual') end
end

function M.onPreRender(dt)
  if not running then return end
  local ok, err = updateCameraMatrix()
  if not ok then
    running = false
    emitStatus('error', 'GPU RenderView update failed: ' .. tostring(err))
  end
end

function M.onUpdate(dtReal, dtSim, dtRaw)
  drawLiveWindow()
end

function M.onExtensionUnloaded()
  running = false
  if renderView and RenderViewManagerInstance and RenderViewManagerInstance.destroyView then
    pcall(function() RenderViewManagerInstance:destroyView(renderView) end)
  end
  renderView = nil
end

return M
