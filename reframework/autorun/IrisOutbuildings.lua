-- IrisOutbuildings.lua - player-buildable outbuildings on homestead plots (v1, 2026-08-12)
-- Taken over from the closed homestead-arc session; implements the site half of the
-- iris-outbuildings-menu-handoff contract. The Homestead Screen's Build tab places a SITE
-- (place_site); this module owns everything after: the gather-materials stage (the deed
-- sign's proven getHaveNum/deleteItem kit), the native raise dialog, the hammer build
-- scene (bank 61 clips 4100/4101/4102, the purchase flow's), the forge build via
-- _G.IrisForge.build_kit (per-tag, blocker 1: the site KEY is the persistent tag), and
-- the collision refresh (flat union pool: park -> add re-grafts everything standing).
-- ⛔ Reviewer blockers honored: (4) kit_ready checked BEFORE materials are consumed;
-- (6) every build/rebuild gates on forge.building + collision.busy + homestead inflight
-- + plots.busy; (5) settle detection is SELF-CONTAINED (>50m player jump = hold off).
-- Dialog mutex (9): our dialog only opens when no other IRIS screen or dialog is up.

local SITES_FILE = "IRIS/iris_outbuildings.json"
local STONE_ITEM, TIMBER_ITEM = 34710, 34711
local M = { last = "(idle)" }
local sites = nil
local scene = nil              -- the hammer build scene { stage, t, site }
local dlg = { open = false }   -- own dialog latch (never shared - the sticky-state law)
local pass_at = 0.0
local settle_until = 0.0
local last_pu = nil
local card = nil               -- { title, body, col } fed to IrisFont every frame

local function _log(s)
    pcall(function()
        local f = io.open("IRIS/outbuildings_log.txt", "a")
        if f then f:write(string.format("[%s] %s\n", os.date("%H:%M:%S"), tostring(s))); f:close() end
    end)
end
local function _load()
    if sites then return end
    sites = json.load_file(SITES_FILE) or {}
end
local function _save() pcall(function() json.dump_file(SITES_FILE, sites or {}) end) end

-- ── player kit (the deed sign's proven lines) ───────────────────────────────────────────
local function _pch()
    local ch
    pcall(function() ch = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer") end)
    return ch
end
local function _ptf()
    local ch = _pch()
    local tf
    pcall(function() tf = ch:call("get_GameObject"):call("get_Transform") end)
    return tf
end
local function _pupos()
    local tf = _ptf()
    local p
    if tf then pcall(function() p = tf:call("get_UniversalPosition") end) end
    return p
end
local function _fsm_enabled(on)
    pcall(function()
        local h = _pch():call("get_Human")
        if h and h.Fsm then h.Fsm:set_Enabled(on) end
    end)
end
local function _play_clip(bank, clip)
    return pcall(function()
        _pch():call("get_Motion"):call("getLayer", 0):call(
            "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
            bank, clip, 0.0, 6.0, 1, 1)
    end)
end
local function _count_item(id)
    local n = 0
    pcall(function()
        local im = sdk.get_managed_singleton("app.ItemManager")
        local ch = _pch():call("get_Character")
        if not ch then ch = _pch() end
        n = tonumber(im:call("getHaveNum(System.Int32, app.Character)", id, ch)) or 0
    end)
    return n
end
local function _consume_item(id, n)
    if n <= 0 then return true end
    local before = _count_item(id)
    if before < n then return false end
    local ok = false
    pcall(function()
        local im = sdk.get_managed_singleton("app.ItemManager")
        local ch = _pch():call("get_Character")
        if not ch then ch = _pch() end
        im:call("deleteItem(System.Int32, System.Int32, app.Character)", id, n, ch)
        ok = _count_item(id) <= before - n
    end)
    return ok
end

-- ── native dialog (own latch; DeedSign's RetVal law: None=0 Sel0=1 Sel1=2 Cancel=5) ──────
local DIALOG_GUITYPE = 14
local function _dialog_pick()
    local p
    pcall(function()
        local gm = sdk.get_managed_singleton("app.GuiManager")
        local rv = gm and gm:call("getDialogState")
        if rv == nil then return end
        if type(rv) == "number" then p = rv
        else pcall(function() p = sdk.to_int64(rv) & 0xFFFFFFFF end) end
    end)
    return p
end
local function _other_ui_busy()
    -- dialog mutex (obligation 9) + screen mutex: never talk over another conversation
    if _G.IrisFurnishUIOpen == true or _G.IrisFurnishFootprint == true then return true end
    if _G.IrisStableUIOpen == true then return true end
    -- ⛔ 08-13 (receipts: "WAITING ui_busy=true ... EXPIRED"): the Dialog RetVal is
    -- the LAST answer ever given and stays nonzero forever after any dialog - a
    -- stale answer is not a live conversation. Busy only while the value is FRESH
    -- (changed within 4s); an unchanged leftover stops gating us.
    local pick = _dialog_pick()
    if pick ~= M._lastpick then M._lastpick = pick; M._pickat = os.clock() end
    -- (08-13 round 2, Aurora: "taking forever") 4.0s -> 1.0s: the runes screen
    -- itself bumps the RetVal on close, so a long freshness window made every
    -- examine wait out the whole guard before the dialog could land
    if pick ~= nil and pick ~= 0 and not dlg.open
        and os.clock() - (tonumber(M._pickat) or 0) < 1.0 then return true end
    return false
end
local function _show_dialog(prompt, opt1, opt2, site, opt3, mode)
    pcall(function()
        local gm = sdk.get_managed_singleton("app.GuiManager")
        local dialog = gm and gm:get_field("Dialog")
        if not dialog then return end
        gm:call("requestGuiType", DIALOG_GUITYPE)
        dialog:call("reqDisp", prompt, opt1, opt2, opt3 or "", "",
            true, 0, true, 58, 0, -1, nil,
            false, false, false, false, false, false, true, 0.0)
        dlg.open = true
        dlg.opened_at = os.clock()
        dlg.baseline = _dialog_pick()
        dlg.site = site
        dlg.mode = mode
    end)
end
local function _close_dialog()
    pcall(function()
        local gm = sdk.get_managed_singleton("app.GuiManager")
        local dialog = gm and gm:get_field("Dialog")
        if dialog then dialog:call("reqClose") end
        gm:call("requestHideGuiType", DIALOG_GUITYPE)
    end)
    dlg.open = false
    dlg.site = nil
    dlg.mode = nil
end
pcall(_close_dialog)   -- softlock guard: a reload must never strand an orphaned dialog

-- ⭐ 08-13 (Aurora: "can the prompt not appear AS you read the sign, like buying
-- land?"): the DeedSign precedent - the choice dialog renders OVER the open runes
-- screen, and the dialog reader is pause-unguarded, so answers land while reading.
-- Returns "dlg" when a dialog opened, "paid" for a pre-paid site (the hammer must
-- NEVER start on a paused frame - that path still waits for the close), nil = no
-- matching site in the "site" state.
local function _examine_dialog(key)
    _load()
    for _, s in ipairs(sites) do
        if s.key == key and s.state == "site" then
            if s.paid then return "paid" end
            local ht = _count_item(TIMBER_ITEM)
            local hs = _count_item(STONE_ITEM)
            local nt, ns = tonumber(s.timber) or 0, tonumber(s.stone) or 0
            if ht >= nt and hs >= ns then
                _show_dialog("Raise the " .. tostring(s.label) .. "?\n"
                    .. string.format("%d Timber, %d Stone", nt, ns),
                    "Raise it", "Not yet", s, "Cancel the commission")
            else
                _show_dialog("The " .. tostring(s.label) .. " wants "
                    .. string.format("%d Timber, %d Stone.", nt, ns),
                    "Cancel the commission", "Leave it", s, "", "poor")
            end
            return "dlg"
        end
    end
    return nil
end

-- ── gates (blocker 6): nothing raises while any heavy pump is mid-flight ────────────────
local function _gates_idle()
    local ok = true
    pcall(function()
        local st = _G.IrisForge and _G.IrisForge.status and _G.IrisForge.status()
        if st and st.building then ok = false end
    end)
    pcall(function()
        if ok and _G.IrisCollision and _G.IrisCollision.busy and _G.IrisCollision.busy() then ok = false end
    end)
    pcall(function()
        if ok and _G.IrisHomestead and _G.IrisHomestead.inflight and _G.IrisHomestead.inflight() then ok = false end
    end)
    pcall(function()
        if ok and _G.IrisHomesteadPlots and _G.IrisHomesteadPlots.busy and _G.IrisHomesteadPlots.busy() then ok = false end
    end)
    return ok
end
local function _kit_row(key)
    local row
    pcall(function()
        for _, k in ipairs(_G.IrisForge.kits()) do if k.key == key then row = k end end
    end)
    return row
end

-- collision refresh after a raise: flat-union law - park the standing pool, then add();
-- the pool's equality gate sees the bigger piece list, tears down and re-grafts EVERYTHING
local function _queue_collision_refresh(site)
    site.coll_pending = true
    site.coll_started = nil
    site.coll_error = nil
    _save()
end
local function _collision_refresh_tick(wanted)
    local due = wanted and wanted.coll_pending and wanted or nil
    if not due then
        for _, s in ipairs(sites or {}) do if s.coll_pending then due = s break end end
    end
    if not due then return end
    if not _gates_idle() then return end
    local C9 = _G.IrisCollision
    if not (C9 and C9.add) then
        due.coll_pending = nil
        due.coll_error = "collision service unavailable"
        _save()
        return
    end
    pcall(function() if C9.park then C9.park() end end)
    local add_ok = pcall(function() C9.add() end)
    local took = false
    pcall(function()
        took = add_ok and ((C9.busy and C9.busy() == true)
            or (C9.count and (tonumber(C9.count()) or 0) > 0))
    end)
    -- consume only on success (blocker 3's law, applied to our own flag)
    if took then
        due.coll_pending = nil
        due.coll_started = os.clock()
        _save()
        _log("collision refresh queued after '" .. tostring(due.label) .. "'")
    elseif not add_ok then
        due.coll_pending = nil
        due.coll_error = "collision build request failed"
        _save()
    end
end

-- ── the contract surface ────────────────────────────────────────────────────────────────
_G.IrisOutbuildings = {
    place_site = function(kit_key, ux, uy, uz, yaw)
        _load()
        local kit = _kit_row(kit_key)
        if not kit then return false, "no such plan ('" .. tostring(kit_key) .. "')" end
        -- an owned + BUILT plot within range anchors every site (the contract's refusal)
        local plot, best
        pcall(function()
            for _, pr in ipairs(_G.IrisHomesteadPlots.list()) do
                if pr.owned ~= false and pr.built ~= false then
                    local dx, dz = (pr.ux or 0) - ux, (pr.uz or 0) - uz
                    local dd = dx * dx + dz * dz
                    if (not best or dd < best) and dd < 60.0 ^ 2 then best = dd; plot = pr end
                end
            end
        end)
        if not plot then return false, "no built homestead plot within 60m of the site" end
        -- blocker 1: the site key is PERSISTENT and unique - it is also the forge tag
        local key = string.format("ob_%s_%s_%d", tostring(plot.name or "plot"), tostring(kit_key), os.time())
        sites[#sites + 1] = {
            key = key, kit = kit_key, label = kit.label or kit_key,
            plot = plot.name, ux = ux, uy = uy, uz = uz, yaw = yaw or 0,
            state = "site", timber = tonumber(kit.timber) or 0, stone = tonumber(kit.stone) or 0,
        }
        _save()
        _log(string.format("SITE placed: %s (%s) at U(%.1f,%.1f,%.1f) yaw=%.0f plot=%s",
            key, kit_key, ux, uy, uz, yaw or 0, tostring(plot.name)))
        return true
    end,
    sites = function()
        _load()
        local t = {}
        for _, s in ipairs(sites) do
            local state = s.state
            if state == "site" then
                state = string.format("gathering: %d/%d Timber, %d/%d Stone",
                    math.min(_count_item(TIMBER_ITEM), s.timber or 0), s.timber or 0,
                    math.min(_count_item(STONE_ITEM), s.stone or 0), s.stone or 0)
            elseif state == "raising" then
                state = "being raised"
            end
            t[#t + 1] = { key = s.key, kit_key = s.kit, label = s.label, state = state }
        end
        return t
    end,
    clear_plot = function(plotname)
        _load()
        local n = 0
        for i = #sites, 1, -1 do
            if sites[i].plot == plotname then
                pcall(function() _G.IrisForge.despawn_tag(sites[i].key) end)
                table.remove(sites, i)
                n = n + 1
            end
        end
        if n > 0 then _save(); _log("cleared " .. n .. " site(s) of plot '" .. tostring(plotname) .. "'") end
        return n
    end,
    -- cancel a commission (the Build tab's X/Del): whatever was given comes back - a
    -- paid-but-unraised site refunds everything; a raised one is demolished for half
    cancel_site = function(key)
        _load()
        for i = #sites, 1, -1 do
            local s = sites[i]
            if s.key == key then
                if s.state == "raising" then
                    -- mid-raise pieces are still in the forge queue: a despawn now would
                    -- orphan the stragglers. Let the hammer finish; cancel after.
                    local bt = nil
                    pcall(function() bt = _G.IrisForge.status().building_tag end)
                    if bt == s.key or scene ~= nil then return false end
                end
                local rt, rs = 0, 0
                if s.state == "built" or s.state == "raising" then
                    rt = math.floor((s.timber or 0) / 2)
                    rs = math.floor((s.stone or 0) / 2)
                elseif s.paid then
                    rt, rs = s.timber or 0, s.stone or 0
                end
                pcall(function() _G.IrisForge.despawn_tag(key) end)
                if rt > 0 or rs > 0 then
                    pcall(function()
                        local im = sdk.get_managed_singleton("app.ItemManager")
                        local ch = _pch():call("get_Character") or _pch()
                        if rt > 0 then im:call("getItem(System.Int32, System.Int32, app.Character)", TIMBER_ITEM, rt, ch) end
                        if rs > 0 then im:call("getItem(System.Int32, System.Int32, app.Character)", STONE_ITEM, rs, ch) end
                    end)
                end
                if scene and scene.site == s then _fsm_enabled(true); scene = nil end
                table.remove(sites, i)
                _save()
                -- record is gone: the reaper may now hunt the physical signboard
                pcall(function() _G.IrisOutbuildings.reap_sign(key, s.ux, s.uz) end)
                _log(string.format("CANCELLED %s (refund %dT %dS)", tostring(key), rt, rs))
                return true, rt, rs
            end
        end
        return false
    end,
    remove_site = function(key)
        _load()
        for i = #sites, 1, -1 do
            if sites[i].key == key then
                pcall(function() _G.IrisForge.despawn_tag(key) end)
                table.remove(sites, i)
                _save()
                return true
            end
        end
        return false
    end,
}

-- ══ ⭐ THE PHYSICAL SIGN (Aurora: "we have the native B prompt on signs, we don't need
-- the fake one"): the deed sign's own gimmick (Gm81_129, brain app.gm81_128) raised at
-- every un-raised site. The native Examine prompt comes free with the gimmick; examining
-- OUR sign queues the raise dialog once the runes close (⛔ never SKIP the interact -
-- the prompt-starvation law). Signs adopt survivors after resets (twin guard).
local signs = {}       -- [site.key] = go (this load's wrappers)
local sign_jobs = {}
-- ⭐ 08-13 (the guid hunt, verified against the deed sign's own runtime harvest of the
-- game catalog): site signs read "A Place to Call Home" - per-instance repoint, the
-- homestead deed sign keeps its own text untouched
local SIGN_MSG_GUID = "2ce20e41-ce98-4384-af94-a161aec625c1"   -- "A Place to Call Home"
local function _sign_repoint(go)
    pcall(function()
        local c = go:call("getComponent(System.Type)", sdk.typeof("app.gm81_128"))
        local prm = c and c:get_field("_Param")
        if not prm then return end
        local g = sdk.find_type_definition("System.Guid"):get_method("Parse(System.String)")
            :call(nil, SIGN_MSG_GUID)
        if not g then return end
        prm:set_field("TitleMessageId", g)
        prm:set_field("MessageId", g)
        pcall(function() c:call("applyGimmickParam") end)
    end)
end
local function _sign_registry()
    _G.IrisOBSigns = _G.IrisOBSigns or {}
    return _G.IrisOBSigns
end
local function _sign_remove(key)
    local go = signs[key]
    if go then pcall(function() go:call("destroy", go) end) end
    signs[key] = nil
    _sign_registry()[key] = nil
end
local function _sign_adopt(s)
    -- a reset survivor within 3m of the site = OUR sign: re-own, never twin
    local found
    pcall(function()
        local tf9 = _ptf()
        local rp9 = tf9:call("get_Position")
        local up9 = tf9:call("get_UniversalPosition")
        if not (rp9 and up9) then return end
        local sx, sz = s.ux - (up9.x - rp9.x), s.uz - (up9.z - rp9.z)
        local sm = sdk.get_native_singleton("via.SceneManager")
        local smt = sdk.find_type_definition("via.SceneManager")
        local scene9 = sdk.call_native_func(sm, smt, "get_CurrentScene")
        local comps = scene9:call("findComponents(System.Type)", sdk.typeof("app.gm81_128"))
        local n = 0
        pcall(function() n = comps:call("get_Length") or 0 end)
        if n == 0 then pcall(function() n = comps:get_size() or 0 end) end
        for i = 0, (tonumber(n) or 0) - 1 do
            pcall(function()
                local c
                pcall(function() c = comps:call("get_Item", i) end)
                if not c then pcall(function() c = comps:get_element(i) end) end
                local go = c and c:call("get_GameObject")
                local p = go and go:call("get_Transform"):call("get_Position")
                if not p then return end
                local dx, dz = p.x - sx, p.z - sz
                if dx * dx + dz * dz < 9.0 then
                    found = go:add_ref()
                    -- a sky-sign survivor gets re-planted on adoption (the float fix
                    -- applies to old signs too, not just fresh spawns)
                    pcall(function()
                        local cast = rawget(_G, "route3_cast_ground_below")
                        if type(cast) ~= "function" then return end
                        local hit = cast(sx, (tonumber(s.uy) or 0) + 5.0, sz)
                        local hy = hit and tonumber(hit.y)
                        if hy then
                            local ry = hy - (up9.y - rp9.y)
                            if math.abs(ry - p.y) > 0.4 then
                                go:call("get_Transform"):call("set_Position", Vector3f.new(p.x, ry, p.z))
                                _log("adopted sign re-planted to ground")
                            end
                        end
                    end)
                end
            end)
        end
    end)
    return found
end
-- ⭐ 08-13 THE SIGN REAPER (Aurora: "cancelling it via the UI keeps the signs in
-- place"): cancel_site is declared before `signs` exists, and a sign planted in an
-- EARLIER load is an orphan no sweep can see (record gone = never adopted, never
-- reaped). Every cancel path calls this: the tracked wrapper first, then a
-- proximity hunt for any survivor signboard within 3m of the dead site. A sign
-- belonging to a still-LIVE site record is never touched.
_G.IrisOutbuildings.reap_sign = function(key, ux, uz)
    pcall(function() _sign_remove(key) end)
    if not (ux and uz) then return end
    pcall(function()
        local tf9 = _ptf()
        local rp9 = tf9:call("get_Position")
        local up9 = tf9:call("get_UniversalPosition")
        if not (rp9 and up9) then return end
        for _, s2 in ipairs(sites) do
            if s2.state == "site" then
                local pdx, pdz = (s2.ux or 1e9) - ux, (s2.uz or 1e9) - uz
                if pdx * pdx + pdz * pdz < 9.0 then return end
            end
        end
        local sx, sz = ux - (up9.x - rp9.x), uz - (up9.z - rp9.z)
        local sm = sdk.get_native_singleton("via.SceneManager")
        local smt = sdk.find_type_definition("via.SceneManager")
        local scene9 = sdk.call_native_func(sm, smt, "get_CurrentScene")
        local comps = scene9:call("findComponents(System.Type)", sdk.typeof("app.gm81_128"))
        local n = 0
        pcall(function() n = comps:call("get_Length") or 0 end)
        if n == 0 then pcall(function() n = comps:get_size() or 0 end) end
        for i = 0, (tonumber(n) or 0) - 1 do
            pcall(function()
                local c
                pcall(function() c = comps:call("get_Item", i) end)
                if not c then pcall(function() c = comps:get_element(i) end) end
                local go = c and c:call("get_GameObject")
                local p = go and go:call("get_Transform"):call("get_Position")
                if not p then return end
                local dx, dz = p.x - sx, p.z - sz
                if dx * dx + dz * dz < 9.0 then
                    go:call("destroy", go)
                    _log("sign REAPED at cancelled site " .. tostring(key))
                end
            end)
        end
    end)
end
local function _sign_spawn(s)
    for _, j in ipairs(sign_jobs) do if j.key == s.key then return end end
    local gid
    pcall(function()
        gid = sdk.find_type_definition("app.GimmickID"):get_field("Gm81_129"):get_data()
    end)
    if not gid then return end
    -- ⭐ plant the post in the DIRT, not the record (Aurora's sky-sign): the site's
    -- stored height is the footprint CENTER on whatever knoll it crowned - ground-probe
    -- the sign's own spot (render x/z in, universal y out, the proven rig)
    local uy = tonumber(s.uy) or 0.0
    pcall(function()
        local cast = rawget(_G, "route3_cast_ground_below")
        if type(cast) ~= "function" then return end
        local tf = _ptf()
        local rp = tf:call("get_Position")
        local up = tf:call("get_UniversalPosition")
        local hit = cast(s.ux - (up.x - rp.x), uy + 5.0, s.uz - (up.z - rp.z))
        local hy = hit and tonumber(hit.y)
        if hy and math.abs(hy - uy) < 12.0 then uy = hy end
    end)
    sign_jobs[#sign_jobs + 1] = { key = s.key, ux = s.ux, uy = uy, uz = s.uz,
        yaw = (tonumber(s.yaw) or 0) + 180.0, gid = gid, stage = "prefab", f = 0 }
    _log(string.format("sign requested for %s (ground y %.1f, record y %.1f)",
        tostring(s.key), uy, tonumber(s.uy) or 0))
end
local function _sign_pump()
    -- the furnish/deed generator recipe, single lane: prefab -> ready -> instantiate -> poll
    for i = #sign_jobs, 1, -1 do
        local q = sign_jobs[i]
        local drop = false
        if q.stage == "prefab" then
            local ok = pcall(function()
                local prefab = sdk.create_instance("via.Prefab"):add_ref()
                prefab:set_Path("AppSystem/gimmick/prefab/gm81_129.pfb")
                pcall(function() prefab:set_Standby(true) end)
                local ctrl = sdk.create_instance("app.PrefabController"):add_ref()
                ctrl._Item = prefab
                local inst = sdk.create_instance("app.InstanceInfo"):add_ref()
                local container
                pcall(function() container = inst:get_Container() end)
                if not container then container = sdk.create_instance("app.GenerateInfo.GenerateInfoContainer"):add_ref() end
                local pos = ValueType.new(sdk.find_type_definition("via.Position"))
                pos.x, pos.y, pos.z = q.ux, q.uy, q.uz
                pcall(function()
                    local f2 = sdk.find_type_definition("app.GeneratorCategory"):get_field("Gimmick")
                    container._CommonInfo._Category = (f2 and f2:get_data()) or 5
                end)
                pcall(function() container._CommonInfo._ObjectID._SelectedGimmickID = q.gid end)
                pcall(function() container._CommonInfo._InitialPosition = pos end)
                pcall(function() container._CommonInfo._ContextPosition = pos end)
                pcall(function() container._CommonInfo:setContextPosition(pos) end)
                pcall(function()
                    local th = math.rad(q.yaw or 0)
                    local rqt = ValueType.new(sdk.find_type_definition("via.Quaternion"))
                    rqt.x, rqt.y, rqt.z, rqt.w = 0.0, math.sin(th / 2.0), 0.0, math.cos(th / 2.0)
                    container._CommonInfo:setInitialAngle(rqt)
                end)
                q.prefab, q.ctrl, q.inst, q.container = prefab, ctrl, inst, container
            end)
            if ok and q.prefab then q.stage = "wait" else drop = true end
        elseif q.stage == "wait" then
            q.f = q.f + 1
            local ready = false
            pcall(function() ready = q.prefab:get_Ready() == true end)
            if ready then
                local okr = pcall(function()
                    sdk.get_managed_singleton("app.GenerateManager"):call(
                        "requestCreateInstance(app.PrefabController, app.GenerateInfo.GenerateInfoContainer, System.Int32, app.InstanceInfo, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>)",
                        q.ctrl, q.container, 743100 + i, q.inst, nil, nil)
                end)
                if okr then q.stage = "poll"; q.f = 0 else drop = true end
            elseif q.f > 900 then drop = true end
        elseif q.stage == "poll" then
            q.f = q.f + 1
            local go
            pcall(function() go = q.inst:get_Instance() end)
            if not go then pcall(function() go = q.inst["<Instance>k__BackingField"] end) end
            if go then
                pcall(function() go = go:add_ref() end)
                signs[q.key] = go
                pcall(function() _sign_registry()[q.key] = go:get_address() end)
                _sign_repoint(go)
                _log("sign UP for " .. tostring(q.key))
                drop = true
            elseif q.f > 900 then drop = true end
        end
        if drop then table.remove(sign_jobs, i) end
    end
end
-- the Examine hook: installs ONCE (hooks persist across resets - the _G flag law); the
-- hook only stamps a flag, the tick opens the dialog after the runes have their moment
if not _G.IrisOBSignHookInstalled then
    _G.IrisOBSignHookInstalled = true
    pcall(function()
        local m = sdk.find_type_definition("app.gm81_128"):get_method("onStartInteract(System.UInt32, app.Character)")
        if not m then return end
        sdk.hook(m, function(args)
            pcall(function()
                local comp = sdk.to_managed_object(args[2])
                local go = comp and comp:call("get_GameObject")
                local a = go and go:get_address()
                if not a then return end
                for k, addr in pairs(rawget(_G, "IrisOBSigns") or {}) do
                    if addr == a then
                        _G.IrisOBSignExamined = { key = k, at = os.clock() }
                        pcall(function() log.info("[IrisOutbuildings] sign EXAMINED: " .. tostring(k)) end)
                    end
                end
            end)
        end, function(r) return r end)
    end)
end

-- ── pause guard (grace pattern) ─────────────────────────────────────────────────────────
local pause_grace = 0.0
local function _world_paused()
    local p = false
    pcall(function()
        local pm = sdk.get_managed_singleton("app.PauseManager")
        if pm and pm:call("isPausedAny") == true then p = true end
    end)
    return p
end

-- ── the pump ────────────────────────────────────────────────────────────────────────────
re.on_application_entry("UpdateBehavior", function()
    -- dialog reader FIRST and unguarded (a pause-guarded reader = softlock, the sign's law)
    if dlg.open then
        local p = _dialog_pick()
        if p ~= nil and p ~= dlg.baseline then dlg.baseline = p else p = nil end
        if p ~= nil and os.clock() - dlg.opened_at < 0.25 then p = nil end
        if p == nil and os.clock() - dlg.opened_at > 30.0 then _close_dialog(); return end
        -- the sign's UNDO (Aurora): "Cancel the commission" = Sel2 (p==3) on the raise
        -- dialog, or Sel0 (p==1) on the short-of-materials dialog (mode "poor")
        if (p == 3 and dlg.mode ~= "poor") or (p == 1 and dlg.mode == "poor") then
            local site = dlg.site
            _close_dialog()
            if site then
                local ok9, rt9, rs9 = nil, 0, 0
                pcall(function() ok9, rt9, rs9 = _G.IrisOutbuildings.cancel_site(site.key) end)
                if ok9 then
                    M.last = "commission cancelled"
                        .. (((rt9 or 0) + (rs9 or 0)) > 0
                            and (" (" .. tostring(rt9) .. " Timber, " .. tostring(rs9) .. " Stone returned)") or "")
                    card = { title = "Commission Cancelled", body = tostring(site.label) .. " will not be built here.",
                        col = 0xFFC8B8A0, until_t = os.clock() + 4.0 }
                    _log("sign cancel: " .. tostring(site.key))
                else
                    M.last = "could not cancel (mid-raise sites finish first)"
                end
            end
            return
        end
        if p == 1 and dlg.mode ~= "poor" then          -- Sel0 = raise it
            local site = dlg.site
            _close_dialog()
            if site and site.state == "site" then
                -- ⛔ blocker 4: pfbs verified on disk BEFORE a single item is consumed
                local ready, missing = false, -1
                pcall(function() ready, missing = _G.IrisForge.kit_ready(site.kit) end)
                if not ready then
                    M.last = "the plans aren't forged yet (" .. tostring(missing) .. " missing) - FORGE ALL after a fresh game start"
                    card = { title = "The Builder Shakes Their Head", body = M.last, col = 0xFFC8B8A0, until_t = os.clock() + 5.0 }
                    _log("raise refused: kit not forged (" .. tostring(missing) .. " missing)")
                    return
                end
                local ok_t = _consume_item(TIMBER_ITEM, site.timber or 0)
                local ok_s = ok_t and _consume_item(STONE_ITEM, site.stone or 0)
                if not (ok_t and ok_s) then
                    M.last = "the materials slipped away mid-count - nothing consumed twice, try again"
                    _log("raise aborted: consume failed (timber ok=" .. tostring(ok_t) .. ")")
                    return
                end
                site.state = "raising"
                _save()
                if _world_paused() then
                    -- ⛔ 08-13: the dialog now overlays the RUNES (still paused) - the
                    -- hammer scene must never start on a paused frame (the pause-spawn
                    -- crash class). Defer to the first live frame below.
                    M.raise_pending = site
                    _log("RAISING deferred until the runes close: " .. tostring(site.key))
                else
                    _fsm_enabled(false)
                    _play_clip(61, 4100)   -- hammer windup (the purchase flow's scene)
                    scene = { stage = "start", t = os.clock(), site = site }
                    _log("RAISING " .. tostring(site.key))
                end
            end
        elseif p == 2 or p == 5 then   -- not yet / cancel: re-offer after a cooldown
            local site = dlg.site
            _close_dialog()
            if site then site.offer_cool = os.clock() + 30.0 end
        end
        return
    end

    if _world_paused() then
        -- the runes reader PAUSES the world (Aurora read the sign at leisure and the
        -- follow-up dialog never came - the stamp had expired): keep the examine stamp
        -- fresh through any pause, and shorten the grace so the dialog lands promptly
        if _G.IrisOBSignExamined then _G.IrisOBSignExamined.at = os.clock() end
        pause_grace = os.clock() + (_G.IrisOBSignExamined and 0.6 or 3.0)
        -- ⭐ 08-13: open the choice OVER the runes (the DeedSign look) - the reader
        -- above this pause-return answers it. Pre-paid sites wait for the close.
        local ex0 = _G.IrisOBSignExamined
        if ex0 and not dlg.open and not scene then
            if _examine_dialog(ex0.key) == "dlg" then _G.IrisOBSignExamined = nil end
        end
        return
    end
    if os.clock() < pause_grace then return end
    -- deferred raise: answered "Raise it" over the runes; this is the first live frame
    if M.raise_pending then
        local sp = M.raise_pending
        M.raise_pending = nil
        _fsm_enabled(false)
        _play_clip(61, 4100)
        scene = { stage = "start", t = os.clock(), site = sp }
        _log("RAISING (deferred past the runes) " .. tostring(sp.key))
    end

    -- hammer scene FSM (runs above the throttle: animation timing is per-frame business)
    if scene then
        local site = scene.site
        if scene.stage == "start" and os.clock() - scene.t > 4.5 then
            local ok, why
            pcall(function() ok, why = _G.IrisForge.build_kit(site.kit, site.ux, site.uy, site.uz, site.yaw, site.key) end)
            if ok then
                scene.stage = "loop"
                scene.t = os.clock()
                scene.reclip = os.clock() + 2.5
            else
                -- the forge refused (mid-build race): hold the hammer a moment and retry
                scene.retry = (scene.retry or 0) + 1
                scene.t = os.clock() - 3.0
                if scene.retry > 8 then
                    _fsm_enabled(true)
                    site.state = "site"   -- materials are gone; the reviewer would call this
                    site.paid = true      -- a refund question - mark paid so no double-charge
                    _save()
                    M.last = "the forge would not answer: " .. tostring(why) .. " (site keeps your materials - approach again)"
                    _log("raise FAILED after retries: " .. tostring(why))
                    scene = nil
                end
            end
        elseif scene.stage == "loop" then
            if os.clock() >= (scene.reclip or 0) then
                scene.reclip = os.clock() + 2.5
                _play_clip(61, 4101)   -- hammering loop
            end
            local building = true
            pcall(function() building = _G.IrisForge.status().building == true end)
            local up = 0
            pcall(function() up = _G.IrisForge.tag_count(site.key) or 0 end)
            local kit9 = _kit_row(site.kit)
            scene.expected = tonumber(kit9 and kit9.pieces) or scene.expected or 1
            scene.up = up
            if not building and up > 0 then
                -- Visual construction is only 85% of the job.  Keep the player in the
                -- hammer scene until the collision pool has accepted and completed its rebuild.
                scene.stage = "collision"
                scene.t = os.clock()
                _queue_collision_refresh(site)
                _log("visual build complete for " .. tostring(site.key) .. "; applying collision")
            elseif os.clock() - scene.t > 90.0 then
                _fsm_enabled(true)
                site.state = "site"; site.paid = true
                _save()
                M.last = "the visual build did not complete; the commission remains paid"
                _log("raise FAILED: visual forge timed out for " .. tostring(site.key))
                scene = nil
            end
        elseif scene.stage == "collision" then
            _collision_refresh_tick(site)
            if site.coll_error then
                _fsm_enabled(true)
                site.state = "site"; site.paid = true
                _save()
                M.last = "the structure stands, but collision failed: " .. tostring(site.coll_error)
                card = { title = "Building Paused", body = M.last, col = 0xFFC8B8A0, until_t = os.clock() + 6.0 }
                _log("raise NOT completed: " .. tostring(site.coll_error))
                scene = nil
            elseif site.coll_started then
                local busy9, count9 = false, 0
                pcall(function()
                    local C9 = _G.IrisCollision
                    busy9 = C9 and C9.busy and C9.busy() == true or false
                    count9 = C9 and C9.count and (tonumber(C9.count()) or 0) or 0
                end)
                if not busy9 and count9 > 0 then
                    scene.stage = "finish"
                    scene.t = os.clock()
                    _play_clip(61, 4102)   -- finishing blow only after collision exists
                end
            elseif os.clock() - scene.t > 45.0 then
                site.coll_pending = nil
                site.coll_error = "collision build timed out"
            end
        elseif scene.stage == "finish" then
            if os.clock() - scene.t > 398 / 60 then
                _fsm_enabled(true)
                site.state = "built"
                site.paid = nil
                site.coll_started, site.coll_pending, site.coll_error = nil, nil, nil
                _save()
                local up = tonumber(scene.up) or 0
                M.last = tostring(site.label) .. " raised (" .. up .. " pieces, collision applied)"
                card = { title = "Raised", body = tostring(site.label) .. " stands.", col = 0xFF9AE89A, until_t = os.clock() + 5.0 }
                _log("RAISED " .. tostring(site.key) .. " pieces=" .. up)
                scene = nil
            end
        end
        if scene then
            local elapsed = os.clock() - scene.t
            local frac, label = 0.0, "Raising " .. tostring(site.label or "the structure")
            if scene.stage == "start" then
                frac = 0.15 * math.min(1.0, elapsed / 4.5)
            elseif scene.stage == "loop" then
                frac = 0.15 + 0.70 * math.min(1.0,
                    (tonumber(scene.up) or 0) / math.max(1, tonumber(scene.expected) or 1))
            elseif scene.stage == "collision" then
                frac = 0.85 + (site.coll_started and 0.11 or 0.04)
                label = "Applying collision to " .. tostring(site.label or "the structure")
            elseif scene.stage == "finish" then
                frac = 0.96 + 0.04 * math.min(1.0, elapsed / (398 / 60))
            end
            _G.IrisProgressHUD = { active = true, t = os.clock(), frac = frac, label = label }
        end
        return
    end

    -- Proximity never opens a commission dialog.  The only production entry is the
    -- native Examine callback on this site's physical sign (handled below).
    M.act_prev = false

    _sign_pump()
    -- Examine on OUR sign (the native B prompt): the raise conversation opens after the
    -- runes have their moment - never skipping the interact (the prompt-starvation law)
    local ex9 = _G.IrisOBSignExamined
    if ex9 and not dlg.open and not scene then
        local age9 = os.clock() - (tonumber(ex9.at) or 0)
        if age9 > 8.0 then
            _G.IrisOBSignExamined = nil
            -- 08-13 RECEIPTS (Aurora: "the sign isn't letting me cancel"): every
            -- refusal path in this consume block was silent - never again
            _log("sign examine EXPIRED unconsumed (ui_busy/gates never cleared in 8s)")
        elseif age9 > 0.5 and not _other_ui_busy() and _gates_idle() then
            _G.IrisOBSignExamined = nil
            _load()
            local matched9 = false
            for _, s in ipairs(sites) do
                if s.key == ex9.key and s.state == "site" then
                    matched9 = true
                    local ht = _count_item(TIMBER_ITEM)
                    local hs = _count_item(STONE_ITEM)
                    local nt, ns = tonumber(s.timber) or 0, tonumber(s.stone) or 0
                    if s.paid then
                        s.state = "raising"
                        s.paid = nil
                        _save()
                        _fsm_enabled(false)
                        _play_clip(61, 4100)
                        scene = { stage = "start", t = os.clock(), site = s }
                        _log("RAISING (pre-paid, sign examine) " .. tostring(s.key))
                    elseif ht >= nt and hs >= ns then
                        _show_dialog("Raise the " .. tostring(s.label) .. "?\n"
                            .. string.format("%d Timber, %d Stone", nt, ns),
                            "Raise it", "Not yet", s, "Cancel the commission")
                    else
                        _show_dialog("The " .. tostring(s.label) .. " wants "
                            .. string.format("%d Timber, %d Stone.", nt, ns),
                            "Cancel the commission", "Leave it", s, "", "poor")
                    end
                end
            end
            if not matched9 then
                local st9 = {}
                for _, s in ipairs(sites) do
                    st9[#st9 + 1] = tostring(s.key) .. "=" .. tostring(s.state)
                end
                _log("sign examine: NO site-state record for key '" .. tostring(ex9.key)
                    .. "' (sites: " .. table.concat(st9, ", ") .. ")")
                M.last = "this sign's site record is not in the 'site' state - see the log"
            end
        elseif age9 > 0.5 and os.clock() > (M.exlog_at or 0) then
            M.exlog_at = os.clock() + 2.0
            _log(string.format("sign examine WAITING: ui_busy=%s gates_idle=%s age=%.1fs",
                tostring(_other_ui_busy()), tostring(_gates_idle()), age9))
        end
    end

    -- feed the gather card every frame while it lives (IrisFont draws ~1s per feed)
    if card and os.clock() < (card.until_t or 0) then
        pcall(function()
            local F = _G.IrisFont
            if F and F.card then F.card(card.title, card.body, card.col) end
        end)
    end

    -- throttled pass
    if os.clock() < pass_at then return end
    pass_at = os.clock() + 1.0
    _load()
    if #sites == 0 then return end
    local pu = _pupos()
    if not pu then return end
    -- self-contained settle law (blocker 5's spirit): a >50m jump = warp/load - hold 10s
    if last_pu then
        local jx, jz = pu.x - last_pu.x, pu.z - last_pu.z
        if jx * jx + jz * jz > 50.0 ^ 2 then settle_until = os.clock() + 10.0 end
    end
    last_pu = { x = pu.x, z = pu.z }
    local settled = os.clock() >= settle_until

    _collision_refresh_tick()

    -- orphaned siting previews: a script reset mid-footprint strands ghost pieces (never
    -- destroyed on reset, the CTD law); the forge's adopt re-owns them tagged "obpreview"
    -- and this sweep clears them once no footprint mode is live
    if _G.IrisFurnishFootprint ~= true then
        pcall(function()
            if (_G.IrisForge.tag_count("obpreview") or 0) > 0 then
                local n = _G.IrisForge.despawn_tag("obpreview")
                _log("swept " .. tostring(n) .. " orphaned siting-preview pieces")
            end
        end)
    end

    M.armed = nil   -- re-armed each pass by the site loop (walking away disarms)
    -- sign lifecycle: a signpost stands ONLY over a live un-raised site; anything else
    -- (cancelled, raised, retired) loses its sign here - one rule, no special cases
    for k in pairs(signs) do
        local keep = false
        for _, s in ipairs(sites) do
            if s.key == k and s.state == "site" then keep = true end
        end
        if not keep then _sign_remove(k) end
    end
    for _, s in ipairs(sites) do
        if s.state == "site" and not signs[s.key] then
            -- (round 6: this compared against rp/d - TreeClear's names, nil HERE - and
            -- the nil-index killed the whole pass silently; pu is this pass's player)
            local dxs, dzs = s.ux - pu.x, s.uz - pu.z
            if dxs * dxs + dzs * dzs < 70.0 ^ 2 then
                local old9 = _sign_adopt(s)
                if old9 then
                    signs[s.key] = old9
                    pcall(function() _sign_registry()[s.key] = old9:get_address() end)
                    _sign_repoint(old9)
                    _log("sign ADOPTED for " .. tostring(s.key))
                else
                    _sign_spawn(s)
                end
            end
        end
    end
    for _, s in ipairs(sites) do
        local dx, dz = s.ux - pu.x, s.uz - pu.z
        local d2 = dx * dx + dz * dz
        if s.state == "site" and d2 < 28.0 ^ 2 then
            local ht = _count_item(TIMBER_ITEM)
            local hs = _count_item(STONE_ITEM)
            local nt, ns = tonumber(s.timber) or 0, tonumber(s.stone) or 0
            local enough = s.paid == true or (ht >= nt and hs >= ns)
            local body = s.paid and "The materials are already given. Stand close to begin."
                or string.format("Timber %d / %d      Stone %d / %d", math.min(ht, nt), nt, math.min(hs, ns), ns)
            card = { title = "Building Site: " .. tostring(s.label), body = body,
                col = enough and 0xFF9AE89A or 0xFFEAD8B0, until_t = os.clock() + 1.5 }
            -- ⭐ 08-13 (Aurora: "there's nothing to interact with - put up a sign"): the
            -- site no longer ambushes with an auto-dialog. It ARMS when you stand close
            -- with everything in hand; the physical sign's native Examine owns B.
            -- arm on PROXIMITY alone (Aurora: the sign must also offer the UNDO) - the
            -- press decides what conversation opens; materials only shape the options
            if d2 < 8.0 ^ 2 and settled then
                M.armed = s
                M.armed_enough = enough
            end
        elseif s.state == "built" and d2 < 110.0 ^ 2 and settled then
            -- rebuild-on-approach: the tagged building should stand; if the forge owns no
            -- pieces for it, adopt first (post-reset survivors), then rebuild - fully gated
            local up = 0
            pcall(function() up = _G.IrisForge.tag_count(s.key) or 0 end)
            if up == 0 and _gates_idle() and os.clock() > (tonumber(s.rebuild_cool) or 0) then
                s.rebuild_cool = os.clock() + 30.0
                local adopted = 0
                pcall(function() adopted = _G.IrisForge.adopt() or 0 end)
                pcall(function() up = _G.IrisForge.tag_count(s.key) or 0 end)
                if up == 0 then
                    local ok, why
                    pcall(function() ok, why = _G.IrisForge.build_kit(s.kit, s.ux, s.uy, s.uz, s.yaw, s.key) end)
                    _log(string.format("rebuild '%s': adopted=%d ok=%s why=%s", s.key, adopted, tostring(ok), tostring(why)))
                    if ok then _queue_collision_refresh(s) end
                else
                    _log(string.format("rebuild '%s': adopt re-owned %d pieces - standing", s.key, up))
                end
                return   -- one heavy action per pass
            end
        end
    end
end)

-- ── THE SIGN (Aurora: "put up a sign in the place the ghost was set"): a floating
-- marker over every un-raised site - name, cost, and the [N / B] line when armed.
re.on_frame(function()
    pcall(function()
        -- ⭐ RETIRED 08-13 (Aurora: "we have the native B prompt on signs, we don't need
        -- the fake one"): the PHYSICAL signpost replaced the floating text entirely.
        if true then return end
        if not sites or #sites == 0 then return end
        local F = _G.IrisFont
        local tf = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
            :call("get_GameObject"):call("get_Transform")
        local rp = tf:call("get_Position")
        local up = tf:call("get_UniversalPosition")
        -- ⛔ ONE-FRAME LAW for the delta (receipts: the sign painted at screen -33417 -
        -- a tile-shear frame put it 128m away, off the monitor): a changed delta is only
        -- believed once it persists 3 consecutive frames; sheared reads draw with the
        -- last stable frame instead.
        local dx0, dy0, dz0 = up.x - rp.x, up.y - rp.y, up.z - rp.z
        local st9 = M.dstab
        if not st9 then
            st9 = { x = dx0, y = dy0, z = dz0, n = 0 }
            M.dstab = st9
        end
        if math.abs(dx0 - st9.x) > 1.0 or math.abs(dz0 - st9.z) > 1.0 then
            if st9.cand and math.abs(dx0 - st9.cand.x) < 1.0 and math.abs(dz0 - st9.cand.z) < 1.0 then
                st9.n = st9.n + 1
                if st9.n >= 3 then
                    st9.x, st9.y, st9.z = dx0, dy0, dz0
                    st9.cand, st9.n = nil, 0
                end
            else
                st9.cand = { x = dx0, y = dy0, z = dz0 }
                st9.n = 1
            end
            dx0, dy0, dz0 = st9.x, st9.y, st9.z
        else
            st9.x, st9.y, st9.z = dx0, dy0, dz0
            st9.cand, st9.n = nil, 0
        end
        for _, s in ipairs(sites) do
            if s.state ~= "built" then
                local sx, sy, sz = s.ux - dx0, s.uy - dy0, s.uz - dz0
                local ddx, ddz = sx - rp.x, sz - rp.z
                if ddx * ddx + ddz * ddz < 40.0 ^ 2 then
                    local sp = draw.world_to_screen(Vector3f.new(sx, sy + 2.2, sz))
                    if sp then
                        -- one receipt per load: "invisible sign" must never be silent
                        if not M.sign_logged then
                            M.sign_logged = true
                            _log(string.format("sign drawing for '%s' at screen (%.0f, %.0f) IrisFont=%s",
                                tostring(s.label), sp.x, sp.y, tostring(F ~= nil)))
                        end
                        local l1 = "Building Site: " .. tostring(s.label)
                        local l2
                        if s.state == "raising" then
                            l2 = "the hammer swings..."
                        elseif M.armed == s then
                            l2 = M.armed_enough and "[B] Examine the sign to begin" or "[B] Examine the sign for options"
                        else
                            l2 = string.format("%d Timber, %d Stone to raise", tonumber(s.timber) or 0, tonumber(s.stone) or 0)
                        end
                        -- IrisFont first; if its face declines (returns falsy), the raw
                        -- draw.text fallback keeps the sign visible (the nameplate law;
                        -- draw.text eats ABGR, hence the swapped constants)
                        if not (F and F.text and F.text(l1, sp.x - #l1 * 4.0, sp.y, 0xFFEAD8B0, 18)) then
                            pcall(function() draw.text(l1, sp.x - #l1 * 4.0, sp.y, 0xFFB0D8EA) end)
                        end
                        local c2 = (M.armed == s) and 0xFF9AE89A or 0xFFC8C8D0
                        local c2f = (M.armed == s) and 0xFF9AE89A or 0xFFD0C8C8
                        if not (F and F.text and F.text(l2, sp.x - #l2 * 3.2, sp.y + 22, c2, 15)) then
                            pcall(function() draw.text(l2, sp.x - #l2 * 3.2, sp.y + 22, c2f) end)
                        end
                    end
                end
            end
        end
    end)
end)

re.on_script_reset(function()
    -- refs only; never destroy on reset (the CTD law). A hammer scene mid-swing must not
    -- strand a frozen player, and our dialog must not be orphaned. Standing signs get
    -- ADOPTED next pass (the _G address registry keeps the examine hook matching).
    if scene then _fsm_enabled(true) end
    scene = nil
    if dlg.open then _close_dialog() end
    signs = {}
    sign_jobs = {}
end)

-- ── panel ───────────────────────────────────────────────────────────────────────────────
re.on_draw_ui(function()
    if not imgui.tree_node("IRIS Outbuildings (sites, gather, raise)") then return end
    _load()
    imgui.text(M.last)
    imgui.text("sites: " .. tostring(#sites))
    for i = #sites, 1, -1 do
        local s = sites[i]
        imgui.text(string.format("  %s [%s] @ %s", tostring(s.label), tostring(s.state), tostring(s.plot)))
        imgui.same_line()
        if imgui.button("REMOVE##iob" .. i) then
            pcall(function() _G.IrisForge.despawn_tag(s.key) end)
            table.remove(sites, i)
            _save()
        end
    end
    if imgui.button("REAP STRAY SIGN NEAR ME (stand at it - away from the deed sign)##iob_reap") then
        pcall(function()
            local tf9 = _ptf()
            local up9 = tf9:call("get_UniversalPosition")
            if up9 then _G.IrisOutbuildings.reap_sign("stray", up9.x, up9.z) end
        end)
    end
    if imgui.button("DEV: give 60 Timber + 20 Stone (test loop)##iob_give") then
        pcall(function()
            local im = sdk.get_managed_singleton("app.ItemManager")
            local ch = _pch():call("get_Character") or _pch()
            im:call("getItem(System.Int32, System.Int32, app.Character)", TIMBER_ITEM, 60, ch)
            im:call("getItem(System.Int32, System.Int32, app.Character)", STONE_ITEM, 20, ch)
        end)
    end
    imgui.tree_pop()
end)
