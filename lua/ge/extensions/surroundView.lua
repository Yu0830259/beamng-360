local M = {}

local sensorId = nil
local running = false
local elapsed = 0
local frameInterval = 0.15
local WIDTH = 200
local HEIGHT = 112

local alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

local function base64Encode(data)
  if type(data) ~= 'string' then return nil end
  local out = {}
  local n = 0
  local len = #data
  local i = 1

  while i + 2 <= len do
    local a, b, c = data:byte(i, i + 2)
    local v = a * 65536 + b * 256 + c
    n = n + 1; out[n] = alphabet:sub(math.floor(v / 262144) % 64 + 1, math.floor(v / 262144) % 64 + 1)
    n = n + 1; out[n] = alphabet:sub(math.floor(v / 4096) % 64 + 1, math.floor(v / 4096) % 64 + 1)
    n = n + 1; out[n] = alphabet:sub(math.floor(v / 64) % 64 + 1, math.floor(v / 64) % 64 + 1)
    n = n + 1; out[n] = alphabet:sub(v % 64 + 1, v % 64 + 1)
    i = i + 3
  end

  local remain = len - i + 1
  if remain == 1 then
    local a = data:byte(i)
    local v = a * 65536
    n = n + 1; out[n] = alphabet:sub(math.floor(v / 262144) % 64 + 1, math.floor(v / 262144) % 64 + 1)
    n = n + 1; out[n] = alphabet:sub(math.floor(v / 4096) % 64 + 1, math.floor(v / 4096) % 64 + 1)
    n = n + 1; out[n] = '='
    n = n + 1; out[n] = '='
  elseif remain == 2 then
    local a, b = data:byte(i, i + 1)
    local v = a * 65536 + b * 256
    n = n + 1; out[n] = alphabet:sub(math.floor(v / 262144) % 64 + 1, math.floor(v / 262144) % 64 + 1)
    n = n + 1; out[n] = alphabet:sub(math.floor(v / 4096) % 64 + 1, math.floor(v / 4096) % 64 + 1)
    n = n + 1; out[n] = alphabet:sub(math.floor(v / 64) % 64 + 1, math.floor(v / 64) % 64 + 1)
    n = n + 1; out[n] = '='
  end

  return table.concat(out)
end

local function emitStatus(state, message)
  guihooks.trigger('SurroundViewStatus', {
    state = state,
    message = message or '',
    width = WIDTH,
    height = HEIGHT
  })
end

local function stopSensor()
  if sensorId and extensions.tech_sensors and extensions.tech_sensors.removeSensor then
    pcall(function() extensions.tech_sensors.removeSensor(sensorId) end)
  end
  sensorId = nil
end

function M.stopRearCamera()
  running = false
  stopSensor()
  emitStatus('stopped', 'Rear camera stopped')
end

function M.startRearCamera()
  running = false
  elapsed = 0
  stopSensor()

  if not extensions.tech_sensors then
    pcall(function() extensions.load('tech_sensors') end)
  end

  if not extensions.tech_sensors or not extensions.tech_sensors.createCamera then
    emitStatus('unsupported', 'tech_sensors camera API is not available in this BeamNG build')
    return false
  end

  local veh = be:getPlayerVehicle(0)
  if not veh then
    emitStatus('error', 'No player vehicle found')
    return false
  end

  local vehId = nil
  local okId, id = pcall(function() return veh:getID() end)
  if okId then vehId = id end
  if not vehId then
    okId, id = pcall(function() return veh:getId() end)
    if okId then vehId = id end
  end

  if not vehId then
    emitStatus('error', 'Could not resolve vehicle ID')
    return false
  end

  local ok, result = pcall(function()
    return extensions.tech_sensors.createCamera(vehId, {
      updateTime = frameInterval,
      updatePriority = 0.0,
      pos = vec3(0.0, 2.35, 1.05),
      dir = vec3(0.0, 1.0, -0.06),
      up = vec3(0.0, 0.0, 1.0),
      size = {WIDTH, HEIGHT},
      fovY = 72.0,
      nearFarPlanes = {0.05, 120.0},
      renderColours = true,
      renderAnnotation = false,
      renderInstance = false,
      renderDepth = false,
      isVisualised = false,
      isStatic = false,
      isSnappingDesired = false,
      isForceInsideTriangle = false
    })
  end)

  if not ok or not result then
    emitStatus('error', 'Camera creation failed: ' .. tostring(result))
    return false
  end

  sensorId = result
  running = true
  emitStatus('starting', 'Rear camera sensor created')
  return true
end

local function getColourData()
  if not sensorId or not extensions.tech_sensors or not extensions.tech_sensors.processCameraData then
    return nil, 'processCameraData unavailable'
  end

  local ok, data = pcall(function()
    return extensions.tech_sensors.processCameraData(sensorId)
  end)

  if not ok then return nil, tostring(data) end
  if not data then return nil, 'No camera data returned yet' end

  local colour = data.colour or data.color or data.colours or data.colors
  if type(colour) ~= 'string' then
    return nil, 'Unexpected colour buffer type: ' .. type(colour)
  end

  return colour, nil
end

function M.onUpdate(dtReal, dtSim, dtRaw)
  if not running then return end

  elapsed = elapsed + (dtReal or 0)
  if elapsed < frameInterval then return end
  elapsed = 0

  local colour, err = getColourData()
  if not colour then
    emitStatus('waiting', err)
    return
  end

  local expected = WIDTH * HEIGHT * 3
  if #colour < expected then
    emitStatus('error', 'RGB buffer too small: ' .. tostring(#colour) .. ' / ' .. tostring(expected))
    return
  end

  local encoded = base64Encode(colour)
  if not encoded then
    emitStatus('error', 'Could not encode camera frame')
    return
  end

  guihooks.trigger('SurroundViewRearFrame', {
    width = WIDTH,
    height = HEIGHT,
    rgb = encoded
  })
end

function M.onExtensionUnloaded()
  stopSensor()
end

return M
