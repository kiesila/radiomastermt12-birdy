-- MT12 Telemetry Dashboard for Rival MT10 running:
-- EZRUN MAX10 G2 (140A) ESC (30102603)
-- EZRUN 3665 G3 3200kv Motor (38020344)
-- HOBBYWING Telemetry Adapter (30850503)

local SENSOR_TEMP = "Tmp1"
local SENSOR_VOLT = "VFAS"
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

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
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

---@param limitPct number|nil
local function drawCenterBar(x, y, w, h, val, limitPct)
  local cx = x + (w / 2)
  -- Draw outer box
  lcd.drawRectangle(x, y, w, h)
  -- Center detent line
  lcd.drawLine(cx, y, cx, y + h - 1, SOLID, 0)

  -- Calculate fill (val is expected to be -1024 to 1024)
  local fillW = math.floor((math.abs(val) / 1024) * (w / 2))
  fillW = clamp(fillW, 0, math.floor(w / 2))

  if val > 0 then
    lcd.drawFilledRectangle(cx, y, fillW, h)
  elseif val < 0 then
    lcd.drawFilledRectangle(cx - fillW, y, fillW, h)
  end

  -- Draw limit markers if a limit percentage is provided
  if limitPct ~= nil then
    local limOffset = math.floor((limitPct / 100) * (w / 2))
    limOffset = clamp(limOffset, 0, math.floor(w / 2))
    -- Triangle pointing down at the box
    local function drawTri(tx, ty)
      lcd.drawFilledRectangle(tx - 2, ty - 3, 5, 1)
      lcd.drawFilledRectangle(tx - 1, ty - 2, 3, 1)
      lcd.drawFilledRectangle(tx, ty - 1, 1, 1)
    end
    drawTri(cx - limOffset, y)
    drawTri(cx + limOffset, y)
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

local function run(event)
  lcd.clear()
  -- 1. HEADER (Y: 0, H: 7)
  local info = model.getInfo()
  local modelName = string.sub(info.name, 1, 10)

  local rssiName = pickSource({ "RSSI", "1RSS", "2RSS", "RQly", "RFMD", "TRSS" })
  local rssi = rssiName and (getValue(rssiName) or 0) or 0
  if type(rssi) == "number" then rssi = math.floor(rssi + 0.5) else rssi = 0 end

  local txVolts = getValue("tx-voltage") or 0

  -- Header Bar
  lcd.drawFilledRectangle(0, 0, 128, 7)
  lcd.drawText(0, 0, modelName, SMLSIZE + INVERS)

  local rightText = "R:" .. rssi
  if txVolts > 0 then
    rightText = rightText .. string.format(" %.1fV", txVolts)
  end
  lcd.drawText(127, 0, rightText, SMLSIZE + INVERS + RIGHT)

  -- 2. STEERING BAR (Y: 13)
  local steeringVal = getValue("ch1") or 0
  local s2Raw = getValue("s2") or 0
  local s2Pct = (s2Raw + 1024) / 20.48

  lcd.drawText(5, 13, "STR", SMLSIZE)
  drawCenterBar(30, 14, 75, 6, steeringVal, s2Pct)
  lcd.drawText(127, 13, math.floor(s2Pct) .. "%", SMLSIZE + RIGHT)

  -- 3. THROTTLE BAR (Y: 25)
  local throttleVal = getValue("ch2") or 0
  local s1Raw = getValue("s1") or 0
  local s1Pct = (s1Raw + 1024) / 20.48

  lcd.drawText(5, 25, "THR", SMLSIZE)
  drawCenterBar(30, 26, 75, 6, throttleVal, s1Pct)
  lcd.drawText(127, 25, math.floor(s1Pct) .. "%", SMLSIZE + RIGHT)

  -- 4. TRIMS (Y: 37)
  -- TS (Steering Trim) - Right, TT (Throttle Trim) - Left
  local trimST = (getTrimValue(1) or 0) * 8
  local trimTH = (getTrimValue(2) or 0) * 8

  lcd.drawText(5, 37, "TT", SMLSIZE)
  drawCenterBar(15, 38, 40, 4, trimTH, nil)

  lcd.drawText(67, 37, "TS", SMLSIZE)
  drawCenterBar(77, 38, 40, 4, trimST, nil)

  -- 5. FOOTER (Separator line at Y: 46)
  lcd.drawLine(0, 46, 127, 46, SOLID, 0)

  -- Motor Temp (Left)
  local motorTemp = getValue(SENSOR_TEMP) or 0
  lcd.drawText(5, 50, math.floor(motorTemp) .. "@C", 0)

  -- Battery (Right)
  local mainVolts = getValue(SENSOR_VOLT) or 0
  drawBattery(92, 50, 29, 10, mainVolts)

  return 0
end

return { run = run }
