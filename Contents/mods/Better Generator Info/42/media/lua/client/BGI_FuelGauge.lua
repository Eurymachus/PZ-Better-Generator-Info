-- Purpose: Draw a horizontal fuel bar INSIDE ISGeneratorInfoWindow, aligned under the "Fuel:" line.
--
-- Notes:
--   - Safe Alternative: stays fully inside the window; no width changes; no external attachments.
--   - Layout is computed from title bar height + font line height. Minor skin differences can be nudged via BGI.Config.
--   - Hover tooltip uses consolidated translation keys (UI_BGI_Fuel_Hover*).

if not ISGeneratorInfoWindow then return end

BGI = BGI or {}

local H = require("BGI_Helpers")

if not H then
  print("BGI.Helpers Table NOT FOUND")
  return
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Config (adjust if your build/skin shifts the content a bit)
-- ─────────────────────────────────────────────────────────────────────────────
BGI.Config = BGI.Config or {
    contentTopPad   = 69,   -- px below title bar where body text starts
    rowGap          = 18,  -- vertical distance per text row (UIFont.Small)
    fuelRowIndex    = 2,   -- 0=Status, 1=Fuel, 2=bar UNDER Fuel (i.e., draw starting at FuelRow + 1*rowGap*0.7)
    barYOffset      = 4,   -- additional pixels below the Fuel text baseline to place the bar
    barHeight       = 10,   -- bar thickness
    barWidth        = 78,   -- bar width
    sidePad         = 8,   -- left/right padding inside window
}

local TOOLTIP_X, TOOLTIP_Y = 20, 20

-- ─────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────────

---@param win ISGeneratorInfoWindow
local function getGenerator(win)
    return (win and (win.generator or win.isoObject or win.object)) or nil
end

-- Linear interpolation helper
local function lerp(a, b, t)
    return a + (b - a) * t
end

-- Return a smooth gradient from RED (<10%) to PZ fuel GREEN (>90%)
-- p: number (0..100)
-- returns r,g,b,a
local function pickBarColor(p)
    -- Vanilla-ish colors (tweak if your palette differs)
    local RED   = { r = 1.00, g = 0.25, b = 0.20 }
    local GREEN = { r = 0.35, g = 0.90, b = 0.35 } -- "PZ fuel colour"

    if type(p) ~= "number" then p = 0 end
    if p <= 10 then
        return RED.r, RED.g, RED.b, 1
    elseif p >= 90 then
        return GREEN.r, GREEN.g, GREEN.b, 1
    else
        -- Normalize 10..90 → 0..1
        local t = (p - 10) / 80
        local r = lerp(RED.r,   GREEN.r,   t)
        local g = lerp(RED.g,   GREEN.g,   t)
        local b = lerp(RED.b,   GREEN.b,   t)
        return r, g, b, 1
    end
end

local function pulseAlpha()
    local t = (UIManager and UIManager.getMillisSinceStart and UIManager.getMillisSinceStart()) or 0
    local phase = (t % 1200) / 1200.0
    local a = 0.85 + 0.15 * math.sin(phase * math.pi * 2)
    if a < 0.7 then a = 0.7 end
    if a > 1.0 then a = 1.0 end
    return a
end

-- Consolidated translation with fallbacks (percent + liters + hours)
local function formatHoverText(percent, liters, hours)
    local pct  = string.format("%d", percent)
    local lits = liters and string.format("%.1f", liters) or nil
    local hrs  = hours  and string.format("%.1f", hours)  or nil

    if lits and hrs then
        return getText("UI_BGI_Fuel_Hover", pct, lits, hrs)
    elseif lits then
        return getText("UI_BGI_Fuel_HoverLiters", pct, lits)
    elseif hrs then
        return getText("UI_BGI_Fuel_HoverHours", pct, hrs)
    else
        return getText("UI_BGI_Fuel_HoverSimple", pct)
    end
end

local function isMouseOverRect(win, rx, ry, rw, rh)
    local mx = win:getMouseX()
    local my = win:getMouseY()
    return mx >= rx and mx <= rx + rw and my >= ry and my <= ry + rh
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Drawing: Horizontal bar under the Fuel line
-- ─────────────────────────────────────────────────────────────────────────────

local function drawHorizontalBar(win, fuelPercent, liters, hours)
    local cfg    = BGI.Config
    local titleH = win:titleBarHeight() or 20
    local font   = getTextManager():getFontFromEnum(UIFont.Small)
    local lineH  = font and font:getLineHeight() or cfg.rowGap
    local side   = cfg.sidePad

    -- We assume the "Fuel:" label is the second body line: Status (row 0), Fuel (row 1).
    -- We draw the bar just below that, with an extra Y offset for visual breathing room.
    local contentTop = titleH + cfg.contentTopPad
    local fuelTextY  = contentTop + (1 * cfg.rowGap) -- row 1 is "Fuel:"
    local barY       = fuelTextY + cfg.barYOffset + math.floor(lineH * 0.4)

    local barX = side
    local barW = cfg.barWidth - side * 2
    local barH = cfg.barHeight

    -- Optional label refresh (keeps vanilla look; harmless if vanilla prints its own line)
    -- Comment this out if you see duplicated "Fuel:" text in your build.
    -- local label = getText("UI_BGI_FuelLabel")
    -- win:drawText(label .. " " .. string.format("%d%%", fuelPercent), barX, fuelTextY - (lineH - 12), 1,1,1,1, UIFont.Small)

    -- Track + subtle plate
    win:drawRect(barX-1, barY-1, barW+2, barH+2, 0.35, 0, 0, 0)
    win:drawRect(barX,   barY,   barW,   barH,   0.8,  0.12,0.12,0.12)

    -- Fill
    local fillW = math.floor(barW * (fuelPercent / 100))
    local r,g,b,a = pickBarColor(fuelPercent)
    if fuelPercent <= 5 then a = pulseAlpha() end
    if fillW > 0 then
        win:drawRect(barX, barY, fillW, barH, a, r, g, b)
    end

    -- Hover tooltip (bar hitbox)
    if isMouseOverRect(win, barX-1, barY-1, barW+2, barH+2) then
        local tip = H.formatHover(fuelPercent, liters, hours)
        local tw  = getTextManager():MeasureStringX(UIFont.Small, tip) + 10
        local th  = (font and font:getLineHeight() or 14) + 6
        local tx  = math.min(win:getMouseX() + TOOLTIP_X, win.width - tw - 6)
        local ty  = math.max(titleH + 4, win:getMouseY() + TOOLTIP_Y)

        -- Shadow/backplate
        win:drawRect(tx-1, ty-1, tw+2, th+2, 0.60, 0, 0, 0)   -- soft drop shadow
        -- Body
        win:drawRect(tx,   ty,   tw,   th,   0.95, 0, 0, 0)   -- dark panel
        -- White border (outer)
        win:drawRectBorder(tx,   ty,   tw,   th,   1.00, 1, 1, 1)

        -- (Optional) subtle inner highlight to match PZ-ish look; comment out if not desired
        -- win:drawRectBorder(tx+1, ty+1, tw-2, th-2, 0.20, 1, 1, 1)

        win:drawText(tip,  tx+5, ty+3, 1, 1, 1, 1, UIFont.Small)
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Monkey-patch: ISGeneratorInfoWindow:render
-- ─────────────────────────────────────────────────────────────────────────────
if not BGI._origRender then
    BGI._origRender = ISGeneratorInfoWindow.render
end

function ISGeneratorInfoWindow:render()
    -- Render vanilla first
    BGI._origRender(self)

    local gen = getGenerator(self)
    if not gen then return end

    -- Option toggle must be ON
    if not (BGI and BGI.Options and BGI.Options.ShowFuelGauge) then return end

    -- Player must meet required Electricity level
    if not BGI.Helpers.hasReqElecLvl(self) then return end

    local fuel   = H.getFuelPercentRaw(gen)
    local liters = H.getLiters(gen)         
    local hours  = H.getHoursRemaining(gen, fuel)

    drawHorizontalBar(self, fuel, liters, hours)
end
