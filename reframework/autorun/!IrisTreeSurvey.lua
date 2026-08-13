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

re.on_application_entry("UpdateBehavior", function()
    if pending then
        pending = false
        pcall(_survey)
    end
    if fol_pending then fol_pending = false; pcall(_fol_census) end
    if fol_hide_pending then fol_hide_pending = false; pcall(_fol_hide) end
    if fol_restore_pending then fol_restore_pending = false; pcall(_fol_restore) end
    if trunk_probe_pending then trunk_probe_pending = false; pcall(_trunk_probe) end
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
    if imgui.button("KILL surgical (this collidable only)##its_ts") then trunk_off_pending = "surgical" end
    imgui.same_line()
    if imgui.button("KILL broad (whole Foliage component)##its_tb") then trunk_off_pending = "broad" end
    imgui.same_line()
    if imgui.button("re-enable##its_ton") then trunk_on_pending = true end
    imgui.text("Order: PROBE, then SURGICAL, walk the trunk AND the neighbor trees. Only if")
    imgui.text("surgical fails, try BROAD. The winning knife is what the ledger automates.")
    imgui.tree_pop()
end)
