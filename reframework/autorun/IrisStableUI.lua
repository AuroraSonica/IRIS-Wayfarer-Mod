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

local function edge(vk, repeat_after, repeat_every)
    local now = os.clock()
    local dn = kb(vk)
    local h = held[vk]
    if dn and not h then
        held[vk] = { at = now, rep = now + (repeat_after or 1e9) }
        return true
    elseif dn and h and repeat_after and now >= h.rep then
        h.rep = now + (repeat_every or 0.12)
        return true
    elseif not dn then
        held[vk] = nil
    end
    return false
end

local function say(s) U.msg = tostring(s); U.msg_until = os.clock() + 3.0 end
local function bridge() return rawget(_G, "IrisGriffinBridge") end
local function stable_rows()
    local b = bridge()
    local rows = nil
    pcall(function() rows = b and b.stable_list and b.stable_list() or nil end)
    return rows or {}
end

-- ── input tick ──────────────────────────────────────────────────────────────────────────
local function input_tick()
    if edge(C.key_toggle) then
        U.open = not U.open
        U.confirm_id = nil
        if U.open then U.cursor = 1 end
    end
    if not U.open then return end
    local rows = stable_rows()
    if #rows == 0 then return end
    if U.cursor > #rows then U.cursor = #rows end
    if U.cursor < 1 then U.cursor = 1 end
    if edge(C.key_up, 0.35, 0.12) then U.cursor = math.max(1, U.cursor - 1); U.confirm_id = nil end
    if edge(C.key_down, 0.35, 0.12) then U.cursor = math.min(#rows, U.cursor + 1); U.confirm_id = nil end
    local row = rows[U.cursor]
    if not row then return end
    local b = bridge()
    if edge(C.key_summon) and b then
        local ok, why = nil, nil
        pcall(function() ok, why = b.stable_summon(row.id) end)
        say((ok and "" or "cannot summon: ") .. tostring(why or (ok and "summoning" or "?")))
    end
    if edge(C.key_dismiss) and b then
        local ok, why = nil, nil
        pcall(function() ok, why = b.stable_dismiss() end)
        say(tostring(why or (ok and "dismissed" or "nothing to dismiss")))
    end
    if edge(C.key_release) and b then
        local now = os.clock()
        if U.confirm_id == row.id and now < (tonumber(U.confirm_until) or 0.0) then
            U.confirm_id = nil
            local ok, why = nil, nil
            pcall(function() ok, why = b.stable_release(row.id) end)
            say(ok and (tostring(row.name) .. " released. Farewell.") or ("cannot release: " .. tostring(why)))
        else
            U.confirm_id = row.id
            U.confirm_until = now + 3.0
            say("RELEASE " .. tostring(row.name) .. " FOREVER? Press Delete again to confirm.")
        end
    end
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
            -- ⛔ no ♀/♂ glyphs: Sovngarde has none (they rendered "?") -- gender lives in
            -- the detail pane as a word instead
            local col = (i == U.cursor) and 0xFFFFF0C8 or (r.live and COL.alive or COL.body)
            txt(string.format("%s  (%s)%s", tostring(r.name or "?"),
                tostring(r.label or "?"), r.live and "  [Out]" or ""),
                X + pad + 6.0 * sc, yy, col)
        end
        -- detail pane
        local r = rows[U.cursor]
        if r then
            local gword = (r.gender == "female" and "Female") or (r.gender == "male" and "Male") or "?"
            txt(string.format("%s  -  %s %s", tostring(r.name or "?"), gword, tostring(r.label or "?")),
                rx + 10.0 * sc, ly + 2.0 * sc, COL.cream, true)
            local status = r.live and "With You Now" or (r.active and "Selected - Not Summoned" or "Resting In The Stable")
            if r.hatch then status = status .. "  (Hatchling)" end
            if r.wyrm then status = status .. "  (Wyrm-Grown)" end
            txt(status, rx + 10.0 * sc, ly + 36.0 * sc, r.live and 0xFF9AE89A or COL.dimtxt)
            local by = ly + 66.0 * sc
            local bar_x = rx + 70.0 * sc
            local bar_w = rw - 200.0 * sc   -- room for "99990 / 100000" beside the bar
            -- current health (Aurora's ask): live body reads live; parked souls read the
            -- stable-rest fields; nothing readable = an honest dash
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
            by = by + 34.0 * sc
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
    txt("[O] Close   [Enter] Summon   [Backspace] Dismiss   [Delete x2] Release",
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

re.on_frame(function()
    pcall(input_tick)
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
        if imgui.button("Open/close now") then U.open = not U.open end
        imgui.tree_pop()
    end
end)
