--==========================================================
-- [BGI] Carried Generator Preview Overlay
--==========================================================
-- Draws a translucent generator power range ring around the player
-- while they are carrying a generator (in primary or secondary hand).
-- Reuses all exposed helpers from BGI_PowerRange.lua:
--   • drawEdgeList()
--   • ensureStencil()
--   • getPerGenColor()
--   • isOverlayEnabled()
--
-- This module runs independently of the Generator Info Window.
--==========================================================

if not BGI_PowerRange then
    DebugLog.log(DebugType.General, "[BGI] PowerRange module missing; preview overlay disabled.")
    return
end

local drawEdgeList     = BGI_PowerRange.drawEdgeList
local ensureStencil    = BGI_PowerRange.ensureStencil
local getPerGenColor   = BGI_PowerRange.getPerGenColor
local isOverlayEnabled = BGI_PowerRange.isOverlayEnabled

local _cache = { edges = {}, px = nil, py = nil, pz = nil, R = nil }

-- ----------------------------------------------------------
-- Helper: check if the player is holding a generator
-- ----------------------------------------------------------
local function isHoldingGenerator(player)
    if not player then return false end
    local prim = player:getPrimaryHandItem()
    local sec  = player:getSecondaryHandItem()
    if prim and prim.getType and prim:getType() == "Generator" then return true end
    if sec  and sec.getType  and sec:getType()  == "Generator" then return true end
    return false
end

-- ----------------------------------------------------------
-- Helper: build or reuse translated edge list
-- ----------------------------------------------------------
local function buildEdges(px, py, pz, R)
    local buf = _cache
    if buf.px == px and buf.py == py and buf.pz == pz and buf.R == R and #buf.edges > 0 then
        return buf.edges
    end

    ensureStencil(R, BGI_PowerRange.ProbePad or 0)
    local eo = BGI_Stencil.edgeOffsets
    local edges = buf.edges
    for i = 1, #edges do edges[i] = nil end
    for i = 1, #eo do
        local dx, dy = eo[i][1], eo[i][2]
        edges[#edges + 1] = { px + dx, py + dy }
    end

    buf.px, buf.py, buf.pz, buf.R = px, py, pz, R
    return edges
end

-- ----------------------------------------------------------
-- Event: draw live preview ring for held generators
-- ----------------------------------------------------------
Events.OnPlayerUpdate.Add(function(player)
    -- respect overlay master toggle
    if not isOverlayEnabled() then return end
    -- if main overlay active (window open), let it handle drawing
    if BGI_PowerRange.Enabled == true then return end
    if not (player and player:isLocalPlayer()) then return end
    if not isHoldingGenerator(player) then return end

    local sq = player:getSquare()
    if not sq then return end
    local px, py, pz = sq:getX(), sq:getY(), sq:getZ()
    local R = BGI_PowerRange:_getEffectiveTileRange()

    local edges = buildEdges(px, py, pz, R)
    if not edges or #edges == 0 then return end

    -- Slightly translucent “planning” color
    local c = getPerGenColor(true)
    local col = { r = c.r, g = c.g, b = c.b, a = math.max(0.02, (c.a or 0.08) * 0.75) }

    drawEdgeList(edges, pz, col)
end)

DebugLog.log(DebugType.General, "[BGI] Carried generator preview module initialized.")
