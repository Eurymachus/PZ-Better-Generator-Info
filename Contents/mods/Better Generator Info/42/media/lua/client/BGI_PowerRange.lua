--[[--------------------------------------------------------------------
BGI_PowerRange.lua — Better Generator Info (BGI)
Build 42.x (SP)

Purpose
  • Show a per-generator power range ring even when the generator is OFF,
    using the engine's reach test: IsoGenerator.isPoweringSquare(...).
  • Draw the exact OUTER perimeter (unpowered tiles with ≥1 powered neighbour).
  • Optional union overlay (all currently powered tiles) in powder blue.

Notes
  • Colours: main ring uses getCore():getGoodHighlitedColor() / getBadHighlitedColor().
  • Union overlay is a custom powder blue with low alpha.
  • Rendering is an overlay (Lua cannot draw “behind” world sprites).
----------------------------------------------------------------------]]--

if BGI_PowerRange ~= nil then
    if BGI_PowerRange.Stop then BGI_PowerRange.Stop() end
end

BGI_PowerRange = {
    -- ===== Config =====
    PerGenAlpha          = 0.08,
    DefaultTileRange     = 20,           -- Fallback if SandboxVars.GeneratorTileRange is absent
    ProbePad             = 2,            -- Sweep R+pad tiles; ensures the OUTER ring lies within the scan
    GenVerticalLimit     = 3,
    UnionOverlayAlpha    = 0.28,
    UnionRefreshStride   = 120,          -- frames between union (haveElectricity) refreshes while visible
    -- Performance knobs
    UnionBuildCurrentZOnly = true,       -- build union edges only for the player's current Z
    -- Visual policy
    UnionProjectToCurrentZ = true,       -- If true, when building union for player Z with no gens on that Z, project all active gens onto player Z
    UnionRespectVerticalLimits = true,   -- When projecting: only include generators whose ΔZ to the target Z lies _BGI_withinVerticalLimits

    -- ===== Runtime =====
    Enabled              = false,
    TargetGen            = nil,          -- IsoGenerator
    ShowPerGen           = true,         -- user toggle (persisted per player) for the focused-gen ring
    ShowUnion            = false,        -- user toggle (persisted per player)
    PerGenEdgesByZ       = {},           -- [z] = { {x,y}, ... }
    UnionEdgesByZ        = {},           -- [z] = { {x,y}, ... }
    UnionPoweredByZ      = {},           -- [z] = set { ["x|y"]=true, ... } of powered tiles (persistent across frames)
    _needsPerGenRebuild  = false,
    _needsUnionRebuild   = false,
    _lastGenOnState      = nil,
    _unionGenStates      = {},           -- map[obj] = last seen isActivated() (true/false); drives state-change rebuilds
    _overridesApplied    = false,
    _unionPollTicker      = 0,           -- counts down to next ON/OFF poll while Union visible
    _lastPlayerZ         = nil,
}

-----------------------------------------------------------------------
-- Generator Registry (event-driven, Build 42.x, SP)
-- Keeps a list of loaded generators without scanning the world.
-- Safe Alternative — replaces predictive sniff/BFS.
-----------------------------------------------------------------------
local BGI_GenRegistry = {
    live = {},   -- array of { obj=IsoGenerator, x, y, z }
    byKey = {},  -- map "x|y|z" -> entry
}

local function _k3(x,y,z) return tostring(x).."|"..tostring(y).."|"..tostring(z or 0) end
local function _isGen(o) return o and instanceof and instanceof(o, "IsoGenerator") end

local function _addGen(obj)
    if not _isGen(obj) then return end
    local sq = obj:getSquare(); if not sq then return end
    local x,y,z = sq:getX(), sq:getY(), sq:getZ()
    local k = _k3(x,y,z)
    if BGI_GenRegistry.byKey[k] then return end
    local rec = { obj=obj, x=x, y=y, z=z }
    table.insert(BGI_GenRegistry.live, rec)
    BGI_GenRegistry.byKey[k] = rec
end

local function _removeGen(obj)
    if not _isGen(obj) then return end
    local sq = obj:getSquare(); if not sq then return end
    local k = _k3(sq:getX(), sq:getY(), sq:getZ())
    local rec = BGI_GenRegistry.byKey[k]; if not rec then return end
    BGI_GenRegistry.byKey[k] = nil
    for i=#BGI_GenRegistry.live,1,-1 do
        if BGI_GenRegistry.live[i] == rec then table.remove(BGI_GenRegistry.live,i); break end
    end
end

-- Public getters (don’t expose internals)
function BGI_GenRegistry.getAll()
    return BGI_GenRegistry.live
end

-- 8-neighbour offsets
local _BGI_NEIGHBORS = {
    {-1,-1},{0,-1},{1,-1},
    {-1, 0},       {1, 0},
    {-1, 1},{0, 1},{1, 1},
}

-----------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------

-- SP player
local function _BGI_getPlayer()
    if getSpecificPlayer then return getSpecificPlayer(0) end
    if getPlayer then return getPlayer() end
    return nil
end

-- True if targetZ lies within the vertical range (SandboxVar or fallback)
function BGI_PowerRange:_getEffectiveVerticalRange()
    local sv = rawget(_G, "SandboxVars")
    if sv and type(sv.GeneratorVerticalPowerRange) == "number" then
        return math.max(0, math.floor(sv.GeneratorVerticalPowerRange))
    end
    -- Fallback
    return self.GenVerticalLimit or 3
end

local function _BGI_withinVerticalLimits(genZ, targetZ)
    local vr = BGI_PowerRange:_getEffectiveVerticalRange()
    local zMin = math.max(0, genZ - vr)
    local zMax = genZ + vr
    return targetZ >= zMin and targetZ <= zMax
end

-- Global master switch (ModOptions): returns true when overlay is enabled
local function _BGI_isOverlayEnabled()
    local opts = rawget(_G, "BGI") and BGI.Options
    if opts and opts.EnablePowerRangeOverlay ~= nil then
        return opts.EnablePowerRangeOverlay == true
    end
    return true  -- default to ON if options aren't loaded yet
end

-- Per Gen Color (respects ON/OFF)
-- Inputs : isOn (boolean or nil)
-- Output : {r,g,b,a}
local function _BGI_PerGenCol(isOn)
    local alpha = BGI_PowerRange.PerGenAlpha or 0.08
    local opts  = rawget(_G, "BGI") and BGI.Options
    -- ON: use user colour if available; else core "good"
    if isOn == true then
        if opts and opts.getGenColor then
            local c = opts:getGenColor(alpha)
            if c then return c end
        end
        local good = getCore():getGoodHighlitedColor()
        return { r = good:getR(), g = good:getG(), b = good:getB(), a = alpha }
    end
    -- OFF: optional user off-colour; else core "bad"
    if opts and opts.getGenOffColor then
        local cOff = opts:getGenOffColor(alpha)
        if cOff then return cOff end
    end
    local bad = getCore():getBadHighlitedColor()
    return { r = bad:getR(), g = bad:getG(), b = bad:getB(), a = alpha }
end

-- Union Gen Color
local function _BGI_UnionGenCol()
    local opts = rawget(_G, "BGI") and BGI.Options
    if opts and opts.getUnionColor and opts:getUnionColor() ~= nil then
        return opts:getUnionColor(BGI_PowerRange.UnionOverlayAlpha)
    end
    return { r = 0.690, g = 0.878, b = 0.902, a = BGI_PowerRange.UnionOverlayAlpha } -- powder blue (#B0E0E6)
end

-- Effective generator tile range
function BGI_PowerRange:_getEffectiveTileRange()
    local sv = rawget(_G, "SandboxVars")
    if sv and type(sv.GeneratorTileRange) == "number" then
        return math.max(1, math.floor(sv.GeneratorTileRange))
    end
    return self.DefaultTileRange
end

-- Generator square & cell guard
local function _BGI_getGenSquareAndCell(gen)
    if not gen or not gen.getSquare then return nil, nil end
    local sq = gen:getSquare()
    if not sq then return nil, nil end
    local cell = getCell and getCell() or nil
    if not cell then return nil, nil end
    return sq, cell
end

-- True if we already have cached union edges for the given Z
local function _BGI_hasWarmUnionCache(z)
    local u = BGI_PowerRange and BGI_PowerRange.UnionEdgesByZ
    return (u and u[z] and #u[z] > 0) == true
end

-- Seed _unionGenStates from the current registry without causing rebuilds.
local function _BGI_seedUnionSnapshot()
    BGI_PowerRange._unionGenStates = BGI_PowerRange._unionGenStates or {}

    local gens = BGI_GenRegistry.getAll()  -- safe: BGI_GenRegistry is in scope now
    if not gens or #gens == 0 then return end

    for i = 1, #gens do
        local go = gens[i].obj
        if go and go.isActivated then
            BGI_PowerRange._unionGenStates[go] = (go:isActivated() == true)
        end
    end
end

-----------------------------------------------------------------------
-- Power Stencil (ΔZ = 0): precompute once per (R, ProbePad)
-- Reuses engine truth to build a reusable mask & edge offsets.
-----------------------------------------------------------------------
local BGI_Stencil = {
    keyR = nil, keyPad = nil,
    poweredOffsets = nil, -- array of {dx,dy}
    edgeOffsets    = nil, -- array of {dx,dy} (outer circumference)
}

local function _BGI_buildStencil(R, pad)
    local reach = R + (pad or 0)
    local minX, maxX = -reach, reach
    local minY, maxY = -reach, reach

    -- 1) Powered mask at origin (0,0, z=0)
    local powered = {}
    local poweredOffsets = {}
    for y = minY, maxY do
        powered[y] = {}
        for x = minX, maxX do
            local p = IsoGenerator.isPoweringSquare(0, 0, 0, x, y, 0) == true
            powered[y][x] = p
            if p then poweredOffsets[#poweredOffsets+1] = {x,y} end
        end
    end

    -- 2) Edge offsets (unpowered tiles touching any powered)
    local edgeOffsets = {}
    for y = minY, maxY do
        for x = minX, maxX do
            if not powered[y][x] then
                local touches = false
                for i = 1, #_BGI_NEIGHBORS do
                    local nx, ny = x + _BGI_NEIGHBORS[i][1], y + _BGI_NEIGHBORS[i][2]
                    if nx >= minX and nx <= maxX and ny >= minY and ny <= maxY then
                        if powered[ny][nx] then touches = true; break end
                    end
                end
                if touches then edgeOffsets[#edgeOffsets+1] = {x,y} end
            end
        end
    end

    BGI_Stencil.keyR, BGI_Stencil.keyPad = R, (pad or 0)
    BGI_Stencil.poweredOffsets = poweredOffsets
    BGI_Stencil.edgeOffsets    = edgeOffsets
end

local function _BGI_ensureStencil(R, pad)
    if BGI_Stencil.keyR ~= R or BGI_Stencil.keyPad ~= (pad or 0)
       or not BGI_Stencil.poweredOffsets or not BGI_Stencil.edgeOffsets then
        _BGI_buildStencil(R, pad)
    end
end

-- Key helpers for the sparse set
local function _k2(x,y) return tostring(x).."|"..tostring(y) end
local function _setHas(set, x, y) return set[_k2(x,y)] == true end
local function _setAdd(set, x, y) set[_k2(x,y)] = true end

-- Stamp one generator's powered offsets into a sparse powered set (bounds-clipped)
local function _BGI_stampGenToSet(set, baseX, baseY, minX, maxX, minY, maxY)
    local po = BGI_Stencil.poweredOffsets
    for i = 1, #po do
        local x = baseX + po[i][1]
        local y = baseY + po[i][2]
        if x >= minX and x <= maxX and y >= minY and y <= maxY then
            _setAdd(set, x, y)
        end
    end
end

-- Merge: keep existing edges outside bbox, replace inside with newEdges
local function _BGI_mergeEdgesReplaceInBox(oldEdges, newEdges, minX, maxX, minY, maxY)
    local out = {}
    if oldEdges then
        for i = 1, #oldEdges do
            local x, y = oldEdges[i][1], oldEdges[i][2]
            if not (x >= minX and x <= maxX and y >= minY and y <= maxY) then
                out[#out+1] = oldEdges[i]
            end
        end
    end
    for i = 1, #newEdges do out[#out+1] = newEdges[i] end
    return out
end

-- Event wiring (lightweight)
Events.LoadGridsquare.Add(function(sq)
    if not sq then return end
    local objs = sq:getObjects(); if not objs then return end
    local any = false
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if _isGen(o) then
            _addGen(o)
            -- seed snapshot so we don't trigger repeated diffs
            BGI_PowerRange._unionGenStates = BGI_PowerRange._unionGenStates or {}
            BGI_PowerRange._unionGenStates[o] = (o.isActivated and o:isActivated() == true) or false
            any = true
        end
    end
    if any then
        -- Localized: for each generator discovered on this square, apply a small-area update.
        if BGI_PowerRange and BGI_PowerRange.Enabled and BGI_PowerRange.ShowUnion then
            for i = 0, objs:size() - 1 do
                local o2 = objs:get(i)
                if _isGen(o2) then
                    BGI_PowerRange:_localizedUnionUpdateForGen(o2)
                end
            end
        else
            -- If overlay is hidden, just mark for a normal rebuild when shown.
            BGI_PowerRange._needsUnionRebuild = true
        end
    end
end)

Events.OnObjectAboutToBeRemoved.Add(function(o)
    -- DebugLog.log(DebugType.General, "[BGI] Object Removed: " .. tostring(o))
    if not _isGen(o) then return end
    _removeGen(o)
    if BGI_PowerRange._unionGenStates then BGI_PowerRange._unionGenStates[o] = nil end
    BGI_PowerRange._needsUnionRebuild = true
end)

-- NOTE: We deliberately do NOT purge on ReuseGridsquare:
-- You chose to "keep painting" already loaded powered tiles.
-- If you later want ghosting (coords-only snapshots), we can add it here.

-----------------------------------------------------------------------
-- Edge building (outer perimeter from a boolean map)
-----------------------------------------------------------------------

-- Build OUTER edge list (unpowered tiles that touch a powered tile) for a Z slice.
-- Returns an array of {x,y} coords (immutable; safe across unload/reload).
local function _BGI_buildOuterEdgeForZ(_cell_unused, _z, minX, maxX, minY, maxY, getPowered)
    local edges = {}

    -- Memoize per-rebuild: each (x,y) is evaluated once
    local memo = {}
    local function gp(x, y)
        local ry = y - minY
        local rx = x - minX
        local row = memo[ry]; if not row then row = {}; memo[ry] = row end
        local v = row[rx]
        if v == nil then
            v = getPowered(x, y) and true or false
            row[rx] = v
        end
        return v
    end

    for y = minY, maxY do
        for x = minX, maxX do
            if not gp(x, y) then
                local touchesPowered = false
                for i = 1, #_BGI_NEIGHBORS do
                    local nx, ny = x + _BGI_NEIGHBORS[i][1], y + _BGI_NEIGHBORS[i][2]
                    if nx >= minX and nx <= maxX and ny >= minY and ny <= maxY then
                        if gp(nx, ny) then touchesPowered = true; break end
                    end
                end
                if touchesPowered then
                    edges[#edges + 1] = { x, y } -- store coordinates only
                end
            end
        end
    end
    return edges
end

-----------------------------------------------------------------------
-- Rebuild per-generator edge cache using the engine reach test
-----------------------------------------------------------------------

function BGI_PowerRange:_rebuildPerGenEdges()
    --- Rebuilds the focused generator's ring cache and (optionally) mirrors it onto the player's Z.
    --- Inputs : self.TargetGen (IsoGenerator), self.PerGenEdgesByZ (table)
    --- Output : self.PerGenEdgesByZ[z] = { {x,y}, ... } for relevant z-slices (player Z + gen Z)
    local genSq, cell = _BGI_getGenSquareAndCell(self.TargetGen)
    if not genSq then
        self.PerGenEdgesByZ = {}
        self._needsPerGenRebuild = false
        return
    end

    local gx, gy, gz = genSq:getX(), genSq:getY(), genSq:getZ()
    local R   = self:_getEffectiveTileRange()
    local pad = (self.ProbePad or 0)

    -- Ensure stencil (ΔZ=0)
    _BGI_ensureStencil(R, pad)

    -- Build edges at generator coords once
    local builtEdges = {}
    for i = 1, #BGI_Stencil.edgeOffsets do
        local dx, dy = BGI_Stencil.edgeOffsets[i][1], BGI_Stencil.edgeOffsets[i][2]
        builtEdges[#builtEdges+1] = { gx + dx, gy + dy }
    end

    -- Reset and populate gen Z
    self.PerGenEdgesByZ = {}
    self.PerGenEdgesByZ[gz] = builtEdges

    -- Mirror to player's current Z always (visual guide only; engine power remains ΔZ-limited)
    -- We still colour based on “powers this Z” in _drawCurrentZ().
    do
        local p = _BGI_getPlayer()
        local pz = (p and p.getZ) and p:getZ() or nil
        if pz ~= nil and pz ~= gz then
            local copy = {}
            for i = 1, #builtEdges do
                local e = builtEdges[i]; copy[i] = { e[1], e[2] }
            end
            self.PerGenEdgesByZ[pz] = copy
        end
    end

    self._needsPerGenRebuild = false
end

-- Rebuild union (event-driven): union of ALL eligible (activated && connected) gens via stencil stamping.
function BGI_PowerRange:_rebuildUnionEdges(onlyZ)
    --- Rebuilds union edges for a Z slice (or a span). If UnionProjectToCurrentZ is true and we are
    --- asked to build the player's current Z but no active generators exist on that Z, we project
    --- all active generators' coverage onto the player's Z (same x,y) for visual guidance.
    local genSq, _cell = _BGI_getGenSquareAndCell(self.TargetGen)
    if not genSq then
        self.UnionEdgesByZ = {}
        self.UnionPoweredByZ = {}
        self._needsUnionRebuild = false
        return
    end

    local seedGX, seedGY, seedGZ = genSq:getX(), genSq:getY(), genSq:getZ()
    local R   = self:_getEffectiveTileRange()
    local pad = (self.ProbePad or 0)
    local reachBox = R + pad

    _BGI_ensureStencil(R, pad)

    local gens = BGI_GenRegistry.getAll()
    if not gens or #gens == 0 then
        self.UnionEdgesByZ = {}
        self.UnionPoweredByZ = {}
        self._needsUnionRebuild = false
        return
    end

    -- Eligible = activated && connected
    local active = {}
    for i = 1, #gens do
        local g  = gens[i]
        local go = g.obj
        if go and go.isActivated and go:isActivated() == true then
            active[#active+1] = g
        end
    end
    if #active == 0 then
        self.UnionEdgesByZ = {}
        self.UnionPoweredByZ = {}
        self._needsUnionRebuild = false
        return
    end

    -- Figure out build range (by default: limited span around the selected gen)
    local vr   = self:_getEffectiveVerticalRange()
    local zMin = math.max(0, seedGZ - vr)
    local zMax = seedGZ + vr
    local buildZmin, buildZmax
    if onlyZ ~= nil then buildZmin, buildZmax = onlyZ, onlyZ else buildZmin, buildZmax = zMin, zMax end

    self.UnionEdgesByZ   = self.UnionEdgesByZ or {}
    self.UnionPoweredByZ = self.UnionPoweredByZ or {}

    -- Helper: compute an AABB that covers a list of generator records (on any Z)
    local function computeAABBForGens(genList)
        local minX, maxX = seedGX - reachBox, seedGX + reachBox
        local minY, maxY = seedGY - reachBox, seedGY + reachBox
        for i = 1, #genList do
            local g = genList[i]
            local gMinX, gMaxX = g.x - reachBox, g.x + reachBox
            local gMinY, gMaxY = g.y - reachBox, g.y + reachBox
            if gMinX < minX then minX = gMinX end
            if gMaxX > maxX then maxX = gMaxX end
            if gMinY < minY then minY = gMinY end
            if gMaxY > maxY then maxY = gMaxY end
        end
        return minX, maxX, minY, maxY
    end

    for z = buildZmin, buildZmax do
        -- 1) Check if there are any active generators on this Z
        local anyOnZ = false
        for i = 1, #active do
            if active[i].z == z then anyOnZ = true; break end
        end

        local projectForPlayerZ = false
        do
            -- If we're explicitly building the player's current Z but no gens are on this Z,
            -- we can project the union visually onto this Z if allowed by policy.
            local p = _BGI_getPlayer()
            local pz = (p and p.getZ) and p:getZ() or nil
            if pz ~= nil and z == pz and not anyOnZ and (self.UnionProjectToCurrentZ == true) then
                projectForPlayerZ = true
            end
        end

        if not anyOnZ and not projectForPlayerZ then
            -- Nothing to stamp here (and not projecting) → empty slice
            self.UnionEdgesByZ[z]   = {}
            self.UnionPoweredByZ[z] = {}
        else
            -- 2) Build powered set
            local poweredSet = {}
            local minX, maxX, minY, maxY

            local skipCompute = false

            if projectForPlayerZ then
                -- Project onto the player's Z. Optionally respect vertical limits.
                local listProjected = active
                if self.UnionRespectVerticalLimits == true then
                    listProjected = {}
                    for i = 1, #active do
                        local g = active[i] -- {obj, x, y, z}
                        if _BGI_withinVerticalLimits(g.z, z) then
                            listProjected[#listProjected+1] = g
                        end
                    end
                end

                if #listProjected == 0 then
                    -- Nothing eligible to project onto this Z. Mark empty and skip edge build.
                    self.UnionEdgesByZ[z]   = {}
                    self.UnionPoweredByZ[z] = {}
                    skipCompute = true
                else
                    minX, maxX, minY, maxY = computeAABBForGens(listProjected)
                    for i = 1, #listProjected do
                        local g = listProjected[i]
                        _BGI_stampGenToSet(poweredSet, g.x, g.y, minX, maxX, minY, maxY)
                    end
                end
            else
                -- Normal: only generators actually on this Z
                local listOnZ = {}
                for i = 1, #active do if active[i].z == z then listOnZ[#listOnZ+1] = active[i] end end
                if #listOnZ == 0 then
                    self.UnionEdgesByZ[z]   = {}
                    self.UnionPoweredByZ[z] = {}
                    skipCompute = true
                else
                    minX, maxX, minY, maxY = computeAABBForGens(listOnZ)
                    for i = 1, #listOnZ do
                        local g = listOnZ[i]
                        _BGI_stampGenToSet(poweredSet, g.x, g.y, minX, maxX, minY, maxY)
                    end
                end
            end

            -- 3) Edge from powered set (only if we stamped anything)
            if not skipCompute then
                local function getPowered(x, y) return _setHas(poweredSet, x, y) end
                local edges = _BGI_buildOuterEdgeForZ(nil, z, minX, maxX, minY, maxY, getPowered)

                -- 4) Hide selected-gen coverage when it's ON on its native Z only (unchanged rule)
                local selOn = self.TargetGen and self.TargetGen.isActivated and self.TargetGen:isActivated()
                if selOn and not projectForPlayerZ and z == seedGZ then
                    local filtered = {}
                    for i = 1, #edges do
                        local x, y = edges[i][1], edges[i][2]
                        local covered = false
                        for k = 1, #BGI_Stencil.poweredOffsets do
                            local dx, dy = BGI_Stencil.poweredOffsets[k][1], BGI_Stencil.poweredOffsets[k][2]
                            if x == seedGX + dx and y == seedGY + dy then covered = true; break end
                        end
                        if not covered then filtered[#filtered+1] = edges[i] end
                    end
                    edges = filtered
                end

                self.UnionPoweredByZ[z] = poweredSet
                self.UnionEdgesByZ[z]   = edges
            end
        end
    end

    self._needsUnionRebuild = false
end

-- Localized union update for a single generator that just became available.
-- Fast path: stamps into the persistent powered set and recomputes edges only in the gen's AABB.
function BGI_PowerRange:_localizedUnionUpdateForGen(gen)
    if not (gen and gen.getSquare and gen.isActivated) then return end
    if gen:isActivated() ~= true then return end
    local sq = gen:getSquare(); if not sq then return end

    local gx, gy, gz = sq:getX(), sq:getY(), sq:getZ()
    local R   = self:_getEffectiveTileRange()
    local pad = (self.ProbePad or 0)
    local reachBox = R + pad

    _BGI_ensureStencil(R, pad)

    self.UnionPoweredByZ = self.UnionPoweredByZ or {}
    self.UnionEdgesByZ   = self.UnionEdgesByZ   or {}

    -- If we don't have a powered set for this Z yet, fall back to a full rebuild (once).
    local setZ = self.UnionPoweredByZ[gz]
    if not setZ then
        -- Build only current Z to seed the map
        self:_rebuildUnionEdges(gz)
        setZ = self.UnionPoweredByZ[gz]
        if not setZ then return end
    end

    -- 1) Stamp this generator into the set (clip to a local bbox)
    local minX, maxX = gx - reachBox, gx + reachBox
    local minY, maxY = gy - reachBox, gy + reachBox
    _BGI_stampGenToSet(setZ, gx, gy, minX, maxX, minY, maxY)

    -- 2) Rebuild edges only inside the affected bbox (+1 tile padding for correctness)
    local bxMin, bxMax = minX - 1, maxX + 1
    local byMin, byMax = minY - 1, maxY + 1
    local function getPoweredLocal(x, y) return _setHas(setZ, x, y) end
    local newEdges = _BGI_buildOuterEdgeForZ(nil, gz, bxMin, bxMax, byMin, byMax, getPoweredLocal)

    -- 3) Apply selected-gen hide rule locally if needed
    local seedSq = self.TargetGen and self.TargetGen.getSquare and self.TargetGen:getSquare() or nil
    if seedSq and self.TargetGen.isActivated and self.TargetGen:isActivated() and seedSq:getZ() == gz then
        local sx, sy = seedSq:getX(), seedSq:getY()
        local filtered = {}
        for i = 1, #newEdges do
            local x, y = newEdges[i][1], newEdges[i][2]
            local covered = false
            for k = 1, #BGI_Stencil.poweredOffsets do
                local dx, dy = BGI_Stencil.poweredOffsets[k][1], BGI_Stencil.poweredOffsets[k][2]
                if x == sx + dx and y == sy + dy then covered = true; break end
            end
            if not covered then filtered[#filtered+1] = newEdges[i] end
        end
        newEdges = filtered
    end

    -- 4) Merge into UnionEdges for this Z (replace edges inside bbox)
    local old = self.UnionEdgesByZ[gz] or {}
    self.UnionEdgesByZ[gz] = _BGI_mergeEdgesReplaceInBox(old, newEdges, bxMin, bxMax, byMin, byMax)
end

-----------------------------------------------------------------------
-- Drawing
-----------------------------------------------------------------------

-- Draw one Z-slice of the edges with the provided colour (table .r .g .b .a)
-- Now edges are stored as immutable {x,y} coords (not IsoGridSquare objects),
-- so drawing is chunk/load agnostic (no hitches, no gaps).
local function _BGI_drawEdgeList(edgeList, z, color)
    if not edgeList or #edgeList == 0 then return end
    local r, g, b, a = color.r, color.g, color.b, color.a
    for i = 1, #edgeList do
        local e = edgeList[i]
        if e then
            local x, y = e[1], e[2]
            addAreaHighlight(x, y, x + 1, y + 1, z, r, g, b, a)
        end
    end
end

-- Draw overlays for the player's current Z
function BGI_PowerRange:_drawCurrentZ()
    if not _BGI_isOverlayEnabled() then return end
    local p = _BGI_getPlayer(); if not p or not p.getZ then return end
    local z = p:getZ()

    -- Micro-opt: if neither list has entries for this Z, skip work altogether
    local hasUnion = self.ShowUnion and self.UnionEdgesByZ and self.UnionEdgesByZ[z] and #self.UnionEdgesByZ[z] > 0
    local hasPer   = self.ShowPerGen and self.PerGenEdgesByZ and self.PerGenEdgesByZ[z] and #self.PerGenEdgesByZ[z] > 0
    if not hasUnion and not hasPer then return end

    -- 1) Union overlay first (optional, powder blue)
    if hasUnion then
        local col = _BGI_UnionGenCol()
        _BGI_drawEdgeList(self.UnionEdgesByZ[z], z, col)
    end

    -- 2) Per-generator ring on top (colour by “does this gen power THIS Z?”)
    if hasPer then
        local isOn = self.TargetGen and self.TargetGen.isActivated and self.TargetGen:isActivated() or false

        -- Determine if the focused generator powers the player's current Z.
        local powersThisZ = false
        do
            local gsq = self.TargetGen and self.TargetGen.getSquare and self.TargetGen:getSquare() or nil
            if gsq then
                local gz = gsq:getZ()
                -- Powers this Z only if same Z OR within vertical limits.
                powersThisZ = (z == gz) or _BGI_withinVerticalLimits(gz, z)  -- uses helper from Helpers section
            end
        end

        -- If the gen is ON but doesn’t power this Z, treat as OFF for colour choice.
        local color = _BGI_PerGenCol(isOn and powersThisZ)
        _BGI_drawEdgeList(self.PerGenEdgesByZ[z], z, color)
    end
end

-----------------------------------------------------------------------
-- Public API
-----------------------------------------------------------------------

function BGI_PowerRange.Start(gen)
    BGI_PowerRange.Enabled             = true
    BGI_PowerRange.TargetGen           = gen or BGI_PowerRange.TargetGen
    BGI_PowerRange._needsPerGenRebuild = true

    -- Only request Union rebuild if there is no warm cache for the player's current Z
    local p = _BGI_getPlayer()
    local z = (p and p.getZ) and p:getZ() or nil
    if z ~= nil and _BGI_hasWarmUnionCache(z) then
        BGI_PowerRange._needsUnionRebuild = false
    else
        BGI_PowerRange._needsUnionRebuild = true
    end

    BGI_PowerRange._lastGenOnState = nil
    _BGI_seedUnionSnapshot()  -- no false diffs on open

    -- Remember the player's current Z on open and warm the union cache for that Z.
    do
        local p  = _BGI_getPlayer()
        local pz = (p and p.getZ) and p:getZ() or nil
        BGI_PowerRange._lastPlayerZ = pz

        -- If Union is intended to be visible (or could be toggled), ensure the current Z is ready.
        -- We warm the cache unconditionally so toggling ON is instant.
        if pz ~= nil then
            BGI_PowerRange:_rebuildUnionEdges(pz)   -- build current-Z only
            BGI_PowerRange._needsUnionRebuild = false
        else
            BGI_PowerRange._needsUnionRebuild = true
        end
    end

    -- Load persisted toggle (per player)
    local p = _BGI_getPlayer()
    if p and p.getModData then
        local md = p:getModData()
        if md and md.BGI_ShowUnion ~= nil then
            BGI_PowerRange.ShowUnion = md.BGI_ShowUnion == true
        end
        if md and md.BGI_ShowPerGen ~= nil then
            BGI_PowerRange.ShowPerGen = md.BGI_ShowPerGen == true
        end
    end
end

function BGI_PowerRange.Stop()
    BGI_PowerRange.Enabled             = false
    BGI_PowerRange.TargetGen           = nil
    BGI_PowerRange.PerGenEdgesByZ      = {}
    BGI_PowerRange.UnionEdgesByZ       = {}
    BGI_PowerRange._needsPerGenRebuild = false
    BGI_PowerRange._needsUnionRebuild  = false
    BGI_PowerRange._lastGenOnState     = nil
    BGI_PowerRange._unionGenStates     = nil
end

function BGI_PowerRange.SetTargetGenerator(gen)
    if BGI_PowerRange.TargetGen ~= gen then
        BGI_PowerRange.TargetGen           = gen
        BGI_PowerRange._needsPerGenRebuild = true
        BGI_PowerRange._needsUnionRebuild  = true
        BGI_PowerRange._unionGenStates     = nil
    end
end

-- Called each frame from the window's prerender override
function BGI_PowerRange.Update()
    if not BGI_PowerRange.Enabled then return end
    -- Master switch via ModOptions
    if not _BGI_isOverlayEnabled() then
        return  -- no rebuilds, no drawing
    end

    local gen = BGI_PowerRange.TargetGen
    if not gen then return end

    -- Floor change: rebuild union for the new Z immediately (warm cache), and refresh per-gen projection.
    do
        local p    = _BGI_getPlayer()
        local curZ = (p and p.getZ) and p:getZ() or nil
        if curZ ~= nil and curZ ~= BGI_PowerRange._lastPlayerZ then
            BGI_PowerRange._lastPlayerZ = curZ

            -- Rebuild union edges for THIS Z so a later toggle-on is instant and drawing stays correct.
            BGI_PowerRange:_rebuildUnionEdges(curZ)
            BGI_PowerRange._needsUnionRebuild = false

            -- Also refresh the per-gen ring so projection appears on the new floor if needed.
            BGI_PowerRange._needsPerGenRebuild = true
        end
    end

    -- Rebuild per-gen edges on ON/OFF flip or when flagged dirty
    local isOn = gen:isActivated()
    if BGI_PowerRange._lastGenOnState == nil or BGI_PowerRange._lastGenOnState ~= isOn then
        BGI_PowerRange._lastGenOnState     = isOn
        BGI_PowerRange._needsPerGenRebuild = true
        -- union can also change if live power changes; we'll refresh on stride below
    end

    -- Rebuild per-gen ring only if shown (works when OFF via reach test)
    if BGI_PowerRange.ShowPerGen and BGI_PowerRange._needsPerGenRebuild then
        BGI_PowerRange:_rebuildPerGenEdges()
    end

    -- Union refresh policy (single scan, stride-gated)
    if BGI_PowerRange.ShowUnion then
        local need = BGI_PowerRange._needsUnionRebuild

        -- Poll ON/OFF only every UnionRefreshStride frames to avoid overhead
        BGI_PowerRange._unionPollTicker = (BGI_PowerRange._unionPollTicker or 0) - 1
        local shouldPoll = (BGI_PowerRange._unionPollTicker <= 0)

        if not need and shouldPoll then
            local gens = BGI_GenRegistry.getAll()
            if gens and #gens > 0 then
                for i = 1, #gens do
                    local go = gens[i].obj
                    if go and go.isActivated then
                        local cur  = (go:isActivated() == true)
                        local prev = BGI_PowerRange._unionGenStates and BGI_PowerRange._unionGenStates[go]
                        -- Only trigger rebuild on a real change (prev ~= nil and prev ~= cur)
                        if prev ~= nil and prev ~= cur then
                            need = true
                            break
                        end
                        -- Update snapshot (initial seeding or steady-state)
                        BGI_PowerRange._unionGenStates = BGI_PowerRange._unionGenStates or {}
                        BGI_PowerRange._unionGenStates[go] = cur
                    end
                end
            end
            -- Reset stride ticker (use at least 1 to avoid negative churn)
            BGI_PowerRange._unionPollTicker = math.max(1, (BGI_PowerRange.UnionRefreshStride or 120))
        end

        if need then
            local p = _BGI_getPlayer()
            local z = (p and p.getZ) and p:getZ() or nil
            BGI_PowerRange:_rebuildUnionEdges(z)
            BGI_PowerRange._needsUnionRebuild = false
        end
    end
    BGI_PowerRange:_drawCurrentZ()
end

-----------------------------------------------------------------------
-- UI integration: ISGeneratorInfoWindow overrides + checkbox
-----------------------------------------------------------------------
do
    if ISGeneratorInfoWindow and not BGI_PowerRange._overridesApplied then

        -- Create / place our checkbox once UI children exist
        local _legacy_createChildren = ISGeneratorInfoWindow.createChildren
        function ISGeneratorInfoWindow:createChildren()
            if _legacy_createChildren then _legacy_createChildren(self) end

            -- === Title-bar toggle button for Union Overlay ===
            if not self.bgiUnionBtn then
                -- Small text label; keep it short so it fits in the title bar
                local label = getText and getText("UI_BGI_ShowAllPowered_Short") or "All"

                -- Create a tiny title-bar button; size auto-fits the text
                local txtW = getTextManager() and getTextManager():MeasureStringX(UIFont.Small, label) or 18
                local btnW, btnH = math.max(26, txtW + 8), 18
                self.bgiUnionBtn = ISButton:new(0, 0, btnW, btnH, label, self,
                    function()
                        if not _BGI_isOverlayEnabled() then return end
                        local turningOn = not (BGI_PowerRange.ShowUnion == true)
                        BGI_PowerRange.ShowUnion = turningOn

                        -- Persist per-player
                        local p = _BGI_getPlayer()
                        if p and p.getModData then p:getModData().BGI_ShowUnion = turningOn end

                        if turningOn then
                            local p = _BGI_getPlayer()
                            local z = (p and p.getZ) and p:getZ() or nil
                            -- Only rebuild if no warm cache exists for the current Z
                            if z == nil or not _BGI_hasWarmUnionCache(z) then
                                BGI_PowerRange._needsUnionRebuild = true
                            else
                                BGI_PowerRange._needsUnionRebuild = false
                            end
                        else
                            -- Turning OFF: keep cache; do nothing.
                        end
                    end
                )
                self.bgiUnionBtn:initialise()
                self.bgiUnionBtn:instantiate()
                self.bgiUnionBtn.borderColor = { r=1, g=1, b=1, a=0.5 }
                self.bgiUnionBtn.tooltip = getText and getText("UI_BGI_ShowAllPowered_Tooltip")
                    or "Outline tiles powered by all nearby active generators."
                self:addChild(self.bgiUnionBtn)
            end
            
            -- === Title-bar toggle button for Per-Gen Ring ===
            if not self.bgiThisBtn then
                local labelThis = getTextOrNull and getTextOrNull("UI_BGI_ShowThis_Short") or "This"
                local txtW2 = getTextManager() and getTextManager():MeasureStringX(UIFont.Small, labelThis) or 20
                local btnW2, btnH2 = math.max(28, txtW2 + 8), 18
                self.bgiThisBtn = ISButton:new(0, 0, btnW2, btnH2, labelThis, self,
                    function()
                        if not _BGI_isOverlayEnabled() then return end
                        local turningOn = not (BGI_PowerRange.ShowPerGen == true)
                        BGI_PowerRange.ShowPerGen = turningOn
                        local p = _BGI_getPlayer()
                        if p and p.getModData then p:getModData().BGI_ShowPerGen = turningOn end
                        if turningOn then
                            BGI_PowerRange._needsPerGenRebuild = true
                        else
                            -- optional: drop cached edges to free memory
                            BGI_PowerRange.PerGenEdgesByZ = {}
                        end
                    end
                )
                self.bgiThisBtn:initialise()
                self.bgiThisBtn:instantiate()
                self.bgiThisBtn.borderColor = { r=1, g=1, b=1, a=0.5 }
                self.bgiThisBtn.tooltip = getTextOrNull and getTextOrNull("UI_BGI_ShowThis_Tooltip") or "Outline tiles powered by this generator"
                    or "Show the range of this generator."
                self:addChild(self.bgiThisBtn)
            end
        end

        -- Keep the checkbox anchored to the bottom; drive Update()
        local _legacy_prerender = ISGeneratorInfoWindow.prerender
        function ISGeneratorInfoWindow:prerender()
            local overlayEnabled = _BGI_isOverlayEnabled()
            if self.bgiUnionBtn then self.bgiUnionBtn:setVisible(overlayEnabled) end
            if self.bgiThisBtn  then self.bgiThisBtn:setVisible(overlayEnabled)  end
            if not overlayEnabled then
                BGI_PowerRange.Update(); if _legacy_prerender then _legacy_prerender(self) end
                return
            end

            -- Shared metrics
            local tbH = 20
            if self.titleBarHeight ~= nil then
                tbH = (type(self.titleBarHeight)=="function") and self:titleBarHeight()
                or (type(self.titleBarHeight)=="number"   and self.titleBarHeight or tbH)
            end
            local rightGutter = 56
            local rightLimit  = self:getWidth() - rightGutter

            -- Union button
            if self.bgiUnionBtn then
                self.bgiUnionBtn:setY(math.max(1, math.floor((tbH - self.bgiUnionBtn:getHeight())/2)))
                self.bgiUnionBtn:setX(math.max(4, rightLimit - self.bgiUnionBtn:getWidth()))
                -- tinting...
            end

            -- THIS button (reuse Union Y; fallback to tbH math)
            if self.bgiThisBtn then
                self.bgiThisBtn:setY(self.bgiUnionBtn and self.bgiUnionBtn:getY()
                    or math.max(1, math.floor((tbH - self.bgiThisBtn:getHeight())/2)))
                local unionX = self.bgiUnionBtn and self.bgiUnionBtn:getX() or rightLimit
                self.bgiThisBtn:setX(math.max(4, unionX - 4 - self.bgiThisBtn:getWidth()))
            end

            BGI_PowerRange.Update(); if _legacy_prerender then _legacy_prerender(self) end
        end

        -- Set object (selected generator) and mirror checkbox from persisted state
        local _legacy_setObject = ISGeneratorInfoWindow.setObject
        function ISGeneratorInfoWindow:setObject(object)
            BGI_PowerRange.SetTargetGenerator(object)
            -- Mirror persisted state to the toggle (no callback)
            if self.bgiUnionBtn then
                local p = _BGI_getPlayer()
                local persisted = p and p.getModData and p:getModData().BGI_ShowUnion or nil
                BGI_PowerRange.ShowUnion = (persisted == true)
                if BGI_PowerRange.ShowUnion then
                    local p = _BGI_getPlayer()
                    local z = (p and p.getZ) and p:getZ() or nil
                    if z ~= nil and _BGI_hasWarmUnionCache(z) then
                        BGI_PowerRange._needsUnionRebuild = false
                    else
                        BGI_PowerRange._needsUnionRebuild = true
                    end
                else
                    BGI_PowerRange._needsUnionRebuild = false
                end
            end
            if _legacy_setObject then return _legacy_setObject(self, object) end
        end

        -- Start/Stop overlay with window visibility
        local _legacy_setVisible = ISGeneratorInfoWindow.setVisible
        function ISGeneratorInfoWindow:setVisible(visible, ...)
            if visible then
                BGI_PowerRange.Start(self and self.object or nil)
                if self.bgiUnionBtn then
                    local p = _BGI_getPlayer()
                    local persisted = p and p.getModData and p:getModData().BGI_ShowUnion or nil
                    BGI_PowerRange.ShowUnion = (persisted == true)
                    if BGI_PowerRange.ShowUnion then
                        local z = (p and p.getZ) and p:getZ() or nil
                        if z ~= nil and _BGI_hasWarmUnionCache(z) then
                            BGI_PowerRange._needsUnionRebuild = false
                        else
                            BGI_PowerRange._needsUnionRebuild = true
                        end
                    else
                        BGI_PowerRange._needsUnionRebuild = false
                    end
                end
            else
                BGI_PowerRange.Stop()
            end
            if _legacy_setVisible then
                return _legacy_setVisible(self, visible, ...)
            end
        end

        -- Ensure stop on close
        local _legacy_remove = ISGeneratorInfoWindow.removeFromUIManager
        function ISGeneratorInfoWindow:removeFromUIManager()
            BGI_PowerRange.Stop()
            if _legacy_remove then return _legacy_remove(self) end
        end

        BGI_PowerRange._overridesApplied = true
    end
end

-- Build 42.x — Safe Alternative: hook generator connect/disconnect + activate/deactivate
-- Purpose: keep registry in sync and rebuild union exactly once on real changes.

-- Ensure classes exist
if not ISPlugGenerator then require "TimedActions/ISPlugGenerator" end
if not ISActivateGenerator then require "TimedActions/ISActivateGenerator" end

-- Helper: ensure a gen is present in the registry (by square key)
local function _BGI_ensureGenRegistered(gen)
    if not gen or not gen.getSquare then return false end
    local sq = gen:getSquare(); if not sq then return false end
    local key = tostring(sq:getX()) .. "|" .. tostring(sq:getY()) .. "|" .. tostring(sq:getZ() or 0)
    if not BGI_GenRegistry.byKey[key] then
        _addGen(gen)
        return true
    end
    return false
end

-- Helper: schedule a single union rebuild (and warm cache if hidden)
local function _BGI_requestUnionRebuild()
    BGI_PowerRange._needsUnionRebuild = true
    if not BGI_PowerRange.ShowUnion then
        local p = _BGI_getPlayer()
        local onlyZ = (BGI_PowerRange.UnionBuildCurrentZOnly and p and p.getZ) and p:getZ() or nil
        BGI_PowerRange:_rebuildUnionEdges(onlyZ)
    end
end

-- ========== Connect / Disconnect ==========
do
    if ISPlugGenerator and not ISPlugGenerator._BGI_wrapComplete then
        local _oldComplete = ISPlugGenerator.complete

        --- Runs when the connect/disconnect timed action completes.
        function ISPlugGenerator:complete()
            local ok = _oldComplete(self) -- vanilla sets setConnected(self.plug)
            local gen = self.generator
            if gen then
                -- Make sure it’s tracked (covers cases where add didn’t fire)
                _BGI_ensureGenRegistered(gen)

                -- Seed/update activation snapshot (connection may gate eligibility)
                BGI_PowerRange._unionGenStates = BGI_PowerRange._unionGenStates or {}
                BGI_PowerRange._unionGenStates[gen] = (gen.isActivated and gen:isActivated() == true) or false

                -- Rebuild union once (connected → include; disconnected → exclude)
                _BGI_requestUnionRebuild()
            end
            return ok
        end

        ISPlugGenerator._BGI_wrapComplete = true
    end
end

-- ========== Activate / Deactivate ==========
do
    if ISActivateGenerator and not ISActivateGenerator._BGI_wrapComplete then
        local _oldComplete = ISActivateGenerator.complete

        --- Runs when the power toggle timed action completes (setActivated + sync).
        function ISActivateGenerator:complete()
            local ok = _oldComplete(self)
            local gen = self.generator
            if gen and gen.isActivated then
                -- Ensure listed & seed snapshot to “current truth”
                _BGI_ensureGenRegistered(gen)
                BGI_PowerRange._unionGenStates = BGI_PowerRange._unionGenStates or {}
                BGI_PowerRange._unionGenStates[gen] = (gen:isActivated() == true)

                -- Union may change; request a single rebuild
                _BGI_requestUnionRebuild()

                -- If the selected gen toggled, refresh its per-gen ring too
                if BGI_PowerRange.TargetGen == gen then
                    BGI_PowerRange._needsPerGenRebuild = true
                end
            end
            return ok
        end

        ISActivateGenerator._BGI_wrapComplete = true
    end
end