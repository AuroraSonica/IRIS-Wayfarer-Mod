-- IrisHorseRodeo.lua
--
-- I.R.I.S. — Horse Rodeo (taming, phase 0 of the mount campaign).
-- Approach a wild horse calmly, grab hold (E / RT), survive the buck cycle,
-- and it settles: tamed = true on its registry record. Thrown = detached and
-- it bolts. The rider attachment built here IS the future mount attachment.
--
-- Mechanism notes (extracted from the griffin ride saga 2026-07-21):
--   * player set_UniversalPosition RENDERS; set_Position does not;
--     set_Rotation never renders for the player. So the hold = per-frame
--     universal write at the seat point; body pose via motion freeze.
--   * seat point: horse joint render pos rebased to universal space
--     (joint_render - horse_render_root + horse_universal_root).
--   * player colliders/controller suppressed per-TICK while held, with
--     disable/restore bookkeeping. Player MotionFsm2/think-stop untouched.
--   * horse bucking: think-stop + fsm-off (the taming clip-visibility law)
--     + driven hop/leap clips + yaw jitter written to the horse transform.

local MOD = "IrisHorseRodeo"
local CONFIG_FILE = MOD .. ".json"
local REGISTRY_KEY = "__lyra_animal_audio_variants"
local REGISTRY = rawget(_G, REGISTRY_KEY) or {}
rawset(_G, REGISTRY_KEY, REGISTRY)
local AUDIO_API_KEY = "__lyra_horse_custom_audio_api"

local GRAB_KEY = 0x45          -- E
local GAMEPAD_GRAB_MASK = 0x800 -- RT
local SEAT_JOINTS = {"Spine_2", "Spine_1", "Hip"}
local BUCK_MOTION_ID = 212     -- doe hop (native bank 0)
local PLAYER_SUPPRESS_COMPONENTS = {
    "via.physics.RequestSetCollider",
    "via.physics.Colliders",
    "via.physics.CharacterController",
    "app.HitController",
    "app.GroundFixer",
    "via.motion.JointConstraints", -- griffin CSV parity (07-23: missing
                                   -- entry let world brushes nudge the
                                   -- seated rider)
    "via.motion.IkLeg2",
    -- ⛔⛔ 2026-08-09 RIDE CTD (12 min into a mounted combat ride, named in the stack):
    -- `app.RunupToClimbWallController.isRunupMotionEnd` <- `.update`. This controller
    -- watches for "running at a wall to climb it" and asks the MOTION whether the run-up
    -- clip has finished -- but a seated rider is parked (FallLoop) with her motion FSM
    -- disabled and PlaySpeed 0, so the clip it expects does not exist and the query
    -- derefs null. The seat enforcer log shows the trigger: it kept re-parking because
    -- the action kept returning to LandingToRun, i.e. ground-locomotion machinery was
    -- live on a body we have frozen. Same family the determinism hunt already met when
    -- it had to block trySetActionOnGround / ClimbWallAction.startClimbing (r37) --
    -- wall-climb machinery must be OFF on a seated rider, not merely out-voted.
    "app.RunupToClimbWallController",
}

local C = {
    enabled = true,
    -- ⭐ BACK ON (2026-08-09): EXONERATED by the mount-CTD bisect (the crash survived with
    -- this off; the real cause was the untyped GUI write). This is the r13 dismount-drift
    -- cure -- it feeds the live seat position to the suppressed components so they do not
    -- keep a stale mount-point coordinate. ⚠ It now drives set_OverwritePosition rather
    -- than the r16 `warp()` that AV'd, so if anything about DISMOUNT POSITION looks off,
    -- this is the one thing in that path that changed.
    cc_sync_enabled = true,
    -- ⭐ 08-09: issue the 0-arg warp() straight after each destination write, which is the
    -- contract the crash-law comment in costume_tick already spells out. Without it the write
    -- fills a field nothing applies, the controller's internal position stays at the mount
    -- point, and DISMOUNT TELEPORTS BACK THERE (the r13 bug, returned). Set false to fall back
    -- to write-only if this ever AVs again -- a bare warp is lethal, a warp right after a
    -- fresh valid write is the documented sequence.
    cc_sync_warp = true,
    -- ⭐ BACK ON (2026-08-09) now the real defect is fixed. This is the r54 mounted
    -- button-prompt renamer (RT=Dismount, X=Kick, B=Gallop...). It CAUSED the mount CTD
    -- not by existing but by writing set_Message onto whatever object sat at a GUI path
    -- WITHOUT checking the type -- see the guard in horse_ride_hud_tick. The bisect that
    -- caught it lives in this file's history; the switch stays so it can be halved again.
    ride_hud = true,
    -- While riding, the mount owns enemy attention and the rider has no combat
    -- hurtbox.  This also stops short enemies trying to stand beneath the saddle
    -- to reach the Arisen instead of fighting the creature in front of them.
    ride_suppress_player_hitcontroller = true,
    mounted_weapon_lock = true,
    -- Mounted unicorn cooldown ring.  The game's GUI reports the Y/keycap
    -- object's pivot differently between prompt layouts, so the native anchor
    -- is the baseline and these small, saved corrections remain user-tunable.
    blessing_hud_pad_dx = 0.0,
    blessing_hud_pad_dy = 0.0,
    blessing_hud_keyboard_dx = 0.0,
    blessing_hud_keyboard_dy = 0.0,
    blessing_hud_size = 1.0,
    -- What a "blank" mounted prompt writes.
    --   " " (default) = a single space: the slot LOOKS empty, which is the intent, while
    --                   still being a NON-EMPTY write so it never takes the path that
    --                   CTD'd the mount.
    --   ""            = write NOTHING at all; the game's own label stands (griffin parity,
    --                   the maximally-safe fallback if a space ever misbehaves).
    -- ⛔ The one thing that must NEVER reach set_Message is the empty string itself --
    -- emptying a live prompt re-lays-out the panel mid-write. A space is not empty.
    -- ⚠ RESIDUAL UNKNOWN: if the GUI TRIMS whitespace internally it would treat " " as ""
    -- and the crash returns -- in which case set this back to "".
    ride_hud_blank_text = " ",
    approach_range = 3.2,
    grab_calm_speed = 2.0,     -- horse must be slower than this to grab
    seat_up = 1.55,          -- fallback height above the ROOT (no joint)
    seat_above_joint = 0.15, -- rider height above the animated back joint
    seat_fwd = 0.25,         -- forward along the horse (toward the withers)
    use_wilds_pose = false,  -- the Wilds clip is griffin-saddle-calibrated:
                             -- its painted root/hip lift FLOATS a horse rider
    teleport_mount = false,  -- scripted place+latch (the old entry);
                             -- default = ORGANIC: jump at the horse + grab
    -- ⭐ 08-18 work-order: W3 full-bank ride features (all horse-gated).
    gait_ladder_enabled = true,   -- tap B/SHIFT: trot -> canter -> gallop
    speed_canter = 6.0,           -- matches the W3 canter clip's calibrated m/s
    w3_jumps_enabled = true,      -- per-gait W3 jump sets over the 902 pack
    kick_hit_frac = 0.4,          -- kick contact as fraction of the W3 clip
    horse_ik_off_ride = true,     -- release DD2 foot-IK while mounted (the
                                  -- backwards-bending-legs fix); off = legacy
    speed_reverse = 0.9,          -- backing-up speed (m/s), 901:106 walk_back
    gait_trans_hold = 0.9,        -- seconds a transition clip owns the layer
    grip_max = 100.0,
    grip_drain_per_buck_s = 26.0,
    grip_regen_calm_s = 9.0,
    rodeo_secs = 18.0,
    buck_motion_id = 401, -- lading_vertical (landing slam); 212 = run_end skid
    buck_on_s = 1.1,
    buck_off_min_s = 0.7,
    buck_off_max_s = 1.6,
    yaw_kick_deg = 55.0,
    kick_camera_blend_s = 0.65,
    jump_max_landing_slope_deg = 42.0,
    jump_landing_sample_m = 0.8,
    -- Shadow-only proof of Nick's Puppeteer route.  X requests the authored
    -- Ch223_Bite action node (and therefore its real AttackUserData/collider)
    -- instead of painting the visually matching atlas clip + synthetic HP hit.
    -- Cats stay on the shipping path until the wolf proves this ownership lease.
    -- Off after the first field test: the raw node translated Shadow backwards
    -- without taking visible motion ownership.  Re-enable deliberately from the
    -- panel for the corrected native-collider + deterministic-visual test.
    wyrm_native_bite_test = false,
    -- Separate because this is a paired-body catch, not an ordinary strike.
    -- The lease always requests HoldDownCatchFinish before it parks the wolf.
    wyrm_native_maul_test = false,
    -- 08-16 failed experiment: Puppeteer's controller works on the fresh ch223
    -- puppet it creates, but a persistent tamed ch223 reports Action=Invalid
    -- for every selector request.  Enabling it produces unbounded root motion
    -- (backwards sliding / flying bite loop), so this may never be enabled on a
    -- shipping ride.  The dormant probe remains below for diagnosis only.
    wyrm_native_controller = false,
    -- Bounded, event-driven receipts for mounted combat.  This writes only when
    -- a button/link/stage changes state (never every frame), so it is safe to
    -- leave enabled while diagnosing the unreliable ch223 jaw transaction.
    wyrm_combat_trace = true,
    -- Multiplies the FINAL applied HP amount (updateDamageHp args[4]) whenever
    -- the mounted wyrm is the attacker. 08-18: the retired AttackRate write was
    -- measured doing nothing at 8x -- DD2 subtracts HP from a separate argument
    -- (the r96-r98 horse-clamp law), so this is the one authoritative lever.
    -- Still not a fixed-damage fallback: if the real collider does not connect,
    -- updateDamageHp never fires and no damage occurs. The attack IV gene
    -- multiplies on top via _G.IrisIVState.
    wyrm_native_damage_scale = 8.0,
    -- Multiplies DamageInfo.Damage at damageProc for the wyrm's hits. Damage is
    -- the REACTION input (never the HP amount), so this dial picks how hard
    -- enemies visibly react -- stagger/knockdown tiers -- independent of HP.
    wyrm_reaction_scale = 2.0,
    -- Dodge (LB/RB): the lateral travel waits this long so clip 462/463 can
    -- reach its actual hop frame instead of skating sideways out of the blend.
    wyrm_dodge_delay = 0.16,
    wyrm_dodge_speed = 4.8,
    wyrm_dodge_secs = 0.42,
    -- Multiplies the genuine ch223 collider dimensions returned by the engine.
    -- This does not manufacture damage: an expanded jaw volume must still make
    -- a native receiver contact, so blood, sound and reaction remain authored.
    wyrm_native_collider_scale = 1.85,
}

local S = rawget(_G, "__iris_horse_rodeo_v1") or {}
rawset(_G, "__iris_horse_rodeo_v1", S)
S.generation = (S.generation or 0) + 1
local GENERATION = S.generation
-- per-reload: each reload may have stranded hardened bodies (see the
-- invincibility sweep in on_frame)
S.invincibility_swept = nil
S.loaded_at = os.clock()
S.stage = "idle"            -- idle | latching | rodeo
S.status = "wild horses can be broken: climb on and hold tight"
S.prompt = nil
-- Script reset RECOVERY: a ride active at reset time used to survive in
-- the persisted state and keep its hold running forever ("stuck standing
-- on the horse"). Force-clear and restore the player's basics every load.
if S.ride then
    pcall(function()
        local manager = sdk.get_managed_singleton("app.CharacterManager")
        local character = manager and manager:call("get_ManualPlayer")
        local inner = character and character:call("get_Character")
        character = inner or character
        if character then
            pcall(function()
                character:call("setCharacterControllerEnable", true)
            end)
            local go = character:call("get_GameObject")
            local fsm = go and go:call(
                "getComponent(System.Type)", sdk.typeof("via.motion.MotionFsm2"))
            if fsm then fsm:call("set_Enabled", true) end
            local motion = character:call("get_Motion")
            if motion then motion:call("set_PlaySpeed", 1.0) end
            -- clear any lingering climb state from earlier experiments
            pcall(function() character:call("endClimb") end)
            pcall(function() character:call("requestEndClimb") end)
            pcall(function()
                character:call("set_IsSetClimbActionByRequest", false)
            end)
        end
    end)
end
S.ride = nil
rawset(_G, "__iris_horse_rodeo_active_addr", nil)
S.tamed_count = S.tamed_count or 0
S.thrown_count = S.thrown_count or 0
S.disabled_components = {}
-- STATE HYGIENE (07-23 "climbed and nothing happened"): S survives script
-- reloads, so a stale ride_pose_on=true from ANY earlier test convinces
-- the mount-capture tick someone is already seated and it dead-ends.
-- The suppress/restore records were just wiped above, so a seated state
-- cannot legitimately survive a reload — always start dismounted.
S.ride_pose_on = false
S.mount_climb_since = nil
if S.costume then S.costume.seat = nil end
-- Reload hygiene: this global is consumed by the griffin relationship/hate
-- hooks.  Never let a previous script generation leave the world believing a
-- wolf/cat is still being ridden.
rawset(_G, "IrisWyrmMounted", nil)
rawset(_G, "IrisWyrmNativeAttackLease", nil)
-- A reload can interrupt the short native-damage lease before its normal
-- finish path restores ch223's AttackRate. S survives reloads, so restore from
-- the retained managed wrapper before discarding that lease below.
if S.wyrm_native_lease and S.wyrm_native_lease.native_hit_controller
    and S.wyrm_native_lease.old_attack_rate ~= nil then
    pcall(function()
        S.wyrm_native_lease.native_hit_controller:call(
            "set_AttackRate(System.Single)",
            S.wyrm_native_lease.old_attack_rate)
    end)
end
if S.wyrm_native_lease and S.wyrm_native_lease.native_jaw_tracks then
    pcall(function() S.wyrm_native_lease.native_jaw_tracks:release() end)
    S.wyrm_native_lease.native_jaw_tracks = nil
end
-- r8: a reload mid-pinned-maul must not leave a think-stopped goblin statue.
-- The retained wrapper may be dead (wrappers DIE across reloads) -- pcall.
if S.wyrm_native_lease and S.wyrm_native_lease.pin_maul then
    pcall(function()
        local target = S.wyrm_native_lease.target
        target:call("set_IsThinkStop", false)
        local motion = target:call("get_Motion")
        if motion then motion:call("set_PlaySpeed", 1.0) end
    end)
end
-- gait overrides are session-only lab levers — every load returns to the
-- baked defaults (bank 901: walk 1 / trot 2 / gallop 3)
S.gait_walk_bank, S.gait_walk_id = nil, nil
S.gait_run_bank, S.gait_run_id = nil, nil
S.gait_dash_bank, S.gait_dash_id = nil, nil
-- A script reset can occur while the rejected native-controller experiment owns
-- the persistent body.  Restore the interface and park that invalid graph BEFORE
-- dropping the surviving managed wrappers; otherwise the new generation cannot
-- undo the flying bite loop it inherited.
if S.costume and S.costume.native_controller_prepared then
    local stale_costume = S.costume
    pcall(function()
        local act = stale_costume.native_action_interface
        if act then
            act:call("set_Enabled",
                stale_costume.native_action_interface_was_enabled ~= false)
        end
    end)
    pcall(function()
        local ai = stale_costume.native_ai
        local nav = stale_costume.native_nav
        local fsm = stale_costume.native_fsm
        if ai then ai:call("set_Enabled", false) end
        if nav then nav:call("set_Enabled", false) end
        if fsm then fsm:call("set_Enabled", false) end
        if stale_costume.horse_character then
            stale_costume.horse_character:call("set_IsThinkStop", true)
            local motion = stale_costume.horse_character:call("get_Motion")
            if motion then motion:call("set_PlaySpeed", 1.0) end
        end
    end)
    stale_costume.native_controller_live = nil
    stale_costume.native_controller_prepared = nil
    stale_costume.native_move_mode = nil
    stale_costume.native_move_retry_at = nil
    stale_costume.native_move_log_at = nil
    stale_costume.native_jump_latch = nil
end
-- ⭐ 08-13 LOAD HYGIENE (the stale-state trap's second bite - "RT tries to pick him
-- up"): S survives script resets but its managed wrappers DIE. A costume carrying a
-- dead horse_go silently disables the press-to-mount block (valid() reads false), so
-- the native catch deadlifts the mount instead. A costume can never legitimately
-- survive a reload - drop it, and the stale seat flag with it (the documented
-- ride_pose_on trap). Re-arm with the panel button after any reset.
S.costume = nil
S.ride_pose_on = false
S.wyrm_atk_until, S.wyrm_atk_hold, S.wyrm_btn_prev = nil, nil, nil
S.wyrm_native_lease = nil
S.wyrm_native_pending = nil
S.wyrm_native_recover_until = nil
S.wyrm_down_release = nil
S.wyrm_pad = nil
-- CatchController settings are live managed instances owned by the current
-- scene.  Never carry one through a script reset; the passive startCatch spy
-- below will retain a fresh ch223 contract when a wild wolf/cat next uses it.
S.wyrm_catch_setting = nil
S.wyrm_catch_interpolator = nil
S.wyrm_catch_capture_status = "waiting for a natural ch223 catch"
rawset(_G, "IrisWyrmNativeCatchSetting", nil)
rawset(_G, "IrisWyrmNativeCatchInterpolator", nil)
pcall(function()
    local saved = json.load_file("IrisHorseRodeo_wolf_catch_setting.json")
    if type(saved) == "table"
        and tostring(saved.catcher_id or ""):lower():match("^ch223") then
        S.wyrm_catch_capture_status = "saved ch223 catch contract ready"
    end
end)
-- 08-13 Shadow-mount CTD guard: the costume is gone, so release the scale easer too
_G.IrisScaleHoldAddr = nil

local reflog = log  -- capture REFramework's log API before shadowing it
local function log(message)
    -- log.info persists to re2_framework_log.txt (print does not survive a
    -- crash or restart — learned the hard way on the graft CTD).
    pcall(function() reflog.info("[" .. MOD .. "] " .. tostring(message)) end)
    pcall(function() print("[" .. MOD .. "] " .. tostring(message)) end)
end

local function valid(object)
    if not object then return false end
    local ok, value = pcall(function() return object:call("get_Valid") end)
    return (not ok) or value ~= false
end

-- re.on_frame continues while DD2's photo mode is open.  The ridden mount is
-- transform-driven, so merely pausing its animation (IrisWildHorses' guard)
-- does not stop the body from walking through the frozen world.  The rodeo
-- drive itself must relinquish the reins for every gameplay/photo pause.
local function horse_world_paused()
    local paused = false
    pcall(function()
        local manager = sdk.get_managed_singleton("app.PauseManager")
        paused = manager and manager:call("isPausedAny") == true
    end)
    if not paused then
        pcall(function()
            local gui = sdk.get_managed_singleton("app.GuiManager")
            paused = gui and (gui:call("isPausedGUI") == true
                or gui:call("get_IsDispPhotoModeAll") == true
                or gui:call("get_IsDispPhotoMode") == true)
        end)
    end
    return paused == true
end

local function object_address(object)
    local address = nil
    pcall(function() address = tonumber(object:get_address()) end)
    return address
end

-- ⛔ 2026-08-09: `sdk.typeof(name)` returns NIL for a type this build does not have, and
-- that nil went straight into getComponent -> "Internal game exception ...
-- System.ArgumentNullException", 144 times in one session (once per suppress-list pass,
-- ~1.3s apart, all ride long). Harmless-looking log noise that is really us asking the
-- engine for a type that does not exist. Resolve the type FIRST, skip if unknown, and
-- name the bad entry ONCE so a typo in a component list can never hide again.
local TYPEOF_MISSING = {}
local function get_component(game_object, type_name)
    if not valid(game_object) then return nil end
    local t = nil
    pcall(function() t = sdk.typeof(type_name) end)
    if not t then
        if not TYPEOF_MISSING[type_name] then
            TYPEOF_MISSING[type_name] = true
            pcall(function()
                reflog.warn("[" .. MOD .. "] unknown component type '"
                    .. tostring(type_name) .. "' -- skipped (check the spelling)")
            end)
        end
        return nil
    end
    local component = nil
    pcall(function()
        component = game_object:call("getComponent(System.Type)", t)
    end)
    return valid(component) and component or nil
end

local function load_config()
    local data = nil
    pcall(function() data = json.load_file(CONFIG_FILE) end)
    if type(data) ~= "table" then
        pcall(function() json.dump_file(CONFIG_FILE, C) end)
        return
    end
    for key, default in pairs(C) do
        if type(default) == "boolean" then
            if data[key] ~= nil then C[key] = data[key] == true end
        elseif data[key] ~= nil then
            C[key] = tonumber(data[key]) or default
        end
    end
    -- 07-23 "pitch/yaw isn't remembered": keys invented after load (seat
    -- fit, mount camera, speeds, pose speed) saved fine but were skipped
    -- here because they have no default — adopt them too
    for key, value in pairs(data) do
        if C[key] == nil
            and (type(value) == "number" or type(value) == "boolean"
                or type(value) == "string") then
            C[key] = value
        end
    end
    -- Migration: seat_up changed meaning (above-JOINT → above-ROOT);
    -- old low values would put the rider inside the horse's belly.
    if C.seat_up < 0.8 then C.seat_up = 1.55 end
    -- Safety migration: builds from the 08-16 field test may have persisted the
    -- broken native controller as true.  A persistent tame has an Invalid action
    -- graph, so silently honouring that saved bit recreates the launch/crash loop.
    C.wyrm_native_controller = false
end

local function save_config()
    pcall(function() json.dump_file(CONFIG_FILE, C) end)
end

-- ---------------------------------------------------------------------------
-- Player / horse plumbing
-- ---------------------------------------------------------------------------

local function player_character()
    local character = nil
    pcall(function()
        local manager = sdk.get_managed_singleton("app.CharacterManager")
        character = manager and manager:call("get_ManualPlayer") or nil
        local inner = character and character:call("get_Character") or nil
        character = inner or character
    end)
    return character
end

local function player_game_object()
    local character = player_character()
    local game_object = nil
    pcall(function() game_object = character and character:call("get_GameObject") end)
    return valid(game_object) and game_object or nil
end

local function mounted_weapon_tick(force)
    if not S.ride_pose_on or C.mounted_weapon_lock == false then return end
    local now = os.clock()
    if not force and now < (tonumber(S.mounted_weapon_check_at) or 0.0) then
        return
    end
    S.mounted_weapon_check_at = now + 0.25
    pcall(function()
        local character = player_character()
        local human = character and character:call("get_Human") or nil
        if human and human:call("isSheathedWeaponPlayer") ~= true then
            human:call("forceChangeDrawingWeapon", false)
            -- 08-18 receipt (Aurora: "weapon out when mounting again"): if
            -- this counter climbs steadily while seated, the force call is
            -- being fought and loses; if it stays at one or two per mount,
            -- the draw happens once (mount-press attack input or combat
            -- auto-draw) and is being corrected. Different fixes each way.
            S.mounted_weapon_forced = (tonumber(S.mounted_weapon_forced) or 0) + 1
            S.mounted_weapon_forced_at = now
        end
    end)
end

-- Hooks survive a REFramework script reset, so they call a replaceable global
-- dispatcher rather than closing over stale state from an older generation.
rawset(_G, "__iris_mounted_draw_weapon_dispatch", function()
    return S.ride_pose_on and C.mounted_weapon_lock ~= false
end)
if not rawget(_G, "__iris_mounted_draw_weapon_hook") then
    pcall(function()
        local td = sdk.find_type_definition("app.PlayerInputProcessor")
        local method = td and td:get_method("processDrawWeapon()")
        if not method then return end
        sdk.hook(method, function()
            local dispatch = rawget(_G, "__iris_mounted_draw_weapon_dispatch")
            if dispatch and dispatch() then
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
            return sdk.PreHookResult.CALL_ORIGINAL
        end, function(retval) return retval end)
        rawset(_G, "__iris_mounted_draw_weapon_hook", true)
    end)
end

-- Redirect NEW enemy hate writes from the rider to the ridden creature. Existing
-- player hate becomes harmless because the mounted rider's hurt/target colliders
-- are suppressed. Mount- or player-authored hate is deliberately left alone.
rawset(_G, "__iris_mounted_hate_redirect_dispatch", function(args)
    if not S.ride_pose_on or C.ride_suppress_player_hitcontroller == false then
        return
    end
    local mount_go = S.costume and S.costume.horse_go or nil
    local rider_go = player_game_object()
    if not (valid(mount_go) and valid(rider_go)) then return end
    local target_go = nil
    pcall(function() target_go = sdk.to_managed_object(args[3]) end)
    if object_address(target_go) ~= object_address(rider_go) then return end
    local hater_go = nil
    pcall(function()
        local hate_system = sdk.to_managed_object(args[2])
        hater_go = hate_system and hate_system:call("get_GameObject") or nil
    end)
    local hater_addr = object_address(hater_go)
    if hater_addr == object_address(mount_go)
        or hater_addr == object_address(rider_go) then return end
    args[3] = sdk.to_ptr(mount_go)
    S.mounted_hate_redirects = (tonumber(S.mounted_hate_redirects) or 0) + 1
end)
if not rawget(_G, "__iris_mounted_hate_redirect_hook") then
    pcall(function()
        local td = sdk.find_type_definition("app.HateSystem")
        local method = td and td:get_method(
            "addHateParam(via.GameObject, app.HateRecvCategory, app.HateSystem.WriteType, "
            .. "System.Single, System.Single, System.Single, System.Single)")
        if not method then return end
        sdk.hook(method, function(args)
            local dispatch = rawget(_G, "__iris_mounted_hate_redirect_dispatch")
            if dispatch then pcall(dispatch, args) end
            return sdk.PreHookResult.CALL_ORIGINAL
        end, function(retval) return retval end)
        rawset(_G, "__iris_mounted_hate_redirect_hook", true)
    end)
end

local function universal_pos(game_object)
    local value = nil
    pcall(function()
        local transform = game_object:call("get_Transform")
        value = transform and transform:call("get_UniversalPosition") or nil
    end)
    return value
end

local function render_pos(game_object)
    local value = nil
    pcall(function()
        local transform = game_object:call("get_Transform")
        value = transform and transform:call("get_Position") or nil
    end)
    return value
end

-- ⛔⛔ 08-09 r62 -- WHY EVERY RAY IN THIS FILE HAS BEEN DEAD SINCE THE DAY IT
-- WAS WRITTEN. Both ray users here (the jump's wall-check, r33; the mount
-- camera's wall pull-in, r33/r53/r55) opened with
--     local mkv = rawget(_G, "make_vec3")
--     if not (... and mkv) then return end
-- and make_vec3 is a `local function` in GriffinRideProbe, never exported.
-- rawget on _G therefore returned nil EVERY time, so both guards took the
-- silent early return on every single call. Not "sometimes" -- always.
-- Evidence (08-09 log, 11 jumps across two script reloads): not one
-- "wall at"/"LEDGE at" line and not one "mountcam occlusion engaged" line.
-- The consequences are exactly the two bugs Aurora keeps reporting:
--   * the leap had NO wall protection at all, so it drove its full 8-45m
--     arc straight through whatever was in front of it -- the horse
--     "disappearing" into scenery;
--   * the camera had NO occlusion handling at all, so a wall between lens
--     and rider was simply never noticed -- the "spazzing out on obstruction".
-- ⚠ THE LESSON: `rawget(_G, name)` across files only works if the other file
-- declared it GLOBAL. route3_ray / route3_ensure_ray / route3_ground_below_uni
-- are global; make_vec3 is not. A nil fetch inside an `if not (...) then
-- return end` guard fails SILENTLY and looks exactly like "no hit".
-- Build the vec3 here instead -- no cross-file dependency to rot.
local function rodeo_vec3(x, y, z)
    local v = nil
    pcall(function()
        v = ValueType.new(sdk.find_type_definition("via.vec3"))
        v.x = x or 0
        v.y = y or 0
        v.z = z or 0
    end)
    return v
end

-- ⭐⭐ 08-10 r92 -- GRIFFIN-PARITY JUMP HELPERS.
-- ⛔ THE BLEND ARGUMENT IS FRAMES, NOT SECONDS. The griffin blends every clip
-- swap over 8.0 and its config names the unit outright (route3_flap_blend_frames,
-- clamped to a minimum of 2.0). The horse has been passing 0.12 / 0.20 into the
-- same 4th argument -- which, read as frames, is a two-millisecond hard cut. That
-- is almost certainly the "popping between phases" that no amount of arc maths
-- was ever going to fix. One constant, used everywhere the jump changes clip.
local IRIS_JUMP_BLEND = 8.0
local function iris_jump_play(costume, bank, clip, blend)
    if not (costume and bank and clip) then return false end
    local ok = false
    pcall(function()
        local motion = costume.horse_character:call("get_Motion")
        local layer = motion and motion:call("getLayer", 0)
        if not layer then return end
        layer:call(
            "changeMotion(System.UInt32, System.UInt32, System.Single, "
            .. "System.Single, via.motion.InterpolationMode, "
            .. "via.motion.InterpolationCurve)",
            bank, clip, 0.0, tonumber(blend) or IRIS_JUMP_BLEND, 1, 1)
        layer:call("set_Speed", 1.0)
        ok = true
    end)
    -- ⛔ AND KILL ROOT MOTION AFTER EVERY SWAP. changeMotion can reset the
    -- layer's root-motion state (this file says so itself where the GAIT clips
    -- do exactly this) -- but none of the jump phases ever did. So the borrowed
    -- bank-902 clip's baked leap has been free to move the body AGAINST our
    -- ballistics for the whole arc. The griffin disables its root controllers at
    -- launch and restores them at touchdown for precisely this reason.
    S.need_rootmotion_kill = true
    return ok
end
local function iris_jump_sync_character(costume, pos)
    -- ⚠ OPT-IN. The griffin writes the GameObject transform AND
    -- app.Character:set_UniversalPosition every frame. The horse drives the OX
    -- (the live-physics body the engine settles first) and lets the shell follow,
    -- so a second write here could double-drive it. Unproven either way, so it
    -- is a switch, default OFF -- turn it on if the body contests mid-air Y.
    if C.jump_sync_character ~= true then return end
    pcall(function()
        costume.horse_character:call("set_UniversalPosition", pos)
    end)
end
local function iris_jump_land(costume, jump, now_d)
    -- phase 3 + the settle. The griffin locks MOVEMENT for 0.5s while its
    -- landing clip plays; we only ever held the animation layer, so the gait
    -- could visually resume under a body still landing.
    if jump.jland and jump.jbank then
        iris_jump_play(costume, jump.jbank, jump.jland, IRIS_JUMP_BLEND)
        costume.force_hold = true
        log("jump seq: land (on contact)")
    end
    costume.jump_land_until = now_d + (tonumber(C.jump_land_secs) or 0.45)
    costume.jump_settle_until = costume.jump_land_until
    -- The descent predictor normally posts this a fraction before contact, but
    -- an uphill/shortened arc can meet the world before the prediction window.
    -- Actual contact is the final authority: guarantee exactly one impact event.
    if not jump.land_fx_done then
        jump.land_fx_done = true
        pcall(function()
            local audio = rawget(_G, "__lyra_horse_custom_audio_api")
            if audio and audio.play_event then
                local ok = audio.play_event(
                    tonumber(C.jump_land_event) or 1084357815,
                    costume.horse_go)
                log("jump land fx: " .. tostring(ok) .. " (contact fallback)")
            end
        end)
    end
    costume.jump_thud_pending = nil
    costume.bang_due = {tries = 10}
end

local function distance(a, b)
    if not a or not b then return math.huge end
    local dx = (a.x or 0) - (b.x or 0)
    local dy = (a.y or 0) - (b.y or 0)
    local dz = (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function horses()
    local found = {}
    for _, record in pairs(REGISTRY) do
        if record.kind == "horse" and valid(record.game_object) then
            found[#found + 1] = record
        end
    end
    return found
end

-- Horse taming owns a horse only when the camera is actually pointing at it.
-- The old nearest-within-9m rule made N select a horse behind the player (and,
-- at the same time, let IrisTaming arm an unrelated rabbit/wolf in front).
-- Centre-line wins first; distance only breaks near-equal aim.
local function focused_wild_horse(max_distance)
    local player_pos = universal_pos(player_game_object())
    if not player_pos then return nil end
    local cam_pos, cfx, cfz = nil, nil, nil
    pcall(function()
        local cam = sdk.get_primary_camera()
        local cgo = cam and cam:call("get_GameObject")
        local ctf = cgo and cgo:call("get_Transform")
        local rot = ctf and ctf:call("get_Rotation")
        cam_pos = ctf and ctf:call("get_UniversalPosition")
        if rot then
            local fx = -(2.0 * (rot.x * rot.z + rot.w * rot.y))
            local fz = -(1.0 - 2.0 * (rot.x * rot.x + rot.y * rot.y))
            local fl = math.sqrt(fx * fx + fz * fz)
            if fl > 0.05 then cfx, cfz = fx / fl, fz / fl end
        end
    end)
    if not (cam_pos and cfx and cfz) then return nil end

    local best, best_dot, best_d = nil, 0.72, math.huge
    for _, record in ipairs(horses()) do
        if not record.tamed and valid(record.game_object) then
            local hp = universal_pos(record.game_object)
            local pd = hp and distance(player_pos, hp) or math.huge
            if hp and pd <= (tonumber(max_distance) or 9.0) then
                local dx, dz = hp.x - cam_pos.x, hp.z - cam_pos.z
                local dl = math.sqrt(dx * dx + dz * dz)
                if dl > 0.05 then
                    local dot = (dx / dl) * cfx + (dz / dl) * cfz
                    if dot >= 0.72
                        and (dot > best_dot + 0.03
                            or (math.abs(dot - best_dot) <= 0.03
                                and pd < best_d)) then
                        best, best_dot, best_d = record, dot, pd
                    end
                end
            end
        end
    end
    return best
end

local function horse_speed(record)
    -- The Wild Horses module tracks smoothed speed; read it if present.
    local module_state = rawget(_G, "__iris_wild_horses_v1")
    local address = object_address(record.game_object)
    local state = module_state and address
        and module_state.horses and module_state.horses[tostring(address)]
    return state and state.smoothed_speed or 0
end

local function pad_button_down(want_mask)
    local pressed = false
    pcall(function()
        local hid = sdk.get_native_singleton("via.hid.GamePad")
        local hid_type = sdk.find_type_definition("via.hid.GamePad")
        if not (hid and hid_type) then return end
        local device = sdk.call_native_func(hid, hid_type, "get_MergedDevice")
        if not device then
            pcall(function()
                device = sdk.call_native_func(
                    hid, hid_type, "getMergedDevice(System.UInt32)", 0)
            end)
        end
        local mask = device and tonumber(device:call("get_Button")) or 0
        pressed = (mask & want_mask) ~= 0
    end)
    return pressed
end

local function grab_pressed()
    local pressed = false
    pcall(function()
        pressed = iris_kb(GRAB_KEY)
    end)
    if pressed then return true end
    return pad_button_down(GAMEPAD_GRAB_MASK)
end

local function keyboard_grab_pressed()
    local pressed = false
    pcall(function() pressed = iris_kb(GRAB_KEY) end)
    return pressed
end

-- 07-24 griffin dismount ask: on the griffin, RT must NOT dismount (it
-- collides with the griffin mod's own control flow) — L3 does, matching
-- that mod's language. 0x1000 = L3 (the griffin mod's own mask).
local function l3_pressed()
    return pad_button_down(0x1000)
end

-- ---------------------------------------------------------------------------
-- Rider hold (transform-drive: the future mount attachment)
-- ---------------------------------------------------------------------------

local function find_seat_joint(horse_go)
    local transform = nil
    pcall(function() transform = horse_go:call("get_Transform") end)
    if not transform then return nil end
    for _, name in ipairs(SEAT_JOINTS) do
        local joint = nil
        pcall(function() joint = transform:call("getJointByName", name) end)
        if joint then return joint end
    end
    return nil
end

local function seat_universal(ride)
    -- JOINT-anchored seat: tracks the ANIMATED body, so bucks genuinely toss
    -- the rider. Safe now because calm phases freeze the buck clip at frame
    -- 0 — the old float was the clip parking on its leap-apex final frame,
    -- stranding the joint (and the rider) mid-air. Root fallback if the
    -- joint is missing. Joint positions are RENDER space; rebase to
    -- universal via the horse's own render/universal pair.
    local horse_universal = universal_pos(ride.horse_go)
    local horse_render = render_pos(ride.horse_go)
    if not horse_universal then return nil end
    local x, y, z
    local jx, jy, jz = nil, nil, nil
    if ride.seat_joint and horse_render then
        pcall(function()
            local p = ride.seat_joint:call("get_Position")
            jx, jy, jz = p.x, p.y, p.z
        end)
    end
    if jx ~= nil then
        x = jx - horse_render.x + horse_universal.x
        y = jy - horse_render.y + horse_universal.y + C.seat_above_joint
        z = jz - horse_render.z + horse_universal.z
    else
        x = horse_universal.x
        y = horse_universal.y + C.seat_up
        z = horse_universal.z
    end
    pcall(function()
        local transform = ride.horse_go:call("get_Transform")
        local rot = transform:call("get_Rotation")
        -- forward = rotate (0,0,1) by rot (quaternion sandwich, y-up yaw ok)
        local qx, qy, qz, qw = rot.x, rot.y, rot.z, rot.w
        local fx = 2 * (qx * qz + qw * qy)
        local fz = 1 - 2 * (qx * qx + qy * qy)
        x = x + fx * C.seat_fwd
        z = z + fz * C.seat_fwd
        -- lateral fit: right = up x forward = (fz, 0, -fx)
        local side = C.seat_side or 0.0
        x = x + fz * side
        z = z - fx * side
    end)
    return x, y, z
end

-- seat orientation trim: the Wilds pose was authored against the griffin
-- saddle root — on the horse the rider needs yaw/pitch/roll correction,
-- composed onto the horse's rotation each pin
local function quat_mul(a, b)
    return {
        w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
        x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
    }
end

-- rotate vector by quaternion: v' = v + w*t + q.xyz x t, t = 2*(q.xyz x v)
local function quat_rot(q, vx, vy, vz)
    local x, y, z, w = q.x, q.y, q.z, q.w
    local tx = 2 * (y * vz - z * vy)
    local ty = 2 * (z * vx - x * vz)
    local tz = 2 * (x * vy - y * vx)
    return vx + w * tx + (y * tz - z * ty),
           vy + w * ty + (z * tx - x * tz),
           vz + w * tz + (x * ty - y * tx)
end

-- Aurora's field-tuned pose fits (FINAL 07-24, screenshotted) = the
-- DEFAULTS. A saved config still wins; a fresh install starts here.
local SEAT_DEFAULTS = {
    seat_above_joint_calm = -0.600, seat_fwd_calm = -0.288,
    seat_side_calm = 0.168, seat_yaw_calm = -26.507,
    seat_pitch_calm = 23.425, seat_roll_calm = -0.616,
    hand_grip_width_calm = 0.035, hand_grip_up_calm = 0.100,
    hand_grip_fwd_calm = 0.172,
    leg_pitch_L_calm = -3.699, leg_splay_L_calm = 8.168,
    leg_knee_L_calm = 7.397,
    leg_pitch_R_calm = -22.192, leg_splay_R_calm = -0.308,
    leg_knee_R_calm = 0.0,
    seat_above_joint_active = -0.690, seat_fwd_active = -0.278,
    seat_side_active = -0.026, seat_yaw_active = -17.877,
    seat_pitch_active = 3.083, seat_roll_active = -7.397,
    hand_grip_width_active = 0.108, hand_grip_up_active = 0.378,
    hand_grip_fwd_active = 0.157,
    leg_pitch_L_active = 13.151, leg_splay_L_active = 12.483,
    leg_knee_L_active = 0.0,
    leg_pitch_R_active = 17.260, leg_splay_R_active = 6.627,
    leg_knee_R_active = 10.274,
    -- griffin experiment starting guesses (its back is far taller/wider)
    seat_above_joint_griffin = 0.5, seat_fwd_griffin = 0.0,
    hand_grip_width_griffin = 0.35, hand_grip_up_griffin = 0.1,
    hand_grip_fwd_griffin = 0.2,
    -- griffin follow smoothing (07-24 "animating like mad"): soften the
    -- thrash; 0 = raw follow. Horse variants default 0 (own clips).
    seat_follow_smooth_griffin = 0.15,
    -- griffin camera = the probe's proven framing (11/4/2.5 = 3/4 angle
    -- outside the wing volume; cures the occlusion fade-to-black)
    mountcam_dist_griffin = 11.0, mountcam_height_griffin = 4.0,
    mountcam_side_griffin = 2.5, mountcam_look_up_griffin = 2.0,
    -- 08-13 PANTHER FIT: ch223001's spine sits markedly higher and further
    -- back inside the enlarged mesh than ch223000's.  Falling through to the
    -- horse/Shadow fit left the Arisen crouched on top of the shoulders.  Cat
    -- identity now comes from the stable species record, not the shared live
    -- ch223 chassis, so this correction cannot move Shadow with it.
    -- -1.08 was the first screenshot fit and overcorrected: Mia swallowed
    -- the rider from the waist down. Raise the neutral fit by 30 cm; the
    -- species-only sliders below remain authoritative for fine adjustment.
    seat_above_joint_wyrm_cat = -0.78,
    seat_fwd_wyrm_cat = -0.08,
    seat_side_wyrm_cat = -0.026,
    seat_yaw_wyrm_cat = -17.877,
    seat_pitch_wyrm_cat = 3.083,
    seat_roll_wyrm_cat = -2.772,
    hand_grip_up_wyrm_cat = 0.12,
    hand_grip_fwd_wyrm_cat = 0.30,
    hand_grip_width_wyrm_cat = 0.18,
}

-- VARIANT-AWARE seat config (07-24 Aurora: separate positioning for the
-- static and the animated pose — they sit differently). Key resolution:
-- saved <key>_<calm|active> -> Aurora's tuned default -> legacy <key>
-- -> caller default.
-- griffin ride-state sub-variants (07-24 ROUND-11 Aurora: "different mount
-- position for flying vs grounded" + "animated pose for ground sprint"):
-- gground (idle/walk), gflight (airborne), gsprint (ground run = animated
-- loop). Each INHERITS the _griffin base tuning until its own slider is
-- moved, so a fresh install has all three sitting at the griffin guess.
local GRIFFIN_SUBVARIANTS = {gground = true, gflight = true, gsprint = true}

local function seat_cfg(key, default)
    local seat = S.costume and S.costume.seat
    local variant = (seat and seat.pose_variant) or "calm"
    if S.costume and S.costume.passenger_only then
        -- griffin tuning NEVER touches the horse's. Sub-variant first,
        -- then the shared _griffin base, then the bare key.
        if not GRIFFIN_SUBVARIANTS[variant] then variant = "gground" end
        for _, vk in ipairs({key .. "_" .. variant, key .. "_griffin"}) do
            local v = C[vk]
            if v == nil then v = SEAT_DEFAULTS[vk] end
            if v ~= nil then return tonumber(v) or default end
        end
        local base = C[key]
        if base == nil then return default end
        return tonumber(base) or default
    end
    -- ⭐ 08-13 WYRM (Aurora: "sliders for the cat positioning, the arms need to come
    -- down"): wyrm tuning NEVER touches the horse's - saved <key>_wyrm wins; until a
    -- wyrm slider moves, it inherits the horse's resolved value as the starting guess
    -- (the griffin sub-variant inheritance pattern). Covers the SEAT and the HAND
    -- MAGNET alike (hand_grip_up/fwd/width resolve through here).
    if S.costume and S.costume.wyrm_kind then
        -- 08-13 PER-SPECIES SEAT (Aurora: "if they both adjust the same way one will
        -- break the other"): <key>_wyrm_wolf / <key>_wyrm_cat win; the old shared
        -- <key>_wyrm (her wolf tune) is the fallback so nothing she set is lost.
        local species_key = key .. "_wyrm_" .. tostring(S.costume.wyrm_kind)
        local wv = C[species_key]
        -- A species default must beat the old shared fallback. Otherwise an
        -- old wolf tune silently becomes the cat tune on every existing save.
        if wv == nil then wv = SEAT_DEFAULTS[species_key] end
        if wv == nil then wv = C[key .. "_wyrm"] end
        if wv == nil then wv = SEAT_DEFAULTS[key .. "_wyrm"] end
        if wv ~= nil then return tonumber(wv) or default end
    end
    -- r52 (Aurora: "if we're using the non-static ride pose for calm
    -- we need to use the same sliders" -- the calm offsets were tuned
    -- for the NEUTRAL clip's body; painting the loop body with them
    -- perches her on the neck): while calm rides the loop clip, calm
    -- resolves the ACTIVE sliders too. One clip, one tuning, one seat.
    if variant == "calm" and C.calm_use_loop ~= false then
        variant = "active"
    end
    local vkey = key .. "_" .. variant
    local value = C[vkey]
    if value == nil then value = SEAT_DEFAULTS[vkey] end
    if value == nil then value = C[key] end
    if value == nil then return default end
    return tonumber(value) or default
end

local function seat_trim_rotation(horse_rot)
    local yaw = math.rad(seat_cfg("seat_yaw", 0.0))
    local pitch = math.rad(seat_cfg("seat_pitch", 0.0))
    local roll = math.rad(seat_cfg("seat_roll", 0.0))
    local q = {w = horse_rot.w, x = horse_rot.x,
               y = horse_rot.y, z = horse_rot.z}
    if yaw ~= 0 then
        q = quat_mul(q, {w = math.cos(yaw * 0.5), x = 0,
                         y = math.sin(yaw * 0.5), z = 0})
    end
    if pitch ~= 0 then
        q = quat_mul(q, {w = math.cos(pitch * 0.5),
                         x = math.sin(pitch * 0.5), y = 0, z = 0})
    end
    if roll ~= 0 then
        q = quat_mul(q, {w = math.cos(roll * 0.5), x = 0, y = 0,
                         z = math.sin(roll * 0.5)})
    end
    return q
end

-- PASSENGER SADDLE BASIS (07-24 "the griffin idle moves constantly"):
-- a LIVE body animates its whole spine during idle — wing flares, head
-- lurches, weight shifts — so a flat body-yaw seat frame shears the
-- rider off the back the moment the animation sweeps. Build the seat
-- frame from the animated spine ITSELF (the griffin mod's proven saddle
-- basis: fwd = Spine_1 -> Spine_3 along the back): yaw + pitch follow
-- the idle, offsets ride the back, the rider tilts WITH the body. This
-- is the thing the old griffin attempt could never do — back then the
-- live FSM fought every rider write; a full puppet has no co-author.
local function seat_saddle_basis(horse_tf)
    local a, b = nil, nil
    pcall(function()
        local ja = horse_tf:call("getJointByName", "Spine_1")
        local jb = horse_tf:call("getJointByName", "Spine_3")
        a = ja and ja:call("get_Position")
        b = jb and jb:call("get_Position")
    end)
    if not (a and b) then return nil end
    local fx = (tonumber(b.x) or 0) - (tonumber(a.x) or 0)
    local fy = (tonumber(b.y) or 0) - (tonumber(a.y) or 0)
    local fz = (tonumber(b.z) or 0) - (tonumber(a.z) or 0)
    local fl = math.sqrt(fx * fx + fy * fy + fz * fz)
    if fl < 1e-4 then return nil end
    fx, fy, fz = fx / fl, fy / fl, fz / fl
    -- ROLL v2 (07-24 "animating like mad still misplaces her"): side
    -- axis from a L/R joint pair — LEGS first (steadier than flapping
    -- wings), wings fallback; the griffin mod's proven saddle frame,
    -- flip-guard and all. No pair readable = flat right (the old
    -- yaw+pitch behavior).
    local rx, ry, rz = nil, nil, nil
    pcall(function()
        for _, pair in ipairs({{"L_Leg_Upper", "R_Leg_Upper"},
                               {"L_Arm_Upper", "R_Arm_Upper"}}) do
            local jl = horse_tf:call("getJointByName", pair[1])
            local jr = horse_tf:call("getJointByName", pair[2])
            local pl = jl and jl:call("get_Position")
            local pr = jr and jr:call("get_Position")
            if pl and pr then
                local dx = (tonumber(pr.x) or 0) - (tonumber(pl.x) or 0)
                local dy = (tonumber(pr.y) or 0) - (tonumber(pl.y) or 0)
                local dz = (tonumber(pr.z) or 0) - (tonumber(pl.z) or 0)
                local dl = math.sqrt(dx * dx + dy * dy + dz * dz)
                if dl > 0.05 then
                    rx, ry, rz = dx / dl, dy / dl, dz / dl
                    break
                end
            end
        end
    end)
    local ux, uy, uz
    if rx then
        ux = fy * rz - fz * ry -- up = fwd x right
        uy = fz * rx - fx * rz
        uz = fx * ry - fy * rx
        if uy < 0.0 then -- swapped/odd pair: never seat her upside down
            rx, ry, rz = -rx, -ry, -rz
            ux, uy, uz = -ux, -uy, -uz
        end
    else
        rx = fz -- right = world-up x fwd (flat, no roll)
        ry = 0.0
        rz = -fx
        local rl = math.sqrt(rx * rx + rz * rz)
        if rl < 1e-4 then return nil end
        rx, rz = rx / rl, rz / rl
        ux = fy * rz - fz * ry
        uy = fz * rx - fx * rz
        uz = fx * ry - fy * rx
    end
    local ul = math.sqrt(ux * ux + uy * uy + uz * uz)
    if ul < 1e-4 then return nil end
    ux, uy, uz = ux / ul, uy / ul, uz / ul
    rx = uy * fz - uz * fy -- re-orthonormalize right = up x fwd
    ry = uz * fx - ux * fz
    rz = ux * fy - uy * fx
    -- columns (right, up, fwd) -> quaternion (standard 4-branch)
    local m11, m12, m13 = rx, ux, fx
    local m21, m22, m23 = ry, uy, fy
    local m31, m32, m33 = rz, uz, fz
    local tr = m11 + m22 + m33
    local qw, qx, qy2, qz2
    if tr > 0.0 then
        local s = math.sqrt(tr + 1.0) * 2.0
        qw = 0.25 * s
        qx = (m32 - m23) / s
        qy2 = (m13 - m31) / s
        qz2 = (m21 - m12) / s
    elseif m11 > m22 and m11 > m33 then
        local s = math.sqrt(1.0 + m11 - m22 - m33) * 2.0
        qw = (m32 - m23) / s
        qx = 0.25 * s
        qy2 = (m12 + m21) / s
        qz2 = (m13 + m31) / s
    elseif m22 > m33 then
        local s = math.sqrt(1.0 + m22 - m11 - m33) * 2.0
        qw = (m13 - m31) / s
        qx = (m12 + m21) / s
        qy2 = 0.25 * s
        qz2 = (m23 + m32) / s
    else
        local s = math.sqrt(1.0 + m33 - m11 - m22) * 2.0
        qw = (m21 - m12) / s
        qx = (m13 + m31) / s
        qy2 = (m23 + m32) / s
        qz2 = 0.25 * s
    end
    return {w = qw, x = qx, y = qy2, z = qz2}
end

local function suppress_player_components(player_go)
    -- ⛔ 08-09 r65: this loop used to fail ENTIRELY SILENTLY. A type name that is
    -- not a component on the player GameObject just falls through the `if` and
    -- nothing is disabled, logged, or flagged -- so a suppression can look
    -- installed for weeks while doing nothing (see the RunupToClimbWallController
    -- CTD, which recurred after being "fixed" by adding it to this very list).
    -- One line, once per mount, naming exactly what was found and what was not.
    local hit, miss = {}, {}
    for _, type_name in ipairs(PLAYER_SUPPRESS_COMPONENTS) do
        -- ⭐ 08-09 r68 -- THE PRIME SUSPECT FOR "THE CYCLOPS CANNOT HURT US AND
        -- THERE IS NO BOSS HEALTHBAR". app.HitController is what makes a body a
        -- valid damage TARGET; it has been suppressed on the rider for the whole
        -- ride. With the rider not targetable, the game has no reason to treat
        -- the cyclops as engaged -- which is exactly the missing boss bar -- and
        -- melee has nothing to resolve against.
        -- ⚠ It is in the list for a reason (a seat-pinned rider taking hit
        -- reactions would fight the seat), so this is a SWITCH, not a deletion:
        -- set ride_suppress_player_hitcontroller = false to keep the rider
        -- targetable and see whether the boss bar and the damage come back.
        -- Fall damage is unaffected either way -- it does not route through here,
        -- which is why the fall shield still fired while this was off.
        -- ⭐⭐ r86 -- HITCONTROLLER ALONE IS NOT A HURTBOX. The diag settled the
        -- immunity question (horse=00 rider=00, both mortal) but exposed the
        -- next link: "rider HitCtrl=on Colliders=off". app.HitController decides
        -- what damage DOES; via.physics.Colliders and RequestSetCollider are the
        -- shapes an attack has to actually INTERSECT. With those off the rider
        -- has no body to hit, so enabling HitController changed nothing.
        -- This switch means "the rider is a valid target", so it has to release
        -- all three or it releases nothing useful.
        -- ⚠ Colliders on a seat-pinned rider is what the suppression list was
        -- guarding against (depenetration shoving her off the saddle). If you
        -- start getting nudged around or the seat judders, re-tick the box.
        if C.ride_suppress_player_hitcontroller == false
            and (type_name == "app.HitController"
                or type_name == "via.physics.Colliders"
                or type_name == "via.physics.RequestSetCollider") then
            goto continue_suppress
        end
        do
        local component = get_component(player_go, type_name)
        if not component then miss[#miss + 1] = type_name
        else hit[#hit + 1] = type_name end
        if component then
            local was_enabled = nil
            pcall(function() was_enabled = component:call("get_Enabled") end)
            pcall(function() component:call("set_Enabled", false) end)
            if S.disabled_components[type_name] == nil then
                S.disabled_components[type_name] = {
                    component = component,
                    was_enabled = was_enabled ~= false,
                }
            end
        end
        end
        ::continue_suppress::
    end
    if #miss > 0 then
        log("player suppress: NOT FOUND -> " .. table.concat(miss, ", ")
            .. "  (found " .. #hit .. ")")
    else
        log("player suppress: all " .. #hit .. " components found")
    end
end

local function restore_player_components(defer)
    -- ⭐ 08-09 r75 -- CORRELATION MARKER FOR THE REVIVE CTD.
    -- The pawn theory is dead: the probe reported "pawn ch100000_00 follows
    -- (none)" and cleared ZERO references, so that mitigation never fired and
    -- the one clean revive was luck, not a fix.
    -- The remaining object whose components we demonstrably toggle in that same
    -- window is the PLAYER -- the ride diag shows rider HitCtrl/Colliders going
    -- off on mount and on at dismount, and the crash chain
    -- (ActionInterface -> ... -> MoveBase.updateImpl -> getSameComponent) is
    -- exactly the shape of something reading components off a body mid-toggle.
    -- Timestamp every restore so the next CTD can be lined up against it.
    local names = {}
    for type_name, _ in pairs(S.disabled_components) do
        names[#names + 1] = type_name
    end
    if #names > 0 then
        log("player components RESTORING: " .. table.concat(names, ", ")
            .. (defer and " (deferred set held back)" or ""))
    end
    for type_name, record in pairs(S.disabled_components) do
        if not (defer and defer[type_name]) then
            if valid(record.component) and record.was_enabled then
                pcall(function()
                    record.component:call("set_Enabled", true)
                end)
            end
            S.disabled_components[type_name] = nil
        end
    end
end

-- Keep DD2's safe-coordinate/fall recorder in the same place as the rider.
-- Without this, restoring the CharacterController after a long ride can
-- invoke the stuck-player rescue and return the Arisen to the pre-mount
-- coordinate even though our transform is beside the horse.
local function feed_player_safe_position(x, y, z, reset_history)
    pcall(function()
        local player = player_character()
        local recorder = player
            and player:get_field("<PosRotRecorder>k__BackingField")
        local pgo = player_game_object()
        local tf = pgo and pgo:call("get_Transform")
        if not (recorder and tf) then return end
        if reset_history then
            pcall(function() recorder:call("resetHistory") end)
        end
        local pos = ValueType.new(sdk.find_type_definition("via.Position"))
        pos.x, pos.y, pos.z = x, y, z
        local rot = tf:call("get_Rotation")
        pcall(function() recorder:call("set_IsSafeCoord", true) end)
        local wrote = pcall(function()
            recorder:call("recordPosRotExternal", pos, rot)
        end)
        if not wrote then
            pcall(function() recorder:call("recordPosRot", pos, rot) end)
        end
        pcall(function()
            recorder:set_field("PosAfterReviveFromFallDead",
                Vector3f.new(x, y, z))
            recorder:set_field("IsAfterReviveFromFallDead", false)
        end)
        pcall(function()
            local landing = recorder:get_field("LandingProcessor")
            if not landing then return end
            local ground = landing:call("get_LastGroundPosition")
            if ground then
                ground.x, ground.y, ground.z = x, y - 0.1, z
                landing:call("set_LastGroundPosition", ground)
            end
            landing:call("resetFallingStuckStopperToCurrentPosition")
            local fall = landing:get_field("FallInfo")
            if fall then
                fall:call("resetFallHeight")
                fall:call("set_FallHeight", 0.0)
            end
        end)
    end)
end

local function remember_mount_safe_ground(costume, x, y, z)
    if not S.ride_pose_on then return end
    local now = os.clock()
    local wet = S.mount_water_cached == true
    if now >= (tonumber(S.mount_water_check_at) or 0.0) then
        S.mount_water_check_at = now + 0.25
        wet = false
        pcall(function()
            local detector = rawget(_G, "griffin_downed_in_water")
            wet = detector and detector(costume.horse_go) == true or false
        end)
        S.mount_water_cached = wet
    end
    if wet then return end
    local next_safe = { x = x, y = y, z = z, at = now }
    local old = S.mount_last_safe_ground
    -- Do not immediately bless the seabed (or the bottom of a cliff) after a
    -- large drop. Ordinary downhill travel changes by centimetres per frame and
    -- remains current; a discontinuous lower surface must stay stable for two
    -- seconds before it can replace the recovery point.
    if old and y < (tonumber(old.y) or y) - 1.25 then
        local c = S.mount_safe_candidate
        local near = c and math.abs((tonumber(c.y) or y) - y) < 0.75
        if not near then
            S.mount_safe_candidate = {
                x = x, y = y, z = z, since = now,
            }
            return
        end
        c.x, c.y, c.z = x, y, z
        if now - (tonumber(c.since) or now) < 2.0 then return end
    end
    S.mount_last_safe_ground = next_safe
    S.mount_safe_candidate = nil
end

local function freeze_player_pose(player_go)
    -- Pose bridge first (Wilds ride pose); motion-freeze fallback.
    local posed = false
    if C.use_wilds_pose then
        pcall(function()
            local pose = rawget(_G, "NB_Pose")
            if pose and type(pose.play) == "function" then
                posed = pose.play(
                    "rs_wilds_ride_neutral", "Arisen", "Full", true, 1.0, true)
                    ~= false
            end
        end)
    end
    if posed then return "wilds_pose" end
    pcall(function()
        local character = get_component(player_go, "app.Character")
        local motion = character and character:call("get_Motion")
        if motion then motion:call("set_PlaySpeed", 0.0) end
    end)
    return "motion_freeze"
end

local function unfreeze_player_pose(player_go, mode)
    if mode == "wilds_pose" then
        pcall(function()
            local pose = rawget(_G, "NB_Pose")
            if pose and type(pose.stop) == "function" then pose.stop() end
        end)
    end
    pcall(function()
        local character = get_component(player_go, "app.Character")
        local motion = character and character:call("get_Motion")
        if motion then motion:call("set_PlaySpeed", 1.0) end
    end)
end

local function write_player_seat(ride)
    local x, y, z = seat_universal(ride)
    if not x then return false end
    local ok = false
    pcall(function()
        local transform = ride.player_go:call("get_Transform")
        local position = transform:call("get_UniversalPosition")
        position.x, position.y, position.z = x, y, z
        transform:call("set_UniversalPosition", position)
        ok = true
    end)
    return ok
end

-- One-shot coordinate diagnostic: every space the seat math touches, dumped
-- so a wrong-space term is visible as a ~10m mismatch in the numbers.
local function dump_seat_spaces(ride)
    local diag = {}
    pcall(function()
        local hu = universal_pos(ride.horse_go)
        local hr = render_pos(ride.horse_go)
        diag.horse_universal = hu and {hu.x, hu.y, hu.z}
        diag.horse_render = hr and {hr.x, hr.y, hr.z}
    end)
    pcall(function()
        if ride.seat_joint then
            local p = ride.seat_joint:call("get_Position")
            diag.joint_get_position = {p.x, p.y, p.z}
        end
    end)
    pcall(function()
        local pu = universal_pos(ride.player_go)
        local pr = render_pos(ride.player_go)
        diag.player_universal = pu and {pu.x, pu.y, pu.z}
        diag.player_render = pr and {pr.x, pr.y, pr.z}
    end)
    local x, y, z = seat_universal(ride)
    diag.computed_seat_universal = x and {x, y, z}
    pcall(function() json.dump_file("IrisRodeo_seat_diag.json", diag) end)
    log(string.format(
        "seat diag: horse_uni_y=%.2f horse_ren_y=%.2f joint_y=%.2f seat_y=%.2f player_uni_y=%.2f",
        diag.horse_universal and diag.horse_universal[2] or -999,
        diag.horse_render and diag.horse_render[2] or -999,
        diag.joint_get_position and diag.joint_get_position[2] or -999,
        y or -999,
        diag.player_universal and diag.player_universal[2] or -999))
end

-- ---------------------------------------------------------------------------
-- Horse control during the rodeo
-- ---------------------------------------------------------------------------

local function set_think_stop(character, value)
    pcall(function() character:call("set_IsThinkStop", value == true) end)
end

local function set_horse_fsm(horse_go, enabled)
    pcall(function()
        local fsm = get_component(horse_go, "via.motion.MotionFsm2")
        if fsm then fsm:call("set_Enabled", enabled == true) end
    end)
end

local function play_horse_clip(ride, bank, id)
    pcall(function()
        local character = get_component(ride.horse_go, "app.Character")
        local motion = character and character:call("get_Motion")
        local layer = motion and motion:call("getLayer", 0)
        if layer then
            layer:call(
                "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                bank, id, 0.0, 0.35, 1, 1)
            layer:call("set_Speed", 1.0)
        end
    end)
end

local function kick_horse_yaw(ride, degrees)
    pcall(function()
        local transform = ride.horse_go:call("get_Transform")
        local rot = transform:call("get_Rotation")
        local half = math.rad(degrees) * 0.5
        local sy, cy = math.sin(half), math.cos(half)
        -- multiply rot by yaw quaternion (0, sy, 0, cy)
        local x = rot.w * 0 + rot.x * cy + rot.y * 0 - rot.z * sy
        local y = rot.w * sy - rot.x * 0 + rot.y * cy + rot.z * 0
        local z = rot.w * 0 + rot.x * sy - rot.y * 0 + rot.z * cy
        local w = rot.w * cy - rot.x * 0 - rot.y * sy - rot.z * 0
        rot.x, rot.y, rot.z, rot.w = x, y, z, w
        transform:call("set_Rotation", rot)
        -- kicks must persist through the per-tick anchor reassert
        if S.ride then S.ride.anchor_rot = rot end
    end)
end

local function play_horse_sound(category, horse_go)
    pcall(function()
        local api = rawget(_G, AUDIO_API_KEY)
        if api and type(api.play_category) == "function" then
            api.play_category(category, horse_go)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- GRAFT v2 (the MANUAL RIG, Aurora's call): build the climb rig on the
-- horse at runtime with EVERY field populated in the same Lua frame — the
-- one graft form the crash law permits (the old CTD was the EMPTY variant).
-- Typedefs dump proved full public setters exist:
--   SkinningMeshInfo.set_SkinningMesh(CollisionSkinningMeshResourceHolder)
--   SkinningMeshInfo.set_Filter(CollisionFilterResourceHolder)
--   Set.setSkinningMeshInfosCount/setSkinningMeshInfos
--   Holder.setupColliders()/addCollider(...)  Checker.set_Chara(...)
-- ---------------------------------------------------------------------------

local GRAFT_CLSM = "Character/ch/ch99_003/ch99_003_00.clsm"
local GRAFT_CFIL = "Config/Collision/CollisionFilter/Object/ObjectCollisionDefault.cfil"

local GR = {status = "not staged"}
pcall(function()
    local clsm = sdk.create_resource(
        "via.physics.CollisionSkinningMeshResource", GRAFT_CLSM)
    if clsm then
        GR.clsm_holder = clsm:create_holder(
            "via.physics.CollisionSkinningMeshResourceHolder")
        if GR.clsm_holder then GR.clsm_holder:add_ref() end
    end
    local cfil = sdk.create_resource(
        "via.physics.CollisionFilterResource", GRAFT_CFIL)
    if cfil then
        GR.cfil_holder = cfil:create_holder(
            "via.physics.CollisionFilterResourceHolder")
        if GR.cfil_holder then GR.cfil_holder:add_ref() end
    end
    GR.status = string.format("staged clsm=%s cfil=%s",
        tostring(GR.clsm_holder ~= nil), tostring(GR.cfil_holder ~= nil))
end)

local function graft_v2(horse_go)
    if not valid(horse_go) then return false, "no horse" end
    if not (GR.clsm_holder and GR.cfil_holder) then
        return false, "resources not staged: " .. tostring(GR.status)
    end
    local steps = {}
    local function step(tag, fn)
        local ok, err = pcall(fn)
        steps[#steps + 1] = tag .. (ok and "" or ("!" .. tostring(err)))
        return ok
    end

    -- 1. the Info valuetype, fully populated BEFORE anything consumes it
    local info = nil
    step("info", function()
        info = sdk.create_instance(
            "via.physics.SkinningMeshColliderSet.SkinningMeshInfo")
        if not info then error("instance nil") end
        info = info:add_ref()
        info:call("set_SkinningMesh", GR.clsm_holder)
        info:call("set_Filter", GR.cfil_holder)
    end)
    if not info then return false, table.concat(steps, " ") end

    -- 2. the Set, populated in the SAME frame it is born (ADOPT an existing
    -- one first — grafts survive script resets, createComponent returns nil
    -- for a component that already exists)
    local set_component = nil
    step("set", function()
        set_component = get_component(
            horse_go, "via.physics.SkinningMeshColliderSet")
        if not set_component then
            set_component = horse_go:call(
                "createComponent(System.Type)",
                sdk.typeof("via.physics.SkinningMeshColliderSet"))
        end
        if not set_component then error("createComponent nil") end
        set_component:call("setSkinningMeshInfosCount", 1)
        set_component:call(
            "setSkinningMeshInfos(System.UInt64, via.physics.SkinningMeshColliderSet.SkinningMeshInfo)",
            0, info)
        set_component:call("set_Update", true)
        set_component:call("set_Enabled", true)
    end)

    -- ⛔ HOLDER = UNGRAFTABLE BY CONSTRUCTION (v2.2 autopsy: the
    -- createComponent call ITSELF throws — "Exception thrown in
    -- REMethodDefinition::invoke for via.GameObject.createComponent" then
    -- AV at the same RIP as v2. Its constructor demands context that can
    -- never be pre-populated. Do not re-attempt.)
    -- The climb route for a grafted horse is the REQUEST LATCH instead
    -- (proven on the ghost): surface + set_RequestClimbTarget/startClimb.

    GR.grafted_go = horse_go
    GR.set_component = set_component
    S.graft_rig = true
    local report = table.concat(steps, " ")
    -- readbacks on the surface itself
    pcall(function()
        report = report .. " | infosCount="
            .. tostring(set_component:call("getSkinningMeshInfosCount"))
        report = report .. " | enabled="
            .. tostring(set_component:call("get_CurrentEnabled"))
    end)
    log("GRAFT v2.1 minimal: " .. report)
    return true, report
end

-- ---------------------------------------------------------------------------
-- GHOST RIG (plan D): an invisible donor monster with a real authored climb
-- rig, pinned inside the horse. The player native-climbs the ghost while
-- visually riding the horse. Unlike the component graft (CTD, retired),
-- the donor's rig is fully authored prefab data — law-compliant borrowing.
-- ---------------------------------------------------------------------------

local function bind_ghost_rig()
    local player_pos = universal_pos(player_game_object())
    if not player_pos then
        S.status = "ghost bind: no player position"
        return
    end
    local best, best_d, best_id = nil, 35, nil
    pcall(function()
        local scene_manager = sdk.get_native_singleton("via.SceneManager")
        local scene_type = sdk.find_type_definition("via.SceneManager")
        local scene = sdk.call_native_func(
            scene_manager, scene_type, "get_CurrentScene()")
        local characters = scene and scene:call(
            "findComponents(System.Type)", sdk.typeof("app.Character"))
        local elements = {}
        pcall(function() elements = characters:get_elements() end)
        for _, character in ipairs(elements) do
            local id = ""
            pcall(function()
                id = tostring(character:call("get_CharaIDString"))
            end)
            -- any monster that is not our horse/wolf-family creatures
            if id:match("^ch2") and not id:match("^ch299011")
                and not id:match("^ch223") then
                local game_object = nil
                pcall(function()
                    game_object = character:call("get_GameObject")
                end)
                if valid(game_object) then
                    local d = distance(player_pos, universal_pos(game_object))
                    if d < best_d then
                        best, best_d, best_id = {
                            go = game_object, character = character,
                        }, d, id
                    end
                end
            end
        end
    end)
    if not best then
        S.status = "ghost bind: no monster within 35m (spawn a garm first)"
        return
    end
    -- Hide it and switch off its decision-making (NOT think-stop — the
    -- climb needs its motion systems alive).
    pcall(function()
        local mesh = get_component(best.go, "via.render.Mesh")
        if mesh then mesh:call("set_Enabled", false) end
    end)
    pcall(function()
        local ai = get_component(best.go, "app.AIDecisionMaker")
        if ai then ai:call("set_Enabled", false) end
    end)
    pcall(function()
        local hate = get_component(best.go, "app.HateSystem")
        if hate then hate:call("clearAllHate") end
    end)
    -- Strip its PUSH physics (two solid hulls in the same space = the horse
    -- ice-skates into the lake). Keep SkinningMeshColliderSet — that IS the
    -- climbing surface.
    best.stripped = {}
    best.strip_report = {}
    for _, type_name in ipairs({
        -- Pushers off permanently. RequestSetCollider = THE SWITCH: it is
        -- both the push source and the climb surface, so it turns ON only
        -- during a ride and OFF while idle — the ghost stays co-located
        -- with the horse at all times (parking anywhere = teleport hazard:
        -- late-consumed latches dragged Aurora into the sky / the void).
        "via.physics.CharacterController",
        "app.AdjustPress",
        "app.AdjustTerrain",
        -- ⛔ RSC/Colliders/skinning must STAY ENABLED: disabling them
        -- FREEZES their registered shapes at the spawn spot (07-22/23 —
        -- climb latched the frozen shell, push haunted the spawn zone, and
        -- the pinned ghost carried no live surface at all). The push is
        -- killed surgically via RSC set_DisableLayerBits instead (lab knob).
    }) do
        local hit = false
        pcall(function()
            local component = get_component(best.go, type_name)
            if component then
                component:call("set_Enabled", false)
                best.stripped[#best.stripped + 1] = component
                hit = true
            end
        end)
        best.strip_report[#best.strip_report + 1] =
            type_name .. (hit and " = OFF" or " = MISSING")
    end
    pcall(function()
        best.rsc = get_component(best.go, "via.physics.RequestSetCollider")
    end)
    pcall(function()
        best.colliders = get_component(best.go, "via.physics.Colliders")
    end)
    -- NO layer mask at bind (07-23: bit 7 killed the CLIMB along with the
    -- push — the climb layer and press layer overlap or neighbor). Climb
    -- comes first; the push gets solved pair-wise via RSC ignore tags.
    pcall(function()
        if best.rsc then
            best.rsc:call("set_DisableLayerBits", 0)
            best.layer_bit = 0
        end
    end)
    -- The horse must ignore the ghost's colliders: disable ITS press
    -- response while a ghost is bound (restored on release).
    local horse_record = horses()[1]
    if horse_record then
        pcall(function()
            local press = get_component(
                horse_record.game_object, "app.AdjustPress")
            if press then
                press:call("set_Enabled", false)
                best.horse_press = press
            end
        end)
    end
    best.id = best_id
    best.strip_report[#best.strip_report + 1] = "donor = " .. tostring(best_id)
    -- if pushing persists, list EVERY physics-ish component still alive on
    -- the donor — the un-stripped pusher will be in this list
    pcall(function()
        local components = best.go:call("get_Components")
        local n = components and components:call("get_Count") or 0
        for i = 0, n - 1 do
            local comp = components:call("get_Item", i)
            local tname = ""
            pcall(function()
                tname = comp:get_type_definition():get_full_name()
            end)
            if tname:find("hysic") or tname:find("[Cc]ollid")
                or tname:find("[Pp]ress") or tname:find("[Tt]errain")
                or tname:find("[Cc]ontroller") then
                local enabled = "?"
                pcall(function()
                    enabled = tostring(comp:call("get_Enabled"))
                end)
                best.strip_report[#best.strip_report + 1] =
                    "alive: " .. tname .. " enabled=" .. enabled
            end
        end
    end)
    pcall(function()
        json.dump_file("GhostBindReport.json", best.strip_report)
    end)
    S.ghost = best
    S.status = "ghost rig bound: " .. tostring(best_id)
        .. " (invisible, pinned to the horse)"
    log(S.status)
end

local function release_ghost_rig()
    local ghost = S.ghost
    S.ghost = nil
    if not (ghost and valid(ghost.go)) then return end
    pcall(function()
        local mesh = get_component(ghost.go, "via.render.Mesh")
        if mesh then mesh:call("set_Enabled", true) end
    end)
    pcall(function()
        local ai = get_component(ghost.go, "app.AIDecisionMaker")
        if ai then ai:call("set_Enabled", true) end
    end)
    for _, component in ipairs(ghost.stripped or {}) do
        pcall(function() component:call("set_Enabled", true) end)
    end
    if ghost.horse_press then
        pcall(function() ghost.horse_press:call("set_Enabled", true) end)
    end
    S.status = "ghost rig released"
end

-- Place the player FLUSH on the ghost's back joint (the griffin mount law:
-- root-level placement never latches; the climb wants surface contact).
local function place_player_on_ghost(player_go)
    local ghost = S.ghost
    if not (ghost and valid(ghost.go)) then return false end
    local placed = false
    pcall(function()
        local ghost_tf = ghost.go:call("get_Transform")
        local joint = nil
        for _, name in ipairs(SEAT_JOINTS) do
            pcall(function()
                joint = joint or ghost_tf:call("getJointByName", name)
            end)
        end
        local target = ghost_tf:call("get_UniversalPosition")
        if joint then
            local jp = joint:call("get_Position")
            local ghost_render = ghost_tf:call("get_Position")
            target.x = jp.x - ghost_render.x + target.x
            target.y = jp.y - ghost_render.y + target.y + 0.25
            target.z = jp.z - ghost_render.z + target.z
        else
            target.y = target.y + 1.2
        end
        local player_tf = player_go:call("get_Transform")
        player_tf:call("set_UniversalPosition", target)
        placed = true
    end)
    return placed
end

-- Pin the ghost to the horse (or PARKED 60m below it while idle — its climb
-- colliders are solid, and a live horse's CharacterController gets shoved by
-- them no matter whose press is off; underground they can't meet).
-- COSTUME RIG (07-23, the inversion): the ox stays 100% NATIVE (climbable,
-- alive, untouched); the HORSE becomes the ghost — think-stopped, CC off
-- (both proven calls), visual pinned onto the ox every frame. No physics
-- fight is possible because the only real body is an unmodified ox.
-- OX SHIELD (07-23 empirical law: set_IsInvincible on the HitController
-- GATES grab/climb consent — an invincible body refuses all contact).
-- Immortality instead comes from the wild-horses-proven updateDamageHp
-- pre-hook: the ox stays grabbable, every point of damage zeroes out.
local function costume_ox_ancestor(go)
    local costume = S.costume
    if not costume or not valid(costume.ox_go) then return false end
    local target = costume.ox_go:get_address()
    local current = go
    for _ = 1, 8 do
        if not current then return false end
        if current:get_address() == target then return true end
        local parent = nil
        pcall(function()
            local tf = current:call("get_Transform")
            local ptf = tf and tf:call("get_Parent")
            parent = ptf and ptf:call("get_GameObject")
        end)
        current = parent
    end
    return false
end

-- ⛔⛔⛔ MOUNT CTD ROOT CAUSE (2026-08-09, three crashes, identical fingerprint).
-- This hook used to be installed LAZILY, from the mount path -- the log shows
-- "[HookManager] Adding hook for 'updateDamageHp'" ~375ms before every c0000005, and
-- the crash lands on a WORKER thread inside JIT'd managed code.
-- `app.HitController.updateDamageHp` is combat-hot code that the engine runs constantly,
-- including off the main thread. Installing a hook PATCHES that function's code. Patch it
-- while another thread is mid-execution inside it and you get exactly this AV -- and
-- IrisWildHorses already hooks the same method, so we were also chaining a SECOND hook
-- onto a live one ("Reusing existing hook..." in the log).
-- ⭐ THE LAW: install every sdk.hook ONCE, EARLY, in a quiet moment (load / world-live).
-- NEVER install one from a gameplay action -- a mount, an attack, a menu press. Lazy
-- hooking looks tidy and is a code-patch race against the whole engine.
-- ⚠ pcall cannot catch this either: it is a native AV, not a Lua error.
local OX_SHIELD = {installed = false}
local function install_ox_shield_hook()
    if OX_SHIELD.installed then return end
    local td = sdk.find_type_definition("app.HitController")
    local method = td and td:get_method("updateDamageHp")
    if not method then return end
    OX_SHIELD.installed = true
    sdk.hook(method, function(args)
        pcall(function()
            local hc = sdk.to_managed_object(args[2])
            if not hc then return end
            local go = nil
            pcall(function() go = hc:call("get_GameObject") end)
            if not go then return end
            local shielded = costume_ox_ancestor(go)
            if not shielded then
                -- 07-24 v2 (Aurora: "she shouldn't be invincible — an
                -- aerial attack SHOULD kill her"): no blanket shield
                -- while seated. The fall-kill tick zeroes the fall
                -- bill; this grace covers ONLY the brief post-dismount
                -- restore window.
                if (tonumber(S.player_shield_until) or 0)
                    > os.clock() then
                    local pgo = player_game_object()
                    if pgo and go:get_address() == pgo:get_address() then
                        shielded = true
                    end
                end
            end
            if not shielded then return end
            local info = sdk.to_managed_object(args[3])
            if info then
                for _, field in ipairs({"Damage", "FixedDamage"}) do
                    pcall(function() info:set_field(field, 0) end)
                end
            end
            pcall(function() args[4] = sdk.float_to_ptr(0.0) end)
        end)
    end, function(retval) return retval end)
end

-- ⭐ INSTALL AT LOAD, not at mount (see the law above). The hook body already self-gates
-- on costume state, so arming it early costs nothing while nothing is being ridden --
-- it simply reads "not shielded" and returns. This is the whole fix for the mount CTD.
install_ox_shield_hook()

-- live layer-0 readout (Nick-core/EMV-proven getters): the evidence feed
-- for the gait work — what each body is ACTUALLY playing right now
local function read_layer0(go)
    local out = nil
    pcall(function()
        local character = get_component(go, "app.Character")
        local motion = character and character:call("get_Motion")
        local layer = motion and motion:call("getLayer", 0)
        if not layer then return end
        out = {
            bank = tonumber(layer:call("get_MotionBankID")) or -1,
            id = tonumber(layer:call("get_MotionID")) or -1,
            frame = tonumber(layer:call("get_Frame")) or -1,
            endf = tonumber(layer:call("get_EndFrame")) or -1,
        }
        pcall(function()
            out.speed = tonumber(layer:call("get_Speed"))
        end)
    end)
    return out
end

-- ⭐ 08-18 RUNTIME FOOT-IK RELEASE (work-order field fix, Aurora's jump
-- screenshot): DD2's leg-IK / ground solvers keep planting hooves as if
-- grounded while the scripted ride owns a parked FSM — the engine never
-- learns the body is airborne or posing, so mid-air the legs get yanked
-- toward the ground and fold BACKWARDS, and idles get a re-planted hind
-- leg. Disable every IK-flavoured component for the duration of the hold
-- (the proven ox-gait recipe) and restore on release. Horse-kind only —
-- wyrms play clips authored for their own chassis.
local function horse_ik_set(go, enabled)
    local touched = {}
    pcall(function()
        local comps = go:call("get_Components")
        local n = comps and comps:call("get_Count") or 0
        for i = 0, n - 1 do
            local comp = comps:call("get_Item", i)
            local tname = ""
            pcall(function()
                tname = comp:get_type_definition():get_full_name()
            end)
            if tname:find("[Ii]k") or tname:find("GroundFixer")
                or tname:find("SlopeBody") then
                if pcall(function() comp:call("set_Enabled", enabled) end) then
                    touched[#touched + 1] = tname
                end
            end
        end
    end)
    return touched
end

local function costume_stop()
    local costume = S.costume
    if costume and costume.ik_released and valid(costume.horse_go)
        and not costume.wyrm_kind then
        costume.ik_released = nil
        horse_ik_set(costume.horse_go, true)
        log("ride: horse leg-IK restored")
    end
    -- A release can arrive during the impact wind-up. Retire every owner
    -- before the body/AI handover; no attack callback may retain or move a
    -- just-released mount on the following frame.
    if S.wyrm_native_lease and iris_wyrm_native_bite_finish then
        iris_wyrm_native_bite_finish("mount released")
    end
    S.wyrm_attack, S.wyrm_atk_until = nil, nil
    S.wyrm_atk_hold, S.wyrm_btn_prev = nil, nil
    S.wyrm_native_pending, S.wyrm_native_recover_until = nil, nil
    S.mounted_combat_off = nil
    rawset(_G, "IrisWyrmMounted", nil)
    if costume then costume.force_hold = nil end
    -- Restore the native action interface before handing a persistent tame back
    -- to IrisTaming.  Puppeteer destroys its puppet, so it has no equivalent
    -- hand-back step; our existing companion absolutely does.
    if costume and costume.native_controller_prepared then
        pcall(function()
            local act = costume.native_action_interface
            if act then act:call("set_Enabled",
                costume.native_action_interface_was_enabled ~= false) end
            local fsm = costume.native_fsm
            if fsm and costume.native_fsm_was_puppet ~= nil then
                fsm:call("set_PuppetMode",
                    costume.native_fsm_was_puppet == true)
            end
            local am = costume.native_action_manager
            if am and costume.native_reject_request_was ~= nil then
                am:call("set_IsRejectRequestOnDefault",
                    costume.native_reject_request_was == true)
            end
            if am and costume.native_reject_abort_was ~= nil then
                am:call("set_IsRejectAbortOnDefault",
                    costume.native_reject_abort_was == true)
            end
        end)
        costume.native_controller_live = false
        C.wyrm_native_controller = false -- takeover is one ride only
    end
    S.costume = nil
    _G.IrisScaleHoldAddr = nil -- scale easer resumes (08-13 crash guard)
    if not costume then return end
    if S.ride_pose_on then
        S.ride_pose_on = false
        restore_player_components()
        pcall(function()
            local player_go = player_game_object()
            local fsm = get_component(player_go, "via.motion.MotionFsm2")
            if fsm then fsm:call("set_Enabled", true) end
        end)
        pcall(function()
            local motion = player_character():call("get_Motion")
            if motion then motion:call("set_PlaySpeed", 1.0) end
        end)
        pcall(function()
            local pose = rawget(_G, "NB_Pose")
            if pose then pose.stop() end
        end)
    end
    if costume.passenger_only then
        -- griffin experiment: we never touched the body — restore NOTHING
        -- on it (clearing NoDie/AI on a tamed griffin, or resetActionAndAI
        -- on a live one, is the griffin mod's territory and the AV class)
        S.status = "griffin experiment released"
        return
    end
    pcall(function()
        local mesh = get_component(costume.ox_go, "via.render.Mesh")
        if mesh then mesh:call("set_Enabled", true) end
    end)
    pcall(function()
        local hc = get_component(costume.ox_go, "app.HitController")
        if hc then
            hc:call("set_IsInvincible", false)
            hc:call("set_IsNoDie", false)
        end
    end)
    pcall(function()
        for _, comp in ipairs(costume.muted_wwise or {}) do
            pcall(function() comp:call("set_Enabled", true) end)
        end
        local wwise = get_component(costume.ox_go, "app.WwiseContainerApp")
        if wwise then wwise:call("set_Enabled", true) end
    end)
    pcall(function()
        for _, comp in ipairs(costume.rootmotion_disabled or {}) do
            pcall(function() comp:call("set_Enabled", true) end)
        end
    end)
    -- A tamed wyrm is NOT handed back to Capcom's decision/navigation stack after
    -- riding.  Two separate traces proved that stack retained a stale bridge-nav
    -- request from the driven body: waking it first crashed in decision evaluation,
    -- and delaying the wake merely moved the AV into NavigationAI.navigationRequest.
    -- IrisTaming owns these companions already, so mark the body for its safe
    -- transform-follow driver and keep native decision/navigation parked.
    local staged_puppet_release = costume.oxless == true
        and costume.passenger_only ~= true
    if not staged_puppet_release then
        pcall(function()
            local ai = get_component(costume.ox_go, "app.AIDecisionMaker")
            if ai then ai:call("set_Enabled", true) end
        end)
    end
    if not costume.oxless then
        -- oxless: ox_go IS the horse — a 1.0 reset would shrink it
        pcall(function()
            local ox_tf = costume.ox_go:call("get_Transform")
            ox_tf:call("set_LocalScale", Vector3f.new(1.0, 1.0, 1.0))
        end)
    end
    if valid(costume.horse_go) then
        local character = get_component(costume.horse_go, "app.Character")
        pcall(function()
            character:call("setCharacterControllerEnable", true)
        end)
        -- A staged wyrm release is already owned by IrisTaming's puppet
        -- follower.  The old code woke MotionFsm2 + thinking for 0.45 seconds
        -- and only parked them later.  That window is enough for a stale combat
        -- action/nav request to run the mount into water (and is the same class
        -- of stale-navigation crash seen on Shadow).  Never wake them at all.
        if not staged_puppet_release then
            pcall(function()
                local fsm = get_component(costume.horse_go,
                    "via.motion.MotionFsm2")
                if fsm then fsm:call("set_Enabled", true) end
            end)
            pcall(function() character:call("set_IsThinkStop", false) end)
        else
            pcall(function()
                local ai = get_component(costume.horse_go, "app.AIDecisionMaker")
                local nav = get_component(costume.horse_go, "app.NavigationAI")
                local fsm = get_component(costume.horse_go, "via.motion.MotionFsm2")
                if ai then ai:call("set_Enabled", false) end
                if nav then nav:call("set_Enabled", false) end
                if fsm then fsm:call("set_Enabled", false) end
                if character then character:call("set_IsThinkStop", true) end
            end)
        end
        -- Never call resetActionAndAI without its native argument.  REFramework's
        -- warning is not benign here: on a just-dismounted wolf it was immediately
        -- followed by an access violation in DecisionEvaluationModuleLateUpdator.
        pcall(function()
            local hc = get_component(costume.horse_go, "app.HitController")
            if hc then
                -- Mounting temporarily hardens the body.  Restore what the
                -- companion actually had before mounting; blindly writing
                -- false made a previously protected Shadow player-damageable.
                hc:call("set_IsInvincible",
                    costume.native_was_invincible == true)
                hc:call("set_IsNoDie", costume.native_was_no_die == true)
            end
        end)
        if staged_puppet_release then
            local addr = object_address(costume.horse_go)
            local puppet_addrs = rawget(_G, "IrisMountPuppetAddrs")
            if type(puppet_addrs) ~= "table" then
                puppet_addrs = {}
                rawset(_G, "IrisMountPuppetAddrs", puppet_addrs)
            end
            if addr then puppet_addrs[addr] = true end
            S.costume_release = {
                go = costume.horse_go,
                character = character,
                addr = addr,
                wake_at = os.clock() + 0.45,
                expires = os.clock() + 3.0,
            }
            rawset(_G, "IrisMountReleaseAddr", addr)
        end
    end
end

local function costume_start()
    local player_pos = universal_pos(player_game_object())
    if not player_pos then
        S.status = "costume: no player position"
        return
    end
    -- NEAREST registered horse (not merely the first)
    local record, record_d = nil, 50
    for _, candidate in ipairs(horses()) do
        if valid(candidate.game_object) then
            local d = distance(player_pos, universal_pos(candidate.game_object))
            if d < record_d then record, record_d = candidate, d end
        end
    end
    if not record then
        S.status = "costume: need a live horse nearby"
        return
    end
    local best, best_d = nil, 35
    pcall(function()
        local scene_manager = sdk.get_native_singleton("via.SceneManager")
        local scene_type = sdk.find_type_definition("via.SceneManager")
        local scene = sdk.call_native_func(
            scene_manager, scene_type, "get_CurrentScene()")
        local characters = scene and scene:call(
            "findComponents(System.Type)", sdk.typeof("app.Character"))
        local elements = {}
        pcall(function() elements = characters:get_elements() end)
        for _, character in ipairs(elements) do
            local id = ""
            pcall(function()
                id = tostring(character:call("get_CharaIDString"))
            end)
            if id:match("^ch299003") then
                local go = nil
                pcall(function() go = character:call("get_GameObject") end)
                if valid(go) then
                    local d = distance(player_pos, universal_pos(go))
                    if d < best_d then best, best_d = go, d end
                end
            end
        end
    end)
    if not best then
        S.status = "costume: no ox within 35m (spawn one)"
        return
    end
    -- fit the body double: scale sits the ox inside the horse's silhouette
    -- (0.75 left the climb-top hanging in air behind the rump — Aurora
    -- field-fit 0.85, live slider in the panel); restored to 1.0 on stop
    pcall(function()
        local ox_tf = best:call("get_Transform")
        local sc = S.ox_scale or 0.94
        ox_tf:call("set_LocalScale", Vector3f.new(sc, sc, sc))
    end)
    -- the ox stays native; only its RENDERING sleeps (proven harmless)
    pcall(function()
        local mesh = get_component(best, "via.render.Mesh")
        if mesh then mesh:call("set_Enabled", false) end
    end)
    pcall(function()
        local hate = get_component(best, "app.HateSystem")
        if hate then hate:call("clearAllHate") end
    end)
    -- mount hardening (Aurora's list 07-23): unkillable, silent, and calm.
    -- NOT via set_IsInvincible — that flag gates climb (07-23 field find);
    -- the damage-zero hook keeps the ox grabbable AND immortal
    install_ox_shield_hook()
    -- SILENCE the ox completely (07-23: container-off still mooed —
    -- sweep EVERY Wwise* component on the body; restored on stop)
    local muted_wwise = {}
    pcall(function()
        local comps = best:call("get_Components")
        for _, comp in ipairs(comps and comps:get_elements() or {}) do
            local type_name = ""
            pcall(function()
                type_name = comp:get_type_definition():get_full_name()
            end)
            if type_name:find("Wwise") then
                pcall(function()
                    if comp:call("get_Enabled") == true then
                        comp:call("set_Enabled", false)
                        muted_wwise[#muted_wwise + 1] = comp
                    end
                end)
            end
        end
    end)
    -- brain off = no wandering into rivers; re-enable via the checkbox if
    -- the climb ever needs it (costume climb worked on the ALIVE ox — this
    -- is the empirical test of whether consent needs the brain)
    pcall(function()
        local ai = get_component(best, "app.AIDecisionMaker")
        if ai then ai:call("set_Enabled", false) end
    end)
    -- summoned oxen arrive think-stopped (idle spawn); the climb needs the
    -- body AWAKE (ghost-era note: think-stop may block the latch) — AI-off
    -- above is what keeps it calm instead
    pcall(function()
        local ox_character = get_component(best, "app.Character")
        if ox_character then
            ox_character:call("set_IsThinkStop", false)
        end
    end)
    -- THE OX COMES TO THE HORSE (07-24 tame field: the pin drags the
    -- horse to wherever the ox spawned — teleporting the WILD horse away
    -- mid-rite, in the ox's rotation, shaking against its settling
    -- physics). The horse's CC goes off later THIS SAME FRAME (below),
    -- before any physics tick can press the overlapped pair.
    pcall(function()
        local horse_tf = record.game_object:call("get_Transform")
        local ox_tf = best:call("get_Transform")
        ox_tf:call("set_UniversalPosition",
            horse_tf:call("get_UniversalPosition"))
        ox_tf:call("set_Rotation", horse_tf:call("get_Rotation"))
    end)
    -- the horse becomes the costume: brain off, capsule off (both = the
    -- ride's own proven calls on this exact creature)
    local character = get_component(record.game_object, "app.Character")
    pcall(function() character:call("set_IsThinkStop", true) end)
    pcall(function()
        character:call("setCharacterControllerEnable", false)
    end)
    -- 07-23 "keeps lying down": think-stop silences the BRAIN only — the
    -- motion FSM's livelihood scheduler kept firing bank-60 lie/ruminate
    -- clips over our commands. Park the FSM (carry-walk law: L0 clips are
    -- fully drivable with the FSM off) so the gait machinery owns layer 0.
    pcall(function()
        local fsm = get_component(record.game_object, "via.motion.MotionFsm2")
        if fsm then fsm:call("set_Enabled", false) end
    end)
    -- root-motion kill runs from costume_tick (definition order): flag it
    S.need_rootmotion_kill = true
    -- the SHELL is what everyone hits: it must be as immortal as the ox
    -- (07-23: "horse dies in 1 hit" — we hardened the wrong body only)
    pcall(function()
        local hc = get_component(record.game_object, "app.HitController")
        if hc then
            hc:call("set_IsInvincible", true)
            hc:call("set_IsNoDie", true)
        end
    end)
    S.costume = {ox_go = best, horse_go = record.game_object,
                 horse_character = character, last_gait = nil,
                 muted_wwise = muted_wwise}
    -- a fresh costume means nobody is seated on it yet
    S.ride_pose_on = false
    S.mount_climb_since = nil
    S.status = "costume: horse is wearing the ox — climb the horse"
end

-- ⭐ GRIFFIN PASSENGER EXPERIMENT (07-24, Aurora: "I'd like to know if
-- this is some kind of magic solution"): the horse technique, verbatim,
-- on a griffin — with the KEY reframing that the griffin plays the OX's
-- role (a fully ALIVE native body; we never touch its brain/FSM/clips —
-- its own crash laws stay unviolated). Only the RIDER is puppeted: vault,
-- seat pin to Spine_2, Wilds pose, hand magnet, chase cam. Passenger
-- only: no driving, no gait commands. Stop reverts everything.
-- target_go (07-24 bridge port): the griffin probe hands us ITS griffin
-- directly via _G.IrisPuppetSeat.mount(go); nil = the original scene
-- sweep (the panel experiment button).
local function costume_start_griffin_experiment(target_go)
    local player_pos = universal_pos(player_game_object())
    if not player_pos then return end
    local best, best_d = nil, 30.0
    if valid(target_go) then best = target_go end
    pcall(function()
        if best then return end
        local scene_manager = sdk.get_native_singleton("via.SceneManager")
        local scene_type = sdk.find_type_definition("via.SceneManager")
        local scene = sdk.call_native_func(
            scene_manager, scene_type, "get_CurrentScene()")
        local characters = scene and scene:call(
            "findComponents(System.Type)", sdk.typeof("app.Character"))
        local elements = {}
        pcall(function() elements = characters:get_elements() end)
        for _, character in ipairs(elements) do
            local id = ""
            pcall(function()
                id = tostring(character:call("get_CharaIDString"))
            end)
            if id:match("^ch253") then
                local go = nil
                pcall(function() go = character:call("get_GameObject") end)
                if valid(go) then
                    local dd = distance(player_pos, universal_pos(go))
                    if dd < best_d then best, best_d = go, dd end
                end
            end
        end
    end)
    if not best then
        S.status = "griffin exp: no griffin within 30m"
        return
    end
    -- 07-24 SHIELD BUG: the damage-zero hook only ever installed on the
    -- LEGACY costume path — the player shield inside it never armed on
    -- passenger/oxless rides ("died on landing" round 2)
    install_ox_shield_hook()
    S.costume = {ox_go = best, horse_go = best,
                 horse_character = get_component(best, "app.Character"),
                 last_gait = nil, oxless = true, passenger_only = true,
                 muted_wwise = {}}
    S.ride_pose_on = false
    S.mount_climb_since = nil
    S.status = "GRIFFIN EXPERIMENT armed - press E/RT beside it"
end

-- ⭐ OXLESS MOUNT (07-24, Aurora's call: "we don't need it at all"): the
-- horse IS its own drive body — ox_go = horse_go, so every existing pipe
-- (drive, gait, seat, camera, magnet, bucks) works unchanged. The one
-- real difference: its CharacterController STAYS ON — its own physics
-- does terrain/gravity/walls, the job the ox used to do.
local function costume_start_oxless(record)
    local character = get_component(record.game_object, "app.Character")
    local native_was_invincible, native_was_no_die = nil, nil
    -- Preserve a fresh ch223 graph while the seat is merely armed. Disabling
    -- MotionFsm2 here was discarding the graph before the panel's START button
    -- could ever take ownership.
    local retain_native_graph = record.wyrm_mount == true
        and record.wyrm_chassis == "ch223"
    pcall(function()
        character:call("set_IsThinkStop", not retain_native_graph)
    end)
    pcall(function()
        local ai = get_component(record.game_object, "app.AIDecisionMaker")
        if ai then ai:call("set_Enabled", false) end
    end)
    pcall(function()
        local fsm = get_component(record.game_object,
            "via.motion.MotionFsm2")
        if fsm then
            fsm:call("set_Enabled", retain_native_graph)
            if retain_native_graph then
                pcall(function() fsm:call("set_PuppetMode", false) end)
            end
        end
    end)
    pcall(function()
        local nav = get_component(record.game_object, "app.NavigationAI")
        -- Puppeteer leaves NavigationAI alive on ch223.  Disabling it while the
        -- seat was merely armed could discard the action graph before START.
        if nav and not retain_native_graph then nav:call("set_Enabled", false) end
    end)
    S.need_rootmotion_kill = true
    pcall(function()
        local hc = get_component(record.game_object, "app.HitController")
        if hc then
            pcall(function() native_was_invincible = hc:call("get_IsInvincible") end)
            pcall(function() native_was_no_die = hc:call("get_IsNoDie") end)
            hc:call("set_IsInvincible", true)
            hc:call("set_IsNoDie", true)
        end
    end)
    install_ox_shield_hook() -- 07-24: never armed on oxless before
    S.costume = {ox_go = record.game_object,
                 horse_go = record.game_object,
                 horse_character = character, last_gait = nil,
                 oxless = true, record = record, muted_wwise = {},
                  native_ai = get_component(record.game_object, "app.AIDecisionMaker"),
                  native_nav = get_component(record.game_object, "app.NavigationAI"),
                  native_fsm = get_component(record.game_object, "via.motion.MotionFsm2"),
                  native_wwise = get_component(record.game_object, "app.WwiseContainerApp"),
                  native_was_invincible = native_was_invincible,
                  native_was_no_die = native_was_no_die}
    -- ⛔ 08-13 Shadow-mount CTD, ladder step 1 (v2 - TIMED): the easer's LocalScale
    -- write at the exact mount moment was the last mod action before the crash. v1
    -- held for the whole costume life - but auto-arm keeps a costume on any nearby
    -- wolf/cat, so the native ScaleMediator stomped them back toward 1.0 with nobody
    -- on duty (Aurora: "they were so much bigger before"). Now the hold is a short
    -- WINDOW around the two churn moments only: arming (think-stop/FSM-off, here)
    -- and the mount vault (seat_mount). Steady-state easer writes resume in between.
    _G.IrisScaleHoldAddr = { addr = object_address(record.game_object),
                             untilt = os.clock() + 2.5 }
    S.ride_pose_on = false
    S.mount_climb_since = nil
    S.status = "OXLESS mount ready - press E/RT beside it"
end

-- The stable handover must not be trusted to preserve incidental rodeo
-- state.  Promote the exact horse that completed the pact into the oxless
-- mount path explicitly, while keeping an already-prepared body intact.
local function ready_tamed_mount(record)
    if not (record and valid(record.game_object)) then return false end
    record.tamed = true
    local wanted = object_address(record.game_object)
    local current = S.costume and object_address(S.costume.horse_go)
    if not (S.costume and wanted and current == wanted) then
        if S.costume then costume_stop() end
        costume_start_oxless(record)
    end
    if not S.costume then return false end
    S.costume.record = record
    S.costume.tamed = true
    S.mount_press_latch = grab_pressed()
    S.status = "TAMED - stand beside your horse and press E/RT to mount"
    return true
end

-- ⭐⭐ 08-13 WYRM MOUNT (Aurora: the horse mount on Wyrmlife-grown wolves + big cats).
-- The 07-24 verdict pre-blessed this port: "oxless mount = SPECIES-AGNOSTIC - wolves/
-- pumas need only seat joint + gait ids + seat-fit + scale." One port, two id families:
-- wolf ch260, cat ch223 (atlases ch260000/ch223000, both textbook: walk 0:100,
-- run 0:200, dash 0:300, idle 0:0). Only a WYRM-GROWN live companion qualifies - the
-- ritual's size is what makes a back worth sitting on.
-- GLOBAL function (⛔ the main chunk rides the 200-local ceiling - the file's own law).
function iris_wyrm_mount_start(quiet)
    local b = rawget(_G, "IrisGriffinBridge")
    if not b then if not quiet then S.status = "wyrm mount: bridge not loaded" end return false end
    local ch = nil
    pcall(function() ch = b.griffin and b.griffin() end)
    if not ch then if not quiet then S.status = "wyrm mount: no companion is out" end return false end
    local go = nil
    pcall(function() go = ch:call("get_GameObject") end)
    if not valid(go) then if not quiet then S.status = "wyrm mount: no body" end return false end
    local id = ""
    pcall(function() id = tostring(ch:call("get_CharaIDString")) end)
    -- Identity and animation chassis are separate facts. Shadow is ch223000;
    -- Mia is ch223001. Both use the ch223 motions, but only Mia gets the cat
    -- seat and imported Wild Cats voice. The former chassis-only test called
    -- both of them "cat" and made their fit/audio inseparable.
    local chassis = (id:find("^ch260") and "ch260")
        or (id:find("^ch223") and "ch223") or nil
    if not chassis then
        if not quiet then
            S.status = "wyrm mount: companion is not a wolf or great cat (" .. tostring(id) .. ")"
        end
        return false
    end
    local wyrm, live_rec = false, nil
    pcall(function()
        for _, r in ipairs(b.stable_list() or {}) do
            if r.live and r.wyrm then wyrm, live_rec = true, r; break end
        end
    end)
    if not wyrm then
        if not quiet then
            S.status = "wyrm mount: this friend is not wyrm-grown - too small to bear a rider"
        end
        return false
    end
    local species = tostring((live_rec and live_rec.species) or id)
    local kind = (species:find("^ch223001") and "cat") or "wolf"
    -- Snapshot the passive companion before costume_start_oxless parks its
    -- graph. This tells us whether IRIS received a healthy native wolf and
    -- invalidated it later, or whether the stable body arrived Invalid already.
    local pre_mount_action = nil
    pcall(function()
        local am = ch["<ActionManager>k__BackingField"]
            or ch:call("get_ActionManager")
        pre_mount_action = iris_wyrm_native_action_name(am)
    end)
    pcall(function() log("WYRM MOUNT arming on "
        .. tostring(id) .. " identity=" .. kind .. " species=" .. species
        .. " preAction=" .. tostring(pre_mount_action)) end)
    local record = { game_object = go, kind = kind, tamed = true,
        wyrm_mount = true, wyrm_chassis = chassis }
    if S.costume then costume_stop() end
    costume_start_oxless(record)
    if not S.costume then S.status = "wyrm mount: costume refused"; return false end
    S.costume.record = record
    S.costume.tamed = true
    S.costume.wyrm_kind = kind
    S.costume.wyrm_chassis = chassis
    S.costume.wyrm_species = species
    S.costume.native_pre_mount_action = pre_mount_action
    S.mounted_combat_off = true
    -- their OWN legs: the native locomotion loops, straight from the atlases
    S.costume.gaits = { walk = { 0, 100 }, run = { 0, 200 }, dash = { 0, 300 } }
    -- 08-13 (Aurora: "randomly growling constantly, angry pose"): the think-stop
    -- freezes whatever clip was playing, and a companion wolf's default is the AGGRO
    -- STALK with the growl baked into the loop. Arm into the neutral idle instead.
    pcall(function()
        local motion = S.costume.horse_character:call("get_Motion")
        local layer = motion and motion:call("getLayer", 0)
        if layer then
            layer:call(
                "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                0, 0, 0.0, 0.4, 1, 1)
        end
    end)
    S.mount_press_latch = grab_pressed()
    S.status = "WYRM MOUNT ready - stand beside your " .. kind .. " and press E/RT"
    return true
end

function iris_wyrm_mount_stop()
    if S.costume and S.costume.wyrm_kind then
        costume_stop()
        S.status = "wyrm mount released - your friend is their own again"
        return true
    end
    return false
end

-- Wild Cats normally recognises converted bodies through its spawn registry.
-- Stable summon/rebuild can replace that wrapper before the rodeo takes
-- ownership, so give the vocal hook one authoritative live identity check.
-- registered_cat_ancestor() walks parents, allowing Wwise child objects to
-- resolve back to the mounted body without sharing chassis-based guesses.
rawset(_G, "__iris_rodeo_mounted_cat_audio_owner", function(game_object, container)
    local costume = S.costume
    if not (costume and costume.wyrm_kind == "cat"
        and valid(costume.horse_go)) then return nil end
    if valid(game_object)
        and object_address(game_object) == object_address(costume.horse_go) then
        return costume.horse_go
    end
    -- Wwise calls are made by their container component; its GameObject is not
    -- guaranteed to be the registered/root object.  Component identity is the
    -- authoritative link and avoids classifying every ch223 chassis as a cat.
    local mounted_wwise = costume.native_wwise
    if container and mounted_wwise
        and object_address(container) == object_address(mounted_wwise) then
        return costume.horse_go
    end
    return nil
end)
rawset(_G, "__iris_rodeo_is_mounted_cat", function(game_object)
    local match = rawget(_G, "__iris_rodeo_mounted_cat_audio_owner")
    return match and match(game_object, nil) ~= nil or false
end)

-- resetActionAndAI is a one-argument method in this DD2 build.  A bare
-- `character:call("resetActionAndAI")` only emits a REFramework warning and,
-- on a parked companion, has been followed by a DecisionEvaluation AV.  Resolve
-- the exact overload and build its real option object before touching Shadow.
local function iris_wyrm_reset_action_and_ai(character)
    local method, signature = nil, nil
    local ok_find, find_err = pcall(function()
        local td = sdk.find_type_definition("app.Character")
        for _, candidate in ipairs((td and td:get_methods()) or {}) do
            if candidate:get_name() == "resetActionAndAI" then
                local params = candidate:get_param_types() or {}
                local p0 = params[1]
                local pn = p0 and tostring(p0:get_full_name()) or ""
                if #params == 1
                    and pn == "app.Character.ResetActionAndAIOption" then
                    method = candidate
                    signature = "resetActionAndAI(" .. pn .. ")"
                    break
                end
            end
        end
    end)
    if not ok_find or not method then
        return false, "typed reset overload unavailable: " .. tostring(find_err)
    end

    local option = nil
    local ok_new, new_err = pcall(function()
        option = sdk.create_instance(
            "app.Character.ResetActionAndAIOption", true)
        if not option then
            option = sdk.create_instance(
                "app.Character.ResetActionAndAIOption")
        end
    end)
    if not ok_new or not option then
        return false, "could not construct ResetActionAndAIOption: "
            .. tostring(new_err)
    end

    local function option_field(name, value)
        local wrote = false
        pcall(function() option:set_field(name, value); wrote = true end)
        if not wrote then
            pcall(function() option[name] = value; wrote = true end)
        end
        return wrote
    end
    -- The STRUCT_* names exist only in the RSZ serialisation schema, not on the
    -- live managed object (writing them produces a red REFramework error).
    option_field("IsResetAI", true)
    option_field("IsResetCatch", true)
    option_field("IsResetCaught", true)
    option_field("ActionName", "NormalLocomotion")

    local ok_call, call_err = pcall(function()
        method:call(character, option)
    end)
    if not ok_call then
        return false, signature .. " failed: " .. tostring(call_err)
    end
    return true, signature
end

-- Return a failed/aborted takeover to the proven transform driver immediately.
-- AI/navigation stay parked: waking either is what previously let the companion
-- choose its own targets/path and produced the 15-fps decision storm.
function iris_wyrm_native_controller_abort(costume, reason)
    C.wyrm_native_controller = false
    costume = costume or S.costume
    if costume then
        pcall(function()
            local act = costume.native_action_interface
            if act then
                act:call("set_Enabled",
                    costume.native_action_interface_was_enabled ~= false)
            end
            local fsm = costume.native_fsm
            if fsm and costume.native_fsm_was_puppet ~= nil then
                fsm:call("set_PuppetMode",
                    costume.native_fsm_was_puppet == true)
            end
            local am = costume.native_action_manager
            if am and costume.native_reject_request_was ~= nil then
                am:call("set_IsRejectRequestOnDefault",
                    costume.native_reject_request_was == true)
            end
            if am and costume.native_reject_abort_was ~= nil then
                am:call("set_IsRejectAbortOnDefault",
                    costume.native_reject_abort_was == true)
            end
        end)
        pcall(function()
            local ai, nav, fsm = costume.native_ai,
                costume.native_nav, costume.native_fsm
            if ai then ai:call("set_Enabled", false) end
            if nav then nav:call("set_Enabled", false) end
            if fsm then fsm:call("set_Enabled", false) end
            if costume.horse_character then
                costume.horse_character:call("set_IsThinkStop", true)
                costume.horse_character:call("setCharacterControllerEnable", true)
                local motion = costume.horse_character:call("get_Motion")
                if motion then motion:call("set_PlaySpeed", 1.0) end
            end
        end)
        costume.native_controller_live = nil
        costume.native_controller_prepared = nil
        costume.native_controller_booting = nil
        costume.native_controller_boot_until = nil
        costume.native_controller_boot_tries = nil
        costume.native_controller_invalid_since = nil
        costume.native_move_mode = nil
        costume.native_move_retry_at = nil
        costume.native_move_log_at = nil
        costume.native_jump_latch = nil
        costume.native_speed_pos = nil
        costume.cmd_bank, costume.cmd_clip = nil, nil
        costume.driven_gait, costume.last_gait = nil, nil
        costume.force_hold = nil
        costume.ownership_at = 0.0
    end
    if S.wyrm_native_lease and iris_wyrm_native_bite_finish then
        pcall(iris_wyrm_native_bite_finish, "native controller abort")
    end
    S.wyrm_attack, S.wyrm_atk_until, S.wyrm_atk_hold = nil, nil, nil
    S.wyrm_native_pending, S.wyrm_native_recover_until = nil, nil
    S.need_rootmotion_kill = true
    S.wyrm_native_status = "native takeover ABORTED: "
        .. tostring(reason or "manual stop")
    log(S.wyrm_native_status)
    return false
end

-- Puppeteer does not translate its Barghest by hand.  It leaves the enemy
-- action graph and CharacterController alive, parks autonomous decision input,
-- and asks MonsterActionSelector for its authored locomotion.  This adapter
-- applies that ownership to the SAME persistent ch223 body the rider is sitting
-- on; there is no second/invisible chassis in the wyrm path.
function iris_wyrm_native_controller_prepare(costume)
    if C.wyrm_native_controller ~= true
        or not (costume and costume.wyrm_chassis == "ch223"
            and costume.wyrm_kind == "wolf"
            and valid(costume.horse_character) and valid(costume.horse_go)) then
        return false
    end
    if costume.native_controller_prepared then
        if costume.native_controller_booting then
            local now = os.clock()
            if now < (tonumber(costume.native_controller_boot_until) or now) then
                return true -- keep the fallback driver out during Puppeteer's settle window
            end
            local action = iris_wyrm_native_action_name(
                costume.native_action_manager)
            -- PuppetSetup does not wait for slot zero to become non-Invalid.
            -- After its one-second delay it starts the handler, which requests
            -- idle/locomotion and lets the authored selector populate the slot.
            costume.native_controller_booting = nil
            costume.native_controller_live = true
            costume.native_controller_invalid_since = nil
            costume.native_move_mode = nil
            costume.native_move_retry_at = nil
            S.need_rootmotion_kill = nil
            S.wyrm_native_status = "native takeover LIVE after 1s: action "
                .. tostring(action or "nil") .. " (pre-mount "
                .. tostring(costume.native_pre_mount_action) .. ")"
            log(S.wyrm_native_status)
            return true
        end
        return costume.native_controller_live == true
    end
    costume.native_controller_prepared = true
    local character = costume.horse_character
    pcall(function()
        costume.native_action_manager =
            character["<ActionManager>k__BackingField"]
                or character:call("get_ActionManager")
                or get_component(costume.horse_go, "app.ActionManager")
    end)
    pcall(function()
        costume.native_monster = get_component(costume.horse_go, "app.Monster")
        costume.native_selector = costume.native_monster
            and costume.native_monster["<MonsterActionSelector>k__BackingField"]
            or nil
    end)
    pcall(function()
        local enemy_ctrl = character.EnemyCtrl
            or character:get_field("EnemyCtrl")
        local ch2 = enemy_ctrl and (enemy_ctrl.Ch2
            or enemy_ctrl:get_field("Ch2")) or nil
        costume.native_ch2 = ch2
        costume.native_action_interface = ch2 and (ch2._ActInter
            or ch2:get_field("_ActInter")) or nil
    end)
    if not (costume.native_action_manager and costume.native_selector) then
        costume.native_controller_live = false
        S.wyrm_native_status = "native controller unavailable: missing "
            .. (costume.native_action_manager and "MonsterActionSelector"
                or (costume.native_selector and "ActionManager"
                    or "ActionManager + MonsterActionSelector"))
        log(S.wyrm_native_status)
        return false
    end
    local graph_before = iris_wyrm_native_action_name(
        costume.native_action_manager)
    pcall(function()
        local am = costume.native_action_manager
        if costume.native_action_locks_captured ~= true then
            pcall(function()
                costume.native_reject_request_was =
                    am:call("get_IsRejectRequestOnDefault") == true
            end)
            pcall(function()
                costume.native_reject_abort_was =
                    am:call("get_IsRejectAbortOnDefault") == true
            end)
            costume.native_action_locks_captured = true
        end
        if am:call("get_Enabled") == false then am:call("set_Enabled", true) end
        -- Puppeteer's fresh wolf accepts selector requests. IRIS action leases
        -- can leave either default rejection latch set on the persistent body.
        pcall(function() am:call("set_IsRejectRequestOnDefault", false) end)
        pcall(function() am:call("set_IsRejectAbortOnDefault", false) end)
    end)
    pcall(function()
        local ai = costume.native_ai
        if ai then ai:call("set_Enabled", false) end
        -- Puppeteer's disposable spawn has no IRIS follower destination, but
        -- persistent Shadow does. Leaving NavigationAI alive lets that stale
        -- destination drive the body even while our selector says idle (the
        -- 08-17 water test proved exactly that). Native authored locomotion is
        -- ActionManager/MonsterActionSelector + CharacterController; it does
        -- not require autonomous pathfinding, so cut navigation at takeover.
        local nav = costume.native_nav
        if nav then nav:call("set_Enabled", false) end
        character:call("setCharacterControllerEnable", true)
        local motion = character:call("get_Motion")
        if motion then
            pcall(function() motion:call("set_Enabled", true) end)
            motion:call("set_PlaySpeed", 1.0)
        end
        local fsm = costume.native_fsm
        if fsm then
            if costume.native_fsm_snapshot_taken ~= true then
                pcall(function()
                    costume.native_fsm_was_puppet =
                        fsm:call("get_PuppetMode") == true
                end)
                costume.native_fsm_snapshot_taken = true
            end
            fsm:call("set_Enabled", true)
            -- This is the critical Puppeteer diff. Stable registration puts
            -- persistent companions into MotionFsm2 PuppetMode; Puppeteer does
            -- not. Merely re-enabling that FSM leaves ActionList[0] Invalid.
            fsm:call("set_PuppetMode", false)
        end
        character:call("set_IsThinkStop", false)
    end)
    pcall(function()
        local act = costume.native_action_interface
        if act then
            costume.native_action_interface_was_enabled =
                act:call("get_Enabled") == true
            -- Match Puppeteer: decision input stays cut while the authored FSM
            -- and MonsterActionSelector take movement requests from us.
            act:call("set_Enabled", false)
        end
    end)
    -- CurrentActionList[0]=Invalid is Puppeteer's ordinary no-current-action
    -- state, not proof that the action graph was discarded.  The controller
    -- contract is the live ActionManager + MonsterActionSelector checked above.
    pcall(function()
        local ai = costume.native_ai
        if ai then ai:call("set_Enabled", false) end
        local act = costume.native_action_interface
        if act then act:call("set_Enabled", false) end
        costume.native_selector:call("requestNormalIdleImpl")
    end)
    costume.native_controller_booting = true
    costume.native_controller_boot_until = os.clock() + 1.0
    costume.native_controller_boot_tries = 0
    costume.native_controller_live = false
    costume.native_move_mode = nil
    costume.native_move_retry_at = nil
    costume.native_move_log_at = nil
    costume.cmd_bank, costume.cmd_clip = nil, nil
    costume.driven_gait, costume.last_gait = nil, nil
    S.wyrm_native_status = "Puppeteer settle 1.0s: action "
        .. tostring(graph_before) .. " puppet="
        .. tostring(costume.native_fsm_was_puppet) .. " -> selector idle"
    log(S.wyrm_native_status)
    return true
end

function iris_wyrm_native_controller_tick(costume, now, dt, input)
    if not iris_wyrm_native_controller_prepare(costume) then return false end
    if costume.native_controller_live ~= true then
        costume.cur_speed = 0.0
        costume.speed = 0.0
        return true
    end
    local character = costume.horse_character
    local selector = costume.native_selector
    local action_manager = costume.native_action_manager
    local tf = costume.horse_go:call("get_Transform")
    if not (selector and action_manager and tf) then return false end

    -- Invalid is a vacant action slot and is normal while standing.  It must
    -- not abort native ownership: the selector below is what starts idle or
    -- locomotion, exactly as Puppeteer's per-frame handler does.
    local live_action = iris_wyrm_native_action_name(action_manager)
    if live_action == nil or tostring(live_action) == "Invalid" then
        costume.native_controller_invalid_since = now
    else
        costume.native_controller_invalid_since = nil
    end

    -- Reins-style steering is retained; only propulsion/terrain/root motion is
    -- handed to ch223.  Puppeteer's camera-relative strafing would make a mount
    -- sidestep when Aurora expects it to turn.
    local turn_in = ((input.right and 1.0 or 0.0)
        - (input.left and 1.0 or 0.0))
    if turn_in == 0.0 and math.abs(input.stick_x or 0.0) > 0.15 then
        turn_in = (math.abs(input.stick_x) - 0.15) / 0.85
        if input.stick_x < 0.0 then turn_in = -turn_in end
        turn_in = math.max(-1.0, math.min(1.0, turn_in))
    end
    local yaw = costume.wyrm_yaw
    if not yaw then
        local axis = tf:call("get_AxisZ")
        yaw = math.atan(axis.x, axis.z)
    end
    local lag = math.max(0.01, tonumber(C.turn_lag_secs) or 0.35)
    local eased = tonumber(costume.turn_ease) or 0.0
    eased = eased + (turn_in - eased) * math.min(1.0, dt / lag)
    if math.abs(eased) < 0.001 then eased = 0.0 end
    costume.turn_ease = eased
    if eased ~= 0.0 and not S.wyrm_native_lease then
        yaw = yaw + math.rad(-eased
            * (tonumber(C.wyrm_turn_rate) or 110.0) * dt)
    end
    costume.wyrm_yaw = yaw
    pcall(function()
        local tac = character["<TargetAngleCtrl>k__BackingField"]
        if tac then
            local deg = math.deg(yaw)
            tac.Front["<AngleDeg>k__BackingField"] = deg
            tac.Move["<AngleDeg>k__BackingField"] = deg
        end
        local rot = tf:call("get_Rotation")
        rot.x, rot.y, rot.z, rot.w =
            0.0, math.sin(yaw * 0.5), 0.0, math.cos(yaw * 0.5)
        tf:call("set_Rotation", rot)
    end)

    local jump_down = input.can_drive
        and (input.pad_jump or iris_kb(0x20))
    if jump_down and not costume.native_jump_latch
        and not S.wyrm_native_lease then
        costume.native_jump_latch = true
        costume.native_move_mode = nil
        local ok = pcall(function()
            action_manager:call(
                "requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)",
                0, "ForwardJumpFront", 0)
        end)
        S.wyrm_native_status = ok and "native leap requested"
            or "native leap request FAILED"
        log(S.wyrm_native_status)
        return true
    elseif not jump_down then
        costume.native_jump_latch = nil
    end

    -- An authored attack/jump owns its own root motion.  Do not issue a
    -- locomotion request over it; clearing the remembered mode guarantees one
    -- fresh selector request when the action finishes.
    local grounded = true
    pcall(function() grounded = character:call("get_IsGround") == true end)
    if S.wyrm_native_lease or S.wyrm_attack or not grounded then
        costume.native_move_mode = nil
        costume.cur_speed = 0.0
        return true
    end

    local moving = input.can_drive
        and (input.up or input.pad_move) and true or false
    local mode = 0
    if moving then
        local mag = math.sqrt((input.stick_x or 0.0) ^ 2
            + (input.stick_y or 0.0) ^ 2)
        if input.pad_gallop or (input.up and iris_kb(0x10)) then
            mode = 3
        elseif (input.pad_move and not input.up and mag < 0.42)
            or (input.up and iris_kb(0x11)) then
            mode = 1
        else
            mode = 2
        end
    end
    local vacant_action = live_action == nil
        or tostring(live_action) == "Invalid"
    -- Puppeteer asks again each frame while no authored move owns the body.
    -- A bounded 12.5 Hz retry preserves that contract without turning a
    -- rejected request into the performance-heavy loop Aurora saw earlier.
    local retry_due = vacant_action
        and now >= (tonumber(costume.native_move_retry_at) or 0.0)
    local mode_changed = mode ~= costume.native_move_mode
    if mode_changed or retry_due then
        local ok = pcall(function()
            if mode == 0 then
                selector:call("requestNormalIdleImpl")
            else
                selector:call("requestLocomotionImpl", mode, true)
            end
        end)
        costume.native_move_mode = ok and mode or nil
        costume.native_move_request_at = now
        costume.native_move_retry_at = now + 0.08
        local action = iris_wyrm_native_action_name(action_manager) or "?"
        S.wyrm_native_status = string.format(
            "native locomotion %s | action=%s",
            ok and ({[0]="idle",[1]="walk",[2]="run",[3]="dash"})[mode]
                or "REQUEST FAILED", tostring(action))
        -- Repeated vacant-slot retries are intentional, but repeated disk log
        -- writes are not. Log mode changes immediately and a persistent retry
        -- at most once per second.
        if mode_changed or now >=
                (tonumber(costume.native_move_log_at) or 0.0) then
            costume.native_move_log_at = now + 1.0
            log(S.wyrm_native_status)
        end
    end

    -- Read speed; do not manufacture it.  This drives the HUD/camera without
    -- feeding a second movement system back into the body.
    local pos = tf:call("get_UniversalPosition")
    local prev = costume.native_speed_pos
    if prev and dt > 0.0001 then
        local dx, dz = pos.x - prev.x, pos.z - prev.z
        costume.cur_speed = math.sqrt(dx * dx + dz * dz) / dt
        costume.speed = costume.cur_speed
    end
    costume.native_speed_pos = { x = pos.x, z = pos.z }
    costume.cmd_bank, costume.cmd_clip = nil, nil
    costume.driven_gait = nil
    return true
end

-- Single-owner contract for ridden wyrms.  Streaming/action rebuilds can
-- silently re-enable native components after the initial mount setup.  Check
-- at a bounded 4 Hz and only write when a component actually woke; the drive,
-- gait and scripted contact system remain the sole owners of the body.
function iris_wyrm_ownership_tick()
    local costume = S.costume
    local mounted = costume and costume.wyrm_kind and S.ride_pose_on == true
    rawset(_G, "IrisWyrmMounted", mounted and true or nil)
    S.mounted_combat_off = mounted and true or nil
    if not mounted then return end
    local now = os.clock()
    -- r7: the native maul window deliberately wakes FSM/think for a few
    -- seconds; this 4Hz parking sweep must not strangle it mid-hold.
    local window_lease = S.wyrm_native_lease
    if window_lease and window_lease.native_maul_window
        and now < (tonumber(window_lease.until_t) or 0.0) + 0.5 then
        return
    end
    if now < (tonumber(costume.ownership_at) or 0.0) then return end
    costume.ownership_at = now + 0.25
    pcall(function()
        local ai = costume.native_ai
        if ai and ai:call("get_Enabled") == true then ai:call("set_Enabled", false) end
    end)
    -- The full-native takeover is retired.  Field tests proved that a persistent
    -- companion ch223 can still acquire an unseen movement owner after both its
    -- decision maker and NavigationAI are cut, then drive itself into water.
    -- The dependable ridden contract is therefore deliberately single-owner:
    -- IRIS drives the root and atlas; every autonomous/native action source stays
    -- parked for the entire ride, including during attacks.
    C.wyrm_native_controller = false
    costume.native_controller_live = nil
    costume.native_controller_prepared = nil
    pcall(function()
        local nav = costume.native_nav
        if nav and nav:call("get_Enabled") == true then nav:call("set_Enabled", false) end
        local fsm = costume.native_fsm
        if fsm and fsm:call("get_Enabled") == true then fsm:call("set_Enabled", false) end
        if costume.horse_character then
            costume.horse_character:call("set_IsThinkStop", true)
        end
        local act = costume.native_action_interface
        if act and act:call("get_Enabled") == true then act:call("set_Enabled", false) end
    end)
    S.wyrm_native_recover_until = nil
end

-- RIDDEN WYRM TARGET: enemies plus ordinary wildlife. EnemyManager deliberately excludes
-- rabbits/deer/oxen, which is why the animation could visibly bite a spawned rabbit and deal
-- nothing. Homestead residents remain friends and are rejected by character address.
function iris_wyrm_attack_target(costume, atk)
    -- Select inside the strike volume, not merely the nearest EnemyManager
    -- entry.  The old nearest-first route could lock a goblin behind the mount,
    -- then reject it at contact while the doe directly under its jaws was never
    -- considered.  One scene sweep per button press is cheap; no per-frame scan.
    if not (costume and valid(costume.horse_go)) then return nil end
    local root_origin = universal_pos(costume.horse_go)
    local origin = root_origin
    -- The Wyrmlife shell is several times larger than an ordinary ch223.  Its
    -- body root can be metres behind a goblin already touching the jaws, so the
    -- old root-centred forward box rejected the very target the animation was
    -- visibly biting.  Prefer the live mouth joint, but sanity-check the atlas
    -- rebase before trusting it across a streamed skeleton rebuild.
    local mouth = iris_wyrm_native_mouth_positions(costume)
    if mouth and root_origin then
        local mdx = (tonumber(mouth.x) or 0.0) - (tonumber(root_origin.x) or 0.0)
        local mdy = (tonumber(mouth.y) or 0.0) - (tonumber(root_origin.y) or 0.0)
        local mdz = (tonumber(mouth.z) or 0.0) - (tonumber(root_origin.z) or 0.0)
        if mdx * mdx + mdy * mdy + mdz * mdz <= 225.0 then origin = mouth end
    end
    local tf = costume.horse_go:call("get_Transform")
    local forward = tf and tf:call("get_AxisZ")
    if not (origin and forward) then return nil end
    local fx, fz = tonumber(forward.x) or 0.0, tonumber(forward.z) or 0.0
    local fl = math.sqrt(fx * fx + fz * fz)
    if fl < 0.01 then return nil end
    fx, fz = fx / fl, fz / fl
    local reach = tonumber(atk.range) or 5.5
    local width = tonumber(atk.width) or 2.8
    -- Creature roots sit at very different heights (a prone goblin, a doe and
    -- a large pawn do not put their HitController at the same Y).  Treat this
    -- as a tall jaw volume rather than a thin horizontal slice.
    local vertical = tonumber(atk.vertical) or 6.0
    local voice = atk.slot == "voice"
    local mount_addr = object_address(costume.horse_go)
    local residents = rawget(_G, "IrisResidentChAddrs")
    local best, best_go, best_score = nil, nil, math.huge
    local function consider(ch)
        if not valid(ch) then return end
        pcall(function()
            local id = tostring(ch:call("get_CharaIDString") or "")
            if not id:match("^ch2") then return end
            local go = ch:call("get_GameObject")
            if not valid(go) or object_address(go) == mount_addr then return end
            local ca, ga = object_address(ch), object_address(go)
            if residents and (residents[ca] == true or residents[ga] == true) then return end
            local dead = false
            pcall(function() dead = ch:call("get_IsDead") == true end)
            if dead then return end
            local hp = nil
            pcall(function()
                local hc = get_component(go, "app.HitController")
                hp = hc and hc:call("get_Hp") or nil
            end)
            if tonumber(hp) and tonumber(hp) <= 0 then return end
            local pos = universal_pos(go)
            if not pos then return end
            local dx = (tonumber(pos.x) or 0.0) - (tonumber(origin.x) or 0.0)
            local dz = (tonumber(pos.z) or 0.0) - (tonumber(origin.z) or 0.0)
            local dy = (tonumber(pos.y) or 0.0) - (tonumber(origin.y) or 0.0)
            local along = dx * fx + dz * fz
            local across = math.abs(dx * fz - dz * fx)
            local radial2 = dx * dx + dz * dz
            local body_along = along
            if root_origin ~= origin then
                local bdx = (tonumber(pos.x) or 0.0) - (tonumber(root_origin.x) or 0.0)
                local bdz = (tonumber(pos.z) or 0.0) - (tonumber(root_origin.z) or 0.0)
                body_along = bdx * fx + bdz * fz
            end
            local aim_ok = true
            local aim_deg = tonumber(atk.aim_deg)
            if aim_deg and not voice then
                local flat_d = math.sqrt(math.max(0.0001, radial2))
                local aim_dot = along / flat_d
                -- 105 degrees deliberately includes a victim slightly beside a
                -- huge jaw.  The previous additional `along > 0` silently
                -- collapsed every >90-degree setting back to a strict half-plane.
                aim_ok = aim_dot >= math.cos(math.rad(aim_deg))
            end
            -- A recovered/downed small enemy can move its Character root several
            -- metres behind the scaled ch223 mouth while still being visibly
            -- underneath Shadow's head.  Within the generous jaw radius, accept
            -- that close body without making the mouth-origin half-plane the
            -- arbiter.  This is target acquisition only; scenery-safe movement
            -- and the one-contact transaction still own the actual strike.
            local close_jaw = radial2 <= math.min(reach * reach, 100.0)
                and math.abs(dy) <= vertical
                and body_along >= -4.5
            local inside = voice and radial2 <= reach * reach
                or (body_along >= -4.5 and along >= -6.0 and along <= reach
                    and across <= width and math.abs(dy) <= vertical
                    and (aim_ok or close_jaw))
            if not inside then return end
            local score = voice and radial2
                or (radial2 + across * across * 1.5 + dy * dy * 0.08)
            if score < best_score then
                best, best_go, best_score = ch, go, score
            end
        end)
    end

    -- Consecutive combo presses should retain their victim.  Besides feeling
    -- like an actual lock, this avoids a whole-scene component enumeration for
    -- every link of X while battle actors are spawning/despawning.
    local cached = costume.wyrm_attack_target_cache
    if cached and os.clock() <= (tonumber(cached.until_t) or 0.0) then
        consider(cached.target)
        if best then return best, best_go end
    end

    -- EnemyManager is much cheaper than Scene.findComponents and covers the
    -- common combat case.  Keep the scene sweep only as the wildlife fallback.
    pcall(function()
        local find_enemy = rawget(_G, "griffin_find_enemy")
        if find_enemy then
            local candidate = find_enemy(reach + width + 6.0)
            local as_character = rawget(_G, "griffin_as_character")
            if candidate and as_character then
                candidate = as_character(candidate) or candidate
            end
            consider(candidate)
        end
    end)
    if best then
        costume.wyrm_attack_target_cache = {
            target = best, until_t = os.clock() + 0.85,
        }
        return best, best_go
    end
    pcall(function()
        local sm = sdk.get_native_singleton("via.SceneManager")
        local smt = sdk.find_type_definition("via.SceneManager")
        local scene = sdk.call_native_func(sm, smt, "get_CurrentScene()")
        local chars = scene and scene:call(
            "findComponents(System.Type)", sdk.typeof("app.Character"))
        for _, ch in ipairs(chars and chars:get_elements() or {}) do consider(ch) end
    end)
    if best then
        costume.wyrm_attack_target_cache = {
            target = best, until_t = os.clock() + 0.85,
        }
    else
        costume.wyrm_attack_target_cache = nil
    end
    return best, best_go
end

function iris_wyrm_play_native_howl_sound(costume, lease)
    if not (costume and valid(costume.horse_character)) then return false end
    local played = false
    local route = "none"
    local audio_receipt = nil
    -- Prefer the exact ch223 vocal once Wild Cats has learnt it from any real
    -- wolf howl.  Its API now distinguishes an audible post from a queued miss.
    pcall(function()
        local capi = rawget(_G, "__iris_wild_cats_api")
        if capi and capi.play_wolf_howl then
            played = capi.play_wolf_howl(costume.horse_go) == true
            if played then route = "exact ch223 howl event" end
        elseif capi and capi.play_wolf_call then
            played = capi.play_wolf_call(costume.horse_go, true) == true
            if played then route = "exact ch223 howl event (legacy API)" end
        end
        if capi and capi.get_wolf_howl_status then
            audio_receipt = select(1, capi.get_wolf_howl_status())
        end
    end)
    -- Do not fall back to Barghest's player-owned action trigger.  Field testing
    -- proved that it is the generic action noise Aurora heard, not a wolf vocal.
    -- An exact ch223 howl or an honest failure is preferable to a false success.
    costume.wyrm_howl_sound_route = route
    log("native howl sound: " .. (played and ("posted via " .. route) or "FAILED"))
    if lease then
        local detail = played and ("post accepted: " .. route)
            or "no ch223 howl request accepted"
        if type(audio_receipt) == "table" then
            detail = detail .. " | route=" .. tostring(audio_receipt.route)
                .. " trigger=" .. tostring(audio_receipt.trigger_id)
        end
        iris_wyrm_combat_trace(lease, "howl-audio",
            detail)
    end
    return played
end

-- Replaying a ch223 attack motion does not perform the ActionManager transition
-- which normally retires the previous attack and clears its victim history.  The
-- first bite could therefore use the real jaw collider, while the same goblin was
-- silently rejected by every later bite/maul contact.  Reset only the outgoing
-- attack bookkeeping; AttackList and ColliderRequestList contain the authored jaw
-- definition and must never be cleared or replaced.
function iris_wyrm_native_rearm_attack(costume, label)
    if not (costume and valid(costume.horse_go)) then return false, 0 end
    local hit = get_component(costume.horse_go, "app.HitController")
    if not hit then return false, 0 end
    local cleared = 0
    local function clear_member(name)
        pcall(function()
            local value = hit[name]
            if not value then value = hit:call("get_" .. name) end
            if value then
                value:call("Clear")
                cleared = cleared + 1
            end
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
    if costume then
        costume.wyrm_last_rearm = tostring(label or "attack")
        costume.wyrm_last_rearm_cleared = cleared
    end
    return armed, cleared
end

-- Native-only melee invariant: X, Y and RT may only succeed through ch223's
-- authored AttackUserData and collider request.  There is deliberately no
-- ShellManager or direct-HP fallback here; those produce the wrong material
-- language and receiver behaviour even when they move the health bar.

function iris_wyrm_cast_real_howl_shell(costume)
    if not (costume and valid(costume.horse_character)
        and valid(costume.horse_go)) then return false end
    local shell_handler = nil
    if not pcall(function()
        shell_handler = require("Bestiary/ShellHandler")
    end) or not (shell_handler and shell_handler.cast_shell) then
        return false
    end
    local tf = costume.horse_go:call("get_Transform")
    local shared = nil
    local ok = pcall(function()
        -- This is Puppeteer's exact Barghest dome, not a hand-moved victim or
        -- fake stagger.  The engine owns its collision and reaction semantics.
        shared = shell_handler.cast_shell(costume.horse_character,
            "AppSystem/ch/ch227/001/userdata/ch227001darkareashellparamdata.user",
            0, {
                position = tf:call("get_Position"),
                rotation = tf:call("get_Rotation"),
                size = 2.5,
                omentime = 0.0,
                lifetime = 0.5,
                colorParams = {
                    color = { 0, 0, 0, 0 },
                    externColor = { 0, 0, 0, 0 },
                },
                delay = 0.8,
            })
    end)
    return ok and shared ~= nil and shared.requestID ~= nil
end

function iris_wyrm_howl_blast(costume)
    if not (costume and valid(costume.horse_go)) then return 0 end
    local cast = iris_wyrm_cast_real_howl_shell(costume)
    S.wyrm_native_status = (cast and "native Barghest howl shell cast"
        or "native Barghest howl shell FAILED")
        .. " | sound=" .. tostring(costume.wyrm_howl_sound_route or "none")
    log(S.wyrm_native_status)
    return cast and 1 or 0
end

function iris_wyrm_attack_home(costume, atk, now, age)
    -- RETIRED 08-13: this used set_UniversalPosition every frame to pull the
    -- complete rider/mount rig towards a target. It bypassed collision and
    -- water boundaries, repeatedly rescanned the whole wildlife scene when no
    -- target existed, and could carry Mia plus rider into water during a
    -- dismount. Contact assist is now the generous timed front sweep only.
    return
end

-- Read-only proof instrumentation for the native bite.  The native action must
-- stand on its own: no fabricated DamageInfo and no direct-HP fallback are
-- allowed in this branch, otherwise a falling health number would prove nothing.
function iris_wyrm_native_target_hp(target)
    if not valid(target) then return nil end
    local hp = nil
    pcall(function()
        local reader = rawget(_G, "griffin_read_target_hp")
        if reader then hp = tonumber(reader(target)) end
    end)
    if hp ~= nil then return hp end
    pcall(function()
        local go = target:call("get_GameObject")
        local hc = go and get_component(go, "app.HitController") or nil
        hp = hc and tonumber(hc:call("get_Hp")) or nil
    end)
    return hp
end

-- Captured twice from separate natural ch223 bites on Aurora, 2026-08-17.
-- The native action drives ColliderReqTracks.ReqId1=50 throughout its authored
-- jaw window. Replaying this request does not create DamageInfo or alter HP: it
-- merely asks Shadow's own RequestSetCollider to run the same wolf collider.
local IRIS_WYRM_NATIVE_BITE_REQUEST_ID = 50

function iris_wyrm_native_jaw_tracks(lease)
    if not lease then return nil end
    if lease.native_jaw_tracks then return lease.native_jaw_tracks end
    local tracks = nil
    pcall(function()
        tracks = sdk.create_instance("app.ColliderReqTracks")
        if tracks then
            tracks:add_ref()
            pcall(function() tracks:call(".ctor()") end)
            for _, name in ipairs({
                "ReqId1", "ReqId2", "ReqId3", "ReqId4", "ReqId5", "ReqId6",
                "ReqId7", "ReqId8", "ReqId9", "ReqId10", "ReqId11", "ReqId12",
                "DamageReqId", "PushReqId", "AtkDetectReqId",
            }) do
                tracks:set_field(name, -1)
            end
            tracks:set_field("ReqId1", IRIS_WYRM_NATIVE_BITE_REQUEST_ID)
        end
    end)
    lease.native_jaw_tracks = tracks
    return tracks
end

function iris_wyrm_native_request_jaw(lease, label, request_id)
    if not (lease and lease.costume and valid(lease.costume.horse_go)) then
        return false
    end
    local hit_controller = lease.native_hit_controller
        or get_component(lease.costume.horse_go, "app.HitController")
    local tracks = iris_wyrm_native_jaw_tracks(lease)
    if not (hit_controller and tracks) then return false end
    local requested = false
    pcall(function()
        -- One authored request per strike. Re-posting ReqId1 every rendered frame
        -- restarts the request state instead of making the jaw volume wider; the
        -- field trace showed that this could keep a perfectly aligned bite from
        -- ever reaching its receiver transaction.
        request_id = tonumber(request_id) or IRIS_WYRM_NATIVE_BITE_REQUEST_ID
        tracks:set_field("ReqId1", request_id)
        hit_controller:call("requestSeqCollider(app.ColliderReqTracks)", tracks)
        requested = true
    end)
    if requested then
        lease.native_jaw_requests = (tonumber(lease.native_jaw_requests) or 0) + 1
        iris_wyrm_combat_trace(lease, "jaw-request",
            tostring(label or "impact") .. " | ReqId1="
                .. tostring(request_id) .. " | one-shot")
    end
    return requested
end

-- Atlas bite clips 50:422/423 are not self-contained locomotion actions on the
-- parked mounted graph. In particular 50:423 naturally falls through to the
-- common airborne loop (0:415). That is an animation transition, not evidence
-- that the transform-driven chassis left the ground. Retire only that leaked
-- transition; real jump/fall state remains authoritative and is never touched.
function iris_wyrm_native_grounded_motion_guard(lease, force_idle)
    local costume = lease and lease.costume or nil
    if not (costume and valid(costume.horse_character))
        or costume.jump then return false end
    -- The gravity integrator can be seeded by a one-frame ground-query miss while
    -- an attack pose shifts the giant shell. Do not call that airborne until the
    -- chassis itself has dropped a visible distance. Genuine ledge falls pass this
    -- threshold and retain 0:415 normally.
    local physical_drop = 0.0
    if costume.fall_v ~= nil then
        pcall(function()
            local base = valid(costume.ox_go) and costume.ox_go or costume.horse_go
            local p = base:call("get_Transform"):call("get_UniversalPosition")
            physical_drop = math.max(0.0,
                (tonumber(costume.fall_from) or tonumber(p.y) or 0.0)
                    - (tonumber(p.y) or 0.0))
        end)
        if costume.fall_anim_force == true or physical_drop >= 0.55 then
            return false
        end
    end
    local current = read_layer0(costume.horse_go)
    local leaked_fall = current and current.bank == 0 and current.id == 415
    if not (force_idle or leaked_fall) then return false end
    local changed = false
    pcall(function()
        local motion = costume.horse_character:call("get_Motion")
        local layer = motion and motion:call("getLayer", 0)
        if not layer then return end
        layer:call(
            "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
            0, 0, 0.0, 6.0, 1, 1)
        layer:call("set_Speed", 1.0)
        costume.cmd_bank, costume.cmd_clip = 0, 0
        costume.fall_anim, costume.fall_anim_force = nil, nil
        changed = true
    end)
    if changed and leaked_fall and not lease.grounded_fall_guard_logged then
        lease.grounded_fall_guard_logged = true
        iris_wyrm_combat_trace(lease, "grounded-fall-guard",
            "retired leaked 0:415; physical fall state was nil")
    end
    return changed
end

function iris_wyrm_native_action_name(action_manager)
    local name = nil
    pcall(function()
        local list = action_manager.CurrentActionList
            or action_manager:get_field("CurrentActionList")
        local entry = list and (list[0] or list:call("get_Item", 0)) or nil
        local raw = entry and (entry.Name or entry:get_field("Name")) or nil
        if raw ~= nil then name = tostring(raw) end
        -- Several ActionEntry variants expose no Name field at all; ToString is
        -- the proven read used by the down-node probe.
        if entry and (not name or name == "nil" or name == "") then
            name = tostring(entry:call("ToString()") or "")
        end
    end)
    if name == "" or name == "nil" then return nil end
    return name
end

-- Front-cone assist, not lock-on. Selection comes from the mount's nose rather
-- than the camera, turns only through a bounded forward angle, and finishes
-- before contact. It never translates or acquires behind the rider.
function iris_wyrm_native_prepare_aim(costume, target, lease, max_deg, secs)
    if not (costume and valid(costume.horse_go) and valid(target) and lease) then
        return false
    end
    local op, tp = universal_pos(costume.horse_go), nil
    pcall(function()
        local tgo = target:call("get_GameObject")
        tp = tgo and universal_pos(tgo) or nil
    end)
    if not (op and tp) then return false end
    local dx = (tonumber(tp.x) or 0.0) - (tonumber(op.x) or 0.0)
    local dz = (tonumber(tp.z) or 0.0) - (tonumber(op.z) or 0.0)
    if dx * dx + dz * dz < 0.01 then return false end
    local from = tonumber(costume.wyrm_yaw)
    if not from then
        pcall(function()
            local az = costume.horse_go:call("get_Transform"):call("get_AxisZ")
            from = math.atan(tonumber(az.x) or 0.0, tonumber(az.z) or 1.0)
        end)
    end
    if not from then return false end
    local wanted = math.atan(dx, dz)
    local delta = wanted - from
    while delta > math.pi do delta = delta - 2.0 * math.pi end
    while delta < -math.pi do delta = delta + 2.0 * math.pi end
    if math.abs(math.deg(delta)) > (tonumber(max_deg) or 38.0) then
        return false
    end
    lease.aim_from = from
    lease.aim_delta = delta
    lease.aim_secs = tonumber(secs) or 0.12
    -- Pounce is a committed target move, not camera-relative free aim.  Snap
    -- both the transform-driven chassis and the visible shell before launch;
    -- changing only horse_go let ox_tf leap along its previous heading.
    if lease.hard_aim == true then
        local yaw = from + delta
        costume.wyrm_yaw = yaw
        for _, go in ipairs({ costume.ox_go, costume.horse_go }) do
            if valid(go) then
                pcall(function()
                    local tf = go:call("get_Transform")
                    local rot = tf:call("get_Rotation")
                    rot.x, rot.y, rot.z, rot.w =
                        0.0, math.sin(yaw * 0.5), 0.0, math.cos(yaw * 0.5)
                    tf:call("set_Rotation", rot)
                end)
            end
        end
        lease.aim_from, lease.aim_delta = nil, nil
    end
    return true
end

-- Live attack origin. ch223's native bite VFX and collision are authored around
-- mouthLowerMid; measuring from the body root guessed several metres wrong on
-- a Wyrmlife-scaled wolf and could pull the target beneath Shadow's chest.
function iris_wyrm_native_mouth_positions(costume)
    if not (costume and valid(costume.horse_go)) then return nil, nil end
    local up, rp, jp = nil, nil, nil
    pcall(function()
        local tf = costume.horse_go:call("get_Transform")
        up = tf:call("get_UniversalPosition")
        rp = tf:call("get_Position")
        for _, name in ipairs({ "mouthLowerMid", "Tongue_0", "Head", "Neck_0" }) do
            local joint = tf:call("getJointByName", name)
            if joint then jp = joint:call("get_Position"); break end
        end
    end)
    if not (up and rp and jp) then return nil, nil end
    return {
        x = up.x + jp.x - rp.x,
        y = up.y + jp.y - rp.y,
        z = up.z + jp.z - rp.z,
    }, jp
end

-- A native bite owns its collider, so the wolf has to be at the authored jaw
-- distance when that collider opens.  Aim alone cannot solve a 3-4m gap.  This
-- helper measures WORLD obstruction in render space (the ray API's space) so
-- the bounded attack step below never becomes the old through-wall homing pin.
function iris_wyrm_native_go_under(game_object, ancestor)
    if not (valid(game_object) and valid(ancestor)) then return false end
    local wanted = object_address(ancestor)
    local current = game_object
    for _ = 1, 8 do
        if object_address(current) == wanted then return true end
        local parent_go = nil
        pcall(function()
            local tf = current:call("get_Transform")
            local parent = tf and tf:call("get_Parent") or nil
            parent_go = parent and parent:call("get_GameObject") or nil
        end)
        if not valid(parent_go) then break end
        current = parent_go
    end
    return false
end

function iris_wyrm_native_clear_forward(costume, wanted, target_go, dir_x, dir_z)
    -- Contact assist may only advance towards the selected target. Backwards
    -- correction was geometrically valid when the goblin sat under the jaws,
    -- but visibly made Shadow retreat from the enemy on every point-blank bite.
    local magnitude = math.max(0.0, tonumber(wanted) or 0.0)
    if magnitude <= 0.001 or not (costume and valid(costume.horse_go)) then
        return 0.0
    end
    local clear = 0.0
    pcall(function()
        local ray = rawget(_G, "route3_ray")
        local ensure = rawget(_G, "route3_ensure_ray")
        if not (ray and ensure and ensure()) then
            clear = 0.0 -- no collision proof, no scripted translation
            return
        end
        local tf = costume.horse_go:call("get_Transform")
        local _, mouth_rp = iris_wyrm_native_mouth_positions(costume)
        local fwd = tf and tf:call("get_AxisZ")
        if not (mouth_rp and fwd) then clear = 0.0; return end
        local fx = dir_x ~= nil and tonumber(dir_x) or tonumber(fwd.x) or 0.0
        local fz = dir_z ~= nil and tonumber(dir_z) or tonumber(fwd.z) or 0.0
        local fl = math.sqrt(fx * fx + fz * fz)
        if fl < 0.01 then clear = 0.0; return end
        fx, fz = fx / fl, fz / fl
        -- Cast beyond the intended step and retain a nose buffer.  Layer 2 is
        -- the same scenery-only query used by the proven mount jump wall test.
        local cast = magnitude + 0.30
        local sx, sy, sz = mouth_rp.x, mouth_rp.y, mouth_rp.z
        ray.filter:set_Group(0)
        ray.filter:set_Layer(2)
        ray.filter:set_MaskBits(0)
        ray.result:clear()
        ray.query:call("setRay(via.vec3, via.vec3)",
            rodeo_vec3(sx, sy, sz),
            rodeo_vec3(sx + fx * cast, sy, sz + fz * cast))
        ray.method:call(ray.system, ray.query, ray.result)
        local contacts = tonumber(ray.result:get_NumContactPoints() or 0) or 0
        if contacts <= 0 then
            clear = magnitude
            return
        end
        -- All-hits ray: ignore Shadow and the selected victim. Treat only the
        -- first unrelated collidable as a wall. The old first-hit rule often
        -- saw the goblin itself and stopped the jaws short of its hit volume.
        for i = 0, contacts - 1 do
            local hit_go = nil
            pcall(function()
                local col = ray.result:call(
                    "getContactCollidable(System.UInt32)", i)
                hit_go = col and col:call("get_GameObject") or nil
            end)
            if not (iris_wyrm_native_go_under(hit_go, costume.horse_go)
                or iris_wyrm_native_go_under(hit_go, target_go)) then
                local contact = ray.result:call(
                    "getContactPoint(System.UInt32)", i)
                local hp = contact and sdk.get_native_field(
                    contact, ray.contact_td, "Position")
                if hp then
                    local hx, hz = hp.x - sx, hp.z - sz
                    clear = math.max(0.0, math.min(magnitude,
                        math.sqrt(hx * hx + hz * hz) - 0.20))
                    return
                end
            end
        end
        clear = magnitude
    end)
    return clear
end

-- The ridden chassis is transform-driven, so CharacterController collision does
-- not get a vote.  Validate every deliberate horizontal step in render space,
-- then reject terrain rises steeper than that mount can actually climb.  Horses
-- and wyrms are deliberately separate here: the old shared wolf tune used a low
-- 0.48 m horizontal ray and 38 degree limit for the horse too.  That ray struck
-- ordinary uphill terrain, zeroed the horse's speed, and then the speed-gated
-- jump refused to launch.  A horse uses a shorter leg ray, a long chest ray and
-- its native controller's measured 50 degree slope limit; wolves/cats retain the
-- conservative protection built around their lower body.
function iris_wyrm_clear_travel(costume, wanted, dir_x, dir_z,
        airborne_clearance)
    local magnitude = math.max(0.0, tonumber(wanted) or 0.0)
    if magnitude <= 0.0001 or not (costume and valid(costume.horse_go)) then
        return 0.0
    end
    local body_go = valid(costume.ox_go) and costume.ox_go or costume.horse_go
    local dx, dz = tonumber(dir_x) or 0.0, tonumber(dir_z) or 0.0
    local dl = math.sqrt(dx * dx + dz * dz)
    if dl < 0.01 then return 0.0 end
    dx, dz = dx / dl, dz / dl
    local block = costume.wyrm_wall_block
    if block then
        local bp = universal_pos(body_go)
        local bx, bz = bp and bp.x - (tonumber(block.x) or bp.x) or 99.0,
            bp and bp.z - (tonumber(block.z) or bp.z) or 99.0
        local near = bx * bx + bz * bz < 9.0
        local pushing_into = dx * (tonumber(block.dx) or 0.0)
            + dz * (tonumber(block.dz) or 0.0) > 0.45
        local jumping_over_low = airborne_clearance == true
            and block.reason == "collidable"
        if near and pushing_into and not jumping_over_low then return 0.0 end
        -- Turning substantially away, backing out, or an external teleport
        -- releases the directional wall latch.
        if not (near and pushing_into) then costume.wyrm_wall_block = nil end
    end
    local function arm_block(reason)
        local p = costume.wyrm_last_open_pos or universal_pos(body_go)
        if not p then return end
        costume.wyrm_wall_block = {
            -- The root being clear does not mean a Wyrmlife-sized wolf's nose
            -- and rider are clear. Keep a full body margin behind the last
            -- proven sample for emergency rollback/dismount recovery.
            x = (tonumber(p.x) or 0.0) - dx * 0.90,
            y = tonumber(p.y),
            z = (tonumber(p.z) or 0.0) - dz * 0.90,
            dx = dx, dz = dz, reason = reason, at = os.clock(),
        }
    end
    local clear = magnitude
    pcall(function()
        local ray = rawget(_G, "route3_ray")
        local ensure = rawget(_G, "route3_ensure_ray")
        if not (ray and ensure and ensure()) then return end
        -- The drive moves ox_tf, not the visible animal shell.  Casting from the
        -- shell sampled a late/offset position and could begin behind the wall
        -- the chassis was already entering.
        local tf = body_go:call("get_Transform")
        local rp = tf and tf:call("get_Position")
        if not rp then return end
        local is_wyrm = costume.wyrm_kind ~= nil
        local ray_specs
        if airborne_clearance == true then
            ray_specs = {{ height = 1.55, lead = 1.28, stop = 1.10 }}
        elseif is_wyrm then
            -- r13 (Aurora: "the wolf is struggling to walk up a hill"): the
            -- old low ray (0.48m height, 1.28m lead) intersected any uphill
            -- slope past ~20 deg and armed the wall latch -- the exact trap
            -- the horse specs below document. Rebalanced to the horse law:
            -- short low lead clears hillsides, still catches fences (vertical
            -- faces trigger at any lead).
            ray_specs = {
                { height = 0.85, lead = 0.55, stop = 0.42 },
                { height = 1.55, lead = 1.15, stop = 0.95 },
            }
        else
            ray_specs = {
                -- A short fetlock ray still catches low fences without
                -- projecting far enough to intersect an ordinary hillside.
                { height = 0.85, lead = 0.45, stop = 0.30 },
                -- The long chest ray catches trees/walls before the horse's
                -- body reaches them and naturally clears traversable slopes.
                { height = 1.55, lead = 1.15, stop = 0.95 },
            }
        end
        for _, spec in ipairs(ray_specs) do
            -- Stop the chassis before the visible wolf's chest reaches the
            -- obstacle.  The old 42cm margin protected only the root point, so
            -- most of Shadow could already be inside a tree or fence.
            local cast = clear + spec.lead
            ray.filter:set_Group(0)
            ray.filter:set_Layer(2)
            ray.filter:set_MaskBits(0)
            ray.result:clear()
            ray.query:call("setRay(via.vec3, via.vec3)",
                rodeo_vec3(rp.x, rp.y + spec.height, rp.z),
                rodeo_vec3(rp.x + dx * cast, rp.y + spec.height,
                    rp.z + dz * cast))
            ray.method:call(ray.system, ray.query, ray.result)
            local contacts = tonumber(ray.result:get_NumContactPoints() or 0) or 0
            for i = 0, contacts - 1 do
                local hit_go = nil
                pcall(function()
                    local col = ray.result:call(
                        "getContactCollidable(System.UInt32)", i)
                    hit_go = col and col:call("get_GameObject") or nil
                end)
                if not (iris_wyrm_native_go_under(hit_go, costume.horse_go)
                    or iris_wyrm_native_go_under(hit_go, body_go)) then
                    local contact = ray.result:call(
                        "getContactPoint(System.UInt32)", i)
                    local hp = contact and sdk.get_native_field(
                        contact, ray.contact_td, "Position")
                    if hp then
                        local hx, hz = hp.x - rp.x, hp.z - rp.z
                        clear = math.min(clear, math.max(0.0,
                            math.sqrt(hx * hx + hz * hz) - spec.stop))
                    end
                end
            end
        end
    end)
    if clear < magnitude * 0.95 then arm_block("collidable") end
    if clear <= 0.0001 then return 0.0 end
    pcall(function()
        local now = os.clock()
        if now < (tonumber(costume.wyrm_steep_block_until) or 0.0) then
            clear = 0.0
            return
        end
        if now < (tonumber(costume.wyrm_slope_probe_at) or 0.0) then return end
        costume.wyrm_slope_probe_at = now + 0.08
        local ground = rawget(_G, "route3_ground_below_uni")
        if not ground then return end
        local up = universal_pos(body_go)
        if not up then return end
        local probe = math.max(0.70, clear)
        local below = ground(up.x, up.y + 1.0, up.z, 1.2, 5.0)
        local ahead = ground(up.x + dx * probe, up.y + 3.0,
            up.z + dz * probe, 3.5, 10.0)
        -- Compare ground with ground.  The former `up.y - 0.15` baseline added
        -- 15 cm to every measured rise, turning the nominal 38 degree guard
        -- into an effective ~30 degree wall on a 0.7 m probe.
        local by = below and tonumber(below.y)
            or ((tonumber(up.y) or 0.0) - 0.02)
        local ay = ahead and tonumber(ahead.y)
        if ay then
            local rise = ay - by
            -- r13: 38 deg stalled the wolf on ordinary DD2 hillsides; 50 deg
            -- = the native CharacterController's own SlopeLimit and the value
            -- horses ride with.
            local slope_limit = 50.0
            local allowed = math.max(0.30,
                probe * math.tan(math.rad(slope_limit)))
            if rise > allowed then
                clear = 0.0
                costume.wyrm_steep_block_until = now + 0.12
                arm_block("steep ground")
            else
                -- Only a freshly sampled, non-steep position can become the
                -- recovery anchor. Cached probe frames cannot ratchet this
                -- point into a wall while forward input remains held.
                costume.wyrm_last_open_pos = {
                    x = tonumber(up.x), y = tonumber(up.y), z = tonumber(up.z),
                    at = now,
                }
            end
        end
    end)
    return clear
end

-- Read rather than manufacture the catch prerequisite.  Different character
-- classes expose slightly different down flags, so preserve "unknown" when no
-- usable flag exists and include the target's native action node as evidence.
function iris_wyrm_native_target_down_state(target)
    if not valid(target) then return nil, "no target" end
    local saw, down = false, false
    local flags = {}
    for _, getter in ipairs({
        "get_IsDown", "get_IsDowned", "get_IsFall", "get_IsUnconscious",
    }) do
        local ok, value = pcall(function() return target:call(getter) end)
        if ok and type(value) == "boolean" then
            saw = true
            flags[#flags + 1] = getter:gsub("get_", "") .. "=" .. tostring(value)
            if value then down = true end
        end
    end
    local node = nil
    pcall(function()
        local go = target:call("get_GameObject")
        local am = go and get_component(go, "app.ActionManager") or nil
        node = am and iris_wyrm_native_action_name(am) or nil
    end)
    if node then
        flags[#flags + 1] = "node=" .. tostring(node)
        local lower = tostring(node):lower()
        if lower:find("down", 1, true) or lower:find("fall", 1, true)
            or lower:find("blown", 1, true) then
            saw, down = true, true
        end
    end
    local detail = (#flags > 0 and table.concat(flags, ", ") or "state unknown")
    if saw then return down, detail end
    return nil, detail
end

-- A compact transaction trace for X/Y/RT/LT.  Position alone cannot tell us
-- whether a bite missed: field receipts have shown the goblin 0.07 m from the
-- mouth while HitController still had no active authored request.  Record both
-- geometry and the controller's attack bookkeeping at the few meaningful
-- checkpoints, then flush complete runs to one small JSON file.
local function iris_wyrm_managed_count(value)
    if not value then return nil end
    local count = nil
    pcall(function() count = tonumber(value:call("get_Count")) end)
    if count == nil then pcall(function() count = tonumber(value.Count) end) end
    if count == nil then pcall(function() count = tonumber(value:get_field("_size")) end) end
    return count
end

local function iris_wyrm_hit_member(hit, name)
    if not hit then return nil end
    local value = nil
    pcall(function() value = hit[name] end)
    if value == nil then pcall(function() value = hit:get_field(name) end) end
    if value == nil then
        pcall(function() value = hit:get_field("<" .. name .. ">k__BackingField") end)
    end
    if value == nil then pcall(function() value = hit:call("get_" .. name) end) end
    return value
end

local function iris_wyrm_hit_flag(hit, name)
    local value = iris_wyrm_hit_member(hit, name)
    if type(value) == "boolean" then return value end
    return value ~= nil and tostring(value) or nil
end

local function iris_wyrm_trace_num(value)
    value = tonumber(value)
    if value == nil then return nil end
    return math.floor(value * 1000.0 + (value >= 0 and 0.5 or -0.5)) / 1000.0
end

function iris_wyrm_combat_trace(lease, checkpoint, note)
    if C.wyrm_combat_trace == false or type(lease) ~= "table" then return end
    if not lease.trace_id then
        S.wyrm_combat_trace_seq = (tonumber(S.wyrm_combat_trace_seq) or 0) + 1
        lease.trace_id = S.wyrm_combat_trace_seq
    end
    lease.trace = type(lease.trace) == "table" and lease.trace or {}
    local costume = lease.costume
    local root = costume and universal_pos(costume.horse_go) or nil
    local mouth = costume and iris_wyrm_native_mouth_positions(costume) or nil
    local target_pos = valid(lease.target_go) and universal_pos(lease.target_go) or nil
    local along, across, distance, vertical = nil, nil, nil, nil
    if mouth and target_pos and costume and valid(costume.horse_go) then
        local dx, dy, dz = target_pos.x - mouth.x,
            target_pos.y - mouth.y, target_pos.z - mouth.z
        distance = math.sqrt(dx * dx + dz * dz)
        vertical = dy
        pcall(function()
            local fwd = costume.horse_go:call("get_Transform"):call("get_AxisZ")
            local fx, fz = tonumber(fwd.x) or 0.0, tonumber(fwd.z) or 0.0
            local fl = math.sqrt(fx * fx + fz * fz)
            if fl > 0.01 then
                fx, fz = fx / fl, fz / fl
                along = dx * fx + dz * fz
                across = math.abs(dx * fz - dz * fx)
            end
        end)
    end
    local hit = costume and valid(costume.horse_go)
        and get_component(costume.horse_go, "app.HitController") or nil
    local motion = costume and valid(costume.horse_go)
        and read_layer0(costume.horse_go) or nil
    local down, down_detail = iris_wyrm_native_target_down_state(lease.target)
    local target_action = nil
    pcall(function()
        local am = lease.target and (lease.target["<ActionManager>k__BackingField"]
            or lease.target:call("get_ActionManager")) or nil
        am = am or (valid(lease.target_go)
            and get_component(lease.target_go, "app.ActionManager") or nil)
        target_action = am and iris_wyrm_native_action_name(am) or nil
    end)
    local snap = {
        t = iris_wyrm_trace_num(os.clock()),
        checkpoint = tostring(checkpoint or "event"),
        note = note and tostring(note) or nil,
        label = tostring(lease.label or "attack"),
        button = tostring(lease.trace_button or lease.slot or "?"),
        combo = tonumber(lease.combo_index),
        phase = tostring(lease.phase or "-"),
        hp = iris_wyrm_trace_num(iris_wyrm_native_target_hp(lease.target)),
        down = down,
        down_detail = down_detail,
        mount_action = lease.action_manager
            and iris_wyrm_native_action_name(lease.action_manager) or nil,
        target_action = target_action,
        motion_bank = motion and motion.bank or nil,
        motion_id = motion and motion.id or nil,
        motion_frame = motion and iris_wyrm_trace_num(motion.frame) or nil,
        root = root and { x = iris_wyrm_trace_num(root.x),
            y = iris_wyrm_trace_num(root.y), z = iris_wyrm_trace_num(root.z) } or nil,
        mouth = mouth and { x = iris_wyrm_trace_num(mouth.x),
            y = iris_wyrm_trace_num(mouth.y), z = iris_wyrm_trace_num(mouth.z) } or nil,
        target = target_pos and { x = iris_wyrm_trace_num(target_pos.x),
            y = iris_wyrm_trace_num(target_pos.y), z = iris_wyrm_trace_num(target_pos.z) } or nil,
        distance = iris_wyrm_trace_num(distance),
        along = iris_wyrm_trace_num(along),
        across = iris_wyrm_trace_num(across),
        vertical = iris_wyrm_trace_num(vertical),
        attack_list = iris_wyrm_managed_count(iris_wyrm_hit_member(hit, "AttackList")),
        collider_requests = iris_wyrm_managed_count(
            iris_wyrm_hit_member(hit, "ColliderRequestList")),
        hit_history = iris_wyrm_managed_count(iris_wyrm_hit_member(hit, "HitHistory")),
        multi_history = iris_wyrm_managed_count(
            iris_wyrm_hit_member(hit, "MultiHitHistory")),
        is_use_attack = iris_wyrm_hit_flag(hit, "IsUseAttack"),
        is_request_atk_coll = iris_wyrm_hit_flag(hit, "IsRequestAtkColl"),
    }
    local previous = lease.trace[#lease.trace]
    if previous and previous.target and snap.target then
        local dx, dy, dz = snap.target.x - previous.target.x,
            snap.target.y - previous.target.y, snap.target.z - previous.target.z
        snap.target_moved = iris_wyrm_trace_num(math.sqrt(dx * dx + dy * dy + dz * dz))
    end
    lease.trace[#lease.trace + 1] = snap
    while #lease.trace > 64 do table.remove(lease.trace, 1) end
    log(string.format(
        "[WYRM-COMBAT #%d] %s %s | hp=%s | mouth=%s along=%s across=%s dy=%s | motion=%s:%s f=%s | action=%s target=%s | colliders req=%s atk=%s hist=%s/%s flags=%s/%s%s",
        lease.trace_id, snap.button, snap.checkpoint, tostring(snap.hp),
        tostring(snap.distance), tostring(snap.along), tostring(snap.across),
        tostring(snap.vertical), tostring(snap.motion_bank), tostring(snap.motion_id),
        tostring(snap.motion_frame), tostring(snap.mount_action), tostring(snap.target_action),
        tostring(snap.collider_requests), tostring(snap.attack_list),
        tostring(snap.hit_history), tostring(snap.multi_history),
        tostring(snap.is_use_attack), tostring(snap.is_request_atk_coll),
        note and (" | " .. tostring(note)) or ""))
end

function iris_wyrm_combat_trace_flush(lease, reason)
    if C.wyrm_combat_trace == false or type(lease) ~= "table" then return end
    iris_wyrm_combat_trace(lease, "finish", reason)
    S.wyrm_combat_trace_runs = type(S.wyrm_combat_trace_runs) == "table"
        and S.wyrm_combat_trace_runs or {}
    S.wyrm_combat_trace_runs[#S.wyrm_combat_trace_runs + 1] = {
        id = lease.trace_id,
        label = tostring(lease.label or "attack"),
        reason = tostring(reason or "finished"),
        rows = lease.trace,
    }
    while #S.wyrm_combat_trace_runs > 12 do
        table.remove(S.wyrm_combat_trace_runs, 1)
    end
    pcall(function()
        json.dump_file("IrisWyrmCombatTrace.json", {
            generated_at = os.date("%Y-%m-%d %H:%M:%S"),
            latest_id = lease.trace_id,
            runs = S.wyrm_combat_trace_runs,
        })
    end)
end

-- Native-only collider workbench.  We cannot enlarge an empty list, and guessing
-- request methods on HitController is exactly the sort of managed-object misuse
-- that causes delayed crashes.  Dump the actual API at script load, then capture
-- the live attack/collider entries from a genuine ch223 damage transaction.  No
-- damage, animation or state is modified by this probe.
function iris_wyrm_dump_hitcontroller_api()
    local out = { types = {} }
    local function relevant(name)
        name = tostring(name or ""):lower()
        return name:find("attack", 1, true) or name:find("coll", 1, true)
            or name:find("hit", 1, true) or name:find("request", 1, true)
    end
    local function method_signature(method)
        local params, ret = {}, "?"
        pcall(function()
            local types = method:get_param_types()
            for i = 1, method:get_num_params() do
                params[#params + 1] = tostring(types[i]:get_full_name())
            end
        end)
        pcall(function() ret = tostring(method:get_return_type():get_full_name()) end)
        return tostring(method:get_name()) .. "(" .. table.concat(params, ",")
            .. ")->" .. ret
    end
    for _, type_name in ipairs({
        "app.HitController",
        "app.HitController.ColliderRequestData",
        "app.HitInfo",
        "app.AttackUserData",
        "app.DamageUserData",
        "app.ColliderReqTracks",
        "via.physics.RequestSetCollider",
        "via.physics.RequestSetColliderUserData",
    }) do
        local td = sdk.find_type_definition(type_name)
        local row = { methods = {}, fields = {} }
        out.types[type_name] = row
        if td then
            pcall(function()
                for _, method in ipairs(td:get_methods() or {}) do
                    local name = tostring(method:get_name() or "")
                    if type_name ~= "app.HitController" or relevant(name) then
                        row.methods[#row.methods + 1] = method_signature(method)
                    end
                end
            end)
            pcall(function()
                for _, field in ipairs(td:get_fields() or {}) do
                    local name = tostring(field:get_name() or "")
                    if type_name ~= "app.HitController" or relevant(name) then
                        local field_type = "?"
                        pcall(function()
                            field_type = tostring(field:get_type():get_full_name())
                        end)
                        row.fields[#row.fields + 1] = name .. " : " .. field_type
                    end
                end
            end)
            table.sort(row.methods)
            table.sort(row.fields)
        else
            row.error = "type not found"
        end
    end
    pcall(function() json.dump_file("IrisWyrmHitControllerAPI.json", out) end)
    return true
end

local function iris_wyrm_describe_native_entry(entry)
    if not entry then return nil end
    local out = { type = "?", fields = {} }
    local td = nil
    pcall(function()
        td = entry:get_type_definition()
        out.type = tostring(td:get_full_name())
    end)
    if not td then return out end
    pcall(function()
        for _, field in ipairs(td:get_fields() or {}) do
            if #out.fields >= 160 then break end
            local name = tostring(field:get_name() or "")
            local row = { name = name, type = "?" }
            pcall(function() row.type = tostring(field:get_type():get_full_name()) end)
            pcall(function()
                local value = entry:get_field(name)
                local kind = type(value)
                if kind == "number" or kind == "boolean" or kind == "string" then
                    row.value = value
                elseif value and value.x ~= nil and value.y ~= nil then
                    row.value = { x = tonumber(value.x), y = tonumber(value.y),
                        z = tonumber(value.z), w = tonumber(value.w) }
                end
            end)
            out.fields[#out.fields + 1] = row
        end
    end)
    return out
end

local function iris_wyrm_native_list_snapshot(list)
    local out = { count = iris_wyrm_managed_count(list) or 0, entries = {} }
    for i = 0, math.min(7, math.max(-1, out.count - 1)) do
        local item = nil
        pcall(function() item = list[i] end)
        if not item then pcall(function() item = list:call("get_Item", i) end) end
        if item then
            out.entries[#out.entries + 1] = iris_wyrm_describe_native_entry(item)
        end
    end
    return out
end

function iris_wyrm_native_hit_capture(args)
    local di = nil
    pcall(function() di = sdk.to_managed_object(args[3]) end)
    if not di then return end
    -- ⭐ 08-18 damageProc runs BEFORE calcDamageReaction, so this is the one
    -- stage early enough to shape the receiver's REACTION (DamageInfo.Damage
    -- is the reaction input, never the HP amount -- that is args[4] of
    -- updateDamageHp, handled by the damage amp dispatch).
    local amp_costume = S.costume
    if amp_costume and amp_costume.wyrm_kind and valid(amp_costume.horse_go) then
        local mount_addr = object_address(amp_costume.horse_go)
        local attacker = iris_wyrm_damage_attacker_go(di)
        -- 08-18 r4: the receiver is THIS HitController's own GameObject
        -- (args[2] = the hc processing the hit). The DamageGameObject field is
        -- only a fallback -- it can be unset at damageProc entry, which is why
        -- incoming wolf hits never matched in round 3.
        local receiver = nil
        pcall(function()
            local this_hc = sdk.to_managed_object(args[2])
            receiver = this_hc and this_hc:call("get_GameObject") or nil
        end)
        if not valid(receiver) then
            pcall(function()
                receiver = di:get_field("<DamageGameObject>k__BackingField")
            end)
        end
        local attacker_is_mount =
            iris_wyrm_go_under_mount(attacker, mount_addr)
        local receiver_is_mount =
            iris_wyrm_go_under_mount(receiver, mount_addr)
        -- 08-18 r5: the incoming-hit presentation call moved to its own
        -- POST-hook on damageProc (iris_wyrm_install_incoming_fx). Calling
        -- callbackHit here at ENTRY threw KeyNotFoundException inside the
        -- engine every time -- the packet's joint/position data is only
        -- resolved during the proc, so the painter looked up an empty key.
        if attacker_is_mount then
            if receiver_is_mount then
                -- Self-hit (the howl dome): kill the reaction here so the
                -- yelp/flinch never computes; the amp dispatch kills the HP.
                for _, field in ipairs({ "Damage", "FixedDamage" }) do
                    pcall(function() di:set_field(field, 0) end)
                end
                S.wyrm_selfhit_blocked =
                    (tonumber(S.wyrm_selfhit_blocked) or 0) + 1
                return
            end
            if not iris_wyrm_damage_go_is_party(receiver) then
                -- Reaction dial: bigger Damage = heavier authored stagger /
                -- knockdown tiers on the victim. Engine still owns which
                -- reaction plays; we only raise the input.
                local rscale = math.max(1.0, math.min(10.0,
                    tonumber(C.wyrm_reaction_scale) or 2.0))
                if rscale > 1.001 then
                    pcall(function()
                        local dmg = tonumber(di:get_field("Damage"))
                        if dmg and dmg > 0.0 then
                            di:set_field("Damage", dmg * rscale)
                        end
                    end)
                end
            end
        end
    end
    local attack_hit, owner_go = nil, nil
    pcall(function()
        attack_hit = di:get_field("<AttackHitController>k__BackingField")
        owner_go = di:get_field("<AttackOwnerObject>k__BackingField")
    end)
    if not (attack_hit and valid(owner_go)) then return end
    -- Shell contacts are explicitly outside this investigation.
    local cached_shell = nil
    pcall(function()
        cached_shell = attack_hit:get_field("<CachedShell>k__BackingField")
    end)
    if cached_shell then return end
    local owner_ch, chara_id = get_component(owner_go, "app.Character"), ""
    pcall(function() chara_id = tostring(owner_ch:call("get_CharaIDString")) end)
    if not chara_id:match("^ch223") then return end
    local attack_list = iris_wyrm_hit_member(attack_hit, "AttackList")
    local collider_list = iris_wyrm_hit_member(attack_hit, "ColliderRequestList")
    local first_hit, attack_user_data, damage_user_data = nil, nil, nil
    if (iris_wyrm_managed_count(attack_list) or 0) > 0 then
        pcall(function() first_hit = attack_list[0] end)
        if not first_hit then
            pcall(function() first_hit = attack_list:call("get_Item", 0) end)
        end
        if first_hit then pcall(function()
            attack_user_data = first_hit:get_field(
                "<AttackUserData>k__BackingField")
            damage_user_data = first_hit:get_field(
                "<DamageUserData>k__BackingField")
        end) end
    end
    local receiver_go = nil
    pcall(function()
        receiver_go = di:get_field("<DamageGameObject>k__BackingField")
    end)
    local owner_name = "ch223"
    pcall(function() owner_name = tostring(owner_go:call("get_Name") or chara_id) end)
    local row = {
        captured_at = os.date("%Y-%m-%d %H:%M:%S"),
        owner_id = chara_id,
        owner_name = owner_name,
        owner_addr = object_address(owner_go),
        receiver_addr = object_address(receiver_go),
        mounted_shadow = S.costume and object_address(S.costume.horse_go)
            == object_address(owner_go) or false,
        attack_list = iris_wyrm_native_list_snapshot(attack_list),
        collider_requests = iris_wyrm_native_list_snapshot(collider_list),
        attack_user_data = iris_wyrm_describe_native_entry(attack_user_data),
        damage_user_data = iris_wyrm_describe_native_entry(damage_user_data),
        hit_controller = iris_wyrm_describe_native_entry(attack_hit),
    }
    S.wyrm_native_hit_capture_pending = row
    S.wyrm_native_hit_capture_status = string.format(
        "captured ch223 native hit: attack=%d collider=%d",
        row.attack_list.count or 0, row.collider_requests.count or 0)
end

local function iris_wyrm_request_owner(hit_controller)
    if not hit_controller then return nil, nil, "" end
    local character, game_object, chara_id = nil, nil, ""
    pcall(function()
        character = hit_controller:get_field("<CachedCharacter>k__BackingField")
        game_object = character and character:call("get_GameObject") or nil
        chara_id = character and tostring(character:call("get_CharaIDString") or "") or ""
    end)
    return character, game_object, chara_id
end

function iris_wyrm_native_request_capture(args, method_name)
    local hit_controller = nil
    pcall(function() hit_controller = sdk.to_managed_object(args[2]) end)
    local _, owner_go, chara_id = iris_wyrm_request_owner(hit_controller)
    if not chara_id:match("^ch223") then return end
    local row = {
        at = os.clock(), method = tostring(method_name), owner_id = chara_id,
        owner_addr = object_address(owner_go),
        mounted_shadow = S.costume and object_address(S.costume.horse_go)
            == object_address(owner_go) or false,
    }
    pcall(function() row.arg1 = tonumber(sdk.to_int64(args[3])) end)
    if method_name == "requestSeqCollider" then
        local tracks = nil
        pcall(function() tracks = sdk.to_managed_object(args[3]) end)
        row.tracks = iris_wyrm_describe_native_entry(tracks)
        row.active_request_ids = {}
        for _, field in ipairs((row.tracks and row.tracks.fields) or {}) do
            local value = tonumber(field.value)
            if value and value ~= -1 then
                row.active_request_ids[tostring(field.name)] = value
            end
        end
        -- requestSeqCollider is called every frame. Idle snapshots previously
        -- evicted the one useful attack frame from the bounded trace before
        -- Aurora could report back; never record an all--1 track set.
        if next(row.active_request_ids) == nil then return end
    else
        local only_go = nil
        pcall(function() only_go = sdk.to_managed_object(args[4]) end)
        row.only_hit_addr = object_address(only_go)
        if method_name == "requestCollider" then
            pcall(function() row.arg3 = tonumber(sdk.to_int64(args[5])) end)
            pcall(function() row.arg4 = sdk.to_int64(args[6]) ~= 0 end)
        else -- registRequestCollider(UInt32, GameObject, Boolean, UInt32)
            pcall(function() row.arg3 = sdk.to_int64(args[5]) ~= 0 end)
            pcall(function() row.arg4 = tonumber(sdk.to_int64(args[6])) end)
        end
    end
    local signature_parts = { row.method, tostring(row.arg1),
        tostring(row.only_hit_addr), tostring(row.arg3), tostring(row.arg4) }
    if row.active_request_ids then
        local names = {}
        for name in pairs(row.active_request_ids) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            signature_parts[#signature_parts + 1] = name .. "="
                .. tostring(row.active_request_ids[name])
        end
    end
    local signature = table.concat(signature_parts, "|")
    S.wyrm_native_request_trace_keys = type(S.wyrm_native_request_trace_keys)
        == "table" and S.wyrm_native_request_trace_keys or {}
    if S.wyrm_native_request_trace_keys[signature] then return end
    S.wyrm_native_request_trace_keys[signature] = true
    S.wyrm_native_request_trace = type(S.wyrm_native_request_trace) == "table"
        and S.wyrm_native_request_trace or {}
    S.wyrm_native_request_trace[#S.wyrm_native_request_trace + 1] = row
    while #S.wyrm_native_request_trace > 96 do
        table.remove(S.wyrm_native_request_trace, 1)
    end
    S.wyrm_native_request_capture_pending = true
    S.wyrm_native_request_status = string.format(
        "captured %s(%s, target=%s, %s, %s)", row.method,
        tostring(row.arg1), tostring(row.only_hit_addr),
        tostring(row.arg3), tostring(row.arg4))
end

function iris_wyrm_install_native_request_capture()
    if S.wyrm_native_request_capture_generation ~= GENERATION then
        S.wyrm_native_request_capture_generation = GENERATION
        S.wyrm_native_request_trace = {}
        S.wyrm_native_request_trace_keys = {}
        S.wyrm_native_request_capture_pending = nil
    end
    rawset(_G, "__iris_wyrm_native_request_capture_dispatch",
        function(args, method_name)
            pcall(iris_wyrm_native_request_capture, args, method_name)
        end)
    local td = sdk.find_type_definition("app.HitController")
    if not td then return false end
    local signatures = {
        requestCollider = "requestCollider(System.UInt32,via.GameObject,System.UInt32,System.Boolean)",
        registRequestCollider = "registRequestCollider(System.UInt32,via.GameObject,System.Boolean,System.UInt32)",
        requestSeqCollider = "requestSeqCollider(app.ColliderReqTracks)",
    }
    for name, signature in pairs(signatures) do
        local hook_name = name
        local guard = "__iris_wyrm_native_request_capture_hook_" .. name
        if not rawget(_G, guard) then
            local method = td:get_method(signature)
            if method then
                sdk.hook(method, function(args)
                    local dispatch = rawget(_G,
                        "__iris_wyrm_native_request_capture_dispatch")
                    if dispatch then dispatch(args, hook_name) end
                end, function(retval) return retval end)
                rawset(_G, guard, true)
            end
        end
    end
    return true
end

function iris_wyrm_install_native_hit_capture()
    rawset(_G, "__iris_wyrm_native_hit_capture_dispatch", function(args)
        pcall(iris_wyrm_native_hit_capture, args)
    end)
    if rawget(_G, "__iris_wyrm_native_hit_capture_hook") then return true end
    local td = sdk.find_type_definition("app.HitController")
    local method = td and td:get_method("damageProc(app.HitController.DamageInfo)")
    if not method then return false end
    sdk.hook(method, function(args)
        local dispatch = rawget(_G, "__iris_wyrm_native_hit_capture_dispatch")
        if dispatch then dispatch(args) end
    end, function(retval) return retval end)
    rawset(_G, "__iris_wyrm_native_hit_capture_hook", true)
    return true
end

-- Enlarge the engine-owned ch223 attack volume for the duration of a mounted
-- native attack.  Hooking getColliderScale preserves the genuine HitController
-- transaction; unlike the retired shells, a miss remains a miss and a contact
-- still owns its native blood, material sound, hit-stop and receiver reaction.
function iris_wyrm_native_collider_scale_dispatch(args)
    if not S.ride_pose_on then return nil end
    local lease = S.wyrm_native_lease
    if not (lease and lease.native_hit_controller) then return nil end
    local this = nil
    pcall(function() this = sdk.to_managed_object(args[2]) end)
    if object_address(this) ~= object_address(lease.native_hit_controller) then
        return nil
    end
    return math.max(1.0, math.min(2.5,
        tonumber(C.wyrm_native_collider_scale) or 1.85))
end

function iris_wyrm_install_native_collider_scale()
    rawset(_G, "__iris_wyrm_native_collider_scale_dispatch",
        iris_wyrm_native_collider_scale_dispatch)
    if rawget(_G, "__iris_wyrm_native_collider_scale_hook") then return true end
    local td = sdk.find_type_definition("app.HitController")
    local method = td and td:get_method(
        "getColliderScale(System.UInt32,System.UInt32)")
    if not method then return false end
    sdk.hook(method,
        function(args)
            local multiplier = nil
            local dispatch = rawget(_G,
                "__iris_wyrm_native_collider_scale_dispatch")
            if dispatch then pcall(function() multiplier = dispatch(args) end) end
            thread.get_hook_storage().iris_wyrm_collider_multiplier = multiplier
            return sdk.PreHookResult.CALL_ORIGINAL
        end,
        function(retval)
            local storage = thread.get_hook_storage()
            local multiplier = storage.iris_wyrm_collider_multiplier
            storage.iris_wyrm_collider_multiplier = nil
            if multiplier then
                local base = sdk.to_float(retval)
                if base and base > 0.0 then
                    return sdk.float_to_ptr(base * multiplier)
                end
            end
            return retval
        end)
    rawset(_G, "__iris_wyrm_native_collider_scale_hook", true)
    return true
end

-- The field-proven attacker ladder (IrisTaming strike hook / downed.lua FF
-- shield shape): DamageInfo speaks GameObjects, and the attacker lives in
-- auto-property backing fields that get_fields() never lists. Shell tier
-- included so the howl dome attributes to the wolf, not the projectile.
function iris_wyrm_damage_attacker_go(di)
    if not di then return nil end
    local ago = nil
    pcall(function() ago = di:get_field("<AttackOwnerObject>k__BackingField") end)
    if ago then return ago end
    local ahc = nil
    pcall(function() ahc = di:get_field("<AttackHitController>k__BackingField") end)
    if ahc then
        local shell = nil
        pcall(function() shell = ahc:get_field("<CachedShell>k__BackingField") end)
        if shell then
            pcall(function()
                local owner = shell:get_field("<OwnerCharacter>k__BackingField")
                ago = owner and owner:call("get_GameObject")
            end)
            if ago then return ago end
        end
        pcall(function()
            local cached = ahc:get_field("<CachedCharacter>k__BackingField")
            ago = cached and cached:call("get_GameObject")
        end)
        if ago then return ago end
    end
    pcall(function() ago = di:get_field("<AttackGameObject>k__BackingField") end)
    return ago
end

-- Hurt colliders can hang their HitController on a CHILD GameObject of the
-- body -- a raw address compare on the root misses them. Walk up to 8 parents.
function iris_wyrm_go_under_mount(go, mount_addr)
    if not (valid(go) and mount_addr) then return false end
    local current = go
    for _ = 1, 8 do
        if not current then return false end
        if object_address(current) == mount_addr then return true end
        local parent = nil
        pcall(function()
            local tf = current:call("get_Transform")
            local ptf = tf and tf:call("get_Parent")
            parent = ptf and ptf:call("get_GameObject")
        end)
        current = parent
    end
    return false
end

-- DD2's combat blood/impact painter (DismemberLab discovery): every character
-- carries an app.EPVExpertCharacterDamageTriggerUnit whose callbackHit
-- (DamageInfo) converts a hit packet into the species-coloured blood + hit
-- presentation. It can sit on the body or on an effect child. Cached per
-- costume per load (S survives resets, wrappers DIE -- the generation stamp
-- forces a re-resolve after every reload).
function iris_wyrm_epv_unit(costume)
    if not (costume and valid(costume.horse_go)) then return nil end
    local cache = costume.wyrm_epv_cache
    if cache and cache.gen == GENERATION then return cache.unit end
    local unit = get_component(costume.horse_go,
        "app.EPVExpertCharacterDamageTriggerUnit")
    if not unit then
        pcall(function()
            local budget = 0
            local function walk(tf)
                if not tf or unit or budget > 200 then return end
                budget = budget + 1
                local cgo = tf:call("get_GameObject")
                if cgo then
                    unit = get_component(cgo,
                        "app.EPVExpertCharacterDamageTriggerUnit")
                    if unit then return end
                end
                local c = tf:call("get_Child")
                while c and not unit do
                    walk(c)
                    c = c:call("get_Next")
                end
            end
            walk(costume.horse_go:call("get_Transform"))
        end)
    end
    costume.wyrm_epv_cache = { gen = GENERATION, unit = unit }
    return unit
end

-- True when a GameObject is the player or a pawn body (chara id ch000/ch001
-- band). The amplifier must never turn the wolf's native friendly contacts
-- into 20x party wipes; those keep their unmodified engine damage.
function iris_wyrm_damage_go_is_party(go)
    if not valid(go) then return false end
    local party = false
    pcall(function()
        local ch = get_component(go, "app.Character")
        local id = ch and tostring(ch:call("get_CharaIDString")) or ""
        party = id:match("^ch00") ~= nil
    end)
    return party
end

-- ⭐ 08-18 THE AUTHORITATIVE DAMAGE LEVER. app.HitController.updateDamageHp is
-- where HP is actually subtracted, and the amount is its own argument (args[4])
-- -- not DamageInfo.Damage (the r96-r98 horse-clamp law). Two jobs, attacker-
-- keyed to the mounted wyrm body:
--   1. SELF-HIT GUARD: the howl dome overlaps its own caster; attacker ==
--      receiver == our wyrm zeroes both stages (no yelp, no HP loss).
--   2. AMPLIFY: enemy receivers get amount x wyrm_native_damage_scale x the
--      attack IV multiplier from _G.IrisIVState. Applies only when a genuine
--      native transaction reached the point of application -- a miss never
--      gets here, so this cannot manufacture damage.
function iris_wyrm_native_damage_amp_dispatch(args)
    local costume = S.costume
    if not (costume and costume.wyrm_kind and valid(costume.horse_go)) then
        return
    end
    local mount_addr = object_address(costume.horse_go)
    if not mount_addr then return end
    local di = sdk.to_managed_object(args[3])
    if not di then return end
    local attacker = iris_wyrm_damage_attacker_go(di)
    if not valid(attacker) or object_address(attacker) ~= mount_addr then
        return
    end
    local receiver = nil
    pcall(function()
        local hc = sdk.to_managed_object(args[2])
        receiver = hc and hc:call("get_GameObject")
    end)
    if not valid(receiver) then
        pcall(function()
            receiver = di:get_field("<DamageGameObject>k__BackingField")
        end)
    end
    if valid(receiver) and object_address(receiver) == mount_addr then
        -- Its own attack came home (the howl dome). Zero the application AND
        -- the reaction inputs; a zero-damage packet is not a hit.
        for _, field in ipairs({ "Damage", "FixedDamage" }) do
            pcall(function() di:set_field(field, 0) end)
        end
        pcall(function() args[4] = sdk.float_to_ptr(0.0) end)
        return
    end
    -- 08-18 round 2: in-flight amplification RETIRED here -- an entire field
    -- session produced zero receipts, consistent with the r98 finding that
    -- updateDamageHp fires only rarely (14x/session) and is not the path these
    -- creature hits take. The counter below stays as knowledge: if it ever
    -- climbs, this method IS reachable for wyrm attacks after all.
    -- Amplification now happens post-hit in iris_wyrm_apply_bonus_damage.
    S.wyrm_dmg_hook_wyrm_hits = (tonumber(S.wyrm_dmg_hook_wyrm_hits) or 0) + 1
end

-- One multiplier for everything the mounted wyrm deals: the panel dial times
-- the attack IV gene (published by the probe's IV state for the active body).
function iris_wyrm_damage_multiplier(costume)
    local dial = math.max(1.0,
        math.min(100.0, tonumber(C.wyrm_native_damage_scale) or 8.0))
    local iv = 1.0
    pcall(function()
        local st = rawget(_G, "IrisIVState")
        if st and costume and valid(costume.horse_go)
            and st.addr == object_address(costume.horse_go)
            and tonumber(st.atk) then
            iv = tonumber(st.atk)
        end
    end)
    return dial * iv, dial, iv
end

-- ⭐ 08-18 round 2 THE WORKING DAMAGE LEVER: post-hit amplification. When a
-- GENUINE native transaction has already landed (observed HP delta -- blood,
-- material sound and reaction all engine-owned and already playing), scale
-- that hit's magnitude by draining the remainder through the proven setHp
-- ladder (downed.lua:319 shape; the game's HP monitor triggers natural death
-- at 0 -- probe law 9237). A miss never gets here, so no fake damage exists.
-- ⛔ NEVER "upgrade" this to a fabricated DamageInfo packet: that path is
-- retired with access violations (griffin_damage_via_pipeline, 08-14).
function iris_wyrm_apply_bonus_damage(lease, native_delta, label)
    local costume = lease and lease.costume or nil
    local mult, dial, iv = iris_wyrm_damage_multiplier(costume)
    if mult <= 1.001 then return end
    local delta = math.max(0.0, tonumber(native_delta) or 0.0)
    if delta <= 0.01 then return end
    local target = lease.target
    if not valid(target) then return end
    local hc = nil
    pcall(function() hc = target:call("get_HitController") end)
    if not hc and valid(lease.target_go) then
        hc = get_component(lease.target_go, "app.HitController")
    end
    if not hc then
        S.wyrm_dmg_amp_last = tostring(label or "hit")
            .. ": bonus skipped (no HitController)"
        return
    end
    local hp = nil
    pcall(function() hp = tonumber(hc:call("get_Hp")) end)
    if not hp or hp <= 0.0 then return end
    local bonus = delta * (mult - 1.0)
    local new = math.max(0.0, hp - bonus)
    local applied = false
    local function try(fn)
        if applied then return end
        pcall(fn)
        local rb = nil
        pcall(function() rb = tonumber(hc:call("get_Hp")) end)
        if rb and rb <= new + 0.5 then applied = true end
    end
    local function ladder()
        try(function() hc:call("setHp(System.Single, System.Boolean, System.Int32)",
            new, true, 0) end)
        try(function() hc:call("setHp(System.Single, System.Boolean)", new, true) end)
        try(function() hc:call("setHp(System.Single)", new) end)
        try(function() hc:call("set_Hp(System.Single)", new) end)
    end
    ladder()
    if not applied and new < 1.0 then
        -- 08-18 r3 field receipt (run 11 "hp 13 -> 13 REFUSED"): the engine
        -- refuses a direct HP write to 0 on a living body. Leave the victim
        -- at 1 HP -- the next native contact kills with full presentation.
        new = 1.0
        ladder()
    end
    S.wyrm_dmg_amp_last = string.format(
        "%s: native %.0f + bonus %.0f (x%.1f dial x%.2f IV) hp %.0f -> %.0f%s",
        tostring(label or "hit"), delta, bonus, dial, iv, hp,
        applied and new or hp, applied and "" or " | REFUSED")
    iris_wyrm_combat_trace(lease, "bonus-damage", S.wyrm_dmg_amp_last)
end

-- ⭐ 08-18 r8: full scripted damage for the PINNED maul's chomps. The native
-- transaction routes are conclusively walled here (parked-graph clips own no
-- events for the hold-down set; the mounted ActionManager rejects every
-- request even in a live window with the catch paired -- receipts 16:31/16:32,
-- retainedEnds=317, maulContacts=0). A pinned victim physically in the jaws
-- cannot be a miss, so the honesty contract holds: this only ever runs at a
-- chomp contact frame on a held target. Same setHp ladder + 1-HP kill floor.
function iris_wyrm_apply_direct_damage(lease, label)
    local costume = lease and lease.costume or nil
    local mult = iris_wyrm_damage_multiplier(costume)
    local base = math.max(1.0, tonumber(C.wyrm_maul_chomp_damage) or 45.0)
    local total = base * mult
    local target = lease.target
    if not valid(target) then return false end
    local hc = nil
    pcall(function() hc = target:call("get_HitController") end)
    if not hc and valid(lease.target_go) then
        hc = get_component(lease.target_go, "app.HitController")
    end
    if not hc then return false end
    local hp = nil
    pcall(function() hp = tonumber(hc:call("get_Hp")) end)
    if not hp or hp <= 0.0 then return false, false end
    local new = math.max(0.0, hp - total)
    -- r9: a chomp that would take HP to 0 is LETHAL. The engine refuses direct
    -- HP writes to 0 (run 11 receipt), so the caller finishes with the proven
    -- kill lever instead of stranding the prey at the 1-HP floor -- run 11
    -- field report: "goblin stands up as if nothing happened" at hp 1.
    local lethal = new <= 0.0
    local applied = false
    local function try(fn)
        if applied then return end
        pcall(fn)
        local rb = nil
        pcall(function() rb = tonumber(hc:call("get_Hp")) end)
        if rb and rb <= new + 0.5 then applied = true end
    end
    local function ladder()
        try(function() hc:call("setHp(System.Single, System.Boolean, System.Int32)",
            new, true, 0) end)
        try(function() hc:call("setHp(System.Single, System.Boolean)", new, true) end)
        try(function() hc:call("setHp(System.Single)", new) end)
        try(function() hc:call("set_Hp(System.Single)", new) end)
    end
    ladder()
    if not applied and new < 1.0 then
        new = 1.0
        ladder()
    end
    S.wyrm_dmg_amp_last = string.format(
        "%s: %.0f dealt (x%.1f of %.0f base) hp %.0f -> %.0f%s%s",
        tostring(label or "chomp"), total, mult, base, hp,
        applied and new or hp, applied and "" or " | REFUSED",
        lethal and " | LETHAL" or "")
    iris_wyrm_combat_trace(lease, "pin-damage", S.wyrm_dmg_amp_last)
    return applied, lethal
end

-- ⭐⭐ 08-18 r9 CHOMP PRESENTATION -- replay a REAL packet, never a synthetic.
-- Field verdict today: the mount's incoming-hit blood WORKS, and that route's
-- only difference from every failed blood attempt is the packet -- an
-- engine-RESOLVED DamageInfo replayed into the victim's own EPV damage-trigger
-- unit paints; DismemberLab's reconstructed packets never did (four rounds,
-- including a field-captured sword hit copied field-for-field). The wolf's
-- genuine X bites on this prey supply the template: the incoming-fx PRE hook
-- stashes the resolved packet when the receiver is the current lease target,
-- POST retains it in _G.IrisWyrmPreyPkt (add_ref -- managed retention, the
-- same pattern DismemberLab:504 uses; released on replacement).
function iris_wyrm_prey_paint_chomp(lease)
    local pkt = rawget(_G, "IrisWyrmPreyPkt")
    if not (pkt and pkt.di and valid(lease.target_go)) then
        S.wyrm_maul_fx_status = "no captured prey packet yet"
        return false
    end
    if pkt.addr ~= object_address(lease.target_go) then
        S.wyrm_maul_fx_status = "prey packet is for another body"
        return false
    end
    local unit = get_component(lease.target_go,
        "app.EPVExpertCharacterDamageTriggerUnit")
    if not unit then
        pcall(function()
            local budget = 0
            local function walk(tf)
                if not tf or unit or budget > 200 then return end
                budget = budget + 1
                local cgo = tf:call("get_GameObject")
                if cgo then
                    unit = get_component(cgo,
                        "app.EPVExpertCharacterDamageTriggerUnit")
                    if unit then return end
                end
                local c = tf:call("get_Child")
                while c and not unit do
                    walk(c)
                    c = c:call("get_Next")
                end
            end
            walk(lease.target_go:call("get_Transform"))
        end)
    end
    if not unit then
        S.wyrm_maul_fx_status = "prey EPV unit missing"
        return false
    end
    -- r11: the packet's spray direction is baked from the ORIGINAL hit (the
    -- pounce), and by chomp time it points through the wolf's own body --
    -- field verdict: "the blood was coming from the wolf". Re-aim the spray
    -- out in front of the jaws on every replay. One pcall per set_field
    -- (blood_fire law) so a throw can't skip the paint below.
    pcall(function()
        local tf = lease.costume and valid(lease.costume.horse_go)
            and lease.costume.horse_go:call("get_Transform") or nil
        local fwd = tf and tf:call("get_AxisZ") or nil
        if fwd then
            local vec = Vector3f.new(
                (tonumber(fwd.x) or 0.0) * 0.85, 0.5,
                (tonumber(fwd.z) or 0.0) * 0.85)
            pcall(function() pkt.di:set_field("AttackVec", vec) end)
            pcall(function() pkt.di:set_field("HitBackVec", vec) end)
        end
    end)
    -- r13: DamageInfo has NO position field at all (il2cpp: 81 fields, the
    -- only vec3s are the two direction vectors) -- the paint anchors to the
    -- packet's OBJECT references, and ours name the WOLF as attacker, which
    -- is the remaining suspect for "the blood is coming from Shadow's body".
    -- Re-point the attack side at the victim itself; if the painter throws
    -- on that shape (HitHistory is keyed per attacker), fall back to the
    -- original wolf-anchored shape so a chomp never loses its paint.
    local function fire()
        return pcall(function()
            -- post-proc packets can carry a zeroed Damage (companion clamp
            -- law); the painter skips zero-damage packets as non-hits.
            local d = tonumber(pkt.di:get_field("Damage")) or 0
            if d <= 0 and tonumber(pkt.dmg) then
                pkt.di:set_field("Damage", pkt.dmg)
            end
            unit:call("callbackHit(app.HitController.DamageInfo)", pkt.di)
        end)
    end
    local shape = "self-anchored"
    pcall(function()
        pkt.di:set_field("<AttackGameObject>k__BackingField", lease.target_go)
    end)
    pcall(function()
        pkt.di:set_field("<AttackOwnerObject>k__BackingField", lease.target_go)
    end)
    local ok = fire()
    if not ok and lease.costume and valid(lease.costume.horse_go) then
        shape = "wolf-anchored fallback"
        pcall(function()
            pkt.di:set_field("<AttackGameObject>k__BackingField",
                lease.costume.horse_go)
        end)
        pcall(function()
            pkt.di:set_field("<AttackOwnerObject>k__BackingField",
                lease.costume.horse_go)
        end)
        ok = fire()
    end
    S.wyrm_maul_fx_status = ok
        and ("chomp painted (" .. shape .. ")")
        or "chomp paint THREW (both shapes)"
    iris_wyrm_combat_trace(lease, "chomp-fx", S.wyrm_maul_fx_status)
    return ok
end

-- r10: the deferred maul death blow. r9 killed at the chomp that broke the HP
-- and run 13's field verdict was "kills the goblin instantly before the wolf
-- even took a bite" -- the ragdoll erased the whole savaging. Now the floor
-- holds the prey at 1 HP through the chomps and THIS fires at the release
-- fling (or any early lease exit that still owes a death). Unpin FIRST -- a
-- think-stopped body cannot run its die loop -- then the proven kill lever
-- (NicksDevtools/CombatTools.lua:78, Nick's own kill button).
function iris_wyrm_pin_kill(lease)
    pcall(function()
        if valid(lease.target) then
            lease.target:call("set_IsThinkStop", false)
            local m = lease.target:call("get_Motion")
            if m then m:call("set_PlaySpeed", 1.0) end
        end
    end)
    lease.pin_maul = nil
    lease.pin_jolt_until = nil
    local killed = false
    pcall(function()
        if valid(lease.target) then
            lease.target:call("killAndSetDieLoop", nil)
            killed = true
        end
    end)
    S.wyrm_native_status = killed
        and "pinned maul: prey slain (release fling)"
        or "pinned maul: kill lever threw (left at 1 HP)"
    log(S.wyrm_native_status)
    iris_wyrm_combat_trace(lease, "maul-kill", S.wyrm_native_status)
    return killed
end

-- ⭐ 08-18 r5 INCOMING-HIT PRESENTATION, POST-PROC. Round 3/4 called the EPV
-- painter (app.EPVExpertCharacterDamageTriggerUnit.callbackHit) at damageProc
-- ENTRY and it threw KeyNotFoundException inside the engine on every hit --
-- the packet's joint/position data only exists once the proc has run. This
-- hook decides at PRE (and remembers the pre-clamp Damage), then calls the
-- painter at POST -- same invocation, the packet is still alive (⛔ never
-- retain di across frames -- UAF law). Damage is re-asserted before painting
-- because the companion clamp zeroes it mid-proc and the painter skips
-- zero-damage packets as non-hits.
function iris_wyrm_install_incoming_fx()
    rawset(_G, "__iris_wyrm_incoming_fx_pre", function(args)
        local storage = thread.get_hook_storage()
        storage.iris_wyrm_fx_di = nil
        storage.iris_wyrm_fx_dmg = nil
        storage.iris_wyrm_prey_di = nil
        storage.iris_wyrm_prey_dmg = nil
        storage.iris_wyrm_prey_addr = nil
        local costume = S.costume
        if not (costume and costume.wyrm_kind and valid(costume.horse_go)) then
            return
        end
        local di = sdk.to_managed_object(args[3])
        if not di then return end
        local mount_addr = object_address(costume.horse_go)
        local receiver = nil
        pcall(function()
            local this_hc = sdk.to_managed_object(args[2])
            receiver = this_hc and this_hc:call("get_GameObject") or nil
        end)
        if not iris_wyrm_go_under_mount(receiver, mount_addr) then
            -- r9: not the mount -- but if it IS the current prey, stash the
            -- engine's own resolved packet for chomp-time replay (real
            -- resolved packets PAINT; synthetics never did). No attacker
            -- filter: the wolf's own bite packet is the best template.
            local lease = S.wyrm_native_lease
            local prey_go = lease and lease.target_go or nil
            if prey_go and valid(prey_go) and valid(receiver)
                and object_address(receiver) == object_address(prey_go) then
                local pdmg = nil
                pcall(function() pdmg = tonumber(di:get_field("Damage")) end)
                if pdmg and pdmg > 0.0 then
                    storage.iris_wyrm_prey_di = di
                    storage.iris_wyrm_prey_dmg = pdmg
                    storage.iris_wyrm_prey_addr = object_address(receiver)
                    -- r14: open the hurt-vocal watch window -- the prey's
                    -- native pain cry posts within a breath of a real hit;
                    -- IrisWildCats' trigger hook records it for the maul.
                    rawset(_G, "IrisWyrmPreyVocalWatch", {
                        addr = object_address(receiver),
                        until_t = os.clock() + 0.4,
                    })
                end
            end
            return
        end
        local attacker = iris_wyrm_damage_attacker_go(di)
        if iris_wyrm_go_under_mount(attacker, mount_addr) then return end
        if iris_wyrm_damage_go_is_party(attacker) then return end
        local dmg = nil
        pcall(function() dmg = tonumber(di:get_field("Damage")) end)
        if not (dmg and dmg > 0.0) then return end
        local now = os.clock()
        if now < (tonumber(S.wyrm_incoming_fx_at) or 0.0) then return end
        S.wyrm_incoming_fx_at = now + 0.08
        storage.iris_wyrm_fx_di = di
        storage.iris_wyrm_fx_dmg = dmg
        -- Log-side receipt (throttled): proves the receiver match fired even
        -- if the post-stage paint fails silently.
        if now >= (tonumber(S.wyrm_incoming_fx_seen_log_at) or 0.0) then
            S.wyrm_incoming_fx_seen_log_at = now + 2.0
            log(string.format(
                "incoming wolf hit SEEN (dmg %.0f) - painting post-proc", dmg))
        end
    end)
    rawset(_G, "__iris_wyrm_incoming_fx_post", function()
        local storage = thread.get_hook_storage()
        -- r9: retain the prey's resolved packet for chomp replay. add_ref is
        -- the managed-retention pattern (DismemberLab:504); the previous
        -- packet is released on replacement so only one ref is ever held.
        local pdi = storage.iris_wyrm_prey_di
        if pdi then
            local pdmg = storage.iris_wyrm_prey_dmg
            local paddr = storage.iris_wyrm_prey_addr
            storage.iris_wyrm_prey_di = nil
            storage.iris_wyrm_prey_dmg = nil
            storage.iris_wyrm_prey_addr = nil
            if pcall(function() pdi:add_ref() end) then
                local old = rawget(_G, "IrisWyrmPreyPkt")
                if old and old.di then
                    pcall(function() old.di:release() end)
                end
                rawset(_G, "IrisWyrmPreyPkt",
                    { di = pdi, dmg = pdmg, addr = paddr, t = os.clock() })
            end
        end
        local di = storage.iris_wyrm_fx_di
        local dmg = storage.iris_wyrm_fx_dmg
        storage.iris_wyrm_fx_di = nil
        storage.iris_wyrm_fx_dmg = nil
        if not di then return end
        local unit = iris_wyrm_epv_unit(S.costume)
        if not unit then
            S.wyrm_incoming_fx_status = "EPV damage-trigger unit MISSING"
            if S.wyrm_incoming_fx_status ~= S.wyrm_incoming_fx_logged then
                S.wyrm_incoming_fx_logged = S.wyrm_incoming_fx_status
                log("incoming FX: " .. S.wyrm_incoming_fx_status)
            end
            return
        end
        pcall(function()
            if tonumber(dmg) and (tonumber(di:get_field("Damage")) or 0) <= 0 then
                di:set_field("Damage", dmg)
            end
        end)
        local ok = pcall(function()
            unit:call("callbackHit(app.HitController.DamageInfo)", di)
        end)
        if ok then
            S.wyrm_incoming_fx_count =
                (tonumber(S.wyrm_incoming_fx_count) or 0) + 1
            S.wyrm_incoming_fx_status = string.format(
                "painted %d (post-proc, dmg %.0f)",
                S.wyrm_incoming_fx_count, tonumber(dmg) or -1)
        else
            S.wyrm_incoming_fx_status = "callbackHit threw even post-proc"
        end
        -- Every outcome lands in the framework log so the next session can
        -- read the verdict without relaying panel text.
        if S.wyrm_incoming_fx_status ~= S.wyrm_incoming_fx_logged then
            S.wyrm_incoming_fx_logged = S.wyrm_incoming_fx_status
            log("incoming FX: " .. tostring(S.wyrm_incoming_fx_status))
        end
    end)
    -- ⭐ 08-18 r6: hook BOTH receiver-side entries. downed.lua's r83 law:
    -- for COMPANION bodies "the controller that ACTUALLY takes the damage is
    -- the receiver handed to calcDamageReaction -- two different HP stores on
    -- the same body". The proven companion clamp lives on calcDamageReaction;
    -- damageProc may never fire for the wolf as receiver at all. The 0.08s
    -- throttle in the pre-dispatch keeps a hit that traverses both methods
    -- from painting twice.
    local td = sdk.find_type_definition("app.HitController")
    if not td then return false end
    for guard, signature in pairs({
        __iris_wyrm_incoming_fx_hook = "damageProc(app.HitController.DamageInfo)",
        __iris_wyrm_incoming_fx_hook_calc =
            "calcDamageReaction(app.HitController.DamageInfo)",
    }) do
        if not rawget(_G, guard) then
            local method = td:get_method(signature)
            if method then
                sdk.hook(method, function(args)
                    local dispatch = rawget(_G, "__iris_wyrm_incoming_fx_pre")
                    if dispatch then pcall(dispatch, args) end
                end, function(retval)
                    local dispatch = rawget(_G, "__iris_wyrm_incoming_fx_post")
                    if dispatch then pcall(dispatch) end
                    return retval
                end)
                rawset(_G, guard, true)
            end
        end
    end
    return true
end

function iris_wyrm_install_native_damage_amp()
    -- Dispatch through _G, re-pointed every load, so the single persistent
    -- hook always runs the freshest code. ⛔ NEVER install this hook per
    -- reload without the guard: amplification is not idempotent -- stacked
    -- closures would each multiply and turn x8 into x64.
    rawset(_G, "__iris_wyrm_native_damage_amp_dispatch", function(args)
        pcall(iris_wyrm_native_damage_amp_dispatch, args)
    end)
    if rawget(_G, "__iris_wyrm_native_damage_amp_hook") then return true end
    local td = sdk.find_type_definition("app.HitController")
    local method = td and td:get_method("updateDamageHp")
    if not method then return false end
    sdk.hook(method, function(args)
        local dispatch = rawget(_G, "__iris_wyrm_native_damage_amp_dispatch")
        if dispatch then dispatch(args) end
    end, function(retval) return retval end)
    rawset(_G, "__iris_wyrm_native_damage_amp_hook", true)
    return true
end

function iris_wyrm_native_hit_capture_flush()
    local row = S.wyrm_native_hit_capture_pending
    if row then
        S.wyrm_native_hit_capture_pending = nil
        pcall(function() json.dump_file("IrisWyrmNativeHitCapture.json", row) end)
    end
    if S.wyrm_native_request_capture_pending then
        S.wyrm_native_request_capture_pending = nil
        pcall(function()
            json.dump_file("IrisWyrmNativeColliderRequests.json", {
                generated_at = os.date("%Y-%m-%d %H:%M:%S"),
                requests = S.wyrm_native_request_trace or {},
            })
        end)
    end
end

pcall(iris_wyrm_dump_hitcontroller_api)
pcall(iris_wyrm_install_native_hit_capture)
pcall(iris_wyrm_install_native_request_capture)
pcall(iris_wyrm_install_native_collider_scale)
pcall(iris_wyrm_install_native_damage_amp)
pcall(iris_wyrm_install_incoming_fx)

function iris_wyrm_native_maul_stages()
    return {
        { at = 0.08, bank = 20, clip = 4010 },
        { at = 0.42, bank = 20, clip = 4012 },
        { at = 0.86, bank = 20, clip = 4000 },
        { at = 1.62, bank = 20, clip = 4020 },
    }
end

-- Recreate the exact ch223 Setting Aurora captured from a natural wolf taking a
-- pawn away to maul.  A live capture wins; the JSON survives script/game reloads
-- and is overlaid on a known-good baseline.  Managed/object-valued fields are
-- deliberately skipped: this contract had a nil interpolator and the nullable
-- FallCancelHeight can safely retain its constructor default.
function iris_wyrm_native_catch_setting()
    if S.wyrm_catch_setting then
        local alive = false
        pcall(function()
            alive = S.wyrm_catch_setting:get_type_definition() ~= nil
        end)
        if alive then return S.wyrm_catch_setting end
        S.wyrm_catch_setting = nil
    end
    local setting = nil
    pcall(function()
        setting = sdk.create_instance("app.CatchController.Setting"):add_ref()
        pcall(function() setting:call(".ctor()") end)
    end)
    if not setting then return nil end
    local values = {
        CatchType = 1,
        Name = "",
        InterpolationFrame = 10.0,
        ParentJointName = "C_PropA",
        IsForceUseExtraJoint = false,
        InterpolationType = 0,
        IsInterpolatingCaughtEnableLanding = false,
        EscapeSec = 3.4028234663852886e38,
        ResistSec = 3.4028234663852886e38,
        NearlyEscapeSec = -1.0,
        GachaValue = 3.4028234663852886e38,
        IsDisableCaughtIK = true,
        CatchStartAction = "TakeAwayDownCatchSuccess",
        CaughtStartAction = "Caught_TakeAwayWolf_StartLoop_D",
        CatchStartActionLayer = 0,
        CatchCancelAction = "HoldDownCatchCancel",
        IsDisableCatchCancelActionOnAbort = false,
        CaughtCancelAction = "Caught_TakeAwayWolf_Cancel_D",
        CatchEscapeAction = "TakeAwayDownCatchMoveEscape",
        CaughtEscapeAction = "Caught_TakeAwayWolf_Escape_D",
        IsNoCheckCaughtStartAndCancelAction = false,
    }
    local string_fields = {
        Name = true, ParentJointName = true, ConstraintChildJointName = true,
        CatchStartAction = true, CaughtStartAction = true,
        CatchCancelAction = true, CaughtCancelAction = true,
        CaughtCancelActionForDead = true, CaughtDieAction = true,
        CaughtDamageAction = true, CatchCaughtDamageAction = true,
        CatchRestartAction = true, CatchEscapeAction = true,
        CaughtEscapeAction = true, CatchResistAction = true,
        CaughtResistAction = true, CaughtNearlyEscapeAction = true,
    }
    pcall(function()
        local saved = json.load_file("IrisHorseRodeo_wolf_catch_setting.json")
        if type(saved) == "table" and type(saved.fields) == "table" then
            for _, row in ipairs(saved.fields) do
                local name, value = tostring(row.name or ""), row.value
                local kind = type(value)
                if name ~= "" and (kind == "number" or kind == "boolean"
                    or (kind == "string" and string_fields[name])) then
                    values[name] = value
                end
            end
        end
    end)
    for name, value in pairs(values) do
        pcall(function()
            if string_fields[name] then
                setting:set_field(name, sdk.create_managed_string(tostring(value)))
            else
                setting:set_field(name, value)
            end
        end)
    end
    S.wyrm_catch_setting = setting
    rawset(_G, "IrisWyrmNativeCatchSetting", setting)
    S.wyrm_catch_capture_status = "saved ch223 catch contract loaded"
    return setting
end

local function iris_wyrm_native_catch_active(controller)
    local active = false
    pcall(function() active = controller and controller:call("get_IsActive") == true end)
    return active
end

local function iris_wyrm_native_caught_active(target)
    local controller, active = nil, false
    pcall(function()
        controller = target and target:call("get_CaughtController") or nil
        active = controller and controller:call("get_IsActive") == true or false
    end)
    return active, controller
end

local function iris_wyrm_native_abort_catch(lease)
    if not lease then return false end
    -- Opt out before calling terminal methods; otherwise the scoped retention
    -- hook would correctly treat our deliberate release as another premature
    -- mounted-FSM cleanup and block it.
    lease.retain_catch = false
    local released = false
    pcall(function()
        local cc = lease.catch_controller
        if cc then
            cc:call("set_IsRejectAbortOnDefault(System.Boolean)", false)
            cc:call("set_IsContinue(System.Boolean)", false)
        end
        if cc and cc:call("get_IsActive") == true then
            cc:call("abort(System.Boolean)", true)
            released = true
        end
    end)
    pcall(function()
        local caught = lease.caught_controller
        if caught then
            caught:call("set_IsRejectAbortOnDefault(System.Boolean)", false)
            caught:call("set_IsContinue(System.Boolean)", false)
        end
        if caught and caught:call("get_IsActive") == true then
            caught:call("abortDirect")
            released = true
        end
    end)
    lease.release_requested = released or lease.release_requested
    return released
end

-- ⭐ 08-18 r7 THE MAUL LIVE WINDOW. Wake exactly what the paired catch needs
-- (FSM + think + ActionInterface) for the maul's few seconds; AI and nav stay
-- dead the whole time. Containment the retired global takeover never had: the
-- r3 always-on drift cancel eats every non-commanded translation same-tick,
-- so the woken graph cannot walk the mount anywhere. ownership_at is pushed
-- past the window so the 4Hz parking tick does not strangle it (belt: the
-- tick also bails on lease.native_maul_window).
function iris_wyrm_native_maul_window_open(costume, now, secs)
    if not (costume and valid(costume.horse_character)) then return false end
    local opened = false
    pcall(function()
        costume.ownership_at = now + (tonumber(secs) or 6.5)
        local ai = costume.native_ai
        if ai then ai:call("set_Enabled", false) end
        local nav = costume.native_nav
        if nav then nav:call("set_Enabled", false) end
        local act = costume.native_action_interface
        if act then act:call("set_Enabled", true) end
        local fsm = costume.native_fsm
        if fsm then fsm:call("set_Enabled", true) end
        costume.horse_character:call("set_IsThinkStop", false)
        opened = true
    end)
    return opened
end

function iris_wyrm_native_maul_window_close(costume)
    if not costume then return end
    pcall(function()
        local fsm = costume.native_fsm
        if fsm then fsm:call("set_Enabled", false) end
        local act = costume.native_action_interface
        if act then act:call("set_Enabled", false) end
        if valid(costume.horse_character) then
            costume.horse_character:call("set_IsThinkStop", true)
        end
        costume.ownership_at = 0.0
    end)
end

-- ⭐⭐ 08-18 r8 THE PINNED MAUL -- the shipping RT maul. Field receipts killed
-- both native wolf-side routes: parked-graph hold-down clips own no attack
-- events, and the mounted ActionManager rejects every request even inside a
-- live window with the catch paired (Action=Invalid, retainedEnds=317,
-- maulContacts=0; the C_PropA attach also parks the prey standing under the
-- belly at wyrm scale). What IS achievable: PIN the downed prey via think-stop
-- in its own native down pose (slow PlaySpeed = struggling), play the wolf's
-- authored maul choreography, and land scripted damage + the victim's own EPV
-- blood callback at every chomp. The prey is physically under the jaws, so a
-- chomp can never be a miss.
function iris_wyrm_pin_maul_start(lease, now)
    local costume = lease.costume
    if not (costume and valid(lease.target)) then return false end
    lease.direct_maul = true
    lease.pin_maul = true
    lease.phase = "maul"
    lease.label = "pinned maul"
    -- r10: keep converging through the push-down so the slam lands ON the
    -- body even when RT fired from the 1.0-1.6m edge of the contact ring.
    lease.maul_converge_until = now + 0.55
    -- r12: PIN THE POSITION, not just the pose. Field video 18-52: the chomp
    -- flinch restarts replay the damage clip's root-motion shove (and the
    -- replayed packet may add engine knockback), sliding the prey ~20m out
    -- of the jaws while the wolf mauled bare ground. The anchor is clamped
    -- every tick below; unpin frees it for the death fling.
    pcall(function()
        local ap = universal_pos(lease.target_go)
        if ap then
            lease.pin_anchor = { x = ap.x, y = ap.y, z = ap.z }
        end
    end)
    pcall(function()
        lease.target:call("set_IsThinkStop", true)
        local motion = lease.target:call("get_Motion")
        if motion then motion:call("set_PlaySpeed", 0.30) end
    end)
    -- r13 (Aurora: "can the goblin be lying down"): capture the LYING frame.
    -- The r11 flinch restarted the damage clip at frame 0 -- the STANDING
    -- start of the reaction -- which is what kept sitting him up. The chomp
    -- flinch now rewinds a few frames and plays back toward this anchor, and
    -- the tick clamps the clip so it can never advance past it.
    pcall(function()
        local motion = lease.target:call("get_Motion")
        local layer = motion and motion:call("getLayer", 0)
        if layer then
            lease.pin_frame = tonumber(layer:call("get_Frame"))
        end
    end)
    -- r13 POSE-SEEK window: knockdown/lie/get-up are ONE clip (trace: node
    -- DmgShrinkLLL through the whole arc), so RT during the get-up tail
    -- anchors a half-standing frame. The tick walks the anchor BACKWARD
    -- until the head joint is actually near the ground.
    lease.pin_seek_until = now + 0.45
    -- Lyra's captured hold-down choreography: push-down, ADD start/hit, then
    -- the shake/chomp loop and release. Every chomp stage deals + bleeds.
    lease.visual_stages = {
        { at = 0.00, bank = 30, clip = 810, blend = 8.0 },
        { at = 0.42, bank = 20, clip = 4010, blend = 6.0 },
        { at = 0.86, bank = 20, clip = 4012, blend = 5.0 },
        { at = 1.20, bank = 20, clip = 4000, blend = 5.0,
            maul_contact = true, pin_damage = true, result_at = 0.30 },
        { at = 1.58, bank = 20, clip = 4040, blend = 6.0 },
        { at = 1.92, bank = 20, clip = 4041, blend = 4.0 },
        { at = 2.26, bank = 20, clip = 4043, blend = 4.0,
            maul_contact = true, pin_damage = true, result_at = 0.30 },
        { at = 2.66, bank = 20, clip = 4041, blend = 4.0 },
        { at = 3.00, bank = 20, clip = 4043, blend = 4.0,
            maul_contact = true, pin_damage = true, result_at = 0.30 },
        { at = 3.40, bank = 20, clip = 4041, blend = 4.0 },
        { at = 3.74, bank = 20, clip = 4043, blend = 4.0,
            maul_contact = true, pin_damage = true, result_at = 0.30 },
        { at = 4.14, bank = 20, clip = 4050, blend = 8.0 },
    }
    lease.t0 = now
    lease.until_t = now + 4.75
    if S.wyrm_down_release
        and S.wyrm_down_release.target_addr == object_address(lease.target) then
        S.wyrm_down_release.at = lease.until_t + 0.15
    end
    lease.approach_secs = 0.0
    lease.approach_done = true
    S.wyrm_atk_until = lease.until_t
    rawset(_G, "IrisWyrmNativeAttackLease", {
        mount_addr = object_address(costume.horse_character),
        target_addr = object_address(lease.target),
        until_t = lease.until_t,
    })
    S.wyrm_native_status = "pinned maul: prey held, savaging"
    log(S.wyrm_native_status)
    iris_wyrm_combat_trace(lease, "maul-start", S.wyrm_native_status)
    return true
end

-- Convert the still-live opener lease into the captured paired catch.  AI and
-- navigation stay disabled, but the action FSM and both CatchControllers remain
-- live: they own the predator animation, victim reaction, C_PropA attachment,
-- carry and maul damage exactly as they do for a wild ch223.
function iris_wyrm_native_begin_maul(lease, now, direct)
    if not (lease and lease.action_manager and valid(lease.target)) then
        return false
    end
    -- r8: RT routes to the pinned maul (panel toggle wyrm_native_maul);
    -- unchecked falls through to the scripted stationary maul below.
    if direct and C.wyrm_native_maul ~= false then
        if iris_wyrm_pin_maul_start(lease, now) then return true end
    end
    local function arm_stationary_maul(paired)
        -- Mounted ch223 does not own Puppeteer's complete action graph.  Keep the
        -- contextual maul planted: the catch pair may attach the victim, while
        -- the atlas supplies the predator pose and timed native receiver hits.
        -- If DD2 immediately retires the caught side, the maul still completes
        -- against the already-downed target instead of bucking the camera or
        -- silently cancelling after a quarter of a second.
        lease.direct_maul = true
        lease.phase = "maul"
        lease.label = paired and "contextual maul" or "contextual hold-down maul"
        lease.visual_stages = {
            -- ⭐ 08-18 r4 FIELD LAW (trace run 48: perfect 0.11m hold, jaw-50
            -- posted at every chomp, ZERO transactions): neither the hold-down
            -- clips' own events (101/103) nor ANY replayed request transacts on
            -- the parked graph. Only clip-OWNED attack events do -- so every
            -- chomp is now the proven standalone bite 50:50 (6/6 as the combo
            -- opener), framed by the hold/shake clips for the maul read.
            -- result_at 0.85: 50:50's authored bite event lands ~0.6s in; the
            -- old +0.28 check would call a genuine hit a miss.
            -- r6 RHYTHM (Aurora: "it just spams a normal bite over and over"):
            -- r5 let each 50:50 bite run a full second -- three seconds of
            -- bite in a 4.4s maul reads as bite spam, not a pin. The bite is
            -- now a quick SNAP (speed 1.5, cut at 0.55s -- its authored event
            -- fires at ~0.41s real time) and the hold/shake clips own the
            -- space between. Damage law unchanged: only 50:50's clip-owned
            -- event transacts, so every snap is still the real jaw.
            { at = 0.00, bank = 30, clip = 810, blend = 8.0 },
            { at = 0.42, bank = 20, clip = 4012, blend = 5.0 },
            { at = 0.80, bank = 50, clip = 50, blend = 5.0, speed = 1.5,
                maul_contact = true, result_at = 0.55 },
            { at = 1.35, bank = 20, clip = 4041, blend = 5.0 },
            { at = 2.20, bank = 50, clip = 50, blend = 5.0, speed = 1.5,
                maul_contact = true, result_at = 0.55 },
            { at = 2.75, bank = 20, clip = 4041, blend = 5.0 },
            { at = 3.60, bank = 50, clip = 50, blend = 5.0, speed = 1.5,
                maul_contact = true, result_at = 0.55 },
            { at = 4.15, bank = 20, clip = 4041, blend = 5.0 },
            { at = 4.75, bank = 20, clip = 4050, blend = 8.0 },
        }
        lease.t0 = now
        lease.until_t = now + 5.30
        if S.wyrm_down_release
            and S.wyrm_down_release.target_addr == object_address(lease.target) then
            S.wyrm_down_release.at = lease.until_t + 0.15
        end
        lease.catch_established_at = paired and now or nil
        lease.approach_secs = 0.0
        lease.approach_done = true
        S.wyrm_atk_until = lease.until_t
        rawset(_G, "IrisWyrmNativeAttackLease", {
            mount_addr = object_address(lease.costume.horse_character),
            target_addr = object_address(lease.target),
            until_t = lease.until_t,
        })
        S.wyrm_native_status = paired
            and "contextual maul attached to downed target"
            or "contextual hold-down maul started"
        log(S.wyrm_native_status)
        iris_wyrm_combat_trace(lease, "maul-start", S.wyrm_native_status)
        return true
    end
    -- ⛔ r7 POST-MORTEM: the live-window catch paired successfully (victim
    -- entered Caught_TakeAwayWolf_StartLoop_D) but the wolf-side action stayed
    -- Invalid through the whole window and the engine fought the pairing ~300
    -- times in 6s. The catch machinery below remains only for the non-direct
    -- combo path; RT now uses the pinned maul above.
    local full_native = lease.costume
        and lease.costume.native_controller_live == true
    if direct and not full_native then return arm_stationary_maul(false) end
    local setting = iris_wyrm_native_catch_setting()
    local catch_controller = nil
    pcall(function()
        catch_controller = lease.costume.horse_character:call("get_CatchController")
    end)
    local _, caught_controller = iris_wyrm_native_caught_active(lease.target)
    if not (setting and catch_controller and caught_controller) then
        if direct then return arm_stationary_maul(false) end
        S.wyrm_native_status = "native maul refused: captured catch machinery unavailable"
        log(S.wyrm_native_status)
        return false
    end

    -- Do not stack transactions. A stale active pair is evidence of a previous
    -- interrupted catch and must be dismantled before this target is enrolled.
    if iris_wyrm_native_catch_active(catch_controller) then
        pcall(function() catch_controller:call("abort(System.Boolean)", true) end)
    end
    local prey_was_active = iris_wyrm_native_caught_active(lease.target)
    if prey_was_active then
        pcall(function() caught_controller:call("abortDirect") end)
    end
    pcall(function()
        lease.target:call("set_IsThinkStop", false)
        local motion = lease.target:call("get_Motion")
        if motion then motion:call("set_PlaySpeed", 1.0) end
    end)
    lease.catch_move = true -- arm the startCatch receipt before the synchronous call
    lease.retain_catch = true -- terminal callbacks can occur inside startCatch
    lease.catch_controller = catch_controller
    lease.caught_controller = caught_controller
    lease.catch_setting = setting
    local called, call_error = pcall(function()
        catch_controller:call(
            "startCatch(app.Character, app.CatchController.Setting, app.CatchInterpolator)",
            lease.target, setting, nil)
    end)
    local catcher_active = iris_wyrm_native_catch_active(catch_controller)
    local caught_active = iris_wyrm_native_caught_active(lease.target)
    if not (called and catcher_active and caught_active) then
        iris_wyrm_native_abort_catch(lease)
        lease.catch_move = false
        lease.retain_catch = false
        lease.catch_controller = nil
        lease.caught_controller = nil
        if direct then return arm_stationary_maul(false) end
        S.wyrm_native_status = "native maul startCatch refused"
            .. (call_error and (": " .. tostring(call_error)) or "")
        log(S.wyrm_native_status)
        return false
    end

    -- Preserve an accepted pair against the ordinary default-abort path while
    -- the ridden ch223 has its decision maker parked. Escape remains governed by
    -- the captured setting; these flags do not invent a new attachment.
    pcall(function()
        catch_controller:call("set_IsRejectAbortOnDefault(System.Boolean)", true)
        catch_controller:call("set_IsContinue(System.Boolean)", true)
        caught_controller:call("set_IsRejectAbortOnDefault(System.Boolean)", true)
        caught_controller:call("set_IsContinue(System.Boolean)", true)
    end)
    lease.catch_start_seen = math.max(1,
        tonumber(lease.catch_start_seen) or 0)
    lease.phase = "catch"
    lease.label = "take-away maul"
    lease.native_catch_unavailable = nil
    lease.release_node = nil
    lease.cancel_node = "HoldDownCatchCancel"
    lease.release_requested = nil
    if direct and full_native then
        -- Retired-controller branch only; RT never reaches this since r8.
        lease.direct_maul = true
        lease.phase = "catch"
        lease.label = "native paired hold-down maul"
        lease.visual_stages = nil
        lease.t0 = now
        lease.until_t = now + 6.0
        lease.catch_established_at = now
        lease.approach_secs = 0.0
        lease.approach_done = true
        lease.release_node = "HoldDownCatchFinish"
        lease.release_at = 5.25
        S.wyrm_atk_until = lease.until_t
        pcall(function()
            lease.action_manager:call(
                "requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)",
                0, "HoldDownCatchAttack", 0)
        end)
        S.wyrm_native_status = "native paired maul attached; ch223 owns damage"
        log(S.wyrm_native_status)
        iris_wyrm_combat_trace(lease, "maul-start", S.wyrm_native_status)
        return true
    elseif direct then
        return arm_stationary_maul(true)
    end
    -- The paired controllers own attachment/reaction, but the ridden wolf's
    -- native ActionManager remains Invalid. Advance the actual ch223 atlas
    -- motions explicitly without ever waking AIDecisionMaker/navigation.
    lease.visual_stages = {
        { at = 0.00, bank = 30, clip = 515, blend = 8.0 }, -- lift downed prey
        { at = 0.72, bank = 30, clip = 500, blend = 6.0 }, -- carry/settle
        { at = 2.10, bank = 20, clip = 4010, blend = 8.0 }, -- push-down start
        { at = 2.68, bank = 20, clip = 4012, blend = 4.0 },
        { at = 3.28, bank = 20, clip = 4000, blend = 4.0,
            maul_contact = true, native_request_id = 101 }, -- maul opener
        { at = 4.08, bank = 20, clip = 4041, blend = 4.0 },
        { at = 4.48, bank = 20, clip = 4043, blend = 4.0,
            maul_contact = true, native_request_id = 103 },
        { at = 5.08, bank = 20, clip = 4041, blend = 4.0 },
        { at = 5.48, bank = 20, clip = 4043, blend = 4.0,
            maul_contact = true, native_request_id = 103 },
        { at = 6.08, bank = 20, clip = 4041, blend = 4.0 },
        { at = 6.48, bank = 20, clip = 4043, blend = 4.0,
            maul_contact = true, native_request_id = 103 },
        { at = 8.05, bank = 20, clip = 4020, blend = 8.0 }, -- release pose
    }
    lease.t0 = now
    lease.until_t = now + 9.0
    lease.catch_established_at = now
    lease.approach_secs = 0.0
    lease.approach_done = true
    S.wyrm_atk_until = lease.until_t
    rawset(_G, "IrisWyrmNativeAttackLease", {
        mount_addr = object_address(lease.costume.horse_character),
        target_addr = object_address(lease.target),
        until_t = lease.until_t,
    })
    S.wyrm_native_status = direct
        and "native take-away maul established on downed target"
        or "native take-away maul established after opener knockdown"
    log(S.wyrm_native_status)
    return true
end

function iris_wyrm_native_bite_finish(reason)
    local lease = S.wyrm_native_lease
    if not lease then return end
    if lease.cam_yaw then
        S.mountcam_kick_release = {
            yaw = lease.cam_yaw,
            look = lease.cam_look,
            t0 = os.clock(),
            dur = tonumber(C.kick_camera_blend_s) or 0.65,
        }
    end
    iris_wyrm_combat_trace_flush(lease, reason)
    S.wyrm_native_lease = nil
    rawset(_G, "IrisWyrmNativeAttackLease", nil)
    if S.wyrm_attack == lease then S.wyrm_attack = nil end
    S.wyrm_atk_until = nil
    S.wyrm_atk_hold = nil
    -- r8: UNPIN on every exit path -- a think-stopped goblin outliving its
    -- maul would be a frozen statue. PlaySpeed restored with it.
    -- r10: an early exit that still owes the deferred death pays it here
    -- (pin_kill unpins on its own).
    if lease.pin_kill_pending and not lease.pin_kill_done then
        lease.pin_kill_done = true
        iris_wyrm_pin_kill(lease)
    elseif lease.pin_maul then
        pcall(function()
            if valid(lease.target) then
                lease.target:call("set_IsThinkStop", false)
                local motion = lease.target:call("get_Motion")
                if motion then motion:call("set_PlaySpeed", 1.0) end
            end
        end)
    end
    local costume = lease.costume
    if lease.native_jaw_tracks then
        pcall(function() lease.native_jaw_tracks:release() end)
        lease.native_jaw_tracks = nil
    end
    if costume then
        if lease.native_hit_controller and lease.old_attack_rate ~= nil then
            pcall(function()
                lease.native_hit_controller:call("set_AttackRate(System.Single)",
                    lease.old_attack_rate)
            end)
        end
        costume.force_hold = nil
        costume.last_gait = nil
        costume.cur_speed = 0.0
        costume.idle_anchor = nil
        costume.drive_step = nil
        costume.wyrm_prev_upos = nil
        costume.ownership_at = 0.0
        local can_recover = S.ride_pose_on == true and S.costume == costume
            and reason ~= "mount released" and reason ~= "ride ended"
        if can_recover then
            -- Do this before releasing force_hold so 50:423 cannot leave the
            -- parked ch223 layer stuck in com_fall_loop_vertical.
            iris_wyrm_native_grounded_motion_guard(lease, true)
        end
        pcall(function()
            -- Early dismount, timeout or kill-switch during a paired catch:
            -- release both native controllers. Directly requesting the captured
            -- cancel action is insufficient because that only changes Shadow's
            -- graph and can leave the victim attached to C_PropA.
            if lease.catch_move and lease.catch_controller then
                -- A requested finish node is not proof that both controller
                -- halves actually retired.  Explicitly close any surviving pair
                -- before locomotion resumes; this prevents the old abort storm
                -- and a victim remaining invisibly attached after RT.
                local catcher_live = iris_wyrm_native_catch_active(
                    lease.catch_controller)
                local caught_live = iris_wyrm_native_caught_active(lease.target)
                if catcher_live or caught_live then
                    iris_wyrm_native_abort_catch(lease)
                end
            end
            local ai = costume.native_ai
            if ai then ai:call("set_Enabled", false) end
            local nav = costume.native_nav
            if nav then nav:call("set_Enabled", false) end
            local fsm = costume.native_fsm
            if can_recover and costume.native_controller_live then
                -- The Puppeteer controller never parks the graph between moves.
                -- Return through MonsterActionSelector so the authored action
                -- reaches a genuine locomotion/idle node, then let the next
                -- drive tick select the requested pace.
                if fsm then fsm:call("set_Enabled", true) end
                costume.horse_character:call("set_IsThinkStop", false)
                if costume.native_selector then
                    costume.native_selector:call("requestNormalIdleImpl")
                elseif lease.action_manager then
                    lease.action_manager:call(
                        "requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)",
                        0, "NormalLocomotion", 0)
                end
                costume.native_move_mode = nil
                S.wyrm_native_recover_until = nil
                costume.ownership_at = 0.0
            elseif can_recover then
                -- The shipping controller never woke the graph, so there is no
                -- native attack node to recover from.  Keep it parked; waking it
                -- for a 0.22s neutral request was enough to leak ch223's falling
                -- state into later grounded bite-combo presses.
                if fsm then fsm:call("set_Enabled", false) end
                if costume.horse_character then
                    costume.horse_character:call("set_IsThinkStop", true)
                end
                S.wyrm_native_recover_until = nil
                costume.ownership_at = 0.0
            else
                S.wyrm_native_recover_until = nil
                if fsm then fsm:call("set_Enabled", false) end
                if costume.horse_character then
                    costume.horse_character:call("set_IsThinkStop", true)
                end
            end
        end)
    end
    local hp1 = iris_wyrm_native_target_hp(lease.target)
    local result = "native " .. tostring(lease.label or "bite") .. " "
        .. tostring(reason or "finished")
    if lease.hp0 and hp1 then
        result = result .. string.format(" | target HP %.0f -> %.0f (delta %.0f)",
            lease.hp0, hp1, hp1 - lease.hp0)
    elseif lease.target then
        result = result .. " | target HP unavailable"
    else
        result = result .. " | no target in the forward bite volume"
    end
    if lease.observed_node then
        result = result .. " | node=" .. tostring(lease.observed_node)
    end
    if lease.catch_move then
        result = result .. " | target start=" .. tostring(lease.target_down_detail or "unknown")
            .. " | startCatch=" .. tostring(tonumber(lease.catch_start_seen) or 0)
            .. " | paired=" .. tostring(lease.catch_established_at ~= nil)
            .. " | retainedEnds=" .. tostring(tonumber(lease.retained_ends) or 0)
            .. " | maulContacts=" .. tostring(tonumber(lease.maul_contacts) or 0)
            .. " | lastEnd=" .. tostring(lease.last_retained_end or "none")
    end
    if lease.combo_maul then
        result = result .. " | phase=" .. tostring(lease.phase or "opener")
            .. " | openerHit=" .. tostring(lease.opener_hit == true)
            .. " | nativeDown=" .. tostring(lease.target_down_detail or "unknown")
    end
    if lease.native_catch_unavailable then
        result = result .. " | nativeCatch=withheld(non-requestable branch)"
    end
    if lease.acquire_reason then
        result = result .. " | acquire=" .. tostring(lease.acquire_reason)
    end
    if lease.receiver_contact then
        result = result .. " | receiverContact=native-pipeline"
    elseif lease.native_contact then
        result = result .. " | receiverContact=ch223-collider"
    end
    if lease.contact_retry then
        result = result .. " | nativeColliderRetry=true"
    end
    if (tonumber(lease.approach_moved) or 0.0) > 0.001
        or lease.approach_blocked then
        result = result .. string.format(" | contact step=%.2fm%s",
            tonumber(lease.approach_moved) or 0.0,
            lease.approach_blocked and " (blocked)" or "")
    end
    S.wyrm_native_status = result
    log(result)
end

-- Fire only after the contact assist has put the authored mouth collider on the
-- selected victim.  Previously Ch223_Bite started on the button frame while the
-- mount was still turning/advancing for another 0.58s; its real hit window was
-- normally over before Shadow arrived, and requesting the already-active node
-- at 0.52s was not a reliable restart.
function iris_wyrm_native_fire_bite(lease, now, acquire_reason)
    if not (lease and lease.action_manager and lease.costume
        and valid(lease.costume.horse_character)) then return false end
    lease.phase = lease.combo_maul and "opener" or "attack"
    lease.t0 = now
    lease.until_t = now + (tonumber(lease.attack_duration) or 1.45)
    -- Initial placement is complete, but the victim and the animated mouth both
    -- move during wind-up. Keep a small FORWARD-ONLY, scenery-checked correction
    -- alive until impact. The former signed correction crossed the victim and
    -- immediately stepped backwards, producing the visible mini-teleport.
    lease.approach_done = (tonumber(lease.approach_max) or 0.0) <= 0.0
    lease.approach_secs = lease.approach_done and 0.0
        or ((tonumber(lease.impact_at) or 0.62) + 0.08)
    lease.approach_moved = 0.0
    lease.approach_stop = math.max(0.16,
        math.min(0.32, tonumber(lease.approach_stop) or 0.20))
    -- Acquisition can close distance decisively; once the animation has begun,
    -- cap follow-through so target knockback produces a smooth chase rather than
    -- a 0.3m single-frame lurch.
    lease.approach_speed = math.min(7.5,
        tonumber(lease.approach_speed) or 7.5)
    lease.native_jaw_requested = lease.native_request_auto == true or nil
    lease.observed_node = nil
    lease.contact_retry = nil
    lease.acquire_reason = acquire_reason
    S.wyrm_atk_until = lease.until_t
    rawset(_G, "IrisWyrmNativeAttackLease", {
        mount_addr = object_address(lease.costume.horse_character),
        target_addr = object_address(lease.target),
        until_t = lease.until_t,
    })
    lease.collider_rearmed, lease.histories_cleared =
        iris_wyrm_native_rearm_attack(lease.costume, lease.label)
    iris_wyrm_combat_trace(lease, "collider-armed",
        tostring(acquire_reason or "untargeted")
            .. " | rearm=" .. tostring(lease.collider_rearmed)
            .. " cleared=" .. tostring(lease.histories_cleared))
    local requested = not lease.full_native_controller
    if lease.full_native_controller then
        pcall(function()
            lease.action_manager:call(
                "requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)",
                0, lease.node, 0)
            requested = true
        end)
    end
    if requested then
        -- A contextual RT maul uses this same acquisition corridor.  Only arm
        -- the hold-down sequence after Shadow's mouth has actually been placed
        -- on the prone target; starting it on the button frame was the reason
        -- the animation played while the goblin simply stood back up.
        if lease.direct_maul then
            if not iris_wyrm_native_begin_maul(lease, now, true) then
                iris_wyrm_native_bite_finish("contextual maul start failed")
                return false
            end
            return true
        end
        S.wyrm_native_status = "native " .. tostring(lease.label)
            .. " fired after contact acquire"
            .. (acquire_reason and (" | " .. tostring(acquire_reason)) or "")
        log(S.wyrm_native_status)
        return true
    end
    iris_wyrm_native_bite_finish("fire request FAILED")
    return false
end

function iris_wyrm_native_bite_start(costume, now, spec)
    if not (costume and costume.wyrm_kind
        and costume.wyrm_chassis == "ch223"
        and valid(costume.horse_go) and valid(costume.horse_character)) then
        return false
    end
    if S.wyrm_native_recover_until
        and now < S.wyrm_native_recover_until then
        -- Button edges must not be lost during the neutral settle. Queue exactly
        -- one latest request; it will start once NormalLocomotion has had a frame.
        S.wyrm_native_pending = {
            costume = costume,
            spec = spec,
            at = S.wyrm_native_recover_until + 0.02,
        }
        S.wyrm_native_status = "native attack queued while Shadow returns to neutral"
        return true
    end
    spec = spec or {
        label = "bite", slot = "light", node = "Ch223_Bite",
        duration = 1.16, range = 8.5, width = 6.5, vertical = 12.0,
        -- ⭐ 08-18 r5 (trace runs 10-17: EIGHT straight X presses withheld at
        -- combat start, victim 1.7-3.8m BEHIND the mouth -- the rider charges
        -- in and the jaw overshoots). The combo links already turn 180°; the
        -- OPENER was still capped at 105° and could never come back around.
        aim_deg = 180.0, aim_secs = 0.14, hard_aim = true,
        combo_kind = "bite", combo_index = 1,
        combo_transition_at = 1.02, combo_end_at = 1.15,
        impact_at = 0.62,
        -- Put the mouth, not Shadow's oversized body/root, into strike range.
        -- clear_travel performs a scenery cast for every short step, so this is
        -- bounded contact assistance rather than the old through-wall lunge.
        approach_stop = 0.55, approach_max = 4.0,
        approach_secs = 0.44, approach_speed = 16.0,
        forced_damage = 94.0,
        -- 08-18 round 2: trust clip 50:50's OWN authored window first (run 25
        -- missed at a perfect 0.36m WITH the explicit post -- the post can
        -- restart the clip-owned window). Fallback 50 only if nothing landed.
        request_auto = true, request_fallback = 50,
        visual_stages = { { at = 0.08, bank = 50, clip = 50 } },
    }
    -- Puppeteer reads Character.<ActionManager> rather than doing a component
    -- lookup.  They are not interchangeable on ch223: the latter is the route
    -- that kept reporting the `Invalid` placeholder while the clip still moved.
    local action_manager = costume.native_action_manager
    if not action_manager then
        pcall(function()
            action_manager = costume.horse_character["<ActionManager>k__BackingField"]
                or costume.horse_character:call("get_ActionManager")
        end)
    end
    action_manager = action_manager
        or get_component(costume.horse_go, "app.ActionManager")
    if not action_manager then
        S.wyrm_native_status = "native bite refused: no ActionManager"
        log(S.wyrm_native_status)
        return false
    end
    local probe = {
        slot = spec.slot or "light",
        range = tonumber(spec.range) or 5.5,
        width = tonumber(spec.width) or 2.8,
        aim_deg = tonumber(spec.aim_deg) or 65.0,
        vertical = tonumber(spec.vertical) or 7.5,
    }
    local target, target_go = iris_wyrm_attack_target(costume, probe)
    local target_down, target_down_detail =
        iris_wyrm_native_target_down_state(target)
    if spec.requires_downed == true and not target then
        S.wyrm_native_status = "contextual maul held: no downed target in front"
        return true
    end
    if spec.requires_downed == true and target and target_down ~= true then
        S.wyrm_native_status = "native maul held: target is not down/catchable | "
            .. tostring(target_down_detail)
        log(S.wyrm_native_status)
        return true
    end
    local lease = {
        native = true,
        costume = costume,
        target = target,
        target_go = target_go,
        hp0 = iris_wyrm_native_target_hp(target),
        action_manager = action_manager,
        t0 = now,
        until_t = now + (tonumber(spec.duration) or 1.45),
        attack_duration = tonumber(spec.duration) or 1.45,
        forced_damage = tonumber(spec.forced_damage) or 94.0,
        slot = spec.slot or "light",
        trace_button = (spec.slot == "heavy" and "Y")
            or (spec.slot == "voice" and "LT")
            or (spec.slot == "maul" and "RT") or "X",
        node = spec.node or "Ch223_Bite",
        label = spec.label or "bite",
        visual_stages = spec.visual_stages,
        aim_deg = tonumber(spec.aim_deg) or 65.0,
        aim_secs = tonumber(spec.aim_secs) or 0.12,
        hard_aim = spec.hard_aim == true,
        release_node = spec.release_node,
        release_at = spec.release_at,
        cancel_node = spec.cancel_node,
        catch_move = spec.catch_move == true,
        combo_maul = spec.combo_maul == true,
        combo_kind = spec.combo_kind,
        combo_index = tonumber(spec.combo_index),
        combo_transition_at = tonumber(spec.combo_transition_at),
        combo_end_at = tonumber(spec.combo_end_at),
        impact_at = tonumber(spec.impact_at),
        force_contact = spec.force_contact == true,
        damage_kind = spec.damage_kind,
        direct_maul = spec.direct_maul == true,
        howl_blast = spec.howl_blast == true,
        howl_blast_at = tonumber(spec.howl_blast_at) or 0.72,
        howl_sound_at = tonumber(spec.howl_sound_at),
        pounce_motion = spec.pounce_motion == true,
        pounce_travel = tonumber(spec.pounce_travel) or 3.4,
        pounce_height = tonumber(spec.pounce_height) or 1.35,
        pounce_airtime = tonumber(spec.pounce_airtime) or 0.78,
        pounce_launch_delay = tonumber(spec.pounce_launch_delay) or 0.0,
        phase = spec.combo_maul == true and "opener" or nil,
        target_down = target_down,
        target_down_detail = target_down_detail,
        -- Horizontal gap from live mouth joint to victim root, not body-centre
        -- distance. A goblin at ~0.55m is directly in the jaw collider.
        approach_stop = tonumber(spec.approach_stop) or 0.12,
        approach_max = tonumber(spec.approach_max) or 4.5,
        approach_secs = tonumber(spec.approach_secs) or 0.58,
        approach_speed = tonumber(spec.approach_speed) or 18.0,
        approach_moved = 0.0,
        native_request_auto = spec.request_auto == true,
        native_request_fallback = tonumber(spec.request_fallback),
    }
    -- Auto windows: mark the one-shot as already handled so attack_tick never
    -- posts on top of the clip's own authored request (the stomp law). The
    -- fallback block still fires if no HP transaction shows by impact+0.12.
    if lease.native_request_auto then lease.native_jaw_requested = true end
    -- 08-18: AttackRate scaling RETIRED -- 8x produced no measurable change in
    -- the field, consistent with the r96-r98 law that HP is applied from a
    -- separate updateDamageHp argument. Damage amplification now happens in
    -- iris_wyrm_native_damage_amp_dispatch at the exact point of application.
    -- The HitController is still cached: the collider-scale hook and the jaw
    -- request path key off lease.native_hit_controller.
    if lease.slot ~= "voice" then
        lease.native_hit_controller =
            get_component(costume.horse_go, "app.HitController")
    end
    if costume.native_controller_live then
        -- With a valid, continuously awake graph the requested action owns its
        -- animation, collider and root motion.  Painting atlas frames or adding
        -- our parabola here would recreate the exact hybrid fight this route is
        -- meant to remove (and is why Y sailed over small targets).
        lease.visual_stages = nil
        lease.full_native_controller = true
    end
    -- Attacks with a selected victim begin in a neutral acquire phase.  Howls
    -- and untargeted bites still fire immediately because there is no geometry
    -- to solve first.
    lease.acquire_contact = (lease.node == "Ch223_Bite" or lease.direct_maul)
        and valid(target)
    if lease.acquire_contact then
        lease.phase = "acquire"
        lease.acquire_t0 = now
        -- Cover acquire time plus the subsequent real action duration.
        lease.until_t = now + lease.approach_secs + lease.attack_duration
    end
    -- Even when the target is already prone, enter through the proven native
    -- bite collider. HoldDownCatchAttack is not a public/requestable leaf.
    if valid(target_go) then
        lease.aim_go = target_go
        -- Preserve the rider's pre-auto-aim world heading, exactly like the
        -- horse kick camera. The look point follows the victim; the boom does
        -- not whip around when Shadow snaps towards it.
        pcall(function()
            local base = valid(costume.ox_go) and costume.ox_go
                or costume.horse_go
            local axis = base:call("get_Transform"):call("get_AxisZ")
            lease.cam_yaw = math.atan(axis.x, axis.z)
                + (tonumber(S.mountcam_orbit_yaw) or 0.0)
        end)
    end
    S.wyrm_native_lease = lease
    iris_wyrm_combat_trace(lease, "button",
        valid(target_go) and "target selected" or "no target selected")
    iris_wyrm_native_prepare_aim(costume, target, lease,
        lease.aim_deg, lease.aim_secs)
    rawset(_G, "IrisWyrmNativeAttackLease", {
        mount_addr = object_address(costume.horse_character),
        target_addr = object_address(target),
        until_t = lease.until_t,
    })
    S.wyrm_attack = lease
    S.wyrm_atk_until = lease.until_t
    S.wyrm_atk_hold = true
    costume.force_hold = true
    costume.cur_speed = 0.0
    costume.idle_anchor = nil
    costume.drive_step = { x = 0.0, z = 0.0 }
    local native_p0 = universal_pos(costume.horse_go)
    costume.wyrm_prev_upos = native_p0
        and { x = native_p0.x, z = native_p0.z } or nil
    if lease.pounce_motion and native_p0 then
        lease.pounce_y0 = tonumber(native_p0.y) or 0.0
        lease.pounce_moved = 0.0
        if valid(target_go) then
            local tp = universal_pos(target_go)
            local mouth = iris_wyrm_native_mouth_positions(costume)
            if tp and mouth then
                -- Root distance overstates the needed leap on a scaled ch223;
                -- its head is metres ahead of the root. Stop the JAW just shy
                -- of the victim rather than driving the torso over them.
                local dx, dz = tp.x - mouth.x, tp.z - mouth.z
                local dist = math.sqrt(dx * dx + dz * dz)
                -- r13 ENGAGE POUNCE (Aurora: "the main benefit of pounce is
                -- the range, which it doesn't really have"): the old
                -- min(2.8, dist - 1.35) hop landed metres short of anything
                -- past spitting distance. Fuel the leap to REACH the victim
                -- plus a carry-through; airtime stays fixed, so a longer
                -- leap is a faster leap. The homing stops the drive once the
                -- mouth has carried just past the body, and the RT converge
                -- lines the maul up from wherever the prey ends up.
                lease.pounce_travel = math.max(2.2,
                    math.min(8.5, dist + 1.4))
                lease.pounce_height = math.max(0.48,
                    math.min(1.0, 0.42 + lease.pounce_travel * 0.06))
            end
        end
    end
    costume.ownership_at = 0.0
    local requested = false
    pcall(function()
        -- Autonomous components stay parked for the shipping controller.  Atlas
        -- motion plus one receiver transaction is intentional: waking ch223's
        -- incomplete mounted graph caused self-driving, fall-state leakage and
        -- the persistent combat slowdown.  The retired native-controller branch
        -- remains fenced here only so stale session state cannot form a hybrid.
        local ai = costume.native_ai
        if ai then ai:call("set_Enabled", false) end
        local nav = costume.native_nav
        if nav then nav:call("set_Enabled", false) end
        local fsm = costume.native_fsm
        if lease.full_native_controller then
            if fsm then fsm:call("set_Enabled", true) end
            costume.horse_character:call("set_IsThinkStop", false)
            action_manager:call(
                "requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)",
                0, lease.acquire_contact and "NormalLocomotion" or lease.node, 0)
            requested = true
        else
            if fsm then fsm:call("set_Enabled", false) end
            costume.horse_character:call("set_IsThinkStop", true)
            requested = true
        end
    end)
    if not requested then
        iris_wyrm_native_bite_finish("request FAILED")
        return true -- consume X; never fall through to disguised synthetic damage
    end
    if lease.direct_maul and not lease.acquire_contact then
        if not iris_wyrm_native_begin_maul(lease, now, true) then
            iris_wyrm_native_bite_finish("contextual maul start failed")
        end
        return true
    end
    S.wyrm_native_status = lease.acquire_contact
        and ("native " .. tostring(lease.label)
            .. " acquiring target before collider")
        or ("native " .. tostring(lease.label)
            .. " requested: " .. tostring(lease.node) .. " (waiting for node)")
    log(S.wyrm_native_status)
    return true
end

-- Barghest-style combat language, adapted for a mounted ch223.  Puppeteer can
-- trust a possessed monster's complete action graph; our ridden chassis cannot,
-- so buttons are buffered here and later combo stages use the exact native atlas
-- motions with one receiver transaction at their authored impact frame.
function iris_wyrm_read_controls()
    if not S.wyrm_pad or not S.wyrm_pad.rt then
        local names = {}
        pcall(function()
            local t = sdk.find_type_definition("via.hid.GamePadButton")
            for _, f in ipairs(t:get_fields()) do
                pcall(function() names[f:get_name()] = f:get_data() end)
            end
        end)
        local function pick(fallback, ...)
            for _, n in ipairs({ ... }) do
                if names[n] and names[n] ~= 0 then return names[n] end
            end
            return fallback
        end
        S.wyrm_pad = {
            x = pick(0x40, "Action", "RLeft", "Square"),
            y = pick(0x10, "Special", "RUp", "Triangle"),
            lb = pick(0x100, "LTrigTop", "L1"),
            lt = pick(0x200, "LTrigBottom", "L2"),
            rb = pick(0x400, "RTrigTop", "R1"),
            rt = pick(0x800, "RTrigBottom", "R2"),
        }
    end
    local btn = 0
    pcall(function()
        local gp = sdk.get_native_singleton("via.hid.GamePad")
        local td = sdk.find_type_definition("via.hid.GamePad")
        local dev = sdk.call_native_func(gp, td, "get_MergedDevice")
        btn = dev and math.floor(dev:call("get_Button") or 0) or 0
    end)
    local key = {}
    pcall(function()
        key.light = reframework:is_key_down(0x54) == true -- T
        key.heavy = reframework:is_key_down(0x47) == true -- G
        key.voice = reframework:is_key_down(0x48) == true -- H
        key.dodge_left = reframework:is_key_down(0x5A) == true -- Z
        key.dodge_right = reframework:is_key_down(0x43) == true -- C
        key.maul = reframework:is_key_down(0x52) == true -- R
    end)
    local p = S.wyrm_pad
    local down = {
        light = key.light or (btn & p.x) ~= 0,
        heavy = key.heavy or (btn & p.y) ~= 0,
        voice = key.voice or (btn & p.lt) ~= 0,
        dodge_left = key.dodge_left or (btn & p.lb) ~= 0,
        dodge_right = key.dodge_right or (btn & p.rb) ~= 0,
        maul = key.maul or (btn & p.rt) ~= 0,
    }
    local prev = S.wyrm_btn_prev or {}
    local pressed = {}
    for name, value in pairs(down) do
        pressed[name] = value and not prev[name]
    end
    S.wyrm_btn_prev = down
    return down, pressed
end

function iris_wyrm_native_combo_advance(lease, now)
    if not (lease and lease.combo_kind == "bite" and lease.costume) then
        return false
    end
    local index = (tonumber(lease.combo_index) or 1) + 1
    local stage = ({
        -- ⭐ 08-18 ROUND 2 FIELD LAW (14 attempts over two sessions): clip
        -- 50:422 landed ZERO hits by every route -- explicit 54, auto, and the
        -- 50 fallback -- while 50:423 as link 3 (pure changeMotion, no post)
        -- hit every single time. Conclusion: motion-driven clips fire their
        -- OWN attack events even under think-stop, and 422 simply owns none.
        -- Link 2 is now 50:413 -- the left-side mirror of the proven 423 --
        -- so the chain reads bite -> L jump-bite -> R jump-bite. Both links
        -- trust their authored windows; the proven 50 posts once only if no
        -- HP transaction showed by impact+0.12.
        [2] = { clip = 413, duration = 0.62, transition = 0.55,
            impact = 0.30, request_auto = true,
            request_fallback = 50, label = "bite combo 2" },
        -- 50:423 emits request 54 itself. It falls through to 0:415 at roughly
        -- 0.65s on the parked graph, so retire the link after its real hit window.
        [3] = { clip = 423, duration = 0.58, transition = 0.55,
            impact = 0.30, request_auto = true,
            request_fallback = 50, label = "bite combo 3" },
    })[index]
    if not stage then return false end
    local target, target_go = lease.target, lease.target_go
    local target_hp = iris_wyrm_native_target_hp(target)
    if not (valid(target) and valid(target_go)
        and tonumber(target_hp) and tonumber(target_hp) > 0.0) then
        target, target_go = iris_wyrm_attack_target(lease.costume, {
            slot = "light", range = 8.5, width = 6.5, aim_deg = 105.0,
            vertical = 12.0,
        })
    end
    lease.combo_index = index
    lease.combo_buffered = nil
    lease.combo_buffer_until = nil
    lease.label = stage.label
    -- Each authored follow-through owns a different genuine ch223 request
    -- (422 -> 53, 423 -> 54).  Rearming the HitController below makes the same
    -- victim eligible again without substituting a fake damage pulse.
    lease.node = "Ch223_Bite"
    lease.target, lease.target_go = target, target_go
    lease.hp0 = iris_wyrm_native_target_hp(target)
    lease.t0 = now
    lease.acquire_t0 = now
    lease.until_t = now + 0.26 + stage.duration
    lease.attack_duration = stage.duration
    lease.combo_transition_at = stage.transition
    lease.combo_end_at = stage.duration
    lease.impact_at = stage.impact
    lease.native_request_id = stage.request_id
    lease.native_request_auto = stage.request_auto == true
    lease.native_request_fallback = stage.request_fallback
    lease.native_jaw_fallback_done = nil
    lease.force_contact = true
    lease.forced_damage = 94.0
    -- Reacquire before every combo link.  Blind animation lunges overshot short
    -- enemies and made the camera show a hit which occurred behind the jaw.
    local has_target = valid(target) and valid(target_go)
    lease.phase = has_target and "acquire" or "attack"
    lease.acquire_contact = has_target
    lease.approach_done = not has_target
    lease.approach_moved = 0.0
    lease.approach_stop = 0.55
    lease.approach_max = 4.0
    lease.approach_secs = 0.44
    lease.approach_speed = 16.0
    lease.lunge_total, lease.lunge_until, lease.lunge_done = nil, nil, nil
    lease.contact_resolved = nil
    lease.native_jaw_requested = lease.native_request_auto == true or nil
    lease.receiver_contact, lease.native_contact = nil, nil
    lease.observed_node = nil
    lease.visual_stages = {
        { at = 0.0, bank = 50, clip = stage.clip, blend = 15.0, speed = 1.1 },
    }
    -- Rearming happens after acquire, immediately before the hit clip starts.
    lease.collider_rearmed, lease.histories_cleared = nil, nil
    lease.aim_go = target_go
    lease.aim_from, lease.aim_delta = nil, nil
    lease.hard_aim = true
    lease.aim_deg = 180.0
    -- Bite 1 can knock the same victim behind the scaled body. Continue turning
    -- towards that valid combo target instead of aborting at the old 105° gate.
    iris_wyrm_native_prepare_aim(lease.costume, target, lease, 180.0, 0.04)
    S.wyrm_atk_until = lease.until_t
    rawset(_G, "IrisWyrmNativeAttackLease", {
        mount_addr = object_address(lease.costume.horse_character),
        target_addr = object_address(target),
        until_t = lease.until_t,
    })
    S.wyrm_native_status = stage.label .. " buffered"
    iris_wyrm_combat_trace(lease, "combo-link",
        "reacquired target; visual=" .. tostring(50) .. ":" .. tostring(stage.clip))
    return true
end

function iris_wyrm_dodge_start(costume, now, side)
    if not (costume and costume.wyrm_chassis == "ch223") then return false end
    local left = side < 0
    costume.force_hold = true
    costume.cur_speed = 0.0
    costume.last_gait = nil
    S.wyrm_atk_hold = true
    -- 08-18: the lateral travel used to start on the button frame while clip
    -- 462/463 was still blending through its crouch -- a visible skate before
    -- the hop. The travel window now opens only once the leap frame arrives.
    local dodge_delay = math.max(0.0,
        math.min(0.5, tonumber(C.wyrm_dodge_delay) or 0.16))
    local dodge_secs = math.max(0.1,
        math.min(0.9, tonumber(C.wyrm_dodge_secs) or 0.42))
    S.wyrm_atk_until = now + math.max(0.72, dodge_delay + dodge_secs + 0.15)
    S.wyrm_attack = {
        t0 = now, slot = left and "dodge_left" or "dodge_right",
        hit = true, dodge_side = left and -1 or 1,
        dodge_move_delay = dodge_delay,
        dodge_move_until = dodge_delay + dodge_secs,
        dodge_speed = math.max(1.0,
            math.min(12.0, tonumber(C.wyrm_dodge_speed) or 4.8)),
    }
    local pos = universal_pos(costume.horse_go)
    costume.wyrm_prev_upos = pos and { x = pos.x, z = pos.z } or nil
    costume.drive_step = { x = 0.0, z = 0.0 }
    if costume.native_controller_live and costume.native_action_manager then
        pcall(function()
            costume.native_action_manager:call(
                "requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)",
                0, left and "AvoidLeft" or "AvoidRight", 0)
        end)
        costume.native_move_mode = nil
        return true
    end
    pcall(function()
        local layer = costume.horse_character:call("get_Motion"):call("getLayer", 0)
        if layer then
            layer:call(
                "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                0, left and 462 or 463, 0.0, 8.0, 1, 1)
        end
    end)
    S.need_rootmotion_kill = true
    return true
end

-- Atlas-driven combo sequences rather than a single frozen pose:
-- ch260: bite / lion jump-slam / howl; ch223 (Shadow and converted pumas):
-- bite / full jump-bite chain / howl. Contact timing follows the impact pose.
function iris_wyrm_attack_tick()
    local costume = S.costume
    if not (costume and costume.wyrm_kind and S.ride_pose_on) then
        if S.wyrm_native_lease then iris_wyrm_native_bite_finish("ride ended") end
        if S.wyrm_down_release then
            pcall(function()
                S.wyrm_down_release.action_manager:call(
                    "requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)",
                    0, "Locomotion", 0)
            end)
            S.wyrm_down_release = nil
        end
        if costume and costume.wyrm_impact_pause_until then
            costume.wyrm_impact_pause_until = nil
            pcall(function()
                costume.horse_character:call("get_Motion"):call("set_PlaySpeed", 1.0)
            end)
        end
        S.wyrm_btn_prev = nil
        S.wyrm_native_pending, S.wyrm_native_recover_until = nil, nil
        S.wyrm_attack = nil
        S.wyrm_atk_until = nil
        if costume and S.wyrm_atk_hold then costume.force_hold = nil end
        S.wyrm_atk_hold = nil
        return
    end
    local now = os.clock()
    -- Downed enemies recover through their own damage graph.  The old timed
    -- DmgDownLoop -> Locomotion jump poisoned later mounted hit registration.
    S.wyrm_down_release = nil
    local down, pressed = iris_wyrm_read_controls()
    -- Diagnostic for "the wolf won't attack at combat start": proves whether
    -- the press even reached this tick, and what state was holding the floor.
    for name, was in pairs(pressed) do
        if was then
            S.wyrm_last_press = string.format("%s (busy=%s lease=%s)",
                tostring(name),
                tostring(S.wyrm_atk_until ~= nil),
                tostring(S.wyrm_native_lease ~= nil))
        end
    end
    local pending = S.wyrm_native_pending
    if pending and now >= (tonumber(pending.at) or now) then
        S.wyrm_native_pending = nil
        if pending.costume == costume then
            iris_wyrm_native_bite_start(costume, now, pending.spec)
            return
        end
    end
    local native = S.wyrm_native_lease
    if native then
        if pressed.light and native.combo_kind == "bite"
            and (tonumber(native.combo_index) or 1) < 3 then
            native.combo_buffered = true
            native.combo_buffer_until = now + 1.25
            S.wyrm_native_status = "bite combo input buffered"
            iris_wyrm_combat_trace(native, "combo-input", "X buffered")
        end
        costume.cur_speed = 0.0
        costume.force_hold = true
        local native_age = now - native.t0
        iris_wyrm_native_grounded_motion_guard(native, false)
        if native.howl_blast and not native.howl_blast_done
            and native_age >= (tonumber(native.howl_blast_at) or 0.72) then
            native.howl_blast_done = true
            iris_wyrm_howl_blast(costume)
            iris_wyrm_combat_trace(native, "howl-effect", "native shell requested")
        end
        if native.howl_sound_at and not native.howl_sound_done
            and native_age >= native.howl_sound_at then
            native.howl_sound_done = true
            iris_wyrm_play_native_howl_sound(costume, native)
        end
        if native.aim_from and native.aim_delta then
            local a = math.min(1.0, math.max(0.0,
                native_age / math.max(0.01,
                    tonumber(native.aim_secs) or 0.12)))
            -- Fast ease-out: decisive enough to help, without a one-frame snap.
            local eased = 1.0 - (1.0 - a) * (1.0 - a)
            local yaw = native.aim_from + native.aim_delta * eased
            costume.wyrm_yaw = yaw
            pcall(function()
                local tf = costume.horse_go:call("get_Transform")
                local rot = tf:call("get_Rotation")
                rot.x, rot.y, rot.z, rot.w =
                    0.0, math.sin(yaw * 0.5), 0.0, math.cos(yaw * 0.5)
                tf:call("set_Rotation", rot)
            end)
        end
        -- Keep the nose on a living selected target through the wind-up. This is
        -- camera-independent and stops at the impact frame; it cannot make Shadow
        -- chase an enemy after the strike has committed.
        if native.phase ~= "acquire" and native.hard_aim == true
            and valid(native.target) and valid(native.target_go)
            and native_age <= (tonumber(native.impact_at) or 0.62) + 0.02 then
            native.aim_from, native.aim_delta = nil, nil
            iris_wyrm_native_prepare_aim(costume, native.target, native,
                tonumber(native.aim_deg) or 105.0, 0.01)
        end
        if native.phase == "acquire" then
            if not (valid(native.target) and valid(native.target_go)) then
                iris_wyrm_native_bite_finish("target lost during acquire")
                return
            end
            local mouth = iris_wyrm_native_mouth_positions(costume)
            local tp = universal_pos(native.target_go)
            local distance, across, along = nil, nil, nil
            if mouth and tp then
                local tf = costume.horse_go:call("get_Transform")
                local fwd = tf and tf:call("get_AxisZ") or nil
                if fwd then
                    local fx, fz = tonumber(fwd.x) or 0.0,
                        tonumber(fwd.z) or 0.0
                    local fl = math.sqrt(fx * fx + fz * fz)
                    if fl > 0.01 then
                        fx, fz = fx / fl, fz / fl
                        local dx, dz = tp.x - mouth.x, tp.z - mouth.z
                        distance = math.sqrt(dx * dx + dz * dz)
                        along = dx * fx + dz * fz
                        across = math.abs(dx * fz - dz * fx)
                    end
                end
            end
            native.acquire_distance = distance
            native.acquire_across = across
            native.acquire_along = along
            local acquire_age = now - (tonumber(native.acquire_t0) or now)
            local aimed = acquire_age >= math.max(0.08,
                tonumber(native.aim_secs) or 0.08)
            -- The mouth must genuinely bracket the victim before the authored
            -- window starts.  A timeout is not contact: firing anyway produced
            -- the visible air-bites in Aurora's recordings and hid whether the
            -- real fault was geometry or an unarmed HitController.
            local in_contact = distance and distance <= 1.35
                and across and across <= 1.05
                and along and along >= -0.75 and along <= 1.20
            -- r10: the PIN maul needs the mouth NEAR the body, not bracketing
            -- it -- damage is scripted and the slam covers the last half
            -- metre, whichever side the prey fell on. Post-pounce it lies
            -- under the belly (run 12: along=-0.94 withheld), so RT contact
            -- is pure distance; the converge drive closes it from any side.
            if native.direct_maul then
                in_contact = distance and distance <= 1.0
            end
            local timed_out = acquire_age >=
                (tonumber(native.approach_secs) or 0.58)
            if aimed and in_contact then
                local why = string.format("mouth=%.2fm across=%.2fm along=%.2fm%s",
                    tonumber(distance) or -1.0,
                    tonumber(across) or -1.0,
                    tonumber(along) or -1.0,
                    " ready")
                iris_wyrm_combat_trace(native, "acquire-ready", why)
                iris_wyrm_native_fire_bite(native, now, why)
                return
            end
            if timed_out then
                -- r10: RT only -- close enough at the deadline still slams;
                -- withholding here is what broke the Y->RT one-two punch.
                if native.direct_maul and distance and distance <= 1.6 then
                    local why = string.format(
                        "converge close enough (%.2fm) - slamming", distance)
                    iris_wyrm_combat_trace(native, "acquire-ready", why)
                    iris_wyrm_native_fire_bite(native, now, why)
                    return
                end
                local why = string.format(
                    "mouth=%.2fm across=%.2fm along=%.2fm blocked=%s",
                    tonumber(distance) or -1.0, tonumber(across) or -1.0,
                    tonumber(along) or -1.0,
                    tostring(native.approach_blocked == true))
                iris_wyrm_combat_trace(native, "acquire-failed", why)
                iris_wyrm_native_bite_finish("contact acquire failed; attack withheld")
                return
            end
            return
        end
        -- Submit the captured ch223 jaw request once at the authored impact.
        -- Reposting it every frame resets rather than enlarges the native window.
        local jaw_impact = tonumber(native.impact_at) or 0.62
        if native.slot ~= "voice"
            and (native.node == "Ch223_Bite" or native.force_contact)
            and not native.contact_resolved
            and not native.native_jaw_requested
            and valid(native.target)
            and native_age >= jaw_impact - 0.10
            and native_age <= jaw_impact + 0.20 then
            native.native_jaw_requested =
                iris_wyrm_native_request_jaw(native, native.label,
                    native.native_request_id)
        end
        -- 08-18: combo links trust their clip-owned windows first (see the
        -- combo_advance field law). Only if the authored window has produced
        -- no HP transaction by impact+0.12 does the proven standalone jaw
        -- request (50) fire once. Native collider either way.
        if native.native_request_fallback
            and not native.native_jaw_fallback_done
            and not native.contact_resolved
            and valid(native.target)
            and native_age >= jaw_impact + 0.12 then
            native.native_jaw_fallback_done = true
            iris_wyrm_native_request_jaw(native,
                tostring(native.label) .. " (fallback)",
                native.native_request_fallback)
        end
        -- Receipts only: a real hit is one which changed HP through ch223's own
        -- jaw collider.  The previous shell substitution created a request but no
        -- receiver transaction, then falsely labelled later combo/maul pulses as
        -- native hits.  Never counterfeit a miss here.
        if (native.node == "Ch223_Bite" or native.force_contact)
            and not native.contact_resolved
            and native_age >= (tonumber(native.impact_at) or 0.62)
            and valid(native.target) then
            local hp_contact = iris_wyrm_native_target_hp(native.target)
            local native_landed = native.hp0 and hp_contact
                and hp_contact < native.hp0 - 0.01
            if not native_landed then
                -- Native-only contract: an absent authored ch223 transaction is
                -- a miss.  Do not substitute a ShellManager hit, direct HP, blood
                -- pulse or generic reaction; Aurora explicitly wants the wolf's
                -- genuine collider/material language or nothing.
                -- A posted fallback window (impact+0.12) needs its own grace
                -- before the verdict; without it the fallback had 0.12s to
                -- produce a receiver transaction.
                local miss_at = (tonumber(native.impact_at) or 0.62)
                    + (native.native_jaw_fallback_done and 0.36 or 0.24)
                if native_age >= miss_at then
                    native.contact_resolved = true
                    native.native_contact_missed = true
                    -- 08-18: stamp mouth-frame geometry into the miss row.
                    -- Pounces skip the acquire phase, so their traces carried
                    -- no distance/along/across and every miss was blind.
                    pcall(function()
                        if not valid(native.target_go) then return end
                        local mouth = iris_wyrm_native_mouth_positions(costume)
                        local tp = universal_pos(native.target_go)
                        if not (mouth and tp) then return end
                        local tf = costume.horse_go:call("get_Transform")
                        local fwd = tf:call("get_AxisZ")
                        local fx, fz = tonumber(fwd.x) or 0.0,
                            tonumber(fwd.z) or 0.0
                        local fl = math.sqrt(fx * fx + fz * fz)
                        if fl <= 0.01 then return end
                        fx, fz = fx / fl, fz / fl
                        local dx, dz = tp.x - mouth.x, tp.z - mouth.z
                        native.acquire_distance = math.sqrt(dx * dx + dz * dz)
                        native.acquire_along = dx * fx + dz * fz
                        native.acquire_across = math.abs(dx * fz - dz * fx)
                    end)
                    S.wyrm_native_status = tostring(native.label)
                        .. " jaw window missed (no substitute damage)"
                    log(S.wyrm_native_status)
                    iris_wyrm_combat_trace(native, "jaw-miss", S.wyrm_native_status)
                end
            else
                native.contact_resolved = true
                native.native_contact = true
                iris_wyrm_combat_trace(native, "jaw-hit",
                    "authored jaw HP delta=" .. tostring(hp_contact - native.hp0))
                -- The native hit is real and already presenting; scale its
                -- magnitude through the working post-hit lever.
                iris_wyrm_apply_bonus_damage(native,
                    native.hp0 - hp_contact,
                    tostring(native.label or "bite"))
            end
        end
        if native.combo_maul and native.phase == "opener" then
            local hp_now = iris_wyrm_native_target_hp(native.target)
            if native.hp0 and hp_now
                and hp_now < native.hp0 - 0.01 then
                native.opener_hit = true
            end
            if native.opener_hit then
                local is_down, detail =
                    iris_wyrm_native_target_down_state(native.target)
                native.target_down_detail = detail
                if is_down == true then
                    if not iris_wyrm_native_begin_maul(native, now, false) then
                        iris_wyrm_native_bite_finish("startCatch failed; maul cancelled")
                    end
                    return
                end
                if native_age >= 1.35 then
                    iris_wyrm_native_bite_finish(
                        "opener hit but native pounce did not down target")
                    return
                end
            elseif native_age >= 1.35 then
                iris_wyrm_native_bite_finish("opener missed; maul cancelled")
                return
            end
        end
        if (native.phase == "catch"
                or (native.direct_maul and native.catch_move))
            and native_age >= 0.25 then
            local catcher_active = iris_wyrm_native_catch_active(
                native.catch_controller)
            local caught_active = iris_wyrm_native_caught_active(native.target)
            native.catch_catcher_active = catcher_active
            native.catch_caught_active = caught_active
            -- A successful catch may retire its catcher-side one-shot while the
            -- victim-side controller continues maintaining the C_PropA pairing.
            -- Griffin field work proved the caught half is authoritative here.
            if not caught_active then
                if native.native_maul_window then
                    -- r7: the live-window maul has no scripted stages to fall
                    -- back on -- when the native pairing ends (victim died,
                    -- escaped, or the engine retired it), end cleanly and
                    -- re-park rather than holding an empty 6s lease.
                    iris_wyrm_native_bite_finish(
                        "native maul: attachment ended")
                    return
                elseif native.direct_maul then
                    native.catch_detached = true
                    native.catch_move = false
                    native.retain_catch = false
                    S.wyrm_native_status =
                        "contextual maul: native attachment ended; planted maul continuing"
                else
                    iris_wyrm_native_bite_finish(
                        "native caught-side transaction ended")
                    return
                end
            end
        end
        -- r7: amplify the native maul's own chomp damage. Watch the victim's
        -- HP at 4Hz; every native decrement gets the dial x IV bonus, then the
        -- watermark re-reads so the bonus itself is never re-amplified.
        if native.native_maul_window and valid(native.target)
            and now >= (tonumber(native.maul_amp_at) or 0.0) then
            native.maul_amp_at = now + 0.25
            local hp_now = iris_wyrm_native_target_hp(native.target)
            local last = tonumber(native.maul_amp_hp) or tonumber(native.hp0)
            if hp_now and last and hp_now < last - 0.01 then
                iris_wyrm_apply_bonus_damage(native, last - hp_now,
                    "native maul chomp")
                hp_now = iris_wyrm_native_target_hp(native.target)
            end
            if hp_now then native.maul_amp_hp = hp_now end
        end
        if not native.observed_node and now - native.t0 >= 0.06 then
            native.observed_node = iris_wyrm_native_action_name(native.action_manager)
            if native.observed_node then
                S.wyrm_native_status = "native " .. tostring(native.label)
                    .. " live: " .. native.observed_node
                log(S.wyrm_native_status)
            end
        end
        -- Field test 1 proved that requesting the node alone moved the root but
        -- never gave the mounted render layer a bite.  Keep ActionManager as
        -- the damage/collider owner, then paint the exact atlas motion once the
        -- action has had a frame to enter.  This is still native contact; only
        -- the mounted visual is deterministic.
        for _, stage in ipairs(native.visual_stages or {}) do
            if not stage.done and native_age >= (tonumber(stage.at) or 0.08) then
                stage.done = true
                if stage.maul_contact and valid(native.target) then
                    -- Each maul bite must be a fresh authored jaw transaction.
                    -- Clearing the outgoing histories before the hit clip lets
                    -- blood, material sound, damage and victim reaction all come
                    -- from the game rather than from a synthetic HP change.
                    stage.hp0 = iris_wyrm_native_target_hp(native.target)
                    stage.collider_rearmed =
                        iris_wyrm_native_rearm_attack(native.costume,
                            "maul contact") == true
                    -- 08-18 r4: replayed requests NEVER transact (run 48 proof)
                    -- and would only restart the painted 50:50's own window --
                    -- rearm histories, then let the bite clip's authored event
                    -- do the whole job (the stomp law, both directions).
                    iris_wyrm_combat_trace(native, "maul-window",
                        "clip=" .. tostring(stage.bank) .. ":" .. tostring(stage.clip)
                            .. " rearm=" .. tostring(stage.collider_rearmed)
                            .. " | clip-owned event only (replays proven dead)")
                end
                if stage.bank ~= nil and stage.clip ~= nil then
                    pcall(function()
                        local motion = costume.horse_character:call("get_Motion")
                        local layer = motion and motion:call("getLayer", 0)
                        if layer then
                            layer:call(
                                "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                                stage.bank, stage.clip, 0.0,
                                tonumber(stage.blend) or 6.0, 1, 1)
                            layer:call("set_Speed", tonumber(stage.speed) or 1.0)
                            costume.cmd_bank, costume.cmd_clip = stage.bank, stage.clip
                        end
                    end)
                    iris_wyrm_combat_trace(native, "motion-stage",
                        tostring(stage.bank) .. ":" .. tostring(stage.clip)
                            .. " requested")
                end
            end
        end
        for _, stage in ipairs(native.visual_stages or {}) do
            if stage.maul_contact and stage.done and not stage.result_checked
                and native_age >= (tonumber(stage.at) or 0.0)
                    + (tonumber(stage.result_at) or 0.28) then
                stage.result_checked = true
                if stage.pin_damage then
                    -- r8 pinned maul: the prey is held under the jaws -- deal
                    -- the chomp and fire its own EPV blood callback. No HP
                    -- delta to measure; this IS the damage.
                    local landed_pin, lethal_pin =
                        iris_wyrm_apply_direct_damage(native,
                            "pinned maul chomp")
                    -- r9: real-packet replay first (the route that paints);
                    -- the synthetic pulse only as a last resort.
                    if not iris_wyrm_prey_paint_chomp(native) then
                        pcall(function()
                            local pulse = rawget(_G, "IrisNativeBloodPulse")
                            if pulse and valid(native.target_go) then
                                pulse(native.target_go)
                            end
                        end)
                    end
                    -- r14: the pain cry -- post the prey's own captured hurt
                    -- vocal on its own container. Think-stop mutes native
                    -- FSM vocals, but a manual post plays (the ridden-cat
                    -- voice is the standing proof).
                    pcall(function()
                        local store = rawget(_G, "IrisWyrmPreyHurtVocal")
                        local rec = store and valid(native.target_go)
                            and store[object_address(native.target_go)]
                        local capi = rawget(_G, "__iris_wild_cats_api")
                        if rec and capi and capi.play_trigger_on then
                            local voiced = capi.play_trigger_on(
                                native.target_go, rec.trigger_id)
                            S.wyrm_maul_voice_status = voiced
                                and "pain cry posted"
                                or "pain cry post FAILED"
                        else
                            S.wyrm_maul_voice_status =
                                "no hurt vocal captured yet"
                        end
                    end)
                    -- r13: the r11 frame-0 clip restart SAT THE GOBLIN UP
                    -- (frame 0 of a damage clip is the standing start of the
                    -- reaction) and replayed the clip's root-motion shove.
                    -- Flinch = rewind a few frames behind the captured LYING
                    -- anchor and play back toward it at speed -- a squirm
                    -- that stays on the ground. No changeMotion, no root
                    -- restart, no guessed ids.
                    if native.pin_maul then
                        pcall(function()
                            if valid(native.target) then
                                local m = native.target:call("get_Motion")
                                local layer = m and m:call("getLayer", 0)
                                if layer and tonumber(native.pin_frame) then
                                    layer:call("set_Frame", math.max(0.0,
                                        (tonumber(native.pin_frame) or 0.0)
                                            - 12.0))
                                end
                                if m then m:call("set_PlaySpeed", 1.4) end
                                native.pin_jolt_until = now + 0.30
                            end
                        end)
                    end
                    native.maul_contacts =
                        (tonumber(native.maul_contacts) or 0) + 1
                    S.wyrm_native_status = "pinned maul chomp "
                        .. tostring(native.maul_contacts)
                        .. (landed_pin and "" or " (damage REFUSED)")
                    log(S.wyrm_native_status)
                    iris_wyrm_combat_trace(native, "maul-hit",
                        S.wyrm_native_status)
                    if lethal_pin and not native.pin_kill_pending then
                        -- r10: DON'T kill at the chomp that breaks the HP --
                        -- run 13 field verdict: killAndSetDieLoop at chomp 1
                        -- ragdolled the prey before any of the savaging read.
                        -- The floor holds it at 1 HP; the release fling is
                        -- the death blow (iris_wyrm_pin_kill below).
                        native.pin_kill_pending = true
                        iris_wyrm_combat_trace(native, "maul-kill-pending",
                            "HP exhausted - kill deferred to the release fling")
                    end
                else
                    local hp1 = iris_wyrm_native_target_hp(native.target)
                    local landed = stage.hp0 and hp1 and hp1 < stage.hp0 - 0.01
                    if landed then
                        iris_wyrm_apply_bonus_damage(native,
                            stage.hp0 - hp1, "maul chomp")
                    end
                    native.maul_contacts = (tonumber(native.maul_contacts) or 0)
                        + (landed and 1 or 0)
                    S.wyrm_native_status = landed
                        and ("genuine ch223 maul contact "
                            .. tostring(native.maul_contacts))
                        or "maul jaw window missed"
                    log(S.wyrm_native_status)
                    iris_wyrm_combat_trace(native,
                        landed and "maul-hit" or "maul-miss",
                        S.wyrm_native_status)
                end
            end
        end
        -- r13 POSE-SEEK: while the seek window is open, measure the head
        -- joint's height over the root; if the body reads half-standing,
        -- step the anchor frame backward (earlier in the clip = closer to
        -- the ground for the get-up tail) until it lies. Head_0 is the
        -- proven joint name on ch220 (DismemberLab lever C).
        if native.pin_maul and tonumber(native.pin_frame)
            and native.pin_seek_until and now <= native.pin_seek_until
            and valid(native.target_go) and valid(native.target) then
            pcall(function()
                local tf = native.target_go:call("get_Transform")
                local hj = tf and tf:call("getJointByName", "Head_0")
                local hp = hj and hj:call("get_Position")
                local rp = tf and tf:call("get_Position")
                if hp and rp
                    and (tonumber(hp.y) or 0.0) - (tonumber(rp.y) or 0.0)
                        > 0.45
                    and (tonumber(native.pin_frame) or 0.0) > 8.0 then
                    native.pin_frame = math.max(8.0,
                        (tonumber(native.pin_frame) or 0.0) - 6.0)
                    local m = native.target:call("get_Motion")
                    local layer = m and m:call("getLayer", 0)
                    if layer then
                        layer:call("set_Frame",
                            tonumber(native.pin_frame) + 0.0)
                    end
                end
            end)
        end
        -- r13: the frame clamp -- the pinned clip may never advance past the
        -- captured lying frame, so the goblin stays DOWN between flinches.
        if native.pin_maul and tonumber(native.pin_frame)
            and valid(native.target) then
            pcall(function()
                local m = native.target:call("get_Motion")
                local layer = m and m:call("getLayer", 0)
                local f = layer and tonumber(layer:call("get_Frame"))
                if f and f > (tonumber(native.pin_frame) or 0.0) then
                    layer:call("set_Frame",
                        tonumber(native.pin_frame) + 0.0)
                end
            end)
        end
        -- r12: the position clamp -- re-assert the pin anchor every tick so
        -- no root motion or knockback can slide the prey out of the jaws.
        -- Dies with pin_maul, so the death fling ragdolls free.
        if native.pin_maul and native.pin_anchor
            and valid(native.target_go) then
            pcall(function()
                local tf = native.target_go:call("get_Transform")
                local p = tf and tf:call("get_UniversalPosition")
                if p then
                    p.x = native.pin_anchor.x
                    p.y = native.pin_anchor.y
                    p.z = native.pin_anchor.z
                    tf:call("set_UniversalPosition", p)
                end
            end)
        end
        -- r10: the deferred death blow -- the release fling (stage at 4.14)
        -- IS the kill. Fires just before it so the body ragdolls out of the
        -- throw.
        if native.pin_kill_pending and not native.pin_kill_done
            and native.direct_maul and native_age >= 4.10 then
            native.pin_kill_done = true
            iris_wyrm_pin_kill(native)
        end
        -- r9: end of a chomp jolt -- settle the pinned body back into the
        -- slow struggle.
        if native.pin_maul and native.pin_jolt_until
            and now >= native.pin_jolt_until then
            native.pin_jolt_until = nil
            pcall(function()
                if valid(native.target) then
                    local m = native.target:call("get_Motion")
                    if m then m:call("set_PlaySpeed", 0.30) end
                end
            end)
        end
        -- 08-18 r5: the r4 release polled the down FLAG and killed run 20's
        -- maul at 0.9s -- before the first chomp -- because IsDown flipped
        -- false while the goblin still lay there. ⛔ get_IsDown LIES (the
        -- liveness law). Release only on FACTS: target gone, target dead, or
        -- the body physically out of the jaws (>3m). A victim that stands up
        -- in the jaws keeps getting chomped -- 50:50 bites standing targets.
        if native.direct_maul and native.phase == "maul"
            and native_age >= 1.7
            and now >= (tonumber(native.maul_down_check_at) or 0.0) then
            native.maul_down_check_at = now + 0.4
            if not valid(native.target) then
                iris_wyrm_native_bite_finish("maul ended: target gone")
                return
            end
            local hp_now = iris_wyrm_native_target_hp(native.target)
            if hp_now ~= nil and hp_now <= 0.0 then
                iris_wyrm_native_bite_finish("maul ended: target dead")
                return
            end
            local away = nil
            pcall(function()
                local mouth = iris_wyrm_native_mouth_positions(costume)
                local tp = valid(native.target_go)
                    and universal_pos(native.target_go) or nil
                if mouth and tp then
                    local dx, dz = tp.x - mouth.x, tp.z - mouth.z
                    away = math.sqrt(dx * dx + dz * dz)
                end
            end)
            if away and away > 3.0 then
                iris_wyrm_native_bite_finish("maul ended: target escaped jaws")
                return
            end
        end
        if native.release_node and not native.release_requested
            and native_age >= (tonumber(native.release_at) or 1.5) then
            native.release_requested = true
            pcall(function()
                native.action_manager:call(
                    "requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)",
                    0, native.release_node, 0)
            end)
        end
        if native.combo_kind == "bite" then
            if native.combo_buffer_until and now > native.combo_buffer_until then
                native.combo_buffered = nil
                native.combo_buffer_until = nil
            end
            if native.combo_buffered
                and native_age >= (tonumber(native.combo_transition_at) or 0.75)
                and (tonumber(native.combo_index) or 1) < 3 then
                iris_wyrm_native_combo_advance(native, now)
                return
            end
            if native_age >= (tonumber(native.combo_end_at)
                    or tonumber(native.attack_duration) or 1.0) then
                iris_wyrm_native_bite_finish("combo ended")
                return
            end
        end
        if now >= native.until_t then
            iris_wyrm_native_bite_finish("completed")
        end
        return
    end
    if costume.wyrm_impact_pause_until then
        if now < costume.wyrm_impact_pause_until then
            costume.cur_speed = 0.0
            return
        end
        costume.wyrm_impact_pause_until = nil
        pcall(function()
            costume.horse_character:call("get_Motion"):call("set_PlaySpeed", 1.0)
        end)
    end
    local active = S.wyrm_attack
    if active then
        local age = now - (tonumber(active.t0) or now)
        -- No per-frame transform pin here.  Pinning a live CharacterController
        -- against combat/root-motion produced a physics correction loop and the
        -- catastrophic frame collapse.  The drive owns translation; the attack
        -- merely holds requested speed at zero while its visual plays.
        costume.cur_speed = 0.0
        for _, stage in ipairs(active.stages or {}) do
            if not stage.done and age >= stage.at then
                stage.done = true
                costume.cmd_bank, costume.cmd_clip = stage.bank, stage.clip
                pcall(function()
                    local layer = costume.horse_character:call("get_Motion"):call("getLayer", 0)
                    if layer then
                        layer:call(
                            "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                            stage.bank, stage.clip, 0.0, 0.12, 1, 1)
                    end
                end)
            end
        end
        if age >= (tonumber(active.hit_at) or 0.5) and active.hit ~= true then
            pcall(iris_wyrm_attack_hit, costume, active)
        end
    end
    if S.wyrm_atk_until and now > S.wyrm_atk_until then
        S.wyrm_atk_until = nil
        S.wyrm_attack = nil
        if S.wyrm_atk_hold then
            S.wyrm_atk_hold = nil
            costume.force_hold = nil
            costume.last_gait = nil   -- gait re-pick resumes locomotion
        end
    end
    if S.wyrm_atk_until then return end   -- one move at a time
    if costume.wyrm_chassis == "ch223" then
        if pressed.dodge_left then
            -- Native action names are truthful; the atlas/AxisX fallback is
            -- mirrored and keeps its historical compensation.
            iris_wyrm_dodge_start(costume, now,
                costume.native_controller_live and -1 or 1)
            return
        elseif pressed.dodge_right then
            iris_wyrm_dodge_start(costume, now,
                costume.native_controller_live and 1 or -1)
            return
        elseif pressed.maul then
            iris_wyrm_native_bite_start(costume, now, {
                label = "contextual maul",
                slot = "maul",
                node = "HoldDownCatchAttack",
                duration = 5.0,
                range = 7.5,
                width = 6.0,
                vertical = 12.0,
                -- 08-18 r4 (trace runs 39-44: SIX RT presses withheld with the
                -- prone victim 2-3m BEHIND the mouth -- a 1.85-scale wolf's jaw
                -- sits metres past a goblin it is standing over). Full-circle
                -- aim turns the wolf onto the body; the longer, wider approach
                -- then closes forward after the pivot.
                aim_deg = 180.0,
                aim_secs = 0.22,
                hard_aim = true,
                requires_downed = true,
                direct_maul = true,
                -- RT used to skip target acquisition entirely, so Shadow could
                -- maul the ground while the prone victim lay outside his mouth.
                -- r10: forward approach OFF for RT -- it can only close a
                -- positive along, and post-pounce the prey lies BEHIND the
                -- mouth (run 12: along=-0.94 withheld). The omnidirectional
                -- converge in the drive loop owns all RT movement now.
                approach_stop = 0.30,
                approach_max = 3.6,
                approach_secs = 1.25,
                approach_speed = 0.0,
                visual_stages = {},
            })
            return
        end
    end
    local moves = (costume.wyrm_chassis == "ch260") and {
        light = { bank=50, clip=20, dur=1.05, hit_at=0.42, damage=150, range=5.5, min_dot=-0.35 },
        -- Grounded grab/maul sequence: no jump root motion, water launch or
        -- camera buck.  The contact lands on the authored hold-hit frame.
        heavy = { bank=20, clip=2010, dur=1.45, hit_at=0.50, damage=320,
            range=6.0, width=3.2, stages={{at=0.34,bank=20,clip=2012},
                {at=0.92,bank=20,clip=2020}} },
        voice = { bank=0, clip=4610, dur=2.65, hit_at=0.95, damage=80, range=10.0,
            stages={{at=0.52,bank=0,clip=4611},{at=2.00,bank=0,clip=4612}} },
    } or {
        light = { bank=50, clip=50, dur=1.05, hit_at=0.42, damage=150, range=5.5, min_dot=-0.35 },
        heavy = { bank=20, clip=4010, dur=1.45, hit_at=0.50, damage=320,
            range=6.0, width=3.2, stages={{at=0.34,bank=20,clip=4012},
                {at=0.92,bank=20,clip=4020}} },
        voice = { bank=0, clip=4610, dur=2.65, hit_at=0.95, damage=80, range=10.0,
            stages={{at=0.52,bank=0,clip=4611},{at=2.00,bank=0,clip=4612}} },
    }
    if costume.wyrm_kind == "cat" then
        -- L2 CAT ROAR: the ch223 howl clips rear back and point the muzzle at
        -- the sky like a wolf because that is exactly what they were authored
        -- for. A planted battle-threat display (0:1 -> 0:2) reads as a big-cat
        -- roar and is paired with the imported attack-roar bank below.
        moves.voice = { bank=0, clip=1, dur=1.75, hit_at=0.62,
            damage=80, range=10.0, stages={{at=0.78,bank=0,clip=2}} }
    end
    for _, slot in ipairs({ "heavy", "light", "voice" }) do
        if pressed[slot] then
            if slot == "voice" and costume.wyrm_kind == "wolf"
                and costume.wyrm_chassis == "ch223" then
                -- Native action ownership is what emits the semantic wolf
                -- howl. The old manual clip was think-stopped, heard nothing,
                -- then Wild Cats supplied a feline fallback to Shadow.
                iris_wyrm_native_bite_start(costume, now, {
                    label = "howl",
                    slot = "voice",
                    node = "Ch223HowlingStartLoop",
                    duration = 2.65,
                    range = 0.0,
                    width = 0.0,
                    howl_blast = true,
                    howl_blast_at = 0.78,
                    -- Post from the actual open-mouth howl frame. Doing it on the
                    -- button frame raced the motion change and also taught Wild
                    -- Cats its own synthetic request as though Shadow had howled.
                    howl_sound_at = 0.52,
                    approach_max = 0.0,
                    release_node = "Ch223HowlingEnd",
                    release_at = 2.00,
                    visual_stages = {
                        { at = 0.08, bank = 0, clip = 4610 },
                        { at = 0.52, bank = 0, clip = 4611 },
                        { at = 2.00, bank = 0, clip = 4612 },
                    },
                })
                break
            end
            if slot == "light" and costume.wyrm_chassis == "ch223" then
                iris_wyrm_native_bite_start(costume, now)
                break
            end
            if slot == "heavy" and costume.wyrm_chassis == "ch223" then
                costume.wyrm_pounce_left = not costume.wyrm_pounce_left
                local left = costume.wyrm_pounce_left
                iris_wyrm_native_bite_start(costume, now, {
                    label = "pounce",
                    slot = "heavy",
                    node = left and "Ch223JumpAttackL" or "Ch223JumpAttackR",
                    duration = 0.98,
                    range = 12.0,
                    width = 8.5,
                    vertical = 12.0,
                    -- 08-18 r3: full-circle launch aim -- trace run 14 fired
                    -- with the goblin already BEHIND the mouth and 105° could
                    -- not bring the nose around before the leap.
                    aim_deg = 180.0,
                    aim_secs = 0.05,
                    hard_aim = true,
                    impact_at = 0.52,
                    force_contact = true,
                    pounce_motion = true,
                    -- r13: targetless default raised too -- an empty-air
                    -- pounce is still a travel leap.
                    pounce_travel = 4.2,
                    pounce_height = 0.48,
                    pounce_airtime = 0.50,
                    pounce_launch_delay = 0.06,
                    damage_kind = "heavy",
                    approach_stop = 0.12,
                    approach_max = 0.0,
                    approach_secs = 0.0,
                    approach_speed = 0.0,
                    forced_damage = 120.0,
                    -- 08-18 round 2: 50:413/423 own their attack events (423
                    -- proved it as combo link 3, 6/6). The explicit post on the
                    -- button path could stomp them mid-window; trust the clip,
                    -- fall back to the proven 50 only when nothing landed.
                    request_auto = true, request_fallback = 50,
                    visual_stages = left and {
                        { at = 0.02, bank = 51, clip = 410, blend = 10.0 },
                        { at = 0.12, bank = 50, clip = 413, blend = 7.0 },
                        { at = 0.78, bank = 50, clip = 415, blend = 8.0 },
                    } or {
                        { at = 0.02, bank = 51, clip = 420, blend = 10.0 },
                        { at = 0.12, bank = 50, clip = 423, blend = 7.0 },
                        { at = 0.78, bank = 50, clip = 425, blend = 8.0 },
                    },
                })
                break
            end
            local m = moves[slot]
            costume.force_hold = true
            S.wyrm_atk_hold = true
            S.wyrm_atk_until = now + m.dur
            costume.cmd_bank, costume.cmd_clip = m.bank, m.clip
            S.wyrm_attack = {
                -- Resolve the enemy on the impact frame. Holding a managed enemy
                -- wrapper through a wind-up is unnecessary dangling-handle risk.
                t0=now, slot=slot, hit_at=m.hit_at,
                damage=m.damage, range=m.range, width=m.width, min_dot=m.min_dot,
                lock_range=m.lock_range, stages=m.stages,
            }
            S.wyrm_attack.lock_range = S.wyrm_attack.lock_range or 14.0
            pcall(function()
                -- Seed the normal drive-phase residual filter.  Attack clips
                -- have authored root travel, but attack speed is intentionally
                -- zero; without this seed the first root sample escaped before
                -- the filter established a baseline.
                local p = universal_pos(costume.horse_go)
                costume.wyrm_prev_upos = p and { x = p.x, z = p.z } or nil
                costume.drive_step = { x = 0.0, z = 0.0 }
                if slot == "voice" then
                    costume.cur_speed = 0.0
                end
            end)
            costume.last_gait = nil
            pcall(function()
                local motion = costume.horse_character:call("get_Motion")
                local layer = motion and motion:call("getLayer", 0)
                if layer then
                    layer:call(
                        "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                        m.bank, m.clip, 0.0, 0.25, 1, 1)
                end
            end)
            S.need_rootmotion_kill = true
            -- 08-13 RIDDEN CAT VOICE: the think-stop silences the cat's native vocal
            -- triggers, so speak through the Wild Cats audio graph directly
            pcall(function()
                local capi = rawget(_G, "__iris_wild_cats_api")
                if capi and costume.wyrm_kind == "cat" then
                    if capi.play then
                        capi.play(slot == "voice" and "attack" or "attack",
                            costume.horse_go)
                    end
                elseif slot == "voice" and capi and capi.play_wolf_call then
                    -- Never fall back to the first arbitrary native vocal:
                    -- that was a pain event, not a howl.
                    capi.play_wolf_call(costume.horse_go)
                end
            end)
            break
        end
    end
end
-- ⭐ AUTO-ARM (08-13, "still can't ride it" - the panel button was a ritual nobody
-- should need): whenever the LIVE companion is a wyrm-grown wolf/cat within 8m and no
-- costume is armed, the saddle readies itself quietly. E/RT then just works.
function iris_wyrm_auto_arm()
    if os.clock() < (S.wyrm_arm_at or 0) then return end
    S.wyrm_arm_at = os.clock() + 1.0
    -- ⭐ 08-13 (Aurora: "still doing the growl... it wasn't happening before" - and
    -- she is right about WHY): the costume's think-stop freezes the wolf in whatever
    -- clip his AI was playing, and a companion wolf's follow posture is the aggro
    -- stalk with the growl looping in the clip. The 8m arm meant he was frozen
    -- basically always. Now: arm only at TOUCH range (2.4m - the mount press gate is
    -- 4.5m, so E/RT still just works), and AUTO-RELEASE when you walk away without
    -- riding - his own AI returns, he stands/follows/breathes naturally.
    local b = rawget(_G, "IrisGriffinBridge")
    local ch = nil
    pcall(function() ch = b and b.griffin and b.griffin() end)
    if S.costume then
        -- release the parked (unridden) wyrm costume once you leave its side
        if S.costume.wyrm_kind and not S.ride_pose_on then
            local go1 = S.costume.horse_go
            if not valid(go1) then iris_wyrm_mount_stop() return end
            local pp1 = universal_pos(player_game_object())
            local wp1 = universal_pos(go1)
            if pp1 and wp1 and distance(pp1, wp1) > 5.0 then
                iris_wyrm_mount_stop()
            end
        end
        return
    end
    if not ch then return end
    local go = nil
    pcall(function() go = ch:call("get_GameObject") end)
    if not valid(go) then return end
    local id = ""
    pcall(function() id = tostring(ch:call("get_CharaIDString")) end)
    if not (id:find("^ch260") or id:find("^ch223")) then return end
    local pp = universal_pos(player_game_object())
    local wp = universal_pos(go)
    if not (pp and wp) or distance(pp, wp) > 2.4 then return end
    iris_wyrm_mount_start(true)
end
-- ⭐⭐ 08-13 DRIFT CANCEL (Aurora: "moving forward it also goes sideways"): the wolf's
-- native loops carry root motion with LATERAL/banked components the horse's authored
-- clips never had (root-motion kill is default-off - root travel IS the mover). Keep
-- the forward travel, erase the sideways remainder: per frame, project the body's
-- actual movement onto its forward axis and write back the lateral part.
-- LateUpdateBehavior (the phase law: positions never in UpdateBehavior/PrepareRendering);
-- registered after costume_tick so the cancel runs post-pin.
function iris_wyrm_drift_cancel()
    local costume = S.costume
    if not (costume and costume.wyrm_kind and S.ride_pose_on)
        or costume.native_controller_live == true
        or C.wyrm_drift_cancel == false then
        S.wyrm_drift = nil
        return
    end
    pcall(function()
        local tf = costume.horse_go:call("get_Transform")
        local p = tf:call("get_Position")
        local nowc = os.clock()
        local prev = S.wyrm_drift
        S.wyrm_drift = { x = p.x, y = p.y, z = p.z, t = nowc }
        if not prev then return end
        local dx, dz = p.x - prev.x, p.z - prev.z
        local d2 = dx * dx + dz * dz
        if d2 > 25.0 then return end   -- a teleport: not ours
        local jmp = costume.jump
        if jmp then
            -- LEAP ("goes way too far, no height"): the jump clip carries big
            -- FORWARD root motion on top of the arc integrator's hspeed. Cancel
            -- lateral, clamp this frame's forward travel to the arc's own speed:
            -- the clip keeps the look, the integrator keeps the map.
            local az = tf:call("get_AxisZ")
            local fx, fz = az.x, az.z
            local fl = math.sqrt(fx * fx + fz * fz)
            if fl < 0.001 then return end
            fx, fz = fx / fl, fz / fl
            local fwd = dx * fx + dz * fz
            local lx, lz = dx - fx * fwd, dz - fz * fwd
            local back = 0.0
            local dtc = math.min(0.15,
                math.max(0.0, nowc - (tonumber(prev.t) or nowc)))
            local maxf = ((tonumber(jmp.hspeed) or 0.0) + 0.3) * dtc
            if fwd > maxf then back = fwd - maxf end
            if (lx * lx + lz * lz) < 1e-6 and back <= 0.0 then return end
            local nx = p.x - lx - fx * back
            local nz = p.z - lz - fz * back
            tf:call("set_Position", Vector3f.new(nx, p.y, nz))
            S.wyrm_drift = { x = nx, y = p.y, z = nz, t = nowc }
            return
        end
        -- ⛔ 08-13 v4: ground-frame cancellation MOVED INTO THE DRIVE TICK itself
        -- (see the drive block). This LateUpdate callback raced the drive across
        -- phases and ate the real commanded step as "contamination" - Aurora:
        -- "movement is kinda non-existent". Jump frames only from here on (the
        -- leap clamp above is field-approved and phase-safe: the integrator owns
        -- jump position in this same phase).
    end)
end
re.on_application_entry("UpdateBehavior", function()
    -- ⭐ 08-13 THE MOUNTED TRUTH: while seated on ANY rodeo mount (horse, unicorn,
    -- wolf, cat...) ground-life interactions must stand down - taming prompts,
    -- sowing, cookpots, the stable UI (opening it mid-ride teleported Aurora under
    -- the ground and killed the cat). Consumers read rawget(_G, "IrisRiddenNow").
    _G.IrisRiddenNow = ((S.ride_pose_on == true)
        or (rawget(_G, "IrisGriffinMounted") == true)) and true or nil
    pcall(iris_wyrm_ownership_tick)
    pcall(iris_wyrm_native_hit_capture_flush)
    pcall(iris_wyrm_attack_tick)
    pcall(iris_wyrm_auto_arm)
end)
re.on_application_entry("LateUpdateBehavior", function()
    pcall(iris_wyrm_drift_cancel)
end)

-- kill ROOT MOTION on the shell (07-23 "the horse kind of shakes now"):
-- the gait clips shove the shell's root forward every frame and the pin
-- snaps it back — a per-frame fight the mesh renders as vibration. The
-- exact API is engine-version dependent, so try the known names and
-- report what stuck; a component sweep catches app-level movers too.
local function shell_kill_root_motion()
    -- EXPERIMENT, OFF BY DEFAULT (07-23: first field run made the PLAYER
    -- "vibrate and shake a lot" — the sweep likely disabled something the
    -- shell needs; A/B it via the checkbox while reading the diag line)
    if C.rootmotion_kill ~= true then
        S.rootmotion_diag = "(kill disabled — checkbox to A/B)"
        return
    end
    local costume = S.costume
    if not (costume and costume.horse_character) then return end
    local report = {}
    pcall(function()
        local motion = costume.horse_character:call("get_Motion")
        local layer = motion and motion:call("getLayer", 0)
        for _, target in ipairs({
            {obj = layer, tag = "layer"},
            {obj = motion, tag = "motion"},
        }) do
            if target.obj then
                for _, name in ipairs({
                    "set_RootMotion", "set_EnableRootMotion",
                    "set_RootMotionEnable", "set_IsRootMotion",
                    "set_ApplyRootMotion",
                }) do
                    if pcall(function()
                        target.obj:call(name, false)
                    end) then
                        report[#report + 1] = target.tag .. ":" .. name
                    end
                end
            end
        end
    end)
    pcall(function()
        costume.rootmotion_disabled = costume.rootmotion_disabled or {}
        local comps = costume.horse_go:call("get_Components")
        for _, comp in ipairs(comps and comps:get_elements() or {}) do
            local type_name = ""
            pcall(function()
                type_name = comp:get_type_definition():get_full_name()
            end)
            if type_name:find("RootMotion") or type_name:find("RootMove") then
                pcall(function()
                    if comp:call("get_Enabled") == true then
                        comp:call("set_Enabled", false)
                        costume.rootmotion_disabled[
                            #costume.rootmotion_disabled + 1] = comp
                        report[#report + 1] = "comp:" .. type_name
                    end
                end)
            end
        end
    end)
    S.rootmotion_diag = #report > 0
        and table.concat(report, ", ")
        or "nothing found — root motion API not located"
end

-- the seat write, callable from BOTH update phases (LateUpdateBehavior
-- for gameplay-visible position, PrepareRendering so the rendered frame
-- can never show a mid-frame nudge — the griffin's proven pair)
local function seat_pin_apply()
    local costume = S.costume
    if not (S.ride_pose_on and costume and costume.seat) then return end
    -- ⛔ pose-only (the griffin invert): the native climb owns position —
    -- a single transform write here wakes the rollback/rescue = the fade.
    -- Never pin. Joints + camera only.
    if costume.pose_only then return end
    if not valid(costume.horse_go) then return end
    -- r28 FIRST-MOUNT FIX (Aurora: first mount after spawning seats her
    -- on the RUMP; every remount is fine): the seat joint resolves at
    -- mount time, and on a fresh spawn the converted skeleton is still
    -- settling -- the lookup can latch the wrong joint. Re-resolve once
    -- ~1s in; a changed joint snaps the seat onto the true spine.
    -- (r54: the r36-r51 mount-saga diagnostics lived here -- limb/body
    -- fingerprints, action/cling probes. Stripped once Aurora called
    -- the saga over; the full story is in the memory file
    -- iris-horse-mount-determinism-hunt.)
    do
        local seat = costume.seat
        if seat.joint_recheck_at == nil then
            seat.joint_recheck_at = os.clock() + 0.9
        elseif seat.joint_recheck_at
            and os.clock() >= seat.joint_recheck_at then
            seat.joint_recheck_at = false
            pcall(function()
                local fresh = find_seat_joint(seat.horse_go)
                if fresh and fresh ~= seat.joint then
                    seat.joint = fresh
                    log("seat joint re-resolved (first-mount fix)")
                end
            end)
        end
    end
    pcall(function()
        local seat = costume.seat
        local horse_tf = costume.horse_go:call("get_Transform")
        local player_tf = seat.player_go:call("get_Transform")
        -- (r54: r44-r50 drift/heartbeat instrumentation stripped; the
        -- late pin + enforcer that came out of it are load-bearing and
        -- live below / in the frame loop)
        local hrot = horse_tf:call("get_Rotation")
        local off = seat.local_off or {0.0, 0.0, 0.0}
        -- YAW-ONLY position lever (07-23 "slides into the neck"): the
        -- ~1.55m up-offset rotated by the FULL rotation swings like a
        -- pendulum when the body pitches on gait bob or slopes (15° =
        -- 40cm forward). The seat POSITION follows heading only; the
        -- rider's BODY still tilts with the trimmed rotation below.
        local fwd_ax = horse_tf:call("get_AxisZ")
        local yaw_half = math.atan(fwd_ax.x, fwd_ax.z) * 0.5
        local yaw_q = {x = 0.0, y = math.sin(yaw_half), z = 0.0,
                       w = math.cos(yaw_half)}
        -- passenger mode: the seat frame follows the ANIMATED spine
        -- (full 3-axis incl. roll), not the static body root — the live
        -- idle otherwise sweeps the back out from under the rider.
        -- FOLLOW SMOOTHING (07-24 "animating like mad"): low-pass the
        -- ANIMATION component only — spikes soften, the rider rides the
        -- average of the thrash; root travel stays instant (no flight
        -- lag). alpha shared with the joint-offset smoother below.
        local basis, follow_alpha = nil, nil
        if costume.passenger_only then
            local tau = seat_cfg("seat_follow_smooth", 0.0)
            if tau > 0.01 then
                local now_t = os.clock()
                local dt = math.min(0.1,
                    now_t - (seat.follow_t or now_t))
                seat.follow_t = now_t
                follow_alpha = 1.0 - math.exp(-dt / tau)
            end
            basis = seat_saddle_basis(horse_tf)
            if basis and follow_alpha and seat.basis_smooth then
                local prev = seat.basis_smooth
                local dot = prev.w * basis.w + prev.x * basis.x
                    + prev.y * basis.y + prev.z * basis.z
                local sgn = dot < 0 and -1.0 or 1.0
                local q = {
                    w = prev.w + (basis.w * sgn - prev.w) * follow_alpha,
                    x = prev.x + (basis.x * sgn - prev.x) * follow_alpha,
                    y = prev.y + (basis.y * sgn - prev.y) * follow_alpha,
                    z = prev.z + (basis.z * sgn - prev.z) * follow_alpha,
                }
                local l = math.sqrt(q.w * q.w + q.x * q.x
                    + q.y * q.y + q.z * q.z)
                if l > 1e-6 then
                    q.w, q.x, q.y, q.z = q.w / l, q.x / l, q.y / l, q.z / l
                    basis = q
                end
            end
            if basis then
                seat.basis_smooth = basis
                yaw_q = basis
            end
        end
        local wx, wy, wz = quat_rot(yaw_q,
            off[1] + seat_cfg("seat_side", 0.0),
            off[2] + seat_cfg("seat_above_joint", 0.0),
            off[3] + seat_cfg("seat_fwd", 0.0))
        local pos = horse_tf:call("get_UniversalPosition")
        -- JOINT ANCHOR: base = the animated spine joint, rebased from
        -- render to universal space (griffin seat law: joint_render −
        -- body_render_root + body_universal_root). Rider rides the BACK,
        -- bobbing and swaying WITH the gait. Root is the fallback.
        local bx, by, bz = pos.x, pos.y, pos.z
        if seat.joint then
            pcall(function()
                local jp = seat.joint:call("get_Position")
                local hr = horse_tf:call("get_Position")
                local ox2 = jp.x - hr.x
                local oy2 = jp.y - hr.y
                local oz2 = jp.z - hr.z
                -- follow smoothing on the joint-vs-root offset (the
                -- ANIMATION part; the root itself is never smoothed)
                if follow_alpha and seat.off_smooth then
                    local o = seat.off_smooth
                    ox2 = o[1] + (ox2 - o[1]) * follow_alpha
                    oy2 = o[2] + (oy2 - o[2]) * follow_alpha
                    oz2 = o[3] + (oz2 - o[3]) * follow_alpha
                end
                if follow_alpha then
                    seat.off_smooth = {ox2, oy2, oz2}
                else
                    seat.off_smooth = nil
                end
                bx = pos.x + ox2
                by = pos.y + oy2
                bz = pos.z + oz2
            end)
        end
        pos.x, pos.y, pos.z = bx + wx, by + wy, bz + wz
        -- MOUNT-UP lerp: while the vault plays, the seat base eases from
        -- the ground beside the horse to the saddle (smoothstep)
        local enter = seat.enter
        if enter then
            local t = (os.clock() - enter.t0) / enter.dur
            if t >= 1.0 then
                seat.enter = nil
            elseif enter.root then
                -- THE CLIP'S OWN JUMP (07-24 v2): base = start + the
                -- vault's root arc rotated into the approach heading;
                -- the saddle residual blends in smoothly on top so the
                -- leap is real AND the landing is exact
                local n = #enter.root
                local fi = math.max(1, math.min(n,
                    math.floor(t * (n - 1)) + 1))
                local rp = enter.root[fi]
                local cy = math.cos(enter.face_yaw)
                local sy2 = math.sin(enter.face_yaw)
                local ax = enter.fx + (rp[1] * cy + rp[3] * sy2)
                local ay = enter.fy + rp[2]
                local az = enter.fz + (-rp[1] * sy2 + rp[3] * cy)
                local s = t * t * (3.0 - 2.0 * t)
                pos.x = ax + (pos.x - (enter.fx + enter.end_x)) * s
                pos.y = ay + (pos.y - (enter.fy + enter.end_y)) * s
                pos.z = az + (pos.z - (enter.fz + enter.end_z)) * s
            else
                -- SYNTHESIZED LEAP v2 (07-24 "still slides"): a jump is
                -- TIMING, not a curve shape — crouch IN PLACE while the
                -- clip gathers (first 30%), then an explosive leap with
                -- a real arc over the saddle (30-75%), then settled.
                local p = math.max(0.0, math.min(1.0, (t - 0.22) / 0.45))
                local h = p * p * (3.0 - 2.0 * p)
                local hop = (enter.jump or 0.0) * math.sin(p * math.pi)
                pos.x = enter.fx + (pos.x - enter.fx) * h
                pos.y = enter.fy + (pos.y - enter.fy) * h + hop
                pos.z = enter.fz + (pos.z - enter.fz) * h
            end
        end
        player_tf:call("set_UniversalPosition", pos)
        seat.last_wx, seat.last_wy, seat.last_wz = pos.x, pos.y, pos.z
        local trimmed = seat_trim_rotation(basis or hrot)
        local rot = player_tf:call("get_Rotation")
        rot.x, rot.y, rot.z, rot.w =
            trimmed.x, trimmed.y, trimmed.z, trimmed.w
        player_tf:call("set_Rotation", rot)
        -- r50: rotation joins the late pin (position was enforced in
        -- three places, rotation in ONE -- and the off-angle seats
        -- prove that one write loses; the rider sat rotated to her
        -- APPROACH angle while position held perfectly)
        seat.last_rx, seat.last_ry, seat.last_rz, seat.last_rw =
            trimmed.x, trimmed.y, trimmed.z, trimmed.w
    end)
end

-- BONE-phase pass (PrepareRendering — the couples law: the ONLY place
-- joint-local writes stick; POSITION writes there get reverted/fight)
local function seat_bone_apply()
    local costume = S.costume
    if not (S.ride_pose_on and costume and costume.seat) then return end
    -- ARMS-ONLY: the native climb cling owns the body. We must NOT pin
    -- the hip to bind or reset feet (that clobbers the cling), BUT the
    -- seat position/rotation sliders STILL apply — as a NUDGE on top of
    -- the cling (07-24 "sliders don't move the arisen": arms_only used to
    -- early-return and skip them entirely — that was the bug).
    local arms_only = costume.pose_only and costume.arms_only
    pcall(function()
        local player_tf = costume.seat.player_go:call("get_Transform")
        local hip = player_tf:call("getJointByName", "Hip")
        if hip then
            -- base: FULL mode pins to BIND (deterministic body); ARMS-ONLY
            -- reads the CLING's current hip and nudges it (preserves the
            -- native cling posture). seat_hx/hy/hz = the offset, both modes.
            local px, py, pz
            if arms_only then
                local cur = hip:call("get_LocalPosition")
                px = tonumber(cur and cur.x) or 0
                py = tonumber(cur and cur.y) or 0
                pz = tonumber(cur and cur.z) or 0
            else
                local base = hip:call("get_BaseLocalPosition")
                px = tonumber(base and base.x) or 0
                py = tonumber(base and base.y) or 0
                pz = tonumber(base and base.z) or 0
            end
            if costume.pose_only then
                px = px + seat_cfg("seat_hx", 0.0)
                py = py + seat_cfg("seat_hy", 0.0)
                pz = pz + seat_cfg("seat_hz", 0.0)
            end
            hip:call("set_LocalPosition", Vector3f.new(px, py, pz))
            -- HIP ROTATION offset (07-24 ROUND-13, Aurora "no yaw/pitch/
            -- rotate sliders"): compose a yaw/pitch/roll offset ON TOP of
            -- the pose's hip rotation so she can angle the whole seated
            -- body — incl. un-horizontal a bad boarding pose. Joint-local
            -- = fade-safe (never the root, which the climb owns).
            if costume.pose_only then
                local ry = math.rad(seat_cfg("seat_hyaw", 0.0))
                local rp = math.rad(seat_cfg("seat_hpitch", 0.0))
                local rr = math.rad(seat_cfg("seat_hroll", 0.0))
                if ry ~= 0.0 or rp ~= 0.0 or rr ~= 0.0 then
                    pcall(function()
                        local cur = hip:call("get_LocalRotation")
                        if not cur then return end
                        local c = {w = tonumber(cur.w) or 1,
                            x = tonumber(cur.x) or 0,
                            y = tonumber(cur.y) or 0,
                            z = tonumber(cur.z) or 0}
                        local qy = {w = math.cos(ry * 0.5), x = 0,
                            y = math.sin(ry * 0.5), z = 0}
                        local qp = {w = math.cos(rp * 0.5),
                            x = math.sin(rp * 0.5), y = 0, z = 0}
                        local qr = {w = math.cos(rr * 0.5), x = 0, y = 0,
                            z = math.sin(rr * 0.5)}
                        local off = quat_mul(quat_mul(qy, qp), qr)
                        local n = quat_mul(c, off)
                        cur.x, cur.y, cur.z, cur.w = n.x, n.y, n.z, n.w
                        hip:call("set_LocalRotation", cur)
                    end)
                end
            end
        end
        -- FEET (07-24 "feet bent wrong"): the ride clips don't author
        -- ankles/feet/toes (the scene solver's ankle law), so they stay
        -- frozen at the climb frame — reset to bind each frame (the
        -- griffin rider_pose_cleanup recipe). ⛔ SKIP in arms_only: the
        -- native cling authors the feet (grip), don't clobber it.
        for _, name in ipairs(arms_only and {} or {
            "L_Leg_Ankle", "R_Leg_Ankle", "L_Leg_Foot", "R_Leg_Foot",
            "L_Leg_Toes", "R_Leg_Toes",
        }) do
            local joint = player_tf:call("getJointByName", name)
            if joint then
                local base_rot = joint:call("get_BaseLocalRotation")
                if base_rot then
                    -- quat -> engine ZXY euler (griffin q_to_euler recipe)
                    local qx = tonumber(base_rot.x) or 0
                    local qy = tonumber(base_rot.y) or 0
                    local qz = tonumber(base_rot.z) or 0
                    local qw = tonumber(base_rot.w) or 1
                    local m23 = 2 * (qy * qz - qx * qw)
                    local ex = math.asin(math.max(-1, math.min(1, -m23)))
                    local ey = math.atan(2 * (qx * qz + qy * qw),
                        1 - 2 * (qx * qx + qy * qy))
                    local ez = math.atan(2 * (qx * qy + qz * qw),
                        1 - 2 * (qx * qx + qz * qz))
                    joint:call("set_LocalEulerAngle",
                        Vector3f.new(ex, ey, ez))
                end
            end
        end
    end)
end

-- forward-declared: seat_play_ride_pose is defined ~1100 lines below but
-- costume_tick calls it (07-24 crash: "global seat_play_ride_pose is not
-- callable" — a local defined AFTER the caller is nil inside it)
local seat_play_ride_pose

local function costume_tick()
    local costume = S.costume
    if not costume then return end
    -- ⭐ 08-18 PHOTO-MODE / PAUSE FREEZE (Aurora: "the animation continues
    -- to play when paused"): the engine pauses native anim clocks but a
    -- dynamic-bank layer keeps playing, and this tick's os.clock ballistics
    -- (jump/kick/bless) advance straight through a pause. Park the shell
    -- layer at speed 0 and skip the drive; on resume, shift every running
    -- clock by the paused span so nothing "happened" while frozen. Pause
    -- state comes from the wild-horses module's field-verified detector
    -- (PauseManager.isPausedAny + GuiManager photo-mode getters).
    local wildS = rawget(_G, "__iris_wild_horses_v1")
    if wildS and wildS.game_paused then
        if not S.pause_hold then
            S.pause_hold = os.clock()
            pcall(function()
                local motion = costume.horse_character
                    and costume.horse_character:call("get_Motion")
                local layer = motion and motion:call("getLayer", 0)
                if layer then layer:call("set_Speed", 0.0) end
            end)
        end
        return
    elseif S.pause_hold then
        local span = os.clock() - S.pause_hold
        S.pause_hold = nil
        pcall(function()
            local motion = costume.horse_character
                and costume.horse_character:call("get_Motion")
            local layer = motion and motion:call("getLayer", 0)
            if layer then layer:call("set_Speed", 1.0) end
        end)
        pcall(function()
            local j = costume.jump
            if j then
                j.t0 = (j.t0 or 0) + span
                j.last_t = (j.last_t or 0) + span
                if j.front_at then j.front_at = j.front_at + span end
                if j.air_at then j.air_at = j.air_at + span end
            end
            local k = costume.kick
            if k then
                k.t0 = (k.t0 or 0) + span
                k.hit_at = (k.hit_at or 0) + span
            end
            local b = costume.bless
            if b then
                b.t0 = (b.t0 or 0) + span
                if b.thrust_t0 then b.thrust_t0 = b.thrust_t0 + span end
                b.gather_end = (b.gather_end or 0) + span
                b.strike_at = (b.strike_at or 0) + span
                b.ends_at = (b.ends_at or 0) + span
            end
            if costume.jump_land_until then
                costume.jump_land_until = costume.jump_land_until + span
            end
            if costume.jump_settle_until then
                costume.jump_settle_until = costume.jump_settle_until + span
            end
            costume.last_t = (costume.last_t or 0) + span
            if costume.gait_issue_t then
                costume.gait_issue_t = costume.gait_issue_t + span
            end
        end)
    end
    -- foot-IK release tracks the SEAT, not the costume: off while mounted,
    -- restored the moment the rider leaves (armed-but-unridden horses keep
    -- native IK so their own AI idles ground normally)
    if not costume.wyrm_kind and C.horse_ik_off_ride ~= false then
        local want_off = S.ride_pose_on == true
        if want_off and not costume.ik_released
            and valid(costume.horse_go) then
            costume.ik_released = true
            local touched = horse_ik_set(costume.horse_go, false)
            log("ride: horse leg-IK off (" .. tostring(#touched) .. " comps)")
        elseif (not want_off) and costume.ik_released
            and valid(costume.horse_go) then
            costume.ik_released = nil
            horse_ik_set(costume.horse_go, true)
            log("ride: horse leg-IK restored (dismount)")
        end
    end
    if not (valid(costume.ox_go) and valid(costume.horse_go)) then
        -- 08-06 (Aurora: dismissing the horse WHILE RIDING warped her to the
        -- origin): a seat pinned to a dead body is a teleport factory --
        -- route through the rider-death teardown (releases the seat) first
        if S.ride_pose_on then
            -- 08-07 (instant warp home on dismiss): costume_stop here ran
            -- BEFORE next frame's seat_dismount -- the landing spot then
            -- computed off a corpse, land stayed nil, and the whole
            -- handover collapsed into an instant component restore.
            -- Seat release FIRST (next frame), teardown second.
            S.costume_stop_requested = true
            return
        end
        costume_stop()
        return
    end
    -- A mounted damage reaction temporarily owns the horse's base motion.
    -- Release only the hold created by that reaction; jump/fall/landing holds
    -- have their own lifecycles and must not be cleared here.
    if costume.hit_react_hold
        and os.clock() >= (tonumber(costume.hit_react_until) or 0.0) then
        costume.hit_react_hold = nil
        costume.hit_react_until = nil
        costume.force_hold = nil
        costume.last_gait = nil
    end
    if S.need_rootmotion_kill then
        S.need_rootmotion_kill = nil
        shell_kill_root_motion()
    end
    if costume.pose_only then
        -- ⭐ THE INVERT (07-24 ROUND-10/11): the native climb owns
        -- position/physics/gravity/attach/fall-state — we touch NONE of
        -- it (no pin/suppress/belief-inject/fall-kill). We only pick the
        -- POSE by the griffin's ride-state and paint joints + camera.
        local seat = costume.seat
        if not (S.ride_pose_on and seat) then return end
        local now_p = os.clock()
        -- (a) MOUNT-UP -> riding-pose handoff (the get-on vault plays as
        -- joints while the native climb-on carries her up; then settle)
        if seat.pose_stage == "mountup" then
            if now_p >= (seat.pose_until or 0) then
                seat.pose_stage = "loop"
                seat.pose_variant = nil -- force the first state switch
            else
                return
            end
        end
        -- (b) deferred first pose start (no vault path)
        if S.pose_only_start_at and now_p >= S.pose_only_start_at then
            S.pose_only_start_at = nil
            seat.pose_stage = "loop"
        end
        if seat.pose_stage ~= "loop" then return end
        -- MANUAL pose ONLY (07-24 Aurora: keep the 3 tunable poses but NO
        -- auto-switching — she picks which one is live in the "active
        -- pose" dropdown). The airborne/speed state machine is GONE. The
        -- pose changes ONLY when she changes the dropdown.
        local sel = tostring(C.griffin_pose_sel or "gground")
        if not GRIFFIN_SUBVARIANTS[sel] then sel = "gground" end
        if seat.pose_variant ~= sel then
            S.seat_pose_report = seat_play_ride_pose(sel)
        end
        return
    end
    if costume.passenger_only then
        -- LEGACY puppet experiment (climb ENDED — fades; kept only for
        -- the horse-derived experiment button, NOT the griffin ride).
        seat_pin_apply()
        -- 07-24 FADE-TO-BLACK in flight (Aurora's read confirmed: the
        -- fall-RESCUE system): native RE-ENABLES IkLeg2 (+friends)
        -- every frame — the probe's storm note — so our one-shot
        -- suppress silently undoes itself and IkLeg2 reports "no
        -- ground, rescue!" the whole flight. Counter = per-tick
        -- re-disable, last-writer-wins (the probe's own recipe).
        if S.ride_pose_on then
            -- mortal now (no blanket shield): if she dies up there, the
            -- seat must release the body immediately
            pcall(function()
                local hp = player_character():call("get_Hp")
                if tonumber(hp) and tonumber(hp) <= 0 then
                    S.costume_stop_requested = true
                    return
                end
            end)
            for _, record in pairs(S.disabled_components) do
                pcall(function()
                    record.component:call("set_Enabled", false)
                end)
            end
            -- ⭐ the probe's ROUND-40/42 counter, ported: the STUCK-
            -- PLAYER RESCUE (the fade-to-black) restores her to a
            -- stored "safe coord". Poison the well every tick — safety
            -- = the seat she's already in — and un-latch the fall-dead
            -- revive bias. Whatever executor fires, displacement zero.
            pcall(function()
                local pl = player_character()
                local rec = pl:get_field("<PosRotRecorder>k__BackingField")
                if not rec then return end
                pcall(function() rec:call("set_IsSafeCoord", true) end)
                local ptf = player_game_object():call("get_Transform")
                local pp = ptf:call("get_UniversalPosition")
                local pr = ptf:call("get_Rotation")
                if pp and pr then
                    local vp = ValueType.new(
                        sdk.find_type_definition("via.Position"))
                    vp.x, vp.y, vp.z = pp.x, pp.y, pp.z
                    local fed = pcall(function()
                        rec:call("recordPosRotExternal", vp, pr)
                    end)
                    if not fed then
                        pcall(function()
                            rec:call("recordPosRot", vp, pr)
                        end)
                    end
                    pcall(function()
                        rec:set_field("PosAfterReviveFromFallDead",
                            Vector3f.new(pp.x, pp.y, pp.z))
                    end)
                end
                pcall(function()
                    rec:set_field("IsAfterReviveFromFallDead", false)
                end)
                S.rescue_feed_n = (tonumber(S.rescue_feed_n) or 0) + 1
                if S.rescue_feed_n % 60 == 30 then
                    -- the Recorder's own resetHistory (round-44 law:
                    -- never hand-drain — empty-data warps)
                    pcall(function() rec:call("resetHistory") end)
                end
                -- ⭐ ROUND-48/49 CURE, ported (the probe's fall-kill
                -- tick): at altitude the rider is in a perpetual
                -- native FALLING state — the stuck-fall machinery
                -- fires the fades, and FallInfo bills the whole
                -- flight as ONE lethal fall at touchdown. BELIEF
                -- INJECTION: ground rides 0.6m under her feet every
                -- tick and the fall meter reads zero. Nothing is
                -- disabled, so dismount needs no restore.
                local lp = nil
                pcall(function()
                    lp = rec:get_field("LandingProcessor")
                end)
                if lp and pp then
                    pcall(function()
                        local g = lp:call("get_LastGroundPosition")
                        if g then
                            g.x = pp.x
                            g.y = pp.y - 0.6
                            g.z = pp.z
                            lp:call("set_LastGroundPosition", g)
                        end
                    end)
                    pcall(function()
                        lp:call(
                            "resetFallingStuckStopperToCurrentPosition")
                    end)
                    pcall(function()
                        local fi = lp:get_field("FallInfo")
                        if fi then
                            fi:call("resetFallHeight")
                            fi:call("set_FallHeight", 0.0)
                        end
                    end)
                end
            end)
        end
        return
    end
    -- TAME RODEO ANCHOR (07-24 "miles in massive leaps, through the
    -- scenery"): during brace/rodeo NOTHING may translate the body.
    -- Kill any drive velocity and pin the root to the anchor every
    -- frame (LateUpdate = the phase position writes stick) — the bucks
    -- still read fine, joints hop around the pinned root.
    local tame_hold = S.tame
    local tame_pinned = tame_hold
        and (tame_hold.stage == "brace" or tame_hold.stage == "rodeo")
    if tame_pinned and not tame_hold.anchor then
        -- 07-24 review: the anchor was only ever set once, inside a pcall at
        -- brace entry. If that failed we silently lost BOTH the pin and the
        -- steering lock — the "miles in massive leaps through the scenery"
        -- runaway, straight back, with nothing to explain it. Re-acquire
        -- every frame until it takes.
        pcall(function()
            local p0 = costume.horse_go:call("get_Transform")
                :call("get_UniversalPosition")
            tame_hold.anchor = {p0.x, p0.y, p0.z}
            tame_hold.anchor_home = tame_hold.anchor_home
                or {p0.x, p0.y, p0.z}
        end)
    end
    if tame_pinned and tame_hold.anchor then
        -- NO early return: the loop assist below must keep re-firing the
        -- buck clips. The pin runs first; any residual drive nudge this
        -- frame is millimetres and gets wiped by next frame's pin.
        costume.cur_speed = 0.0
        -- 08-12 (Aurora: the breather trot was "very stuttery"): the anchor
        -- used to advance in the TAME tick while the pin applied it HERE in
        -- LateUpdate -- two clocks stepping one position = judder. The
        -- advance now happens in the same breath as the pin, with a slow
        -- WANDERING heading (re-rolled every 1-2s) so the circuit reads like
        -- an animal ambling, not a rail. Leash steering preserved.
        local ro2 = tame_hold.rodeo
        if ro2 and ro2.phase == "rest" then
            local now2 = os.clock()
            local pdt = math.min(0.05, now2 - (tame_hold.pin_t or now2))
            tame_hold.pin_t = now2
            pcall(function()
                local ox_tf2 = costume.ox_go:call("get_Transform")
                if not ro2.wander_until or now2 >= ro2.wander_until then
                    ro2.wander_until = now2 + 1.0 + math.random()
                    ro2.wander_rate = (math.random() - 0.5) * math.rad(50.0)
                end
                local turn2 = (ro2.wander_rate or 0.0) * pdt
                local hx0 = tame_hold.anchor[1]
                    - (tame_hold.anchor_home and tame_hold.anchor_home[1]
                        or tame_hold.anchor[1])
                local hz0 = tame_hold.anchor[3]
                    - (tame_hold.anchor_home and tame_hold.anchor_home[3]
                        or tame_hold.anchor[3])
                local fwd = ox_tf2:call("get_AxisZ")
                if math.sqrt(hx0 * hx0 + hz0 * hz0) > 3.0 then
                    local want = math.atan(-hx0, -hz0)
                    local have = math.atan(tonumber(fwd.x) or 0.0,
                        tonumber(fwd.z) or 1.0)
                    local dyaw = want - have
                    while dyaw > math.pi do dyaw = dyaw - 2 * math.pi end
                    while dyaw < -math.pi do dyaw = dyaw + 2 * math.pi end
                    turn2 = math.max(-1.0, math.min(1.0, dyaw))
                        * math.rad(80.0) * pdt
                end
                if turn2 ~= 0.0 then
                    local rot = ox_tf2:call("get_Rotation")
                    local half = turn2 * 0.5
                    local sy, cy = math.sin(half), math.cos(half)
                    local qx = rot.x * cy - rot.z * sy
                    local qy = rot.w * sy + rot.y * cy
                    local qz = rot.x * sy + rot.z * cy
                    local qw = rot.w * cy - rot.y * sy
                    rot.x, rot.y, rot.z, rot.w = qx, qy, qz, qw
                    ox_tf2:call("set_Rotation", rot)
                end
                fwd = ox_tf2:call("get_AxisZ")
                -- 08-12 (Aurora: "walk speed of the breather is too fast"):
                -- with the idle-latch fight fixed, a true WALK works -- the
                -- 08-06 "walk slid" verdict was the latch snapping, not the
                -- clip. 1.6 m/s matches the walk clip 901:1 commanded below.
                local step = 1.6 * pdt
                tame_hold.anchor[1] = tame_hold.anchor[1]
                    + (tonumber(fwd.x) or 0.0) * step
                tame_hold.anchor[3] = tame_hold.anchor[3]
                    + (tonumber(fwd.z) or 0.0) * step
            end)
        else
            tame_hold.pin_t = nil
        end
        pcall(function()
            local tf = costume.horse_go:call("get_Transform")
            local p = tf:call("get_UniversalPosition")
            p.x = tame_hold.anchor[1]
            p.z = tame_hold.anchor[3]
            -- 07-24 review: Y is NO LONGER pinned. The bucks drift the
            -- anchor up to 2.5m but only in X/Z, so a frozen height left
            -- the horse floating off a downhill or hips-deep in an uphill.
            -- Gravity owns height now; we only catch a REAL fall (>3m from
            -- where the brace began).
            local home_y = (tame_hold.anchor_home
                and tame_hold.anchor_home[2]) or tame_hold.anchor[2]
            if math.abs((tonumber(p.y) or home_y) - home_y) > 3.0 then
                p.y = home_y
            end
            tf:call("set_UniversalPosition", p)
            tame_hold.anchor[2] = p.y -- anchor tracks the live ground
        end)
    end
    pcall(function()
        local ox_tf = costume.ox_go:call("get_Transform")
        local horse_tf = costume.horse_go:call("get_Transform")
        -- THE REINS v1 (07-23 gait-lab verdict): the brain-off ox never
        -- moves on its own, so WE drive it — arrow keys puppet-drive the
        -- invisible body (approach-pathing technique), and the commanded
        -- gait is KNOWN, no speed guessing needed.
        --   Up = trot | Up+Shift = gallop | Up+Ctrl = walk
        --   Left/Right = turn (works while moving or standing)
        costume.driven_gait = nil
        do
            local now_d = os.clock()
            local dt = now_d - (costume.drive_t or now_d)
            costume.drive_t = now_d
            if dt > 0 and dt < 0.1 then
                -- 07-24 (Aurora #2): NO player control during the tame
                -- brace/rodeo — the horse fights you, you can't steer it.
                -- 07-24 review: gated on STAGE ONLY — a missing anchor must
                -- never hand the reins back mid-rodeo.
                local rodeo_lock = tame_pinned
                local seat = costume.seat
                local mounting = S.ride_pose_on and seat
                    and (seat.pose_stage == "mountup"
                        or seat.enter ~= nil)
                -- No reins before the vault has handed off to the seated
                -- loop. This is a hard lock, not merely deceleration: the
                -- horse cannot creep while the rider is still climbing on.
                local can_drive = S.ride_pose_on and not rodeo_lock
                    and not mounting and not horse_world_paused()
                local native_wyrm_drive = can_drive and costume.wyrm_kind
                    and costume.wyrm_chassis == "ch223"
                    and C.wyrm_native_controller ~= false
                if not S.ride_pose_on or mounting then
                    costume.cur_speed = 0.0
                end
                -- 08-18 (Aurora): keyboard reins = WASD as well as the
                -- arrows, matching the gamepad stick. Safe while mounted:
                -- the player puppet's FSM is parked, so native WASD
                -- movement never fights the reins (same reason the stick
                -- never did on pad).
                local up = can_drive and (iris_kb(0x26) or iris_kb(0x57))
                local left = can_drive and (iris_kb(0x25) or iris_kb(0x41))
                local right = can_drive and (iris_kb(0x27) or iris_kb(0x44))
                -- CONTROLLER reins (Aurora 07-23), active only while
                -- SEATED: left stick = ride/turn (light tilt walk, full
                -- tilt trot — the doe has no native trot, so trot is just
                -- the middle rung of the speed ladder), B/Circle = gallop
                local stick_x, stick_y, pad_gallop, pad_jump =
                    0.0, 0.0, false, false
                local pad_kick = false
                local pad_bless = false
                -- 08-07 kick button: X/Square = RLeft, value resolved
                -- from the engine's own enum (never guess masks)
                if S.kick_mask == nil then
                    S.kick_mask = 0
                    pcall(function()
                        local bt = sdk.find_type_definition(
                            "via.hid.GamePadButton")
                        local f = bt and bt:get_field("RLeft")
                        S.kick_mask = tonumber(f:get_data(nil)) or 0
                    end)
                    log(string.format(
                        "kick button (X/RLeft) mask resolved: 0x%X",
                        S.kick_mask))
                end
                -- 08-11 blessing button (Aurora: X = kick, Y = blessing):
                -- Y/Triangle = RUp, resolved the same enum way.
                if S.bless_mask == nil then
                    S.bless_mask = 0
                    pcall(function()
                        local bt = sdk.find_type_definition(
                            "via.hid.GamePadButton")
                        local f = bt and bt:get_field("RUp")
                        S.bless_mask = tonumber(f:get_data(nil)) or 0
                    end)
                    log(string.format(
                        "blessing button (Y/RUp) mask resolved: 0x%X",
                        S.bless_mask))
                end
                if can_drive then
                    pcall(function()
                        local hid = sdk.get_native_singleton("via.hid.GamePad")
                        local hid_type = sdk.find_type_definition(
                            "via.hid.GamePad")
                        local device = sdk.call_native_func(
                            hid, hid_type, "get_MergedDevice")
                        if device then
                            local axis = device:call("get_AxisL")
                            if axis then
                                stick_x = tonumber(axis.x) or 0.0
                                stick_y = tonumber(axis.y) or 0.0
                            end
                            local mask = tonumber(
                                device:call("get_Button")) or 0
                            pad_gallop = (mask & 0x40080) ~= 0 -- B/Circle
                            pad_jump = (mask & 0x20020) ~= 0 -- A/Cross
                            pad_kick = S.kick_mask ~= 0
                                and (mask & S.kick_mask) ~= 0 -- X/Square
                            pad_bless = S.bless_mask ~= 0
                                and (mask & S.bless_mask) ~= 0 -- Y/Triangle
                        end
                    end)
                end
                -- HORSE JUMP: Space / A owns one short, deterministic arc.
                -- The player is seat-pinned, so moving only the horse root
                -- keeps horse and rider together and never enters the
                -- player's native falling state.
                local jump_down = can_drive and not native_wyrm_drive
                    and (iris_kb(0x20) or pad_jump)
                -- ⭐ r76 (Aurora: "the horse can jump mid falling"). A body in
                -- the air has nothing to push off. costume.fall_v is non-nil
                -- exactly while r57's gravity owns the body, so it is the
                -- authoritative "am I airborne" flag -- and gating on it also
                -- stops a jump being started during the post-landing clip.
                if jump_down and not costume.jump_latch
                    and not costume.jump
                    and costume.fall_v == nil
                    and ((tonumber(costume.cur_speed) or 0.0) > 0.35
                        -- Terrain protection may have just zeroed cur_speed.
                        -- Forward-held input is still a valid horse take-off;
                        -- without this escape hatch the obstacle guard also
                        -- disabled the one action meant to clear the obstacle.
                        or up or pad_move or pad_gallop
                        or costume.wyrm_kind) then
                    -- a fresh leap cancels any lingering landing-clip hold
                    costume.jump_land_until = nil
                    local jp = ox_tf:call("get_UniversalPosition")
                    local jf = ox_tf:call("get_AxisZ")
                    local speed = tonumber(costume.cur_speed) or 0.0
                    -- THE REAL JUMP CLIP (08-06): if the wild-horses jump pack
                    -- is live (bank 902, Gallop_Jump), the arc stretches to the
                    -- clip's length and the clip rides it -- the animation's own
                    -- baked hip arc carries the rider (seat = spine joint)
                    local jpk = nil
                    pcall(function()
                        local api = rawget(_G, "__iris_wild_horses_api")
                        jpk = api and api.jump_pack and api.jump_pack()
                    end)
                    -- ⭐ 08-18 W3 PER-GAIT JUMPS (work-order, horse only):
                    -- speed-appropriate take-off / air loop / landing from
                    -- the full bank; jpk keeps the r71 field shape so every
                    -- downstream consumer works verbatim. 902 = fallback.
                    if jpk and (not costume.wyrm_kind)
                        and C.w3_jumps_enabled ~= false then
                        pcall(function()
                            local api = rawget(_G, "__iris_wild_horses_api")
                            local w3j = api and api.w3_jump_pack
                                and api.w3_jump_pack()
                            if not w3j then return end
                            local dg = costume.driven_gait or 0
                            local set9 = (dg >= 300 and w3j.gallop)
                                or (dg == 250 and w3j.canter) or w3j.trot
                            jpk = { bank = w3j.bank, jump = set9.start,
                                front = set9.loop, fall = set9.loop,
                                land = set9.land }
                        end)
                    end
                    -- ⭐ 08-13 WYRM MOUNT (Aurora: "the jump has no animation"):
                    -- the horse pack means nothing to a wolf body - the wyrm
                    -- costume brings its own atlas-verified leap. 422 is the launch;
                    -- starting on 423 skipped the take-off and made the wolf point down
                    -- through the ascent as though the jump had begun at its end.
                    if costume.wyrm_kind then
                        jpk = { bank = 0, jump = 422, front = 423, fall = 416, land = 401 }
                    end
                    -- 08-06 round 2 (Aurora: "must clear these fences easily"
                    -- + the log showed gallop jumps launching at speed 4.8):
                    -- snappier arc (1.2s), a REAL minimum lunge regardless of
                    -- current speed, and fence-clearing height (default 1.5)
                    -- ⭐⭐⭐ 08-09 r66 -- BALLISTIC JUMP. (Aurora: "the jump is the
                    -- part that makes this feel like a toy instead of an actual
                    -- horse... maybe we need a better animation or maybe it's
                    -- the jump arc itself but it just feels wrong. The kick
                    -- animation is good though.")
                    -- The clip is NOT the problem -- the kick uses the same
                    -- animation machinery and reads fine. The MODEL was:
                    --   * FIXED DURATION. 1.2s whether the leap was 8m or 45m,
                    --     so distance was bought with SPEED. At a gallop the
                    --     horse covered 15.6m in 1.2s = 13 m/s -- it visibly
                    --     accelerated at take-off and snapped back on landing.
                    --     That speed discontinuity is the single biggest "toy"
                    --     tell; nothing with mass changes pace like that.
                    --   * FIXED HEIGHT. 1.65m apex for every jump regardless.
                    --   * NOT A PARABOLA. The envelope held y FLAT for the
                    --     first 20% and last 14% of the arc and sine-bumped the
                    --     middle -- so the horse slid along the ground, popped
                    --     up, then slid again. Real bodies leave the ground
                    --     immediately and accelerate downward the whole way.
                    -- Now it is genuine projectile motion: you leave at the
                    -- speed you were already travelling (plus a small push-off),
                    -- gravity is the SAME constant r57 uses for falling, and
                    -- DURATION AND DISTANCE ARE DERIVED, not dialled in. A
                    -- gallop jumps far because it is fast, not because a
                    -- different number was substituted.
                    local g_j = tonumber(C.jump_gravity) or 14.0
                    local v0_j = tonumber(C.jump_launch_v) or 7.2
                    local air_j = 2.0 * v0_j / g_j   -- level-landing airtime
                    local dur = jpk and air_j or 0.68
                    local hspeed_j = nil
                    local travel = math.max(0.9,
                        math.min(2.8, speed * 0.55))
                    if jpk then
                        -- 08-06 r3 (Aurora: gallop jump "a LOT further and
                        -- faster, 1.5-2x"): base on the COMMANDED speed (the
                        -- eased value lags the gallop -- the log showed 4.8
                        -- at full B), then overdrive 1.6x: a leap outruns
                        -- the run
                        local jspeed = speed
                        if pad_gallop then
                            jspeed = math.max(jspeed,
                                tonumber(C.speed_dash) or 9.5)
                        elseif up or stick_y > 0.25 then
                            -- 08-07 r11 (Aurora: "boost non-sprinting
                            -- slightly"): 1.35x floor on the run jump
                            jspeed = math.max(jspeed,
                                (tonumber(C.speed_run) or 3.4) * 1.35)
                        end
                        -- r66: distance is now a CONSEQUENCE of the launch, not
                        -- a dialled number. Horizontal speed carries over from
                        -- the gallop (plus a modest push-off), so there is no
                        -- jolt at take-off or landing, and travel falls out of
                        -- speed x airtime. ⛔ The old max(8.0, ...) floor is
                        -- gone deliberately: it made a standing horse leap 8m,
                        -- which is most of what read as "a toy". A small floor
                        -- remains so a walking hop still clears something.
                        hspeed_j = math.max(
                            tonumber(C.jump_min_hspeed) or 3.0,
                            jspeed * (tonumber(C.jump_forward_boost) or 1.25))
                        travel = math.min(45.0, hspeed_j * air_j)
                        -- the PUSH-OFF (08-07 r25, Aurora's pick):
                        -- native event 2308327367 layered with the snort
                        pcall(function()
                            local audio = rawget(_G,
                                "__lyra_horse_custom_audio_api")
                            if not audio then return end
                            if audio.play_event then
                                local okj = audio.play_event(
                                    tonumber(C.jump_start_event)
                                        or 2308327367,
                                    costume.horse_go)
                                log("jump start fx: " .. tostring(okj))
                            end
                            if audio.play_category then
                                audio.play_category("snort",
                                    costume.horse_go)
                            end
                        end)
                    end
                    log(string.format(
                        "ride jump: clip=%s speed=%.1f travel=%.1fm dur=%.2fs",
                        tostring(jpk ~= nil), speed, travel, dur))
                    local ex = jp.x + jf.x * travel
                    local ez = jp.z + jf.z * travel
                    -- r33 (Aurora: "the horse can clip while jumping"):
                    -- wall-check the leap line at chest height (+1.2 --
                    -- jumpable fences pass UNDER the ray, real walls
                    -- don't); scenery ahead shortens the landing to
                    -- just short of the first hit.
                    --
                    -- ⛔⛔ 08-09 r60 -- THE SPACE BUG THIS RAY WAS BORN WITH.
                    -- jp is UNIVERSAL (get_UniversalPosition); the ray rig is
                    -- RENDER. The old code converted Y and left x/z alone,
                    -- i.e. it assumed the x/z offset between the two spaces is
                    -- zero. It is not, and it is not even constant -- it moves
                    -- every time the floating render origin REBASES, which is
                    -- precisely what happens when you ride a long way. The
                    -- warning on route3_ground_below_uni already spells the
                    -- failure out: a universal x/z fed to a render ray gets
                    -- cast somewhere else on the map entirely, and it fails
                    -- SILENTLY and two-faced -- either it finds nothing, or it
                    -- hits unrelated terrain.
                    -- "Finds nothing" is the one Aurora sees: no wall is
                    -- reported, the leap keeps its full 8-45m travel, and the
                    -- horse drives straight through the ledge face -- "goes
                    -- through the ground / disappears".
                    -- Both spaces are readable off the SAME transform, so take
                    -- the offset from the ox itself. Exact, live, no globals,
                    -- and it self-corrects on every rebase.
                    local jr = ox_tf:call("get_Position")
                    local odx, ody, odz = 0.0, 0.0, 0.0
                    if jr then
                        odx = (tonumber(jp.x) or 0.0)
                            - (tonumber(jr.x) or 0.0)
                        ody = (tonumber(jp.y) or 0.0)
                            - (tonumber(jr.y) or 0.0)
                        odz = (tonumber(jp.z) or 0.0)
                            - (tonumber(jr.z) or 0.0)
                    else
                        -- no render read = fall back to the Y-only helper the
                        -- old code used; x/z assumed shared, as before
                        local yoffn = rawget(_G, "route3_y_space_offset")
                        ody = yoffn and tonumber(yoffn()) or 0.0
                    end
                    local face_d = nil
                    pcall(function()
                        local ray = rawget(_G, "route3_ray")
                        local ensure = rawget(_G, "route3_ensure_ray")
                        local mkv = rodeo_vec3   -- r62: was a nil _G fetch
                        if not (ray and ensure and ensure()
                            and mkv) then
                            log("ride jump: wall ray UNAVAILABLE")
                            return
                        end
                        local cy = jp.y - ody + 1.2
                        ray.filter:set_Group(0)
                        ray.filter:set_Layer(2)
                        ray.filter:set_MaskBits(0)
                        ray.result:clear()
                        ray.query:call("setRay(via.vec3, via.vec3)",
                            mkv(jp.x - odx, cy, jp.z - odz),
                            mkv(ex - odx, cy, ez - odz))
                        ray.method:call(ray.system, ray.query,
                            ray.result)
                        if (ray.result:get_NumContactPoints() or 0)
                            <= 0 then
                            return
                        end
                        local contact = ray.result:call(
                            "getContactPoint(System.UInt32)", 0)
                        local pos = contact and sdk.get_native_field(
                            contact, ray.contact_td, "Position")
                        if not pos then return end
                        -- contact comes back in RENDER space: put it back
                        local hx = (pos.x + odx) - jp.x
                        local hz = (pos.z + odz) - jp.z
                        face_d = math.sqrt(hx * hx + hz * hz)
                    end)
                    -- ⭐ r60 THE LEDGE PASS (Aurora: "when you try and jump
                    -- vertically up to say higher ledges"). Until now a face
                    -- was ALWAYS a wall: any obstacle over chest height cut
                    -- the leap to just short of it, so the horse hopped on the
                    -- spot at the base and could never get on top of anything.
                    -- So before writing a face off, look at what is ON it:
                    -- probe the ground just PAST the face, and if that surface
                    -- is above us but still inside the arc's reach, this is a
                    -- ledge we can clear -- keep the full leap and land up
                    -- there. Only a face with nothing reachable on top (a real
                    -- wall, or a rise taller than the horse can jump) still
                    -- shortens the leap.
                    local land_y = jp.y
                    local ledge_top = nil
                    local travel_clamped = false   -- r81: did a wall/ledge shorten it?
                    -- r65: reach was jump_height*0.85 = 1.40m, which is why
                    -- Aurora "just can't get up there at all" on anything
                    -- meaningful -- most real ledges are taller than that, and
                    -- a face out of reach is treated as a plain wall. 2.0m is a
                    -- generous but believable hop for a horse; tune from here.
                    local reach = tonumber(C.jump_ledge_reach) or 2.0
                    if face_d then
                        pcall(function()
                            local ground = rawget(_G,
                                "route3_ground_below_uni")
                            if not ground then return end
                            local px = jp.x + jf.x * (face_d + 1.0)
                            local pz = jp.z + jf.z * (face_d + 1.0)
                            local hit = ground(px,
                                jp.y + reach + 1.0, pz,
                                0.5, reach + 9.0)
                            local ty = hit and tonumber(hit.y)
                            -- > +0.25 so ordinary ground past a thin fence
                            -- reads as "no ledge" and the fence logic is
                            -- untouched; <= reach so a cliff stays a cliff
                            if ty and ty > jp.y + 0.25
                                and ty <= jp.y + reach then
                                -- ⭐⭐⭐ r88 -- IS THERE ANYWHERE TO STAND?
                                -- Aurora's video shows the horse and rider
                                -- CLIMBING A SHEER CLIFF -- jump, land on a
                                -- shelf, jump again, progressively up a vertical
                                -- rock wall, ending with the Arisen clinging to
                                -- the face. Cause: a "ledge" was anything with a
                                -- surface within reach 1m past the wall. A cliff
                                -- with any small shelf 2m up passes that test,
                                -- so every jump found a new one and stair-cased
                                -- the horse up a face it should never touch.
                                -- ⛔ A LEDGE IS A PLATFORM, NOT A FOOTHOLD.
                                -- Probe AGAIN, further past the lip: standing
                                -- room has to CONTINUE at roughly the same
                                -- height. A shelf on a cliff fails (nothing
                                -- there, or the rock keeps climbing), a real
                                -- step or wall-top passes.
                                local px2 = jp.x + jf.x
                                    * (face_d + (tonumber(C.jump_ledge_overshoot)
                                        or 2.5) + 1.0)
                                local pz2 = jp.z + jf.z
                                    * (face_d + (tonumber(C.jump_ledge_overshoot)
                                        or 2.5) + 1.0)
                                local h2 = ground(px2, ty + 1.5, pz2, 0.5, 4.0)
                                local ty2 = h2 and tonumber(h2.y)
                                if ty2 and math.abs(ty2 - ty) <= 0.75 then
                                    ledge_top = ty
                                else
                                    log(string.format(
                                        "ride jump: face at %.1fm has a lip at "
                                        .. "+%.2fm but NO standing room -- wall",
                                        face_d, ty - jp.y))
                                end
                            end
                        end)
                    end
                    if face_d and not ledge_top then
                        -- ⭐ 08-12 (Aurora: "so I can actually jump over this
                        -- fence"): a LOW obstacle is not a wall. Re-cast the
                        -- same ray at APEX height -- if the air is clear up
                        -- there, the arc carries the horse over the top
                        -- (fences, rails, low hedges). Only a face that is
                        -- ALSO solid at apex height still shortens the leap.
                        local clear_above = false
                        pcall(function()
                            local ray = rawget(_G, "route3_ray")
                            local ensure = rawget(_G, "route3_ensure_ray")
                            local mkv = rodeo_vec3
                            if not (ray and ensure and ensure() and mkv) then
                                return
                            end
                            local apex = jp.y - ody
                                + (tonumber(C.jump_height) or 1.65) + 0.25
                            ray.filter:set_Group(0)
                            ray.filter:set_Layer(2)
                            ray.filter:set_MaskBits(0)
                            ray.result:clear()
                            ray.query:call("setRay(via.vec3, via.vec3)",
                                mkv(jp.x - odx, apex, jp.z - odz),
                                mkv(ex - odx, apex, ez - odz))
                            ray.method:call(ray.system, ray.query, ray.result)
                            clear_above =
                                (ray.result:get_NumContactPoints() or 0) <= 0
                        end)
                        if clear_above then
                            log(string.format(
                                "ride jump: low obstacle at %.1fm, apex clear"
                                .. " -- flying over", face_d))
                        else
                            local keep = math.max(0.0, face_d - 1.2)
                            if keep < travel then
                                ex = jp.x + jf.x * keep
                                ez = jp.z + jf.z * keep
                                travel_clamped = true
                                log(string.format(
                                    "ride jump: wall at %.1fm, travel %.1f -> %.1fm",
                                    face_d, travel, keep))
                            end
                        end
                    elseif ledge_top then
                        -- ⭐ r65 (Aurora: "it'll launch you really far onto the
                        -- ledge"). Keeping the FULL leap was the bug: a gallop
                        -- jump is 15.6m and a standing one is still 8m, so
                        -- hopping onto a lip 1.5m away threw the horse 15m
                        -- across whatever was on top. When the goal is to get
                        -- UP onto something, the leap should end just past the
                        -- lip -- so clamp travel to the face plus a small
                        -- landing margin. A ledge further away than the leap
                        -- can reach keeps the full leap (min() handles it).
                        local keep = math.min(travel, face_d
                            + (tonumber(C.jump_ledge_overshoot) or 2.5))
                        ex = jp.x + jf.x * keep
                        ez = jp.z + jf.z * keep
                        travel_clamped = true
                        log(string.format(
                            "ride jump: LEDGE at %.1fm, +%.2fm -- travel %.1f -> %.1fm",
                            face_d, ledge_top - jp.y, travel, keep))
                    end
                    pcall(function()
                        local ground = rawget(_G,
                            "route3_ground_below_uni")
                        local hit = ground and ground(
                            ex, jp.y + 1.5, ez, 2.0, 8.0)
                        if hit and tonumber(hit.y) then
                            land_y = tonumber(hit.y)
                        end
                    end)
                    -- never land BELOW a ledge we committed to clearing
                    if ledge_top and land_y < ledge_top then
                        land_y = ledge_top
                    end
                    -- r66: the clamped horizontal reach. The wall/ledge logic
                    -- above moves ex/ez, so measure the distance it actually
                    -- left us -- the flight advances at hspeed until it hits
                    -- this, then stops moving forward and keeps falling (which
                    -- is what running into a wall mid-leap should look like).
                    -- ⛔⛔ r81 -- "MIDWAY THROUGH THE ARC IT SUDDENLY STOPS AND
                    -- GOES DOWN." Aurora is describing this clamp, and the bug
                    -- is mine: r72's gather delays the VERTICAL clock but not
                    -- the horizontal one, so the horse runs out of horizontal
                    -- travel `gather` seconds BEFORE the arc finishes -- forward
                    -- motion dies instantly and it just drops the rest of the
                    -- way. Not smooth, and it reads as "not far enough".
                    -- ⭐ And the deeper point: this cap only ever existed to stop
                    -- the horse ploughing INTO A WALL. With no wall and no ledge
                    -- there is nothing to clamp to -- the leap should simply fly
                    -- until it lands. So the cap now applies ONLY when the
                    -- wall/ledge pass actually shortened the leap.
                    local maxd_j = 1e9
                    if travel_clamped then
                        maxd_j = math.sqrt((ex - jp.x) * (ex - jp.x)
                            + (ez - jp.z) * (ez - jp.z))
                    end
                    costume.jump = {
                        t0 = now_d, dur = dur,
                        x0 = jp.x, y0 = jp.y, z0 = jp.z,
                        x1 = ex, y1 = land_y, z1 = ez,
                        height = tonumber(C.jump_height)
                            or (jpk and 1.65 or 0.62),   -- 08-06 r5: "a bit too high" at 1.8
                        clip = jpk ~= nil,
                        -- ballistic state (r66)
                        g = g_j, v0 = v0_j,
                        hspeed = hspeed_j or (travel / math.max(0.05, dur)),
                        dirx = jf.x, dirz = jf.z, maxd = maxd_j,
                        clamped = travel_clamped,   -- r83: only snap x/z if a wall defined the end
                        d = 0.0, last_t = now_d,    -- r92: live horizontal integration
                        -- r71 three-phase clip state
                        jbank = jpk and jpk.bank or nil,
                        jstart = jpk and jpk.jump or nil,
                        jfront = jpk and jpk.front or nil,
                        jfall = jpk and jpk.fall or nil,
                        jland = jpk and jpk.land or nil,
                        seq = "start",
                        gather = tonumber(C.jump_gather_secs) or 0.18,
                    }
                    -- ⭐ 08-13 WYRM LEAP SHAPE (Aurora: "doesn't go high enough,
                    -- moves a bit too far forward"): the arc's numbers were the
                    -- horse's fence-clearing tune. Wyrm keys: height up, travel
                    -- reined in; ballistic v0 re-derived so physics agree.
                    if costume.wyrm_kind then
                        local j = costume.jump
                        j.height = tonumber(C.wyrm_jump_height) or 2.2
                        j.g = tonumber(C.wyrm_jump_gravity) or 38.0
                        j.gather = tonumber(C.wyrm_jump_gather_secs) or 0.04
                        j.front_at = now_d + (tonumber(C.wyrm_jump_start_secs) or 0.10)
                        local jt = tonumber(C.wyrm_jump_travel) or 0.7
                        j.x1 = j.x0 + (j.x1 - j.x0) * jt
                        j.z1 = j.z0 + (j.z1 - j.z0) * jt
                        j.hspeed = (tonumber(j.hspeed) or 0) * jt
                        if j.maxd and j.maxd < 1e8 then j.maxd = j.maxd * jt end
                        if tonumber(j.g) and j.g > 0 then
                            j.v0 = math.sqrt(2.0 * j.g * j.height)
                        end
                        -- 08-13 ridden cat voice: a short call on take-off
                        pcall(function()
                            local capi = rawget(_G, "__iris_wild_cats_api")
                            if capi and capi.play
                                and costume.wyrm_kind == "cat" then
                                capi.play("alert", costume.horse_go)
                            end
                        end)
                    end
                    -- ⭐ 08-18 UPHILL COMPENSATION (Aurora: "jumping up a hill
                    -- ... ends early, feels off"): v0 buys C.jump_height of
                    -- apex above the TAKE-OFF point, so when the landing sits
                    -- higher the parabola meets the hill almost immediately
                    -- and the leap reads as a stumble. Add the climb (capped)
                    -- to the launch energy — the arc then clears the slope
                    -- with the same apex margin a flat jump gets, and the
                    -- r92 emergent landing does the rest.
                    if not costume.wyrm_kind then
                        local climb = (tonumber(land_y) or jp.y) - jp.y
                        if climb > 0.05 then
                            local j9 = costume.jump
                            local eff = (tonumber(C.jump_height) or 1.65)
                                + math.min(climb, 2.5)
                            j9.height = eff
                            j9.v0 = math.sqrt(
                                2.0 * (tonumber(j9.g) or 14.0) * eff)
                        end
                    end
                    if jpk then
                        -- ⭐⭐⭐ 08-09 r71 -- THREE-PHASE JUMP, the griffin's shape.
                        -- (Aurora: "the clip isn't good though, it looks
                        -- terrible... unless we just copy the griffin's jump
                        -- CODE anyway with the current animation and see".)
                        -- ⛔ AND THE REASON IT LOOKS TERRIBLE IS NOW CONFIRMED:
                        -- the horse chassis has NO JUMP ANIMATION. Every horse
                        -- atlas -- ch299003/010/011/020/030/031, 129 clips on
                        -- ch299011 alone -- returns ZERO matches for jump. DD2
                        -- horses were never animated to leap. What we play is a
                        -- borrowed clip out of the wild-horses pack (bank 902),
                        -- and it was being TIME-STRETCHED on top of that:
                        -- set_Speed(1.5/dur) ran it ~46% fast against the new
                        -- ballistic airtime. A foreign clip, played wrong.
                        -- The griffin does it properly and its shape is simply
                        -- three clips in sequence rather than one stretched:
                        --   com_jump_start_front -> com_jump_front -> landing.
                        -- We can do the same with what we already own, because
                        -- the pack exposes {jump=1, land=2} and NOBODY HAS EVER
                        -- PLAYED land -- Jump_toIdle has been sitting unused
                        -- since the pack was added.
                        --   phase 1 start = 902/1 at NATURAL speed (no stretch)
                        --   phase 2 air   = bank 0 / 415 com_fall_loop_vertical,
                        --                   the horse's OWN airborne clip
                        --   phase 3 land  = 902/2 Jump_toIdle, finally used
                        -- force_hold owns the layer so the gait selector
                        -- can't stomp the leap mid-air; released after landing
                        costume.force_hold = true
                        costume.cmd_bank, costume.cmd_clip =
                            jpk.bank, jpk.jump
                        costume.jump.air_at = now_d
                            + (tonumber(C.jump_launch_secs) or 0.45)
                        -- r92: natural speed, griffin blend, root motion killed
                        iris_jump_play(costume, jpk.bank, jpk.jump)
                    end
                end
                costume.jump_latch = jump_down
                -- landing-bang retry (r19): posts until the hoof lane
                -- accepts it or tries run out
                if costume.bang_due then
                    local okb = false
                    pcall(function()
                        local audio = rawget(_G,
                            "__lyra_horse_custom_audio_api")
                        if not audio then return end
                        -- (r26: the native impact moved EARLIER, into
                        -- the descent -- only the hoof slam lands here)
                        if audio.play_category then
                            okb = audio.play_category("land",
                                costume.horse_go) == true
                        end
                    end)
                    costume.bang_due.tries =
                        (costume.bang_due.tries or 10) - 1
                    if okb or costume.bang_due.tries <= 0 then
                        log("landing bang: "
                            .. (okb and "played" or "gave up (throttled)"))
                        costume.bang_due = nil
                    end
                end
                -- ⭐ HORSE KICK (08-07 r19, Aurora: "X = a kick using the
                -- buck animation, real damage + knockback/over"): buck
                -- 902:3 played as an ATTACK; at the kick beat a rear-arc
                -- sweep applies damage (the probe's proven applicator,
                -- setHp ladder fallback) + the gust finale's HateSystem
                -- tumble packet (⛔ dd2-knockback law: synthetic
                -- DamageInfo can NEVER launch -- the HateSystem route
                -- makes the victim play its OWN tumble, proven 07-10)
                -- r23 NOSE CALIBRATION: while she's moving, sample the
                -- drive body's actual travel direction -- the horse
                -- never reverses, so this IS nose-forward
                pcall(function()
                    if (tonumber(costume.cur_speed) or 0) > 0.8 then
                        local bgo = valid(costume.ox_go)
                            and costume.ox_go or costume.horse_go
                        local bp = bgo:call("get_Transform")
                            :call("get_Position")
                        local pn = costume.nose_prev
                        if pn then
                            local ndx = bp.x - pn.x
                            local ndz = bp.z - pn.z
                            local nl = math.sqrt(ndx * ndx + ndz * ndz)
                            if nl > 0.05 then
                                costume.nose_dir =
                                    {x = ndx / nl, z = ndz / nl}
                            end
                        end
                        costume.nose_prev = {x = bp.x, z = bp.z}
                    else
                        costume.nose_prev = nil
                    end
                end)
                -- ⭐ 08-13: on a WYRM mount X/Y belong to the beast's own moves
                -- (iris_wyrm_attack_tick) - the horse kick played horse clips
                -- on a wolf ("the Y is doing the horse kick still")
                local kick_down = can_drive and pad_kick
                    and not costume.wyrm_kind
                if kick_down and not S.kick_latch and not costume.kick
                    and not costume.jump then
                    S.kick_latch = true
                    local kpk = nil
                    pcall(function()
                        local api = rawget(_G, "__iris_wild_horses_api")
                        kpk = api and api.jump_pack and api.jump_pack()
                    end)
                    -- ⭐ 08-18 W3 kick (work-order): the real back_kick01
                    -- replaces the 902 buck when the full bank serves. dur/
                    -- hit_at start on the legacy clocks and re-calibrate to
                    -- the actual clip length once the layer reports it.
                    local kw3 = nil
                    pcall(function()
                        local api = rawget(_G, "__iris_wild_horses_api")
                        kw3 = api and api.w3_actions and api.w3_actions()
                    end)
                    if kpk then
                        costume.kick = {
                            t0 = now_d,
                            dur = tonumber(C.kick_secs) or 1.5,
                            hit_at = now_d
                                + (tonumber(C.kick_hit_delay) or 0.55),
                            w3 = kw3 ~= nil,
                            w3_clip = kw3 and kw3.kick or nil,
                        }
                        -- A kick is planted, not a braking gait. Capture the chassis
                        -- position at the press and kill carried locomotion immediately.
                        pcall(function()
                            local base = valid(costume.ox_go)
                                and costume.ox_go or costume.horse_go
                            local p = base:call("get_Transform")
                                :call("get_UniversalPosition")
                            costume.kick.plant_x, costume.kick.plant_z = p.x, p.z
                        end)
                        costume.cur_speed = 0.0
                        costume.idle_anchor = nil
                        costume.force_hold = true
                        local kb9 = kw3 and kw3.bank or kpk.bank
                        local kc9 = kw3 and kw3.kick or kpk.buck
                        costume.cmd_bank, costume.cmd_clip = kb9, kc9
                        pcall(function()
                            local motion = costume.horse_character
                                :call("get_Motion")
                            local layer = motion
                                and motion:call("getLayer", 0)
                            if layer then
                                layer:call(
                                    "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                                    kb9, kc9, 0.0, 0.15, 1, 1)
                                layer:call("set_Speed", 1.0)
                            end
                        end)
                        pcall(function()
                            local audio = rawget(_G,
                                "__lyra_horse_custom_audio_api")
                            if audio and audio.play_category then
                                audio.play_category("alert",
                                    costume.horse_go)
                            end
                        end)
                        log("kick: buck fired")
                        -- r33 AUTO-AIM (Aurora: "autotarget the nearest
                        -- enemy and turn the butt to face it -- only if
                        -- there's an enemy in range"): nearest live
                        -- external character within kick_aim_range;
                        -- the windup then yaws the ox so the tail line
                        -- points at it. No target = kick as-is.
                        pcall(function()
                            local k2 = costume.kick
                            local abase = valid(costume.ox_go)
                                and costume.ox_go or costume.horse_go
                            local apv = abase:call("get_Transform")
                                :call("get_Position")
                            local arange = tonumber(C.kick_aim_range)
                                or 6.0
                            local best, bd2 = nil, arange * arange
                            local skip = {}
                            for _, sgo in ipairs({costume.horse_go,
                                costume.ox_go, player_game_object()}) do
                                if valid(sgo) then
                                    skip[object_address(sgo)] = true
                                end
                            end
                            local smk = sdk.get_native_singleton(
                                "via.SceneManager")
                            local smtk = sdk.find_type_definition(
                                "via.SceneManager")
                            local scn = smk and sdk.call_native_func(
                                smk, smtk, "get_CurrentScene")
                            local chars = scn and scn:call(
                                "findComponents(System.Type)",
                                sdk.typeof("app.Character"))
                            for _, ench in ipairs(
                                chars and chars:get_elements() or {}) do
                                pcall(function()
                                    local ego = ench:call(
                                        "get_GameObject")
                                    if not valid(ego) then return end
                                    if skip[object_address(ego)] then
                                        return
                                    end
                                    local ehc = get_component(ego,
                                        "app.HitController")
                                    local ehp = ehc and tonumber(
                                        ehc:call("get_Hp"))
                                    if ehp ~= nil and ehp <= 0 then
                                        return
                                    end
                                    local epv = ego
                                        :call("get_Transform")
                                        :call("get_Position")
                                    if math.abs(epv.y - apv.y) > 3.0 then
                                        return
                                    end
                                    local dx = epv.x - apv.x
                                    local dz = epv.z - apv.z
                                    local d2 = dx * dx + dz * dz
                                    if d2 < bd2 and d2 > 0.01 then
                                        bd2 = d2
                                        best = ego
                                    end
                                end)
                            end
                            if best then
                                k2.aim_go = best
                                -- Preserve the VIEW'S current world heading,
                                -- including the rider's right-stick orbit. The
                                -- horse is about to yaw its nose away from the
                                -- target so its hind legs face it; the camera
                                -- must not ride that temporary half-turn.
                                local az = abase:call("get_Transform")
                                    :call("get_AxisZ")
                                if az then
                                    k2.cam_yaw = math.atan(az.x, az.z)
                                        + (tonumber(S.mountcam_orbit_yaw) or 0.0)
                                end
                                log(string.format(
                                    "kick aim: target at %.1fm",
                                    math.sqrt(bd2)))
                            end
                        end)
                    end
                end
                if not kick_down then S.kick_latch = false end
                -- 08-11 RIDDEN BLESSING (Aurora: Y casts while riding the
                -- unicorn). The rodeo owns the mounted body's motion, so the
                -- choreography runs HERE (gather at 2x -> thrust) and only the
                -- strike (circle + party heal) is delegated to the wild-horses
                -- API. Mirrors the kick's shape: latch, planted reins, phases.
                local bless_down = can_drive and pad_bless
                    and not costume.wyrm_kind
                if bless_down and not S.bless_latch and not costume.kick
                    and not costume.jump and not costume.bless then
                    S.bless_latch = true
                    pcall(function()
                        local api = rawget(_G, "__iris_wild_horses_api")
                        local rpk = api and api.ritual_pack
                            and api.ritual_pack()
                        local isu = api and api.is_unicorn
                            and api.is_unicorn(costume.horse_go)
                        if not rpk then
                            log("blessing (ridden): ritual pack not loaded")
                            return
                        end
                        if not isu then
                            log("blessing (ridden): mount is not a unicorn")
                            return
                        end
                        local ready, remaining = nil, nil
                        if api.blessing_ready then
                            ready, remaining = api.blessing_ready(
                                costume.horse_go, 89)
                        end
                        if ready ~= true then
                            log(string.format(
                                "blessing (ridden): cooling down (%.0fs left)",
                                tonumber(remaining) or 0.0))
                            return
                        end
                        -- ⭐ 08-18 W3 choreography (work-order): eating_start
                        -- = the reverent bow-down gather, rearing01 = the
                        -- strike at the apex. Phases are frame-driven with
                        -- the old wall clocks demoted to watchdogs.
                        local w3a = api.w3_actions and api.w3_actions()
                        local use_w3 = w3a and w3a.ritual
                        if use_w3 then
                            costume.bless = {
                                w3 = true, t0 = now_d,
                                strike_frac = tonumber(w3a.strike_frac) or 0.45,
                                gather_end = now_d + 2.4,   -- watchdog only
                                strike_at = now_d + 4.2,    -- watchdog only
                                ends_at = now_d + 7.0,      -- watchdog only
                                thrust = false, struck = false,
                            }
                            costume.force_hold = true
                            costume.cmd_bank, costume.cmd_clip =
                                w3a.bank, w3a.eat_start
                            local motion = costume.horse_character
                                :call("get_Motion")
                            local layer = motion
                                and motion:call("getLayer", 0)
                            if layer then
                                layer:call(
                                    "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                                    w3a.bank, w3a.eat_start, 0.0, 0.15, 1, 1)
                                layer:call("set_Speed", 1.0)
                            end
                            log("blessing (ridden): W3 gather bow")
                            return
                        end
                        costume.bless = {
                            gather_end = now_d + 1.7,
                            strike_at = now_d + 2.3,
                            ends_at = now_d + 3.0,
                            thrust = false, struck = false,
                        }
                        costume.force_hold = true
                        costume.cmd_bank, costume.cmd_clip =
                            rpk.bank, rpk.gather
                        local motion = costume.horse_character
                            :call("get_Motion")
                        local layer = motion
                            and motion:call("getLayer", 0)
                        if layer then
                            layer:call(
                                "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                                rpk.bank, rpk.gather, 0.0, 0.15, 1, 1)
                            -- 2x: "the initial idle should be half the length"
                            layer:call("set_Speed", 2.0)
                        end
                        log("blessing (ridden): gather")
                    end)
                end
                if not bless_down then S.bless_latch = false end
                if costume.bless then
                    -- planted: no reins while the ritual plays out
                    up, left, right = false, false, false
                    stick_x, stick_y = 0.0, 0.0
                    pad_gallop = false
                    local bl = costume.bless
                    -- 08-18 W3 phases are frame-driven; sample the layer once
                    -- per tick. ⛔ Reads inside the first 0.4s of any phase
                    -- report the OUTGOING clip (reviewer #3) — every frame
                    -- condition below carries a time guard for exactly that.
                    local bfr, bef, bbank, bid = nil, nil, nil, nil
                    if bl.w3 then
                        pcall(function()
                            local motion = costume.horse_character
                                :call("get_Motion")
                            local layer = motion
                                and motion:call("getLayer", 0)
                            if not layer then return end
                            bfr = tonumber(layer:call("get_Frame"))
                            bef = tonumber(layer:call("get_EndFrame"))
                            bbank = tonumber(layer:call("get_MotionBankID"))
                            bid = tonumber(layer:call("get_MotionID"))
                        end)
                    end
                    local gather_done = now_d >= bl.gather_end
                    if bl.w3 and not gather_done then
                        local t9 = now_d - (bl.t0 or now_d)
                        gather_done = t9 > 0.4 and bbank == 901 and bid == 19
                            and bfr and bef and bef > 2 and bfr >= bef - 4
                    end
                    if not bl.thrust and gather_done then
                        bl.thrust = true
                        bl.thrust_t0 = now_d
                        pcall(function()
                            local api = rawget(_G, "__iris_wild_horses_api")
                            if bl.w3 then
                                local w3a = api and api.w3_actions
                                    and api.w3_actions()
                                if not w3a then return end
                                costume.cmd_bank, costume.cmd_clip =
                                    w3a.bank, w3a.rear
                                local motion = costume.horse_character
                                    :call("get_Motion")
                                local layer = motion
                                    and motion:call("getLayer", 0)
                                if layer then
                                    layer:call(
                                        "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                                        w3a.bank, w3a.rear, 0.0, 0.15, 1, 1)
                                    layer:call("set_Speed", 1.0)
                                end
                                log("blessing (ridden): W3 rear")
                                return
                            end
                            local rpk = api and api.ritual_pack()
                            if not rpk then return end
                            costume.cmd_bank, costume.cmd_clip =
                                rpk.bank, rpk.thrust
                            local motion = costume.horse_character
                                :call("get_Motion")
                            local layer = motion
                                and motion:call("getLayer", 0)
                            if layer then
                                layer:call(
                                    "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                                    rpk.bank, rpk.thrust, 0.0, 0.15, 1, 1)
                                layer:call("set_Speed", 1.0)
                            end
                            log("blessing (ridden): thrust")
                        end)
                    end
                    local strike_ok = now_d >= bl.strike_at
                    if bl.w3 then
                        -- strike at the rearing APEX: a fraction of the rear
                        -- clip, never while the layer still shows the bow
                        local tt9 = now_d - (bl.thrust_t0 or now_d)
                        strike_ok = bl.thrust and ((tt9 > 0.3 and bbank == 901
                            and bid == 18 and bfr and bef and bef > 4
                            and bfr < bef - 2
                            and bfr >= bef * math.max(0.1, math.min(0.9,
                                tonumber(bl.strike_frac) or 0.45)))
                            or tt9 > 1.6)
                    end
                    if not bl.struck and strike_ok then
                        bl.struck = true
                        pcall(function()
                            local api = rawget(_G, "__iris_wild_horses_api")
                            local healed = api and api.blessing_strike
                                and api.blessing_strike(costume.horse_go, 89)
                            log("blessing (ridden): strike -- healed "
                                .. tostring(healed))
                        end)
                        pcall(function()
                            local audio = rawget(_G,
                                "__lyra_horse_custom_audio_api")
                            if audio and audio.play_category then
                                audio.play_category("nicker",
                                    costume.horse_go)
                            end
                        end)
                    end
                    local bless_over = now_d >= bl.ends_at
                    if bl.w3 and not bless_over then
                        -- end when the rear clip finishes (post-strike)
                        local tt9 = now_d - (bl.thrust_t0 or bl.t0 or now_d)
                        bless_over = bl.struck and bl.thrust and tt9 > 0.5
                            and bbank == 901 and bid == 18
                            and bfr and bef and bef > 2 and bfr >= bef - 3
                    end
                    if bless_over then
                        costume.bless = nil
                        costume.force_hold = false
                        costume.cmd_bank, costume.cmd_clip = nil, nil
                    end
                end
                if costume.kick then
                    -- planted: no reins while the kick plays out
                    up, left, right = false, false, false
                    stick_x, stick_y = 0.0, 0.0
                    pad_gallop = false
                    local k = costume.kick
                    -- Absorb native physics/root-motion drift for the complete buck.
                    -- Rotation remains free so butt auto-aim can still turn in place.
                    if k.plant_x and k.plant_z then
                        pcall(function()
                            local base = valid(costume.ox_go)
                                and costume.ox_go or costume.horse_go
                            local tf = base:call("get_Transform")
                            local p = tf:call("get_UniversalPosition")
                            p.x, p.z = k.plant_x, k.plant_z
                            tf:call("set_UniversalPosition", p)
                        end)
                    end
                    -- r33 BUTT-AIM: during the windup, yaw the ox (the
                    -- axis authority, r22) so the TAIL faces the
                    -- target. Absolute-yaw ease -- self-consistent
                    -- with the AxisZ decomposition, no quaternion
                    -- sign guessing.
                    if k.aim_go and not k.hit_done then
                        pcall(function()
                            if not valid(k.aim_go) then
                                k.aim_go = nil
                                return
                            end
                            local otf = costume.ox_go
                                :call("get_Transform")
                            local opv = otf:call("get_Position")
                            local tpv = k.aim_go
                                :call("get_Transform")
                                :call("get_Position")
                            -- nose AWAY from the enemy = butt at it
                            local dxa = opv.x - tpv.x
                            local dza = opv.z - tpv.z
                            if dxa * dxa + dza * dza < 0.0025 then
                                return
                            end
                            local want = math.atan(dxa, dza)
                            local az = otf:call("get_AxisZ")
                            local have = math.atan(az.x, az.z)
                            local diff = want - have
                            while diff > math.pi do
                                diff = diff - 2.0 * math.pi
                            end
                            while diff < -math.pi do
                                diff = diff + 2.0 * math.pi
                            end
                            local step = math.rad(tonumber(
                                C.kick_aim_rate) or 400.0) * dt
                            if diff > step then diff = step
                            elseif diff < -step then diff = -step end
                            local yaw = have + diff
                            local rot = otf:call("get_Rotation")
                            local hy = yaw * 0.5
                            rot.x, rot.y, rot.z, rot.w =
                                0.0, math.sin(hy), 0.0, math.cos(hy)
                            otf:call("set_Rotation", rot)
                        end)
                    end
                    -- 08-18 W3 kick calibration: sync dur/hit to the REAL
                    -- clip length once the layer reports it. ⛔ Deferred a
                    -- beat on purpose — a same-tick get_EndFrame read
                    -- returns the OUTGOING clip's frames (reviewer #3).
                    if k.w3 and not k.calibrated and now_d - k.t0 > 0.25 then
                        pcall(function()
                            local motion = costume.horse_character
                                :call("get_Motion")
                            local layer = motion
                                and motion:call("getLayer", 0)
                            if not layer then return end
                            local bid = tonumber(
                                layer:call("get_MotionBankID"))
                            local mid = tonumber(layer:call("get_MotionID"))
                            if bid ~= 901 or mid ~= k.w3_clip then return end
                            local endf = tonumber(
                                layer:call("get_EndFrame")) or 0
                            if endf <= 4 then return end
                            k.calibrated = true
                            local secs = endf / 60.0
                            k.dur = secs + 0.15
                            local frac = math.max(0.15, math.min(0.85,
                                tonumber(C.kick_hit_frac) or 0.4))
                            local want = k.t0 + secs * frac
                            if not k.hit_done and want > now_d then
                                k.hit_at = want
                            end
                        end)
                    end
                    if not k.hit_done and now_d >= k.hit_at then
                        k.hit_done = true
                        -- r32: SHELL STRIKE REMOVED (Aurora: the buffet
                        -- cast reads as a LIGHTNING STRIKE -- the "Golem
                        -- foot slam" citation was wrong; Golem actually
                        -- fires the LEVIN spell shell. Shells carry
                        -- their baked VFX, so no shell for a plain
                        -- kick). The r24 hybrid fling below is THE
                        -- launch route.
                        -- r29 (Aurora: "the thud should only play if
                        -- something gets hit"): all impact audio moved
                        -- BELOW the sweep, gated on struck > 0
                        local struck, flungn = 0, 0
                        pcall(function()
                            -- r22 (Aurora: fling went TOWARD the horse):
                            -- the SHELL's AxisZ is 180 off -- the OX is
                            -- the axis authority (the jump's proven
                            -- forward). Aimed backwards, the 12m arc
                            -- flung goblins INTO the horse body = jammed
                            -- standing = every r21 symptom at once.
                            local base_go = valid(costume.ox_go)
                                and costume.ox_go or costume.horse_go
                            local htf = base_go:call("get_Transform")
                            local hpv = htf:call("get_Position")
                            -- r23 SELF-CALIBRATED FORWARD: transform Z
                            -- conventions (shell vs ox vs chassis) have
                            -- burned three rounds. The horse only ever
                            -- MOVES nose-first, so the ride's own
                            -- motion is the forward truth (costume.
                            -- nose_dir, sampled while she walks). AxisZ
                            -- is only the cold-start fallback.
                            local hfw = costume.nose_dir
                            if k.aim_go or not hfw then
                                -- r33: aimed kick = we own the yaw, so
                                -- the live axis IS the truth (nose_dir
                                -- is stale after an in-place butt-turn)
                                local az = htf:call("get_AxisZ")
                                hfw = {x = az.x, z = az.z}
                            end
                            log(string.format(
                                "kick dir: fwd=%.2f,%.2f calibrated=%s",
                                hfw.x, hfw.z,
                                tostring(costume.nose_dir ~= nil)))
                            -- the strike zone: a circle around a point
                            -- 1.6m BEHIND her (the hooves' reach)
                            local rxp = hpv.x - hfw.x * 1.6
                            local rzp = hpv.z - hfw.z * 1.6
                            local range = tonumber(C.kick_range) or 3.0
                            local r2k = range * range
                            local dmgk = tonumber(C.kick_damage) or 180.0
                            local skip = {}
                            for _, sgo in ipairs({costume.horse_go,
                                costume.ox_go, player_game_object()}) do
                                if valid(sgo) then
                                    skip[object_address(sgo)] = true
                                end
                            end
                            local dmg_fn = rawget(_G,
                                "griffin_apply_attack_damage")
                            local smk = sdk.get_native_singleton(
                                "via.SceneManager")
                            local smtk = sdk.find_type_definition(
                                "via.SceneManager")
                            local scn = smk and sdk.call_native_func(
                                smk, smtk, "get_CurrentScene")
                            local chars = scn and scn:call(
                                "findComponents(System.Type)",
                                sdk.typeof("app.Character"))
                            for _, ench in ipairs(
                                chars and chars:get_elements() or {}) do
                                pcall(function()
                                    local ego = ench:call("get_GameObject")
                                    if not valid(ego) then return end
                                    if skip[object_address(ego)] then
                                        return
                                    end
                                    local ehp = nil
                                    pcall(function()
                                        ehp = tonumber(
                                            ench:call("get_Hp"))
                                    end)
                                    if ehp ~= nil and ehp <= 0 then
                                        return
                                    end
                                    local epv = ego:call("get_Transform")
                                        :call("get_Position")
                                    local dxk = epv.x - rxp
                                    local dzk = epv.z - rzp
                                    if dxk * dxk + dzk * dzk > r2k then
                                        return
                                    end
                                    if math.abs(epv.y - hpv.y) > 3.0 then
                                        return
                                    end
                                    -- ⭐ r20 REAL LAUNCH (Aurora: the
                                    -- tumble packet read as "very fake
                                    -- ... appears slightly further away"
                                    -- -- wants the warrior-greatsword
                                    -- send): the gust finale's FULL
                                    -- hybrid fling -- forced ragdoll +
                                    -- airborne flail clip + ballistic
                                    -- arc, flight driven and restored by
                                    -- the probe's own blown-tick (runs
                                    -- unconditionally in its frame
                                    -- loop). Fling FIRST, damage after
                                    -- (the gust law: corpses can't fly).
                                    -- r32: HEAVENWARD REPLAY REMOVED --
                                    -- r27 captured the real Sunder
                                    -- packet, r30 proved damageProc
                                    -- silently NO-OPs foreign packets
                                    -- (hp unchanged x6). ⛔ CLOSED.
                                    -- ⭐ r24 SELF-CONTAINED FLING
                                    -- (the kick's launch route): the
                                    -- gust recipe owned by the rodeo --
                                    -- ragdoll + flail + ballistic arc +
                                    -- blackout, ticked at render time,
                                    -- damage by plain setHp mid-air.
                                    -- ⭐ 08-09 r66 HEAVY THINGS DO NOT FLY.
                                    -- (Aurora: "the kick knocks back the cyclops
                                    -- which is hilarious but unrealistic, can we
                                    -- have the knockback only affect small
                                    -- enemies".) Chassis ids below are READ from
                                    -- the Bestiary mod's own per-enemy files --
                                    -- ch250 Cyclops, ch251 Ogre, ch252 Golem,
                                    -- ch253 Griffin/Sphinx, ch254 Chimera,
                                    -- ch255 Medusa, ch256 Minotaur, ch257 Drake,
                                    -- ch258 Dragon, ch260 Garm/Warg, ch226
                                    -- Skeleton Lord, ch229 Dullahan -- not
                                    -- guessed. A BLOCKLIST, not an allow-list,
                                    -- so unknown small fry keep flying (that
                                    -- part is fun and reads fine).
                                    -- ⛔ Damage is unaffected -- a cyclops still
                                    -- takes the kick, it just does not sail.
                                    local heavy = false
                                    pcall(function()
                                        -- ⭐ 08-14 (Aurora: "the horse knockback shouldn't
                                        -- affect large creatures like oxen"). ch299003 is the
                                        -- ox band -- _A the milkable cows, _B the bull, and the
                                        -- prefix match covers both (IrisSpecies.lua:21,64). It
                                        -- is the one piece of LIVESTOCK heavy enough that being
                                        -- punted reads as a bug rather than as comedy; the small
                                        -- fry deliberately keep flying.
                                        -- ⚠ To spare another species later, add its chassis
                                        -- here -- one string, nothing else. Horses (ch299011) and
                                        -- stags (ch299010) are deliberately still flingable.
                                        local en = tostring(ego:call("get_Name") or "")
                                        for _, hid in ipairs({"ch226", "ch229",
                                            "ch250", "ch251", "ch252", "ch253",
                                            "ch254", "ch255", "ch256", "ch257",
                                            "ch258", "ch260", "ch299003"}) do
                                            if en:find(hid, 1, true) then
                                                heavy = true; break
                                            end
                                        end
                                    end)
                                    if heavy then
                                        -- ⛔ damage normally rides the FLIGHT
                                        -- (applied in kick_flights_tick when it
                                        -- lands), so skipping the fling would
                                        -- silently skip the hit too. Deal it
                                        -- here instead -- same amount, same
                                        -- applicator, just no ragdoll.
                                        local hit_ok = false
                                        pcall(function()
                                            if dmg_fn then
                                                hit_ok = dmg_fn(ench, dmgk) == true
                                            end
                                            if not hit_ok then
                                                local hhc = get_component(ego,
                                                    "app.HitPointController")
                                                local ch2 = hhc and tonumber(
                                                    hhc:call("get_Hp"))
                                                if ch2 and ch2 > 0 then
                                                    hhc:call(
                                                        "setHp(System.Single, System.Boolean, System.Int32)",
                                                        math.max(0.0, ch2 - dmgk),
                                                        true, 0)
                                                    hit_ok = true
                                                end
                                            end
                                        end)
                                        log("kick: heavy target -- damage "
                                            .. (hit_ok and "dealt" or "FAILED")
                                            .. ", no fling")
                                    else
                                    local fl = {
                                        ch = ench, go = ego,
                                        -- r33 DAMAGE FIX: app.Character
                                        -- has NO get_HitController
                                        -- getter (r28's "no victim HC"
                                        -- x5) -- the tick's damage
                                        -- pcall died on it and setHp
                                        -- NEVER ran. Resolve the HC as
                                        -- a COMPONENT here, on the
                                        -- ground, once.
                                        hc = get_component(ego,
                                            "app.HitController"),
                                        t0 = now_d,
                                        -- r32 Heavenward-feel defaults:
                                        -- up 8 with the tick's grav 14
                                        -- = ~2.3m apex (was 5 = a 0.9m
                                        -- shove), 1.0s of carry
                                        dur = tonumber(
                                            C.kick_fling_secs) or 1.0,
                                        disabled = {},
                                    }
                                    local p0 = ego:call("get_Transform")
                                        :call("get_UniversalPosition")
                                    fl.x0 = tonumber(p0.x)
                                    fl.y0 = tonumber(p0.y)
                                    fl.z0 = tonumber(p0.z)
                                    local fdist = tonumber(
                                        C.kick_fling_dist) or 8.0
                                    -- r33 (Aurora: "the direction of
                                    -- the knockback isn't always
                                    -- right"): fling RADIALLY along
                                    -- horse->victim, not the tail
                                    -- line -- a side-clipped victim
                                    -- flies away from the horse, never
                                    -- sideways-wrong
                                    local rdx, rdz = -hfw.x, -hfw.z
                                    local ddx = epv.x - hpv.x
                                    local ddz = epv.z - hpv.z
                                    local ddl = math.sqrt(
                                        ddx * ddx + ddz * ddz)
                                    if ddl > 0.05 then
                                        rdx, rdz = ddx / ddl, ddz / ddl
                                    end
                                    fl.vx = rdx * fdist / fl.dur
                                    fl.vz = rdz * fdist / fl.dur
                                    fl.vy = tonumber(C.kick_fling_up)
                                        or 8.0
                                    -- blackout: AI + ground glue (gust
                                    -- law: with these live the arc
                                    -- flattens to "iceskating")
                                    for _, tn in ipairs({
                                        "app.AIDecisionMaker",
                                        "app.NavigationAI",
                                        "app.GroundFixer",
                                        "via.physics.CharacterController",
                                    }) do
                                        local ccx = get_component(ego, tn)
                                        if ccx then
                                            pcall(function()
                                                ccx:call("set_Enabled",
                                                    false)
                                                fl.disabled[
                                                    #fl.disabled + 1] =
                                                    ccx
                                            end)
                                        end
                                    end
                                    -- limp: forced ragdoll + recorded
                                    -- throw state + the flail clip
                                    -- (bank 10 clip 500, the Arisen-
                                    -- throw tape)
                                    pcall(function()
                                        ench:call(
                                            "set_IsForceEnableRagdoll",
                                            true)
                                        fl.ragdolled = true
                                    end)
                                    pcall(function()
                                        local rt =
                                            sdk.find_type_definition(
                                                "via.dynamics.Ragdoll")
                                            :get_runtime_type()
                                        local rd = ego:call(
                                            "getComponent(System.Type)",
                                            rt)
                                        if rd then
                                            rd:call(
                                                "set_RagdollStateName(System.String)",
                                                "dmg_throw_action")
                                        end
                                    end)
                                    fl.rag_pause_at = now_d + 0.4
                                    pcall(function()
                                        local mo = ench:call("get_Motion")
                                        local ly = mo and mo:call(
                                            "getLayer", 0)
                                        if ly then
                                            mo:call("set_PlaySpeed", 1.0)
                                            mo:call("set_PlayState", 0)
                                            ly:call(
                                                "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                                                10, 500, 0.0, 8.0, 1, 1)
                                        end
                                    end)
                                    S.kick_flights =
                                        S.kick_flights or {}
                                    S.kick_flights[
                                        #S.kick_flights + 1] = fl
                                    flungn = flungn + 1
                                    end -- r66 heavy gate
                                    struck = struck + 1
                                end)
                            end
                        end)
                        log(string.format(
                            "kick: struck %d (flung %d, tumble %d)",
                            struck, flungn, struck - flungn))
                        if struck > 0 then
                            -- MEAT impact + hoof slam, HITS ONLY (r29)
                            pcall(function()
                                local audio = rawget(_G,
                                    "__lyra_horse_custom_audio_api")
                                if not audio then return end
                                if audio.play_event then
                                    local okfx = audio.play_event(
                                        tonumber(C.kick_hit_event)
                                            or 2034376889,
                                        costume.horse_go)
                                    log("kick impact fx: "
                                        .. tostring(okfx))
                                end
                                if audio.play_category then
                                    audio.play_category("land",
                                        costume.horse_go)
                                end
                            end)
                            -- double hoof-slam: second bang 80ms later
                            k.hit2_at = now_d + 0.08
                        end
                    end
                    if k.hit2_at and now_d >= k.hit2_at then
                        k.hit2_at = nil
                        pcall(function()
                            local audio = rawget(_G,
                                "__lyra_horse_custom_audio_api")
                            if audio and audio.play_category then
                                audio.play_category("land",
                                    costume.horse_go)
                            end
                        end)
                    end
                    if now_d >= k.t0 + k.dur then
                        if k.cam_yaw then
                            S.mountcam_kick_release = {
                                yaw = k.cam_yaw,
                                look = k.cam_look,
                                t0 = now_d,
                                dur = tonumber(C.kick_camera_blend_s) or 0.65,
                            }
                        end
                        costume.kick = nil
                        costume.force_hold = nil
                        costume.last_gait = nil
                    end
                end
                -- Native ch223 propulsion/terrain begins here.  Everything in
                -- the `else` arm is the former transform driver, preserved as
                -- an immediate fallback for the live checkbox.
                local native_driven = native_wyrm_drive
                    and iris_wyrm_native_controller_tick(costume, now_d, dt, {
                        can_drive = can_drive, up = up, left = left, right = right,
                        stick_x = stick_x, stick_y = stick_y,
                        pad_move = stick_y > 0.25,
                        pad_gallop = pad_gallop, pad_jump = pad_jump,
                    })
                if not native_driven then
                local pad_move = stick_y > 0.25
                local pad_turn = 0
                if stick_x > 0.3 then pad_turn = 1
                elseif stick_x < -0.3 then pad_turn = -1 end
                local any_input = up or left or right or pad_move
                    or pad_turn ~= 0 or pad_gallop
                if any_input and costume.force_hold
                    and not costume.jump and not costume.kick
                    and not costume.bless
                    and not S.wyrm_atk_until
                    and not costume.hit_react_hold then
                    -- grabbing the reins releases any force-hold test clip
                    costume.force_hold = nil
                    costume.last_gait = nil
                end
                -- ⭐⭐ 08-09 r65 THE TURNING CIRCLE (Aurora: "you can go left/right
                -- very quickly and it feels unruly... in driving games that's
                -- called a turning circle right? We need to make it a bit
                -- heavier"). Three things were wrong, and they compounded:
                --   1. RATE: a flat 110 deg/s. That is a horse pirouetting.
                --   2. BINARY: pad_turn is +-1 the instant the stick passes 0.3,
                --      so there was no such thing as a gentle steer -- every
                --      input was a full-lock input.
                --   3. INSTANT: no easing in or out, so the yaw snapped on and
                --      off with the key. That snap is most of the "unruly".
                -- Now: analogue off the stick, eased toward the target (the
                -- weight), and the rate FALLS OFF WITH SPEED -- which is what a
                -- turning circle actually is. A walk still turns tightly; a
                -- gallop has to commit to a wide arc.
                local turn_in = (right and 1.0 or 0.0) - (left and 1.0 or 0.0)
                if turn_in == 0.0 and math.abs(stick_x) > 0.15 then
                    -- rescale past the deadzone so small pushes stay small
                    turn_in = (math.abs(stick_x) - 0.15) / 0.85
                    if stick_x < 0 then turn_in = -turn_in end
                    if turn_in > 1.0 then turn_in = 1.0
                    elseif turn_in < -1.0 then turn_in = -1.0 end
                end
                if costume.jump or costume.kick then turn_in = 0 end   -- committed: no steering
                -- r92 LANDING SETTLE: the griffin locks movement while its land
                -- clip plays. Brake rather than freeze -- a hard stop reads as a
                -- snag, a brake reads as absorbing the impact.
                if costume.jump_settle_until
                    and now_d < costume.jump_settle_until then
                    turn_in = 0
                    costume.cur_speed = math.max(0.0,
                        (tonumber(costume.cur_speed) or 0.0) - dt * 6.0)
                elseif costume.jump_settle_until then
                    costume.jump_settle_until = nil
                end
                -- the WEIGHT: first-order lag toward the requested lock
                local lag = math.max(0.01, tonumber(C.turn_lag_secs) or 0.35)
                local te = tonumber(costume.turn_ease) or 0.0
                te = te + (turn_in - te) * math.min(1.0, dt / lag)
                if math.abs(te) < 0.001 then te = 0.0 end
                costume.turn_ease = te
                local turn = te
                -- 08-18: the gait-issue block (a later scope) needs the live
                -- steering value for the stationary turn-in-place clips
                costume.turn_input = te
                if turn ~= 0 and not costume.wyrm_kind then
                    -- speed falloff: at a standstill you get the full rate, at a
                    -- flat gallop only (1 - falloff) of it
                    local dash_s2 = math.max(0.1, tonumber(C.speed_dash) or 9.5)
                    local sfrac = math.max(0.0, math.min(1.0,
                        (tonumber(costume.cur_speed) or 0.0) / dash_s2))
                    local rate = (tonumber(C.turn_rate_deg) or 70.0)
                        * (1.0 - sfrac * (tonumber(C.turn_speed_falloff) or 0.40))
                    local rot = ox_tf:call("get_Rotation")
                    local half = math.rad(-turn * rate * dt) * 0.5
                    local sy, cy = math.sin(half), math.cos(half)
                    local qx = rot.x * cy - rot.z * sy
                    local qy = rot.w * sy + rot.y * cy
                    local qz = rot.x * sy + rot.z * cy
                    local qw = rot.w * cy - rot.y * sy
                    rot.x, rot.y, rot.z, rot.w = qx, qy, qz, qw
                    ox_tf:call("set_Rotation", rot)
                end
                -- ⭐ 08-13 WYRM VEER (Aurora: "moves forward but also goes sideways"):
                -- the wolf/cat loop clips carry root YAW as well as lateral root motion.
                -- The LateUpdate drift cancel removes the sideways slide, but yaw rotates
                -- the forward axis itself - a slow curve reads as "forward" every frame
                -- and survives the cancel. Steering only writes rotation while turning,
                -- so while driving STRAIGHT nothing owned the heading. Wyrm only: latch
                -- the commanded heading whenever turning or stopped, re-assert it every
                -- straight moving frame. Horse clips are yaw-clean and stay untouched.
                if costume.wyrm_kind then
                    -- ⭐ 08-13 v5 FULL YAW OWNERSHIP (Aurora: "rotate isn't going far
                    -- enough" + forward slows in turns): the latch couldn't tell
                    -- steering from clip root yaw, so root yaw BIASED every turn.
                    -- Now the drive owns heading as a NUMBER: steering moves the
                    -- number, the body is set from it every tick - the same exact
                    -- ownership the translation got in v4. Root yaw is orphaned.
                    local hy = costume.wyrm_yaw
                    if not hy then
                        local az5 = ox_tf:call("get_AxisZ")
                        hy = math.atan(az5.x, az5.z)
                    end
                    if turn ~= 0 then
                        local dash5 = math.max(0.1, tonumber(C.speed_dash) or 9.5)
                        local sfrac5 = math.max(0.0, math.min(1.0,
                            (tonumber(costume.cur_speed) or 0.0) / dash5))
                        local rate5 = (tonumber(C.wyrm_turn_rate) or 110.0)
                            * (1.0 - sfrac5 * (tonumber(C.turn_speed_falloff) or 0.40))
                        hy = hy + math.rad(-turn * rate5 * dt)
                    end
                    costume.wyrm_yaw = hy
                    local rot5 = ox_tf:call("get_Rotation")
                    rot5.x, rot5.y, rot5.z, rot5.w =
                        0.0, math.sin(hy * 0.5), 0.0, math.cos(hy * 0.5)
                    ox_tf:call("set_Rotation", rot5)
                end
                -- commanded gait + target speed from input
                -- ⭐ 08-18 GAIT LADDER v2 (Aurora field: v1 read as "2 speeds"
                -- because taps only counted once the stick already commanded
                -- trot). v2 = TAP/HOLD HYBRID with an absolute tier:
                --   HOLD B (>=0.28s)  = gallop, exactly the classic feel;
                --   TAP B             = +1 gait from wherever you are
                --                       (walk>trot>canter>gallop);
                --   stick release     = ladder resets.
                -- Toggle off = pure hold-B. Wyrms keep their own Sprint.
                local ladder_on = (not costume.wyrm_kind)
                    and C.gait_ladder_enabled ~= false
                local stick_mag9 = math.sqrt(
                    stick_x * stick_x + stick_y * stick_y)
                local boost_btn = pad_gallop or (up and iris_kb(0x10))
                if ladder_on then
                    if boost_btn then
                        if not S.gait_b_t0 then S.gait_b_t0 = now_d end
                        if (now_d - S.gait_b_t0) >= 0.28 then
                            costume.gait_hold_gallop = true
                        end
                    else
                        if S.gait_b_t0 and not costume.gait_hold_gallop then
                            costume.gait_boost =
                                math.min(3, (costume.gait_boost or 0) + 1)
                        end
                        S.gait_b_t0 = nil
                        costume.gait_hold_gallop = nil
                    end
                    if not (up or (pad_move and stick_mag9 >= 0.42)) then
                        costume.gait_boost = 0
                    end
                else
                    costume.gait_boost = 0
                    costume.gait_hold_gallop = nil
                    S.gait_b_t0 = nil
                end
                local target_speed, gait = 0.0, 0
                if up or pad_move or pad_gallop then
                    target_speed, gait = (C.speed_run or 3.4), 200
                    if (not ladder_on) and (pad_gallop
                        or (up and iris_kb(0x10))) then
                        target_speed, gait = (C.speed_dash or 9.5), 300
                    elseif up and iris_kb(0x11) then
                        target_speed, gait = (C.speed_walk or 1.6), 100
                    elseif pad_move and not up and not costume.wyrm_kind
                        and (ladder_on and stick_mag9 or stick_y) < 0.85 then
                        target_speed, gait = (C.speed_walk or 1.6), 100
                    end
                    if ladder_on then
                        -- absolute tier: base (walk 1 / trot 2) + taps, so a
                        -- tap ALWAYS visibly shifts one gait, from any speed
                        local base_tier = (gait == 100) and 1 or 2
                        local tier = math.min(4,
                            base_tier + (costume.gait_boost or 0))
                        if costume.gait_hold_gallop then tier = 4 end
                        if tier == 1 then
                            target_speed, gait = (C.speed_walk or 1.6), 100
                        elseif tier == 2 then
                            target_speed, gait = (C.speed_run or 3.4), 200
                        elseif tier == 3 then
                            target_speed, gait =
                                (tonumber(C.speed_canter) or 6.0), 250
                        else
                            target_speed, gait = (C.speed_dash or 9.5), 300
                        end
                    end
                end
                -- ⭐ 08-18 REVERSE GEAR (Aurora: "we can go backwards now"):
                -- stick pulled straight back, or DOWN arrow, while slow =
                -- back up (the 901:106 walk_back clip + a gentle reverse
                -- mover). Forward intent is force-cleared while reversing.
                costume.reversing = nil
                if (not costume.wyrm_kind) and can_drive
                    and not (costume.jump or costume.kick or costume.bless)
                    and (tonumber(costume.cur_speed) or 0) <= 0.6
                    and ((stick_y < -0.45 and math.abs(stick_x) < 0.5
                          and not up)
                        or iris_kb(0x28) or iris_kb(0x53)) then
                    costume.reversing = true
                    target_speed, gait = 0.0, 0
                end
                costume.cmd_target_speed = target_speed
                -- ⭐ 08-13 WYRM PACE (Aurora: "forward movement is kinda
                -- non-existent"): with root motion now fully cancelled the body
                -- moves at the drive's speed ALONE - and these were horse numbers.
                -- A wolf's sprint stride wants more ground per second or it runs
                -- on the spot. Sliders in the WYRM SEAT + PACE panel block.
                if costume.wyrm_kind and target_speed > 0.0 then
                    -- Wolf/cat gait is not the horse walk->trot->gallop ladder.
                    -- A diagonal full-stick turn used to lower stick_y below .85
                    -- and silently demote the mount to WALK.  Use total stick
                    -- commitment instead: gentle input walks; committed input
                    -- runs at full speed regardless of steering; B remains Sprint.
                    local stick_mag = math.sqrt(stick_x * stick_x + stick_y * stick_y)
                    if gait == 300 then
                        target_speed = tonumber(C.wyrm_speed_dash) or 11.0
                    elseif (pad_move and not up and stick_mag < 0.42)
                        or (up and iris_kb(0x11)) then
                        gait = 100
                        target_speed = tonumber(C.wyrm_speed_walk) or 2.2
                    else
                        gait = 200
                        target_speed = tonumber(C.wyrm_speed_run) or 6.0
                    end
                end
                if costume.wyrm_kind and S.wyrm_atk_until then
                    -- An attack owns translation. Movement input must not drag a howl across
                    -- the ground or make a bite fight the locomotion driver.
                    target_speed, gait = 0.0, 0
                end
                -- EASED velocity (07-23 "teleports slightly on a nudge"):
                -- speed was a step function — one frame at full walk
                -- speed = a visible hop before the clip even blends.
                -- Accelerate/brake smoothly; runs every frame so release
                -- decelerates instead of freezing mid-stride.
                local cur = costume.cur_speed or 0.0
                if costume.kick or costume.bless then cur = 0.0 end
                local rate
                if costume.wyrm_kind then
                    -- Wolves reach a run in roughly half a second rather than winding up
                    -- with the horse's heavy acceleration curve.
                    rate = (target_speed > cur) and (tonumber(C.wyrm_accel) or 26.0)
                        or (tonumber(C.wyrm_brake) or 10.0)
                else
                    rate = (target_speed > cur) and 5.0 or 7.0
                end
                local step = rate * dt
                if math.abs(target_speed - cur) <= step then
                    cur = target_speed
                else
                    cur = cur + ((target_speed > cur) and step or -step)
                end
                costume.cur_speed = cur
                -- Native physics can nudge the invisible ox chassis by a few
                -- millimetres while our commanded speed is zero. The visible
                -- horse copies that drift every frame, producing vibration and
                -- the slow stationary ice-skate. Latch X/Z once fully stopped;
                -- release immediately for movement, falls, kicks or hit recoil.
                -- 08-12 THE BREATHER STUTTER: during the tame rodeo the rest
                -- phase's pin IS a mover (it walks the anchor forward at trot
                -- pace), but cur_speed reads 0 so this latch stayed armed and
                -- snapped the horse back every frame until the pin drifted
                -- >1m -- freeze, 1m lurch, freeze. The pin owns the body for
                -- the whole brace/rodeo; the latch must stand down there.
                if S.ride_pose_on and target_speed <= 0.0 and cur <= 0.02
                    and not tame_pinned
                    and not costume.reversing   -- 08-18: reverse is a mover
                    and not costume.jump and not costume.fall_v
                    and not costume.kick and not costume.hit_react_hold
                    and not S.wyrm_native_lease then
                    local pos = ox_tf:call("get_UniversalPosition")
                    local anchor = costume.idle_anchor
                    if not anchor then
                        costume.idle_anchor = { x = pos.x, z = pos.z }
                    else
                        local dx = pos.x - anchor.x
                        local dz = pos.z - anchor.z
                        if dx * dx + dz * dz <= 1.0 then
                            pos.x, pos.z = anchor.x, anchor.z
                            ox_tf:call("set_UniversalPosition", pos)
                        else
                            -- A real displacement (scripted move/impact) is not
                            -- vibration; adopt it rather than snapping backwards.
                            costume.idle_anchor = { x = pos.x, z = pos.z }
                        end
                    end
                else
                    costume.idle_anchor = nil
                end
                -- ⭐ 08-18 REVERSE MOVER: a gentle backward step along -facing
                -- while the reverse gear is engaged (clip root motion is
                -- killed on the shell, so the drive owns this travel too)
                if costume.reversing and not costume.jump then
                    pcall(function()
                        local fwdr = ox_tf:call("get_AxisZ")
                        local posr = ox_tf:call("get_UniversalPosition")
                        local stepr = (tonumber(C.speed_reverse) or 0.9) * dt
                        posr.x = posr.x - (tonumber(fwdr.x) or 0.0) * stepr
                        posr.z = posr.z - (tonumber(fwdr.z) or 0.0) * stepr
                        ox_tf:call("set_UniversalPosition", posr)
                    end)
                end
                -- Run the same-phase residual filter during a planted attack
                -- even though requested speed is zero.  This absorbs authored
                -- attack root motion in the drive's own phase; the retired
                -- UpdateBehavior anchor fought the CharacterController and
                -- caused the persistent 15 fps correction storm.
                -- ⭐ 08-18: for wyrms the filter now runs EVERY ridden frame,
                -- not just while moving/attacking. A damage reaction while
                -- parked played its clip root travel with nobody owning
                -- translation -- Aurora's "slides to the left when hurt". Full
                -- ownership doctrine: the flinch animates, the drive holds the
                -- ground. Scripted moves >20m still adopt (the r2 ceiling).
                if (cur > 0.02 or (costume.wyrm_kind
                        and (S.wyrm_attack or C.wyrm_drift_cancel ~= false)))
                    and not costume.jump then
                    local fwd = ox_tf:call("get_AxisZ")
                    local pos = ox_tf:call("get_UniversalPosition")
                    -- ⭐ 08-13 v4 IN-TICK ROOT-MOTION CANCEL (v3's LateUpdate
                    -- canceller raced the drive across phases and ate the real
                    -- step - "movement kinda non-existent"). Same tick = no race:
                    -- whatever moved the body since the LAST drive tick beyond the
                    -- step we commanded is clip root motion - remove it, then walk.
                    if costume.wyrm_kind and C.wyrm_drift_cancel ~= false then
                        local pv, ds = costume.wyrm_prev_upos, costume.drive_step
                        if pv then
                            local rx = pos.x - pv.x - (ds and tonumber(ds.x) or 0.0)
                            local rz = pos.z - pv.z - (ds and tonumber(ds.z) or 0.0)
                            local r2 = rx * rx + rz * rz
                            -- ch223001 at wyrm scale can contribute over five
                            -- metres of clip root in a single sampled frame.
                            -- Universal coordinates do not render-rebase, so a
                            -- 5m ceiling merely let that root escape and turned
                            -- Mia into a 60m/s uncontrolled mover. Absorb any
                            -- plausible animation residual; genuine scripted
                            -- teleports above 20m are adopted on the next tick.
                            if r2 > 1e-10 and r2 < 400.0 then
                                pos.x, pos.z = pos.x - rx, pos.z - rz
                            end
                        end
                    end
                    -- Native-contact assist: follow the selected target only while
                    -- it remains in front of the mouth. A signed correction used to
                    -- overshoot, reverse on the next frame, and visibly teleport
                    -- Shadow back and forth around a goblin.
                    local attack_step = 0.0
                    local lease = S.wyrm_native_lease
                    if lease and lease.costume == costume
                        and not lease.approach_done
                        and valid(lease.target_go)
                        and (now_d - (tonumber(lease.t0) or now_d))
                            <= (tonumber(lease.approach_secs) or 0.28)
                        and (tonumber(lease.approach_moved) or 0.0)
                            < (tonumber(lease.approach_max) or 2.2) then
                        local tp = universal_pos(lease.target_go)
                        local mouth = iris_wyrm_native_mouth_positions(costume)
                        if tp and mouth then
                            local fx, fz = tonumber(fwd.x) or 0.0,
                                tonumber(fwd.z) or 0.0
                            local fl = math.sqrt(fx * fx + fz * fz)
                            if fl > 0.01 then
                                fx, fz = fx / fl, fz / fl
                                local dx, dz = tp.x - mouth.x, tp.z - mouth.z
                                local along = dx * fx + dz * fz
                                local across = math.abs(dx * fz - dz * fx)
                                local remaining = (tonumber(lease.approach_max) or 2.2)
                                    - (tonumber(lease.approach_moved) or 0.0)
                                local error = along
                                    - (tonumber(lease.approach_stop) or 0.12)
                                local cap = math.min(
                                    math.max(0.0, remaining),
                                    (tonumber(lease.approach_speed) or 18.0) * dt)
                                local wanted = math.min(cap, math.max(0.0, error))
                                if wanted > 0.001 and across <= 2.2 then
                                    if lease.approach_direction ~= "forward" then
                                        lease.approach_direction = "forward"
                                        iris_wyrm_combat_trace(lease, "contact-follow",
                                            string.format("forward error=%.2f", error))
                                    end
                                    local clear = iris_wyrm_native_clear_forward(
                                        costume, wanted, lease.target_go, fx, fz)
                                    attack_step = clear
                                    if clear <= 0.0001 then
                                        lease.approach_blocked = true
                                    end
                                    lease.approach_moved =
                                        (tonumber(lease.approach_moved) or 0.0)
                                        + clear
                                    lease.approach_forward =
                                        (tonumber(lease.approach_forward) or 0.0) + clear
                                end
                            end
                        end
                    end
                    if lease and lease.lunge_total
                        and (now_d - (tonumber(lease.t0) or now_d))
                            <= (tonumber(lease.lunge_until) or 0.4) then
                        local remaining = math.max(0.0,
                            (tonumber(lease.lunge_total) or 0.0)
                                - (tonumber(lease.lunge_done) or 0.0))
                        if remaining > 0.001 then
                            local wanted = math.min(remaining,
                                ((tonumber(lease.lunge_total) or 0.0)
                                    / math.max(0.1,
                                        tonumber(lease.lunge_until) or 0.4)) * dt)
                            local extra = iris_wyrm_clear_travel(costume,
                                wanted, fwd.x, fwd.z)
                            attack_step = attack_step + extra
                            lease.lunge_done = (tonumber(lease.lunge_done) or 0.0)
                                + extra
                        end
                    end
                    local dodge_x, dodge_z = 0.0, 0.0
                    local active_attack = S.wyrm_attack
                    local dodge_age = active_attack
                        and (now_d - (tonumber(active_attack.t0) or now_d)) or 0.0
                    if active_attack and active_attack.dodge_side
                        and dodge_age >= (tonumber(active_attack.dodge_move_delay)
                            or 0.0)
                        and dodge_age
                            <= (tonumber(active_attack.dodge_move_until) or 0.42) then
                        local axis_x = ox_tf:call("get_AxisX")
                        if axis_x then
                            local side = tonumber(active_attack.dodge_side) or 0.0
                            local dx = (tonumber(axis_x.x) or 0.0) * side
                            local dz = (tonumber(axis_x.z) or 0.0) * side
                            local dl = math.sqrt(dx * dx + dz * dz)
                            if dl > 0.01 then
                                dx, dz = dx / dl, dz / dl
                                local wanted = (tonumber(active_attack.dodge_speed)
                                    or 4.8) * dt
                                local clear = iris_wyrm_clear_travel(
                                    costume, wanted, dx, dz)
                                dodge_x, dodge_z = dx * clear, dz * clear
                            end
                        end
                    end
                    local locomotion = cur * dt
                    if locomotion > 0.0001 then
                        local safe = iris_wyrm_clear_travel(costume,
                            locomotion, fwd.x, fwd.z)
                        if safe < locomotion * 0.35 then
                            costume.cur_speed = 0.0
                        end
                        locomotion = safe
                    end
                    local pounce_dx, pounce_dz = 0.0, 0.0
                    local pounce_y = nil
                    if lease and lease.pounce_motion
                        and not lease.full_native_controller then
                        local age = now_d - (tonumber(lease.t0) or now_d)
                            - (tonumber(lease.pounce_launch_delay) or 0.0)
                        local air = math.max(0.2,
                            tonumber(lease.pounce_airtime) or 0.78)
                        local u = math.max(0.0, math.min(1.0, age / air))
                        local remaining = math.max(0.0,
                            (tonumber(lease.pounce_travel) or 0.0)
                                - (tonumber(lease.pounce_moved) or 0.0))
                        if age >= 0.0 and u < 1.0 and remaining > 0.001 then
                            -- ⭐ 08-18 r3 IN-FLIGHT HOMING (trace runs 14/18:
                            -- both pounce misses OVERSHOT -- victim 1.7-2.9m
                            -- BEHIND the mouth by the window). Steer each step
                            -- of the leap at the live victim's position, and
                            -- once the mouth is on/past it, LAND -- never sail
                            -- on along the launch heading.
                            local dirx = tonumber(fwd.x) or 0.0
                            local dirz = tonumber(fwd.z) or 0.0
                            if valid(lease.target_go) then
                                local tp = universal_pos(lease.target_go)
                                local mouth =
                                    iris_wyrm_native_mouth_positions(costume)
                                if tp and mouth then
                                    local dx = tp.x - mouth.x
                                    local dz = tp.z - mouth.z
                                    local along = dx * dirx + dz * dirz
                                    local dl = math.sqrt(dx * dx + dz * dz)
                                    -- r13: carry ~0.9m PAST the body (engage
                                    -- feel), not a dead stop at the nose.
                                    if along <= -0.9 and dl <= 3.4 then
                                        remaining = 0.0
                                        lease.pounce_moved =
                                            tonumber(lease.pounce_travel) or 0.0
                                    elseif dl > 0.05 then
                                        dirx, dirz = dx / dl, dz / dl
                                    end
                                end
                            end
                            if remaining > 0.001 then
                                local wanted = math.min(remaining,
                                    ((tonumber(lease.pounce_travel) or 0.0) / air)
                                        * dt)
                                local clear = iris_wyrm_clear_travel(costume,
                                    wanted, dirx, dirz)
                                pounce_dx, pounce_dz = dirx * clear, dirz * clear
                                lease.pounce_moved =
                                    (tonumber(lease.pounce_moved) or 0.0) + clear
                                if clear <= 0.0001 then
                                    lease.pounce_blocked = true
                                end
                            end
                        end
                        pounce_y = (tonumber(lease.pounce_y0) or pos.y)
                            + 4.0 * (tonumber(lease.pounce_height) or 1.35)
                                * u * (1.0 - u)
                    end
                    -- r10 RT CONVERGE: walk the MOUTH onto the downed prey in
                    -- ANY direction, backwards included, through acquire and
                    -- the push-down. The forward approach can only close a
                    -- positive along, so post-pounce (prey under the belly,
                    -- run 12: along=-0.94) it stood still and RT withheld.
                    local maul_dx, maul_dz = 0.0, 0.0
                    if lease and lease.direct_maul
                        and not lease.full_native_controller
                        and (lease.phase ~= "maul"
                            or now_d <= (tonumber(lease.maul_converge_until)
                                or 0.0))
                        and valid(lease.target_go) then
                        local mtp = universal_pos(lease.target_go)
                        local mmouth =
                            iris_wyrm_native_mouth_positions(costume)
                        if mtp and mmouth then
                            local mdx = mtp.x - mmouth.x
                            local mdz = mtp.z - mmouth.z
                            local mdl = math.sqrt(mdx * mdx + mdz * mdz)
                            if mdl > 0.12 then
                                local wanted = math.min(mdl, 6.5 * dt)
                                local dirx, dirz = mdx / mdl, mdz / mdl
                                local clear = iris_wyrm_clear_travel(costume,
                                    wanted, dirx, dirz)
                                maul_dx, maul_dz = dirx * clear, dirz * clear
                            end
                        end
                    end
                    local commanded = locomotion + attack_step
                    local step_x = fwd.x * commanded + dodge_x + pounce_dx
                        + maul_dx
                    local step_z = fwd.z * commanded + dodge_z + pounce_dz
                        + maul_dz
                    pos.x = pos.x + step_x
                    pos.z = pos.z + step_z
                    if pounce_y then pos.y = pounce_y end
                    ox_tf:call("set_UniversalPosition", pos)
                    costume.drive_step = { x = step_x, z = step_z }
                    costume.wyrm_prev_upos = { x = pos.x, z = pos.z }
                else
                    costume.drive_step = nil
                    costume.wyrm_prev_upos = nil
                end
                -- r57 GROUND & GRAVITY (subsumes the r34 bridge fix;
                -- Aurora: "gallop off an edge and it kind of floats
                -- down... similar if I walk/trot off too" -- the drive
                -- only ever LIFTED y, descent was left to the chassis,
                -- which sinks gently instead of falling). One y-pass
                -- every ridden frame, moving or not: step/slope UP
                -- (<=1m, the bridge law), glue down gentle slopes, and
                -- past a 0.35m drop = REAL integrated gravity (14,
                -- the kick-arc constant) with a landing thud after
                -- >1.6m of fall. Cast reaches 30m so cliffs register.
                local pounce_airborne = S.wyrm_native_lease
                    and S.wyrm_native_lease.pounce_motion
                    and not S.wyrm_native_lease.full_native_controller
                    and (now_d - (tonumber(S.wyrm_native_lease.t0) or now_d))
                        < ((tonumber(S.wyrm_native_lease.pounce_launch_delay)
                                or 0.0)
                            + (tonumber(S.wyrm_native_lease.pounce_airtime)
                                or 0.78))
                if not costume.jump and not pounce_airborne then
                    pcall(function()
                        local ground = rawget(_G,
                            "route3_ground_below_uni")
                        local pos = ox_tf:call("get_UniversalPosition")
                        local hit = ground and ground(
                            pos.x, pos.y + 1.0, pos.z, 1.2, 30.0)
                        local gy = hit and tonumber(hit.y)
                        local changed = false
                        if gy then
                            local dyg = pos.y - gy
                            local rollback = false
                            local safe = costume.wyrm_kind
                                and (costume.wyrm_wall_block
                                    or S.mount_last_safe_ground) or nil
                            if safe and costume.fall_v == nil then
                                local sx, sy, sz = tonumber(safe.x),
                                    tonumber(safe.y), tonumber(safe.z)
                                if sx and sy and sz then
                                    local hx, hz = pos.x - sx, pos.z - sz
                                    local flat = math.sqrt(hx * hx + hz * hz)
                                    local rise = (gy + 0.02) - sy
                                    local allowed = math.max(0.28,
                                        flat * math.tan(math.rad(38.0)))
                                    -- Catch both the one-frame ground snap and
                                    -- the rarer case where transform/root motion
                                    -- has already ratcheted the chassis through
                                    -- the hill before the forward ray saw it.
                                    rollback = (dyg < 0.0 and rise > allowed)
                                        or (pos.y - sy > 2.4 and flat < 6.0)
                                    if rollback then
                                        pos.x, pos.y, pos.z = sx, sy, sz
                                        costume.cur_speed = 0.0
                                        costume.fall_v, costume.fall_from = nil, nil
                                        costume.jump = nil
                                        costume.drive_step = { x = 0.0, z = 0.0 }
                                        costume.wyrm_prev_upos = { x = sx, z = sz }
                                        costume.wyrm_steep_block_until = now_d + 0.35
                                        S.mount_last_safe_ground = {
                                            x = sx, y = sy, z = sz, at = now_d,
                                        }
                                        changed = true
                                        if now_d >= (tonumber(
                                                costume.wyrm_rollback_log_at)
                                                or 0.0) then
                                            costume.wyrm_rollback_log_at = now_d + 1.0
                                            log(string.format(
                                                "wyrm terrain rollback: rise %.2fm / %.2fm travel",
                                                rise, flat))
                                        end
                                    end
                                end
                            end
                            if not rollback and dyg >= -0.10 and dyg <= 0.35
                                and costume.fall_v == nil then
                                remember_mount_safe_ground(costume,
                                    pos.x, gy + 0.15, pos.z)
                            end
                            local stationary_ground = S.ride_pose_on
                                and (tonumber(costume.cur_speed) or 0.0) <= 0.02
                                and costume.fall_v == nil
                                -- 08-12: the rodeo rest phase WALKS the body
                                -- (pin-driven, cur_speed still 0) -- it must
                                -- ground-follow smoothly, not in 8cm steps
                                and not (tame_pinned and tame_hold
                                    and tame_hold.rodeo
                                    and tame_hold.rodeo.phase == "rest")
                            if rollback then
                                -- Position and movement state were restored to
                                -- the last grounded point above.
                            elseif dyg < 0.0 and -dyg < 1.0 then
                                -- Ray contacts flicker by a few centimetres on
                                -- triangle seams. Do not bounce a stationary
                                -- chassis for that noise; real steps still win.
                                if not stationary_ground or -dyg > 0.08 then
                                    pos.y = gy + 0.02
                                    changed = true
                                end
                                costume.fall_v = nil
                                costume.fall_from = nil
                            elseif dyg > 0.35 then
                                costume.fall_v =
                                    (costume.fall_v or 0.0) + 14.0 * dt
                                costume.fall_from =
                                    costume.fall_from or pos.y
                                local ny = pos.y
                                    - costume.fall_v * dt
                                if ny <= gy + 0.02 then
                                    ny = gy + 0.02
                                    local fell = (tonumber(
                                        costume.fall_from) or ny) - gy
                                    costume.fall_v = nil
                                    costume.fall_from = nil
                                    -- ⭐⭐ r90 THE THUD, ON ACTUAL CONTACT.
                                    -- (Aurora: "sometimes the landing thud
                                    -- doesn't happen... can we not have it play
                                    -- when the raycast reads that the horse is
                                    -- on the ground after a jump?" -- yes, and
                                    -- that is strictly better than predicting.)
                                    -- ⛔ WHY IT WENT MISSING: the r72 predictor
                                    -- lives INSIDE `if costume.jump`. When a
                                    -- leap outlasts its arc the jump table is
                                    -- cleared and the body is handed to gravity
                                    -- -- so the predictor stops running before
                                    -- the horse ever lands, and the thud is
                                    -- simply never fired. Exactly the "jump
                                    -- lasting longer than intended" case.
                                    -- This branch IS the touchdown, so fire it
                                    -- here where the ground is a fact.
                                    if costume.jump_thud_pending then
                                        costume.jump_thud_pending = nil
                                        pcall(function()
                                            local audio = rawget(_G,
                                                "__lyra_horse_custom_audio_api")
                                            if audio and audio.play_event then
                                                audio.play_event(
                                                    tonumber(C.jump_land_event)
                                                        or 1084357815,
                                                    costume.horse_go)
                                                log(string.format(
                                                    "jump land fx: ON CONTACT (fell %.1fm)",
                                                    fell))
                                            end
                                        end)
                                    end
                                    if fell > 1.6 then
                                        pcall(function()
                                            local audio = rawget(_G,
                                                "__lyra_horse_custom_audio_api")
                                            if audio
                                                and audio.play_category then
                                                audio.play_category(
                                                    "land",
                                                    costume.horse_go)
                                            end
                                        end)
                                    end
                                end
                                pos.y = ny
                                changed = true
                            else
                                if dyg > 0.02
                                    and (not stationary_ground or dyg > 0.10) then
                                    pos.y = gy + 0.02
                                    changed = true
                                end
                                costume.fall_v = nil
                                costume.fall_from = nil
                            end
                        elseif costume.fall_v then
                            -- nothing under the ray at all: keep falling
                            costume.fall_v = costume.fall_v + 14.0 * dt
                            pos.y = pos.y - costume.fall_v * dt
                            changed = true
                        else
                            -- ⭐⭐ r76 (Aurora: "going into the fall state doesn't
                            -- seem to happen either, on long falls").
                            -- THE HOLE: the cast reaches 30m. Past that gy is
                            -- nil -- and with fall_v also nil, BOTH branches
                            -- above were skipped and nothing happened at all.
                            -- So the deeper the drop, the less likely the horse
                            -- was to fall: step off a 5m ledge and gravity
                            -- started, step off a cliff and it just hung there
                            -- until something else moved it. Seed the fall here
                            -- so the next frame's branch takes over properly.
                            -- r13 UNBURY (video 19-34): a jump can land INSIDE
                            -- a rock mass -- the probe then starts inside the
                            -- mesh, misses backfaces, and this branch seeded a
                            -- FALL that sank the wolf through the boulder. A
                            -- surface well ABOVE the root means inside
                            -- geometry, not over a void: roll back to the last
                            -- proven ground instead of falling.
                            local high = ground and ground(
                                pos.x, pos.y + 6.0, pos.z, 1.2, 12.0)
                            local hy = high and tonumber(high.y)
                            local safe2 = S.mount_last_safe_ground
                            if hy and hy > pos.y + 1.2 and safe2
                                and tonumber(safe2.x)
                                and now_d - (tonumber(safe2.at) or 0.0)
                                    < 10.0 then
                                pos.x = tonumber(safe2.x)
                                pos.y = tonumber(safe2.y)
                                pos.z = tonumber(safe2.z)
                                costume.cur_speed = 0.0
                                costume.jump = nil
                                costume.fall_v, costume.fall_from = nil, nil
                                costume.drive_step = { x = 0.0, z = 0.0 }
                                costume.wyrm_prev_upos =
                                    { x = pos.x, z = pos.z }
                                changed = true
                                log(string.format(
                                    "wyrm unbury: surface %.1fm overhead - rolled back",
                                    hy - pos.y))
                            else
                                costume.fall_v = 0.5
                                costume.fall_from = pos.y
                                log("fall: long drop (no ground within 30m)")
                            end
                        end
                        if changed then
                            ox_tf:call("set_UniversalPosition", pos)
                        end
                    end)
                    -- ⭐ 08-09 r63 THE FALLING ANIMATION (Aurora: "we need a
                    -- falling state/animation"). bank 0 / 415 =
                    -- com_fall_loop_vertical -- read out of the Animal Atlas by
                    -- NAME and present on EVERY ridable chassis (ch99_0xx horse,
                    -- ch23 wolf, ch53 griffin all carry it at the same address),
                    -- so no species table is needed for this one.
                    -- Edge-triggered in BOTH directions: fired once when the
                    -- fall starts, and force_hold released once it ends so the
                    -- normal gait selector takes the layer straight back. It is
                    -- a LOOP, so it is never re-fired while airborne -- that
                    -- would pin it at frame 0 and read as a frozen horse.
                    if C.fall_anim_enabled ~= false then
                        -- ⭐ r65 (Aurora: "I don't think the falling animation
                        -- is actually working... it kind of just fell down
                        -- normally"). It WAS firing -- 13 times in her log --
                        -- but far too late to see. The gate was fall_v > 3.0,
                        -- and fall_v starts at 0 and grows at 14*dt, so it took
                        -- ~0.21s of falling to arm. For that whole window
                        -- force_hold is still nil, so the GAIT SELECTOR owns
                        -- layer 0 and paints a ground gait over the fall -- the
                        -- horse visibly "falls normally", then maybe flicks.
                        -- 2.0 arms in ~0.14s, and fall_anim_force (set by the
                        -- r63 jump handover) arms it on the very first frame,
                        -- which is the case that most needed it.
                        local fall_drop = 0.0
                        if costume.fall_v ~= nil then
                            pcall(function()
                                local fp = ox_tf:call("get_UniversalPosition")
                                fall_drop = math.max(0.0,
                                    (tonumber(costume.fall_from)
                                        or tonumber(fp.y) or 0.0)
                                        - (tonumber(fp.y) or 0.0))
                            end)
                        end
                        local falling = costume.fall_v ~= nil
                            and (costume.fall_anim_force == true
                                or fall_drop >= 0.55)
                        if falling and not costume.fall_anim then
                            costume.fall_anim = true
                            costume.force_hold = true
                            pcall(function()
                                local motion = costume.horse_character
                                    :call("get_Motion")
                                local layer = motion
                                    and motion:call("getLayer", 0)
                                if not layer then return end
                                layer:call(
                                    "changeMotion(System.UInt32, System.UInt32, "
                                    .. "System.Single, System.Single, "
                                    .. "via.motion.InterpolationMode, "
                                    .. "via.motion.InterpolationCurve)",
                                    tonumber(C.fall_anim_bank) or 0,
                                    tonumber(C.fall_anim_clip) or 415,
                                    0.0, 0.18, 1, 1)
                                log("fall anim: airborne")
                            end)
                        elseif (not falling) and costume.fall_anim then
                            costume.fall_anim = nil
                            costume.fall_anim_force = nil
                            costume.force_hold = nil
                            costume.last_gait = nil   -- force a gait re-pick
                        end
                    end
                    -- r83: the mount HP feed MOVED to
                    -- iris_companion_hp_tick in GriffinRideProbe -- it now
                    -- follows the summoned companion rather than the saddle,
                    -- and one writer owns _G.IrisMountHUD.
                    -- ⭐⭐ r85 MORTALITY ENFORCER. The rider's blanket immunity is
                    -- already off (r79), but the MOUNT has several paths that
                    -- can set IsDamageZero on it -- IrisTaming's ritual shield
                    -- ("while approached/yielded/tamed the creature CANNOT be
                    -- hurt"), the grab/carry immunity, the downed re-assert --
                    -- and any one of them failing to clear leaves the horse
                    -- permanently unhittable. I have been unable to SEE which,
                    -- because the reader used the wrong component type.
                    -- ⛔ So stop caring which path set it: while you are riding
                    -- and mounted combat is enabled, the mount is mortal, every
                    -- tick, full stop. You cannot ride a downed body (forced
                    -- dismount + the r67 mount gate), so this can never fight
                    -- the downed system's deliberate shield.
                    if C.route3_mounted_combat ~= false then
                        pcall(function()
                            local f = rawget(_G, "route3_grab_set_immunity")
                            if f then f(costume.horse_character, false) end
                        end)
                    end
                    -- ⭐⭐⭐ 08-10 r94 -- WHY MOST CYCLOPS SWINGS DO NOTHING.
                    -- (Aurora: "there were many attacks before that which did
                    -- nothing... little hits should still happen".)
                    -- The ride drives ONLY ox_tf:set_UniversalPosition. It has
                    -- never once written the horse's app.Character position --
                    -- the griffin's equivalent helper (set_character_transform)
                    -- writes the transform AND ch:set_UniversalPosition AND the
                    -- rotation, every frame, and that is not decoration.
                    -- app.Character's position is what the damage/collision side
                    -- resolves against, so if it is stale the horse's HURTBOX is
                    -- parked somewhere the horse no longer is. Attacks then pass
                    -- through the visible body untouched, and only something with
                    -- an enormous radius ever connects -- exactly one hit in a
                    -- whole fight, and it happened to be a 249-damage one.
                    -- ⛔ SELF-LIMITING BY DESIGN: measure the gap first and only
                    -- correct it past a threshold. If the two bodies are already
                    -- co-located this does nothing at all, so it cannot introduce
                    -- the double-drive the ox/shell split was built to avoid.
                    if C.ride_sync_character ~= false then
                        pcall(function()
                            -- r95: app.Character has no get_UniversalPosition
                            -- (that is why bodyGap read -1.00 = never measured).
                            -- Go through its transform.
                            local ctf = costume.horse_character
                                :call("get_Transform")
                            local cpos = ctf
                                and ctf:call("get_UniversalPosition")
                            local opos = ox_tf:call("get_UniversalPosition")
                            if not (cpos and opos) then return end
                            local dxc = (tonumber(cpos.x) or 0) - (tonumber(opos.x) or 0)
                            local dyc = (tonumber(cpos.y) or 0) - (tonumber(opos.y) or 0)
                            local dzc = (tonumber(cpos.z) or 0) - (tonumber(opos.z) or 0)
                            local gap = math.sqrt(dxc * dxc + dyc * dyc + dzc * dzc)
                            S.ride_body_gap = gap
                            if gap > (tonumber(C.ride_sync_gap) or 0.5) then
                                ctf:call("set_UniversalPosition", opos)
                                S.ride_body_synced = (tonumber(S.ride_body_synced) or 0) + 1
                            end
                        end)
                    end
                    -- ⭐ 08-09 r68 RIDE DAMAGE DIAGNOSTIC. Aurora reports the
                    -- horse is effectively invincible to a cyclops WHILE RIDDEN,
                    -- AND that no boss healthbar appears for that cyclops -- and
                    -- the r66 collider change never even logged, so the branch it
                    -- lives in is not the branch her ride takes. That is three
                    -- unknowns, and I have already guessed wrong twice, so this
                    -- MEASURES instead: one line every 2s naming the horse's HP,
                    -- which of its damage-relevant components exist and whether
                    -- they are enabled, the same for the rider, and whether the
                    -- downed system is even protecting this body.
                    -- Expected readings and what each would mean:
                    --   horse Colliders=off  -> no hurtbox, r66 did not apply here
                    --   horse HitController missing/off -> hits cannot resolve
                    --   player HitController=off -> rider is not a target, which
                    --     would explain the missing boss bar (no engagement)
                    --   hp falling but no downed entry -> the clamp is the issue
                    -- ⛔ Read-only and opt-in.  Reflection over both full
                    -- component graphs every two seconds is inappropriate for
                    -- normal play and contributed periodic hitches.
                    if C.ride_damage_diag == true
                        and now_d >= (tonumber(S.ride_diag_at) or 0.0) then
                        S.ride_diag_at = now_d + 2.0
                        pcall(function()
                            local function cs(go, tn)
                                local c = get_component(go, tn)
                                if not c then return "MISSING" end
                                local en = nil
                                pcall(function() en = c:call("get_Enabled") end)
                                return (en == false) and "off" or "on"
                            end
                            local hgo = costume.horse_go
                            -- ⛔ r82: was app.HitPointController -- WRONG TYPE,
                            -- which is why every diag line read "hp=?". The
                            -- damage authority is app.HitController (it carries
                            -- get_Hp AND setHp); griffin_read_target_hp is the
                            -- mod's existing, working reader for exactly this.
                            -- ⭐ r90: read BOTH HP stores side by side. The clamp
                            -- reports damage passing through at 31 with a budget
                            -- of 249, yet this number never moves -- so either
                            -- the engine is not applying it, or we are watching
                            -- the wrong store. hpRecv is the controller the
                            -- damage pipeline actually hands us; if that one
                            -- falls while hhp sits at 250, the split is proven
                            -- and everything just needs repointing.
                            local hhp = "?"
                            pcall(function()
                                local rd = rawget(_G, "griffin_read_target_hp")
                                if rd then
                                    hhp = tostring(rd(costume.horse_character))
                                end
                            end)
                            local hrecv = "?"
                            pcall(function()
                                local src = rawget(_G, "IrisHpSourceHp")
                                if src then hrecv = tostring(src) end
                            end)
                            hhp = hhp .. " recv=" .. hrecv
                            local think = "?"
                            pcall(function()
                                think = tostring(costume.horse_character
                                    :call("get_IsThinkStop"))
                            end)
                            local hkind = "?"
                            pcall(function()
                                local ctx = costume.horse_character
                                    :get_field("<Context>k__BackingField")
                                hkind = tostring(ctx and ctx:get_field("CharacterKind") or "?")
                            end)
                            local prot = "no"
                            pcall(function()
                                local a = hgo:get_address()
                                if type(_G.IrisDownedAddrs) == "table"
                                    and _G.IrisDownedAddrs[a] then
                                    prot = "DOWNED"
                                end
                            end)
                            -- ⭐ r79: the IMMUNITY FLAGS. Twice now an invisible
                            -- boolean (IsDamageZero) has cost hours of hunting
                            -- component states that were never the blocker.
                            -- Show them for both bodies.
                            -- ⛔ r85: was app.HitPointController -- the SAME wrong
                            -- type that made hp read "?" for days. So the
                            -- immunity flags have never actually been measured;
                            -- every "horse=? rider=?" line was a failed lookup,
                            -- not a body with nothing set. Use the mod's own
                            -- resolver, which finds app.HitController.
                            local function imm(ch_or_go, ch)
                                local out = "?"
                                pcall(function()
                                    local f = rawget(_G,
                                        "griffin_target_hit_controller")
                                    local hc = ch and f and f(ch) or nil
                                    if not hc then
                                        hc = get_component(ch_or_go,
                                            "app.HitController")
                                    end
                                    if not hc then return end
                                    local z = nil
                                    for _, g in ipairs({ "get_IsDamageZero",
                                        "get_IsIgnoreDamageHit" }) do
                                        local ok, v = pcall(function()
                                            return hc:call(g)
                                        end)
                                        if ok and type(v) == "boolean" then
                                            z = (z or "") .. (v and "1" or "0")
                                        end
                                    end
                                    out = z or "n/a"
                                end)
                                return out
                            end
                            local pgo2 = player_game_object()
                            log(string.format(
                                "ride diag immunity: horse=%s rider=%s",
                                imm(hgo, costume.horse_character),
                                imm(pgo2, player_character())))
                            log(string.format(
                                "ride diag: horse hp=%s think=%s kind=%s Colliders=%s "
                                .. "HitCtrl=%s ReqSetCol=%s | rider HitCtrl=%s "
                                .. "Colliders=%s | downed=%s",
                                hhp, think, hkind,
                                cs(hgo, "via.physics.Colliders"),
                                cs(hgo, "app.HitController"),
                                cs(hgo, "via.physics.RequestSetCollider"),
                                cs(pgo2, "app.HitController"),
                                cs(pgo2, "via.physics.Colliders"),
                                prot)
                                .. string.format(
                                    " | riderReqSetCol=%s hateAllowed=%s"
                                    .. " | clampHits=%s clamp=%s"
                                    .. " | bodyGap=%.2fm synced=%s dmgApplyAll=%s"
                                    .. " friendForced=%s alertBlocks=%s(%s)"
                                    .. " catchHand=%s hpFallback=%s[%s]",
                                    cs(pgo2, "via.physics.RequestSetCollider"),
                                    tostring(rawget(_G,
                                        "IrisMountedHateAllowed") or 0),
                                    tostring(rawget(_G, "IrisClampHits") or 0)
                                        .. "/relEnemy=" .. tostring(rawget(_G,
                                            "IrisMountedRelEnemy") or 0),
                                    tostring(rawget(_G, "IrisClampDbg")
                                        or "(no damage seen)"),
                                    tonumber(S.ride_body_gap) or -1.0,
                                    tostring(S.ride_body_synced or 0),
                                    tostring(rawget(_G, "IrisDmgApplyAll") or 0),
                                    tostring(rawget(_G, "IrisFriendAttackForced") or 0),
                                    tostring(rawget(_G, "IrisAlertBlocks") or 0),
                                    tostring(rawget(_G, "IrisAlertLastNode") or "-"),
                                    tostring(S.catch_handoffs or 0),
                                    tostring(rawget(_G, "IrisFallbackDamageHits") or 0),
                                    tostring(rawget(_G, "IrisFallbackDamageLast") or "-")))
                        end)
                    end
                end
                -- r71: release the layer once the landing clip has played out.
                -- ⛔ Kept OUTSIDE the `if costume.jump` block on purpose --
                -- costume.jump is already nil by the time this needs to fire.
                -- ⛔ r76: never release mid-leap. (Aurora: "sometimes when you
                -- press jump the animation doesn't happen - might be something
                -- to do with pressing the jump immediately after landing.")
                -- Exactly that: this watcher runs BEFORE the jump block, so a
                -- jump started inside the landing window had its force_hold
                -- torn away on the very next frame and the gait selector
                -- repainted straight over the take-off clip -- a jump with no
                -- animation. The `not costume.jump` guard closes it.
                if costume.jump_land_until and not costume.jump
                    and now_d >= costume.jump_land_until then
                    costume.jump_land_until = nil
                    costume.force_hold = nil
                    costume.last_gait = nil   -- force a fresh gait pick
                end
                if costume.jump then
                    local jump = costume.jump
                    -- ⭐ r72 THE GATHER (Aurora: "the horse needs to not actually
                    -- jump vertically for a small moment to let the jump start
                    -- animation prep"). The take-off clip opens with the hooves
                    -- gathering under the body -- but the ballistic arc used to
                    -- begin on the very same frame, so the horse was already
                    -- rising while the clip was still crouching to push off.
                    -- ⛔ The gather delays the VERTICAL clock only. Horizontal
                    -- keeps advancing at the take-off speed throughout, because
                    -- a real horse gathers WHILE STILL RUNNING -- freezing it
                    -- outright for a fifth of a second would read as a hitch,
                    -- which is the opposite of the fix.
                    local gth = tonumber(jump.gather) or 0.0
                    local phase = (now_d - jump.t0 - gth) / jump.dur
                    -- ⛔ r92: LANDING IS NO LONGER A TIMER. The flight code below
                    -- ends the jump the moment the parabola meets the ground, or
                    -- hands it to gravity at jump_max_air. This branch used to
                    -- fire at phase >= 1.0 -- i.e. at the airtime the arc WOULD
                    -- have taken on flat ground -- which is precisely what cut
                    -- long falls short and produced the endpoint snap.
                    -- Kept only as a hard backstop so a jump can never wedge.
                    if phase >= 6.0 then
                        -- ⭐⭐⭐ 08-09 r63 -- THE ARC ENDS INTO THE WORLD, NOT
                        -- INTO AN ASSUMPTION. Two defects lived in these five
                        -- lines, and between them they are most of what Aurora
                        -- has been reporting about jumping.
                        --
                        -- (1) IT TELEPORTED TO jump.y1 UNCONDITIONALLY. y1 was
                        -- itself a GUESS made at take-off by a probe reaching
                        -- only 8m, and it was never re-checked. Jump anywhere
                        -- the launch probe was wrong -- off a ledge, over a
                        -- lip, near a drop -- and the arc ends by hard-setting
                        -- Y to a stale number. That IS the horse "appearing on
                        -- top of things" and "going through the floor": not a
                        -- physics glitch, a teleport to a bad coordinate.
                        -- The correction: keep the scripted HORIZONTAL
                        -- endpoint, but RESOLVE Y here and now, with a probe
                        -- that reaches 60m instead of 6m.
                        --
                        -- (2) IT ALWAYS DECLARED A LANDING. (Aurora: "if you
                        -- jump off a ledge it does a landing mid fall, with the
                        -- thud sound, then just acts as normal.") The arc is a
                        -- fixed 1.2s box; the world is not. When the clip runs
                        -- out in mid-air the body must be handed to GRAVITY --
                        -- r57 already implements real integrated falling right
                        -- above -- and the thud must wait for actual contact.
                        local pos = ox_tf:call("get_UniversalPosition")
                        -- ⛔ r83 -- "IT LANDS IN A NORMAL ARC THEN TELEPORTS BACK
                        -- A BIT." My own r81 bug: lifting the horizontal clamp
                        -- let the leap fly PAST the precomputed endpoint, but
                        -- this line still snapped x/z back to that endpoint on
                        -- touchdown -- so the further it flew, the further back
                        -- it yanked. The endpoint is only meaningful when a wall
                        -- or ledge actually defined it; otherwise the horse has
                        -- already arrived and there is nothing to correct.
                        if jump.clamped then
                            pos.x, pos.z = jump.x1, jump.z1
                        end
                        local cur_y = tonumber(pos.y) or jump.y1
                        local landed_y = nil
                        pcall(function()
                            local ground = rawget(_G,
                                "route3_ground_below_uni")
                            local hit = ground and ground(
                                pos.x, cur_y + 2.0, pos.z, 2.5, 60.0)
                            if hit and tonumber(hit.y) then
                                landed_y = tonumber(hit.y)
                            end
                        end)
                        if landed_y and (cur_y - landed_y) <= 0.6 then
                            -- ground is right there: a genuine touchdown
                            pos.y = landed_y
                            -- ⭐ r71 PHASE 3: Jump_toIdle. The pack has shipped
                            -- a landing clip (902/2) since the day it was added
                            -- and nothing has ever played it -- the leap simply
                            -- stopped and the gait selector took over, which is
                            -- the abrupt "and then just acts as normal" ending.
                            -- Hold the layer for its length, then release.
                            if jump.jland and jump.jbank then
                                costume.force_hold = true
                                costume.jump_land_until = now_d
                                    + (tonumber(C.jump_land_secs) or 0.45)
                                pcall(function()
                                    local motion = costume.horse_character
                                        :call("get_Motion")
                                    local layer = motion
                                        and motion:call("getLayer", 0)
                                    if not layer then return end
                                    layer:call(
                                        "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                                        jump.jbank, jump.jland, 0.0, 0.12, 1, 1)
                                    layer:call("set_Speed", 1.0)
                                    log("jump seq: land")
                                end)
                            end
                            -- THE LANDING BANG -- 08-07 r19 ("don't hear much
                            -- of a bang"): a one-shot post can lose its lane
                            -- slot to a resumed hoofbeat (30ms window) --
                            -- RETRY a few frames until it lands
                            costume.bang_due = {tries = 10}
                        else
                            -- still in the air (or nothing found at all): do
                            -- NOT snap, do NOT bang. Seed r57's gravity from
                            -- where the body actually is and let it fall.
                            pos.y = cur_y
                            -- ⭐ r66: hand over the REAL descent velocity, not a
                            -- token 2.0. The arc ends travelling downward at
                            -- g*t - v0, and r57 falls under the SAME g -- so
                            -- carrying the true speed across makes the join
                            -- invisible instead of a visible re-start.
                            local tj2 = math.max(0.0, (now_d - jump.t0)
                                - (tonumber(jump.gather) or 0.0))
                            local vdown = (tonumber(jump.g) or 14.0) * tj2
                                - (tonumber(jump.v0) or 7.2)
                            costume.fall_v = math.max(
                                tonumber(costume.fall_v) or 0.0,
                                math.max(2.0, vdown))
                            costume.fall_from = cur_y
                            -- r65: arm the fall animation on THIS frame. Waiting
                            -- for the velocity gate left a visible beat where
                            -- the gait selector repainted a ground clip -- which
                            -- is the "stops for a split second then just falls"
                            -- Aurora sees straight after a jump off a ledge.
                            costume.fall_anim_force = true
                            -- r90: the arc is over but the horse has NOT landed.
                            -- Arm the thud so r57's touchdown fires it whenever
                            -- contact actually happens, however long that takes.
                            costume.jump_thud_pending = true
                        end
                        ox_tf:call("set_UniversalPosition", pos)
                        costume.jump = nil
                        costume.last_gait = nil
                        -- the leap owned the layer; gaits resume -- ⛔ UNLESS the
                        -- r71 landing clip is still running, which is set two
                        -- lines above and would be wiped by an unconditional
                        -- clear here. Released by the jump_land_until watcher.
                        if not costume.jump_land_until then
                            costume.force_hold = nil
                        end
                    else
                        phase = math.max(0.0, phase)
                        -- r26 (Aurora: landing sound "0.5s or so
                        -- earlier"): the native impact fires DURING the
                        -- descent, half a second before touchdown; the
                        -- hoof slam stays at the actual touch
                        -- ⭐⭐ r72 THE THUD IS PREDICTED FROM THE GROUND, NOT THE
                        -- CLOCK. (Aurora: "the thud sound still doesn't happen
                        -- on ground hit, it's still timed so it can happen in
                        -- midair.") Correct -- r65 only added a distance gate
                        -- around a fixed timer that still fired at dur-0.25
                        -- whatever was happening. On a jump onto a ledge, off a
                        -- cliff, or into a wall, "0.25s before the timer ends"
                        -- has nothing to do with when the hooves arrive.
                        -- Now it is checked EVERY frame and answers the only
                        -- question that matters: given how fast we are actually
                        -- falling and how far the ground actually is, how long
                        -- until contact? Fire when that is inside the lead time.
                        -- ⛔ No ground under the ray = it CANNOT fire. Leaping
                        -- into open air is silent by construction, and it stays
                        -- armed, so the thud lands whenever the horse eventually
                        -- does. r26's early-by-a-fraction feel is preserved --
                        -- it is now a real 0.22s before touchdown, not a guess.
                        if not jump.land_fx_done then
                            pcall(function()
                                local gj2 = tonumber(jump.g) or 14.0
                                local vj2 = tonumber(jump.v0) or 7.2
                                local tv = math.max(0.0,
                                    (now_d - jump.t0) - gth)
                                local vy = vj2 - gj2 * tv   -- +up / -down
                                if vy >= -0.5 then return end   -- still rising
                                local ground = rawget(_G,
                                    "route3_ground_below_uni")
                                local p2 = ox_tf:call("get_UniversalPosition")
                                local h2 = ground and ground(
                                    p2.x, p2.y + 1.0, p2.z, 1.5, 20.0)
                                local gy2 = h2 and tonumber(h2.y)
                                if not gy2 then return end
                                local drop = math.max(0.0, p2.y - gy2)
                                local tt = drop / (-vy)
                                if tt > (tonumber(C.jump_land_lead) or 0.22) then
                                    return
                                end
                                jump.land_fx_done = true
                                local audio = rawget(_G,
                                    "__lyra_horse_custom_audio_api")
                                if audio and audio.play_event then
                                    local okl = audio.play_event(
                                        tonumber(C.jump_land_event)
                                            or 1084357815,
                                        costume.horse_go)
                                    log(string.format(
                                        "jump land fx: %s (%.2fs to ground, %.1fm)",
                                        tostring(okl), tt, drop))
                                end
                            end)
                        end
                        local pos = ox_tf:call("get_UniversalPosition")
                        -- ⭐ r66 BALLISTIC INTEGRATION. Horizontal advances at
                        -- the take-off speed (constant -- no acceleration, no
                        -- snap-back), capped at the wall/ledge-clamped reach.
                        -- Vertical is real projectile motion under the SAME
                        -- gravity r57 falls with, so the hand-off at the end of
                        -- the arc is seamless instead of a gear change.
                        -- ⛔ The old flat-hold envelope is gone on purpose: it
                        -- kept y pinned to the ground line for the first 20% and
                        -- last 14%, so the horse slid, popped, and slid again.
                        -- r72: two clocks. Horizontal never pauses; vertical
                        -- waits out the gather so the push-off reads as a push.
                        -- ⭐⭐⭐ 08-10 r92 -- GRIFFIN-PARITY FLIGHT.
                        -- The griffin's ground jump (route3_ground_jump_tick)
                        -- has NO destination: it steps forward from wherever it
                        -- currently is and re-resolves the ground under itself
                        -- EVERY FRAME, landing whenever the parabola meets it.
                        -- Ledges, fences and cliffs all fall out of that for
                        -- free. Ours flew a scripted line to a point chosen at
                        -- take-off, which is why it needed an apex path-guard to
                        -- shove Y over lips, an endpoint snap, and a teleport
                        -- branch -- three patches for one wrong premise.
                        -- Horizontal now advances from the CURRENT position.
                        local tjh = math.max(0.0, now_d - jump.t0)
                        local tj = math.max(0.0, tjh - gth)
                        local dt_j = math.max(0.0, math.min(0.1,
                            now_d - (tonumber(jump.last_t) or jump.t0)))
                        jump.last_t = now_d
                        local step = (tonumber(jump.hspeed) or 0.0) * dt_j
                        local prev_x, prev_z = pos.x, pos.z
                        local mj = tonumber(jump.maxd) or 0.0
                        if mj > 0.0 then
                            step = math.min(step,
                                math.max(0.0, mj - (tonumber(jump.d) or 0.0)))
                        end
                        if costume.wyrm_kind and step > 0.0001 then
                            local clear = iris_wyrm_clear_travel(costume, step,
                                tonumber(jump.dirx) or 0.0,
                                tonumber(jump.dirz) or 0.0, true)
                            if clear < step * 0.5 then
                                -- Preserve the vertical arc but stop horizontal
                                -- travel at the wall; never use the wall's top
                                -- as a staircase destination.
                                jump.maxd = (tonumber(jump.d) or 0.0) + clear
                            end
                            step = clear
                        end
                        jump.d = (tonumber(jump.d) or 0.0) + step
                        pos.x = pos.x + (tonumber(jump.dirx) or 0.0) * step
                        pos.z = pos.z + (tonumber(jump.dirz) or 0.0) * step
                        -- vertical stays the ABSOLUTE parabola (drift-free --
                        -- integrating y as well would accumulate error)
                        local gj = tonumber(jump.g) or 14.0
                        local vj = tonumber(jump.v0) or 7.2
                        pos.y = jump.y0 + vj * tj - 0.5 * gj * tj * tj
                        -- ⭐ r71 PHASE 2: the take-off clip has said what it has
                        -- to say -- hand the air over to the horse's OWN
                        -- airborne clip rather than letting a borrowed one run
                        -- long. Edge-triggered; it is a loop, so never re-fired.
                        local vertical_v = vj - gj * tj
                        if costume.wyrm_kind and jump.seq == "start"
                            and now_d >= (tonumber(jump.front_at) or now_d) then
                            jump.seq = "rise"
                            iris_jump_play(costume, tonumber(jump.jbank) or 0,
                                tonumber(jump.jfront) or 423)
                            log("jump seq: rise")
                        elseif ((costume.wyrm_kind and jump.seq == "rise" and vertical_v <= 0.0)
                            or (not costume.wyrm_kind and jump.seq == "start" and jump.air_at
                                and now_d >= jump.air_at)) then
                            jump.seq = "air"
                            iris_jump_play(costume, tonumber(jump.jbank)
                                or tonumber(C.fall_anim_bank) or 0,
                                tonumber(jump.jfall) or tonumber(C.fall_anim_clip) or 415)
                            log("jump seq: air")
                        end
                        -- ⭐⭐⭐ r92 GROUND TRUTH EVERY FRAME, LANDING IS EMERGENT.
                        -- ⛔ The r58/r59 apex path-guard is GONE, deliberately.
                        -- It existed to shove Y up over lips the scripted line
                        -- would otherwise pass through -- a non-ballistic
                        -- override that popped. With the ground re-resolved
                        -- under the CURRENT position each frame, "landing on a
                        -- lip" is simply the parabola meeting the ground early,
                        -- which needs no correction at all. Cast reaches 60m
                        -- (griffin uses 120) so a cliff resolves properly
                        -- instead of falling into r57's no-ground hole.
                        local land_y = nil
                        local landing_slope_ok = true
                        local steep_base_y = nil
                        pcall(function()
                            local ground = rawget(_G,
                                "route3_ground_below_uni")
                            local hit = ground and ground(
                                pos.x, pos.y + 2.0, pos.z, 2.5, 60.0)
                            if hit then land_y = tonumber(hit.y) end
                            if not land_y or jump.steep_blocked then return end
                            -- A vertical ray reports the face of a steep incline
                            -- as "ground" once the parabola gets near it. Sample
                            -- across the direction of travel and reject anything
                            -- too steep to support four hooves.
                            local sample = math.max(0.25,
                                tonumber(C.jump_landing_sample_m) or 0.8)
                            local back = ground(
                                pos.x - (tonumber(jump.dirx) or 0.0) * sample,
                                pos.y + 2.0,
                                pos.z - (tonumber(jump.dirz) or 0.0) * sample,
                                2.5, 60.0)
                            local ahead = ground(
                                pos.x + (tonumber(jump.dirx) or 0.0) * sample,
                                pos.y + 2.0,
                                pos.z + (tonumber(jump.dirz) or 0.0) * sample,
                                2.5, 60.0)
                            local by = back and tonumber(back.y)
                            local ay = ahead and tonumber(ahead.y)
                            steep_base_y = by
                            local rise = nil
                            if by and ay then rise = math.abs(ay - by) / (2.0 * sample)
                            elseif by then rise = math.abs(land_y - by) / sample end
                            local limit = math.tan(math.rad(tonumber(
                                C.jump_max_landing_slope_deg) or 42.0))
                            if rise and rise > limit then landing_slope_ok = false end
                        end)
                        if jump.steep_blocked then
                            land_y = tonumber(jump.block_ground_y) or land_y
                            landing_slope_ok = true
                        end
                        local descending = (vj - gj * tj) < 0.0
                        if land_y and descending
                            and landing_slope_ok
                            and pos.y <= land_y + 0.25 then
                            -- TOUCHDOWN -- wherever it happens to be
                            pos.y = land_y
                            ox_tf:call("set_UniversalPosition", pos)
                            iris_jump_sync_character(costume, pos)
                            iris_jump_land(costume, jump, now_d)
                            costume.jump = nil
                            costume.last_gait = nil
                        elseif land_y and descending and not landing_slope_ok
                            and pos.y <= land_y + 0.25 then
                            -- The arc met a wall-like incline, not a floor.
                            -- Undo this frame's forward step, stop horizontal
                            -- travel, and let the vertical arc finish onto the
                            -- last standable ground instead of "landing" on the
                            -- face halfway through the jump.
                            pos.x, pos.z = prev_x, prev_z
                            jump.d = math.max(0.0,
                                (tonumber(jump.d) or 0.0) - step)
                            jump.maxd = jump.d
                            jump.hspeed = 0.0
                            jump.steep_blocked = true
                            jump.block_ground_y = steep_base_y or jump.y0
                            if not jump.steep_logged then
                                jump.steep_logged = true
                                log("jump: steep incline rejected as landing surface")
                            end
                            ox_tf:call("set_UniversalPosition", pos)
                            iris_jump_sync_character(costume, pos)
                        elseif tj > (tonumber(C.jump_max_air) or 4.0) then
                            -- never landed (leapt into a chasm): hand to r57
                            -- gravity carrying the true descent speed
                            ox_tf:call("set_UniversalPosition", pos)
                            iris_jump_sync_character(costume, pos)
                            costume.fall_v = math.max(
                                tonumber(costume.fall_v) or 0.0,
                                math.max(2.0, gj * tj - vj))
                            costume.fall_from = pos.y
                            costume.fall_anim_force = true
                            costume.jump_thud_pending = true
                            costume.jump = nil
                            costume.last_gait = nil
                            costume.force_hold = nil
                            log("jump: airborne past timeout -> gravity")
                        else
                            ox_tf:call("set_UniversalPosition", pos)
                            iris_jump_sync_character(costume, pos)
                        end
                    end
                end
                -- DISPLAY gait follows the EASED speed, not the command
                -- (07-23: trot legs on a barely-moving body at start, and
                -- freeze-flick at stop — both were command-vs-body
                -- mismatch). Accelerating walks before it trots; stopping
                -- steps back down through the gaits. Always set while the
                -- costume drives (the measured fallback never flickers in).
                local walk_s = C.speed_walk or 1.6
                local trot_s = C.speed_run or 3.4
                local dash_s = C.speed_dash or 9.5
                local display = 0
                if (not costume.wyrm_kind)
                    and C.gait_ladder_enabled ~= false then
                    -- 08-18 four-tier horse ladder: the canter band sits at
                    -- the midpoints. ⛔ EXPLICITLY horse-only (reviewer #8:
                    -- a shared canter band would classify wyrm_speed_run 6.0
                    -- as display 250 on a body with no bank 901).
                    local cant_s = tonumber(C.speed_canter) or 6.0
                    if cur >= (cant_s + dash_s) * 0.5 then display = 300
                    elseif cur >= (trot_s + cant_s) * 0.5 then display = 250
                    elseif cur >= (walk_s + trot_s) * 0.5 then display = 200
                    elseif cur > 0.25 then display = 100 end
                else
                    if cur >= (trot_s + dash_s) * 0.5 then display = 300
                    elseif cur >= (walk_s + trot_s) * 0.5 then display = 200
                    elseif cur > 0.25 then display = 100 end
                end
                costume.driven_gait = display
                end -- transform-driven fallback / native ch223 controller
            end
        end
        -- ox_pos feeds the gait-match measure BELOW — it must exist in
        -- BOTH modes (07-24 frozen-horse bug: moving it inside the guard
        -- nil-crashed the rest of this pcall silently = no gaits at all)
        local ox_pos = ox_tf:call("get_UniversalPosition")
        if not costume.oxless then
            horse_tf:call("set_UniversalPosition", ox_pos)
            horse_tf:call("set_Rotation", ox_tf:call("get_Rotation"))
        end
        -- GAIT MATCH: think-stop froze the horse in whatever clip it had
        -- ("runs on the spot"). Measure the ox's real speed and request the
        -- matching NATIVE doe clip (0/100/200/300) — the wild-horses module
        -- auto-upgrades those ids to Lyra's horse gaits (AUTO_MAP).
        local now = os.clock()
        if not costume.native_controller_live
            and costume.last_pos and now > (costume.last_t or 0) then
            local dt = now - costume.last_t
            if dt > 0.05 then
                local dx = ox_pos.x - costume.last_pos.x
                local dz = ox_pos.z - costume.last_pos.z
                local speed = math.sqrt(dx * dx + dz * dz) / dt
                costume.speed = speed
                -- ⭐ r80 SNAP DETECTOR (Aurora: "sometimes when running the horse
                -- will stop and then suddenly be a lot further forward"). That is
                -- a positional discontinuity, and I have guessed wrong enough
                -- times today -- so catch it with the state attached instead.
                -- Gallop is ~9.5 m/s; anything over 25 m/s in a single frame is
                -- a teleport, not locomotion. One line per event, with every
                -- flag that could plausibly own the body at that moment.
                if speed > (tonumber(C.ride_snap_warn) or 25.0) then
                    log(string.format(
                        "RIDE SNAP: %.1fm in %.3fs (%.0f m/s) | jump=%s fall_v=%s "
                        .. "hold=%s landclip=%s gait=%s cur=%.1f",
                        math.sqrt(dx * dx + dz * dz), dt, speed,
                        tostring(costume.jump ~= nil),
                        tostring(costume.fall_v ~= nil),
                        tostring(costume.force_hold == true),
                        tostring(costume.jump_land_until ~= nil),
                        tostring(costume.last_gait),
                        tonumber(costume.cur_speed) or 0.0))
                end
                -- driven gait is authoritative (we KNOW it); speed
                -- thresholds only cover un-driven native movement
                local target = costume.driven_gait
                if target == nil then
                    target = 0
                    if speed > 6.0 then target = 300
                    elseif speed > 2.6 then target = 200
                    elseif speed > 0.35 then target = 100 end
                end
                -- ⭐ 08-18 v2 pseudo-targets (negative codes so plain gaits
                -- never collide): reverse gear and stationary turn-in-place.
                -- And STOP-DIRECT: when the input is fully released while
                -- moving, jump straight to the real stop clip for the CURRENT
                -- gait instead of stepping down through every band (the
                -- step-down is why Aurora never saw a single transition).
                if (not costume.wyrm_kind) and not costume.force_hold then
                    if costume.reversing then
                        target = -106
                    elseif target == 0 and math.abs(
                            tonumber(costume.turn_input) or 0.0) > 0.35 then
                        target = ((tonumber(costume.turn_input) or 0.0) > 0)
                            and -8 or -7
                    elseif target >= 100
                        and (tonumber(costume.cmd_target_speed) or 1.0)
                            <= 0.01 then
                        target = 0
                    end
                end
                if target ~= costume.last_gait
                    and not costume.force_hold then
                    local prev_gait = costume.last_gait
                    costume.last_gait = target
                    -- semantic gait -> Lyra's REAL horse gaits, baked in
                    -- (Aurora 07-23): bank 901 walk=1 trot=2 gallop=3
                    -- (+ 08-18: canter=5 at tier 250, horse ladder only).
                    -- Sliders still override for lab work.
                    -- ⭐ 08-13 WYRM MOUNT: a costume with its OWN gait table
                    -- (wolf/cat native locomotion) outranks the horse bank
                    local bank, clip = 0, target
                    local g9 = costume.gaits
                    if target == 100 then
                        bank = (g9 and g9.walk and g9.walk[1]) or S.gait_walk_bank or 901
                        clip = (g9 and g9.walk and g9.walk[2]) or S.gait_walk_id or 1
                    elseif target == 200 then
                        bank = (g9 and g9.run and g9.run[1]) or S.gait_run_bank or 901
                        clip = (g9 and g9.run and g9.run[2]) or S.gait_run_id or 2
                    elseif target == 250 then
                        bank, clip = 901, 5   -- W3 canter (never reached by wyrms)
                    elseif target == -106 then
                        bank, clip = 901, 106   -- reverse: walk_back loop
                    elseif target == -7 then
                        bank, clip = 901, 7     -- turn-in-place (stick left)
                    elseif target == -8 then
                        bank, clip = 901, 8     -- turn-in-place (stick right)
                    elseif target == 300 then
                        bank = (g9 and g9.dash and g9.dash[1]) or S.gait_dash_bank or 901
                        clip = (g9 and g9.dash and g9.dash[2]) or S.gait_dash_id or 3
                    elseif target == 0 and (not costume.wyrm_kind) and not g9 then
                        -- 08-18: ridden idle = W3 standing idle when the full
                        -- bank serves (nil api = old doe idle 0:0 unchanged)
                        pcall(function()
                            local api = rawget(_G, "__iris_wild_horses_api")
                            local w3a = api and api.w3_actions and api.w3_actions()
                            if w3a then bank, clip = w3a.bank, w3a.idle end
                        end)
                    end
                    -- ⭐ 08-18 v2 TRANSITION COMMIT (Aurora: "I'm not seeing
                    -- any of the transitions"): v1 let the NEXT band crossing
                    -- stomp a transition ~0.35s in, so none ever finished.
                    -- Now a transition clip owns the layer for
                    -- C.gait_trans_hold seconds; gait changes underneath only
                    -- retarget cmd_clip, and the loop assist lands the NEWEST
                    -- loop when the clip ends (the assist IS the chain).
                    -- Exception: accelerating out of a committed STOP breaks
                    -- the hold immediately — a rider pushing forward must
                    -- never feel glued to a stop animation.
                    local issue_bank, issue_clip = bank, clip
                    local trans_len = 0.0
                    local trans_hold = costume.gait_trans_until
                        and now < costume.gait_trans_until
                    if trans_hold and costume.gait_trans_kind == "stop"
                        and target >= 100 then
                        trans_hold = false
                        costume.gait_trans_until = nil
                    end
                    if (not costume.wyrm_kind) and (not g9) and bank == 901
                        and target >= 0 and not trans_hold then
                        pcall(function()
                            local api = rawget(_G, "__iris_wild_horses_api")
                            local tmap = api and api.w3_trans and api.w3_trans()
                            -- ⛔ prev_gait nil = a FORCED re-pick (post-jump
                            -- landing, mount): never paint a stationary start
                            -- clip over a body already at speed. Negative
                            -- (pseudo) prevs have no keys and skip naturally.
                            local tclip = prev_gait and type(prev_gait) == "number"
                                and prev_gait >= 0 and tmap
                                and tmap[tostring(prev_gait)
                                .. ">" .. tostring(target)]
                            if tclip then
                                issue_clip = tclip
                                costume.loop_prev = nil
                                trans_len = tonumber(C.gait_trans_hold) or 0.9
                            end
                        end)
                    end
                    costume.cmd_bank, costume.cmd_clip = bank, clip
                    if trans_hold then
                        -- committed clip still playing: cmd retargeted above,
                        -- the assist lands it at the clip's final frame
                        costume.gait_trans_pending = true
                    else
                        costume.gait_issue_t = now
                        costume.gait_trans_until = (trans_len > 0)
                            and (now + trans_len) or nil
                        costume.gait_trans_kind = (trans_len > 0)
                            and ((target == 0) and "stop" or "go") or nil
                        pcall(function()
                            local motion = costume.horse_character:call("get_Motion")
                            local layer = motion and motion:call("getLayer", 0)
                            if layer then
                                layer:call(
                                    "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                                    bank, issue_clip, 0.0, 0.35, 1, 1)
                            end
                        end)
                    end
                    -- changeMotion may reset layer root-motion state
                    S.need_rootmotion_kill = true
                    -- ⭐ 08-13 WYRM CADENCE (Aurora: "focus on movement"): scale the
                    -- clip's play speed so paws match the ground - per-gait, saved,
                    -- 1.0 = authored pace. Wyrm-gated: the horse's own speed lever
                    -- stays untouched.
                    if costume.wyrm_kind then
                        pcall(function()
                            local f = 1.0
                            if target == 100 then f = tonumber(C.wyrm_pace_walk) or 1.0
                            elseif target == 200 then f = tonumber(C.wyrm_pace_run) or 1.0
                            elseif target == 300 then f = tonumber(C.wyrm_pace_dash) or 1.12 end
                            local motion = costume.horse_character:call("get_Motion")
                            local layer = motion and motion:call("getLayer", 0)
                            if layer then layer:call("set_Speed", f) end
                        end)
                    end
                end
                costume.last_pos = {x = ox_pos.x, y = ox_pos.y, z = ox_pos.z}
                costume.last_t = now
            end
        else
            costume.last_pos = {x = ox_pos.x, y = ox_pos.y, z = ox_pos.z}
            costume.last_t = now
        end
    end)
    -- LOOP ASSIST: some of the best doe clips (112 = the clopping walk)
    -- are authored NON-looping — re-issue the commanded clip the moment
    -- its frame counter reaches the end, turning any clip into a loop
    pcall(function()
        local clip = costume.cmd_clip
        if not clip then return end
        if costume.jump then return end   -- the leap plays ONCE; never re-fired mid-air
        -- ⛔⛔ 08-09 r80 -- THIS IS WHAT KILLS THE FALL ANIMATION.
        -- (Aurora: "fall state/animation doesn't seem to be working at all" --
        -- while the log shows "fall anim: airborne" firing nine times. Both are
        -- true: it plays, and then this stomps it.)
        -- The loop assist reads get_Frame/get_EndFrame off LAYER 0 -- which by
        -- then is the FALL clip -- and on any stall re-issues costume.cmd_clip,
        -- which is the GAIT (901/3 gallop). So the moment the fall loop reaches
        -- its end the horse is snapped back to a galloping animation in mid-air.
        -- It only ever guarded against costume.jump, so every OTHER thing that
        -- borrows layer 0 -- the fall loop, the r71 landing clip, the downed
        -- pose -- was fair game.
        -- force_hold is precisely the "someone else owns layer 0" flag those
        -- systems already set, so honour it here; the explicit two are belt and
        -- braces in case a future path forgets to raise it.
        if costume.force_hold then return end
        if costume.fall_anim then return end
        if costume.jump_land_until then return end
        local motion = costume.horse_character:call("get_Motion")
        local layer = motion and motion:call("getLayer", 0)
        if not layer then return end
        local frame = tonumber(layer:call("get_Frame")) or 0
        local endf = tonumber(layer:call("get_EndFrame")) or 0
        -- STALL detection only (07-23 "flicking" fix): natively-looping
        -- clips wrap before the end and must never be touched — rewind
        -- only when the frame counter has genuinely stopped at the end
        local prev = costume.loop_prev
        costume.loop_prev = frame
        if endf > 1 and frame >= endf - 0.5
            and prev and frame <= prev + 0.01 then
            -- 08-18: when the stalled clip is NOT cmd_clip this call is a
            -- transition landing its target loop — changeMotion may reset
            -- layer root-motion state there, so re-arm the kill
            pcall(function()
                local cur_id = tonumber(layer:call("get_MotionID"))
                if cur_id ~= clip then S.need_rootmotion_kill = true end
            end)
            layer:call(
                "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                costume.cmd_bank or 0, clip, 0.0, 0.0, 1, 1)
        end
    end)
    -- SEAT LOCK pin: the rider is a couples-law passenger of the horse.
    -- Written HERE (LateUpdateBehavior) and re-asserted at PrepareRendering
    -- (griffin seat_hold rung — kills the mid-frame micro-shifts the
    -- LateUpdate-only pin still showed, 07-23 "she moves into new
    -- positions when the horse moves")
    seat_pin_apply()
    -- ⭐ 08-06 THE DISMOUNT-TELEPORT CURE: the well-poisoning (the probe's
    -- round-40/42 counter) only ran in the LEGACY passenger branch -- the
    -- NORMAL horse ride never seeded the recorder, so the game's stuck-rescue
    -- held ONE safe coordinate for the whole ride: the MOUNT POINT. Seed the
    -- seat as safe ground every tick; whatever rescue fires (it likely also
    -- explains the camera going nuts), displacement = zero.
    if S.ride_pose_on and costume.seat then
        pcall(function()
            local pl = player_character()
            local rec = pl and pl:get_field("<PosRotRecorder>k__BackingField")
            if not rec then return end
            pcall(function() rec:call("set_IsSafeCoord", true) end)
            local ptf = player_game_object():call("get_Transform")
            local pp = ptf:call("get_UniversalPosition")
            local pr = ptf:call("get_Rotation")
            if pp and pr then
                local vp = ValueType.new(
                    sdk.find_type_definition("via.Position"))
                vp.x, vp.y, vp.z = pp.x, pp.y, pp.z
                if not pcall(function()
                    rec:call("recordPosRotExternal", vp, pr)
                end) then
                    pcall(function() rec:call("recordPosRot", vp, pr) end)
                end
                pcall(function()
                    rec:set_field("PosAfterReviveFromFallDead",
                        Vector3f.new(pp.x, pp.y, pp.z))
                    rec:set_field("IsAfterReviveFromFallDead", false)
                end)
                local lp = nil
                pcall(function()
                    lp = rec:get_field("LandingProcessor")
                end)
                if lp then
                    pcall(function()
                        local g = lp:call("get_LastGroundPosition")
                        if g then
                            g.x, g.y, g.z = pp.x, pp.y - 0.6, pp.z
                            lp:call("set_LastGroundPosition", g)
                        end
                    end)
                    pcall(function()
                        lp:call("resetFallingStuckStopperToCurrentPosition")
                    end)
                    pcall(function()
                        local fi = lp:get_field("FallInfo")
                        if fi then
                            fi:call("resetFallHeight")
                            fi:call("set_FallHeight", 0.0)
                        end
                    end)
                end
            end
        end)
    end
    -- ⭐ 08-07 r13 (Aurora: "can't we just track player movement as the
    -- horse moves so dismount is in the expected place?" -- yes, and
    -- it's the fix for the CAUSE): the suppressed components each keep
    -- an INTERNAL position that froze at the mount point -- the root of
    -- every dismount teleport. Feed them the live seat position all
    -- ride. Each component is reflection-probed ONCE for a position
    -- setter; the probe log names what each type actually offers, so a
    -- missing setter still buys next-round evidence instead of a guess.
    -- ⛔⛔ MOUNT CTD BISECT (2026-08-09): mounting still crashes after the warp(0) fix,
    -- ~11ms after the park, INSIDE a REFramework-mediated call (dinput8 frames sit in the
    -- crash stack = the AV happened in a managed call WE issued, not in idle game code).
    -- This sync is the only thing in the mount path that pokes native methods into
    -- components we have DISABLED, every 0.25s -- writing physics state on a suppressed
    -- component is exactly the class that has bitten this repo before (frozen-shape law).
    -- It exists only to stop a dismount POSITION DRIFT: a cosmetic bug. A crash outranks
    -- it, so the whole block is now opt-in and OFF by default -- and that makes the next
    -- test a clean one-variable bisect instead of another guess.
    if C.cc_sync_enabled == true and S.ride_pose_on and costume.seat then
        if not S.cc_sync or S.cc_sync.v ~= 4 then
            -- v4 (08-09): bumped so the probe RE-RUNS and records warp0 alongside the
            -- 1-arg setter. S survives script reloads, so a stale v3 table would keep
            -- write-only setters and the dismount teleport would persist even with the
            -- fix in place. (v3 dropped the bare warp that AV'd; v4 restores it as the
            -- second half of write-then-warp, never on its own.)
            S.cc_sync = {v = 4, probed = {}, setters = {}}
        end
        local sync = S.cc_sync
        local nowc = os.clock()
        if nowc >= (sync.next_t or 0) then
            sync.next_t = nowc + 0.25
            -- only the two position-CACHING components get written; the
            -- IK/collider entries are probe-logged for information only
            local sync_targets = {
                ["via.physics.CharacterController"] = true,
                ["app.GroundFixer"] = true,
            }
            pcall(function()
                local ptf = player_game_object():call("get_Transform")
                local rp = ptf:call("get_Position") -- component space
                for type_name, record in pairs(S.disabled_components) do
                    local comp = record.component
                    if valid(comp) then
                        if not sync.probed[type_name] then
                            sync.probed[type_name] = true
                            pcall(function()
                                -- 08-07 r16 (the probe log delivered:
                                -- CharacterController has NO set_Position
                                -- -- it has WARP): prefer warp, fall back
                                -- to set_Position on types that have it
                                local names, best, warp0 = {}, nil, false
                                local td = comp:get_type_definition()
                                while td do
                                    for _, m in ipairs(td:get_methods()) do
                                        local n = m:get_name()
                                        if n:match("[Pp]osition")
                                            or n:match("[Ww]arp")
                                            or n:match("[Tt]eleport") then
                                            names[#names + 1] = n
                                            if sync_targets[type_name] then
                                                -- ⛔⛔ CRASH LAW (2026-08-09, mount CTD):
                                                -- a setter that takes NO ARGUMENTS is not a
                                                -- setter -- it is a COMMAND that acts on
                                                -- internal state we never wrote. The probe
                                                -- found CharacterController.warp() with 0
                                                -- params, wired it, and calling it every
                                                -- 0.25s AV'd the game 23ms later (log:
                                                -- "cc sync wired: ... -> warp(0 params)" is
                                                -- the last line before c0000005). Its own
                                                -- probe list shows the real contract:
                                                -- warp + get/set_OverwritePosition -- i.e.
                                                -- WRITE the destination, THEN warp. A bare
                                                -- warp() travels to whatever uninitialised
                                                -- value that field holds.
                                                -- ⛔ pcall CANNOT catch a native AV, so the
                                                -- wrapper around the call was never safety.
                                                -- Only ever wire a 1-ARG position setter.
                                                if (n == "set_OverwritePosition"
                                                    or n == "set_Position")
                                                    and not (best and best.name
                                                        == "set_OverwritePosition") then
                                                    local np = 1
                                                    pcall(function()
                                                        np = m:get_num_params()
                                                    end)
                                                    if np == 1 then
                                                        best = {name = n, params = 1}
                                                    end
                                                end
                                                -- ⭐ 08-09 THE SECOND HALF OF THE CONTRACT.
                                                -- The crash law above is right that a BARE
                                                -- warp() is lethal -- it travels to an
                                                -- uninitialised field. But writing the
                                                -- destination and never warping is why the
                                                -- DISMOUNT TELEPORT came back: set_Overwrite-
                                                -- Position only fills the field; nothing moves
                                                -- the controller, so its internal position
                                                -- stays frozen at the mount point -- exactly
                                                -- the state r13 was built to kill. Record the
                                                -- 0-arg warp so the call site can do what this
                                                -- comment already prescribes: WRITE, then WARP.
                                                if n == "warp" then
                                                    local np = 1
                                                    pcall(function()
                                                        np = m:get_num_params()
                                                    end)
                                                    if np == 0 then warp0 = true end
                                                end
                                            end
                                        end
                                    end
                                    td = td:get_parent_type()
                                end
                                if best then
                                    best.warp0 = warp0 == true
                                    sync.setters[type_name] = best
                                    log("cc sync wired: " .. type_name
                                        .. " -> " .. best.name .. "("
                                        .. tostring(best.params) .. " params)"
                                        .. (best.warp0 and " + warp() apply" or ""))
                                end
                                log("cc probe " .. type_name .. ": "
                                    .. table.concat(names, " "):sub(1, 220))
                            end)
                        end
                        local setter = sync.setters[type_name]
                        -- belt to the probe's braces: even if a 0-param entry survives in
                        -- stale saved state, never issue an argument-less native command here
                        if setter and (setter.params or 1) == 1 then
                            pcall(function() comp:call(setter.name, rp) end)
                            -- ⭐ WRITE, THEN WARP (08-09). The write alone fills a field and
                            -- moves nothing, which is why the dismount teleport returned. The
                            -- warp is only ever issued in the SAME breath as a fresh, valid
                            -- destination write -- never bare, which is what AV'd. Flip
                            -- C.cc_sync_warp = false to fall back to write-only instantly.
                            if setter.warp0 and C.cc_sync_warp ~= false then
                                pcall(function() comp:call("warp") end)
                            end
                        end
                    end
                end
            end)
        end
    end
    -- TAME-CLIMB stamina hold (griffin-proven APIs): climbing your own
    -- mount never drains — top the player off while near the costume
    pcall(function()
        local player_pos = universal_pos(player_game_object())
        local ox_pos = universal_pos(costume.ox_go)
        if not (player_pos and ox_pos)
            or distance(player_pos, ox_pos) > 6.0 then
            return
        end
        local player = player_character()
        local sm = player and player:call("get_StaminaManager")
        if not sm then return end
        local max_value = sm:call("get_MaxValue")
        if max_value then sm:call("set_RemainingAmount", max_value) end
    end)
end

-- ---------------------------------------------------------------------------
-- SUMMON MOUNT spawner — DIRECT spawn via app.GenerateManager, the proven
-- Nick's-devtools one-shot: native prefab path + catalog chara id +
-- InstanceInfo overload once the prefab reads Ready. Replaces the
-- capture-replay machinery (which needed a one-time manual EnemySpawner
-- capture, and matched the STAG's id ch299010 as "doe" — doe is ch299011,
-- so the trap could never have armed anyway).
-- ---------------------------------------------------------------------------
local SUMMON = { pending = nil, trace = {} }
local SUMMON_SPECIES = {
    doe = "ch299011_A_00", -- the Wild Horses chassis
    ox = "ch299003_A_00",  -- the climbable body-double
}
local SPAWN_METHOD = sdk.find_type_definition("app.GenerateManager")
    :get_method("requestCreateInstance(app.PrefabController, "
        .. "app.GenerateInfo.GenerateInfoContainer, System.Int32, "
        .. "app.InstanceInfo, "
        .. "System.Action`2<app.PrefabInstantiateResults,app.DummyArg>, "
        .. "System.Action`2<app.PrefabInstantiateResults,app.DummyArg>)")

local function summon_trace(species, msg)
    SUMMON.trace[species] = msg
end

local function summon_chara_id(field_name)
    local td = sdk.find_type_definition("app.CharacterID")
    for _, field in ipairs(td:get_fields() or {}) do
        if field:is_static() and field:get_name() == field_name then
            return field:get_data()
        end
    end
    return nil
end

local function summon_spawn(species, forward_m)
    local id_string = SUMMON_SPECIES[species]
    if not id_string then
        return false, "unknown species " .. tostring(species)
    end
    local ok, err = pcall(function()
        local chara_id = summon_chara_id(id_string)
        if chara_id == nil then
            error(id_string .. " not found in app.CharacterID")
        end
        local prefab = sdk.create_instance("via.Prefab"):add_ref()
        prefab:set_Path("AppSystem/ch/ch299/prefab/"
            .. id_string:lower() .. ".pfb")
        -- RESOURCE LAW 11c: bare set_Path never STARTS the load — standby
        -- + the per-frame pump below is what makes Ready come true
        pcall(function() prefab:set_Standby(true) end)
        local pc = sdk.create_instance("app.PrefabController"):add_ref()
        pc._Item = prefab
        local gi = sdk.create_instance(
            "app.GenerateInfo.GenerateInfoContainer"):add_ref()
        local tf = player_game_object():call("get_Transform")
        local up = tf:call("get_UniversalPosition")
        local fwd = tf:call("get_AxisZ")
        up.x = up.x + fwd.x * forward_m
        up.y = up.y + 0.2
        up.z = up.z + fwd.z * forward_m
        gi._CommonInfo._InitialPosition = up
        gi._CommonInfo._ContextPosition = up
        local rot = tf:call("get_Rotation")
        gi._CommonInfo._InitialAngle = rot
        gi._CommonInfo._ContextAngle = rot
        gi._CommonInfo._ObjectID._SelectedCharacterID = chara_id
        -- spawn IDLE: no fleeing doe / wandering ox while the costume
        -- assembles itself (costume_start wakes the ox when it dresses)
        gi._CharaInfo._IsThinkStop = true
        local ii = sdk.create_instance("app.InstanceInfo"):add_ref()
        SUMMON.pending = SUMMON.pending or {}
        SUMMON.pending[#SUMMON.pending + 1] = {
            prefab = prefab, pc = pc, gi = gi, ii = ii,
            t0 = os.clock(), species = species,
        }
        summon_trace(species, "staged, warming prefab...")
    end)
    if not ok then
        summon_trace(species, "build THREW: " .. tostring(err))
    end
    return ok, err
end

-- THREAD LAW (resource laws 11b): prefab pumping is engine streaming work
-- and must run on the GAME thread — UpdateBehavior, not on_frame
re.on_application_entry("UpdateBehavior", function()
    -- stage 2: spawned instances — the moment the doe's body exists, hand
    -- it straight to the Wild Horses converter (the ScaleMediator hook is
    -- not reliable for direct spawns; this is)
    if S.summon_keep then
        for index = #S.summon_keep, 1, -1 do
            local p = S.summon_keep[index]
            local done = false
            if os.clock() - p.t0 > 30 then
                if p.species == "doe" then
                    local api = rawget(_G, "__iris_wild_horses_api")
                    summon_trace("doe", "conversion NEVER landed (30s) — "
                        .. "wild-horses says: "
                        .. ((api and api.status) and api.status() or "?"))
                end
                done = true
            else
                local go = nil
                pcall(function()
                    go = p.ii["<Instance>k__BackingField"]
                end)
                if valid(go) then
                    if p.species == "ox" then
                        -- born SILENT + INVISIBLE (07-24: a moo escaped
                        -- in the spawn-to-dress window; the body-double
                        -- must never be seen or heard)
                        pcall(function()
                            local comps = go:call("get_Components")
                            for _, comp in ipairs(
                                comps and comps:get_elements() or {}) do
                                local type_name = ""
                                pcall(function()
                                    type_name = comp:get_type_definition()
                                        :get_full_name()
                                end)
                                if type_name:find("Wwise") then
                                    pcall(function()
                                        comp:call("set_Enabled", false)
                                    end)
                                end
                            end
                            local mesh = get_component(go,
                                "via.render.Mesh")
                            if mesh then
                                mesh:call("set_Enabled", false)
                            end
                        end)
                        done = true
                    elseif p.species ~= "doe" then
                        done = true
                    else
                        -- RETRY-UNTIL-VERIFIED (07-23: the one-shot handoff
                        -- raced component init — Character/renderer may not
                        -- exist yet when the game object first appears, and
                        -- a burned-out apply window was silently dropped)
                        local api = rawget(_G, "__iris_wild_horses_api")
                        if not (api and api.convert_doe) then
                            summon_trace("doe", "Wild Horses api missing — "
                                .. "is the module loaded + enabled?")
                            done = true
                        elseif os.clock() - (p.next_try or 0) >= 0 then
                            p.next_try = os.clock() + 0.5
                            p.tries = (p.tries or 0) + 1
                            pcall(function()
                                api.convert_doe(go:call("get_Transform"))
                            end)
                            local address = object_address(go)
                            local record = address and REGISTRY[address]
                            if record and record.kind == "horse" then
                                summon_trace("doe", "converted to horse ("
                                    .. p.tries .. " tries)")
                                done = true
                            else
                                summon_trace("doe", "converting... try "
                                    .. p.tries .. " | wild-horses: "
                                    .. (api.status and api.status() or "?"))
                            end
                        end
                    end
                end
            end
            if done then table.remove(S.summon_keep, index) end
        end
        if #S.summon_keep == 0 then S.summon_keep = nil end
    end
    -- stage 1: staged prefabs warming toward Ready
    if not SUMMON.pending then return end
    for index = #SUMMON.pending, 1, -1 do
        local p = SUMMON.pending[index]
        local drop = false
        if os.clock() - p.t0 > 15 then
            summon_trace(p.species, "prefab never Ready (15s) — path "
                .. "not loading?")
            S.status = "summon: " .. p.species .. " prefab never ready (15s)"
            drop = true
        else
            -- the pump: PrefabController:update() advances the load
            pcall(function() p.pc:call("update") end)
            local ready = false
            pcall(function() ready = p.prefab:get_Ready() end)
            if ready then
                local ok2, err2 = pcall(function()
                    local gm = sdk.get_managed_singleton("app.GenerateManager")
                    SPAWN_METHOD:call(gm, p.pc, p.gi, 0, p.ii, nil, nil)
                end)
                summon_trace(p.species, string.format(
                    "ready in %.1fs, spawn call %s",
                    os.clock() - p.t0,
                    ok2 and "OK" or ("THREW: " .. tostring(err2))))
                S.status = "summon: " .. p.species
                    .. (ok2 and " spawn requested" or " spawn THREW")
                S.summon_keep = S.summon_keep or {}
                S.summon_keep[#S.summon_keep + 1] = p
                drop = true
            end
        end
        if drop then table.remove(SUMMON.pending, index) end
    end
    if #SUMMON.pending == 0 then SUMMON.pending = nil end
end)

-- COUPLES LAW: position writes only stick in LateUpdateBehavior — the
-- on_frame costume pin fought the horse's own systems at 60Hz ("spazzing
-- like crazy", 07-23). Post-pose application is the cure.
local function dismount_hold_tick()
    local hold = S.dismount_hold
    if not hold then return end
    local now = os.clock()
    -- 08-06 round 3: the every-frame position pin made the landing a
    -- REPEATED ground-hit loop (place -> micro-fall -> land -> re-place).
    -- New shape: DON'T pin. Watch for single-frame YANKS (nothing legit
    -- displaces the player 1.5m in one frame) and counter only those,
    -- back to wherever she actually was; the safe-coord feed follows her
    -- own movement so walking away stays legal.
    pcall(function()
        local tf = player_game_object():call("get_Transform")
        local pos = tf:call("get_UniversalPosition")
        local px = tonumber(pos.x) or 0.0
        local py = tonumber(pos.y) or 0.0
        local pz = tonumber(pos.z) or 0.0
        local lx = tonumber(hold.lx) or hold.x
        local ly = tonumber(hold.ly) or hold.y
        local lz = tonumber(hold.lz) or hold.z
        local dx, dy, dz = px - lx, py - ly, pz - lz
        local d2 = dx * dx + dy * dy + dz * dz
        if d2 > 2.25 then
            pos.x, pos.y, pos.z = lx, ly, lz
            tf:call("set_UniversalPosition", pos)
            log(string.format(
                "dismount hold: yank countered (%.1fm)", math.sqrt(d2)))
            px, py, pz = lx, ly, lz
        end
        hold.lx, hold.ly, hold.lz = px, py, pz
    end)
    feed_player_safe_position(
        tonumber(hold.lx) or hold.x,
        tonumber(hold.ly) or hold.y,
        tonumber(hold.lz) or hold.z, true)
    -- forensics (08-06, the perpetual-fall pose after dismount): name the
    -- action the body is actually stuck in -- the log tells us which exit
    -- action to request instead of guessing one
    if now >= (tonumber(hold.diag_at) or 0.0) then
        hold.diag_at = now + 0.8
        pcall(function()
            local pl = player_character()
            local am = nil
            pcall(function() am = pl["<ActionManager>k__BackingField"] end)
            if not am then pcall(function() am = pl:call("get_ActionManager") end) end
            if not am then return end
            local l0 = "-"
            pcall(function()
                local it = am.CurrentActionList[0]
                l0 = tostring(it.Name or it:call("get_Name"))
            end)
            log("dismount action L0: " .. l0)
        end)
    end
    -- Seed the landing coordinate before waking the two components that
    -- cache/restore player position. The LateUpdate write then wins the
    -- same frame if either component still attempts a stale snap.
    if not hold.components_restored
        and now >= (tonumber(hold.restore_at) or now) then
        restore_player_components()
        hold.components_restored = true
    end
    if now > (tonumber(hold.hold_until) or now) then
        if not hold.components_restored then restore_player_components() end
        feed_player_safe_position(
            tonumber(hold.lx) or hold.x,
            tonumber(hold.ly) or hold.y,
            tonumber(hold.lz) or hold.z, true)
        S.dismount_hold = nil
    end
end

local function costume_release_tick()
    local release = S.costume_release
    if not release then return end
    local now = os.clock()
    if now < (tonumber(release.wake_at) or now) then return end

    -- A fresh mount may have reclaimed this same body during the grace window.
    -- In that case its AI must remain parked under the saddle's ownership.
    local active_addr = S.costume and object_address(S.costume.horse_go) or nil
    if active_addr and active_addr == release.addr then
        S.costume_release = nil
        rawset(_G, "IrisMountReleaseAddr", nil)
        return
    end

    if now <= (tonumber(release.expires) or now) and valid(release.go) then
        pcall(function()
            local fsm = get_component(release.go, "via.motion.MotionFsm2")
            if fsm then fsm:call("set_Enabled", true) end
        end)
        pcall(function()
            if release.character then
                release.character:call("set_IsThinkStop", false)
            end
        end)
        -- Never wake the native evaluator here. IrisTaming sees the address marker
        -- above and resumes Shadow/Puma through its puppet follow on this same body.
        pcall(function()
            local ai = get_component(release.go, "app.AIDecisionMaker")
            if ai then ai:call("set_Enabled", false) end
            local nav = get_component(release.go, "app.NavigationAI")
            if nav then nav:call("set_Enabled", false) end
            if release.character then
                release.character:call("set_IsThinkStop", true)
            end
            local fsm = get_component(release.go, "via.motion.MotionFsm2")
            if fsm then fsm:call("set_Enabled", false) end
        end)
        log("wyrm mount release: native decision/nav parked; tame puppet follow owns body")
    end
    S.costume_release = nil
    rawset(_G, "IrisMountReleaseAddr", nil)
end

re.on_application_entry("LateUpdateBehavior", function()
    if S.generation ~= GENERATION then return end
    costume_tick()
    dismount_hold_tick()
    costume_release_tick()
end)

-- HAND MAGNET (07-24, Aurora's ask — the griffin round-32 port): each
-- hand is pulled onto a grip point beside the horse's neck via 2-bone
-- arm IK in POSITION space: law-of-cosines elbow -> minimal-twist locals
-- against the LIVE clavicle world -> SEEDED euler extraction (branch
-- continuity). Bone-local writes = PrepareRendering-legal (couples law).
-- Self-contained math on purpose (the griffin's LUA locals trap).
local function seat_hand_magnet_apply()
    if C.hand_magnet == false then return end
    local costume = S.costume
    if not (S.ride_pose_on and costume and costume.seat
        and valid(costume.horse_go)) then return end
    -- only once seated (the vault animates the arms itself)
    if costume.seat.pose_stage ~= "loop" then return end
    local player_go = costume.seat.player_go
    if not valid(player_go) then return end
    local ptf, horse_tf, np = nil, nil, nil
    pcall(function() ptf = player_go:call("get_Transform") end)
    pcall(function() horse_tf = costume.horse_go:call("get_Transform") end)
    if not (ptf and horse_tf) then return end
    pcall(function()
        -- 07-24 "IK isn't working on the griffin": the grip joint is
        -- per-variant now — the griffin's Neck_0 sits a body-length away
        -- from the rider, so the passenger variant gets its own joint
        -- (panel dropdown, scanned from the mounted body's real skeleton)
        local grip_name = C.hand_grip_joint or "Neck_0"
        if costume.passenger_only then
            grip_name = C.hand_grip_joint_griffin or grip_name
        end
        local nj = horse_tf:call("getJointByName", tostring(grip_name))
        np = nj and nj:call("get_Position")
    end)
    if not np then return end
    local fwd = horse_tf:call("get_AxisZ")
    local gyaw = math.atan(fwd.x, fwd.z)
    local fwx, fwz = math.sin(gyaw), math.cos(gyaw)
    local rgx, rgz = math.cos(gyaw), -math.sin(gyaw)
    local GW = seat_cfg("hand_grip_width", 0.22)
    local GH = seat_cfg("hand_grip_up", 0.05)
    local GF = seat_cfg("hand_grip_fwd", 0.10)
    local function v(x, y, z) return {x = x, y = y, z = z} end
    local function vsub(a, b) return v(a.x - b.x, a.y - b.y, a.z - b.z) end
    local function vadd(a, b) return v(a.x + b.x, a.y + b.y, a.z + b.z) end
    local function vscale(a, s) return v(a.x * s, a.y * s, a.z * s) end
    local function vlen(a)
        return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
    end
    local function vnorm(a)
        local l = vlen(a)
        if l < 1e-9 then return v(0, 0, 1) end
        return vscale(a, 1.0 / l)
    end
    local function vcross(a, b)
        return v(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z,
            a.x * b.y - a.y * b.x)
    end
    local function vdot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
    local function m3_mul(a, b)
        local r = {{0, 0, 0}, {0, 0, 0}, {0, 0, 0}}
        for i = 1, 3 do
            for j = 1, 3 do
                r[i][j] = a[i][1] * b[1][j] + a[i][2] * b[2][j]
                    + a[i][3] * b[3][j]
            end
        end
        return r
    end
    local function m3_mulv(m, p)
        return v(m[1][1] * p.x + m[1][2] * p.y + m[1][3] * p.z,
                 m[2][1] * p.x + m[2][2] * p.y + m[2][3] * p.z,
                 m[3][1] * p.x + m[3][2] * p.y + m[3][3] * p.z)
    end
    local function m3_tmulv(m, p) -- transpose multiply
        return v(m[1][1] * p.x + m[2][1] * p.y + m[3][1] * p.z,
                 m[1][2] * p.x + m[2][2] * p.y + m[3][2] * p.z,
                 m[1][3] * p.x + m[2][3] * p.y + m[3][3] * p.z)
    end
    local function quat_m3(q)
        local x = tonumber(q.x) or 0.0
        local y = tonumber(q.y) or 0.0
        local z = tonumber(q.z) or 0.0
        local w = tonumber(q.w) or 1.0
        return {{1 - 2 * (y * y + z * z), 2 * (x * y - z * w),
                 2 * (x * z + y * w)},
                {2 * (x * y + z * w), 1 - 2 * (x * x + z * z),
                 2 * (y * z - x * w)},
                {2 * (x * z - y * w), 2 * (y * z + x * w),
                 1 - 2 * (x * x + y * y)}}
    end
    local function axis_m3(a, ang)
        local c, s, C1 = math.cos(ang), math.sin(ang), 1.0 - math.cos(ang)
        local x, y, z = a.x, a.y, a.z
        return {{c + x * x * C1, x * y * C1 - z * s, x * z * C1 + y * s},
                {y * x * C1 + z * s, c + y * y * C1, y * z * C1 - x * s},
                {z * x * C1 - y * s, z * y * C1 + x * s, c + z * z * C1}}
    end
    local function rot_between(a, b)
        a, b = vnorm(a), vnorm(b)
        local ax = vcross(a, b)
        local s = vlen(ax)
        local c = math.max(-1.0, math.min(1.0, vdot(a, b)))
        if s < 1e-9 then
            if c > 0 then
                return {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}
            end
            local p = vnorm(vcross(a,
                math.abs(a.y) < 0.9 and v(0, 1, 0) or v(1, 0, 0)))
            return axis_m3(p, math.pi)
        end
        return axis_m3(vnorm(ax), math.atan(s, c))
    end
    local function m3_euler_seeded(m, seed)
        -- engine R = Ry@Rx@Rz; pick the branch closest to the seed
        local exb = math.asin(math.max(-1.0, math.min(1.0, -m[2][3])))
        local best, bd = nil, 1e9
        for _, exc in ipairs({exb, math.pi - exb}) do
            local eyc, ezc
            if math.abs(math.cos(exc)) > 1e-6 then
                eyc = math.atan(m[1][3], m[3][3])
                ezc = math.atan(m[2][1], m[2][2])
            else
                eyc = math.atan(-m[3][1], m[1][1])
                ezc = 0.0
            end
            local t = {exc, eyc, ezc}
            for i = 1, 3 do
                while t[i] - seed[i] > math.pi do
                    t[i] = t[i] - 2.0 * math.pi
                end
                while t[i] - seed[i] < -math.pi do
                    t[i] = t[i] + 2.0 * math.pi
                end
            end
            local d = math.abs(t[1] - seed[1]) + math.abs(t[2] - seed[2])
                + math.abs(t[3] - seed[3])
            if d < bd then bd, best = d, t end
        end
        return best[1], best[2], best[3]
    end
    S.hand_seed = S.hand_seed or {}
    for _, sd in ipairs({{side = "L", sx = 1.0}, {side = "R", sx = -1.0}}) do
        pcall(function()
            local side, sx = sd.side, sd.sx
            local uj = ptf:call("getJointByName", side .. "_Arm_Upper")
            local lj = ptf:call("getJointByName", side .. "_Arm_Lower")
            local hj = ptf:call("getJointByName", side .. "_Arm_Hand")
            local cj = ptf:call("getJointByName", side .. "_Arm_Clavicle")
            if not (uj and lj and hj and cj) then return end
            local Sp = uj:call("get_Position")
            local Ep = lj:call("get_Position")
            local Hp = hj:call("get_Position")
            local cq = cj:call("get_Rotation")
            if not (Sp and Ep and Hp and cq) then return end
            local SP = v(tonumber(Sp.x) or 0, tonumber(Sp.y) or 0,
                tonumber(Sp.z) or 0)
            local EP = v(tonumber(Ep.x) or 0, tonumber(Ep.y) or 0,
                tonumber(Ep.z) or 0)
            local l1 = vlen(vsub(EP, SP))
            local l2 = vlen(vsub(v(tonumber(Hp.x) or 0,
                tonumber(Hp.y) or 0, tonumber(Hp.z) or 0), EP))
            if l1 < 0.05 or l2 < 0.05 then return end
            local T = v((tonumber(np.x) or 0) + rgx * (sx * GW) + fwx * GF,
                        (tonumber(np.y) or 0) + GH,
                        (tonumber(np.z) or 0) + rgz * (sx * GW) + fwz * GF)
            local D = vsub(T, SP)
            local d = math.max(math.abs(l1 - l2) + 0.01,
                math.min(l1 + l2 - 0.01, vlen(D)))
            local t0 = vnorm(D)
            local cosA = math.max(-1.0, math.min(1.0,
                (l1 * l1 + d * d - l2 * l2) / (2.0 * l1 * d)))
            -- elbow pole: outward + down, elbows bow away from the body
            local pole = vnorm(v(rgx * sx, -0.6, rgz * sx))
            local axis = vcross(t0, pole)
            if vlen(axis) < 1e-6 then axis = v(0, 1, 0) end
            local updir = vnorm(m3_mulv(
                axis_m3(vnorm(axis), math.acos(cosA)), t0))
            local elbow = vadd(SP, vscale(updir, l1))
            local foredir = vnorm(vsub(T, elbow))
            local Wc = quat_m3(cq)
            local Xax = v(sx, 0, 0) -- +X on L, -X on R (mirrored-rig law)
            local ubase = uj:call("get_BaseLocalRotation")
            local lbase = lj:call("get_BaseLocalRotation")
            if not (ubase and lbase) then return end
            local Ru_rest = quat_m3(ubase)
            local Ru = m3_mul(rot_between(m3_mulv(Ru_rest, Xax),
                m3_tmulv(Wc, updir)), Ru_rest)
            local Wup = m3_mul(Wc, Ru)
            local Rl_rest = quat_m3(lbase)
            local Rl = m3_mul(rot_between(m3_mulv(Rl_rest, Xax),
                m3_tmulv(Wup, foredir)), Rl_rest)
            local ks = S.hand_seed[side]
            if not ks then
                local cu = uj:call("get_LocalEulerAngle")
                local cl = lj:call("get_LocalEulerAngle")
                ks = {
                    u = {tonumber(cu and cu.x) or 0,
                         tonumber(cu and cu.y) or 0,
                         tonumber(cu and cu.z) or 0},
                    l = {tonumber(cl and cl.x) or 0,
                         tonumber(cl and cl.y) or 0,
                         tonumber(cl and cl.z) or 0},
                }
            end
            local ux, uy, uz = m3_euler_seeded(Ru, ks.u)
            local lx, ly, lz = m3_euler_seeded(Rl, ks.l)
            ks.u = {ux, uy, uz}
            ks.l = {lx, ly, lz}
            S.hand_seed[side] = ks
            uj:call("set_LocalEulerAngle", Vector3f.new(ux, uy, uz))
            lj:call("set_LocalEulerAngle", Vector3f.new(lx, ly, lz))
        end)
    end
end

-- render-phase pass — BONES ONLY (couples law), registered LAZILY at the
-- first mount of each script generation. NOT at load: alphabetical load
-- order puts IrisHorseRodeo BEFORE rs_anim_lab, so a load-time
-- registration runs BEFORE the lab paints and the lab overwrites the IK
-- arms every frame (07-24 "grip IK isn't working" — the griffin dodged
-- this identically: its limbfit/hand-magnet pass registers at first play)
local function ensure_bone_pass()
    if S.bone_pass_generation == GENERATION then return end
    S.bone_pass_generation = GENERATION
    re.on_application_entry("PrepareRendering", function()
        if S.generation ~= GENERATION then return end
        seat_bone_apply()
        seat_hand_magnet_apply()
    end)
end

-- ---------------------------------------------------------------------------
-- MOUNT CAMERA (the IrisCreatureCam/griffin recipe): while the seat is
-- locked, a post-hook on MainCameraController.lateUpdate makes OUR chase
-- pose the final word each frame. The native camera tracking a physics-
-- suppressed, seat-pinned player is what "vibrates the camera and player
-- like crazy" — it samples the mover mid-frame, before the seat pin lands.
-- Owning the camera outright is the griffin's proven cure (killed the
-- vibration, the occlusion fade AND the muffled audio in one stroke).
-- ---------------------------------------------------------------------------
local function mountcam_m3_to_quat(m)
    -- Shepperd's method (griffin_m3_to_quat, verified by hand)
    local t = m[1][1] + m[2][2] + m[3][3]
    local x, y, z, w
    if t > 0.0 then
        local s = math.sqrt(t + 1.0) * 2.0
        w = 0.25 * s
        x = (m[3][2] - m[2][3]) / s
        y = (m[1][3] - m[3][1]) / s
        z = (m[2][1] - m[1][2]) / s
    elseif m[1][1] > m[2][2] and m[1][1] > m[3][3] then
        local s = math.sqrt(1.0 + m[1][1] - m[2][2] - m[3][3]) * 2.0
        w = (m[3][2] - m[2][3]) / s
        x = 0.25 * s
        y = (m[1][2] + m[2][1]) / s
        z = (m[1][3] + m[3][1]) / s
    elseif m[2][2] > m[3][3] then
        local s = math.sqrt(1.0 + m[2][2] - m[1][1] - m[3][3]) * 2.0
        w = (m[1][3] - m[3][1]) / s
        x = (m[1][2] + m[2][1]) / s
        y = 0.25 * s
        z = (m[2][3] + m[3][2]) / s
    else
        local s = math.sqrt(1.0 + m[3][3] - m[1][1] - m[2][2]) * 2.0
        w = (m[2][1] - m[1][2]) / s
        x = (m[1][3] + m[3][1]) / s
        y = (m[2][3] + m[3][2]) / s
        z = 0.25 * s
    end
    local l = math.sqrt(x * x + y * y + z * z + w * w)
    if l < 1e-9 then return nil end
    return {x = x / l, y = y / l, z = z / l, w = w / l}
end

-- r33 (Aurora: "the camera goes a bit crazy running around" = the lens
-- buried in scenery): fraction (0..1] of the look->camera segment that
-- is CLEAR of static world. r34: PRIVATE ray rig -- mountcam runs
-- inside the camera lateUpdate HOOK, and sharing the probe's query/
-- result objects with its frame-loop casts risked concurrent mutation
-- = garbage fractions = the camera yanking randomly near scenery
-- (plausibly the r33 "still crazy"). Own instances, same native method.
local CAMRAY = {}
local function camray_ensure()
    if CAMRAY.ready then return true end
    local ok = pcall(function()
        CAMRAY.system = sdk.get_native_singleton("via.physics.System")
        CAMRAY.method = sdk.find_type_definition("via.physics.System")
            :get_method(
                "castRay(via.physics.CastRayQuery, via.physics.CastRayResult)")
        CAMRAY.contact_td = sdk.find_type_definition(
            "via.physics.ContactPoint")
        CAMRAY.query = sdk.create_instance(
            "via.physics.CastRayQuery"):add_ref()
        CAMRAY.result = sdk.create_instance(
            "via.physics.CastRayResult"):add_ref()
        CAMRAY.query:clearOptions()
        CAMRAY.query:enableAllHits()
        CAMRAY.query:enableNearSort()
        CAMRAY.filter = CAMRAY.query:get_FilterInfo()
    end)
    CAMRAY.ready = ok and CAMRAY.system ~= nil and CAMRAY.method ~= nil
        and CAMRAY.query ~= nil and CAMRAY.result ~= nil
        and CAMRAY.filter ~= nil
    return CAMRAY.ready == true
end
local function mountcam_wall_pull(lx, ly, lz, cx, cy, cz)
    local frac = 1.0
    pcall(function()
        local mkv = rodeo_vec3   -- r62: was a nil _G fetch (see rodeo_vec3)
        if not (camray_ensure() and mkv) then return end
        CAMRAY.filter:set_Group(0)
        CAMRAY.filter:set_Layer(2) -- static world, like the ground casts
        CAMRAY.filter:set_MaskBits(0)
        CAMRAY.result:clear()
        CAMRAY.query:call("setRay(via.vec3, via.vec3)",
            mkv(lx, ly, lz), mkv(cx, cy, cz))
        CAMRAY.method:call(CAMRAY.system, CAMRAY.query, CAMRAY.result)
        local n = CAMRAY.result:get_NumContactPoints() or 0
        if n <= 0 then return end
        local contact = CAMRAY.result:call(
            "getContactPoint(System.UInt32)", 0) -- NearSort: 0 = nearest
        local pos = contact and sdk.get_native_field(
            contact, CAMRAY.contact_td, "Position")
        if not pos then return end
        local dx, dy, dz = cx - lx, cy - ly, cz - lz
        local seg = math.sqrt(dx * dx + dy * dy + dz * dz)
        if seg < 0.05 then return end
        local hx, hy, hz = pos.x - lx, pos.y - ly, pos.z - lz
        local hd = math.sqrt(hx * hx + hy * hy + hz * hz)
        -- stop 0.35m short of the wall; r53: floor raised 12% -> 30%
        -- of the boom -- the native camera never slams to extreme
        -- close-up either, and the sudden zoom WAS the gallop surprise
        -- ⭐ r64 (08-09): r62 finally made this code RUN for the first
        -- time, and the log immediately showed why it reads as a spaz:
        -- five engagements, pulling to 0.30 / 0.31 / 0.38 / 0.48 / 0.51.
        -- A drop to 0.30 of a 6.5m boom is a lurch from 6.5m to 2m --
        -- correct as occlusion avoidance, far too violent as a camera.
        -- The floor is the single most effective knob: 0.55 keeps the
        -- rider framed and turns the lurch into a lean-in.
        -- r66: 0.55 -> 0.70. Aurora's log shows the surviving incidents are all
        -- pulls to 0.55-0.56 (the ones at 0.83 pass unnoticed), so the floor is
        -- still doing the visible damage. 0.70 keeps the boom at 70% minimum.
        -- A 70% floor is visually gentle but physically wrong: on a steep bank
        -- or close wall it deliberately leaves the lens beyond the collision,
        -- which is the ground/scenery penetration that makes the view flip or
        -- whip. Keep only a small framing floor and prioritise a valid lens.
        frac = math.max(tonumber(C.mountcam_pull_floor) or 0.0,
            math.min(1.0, (hd - 0.35) / seg))
        -- r34 deadzone: a sliver of railing right at the lens isn't
        -- worth moving for
        if frac > 0.92 then frac = 1.0 end
    end)
    return frac
end

local function mountcam_apply()
    if C.mountcam_enabled == false then
        S.mountcam_state, S.mountcam_look = nil, nil
        S.mountcam_kick_release = nil
        S.mountcam_occl, S.mountcam_pull = 0, 1.0   -- r77: clear WITH the state
        return
    end
    -- MENU GUARD v2 (07-23: PauseManager was the wrong oracle — DD2's
    -- menus don't pause the world. The community-proven check is
    -- app.GuiManager:isPausedGUI(), used by Nick's core + Bestiary).
    -- Stand down while any paused-GUI is up; state is kept so the view
    -- resumes exactly where it was.
    do
        local menu_open = false
        pcall(function()
            local gui = sdk.get_managed_singleton("app.GuiManager")
            menu_open = gui and gui:call("isPausedGUI") == true
        end)
        if menu_open then return end
    end
    local ride_live = S.ride_pose_on and S.costume
        and valid(S.costume.horse_go)
    -- ⭐ 08-07 r15 (the r13/r14 A/B settled it: cc_sync + hold-mask =
    -- clean dismount, cc_sync alone = camera-first teleport): the native
    -- camera pivot still needs a beat to re-converge after the
    -- components wake, and the hold-mask is what bridges it. But blind
    -- 6s reads as "stuck riding camera" (Aurora r14) -- so the mask now
    -- releases the MOMENT the native camera's own computed position
    -- (read each frame BEFORE our overwrite) is back within 7m of the
    -- player. Cap = hold end (6s), the r9 worst case.
    local hold = S.dismount_hold
    if not ride_live then
        if not hold or hold.cam_released then
            S.mountcam_state, S.mountcam_look = nil, nil
            S.mountcam_anchor_raw = nil
            S.mountcam_wyrm_anchor, S.mountcam_wyrm_t = nil, nil
            S.mountcam_kick_release = nil
            S.mountcam_occl, S.mountcam_pull = 0, 1.0   -- r77: clear WITH the state
            return
        end
        pcall(function()
            local cam = sdk.get_primary_camera()
            local ct = cam and cam:call("get_GameObject")
                :call("get_Transform")
            local cp = ct and ct:call("get_Position")
            local pp = player_game_object():call("get_Transform")
                :call("get_Position")
            if cp and pp then
                local dx = cp.x - pp.x
                local dy = cp.y - pp.y
                local dz = cp.z - pp.z
                local d2 = dx * dx + dy * dy + dz * dz
                if d2 < 49.0 then
                    hold.cam_released = true
                    log(string.format(
                        "mountcam handover: native cam converged (%.1fm)",
                        math.sqrt(d2)))
                    -- Native convergence is the handover.  Replaying a captured
                    -- CameraReset.request looked attractive, but Nullable<T>
                    -- parameters cannot be reconstructed by passing Lua nil.  The
                    -- wolf field log caught a native access violation on every
                    -- dismount here, so the unsafe replay is deliberately gone.
                end
            end
        end)
        if hold.cam_released then
            S.mountcam_state, S.mountcam_look = nil, nil
        S.mountcam_occl, S.mountcam_pull = 0, 1.0   -- r77: clear WITH the state
            return
        end
    end
    local anchor_go
    if ride_live then
        -- anchor to the OX: it's the live-physics body the engine settles
        -- BEFORE cameras run; the horse shell is written late each frame
        -- and reading it here serves last-frame positions (the shake)
        anchor_go = valid(S.costume.ox_go) and S.costume.ox_go
            or S.costume.horse_go
    else
        -- dismount bridge: follow the PLAYER until native converges
        anchor_go = player_game_object()
        if not valid(anchor_go) then
            S.mountcam_state, S.mountcam_look = nil, nil
        S.mountcam_occl, S.mountcam_pull = 0, 1.0   -- r77: clear WITH the state
            return
        end
    end
    local horse_tf = anchor_go:call("get_Transform")
    local hp_raw = horse_tf:call("get_Position") -- render space, like the cam
    local fwd = horse_tf:call("get_AxisZ")
    if not (hp_raw and fwd) then return end
    -- The render origin rebases during long/fast travel. hp_raw then jumps by
    -- many metres in one frame while the stored camera/look points remain in
    -- the old render space; smoothing that discontinuity is the spectacular
    -- gallop-away/return camera failure. Translate all stored camera state by
    -- the same rebase delta so the view is continuous across the new origin.
    local prev_anchor = S.mountcam_anchor_raw
    if type(prev_anchor) == "table" then
        local sx = hp_raw.x - prev_anchor.x
        local sy = hp_raw.y - prev_anchor.y
        local sz = hp_raw.z - prev_anchor.z
        local shift = math.sqrt(sx * sx + sy * sy + sz * sz)
        if shift > (tonumber(C.mountcam_rebase_threshold) or 4.0) then
            for _, point in ipairs({ S.mountcam_state, S.mountcam_look,
                                      S.mountcam_wyrm_anchor }) do
                if type(point) == "table" then
                    point.x, point.y, point.z =
                        point.x + sx, point.y + sy, point.z + sz
                end
            end
            S.mountcam_rebases = (tonumber(S.mountcam_rebases) or 0) + 1
            log(string.format("mountcam render rebase absorbed: %.1fm", shift))
        end
    end
    S.mountcam_anchor_raw = { x = hp_raw.x, y = hp_raw.y, z = hp_raw.z }
    -- WOLF/PANTHER CAMERA DECOUPLING (video 23:10/23:11): a ch223 run
    -- deliberately heaves its root on every stride. The old camera looked at
    -- that animated root, so its lens and aim bobbed with both locomotion and
    -- every attack. Track a virtual world anchor instead: x/z remain prompt;
    -- grounded y rejects stride-scale oscillation, while real jumps/falls and
    -- large terrain changes catch up quickly. Heading comes from our drive yaw
    -- rather than the animation's temporarily pitched transform.
    if ride_live and S.costume and S.costume.wyrm_kind then
        local now_w = os.clock()
        local dt_w = math.max(0.001, math.min(0.05,
            now_w - (tonumber(S.mountcam_wyrm_t) or now_w)))
        S.mountcam_wyrm_t = now_w
        local wa = S.mountcam_wyrm_anchor
        if type(wa) ~= "table" then
            wa = { x = hp_raw.x, y = hp_raw.y, z = hp_raw.z }
        else
            local axz = 1.0 - math.exp(-12.0 * dt_w)
            wa.x = wa.x + (hp_raw.x - wa.x) * axz
            wa.z = wa.z + (hp_raw.z - wa.z) * axz
            local yerr = hp_raw.y - wa.y
            local airborne = S.costume.jump or S.costume.fall_anim
                or math.abs(yerr) > 0.75
            local ay = 1.0 - math.exp(-(airborne and 9.0 or 2.0) * dt_w)
            wa.y = wa.y + yerr * ay
        end
        S.mountcam_wyrm_anchor = wa
        hp_raw = wa
        local yaw = tonumber(S.costume.wyrm_yaw)
        if yaw then fwd = { x = math.sin(yaw), y = 0.0, z = math.cos(yaw) } end
    else
        S.mountcam_wyrm_anchor, S.mountcam_wyrm_t = nil, nil
    end
    -- smooth the LOOK TARGET too — a raw look-at jitters the view axis
    -- even when the camera position is smoothed
    local a0 = math.max(0.02, math.min(1.0,
        tonumber(C.mountcam_smooth) or 0.12))
    local lk = S.mountcam_look
    if type(lk) ~= "table" then
        lk = {x = hp_raw.x, y = hp_raw.y, z = hp_raw.z}
    end
    lk.x = lk.x + (hp_raw.x - lk.x) * a0
    lk.y = lk.y + (hp_raw.y - lk.y) * a0
    lk.z = lk.z + (hp_raw.z - lk.z) * a0
    S.mountcam_look = lk
    local hp = lk
    local fl = math.sqrt(fwd.x * fwd.x + fwd.z * fwd.z)
    if fl < 1e-6 then return end
    local fx, fz = fwd.x / fl, fwd.z / fl
    local kick_cam = ride_live and S.costume and S.costume.kick or nil
    if not kick_cam then
        local attack_cam = S.wyrm_native_lease
        if attack_cam and attack_cam.cam_yaw then
            kick_cam = attack_cam
        end
    end
    local kick_release_mix = nil
    -- RIGHT-STICK ORBIT (Aurora 07-23): we own the camera, so native RS
    -- look is dead — read the stick ourselves. Yaw orbits around the
    -- mount and eases back behind it when idle; pitch raises/lowers.
    do
        local nowc = os.clock()
        local ldt = math.max(0.001, math.min(0.05,
            nowc - (tonumber(S.mountcam_orbit_t) or nowc)))
        S.mountcam_orbit_t = nowc
        local rsx, rsy = 0.0, 0.0
        pcall(function()
            local hid = sdk.get_native_singleton("via.hid.GamePad")
            local hid_type = sdk.find_type_definition("via.hid.GamePad")
            local device = sdk.call_native_func(
                hid, hid_type, "get_MergedDevice")
            local axis = device and device:call("get_AxisR")
            if axis then
                rsx = tonumber(axis.x) or 0.0
                rsy = tonumber(axis.y) or 0.0
            end
        end)
        if C.mountcam_invert_x then rsx = -rsx end
        if C.mountcam_invert_y then rsy = -rsy end
        local ryaw = tonumber(S.mountcam_orbit_yaw) or 0.0
        local rpit = tonumber(S.mountcam_orbit_pit) or 0.0
        local sens = math.rad(150.0)
        -- yaw sign settled by field test (07-23: "-" made left go right);
        -- NO idle recenter — the view HOLDS where you left it
        if not (kick_cam and kick_cam.cam_yaw)
            and math.abs(rsx) > 0.15 then
            ryaw = ryaw + rsx * sens * ldt
        end
        if not (kick_cam and kick_cam.cam_yaw)
            and math.abs(rsy) > 0.15 then
            rpit = rpit + rsy * sens * ldt * 0.6
        end
        local ymax, pmax = math.rad(150.0), math.rad(40.0)
        if ryaw > ymax then ryaw = ymax
        elseif ryaw < -ymax then ryaw = -ymax end
        if rpit > pmax then rpit = pmax
        elseif rpit < -pmax then rpit = -pmax end
        S.mountcam_orbit_yaw, S.mountcam_orbit_pit = ryaw, rpit
        if ryaw ~= 0.0 then
            local byaw = math.atan(fx, fz) + ryaw
            fx, fz = math.sin(byaw), math.cos(byaw)
        end
        S.mountcam_pitch_lift = math.sin(rpit)
    end
    -- KICK CAMERA: the boom keeps its pre-kick world heading while the horse
    -- pivots, then eases back to the live horse/orbit heading. Interpolating
    -- yaw (rather than direction vectors) avoids the zero-vector singularity
    -- at the midpoint of a near-180-degree kick turn.
    if kick_cam and kick_cam.cam_yaw then
        fx, fz = math.sin(kick_cam.cam_yaw), math.cos(kick_cam.cam_yaw)
        S.mountcam_kick_release = nil
    elseif type(S.mountcam_kick_release) == "table" then
        local kr = S.mountcam_kick_release
        local span = math.max(0.05, tonumber(kr.dur) or 0.65)
        local u = math.max(0.0, math.min(1.0,
            (os.clock() - (tonumber(kr.t0) or os.clock())) / span))
        kick_release_mix = u * u * (3.0 - 2.0 * u)
        local want = math.atan(fx, fz)
        local diff = want - (tonumber(kr.yaw) or want)
        while diff > math.pi do diff = diff - 2.0 * math.pi end
        while diff < -math.pi do diff = diff + 2.0 * math.pi end
        local yaw = (tonumber(kr.yaw) or want) + diff * kick_release_mix
        fx, fz = math.sin(yaw), math.cos(yaw)
        if u >= 1.0 then S.mountcam_kick_release = nil end
    end
    -- variant-aware (07-24 fade-to-black): 6.5m dead-behind sits the
    -- lens INSIDE a griffin's tail/wing volume — the probe's proven
    -- griffin framing is 11m back, 4m up, 2.5m to the side (3/4 angle)
    local dist = seat_cfg("mountcam_dist", 6.5)
    local h = seat_cfg("mountcam_height", 2.6)
        + (tonumber(S.mountcam_pitch_lift) or 0.0) * dist * 0.6
    local lookup = seat_cfg("mountcam_look_up", 1.4)
    local side = seat_cfg("mountcam_side", 0.0)
    if not ride_live then
        -- dismount bridge: normal third-person framing, not the wide
        -- riding view (r14 "camera stays as horse riding camera")
        dist, h, lookup, side = 4.2, 1.9, 1.5, 0.0
    end
    local a = math.max(0.02, math.min(1.0,
        tonumber(C.mountcam_smooth) or 0.12))
    local rgx, rgz = fz, -fx -- camera-right (the field-settled pair)
    local tx = hp.x - fx * dist + rgx * side
    local ty = hp.y + h
    local tz = hp.z - fz * dist + rgz * side
    local st = S.mountcam_state
    if type(st) ~= "table" then
        -- ⭐ r77: seed the boom from WHERE THE VIEW ACTUALLY IS, not from the
        -- target. `ride_live` depends on a per-frame valid() call, so a single
        -- transient false frame clears the state and hands that frame to the
        -- native camera -- and the old re-seed then snapped straight to the
        -- target boom position. That is a two-frame visible cut out of a
        -- one-frame flicker. Seeding from the live lens makes the recovery a
        -- smooth ease instead, so the flicker costs nothing visible.
        st = nil
        pcall(function()
            local cam0 = sdk.get_primary_camera()
            local xf0 = cam0 and cam0:call("get_GameObject")
                :call("get_Transform")
            local p0 = xf0 and xf0:call("get_Position")
            if p0 then st = {x = p0.x, y = p0.y, z = p0.z} end
        end)
        if type(st) ~= "table" then st = {x = tx, y = ty, z = tz} end
    end
    st.x = st.x + (tx - st.x) * a
    st.y = st.y + (ty - st.y) * a
    st.z = st.z + (tz - st.z) * a
    S.mountcam_state = st
    -- r33 wall pull-in: the smoothed boom stays the TRUTH (st); only
    -- the frame's EFFECTIVE lens position is pulled, so leaving the
    -- obstruction eases straight back to the normal framing
    -- r56 LOOK-AHEAD (Aurora: "I want to be able to see what's in
    -- front of me" -- raising the camera only steepened the stare at
    -- the horse's back, because the AIM POINT was the horse): the
    -- camera now looks at a point ahead of her along the heading,
    -- which levels the view toward the road. 0 = old behavior.
    local ahead = seat_cfg("mountcam_look_ahead", 6.0)
    local lax = hp.x + fx * ahead
    local laz = hp.z + fz * ahead
    local lyy = hp.y + lookup
    -- During auto-aim, look at the victim itself while leaving the camera boom
    -- on the preserved world heading. On release, blend that aim point back to
    -- the normal road look-ahead at the same rate as the boom.
    local kick_look = nil
    if kick_cam and kick_cam.cam_yaw and valid(kick_cam.aim_go) then
        pcall(function()
            local tp = kick_cam.aim_go:call("get_Transform")
                :call("get_Position")
            if tp then
                kick_look = { x = tp.x, y = tp.y + 1.2, z = tp.z }
                kick_cam.cam_look = kick_look
            end
        end)
    end
    if kick_look then
        lax, lyy, laz = kick_look.x, kick_look.y, kick_look.z
    elseif kick_release_mix and type(S.mountcam_kick_release) == "table"
        and type(S.mountcam_kick_release.look) == "table" then
        local old = S.mountcam_kick_release.look
        local keep = 1.0 - kick_release_mix
        lax = old.x * keep + lax * kick_release_mix
        lyy = old.y * keep + lyy * kick_release_mix
        laz = old.z * keep + laz * kick_release_mix
    end
    -- ⭐ 08-09 r61 -- THE OCCLUSION ANCHOR. (Aurora: "riding over long
    -- distances the camera completely teleports to somewhere else or looks
    -- weird before returning back to the horse -- I always assumed it was
    -- scenery blocking the camera.") It IS the occlusion path, but it is
    -- misaimed, and r56 is what misaimed it: when r33 was written the aim
    -- point WAS the mount, so pulling toward the aim point meant pulling in
    -- tight behind her. r56 moved the aim 6-7.5m out in FRONT and the pull
    -- silently travelled with it. Two consequences, both matching the report:
    --   * the ray now STARTS 7.5m ahead of the horse. Crest any rise at
    --     gallop and that origin is INSIDE the hillside, so the cast reports
    --     a hard hit at ~zero distance -- a false occlusion that rolling
    --     terrain at speed triggers over and over. Hence "long distances".
    --   * the pull then drags the lens toward that point, which is PAST the
    --     horse. She doesn't tuck in behind, she slingshots to the horse's
    --     nose -- "teleports somewhere else" -- and the r34 easing walks her
    --     back once the ray clears, which is the "returns to the horse" half.
    -- Occlusion is about being able to see THE HORSE, so anchor the ray AND
    -- the pull to the horse, and leave the AIM on the look-ahead point. Every
    -- r34/r53/r55 constant below is untouched -- only the anchor moves.
    -- ⛔⛔ r77 -- MY OWN r61 BUG. I said "anchor the ray to the horse" and then
    -- anchored it to `hp`, which is `lk` = S.mountcam_look -- the SMOOTHED look
    -- target, lerped at alpha 0.265. At a gallop that point trails the horse by
    -- metres, and cresting a rise it lags BELOW the terrain -- so the ray origin
    -- ends up buried inside the ground. A buried origin reports a contact at
    -- hd ~ 0, which drives frac negative, which math.max clamps straight up to
    -- the pull FLOOR -- i.e. every buried frame becomes a full-strength false
    -- engagement, and on a sustained slope it survives the 14-frame gate.
    -- That is precisely "plays up when running past certain things".
    -- hp_raw is the horse's ACTUAL transform position this frame. Use it.
    local pax, pay, paz = hp_raw.x,
        hp_raw.y + math.max(1.2, lookup), hp_raw.z
    local pull_t = mountcam_wall_pull(
        pax, pay, paz, st.x, st.y, st.z)
    -- r53 PERSISTENCE GATE (Aurora: "temperamental with scenery,
    -- riding fast takes you by surprise -- the standard camera
    -- doesn't do this"): the native camera only reacts to SUSTAINED
    -- occlusion. A branch/post flicking through the ray for a few
    -- frames at gallop is now IGNORED -- pull only engages after
    -- ~0.13s of continuous obstruction.
    if pull_t < 0.98 then
        S.mountcam_occl = (tonumber(S.mountcam_occl) or 0) + 1
    else
        S.mountcam_occl = 0
    end
    -- r64: gate widened 8 -> 14 frames (~0.23s). Terrain grazing the ray on a
    -- slope is the common false positive now that the cast actually runs, and
    -- a longer gate ignores it without touching genuine walls.
    local occl_gate = math.max(1, math.floor(tonumber(C.mountcam_occl_gate) or 5))
    if (tonumber(S.mountcam_occl) or 0) < occl_gate then pull_t = 1.0
    elseif (tonumber(S.mountcam_occl) or 0) == occl_gate then
        -- THE PROBE (r61): one line the frame an episode actually engages, so
        -- a camera lurch can be read straight off the log instead of guessed
        -- at. No hit = no line, so silence here means scenery is NOT the cause.
        log(string.format(
            "mountcam occlusion engaged: pull=%.2f (anchor = mount)", pull_t))
    end
    local pl = tonumber(S.mountcam_pull) or 1.0
    -- r34 (bridge test: railing posts crossing the ray made the boom
    -- PUMP): eased BOTH ways, in fast, out (r53) quicker than before
    -- r55: gentler engage (0.35 -> 0.22) -- "the camera suddenly in a
    -- different place for a second" was the confirmed-wall snap-in
    -- r64: engage softened 0.22 -> 0.10 (the snap-in was still the thing that
    -- read as "the camera is suddenly somewhere else"); release left quicker
    -- than engage so clearing a wall recovers promptly.
    -- Collision entry is a safety constraint, not a camera preference: never
    -- ease through a wall for several frames. Snap inside the hit, then ease
    -- back out once the boom is clear. This matches a normal third-person
    -- camera and prevents the underground rotation singularity.
    if pull_t < pl then pl = pull_t
    else pl = pl + (pull_t - pl) * 0.15 end
    S.mountcam_pull = pl
    -- pull toward the MOUNT (r61), keep the AIM on the look-ahead point below
    local ex = pax + (st.x - pax) * pl
    local ey = pay + (st.y - pay) * pl
    local ez = paz + (st.z - paz) * pl
    local dx = lax - ex
    local dy = lyy - ey
    local dz = laz - ez
    local l = math.sqrt(dx * dx + dy * dy + dz * dz)
    if l < 1e-6 then return end
    -- camera forward column = -look direction (engine looks along -Z).
    -- 07-23 field fix (upside-down world): the griffin's negated pair is
    -- wrong in THIS math — hand-check: cf=(0,0,-1) here gives right
    -- (-1,0,0), up = cf x right = (0,+1,0) = proper sky-up basis
    local cfx, cfy, cfz = -dx / l, -dy / l, -dz / l
    local rx, ry, rz = cfz, 0.0, -cfx
    local rl = math.sqrt(rx * rx + ry * ry + rz * rz)
    if rl < 1e-6 then return end
    rx, ry, rz = rx / rl, ry / rl, rz / rl
    local ux = cfy * rz - cfz * ry
    local uy = cfz * rx - cfx * rz
    local uz = cfx * ry - cfy * rx
    local q = mountcam_m3_to_quat(
        {{rx, ux, cfx}, {ry, uy, cfy}, {rz, uz, cfz}})
    if not q then return end
    local cam = sdk.get_primary_camera()
    local xf = cam and cam:call("get_GameObject"):call("get_Transform")
    if not xf then return end
    local p = xf:call("get_Position")
    p.x, p.y, p.z = ex, ey, ez
    xf:call("set_Position", p)
    local qq = xf:call("get_Rotation")
    qq.x, qq.y, qq.z, qq.w = q.x, q.y, q.z, q.w
    xf:call("set_Rotation", qq)
end

-- ---------------------------------------------------------------------------
-- MOUNT / DISMOUNT (the actual mounting, 07-23): climbing the costume IS
-- the mount request — once the native climb has you on the body, end the
-- climb (ghost-exit trio) and hand the rider to the seat pin + Wilds pose.
-- One code path for the auto-capture, the hotkey and the panel checkbox.
-- ---------------------------------------------------------------------------
-- LEG TRIMS (07-24 "only thing left is leg positions"): additive euler
-- trims through the anim lab's set_trim bridge — sculpt the straddle
-- live, per variant, mirrored L/R. Cleared on dismount.
local function apply_leg_trims()
    local pose = rawget(_G, "NB_Pose")
    if not (pose and type(pose.set_trim) == "function") then return end
    -- PER-LEG (07-24 "split the legs"): mirrored trims made asymmetric
    -- fixes impossible. Raw per-leg axes, no auto-mirroring — what the
    -- slider says is what the bone gets.
    for _, side in ipairs({"L", "R"}) do
        local pitch = math.rad(seat_cfg("leg_pitch_" .. side, 0.0))
        local splay = math.rad(seat_cfg("leg_splay_" .. side, 0.0))
        local knee = math.rad(seat_cfg("leg_knee_" .. side, 0.0))
        pcall(pose.set_trim, side .. "_Leg_Upper", pitch, 0.0, splay)
        pcall(pose.set_trim, side .. "_Leg_Lower", knee, 0.0, 0.0)
    end
end

local function clear_leg_trims()
    local pose = rawget(_G, "NB_Pose")
    if not (pose and type(pose.set_trim) == "function") then return end
    for _, bone in ipairs({"L_Leg_Upper", "R_Leg_Upper",
                           "L_Leg_Lower", "R_Leg_Lower"}) do
        pcall(pose.set_trim, bone, 0, 0, 0)
    end
end

-- GAIT-AWARE ride pose (Aurora 07-24): "calm" = the stationary Wilds
-- pose for stand/walk; "active" = the animated ride loop for trot/gallop
-- assignment (NOT `local function`) so it fills the forward declaration
-- above — costume_tick closed over that local
seat_play_ride_pose = function(variant)
    local pose = rawget(_G, "NB_Pose")
    if type(pose) ~= "table" or type(pose.play) ~= "function" then
        return "pose bridge MISSING (rs_anim_lab not loaded?)"
    end
    -- 1.29 = Aurora's tuned default (07-24)
    local speed = math.max(0.0, tonumber(C.ride_pose_speed) or 1.29)
    -- ANIMATED loop for the "moving" variants (horse trot/gallop = active;
    -- griffin ground-sprint = gsprint), static neutral for the rest
    local animated = (variant == "active" or variant == "gsprint")
    -- r51 (Aurora: "the non-static ride position is fine EVERY single
    -- time" -- ONLY the static neutral misbehaves, on the same seat
    -- and same paint machinery): calm now rides the SAME loop clip at
    -- low speed instead of the neutral -- whatever the neutral's paint
    -- fails to own, the loop demonstrably owns. Gentle idle sway
    -- replaces statue-still. Revert: calm_use_loop=false in config.
    local clip = (animated or C.calm_use_loop ~= false)
        and "rs_wilds_ride_loop" or "rs_wilds_ride_neutral"
    if not animated and C.calm_use_loop ~= false then
        -- r52: 0 = FROZEN on the loop's first frame (Aurora's ask) --
        -- the paint still re-asserts that frame every render frame,
        -- so it holds like a pose but with the loop's proven body
        speed = math.max(0.0, tonumber(C.calm_loop_speed) or 0.0)
    end
    -- ARMS-ONLY (07-24 ROUND-13, Aurora's insight): on the griffin, paint
    -- only the Wilds ARM/hand grip (set "Arms") and let the NATIVE climb
    -- cling own the body — the cling already reads as a mount; we just add
    -- arms holding the head. Full-body pose stays the horse's mode.
    -- r33 (Aurora: "sometimes she mounts with legs in a weird place"):
    -- arms-only left the LEGS to the native climb-on, whose end state
    -- VARIES by approach = the sideways-tuck mounts. "ArmsLegs" (new lab
    -- set) paints the straddle legs too but still skips Hip/Spine, so
    -- the hip-lift float that killed Full stays gone.
    local set = (S.costume and S.costume.arms_only) and "ArmsLegs" or "Full"
    local ok, played = pcall(pose.play, clip, "Arisen", set, true,
        speed, true)
    if ok and played ~= false then
        if S.costume and S.costume.seat then
            S.costume.seat.pose_variant = variant
        end
        apply_leg_trims() -- re-push this variant's leg sculpt
        return "ride pose [" .. tostring(variant) .. " -> " .. clip .. "]"
    end
    return "pose clip FAILED: " .. clip
end

-- ---------------------------------------------------------------------------
-- MIRRORED VAULT (07-24 Aurora: "detect which side the player mounts
-- from and mirror the animation" — horse AND griffin). Naive euler
-- mirroring (swap L/R, negate y/z) breaks on bones whose BIND pose is
-- not mirror-symmetric — this very clip's Hip carries a baked ~90°
-- roll. So mirror in MODEL space against the player's REAL skeleton:
-- chain the clip's locals through the live joint hierarchy to world
-- quats, reflect across the sagittal plane (q -> w,x,-y,-z + L/R
-- partner swap), pull back to locals through the mirrored parents, and
-- re-extract engine ZXY eulers with per-bone continuity seeding. One
-- button press writes rs_wilds_mountup_R.json; the mount picks the clip
-- by approach side.
-- ---------------------------------------------------------------------------

local function vault_mirror_available()
    if S.vault_mirror_ok == nil then
        local ok = false
        pcall(function()
            local c = json.load_file("Animations/rs_wilds_mountup_R.json")
            ok = type(c) == "table" and type(c.frames) == "table"
        end)
        S.vault_mirror_ok = ok
    end
    return S.vault_mirror_ok == true
end

local function generate_mirrored_vault()
    local clip = nil
    pcall(function()
        clip = json.load_file("Animations/rs_wilds_mountup.json")
    end)
    if type(clip) ~= "table" or type(clip.frames) ~= "table"
        or type(clip.bones) ~= "table" then
        return "source vault clip missing"
    end
    local player_go = player_game_object()
    local ptf = nil
    pcall(function() ptf = player_go and player_go:call("get_Transform") end)
    if not ptf then return "no player skeleton (be in-game)" end
    -- self-contained math (the LUA locals trap)
    local function qinv(q)
        return {w = q.w, x = -q.x, y = -q.y, z = -q.z}
    end
    local function euler_q(e) -- engine R = Ry@Rx@Rz
        local hx = (tonumber(e[1]) or 0) * 0.5
        local hy = (tonumber(e[2]) or 0) * 0.5
        local hz = (tonumber(e[3]) or 0) * 0.5
        local qy2 = {w = math.cos(hy), x = 0, y = math.sin(hy), z = 0}
        local qx2 = {w = math.cos(hx), x = math.sin(hx), y = 0, z = 0}
        local qz2 = {w = math.cos(hz), x = 0, y = 0, z = math.sin(hz)}
        return quat_mul(qy2, quat_mul(qx2, qz2))
    end
    local function mirror_q(q) -- reflect across the sagittal (YZ) plane
        return {w = q.w, x = q.x, y = -q.y, z = -q.z}
    end
    local function q_m3(q)
        local x = tonumber(q.x) or 0.0
        local y = tonumber(q.y) or 0.0
        local z = tonumber(q.z) or 0.0
        local w = tonumber(q.w) or 1.0
        return {{1 - 2 * (y * y + z * z), 2 * (x * y - z * w),
                 2 * (x * z + y * w)},
                {2 * (x * y + z * w), 1 - 2 * (x * x + z * z),
                 2 * (y * z - x * w)},
                {2 * (x * z - y * w), 2 * (y * z + x * w),
                 1 - 2 * (x * x + y * y)}}
    end
    local function q_euler_seeded(q, seed) -- the proven branch picker
        local m = q_m3(q)
        local exb = math.asin(math.max(-1.0, math.min(1.0, -m[2][3])))
        local best, bd = nil, 1e9
        for _, exc in ipairs({exb, math.pi - exb}) do
            local eyc, ezc
            if math.abs(math.cos(exc)) > 1e-6 then
                eyc = math.atan(m[1][3], m[3][3])
                ezc = math.atan(m[2][1], m[2][2])
            else
                eyc = math.atan(-m[3][1], m[1][1])
                ezc = 0.0
            end
            local t = {exc, eyc, ezc}
            for i = 1, 3 do
                while t[i] - seed[i] > math.pi do
                    t[i] = t[i] - 2.0 * math.pi
                end
                while t[i] - seed[i] < -math.pi do
                    t[i] = t[i] + 2.0 * math.pi
                end
            end
            local d = math.abs(t[1] - seed[1]) + math.abs(t[2] - seed[2])
                + math.abs(t[3] - seed[3])
            if d < bd then bd, best = d, t end
        end
        return best[1], best[2], best[3]
    end
    local function partner(nm)
        if nm:sub(1, 2) == "L_" then return "R_" .. nm:sub(3) end
        if nm:sub(1, 2) == "R_" then return "L_" .. nm:sub(3) end
        return nm
    end
    -- joint graph: clip bones + every ancestor + all partners
    local joints, parent_of = {}, {}
    local function note_joint(j)
        local nm = tostring(j:call("get_Name"))
        if joints[nm] then return nm end
        joints[nm] = j
        local p = nil
        pcall(function() p = j:call("get_Parent") end)
        if p then parent_of[nm] = note_joint(p) end
        return nm
    end
    for _, bname in ipairs(clip.bones) do
        local j = ptf:call("getJointByName", bname)
        if not j then return "player joint missing: " .. tostring(bname) end
        note_joint(j)
    end
    local extra = {}
    for nm in pairs(joints) do
        local pn = partner(nm)
        if not joints[pn] then extra[#extra + 1] = pn end
    end
    for _, pn in ipairs(extra) do
        local j = nil
        pcall(function() j = ptf:call("getJointByName", pn) end)
        if j then note_joint(j) end
    end
    local ordered = {}
    for nm in pairs(joints) do ordered[#ordered + 1] = nm end
    local function depth(nm)
        local d, p = 0, parent_of[nm]
        while p do d = d + 1; p = parent_of[p] end
        return d
    end
    table.sort(ordered, function(a, b)
        local da, db = depth(a), depth(b)
        if da ~= db then return da < db end
        return a < b
    end)
    local bind = {}
    for nm, j in pairs(joints) do
        local b = nil
        pcall(function() b = j:call("get_BaseLocalRotation") end)
        if not b then return "no bind rotation for " .. nm end
        bind[nm] = {w = tonumber(b.w) or 1, x = tonumber(b.x) or 0,
                    y = tonumber(b.y) or 0, z = tonumber(b.z) or 0}
    end
    local animated = {}
    for _, b in ipairs(clip.bones) do animated[b] = true end
    local function r5(v)
        return math.floor(v * 100000 + 0.5) / 100000
    end
    local out_frames, seeds = {}, {}
    for fi, frame in ipairs(clip.frames) do
        local localq, world = {}, {}
        for _, nm in ipairs(ordered) do
            local e = animated[nm] and frame[nm]
            localq[nm] = e and euler_q(e) or bind[nm]
            local pw = parent_of[nm] and world[parent_of[nm]]
            world[nm] = pw and quat_mul(pw, localq[nm]) or localq[nm]
        end
        local mworld = {}
        for _, nm in ipairs(ordered) do
            mworld[nm] = mirror_q(world[partner(nm)] or world[nm])
        end
        local of = {}
        for _, nm in ipairs(ordered) do
            if animated[nm] then
                local pw = parent_of[nm] and mworld[parent_of[nm]]
                local lq = pw and quat_mul(qinv(pw), mworld[nm])
                    or mworld[nm]
                local ex, ey, ez = q_euler_seeded(lq,
                    seeds[nm] or {0.0, 0.0, 0.0})
                seeds[nm] = {ex, ey, ez}
                of[nm] = {r5(ex), r5(ey), r5(ez)}
            end
        end
        out_frames[fi] = of
    end
    local out = {
        format = clip.format, space = clip.space, fps = clip.fps,
        frame_count = clip.frame_count, loop = clip.loop,
        bones = clip.bones, frames = out_frames,
        mirrored_from = "rs_wilds_mountup",
    }
    if type(clip.root_pos) == "table" then
        local rp = {}
        for i, p in ipairs(clip.root_pos) do
            rp[i] = {-(tonumber(p[1]) or 0), p[2], p[3]}
        end
        out.root_pos = rp
    end
    local wrote = false
    pcall(function()
        wrote = json.dump_file(
            "Animations/rs_wilds_mountup_R.json", out) ~= false
    end)
    S.vault_mirror_ok = nil -- re-probe next mount
    return wrote and "mirrored vault written (rs_wilds_mountup_R)"
        or "WRITE FAILED (json.dump_file)"
end

-- 07-24 Aurora's probe: x-ray every fall/climb/catch/grab state the
-- game holds on the player + the fade-owner singletons. Press once
-- during a REAL climb (jump and grab the griffin, no costume needed),
-- once mid-flight seated — the flags that differ are the attach levers.
local function run_fall_probe()
    pcall(function()
        local pl = player_character()
        local lines = {}
        for _, getter in ipairs({
            "get_IsClimbOnCharacter", "get_IsClimb",
            "get_IsFall", "get_IsInAir", "get_IsGrounded",
            "get_IsLanding", "get_IsCatch", "get_IsCaught",
            "get_IsHang",
        }) do
            pcall(function()
                local v = pl:call(getter)
                lines[#lines + 1] = getter .. "=" .. tostring(v)
            end)
        end
        -- FreeFallCtrl = the falling-state owner (the levitate mod's
        -- lever); dump its switches so we learn what turns "falling" OFF
        pcall(function()
            local ff = pl:call("get_FreeFallCtrl")
            lines[#lines + 1] = "FreeFallCtrl.IsActive="
                .. tostring(ff and ff:call("get_IsActive"))
            if ff then
                local names = {}
                for _, m in ipairs(
                    ff:get_type_definition():get_methods()) do
                    names[#names + 1] = tostring(m:get_name())
                end
                lines[#lines + 1] = "FreeFallCtrl methods: "
                    .. table.concat(names, ",")
            end
        end)
        -- fall/climb/catch/grab-named FIELDS on app.Character
        pcall(function()
            for _, f in ipairs(pl:get_type_definition():get_fields()) do
                local n = tostring(f:get_name())
                local lo = n:lower()
                if lo:find("fall", 1, true) or lo:find("climb", 1, true)
                    or lo:find("catch", 1, true)
                    or lo:find("grab", 1, true)
                    or lo:find("hang", 1, true) then
                    pcall(function()
                        lines[#lines + 1] = n .. "="
                            .. tostring(pl:get_field(n))
                    end)
                end
            end
        end)
        -- player COMPONENTS named Climb/Fall/Catch/Hang + every BOOLEAN
        -- field on them — the attach-flag hunt with evidence
        pcall(function()
            local comps = player_game_object():call("get_Components")
            for _, comp in ipairs(comps and comps:get_elements() or {}) do
                local tn = ""
                pcall(function()
                    tn = comp:get_type_definition():get_full_name()
                end)
                local lo = tn:lower()
                if lo:find("climb", 1, true) or lo:find("fall", 1, true)
                    or lo:find("catch", 1, true)
                    or lo:find("hang", 1, true) then
                    lines[#lines + 1] = "COMPONENT " .. tn
                    pcall(function()
                        for _, f in ipairs(
                            comp:get_type_definition():get_fields()) do
                            local fn = tostring(f:get_name())
                            local okv, v = pcall(function()
                                return comp:get_field(fn)
                            end)
                            if okv and type(v) == "boolean" then
                                lines[#lines + 1] = "  " .. tn .. "."
                                    .. fn .. "=" .. tostring(v)
                            end
                        end
                    end)
                end
            end
        end)
        -- FADE OWNER sweep: every managed singleton with Fade in its
        -- name + its method surface — names the black-painter so it can
        -- be hooked next round
        pcall(function()
            for _, sg in ipairs(sdk.get_managed_singletons()) do
                local tn = ""
                pcall(function()
                    tn = sg:get_type_definition():get_full_name()
                end)
                if tn:lower():find("fade", 1, true) then
                    local names = {}
                    pcall(function()
                        for _, m in ipairs(
                            sg:get_type_definition():get_methods()) do
                            names[#names + 1] = tostring(m:get_name())
                        end
                    end)
                    lines[#lines + 1] = "FADE SINGLETON " .. tn
                        .. " methods: " .. table.concat(names, ",")
                end
            end
        end)
        log.info("[HorseRodeo fallprobe] " .. table.concat(lines, " | "))
        S.status = "fall probe -> re log (" .. #lines .. " entries)"
    end)
end

local function seat_mount()
    local player_go = player_game_object()
    if not (valid(player_go) and S.costume
        and valid(S.costume.horse_go)) then return end
    if S.ride_pose_on then return end
    -- 08-13 crash guard window 2: no scale writes on the body during the vault
    -- (the crash lived at exactly this moment - endClimb trio + seat + scale write)
    pcall(function()
        _G.IrisScaleHoldAddr = { addr = object_address(S.costume.horse_go),
                                 untilt = os.clock() + 4.0 }
    end)
    -- ⛔⛔ 08-10 r97 -- NO MOUNTING A DOWNED HORSE. (Aurora: "you can mount the
    -- downed horse" -- still, after r67.) My r67 gate went into the GRIFFIN's
    -- griffin_rt_mount_tick, but horses never take that path: they have their
    -- own rodeo route, and this is its front door. The gate was real, it was
    -- just guarding a corridor the horse does not walk down.
    -- A downed body is HP-pinned, AI-off and animation-claimed; sitting on it
    -- puts the seat writer and the downed re-assert on the same body, which is
    -- how the actinter move crash starts.
    do
        local d_addr = nil
        pcall(function() d_addr = S.costume.horse_go:get_address() end)
        if d_addr and type(_G.IrisDownedAddrs) == "table"
            and _G.IrisDownedAddrs[d_addr] then
            log("mount refused: the horse is DOWN -- revive it first")
            return
        end
    end
    -- r47 SIDE-ONLY MOUNT (Aurora: "lock it so the horse can only be
    -- mounted from the sides to stop the broken mounting up
    -- animation"): nose/tail presses have NEVER produced a clean
    -- boarding across every round of this hunt -- refuse them. The
    -- press must come from a side sector (|side| dominates |fore|).
    if C.mount_side_only ~= false then
        local blocked = false
        pcall(function()
            local bgo = valid(S.costume.ox_go) and S.costume.ox_go
                or S.costume.horse_go
            local btf = bgo:call("get_Transform")
            local bp = btf:call("get_Position")
            local az = btf:call("get_AxisZ")
            local pp = player_go:call("get_Transform")
                :call("get_Position")
            local dx = pp.x - bp.x
            local dz = pp.z - bp.z
            local fore = dx * az.x + dz * az.z
            local sidem = math.sqrt(math.max(0.0,
                dx * dx + dz * dz - fore * fore))
            blocked = math.abs(fore) > sidem + 0.35
        end)
        if blocked then
            S.status = "mount refused - walk to her SIDE first"
            log("mount refused: press from the nose/tail sector")
            S.mount_cooldown_until = os.clock() + 0.4
            return
        end
    end
    -- the native climb must END before the pin owns the body — a live
    -- climb state fights the seat write (crest-vault bug family)
    pcall(function()
        local pc = player_character()
        pc:call("endClimb")
        pc:call("requestEndClimb")
        pc:call("set_IsSetClimbActionByRequest", false)
    end)
    -- r37: the trio above only ends a climb that already STARTED; the
    -- same press can leave a climb REQUEST in flight that lands next
    -- frame and steals the body (the r36 outlier mounts). This window
    -- makes the climb-block hooks swallow it.
    S.mount_climb_block_until = os.clock() + 1.5
    -- SEAT = the SPINE JOINT (07-23 night: root-anchor left the rider
    -- static while gait clips bob the body around the root — "she moves
    -- when the horse moves"; and scale drift moved the back relative to
    -- the root — "different position every mount"). Joint-anchor tracks
    -- the animated back itself; migration pulls root-era heights (1.55)
    -- down to the small above-the-spine offset this needs.
    if (tonumber(C.seat_above_joint) or 0.0) > 0.8 then
        C.seat_above_joint = 0.2
        pcall(save_config)
    end
    S.ride_pose_on = true
    _G.IrisRiddenNow = true -- same-frame mount transition guard for prompt/UI writers
    mounted_weapon_tick(true)
    S.seat_started = os.clock()
    S.seat_key_latch = true -- swallow the still-held grab key
    S.mount_climb_since = nil
    S.costume.seat = {
        player_go = player_go,
        horse_go = S.costume.horse_go,
        joint = find_seat_joint(S.costume.horse_go),
        -- DETERMINISTIC SEAT: zero base + saved sliders, every mount
        local_off = {0.0, 0.0, 0.0},
    }
    suppress_player_components(player_go)
    -- 08-07: the coordinate every suppressed system will REMEMBER all
    -- ride -- the dismount decides warp-vs-gentle by how far we got
    pcall(function()
        local p0 = universal_pos(player_go)
        if p0 then
            S.mount_origin = {x = p0.x, y = p0.y, z = p0.z}
            S.mount_last_safe_ground = {
                x = p0.x, y = p0.y, z = p0.z, at = os.clock(),
            }
            S.mount_safe_candidate = nil
            S.mount_water_cached = false
            S.mount_water_check_at = 0.0
        end
    end)
    -- r42 THE REAL THIEF (00:56 log: FallLoop request TOOK, action went
    -- VerticalJumpLanding, body STAYED ~1.75m fore of the root -- the
    -- rider is being RETURNED somewhere specific, not wandering): DD2's
    -- stuck-player rescue. The PosRotRecorder still holds the PRE-MOUNT
    -- spot as "safe"; a nose/butt mount = a 2m+ warp to the saddle =
    -- reads as stuck-in-collision, and the rescue warps her back
    -- harder than anything we write. Feed the recorder the horse's own
    -- ground position at mount (dismount already does this on its
    -- side); the ride keeps re-feeding from the enforcer tick.
    pcall(function()
        local hp0 = universal_pos(S.costume.horse_go)
        if hp0 then
            feed_player_safe_position(hp0.x, hp0.y, hp0.z, true)
        end
    end)
    -- r43 DETERMINISTIC PARK (Aurora's own diagnosis: "is it the leg
    -- position when pressing the mount button -- mid walking or
    -- standing still?" -- YES: the old park froze the native anim at
    -- WHATEVER frame the press caught, and everything the pose paint
    -- doesn't cover keeps that random frozen underlay). Fix with the
    -- proven action lever: command FallLoop (the parked state every
    -- clean mount rides in) FIRST, give it a beat to reset the body,
    -- THEN freeze -- same underlay every mount. The park itself
    -- (MotionFsm2 off + PlaySpeed 0) moves to the frame loop at
    -- seat.park_at; the vault paint covers the 0.2s gap visually.
    pcall(function()
        local pl = player_character()
        local am = nil
        pcall(function()
            am = pl["<ActionManager>k__BackingField"]
        end)
        if not am then am = pl:call("get_ActionManager") end
        am:call(
            "requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)",
            10, "FallLoop", 0)
    end)
    S.costume.seat.park_at = os.clock() + 0.2
    -- MOUNT-UP (07-24 v2, Aurora: "let the JUMP of the animation carry
    -- her"): the vault clip's own ROOT ARC (root_pos channel, emitted by
    -- the scene retargeter) drives the seat base — the real leap, not a
    -- slide. A smoothstep residual correction is distributed across the
    -- arc so it still lands EXACTLY on the saddle.
    pcall(function()
        local ox_tf = S.costume.ox_go:call("get_Transform")
        local ox_pos = ox_tf:call("get_UniversalPosition")
        local right = ox_tf:call("get_AxisX")
        -- r35 CANONICAL MOUNT (Aurora: "we just need it to be one
        -- single position every time"): the approach no longer picks
        -- anything. Every mount starts from the SAME flank point and
        -- plays the SAME unmirrored vault -- side-detect + mirrored
        -- clip RETIRED (a front approach used to coin-flip the side
        -- and pose-yoga at the shoulder for the whole enter lerp).
        -- vault_mirror_flip still honoured so a tuned config keeps
        -- its proven-correct handedness.
        local side = 1.0
        local fx = ox_pos.x + right.x * side * 1.1
        local fy = ox_pos.y + 0.05
        local fz = ox_pos.z + right.z * side * 1.1
        local mirrored = false
        if C.vault_mirror_flip == true then mirrored = not mirrored end
        local vault_clip = "rs_wilds_mountup"
        if mirrored and vault_mirror_available() then
            vault_clip = "rs_wilds_mountup_R"
        end
        S.costume.seat.mount_clip = vault_clip
        local enter = {
            t0 = os.clock(), dur = 1.7,
            fx = fx, fy = fy, fz = fz,
            -- approach facing: from the start point toward the saddle
            face_yaw = math.atan(ox_pos.x - fx, ox_pos.z - fz),
        }
        -- the clip's root arc (start-space: x lateral, y up, z forward)
        pcall(function()
            local clip = json.load_file(
                "Animations/" .. vault_clip .. ".json")
            local root = clip and clip.root_pos
            if type(root) == "table" and #root > 1 then
                enter.dur = #root / (tonumber(clip.fps) or 60)
                local peak = 0.0
                for _, rp in ipairs(root) do
                    if rp[2] > peak then peak = rp[2] end
                end
                if peak >= 0.15 then
                    -- real jump data (re-export with root motion ON)
                    enter.root = root
                    local cy = math.cos(enter.face_yaw)
                    local sy = math.sin(enter.face_yaw)
                    local last = root[#root]
                    enter.end_x = last[1] * cy + last[3] * sy
                    enter.end_y = last[2]
                    enter.end_z = -last[1] * sy + last[3] * cy
                else
                    -- 07-24: the carved FBX was travel-stripped (REE-CE
                    -- DisableRootMotion trap) — root arc is FLAT, so
                    -- synthesize the leap: parabolic hop over the ease
                    enter.jump = 0.45
                end
            end
        end)
        -- r28 (Aurora: "trim the mount animation by ~2s" -- the clip's
        -- tail is where the legs go funny): cap the vault window; the
        -- root arc just traverses faster and the calm pose takes over
        local vcap = tonumber(C.mount_vault_max_secs) or 1.6
        if (tonumber(enter.dur) or 1.7) > vcap then
            enter.dur = vcap
        end
        S.costume.seat.enter = enter
        S.costume.seat.enter_dur = enter.dur
    end)
    S.hand_seed = nil -- fresh IK seeds per mount
    -- grip-joint candidates for the panel dropdown (07-24 griffin IK):
    -- scanned from the mounted body's REAL skeleton, so it works for any
    -- future species without guessing bone names
    S.grip_joint_options = nil
    pcall(function()
        local tf = S.costume.horse_go:call("get_Transform")
        local joints = tf:call("get_Joints")
        local opts = {}
        for _, j in ipairs(joints and joints:get_elements() or {}) do
            local nm = nil
            pcall(function() nm = tostring(j:call("get_Name")) end)
            if nm and (nm:find("Neck") or nm:find("Head")
                or nm:find("Spine") or nm:find("Hip")) then
                opts[#opts + 1] = nm
            end
        end
        if #opts > 0 then S.grip_joint_options = opts end
    end)
    ensure_bone_pass() -- runtime registration = paints AFTER the lab
    local pose = rawget(_G, "NB_Pose")
    local pose_report
    if type(pose) ~= "table" or type(pose.play) ~= "function" then
        pose_report = "pose bridge MISSING (rs_anim_lab not loaded?)"
    else
        local ok, played = pcall(pose.play,
            S.costume.seat.mount_clip or "rs_wilds_mountup",
            "Arisen", "Full", false, 1.0, true)
        if ok and played ~= false then
            S.costume.seat.pose_stage = "mountup"
            -- hand off at 90%: the clip's final settle frames land her
            -- leaning over the neck (07-24 "lands a little weirdly") —
            -- the calm pose takes over just before, while the seat arc
            -- finishes underneath
            S.costume.seat.pose_until = os.clock()
                + (tonumber(S.costume.seat.enter_dur) or 1.7) * 0.9
            pose_report = "mount-up vault playing"
        else
            -- no mount-up clip on disk: straight to the seated pose
            S.costume.seat.enter = nil
            S.costume.seat.pose_stage = "loop"
            pose_report = seat_play_ride_pose("calm")
        end
    end
    S.seat_pose_report = pose_report
    S.status = "MOUNTED [" .. pose_report .. "] - "
        .. ((S.costume.passenger_only and "L3 to dismount")
            or (S.costume.wyrm_kind and "E/L3 to dismount")
            or "E/RT to dismount")
end

local function seat_dismount(reason)
    local caught_handoff = reason == "caught"
    local downed_handoff = reason == "downed"
    local recovery = S.mount_last_safe_ground or S.mount_origin
    local emergency_recovery = false
    local costume_at_release = S.costume
    -- Dismount is a hard transaction boundary, including a manual RT during
    -- an attack. Clear the mover before reading a landing position.
    S.wyrm_attack, S.wyrm_atk_until = nil, nil
    S.wyrm_atk_hold, S.wyrm_btn_prev = nil, nil
    if costume_at_release then
        costume_at_release.force_hold = nil
        costume_at_release.cur_speed = 0.0
    end
    emergency_recovery = costume_at_release
        and (costume_at_release.jump ~= nil
            or costume_at_release.fall_v ~= nil) or false
    pcall(function()
        local detector = rawget(_G, "griffin_downed_in_water")
        if detector and costume_at_release
            and detector(costume_at_release.horse_go) == true then
            emergency_recovery = true
        end
    end)
    if costume_at_release then
        -- The old dismount only released the rider pose. The mount's jump
        -- sequencer continued afterwards (confirmed by `jump seq: air` in the
        -- crash log), invalidating Mia while stale callbacks still held her
        -- components. Stop every airborne/drive writer synchronously.
        costume_at_release.jump = nil
        costume_at_release.fall_v = nil
        costume_at_release.fall_from = nil
        costume_at_release.fall_anim = nil
        costume_at_release.jump_land_until = nil
        costume_at_release.jump_settle_until = nil
        costume_at_release.jump_thud_pending = nil
        costume_at_release.drive_step = nil
        costume_at_release.wyrm_prev_upos = nil
        costume_at_release.idle_anchor = nil
    end
    -- ⭐ pose-only (griffin invert): we touched NOTHING native — no
    -- restores, no landing write (the climb owns her position and the
    -- probe ends the climb itself). Just stop painting the pose + clear
    -- our render trims, then let costume_stop tear the rest down.
    if S.costume and S.costume.pose_only then
        S.ride_pose_on = false
        S.pose_only_start_at = nil
        pcall(function()
            local pose = rawget(_G, "NB_Pose")
            if pose then pose.stop() end
        end)
        pcall(clear_leg_trims)
        S.mount_cooldown_until = os.clock() + 1.0
        S.status = "griffin pose overlay released"
        return
    end
    -- landing grace (07-24 "dying on landing"): the damage shield keeps
    -- covering the player briefly while components restore
    if not caught_handoff and S.costume and S.costume.passenger_only then
        S.player_shield_until = os.clock() + 3.0
    end
    S.ride_pose_on = false
    -- 07-23 "dismount mounts me again": you land NEXT TO the horse, and
    -- any grab press there starts a fresh climb the auto-capture happily
    -- re-seats — give the rider a window to actually walk away
    S.mount_cooldown_until = os.clock() + 2.5
    -- 07-23 "get down under the ground" + "teleports miles back to the
    -- mount point": the landing spot (beside the ox, at its root height —
    -- the ox root sits ON the ground) is computed FIRST, but written
    -- AFTER the restores below — a re-enabled CharacterController snaps
    -- the body back to its cached mount-time position if it gets the
    -- last word. A short re-assert window beats any late snap.
    local land = nil
    if not caught_handoff then pcall(function()
        local costume = S.costume
        local base = costume
            and (valid(costume.ox_go) and costume.ox_go
                or (valid(costume.horse_go) and costume.horse_go))
        if base then
            local base_tf = base:call("get_Transform")
            local pos = base_tf:call("get_UniversalPosition")
            local side = base_tf:call("get_AxisX")
            land = {
                x = pos.x + side.x * 1.4,
                y = pos.y + 0.15,
                z = pos.z + side.z * 1.4,
            }
            -- Root height is not reliable on slopes. Prefer the stable
            -- module's fully-universal terrain ray when it is available.
            pcall(function()
                local ground = rawget(_G, "route3_ground_below_uni")
                local hit = ground and ground(
                    land.x, pos.y + 1.5, land.z, 2.0, 8.0)
                if hit and tonumber(hit.y) then
                    land.y = tonumber(hit.y) + 0.15
                end
            end)
        end
    end) end
    -- 08-07 fallback (dismiss-while-riding): the horse can already be
    -- DESPAWNED when this runs -- land where the RIDER is, not beside a
    -- body that no longer exists (land=nil was the instant-warp-home bug)
    if not land and not caught_handoff then
        pcall(function()
            local pos = player_game_object():call("get_Transform")
                :call("get_UniversalPosition")
            land = {
                x = tonumber(pos.x), y = tonumber(pos.y),
                z = tonumber(pos.z),
            }
            local ground = rawget(_G, "route3_ground_below_uni")
            local hit = ground and ground(
                land.x, land.y + 1.5, land.z, 2.0, 8.0)
            if hit and tonumber(hit.y) then
                land.y = tonumber(hit.y) + 0.15
            end
        end)
    end
    if recovery and (downed_handoff or emergency_recovery) then
        -- A seabed ray can be perfectly valid terrain while still being a lethal
        -- dismount. A sudden fall well below the last grounded ride point is an
        -- emergency even if the water component has not reported in yet.
        if not land or (tonumber(land.y) or recovery.y)
            < (tonumber(recovery.y) or 0.0) - 2.5 then
            emergency_recovery = true
        end
        if emergency_recovery then
            -- Recover the mount as part of the same transaction. Moving only
            -- the rider left Mia falling/drowning and allowed her downed system
            -- to invalidate the body underneath pending rodeo callbacks.
            local side_x, side_z = 1.0, 0.0
            pcall(function()
                local mtf = costume_at_release.horse_go:call("get_Transform")
                local side = mtf:call("get_AxisX")
                side_x, side_z = tonumber(side.x) or 1.0,
                    tonumber(side.z) or 0.0
                local mp = mtf:call("get_UniversalPosition")
                mp.x, mp.y, mp.z = tonumber(recovery.x),
                    tonumber(recovery.y), tonumber(recovery.z)
                mtf:call("set_UniversalPosition", mp)
            end)
            land = {
                x = tonumber(recovery.x) + side_x * 1.4,
                y = tonumber(recovery.y) + 0.15,
                z = tonumber(recovery.z) + side_z * 1.4,
            }
            log(string.format(
                "downed water/air recovery -> last grounded ride point %.2f %.2f %.2f",
                land.x, land.y, land.z))
        end
    end
    if S.costume then S.costume.seat = nil end
    if caught_handoff then S.dismount_hold = nil end
    -- 08-07 r13 (Aurora: "this teleporting nonsense is breaking the
    -- game" -- she's right): the TimeSkipManager warp + blackout rounds
    -- are GONE. The cause is cured upstream instead -- the ride tick now
    -- keeps every suppressed component's internal position current (the
    -- cc_sync block in costume_tick), so a dismount has nothing stale to
    -- snap back to and the gentle handover below is all that's needed.
    if land then
        pcall(function()
            local tf = player_game_object():call("get_Transform")
            local pos = tf:call("get_UniversalPosition")
            pos.x, pos.y, pos.z = land.x, land.y, land.z
            tf:call("set_UniversalPosition", pos)
        end)
        feed_player_safe_position(land.x, land.y, land.z, true)
        -- Wake collision/hit immediately, but defer the two components
        -- that can restore their cached pre-mount coordinate.
        restore_player_components({
            ["via.physics.CharacterController"] = true,
            ["app.GroundFixer"] = true,
        })
    else
        restore_player_components()
    end
    pcall(function()
        local player_go = player_game_object()
        local fsm = get_component(player_go, "via.motion.MotionFsm2")
        if fsm then fsm:call("set_Enabled", true) end
    end)
    pcall(function()
        local motion = player_character():call("get_Motion")
        if motion then motion:call("set_PlaySpeed", 1.0) end
    end)
    clear_leg_trims()
    pcall(function()
        local pose = rawget(_G, "NB_Pose")
        if pose then pose.stop() end
    end)
    if land then
        -- Re-assert while the safe-coordinate recorder and controller
        -- adopt the new landing. This is a state handover, not a blind
        -- timer fighting an unchanged pre-mount cache.
        S.dismount_hold = {
            x = land.x, y = land.y, z = land.z,
            restore_at = os.clock() + 0.20,
            hold_until = os.clock() + 6.00,   -- yank-watch window (08-06 r3: watch, don't pin)
            components_restored = false,
        }
        log(string.format(
            "dismount handover -> %.2f %.2f %.2f (safe coord seeded)",
            land.x, land.y, land.z))
    end
    S.status = caught_handoff and "dismounted: native grab owns the rider"
        or (emergency_recovery and "dismounted: recovered to safe ground"
            or "dismounted")
    S.mount_last_safe_ground = nil
    S.mount_safe_candidate = nil
    S.mount_water_cached = nil
end

-- Public horse-mount bridge. The IRIS stable must never run its griffin
-- native-climb/smart-mount path on a horse: ch299011 has no compatible
-- climb latch, so that path merely teleports the player onto its back and
-- leaves them falling. Stable RT prepares this owner; this module consumes
-- the same RT press in its ordinary mount-capture tick.
local function horse_record_for(game_object)
    local address = object_address(game_object)
    local direct = address and REGISTRY[address]
    if direct and direct.kind == "horse" then return direct end
    for _, record in pairs(REGISTRY) do
        if record.kind == "horse" and valid(record.game_object)
            and object_address(record.game_object) == address then
            return record
        end
    end
    return nil
end

rawset(_G, "IrisHorseMount", {
    prepare = function(game_object, accept_current_grab)
        local record = horse_record_for(game_object)
        if not record then return false, "horse is not registered" end
        if not ready_tamed_mount(record) then
            return false, "horse mount could not be prepared"
        end
        if accept_current_grab == true then
            S.mount_press_latch = false
        end
        return true
    end,
    mount = function(game_object)
        local record = horse_record_for(game_object)
        if not record or not ready_tamed_mount(record) then return false end
        if not S.ride_pose_on then seat_mount() end
        return S.ride_pose_on == true
    end,
    dismount = function(game_object, reason)
        if not S.ride_pose_on then return false end
        if game_object and S.costume
            and object_address(game_object)
                ~= object_address(S.costume.horse_go) then
            return false
        end
        seat_dismount(reason)
        return true
    end,
    is_mounted = function(game_object)
        if not (S.ride_pose_on and S.costume) then return false end
        return not game_object or object_address(game_object)
            == object_address(S.costume.horse_go)
    end,
    begin_hit_reaction = function(game_object, seconds)
        if not (S.ride_pose_on and S.costume
            and object_address(game_object)
                == object_address(S.costume.horse_go)) then
            return false
        end
        local costume = S.costume
        -- Jump/fall/landing already own layer 0. A ground hit can borrow it;
        -- force_hold keeps the gait matcher from repainting the flinch.
        if costume.jump or costume.fall_anim or costume.jump_land_until
            or costume.force_hold then return false end
        costume.force_hold = true
        costume.hit_react_hold = true
        costume.hit_react_until = os.clock()
            + math.max(0.15, tonumber(seconds) or 0.9)
        return true
    end,
})

-- A boss grab must take ownership before startCatch validates the victim.
-- Normal dismount is deliberately unsuitable here: it moves the player beside
-- the horse and pins that landing for the camera hand-over, which would tear
-- apart the native catch constraint. This path only releases our seat, frozen
-- motion and suppressed components, leaving the player exactly where the boss
-- found them.
rawset(_G, "__iris_rodeo_surrender_to_catch", function(prey)
    -- Native Shadow maul proof.  This callback already sits on the engine's
    -- real CatchController.startCatch boundary, so a count here distinguishes
    -- an actual paired catch from the wolf merely playing its half of a clip.
    local lease = S.wyrm_native_lease
    if lease and lease.catch_move
        and object_address(prey) == object_address(lease.target) then
        lease.catch_start_seen = (tonumber(lease.catch_start_seen) or 0) + 1
        lease.catch_prey_addr = object_address(prey)
    end
    if not S.ride_pose_on then return false end
    local player = player_character()
    if not (prey and player
        and object_address(prey) == object_address(player)) then return false end
    seat_dismount("caught")
    S.catch_handoffs = (tonumber(S.catch_handoffs) or 0) + 1
    log("native boss grab: saddle ownership released before startCatch")
    return true
end)
if not rawget(_G, "__iris_rodeo_startcatch_handoff_hooked") then
    pcall(function()
        local td = sdk.find_type_definition("app.CatchController")
        local m = td and td:get_method(
            "startCatch(app.Character, app.CatchController.Setting, app.CatchInterpolator)")
        if not m then return end
        sdk.hook(m, function(args)
            local prey = nil
            pcall(function() prey = sdk.to_managed_object(args[3]) end)
            local handoff = rawget(_G, "__iris_rodeo_surrender_to_catch")
            if handoff then pcall(handoff, prey) end
        end, function(retval) return retval end)
        rawset(_G, "__iris_rodeo_startcatch_handoff_hooked", true)
    end)
end

-- Native wolf/great-cat maul capture.  The natural move is not one requestable
-- action: the predator opens, knocks the victim down, starts a paired catch,
-- carries it away and only then enters the grounded maul.  startCatch receives
-- the species-authored contract that joins those two characters.  Retain that
-- exact live Setting (and interpolator, when supplied) instead of fabricating
-- one from action names.  This hook observes only; it never changes arguments
-- or the return value of natural combat.
local function iris_wyrm_find_catch_owner(controller)
    if not controller then return nil end
    local owner = nil
    -- GriffinRideProbe already has the same scene lookup.  Reuse it when that
    -- module is loaded, but keep Horse Rodeo self-contained when it is not.
    pcall(function()
        local find_owner = rawget(_G, "griffin_predation_find_catch_owner")
        if find_owner then owner = find_owner(controller) end
    end)
    if owner then return owner end
    pcall(function()
        local sm = sdk.get_native_singleton("via.SceneManager")
        local smt = sdk.find_type_definition("via.SceneManager")
        local scene = sm and sdk.call_native_func(sm, smt, "get_CurrentScene()")
        local chars = scene and scene:call(
            "findComponents(System.Type)", sdk.typeof("app.Character"))
        for _, ch in ipairs(chars and chars:get_elements() or {}) do
            if not owner then
                pcall(function()
                    local cc = ch and ch:call("get_CatchController")
                    if cc and object_address(cc) == object_address(controller) then
                        owner = ch
                    end
                end)
            end
        end
    end)
    return owner
end

local function iris_wyrm_dump_catch_contract(catcher, prey, setting, interp)
    local out = {
        captured_at = os.date("%Y-%m-%d %H:%M:%S"),
        catcher_id = "?", catcher_name = "?", prey_id = "?",
        setting_type = "?", interpolator_type = interp and "present" or "nil",
        fields = {},
    }
    pcall(function() out.catcher_id = tostring(catcher:call("get_CharaIDString") or "?") end)
    pcall(function()
        local go = catcher:call("get_GameObject")
        out.catcher_name = tostring(go and go:call("get_Name") or "?")
    end)
    pcall(function() out.prey_id = tostring(prey:call("get_CharaIDString") or "?") end)
    pcall(function() out.setting_type = tostring(setting:get_type_definition():get_full_name()) end)
    pcall(function() out.interpolator_type = tostring(interp:get_type_definition():get_full_name()) end)
    pcall(function()
        local td = setting:get_type_definition()
        while td do
            local declaring = tostring(td:get_full_name() or "?")
            for _, field in ipairs(td:get_fields() or {}) do
                pcall(function()
                    if not field:is_static() then
                        local value = field:get_data(setting)
                        local kind = type(value)
                        if kind ~= "nil" and kind ~= "number"
                            and kind ~= "boolean" and kind ~= "string" then
                            value = tostring(value)
                        end
                        out.fields[#out.fields + 1] = {
                            declaring_type = declaring,
                            name = tostring(field:get_name() or "?"),
                            type = tostring(field:get_type():get_full_name() or "?"),
                            value = value,
                        }
                    end
                end)
            end
            td = td:get_parent_type()
        end
    end)
    pcall(function()
        json.dump_file("IrisHorseRodeo_wolf_catch_setting.json", out)
    end)
end

rawset(_G, "__iris_wyrm_capture_ch223_catch", function(controller, prey, setting, interp)
    if not (controller and setting) then return false end
    local catcher = iris_wyrm_find_catch_owner(controller)
    if not catcher then return false end
    local chara_id = ""
    pcall(function()
        chara_id = tostring(catcher:call("get_CharaIDString") or ""):lower()
    end)
    if not chara_id:match("^ch223") then return false end

    local kept_setting, kept_interp = setting, interp
    pcall(function() kept_setting = setting:add_ref() or setting end)
    if interp then
        pcall(function() kept_interp = interp:add_ref() or interp end)
    end
    S.wyrm_catch_setting = kept_setting
    S.wyrm_catch_interpolator = kept_interp
    rawset(_G, "IrisWyrmNativeCatchSetting", kept_setting)
    rawset(_G, "IrisWyrmNativeCatchInterpolator", kept_interp)

    local prey_id = "?"
    pcall(function() prey_id = tostring(prey:call("get_CharaIDString") or "?") end)
    S.wyrm_catch_capture_status = string.format(
        "CAPTURED %s catch (prey %s)", chara_id, prey_id)
    iris_wyrm_dump_catch_contract(catcher, prey, kept_setting, kept_interp)
    log("native wolf catch contract: " .. S.wyrm_catch_capture_status
        .. " -> data/IrisHorseRodeo_wolf_catch_setting.json")
    return true
end)

-- A separate reload-safe hook is intentional.  Older Horse Rodeo builds have
-- already installed the hand-off closure above, and REFramework keeps hooks
-- across script resets.  The versioned guard lets this capture arrive without
-- requiring Aurora to restart the whole game.
if not rawget(_G, "__iris_wyrm_startcatch_capture_hooked_v1") then
    pcall(function()
        local td = sdk.find_type_definition("app.CatchController")
        local method = td and td:get_method(
            "startCatch(app.Character, app.CatchController.Setting, app.CatchInterpolator)")
        if not method then return end
        sdk.hook(method, function(args)
            local controller, prey, setting, interp = nil, nil, nil, nil
            pcall(function() controller = sdk.to_managed_object(args[2]) end)
            pcall(function() prey = sdk.to_managed_object(args[3]) end)
            pcall(function() setting = sdk.to_managed_object(args[4]) end)
            pcall(function() interp = sdk.to_managed_object(args[5]) end)
            local capture = rawget(_G, "__iris_wyrm_capture_ch223_catch")
            if capture then pcall(capture, controller, prey, setting, interp) end
        end, function(retval) return retval end)
        rawset(_G, "__iris_wyrm_startcatch_capture_hooked_v1", true)
    end)
end

-- A mounted ch223 has no valid native transition after the one-shot catch
-- success action, so its ordinary terminal callback dismantles a perfectly
-- accepted pair about 0.25s later. Retain only Horse Rodeo's current Y lease.
-- Dispatch through _G because REFramework hooks survive script resets while
-- this file's local S reference is refreshed.
rawset(_G, "__iris_wyrm_retain_catch_terminal", function(controller, side, label)
    local lease = S.wyrm_native_lease
    if not (lease and lease.retain_catch == true and lease.catch_move
        and S.ride_pose_on == true and lease.costume == S.costume) then
        return false
    end
    local expected = side == "catcher"
        and lease.catch_controller or lease.caught_controller
    if not (controller and expected
        and object_address(controller) == object_address(expected)) then
        return false
    end
    local active = false
    pcall(function() active = controller:call("get_IsActive") == true end)
    if not active then return false end -- allow startCatch's inactive reset work
    lease.retained_ends = (tonumber(lease.retained_ends) or 0) + 1
    lease.last_retained_end = tostring(side) .. "." .. tostring(label)
    if lease.retained_ends <= 8 then
        log("native maul retained premature " .. lease.last_retained_end)
    end
    return true
end)

local function iris_wyrm_install_catch_retention_hook(type_name, signature, side)
    local td = sdk.find_type_definition(type_name)
    local method = td and td:get_method(signature)
    if not method then return false end
    sdk.hook(method, function(args)
        local controller = nil
        pcall(function() controller = sdk.to_managed_object(args[2]) end)
        local retain = rawget(_G, "__iris_wyrm_retain_catch_terminal")
        local block = false
        if retain then pcall(function()
            block = retain(controller, side, signature) == true
        end) end
        return block and sdk.PreHookResult.SKIP_ORIGINAL
            or sdk.PreHookResult.CALL_ORIGINAL
    end, function(retval) return retval end)
    return true
end

if not rawget(_G, "__iris_wyrm_catch_retention_hooks_v1") then
    pcall(function()
        iris_wyrm_install_catch_retention_hook("app.CatchController",
            "endFromFsm(via.behaviortree.ActionArg)", "catcher")
        iris_wyrm_install_catch_retention_hook("app.CatchController",
            "abort(System.Boolean)", "catcher")
        iris_wyrm_install_catch_retention_hook("app.CatchController",
            "onFinish(System.Boolean)", "catcher")
        iris_wyrm_install_catch_retention_hook("app.CaughtController",
            "abort(System.Boolean)", "caught")
        iris_wyrm_install_catch_retention_hook("app.CaughtController",
            "abortDirect()", "caught")
        iris_wyrm_install_catch_retention_hook("app.CaughtController",
            "notifyAbort()", "caught")
        iris_wyrm_install_catch_retention_hook("app.CaughtController",
            "notifyEnd()", "caught")
        iris_wyrm_install_catch_retention_hook("app.CaughtController",
            "notifyEscape()", "caught")
        iris_wyrm_install_catch_retention_hook("app.CaughtController",
            "onFinish()", "caught")
        rawset(_G, "__iris_wyrm_catch_retention_hooks_v1", true)
    end)
end

-- the hook installs ONCE and dispatches through _G so script reloads keep
-- the camera alive (the trycatch-hook pattern used elsewhere in this file)
-- r45 LATE PIN (the r44 instrument's verdict: a native writer moves the
-- rider EVERY FRAME after our seat write -- constant ~2.3m back to the
-- press spot on nose/butt mounts, ~0.4m gravity sag even on good ones.
-- We stop trying to find-and-kill every writer and simply write LAST:
-- this rides the MainCameraController.lateUpdate hook, after the
-- frame's game logic. Their write still happens; OURS is the one that
-- renders -- the button-prompt law applied to the seat.)
local function seat_late_pin()
    if not S.ride_pose_on then return end
    local costume = S.costume
    local seat = costume and costume.seat
    if costume and (costume.pose_only or costume.passenger_only) then
        return
    end
    if not (seat and seat.last_wx and valid(seat.player_go)) then
        return
    end
    pcall(function()
        local tf = seat.player_go:call("get_Transform")
        local p = tf:call("get_UniversalPosition")
        p.x, p.y, p.z = seat.last_wx, seat.last_wy, seat.last_wz
        tf:call("set_UniversalPosition", p)
        -- r50: pin ROTATION late too (the off-angle-seat culprit)
        if seat.last_rw then
            local q = tf:call("get_Rotation")
            q.x, q.y, q.z, q.w = seat.last_rx, seat.last_ry,
                seat.last_rz, seat.last_rw
            tf:call("set_Rotation", q)
        end
    end)
end
-- r54 MOUNTED BUTTON PROMPTS (Aurora: RT=Dismount, RB/LB/LT/Y blank,
-- X=Kick, B=Gallop; A/Jump stays native): the proven set_Message
-- recipe (read from Puppeteer, griffin_ride_hud_tick parity).
-- ⛔ set_Message ONLY -- writing PlayStates into this GUI = CTD
-- (walled 08-05). Re-asserted every frame from the late hook because
-- the game rewrites the labels whenever the prompt set changes.
local HUD_GETOBJ = nil
local RIDE_HUD_INPUT_DEVICE = "pad"
local RIDE_HUD_INPUT_PROBE_AT = 0.0
local RIDE_HUD_LABELS = {
    {"PNL_top/PNL_R00/PNL_txt/mtx_00", "Dismount", dynamic = "rt"}, -- RT
    {"PNL_top/PNL_R01/PNL_txt/mtx_00", "", dynamic = "dodge_right"}, -- RB
    {"PNL_top/PNL_L00/PNL_txt/mtx_00", "", dynamic = "howl"}, -- LT
    {"PNL_top/PNL_L01/PNL_txt/mtx_00", "", dynamic = "dodge_left"}, -- LB
    -- Y: dynamic -- "Blessing" ONLY while the mount is a unicorn (written
    -- per-tick below; blank rows are never written, per the mount-CTD law).
    {"PNL_top/PNL_L02/PNL_txt/mtx_00", "", dynamic = "bless"},  -- Y
    {"PNL_top/PNL_L03/PNL_txt/mtx_00", "Kick", dynamic = "bite"}, -- X
    {"PNL_top/PNL_R02/PNL_txt/mtx_00", "Gallop", dynamic = "pace"}, -- B
}
local function horse_ride_hud_tick()
    if C.ride_hud == false or not S.ride_pose_on then
        -- This oracle describes ui010201, the MOUNTED prompt set. Publishing a
        -- fresh `false` while on foot made the companion-HP renderer mistake
        -- "not riding" for "the entire native HUD is hidden", even with the
        -- Arisen HP/stamina bars plainly visible. Expire the mounted oracle so
        -- the general player-vitals widget owns on-foot HUD visibility.
        rawset(_G, "IrisRideNativeHudVisible", nil)
        rawset(_G, "IrisRideNativeHudVisibleT", 0.0)
        return
    end
    local costume = S.costume
    if costume and (costume.pose_only or costume.passenger_only) then
        return
    end
    pcall(function()
        if not HUD_GETOBJ then
            HUD_GETOBJ = sdk.find_type_definition("via.gui.Control")
                :get_method("getObject(System.String)")
        end
        local scene = sdk.call_native_func(
            sdk.get_native_singleton("via.SceneManager"),
            sdk.find_type_definition("via.SceneManager"),
            "get_CurrentScene")
        local ui = scene:call("findGameObject(System.String)",
            "ui010201")
        local base = ui and get_component(ui, "app.GUIBase")
        local root = base and base.Root
        local native_visible = ui and ui:get_DrawSelf() == true
            and root ~= nil
        if native_visible then
            local actual = nil
            pcall(function() actual = root:call("get_ActualVisible") end)
            if actual ~= nil then native_visible = actual == true end
        end
        rawset(_G, "IrisRideNativeHudVisible", native_visible)
        rawset(_G, "IrisRideNativeHudVisibleT", os.clock())
        if not native_visible then return end

        -- The cooldown renderer must decorate the game's real button, not a
        -- guessed 1920x1080 coordinate. PNL_txt's next sibling is the native
        -- button artwork (the same relationship Better Oxcarts uses); reading
        -- its transform is harmless and follows UI scale, ultrawide layout and
        -- the keyboard/gamepad plaque swap automatically.
        pcall(function()
            local prompt = HUD_GETOBJ:call(root, "PNL_top/PNL_L02/PNL_txt")
            local button = prompt and prompt:call("get_Next")
            local pos = button and button:call("get_GlobalPosition")
            local sz = nil
            if button then pcall(function() sz = button:call("get_Size") end) end
            if pos then
                rawset(_G, "IrisBlessingNativeButton", {
                    x = tonumber(pos.x), y = tonumber(pos.y),
                    w = sz and (tonumber(sz.w) or tonumber(sz.x)) or nil,
                    h = sz and (tonumber(sz.h) or tonumber(sz.y)) or nil,
                    device = RIDE_HUD_INPUT_DEVICE,
                    pad_dx = tonumber(C.blessing_hud_pad_dx) or 0.0,
                    pad_dy = tonumber(C.blessing_hud_pad_dy) or 0.0,
                    keyboard_dx = tonumber(C.blessing_hud_keyboard_dx) or 0.0,
                    keyboard_dy = tonumber(C.blessing_hud_keyboard_dy) or 0.0,
                    size_scale = tonumber(C.blessing_hud_size) or 1.0,
                    t = os.clock(),
                })
            end
        end)

        -- DD2 changes the native glyph according to the last-used device. Keep
        -- the overlay in step: round for pad, rectangular for keyboard. This is
        -- deliberately sampled, not run through every input API every frame.
        local input_now = os.clock()
        if input_now >= RIDE_HUD_INPUT_PROBE_AT then
            RIDE_HUD_INPUT_PROBE_AT = input_now + 0.08
            pcall(function()
                local gp = sdk.get_native_singleton("via.hid.GamePad")
                local td = sdk.find_type_definition("via.hid.GamePad")
                local dv = gp and td and sdk.call_native_func(gp, td, "get_MergedDevice")
                if not dv then return end
                local bits = math.floor(tonumber(dv:call("get_Button")) or 0)
                local al = dv:call("get_AxisL")
                local ar = dv:call("get_AxisR")
                if bits ~= 0
                    or (al and (math.abs(tonumber(al.x) or 0) > 0.22
                        or math.abs(tonumber(al.y) or 0) > 0.22))
                    or (ar and (math.abs(tonumber(ar.x) or 0) > 0.22
                        or math.abs(tonumber(ar.y) or 0) > 0.22)) then
                    RIDE_HUD_INPUT_DEVICE = "pad"
                end
            end)
            pcall(function()
                for _, vk in ipairs({
                    0x57, 0x41, 0x53, 0x44, -- movement
                    0x45, 0x56, 0x59,       -- E / native V / fallback Y
                    0x10, 0x11, 0x20,       -- Shift / Ctrl / Space
                    0x25, 0x26, 0x27, 0x28,
                }) do
                    if reframework:is_key_down(vk) == true then
                        RIDE_HUD_INPUT_DEVICE = "keyboard"
                        break
                    end
                end
            end)
        end
        -- The transform was sampled just before the throttled device probe.
        -- Correct the published record in the same frame so the ring changes
        -- shape on the first keyboard/gamepad input, not one probe later.
        local blessing_button = rawget(_G, "IrisBlessingNativeButton")
        if type(blessing_button) == "table" then
            blessing_button.device = RIDE_HUD_INPUT_DEVICE
        end
        for _, row in ipairs(RIDE_HUD_LABELS) do
            -- ⛔⛔⛔ NEVER set_Message("") -- THE MOUNT CTD (2026-08-09, found by Aurora's
            -- own observation: "it works fine on the griffin and we use it for the
            -- homesteading too"). Same paths, same method, same phase in all three; the
            -- ONLY difference was that r54's table blanks RB/LT/LB/Y by writing an EMPTY
            -- STRING. The griffin learned this on 2026-08-04 and wrote the law in its own
            -- comment: "Blank now means exactly that: we do not write that slot at all and
            -- the game's own prompt stands." Emptying a live prompt makes the GUI re-lay
            -- out that panel -- while we are mid-iteration writing it every frame -- so the
            -- next write lands in a rebuilding panel, set_Message throws in native GUI code
            -- and the AV follows. The type guard below was necessary but NOT sufficient:
            -- the object is a genuine via.gui.Text, it is the EMPTY WRITE that detonates.
            local txt = tostring(row[2] or "")
            -- 08-12: dynamic Y slot -- "Blessing" only while the mount is a
            -- unicorn (never written otherwise, so the empty-write law holds).
            if row.dynamic == "rt" then
                txt = costume.wyrm_kind and "Maul" or "Dismount"
            elseif row.dynamic == "dodge_right" then
                txt = costume.wyrm_kind and "Dodge Right" or ""
            elseif row.dynamic == "dodge_left" then
                txt = costume.wyrm_kind and "Dodge Left" or ""
            elseif row.dynamic == "bless" then
                if costume.wyrm_kind then
                    txt = "Pounce"
                else
                    local isu = false
                    pcall(function()
                        local api = rawget(_G, "__iris_wild_horses_api")
                        isu = api and api.is_unicorn
                            and api.is_unicorn(costume.horse_go) or false
                    end)
                    txt = isu and "Blessing" or ""
                end
            elseif row.dynamic == "howl" then
                txt = costume.wyrm_kind == "cat" and "Roar"
                    or (costume.wyrm_kind and "Howl" or "")
            elseif row.dynamic == "pace" then
                txt = costume.wyrm_kind and "Sprint" or "Gallop"
            elseif row.dynamic == "bite" then
                txt = costume.wyrm_kind and "Bite Combo" or "Kick"
            end
            if txt == "" then
                -- opt-in only: a single space reads blank without taking the empty path.
                -- Default is the griffin's proven behaviour -- leave the slot alone.
                txt = tostring(C.ride_hud_blank_text or "")
            end
            if txt ~= "" then
            pcall(function()
                local obj = HUD_GETOBJ:call(root, row[1])
                if not obj then return end
                -- ⛔⛔ 2026-08-09 MOUNT CTD: the log's last line before c0000005 was
                -- "Exception thrown in REMethodDefinition::invoke for via.gui.Text.set_Message"
                -- (16ms earlier). getObject() returns whatever sits at that PATH -- there is
                -- no guarantee it is a via.gui.Text. During a prompt-set rebuild the slot can
                -- hold a different control type (or a half-constructed one), and calling
                -- set_Message on it throws inside the GUI system. ⛔ A pcall does NOT make
                -- that safe: the managed throw happens inside native GUI code and the AV
                -- follows it. VERIFY THE TYPE before writing, never just the nil-ness.
                local ok_t = false
                pcall(function()
                    local td = obj:get_type_definition()
                    while td do
                        if td:get_full_name() == "via.gui.Text" then ok_t = true; return end
                        td = td:get_parent_type()
                    end
                end)
                if ok_t then obj:call("set_Message", txt) end
            end)
            end
        end
    end)
end
rawset(_G, "__iris_rodeo_mountcam_apply", function()
    mountcam_apply()
    seat_late_pin()
end)
-- r55 (Aurora: "extremely quickly flickering between kick and
-- mightysweep... the blank ones aren't blank"): the camera hook fires
-- BEFORE the game's GUI label writer on some frames = alternating
-- winners = flicker. The griffin's hud tick never flickers because it
-- runs in LateUpdateBehavior -- after the GUI writer, every frame.
-- Same phase for ours.
re.on_application_entry("LateUpdateBehavior", function()
    if S.generation ~= GENERATION then return end
    horse_ride_hud_tick()
end)
if not rawget(_G, "__iris_rodeo_mountcam_hooked") then
    pcall(function()
        local td = sdk.find_type_definition("app.MainCameraController")
        local m = td and td:get_method("lateUpdate")
        if m then
            sdk.hook(m, function() end, function(retval)
                local apply = rawget(_G, "__iris_rodeo_mountcam_apply")
                if apply then pcall(apply) end
                return retval
            end)
            rawset(_G, "__iris_rodeo_mountcam_hooked", true)
        end
    end)
end
-- ⭐ POSE-ONLY mount (07-24 ROUND-10, THE INVERT — the fade fix): paint
-- our riding pose + hand IK + chase cam ON TOP of the probe's LIVE native
-- climb. The native climb owns position/physics/gravity/attach (so the
-- game NEVER sees a falling player = no fade, no fall-death, proven for
-- weeks). We own ONLY render-phase joints + the camera. ⛔ NO endClimb,
-- NO FSM park, NO PlaySpeed 0, NO component suppress, NO position pin, NO
-- vault (the native climb-on IS the boarding). This is why ROUNDS 1-9
-- faded: the old seat_mount ENDED the climb. Never again on the griffin.
local function seat_mount_pose_only()
    local player_go = player_game_object()
    if not (valid(player_go) and S.costume
        and valid(S.costume.horse_go)) then return end
    if S.ride_pose_on then return end
    S.ride_pose_on = true
    _G.IrisRiddenNow = true -- pose-only griffin/drake mount needs the same early guard
    S.seat_started = os.clock()
    S.seat_key_latch = true
    S.hand_seed = nil
    -- ARMS-ONLY default (Aurora's "native body + Wilds arms" insight)
    S.costume.arms_only = C.griffin_arms_only ~= false
    S.costume.seat = {
        player_go = player_go,
        horse_go = S.costume.horse_go,
        joint = find_seat_joint(S.costume.horse_go),
        local_off = {0.0, 0.0, 0.0},
        pose_stage = "loop", -- hand IK runs at once (no vault to wait on)
        pose_variant = "calm",
    }
    -- grip-joint dropdown candidates, scanned from the griffin's real rig
    S.grip_joint_options = nil
    pcall(function()
        local tf = S.costume.horse_go:call("get_Transform")
        local joints = tf:call("get_Joints")
        local opts = {}
        for _, j in ipairs(joints and joints:get_elements() or {}) do
            local nm = nil
            pcall(function() nm = tostring(j:call("get_Name")) end)
            if nm and (nm:find("Neck") or nm:find("Head")
                or nm:find("Spine") or nm:find("Hip")) then
                opts[#opts + 1] = nm
            end
        end
        if #opts > 0 then S.grip_joint_options = opts end
    end)
    ensure_bone_pass() -- PrepareRendering: seat_bone_apply + hand_magnet
    S.pose_only_start_at = nil
    -- MOUNT ANIMATION (07-24 ROUND-11 "no mount animation"): play the
    -- vault clip as a JOINT overlay while the native climb-on carries her
    -- up (the climb owns the position arc; we paint the boarding body
    -- motion). Then hand off to the riding pose. Pure joints — no
    -- position write, so it's fade-safe. Toggle: griffin_mount_anim.
    -- MOUNT ANIMATION: default = let the NATIVE climb-on play as the
    -- boarding (upright, correct). Our vault clip is OPT-IN (07-24 Aurora
    -- "the mount is horizontal" — the rs_wilds_mountup Hip carries a
    -- baked ~90° roll that reads flat when composed over the climb's own
    -- orientation; the native climb-on doesn't have that problem).
    local pose = rawget(_G, "NB_Pose")
    local did_vault = false
    if C.griffin_mount_anim == true
        and type(pose) == "table" and type(pose.play) == "function" then
        local ok, played = pcall(pose.play, "rs_wilds_mountup",
            "Arisen", "Full", false, 1.0, true)
        if ok and played ~= false then
            S.costume.seat.pose_stage = "mountup"
            S.costume.seat.pose_until = os.clock() + 2.5
            did_vault = true
        end
    end
    if not did_vault then
        -- hold OFF the riding pose long enough for the native climb-on to
        -- finish (else our pose snaps over the boarding). Tunable.
        S.pose_only_start_at = os.clock()
            + (tonumber(C.griffin_pose_delay) or 1.8)
    end
    S.seat_pose_report = "pose-only armed (climb stays alive)"
    S.status = "GRIFFIN pose overlay (climb-alive) - L3 to dismount"
end

-- ---------------------------------------------------------------------------
-- ⛔ _G.IrisPuppetSeat — GRIFFIN INTEGRATION REVERTED 07-24 (Aurora: "fully
-- revert the griffin, back to the horse tame"). The pose-only invert was
-- PROVEN to work (fade-free) but the tuning wasn't worth it. The bridge is
-- DISABLED here — set to nil so the griffin probe's iris_puppet_seat()
-- returns nil, every stand-down gate passes through, and the probe uses
-- its OWN native rider exactly as before. ⭐ This reverts the griffin
-- BEHAVIOUR from OUR side alone — ZERO probe edits (the other session is
-- live in that file). The probe's inert scaffolding (gates/config/push)
-- can be stripped later once its pen is free. The pose-only code below
-- (seat_mount_pose_only etc.) is now dead — never armed, harms nothing,
-- gated on costume.pose_only which is never set again.
-- To RE-ENABLE the experiment: restore the bridge table (git history).
-- ---------------------------------------------------------------------------
rawset(_G, "IrisPuppetSeat", nil)

local function pin_ghost_to_horse(horse_go, park)
    local ghost = S.ghost
    if not (ghost and valid(ghost.go) and valid(horse_go)) then return end
    pcall(function()
        local horse_tf = horse_go:call("get_Transform")
        local ghost_tf = ghost.go:call("get_Transform")
        local position = horse_tf:call("get_UniversalPosition")
        ghost_tf:call("set_UniversalPosition", position)
        ghost_tf:call("set_Rotation", horse_tf:call("get_Rotation"))
    end)
end

-- ---------------------------------------------------------------------------
-- Rodeo state machine
-- ---------------------------------------------------------------------------

-- NATIVE-CLIMB attachment (the griffin's proven foundation; their v1
-- "teleport high + no-arg startClimb" produced the exact "sends me flying"
-- ejection we hit — the fix is FLUSH placement + the full latch, then a
-- short watch for get_IsClimbOnCharacter. Do NOT think-stop the horse at
-- latch time: the climb FSM must run to consume the transition.)
local function fire_climb_latch(player, horse_go)
    local ctrl = nil
    pcall(function() ctrl = player:call("get_ClimbCtrl") end)
    local tags = {}
    local function step(tag, fn)
        local ok = pcall(fn)
        tags[#tags + 1] = tag .. (ok and "" or "!")
    end
    if ctrl then
        step("ctrl", function()
            ctrl:call("startClimb(via.GameObject, System.Boolean)",
                horse_go, false)
        end)
    end
    step("tgt", function() player:call("set_RequestClimbTarget", horse_go) end)
    step("byreq", function()
        player:call("set_IsSetClimbActionByRequest", true)
    end)
    step("start", function() player:call("startClimb(System.Boolean)", false) end)
    return table.concat(tags, " "), ctrl
end

local function player_climbing_on(player)
    local on = false
    pcall(function() on = player:call("get_IsClimbOnCharacter") == true end)
    return on
end

-- Stricter check for organic adoption: climbing state can go STALE across
-- experiments (a lingering true adopted phantom rides). Require the climb's
-- actual target to be OUR ghost.
local function player_climbing_target(player, go)
    if not valid(go) then return false end
    if not player_climbing_on(player) then return false end
    local target_address = nil
    pcall(function()
        local ctrl = player:call("get_ClimbCtrl")
        local target = ctrl and (ctrl:get_field("TargetRootObject")
            or ctrl:call("get_TargetRootObject"))
        target_address = target and object_address(target)
    end)
    return target_address ~= nil and target_address == object_address(go)
end

local function player_climbing_our_ghost(player)
    return S.ghost and player_climbing_target(player, S.ghost.go)
end

local function begin_rodeo(record)
    local player = player_character()
    local player_go = player_game_object()
    if not (player and player_go) then return end
    local horse_character = get_component(record.game_object, "app.Character")
    local ride = {
        horse_go = record.game_object,
        horse_character = horse_character,
        player = player,
        player_go = player_go,
        seat_joint = find_seat_joint(record.game_object),
        started = os.clock(),
        grip = C.grip_max,
        bucking = false,
        next_phase = os.clock() + 0.6,
        latch_until = os.clock() + 1.5,
        latched = false,
    }
    -- LATCH paths: ghost-rig (latch at the pinned donor) or GRAFT mode
    -- (latch at the HORSE ITSELF — she has a real climb surface now; the
    -- old refusal predates the graft).
    if (S.ghost and valid(S.ghost.go)) or S.graft_rig then
        ride.ghost_mode = true
        ride.latch_go = (S.ghost and valid(S.ghost.go)) and S.ghost.go
            or record.game_object
        ride.latch_until = os.clock() + 2.0
        ride.last_latch_fire = os.clock()
        -- the climb surface comes alive only for the ride. RSC ONLY — the
        -- ghost's solid hull stays OFF permanently (hull-on during ride =
        -- solid-vs-solid depenetration against the HORSE's hull = the harsh
        -- horse vibration, 07-22 round 2). The horse's own hull also sleeps
        -- for the ride so nothing can shove the anchored body.
        pcall(function()
            if S.ghost.rsc then S.ghost.rsc:call("set_Enabled", true) end
        end)
        -- ⭐⭐ 08-09 r66 -- THIS IS WHY THE CYCLOPS CANNOT HURT THE HORSE.
        -- (Aurora: "I've been letting a cyclops beat on me and my horse for
        -- about 10 minutes and the horse hasn't gone down -- is the horse not
        -- getting hit / does it not have a hitbox when being ridden?")
        -- Correct: via.physics.Colliders is switched OFF for the whole ride, so
        -- the horse has no hurtbox and nothing can land on it. It is not
        -- invincible by rule -- it is simply not there to be hit.
        -- The reason was solid-vs-solid depenetration causing the harsh horse
        -- vibration (07-22 r2) -- but that was the GHOST's hull fighting the
        -- HORSE's hull, and the ghost hull is now off PERMANENTLY (line above).
        -- With one side of that pair already gone, sleeping the horse too looks
        -- redundant, so it now stays awake by default and the horse can be
        -- fought over -- which is the whole point of the downed system.
        -- ⚠ IF THE HARSH VIBRATION COMES BACK, this is the switch: set
        -- ride_horse_colliders_off = true and it reverts exactly.
        pcall(function()
            if C.ride_horse_colliders_off ~= true then
                log("horse colliders: LEFT ON (hittable while ridden)")
                return
            end
            local horse_colliders = get_component(
                ride.horse_go, "via.physics.Colliders")
            if horse_colliders then
                horse_colliders:call("set_Enabled", false)
                ride.horse_colliders = horse_colliders
            end
        end)
        -- The horse holds still for the ride: controller off (it is about
        -- to be think-stopped anyway) so colliders cannot shove it. CC-off
        -- also removes GROUND SUPPORT (the trio sank through the world and
        -- died in the Brine — RIP horse & garm #3), so we anchor the
        -- horse's position per frame for the whole ride.
        pcall(function()
            local horse_tf = ride.horse_go:call("get_Transform")
            local p = horse_tf:call("get_UniversalPosition")
            ride.anchor = {x = p.x, y = p.y, z = p.z}
            ride.anchor_rot = horse_tf:call("get_Rotation")
        end)
        pcall(function()
            if ride.horse_character then
                ride.horse_character:call("setCharacterControllerEnable", false)
                ride.horse_cc_off = true
            end
        end)
        if S.ghost and valid(S.ghost.go) then
            pin_ghost_to_horse(ride.horse_go)
            place_player_on_ghost(player_go)
        else
            -- graft mode: flush on the horse's own back joint
            ride.seat_joint = find_seat_joint(ride.horse_go)
            write_player_seat(ride)
        end
        local tags = fire_climb_latch(player, ride.latch_go)
        rawset(_G, "__iris_horse_rodeo_active_addr",
            tostring(object_address(ride.horse_go)))
        S.ride = ride
        S.stage = "latching"
        S.status = "grabbing the ghost rig... [" .. tags .. "]"
        log("ghost climb latch fired [" .. tags .. "]")
        return
    end

    -- TRANSFORM-DRIVE hold (plan C, the griffin's pre-native-climb route):
    -- flush seat + character controller OFF + per-frame universal writes.
    -- (Native-climb latch on the DOE itself: REFUSED; climb-rig graft: CTD.
    --  Both retired 2026-07-21 — do not re-attempt on the horse body.)
    ride.latched = false
    dump_seat_spaces(ride)
    pcall(function()
        player:call("setCharacterControllerEnable", false)
        ride.cc_disabled = true
    end)
    if not write_player_seat(ride) then
        if ride.cc_disabled then
            pcall(function()
                player:call("setCharacterControllerEnable", true)
            end)
        end
        S.status = "could not place on the horse's back"
        return
    end
    -- PUPPET the player (the griffin file's designated transform-drive
    -- config): FSM off + parked animation = the pose overlay and our
    -- transform writes own the body; with the FSM live they lose ("the
    -- storm"). Taming's beyblade bug proved rotation writes DO render for
    -- a puppeted player.
    set_horse_fsm(player_go, false)  -- generic MotionFsm2 disable
    ride.player_fsm_off = true
    ride.pose_mode = freeze_player_pose(player_go)
    if ride.pose_mode == "wilds_pose" then
        -- park the underlying clip so it can't flicker through the overlay
        pcall(function()
            local character = get_component(player_go, "app.Character")
            local motion = character and character:call("get_Motion")
            if motion then motion:call("set_PlaySpeed", 0.0) end
        end)
    end
    if ride.horse_character then set_think_stop(ride.horse_character, true) end
    set_horse_fsm(ride.horse_go, false)
    rawset(_G, "__iris_horse_rodeo_active_addr",
        tostring(object_address(ride.horse_go)))
    S.ride = ride
    S.stage = "rodeo"
    S.status = "HOLD ON! (keep E / RT held)"
    play_horse_sound("alert", ride.horse_go)
    log("rodeo started (transform-drive hold; seat joint: "
        .. (ride.seat_joint and "found" or "root fallback") .. ")")
end

local function end_rodeo(outcome)
    local ride = S.ride
    S.ride = nil
    S.stage = "idle"
    rawset(_G, "__iris_horse_rodeo_active_addr", nil)
    if not ride then return end
    restore_player_components()
    unfreeze_player_pose(ride.player_go, ride.pose_mode)
    if ride.player_fsm_off then
        set_horse_fsm(ride.player_go, true)
    end
    -- ALWAYS cancel climb state in ghost mode — a latch the FSM consumes
    -- AFTER the watch window is how the oblivion elevator happened.
    if ride.ghost_mode and ride.player then
        pcall(function() ride.player:call("endClimb") end)
        pcall(function() ride.player:call("requestEndClimb") end)
        pcall(function()
            ride.player:call("set_IsSetClimbActionByRequest", false)
        end)
        pcall(function()
            if S.ghost and S.ghost.rsc then
                S.ghost.rsc:call("set_Enabled", false)
            end
            if S.ghost and S.ghost.colliders then
                S.ghost.colliders:call("set_Enabled", false)
            end
        end)
    elseif ride.latched and ride.player then
        pcall(function() ride.player:call("endClimb") end)
        pcall(function() ride.player:call("requestEndClimb") end)
        pcall(function()
            ride.player:call("set_IsSetClimbActionByRequest", false)
        end)
    end
    if ride.cc_disabled and ride.player then
        pcall(function()
            ride.player:call("setCharacterControllerEnable", true)
        end)
    end
    if valid(ride.horse_go) then
        set_horse_fsm(ride.horse_go, true)
        pcall(function()
            if ride.horse_colliders then
                ride.horse_colliders:call("set_Enabled", true)
            end
        end)
        if ride.horse_character then
            if ride.horse_cc_off then
                pcall(function()
                    ride.horse_character:call(
                        "setCharacterControllerEnable", true)
                end)
            end
            set_think_stop(ride.horse_character, false)
            -- FSM/controller/think restoration is sufficient.  The no-argument
            -- resetActionAndAI call does not match DD2's current native method and
            -- must not be issued during a decision-system handover.
        end
    end
    if outcome == "tamed" then
        local address = object_address(ride.horse_go)
        local record = address and REGISTRY[address]
        if record then record.tamed = true end
        S.tamed_count = S.tamed_count + 1
        S.status = "IT SETTLES. The horse is yours."
        play_horse_sound("snort", ride.horse_go)
    elseif outcome == "thrown" then
        S.thrown_count = S.thrown_count + 1
        S.status = "THROWN! It bolts. Try again."
        play_horse_sound("alert", ride.horse_go)
    else
        S.status = "released"
    end
    log("rodeo ended: " .. tostring(outcome))
end

local function latching_tick(now)
    local ride = S.ride
    if not ride then return end
    if player_climbing_on(ride.player) then
        ride.latched = true
        S.stage = "rodeo"
        S.status = "HOLD ON! (keep E / RT held)"
        -- NOW the rodeo owns the horse's body (never at latch time).
        if ride.horse_character then
            set_think_stop(ride.horse_character, true)
        end
        set_horse_fsm(ride.horse_go, false)
        play_horse_sound("alert", ride.horse_go)
        log("NATIVE CLIMB LATCHED on the horse - rodeo on")
        return
    end
    -- Re-fire the latch through the window (the climb FSM takes frames to
    -- consume it; ONE fire routinely reads as refused). CRASH LAW: never
    -- fire into an in-progress climb transition; throttle 0.45s.
    if ride.ghost_mode and valid(ride.latch_go)
        and now - (ride.last_latch_fire or 0) > 0.45 then
        local transitioning = false
        pcall(function()
            transitioning = ride.player:call("get_IsClimbing") == true
        end)
        if not transitioning then
            ride.last_latch_fire = now
            if S.ghost and valid(S.ghost.go) then
                pin_ghost_to_horse(ride.horse_go)
                place_player_on_ghost(ride.player_go)
            else
                write_player_seat(ride)
            end
            fire_climb_latch(ride.player, ride.latch_go)
        end
    end
    if now >= ride.latch_until then
        end_rodeo("refused")
        S.status = ride.ghost_mode
            and "the ghost refused the climb (watch window exhausted)"
            or "the horse refused the climb (no native rig?)"
    end
end

local function rodeo_tick(now)
    local ride = S.ride
    if not ride then return end
    if not (valid(ride.horse_go) and valid(ride.player_go)) then
        end_rodeo("lost")
        return
    end

    -- Player must keep holding on.
    if not grab_pressed() then
        end_rodeo("thrown")
        return
    end
    if ride.ghost_mode then
        -- Native climb owns the player; we own the ghost's pin AND the
        -- horse's anchor (its CC is off, so we are its ground now).
        if ride.anchor then
            pcall(function()
                local horse_tf = ride.horse_go:call("get_Transform")
                local p = horse_tf:call("get_UniversalPosition")
                p.x, p.y, p.z = ride.anchor.x, ride.anchor.y, ride.anchor.z
                horse_tf:call("set_UniversalPosition", p)
                if ride.anchor_rot then
                    horse_tf:call("set_Rotation", ride.anchor_rot)
                end
            end)
        end
        pin_ghost_to_horse(ride.horse_go)
        if not player_climbing_on(ride.player) then
            end_rodeo("thrown")
            return
        end
        -- hold the climb still: no crawling around the ghost
        pcall(function()
            local ctrl = ride.player:call("get_ClimbCtrl")
            if ctrl then
                ctrl:call("set_IsClimbMoving", false)
                ctrl:call("set_ClimbMotionSpeed", 0.0)
            end
        end)
    else
        -- Transform-drive hold: controller off + per-frame universal writes.
        pcall(function()
            ride.player:call("setCharacterControllerEnable", false)
        end)
        suppress_player_components(ride.player_go)
        if not write_player_seat(ride) then
            end_rodeo("lost")
            return
        end
        pcall(function()
            local horse_tf = ride.horse_go:call("get_Transform")
            local player_tf = ride.player_go:call("get_Transform")
            player_tf:call("set_Rotation", horse_tf:call("get_Rotation"))
        end)
    end

    -- Buck cycle. Calm = the doe's LIVE neutral idle loop (bank 0 id 0,
    -- from the locomotion capture) — breathing and natural, no crouch-park.
    -- (Old bug: "calm" froze frame 0 of the buck clip = a gathered crouch,
    -- and clip 212 is actually run_end, a skid — the sink-and-pop look.)
    if now >= ride.next_phase then
        ride.bucking = not ride.bucking
        if ride.bucking then
            ride.next_phase = now + C.buck_on_s
            play_horse_clip(ride, 0, math.floor(C.buck_motion_id))
            kick_horse_yaw(ride, (math.random() * 2 - 1) * C.yaw_kick_deg)
        else
            ride.next_phase = now
                + C.buck_off_min_s
                + math.random() * (C.buck_off_max_s - C.buck_off_min_s)
            play_horse_clip(ride, 0, 0)  -- idle_loop
        end
    end

    -- Grip drain/regen.
    local dt = ride.last_tick and (now - ride.last_tick) or 0
    ride.last_tick = now
    if ride.bucking then
        ride.grip = ride.grip - C.grip_drain_per_buck_s * dt
    else
        ride.grip = math.min(C.grip_max, ride.grip + C.grip_regen_calm_s * dt)
    end

    if ride.grip <= 0 then
        end_rodeo("thrown")
        return
    end
    if now - ride.started >= C.rodeo_secs then
        end_rodeo("tamed")
        return
    end
end

-- Organic entry: the ghost's climb collider comes alive while the player is
-- in the prompt zone; the player jumps at the horse and grabs it like any
-- climbable monster; when the climb takes, the rodeo machine adopts it.
local function begin_rodeo_from_climb(record)
    local player = player_character()
    local player_go = player_game_object()
    if not (player and player_go) then return end
    local ride = {
        horse_go = record.game_object,
        horse_character = get_component(record.game_object, "app.Character"),
        player = player,
        player_go = player_go,
        started = os.clock(),
        grip = C.grip_max,
        bucking = false,
        next_phase = os.clock() + 0.8,
        ghost_mode = true,
        latched = true,
    }
    pcall(function()
        local horse_tf = ride.horse_go:call("get_Transform")
        local p = horse_tf:call("get_UniversalPosition")
        ride.anchor = {x = p.x, y = p.y, z = p.z}
        ride.anchor_rot = horse_tf:call("get_Rotation")
    end)
    pcall(function()
        if ride.horse_character then
            ride.horse_character:call("setCharacterControllerEnable", false)
            ride.horse_cc_off = true
        end
        set_think_stop(ride.horse_character, true)
    end)
    set_horse_fsm(ride.horse_go, false)
    rawset(_G, "__iris_horse_rodeo_active_addr",
        tostring(object_address(ride.horse_go)))
    S.ride = ride
    S.stage = "rodeo"
    S.status = "HOLD ON! (native climb adopted)"
    play_horse_sound("alert", ride.horse_go)
    log("rodeo adopted an ORGANIC climb")
end

local function set_ghost_rsc(enabled)
    pcall(function()
        if S.ghost and S.ghost.rsc then
            S.ghost.rsc:call("set_Enabled", enabled == true)
        end
    end)
end

local function idle_tick()
    local player_go = player_game_object()
    if not player_go then return end
    local player_pos = universal_pos(player_go)
    if not player_pos then return end
    S.prompt = nil
    local near_record = nil
    for _, record in ipairs(horses()) do
        -- tamed horses currently use the same hold (Phase-1 sit-mount will
        -- give them their own calm mounting later)
        local horse_pos = universal_pos(record.game_object)
        local d = distance(player_pos, horse_pos)
        if d <= C.approach_range
            and horse_speed(record) < C.grab_calm_speed then
            near_record = record
            break
        end
    end

    if S.ghost then
        -- FROZEN-SHAPE LAW: never disable the RSC (shapes freeze in place);
        -- it stays ON permanently and the press layer bit handles the push
        set_ghost_rsc(true)
    end

    -- ⛔ BENCHED HARD (Aurora's standing order, re-broken 07-23: merely
    -- leaving this behind the Enabled toggle meant every "Enabled" test
    -- re-summoned the synthetic teleport-seat). The costume mount
    -- (climb -> seat_mount) owns mounting now. The synthetic E-grab
    -- rodeo entry only exists behind the explicit LEGACY checkbox in
    -- Advanced, default OFF, never saved ON by accident.
    if near_record and S.legacy_rodeo_grab == true then
        S.prompt = (S.ghost or S.graft_rig)
            and "CLIMB ON (jump at it and grab)"
            or "GRAB HOLD (E / RT)"
        -- organic adoption, target-verified (stale climb flags never adopt):
        -- ghost mode = climbing the ghost; graft mode = climbing the HORSE
        local player = player_character()
        if player then
            if S.ghost and player_climbing_our_ghost(player) then
                begin_rodeo_from_climb(near_record)
                return
            end
            if S.graft_rig
                and player_climbing_target(player, near_record.game_object) then
                begin_rodeo_from_climb(near_record)
                return
            end
        end
        if grab_pressed() and not S.grab_latch then
            S.grab_latch = true
            begin_rodeo(near_record)
        end
    end
end

-- E is also DD2's native grab key: without this, grabbing the horse makes
-- the player PICK IT UP (the native catch happily deadlifts a scaled doe).
-- Suppress the native grab exactly while the rodeo prompt/ride owns the key.
-- The hook survives script resets; it dispatches through the shared state.
if not rawget(_G, "__iris_horse_rodeo_trycatch_hooked") then
    local human_type = sdk.find_type_definition("app.Human")
    local trycatch = human_type and human_type:get_method(
        "requestTryCatch(app.Human.TryCatchType, System.Boolean, System.Boolean, System.Boolean)")
    if trycatch then
        sdk.hook(trycatch, function(args)
            local state = rawget(_G, "__iris_horse_rodeo_v1")
            if not state then return end
            local active = state.prompt or state.stage == "rodeo"
                or state.stage == "latching"
                or (tonumber(state.suppress_grab_until) or 0) > os.clock()
            if not active then return end
            -- 07-23: with a ghost bound and the prompt up, the E key belongs
            -- ENTIRELY to the rodeo (our request-latch replaces the native
            -- grab) — suppressing here is what kills the horse-deadlift.
            return sdk.PreHookResult.SKIP_ORIGINAL
        end, function(retval) return retval end)
        rawset(_G, "__iris_horse_rodeo_trycatch_hooked", true)
        log("native grab suppressed while the rodeo prompt is active")
    end
end
-- r37 CLIMB-START BLOCK (the r36 fingerprint verdict: 5 of 7 mounts
-- identical, 2 showed the rider carried ~2m in FRONT at ground level
-- mid-vault -- the SAME press that mounts also lands a native climb
-- REQUEST, and a climb starting a frame after seat_mount's endClimb
-- trio owns the body = the frozen-vault and prone-on-the-ground
-- mounts). Proven recipe = RiftSpeakBabyCradleSpike: skip BOTH
-- trySetActionOnGround (SELECTS the climb) and
-- ClimbWallAction.startClimbing (STARTS it). Active ONLY during the
-- 1.5s mount window or while seated on a NON-pose-only ride --
-- ⛔ the griffin invert keeps its native climb ALIVE by design, so
-- pose_only rides are exempt; and the organic climb-onto-the-horse
-- mount path still works because its climb starts BEFORE seat_mount.
-- ⛔ GUARD BUMPED TO _v2 (08-09): sdk.hook installs persist across reloads and
-- this flag pins the OLD install -- which had only the two climb hooks. Without
-- the bump the RunupToClimbWallController hook added below would never arm.
-- ⭐⭐⭐ 08-10 r96 -- INSTRUMENT THE ACTUAL POINT OF APPLICATION.
-- Everything measured so far is upstream of the effect: our clamp permits the
-- damage (dmg 88, budget 249), the bodies are co-located (bodyGap 0.00m), the
-- immunity flags read clear on the diag frame -- and HP never moves off 250.
-- calcDamageReaction only computes the REACTION. HP is applied in
-- updateDamageHp(DamageInfo, amount, bool), and CRUCIALLY the amount is a
-- SEPARATE ARGUMENT (args[4]) -- not DamageInfo.Damage, which is the field our
-- clamp has been carefully adjusting. IrisWildHorses already rewrites that same
-- args[4] for horse bodies (scaling by 250/horse_hp), so this is exactly where
-- the number can quietly become nothing.
-- ⛔ READ-ONLY. It changes no value; it reports amount-in, HP before, and HP
-- after, for the ridden mount only. One line per real hit is enough to end this.
if not rawget(_G, "__iris_rodeo_dmg_probe_v2") then
    pcall(function()
        local td = sdk.find_type_definition("app.HitController")
        local m = td and td:get_method("updateDamageHp")
        if not m then
            log("dmg probe: updateDamageHp NOT FOUND")
            return
        end
        sdk.hook(m,
            function(args)
                pcall(function()
                    -- ⛔ r97: the v1 filter compared hc:get_GameObject() to
                    -- costume.horse_go by ADDRESS and fired zero times. That is
                    -- ambiguous -- it means either "no damage is ever applied to
                    -- the horse" OR "the HitController lives on a different
                    -- GameObject than the one I compared against" (the clamp
                    -- resolves its target a completely different way, via
                    -- DamageInfo's DamageGameObject). Do not conclude from a
                    -- filter that may simply never match.
                    -- Count EVERY call so we can prove the hook works at all,
                    -- and match the horse by NAME instead of identity.
                    _G.IrisDmgApplyAll = (tonumber(rawget(_G, "IrisDmgApplyAll")) or 0) + 1
                    local hc = sdk.to_managed_object(args[2])
                    if not hc then return end
                    local go = hc:call("get_GameObject")
                    if not go then return end
                    local gname = tostring(go:call("get_Name") or "?")
                    if not gname:find("ch299", 1, true) then return end
                    local amt = sdk.to_float(args[4])
                    local hp0 = nil
                    pcall(function() hp0 = tonumber(hc:call("get_Hp")) end)
                    local zero = "?"
                    pcall(function()
                        zero = tostring(hc:call("get_IsDamageZero"))
                    end)
                    rawset(_G, "__iris_dmg_probe_pending",
                        { hc = hc, amt = amt, hp0 = hp0, zero = zero,
                          name = gname })
                end)
            end,
            function(retval)
                pcall(function()
                    local p = rawget(_G, "__iris_dmg_probe_pending")
                    if not p then return end
                    rawset(_G, "__iris_dmg_probe_pending", nil)
                    local hp1 = nil
                    pcall(function() hp1 = tonumber(p.hc:call("get_Hp")) end)
                    log(string.format(
                        "DMG APPLY [%s]: amount=%s hp %s -> %s  IsDamageZero=%s",
                        tostring(p.name), tostring(p.amt), tostring(p.hp0),
                        tostring(hp1), tostring(p.zero)))
                end)
                return retval
            end)
        rawset(_G, "__iris_rodeo_dmg_probe_v2", true)
        log("dmg probe armed on updateDamageHp")
    end)
end

-- ⭐⭐⭐ 08-10 r98 -- THE LAST GATE: isFriendAttack.
-- The probe finally isolated where the damage dies. calcDamageReaction fires for
-- the horse over and over (clampHits climbing, dmg 88 permitted, budget 249) --
-- but updateDamageHp, which is where HP is actually SUBTRACTED, fired 14 times
-- in an entire session and NOT ONCE for the horse. So the blow is fully
-- computed and then thrown away between reaction and application.
-- app.HitController.isFriendAttack(DamageInfo) is the gate that sits in exactly
-- that gap: answer "yes, friendly fire" and the engine skips application while
-- everything upstream still runs and still looks healthy. That is why every
-- measurement we took read fine.
-- Fixing the RELATIONSHIP hook was necessary but not sufficient -- relEnemy is
-- climbing, so the hostility answer is right, and isFriendAttack is evidently
-- deciding on something else (mount/party membership, most likely).
-- ⛔ SCOPED HARD: forced false ONLY when the victim is the mount you are
-- actually sitting on. Friendly fire everywhere else in the game is untouched.
-- Same recipe MonsterInfightingImproved and RiftSpeakSparringSpike already use.
if not rawget(_G, "__iris_rodeo_friendattack_v3") then
    pcall(function()
        local td = sdk.find_type_definition("app.HitController")
        local m = td and td:get_method("isFriendAttack(app.HitController.DamageInfo)")
        if not m then
            log("friend-attack gate: method NOT FOUND")
            return
        end
        sdk.hook(m,
            function(args)
                local st = thread.get_hook_storage()
                st.iris_force = nil
                pcall(function()
                    local rst = rawget(_G, "__iris_horse_rodeo_v1")
                    -- The active tamed horse remains a valid enemy target when
                    -- unmounted too. Party safety is still handled by the
                    -- relationship/hate shields; this only prevents the engine
                    -- misclassifying a hostile monster's hit as friendly fire.
                    if not (rst and rst.costume) then return end
                    if rst.mounted_combat_off == true then return end
                    local mount_ch = rst.costume.horse_character
                    if not mount_ch then return end
                    local di = sdk.to_managed_object(args[3])
                    if not di then return end
                    -- ⛔ r100: friendForced stayed at 0, so this match NEVER
                    -- fired. That is the third probe in a row whose FILTER was
                    -- the thing that failed, not the phenomenon. Stop guessing
                    -- at the victim's shape -- resolve it several ways, match by
                    -- NAME as well as identity, and LOG what we actually see so
                    -- the next run cannot be ambiguous.
                    local vic, vname = nil, nil
                    local dhc = di["<DamageHitController>k__BackingField"]
                    if dhc then
                        pcall(function() vic = dhc["<CachedCharacter>k__BackingField"] end)
                        if not vic then
                            pcall(function()
                                local vgo = dhc:call("get_GameObject")
                                vname = vgo and tostring(vgo:call("get_Name"))
                            end)
                        end
                    end
                    if not vname then
                        pcall(function()
                            local vgo2 = di["<DamageGameObject>k__BackingField"]
                            vname = vgo2 and tostring(vgo2:call("get_Name"))
                        end)
                    end
                    if not vname and vic then
                        pcall(function()
                            vname = tostring(vic:call("get_GameObject")
                                :call("get_Name"))
                        end)
                    end
                    -- one line per distinct victim, so the log stays readable
                    if vname then
                        _G.IrisFriendVics = rawget(_G, "IrisFriendVics") or {}
                        if not _G.IrisFriendVics[vname] then
                            _G.IrisFriendVics[vname] = true
                            log("friend-attack gate saw victim: " .. vname)
                        end
                    end
                    local same = false
                    if vic and mount_ch then
                        pcall(function()
                            same = vic:get_address() == mount_ch:get_address()
                        end)
                    end
                    if not same and vname and vname:find("ch299", 1, true) then
                        same = true   -- name match: any horse chassis
                    end
                    if same then st.iris_force = true end
                end)
            end,
            function(retval)
                local st = thread.get_hook_storage()
                if st and st.iris_force then
                    _G.IrisFriendAttackForced =
                        (tonumber(rawget(_G, "IrisFriendAttackForced")) or 0) + 1
                    return sdk.to_ptr(false)
                end
                return retval
            end)
        rawset(_G, "__iris_rodeo_friendattack_v3", true)
        log("friend-attack gate armed (active tamed horse accepts hostile hits)")
    end)
end

if not rawget(_G, "__iris_rodeo_climb_block_hooked_v2") then
    local function install_mount_climb_block(type_name, sig)
        pcall(function()
            local td = sdk.find_type_definition(type_name)
            if not td then return end
            local m = td:get_method(sig)
            if not m and sig:find("%(") then
                m = td:get_method(sig:gsub("%(.*$", ""))
            end
            if not m then return end
            sdk.hook(m, function(args)
                local state = rawget(_G, "__iris_horse_rodeo_v1")
                if not state then return end
                local pose_only = state.costume
                    and state.costume.pose_only
                local active = (state.ride_pose_on == true
                        and not pose_only)
                    or (tonumber(state.mount_climb_block_until) or 0)
                        > os.clock()
                if active then
                    return sdk.PreHookResult.SKIP_ORIGINAL
                end
            end, function(retval) return retval end)
        end)
    end
    install_mount_climb_block("app.HumanClimbWallActionRequester",
        "trySetActionOnGround(app.HumanClimbWallActionRequesterBase.ActionInfo)")
    install_mount_climb_block("app.ClimbWallAction", "startClimbing()")
    -- ⛔⛔ 08-09 r65 -- THE RIDE CTD, AGAIN. Aurora crashed mid-ride 0.04s after a
    -- jump into a wall; the stack is the same one already documented up at
    -- PLAYER_SUPPRESS_COMPONENTS: app.RunupToClimbWallController.isRunupMotionEnd
    -- <- .update, asking a parked rider's motion whether a run-up clip has
    -- finished and dereferencing null because that clip does not exist.
    -- That controller was ALREADY added to PLAYER_SUPPRESS_COMPONENTS today --
    -- and it crashed anyway. The reason is the shape of that fix:
    -- suppress_player_components does get_component(go, name) and, if the
    -- component is not found, does NOTHING AND SAYS NOTHING. If this controller
    -- is not a via.Component sitting on the player GameObject, disabling it was
    -- a silent no-op the whole time -- the identical failure mode as the dead
    -- make_vec3 rays. (Logging is now added there so we can finally see which.)
    -- Blocking the METHOD does not care where the controller lives or whether
    -- set_Enabled is honoured: the crashing function simply does not run while
    -- seated. Same proven recipe as the two hooks above.
    install_mount_climb_block("app.RunupToClimbWallController", "update()")
    install_mount_climb_block("app.RunupToClimbWallController",
        "isRunupMotionEnd()")
    rawset(_G, "__iris_rodeo_climb_block_hooked_v2", true)
    log("climb-start block armed (mount window + while seated) + runup block")
end

-- =========================================================================
-- THE HORSE TAME (Aurora's rite, 07-24): PALM > HERB > RODEO > PALM > NAME
-- Wild horses flee — sneaking close IS the approach gameplay. Hold N in
-- palm range to begin. The ox conjures itself for the rodeo; ride out the
-- bucks, steady the palm, give the name.
-- =========================================================================
local TAME_HERBS = {184, 187, 193} -- Greenwarish, Morningtide, Syrupwort

-- ABGR card colors (the IrisTaming convention): RED = act now (hold the
-- grip), GREEN = rest/recover, AMBER = get ready
local TAME_RED = 0xFF5050FF
local TAME_GREEN = 0xFF50FF50
local TAME_AMBER = 0xFF50D0FF

local function tame_card(title, sub, argb)
    local font = rawget(_G, "IrisFont")
    if font and type(font.card) == "function" then
        pcall(font.card, title, sub, argb)
    end
    S.status = title .. (sub and (" - " .. sub) or "")
end

-- 08-12 (Aurora): a species + gender tag over the whole tame -- "Unicorn ♀" /
-- "Horse ♂" -- so you know what you are wrestling before the christening.
-- Species asks the wild-horses api per frame (a unicorn promotion mid-tame
-- updates live); drawn just above the ritual card, unicorns in pale blue.
local function tame_species_line(tame)
    local rec = tame and tame.record
    local go = rec and rec.game_object
    if not (go and valid(go)) then return end
    local font = rawget(_G, "IrisFont")
    if not (font and type(font.text) == "function") then return end
    local species = "Horse"
    pcall(function()
        local api = rawget(_G, "__iris_wild_horses_api")
        if api and api.is_unicorn and api.is_unicorn(go) then
            species = "Unicorn"
        end
    end)
    local sym = (tame.gender == "female") and "\u{2640}" or "\u{2642}"
    local label = species .. " " .. sym
    local sw, sh = 1920.0, 1080.0
    pcall(function()
        local ds = imgui.get_display_size()
        if ds then
            sw = tonumber(ds.x) or sw
            sh = tonumber(ds.y) or sh
        end
    end)
    -- rough centring: glyph count (utf8 -- the symbol is 3 BYTES), ~0.30em wide
    local n = #label
    pcall(function() n = utf8.len(label) or n end)
    local base = 18
    local half = n * (sh / 1080.0) * base * 0.30
    local col = (species == "Unicorn") and 0xFFA8E0FF or 0xFFE2D6BA
    pcall(font.text, label, sw * 0.5 - half, sh * 0.105, col, base)
end

-- the house gauges (drawn by the griffin probe's d2d suite, cross-file):
-- IrisProgressHUD = the amber charge bar; IrisRodeoHUD = Grip + Break
local function tame_charge_bar(frac, label)
    _G.IrisProgressHUD = {active = true, t = os.clock(),
        frac = math.max(0.0, math.min(1.0, frac)), label = tostring(label)}
end

local function tame_rodeo_bars(grip, brk, striking)
    _G.IrisRodeoHUD = {active = true, t = os.clock(),
        grip = grip, brk = brk, striking = striking == true}
end

-- LT (pad) or SPACE (kbd) = the GRIP hold; E/RT stays clear (dismount)
local function tame_grip_down()
    local down = false
    pcall(function() down = iris_kb(0x20) end)
    if down then return true end
    pcall(function()
        local hid = sdk.get_native_singleton("via.hid.GamePad")
        local hid_type = sdk.find_type_definition("via.hid.GamePad")
        local device = sdk.call_native_func(hid, hid_type,
            "get_MergedDevice")
        local mask = device and tonumber(device:call("get_Button")) or 0
        down = (mask & 0x200) ~= 0 -- L2 / LT
    end)
    return down
end

local function tame_have_herb()
    local found = nil
    pcall(function()
        local im = sdk.get_managed_singleton("app.ItemManager")
        local player = player_character()
        for _, id in ipairs(TAME_HERBS) do
            local n = im:call("getHaveNum(System.Int32, app.Character)",
                id, player)
            if tonumber(n) and tonumber(n) > 0 then
                found = id
                return
            end
        end
    end)
    return found ~= nil, found
end

-- Passive-tame weapon gate. The old cross-file courtship path forcibly sheathed the
-- player; a horse should instead refuse the offer, and bolt if steel appears mid-rite.
local function tame_weapon_sheathed()
    local player = player_character()
    if not player then return nil end
    local h = nil
    pcall(function() h = player:call("get_Human") end)
    for _, obj in ipairs({h, player}) do
        if obj then
            local ok, drawn = pcall(function() return obj:call("get_IsDrawedWeapon") end)
            if ok and type(drawn) == "boolean" then return not drawn end
        end
    end
    if h then
        for _, fn in ipairs({"<DrawingWeapon>k__BackingField", "<IsDrawWeapon>k__BackingField", "_DrawingWeapon", "DrawingWeapon"}) do
            local ok, drawn = pcall(function() return h:get_field(fn) end)
            if ok and type(drawn) == "boolean" then return not drawn end
        end
    end
    return nil
end

-- the OFFERING watch (ported from IrisTaming's passive critter tame):
-- the player drops the herb NATIVELY from the pouch; we spot the new
-- ground object on two surfaces — DropItemList (loot bags) + a scene
-- mesh sweep (field law: plain discards may never enter the drop list)
local function tame_drop_snapshot()
    local set = {}
    pcall(function()
        local im = sdk.get_managed_singleton("app.ItemManager")
        local dl = im:call("get_DropItemList")
        local n = dl and (tonumber(dl:call("get_Count")) or 0) or 0
        for i = 0, n - 1 do
            pcall(function()
                set[dl:call("get_Item", i):get_address()] = true
            end)
        end
    end)
    return set
end

local function tame_ground_snapshot()
    local set = {}
    pcall(function()
        local sm = sdk.get_native_singleton("via.SceneManager")
        local smt = sdk.find_type_definition("via.SceneManager")
        local scene = sm and sdk.call_native_func(sm, smt,
            "get_CurrentScene")
        local comps = scene and scene:call("findComponents(System.Type)",
            sdk.typeof("via.render.Mesh"))
        local prp = render_pos(player_game_object())
        local n = 0
        pcall(function() n = comps:call("get_Length") or 0 end)
        if n == 0 then pcall(function() n = comps:get_size() or 0 end) end
        for i = 0, (tonumber(n) or 0) - 1 do
            pcall(function()
                local m = comps:call("get_Item", i) or comps[i]
                local g = m:call("get_GameObject")
                local rp = g:call("get_Transform"):call("get_Position")
                local dx, dz = rp.x - prp.x, rp.z - prp.z
                if dx * dx + dz * dz < 100.0 then
                    set[g:get_address()] = true
                end
            end)
        end
    end)
    return set
end

-- RENDER -> UNIVERSAL via the player's own offset (the coord law)
local function tame_render_to_universal(rp)
    local pgo = player_game_object()
    local pu = universal_pos(pgo)
    local pr = render_pos(pgo)
    if not (rp and pu and pr) then return nil end
    return {x = rp.x + (pu.x - pr.x), y = rp.y + (pu.y - pr.y),
            z = rp.z + (pu.z - pr.z)}
end

local function tame_find_offering(tame)
    -- surface 1: a NEW DropItemList entry near the player
    local found_go, found_rp = nil, nil
    pcall(function()
        local im = sdk.get_managed_singleton("app.ItemManager")
        local dl = im:call("get_DropItemList")
        local prp = render_pos(player_game_object())
        local n = dl and (tonumber(dl:call("get_Count")) or 0) or 0
        for i = 0, n - 1 do
            pcall(function()
                local dr = dl:call("get_Item", i)
                if not tame.drop_seen[dr:get_address()] then
                    local dgo = dr:call("get_GameObject")
                    local rp = dgo
                        and dgo:call("get_Transform"):call("get_Position")
                    if rp and prp then
                        local dx, dz = rp.x - prp.x, rp.z - prp.z
                        if dx * dx + dz * dz < 36.0 then
                            found_go, found_rp = dgo, rp
                        end
                    end
                end
            end)
        end
    end)
    -- surface 2 (1/s, heavy): a NEW mesh GO at the feet — plain discards
    if not found_go and tame.ground_seen
        and os.clock() >= (tame.ground_at or 0) then
        tame.ground_at = os.clock() + 1.0
        pcall(function()
            local sm = sdk.get_native_singleton("via.SceneManager")
            local smt = sdk.find_type_definition("via.SceneManager")
            local scene = sm and sdk.call_native_func(sm, smt,
                "get_CurrentScene")
            local comps = scene
                and scene:call("findComponents(System.Type)",
                    sdk.typeof("via.render.Mesh"))
            local prp = render_pos(player_game_object())
            local n = 0
            pcall(function() n = comps:call("get_Length") or 0 end)
            if n == 0 then
                pcall(function() n = comps:get_size() or 0 end)
            end
            for i = 0, (tonumber(n) or 0) - 1 do
                pcall(function()
                    local m = comps:call("get_Item", i) or comps[i]
                    local g = m:call("get_GameObject")
                    if not tame.ground_seen[g:get_address()] then
                        local name = tostring(g:call("get_Name") or "")
                        if not name:match("^ch%d") then
                            local rp = g:call("get_Transform")
                                :call("get_Position")
                            local dx, dz = rp.x - prp.x, rp.z - prp.z
                            if dx * dx + dz * dz < 36.0 then
                                found_go, found_rp = g, rp
                            end
                        end
                    end
                end)
            end
        end)
    end
    if found_go and found_rp then
        local u = tame_render_to_universal(found_rp)
        if u then return found_go, u end
    end
    return nil
end

local function tame_horse_clip(record, bank, id, interp)
    pcall(function()
        local ch = get_component(record.game_object, "app.Character")
        local motion = ch and ch:call("get_Motion")
        local layer = motion and motion:call("getLayer", 0)
        if layer then
            layer:call(
                "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                bank, id, 0.0, interp or 0.3, 1, 1)
        end
    end)
end

local function tame_hold_horse(record, hold)
    -- think-stop kills the BRAIN; the FSM must park too or the
    -- livelihood scheduler stomps our clips (the lying-down law) —
    -- and a parked FSM is what makes the eat clips visible at all
    pcall(function()
        local ch = get_component(record.game_object, "app.Character")
        if ch then ch:call("set_IsThinkStop", hold == true) end
        local fsm = get_component(record.game_object,
            "via.motion.MotionFsm2")
        if fsm then fsm:call("set_Enabled", hold ~= true) end
    end)
    if hold then
        -- settle out of whatever flee frame it froze in
        tame_horse_clip(record, 0, 0, 0.4)
    end
end

-- the palm: player FSM parked on the hand-out clip (the taming recipe —
-- InteractRimStone's 60:6200 IS the hand gesture, proven in IrisTaming)
local function tame_palm_pose(active)
    if active and not S.tame_palm_on then
        S.tame_palm_on = true
        pcall(function()
            local pgo = player_game_object()
            local fsm = get_component(pgo, "via.motion.MotionFsm2")
            if fsm then fsm:call("set_Enabled", false) end
            local motion = player_character():call("get_Motion")
            local layer = motion and motion:call("getLayer", 0)
            if layer then
                layer:call(
                    "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                    60, 6200, 0.0, 0.25, 1, 1)
            end
        end)
    elseif not active and S.tame_palm_on then
        S.tame_palm_on = nil
        pcall(function()
            local pgo = player_game_object()
            local fsm = get_component(pgo, "via.motion.MotionFsm2")
            if fsm and not S.ride_pose_on then
                fsm:call("set_Enabled", true)
            end
        end)
    end
end

local function tame_abort(reason)
    local tame = S.tame
    S.tame = nil
    tame_palm_pose(false)
    _G.IrisRodeoHUD = nil
    if tame and S.costume
        and (tame.ox_called or S.costume.oxless) then
        -- release the horse (costume_stop restores think/FSM/CC/
        -- invincibility) — it bolts, as a failed tame should
        S.costume_stop_requested = true
    elseif tame and tame.record and valid(tame.record.game_object)
        and not S.costume then
        tame_hold_horse(tame.record, false)
    end
    S.status = "tame: " .. tostring(reason)
end

-- Cancellation bridge for IrisTaming's mode/UI. This module alone owns the horse costume,
-- FSM and palm pose, so callers request its normal abort instead of clearing S.tame externally.
_G.IrisHorseTamingCancel = function(reason)
    if not S.tame then return false end
    tame_abort(reason or "cancelled")
    return true
end

local function tame_tick()
    local now = os.clock()
    local n_down = false
    pcall(function() n_down = iris_kb(0x4E) end)
    -- 08-12 (Aurora: "B to tame isn't working on horses/unicorns"): pad B/Circle joins N
    -- (mask 0x40080, the taming standard) -- gated on a live rite or an AIMED claim
    -- (focused_wild_horse publishes it key-free), so plain dashing never arms a horse
    if not n_down and (S.tame ~= nil or rawget(_G, "__iris_horse_taming_claim_addr") ~= nil) then
        pcall(function()
            local gp9 = sdk.get_native_singleton("via.hid.GamePad")
            local td9 = sdk.find_type_definition("via.hid.GamePad")
            local dev9 = gp9 and td9 and sdk.call_native_func(gp9, td9, "get_MergedDevice")
            if not dev9 then dev9 = gp9 and td9 and sdk.call_native_func(gp9, td9, "getMergedDevice(System.UInt32)", 0) end
            local mask9 = dev9 and tonumber(dev9:call("get_Button")) or 0
            n_down = (math.floor(mask9) & 0x40080) ~= 0
        end)
    end
    local tame = S.tame
    -- RITUAL MUSIC (08-06, Aurora): the horse rite sings like every other
    -- tame -- publish the shared mode IrisRitualMusic watches. Claimed only
    -- when free (never stomps IrisTaming's own rites); released on the next
    -- tick after the tame ends by ANY path (seal, abort, thrown).
    if tame then
        local mmode = rawget(_G, "IrisTamingMode")
        if S.music_claimed or mmode == nil or mmode == "idle" then
            _G.IrisTamingMode = "trusting"
            S.music_claimed = true
        end
    elseif S.music_claimed then
        _G.IrisTamingMode = "idle"
        S.music_claimed = nil
    end
    if not tame then
        if S.ride_pose_on then return end
        local player_pos = universal_pos(player_game_object())
        if not player_pos then return end
        -- The palm still reaches 9m, but it belongs to the horse under the
        -- camera — never merely whichever horse happens to be nearest.
        local best = S.focused_wild_horse
        if not (best and not best.tamed and valid(best.game_object)) then
            best = focused_wild_horse(9.0)
        end
        -- ⭐⭐⭐ 08-13 HOLD-TO-COMMIT, shared with every other passive tame (Aurora: tames kept
        -- starting off a press she meant for a sign or a bell). A tap no longer begins the rite --
        -- the button must be HELD for the species' commit time, and letting go costs nothing.
        -- ⛔ THE RECORD RIDES ALONG AS THE PAYLOAD and comes back on completion: focused_wild_horse
        -- is re-evaluated every frame, and a horse that turns its head leaves the 9m focus for a
        -- frame -- which would otherwise cancel a hold that had already rightfully claimed it.
        -- ⚠ This file cannot see IrisTaming's TB (it is a chunk-local over there), so it goes
        -- through the _G export; with IrisTaming absent the old single-tap start is kept verbatim.
        if not n_down then return end
        -- ⭐⭐⭐ 08-13 TAMING MODE gates the horse/unicorn rite too. IrisTaming owns the flag and
        -- already suppresses the PROMPT when the mode is off -- but this file starts its own rite
        -- off its own key read, so without this a horse would still be tameable with no prompt and
        -- no intent declared. Cross-file via rawget per this project's law; with IrisTaming absent
        -- the rite behaves exactly as it always did.
        local Tm = rawget(_G, "IrisTaming")
        if Tm and Tm.mode_on and Tm.mode_on() ~= true then return end
        if not (best and valid(best.game_object)) then return end
        if tame_weapon_sheathed() == false then
            tame_card("LOWER YOUR WEAPON", "A horse will not accept an armed approach.", TAME_RED)
            return
        end
        S.tame = {record = best, stage = "palm1", hold = 0.0, t = now,
                  n_latch = true,
                  gender = (math.random() < 0.5) and "female" or "male"}
        tame_hold_horse(best, true)
        return
    end
    local record = tame.record
    if not (record and valid(record.game_object)) then
        tame_abort("the horse is gone")
        return
    end
    tame_species_line(tame)
    local player_pos = universal_pos(player_game_object())
    local horse_pos = universal_pos(record.game_object)
    local d = (player_pos and horse_pos)
        and distance(player_pos, horse_pos) or 99.0
    if d > 14.0 and tame.stage ~= "mount" and tame.stage ~= "brace"
        and tame.stage ~= "rodeo" then
        tame_abort("you left - it bolts")
        return
    end
    local dt = math.min(0.1, now - (tame.t or now))
    tame.t = now

    -- The mounted brace/rodeo owns the player's whole body. Everywhere else, drawing
    -- steel breaks this peaceful rite and uses tame_abort's existing bolt/restore path.
    if tame.stage ~= "brace" and tame.stage ~= "rodeo" and tame_weapon_sheathed() == false then
        tame_card("IT SPOOKS", "Drawn steel sends it bolting.", TAME_RED)
        tame_abort("you drew steel - it bolts")
        return
    end

    if tame.stage == "palm1" then
        -- prey window: fills from 2.5-9m; crowding it spooks it
        if d < 2.2 then
            tame.spook = (tame.spook or 0) + dt
            tame_card("TOO CLOSE", "step back - it shies!", TAME_RED)
            tame_palm_pose(false)
            if tame.spook > 1.2 then
                tame_abort("you pressed too close - it BOLTS")
                return
            end
        elseif n_down and d <= 9.0 then
            tame.spook = 0
            tame.hold = (tame.hold or 0) + dt
            tame_palm_pose(true)
            -- 07-24 (Aurora #4): wording matches the passive tames
            tame_card("THE PALM", "Hold... your hand stays open.")
            tame_charge_bar(tame.hold / 3.0, "The Palm")
            if tame.hold >= 3.0 then
                tame.stage = "herb"
                tame.hold = 0
                tame_palm_pose(false)
            end
        else
            tame.spook = 0
            tame_palm_pose(false)
            tame_card("THE PALM",
                "Hold out your hand (hold N / B) -- keep your distance.")
        end
    elseif tame.stage == "herb" then
        if tame.eat_until then
            tame_card("IT EATS", "the greens won it over...")
            -- Aurora's clip ids (07-24 dump): 60:0 liv_eat_start,
            -- 60:1 liv_eat_loop, 60:9 liv_eat_end
            if tame.eat_phase == 1 and now >= tame.eat_next then
                tame_horse_clip(record, 60, 1)
                tame.eat_phase = 2
            elseif tame.eat_phase == 2
                and now >= tame.eat_until - 1.0 then
                tame_horse_clip(record, 60, 9)
                tame.eat_phase = 3
                -- the offering is eaten
                pcall(function()
                    local go = tame.offering and tame.offering.go
                    if go then go:call("destroy", go) end
                end)
            end
            if now > tame.eat_until then
                tame_horse_clip(record, 0, 0, 0.4)
                tame.offering = nil
                tame.stage = "mount"
                tame.eat_until = nil
            end
        elseif tame.offering then
            -- it comes to the laid greens (puppet step: think-stopped +
            -- FSM parked = translate + walk clip, the proven recipe)
            local o = tame.offering
            local ox, oz = o.x - horse_pos.x, o.z - horse_pos.z
            local od = math.sqrt(ox * ox + oz * oz)
            if od > 1.4 then
                if not tame.walking then
                    tame.walking = true
                    tame_horse_clip(record, 0, 100, 0.3)
                end
                pcall(function()
                    local tf = record.game_object:call("get_Transform")
                    local pos = tf:call("get_UniversalPosition")
                    local step = math.min(1.8 * dt, od)
                    pos.x = pos.x + ox / od * step
                    pos.z = pos.z + oz / od * step
                    local dy = o.y - pos.y
                    pos.y = pos.y
                        + math.max(-1.5 * dt, math.min(1.5 * dt, dy))
                    tf:call("set_UniversalPosition", pos)
                    local yaw = math.atan(ox, oz)
                    local rot = tf:call("get_Rotation")
                    rot.x, rot.y, rot.z, rot.w =
                        0.0, math.sin(yaw * 0.5), 0.0, math.cos(yaw * 0.5)
                    tf:call("set_Rotation", rot)
                end)
                tame_card("IT COMES", "the greens tempt it - stay still")
            else
                tame.walking = nil
                tame_horse_clip(record, 60, 0)
                tame.eat_phase = 1
                tame.eat_next = now + 1.1
                tame.eat_until = now + 5.0
            end
        else
            if not tame.drop_seen then
                tame.drop_seen = tame_drop_snapshot()
                tame.ground_seen = tame_ground_snapshot()
                tame.ground_at = now + 1.0
            end
            local have = tame_have_herb()
            -- 07-24 (Aurora #4): match the passive tames' offering wording
            if have then
                tame_card("THE OFFERING",
                    "Lay the greens before it -- drop a Greenwarish "
                    .. "(or other herb) from your pouch.")
            else
                tame_card("IT WAITS", "Something green would do -- "
                    .. "Greenwarish, Morningtide, Syrupwort... you carry none.")
            end
            local go, upos_t = tame_find_offering(tame)
            if upos_t then
                tame.offering = {go = go, x = upos_t.x, y = upos_t.y,
                                 z = upos_t.z}
                tame.offer_t0 = now
            end
        end
    elseif tame.stage == "mount" then
        if not S.costume then
            -- OXLESS (07-24): no conjure, no ghost — the horse is its
            -- own drive body, instantly ready
            costume_start_oxless(record)
            tame_card("IT STANDS READY", "it steadies itself...")
        elseif not S.ride_pose_on then
            -- the grab is NOT the smoothness (07-24 verdict: the vault +
            -- seat pin are) — a plain press mounts directly; climbing on
            -- still works as the organic alternative
            tame_card("MOUNT IT", "press E/RT - and HOLD TIGHT")
            local pressed = grab_pressed()
            if pressed and not tame.mount_latch and d < 4.5 then
                seat_mount()
            end
            tame.mount_latch = pressed
        else
            tame.stage = "brace"
            -- rodeo ANCHOR (07-24 runaway): the drive must never translate
            -- the body, but the bucks may DRIFT it a little (Aurora #1 —
            -- "barely moves, would be good to move around a bit"). anchor
            -- = the live pin point; anchor_home = the centre the drift is
            -- clamped around (stays within ~2.5m, no running off).
            tame.anchor = nil
            pcall(function()
                local p = S.costume.horse_go:call("get_Transform")
                    :call("get_UniversalPosition")
                tame.anchor = {p.x, p.y, p.z}
                tame.anchor_home = {p.x, p.y, p.z}
            end)
        end
    elseif tame.stage == "brace" then
        -- 07-24: the frenzy used to erupt DURING the vault — wait for
        -- the seat to settle, then a clear 2s "get ready" beat
        if not S.ride_pose_on then
            tame_abort("thrown clear - it bolts")
            return
        end
        local seat = S.costume and S.costume.seat
        if seat and seat.pose_stage == "loop" then
            tame.brace_until = tame.brace_until or (now + 2.0)
            local left = tame.brace_until - now
            tame_card("IT TREMBLES", "READY YOUR GRIP - LT (or SPACE)!",
                TAME_AMBER)
            tame_charge_bar(1.0 - math.max(0, left) / 2.0, "Brace")
            if left <= 0 then
                tame.stage = "rodeo"
                tame.rodeo = {phase = "frenzy", phase_until = now + 4.0,
                              grip = 1.0, brk = 0.0}
                tame.buck_at = now + 0.5
                tame.brace_until = nil
            end
        else
            tame_card("IT SHIVERS BENEATH YOU", "steady...", TAME_AMBER)
        end
    elseif tame.stage == "rodeo" then
        -- GRIP/BREAK duel (Aurora's spec, the griffin rodeo's shape minus
        -- the striking): FRENZY = it bucks, hold LT/SPACE to grip — break
        -- rises while gripping, grip drains (fast if you aren't gripping,
        -- 0 = thrown). REST = a few seconds to regain the grip. Repeat
        -- until BREAK maxes, then it stands blown and you slide off.
        local ro = tame.rodeo
        if not S.ride_pose_on or not ro then
            tame_abort("thrown clear - it bolts")
            return
        end
        local gripping = tame_grip_down()
        if ro.phase == "frenzy" then
            tame_card("THE FRENZY", "HOLD LT (or SPACE) - GRIP!",
                TAME_RED)
            if gripping then
                ro.brk = ro.brk + dt / 9.0
                ro.grip = ro.grip - dt / 8.0
            else
                ro.grip = ro.grip - dt / 2.5
            end
            if now >= (tame.buck_at or 0) then
                tame.buck_at = now + 0.7 + math.random() * 0.9
                pcall(function()
                    local costume = S.costume
                    local ox_tf = costume.ox_go:call("get_Transform")
                    local rot = ox_tf:call("get_Rotation")
                    local half = (math.random() - 0.5)
                        * math.rad(140.0) * 0.5
                    local sy, cy = math.sin(half), math.cos(half)
                    local qx = rot.x * cy - rot.z * sy
                    local qy = rot.w * sy + rot.y * cy
                    local qz = rot.x * sy + rot.z * cy
                    local qw = rot.w * cy - rot.y * sy
                    rot.x, rot.y, rot.z, rot.w = qx, qy, qz, qw
                    ox_tf:call("set_Rotation", rot)
                    -- 07-24 "went miles in massive leaps": cur_speed
                    -- injection here fed the DRIVE — every buck galloped
                    -- the horse 5.5-9 m/s in a random direction. The
                    -- rodeo anchors in place now (costume_tick pin);
                    -- bucks are clips + spin only.
                    -- 08-06 (Aurora, rodeo round 2): NO drift during bucks --
                    -- the frenzy holds its ground (planted rear legs sell the
                    -- Attack_Kick); the REST phase walks it forward instead.
                    -- BUCK CLIP v2 (07-24: hitbacks "flop like a fish" —
                    -- they're knockdowns): the step-climb HOPS are the
                    -- doe's real upward launches — 566 high-climb, 561
                    -- low-climb, 212 skid for variety. force_hold owns
                    -- the layer; the loop assist re-fires the clip.
                    costume.force_hold = true
                    -- THE REAL BUCK (08-06): the jump pack's Attack_Kick
                    -- (bank 902 take 3 -- weight back, rear legs FIRE) is the
                    -- upward launch this pool always wanted; the doe hops
                    -- stay as the fallback and for variety seasoning
                    local pool = {566, 566, 561, 212}
                    local buck_bank = 0
                    local buck_id = pool[math.random(1, #pool)]
                    pcall(function()
                        local api = rawget(_G, "__iris_wild_horses_api")
                        local jpk = api and api.jump_pack and api.jump_pack()
                        -- 08-06 r3 (Aurora: "a bit crazy with the jumps --
                        -- stick with the bucks"): the doe climb-hops read as
                        -- leaping about; pack live = ALWAYS the real buck
                        if jpk then
                            buck_bank, buck_id = jpk.bank, jpk.buck
                        end
                        -- ⭐ 08-18 W3 FRENZY VARIETY (Aurora: "a mix of
                        -- rearing... as well as the occasional kick"): rear
                        -- and back-kick join the real buck, weighted. The
                        -- throw-off clip is NOT in this pool — it plays at
                        -- the actual throw moment instead.
                        local w3a = api and api.w3_actions and api.w3_actions()
                        if w3a then
                            local pool9 = {
                                {w3a.bank, w3a.rear}, {w3a.bank, w3a.rear},
                                {w3a.bank, w3a.kick},
                                {buck_bank, buck_id}, {buck_bank, buck_id},
                            }
                            local pick = pool9[math.random(1, #pool9)]
                            buck_bank, buck_id = pick[1], pick[2]
                        end
                    end)
                    costume.cmd_bank, costume.cmd_clip = buck_bank, buck_id
                    local motion = costume.horse_character
                        :call("get_Motion")
                    local layer = motion and motion:call("getLayer", 0)
                    if layer then
                        layer:call(
                            "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                            buck_bank, buck_id, 0.0, 0.15, 1, 1)
                        -- ⛔ set_Speed persists across changeMotion (reviewer
                        -- #2): a frenzy clip after a gallop would inherit
                        -- gallop pace without this
                        pcall(function() layer:call("set_Speed", 1.0) end)
                    end
                    -- and it SCREAMS (the custom horse soundbank's hurt
                    -- whinny, via the wild-horses audio api)
                    local audio = rawget(_G,
                        "__lyra_horse_custom_audio_api")
                    if audio and audio.play_category then
                        pcall(audio.play_category, "hurt",
                            costume.horse_go)
                    end
                end)
            end
            if ro.grip <= 0.0 then
                -- ⭐ 08-18: the W3 throw-off clip AT the throw itself — the
                -- cut when native flee re-owns the layer a moment later is
                -- masked by the player's own launch (Aurora: "knock rider
                -- off animations" in the taming mix)
                pcall(function()
                    local api = rawget(_G, "__iris_wild_horses_api")
                    local w3a = api and api.w3_actions and api.w3_actions()
                    local costume = S.costume
                    if not (w3a and costume
                        and costume.horse_character) then return end
                    local motion = costume.horse_character:call("get_Motion")
                    local layer = motion and motion:call("getLayer", 0)
                    if layer then
                        layer:call(
                            "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                            w3a.bank, w3a.throw, 0.0, 0.1, 1, 1)
                        pcall(function() layer:call("set_Speed", 1.0) end)
                    end
                end)
                seat_dismount()
                tame_abort("THROWN - it bolts")
                return
            end
            if now >= ro.phase_until then
                ro.phase = "rest"
                ro.phase_until = now + 3.0
            end
        else -- rest
            -- 07-24 (Aurora #3): grip recharges ONLY when LT is RELEASED
            -- — holding on during the breather won't recover you, you
            -- have to let go to catch your grip back.
            tame_card("IT TIRES",
                gripping and "LET GO to catch your grip"
                or "breathe - regain your grip", TAME_GREEN)
            -- 08-12: WALK, not trot. The 08-06 "walk slid / paced on the
            -- spot" that forced the trot was the idle-latch fight (now
            -- fixed); with the body stepping at a real 1.6 m/s the walk
            -- clip 901:1 finally matches its own feet. force_hold so
            -- nothing stomps it.
            if S.costume and S.costume.cmd_clip ~= 1 then
                S.costume.force_hold = true
                S.costume.cmd_bank, S.costume.cmd_clip = 901, 1
                pcall(function()
                    local motion = S.costume.horse_character
                        :call("get_Motion")
                    local layer = motion and motion:call("getLayer", 0)
                    if layer then
                        layer:call(
                            "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                            901, 1, 0.0, 0.35, 1, 1)
                    end
                end)
            end
            if not gripping then
                -- 08-06 r3 (Aurora: "grip regains way too fast"): a 3s rest
                -- now recovers ~half a bar, not all of it -- the duel bites
                ro.grip = math.min(1.0, ro.grip + dt / 6.0)
            end
            -- 08-12: the breather's movement now lives INSIDE the costume-tick
            -- pin (same clock as the position write -- the two-tick split was
            -- the "very stuttery" trot Aurora reported), with a wandering
            -- heading re-rolled every 1-2s. Nothing to do here but let the
            -- trot clip play and the grip recover.
            if now >= ro.phase_until then
                ro.phase = "frenzy"
                ro.phase_until = now + 4.0
                tame.buck_at = now + 0.6
            end
        end
        tame_rodeo_bars(ro.grip, ro.brk, gripping and ro.phase == "frenzy")
        if ro.brk >= 1.0 then
            -- BROKEN: it stands blown; slide off for the sealing palm
            if S.costume then
                S.costume.force_hold = nil
                S.costume.last_gait = nil
            end
            seat_dismount()
            tame.stage = "palm2"
            tame.hold = 0
            tame.rodeo = nil
        end
    elseif tame.stage == "palm2" then
        -- the sealing palm, ON THE GROUND beside the blown horse
        if S.ride_pose_on then
            seat_dismount()
        end
        if n_down and d < 4.5 then
            tame.hold = (tame.hold or 0) + dt
            tame_palm_pose(true)
            -- 07-24 (Aurora #4): the sealing palm matches the passive
            -- tames' "THE PACT" wording
            tame_card("THE PACT", "Hold... the bond takes.")
            tame_charge_bar(tame.hold / 3.0, "The Pact")
            if tame.hold >= 3.0 then
                tame_palm_pose(false)
                -- SEAL: into the IRIS stable + the christening card
                -- ("Name the <gender> horse who chose you") — the same
                -- flow as every other tame
                local record = tame.record
                record.tamed = true
                S.tamed_count = (S.tamed_count or 0) + 1
                local sealed = false
                pcall(function()
                    local bridge = rawget(_G, "IrisGriffinBridge")
                    local ch = get_component(record.game_object,
                        "app.Character")
                    if bridge and bridge.tame_creature and ch then
                        -- 08-10: carry the SUB-VARIANT into the stable record. Without
                        -- it a tamed unicorn's identity is destroyed at tame time --
                        -- before any reload -- and it returns as an ordinary horse.
                        local hv = rawget(_G, "__iris_wild_horses_api")
                        local variant = (hv and hv.is_unicorn
                            and hv.is_unicorn(record.game_object)) and "unicorn" or nil
                        sealed = bridge.tame_creature(
                            ch, tame.gender, "horse", variant) ~= false
                    end
                end)
                ready_tamed_mount(record)
                local christened = false
                if sealed then
                    pcall(function()
                        local taming = rawget(_G, "IrisTaming")
                        if taming and taming.open_christening then
                            taming.open_christening("horse", tame.gender)
                            christened = true
                        end
                    end)
                end
                if christened then
                    S.tame = nil
                    S.status = "TAMED - christen it, then press E/RT beside it to mount"
                    return
                end
                tame.sealed = sealed
                tame.stage = "name" -- panel fallback (no card available)
            end
        else
            tame_palm_pose(false)
            tame_card("THE PACT",
                "Stand before it and hold out your hand (hold N / B).")
        end
    elseif tame.stage == "name" then
        tame_card("NAME IT", "type the name in the IRIS - Horse Rodeo panel")
    end
    tame.n_latch = n_down
end

-- ⭐ r25 KICK FLIGHT TICKER at RENDER TIME: r24 drove the arc from
-- LateUpdateBehavior and the log said "down after 0.76s" while the
-- goblin never visibly moved -- something later in the frame overwrote
-- the transform. The gust drove its flights from re.on_frame (render
-- time, after every game write) and vsibly flew for weeks. Same site now.
local function kick_flights_tick()
    local fls = S.kick_flights
    if not (fls and #fls > 0) then return end
    local nowf = os.clock()
    for i = #fls, 1, -1 do
        local fl = fls[i]
        local te = nowf - (tonumber(fl.t0) or nowf)
        local done = false
        -- ⛔⛔⛔ 08-14: WHY a flight ends decides whether we may still TOUCH the victim.
        -- Both endings below mean the engine owns/owned the body -- see the cleanup block.
        local gone = false
        local okt = pcall(function()
            if not valid(fl.go) then
                done = true
                gone = true   -- despawned mid-arc: every wrapper we hold is now stale
                return
            end
            local hpq = nil
            pcall(function()
                hpq = tonumber((fl.hc or fl.ch):call("get_Hp"))
            end)
            if hpq ~= nil and hpq <= 0 then
                done = true   -- death: native ragdoll takes the corpse
                -- ⚠⚠ get_Hp IS NOT A TRUSTWORTHY DEATH ORACLE HERE. This function's own r34
                -- note (below) records that on enemies it is "usually the WRONG getter ...
                -- read 0 there and BAILED" -- i.e. it returns 0 for bodies that are alive.
                -- Ending the arc on that reading is fine (it always did), but declaring the
                -- body UNTOUCHABLE on it is not: a false positive would skip the component
                -- restore in the cleanup and leave a LIVE enemy frozen forever with its AI,
                -- nav and CharacterController disabled and ragdoll forced on. Confirm with
                -- get_IsDead -- the same second signal doe_is_alive uses
                -- (IrisWildHorses.lua:1878) -- and only then stop touching it.
                pcall(function()
                    if fl.ch:call("get_IsDead") == true then gone = true end
                end)
                return
            end
            if fl.rag_pause_at and nowf >= fl.rag_pause_at then
                fl.rag_pause_at = nil
                pcall(function()
                    local rt = sdk.find_type_definition(
                        "via.dynamics.Ragdoll"):get_runtime_type()
                    local rd = fl.go:call(
                        "getComponent(System.Type)", rt)
                    if rd then
                        rd:call("set_RagdollStateName(System.String)",
                            "dmg_throw_pause")
                    end
                end)
            end
            -- r34 DAMAGE MOVED TO LANDING (Aurora: "not sure it's doing
            -- damage"): the mid-air setHp read hp off get_Hp, which for
            -- enemies is usually the WRONG getter (the probe's own
            -- lesson: "read 0 there and BAILED") -- so the write went
            -- nowhere real. The landing handler below now feeds the
            -- probe's field-proven griffin_apply_attack_damage instead
            -- (multi-getter read + updateDamageHp + setHp ladder).
            -- Grounded-only because updateDamageHp threw a native
            -- exception on airborne victims (the gust law).
            local grav = 14.0
            local nx = fl.x0 + fl.vx * te
            local nz = fl.z0 + fl.vz * te
            local ny = fl.y0 + fl.vy * te - 0.5 * grav * te * te
            local gy = nil
            pcall(function()
                local ground = rawget(_G, "route3_ground_below_uni")
                local hit = ground and ground(
                    nx, fl.y0 + 2.0, nz, 2.0, 12.0)
                if hit then gy = tonumber(hit.y) end
            end)
            if te > 0.15 and gy and ny <= gy then
                ny = gy
                done = true
            elseif te >= (tonumber(fl.dur) or 0.8) + 1.2 then
                done = true
            end
            local tf = fl.go:call("get_Transform")
            local pos = tf:call("get_UniversalPosition")
            pos.x, pos.y, pos.z = nx, ny, nz
            tf:call("set_UniversalPosition", pos)
        end)
        -- a throw from inside the arc means one of our wrappers already misbehaved -- treat the
        -- body as gone rather than poking it further to find out.
        if not okt then done = true; gone = true end
        if done and gone then
            -- ⛔⛔⛔ THE VICTIM IS DEAD OR DESPAWNED. TOUCH NOTHING.
            -- The block below this one restores components, un-ragdolls and applies damage -- all
            -- of it CALLS INTO the body. Running that against a corpse the engine is tearing down
            -- is what corrupted the heap tonight: 7x "REManagedObject:release attempted to release
            -- an object that was not managed by our Lua state" over 8 minutes of kick-spam, then a
            -- c0000005 with RIP=0 (a call through a freed vtable).
            -- ⭐ There is nothing to restore anyway: a dead body's AI/nav/controller state is the
            -- engine's problem now, and the damage that would be applied is moot -- it is already
            -- dead. Drop every wrapper THIS INSTANT and force one batched collect, per the law the
            -- 08-12 blessing shell CTD established: never let a lazy GC release a wrapper against
            -- an object the engine has already freed.
            fl.go, fl.ch, fl.hc, fl.disabled, fl.ragdolled = nil, nil, nil, nil, nil
            S.kick_gc_at = math.min(tonumber(S.kick_gc_at) or math.huge, nowf + 0.10)
            log("kick flight: victim died/despawned mid-arc -- refs dropped, body untouched")
            table.remove(fls, i)
        elseif done then
            pcall(function()
                if fl.ragdolled then
                    fl.ch:call("set_IsForceEnableRagdoll", false)
                end
            end)
            for _, ccx in ipairs(fl.disabled or {}) do
                pcall(function() ccx:call("set_Enabled", true) end)
            end
            -- r34: damage lands WITH the body (see note above). The
            -- probe's applicator wants the app.Character.
            pcall(function()
                local dmg = tonumber(C.kick_damage) or 180.0
                local dealt = false
                local dmg_fn = rawget(_G,
                    "griffin_apply_attack_damage")
                if dmg_fn then
                    dealt = dmg_fn(fl.ch, dmg) == true
                end
                if not dealt and fl.hc then
                    -- probe not loaded: last-resort ladder on the
                    -- component HC
                    local curh = tonumber(fl.hc:call("get_Hp"))
                    if curh and curh > 0 then
                        local newh = math.max(0.0, curh - dmg)
                        pcall(function()
                            fl.hc:call(
                                "setHp(System.Single, System.Boolean, System.Int32)",
                                newh, true, 0)
                        end)
                        dealt = true
                    end
                end
                log("kick damage: "
                    .. (dealt and "dealt" or "FAILED (see probe hud)"))
            end)
            log(string.format("kick flight: down after %.2fs", te))
            table.remove(fls, i)
        end
    end
    if #fls == 0 then S.kick_flights = nil end
    -- ⭐ THE FORCED COLLECT (law from the 08-12 blessing shell CTD: any Lua that wraps a
    -- short-lived engine object must force-collect right after dropping it -- lazy GC + engine
    -- lifetime is exactly the double-release signature above). Deadline-batched so a scrum where
    -- six things die at once still costs ONE collection, not six.
    if S.kick_gc_at and os.clock() >= S.kick_gc_at then
        S.kick_gc_at = nil
        collectgarbage("collect")
    end
end

re.on_frame(function()
    if S.generation ~= GENERATION then return end
    kick_flights_tick()
    mounted_weapon_tick(false)
    -- Cross-module ownership for the shared N key.  IrisTaming reads this
    -- before it acquires/arms a generic creature, so one press can never
    -- start two different rites.  Keep the claim for the whole horse rite,
    -- even if the camera moves during the rodeo.
    local focus = S.tame and S.tame.record or focused_wild_horse(9.0)
    if not (focus and valid(focus.game_object)) then focus = nil end
    S.focused_wild_horse = focus
    rawset(_G, "__iris_horse_taming_claim_addr",
        focus and object_address(focus.game_object) or nil)
    -- 08-13 (Aurora: "make sure the B to tame notification appears over the Horse/Unicorn"):
    -- publish the GameObject too, not just its address. IrisTaming owns every tame marker and the
    -- native B prompt, and it cannot draw over an address -- it needs the object. Additive; the
    -- addr key keeps its existing readers.
    rawset(_G, "__iris_horse_taming_claim_go", focus and focus.game_object or nil)
    -- ⭐ 08-13 (Aurora #2: "the 'Tame the Unicorn' B prompt should disappear once taming has
    -- started"). The claim above deliberately KEEPS naming the horse for the WHOLE rite -- the pad
    -- gate in tame_tick and IrisTaming's start-guard both depend on that -- so from the outside
    -- "you may begin" and "you are three seconds into THE PALM" look identical, and IrisTaming went
    -- on advertising B over a horse already being tamed. Publish the rite state as its own key so
    -- the marker/prompt owner can stand down without losing the claim.
    -- (Read one frame late: tame_tick runs later in this same on_frame. A prompt does not care.)
    rawset(_G, "__iris_horse_taming_rite_active", (S.tame ~= nil) or nil)
    if S.costume_stop_requested then
        S.costume_stop_requested = nil
        if S.ride_pose_on then seat_dismount() end
        costume_stop()
    end
    -- 07-24 "all doe and horses seem invincible": the mount hardening
    -- (IsInvincible/IsNoDie at costume start) LEAKS across script
    -- reloads — S.costume is wiped, costume_stop's restore never runs,
    -- and every test iteration strands one immortal horse. One-shot
    -- sweep at load clears the flags on every doe/horse body (ch299011
    -- ONLY — native oxen may carry legit protection, never touch them).
    if not S.invincibility_swept
        and os.clock() - (S.loaded_at or 0) > 2.0 then
        S.invincibility_swept = true
        pcall(function()
            local scene_manager = sdk.get_native_singleton(
                "via.SceneManager")
            local scene_type = sdk.find_type_definition("via.SceneManager")
            local scene = sdk.call_native_func(
                scene_manager, scene_type, "get_CurrentScene()")
            local characters = scene and scene:call(
                "findComponents(System.Type)",
                sdk.typeof("app.Character"))
            local cleared = 0
            for _, character in ipairs(
                characters and characters:get_elements() or {}) do
                pcall(function()
                    local id = tostring(
                        character:call("get_CharaIDString"))
                    if not id:match("^ch299011") then return end
                    local go = character:call("get_GameObject")
                    local hc = go
                        and get_component(go, "app.HitController")
                    if not hc then return end
                    if hc:call("get_IsInvincible") == true
                        or hc:call("get_IsNoDie") == true then
                        hc:call("set_IsInvincible", false)
                        hc:call("set_IsNoDie", false)
                        cleared = cleared + 1
                    end
                end)
            end
            if cleared > 0 then
                log("invincibility sweep: cleared " .. cleared
                    .. " leaked horse(s)")
            end
        end)
    end
    -- A bound ghost shadows the first horse at ALL times, co-located —
    -- INDEPENDENT of the rodeo toggle (07-23: module off = pin dead = the
    -- ghost parks beside the horse and Aurora climbed thin air).
    -- pin gated on an explicit toggle: pinning with LIVE colliders and no
    -- pair-ignore = mutual-press rocket (one dead horse, 07-23, o7)
    if S.ghost and S.ghost.pin_enabled
        and S.stage ~= "rodeo" and S.stage ~= "latching" then
        local record = horses()[1]
        if record then pin_ghost_to_horse(record.game_object) end
    end
    -- summon orchestration: once BOTH conjured bodies are live nearby, the
    -- costume dresses itself (costume_start is self-locating and idempotent
    -- in failure: it just sets a status until both exist). Deliberately
    -- ABOVE the enabled gate: the summon button is an explicit press and
    -- must finish its job whether or not the rodeo toggle is on (07-23:
    -- toggle off = watcher dead = "doesn't change to mount ready")
    if S.summon_watch and not S.costume then
        if os.clock() - S.summon_watch > 25 then
            S.summon_watch = nil
            S.status = "summon: timed out waiting for the pair"
        elseif os.clock() - (S.summon_try or 0) > 2.0 then
            S.summon_try = os.clock()
            costume_start()
            if S.costume then
                S.summon_watch = nil
                S.status = "summon: MOUNT READY — climb on"
            end
        end
    end
    dismount_hold_tick()
    -- MOUNT CAPTURE tick (above the rodeo gate — mount UX, not rodeo
    -- gameplay): a sustained native climb on the costume = boarding;
    -- E/RT while seated = dismount
    if S.costume and valid(S.costume.horse_go) then
        if not S.ride_pose_on then
            -- OXLESS press-to-mount: no climbable body exists, a plain
            -- E/RT beside the horse mounts; the suppression window keeps
            -- the native grab from deadlifting the horse meanwhile
            if S.costume.oxless then
                local ppos = universal_pos(player_game_object())
                local hpos = universal_pos(S.costume.horse_go)
                local near_d = (ppos and hpos)
                    and distance(ppos, hpos) or 99.0
                local pressed = grab_pressed()
                if near_d < 4.5 then
                    S.suppress_grab_until = os.clock() + 0.3
                    if pressed and not S.mount_press_latch
                        and os.clock()
                            >= (S.mount_cooldown_until or 0) then
                        seat_mount()
                    end
                end
                S.mount_press_latch = pressed
            end
            -- 07-23 field find (diag line): get_IsClimbing = walls/ladders
            -- and reads FALSE during a monster-cling; the proven probe is
            -- get_IsClimbOnCharacter + the target-verified ClimbCtrl check
            -- (also immune to stale climb flags from earlier experiments)
            local player = player_character()
            local climb_on = false
            pcall(function()
                climb_on = player
                    and player:call("get_IsClimbOnCharacter") == true
            end)
            local on_ours = false
            if climb_on and player then
                on_ours = player_climbing_target(player, S.costume.ox_go)
                    or player_climbing_target(player, S.costume.horse_go)
            end
            local cooling = os.clock() < (S.mount_cooldown_until or 0)
            if climb_on and on_ours and not cooling then
                S.mount_climb_since = S.mount_climb_since or os.clock()
                -- settle beat: let the native grab visibly land first
                if os.clock() - S.mount_climb_since > 0.35 then
                    seat_mount()
                end
            else
                S.mount_climb_since = nil
            end
            S.mount_capture_diag = cooling
                and string.format("dismount cooldown %.1fs",
                    (S.mount_cooldown_until or 0) - os.clock())
                or string.format(
                    "climb-on=%s | on OUR mount=%s | hold %.2fs",
                    tostring(climb_on), tostring(on_ours),
                    S.mount_climb_since
                        and (os.clock() - S.mount_climb_since) or 0.0)
        else
            -- r43: the deferred deterministic park -- freeze the native
            -- body only after the commanded FallLoop has reset it
            local seat_pk = S.costume and S.costume.seat
            if seat_pk and seat_pk.park_at
                and os.clock() >= seat_pk.park_at then
                seat_pk.park_at = nil
                pcall(function()
                    local fsm = get_component(seat_pk.player_go,
                        "via.motion.MotionFsm2")
                    if fsm then fsm:call("set_Enabled", false) end
                end)
                pcall(function()
                    local mo = player_character():call("get_Motion")
                    if mo then mo:call("set_PlaySpeed", 0.0) end
                end)
                log("park: frozen from FallLoop base"
                    .. " (deterministic underlay)")
            end
            -- mount-up vault -> seated pose handoff
            local seat = S.costume.seat
            if seat and seat.pose_stage == "mountup"
                and os.clock() > (seat.pose_until or 0) then
                seat.pose_stage = "loop"
                -- r48 ATOMIC HANDOFF (Aurora: "the mounting animation
                -- itself throwing the position off if it ends at
                -- certain times"): the vault had TWO clocks -- pose
                -- switched at 90% of the window while the enter lerp
                -- kept driving the base to 100%. That 10% overlap made
                -- the landing state depend on frame timing. Now the
                -- handoff is one atomic instant: pose swaps AND the
                -- lerp dies AND the seat snaps to the pure formula
                -- (captured sliders) in the same frame, every mount.
                seat.enter = nil
                S.seat_pose_report = seat_play_ride_pose("calm")
                S.status = "MOUNTED [" .. S.seat_pose_report
                    .. (S.costume.wyrm_kind
                        and "] — E/L3 to dismount"
                        or "] — E/RT to dismount")
            end
            -- GAIT-AWARE pose switch (calm <-> active) with hysteresis
            if seat and seat.pose_stage == "loop" then
                local cur = (S.costume and S.costume.cur_speed) or 0.0
                local threshold = ((C.speed_walk or 1.6)
                    + (C.speed_run or 3.4)) * 0.5
                local want = (cur >= threshold) and "active" or "calm"
                if want ~= (seat.pose_variant or "calm")
                    and os.clock() > (seat.pose_switch_at or 0) then
                    seat.pose_switch_at = os.clock() + 0.6
                    S.seat_pose_report = seat_play_ride_pose(want)
                end
                -- r34 POSE WATCHDOG (Aurora: "strange mount positions,
                -- different every time" -- the log's seat probe shows
                -- the ANCHOR is deterministic; the variance is the
                -- puppet-parked body keeping a random frozen climb
                -- frame whenever the ride pose isn't actually painting:
                -- a mount-time play hiccup, or another IRIS module
                -- borrowing the shared NB_Pose player). Once a second:
                -- if the lab isn't playing OUR clip, re-assert it.
                if not (S.costume and (S.costume.pose_only
                    or S.costume.passenger_only))
                    and os.clock() > (seat.pose_check_at or 0) then
                    seat.pose_check_at = os.clock() + 1.0
                    pcall(function()
                        local pose = rawget(_G, "NB_Pose")
                        if not (pose and pose.is_playing) then
                            -- r36: log the absence ONCE -- an old
                            -- rs_anim_lab without current() means the
                            -- watchdog was silently blind
                            if not seat.wd_logged then
                                seat.wd_logged = true
                                log("watchdog: NB_Pose bridge missing"
                                    .. " is_playing/current")
                            end
                            return
                        end
                        if not seat.wd_logged then
                            seat.wd_logged = true
                            log("watchdog live: clip="
                                .. tostring(pose.current
                                    and pose.current() or "?")
                                .. " playing="
                                .. tostring(pose.is_playing()))
                        end
                        local v = seat.pose_variant or "calm"
                        -- r51: keep in lockstep with seat_play_ride_pose
                        -- (calm rides the loop now unless disabled)
                        local want_clip = (v == "active"
                            or v == "gsprint"
                            or C.calm_use_loop ~= false)
                            and "rs_wilds_ride_loop"
                            or "rs_wilds_ride_neutral"
                        local cur_clip = pose.current
                            and tostring(pose.current()) or "?"
                        if pose.is_playing() ~= true
                            or cur_clip ~= want_clip then
                            S.seat_pose_report =
                                seat_play_ride_pose(v)
                            log("pose watchdog: re-asserted ("
                                .. cur_clip .. " -> "
                                .. want_clip .. ")")
                        end
                    end)
                end
                -- r40 SEAT ENFORCER (r39 fingerprint NAMED the thief:
                -- every good mount rides with action=FallLoop = native
                -- brain parked; the stolen mount rode with
                -- action=NormalLocomotion = the ground mover survived
                -- or revived past the mount-time park, and its writes
                -- beat ours -- rider walks at the horse's head). If
                -- the native action is ever NormalLocomotion while
                -- seated, re-run the whole park on the spot.
                if not (S.costume and (S.costume.pose_only
                    or S.costume.passenger_only))
                    and os.clock() > (seat.enforce_at or 0) then
                    -- Wyrm rides own their mount and rider action state.  A
                    -- quarter-second watchdog fought each attack animation and
                    -- generated needless action/component churn; a one-second
                    -- safety check is sufficient for this chassis.
                    local wyrm_seat = S.costume and S.costume.wyrm_kind
                    seat.enforce_at = os.clock() + (wyrm_seat and 1.0 or 0.25)
                    -- Keep DD2's rescue recorder on the last GROUNDED ride
                    -- point, never blindly on the saddle. Gluing it to an
                    -- airborne/submerged horse poisoned the player's respawn
                    -- coordinate and produced an endless Brine-under-floor loop.
                    pcall(function()
                        local hp0 = S.mount_last_safe_ground
                        if hp0 then
                            feed_player_safe_position(
                                hp0.x, hp0.y, hp0.z, true)
                        end
                    end)
                    pcall(function()
                        local pl = player_character()
                        local am = nil
                        pcall(function()
                            am = pl["<ActionManager>k__BackingField"]
                        end)
                        if not am then
                            am = pl:call("get_ActionManager")
                        end
                        -- r49 CLING KILLER (the off-angle rotated seats:
                        -- the native monster-cling latches on the mount
                        -- press and orients the body by GRAB ANGLE --
                        -- perpendicular grabs align, diagonal grabs sit
                        -- her rotated. seat_mount's endClimb trio runs
                        -- ONCE, before a late-latching cling lands).
                        -- While seated: any live climb-on-character
                        -- gets the full trio, every check.
                        if player_climbing_on(pl) then
                            pcall(function()
                                pl:call("endClimb")
                                pl:call("requestEndClimb")
                                pl:call("set_IsSetClimbActionByRequest",
                                    false)
                            end)
                            log("seat enforcer: live cling KILLED"
                                .. " (climb-on-character while seated)")
                        end
                        local it = am.CurrentActionList[0]
                        local act = tostring(it.Name
                            or it:call("get_Name"))
                        -- r46: ANY action other than the parked
                        -- FallLoop is a violation -- r43's landing
                        -- chain (VerticalJumpLanding etc.) sailed past
                        -- the NormalLocomotion-only check, and ground
                        -- actions re-enable the CharacterController,
                        -- whose cached position then beats every
                        -- transform write we make
                        if act ~= "FallLoop" and not (wyrm_seat and S.wyrm_atk_until) then
                            suppress_player_components(seat.player_go)
                            pcall(function()
                                local fsm = get_component(
                                    seat.player_go,
                                    "via.motion.MotionFsm2")
                                if fsm then
                                    fsm:call("set_Enabled", false)
                                end
                            end)
                            pcall(function()
                                local mo = pl:call("get_Motion")
                                if mo then
                                    mo:call("set_PlaySpeed", 0.0)
                                end
                            end)
                            -- r41 (00:08 log: component re-park alone
                            -- did NOT stick -- NormalLocomotion came
                            -- back every second on the 180° mounts):
                            -- swap the ACTION itself. Proven player
                            -- lever = IrisWoodcutting's chop cancel
                            -- (requestActionCore priority 10); we
                            -- request the parked FallLoop the good
                            -- mounts all ride in.
                            local okf = pcall(function()
                                am:call(
                                    "requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)",
                                    10, "FallLoop", 0)
                            end)
                            log("seat enforcer: re-parked + FallLoop"
                                .. " requested (" .. tostring(okf)
                                .. ", action was " .. act .. ")")
                        end
                    end)
                end
            end
            -- griffin passenger: RT is the griffin mod's territory — our
            -- dismount moves to L3 (its own control language); horse
            -- keeps E/RT
            local pressed
            if S.costume and S.costume.passenger_only then
                if S.costume.bridge_managed then
                    -- probe-driven ride: ITS L3 handler dismounts us via
                    -- the bridge (it owns the land-first rule)
                    pressed = false
                else
                    pressed = l3_pressed()
                end
            elseif S.costume and S.costume.wyrm_kind then
                -- RT belongs to the contextual maul while riding ch223.  Keep E
                -- for keyboard and move the controller dismount to L3, matching
                -- the griffin's established mounted control language.
                pressed = keyboard_grab_pressed() or l3_pressed()
            else
                pressed = grab_pressed()
            end
            if pressed and not S.seat_key_latch
                and os.clock() - (S.seat_started or 0) > 1.0 then
                seat_dismount()
            end
            S.seat_key_latch = pressed
        end
    end
    -- THE TAME rite (above the rodeo gate — this IS the taming feature)
    pcall(tame_tick)
    if not C.enabled then return end
    local now = os.clock()
    if not grab_pressed() then S.grab_latch = false end
    if S.stage == "rodeo" then
        rodeo_tick(now)
    elseif S.stage == "latching" then
        latching_tick(now)
    else
        idle_tick()
    end
end)

re.on_draw_ui(function()
    if S.generation ~= GENERATION then return end
    if not imgui.collapsing_header("IRIS - Horse Rodeo") then return end
    -- TOP of the panel, ungated (07-24 "where are these probes?" — it
    -- was buried in the costume-only section, and the REAL-climb
    -- reading needs no costume armed at all)
    if imgui.button(
        "PROBE: player fall/climb/grab state -> log##fallprobe") then
        run_fall_probe()
    end
    imgui.same_line()
    imgui.text("(press during a REAL climb, again mid-flight; check"
        .. " re log)")

    local changed, value
    changed, value = imgui.checkbox("Enabled##iris_rodeo", C.enabled)
    if changed then
        C.enabled = value
        save_config()
        if not value and S.stage == "rodeo" then end_rodeo("released") end
    end

    imgui.text("Stage: " .. tostring(S.stage))
    if imgui.tree_node("Blessing cooldown HUD alignment") then
        imgui.text("  Gamepad draws a circle; keyboard draws a square.")
        imgui.text("  Offsets are 1080p pixels and scale with resolution.")
        local function blessing_hud_slider(label, key, lo, hi)
            local ch, v = imgui.slider_float(label .. "##" .. key,
                tonumber(C[key]) or 0.0, lo, hi, "%.1f")
            if ch then C[key] = v; save_config() end
        end
        blessing_hud_slider("Gamepad X", "blessing_hud_pad_dx", -120.0, 120.0)
        blessing_hud_slider("Gamepad Y", "blessing_hud_pad_dy", -120.0, 120.0)
        blessing_hud_slider("Keyboard X", "blessing_hud_keyboard_dx", -120.0, 120.0)
        blessing_hud_slider("Keyboard Y", "blessing_hud_keyboard_dy", -120.0, 120.0)
        local sch, sv = imgui.slider_float("Ring size##blessing_hud_size",
            tonumber(C.blessing_hud_size) or 1.0, 0.50, 2.00, "%.2f")
        if sch then C.blessing_hud_size = sv; save_config() end
        if imgui.button("Reset blessing HUD alignment##blessing_hud_reset") then
            C.blessing_hud_pad_dx, C.blessing_hud_pad_dy = 0.0, 0.0
            C.blessing_hud_keyboard_dx, C.blessing_hud_keyboard_dy = 0.0, 0.0
            C.blessing_hud_size = 1.0
            save_config()
        end
        imgui.tree_pop()
    end
    if S.prompt then imgui.text(">> " .. S.prompt) end
    if S.ride then
        imgui.text(string.format(
            "GRIP %.0f%% | %s | %.1fs left",
            math.max(0, S.ride.grip / C.grip_max * 100),
            S.ride.bucking and "BUCKING" or "calm",
            math.max(0, C.rodeo_secs - (os.clock() - S.ride.started))))
        if imgui.button("Bail out") then end_rodeo("released") end
    end
    if S.ghost then
        imgui.text("GHOST RIG: " .. tostring(S.ghost.id or "?")
            .. (valid(S.ghost.go) and " (bound)" or " (LOST)"))
        imgui.same_line()
        if imgui.button("Release##ghost") then release_ghost_rig() end
        if S.ghost and valid(S.ghost.go) then
            local ts = S.ghost.think_stopped or false
            local changed_ts, want_ts = imgui.checkbox(
                "Ghost: think-stop (calms struggling; may block the latch)##gts",
                ts)
            if changed_ts then
                pcall(function()
                    local ch = S.ghost.character
                    if ch then
                        ch:call("set_IsThinkStop", want_ts == true)
                        S.ghost.think_stopped = want_ts == true
                    end
                end)
            end
            local pin_on = S.ghost.pin_enabled or false
            local changed_pin, want_pin = imgui.checkbox(
                "PIN ghost to horse (kills its CC — the real one)##gpin",
                pin_on)
            if changed_pin then
                S.ghost.pin_enabled = want_pin == true
                -- THE REAL CC lever (07-23): component set_Enabled on the CC
                -- is a silent no-op (homestead law); the working call is the
                -- character's setCharacterControllerEnable — same one the
                -- ride uses on the horse. Live CC capsule = the rocket.
                -- CC-off also removes ground support, so it dies exactly
                -- when the pin (the new support) engages, returns on unpin.
                pcall(function()
                    S.ghost.character:call(
                        "setCharacterControllerEnable", not S.ghost.pin_enabled)
                end)
            end
            local vis = S.ghost.visible or false
            local changed_vis, want_vis = imgui.checkbox(
                "Ghost VISIBLE (debug — rendering only, zero collision)##gvis",
                vis)
            if changed_vis then
                pcall(function()
                    local mesh = get_component(S.ghost.go, "via.render.Mesh")
                    if mesh then
                        mesh:call("set_Enabled", want_vis == true)
                        S.ghost.visible = want_vis == true
                    end
                end)
            end
            if imgui.button("PAIR-EXCLUDE: ghost joins horse collision group##pairex") then
                local horse_record = horses()[1]
                local ok, detail = false, "?"
                pcall(function()
                    local horse_pc = get_component(
                        horse_record.game_object, "via.physics.Colliders")
                    local ghost_pc = get_component(
                        S.ghost.go, "via.physics.Colliders")
                    local horse_fi = horse_pc:call("getCollider", 0)
                        :call("get_FilterInfo")
                    local horse_group = horse_fi:call("get_Group")
                    local ghost_collider = ghost_pc:call("getCollider", 0)
                    local ghost_fi = ghost_collider:call("get_FilterInfo")
                    ghost_fi:call("set_Group", horse_group)
                    pcall(function()
                        ghost_collider:call("updateCollisionFilter")
                    end)
                    pcall(function()
                        ghost_pc:call("updateCollisionFilter")
                    end)
                    detail = "ghost group -> " .. tostring(horse_group)
                    ok = true
                end)
                S.status = "pairex: " .. (ok and detail or "FAILED (see order: bind + live horse first)")
            end
            if imgui.button("DUMP press/RSC apis -> data##pressdump") then
                local lines = {}
                -- FILTER INFO route: per-collider filter structure on both
                -- bodies (homestead law: Colliders has NO set_Enabled; the
                -- filter data lives per-collider + updateCollisionFilter()).
                local horse_record = horses()[1]
                local sides = {
                    {"GHOST", S.ghost.go},
                    {"HORSE", horse_record and horse_record.game_object},
                }
                for _, side in ipairs(sides) do
                    local label, go = side[1], side[2]
                    lines[#lines + 1] = "== " .. label
                    if not (go and valid(go)) then
                        lines[#lines + 1] = "  (no body)"
                    else
                        local pc = get_component(go, "via.physics.Colliders")
                        if not pc then
                            lines[#lines + 1] = "  no Colliders"
                        else
                            local count = 0
                            for _, getter in ipairs({"get_NumColliders",
                                                     "getNumColliders"}) do
                                pcall(function()
                                    count = tonumber(pc:call(getter)) or count
                                end)
                                if count > 0 then break end
                            end
                            lines[#lines + 1] = "colliders: " .. tostring(count)
                            for i = 0, math.min(count, 12) - 1 do
                                pcall(function()
                                    local collider = pc:call("getCollider", i)
                                    if not collider then return end
                                    local shape_name = "?"
                                    pcall(function()
                                        shape_name = collider:call("get_Shape")
                                            :get_type_definition():get_full_name()
                                    end)
                                    local fi = nil
                                    pcall(function()
                                        fi = collider:call("get_FilterInfo")
                                    end)
                                    if fi then
                                        local ftd = fi:get_type_definition()
                                        local desc = {}
                                        for _, method in ipairs(ftd:get_methods()) do
                                            local mname = method:get_name()
                                            if mname:find("^get_") then
                                                pcall(function()
                                                    desc[#desc + 1] = mname:sub(5)
                                                        .. "=" .. tostring(
                                                            fi:call(mname))
                                                end)
                                            end
                                        end
                                        lines[#lines + 1] = string.format(
                                            "  [%d] %s | %s | %s", i, shape_name,
                                            ftd:get_full_name(),
                                            table.concat(desc, " "))
                                    else
                                        lines[#lines + 1] = string.format(
                                            "  [%d] %s | no FilterInfo",
                                            i, shape_name)
                                    end
                                end)
                            end
                        end
                    end
                end
                pcall(function()
                    json.dump_file("GhostPressDump.json", lines)
                end)
                S.status = "press apis -> data/GhostPressDump.json"
            end
            -- RSC layer mask: hunt the PRESS layer bit while the climb
            -- layer stays live. Try each bit; win = push gone, grab works.
            if S.ghost.rsc then
                S.ghost.layer_bit = S.ghost.layer_bit or 0
                local bit_changed, bit_value = imgui.slider_int(
                    "RSC disable-layer BIT (0=none)##rscbit",
                    S.ghost.layer_bit, 0, 31)
                if bit_changed then
                    S.ghost.layer_bit = bit_value
                    pcall(function()
                        local mask = 0
                        if bit_value > 0 then mask = 2 ^ bit_value end
                        S.ghost.rsc:call("set_DisableLayerBits",
                            math.floor(mask))
                    end)
                end
            end
            -- GHOST LAB: live component toggles for hunting the pusher.
            -- Flip ONE at a time while watching the idle push / climb shake.
            imgui.text("-- ghost lab (flip one, watch the push) --")
            local horse_record = horses()[1]
            local lab = {
                {"G brain", S.ghost.go, "app.AIDecisionMaker"},
                {"G nav", S.ghost.go, "app.MonsterNavigationController"},
                {"G pressRec", S.ghost.go, "app.RegisteredPressRequestSetRecorder"},
                {"G skinHold", S.ghost.go, "app.SkinningMeshColliderHolder"},
                {"G skinUpd", S.ghost.go, "app.SkinningMeshColliderUpdater"},
                {"G seq", S.ghost.go, "app.SequenceController"},
                {"H colliders", horse_record and horse_record.game_object,
                 "via.physics.Colliders"},
                {"H skinHold", horse_record and horse_record.game_object,
                 "app.SkinningMeshColliderHolder"},
                {"H pressRec", horse_record and horse_record.game_object,
                 "app.RegisteredPressRequestSetRecorder"},
            }
            for i, entry in ipairs(lab) do
                local label, go, type_name = entry[1], entry[2], entry[3]
                if go and valid(go) then
                    local comp = get_component(go, type_name)
                    if comp then
                        local on = false
                        pcall(function() on = comp:call("get_Enabled") end)
                        local chg, want = imgui.checkbox(
                            label .. "##lab" .. i, on == true)
                        if chg then
                            pcall(function()
                                comp:call("set_Enabled", want == true)
                            end)
                        end
                        if i % 2 == 1 then imgui.same_line() end
                    end
                end
            end
        end
    else
        if imgui.button("Bind ghost rig (nearest spawned monster)") then
            bind_ghost_rig()
        end
    end
    if S.costume then
        -- 07-24: griffin pose-only ride has no ox/costume — label it for
        -- what it is so the SEAT FIT — GRIFFIN groups below are findable
        -- (Aurora "couldn't do positioning from there")
        if S.costume.pose_only then
            imgui.text_colored(
                ">> GRIFFIN MOUNT — seat tuning in SEAT FIT groups below",
                0xFF66FFCC)
        else
            imgui.text("COSTUME RIG: horse is wearing the ox")
        end
        imgui.same_line()
        -- DEFERRED stop (07-23 draw crash): niling S.costume mid-draw left
        -- the rest of this frame's panel indexing a nil costume — the
        -- actual stop runs at the top of the next on_frame instead
        if imgui.button("Stop##costume") then
            S.costume_stop_requested = true
        end
        -- GAIT LAB: evidence before commands. Walk/run the ox around and
        -- watch what each body's layer 0 ACTUALLY plays.
        local ox = valid(S.costume.ox_go) and read_layer0(S.costume.ox_go)
        local horse = valid(S.costume.horse_go)
            and read_layer0(S.costume.horse_go)
        local function fmt(tag, r)
            if not r then return tag .. ": (no layer)" end
            return string.format(
                "%s: bank=%d id=%d frame=%.0f/%.0f spd=%.2f",
                tag, r.bank, r.id, r.frame, r.endf, r.speed or -1)
        end
        imgui.text(fmt("OX   ", ox))
        imgui.text(fmt("HORSE", horse))
        -- CLIMB SUSPECT toggles ("can't climb it right now" 07-23): the
        -- hardening changed three things since climb last worked — flip
        -- each live and try to grab, the one that restores climb is guilty
        local function ox_toggle(label, key, get_state, set_state)
            local cur = S[key]
            if cur == nil then cur = get_state() end
            local ch, want = imgui.checkbox(label, cur == true)
            if ch then
                S[key] = want == true
                pcall(function() set_state(want == true) end)
            end
        end
        local ox_go = S.costume.ox_go
        ox_toggle("ox brain (AIDecisionMaker)", "climb_ox_brain",
            function()
                local ai = get_component(ox_go, "app.AIDecisionMaker")
                return ai and ai:call("get_Enabled") == true
            end,
            function(v)
                local ai = get_component(ox_go, "app.AIDecisionMaker")
                if ai then ai:call("set_Enabled", v) end
            end)
        local sc_ch, sc_v = imgui.slider_float(
            "ox scale (climb-body fit)##oxsc", S.ox_scale or 0.94,
            0.5, 1.5)
        if sc_ch then
            S.ox_scale = sc_v
            pcall(function()
                ox_go:call("get_Transform"):call("set_LocalScale",
                    Vector3f.new(sc_v, sc_v, sc_v))
            end)
        end
        imgui.text(string.format(
            "measured ox speed=%.2f m/s | last commanded gait id=%s%s",
            S.costume.speed or 0,
            tostring(S.costume.last_gait or "none"),
            S.costume.force_hold and " | FORCE HOLD (matcher off)" or ""))
        -- force-clip test: does changeMotion take AT ALL on the shell?
        local fb_changed, fb = imgui.slider_int(
            "test bank##costume_fb",
            math.floor(S.costume_test_bank or 0), 0, 950)
        if fb_changed then S.costume_test_bank = fb end
        local fc_changed, fc = imgui.slider_int(
            "test clip id##costume_fc",
            math.floor(S.costume_test_id or 100), 0, 400)
        if fc_changed then S.costume_test_id = fc end
        if imgui.button("Force test clip on HORSE##costume_fc") then
            S.costume.force_hold = true
            -- feed the loop assist too: non-loop clips (112) auto-rewind
            S.costume.cmd_bank = math.floor(S.costume_test_bank or 0)
            S.costume.cmd_clip = math.floor(S.costume_test_id or 100)
            pcall(function()
                local motion = S.costume.horse_character:call("get_Motion")
                local layer = motion and motion:call("getLayer", 0)
                if layer then
                    layer:call(
                        "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                        math.floor(S.costume_test_bank or 0),
                        math.floor(S.costume_test_id or 100), 0.0, 0.35,
                        1, 1)
                end
            end)
        end
        imgui.same_line()
        if imgui.button("Release hold##costume_fc") then
            S.costume.force_hold = nil
            S.costume.last_gait = nil
            S.costume.cmd_bank = nil
            S.costume.cmd_clip = nil
        end
        -- THE REINS: Up=trot, +Shift=gallop, +Ctrl=walk, Left/Right=turn
        imgui.text("REINS: Up-arrow = ride (+Shift gallop, +Ctrl walk), "
            .. "Left/Right = turn")
        -- SEAT LOCK v2 (07-23, Aurora's mounting UX: walk onto the back
        -- and sit — no cling needed): pin the player to the seat joint
        -- every LateUpdate (couples law), suppress the player's physics
        -- + motion FSM, paint the Wilds saddle pose over the top. The
        -- seat height/forward sliders in Advanced tune the perch — the
        -- Wilds clip's painted hip-lift floats a horse rider, so expect
        -- to pull seat height DOWN.
        if S.costume and S.costume.passenger_only and S.ride_pose_on then
            imgui.text("GRIFFIN SEAT: dismount = L3 (RT stays the"
                .. " griffin mod's)")
            if imgui.button("FORCE DISMOUNT (griffin experiment)##gexpoff")
                then
                seat_dismount()
            end
            imgui.text("(the griffin mod may still think you're mounted"
                .. " - its L3-control state; the real backport gets a"
                .. " stand-down flag)")
        end
        -- MIRRORED VAULT (07-24): one-time generation against the real
        -- player skeleton; the mount then picks handedness by approach
        -- side automatically (horse AND griffin)
        if imgui.button(vault_mirror_available()
            and "REGENERATE mirrored vault clip##mirrvault"
            or "GENERATE mirrored vault clip (one-time)##mirrvault") then
            S.mirror_vault_report = generate_mirrored_vault()
        end
        imgui.same_line()
        local vf_ch, vf_v = imgui.checkbox(
            "flip mirror side##vaultflip", C.vault_mirror_flip == true)
        if vf_ch then C.vault_mirror_flip = vf_v; save_config() end
        if S.mirror_vault_report then
            imgui.text("mirror: " .. tostring(S.mirror_vault_report))
        end
        imgui.text("MOUNT-CAPTURE: "
            .. tostring(S.mount_capture_diag or "(waiting)"))
        -- 08-18 ladder field diagnostic (Aurora: "pressing B isn't working")
        if S.costume and not S.costume.wyrm_kind then
            imgui.text(string.format(
                "LADDER: boost=%d display=%s cmd=%s:%s cur=%.1f m/s",
                tonumber(S.costume.gait_boost) or 0,
                tostring(S.costume.driven_gait),
                tostring(S.costume.cmd_bank),
                tostring(S.costume.cmd_clip),
                tonumber(S.costume.cur_speed) or 0.0))
        end
        local rp_ch, rp_v = imgui.checkbox(
            "SEAT LOCK (sit here — stand on/near the horse first)##rpose",
            S.ride_pose_on == true)
        if rp_ch then
            -- one code path with the climb auto-capture and the hotkey
            if rp_v then seat_mount() else seat_dismount() end
        end
        if S.ride_pose_on then
            -- SEAT FIT: per-variant (07-24 Aurora — the static and the
            -- animated pose sit differently). The group matching the pose
            -- CURRENTLY showing is the live one.
            local seat_now = S.costume and S.costume.seat
            local variant_now = (seat_now and seat_now.pose_variant)
                or "calm"
            local sf = {
                {"seat height", "seat_above_joint", -0.5, 2.5, 0.2},
                {"seat forward", "seat_fwd", -1.5, 1.5, 0.0},
                {"seat side", "seat_side", -1.0, 1.0, 0.0},
                {"seat yaw deg", "seat_yaw", -180.0, 180.0, 0.0},
                {"seat pitch deg", "seat_pitch", -180.0, 180.0, 0.0},
                {"seat roll deg", "seat_roll", -180.0, 180.0, 0.0},
                -- ranges griffin-scale (07-24 wing clipping): a horse
                -- neck is 30cm wide, a griffin head is over a metre out
                {"grip width", "hand_grip_width", -0.4, 1.2, 0.22},
                {"grip height", "hand_grip_up", -0.8, 0.8, 0.05},
                {"grip forward", "hand_grip_fwd", -0.6, 1.2, 0.10},
                -- 07-24: low-pass on the ANIMATION follow (griffin
                -- thrash); 0 = raw. Root travel is never smoothed.
                {"follow smoothing s", "seat_follow_smooth",
                    0.0, 0.5, 0.0},
                {"L thigh pitch deg", "leg_pitch_L", -60.0, 60.0, 0.0},
                {"L thigh splay deg", "leg_splay_L", -45.0, 45.0, 0.0},
                {"L knee bend deg", "leg_knee_L", -60.0, 60.0, 0.0},
                {"R thigh pitch deg", "leg_pitch_R", -60.0, 60.0, 0.0},
                {"R thigh splay deg", "leg_splay_R", -45.0, 45.0, 0.0},
                {"R knee bend deg", "leg_knee_R", -60.0, 60.0, 0.0},
            }
            -- GRIFFIN pose-only sliders (07-24 ROUND-12): the pin-mode
            -- sliders above (height/fwd/side/yaw/pitch/roll) are DEAD in
            -- pose-only (the native climb owns position/rotation). These
            -- are the ones that actually move her: a STATIC hip-bone
            -- offset (fade-safe, stable — NEVER follows the anim) + grips
            -- + legs. "seat back" < 0 sits her further toward the tail.
            local sf_griffin = {
                {"seat back (- = toward tail)", "seat_hz", -1.5, 1.5, 0.0},
                {"seat up", "seat_hy", -1.0, 1.5, 0.0},
                {"seat side", "seat_hx", -1.0, 1.0, 0.0},
                {"body yaw deg", "seat_hyaw", -180.0, 180.0, 0.0},
                {"body pitch deg", "seat_hpitch", -180.0, 180.0, 0.0},
                {"body roll deg (un-horizontal)", "seat_hroll",
                    -180.0, 180.0, 0.0},
                {"grip width", "hand_grip_width", -0.4, 1.2, 0.22},
                {"grip height", "hand_grip_up", -0.8, 0.8, 0.05},
                {"grip forward", "hand_grip_fwd", -0.6, 1.2, 0.10},
                {"L thigh pitch deg", "leg_pitch_L", -60.0, 60.0, 0.0},
                {"L thigh splay deg", "leg_splay_L", -45.0, 45.0, 0.0},
                {"L knee bend deg", "leg_knee_L", -60.0, 60.0, 0.0},
                {"R thigh pitch deg", "leg_pitch_R", -60.0, 60.0, 0.0},
                {"R thigh splay deg", "leg_splay_R", -45.0, 45.0, 0.0},
                {"R knee bend deg", "leg_knee_R", -60.0, 60.0, 0.0},
            }
            -- r47 CAPTURE (Aurora: "read my exact position on the horse
            -- when I get it set up correctly and force that exact same
            -- position every single time"): converts where her body IS
            -- right now into the three seat offsets for the CURRENT
            -- variant and saves them -- every future mount reproduces
            -- this exact seat. Ride to a moment that looks RIGHT, then
            -- press. (Inverse of the seat apply's yaw-frame math.)
            -- r52: capture must write the slider set calm actually
            -- READS -- with calm riding the loop clip, that's _active
            local capvar = variant_now
            if capvar == "calm" and C.calm_use_loop ~= false then
                capvar = "active"
            end
            if seat_now and not (S.costume and S.costume.passenger_only)
                and imgui.button("CAPTURE this seat as THE seat ("
                    .. capvar .. ")##seatcap") then
                local okc = pcall(function()
                    local htf = S.costume.horse_go
                        :call("get_Transform")
                    local root = htf:call("get_UniversalPosition")
                    local bx, by, bz = root.x, root.y, root.z
                    if seat_now.joint then
                        local jp = seat_now.joint:call("get_Position")
                        local hr = htf:call("get_Position")
                        bx = bx + (jp.x - hr.x)
                        by = by + (jp.y - hr.y)
                        bz = bz + (jp.z - hr.z)
                    end
                    local pp = seat_now.player_go
                        :call("get_Transform")
                        :call("get_UniversalPosition")
                    local wx = pp.x - bx
                    local wy = pp.y - by
                    local wz = pp.z - bz
                    local az = htf:call("get_AxisZ")
                    local fl2 = math.sqrt(az.x * az.x + az.z * az.z)
                    local fx2, fz2 = az.x / fl2, az.z / fl2
                    C["seat_fwd_" .. capvar] = wx * fx2 + wz * fz2
                    C["seat_side_" .. capvar] = wx * fz2 - wz * fx2
                    C["seat_above_joint_" .. capvar] = wy
                    save_config()
                    log(string.format(
                        "seat CAPTURED [%s]: fwd=%.3f side=%.3f up=%.3f",
                        capvar, C["seat_fwd_" .. capvar],
                        C["seat_side_" .. capvar],
                        C["seat_above_joint_" .. capvar]))
                end)
                S.status = okc
                    and ("seat CAPTURED for '" .. capvar
                        .. "' - every mount now reproduces it")
                    or "seat capture failed"
            end
            local variant_list = {"calm", "active"}
            if S.costume and S.costume.passenger_only then
                -- 3 tunable griffin poses; MANUALLY selected (no auto-
                -- switch). Each inherits the _griffin base until tuned.
                variant_list = {"gground", "gflight", "gsprint"}
            end
            local GTITLE = {
                gground = "SEAT FIT — GRIFFIN pose 1 (grounded)",
                gflight = "SEAT FIT — GRIFFIN pose 2 (flight)",
                gsprint = "SEAT FIT — GRIFFIN pose 3 (sprint)",
            }
            for _, variant in ipairs(variant_list) do
                local is_griffin = GRIFFIN_SUBVARIANTS[variant]
                local title = (variant == "calm")
                    and "SEAT FIT — static (stand/walk)"
                    or (variant == "active")
                    and "SEAT FIT — animated (trot/gallop)"
                    or GTITLE[variant] or "SEAT FIT — GRIFFIN"
                -- ⛔ NO "<< ACTIVE NOW" tag: a title that changes each frame
                -- makes imgui collapse/expand the tree node on its own
                -- (07-24 Aurora "opening and closing the panel"). STATIC
                -- titles = the panels stay exactly how you leave them.
                if imgui.tree_node(title .. "##sf_" .. variant) then
                    if is_griffin then
                        -- grip-joint dropdown (shared across the griffin
                        -- states — it's the target JOINT, not a pose)
                        local opts = S.grip_joint_options
                            or {"Neck_0", "Neck_1", "Neck_2", "Neck_3",
                                "Head_0", "Spine_3", "Spine_4"}
                        local cur_name = tostring(
                            C.hand_grip_joint_griffin or "Neck_0")
                        local cur_idx = 1
                        for i, nm in ipairs(opts) do
                            if nm == cur_name then cur_idx = i end
                        end
                        local gj_ch, gj_v = imgui.combo(
                            "hands grip joint (shared)##gripjoint",
                            cur_idx, opts)
                        if gj_ch and opts[gj_v] then
                            C.hand_grip_joint_griffin = opts[gj_v]
                            save_config()
                            S.hand_seed = nil
                        end
                    end
                    for _, row in ipairs(is_griffin and sf_griffin or sf) do
                        local label, key, lo, hi, dv =
                            row[1], row[2], row[3], row[4], row[5]
                        local ck = key .. "_" .. variant
                        local cur = C[ck]
                        if cur == nil then cur = SEAT_DEFAULTS[ck] end
                        -- griffin sub-variants inherit the _griffin base
                        if cur == nil and is_griffin then
                            cur = C[key .. "_griffin"]
                            if cur == nil then
                                cur = SEAT_DEFAULTS[key .. "_griffin"]
                            end
                        end
                        if cur == nil then cur = C[key] end
                        if cur == nil then cur = dv end
                        local sch, sv = imgui.slider_float(
                            label .. "##" .. ck, tonumber(cur) or dv,
                            lo, hi)
                        if sch then
                            C[ck] = sv
                            save_config()
                            if key:sub(1, 4) == "leg_" then
                                apply_leg_trims()
                            end
                        end
                    end
                    imgui.tree_pop()
                end
            end
            -- griffin mount options (07-24: NO auto-switch — the pose is
            -- whichever you pick here, manually)
            if S.costume and S.costume.passenger_only then
                -- ACTIVE POSE: which of the 3 tunable poses plays. Manual
                -- only — it never changes on its own. Set to the pose you
                -- want to tune/see, tune its group above, done.
                local sopts = {"gground", "gflight", "gsprint"}
                local slabel = {gground = "pose 1 (grounded)",
                    gflight = "pose 2 (flight)", gsprint = "pose 3 (sprint)"}
                local scur = tostring(C.griffin_pose_sel or "gground")
                local sidx = 1
                for i, o in ipairs(sopts) do if o == scur then sidx = i end end
                local disp = {}
                for i, o in ipairs(sopts) do disp[i] = slabel[o] end
                local sp_ch, sp_v = imgui.combo(
                    "ACTIVE pose (which one plays)##gposesel", sidx, disp)
                if sp_ch and sopts[sp_v] then
                    C.griffin_pose_sel = sopts[sp_v]
                    save_config()
                end
                local ao_ch, ao_v = imgui.checkbox(
                    "ARMS-ONLY (native cling body + Wilds arms to head)"
                    .. "##garmsonly", C.griffin_arms_only ~= false)
                if ao_ch then
                    C.griffin_arms_only = ao_v
                    save_config()
                    if S.costume then S.costume.arms_only = ao_v end
                    -- re-play the pose in the new set
                    if S.ride_pose_on and S.costume.seat then
                        S.costume.seat.pose_variant = nil
                    end
                end
                local pd_ch, pd_v = imgui.slider_float(
                    "riding-pose delay s (lets climb-on play)##gposedelay",
                    tonumber(C.griffin_pose_delay) or 1.8, 0.0, 4.0)
                if pd_ch then C.griffin_pose_delay = pd_v; save_config() end
                local ma_ch, ma_v = imgui.checkbox(
                    "our vault clip (OFF = native climb-on; vault reads "
                    .. "horizontal)##gmountanim",
                    C.griffin_mount_anim == true)
                if ma_ch then C.griffin_mount_anim = ma_v; save_config() end
            end
            -- POSE SPEED diagnostic (07-23 residual body shake): 0 freezes
            -- the Wilds clip on one frame — if the shake dies at 0, it's
            -- the CLIP's own captured wobble, not the seat pin
            local ps_ch, ps_v = imgui.slider_float(
                "ride pose speed (0 = freeze)##ridepspd",
                tonumber(C.ride_pose_speed) or 1.29, 0.0, 2.0)
            if ps_ch then
                C.ride_pose_speed = ps_v
                save_config()
                pcall(function()
                    local pose = rawget(_G, "NB_Pose")
                    if pose and pose.set_speed then
                        pose.set_speed(math.max(0.0, ps_v))
                    end
                end)
            end
            -- HAND MAGNET toggle (grip sliders live in the per-variant
            -- SEAT FIT groups above)
            local hm_ch, hm_v = imgui.checkbox(
                "Hands on neck (IK magnet)##handmag",
                C.hand_magnet ~= false)
            if hm_ch then C.hand_magnet = hm_v; save_config() end
            -- MOUNT CAMERA: our chase cam owns the view while seated (the
            -- anti-vibration fix — native cam vs the pinned player = shake)
            -- ⭐ r76: the ogre/cyclops targeting switch, in the panel rather than
            -- buried in JSON. app.HitController is what makes a body a valid
            -- damage TARGET, and suppressing it on the rider is why enemies
            -- swing at you without connecting and no boss healthbar appears.
            -- UNCHECK to become targetable while mounted.
            local mhp_ch, mhp_v = imgui.checkbox(
                "Show mount health bar while riding##mounthp",
                C.mount_hp_bar ~= false)
            if mhp_ch then C.mount_hp_bar = mhp_v; save_config() end
            local hc_ch, hc_v = imgui.checkbox(
                "Rider untargetable while mounted (uncheck to take hits)##ridehc",
                C.ride_suppress_player_hitcontroller ~= false)
            if hc_ch then
                C.ride_suppress_player_hitcontroller = hc_v
                save_config()
            end
            local mw_ch, mw_v = imgui.checkbox(
                "Keep rider weapon sheathed while mounted##mounted_weapon_lock",
                C.mounted_weapon_lock ~= false)
            if mw_ch then
                C.mounted_weapon_lock = mw_v
                save_config()
            end
            local mc_ch, mc_v = imgui.checkbox(
                "Mount camera (chase — cures the shake)##mountcam",
                C.mountcam_enabled ~= false)
            if mc_ch then C.mountcam_enabled = mc_v; save_config() end
            if C.mountcam_enabled ~= false then
                local cf = {
                    {"cam distance", "mountcam_dist", 2.0, 20.0, 6.5},
                    -- r55: range raised (Aurora rides at 10+ now)
                    {"cam height", "mountcam_height", 0.5, 16.0, 2.6},
                    -- r56: aim point ahead of the horse = see the road
                    {"cam look ahead", "mountcam_look_ahead",
                        0.0, 15.0, 6.0},
                    {"cam side", "mountcam_side", -6.0, 6.0, 0.0},
                    {"cam look-up", "mountcam_look_up", 0.0, 4.0, 1.4},
                    {"cam smoothing", "mountcam_smooth", 0.02, 1.0, 0.12},
                    -- Safety floor for unusual framing experiments. Zero lets
                    -- collision keep the lens fully out of walls/terrain;
                    -- raising it knowingly permits clipping again.
                    {"cam wall pull-in floor", "mountcam_pull_floor",
                        0.0, 1.0, 0.0},
                    -- r65 turning circle: rate at a standstill, how much of it
                    -- a full gallop loses, and how heavy the steering feels
                    {"turn rate (deg/s)", "turn_rate_deg", 20.0, 140.0, 70.0},
                    {"turn falloff at gallop", "turn_speed_falloff",
                        0.0, 0.8, 0.40},
                    {"turn weight (secs)", "turn_lag_secs", 0.05, 1.2, 0.35},
                    -- r65 ledge jump: how high a lip counts as climbable, and
                    -- how far past the lip the leap lands
                    {"jump ledge reach (m)", "jump_ledge_reach", 0.5, 4.0, 2.0},
                    {"jump ledge overshoot (m)", "jump_ledge_overshoot",
                        0.5, 8.0, 2.5},
                    -- r66 ballistic jump. Launch velocity sets BOTH the height
                    -- and the airtime (apex = v0^2/2g, air = 2*v0/g), so this
                    -- one slider is the whole feel of the leap. Distance then
                    -- follows from your speed -- there is no distance slider by
                    -- design, that was the arcade part.
                    {"jump launch (m/s up)", "jump_launch_v", 3.0, 12.0, 7.2},
                    {"jump gravity", "jump_gravity", 6.0, 26.0, 14.0},
                    {"jump push-off (x speed)", "jump_forward_boost",
                        1.0, 2.5, 1.25},
                    {"jump min forward (m/s)", "jump_min_hspeed",
                        0.0, 8.0, 3.0},
                    -- r71 three-phase timing: how long the take-off clip runs
                    -- before the airborne loop takes over, and how long the
                    -- landing clip (902/2 Jump_toIdle) holds the layer.
                    {"jump takeoff clip (s)", "jump_launch_secs",
                        0.1, 1.2, 0.45},
                    {"jump landing clip (s)", "jump_land_secs",
                        0.1, 1.2, 0.45},
                    -- r72: the gather -- how long the horse stays on the ground
                    -- pushing off before the arc lifts it. 0 = the old instant.
                    {"jump gather (s)", "jump_gather_secs", 0.0, 0.6, 0.18},
                    {"thud lead (s before contact)", "jump_land_lead",
                        0.0, 0.6, 0.22},
                }
                local cam_passenger = S.costume
                    and S.costume.passenger_only
                for _, row in ipairs(cf) do
                    local label, key, lo, hi, dv =
                        row[1], row[2], row[3], row[4], row[5]
                    -- griffin rides tune their OWN cam set (base keys =
                    -- the horse's; smoothing stays shared)
                    local ck = key
                    if cam_passenger and key ~= "mountcam_smooth" then
                        ck = key .. "_griffin"
                        if SEAT_DEFAULTS[ck] ~= nil then
                            dv = SEAT_DEFAULTS[ck]
                        end
                    end
                    local cch, cv = imgui.slider_float(
                        label .. "##" .. ck, C[ck] or dv, lo, hi)
                    if cch then C[ck] = cv; save_config() end
                end
                local ix_ch, ix_v = imgui.checkbox(
                    "invert camera X##caminvx", C.mountcam_invert_x == true)
                if ix_ch then C.mountcam_invert_x = ix_v; save_config() end
                imgui.same_line()
                local iy_ch, iy_v = imgui.checkbox(
                    "invert camera Y##caminvy", C.mountcam_invert_y == true)
                if iy_ch then C.mountcam_invert_y = iy_v; save_config() end
            end
            local rk_ch, rk_v = imgui.checkbox(
                "EXPERIMENT: kill shell root motion (A/B for horse "
                .. "vibration)##rmkill", C.rootmotion_kill == true)
            if rk_ch then
                C.rootmotion_kill = rk_v
                save_config()
                S.need_rootmotion_kill = true -- re-run with new setting
            end
            if S.rootmotion_diag then
                imgui.text("root-motion kill: " .. tostring(S.rootmotion_diag))
            end
        end
        -- defaults = Lyra's real gaits (bank 901: walk 1 / trot 2 /
        -- gallop 3, baked in 07-23); sliders remain as lab overrides
        local function gait_row(label, key_bank, key_id, def_bank, def_id)
            local cb, vb = imgui.slider_int(
                label .. " bank##" .. key_bank,
                math.floor(S[key_bank] or def_bank), 0, 950)
            if cb then S[key_bank] = vb end
            local ci, vi = imgui.slider_int(
                label .. " clip##" .. key_id,
                math.floor(S[key_id] or def_id), 0, 400)
            if ci then S[key_id] = vi end
        end
        gait_row("walk", "gait_walk_bank", "gait_walk_id", 901, 1)
        gait_row("trot", "gait_run_bank", "gait_run_id", 901, 2)
        gait_row(S.costume.wyrm_kind and "sprint" or "gallop",
            "gait_dash_bank", "gait_dash_id", 901, 3)
        -- SAVED to config (07-23: Aurora tuned these and they were
        -- session-only — walk 1.25 / gallop 13 must survive reloads)
        local s1, sv1 = imgui.slider_float(
            "walk speed m/s##spd_w", C.speed_walk or 1.6, 0.5, 4.0)
        if s1 then C.speed_walk = sv1; save_config() end
        local s2, sv2 = imgui.slider_float(
            "trot speed m/s##spd_r", C.speed_run or 3.4, 1.0, 8.0)
        if s2 then C.speed_run = sv2; save_config() end
        if not S.costume.wyrm_kind then
            -- 08-18 four-tier ladder (horse only)
            local s25, sv25 = imgui.slider_float(
                "canter speed m/s##spd_c",
                tonumber(C.speed_canter) or 6.0, 3.0, 9.0)
            if s25 then C.speed_canter = sv25; save_config() end
        end
        local s3, sv3 = imgui.slider_float(
            (S.costume.wyrm_kind and "sprint speed m/s##spd_d"
                or "gallop speed m/s##spd_d"),
            C.speed_dash or 9.5, 3.0, 20.0)
        if s3 then C.speed_dash = sv3; save_config() end
        if not S.costume.wyrm_kind then
            local gl1, gl1v = imgui.checkbox(
                "Gait ladder (TAP B = +1 gait, HOLD B = gallop)",
                C.gait_ladder_enabled ~= false)
            if gl1 then C.gait_ladder_enabled = gl1v; save_config() end
            imgui.text("  hold-B still slams gallop exactly like before; taps add the")
            imgui.text("  in-between gaits. Stick release resets. Off = pure classic.")
            local rv1, rv1v = imgui.slider_float(
                "reverse speed m/s##spd_rev",
                tonumber(C.speed_reverse) or 0.9, 0.3, 2.0)
            if rv1 then C.speed_reverse = rv1v; save_config() end
            local th1, th1v = imgui.slider_float(
                "transition hold s##gait_trans_hold",
                tonumber(C.gait_trans_hold) or 0.9, 0.3, 2.0)
            if th1 then C.gait_trans_hold = th1v; save_config() end
            local wj1, wj1v = imgui.checkbox(
                "W3 per-gait jumps", C.w3_jumps_enabled ~= false)
            if wj1 then C.w3_jumps_enabled = wj1v; save_config() end
        end
    end
    -- This used to be the `else` arm of `if S.costume`, so the sliders
    -- disappeared at exactly the moment a wolf/cat was armed or mounted.  Keep
    -- the panel available both before arming and throughout a wyrm ride.
    if (not S.costume) or S.costume.wyrm_kind then
        if imgui.button("WYRM MOUNT: ready the wyrm-grown companion (wolf / great cat)") then
            iris_wyrm_mount_start()
        end
        imgui.same_line()
        if imgui.button("release##wyrm_rel") then iris_wyrm_mount_stop() end
        imgui.text("  X/T Bite combo   Y/G Pounce   LT/H Howl or Roar")
        imgui.text("  LB/Z Dodge left   RB/C Dodge right   RT/R Maul downed target")
        imgui.text("  Dismount: L3 (controller) or E (keyboard)")
        if S.wyrm_native_status then
            imgui.text("  " .. tostring(S.wyrm_native_status))
        end
        if S.wyrm_native_hit_capture_status then
            imgui.text("  " .. tostring(S.wyrm_native_hit_capture_status))
        end
        if S.wyrm_native_request_status then
            imgui.text("  " .. tostring(S.wyrm_native_request_status))
        end
        local trace_changed, trace_value = imgui.checkbox(
            "combat transaction trace##wyrm_combat_trace",
            C.wyrm_combat_trace ~= false)
        if trace_changed then
            C.wyrm_combat_trace = trace_value
            save_config()
        end
        if C.wyrm_combat_trace ~= false then
            imgui.text("  Last 12 attacks: reframework/data/IrisWyrmCombatTrace.json")
        end
        pcall(function()
            local bridge = rawget(_G, "IrisGriffinBridge")
            local spawn_status, park_status, live_action = nil, nil, nil
            if bridge and bridge.native_ch223_status then
                spawn_status, park_status, live_action = bridge.native_ch223_status()
            end
            if spawn_status then
                imgui.text("  stable route: " .. tostring(spawn_status))
            end
            if park_status then
                imgui.text("  passive park: " .. tostring(park_status))
            end
            if live_action then
                imgui.text("  live action: " .. tostring(live_action))
            end
        end)
        imgui.text("  catch template: " .. tostring(
            S.wyrm_catch_capture_status or "waiting for a natural ch223 catch"))
        -- ⭐ 08-13 (Aurora: "I don't know where these sliders are"): ALWAYS visible,
        -- own section, and rider position split per species - wolf's tune is the
        -- cat's starting point but they never move together again.
        if imgui.tree_node("WOLF / CAT SLIDERS (wyrm mount)") then
            imgui.text("  IRIS controller active (native takeover retired: unsafe self-driving).")
            local wdc, wdv = imgui.checkbox("drift cancel (kill the sideways slide)##wyrm_dc",
                C.wyrm_drift_cancel ~= false)
            if wdc then C.wyrm_drift_cancel = wdv; save_config() end
            local wdmgc, wdmgv = imgui.slider_float(
                "native attack damage multiplier##wyrm_native_damage_scale",
                tonumber(C.wyrm_native_damage_scale) or 8.0, 1.0, 60.0)
            if wdmgc then
                C.wyrm_native_damage_scale = wdmgv
                save_config()
            end
            imgui.text("  Post-hit amp: a landed native hit's damage x this dial x ATK IV.")
            imgui.text("  A miss stays a miss -- the bonus only rides real contact.")
            if S.wyrm_dmg_amp_last then
                imgui.text("  last amped hit: " .. tostring(S.wyrm_dmg_amp_last))
            end
            if (tonumber(S.wyrm_selfhit_blocked) or 0) > 0 then
                imgui.text("  self-hits blocked (howl dome): "
                    .. tostring(S.wyrm_selfhit_blocked))
            end
            if (tonumber(S.wyrm_dmg_hook_wyrm_hits) or 0) > 0 then
                imgui.text("  updateDamageHp saw wyrm attacks: "
                    .. tostring(S.wyrm_dmg_hook_wyrm_hits) .. " (diagnostic)")
            end
            if S.wyrm_incoming_fx_status then
                imgui.text("  incoming-hit FX: "
                    .. tostring(S.wyrm_incoming_fx_status))
            end
            if S.wyrm_maul_fx_status then
                imgui.text("  maul chomp FX: "
                    .. tostring(S.wyrm_maul_fx_status))
            end
            if S.wyrm_maul_voice_status then
                imgui.text("  maul pain cry: "
                    .. tostring(S.wyrm_maul_voice_status))
            end
            if S.wyrm_last_press then
                imgui.text("  last combat press: "
                    .. tostring(S.wyrm_last_press))
            end
            if (tonumber(S.mounted_weapon_forced) or 0) > 0 then
                imgui.text(string.format(
                    "  rider sheathe forced: %d (last %.0fs ago)",
                    tonumber(S.mounted_weapon_forced) or 0,
                    os.clock() - (tonumber(S.mounted_weapon_forced_at) or 0)))
            end
            local wnm, wnmv = imgui.checkbox(
                "RT maul = PINNED maul##wyrm_native_maul",
                C.wyrm_native_maul ~= false)
            if wnm then C.wyrm_native_maul = wnmv; save_config() end
            imgui.text("  Prey held in its native down pose; authored maul choreography;")
            imgui.text("  damage + blood per chomp. Uncheck for the old scripted maul.")
            local wmcd, wmcdv = imgui.slider_float(
                "maul chomp damage (x dial x IV)##wyrm_maul_chomp_damage",
                tonumber(C.wyrm_maul_chomp_damage) or 45.0, 5.0, 200.0)
            if wmcd then C.wyrm_maul_chomp_damage = wmcdv; save_config() end
            local wreac, wreav = imgui.slider_float(
                "enemy reaction weight##wyrm_reaction_scale",
                tonumber(C.wyrm_reaction_scale) or 2.0, 1.0, 10.0)
            if wreac then
                C.wyrm_reaction_scale = wreav
                save_config()
            end
            imgui.text("  How hard victims visibly react (stagger/knockdown tiers);")
            imgui.text("  independent of the HP multiplier above.")
            local wdd1, wdd1v = imgui.slider_float(
                "dodge launch delay (s)##wyrm_dodge_delay",
                tonumber(C.wyrm_dodge_delay) or 0.16, 0.0, 0.5)
            if wdd1 then C.wyrm_dodge_delay = wdd1v; save_config() end
            local wdd2, wdd2v = imgui.slider_float(
                "dodge speed (m/s)##wyrm_dodge_speed",
                tonumber(C.wyrm_dodge_speed) or 4.8, 1.0, 12.0)
            if wdd2 then C.wyrm_dodge_speed = wdd2v; save_config() end
            local wdd3, wdd3v = imgui.slider_float(
                "dodge travel time (s)##wyrm_dodge_secs",
                tonumber(C.wyrm_dodge_secs) or 0.42, 0.1, 0.9)
            if wdd3 then C.wyrm_dodge_secs = wdd3v; save_config() end
            imgui.text("  Delay holds the slide until the hop frame of 462/463.")
            local wcolc, wcolv = imgui.slider_float(
                "native jaw collider reach##wyrm_native_collider_scale",
                tonumber(C.wyrm_native_collider_scale) or 1.85, 1.0, 2.5)
            if wcolc then
                C.wyrm_native_collider_scale = wcolv
                save_config()
            end
            imgui.text("  Enlarges native contact only; it never manufactures damage.")
            imgui.text("MOVEMENT + LEAP (shared - same chassis, same legs):")
            imgui.text("  Run uses native 0:200; Sprint uses native 0:300.")
            local wdefs = {
                { "wyrm_speed_walk", "walk speed (m/s)", 0.8, 4.0 },
                { "wyrm_speed_run", "run speed (m/s)", 2.0, 9.0 },
                { "wyrm_speed_dash", "sprint speed (m/s)", 5.0, 16.0 },
                { "wyrm_accel", "acceleration (m/s squared)", 5.0, 40.0 },
                { "wyrm_brake", "braking (m/s squared)", 4.0, 20.0 },
                { "wyrm_turn_rate", "turn rate (deg/s)", 40.0, 220.0 },
                { "wyrm_jump_height", "leap height (m)", 1.0, 4.0 },
                { "wyrm_jump_travel", "leap distance (1.0 = horse tune)", 0.3, 1.5 },
                { "wyrm_jump_gravity", "jump gravity (higher = quicker arc)", 12.0, 50.0 },
                { "wyrm_jump_gather_secs", "jump gather time (s)", 0.00, 0.25 },
                { "wyrm_jump_start_secs", "take-off animation time (s)", 0.05, 0.35 },
                { "wyrm_pace_walk", "walk cadence (paws vs ground)", 0.5, 2.0 },
                { "wyrm_pace_run", "run cadence", 0.5, 2.0 },
                { "wyrm_pace_dash", "sprint cadence", 0.5, 2.0 },
            }
            for _, wd in ipairs(wdefs) do
                local wdef0 = 0.0
                if wd[1] == "wyrm_pace_dash" then wdef0 = 1.12
                elseif wd[1]:find("pace") then wdef0 = 1.0
                elseif wd[1] == "wyrm_jump_height" then wdef0 = 2.2
                elseif wd[1] == "wyrm_jump_travel" then wdef0 = 0.7
                elseif wd[1] == "wyrm_jump_gravity" then wdef0 = 38.0
                elseif wd[1] == "wyrm_jump_gather_secs" then wdef0 = 0.04
                elseif wd[1] == "wyrm_jump_start_secs" then wdef0 = 0.10
                elseif wd[1] == "wyrm_speed_walk" then wdef0 = 2.2
                elseif wd[1] == "wyrm_speed_run" then wdef0 = 6.0
                elseif wd[1] == "wyrm_speed_dash" then wdef0 = 11.0
                elseif wd[1] == "wyrm_accel" then wdef0 = 26.0
                elseif wd[1] == "wyrm_brake" then wdef0 = 10.0
                elseif wd[1] == "wyrm_turn_rate" then wdef0 = 110.0 end
                local wcur = tonumber(C[wd[1]]) or wdef0
                local wch, wv2 = imgui.slider_float(wd[2] .. "##" .. wd[1], wcur, wd[3], wd[4])
                if wch then C[wd[1]] = wv2; save_config() end
            end
            local sdefs = {
                { "seat_above_joint", "seat height", -1.5, 1.0 },
                { "seat_fwd", "seat forward/back", -1.5, 1.5 },
                { "seat_side", "seat side", -0.8, 0.8 },
                { "seat_yaw", "rider yaw", -90.0, 90.0 },
                { "seat_pitch", "rider lean/pitch", -60.0, 60.0 },
                { "seat_roll", "rider roll", -45.0, 45.0 },
                { "hand_grip_up", "hands height (DOWN = drag left)", -0.6, 0.6 },
                { "hand_grip_fwd", "hands forward", -0.6, 0.9 },
                { "hand_grip_width", "hands width", 0.0, 0.8 },
            }
            for _, wkind in ipairs({ "wolf", "cat" }) do
                imgui.separator()
                imgui.text(wkind == "wolf" and "WOLF rider position:"
                    or "CAT (puma/panther) rider position:")
                for _, sd in ipairs(sdefs) do
                    local k9 = sd[1] .. "_wyrm_" .. wkind
                    local cur9 = tonumber(C[k9])
                    if cur9 == nil then
                        cur9 = tonumber(SEAT_DEFAULTS[k9])
                    end
                    if cur9 == nil then cur9 = tonumber(C[sd[1] .. "_wyrm"]) end
                    if cur9 == nil then
                        cur9 = tonumber(SEAT_DEFAULTS[sd[1] .. "_wyrm"]) or 0.0
                    end
                    local ch9, v9 = imgui.slider_float(sd[2] .. "##" .. k9,
                        cur9, sd[3], sd[4])
                    if ch9 then C[k9] = v9; save_config() end
                end
            end
            imgui.tree_pop()
        end
    end
    if not S.costume then
        if imgui.button("OXLESS MOUNT: ready the nearest horse (no ghost)") then
            local player_pos = universal_pos(player_game_object())
            local best, best_d = nil, 50.0
            for _, record in ipairs(horses()) do
                if valid(record.game_object) and player_pos then
                    local dd = distance(player_pos,
                        universal_pos(record.game_object))
                    if dd < best_d then best, best_d = record, dd end
                end
            end
            if best then
                costume_start_oxless(best)
            else
                S.status = "oxless: no live horse nearby"
            end
        end
        if imgui.button("LEGACY costume rig (ox ghost)##oldrig") then
            costume_start()
        end
        -- 07-24: griffin experiment REVERTED (Aurora) — button removed so
        -- the griffin path can't be armed. The costume_start_griffin_
        -- experiment / pose_only functions remain as dead code pending a
        -- full cleanup pass.
        if imgui.button("SUMMON MOUNT (spawn horse + ox + auto-costume)") then
            local api = rawget(_G, "__iris_wild_horses_api")
            if api and api.force_next_horse then api.force_next_horse() end
            local ok1, err1 = summon_spawn("doe", 4.0)
            local ok2, err2 = summon_spawn("ox", 6.0)
            if not ok1 or not ok2 then
                S.status = "summon: " .. tostring(err1 or err2)
            else
                S.summon_watch = os.clock()
                S.status = "summon: conjuring the pair..."
            end
        end
        for _, sp in ipairs({"doe", "ox"}) do
            if SUMMON.trace[sp] then
                imgui.text("  " .. sp .. ": " .. SUMMON.trace[sp])
            end
        end
    end
    if S.tame and S.tame.stage == "name" then
        imgui.text(">> NAME YOUR HORSE <<")
        local nch, nv = imgui.input_text("name##tamename",
            S.tame_name_buf or "")
        if nch then S.tame_name_buf = nv end
        if imgui.button("SEAL THE BOND##tameok")
            and (S.tame_name_buf or "") ~= "" then
            local record = S.tame.record
            record.tamed = true
            record.name = S.tame_name_buf
            S.tamed_count = (S.tamed_count or 0) + 1
            -- fallback stable seal (the christening card normally owns
            -- this; only runs if IrisTaming's card was unavailable)
            pcall(function()
                local bridge = rawget(_G, "IrisGriffinBridge")
                local ch = get_component(record.game_object,
                    "app.Character")
                if bridge and ch then
                    if bridge.tame_creature and not S.tame.sealed then
                        -- same sub-variant carry as the seal path above
                        local hv = rawget(_G, "__iris_wild_horses_api")
                        local variant = (hv and hv.is_unicorn
                            and hv.is_unicorn(record.game_object)) and "unicorn" or nil
                        bridge.tame_creature(ch, S.tame.gender, "horse", variant)
                    end
                    if bridge.rename_active then
                        bridge.rename_active(tostring(record.name))
                    end
                end
            end)
            ready_tamed_mount(record)
            S.tame = nil
            S.tame_name_buf = nil
            S.status = "TAMED: " .. tostring(record.name)
                .. " - press E/RT beside it to mount"
        end
    elseif S.tame then
        imgui.text("TAME: stage " .. tostring(S.tame.stage))
        imgui.same_line()
        if imgui.button("abandon##tameab") then
            tame_abort("abandoned")
        end
    end
    imgui.text(string.format(
        "Tamed: %d | Thrown: %d", S.tamed_count, S.thrown_count))
    imgui.text("Status: " .. tostring(S.status))

    if imgui.tree_node("Advanced##iris_rodeo") then
        -- session-only on purpose: the benched synthetic rodeo can never
        -- come back from a saved config
        local lg_ch, lg_v = imgui.checkbox(
            "LEGACY: synthetic E-grab rodeo (benched — leave OFF)##lgrodeo",
            S.legacy_rodeo_grab == true)
        if lg_ch then S.legacy_rodeo_grab = lg_v == true end
        changed, value = imgui.slider_float(
            "rodeo length (s)", C.rodeo_secs, 6.0, 40.0)
        if changed then C.rodeo_secs = value; save_config() end
        changed, value = imgui.slider_float(
            "grip drain per buck-second", C.grip_drain_per_buck_s, 5.0, 60.0)
        if changed then C.grip_drain_per_buck_s = value; save_config() end
        changed, value = imgui.slider_float(
            "seat above back joint", C.seat_above_joint, -1.5, 1.0)
        if changed then C.seat_above_joint = value; save_config() end
        changed, value = imgui.slider_float(
            "seat forward", C.seat_fwd, -1.0, 1.0)
        if changed then C.seat_fwd = value; save_config() end
        local id_changed, id_value = imgui.slider_int(
            "buck motion id (bank 0)", math.floor(C.buck_motion_id), 0, 600)
        if id_changed then C.buck_motion_id = id_value; save_config() end
        imgui.text("known: 212 run_end skid | 401 landing slam | 100 walk")
        if imgui.button("Dump doe bank-0 motion list") then
            local record = horses()[1]
            local rows = {}
            if record then
                pcall(function()
                    local character = get_component(
                        record.game_object, "app.Character")
                    local motion = character and character:call("get_Motion")
                    local count = motion
                        and tonumber(motion:call("getMotionCount", 0)) or 0
                    for index = 0, count - 1 do
                        local info = sdk.create_instance(
                            "via.motion.MotionInfo", true)
                        if info then
                            local got = motion:call(
                                "getMotionInfoByIndex(System.UInt32, System.UInt32, via.motion.MotionInfo)",
                                0, index, info)
                            if got ~= false then
                                rows[#rows + 1] = {
                                    id = tonumber(info:call("get_MotionID")),
                                    name = tostring(info:call("get_MotionName")),
                                }
                            end
                        end
                    end
                end)
            end
            pcall(function()
                json.dump_file("IrisRodeo_doe_motions.json", rows)
            end)
            S.status = "dumped " .. tostring(#rows)
                .. " motions -> data/IrisRodeo_doe_motions.json"
        end
        -- Climb-rig graft experiment RETIRED 2026-07-21: attaching the
        -- griffin's climb components (SkinningMeshColliderSet family /
        -- ClimbedRegionChecker / WrestleCtrl) via createComponent CTD'd
        -- the game. Do not re-attempt; the hold is transform-drive now.
        imgui.text("(climb-graft experiment retired: CTD; hold = transform-drive)")
        imgui.text("Graft v2 resources: " .. tostring(GR.status))
        if imgui.button("GRAFT v2: build climb rig on nearest horse (SAVE FIRST)") then
            local record = horses()[1]
            if not record then
                S.status = "graft v2: no live horse"
            else
                local ok, report = graft_v2(record.game_object)
                S.status = "graft v2: " .. tostring(report)
            end
        end
        if imgui.button("Check graft status (post-frame readback)") then
            if not (GR.set_component and valid(GR.set_component)) then
                S.status = "graft check: no live Set component"
            else
                local report = {}
                pcall(function()
                    GR.set_component:call("set_Enabled", true)
                    GR.set_component:call("set_Update", true)
                end)
                pcall(function()
                    report[#report + 1] = "count="
                        .. tostring(GR.set_component:call(
                            "getSkinningMeshInfosCount"))
                    report[#report + 1] = "enabled="
                        .. tostring(GR.set_component:call("get_Enabled"))
                    report[#report + 1] = "current="
                        .. tostring(GR.set_component:call("get_CurrentEnabled"))
                    report[#report + 1] = "update="
                        .. tostring(GR.set_component:call("get_Update"))
                end)
                pcall(function()
                    local aabb = GR.set_component:call("get_BoundingAabb")
                    local mn = aabb and aabb:call("getMin")
                    local mx = aabb and aabb:call("getMax")
                    if mn and mx then
                        report[#report + 1] = string.format(
                            "aabb=(%.1f,%.1f,%.1f)-(%.1f,%.1f,%.1f)",
                            mn.x, mn.y, mn.z, mx.x, mx.y, mx.z)
                    else
                        report[#report + 1] = "aabb=nil"
                    end
                end)
                S.status = "graft check: " .. table.concat(report, " | ")
                log(S.status)
            end
        end
        -- Graft-v2 prep: pure REFLECTION dump of the climb component types
        -- (fields + zero-arg setters). No instantiation — safe anywhere.
        if imgui.button("Dump climb component TYPE DEFS (safe)") then
            local out = {}
            for _, type_name in ipairs({
                "app.ClimbedRegionChecker",
                "app.SkinningMeshColliderHolder",
                "via.physics.SkinningMeshColliderSet",
                "via.physics.SkinningMeshColliderSet.SkinningMeshInfo",
                "app.AIClimbPointHolder",
            }) do
                local row = {fields = {}, methods = {}}
                pcall(function()
                    local td = sdk.find_type_definition(type_name)
                    local current = td
                    while current do
                        for _, f in ipairs(current:get_fields() or {}) do
                            pcall(function()
                                row.fields[#row.fields + 1] = {
                                    name = f:get_name(),
                                    type = f:get_type():get_full_name(),
                                    static = f:is_static(),
                                }
                            end)
                        end
                        for _, m in ipairs(current:get_methods() or {}) do
                            local n = tostring(m:get_name())
                            if n:find("^set_") or n:find("^get_")
                                or n:lower():find("mesh")
                                or n:lower():find("collider")
                                or n:lower():find("resource") then
                                local params = {}
                                pcall(function()
                                    for _, p in ipairs(m:get_param_types()) do
                                        params[#params + 1] = p:get_full_name()
                                    end
                                end)
                                row.methods[#row.methods + 1] =
                                    n .. "(" .. table.concat(params, ",") .. ")"
                            end
                        end
                        current = current:get_parent_type()
                        if current and current:get_full_name() == "via.Component" then
                            break
                        end
                    end
                end)
                out[type_name] = row
            end
            pcall(function()
                json.dump_file("IrisRodeo_climb_typedefs.json", out)
            end)
            S.status = "typedefs dumped -> data/IrisRodeo_climb_typedefs.json"
        end
        if imgui.button("Dump climb rig (horse vs nearby monsters)") then
            local rows = {}
            local player_pos = universal_pos(player_game_object())
            local function describe(game_object, label)
                local row = {label = label, components = {}}
                pcall(function()
                    row.name = tostring(game_object:call("get_Name"))
                end)
                pcall(function()
                    local list = game_object:call("get_Components")
                    local count = 0
                    pcall(function() count = list:call("get_Count") end)
                    if count == 0 then
                        pcall(function() count = #list end)
                    end
                    for index = 0, count - 1 do
                        local component = nil
                        pcall(function() component = list[index] end)
                        if component then
                            local type_name = "?"
                            local enabled = nil
                            pcall(function()
                                type_name = component
                                    :get_type_definition():get_full_name()
                            end)
                            pcall(function()
                                enabled = component:call("get_Enabled")
                            end)
                            row.components[#row.components + 1] = {
                                type = type_name, enabled = enabled,
                            }
                        end
                    end
                end)
                rows[#rows + 1] = row
            end
            for _, record in ipairs(horses()) do
                describe(record.game_object, "HORSE")
                break
            end
            pcall(function()
                local scene_manager = sdk.get_native_singleton("via.SceneManager")
                local scene_type = sdk.find_type_definition("via.SceneManager")
                local scene = sdk.call_native_func(
                    scene_manager, scene_type, "get_CurrentScene()")
                local characters = scene and scene:call(
                    "findComponents(System.Type)", sdk.typeof("app.Character"))
                local elements = {}
                pcall(function() elements = characters:get_elements() end)
                for _, character in ipairs(elements) do
                    local id = ""
                    pcall(function()
                        id = tostring(character:call("get_CharaIDString"))
                    end)
                    -- Large-monster families only (ch25x/ch26x/ch27x).
                    if id:match("^ch2[5-7]") then
                        local game_object = nil
                        pcall(function()
                            game_object = character:call("get_GameObject")
                        end)
                        if valid(game_object)
                            and distance(player_pos,
                                universal_pos(game_object)) < 100 then
                            describe(game_object, "MONSTER " .. id)
                        end
                    end
                end
            end)
            pcall(function()
                json.dump_file("IrisRodeo_climb_rig_dump.json", rows)
            end)
            S.status = "dumped " .. tostring(#rows)
                .. " rigs -> data/IrisRodeo_climb_rig_dump.json"
        end
        imgui.tree_pop()
    end
end)

load_config()
log("loaded; approach a wild horse slowly and grab hold")
