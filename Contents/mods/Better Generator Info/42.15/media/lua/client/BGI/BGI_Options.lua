local MODULE_ID = "BetterGeneratorInfo"

BGI = BGI or {}
BGI.MODULE_ID = MODULE_ID

local core = getCore()
local defaultColor = core:getGoodHighlitedColor()

BGI.Options = {
    ReqElecLvl   = 0,
    ConvertToRT  = false,
    EnablePowerRangeOverlay = true,  -- Master switch for the overlay
    GeneratorOverlayColor = { r = defaultColor:getR(), g = defaultColor:getG(), b = defaultColor:getB(), a = 1.0 },
    UnionOverlayColor = { r = 0.690, g = 0.878, b = 0.902 , a = 1.0 },
}

function BGI.Options:getGenColor(alpha)
    local col = self.GeneratorOverlayColor
    return { r = col.r, g = col.g, b = col.b, a = alpha }
end

function BGI.Options:getUnionColor(alpha)
    local col = self.UnionOverlayColor
    return { r = col.r, g = col.g, b = col.b, a = alpha or col.a }
end

local PZOptions

local config = {
    ReqElecLvl   = nil,
    ConvertToRT  = nil,
    ShowFuelGauge = nil,
    EnablePowerRangeOverlay = nil,
    GeneratorOverlayColor = nil, 
    UnionOverlayColor = nil,
}

local function applyOptions()
    local options = PZAPI.ModOptions:getOptions(MODULE_ID)

    if options then
        BGI.Options.ReqElecLvl  = options:getOption("ReqElecLvl"):getValue()
        BGI.Options.ConvertToRT = options:getOption("ConvertToRT"):getValue()
        BGI.Options.ShowFuelGauge = options:getOption("ShowFuelGauge"):getValue()
        BGI.Options.EnablePowerRangeOverlay = options:getOption("EnablePowerRangeOverlay"):getValue()
        BGI.Options.GeneratorOverlayColor = options:getOption("GeneratorOverlayColor"):getValue()
        BGI.Options.UnionOverlayColor = options:getOption("UnionOverlayColor"):getValue()
    else
        print("BGI: Could not load saved settings.  Using defaults.")
    end
end

local function initConfig()
    PZOptions = PZAPI.ModOptions:create(MODULE_ID, getText("UI_BGI_Options_Title"))

    config.ReqElecLvl = PZOptions:addSlider(
        "ReqElecLvl",
        getText("UI_BGI_Options_ReqLevel"),
        0,
        10,
        1,
        BGI.Options.ReqElecLvl,
        getText("UI_BGI_Options_ReqLevel_Tooltip")
    )

    config.ConvertToRT = PZOptions:addTickBox(
        "ConvertToRT",
        getText("UI_BGI_Options_Convert"),
        BGI.Options.ConvertToRT,
        getText("UI_BGI_Options_Convert_Tooltip")
    )

    config.ShowFuelGauge = PZOptions:addTickBox(
        "ShowFuelGauge",
        getText("UI_BGI_Options_ShowGauge"),
        BGI.Options.ShowFuelGauge,
        getText("UI_BGI_Options_ShowGauge_Tooltip")
    )
    
    config.EnablePowerRangeOverlay = PZOptions:addTickBox(
        "EnablePowerRangeOverlay",
        getText("UI_BGI_Options_EnableOverlay"),
        BGI.Options.EnablePowerRangeOverlay,
        getText("UI_BGI_Options_EnableOverlay_Tooltip")
    )
    
    local p = BGI.Options.GeneratorOverlayColor
    config.GeneratorOverlayColor = PZOptions:addColorPicker(
        "GeneratorOverlayColor",
        getText("UI_BGI_Options_GeneratorOverlayColor"),
        p.r, p.g, p.b, p.a,
        getText("UI_BGI_Options_GeneratorOverlayColor_Tooltip")
    )
    
    local u = BGI.Options.UnionOverlayColor
    config.UnionOverlayColor = PZOptions:addColorPicker(
        "UnionOverlayColor",
        getText("UI_BGI_Options_UnionOverlayColor"),
        u.r, u.g, u.b, u.a,
        getText("UI_BGI_Options_UnionOverlayColor_Tooltip")
    )

    PZOptions.apply = function ()
        applyOptions()
    end
end

initConfig()

Events.OnMainMenuEnter.Add(function()
    applyOptions()
end)

return BGI.Options