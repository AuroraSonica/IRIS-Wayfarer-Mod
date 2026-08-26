-- I.R.I.S. shared mount HUD and companion gauges.
--
-- Owns display publication, D2D registration and rendering only. Combat
-- stamina accounting lives with shared combat; mount movement, seating and
-- native UI mutation remain outside this module.

local ctx = require("IRISMounts.context")
local C, S = ctx.C, ctx.S
local MOD = ctx.MOD
local char_go = ctx.char_go
local go_name = ctx.go_name
local reacquire_griffin = ctx.reacquire_griffin
local status = ctx.status

-- friendly display name for the HP panel + anywhere (ch253000_00 -> "Griffin", NPCs keep raw for now)
function griffin_display_name(ch)
    if not ch then return "Target" end
    local raw = tostring(go_name(char_go(ch)) or "")
    if iris_type_name then local nm = iris_type_name(raw); if nm and nm ~= "" then return nm end end
    local base = raw:match("^(ch%d+)")
    return base or (raw ~= "" and raw or "Target")
end

-- ===== D2D HP PANEL (top-centre target HP bar; imgui fallback if d2d absent). ARGB. Globals only. =====
function griffin_hud_argb(a, r, g, b)
    return ((a & 0xFF) << 24) | ((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF)
end
function route3_hud_prepare()
    if S.route3_hud_d2d_ok ~= true then return end
    local st = S.route3_d2d or {}; S.route3_d2d = st
    local now = os.clock()
    local sw = 1920.0
    pcall(function() local ds = imgui.get_display_size(); if ds and tonumber(ds.x) then sw = tonumber(ds.x) end end)
    st.sw = sw
    local hud = S.route3_hit_hud
    st.bar = st.bar or {}
    -- retired by default (2026-08-06, Aurora: "I don't really like it anymore") -- flip
    -- route3_dogfight_hit_hud true to bring the top-centre target bar back
    if C.route3_dogfight_hit_hud == true and type(hud) == "table" and now <= (tonumber(hud.until_clock) or 0.0) then
        local mx = math.max(1.0, tonumber(hud.max) or 1.0)
        local after = math.max(0.0, math.min(mx, tonumber(hud.after) or mx))
        local before = math.max(after, math.min(mx, tonumber(hud.before) or after))
        local ease = math.min(1.0, (now - (tonumber(hud.t0) or now)) / 0.35)
        st.bar.visible = true
        st.bar.frac = after / mx
        st.bar.chipFrac = (before / mx) + ((after / mx) - (before / mx)) * ease
        st.bar.name = tostring(hud.name or "Target")
        st.bar.hptext = string.format("%d / %d", math.floor(after), math.floor(mx))
    else
        st.bar.visible = false
    end
end
function griffin_hud_d2d_draw()
    local st = S.route3_d2d; if not st then return end
    local b = st.bar
    if b and b.visible and S.griffin_hud_font then
        local bw, bh = 340.0, 20.0
        local bx = (tonumber(st.sw) or 1920.0) * 0.5 - bw * 0.5
        local by = 92.0
        local d = S.griffin_hud_d2d
        d.fill_rect(bx - 3.0, by - 3.0, bw + 6.0, bh + 6.0, griffin_hud_argb(190, 8, 8, 10))
        d.fill_rect(bx, by, bw, bh, griffin_hud_argb(225, 42, 12, 12))
        d.fill_rect(bx, by, bw * (b.chipFrac or b.frac), bh, griffin_hud_argb(150, 235, 120, 90))
        d.fill_rect(bx, by, bw * (b.frac or 0.0), bh, griffin_hud_argb(255, 225, 45, 45))
        d.text(S.griffin_hud_font, tostring(b.name), bx + 2.0, by - 24.0, griffin_hud_argb(255, 255, 255, 255))
        d.text(S.griffin_hud_font, tostring(b.hptext), bx + bw - 96.0, by - 24.0, griffin_hud_argb(255, 235, 235, 235))
    end
end
function iris_hud_text(s, x, y, col, base)
    -- ⭐ ONE ON-SCREEN FACE (07-21): player-facing strings route through the shared d2d text
    -- layer (IrisFont.lua). ⛔ draw.text takes NO font argument -- it can only ever be the
    -- imgui default bitmap face -- so it stays purely as the no-d2d fallback. GLOBAL on
    -- purpose: this file's call sites sit thousands of lines ABOVE here, and a local would
    -- resolve to a nil global there (the local-function law).
    local F = _G.IrisFont
    if F and F.text and F.text(s, x, y, col, base or 19) then return end
    pcall(draw.text, s, x, y, col)
end

-- Read the Arisen gauge instead of inventing a separate idle timer.  DD2 owns
-- when its HUD should fade (idling, cinematics, menus and other contexts), and
-- the companion/blessing overlays should follow that exact decision.  ui020901
-- exposes that decision directly as NowDispState: Hide=0, In=1, Out=2.
-- Field testing showed NowDispState remains In during the ordinary idle fade. The
-- no-argument updateDisp() returns the actual per-frame "should display" decision,
-- so observe its return value without calling or modifying the native UI ourselves.
if not rawget(_G, "__iris_player_vitals_disp_hooked") then
    pcall(function()
        local td = sdk.find_type_definition("app.ui020901")
        local method = td and td:get_method("updateDisp()")
        if not method then return end
        sdk.hook(method, function() end, function(retval)
            pcall(function()
                rawset(_G, "__iris_player_vitals_native_wanted",
                    (sdk.to_int64(retval) & 0xFF) ~= 0)
                rawset(_G, "__iris_player_vitals_native_wanted_t", os.clock())
            end)
            return retval
        end)
        rawset(_G, "__iris_player_vitals_disp_hooked", true)
    end)
end

function iris_player_vitals_visible()
    local now = os.clock()
    local ride_t = tonumber(rawget(_G, "IrisRideNativeHudVisibleT")) or 0.0
    local ride_visible = rawget(_G, "IrisRideNativeHudVisible")
    local ride_fresh = ride_visible ~= nil and now - ride_t <= 0.5
    local native_t = tonumber(rawget(_G,
        "__iris_player_vitals_native_wanted_t")) or 0.0
    local native_wanted = rawget(_G, "__iris_player_vitals_native_wanted")
    if native_wanted ~= nil and now - native_t <= 0.5 then
        S.player_vitals_visible = native_wanted == true
            and (not ride_fresh or ride_visible == true)
        S.player_vitals_next_read = now + 0.10
        return S.player_vitals_visible
    end
    if ride_fresh then
        S.player_vitals_visible = ride_visible == true
        S.player_vitals_next_read = now + 0.10
        return S.player_vitals_visible
    end
    if now < (tonumber(S.player_vitals_next_read) or 0.0)
        and S.player_vitals_visible ~= nil then
        return S.player_vitals_visible
    end
    S.player_vitals_next_read = now + 0.10

    local ui = S.player_vitals_ui
    if ui and valid and not valid(ui) then ui = nil end
    if not ui and now >= (tonumber(S.player_vitals_next_scan) or 0.0) then
        S.player_vitals_next_scan = now + 2.0
        pcall(function()
            local sm = sdk.get_native_singleton("via.SceneManager")
            local smt = sdk.find_type_definition("via.SceneManager")
            local scene = sm and smt and sdk.call_native_func(sm, smt, "get_CurrentScene()")
            local td = sdk.find_type_definition("app.ui020901")
            local list = scene and td and scene:call(
                "findComponents(System.Type)", td:get_runtime_type())
            local n = 0
            if list then pcall(function() n = tonumber(list:get_size()) or 0 end) end
            if n == 0 and list then pcall(function() n = tonumber(list:get_Count()) or 0 end) end
            if n > 0 then
                pcall(function() ui = list:get_element(0) end)
                if not ui then pcall(function() ui = list:get_Item(0) end) end
            end
        end)
        S.player_vitals_ui = ui
    end
    if not ui then
        -- Unknown is visible: losing the custom gauge is worse than leaving it
        -- up on a build where the native widget could not be resolved.
        S.player_vitals_visible = true
        return true
    end

    local raw_state = nil
    pcall(function() raw_state = ui:get_field("NowDispState") end)
    local state = tonumber(raw_state)
    if state == nil and raw_state ~= nil then
        local label = tostring(raw_state):lower()
        state = tonumber(label:match("%-?%d+"))
        if label:find("hide", 1, true) then state = 0
        elseif label:find("out", 1, true) then state = 2
        elseif label:find("in", 1, true) then state = 1 end
    end
    local visible = state == nil or state == 1
    local parent = nil
    pcall(function() parent = ui:get_field("Parent") end)
    if parent then
        local actual = nil
        pcall(function() actual = parent:call("get_ActualVisible") end)
        if actual ~= nil then visible = visible and actual == true end
    end
    S.player_vitals_visible = visible
    return visible
end

function griffin_hud_fonts()
    -- re-resolved every d2d pass so the shared face/size picker is LIVE (fonts baked once in
    -- the init callback below would ignore the slider until a script reload)
    local F = _G.IrisFont
    if not (F and F.d2d) then return end
    local f = F.d2d(20)
    if f then S.griffin_hud_font = f; S.griffin_hud_font_rodeo = f end
end

function griffin_hud_init_d2d()
    if not _G.d2d then return false end
    S.griffin_hud_d2d = _G.d2d
    S.griffin_hud_d2d.register(function()
        -- FALLBACK faces only -- griffin_hud_fonts overwrites both with the shared IrisFont
        -- serif each pass. Constantia was the old rodeo face: a good match for the game's UI
        -- serif but a MICROSOFT SYSTEM font, so ⛔ not redistributable in a Nexus release.
        S.griffin_hud_font = S.griffin_hud_d2d.Font.new("Tahoma", 20)
        pcall(function() S.griffin_hud_font_rodeo = S.griffin_hud_d2d.Font.new("Constantia", 20) end)
    end, function() pcall(griffin_hud_fonts); pcall(griffin_hud_d2d_draw); pcall(iris_rodeo_bars_d2d_draw); pcall(iris_progress_bar_d2d_draw); pcall(iris_scout_bar_d2d_draw); pcall(iris_mount_hp_d2d_draw); pcall(iris_blessing_cooldown_d2d_draw) end)
    _G.IrisHudD2DOk = true   -- cross-file signal: the styled d2d gauges own the bars (fallback rects stand down)
    S.route3_hud_d2d_ok = true
    pcall(function() log.info("[hud] d2d HP panel active") end)
    return true
end
pcall(griffin_hud_init_d2d)

-- ⭐ HUD EASING. Rodeo input is now integrated every game frame in IrisTaming; this small display
-- ease removes the last pixel-level jitter without concealing a genuine grip change.
-- Shared by both renderers (d2d + the draw.* fallback) so they can never disagree.
function iris_rodeo_hud_ease(gf, bf)
    local now = os.clock()
    local dt = math.max(0.0, math.min(0.25, now - (tonumber(S.rodeo_shown_t) or now)))
    S.rodeo_shown_t = now
    local rate = 0.9 * dt                     -- ~1.1s for a full sweep; a 30% step reads as ~0.35s
    local function ease(shown, target)
        if shown == nil then return target end -- first frame of a duel: adopt, don't crawl up from 0
        local diff = target - shown
        if math.abs(diff) <= rate then return target end
        return shown + ((diff > 0.0) and rate or -rate)
    end
    S.rodeo_grip_shown = ease(tonumber(S.rodeo_grip_shown), gf)
    S.rodeo_brk_shown = ease(tonumber(S.rodeo_brk_shown), bf)
    return S.rodeo_grip_shown, S.rodeo_brk_shown
end

function iris_progress_hud_ease(key, target, dt)
    S.prog_hud_shown = S.prog_hud_shown or {}
    target = math.max(0.0, math.min(1.0, tonumber(target) or 0.0))
    local shown = tonumber(S.prog_hud_shown[key])
    if shown == nil then
        shown = target
    else
        -- Exponential response is independent of refresh rate and removes the stair-step caused
        -- by gameplay systems that publish progress less often than D2D renders it.
        local a = 1.0 - math.exp(-10.0 * math.max(0.0, math.min(0.10, tonumber(dt) or 0.0)))
        shown = shown + (target - shown) * a
        if math.abs(target - shown) < 0.0005 then shown = target end
    end
    S.prog_hud_shown[key] = shown
    return shown
end

function iris_companion_hp_tick()
    -- ⭐ r83 (Aurora: "would be good to have this up for all tamed creatures
    -- while they are summoned, instead of while mounted"). Moved out of the
    -- rodeo's ride tick and into the companion frame loop, so it follows the
    -- SOUL rather than the saddle -- wolf, griffin, critter, mounted or not.
    -- ⛔ ONE writer for _G.IrisMountHUD. The rodeo's feed is gone; two modules
    -- writing one value is the exact pattern that caused the scale vibration.
    if C.mount_hp_bar == false and C.route3_combat_stamina_enabled == false then return end
    local ch = nil
    pcall(function() ch = reacquire_griffin() end)
    if not ch then return end
    local go = char_go(ch)
    if not go then return end
    local addr = nil
    pcall(function() addr = go:get_address() end)
    -- ⭐ read the HP store that ACTUALLY MOVES. r83 proved app.HitController on
    -- the body reports full health while the creature is downed; the receiver
    -- captured in the damage hook is the one taking the hits. Prefer it, and
    -- fall back to the old reader only until the first hit lands.
    local hc = addr and (S.hp_source or {})[addr] or nil
    local hp = nil
    if hc then pcall(function() hp = tonumber(hc:call("get_Hp")) end) end
    if not hp then hp = tonumber(griffin_read_target_hp(ch)) end
    local hpmax = nil
    pcall(function()
        hpmax = tonumber(griffin_hp_max_from_component(
            hc or griffin_target_hit_controller(ch)))
    end)
    if not (hp and hpmax and hpmax > 0) then return end
    local nm = "Companion"
    pcall(function()
        local r = griffin_stable_live_rec()
        if type(r) == "table" and r.name then nm = tostring(r.name) end
    end)
    -- Persistent, tiny damage receipt. The framework log is commonly empty
    -- after a relaunch/CTD; this survives and tells us whether a future report
    -- is a hit-routing, HP-write or merely bar-resolution problem.
    pcall(function()
        local hits = tonumber(rawget(_G, "IrisClampHits")) or 0
        local key = table.concat({ tostring(addr), string.format("%.3f", hp),
            string.format("%.3f", hpmax), tostring(hits) }, ":")
        local now = os.clock()
        if key ~= S.companion_damage_diag_key
            and now >= (tonumber(S.companion_damage_diag_at) or 0.0) then
            S.companion_damage_diag_key = key
            S.companion_damage_diag_at = now + 0.2
            local hca = nil
            pcall(function() hca = hc and hc:get_address() end)
            json.dump_file(MOD .. "_companion_damage_diag.json", {
                time = os.date("%H:%M:%S"), name = nm,
                species = tostring(go_name(go) or "?"),
                hp = hp, hp_max = hpmax, fraction = hp / hpmax,
                clamp_hits = hits,
                clamp = tostring(rawget(_G, "IrisClampDbg") or "none"),
                fallback_hits = tonumber(rawget(_G, "IrisFallbackDamageHits")) or 0,
                fallback_last = tostring(rawget(_G, "IrisFallbackDamageLast") or "none"),
                -- 08-12 IV receipts: the bloodline's actual fingerprints on the pipeline
                iv_atk_hits = tonumber(rawget(_G, "IrisIVAtkHits")) or 0,
                iv_last_atk = tostring(rawget(_G, "IrisIVLastAtk") or "none"),
                iv_def_hits = tonumber(rawget(_G, "IrisIVDefHits")) or 0,
                iv_last_def = tostring(rawget(_G, "IrisIVLastDef") or "none"),
                body_address = tostring(addr), hp_source_address = tostring(hca),
            })
        end
    end)
    -- 08-12 UNICORN DISPLAY HP: the native max-HP write is walled (the
    -- engine computes max from an unreachable authority), but the wild-horses
    -- damage hook already makes a unicorn EFFECTIVELY base_hp (incoming
    -- damage x native/base). The bar scales its numbers by that same factor:
    -- identical fraction, denominator = the true effective pool. To the
    -- player this IS 1000 HP.
    pcall(function()
        local api = rawget(_G, "__iris_wild_horses_api")
        -- 08-12 (Aurora: "a flash of 1000/1000 before it changes, every
        -- summon"): the registry's gene-scaled base_hp lands a second AFTER
        -- the variant stamp, so the api briefly answered the plain species
        -- pool. The STABLE RECORD knows the gene from frame one and uses the
        -- SAME curve -- ask it FIRST; the api is the fallback.
        local want = nil
        local r0 = griffin_stable_live_rec()
        if type(r0) == "table" and r0.kind == "horse" then
            local pool0 = (r0.variant == "unicorn")
                and ((api and api.unicorn_base_hp and api.unicorn_base_hp())
                    or 1000) or 250
            local g0 = r0.iv and tonumber(r0.iv.hp)
            local want0 = math.floor(
                pool0 * (g0 and (1.0 + g0 / 30.0 * 0.5) or 1.0) + 0.5)
            if want0 > 250.5 then want = want0 end
        end
        if not want then
            want = api and api.display_max_hp and api.display_max_hp(go)
        end
        if want and want > hpmax then
            local k = want / hpmax
            hp, hpmax = hp * k, want
        end
    end)
    _G.IrisMountHUD = {
        active = true, t = os.clock(),
        frac = math.max(0.0, math.min(1.0, hp / hpmax)),
        label = nm, hp = hp, hp_max = hpmax,
        combat_active = S.mounted == true and C.route3_combat_stamina_enabled ~= false,
        combat_frac = math.max(0.0, math.min(1.0,
            tonumber(S.route3_combat_stamina_frac) or 1.0)),
    }
end
local function iris_pet_hp_integer(v)
    -- Exact, readable health values without letting floating-point tails leak
    -- into the HUD: 101265.003 becomes 101,265.
    local n = math.floor(math.max(0.0, tonumber(v) or 0.0) + 0.5)
    local s = tostring(n)
    repeat
        local next_s, changed = s:gsub("^(%d+)(%d%d%d)", "%1,%2")
        s = next_s
        if changed == 0 then break end
    until false
    return s
end
function iris_mount_hp_d2d_draw()
    -- ⭐⭐ MOUNT HEALTH (08-09, Aurora: "is there any way to show the horse's
    -- health bar somewhere while riding? might be useful info"). Now that a
    -- mount can actually be hurt and downed, riding without knowing its HP is
    -- flying blind -- the first warning you get is the body collapsing.
    -- Same iris_hud_bar the house gauge and rodeo bars use, so it is the native
    -- look for free. Top-left: DD2 owns bottom-centre (player HP/stamina) and
    -- top-right (map), and this must never sit on top of either.
    -- Fed by _G.IrisMountHUD = {active, t, frac, label} from the rodeo.
    local d = S.griffin_hud_d2d
    if not d then return end
    local hud = _G.IrisMountHUD
    local now = os.clock()
    local live = type(hud) == "table" and hud.active == true
        and (now - (tonumber(hud.t) or 0.0)) <= 1.0
    local fd = S.mount_hp_fade or { a = 0.0, t = now }
    S.mount_hp_fade = fd
    local dtf = math.max(0.0, math.min(0.1, now - (tonumber(fd.t) or now)))
    fd.t = now
    fd.a = math.max(0.0, math.min(1.0, (tonumber(fd.a) or 0.0)
        + (live and (dtf / 0.25) or -(dtf / 0.35))))
    if live then S.mount_hp_last = hud else hud = S.mount_hp_last end
    if fd.a <= 0.02 or type(hud) ~= "table" then
        S.prog_hud_shown = nil
        return
    end
    -- ⛔ r83: no gauges over the pause menu / map / photo mode (Aurora: "it needs
    -- to disappear when the game is paused"). Same oracle the progress bar uses.
    local paused = false
    pcall(function()
        local pm = sdk.get_managed_singleton("app.PauseManager")
        if pm and pm:call("isPausedAny") == true then paused = true end
    end)
    if not paused then
        pcall(function()
            local gm = sdk.get_managed_singleton("app.GuiManager")
            if gm and (gm:call("isPausedGUI") == true
                or gm:call("get_IsDispPhotoModeAll") == true
                or gm:call("get_IsDispPhotoMode") == true) then
                paused = true
            end
        end)
    end
    if paused then return end
    if iris_player_vitals_visible() == false then return end
    local sw, sh = 1920.0, 1080.0
    pcall(function()
        local ds = imgui.get_display_size()
        if ds then sw = tonumber(ds.x) or sw; sh = tonumber(ds.y) or sh end
    end)
    local scale = sh / 1080.0
    -- ⭐ r83 PLACEMENT (Aurora's marked screenshot): sit it directly ABOVE the
    -- Arisen's own health/stamina pair, matching their width and centring, so it
    -- reads as part of the same stack rather than a mod overlay.
    -- r84 placement, tunable (Aurora: "slightly different size/thickness than
    -- the arisen's, also it currently blocks the arisen's health bar").
    -- Raised clear of the player's pair and thinned to match their weight.
    -- All four are config keys so this can be dialled without another round
    -- trip: mount_hp_w / mount_hp_h / mount_hp_y (up from the bottom) /
    -- mount_hp_x (offset from centre, 0 = centred).
    local bw = (tonumber(C.mount_hp_w) or 552.0) * scale
    local bh = (tonumber(C.mount_hp_h) or 9.0) * scale
    local bx = sw * 0.5 - bw * 0.5 + (tonumber(C.mount_hp_x) or 0.0) * scale
    local by = sh - ((tonumber(C.mount_hp_y) or 112.0) * scale)
    local f = math.max(0.0, math.min(1.0, tonumber(hud.frac) or 0.0))
    local font = S.griffin_hud_font_rodeo or S.griffin_hud_font
    -- ⭐ TRAFFIC-LIGHT (Aurora's split, with the thresholds nudged): under 25%
    -- red, under 60% amber, otherwise green. Deliberately NOT the native crimson
    -- -- a creature's health is a different thing from the Arisen's, and the
    -- colour is doing the work of telling you at a glance.
    local fr, fg, fb, hr, hg, hb
    if f < 0.25 then
        fr, fg, fb, hr, hg, hb = 190, 48, 36, 255, 140, 110       -- red
    elseif f < 0.60 then
        fr, fg, fb, hr, hg, hb = 214, 168, 74, 255, 236, 180      -- DD2 amber
    else
        fr, fg, fb, hr, hg, hb = 92, 158, 68, 190, 245, 170       -- green
    end
    local label = tostring(hud.label or "Companion")
    local hp = tonumber(hud.hp)
    local hpmax = tonumber(hud.hp_max)
    if hp and hpmax and hpmax > 0.0 then
        label = string.format("%s  %s / %s", label,
            iris_pet_hp_integer(hp), iris_pet_hp_integer(hpmax))
    end
    -- Keep the thin gauge visually clean.  iris_hud_bar's house style puts text in the gauge
    -- band, which is fine for 20px progress bars but obscures this 9px companion bar.  Draw the
    -- gauge unlabelled, then place both readings on the baseline immediately above it.
    iris_hud_bar(d, font, bx, by, bw, bh, fd.a, f,
        nil, false, fr, fg, fb, hr, hg, hb)
    local combat_active = hud.combat_active == true
    -- Mirror the Arisen: health first, then a narrower stamina rule beneath it.
    local stamina_h = math.max(3.0 * scale, bh * 0.52)
    local sy = by + bh + 2.0 * scale
    if combat_active then
        local sf = math.max(0.0, math.min(1.0, tonumber(hud.combat_frac) or 0.0))
        local low = sf < 0.20 or now <= (tonumber(S.route3_combat_stamina_flash_until) or 0.0)
        if low then
            iris_hud_bar(d, font, bx, sy, bw, stamina_h, fd.a, sf,
                nil, false, 180, 55, 38, 255, 125, 82)
        else
            iris_hud_bar(d, font, bx, sy, bw, stamina_h, fd.a, sf,
                nil, false, 207, 155, 58, 255, 232, 153)
        end
    end
    if font then
        local A = fd.a
        local function tc(a, r, g, b)
            return griffin_hud_argb(math.floor(a * A + 0.5), r, g, b)
        end
        local ty = by - 21.0 * scale
        local pt = string.format("%d%%", math.floor(f * 100.0 + 0.5))
        local px = bx + bw - 55.0 * scale
        d.text(font, label, bx + 1.0, ty + 1.0, tc(200, 10, 8, 6))
        d.text(font, label, bx, ty, tc(255, 226, 214, 186))
        d.text(font, pt, px + 1.0, ty + 1.0, tc(200, 10, 8, 6))
        d.text(font, pt, px, ty, tc(255, 226, 214, 186))
    end
end


function iris_blessing_cooldown_d2d_draw()
    local d = S.griffin_hud_d2d
    local hud = rawget(_G, "IrisBlessingHUD")
    local now = os.clock()
    if not d or type(hud) ~= "table" or hud.active ~= true
        or now - (tonumber(hud.t) or 0.0) > 1.0 then return end
    if iris_player_vitals_visible() == false then return end
    local paused = false
    pcall(function()
        local pm = sdk.get_managed_singleton("app.PauseManager")
        paused = pm and pm:call("isPausedAny") == true
    end)
    if paused then return end

    local sw, sh = 1920.0, 1080.0
    pcall(function()
        local ds = imgui.get_display_size()
        if ds then sw = tonumber(ds.x) or sw; sh = tonumber(ds.y) or sh end
    end)
    local scale = sh / 1080.0
    local frac = math.max(0.0, math.min(1.0, tonumber(hud.frac) or 0.0))
    local remaining = math.max(0.0, tonumber(hud.remaining) or 0.0)
    local font = S.griffin_hud_font_rodeo or S.griffin_hud_font
    local function col(a, r, g, b) return griffin_hud_argb(a, r, g, b) end
    local key = math.floor(tonumber(hud.key) or 66)
    local mounted_y = key == 89
    -- 08-18 (Aurora): the cooldown ring is a RIDE instrument — draw it only
    -- while mounted with the native ride HUD actually on screen, whichever
    -- key charged the cooldown. The rodeo publishes this oracle every
    -- mounted frame and EXPIRES it on foot, so freshness IS the mount
    -- state; the old gate only covered ridden-cast cooldowns and fell
    -- through to visible after dismounting (stale oracle).
    local rt = tonumber(rawget(_G, "IrisRideNativeHudVisibleT")) or 0.0
    if now - rt > 0.5
        or rawget(_G, "IrisRideNativeHudVisible") ~= true then return end
    local base_x, base_y = sw - 270.0 * scale, sh - 154.0 * scale
    -- Mounted Y is the game's own live control. IrisHorseRodeo publishes that
    -- control's transform, so this survives keyboard/controller swaps and UI
    -- scaling instead of guessing one fixed square in 1920x1080 space.
    local native = mounted_y and rawget(_G, "IrisBlessingNativeButton") or nil
    local native_fresh = type(native) == "table"
        and now - (tonumber(native.t) or 0.0) <= 0.5
        and tonumber(native.x) and tonumber(native.y)
    local size = (mounted_y and 26.0 or 38.0) * scale
    local edge = (mounted_y and 2.0 or 3.0) * scale
    local bx = base_x + (mounted_y and 22.0 or 0.0) * scale
    local by = base_y + (mounted_y and 54.0 or 0.0) * scale
    local device = "pad"
    if native_fresh then
        device = tostring(native.device or "pad")
        local nx, ny = tonumber(native.x), tonumber(native.y)
        local nw = tonumber(native.w)
        local nh = tonumber(native.h)
        -- GUI global coordinates are normally physical pixels. A few REFramework
        -- builds expose the 1920x1080 reference plane instead, so scale only when
        -- the native point otherwise falls implausibly far from the action guide.
        if sw > 2100.0 and nx < sw * 0.72 then nx = nx * scale end
        if sh > 1200.0 and ny < sh * 0.72 then ny = ny * scale end
        if nw and nw > 8.0 and nw < 90.0 then size = math.max(22.0 * scale, math.min(48.0 * scale, nw)) end
        if nh and nh > 8.0 and nh < 90.0 then size = math.max(size, math.min(48.0 * scale, nh)) end
        size = size * math.max(0.5, math.min(2.0,
            tonumber(native.size_scale) or 1.0))
        local dx = device == "keyboard"
            and (tonumber(native.keyboard_dx) or 0.0)
            or (tonumber(native.pad_dx) or 0.0)
        local dy = device == "keyboard"
            and (tonumber(native.keyboard_dy) or 0.0)
            or (tonumber(native.pad_dy) or 0.0)
        -- The native transform is the baseline; DD2 uses different pivots for
        -- controller glyphs and keyboard keycaps, hence separate saved offsets.
        bx, by = nx - size * 0.5 + dx * scale,
            ny - size * 0.5 + dy * scale
    end

    if not mounted_y then
        -- On foot there is no persistent native B prompt to decorate.
        d.fill_rect(bx - 2.0, by - 2.0, size + 4.0, size + 4.0, col(210, 25, 22, 18))
        d.fill_rect(bx, by, size, size, col(235, 74, 72, 68))
        d.fill_rect(bx + 2.0, by + 2.0, size - 4.0, size - 4.0, col(235, 42, 40, 38))
    end

    if mounted_y and device ~= "keyboard" then
        -- D2D has no arc primitive on this REFramework build. Closely spaced
        -- square samples produce a visually continuous circular progress ring.
        local cx, cy = bx + size * 0.5, by + size * 0.5
        local radius = size * 0.5 + edge * 0.9
        local segments = 64
        local lit = math.floor(frac * segments + 0.5)
        local dot = math.max(1.5, edge * 1.25)
        for i = 0, segments - 1 do
            local a = -math.pi * 0.5 + (i / segments) * math.pi * 2.0
            local x = cx + math.cos(a) * radius - dot * 0.5
            local y = cy + math.sin(a) * radius - dot * 0.5
            local ring_col = (i < lit)
                and col(255, 224, 184, 92) or col(105, 66, 62, 56)
            d.fill_rect(x, y, dot, dot, ring_col)
        end
    else
        -- Keyboard glyphs are boxes (and some, such as Ctrl/Shift, are wider).
        -- A rectangular perimeter matches the game's own keycap language.
        local left = frac * size * 4.0
        local take = math.min(size, left)
        if take > 0 then d.fill_rect(bx, by - edge, take, edge, col(255, 224, 184, 92)) end
        left = left - take; take = math.min(size, math.max(0.0, left))
        if take > 0 then d.fill_rect(bx + size, by, edge, take, col(255, 224, 184, 92)) end
        left = left - take; take = math.min(size, math.max(0.0, left))
        if take > 0 then d.fill_rect(bx + size - take, by + size, take, edge, col(255, 224, 184, 92)) end
        left = left - take; take = math.min(size, math.max(0.0, left))
        if take > 0 then d.fill_rect(bx - edge, by + size - take, edge, take, col(255, 224, 184, 92)) end
    end

    if font then
        local key_name = (key >= 48 and key <= 90) and string.char(key) or tostring(key)
        local seconds = math.ceil(remaining)
        local timer = (seconds >= 60)
            and string.format("Blessing  %d:%02d", math.floor(seconds / 60), seconds % 60)
            or string.format("Blessing  %ds", seconds)
        if not mounted_y then
            d.text(font, key_name, bx + 12.0 * scale, by + 6.0 * scale,
                col(255, 185, 181, 171))
        end
        d.text(font, timer, bx - (mounted_y and 172.0 or 150.0) * scale,
            by + (mounted_y and -47.0 or 7.0) * scale,
            col(255, 226, 214, 186))
    end
end
function iris_rodeo_bars_d2d_draw()
    -- ⭐⭐ NATIVE-STYLED rodeo bars (07-21, Aurora: "mimic the game's UI style" -- the Boss Healthbar
    -- Overhaul lesson: the native look = a real serif font + the game's palette + fades, not imgui
    -- rects). d2d gives all three. Smoky backing, antique-gold border, DD2's stamina amber for GRIP
    -- (ember-red when low, like the real stamina bar), crimson for BREAK, top-edge sheen, quarter
    -- ticks, parchment serif labels with a drop shadow, fade in/out envelope.
    local d = S.griffin_hud_d2d
    if not d then return end
    local now = os.clock()
    local hud = _G.IrisRodeoHUD
    local live = type(hud) == "table" and hud.active == true and (now - (tonumber(hud.t) or 0.0)) <= 1.0
    -- fade envelope: 0.25s in, 0.35s out (the last feed keeps drawing through the fade-out)
    local fd = S.rodeo_hud_fade or { a = 0.0, t = now }
    S.rodeo_hud_fade = fd
    local dtf = math.max(0.0, math.min(0.1, now - (tonumber(fd.t) or now)))
    fd.t = now
    fd.a = math.max(0.0, math.min(1.0, (tonumber(fd.a) or 0.0) + (live and (dtf / 0.25) or -(dtf / 0.35))))
    if live then S.rodeo_hud_last = hud else hud = S.rodeo_hud_last end
    if fd.a <= 0.02 or type(hud) ~= "table" then
        -- duel over: forget the eased readings so the next one adopts its opening values instantly
        S.rodeo_grip_shown = nil; S.rodeo_brk_shown = nil
        return
    end
    local A = fd.a
    local function c(a, r, g, b) return griffin_hud_argb(math.floor(a * A + 0.5), r, g, b) end
    local sw = 1920.0
    pcall(function() local ds = imgui.get_display_size(); if ds and tonumber(ds.x) then sw = tonumber(ds.x) end end)
    local bw, bh = 430.0, 20.0
    local bx = sw * 0.5 - bw * 0.5
    local font = S.griffin_hud_font_rodeo or S.griffin_hud_font
    local gf, bf = iris_rodeo_hud_ease(
        math.max(0.0, math.min(1.0, tonumber(hud.grip) or 0.0)),
        math.max(0.0, math.min(1.0, tonumber(hud.brk) or 0.0)))
    if gf < 0.30 then iris_hud_bar(d, font, bx, 56.0, bw, bh, A, gf, "Grip", true, 196, 64, 34, 255, 150, 110)      -- ember: you're losing her
    else iris_hud_bar(d, font, bx, 56.0, bw, bh, A, gf, "Grip", true, 214, 168, 74, 255, 236, 180) end              -- DD2 stamina amber
    if hud.striking == true then iris_hud_bar(d, font, bx, 92.0, bw, bh, A, bf, "Break", true, 214, 60, 40, 255, 150, 120)   -- blood-bright while you land it
    else iris_hud_bar(d, font, bx, 92.0, bw, bh, A, bf, "Break", true, 158, 32, 28, 235, 110, 90) end                        -- native HP crimson
end
function iris_hud_bar(d, font, bx, y, bw, bh, A, frac, label, pct, fr, fg, fb, hr, hg, hb)
    -- ⭐ THE house gauge (07-21): border (antique gold, 1px) -> smoky backing -> leather trough ->
    -- fill + top sheen -> quarter ticks -> parchment serif label (+ optional right-aligned percent).
    -- A = fade alpha 0..1. Shared by the rodeo bars and the universal progress bar.
    local function c(a, r, g, b) return griffin_hud_argb(math.floor(a * A + 0.5), r, g, b) end
    d.fill_rect(bx - 1.0, y - 1.0, bw + 2.0, bh + 2.0, c(150, 158, 130, 78))
    d.fill_rect(bx, y, bw, bh, c(215, 16, 13, 10))
    d.fill_rect(bx + 1.0, y + 1.0, bw - 2.0, bh - 2.0, c(235, 34, 28, 22))
    local fq = math.max(0.0, math.min(1.0, tonumber(frac) or 0.0))
    local fw = (bw - 2.0) * fq
    if fw > 0.5 then
        d.fill_rect(bx + 1.0, y + 1.0, fw, bh - 2.0, c(255, fr, fg, fb))
        d.fill_rect(bx + 1.0, y + 1.0, fw, (bh - 2.0) * 0.42, c(70, hr, hg, hb))   -- top sheen
    end
    for i = 1, 3 do   -- quarter ticks, faint
        d.fill_rect(bx + (bw * 0.25) * i, y + 2.0, 1.0, bh - 4.0, c(70, 0, 0, 0))
    end
    if font then
        if label and label ~= "" then
            d.text(font, label, bx + 9.0, y - 2.0, c(200, 10, 8, 6))               -- drop shadow
            d.text(font, label, bx + 8.0, y - 3.0, c(255, 226, 214, 186))          -- parchment
        end
        if pct then
            local pt = string.format("%d%%", math.floor(fq * 100.0 + 0.5))
            d.text(font, pt, bx + bw - 55.0, y - 2.0, c(200, 10, 8, 6))
            d.text(font, pt, bx + bw - 56.0, y - 3.0, c(255, 226, 214, 186))
        end
    end
end
function iris_progress_bar_d2d_draw()
    -- ⭐⭐ THE UNIVERSAL PROGRESS BAR (07-21, Aurora: "use a bar like this for all the progress
    -- stuff -- any time a % is climbing"): one native-styled amber gauge, lower-center (near where
    -- the game parks its interaction gauges), fed by _G.IrisProgressHUD = {active, t, frac, label}
    -- from ANY rite -- the palm, the pact, the bond, the patience. Same fade envelope as the rodeo.
    local d = S.griffin_hud_d2d
    if not d then return end
    -- no gauges over the pause menu / photo mode (Aurora 07-23) - flags per the pause probe
    local paused = false
    pcall(function()
        local pm = sdk.get_managed_singleton("app.PauseManager")
        if pm and pm:call("isPausedAny") == true then paused = true end
    end)
    if not paused then pcall(function()
        local gm = sdk.get_managed_singleton("app.GuiManager")
        if gm and (gm:call("get_IsDispPhotoModeAll") == true or gm:call("get_IsDispPhotoMode") == true) then paused = true end
    end) end
    if paused then return end
    local now = os.clock()
    local hud = _G.IrisProgressHUD
    local live = type(hud) == "table" and hud.active == true and (now - (tonumber(hud.t) or 0.0)) <= 1.0
    local fd = S.prog_hud_fade or { a = 0.0, t = now }
    S.prog_hud_fade = fd
    local dtf = math.max(0.0, math.min(0.1, now - (tonumber(fd.t) or now)))
    fd.t = now
    fd.a = math.max(0.0, math.min(1.0, (tonumber(fd.a) or 0.0) + (live and (dtf / 0.25) or -(dtf / 0.35))))
    if live then S.prog_hud_last = hud else hud = S.prog_hud_last end
    if fd.a <= 0.02 or type(hud) ~= "table" then return end
    local sw, sh = 1920.0, 1080.0
    pcall(function() local ds = imgui.get_display_size(); if ds then sw = tonumber(ds.x) or sw; sh = tonumber(ds.y) or sh end end)
    local bw, bh = 400.0, 20.0
    if type(hud.bars) == "table" and #hud.bars > 0 then
        -- ⭐ MULTI-BAR mode (07-23, Aurora's construction site: Stone + Timber): feed
        -- hud.bars = { {frac,label}, ... } and they stack upward from the single-bar spot,
        -- same amber, same fades. Single-bar callers keep working untouched.
        for i, b in ipairs(hud.bars) do
            iris_hud_bar(d, S.griffin_hud_font_rodeo or S.griffin_hud_font,
                sw * 0.5 - bw * 0.5, sh * 0.66 + (i - 1) * (bh + 16.0), bw, bh, fd.a,
                iris_progress_hud_ease("multi:" .. tostring(i) .. ":" .. tostring(b.label or ""),
                    tonumber(b.frac) or 0.0, dtf), tostring(b.label or ""), true,
                214, 168, 74, 255, 236, 180)
        end
    else
        iris_hud_bar(d, S.griffin_hud_font_rodeo or S.griffin_hud_font,
            sw * 0.5 - bw * 0.5, sh * 0.66, bw, bh, fd.a,
            iris_progress_hud_ease("single:" .. tostring(hud.label or ""),
                tonumber(hud.frac) or 0.0, dtf), tostring(hud.label or ""), true,
            214, 168, 74, 255, 236, 180)   -- the bond amber
    end
end
function iris_scout_bar_d2d_draw()
    -- ⭐ SCOUT SPRINT STAMINA as the house gauge (07-21, Aurora): fed by _G.IrisScoutHUD
    -- {active, t, stamina, sprinting, lock} from the taming side's critter-control loop.
    -- DD2 stamina amber; brighter while sprinting; ember red when sprint-locked (spent) --
    -- the same language as the game's own stamina bar. No label, no percent: just the gauge.
    local d = S.griffin_hud_d2d
    if not d then return end
    local now = os.clock()
    local hud = _G.IrisScoutHUD
    local live = type(hud) == "table" and hud.active == true and (now - (tonumber(hud.t) or 0.0)) <= 1.0
    local fd = S.scout_hud_fade or { a = 0.0, t = now }
    S.scout_hud_fade = fd
    local dtf = math.max(0.0, math.min(0.1, now - (tonumber(fd.t) or now)))
    fd.t = now
    fd.a = math.max(0.0, math.min(1.0, (tonumber(fd.a) or 0.0) + (live and (dtf / 0.25) or -(dtf / 0.35))))
    if live then S.scout_hud_last = hud else hud = S.scout_hud_last end
    if fd.a <= 0.02 or type(hud) ~= "table" then return end
    local sw = 1920.0
    pcall(function() local ds = imgui.get_display_size(); if ds and tonumber(ds.x) then sw = tonumber(ds.x) end end)
    local bw, bh = 260.0, 12.0
    local sf = tonumber(hud.stamina) or 0.0
    if hud.lock == true then
        iris_hud_bar(d, nil, sw * 0.5 - bw * 0.5, 92.0, bw, bh, fd.a, sf, nil, false, 196, 64, 34, 255, 150, 110)    -- spent: ember
    elseif hud.sprinting == true then
        iris_hud_bar(d, nil, sw * 0.5 - bw * 0.5, 92.0, bw, bh, fd.a, sf, nil, false, 235, 190, 90, 255, 244, 200)   -- sprinting: bright
    else
        iris_hud_bar(d, nil, sw * 0.5 - bw * 0.5, 92.0, bw, bh, fd.a, sf, nil, false, 214, 168, 74, 255, 236, 180)   -- amber
    end
end
function iris_rodeo_bars_draw()
    -- ⭐ on-screen GRIP + BREAK bars for the ox-tame RODEO (Aurora 07-20: real bars, not "==="). Fed by
    -- _G.IrisRodeoHUD (written each rodeo tick in IrisTaming; cross-file since the two files hold
    -- separate S). Auto-hides when the feed goes stale (duel ended). Built-in draw.* -- ARGB colors.
    -- FALLBACK ONLY (07-21): when d2d is up, the native-styled iris_rodeo_bars_d2d_draw owns the bars.
    if S.route3_hud_d2d_ok == true then return end
    local hud = _G.IrisRodeoHUD
    if not (type(hud) == "table" and hud.active == true) then return end
    if (os.clock() - (tonumber(hud.t) or 0.0)) > 1.0 then _G.IrisRodeoHUD = nil; return end
    if not draw then return end
    pcall(function()
        local sw = 1920.0
        pcall(function() local ds = imgui.get_display_size(); if ds and tonumber(ds.x) then sw = tonumber(ds.x) end end)
        local bw, bh = 360.0, 20.0
        local bx = sw * 0.5 - bw * 0.5
        local gy = 64.0
        -- GRIP (top): green -> amber -> red as it drains
        local gf, bf = iris_rodeo_hud_ease(
            math.max(0.0, math.min(1.0, tonumber(hud.grip) or 0.0)),
            math.max(0.0, math.min(1.0, tonumber(hud.brk) or 0.0)))
        local gcol = (gf < 0.30) and 0xFFE0402A or ((gf < 0.60) and 0xFFE0B020 or 0xFF3CC05A)
        draw.filled_rect(bx - 3.0, gy - 3.0, bw + 6.0, bh + 6.0, 0xC0000000)
        draw.filled_rect(bx, gy, bw, bh, 0xFF23232A)
        draw.filled_rect(bx, gy, bw * gf, bh, gcol)
        draw.text(string.format("GRIP  %d%%", math.floor(gf * 100.0 + 0.5)), bx + 6.0, gy + 2.0, 0xFFFFFFFF)
        -- BREAK (below): fills as she breaks; brightens while you're landing it
        local byy = gy + bh + 10.0
        local bcol = (hud.striking == true) and 0xFF66D0FF or 0xFF3E82D8
        draw.filled_rect(bx - 3.0, byy - 3.0, bw + 6.0, bh + 6.0, 0xC0000000)
        draw.filled_rect(bx, byy, bw, bh, 0xFF23232A)
        draw.filled_rect(bx, byy, bw * bf, bh, bcol)
        draw.text(string.format("BREAK  %d%%%s", math.floor(bf * 100.0 + 0.5), (hud.striking == true) and "  <<<" or ""), bx + 6.0, byy + 2.0, 0xFFFFFFFF)
        -- (the old "act:<name>" DIAG line lived here -- retired 07-21 for release; the action name
        -- still reaches the REF-menu status line via S.status for pattern debugging)
    end)
end

log.info("[IRISMountUI] shared mount HUD loaded")
