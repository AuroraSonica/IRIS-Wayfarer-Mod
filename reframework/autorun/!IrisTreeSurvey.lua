-- !IrisTreeSurvey.lua - RECEIPTS FIRST for the homestead tree-clearing ask (2026-08-12)
-- Aurora: "trees make everything worse - can we destroy trees near the homestead
-- permanently?" Before any clearing campaign exists we need to know what a tree IS here:
-- scenery composite? own GameObject? what collider family? So: stand at the offending
-- trees, press SURVEY, and everything mesh-bearing within the radius goes to
-- IRIS/tree_survey.json with names, sizes and component inventories. The clearing
-- campaign (hide mesh + kill collision, re-asserted per approach like the grass ledger)
-- gets built against THESE receipts, not guesses.

local M = { last = "(idle) stand near the trees and press SURVEY", radius = 30.0, fol_r = 8.0 }
local pending = false
local fol_pending, fol_hide_pending, fol_restore_pending = false, false, false
local fol_hidden = {}   -- { comp, index } hidden by the TEST button (session-only, restorable)

local function _log(s)
    pcall(function()
        local f = io.open("IRIS/tree_survey_log.txt", "a")
        if f then f:write(string.format("[%s] %s\n", os.date("%H:%M:%S"), tostring(s))); f:close() end
    end)
end

local function _survey()
    local out = {}
    local ok = pcall(function()
        local pl = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
        local pp = pl:call("get_GameObject"):call("get_Transform"):call("get_Position")
        local sm = sdk.get_native_singleton("via.SceneManager")
        local smt = sdk.find_type_definition("via.SceneManager")
        local scene = sdk.call_native_func(sm, smt, "get_CurrentScene")
        local comps = scene:call("findComponents(System.Type)", sdk.typeof("via.render.Mesh"))
        local cnt = 0
        pcall(function() cnt = comps:call("get_Length") or 0 end)
        if cnt == 0 then pcall(function() cnt = comps:get_size() or 0 end) end
        local r2 = (tonumber(M.radius) or 30.0) ^ 2
        for i = 0, (tonumber(cnt) or 0) - 1 do
            if #out >= 400 then break end
            pcall(function()
                local c
                pcall(function() c = comps:call("get_Item", i) end)
                if not c then pcall(function() c = comps:get_element(i) end) end
                local go = c and c:call("get_GameObject")
                local p = go and go:call("get_Transform"):call("get_Position")
                if not p then return end
                local dx, dz = p.x - pp.x, p.z - pp.z
                if dx * dx + dz * dz > r2 then return end
                local e = { name = tostring(go:call("get_Name") or "?"),
                    dist = math.floor(math.sqrt(dx * dx + dz * dz) * 10) / 10,
                    x = p.x, y = p.y, z = p.z }
                pcall(function()
                    local ab = c:call("get_WorldAABB")
                    local a, b = ab:get_field("minpos"), ab:get_field("maxpos")
                    e.w = math.floor((b.x - a.x) * 10) / 10
                    e.h = math.floor((b.y - a.y) * 10) / 10
                    e.d = math.floor((b.z - a.z) * 10) / 10
                end)
                pcall(function()
                    local arr = go:call("get_Components")
                    local names = {}
                    for j = 0, (arr:get_size() or 1) - 1 do
                        pcall(function()
                            local td = arr:get_element(j):get_type_definition()
                            names[#names + 1] = td and td:get_full_name() or "?"
                        end)
                    end
                    e.comps = table.concat(names, " ")
                end)
                out[#out + 1] = e
            end)
        end
        table.sort(out, function(a, b) return (a.h or 0) > (b.h or 0) end)
    end)
    if ok and #out > 0 then
        json.dump_file("IRIS/tree_survey.json", out)
        local tall = 0
        for _, e in ipairs(out) do if (e.h or 0) > 4.0 then tall = tall + 1 end end
        M.last = string.format("surveyed %d mesh objects within %dm (%d taller than 4m) -> IRIS/tree_survey.json",
            #out, math.floor(M.radius), tall)
        _log(M.last)
        for i = 1, math.min(8, #out) do
            local e = out[i]
            _log(string.format("  TALL #%d: %s  h=%.1f w=%.1f  %dm away  comps: %s",
                i, e.name, e.h or 0, e.w or 0, math.floor(e.dist or 0), tostring(e.comps or "?"):sub(1, 160)))
        end
    else
        M.last = "survey found nothing (or no player) - see tree_survey_log.txt"
        _log("survey empty ok=" .. tostring(ok))
    end
end

-- ── FOLIAGE lane (the big-oak hypothesis): the 30m mesh survey saw NO tall world object
-- where the canopy giants stand, so they are not GameObjects - the strong candidate is
-- via.landscape.Foliage INSTANCES (the grass campaign's own layer; per-instance
-- setVisibility is proven there). These buttons run the decisive experiment.
local function _pl_pos()
    local p
    pcall(function()
        p = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
            :call("get_GameObject"):call("get_Transform"):call("get_Position")
    end)
    return p
end
local function _set_fol_vis(comp, index, visible)
    -- ⛔ the EXACT overload (the 264-native-AV law from the grass campaign)
    if not comp or not sdk.is_managed_object(comp) then return false end
    return pcall(function()
        comp:call("setVisibility(System.UInt32, System.Boolean)", math.floor(index), visible)
    end)
end
local function _fol_walk(radius, fn)
    -- fn(comp, index, pos) for every foliage instance within radius of the player
    local pp = _pl_pos()
    if not pp then return 0 end
    local touched = 0
    pcall(function()
        local sm = sdk.get_native_singleton("via.SceneManager")
        local smt = sdk.find_type_definition("via.SceneManager")
        local scene = sdk.call_native_func(sm, smt, "get_CurrentScene")
        local arr = scene:call("findComponents(System.Type)", sdk.typeof("via.landscape.Foliage"))
        local n = arr and arr:get_size() or 0
        local r2 = radius * radius
        for ci = 0, (tonumber(n) or 0) - 1 do
            pcall(function()
                local c = arr:get_element(ci)
                local cnt = tonumber(c:call("get_InstanceCount")) or 0
                if cnt == 0 then return end
                -- proxy cull: instance 0 within 300m keeps the walk sane
                local p0 = c:call("getWorldPosition", 0)
                if not p0 then return end
                local dx0, dz0 = p0.x - pp.x, p0.z - pp.z
                if dx0 * dx0 + dz0 * dz0 > 300.0 ^ 2 then return end
                for i = 0, cnt - 1 do
                    pcall(function()
                        local p = c:call("getWorldPosition", i)
                        if p then
                            local dx, dz = p.x - pp.x, p.z - pp.z
                            if dx * dx + dz * dz <= r2 then
                                touched = touched + 1
                                fn(c, i, p)
                            end
                        end
                    end)
                end
            end)
        end
    end)
    return touched
end
local function _fol_census()
    local per = {}
    local n = _fol_walk(tonumber(M.fol_r) or 8.0, function(c, i, p)
        local a = tostring(c:get_address())
        per[a] = per[a] or { cnt = 0, comp = c }
        per[a].cnt = per[a].cnt + 1
    end)
    local lines = 0
    for a, e in pairs(per) do
        lines = lines + 1
        local total = 0
        pcall(function() total = tonumber(e.comp:call("get_InstanceCount")) or 0 end)
        _log(string.format("  foliage comp %s: %d instance(s) within %dm (component holds %d total)",
            a, e.cnt, math.floor(M.fol_r), total))
    end
    M.last = string.format("foliage census: %d instance(s) in %d component(s) within %dm -> tree_survey_log.txt",
        n, lines, math.floor(M.fol_r))
    _log(M.last)
end
local function _fol_hide()
    local n = _fol_walk(tonumber(M.fol_r) or 8.0, function(c, i, p)
        if _set_fol_vis(c, i, false) then
            fol_hidden[#fol_hidden + 1] = { comp = c, index = i }
        end
    end)
    M.last = string.format("TEST HIDE: %d foliage instance(s) hidden within %dm - did the big tree vanish? (walk into its spot: does an invisible trunk still block?)",
        n, math.floor(M.fol_r))
    _log(M.last)
end
local function _fol_restore()
    local n = 0
    for i = #fol_hidden, 1, -1 do
        local e = fol_hidden[i]
        if _set_fol_vis(e.comp, e.index, true) then n = n + 1 end
        table.remove(fol_hidden, i)
    end
    M.last = "restored " .. n .. " hidden foliage instance(s)"
    _log(M.last)
end

-- ── TRUNK COLLISION probe: after a big tree is hidden, does an unseen trunk still block?
-- The woodcutting header says scenery-tree collision = "the scene-side merged blob" (the
-- house's old wall). This names the collidable(s) at the player's spot and lets us TEST
-- disabling them - then Aurora walks around and reports what ELSE lost collision. That
-- receipt decides whether per-tree collision kill is safe or the blob-wall stands.
local tray = {}
local trunk_cols = {}   -- last probe's collidables (for the disable/enable test)
local trunk_probe_pending, trunk_off_pending, trunk_on_pending = false, false, false
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
local function _tray_vec3(x, y, z)
    local v = ValueType.new(sdk.find_type_definition("via.vec3"))
    v.x, v.y, v.z = x or 0, y or 0, z or 0
    return v
end
local function _trunk_probe()
    trunk_cols = {}
    local pp = _pl_pos()
    if not (pp and _tray_ensure()) then M.last = "trunk probe: no player or ray"; return end
    local seen = {}
    local function ray_between(x1, y1, z1, x2, y2, z2)
        pcall(function()
            tray.filter:set_Group(0); tray.filter:set_Layer(2); tray.filter:set_MaskBits(0)
            tray.result:clear()
            tray.query:call("setRay(via.vec3, via.vec3)", _tray_vec3(x1, y1, z1), _tray_vec3(x2, y2, z2))
            tray.method:call(tray.system, tray.query, tray.result)
            local nhit = tray.result:get_NumContactPoints() or 0
            for i = 0, math.min(nhit, 3) - 1 do
                pcall(function()
                    local col = tray.result:call("getContactCollidable(System.UInt32)", i)
                    if not col then return end
                    local a = tostring(col:get_address())
                    if seen[a] then return end
                    seen[a] = true
                    local goname, tn = "(no GameObject)", "?"
                    pcall(function() tn = col:get_type_definition():get_full_name() end)
                    pcall(function()
                        local go = col:call("get_GameObject")
                        if go then goname = tostring(go:call("get_Name")) end
                    end)
                    pcall(function() col = col:add_ref() end)
                    trunk_cols[#trunk_cols + 1] = { col = col, name = goname, tn = tn }
                    _log(string.format("  trunk collidable: %s  GO='%s'  addr=%s", tn, goname, a))
                end)
            end
        end)
    end
    -- 8 directions, two heights, BOTH ways: a ray STARTED inside a shape never reports it
    -- (the 00:45 zero-collidable miss - Aurora was standing IN the trunk), so the inward
    -- pass casts from a ring 3.5m out, converging on the player.
    for _, dirv in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
        { 0.707, 0.707 }, { -0.707, 0.707 }, { 0.707, -0.707 }, { -0.707, -0.707 } }) do
        for _, hy in ipairs({ 0.5, 1.3 }) do
            ray_between(pp.x, pp.y + hy, pp.z,
                pp.x + dirv[1] * 3.5, pp.y + hy, pp.z + dirv[2] * 3.5)
            ray_between(pp.x + dirv[1] * 3.5, pp.y + hy, pp.z + dirv[2] * 3.5,
                pp.x, pp.y + hy, pp.z)
        end
    end
    M.last = "trunk probe: " .. #trunk_cols .. " collidable(s) named -> tree_survey_log.txt"
    _log("trunk probe at player: " .. #trunk_cols .. " unique collidable(s)")
end
-- v2 (00:39 receipt: set_Enabled "succeeded" but the trunk still blocked): dump the REAL
-- API surface, then fire every plausible kill route incl. the collision module's own
-- refresh ritual (updateCollisionFilter + updateBroadphase - a stale broadphase ignores
-- flag flips). The Colliders-component disable may kill the whole patch - that is the
-- GRANULARITY receipt: the walk afterward tells us what one switch actually covers.
local function _trunk_dump()
    for _, e in ipairs(trunk_cols) do
        pcall(function()
            local td = e.col:get_type_definition()
            local ms, depth = {}, 0
            while td and depth < 3 do
                for _, m in ipairs(td:get_methods()) do
                    local ln = m:get_name():lower()
                    if ln:find("enable") or ln:find("valid") or ln:find("active") or ln:find("shape")
                        or ln:find("filter") or ln:find("layer") or ln:find("attr") or ln:find("restraint") then
                        ms[#ms + 1] = m:get_name()
                    end
                end
                td = td:get_parent_type()
                depth = depth + 1
            end
            _log("collidable API (" .. tostring(e.tn) .. "): " .. table.concat(ms, " "))
        end)
        pcall(function()
            local go = e.col:call("get_GameObject")
            local arr = go:call("get_Components")
            local names = {}
            for j = 0, (arr:get_size() or 1) - 1 do
                pcall(function() names[#names + 1] = arr:get_element(j):get_type_definition():get_full_name() end)
            end
            _log("'" .. tostring(e.name) .. "' GO components: " .. table.concat(names, " "))
        end)
    end
end
-- v3 SPLIT (the 00:48 kill WORKED but fired everything at once - granularity unknown):
-- SURGICAL = only the probed collidable's own set_Enabled + the refresh ritual.
-- BROAD    = adds Colliders.set_Enabled on the Foliage GO (likely the WHOLE patch).
-- Test order after a reset: probe -> SURGICAL -> walk. If surgical alone opens the
-- trunk while neighbors stay solid, that is the knife the ledger automates.
local function _trunk_set(on, broad)
    if not on then _trunk_dump() end
    for _, e in ipairs(trunk_cols) do
        local r = {}
        if pcall(function() e.col:call("set_Enabled", on) end) then r[#r + 1] = "col.set_Enabled" end
        if pcall(function() e.col:call("set_Valid", on) end) then r[#r + 1] = "col.set_Valid" end
        if pcall(function() e.col:call("setValid", on) end) then r[#r + 1] = "col.setValid" end
        pcall(function()
            local go = e.col:call("get_GameObject")
            local cs = go:call("getComponent(System.Type)", sdk.typeof("via.physics.Colliders"))
            if cs then
                if broad or on then
                    -- restore always re-enables the component (whichever kill ran)
                    if pcall(function() cs:call("set_Enabled", on) end) then r[#r + 1] = "Colliders.set_Enabled" end
                end
                if pcall(function() cs:call("updateCollisionFilter") end) then r[#r + 1] = "updateCollisionFilter" end
                if pcall(function() cs:call("updateBroadphase", true) end) then r[#r + 1] = "updateBroadphase(t)" end
                pcall(function() cs:call("updateBroadphase") end)
            end
        end)
        _log(string.format("%s(%s) routes on %s: %s", on and "RESTORE" or "KILL",
            broad and "broad" or "surgical", tostring(e.tn), table.concat(r, ", ")))
    end
    M.last = on and "restore fired - collision should be back"
        or ((broad and "BROAD" or "SURGICAL") .. " kill fired - walk the trunk, then the NEIGHBOR trees")
    _log(M.last)
end

-- ── ⭐ 08-19 PER-TREE COLLISION HUNT (Aurora: "I bet you could find a per-tree kill") ──────
-- The 08-13 wall: SpeedTree trunk COLLIDABLES are shared per tree MODEL - any flag flip goes
-- world-wide by architecture. Two layers were never probed: (1) via.dynamics.RigidBodyMeshSet
-- on the same Foliage GO (a mesh SET suggests per-instance bodies = the surgical lever), and
-- (2) per-instance TRANSFORM writes on via.landscape.Foliage (a position setter + collision
-- following the instance = sink ONE tree underground, nothing shared ever touched).
-- This dump names both layers' REAL methods (⛔ never guess names - typedef-dump first law);
-- the sink/kill gets wired NEXT round from these receipts. Output: IRIS/pertree_probe.txt
local pertree_pending = false
local function _pertree_dump()
    local pp = _pl_pos()
    if not pp then M.last = "no player"; return end
    local f = io.open("IRIS/pertree_probe.txt", "w")
    if not f then M.last = "cannot open pertree_probe.txt"; return end
    f:write("PER-TREE PROBE " .. os.date("%Y-%m-%d %H:%M:%S")
        .. string.format("  player(%.2f,%.2f,%.2f) radius=%.0f\n\n", pp.x, pp.y, pp.z, M.radius or 30.0))
    local function dump_methods(obj, label, filter)
        pcall(function()
            local td = obj:get_type_definition()
            f:write("== " .. label .. " (" .. td:get_full_name() .. ") ==\n")
            local depth = 0
            while td and depth < 4 do
                for _, m in ipairs(td:get_methods()) do
                    local nm = m:get_name()
                    if (not filter) or filter(nm:lower()) then
                        local ps = {}
                        pcall(function()
                            for _, pt in ipairs(m:get_param_types()) do ps[#ps + 1] = pt:get_full_name() end
                        end)
                        local rt = ""
                        pcall(function() rt = m:get_return_type():get_full_name() end)
                        f:write(string.format("  %s(%s) -> %s\n", nm, table.concat(ps, ", "), rt))
                    end
                end
                td = td:get_parent_type(); depth = depth + 1
            end
            f:write("\n")
        end)
    end
    -- foliage comps with an instance inside the radius; nearest instance = the sink target
    local sm = sdk.get_native_singleton("via.SceneManager")
    local scene = sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    local comps = scene:call("findComponents(System.Type)", sdk.typeof("via.landscape.Foliage"))
    local n = 0
    pcall(function() n = comps:call("get_Length") or 0 end)
    if n == 0 then pcall(function() n = comps:get_size() or 0 end) end
    local hit_gos, dumped, best = {}, 0, nil
    local r2 = (M.radius or 30.0) ^ 2
    for i = 0, (tonumber(n) or 0) - 1 do
        pcall(function()
            local c
            pcall(function() c = comps:call("get_Item", i) end)
            if not c then c = comps:get_element(i) end
            if not c then return end
            local cnt = 0; pcall(function() cnt = tonumber(c:call("get_InstanceCount")) or 0 end)
            local near_k = nil
            for k = 0, math.min(cnt, 3000) - 1 do
                local wp; pcall(function() wp = c:call("getWorldPosition", k) end)
                if wp then
                    local d2 = (wp.x - pp.x) ^ 2 + (wp.z - pp.z) ^ 2
                    if d2 < r2 then
                        near_k = near_k or k
                        if (not best) or d2 < best.d2 then best = { comp = c, k = k, d2 = d2, wp = wp } end
                    end
                end
            end
            if near_k == nil then return end
            local go; pcall(function() go = c:call("get_GameObject") end)
            if not go or hit_gos[go:get_address()] then return end
            hit_gos[go:get_address()] = true
            dumped = dumped + 1
            if dumped > 3 then return end   -- 3 GOs of receipts is plenty
            local gname = "?"; pcall(function() gname = go:call("get_Name") end)
            f:write(string.format("---- GO '%s' (comp instances=%d, first near idx=%d) ----\n", tostring(gname), cnt, near_k))
            -- (1) the PRIZE: RigidBodyMeshSet full API + parameterless getter values
            pcall(function()
                local rbs = go:call("getComponent(System.Type)", sdk.typeof("via.dynamics.RigidBodyMeshSet"))
                if not rbs then f:write("  (no via.dynamics.RigidBodyMeshSet on this GO)\n\n"); return end
                dump_methods(rbs, "RigidBodyMeshSet FULL API", nil)
                f:write("== RigidBodyMeshSet live getter values ==\n")
                -- ⛔ 08-19 CRASH LESSON (first run CTD'd AFTER a clean dump = the Lua-wrapper
                -- UAF family): the old sweep blind-called EVERY get_* incl. object-returning
                -- ones (get_World, get_MeshResources, get_Chain) and let the wrappers fall to
                -- GC. Whitelist of primitive-return getters ONLY, nothing wrapped:
                for _, gn in ipairs({ "getMeshResourcesCount", "getResourcesCount",
                        "get_NumRigidBodies", "get_Enabled", "get_CurrentEnabled",
                        "get_Static", "get_DisableRigidBodies", "get_CalculateTypes" }) do
                    pcall(function()
                        local v = rbs:call(gn)
                        local tv = type(v)
                        if tv == "number" or tv == "boolean" or tv == "string" then
                            f:write(string.format("  %s = %s\n", gn, tostring(v)))
                        end
                    end)
                end
                f:write("\n")
            end)
            -- (2) foliage per-instance surface: anything instance-addressed or transform-shaped
            dump_methods(c, "Foliage instance-addressed methods", function(ln)
                return ln:find("instance") or ln:find("matrix") or ln:find("position") or ln:find("transform")
                    or ln:find("visib") or ln:find("fade") or ln:find("scale") or ln:find("remove")
                    or ln:find("delete") or ln:find("hide") or ln:find("count") or ln:find("collision")
            end)
        end)
    end
    if best then
        f:write(string.format("SINK TARGET (nearest instance): idx=%d dist=%.1fm world(%.2f,%.2f,%.2f)\n",
            best.k, math.sqrt(best.d2), best.wp.x, best.wp.y, best.wp.z))
    else
        f:write("no foliage instance inside the radius - stand nearer a tree\n")
    end
    f:close()
    collectgarbage("collect")   -- UAF law: flush stray wrappers NOW, while their state is valid
    M.last = string.format("PER-TREE dump: %d GO(s) -> IRIS/pertree_probe.txt (stand at a BIG tree for best receipts)",
        math.min(dumped, 3))
    _log(M.last)
end

-- ── ⭐ 08-19 THE FIELD TEST: per-tree SINK + REMOVE (wired from the probe receipts) ────────
-- Receipts said: setLocalPosition(UInt32, via.vec3) + removeFoliageInstance(UInt16[]) exist;
-- RigidBodyMeshSet = ONE merged body per patch (so per-instance physics does NOT live there).
-- The open question these buttons answer: does trunk COLLISION follow the instance?
-- Ritual: test AWAY from the homestead, ONE tree, then WALK where it stood. Game restart
-- (or UNDO for sink) restores everything - engine state, never saved.
local sink = nil   -- { comp, idx, orig = {x,y,z} } - the one sunk instance, for UNDO
local sink_pending, unsink_pending, remove_pending = false, false, false
local function _nearest_instance(maxd)
    local pp = _pl_pos(); if not pp then return nil end
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
                local cnt = 0; pcall(function() cnt = tonumber(c:call("get_InstanceCount")) or 0 end)
                for k = 0, math.min(cnt, 3000) - 1 do
                    local wp; pcall(function() wp = c:call("getWorldPosition", k) end)
                    if wp then
                        local d2 = (wp.x - pp.x) ^ 2 + (wp.z - pp.z) ^ 2
                        if d2 <= maxd * maxd and ((not best) or d2 < best.d2) then
                            best = { comp = c, k = k, d2 = d2, wy = wp.y }
                        end
                    end
                end
            end)
        end
    end)
    return best
end
local function _sink_test()
    if sink then M.last = "a tree is already sunk - UNDO SINK first (one at a time)"; return end
    local best = _nearest_instance(3.0)
    if not best then M.last = "no foliage instance within 3m - stand AT the trunk"; return end
    local lp
    local okl = pcall(function() lp = best.comp:call("getLocalPosition(System.UInt32)", best.k) end)
    if not (okl and lp) then
        M.last = "getLocalPosition failed - receipts in the log"
        _log("SINK abort: getLocalPosition(System.UInt32) idx=" .. tostring(best.k) .. " failed")
        return
    end
    sink = { comp = best.comp, idx = best.k, orig = { x = lp.x, y = lp.y, z = lp.z } }
    local oks = pcall(function()
        best.comp:call("setLocalPosition(System.UInt32, via.vec3)", best.k,
            _tray_vec3(lp.x, lp.y - 500.0, lp.z))
    end)
    local wy2; pcall(function() local wp = best.comp:call("getWorldPosition", best.k); wy2 = wp and wp.y end)
    M.last = string.format("SINK idx=%d set=%s worldY %.1f -> %s | WALK the spot: mesh gone? trunk gone? NEIGHBORS intact?",
        best.k, tostring(oks), best.wy or 0, tostring(wy2 and string.format("%.1f", wy2) or "?"))
    _log(M.last)
    if not oks then sink = nil end
    collectgarbage("collect")
end
local function _unsink()
    if not sink then M.last = "nothing sunk"; return end
    local ok = pcall(function()
        sink.comp:call("setLocalPosition(System.UInt32, via.vec3)", sink.idx,
            _tray_vec3(sink.orig.x, sink.orig.y, sink.orig.z))
    end)
    M.last = "UNDO SINK idx=" .. tostring(sink.idx) .. " restore=" .. tostring(ok)
    _log(M.last)
    sink = nil
    collectgarbage("collect")
end
local function _remove_test()
    local best = _nearest_instance(3.0)
    if not best then M.last = "no foliage instance within 3m - stand AT the trunk"; return end
    if best.k > 65535 then M.last = "idx > UInt16 range - cannot remove this one"; return end
    local arr
    pcall(function() arr = sdk.create_managed_array("System.UInt16", 1) end)
    if not arr then M.last = "create_managed_array(System.UInt16,1) failed"; _log(M.last); return end
    pcall(function() arr:add_ref() end)
    -- fill + VERIFY before firing (⛔ an unverified zero array would remove instance 0 = a
    -- random tree). Two routes, then a readback:
    local routes = {}
    if pcall(function() arr[0] = best.k end) then routes[#routes + 1] = "index-assign" end
    pcall(function() arr:call("SetValue(System.Object, System.Int32)", best.k, 0); routes[#routes + 1] = "SetValue" end)
    local rb = nil
    pcall(function()
        local v = arr:call("GetValue(System.Int32)", 0)
        rb = tonumber(v) or tonumber(tostring(v))
        if rb == nil and v ~= nil then rb = tonumber(v:call("ToString()")) end
    end)
    if rb ~= best.k then
        M.last = string.format("REMOVE abort: array fill unverified (want %d, readback %s; routes: %s)",
            best.k, tostring(rb), table.concat(routes, ","))
        _log(M.last)
        collectgarbage("collect")
        return
    end
    local res = nil
    local okr = pcall(function()
        res = best.comp:call("removeFoliageInstance(System.UInt16[])", arr)
    end)
    M.last = string.format("REMOVE idx=%d call=%s result=%s | WALK the spot + check NEIGHBORS (restart restores)",
        best.k, tostring(okr), tostring(res))
    _log(M.last)
    collectgarbage("collect")
end

re.on_application_entry("UpdateBehavior", function()
    if pending then
        pending = false
        pcall(_survey)
    end
    if fol_pending then fol_pending = false; pcall(_fol_census) end
    if fol_hide_pending then fol_hide_pending = false; pcall(_fol_hide) end
    if fol_restore_pending then fol_restore_pending = false; pcall(_fol_restore) end
    if trunk_probe_pending then trunk_probe_pending = false; pcall(_trunk_probe) end
    if pertree_pending then pertree_pending = false; pcall(_pertree_dump) end
    if sink_pending then sink_pending = false; pcall(_sink_test) end
    if unsink_pending then unsink_pending = false; pcall(_unsink) end
    if remove_pending then remove_pending = false; pcall(_remove_test) end
    if trunk_off_pending then
        local mode = trunk_off_pending
        trunk_off_pending = false
        pcall(function() _trunk_set(false, mode == "broad") end)
    end
    if trunk_on_pending then trunk_on_pending = false; pcall(function() _trunk_set(true, true) end) end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("IRIS Tree Survey (receipts for the clearing campaign)") then return end
    imgui.text(M.last)
    local c
    c, M.radius = imgui.slider_float("radius (m)##its", tonumber(M.radius) or 30.0, 10.0, 60.0)
    if imgui.button("SURVEY: dump every mesh object around me##its_go") then pending = true end
    imgui.text("Stand at the offending trees first. Tallest objects logged to")
    imgui.text("tree_survey_log.txt; full dump in IRIS/tree_survey.json.")
    imgui.separator()
    imgui.text("BIG TREES (not gimmicks): the foliage-layer experiment")
    c, M.fol_r = imgui.slider_float("foliage radius (m)##its_fr", tonumber(M.fol_r) or 8.0, 2.0, 20.0)
    if imgui.button("FOLIAGE census (count leafy instances around me)##its_fc") then fol_pending = true end
    if imgui.button("TEST HIDE: vanish all foliage within the radius##its_fh") then fol_hide_pending = true end
    imgui.same_line()
    if imgui.button("RESTORE hidden##its_fu") then fol_restore_pending = true end
    imgui.text("Stand UNDER the big oak, small radius, TEST HIDE. If it vanishes = the")
    imgui.text("lever is found. Then walk into its spot: does an unseen trunk still block?")
    imgui.separator()
    imgui.text("TRUNK COLLISION (the invisible blocker where a felled tree stood)")
    if imgui.button("PROBE: name the collidables around me##its_tp") then trunk_probe_pending = true end
    if imgui.button("PER-TREE HUNT: dump RigidBodyMeshSet + instance APIs##its_pt") then pertree_pending = true end
    imgui.text("per-tree kill test (stand AT the trunk; test AWAY from home; restart restores):")
    if imgui.button("SINK nearest tree (-500m, reversible)##its_sk") then sink_pending = true end
    imgui.same_line()
    if imgui.button("UNDO SINK##its_us") then unsink_pending = true end
    if imgui.button("REMOVE nearest tree (native delete, restores on re-stream/restart)##its_rm") then remove_pending = true end
    if imgui.button("KILL surgical (this collidable only)##its_ts") then trunk_off_pending = "surgical" end
    imgui.same_line()
    if imgui.button("KILL broad (whole Foliage component)##its_tb") then trunk_off_pending = "broad" end
    imgui.same_line()
    if imgui.button("re-enable##its_ton") then trunk_on_pending = true end
    imgui.text("Order: PROBE, then SURGICAL, walk the trunk AND the neighbor trees. Only if")
    imgui.text("surgical fails, try BROAD. The winning knife is what the ledger automates.")
    imgui.tree_pop()
end)
