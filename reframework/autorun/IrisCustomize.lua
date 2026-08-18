-- IrisCustomize.lua -- the D2D creature CUSTOMISE screen (RiftSpeak child-creator style).
-- Framing = IrisCreatureCam + a PauseManager debug-camera freeze (no banner, no dim).
--
-- ⭐⭐ 08-16 REDESIGN (Aurora's tidy-up pass):
--  1. NO GLOBAL HOTKEY. The Stable owns the door now ([C] / DpadLeft on a summoned row), so
--     C stays free out in the world. Reached only through _G.IrisCustomize.open().
--  2. TWO SECTIONS, not one list with a colour strip glued underneath:
--       PART   -- walk to the part you want, A steps DOWN into the colour section
--       COLOUR -- presets (or advanced RGB); A keeps the colour and steps back UP, B cancels
--                 it back to what it was when you entered
--     Under the last part sits ACCEPT CHANGES, which raises the usual confirm dialog.
--  3. DOCKED LEFT + height fitted to its content, so the framed creature is never behind it
--     (the panel used to sit dead centre over the animal you were trying to look at).
--  4. The header reads the creature's real KIND from the stable row -- a converted ch299011
--     body is a Horse or a Unicorn, never the "Doe" chassis it was built from.

local PRESET_PER_ROW = 9

local CU = {
    open = false,
    parts = {}, part_i = 1, on_accept = false,
    focus = "parts",          -- "parts" | "colour"  (which section owns the cursor)
    adv = false,              -- inside COLOUR: RGB sliders instead of the preset grid
    chan_i = 1, preset_i = 1, slider = { 1.0, 1.0, 1.0 },
    entry = {}, staged = {}, dirty = false, dialog = nil,
    col_snap = nil,           -- the part's colour as it was when COLOUR was entered (B undoes to this)
    keys = {}, rep = {},
    fonts = nil, font_h = 0, reg = false,
    kind = "Creature", info = "",
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
    -- last-resort chassis ladder (see kind_name below -- this only runs when nothing that
    -- actually knows the creature is loaded)
    nm = tostring(nm or "")
    if nm:find("ch253", 1, true) then return "Griffin" end
    if nm:find("ch257", 1, true) then return "Drake" end
    -- 08-14: ch223001 is the Redwolf chassis and the IRIS cat pak makes both its prefabs cats
    -- (_01 Panther, _00 Puma) - this header used to read "DOG - PART" over a panther
    if nm:find("ch223001_01", 1, true) then return "Panther" end
    if nm:find("ch223001", 1, true) then return "Puma" end
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

-- ⭐ 08-16 (Aurora: "this UI says Doe, but this creature I'm customizing is a horse"): the
-- STABLE ROW is the only place that knows a converted ch299011 body is a Horse -- or a
-- Unicorn -- rather than the Doe chassis it was built from, because the KIND and VARIANT
-- live on the record, not on the GameObject name. Ask the bridge first, then the shared
-- name book (IrisSpecies), and only then this file's own chassis ladder. Resolved ONCE at
-- open: stable_list() walks every companion and reads HP, so it is not a per-frame call.
local function kind_name(go)
    local lbl = nil
    pcall(function()
        local b = rawget(_G, "IrisGriffinBridge")
        for _, r in ipairs((b and b.stable_list and b.stable_list()) or {}) do
            if r.live and type(r.label) == "string" and r.label ~= "" then lbl = r.label; break end
        end
    end)
    if lbl and lbl ~= "" then return lbl end
    pcall(function()
        local SP = rawget(_G, "IrisSpecies")
        if SP and SP.name then lbl = SP.name(go) end
    end)
    if lbl and lbl ~= "" then return lbl end
    local nm = nil
    pcall(function() nm = go and go:call("get_Name") end)
    return type_name(nm)
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

-- DIRTY is now MEASURED, not latched (08-16): the Accept Changes row dims itself when there
-- is nothing to accept, and cancelling a colour has to be able to take dirty back off.
local function same_c(a, b) return math.abs((a or 1.0) - (b or 1.0)) < 0.004 end
-- an untinted material captures as BaseColor 1,1,1 -- so "has a colour" must mean "is tinted",
-- otherwise EVERY part wears a white swatch and a * the moment the screen opens (08-16)
local function is_tinted(c)
    return c ~= nil and not (same_c(c[1], 1.0) and same_c(c[2], 1.0) and same_c(c[3], 1.0))
end
local function recompute_dirty()
    local d = false
    for mn, c in pairs(CU.staged) do
        local e = CU.entry[mn]
        if e then
            if not (same_c(c[1], e[1]) and same_c(c[2], e[2]) and same_c(c[3], e[3])) then d = true; break end
        elseif not (same_c(c[1], 1.0) and same_c(c[2], 1.0) and same_c(c[3], 1.0)) then
            d = true; break   -- never customised + not plain Natural = a real change
        end
    end
    CU.dirty = d
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
    recompute_dirty()
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
    CU.open = false; CU.dialog = nil; CU.col_snap = nil
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
    CU.staged = {}; CU.dirty = false; CU.dialog = nil; CU.col_snap = nil
    CU.kind = kind_name(go)
    for _, part in ipairs(CU.parts) do
        local c = part.mats[1] and CU.entry[part.mats[1]]
        if c then part.color = { c[1], c[2], c[3] } else part.color = nil end
    end
    CU.part_i = 1; CU.on_accept = false; CU.focus = "parts"; CU.adv = false
    CU.chan_i = 1; CU.preset_i = 1; CU.slider = { 1.0, 1.0, 1.0 }
    do local part = CU.parts[1]; local c = part and part.color
        if c then for i, pr in ipairs(PRESETS) do if math.abs(pr[2][1]-c[1])+math.abs(pr[2][2]-c[2])+math.abs(pr[2][3]-c[3]) < 0.06 then CU.preset_i = i; break end end end end
    -- swallow whatever is already HELD as the screen opens: the button that opened this must
    -- not also land as its first command (the same-frame double-edge trap the Stable hit).
    -- Marking held keys as already-down makes the first edge require a genuine re-press.
    CU.keys = {}; CU.rep = {}
    for _, vk in ipairs({ 0x0D, 0x1B, 0x08, 0x46, 0x26, 0x28, 0x57, 0x53, 0x25, 0x27, 0x41, 0x44 }) do
        local d = false; pcall(function() d = iris_kb(vk) == true end)
        CU.keys[vk] = d
    end
    PAD.prev = pad_button()
    PAD.held = pad_held_dir(PAD.prev); PAD.held_at = os.clock(); PAD.rep_at = PAD.held_at
    _G.IrisCustomizeOpen = true
    pcall(function() if _G.IrisCreatureCam then _G.IrisCreatureCam.set_on(true) end end)
    world_pause(true)
    CU.open = true
    return true
end

-- ===== actions =====
local function cam_orbit(d) pcall(function() if _G.IrisCreatureCam then _G.IrisCreatureCam.orbit(d) end end) end
local function cam_zoom(d) pcall(function() if _G.IrisCreatureCam then _G.IrisCreatureCam.zoom(d) end end) end

local function set_preset(i)
    CU.preset_i = math.max(1, math.min(#PRESETS, math.floor(i)))
    local pr = PRESETS[CU.preset_i]; if pr then apply_part(CU.parts[CU.part_i], pr[2]) end
end
local function cycle_preset(delta)
    set_preset(((CU.preset_i - 1 + delta) % #PRESETS) + 1)
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

-- ── section handover: PART -> COLOUR and back ───────────────────────────────────────────
local function enter_colour()
    local part = CU.parts[CU.part_i]; if not part then return end
    sync_preset()
    -- snapshot every mat this part owns EXACTLY as it stands, so B can put it back
    local snap = {}
    for _, mn in ipairs(part.mats or {}) do
        local c = CU.staged[mn]
        if c then snap[mn] = { c[1], c[2], c[3], c[4] or 1.0 } end
    end
    CU.col_snap = { mats = snap, color = part.color and { part.color[1], part.color[2], part.color[3] } or nil }
    CU.focus = "colour"
end
local function keep_colour()
    CU.col_snap = nil
    CU.focus = "parts"; CU.adv = false
end
local function cancel_colour()
    local part = CU.parts[CU.part_i]
    local s = CU.col_snap
    if part and s then
        local restore = {}
        for _, mn in ipairs(part.mats or {}) do
            local c = s.mats[mn] or CU.entry[mn] or { 1.0, 1.0, 1.0, 1.0 }
            restore[mn] = { c[1], c[2], c[3], c[4] or 1.0 }
            -- ⛔ keep it STAGED (at its old value) rather than dropping it: the per-frame
            -- re-assert below is what actually holds a colour on the body, and a mat that
            -- leaves the staged table stops being held mid-preview. recompute_dirty()
            -- knows an unchanged staged entry is not a change.
            CU.staged[mn] = restore[mn]
        end
        pcall(function() local g = active_go(); if g and iris_recolor then iris_recolor(g, restore) end end)
        part.color = s.color
    end
    CU.col_snap = nil
    CU.focus = "parts"; CU.adv = false
    recompute_dirty(); sync_preset()
end
local function toggle_advanced()
    if CU.focus ~= "colour" then
        if CU.on_accept then return end   -- the Accept row has no colour to open
        enter_colour()
        CU.adv = true
    else
        CU.adv = not CU.adv
    end
    if CU.adv then
        local c = CU.parts[CU.part_i] and CU.parts[CU.part_i].color or { 1, 1, 1 }
        CU.slider = { c[1] or 1, c[2] or 1, c[3] or 1 }
    end
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
    -- ⭐ 08-16: NO global open hotkey any more. The Stable screen is the only door (its row
    -- action defers the open to a live frame, which is also the only SAFE way in -- opening
    -- straight off the paused menu frame was never sound).
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
    -- advanced sliders: one button, from either section
    if x_hit then toggle_advanced(); return end
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

    if CU.focus == "parts" then
        -- A = step DOWN into the colour section for this part (or fire Accept Changes)
        if a_hit then
            if CU.on_accept then
                if CU.dirty then CU.dialog = "apply" else close_screen() end
            else
                enter_colour()
            end
            return
        end
        if b_hit then if CU.dirty then CU.dialog = "revert" else close_screen() end return end
        local n = #CU.parts
        if up then
            if CU.on_accept then CU.on_accept = false; CU.part_i = n
            elseif CU.part_i <= 1 then CU.on_accept = true
            else CU.part_i = CU.part_i - 1 end
            sync_preset()
        end
        if down then
            if CU.on_accept then CU.on_accept = false; CU.part_i = 1
            elseif CU.part_i >= n then CU.on_accept = true
            else CU.part_i = CU.part_i + 1 end
            sync_preset()
        end
    else
        -- COLOUR section: A keeps and steps back up, B undoes this part and steps back up
        if a_hit then keep_colour(); return end
        if b_hit then cancel_colour(); return end
        if CU.adv then
            if up then CU.chan_i = ((CU.chan_i - 2) % 3) + 1 end
            if down then CU.chan_i = (CU.chan_i % 3) + 1 end
            if left then adjust_slider(-0.04) elseif right then adjust_slider(0.04) end
        else
            if left then cycle_preset(-1) elseif right then cycle_preset(1) end
            if up then
                -- off the top row = back up to the part list, keeping what you picked
                if CU.preset_i <= PRESET_PER_ROW then keep_colour(); return end
                set_preset(CU.preset_i - PRESET_PER_ROW)
            elseif down then
                if CU.preset_i + PRESET_PER_ROW <= #PRESETS then set_preset(CU.preset_i + PRESET_PER_ROW)
                elseif CU.preset_i <= PRESET_PER_ROW then set_preset(#PRESETS) end
            end
        end
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
    local function u(v) return math.floor(v * scale) end
    local function argb(a, rgb) if a < 0 then a = 0 elseif a > 1 then a = 1 end return math.floor(255 * a) * 0x1000000 + (rgb % 0x1000000) end
    local function txt(font, s, x, y, col, a)
        pcall(d2d.text, font, s, x + 2, y + 2, argb((a or 1) * 0.7, 0x000000))
        pcall(d2d.text, font, s, x, y, argb(a or 1, col))
    end
    -- Same visual grammar as the Stable and decoration screen: smoke glass, fine gold
    -- rules, cream headings and a translucent gold selection.
    local C_ACCENT, C_PANEL, C_TITLE, C_ROW, C_DIM, C_SEL, C_INSET =
        0xC8A050, 0x14141A, 0xE8D8A8, 0xD8D0BC, 0x8E8A82, 0xC8A050, 0x000000

    -- ── metrics: the panel is FITTED to its content (08-16) so it stops being a slab of
    -- empty smoke, and DOCKED LEFT so the framed creature stays in the clear.
    local tpx, rpx, spx = (ft.title_px or 34), (ft.row_px or 24), (ft.small_px or 18)
    local pad_top   = u(18)
    local title_h   = tpx + u(16)
    local head_h    = spx + u(8)
    local rowh      = math.floor(rpx * 1.45)
    local acc_gap   = u(12)
    local parts_h   = #CU.parts * rowh + acc_gap + rowh + u(8)
    local gap_mid   = u(14)
    local cur_h     = u(46)
    local grid_rows = math.ceil(#PRESETS / PRESET_PER_ROW)
    local grid_h    = grid_rows * u(30)
    local adv_h     = 3 * u(28) + u(42)
    local body_h    = head_h + (CU.adv and adv_h or (cur_h + grid_h))
    local foot_h    = u(20) + spx + u(6) + spx + u(14)
    local ph = pad_top + title_h + head_h + parts_h + gap_mid + body_h + foot_h
    local pw = math.floor(math.min(sw * 0.40, 660 * scale))
    local px = u(48)
    local py = math.floor((sh - ph) * 0.5)
    local b = math.max(2, u(2))
    pcall(d2d.fill_rect, px + b * 2, py + b * 2, pw, ph, argb(0.4, 0x000000))
    pcall(d2d.fill_rect, px, py, pw, ph, argb(0.95, C_PANEL))
    pcall(d2d.fill_rect, px, py, pw, b, argb(1.0, C_ACCENT))
    pcall(d2d.fill_rect, px, py + ph - b, pw, b, argb(1.0, C_ACCENT))
    local ix = px + u(20)
    local iw = pw - u(40)
    local y = py + pad_top

    local on_parts = (CU.focus == "parts")
    local part_now = CU.parts[CU.part_i]

    txt(ft.title_f, "The Stable  /  Customise", ix, y, C_TITLE, 1.0)
    y = y + title_h

    -- ── SECTION 1: PART ─────────────────────────────────────────────────────────────────
    txt(ft.small_f, tostring(CU.kind or "Creature") .. "  -  Part", ix, y, C_ACCENT, on_parts and 1.0 or 0.5)
    y = y + head_h
    local parts_y = y
    pcall(d2d.fill_rect, ix - u(8), parts_y - u(4), iw + u(16), parts_h, argb(0.32, C_INSET))
    for i, part in ipairs(CU.parts) do
        local sel = (i == CU.part_i) and not CU.on_accept
        if sel then
            -- dimmer while the COLOUR section holds the cursor: you can still see which part
            -- you are painting, but the bright selection lives where your input goes
            pcall(d2d.fill_rect, ix - u(8), y - u(2), iw + u(16), rowh, argb(on_parts and 0.34 or 0.16, C_SEL))
            pcall(d2d.fill_rect, ix - u(8), y - u(2), math.max(2, u(3)), rowh, argb(on_parts and 1.0 or 0.6, C_ACCENT))
        end
        local tinted = is_tinted(part.color)
        txt(ft.row_f, part.name .. (tinted and "  *" or ""), ix, y, sel and C_TITLE or C_ROW, sel and 1.0 or 0.8)
        if tinted then pcall(d2d.fill_rect, ix + iw - u(34), y + u(2), u(30), rpx - u(2), argb(1.0, swatch_hex(part.color))) end
        y = y + rowh
    end
    -- ── the ACCEPT CHANGES line, under the last part (Aurora, 08-16) ────────────────────
    pcall(d2d.fill_rect, ix - u(8), y + math.floor(acc_gap * 0.5), iw + u(16), math.max(1, u(1)), argb(0.35, C_ACCENT))
    y = y + acc_gap
    do
        local sel = CU.on_accept
        if sel then
            pcall(d2d.fill_rect, ix - u(8), y - u(2), iw + u(16), rowh, argb(on_parts and 0.34 or 0.16, C_SEL))
            pcall(d2d.fill_rect, ix - u(8), y - u(2), math.max(2, u(3)), rowh, argb(on_parts and 1.0 or 0.6, C_ACCENT))
        end
        txt(ft.row_f, "Accept Changes", ix, y,
            sel and C_TITLE or (CU.dirty and C_ACCENT or C_ROW), CU.dirty and 1.0 or 0.5)
        y = y + rowh
    end
    y = y + u(8) + gap_mid

    -- ── SECTION 2: COLOUR ───────────────────────────────────────────────────────────────
    local ca = on_parts and 0.55 or 1.0     -- the inactive section reads as context, not input
    local chead = "Colour"
    if not on_parts and part_now then chead = "Colour  -  " .. tostring(part_now.name) end
    txt(ft.small_f, CU.adv and (chead .. "  (Advanced)") or chead, ix, y, C_ACCENT, on_parts and 0.5 or 1.0)
    y = y + head_h
    if not CU.adv then
        local pr = PRESETS[CU.preset_i]
        if pr then
            pcall(d2d.fill_rect, ix, y, u(48), u(34), argb(ca, swatch_hex(pr[2])))
            txt(ft.row_f, pr[1], ix + u(60), y + u(3), C_TITLE, ca)
        end
        y = y + cur_h
        local sww = math.floor(iw / PRESET_PER_ROW)
        for i, p2 in ipairs(PRESETS) do
            local col = (i - 1) % PRESET_PER_ROW
            local rown = math.floor((i - 1) / PRESET_PER_ROW)
            local rx = ix + col * sww
            local ry = y + rown * u(30)
            pcall(d2d.fill_rect, rx, ry, sww - u(4), u(24), argb(ca, swatch_hex(p2[2])))
            if i == CU.preset_i then
                -- the cursor is a full ring while COLOUR owns the input, a hairline otherwise
                if on_parts then
                    pcall(d2d.fill_rect, rx, ry, sww - u(4), math.max(2, u(2)), argb(0.7, C_TITLE))
                else
                    local t = math.max(2, u(3))
                    pcall(d2d.fill_rect, rx - t, ry - t, sww - u(4) + t * 2, t, argb(1.0, C_TITLE))
                    pcall(d2d.fill_rect, rx - t, ry + u(24), sww - u(4) + t * 2, t, argb(1.0, C_TITLE))
                    pcall(d2d.fill_rect, rx - t, ry - t, t, u(24) + t * 2, argb(1.0, C_TITLE))
                    pcall(d2d.fill_rect, rx + sww - u(4), ry - t, t, u(24) + t * 2, argb(1.0, C_TITLE))
                end
            end
        end
        y = y + grid_h
    else
        local chans = { { "R", 0xC04030 }, { "G", 0x40A040 }, { "B", 0x4060C0 } }
        for ci, cc in ipairs(chans) do
            local val = CU.slider[ci] or 1.0
            local sel = (ci == CU.chan_i)
            txt(ft.row_f, cc[1], ix, y, sel and C_TITLE or C_ROW, (sel and 1.0 or 0.8) * ca)
            local barx = ix + u(30)
            local barw = iw - u(90)
            pcall(d2d.fill_rect, barx, y + u(6), barw, u(14), argb(0.5, 0x000000))
            pcall(d2d.fill_rect, barx, y + u(6), math.floor(barw * math.min(val / 2.0, 1.0)), u(14), argb(ca, cc[2]))
            if sel then pcall(d2d.fill_rect, barx - u(3), y + u(4), math.max(3, u(3)), u(18), argb(ca, C_ACCENT)) end
            txt(ft.small_f, string.format("%.2f", val), barx + barw + u(10), y + u(3), C_ROW, ca)
            y = y + u(28)
        end
        pcall(d2d.fill_rect, ix, y + u(4), u(60), u(30), argb(ca, swatch_hex(CU.slider)))
        y = y + u(42)
    end

    -- ── footer: the two lines say what THIS section's buttons do, not a fixed legend ─────
    local fy = py + ph - (spx + u(6) + spx + u(14))
    txt(ft.small_f, "L-Stick / Arrows: Navigate      R-Stick: Camera  (Q/E Turn, Z/X Zoom)", ix, fy, C_DIM, 1.0)
    local line2
    if on_parts then
        if CU.on_accept then
            line2 = "A / Enter: Accept Changes      B / Esc: Back"
        else
            line2 = "A / Enter: Choose Colour      B / Esc: Back      X / F: Advanced"
        end
    else
        line2 = "A / Enter: Keep Colour      B / Esc: Cancel      X / F: "
            .. (CU.adv and "Presets" or "Advanced")
    end
    txt(ft.small_f, line2, ix, fy + spx + u(6), C_DIM, 1.0)

    -- confirm dialog over everything
    if CU.dialog then
        local dw = math.floor(math.min(sw * 0.44, 680 * scale))
        local dh = u(190)
        local dx = math.floor((sw - dw) * 0.5)
        local dy = math.floor((sh - dh) * 0.42)
        pcall(d2d.fill_rect, 0, 0, sw, sh, argb(0.45, 0x000000))
        pcall(d2d.fill_rect, dx, dy, dw, dh, argb(0.98, C_PANEL))
        pcall(d2d.fill_rect, dx, dy, dw, b, argb(1.0, C_ACCENT))
        pcall(d2d.fill_rect, dx, dy + dh - b, dw, b, argb(1.0, C_ACCENT))
        local q = (CU.dialog == "apply") and "Apply These Changes?" or "Revert These Changes?"
        local function cen(font, s, ty, col)
            local mw = #tostring(s) * 9; pcall(function() local ok2, m = pcall(d2d.measure_text, font, s); if ok2 and m and m > 0 then mw = m end end)
            txt(font, s, math.floor(dx + (dw - mw) * 0.5), ty, col, 1.0)
        end
        cen(ft.title_f, q, dy + u(40), C_TITLE)
        cen(ft.row_f, "A / Enter:  Yes            B / Esc:  No", dy + u(40) + tpx + u(24), C_ROW)
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
    imgui.text("Frames the active companion + freezes the world + opens the colour menu.")
    imgui.text("No hotkey: open it from THE STABLE screen ([C] / DpadLeft on a summoned row).")
    if imgui.button(CU.open and "Close screen" or "Open screen") then if CU.open then close_screen() else open_screen() end end
    imgui.text(tostring(CU.info or ""))
    imgui.text("D2D: " .. (CU.reg and "on" or "waiting") .. "   pad face A/B/X: " .. string.format("0x%X/0x%X/0x%X", PAD.face.a, PAD.face.b, PAD.face.x))
    imgui.tree_pop()
end)

_G.IrisCustomize = {
    open = function() return open_screen() end,
    close = function() close_screen() end,
    is_open = function() return CU.open end,
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
