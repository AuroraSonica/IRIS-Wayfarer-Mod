-- !IrisTreeSurvey.lua — TREE CLEARING BENCH (rebuilt clean 2026-08-20)
--
-- WHAT WORKS (proven in the field this session, receipts in tree_survey_log.txt):
--   * A single tree can be made INVISIBLE per-instance: setLocalPosition(y-500) +
--     setVisibility(false). Surgical - its neighbours are untouched. Reversible.
--   * A tree can be made WALK-THROUGH by disabling the collider its trunk ray hits AND
--     then refreshing the broadphase FROM THE COMPONENT. The refresh is the step that
--     was missing for three rounds: set_Enabled(false) on its own is completely inert.
--   * COLLISION IS PER-PATCH: every tree in one Foliage component shares ONE collider
--     (measured: trees 120m apart all hit Foliage@1232085232). So clearing collision for
--     one tree clears it for that whole patch - and THAT is why 2026-08-13 looked like
--     "the whole world lost collision". It is per-patch, NOT per-model: the same tree
--     model 250m away sits in a different patch with its own collider.
--
-- WHAT IS DEAD (do not rebuild, the receipts are in the log):
--   * removeFoliageInstance - always returns false, count never changes, under every
--     variant tried (instance index, unitId, static forced off, preUpdateFrame first).
--   * updateBoundingBox / updateToDraw / preUpdateFrame / RigidBodyMeshSet blink - none
--     of them rebuild collision after a per-instance edit.
--   * Disabling the via.physics.Colliders COMPONENT - works, but takes the whole patch
--     with no finer control, and it is what caused the 08-13 scare. Never do it.
--
-- ⛔ LAWS: engine calls only from the UpdateBehavior pump; fetch collider refs FRESH every
-- time (cached ones = use-after-free CTD); exact overload strings; log every call's result
-- because pcall failures are silent. Nothing here is saved - a game restart undoes it all.

local M = { last = "(idle) stand at a tree and press SELECT", radius = 30.0, min_h = 3.0, reach = 6.0 }
local target = nil     -- { comp, idx, path, h, cnt, go, opos = {x,y,z} }
local cleared = nil    -- { comp, idx, orig = {x,y,z}, coll = <collider index>, opos }
local tray = {}

local function _log(s)
    pcall(function()
        local f = io.open("IRIS/tree_survey_log.txt", "a")
        if f then f:write(string.format("[%s] %s\n", os.date("%H:%M:%S"), tostring(s))); f:close() end
    end)
end

local function _pl_pos()
    local p
    pcall(function()
        p = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
            :call("get_GameObject"):call("get_Transform"):call("get_Position")
    end)
    return p
end

local function _tray_ensure()
    if tray.ready then return true end
    local ok = pcall(function()
        tray.system = sdk.get_native_singleton("via.physics.System")
        tray.method = sdk.find_type_definition("via.physics.System")
            :get_method("castRay(via.physics.CastRayQuery, via.physics.CastRayResult)")
        tray.query = sdk.create_instance("via.physics.CastRayQuery"):add_ref()
        tray.result = sdk.create_instance("via.physics.CastRayResult"):add_ref()
        tray.query:clearOptions()
        tray.query:enableAllHits()
        tray.query:enableNearSort()
        tray.filter = tray.query:get_FilterInfo()
    end)
    tray.ready = ok and tray.system ~= nil and tray.method ~= nil
    return tray.ready == true
end

local function _vec3(x, y, z)
    local v = ValueType.new(sdk.find_type_definition("via.vec3"))
    v.x, v.y, v.z = x or 0, y or 0, z or 0
    return v
end

-- via.AABB spells its corners differently across builds - read both
local function _aabb_h(ab)
    if not ab then return nil end
    local mn, mx
    pcall(function() mn, mx = ab.minpos, ab.maxpos end)
    if not (mn and mx) then pcall(function() mn, mx = ab.min, ab.max end) end
    if not (mn and mx) then return nil end
    local ok, h = pcall(function() return mx.y - mn.y end)
    return ok and h or nil
end

-- every collidable around a world spot. ⛔ a ray STARTED inside a shape reports nothing, so
-- each direction is also cast INWARD from a 3.5m ring - the law that fixed the first misses.
local function _hits_at(px, py, pz, label)
    if not _tray_ensure() then _log("ray unavailable"); return {} end
    local seen, list = {}, {}
    local function ray(x1, y1, z1, x2, y2, z2)
        pcall(function()
            tray.filter:set_Group(0); tray.filter:set_Layer(2); tray.filter:set_MaskBits(0)
            tray.result:clear()
            tray.query:call("setRay(via.vec3, via.vec3)", _vec3(x1, y1, z1), _vec3(x2, y2, z2))
            tray.method:call(tray.system, tray.query, tray.result)
            local n = tray.result:get_NumContactPoints() or 0
            for i = 0, math.min(n, 3) - 1 do
                pcall(function()
                    local col = tray.result:call("getContactCollidable(System.UInt32)", i)
                    if not col then return end
                    local a = tostring(col:get_address())
                    if seen[a] then return end
                    seen[a] = true
                    local nm = "(none)"
                    pcall(function()
                        local go = col:call("get_GameObject")
                        if go then nm = tostring(go:call("get_Name")) end
                    end)
                    list[#list + 1] = { addr = a, name = nm }
                end)
            end
        end)
    end
    for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
        { 0.707, 0.707 }, { -0.707, 0.707 }, { 0.707, -0.707 }, { -0.707, -0.707 } }) do
        for _, hy in ipairs({ 0.5, 1.3 }) do
            ray(px, py + hy, pz, px + d[1] * 3.5, py + hy, pz + d[2] * 3.5)
            ray(px + d[1] * 3.5, py + hy, pz + d[2] * 3.5, px, py + hy, pz)
        end
    end
    if label then
        local names = {}
        for _, e in ipairs(list) do names[#names + 1] = e.name .. "@" .. e.addr end
        _log(string.format("  hits[%s] (%.1f,%.1f,%.1f) = %s", label, px, py, pz,
            (#list > 0) and table.concat(names, " | ") or "(NOTHING - passable)"))
    end
    collectgarbage("collect")
    return list
end

local function _foliage_hit(list)
    for _, e in ipairs(list or {}) do
        if tostring(e.name):find("Foliage") then return e.addr end
    end
    return nil
end

-- ── 1. SELECT ────────────────────────────────────────────────────────────────────────────
-- Only Foliage components whose GameObject carries a RigidBodyMeshSet are TREE patches;
-- grass components (no rigid body) outnumber them ~25:1 and used to win every time.
local function _select()
    local pp = _pl_pos(); if not pp then M.last = "no player"; return end
    local best = nil
    pcall(function()
        local sm = sdk.get_native_singleton("via.SceneManager")
        local scene = sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        local comps = scene:call("findComponents(System.Type)", sdk.typeof("via.landscape.Foliage"))
        local n = 0
        pcall(function() n = comps:call("get_Length") or 0 end)
        if n == 0 then pcall(function() n = comps:get_size() or 0 end) end
        for i = 0, (tonumber(n) or 0) - 1 do
            pcall(function()
                local c
                pcall(function() c = comps:call("get_Item", i) end)
                if not c then c = comps:get_element(i) end
                if not c then return end
                local has_rbs, goname = false, "?"
                pcall(function()
                    local go = c:call("get_GameObject")
                    if not go then return end
                    pcall(function() goname = go:call("get_Name") or "?" end)
                    has_rbs = go:call("getComponent(System.Type)",
                        sdk.typeof("via.dynamics.RigidBodyMeshSet")) ~= nil
                end)
                if not has_rbs then return end
                local cnt = 0; pcall(function() cnt = tonumber(c:call("get_InstanceCount")) or 0 end)
                for k = 0, math.min(cnt, 3000) - 1 do
                    local wx, wy, wz
                    pcall(function()
                        local wp = c:call("getWorldPosition", k)
                        if wp then wx, wy, wz = wp.x, wp.y, wp.z end
                    end)
                    if wx then
                        local d2 = (wx - pp.x) ^ 2 + (wz - pp.z) ^ 2
                        if d2 <= (M.reach or 6.0) ^ 2 and ((not best) or d2 < best.d2) then
                            local h
                            pcall(function() h = _aabb_h(c:call("getWorldAABB(System.UInt32)", k)) end)
                            if h and h >= (M.min_h or 3.0) then
                                local path = "?"
                                pcall(function()
                                    local uid = c:call("getUnitId", k)
                                    if uid then path = c:call("getUnitMeshResourcePath", uid) or "?" end
                                end)
                                best = { comp = c, idx = k, d2 = d2, h = h, path = path,
                                         go = goname, cnt = cnt,
                                         -- ⭐ the position BEFORE any clearing: every later ray
                                         -- must use THIS, not the live (possibly sunk) position
                                         opos = { x = wx, y = wy, z = wz } }
                            end
                        end
                    end
                end
            end)
        end
    end)
    collectgarbage("collect")
    if not best then
        target = nil
        M.last = string.format("no tree within %.0fm (needs to be >= %.0fm tall)", M.reach or 6, M.min_h or 3)
        _log(M.last); return
    end
    target = best
    local short = tostring(best.path):match("([^/]+)$") or tostring(best.path)
    M.last = string.format("SELECTED %s  %.1fm tall  |  patch '%s' holds %d trees",
        short, best.h, tostring(best.go), best.cnt or 0)
    _log("SELECT " .. tostring(best.path) .. " idx=" .. best.idx .. " " .. M.last)
end

-- find which collider index on the patch owns the trunk the ray hits (their addresses match)
local function _collider_index(addr)
    local found = nil
    pcall(function()
        local go = target.comp:call("get_GameObject")
        local cols = go:call("getComponent(System.Type)", sdk.typeof("via.physics.Colliders"))
        if not cols then return end
        local n = tonumber(cols:call("getCollidersCount")) or 0
        for i = 0, math.min(n, 32) - 1 do
            pcall(function()
                local c = cols:call("getColliders(System.UInt32)", i)   -- FRESH every time (UAF law)
                if c and tostring(c:get_address()) == addr then found = i end
                c = nil
            end)
        end
        cols = nil
    end)
    return found
end

-- enable/disable ONE collider, then refresh the broadphase FROM THE COMPONENT.
-- ⛔ the component's own set_Enabled is NEVER touched (that is the 08-13 route).
-- ⭐ the refresh is not optional in EITHER direction: without it the flag change is inert,
-- which is exactly why "restore" appeared to do nothing.
local function _collider_enable(i, on)
    local ok, bp = false, false
    pcall(function()
        local go = target.comp:call("get_GameObject")
        local cols = go:call("getComponent(System.Type)", sdk.typeof("via.physics.Colliders"))
        if not cols then error("no Colliders component") end
        local c = cols:call("getColliders(System.UInt32)", i)
        if not c then error("no collider " .. tostring(i)) end
        c:call("set_Enabled", on)
        pcall(function() c:call("updateCollisionFilter") end)
        c = nil
        ok = true
        bp = pcall(function() cols:call("updateBroadphase(System.Boolean)", true) end)
        pcall(function() cols:call("updateBroadphase") end)
        pcall(function() cols:call("updateCollisionFilter") end)
        cols = nil
    end)
    _log(string.format("  collider[%s] enabled=%s set=%s broadphase=%s", tostring(i), tostring(on),
        tostring(ok), tostring(bp)))
    collectgarbage("collect")
    return ok and bp
end

-- ── 2. CLEAR ─────────────────────────────────────────────────────────────────────────────
local function _clear()
    if not target then M.last = "press SELECT first"; return end
    if cleared then M.last = "something is already cleared - press PUT IT BACK first"; return end
    local o = target.opos
    local before = _hits_at(o.x, o.y, o.z, "before")
    local addr = _foliage_hit(before)
    local ci = addr and _collider_index(addr) or nil
    -- (a) the visual half: this one instance only
    local lp
    pcall(function() lp = target.comp:call("getLocalPosition(System.UInt32)", target.idx) end)
    local moved, hid = false, false
    if lp then
        moved = pcall(function()
            target.comp:call("setLocalPosition(System.UInt32, via.vec3)", target.idx,
                _vec3(lp.x, lp.y - 500.0, lp.z))
        end)
        hid = pcall(function()
            target.comp:call("setVisibility(System.UInt32, System.Boolean)", target.idx, false)
        end)
    end
    -- (b) the collision half: the patch's trunk collider + the broadphase refresh
    local coll_done = false
    if ci then coll_done = _collider_enable(ci, false) end
    cleared = { comp = target.comp, idx = target.idx, coll = ci, opos = o,
                orig = lp and { x = lp.x, y = lp.y, z = lp.z } or nil }
    local after = _hits_at(o.x, o.y, o.z, "after")
    local still = _foliage_hit(after) ~= nil
    M.last = string.format("CLEARED: hidden=%s, collision=%s%s",
        tostring(moved and hid),
        ci and (coll_done and (still and "STILL BLOCKING" or "gone") or "failed") or "no trunk collider found",
        ci and (" (collider " .. ci .. ", affects all " .. tostring(target.cnt) .. " trees in this patch)") or "")
    _log("CLEAR " .. M.last)
end

-- ── 3. PUT IT BACK ───────────────────────────────────────────────────────────────────────
local function _put_back()
    if not cleared then M.last = "nothing is cleared"; return end
    local moved, shown = false, false
    if cleared.orig then
        moved = pcall(function()
            cleared.comp:call("setLocalPosition(System.UInt32, via.vec3)", cleared.idx,
                _vec3(cleared.orig.x, cleared.orig.y, cleared.orig.z))
        end)
    end
    shown = pcall(function()
        cleared.comp:call("setVisibility(System.UInt32, System.Boolean)", cleared.idx, true)
    end)
    local coll_back = "n/a"
    if cleared.coll then
        local saved = target
        target = { comp = cleared.comp }               -- _collider_enable reads target.comp
        coll_back = tostring(_collider_enable(cleared.coll, true))
        target = saved
    end
    local o = cleared.opos
    cleared = nil
    local after = o and _hits_at(o.x, o.y, o.z, "after put-back") or {}
    M.last = string.format("PUT BACK: visible=%s moved=%s collision=%s%s",
        tostring(shown), tostring(moved), coll_back,
        (o and (_foliage_hit(after) and " (trunk blocks again)" or " (⚠ still passable)")) or "")
    _log("PUT BACK " .. M.last)
end

-- ── diagnostics (collapsed; only needed when something behaves oddly) ────────────────────
local function _blast_radius()
    if not target then M.last = "press SELECT first"; return end
    local o = target.opos
    _hits_at(o.x, o.y, o.z, "this tree")
    -- another tree in the SAME patch: expected to change together (shared collider)
    local same
    pcall(function()
        local cnt = tonumber(target.comp:call("get_InstanceCount")) or 0
        for k = 0, math.min(cnt, 3000) - 1 do
            if k ~= target.idx and not same then
                local wx, wy, wz
                pcall(function()
                    local wp = target.comp:call("getWorldPosition", k)
                    if wp then wx, wy, wz = wp.x, wp.y, wp.z end
                end)
                if wx then
                    local d2 = (wx - o.x) ^ 2 + (wz - o.z) ^ 2
                    if d2 > 25.0 then
                        local h
                        pcall(function() h = _aabb_h(target.comp:call("getWorldAABB(System.UInt32)", k)) end)
                        if h and h >= (M.min_h or 3.0) then same = { x = wx, y = wy, z = wz } end
                    end
                end
            end
        end
    end)
    if same then _hits_at(same.x, same.y, same.z, "same patch") end
    -- a tree in a DIFFERENT patch: must NOT change. This is the real collateral test.
    local other
    pcall(function()
        local sm = sdk.get_native_singleton("via.SceneManager")
        local scene = sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        local comps = scene:call("findComponents(System.Type)", sdk.typeof("via.landscape.Foliage"))
        local n = 0
        pcall(function() n = comps:call("get_Length") or 0 end)
        if n == 0 then pcall(function() n = comps:get_size() or 0 end) end
        local mine = target.comp:get_address()
        for i = 0, (tonumber(n) or 0) - 1 do
            if other then break end
            pcall(function()
                local c
                pcall(function() c = comps:call("get_Item", i) end)
                if not c then c = comps:get_element(i) end
                if not c or c:get_address() == mine then return end
                local has_rbs = false
                pcall(function()
                    local go = c:call("get_GameObject")
                    has_rbs = go and go:call("getComponent(System.Type)",
                        sdk.typeof("via.dynamics.RigidBodyMeshSet")) ~= nil
                end)
                if not has_rbs then return end
                local cnt = 0; pcall(function() cnt = tonumber(c:call("get_InstanceCount")) or 0 end)
                for k = 0, math.min(cnt, 1500) - 1 do
                    if other then return end
                    local wx, wy, wz
                    pcall(function()
                        local wp = c:call("getWorldPosition", k)
                        if wp then wx, wy, wz = wp.x, wp.y, wp.z end
                    end)
                    if wx then
                        local h
                        pcall(function() h = _aabb_h(c:call("getWorldAABB(System.UInt32)", k)) end)
                        if h and h >= (M.min_h or 3.0) then other = { x = wx, y = wy, z = wz } end
                    end
                end
            end)
        end
    end)
    if other then _hits_at(other.x, other.y, other.z, "OTHER patch (must not change)") end
    M.last = "blast radius logged - compare the 'hits[...]' lines in tree_survey_log.txt"
    _log(M.last)
end

local function _patch_map()
    if not target then M.last = "press SELECT first"; return end
    local cnt = 0
    pcall(function() cnt = tonumber(target.comp:call("get_InstanceCount")) or 0 end)
    local stride = math.max(math.floor(cnt / 8), 1)
    local seen, n = {}, 0
    for k = 0, cnt - 1, stride do
        if n >= 8 then break end
        local wx, wy, wz, h
        pcall(function()
            local wp = target.comp:call("getWorldPosition", k)
            if wp then wx, wy, wz = wp.x, wp.y, wp.z end
        end)
        pcall(function() h = _aabb_h(target.comp:call("getWorldAABB(System.UInt32)", k)) end)
        if wx and h and h >= (M.min_h or 3.0) then
            n = n + 1
            local a = _foliage_hit(_hits_at(wx, wy, wz, nil)) or "(none)"
            seen[a] = (seen[a] or 0) + 1
        end
    end
    local parts = {}
    for a, c in pairs(seen) do parts[#parts + 1] = a .. " x" .. c end
    M.last = "patch map: " .. n .. " trees sampled -> " .. table.concat(parts, " , ")
    _log(M.last)
    collectgarbage("collect")
end

-- ── pump + panel ─────────────────────────────────────────────────────────────────────────
local q = {}
re.on_application_entry("UpdateBehavior", function()
    if q.select then q.select = false; pcall(_select) end
    if q.clear then q.clear = false; pcall(_clear) end
    if q.back then q.back = false; pcall(_put_back) end
    if q.radius then q.radius = false; pcall(_blast_radius) end
    if q.map then q.map = false; pcall(_patch_map) end
end)

re.on_script_reset(function()
    -- leave nothing disabled behind a reset: the flag survives, our bookkeeping does not
    pcall(function() if cleared then _put_back() end end)
end)

re.on_draw_ui(function()
    if not imgui.tree_node("IRIS Tree Clearing") then return end
    imgui.text(M.last)
    imgui.text("")
    imgui.text("Stand next to a tree, then work down this list:")
    if imgui.button("1.  SELECT the tree next to me") then q.select = true end
    if target then
        local short = tostring(target.path):match("([^/]+)$") or "?"
        imgui.text(string.format("      -> %s, %.1fm tall, in a patch of %d trees",
            short, target.h or 0, target.cnt or 0))
    else
        imgui.text("      -> nothing selected yet")
    end
    if imgui.button("2.  CLEAR IT  (invisible + walk-through)") then q.clear = true end
    if imgui.button("3.  PUT IT BACK") then q.back = true end
    imgui.text("")
    imgui.text("Heads-up: collision is shared by the whole patch, so step 2 makes")
    imgui.text("every tree in this patch walk-through. Only the SELECTED one vanishes.")
    imgui.text("Nothing is permanent - restarting the game undoes everything.")
    if imgui.tree_node("checks (only if something looks wrong)") then
        if imgui.button("does it affect other patches?") then q.radius = true end
        if imgui.button("how many colliders does this patch use?") then q.map = true end
        local c
        c, M.reach = imgui.slider_float("how far to look for a tree (m)", M.reach or 6.0, 2.0, 20.0)
        c, M.min_h = imgui.slider_float("smallest thing that counts as a tree (m)", M.min_h or 3.0, 1.0, 10.0)
        imgui.tree_pop()
    end
    imgui.tree_pop()
end)
