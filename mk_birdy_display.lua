-- MT12 Telemetry Dashboard for Rival MT10 running:
-- EZRUN MAX10 G2 (140A) ESC (30102603)
-- EZRUN 3665 G3 3200kv Motor (38020344)
-- HOBBYWING Telemetry Adapter (30850503)

-- --- CONSTANTS ---
local SENSOR_MOTOR_TEMP = "Tmp1"
local SENSOR_ESC_TEMP = "EscT"
local SENSOR_VOLT = "EscV"
local CELLS = 3 -- 3S LiPo config

-- LiPo discharge curve mapping (Voltage per cell -> Capacity %)
local lipoCurve = {
  { v = 4.20, pct = 1.00 },
  { v = 4.00, pct = 0.84 },
  { v = 3.90, pct = 0.63 },
  { v = 3.80, pct = 0.39 },
  { v = 3.70, pct = 0.15 },
  { v = 3.50, pct = 0.05 },
  { v = 3.20, pct = 0.00 }
}

-- Cached telemetry source names to avoid expensive lookups in the render loop
local cachedRssiName = nil

local voltHistory = {}
local voltHistoryIdx = 1
local lastVoltTime = 0
local voltSum = 0
local voltCount = 0
local smoothedVoltage = 0

-- --- HELPER FUNCTIONS ---

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- Scale raw radio input (-1024 to 1024) to a percentage (0 to 100)
local function scaleRawToPct(raw)
  return clamp((raw + 1024) / 20.48, 0, 100)
end

local function pickSource(candidates)
  for i = 1, #candidates do
    local name = candidates[i]
    if getFieldInfo(name) ~= nil then
      return name
    end
  end
  return nil
end

-- Triangle pointing down at the bar (for limit markers)
local function drawLimiterTriangle(tx, ty)
  lcd.drawFilledRectangle(tx - 2, ty - 3, 5, 1)
  lcd.drawFilledRectangle(tx - 1, ty - 2, 3, 1)
  lcd.drawFilledRectangle(tx, ty - 1, 1, 1)
end

-- Triangle pointing right at the vertical bar
local function drawLimiterTriangleRight(tx, ty)
  lcd.drawFilledRectangle(tx - 3, ty - 2, 1, 5)
  lcd.drawFilledRectangle(tx - 2, ty - 1, 1, 3)
  lcd.drawFilledRectangle(tx - 1, ty, 1, 1)
end

-- --- RENDERING COMPONENT HELPERS ---

---@param limitPct number|nil
local function drawCenterBar(x, y, w, h, val, limitPct)
  local cx = x + (w / 2)
  -- Draw outer box
  lcd.drawRectangle(x, y, w, h)
  -- Center detent line
  lcd.drawLine(cx, y, cx, y + h - 1, SOLID, 0)

  -- Calculate fill (val is expected to be -1024 to 1024)
  local fillW = math.floor((math.abs(val) / 1024) * (w / 2))
  local maxFill = math.floor(w / 2)

  local limOffset = nil
  if limitPct ~= nil then
    limOffset = math.floor((limitPct / 100) * (w / 2))
    limOffset = clamp(limOffset, 0, maxFill)
    maxFill = limOffset
  end

  fillW = clamp(fillW, 0, maxFill)

  if val > 0 then
    lcd.drawFilledRectangle(cx, y, fillW, h)
  elseif val < 0 then
    lcd.drawFilledRectangle(cx - fillW, y, fillW, h)
  end

  -- Draw limit markers if a limit percentage is provided
  if limOffset ~= nil then
    drawLimiterTriangle(cx - limOffset, y)
    drawLimiterTriangle(cx + limOffset, y)
  end
end

local function drawVerticalCenterBar(x, y, w, h, val, limitPct)
  local cy = y + math.floor(h / 2)
  -- Draw outer box
  lcd.drawRectangle(x, y, w, h)
  -- Center detent line
  lcd.drawLine(x, cy, x + w - 1, cy, SOLID, 0)

  -- Calculate fill (val is expected to be -1024 to 1024)
  local fillH = math.floor((math.abs(val) / 1024) * (h / 2))
  local maxFill = math.floor(h / 2)

  local limOffset = nil
  if limitPct ~= nil then
    limOffset = math.floor((limitPct / 100) * (h / 2))
    limOffset = clamp(limOffset, 0, maxFill)
    maxFill = limOffset
  end

  fillH = clamp(fillH, 0, maxFill)

  if val > 0 then
    lcd.drawFilledRectangle(x, cy - fillH, w, fillH)
  elseif val < 0 then
    lcd.drawFilledRectangle(x, cy + 1, w, fillH)
  end

  -- Draw limit markers if a limit percentage is provided
  if limOffset ~= nil then
    drawLimiterTriangleRight(x, cy - limOffset)
    drawLimiterTriangleRight(x, cy + limOffset)
  end
end

local function getTrimValue(i)
  local fmIdx = select(1, getFlightMode())
  local fm = model.getFlightMode(fmIdx)
  if fm and fm.trimsValues then
    local v = fm.trimsValues[i]
    if type(v) == "number" then
      return v
    end
  end
  return 0
end

local function drawBattery(x, y, w, h, voltage)
  local vPerCell = voltage / CELLS

  -- Calculate number of blocks based on lipoCurve thresholds
  local blocks = 0
  for i = 1, #lipoCurve do
    if vPerCell >= lipoCurve[i].v then
      blocks = #lipoCurve - i + 1
      break
    end
  end

  -- Battery outline and terminal
  lcd.drawRectangle(x, y, w, h)
  lcd.drawFilledRectangle(x + w, y + math.floor(h / 4), 2, math.floor(h / 2))

  -- Draw the active blocks
  local bw = 3
  local s = 1
  for j = 1, blocks do
    local bx = x + 1 + (j - 1) * (bw + s)
    lcd.drawFilledRectangle(bx, y + 1, bw, h - 2)
  end
end

-- --- MAIN RENDER LOOP ---

local function run(event)
  lcd.clear()

  -- 1. HEADER (Y: 0, H: 7)
  local info = model.getInfo()
  local modelName = string.sub(info.name, 1, 10)

  -- Resolve telemetry RSSI sensor (lazy-cached once)
  if cachedRssiName == nil then
    cachedRssiName = pickSource({ "RSSI", "1RSS", "2RSS", "RQly", "RFMD", "TRSS" }) or ""
  end

  local rssi = 0
  if cachedRssiName ~= "" then
    rssi = getValue(cachedRssiName) or 0
  end
  if type(rssi) == "number" then
    rssi = math.floor(rssi + 0.5)
  else
    rssi = 0
  end

  local txVolts = getValue("tx-voltage") or 0

  -- Header Bar
  lcd.drawFilledRectangle(0, 0, 128, 7)
  lcd.drawText(0, 0, modelName, SMLSIZE + INVERS)

  local rightText = "R:" .. rssi
  if txVolts > 0 then
    rightText = rightText .. string.format(" %.1fV", txVolts)
  end
  lcd.drawText(127, 0, rightText, SMLSIZE + INVERS + RIGHT)

  -- Read inputs
  local steeringVal = getValue("ch1") or 0
  local s2Raw = getValue("s2") or 0
  local s2Pct = scaleRawToPct(s2Raw)

  local throttleVal = getValue("ch2") or 0
  local s1Raw = getValue("s1") or 0
  local s1Pct = scaleRawToPct(s1Raw)

  local trimST = getTrimValue(1) * 8 or 0
  local trimTH = getTrimValue(2) * 8 or 0

  local motorTemp = getValue(SENSOR_MOTOR_TEMP) or 0
  local escTemp = getValue(SENSOR_ESC_TEMP) or 0

  -- Battery voltage processing
  -- Exponential Moving Average (EMA) to smooth out voltage fluctuations
  local mainVolts = getValue(SENSOR_VOLT) or 0
  local now = getTime()
  local smoothedVoltage = 0
  local filterFactor = 0.05 -- Range 0.0 to 1.0. Lower = smoother/slower.

  if mainVolts > 0 then
    if smoothedVoltage == 0 then
      -- Snap to the first valid reading instantly so you don't slowly climb from 0
      smoothedVoltage = mainVolts
    else
      -- The EMA formula: add a small percentage of the difference between the new and old value
      smoothedVoltage = smoothedVoltage + filterFactor * (mainVolts - smoothedVoltage)
    end
  else
    smoothedVoltage = 0
  end

  -- 2. STEERING BAR
  drawCenterBar(4, 11, 94, 6, steeringVal, s2Pct)
  lcd.drawText(102, 10, math.floor(s2Pct) .. "%", SMLSIZE)

  -- Separators
  lcd.drawLine(0, 18, 127, 18, SOLID, 0)
  lcd.drawLine(48, 18, 48, 54, SOLID, 0)

  -- 3. THROTTLE BAR (Left Pane)
  lcd.drawText(46, 20, math.floor(s1Pct) .. "%", SMLSIZE + RIGHT)
  drawVerticalCenterBar(10, 21, 12, 31, throttleVal, s1Pct)

  -- 4. TEMP & BATTERY (Right Pane)
  lcd.drawText(52, 21, "Motor", SMLSIZE)
  lcd.drawText(84, 19, math.floor(motorTemp) .. "@C", 0)

  lcd.drawText(52, 31, "ESC", SMLSIZE)
  lcd.drawText(84, 29, math.floor(escTemp) .. "@C", 0)

  drawBattery(90, 40, 29, 10, smoothedVoltage)
  lcd.drawText(86, 42, string.format("%.1fV", smoothedVoltage), SMLSIZE + RIGHT)

  -- 5. FOOTER (Trims)
  lcd.drawLine(0, 54, 127, 54, SOLID, 0)

  lcd.drawText(2, 56, "TT", SMLSIZE)
  drawCenterBar(15, 57, 40, 4, trimTH, nil)

  lcd.drawText(65, 56, "TS", SMLSIZE)
  drawCenterBar(78, 57, 40, 4, trimST, nil)

  return 0
end

return { run = run }
