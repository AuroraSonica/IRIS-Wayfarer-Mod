-- IrisCustomize.lua -- the D2D creature CUSTOMIZE screen (RiftSpeak child-creator style).
-- Hotkey -> frame the active tamed companion (IrisCreatureCam) + FREEZE the world (PauseManager
-- debug-camera type) + a D2D menu. Pick a PART (auto-grouped from mesh materials), a preset
-- COLOUR, or open ADVANCED RGB sliders. Controller: left stick nav, right stick camera, A keep /
-- B back / X advanced. Accept/cancel with confirm dialogs (revert snapshot on cancel).

local CU = {
    open = false,
    parts = {}, part_i = 1,
    mode = "parts", chan_i = 1, preset_i = 1, slider = { 1.0, 1.0, 1.0 },
    entry = {}, staged = {}, dirty = false, dialog = nil,
    keys = {}, rep = {},
    fonts = nil, font_h = 0, reg = false,
    key = 0x43, info = "",
}

local PRESETS = {
    { "Natural", { 1.0, 1.0, 1.0 } }, { "Black", { 0.12, 0.12, 0.13 } }, { "Grey", { 0.5, 0.5, 0.5 } },
    { "White", { 1.5, 1.5, 1.5 } }, { "Brown", { 0.35, 0.22, 0.12 } }, { "Tan", { 0.72, 0.56, 0.36 } },
    { "Rust", { 0.6, 0.25, 0.12 } }, { "Red", { 0.62, 0.12, 0.1 } }, { "Ember", { 1.1, 0.45, 0.15 } },
    { "Gold", { 1.1, 0.8, 0.25 } }, { "Green", { 0.2, 0.5, 0.2 } }, { "Teal", { 0.15, 0.5, 0.5 } },
    { "Blue", { 0.2, 0.3, 0.7 } }, { "Indigo", { 0.3, 0.2, 0.6 } }, { "Purple", { 0.45, 0.2, 0.6 } },
    { "Pink", { 0.95, 0.45, 0.6 } }, { "Bone", { 0.9, 0.85, 0.7 } },
}

local PART_KEYS = {
    { "Wings", { "feather", "wing", "plume" } },
    { "Head", { "head", "face", "beak", "mane", "ear", "horn", "eye", "mouth" } },
    { "Body", { "chest", "stomach", "belly", "torso", "back", "body", "fur", "hair", "skin", "base", "neck" } },
    { "Legs", { "leg", "foot", "paw", "claw", "talon", "thigh", "hoof" } },
    { "Arms", { "arm", "hand" } },
    { "Tail", { "tail" } },
}

local function type_name(nm)
    nm = tostring(nm or "")
    if nm:find("ch253", 1, true) then return "Griffin" end
    if nm:find("ch223001", 1, true) then return "Dog" end
    if nm:find("ch223", 1, true) then return "Wolf" end
    if nm:find("ch299410", 1, true) then return "Crow" end
    if nm:find("ch299430", 1, true) then return "Bird" end
    if nm:find("ch299011", 1, true) then return "Doe" end
    return "Creature"
end

local function active_go()
    local g = nil
    pcall(function() if iris_active_go then g = iris_active_go() end end)
    if g and g.call then return g end
    return nil
end

-- ===== gamepad (stolen from RiftSpeakCreatorInput) =====
local PAD = { names = {}, dpad = { up = 0, down = 0, left = 0, right = 0 }, face = { a = 0, b = 0, x = 0 },
    prev = 0, held = nil, held_at = 0, rep_at = 0 }
local function load_pad_enum()
    local t = sdk.find_type_definition("via.hid.GamePadButton"); if not t then return end
    for _, f in ipairs(t:get_fields()) do
        pcall(function()
            if f:is_static() then
                local v; pcall(function() v = f:get_data() end); if v == nil then pcall(function() v = f:get_data(nil) end) end
                if type(v) == "number" then PAD.names[f:get_name()] = v end
            end
        end)
    end
    local function pick(...) for _, n in ipairs({ ... }) do if PAD.names[n] then return PAD.names[n] end end return 0 end
    PAD.dpad.up = pick("LUp", "Up", "DUp", "PadUp")
    PAD.dpad.down = pick("LDown", "Down", "DDown", "PadDown")
    PAD.dpad.left = pick("LLeft", "Left", "DLeft", "PadLeft")
    PAD.dpad.right = pick("LRight", "Right", "DRight", "PadRight")
    PAD.face.a = pick("Decide", "RDown", "A", "Cross", "South")
    PAD.face.b = pick("Cancel", "RRight", "B", "Circle", "East")
    PAD.face.x = pick("RLeft", "X", "Square", "West")
end
pcall(load_pad_enum)
local function pad_dev()
    local d; pcall(function() local s = sdk.get_native_singleton("via.hid.GamePad"); local t = sdk.find_type_definition("via.hid.GamePad"); d = sdk.call_native_func(s, t, "get_MergedDevice") end); return d
end
local function pad_button() local v = 0; local d = pad_dev(); if d then pcall(function() v = d:call("get_Button") or 0 end) end return math.floor(v) end
local function pad_axis_l() local x, y = 0, 0; local d = pad_dev(); if d then pcall(function() local a = d:call("get_AxisL"); if a then x = a.x or 0; y = a.y or 0 end end) end return x, y end
local function pad_axis_r() local x, y = 0, 0; local d = pad_dev(); if d then pcall(function() local a = d:call("get_AxisR"); if a then x = a.x or 0; y = a.y or 0 end end) end return x, y end
local function pad_held_dir(cur)
    local function held(b) return b ~= 0 and (cur & b) == b end
    if held(PAD.dpad.left) then return "left" end
    if held(PAD.dpad.right) then return "right" end
    if held(PAD.dpad.up) then return "up" end
    if held(PAD.dpad.down) then return "down" end
    local lx, ly = pad_axis_l()
    if math.abs(lx) > 0.6 and math.abs(lx) >= math.abs(ly) then return (lx > 0) and "right" or "left" end
    if math.abs(ly) > 0.6 then return (ly > 0) and "up" or "down" end
    return nil
end

-- ===== world freeze (debug-camera PauseType: no banner/dim) =====
local PAUSE_SIG = "requestPause(System.Boolean, app.PauseManager.PauseType, System.String, System.Action)"
local function pause_value()
    if CU.pause_val then return CU.pause_val end
    local list, sel = {}, 1
    pcall(function()
        local td = sdk.find_type_definition("app.PauseManager.PauseType")
        if td then for _, f in ipairs(td:get_fields()) do
            if f:is_static() then local v; pcall(function() v = f:get_data() end); if v == nil then pcall(function() v = f:get_data(nil) end) end
                if v ~= nil then list[#list + 1] = { name = f:get_name(), value = v } end
            end
        end end
    end)
    local function pp(pred) for i, e in ipairs(list) do if pred(e) then sel = i; return true end end return false end
    local _ = pp(function(e) local l = e.name:lower(); return l:find("debug") and l:find("cam") end)
        or pp(function(e) return e.name:lower():find("debug") end)
        or pp(function(e) return e.value == 1 end)
    CU.pause_val = (list[sel] and list[sel].value) or 1
    return CU.pause_val
end
local function world_pause(on)
    pcall(function()
        local pm = sdk.get_managed_singleton("app.PauseManager"); if not pm then return end
        if on and not CU.paused then CU.paused_type = pause_value(); pm:call(PAUSE_SIG, true, CU.paused_type, "IrisCustomize", nil); CU.paused = true
        elseif (not on) and CU.paused then pm:call(PAUSE_SIG, false, CU.paused_type or pause_value(), "IrisCustomize", nil); CU.paused = false; CU.paused_type = nil end
    end)
end

-- ===== parts + colour =====
local function build_parts(go)
    local parts, all_mats, groups = {}, {}, {}
    local mesh = nil
    pcall(function() mesh = go:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh")) end)
    if not mesh then return parts end
    local n = 0; pcall(function() n = mesh:call("get_MaterialNum") or 0 end)
    for mi = 0, (tonumber(n) or 0) - 1 do
        local mn = ""
        pcall(function() mn = tostring(mesh:call("getMaterialName", mi) or "") end)
        if mn ~= "" then
            all_mats[#all_mats + 1] = mn
            local low, placed = mn:lower(), false
            for _, pk in ipairs(PART_KEYS) do
                for _, kw in ipairs(pk[2]) do
                    if low:find(kw, 1, true) then groups[pk[1]] = groups[pk[1]] or {}; table.insert(groups[pk[1]], mn); placed = true; break end
                end
                if placed then break end
            end
            if not placed then groups["Other"] = groups["Other"] or {}; table.insert(groups["Other"], mn) end
        end
    end
    parts[#parts + 1] = { name = "All", mats = all_mats }
    for _, pk in ipairs(PART_KEYS) do
        if groups[pk[1]] and #groups[pk[1]] > 0 then parts[#parts + 1] = { name = pk[1], mats = groups[pk[1]] } end
    end
    if groups["Other"] and #groups["Other"] > 0 then parts[#parts + 1] = { name = "Other", mats = groups["Other"] } end
    return parts
end

local function apply_part(part, rgb)
    if not part then return end
    local go = active_go(); if not go then return end
    local matcolors = {}
    for _, mn in ipairs(part.mats or {}) do
        local rgba = { rgb[1], rgb[2], rgb[3], 1.0 }
        CU.staged[mn] = rgba; matcolors[mn] = rgba
    end
    pcall(function() if iris_recolor then iris_recolor(go, matcolors) end end)   -- LIVE only (persist on accept)
    part.color = { rgb[1], rgb[2], rgb[3] }
    CU.dirty = true
end

local function do_revert()
    local go = active_go(); if not go then return end
    local revert = {}
    for mn, _ in pairs(CU.staged) do revert[mn] = CU.entry[mn] or { 1.0, 1.0, 1.0, 1.0 } end
    if not next(revert) then return end
    pcall(function() if iris_recolor then iris_recolor(go, revert) end end)
    pcall(function() if iris_save_active_colors then iris_save_active_colors(revert) end end)
end

-- ===== open / close =====
local function close_screen()
    CU.open = false; CU.dialog = nil
    _G.IrisCustomizeOpen = false
    world_pause(false)
    pcall(function() if _G.IrisCreatureCam then _G.IrisCreatureCam.set_on(false) end end)
end
local function open_screen()
    local go = active_go()
    if not go then CU.info = "no active companion -- summon one first"; return false end
    CU.parts = build_parts(go)
    if #CU.parts == 0 then CU.info = "no colourable materials found"; return false end
    CU.entry = {}; pcall(function() if iris_get_active_colors then CU.entry = iris_get_active_colors() end end)
    CU.staged = {}; CU.dirty = false; CU.dialog = nil
    for _, part in ipairs(CU.parts) do
        local c = part.mats[1] and CU.entry[part.mats[1]]
        if c then part.color = { c[1], c[2], c[3] } else part.color = nil end
    end
    CU.part_i = 1; CU.mode = "parts"; CU.chan_i = 1; CU.preset_i = 1; CU.slider = { 1.0, 1.0, 1.0 }
    do local part = CU.parts[1]; local c = part and part.color
        if c then for i, pr in ipairs(PRESETS) do if math.abs(pr[2][1]-c[1])+math.abs(pr[2][2]-c[2])+math.abs(pr[2][3]-c[3]) < 0.06 then CU.preset_i = i; break end end end end
    _G.IrisCustomizeOpen = true
    pcall(function() if _G.IrisCreatureCam then _G.IrisCreatureCam.set_on(true) end end)
    world_pause(true)
    CU.open = true
    return true
end

-- ===== actions =====
local function cam_orbit(d) pcall(function() if _G.IrisCreatureCam then _G.IrisCreatureCam.orbit(d) end end) end
local function cam_zoom(d) pcall(function() if _G.IrisCreatureCam then _G.IrisCreatureCam.zoom(d) end end) end
local function toggle_advanced()
    if CU.mode == "parts" then
        CU.mode = "advanced"
        local c = CU.parts[CU.part_i] and CU.parts[CU.part_i].color or { 1, 1, 1 }
        CU.slider = { c[1] or 1, c[2] or 1, c[3] or 1 }
    else CU.mode = "parts" end
end
local function cycle_preset(delta)
    CU.preset_i = ((CU.preset_i - 1 + delta) % #PRESETS) + 1
    local pr = PRESETS[CU.preset_i]; if pr then apply_part(CU.parts[CU.part_i], pr[2]) end
end
local function adjust_slider(step)
    CU.slider[CU.chan_i] = math.max(0.0, math.min(2.0, (CU.slider[CU.chan_i] or 1.0) + step))
    apply_part(CU.parts[CU.part_i], { CU.slider[1], CU.slider[2], CU.slider[3] })
end
local function sync_preset()
    -- move the colour cursor onto whatever the current part already is
    local part = CU.parts[CU.part_i]
    local c = part and part.color
    if not c then CU.preset_i = 1; return end   -- Natural
    for i, pr in ipairs(PRESETS) do
        if math.abs(pr[2][1] - c[1]) + math.abs(pr[2][2] - c[2]) + math.abs(pr[2][3] - c[3]) < 0.06 then
            CU.preset_i = i; return
        end
    end
    -- a custom colour with no matching preset: leave the cursor where it is
end
local function confirm_dialog()
    if CU.dialog == "apply" then
        pcall(function() if iris_save_active_colors then iris_save_active_colors(CU.staged) end end)
        close_screen()
    elseif CU.dialog == "revert" then
        do_revert(); close_screen()
    end
    CU.dialog = nil
end

-- ===== keyboard edges =====
local function edge(vk)
    local d = false; pcall(function() d = iris_kb(vk) == true end)
    local was = CU.keys[vk] == true
    CU.keys[vk] = d
    return d and not was
end
local function held_repeat(vk, name)
    local d = false; pcall(function() d = iris_kb(vk) == true end)
    if not d then CU.rep[name] = nil; return false end
    local now = os.clock(); local st = CU.rep[name]
    if not st then CU.rep[name] = { first = now, last = now }; return true end
    if now - st.first < 0.34 then return false end
    if now - st.last > 0.055 then st.last = now; return true end
    return false
end

local function input_tick()
    if edge(math.floor(tonumber(CU.key) or 0x43)) then
        if CU.open then if CU.dirty then CU.dialog = "revert" else close_screen() end else open_screen() end
        return
    end
    if not CU.open then return end
    -- unified face buttons (keyboard + gamepad edge)
    local cur = pad_button()
    local gdown = cur & (~(PAD.prev or 0)); PAD.prev = cur
    local function ghit(b) return b ~= 0 and (gdown & b) == b end
    local a_hit = edge(0x0D) or ghit(PAD.face.a)                 -- Enter / A
    local b_hit = edge(0x1B) or edge(0x08) or ghit(PAD.face.b)   -- Esc / Backspace / B
    local x_hit = edge(0x46) or ghit(PAD.face.x)                 -- F / X : advanced
    -- DIALOG mode
    if CU.dialog then
        if a_hit then confirm_dialog() elseif b_hit then CU.dialog = nil end
        return
    end
    -- camera: keyboard Q/E/Z/X + right stick
    if held_repeat(0x51, "orbL") then cam_orbit(-6) end
    if held_repeat(0x45, "orbR") then cam_orbit(6) end
    if held_repeat(0x5A, "zin") then cam_zoom(-0.15) end
    if held_repeat(0x58, "zout") then cam_zoom(0.15) end
    local rrx, rry = pad_axis_r()
    if math.abs(rrx) > 0.15 then cam_orbit(rrx * 3.0) end
    if math.abs(rry) > 0.15 then cam_zoom(-rry * 0.08) end
    -- advanced toggle / accept / cancel
    if x_hit then toggle_advanced() end
    if a_hit then if CU.dirty then CU.dialog = "apply" else close_screen() end return end
    if b_hit then if CU.dirty then CU.dialog = "revert" else close_screen() end return end
    -- NAV: keyboard + gamepad (with auto-repeat)
    local kb_up = edge(0x26) or edge(0x57)
    local kb_down = edge(0x28) or edge(0x53)
    local kb_left = held_repeat(0x25, "l") or held_repeat(0x41, "la")
    local kb_right = held_repeat(0x27, "r") or held_repeat(0x44, "ra")
    local gdir = pad_held_dir(cur)
    local now = os.clock(); local gfire = false
    if gdir ~= PAD.held then PAD.held = gdir; PAD.held_at = now; PAD.rep_at = now; gfire = (gdir ~= nil)
    elseif gdir and (now - (PAD.held_at or 0)) >= 0.34 and (now - (PAD.rep_at or 0)) >= 0.06 then PAD.rep_at = now; gfire = true end
    local up = kb_up or (gfire and gdir == "up")
    local down = kb_down or (gfire and gdir == "down")
    local left = kb_left or (gfire and gdir == "left")
    local right = kb_right or (gfire and gdir == "right")
    if CU.mode == "parts" then
        if up then CU.part_i = ((CU.part_i - 2) % #CU.parts) + 1; sync_preset() end
        if down then CU.part_i = (CU.part_i % #CU.parts) + 1; sync_preset() end
        if left then cycle_preset(-1) elseif right then cycle_preset(1) end
    else
        if up then CU.chan_i = ((CU.chan_i - 2) % 3) + 1 end
        if down then CU.chan_i = (CU.chan_i % 3) + 1 end
        if left then adjust_slider(-0.04) elseif right then adjust_slider(0.04) end
    end
end

-- ===== D2D draw =====
function iris_cu_make_fonts(sh)
    -- ⭐ ONE ON-SCREEN FACE (07-21, Aurora): ask IrisFont so the customize screen wears the
    -- same serif as the Grip/Break gauges and follows the one shared size slider. This
    -- screen's own ladder survives underneath as the no-IrisFont fallback (it was the
    -- prototype for the shared one). Cache keyed on the RESOLVED px so moving the shared
    -- slider rebuilds the faces instead of silently keeping the old sizes.
    local F = _G.IrisFont
    local key = tostring(math.floor(sh)) .. ":" .. tostring((F and F.px) and F.px(34) or "-")
    if CU.fonts and CU.font_key == key then return CU.fonts end
    if not (_G.d2d and d2d.Font and d2d.Font.new) then return nil end
    local scale = sh / 1080.0
    local function font(px)
        if F and F.d2d and F.px then
            local shared = F.d2d(px)
            if shared then return shared, F.px(px) end
        end
        px = math.max(11, math.floor(px * scale))
        for _, fn in ipairs({ "LinLibertine_R.ttf", "times.ttf", "NotoSansJP-Regular.ttf" }) do
            local ok, f = pcall(d2d.Font.new, fn, px)
            if ok and f then return f, px end
        end
        return nil, px
    end
    local ft = {}
    ft.title_f, ft.title_px = font(34)
    ft.row_f, ft.row_px = font(24)
    ft.small_f, ft.small_px = font(18)
    if not (ft.title_f and ft.row_f and ft.small_f) then return nil end
    CU.fonts, CU.font_h, CU.font_key = ft, sh, key
    return ft
end
local function clampc(v) if v < 0 then return 0 elseif v > 1 then return 1 end return v end
local function swatch_hex(rgb)
    return math.floor(clampc(rgb[1] or 1) * 255) * 0x10000 + math.floor(clampc(rgb[2] or 1) * 255) * 0x100 + math.floor(clampc(rgb[3] or 1) * 255)
end

function iris_cu_draw()
    if not CU.open then return end
    if not (_G.d2d and d2d.fill_rect and d2d.text) then return end
    local sw, sh = 1920, 1080
    local ok, w, h = pcall(d2d.surface_size); if ok and w and h and h > 0 then sw = w; sh = h end
    local ft = iris_cu_make_fonts(sh); if not ft then return end
    local scale = sh / 1080.0
    local function argb(a, rgb) if a < 0 then a = 0 elseif a > 1 then a = 1 end return math.floor(255 * a) * 0x1000000 + (rgb % 0x1000000) end
    local function txt(font, s, x, y, col, a)
        pcall(d2d.text, font, s, x + 2, y + 2, argb((a or 1) * 0.7, 0x000000))
        pcall(d2d.text, font, s, x, y, argb(a or 1, col))
    end
    local C_ACCENT, C_PANEL, C_TITLE, C_ROW, C_DIM, C_SEL = 0xB4552A, 0x140E0A, 0xEAD8B0, 0xD8C9A8, 0x8A7A5E, 0x2A1C12
    local px = math.floor(40 * scale)
    local pw = math.floor(math.min(sw * 0.36, 560 * scale))
    local ph = math.floor(sh * 0.74)
    local py = math.floor((sh - ph) * 0.5)
    local b = math.max(2, math.floor(2.5 * scale))
    pcall(d2d.fill_rect, px + b * 2, py + b * 2, pw, ph, argb(0.4, 0x000000))
    pcall(d2d.fill_rect, px - b, py - b, pw + b * 2, ph + b * 2, argb(0.9, C_ACCENT))
    pcall(d2d.fill_rect, px, py, pw, ph, argb(0.95, C_PANEL))
    pcall(d2d.fill_rect, px, py, pw, math.max(4, math.floor(6 * scale)), argb(1.0, C_ACCENT))
    local ix = px + math.floor(28 * scale)
    local iw = pw - math.floor(56 * scale)
    local y = py + math.floor(24 * scale)
    local cname = "Creature"
    pcall(function() local g = active_go(); if g then cname = type_name(g:call("get_Name")) end end)
    txt(ft.title_f, "CUSTOMIZE  " .. cname, ix, y, C_TITLE, 1.0)
    y = y + (ft.title_px or 34) + math.floor(16 * scale)
    txt(ft.small_f, "PART", ix, y, C_DIM, 1.0); y = y + (ft.small_px or 18) + math.floor(6 * scale)
    local rowh = math.floor((ft.row_px or 24) * 1.45)
    for i, part in ipairs(CU.parts) do
        local sel = (i == CU.part_i)
        if sel then
            pcall(d2d.fill_rect, ix - math.floor(8 * scale), y - math.floor(2 * scale), iw + math.floor(16 * scale), rowh, argb(0.9, C_SEL))
            pcall(d2d.fill_rect, ix - math.floor(8 * scale), y - math.floor(2 * scale), math.max(3, math.floor(4 * scale)), rowh, argb(1.0, C_ACCENT))
        end
        txt(ft.row_f, part.name .. (part.color and "  *" or ""), ix, y, sel and C_TITLE or C_ROW, sel and 1.0 or 0.8)
        if part.color then pcall(d2d.fill_rect, ix + iw - math.floor(34 * scale), y + math.floor(2 * scale), math.floor(30 * scale), (ft.row_px or 24) - math.floor(2 * scale), argb(1.0, swatch_hex(part.color))) end
        y = y + rowh
    end
    y = y + math.floor(14 * scale)
    if CU.mode == "parts" then
        txt(ft.small_f, "COLOUR", ix, y, C_DIM, 1.0); y = y + (ft.small_px or 18) + math.floor(8 * scale)
        local pr = PRESETS[CU.preset_i]
        if pr then
            pcall(d2d.fill_rect, ix, y, math.floor(48 * scale), math.floor(34 * scale), argb(1.0, swatch_hex(pr[2])))
            txt(ft.row_f, pr[1], ix + math.floor(60 * scale), y + math.floor(3 * scale), C_TITLE, 1.0)
        end
        y = y + math.floor(46 * scale)
        local per = 9
        local sww = math.floor(iw / per)
        for i, p2 in ipairs(PRESETS) do
            local col = (i - 1) % per
            local rown = math.floor((i - 1) / per)
            local rx = ix + col * sww
            local ry = y + rown * math.floor(30 * scale)
            pcall(d2d.fill_rect, rx, ry, sww - math.floor(4 * scale), math.floor(24 * scale), argb(1.0, swatch_hex(p2[2])))
            if i == CU.preset_i then pcall(d2d.fill_rect, rx, ry, sww - math.floor(4 * scale), math.max(3, math.floor(3 * scale)), argb(1.0, C_TITLE)) end
        end
    else
        txt(ft.small_f, "ADVANCED", ix, y, C_DIM, 1.0); y = y + (ft.small_px or 18) + math.floor(10 * scale)
        local chans = { { "R", 0xC04030 }, { "G", 0x40A040 }, { "B", 0x4060C0 } }
        for ci, cc in ipairs(chans) do
            local val = CU.slider[ci] or 1.0
            local sel = (ci == CU.chan_i)
            txt(ft.row_f, cc[1], ix, y, sel and C_TITLE or C_ROW, sel and 1.0 or 0.8)
            local barx = ix + math.floor(30 * scale)
            local barw = iw - math.floor(90 * scale)
            pcall(d2d.fill_rect, barx, y + math.floor(6 * scale), barw, math.floor(14 * scale), argb(0.5, 0x000000))
            pcall(d2d.fill_rect, barx, y + math.floor(6 * scale), math.floor(barw * math.min(val / 2.0, 1.0)), math.floor(14 * scale), argb(1.0, cc[2]))
            if sel then pcall(d2d.fill_rect, barx - math.floor(3 * scale), y + math.floor(4 * scale), math.max(3, math.floor(3 * scale)), math.floor(18 * scale), argb(1.0, C_ACCENT)) end
            txt(ft.small_f, string.format("%.2f", val), barx + barw + math.floor(10 * scale), y + math.floor(3 * scale), C_ROW, 1.0)
            y = y + math.floor(28 * scale)
        end
        pcall(d2d.fill_rect, ix, y + math.floor(4 * scale), math.floor(60 * scale), math.floor(30 * scale), argb(1.0, swatch_hex(CU.slider)))
    end
    local fy = py + ph - math.floor(54 * scale)
    txt(ft.small_f, "L-stick / arrows: navigate      R-stick: camera (Q/E turn, Z/X zoom)", ix, fy, C_DIM, 1.0)
    txt(ft.small_f, "A / Enter: accept    B / Esc: back    X / F: " .. (CU.mode == "parts" and "advanced" or "presets"), ix, fy + (ft.small_px or 18) + math.floor(6 * scale), C_DIM, 1.0)
    -- confirm dialog over everything
    if CU.dialog then
        local dw = math.floor(math.min(sw * 0.44, 680 * scale))
        local dh = math.floor(190 * scale)
        local dx = math.floor((sw - dw) * 0.5)
        local dy = math.floor((sh - dh) * 0.42)
        pcall(d2d.fill_rect, 0, 0, sw, sh, argb(0.45, 0x000000))
        pcall(d2d.fill_rect, dx - b, dy - b, dw + b * 2, dh + b * 2, argb(0.95, C_ACCENT))
        pcall(d2d.fill_rect, dx, dy, dw, dh, argb(0.98, C_PANEL))
        pcall(d2d.fill_rect, dx, dy, dw, math.max(4, math.floor(6 * scale)), argb(1.0, C_ACCENT))
        local q = (CU.dialog == "apply") and "Apply these changes?" or "Revert these changes?"
        local function cen(font, s, ty, col)
            local mw = #tostring(s) * 9; pcall(function() local ok2, m = pcall(d2d.measure_text, font, s); if ok2 and m and m > 0 then mw = m end end)
            txt(font, s, math.floor(dx + (dw - mw) * 0.5), ty, col, 1.0)
        end
        cen(ft.title_f, q, dy + math.floor(40 * scale), C_TITLE)
        cen(ft.row_f, "A / Enter:  Yes            B / Esc:  No", dy + math.floor(40 * scale) + (ft.title_px or 34) + math.floor(24 * scale), C_ROW)
    end
end

-- ===== hooks =====
re.on_frame(function()
    pcall(input_tick)
    if not CU.reg and _G.d2d and type(d2d.register) == "function" then
        pcall(function()
            d2d.register(function() iris_cu_make_fonts(1080) end, function() iris_cu_draw() end)
            CU.reg = true
        end)
    end
    -- LIVE PREVIEW FIX (Aurora): the game re-asserts each material's BaseColor every frame, so a
    -- one-shot iris_recolor (apply_part) gets clobbered next frame -> the preview never showed the new
    -- colours, only Apply did (Apply persists via iris_recolor_tick). Re-assert the STAGED colours every
    -- frame while the screen is open so the preview updates live.
    if CU.open and iris_recolor and CU.staged and next(CU.staged) then
        pcall(function() local g = active_go(); if g then iris_recolor(g, CU.staged) end end)
    end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("I.R.I.S. customize screen") then return end
    imgui.text("Hotkey frames the active companion + freezes the world + opens the colour menu.")
    local c
    c, CU.key = imgui.drag_int("open hotkey (VK)", math.floor(tonumber(CU.key) or 0x43), 1, 0x08, 0xFE)
    local kc = math.floor(tonumber(CU.key) or 0x43)
    imgui.text("hotkey: " .. ((kc >= 0x41 and kc <= 0x5A) and string.char(kc) or string.format("0x%X", kc)))
    if imgui.button(CU.open and "Close screen" or "Open screen") then if CU.open then close_screen() else open_screen() end end
    imgui.text(tostring(CU.info or ""))
    imgui.text("D2D: " .. (CU.reg and "on" or "waiting") .. "   pad face A/B/X: " .. string.format("0x%X/0x%X/0x%X", PAD.face.a, PAD.face.b, PAD.face.x))
    imgui.tree_pop()
end)

_G.IrisCustomize = {
    open = function() return open_screen() end,
    close = function() close_screen() end,
    is_open = function() return CU.open end,
    get_key = function() return math.floor(tonumber(CU.key) or 0x43) end,
    set_key = function(vk) CU.key = math.floor(tonumber(vk) or 0x43) end,
}

re.on_script_reset(function()
    if CU.paused then pcall(function() world_pause(false) end) end
end)


-- the TYPING GUARD fallback (the real one lives in IrisTaming): no IRIS hotkey exists while
-- the RiftSpeak prompt box is open
if not iris_kb then
    function iris_kb(vk9)
        if type(iris_input_blocked) == "function" and iris_input_blocked() then return false end
        if _G.RiftSpeakPromptOpen == true or _G.RiftSpeak_PromptOpen == true then return false end
        local dn9 = false
        pcall(function() dn9 = reframework:is_key_down(vk9) == true end)
        return dn9
    end
end