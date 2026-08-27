local M = {}

M.dependencies = {"render_renderViews"}

local running = false
local elapsed = 0
local frameInterval = 0.25
local frameNumber = 0
local WIDTH = 320
local HEIGHT = 180
local OUTPUT_DIR = "screenshots/beamng-360"
local OUTPUT_FILE = OUTPUT_DIR .. "/rear.png"

local function emitStatus(state, message)
  if guihooks and guihooks.trigger then
    guihooks.trigger("SurroundViewStatus", {
      state = state,
      message = message or "",
      width = WIDTH,
      height = HEIGHT,
      frame = frameNumber
    })
  end
end

local function ensureOutputDirectory()
  if not FS then return false, "FS API unavailable" end

  if not FS:directoryExists(OUTPUT_DIR) then
    local ok, err = pcall(function()
      FS:directoryCreate(OUTPUT_DIR, true)
    end)
    if not ok then
      return false, tostring(err)
    end
  end

  return true
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

  if not pos or not dir or not up then
    return nil, nil, "Vehicle transform unavailable"
  end

  -- Place the camera just behind and above the vehicle, facing backwards.
  -- These offsets are intentionally generic so this first retail-drive test
  -- works across many vehicles; per-car calibration can come later.
  local cameraPos = pos - (dir * 2.35) + (up * 1.05)
  local lookDir = (dir * -1.0) + (up * -0.06)
  local cameraRot = quatFromDir(lookDir, up)

  return cameraPos, cameraRot, nil
end

local function captureRearFrame()
  if not render_renderViews or not render_renderViews.takeScreenshot then
    return false, "render_renderViews.takeScreenshot is unavailable"
  end

  local veh = getPlayerVehicleSafe()
  if not veh then
    return false, "No player vehicle found"
  end

  local cameraPos, cameraRot, transformError = getRearCameraTransform(veh)
  if not cameraPos or not cameraRot then
    return false, transformError or "Could not calculate rear camera transform"
  end

  local ok, err = pcall(function()
    render_renderViews.takeScreenshot({
      renderViewName = "surroundViewRear",
      filename = OUTPUT_FILE,
      resolution = vec3(WIDTH, HEIGHT, 0),
      pos = cameraPos,
      rot = cameraRot,
      fov = 78,
      nearPlane = 0.08,
      screenshotDelay = 0.02
    })
  end)

  if not ok then
    return false, tostring(err)
  end

  frameNumber = frameNumber + 1
  return true
end

function M.startRearCamera()
  running = false
  elapsed = 0
  frameNumber = 0

  local dirOk, dirError = ensureOutputDirectory()
  if not dirOk then
    emitStatus("error", "RenderView output directory failed: " .. tostring(dirError))
    return false
  end

  if not render_renderViews or not render_renderViews.takeScreenshot then
    emitStatus("error", "Retail RenderView API unavailable: render_renderViews.takeScreenshot missing")
    return false
  end

  running = true
  emitStatus("starting", "Retail RenderView rear camera starting")

  local ok, err = captureRearFrame()
  if not ok then
    running = false
    emitStatus("error", "Rear RenderView capture failed: " .. tostring(err))
    return false
  end

  emitStatus("ready", "REAR RENDERVIEW READY")
  return true
end

function M.stopRearCamera()
  running = false
  emitStatus("stopped", "Rear RenderView stopped")
end

function M.onInit()
  if setExtensionUnloadMode then
    setExtensionUnloadMode(M, "manual")
  end
end

function M.onUpdate(dtReal, dtSim, dtRaw)
  if not running then return end

  elapsed = elapsed + (dtReal or 0)
  if elapsed < frameInterval then return end
  elapsed = 0

  local ok, err = captureRearFrame()
  if not ok then
    running = false
    emitStatus("error", "Rear RenderView capture failed: " .. tostring(err))
    return
  end

  if frameNumber % 20 == 0 then
    emitStatus("live", "REAR RENDERVIEW LIVE · frame " .. tostring(frameNumber))
  end
end

function M.onExtensionUnloaded()
  running = false
end

return M
