-- IrisFurnish.lua - the homestead DECORATING system (v1, 2026-07-23)
-- Aurora's spec: browse a curated catalog (Nick's gimmick index -> furnish_catalog_draft),
-- each piece costs gold, ghost-preview placement (Ark-style: the piece floats ahead of you,
-- walk + sliders to aim), native "are you sure" dialog on place, per-plot persistence.
-- Proven tech only: GenerateManager spawn (+setInitialAngle - the deed sign's lesson),
-- ui010101 native dialog (TRUE RetVal enum: None=0 Sel0=1 Sel1=2 Cancel=5; latch baseline +
-- 0.25s debounce + close-on-reset laws), wallet = ItemManager._Version (_Golden is a DECOY),
-- universal<->render conversion via the player delta. Fences/forge pieces = phase 2.

local M = { last = "(idle) pick a piece, ghost it, walk it into place", cat = 1, page = 0 }

local CATALOG_FILE = "IRIS/furnish_catalog_draft.json"
local PATHS_FILE   = "IRIS/furnish_paths.json"   -- gid -> real pfb path (offline filelist map:
-- gimmick prefabs live in SUBDIRS - interact/chair/breakable/... - the invisible-ghost bug)
local HIDDEN_FILE  = "IRIS/furnish_hidden.json"
local PLACED_FILE  = "IRIS/iris_furniture.json"
-- ⭐ custom categories Aurora adds in the panel. Its own file rather than a field in the catalog,
--   so a category can exist BEFORE anything is filed under it (otherwise a new category would
--   vanish the moment the catalog rebuilt, because nothing referenced it yet).
local EXTRACAT_FILE = "IRIS/furnish_categories.json"

local function _log(s)
    pcall(function()
        local f = io.open("IRIS/furnish_log.txt", "a")
        if f then f:write(string.format("[%s] %s\n", os.date("%H:%M:%S"), tostring(s))); f:close() end
    end)
end

-- ── data ─────────────────────────────────────────────────────────────────────────────────
local catalog = nil        -- { {gid,label,category,price}, ... } sorted, hidden filtered out
local hidden = nil         -- [gid]=true (Aurora's curation)
local placed = nil         -- array of {plot,gid,label,price,ux,uy,uz,yaw}
local cats = {}            -- category names for the combo

local function _load_data()
    if catalog then return end
    hidden = json.load_file(HIDDEN_FILE) or {}
    placed = json.load_file(PLACED_FILE) or {}
    M.extra_cats = json.load_file(EXTRACAT_FILE) or {}
    M.paths = json.load_file(PATHS_FILE) or {}
    local raw = json.load_file(CATALOG_FILE) or {}
    catalog = {}
    cats = {}   -- RESET (the HIDE-button reload was APPENDING: "bedroom bedroom craft craft"
                -- + imgui duplicate-ID screams - Aurora's screenshot)
    local seen_cat = {}
    for gid, e in pairs(raw) do
        if not hidden[gid] and M.paths[gid] then   -- no pfb on disk = scene-baked, unspawnable
            catalog[#catalog + 1] = { gid = gid, label = e.label or gid,
                category = e.category or "misc", price = tonumber(e.price) or 100 }
        end
        if e.category and not seen_cat[e.category] then
            seen_cat[e.category] = true
            cats[#cats + 1] = e.category
        end
    end
    table.sort(catalog, function(a, b)
        if a.category ~= b.category then return a.category < b.category end
        if a.label ~= b.label then return a.label < b.label end
        return a.gid < b.gid
    end)
    table.sort(cats)
    table.insert(cats, 1, "ALL")
    _log("catalog loaded: " .. #catalog .. " pieces, " .. #placed .. " placed")
end
local function _save_hidden() pcall(function() json.dump_file(HIDDEN_FILE, hidden) end) end
local function _save_placed() pcall(function() json.dump_file(PLACED_FILE, placed) end) end

-- ── shared helpers (the session's proven recipes) ────────────────────────────────────────
local function _pgo()
    local go
    pcall(function() go = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer"):call("get_GameObject") end)
    return go
end
local function _ptf() local go = _pgo(); return go and go:call("get_Transform") end
local function _ppos() local tf = _ptf(); local p; if tf then pcall(function() p = tf:call("get_Position") end) end; return p end
local function _pupos() local tf = _ptf(); local p; if tf then pcall(function() p = tf:call("get_UniversalPosition") end) end; return p end
local function _pfwd()
    local tf = _ptf()
    local fx, fz = 0, 1
    if tf then pcall(function()
        local f = tf:call("get_AxisZ")
        local l = math.sqrt(f.x * f.x + f.z * f.z)
        if l > 0.001 then fx, fz = f.x / l, f.z / l end
    end) end
    return fx, fz
end
local function _delta()   -- universal = render + delta
    local up, rp = _pupos(), _ppos()
    if not (up and rp) then return nil end
    return { x = up.x - rp.x, y = up.y - rp.y, z = up.z - rp.z }
end
local function _try_pay(amount)
    -- the REAL wallet: app.ItemManager._Version ("_Golden" is Capcom's decoy)
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
local function _gold()
    local g
    pcall(function() g = tonumber(sdk.get_managed_singleton("app.ItemManager"):get_field("_Version")) end)
    return g
end

-- ── the native dialog (ui010101; the deed sign's hardened recipe) ────────────────────────
local DIALOG_GUITYPE = 14
local dlg = { open = false, baseline = nil, opened_at = 0 }
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
local function _show_dialog(prompt, opt1, opt2, phase)
    pcall(function()
        local gm = sdk.get_managed_singleton("app.GuiManager")
        local dialog = gm and gm:get_field("Dialog")
        if not dialog then return end
        gm:call("requestGuiType", DIALOG_GUITYPE)
        dialog:call("reqDisp", prompt, opt1, opt2, "", "",
            true, 0, true, 58, 0, -1, nil,
            false, false, false, false, false, false, true, 0.0)
        dlg.open = true
        dlg.opened_at = os.clock()
        dlg.baseline = _dialog_pick()
        dlg.phase = phase   -- nil = place; "sell" = sell confirm (dialog reader routes on it)
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
end

-- ── gimmick spawn machinery (the quarry/sign state machine + setInitialAngle) ────────────
local jobs = {}     -- { gid_name, x,y,z (universal), yaw, stage, f, on_go(go) }
local seq = 0
local _euler_quat   -- forward declaration: _apply_xform uses it before its body appears below
-- Only props proven to have an unwanted rigid-body rest pose belong here. Do NOT freeze every
-- furnishing: loose plates/buckets are meant to retain their native physical behaviour.
local POSE_LOCK = { gm50_007 = true, gm50_007_01 = true }   -- Broom variants
-- ⭐ NON-UNIFORM SCALE (Aurora: "horizontal vs vertical scale for gimmick scaling").
-- The spawn container carries only ONE `ScaleRate` float, so a stretched piece could never
-- survive a respawn through that route. `set_LocalScale` takes a full vector though — the
-- house kit's ground-reach already stretches wall pieces vertically that way — so we keep
-- three axes on the record and re-apply them to the live object on every spawn and adopt.
-- ⛔ Must be re-applied AFTER birth: late scale writes on a created prop silently no-op, but
-- on a spawned GIMMICK the transform write does stick (the ground-reach proves it).
local function _apply_xform(go, rec)
    if not (go and rec) then return end
    -- Brooms carry an .rbs rigid body. The preview is driven and therefore stays upright, but the
    -- real spawned piece enters simulation and tips over. Freeze that body first, then restore the
    -- exact WORLD quaternion recorded from the preview. This is the egg's already-proven physics
    -- freeze lever; it leaves every other furnishing untouched.
    if POSE_LOCK[tostring(rec.gid or "")] then
        pcall(function()
            local rb = go:call("getComponent(System.Type)", sdk.typeof("via.dynamics.RigidBodySet"))
            if rb then rb:call("set_Enabled", false) end
        end)
    end
    pcall(function()
        local eq = rec.q or _euler_quat(rec.yaw or 0, rec.pitch or 0, rec.roll or 0)
        if not eq then return end
        local tf = go:call("get_Transform")
        local q = tf:call("get_Rotation")
        q.x, q.y, q.z, q.w = eq.x, eq.y, eq.z, eq.w
        tf:call("set_Rotation", q)
    end)
    pcall(function()
        local u = tonumber(rec.scale) or 1.0
        local sx, sy, sz = tonumber(rec.sx) or u, tonumber(rec.sy) or u, tonumber(rec.sz) or u
        if sx == 1.0 and sy == 1.0 and sz == 1.0 then return end
        go:call("get_Transform"):call("set_LocalScale", Vector3f.new(sx, sy, sz))
    end)
end

-- pieces whose rotation must be re-written once they have settled (see the placement callback)
local _reassert = {}

_euler_quat = function(yaw, pitch, roll)   -- degrees; yaw(Y) * pitch(X) * roll(Z)
    -- (lives ABOVE the spawn machinery on purpose - the local-scope ordering law, 5th victim)
    local cy, sy = math.cos(math.rad(yaw) / 2), math.sin(math.rad(yaw) / 2)
    local cp, sp = math.cos(math.rad(pitch) / 2), math.sin(math.rad(pitch) / 2)
    local cr, sr = math.cos(math.rad(roll) / 2), math.sin(math.rad(roll) / 2)
    return {
        w = cy * cp * cr + sy * sp * sr,
        x = cy * sp * cr + sy * cp * sr,
        y = sy * cp * cr - cy * sp * sr,
        z = cy * cp * sr - sy * sp * cr,
    }
end
-- ══ ⭐⭐ CUSTOM MESHES, AURORA'S WAY: SKIN A CARRIER GIMMICK ═══════════════════════════
-- Aurora (08-08): "I thought we'd just put it over a gimmick like we do with the egg/
-- bassinet". She was right and my plan was worse. I was going to add a whole custom-mesh
-- ITEM TYPE, which meant touching the catalog, the ghost/drive mode, persistence, the
-- distance lifecycle AND sell - five places in the file her homestead lives in.
--
-- Instead: a real gimmick spawns as the CARRIER and we simply RETARGET ITS OWN RENDERER
-- to our mesh. The carrier keeps its transform, its collision, its lifecycle and its
-- record, so ghost/persist/lifecycle/sell/shop all work UNCHANGED and this is the only
-- edit in the file. The catalog entry stays an ordinary gid row; it just draws something
-- else. (Bonus: the plaque is solid rather than walk-through, for free.)
--
-- ⛔ RESOURCE-PATH LAW: create_resource on a path the engine cannot serve CRASHES the
--    engine - it is not a nil return. So only ever put a path in here that ships in the
--    IRIS pak, and warm it on a delay after load (never lazily at spawn: cold resources
--    lie, reporting MaterialNum>0 while drawing nothing - the farmland's bug).
-- ⛔ HOLDER-BIND: setMesh with a RAW resource silently no-ops. It must be wrapped in a
--    create_holder(...). And bind TWICE - a cold first bind renders nothing, which is
--    exactly the "takes 2 spawns to texture" the auditioner shows.
-- ⛔⛔ CARRIER CHOICE IS THE WHOLE GAME, AND THE FIRST PICK WAS WRONG (Aurora 08-09:
--   "I placed it on the wall and it fell down and through the wall"). A Crate is a
--   BREAKABLE: its prefab carries `.rbs` = rigid-body simulation, so the engine drops it.
-- ⭐ THE DISTINCTION TO CHECK, and it is readable offline from the .pfb strings:
--     `.rbs`  = rigid body physics  -> it FALLS. Never a wall carrier.
--     `.mcol` = STATIC collision    -> solid but immovable. Exactly what a wall prop wants.
--     an `*_interact_fsm.motfsm2`   -> the carrier owns a PROMPT you did not ask for.
--   Surveyed: gm81_141 Portrait (no collision, HAS interact fsm) · gm81_134 Scroll (no
--   collision, HAS a text interact) · gm81_075 Curtains (4x .mcol, NO .rbs, NO interact).
-- ⇒ Curtains is the clean one: wall-hung, statically collided, silent.
-- ⚠ COST: gm81_075 was the catalog's only "Curtains" row, and it is now the plaque. If
--   curtains are wanted back, find them a different carrier - do not hand this one back.
local SKIN = {
    -- carrier gimmick id -> our mesh basename (no extension, the egg's convention)
    ["gm81_075"] = "custom_tex/wallrack/wallrack",   -- Weapon Plaque (Curtains, reskinned)
}
local skinq, skinres = {}, { warmed = false, boot_at = nil }

local function _warm_skins()
    if skinres.warmed then return end
    skinres.warmed = true
    for _, base in pairs(SKIN) do
        pcall(function()
            local r = sdk.create_resource("via.render.MeshResource", base .. ".mesh")
            if r then skinres[#skinres + 1] = r:add_ref() end
            local m = sdk.create_resource("via.render.MeshMaterialResource", base .. ".mdf2")
            if m then skinres[#skinres + 1] = m:add_ref() end
        end)
    end
    _log("skin resources warmed")
end

re.on_frame(function()
    if skinres.warmed then return end
    if not skinres.boot_at then skinres.boot_at = os.clock() + 5.0; return end
    if os.clock() >= skinres.boot_at then pcall(_warm_skins) end
end)

-- every via.render.Mesh on the carrier or its children
local function _meshes_of(go, out, depth)
    out, depth = out or {}, depth or 3
    if depth <= 0 then return out end
    pcall(function()
        local c = go:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
        if c then out[#out + 1] = c end
        local tf = go:call("get_Transform")
        local ch = tf and tf:call("get_Child")
        local n = 0
        while ch and n < 24 do
            n = n + 1
            local cgo = nil
            pcall(function() cgo = ch:call("get_GameObject") end)
            if cgo then _meshes_of(cgo, out, depth - 1) end
            local nx = nil
            pcall(function() nx = ch:call("get_Next") end)
            ch = nx
        end
    end)
    return out
end

local function _skin_bind(go, base)
    local mcs = _meshes_of(go)
    if #mcs == 0 then _log("skin: carrier has no via.render.Mesh"); return false end
    -- the FIRST renderer becomes our plaque; any others are carrier parts we do not want
    local mc = mcs[1]
    for i = 2, #mcs do pcall(function() mcs[i]:call("set_Enabled", false) end) end
    local ok = false
    pcall(function()
        local res = sdk.create_resource("via.render.MeshResource", base .. ".mesh")
        if res then
            local hold = res:add_ref():create_holder("via.render.MeshResourceHolder"):add_ref()
            if not pcall(function() mc:call("setMesh", hold) end) then
                pcall(function() mc:call("set_Mesh", hold) end)
            end
            ok = true
        end
        local mt = sdk.create_resource("via.render.MeshMaterialResource", base .. ".mdf2")
        if mt then
            local mh = mt:add_ref():create_holder("via.render.MeshMaterialResourceHolder"):add_ref()
            if not pcall(function() mc:call("set_Material", mh) end) then
                pcall(function() mc:call("setMaterial", mh) end)
            end
        end
        pcall(function() mc:call("set_Enabled", true) end)
    end)
    return ok, mc
end

-- the CURE pass: re-bind ~1.2s later, because a cold first bind renders nothing
re.on_frame(function()
    if #skinq == 0 then return end
    local now = os.clock()
    for i = #skinq, 1, -1 do
        local s = skinq[i]
        if now >= s.at then
            local alive = false
            pcall(function() alive = s.go:call("get_Valid") == true end)
            if alive then
                _skin_bind(s.go, s.base)
                local mn = "?"
                pcall(function() mn = tostring(s.mc:call("get_MaterialNum")) end)
                _log("skin CURED " .. s.base .. " MaterialNum=" .. mn .. " (>0 = it took)")
            end
            table.remove(skinq, i)
        end
    end
end)

local function _queue_spawn(gid_name, ux, uy, uz, yaw, on_go, pitch, roll, scale)
    -- ⭐ wrap the caller's callback so all FOUR existing spawn sites (ghost, lifecycle,
    -- move-pickup, adopt) get skinning for free and none of them needed editing
    local base = SKIN[gid_name]
    if base then
        local inner = on_go
        on_go = function(go)
            if inner then pcall(inner, go) end
            _warm_skins()                      -- belt and braces if the boot warm hasn't run
            local ok, mc = _skin_bind(go, base)
            if ok then skinq[#skinq + 1] = { go = go, base = base, mc = mc, at = os.clock() + 1.2 } end
            _log("skin applied to carrier " .. gid_name .. " -> " .. base .. " (ok=" .. tostring(ok) .. ")")
        end
    end
    local gid
    pcall(function()
        -- gimmick_index keys are like "gm81_129"; the enum field is "Gm81_129"
        local fld = sdk.find_type_definition("app.GimmickID"):get_field(
            (gid_name:gsub("^gm", "Gm")))
        if fld then gid = fld:get_data() end
    end)
    if not gid then _log("no GimmickID enum for " .. gid_name); return false end
    jobs[#jobs + 1] = { gid = gid, name = gid_name, x = ux, y = uy, z = uz, yaw = yaw or 0,
        pitch = pitch or 0, roll = roll or 0, scale = scale, stage = "prefab", f = 0, on_go = on_go }
    return true
end
local function _pump_jobs()
    for i = #jobs, 1, -1 do
        local q = jobs[i]
        local drop = false
        if q.stage == "prefab" then
            local ok = pcall(function()
                local prefab = sdk.create_instance("via.Prefab"):add_ref()
                prefab:set_Path((M.paths and M.paths[q.name]) or ("AppSystem/gimmick/prefab/" .. q.name .. ".pfb"))
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
                -- setInitialAngle ONLY (the invisible-sign bisect: context/raw-field writes
                -- poison); FULL euler now - placed furniture keeps its pitch/roll across respawns
                pcall(function()
                    local eq = _euler_quat(q.yaw or 0, q.pitch or 0, q.roll or 0)
                    local rqt = ValueType.new(sdk.find_type_definition("via.Quaternion"))
                    rqt.x, rqt.y, rqt.z, rqt.w = eq.x, eq.y, eq.z, eq.w
                    container._CommonInfo:setInitialAngle(rqt)
                end)
                pcall(function() container._StatusInfo["<ScaleRate>k__BackingField"] = q.scale or 1.0 end)
                q.prefab, q.ctrl, q.inst = prefab, ctrl, inst
                q.container = container
            end)
            if ok and q.prefab then q.stage = "wait"; q.f = 0 else drop = true end
        elseif q.stage == "wait" then
            q.f = q.f + 1
            local ready = false
            pcall(function() ready = q.prefab:get_Ready() == true end)
            if ready then
                seq = seq + 1
                local okr = pcall(function()
                    local gen = sdk.get_managed_singleton("app.GenerateManager")
                    gen:call("requestCreateInstance(app.PrefabController, app.GenerateInfo.GenerateInfoContainer, System.Int32, app.InstanceInfo, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>)",
                        q.ctrl, q.container, 742000 + seq, q.inst, nil, nil)
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
                if q.on_go then pcall(q.on_go, go) end
                drop = true
            elseif q.f > 1500 then
                _log("spawn TIMED OUT (instantiate never returned a GO): " .. tostring(q.name))
                drop = true
            end
        end
        if drop then table.remove(jobs, i) end
    end
end

-- ══ v2: THE SHOP SCREEN + GHOST DRIVING (Aurora: "onscreen UI like our character
-- customizer... you take control of the item... position the ghost... confirm, are you
-- sure, purchase" + "pitch/yaw/roll as well"). Patterns lifted from IrisCustomize:
-- pad enum via via.hid.GamePadButton, get_MergedDevice axes, edge/repeat keys, d2d panel
-- in the same palette, IrisFont shared faces. No world pause (the requestPause dragon
-- stays sleeping): browse + drive = player FSM OFF, restored on every exit path.
local PAD = { names = {}, dpad = {}, face = {}, prev = 0 }
pcall(function()
    local t = sdk.find_type_definition("via.hid.GamePadButton")
    for _, f in ipairs(t:get_fields()) do
        pcall(function() PAD.names[f:get_name()] = f:get_data() end)
    end
    local function pick(...) for _, n in ipairs({ ... }) do if PAD.names[n] then return PAD.names[n] end end return 0 end
    PAD.dpad.up = pick("LUp", "Up", "DUp", "PadUp")
    PAD.dpad.down = pick("LDown", "Down", "DDown", "PadDown")
    PAD.dpad.left = pick("LLeft", "Left", "DLeft", "PadLeft")
    PAD.dpad.right = pick("LRight", "Right", "DRight", "PadRight")
    PAD.face.a = pick("Decide", "A", "RDown")
    PAD.face.b = pick("Cancel", "B", "RRight")
    PAD.face.x = pick("Action", "X", "RLeft")
    PAD.face.y = pick("Special", "Y", "RUp", "Triangle")
    PAD.lb = pick("LTrigTop", "L1", "LB", "LShoulder")
    PAD.rb = pick("RTrigTop", "R1", "RB", "RShoulder")
    PAD.lt = pick("LTrigBottom", "L2", "LT", "ZL")
    PAD.rt = pick("RTrigBottom", "R2", "RT", "ZR")
    -- ⭐ R3 = the right stick PRESS. Resolved through the same `pick` ladder as everything else,
    --   so a name that does not exist in via.hid.GamePadButton cannot masquerade as one that does
    --   (the trap IrisFarming documents: "B"/"Circle" are not fields, so lookups slid to RDown).
    PAD.r3 = pick("RStickPush", "R3", "RThumb", "RStick", "RSPush")
    -- name inventory to the log ONCE: if any button is dead on Aurora's pad, the real names live here
    local names = {}
    for n in pairs(PAD.names) do names[#names + 1] = n end
    table.sort(names)
    pcall(function()
        local f = io.open("IRIS/furnish_log.txt", "a")
        if f then f:write("[pad] GamePadButton names: " .. table.concat(names, " ") .. "\n"); f:close() end
    end)
end)
local function _pad_dev()
    local d
    pcall(function()
        local s = sdk.get_native_singleton("via.hid.GamePad")
        local t = sdk.find_type_definition("via.hid.GamePad")
        d = sdk.call_native_func(s, t, "get_MergedDevice")
    end)
    return d
end
local function _pad_button() local v = 0; local d = _pad_dev(); if d then pcall(function() v = d:call("get_Button") or 0 end) end return math.floor(v) end
local function _pad_axis_l() local x, y = 0, 0; local d = _pad_dev(); if d then pcall(function() local a = d:call("get_AxisL"); if a then x = a.x or 0; y = a.y or 0 end end) end return x, y end

local UI = { open = false, row = 1, cat_i = 1, keys = {}, rep = {}, paused = false,
    preview_want = nil, preview_at = 0 }
M.ui_key = 0x6A   -- '*' numpad multiply (Aurora: function keys are RiftSpeak's); editable in panel
M.place_radius = 25.0   -- ⭐ decor can't be dragged further than this (m) from the plot centre (Aurora: no placing it out in the world)
M.warn_radius = 70.0    -- outside decorate range but within this band -> "too far" warning; beyond = stay silent (Aurora)
local PAUSE_SIG = "requestPause(System.Boolean, app.PauseManager.PauseType, System.String, System.Action)"
local function _pause_value()
    if UI.pause_val then return UI.pause_val end
    local list, sel = {}, 1
    pcall(function()
        local td = sdk.find_type_definition("app.PauseManager.PauseType")
        for _, f in ipairs(td:get_fields()) do
            if f:is_static() then
                local v; pcall(function() v = f:get_data() end)
                if v == nil then pcall(function() v = f:get_data(nil) end) end
                if v ~= nil then list[#list + 1] = { name = f:get_name(), value = v } end
            end
        end
    end)
    local function pp(pred) for i, e in ipairs(list) do if pred(e) then sel = i; return true end end return false end
    local _ = pp(function(e) local l = e.name:lower(); return l:find("debug") and l:find("cam") end)
        or pp(function(e) return e.name:lower():find("debug") end)
        or pp(function(e) return e.value == 1 end)
    UI.pause_val = (list[sel] and list[sel].value) or 1
    return UI.pause_val
end
local function _world_pause(on)
    pcall(function()
        local pm = sdk.get_managed_singleton("app.PauseManager"); if not pm then return end
        if on and not UI.paused then
            UI.paused_type = _pause_value()
            pm:call(PAUSE_SIG, true, UI.paused_type, "IrisFurnish", nil); UI.paused = true
        elseif (not on) and UI.paused then
            pm:call(PAUSE_SIG, false, UI.paused_type or _pause_value(), "IrisFurnish", nil)
            UI.paused = false; UI.paused_type = nil
        end
    end)
end
local function _pad_axis_r() local x, y = 0, 0; local d = _pad_dev(); if d then pcall(function() local a = d:call("get_AxisR"); if a then x = a.x or 0; y = a.y or 0 end end) end return x, y end
local function _kb(vk)
    -- ⛔ 08-09: this used to fall through to a RAW read whenever iris_kb returned false,
    -- which silently DEFEATED the typing guard -- iris_kb says "you're typing, no key",
    -- and the next line went and read the key anyway. The raw path is now only for
    -- iris_kb being absent entirely, and it still honours the gate.
    local d = false
    if type(iris_kb) == "function" then
        pcall(function() d = iris_kb(vk) == true end)                  -- shared helper (input gate/taming/griffin)
        return d
    end
    if type(iris_input_blocked) == "function" and iris_input_blocked() then return false end
    pcall(function() d = reframework:is_key_down(vk) == true end)
    return d
end
local function _edge(vk)
    local d = _kb(vk)
    local was = UI.keys[vk] == true
    UI.keys[vk] = d
    return d and not was
end
local function _rep(vk, name)
    if not _kb(vk) then UI.rep[name] = nil; return false end
    local now = os.clock(); local st = UI.rep[name]
    if not st then UI.rep[name] = { first = now, last = now }; return true end
    if now - st.first < 0.30 then return false end
    if now - st.last > 0.06 then st.last = now; return true end
    return false
end
local function _fsm_enabled(on)
    pcall(function()
        local h = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer"):call("get_Human")
        if h and h.Fsm then h.Fsm:set_Enabled(on) end
    end)
end
local function _cam_fwd()
    local fx, fz = 0, 1
    pcall(function()
        local f = sdk.get_primary_camera():call("get_GameObject"):call("get_Transform"):call("get_AxisZ")
        local l = math.sqrt(f.x * f.x + f.z * f.z)
        if l > 0.001 then fx, fz = f.x / l, f.z / l end
    end)
    return fx, fz
end

-- ── furniture is INVINCIBLE (Aurora 07-24: "I just destroyed the windows I bought xD") ──
-- breakable-family gimmicks ship live HP; your property must not die to a stray swing.
-- setNoDamage-style switches live on the gimmick component - try every safe spelling.
-- set a field ONLY if the type actually declares it - set_field on a missing name throws a
-- logged REFramework error even inside pcall (Aurora's "invalid REManagedObject field" spam)
local function _set_if(obj, name, val)
    pcall(function()
        local td = obj:get_type_definition()
        if td and td:get_field(name) then obj:set_field(name, val) end
    end)
end
local function _call_if(obj, sig, ...)
    local args = { ... }
    pcall(function()
        local td = obj:get_type_definition()
        local base = sig:match("^([^(]+)")
        if td and (td:get_method(sig) or td:get_method(base)) then obj:call(sig, table.unpack(args)) end
    end)
end
-- one-time: dump HitController's damage/invincible-ish fields+methods so we name the REAL
-- armor switch (Aurora: literal "IsInvincible" is invalid - find what actually exists)
local _hc_dumped = false
local function _dump_hitctrl(go)
    if _hc_dumped then return end
    _hc_dumped = true
    pcall(function()
        local hc = go:call("getComponent(System.Type)", sdk.typeof("app.HitController"))
        local td = hc and hc:get_type_definition()
        if not td then _log("HitController: none on this piece"); return end
        local want = { "invin", "damage", "dmg", "nodamage", "dead", "hp", "break", "guard" }
        local function match(s) s = s:lower(); for _, w in ipairs(want) do if s:find(w) then return true end end return false end
        local fs, ms = {}, {}
        pcall(function() for _, f in ipairs(td:get_fields()) do if match(f:get_name()) then fs[#fs+1] = f:get_name() end end end)
        pcall(function() for _, m in ipairs(td:get_methods()) do if match(m:get_name()) then ms[#ms+1] = m:get_name() end end end)
        _log("HitController fields: " .. table.concat(fs, " "))
        _log("HitController methods: " .. table.concat(ms, " "))
    end)
end
local function _protect(go)
    _dump_hitctrl(go)
    pcall(function()
        local arr = go:call("get_Components")
        for i = 0, (arr:get_size() or 1) - 1 do
            pcall(function()
                local c = arr:get_element(i)
                -- Do not invoke GimmickBase.setNoDamage here. On the current
                -- DD2 build the reflected method exists, but calling it from
                -- Lua enters an invalid native target (the 16:30 run produced
                -- a c0000005 every time). The guarded fields below and the
                -- HitController switch provide protection without that call.
                _set_if(c, "<NoDamage>k__BackingField", true)
                _set_if(c, "_NoDamage", true)
            end)
        end
    end)
    -- ⭐ HitController.IsInvincible (Aurora's find 07-24): the direct armor switch, guarded
    pcall(function()
        local hc = go:call("getComponent(System.Type)", sdk.typeof("app.HitController"))
        if hc then
            _set_if(hc, "IsInvincible", true)
            _set_if(hc, "<IsInvincible>k__BackingField", true)
            _call_if(hc, "set_IsInvincible(System.Boolean)", true)
        end
    end)
end

-- ── the GHOST (Ark-style carry: floats ahead, you walk it into place) ────────────────────
local ghost = nil   -- { entry, go, dist, h, yaw, pending, frozen }
local function _drop_ghost(destroy)
    -- a MOVE that never got re-placed must NOT vanish the piece (Aurora: "sold a bed without
    -- a confirmation" = the A-move pickup lost the record on cancel). Restore it.
    if ghost and ghost.moving_rec and not ghost.placed_done then
        placed[#placed + 1] = ghost.moving_rec
        pcall(_save_placed)
        _log("move cancelled -> restored " .. tostring(ghost.moving_rec.label))
    end
    if ghost and ghost.go and destroy then pcall(function() ghost.go:call("destroy", ghost.go) end) end
    ghost = nil
end
local function _start_ghost(entry, drive)
    if dlg.open then return end
    _drop_ghost(true)
    local up = _pupos()
    if not up then M.last = "no player"; return end
    local fx, fz = _pfwd()
    ghost = { entry = entry, dist = 3.5, h = 0.0, yaw = 0.0, pitch = 0.0, roll = 0.0,
        pending = true, drive = drive or nil }
    _log("ghost requested: " .. entry.gid .. " '" .. entry.label .. "'" .. (drive and " (drive)" or ""))
    local ok = _queue_spawn(entry.gid, up.x + fx * 3.5, up.y, up.z + fz * 3.5, 0,
        function(go)
            if ghost and ghost.pending then
                ghost.go = go; ghost.pending = nil
                _protect(go)   -- your property does not die to a stray swing
                local p; pcall(function() p = go:call("get_Transform"):call("get_Position") end)
                if p then ghost.px, ghost.py, ghost.pz = p.x, p.y, p.z end   -- drive starts here
                _log(string.format("ghost UP: %s at render(%.1f,%.1f,%.1f)", entry.gid,
                    p and p.x or -1, p and p.y or -1, p and p.z or -1))
            else
                -- ⛔⛔ THE ORPHAN BUG (Aurora 08-09: "it can spawn a gimmick you didn't buy and
                --   you can't remove it because it doesn't go into placed"). The preview spawn
                --   is ASYNCHRONOUS. If the selection moves on, or the menu closes, before the
                --   job lands, `ghost` is already nil or a different ghost — and v1 just let
                --   this callback fall through, LEAKING the GameObject. Alive in the world,
                --   referenced by nothing, in no list, impossible to remove.
                -- ⇒ if we cannot adopt it, DESTROY it. An un-adoptable spawn is litter.
                pcall(function() go:call("destroy", go) end)
                _log("ghost arrived too late to adopt (" .. tostring(entry.gid)
                     .. ") - destroyed it instead of leaking it")
            end
        end)
    if not ok then ghost = nil; M.last = "no spawnable gimmick id for " .. entry.gid; return end
    M.last = drive and (entry.label .. ": WASD/stick move, Z/X height, Q/E yaw, R/F pitch, T/G roll, Enter place, Esc cancel")
        or ("ghosting " .. entry.label .. " - walk it into place, then PLACE")
end

-- categories + the PLACED management pseudo-category (Aurora v3 note 5)
local function _all_cats()
    local t = {}
    for _, c in ipairs(cats) do t[#t + 1] = c end
    t[#t + 1] = "PLACED"
    return t
end
-- the current category's rows (shared by the input tick and the screen draw)
local function _rows_for_cat()
    local ac = _all_cats()
    if UI.cat_i > #ac then UI.cat_i = 1 end
    local want = ac[UI.cat_i] or "ALL"
    local rows = {}
    if want == "PLACED" then
        -- ⭐ DISTANCE PER ROW (Aurora 08-09: "might help people know which placed prop is
        --   which"). With eleven rows all called "Chair", the price tells you nothing — how
        --   far away it is tells you everything. Sorted nearest-first for the same reason.
        local up = _pupos()
        for i, rec in ipairs(placed or {}) do
            local d = nil
            if up and rec.ux then
                local dx, dy, dz = rec.ux - up.x, (rec.uy or up.y) - up.y, rec.uz - up.z
                d = math.sqrt(dx * dx + dy * dy + dz * dz)
            end
            rows[#rows + 1] = { placed_i = i, gid = rec.gid, label = rec.label,
                category = "placed", price = rec.price or 0, dist = d }
        end
        table.sort(rows, function(a, b) return (a.dist or 1e9) < (b.dist or 1e9) end)
    else
        for _, e in ipairs(catalog or {}) do
            if want == "ALL" or e.category == want then rows[#rows + 1] = e end
        end
    end
    UI.rows = rows
    return rows
end
local function _cam(fn, ...)
    local a = { ... }
    pcall(function() if _G.IrisCreatureCam and _G.IrisCreatureCam[fn] then _G.IrisCreatureCam[fn](table.unpack(a)) end end)
end
local function _close_shop()
    UI.open = false; _G.IrisFurnishUIOpen = false
    UI.preview_want = nil
    if ghost and not ghost.frozen then _drop_ghost(true) end   -- unbought preview dies with the menu
    _cam("clear_target"); _cam("set_on", false)
    _world_pause(false)
    _fsm_enabled(true)
    M.last = "shop closed"
end
local function _open_shop()
    _load_data()
    -- gate: decorating happens AT a BUILT homestead (owned + built plot within 35m).
    -- Track the NEAREST built plot too: it anchors the placement-range clamp AND the
    -- two-tier "too far" message (Aurora 07-24: silent when nowhere near, warn only when close).
    local ok_here, nearest2, anchor = false, nil, nil
    pcall(function()
        local up = _pupos()
        if not up then return end
        for _, pr in ipairs(_G.IrisHomesteadPlots.list()) do
            if pr.owned ~= false and pr.built ~= false then
                local dx, dz = (pr.ux or 0) - up.x, (pr.uz or 0) - up.z
                local dd = dx * dx + dz * dz
                if not nearest2 or dd < nearest2 then nearest2 = dd; anchor = { ux = pr.ux, uz = pr.uz } end
                if dd < 35.0 ^ 2 then ok_here = true end
            end
        end
    end)
    if not ok_here then
        UI.anchor = nil
        local warn2 = (tonumber(M.warn_radius) or 70.0) ^ 2
        if nearest2 and nearest2 < warn2 then
            -- close to home but not IN range: warn, and hold it long enough to actually read (Aurora)
            UI.warn_until = os.clock() + 4.5
            M.last = "too far to decorate - move closer to your house"
        else
            -- nowhere near a homestead: say nothing at all (Aurora: no nag out in the open world)
            M.last = "decorate hotkey (not near a homestead - silent)"
        end
        return
    end
    UI.anchor = anchor          -- the plot you're standing at: clamps how far decor can roam
    UI.open = true;  _G.IrisFurnishUIOpen = true
    UI.last_sel = nil           -- forces the auto-preview of the current row
    UI.warn_until = nil
    _fsm_enabled(false)
    _world_pause(true)
    M.last = "decorating - the world holds its breath"
end

-- ── placed furniture lifecycle (auto spawn/despawn by proximity; adopt-don't-duplicate) ──
local live = {}       -- [placed index] = go
local lc = { at = 0 } -- lifecycle throttle
local function _adopt_near(ux, uz, d, gid)
    -- a gimmick standing within 1.2m of the record = a script-reset survivor: re-own it.
    -- ⛔ IDENTITY CHECK ADDED 08-04 (Aurora: "it says I have 2 cookpots but they're not appearing
    -- when I reload"). Adoption used to take ANY gimmick in radius - in a furnished corner a
    -- cookpot record adopted a NEIGHBOURING piece, marked itself live, and its real gimmick never
    -- spawned. The record's gid must now appear in the candidate's GameObject name; a survivor
    -- whose name doesn't carry it is left alone and the piece respawns properly instead.
    local found, wrong
    pcall(function()
        local rp = _ppos()
        if not (d and rp) then return end
        local prx, prz = ux - d.x, uz - d.z
        local want = tostring(gid or ""):lower()
        local smgr = sdk.get_native_singleton("via.SceneManager")
        local scene = smgr and sdk.call_native_func(smgr, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        local arr = scene and scene:call("findComponents(System.Type)", sdk.typeof("app.GimmickBase"))
        local n = arr and arr:get_size() or 0
        for i = 0, (tonumber(n) or 0) - 1 do
            if found then break end
            pcall(function()
                local c = arr:get_element(i)
                local go = c:call("get_GameObject")
                local p = go:call("get_Transform"):call("get_Position")
                local dx, dz = p.x - prx, p.z - prz
                if dx * dx + dz * dz < 1.44 then
                    local nm = tostring(go:call("get_Name") or ""):lower()
                    if want == "" or nm:find(want, 1, true) then
                        found = go:add_ref()
                    else
                        wrong = nm   -- remember one mismatch for the log
                    end
                end
            end)
        end
    end)
    if not found and wrong then
        _log("adopt: skipped '" .. wrong .. "' near a " .. tostring(gid) .. " record (wrong kind) - spawning fresh")
    end
    return found
end

-- destroy EVERY gimmick standing near a record's spot - not just the tracked live ref
-- (Aurora 07-24: sold a dressing screen, it didn't disappear. Cause = duplicate/adopted
-- copy the live[] index never tracked. Kill by POSITION, tracked or not.)
local function _destroy_at(ux, uz, d, radius)
    local killed = 0
    pcall(function()
        local rp = _ppos()
        if not (d and rp) then return end
        local prx, prz = ux - d.x, uz - d.z
        local r2 = (radius or 2.0) ^ 2
        local smgr = sdk.get_native_singleton("via.SceneManager")
        local scene = smgr and sdk.call_native_func(smgr, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        local arr = scene and scene:call("findComponents(System.Type)", sdk.typeof("app.GimmickBase"))
        local n = arr and arr:get_size() or 0
        local kill = {}
        for i = 0, (tonumber(n) or 0) - 1 do
            pcall(function()
                local c = arr:get_element(i)
                local go = c:call("get_GameObject")
                local p = go:call("get_Transform"):call("get_Position")
                local dx, dz = p.x - prx, p.z - prz
                if dx * dx + dz * dz < r2 then kill[#kill + 1] = go end
            end)
        end
        for _, go in ipairs(kill) do
            pcall(function() go:call("destroy", go); killed = killed + 1 end)
        end
    end)
    return killed
end

-- ── pumps ────────────────────────────────────────────────────────────────────────────────
re.on_application_entry("UpdateBehavior", function()
    -- confirm dialog reader FIRST and UNGUARDED (our own dialog pauses the world; a
    -- pause-guarded reader = softlock - the deed sign's law)
    if dlg.open then
        local p = _dialog_pick()
        if p ~= nil and p ~= dlg.baseline then dlg.baseline = p else p = nil end
        if p ~= nil and os.clock() - dlg.opened_at < 0.25 then p = nil end
        if p == nil and os.clock() - dlg.opened_at > 30.0 then _close_dialog(); dlg.phase = nil; return end
        -- SELL confirm (Aurora: "we need a confirmation for selling too")
        if dlg.phase == "sell" then
            if p == 1 then          -- Sel0 = Sell it
                _close_dialog()
                local rec = dlg.sell_rec
                dlg.sell_rec, dlg.phase = nil, nil
                if rec then
                    -- kill EVERY copy at the spot (tracked, adopted, or duplicate)
                    _destroy_at(rec.ux, rec.uz, _delta(), 2.0)
                    for i = #placed, 1, -1 do if placed[i] == rec then table.remove(placed, i) end end
                    for k in pairs(live) do live[k] = nil end   -- indexes shifted; re-adopt
                    _save_placed()
                    pcall(function()
                        local im = sdk.get_managed_singleton("app.ItemManager")
                        local curg = tonumber(im:get_field("_Version"))
                        if curg then im:set_field("_Version", curg + math.floor((rec.price or 0) / 2)) end
                    end)
                    M.last = "sold " .. tostring(rec.label) .. " (+" .. math.floor((rec.price or 0) / 2) .. " G)"
                end
            elseif p == 2 or p == 5 then   -- Keep it / Cancel
                _close_dialog(); dlg.sell_rec, dlg.phase = nil, nil
            end
            return
        end
        if p == 1 then          -- Sel0 = Place it
            _close_dialog()
            if ghost and ghost.go and ghost.frozen then
                local paid = true
                if not ghost.repick then paid = _try_pay(ghost.entry.price) end   -- moving = free
                if paid == "poor" then
                    M.last = "not enough gold (" .. ghost.entry.price .. " G)"
                    ghost.frozen = nil   -- back to carrying
                    return
                end
                local d = _delta()
                local gp
                pcall(function() gp = ghost.go:call("get_Transform"):call("get_Position") end)
                if d and gp then
                    local rec = {
                        plot = "loose", gid = ghost.entry.gid, label = ghost.entry.label,
                        price = ghost.entry.price,
                        ux = gp.x + d.x, uy = gp.y + d.y, uz = gp.z + d.z,
                        yaw = ghost.yaw or ghost.wyaw or 0,
                        pitch = ghost.pitch or 0, roll = ghost.roll or 0,
                        scale = ghost.scale or 1.0,
                    }
                    -- ⛔⛔ TAKE THE GHOST'S ACTUAL ROTATION, NOT JUST THE EULER WE TYPED IN
                    --   (Aurora 08-10: "if you place an item in decorate when it spawns in, it'll
                    --   be at a different angle to how you placed it"). The ghost is posed with
                    --   set_Rotation (a WORLD rotation); the spawn feeds the same euler to
                    --   setInitialAngle, which the generator does not interpret identically — so
                    --   a broom stood upright in the preview came back leaning.
                    --   Recording the ghost's real quaternion means _apply_xform can restore
                    --   exactly what was previewed, whatever the generator did on the way in.
                    pcall(function()
                        local gq = ghost.go:call("get_Transform"):call("get_Rotation")
                        if gq then
                            rec.q = { x = gq.x, y = gq.y, z = gq.z, w = gq.w }
                            -- ⛔ MEASURE, DO NOT THEORISE. Two attempts at this failed on a guess
                            --   (setInitialAngle mismatch, then cold-bind restomp). Log the
                            --   GHOST's quaternion here and the PIECE's quaternion after it
                            --   settles; if they match, the rotation is right and the mesh's own
                            --   rest pose is the difference, which is a different fix entirely.
                            _log(string.format("PLACE ghost q=(%.3f,%.3f,%.3f,%.3f) euler y=%.1f p=%.1f r=%.1f",
                                gq.x, gq.y, gq.z, gq.w, rec.yaw or 0, rec.pitch or 0, rec.roll or 0))
                        end
                    end)
                    -- attach to the nearest saved plot when one is close (the homestead bridge)
                    pcall(function()
                        local best, bd
                        for _, pr in ipairs(_G.IrisHomesteadPlots.list()) do
                            local dx, dz = (pr.ux or 0) - rec.ux, (pr.uz or 0) - rec.uz
                            local dd = dx * dx + dz * dz
                            if (not bd or dd < bd) and dd < 3600.0 then bd = dd; best = pr end
                        end
                        if best then rec.plot = best.name end
                    end)
                    placed[#placed + 1] = rec
                    _save_placed()
                    -- ⛔ THE GHOST NO LONGER BECOMES THE FURNITURE (Aurora 08-05: "when it spawns
                    -- it's not solid - but if I reload it becomes solid"). A DRIVEN gimmick's
                    -- static collision stays where it SPAWNED (3.5m in front of wherever the
                    -- ghost was requested); walking the ghost into place moves only the render.
                    -- The reload path spawns fresh AT the saved spot - which is why reloading
                    -- fixed it. So placing now does exactly what reloading does: the ghost dies
                    -- and a real piece spawns at the final coordinates, collision and all.
                    local gidx = #placed
                    pcall(function() ghost.go:call("destroy", ghost.go) end)
                    _queue_spawn(rec.gid, rec.ux, rec.uy, rec.uz, rec.yaw,
                        function(go)
                            _protect(go); _apply_xform(go, rec); live[gidx] = go
                            -- ⛔ ONE WRITE IS NOT ENOUGH. _apply_xform lands at spawn-complete,
                            --   but the piece then finishes its cold bind and re-settles onto the
                            --   angle the generator gave it via setInitialAngle — which is why
                            --   the broom stood upright in the preview and leaned once placed.
                            --   Same shape as the double-bind law the mesh/prop work already
                            --   follows: write, let it settle, write again.
                            _reassert[#_reassert + 1] = { go = go, rec = rec, at = os.clock() }
                        end, rec.pitch, rec.roll, rec.scale)
                    _log(string.format("PLACED %s (%s) at (%.1f,%.1f,%.1f) plot=%s -%dG",
                        rec.label, rec.gid, rec.ux, rec.uy, rec.uz, rec.plot, rec.price))
                    M.last = rec.label .. " placed" ..
                        (ghost.repick and " (moved, no charge)" or (" (-" .. rec.price .. " G)"))
                    local in_menu = ghost.menu
                    ghost.go = nil
                    ghost.placed_done = true   -- a move that COMPLETED: don't restore the old rec
                    _drop_ghost(false)
                    if in_menu then
                        UI.last_sel = nil   -- menu stays open (Aurora v3 note 4): re-preview
                                            -- the row -> place ANOTHER copy, or browse on
                    else
                        _fsm_enabled(true)  -- v1 dev-carry path: give the player back
                    end
                end
            end
        elseif p == 2 or p == 5 then   -- Not yet / Cancel
            _close_dialog()
            if ghost then ghost.frozen = nil end   -- keep carrying
        end
        return
    end

    -- ⛔ PAUSE GUARD (the frame-gen crash law): no spawning/moving while the world is paused
    local paused = false
    pcall(function()
        local pm = sdk.get_managed_singleton("app.PauseManager")
        if pm and pm:call("isPausedAny") == true then paused = true end
    end)
    -- our own world-pause must NOT freeze the decorator (game-menu pause still does)
    if paused and not UI.paused then return end

    -- ── the DECORATOR (v3: paused menu, live preview, place many, manage placed) ─────────
    if _edge(tonumber(M.ui_key) or 0x6A) then
        if UI.open then _close_shop() else _open_shop() end
    end
    local cur = _pad_button()
    local gdown = cur & (~(PAD.prev or 0)); PAD.prev = cur
    local function ghit(b) return b ~= 0 and (gdown & b) == b end
    local function gheld(b) return b ~= 0 and (cur & b) == b end
    local a_hit = _edge(0x0D) or ghit(PAD.face.a)                 -- Enter / A
    local b_hit = _edge(0x1B) or _edge(0x08) or ghit(PAD.face.b)  -- Esc / Backspace / B

    _pump_jobs()   -- runs under OUR pause too (preview spawns; one-at-a-time, gentle)

    -- ⛔⛔ THE PRECISE EDITOR APPLIES **HERE**, NOT IN THE PANEL (Aurora: "the sliders aren't
    -- actually affecting"). Transform writes must happen on the game thread — postpatch law
    -- #11, "never on_frame/on_draw_ui" — so a set_Position issued from inside the imgui draw
    -- silently does nothing. The panel only edits the RECORD; this tick pushes the record onto
    -- the live object every frame while the overlay is open, so dragging a slider reads as
    -- live movement.
    if M.edit_i and placed[M.edit_i] then
        local rec, go = placed[M.edit_i], live[M.edit_i]
        if go and M.edit_base then
            rec.ux = M.edit_base.x + (M.edit_dx or 0)
            rec.uy = M.edit_base.y + (M.edit_dy or 0)
            rec.uz = M.edit_base.z + (M.edit_dz or 0)
            local d = _delta()
            pcall(function()
                local tf = go:call("get_Transform")
                if d then
                    tf:call("set_Position", Vector3f.new(rec.ux - d.x, rec.uy - d.y, rec.uz - d.z))
                end
                -- ⭐ the exact quaternion the ghost had, when we have it; the euler is the
                --   fallback for pieces placed before rec.q existed
                local eq = rec.q or _euler_quat(rec.yaw or 0, rec.pitch or 0, rec.roll or 0)
                local q = tf:call("get_Rotation")
                q.x, q.y, q.z, q.w = eq.x, eq.y, eq.z, eq.w
                tf:call("set_Rotation", q)
            end)
            _apply_xform(go, rec)
        end
    end

    if UI.open then
        local rows = _rows_for_cat()
        local ac = _all_cats()
        local in_placed = ac[UI.cat_i] == "PLACED"
        -- navigation
        local up = _rep(0x26, "u")
        local dn = _rep(0x28, "d")
        -- ⭐ arrow keys drive the tabs too (Aurora 2026-08-08): up/down already browsed rows,
        -- but changing category was [ / ] only, which nobody guesses. Left/Right are the
        -- obvious keyboard mirror of LB/RB and cost nothing to accept alongside the brackets.
        local cat_l = _edge(0xDB) or _edge(0x25) or ghit(PAD.lb)   -- [ / Left / LB
        local cat_r = _edge(0xDD) or _edge(0x27) or ghit(PAD.rb)   -- ] / Right / RB
        -- ── LOCK-IN two-stage flow (Aurora: "I've pressed the wrong button and lost the
        -- item a few too many times"): BROWSING = nav lives, steering dead. A locks the
        -- piece IN: nav dead, steering lives. A again places; B unlocks back to browsing.
        local locked = ghost and ghost.locked and ghost.go
        local xmod = gheld(PAD.face.x)
        if not locked then
            local gdir = nil
            if not xmod then
                if gheld(PAD.dpad.up) then gdir = "up" elseif gheld(PAD.dpad.down) then gdir = "down" end
            end
            local now = os.clock()
            if gdir ~= UI.gheld then UI.gheld = gdir; UI.gheld_at = now; UI.grep_at = now
                if gdir == "up" then up = true elseif gdir == "down" then dn = true end
            elseif gdir and now - (UI.gheld_at or 0) > 0.3 and now - (UI.grep_at or 0) > 0.07 then
                UI.grep_at = now
                if gdir == "up" then up = true elseif gdir == "down" then dn = true end
            end
            if cat_l then UI.cat_i = ((UI.cat_i - 2) % #ac) + 1; UI.row = 1; UI.last_sel = nil end
            if cat_r then UI.cat_i = (UI.cat_i % #ac) + 1; UI.row = 1; UI.last_sel = nil end
            if up and #rows > 0 then UI.row = ((UI.row - 2) % #rows) + 1 end
            if dn and #rows > 0 then UI.row = (UI.row % #rows) + 1 end
        end
        if b_hit and not dlg.open then
            if locked then
                ghost.locked = nil   -- unlock: back to browsing, the preview survives
                M.last = "unlocked - browse again, A locks the piece in"
                return
            end
            _close_shop(); return
        end

        -- AUTO-PREVIEW (settle 0.45s on a selection): the selected item stands before you.
        -- ⛔ NEVER while a piece is being POSITIONED (locked), MOVED (repick), or awaiting the
        -- place dialog (frozen): the pickup->move flow flips to cat ALL while the moved ghost is
        -- still spawning, and an unguarded auto-preview clobbers it with a fresh ALL item -- that
        -- was the "press A on a placed piece -> bounces to ALL, you lose control" bug (Aurora 07-24).
        local sel_key = tostring(UI.cat_i) .. ":" .. tostring(UI.row)
        local busy_ghost = ghost and (ghost.locked or ghost.repick or ghost.frozen)
        if not in_placed and not busy_ghost then
            if sel_key ~= UI.last_sel then
                UI.last_sel = sel_key
                UI.preview_want = { e = rows[UI.row], at = os.clock() + 0.45 }
            end
            if UI.preview_want and os.clock() >= UI.preview_want.at then
                local e = UI.preview_want.e
                UI.preview_want = nil
                if e and not (ghost and ghost.frozen) then
                    _start_ghost(e, true)
                    if ghost then ghost.menu = true end
                end
            end
        end

        -- PLACED management: A picks the piece UP (move it, re-place free), Del/X sells half
        if in_placed and rows[UI.row] then
            local pr = rows[UI.row]
            if a_hit and placed[pr.placed_i] then
                local rec = table.remove(placed, pr.placed_i)
                _save_placed()
                -- kill EVERY standing copy at the spot (tracked or not), then spawn ONE fresh
                -- ghost to move - guarantees no duplicate left behind (the sell-didn't-vanish bug)
                _destroy_at(rec.ux, rec.uz, _delta(), 2.0)
                for k in pairs(live) do live[k] = nil end   -- indexes shifted; lifecycle re-adopts
                _drop_ghost(true)
                ghost = { entry = { gid = rec.gid, label = rec.label, price = rec.price or 0 },
                    repick = true, menu = true, drive = true, locked = true,   -- pickup = straight to moving
                    moving_rec = rec,   -- data-safe: cancelling the move restores this record
                    h = 0, yaw = rec.yaw or 0, pending = true,
                    pitch = rec.pitch or 0, roll = rec.roll or 0, scale = rec.scale or 1.0 }
                _queue_spawn(rec.gid, rec.ux, rec.uy, rec.uz, rec.yaw, function(go)
                    if ghost and ghost.pending then
                        ghost.go = go; ghost.pending = nil
                        _protect(go)
                        local p; pcall(function() p = go:call("get_Transform"):call("get_Position") end)
                        if p then ghost.px, ghost.py, ghost.pz = p.x, p.y, p.z end
                    end
                end, rec.pitch, rec.roll, rec.scale)
                -- switch to a browse cat so the NEXT A places (place-confirm only fires outside
                -- the PLACED tab); kill any queued preview + sync last_sel to the post-switch row
                -- so nothing auto-spawns over the pickup ghost (Aurora 07-24 clobber fix)
                UI.cat_i = 1
                UI.preview_want = nil
                UI.last_sel = "1:" .. tostring(UI.row)
                M.last = "moving " .. tostring(rec.label) .. " - reposition and place (no charge)"
            elseif (_edge(0x2E) or ghit(PAD.face.x)) and placed[pr.placed_i] then
                -- SELL now asks first (Aurora: "confirmation for selling too")
                local rec = placed[pr.placed_i]
                dlg.sell_rec = rec
                _show_dialog("Sell the " .. tostring(rec.label) .. "?\n+" ..
                    math.floor((rec.price or 0) / 2) .. " G", "Sell it", "Keep it", "sell")
            end
        end

        -- GHOST DRIVING: only while LOCKED IN (left stick/WASD move, RT/LT yaw, right
        -- stick = camera, holdX+dpad tilt, Z/X height)
        if ghost and ghost.go and ghost.locked and not ghost.frozen then
            -- set the camera target ONCE per ghost: re-targeting every tick RESETS the cam's
            -- orbit state (Aurora: "zoom goes a tiny bit and instantly returns")
            if UI.cam_go ~= ghost.go then
                UI.cam_go = ghost.go
                -- TARGET FIRST, then on: set_on(true) with no subject REFUSES and stays off
                -- (Aurora's "camera locked on the Arisen" - the vanilla cam never yielded)
                _cam("set_target", ghost.go)
                _cam("set_on", true)
            end
            -- pin the orbit frame to WORLD heading 0: without this the cam orbits the item's
            -- FACING, so spinning the piece spun the view too (Aurora: "camera stay in place")
            _cam("set_heading", 0)
            pcall(function()
                local fx, fz = _cam_fwd()
                local rxv, rzv = fz, -fx
                local mx, mz = 0.0, 0.0
                -- ⛔ W/S WERE INVERTED (Aurora 2026-08-08: "S is moving it forward, W is
                -- moving it backwards"). The camera's AxisZ points back toward the viewer, so
                -- +fx/+fz is TOWARD you, not away. Flipped on the KEYBOARD only — the stick
                -- mapping below reads ly with its own sign and she has never reported it
                -- backwards, so leave the thing that works alone.
                if _kb(0x57) then mz = mz - 1 end   -- W = away from the camera
                if _kb(0x53) then mz = mz + 1 end   -- S = toward the camera
                if _kb(0x41) then mx = mx - 1 end
                if _kb(0x44) then mx = mx + 1 end
                local lx, ly = _pad_axis_l()
                if math.abs(lx) > 0.15 then mx = mx + lx end
                if math.abs(ly) > 0.15 then mz = mz - ly end
                local sp = 0.09
                ghost.px = (ghost.px or 0) + (fx * mz + rxv * mx) * sp
                ghost.pz = (ghost.pz or 0) + (fz * mz + rzv * mx) * sp
                -- height: Z/X keys, or BARE dpad up/down (nav is dead while locked - free keys)
                -- height: Z/X keys, or HOLD Y + dpad up/down (Aurora's mapping)
                local ymod = gheld(PAD.face.y)
                if _kb(0x5A) or (ymod and gheld(PAD.dpad.up)) then ghost.h = (ghost.h or 0) + 0.04 end
                if _kb(0x58) or (ymod and gheld(PAD.dpad.down)) then ghost.h = (ghost.h or 0) - 0.04 end
                if _kb(0x51) or (not xmod and gheld(PAD.lt)) then ghost.yaw = (ghost.yaw or 0) - 1.6 end
                if _kb(0x45) or (not xmod and gheld(PAD.rt)) then ghost.yaw = (ghost.yaw or 0) + 1.6 end
                -- SCALE: PgUp/PgDn or HOLD X + RT/LT (Aurora: "if there's any controls left")
                if _kb(0x21) or (xmod and gheld(PAD.rt)) then ghost.scale = math.min(4.0, (ghost.scale or 1.0) + 0.012) end
                if _kb(0x22) or (xmod and gheld(PAD.lt)) then ghost.scale = math.max(0.25, (ghost.scale or 1.0) - 0.012) end
                -- HOLD X + dpad: up/down = ROLL, left/right = PITCH (Aurora's swap 07-24)
                if _kb(0x52) or (xmod and gheld(PAD.dpad.left)) then ghost.pitch = (ghost.pitch or 0) - 1.2 end
                if _kb(0x46) or (xmod and gheld(PAD.dpad.right)) then ghost.pitch = (ghost.pitch or 0) + 1.2 end
                -- ⭐ R3 (or Backspace) puts the piece back to how it came out of the catalogue.
                --   Fiddling pitch/roll is easy to get lost in; there was no way back short of
                --   cancelling the whole placement.
                if _kb(0x08) or gheld(PAD.r3) then
                    ghost.yaw, ghost.pitch, ghost.roll = 0.0, 0.0, 0.0
                    M.last = (ghost.entry and ghost.entry.label or "piece") .. ": orientation reset"
                end
                if _kb(0x54) or (xmod and gheld(PAD.dpad.up)) then ghost.roll = (ghost.roll or 0) - 1.2 end
                if _kb(0x47) or (xmod and gheld(PAD.dpad.down)) then ghost.roll = (ghost.roll or 0) + 1.2 end
                -- right stick = camera (the creature cam orbits the piece)
                local rrx, rry = _pad_axis_r()
                if math.abs(rrx) > 0.15 then _cam("orbit", rrx * 3.0) end
                if math.abs(rry) > 0.15 then _cam("zoom", -rry * 0.08) end
                -- RANGE CLAMP (Aurora 07-24): a piece can't be dragged past M.place_radius from the
                -- plot you're standing at, so decor can't be walked out into the open world.
                -- universal = render + delta; clamp in universal, write the result back to render px/pz.
                if UI.anchor then
                    local dd = _delta()
                    if dd then
                        local ux, uz = (ghost.px or 0) + dd.x, (ghost.pz or 0) + dd.z
                        local ax, az = ux - UI.anchor.ux, uz - UI.anchor.uz
                        local m2 = ax * ax + az * az
                        local R = tonumber(M.place_radius) or 25.0
                        if m2 > R * R then
                            local s = R / math.sqrt(m2)
                            ghost.px = (UI.anchor.ux + ax * s) - dd.x
                            ghost.pz = (UI.anchor.uz + az * s) - dd.z
                        end
                    end
                end
                local gt = ghost.go:call("get_Transform")
                local v = Vector4f and Vector4f.new(ghost.px, (ghost.py or 0) + (ghost.h or 0), ghost.pz, 1.0)
                    or Vector3f.new(ghost.px, (ghost.py or 0) + (ghost.h or 0), ghost.pz)
                gt:call("set_Position", v)
                local q = _euler_quat(ghost.yaw or 0, ghost.pitch or 0, ghost.roll or 0)
                local qt = ValueType.new(sdk.find_type_definition("via.Quaternion"))
                qt.x, qt.y, qt.z, qt.w = q.x, q.y, q.z, q.w
                gt:call("set_Rotation", qt)
                local sc = ghost.scale or 1.0
                pcall(function() gt:call("set_LocalScale", Vector3f.new(sc, sc, sc)) end)
            end)
            if a_hit and not in_placed then
                ghost.frozen = true
                _show_dialog(ghost.repick
                        and ("Set the " .. tostring(ghost.entry.label) .. " down here?")
                        or ("Place the " .. tostring(ghost.entry.label) .. " here?\n" .. tostring(ghost.entry.price) .. " G"),
                    "Place it", "Not yet")
            end
        elseif a_hit and not in_placed and ghost and ghost.go and not ghost.locked then
            -- browsing + a preview stands: A LOCKS IT IN (stage one of the two-press place)
            ghost.locked = true
            M.last = "locked in: " .. tostring(ghost.entry.label) .. " - position it, A places, B unlocks"
        end
        return
    end

    -- "press [hotkey] to decorate" - a quiet top-left whisper when you come home (Aurora):
    -- shows 4s on arrival at a built homestead, re-arms after you leave (>25m)
    if os.clock() - (UI.hint_check or 0) > 1.0 then
        UI.hint_check = os.clock()
        pcall(function()
            local up2 = _pupos()
            local near_home = false
            for _, pr in ipairs(_G.IrisHomesteadPlots.list()) do
                if pr.owned ~= false and pr.built ~= false then
                    local dx, dz = (pr.ux or 0) - up2.x, (pr.uz or 0) - up2.z
                    if dx * dx + dz * dz < 12.0 ^ 2 then near_home = true; break end
                end
            end
            if near_home and not UI.hint_shown then
                UI.hint_shown = true
                UI.hint_until = os.clock() + 4.0
            elseif not near_home then
                -- re-arm only once properly AWAY (hysteresis: stepping on the doorstep
                -- repeatedly shouldn't nag)
                local far = true
                for _, pr in ipairs(_G.IrisHomesteadPlots.list()) do
                    local dx, dz = (pr.ux or 0) - up2.x, (pr.uz or 0) - up2.z
                    if dx * dx + dz * dz < 25.0 ^ 2 then far = false; break end
                end
                if far then UI.hint_shown = false end
            end
        end)
    end
    if UI.hint_until and os.clock() < UI.hint_until and not UI.open then
        pcall(function()
            local F = _G.IrisFont
            if F then
                local key = tonumber(M.ui_key) or 0x6A
                local kn = (key == 0x6A) and "Numpad *" or string.format("key %X", key)
                F.text("Press [" .. kn .. "] to decorate", 24, 24, 0xCCEAD8B0, 18)
            end
        end)
    end
    -- "too far to decorate" card (Aurora 07-24): fed every frame while the timer runs so it
    -- actually LINGERS -- F.card only draws ~1s per feed. Only shows when you pressed the hotkey
    -- CLOSE to home but out of decorate range; a nowhere-near press sets no timer at all (silent).
    if UI.warn_until and os.clock() < UI.warn_until and not UI.open then
        pcall(function()
            local F = _G.IrisFont
            if F then F.card("Too far to decorate", "Move closer to your built homestead.", 0xFFC8B8A0) end
        end)
    end

    -- placed-furniture lifecycle (throttled): spawn near, adopt survivors, despawn far.
    -- ⛔ SEQUENCING LAW (Aurora: "spawn in a bit after the house to avoid crashing"): while
    -- the forge builds or collision grafts, furniture WAITS - and holds 6s after they finish.
    -- Then ONE spawn per 2s pass, never a volley (gentle by construction).
    if os.clock() - lc.at < 2.0 then return end
    lc.at = os.clock()
    local busy = false
    pcall(function()
        local st = _G.IrisForge and _G.IrisForge.status()
        if st and (st.building or false) then busy = true end
    end)
    pcall(function()
        if _G.IrisCollision and _G.IrisCollision.busy and _G.IrisCollision.busy() then busy = true end
    end)
    if busy then lc.hold_until = os.clock() + 6.0; return end
    if os.clock() < (lc.hold_until or 0) then return end
    _load_data()
    local up = _pupos()
    if not up then return end
    local d = _delta()
    for i, rec in ipairs(placed) do
        local dx, dz = (rec.ux or 0) - up.x, (rec.uz or 0) - up.z
        local dist2 = dx * dx + dz * dz
        if live[i] then
            if dist2 > 175.0 ^ 2 and dist2 < 1e10 then
                -- SURVIVOR POOL: do not move the gimmick (its static collision would stay behind)
                -- and do not destroy it. Release only our tracking reference; the engine may keep
                -- the correctly-spawned object culled at its original world position. On return,
                -- _adopt_near reclaims every survivor in one pass. If streaming retired it, the
                -- unchanged slow spawn fallback below recreates it safely.
                live[i] = nil
            end
        elseif dist2 < 120.0 ^ 2 and not live[i] and #jobs == 0 then
            local survivor = _adopt_near(rec.ux, rec.uz, d, rec.gid)
            if survivor then
                -- Already protected during its original spawn. Re-walking a fully-attached gimmick
                -- hierarchy is redundant and was implicated in the late-protection native crash.
                live[i] = survivor
                -- A survivor keeps its physics state too. Re-freeze/re-pose only the explicit
                -- pose-locked props; ordinary furnishings retain their native behaviour.
                if POSE_LOCK[tostring(rec.gid or "")] then _apply_xform(survivor, rec) end
                _log("SURVIVOR RECLAIM: " .. tostring(rec.gid) .. " (no regeneration)")
            else
                local idx = i
                _queue_spawn(rec.gid, rec.ux, rec.uy, rec.uz, rec.yaw,
                    function(go) _protect(go); _apply_xform(go, rec); live[idx] = go end, rec.pitch, rec.roll, rec.scale)
                break   -- one spawn per pass - the next piece waits its 2s turn
            end
        end
    end
end)

-- ── the SHOP SCREEN (d2d, the customize screen's visual language) ────────────────────────
function iris_furnish_draw()
    if not UI.open then return end
    if not (_G.d2d and d2d.fill_rect and d2d.text) then return end
    local sw, sh = 1920, 1080
    local ok, w, h = pcall(d2d.surface_size)
    if ok and w and h and h > 0 then sw = w; sh = h end
    local scale = sh / 1080.0
    local F = _G.IrisFont
    local title_f = F and F.d2d and F.d2d(30)
    local row_f = F and F.d2d and F.d2d(21)
    local small_f = F and F.d2d and F.d2d(16)
    if not (title_f and row_f and small_f) then return end
    local function argb(a, rgb) return math.floor(255 * math.max(0, math.min(1, a))) * 0x1000000 + (rgb % 0x1000000) end
    local function txt(font, s, x, y, col, a)
        pcall(d2d.text, font, s, x + 2, y + 2, argb((a or 1) * 0.7, 0x000000))
        pcall(d2d.text, font, s, x, y, argb(a or 1, col))
    end
    local C_ACCENT, C_PANEL, C_TITLE, C_ROW, C_DIM = 0xB4552A, 0x140E0A, 0xEAD8B0, 0xD8C9A8, 0x8A7A5E
    local px = math.floor(40 * scale)
    local pw = math.floor(math.min(sw * 0.38, 600 * scale))
    local ph = math.floor(sh * 0.78)
    local py = math.floor((sh - ph) * 0.5)
    local b = math.max(2, math.floor(2.5 * scale))
    pcall(d2d.fill_rect, px + b * 2, py + b * 2, pw, ph, argb(0.4, 0x000000))
    pcall(d2d.fill_rect, px - b, py - b, pw + b * 2, ph + b * 2, argb(0.9, C_ACCENT))
    pcall(d2d.fill_rect, px, py, pw, ph, argb(0.95, C_PANEL))
    pcall(d2d.fill_rect, px, py, pw, math.max(4, math.floor(6 * scale)), argb(1.0, C_ACCENT))
    local ix = px + math.floor(26 * scale)
    local y = py + math.floor(22 * scale)
    txt(title_f, "Homestead Furnishings", ix, y, C_TITLE); y = y + math.floor(44 * scale)
    local ac = _all_cats()
    txt(row_f, "< " .. tostring(ac[UI.cat_i] or "ALL") .. " >  (LB/RB)", ix, y, C_ACCENT + 0x303030)
    txt(row_f, tostring(_gold() or "?") .. " G", px + pw - math.floor(130 * scale), y, C_TITLE)
    y = y + math.floor(36 * scale)
    local rows = _rows_for_cat()
    if UI.row > #rows then UI.row = math.max(1, #rows) end
    local visible = math.floor((ph - (y - py) - 70 * scale) / (28 * scale))
    local first = math.max(1, math.min(UI.row - math.floor(visible / 2), #rows - visible + 1))
    for r = first, math.min(#rows, first + visible - 1) do
        local e = rows[r]
        local sel = r == UI.row
        if sel then pcall(d2d.fill_rect, px + 8, y - 2, pw - 16, math.floor(26 * scale), argb(0.8, 0x2A1C12)) end
        txt(row_f, e.label, ix + math.floor(10 * scale), y, sel and C_TITLE or C_ROW, sel and 1.0 or 0.85)
        -- ⭐ in PLACED, the distance is what identifies a row — eleven "Chair" rows at 400 G
        --   each are indistinguishable, but "2m" vs "31m" tells you exactly which one.
        local right = (e.dist and string.format("%.0fm", e.dist)) or (e.price .. " G")
        txt(row_f, right, px + pw - math.floor(120 * scale), y, sel and C_TITLE or C_DIM, sel and 1.0 or 0.8)
        y = y + math.floor(28 * scale)
    end
    if ac[UI.cat_i] == "PLACED" then
        txt(small_f, "Up/Down pick   A/Enter: pick UP (move, free)   X/Del: sell for half",
            ix, py + ph - math.floor(34 * scale), C_DIM)
        txt(small_f, "LB/RB or [ ]: category   B/Esc: leave", ix, py + ph - math.floor(18 * scale), C_DIM)
    else
        local locked_now = ghost and ghost.locked and ghost.go
        local h1 = locked_now
            and "Stick move   LT/RT spin   holdX+dpad tilt   holdX+RT/LT scale   holdY+up/down height"
            or "Up/Down browse   LB/RB category   A: LOCK the piece in   B/Esc: leave"
        local h2 = locked_now
            and "A/Enter: place (confirm + pay)   R3/Backspace: reset angle   B: unlock"
            or "(the preview follows your selection; locking in enables the move controls)"
        txt(small_f, h1, ix, py + ph - math.floor(34 * scale), C_DIM)
        txt(small_f, h2, ix, py + ph - math.floor(18 * scale), C_DIM)
    end
end
pcall(function()
    if _G.d2d and type(d2d.register) == "function" then
        d2d.register(function() end, function() pcall(iris_furnish_draw) end)
    end
end)

-- ── bridge: selling the homestead sells its furnishings (Aurora: reset-to-sale must not
-- orphan bought furniture). Refunds half of each piece into the wallet; returns total, count.
_G.IrisFurnish = {
    sell_plot = function(plotname)
        _load_data()
        local total, n = 0, 0
        local d = _delta()
        for i = #placed, 1, -1 do
            local rec = placed[i]
            if rec.plot == plotname then
                if live[i] then pcall(function() live[i]:call("destroy", live[i]) end) end
                _destroy_at(rec.ux, rec.uz, d, 2.0)   -- + any untracked/duplicate copy
                total = total + math.floor((rec.price or 0) / 2)
                table.remove(placed, i)
                n = n + 1
            end
        end
        if n > 0 then
            for k in pairs(live) do live[k] = nil end   -- indexes shifted; survivors re-adopt
            _save_placed()
            pcall(function()
                local im = sdk.get_managed_singleton("app.ItemManager")
                local cur = tonumber(im:get_field("_Version"))
                if cur then im:set_field("_Version", cur + total) end
            end)
            _log(string.format("sold %d furnishings of plot '%s' (+%d G)", n, tostring(plotname), total))
        end
        return total, n
    end,
}

re.on_script_reset(function()
    -- refs only (destroy-on-reset CTD law); standing furniture gets ADOPTED next pass.
    -- NEVER leave the player FSM-frozen OR the world OUR-paused (both = softlock laws).
    if UI.open or (ghost and ghost.drive) then _fsm_enabled(true) end
    _world_pause(false)
    pcall(function() if _G.IrisCreatureCam then _G.IrisCreatureCam.clear_target(); _G.IrisCreatureCam.set_on(false) end end)
    UI.open = false; _G.IrisFurnishUIOpen = false
    if dlg.open then _close_dialog() end
    for k in pairs(live) do live[k] = nil end
    jobs = {}
    ghost = nil
end)

-- ── UI ───────────────────────────────────────────────────────────────────────────────────
re.on_draw_ui(function()
    if not imgui.tree_node("IRIS FURNISH (decorate the homestead)") then return end
    _load_data()
    imgui.text(M.last)

    -- ⭐ PRECISE EDITOR (Aurora 2026-08-08: "a decorate UI in the reframework UI section for
    -- more granular changes to placed items"). The in-world mode is for placing by feel; this
    -- is for getting a piece exactly right — and it is mouse-driven for free, because imgui
    -- owns the cursor while the overlay is open. Edits apply to the LIVE object immediately
    -- and are saved to the record, so they survive a respawn.
    if imgui.tree_node("EDIT A PLACED PIECE (precise / mouse)##ifn_edit") then
        pcall(function()
            local d, pp = _delta(), nil
            pcall(function() pp = _pgo():call("get_Transform"):call("get_UniversalPosition") end)
            imgui.text("pieces near you:")
            local shown = 0
            for i, rec in ipairs(placed) do
                if pp and shown < 14 then
                    local dx, dz = (rec.ux or 0) - pp.x, (rec.uz or 0) - pp.z
                    local dist = math.sqrt(dx * dx + dz * dz)
                    if dist <= 30.0 then
                        shown = shown + 1
                        if imgui.button(string.format("%s%s  (%.0fm)##ifn_pick%d",
                                (M.edit_i == i) and "> " or "  ", tostring(rec.label), dist, i)) then
                            -- selecting captures a BASELINE so the position sliders can be a
                            -- readable +/-3m offset instead of raw universal coordinates,
                            -- which are five-figure numbers no slider can show usefully.
                            M.edit_i = i
                            M.edit_base = { x = rec.ux or 0, y = rec.uy or 0, z = rec.uz or 0 }
                            M.edit_dx, M.edit_dy, M.edit_dz = 0.0, 0.0, 0.0
                        end
                    end
                end
            end
            if shown == 0 then imgui.text("   nothing placed within 30m") end

            local rec = M.edit_i and placed[M.edit_i]
            if rec then
                imgui.text("editing: " .. tostring(rec.label) .. " (" .. tostring(rec.gid) .. ")")
                local c
                c, rec.yaw   = imgui.slider_float("yaw##ifn_e",   rec.yaw or 0, -180, 180)
                c, rec.pitch = imgui.slider_float("pitch##ifn_e", rec.pitch or 0, -180, 180)
                c, rec.roll  = imgui.slider_float("roll##ifn_e",  rec.roll or 0, -180, 180)
                local u = tonumber(rec.scale) or 1.0
                c, rec.sx = imgui.slider_float("scale X (width)##ifn_e",  tonumber(rec.sx) or u, 0.1, 4.0)
                c, rec.sy = imgui.slider_float("scale Y (height)##ifn_e", tonumber(rec.sy) or u, 0.1, 4.0)
                c, rec.sz = imgui.slider_float("scale Z (depth)##ifn_e",  tonumber(rec.sz) or u, 0.1, 4.0)
                -- position as +/-3m OFFSETS from where the piece was when you selected it
                if not M.edit_base then
                    M.edit_base = { x = rec.ux or 0, y = rec.uy or 0, z = rec.uz or 0 }
                    M.edit_dx, M.edit_dy, M.edit_dz = 0.0, 0.0, 0.0
                end
                c, M.edit_dx = imgui.slider_float("move X##ifn_e", M.edit_dx or 0, -3.0, 3.0)
                c, M.edit_dy = imgui.slider_float("move Y (height)##ifn_e", M.edit_dy or 0, -3.0, 3.0)
                c, M.edit_dz = imgui.slider_float("move Z##ifn_e", M.edit_dz or 0, -3.0, 3.0)
                if imgui.button("re-centre offsets here##ifn_e") then
                    M.edit_base = { x = rec.ux or 0, y = rec.uy or 0, z = rec.uz or 0 }
                    M.edit_dx, M.edit_dy, M.edit_dz = 0.0, 0.0, 0.0
                end

                -- ⛔ nothing is applied from this panel: the transform write happens on the
                -- game thread in the tick above, or it silently does nothing.
                if not live[M.edit_i] then
                    imgui.text("   (not spawned right now - edits save and apply on respawn)")
                end
                if imgui.button("SAVE##ifn_e") then _save_placed(); M.last = "saved " .. tostring(rec.label) end
                imgui.same_line()
                if imgui.button("reset scale##ifn_e") then rec.sx, rec.sy, rec.sz = 1.0, 1.0, 1.0 end
            end
        end)
        imgui.tree_pop()
    end
    local kc, kv = imgui.input_text("shop hotkey (VK hex; 6A = numpad *)##ifn_key", string.format("%X", tonumber(M.ui_key) or 0x6A))
    if kc then M.ui_key = tonumber(kv, 16) or 0x6A end
    imgui.text("⭐ v3: press the hotkey AT YOUR BUILT HOMESTEAD - paused shop, live preview,")
    imgui.text("   drive the piece, A to place (confirm+pay), PLACED category = move/sell")
    imgui.text("gold: " .. tostring(_gold() or "?") .. " G    placed pieces: " .. tostring(#placed))
    local c
    c, M.cat = imgui.combo("category##ifn_cat", M.cat, cats)

    if ghost then
        imgui.separator()
        imgui.text("GHOST: " .. tostring(ghost.entry.label) .. "  (" .. ghost.entry.price .. " G)")
        if ghost.pending then imgui.text("  (spawning...)") end
        c, ghost.dist = imgui.slider_float("distance ahead##ifn_d", ghost.dist, 1.0, 10.0)
        c, ghost.h = imgui.slider_float("height##ifn_h", ghost.h, -2.0, 3.0)
        c, ghost.yaw = imgui.slider_float("spin (deg)##ifn_y", ghost.yaw, -180.0, 180.0)
        if imgui.button("PLACE HERE (opens the confirm)##ifn_place") and ghost.go then
            ghost.frozen = true
            _show_dialog("Place the " .. tostring(ghost.entry.label) .. " here?\n" ..
                tostring(ghost.entry.price) .. " G", "Place it", "Not yet")
        end
        imgui.same_line()
        if imgui.button("CANCEL GHOST##ifn_cg") then _drop_ghost(true); M.last = "ghost cancelled" end
        imgui.separator()
    end

    -- catalog list (filtered, paginated 12/page)
    local want = cats[M.cat] or "ALL"
    local rows = {}
    for _, e in ipairs(catalog) do
        if want == "ALL" or e.category == want then rows[#rows + 1] = e end
    end
    -- ⛔⛔ PAGINATION REMOVED (Aurora 08-09: "have all of the furnishings be on 1 list? it's
    --   annoying having to sift through pages when they move around when you retype their name").
    --   She is describing a real defect, not a preference: renaming re-sorts the catalog, the row
    --   you just typed into jumps to a different PAGE, and it vanishes from under the cursor.
    --   One scrolling child window fixes both complaints - nothing to page through, and a
    --   re-sorted row is still on screen where you can see where it went.
    imgui.text(string.format("%d pieces", #rows))
    imgui.same_line()
    -- ⭐ UNHIDE (ask 4): hiding was one-way, so a mis-click meant hand-editing the json
    local nh = 0
    for _ in pairs(hidden or {}) do nh = nh + 1 end
    if nh > 0 and imgui.button(string.format("un-hide all %d hidden##ifn_uh", nh)) then
        hidden = {}; _save_hidden(); catalog = nil
        M.last = string.format("restored %d hidden piece(s)", nh)
    end
    -- ⭐ ADD A CATEGORY (ask 3). Kept in the catalog json alongside everything else, so a custom
    --   category survives reloads exactly like a rename or a re-filing does.
    local CATLIST = { "bedroom", "living", "kitchen", "storage", "decor", "yard",
        "craft", "utility", "structure", "interact", "misc" }
    for _, cn in ipairs(M.extra_cats or {}) do CATLIST[#CATLIST + 1] = cn end
    -- ⛔⛔ THIS ADDED A CATEGORY PER KEYSTROKE (Aurora 08-09: typing "food" produced f, fo, foo,
    --   food). My commit condition was `button OR text-differs-from-last-frame`, and the text
    --   differs on EVERY character — so the "or" I added as belt-and-braces WAS the bug.
    --   ⇒ commit ONLY on the input's own ENTER flag (32 = EnterReturnsTrue, the same rule the
    --     rename and price fields use) or an actual button press. The buffer is kept in M.newcat
    --     between frames so typing still works; it is just no longer a commit.
    imgui.push_item_width(150)
    local ent, typed = imgui.input_text("##ifn_newcat", M.newcat or "", 32)
    imgui.pop_item_width()
    if typed ~= nil then M.newcat = typed end
    imgui.same_line()
    local pressed = imgui.button("add category##ifn_ac")
    if ent or pressed then
        local nm = tostring(M.newcat or ""):lower():gsub("%s+", "")
        if nm ~= "" then
            local dup = false
            for _, cn in ipairs(CATLIST) do if cn == nm then dup = true end end
            if dup then
                M.last = "category '" .. nm .. "' already exists"
            else
                M.extra_cats = M.extra_cats or {}
                M.extra_cats[#M.extra_cats + 1] = nm
                pcall(function() json.dump_file(EXTRACAT_FILE, M.extra_cats) end)
                M.last = "added category '" .. nm .. "'"
                catalog = nil
            end
            M.newcat = ""
        end
    end
    -- ⭐ AND A WAY TO DELETE THEM, because the bug above has almost certainly left junk behind.
    --   Only custom categories can be removed; the built-in list is untouchable.
    if M.extra_cats and #M.extra_cats > 0 then
        imgui.text("custom categories:")
        for i = #M.extra_cats, 1, -1 do
            imgui.same_line()
            if imgui.button(M.extra_cats[i] .. " X##ifn_dc" .. i) then
                local gone = table.remove(M.extra_cats, i)
                pcall(function() json.dump_file(EXTRACAT_FILE, M.extra_cats) end)
                M.last = "removed category '" .. tostring(gone) .. "'"
                catalog = nil
            end
        end
    end
    -- ⭐ ONE SCROLLING LIST. 420px keeps the panel usable; the list itself is unbounded.
    -- ⛔ the size is a **Vector2f**, not two floats. Copied from IrisMusicProbe.lua:741, which
    --   ships and works; my first version passed (0.0, 420.0, true) and would have been wrong.
    imgui.begin_child_window("ifn_list", Vector2f.new(0, 420), true)
    for r = 1, #rows do
        local e = rows[r]
        -- ⭐ RENAME (Aurora 08-09: "give me the option to rename the items... I want to give
        -- some of them more specific names"). The catalog ships 594 auto-labelled rows where
        -- twelve different things are all called "Table decor", so a per-row rename is worth
        -- more than it looks. Written straight into the catalog json exactly like the
        -- category re-filing beside it, so it survives reloads, resets and rebuilds.
        -- ⚠ Committed on ENTER, not per keystroke - a write + catalog reload on every
        -- character would rebuild the row list under the cursor you are typing into.
        imgui.push_item_width(190)
        local nc, nv = imgui.input_text("##ifn_n" .. e.gid, e.label, 32)  -- 32 = EnterReturnsTrue
        imgui.pop_item_width()
        if nc and nv and nv ~= "" and nv ~= e.label then
            pcall(function()
                local raw = json.load_file(CATALOG_FILE) or {}
                if raw[e.gid] then raw[e.gid].label = nv end
                json.dump_file(CATALOG_FILE, raw)
            end)
            _log(string.format("renamed %s: '%s' -> '%s'", e.gid, tostring(e.label), tostring(nv)))
            catalog = nil   -- reload so the shop screen shows the new name too
        end
        imgui.same_line()
        -- ⭐ EDITABLE PRICE (ask 2). Same commit-on-ENTER rule as the rename beside it: writing
        --   on every keystroke would rebuild the catalog under the cursor mid-number.
        --   ⚠ Stored as a NUMBER, and rejected if it is not one — a string price would break the
        --     affordability check and the half-refund maths on removal.
        imgui.push_item_width(70)
        local pc, pv = imgui.input_text("##ifn_p" .. e.gid, tostring(e.price or 0), 32)
        imgui.pop_item_width()
        if pc and pv then
            local n = tonumber(pv)
            if n and n >= 0 and math.floor(n) ~= (e.price or 0) then
                n = math.floor(n)
                pcall(function()
                    local raw = json.load_file(CATALOG_FILE) or {}
                    if raw[e.gid] then raw[e.gid].price = n end
                    json.dump_file(CATALOG_FILE, raw)
                end)
                _log(string.format("repriced %s: %d -> %d G", e.gid, e.price or 0, n))
                catalog = nil
            end
        end
        imgui.same_line()
        imgui.text("G")
        imgui.same_line()
        local cur_i = 1
        for ci, cn in ipairs(CATLIST) do if cn == e.category then cur_i = ci; break end end
        imgui.push_item_width(110)
        local cc, cv = imgui.combo("##ifn_c" .. e.gid, cur_i, CATLIST)
        imgui.pop_item_width()
        if cc and CATLIST[cv] and CATLIST[cv] ~= e.category then
            -- write the re-filing straight into the catalog json (survives everything)
            pcall(function()
                local raw = json.load_file(CATALOG_FILE) or {}
                if raw[e.gid] then raw[e.gid].category = CATLIST[cv] end
                json.dump_file(CATALOG_FILE, raw)
            end)
            catalog = nil   -- reload with the new filing
        end
        imgui.same_line()
        if imgui.button("GHOST##ifn_g" .. e.gid) then _start_ghost(e) end
        imgui.same_line()
        if imgui.button("HIDE##ifn_h" .. e.gid) then
            hidden[e.gid] = true; _save_hidden(); catalog = nil   -- reload filters it out
        end
    end
    imgui.end_child_window()

    -- placed management
    if #placed > 0 and imgui.tree_node("PLACED pieces (remove refunds half)##ifn_pl") then
        for i = #placed, 1, -1 do
            local rec = placed[i]
            imgui.text(string.format("  %s @ %s", tostring(rec.label), tostring(rec.plot)))
            imgui.same_line()
            if imgui.button("REMOVE##ifn_rm" .. i) then
                if live[i] then pcall(function() live[i]:call("destroy", live[i]) end); live[i] = nil end
                pcall(function()
                    local im = sdk.get_managed_singleton("app.ItemManager")
                    local cur = tonumber(im:get_field("_Version"))
                    if cur then im:set_field("_Version", cur + math.floor((rec.price or 0) / 2)) end
                end)
                table.remove(placed, i)
                -- live[] indexes shift with the removal: drop all refs, the lifecycle re-adopts
                for k in pairs(live) do live[k] = nil end
                _save_placed()
                M.last = "removed " .. tostring(rec.label) .. " (+".. math.floor((rec.price or 0) / 2) .. " G back)"
            end
        end
        imgui.tree_pop()
    end
    imgui.tree_pop()
end)

-- ⭐ RE-ASSERT PUMP. Re-writes a freshly placed piece's rotation ~1.2s after it spawns, once its
--   cold bind has finished and the generator's own initial angle has stopped fighting us.
--   Runs twice (1.2s and 2.4s) then drops the entry, so this costs nothing at rest.
re.on_frame(function()
    if #_reassert == 0 then return end
    local now = os.clock()
    for i = #_reassert, 1, -1 do
        local e = _reassert[i]
        local age = now - (e.at or 0)
        local want = (e.done or 0) == 0 and 1.2 or 2.4
        if age >= want then
            local alive = false
            pcall(function() alive = e.go:call("get_Valid") == true end)
            if alive then
                pcall(function()
                    local before = e.go:call("get_Transform"):call("get_Rotation")
                    if before then
                        _log(string.format("SETTLE +%.1fs piece q=(%.3f,%.3f,%.3f,%.3f)  want=(%.3f,%.3f,%.3f,%.3f)",
                            age, before.x, before.y, before.z, before.w,
                            (e.rec.q or {}).x or 0, (e.rec.q or {}).y or 0,
                            (e.rec.q or {}).z or 0, (e.rec.q or {}).w or 1))
                    end
                end)
                pcall(function() _apply_xform(e.go, e.rec) end)
            end
            e.done = (e.done or 0) + 1
            if e.done >= 2 or not alive then table.remove(_reassert, i) end
        end
    end
end)

return M

