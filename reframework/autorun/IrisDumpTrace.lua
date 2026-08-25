-- ============================================================================
-- IrisDumpTrace.lua — the DIFFERENCE-DIFF for the putItem drop crash
-- ============================================================================
-- 2026-08-24. Nine hypotheses eliminated (see IrisDropProbe.lua header + the
-- dd2-putitem-storagedata-law memory). Both our clean-room drop AND Arrythmia's
-- mod die on ~the 3rd putItem call with heap corruption: ACCESS_VIOLATION
-- reading 0x0 in an il2cpp dispatch stub, ~400ms AFTER putItem returns, on a
-- random worker thread (differing tid each crash), zero Lua release warnings.
--
-- ✅✅✅ RESULT 2026-08-24 22:38 — THE DIFF CAME BACK EMPTY. Captured live:
--     VANILLA:  isDumpEnable -> commandDecideDump -> execDump
--                              -> putItem_3arg -> putItem_6arg -> addDumpedData
--     OURS:     isDumpEnable -> putItem_3arg -> putItem_6arg -> addDumpedData
--   The INNER SEQUENCE IS IDENTICAL. execDump contributes nothing but itself; the
--   two UI frames are just the menu wrapper. Conclusions:
--     * We call putItem exactly as the game does. No missing bookkeeping step.
--     * registDropItemInfo fires in NEITHER path -- the UniqueID double-retire
--       theory is dead.
--     * ⭐ putItem_3arg INTERNALLY CALLS putItem_6arg. So the 6-arg CTD banned in
--       IrisTaming.lua:5971 was never a via.Position marshalling fault -- the 3-arg
--       overload we "replaced" it with runs the exact same code one frame deeper.
--   ⇒ THE DROP IS NOT THE BUG. Next suspect: the ITEM. Both crashing mods drop the
--     same custom ContentEditor item with a custom mesh, repeatedly. Vanilla items
--     get discarded and re-collected endlessly without this. Run the control.
--
-- ⭐ THE ORIGINAL QUESTION (answered above, kept for the reasoning):
--   putItem is `FamANDAssem | Family` (PROTECTED). The game never calls it
--   naked -- it reaches it through app.ui060301_00.commandDecideDump -> execDump.
--   WHAT ELSE DOES THAT PATH DO THAT WE DO NOT?
--
--   Known candidates in the chain, all confirmed present in il2cpp_dump.json:
--     app.ItemManager.addDumpedData(StorageData, Int32, app.UniqueID, Int32)
--     app.ItemManager.deleteDumpedData(app.UniqueID, Boolean, app.CharacterID)
--     app.ItemManager.updateDumpedData()      /  clearDumpedData()
--     app.DropItemLostManager.registDropItemInfo(app.UniqueID)
--     app.DropItemLostManager.unregistDropItemInfo(app.UniqueID)
--   A drop that is registered with a UniqueID nobody ever retires -- or one
--   retired twice -- is exactly the shape of "corrupts, surfaces later".
--
-- ⭐ HOW TO USE IT (this is the whole experiment):
--   1. Press MARK and choose "VANILLA".  Now discard an item using the GAME'S
--      OWN inventory menu (the normal in-game discard). Trace captures it.
--   2. Press MARK and choose "OURS".     Now press the IrisDropProbe hotkey.
--   3. Send Iris both blocks. The DELTA between the two sequences is the answer.
--
-- ⚠ Tracing is ARMED-ONLY (a few seconds per MARK). updateDumpedData and friends
--   may run per-frame; logging them unconditionally would flood the log and
--   change the timing we are trying to measure. Never leave it armed.
-- ⚠ Hooks are PERMANENT -- REFramework has no unhook. A script reset orphans them
--   with their upvalues live, so every callback is pcall-wrapped and reads the
--   arm flag through a table, never a captured local.
-- ============================================================================

local S = { armed_until = 0, label = "-", seq = 0, log = {}, hooks = 0, fails = 0 }
local ARM_SECS = 12.0

local function ev(name, extra)
    if os.clock() > S.armed_until then return end
    S.seq = S.seq + 1
    local line = string.format("[%03d] %-8s %s%s", S.seq, S.label, name,
                               extra and ("  " .. extra) or "")
    S.log[#S.log + 1] = line
    if #S.log > 120 then table.remove(S.log, 1) end
    pcall(function() log.info("[IrisDumpTrace] " .. line) end)
end

local function note(s)   -- setup messages, always logged
    S.log[#S.log + 1] = s
    if #S.log > 120 then table.remove(S.log, 1) end
    pcall(function() log.info("[IrisDumpTrace] " .. s) end)
end

-- ── hook installer ──────────────────────────────────────────────────────────
-- Tries each signature in turn, falls back to the bare name. Everything is
-- pcall'd: a trace that crashes the game is worse than no trace at all.
local function install(tdname, sigs, label, read_args)
    local ok = pcall(function()
        local td = sdk.find_type_definition(tdname)
        if not td then note("HOOKFAIL (no type) " .. tdname); S.fails = S.fails + 1; return end
        local m = nil
        for _, s in ipairs(sigs) do
            m = td:get_method(s)
            if m then break end
        end
        if not m then note("HOOKFAIL (no method) " .. tdname .. "." .. label); S.fails = S.fails + 1; return end
        sdk.hook(m,
            function(args) pcall(function()
                if os.clock() > S.armed_until then return end
                local extra = read_args and read_args(args) or nil
                ev("ENTER " .. label, extra)
            end) end,
            function(retval) pcall(function() ev("EXIT  " .. label) end); return retval end)
        S.hooks = S.hooks + 1
        note("hooked " .. tdname .. "." .. label)
    end)
    if not ok then note("HOOKFAIL (threw) " .. tdname .. "." .. label); S.fails = S.fails + 1 end
end

-- ⭐⭐⭐ THE ARGUMENT DIFF (2026-08-24 23:0x — after the pause theory died too)
-- The call SEQUENCE is identical between the menu and us (proven above). The one
-- surface never inspected is WHAT WE PASS. putItem takes StorageData BY VALUE, so
-- the engine gets a 32-byte payload and must locate the real row from the identity
-- fields inside it. If ours disagree with the menu's -- especially _StorageId or
-- _UpdateIndex, which smell like slot + generation counters -- the engine would be
-- operating on the wrong row, which IS heap corruption.
--   _ItemData @0x0 (ptr) · _Enhance @0x8 · _StorageId @0xc · _UpdateIndex @0x10
--   _CharaId @0x14 · _ItemId @0x18 · _Num @0x1a · _EquipSlot @0x1c
--   _IsEquipped @0x1d · _IsNew @0x1e · _ArisenEquipNo @0x1f
local SD_TD  = sdk.find_type_definition("app.ItemDefine.StorageData")
local UID_TD = sdk.find_type_definition("app.UniqueID")
local POS_TD = sdk.find_type_definition("via.Position")
local ROT_TD = sdk.find_type_definition("via.Quaternion")

local function type_size(td, hard_cap)
    if not td then return 0 end
    local n = 0
    -- get_size() includes the 0x10-byte managed header for value types in TDB73.
    -- Hook arguments contain only the payload reported by get_valuetype_size().
    pcall(function() n = tonumber(td:get_valuetype_size()) or 0 end)
    if n <= 0 then pcall(function() n = tonumber(td:get_size()) or 0 end) end
    if hard_cap and n > hard_cap then n = hard_cap end
    return n
end

-- Deliberately use only ValueType:read_* here. Calling get_field("_ItemData")
-- manufactures an REManagedObject Lua wrapper and changes the pointed object's
-- refcount while we are trying to observe a lifetime/corruption bug.
local function raw_value(ptr, td, exact_size)
    if not td then return "<no type>" end
    local out, vt = {}, nil
    local ok = pcall(function() vt = sdk.to_valuetype(ptr, td) end)
    if not ok or not vt then return "<READ THREW>" end
    local n = exact_size or type_size(td, 128)
    for i = 0, n - 1 do
        local b = nil
        pcall(function() b = tonumber(vt:read_byte(i)) end)
        out[#out + 1] = b and string.format("%02X", b) or "??"
    end
    return table.concat(out)
end

local function dump_storage(ptr)
    if not SD_TD then return "no StorageData typedef" end
    local sd = nil
    local ok = pcall(function() sd = sdk.to_valuetype(ptr, SD_TD) end)
    if not ok or not sd then return "READ THREW" end

    local function rd(method, off)
        local v = "?"
        pcall(function() v = tostring(sd[method](sd, off)) end)
        return v
    end

    -- Raw bytes are the authority. The decoded suffix is only for readability.
    -- Runtime-verified on DD2/TDB73: get_size=0x30 BOXED, while the actual
    -- StorageData payload is get_valuetype_size=0x20. The last named byte is 0x1f.
    local raw = raw_value(ptr, SD_TD, 0x20)
    return string.format(
        "raw32=%s | itemDataRaw=%s storageId=%s updateIndex=%s charaId=%s itemId=%s num=%s equipSlot=%s equipped=%s isNew=%s arisenEquipNo=%s",
        raw, raw:sub(1, 16), rd("read_dword", 0x0c), rd("read_dword", 0x10),
        rd("read_dword", 0x14), rd("read_short", 0x18), rd("read_short", 0x1a),
        rd("read_byte", 0x1c), rd("read_byte", 0x1d), rd("read_byte", 0x1e),
        rd("read_byte", 0x1f))
end

local function dump_uid(ptr)
    return "uidRaw=" .. raw_value(ptr, UID_TD)
end

local function scalar(ptr)
    local v = "?"
    pcall(function() v = tostring(sdk.to_int64(ptr)) end)
    return v
end

do
    local function sizes(td)
        if not td then return "missing" end
        local a, b = "?", "?"
        pcall(function() a = tostring(td:get_size()) end)
        pcall(function() b = tostring(td:get_valuetype_size()) end)
        return "size=" .. a .. "/valuetype=" .. b
    end
    note("TYPE SIZES: StorageData " .. sizes(SD_TD) .. "; UniqueID " .. sizes(UID_TD)
         .. "; Position " .. sizes(POS_TD) .. "; Quaternion " .. sizes(ROT_TD))
end

-- Inventory the narrow native surface once. If the struct bytes match, the best
-- fix is likely a game-owned wrapper which accepts stable scalar IDs and creates
-- StorageData inside managed code, rather than another variation of Lua->ValueType.
local function note_dump_surface(tdname)
    pcall(function()
        local td = sdk.find_type_definition(tdname)
        if not td then return end
        for _, m in ipairs(td:get_methods() or {}) do
            local name = tostring(m:get_name() or "")
            local low = name:lower()
            if low:find("dump", 1, true) or low:find("putitem", 1, true)
                    or low:find("dropitem", 1, true) or low:find("pickup", 1, true) then
                local ps, pnames = {}, {}
                pcall(function() pnames = m:get_param_names() or {} end)
                for i, pt in ipairs(m:get_param_types() or {}) do
                    local pn = tostring(pnames[i] or ("arg" .. tostring(i)))
                    local tn, byref = "?", false
                    pcall(function() tn = tostring(pt:get_full_name() or "?") end)
                    pcall(function() byref = pt:is_by_ref() == true end)
                    ps[#ps + 1] = pn .. ":" .. tn .. (byref and "&" or "")
                end
                note("SURFACE " .. tdname .. "." .. name .. "(" .. table.concat(ps, ", ") .. ")")
            end
        end
    end)
end
note_dump_surface("app.ItemManager")
note_dump_surface("app.ui060301_00")

-- ── the chain ───────────────────────────────────────────────────────────────
-- putItem gets the full argument dump; everything else just logs enter/exit.
pcall(function()
    local td = sdk.find_type_definition("app.ItemManager")
    local m = td and td:get_method("putItem(app.ItemDefine.StorageData, System.Int32, app.Character)")
    if not m then note("HOOKFAIL putItem_3arg (argdump)"); S.fails = S.fails + 1; return end
    sdk.hook(m,
        function(args)
            pcall(function()
                if os.clock() > S.armed_until then return end
                ev("ENTER putItem_3arg", dump_storage(args[3])
                    .. " | num=" .. scalar(args[4]) .. " characterRaw=" .. tostring(args[5]))
            end)
        end,
        function(retval) pcall(function() ev("EXIT  putItem_3arg") end); return retval end)
    S.hooks = S.hooks + 1
    note("hooked app.ItemManager.putItem_3arg (WITH ARG DUMP)")
end)

install("app.ItemManager",
    { "putItem(app.ItemDefine.StorageData, System.Int32, via.Position, via.Quaternion, via.GameObject, System.Boolean)" },
    "putItem_6arg", function(args)
        return dump_storage(args[3])
            .. " | num=" .. scalar(args[4])
            .. " posRaw=" .. raw_value(args[5], POS_TD)
            .. " rotRaw=" .. raw_value(args[6], ROT_TD)
            .. " requestObjRaw=" .. tostring(args[7])
            .. " flag=" .. scalar(args[8])
    end)

install("app.ItemManager",
    { "addDumpedData(app.ItemDefine.StorageData, System.Int32, app.UniqueID, System.Int32)", "addDumpedData" },
    "addDumpedData", function(args)
        return dump_storage(args[3]) .. " | num=" .. scalar(args[4])
            .. " " .. dump_uid(args[5]) .. " lostHour=" .. scalar(args[6])
    end)

install("app.ItemManager",
    { "deleteDumpedData(app.UniqueID, System.Boolean)", "deleteDumpedData" },
    "deleteDumpedData", function(args)
        return dump_uid(args[3]) .. " isDelete=" .. scalar(args[4])
    end)

-- ⛔ updateDumpedData is a PER-FRAME tick (~55 calls/sec). Hooking it produced 1200+
--   log lines in one 12s window and buried the signal. Never hook it again.
-- install("app.ItemManager", { "updateDumpedData()" }, "updateDumpedData")
install("app.ItemManager", { "clearDumpedData()",  "clearDumpedData"  }, "clearDumpedData")

install("app.ItemManager",
    { "isDumpEnable(app.ItemDefine.StorageData, app.Character, app.Human)", "isDumpEnable" },
    -- Static method: args[2] is its first declared parameter (there is no `this`).
    "isDumpEnable", function(args)
        return dump_storage(args[2])
            .. " | characterRaw=" .. tostring(args[3]) .. " humanRaw=" .. tostring(args[4])
    end)

install("app.DropItemLostManager", { "registDropItemInfo(app.UniqueID)" },   "regist_LostInfo")
install("app.DropItemLostManager", { "unregistDropItemInfo(app.UniqueID)" }, "unregist_LostInfo")

-- the vanilla UI route -- THE reference sequence we are trying to reproduce
install("app.ui060301_00", { "commandDecideDump(app.Character)", "commandDecideDump" }, "UI_commandDecideDump")
install("app.ui060301_00", { "execDump(System.Int32)", "execDump" },                   "UI_execDump")

-- deleteItem, for contrast: the call we KNOW is safe (IrisWeaponMount ships it)
install("app.ItemManager",
    { "deleteItem(app.ItemDefine.StorageData, System.Int32)" },
    "deleteItem_sd", function(args)
        return dump_storage(args[3]) .. " | num=" .. scalar(args[4])
    end)

note(string.format("IrisDumpTrace ready: %d hooks installed, %d failed", S.hooks, S.fails))

-- ── panel ───────────────────────────────────────────────────────────────────
re.on_draw_ui(function()
    if not imgui.tree_node("Iris Dump Trace") then return end

    local armed = os.clock() <= S.armed_until
    imgui.text(string.format("hooks: %d installed, %d failed", S.hooks, S.fails))
    imgui.text(armed
        and string.format("ARMED as '%s'  (%.1fs left)", S.label, S.armed_until - os.clock())
        or  "idle - press a MARK button, then perform the drop")

    imgui.separator()
    imgui.text("1) MARK VANILLA, then discard via the GAME'S OWN inventory menu")
    if imgui.button("MARK: VANILLA") then
        S.label = "VANILLA"; S.seq = 0; S.armed_until = os.clock() + ARM_SECS
        note("==== MARK VANILLA -- discard something via the game menu now ====")
    end

    imgui.text("2) MARK OURS, then press the IrisDropProbe hotkey")
    if imgui.button("MARK: OURS") then
        S.label = "OURS"; S.seq = 0; S.armed_until = os.clock() + ARM_SECS
        note("==== MARK OURS -- press the drop hotkey now ====")
    end

    imgui.separator()
    if imgui.button("disarm now") then S.armed_until = 0 end
    imgui.same_line()
    if imgui.button("clear log") then S.log = {}; S.seq = 0 end

    if imgui.tree_node("trace") then
        for i = #S.log, 1, -1 do imgui.text(S.log[i]) end
        imgui.tree_pop()
    end

    imgui.tree_pop()
end)
