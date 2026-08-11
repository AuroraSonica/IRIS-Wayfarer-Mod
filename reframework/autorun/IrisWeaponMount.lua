-- ═════════════════════════════════════════════════════════════════════════════════════
-- IrisWeaponMount.lua — SLICE 1: CUSTODY. Hang a weapon on a plaque and get it back
-- EXACTLY as it went in, upgrade level and all.
--
-- Aurora's spec (08-09): "I don't mind the weapon being 'gone' if it can be retrieved...
-- like the weapon mounts in Breath of the Wild." The plaque IS the container.
--
-- ⭐ WHY THIS IS SAFE TO ATTEMPT AT ALL (all measured in-game, 08-09):
--   `getItem` CANNOT carry enhancement (9 params, none of them are it) — so the naive
--   delete-and-re-grant strips upgrade level and Dragonforging silently. But
--   `addStorageNoLock(itemId, num, EnhanceParam, CharacterID, ...)` takes the enhancement
--   struct BY VALUE, which is the whole ball game: read it off the weapon, hold it,
--   hand it back.
--
-- ⛔⛔ LAWS THIS FILE IS BUILT AROUND — each one is a way to eat somebody's gear:
--   1. **PROVE THE ADD BEFORE ANY DELETE.** Mounting is REFUSED until the self-test has
--      round-tripped a SPARE item in this session. A delete whose matching add turns out
--      not to work is unrecoverable, and "it logged success" is not proof.
--   2. **NEVER read enhancement via `get_Param`** — it returns a ValueType copy REFramework
--      does not bind, and the +3 Lifetaker read back as `_Num=15`, `_Type0=39`, getters
--      claiming it was a *Rotten Apple*. Read `sd:call("get_Enhance")` and use its FIELDS.
--      Its getters lie too (`get_Num`=104 while `_Num`=3). Fields good, getters junk.
--   3. **`addStorageNoLock` is a NO-LOCK mutator.** The caller is normally expected to hold
--      the storage mutex. Game thread only (UpdateBehavior), ONE item at a time, never in
--      a loop. Everything here is queued and drained one job per tick.
--   4. **The record is written BEFORE the delete and only cleared AFTER a verified re-add**,
--      so a crash mid-operation leaves the weapon recoverable rather than gone.
--
-- Slice 2 (not here): the weapon's `wp` mesh displayed on the plaque. Deliberately after
-- custody — a mesh offset bug must never be tangled up with a lost weapon.
-- ═════════════════════════════════════════════════════════════════════════════════════

local M = {
    reach       = 3.0,        -- how near a plaque you must stand
    carrier     = "gm81_075", -- the plaque's carrier gimmick (IrisFurnish SKIN)
    test_item   = 34712,      -- Woodcutter's Axe: one of ours, trivially re-grantable
    test_enh    = 3,          -- the enhancement level the self-test writes and reads back
    require_test = false,     -- Aurora waived the safety gate; kept as a switch
    log         = true,

    -- ── the in-world interact ────────────────────────────────────────────────────────
    -- ⭐ AURORA'S DESIGN (08-09), and it is better than the dialog I proposed: "we might
    --   not need the dialogue menu... the interact button can just put the equipped weapon
    --   straight on." It removes the whole 4-slot paged-dialog problem AND guarantees the
    --   mesh is readable, because the weapon is on the body at the moment we read it.
    prompt      = true,
    key         = 0x45,       -- E
    -- ⛔ PAD BUTTON: `via.hid.GamePadButton` has NO field called "B". RDown = Xbox A =
    --   DD2's own interact/confirm, which is what farming/cooking already use.
    --   Aurora would prefer B for consistency with the native "B Sit" prompts — that is a
    --   fair instinct, but B is ALSO dodge/cancel, so moving to it needs an action-level
    --   DODGE block the same way A needs a JUMP block. One field + one hook when wanted.
    -- ⭐ MOVED TO B (Aurora 08-09): B is DD2's own interact button, so every native prompt
    --   she sees uses it and ours looked foreign on A. Resolved through the shared
    --   _G.IrisPad resolver, which logs the real field list once — `via.hid.GamePadButton`
    --   has no field literally called "B", and farming spent weeks advertising a button it
    --   was not reading.
    pad         = "Cancel",   -- candidates tried in order below; this is only the first guess
    pad_label   = "B",
    -- ⛔ B is ALSO dodge/dash, so it needs the same action-level suppression A needed for
    --   jump. The game gets away with sharing the button because its own interact system
    --   claims priority; we cannot join that system (register() is a CTD), so we block.
    -- ⛔ OFF 08-09, same reason as IrisFarming: the plaque interact is B, so eating A only
    --   removes the player's jump for no benefit while stood at a weapon mount.
    block_jump  = false,
    block_dodge = true,       -- ⚠ STAYS: B is dodge/dash, so this collision is the real one
    label_h     = 1.0,        -- metres above the plaque origin
    auto_equip  = true,       -- re-equip the weapon when you take it back

    -- ── slice 2b: the weapon shown ON the plaque ─────────────────────────────────────
    -- ⚠ These WILL need eyeballing. A weapon's origin is wherever its rig puts it, so the
    --   first sword hangs at some daft angle; once one is right most one-handers share it.
    display     = true,
    disp_x      = 0.0,
    disp_y      = 0.0,
    disp_z      = 0.0,
    disp_yaw    = 0.0,
    disp_pitch  = 0.0,
    disp_roll   = 0.0,
    disp_scale  = 1.0,
    disp_range  = 30.0,       -- spawn the prop only while you are near the plaque
}

local LOG   = "IrisWeaponMount.log"
local STORE = "IRIS/weapon_mounts.json"

local function _log(s)
    if not M.log then return end
    pcall(function()
        local f = io.open(LOG, "a")
        if f then f:write(os.date("[%H:%M:%S] ") .. tostring(s) .. "\n"); f:close() end
    end)
end

local mounts = nil            -- { [posKey] = {item=, name=, num=, t0=, t1=, t2=} }
local Q      = {}
local proven = false          -- has the round trip been demonstrated THIS SESSION?
local last   = "not tested yet"

local function _load()
    if mounts then return end
    mounts = {}
    pcall(function() mounts = json.load_file(STORE) or {} end)
end
local function _save()
    pcall(function() json.dump_file(STORE, mounts) end)
end

-- ⛔⛔ THE OFFSETS MUST PERSIST (Aurora 08-09: "will it use that positioning every time?").
--   v1 kept them in module locals, so every script reset silently threw her tuning away —
--   she would have re-dialled the same sliders after every reload and eventually assumed
--   the feature was flaky. Own file, so it survives resets, reloads and rebuilds.
local CFG = "IRIS/weapon_mount_cfg.json"
local CFG_KEYS = { "disp_x", "disp_y", "disp_z", "disp_yaw", "disp_pitch", "disp_roll",
                   "disp_scale", "label_h", "reach", "auto_equip", "display" }
local function _load_cfg()
    pcall(function()
        local c = json.load_file(CFG)
        if type(c) ~= "table" then return end
        for _, k in ipairs(CFG_KEYS) do if c[k] ~= nil then M[k] = c[k] end end
    end)
end
local function _save_cfg()
    pcall(function()
        local c = {}
        for _, k in ipairs(CFG_KEYS) do c[k] = M[k] end
        json.dump_file(CFG, c)
    end)
end
_load_cfg()

-- ── helpers ──────────────────────────────────────────────────────────────────────────
local function _im() return sdk.get_managed_singleton("app.ItemManager") end

-- full-euler -> quaternion, same construction IrisFurnish uses for placed furniture
local function _euler_quat(yaw, pitch, roll)
    local cy, sy = math.cos(math.rad(yaw) / 2),   math.sin(math.rad(yaw) / 2)
    local cp, sp = math.cos(math.rad(pitch) / 2), math.sin(math.rad(pitch) / 2)
    local cr, sr = math.cos(math.rad(roll) / 2),  math.sin(math.rad(roll) / 2)
    return {
        w = cy * cp * cr + sy * sp * sr,
        x = cy * sp * cr + sy * cp * sr,
        y = sy * cp * cr - cy * sp * sr,
        z = cy * cp * sr - sy * sp * cr,
    }
end

local function _player()
    local ch = nil
    pcall(function() ch = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer") end)
    return ch
end

local function _cid()
    local c, id = _player(), nil
    if not c then return nil end
    pcall(function() id = c:call("get_CharaID") end)
    return id
end

local function _each(list, fn)
    if not list then return 0 end
    local n, seen = nil, 0
    pcall(function() n = list:get_size() end)
    if n then
        for i = 0, n - 1 do
            local e = nil
            if pcall(function() e = list:get_element(i) end) and e then seen = seen + 1; fn(e) end
        end
        return seen
    end
    pcall(function()
        local c = list:call("get_Count") or 0
        for i = 0, c - 1 do
            local e = nil
            if pcall(function() e = list:call("get_Item", i) end) and e then seen = seen + 1; fn(e) end
        end
    end)
    return seen
end

-- every weapon the player is carrying, with its enhancement READ THE SAFE WAY
local function _weapons()
    local out, mgr, cid = {}, _im(), _cid()
    if not (mgr and cid) then return out end
    local list = nil
    pcall(function() list = mgr:call("getStorageMasterList(app.CharacterID)", cid) end)
    _each(list, function(sd)
        pcall(function()
            local id = sd:call("get_ItemId")
            if not id or id == 0 then return end
            local d = mgr:call("getItemData(System.Int32)", id)
            if not d then return end
            local cat = tostring(d:call("get_EquipCategory"))
            if cat ~= "0" and cat ~= "1" then return end          -- main/sub hand only
            local name = tostring(d:call("get_Name"))
            local enh  = sd:call("get_EnhanceNum") or 0
            -- ⛔ FIELDS of get_Enhance, never get_Param, never the getters
            local ep = sd:call("get_Enhance")
            local t0, t1, t2 = 0, 0, 0
            if ep then
                pcall(function() t0 = ep:get_field("_Type0") or 0 end)
                pcall(function() t1 = ep:get_field("_Type1") or 0 end)
                pcall(function() t2 = ep:get_field("_Type2") or 0 end)
            end
            out[#out + 1] = { sd = sd, id = id, name = name, num = enh, t0 = t0, t1 = t1, t2 = t2 }
        end)
    end)
    return out
end

-- the weapon currently in the main hand
-- ⛔ MUST live above _retrieve (auto-equip) and the interact block. A `local function` is
--    invisible to code defined ABOVE it — the reference compiles to a nil GLOBAL and, inside
--    a pcall, fails in total silence. Third time tonight; luac cannot see it.
local function _equipped_weapon()
    for _, w in ipairs(_weapons()) do
        local eq = false
        pcall(function() eq = w.sd:call("get_IsEquipped") == true end)
        if eq then return w end
    end
    return nil
end

-- build a fresh EnhanceParam ValueType from stored numbers (the struct is passed BY VALUE,
-- so we construct one rather than trying to mutate a copy we were handed)
local function _mk_enhance(num, t0, t1, t2)
    local ep = nil
    pcall(function()
        ep = ValueType.new(sdk.find_type_definition("app.ItemDefine.EnhanceParam"))
        ep:set_field("_Num",   num or 0)
        ep:set_field("_Type0", t0 or 0)
        ep:set_field("_Type1", t1 or 0)
        ep:set_field("_Type2", t2 or 0)
    end)
    return ep
end

-- ⭐ THE ACQUISITION EVENT (Aurora 08-09: "it would be good to get the kaching and the
--   popup to receive an item"). `addStorageNoLock` has no event parameter, which is exactly
--   why retrieval is silent. `addItemToStorageNoLock` carries BOTH the EnhanceParam AND an
--   `app.ItemManager.GetItemEventType` — it is almost certainly what the locked `getItem`
--   calls internally once it has taken the mutex.
-- ⛔ Resolve the enum by NAME and LOG every member; never hardcode an integer for an enum
--   we have not read. (The weather resolver latched a plausible-but-wrong name and
--   reported "look 0" in the pouring rain — same class of mistake, one layer down.)
local EVT = { done = false, val = nil }
local function _event_type()
    if EVT.done then return EVT.val end
    EVT.done = true
    pcall(function()
        local td = sdk.find_type_definition("app.ItemManager.GetItemEventType")
        if not td then _log("GetItemEventType: type not found"); return end
        local names, byname = {}, {}
        for _, f in ipairs(td:get_fields() or {}) do
            pcall(function()
                if f:is_static() then
                    local v = f:get_data(nil)
                    names[#names + 1] = f:get_name() .. "=" .. tostring(v)
                    byname[f:get_name()] = v
                end
            end)
        end
        _log("GetItemEventType members: " .. table.concat(names, ", "))
        -- ⭐ THE REAL MEMBERS, read in-game 08-09: None=1, Gather=2, TreasureBox=4, Talk=8,
        --   DeadEnemy=16. None of my guessed names existed, so evt was nil and the retrieval
        --   was silent. `Gather` is the ordinary item-pickup event; `TreasureBox` is the
        --   chest flourish, which arguably suits taking a sword off a wall even better.
        for _, want in ipairs({ "Gather", "TreasureBox", "DeadEnemy", "None" }) do
            if byname[want] ~= nil then
                EVT.val = byname[want]
                _log("GetItemEventType chosen: " .. want .. "=" .. tostring(EVT.val))
                return
            end
        end
        _log("GetItemEventType: no preferred name matched - passing nil (silent, but safe)")
    end)
    return EVT.val
end

-- ⛔ MUST be defined ABOVE _give_back, which verifies its own result with it. A `local
--    function` does not exist above its own definition — the call would resolve to a nil
--    GLOBAL and, inside a pcall, fail completely silently. luac cannot catch this.
local function _find(id, want_num)
    for _, w in ipairs(_weapons()) do
        if w.id == id and (want_num == nil or w.num == want_num) then return w end
    end
    return nil
end

-- ⛔ NO-LOCK MUTATOR. Game thread, one at a time. Flushed log either side of the native
--    call so a CTD gives a precise verdict instead of "no trace".
local function _give_back(id, num, t0, t1, t2)
    local mgr, cid = _im(), _cid()
    if not (mgr and cid) then _log("give_back: no manager/charaID"); return false end
    local ep = _mk_enhance(num, t0, t1, t2)
    if not ep then _log("give_back: could not build EnhanceParam"); return false end

    -- ⭐ TRY THE EVENT-FIRING ROUTE FIRST, FALL BACK TO THE PROVEN SILENT ONE. The flag
    --   pattern mirrors getItem's own (true,false,false, evt, true,false), which is the
    --   best-informed guess available for the extra parameters.
    local evt = _event_type()
    _log(string.format("ABOUT TO CALL addItemToStorageNoLock(item=%d, 1, Enhance{num=%s,t=%s/%s/%s}, evt=%s)",
        id, tostring(num), tostring(t0), tostring(t1), tostring(t2), tostring(evt)))
    local ok = pcall(function()
        mgr:call("addItemToStorageNoLock", id, 1, ep, cid, 0, true, false, false, evt, true, false, 0, false)
    end)
    _log("survived addItemToStorageNoLock: " .. tostring(ok))
    if ok and _find(id, num) then
        _log("give_back: arrived via addItemToStorageNoLock (with acquisition event)")
        return true
    end

    _log("give_back: falling back to addStorageNoLock (silent, but proven)")
    _log(string.format("ABOUT TO CALL addStorageNoLock(item=%d, 1, Enhance{num=%s})", id, tostring(num)))
    local ok2 = pcall(function()
        mgr:call("addStorageNoLock", id, 1, ep, cid, 0, false, false, false, false, 0)
    end)
    _log("survived addStorageNoLock: " .. tostring(ok2))
    return ok2
end

-- ── ⭐ THE SELF-TEST: prove the round trip on a SPARE before any real weapon ─────────
local function _selftest()
    local mgr, ch = _im(), _player()
    if not (mgr and ch) then last = "no manager/player"; _log(last); return end
    local id = M.test_item

    _log("")
    _log(string.rep("=", 70))
    _log("SELF-TEST on item " .. id .. " — grant a SPARE, round-trip it, verify")

    -- 1. grant a spare so the player's own copy is never the subject
    _log("step 1: grant a spare via getItem")
    pcall(function()
        local m = sdk.find_type_definition("app.ItemManager"):get_method(
            "getItem(System.Int32, System.Int32, app.Character, System.Boolean, System.Boolean, System.Boolean, app.ItemManager.GetItemEventType, System.Boolean, System.Boolean)")
        m:call(mgr, id, 1, ch, true, false, false, nil, true, false)
    end)

    -- 2. re-add it with an enhancement and see whether the level sticks
    _log("step 2: add one WITH enhancement " .. M.test_enh)
    if not _give_back(id, M.test_enh, 0, 0, 0) then
        last = "FAILED: addStorageNoLock threw"; _log(last); return
    end

    -- 3. verify by reading the inventory back
    local got = _find(id, M.test_enh)
    if got then
        proven = true
        last = string.format("PASSED — item %d came back at +%d. Mounting unlocked.", id, M.test_enh)
        _log(last)
        _log("step 4: cleaning up the +" .. M.test_enh .. " spare")
        pcall(function() mgr:call("deleteItem(System.Int32, System.Int32, app.CharacterID)", id, 1, _cid()) end)
    else
        proven = false
        local any = _find(id)
        last = "FAILED — no +" .. M.test_enh .. " copy found"
            .. (any and (" (an unenhanced one exists, so the ADD ran but the enhancement did not stick)")
                     or " (nothing was added at all)")
        _log(last)
    end
    _log(string.rep("=", 70))
end

-- ── plaques ──────────────────────────────────────────────────────────────────────────
local function _upos(go)
    local p = nil
    pcall(function() p = go:call("get_Transform"):call("get_UniversalPosition") end)
    return p
end

local function _nearest_plaque()
    local sc, pl = nil, _player()
    pcall(function()
        sc = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),
             sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    end)
    if not (sc and pl) then return nil end
    local pgo = nil
    pcall(function() pgo = pl:call("get_GameObject") end)
    local pp = pgo and _upos(pgo)
    if not pp then return nil end

    local comps = nil
    pcall(function() comps = sc:call("findComponents(System.Type)", sdk.typeof("app.GimmickBase")) end)
    local best, bd = nil, 1e9
    local n = nil
    pcall(function() n = comps and comps:get_size() end)
    for i = 0, (n or 0) - 1 do
        pcall(function()
            local c = comps:get_element(i)
            local go = c and c:call("get_GameObject")
            if not go then return end
            local nm = tostring(go:call("get_Name") or "")
            if not nm:find(M.carrier, 1, true) then return end
            local gp = _upos(go)
            if not gp then return end
            local dx, dy, dz = gp.x - pp.x, gp.y - pp.y, gp.z - pp.z
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if d < bd and d <= M.reach then best, bd = { go = go, p = gp, d = d }, d end
        end)
    end
    return best
end

-- position key: survives despawn/respawn because IrisFurnish persists the same coords
local function _key(p) return string.format("%.1f_%.1f_%.1f", p.x, p.y, p.z) end

-- ── mount / retrieve ─────────────────────────────────────────────────────────────────
-- ⛔ THE WHOLE 2b BLOCK LIVES ABOVE _mount/_retrieve DELIBERATELY. They call
--    _wp_snapshot / _diff_paths / _kill_display, and a `local function` defined BELOW
--    its caller resolves to a nil GLOBAL — silent inside a pcall. luac cannot see it.
-- ══ SLICE 2b: THE WEAPON ON THE PLAQUE ═══════════════════════════════════════════════
-- ⭐ IDENTIFYING WHICH MESH IS THE WEAPON — by DIFFING ACROSS THE UNEQUIP, not by guessing.
--   A bare `^wp` name match also catches arrows and quivers (farming's "arrow lesson"), and
--   `app.Weapon.ID` is the WEAPON id (47220) not the ITEM id (34713), so it cannot be matched
--   against the storage row either. But mounting already unequips — so snapshot the wp
--   children BEFORE and AFTER, and whatever DISAPPEARED is exactly this weapon. Exact, no
--   lookup table, no heuristics.
-- ⛔ create_resource on a path the engine cannot serve CRASHES — but every path here was READ
--   off a mesh the game had already loaded, so it is guaranteed servable. Never let a
--   hand-typed weapon path into this.
local disp = { live = {}, q = {} }

local function _mesh_paths_of(go, out)
    out = out or {}
    pcall(function()
        local mc = go:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
        if mc then
            local p = nil
            pcall(function() p = tostring(mc:call("getMesh"):call("get_ResourcePath")) end)
            if p and p ~= "" and p ~= "nil" then out[p] = true end
        end
        local tf = go:call("get_Transform")
        local ch = tf and tf:call("get_Child")
        local n = 0
        while ch and n < 16 do
            n = n + 1
            local cgo = nil
            pcall(function() cgo = ch:call("get_GameObject") end)
            if cgo then _mesh_paths_of(cgo, out) end
            local nx = nil
            pcall(function() nx = ch:call("get_Next") end)
            ch = nx
        end
    end)
    return out
end

-- every mesh path currently hanging off the player under a `wp*` child
local function _wp_snapshot()
    local out = {}
    pcall(function()
        local pl = _player()
        local pgo = pl and pl:call("get_GameObject")
        local tf = pgo and pgo:call("get_Transform")
        local ch = tf and tf:call("get_Child")
        local n = 0
        while ch and n < 40 do
            n = n + 1
            pcall(function()
                local go = ch:call("get_GameObject")
                local nm = go and tostring(go:call("get_Name") or "")
                if nm:find("^wp") then _mesh_paths_of(go, out) end
            end)
            local nx = nil
            pcall(function() nx = ch:call("get_Next") end)
            ch = nx
        end
    end)
    return out
end

local function _diff_paths(before, after)
    for p in pairs(before) do
        if not after[p] then return p end     -- vanished with the unequip = this weapon
    end
    return nil
end

-- ⛔⛔ THE DIFF IDEA WAS WRONG (field log 01:13:45: "nothing vanished from the wp children").
--   The weapon's GameObject does NOT tear down in the same tick as the unequip — the model
--   removal is deferred — so the before/after snapshots are identical and the diff finds
--   nothing. Elegant, and simply not how the engine behaves.
-- ⭐ THE EXACT ROUTE, and it needs no timing at all: match by WEAPON ID.
--   `app.ItemWeaponParam._WeaponId` points an ITEM at its WEAPON entity (item 34713 -> weapon
--   47220 for the hoe), and each `wp*` child carries an `app.Weapon` whose ID is that weapon
--   id. So read the item's _WeaponId, walk the wp children, and take the one that matches.
--   Deterministic, no diff, no frame delay — and it works for an unequipped weapon too if it
--   happens to be rendered.
--   ⚠ The three-way ID read is farming's: the field name varies by build.
local function _weapon_id_of_item(itemId)
    local wid = nil
    pcall(function()
        local d = _im():call("getItemData(System.Int32)", itemId)
        if not d then return end
        pcall(function() wid = d:get_field("_WeaponId") end)
        if wid == nil then pcall(function() wid = d:call("get_WeaponId") end) end
    end)
    return tonumber(wid)
end

local function _mesh_for_weapon(itemId)
    local want = _weapon_id_of_item(itemId)
    local found, seen = nil, {}
    pcall(function()
        local pl = _player()
        local pgo = pl and pl:call("get_GameObject")
        local tf = pgo and pgo:call("get_Transform")
        local ch = tf and tf:call("get_Child")
        local n = 0
        while ch and n < 40 do
            n = n + 1
            pcall(function()
                local go = ch:call("get_GameObject")
                local nm = go and tostring(go:call("get_Name") or "")
                if nm:find("^wp") then
                    local w = go:call("getComponent(System.Type)", sdk.typeof("app.Weapon"))
                    local id = nil
                    if w then
                        pcall(function() id = w:get_field("ID") end)
                        if id == nil then pcall(function() id = w:get_field("<ID>k__BackingField") end) end
                        if id == nil then pcall(function() id = w:call("get_ID") end) end
                    end
                    local paths = _mesh_paths_of(go)
                    local first = nil
                    for p in pairs(paths) do first = first or p end
                    seen[#seen + 1] = string.format("%s(id=%s, mesh=%s)", nm, tostring(id), tostring(first))
                    if want and tonumber(id) == want and first then found = first end
                end
            end)
            local nx = nil
            pcall(function() nx = ch:call("get_Next") end)
            ch = nx
        end
    end)
    -- ⭐ always log the candidates: a miss must be diagnosable in one read, not another round
    _log("wp children seen: " .. (#seen > 0 and table.concat(seen, ", ") or "NONE")
         .. "  | item " .. tostring(itemId) .. " -> weaponId " .. tostring(want))
    if found then return found end
    -- fallback: exactly one wp child with a real weapon mesh is unambiguous anyway
    local only, cnt = nil, 0
    for _, s in ipairs(seen) do
        local p = s:match("mesh=([^)]+)")
        if p and p ~= "nil" and p:lower():find("/wp") then cnt = cnt + 1; only = p end
    end
    if cnt == 1 then _log("wp match fell back to the only weapon mesh present: " .. only); return only end
    return nil
end

-- ⭐⭐ WARM THE MOUNTED WEAPONS' MESHES AT LOAD (Aurora 08-09: "I tried reloading the save
--   with a weapon mounted and it was invisible"). This is the COLD RESOURCE LAW again, and it
--   is why it worked in-session but not across a reload:
--     • mounting in-session: the weapon was ON HER BODY, so its mesh was already loaded and
--       the bind had something real to grab.
--     • after a reload: nothing in the world references that weapon, so the resource is cold.
--       `create_resource` returns something, the bind reports MaterialNum > 0, and it draws
--       NOTHING. Cold resources lie — exactly the farmland's invisible-until-reset bug.
--   ⇒ create the resources EARLY and HOLD REFS, then let the streamer have a beat before the
--   first bind. Same `boot_at` one-shot the farmland uses.
-- ⛔ Only paths that came from a live mesh ever get here (they were read off the equipped
--   weapon), so create_resource cannot be handed a path the engine can't serve — which would
--   be an instant crash, not a nil.
local wres = { warmed = false, boot_at = nil, refs = {} }
local function _warm_mounted()
    if wres.warmed then return end
    wres.warmed = true
    _load()
    local n = 0
    for _, rec in pairs(mounts) do
        if rec.mesh then
            pcall(function()
                local r = sdk.create_resource("via.render.MeshResource", rec.mesh)
                if r then wres.refs[#wres.refs + 1] = r:add_ref(); n = n + 1 end
                local m = sdk.create_resource("via.render.MeshMaterialResource",
                                              rec.mesh:gsub("%.mesh$", ".mdf2"))
                if m then wres.refs[#wres.refs + 1] = m:add_ref() end
            end)
        end
    end
    _log("warmed " .. n .. " mounted-weapon mesh(es) so they survive a reload")
end

local function _kill_display(k)
    local d = disp.live[k]
    if not d then return end
    pcall(function() if d.go:call("get_Valid") == true then d.go:call("destroy", d.go) end end)
    pcall(function() d.go:release() end)
    disp.live[k] = nil
end

local function _drop_displays()
    for k in pairs(disp.live) do _kill_display(k) end
    disp.q = {}
end

local function _bind_display(mc, meshpath)
    local ok = false
    pcall(function()
        local res = sdk.create_resource("via.render.MeshResource", meshpath)
        if res then
            local h = res:add_ref():create_holder("via.render.MeshResourceHolder"):add_ref()
            if not pcall(function() mc:call("setMesh", h) end) then
                pcall(function() mc:call("set_Mesh", h) end)
            end
            ok = true
        end
        -- ⭐ the mdf2 sits beside the mesh under the same name — wp meshes are completely
        --   regular (`character/wp/wpNN/MMM/wpNN_MMM.mesh` + `.mdf2`), so swapping the
        --   extension beats another API guess at reading the material path.
        local mdf = meshpath:gsub("%.mesh$", ".mdf2")
        local mt = sdk.create_resource("via.render.MeshMaterialResource", mdf)
        if mt then
            local mh = mt:add_ref():create_holder("via.render.MeshMaterialResourceHolder"):add_ref()
            if not pcall(function() mc:call("set_Material", mh) end) then
                pcall(function() mc:call("setMaterial", mh) end)
            end
        end
        pcall(function() mc:call("set_Enabled", true) end)
    end)
    return ok
end

-- rotate a vector by a quaternion, in pure Lua. ⛔ Done by hand deliberately rather than
--   guessing at a via.Quaternion multiply overload — an unresolved method inside a pcall
--   fails silently, and a silently-unrotated offset is exactly the bug being fixed here.
--   v' = v + 2 * cross(q.xyz, cross(q.xyz, v) + q.w * v)
-- Hamilton product a*b, in pure Lua. ⛔ Same reasoning as _rotate_vec: v1 tried
--   `pr:call("mul(via.Quaternion)", q)` and fell back to `q` when it threw. The overload
--   evidently does not resolve, the pcall ate it, and the fallback applied the offset
--   rotation with NO plaque rotation — which is why one plaque looked perfect (its rotation
--   is near-identity, so right and wrong coincide) and the next hung the sword sideways.
-- ⭐ THE LESSON: a fallback that produces PLAUSIBLE output hides the failure it is catching.
--   Either compute it properly or let it fail loudly; never quietly substitute a half-answer.
local function _quat_mul(a, b)
    return {
        w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
        x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
    }
end

local function _rotate_vec(q, x, y, z)
    local qx, qy, qz, qw = q.x, q.y, q.z, q.w
    local tx = 2 * (qy * z - qz * y)
    local ty = 2 * (qz * x - qx * z)
    local tz = 2 * (qx * y - qy * x)
    return x + qw * tx + (qy * tz - qz * ty),
           y + qw * ty + (qz * tx - qx * tz),
           z + qw * tz + (qx * ty - qy * tx)
end

-- place the prop relative to the plaque, IN THE PLAQUE'S OWN FRAME
-- ⛔⛔ v1 added the offset in WORLD axes (Aurora 08-09: "what if I were to put a plaque on a
--   different wall?" — exactly the right question). A world-space offset means "20cm north",
--   so the same numbers that hang the sword nicely on one wall drive it INTO the next one.
--   Rotating the offset by the plaque's own rotation makes it mean "20cm in front of the
--   plaque, 30cm up its face" — orientation-independent, so one setting fits every wall.
local function _place_display(go, plaque_go)
    pcall(function()
        local ptf = plaque_go:call("get_Transform")
        local pp  = ptf:call("get_Position")            -- RENDER space, same as the prop wants
        local pr  = ptf:call("get_Rotation")
        local t   = go:call("get_Transform")
        -- compose our offset rotation ONTO the plaque's own, in Lua, so the sword turns with
        -- whatever wall the plaque is on (never invent a rotation from scratch — the R20 law)
        local e = _euler_quat(M.disp_yaw or 0, M.disp_pitch or 0, M.disp_roll or 0)
        local c = _quat_mul(pr, e)
        local q = ValueType.new(sdk.find_type_definition("via.Quaternion"))
        q.x, q.y, q.z, q.w = c.x, c.y, c.z, c.w
        t:call("set_Rotation", q)
        -- the offset now travels through the plaque's rotation before being applied
        local ox, oy, oz = _rotate_vec(pr, M.disp_x or 0, M.disp_y or 0, M.disp_z or 0)
        t:call("set_Position", Vector3f.new(pp.x + ox, pp.y + oy, pp.z + oz))
        t:call("set_LocalScale", Vector3f.new(M.disp_scale or 1.0, M.disp_scale or 1.0, M.disp_scale or 1.0))
    end)
end

local function _spawn_display(k, rec, plaque_go)
    if disp.live[k] or not (rec and rec.mesh) then return end
    local go = nil
    pcall(function()
        go = sdk.find_type_definition("via.GameObject"):get_method("create(System.String)")
             :call(nil, "IrisMountedWeapon")
    end)
    if not go then _log("display: GameObject create failed"); return end
    pcall(function() go = go:add_ref() end)
    pcall(function() go:call("set_DrawSelf", true); go:call("set_UpdateSelf", true) end)
    local mc = nil
    pcall(function() mc = go:call("createComponent(System.Type)", sdk.typeof("via.render.Mesh")) end)
    if not mc then
        pcall(function() go:call("destroy", go) end)
        _log("display: Mesh component create failed"); return
    end
    _bind_display(mc, rec.mesh)
    _place_display(go, plaque_go)
    disp.live[k] = { go = go, mc = mc, mesh = rec.mesh, plaque = plaque_go }
    -- ⛔ a cold first bind renders NOTHING — re-bind ~1.2s later (the double-bind law)
    disp.q[#disp.q + 1] = { k = k, at = os.clock() + 1.2 }
    _log("display: spawned " .. tostring(rec.name) .. " -> " .. tostring(rec.mesh))
end

local function _mount(w)
    _load()
    -- ⛔⛔ THIS IS WHY "PRESSING E DID NOTHING" (Aurora 08-09). Mounting IS implemented — but
    --   `proven` resets to false on every script reset, so the world label cheerfully offered
    --   "Hang up Lifetaker" and the press was refused in silence, with only the imgui panel's
    --   `last` line saying so. **A world prompt that advertises an action must never refuse
    --   invisibly.** Aurora also waived this gate twice ("I'll just spawn it back with Nick's
    --   dev tools"), so it is now OFF by default and the refusal is logged loudly when on.
    if M.require_test and not proven then
        last = "REFUSED: run the self-test first (or untick 'require self-test')"
        _log("MOUNT REFUSED: self-test not passed this session — " .. tostring(w.name)
             .. " was NOT taken. Untick 'require self-test' or press RUN SELF-TEST.")
        return
    end
    local pq = _nearest_plaque()
    if not pq then last = "no plaque within " .. M.reach .. "m"; _log(last); return end
    local k = _key(pq.p)
    if mounts[k] then last = "that plaque already holds " .. tostring(mounts[k].name); _log(last); return end

    -- ⭐ RECORD FIRST, DELETE SECOND. If anything dies in between, the weapon is written
    --   down and recoverable; the reverse order loses it outright.
    mounts[k] = { item = w.id, name = w.name, num = w.num, t0 = w.t0, t1 = w.t1, t2 = w.t2 }
    _save()
    _log(string.format("MOUNT %s (id=%d +%d) at plaque %s — record saved, now deleting",
        w.name, w.id, w.num, k))

    -- ⭐⭐ UNEQUIP FIRST (Aurora 08-09: "when I click mount with the weapon I have equipped,
    --   it doesn't come off me"). An EQUIPPED weapon is still referenced by the equip slot,
    --   so deleting its storage row leaves the model on the body. `removeEquip` is the
    --   proper, model-managing reverse of setEquip, and `applyEquipChange` is what actually
    --   updates the character — without it the change is bookkeeping only.
    --   Exact signature cribbed from RiftSpeak/inventory.lua:526.
    local equipped = false
    pcall(function() equipped = w.sd:call("get_IsEquipped") == true end)
    -- ⭐ resolve the weapon's mesh BEFORE the unequip, while it is definitely rendered.
    --   By weapon ID, not by diffing — the diff never fired because the model teardown is
    --   deferred past the tick we snapshot in.
    local wp_mesh = _mesh_for_weapon(w.id)
    if equipped then
        local ch = _player()
        _log("mount: " .. tostring(w.name) .. " is EQUIPPED - unequipping before delete")
        pcall(function()
            _im():call("removeEquip(app.ItemDefine.StorageData, app.Character, System.Boolean, System.Boolean)",
                w.sd:call("get_Param"), ch, true, true)
        end)
        pcall(function() _im():call("applyEquipChange") end)
        -- verify it actually came off; a silent failure here would delete a worn weapon
        local still = false
        pcall(function() still = w.sd:call("get_IsEquipped") == true end)
        _log("mount: unequip -> still equipped = " .. tostring(still))
        if still then
            last = "could not unequip " .. tostring(w.name) .. " - NOT deleting it"
            _log(last)
            mounts[k] = nil; _save()          -- roll the record back, nothing was taken
            return
        end
    end

    local ok = pcall(function()
        _im():call("deleteItem(app.ItemDefine.StorageData, System.Int32)", w.sd:call("get_Param"), 1)
    end)
    if not ok then
        -- fall back to the by-id delete; StorageData overload can be fussy
        ok = pcall(function()
            _im():call("deleteItem(System.Int32, System.Int32, app.CharacterID)", w.id, 1, _cid())
        end)
    end
    _log("delete ok=" .. tostring(ok))
    if ok then
        -- ⭐ resolve WHICH mesh was this weapon, now that it has left the body
        if wp_mesh then
            mounts[k].mesh = wp_mesh
            _save()
            _log("mount: captured weapon mesh -> " .. wp_mesh)
        else
            _log("mount: could not identify the weapon mesh - it will mount with no display. "
                 .. "See the 'wp children seen:' line above for what WAS on the body.")
        end
        last = "mounted " .. tostring(w.name) .. " (+" .. tostring(w.num) .. ")"
    else
        -- the record stays either way: a kept record with the weapon still in the bag is
        -- a harmless duplicate you can clear, whereas a cleared record with the weapon
        -- deleted is a weapon gone forever.
        last = "DELETE FAILED — record kept, " .. tostring(w.name) .. " is still in your bag"
    end
end

-- ⛔⛔ THE VERIFY MUST NOT RUN IN THE SAME TICK AS THE ADD (Aurora 08-09: "the first time
--   after a script reset it's not in your equipment, you have to retrieve it again").
--   DD2 QUEUES storage changes — `addStorageEvent` / `updateStorageEvent` are right there in
--   the API — so `getStorageMasterList` does not show the new row until a later update. My
--   same-tick `_find` therefore failed, the record stayed, and her SECOND press is what
--   appeared to work. ⚠ Worse: the first add may well have landed anyway, so a retry could
--   duplicate the weapon. Split into add-now / verify-later, and refuse a second attempt
--   while one is in flight.
--   (Same lesson as the register() sentinel earlier: never judge an engine mutation on a
--   same-frame read.)
local function _retrieve(k)
    _load()
    local rec = mounts[k]
    if not rec then last = "nothing mounted there"; return end
    if rec.returning and (os.clock() - rec.returning) < 3.0 then
        last = "already handing that back - give it a moment"
        _log("retrieve: ignored, a return is already in flight for " .. tostring(rec.name))
        return
    end
    _log(string.format("RETRIEVE %s (id=%d +%d) from %s", tostring(rec.name), rec.item, rec.num or 0, k))
    rec.returning = os.clock()
    _save()
    if not _give_back(rec.item, rec.num or 0, rec.t0, rec.t1, rec.t2) then
        rec.returning = nil; _save()
        last = "give-back FAILED — record kept, nothing lost"; _log(last); return
    end
    -- verify on a LATER tick; the pump runs this once the storage event has been applied
    Q[#Q + 1] = { k = "verify", key = k, at = os.clock() + 0.6 }
    last = "handing back " .. tostring(rec.name) .. "..."
end

local function _verify_return(k)
    _load()
    local rec = mounts[k]
    if not rec then return end
    local got = _find(rec.item, rec.num or 0)
    if got then
        mounts[k] = nil; _save()
        _kill_display(k)                 -- the sword leaves the wall the moment you take it
        last = string.format("returned %s at +%d", tostring(rec.name), rec.num or 0)

        -- ⭐ AUTO-EQUIP IF HANDS ARE EMPTY (Aurora 08-09). Deliberately CONDITIONAL: if she
        --   is already holding something, silently swapping her weapon mid-play would be
        --   worse than leaving it in the bag. Only fills an empty main hand.
        -- ⛔ Own it: `auto_equip` existed as a config flag and was never implemented — I said
        --   it re-equipped and it did not. Now it does.
        if M.auto_equip ~= false and _equipped_weapon() == nil then
            local ch, mgr = _player(), _im()
            local ok = false
            pcall(function()
                local data = mgr:call("getItemData(System.Int32)", rec.item)
                if not data then return end
                -- slot comes from EquipCategory (weapons Main=0/Sub=1), the same derivation
                -- RiftSpeak/inventory.lua:418-425 uses, through the proper model-managing
                -- pipeline rather than poking equip state directly
                local catn = tonumber(data:call("get_EquipCategory"))
                if not catn or catn < 0 then return end
                local slot = (catn == 7) and 8 or catn
                ok = pcall(function()
                    mgr:call("setEquip(app.ItemDefine.StorageData, app.Character, app.EquipData.SlotEnum, System.Boolean, System.Boolean)",
                        got.sd:call("get_Param"), ch, slot, true, true)
                end)
            end)
            -- ⛔ without applyEquipChange the change is bookkeeping only and the model never
            --   updates — the same half of the pair that made unequip look broken
            pcall(function() mgr:call("applyEquipChange") end)
            local worn = (_equipped_weapon() ~= nil)
            _log(string.format("auto-equip %s: called=%s, now holding something=%s",
                tostring(rec.name), tostring(ok), tostring(worn)))
            if worn then last = last .. " and equipped it" end
        end
    else
        rec.returning = nil; _save()
        last = "add ran but the item was not found — record KEPT so you can retry"
    end
    _log(last)
end

-- ══ THE IN-WORLD INTERACT ════════════════════════════════════════════════════════════
-- Press at a plaque: empty -> hang up whatever you are holding; full -> take it back.
local IW = { at = 0, target = nil, key_prev = false, pad_prev = false, pad_bit = nil, hooked = false }

-- ⛔ Resolve the pad bit ONCE and LOG if the name does not exist. Never fall through a
--   fallback chain silently — farming's `_pad_bit` walked past a missing "B" all the way
--   to RDown, so the prompt advertised one button while another one worked.
-- ⭐ resolved through the SHARED resolver so every IRIS module agrees on what "B" is, and
--   the real field list lands in IrisPromptBar.log once rather than being guessed per file.
local function _pad_down()
    if IW.pad_bit == nil then
        IW.pad_bit = 0
        if _G.IrisPad and _G.IrisPad.bit then
            local b, nm = _G.IrisPad.bit(M.pad, "Cancel", "RRight", "B", "Circle")
            IW.pad_bit = b or 0
            if nm then M.pad = nm end
            _log("pad button for the plaque resolved to '" .. tostring(nm) .. "' = " .. tostring(b))
        end
    end
    if not IW.pad_bit or IW.pad_bit == 0 then return false end
    if _G.IrisPad and _G.IrisPad.down then return _G.IrisPad.down(IW.pad_bit) end
    return false
end

-- ⛔⛔ DO NOT ACT WHILE A MENU IS UP (Aurora 08-09: "the plaques might be registering presses
--   that are in the pause menus"). She is right — v1 had no gate at all, so an A in the pause
--   menu, the inventory, a native dialog or the furnish shop reached the plaque and mounted or
--   retrieved a weapon behind her back. Farming has guarded this since 07-26 and I did not
--   copy it. ⚠ Also holds the key/pad edges DOWN while blocked, or the press that dismissed
--   the menu becomes an unseen edge and fires the moment it closes (farming's double-cancel).
local function _blocked()
    local b = false
    pcall(function()
        local pm = sdk.get_managed_singleton("app.PauseManager")
        if pm and pm:call("isPausedAny") == true then b = true end
    end)
    if b then return true end
    -- REFramework's own overlay: the click that dismisses it also reaches the game
    pcall(function() if reframework:is_drawing_ui() then b = true end end)
    -- and any RiftSpeak/cooperating text box -- typing must never yank a weapon off the wall
    if _G.RiftSpeak_PromptOpen == true or _G.RiftSpeak_ExternalTyping == true then b = true end
    if b then return true end
    -- and our own decorator, which owns the pad while it is open
    pcall(function() if _G.IrisFurnishUIOpen then b = true end end)
    -- ⭐ NOT WHILE SEATED (Aurora 08-09: "make sure you can't mount/retrieve your weapon when
    --   sitting in a chair"). A seated Arisen is mid-interact with the hidden native seat, and
    --   pulling a sword out of the wall from a chair both looks absurd and fights whatever
    --   owns the body. `isInteracting(Character)` is a READ on InteractManager — the same
    --   family of reads exercised safely all evening — and it covers every native interact,
    --   not just chairs.
    pcall(function()
        local im = sdk.get_managed_singleton("app.InteractManager")
        local pl = _player()
        if im and pl and im:call("isInteracting", pl) == true then b = true end
    end)
    return b
end

local function _iw_scan()
    if M.prompt == false then IW.target = nil; return end
    local now = os.clock()
    if now - IW.at < 0.3 then return end
    IW.at = now
    IW.target = _nearest_plaque()

    -- ⭐ publish the verb so the GAME'S OWN button panel reads "B Mount" / "B Take" instead
    --   of "B Dash" (IrisPromptBar). Priority 20: a plaque is a deliberate walk-up, so it
    --   should out-rank an ambient prompt like a crop bed you happen to be standing near.
    if _G.IrisPrompt then
        if IW.target and not _blocked() then
            _load()
            local rec = mounts[_key(IW.target.p)]
            -- ⭐ publish the DISTANCE too: the arbiter picks the nearest interactable, so a
            --   cookpot a metre closer takes the button instead of both firing.
            local d = IW.target.d or 1e9
            if rec then
                _G.IrisPrompt.set("weapon_mount", "Take", 20, d)
            elseif _equipped_weapon() then
                _G.IrisPrompt.set("weapon_mount", "Mount", 20, d)
            else
                _G.IrisPrompt.clear("weapon_mount")
            end
        else
            _G.IrisPrompt.clear("weapon_mount")
        end
    end
end

local function _iw_input()
    if _blocked() then
        -- keep the edges primed so releasing inside a menu is not seen as a fresh press
        pcall(function() IW.key_prev = reframework:is_key_down(M.key) end)
        IW.pad_prev = _pad_down()
        return
    end
    if not IW.target then IW.key_prev, IW.pad_prev = false, false; return end
    local kd, pd = false, false
    pcall(function() kd = reframework:is_key_down(M.key) end)
    pd = _pad_down()
    local fire = (kd and not IW.key_prev) or (pd and not IW.pad_prev)
    IW.key_prev, IW.pad_prev = kd, pd
    if not fire then return end

    -- ⛔ ONE ACTION AT A TIME. Publishing a prompt no longer entitles us to act — the
    --   arbiter decides who is nearest, and the game's own interact outranks all of us.
    --   ⚠ the edges are consumed ABOVE this point on purpose: if we bailed before updating
    --   key_prev/pad_prev, the press would still be "new" next frame and fire the moment we
    --   became the winner — which is precisely the queued-interact-after-the-menu bug.
    if _G.IrisPrompt then
        if _G.IrisPrompt.native_busy() then
            _log("press ignored: the game is offering its own interact here")
            return
        end
        local w = _G.IrisPrompt.winner()
        if w and w ~= "weapon_mount" then
            _log("press ignored: '" .. tostring(w) .. "' is nearer")
            return
        end
    end

    _load()
    local k = _key(IW.target.p)
    if mounts[k] then
        Q[#Q + 1] = { k = "retrieve", key = k }
    else
        local w = _equipped_weapon()
        if not w then last = "nothing equipped to hang up"; _log(last); return end
        Q[#Q + 1] = { k = "mount", w = w }
    end
end

-- ⭐ A is DD2's jump, so every press would also hop. The gate is POSITIONAL ("am I at a
--   plaque"), never "was the key just pressed" — a keypress gate races the engine's input
--   pass against our tick, so the jump can fire before we ever see the button.
-- ⛔ ACTION level (requestActionCore, matched BY NAME). NEVER the input-processor route:
--   farming tried that and it froze ALL movement, not just jumping.
-- ⛔ Hooks are permanent until the process exits, and a script reset ORPHANS the old one
--   with its captured locals still live — so install exactly once, and read mutable state
--   through a _G table every generation points at.
-- ⛔⛔ v1 OF THIS BLOCK WAS WRONG IN THREE WAYS AND SILENTLY DID NOTHING (Aurora 08-09:
--   "pressing A jumps"). Corrected against the WORKING one in IrisFarming.lua:3213-3244:
--     1. the method needs its FULL signature —
--        `requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)`.
--        A bare `get_method("requestActionCore")` does not resolve the overload.
--     2. the args are `args[2]` = the ActionManager (this) and `args[4]` = the action NAME.
--        v1 read args[3] and called get_Name() on it; it is a System.String, so ToString().
--     3. **pawns and enemies request through this same call**, so without checking the
--        ActionManager belongs to the PLAYER you either block nothing or block everyone.
_G.IrisWeaponMountState = _G.IrisWeaponMountState or {}
local S = _G.IrisWeaponMountState
S.at_plaque = false
S.seen = S.seen or {}
if not S.hooked then
    pcall(function()
        local m = sdk.find_type_definition("app.ActionManager")
            :get_method("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)")
        if not m then _log("jump block: requestActionCore not found"); return end
        sdk.hook(m, function(args)
            if not S.at_plaque then return end
            local block = false
            pcall(function()
                local cm = sdk.get_managed_singleton("app.CharacterManager")
                local pl = cm and cm:call("get_ManualPlayer")
                local pam = pl and pl:call("get_ActionManager")
                local am = sdk.to_managed_object(args[2])
                if not (am and pam and am:get_address() == pam:get_address()) then return end
                local name = sdk.to_managed_object(args[4])
                local s = name and tostring(name:call("ToString()")) or ""
                -- ⭐ B is DD2's dodge/dash as well as its interact, so moving our button to B
                --   means suppressing the dodge the same way A needed the jump suppressed.
                --   Matched BY NAME and logged once per distinct action, so if some other
                --   dodge variant slips through, the log names it instead of us guessing.
                local hit = s:find("Jump")
                    or (M.block_dodge ~= false and (s:find("Dodge") or s:find("Dash")
                        or s:find("StepAvoid") or s:find("Avoid")))
                if hit then
                    if not S.seen[s] then
                        S.seen[s] = true
                        _log("input block: blocking action '" .. s .. "' at a plaque")
                    end
                    block = true
                end
            end)
            -- ⛔ the pcall above CANNOT return SKIP_ORIGINAL — it would escape the closure,
            -- not the hook. Set `block` inside and act on it out here.
            if block then return sdk.PreHookResult.SKIP_ORIGINAL end
        end, function(r) return r end)
        S.hooked = true
        _log("jump block: hooked requestActionCore (action-level, input pipeline untouched)")
    end)
end

-- ── display lifecycle: spawn the prop for any mounted plaque you are near, retire it when
--    you walk away, and run the cure re-bind. Mirrors IrisFurnish's distance lifecycle.
local dtick = { at = 0 }
local function _display_tick()
    if M.display == false then _drop_displays(); return end
    local now = os.clock()

    -- ⛔ warm BEFORE anything is allowed to spawn: a bind against a cold resource reports
    --   success and draws nothing, and the prop would then sit there invisible until you
    --   walked out of range and back.
    if not wres.warmed then
        if not wres.boot_at then wres.boot_at = now + 5.0; return end
        if now < wres.boot_at then return end
        pcall(_warm_mounted)
        return                                  -- give the streamer a beat before binding
    end

    -- cure pass first: a cold first bind renders nothing
    for i = #disp.q, 1, -1 do
        local j = disp.q[i]
        if now >= j.at then
            local d = disp.live[j.k]
            if d then
                local alive = false
                pcall(function() alive = d.go:call("get_Valid") == true end)
                if alive then
                    _bind_display(d.mc, d.mesh)
                    local mn = "?"
                    pcall(function() mn = tostring(d.mc:call("get_MaterialNum")) end)
                    _log("display CURED " .. tostring(d.mesh) .. " MaterialNum=" .. mn .. " (>0 = took)")
                end
            end
            table.remove(disp.q, i)
        end
    end

    if now - dtick.at < 1.0 then return end
    dtick.at = now
    _load()

    -- which mounted plaques are in range right now?
    local want = {}
    pcall(function()
        local sc = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),
                   sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        local pl = _player()
        local pgo = pl and pl:call("get_GameObject")
        local pp = pgo and _upos(pgo)
        if not (sc and pp) then return end
        local comps = sc:call("findComponents(System.Type)", sdk.typeof("app.GimmickBase"))
        local n = nil
        pcall(function() n = comps and comps:get_size() end)
        for i = 0, (n or 0) - 1 do
            pcall(function()
                local c = comps:get_element(i)
                local go = c and c:call("get_GameObject")
                if not go then return end
                if not tostring(go:call("get_Name") or ""):find(M.carrier, 1, true) then return end
                local gp = _upos(go); if not gp then return end
                local dx, dz = gp.x - pp.x, gp.z - pp.z
                if math.sqrt(dx * dx + dz * dz) > (M.disp_range or 30.0) then return end
                local k = _key(gp)
                if mounts[k] and mounts[k].mesh then want[k] = go end
            end)
        end
    end)

    for k, go in pairs(want) do
        if not disp.live[k] then _spawn_display(k, mounts[k], go)
        else _place_display(disp.live[k].go, go) end     -- keep it pinned if sliders moved
    end
    for k in pairs(disp.live) do
        if not want[k] then _kill_display(k) end
    end
end

re.on_application_entry("UpdateBehavior", function()
    pcall(_iw_scan)
    pcall(_iw_input)
    pcall(_display_tick)
    S.at_plaque = (M.block_jump ~= false) and (IW.target ~= nil) or false
end)

re.on_frame(function()
    -- the label is a WORLD draw, so it must stand down while a menu is up for exactly the
    -- same reason the hoe ring does — otherwise "[E / A] Hang up Lifetaker" floats over the
    -- storage screen. Same instantaneous pause check, not a timed blackout.
    if _blocked() then return end
    if not (M.prompt ~= false and IW.target) then return end
    pcall(function()
        _load()
        local k = _key(IW.target.p)
        local rec = mounts[k]
        local msg
        if rec then
            msg = string.format("[E / %s]  Take %s", M.pad_label, tostring(rec.name))
        else
            local w = _equipped_weapon()
            msg = w and string.format("[E / %s]  Hang up %s", M.pad_label, tostring(w.name))
                    or "(equip a weapon to hang it here)"
        end
        local tf = IW.target.go:call("get_Transform")
        local p = tf and tf:call("get_Position")          -- RENDER space for world_to_screen
        if not p then return end
        -- ⛔ world_to_screen returns ONE vector (sp.x/sp.y), not two values
        local sp = draw.world_to_screen(Vector3f.new(p.x, p.y + (M.label_h or 1.0), p.z))
        if not sp then return end
        -- ⭐ USE THE IRIS FONT (Aurora 08-09: "it looks different to our usual label"). The
        --   cookpot/bed prompts render through `_G.IrisFont` in amber at size 19, centred by
        --   backing off half the string width; plain draw.text was the odd one out. Exact
        --   shape from IrisFarming.lua:4277-4279, including the fallback when the font
        --   module is absent — F.text returns falsy and draw.text takes over.
        local F = _G.IrisFont
        local x, y = sp.x - #msg * 3.5, sp.y
        if not (F and F.text and F.text(msg, x, y, 0xFFF0D8A0, 19)) then
            draw.text(msg, x, y, 0xFFF0D8A0)
        end
    end)
end)

-- ── job pump: game thread, ONE per tick (the no-lock law) ────────────────────────────
re.on_application_entry("UpdateBehavior", function()
    if #Q == 0 then return end
    -- ⭐ jobs may carry an `at` deadline (the deferred verify). Take the first one that is
    --   DUE rather than blindly the head, or a pending verify would block the queue behind
    --   it. Still exactly ONE engine job per tick — the no-lock law.
    local now, idx = os.clock(), nil
    for i, j in ipairs(Q) do
        if not j.at or now >= j.at then idx = i; break end
    end
    if not idx then return end
    local j = table.remove(Q, idx)
    if     j.k == "test"     then pcall(_selftest)
    elseif j.k == "mount"    then pcall(function() _mount(j.w) end)
    elseif j.k == "retrieve" then pcall(function() _retrieve(j.key) end)
    elseif j.k == "verify"   then pcall(function() _verify_return(j.key) end)
    end
end)

re.on_script_reset(function()
    Q = {}
    IW.target = nil
    -- ⛔⛔ MUST clear the shared flag. The jump-block hook is PERMANENT (REFramework has no
    --   unhook) and a script reset ORPHANS it with its upvalues still live. Resetting while
    --   stood at a plaque would otherwise leave `at_plaque = true` forever, and the orphaned
    --   hook would keep eating every jump for the rest of the process. Same class as the
    --   pacifist ghost: mutable state a permanent hook reads must be reset explicitly.
    S.at_plaque = false
    -- ⛔ DESTROY the display props on reset. An orphaned prop is an un-findable sword
    --   floating on a wall with nothing tracking it (IrisFurnish's orphan lesson).
    pcall(_drop_displays)
end)

-- ── panel ────────────────────────────────────────────────────────────────────────────
re.on_draw_ui(function()
    if not imgui.tree_node("IRIS WEAPON MOUNT (slice 1: custody, no display yet)") then return end
    _load()

    imgui.text("Hang a weapon on a plaque and get it back WITH its upgrade level.")
    imgui.text("last: " .. tostring(last))
    imgui.separator()

    imgui.text("STEP 1 — prove the round trip on a spare (never touches your real gear):")
    if imgui.button("RUN SELF-TEST") then Q[#Q + 1] = { k = "test" }; last = "queued..." end
    imgui.text("  grants a spare item " .. tostring(M.test_item) .. ", re-adds it at +"
               .. tostring(M.test_enh) .. ", checks the level stuck, deletes the spare")
    imgui.text("  self-test this session: " .. (proven and "PASSED" or "not run"))
    -- Aurora waived the gate twice, so it defaults OFF. Kept as a switch because it is the
    -- only thing standing between a broken re-add and a deleted weapon.
    local sc
    sc, M.require_test = imgui.checkbox("require the self-test before mounting (default off)", M.require_test == true)

    imgui.separator()
    local pq = _nearest_plaque()
    imgui.text("plaque in reach: " .. (pq and string.format("yes (%.1fm)", pq.d) or "no"))

    imgui.text("STEP 2 — your carried weapons:")
    local ws = _weapons()
    for i, w in ipairs(ws) do
        if i > 12 then break end
        imgui.text(string.format("  %-26s id=%-6d +%d", w.name, w.id, w.num))
        imgui.same_line()
        if imgui.button("MOUNT##wm" .. i) then Q[#Q + 1] = { k = "mount", w = w }; last = "queued..." end
    end
    if #ws == 0 then imgui.text("  (none)") end

    imgui.separator()
    imgui.text("MOUNTED:")
    local any = false
    for k, rec in pairs(mounts) do
        any = true
        imgui.text(string.format("  %-26s +%d   @%s", tostring(rec.name), rec.num or 0, k))
        imgui.same_line()
        if imgui.button("RETRIEVE##wr" .. k) then Q[#Q + 1] = { k = "retrieve", key = k }; last = "queued..." end
    end
    if not any then imgui.text("  (nothing mounted)") end

    imgui.separator()
    imgui.text("DISPLAY — where the weapon sits on the plaque (tune it live):")
    imgui.text("  (offsets are in the PLAQUE's own frame, so they hold on any wall)")
    local dc, ch = false, false
    dc, M.display    = imgui.checkbox("show the mounted weapon", M.display ~= false); ch = ch or dc
    dc, M.disp_x     = imgui.slider_float("  offset X (across the plaque)", M.disp_x or 0, -1.5, 1.5); ch = ch or dc
    dc, M.disp_y     = imgui.slider_float("  offset Y (up its face)", M.disp_y or 0, -1.5, 1.5); ch = ch or dc
    dc, M.disp_z     = imgui.slider_float("  offset Z (out from the wall)", M.disp_z or 0, -1.5, 1.5); ch = ch or dc
    dc, M.disp_yaw   = imgui.slider_float("  yaw",   M.disp_yaw or 0, -180, 180); ch = ch or dc
    dc, M.disp_pitch = imgui.slider_float("  pitch", M.disp_pitch or 0, -180, 180); ch = ch or dc
    dc, M.disp_roll  = imgui.slider_float("  roll",  M.disp_roll or 0, -180, 180); ch = ch or dc
    dc, M.disp_scale = imgui.slider_float("  scale", M.disp_scale or 1.0, 0.2, 3.0); ch = ch or dc
    -- save on CHANGE only; writing every frame would hammer the disk while a slider is dragged
    if ch then _save_cfg() end
    local nlive = 0
    for _ in pairs(disp.live) do nlive = nlive + 1 end
    imgui.text(string.format("  %d display prop(s) live", nlive))

    imgui.separator()
    local c
    c, M.reach     = imgui.slider_float("plaque reach (m)", M.reach, 1.0, 8.0)
    c, M.test_item = imgui.drag_int("self-test item id", M.test_item, 1, 1, 40000)
    c, M.test_enh  = imgui.drag_int("self-test enhance level", M.test_enh, 1, 1, 9)
    c, M.log       = imgui.checkbox("write the log", M.log)

    imgui.tree_pop()
end)

_log("IrisWeaponMount loaded — mounting is REFUSED until the self-test passes")
