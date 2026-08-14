-- I.R.I.S. -- BED WAKE (2026-08-13)
-- "Sleeping in a bed in my homestead sends me to a place in the world where the bed was
--  originally from (in my case, it's the Battahl house bed or something) - can we make sure
--  any placed bed in the Iris homestead furniture when resting keeps you at the bed that was
--  used?"  -- Aurora, 08-13
--
-- ══ THE ROOT CAUSE, read off the game's own types (il2cpp), not guessed ══════════════════
--   app.Gm51_115                       the bed gimmick. Field: InnParam
--   app.FacilityManager.InnAwakeParam  5 x ObjectSetting: Camera, Player, Main, Sub1, Sub2
--   ...InnAwakeParam.ObjectSetting     via.vec3 _Pos @0x10 · via.Quaternion _Rot @0x20
--   ...InnAwakeParam.WarpCharacter(SettingOrder order, app.Character chara)   <- the teleport
--   app.FacilityManager.startInn(bool is_awake_morning, int cost,
--                                InnAwakeParam param, CharacterID, Action<bool>, TalkEventID)
--
-- Those five positions are BAKED ABSOLUTE COORDINATES. They come from app.Gm51_115Param via
-- the prefab's `GimmickParamId`, resolved against gm51_115_gmdata.user -- so a bed we SPAWN
-- keeps the ParamId of whichever authored bed owns it, and wakes you in that bed's room.
-- ⛔ NOTHING in that chain ever reads the bed's live transform. This is not a bug we caused
-- and it is not fixable by choosing a different bed prefab: every one of the nine bed families
-- behaves the same way, you would just wake in a different wrong room.
--
-- ⭐ ObjectSetting is a managed CLASS (parent System.Object, size 0x40; InnAwakeParam is 0x38
-- = 0x10 header + 5 x 8-byte POINTERS), so get_field("Player") hands back a live reference and
-- writes to it stick. It has no set_Pos/set_Rot -- only get_Pos/get_Rot -- so we write the
-- _Pos / _Rot FIELDS directly.
--
-- ══ THE ONE THING WE DO NOT KNOW, AND HOW THIS MODULE HANDLES IT ═════════════════════════
-- ⛔⛔ WHICH COORDINATE SPACE `_Pos` SPEAKS. It is a via.vec3 (floats), but float-ness proves
-- nothing: at 20km a float still resolves ~2mm. The values are authored .user data, and every
-- DD2 warp API this repo already drives (TimeSkipManager.requestPlayerWarp) takes UNIVERSAL
-- world coordinates -- so UNIVERSAL is the strong favourite, but it is a favourite, not a fact.
-- Writing the wrong space would not fix Aurora's bug, it would drop her somewhere arbitrary.
-- So this module never bets the outcome on the guess. Three layers:
--   1. PASSIVE CALIBRATION (zero risk): any NATIVE bed in the world has an InnParam pointing at
--      ITS OWN room. Read such a bed's _Pos and compare it to that same bed's render and
--      universal positions -- whichever matches names the space, permanently, and it costs
--      nothing but walking past a bed in an inn. (Our own spawned beds point somewhere far
--      away, so they simply fail both tests and are skipped.)
--   2. THE WRITE, in the calibrated space (default universal until proven otherwise).
--   3. THE AIRBAG: after the sleep we check where she ACTUALLY ended up. Too far from the bed
--      means the guess was wrong -- so we flip the space, persist the flip, and warp her back
--      with the proven requestPlayerWarp recipe. One bad wake, self-corrected forever.
--
-- ⚠ IrisFarming's own WAKE-DRIFT GUARD (_wdg_tick) stays exactly where it is as a further
-- backstop, but it is NOT relied on: its settle gate re-arms to now+20s on any tick where the
-- player is unreadable (which the sleep fade does), while its firing window is only
-- fast_until+10s -- the gate outlives the window, which is why it never caught this.

local CFG = "IrisBedWake.json"
local C = {
    enabled     = true,
    -- "universal" | "render". Rewritten by calibration or by the airbag; persisted.
    space       = "universal",
    calibrated  = false,      -- has a native bed ever confirmed the space?
    match_r     = 2.5,        -- how near a placed-bed record a live bed must be to be "ours"
    side        = 0.9,        -- how far to the bed's side the sleeper is put down
    pawn_side   = 1.8,        -- pawns stand further out...
    pawn_spread = 1.1,        -- ...and fan along the bed
    cam_up      = 1.4,        -- the wake camera sits above and behind the player
    cam_back    = 1.6,
    verify_after = 18.0,      -- seconds after the sleep starts before we check where she is
    verify_until = 75.0,      -- give up looking after this
    heal_dist   = 50.0,       -- further than this from the bed = the wake went wrong
    heal        = true,       -- warp her back when it did
    log         = true,
}
pcall(function()
    local d = json.load_file(CFG)
    if type(d) == "table" then for k, v in pairs(d) do if C[k] ~= nil then C[k] = v end end end
end)
local function save_cfg() pcall(function() json.dump_file(CFG, C) end) end

local M = _G.IrisBedWake or {}
_G.IrisBedWake = M
M.armed = M.armed or nil       -- { ux, uy, uz, yaw, at, verify_at, wrote }
M.stats = M.stats or { latched = 0, wrote = 0, healed = 0 }

local function _log(s)
    if C.log == false then return end
    pcall(function() log.info("[IrisBedWake] " .. tostring(s)) end)
end

-- ── helpers ───────────────────────────────────────────────────────────────────────────
-- ⛔ via.vec3 is FLOAT3 and via.Position is DOUBLE3. This repo has been burned BOTH ways --
-- a float vector read as doubles put a bat at coordinate twenty million. _Pos is a vec3.
local function make_vec3(x, y, z)
    local v = ValueType.new(sdk.find_type_definition("via.vec3"))
    v.x, v.y, v.z = x or 0.0, y or 0.0, z or 0.0
    return v
end

local function make_quat_yaw(yaw)
    local q = ValueType.new(sdk.find_type_definition("via.Quaternion"))
    q.x, q.y, q.z, q.w = 0.0, math.sin(yaw * 0.5), 0.0, math.cos(yaw * 0.5)
    return q
end

-- ⭐ YAW ONLY. The furnish system lets Aurora set pitch and roll on a placed piece, and it
-- writes the full quaternion -- so handing the bed's raw rotation to the wake would stand her
-- up tilted. Take the heading and nothing else.
local function yaw_of(q)
    if not q then return 0.0 end
    local x, y, z, w = q.x or 0.0, q.y or 0.0, q.z or 0.0, q.w or 1.0
    return math.atan(2.0 * (w * y + x * z), 1.0 - 2.0 * (y * y + z * z))
end

local function player_char()
    local pl = nil
    pcall(function()
        pl = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
    end)
    return pl
end

local function player_spaces()
    local u, r = nil, nil
    pcall(function()
        local pl = player_char()
        local tr = pl and pl:call("get_GameObject"):call("get_Transform")
        if not tr then return end
        u = tr:call("get_UniversalPosition")
        r = tr:call("get_Position")
    end)
    return u, r
end

-- ── which beds are OURS ───────────────────────────────────────────────────────────────
-- ⛔ IDENTITY, never radius alone. A real inn bed must behave exactly as vanilla, so a bed is
-- only ours if it stands where the furnish system recorded that Aurora placed one.
local BED_GIDS = {
    gm51_092_02 = true, gm51_100 = true, gm51_115_01 = true, gm51_393 = true,
    gm51_396 = true, gm51_409 = true, gm51_409_01 = true, gm51_460 = true,
    gm51_603 = true, gm51_603_01 = true, gm51_742 = true,
}
local placed, placed_at = nil, 0.0
local function placed_beds()
    local now = os.clock()
    if placed and now < placed_at then return placed end
    placed_at = now + 5.0
    local out = {}
    pcall(function()
        local d = json.load_file("IRIS/iris_furniture.json")
        for _, r in ipairs(d or {}) do
            if BED_GIDS[tostring(r.gid or "")] and tonumber(r.ux) and tonumber(r.uz) then
                out[#out + 1] = { x = tonumber(r.ux), y = tonumber(r.uy) or 0.0, z = tonumber(r.uz) }
            end
        end
    end)
    placed = out
    return placed
end

local function is_our_bed(u)
    if not u then return false end
    local r = tonumber(C.match_r) or 2.5
    for _, b in ipairs(placed_beds()) do
        local dx, dz = b.x - u.x, b.z - u.z
        if dx * dx + dz * dz <= r * r then return true end
    end
    return false
end

-- ── PASSIVE CALIBRATION: let a native bed tell us which space _Pos speaks ─────────────
local calib_at = 0.0
local function calibrate_tick(now)
    if C.calibrated == true then return end
    if now < calib_at then return end
    calib_at = now + 5.0
    pcall(function()
        local sm = sdk.get_native_singleton("via.SceneManager")
        local smt = sdk.find_type_definition("via.SceneManager")
        local scene = sm and sdk.call_native_func(sm, smt, "get_CurrentScene")
        if not scene then return end
        local comps = scene:call("findComponents(System.Type)", sdk.typeof("app.Gm51_115"))
        local n = 0
        pcall(function() n = tonumber(comps:call("get_Length")) or 0 end)
        for i = 0, n - 1 do
            pcall(function()
                local bed = comps:call("get_Item", i)
                if not bed then return end
                local ip = bed:get_field("InnParam")
                if not ip then return end
                local ps = ip:get_field("Player")
                if not ps then return end
                local p = ps:get_field("_Pos")
                if not (p and p.x) then return end
                local tr = bed:call("get_GameObject"):call("get_Transform")
                local ur = tr:call("get_UniversalPosition")
                local rr = tr:call("get_Position")
                if not (ur and rr) then return end
                -- a NATIVE bed's authored wake spot is in its own room, i.e. right beside it.
                local du = math.sqrt((p.x - ur.x) ^ 2 + (p.z - ur.z) ^ 2)
                local dr = math.sqrt((p.x - rr.x) ^ 2 + (p.z - rr.z) ^ 2)
                if du < 30.0 and du < dr then
                    C.space, C.calibrated = "universal", true
                    save_cfg()
                    _log(string.format("CALIBRATED from a native bed: _Pos is UNIVERSAL (%.1fm from that bed universal, %.0fm render)", du, dr))
                elseif dr < 30.0 and dr < du then
                    C.space, C.calibrated = "render", true
                    save_cfg()
                    _log(string.format("CALIBRATED from a native bed: _Pos is RENDER (%.1fm from that bed render, %.0fm universal)", dr, du))
                end
            end)
            if C.calibrated == true then return end
        end
    end)
end

-- ── the write ─────────────────────────────────────────────────────────────────────────
-- Build the five wake spots around the latched bed and stamp them onto an InnAwakeParam.
local function write_param(param, why)
    local a = M.armed
    if not (param and a) then return false end
    local ok = false
    pcall(function()
        -- the space question, answered at the last possible moment
        local bx, by, bz = a.ux, a.uy, a.uz
        if C.space == "render" then
            -- convert universal -> render off the PLAYER's own transform, translation-invariant
            -- (the spaces differ by a pure translation; only valid while nearby, which a bed we
            -- are sleeping in certainly is)
            local pu, pr = player_spaces()
            if not (pu and pr) then return end
            bx, by, bz = pr.x + (a.ux - pu.x), pr.y + (a.uy - pu.y), pr.z + (a.uz - pu.z)
        end
        local yaw = a.yaw or 0.0
        local fx, fz = math.sin(yaw), math.cos(yaw)          -- forward
        local rx, rz = math.cos(yaw), -math.sin(yaw)         -- right
        local q = make_quat_yaw(yaw)

        local side = tonumber(C.side) or 0.9
        local pside = tonumber(C.pawn_side) or 1.8
        local spread = tonumber(C.pawn_spread) or 1.1

        local function stamp(field, px, py, pz)
            local slot = param:get_field(field)
            if not slot then return end
            pcall(function() slot:set_field("_Pos", make_vec3(px, py, pz)) end)
            pcall(function() slot:set_field("_Rot", q) end)
        end

        stamp("Player", bx + rx * side, by, bz + rz * side)
        stamp("Main",   bx + rx * pside + fx * spread,  by, bz + rz * pside + fz * spread)
        stamp("Sub1",   bx + rx * pside,                by, bz + rz * pside)
        stamp("Sub2",   bx + rx * pside - fx * spread,  by, bz + rz * pside - fz * spread)
        -- ⚠ the camera is NOT the player's own spot -- that would wake her inside her own head.
        stamp("Camera", bx + rx * side - fx * (tonumber(C.cam_back) or 1.6),
                        by + (tonumber(C.cam_up) or 1.4),
                        bz + rz * side - fz * (tonumber(C.cam_back) or 1.6))

        -- readback receipt: a silent write is indistinguishable from no write at all
        local rb = nil
        pcall(function()
            local s = param:get_field("Player")
            local p = s and s:get_field("_Pos")
            if p then rb = string.format("(%.1f, %.1f, %.1f)", p.x, p.y, p.z) end
        end)
        ok = true
        M.stats.wrote = M.stats.wrote + 1
        _log(string.format("wrote wake spots (%s, space=%s) bed universal(%.1f, %.1f, %.1f) -> Player._Pos readback %s",
            tostring(why), tostring(C.space), a.ux, a.uy, a.uz, tostring(rb)))
    end)
    return ok
end

-- ── the latch: "a sleep is starting, and it is OUR bed" ───────────────────────────────
-- ⛔ Routed through _G so a script reset re-points the PERMANENT hooks at fresh code. A hook
-- body written inline can only ever be changed by restarting the game (REFramework cannot
-- unhook, and a reset orphans the old closure with its old upvalues still live).
_G.IrisBedWakeOnBed = function(bed_comp, why)
    if C.enabled == false then return end
    pcall(function()
        local go = bed_comp and bed_comp:call("get_GameObject")
        local tr = go and go:call("get_Transform")
        local u = tr and tr:call("get_UniversalPosition")
        if not u then return end
        if not is_our_bed(u) then return end       -- a real inn bed: leave it entirely alone
        local yaw = yaw_of(tr:call("get_Rotation"))
        local now = os.clock()
        M.armed = {
            ux = u.x, uy = u.y, uz = u.z, yaw = yaw,
            at = now,
            verify_at = now + (tonumber(C.verify_after) or 18.0),
            verify_until = now + (tonumber(C.verify_until) or 75.0),
        }
        M.stats.latched = M.stats.latched + 1
        _log(string.format("OUR bed (%s) at universal(%.1f, %.1f, %.1f) yaw %.0f deg - armed",
            tostring(why), u.x, u.y, u.z, math.deg(yaw)))
    end)
end

_G.IrisBedWakeOnStartInn = function(param)
    if C.enabled == false then return end
    local a = M.armed
    if not a then return end
    if (os.clock() - (tonumber(a.at) or 0.0)) > 120.0 then M.armed = nil; return end
    if write_param(param, "startInn") then a.wrote = true end
end

-- last-instant belt & braces: whatever object actually reaches the teleport gets stamped too,
-- in case the inn flow hands WarpCharacter a copy rather than the object startInn received.
_G.IrisBedWakeOnWarp = function(param)
    if C.enabled == false then return end
    local a = M.armed
    if not a then return end
    if (os.clock() - (tonumber(a.at) or 0.0)) > 120.0 then M.armed = nil; return end
    write_param(param, "WarpCharacter")
end

-- ── the airbag: did she actually wake at the bed? ─────────────────────────────────────
local function verify_tick(now)
    local a = M.armed
    if not a or not a.verify_at then return end
    if now < a.verify_at then return end
    local pu = select(1, player_spaces())
    if not pu then
        -- still on a loading screen / mid-fade: keep looking until the window closes
        if now > (tonumber(a.verify_until) or 0.0) then
            _log("verify gave up: the player never became readable")
            M.armed = nil
        end
        return
    end
    local d = math.sqrt((pu.x - a.ux) ^ 2 + (pu.z - a.uz) ^ 2)
    M.armed = nil
    if d <= (tonumber(C.heal_dist) or 50.0) then
        _log(string.format("wake verified: %.1fm from the bed (wrote=%s, space=%s) - good",
            d, tostring(a.wrote == true), tostring(C.space)))
        -- a good wake with a write is the strongest possible confirmation of the space
        if a.wrote and C.calibrated ~= true then
            C.calibrated = true
            save_cfg()
            _log("space CONFIRMED by a good wake: " .. tostring(C.space))
        end
        return
    end

    _log(string.format("⛔ wake went WRONG: %.0fm from the bed (wrote=%s, space=%s)",
        d, tostring(a.wrote == true), tostring(C.space)))
    -- ⭐ SELF-CORRECT. If we wrote and she still ended up far away, the space guess is the
    -- prime suspect -- flip it and persist, so the next sleep is right without anyone reading
    -- a log. (If we never wrote, the hooks are not firing and flipping would be superstition.)
    if a.wrote then
        C.space = (C.space == "universal") and "render" or "universal"
        C.calibrated = false
        save_cfg()
        _log("space guess FLIPPED to " .. tostring(C.space) .. " for the next sleep")
    end
    if C.heal == false then return end
    -- warp her back with the recipe this repo has shipped four times over: requestPlayerWarp
    -- takes a via.Position (DOUBLES) in UNIVERSAL space.
    pcall(function()
        local tm = sdk.get_managed_singleton("app.TimeManager")
        local tsm = sdk.get_managed_singleton("app.TimeSkipManager")
        if not (tm and tsm) then return end
        local pos = ValueType.new(sdk.find_type_definition("via.Position"))
        pos.x, pos.y, pos.z = a.ux, a.uy + 0.6, a.uz
        local prot = nil
        pcall(function() prot = player_char():call("get_GameObject"):call("get_Transform"):call("get_Rotation") end)
        tsm:call("requestPlayerWarp",
            tm:call("get_InGameHour"), tm:call("get_InGameMinute"), tm:call("get_InGameDay"),
            pos, prot, nil, true, true)
        M.stats.healed = M.stats.healed + 1
        _log("warped back to the bedside (the airbag)")
    end)
end

-- ── hooks ─────────────────────────────────────────────────────────────────────────────
-- ⭐ Aurora's bed is app.Gm51_115 and its interact points are authored PLAYER-capable by
-- Capcom -- IRIS does nothing to make it sleepable, so there is nothing of ours to disable.
-- We only observe, and rewrite DATA the game is about to read. We never call into the interact
-- system and never skip an original (both are crash-proven in this codebase).
if not _G.IrisBedWakeHooks then
    _G.IrisBedWakeHooks = true

    -- 1) which bed
    pcall(function()
        local td = sdk.find_type_definition("app.Gm51_115")
        if not td then _log("hook: app.Gm51_115 NOT FOUND"); return end
        for _, sig in ipairs({ "onStartInteractBase(System.UInt32, app.Character)", "execSleep()" }) do
            local m = td:get_method(sig)
            if m then
                local label = sig
                sdk.hook(m, function(args)
                    pcall(function()
                        local f = rawget(_G, "IrisBedWakeOnBed")
                        if type(f) == "function" then f(sdk.to_managed_object(args[2]), label) end
                    end)
                end, function(r) return r end)
                _log("hook installed: app.Gm51_115." .. sig)
            else
                _log("hook: NOT FOUND app.Gm51_115." .. sig)
            end
        end
    end)

    -- 2) the sleep itself. startInn(bool, int, InnAwakeParam, CharacterID, Action, TalkEventID)
    --    args[2]=this  args[3]=is_awake_morning  args[4]=cost  args[5]=param
    pcall(function()
        local td = sdk.find_type_definition("app.FacilityManager")
        if not td then _log("hook: app.FacilityManager NOT FOUND"); return end
        local found = 0
        for _, mm in ipairs(td:get_methods() or {}) do
            local nm = nil
            pcall(function() nm = mm:get_name() end)
            if nm == "startInn" or nm == "startInnNoLock" then
                found = found + 1
                sdk.hook(mm, function(args)
                    pcall(function()
                        local f = rawget(_G, "IrisBedWakeOnStartInn")
                        if type(f) == "function" then f(sdk.to_managed_object(args[5])) end
                    end)
                end, function(r) return r end)
                _log("hook installed: app.FacilityManager." .. tostring(nm))
            end
        end
        if found == 0 then _log("hook: no startInn / startInnNoLock found on app.FacilityManager") end
    end)

    -- 3) the literal teleport, as the last-instant write + the receipt that the chain is real
    pcall(function()
        local td = sdk.find_type_definition("app.FacilityManager.InnAwakeParam")
        local m = td and td:get_method("WarpCharacter(app.FacilityManager.InnAwakeParam.SettingOrder, app.Character)")
        if not m then
            _log("hook: WarpCharacter NOT FOUND on app.FacilityManager.InnAwakeParam"
                 .. " (the startInn write still stands on its own)")
            return
        end
        sdk.hook(m, function(args)
            pcall(function()
                local f = rawget(_G, "IrisBedWakeOnWarp")
                if type(f) == "function" then f(sdk.to_managed_object(args[2])) end
            end)
        end, function(r) return r end)
        _log("hook installed: app.FacilityManager.InnAwakeParam.WarpCharacter")
    end)
end

-- ── pumps ─────────────────────────────────────────────────────────────────────────────
re.on_application_entry("UpdateBehavior", function()
    if C.enabled == false then return end
    local now = os.clock()
    pcall(function() calibrate_tick(now) end)
    pcall(function() verify_tick(now) end)
end)

re.on_script_reset(function()
    -- nothing to tear down in the world: this module only writes DATA the game already owns,
    -- and holds no bodies, no props and no prompts. Just drop the latch so a reset mid-sleep
    -- cannot leave a stale arm pointed at somebody's inn.
    pcall(function() M.armed = nil end)
end)

re.on_draw_ui(function()
    if not imgui.tree_node("IRIS BED WAKE (sleep at your own bed)") then return end
    local ch
    ch, C.enabled = imgui.checkbox("enabled", C.enabled ~= false)
    imgui.text("Placed beds known: " .. tostring(#placed_beds()))
    imgui.text("_Pos space: " .. tostring(C.space)
        .. (C.calibrated and "  (CONFIRMED)" or "  (assumed - will self-correct)"))
    imgui.text(string.format("latched %d · wrote %d · healed %d",
        M.stats.latched or 0, M.stats.wrote or 0, M.stats.healed or 0))
    if M.armed then
        imgui.text(string.format("ARMED at universal(%.1f, %.1f, %.1f)", M.armed.ux, M.armed.uy, M.armed.uz))
    end
    imgui.separator()
    ch, C.side       = imgui.slider_float("player side offset (m)", C.side or 0.9, 0.0, 3.0)
    ch, C.pawn_side  = imgui.slider_float("pawn side offset (m)", C.pawn_side or 1.8, 0.0, 5.0)
    ch, C.cam_up     = imgui.slider_float("camera up (m)", C.cam_up or 1.4, 0.0, 4.0)
    ch, C.cam_back   = imgui.slider_float("camera back (m)", C.cam_back or 1.6, 0.0, 5.0)
    ch, C.heal_dist  = imgui.slider_float("wrong-wake distance (m)", C.heal_dist or 50.0, 5.0, 300.0)
    ch, C.heal       = imgui.checkbox("warp back when the wake goes wrong", C.heal ~= false)
    if imgui.button("SAVE") then save_cfg() end
    imgui.same_line()
    if imgui.button("re-calibrate (forget the space)") then
        C.calibrated = false; save_cfg()
        _log("calibration cleared by the panel")
    end
    imgui.tree_pop()
end)

_log("IrisBedWake loaded (space=" .. tostring(C.space)
    .. (C.calibrated and ", confirmed" or ", assumed") .. ", "
    .. tostring(#placed_beds()) .. " placed bed(s) known)")
