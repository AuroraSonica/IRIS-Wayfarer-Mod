-- I.R.I.S. -- THE STABLE SCREEN (2026-08-11, v2)
-- An in-game stable UI (Aurora: "like the pokemon box screen, NOT a reframework panel"):
-- a list + detail pane drawn over the game, driven by keyboard (pad nav lands once the
-- dpad mask is read off the debug line). All stable ACTIONS go through
-- _G.IrisGriffinBridge's stable_* API (GriffinRideProbe owns the machinery); this file is
-- presentation + input only, per the unified-UI registry law (engines stay engines).
--
-- ⛔ v2 LESSONS (Aurora's first screenshot -- "I can't see any text"):
--  1. The d2d text layer draws UNDER the imgui background drawlist on this build, so
--     IrisFont.text painted every string BEHIND the panel rects ("THE STABLE" was faintly
--     visible through the smoke). Fix = one layer for everything: text goes through
--     imgui.push_font + draw.text (Nick's Boss-Healthbar technique -- draw.text DOES
--     honour a pushed font), same drawlist as the rects, call order = z order.
--  2. draw.filled_rect colours are ABGR, not ARGB -- the "gold" hairline rendered BLUE.
--     Everything here is authored ARGB and converted through rc() at the draw call.
--
-- KEYS (v1): O = open/close · Up/Down = move · Enter = summon · Backspace = dismiss ·
-- Delete = release (press TWICE -- releasing ERASES the soul). No WASD/E/R/Esc on
-- purpose: the game keeps receiving input while the screen is up.

local CFG_FILE = "IrisStableUI.json"
local C = {
    key_toggle = 0x4F,     -- O
    key_up = 0x26, key_down = 0x28,          -- arrows
    key_summon = 0x0D,     -- Enter
    key_dismiss = 0x08,    -- Backspace
    key_release = 0x2E,    -- Delete (double-press)
    key_rename = 0x52,     -- R (safe: the world is paused while the screen is open)
    key_home = 0x48,       -- H: send to / call back from the homestead
    scale = 1.0,
    font_file = "Sovngarde Light.ttf",       -- the IRIS face (reframework/fonts/)
    show_pad_mask = false, -- dev: show the live gamepad button mask (for wiring pad nav)
}
pcall(function()
    local d = json.load_file(CFG_FILE)
    if type(d) == "table" then for k, v in pairs(d) do if C[k] ~= nil then C[k] = v end end end
end)
local function save_cfg() pcall(function() json.dump_file(CFG_FILE, C) end) end

-- state survives reloads (the _G table pattern); registrations are per-load re.on_frame
_G.IrisStableUI = _G.IrisStableUI or {}
local U = _G.IrisStableUI
U.open = U.open or false
U.cursor = U.cursor or 1
U.msg, U.msg_until = U.msg or nil, U.msg_until or 0.0
U.confirm_id, U.confirm_until = nil, 0.0
-- ⛔ 08-11 (Aurora: a "Tails" rename box popped up after CHRISTENING a new bird, and a
-- phantom release dialog after naming Bordy): U survives reloads by design, but queued
-- ACTIONS and dialogs must NOT -- a stale pending waits patiently for a quiet frame and
-- then fires into a completely different moment. Fresh load = empty hands.
U.pending = nil
U.dlg = nil
local held = {}   -- per-load key edge/repeat state

-- ── ARGB (authored) -> ABGR (what the imgui drawlist actually eats) ─────────────────────
local function rc(argb)
    local a = (argb >> 24) & 0xFF
    local r = (argb >> 16) & 0xFF
    local g = (argb >> 8) & 0xFF
    local b = argb & 0xFF
    return (a << 24) | (b << 16) | (g << 8) | r
end

-- ── fonts: loaded lazily at the resolved pixel size; slider change reloads ──────────────
local fonts = { tried = false, big = nil, std = nil, at_scale = nil }
local function screen_size()
    local w, h = 1920.0, 1080.0
    pcall(function()
        local sz = imgui.get_display_size()
        if sz and tonumber(sz.x) and tonumber(sz.x) > 0 then w, h = sz.x, sz.y end
    end)
    return w, h
end
local function ui_scale()
    local _, sh = screen_size()
    return (sh / 1080.0) * (tonumber(C.scale) or 1.0)
end
local function ensure_fonts()
    local sc = ui_scale()
    if fonts.tried and fonts.at_scale == sc then return end
    fonts.tried = true
    fonts.at_scale = sc
    fonts.big, fonts.std = nil, nil
    local file = tostring(C.font_file or "Sovngarde Light.ttf")
    -- glyph ranges: try to include ♀/♂ (U+2640/2642); fall back to default ranges
    pcall(function()
        fonts.big = imgui.load_font(file, math.floor(26 * sc + 0.5), { 0x0020, 0x00FF, 0x2600, 0x26FF, 0 })
        fonts.std = imgui.load_font(file, math.floor(17 * sc + 0.5), { 0x0020, 0x00FF, 0x2600, 0x26FF, 0 })
    end)
    if not fonts.std then
        pcall(function()
            fonts.big = imgui.load_font(file, math.floor(26 * sc + 0.5))
            fonts.std = imgui.load_font(file, math.floor(17 * sc + 0.5))
        end)
    end
    -- ♀/♂: Sovngarde carries neither (the imgui atlas has NO fallback, unlike d2d's
    -- DirectWrite substitution on the nameplates -- Aurora caught the difference).
    -- Bake JUST the two gender glyphs from a Unicode-rich bundled face; with a
    -- restricted range even the 9MB Noto costs a couple of atlas cells.
    fonts.sym = nil
    for _, cand in ipairs({ "LinLibertine_R.ttf", "NotoSansJP-Regular.ttf" }) do
        if not fonts.sym then
            pcall(function()
                fonts.sym = imgui.load_font(cand, math.floor(17 * sc + 0.5), { 0x2640, 0x2642, 0 })
            end)
        end
    end
end

local function text_w(s)
    -- measured width of s in the std face (for stitching mixed-font segments)
    local w = nil
    if fonts.std then imgui.push_font(fonts.std) end
    pcall(function()
        local sz = imgui.calc_text_size(tostring(s))
        w = sz and tonumber(sz.x) or nil
    end)
    if fonts.std then imgui.pop_font() end
    return w
end

-- one layer for everything: pushed-font draw.text sits in the SAME drawlist as the rects
local function txt(s, x, y, argb, big)
    local f = big and fonts.big or fonts.std
    if f then imgui.push_font(f) end
    pcall(function() draw.text(tostring(s), x, y, rc(argb)) end)
    if f then imgui.pop_font() end
end

local function kb(vk)
    if type(iris_input_blocked) == "function" and iris_input_blocked() then return false end
    if _G.RiftSpeakPromptOpen == true or _G.RiftSpeak_PromptOpen == true then return false end
    local dn = false
    pcall(function() dn = reframework:is_key_down(vk) == true end)
    return dn
end

-- ── PAD (IrisFurnish's proven kit, ported verbatim): bits resolved BY ENUM NAME from
-- via.hid.GamePadButton -- never hardcode masks, and never guess names ("B"/"Circle" are
-- not fields; a bad name slides the lookup to the wrong button, the IrisFarming trap).
local PAD = { names = {}, dpad = {}, face = {} }
pcall(function()
    local t = sdk.find_type_definition("via.hid.GamePadButton")
    for _, f in ipairs(t:get_fields()) do
        pcall(function() PAD.names[f:get_name()] = f:get_data() end)
    end
    local function pick(...)
        for _, n in ipairs({ ... }) do if PAD.names[n] then return PAD.names[n] end end
        return 0
    end
    PAD.dpad.up = pick("LUp", "Up", "DUp", "PadUp")
    PAD.dpad.down = pick("LDown", "Down", "DDown", "PadDown")
    PAD.dpad.right = pick("LRight", "Right", "DRight", "PadRight")
    PAD.face.a = pick("Decide", "A", "RDown")
    PAD.face.b = pick("Cancel", "B", "RRight")
    PAD.face.x = pick("Action", "X", "RLeft")
    PAD.face.y = pick("Special", "Y", "RUp", "Triangle")
    -- ⛔ 08-11 (furnish_log's name inventory): this enum has NO "Select"/"Back" -- the
    -- centre cluster is CCenter/CLeft/CRight. CLeft = the View/Back/Select button; the
    -- old ladder resolved 0 and the hold-to-open could never fire (Aurora caught it).
    PAD.sel = pick("CLeft", "Select", "Back", "Share", "Minus")
end)
local function pad_button()
    local v = 0
    pcall(function()
        local s = sdk.get_native_singleton("via.hid.GamePad")
        local t = sdk.find_type_definition("via.hid.GamePad")
        local d = sdk.call_native_func(s, t, "get_MergedDevice")
        if d then v = d:call("get_Button") or 0 end
    end)
    return math.floor(v)
end
local function pdown(bit)
    if not bit or bit == 0 then return false end
    if type(iris_input_blocked) == "function" and iris_input_blocked() then return false end
    return (pad_button() & bit) ~= 0
end

-- ── WORLD PAUSE (Aurora: "all the buttons do something in game -- pause like a menu").
-- IrisFurnish's requestPause kit + RiftSpeak's anti-underflow laws (the infini-freeze
-- post-mortem): (1) only mark paused when the TRUE call confirmably fired; (2) NEVER fire
-- a FALSE without holding a confirmed pause -- an unbalanced false underflows the engine
-- pause stack = frozen-frame-with-audio, task-kill; (3) never pause during a transition
-- (no player character = the call gets swallowed and the bookkeeping lies).
-- ⚠ Reset Scripts while the screen is open would orphan our pause (Lua state wiped, native
-- stack keeps the TRUE) -- the panel has an emergency release button for exactly that.
local PAUSE_SIG = "requestPause(System.Boolean, app.PauseManager.PauseType, System.String, System.Action)"
local function pause_value()
    if U.pause_val then return U.pause_val end
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
    U.pause_val = (list[sel] and list[sel].value) or 1
    return U.pause_val
end
local function world_pause(on)
    pcall(function()
        local pm = sdk.get_managed_singleton("app.PauseManager")
        if not pm then if not on then U.paused = false end return end
        if on and not U.paused then
            local pl = nil
            pcall(function() pl = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer") end)
            if not pl then return end   -- transition gate: the call would be swallowed
            local ok = pcall(function() pm:call(PAUSE_SIG, true, pause_value(), "IrisStableUI", nil) end)
            if ok then U.paused = true end
        elseif (not on) and U.paused then
            pcall(function() pm:call(PAUSE_SIG, false, U.pause_val or pause_value(), "IrisStableUI", nil) end)
            U.paused = false
        end
    end)
end

-- edge/repeat keyed by ACTION name so keyboard and pad merge into one logical press
local function edge2(name, dn, repeat_after, repeat_every)
    local now = os.clock()
    local h = held[name]
    if dn and not h then
        held[name] = { rep = now + (repeat_after or 1e9) }
        return true
    elseif dn and h and repeat_after and now >= h.rep then
        h.rep = now + (repeat_every or 0.12)
        return true
    elseif not dn then
        held[name] = nil
    end
    return false
end
local function edge(vk, repeat_after, repeat_every)
    return edge2(vk, kb(vk), repeat_after, repeat_every)
end

local function say(s) U.msg = tostring(s); U.msg_until = os.clock() + 3.0 end
local function bridge() return rawget(_G, "IrisGriffinBridge") end

-- ── NATIVE Yes/No dialog (the wyrm rite's proven ui010101 recipe, replicated with OUR
-- OWN state -- ⛔ never call iris_wyrm_dialog_open: it arms IrisTaming's poll and a YES
-- would read as the RITE confirmation and eat 3 crystals). RetVal: None=0 Cancel=1
-- Sel0/YES=2 Sel1/NO=3; act on CHANGE from the open baseline; 0.25s debounce; 30s stuck
-- guard; blind reqClose at load = the softlock guard (same law as the homestead dialogs).
local DLG_TYPE = 14   -- app.GuiDefine.GuiType.Dialog
local function dlg_pick()
    local p
    pcall(function()
        local gm = sdk.get_managed_singleton("app.GuiManager")
        local rv = gm and gm:call("getDialogState")
        if type(rv) == "number" then p = rv
        elseif rv ~= nil then p = sdk.to_int64(rv) & 0xFFFFFFFF end
    end)
    return p
end
local function dlg_close()
    pcall(function()
        local gm = sdk.get_managed_singleton("app.GuiManager")
        local dialog = gm and gm:get_field("Dialog")
        if dialog then dialog:call("reqClose") end
        gm:call("requestHideGuiType", DLG_TYPE)
    end)
    U.dlg = nil
end
local function dlg_open(prompt, yes_label, no_label, payload)
    pcall(function()
        local gm = sdk.get_managed_singleton("app.GuiManager")
        local dialog = gm and gm:get_field("Dialog")
        if not dialog then return end
        -- ⛔ 08-11 (Aurora: YES did nothing twice, NO released): getDialogState is STICKY
        -- across dialogs -- a stale 2 from any past YES makes a fresh YES invisible to
        -- change-detection. Reset the stored answer before opening -- but ⛔ NEVER guess
        -- field names ("<RetVal>k__BackingField" red-bannered even inside pcall, Aurora's
        -- screenshot). DISCOVER the field from the Dialog's own type once; if nothing
        -- matches, dump the field list to the log so the real name can be wired.
        if U.dlg_field == nil then
            U.dlg_field = false
            pcall(function()
                local td = dialog:get_type_definition()
                local names = {}
                for _, f in ipairs(td:get_fields() or {}) do
                    local n = tostring(f:get_name() or "")
                    names[#names + 1] = n
                    if U.dlg_field == false then
                        local ln = n:lower()
                        if ln:find("retval", 1, true) or ln:find("result", 1, true) or ln:find("selectno", 1, true) then
                            local v = nil
                            pcall(function() v = tonumber(dialog:get_field(n)) end)
                            if v ~= nil then U.dlg_field = n end
                        end
                    end
                end
                if U.dlg_field == false then
                    log.info("[IrisStableUI] no dialog result field matched; fields: " .. table.concat(names, " "))
                else
                    log.info("[IrisStableUI] dialog result field = " .. tostring(U.dlg_field))
                end
            end)
        end
        if U.dlg_field and U.dlg_field ~= false then
            pcall(function() dialog:set_field(U.dlg_field, 0) end)
        end
        gm:call("requestGuiType", DLG_TYPE)
        dialog:call("reqDisp",
            prompt, yes_label, no_label, "", "",
            true, 0, true, 58, 0, -1, nil,
            false, false, false, false, false, false,
            true, 0.0)
        U.dlg = { open = true, opened_at = os.clock(), baseline = dlg_pick(), payload = payload }
        pcall(function() log.info("[IrisStableUI] dialog opened, baseline=" .. tostring(U.dlg.baseline)) end)
    end)
end
pcall(dlg_close)   -- softlock guard: a reload orphaning our dialog must not strand it
local function stable_rows()
    local b = bridge()
    local rows = nil
    pcall(function() rows = b and b.stable_list and b.stable_list() or nil end)
    return rows or {}
end

-- ── input tick ──────────────────────────────────────────────────────────────────────────
local function set_open(v)
    U.open = v == true
    _G.IrisStableUIOpen = U.open
    U.confirm_id = nil
    if U.open then U.cursor = 1 end
    world_pause(U.open)
end
local function toggle_open() set_open(not U.open) end
local function queue_action(kind, id, name)
    -- ⛔ never touch bodies on a paused frame (the pause-spawn crash class): the action
    -- queues, the menu closes and unpauses, and the work runs on the first LIVE frame.
    -- Stamped so it EXPIRES: a pending that can't run within 10s is forgotten, never
    -- fired into some later unrelated moment (the phantom-rename lesson).
    if U.dlg and U.dlg.open then return end   -- one conversation at a time
    U.pending = { kind = kind, id = id, name = name, at = os.clock() }
    set_open(false)
end
local function input_tick()
    -- while our native dialog is up, IT owns the player's attention -- no screen toggles,
    -- no new queues (the answer comes through dlg_tick alone)
    if U.dlg and U.dlg.open then return end
    if edge2("toggle", kb(C.key_toggle)) then toggle_open() end
    -- pad opener: HOLD Select/Back ~0.7s (a bare press stays free for whatever the game
    -- binds it to; the hold is deliberate enough not to collide)
    if pdown(PAD.sel) then
        U.sel_t0 = U.sel_t0 or os.clock()
        if os.clock() - U.sel_t0 > 0.7 then U.sel_t0 = 1e12; toggle_open() end
    else
        U.sel_t0 = nil
    end
    -- keep the flag published even across reloads (the jump-block reads it)
    _G.IrisStableUIOpen = U.open == true
    if not U.open then return end
    if edge2("close", pdown(PAD.face.b)) then set_open(false); return end
    local rows = stable_rows()
    if #rows == 0 then return end
    if U.cursor > #rows then U.cursor = #rows end
    if U.cursor < 1 then U.cursor = 1 end
    -- wraparound (Aurora): up from the top lands on the bottom, down from the bottom on the top
    if edge2("up", kb(C.key_up) or pdown(PAD.dpad.up), 0.35, 0.12) then
        U.cursor = (U.cursor <= 1) and #rows or (U.cursor - 1); U.confirm_id = nil
    end
    if edge2("down", kb(C.key_down) or pdown(PAD.dpad.down), 0.35, 0.12) then
        U.cursor = (U.cursor >= #rows) and 1 or (U.cursor + 1); U.confirm_id = nil
    end
    local row = rows[U.cursor]
    if not row then return end
    local b = bridge()
    -- CONTEXTUAL primary (Aurora): the row that is OUT dismisses; any other row summons
    -- (stable_summon already dismisses the current companion as part of the switch).
    -- All body-touching actions QUEUE and run after the unpause (queue_action).
    if edge2("primary", kb(C.key_summon) or pdown(PAD.face.a)) and b then
        queue_action(row.live and "dismiss" or "summon", row.id, row.name)
    end
    if edge2("rename", kb(C.key_rename) or pdown(PAD.face.x)) then
        queue_action("rename", row.id, row.name)
    end
    if edge2("home", kb(C.key_home) or pdown(PAD.dpad.right)) then
        queue_action(row.home and "callback" or "home", row.id, row.name)
    end
    -- ONE press (Aurora): the NATIVE dialog carries the forever-warning, not a
    -- double-tap. The ask queues like everything else and opens after the unpause.
    if edge2("release", kb(C.key_release) or pdown(PAD.face.y)) and b then
        queue_action("release_ask", row.id, row.name)
    end
end

-- ── deferred actions: run on the first LIVE frame after the menu closed ─────────────────
local function pending_tick()
    local p = U.pending
    if not p or U.open then return end
    -- expiry: an action that couldn't run promptly is dropped, loudly
    if os.clock() - (tonumber(p.at) or 0.0) > 10.0 then
        U.pending = nil
        pcall(function() log.info("[IrisStableUI] pending '" .. tostring(p.kind) .. "' EXPIRED unconsumed (dropped)") end)
        return
    end
    local engine_paused = false
    pcall(function()
        engine_paused = type(griffin_world_paused) == "function" and griffin_world_paused() == true
    end)
    if engine_paused or U.paused then return end
    U.pending = nil
    local b = bridge()
    if not b then return end
    local ok, why = nil, nil
    if p.kind == "summon" then
        pcall(function() ok, why = b.stable_summon(p.id) end)
    elseif p.kind == "dismiss" then
        pcall(function() ok, why = b.stable_dismiss() end)
    elseif p.kind == "release_ask" then
        dlg_open("Release " .. tostring(p.name or "this creature") .. " forever?\n"
            .. "The bond will be gone for good.",
            "Release them", "Keep them", { id = p.id, name = p.name })
        return
    elseif p.kind == "home" then
        pcall(function() ok, why = b.stable_send_home(p.id) end)
    elseif p.kind == "callback" then
        pcall(function() ok, why = b.stable_call_back(p.id) end)
    elseif p.kind == "rename" then
        -- hand off to IrisTaming's rename card (the panel's own flow)
        local ok9 = false
        pcall(function()
            local T = rawget(_G, "IrisTaming")
            if T and T.open_rename then T.open_rename(p.id, p.name); ok9 = true end
        end)
        if not ok9 then
            pcall(function()
                local T = rawget(_G, "IrisTaming")
                if T and T.prompt then T.prompt("THE STABLE", "Rename is unavailable (IrisTaming not loaded)", 3.0, 0xFF8080FF) end
            end)
        end
        return
    end
    pcall(function()
        local T = rawget(_G, "IrisTaming")
        if T and T.prompt then
            local msg = (p.kind == "release" and ok) and (tostring(p.name) .. " released. Farewell.")
                or tostring(why or (ok and "done" or "failed"))
            T.prompt("THE STABLE", msg, 3.0, ok and 0xFF80FFB0 or 0xFF8080FF)
        end
    end)
end

-- ── draw (colours authored ARGB; rc() converts at the call) ─────────────────────────────
local COL = {
    dim    = 0xC0000000,  -- outer shadow
    smoke  = 0xF014141A,  -- panel
    inset  = 0x50000000,  -- list/detail wells
    gold   = 0xFFC8A050,  -- hairline + cursor
    cream  = 0xFFE8D8A8,  -- headings
    body   = 0xFFC8C8D0,  -- body text
    dimtxt = 0xFF9A9AA8,  -- hints
    green  = 0xFF58C878,
    amber  = 0xFFC8A050,
    red    = 0xFFB05048,
    alive  = 0xFFB8E8B8,
    trough = 0xFF23232A,
    warn   = 0xFFFF6060,
}
local IV_KEYS = { "hp", "atk", "def", "spd", "size", "luck" }
local IV_LABEL = { hp = "HP", atk = "ATK", def = "DEF", spd = "SPD", size = "SIZE", luck = "LUCK" }

local function draw_ui()
    if not U.open then return end
    ensure_fonts()
    local sw, sh = screen_size()
    local sc = ui_scale()
    -- 960 wide: the health readout ("99990 / 100000") overran the 860 panel (Aurora's
    -- screenshot), and the coming [H] Send Home action wants the elbow room anyway
    local W, H = 960.0 * sc, 560.0 * sc
    local X, Y = (sw - W) * 0.5, (sh - H) * 0.42
    local pad = 14.0 * sc
    draw.filled_rect(X - 3, Y - 3, W + 6, H + 6, rc(COL.dim))
    draw.filled_rect(X, Y, W, H, rc(COL.smoke))
    draw.filled_rect(X, Y, W, 2.0 * sc, rc(COL.gold))
    draw.filled_rect(X, Y + H - 2.0 * sc, W, 2.0 * sc, rc(COL.gold))
    local rows = stable_rows()
    local list_w = 330.0 * sc
    local ly = Y + 52.0 * sc
    local rh = 30.0 * sc
    -- wells first, then every string on top (one drawlist -- call order is z order)
    if #rows > 0 then
        local max_vis = math.floor((H - 110.0 * sc) / rh)
        if U.cursor > #rows then U.cursor = #rows end
        local first = math.max(1, math.min(U.cursor - math.floor(max_vis / 2), #rows - max_vis + 1))
        draw.filled_rect(X + pad, ly - 4.0 * sc, list_w, math.min(#rows, max_vis) * rh + 8.0 * sc, rc(COL.inset))
        local rx = X + pad + list_w + pad
        local rw = W - (rx - X) - pad
        draw.filled_rect(rx, ly - 4.0 * sc, rw, H - 110.0 * sc + 8.0 * sc, rc(COL.inset))
        -- list
        for i = first, math.min(#rows, first + max_vis - 1) do
            local r = rows[i]
            local yy = ly + (i - first) * rh
            if i == U.cursor then
                draw.filled_rect(X + pad, yy - 2.0 * sc, list_w, rh - 2.0 * sc, rc(0x60C8A050))
            end
            local col = (i == U.cursor) and 0xFFFFF0C8 or (r.live and COL.alive or COL.body)
            -- mixed-font stitch: name in Sovngarde, ♀/♂ from the symbol face (measured
            -- placement), rest in Sovngarde again. No symbol font loaded = clean skip.
            local nm = tostring(r.name or "?")
            local rest = string.format("  (%s)%s", tostring(r.label or "?"),
                r.live and "  [Out]" or (r.home and "  [Home]" or ""))
            local x0 = X + pad + 6.0 * sc
            txt(nm, x0, yy, col)
            local xoff = x0 + (text_w(nm) or (#nm * 8.0 * sc))
            local gs = (r.gender == "female" and "\u{2640}") or (r.gender == "male" and "\u{2642}") or nil
            if gs and fonts.sym then
                local gcol = (r.gender == "female" and 0xFFE8A8C8) or 0xFFA8C8E8
                imgui.push_font(fonts.sym)
                pcall(function() draw.text(gs, xoff + 5.0 * sc, yy, rc(gcol)) end)
                local sw = nil
                pcall(function()
                    local sz = imgui.calc_text_size(gs)
                    sw = sz and tonumber(sz.x) or nil
                end)
                imgui.pop_font()
                xoff = xoff + 5.0 * sc + (sw or 12.0 * sc)
            end
            txt(rest, xoff, yy, col)
        end
        -- detail pane
        local r = rows[U.cursor]
        if r then
            local gword = (r.gender == "female" and "Female") or (r.gender == "male" and "Male") or "?"
            txt(string.format("%s  -  %s %s", tostring(r.name or "?"), gword, tostring(r.label or "?")),
                rx + 10.0 * sc, ly + 2.0 * sc, COL.cream, true)
            local status = r.live and "With You Now"
                or (r.home and "Living At The Homestead")
                or (r.active and "Selected - Not Summoned" or "Resting In The Stable")
            if r.hatch then status = status .. "  (Hatchling)" end
            if r.wyrm then status = status .. "  (Wyrm-Grown)" end
            txt(status, rx + 10.0 * sc, ly + 36.0 * sc, r.live and 0xFF9AE89A or COL.dimtxt)
            local by = ly + 62.0 * sc
            local bar_x = rx + 70.0 * sc
            local bar_w = rw - 200.0 * sc   -- room for "99990 / 100000" beside the bar
            -- section header: small gold title + a thin rule (Aurora: separate live
            -- stats from the genes, and give the genes their own name)
            local function section(title)
                txt(title, rx + 10.0 * sc, by, 0xFFB8A070)
                draw.filled_rect(rx + 10.0 * sc, by + 21.0 * sc, rw - 20.0 * sc, 1.0, rc(0x50C8A050))
                by = by + 30.0 * sc
            end
            -- ── CONDITION: the living, changing stats ──
            section("CONDITION")
            local hp, hpmax = tonumber(r.hp), tonumber(r.hp_max)
            txt("Health", rx + 10.0 * sc, by, COL.body)
            draw.filled_rect(bar_x, by + 5.0 * sc, bar_w, 10.0 * sc, rc(COL.trough))
            if hp and hpmax and hpmax > 0 then
                local hf = math.max(0.0, math.min(1.0, hp / hpmax))
                local hcol = (hf > 0.5 and COL.green) or (hf > 0.25 and COL.amber) or COL.red
                draw.filled_rect(bar_x, by + 5.0 * sc, bar_w * hf, 10.0 * sc, rc(hcol))
                txt(string.format("%d / %d", math.floor(hp), math.floor(hpmax)),
                    bar_x + bar_w + 8.0 * sc, by, COL.cream)
            else
                txt("-", bar_x + bar_w + 8.0 * sc, by, COL.dimtxt)
            end
            by = by + 40.0 * sc
            -- ── BLOODLINE: the born genes -- rolled once at the bond, bred forward ──
            section("BLOODLINE")
            local iv = r.iv or {}
            for _, k in ipairs(IV_KEYS) do
                local v = tonumber(iv[k]) or 0
                txt(IV_LABEL[k], rx + 10.0 * sc, by, COL.body)
                draw.filled_rect(bar_x, by + 5.0 * sc, bar_w, 10.0 * sc, rc(COL.trough))
                local f = math.max(0.0, math.min(1.0, v / 30.0))
                local bcol = (v >= 24 and COL.green) or (v >= 12 and COL.amber) or COL.red
                draw.filled_rect(bar_x, by + 5.0 * sc, bar_w * f, 10.0 * sc, rc(bcol))
                txt(tostring(v), bar_x + bar_w + 8.0 * sc, by, COL.cream)
                by = by + 27.0 * sc
            end
            local szv = tonumber(iv.size)
            if szv then
                local word = (szv >= 26 and "A Towering Specimen") or (szv >= 20 and "Larger Than Most")
                    or (szv >= 11 and "True To Its Kind") or (szv >= 5 and "On The Small Side") or "A Wee Runt"
                txt(word, rx + 10.0 * sc, by + 4.0 * sc, COL.body)
            end
        end
    else
        txt("The Stable Is Empty - Tame A Creature To Begin", X + pad, Y + 70.0 * sc, COL.body)
    end
    -- title LAST among strings, still same layer (rects never cover it)
    txt("THE  STABLE", X + pad, Y + pad * 0.6, COL.cream, true)
    txt("[O / B] Close   [Enter / A] Summon / Dismiss   [R / X] Rename   [H / DpadRight] Home   [Delete / Y] Release",
        X + pad, Y + H - 26.0 * sc, COL.dimtxt)
    if U.msg and os.clock() < (tonumber(U.msg_until) or 0.0) then
        local warn = U.confirm_id ~= nil and os.clock() < (tonumber(U.confirm_until) or 0.0)
        txt(tostring(U.msg), X + pad, Y + H - 50.0 * sc, warn and COL.warn or 0xFF9AE89A)
    end
    if C.show_pad_mask then
        local mask = 0
        pcall(function()
            local gp = sdk.get_native_singleton("via.hid.GamePad")
            local td = sdk.find_type_definition("via.hid.GamePad")
            local dev = gp and td and sdk.call_native_func(gp, td, "get_MergedDevice")
            mask = dev and tonumber(dev:call("get_Button")) or 0
        end)
        txt(string.format("pad mask: 0x%X", math.floor(mask)), X + W - 200.0 * sc, Y + pad * 0.6, 0xFF808090)
    end
end

-- ── PAWN-COMMAND LOCK (Aurora: "dpad nav keeps making the pawn Go!/To Me!").
-- Nick's PlayerInputProcessor skip-hook pattern, but the method names are DISCOVERED at
-- install: anything order/command-shaped gets a pre-hook that eats the input ONLY while
-- the screen is open (fast bail otherwise -- the mass-tracer law). If nothing matches,
-- the full method list is dumped so the real name can be wired next session.
local function install_order_lock()
    if _G.IrisStableUIOrderLock then return end
    pcall(function()
        local td = sdk.find_type_definition("app.PlayerInputProcessor")
        if not td then return end
        local hooked = {}
        for _, m in ipairs(td:get_methods() or {}) do
            local nm = tostring(m:get_name() or "")
            local ln = nm:lower()
            if ln:find("order", 1, true) or ln:find("command", 1, true) then
                pcall(function()
                    sdk.hook(m, function(args)
                        if _G.IrisStableUIOpen == true then return sdk.PreHookResult.SKIP_ORIGINAL end
                    end, function(r) return r end)
                    hooked[#hooked + 1] = nm
                end)
            end
        end
        _G.IrisStableUIOrderLock = true
        pcall(function()
            if #hooked > 0 then
                log.info("[IrisStableUI] pawn-order lock hooked: " .. table.concat(hooked, ", "))
            else
                local all = {}
                for _, m in ipairs(td:get_methods() or {}) do all[#all + 1] = tostring(m:get_name()) end
                table.sort(all)
                json.dump_file("IRIS/stableui_inputproc_methods.json", all)
                log.info("[IrisStableUI] pawn-order lock: no order/command methods found -- list dumped to IRIS/stableui_inputproc_methods.json")
            end
        end)
    end)
end
install_order_lock()

-- ── the dialog's answer ─────────────────────────────────────────────────────────────────
local function dlg_tick()
    local d = U.dlg
    if not (d and d.open) then return end
    local now = os.clock()
    local pick = dlg_pick()
    local settled = now > (tonumber(d.opened_at) or 0.0) + 0.25
    if not settled then d.baseline = pick; return end
    if pick ~= nil and pick ~= d.baseline then
        local payload = d.payload
        pcall(function() log.info("[IrisStableUI] dialog answered: baseline=" .. tostring(d.baseline) .. " pick=" .. tostring(pick)) end)
        dlg_close()
        -- ⛔ FIELD-VERIFIED MAPPING (log 22:23-22:25): on THIS dialog Sel0/"Release them"
        -- answers 1 and Sel1/"Keep them" answers 2 -- the wyrm rite's enum (Sel0=2/Sel1=3)
        -- does NOT transfer. Trust the receipts, not the enum.
        if pick == 1 and payload then
            local b = bridge()
            local ok, why = nil, nil
            pcall(function() ok, why = b and b.stable_release_wild and b.stable_release_wild(payload.id) end)
            pcall(function()
                local T = rawget(_G, "IrisTaming")
                if T and T.prompt then
                    T.prompt("RELEASED", ok and (tostring(payload.name) .. " belongs to the world again. Farewell.")
                        or ("Could not release: " .. tostring(why)), 4.0, ok and 0xFF80FFB0 or 0xFF8080FF)
                end
            end)
        end
        return
    end
    if now > (tonumber(d.opened_at) or 0.0) + 30.0 then dlg_close() end
end

re.on_frame(function()
    pcall(input_tick)
    pcall(pending_tick)
    pcall(dlg_tick)
    pcall(draw_ui)
end)

re.on_draw_ui(function()
    if imgui.tree_node("I.R.I.S. Stable Screen") then
        imgui.text("In-game stable UI. Default key: O")
        local ch, v
        ch, v = imgui.checkbox("show pad button mask (dev, for wiring pad nav)", C.show_pad_mask == true)
        if ch then C.show_pad_mask = v; save_cfg() end
        ch, v = imgui.slider_float("UI scale", tonumber(C.scale) or 1.0, 0.6, 1.6)
        if ch then C.scale = v; save_cfg() end
        if imgui.button("Open/close now") then toggle_open() end
        imgui.text("DEV size preview (live companion):")
        imgui.same_line()
        if imgui.button("MIN (gene 1)") then
            pcall(function() local _, m = bridge().size_preview(1); U.preview_msg = m end)
        end
        imgui.same_line()
        if imgui.button("MAX (gene 30)") then
            pcall(function() local _, m = bridge().size_preview(30); U.preview_msg = m end)
        end
        imgui.same_line()
        if imgui.button("real size") then
            pcall(function() local _, m = bridge().size_preview(nil); U.preview_msg = m end)
        end
        if U.preview_msg then imgui.text(tostring(U.preview_msg)) end
        if imgui.button("DEV: complete active companion's wyrm growth now") then
            local ok = false
            pcall(function()
                local b = bridge()
                ok = b and b.complete_active_wyrm and b.complete_active_wyrm() == true
            end)
            imgui.same_line(); imgui.text(ok and "done - next pulse applies" or "no growth to complete")
        end
        -- ⚠ emergency: Reset Scripts while the screen was open orphans our engine pause
        -- (Lua bookkeeping wiped, native TRUE still standing). This fires ONE balanced
        -- release. Only press it if the world is stuck paused after a reset.
        if imgui.button("EMERGENCY: release a stuck stable-screen pause") then
            pcall(function()
                local pm = sdk.get_managed_singleton("app.PauseManager")
                if pm then pm:call(PAUSE_SIG, false, pause_value(), "IrisStableUI", nil) end
                U.paused = false
            end)
        end
        imgui.tree_pop()
    end
end)
