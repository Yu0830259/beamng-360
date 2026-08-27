local M = {}

-- v0.5: persistent offscreen RenderView, no PNG/screenshot loop.
-- The rear camera is rendered continuously by BeamNG and shown directly
-- through the named RenderView texture in an ImGui window.

local im = ui_imgui
local imUtils = require('ui/imguiUtils')

local VIEW_NAME = 'surroundViewRearLive'
local WIDTH = 640
local HEIGHT = 360
local running = false
local renderView = nil
local textureObject = nil
local status = 'IDLE'
local initTried = false
local showWindow = im and im.BoolPtr and im.BoolPtr(true) or nil

local function emitStatus(state, message)
  status = message or state or 'UNKNOWN'
  if guihooks and guihooks.trigger then
    guihooks.trigger('SurroundViewStatus', {
      state = state,
      message = status,
      mode = 'persistent-renderview',
      viewName = VIEW_NAME,
      width = WIDTH,
      height = HEIGHT
    })
  end
end

local function getPlayerVehicleSafe()
  if getPlayerVehicle then
    local ok, veh = pcall(function() return getPlayerVehicle(0) end)
    if ok and veh then return veh end
  end
  if be and be.getPlayerVehicle then
    local ok, veh = pcall(function() return be:getPlayerVehicle(0) end)
    if ok and veh then return veh end
  end
  return nil
end

local function getRearCameraTransform(veh)
  local pos = veh:getPosition()
  local dir = veh:getDirectionVector()
  local up = veh:getDirectionVectorUp()
  if not pos or not dir or not up then return nil, nil end

  local cameraPos = pos - (dir * 2.25) + (up * 1.15)
  local lookDir = (dir * -1.0) - (up * 0.04)
  local cameraRot = quatFromDir(lookDir, up)
  return cameraPos, cameraRot
end

local function tryCall(obj, method, ...)
  if not obj then return false end
  local fn = obj[method]
  if type(fn) ~= 'function' then return false end
  local ok = pcall(fn, obj, ...)
  return ok
end

local function trySet(obj, key, value)
  if not obj then return false end
  local ok = pcall(function() obj[key] = value end)
  return ok
end

local function configureStaticView(view)
  -- BeamNG RenderView APIs have changed names over time. Try the currently
  -- documented shapes first, then harmless field fallbacks.
  trySet(view, 'luaOwned', true)
  trySet(view, 'renderEditorIcons', false)

  local resolutionSet =
    tryCall(view, 'setResolution', WIDTH, HEIGHT) or
    tryCall(view, 'setResolution', Point2I and Point2I(WIDTH, HEIGHT) or vec3(WIDTH, HEIGHT, 0)) or
    trySet(view, 'resolution', Point2I and Point2I(WIDTH, HEIGHT) or vec3(WIDTH, HEIGHT, 0))

  tryCall(view, 'setViewport', 0, 0, WIDTH, HEIGHT)
  trySet(view, 'viewport', vec4 and vec4(0, 0, WIDTH, HEIGHT) or nil)

  local textureSet =
    tryCall(view, 'setNamedTexTargetColor', VIEW_NAME) or
    tryCall(view, 'setNamedTextureTarget', VIEW_NAME) or
    trySet(view, 'namedTexTargetColor', VIEW_NAME) or
    trySet(view, 'textureName', VIEW_NAME)

  return resolutionSet, textureSet
end

local function createPersistentView()
  if not RenderViewManagerInstance or not RenderViewManagerInstance.getOrCreateView then
    return false, 'RenderViewManagerInstance unavailable'
  end

  local ok, view = pcall(function()
    return RenderViewManagerInstance:getOrCreateView(VIEW_NAME)
  end)
  if not ok or not view then
    return false, 'getOrCreateView failed: ' .. tostring(view)
  end

  renderView = view
  local resOk, texOk = configureStaticView(renderView)
  if not resOk then
    return false, 'RenderView created, but resolution API was not recognized'
  end
  if not texOk then
    return false, 'RenderView created, but named texture API was not recognized'
  end

  local okTex, tex = pcall(function()
    return imUtils.texObj('#' .. VIEW_NAME)
  end)
  if okTex then textureObject = tex end

  return true
end

local function updateRenderViewCamera()
  if not renderView then return false, 'RenderView is nil' end

  local veh = getPlayerVehicleSafe()
  if not veh then return false, 'No player vehicle found' end

  local cameraPos, cameraRot = getRearCameraTransform(veh)
  if not cameraPos or not cameraRot then
    return false, 'Vehicle camera transform unavailable'
  end

  local matrix = MatrixF(true)
  matrix:setFromQuat(cameraRot)
  matrix:setPosition(cameraPos)

  local cameraOk =
    tryCall(renderView, 'setCameraMatrix', matrix) or
    trySet(renderView, 'cameraMatrix', matrix)

  local aspect = WIDTH / HEIGHT
  local frustumOk =
    tryCall(renderView, 'setFrustum', 78, aspect, 0.08, 800) or
    tryCall(renderView, 'setFrustum', math.rad(78), aspect, 0.08, 800)

  if not frustumOk then
    trySet(renderView, 'fov', 78)
    trySet(renderView, 'nearPlane', 0.08)
    trySet(renderView, 'farPlane', 800)
  end

  if not cameraOk then
    return false, 'RenderView camera-matrix API was not recognized'
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
    im.Text('GPU RenderView / no screenshots / no PNG reload')
    im.Separator()

    if not textureObject then
      local okTex, tex = pcall(function() return imUtils.texObj('#' .. VIEW_NAME) end)
      if okTex then textureObject = tex end
    end

    if textureObject then
      local texId = textureObject.texId or textureObject.id or textureObject
      local okImg, err = pcall(function()
        im.Image(texId, im.ImVec2(640, 360))
      end)
      if not okImg then
        im.TextColored(im.ImVec4(1, 0.45, 0.45, 1), 'Texture draw error: ' .. tostring(err))
      end
    else
      im.Text('Waiting for named RenderView texture #' .. VIEW_NAME)
    end
  end
  im.End()
end

function M.startRearCamera()
  running = false
  initTried = true
  textureObject = nil

  local ok, err = createPersistentView()
  if not ok then
    emitStatus('error', 'GPU RenderView init failed: ' .. tostring(err))
    return false
  end

  local cameraOk, cameraErr = updateRenderViewCamera()
  if not cameraOk then
    emitStatus('error', 'GPU RenderView camera failed: ' .. tostring(cameraErr))
    return false
  end

  running = true
  if showWindow then showWindow[0] = true end
  emitStatus('live', 'GPU RENDERVIEW LIVE · no PNG')
  return true
end

function M.stopRearCamera()
  running = false
  emitStatus('stopped', 'GPU RenderView stopped')
end

function M.onInit()
  if setExtensionUnloadMode then setExtensionUnloadMode(M, 'manual') end
end

function M.onUpdate(dtReal, dtSim, dtRaw)
  if running then
    local ok, err = updateRenderViewCamera()
    if not ok then
      running = false
      emitStatus('error', 'GPU RenderView update failed: ' .. tostring(err))
    end
  end

  drawLiveWindow()
end

function M.onExtensionUnloaded()
  running = false
  textureObject = nil
  renderView = nil
end

return M
