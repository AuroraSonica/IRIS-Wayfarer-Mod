-- I.R.I.S. MOUNT COMBAT -- the shared combat script for every rideable mount.
--
-- This is the wolf/panther mounted-combat architecture (IrisHorseRodeo's
-- iris_wyrm_* family) ported onto the griffin, and deliberately written so a
-- second, third and fourth mount can adopt it by adding a table entry rather
-- than a new bespoke attack system.  Aurora's standing directive, 2026-08-19
-- and again 08-21: "this should be the combat script for every mount going
-- forward (that has combat)".
--
-- WHAT THE WOLF TAUGHT US, AND WHAT IT MEANS HERE
--
--  1. ⭐ CLIPS OWN THEIR ATTACK EVENTS.  A motion-driven authored attack clip
--     fires its OWN collider request through the body's HitController -- even
--     on a parked graph -- provided the HitController is REARMED first
--     (HitHistory/MultiHitHistory cleared, IsUseAttack + IsRequestAtkColl set).
--     That single fact is what gives a strike real reactions, real material
--     sound, real blood and real hit-stop instead of silent HP subtraction.
--     The ridden griffin is in a BETTER position than the ridden wolf for this:
--     set_griffin_puppet leaves think ALIVE (it only stops nav + the decision
--     maker), which is why the gust can already read a live get_Frame.
--
--  2. ⛔ THE OLD GRIFFIN DAMAGE PATH IS SILENT.  griffin_damage_via_pipeline and
--     griffin_damage_via_update are both latched off behind IRIS_UNSAFE_DAMAGE_PACKET
--     (retired 08-14 after fabricated-DamageInfo access violations), so
--     griffin_apply_attack_damage is a raw setHp: no blood, no stagger, no hit
--     FX.  That is the real reason her combat feels dead.  We do not re-enable
--     fabricated packets -- we let the authored clip do the work and keep the
--     radius pulse only as an honest fallback when the native window missed.
--
--  3. ⭐ NEVER COUNTERFEIT A HIT.  A miss stays a miss.  The receipt
--     (S.route3_combat_receipt) always names which route paid: "native",
--     "fallback pulse", or "miss".
--
--  4. ⛔ ONE DAMAGE OWNER PER ATTACK.  If the native window transacted, the
--     fallback pulse must NOT also fire -- otherwise every connected strike
--     bills twice.  The updateDamageHp detector below is the arbiter.
--
--  5. ⛔⛔ NATIVE HITBOXES CUT BOTH WAYS.  An authored ch253 attack volume does
--     not know the Arisen is riding it; it will happily maul the player and her
--     pawns.  downed.lua already owns the INCOMING half of that problem (the
--     friendly-fire shield).  iris_mc_install_damage_hook installs the OUTGOING
--     half in the same proven shape and at the same authoritative argument.
--
-- WHAT THIS FILE OWNS
--   * target acquisition inside a real strike volume (not "nearest in the scene")
--   * auto-aim: a decisive eased turn onto the acquired body, full circle
--   * the combat camera: a side-on shot that frames HER and the victim together
--   * native strike primitives: rearm, explicit collider request, hit detection,
--     damage amplification, party shield
--   * the staged ground-attack COMBO (talon stamp -> beak -> rush-beak finisher)
--   * the gust finale: real wing-beat frame measurement + the Barghest knockback
--     shell that the wolf's howl uses
--   * the subtle target marker that replaces the old "[ LOCK ]" text
--   * RT prone finisher support for the ground meal
--
-- ⛔ CONFIG KEYS LIVE IN THE MAIN FILE'S `DEFAULT` TABLE.  merge_config runs
-- thousands of lines before this module is required, and it silently DISCARDS
-- any key missing from DEFAULT.  Adding a key here would read as "config isn't
-- saving".  Every route3_combat_* / route3_gust_shell_* / route3_ground_eat_prone*
-- key is declared beside the gatk block in GriffinRideProbe - Iris.lua.

local ctx = require("IrisGriffin.context")
local C, S = ctx.C, ctx.S
local MOD                              = ctx.MOD
local char_go                          = ctx.char_go
local get_component                    = ctx.get_component
local get_player                       = ctx.get_player
local go_name                          = ctx.go_name
local is_dead                          = ctx.is_dead
local is_player_or_party               = ctx.is_player_or_party
local make_position                    = ctx.make_position
local make_quat_yaw                    = ctx.make_quat_yaw
local mounts                           = ctx.mounts
local play_griffin_motion              = ctx.play_griffin_motion
local raw_gamepad_button_down          = ctx.raw_gamepad_button_down
local reacquire_griffin                = ctx.reacquire_griffin
local save_config                      = ctx.save_config
local set_character_rotation_only      = ctx.set_character_rotation_only
local set_character_transform          = ctx.set_character_transform
local set_object_rotation_only         = ctx.set_object_rotation_only
local set_transform                    = ctx.set_transform
local singleton                        = ctx.singleton
local status                           = ctx.status
local system_array_to_table            = ctx.system_array_to_table
local transform_pos                    = ctx.transform_pos
local yaw_from_transform               = ctx.yaw_from_transform

-- ============================================================================
--  SPECIES MOVESETS -- the whole point of the "shared script" ask.
--
--  A mount joins mounted combat by adding one entry here.  Every field is a
--  VERIFIED atlas (bank, clip) pair read by NAME out of Animal Atlas -- never a
--  guessed id (a wrong clip on a parked FSM can hard-crash the game).
--
--  ch253 (griffin), from Animal Atlas/IrisTaming_atlas_ch253000.json:
--      50:0   ch53_000_atk_handstamp_G      double talon stamp
--      50:10  ch53_000_atk_beak_G           beak strike
--      50:512 ch53_000_atk_rush_beak_F      the forward lunging beak -- the
--                                           payoff frame of her native rush
--      50:515 ch53_000_atk_rush_beak_end    its authored recovery
--
--  frames: the stomp/beak numbers are Aurora's own measurements, recovered from
--  the retired route3_gatk_*_hit_frame / _cancel_frame / _end_frame config keys
--  (they were measured, then shelved when the timed-seconds attack replaced the
--  frame experiment).  They are reinstated here as what they always were:
--  authored frame data.  Link 3's are first-pass and are auto-clamped to the
--  live EndFrame, with a stamp tool in the panel to correct them in one field run.
-- ============================================================================

IRIS_MC_MOVESETS = {
    ch253 = {
        name = "griffin",
        bank = 50,
        -- Link 3's numbers come from config so Aurora can stamp them live.
        links = {
            {
                key = "stomp", label = "talon stamp", clip = 0,
                hit_key = "route3_gatk_stomp_hit_frame",
                link_key = "route3_gatk_stomp_cancel_frame",
                end_key = "route3_gatk_stomp_end_frame",
                radius_key = "route3_gatk_stomp_radius",
                forward_key = "route3_gatk_stomp_forward",
                damage_key = "route3_gatk_damage",
                reqid_key = "route3_combat_reqid_stomp",
                joints = { "L_PropA", "R_PropA" },
                fallback_hit = 45.0, fallback_link = 53.0, fallback_end = 70.0,
            },
            {
                key = "beak", label = "beak", clip = 10,
                hit_key = "route3_gatk_beak_hit_frame",
                link_key = "route3_gatk_beak_cancel_frame",
                end_key = "route3_gatk_beak_end_frame",
                radius_key = "route3_gatk_peck_radius",
                forward_key = "route3_gatk_peck_forward",
                damage_key = "route3_gatk_peck_damage",
                reqid_key = "route3_combat_reqid_beak",
                joints = { "Jaw_0" },
                fallback_hit = 60.0, fallback_link = 68.0, fallback_end = 85.0,
            },
            {
                key = "rush", label = "rush beak", clip_key = "route3_combat_link3_clip",
                tail_key = "route3_combat_link3_tail_clip",
                hit_key = "route3_combat_link3_hit_frame",
                link_key = "route3_combat_link3_link_frame",
                end_key = "route3_combat_link3_end_frame",
                radius_key = "route3_combat_link3_radius",
                forward_key = "route3_combat_link3_forward",
                damage_key = "route3_combat_link3_damage",
                reqid_key = "route3_combat_reqid_rush",
                joints = { "Jaw_0" },
                finisher = true,
                fallback_hit = 22.0, fallback_link = 34.0, fallback_end = 46.0,
                clip_fallback = 512, tail_fallback = 515,
            },
        },
    },
}

-- ============================================================================
--  SMALL SHARED READERS
-- ============================================================================

function iris_mc_kb(vk)
    vk = math.floor(tonumber(vk) or 0)
    if vk <= 0 then return false end
    local down = false
    if type(iris_kb) == "function" then
        pcall(function() down = iris_kb(vk) == true end)
    else
        pcall(function() down = reframework:is_key_down(vk) == true end)
    end
    return down == true
end

function iris_mc_species_key(go)
    -- ⛔ Read the species from the BODY, never from a mode flag.  The drake, the
    -- wolf and the griffin can all be the thing under the saddle, and a moveset
    -- picked from "we are mounted" would fire ch253 clips at a ch257.
    local nm = tostring(go_name(go) or "")
    local id = nm:match("[cC][hH](%d%d%d)")
    return id and ("ch" .. id) or nil
end

function iris_mc_moveset()
    local _, go = reacquire_griffin()
    if not go then return nil, nil end
    local key = iris_mc_species_key(go)
    return key and IRIS_MC_MOVESETS[key] or nil, key
end

function iris_mc_cfg(key, fallback)
    if key == nil then return fallback end
    local v = tonumber(C[key])
    if v == nil then return fallback end
    return v
end

-- ⛔ A CLIP ID IS ONLY HALF AN ADDRESS -- it is a (bank, id) PAIR. route3_flap_layer_clip reads
-- the MotionID alone, so bank 0's clip 0 and bank 50's clip 0 (the talon stamp) are
-- indistinguishable through it. Every frame decision in this file goes through this reader, which
-- refuses to answer unless the live layer is genuinely playing OUR bank.
function iris_mc_layer_sample(bank)
    local clip, frame, ending = nil, nil, nil
    pcall(function()
        local ch = reacquire_griffin()
        local motion = ch and ch:call("get_Motion")
        local layer = motion and motion:call("getLayer", 0)
        if not layer then return end
        if tonumber(layer:call("get_MotionBankID")) ~= math.floor(tonumber(bank) or -1) then
            return
        end
        clip = tonumber(layer:call("get_MotionID"))
        frame = tonumber(layer:call("get_Frame"))
        ending = tonumber(layer:call("get_EndFrame"))
    end)
    return clip, frame, ending
end

function iris_mc_link_clip(link)
    if link.clip ~= nil then return math.floor(link.clip) end
    return math.floor(iris_mc_cfg(link.clip_key, link.clip_fallback or 0))
end

function iris_mc_link_tail(link)
    if not link.tail_key then return nil end
    local v = math.floor(iris_mc_cfg(link.tail_key, link.tail_fallback or -1))
    if v < 0 then return nil end
    return v
end

-- Frame numbers are authored data, but a clip's real EndFrame is the only thing
-- that can veto a bad one.  Read the live layer and clamp; never let a stale
-- config number push the impact past the end of the animation (which is exactly
-- how a "the attack does nothing" report is born).
-- ⛔⛔ 08-21 FIELD LAW: THIS MOD ASSUMED 30fps EVERYWHERE AND IT IS ~60.
-- The gust calibration came back "clip 202 ... end=347.0" with beats 61-94 frames apart. A wing
-- beat is not two seconds; at 60fps it is ~1s, which fits. Every hand-written frame constant in
-- the ground-attack config was derived from seconds x 30 and is therefore HALF the frame it
-- meant. That is why the rush beak "ends before an attack happens".
--
-- The cure is to stop writing frame constants at all: a fraction of the clip's OWN measured
-- EndFrame is both framerate- and length-independent, and it self-fits a clip nobody has
-- measured yet. 0 in a *_frame key means AUTO; a stamped value above 0 overrides it, and is
-- still clamped so a stale stamp can never point past the end of the animation.
function iris_mc_link_frames(link, end_frame)
    local ef = tonumber(end_frame)
    local hit = iris_mc_cfg(link.hit_key, link.fallback_hit)
    local lnk = iris_mc_cfg(link.link_key, link.fallback_link)
    local fin = iris_mc_cfg(link.end_key, link.fallback_end)
    if ef and ef > 4.0 then
        local fh = math.max(0.05, math.min(0.95, iris_mc_cfg("route3_combat_frac_hit", 0.62)))
        local fl = math.max(0.05, math.min(0.98, iris_mc_cfg("route3_combat_frac_link", 0.72)))
        local fe = math.max(0.10, math.min(1.00, iris_mc_cfg("route3_combat_frac_end", 0.97)))
        if hit <= 0.0 or hit >= ef then hit = ef * fh end
        if lnk <= 0.0 or lnk >= ef then lnk = ef * fl end
        if fin <= 0.0 or fin > ef then fin = ef * fe end
        if lnk <= hit then lnk = math.min(ef, hit + 4.0) end
        if fin <= lnk then fin = math.min(ef, lnk + 4.0) end
    else
        -- No measurement yet (first frames after a paint, or the layer is hidden). Fall back to
        -- the first-pass constants so the link can always complete rather than hanging.
        if hit <= 0.0 then hit = link.fallback_hit end
        if lnk <= 0.0 then lnk = link.fallback_link end
        if fin <= 0.0 then fin = link.fallback_end end
    end
    return hit, lnk, fin
end

-- The playhead rate, MEASURED rather than assumed. Used only for the fallback clock while the
-- layer is not showing our clip; once it is, the real playhead is authoritative.
function iris_mc_fps()
    local live = tonumber(S.route3_combat_fps_live)
    if live and live > 10.0 then return live end
    return math.max(10.0, iris_mc_cfg("route3_combat_fps", 60.0))
end

function iris_mc_note_rate(st, frame, now)
    if not (st.synced and frame) then st.prev_frame, st.prev_clock = frame, now; return end
    local pf, pc = tonumber(st.prev_frame), tonumber(st.prev_clock)
    st.prev_frame, st.prev_clock = frame, now
    if not (pf and pc and frame > pf) then return end
    local dt = now - pc
    if dt < 0.004 or dt > 0.25 then return end
    local rate = (frame - pf) / dt
    if rate < 10.0 or rate > 200.0 then return end
    local cur = tonumber(S.route3_combat_fps_live) or iris_mc_cfg("route3_combat_fps", 60.0)
    S.route3_combat_fps_live = cur + (rate - cur) * 0.05   -- heavy smoothing; frame pacing is noisy
end

-- One log line per clip, the first time its real length is seen. Three of these and the whole
-- moveset can be pinned to exact frames instead of fractions.
function iris_mc_note_endframe(bank, clip, endf)
    if not (endf and endf > 1.0 and clip) then return end
    S.route3_combat_endframes = type(S.route3_combat_endframes) == "table"
        and S.route3_combat_endframes or {}
    local key = tostring(bank) .. ":" .. tostring(clip)
    if S.route3_combat_endframes[key] then return end
    S.route3_combat_endframes[key] = endf
    log.info(string.format("[IrisMountCombat] clip %s endframe=%.0f (%.2fs at %.0ffps)",
        key, endf, endf / iris_mc_fps(), iris_mc_fps()))
end

-- ============================================================================
--  TARGET ACQUISITION
--
--  Port of iris_wyrm_attack_target.  Selects inside the STRIKE VOLUME, from the
--  striking joint, not "nearest entry in EnemyManager" -- the nearest-first
--  route could lock a goblin behind her while the doe under her beak was never
--  considered.  One sweep per press (plus a short retention cache so a combo
--  keeps its victim), never per frame.
-- ============================================================================

function iris_mc_target_hp(ch, go)
    -- ⛔⛔ app.Character has NO get_HitController -- calling it throws inside a
    -- silent pcall and reads as "no HP".  Component lookup only.
    if not go then return nil end
    local hp = nil
    pcall(function()
        local hc = griffin_target_hit_controller(ch) or get_component(go, "app.HitController")
        -- get_Hp is the field-proven current-health authority. The broad
        -- component reader tries get_Current first, but on some enemy controllers
        -- that is a state/index rather than health; a corpse could consequently
        -- look alive and win a nearest-target comparison.
        if hc then hp = hc:call("get_Hp") end
        if not tonumber(hp) then hp = hc and griffin_hp_from_component(hc) or nil end
    end)
    return tonumber(hp)
end

function iris_mc_strike_origin(go, gp, joints)
    -- The live joint is authoritative; the root is metres behind her beak.
    for _, jn in ipairs(joints or {}) do
        local p = nil
        pcall(function() p = griffin_predation_joint_world_position(go, gp, jn) end)
        if p then
            if #joints > 1 then
                local q = nil
                pcall(function()
                    q = griffin_predation_joint_world_position(go, gp, joints[2])
                end)
                if q and jn == joints[1] then
                    return make_position(((tonumber(p.x) or 0.0) + (tonumber(q.x) or 0.0)) * 0.5,
                        ((tonumber(p.y) or 0.0) + (tonumber(q.y) or 0.0)) * 0.5,
                        ((tonumber(p.z) or 0.0) + (tonumber(q.z) or 0.0)) * 0.5)
                end
            end
            return p
        end
    end
    return gp
end

function iris_mc_acquire(spec)
    local ch, go = reacquire_griffin()
    local gp = go and transform_pos(go)
    if not gp then return nil, nil end
    spec = spec or {}
    local origin = iris_mc_strike_origin(go, gp, spec.joints)
    local yaw = yaw_from_transform(go) or S.heading_yaw or 0.0
    local fx, fz = math.sin(yaw), math.cos(yaw)
    local reach = tonumber(spec.reach) or iris_mc_cfg("route3_combat_reach", 9.0)
    local width = tonumber(spec.width) or iris_mc_cfg("route3_combat_width", 6.5)
    local vertical = tonumber(spec.vertical) or iris_mc_cfg("route3_combat_vertical", 8.0)
    local aim_deg = tonumber(spec.aim_deg) or iris_mc_cfg("route3_combat_aim_deg", 180.0)
    local self_addr = go:get_address()
    local best, best_go, best_score, best_hp = nil, nil, math.huge, nil

    local function consider(cch)
        if not cch then return end
        pcall(function()
            if not route3_ground_target_hostile(cch) then return end
            local cgo = char_go(cch)
            if not cgo or cgo:get_address() == self_addr then return end
            -- A corpse can retain a stale positive HitController value. Death
            -- state/FSM is therefore authoritative even when HP is readable.
            local confirmed_dead = false
            pcall(function()
                confirmed_dead = type(griffin_target_is_dead) == "function"
                    and griffin_target_is_dead(cch) == true
            end)
            if confirmed_dead then return end
            local hp = iris_mc_target_hp(cch, cgo)
            if hp ~= nil and hp <= 0.0 then return end
            -- EnemyManager can retain a corpse after get_IsDead/HP has become
            -- unreadable.  The mounted-combat selector must never let that stale
            -- entry beat a living actor merely because the body is closer.
            if hp == nil and is_dead(cch) then return end
            local pos = transform_pos(cgo)
            if not pos then return end
            local dx = (tonumber(pos.x) or 0.0) - (tonumber(origin.x) or 0.0)
            local dy = (tonumber(pos.y) or 0.0) - (tonumber(origin.y) or 0.0)
            local dz = (tonumber(pos.z) or 0.0) - (tonumber(origin.z) or 0.0)
            local along = dx * fx + dz * fz
            local across = math.abs(dx * fz - dz * fx)
            local radial2 = dx * dx + dz * dz
            if math.abs(dy) > vertical then return end
            -- ⭐ 08-19 wolf law, reused: a 180-degree spec means a genuine FULL
            -- CIRCLE.  The old box gates still rejected a victim square behind
            -- the tail, so she pivoted at nothing.  The aim owns getting the
            -- strike there; acquisition must not pre-veto it.
            local inside
            if aim_deg >= 179.5 then
                inside = radial2 <= reach * reach
            else
                local flat = math.sqrt(math.max(0.0001, radial2))
                local aim_ok = (along / flat) >= math.cos(math.rad(aim_deg))
                inside = along >= -1.5 and along <= reach and across <= width and aim_ok
            end
            if not inside then return end
            local score = radial2 + across * across * 1.5 + dy * dy * 0.08
            if score < best_score then
                best, best_go, best_score, best_hp = cch, cgo, score, hp
            end
        end)
    end

    -- Consecutive combo links keep their victim.  Besides feeling like a real
    -- lock, this avoids a whole-scene component enumeration on every link while
    -- battle actors are spawning and despawning.
    local cached = S.route3_combat_target_cache
    if type(cached) == "table" and os.clock() <= (tonumber(cached.until_t) or 0.0) then
        consider(cached.target)
        if best then return best, best_go end
    end

    pcall(function()
        local em = singleton("app.EnemyManager")
        if not em then return end
        for _, getter in ipairs({ "get_EnemyList", "getAllEnemies",
            "get_ActiveEnemyList", "get_EnemyCharacterList" }) do
            local list = nil
            pcall(function() list = em:call(getter) end)
            local n = 0
            pcall(function() n = tonumber(list and list:call("get_Count")) or 0 end)
            if n > 0 then
                for i = 0, n - 1 do
                    local item = nil
                    pcall(function() item = list:call("get_Item", i) end)
                    pcall(function()
                        consider(ctx.iris_real_character and ctx.iris_real_character(item) or item)
                    end)
                end
                return
            end
        end
    end)
    if not best then
        -- Wildlife (ch299) never reaches EnemyManager, so a deer would report
        -- "nothing to attack" while standing under her beak.
        pcall(function()
            local sm = sdk.get_native_singleton("via.SceneManager")
            local smt = sdk.find_type_definition("via.SceneManager")
            local scene = sm and sdk.call_native_func(sm, smt, "get_CurrentScene")
            local comps = scene and scene:call("findComponents(System.Type)",
                sdk.typeof("app.Character"))
            for _, cch in ipairs(system_array_to_table(comps) or {}) do consider(cch) end
        end)
    end
    if best then
        S.route3_combat_target_cache = { target = best, until_t = os.clock() + 0.85 }
        S.route3_combat_target_status = string.format("LIVE %s hp=%s score=%.1f",
            tostring(go_name(best_go) or "?"), best_hp and string.format("%.1f", best_hp) or "?",
            tonumber(best_score) or -1.0)
    else
        S.route3_combat_target_cache = nil
        S.route3_combat_target_status = "no live target"
    end
    return best, best_go
end

-- ============================================================================
--  AUTO-AIM
--
--  Decisive, eased, and camera-independent.  route3_face_locked_target's slow
--  bodily slew is right for idling toward a marker; an attack that has already
--  committed needs the nose ON the body before the authored window opens, or
--  the camera shows a hit that happened past the victim.
-- ============================================================================

function iris_mc_aim_begin(st, target_go, secs)
    if C.route3_combat_aim_enabled == false then return false end
    local ch, go = reacquire_griffin()
    local gp = go and transform_pos(go)
    local tp = target_go and transform_pos(target_go)
    if not (gp and tp) then return false end
    local dx = (tonumber(tp.x) or 0.0) - (tonumber(gp.x) or 0.0)
    local dz = (tonumber(tp.z) or 0.0) - (tonumber(gp.z) or 0.0)
    if dx * dx + dz * dz < 0.01 then return false end
    local from = yaw_from_transform(go) or S.heading_yaw or 0.0
    local want = math.atan(dx, dz) + (tonumber(st.aim_offset_rad) or 0.0)
    local delta = want - from
    while delta > math.pi do delta = delta - 2.0 * math.pi end
    while delta < -math.pi do delta = delta + 2.0 * math.pi end
    local max_deg = iris_mc_cfg("route3_combat_aim_deg", 180.0)
    if math.abs(math.deg(delta)) > max_deg then return false end
    st.aim_from, st.aim_delta = from, delta
    st.aim_t0 = os.clock()
    st.aim_secs = math.max(0.01, tonumber(secs) or iris_mc_cfg("route3_combat_aim_secs", 0.12))
    return true
end

function iris_mc_aim_tick(st, now)
    if not (st and st.aim_from and st.aim_delta) then return end
    local a = (now - (tonumber(st.aim_t0) or now)) / math.max(0.01, tonumber(st.aim_secs) or 0.12)
    a = math.max(0.0, math.min(1.0, a))
    local eased = 1.0 - (1.0 - a) * (1.0 - a)   -- fast ease-out: helps, never snaps
    local yaw = st.aim_from + st.aim_delta * eased
    S.heading_yaw = yaw
    local ch, go = reacquire_griffin()
    local rot = make_quat_yaw(yaw)
    if go then pcall(function() set_object_rotation_only(go, rot) end) end
    if ch then pcall(function() set_character_rotation_only(ch, rot) end) end
    if a >= 1.0 then st.aim_from, st.aim_delta = nil, nil end
end

-- ============================================================================
--  COMBAT CAMERA
--
--  Aurora: "camera on the target during attack to get a better view".  Same
--  channel the meal camera proved out (_G.IrisGuestCam, written by the rodeo's
--  lateUpdate hook), but framed for a fight: side-on, biased toward the midpoint
--  between her and the victim so both stay in shot, and it releases with a tail
--  so control hands back smoothly instead of snapping.
--
--  ⛔ RENDER SPACE ONLY.  transform_pos is UNIVERSAL in this file and
--  transform_render_pos is RENDER -- the names are the opposite way round from
--  every other Iris file, and feeding universal coordinates to the guest writer
--  is what parked the meal camera under the world.
-- ============================================================================

function iris_mc_target_height(go)
    if not go then return 1.7 end
    local h = nil
    pcall(function()
        local cc = get_component(go, "via.physics.CharacterController")
        h = cc and tonumber(cc:call("get_Height")) or nil
    end)
    -- CharacterController is stable for ordinary enemies. A few large monsters
    -- expose their useful extent only on the render mesh, so use that as a
    -- second source without allowing a weapon/VFX outlier to create a huge arm.
    pcall(function()
        local mesh = get_component(go, "via.render.Mesh")
        local box = mesh and mesh:call("get_WorldAABB")
        local mn, mx = nil, nil
        if box then
            pcall(function() mn, mx = box.minpos, box.maxpos end)
            if not (mn and mx) then pcall(function() mn, mx = box.min, box.max end) end
        end
        local mh = mn and mx and math.abs((tonumber(mx.y) or 0.0) - (tonumber(mn.y) or 0.0)) or nil
        if mh and mh >= 0.5 and mh <= 16.0 then h = math.max(tonumber(h) or 0.0, mh) end
    end)
    return math.max(0.6, math.min(10.0, tonumber(h) or 1.7))
end

function iris_mc_camera_tick(st, look_go)
    if C.route3_combat_cam_enabled == false and not (st and st.force_camera == true) then return end
    if rawget(_G, "__iris_rodeo_mountcam_hooked") ~= true then return end
    pcall(function()
        local _, go = reacquire_griffin()
        local gp = go and transform_render_pos(go)
        if not gp then return end
        local lp = gp
        pcall(function()
            local p2 = look_go and transform_render_pos(look_go)
            if p2 then lp = p2 end
        end)
        local yaw_want = tonumber(st and st.cam_world_yaw)
            or yaw_from_transform(go) or S.heading_yaw or 0.0
        local function angle_step(from, want, blend)
            if from == nil then return want end
            local delta = want - from
            while delta > math.pi do delta = delta - math.pi * 2.0 end
            while delta < -math.pi do delta = delta + math.pi * 2.0 end
            return from + delta * blend
        end
        -- Fire auto-aim updates body yaw continuously. Orbiting the camera from
        -- that raw value magnifies every tiny correction into visible shaking.
        local yaw = yaw_want
        if type(st) == "table" then
            yaw = angle_step(tonumber(st.cam_yaw_smooth), yaw_want, 0.12)
            st.cam_yaw_smooth = yaw
        end
        local base_side = tonumber(st and st.cam_side_deg)
            or iris_mc_cfg("route3_combat_cam_side_deg", -55.0)
        local d = tonumber(st and st.cam_dist) or iris_mc_cfg("route3_combat_cam_dist", 7.5)
        local target_h = iris_mc_target_height(look_go)
        if C.route3_combat_cam_auto_size ~= false and look_go then
            -- Goblin/wolf scale (<=2m) is the authored baseline. Only excess
            -- height pulls back, so small-target framing remains unchanged.
            local gain = math.max(0.0, math.min(4.0,
                iris_mc_cfg("route3_combat_cam_size_gain", 1.8)))
            local extra_cap = math.max(0.0, math.min(24.0,
                iris_mc_cfg("route3_combat_cam_size_max_extra", 12.0)))
            d = d + math.min(extra_cap, math.max(0.0, target_h - 2.0) * gain)
            if type(st) == "table" then st.cam_target_height, st.cam_resolved_dist = target_h, d end
        end
        local bias = math.max(0.0, math.min(1.0, tonumber(st and st.cam_bias)
            or iris_mc_cfg("route3_combat_cam_bias", 0.55)))
        local mx = (tonumber(gp.x) or 0.0) * (1.0 - bias) + (tonumber(lp.x) or 0.0) * bias
        local mz = (tonumber(gp.z) or 0.0) * (1.0 - bias) + (tonumber(lp.z) or 0.0) * bias
        local gy, ly = tonumber(gp.y) or 0.0, tonumber(lp.y) or 0.0
        local vertical_bias = tonumber(st and st.cam_y_bias)
        local my = vertical_bias and (gy * (1.0 - math.max(0.0, math.min(1.0, vertical_bias)))
            + ly * math.max(0.0, math.min(1.0, vertical_bias))) or math.min(gy, ly)
        -- Settled aim: her head travels a long way through a beak strike, and a
        -- 1:1 anchor makes the whole frame lurch with it.
        local prev = S.route3_combat_cam_pt
        local k = math.max(0.02, math.min(1.0, iris_mc_cfg("route3_combat_cam_smooth", 0.22)))
        if type(st) == "table" and st.cam_stabilise == true then k = math.min(k, 0.075) end
        if type(prev) == "table" then
            mx = prev.x + (mx - prev.x) * k
            my = prev.y + (my - prev.y) * k
            mz = prev.z + (mz - prev.z) * k
        end
        S.route3_combat_cam_pt = { x = mx, y = my, z = mz }
        local cam_h = tonumber(st and st.cam_height)
            or iris_mc_cfg("route3_combat_cam_height", 3.2)
        local now = os.clock()
        -- The cinematic chooses a useful opening shot, but the player still owns
        -- composition. Right-stick input offsets that shot for the rest of this
        -- attack; scenery probing remains authoritative and may swap an obstructed
        -- manual side just as it does the authored side.
        if type(st) == "table" and C.route3_combat_cam_manual_orbit ~= false
            and type(scout_read_axis_R) == "function" then
            local last = tonumber(st.cam_stick_last) or now
            local dt = math.max(0.0, math.min(0.05, now - last))
            st.cam_stick_last = now
            local rx, rz = 0.0, 0.0
            pcall(function() rx, rz = scout_read_axis_R() end)
            rx, rz = tonumber(rx) or 0.0, tonumber(rz) or 0.0
            local dead = math.max(0.05, math.min(0.75,
                iris_mc_cfg("route3_combat_cam_stick_deadzone", 0.20)))
            if math.abs(rx) < dead then rx = 0.0 end
            if math.abs(rz) < dead then rz = 0.0 end
            if rx ~= 0.0 then
                local manual = (tonumber(st.cam_manual_side) or 0.0)
                    + rx * iris_mc_cfg("route3_combat_cam_orbit_speed", 110.0) * dt
                while manual > 180.0 do manual = manual - 360.0 end
                while manual < -180.0 do manual = manual + 360.0 end
                st.cam_manual_side = manual
            end
            base_side = base_side + (tonumber(st.cam_manual_side) or 0.0)
            if rx ~= 0.0 then
                st.cam_resolved_side = base_side
                st.cam_side_hold_until = now
            end
            if rz ~= 0.0 then
                local sign = C.route3_combat_cam_invert_y == true and -1.0 or 1.0
                local max_h = math.max(0.0,
                    iris_mc_cfg("route3_combat_cam_height_max", 10.0))
                st.cam_manual_height = math.max(-max_h, math.min(max_h,
                    (tonumber(st.cam_manual_height) or 0.0)
                    + rz * sign * iris_mc_cfg("route3_combat_cam_height_speed", 8.0) * dt))
            end
            cam_h = cam_h + (tonumber(st.cam_manual_height) or 0.0)
            if rx ~= 0.0 or rz ~= 0.0 then
                S.route3_combat_cam_manual_status = string.format(
                    "right stick: orbit %+.0f deg, height %+.1fm",
                    tonumber(st.cam_manual_side) or 0.0,
                    tonumber(st.cam_manual_height) or 0.0)
            end
        end
        local look_h = tonumber(st and st.cam_look_height) or 1.0
        if C.route3_combat_cam_auto_size ~= false and look_go then
            look_h = look_h + math.max(0.0, target_h - 2.0) * 0.38
        end
        local look = { x = mx, y = my + look_h, z = mz }
        if type(st) == "table" and st.drake_attack == true
            and C.route3_drake_camera_scenery_swap ~= false
            and type(route3_camera_path_blocked) == "function"
            and now >= (tonumber(st.cam_occlusion_next) or 0.0) then
            st.cam_occlusion_next = now + 0.15
            local function candidate(side)
                local ca = yaw + math.rad(side)
                return { x = mx + math.sin(ca) * d, y = my + cam_h,
                    z = mz + math.cos(ca) * d }
            end
            local primary_blocked = route3_camera_path_blocked(look, candidate(base_side)) == true
            if primary_blocked then
                local alternatives
                if math.abs(math.abs(base_side) - 180.0) < 12.0 then
                    alternatives = { -135.0, 135.0 }
                elseif math.abs(base_side) < 12.0 then
                    -- Face-on hero shots have no distinct `-0` shoulder. Try
                    -- shallow three-quarter views before abandoning the shot.
                    alternatives = { -45.0, 45.0, -135.0, 135.0 }
                else alternatives = { -base_side } end
                local picked = nil
                for _, side in ipairs(alternatives) do
                    if route3_camera_path_blocked(look, candidate(side)) ~= true then
                        picked = side; break
                    end
                end
                if picked then
                    st.cam_resolved_side = picked
                    st.cam_side_hold_until = now + 0.85
                    S.route3_combat_cam_occlusion = string.format("blocked -> %.0f deg", picked)
                else
                    S.route3_combat_cam_occlusion = "both sides blocked"
                end
            elseif now >= (tonumber(st.cam_side_hold_until) or 0.0) then
                st.cam_resolved_side = base_side
                S.route3_combat_cam_occlusion = "clear"
            end
        end
        local side_want = tonumber(st and st.cam_resolved_side) or base_side
        local side = side_want
        if type(st) == "table" then
            local side_rad = angle_step(st.cam_side_smooth and math.rad(st.cam_side_smooth) or nil,
                math.rad(side_want), 0.16)
            side = math.deg(side_rad)
            st.cam_side_smooth = side
        end
        local a = yaw + math.rad(side)
        rawset(_G, "IrisGuestCam", {
            cam = { x = mx + math.sin(a) * d,
                    y = my + cam_h,
                    z = mz + math.cos(a) * d },
            look = look,
            until_t = os.clock() + 0.35,
        })
        S.route3_combat_cam_live = true
    end)
end

function iris_mc_camera_release()
    if S.route3_combat_cam_live ~= true then return end
    S.route3_combat_cam_live = nil
    S.route3_combat_cam_pt = nil
    S.route3_combat_cam_occlusion = nil
    -- Let the channel LAPSE rather than clearing it: a hard clear on the same
    -- frame the attack ends is the camera snap Aurora reported on the meal.
    local g = rawget(_G, "IrisGuestCam")
    if type(g) == "table" then
        g.until_t = os.clock() + math.max(0.0, iris_mc_cfg("route3_combat_cam_tail", 0.5))
        rawset(_G, "IrisGuestCam", g)
    end
end

-- ============================================================================
--  NATIVE STRIKE PRIMITIVES
-- ============================================================================

-- Replaying an authored attack motion does not perform the ActionManager
-- transition that normally retires the previous attack and clears its victim
-- history.  Without this the FIRST strike uses the real collider and every later
-- one is silently rejected for the same victim.
-- ⛔ AttackList and ColliderRequestList hold the authored volume definitions and
-- must never be cleared or replaced -- only the outgoing bookkeeping.
function iris_mc_rearm(go, label)
    if not go then return false, 0 end
    local hit = get_component(go, "app.HitController")
    if not hit then return false, 0 end
    local cleared = 0
    local function clear_member(name)
        pcall(function()
            local value = hit[name]
            if not value then value = hit:call("get_" .. name) end
            if value then value:call("Clear"); cleared = cleared + 1 end
        end)
    end
    clear_member("HitHistory")
    clear_member("MultiHitHistory")
    clear_member("OldAttackColliderPosition")
    clear_member("AttackHitStopRecordDict")
    local armed = false
    pcall(function()
        hit["<IsUseAttack>k__BackingField"] = true
        hit["<IsRequestAtkColl>k__BackingField"] = true
        armed = true
    end)
    if not armed then
        pcall(function()
            hit:call("set_IsUseAttack(System.Boolean)", true)
            hit:call("set_IsRequestAtkColl(System.Boolean)", true)
            armed = true
        end)
    end
    S.route3_combat_rearm = string.format("%s armed=%s cleared=%d",
        tostring(label or "strike"), tostring(armed), cleared)
    return armed, cleared
end

-- ⛔ THE FLAGS ARE RE-ASSERTED PER FRAME; THE HISTORIES ARE NOT.
-- We do not know exactly which frame of a clip its authored event posts, so the HitController has
-- to be armed across the whole window rather than on one guessed frame.  But CLEARING the hit
-- history on a cadence would make the same victim eligible again mid-swing, and a talon stamp
-- that bills five times is worse than one that misses.  So: booleans every frame, history once,
-- at the paint.
function iris_mc_arm_flags(go)
    if not go then return end
    local hit = get_component(go, "app.HitController")
    if not hit then return end
    pcall(function()
        hit["<IsUseAttack>k__BackingField"] = true
        hit["<IsRequestAtkColl>k__BackingField"] = true
    end)
end

-- Post an exact authored request-track snapshot. A Drake charge is not one
-- ReqId: its live trace is the five-part 600--604 bundle. Keeping this generic
-- lets callers replay the engine's own collider definition without inventing a
-- damage volume. One snapshot per strike only: posting every rendered frame
-- restarts the request state and can prevent the receiver transaction.
function iris_mc_request_collider_tracks(go, ids, label)
    if not go or type(ids) ~= "table" then return false end
    local hit = get_component(go, "app.HitController")
    if not hit then return false end
    local fields = { "ReqId1", "ReqId2", "ReqId3", "ReqId4",
        "ReqId5", "ReqId6", "ReqId7", "ReqId8", "ReqId9", "ReqId10",
        "ReqId11", "ReqId12", "DamageReqId", "PushReqId", "AtkDetectReqId" }
    local tracks = S.route3_combat_tracks
    if not tracks then
        pcall(function()
            tracks = sdk.create_instance("app.ColliderReqTracks")
            if tracks then
                tracks:add_ref()
                pcall(function() tracks:call(".ctor()") end)
                for _, name in ipairs(fields) do tracks:set_field(name, -1) end
            end
        end)
        S.route3_combat_tracks = tracks
    end
    if not tracks then return false end
    local ok = false
    local parts = {}
    pcall(function()
        -- The object is reused, so clear the previous strike's fields first.
        for _, name in ipairs(fields) do tracks:set_field(name, -1) end
        for _, name in ipairs(fields) do
            local value = tonumber(ids[name])
            if value and value >= 0 then
                value = math.floor(value)
                tracks:set_field(name, value)
                parts[#parts + 1] = name .. "=" .. tostring(value)
            end
        end
        if #parts == 0 then return end
        iris_mc_arm_flags(go)
        hit:call("requestSeqCollider(app.ColliderReqTracks)", tracks)
        ok = true
    end)
    if ok then
        S.route3_combat_reqid_last = tostring(label or "strike")
            .. " " .. table.concat(parts, "|")
    end
    return ok
end

function iris_mc_request_collider(go, request_id, label)
    request_id = math.floor(tonumber(request_id) or -1)
    if request_id < 0 then return false end
    return iris_mc_request_collider_tracks(go, { ReqId1 = request_id }, label)
end

-- Native volume extension for the Drake bite lease.  The capture proves its
-- authored clips already post ReqId1=50, so reposting 50 would restart the
-- request rather than make it reach farther.  Scaling HitController's own
-- collider preserves the genuine receiver transaction, hit-stop, reaction and
-- damage while still allowing a geometric miss.
function iris_mc_drake_collider_scale_dispatch(args)
    local st = S.route3_drake_attack
    local stage = type(st) == "table" and st.stage or nil
    local multiplier = tonumber(stage and stage.collider_scale)
    if not multiplier or multiplier <= 1.001 then return nil end
    local hc = nil
    pcall(function() hc = sdk.to_managed_object(args[2]) end)
    local got_addr, own_addr = nil, nil
    pcall(function() got_addr = hc and hc:get_address() or nil end)
    pcall(function()
        own_addr = st.native_hit_controller and st.native_hit_controller:get_address() or nil
    end)
    if not got_addr or got_addr ~= own_addr then return nil end
    local applied = math.max(1.0, math.min(2.5, multiplier))
    st.collider_scale_hits = (tonumber(st.collider_scale_hits) or 0) + 1
    st.collider_scale_requested = multiplier
    st.collider_scale_applied = applied
    S.route3_drake_collider_scale_status = string.format(
        "native scale hook %.2fx (%d calls this attack)",
        applied, tonumber(st.collider_scale_hits) or 0)
    return applied
end

function iris_mc_install_collider_scale()
    rawset(_G, "__iris_mc_drake_collider_scale_dispatch",
        iris_mc_drake_collider_scale_dispatch)
    if rawget(_G, "IrisMountCombatColliderScale_v1") then return true end
    local installed = false
    pcall(function()
        local td = sdk.find_type_definition("app.HitController")
        local method = td and td:get_method("getColliderScale(System.UInt32,System.UInt32)")
        if not method then return end
        sdk.hook(method, function(args)
            local multiplier = nil
            local dispatch = rawget(_G, "__iris_mc_drake_collider_scale_dispatch")
            if dispatch then pcall(function() multiplier = dispatch(args) end) end
            thread.get_hook_storage().iris_mc_drake_collider_multiplier = multiplier
            return sdk.PreHookResult.CALL_ORIGINAL
        end, function(retval)
            local storage = thread.get_hook_storage()
            local multiplier = storage.iris_mc_drake_collider_multiplier
            storage.iris_mc_drake_collider_multiplier = nil
            if multiplier then
                local base = sdk.to_float(retval)
                if base and base > 0.0 then return sdk.float_to_ptr(base * multiplier) end
            end
            return retval
        end)
        installed = true
    end)
    if installed then rawset(_G, "IrisMountCombatColliderScale_v1", true) end
    return installed or rawget(_G, "IrisMountCombatColliderScale_v1") == true
end

-- ⭐ THE DISCOVERY INSTRUMENT. We do not KNOW ch253/ch257's authored collider
-- request ids the way we eventually knew the wolf's 50 -- and we never guess.
-- Manual capture records wild attacks; a live Drake attack lease enables the
-- same narrow recorder automatically so Aurora's mounted test supplies its own proof.
function iris_mc_install_reqid_capture()
    -- ⛔⛔ THE DISPATCH IS REFRESHED BEFORE THE GUARD RETURNS, ALWAYS. The hook itself survives a
    -- script reload (installs die only with the process) and the _G guard stops it stacking --
    -- but the guard would also pin the OLD body if the rawset sat behind it. Indirecting through
    -- _G is what lets an edit here actually take effect on reload.
    rawset(_G, "__iris_mc_reqid_dispatch", function(args)
        pcall(function()
            if C.route3_combat_reqid_capture ~= true
                and type(S.route3_drake_attack) ~= "table"
                and (tonumber(S.route3_drake_req_capture_until) or 0.0) <= os.clock() then return end
            local hc = sdk.to_managed_object(args[2])
            if not hc then return end
            local chara = nil
            pcall(function() chara = hc:get_field("<CachedCharacter>k__BackingField") end)
            local id = ""
            pcall(function() id = tostring(chara and chara:call("get_CharaIDString") or "") end)
            local species = id:match("^(ch25[37])")
            if not species then return end
            local tracks = nil
            pcall(function() tracks = sdk.to_managed_object(args[3]) end)
            if not tracks then return end
            local ids, parts = {}, {}
            for _, name in ipairs({ "ReqId1", "ReqId2", "ReqId3", "ReqId4",
                "ReqId5", "ReqId6", "DamageReqId", "AtkDetectReqId" }) do
                local v = nil
                pcall(function() v = tonumber(tracks:get_field(name)) end)
                if v and v ~= -1 then
                    ids[name] = v
                    parts[#parts + 1] = name .. "=" .. tostring(v)
                end
            end
            -- requestSeqCollider is called every frame; an all--1 snapshot would
            -- evict the one useful attack frame before Aurora could read it.
            if #parts == 0 then return end
            local clip = nil
            pcall(function() clip = route3_flap_layer_clip() end)
            local sig = table.concat(parts, "|") .. "@" .. tostring(clip)
            S.route3_combat_reqid_seen = type(S.route3_combat_reqid_seen) == "table"
                and S.route3_combat_reqid_seen or {}
            if S.route3_combat_reqid_seen[sig] then return end
            S.route3_combat_reqid_seen[sig] = true
            S.route3_combat_reqid_rows = type(S.route3_combat_reqid_rows) == "table"
                and S.route3_combat_reqid_rows or {}
            local rows = S.route3_combat_reqid_rows
            rows[#rows + 1] = { clip = clip, ids = ids, text = sig }
            while #rows > 40 do table.remove(rows, 1) end
            pcall(function() json.dump_file(MOD .. "_" .. species .. "_reqids.json", rows) end)
            log.info("[IrisMountCombat] " .. species .. " collider request: " .. sig)
        end)
    end)
    if rawget(_G, "IrisMountCombatReqCapture_v1") then return true end
    pcall(function()
        local td = sdk.find_type_definition("app.HitController")
        local m = td and td:get_method("requestSeqCollider(app.ColliderReqTracks)")
        if not m then return end
        sdk.hook(m, function(args)
            local d = rawget(_G, "__iris_mc_reqid_dispatch")
            if d then d(args) end
        end, function(r) return r end)
        rawset(_G, "IrisMountCombatReqCapture_v1", true)
    end)
    return rawget(_G, "IrisMountCombatReqCapture_v1") == true
end

-- ============================================================================
--  THE OUTGOING DAMAGE HOOK -- detector, amplifier and party shield in one.
--
--  ⛔⛔ GUARD NAME IS A VERSION NUMBER, NOT A NAME.  sdk.hook installs PERSIST
--  across script reloads (they die only with the process) and this _G flag stops
--  them stacking -- but it also PINS THE OLD CLOSURE.  Editing the body below
--  without bumping the version changes nothing at all in a reloaded session, and
--  you will test code that no longer exists.  This closure therefore reads only
--  _G and the ctx-held C/S tables (whose identity is stable by design), never a
--  captured local that could belong to an abandoned chunk.
--
--  args[2] = receiving HitController, args[3] = DamageInfo,
--  args[4] = the AUTHORITATIVE HP subtraction.  ⛔ DamageInfo.Damage is only the
--  REACTION input; writing it alone changes the flinch and nothing about HP.
-- ============================================================================

function iris_mc_attacker_go(di)
    -- The ladder is IrisTaming's, verbatim, via downed.lua -- field-proven in
    -- this game.  ⚠ These are auto-property BACKING FIELDS and do NOT appear in
    -- DamageInfo:get_fields(); the dump's silence is not evidence of absence.
    if not di then return nil end
    local ago = nil
    pcall(function() ago = di:get_field("<AttackOwnerObject>k__BackingField") end)
    -- Shell payloads frequently put the detached shell/VFX GameObject in
    -- AttackOwnerObject. Its transform is not a child of ch257, but CachedShell
    -- still retains the authoritative owner character. Prefer that owner when
    -- it exists so Drake magic is recognised as hers and cannot hit her body.
    pcall(function()
        local ahc = di:get_field("<AttackHitController>k__BackingField")
        local shell = ahc and ahc:get_field("<CachedShell>k__BackingField")
        local owner = shell and shell:get_field("<OwnerCharacter>k__BackingField")
        local owner_go = owner and owner:call("get_GameObject")
        if owner_go then ago = owner_go end
    end)
    if not ago then
        pcall(function()
            local ahc = di:get_field("<AttackHitController>k__BackingField")
            local ach = ahc and ahc:get_field("<CachedCharacter>k__BackingField")
            ago = ach and ach:call("get_GameObject")
        end)
    end
    if not ago then
        pcall(function() ago = di:get_field("<AttackGameObject>k__BackingField") end)
    end
    return ago
end

function iris_mc_install_damage_hook()
    -- ⛔⛔ Same law as above: refresh the dispatch BEFORE the guard can return, or an edit to the
    -- shield/amplifier below is a silent no-op in every reloaded session and you will spend an
    -- evening testing a closure that no longer exists.
    rawset(_G, "__iris_mc_damage_dispatch", function(args)
        -- ⛔ HOT PATH: this fires for EVERY damage event in the game. The cheapest possible
        -- discriminator goes first -- route3_combat_self_addr is nil whenever she is not being
        -- ridden, so outside mounted play the hook costs one table index and a return.
        -- ⛔ package.loaded, not require(): the module table's IDENTITY is stable across reloads
        -- by design (context.lua refills C and S in place), so this reads the LIVE config even
        -- from a closure pinned by an earlier load.
        local m = package.loaded["IrisGriffin.context"]
        if not m then return end
        local Cc, Ss = m.C, m.S
        local self_addr = tonumber(Ss.route3_combat_self_addr)
        if not self_addr then return end
        if Cc.route3_combat_enabled == false then return end
        local di = nil
        pcall(function() di = sdk.to_managed_object(args[3]) end)
        if not di then return end
        local ago = iris_mc_attacker_go(di)
        local aaddr = nil
        pcall(function() aaddr = ago and ago:get_address() end)
        local vgo, vaddr = nil, nil
        pcall(function()
            local hc = sdk.to_managed_object(args[2])
            vgo = hc and hc:call("get_GameObject")
            vaddr = vgo and vgo:get_address()
        end)
        -- Fire shells may report the shell child rather than ch257 itself as AttackOwnerObject.
        -- Treat a descendant of the live mount transform as hers, but nothing else.
        local attacker_owned = aaddr == self_addr
        if not attacker_owned and ago and tonumber(Ss.route3_combat_self_tf_addr) then
            pcall(function()
                local tf = ago:call("get_Transform")
                for _ = 1, 12 do
                    if not tf then break end
                    if tf:get_address() == tonumber(Ss.route3_combat_self_tf_addr) then
                        attacker_owned = true
                        break
                    end
                    tf = tf:call("get_Parent")
                end
            end)
        end
        if not attacker_owned then return end
        local victim_owned = vaddr == self_addr
        if not victim_owned and vgo and tonumber(Ss.route3_combat_self_tf_addr) then
            pcall(function()
                local tf = vgo:call("get_Transform")
                for _ = 1, 12 do
                    if not tf then break end
                    if tf:get_address() == tonumber(Ss.route3_combat_self_tf_addr) then
                        victim_owned = true
                        break
                    end
                    tf = tf:call("get_Parent")
                end
            end)
        end
        -- A ch257 flame volume can overlap its own enormous body. This is not enemy damage and
        -- never should be amplified: cancel Drake-originated damage received by the root OR any
        -- child body HitController while an attack/charge lease is active.
        if victim_owned and (type(Ss.route3_drake_attack) == "table"
            or Ss.route3_drake_sprint_hit_active == true
            or os.clock() <= (tonumber(Ss.route3_drake_self_guard_until) or 0.0)) then
            pcall(function() args[4] = sdk.float_to_ptr(0.0) end)
            pcall(function()
                di:set_field("Damage", 0.0)
                di:set_field("FixedDamage", 0.0)
            end)
            Ss.route3_drake_self_guard_blocks =
                (tonumber(Ss.route3_drake_self_guard_blocks) or 0) + 1
            Ss.route3_drake_self_guard_status = string.format(
                "blocked own attack volume (%d)", Ss.route3_drake_self_guard_blocks)
            return
        end
        -- The blow is HERS.  Two jobs from here, in this order.
        -- 1) ⛔⛔ PARTY SHIELD.  An authored ch253 volume does not know who is
        -- riding it.  downed.lua owns the incoming half of this problem; this is
        -- the outgoing half, in the same shape, at the same argument.
        if Cc.route3_combat_party_shield ~= false and vaddr then
            local friends = nil
            pcall(function() friends = griffin_friendly_attackers_refresh() end)
            if type(friends) == "table" and friends[vaddr] then
                pcall(function() args[4] = sdk.float_to_ptr(0.0) end)
                pcall(function()
                    di:set_field("Damage", 0.0)
                    di:set_field("FixedDamage", 0.0)
                end)
                Ss.route3_combat_shield_blocks = (tonumber(Ss.route3_combat_shield_blocks) or 0) + 1
                return
            end
        end
        -- 2) ⭐ DETECTOR + AMPLIFIER.  This firing at all is the proof that the
        -- authored clip event transacted natively -- the one signal that tells
        -- the strike resolver not to bill a second time with the radius pulse.
        local amount = 0.0
        pcall(function() amount = tonumber(sdk.to_float(args[4])) or 0.0 end)
        local sprinting = Ss.route3_drake_sprint_hit_active == true
            and type(Ss.route3_drake_attack) ~= "table"
        if sprinting and amount > 0.0 then
            local charge_scale = math.max(0.05, math.min(1.0,
                tonumber(Cc.route3_drake_sprint_damage_scale) or 0.35))
            amount = amount * charge_scale
            pcall(function() args[4] = sdk.float_to_ptr(amount) end)
            Ss.route3_drake_sprint_hit_status = string.format(
                "native charge hit %.0f (x%.2f)", amount, charge_scale)
        end
        -- Furious-Charge is intentionally chip damage. The general authored-hit
        -- amplifier (often 6x) must not multiply it straight back into a boss hit.
        local scale = sprinting and 1.0 or (tonumber(Cc.route3_combat_native_scale) or 1.0)
        if scale > 1.0 and amount > 0.0 then
            pcall(function() args[4] = sdk.float_to_ptr(amount * scale) end)
            Ss.route3_combat_amped_at = os.clock()
        end
        Ss.route3_combat_native_hits = (tonumber(Ss.route3_combat_native_hits) or 0) + 1
        Ss.route3_combat_native_at = os.clock()
        Ss.route3_combat_native_last = string.format("%.0f x%.1f on %s",
            amount, scale, tostring(vgo and go_name(vgo) or "?"))
    end)
    if rawget(_G, "IrisMountCombatDamageHook_v1") then return true end
    pcall(function()
        local td = sdk.find_type_definition("app.HitController")
        local m = td and td:get_method("updateDamageHp")
        if not m then return end
        sdk.hook(m, function(args)
            local d = rawget(_G, "__iris_mc_damage_dispatch")
            if d then pcall(d, args) end
        end, function(r) return r end)
        rawset(_G, "IrisMountCombatDamageHook_v1", true)
    end)
    return rawget(_G, "IrisMountCombatDamageHook_v1") == true
end

-- The post-hit bonus is the wolf's proven lever and the belt to the hook's
-- braces: if a native transaction moved HP but never came through
-- updateDamageHp (the wolf's ch223 hits never did), the scale is applied here
-- from the observed delta instead.  ⛔ Never re-amplify a bonus: the watermark
-- is re-read immediately afterwards.
function iris_mc_apply_bonus(st, native_delta, label)
    local scale = iris_mc_cfg("route3_combat_native_scale", 1.0)
    if scale <= 1.0 or not (native_delta and native_delta > 0.01) then return false end
    -- The hook already did the amplification at source this frame.
    if (os.clock() - (tonumber(S.route3_combat_amped_at) or -999.0)) < 0.5 then return false end
    local ch, go = st.target, st.target_go
    if not go then return false end
    local applied = false
    pcall(function()
        local hc = griffin_target_hit_controller(ch) or get_component(go, "app.HitController")
        if not hc then return end
        local hp = tonumber(griffin_hp_from_component(hc))
        if not (hp and hp > 0.0) then return end
        local want = math.max(0.0, hp - native_delta * (scale - 1.0))
        for _, sig in ipairs({
            "setHp(System.Single, System.Boolean, System.Int32)",
            "setHp(System.Single, System.Boolean)",
            "setHp(System.Single)",
        }) do
            pcall(function() hc:call(sig, want, true, 0) end)
        end
        local rb = tonumber(griffin_hp_from_component(hc)) or hp
        applied = rb < hp - 0.5
        S.route3_combat_bonus = string.format("%s native %.0f + bonus %.0f (x%.1f) hp %.0f -> %.0f",
            tostring(label or "strike"), native_delta, native_delta * (scale - 1.0),
            scale, hp, rb)
    end)
    return applied
end

-- ============================================================================
--  THE KNOCKBACK SHELL
--
--  Aurora, 08-21: "the wolf howl has a great knockback shell which would be
--  great if we can properly time it to the final blow of the griffin wind gust."
--  This is that exact shell -- Puppeteer's Barghest dark-area, cast through
--  Bestiary/ShellHandler.  The ENGINE owns its collision and reaction semantics,
--  which is the whole point: no ragdoll forcing, no AI blackout, no transform
--  arc, no fighting GroundFixer.  Colour is zeroed because the wing animation IS
--  the visual (every shell VFX in the library reads as a spell or an earthquake).
-- ============================================================================

-- ⛔⛔ 08-21 FIELD BUG, AND IT WAS NEVER JUST OURS: `require("Bestiary/ShellHandler")` FAILS on
-- this install. Bestiary's Lua is not live -- the only copy on disk is archived under
-- `data/RiftSpeak/apex enemy variants/reframework/autorun/Bestiary`. So every caller of that path
-- has been silently getting nothing, INCLUDING the wolf's own howl blast
-- (iris_wyrm_cast_real_howl_shell, IrisHorseRodeo:3004) and the drake's breath shell
-- (GriffinRideProbe:19040). Aurora's first field report showed `shell : -` for exactly this.
--
-- ⭐ `SkillCreator/ShellHandler` IS installed, exposes the identical
-- cast_shell(owner, udataPath, shellID, params) API, and its ShellUdatas preloads
-- "AppSystem/ch/ch227/001/userdata/ch227001darkareashellparamdata.user" by name -- the exact
-- Barghest dark-area. Prefer Bestiary when present (it is the original), fall back to SkillCreator.
function iris_mc_shell_handler()
    local cached = rawget(_G, "__iris_mc_shell_handler")
    if cached ~= nil then
        if cached == false then return nil, tostring(S.route3_combat_shell_route or "no shell handler") end
        return cached, tostring(S.route3_combat_shell_route or "cached")
    end
    for _, path in ipairs({ "Bestiary/ShellHandler", "SkillCreator/ShellHandler" }) do
        local h = nil
        pcall(function() h = require(path) end)
        if type(h) == "table" and type(h.cast_shell) == "function" then
            rawset(_G, "__iris_mc_shell_handler", h)
            S.route3_combat_shell_route = path
            log.info("[IrisMountCombat] shell handler: " .. path)
            return h, path
        end
    end
    rawset(_G, "__iris_mc_shell_handler", false)
    S.route3_combat_shell_route = "NONE (neither Bestiary nor SkillCreator ShellHandler loaded)"
    return nil, S.route3_combat_shell_route
end

-- ============================================================================
--  ⭐ STANDALONE SHELL CASTING -- no mod dependency at all.
--
--  Aurora, 08-21: "kinda wanted this mod to work on its own but it sounds like it needs Bestiary
--  support?" It does not. I read SkillCreator's handler and the ENTIRE cast is eight lines of
--  plain REFramework SDK:
--
--      udata  = sdk.create_userdata("app.ShellParamData", <path>)
--      req    = sdk.create_instance("app.ShellRequest.ShellCreateInfo"):add_ref()
--      req.ShellParamIdHash = udata.ShellParams._items[id]._ShellParamIdHash
--      app.ShellManager.requestCreateShell(gameobject, pos, rot, req, udata, nil, nil)
--
--  Everything else in those mods -- the size/gravity param mutation, the colour and lifetime
--  hooks -- is optional polish layered on top. So IRIS casts the shell itself and depends on
--  nobody. A handler is still USED when one is installed, because its colour hook can zero the
--  Barghest dome's VFX (the wing animation is meant to be the visual); without one the knockback
--  is identical but the dome is VISIBLE. Bestiary is preferred over SkillCreator when both exist.
--
--  ⛔ The udata is created ONCE and add_ref'd. Creating one per cast would churn managed memory
--  on a move that can fire several times a fight.
-- ============================================================================

function iris_mc_shell_udata(path)
    local cache = rawget(_G, "__iris_mc_shell_udatas")
    if type(cache) ~= "table" then cache = {}; rawset(_G, "__iris_mc_shell_udatas", cache) end
    local hit = cache[path]
    if hit ~= nil then return hit or nil end
    local u = nil
    pcall(function() u = sdk.create_userdata("app.ShellParamData", path) end)
    if u then pcall(function() u:add_ref() end) end
    cache[path] = u or false
    return u
end

-- Size and lifetime live on the AUTHORED param block, which is shared by every user of that
-- shell -- so it is modified for the cast and put back a moment later. SkillCreator does exactly
-- this with a 0.1s timer; ours restores from iris_mc_tick so we owe nothing to _NickCore.
-- ⛔ Snapshot PRIMITIVES, never a cloned managed object held across frames (the wrapper UAF law).
function iris_mc_shell_apply_base(udata, shell_id, size, lifetime)
    local snap = nil
    pcall(function()
        local base = udata.ShellParams._items[shell_id]._ShellParameterBase.ShellBaseParam
        if not base then return end
        local sc = base.Scale
        snap = {
            path_id = shell_id,
            UseScale = base.UseScale, UseLifeTime = base.UseLifeTime,
            UseOmenPhase = base.UseOmenPhase,
            sx = sc and tonumber(sc.x) or 1.0,
            sy = sc and tonumber(sc.y) or 1.0,
            sz = sc and tonumber(sc.z) or 1.0,
            LifeTime = base.LifeTime, OmenTime = base.OmenTime,
        }
        if size then
            base.UseScale = true
            base.Scale = Vector3f.new(size, size, size)
        end
        if lifetime then
            base.UseLifeTime = lifetime >= 0
            base.LifeTime = lifetime
        end
        base.UseOmenPhase = false
        base.OmenTime = 0.0
        -- Written BACK deliberately: ShellBaseParam reads as a value block, and the reference
        -- handler does the same round-trip rather than trusting an in-place edit.
        udata.ShellParams._items[shell_id]._ShellParameterBase.ShellBaseParam = base
    end)
    return snap
end

function iris_mc_shell_restore_base(udata, snap)
    if not (udata and type(snap) == "table") then return end
    pcall(function()
        local id = snap.path_id or 0
        local base = udata.ShellParams._items[id]._ShellParameterBase.ShellBaseParam
        if not base then return end
        base.UseScale = snap.UseScale
        base.Scale = Vector3f.new(snap.sx, snap.sy, snap.sz)
        base.UseLifeTime = snap.UseLifeTime
        base.LifeTime = snap.LifeTime
        base.UseOmenPhase = snap.UseOmenPhase
        base.OmenTime = snap.OmenTime
        udata.ShellParams._items[id]._ShellParameterBase.ShellBaseParam = base
    end)
end

function iris_mc_shell_cast_native(owner_ch, path, shell_id, pos, rot, size, lifetime)
    local udata = iris_mc_shell_udata(path)
    if not udata then return nil, "create_userdata failed for " .. tostring(path) end
    local sm = sdk.get_managed_singleton("app.ShellManager")
    local method = nil
    pcall(function()
        method = sdk.find_type_definition("app.ShellManager"):get_method(
            "requestCreateShell(via.GameObject, via.vec3, via.Quaternion, "
            .. "app.ShellRequest.ShellCreateInfo, app.ShellParamData, "
            .. "app.ShellRequest.EventCreateShellSuccess, "
            .. "app.ShellRequest.EventBeforeShellInstantiate)")
    end)
    if not (sm and method) then return nil, "app.ShellManager.requestCreateShell missing" end
    -- ⛔⛔ TWO CASTS INSIDE THE RESTORE WINDOW WOULD MAKE THE CHANGE PERMANENT. The gust finale
    -- and the combo finisher can both fire within 0.2s; the second snapshot would capture the
    -- ALREADY-MODIFIED values, and restoring those writes our size into the authored shell for
    -- the rest of the session. Keep the FIRST snapshot -- it holds the true originals -- and only
    -- push the deadline out.
    local pending = S.route3_combat_shell_restore
    local snap = iris_mc_shell_apply_base(udata, shell_id, size, lifetime)
    if type(pending) == "table" and pending.udata == udata and type(pending.snap) == "table" then
        snap = pending.snap
    end
    -- Queued whatever happens below, so a failed cast cannot leave the shell resized either.
    S.route3_combat_shell_restore = { udata = udata, snap = snap, at = os.clock() + 0.20 }
    local req, rid = nil, nil
    local ok, err = pcall(function()
        req = sdk.create_instance("app.ShellRequest.ShellCreateInfo"):add_ref()
        req.ShellParamIdHash = udata.ShellParams._items[shell_id]._ShellParamIdHash
        rid = method:call(sm, owner_ch:call("get_GameObject"), pos, rot, req, udata, nil, nil)
    end)
    if not ok then return nil, tostring(err) end
    if rid == nil then return nil, "no requestID" end
    S.route3_combat_shell_route = "standalone (app.ShellManager.requestCreateShell)"
    return rid, "native"
end

function iris_mc_cast_knock_shell(centre_go, opts)
    opts = opts or {}
    local ch, go = reacquire_griffin()
    local at_go = centre_go or go
    -- ⛔ EVERY EXIT REPORTS. The first version returned early on three paths without touching
    -- S.route3_combat_shell, so a missing handler read as "the finale never fired" in the panel
    -- and cost a field run to diagnose. A silent early return is not a diagnostic.
    if not (ch and at_go) then
        S.route3_combat_shell = "no body"; return false, S.route3_combat_shell
    end
    local tf = nil
    pcall(function() tf = at_go:call("get_Transform") end)
    if not tf then
        S.route3_combat_shell = "no transform"; return false, S.route3_combat_shell
    end
    local path = tostring(C.route3_gust_shell_path
        or "AppSystem/ch/ch227/001/userdata/ch227001darkareashellparamdata.user")
    local size = math.max(0.5, tonumber(opts.size) or iris_mc_cfg("route3_gust_shell_size", 6.0))
    local life = math.max(0.1, tonumber(opts.lifetime)
        or iris_mc_cfg("route3_gust_shell_lifetime", 0.5))
    local pos, rot = tf:call("get_Position"), tf:call("get_Rotation")
    -- 0 = auto (use an installed handler when there is one, because only it can hide the dome's
    -- VFX; otherwise cast it ourselves), 1 = force our own standalone cast, 2 = force the handler.
    local mode = math.floor(iris_mc_cfg("route3_gust_shell_route", 0))
    local handler, hroute = nil, "none"
    if mode ~= 1 then handler, hroute = iris_mc_shell_handler() end

    if handler then
        local shared = nil
        local ok, err = pcall(function()
            shared = handler.cast_shell(ch, path, 0, {
                position = pos, rotation = rot, size = size,
                omentime = 0.0, lifetime = life,
                -- Zeroed on purpose: the wing animation IS the visual. Every shell in the library
                -- reads as a spell or an earthquake, which is not what a gale looks like.
                colorParams = { color = { 0, 0, 0, 0 }, externColor = { 0, 0, 0, 0 } },
                delay = math.max(0.0, tonumber(opts.delay)
                    or iris_mc_cfg("route3_gust_shell_delay", 0.0)),
            })
        end)
        if ok and shared ~= nil and shared.requestID ~= nil then
            S.route3_combat_shell = string.format("cast via %s (req %s, hidden VFX)",
                tostring(hroute), tostring(shared.requestID))
            return true, S.route3_combat_shell
        end
        if mode == 2 then
            S.route3_combat_shell = string.format("FAILED via %s: %s", tostring(hroute),
                ok and "no requestID" or tostring(err))
            log.info("[IrisMountCombat] knock shell " .. S.route3_combat_shell)
            return false, S.route3_combat_shell
        end
        S.route3_combat_shell_note = "handler cast failed; falling through to the standalone cast"
    end

    local rid, why = iris_mc_shell_cast_native(ch, path, 0, pos, rot, size, life)
    if rid ~= nil then
        S.route3_combat_shell = string.format("cast STANDALONE (req %s, VFX visible)", tostring(rid))
        return true, S.route3_combat_shell
    end
    S.route3_combat_shell = "FAILED (standalone): " .. tostring(why)
    log.info("[IrisMountCombat] knock shell " .. S.route3_combat_shell)
    return false, S.route3_combat_shell
end

-- ============================================================================
--  GUST WING-BEAT FRAME DATA
--
--  Aurora: "for the windgust we'll need frame data for when the actual wings
--  flap for the very last hit".  We cannot read that out of the atlas -- ⛔ its
--  endframe is ALWAYS 0 -- and guessing it is exactly the kind of number that
--  quietly drifts wrong.  So MEASURE it: sample the wing joint's height relative
--  to her root every frame of clip 202, record each down-beat trough, and at the
--  end of the clip write the LAST trough into route3_gust_finale_frame.
--
--  One field pass calibrates it permanently; the panel prints every beat it saw
--  so the number can be sanity-checked rather than trusted blindly.  Until the
--  first pass lands, the configured/legacy frame is used, so nothing regresses.
-- ============================================================================

function iris_mc_wing_height(go, gp)
    local names = tostring(C.route3_gust_flap_joints or "L_Wing_Upper,R_Wing_Upper")
    local sum, n = 0.0, 0
    for raw in names:gmatch("[^,%s]+") do
        local p = nil
        pcall(function() p = griffin_predation_joint_world_position(go, gp, raw) end)
        if p and tonumber(p.y) then
            sum = sum + (tonumber(p.y) - (tonumber(gp.y) or 0.0))
            n = n + 1
        end
    end
    if n == 0 then return nil end
    return sum / n
end

function iris_mc_gust_flap_sample(st, frame)
    if C.route3_gust_flap_autocal == false then return end
    if not (st and tonumber(frame)) then return end
    local _, go = reacquire_griffin()
    local gp = go and transform_pos(go)
    if not gp then return end
    local h = iris_mc_wing_height(go, gp)
    if not h then return end
    st.beat = type(st.beat) == "table" and st.beat or
        { list = {}, last_h = h, rising = false, peak = h, trough = h, trough_f = frame }
    local b = st.beat
    local min_drop = math.max(0.005, iris_mc_cfg("route3_gust_flap_min_drop", 0.05))
    if h > (b.last_h or h) then
        -- upstroke: if we were descending, the previous sample was a trough
        if b.falling == true and (b.peak - b.trough) >= min_drop then
            b.list[#b.list + 1] = math.floor(b.trough_f + 0.5)
            while #b.list > 24 do table.remove(b.list, 1) end
        end
        b.falling = false
        b.peak = math.max(b.peak or h, h)
    elseif h < (b.last_h or h) then
        if b.falling ~= true then
            b.falling = true
            b.peak = b.last_h or h
            b.trough = h
            b.trough_f = frame
        elseif h < (b.trough or h) then
            b.trough = h
            b.trough_f = frame
        end
    end
    b.last_h = h
end

-- The measured beat list, persisted as a string so the FIRST gust of a session already knows
-- where the wings beat instead of falling back to a legacy constant.
function iris_mc_gust_beat_list()
    local out = {}
    for raw in tostring(C.route3_gust_beat_frames or ""):gmatch("[^,%s]+") do
        local n = tonumber(raw)
        if n and n > 0 then out[#out + 1] = n end
    end
    return out
end

-- ⭐ 08-21 r2. The measurement said clip 202 holds FIVE beats (f36 f97 f152 f246 f326 of 347) and
-- Aurora's verdict on using the last one was that the move takes too long to get out of. So the
-- knock is now attached to a CHOSEN beat, counted back from the end: 1 = the true final flap
-- (most faithful, slowest), 2 = the one before it, and so on. It is still a real wing beat either
-- way -- what changed is which one, not a made-up number.
function iris_mc_gust_finale_frame()
    local list = iris_mc_gust_beat_list()
    if #list > 0 then
        local idx = math.max(1, math.floor(iris_mc_cfg("route3_gust_finale_beat", 1)))
        local pick = list[math.max(1, #list - idx + 1)]
        if pick then return pick end
    end
    return math.max(1.0, iris_mc_cfg("route3_gust_finale_frame", 90.0))
end

-- ⛔ play_griffin_motion re-asserts PlaySpeed 1.0 on EVERY paint, and the gust re-asserts its clip
-- whenever the native FSM stomps it -- so a speed set once at the phase change is undone the
-- first time that happens. It has to be re-applied on the tick that owns the phase.
function iris_mc_set_motion_speed(v)
    local ok = false
    pcall(function()
        local ch = reacquire_griffin()
        local motion = ch and ch:call("get_Motion")
        if motion then motion:call("set_PlaySpeed", math.max(0.1, tonumber(v) or 1.0)); ok = true end
    end)
    return ok
end

function iris_mc_gust_flap_commit(st)
    -- Called when clip 202 retires.  A descent still in progress at the very end
    -- of the clip IS the final beat -- the wings do not come back up.
    if C.route3_gust_flap_autocal == false then return end
    local b = st and st.beat
    if not (type(b) == "table") then return end
    if b.falling == true and (b.peak - b.trough) >= math.max(0.005,
        iris_mc_cfg("route3_gust_flap_min_drop", 0.05)) then
        b.list[#b.list + 1] = math.floor((b.trough_f or 0) + 0.5)
    end
    if #b.list == 0 then
        S.route3_gust_flap_report = "no wing beat measured (joint unreadable?)"
        return
    end
    local parts, csv = {}, {}
    for _, f in ipairs(b.list) do
        parts[#parts + 1] = "f" .. tostring(f)
        csv[#csv + 1] = tostring(f)
    end
    local idx = math.max(1, math.floor(iris_mc_cfg("route3_gust_finale_beat", 1)))
    local pick = b.list[math.max(1, #b.list - idx + 1)] or b.list[#b.list]
    S.route3_gust_flap_report = string.format(
        "clip %s beats: %s  (%d beats, end=%s, using #%d from the end = f%d)",
        tostring(st.cur_clip), table.concat(parts, " "), #b.list,
        tostring(st.end_frame), idx, pick)
    log.info("[IrisMountCombat] gust " .. S.route3_gust_flap_report)
    -- ⛔ ANCHOR TO A DATUM YOU NEVER WRITE: the beats are compared against the CONFIGURED number,
    -- never against the previous measurement, so a slow drift can never ratchet the finale out of
    -- the clip. The whole list is persisted, not just the pick, so changing route3_gust_finale_beat
    -- takes effect on the very NEXT gust rather than needing a re-measurement first.
    local list_csv = table.concat(csv, ",")
    local cur = tonumber(C.route3_gust_finale_frame) or 90.0
    if list_csv ~= tostring(C.route3_gust_beat_frames or "")
        or math.abs(cur - pick) > 1.0 then
        C.route3_gust_beat_frames = list_csv
        C.route3_gust_finale_frame = pick + 0.0
        S.route3_gust_flap_report = S.route3_gust_flap_report
            .. string.format("  -> pinned finale %.0f -> %d", cur, pick)
        pcall(save_config)
    end
end

-- The gust's finale, rebuilt.  Mode 0 keeps the legacy scripted fling exactly as
-- it was (ragdoll + AI blackout + ballistic arc), 1 is the native shell alone,
-- 2 casts both.  Default is 1: the engine's own knockback reads better and does
-- not have to fight GroundFixer, the CharacterController or the victim's AI.
function iris_mc_gust_finale(radius)
    local mode = math.floor(iris_mc_cfg("route3_gust_blow_mode", 1))
    local did = false
    if mode == 1 or mode == 2 then
        local ok = iris_mc_cast_knock_shell(nil, {
            size = iris_mc_cfg("route3_gust_shell_size", 6.0),
        })
        did = did or ok
    end
    if mode == 0 or mode == 2 then
        pcall(function() route3_gust_finale_blow(radius) end)
        did = true
    end
    return did
end

-- ============================================================================
--  THE GROUND-ATTACK COMBO
--
--  Aurora: "natural comboing in the basic ground attack ... the idea is for it
--  to feel native and like a flowing combo just like the wolf bite combo."
--
--  Shape, straight from iris_wyrm_native_combo_advance: a press during the live
--  window BUFFERS the next link; the link fires at the authored cancel frame, so
--  the chain flows out of the previous animation instead of restarting after it.
--  Every link REACQUIRES and re-aims -- blind animation lunges overshoot short
--  enemies and make the camera show a hit that happened behind the beak.
-- ============================================================================

function iris_mc_combo_active() return type(S.route3_combat_combo) == "table" end

function iris_mc_read_attack_button()
    -- Mirrors route3_gatk_tick's binding exactly so the two readers can never
    -- disagree about what "the attack button" is.
    local down = false
    local names = tostring(C.route3_gatk_buttons or ""):gsub("%s+", "")
    if names == "" then names = "north,triangle" end
    pcall(function() down = raw_gamepad_button_down(names) end)
    if not down then down = iris_mc_kb(C.route3_gatk_key) end
    -- ⛔⛔ MENUS OWN THE PAD: swallow everything while a pausing GUI or the
    -- overlay is up, and remember the held state, so releasing the map with the
    -- button still down cannot edge-fire an attack on the unpause frame.
    if type(iris_input_blocked) == "function" and iris_input_blocked() then
        S.route3_combat_btn = down == true
        return false, false
    end
    local pressed = down == true and S.route3_combat_btn ~= true
    S.route3_combat_btn = down == true
    return down == true, pressed
end

function iris_mc_combo_paint(st, link, now)
    local bank = st.bank
    local clip = iris_mc_link_clip(link)
    st.link_def = link
    st.clip = clip
    -- route3_gatk_contact_effects reads st.name / st.hit_total / st.t0 off whatever state table
    -- it is handed, so a link must present the same shape the legacy attack did.
    st.name = link.label
    st.hit = {}
    st.hit_total = 0
    st.sound_done = nil
    st.lunged = nil
    st.t0 = now
    st.paint_at = now
    st.resolved = nil
    st.fallback_at = nil
    st.tail = nil
    st.buffered = nil
    st.frames = nil
    st.hit_native = nil
    st.reqid_sent = nil
    S.route3_combat_native_hits = 0
    -- Reacquire before every link.  The victim of link 1 can be flung behind her
    -- by the time link 2 opens.
    local spec = {
        joints = link.joints,
        aim_deg = iris_mc_cfg("route3_combat_aim_deg", 180.0),
    }
    local t, tgo = iris_mc_acquire(spec)
    if t and tgo then
        st.target, st.target_go = t, tgo
        st.hp0 = iris_mc_target_hp(t, tgo)
        iris_mc_aim_begin(st, tgo, iris_mc_cfg("route3_combat_aim_secs", 0.12))
    else
        st.target, st.target_go, st.hp0 = nil, nil, nil
    end
    -- ⭐ REARM BEFORE THE CLIP, not at the impact frame.  The authored event may
    -- request its collider well before our configured hit frame; an unarmed
    -- HitController at that moment is a silent miss with no receipt.
    local _, go = reacquire_griffin()
    if C.route3_combat_native_hitbox ~= false then iris_mc_rearm(go, link.label) end
    S.base_owner = { name = "gatk", until_clock = now + 0.6 }
    S.audition_until_clock = now + 0.6
    pcall(function() play_griffin_motion(clip, bank, true, "gatk") end)
    S.route3_combat_status = string.format("%s (link %d/%d)",
        tostring(link.label), st.index, st.count)
end

function iris_mc_combo_start(now)
    if C.route3_combat_enabled == false then return false end
    if C.route3_combat_combo_enabled == false then return false end
    if iris_mc_combo_active() then return false end
    -- ⛔⛔ NODE LOCKOUT SITS ABOVE THE BASE-OWNER GATE. While a real FSM node owns her body,
    -- play_griffin_motion refuses every paint but "rise" -- a combo started here would be a
    -- chain of silently-refused clips, and worse, painting over a body whose root motion a node
    -- still owns is the two-owners access violation that crashed hold-B-mid-animation.
    local locked = false
    pcall(function() locked = griffin_node_lockout_active() == true end)
    if locked then
        S.route3_combat_status = "refused: a native node owns her body"
        return false
    end
    local set = iris_mc_moveset()
    if not (set and set.links and #set.links > 0) then return false end
    if type(route3_combat_stamina_spend) == "function"
        and route3_combat_stamina_spend(nil, "Melee Combo") ~= true then
        S.route3_combat_status = "combo refused: not enough combat stamina"
        return false
    end
    local st = {
        bank = math.floor(tonumber(set.bank) or 50),
        index = 1, count = #set.links, set = set,
        started = now,
    }
    S.route3_combat_combo = st
    iris_mc_combo_paint(st, set.links[1], now)
    return true
end

function iris_mc_combo_finish(reason)
    local st = S.route3_combat_combo
    S.route3_combat_combo = nil
    S.route3_combat_target_cache = nil
    if not st then return end
    S.base_owner = nil               -- release the base layer BEFORE the successor paint
    S.audition_until_clock = 0.0
    -- Cooldown is measured from the START of the chain, so a completed combo is
    -- immediately responsive.
    S.route3_gatk_cd_at = tonumber(st.started) or os.clock()
    iris_mc_camera_release()
    if S.mounted == true then pcall(function() route3_flap_after_action() end) end
    S.route3_combat_status = "combo end: " .. tostring(reason or "done")
end

function iris_mc_strike_centre(st, link, go, gp)
    local yaw = yaw_from_transform(go) or S.heading_yaw or 0.0
    local forward = iris_mc_cfg(link.forward_key, 2.5)
    local centre = make_position(
        (tonumber(gp.x) or 0.0) + math.sin(yaw) * forward,
        tonumber(gp.y) or 0.0,
        (tonumber(gp.z) or 0.0) + math.cos(yaw) * forward)
    local joint = iris_mc_strike_origin(go, gp, link.joints)
    if joint and joint ~= gp then centre = joint end
    -- ⭐ AIM ASSIST, NOT AUTO-WALK.  Rather than driving her body at the victim
    -- mid-attack (four transform writers already contend for that body, and the
    -- pounce work paid for that lesson in crashes), the strike VOLUME reaches: a
    -- near-miss inside lunge_max slides its centre onto the target so the swing
    -- connects where the animation visibly points.
    local tgo = st.target_go
    local tp = tgo and transform_pos(tgo)
    local radius = iris_mc_cfg(link.radius_key, 2.5)
    local lunge = math.max(0.0, iris_mc_cfg("route3_combat_lunge_max", 2.5))
    if tp and lunge > 0.0 then
        local dx = (tonumber(tp.x) or 0.0) - (tonumber(centre.x) or 0.0)
        local dz = (tonumber(tp.z) or 0.0) - (tonumber(centre.z) or 0.0)
        local d = math.sqrt(dx * dx + dz * dz)
        if d > radius and d <= radius + lunge and d > 0.01 then
            local slide = math.min(lunge, d - radius * 0.6)
            centre = make_position((tonumber(centre.x) or 0.0) + dx / d * slide,
                tonumber(centre.y) or 0.0,
                (tonumber(centre.z) or 0.0) + dz / d * slide)
            st.lunged = slide
        end
    end
    return centre, radius
end

function iris_mc_combo_resolve(st, link, now, native_only)
    -- ⛔ ONE DAMAGE OWNER.  If the authored volume transacted, the radius pulse
    -- must not bill the same swing again.
    local ch, go = reacquire_griffin()
    local gp = go and transform_pos(go)
    if not gp then st.resolved = true; return end
    local native = (tonumber(S.route3_combat_native_hits) or 0) > 0
    if not native and st.target and st.hp0 then
        local hp = iris_mc_target_hp(st.target, st.target_go)
        if hp and hp < st.hp0 - 0.01 then
            native = true
            iris_mc_apply_bonus(st, st.hp0 - hp, link.label)
        end
    end
    if native then
        st.resolved = true
        st.hit_native = true
        S.route3_combat_receipt = string.format("%s: NATIVE (%s)",
            tostring(link.label), tostring(S.route3_combat_native_last or "hit"))
        return
    end
    if native_only then return end   -- still inside the grace window; wait
    st.resolved = true
    if C.route3_combat_fallback_pulse == false then
        S.route3_combat_receipt = tostring(link.label) .. ": miss (no native window, pulse off)"
        return
    end
    -- The honest fallback: the proven hand-tuned radius pulse, placed on the
    -- limb that is visibly striking.  It keeps the move from becoming a no-op
    -- regression while the native route is still being proven in the field.
    local centre, radius = iris_mc_strike_centre(st, link, go, gp)
    local fresh = {}
    local dmg = iris_mc_cfg(link.damage_key, 1200.0)
    local hits = 0
    pcall(function()
        hits = route3_ground_aoe_damage(radius, dmg, st.hit or {}, centre, fresh) or 0
    end)
    if hits > 0 then
        pcall(function() route3_gatk_contact_effects(st, fresh, hits, now) end)
        -- Blood the fallback cannot get for free: replay a RESOLVED packet onto
        -- the body.  ⛔ Synthetic packets never paint -- this only works because
        -- the shared blood service holds a real one for that species.
        pcall(function()
            for ench in pairs(fresh) do
                griffin_meal_blood_burst(char_go(ench), go)
                break
            end
        end)
        S.route3_combat_receipt = string.format("%s: fallback pulse (%d)",
            tostring(link.label), hits)
    else
        S.route3_combat_receipt = tostring(link.label) .. ": miss"
    end
end

function iris_mc_combo_tick(now)
    local st = S.route3_combat_combo
    if not st then return end
    if S.mounted ~= true or S.airborne == true then
        iris_mc_combo_finish("dismount/airborne"); return
    end
    local link = st.link_def
    if not link then iris_mc_combo_finish("no link"); return end
    local age = now - (tonumber(st.t0) or now)

    -- Hold the layer and park the flap/idle painters, exactly like the gust.
    S.base_owner = { name = "gatk", until_clock = now + 0.5 }
    S.audition_until_clock = now + 0.3
    iris_mc_aim_tick(st, now)
    -- ⭐ TRACK THE RUNNER: keep the nose on a living victim through the wind-up
    -- and stop at the impact frame -- it cannot make her chase after the swing
    -- has committed.
    if st.target_go and st.resolved ~= true and age <= 0.9 and not st.aim_delta then
        iris_mc_aim_begin(st, st.target_go, 0.10)
    end
    -- ⛔ ONLY TAKE THE CAMERA WHEN THERE IS SOMETHING TO SHOW. Aurora asked for the camera on the
    -- TARGET during an attack; swinging at empty air and having the shot swing with it would be a
    -- camera that fights the player for no benefit.
    if C.route3_combat_cam_enabled ~= false and st.target_go then
        iris_mc_camera_tick(st, st.target_go)
    end

    local clip, frame, endf = iris_mc_layer_sample(st.bank)
    st.live_clip, st.live_frame, st.live_end = clip, frame, endf
    -- NATIVE-STOMP RECOVERY: the gate blocks OUR painters, but the native FSM
    -- does not go through play_griffin_motion.  If the base layer shows a
    -- foreign clip, re-assert (the gust's FACE-reassert pattern).
    local want = st.tail or st.clip
    if want and clip ~= want and age > 0.10
        and (now - (tonumber(st.reassert_at) or 0.0)) > 0.22 then
        st.reassert_at = now
        pcall(function() play_griffin_motion(want, st.bank, true, "gatk") end)
    end

    -- ⛔⛔ NEVER READ A PLAYHEAD -- OR AN ENDFRAME -- THAT BELONGS TO THE PREVIOUS CLIP.
    -- changeMotion does not land on the frame it is called: for a beat or two after a link
    -- advance the layer still shows the OUTGOING animation, whose playhead is typically well past
    -- the incoming link's impact frame (fires link 2's hit instantly, on frame 0 of an animation
    -- that has not started) and whose EndFrame would size the incoming link's fractions wrongly.
    -- So NOTHING is read from the layer until it genuinely shows this link's clip; until then,
    -- elapsed time from the paint carries the move and guarantees it can still end.
    st.synced = (clip == want)
    iris_mc_note_rate(st, frame, now)
    if st.synced then iris_mc_note_endframe(st.bank, want, endf) end
    local hit_f, link_f, end_f = iris_mc_link_frames(link, st.synced and endf or nil)
    if C.route3_combat_native_hitbox ~= false and st.resolved ~= true and not st.tail then
        local _, gob = reacquire_griffin()
        iris_mc_arm_flags(gob)
    end
    local eff = (st.synced and frame) and frame or (age * iris_mc_fps())

    -- Explicit collider request, only if a real ch253 request id has been
    -- discovered and pinned.  ⛔ Never guessed: -1 means "we do not know yet"
    -- and the authored clip event is trusted on its own.
    if st.reqid_sent ~= true and C.route3_combat_native_hitbox ~= false then
        local pre = iris_mc_cfg("route3_gatk_contact_pre_frames", 8.0)
        if eff >= hit_f - pre then
            st.reqid_sent = true
            local rid = iris_mc_cfg(link.reqid_key, -1)
            if rid >= 0 then
                local _, go = reacquire_griffin()
                iris_mc_request_collider(go, rid, link.label)
            end
        end
    end

    -- Resolve.  Native first, and only after the grace does the pulse pay.
    if st.resolved ~= true and eff >= hit_f then
        local post = iris_mc_cfg("route3_gatk_contact_post_frames", 12.0)
        iris_mc_combo_resolve(st, link, now, eff < hit_f + post)
        if st.resolved == true and link.finisher and C.route3_combat_link3_knock ~= false then
            -- ⭐ The finisher gets the same native knockback the gust finale uses.
            pcall(function()
                iris_mc_cast_knock_shell(st.target_go, {
                    size = math.max(1.0, iris_mc_cfg(link.radius_key, 3.0)),
                    lifetime = 0.35,
                })
            end)
        end
    end

    -- Buffer / advance.
    local down, pressed = iris_mc_read_attack_button()
    if pressed and st.index < st.count then
        st.buffered = true
        st.buffer_until = now + math.max(0.2, iris_mc_cfg("route3_gatk_combo_buffer_secs", 0.7))
        S.route3_combat_status = tostring(link.label) .. " -> next link buffered"
    end
    if st.buffered and now > (tonumber(st.buffer_until) or 0.0) then st.buffered = nil end
    if st.buffered and st.index < st.count and eff >= link_f and not st.tail then
        st.index = st.index + 1
        iris_mc_combo_paint(st, st.set.links[st.index], now)
        return
    end

    -- Tail (the authored recovery of the finisher), then end.
    if not st.tail and eff >= end_f then
        local tail = iris_mc_link_tail(link)
        if tail then
            st.tail = tail
            st.tail_until = now + 0.9
            pcall(function() play_griffin_motion(tail, st.bank, false, "gatk") end)
            return
        end
        iris_mc_combo_finish("link complete")
        return
    end
    if st.tail and now >= (tonumber(st.tail_until) or 0.0) then
        iris_mc_combo_finish("recovery complete")
        return
    end
    -- Hard ceiling: no combo may outlive its own animation budget.
    if age > 4.0 then iris_mc_combo_finish("timeout") end
end

-- ============================================================================
--  THE TARGET MARKER
--
--  Aurora, 08-21: "remove the [LOCK] marker on enemies, it's quite ugly ... a
--  thin highlight or something, or just nothing at all."
--
--  Style 1 (default) is four thin corner ticks -- a reticle that reads as "this
--  one" from the corner of your eye and vanishes into the scene when you are not
--  looking for it.  Style 0 is nothing at all.  Style 2 restores the old text
--  for anyone who wants it back.
-- ============================================================================

-- ⭐ 08-21 FIELD (Aurora, on the first version's four floating ticks): "the lockon looks pretty
-- cool but it probably should be a box around the enemy right?" -- yes. A fixed-pixel reticle
-- pinned 2.4m over the root is a marker that happens to be near the enemy; a box derived from the
-- body's own on-screen extent is a marker ON the enemy, and it shrinks with distance for free.
--
-- Project the FEET and the HEAD (root, and root + the authored CharacterController height) and
-- size the bracket from the gap between them.
function iris_mc_target_box(fgo)
    if not fgo then return nil end
    local rp = nil
    pcall(function() rp = transform_render_pos(fgo) end)   -- ⛔ RENDER space: the camera's space
    if not rp then return nil end
    local h = nil
    pcall(function()
        local cc = get_component(fgo, "via.physics.CharacterController")
        h = cc and tonumber(cc:call("get_Height"))
    end)
    h = math.max(0.6, math.min(6.0, tonumber(h) or 1.7))
    local foot, head = nil, nil
    pcall(function()
        local x, y, z = tonumber(rp.x) or 0.0, tonumber(rp.y) or 0.0, tonumber(rp.z) or 0.0
        foot = draw.world_to_screen(Vector3f.new(x, y, z))
        head = draw.world_to_screen(Vector3f.new(x, y + h, z))
    end)
    if not (foot and head) then return nil end
    local fy, hy = tonumber(foot.y) or 0.0, tonumber(head.y) or 0.0
    local cx = ((tonumber(foot.x) or 0.0) + (tonumber(head.x) or 0.0)) * 0.5
    local cy = (fy + hy) * 0.5
    -- Clamps, both ends: a goblin 60m off must still be findable, and an ogre at touching range
    -- must not draw a bracket the size of the screen.
    local half_h = math.max(9.0, math.min(240.0, math.abs(fy - hy) * 0.5))
    local aspect = math.max(0.2, math.min(1.5, iris_mc_cfg("route3_combat_marker_aspect", 0.62)))
    return cx, cy, half_h * aspect, half_h
end

function iris_mc_draw_target_marker(fgo, sx, sy)
    local style = math.floor(iris_mc_cfg("route3_combat_marker_style", 1))
    if style <= 0 then return end
    if style >= 2 then
        pcall(function() iris_hud_text("[ LOCK ]", (tonumber(sx) or 0.0) - 34.0,
            tonumber(sy) or 0.0, 0xFFE05548, 18) end)
        return
    end
    local a = math.max(0, math.min(255, math.floor(iris_mc_cfg("route3_combat_marker_alpha", 140))))
    local rgb = math.floor(iris_mc_cfg("route3_combat_marker_colour", 0x00E8D9B0)) & 0x00FFFFFF
    local col = (a << 24) | rgb
    local cx, cy, hw, hh = iris_mc_target_box(fgo)
    if not cx then
        -- The body could not be projected (off-screen edge, no controller). Fall back to the
        -- caller's point at the configured fixed size rather than drawing nothing.
        local s = math.max(4.0, iris_mc_cfg("route3_combat_marker_size", 14.0))
        cx, cy, hw, hh = tonumber(sx) or 0.0, tonumber(sy) or 0.0, s, s
    end
    -- Corner brackets, not a closed rectangle: a full box reads as a UI element sitting in the
    -- world, four corners read as a reticle finding something.
    local t = math.max(4.0, math.min(28.0, hh * 0.30))
    local tw = math.min(t, hw * 0.85)
    -- ⛔ draw.line only. A filled shape at a target's feet reads as a spell circle, which is
    -- exactly the "looks like a game mechanic" feel we are removing.
    pcall(function()
        for _, q in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
            local x, y = cx + q[1] * hw, cy + q[2] * hh
            draw.line(x, y, x - q[1] * tw, y, col)
            draw.line(x, y, x, y - q[2] * t, col)
        end
    end)
end

-- ============================================================================
--  PRONE FINISHER SUPPORT (the RT eat, extended)
--
--  Aurora: "we have Eat on corpses for RT -- could we bring that in for enemies
--  that are knocked down just like the maul?  If there's a knocked prone enemy,
--  walk up and press RT, it positions them for the eat and does the eat cycle."
--
--  ⛔⛔ THE DOWNED-BODY LIVENESS LAW: get_IsDead reads TRUE on a downed-but-alive
--  body.  A readable HP above the floor VETOES it.  Everything here reads the
--  explicit down flags on app.Character BASE (species-universal) and treats HP as
--  the arbiter of dead-vs-prone.
-- ============================================================================

function iris_mc_down_state(ch)
    if not ch then return nil, "no character" end
    local seen, down = {}, false
    for _, m in ipairs({ "get_IsDown", "get_IsDowned", "get_IsFall", "get_IsUnconscious" }) do
        local v = nil
        pcall(function() v = ch:call(m) end)
        if v ~= nil then
            seen[#seen + 1] = m .. "=" .. tostring(v)
            if v == true then down = true end
        end
    end
    if #seen == 0 then return nil, "no down flags readable" end
    return down, table.concat(seen, " ")
end

-- Is there a knocked-down, still-living hostile close enough in FRONT of her to
-- finish?  Returns character, gameobject, distance.
function iris_mc_find_prone(range)
    if C.route3_ground_eat_prone == false then return nil end
    local ch, go = reacquire_griffin()
    local gp = go and transform_pos(go)
    if not gp then return nil end
    range = math.max(1.0, tonumber(range) or iris_mc_cfg("route3_ground_eat_prone_range", 4.5))
    local yaw = yaw_from_transform(go) or S.heading_yaw or 0.0
    local fx, fz = math.sin(yaw), math.cos(yaw)
    local facing = iris_mc_cfg("route3_ground_eat_prone_facing", 0.15)
    local best, best_go, best_d = nil, nil, range
    local function consider(cch)
        pcall(function()
            if not route3_ground_target_hostile(cch) then return end
            local cgo = char_go(cch)
            if not cgo then return end
            if type(S.route3_eaten) == "table" and S.route3_eaten[cgo:get_address()] then return end
            local hp = iris_mc_target_hp(cch, cgo)
            if not (hp and hp > 0.5) then return end     -- corpses are the other path
            local isdown = iris_mc_down_state(cch)
            if isdown ~= true then return end
            -- boss gate, same authored-controller height the corpse meal uses
            local h = nil
            pcall(function()
                local cc = get_component(cgo, "via.physics.CharacterController")
                h = cc and tonumber(cc:call("get_Height"))
            end)
            if (h or 1.4) > iris_mc_cfg("route3_ground_eat_max_height", 3.2) then return end
            local pos = transform_pos(cgo)
            if not pos then return end
            local dx = (tonumber(pos.x) or 0.0) - (tonumber(gp.x) or 0.0)
            local dz = (tonumber(pos.z) or 0.0) - (tonumber(gp.z) or 0.0)
            local d = math.sqrt(dx * dx + dz * dz)
            if d >= best_d or d < 0.01 then return end
            if (dx / d) * fx + (dz / d) * fz < facing then return end   -- roughly in front
            best, best_go, best_d = cch, cgo, d
        end)
    end
    pcall(function()
        local em = singleton("app.EnemyManager")
        if not em then return end
        for _, getter in ipairs({ "get_EnemyList", "getAllEnemies",
            "get_ActiveEnemyList", "get_EnemyCharacterList" }) do
            local list = nil
            pcall(function() list = em:call(getter) end)
            local n = 0
            pcall(function() n = tonumber(list and list:call("get_Count")) or 0 end)
            if n > 0 then
                for i = 0, n - 1 do
                    local item = nil
                    pcall(function() item = list:call("get_Item", i) end)
                    pcall(function()
                        consider(ctx.iris_real_character and ctx.iris_real_character(item) or item)
                    end)
                end
                return
            end
        end
    end)
    if not best then return nil end
    return best, best_go, best_d
end

-- Hold the prone body still for the whole cycle.  ⛔ The eat's position pin can
-- only own a body whose own brain is not standing it up: the wolf's maul learned
-- this the expensive way (RT during a prey get-up froze it mid-getup).
function iris_mc_prone_hold(st)
    if not (st and st.prone == true and st.target) then return end
    pcall(function() ctx.set_think_stop(st.target, true) end)
end

-- The finisher's kill.
--
-- ⭐ MOST OF THIS ALREADY EXISTS.  griffin_meal_blood_burst kills a LIVING prey
-- itself when the blood paint is refused (the r19 adaptive path) -- which is
-- exactly the living-think-stopped case -- and it carries the r20 ONE-KILL-PER-BODY
-- latch that stopped the engine paying Aurora kill XP five times.  So the normal
-- outcome is that the chomp beats finish the victim and this function only
-- observes it.
--
-- What this adds is the BACKSTOP: a finisher must never let the consume warp a
-- still-living enemy 400m away and 120m under the world.  It waits one full beat
-- so the living body gets its real reaction first (killing at meal start cost us
-- the flinch and the cry), then kills through the same latch so the two paths can
-- never double-bill.
--
-- ⛔ Un-think-stop FIRST or the die loop never runs (the wolf's law).
-- ⛔ killAndSetDieLoop, never setHp-to-0 as the opener -- the engine refuses at 1 HP.
function iris_mc_prone_finish_kill(st, eater_go)
    if not (st and st.prone == true and st.target and st.go) then return false end
    if st.prone_killed == true then return false end
    local hp = iris_mc_target_hp(st.target, st.go)
    if hp ~= nil and hp <= 0.5 then
        st.prone_killed = true                    -- the chomp beats already did it
        S.route3_ground_eat_status = "finisher: prey dead"
        return true
    end
    local grace = (tonumber(C.route3_eat_start_dur) or 3.8) + 1.6
    if (os.clock() - (tonumber(st.t0) or 0.0)) < grace then return false end
    local vaddr = nil
    pcall(function() vaddr = st.go:get_address() end)
    S.route3_meal_killed = type(S.route3_meal_killed) == "table" and S.route3_meal_killed or {}
    if vaddr and S.route3_meal_killed[vaddr] then
        st.prone_killed = true
        return false
    end
    if vaddr then S.route3_meal_killed[vaddr] = true end
    st.prone_killed = true
    pcall(function() ctx.set_think_stop(st.target, false) end)
    pcall(function() griffin_meal_blood_burst(st.go, eater_go) end)
    pcall(function()
        local cry = rawget(_G, "IrisPlayHurtCry")
        if cry then cry(st.go) end
    end)
    local killed = false
    pcall(function() st.target:call("killAndSetDieLoop", nil); killed = true end)
    pcall(function()
        local hc = get_component(st.go, "app.HitController")
        local after = hc and tonumber(griffin_hp_from_component(hc)) or nil
        if after and after > 0.0 then
            hc:call("setHp(System.Single, System.Boolean, System.Int32)", 0.0, true, 0)
        end
    end)
    S.route3_ground_eat_status = killed and "finisher: prey killed" or "finisher: kill FAILED"
    return killed
end

-- ============================================================================
--  THE TICK
-- ============================================================================

function iris_mc_tick()
    local now = os.clock()
    -- ⛔ ABOVE THE ENABLE GATE ON PURPOSE. The shell's size/lifetime block is SHARED with every
    -- other user of that shell, so a pending restore must land even if mount combat is switched
    -- off in the same breath -- otherwise a Barghest's own dark area stays rescaled for the rest
    -- of the session and nothing on screen says why.
    local rs = S.route3_combat_shell_restore
    if type(rs) == "table" and now >= (tonumber(rs.at) or 0.0) then
        S.route3_combat_shell_restore = nil
        pcall(function() iris_mc_shell_restore_base(rs.udata, rs.snap) end)
    end
    if C.route3_combat_enabled == false then
        if iris_mc_combo_active() then iris_mc_combo_finish("disabled") end
        return
    end
    iris_mc_install_damage_hook()
    if C.route3_combat_reqid_capture == true then iris_mc_install_reqid_capture() end
    -- ⭐ The damage hook's ONLY link to "which body is ours" -- refreshed here so
    -- the closure never has to resolve a companion from inside a native hook.
    local _, go = reacquire_griffin()
    S.route3_combat_self_addr = (S.mounted == true and go) and go:get_address() or nil
    if iris_mc_combo_active() then
        iris_mc_combo_tick(now)
    else
        -- Keep the shared edge state honest even when we own nothing, so the
        -- first press after a combo cannot be swallowed or double-read.
        iris_mc_read_attack_button()
    end
end

-- ============================================================================
--  PANEL
-- ============================================================================

-- ⛔ NOT re.on_draw_ui HERE. require() caches this module in package.loaded and a REFramework
-- script reset does not reliably clear that -- so a callback registered from a module chunk can
-- fail to re-register and the panel simply disappears. Every re.* registration in this mod lives
-- in the main script; feature modules only define functions. The main file's own on_draw_ui calls
-- this one.
function iris_mc_draw_panel()
    if not imgui.tree_node("⚔ I.R.I.S. MOUNT COMBAT (shared: griffin + future mounts)##c_mc") then
        return
    end
    local chg
    imgui.text(string.format("status : %s", tostring(S.route3_combat_status or "(idle)")))
    imgui.text(string.format("receipt: %s", tostring(S.route3_combat_receipt or "(none)")))
    imgui.text(string.format("native : hits=%s last=%s  bonus=%s",
        tostring(S.route3_combat_native_hits or 0),
        tostring(S.route3_combat_native_last or "-"),
        tostring(S.route3_combat_bonus or "-")))
    imgui.text(string.format("shield : %s friendly hits blocked",
        tostring(S.route3_combat_shield_blocks or 0)))
    imgui.text(string.format("rearm  : %s   reqid: %s",
        tostring(S.route3_combat_rearm or "-"), tostring(S.route3_combat_reqid_last or "-")))
    imgui.text(string.format("target : %s",
        tostring(S.route3_combat_target_status or "no live target acquired")))
    local st = S.route3_combat_combo
    if st then
        imgui.text_colored(string.format("LIVE link %d/%d clip=%s frame=%s/%s lunge=%s",
            st.index or 0, st.count or 0, tostring(st.live_clip),
            tostring(st.live_frame and math.floor(st.live_frame)), tostring(st.live_end),
            tostring(st.lunged and string.format("%.2fm", st.lunged) or "-")), 0xFF66FF66)
    end
    imgui.separator()

    chg, C.route3_combat_enabled = imgui.checkbox(
        "mount combat enabled##c_mc_on", C.route3_combat_enabled ~= false)
    if chg then save_config() end
    if imgui.tree_node("combat stamina (attacks only)##c_mc_stamina") then
        chg, C.route3_combat_stamina_enabled = imgui.checkbox(
            "use shared mount combat stamina##c_mc_stam_on",
            C.route3_combat_stamina_enabled ~= false)
        if chg then save_config() end
        imgui.text(string.format("   %s",
            tostring(S.route3_combat_stamina_status or "full on mount")))
        chg, C.route3_combat_stamina_max = imgui.drag_float(
            "maximum##c_mc_stam_max", tonumber(C.route3_combat_stamina_max) or 100.0,
            1.0, 20.0, 500.0)
        if chg then save_config() end
        chg, C.route3_combat_stamina_regen = imgui.drag_float(
            "regeneration per second##c_mc_stam_regen",
            tonumber(C.route3_combat_stamina_regen) or 12.0, 0.5, 0.0, 100.0)
        if chg then save_config() end
        chg, C.route3_combat_stamina_regen_delay = imgui.drag_float(
            "regeneration delay (s)##c_mc_stam_delay",
            tonumber(C.route3_combat_stamina_regen_delay) or 1.5, 0.05, 0.0, 10.0)
        if chg then save_config() end
        for _, row in ipairs({
            { "melee combo cost", "route3_combat_stamina_cost_melee", 18.0 },
            { "heavy / gust cost", "route3_combat_stamina_cost_heavy", 28.0 },
            { "breath cost", "route3_combat_stamina_cost_breath", 35.0 },
            { "magic cost", "route3_combat_stamina_cost_magic", 55.0 },
            { "special attack cost", "route3_combat_stamina_cost_special", 40.0 },
            { "charge damage cost", "route3_combat_stamina_cost_charge", 15.0 },
        }) do
            local changed
            changed, C[row[2]] = imgui.drag_float(row[1] .. "##c_mc_" .. row[2],
                tonumber(C[row[2]]) or row[3], 1.0, 0.0, 100.0)
            if changed then save_config() end
        end
        imgui.text_colored(
            "Empty stamina blocks attacks only; flight and sprint movement always remain available.",
            0xFF70D0FF)
        imgui.tree_pop()
    end
    chg, C.route3_combat_combo_enabled = imgui.checkbox(
        "staged combo on the ground attack##c_mc_combo", C.route3_combat_combo_enabled ~= false)
    if chg then save_config() end
    chg, C.route3_combat_native_hitbox = imgui.checkbox(
        "native hitboxes (let the authored clip's own attack event do the work)##c_mc_nat",
        C.route3_combat_native_hitbox ~= false)
    if chg then save_config() end
    chg, C.route3_combat_fallback_pulse = imgui.checkbox(
        "fallback radius pulse when the native window misses##c_mc_fb",
        C.route3_combat_fallback_pulse ~= false)
    if chg then save_config() end
    chg, C.route3_combat_party_shield = imgui.checkbox(
        "party shield (her hitboxes can never hurt you or your pawns)##c_mc_shield",
        C.route3_combat_party_shield ~= false)
    if chg then save_config() end
    chg, C.route3_combat_native_scale = imgui.drag_float(
        "native damage x##c_mc_scale", tonumber(C.route3_combat_native_scale) or 6.0,
        0.1, 1.0, 60.0)
    if chg then save_config() end

    if imgui.tree_node("auto-aim + camera##c_mc_aim") then
        chg, C.route3_combat_aim_enabled = imgui.checkbox(
            "auto-aim onto the acquired body##c_mc_aim_on", C.route3_combat_aim_enabled ~= false)
        if chg then save_config() end
        chg, C.route3_combat_aim_deg = imgui.drag_float("aim cone (180 = full circle)##c_mc_deg",
            tonumber(C.route3_combat_aim_deg) or 180.0, 1.0, 15.0, 180.0)
        if chg then save_config() end
        chg, C.route3_combat_aim_secs = imgui.drag_float("aim time (s)##c_mc_secs",
            tonumber(C.route3_combat_aim_secs) or 0.12, 0.01, 0.01, 0.6)
        if chg then save_config() end
        chg, C.route3_combat_reach = imgui.drag_float("acquisition reach (m)##c_mc_reach",
            tonumber(C.route3_combat_reach) or 9.0, 0.1, 1.0, 30.0)
        if chg then save_config() end
        chg, C.route3_combat_lunge_max = imgui.drag_float(
            "strike-volume reach assist (m)##c_mc_lunge",
            tonumber(C.route3_combat_lunge_max) or 2.5, 0.1, 0.0, 6.0)
        if chg then save_config() end
        chg, C.route3_combat_cam_enabled = imgui.checkbox(
            "combat camera frames her and the target##c_mc_cam", C.route3_combat_cam_enabled ~= false)
        if chg then save_config() end
        chg, C.route3_combat_cam_side_deg = imgui.drag_float("camera angle (deg off heading)##c_mc_cs",
            tonumber(C.route3_combat_cam_side_deg) or -55.0, 1.0, -180.0, 180.0)
        if chg then save_config() end
        chg, C.route3_combat_cam_dist = imgui.drag_float("camera distance##c_mc_cd",
            tonumber(C.route3_combat_cam_dist) or 7.5, 0.1, 2.0, 25.0)
        if chg then save_config() end
        chg, C.route3_combat_cam_height = imgui.drag_float("camera height##c_mc_ch",
            tonumber(C.route3_combat_cam_height) or 3.2, 0.1, 0.0, 12.0)
        if chg then save_config() end
        chg, C.route3_combat_cam_bias = imgui.drag_float(
            "framing bias (0 = her, 1 = the victim)##c_mc_cb",
            tonumber(C.route3_combat_cam_bias) or 0.55, 0.01, 0.0, 1.0)
        if chg then save_config() end
        chg, C.route3_combat_cam_auto_size = imgui.checkbox(
            "pull camera back for large enemies##c_mc_cam_auto_size",
            C.route3_combat_cam_auto_size ~= false)
        if chg then save_config() end
        chg, C.route3_combat_cam_size_gain = imgui.drag_float(
            "large-target distance gain##c_mc_cam_size_gain",
            tonumber(C.route3_combat_cam_size_gain) or 1.8, 0.05, 0.0, 6.0)
        if chg then save_config() end
        chg, C.route3_combat_cam_size_max_extra = imgui.drag_float(
            "large-target maximum extra distance##c_mc_cam_size_cap",
            tonumber(C.route3_combat_cam_size_max_extra) or 12.0, 0.25, 0.0, 40.0)
        if chg then save_config() end
        chg, C.route3_combat_cam_manual_orbit = imgui.checkbox(
            "right stick adjusts the cinematic shot##c_mc_cam_manual",
            C.route3_combat_cam_manual_orbit ~= false)
        if chg then save_config() end
        chg, C.route3_combat_cam_orbit_speed = imgui.drag_float(
            "right-stick orbit speed (deg/s)##c_mc_cam_orbit_speed",
            tonumber(C.route3_combat_cam_orbit_speed) or 110.0, 1.0, 20.0, 300.0)
        if chg then save_config() end
        chg, C.route3_combat_cam_height_speed = imgui.drag_float(
            "right-stick height speed (m/s)##c_mc_cam_height_speed",
            tonumber(C.route3_combat_cam_height_speed) or 8.0, 0.25, 1.0, 30.0)
        if chg then save_config() end
        chg, C.route3_combat_cam_invert_y = imgui.checkbox(
            "invert cinematic camera vertical stick##c_mc_cam_invert_y",
            C.route3_combat_cam_invert_y == true)
        if chg then save_config() end
        imgui.text("   " .. tostring(S.route3_combat_cam_manual_status
            or "right stick is available while an attack camera owns the shot"))
        local live_cam = type(S.route3_drake_attack) == "table" and S.route3_drake_attack
            or type(S.route3_combat_combo) == "table" and S.route3_combat_combo or nil
        imgui.text(string.format("   measured target %.1fm | resolved camera %.1fm",
            tonumber(live_cam and live_cam.cam_target_height) or 0.0,
            tonumber(live_cam and live_cam.cam_resolved_dist)
                or tonumber(C.route3_combat_cam_dist) or 7.5))
        imgui.tree_pop()
    end

    if imgui.tree_node("combo frame data (stamp it once in the field)##c_mc_frames") then
        imgui.text("Link 1 talon stamp 50:0   Link 2 beak 50:10   Link 3 rush beak (below)")
        -- ⭐ The measured lengths. Three of these and the whole moveset can be pinned to exact
        -- frames instead of fractions -- and they are what proved the mod's 30fps assumption wrong.
        imgui.text_colored(string.format("playhead rate: %.1f fps (measured)", iris_mc_fps()), 0xFF66FF66)
        for k, v in pairs(S.route3_combat_endframes or {}) do
            imgui.text(string.format("   clip %s  endframe %.0f  (%.2fs)", tostring(k),
                tonumber(v) or 0.0, (tonumber(v) or 0.0) / iris_mc_fps()))
        end
        imgui.text("0 in a frame box below = AUTO (a fraction of that clip's measured length)")
        if st and st.live_frame then
            imgui.text_colored(string.format("live: clip %s frame %.0f / %s",
                tostring(st.live_clip), st.live_frame, tostring(st.live_end)), 0xFF66FF66)
            if imgui.button("stamp this frame as link " .. tostring(st.index) .. "'s IMPACT##c_mc_stamp") then
                local link = st.link_def
                if link and link.hit_key then
                    C[link.hit_key] = math.floor(st.live_frame + 0.5) + 0.0
                    save_config()
                    S.route3_combat_status = string.format("%s impact stamped at f%.0f",
                        tostring(link.label), st.live_frame)
                end
            end
        else
            imgui.text("(swing while mounted to see the live playhead)")
        end
        for _, k in ipairs({
            { "route3_gatk_stomp_hit_frame", "stamp impact frame" },
            { "route3_gatk_stomp_cancel_frame", "stamp combo-link frame" },
            { "route3_gatk_stomp_end_frame", "stamp end frame" },
            { "route3_gatk_beak_hit_frame", "beak impact frame" },
            { "route3_gatk_beak_cancel_frame", "beak combo-link frame" },
            { "route3_gatk_beak_end_frame", "beak end frame" },
            { "route3_combat_link3_hit_frame", "rush impact frame" },
            { "route3_combat_link3_link_frame", "rush combo-link frame" },
            { "route3_combat_link3_end_frame", "rush end frame" },
        }) do
            local v
            v, C[k[1]] = imgui.drag_float(k[2] .. "##c_mc_" .. k[1],
                tonumber(C[k[1]]) or 0.0, 1.0, 0.0, 400.0)
            if v then save_config() end
        end
        local vb
        vb, C.route3_gatk_combo_buffer_secs = imgui.drag_float(
            "input buffer (s)##c_mc_buf", tonumber(C.route3_gatk_combo_buffer_secs) or 0.7,
            0.05, 0.1, 2.0)
        if vb then save_config() end
        imgui.tree_pop()
    end

    if imgui.tree_node("gust finale -- wing-beat frame + native knockback##c_mc_gust") then
        imgui.text(string.format("measured: %s", tostring(S.route3_gust_flap_report or "(not yet measured)")))
        imgui.text(string.format("shell   : %s", tostring(S.route3_combat_shell or "-")))
        imgui.text(string.format("route   : %s", tostring(S.route3_combat_shell_route
            or "(standalone -- no handler needed)")))
        local g
        g, C.route3_gust_blow_mode = imgui.drag_int(
            "knockback: 0 = legacy scripted fling, 1 = native shell, 2 = both##c_mc_mode",
            math.floor(tonumber(C.route3_gust_blow_mode) or 1), 1, 0, 2)
        if g then save_config() end
        g, C.route3_gust_shell_route = imgui.drag_int(
            "cast route: 0 = auto, 1 = standalone (visible dome), 2 = handler only##c_mc_sr",
            math.floor(tonumber(C.route3_gust_shell_route) or 0), 1, 0, 2)
        if g then save_config() end
        imgui.text_colored("Shorten the wind-down (it is 347 authored frames / ~5.8s):", 0xFF66FF66)
        g, C.route3_gust_finale_beat = imgui.drag_int(
            "knock on which wing beat, counting back from the last (1 = final flap)##c_mc_fb",
            math.floor(tonumber(C.route3_gust_finale_beat) or 1), 1, 1, 8)
        if g then save_config() end
        g, C.route3_gust_end_after_frames = imgui.drag_float(
            "end the wind-down this many frames after the knock (0 = play it out)##c_mc_ea",
            tonumber(C.route3_gust_end_after_frames) or 35.0, 5.0, 0.0, 400.0)
        if g then save_config() end
        g, C.route3_gust_end_speed = imgui.drag_float(
            "wind-down play speed (1.0 = authored)##c_mc_es",
            tonumber(C.route3_gust_end_speed) or 1.5, 0.05, 0.25, 3.0)
        if g then save_config() end
        g, C.route3_gust_finale_frame = imgui.drag_float(
            "finale frame (auto-pinned from the beat above)##c_mc_ff",
            tonumber(C.route3_gust_finale_frame) or 90.0, 1.0, 1.0, 400.0)
        if g then save_config() end
        g, C.route3_gust_flap_autocal = imgui.checkbox(
            "measure the real last wing beat and pin it##c_mc_cal",
            C.route3_gust_flap_autocal ~= false)
        if g then save_config() end
        g, C.route3_gust_shell_size = imgui.drag_float("knock shell size##c_mc_ss",
            tonumber(C.route3_gust_shell_size) or 6.0, 0.25, 0.5, 40.0)
        if g then save_config() end
        g, C.route3_gust_shell_delay = imgui.drag_float(
            "knock shell delay (s) -- raise if the knock lands early##c_mc_sd",
            tonumber(C.route3_gust_shell_delay) or 0.0, 0.05, 0.0, 3.0)
        if g then save_config() end
        g, C.route3_gust_flap_min_drop = imgui.drag_float(
            "wing-beat sensitivity (m of downstroke)##c_mc_md",
            tonumber(C.route3_gust_flap_min_drop) or 0.05, 0.005, 0.005, 0.6)
        if g then save_config() end
        if imgui.button("cast the knock shell now (test)##c_mc_testshell") then
            iris_mc_cast_knock_shell(nil, {})
        end
        imgui.tree_pop()
    end

    if imgui.tree_node("target marker + prone finisher##c_mc_misc") then
        local m
        m, C.route3_combat_marker_style = imgui.drag_int(
            "marker: 0 = none, 1 = subtle ticks, 2 = old [ LOCK ]##c_mc_mk",
            math.floor(tonumber(C.route3_combat_marker_style) or 1), 1, 0, 2)
        if m then save_config() end
        m, C.route3_combat_marker_alpha = imgui.drag_int("marker opacity##c_mc_ma",
            math.floor(tonumber(C.route3_combat_marker_alpha) or 140), 5, 20, 255)
        if m then save_config() end
        m, C.route3_combat_marker_size = imgui.drag_float("marker size##c_mc_ms",
            tonumber(C.route3_combat_marker_size) or 14.0, 0.5, 4.0, 48.0)
        if m then save_config() end
        m, C.route3_ground_eat_prone = imgui.checkbox(
            "RT finishes a knocked-down enemy with the eat cycle##c_mc_prone",
            C.route3_ground_eat_prone ~= false)
        if m then save_config() end
        m, C.route3_ground_eat_prone_range = imgui.drag_float("prone finisher reach (m)##c_mc_pr",
            tonumber(C.route3_ground_eat_prone_range) or 4.5, 0.1, 1.0, 12.0)
        if m then save_config() end
        m, C.route3_combat_reqid_capture = imgui.checkbox(
            "DIAGNOSTIC: record ch253/ch257 collider request ids##c_mc_cap",
            C.route3_combat_reqid_capture == true)
        if m then save_config() end
        for _, row in ipairs(S.route3_combat_reqid_rows or {}) do
            imgui.text("  " .. tostring(row.text))
        end
        imgui.tree_pop()
    end
    imgui.tree_pop()
end

log.info("[IrisMountCombat] shared mount combat loaded (" .. tostring(MOD) .. ")")
