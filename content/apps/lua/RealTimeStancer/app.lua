local ac = require('ac')
local ui = require('ui')
local json = require('json')

local APP_DISPLAY_NAME = 'Real Time Stancer'
local PRESET_FILENAME = 'config_presets.json'
local REQUIRED_PATCH_VERSION = '0.1.80'
local PLAYER_CAR_INDEX = 0

local presetCache = { presets = {}, order = {} }
local selectedPreset = nil
local pendingPresetName = ''
local lastAppliedCar = -1
local lastWheelSignature = ''
local patchSupported = false

local state = {
  wheels = {
    { name = 'Front Left', id = 0, offset = 0.0, track = 0.0, camber = 0.0, rideHeight = 0.0 },
    { name = 'Front Right', id = 1, offset = 0.0, track = 0.0, camber = 0.0, rideHeight = 0.0 },
    { name = 'Rear Left', id = 2, offset = 0.0, track = 0.0, camber = 0.0, rideHeight = 0.0 },
    { name = 'Rear Right', id = 3, offset = 0.0, track = 0.0, camber = 0.0, rideHeight = 0.0 }
  },
  syncAxles = true,
  syncSides = true,
  visualOnly = true
}

local function getPresetFilePath()
  local root = ac.getFolder(ac.FolderID.Content)
  return string.format('%s/apps/lua/RealTimeStancer/%s', root, PRESET_FILENAME)
end

local function parseVersion(value)
  local major, minor, patch = value:match('(%d+)%.(%d+)%.?(%d*)')
  if not major then return 0 end
  local m = tonumber(major) or 0
  local n = tonumber(minor) or 0
  local p = tonumber(patch) or 0
  return m * 1000000 + n * 1000 + p
end

local function updatePatchSupport()
  local version = '0.0.0'
  if ac.getPatchVersion then
    version = ac.getPatchVersion() or '0.0.0'
  end
  patchSupported = parseVersion(version) >= parseVersion(REQUIRED_PATCH_VERSION)
  return patchSupported, version
end

local function ensurePresetStorage()
  local filename = getPresetFilePath()
  local file = io.open(filename, 'r')
  if file then
    file:close()
    return
  end
  file = io.open(filename, 'w')
  if file then
    file:write(json.encode({ presets = {}, order = {} }))
    file:close()
  end
end

local function loadPresets()
  ensurePresetStorage()
  local filename = getPresetFilePath()
  local file = io.open(filename, 'r')
  if not file then return end
  local content = file:read('*a') or ''
  file:close()
  local decoded = json.decode(content) or {}
  presetCache.presets = decoded.presets or {}
  presetCache.order = decoded.order or {}
end

local function savePresets()
  ensurePresetStorage()
  local payload = json.encode({ presets = presetCache.presets, order = presetCache.order })
  local file = io.open(getPresetFilePath(), 'w')
  if not file then return end
  file:write(payload)
  file:close()
end

local function snapshotState()
  local snapshot = {
    wheels = {},
    syncAxles = state.syncAxles,
    syncSides = state.syncSides,
    visualOnly = state.visualOnly
  }
  for i = 1, #state.wheels do
    local wheel = state.wheels[i]
    snapshot.wheels[i] = {
      offset = wheel.offset,
      track = wheel.track,
      camber = wheel.camber,
      rideHeight = wheel.rideHeight
    }
  end
  return snapshot
end

local function applySnapshot(snapshot)
  if not snapshot then return end
  state.syncAxles = snapshot.syncAxles ~= false
  state.syncSides = snapshot.syncSides ~= false
  state.visualOnly = snapshot.visualOnly ~= false
  for i = 1, #state.wheels do
    local wheel = state.wheels[i]
    local presetWheel = snapshot.wheels and snapshot.wheels[i]
    if presetWheel then
      wheel.offset = presetWheel.offset or 0
      wheel.track = presetWheel.track or 0
      wheel.camber = presetWheel.camber or 0
      wheel.rideHeight = presetWheel.rideHeight or 0
    else
      wheel.offset, wheel.track, wheel.camber, wheel.rideHeight = 0, 0, 0, 0
    end
  end
end

local function addPreset(name)
  if not name or name == '' then return false end
  name = name:gsub('^%s+', ''):gsub('%s+$', '')
  if name == '' then return false end
  presetCache.presets[name] = snapshotState()
  local exists = false
  for i = 1, #presetCache.order do
    if presetCache.order[i] == name then
      exists = true
      break
    end
  end
  if not exists then
    presetCache.order[#presetCache.order + 1] = name
  end
  savePresets()
  return true, name
end

local function removePreset(name)
  if not name then return false end
  presetCache.presets[name] = nil
  for i = #presetCache.order, 1, -1 do
    if presetCache.order[i] == name then
      table.remove(presetCache.order, i)
    end
  end
  if selectedPreset == name then
    selectedPreset = nil
  end
  savePresets()
  return true
end

local function buildWheelSignature(carID)
  local items = { tostring(carID) }
  for i = 1, #state.wheels do
    local wheel = state.wheels[i]
    items[#items + 1] = string.format('%.3f|%.3f|%.3f|%.3f', wheel.offset, wheel.track, wheel.camber, wheel.rideHeight)
  end
  items[#items + 1] = state.visualOnly and '1' or '0'
  return table.concat(items, ';')
end

local function applyWheelSettings()
  if ac.getSimState then
    local simState = ac.getSimState()
    if ac.SimState and simState ~= ac.SimState.Running and simState ~= ac.SimState.Paused then
      return
    elseif not ac.SimState and simState ~= 2 and simState ~= 3 then
      return
    end
  end
  local carIndex = PLAYER_CAR_INDEX

  local signature = buildWheelSignature(carIndex)
  if lastWheelSignature == signature and lastAppliedCar == carIndex then
    return
  end

  local physics = ac.getCarPhysics and ac.getCarPhysics(carIndex) or nil

  for i = 1, #state.wheels do
    local wheel = state.wheels[i]
    if physics and physics.setWheelOffset then
      physics:setWheelOffset(wheel.id, wheel.offset)
    elseif ac.setWheelOffset then
      ac.setWheelOffset(carIndex, wheel.id, wheel.offset)
    end
    if physics and physics.setWheelTrackWidth then
      physics:setWheelTrackWidth(wheel.id, wheel.track)
    elseif ac.setWheelTrackWidth then
      ac.setWheelTrackWidth(carIndex, wheel.id, wheel.track)
    end
    if physics and physics.setWheelCamber then
      physics:setWheelCamber(wheel.id, wheel.camber)
    elseif ac.setWheelCamber then
      ac.setWheelCamber(carIndex, wheel.id, wheel.camber)
    end
    if physics and physics.setWheelRideHeight then
      physics:setWheelRideHeight(wheel.id, wheel.rideHeight, state.visualOnly)
    elseif physics and physics.setWheelVisualHeight then
      physics:setWheelVisualHeight(wheel.id, wheel.rideHeight)
    elseif ac.setWheelRideHeight then
      ac.setWheelRideHeight(carIndex, wheel.id, wheel.rideHeight, state.visualOnly)
    end
  end

  if ac.redrawCar then
    ac.redrawCar(carIndex)
  end

  lastAppliedCar = carIndex
  lastWheelSignature = signature
end

local function syncLinkedWheels(sourceIndex, field, value)
  local sourceWheel = state.wheels[sourceIndex]
  sourceWheel[field] = value

  local axlePairs = { [0] = 2, [1] = 3, [2] = 0, [3] = 1 }
  local sidePairs = { [0] = 1, [1] = 0, [2] = 3, [3] = 2 }

  local queue = { sourceWheel.id }
  local visited = { [sourceWheel.id] = true }
  local head = 1

  while queue[head] do
    local current = queue[head]
    head = head + 1

    if state.syncAxles then
      local pair = axlePairs[current]
      if pair and not visited[pair] then
        visited[pair] = true
        queue[#queue + 1] = pair
      end
    end

    if state.syncSides then
      local pair = sidePairs[current]
      if pair and not visited[pair] then
        visited[pair] = true
        queue[#queue + 1] = pair
      end
    end
  end

  for wheelID, _ in pairs(visited) do
    local target = state.wheels[wheelID + 1]
    if target then
      target[field] = value
    end
  end
end

local function drawWheelControls(wheel)
  ui.separator()
  ui.text(wheel.name)

  local function slider(label, field, minValue, maxValue, format)
    local value = wheel[field]
    local newValue = ui.sliderFloat(string.format('%s##%d', label, wheel.id), value, minValue, maxValue, format)
    if newValue ~= nil and math.abs(newValue - value) > 0.0001 then
      syncLinkedWheels(wheel.id + 1, field, newValue)
    end
  end

  slider('Wheel Offset (mm)', 'offset', -50.0, 50.0, '%.1f')
  slider('Track Width (mm)', 'track', -100.0, 100.0, '%.1f')
  slider('Camber (deg)', 'camber', -10.0, 10.0, '%.2f')
  slider('Ride Height (mm)', 'rideHeight', -100.0, 100.0, '%.1f')
end

local function drawPresetManager()
  ui.separator()
  ui.text('Presets')

  local presetNames = presetCache.order
  local selectedIndex = 0
  for i = 1, #presetNames do
    if presetNames[i] == selectedPreset then
      selectedIndex = i
      break
    end
  end

  if ui.beginListBox and ui.endListBox then
    if ui.beginListBox('##PresetList', ui.vec2(0, 140)) then
      for i = 1, #presetNames do
        local isSelected = selectedIndex == i
        if ui.selectable(presetNames[i], isSelected) then
          selectedPreset = presetNames[i]
        end
      end
      ui.endListBox()
    end
  else
    for i = 1, #presetNames do
      local isSelected = selectedPreset == presetNames[i]
      if ui.selectable(presetNames[i], isSelected) then
        selectedPreset = presetNames[i]
      end
    end
  end

  if selectedPreset then
    if ui.button('Load##Preset') then
      applySnapshot(presetCache.presets[selectedPreset])
    end
    if ui.button('Overwrite##Preset') then
      addPreset(selectedPreset)
    end
    if ui.button('Delete##Preset') then
      removePreset(selectedPreset)
    end
  end

  local newText, textChanged = ui.inputText('Preset Name', pendingPresetName or '', 48)
  if textChanged ~= false and newText then
    pendingPresetName = newText
  end
  if ui.button('Save New Preset') then
    local ok, normalizedName = addPreset(pendingPresetName)
    if ok then
      selectedPreset = normalizedName
      pendingPresetName = ''
    end
  end
end

local function drawSyncToggles()
  ui.separator()
  local syncAxles = ui.checkbox('Sync Axles (front ↔ rear)', state.syncAxles)
  if syncAxles ~= nil then
    state.syncAxles = syncAxles
  end
  local syncSides = ui.checkbox('Sync Sides (left ↔ right)', state.syncSides)
  if syncSides ~= nil then
    state.syncSides = syncSides
  end
  local visualOnly = ui.checkbox('Visual Ride Height Only', state.visualOnly)
  if visualOnly ~= nil then
    state.visualOnly = visualOnly
  end
end

local function renderMainWindow(dt)
  local supported, version = updatePatchSupport()
  if not supported then
    ui.text(string.format('Requires CSP %s+ (detected %s). Enable Lua scripting in CSP settings.', REQUIRED_PATCH_VERSION, version))
    return
  end

  drawSyncToggles()

  for i = 1, #state.wheels do
    drawWheelControls(state.wheels[i])
  end

  drawPresetManager()
end

local lastDeltaTime = 0

function script.update(dt)
  lastDeltaTime = dt
  if patchSupported then
    applyWheelSettings()
  end
end

function script.windowMain(dt)
  if ui.windowBegin(APP_DISPLAY_NAME) then
    renderMainWindow(dt or lastDeltaTime)
  end
  ui.windowEnd()
end

function script.load()
  updatePatchSupport()
  loadPresets()
end

function script.unload()
end
