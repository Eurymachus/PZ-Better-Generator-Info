-- Purpose: One source of truth for generator fuel %, liters, consumption, and hover text.
-- ⚠️ Empirical — tested in Build 42.12: parsing "Total ... L/h" from getTotalPowerUsingString(). Requires in-game SP testing.

BGI = BGI or {}
BGI.Helpers = BGI.Helpers or {}

local H = BGI.Helpers
local O = require("BGI_Options")

if not O then
    print("BGI.Options Table NOT FOUND")
    return
end

function H.hasReqElecLvl()
  local minLevel  = O.ReqElecLvl
  if minLevel == 0 then
    return true
  else
    return getPlayer():getPerkLevel(Perks.Electricity) >= minLevel
  end
end

-- Uses window player when available, else getPlayer()
function BGI.Helpers.hasReqElecLvl(win)
  local min = (BGI.Options and BGI.Options.ReqElecLvl) or 0
  if min == 0 then return true end

  local p = (win and type(win.playerNum)=="number" and getSpecificPlayer(win.playerNum)) or getPlayer()
  if not p then return false end
  return p:getPerkLevel(Perks.Electricity) >= min
end

function H.getDayLength()
    return getSandboxOptions():getDayLengthMinutes()
end

function H.convertToRT(hoursDec)
    local realTime  = 60 * 24
    local dayLength = H.getDayLength()

    if dayLength ~= realTime then
        local hoursRT = hoursDec / 24 * dayLength / 60
        return hoursRT
    end
    return hoursDec
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Public: Fuel percent (0..100) as used by vanilla UI
-- ─────────────────────────────────────────────────────────────────────────────
function H.getFuelPercentRaw(gen)
    if not gen or not gen.getFuelPercentage then return 0 end
    local ok, pct = pcall(function() return gen:getFuelPercentage() end)
    if not ok or type(pct) ~= "number" then return 0 end
    if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end
    return pct
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Public: Liters (rounded 0.1) if engine exposes capacity/amount
-- ─────────────────────────────────────────────────────────────────────────────
function H.getLiters(gen)
    if not gen then return nil end
    local fuelPct = H.getFuelPercentRaw(gen)
    local TANK_LITRES = 10.0
    amt = (fuelPct / 100.0) * TANK_LITRES
    return amt
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Internal: read sandbox fuel multiplier (legacy %/h path)
-- ─────────────────────────────────────────────────────────────────────────────
local function getFuelMultiplier()
    local opt = getSandboxOptions() and getSandboxOptions():getOptionByName("GeneratorFuelConsumption")
    return (opt and opt.getValue and opt:getValue()) or 0.1
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Public: consumption as (value, unit)
--  - If we can parse "L/h" from Total string, return (lph, "lph")  [preferred in 42.12]
--  - Else use legacy %/h × sandbox multiplier → (pctph, "pctph")
-- ─────────────────────────────────────────────────────────────────────────────
function H.getLphOrPctPerHour(gen)
    if gen and gen.getTotalPowerUsingString then
        local s = gen:getTotalPowerUsingString() or ""
        -- Match "0.031 L/h" (accepts comma decimals)
        local num = type(s) == "string" and s:match("([%d%.,]+)%s*[Ll]/%s*[Hh]") or nil
        if num then
            num = num:gsub(",", ".")
            local lph = tonumber(num)
            if lph and lph > 0 then
                return lph, "lph"
            end
        end
    end

    -- Fallback: % per hour path
    local pctPerHour = 0
    if gen and gen.getTotalPowerUsing then
        local ok, v = pcall(function() return luautils.round(gen:getTotalPowerUsing(), 2) end)
        pctPerHour = (ok and type(v) == "number") and v or 0
    end
    return pctPerHour * getFuelMultiplier(), "pctph"
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Public: hours remaining (decimal). If convertToRT=true, adjusts for day length.
-- ─────────────────────────────────────────────────────────────────────────────
function H.getHoursRemaining(gen, fuelPct)
    fuelPct = math.max(0, math.min(100, fuelPct or 0))

    local cons, unit = H.getLphOrPctPerHour(gen)
    local hoursDec = 0

    if unit == "lph" then
        -- Capacity path: prefer getFuelAmount over inferring from %
        local amt = nil
        local okAmt, a = pcall(function() return gen.getFuelAmount and gen:getFuelAmount() end)
        if okAmt and type(a) == "number" then amt = a end

        if not amt then
            amt = H.getLiters(gen)
        end

        if cons > 0 then hoursDec = amt / cons end
    else
        local pctPerHour = cons or 0
        if pctPerHour > 0 then
            hoursDec = (fuelPct / 100.0) * (100.0 / pctPerHour)
        end
    end

    if O.ConvertToRT then
        hoursDec = H.convertToRT(hoursDec)
    end

    return hoursDec
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Public: consolidated hover text with translation fallbacks
-- ─────────────────────────────────────────────────────────────────────────────
function H.formatHover(percent, liters, hours)
    local p = tonumber(percent) or 0
    local l = (liters ~= nil) and tonumber(liters) or nil
    local h = (hours  ~= nil) and tonumber(hours)  or nil

    local pct  = string.format("%d", math.ceil(p))   -- no percent sign here; we add it in the translation with %1%
    local lits = l and string.format("%.1f", l) or nil
    local hrs  = h and string.format("%.1f", h) or nil

    if lits and hrs then
        return getText("UI_BGI_Fuel_Hover", pct, lits, hrs)
    elseif lits then
        return getText("UI_BGI_Fuel_HoverLiters", pct, lits)
    elseif hrs then
        return getText("UI_BGI_Fuel_HoverHours", pct, hrs) -- ← matches %2 in the key
    else
        return getText("UI_BGI_Fuel_HoverSimple", pct)
    end
end

return BGI.Helpers
