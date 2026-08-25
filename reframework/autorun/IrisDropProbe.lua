-- ============================================================================
-- IrisDropProbe.lua — "drop the equipped thing on the ground" hotkey + probe
-- ============================================================================
-- Built 2026-08-24 to answer Arrythmia's putItem crash, and to settle OUR OWN
-- abandoned question (IrisTaming.lua:5971/6115: the 6-arg putItem "crashed the
-- game natively", the 3-arg one "proved a silent no-op", so the feeding ritual
-- was rewritten as a display prop and drop_item_begin/_check were orphaned).
--
-- ⭐ REAL CALLER BUG FOUND 08-24, read off il2cpp_dump.json — THE STORAGE TYPE:
--   getStorageMasterList(app.CharacterID) returns
--       List<app.ItemManager.StorageMasterData>   <- parent System.Object = a CLASS
--   but putItem/deleteItem/removeEquip all declare
--       app.ItemDefine.StorageData                <- parent System.ValueType
--   Runtime/TDB73: get_size=0x30 is the BOXED size (0x10 header + 0x20 payload).
--   The actual by-value StorageData payload is get_valuetype_size=0x20 = 32 bytes.
--   IrisWeaponMount converts (`row:call("get_Param")`) and works in-game.
--   IrisTaming.lua:5983 passed the ROW RAW -- a class reference handed to a
--   by-value struct param. That must be corrected in Arrythmia's caller, but the
--   clean-room probe still crashes after passing get_Param() correctly, so it is
--   not the recurring-cycle cause by itself.
--
-- ⭐ BUG #2, same dump — THE POSITION TYPE:
--   the 6-arg overload's `universalPosition` is `via.Position` = THREE
--   System.Doubles = 24 bytes (x@0x0, y@0x8, z@0x10). It is NOT a Vector3f
--   (floats, 12-16 bytes). Hand it a Vector3f and the marshaller copies 24
--   bytes out of a 16-byte buffer -- an 8-byte over-read on EVERY call, which
--   corrupts the heap and crashes minutes later somewhere unrelated.
--   Safest fix: never build one. get_UniversalPosition() already returns one.
--
-- ❌ RULED OUT — copied StorageData / _ItemData lifetime. See _fetch_storage.
--   StorageData's first field is a MANAGED POINTER (_ItemData @0x0). get_Param()
--   copies the value payload into a Lua buffer that is NOT a GC root, so anything that allocates
--   between the copy and the native call can leave it dangling. This is the
--   "crashes after a bit" shape, and the most likely thing biting Arrythmia.
--   Taking the struct last and holding a keepalive wrapper still crashed. Passing
--   the live embedded row payload instead of a ValueType copy also still crashed.
--
-- ⚠ VALUE-TYPE LAW: get_Param() returns a COPY of the struct. After an unequip
--   that copy is STALE (it still says equipped). RE-FETCH after mutating.
--
-- ✅ RESULTS 2026-08-24 (Aurora, in-game):
--   * EQUIPPED backpack -> FULL native drop: correct mesh (gm82_000_02), light
--     shaft, name label, the game's own "F Pick Up" prompt. have 1->0.
--   * `droplist nil->nil` -- get_DropItemList did not even resolve. It is USELESS
--     as a detector, exactly as IrisTaming.lua:14036 warned. Bag count + mesh scan
--     are the honest signals.
--   * ✅ RULED OUT: `_ItemDropId: 0` is harmless. A ContentEditor custom item drops
--     and renders identically to a vanilla one.
--   * ❌ Second press CTD'd (see BUG #3). It happened to be un-equipped that time,
--     but with n=1 each way that correlation is NOT established -- do not "fix" it
--     with an equipped-state guard, that would only hide a timing bug.
--   * ⭐ REPRO CONFIRMED vs Arrythmia: he reports "usually 3-4 cycles of dropping and
--     picking the thing back up", 4 seconds to 10+ minutes. Aurora crashed on the
--     3rd/4th, twice. Same bug in two independent mods.
--   * ✅ RULED OUT #2 -- DumpedList overflow. DumpedItemMax = 100; the list peaked at
--     1 and pickup correctly retired BOTH the DumpedData entry and the gm82 gimmick
--     (1 -> 0). No leak. The CTD lands after putItem returns, often on a worker
--     thread, with zero Lua release warnings. Dumps include async null reads and a
--     corrupted callback-shaped target; "heap corruption" remains a hypothesis,
--     not a diagnosis.
--   * ❌ RULED OUT -- Lua call origin as the sole cause. Replacing a real menu
--     discard's StorageData with backpack data still crashed on cycle 11.
--   * 🔴 THE LIVE LEAD: putItem returned ok=true and DID NOTHING (have 1->1, no mesh)
--     on a call identical to one that worked 90s earlier => it silently declines on
--     state we never check. Hence the isDumpEnable gate, now wired in.
--
-- Laws obeyed: game thread only (UpdateBehavior), one engine job per tick, the
-- shared input gate (000IrisInputGate), no Lua wrapper held past its object.
-- We never modify AdventurersBackpack.lua -- read only, it is not our mod.
-- ============================================================================

local CFG = "IrisDropProbe.json"

local M = {
    hotkey      = 0xDC,     -- '\' -- checked clear of every other IRIS default
    item_id     = 52800,    -- Adventurer's Backpack. 0 = match by name instead
    native_swap_item_id = 184, -- control payload for the game-menu carrier test
    match       = "backpack",
    count       = 1,
    use_6arg    = false,    -- ⛔ OFF by default: this overload native-crashed us before
    gate_dump   = true,     -- refuse the drop when the engine's isDumpEnable says no
    clear_is_new = false,   -- EXPERIMENT: mimic the inventory UI acknowledging a picked-up item
    live_row_arg = false,   -- EXPERIMENT: bypass REFramework's copied ValueType argument buffer
    mesh_scan   = true,
    verbose     = true,
}

do
    local ok, saved = pcall(json.load_file, CFG)
    if ok and type(saved) == "table" then
        for k, v in pairs(saved) do if M[k] ~= nil then M[k] = v end end
    end
end
local function _save() pcall(json.dump_file, CFG, M) end

local Q, LOG, last = {}, {}, "idle"

-- Pure-Lua escape hatch for the unstable StorageData-by-value reflection path.
-- We capture the game's real inventory controller while its menu is alive, then
-- ask that controller to select/unequip/dump.  Lua crosses reflection only with
-- StorageMasterData (a managed reference), Boolean and Int32; StorageData stays
-- entirely inside native game code.
local UI_DUMP = {
    obj = nil,
    address = nil,
    seen_at = 0,
    source = "not captured",
}

local function _log(s)
    s = tostring(s)
    LOG[#LOG + 1] = s
    if #LOG > 40 then table.remove(LOG, 1) end
    if M.verbose then pcall(function() log.info("[IrisDropProbe] " .. s) end) end
end

-- ── engine handles ──────────────────────────────────────────────────────────
local function _im() return sdk.get_managed_singleton("app.ItemManager") end
local function _player()
    local cm = sdk.get_managed_singleton("app.CharacterManager")
    return cm and cm:call("get_ManualPlayer")
end
local function _pgo()
    local p = _player()
    return p and p:call("get_GameObject")
end
local function _cid()
    local p, id = _player(), nil
    pcall(function() id = p:call("get_CharaID") end)
    return id
end

-- ── inventory ───────────────────────────────────────────────────────────────
-- Rows are app.ItemManager.StorageMasterData (a CLASS). The StorageData struct
-- every native actually wants lives behind get_Param().
local function _rows()
    local out, mgr, cid = {}, _im(), _cid()
    if not (mgr and cid) then return out end
    local list = nil
    pcall(function() list = mgr:call("getStorageMasterList(app.CharacterID)", cid) end)
    if not list then return out end
    local n = 0
    pcall(function() n = tonumber(list:call("get_Count")) or 0 end)
    for i = 0, n - 1 do
        pcall(function()
            local e = list:call("get_Item", i)
            if not e then return end
            local id = tonumber(e:call("get_ItemId"))
            if not id or id == 0 then return end
            local name, equipped, dropid, eqcat = "?", false, nil, nil
            pcall(function()
                local d = mgr:call("getItemData(System.Int32)", id)
                if not d then return end
                name = tostring(d:call("get_Name"))
                -- ⭐⭐⭐ _ItemDropId = the item's GROUND-DROP representation.
                --   MANTLES (EquipCategory 5) ship 0 -- they have NO drop asset,
                --   because DD2 never lets you drop equipment. consumable=4,
                --   material=7, top/weapon/ring=8. A 0 here means putItem is being
                --   asked to spawn a drop that does not exist.
                pcall(function() dropid = tonumber(d:get_field("_ItemDropId")) end)
                if dropid == nil then pcall(function() dropid = tonumber(d:call("get_ItemDropId")) end) end
                pcall(function() eqcat = tonumber(d:call("get_EquipCategory")) end)
            end)
            pcall(function() equipped = e:call("get_IsEquipped") == true end)
            out[#out + 1] = { row = e, id = id, name = name, equipped = equipped,
                              dropid = dropid, eqcat = eqcat }
        end)
    end
    return out
end

local function _find_target(force_id)
    local rows = _rows()
    local want = force_id or ((M.item_id and M.item_id > 0) and M.item_id or nil)
    if want then
        for _, r in ipairs(rows) do if r.id == want then return r end end
        return nil, "not carrying item id " .. tostring(want)
    end
    local needle = tostring(M.match or ""):lower()
    if needle == "" then return nil, "no match string and no item id" end
    for _, r in ipairs(rows) do
        if tostring(r.name):lower():find(needle, 1, true) then return r end
    end
    return nil, "nothing carried matching '" .. needle .. "'"
end

-- ── detection that does not lie ─────────────────────────────────────────────
-- ⛔ get_DropItemList read as LOOT-BAGS-ONLY in the field (IrisTaming.lua:14036):
--   player discards may never appear in it. We log it, but never trust it alone.
--   The honest signals are the bag count and a scene-mesh delta.
local function _have(id)
    local mgr, p, n = _im(), _player(), nil
    pcall(function() n = tonumber(mgr:call("getHaveNum(System.Int32, app.Character)", id, p)) end)
    return n
end

-- ⭐⭐⭐ THE CYCLE-COUNTER (added 08-24 after crash #2, RIP 0x1449dcb4a on thread 55/97)
-- Aurora crashed on the 3rd/4th drop+pickup cycle. Arrythmia reports the SAME:
-- "usually takes 3-4 cycles of dropping and picking the thing back up", timing
-- from 4 seconds to 10+ minutes. Identical signature in two independent mods.
--
-- HYPOTHESIS UNDER TEST: `putItem` registers the drop in
--     app.ItemManager.DumpedList : List<app.ItemManager.DumpedData>   @0x1d8
-- and the game caps that at the static
--     app.ItemDefine.DumpedItemMax : System.Int32   (Static | InitOnly)
-- The vanilla discard runs through app.ui060301_00.commandDecideDump -> execDump,
-- which presumably also RETIRES the entry on pickup. Calling putItem directly may
-- append without ever retiring => the list grows one entry per cycle and blows the
-- cap after a few. That fits everything: the cycle count, the degradation at cycle
-- 3 (drop stopped producing a mesh), the random landing thread, and the fact that
-- the crash arrives AFTER the call rather than during it.
-- ⚠ UNPROVEN. This function exists to measure it, not to assert it.
local _dumped_max = nil
local function _dumped_state()
    local mgr, n = _im(), nil
    if _dumped_max == nil then
        _dumped_max = false
        pcall(function()
            local fld = sdk.find_type_definition("app.ItemDefine"):get_field("DumpedItemMax")
            _dumped_max = tonumber(fld:get_data(nil)) or false
        end)
    end
    pcall(function()
        local dl = mgr:get_field("DumpedList")
        n = dl and tonumber(dl:call("get_Count")) or nil
    end)
    return n, (_dumped_max ~= false) and _dumped_max or nil
end

local function _droplist_count()
    local mgr, n = _im(), nil
    pcall(function()
        local dl = mgr:call("get_DropItemList")
        n = dl and tonumber(dl:call("get_Count")) or nil
    end)
    return n
end

local function _mesh_walk(fn)
    pcall(function()
        local sm  = sdk.get_native_singleton("via.SceneManager")
        local smt = sdk.find_type_definition("via.SceneManager")
        local scene = sm and sdk.call_native_func(sm, smt, "get_CurrentScene")
        local comps = scene and scene:call("findComponents(System.Type)", sdk.typeof("via.render.Mesh"))
        if not comps then return end
        local prp = _pgo():call("get_Transform"):call("get_Position")
        local n = 0
        pcall(function() n = comps:call("get_Length") or 0 end)
        if n == 0 then pcall(function() n = comps:get_size() or 0 end) end
        for i = 0, (tonumber(n) or 0) - 1 do
            pcall(function()
                local g = comps:call("get_Item", i):call("get_GameObject")
                local rp = g:call("get_Transform"):call("get_Position")
                local dx, dz = rp.x - prp.x, rp.z - prp.z
                local d2 = dx * dx + dz * dz
                if d2 < 64.0 then fn(g, d2) end
            end)
        end
    end)
end

local function _mesh_snapshot()
    local set = {}
    if not M.mesh_scan then return set end
    _mesh_walk(function(g) set[g:get_address()] = true end)
    return set
end

local function _mesh_new(seen)
    local found = {}
    if not M.mesh_scan then return found end
    _mesh_walk(function(g, d2)
        if seen[g:get_address()] then return end
        local nm = "?"
        pcall(function() nm = tostring(g:call("get_Name")) end)
        if not nm:find("^ch%d") then
            found[#found + 1] = string.format("%s @%.1fm", nm, math.sqrt(d2))
        end
    end)
    return found
end

-- how many dropped-item gimmicks are lying around (the other thing that could leak).
-- Defined here, AFTER _mesh_walk -- a `local function` referenced before its
-- declaration binds to a nil GLOBAL, not to the later local.
local function _drop_gimmick_count()
    if not M.mesh_scan then return nil end
    local c = 0
    _mesh_walk(function(g)
        local nm = ""
        pcall(function() nm = tostring(g:call("get_Name")) end)
        if nm:find("gm82", 1, true) then c = c + 1 end
    end)
    return c
end

-- ── ⛔⛔⛔ THE DANGLING-POINTER LAW (crash dump, 2026-08-24 21:58) ───────────
-- Aurora's CTD: ACCESS_VIOLATION reading 0x0, RIP 0x1449dcb4a. That RIP is ABOVE
-- the managed-method ceiling (0x1449d9b90) and every other frame resolved outside
-- managed code too => an il2cpp dispatch stub, i.e. "the object handed in was
-- already bad" ([[dd2-crash-dump-triage]]).
--
-- WHY. app.ItemDefine.StorageData has a 32-byte value payload whose **first field
-- is a managed POINTER**. REFramework/TDB reports 48 for the boxed size because
-- that includes the 16-byte managed-object header; those header bytes are not a
-- by-value putItem argument:
--     _ItemData  @0x0  app.ItemCommonParam   <- System.Object = a reference
--     _Enhance   @0x8   _StorageId @0xc   _UpdateIndex @0x10  _CharaId @0x14
--     _ItemId    @0x18  _Num @0x1a  _EquipSlot @0x1c  _IsEquipped @0x1d
-- get_Param() hands Lua a COPY of the payload. The pointer at 0x0 comes along
-- as raw bytes, and **the Lua-side copy is NOT a GC root** -- il2cpp does not know
-- we are holding a reference. Allocate hard between the copy and the native call
-- (our full-scene findComponents walk does exactly that) and a collection can free
-- or move ItemCommonParam underneath us. putItem then dereferences a dead pointer.
--
-- This was a reasonable lifetime experiment, but both the keepalive version and
-- the live-row payload version crashed. It remains here as defensive validation,
-- not as a claimed fix.
--
-- Defensive handling, three parts:
--   1. take the struct LAST, with no allocating work before the native call;
--   2. hold a REAL wrapper to _ItemData across the window -- a REManagedObject IS
--      a GC root, so this genuinely pins the object (return it, keep it alive);
--   3. validate before use: null _ItemData, or an _ItemId that disagrees with the
--      row, means the copy is already junk -- refuse rather than hand it over.
-- ⚠ (3) cannot detect a NON-null but dangling pointer. (1)+(2) are the real
--   protection in theory; neither prevented the observed recurring-cycle crash.
local function _fetch_storage(row, want_id)
    local storage = nil
    pcall(function() storage = row:call("get_Param") end)
    if not storage then return nil, "get_Param gave no StorageData" end

    -- ⭐ the keepalive: a live wrapper roots the managed object for the caller's window
    local keepalive = nil
    pcall(function() keepalive = storage:get_field("_ItemData") end)
    if keepalive == nil then return nil, "_ItemData is NULL - struct is junk, refusing" end

    if want_id then
        local iid = nil
        pcall(function() iid = tonumber(storage:get_field("_ItemId")) end)
        if iid and iid ~= want_id then
            return nil, string.format("_ItemId mismatch (struct=%d expected=%d) - refusing", iid, want_id)
        end
    end
    return storage, keepalive
end

local function _capture_inventory_ui(args, source)
    pcall(function()
        local obj = sdk.to_managed_object(args[2]) -- instance method: args[2] is `this`
        if not obj then return end
        local address = tonumber(obj:get_address())
        if not address or address == 0 then return end
        local changed = UI_DUMP.address ~= address
        UI_DUMP.obj = obj
        UI_DUMP.address = address
        UI_DUMP.seen_at = os.clock()
        UI_DUMP.source = source
        if changed then
            _log(string.format("captured native inventory controller at 0x%X (%s)", address, source))
        end
    end)
end

local function _hook_inventory_capture(method_name, source)
    pcall(function()
        local td = sdk.find_type_definition("app.ui060301_00")
        local method = td and td:get_method(method_name)
        if not method then
            _log("inventory-controller capture hook missing: " .. method_name)
            return
        end
        sdk.hook(method,
            function(args) _capture_inventory_ui(args, source) end,
            function(retval) return retval end)
    end)
end

-- start catches a normal game launch; update also catches a probe hot-reload
-- while the inventory is already open and refreshes our liveness timestamp.
_hook_inventory_capture("start", "start")
_hook_inventory_capture("update", "update")

-- ── Native-origin substitution test ────────────────────────────────────────
-- The menu invokes putItem natively and survives repeated vanilla discards. This
-- experiment lets that native call happen, but replaces its by-value argument
-- pointer with a stable StorageData copy chosen by native_swap_item_id.
--
-- Backpack id 52800 eventually crashed on cycle 11, so native origin alone is NOT
-- the fix. Use a normal consumable here as the carrier-control: if that also
-- crashes, pointer substitution is not a valid native baseline; if it survives,
-- the remaining fault follows equipment/backpack state. Diagnostic only.
local NATIVE_SWAP = {
    armed = false, inflight = false, storage = nil, keepalive = nil, source_id = nil,
}
-- ValueType userdata owns REFramework's heap buffer for the by-value payload.
-- Retain completed arguments for the whole diagnostic session. If an engine job
-- incorrectly borrows the incoming address after putItem returns, releasing here
-- would manufacture the delayed UAF we are trying to diagnose. At 48 bytes/call,
-- retaining dozens of these is immaterial.
local RETAINED_STORAGE_ARGS = {}

local function _clear_native_swap()
    NATIVE_SWAP.armed = false
    NATIVE_SWAP.inflight = false
    NATIVE_SWAP.storage = nil
    NATIVE_SWAP.keepalive = nil
    NATIVE_SWAP.source_id = nil
end

local function _arm_native_swap()
    _clear_native_swap()
    local t, why = _find_target(M.native_swap_item_id)
    if not t then _log("NATIVE-SUB abort: " .. tostring(why)); return end
    if t.equipped then
        _log("NATIVE-SUB abort: source item must be unequipped")
        return
    end
    local storage, keepalive = _fetch_storage(t.row, t.id)
    if not storage then _log("NATIVE-SUB abort: " .. tostring(keepalive)); return end
    NATIVE_SWAP.storage = storage
    NATIVE_SWAP.keepalive = keepalive
    NATIVE_SWAP.source_id = t.id
    NATIVE_SWAP.armed = true
    _log(string.format(
        "==== NATIVE-SUB ARMED with item %d: discard ONE cheap item via game menu ====",
        tonumber(t.id) or -1))
end

pcall(function()
    local td = sdk.find_type_definition("app.ItemManager")
    local method = td and td:get_method(
        "putItem(app.ItemDefine.StorageData, System.Int32, app.Character)")
    if not method then _log("NATIVE-SUB hook unavailable: no 3-arg putItem"); return end
    sdk.hook(method,
        function(args)
            pcall(function()
                if not NATIVE_SWAP.armed then return end
                local addr = NATIVE_SWAP.storage and NATIVE_SWAP.storage:get_address() or nil
                if not addr or addr == 0 then
                    _log("NATIVE-SUB abort in hook: source buffer vanished")
                    _clear_native_swap(); return
                end
                args[3] = sdk.to_ptr(addr)
                NATIVE_SWAP.armed = false
                NATIVE_SWAP.inflight = true
                _log(string.format(
                    "NATIVE-SUB applied: native menu call now carries item id %d (payload=0x%X)",
                    tonumber(NATIVE_SWAP.source_id) or -1, tonumber(addr) or 0))
            end)
        end,
        function(retval)
            pcall(function()
                if not NATIVE_SWAP.inflight then return end
                RETAINED_STORAGE_ARGS[#RETAINED_STORAGE_ARGS + 1] = {
                    storage = NATIVE_SWAP.storage,
                    keepalive = NATIVE_SWAP.keepalive,
                    source_id = NATIVE_SWAP.source_id,
                }
                _log(string.format(
                    "NATIVE-SUB native putItem returned; RETAINING source buffer (held=%d)",
                    #RETAINED_STORAGE_ARGS))
                _clear_native_swap()
            end)
            return retval
        end)
    _log("NATIVE-SUB hook installed")
end)

-- ⭐⭐⭐ THE ENGINE'S OWN GATE (added 08-24 after crash #3)
-- RULED OUT by that run: DumpedItemMax = 100 and DumpedList never exceeded 1, and
-- pickup correctly retires both the DumpedData entry and the gm82 gimmick (1 -> 0).
-- The list does NOT leak. Overflow is dead.
--
-- What that run DID show: drop 1 logged `unequip ok` + `putItem ok=true` and then
-- `have 1->1, no mesh` -- putItem REPORTED SUCCESS AND DID NOTHING. Same item, same
-- path that worked 90s earlier. So putItem silently declines depending on state we
-- never check.
--
-- putItem is `FamANDAssem | Family` (protected). The vanilla discard reaches it via
-- app.ui060301_00.commandDecideDump -> execDump, and the engine exposes a static
-- precondition that flow can be expected to consult:
--     app.ItemManager.isDumpEnable(ref StorageData, app.Character, app.Human) -> Boolean
-- We have never called it. Calling a protected method past a gate the engine always
-- checks is exactly how you get "sometimes nothing happens, sometimes it corrupts".
-- ⚠ UNPROVEN, and the ByRef param may not marshal from Lua -- if it throws we log
--   that and carry on rather than blocking the drop on a call we cannot make.
local function _dump_enabled(storage, ch)
    local res, err = nil, nil
    local ok = pcall(function()
        local m = sdk.find_type_definition("app.ItemManager"):get_method("isDumpEnable")
        if not m then err = "no isDumpEnable method"; return end
        local human = ch:call("get_Human")
        if not human then err = "no app.Human on character"; return end
        res = m:call(nil, storage, ch, human)      -- Static: nil `this`
    end)
    if not ok then return nil, "isDumpEnable THREW (ByRef marshalling?)" end
    if err then return nil, err end
    if res == nil then return nil, "isDumpEnable returned nil" end
    return res == true, nil
end

-- ── Lua-only native-UI drop ─────────────────────────────────────────────────
local function _ui_selected_item_id(ui)
    local item_id = nil
    pcall(function()
        local selected = ui:get_field("SelectedStorage")
        item_id = selected and tonumber(selected:get_field("_ItemId")) or nil
    end)
    return item_id
end

local function _ui_select_row(ui, row, want_id)
    local ok, result = pcall(function()
        return ui:call("selectItemSlot(app.ItemManager.StorageMasterData)", row)
    end)
    if not ok then return false, "selectItemSlot threw: " .. tostring(result) end

    local selected_id = _ui_selected_item_id(ui)
    if selected_id ~= want_id then
        return false, string.format(
            "inventory selected item %s instead of %s (return=%s)",
            tostring(selected_id), tostring(want_id), tostring(result))
    end
    return true, tostring(result)
end

local function _do_ui_drop(force_id, label)
    local ui = UI_DUMP.obj
    if not ui then
        last = "open Inventory once after loading this script; controller not captured"
        _log("UI-DROP abort: " .. last)
        return
    end

    -- The update hook refreshes this while the real controller is being ticked.
    -- Refuse a stale raw pointer rather than discovering its lifetime by crashing.
    local age = os.clock() - (UI_DUMP.seen_at or 0)
    if age > 1.0 then
        last = "inventory controller is not live; open Inventory and try while it is open"
        _log(string.format("UI-DROP abort: %s (last seen %.2fs ago)", last, age))
        return
    end

    local t, why = _find_target(force_id)
    if not t then last = tostring(why); _log("UI-DROP target: " .. last); return end
    _log(string.format("── %s via native inventory controller: %s (id=%d) equipped=%s",
        label or "UI-DROP", t.name, t.id, tostring(t.equipped)))

    local before = _have(t.id)
    local dl_before = _droplist_count()
    local seen = _mesh_snapshot()

    if t.equipped then
        local selected, select_detail = _ui_select_row(ui, t.row, t.id)
        _log("   native UI select for unequip: " .. tostring(select_detail))
        if not selected then last = t.name .. ": " .. select_detail; _log("   " .. last); return end

        local unequipped, unequip_err = pcall(function()
            ui:call("equipOffExec(System.Boolean)", false)
        end)
        _log("   native UI equipOffExec: ok=" .. tostring(unequipped)
            .. (unequipped and "" or (" err=" .. tostring(unequip_err))))
        if not unequipped then
            last = t.name .. ": native UI could not unequip it"
            _log("   " .. last)
            return
        end

        -- The equipment operation can rebuild StorageMasterData. Never select the
        -- old wrapper again: resolve the current inventory row and verify its flag.
        t, why = _find_target(t.id)
        if not t then last = "item row vanished after unequip: " .. tostring(why); _log("   " .. last); return end
        if t.equipped then
            last = t.name .. ": equipOffExec returned but the row is still equipped; refusing"
            _log("   " .. last)
            return
        end
    end

    local selected, select_detail = _ui_select_row(ui, t.row, t.id)
    _log("   native UI select for dump: " .. tostring(select_detail))
    if not selected then last = t.name .. ": " .. select_detail; _log("   " .. last); return end

    local called, call_err = pcall(function()
        -- This is the crucial boundary: Lua passes ONE Int32. execDump reads its
        -- own embedded SelectedStorage and calls putItem from native game code.
        ui:call("execDump(System.Int32)", M.count)
    end)
    _log("   native UI execDump(Int32): ok=" .. tostring(called)
        .. (called and "" or (" err=" .. tostring(call_err))))

    Q[#Q + 1] = { k = "verify", at = os.clock() + 0.35,
                  id = t.id, name = t.name, before = before,
                  dl_before = dl_before, seen = seen, called = called }
    last = string.format("%s: native UI execDump called (ok=%s), verifying...", t.name, tostring(called))
end

-- ── retired reflective drop (kept only as investigation evidence) ───────────
local function _do_reflective_drop(force_id, label)
    local mgr, ch, pgo = _im(), _player(), _pgo()
    if not (mgr and ch and pgo) then last = "no player/ItemManager"; _log(last); return end

    local t, why = _find_target(force_id)
    if not t then last = tostring(why); _log("target: " .. last); return end
    _log(string.format("── %s: %s (id=%d) equipped=%s", label or "DROP", t.name, t.id, tostring(t.equipped)))

    -- ⭐ was the world actually paused when this fired? (the whole point of the test)
    do
        local paused = "unknown"
        if type(_G.iris_game_paused) == "function" then
            local ok, p = pcall(iris_game_paused)
            if ok then paused = tostring(p) end
        end
        _log("   game_paused = " .. paused)
    end

    -- ⭐ the cycle counter: does DumpedList grow one per drop and never shrink?
    do
        local dn, dmax = _dumped_state()
        _log(string.format("   PRE : DumpedList=%s/%s   gm82 gimmicks near=%s",
             tostring(dn), tostring(dmax or "?"), tostring(_drop_gimmick_count())))
        if dn and dmax and dn >= dmax then
            _log("   ⛔⛔ DumpedList AT/OVER CAP -- suspected corruption point, expect a CTD soon")
        end
    end

    -- ⛔⛔⛔ ALL HEAVY / ALLOCATING WORK GOES **BEFORE** WE TAKE THE STRUCT.
    --   See _fetch_storage above for why. The mesh walk especially: it allocates
    --   hundreds of objects and is the single most likely thing to trigger a GC.
    local before    = _have(t.id)
    local dl_before = _droplist_count()
    local seen      = _mesh_snapshot()

    -- ⭐ UNEQUIP FIRST. An equipped item is still referenced by the equip slot;
    --   moving its storage row out from under that slot leaves a live pointer to
    --   a row that is gone. removeEquip WITHOUT applyEquipChange is bookkeeping
    --   only -- the model stays on the body. (IrisWeaponMount 08-09 law.)
    if t.equipped then
        local s0, keep0 = _fetch_storage(t.row, t.id)     -- own short-lived copy
        if not s0 then last = "unequip: " .. tostring(keep0); _log(last); return end
        local ok = pcall(function()
            mgr:call("removeEquip(app.ItemDefine.StorageData, app.Character, System.Boolean, System.Boolean)",
                     s0, ch, true, true)
        end)
        s0, keep0 = nil, nil
        pcall(function() mgr:call("applyEquipChange") end)
        local still = true
        pcall(function() still = t.row:call("get_IsEquipped") == true end)
        _log(string.format("   unequip: called=%s still_equipped=%s", tostring(ok), tostring(still)))
        if still then
            last = "could not unequip " .. t.name .. " - REFUSING to drop it"
            _log(last); return
        end
    end

    -- ⭐ RE-RESOLVE THE ROW. `t.row` was captured before the mesh walk and the unequip,
    --   both of which mutate the item system. A StorageMasterData the ItemManager has
    --   since rebuilt is an orphan, and re-fetching get_Param() off an orphan just
    --   yields a fresh copy of stale bytes. Get a CURRENT row first.
    local t2 = _find_target(t.id)
    if not t2 then last = t.name .. ": row vanished before the drop - refusing"; _log("   " .. last); return end

    -- ⭐ DISCRIMINATING TEST, not yet a fix. The first clean backpack drop carried
    -- _IsNew=0. Pickup made its live StorageMasterData row new; the second hotkey
    -- passed _IsNew=1 and the worker thread jumped through a corrupted code pointer
    -- ~0.24s later. The menu-discard controls seen so far both passed _IsNew=0.
    --
    -- Use the row's own setter (rather than editing a detached StorageData copy), so
    -- the experiment reproduces the inventory UI acknowledging the "New" marker.
    -- It is opt-in until repeated cycles establish that this bit is causal.
    local row_is_new = nil
    pcall(function() row_is_new = t2.row:call("get_IsNew") == true end)
    _log("   row IsNew before drop = " .. tostring(row_is_new))
    if M.clear_is_new == true and row_is_new == true then
        local changed, change_err = pcall(function()
            t2.row:call("set_IsNew(System.Boolean)", false)
        end)
        local after_new = nil
        pcall(function() after_new = t2.row:call("get_IsNew") == true end)
        _log(string.format("   EXPERIMENT clear IsNew: called=%s now=%s%s",
            tostring(changed), tostring(after_new),
            changed and "" or (" err=" .. tostring(change_err))))
        if not changed or after_new ~= false then
            last = t.name .. ": could not clear IsNew - refusing experimental drop"
            _log("   " .. last); return
        end
    end

    -- ⭐⭐ NOW acquire the argument -- LAST, with nothing between here and the
    -- native call. Normal mode uses REFramework's copied ValueType. The opt-in
    -- experiment instead hands its invoke wrapper a pointer to the live `_Param`
    -- field embedded at StorageMasterData+0x10. Both routes present the same
    -- 32-byte payload to the game; the latter removes ValueType's vector buffer
    -- and its erroneous boxed-size (48-byte) copy from the equation.
    if M.live_row_arg == true then
        last = "retained-buffer test requires live-row payload OFF - refusing"
        _log("   " .. last)
        return
    end
    local storage, keepalive, storage_arg = nil, nil, nil
    if M.live_row_arg == true then
        local row_addr = nil
        pcall(function() row_addr = tonumber(t2.row:get_address()) end)
        if not row_addr or row_addr == 0 then
            last = t.name .. ": no live StorageMasterData address - refusing pointer experiment"
            _log("   " .. last); return
        end
        storage_arg = row_addr + 0x10 -- runtime/il2cpp_dump: StorageMasterData._Param
        pcall(function() keepalive = t2.row:call("get_ItemData") end)
        if keepalive == nil then
            last = t.name .. ": live row has NULL ItemData - refusing pointer experiment"
            _log("   " .. last); return
        end
        _log(string.format("   EXPERIMENT live-row StorageData arg = 0x%X", storage_arg))
    else
        storage, keepalive = _fetch_storage(t2.row, t.id)
        if not storage then last = t.name .. ": " .. tostring(keepalive); _log("   " .. last); return end
        storage_arg = storage
    end

    -- ⭐⭐⭐ the engine's own precondition
    local gate, gerr = _dump_enabled(storage_arg, ch)
    _log(string.format("   isDumpEnable = %s%s", tostring(gate), gerr and ("  (" .. gerr .. ")") or ""))
    if gate == false and M.gate_dump ~= false then
        last = t.name .. ": isDumpEnable said NO - refusing (this is the engine's own gate)"
        _log("   " .. last); storage, keepalive = nil, nil; return
    end

    local ok, err
    if M.use_6arg then
        -- ⛔ the overload that native-crashed us in IrisTaming. Now with the struct
        --   marshalling actually correct: engine-produced via.Position (3 doubles)
        --   and via.Quaternion, never a hand-built Vector3f.
        ok, err = pcall(function()
            local tr  = pgo:call("get_Transform")
            local pos = tr:call("get_UniversalPosition")   -- already a via.Position
            local rot = tr:call("get_Rotation")            -- already a via.Quaternion
            mgr:call("putItem(app.ItemDefine.StorageData, System.Int32, via.Position, via.Quaternion, via.GameObject, System.Boolean)",
                     storage_arg, M.count, pos, rot, pgo, true)
        end)
        _log("   putItem 6-arg (proper via.Position): ok=" .. tostring(ok) .. (ok and "" or (" err=" .. tostring(err))))
    else
        ok = false
        err = "disabled: reflective StorageData putItem is the proven crash path"
        _log("   putItem 3-arg REFUSED: " .. err)
    end

    -- The menu-carrier A/B test crashed on cycle 11 when its Lua-owned ValueType
    -- buffer was released at return, but survived 20 cycles when each buffer was
    -- retained. Transfer that exact lifetime rule to the direct call. `storage` is
    -- a Lua ValueType userdata owning the argument bytes, not an engine object
    -- wrapper; keeping it rooted is safe and costs only 48 bytes per drop.
    if storage ~= nil then
        RETAINED_STORAGE_ARGS[#RETAINED_STORAGE_ARGS + 1] = {
            storage = storage,
            keepalive = keepalive,
            source_id = t.id,
            origin = "lua-direct",
        }
        _log(string.format(
            "   RETAINING direct StorageData buffer (held=%d)",
            #RETAINED_STORAGE_ARGS))
    elseif M.live_row_arg == true then
        _log("   WARNING: live-row mode has no owned ValueType buffer to retain")
    end
    storage, storage_arg, keepalive = nil, nil, nil

    -- the engine may DEFER the spawn, so read the verdict a beat later
    Q[#Q + 1] = { k = "verify", at = os.clock() + 0.35,
                  id = t.id, name = t.name, before = before,
                  dl_before = dl_before, seen = seen, called = ok }
    last = string.format("%s: putItem called (ok=%s), verifying...", t.name, tostring(ok))
end

local function _verify(j)
    local after    = _have(j.id)
    local dl_after = _droplist_count()
    local newmesh  = _mesh_new(j.seen)
    local dec = (j.before and after and after < j.before) == true

    _log(string.format("   VERDICT %s: have %s->%s (%s) | droplist %s->%s | new meshes: %d",
        j.name, tostring(j.before), tostring(after), dec and "DECREMENTED" or "unchanged",
        tostring(j.dl_before), tostring(dl_after), #newmesh))
    for i = 1, math.min(#newmesh, 6) do _log("      new mesh: " .. newmesh[i]) end

    local dn, dmax = _dumped_state()
    _log(string.format("   POST: DumpedList=%s/%s   gm82 gimmicks near=%s",
         tostring(dn), tostring(dmax or "?"), tostring(_drop_gimmick_count())))

    if not j.called then
        last = j.name .. ": putItem THREW - marshalling rejected (see log)"
    elseif dec and #newmesh > 0 then
        last = j.name .. ": ✅ LEFT THE BAG and something spawned - real drop"
    elseif dec and not M.mesh_scan then
        -- ⚠ with the scan off, #newmesh is ALWAYS 0 -- do not read that as failure.
        last = j.name .. ": ✅ left the bag (mesh scan OFF, visual unverified)"
    elseif dec then
        last = j.name .. ": ⚠ left the bag but NO new mesh - dropped invisibly?"
    elseif #newmesh > 0 then
        last = j.name .. ": ⚠ mesh appeared but bag unchanged - CLONE, not a drop"
    else
        last = j.name .. ": ⚠ no drop present at verification (may already have been picked up)"
    end
    _log("   " .. last)
end

local function _paused()
    if type(_G.iris_game_paused) == "function" then
        local ok, p = pcall(iris_game_paused)
        if ok then return p == true end
    end
    return nil
end

-- ── job pump: game thread, ONE engine job per tick (the no-lock law) ────────
-- ⭐ A job may carry `need_paused`: it is held back until the world is ACTUALLY
--   halted, rather than firing on a timer and hoping. The 5s-timer version of
--   this test fired its second call at game_paused=false and crashed, which told
--   us nothing about paused behaviour -- only that the unpaused path still dies.
re.on_application_entry("UpdateBehavior", function()
    if #Q == 0 then return end
    local now, idx = os.clock(), nil
    for i, j in ipairs(Q) do
        local due = (not j.at) or (now >= j.at)
        if due then
            if j.need_paused and _paused() ~= true then
                if j.expire and now > j.expire then
                    table.remove(Q, i)
                    _log("⛔ armed paused-drop EXPIRED - inventory never opened, nothing fired")
                    return
                end
                -- otherwise keep waiting; later jobs may still be eligible
            else
                idx = i; break
            end
        end
    end
    if not idx then return end
    local j = table.remove(Q, idx)
    if     j.k == "drop"   then pcall(function() _do_ui_drop(j.id, j.label) end)
    elseif j.k == "verify" then pcall(function() _verify(j) end)
    end
end)

-- ── input (gated: menus own the pad) ────────────────────────────────────────
local held = false
re.on_application_entry("UpdateBehavior", function()
    local down = false
    if type(_G.iris_kb) == "function" then
        down = iris_kb(M.hotkey) == true
    else
        pcall(function()
            local kb = sdk.get_native_singleton("via.hid.Keyboard")
            local kt = sdk.find_type_definition("via.hid.Keyboard")
            local st = kb and sdk.call_native_func(kb, kt, "get_Device")
            down = st and st:call("getDown", M.hotkey) == true
        end)
    end
    if down and not held then Q[#Q + 1] = { k = "drop" } end
    held = down
end)

re.on_script_reset(function()
    Q = {}
    held = false
    UI_DUMP.obj = nil
    UI_DUMP.address = nil
    UI_DUMP.seen_at = 0
    UI_DUMP.source = "reset"
    _clear_native_swap()
end)

-- ── panel ───────────────────────────────────────────────────────────────────
re.on_draw_ui(function()
    if not imgui.tree_node("Iris Drop Probe") then return end

    imgui.text("Status: " .. tostring(last))
    local ui_age = UI_DUMP.obj and (os.clock() - (UI_DUMP.seen_at or 0)) or nil
    local ui_live = ui_age ~= nil and ui_age <= 1.0
    imgui.text_colored(
        ui_live and string.format("Lua-only native UI route: LIVE (0x%X)", UI_DUMP.address or 0)
                or "Lua-only native UI route: open Inventory once to capture it",
        ui_live and 0xFF80FF80 or 0xFF80D0FF)
    imgui.separator()

    if imgui.button("DROP TARGET VIA NATIVE UI") then Q[#Q + 1] = { k = "drop" } end
    imgui.same_line()
    imgui.text(string.format("(hotkey VK 0x%02X)", M.hotkey))

    imgui.text_colored("First proof run: leave Inventory open and press the button/hotkey.", 0xFF80D0FF)
    imgui.text_colored("No DLL and no StorageData value crosses the Lua reflection boundary.", 0xFF80FFD0)

    imgui.separator()
    imgui.text("GAME-MENU CARRIER CONTROL:")
    local sw
    sw, M.native_swap_item_id = imgui.drag_int(
        "substitution source item id", M.native_swap_item_id, 1, 1, 100000)
    if sw then _save() end
    if imgui.button("ARM: substitute source into next GAME-MENU discard") then
        _arm_native_swap()
    end
    imgui.text_colored("Source must be carried and unequipped. Discard ONE cheap item normally.", 0xFF80D0FF)
    imgui.text_colored("The source should drop; the menu-selected item should remain.", 0xFF80D0FF)
    if NATIVE_SWAP.armed then
        imgui.text_colored("ARMED - the next 3-arg putItem will be substituted", 0xFF80FF80)
    end
    imgui.text(string.format("retained StorageData buffers: %d", #RETAINED_STORAGE_ARGS))

    local ch
    ch, M.item_id = imgui.drag_int("item id (0 = use name)", M.item_id, 1, 0, 100000)
    if ch then _save() end
    ch, M.match = imgui.input_text("name contains", M.match)
    if ch then _save() end
    ch, M.count = imgui.drag_int("count", M.count, 1, 1, 99)
    if ch then _save() end
    ch, M.hotkey = imgui.drag_int("hotkey VK", M.hotkey, 1, 1, 255)
    if ch then _save() end

    imgui.separator()
    ch, M.mesh_scan = imgui.checkbox("scene-mesh detection (slow, but honest)", M.mesh_scan)
    if ch then _save() end
    ch, M.verbose = imgui.checkbox("log to console", M.verbose)
    if ch then _save() end

    imgui.separator()
    imgui.text("CONTROL TEST -- the actual experiment:")
    imgui.text_colored("The backpack (52800) is a ContentEditor item with _ItemDropId=0.", 0xFF80FFD0)
    imgui.text_colored("If a VANILLA item drops and it does not, the fault is the item,", 0xFF80FFD0)
    imgui.text_colored("not the putItem call. Pick any vanilla thing below and compare.", 0xFF80FFD0)

    if imgui.tree_node("carried items (click to drop as control)") then
        for _, r in ipairs(_rows()) do
            if imgui.button(string.format("drop##%d", r.id)) then
                Q[#Q + 1] = { k = "drop", id = r.id, label = "CONTROL" }
            end
            imgui.same_line()
            local warn = (r.dropid == 0) and "  ⛔ dropId=0 NO DROP ASSET" or ""
            imgui.text(string.format("%6d  %-34s drop=%s eqcat=%s%s%s",
                r.id, r.name, tostring(r.dropid), tostring(r.eqcat),
                r.equipped and "  [EQUIPPED]" or "", warn))
        end
        imgui.tree_pop()
    end

    if imgui.tree_node("log") then
        for i = #LOG, 1, -1 do imgui.text(LOG[i]) end
        imgui.tree_pop()
    end

    imgui.tree_pop()
end)

_log("IrisDropProbe loaded (target id " .. tostring(M.item_id) .. ")")
