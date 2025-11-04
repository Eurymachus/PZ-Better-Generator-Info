local O = require("BGI_Options")

if not O then
  print("BGI Table NOT FOUND")
  return
end

BGI = BGI or {}

BGI.days      = 0
BGI.hours     = 0
BGI.hoursDec  = 0
BGI.hoursPct  = 0
BGI.debug     = false

local H = require("BGI_Helpers")

if not H then
  print("BGI.Helpers Table NOT FOUND")
  return
end

function BGI:_output(str)
  HaloTextHelper.addText(getPlayer(), tostring(str))
end

function BGI:_calcFuelLeft(generator, fuelPct)
  -- One source of truth:
  local hoursDec = H.getHoursRemaining(generator, fuelPct or 0)

  self.hoursDec = hoursDec or 0
  self.hours = math.floor(self.hoursDec)
  self.days  = math.floor(self.hours / 24)
  if self.days >= 1 then
    self.hours = self.hours % 24
  end

  if self.debug then
    -- Optional: keep your debug calc but now derive using the same consumption
    local cons, unit = H.getLphOrPctPerHour(generator)
    if cons and cons > 0 then
      if unit == "pctph" then
        -- approx hours gained per +1% fuel at current rate
        self.hoursPct = math.floor(((1.0 / cons) * 100) - self.hoursDec)
      else
        self.hoursPct = 0 -- not meaningful in L/h mode
      end
    end
  end
end

function BGI:toString(generator, fuel)
  local isNotActive = not generator:isActivated()

  if isNotActive or not H.hasReqElecLvl() then
    return ""
  end

  self:_calcFuelLeft(generator, fuel)

  local str = ""
  --#region New format and switch-case
  if self.days > 1 then
    if self.hours > 1 then
      str = string.format(
        " (%.0f %s, %.0f %s)",
        self.days, getText("Tooltip_BGI_Days"),
        self.hours, getText("Tooltip_BGI_Hours")
      )
    elseif self.hours == 1 then
      str = string.format(
        " (%.0f %s, %.0f %s)",
        self.days, getText("Tooltip_BGI_Days"),
        self.hours, getText("Tooltip_BGI_Hour")
      )
    else
      str = string.format(
        " (%.0f %s)",
        self.days, getText("Tooltip_BGI_Days")
      )
    end
  elseif self.days == 1 then
    if self.hours > 1 then
      str = string.format(
        " (%.0f %s, %.0f %s)",
        self.days, getText("Tooltip_BGI_Day"),
        self.hours, getText("Tooltip_BGI_Hours")
      )
    elseif self.hours == 1 then
      str = string.format(
        " (%.0f %s, %.0f %s)",
        self.days, getText("Tooltip_BGI_Day"),
        self.hours, getText("Tooltip_BGI_Hour")
      )
    else
      str = string.format(
        " (%.0f %s)",
        self.days, getText("Tooltip_BGI_Day")
      )
    end
  else
    if self.hours > 1 then
      str = string.format(
        " (%.0f %s)",
        self.hours, getText("Tooltip_BGI_Hours")
      )
    elseif self.hours == 1 then
      str = string.format(
        " (%.0f %s)",
        self.hours, getText("Tooltip_BGI_Hour")
      )
    else
      str = string.format(
        " (%.0f %s)",
        self.hoursDec * 60, getText("Tooltip_BGI_Minutes")
      )
    end
  end
  --#endregion

  return str
end

local _orig_getRichText = ISGeneratorInfoWindow.getRichText

function ISGeneratorInfoWindow.getRichText(object, displayStats)
	local square = object:getSquare()
	if not displayStats then
		local text = " <INDENT:10> "
		if square and not square:isOutside() and square:getBuilding() then
			text = text .. " <RED> " .. getText("IGUI_Generator_IsToxic")
		end
		return text
	end
  local fuelRaw    = H.getFuelPercentRaw(object)
  local fuelShow   = math.ceil(fuelRaw)
  local fuelLeft   = BGI:toString(object, fuelRaw)
	local condition = object:getCondition()
	local text = getText("IGUI_Generator_FuelAmount", fuelShow) .. fuelLeft .. " <LINE> " .. getText("IGUI_Generator_Condition", condition) .. " <LINE> "
	if object:isActivated() then
		text = text ..  " <LINE> " .. getText("IGUI_PowerConsumption") .. ": <LINE> ";
		text = text .. " <INDENT:10> "
		local items = object:getItemsPowered()
		for i=0,items:size()-1 do
			text = text .. "   " .. items:get(i) .. " <LINE> ";
		end
		text = text .. getText("IGUI_Generator_TypeGas") .. " (" .. object:getBasePowerConsumptionString()..") <LINE> "
		text = text .. getText("IGUI_Total") .. ": " .. object:getTotalPowerUsingString() .. " <LINE> ";
	end
	if square and not square:isOutside() and square:getBuilding() then
		text = text .. " <LINE> <RED> " .. getText("IGUI_Generator_IsToxic")
	end
	return text
end