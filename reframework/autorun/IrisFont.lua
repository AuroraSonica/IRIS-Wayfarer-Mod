-- ============================================================================
-- IrisFont.lua -- ONE on-screen face for every I.R.I.S. mod (2026-07-21, Aurora:
-- "change any of the onscreen fonts to be the same one used in the Break/Grip bars").
--
-- THE PROBLEM THIS SOLVES: three files each made their own independent font
-- decision -- GriffinRideProbe used d2d "Constantia", IrisCustomize used its own
-- LinLibertine ladder, IrisTaming's ritual banner used the imgui DEFAULT bitmap
-- face, and every world marker used draw.text (which takes NO font argument at
-- all and therefore can never be restyled in place). This module is the single
-- place the face, the size ladder and the resolution scale are decided.
--
-- ⛔ SCOPE LAW (Aurora): this is for ON-SCREEN player-facing text ONLY. The
-- REFramework config panels keep the plain imgui look on purpose -- a REF panel
-- should read as a REF panel.
--
-- API (all lazy -- NEVER touch _G.IrisFont at file-load time, only inside a
-- draw callback, because autorun load order is alphabetical and IrisCustomize
-- sorts BEFORE IrisFont):
--   IrisFont.ready()                    -> is the d2d layer up with a real face
--   IrisFont.px(base)                   -> base px authored at 1080p, scaled to this screen
--   IrisFont.d2d(base)                  -> a cached d2d font handle (or nil)
--   IrisFont.imgui(base)                -> a cached imgui font handle (or nil)
--   IrisFont.text(str,x,y,argb[,base][,shadow]) -> queue screen text; TRUE if it took it
--   IrisFont.card(title,sub[,argb])     -> feed the ritual card (call every frame while live)
--   IrisFont.card_live()                -> is the d2d card drawing (so callers skip their imgui fallback)
--
-- ⭐ THE draw.text SWAP: `draw.text(s,x,y,c)` becomes
--   `if not IrisFont.text(s,x,y,c) then draw.text(s,x,y,c) end`
-- so the old path stays as the fallback when d2d is missing.
-- ============================================================================

local FONT = _G.IrisFont or {}
_G.IrisFont = FONT

local C = FONT.cfg or {
    face      = "",      -- "" = walk the ladder; else force this one face
    scale     = 1.0,     -- global size multiplier on top of the resolution scale
    shadow    = true,    -- drop shadow behind on-screen text (readability over bright terrain)
    card      = true,    -- ritual cards use the styled d2d card (false = old imgui window)
}
FONT.cfg = C

-- The ladder (first name that CONSTRUCTS wins). Head = Sovngarde Light -- Aurora's
-- pick, A/B'd against Alegreya on 07-25 and held.
--
-- ✅ LICENSE SETTLED 07-25 (was flagged UNVERIFIED for two sessions): Sovngarde's own
-- embedded name table reads "Copyright (c) 2016, mjorka (mjorka.net), without Reserved
-- Font Name. This Font Software is licensed under the SIL Open Font License, Version
-- 1.1", and its OS/2 fsType is 0 (installable, no embedding restriction). So it IS
-- redistributable -- ship Sovngarde-OFL.txt beside the .ttf and we satisfy OFL clause 2.
-- No Reserved Font Name also means we may modify it if a weight ever needs baking.
--
-- Second = Alegreya (also OFL, also no RFN). It is the closest LEGAL match to DD2's own
-- menu face: the game's Latin UI font is "francr", which Capcom's disclaimer lists as
-- Capcom-owned, so it can never be bundled no matter that every player has it on disk.
-- Kept installed and one click away in the picker.
--
-- Then Constantia (a Windows system serif, referenced BY NAME only = never
-- redistribution, but absent on Proton/Steam Deck), then LinLibertine_R.ttf (OFL), then
-- the system serifs, Tahoma last. 07-23 log CONFIRMED d2d resolves .ttf FILENAMES
-- (LinLibertine measured 10px off the substitute), which is why a bundled .ttf can lead
-- the ladder at all.
local LADDER = {
    "Sovngarde Light.ttf",   -- DEFAULT: Nick's Boss Healthbar Overhaul face (Aurora's pick, held 07-25)
    "Alegreya.ttf",          -- fallback: OFL, closest legal match to DD2's own "francr" menu face
    "Constantia",            -- fallback: game-UI serif, present on all Windows (system font, never shipped)
    "LinLibertine_R.ttf",    -- fallback: OFL, bundled, always safe to redistribute
    "Linux Libertine",
    "Georgia",
    "Times New Roman",
    "Tahoma",
}

local function cfg_path() return "IrisFont_config.json" end
local function save_cfg() pcall(function() json.dump_file(cfg_path(), C) end) end
pcall(function()
    local d = json.load_file(cfg_path())
    if type(d) == "table" then
        for k, v in pairs(d) do if type(C[k]) == type(v) then C[k] = v end end
    end
end)

-- ===== resolution =====
local function screen_h()
    local h = nil
    pcall(function() local ok, w2, h2 = pcall(d2d.surface_size); if ok and h2 and h2 > 0 then h = h2 end end)
    if not h then pcall(function() local ds = imgui.get_display_size(); if ds and tonumber(ds.y) then h = tonumber(ds.y) end end) end
    return h or 1080.0
end
local function screen_w()
    local w = nil
    pcall(function() local ok, w2, h2 = pcall(d2d.surface_size); if ok and w2 and w2 > 0 then w = w2 end end)
    if not w then pcall(function() local ds = imgui.get_display_size(); if ds and tonumber(ds.x) then w = tonumber(ds.x) end end) end
    return w or 1920.0
end

function FONT.px(base)
    local s = screen_h() / 1080.0
    if s < 0.75 then s = 0.75 elseif s > 2.5 then s = 2.5 end
    s = s * (tonumber(C.scale) or 1.0)
    local p = math.floor((tonumber(base) or 20) * s + 0.5)
    if p < 10 then p = 10 end
    return p
end

-- ===== the face, and the SILENT-SUBSTITUTION probe =====
-- ⚠ d2d.Font.new is a DirectWrite family lookup: asking for a face that does not
-- exist does NOT error, it silently hands back a substitute. So a non-nil return
-- proves NOTHING. We measure a distinctive string against a deliberately-bogus
-- baseline face and LOG every candidate's width once, so the field log tells the
-- truth about what really loaded.
--
-- ⛔ 07-23 FIELD LESSON -- the probe is now DIAGNOSTIC-ONLY, it no longer GATES the
-- choice. The log proved BOTH an installed family name (Constantia) AND a bundled
-- .ttf filename (LinLibertine_R.ttf, 10px off the substitute) construct fine here.
-- But the metric test FALSE-REJECTED Constantia: its width landed 0.5px from the
-- substitute (the substitute is metrically near-identical to it on this machine),
-- so the old gate skipped it and flipped EVERY surface -- bars included -- to
-- LinLibertine, which read as "the ritual is the wrong font". The heuristic's core
-- assumption (substitute != wanted face, metrically) is simply not guaranteed. So
-- we TRUST THE LADDER ORDER now: first name that constructs wins. Constantia leads,
-- so everything wears the Break/Grip face again.
local PROBE_STR = "MWmwiIl1 The Quick Brown Fox"

local function measure(f, s)
    local w = nil
    pcall(function() local a, b = f:measure(s); if tonumber(a) then w = tonumber(a) end end)
    if not w then pcall(function() local a, b = d2d.measure_text(f, s); if tonumber(a) then w = tonumber(a) end end) end
    return w
end

local function pick_face(px)
    -- returns font, name. TAKES THE FIRST NAME THAT CONSTRUCTS, in ladder order
    -- (C.face first if forced). The bogus baseline is still measured and every
    -- candidate's width still logged ONCE -- but purely as a diagnostic, never as a
    -- gate (see the 07-23 field lesson above). d2d.Font.new effectively never
    -- returns nil for a plausible name, so "constructs" resolves to the ladder head
    -- Constantia here, which is exactly the Break/Grip face.
    local bogus_f, bogus_w = nil, nil
    pcall(function() bogus_f = d2d.Font.new("__IrisNoSuchFace_9271__", px) end)
    if bogus_f then bogus_w = measure(bogus_f, PROBE_STR) end

    local list = {}
    if C.face and C.face ~= "" then list[#list + 1] = C.face end
    for _, n in ipairs(LADDER) do list[#list + 1] = n end

    local report = {}
    local chosen_f, chosen_name = nil, nil
    for _, name in ipairs(list) do
        local f = nil
        pcall(function() f = d2d.Font.new(name, px) end)
        if f and not chosen_f then chosen_f, chosen_name = f, name end
        if not FONT._logged then
            report[#report + 1] = f and string.format("%s=%s", name, tostring(measure(f, PROBE_STR)))
                or (name .. "=nil")
        elseif chosen_f then
            break                                   -- already logged: stop at the first hit
        end
    end
    if not chosen_f then
        pcall(function() chosen_f = d2d.Font.new(list[1] or "Tahoma", px) end)
        chosen_name = list[1] or "Tahoma"
    end
    if not FONT._logged then
        FONT._logged = true
        pcall(function() log.info("[IrisFont] face=" .. tostring(chosen_name) .. " px=" .. tostring(px)
            .. " substitute_w=" .. tostring(bogus_w) .. " probe: " .. table.concat(report, " ")) end)
    end
    return chosen_f, chosen_name
end

local fonts = {}      -- [px] = handle
FONT.face_used = FONT.face_used or "?"

function FONT.d2d(base)
    if not (_G.d2d and d2d.Font and d2d.Font.new) then return nil end
    local px = FONT.px(base)
    local f = fonts[px]
    if f ~= nil then return f or nil end
    local got, name = pick_face(px)
    fonts[px] = got or false
    FONT._face_ok = (got ~= nil)
    if got then FONT.face_used = name end
    return got
end

-- ⭐ per-call FACE OVERRIDE (2026-08-05, for the griffin's fake button prompts: they must match
-- the GAME's UI face -- Alegreya, the closest legal match to DD2's "francr" -- while everything
-- else keeps the configured default). Own cache keyed face@px; bundled .ttf FILENAMES are proven
-- to resolve in d2d (07-23 field log). ⚠ d2d silently substitutes on a miss -- a wrong name here
-- shows SOME serif rather than erroring, so trust your eyes, not a nil-check.
local face_fonts = {}
function FONT.d2d_face(face, base)
    if not (_G.d2d and d2d.Font and d2d.Font.new) then return nil end
    face = tostring(face or "")
    if face == "" then return FONT.d2d(base) end
    local px = FONT.px(base)
    local key = face .. "@" .. tostring(px)
    local f = face_fonts[key]
    if f ~= nil then return f or nil end
    local got = nil
    pcall(function() got = d2d.Font.new(face, px) end)
    face_fonts[key] = got or false
    return got
end

-- ⚠ DELIBERATELY CHEAP AND NON-CREATING. Callers hit this once per string per frame,
-- and -- more importantly -- they call it from re.on_frame, whereas d2d.Font.new
-- wants to run inside a d2d callback. So this only reports whether the layer is up
-- and whether the LAST real resolution attempt succeeded; the fonts themselves are
-- built lazily inside draw_queue/draw_card, which are d2d callbacks. Worst case a
-- doomed face costs one frame of missing text before ready() starts saying false and
-- every call site drops back to its own draw.text path.
function FONT.ready()
    if _G.d2d == nil or FONT._registered ~= true then return false end
    return FONT._face_ok ~= false
end

-- ===== imgui side (the fallback path, and anything still living in a window) =====
-- ⚠ imgui.load_font needs a FILE in reframework/fonts -- it cannot take a family
-- name, so "Constantia" is not available here. LinLibertine_R.ttf is.
local IMGUI_FILES = { "Sovngarde Light.ttf", "Alegreya.ttf", "LinLibertine_R.ttf", "NotoSerifJP-Regular.ttf" }
local ifonts = {}
function FONT.imgui(base)
    local px = FONT.px(base)
    local f = ifonts[px]
    if f ~= nil then return f or nil end
    local got = nil
    for _, fn in ipairs(IMGUI_FILES) do
        local ok, h = pcall(imgui.load_font, fn, px)
        if ok and h then got = h; break end
    end
    if not got then local ok, h = pcall(imgui.load_font, nil, px); got = (ok and h) or nil end
    ifonts[px] = got or false
    return got
end

-- ===== the screen-text queue =====
-- Callers push during the game frame; the d2d callback drains. DRAIN-AND-CLEAR
-- with a one-frame carry: no ids needed, no ghost trails behind moving markers
-- (a TTL scheme smears them), and no flicker if d2d presents faster than on_frame.
local Q, QPREV = {}, {}

function FONT.text(str, x, y, argb, base, shadow, face)
    if not FONT.ready() then return false end
    Q[#Q + 1] = { s = tostring(str or ""), x = tonumber(x) or 0.0, y = tonumber(y) or 0.0,
        c = math.floor(tonumber(argb) or 0xFFFFFFFF), b = tonumber(base) or 19,
        sh = (shadow ~= false) and (C.shadow ~= false),
        f = (face ~= nil and tostring(face)) or nil }   -- optional per-call face override
    return true
end

-- ===== the ritual card =====
-- Fed every frame while live (same staleness idiom as _G.IrisRodeoHUD); the draw
-- side owns the 0.25s-in / 0.35s-out fade so callers never manage it.
function FONT.card(title, sub, argb)
    FONT._card = { t = os.clock(), title = tostring(title or ""), sub = tostring(sub or ""),
        c = math.floor(tonumber(argb) or 0xFF80D0FF) }
end
function FONT.card_live()
    if C.card == false or not FONT.ready() then return false end
    local cd = FONT._card
    return type(cd) == "table" and (os.clock() - (tonumber(cd.t) or 0.0)) <= 1.0
end

-- ===== draw =====
local function argb(a, r, g, b)
    return ((math.floor(a) & 0xFF) << 24) | ((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF)
end

local function draw_queue()
    local list = Q
    if #list == 0 then list = QPREV end          -- one-frame carry
    for _, e in ipairs(list) do
        local f = (e.f and FONT.d2d_face(e.f, e.b)) or FONT.d2d(e.b)
        if f then
            if e.sh then
                local sa = math.floor(((e.c >> 24) & 0xFF) * 0.75)
                pcall(d2d.text, f, e.s, e.x + 1.0, e.y + 1.0, argb(sa, 8, 6, 5))
            end
            pcall(d2d.text, f, e.s, e.x, e.y, e.c)
        end
    end
    if #Q > 0 then QPREV = Q; Q = {} else QPREV = {} end
end

local function draw_card()
    -- ⭐ the ritual card in the SAME visual language as iris_hud_bar (the Grip/Break
    -- gauges): antique-gold hairline, smoky backing, parchment serif with a drop
    -- shadow. Title keeps the caller's colour -- it carries meaning (amber = act,
    -- green = good, red = danger); the body is always parchment.
    local cd = FONT._card
    local now = os.clock()
    local live = (C.card ~= false) and type(cd) == "table" and (now - (tonumber(cd.t) or 0.0)) <= 1.0
    local fd = FONT._fade or { a = 0.0, t = now }
    FONT._fade = fd
    local dt = math.max(0.0, math.min(0.1, now - (tonumber(fd.t) or now)))
    fd.t = now
    fd.a = math.max(0.0, math.min(1.0, (tonumber(fd.a) or 0.0) + (live and (dt / 0.25) or -(dt / 0.35))))
    if live then FONT._card_last = cd else cd = FONT._card_last end
    if fd.a <= 0.02 or type(cd) ~= "table" then return end
    local A = fd.a
    local function c(a, r, g, b) return argb(math.floor(a * A + 0.5), r, g, b) end

    local ft = FONT.d2d(34)
    local fs = FONT.d2d(21)
    if not (ft and fs) then return end
    local tpx, spx = FONT.px(34), FONT.px(21)
    local tw = measure(ft, cd.title) or (#cd.title * tpx * 0.5)
    local sw2 = measure(fs, cd.sub) or (#cd.sub * spx * 0.5)
    local SW, SH = screen_w(), screen_h()
    local pad = math.max(14.0, tpx * 0.55)
    local w = math.max(tw, sw2) + pad * 2.0
    local minw = SW * 0.22
    if w < minw then w = minw end
    if w > SW * 0.78 then w = SW * 0.78 end
    local h = pad * 1.5 + tpx + (cd.sub ~= "" and (spx + tpx * 0.30) or 0.0)
    local x = SW * 0.5 - w * 0.5
    local y = SH * 0.14

    pcall(d2d.fill_rect, x - 1.0, y - 1.0, w + 2.0, h + 2.0, c(150, 158, 130, 78))   -- antique gold hairline
    pcall(d2d.fill_rect, x, y, w, h, c(215, 16, 13, 10))                             -- smoky backing
    pcall(d2d.fill_rect, x + 1.0, y + 1.0, w - 2.0, h - 2.0, c(228, 30, 25, 20))     -- leather
    pcall(d2d.fill_rect, x + 1.0, y + 1.0, w - 2.0, 2.0, c(60, 226, 214, 186))       -- top sheen

    -- title in the caller's colour, alpha folded through the fade
    local tc = cd.c or 0xFF80D0FF
    local tr, tg, tb = (tc >> 16) & 0xFF, (tc >> 8) & 0xFF, tc & 0xFF
    local tx = x + pad
    local ty = y + pad * 0.62
    pcall(d2d.text, ft, cd.title, tx + 1.0, ty + 1.0, c(200, 10, 8, 6))
    pcall(d2d.text, ft, cd.title, tx, ty, c(255, tr, tg, tb))
    if cd.sub ~= "" then
        local sy = ty + tpx + tpx * 0.18
        pcall(d2d.text, fs, cd.sub, tx + 1.0, sy + 1.0, c(190, 10, 8, 6))
        pcall(d2d.text, fs, cd.sub, tx, sy, c(255, 226, 214, 186))
    end
end

-- late-bound so a script RELOAD swaps the behaviour without stacking registrations
FONT._init = function() fonts = {}; FONT._logged = nil; FONT._face_ok = nil end
FONT._draw = function() pcall(draw_card); pcall(draw_queue) end

re.on_frame(function()
    if FONT._registered then return end
    if not (_G.d2d and type(d2d.register) == "function") then return end
    pcall(function()
        d2d.register(function() FONT._init() end, function() FONT._draw() end)
        FONT._registered = true
        log.info("[IrisFont] d2d text layer registered")
    end)
end)

-- ===== A/B PREVIEW ===== fed for a few seconds from the REF panel button, so the
-- face can be compared on the REAL d2d surfaces (card + a HUD line + a marker line)
-- without having to start a tame. Content is idempotent, so it is harmless if the
-- callback is ever fed twice.
re.on_frame(function()
    local until_c = FONT._preview_until
    if not (until_c and os.clock() < until_c) then return end
    FONT.card("THE HUNT", "It hungers. KILL the quarry (green marker, 8m) and LAY IT BEFORE the wolf.", 0xFF80D0FF)
    local w, h = screen_w(), screen_h()
    FONT.text("[LT] Focus     [RT] Sprint     [B] Release", w * 0.5 - 210.0, h * 0.72, 0xFFDFF0FF, 18)
    FONT.text("Wolf  -  8m", w * 0.5 - 42.0, h * 0.40, 0xFF9FE0FF, 17)
end)

-- A CONTROL, not styling: the face picker lives in the REF panel so the on-screen
-- face can change without a code edit.
re.on_draw_ui(function()
    if not imgui.tree_node("I.R.I.S. on-screen font") then return end
    imgui.text("Shared face for every on-screen surface: ritual cards, Grip/Break bars,")
    imgui.text("creature-control HUD, world markers, the customize screen.")
    imgui.text("d2d: " .. (FONT.ready() and ("UP  (face in use: " .. tostring(FONT.face_used) .. ")") or "MISSING - falling back to imgui/draw.text"))
    local chg = false
    local names = { "auto (ladder)" }
    local sel = 1
    for i, n in ipairs(LADDER) do
        names[i + 1] = n
        if C.face == n then sel = i + 1 end
    end
    local c1, v1 = imgui.combo("face##irisfont_face", sel, names)
    if c1 then
        C.face = (v1 == 1) and "" or (LADDER[v1 - 1] or "")
        fonts = {}; FONT._logged = nil; FONT._face_ok = nil; chg = true
    end
    local c2, v2 = imgui.drag_float("size scale##irisfont_scale", tonumber(C.scale) or 1.0, 0.01, 0.6, 2.0)
    if c2 then C.scale = v2; fonts = {}; ifonts = {}; FONT._face_ok = nil; chg = true end
    local c3, v3 = imgui.checkbox("drop shadow behind on-screen text##irisfont_shadow", C.shadow ~= false)
    if c3 then C.shadow = v3; chg = true end
    local c4, v4 = imgui.checkbox("styled ritual cards (uncheck = plain imgui banner)##irisfont_card", C.card ~= false)
    if c4 then C.card = v4; chg = true end
    if imgui.button("preview on screen 3s  (A/B the face live)##irisfont_preview") then
        FONT._preview_until = os.clock() + 3.0
    end
    imgui.same_line()
    if imgui.button("re-probe the face (writes the metrics to the log)##irisfont_reprobe") then
        fonts = {}; ifonts = {}; FONT._logged = nil; FONT._face_ok = nil
    end
    if chg then save_cfg() end
    imgui.tree_pop()
end)

log.info("[IrisFont] loaded")
