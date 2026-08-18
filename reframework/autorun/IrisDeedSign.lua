-- IrisDeedSign.lua - the plot-purchase sign (v1)
-- The homestead buy-flow: SIGN on for-sale plot -> hold-to-PURCHASE -> homestead builds.
-- Sign = gm81_129 "Signpost" (Aurora's pick 2026-07-23). Its native F-Examine just reads
-- location runes (v0 recon: NO talk node fires - the choice-dialogue route needs its own
-- research; see [[riftspeak-pawn-menu-integration]] dead-ends before trying). So the
-- purchase is OUR proven stack: proximity + IrisFont card + hold-key (the Yoke Rite pattern).
-- Spawning uses the quarry's GenerateManager state machine (proven in IrisWoodcutting).
-- Bridge: _G.IrisDeedSign.ensure_sign(rec) is called by IrisHomestead's auto loop for plots
-- with rec.owned == false; purchase flips rec.owned = true and saves via _G.IrisHomesteadPlots.

local M = { last = "(idle) for-sale plots grow signs; walk up for the offer", price = 20000,
            sign_yaw_off = 180.0,  -- readable/examine side = the mesh's BACK (Aurora 07-23)
            sign_y_off = 0.0 }     -- m: plot anchor Y is the HOUSE floor (lifted) - sign floats without this

local sign = { go = nil, rec = nil, jobs = {}, seq = 0, rot_passes = 0, rot_quat = nil }

local function _log(s)
    pcall(function()
        local f = io.open("IRIS/deed_sign_log.txt", "a")
        if f then f:write("[" .. os.date("%H:%M:%S") .. "] " .. tostring(s) .. "\n"); f:close() end
    end)
end

-- ── the NATIVE dialog selector (Aurora's discovery: app.GuiManager.Dialog = app.ui010101) ──
-- reqDisp shows a real game dialog (pause + cursor + native font); getDialogState returns
-- RetVal: 0=None 1=Cancel 2=Sel0 3=Sel1 4=Sel2 5=Sel3. GUI calls MUST run on the game thread
-- (UpdateBehavior), never the render thread.
local DIALOG_GUITYPE = 14   -- app.GuiDefine.GuiType.Dialog
-- baseline: getDialogState LATCHES its last answer across sessions - a fresh open can read a
-- STALE Cancel from the previous dialog. Only a CHANGE from the open-time baseline is a click.
local dlg = { open = false, armed = true, baseline = nil, opened_at = 0 }

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

local function _show_dialog(prompt, opt1, opt2)
    local ok = pcall(function()
        local gm = sdk.get_managed_singleton("app.GuiManager")
        local dialog = gm and gm:get_field("Dialog")
        if not dialog then return end
        gm:call("requestGuiType", DIALOG_GUITYPE)
        dialog:call("reqDisp",
            prompt,
            opt1, opt2, "", "",
            true,      -- is_cancel_enable
            0,         -- sel_pos
            true,      -- is_wait_input
            58,        -- prio
            0,         -- dispItemID
            -1,        -- itemNum (none)
            nil,       -- tex
            false, false, false, false, false, false,
            (M.pause_world ~= false),      -- is_pause
            0.0)
        dlg.open = true
        dlg.opened_at = os.clock()
        dlg.baseline = _dialog_pick()   -- the stale latch: ignore until it CHANGES
        _log("dialog OPEN baseline=" .. tostring(dlg.baseline) .. " pause=" .. tostring(M.pause_world ~= false))
    end)
    if not ok then M.last = "dialog reqDisp failed (see log)"; _log("reqDisp FAILED") end
end

local function _close_dialog()
    pcall(function()
        local gm = sdk.get_managed_singleton("app.GuiManager")
        local dialog = gm and gm:get_field("Dialog")
        if dialog then dialog:call("reqClose") end
        gm:call("requestHideGuiType", DIALOG_GUITYPE)
    end)
    dlg.open = false
    dlg.closed_at = os.clock()   -- our own close fires type=0 too - don't offer on it (loop)
end

-- ── materials (IRIS bundle items: Stone 34710, Timber 34711 - same ids the tools grant) ──
local STONE_ITEM, TIMBER_ITEM = 34710, 34711

-- ⭐ 08-18 per-plot deed terms: the plot record overrides the panel globals (an Eini's plot
-- costs more gold + more stone/timber than a farmhouse plot). Fields are written into the
-- record by homestead SAVE (its KIT_DEEDS defaults); old records fall through to M.*.
local function _deed_terms(rec)
    local price = (rec and tonumber(rec.price)) or M.price or 20000
    local ns = (rec and tonumber(rec.req_stone)) or M.req_stone or 60
    local nt = (rec and tonumber(rec.req_timber)) or M.req_timber or 25
    return price, ns, nt
end
-- count/consume = RiftSpeak inventory.lua's PROVEN calls (the wedding-ring lessons):
-- getHaveNum(Int32, app.Character) / deleteItem(Int32, Int32, app.Character)
local function _player_chara()
    local ch
    pcall(function() ch = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer") end)
    return ch
end
local function _count_item(id)
    local n
    pcall(function()
        local im = sdk.get_managed_singleton("app.ItemManager")
        local ch = _player_chara()
        if im and ch then n = tonumber(im:call("getHaveNum(System.Int32, app.Character)", id, ch)) end
    end)
    return n
end
local function _consume_item(id, n)
    local before = _count_item(id)
    local after
    pcall(function()
        local im = sdk.get_managed_singleton("app.ItemManager")
        local ch = _player_chara()
        if not (im and ch) then return end
        im:call("deleteItem(System.Int32, System.Int32, app.Character)", id, n, ch)
        after = _count_item(id)
    end)
    local ok = before and after and after <= before - n
    -- explicit numbers so "did it consume?" is never a mystery (Aurora: "I still had 60 stone")
    _log(string.format("consume item %d x%d: before=%s after=%s -> %s",
        id, n, tostring(before), tostring(after), ok and "OK" or "FAILED (build proceeds; tell Iris)"))
    return ok
end

local function _player_upos()
    local up
    pcall(function()
        local tf = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
            :call("get_GameObject"):call("get_Transform")
        up = tf:call("get_UniversalPosition")
    end)
    return up
end

-- ── money: probe-first (API unknown 2026-07-23; purchase proceeds FREE until this lands) ──
local function _dump_money_api()
    local f = io.open("IRIS/money_api.txt", "w")
    if not f then return end
    f:write("MONEY API HUNT " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n\n")
    for _, tn in ipairs({ "app.ItemManager", "app.MoneyManager", "app.ShopManager" }) do
        local td = sdk.find_type_definition(tn)
        if td then
            f:write("### " .. tn .. "\n")
            pcall(function()
                for _, m in ipairs(td:get_methods()) do
                    local mn = m:get_name()
                    if mn:lower():find("money") or mn:lower():find("gold") then
                        local ps = {}
                        pcall(function() for _, p in ipairs(m:get_param_types()) do ps[#ps + 1] = p:get_full_name() end end)
                        local rt = "?"; pcall(function() rt = m:get_return_type():get_full_name() end)
                        f:write("  " .. mn .. "(" .. table.concat(ps, ", ") .. ") -> " .. rt .. "\n")
                    end
                end
            end)
            pcall(function()
                for _, fl in ipairs(td:get_fields()) do
                    local fn = fl:get_name()
                    if fn:lower():find("money") or fn:lower():find("gold") then
                        local ft = "?"; pcall(function() ft = fl:get_type():get_full_name() end)
                        f:write("  ." .. fn .. " : " .. ft .. "\n")
                    end
                end
            end)
            f:write("\n")
        end
    end
    f:close()
    M.last = "money API dump -> IRIS/money_api.txt"
end

local function _try_pay(amount)
    -- ⛔ the REAL wallet = app.ItemManager._Version (RiftSpeak inventory.lua, VERIFIED
    -- 2026-06-11: a 1,250g purchase moved it by exactly -1,250). "_Golden"/get__Golden is a
    -- Capcom DECOY that never changes - Aurora caught it before it shipped broken.
    local paid = false
    pcall(function()
        local im = sdk.get_managed_singleton("app.ItemManager")
        if not im then return end
        local cur = tonumber(im:get_field("_Version"))
        if cur == nil then return end
        if cur < amount then paid = "poor"; return end
        local ok = pcall(function() im:set_field("_Version", cur - amount) end)
        if ok and tonumber(im:get_field("_Version")) == cur - amount then paid = true end
    end)
    return paid
end

-- ── sign lifecycle ───────────────────────────────────────────────────────────────────────
local function _remove_sign()
    if dlg.open then _close_dialog() end
    if sign.go then pcall(function() sign.go:call("destroy", sign.go) end) end
    sign.go, sign.rec, sign.rot_passes, sign.rot_quat = nil, nil, 0, nil
    sign.near = false
    sign.no_adopt_until = os.clock() + 2.0   -- the destroyed sign lingers a frame or two
end

local function _player_rpos()
    local p
    pcall(function()
        p = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
            :call("get_GameObject"):call("get_Transform"):call("get_Position")
    end)
    return p
end

-- repoint the sign's runes message: _Param.TitleMessageId/MessageId (found 07-23; default =
-- "Castle" 4bed24b8-...). Target = the quest-title guid for "Home Is Where the Hearth Is" -
-- a REAL catalog string that reads like a homestead deed. Applied on spawn AND adopt.
local SIGN_MSG_GUID = "df1834c4-18f4-4c33-ab4e-913d592d0b1c"
local function _repoint_sign_text(go)
    pcall(function()
        local c = go:call("getComponent(System.Type)", sdk.typeof("app.gm81_128"))
        local prm = c and c:get_field("_Param")
        if not prm then _log("repoint: no _Param"); return end
        local g = sdk.find_type_definition("System.Guid"):get_method("Parse(System.String)")
            :call(nil, SIGN_MSG_GUID)
        if not g then _log("repoint: Guid.Parse failed"); return end
        prm:set_field("TitleMessageId", g)
        prm:set_field("MessageId", g)
        pcall(function() c:call("applyGimmickParam") end)
        _log("sign text REPOINTED -> 'Home Is Where the Hearth Is' (" .. SIGN_MSG_GUID .. ")")
    end)
end

-- ── sign position: the DOOR-FRONT (Aurora 07-23: house built on top of the player because
-- the sign sat at plot center). farm_complete's door is at plot-local (4.421, 0.075, -0.865);
-- outward from center = normalize(4.421,-0.865); sign = door + 2.8m outward. Rotated into
-- the world by the plot's yaw (the forge's _yaw_offset convention: x'=x*c+z*s, z'=-x*s+z*c).
local SIGN_LOCAL = { x = 7.17, z = -1.40 }
local function _sign_upos(rec)
    -- ⭐ 08-18 kit-aware placement: SIGN_LOCAL is the FARMHOUSE door-front (7.17,-1.40) -
    -- inside the walls of a bigger kit like Eini's. Non-farmhouse plots default the sign to
    -- the plot's ARRIVAL point (rec.tx/tz = where you stood at SAVE: proven ground, outside
    -- the footprint). rec.sign_dx/sign_dz (plot-local) override for hand-fitting.
    local lx, lz = SIGN_LOCAL.x, SIGN_LOCAL.z
    if rec.sign_dx or rec.sign_dz then
        lx, lz = tonumber(rec.sign_dx) or 0, tonumber(rec.sign_dz) or 0
    elseif rec.house and rec.house ~= "farm_complete" and rec.tx then
        return {
            x = rec.tx,
            y = (rec.ty or rec.uy or 0) + (rec.sign_y or M.sign_y_off or 0),
            z = rec.tz,
        }
    end
    local th = math.rad(rec.yaw or 0)
    local s, c = math.sin(th), math.cos(th)
    return {
        x = (rec.ux or 0) + lx * c + lz * s,
        y = (rec.uy or 0) + (rec.sign_y or M.sign_y_off or 0),
        z = (rec.uz or 0) - lx * s + lz * c,
    }
end

-- ── the BUILD SCENE: player mimes construction while the house rises (Aurora's spec:
-- 61:4100 windup 279f -> 61:4101 hammer loop while building -> 61:4102 finish 398f).
-- Motion = the proven carry-walk layer-0 drive; FSM disabled for the scene, ALWAYS re-enabled.
local scene = nil
local function _pch()
    local ch
    pcall(function() ch = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer") end)
    return ch
end
local function _fsm_enabled(on)
    pcall(function()
        local h = _pch():call("get_Human")
        if h and h.Fsm then h.Fsm:set_Enabled(on) end
    end)
end
local function _play_clip(bank, clip)
    local ok = pcall(function()
        _pch():call("get_Motion"):call("getLayer", 0):call(
            "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
            bank, clip, 0.0, 6.0, 1, 1)
    end)
    return ok
end

-- the sign's desired rotation for a plot: absolute per-plot yaw if authored, else face the
-- arrival point (+ the global offset; the readable/examine side = the mesh's back)
local function _sign_quat(rec)
    local yaw
    if rec.sign_yaw ~= nil then
        yaw = math.rad(rec.sign_yaw)
    elseif rec.tx and rec.ux then
        yaw = math.atan(rec.tx - rec.ux, rec.tz - rec.uz) + math.rad(M.sign_yaw_off or 180)
    else
        return nil
    end
    return { x = 0, y = math.sin(yaw / 2), z = 0, w = math.cos(yaw / 2) }
end

-- ADOPT before spawning: a script reset drops our refs but the world sign SURVIVES - find any
-- app.gm81_128 gimmick near the plot and re-own it (kills the duplicate-sign bug); extras get
-- destroyed. Identity learned from the GO log: name 'gm81_129', brain comp 'app.gm81_128'.
local function _adopt_sign(rec)
    local adopted = nil
    pcall(function()
        local up, rp = _player_upos(), _player_rpos()
        if not (up and rp) then return end
        local kx, ky, kz = up.x - rp.x, up.y - rp.y, up.z - rp.z
        local sp = _sign_upos(rec)
        local prx, prz = sp.x - kx, sp.z - kz
        local smgr = sdk.get_native_singleton("via.SceneManager")
        local scene = smgr and sdk.call_native_func(smgr, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        -- plot center in render coords too: stale signs from BEFORE the door-front move
        -- stand at the center - they must be demolished, not orphaned (Aurora: examined the
        -- old center sign, the opener measured to the door-front, dialog never came)
        local pcx, pcz = (rec.ux or 0) - kx, (rec.uz or 0) - kz
        local arr = scene and scene:call("findComponents(System.Type)", sdk.typeof("app.gm81_128"))
        local n = arr and arr:get_size() or 0
        for i = 0, (tonumber(n) or 0) - 1 do
            pcall(function()
                local c = arr:get_element(i)
                local go = c:call("get_GameObject")
                local p = go:call("get_Transform"):call("get_Position")
                local dx, dz = p.x - prx, p.z - prz
                local cx, cz = p.x - pcx, p.z - pcz
                if dx * dx + dz * dz < 25.0 then
                    if not adopted then
                        adopted = go:add_ref()
                    else
                        pcall(function() go:call("destroy", go) end)   -- duplicate: down it goes
                        _log("adopt: destroyed a DUPLICATE sign at the plot")
                    end
                elseif cx * cx + cz * cz < 400.0 then
                    -- a sign near OUR plot but not at the door-front = a stale-position relic
                    pcall(function() go:call("destroy", go) end)
                    _log("adopt: destroyed a STALE-POSITION sign near the plot")
                end
            end)
        end
    end)
    return adopted
end

-- the 'Castle' hunt, phase 3: the label never crossed the message hooks - it lives in the
-- sign's OWN component (app.gm81_128, learned from the GO dump; capital-G probes were nil).
-- Dump its full API once + sniff our standing sign's instance fields for guid/msg/text-ish
-- values -> next pass WRITES the field instead of hooking text.
local function _dump_sign_component()
    local f = io.open("IRIS/deed_sign_api.txt", "w")
    if not f then return end
    f:write("SIGN COMPONENT API " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n\n")
    for _, tn in ipairs({ "app.gm81_128", "app.gm81_129", "app.Gm81_128Param", "app.GimmickTextInteractSettingUserdata" }) do
        local td = sdk.find_type_definition(tn)
        if td then
            f:write("### " .. tn .. "  (parent: " .. tostring(td:get_parent_type() and td:get_parent_type():get_full_name()) .. ")\n")
            pcall(function()
                for _, m in ipairs(td:get_methods()) do
                    local ps = {}
                    pcall(function() for _, pt in ipairs(m:get_param_types()) do ps[#ps + 1] = pt:get_full_name() end end)
                    local rt = "?"; pcall(function() rt = m:get_return_type():get_full_name() end)
                    f:write("  " .. m:get_name() .. "(" .. table.concat(ps, ", ") .. ") -> " .. rt .. "\n")
                end
            end)
            pcall(function()
                for _, fl in ipairs(td:get_fields()) do
                    local ft = "?"; pcall(function() ft = fl:get_type():get_full_name() end)
                    f:write("  ." .. fl:get_name() .. " : " .. ft .. "\n")
                end
            end)
            f:write("\n")
        else
            f:write("(no typedef: " .. tn .. ")\n\n")
        end
    end
    -- live instance sniff: our standing sign's brain, field values
    if sign.go then
        pcall(function()
            local c = sign.go:call("getComponent(System.Type)", sdk.typeof("app.gm81_128"))
            if not c then f:write("(standing sign has no app.gm81_128 component?)\n"); return end
            f:write("### LIVE field values on OUR sign's app.gm81_128\n")
            local td = c:get_type_definition()
            for _, fl in ipairs(td:get_fields()) do
                pcall(function()
                    local fn = fl:get_name()
                    local v = c:get_field(fn)
                    local vs = tostring(v)
                    pcall(function() vs = tostring(v:call("ToString()")) end)
                    f:write("  ." .. fn .. " = " .. vs .. "\n")
                end)
            end
            -- and one level DOWN into _Param (the Castle suspect)
            pcall(function()
                local prm = c:get_field("_Param")
                if not prm then f:write("  (_Param is nil)\n"); return end
                f:write("### LIVE _Param (" .. prm:get_type_definition():get_full_name() .. ") fields\n")
                for _, fl in ipairs(prm:get_type_definition():get_fields()) do
                    pcall(function()
                        local fn = fl:get_name()
                        local v = prm:get_field(fn)
                        local vs = tostring(v)
                        pcall(function() vs = tostring(v:call("ToString()")) end)
                        f:write("  ." .. fn .. " = " .. vs .. "\n")
                    end)
                end
            end)
        end)
    end
    f:close()
    M.last = "sign component dump -> IRIS/deed_sign_api.txt (the Castle field hunt)"
    _log(M.last)
end

local function _ensure_sign(rec)
    if sign.rec == rec and (sign.go or #sign.jobs > 0) then return end   -- already up / coming
    if sign.rec ~= rec then _remove_sign() end
    if #sign.jobs > 0 then return end
    sign.rec = rec
    -- a survivor from a script reset? re-own it instead of growing a twin.
    -- ⛔ NOT right after a respawn: destroy is DEFERRED a frame - adopting would re-own the
    -- DYING sign and leave our state holding a ghost (invisible sign, respawn 'does nothing')
    local old = (os.clock() > (sign.no_adopt_until or 0)) and _adopt_sign(rec) or nil
    if old then
        sign.go = old
        sign.pos = _sign_upos(rec)
        sign.rot_quat = _sign_quat(rec)
        sign.reint_at = os.clock() + 0.8   -- re-register the interact zone after rotation lands
        _repoint_sign_text(old)
        _log("sign ADOPTED at plot '" .. tostring(rec.name) .. "' (script-reset survivor)")
        M.last = "sign adopted at '" .. tostring(rec.name) .. "'"
        return
    end
    local gid
    pcall(function()
        local fld = sdk.find_type_definition("app.GimmickID"):get_field("Gm81_129")
        if fld then gid = fld:get_data() end
    end)
    if not gid then M.last = "Gm81_129 not in the GimmickID enum?!"; _log(M.last); return end
    local sp = _sign_upos(rec)
    sign.pos = sp
    sign.jobs[#sign.jobs + 1] = {
        x = sp.x, y = sp.y, z = sp.z,
        gid = gid, stage = "prefab", f = 0, rq = _sign_quat(rec),
        path_override = "AppSystem/gimmick/prefab/gm81_129.pfb",
    }
    _log(string.format("sign requested at DOOR-FRONT of '%s' (%.1f,%.1f,%.1f)", tostring(rec.name), sp.x, sp.y, sp.z))
end

_G.IrisDeedSign = {
    ensure_sign = _ensure_sign,
    remove_sign = _remove_sign,
    active = function() return sign.rec end,
}

-- ── the pump: spawn jobs + the purchase interaction ──────────────────────────────────────
re.on_application_entry("UpdateBehavior", function()
    -- spawn state machine (quarry recipe: prefab -> wait ready -> requestCreateInstance -> poll)
    for i = #sign.jobs, 1, -1 do
        local q = sign.jobs[i]
        local drop = false
        if q.stage == "prefab" then
            local ok = pcall(function()
                local prefab = sdk.create_instance("via.Prefab"):add_ref()
                prefab:set_Path(q.path_override)
                pcall(function() prefab:set_Standby(true) end)
                local ctrl = sdk.create_instance("app.PrefabController"):add_ref()
                ctrl._Item = prefab
                pcall(function() ctrl:get_Item():set_Standby(true) end)
                local inst = sdk.create_instance("app.InstanceInfo"):add_ref()
                local container
                pcall(function() container = inst:get_Container() end)
                if not container then container = sdk.create_instance("app.GenerateInfo.GenerateInfoContainer"):add_ref() end
                local pos = ValueType.new(sdk.find_type_definition("via.Position"))
                pos.x, pos.y, pos.z = q.x, q.y, q.z
                local cat = 5
                pcall(function()
                    local f2 = sdk.find_type_definition("app.GeneratorCategory"):get_field("Gimmick")
                    if f2 then cat = f2:get_data() end
                end)
                pcall(function() container._CommonInfo._Category = cat end)
                pcall(function() container._CommonInfo._ObjectID._SelectedGimmickID = q.gid end)
                pcall(function() container._CommonInfo._InitialPosition = pos end)
                pcall(function() container._CommonInfo._ContextPosition = pos end)
                pcall(function() container._CommonInfo:setContextPosition(pos) end)
                if q.rq and (M.angle_mode or 1) > 0 then
                    -- spawn-time rotation (typedef-dumped: CommonInfoData._InitialAngle/
                    -- _ContextAngle quaternions + setInitialAngle/setContextAngle). Writing
                    -- ALL FOUR made the sign spawn INVISIBLE at the right spot (07-23) - so
                    -- the mode combo bisects which write is safe:
                    -- 1=setInitialAngle only  2=setContextAngle only  3=both setters  4=raw fields
                    pcall(function()
                        local rqt = ValueType.new(sdk.find_type_definition("via.Quaternion"))
                        rqt.x, rqt.y, rqt.z, rqt.w = q.rq.x, q.rq.y, q.rq.z, q.rq.w
                        local am = M.angle_mode or 1
                        if am == 1 or am == 3 then pcall(function() container._CommonInfo:setInitialAngle(rqt) end) end
                        if am == 2 or am == 3 then pcall(function() container._CommonInfo:setContextAngle(rqt) end) end
                        if am == 4 then
                            pcall(function() container._CommonInfo._InitialAngle = rqt end)
                            pcall(function() container._CommonInfo._ContextAngle = rqt end)
                        end
                    end)
                end
                pcall(function() container._StatusInfo["<ScaleRate>k__BackingField"] = 1.0 end)
                q.prefab, q.ctrl, q.inst, q.container = prefab, ctrl, inst, container
            end)
            if ok and q.prefab then q.stage = "wait"; q.f = 0 else drop = true end
        elseif q.stage == "wait" then
            q.f = q.f + 1
            local ready = false
            pcall(function() ready = q.prefab:get_Ready() == true end)
            if ready then
                sign.seq = sign.seq + 1
                local okr = pcall(function()
                    local gen = sdk.get_managed_singleton("app.GenerateManager")
                    gen:call("requestCreateInstance(app.PrefabController, app.GenerateInfo.GenerateInfoContainer, System.Int32, app.InstanceInfo, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>)",
                        q.ctrl, q.container, 741000 + sign.seq, q.inst, nil, nil)
                end)
                if okr then q.stage = "poll"; q.f = 0 else drop = true end
            elseif q.f > 1500 then drop = true end
        elseif q.stage == "poll" then
            q.f = q.f + 1
            local go
            pcall(function() go = q.inst:get_Instance() end)
            if not go then pcall(function() go = q.inst["<Instance>k__BackingField"] end) end
            if go then
                pcall(function() go = go:add_ref() end)
                sign.go = go
                -- FIRST rotation write IMMEDIATELY (race the component start(): the examine
                -- zone bakes there - if this lands first, zone and mesh agree from birth)
                if q.rq then pcall(function()
                    local t2 = go:call("get_Transform")
                    local qt = ValueType.new(sdk.find_type_definition("via.Quaternion"))
                    qt.x, qt.y, qt.z, qt.w = q.rq.x, q.rq.y, q.rq.z, q.rq.w
                    t2:call("set_Rotation", qt)
                end) end
                if sign.rec then sign.rot_quat = _sign_quat(sign.rec) end
                sign.reint_at = os.clock() + 0.8   -- re-register interact zone post-rotation
                _repoint_sign_text(go)             -- never say Castle
                -- learn the GO's identity (duplicate-on-reset adoption groundwork)
                pcall(function()
                    local nm = tostring(go:call("get_Name"))
                    local comps = {}
                    pcall(function()
                        local arr = go:call("get_Components")
                        for ci = 0, (arr:get_size() or 1) - 1 do
                            pcall(function() comps[#comps + 1] = arr:get_element(ci):get_type_definition():get_full_name() end)
                        end
                    end)
                    _log("sign GO name='" .. nm .. "' comps=[" .. table.concat(comps, ", ") .. "]")
                end)
                -- WHERE did it actually land? (the _InitialAngle experiment may relocate the
                -- spawn frame - log truth, not intention)
                pcall(function()
                    local p = go:call("get_Transform"):call("get_Position")
                    local up2 = go:call("get_Transform"):call("get_UniversalPosition")
                    _log(string.format("sign up: render(%.1f,%.1f,%.1f) universal(%.1f,%.1f,%.1f) expected-universal(%.1f,%.1f,%.1f)",
                        p.x, p.y, p.z, up2.x, up2.y, up2.z, q.x, q.y, q.z))
                end)
                _log("sign up at plot '" .. tostring(sign.rec and sign.rec.name) .. "'")
                M.last = "sign standing at '" .. tostring(sign.rec and sign.rec.name) .. "'"
                drop = true
            elseif q.f > 1500 then drop = true end
        end
        if drop then table.remove(sign.jobs, i) end
    end

    -- ── the BUILD SCENE state machine (owns the player while the house rises) ──────────────
    if scene then
        local st = scene
        if st.stage == "start" then
            if os.clock() - st.t > 279 / 60 then
                st.stage, st.t, st.relast = "loop", os.clock(), os.clock()
                _play_clip(61, 4101)
                -- the hammering begins: NOW the real build starts underneath it
                st.rec.built = true
                pcall(function() if _G.IrisHomesteadPlots then _G.IrisHomesteadPlots.save() end end)
                _remove_sign()
                _log("build scene: loop + house build triggered")
            end
        elseif st.stage == "loop" then
            if os.clock() - (st.relast or 0) > 2.5 then st.relast = os.clock(); _play_clip(61, 4101) end
            local done = false
            pcall(function()
                local fst = _G.IrisForge and _G.IrisForge.status()
                done = fst and (fst.instances or 0) > 0 and not fst.building
            end)
            if (done and os.clock() - st.t > 6.0) or os.clock() - st.t > 45.0 then
                st.stage, st.t = "finish", os.clock()
                _play_clip(61, 4102)
                _log("build scene: finish")
            end
        elseif st.stage == "finish" then
            if os.clock() - st.t > 398 / 60 then
                _fsm_enabled(true)
                _log("build scene complete at '" .. tostring(st.rec.name) .. "'")
                st.stage, st.t = "done", os.clock()   -- curtain call: hold the banner
            end
        elseif st.stage == "done" then
            -- the card is a fed-every-frame widget (1s decay) - feed it for the full bow
            -- (Aurora: "only popped up for a second, needs to be much longer")
            pcall(function()
                local F = _G.IrisFont
                if F then F.card("Your house is complete!", tostring(st.rec.name or ""), 0xFF9FE6A0) end
            end)
            if os.clock() - st.t > 8.0 then scene = nil end
        end
        if scene and scene.stage ~= "done" then
            -- the universal bar tells the build too: windup 0-15%, hammering 15-85%, finish to 100%
            local fr = 0.0
            local e = os.clock() - scene.t
            if scene.stage == "start" then fr = 0.15 * math.min(1.0, e / (279 / 60))
            elseif scene.stage == "loop" then fr = 0.15 + 0.70 * math.min(1.0, e / 25.0)
            else fr = 0.85 + 0.15 * math.min(1.0, e / (398 / 60)) end
            _G.IrisProgressHUD = { active = true, t = os.clock(), frac = fr, label = "Raising the house" }
        end
        return
    end

    -- interact-zone re-registration EXPERIMENT (Aurora: examine stays on the sign's original
    -- back after rotation - the zone bakes at component start): once rotation has settled,
    -- toggle IsEnableInteract off->on to nudge a re-register with the rotated transform
    if sign.go and sign.reint_at and os.clock() > sign.reint_at then
        sign.reint_at = nil
        pcall(function()
            local c = sign.go:call("getComponent(System.Type)", sdk.typeof("app.gm81_128"))
            if c then
                c:set_field("IsEnableInteract", false)
                c:set_field("IsEnableInteract", true)
                _log("interact zone re-register nudge applied")
            end
        end)
    end

    -- sign facing: CONTINUOUS re-assert (the FACE law - one-shot writes lost to the gimmick;
    -- Aurora: "can't rotate the sign with the sliders"). One quat write per tick, trivial.
    if sign.go and sign.rot_quat then
        pcall(function()
            local t2 = sign.go:call("get_Transform")
            local qt = ValueType.new(sdk.find_type_definition("via.Quaternion"))
            qt.x, qt.y, qt.z, qt.w = sign.rot_quat.x, sign.rot_quat.y, sign.rot_quat.z, sign.rot_quat.w
            t2:call("set_Rotation", qt)
        end)
    end

    -- purchase interaction: the NATIVE dialog (pops on approach; re-arms when you walk away)
    if not (sign.go and sign.rec) then sign.near = false; return end
    local up = _player_upos()
    if not up then return end
    local sx = (sign.pos and sign.pos.x) or sign.rec.ux or 0
    local sz = (sign.pos and sign.pos.z) or sign.rec.uz or 0
    local dx, dz = sx - up.x, sz - up.z
    local dist = math.sqrt(dx * dx + dz * dz)   -- distance to the SIGN (door-front), not plot center
    sign.near = dist <= 8.0   -- feeds the sign-text rewrite + examine hooks (cheap flag, no
                              -- position math inside the hot message hook)
    if dist > 220.0 and dist < 100000.0 then _remove_sign(); return end   -- out of draw range

    -- ── CONSTRUCTION MODE (owned, not built): the tracker card; examine the sign to build ──
    local construction = sign.rec.owned == true and sign.rec.built == false
    if construction and sign.quarry_for ~= sign.rec then
        -- a construction site DESERVES its quarry (Aurora 07-23): spawn the stone vein beside
        -- the plot the moment construction opens - materials shouldn't need a field trip.
        -- Plot-local (-10, 8) rotated by yaw = clear of the house footprint, opposite the sign.
        sign.quarry_for = sign.rec
        pcall(function()
            if _G.IrisQuarry and (_G.IrisQuarry.count() or 0) == 0 then
                local rec = sign.rec
                local th = math.rad(rec.yaw or 0)
                local s, c = math.sin(th), math.cos(th)
                local qx = (rec.ux or 0) + (-10.0) * c + 8.0 * s
                local qz = (rec.uz or 0) - (-10.0) * s + 8.0 * c
                _G.IrisQuarry.spawn(qx, rec.uy or 0, qz)
                _log(string.format("construction quarry requested at (%.1f,%.1f)", qx, qz))
            end
        end)
    end
    if construction and not dlg.open then
        -- site-wide card (plot-center radius: you see progress anywhere on your land)
        local cdx, cdz = (sign.rec.ux or 0) - up.x, (sign.rec.uz or 0) - up.z
        if cdx * cdx + cdz * cdz <= 625.0 then
            local ns = _count_item(STONE_ITEM)
            local nt = _count_item(TIMBER_ITEM)
            local _, need_s, need_t = _deed_terms(sign.rec)
            sign.ready = (ns == nil or ns >= need_s) and (nt == nil or nt >= need_t)
            -- ⭐ THE UNIVERSAL PROGRESS BAR (Aurora 07-21: "use a bar like this for ALL the
            -- progress stuff"; 07-23: "I want EVERYTHING to use that font"): the native-styled
            -- amber gauge, fed like the rodeo/palm rites. frac = combined material progress.
            local fs = math.min(1.0, (tonumber(ns) or 0) / math.max(1, need_s))
            local ft = math.min(1.0, (tonumber(nt) or 0) / math.max(1, need_t))
            _G.IrisProgressHUD = {
                active = true, t = os.clock(),
                bars = {
                    { frac = fs, label = sign.ready and "Materials ready! Examine the sign"
                        or string.format("Stone %s/%d", tostring(ns or "?"), need_s) },
                    { frac = ft, label = sign.ready and ""
                        or string.format("Timber %s/%d", tostring(nt or "?"), need_t) },
                },
            }
        end
    end

    if dlg.open then
        local p = _dialog_pick()
        -- act only on a CHANGE from the open-time baseline (the latch keeps old answers around)
        if p ~= nil and p ~= dlg.baseline then
            _log("dialog pick CHANGE " .. tostring(dlg.baseline) .. " -> " .. tostring(p) .. " (phase=" .. tostring(dlg.phase) .. ")")
            dlg.baseline = p
        else
            p = nil
        end
        -- stuck guard: whatever went wrong (native cancel we can't see, frozen reader), never
        -- leave a paused world with no exit
        if p == nil and os.clock() - dlg.opened_at > 30.0 then
            _log("dialog STUCK 30s -> force close")
            _close_dialog()
            dlg.armed = false
            return
        end
        -- debounce: NOTHING within 0.25s of open counts (the phantom-purchase bug: a stale
        -- latched Sel0 bought the plot the instant the dialog appeared)
        if p ~= nil and os.clock() - dlg.opened_at < 0.25 then p = nil end
        -- ⭐ TRUE RetVal mapping (enum dump 07-23; the discovery notes had it WRONG):
        -- None=0 Sel0=1 Sel1=2 Sel2=3 Cancel=5. "Leave"=Sel1=2 was hitting the old "2=buy"
        -- branch - the whole Leave-buys-the-plot bug was a mislabeled enum.
        if dlg.phase == "build" then
            -- o1="Begin construction"(Sel0=1), o2="Not yet"(Sel1=2, bottom/default = safe)
            if p == 1 then
                _close_dialog()
                local _, need_s, need_t = _deed_terms(sign.rec)
                _consume_item(STONE_ITEM, need_s)
                _consume_item(TIMBER_ITEM, need_t)
                _log("CONSTRUCTION confirmed at '" .. tostring(sign.rec.name) .. "' -> build scene")
                M.last = "construction: the house rises at '" .. tostring(sign.rec.name) .. "'"
                -- the BUILD SCENE: windup now; the hammer loop + actual build follow in the pump
                _fsm_enabled(false)
                _play_clip(61, 4100)
                scene = { stage = "start", t = os.clock(), rec = sign.rec }
            elseif p == 2 or p == 5 then   -- Not yet / Cancel
                _close_dialog()
            end
        elseif dlg.phase == "confirm" then
            -- confirm options: o1="Confirm purchase"(Sel0=1), o2="Not yet"(Sel1=2, bottom =
            -- the default highlight = the SAFE slot)
            if p == 1 then           -- Sel0 = Confirm purchase
                _close_dialog()
                dlg.armed = false
                local plot_price = _deed_terms(sign.rec)
                local paid = _try_pay(plot_price)
                if paid == "poor" then
                    M.last = "purchase refused: not enough gold (" .. plot_price .. " G needed)"
                    _log(M.last)
                    return
                end
                sign.rec.owned = true
                sign.rec.built = false   -- construction stage next, NOT an instant house
                pcall(function() if _G.IrisHomesteadPlots then _G.IrisHomesteadPlots.save() end end)
                _log(string.format("PURCHASED plot '%s' (paid=%s price=%d) -> construction stage", tostring(sign.rec.name), tostring(paid), plot_price))
                M.last = "plot '" .. tostring(sign.rec.name) .. "' purchased - now gather materials"
                if paid ~= true then _dump_money_api() end
                -- respawn the sign: it becomes the construction-site marker, and only a fresh
                -- spawn re-fetches the label ("Under Construction" via the text hook)
                _remove_sign()   -- the homestead loop re-ensures it next pass (built == false)
            elseif p == 2 or p == 5 then   -- Sel1 = Not yet / Cancel
                _close_dialog()
            end
        else
            -- offer options: o1="Purchase the plot"(Sel0=1), o2="Leave"(Sel1=2, bottom/default)
            if p == 1 then       -- Sel0 = Purchase -> second-step confirm
                _close_dialog()
                dlg.next_confirm_at = os.clock() + 0.35   -- let the GUI breathe between dialogs
            elseif p == 2 or p == 5 then   -- Sel1 = Leave / Cancel
                _close_dialog()
                dlg.armed = false  -- no nagging: walk 8m away to re-arm
            end
        end
        return
    end

    -- deferred second-step confirm (opening immediately after a close races the GUI)
    if dlg.next_confirm_at then
        if os.clock() >= dlg.next_confirm_at then
            dlg.next_confirm_at = nil
            dlg.phase = "confirm"
            _show_dialog("Purchase this plot for " .. tostring((_deed_terms(sign.rec))) .. " G?",
                "Confirm purchase", "Not yet")
        end
        return
    end

    -- NO auto-open (Aurora 07-23: "should only dialogue when you press it"). The offer/build
    -- dialog opens from the sign examine (runes-close event) or the fallback key.
    if dlg.want_open and dist <= 4.5 then
        dlg.want_open = nil
        local d_price, d_stone, d_timber = _deed_terms(sign.rec)
        if sign.rec.owned == false then
            dlg.phase = "offer"
            _show_dialog("This plot of land is for sale.\n" .. tostring(d_price) .. " G",
                "Purchase the plot", "Leave")
        elseif construction and sign.ready then
            dlg.phase = "build"
            _show_dialog(string.format("Begin construction?\nStone %d and Timber %d will be used.",
                    d_stone, d_timber),
                "Begin construction", "Not yet")
        end
        return
    end
    dlg.want_open = nil
    if not (sign.rec.owned == false or construction) then return end
    if dist <= 4.0 then
        local pressed = false
        pcall(function() pressed = iris_kb(0x0D) end)   -- Enter (fallback trigger), gated: Enter in a text box must not open the deed
        if pressed and not dlg.enter_prev then dlg.want_open = true end
        dlg.enter_prev = pressed
    else
        dlg.enter_prev = false
    end
end)

-- ── SIGN TEXT REWRITE: the runes can't say "Castle" on a land deed ────────────────────────
-- Proven pattern (Bestiary's DragonsplagueRework): hook via.gui.message.get(Guid); when the
-- fetched text is the sign's location label AND the player is near OUR for-sale sign, hand
-- back our own string. Near-sign message fetches are also LOGGED (deduped) so if a sign in
-- another region says "Melve" instead of "Castle", the log teaches us what to add.
-- what the sign should say, by plot state
local function _sign_label()
    local rec = sign.rec
    if rec and rec.owned == true and rec.built == false then return "Under Construction" end
    return M.sign_text or "Land for Sale"
end
sign.msg_seen = {}
local function _msg_post(retval)
    local out = retval
    pcall(function()
        local obj = sdk.to_managed_object(retval)
        if not obj then return end
        local s
        pcall(function() s = obj:call("ToString()") end)
        if type(s) ~= "string" then return end
        if s == "Castle" then
            -- ALWAYS log a Castle fetch (the label kept surviving - WHEN it's fetched is the
            -- question); replace whenever a sign is up OR mid-spawn
            local gate = (sign.go ~= nil) or (#sign.jobs > 0)
            if os.clock() - (sign.castle_log_at or 0) > 1.0 then
                sign.castle_log_at = os.clock()
                _log("Castle fetch! gate=" .. tostring(gate))
            end
            if gate then out = sdk.to_ptr(sdk.create_managed_string(_sign_label())) end
            return
        end
        if not sign.go then return end
        if sign.near then
            local guid = "?"
            pcall(function() guid = thread.get_hook_storage().guid or "?" end)
            if not sign.msg_seen[guid] and #s > 0 and #s < 60 then
                sign.msg_seen[guid] = true
                _log("msg near sign: guid=" .. guid .. " text='" .. s .. "'")
            end
        end
    end)
    return out
end
local function _msg_pre(args)
    pcall(function()
        thread.get_hook_storage().guid = sdk.to_valuetype(args[2], "System.Guid"):ToString()
    end)
end
pcall(function()
    -- hook EVERY Guid-taking get on via.gui.message + app.MessageManager.getMessage: the
    -- 'Castle' label never appeared through get(System.Guid) alone - it travels another lane
    local hooked = 0
    local td = sdk.find_type_definition("via.gui.message")
    if td then
        for _, m in ipairs(td:get_methods()) do
            pcall(function()
                if m:get_name() == "get" then
                    local ps = m:get_param_types()
                    if ps and #ps >= 1 and ps[1]:get_full_name() == "System.Guid" then
                        sdk.hook(m, _msg_pre, _msg_post)
                        hooked = hooked + 1
                    end
                end
            end)
        end
    end
    pcall(function()
        local mm = sdk.find_type_definition("app.MessageManager"):get_method("getMessage(System.Guid)")
        if mm then sdk.hook(mm, _msg_pre, _msg_post); hooked = hooked + 1 end
    end)
    _log("sign-text rewrite armed on " .. hooked .. " message surfaces")
end)

-- dump the spawn container's CommonInfo fields once: the spawn-time rotation attempts wrote
-- guessed names (_InitialRotation etc, all pcall-eaten) - the REAL field name lives here
pcall(function()
    local td = sdk.find_type_definition("app.GenerateInfo.CommonInfoData")
    if not td then _log("CommonInfoData typedef not found"); return end
    local parts = {}
    for _, fl in ipairs(td:get_fields()) do
        pcall(function() parts[#parts + 1] = fl:get_name() .. ":" .. fl:get_type():get_full_name() end)
    end
    _log("CommonInfoData fields: " .. table.concat(parts, "  "))
    -- and its methods (setContextPosition lived here - a rotation sibling may too)
    local ms = {}
    for _, m in ipairs(td:get_methods()) do
        pcall(function()
            local mn = m:get_name()
            if mn:lower():find("rot") or mn:lower():find("angle") or mn:lower():find("dir") or mn:lower():find("deg") then
                ms[#ms + 1] = mn
            end
        end)
    end
    _log("CommonInfoData rotation-ish methods: " .. table.concat(ms, "  "))
end)

-- name the RetVal enum honestly (the Leave-buys-the-plot bug: our 2=Sel0/3=Sel1 assumption
-- may be wrong, or mouse clicks decide the PAD cursor's option - the values tell)
pcall(function()
    local td = sdk.find_type_definition("app.ui010101.RetVal")
    if not td then _log("RetVal typedef not found"); return end
    local parts = {}
    for _, f in ipairs(td:get_fields()) do
        pcall(function()
            local v = f:get_data()
            if v ~= nil then parts[#parts + 1] = f:get_name() .. "=" .. tostring(v) end
        end)
    end
    _log("RetVal enum: " .. table.concat(parts, " "))
end)

-- ── THE REAL EXAMINE HOOK (component dump 07-23): app.gm81_128.onStartInteract fires when
-- the player examines a signpost. Ours -> SKIP the runes entirely and open the offer (the
-- clean flow Aurora asked for). Construction state -> materials card instead.
pcall(function()
    local m = sdk.find_type_definition("app.gm81_128"):get_method("onStartInteract(System.UInt32, app.Character)")
    if not m then _log("onStartInteract not found"); return end
    sdk.hook(m, function(args)
        local ours = false
        pcall(function()
            if not (sign.go and sign.rec) then return end
            local comp = sdk.to_managed_object(args[2])
            local go = comp and comp:call("get_GameObject")
            ours = go and sign.go and go:call("get_Address") == sign.go:call("get_Address")
            if ours == nil then ours = false end
        end)
        if not ours then
            -- address compare can be flaky across wrappers: fall back to proximity
            pcall(function()
                if sign.go and sign.rec and sign.near then ours = true end
            end)
        end
        if ours then
            -- ⛔ NO SKIP (Aurora 07-23: skipping starves the interact framework - the Examine
            -- prompt vanishes forever after one use). Let the native runes run (their guid is
            -- REPOINTED at spawn so they never say Castle); the runes-close trigger opens the
            -- offer. This hook just logs + shows the construction card.
            _log("onStartInteract on OUR sign (native flow runs; runes-close opens the dialog)")
        end
    end, function(r) return r end)
    _log("examine hook armed on app.gm81_128.onStartInteract")
end)

-- ── EXAMINE INTERCEPT: learn the sign-reader's GuiType, then hijack it ────────────────────
-- The native F-Examine opens the location-sign reader ("Castle" runes) via app.GuiManager.
-- Near OUR sign we log every requestGuiType id; once M.examine_gui_type is set to the reader's
-- id, the request is SWALLOWED (PREEMPT) and the purchase dialog opens instead - press F on
-- the sign, get the offer. (Type 14 = our own Dialog, never intercepted.)
pcall(function()
    local m = sdk.find_type_definition("app.GuiManager"):get_method("requestGuiType")
    if not m then _log("requestGuiType method not found - examine intercept dead"); return end
    sdk.hook(m, function(args)
        local hijack = false
        pcall(function()
            if not (sign.go and sign.rec) then return end
            -- ⛔ use the pump-fed sign.near flag, NOT plot-center math: the door-front sign
            -- stands 7.3m from rec.ux - center-distance silently discarded every runes-close
            -- event after the sign moved (Aurora: "still not giving me the dialogue")
            if not sign.near then return end
            local t = sdk.to_int64(args[3]) & 0xFFFFFFFF
            if t == DIALOG_GUITYPE then return end
            if os.clock() - (dlg.gui_log_at or 0) > 0.5 or t ~= dlg.gui_log_last then
                dlg.gui_log_at, dlg.gui_log_last = os.clock(), t
                _log("requestGuiType near sign: type=" .. tostring(t))
            end
            -- LEARNED 07-23 (log forensics): the runes reader does NOT open through
            -- requestGuiType - but CLOSING it fires type=0 ("back to main HUD"). So the flow
            -- is: F reads the sign, A closes it, the OFFER opens. Debounced so one close =
            -- one offer; walking off resets. (An explicitly-set examine_gui_type still
            -- hard-intercepts, for future sharper signals.)
            if (tonumber(M.examine_gui_type) or -1) == t then
                hijack = true
                dlg.want_open = true
            elseif t == 0 and M.offer_on_close ~= false and not dlg.open
                and os.clock() - (dlg.closed_at or 0) > 2.0
                and os.clock() - (dlg.offered_at or 0) > 3.0 then
                dlg.offered_at = os.clock()
                dlg.want_open = true   -- the pump opens the offer on the game thread
            end
        end)
        if hijack then return sdk.PreHookResult.SKIP_ORIGINAL end
    end, function(r) return r end)
    _log("examine-intercept hook armed on requestGuiType")
end)

-- DIAGNOSTIC watchdog (render thread): while the dialog is open, log the raw state once a
-- second from on_frame too. If the UB log goes silent while this keeps ticking, the pause
-- freezes UpdateBehavior and the reader must move (or pause_world goes off). READ-only.
re.on_frame(function()
    if not dlg.open then return end
    if os.clock() - (dlg.rt_log_at or 0) < 1.0 then return end
    dlg.rt_log_at = os.clock()
    local p = _dialog_pick()
    _log("RT watchdog: state=" .. tostring(p) .. " open_for=" .. string.format("%.0fs", os.clock() - dlg.opened_at))
end)

re.on_script_reset(function()
    -- drop refs only; the standing sign clears on area reload (destroy-on-reset CTD law).
    -- but DO close an open dialog - a paused game with no reader is a softlock.
    -- and NEVER leave the player FSM-frozen mid build-scene (locked controls law)
    if scene then _fsm_enabled(true); scene = nil end
    if dlg.open then _close_dialog() end
    sign.go, sign.rec, sign.rot_quat = nil, nil, nil
    sign.jobs, sign.rot_passes = {}, 0
    dlg.armed = true
end)

re.on_draw_ui(function()
    if imgui.tree_node("IRIS DEED SIGN (plot purchase)") then
        imgui.text(M.last)
        local c
        c, M.price = imgui.drag_int("plot price (G)##ids_p", M.price, 100, 0, 500000)
        local oc
        c, oc = imgui.checkbox("offer opens after CLOSING the sign's runes (examine -> A -> offer)##ids_oc", M.offer_on_close ~= false)
        if c then M.offer_on_close = oc end
        local st
        c, st = imgui.input_text("sign text (replaces 'Castle')##ids_st", M.sign_text or "Land for Sale")
        if c then M.sign_text = st end
        c, M.req_stone = imgui.slider_int("construction: Stone needed##ids_rs2", M.req_stone or 60, 0, 200)
        c, M.req_timber = imgui.slider_int("construction: Timber needed##ids_rt", M.req_timber or 25, 0, 200)
        imgui.text("  (fallback: ENTER within 4m also opens the offer)")
        local pw
        c, pw = imgui.checkbox("dialog pauses the world##ids_pw", M.pause_world ~= false)
        if c then M.pause_world = pw end
        imgui.text("  (if picks/B never register with pause ON, turn it OFF - the reader may")
        imgui.text("   be frozen by the pause; the log's RT watchdog lines will confirm)")
        if sign.rec then
            -- PER-PLOT sign authoring (persists into the plot record; ships with the plot)
            local rec = sign.rec
            local yaw_now = rec.sign_yaw or 0.0
            local cy, ny = imgui.slider_float("THIS plot's sign yaw (deg, live)##ids_py", yaw_now, -180.0, 180.0)
            if cy then
                rec.sign_yaw = ny
                sign.rot_quat = _sign_quat(rec)   -- live: the continuous re-assert paints it
                pcall(function() _G.IrisHomesteadPlots.save() end)
            end
            local ch, nh = imgui.slider_float("THIS plot's sign height (m)##ids_ph", rec.sign_y or M.sign_y_off or 0.0, -3.0, 1.0)
            if ch then
                rec.sign_y = nh
                pcall(function() _G.IrisHomesteadPlots.save() end)
            end
            imgui.same_line()
            if imgui.button("RESPAWN (apply height)##ids_rs") then
                _remove_sign(); _ensure_sign(rec)
            end
        else
            imgui.text("(no sign standing - per-plot yaw/height sliders appear here)")
        end
        if imgui.button("DUMP SIGN COMPONENT (the Castle text hunt)##ids_dc") then
            _dump_sign_component()
        end
        local sd = "(none)"
        if sign.go then
            sd = "UP at '" .. tostring(sign.rec and sign.rec.name) .. "'"
            pcall(function()
                local sp = sign.go:call("get_Transform"):call("get_Position")
                local pp2 = _player_rpos()
                if sp and pp2 then
                    sd = sd .. string.format("  pos(%.1f,%.1f,%.1f) %.1fm from you",
                        sp.x, sp.y, sp.z, math.sqrt((sp.x - pp2.x) ^ 2 + (sp.z - pp2.z) ^ 2))
                end
            end)
        end
        imgui.text("sign: " .. sd)
        local am_names = { "OFF (proven spawn, zone stays backwards)", "setInitialAngle only", "setContextAngle only", "both setters", "raw fields" }
        local cam, vam = imgui.combo("spawn rotation mode (bisect the invisible-sign write)##ids_am", (M.angle_mode or 1) + 1, am_names)
        if cam then M.angle_mode = vam - 1 end
        imgui.text("  RESPAWN after changing; all-four writes made the sign spawn INVISIBLE")
        imgui.text("for-sale plots grow a signpost; walking within 3.5m pops the NATIVE dialog")
        imgui.text("(Purchase / Leave). Declining re-arms after you walk 8m away.")
        imgui.text("gold deduction is probe-first: if it can't pay, purchase is FREE and the")
        imgui.text("money API dump lands in IRIS/money_api.txt for wiring next session.")
        if imgui.button("DUMP MONEY API now##ids_m") then _dump_money_api() end
        imgui.tree_pop()
    end
end)

return M
