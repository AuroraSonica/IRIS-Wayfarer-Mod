-- IrisTreeClear.lua - PERMANENT tree clearing for the homestead (v1, 2026-08-12)
-- Aurora: "trees just make things worse - destroy them permanently." Her field call was
-- right: DD2 trees are CHOPPABLE GIMMICKS, and the 23:56 survey named them - gm80_109 /
-- gm80_110, full GameObjects (via.physics.Colliders + app.HitController + Generate*).
-- The game forgets a felled tree the moment the area streams back in, so permanence is
-- OURS: a position-keyed LEDGER (IRIS/iris_tree_clear.json, universal coords) re-kills
-- every recorded tree on approach, silently, before the player can see it stand again.
-- Three ways in: (1) CLEAR button - fell every known tree id within the radius;
-- (2) CHOP PERMANENCE - a tree the PLAYER fells while standing near it auto-records
--     (presence-diff: it was here last pass, the player never left, now it is gone);
-- (3) the outbuildings/screen flows can call _G.IrisTreeClear.clear_at(x, z, r).
-- ⛔ ALLOWLIST LAW: gm80 is NOT all trees (gm80_150 is a WINDOW - the prompt-hijack
-- memory). Only exact ids from survey receipts are ever touched, plus a height gate.

local LEDGER_FILE = "IRIS/iris_tree_clear.json"
local TREE_IDS = { gm80_109 = true, gm80_110 = true }   -- survey 2026-08-12; grow via receipts
local MIN_H = 4.0
-- ⛔⛔ trunk_kill DEFAULT OFF FOREVER (08-13, Aurora: "every tree in the world has
-- lost collision - I can run through all of them"): SpeedTree collision is INSTANCED.
-- The same few tree models are reused across the whole map, and killing a plot
-- tree's collidable kills it for EVERY clone of that model world-wide. The
-- patch-wide law, one level deeper than we knew. Aurora explicitly prefers the
-- remaining plot trunks invisible while we lack a safe per-instance collision API.
-- Keep the global/shared collider untouched and hide only the plot render instances.
-- Game restart restores all runtime foliage state.
local M = { last = "(idle)", radius = 25.0, chop_watch = true, trunk_kill = false,
    zone_foliage_hide = true }
local ledger = nil
local seen = {}        -- [addr] = { name, ux, uy, uz, at, missing }  (chop presence-diff)
local pass_at = 0.0
local killed_this_load = {}   -- [ledger index] = true (log once, not per pass)
local clear_pending = false

local function _log(s)
    pcall(function()
        local f = io.open("IRIS/tree_clear_log.txt", "a")
        if f then f:write(string.format("[%s] %s\n", os.date("%H:%M:%S"), tostring(s))); f:close() end
    end)
end
local function _load()
    if ledger then return end
    ledger = json.load_file(LEDGER_FILE) or {}
end
local function _save() pcall(function() json.dump_file(LEDGER_FILE, ledger or {}) end) end

local function _player()
    local tf
    pcall(function()
        tf = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
            :call("get_GameObject"):call("get_Transform")
    end)
    if not tf then return end
    local rp, up
    pcall(function() rp = tf:call("get_Position") end)
    pcall(function() up = tf:call("get_UniversalPosition") end)
    if not (rp and up) then return end
    return rp, { x = up.x - rp.x, y = up.y - rp.y, z = up.z - rp.z }
end

-- every standing allowlisted tree within r (render metres) of the player
-- ⛔ 08-13 crash-log storm: this scan touches EVERY app.HitController in the scene and
-- dying/streaming comps throw on get_GameObject - pcall-caught, but REF logs each one
-- (dozens per burst, every ~2s, all through the Shadow-mount CTD window = engine churn
-- at the worst moment). Trees do not move: sweep once, reuse for 10s unless the player
-- has walked more than 4m, and refilter the cached list to the asked radius.
local ST_CACHE = { at = -999.0, x = 0.0, z = 0.0, r = 0.0, trees = nil }
local function _standing_trees(rp, r)
    local now = os.clock()
    if ST_CACHE.trees and (now - ST_CACHE.at) < 10.0 and ST_CACHE.r >= r then
        local mx, mz = rp.x - ST_CACHE.x, rp.z - ST_CACHE.z
        if mx * mx + mz * mz < 16.0 then
            local out, r2 = {}, r * r
            for _, t in ipairs(ST_CACHE.trees) do
                local ax, az = t.x - rp.x, t.z - rp.z
                if ax * ax + az * az <= r2 then out[#out + 1] = t end
            end
            return out
        end
    end
    local out = {}
    pcall(function()
        local sm = sdk.get_native_singleton("via.SceneManager")
        local smt = sdk.find_type_definition("via.SceneManager")
        local scene = sdk.call_native_func(sm, smt, "get_CurrentScene")
        local comps = scene:call("findComponents(System.Type)", sdk.typeof("app.HitController"))
        local cnt = 0
        pcall(function() cnt = comps:call("get_Length") or 0 end)
        if cnt == 0 then pcall(function() cnt = comps:get_size() or 0 end) end
        local r2 = r * r
        for i = 0, (tonumber(cnt) or 0) - 1 do
            pcall(function()
                local c
                pcall(function() c = comps:call("get_Item", i) end)
                if not c then pcall(function() c = comps:get_element(i) end) end
                local go = c and c:call("get_GameObject")
                local nm = go and tostring(go:call("get_Name") or "")
                if not TREE_IDS[nm] then return end
                local p = go:call("get_Transform"):call("get_Position")
                local dx, dz = p.x - rp.x, p.z - rp.z
                if dx * dx + dz * dz > r2 then return end
                -- height gate: belt and braces against any short cousin sharing an id
                local h = 99.0
                pcall(function()
                    local mc = go:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
                    local ab = mc and mc:call("get_WorldAABB")
                    if ab then
                        local a, b = ab:get_field("minpos"), ab:get_field("maxpos")
                        h = b.y - a.y
                    end
                end)
                if h < MIN_H then return end
                out[#out + 1] = { go = go, name = nm, x = p.x, y = p.y, z = p.z }
            end)
        end
    end)
    ST_CACHE.at, ST_CACHE.x, ST_CACHE.z, ST_CACHE.r, ST_CACHE.trees = now, rp.x, rp.z, r, out
    return out
end

local function _fell(go)
    local ok = pcall(function() go:call("destroy", go) end)
    return ok
end

-- ── FOLIAGE PERMANENCE (the BIG trees, 08-13): IrisWoodcutting already fells foliage
-- trees (3 chops -> cluster-hide + re-assert) but with a 10-minute regrow TTL. A fell
-- near an owned plot now records HERE, and this module re-hides the cluster FOREVER -
-- across sessions. Positions UNIVERSAL (render shifts with tile re-base); bindings
-- (comp + instance indexes) re-found per session - wrappers die on reset.
local fol_bind = {}        -- [ledger index] = { {comp, idxs}, ... }
local function _fol_set_vis(comp, index, visible)
    -- ⛔ the EXACT overload (the grass campaign's 264-native-AV scar)
    if not comp or not sdk.is_managed_object(comp) then return false end
    return pcall(function()
        comp:call("setVisibility(System.UInt32, System.Boolean)", math.floor(index), visible)
    end)
end

-- ── GHOST-TRUNK COLLISION KILL (PROVEN 08-13 ~01:00, Aurora's field test: the battery
-- opened the trunk, NEIGHBOR trees stayed solid): every foliage ledger entry gets its
-- trunk collidables found by a converging ray ring and switched off, re-asserted each
-- pass. ⛔ SAFETY: only collidables whose GameObject is named 'Foliage' are ever touched
-- (the receipts' owner) - ground, rocks and buildings can never match. Own ray instances
-- (never share ray objects across systems - the dead-rays law).
local kray = {}
local kcol = {}          -- [ledger index] = list of bound collidables (session)
local kcol_retry = {}    -- [ledger index] = next os.clock() a failed probe may retry
local function _kray_ensure()
    if kray.ready then return true end
    local ok = pcall(function()
        kray.system = sdk.get_native_singleton("via.physics.System")
        kray.method = sdk.find_type_definition("via.physics.System")
            :get_method("castRay(via.physics.CastRayQuery, via.physics.CastRayResult)")
        kray.query = sdk.create_instance("via.physics.CastRayQuery"):add_ref()
        kray.result = sdk.create_instance("via.physics.CastRayResult"):add_ref()
        kray.query:clearOptions()
        kray.query:enableAllHits()
        kray.query:enableNearSort()
        kray.filter = kray.query:get_FilterInfo()
    end)
    kray.ready = ok and kray.system ~= nil and kray.method ~= nil
    return kray.ready == true
end
local function _kray_v3(x, y, z)
    local v = ValueType.new(sdk.find_type_definition("via.vec3"))
    v.x, v.y, v.z = x or 0, y or 0, z or 0
    return v
end
local function _kill_probe(ex, ey, ez)
    -- render coords in; inward ring (a ray STARTED inside a shape reports nothing)
    local out, seen = {}, {}
    if not _kray_ensure() then return out end
    for _, dirv in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
        { 0.707, 0.707 }, { -0.707, 0.707 }, { 0.707, -0.707 }, { -0.707, -0.707 } }) do
        for _, hy in ipairs({ 0.6, 1.5 }) do
            pcall(function()
                kray.filter:set_Group(0); kray.filter:set_Layer(2); kray.filter:set_MaskBits(0)
                kray.result:clear()
                kray.query:call("setRay(via.vec3, via.vec3)",
                    _kray_v3(ex + dirv[1] * 3.0, ey + hy, ez + dirv[2] * 3.0),
                    _kray_v3(ex, ey + hy, ez))
                kray.method:call(kray.system, kray.query, kray.result)
                local nhit = kray.result:get_NumContactPoints() or 0
                for i = 0, math.min(nhit, 3) - 1 do
                    pcall(function()
                        local col = kray.result:call("getContactCollidable(System.UInt32)", i)
                        if not col then return end
                        local a = tostring(col:get_address())
                        if seen[a] then return end
                        seen[a] = true
                        local goname = ""
                        pcall(function() goname = tostring(col:call("get_GameObject"):call("get_Name")) end)
                        if goname == "Foliage" then
                            pcall(function() col = col:add_ref() end)
                            out[#out + 1] = col
                        end
                    end)
                end
            end)
        end
    end
    return out
end
local function _kill_fire(cols)
    -- ⛔⛔ 08-13 (Aurora's screenshots: STANDING trees across the grove lost their trunks):
    -- Colliders.set_Enabled(false) is PATCH-WIDE - one component carries collision for
    -- many trees, and the "neighbor still blocked" receipt had merely hit a different
    -- patch. SURGICAL ONLY now: the probed collidable's own flags + the refresh ritual
    -- (whether the flags land without the component switch = the next field receipt).
    for _, col in ipairs(cols) do
        pcall(function() col:call("set_Enabled", false) end)
        pcall(function() col:call("set_Valid", false) end)
        pcall(function() col:call("setValid", false) end)
        pcall(function()
            local cs = col:call("get_GameObject"):call("getComponent(System.Type)", sdk.typeof("via.physics.Colliders"))
            if cs then
                pcall(function() cs:call("updateCollisionFilter") end)
                pcall(function() cs:call("updateBroadphase", true) end)
                pcall(function() cs:call("updateBroadphase") end)
            end
        end)
    end
end

-- ══ ⭐⭐⭐ TREELESS PLOTS (Aurora's final design, 08-13): every owned plot is simply a
-- NO-TREE ZONE. No per-tree marking, no chop bookkeeping: gimmick trees inside the zone
-- are destroyed on sight; each foliage SpeedTree inside it is removed by exact instance
-- id. Never split visibility from collision: foliage colliders are shared by model and
-- cannot safely be toggled for one tree.
M.zone_on = M.zone_on ~= false
M.zone_radius = 45.0
local ZONE_REG_FILE = "IRIS/iris_tree_comps.json"
local zone = { cache = {}, scanned = false, active = false,
    reg = nil, kc = {}, kc_at = {} }
local function _zone_trunk_test(x, y, z)
    -- the woodcutting anatomy law: real trees carry layer-2 trunk collision at their
    -- base; wheat/grass/bushes do not. Two crossing rays at chest height.
    if not _kray_ensure() then return true end   -- no ray = fail open (better hide grass than keep trees)
    local hits = 0
    for _, axis in ipairs({ { 1.5, 0 }, { 0, 1.5 } }) do
        pcall(function()
            kray.filter:set_Group(0); kray.filter:set_Layer(2); kray.filter:set_MaskBits(0)
            kray.result:clear()
            kray.query:call("setRay(via.vec3, via.vec3)",
                _kray_v3(x - axis[1], y + 1.0, z - axis[2]),
                _kray_v3(x + axis[1], y + 1.0, z + axis[2]))
            kray.method:call(kray.system, kray.query, kray.result)
            hits = hits + (kray.result:get_NumContactPoints() or 0)
        end)
    end
    return hits > 0
end
local function _zone_plots(d)
    local t = {}
    pcall(function()
        for _, pr in ipairs(_G.IrisHomesteadPlots.list()) do
            if pr.owned ~= false then t[#t + 1] = { ux = pr.ux or 0, uz = pr.uz or 0 } end
        end
    end)
    return t
end
local function _zone_inside(ux, uz, plots)
    local r2 = (tonumber(M.zone_radius) or 45.0) ^ 2
    for _, p in ipairs(plots) do
        local dx, dz = p.ux - ux, p.uz - uz
        if dx * dx + dz * dz < r2 then return true end
    end
    return false
end
local function _zone_scan(rp, d)
    local plots = _zone_plots(d)
    if #plots == 0 then zone.cache = {}; return end
    local cache = {}
    pcall(function()
        local sm = sdk.get_native_singleton("via.SceneManager")
        local smt = sdk.find_type_definition("via.SceneManager")
        local scene = sdk.call_native_func(sm, smt, "get_CurrentScene")
        local arr = scene:call("findComponents(System.Type)", sdk.typeof("via.landscape.Foliage"))
        local n = arr and arr:get_size() or 0
        local budget = 0
        for ci = 0, (tonumber(n) or 0) - 1 do
            if budget > 60000 then break end   -- the freeze law
            pcall(function()
                local c = arr:get_element(ci)
                local cnt = tonumber(c:call("get_InstanceCount")) or 0
                if cnt == 0 then return end
                local p0 = c:call("getWorldPosition", 0)
                if not p0 then return end
                local dx0, dz0 = p0.x - rp.x, p0.z - rp.z
                if dx0 * dx0 + dz0 * dz0 > 600.0 ^ 2 then return end
                -- ⛔ THE TRUNK-TEST TRAP (Aurora: "trees still visible, walk through
                -- them"): a comp whose trunk collision we already killed classified as
                -- GRASS and never hid - the detector ate its own evidence. SpeedTree
                -- membership is readable regardless of collision state: trees/bushes/
                -- crops are SpeedTree, plain grass is not. On HER cleared farmland,
                -- a bush or wheat clump vanishing with the trees is the right trade.
                local speed = false
                pcall(function() speed = c:call("isSpeedTreeMesh", 0) == true end)
                if not speed then return end
                for k = 0, cnt - 1 do
                    budget = budget + 1
                    if budget > 60000 then break end
                    pcall(function()
                        local wp = c:call("getWorldPosition", k)
                        if not wp then return end
                        if not _zone_inside(wp.x + d.x, wp.z + d.z, plots) then return end
                        cache[#cache + 1] = { comp = c, i = k, x = wp.x, y = wp.y, z = wp.z }
                    end)
                end
            end)
        end
    end)
    zone.cache = cache
    if #cache > 0 then _log("zone scan: " .. #cache .. " speedtree instance(s) inside plot zones") end
end
local function _zone_apply_cache(start_at, budget)
    local hidden, shrunk = 0, 0
    local zero = _kray_v3(0.001, 0.001, 0.001)
    local cache = zone.cache or {}
    local first = math.max(1, tonumber(start_at) or 1)
    local last = math.min(#cache, first + math.max(1, tonumber(budget) or 96) - 1)
    for n = first, last do
        local e = cache[n]
        if _fol_set_vis(e.comp, e.i, false) then hidden = hidden + 1 end
        -- Per-instance transform, unlike the shared physics collidable. Scaling the
        -- removed visual instance to near-zero also makes its instance-generated trunk
        -- degenerate without touching the same SpeedTree model elsewhere in the world.
        local ok, applied = pcall(function()
            e.comp:call("setLocalScale(System.UInt32, via.vec3)", math.floor(e.i), zero)
            local got = e.comp:call("getLocalScale(System.UInt32)", math.floor(e.i))
            return got and tonumber(got.x) and tonumber(got.x) < 0.01
        end)
        if ok and applied then shrunk = shrunk + 1 end
    end
    return hidden, shrunk, last + 1
end
local function _zone_restore_cache(start_at, budget)
    local shown = 0
    local one = _kray_v3(1.0, 1.0, 1.0)
    local cache = zone.cache or {}
    local first = math.max(1, tonumber(start_at) or 1)
    local last = math.min(#cache, first + math.max(1, tonumber(budget) or 96) - 1)
    for n = first, last do
        local e = cache[n]
        pcall(function()
            e.comp:call("setVisibility(System.UInt32, System.Boolean)", math.floor(e.i), true)
            -- Earlier builds shrank the render instance while its shared trunk remained.
            -- There is no saved random scale to recover, so neutral scale is the honest
            -- repair: a slightly different-sized visible tree beats an invisible wall.
            e.comp:call("setLocalScale(System.UInt32, via.vec3)", math.floor(e.i), one)
            shown = shown + 1
        end)
    end
    return shown, last + 1
end
local function _zone_tick(rp, d, trees)
    if not M.zone_on then return end
    local plots = _zone_plots(d)
    if #plots == 0 then return end
    -- gimmick trees inside the zone: destroyed on sight, no bookkeeping
    for _, t in ipairs(trees or {}) do
        if t.go and _zone_inside(t.x + d.x, t.z + d.z, plots) then
            if _fell(t.go) then _log("zone: felled gimmick " .. tostring(t.name)) end
            t.go = nil
        end
    end
    -- DD2's foliage collision is shared across a whole SpeedTree component.  Both
    -- disabling its collider and shrinking/hiding only one render instance have been
    -- field-proven wrong; removeFoliageInstance was also rejected by this runtime.
    -- Until a surgical collision API is found, never manufacture invisible solid trees.
    if M.zone_foliage_hide ~= true then
        if not zone.scanned then
            _zone_scan(rp, d)
            zone.scanned = true
            zone.restore_i = 1
        end
        if (tonumber(zone.restore_i) or 1) <= #(zone.cache or {}) then
            local shown, next_i = _zone_restore_cache(zone.restore_i, 96)
            zone.restore_i = next_i
            if shown > 0 then M.last = "plot foliage restored visibly (shared collision kept honest)" end
        end
        return
    end
    -- Foliage instances are discovered ONCE per approach to the plot. The former
    -- 25-second rescan traversed up to 60,000 instances, then rewrote all 658 cached
    -- trees in 96-item bursts every two seconds. That was Aurora's rhythmic hitch.
    -- Leaving the work radius drops this cache; streaming back in performs one fresh
    -- discovery. The actual writes are spread across tiny per-frame batches below.
    if not zone.scanned then
        _zone_scan(rp, d)
        zone.scanned = true
        zone.apply_i = 1
        zone.apply_hidden = 0
        zone.apply_shrunk = 0
        zone.apply_reported = false
    end
end

_G.IrisTreeClear = {
    -- IrisWoodcutting calls this at every wild-tree fell (render coords in). Only the
    -- configured radius of an owned plot qualifies; "near the homestead" is not enough.
    record_foliage_fell = function(rx, ry, rz)
        _load()
        local rp, d = _player()
        if not (rp and d) then return false end
        local ux, uy, uz = rx + d.x, ry + d.y, rz + d.z
        local near = false
        pcall(function()
            for _, pr in ipairs(_G.IrisHomesteadPlots.list()) do
                if pr.owned ~= false then
                    local dx, dz = (pr.ux or 0) - ux, (pr.uz or 0) - uz
                    if dx * dx + dz * dz < (tonumber(M.zone_radius) or 45.0) ^ 2 then near = true; break end
                end
            end
        end)
        if not near then return false end
        for _, e in ipairs(ledger) do
            if e.kind == "foliage" then
                local dx, dz = e.x - ux, e.z - uz
                if dx * dx + dz * dz < 1.5 ^ 2 then return true end   -- already recorded
            end
        end
        ledger[#ledger + 1] = { kind = "foliage", name = "big tree", x = ux, y = uy, z = uz, chopped = true }
        _save()
        _log(string.format("FOLIAGE fell recorded at U(%.1f, %.1f) - PERMANENT (ledger=%d)", ux, uz, #ledger))
        return true
    end,
    -- IrisWoodcutting's target scan asks before offering a spot as choppable (render in)
    is_perm_felled = function(rx, rz)
        _load()
        local rp, d = _player()
        if not (rp and d) then return false end
        local ux, uz = rx + d.x, rz + d.z
        local in_zone = _zone_inside(ux, uz, _zone_plots(d))
        if M.zone_on then return in_zone end
        if in_zone then return true end
        for _, e in ipairs(ledger) do
            if e.kind == "foliage" then
                local dx, dz = e.x - ux, e.z - uz
                if dx * dx + dz * dz < 2.0 ^ 2 then return true end
            end
        end
        return false
    end,
    -- fell + ledger every known tree within r of universal (ux, uz); returns count
    clear_at = function(ux, uz, r)
        _load()
        local rp, d = _player()
        if not (rp and d) then return 0 end
        local trees = _standing_trees(rp, 120.0)
        local plots = _zone_plots(d)
        local n = 0
        for _, t in ipairs(trees) do
            local tux, tuz = t.x + d.x, t.z + d.z
            local dx, dz = tux - ux, tuz - uz
            if dx * dx + dz * dz <= (r or 25.0) ^ 2 and _zone_inside(tux, tuz, plots) then
                if _fell(t.go) then
                    n = n + 1
                    ledger[#ledger + 1] = { name = t.name, x = tux, y = t.y + d.y, z = tuz }
                end
            end
        end
        if n > 0 then
            _save()
            _log(string.format("CLEARED %d tree(s) at U(%.0f, %.0f) r=%.0f (ledger=%d)", n, ux, uz, r or 25.0, #ledger))
        end
        return n
    end,
    count = function() _load(); return #ledger end,
}

re.on_application_entry("UpdateBehavior", function()
    if clear_pending then
        clear_pending = false
        local rp, d = _player()
        if rp and d then
            local n = _G.IrisTreeClear.clear_at(rp.x + d.x, rp.z + d.z, tonumber(M.radius) or 25.0)
            M.last = n > 0 and ("felled " .. n .. " tree(s) - the ledger keeps them down")
                or "no known trees standing within the radius"
        end
    end
    -- Amortise foliage mutation over normal frames. Eight instance writes are
    -- effectively invisible; 96 in a two-second maintenance beat were not.
    if M.zone_on and M.zone_foliage_hide == true and zone.active
        and (tonumber(zone.apply_i) or 1) <= #(zone.cache or {}) then
        local hidden, shrunk, next_i = _zone_apply_cache(zone.apply_i, 8)
        zone.apply_hidden = (tonumber(zone.apply_hidden) or 0) + hidden
        zone.apply_shrunk = (tonumber(zone.apply_shrunk) or 0) + shrunk
        zone.apply_i = next_i
        M.last = string.format("plot trees: %d/%d hidden, %d verified near-zero",
            tonumber(zone.apply_hidden) or 0, #(zone.cache or {}),
            tonumber(zone.apply_shrunk) or 0)
        if zone.apply_i > #(zone.cache or {}) and not zone.apply_reported then
            zone.apply_reported = true
            _log(string.format("zone apply complete: %d hidden, %d near-zero (amortised)",
                tonumber(zone.apply_hidden) or 0, tonumber(zone.apply_shrunk) or 0))
        end
    end
    if os.clock() < pass_at then return end
    pass_at = os.clock() + 2.0
    _load()
    local rp, d = _player()
    if not (rp and d) then seen = {}; return end
    -- only work near a saved plot: the ledger is a HOMESTEAD tool, not a world edit
    local near_plot = false
    pcall(function()
        for _, pr in ipairs(_G.IrisHomesteadPlots.list()) do
            if pr.owned ~= false then
                local dx, dz = (pr.ux or 0) - (rp.x + d.x), (pr.uz or 0) - (rp.z + d.z)
                -- Work only just outside the treeless boundary. The old 90m gate
                -- made the heavy plot machinery follow Aurora well beyond home.
                local wr = (tonumber(M.zone_radius) or 45.0) + 15.0
                if dx * dx + dz * dz < wr * wr then near_plot = true; break end
            end
        end
    end)
    -- ⭐ PIN (Aurora 08-13, the "it's still visible" saga): stand AT any stubborn tree,
    -- press once - it records where YOU are, and the machinery hides + uncollides it
    -- within seconds and forever. No forensics, no radius guessing.
    if M.pin_pending then
        M.pin_pending = false
        if not near_plot then
            M.last = "no owned plot within 90m - tree pinning is a homestead tool"
        else
            local ux, uz = rp.x + d.x, rp.z + d.z
            local dup = false
            for _, e in ipairs(ledger) do
                if e.kind == "foliage" then
                    local dx, dz = e.x - ux, e.z - uz
                    if dx * dx + dz * dz < 1.5 ^ 2 then dup = true; break end
                end
            end
            if dup then
                M.last = "already pinned here"
            else
                ledger[#ledger + 1] = { kind = "foliage", name = "pinned tree",
                    x = ux, y = rp.y + d.y, z = uz, chopped = true }
                _save()
                _log(string.format("PINNED tree at U(%.1f, %.1f) (ledger=%d)", ux, uz, #ledger))
                M.last = "pinned - the tree here will be hidden and lose its collision within seconds"
            end
        end
    end
    if not near_plot then
        seen = {}
        if zone.active then
            zone.active = false
            zone.scanned = false
            zone.cache = {}
            zone.apply_i = 1
            zone.gimmick_done = false
        end
        return
    end
    zone.active = true
    local trees = {}
    if M.zone_on then
        -- Full app.HitController scene traversal is also entry work, not a
        -- two-second heartbeat. Gimmick trees cannot respawn while the area stays loaded.
        if not zone.gimmick_done then
            trees = _standing_trees(rp, 45.0)
            zone.gimmick_done = true
        end
    else
        trees = _standing_trees(rp, 45.0)
    end
    -- ⭐⭐ TREELESS PLOTS: the zone rule runs FIRST - anything tree inside an owned
    -- plot's radius is destroyed/hidden/uncollided with no bookkeeping at all
    pcall(function() _zone_tick(rp, d, trees) end)
    -- The zone is the sole tree-removal authority. The old position ledger, PIN and
    -- chop-watch routes used a loose 80/90m "near plot" gate and could therefore alter
    -- trees outside the homestead radius. Keep their data for backwards compatibility,
    -- but do not execute those routes while treeless plots are enabled.
    if M.zone_on then seen = {}; return end
    -- 1) RE-KILL: any standing gimmick tree within 2.5m of a ledger entry dies again, silently
    for li, e in ipairs(ledger) do
        if e.kind ~= "foliage" then
            for _, t in ipairs(trees) do
                local dx, dz = (t.x + d.x) - e.x, (t.z + d.z) - e.z
                if dx * dx + dz * dz < 2.5 ^ 2 then
                    if _fell(t.go) and not killed_this_load[li] then
                        killed_this_load[li] = true
                        _log("re-felled ledgered tree #" .. li .. " (" .. tostring(e.name) .. ")")
                    end
                    t.go = nil
                end
            end
        end
    end
    -- 1b) FOLIAGE permanence: re-hide every recorded big-tree cluster. Bound entries are
    -- cheap re-asserts; ONE unbound entry per pass gets the heavy find (budgeted scan).
    local fol_scanned = false
    for li, e in ipairs(ledger) do
        if e.kind == "foliage" and not e.retired then
            local ex, ez = e.x - d.x, e.z - d.z            -- universal -> render
            local dxp, dzp = ex - rp.x, ez - rp.z
            if dxp * dxp + dzp * dzp < 80.0 ^ 2 then
                -- GHOST-TRUNK collision: probe once (retry a miss every 20s), then a
                -- cheap re-assert every pass keeps the trunk soft through streaming.
                -- ⛔⛔ 08-13 DEFAULT OFF (the broken hoe): disabling colliders FREEZES
                -- their shapes in place (the frozen-shape law) - the farm filled with
                -- invisible shells and the hoe's aim ray hit them at the player's feet.
                -- Solid invisible trunks are the accepted floor; opt back in via panel.
                local kc = M.trunk_kill == true and kcol[li] or nil
                if kc then
                    _kill_fire(kc)
                elseif M.trunk_kill == true and os.clock() > (tonumber(kcol_retry[li]) or 0) then
                    kcol_retry[li] = os.clock() + 20.0
                    local ey = (tonumber(e.y) or (rp.y + d.y)) - d.y
                    local cols = _kill_probe(ex, ey, ez)
                    if #cols > 0 then
                        kcol[li] = cols
                        _kill_fire(cols)
                        _log(string.format("ghost-trunk collision KILLED at ledger #%d (%d collidable(s))", li, #cols))
                    end
                end
                local binds = fol_bind[li]
                if binds then
                    for _, b in ipairs(binds) do
                        pcall(function()
                            for _, k in ipairs(b.idxs) do
                                local wp = b.comp:call("getWorldPosition", k)
                                if wp then
                                    local dx, dz = wp.x - ex, wp.z - ez
                                    -- index still ours (streaming reshuffle guard) -> blind re-hide
                                    if dx * dx + dz * dz <= 6.25 then _fol_set_vis(b.comp, k, false) end
                                end
                            end
                        end)
                    end
                elseif not fol_scanned then
                    fol_scanned = true
                    local found = {}
                    pcall(function()
                        local sm = sdk.get_native_singleton("via.SceneManager")
                        local smt = sdk.find_type_definition("via.SceneManager")
                        local scene = sdk.call_native_func(sm, smt, "get_CurrentScene")
                        local arr = scene:call("findComponents(System.Type)", sdk.typeof("via.landscape.Foliage"))
                        local n = arr and arr:get_size() or 0
                        local budget = 0
                        for ci = 0, (tonumber(n) or 0) - 1 do
                            if budget > 60000 then break end   -- the freeze law
                            pcall(function()
                                local c = arr:get_element(ci)
                                local cnt = tonumber(c:call("get_InstanceCount")) or 0
                                if cnt == 0 then return end
                                local p0 = c:call("getWorldPosition", 0)
                                if not p0 then return end
                                local dx0, dz0 = p0.x - ex, p0.z - ez
                                -- 600m proxy: instance 0 of a sprawling patch can stand FAR
                                -- from its siblings (the grass campaign's own warning) - the
                                -- 300m cull was likely how the visible twin kept escaping
                                if dx0 * dx0 + dz0 * dz0 > 600.0 ^ 2 then return end
                                local idxs = {}
                                for k = 0, cnt - 1 do
                                    budget = budget + 1
                                    if budget > 60000 then break end
                                    pcall(function()
                                        local wp = c:call("getWorldPosition", k)
                                        if wp then
                                            local dx, dz = wp.x - ex, wp.z - ez
                                            -- 2m: big trees are often TWIN instances a hair
                                            -- apart (Aurora: "came back visible" - the 1.2m
                                            -- rebind re-hid one twin and left the other)
                                            if dx * dx + dz * dz <= 4.0 then
                                                idxs[#idxs + 1] = k
                                                _fol_set_vis(c, k, false)
                                            end
                                        end
                                    end)
                                end
                                if #idxs > 0 then found[#found + 1] = { comp = c, idxs = idxs } end
                            end)
                        end
                    end)
                    if #found > 0 then
                        fol_bind[li] = found
                        local total = 0
                        for _, b in ipairs(found) do total = total + #b.idxs end
                        _log(string.format("foliage ledger #%d bound: %d instance(s) re-hidden across %d component(s)",
                            li, total, #found))
                    else
                        -- a silent failure taught nothing (Aurora: "it's not invisible") -
                        -- say so, throttled, with enough numbers to diagnose the miss
                        killed_this_load["folmiss" .. li] = (tonumber(killed_this_load["folmiss" .. li]) or 0) + 1
                        if killed_this_load["folmiss" .. li] % 10 == 1 then
                            _log(string.format("foliage ledger #%d NOT FOUND at U(%.1f, %.1f) render(%.1f, %.1f) - no instance within 2m (miss %s)",
                                li, e.x, e.z, ex, ez, tostring(killed_this_load["folmiss" .. li])))
                        end
                        -- 50 straight misses = the record's coordinates are broken (likely
                        -- a sheared delta at record time); the ZONE covers the plot now,
                        -- so retire it instead of spamming the log forever
                        if killed_this_load["folmiss" .. li] >= 50 then
                            e.retired = true
                            _save()
                            _log("foliage ledger #" .. li .. " RETIRED (unfindable; the zone rule covers the plot)")
                        end
                    end
                end
            end
        end
    end
    -- 2) CHOP PERMANENCE (presence-diff): a tree seen standing on an earlier pass, with
    -- the player never leaving the area, that is now GONE = the player felled it. Two
    -- consecutive missing passes required (streaming-hiccup guard), then it ledgers.
    if M.chop_watch then
        local now = os.clock()
        local live = {}
        for _, t in ipairs(trees) do
            if t.go then
                local a = nil
                pcall(function() a = t.go:get_address() end)
                if a then
                    live[a] = true
                    seen[a] = { name = t.name, x = t.x + d.x, y = t.y + d.y, z = t.z + d.z, at = now, missing = 0 }
                end
            end
        end
        for a, e in pairs(seen) do
            if not live[a] then
                e.missing = (e.missing or 0) + 1
                if e.missing >= 2 then
                    -- already ledgered? (a re-kill this pass also reads as missing)
                    local dup = false
                    for _, le in ipairs(ledger) do
                        local dx, dz = e.x - le.x, e.z - le.z
                        if dx * dx + dz * dz < 2.5 ^ 2 then dup = true; break end
                    end
                    if not dup then
                        ledger[#ledger + 1] = { name = e.name, x = e.x, y = e.y, z = e.z, chopped = true }
                        _save()
                        _log(string.format("CHOP recorded: %s at U(%.0f, %.0f) - it stays down (ledger=%d)",
                            tostring(e.name), e.x, e.z, #ledger))
                        M.last = "a felled tree was recorded - it will not return"
                    end
                    seen[a] = nil
                end
            end
        end
    end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("IRIS Tree Clear (the homestead stays clear)") then return end
    _load()
    imgui.text(M.last)
    imgui.text("known tree ids: gm80_109, gm80_110 (survey more biomes to grow the list)")
    local c
    imgui.separator()
    c, M.zone_on = imgui.checkbox("TREELESS PLOTS: every owned plot destroys ALL its trees, forever##itc_zone", M.zone_on ~= false)
    c, M.zone_radius = imgui.slider_float("treeless radius around each plot (m)##itc_zr", tonumber(M.zone_radius) or 45.0, 15.0, 90.0)
    if imgui.button("rescan the zone now##itc_zs") then
        zone.scanned = false
        zone.cache = {}
        zone.apply_i = 1
        zone.gimmick_done = false
    end
    imgui.text("zone: " .. tostring(#(zone.cache or {})) .. " tree instance(s) held invisible; panel status reports verified shrink")
    imgui.text("Tree removal is clamped to the owned-plot radius; the old loose PIN/CLEAR routes are retired.")
    imgui.tree_pop()
end)
