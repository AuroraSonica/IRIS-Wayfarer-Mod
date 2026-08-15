-- IrisSwim.lua -- swimming in Dragon's Dogma 2.
--
-- Replaces IrisSwimProbe.lua, which was a diagnostic instrument. Everything it was asking has
-- been answered, so this is the feature: sane defaults, one screen of settings, real hotkeys.
--
-- BEHAVIOUR: walk into deep water and you swim. That's it. The brine is suppressed, weapons stay
-- sheathed, and you get a swim animation with manual depth control.
--
--   RB  rise      LB  sink      hold B  swim faster      A  jump (at the surface)
--   (rebindable below -- via.hid.GamePadButton names, so keyboard works too)
--
-- ═══ THE LAWS THIS FILE IS BUILT ON (each cost a session to learn) ═══════════
--  * app.Character.Gravity is a plain float (9.8). Zero it EVERY FRAME -- last-writer-wins;
--    a one-shot write is re-asserted away, which is why "there's no zero g" happened.
--  * get_HeightSurface() is ALWAYS nil. The surface is derived: surface_y = univ_y + WaterDepth
--    (log-verified: the sum held at 0.005 across a whole session at the Vernworth harbour).
--    Smooth it -- raw depth swings ~1m on swell and would bounce the clamp.
--  * BONE writes in PrepareRendering (set_LocalEulerAngle, never set_LocalRotation for clips).
--    POSITION writes in LateUpdateBehavior. Mixing them silently does nothing.
--  * The retargeted clips carry NO body orientation -- it is stripped into root_yaw -- so the
--    prone posture is ours to apply, on the ROOT JOINT. Never write the player transform's
--    rotation: an invented quat there inverts the rendered body.
--  * Joints keep the last value written forever -> restore the root on exit or she stays tipped.
--  * Re-acquire the player every frame. Cached wrappers across a zone change = use-after-free.
--
-- ⚠ KNOWN GAPS: the retarget has no ankles, so toes do not point. Horizontal speed is still
--   ordinary locomotion (unslowed). Pawns do not swim yet.

local hk = require("Hotkeys/Hotkeys")

local CFG_FILE = "IrisSwim.json"

-- ⛔⛔⛔ OFF BY DEFAULT (2026-08-15). The v1 hold ejected Aurora into the sky repeatedly and once
-- triggered the STUCK-PLAYER RESCUE -- screen fade + relocation, which she could only escape with
-- a teleport mod. Do not re-enable by default until the hold is field-verified.
local C = {
    enabled       = false,
    suppress_brine = true,   -- on by default: without it deep water is simply lethal
    auto          = true,    -- on by default: walking into water IS the trigger
    enter_depth   = 1.20,
    exit_depth    = 0.85,
    body_pitch    = 82.0,    -- 0 upright, 90 flat. Swimmers ride slightly head-up.
    body_roll     = 0.0,
    surface_gap   = 0.55,    -- how far below the surface the body floats
    rise          = 2.4,
    sink          = 2.4,
    glide         = 6.0,     -- vertical damping; LOW = long coast = reads as water
    fast_mult     = 2.0,
    entry_lift    = 1.2,
    clip_rate     = 1.0,
    rate_ref      = 3.0,     -- travel speed at which the stroke plays 1.0x
    sheathe_lock  = true,    -- no swinging weapons while swimming
    own_pose      = true,    -- disable MotionFsm2 so the painted swim clip actually SHOWS
    face_travel   = true,    -- auto-yaw the body to the direction of travel
    yaw_offset    = 0.0,     -- correction if the auto-facing points the wrong way
}

local HOTKEYS = {
    ["Swim Up"]   = "RTrigTop",    -- RB
    ["Swim Down"] = "LTrigTop",    -- LB
    ["Swim Fast"] = "RRight",      -- B
    ["Swim Jump"] = "RDown",       -- A
}

local S = {
    on = false, depth = 0, surf = nil, surf_avg = nil, vy = 0,
    grav = nil, cc_off = false, clip = nil, frame = 0, last_t = 0,
    speed = 0, last_p = nil, last_t2 = nil, status = "off", clips = {}, note = "",
}

local CLIP_CRUISE, CLIP_SPRINT, CLIP_DOWN = "rs_swim_cruise", "rs_swim_sprint", "rs_swim_down"

-- ─────────────────────────────────────────────────────────────────────────────

local function try(f) local ok, v = pcall(f); if ok then return v end end

local function player()
    local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
    return cm and try(function() return cm:call("get_ManualPlayer") end)
end

local function field_or_get(o, getter, field)
    if not o then return nil end
    local v = try(function() return o:call(getter) end)
    if v ~= nil then return v end
    return try(function() return o:get_field(field) end)
end

local function via_pos(x, y, z)
    local p = try(function() return ValueType.new(sdk.find_type_definition("via.Position")) end)
    if not p then return nil end
    p.x, p.y, p.z = x, y, z
    return p
end

local function finite(n) return type(n) == "number" and n == n and n > -1e8 and n < 1e8 end

local function save_cfg() pcall(function() json.dump_file(CFG_FILE, C) end) end

local function load_cfg()
    local d = try(function() return json.load_file(CFG_FILE) end)
    if type(d) == "table" then for k, v in pairs(d) do if C[k] ~= nil then C[k] = v end end end
    local h = try(function() return json.load_file("IrisSwim_keys.json") end)
    if type(h) == "table" then for k, v in pairs(h) do if HOTKEYS[k] then HOTKEYS[k] = v end end end
end
load_cfg()
hk.setup_hotkeys(HOTKEYS)

-- ─── water sense ─────────────────────────────────────────────────────────────

local function sense(pl)
    S.depth, S.surf = 0, nil
    if not pl then return end
    -- ⛔ app.WaterSurfaceDetector is NOT a via.Component -- get_component() always returns nil.
    local det = field_or_get(pl, "get_WaterSurfaceDetector", "<WaterSurfaceDetector>k__BackingField")
    if not det then return end
    if try(function() return det:call("get_IsDetected") end) ~= true then return end
    local d = try(function() return det:call("get_WaterDepth") end)
    if type(d) ~= "number" then return end
    S.depth = d

    local tf = try(function() return pl:call("get_Transform") end)
    local p = tf and try(function() return tf:call("get_UniversalPosition") end)
    if not p then return end

    local raw = p.y + d                              -- derived surface (get_HeightSurface is nil)
    S.surf_avg = S.surf_avg and (S.surf_avg + (raw - S.surf_avg) * 0.06) or raw
    S.surf = S.surf_avg

    local now = os.clock()
    if S.last_p and S.last_t2 and (now - S.last_t2) > 0.1 then
        local dx, dy, dz = p.x - S.last_p.x, p.y - S.last_p.y, p.z - S.last_p.z
        local dt = now - S.last_t2
        S.speed = math.sqrt(dx * dx + dy * dy + dz * dz) / dt
        -- heading of travel, for auto-facing. Only trust it when actually moving --
        -- a heading derived from noise makes the body spin on the spot.
        local flat = math.sqrt(dx * dx + dz * dz) / dt
        if flat > 0.35 then
            local want = math.atan(dx, dz)
            if S.heading then
                local d = (want - S.heading + math.pi) % (2 * math.pi) - math.pi
                S.heading = S.heading + d * 0.25         -- slew, never snap
            else
                S.heading = want
            end
        end
        S.last_p, S.last_t2 = { x = p.x, y = p.y, z = p.z }, now
    elseif not S.last_p then
        S.last_p, S.last_t2 = { x = p.x, y = p.y, z = p.z }, now
    end
end

-- ─── brine ───────────────────────────────────────────────────────────────────

local BRINE_FIELDS = { "DepthEnvelopedByBrine", "SecKilledByBrine",
                       "DepthInstantKilledByBrine", "DepthNPCInstantKilledByBrine" }
local brine_saved = nil

local function brine(off)
    local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
    local hp = cm and try(function() return cm:get_field("<HumanParam>k__BackingField") end)
    local ap = hp and try(function() return hp:get_field("ActionParam") end)
    local bp = ap and try(function() return ap:get_field("BrinParam") end)   -- Capcom's typo
    local pl = player()

    if off then
        if bp and not brine_saved then
            brine_saved = {}
            for _, f in ipairs(BRINE_FIELDS) do
                brine_saved[f] = try(function() return bp:get_field(f) end)
            end
        end
        if bp then for _, f in ipairs(BRINE_FIELDS) do
            try(function() bp:set_field(f, 100000.0) end) end
        end
        local hu = pl and try(function() return pl:call("get_Human") end)
        if hu then try(function() hu:set_field("<IsEnableDestroyByBrine>k__BackingField", false) end) end
        local proc = field_or_get(pl, "get_BrineProcessor", "<BrineProcessor>k__BackingField")
        if proc then try(function() proc:call("set_IsEnable", false) end) end
    else
        if bp and brine_saved then
            for f, v in pairs(brine_saved) do
                if v ~= nil then try(function() bp:set_field(f, v) end) end
            end
            brine_saved = nil
        end
        local hu = pl and try(function() return pl:call("get_Human") end)
        if hu then try(function() hu:set_field("<IsEnableDestroyByBrine>k__BackingField", true) end) end
        local proc = field_or_get(pl, "get_BrineProcessor", "<BrineProcessor>k__BackingField")
        if proc then try(function() proc:call("set_IsEnable", true) end) end
    end
end

-- ─── clips ───────────────────────────────────────────────────────────────────

local function clip(name)
    if S.clips[name] == nil then
        local d = try(function() return json.load_file("Animations/" .. name .. ".json") end)
        S.clips[name] = (d and d.frames and d.bones) and d or false
        if not S.clips[name] then S.note = "MISSING Animations/" .. name .. ".json" end
    end
    return S.clips[name]
end

local function paint(pl)
    if not (S.on and pl) then S.pdiag = "not swimming"; return end
    local doc = clip(S.clip or CLIP_CRUISE)
    if not doc then S.pdiag = "NO CLIP: " .. tostring(S.note); return end
    local tf = try(function() return pl:call("get_Transform") end)
    if not tf then S.pdiag = "no transform"; return end

    local now = os.clock()
    local dt = math.min(0.1, now - (S.last_t > 0 and S.last_t or now))
    S.last_t = now

    -- stroke rate follows travel speed, or she ice-skates (the loops have no root motion)
    local rate = C.clip_rate * math.max(0.35, math.min(2.2, S.speed / math.max(0.01, C.rate_ref)))
    local n = doc.frame_count or #doc.frames
    S.frame = (S.frame + dt * (doc.fps or 60) * rate) % n

    local fr = doc.frames[math.floor(S.frame) + 1]
    if not fr then return end
    local found, wrote = 0, 0
    for _, bn in ipairs(doc.bones) do
        local e = fr[bn]
        if e then
            local j = try(function() return tf:call("getJointByName", bn) end)
            if j then
                found = found + 1
                if pcall(function()
                    j:call("set_LocalEulerAngle", Vector3f.new(e[1], e[2], e[3]))
                end) then wrote = wrote + 1 end
            end
        end
    end
    -- if found is 0 the bone NAMES are wrong for this rig; if wrote is 0 the setter is wrong
    S.pdiag = ("%s f%d/%d joints=%d wrote=%d"):format(
        S.clip, math.floor(S.frame), doc.frame_count or #doc.frames, found, wrote)

    -- body posture: the clips carry none (stripped into root_yaw), so we apply it on the ROOT joint
    local rj = try(function() return tf:call("getJointByName", "root") end)
    if rj then
        local ay = (C.face_travel and S.heading) and (S.heading + math.rad(C.yaw_offset)) or 0.0
        local hy, hx, hz = ay * 0.5, math.rad(C.body_pitch) * 0.5, math.rad(C.body_roll) * 0.5
        -- q = yaw(Y) * pitch(X) * roll(Z)
        local qy = { 0, math.sin(hy), 0, math.cos(hy) }
        local qx = { math.sin(hx), 0, 0, math.cos(hx) }
        local qz = { 0, 0, math.sin(hz), math.cos(hz) }
        local function mul(a, b)
            return {
                a[4]*b[1] + a[1]*b[4] + a[2]*b[3] - a[3]*b[2],
                a[4]*b[2] - a[1]*b[3] + a[2]*b[4] + a[3]*b[1],
                a[4]*b[3] + a[1]*b[2] - a[2]*b[1] + a[3]*b[4],
                a[4]*b[4] - a[1]*b[1] - a[2]*b[2] - a[3]*b[3],
            }
        end
        local q = mul(mul(qy, qx), qz)
        pcall(function()
            rj:call("set_LocalRotation", Quaternion.new(q[1], q[2], q[3], q[4]))
        end)
    end
end

-- ─── mode ────────────────────────────────────────────────────────────────────

-- ⛔⛔ THE REASON A PAINTED CLIP DOES NOT SHOW (IrisAnimLab law L3):
-- "Think-stop ALONE leaves the FSM owning layer 0, so a painted clip never shows.
--  Clips only SHOW with via.motion.MotionFsm2 disabled."
-- app.Human.Fsm IS via.motion.MotionFsm2. We write 19/19 bones successfully every frame and the
-- FSM simply re-poses the body afterwards.
-- ⛔ AND: think ALIVE + MotionFsm2 off is the SAFE puppet. A think-STOPPED body playing a
-- streamed clip is a native AV that pcall cannot catch. Never think-stop here.
-- ═══ THE HOLD: SUBSTITUTION, NOT SUBTRACTION ════════════════════════════════
-- ⛔⛔⛔ GOVERNING LAW (drake air seat, learned over five failed rounds): you CANNOT hold a
-- player off the ground by removing things. FSM off + controller off + gravity zeroed + a
-- position pin is exactly what v12-v16 tried; every kill worked as designed and none mattered,
-- because once the player is cut out of a valid state the game's only answer is "falling", and
-- the depenetration resolver ejects a pinned body skyward. Aurora hit both failure modes.
-- The answer is to hand the game a state it already owns: sorcerer LEVITATE.
local function player_action(pl, node, priority, layer)
    local am = field_or_get(pl, "get_ActionManager", "<ActionManager>k__BackingField")
    if not am then return false end
    local ok = false
    try(function()
        am:call("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)",
            priority or 0, node, layer or 0)
        ok = true
    end)
    return ok
end

-- ⛔ THE INFINITE DARKNESS = the stuck-player rescue: it warps the held body 70-200m to its last
-- known ground position and FADES THE SCREEN. Cure is belief injection -- no component disabled:
-- tell the game the spot she is in IS safe ground, and zero her accumulated fall.
local function feed_safe_ground(pl, y)
    local rec = try(function() return pl:get_field("<PosRotRecorder>k__BackingField") end)
    if rec then
        local lp = try(function() return rec:get_field("LandingProcessor") end)
        if lp then
            local tf = try(function() return pl:call("get_Transform") end)
            local p = tf and try(function() return tf:call("get_UniversalPosition") end)
            if p then
                local g = via_pos(p.x, (y or p.y) - 0.6, p.z)
                if g then try(function() lp:call("set_LastGroundPosition", g) end) end
            end
            try(function() lp:call("resetFallingStuckStopperToCurrentPosition") end)
        end
        try(function() rec:call("set_IsSafeCoord", true) end)
    end
    local fi = try(function() return pl:get_field("<FallInfo>k__BackingField") end)
    if fi then
        try(function() fi:call("resetFallHeight") end)
        try(function() fi:call("set_FallHeight", 0.0) end)
    end
end

local function levitate_hold(pl)
    local hu = try(function() return pl:call("get_Human") end)
    local lc = hu and field_or_get(hu, "get_LevitateCtrl", "<LevitateCtrl>k__BackingField")
    if not lc then S.lev = "no LevitateCtrl"; return end

    -- ⛔ never write Param in the same frame as the request -- it cancels the action while it is
    -- still starting (that was the "hold kills levitate" bug).
    local since = os.clock() - (S.lev_req or 0)
    if since > 0.15 then
        try(function() lc.Param.MaxKeepSec = 10000.0 end)
        try(function() lc.UpDownMode = 3 end)
    end
    -- ⛔ get_IsActive() lies in some states, but a false reading always means re-arm is safe.
    local active = try(function() return lc:call("get_IsActive") end)
    if active ~= true and since > 0.30 then
        S.lev_req = os.clock()
        player_action(pl, "JobMagicUser_StartLevitate", 0, 0)
    end
    S.lev = (active == true) and "levitating" or "arming"
end

local function set_fsm(pl, on)
    local hu = try(function() return pl:call("get_Human") end)
    local fsm = hu and try(function() return hu:get_field("Fsm") end)
    if not fsm then
        local go = try(function() return pl:call("get_GameObject") end)
        fsm = go and try(function()
            return go:call("getComponent(System.Type)",
                sdk.typeof("via.motion.MotionFsm2"))
        end)
    end
    if fsm then try(function() fsm:call("set_Enabled", on) end) end
    S.fsm_ok = fsm ~= nil
end

-- stop the underlying locomotion clip advancing, or its root motion slides her "on ice"
-- underneath our pose (the couples law).
local function pause_motion(pl, paused)
    local m = try(function() return pl:call("get_Motion") end)
    if not m then return end
    local sp = paused and 0.0 or 1.0
    try(function() m:call("set_Speed", sp) end)
    for i = 0, 15 do
        try(function() m:call("getLayer", i):call("set_Speed", sp) end)
    end
end

local function enter()
    local pl = player()
    if not pl then return end
    -- SUBSTITUTION: give her a valid airborne state, then write position on top of it.
    -- ⛔ No gravity zeroing and NO setCharacterControllerEnable(false) here -- that combination
    -- is what ejected her into the sky and dropped her through the floor.
    S.lev_req = os.clock()
    player_action(pl, "JobMagicUser_StartLevitate", 0, 0)
    -- terrain snap off is part of Nick's proven levitate recipe (stops the ground yanking her)
    local adj = try(function() return pl:get_field("<AdjustTerrain>k__BackingField") end)
    if adj then try(function() adj:call("setEnable", false) end); S.adj_off = true end
    if C.own_pose then
        set_fsm(pl, false)
        pause_motion(pl, true)
    end
    local tf = try(function() return pl:call("get_Transform") end)
    local p = tf and try(function() return tf:call("get_UniversalPosition") end)
    if p and C.entry_lift > 0.01 then
        local ny = p.y + C.entry_lift
        if S.surf then ny = math.min(ny, S.surf - C.surface_gap) end
        local q = via_pos(p.x, ny, p.z)
        if q then try(function() tf:call("set_UniversalPosition", q) end) end
    end
    -- seat the pin at where she actually is AFTER the entry lift
    local p2 = tf and try(function() return tf:call("get_UniversalPosition") end)
    S.target_y = p2 and p2.y or (p and p.y) or nil
    S.vy, S.frame, S.last_t, S.clip = 0, 0, os.clock(), CLIP_CRUISE
    S.on = true
end

local function leave()
    local pl = player()
    if pl then
        if S.grav then try(function() pl:set_field("Gravity", S.grav) end) end
        if S.cc_off then try(function() pl:call("setCharacterControllerEnable", true) end) end
        if S.adj_off then
            local adj = try(function() return pl:get_field("<AdjustTerrain>k__BackingField") end)
            if adj then try(function() adj:call("setEnable", true) end) end
            S.adj_off = false
        end
        -- hand her back to normal locomotion, or she is left in a caster float
        player_action(pl, "NormalLocomotion", 0, 0)
        player_action(pl, "UpperBodyDefault", 0, 1)
        -- ⛔ a frozen FSM never thaws itself; every exit path must restore it
        set_fsm(pl, true)
        pause_motion(pl, false)
        -- joints keep the last written value forever -- put the root back
        local tf = try(function() return pl:call("get_Transform") end)
        local rj = tf and try(function() return tf:call("getJointByName", "root") end)
        if rj then
            local b = try(function() return rj:call("get_BaseLocalRotation") end)
            if b then pcall(function() rj:call("set_LocalRotation", b) end) end
        end
    end
    S.grav, S.cc_off, S.on, S.vy, S.target_y = nil, false, false, 0, nil
    S.status = "on land"
end

-- ⛔ VERIFY, DO NOT ASSUME. Every write in this file was wrapped in a pcall that swallowed its
-- own failure, so "nothing works" gave no clue which of four writes was the broken one. This
-- writes gravity by three routes and READS IT BACK, reporting what actually stuck.
local function set_gravity(pl, want)
    local how = "?"
    try(function() pl:set_field("Gravity", want) end)
    local got = try(function() return pl:get_field("Gravity") end)
    if type(got) == "number" and math.abs(got - want) < 0.001 then
        S.grav_how = "set_field"
        return got
    end
    try(function() pl:call("set_Gravity", want) end)
    got = try(function() return pl:get_field("Gravity") end)
    if type(got) == "number" and math.abs(got - want) < 0.001 then
        S.grav_how = "set_Gravity()"
        return got
    end
    local hu = try(function() return pl:call("get_Human") end)
    if hu then
        try(function() hu:set_field("Gravity", want) end)
        local g2 = try(function() return hu:get_field("Gravity") end)
        if type(g2) == "number" and math.abs(g2 - want) < 0.001 then
            S.grav_how = "Human.Gravity"
            return g2
        end
    end
    S.grav_how = "ALL FAILED (read " .. tostring(got) .. ")"
    return got
end

local function swim_tick(pl)
    if not (S.on and pl) then S.diag = "S.on=false"; return end

    -- the hold, re-asserted every frame, plus the belief injection that stops the stuck-player
    -- rescue fading the screen and warping her away.
    levitate_hold(pl)
    feed_safe_ground(pl, S.target_y)

    S.diag = ("on=%s lev=%s"):format(tostring(S.on), tostring(S.lev))

    local up   = hk.chk_down("Swim Up")
    local dn   = hk.chk_down("Swim Down")
    local fast = hk.chk_down("Swim Fast")
    local dt, mult = 1 / 60, fast and C.fast_mult or 1.0

    if up and not dn then S.vy = C.rise * mult
    elseif dn and not up then S.vy = -C.sink * mult
    else
        S.vy = S.vy - S.vy * math.min(1, C.glide * dt)
        if math.abs(S.vy) < 0.01 then S.vy = 0 end
    end

    S.clip = (S.vy < -0.4) and CLIP_DOWN or (fast and CLIP_SPRINT or CLIP_CRUISE)

    local tf = try(function() return pl:call("get_Transform") end)
    local p = tf and try(function() return tf:call("get_UniversalPosition") end)
    if not p then return end

    -- ⛔⛔ ABSOLUTE PIN, NOT A RELATIVE NUDGE. Reading her Y fresh each frame and adding vy*dt
    -- means that whenever anything else drags her down we read the ALREADY-FALLEN position and
    -- add our small offset on top -- so we follow her through the floor instead of holding her.
    -- Hold an absolute target and write THAT, exactly like the griffin rider seat pin.
    if not S.target_y then S.target_y = p.y end
    S.target_y = S.target_y + S.vy * dt

    -- ⛔ EJECTION GUARD. If she is more than this far off the pin, the engine won the frame --
    -- almost certainly the depenetration resolver launching her. Do NOT shove her back: that
    -- feeds the resolver and is exactly what produced "shooting up into the air repeatedly".
    -- Re-seat to where she actually is, and bail out of the mode if it keeps happening.
    local off = p.y - S.target_y
    if math.abs(off) > 2.5 then
        S.target_y = p.y
        S.eject = (S.eject or 0) + 1
        if S.eject >= 5 then
            S.status = "EJECTED -- swim mode released for safety"
            S.eject = 0
            S.bail = true
            return
        end
    end

    if S.surf and finite(S.surf) then
        local ceil = S.surf - C.surface_gap
        if S.target_y > ceil then
            S.target_y = ceil
            if S.vy > 0 then S.vy = 0 end
            if hk.chk_trig("Swim Jump") then S.vy = C.rise * 1.8 end   -- breach at the surface
            S.status = ("surface | %.1f m/s"):format(S.speed)
        else
            S.status = ("%.1fm down | %.1f m/s"):format(S.surf - S.target_y, S.speed)
        end
    end
    local ny = S.target_y

    if not finite(ny) then return end
    local q = via_pos(p.x, ny, p.z)
    if q then try(function() tf:call("set_UniversalPosition", q) end) end

    -- read back: did the position write actually land, or is something re-asserting over us?
    local after = try(function() return tf:call("get_UniversalPosition") end)
    -- drift = how far the engine dragged her off the pin between our writes. A large, growing
    -- drift means something is still winning the frame and the pin is only papering over it.
    S.diag = S.diag .. ("  vy=%.2f pin=%.2f gotY=%s drift=%.2f keys[%s%s%s]"):format(
        S.vy, ny, after and ("%.2f"):format(after.y) or "nil", p.y - (S.target_y or p.y),
        up and "U" or "-", dn and "D" or "-", fast and "F" or "-")
end

-- ─── hooks ───────────────────────────────────────────────────────────────────

-- ONE guarded hook: keep the weapon sheathed so nothing swings while swimming. Nick's proven
-- shape (PositionTools.lua:135-138). Gated on S.on, so it is a passthrough when not swimming.
if not _G.IRIS_SWIM_HOOKED then
    _G.IRIS_SWIM_HOOKED = true
    local function block()
        if S.on and C.sheathe_lock then return sdk.PreHookResult.SKIP_ORIGINAL end
    end
    local n = 0
    pcall(function()
        local td = sdk.find_type_definition("app.PlayerInputProcessor")
        for _, m in ipairs({ "processDrawWeapon()", "processSheathe()" }) do
            local mm = td and td:get_method(m)
            if mm then sdk.hook(mm, block); n = n + 1 end
        end
    end)
    S.hook_n = n   -- 0 here means the sheathe lock was never installed at all
end

re.on_application_entry("LateUpdateBehavior", function()
    pcall(function()
        if not C.enabled then if S.on then leave() end return end
        local pl = player()
        sense(pl)
        if C.auto then
            if not S.on and S.depth >= C.enter_depth then enter()
            elseif S.on and S.depth <= C.exit_depth then leave() end
            if not S.on then S.status = (S.depth > 0.05)
                and ("wading %.2fm"):format(S.depth) or "on land" end
        end
        swim_tick(pl)
        -- the ejection guard asked us to stand down; do it OUTSIDE the tick so everything
        -- restores cleanly, and stay out until she walks back in deliberately.
        if S.bail then S.bail = false; leave(); C.auto = false; save_cfg() end
    end)
end)

re.on_application_entry("PrepareRendering", function()
    pcall(function() paint(player()) end)
end)

re.on_script_reset(function() pcall(function()
    if S.on then leave() end
    if C.suppress_brine then brine(false) end
end) end)

-- brine is suppressed at load, and stays suppressed. It is not a per-swim toggle: being killed
-- for standing in a river is the thing this mod exists to remove.
if C.suppress_brine then pcall(function() brine(true) end) end

-- ─── UI (one screen) ─────────────────────────────────────────────────────────

re.on_draw_ui(function()
    if not imgui.tree_node("IRIS Swim") then return end
    local ch, v

    imgui.text(S.status .. (S.note ~= "" and ("   [" .. S.note .. "]") or ""))
    imgui.text("depth " .. ("%.2f"):format(S.depth or 0) ..
               "  surf " .. (S.surf and ("%.2f"):format(S.surf) or "nil") ..
               "  hooks " .. tostring(S.hook_n))
    imgui.text(tostring(S.diag))
    imgui.text(tostring(S.pdiag))
    imgui.separator()

    ch, v = imgui.checkbox("Enabled", C.enabled); if ch then C.enabled = v; save_cfg() end
    imgui.same_line()
    ch, v = imgui.checkbox("Auto", C.auto); if ch then C.auto = v; save_cfg() end
    imgui.same_line()
    ch, v = imgui.checkbox("No brine", C.suppress_brine)
    if ch then C.suppress_brine = v; brine(v); save_cfg() end
    imgui.same_line()
    ch, v = imgui.checkbox("Sheathe", C.sheathe_lock); if ch then C.sheathe_lock = v; save_cfg() end

    ch, v = imgui.checkbox("Own pose (FSM off -- REQUIRED for the clip to show)", C.own_pose)
    if ch then C.own_pose = v; if S.on then leave() end; save_cfg() end
    imgui.same_line()
    ch, v = imgui.checkbox("Face travel", C.face_travel); if ch then C.face_travel = v; save_cfg() end

    ch, v = imgui.drag_float("body pitch", C.body_pitch, 0.5, -180, 180)
    if ch then C.body_pitch = v; save_cfg() end
    ch, v = imgui.drag_float("body roll", C.body_roll, 0.5, -180, 180)
    if ch then C.body_roll = v; save_cfg() end
    ch, v = imgui.drag_float("yaw offset", C.yaw_offset, 1.0, -180, 180)
    if ch then C.yaw_offset = v; save_cfg() end
    ch, v = imgui.drag_float("float depth", C.surface_gap, 0.01, 0, 3)
    if ch then C.surface_gap = v; save_cfg() end
    ch, v = imgui.drag_float("rise / sink m/s", C.rise, 0.05, 0.1, 10)
    if ch then C.rise = v; C.sink = v; save_cfg() end
    ch, v = imgui.drag_float("glide", C.glide, 0.1, 0.5, 30)
    if ch then C.glide = v; save_cfg() end
    ch, v = imgui.drag_float("stroke rate", C.clip_rate, 0.01, 0.05, 3)
    if ch then C.clip_rate = v; save_cfg() end
    -- ⛔ max 2.8: get_WaterDepth() SATURATES at 3.0 (engine _MaxWaterDepth), so any threshold
    -- at or above 3 can never be reached and swimming would simply never trigger.
    ch, v = imgui.drag_float("enter depth", C.enter_depth, 0.05, 0.2, 2.8)
    if ch then C.enter_depth = v; C.exit_depth = math.min(C.exit_depth, v - 0.2); save_cfg() end

    if imgui.tree_node("Controls") then
        local changed = false
        for _, name in ipairs({ "Swim Up", "Swim Down", "Swim Fast", "Swim Jump" }) do
            if hk.hotkey_setter(name, nil, name) then changed = true end
        end
        if changed then pcall(function() json.dump_file("IrisSwim_keys.json", hk.hotkeys) end) end
        imgui.tree_pop()
    end

    imgui.tree_pop()
end)
