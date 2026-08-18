-- I.R.I.S. griffin -- orders, following and the whistle.
--
-- Follow / Stay / Come / Attack / Eat, the ground pathing that carries them out, and the whistle
-- that calls her to you. This is the layer that decides where she should BE when you are not
-- riding her; how she gets there on the ground is the follow motor below.

local ctx = require("IrisGriffin.context")
local C, S = ctx.C, ctx.S
local MOD                              = ctx.MOD
local char_go                          = ctx.char_go
local clear_griffin_hate               = ctx.clear_griffin_hate
local clear_griffin_targets            = ctx.clear_griffin_targets
local distance_sq                      = ctx.distance_sq
local get_component                    = ctx.get_component
local get_player                       = ctx.get_player
local go_name                          = ctx.go_name
local griffin_action_manager           = ctx.griffin_action_manager
local iris_real_character              = ctx.iris_real_character
local make_position                    = ctx.make_position
local make_quat_yaw                    = ctx.make_quat_yaw
local pacify_griffin                   = ctx.pacify_griffin
local play_griffin_motion              = ctx.play_griffin_motion
local reacquire_griffin                = ctx.reacquire_griffin
local read_griffin_fsm_node            = ctx.read_griffin_fsm_node
local register_griffin                 = ctx.register_griffin
local restore_disabled                 = ctx.restore_disabled
local set_character_transform          = ctx.set_character_transform
local set_griffin_motion_speed         = ctx.set_griffin_motion_speed
local set_griffin_puppet               = ctx.set_griffin_puppet
local set_motion_fsm_puppet            = ctx.set_motion_fsm_puppet
local set_think_stop                   = ctx.set_think_stop
local set_transform                    = ctx.set_transform
local status                           = ctx.status
local stop_griffin_animation           = ctx.stop_griffin_animation
local stop_navigation                  = ctx.stop_navigation
local system_array_to_table            = ctx.system_array_to_table
local transform_pos                    = ctx.transform_pos
local transform_rot                    = ctx.transform_rot
local wrap_angle                       = ctx.wrap_angle
local yaw_from_transform               = ctx.yaw_from_transform

function route3_whistle_flyin_start()
    local gch = S.griffin
    local go = gch and char_go(gch)
    local pgo = char_go(get_player())
    local ppos = pgo and transform_pos(pgo)
    if not (gch and go and ppos) then return false end
    local target, _, target_detail = route3_find_safe_stable_spawn(C.route3_stable_spawn_distance)
    if not target then
        S.route3_stable_spawn_status = tostring(target_detail or "no safe landing floor")
        return false
    end
    -- Appear nearby but overhead, then descend to the already-proven patch.
    -- The old 45m/22m start could materialise inside a mountain behind the player.
    local yaw = yaw_from_transform(pgo) or 0.0
    local start_x = (tonumber(target.x) or 0.0) - math.sin(yaw) * 12.0
    local start_z = (tonumber(target.z) or 0.0) - math.cos(yaw) * 12.0
    local prp = transform_render_pos(pgo)
    local start_ground = nil
    if prp then
        start_ground = route3_cast_ground_below(
            (tonumber(prp.x) or 0.0) + start_x - (tonumber(ppos.x) or 0.0),
            (tonumber(ppos.y) or 0.0) + 30.0,
            (tonumber(prp.z) or 0.0) + start_z - (tonumber(ppos.z) or 0.0),
            8.0, 100.0)
    end
    local start = make_position(
        start_x,
        math.max(tonumber(target.y) or 0.0, tonumber(start_ground and start_ground.y) or -1.0e9) + 12.0,
        start_z
    )
    pcall(function() set_transform(go, start, nil) end)
    pcall(function() set_character_transform(gch, start, nil) end)
    stop_navigation(gch, true)
    pacify_griffin(nil)
    set_griffin_motion_speed(1.0)
    play_griffin_motion(math.floor(tonumber(C.flap_takeoff_clip) or 5210), 0, true)
    route3_flap_seek(tonumber(C.flap_seg_start) or 138.0)
    S.route3_whistle_flyin = { t0 = os.clock(), target = target }
    status(tostring(C.route3_griffin_name or "Griffin") .. " is flying to you")
    return true
end
function route3_whistle_flyin_tick()
    local fi = S.route3_whistle_flyin
    if not fi then return false end
    if S.world_paused == true then return false end
    local gch = S.griffin
    local go = gch and char_go(gch)
    local pgo = char_go(get_player())
    if not (gch and go and pgo) then S.route3_whistle_flyin = nil; return false end
    if os.clock() - (tonumber(fi.t0) or 0.0) > 25.0 then S.route3_whistle_flyin = nil; return false end
    local gpos = transform_pos(go)
    local ppos = transform_pos(pgo)
    if not (gpos and ppos) then S.route3_whistle_flyin = nil; return false end

    -- The target was footprint-tested before take-off. Keep it fixed: chasing a
    -- moving player can steer the final descent onto a cliff after validation.
    local pyaw = yaw_from_transform(pgo) or 0.0
    local target = fi.target
    if not target then S.route3_whistle_flyin = nil; return false end
    local tx = tonumber(target.x) or 0.0
    local tz = tonumber(target.z) or 0.0
    local ty = tonumber(target.y) or 0.0

    local dx = tx - (tonumber(gpos.x) or 0.0)
    local dy = ty - (tonumber(gpos.y) or 0.0)
    local dz = tz - (tonumber(gpos.z) or 0.0)
    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    if dist < 1.2 then
        -- touchdown, facing the player
        local landed = make_position(tx, ty, tz)
        local face = make_quat_yaw(wrap_angle(pyaw + math.pi))
        pcall(function() set_transform(go, landed, face) end)
        pcall(function() set_character_transform(gch, landed, face) end)
        play_griffin_motion(tonumber(C.landing_end_motion) or 5032, 0, true)
        S.audition_until_clock = os.clock() + 1.2
        S.route3_whistle_flyin = nil
        status(tostring(C.route3_griffin_name or "Griffin") .. " lands beside you")
        return true
    end

    -- fly the approach: ease toward the target, face travel direction
    local step = math.min(dist, 0.5)
    local pos = make_position(
        (tonumber(gpos.x) or 0.0) + dx / dist * step,
        (tonumber(gpos.y) or 0.0) + dy / dist * step * 0.75,
        (tonumber(gpos.z) or 0.0) + dz / dist * step
    )
    local rot = make_quat_yaw(math.atan(dx, dz))
    pcall(function() set_transform(go, pos, rot) end)
    pcall(function() set_character_transform(gch, pos, rot) end)

    -- keep the wings beating (same segment loop as ridden flight)
    local clip = math.floor(tonumber(C.flap_takeoff_clip) or 5210)
    if route3_flap_layer_clip() ~= clip then
        play_griffin_motion(clip, 0, true)
    end
    local s0 = tonumber(C.flap_seg_start) or 138.0
    local s1 = tonumber(C.flap_seg_end) or 195.0
    local layer_end = tonumber(route3_flap_layer_end()) or 0.0
    if layer_end > 1.0 and s1 > layer_end - 0.5 then s1 = layer_end - 0.5 end
    local frame = route3_flap_layer_frame()
    if frame and (frame >= s1 or frame < s0 - 12.0) then route3_flap_seek(s0) end
    return true
end
function griffin_recall()
    -- leash her back to companion after a full-combat unleash.
    -- CRASH-SAFE: writing kind/group contexts on a body mid-native-action is
    -- the known native-crash class (RECALL crashed doing it inline). So we
    -- only stop the monitor + clear hate now, and DEFER the identity restore
    -- (kind 2 + party group + pacify) to the tamed-tick ally path, the proven
    -- safe route (delayed, climb-guarded).
    if S.route3_unleashed ~= true then return false end
    S.route3_unleashed = nil
    S.route3_unleash_phase = nil
    S.route3_unleash_approach = nil
    S.route3_unleash_strike_until = 0.0
    -- the approach drives her airborne (route3_aerial_move_to sets S.airborne/flying);
    -- clear them or a recall mid-approach leaves a GROUNDED body still flagged airborne
    -- (breaks follow/come, keeps flight visual ticks running). State-only = crash-safe,
    -- doesn't touch her body/FSM so it stays within the deferred-restore contract.
    S.airborne = false
    S.flying = false
    S.route3_companion_moving = false
    S.audition_until_clock = 0.0
    S.companion_target = nil
    S.companion_target_go = nil
    S.companion_order = "stay"
    -- NOTE: do NOT re-puppet / think-stop / touch her FSM inline here -- she is
    -- mid native flight-action on recall, and doing it synchronously is the
    -- documented RECALL-crash class. Re-grounding is deferred to the ally tick
    -- below (the proven safe, delayed path). The brief post-unleash float is the
    -- lesser evil; fix it in the deferred restore, never inline.
    pcall(function() clear_griffin_hate() end)
    pcall(function() clear_griffin_targets() end)
    pcall(function() clear_party_hate() end)
    -- deferred, crash-safe identity restore (route3_ally_auto_tick runs it
    -- when due; it re-applies party group + kind 2 + calm burst + pacify)
    S.route3_recall_pending = true
    S.route3_ally_auto_at = os.clock() + 0.75
    S.route3_ally_calm_until = os.clock() + 12.0
    status(tostring(C.route3_griffin_name or "Companion") .. " returns to your side")
    return true
end
-- Aurora's explicit ask: "a stop command that does it early". Every existing stand-down path
-- (the Stay button, the stay hotkey, recall) already funnels through griffin_order_disengage.
function griffin_order_stop(reason)
    if griffin_combat_lease_active() then
        return griffin_combat_lease_end(reason or "ordered")
    end
    return false
end

function griffin_order_disengage(reason)
    -- End the lease FIRST, then fall through to the normal stand-down. Returning early here would
    -- skip the aerial clear / pacify / animation stop that every other disengage path performs.
    if griffin_combat_lease_active() then
        pcall(function() griffin_combat_lease_end(reason or "ordered") end)
    end
    S.companion_order = "stay"
    S.companion_target = nil
    S.companion_target_go = nil
    -- restore the citizen identity after combat
    pcall(function()
        if S.route3_attack_group_swapped == true then
            S.route3_attack_group_swapped = nil
            -- full party identity back: groups + kind 2 + grudge purge +
            -- calm burst (orig hashes stay preserved — join only saves
            -- them when the slot is empty)
            route3_ally_join_party()
            S.route3_attack_kind_prev = nil
            return
        end
        local gch = reacquire_griffin()
        local gctx = gch and route3_ally_group_ctx(gch)
        if gctx and S.route3_attack_kind_prev ~= nil then
            gctx:set_field("CharacterKind", S.route3_attack_kind_prev)
        elseif gctx then
            gctx:set_field("CharacterKind", 2)
        end
        S.route3_attack_kind_prev = nil
    end)
    pcall(function() clear_griffin_hate() end)
    pcall(function() clear_griffin_targets() end)
    pcall(function() clear_party_hate() end)
    route3_aerial_attack_clear("idle")
    -- the fight involved battle registration: keep purging grudges for a
    -- while (same calm burst as the tame moment) so pawns/NPCs let go of her
    S.route3_ally_calm_until = os.clock() + 12.0
    local gch = reacquire_griffin()
    if gch then pacify_griffin(nil) end
    stop_griffin_animation()
    status(tostring(C.route3_griffin_name or "Companion") .. " stands down" .. (reason and (" - " .. reason) or ""))
    return true
end
-- ⭐⭐ PASSIVE SPECIES (2026-08-14, Aurora: "we need to disable the attack command for what
-- would be considered passive creatures"). A rabbit or a hen has no business being ordered at a
-- goblin, and a doe/horse is prey, not a fighter.
-- ⛔ BLOCKLIST, NOT AN ALLOWLIST -- deliberately, and for the same reason the kick's heavy list
-- is one: an unrecognised creature should default to ABLE (Aurora: "majority of the time you'll
-- want the creature to attack whatever enemies it can"), so a newly tamed species works on the
-- day it is tamed instead of silently refusing until someone remembers to whitelist it.
-- ⚠ Matched by chassis PREFIX against the body's GameObject name, the same way the rodeo's
-- heavy-target list matches -- so ch299011_A_00 and ch299011_B_01 both hit the ch299011 entry.
function griffin_species_is_passive(go)
    if not go then return false, nil end
    local bands = tostring(C.route3_attack_passive_bands or "")
    if bands == "" then return false, nil end
    local nm = tostring(go_name(go) or "")
    if nm == "" then return false, nil end
    for band in bands:gmatch("[^,%s]+") do
        if nm:find(band, 1, true) then return true, band end
    end
    return false, nil
end

-- ⭐⭐⭐ THE COMBAT LEASE (2026-08-15). Aurora: "give her the AI back to attack without attacking
-- us, then when enemies are dead return to the original state, and a stop command that does it
-- early." Enter = become what a wild griffin IS. Exit = change back, exactly.
-- ⛔ Everything here is a MEASURED difference, not a guess. Census vs a live cyclops and a live
-- goblin proved her body is structurally complete; the only gaps are the wild group hash and three
-- disabled components. Aurora's own field observation ("griffins hunt goblins in Battahl") is what
-- says we need no relationship override: give her the wild identity and the hunt is native.
function griffin_combat_lease_active()
    return type(S.route3_combat_lease) == "table"
end

-- ⭐⭐⭐ THE THIRD PARKING BRAKE, and the lease shipped without releasing it.
-- [[iris-griffin-live-window-attacks]] settled this in August: think-stop and the motion-FSM puppet
-- are only brakes one and two. Below both of them the via.motion component itself is set to
-- RootPlayMode=None + RootScaleDisabled, and it is RE-APPLIED AT EVERY CLIP PAINT -- so any
-- companion who has ever been painted a walk clip carries it. A body in that state computes its
-- attack's movement every frame and the motion component throws it away: the node animates in
-- place, travels nothing, and lands no real hit windows. That is not an AI that refuses to fight.
-- Continuance(2) is the living character's mode; `live=false` puts the mount law back.
-- ⛔ A cheap component setter, NOT an engine-container mutation -- safe at frame rate, exactly the
-- same class as the puppet/think releases it sits beside (the 60Hz CTD law is about the
-- relationship and battle-group REGISTRIES, not about component flags).
function griffin_lease_root_motion(gch, live)
    gch = gch or reacquire_griffin()
    if not gch then return false end
    -- restoring when the mod does not suppress at all would be inventing a brake nobody asked for
    if live ~= true and C.root_motion_suppress_clip_locomotion ~= true then return true end
    local ok = false
    pcall(function()
        local m = gch:call("get_Motion")
        if not m then return end
        local mode = 2
        if live ~= true then
            mode = math.max(0, math.floor(tonumber(C.root_motion_suppressed_play_mode) or 0))
        end
        local set = pcall(function() m:call("set_RootMotion(via.motion.RootPlayMode)", mode) end)
        if not set then pcall(function() m:call("set_RootMotion", mode) end) end
        pcall(function()
            m:call("set_RootScaleDisabled(System.Boolean)",
                live ~= true and C.root_motion_disable_root_scale == true)
        end)
        ok = true
    end)
    return ok
end

-- ⭐⭐ HATE ONLY -- the half that DECAYS and must be re-won.
-- The documented split ([[iris-attack-enemylist-overturned]]): "frequency is everything" applies to
-- addHateParam + the hate RANKING, which the engine decays out from under you. It is NOT a licence
-- to re-write relationship or battle-group STRUCTURE, which is what hard-crashed the game three
-- times on 08-15. griffin_attack_assert_hate does BOTH, so it runs exactly once per target; this
-- runs on a slow beat and touches nothing structural.
-- ⛔ character_hate_system (global) -- NOT griffin_hate_system, which is a probe file-local and
-- would be a nil global here. That mistake has been made three times in this tree.
function griffin_lease_hate_beat(gch, go, tgt, tgo)
    if not (gch and go and tgt and tgo) then return false end
    local ok = 0
    pcall(function()
        local hs = character_hate_system(gch, go)
        if not hs then return end
        for _, combo in ipairs({ { 0, 0 }, { 0, 1 }, { 1, 0 } }) do
            pcall(function()
                hs:call(
                    "addHateParam(via.GameObject, app.HateRecvCategory, app.HateSystem.WriteType, System.Single, System.Single, System.Single, System.Single)",
                    tgo, combo[1], combo[2], 1000.0, 1000.0, 0.0, 0.0)
                ok = ok + 1
            end)
        end
    end)
    -- MUTUAL: the foe hates her back. Retaliation is the most well-worn escalation path in the
    -- game and it is what keeps a fight alive once her opening move lands.
    pcall(function()
        local ths = character_hate_system(tgt, tgo)
        if not ths then return end
        ths:call(
            "addHateParam(via.GameObject, app.HateRecvCategory, app.HateSystem.WriteType, System.Single, System.Single, System.Single, System.Single)",
            go, 0, 0, 1000.0, 1000.0, 0.0, 0.0)
        ok = ok + 1
    end)
    -- rebuild her AI's target list from the hate we just wrote
    pcall(function()
        local bb = get_component and get_component(go, "app.AIBlackBoardController")
        if bb then bb:call("updateEnemyTargetList") end
    end)
    -- pawns must not mob a monster-kind companion mid-fight: they spectate her kill
    pcall(function() clear_party_hate() end)
    S.route3_lease_hate_writes = (tonumber(S.route3_lease_hate_writes) or 0) + ok
    return ok > 0
end

-- ⭐⭐⭐⭐ ANGRY -- THE ACTUAL WALL, MEASURED 2026-08-15 12:14 IN THE FIELD.
-- With every brake off and hate on the books the telemetry read, every single line for 78 seconds:
--     node=Locomotion.Wait  clip=0:0 f317/450 (a genuine looping IDLE, not a painted freeze)
--     nav=true  puppet=false  enemyList=8-12  hateRank=3-6
--     IsAngry=FALSE  isActiveAngryAttitude=FALSE  AngryCount=0.0  selfTarget=AITargetGameObject(nil)
-- So she is not blind, not welded, not parked, not unfactioned and not un-hated. She simply is
-- not ANGRY -- and in this engine a monster fights because it is angry. Every previous round of
-- this hunt (perception, hate ranking, components, faction, the puppet, root motion) was fixing a
-- prerequisite of a decision that was never taken.
-- ⭐ app.CombatStateControl ships the doors and her own body declares them: startAngryForce,
-- startAngry, increaseAngryGaugeMax, requestAngryGaugeByID, set_AngryCount, plus the permission
-- read get_IsEnableRequsetAngry and the reverse, finishAngry.
-- ⛔ ONLY WHEN THE MEASUREMENT SAYS SHE IS NOT ANGRY. Re-firing an anger transition on a body that
-- is already angry is the "two owners" mistake in a new costume, and the angry gauge is a
-- sequenced thing (updateAngryGaugeBySequence) that we should not be re-seeding mid-fight. This
-- reads first and returns "already angry" without touching her -- so once her own AI takes over,
-- we are out of the loop entirely, which is the whole point of the lease.
-- ⛔ NEVER BLIND-CALL: every name below is verified present on HER type before it is invoked, and
-- the arity is read from the method definition rather than guessed (the blind-field law applies to
-- methods too). The first pass dumps the exact signatures so a wrong guess becomes data, not a
-- mystery.
function griffin_lease_make_angry(gch)
    gch = gch or reacquire_griffin()
    if not gch then return "no body" end
    local csc = nil
    pcall(function() csc = gch:get_field("<CombatStateControl>k__BackingField") end)
    if not csc then pcall(function() csc = gch:call("get_CombatStateControl") end) end
    if not csc then return "no CombatStateControl" end
    local was = nil
    pcall(function() was = csc:call("get_IsAngry") end)
    if was == true then
        -- ⛔ KEEP THE STATUS TRUTHFUL. Leaving the last failure text sitting in the telemetry after
        -- she becomes angry is exactly the "a broken instrument invents facts" failure this tree has
        -- been bitten by -- the log must say what is true NOW, not what was true when we last acted.
        S.route3_angry_status = "already angry (untouched)"
        return S.route3_angry_status
    end
    -- ONE-SHOT SIGNATURE DUMP: names come from the type, arity from the method def when it will
    -- give one. ⛔ DECLARATION and ARITY are separate facts: getting the method object proves the
    -- name exists on HER type (which is what the never-blind-call law actually requires), while
    -- get_num_params may not be available in every REFramework build. An unreadable arity must not
    -- veto a verified method, or a failed introspection silently disables the entire fix.
    if S.route3_angry_api == nil then
        local api = {}
        pcall(function()
            local td = csc:get_type_definition()
            for _, nm in ipairs({ "startAngryForce", "startAngry", "increaseAngryGaugeMax",
                                  "increaseAngryGauge", "increaseAngryGaugeRate",
                                  "requestAngryGaugeByID", "set_AngryCount",
                                  "get_IsEnableRequsetAngry", "isActiveAngryAttitude" }) do
                local m = td:get_method(nm)
                if m then
                    local n = nil
                    pcall(function() n = tonumber(m:get_num_params()) end)
                    local ps = {}
                    pcall(function()
                        for _, p in ipairs(m:get_param_types() or {}) do
                            ps[#ps + 1] = tostring(p:get_full_name())
                        end
                    end)
                    api[nm] = { params = n, sig = table.concat(ps, ",") }
                end
            end
        end)
        S.route3_angry_api = api
        pcall(function() json.dump_file(tostring(MOD) .. "_angry_api.json", api) end)
        pcall(function() log.info("[IrisAttack] angry API: " .. json.dump_string(api)) end)
    end
    local allowed = "?"
    pcall(function() allowed = tostring(csc:call("get_IsEnableRequsetAngry")) end)
    -- ⛔⛔ IT IS REFUSED, SO STOP KNOCKING (field 08-15 12:22): get_IsEnableRequsetAngry read FALSE
    -- on every single beat, and while the calls all returned ok the ONLY thing that moved was
    -- AngryCount, climbing 2.0 -> 16.0 while IsAngry stayed false. So these are landing on a
    -- counter behind a closed permission gate. Repeating a refused request 30 times a lease is
    -- noise that inflates engine state for nothing -- try once, then wait for the PERMISSION to
    -- change and only act if it ever does. (Anger is DD2's rage escalation, not "in combat" -- a
    -- fighting goblin is not angry either -- so this was probably never the wall. Kept as a
    -- measured lever, demoted from a theory.)
    if allowed == "false" and S.route3_angry_tried == true then
        S.route3_angry_status = "refused (IsEnableRequsetAngry=false, not re-asking)"
        return S.route3_angry_status
    end
    S.route3_angry_tried = true
    -- Try the engine's own doors, strongest first, reading IsAngry back after each -- a pcall'd
    -- call with no readback is a wish, not a fact. Stop at the first one that actually lands.
    local tried = {}
    local function attempt(name, ...)
        local rec = S.route3_angry_api and S.route3_angry_api[name]
        if not rec then return false end                  -- not declared on her type: never call it
        local args = table.pack(...)
        -- skip only when the arity is KNOWN and wrong; unknown arity still gets its (pcall'd) try
        if rec.params ~= nil and rec.params ~= args.n then
            tried[#tried + 1] = name .. "~" .. tostring(rec.params) .. "p"
            return false
        end
        local ok = pcall(function()
            if args.n == 0 then csc:call(name) else csc:call(name, table.unpack(args, 1, args.n)) end
        end)
        local got = nil
        pcall(function() got = csc:call("get_IsAngry") end)
        tried[#tried + 1] = name .. (ok and "=ok" or "=throw") .. "/" .. tostring(got)
        return got == true
    end
    local won = attempt("startAngryForce")
        or attempt("startAngryForce", true)
        or attempt("increaseAngryGaugeMax")
        or attempt("startAngry")
        or attempt("increaseAngryGaugeRate", 1.0)
    S.route3_angry_status = string.format("angry=%s enable=%s [%s]",
        tostring(won), allowed, table.concat(tried, " "))
    log.info("[IrisAttack] make angry: " .. S.route3_angry_status)
    return S.route3_angry_status
end

-- ⭐⭐⭐⭐⭐ THE TRIGGER: "SOMETHING JUST HIT ME" (Aurora, 2026-08-15, from the field).
-- With the action hook fixed she FIGHTS -- but only once a wolf actually struck her, and then she
-- fought properly and disengaged properly. So the whole loop works and the only missing piece is
-- what STARTS it. Aurora's read: "we might just need to force a hit from the enemy onto her."
-- ⭐ That is exactly right, and the engine state a hit produces is a single field:
-- `EnemyCtrl.Ch2._LastDamageHitObject`. MonsterInfightingImproved's entire retaliation gate is that
-- field (`trg_ch2._LastDamageHitObject` at :299, and :400 `cha2:get_GameObject() ==
-- ec1.Ch2._LastDamageHitObject`), and this tree already ported the write as
-- griffin_set_combat_target(gch, tgo) for the proxy era -- where it has sat, called by exactly one
-- caller, while the lease never used it.
-- ⭐⭐ BOTH DIRECTIONS, because the wolf incident is the specification: the fight sustained itself
-- once damage was flowing MUTUALLY. Marking the foe as "the thing that hit her" makes her retaliate;
-- marking her as "the thing that hit the foe" makes the foe come at her, which produces REAL damage
-- events and from there the engine's own hate/anger/retaliation machinery runs the fight without us.
-- ⛔ A field write on each body's own Ch2 -- not the relationship registry, not a battle group.
function griffin_lease_mark_mutual_damage(gch, go, tgt, tgo)
    if not (gch and go and tgt and tgo) then return false end
    local a, b = false, false
    pcall(function() a = (griffin_set_combat_target(gch, tgo) == true) end)
    pcall(function()
        -- ⛔ resolve the REAL app.Character: lease.target is an EnemyManager list item and
        -- get_field("EnemyCtrl") on one of those returns nothing at all
        local real = iris_real_character and iris_real_character(tgt) or tgt
        b = (griffin_set_combat_target(real, go) == true)
    end)
    S.route3_lease_ct = (a and "her<-foe " or "her<-foe FAIL ") .. (b and "foe<-her" or "foe<-her FAIL")
    return a or b
end

-- ⭐⭐⭐⭐⭐ THE IGNITION, FOR REAL: FORGE THE HIT (2026-08-15, Aurora's field observation).
-- Confirmed twice in the field, and it is a precise specification: **her being HIT is the trigger**.
-- Aurora hitting the enemy did nothing; the enemy hitting HER started a proper fight, and once it
-- started she threatened, ran, attacked and disengaged entirely on her own. So the fight needs no
-- driving whatsoever -- it needs a first punch.
-- ⛔ Writing `_LastDamageHitObject` was not enough: TRIG reported `her<-foe foe<-her` succeeding on
-- every beat and she still waited. That field is the RECORD of a hit, not the EVENT of one.
-- ⭐ griffin_provoke_from_target (probe:6605) is the event. It forges an app.HitController.DamageInfo
-- whose ATTACKER is the foe and whose VICTIM is her -- a full blow packet, because its own notes
-- record that "a toothless 1-dmg packet bumped hate but never STAGGERED her into combat" -- and
-- fires the whole entry cascade: set_ForceDamageInfo, onReceiveForce, applyAngryGaugeByDamage,
-- onDamageReaction, onUnbalance (the stagger signal that made her attack the player when grabbed),
-- then updateHateRanking. That is the wolf, synthesised. No HP is taken off her.
-- ⭐ griffin_seat_enemy_target (probe:6669) is the other half: her EnemyActionTargetList and
-- _AIPositionTargetDict -- the WHERE-to-go positions her ThinkTable walks -- are empty, so even a
-- provoked griffin has no AITarget to resolve into an approach. Its own header says it is "proven on
-- the companion to make native AI engage".
-- ⛔ BOTH EXISTED ALREADY AND NEITHER WAS WIRED TO THE LEASE. provoke had one caller (unleash);
-- seat_enemy_target was sitting COMMENTED OUT in this very file. Third time this session that the
-- missing piece was a built, working function nothing called.
-- ⭐⭐⭐⭐⭐ PROVOKE THE **FOE**, NOT HER (2026-08-15 -- the direction I had backwards).
-- Field truth, stated twice by Aurora: *the enemy hitting HER* is the trigger; her hitting it does
-- nothing. I answered that by synthesising a hit ON her, and the log says why that fails:
--   provoke: force,recvForce,angryDmg,react,unbal,rank,track  -- the whole cascade FIRED --
--   ...and AI[self=0]. Her AI made ZERO decisions in that run, where it made 19 before.
-- The `unbal` step STAGGERS her (the trace shows Common/InForcedAnimation.user), so re-provoking
-- her on a beat was suppressing the very decision layer we need. We are pouring synthetic state
-- into the one AI in this scene we have spent all day interfering with.
-- ⭐ THE FOE'S AI IS UNTOUCHED. It is a stock wild monster with no mod anywhere near it, and it is
-- known to work -- it is exactly what the wolf demonstrated. So make the FOE believe SHE hit IT:
-- it retaliates, closes, and lands a REAL hit on her, and a real hit is the one thing that has ever
-- started this fight. We stop faking her side and let a healthy AI supply the punch.
-- ⛔ Her side is now provoked ONCE at lease start (a kick, not a habit) and NEVER on the re-kick --
-- staggering her mid-hunt is the interruption class this whole rewrite exists to eliminate.
function griffin_lease_provoke(gch, go, tgt, provoke_her)
    if not (gch and tgt) then return false end
    local real = tgt
    pcall(function() real = (iris_real_character and iris_real_character(tgt)) or tgt end)
    -- ALWAYS: make the foe want her. This is the half that borrows a working brain.
    pcall(function() griffin_provoke_from_target(real, gch) end)
    S.route3_provoke_foe = tostring(S.route3_provoke or "?")
    -- ⛔⛔⛔ HER SIDE IS GONE ENTIRELY (08-15) -- IT WAS SEDATING HER.
    -- The evidence is a clean correlation across four runs. At 13:46, with NOTHING done to her
    -- except unblocking her actions, AI[self=19]: her decision layer was alive and choosing claw,
    -- beak, gust, run, turn. Every synthetic write added after that -- the _LastDamageHitObject
    -- pair, then the her-side provoke -- coincided with AI[self=0]: not fewer decisions, NONE.
    -- ⭐ THE MECHANISM IS IN THE TRACE: `Common/InForcedAnimation.user`. The provoke's onUnbalance
    -- STAGGERS her, and a staggered body is in a forced animation where its AI decides nothing. One
    -- stagger at lease start is enough to silence her for the whole hunt.
    -- ⇒ We were sedating the patient and then asking why she would not stand up. Her side of every
    -- synthetic provocation is removed; the foe side stays, because provoking the FOE cost her
    -- nothing and did land (its hate rank went to 2).
    S.route3_provoke = "(her side removed: onUnbalance was staggering her AI silent)"
    return true
end

-- ⭐⭐⭐⭐⭐ AND THE FLOOR: A GENUINE HIT (2026-08-15).
-- Aurora's observation is now a hard specification confirmed four times: *the enemy landing a real
-- hit on her* is the only thing that has ever started this fight. Every synthetic substitute has
-- failed -- the forged DamageInfo cascade fires completely and does nothing, the field write lands
-- and does nothing, the foe hates her (rank=2) and still will not close.
-- ⇒ Stop simulating the punch and throw it. griffin_damage_via_update runs the REAL pipeline --
-- app.HitController.updateDamageHp + updateDamageReaction -- with a DamageInfo whose attacker is
-- the foe. That is not a reaction we are faking at her AI; it is the engine's own damage
-- transaction, indistinguishable from the wolf's.
-- ⛔ ONE HP by default (route3_lease_ignite_damage) out of a 113,750 pool -- enough to be a real
-- event, small enough to be nothing. Set 0 to disable.
-- ⛔ The unsafe-packet flag is armed and restored around the call so it never stays globally on.
function griffin_lease_real_hit(gch, go, tgt)
    local amt = tonumber(C.route3_lease_ignite_damage) or 1.0
    if amt <= 0.0 then S.route3_lease_hit = "hit: off"; return false end
    local tgo = tgt and char_go(tgt)
    local hc = go and get_component and get_component(go, "app.HitController")
    if not (hc and tgo) then S.route3_lease_hit = "hit: no HitController/target"; return false end
    local ok = false
    local prev = rawget(_G, "IRIS_UNSAFE_DAMAGE_PACKET")
    rawset(_G, "IRIS_UNSAFE_DAMAGE_PACKET", true)
    pcall(function() ok = (griffin_damage_via_update(hc, amt, tgo, nil) == true) end)
    rawset(_G, "IRIS_UNSAFE_DAMAGE_PACKET", prev)
    S.route3_lease_hit = ok
        and string.format("hit: %.0f from %s", amt, tostring(go_name(tgo) or "?"))
        or "hit: FAILED"
    return ok
end

-- ⭐⭐⭐⭐ THE FIGHTER DIFF -- stop guessing which flag matters and READ A WORKING ONE.
-- This technique has already settled this project's two hardest questions (the 131-component census
-- vs a live cyclops, and the enabled-diff that named AIDecisionMaker / NavigationAI /
-- AttackNoticeRequester). We are now four rounds deep into single-flag theories -- hate, then
-- components, then faction, then anger -- each of which was true-but-insufficient. A goblin
-- actively fighting Aurora is standing right there with every one of these fields set correctly.
-- Dump BOTH bodies side by side, once per lease, and let the differences name themselves.
-- ⛔ STRICTLY READ-ONLY. get_* / get_field / get_Enabled only. Safe to run anywhere, and it cannot
-- be the cause of anything it reports.
function griffin_lease_body_snapshot(ch, tag)
    local o = { who = tag }
    if not ch then o.body = "nil"; return o end
    -- ⛔⛔⛔ RESOLVE THE REAL app.Character FIRST (08-15 -- v1 of this diff was worthless without
    -- it). griffin_find_enemy sources from app.EnemyManager, whose list items answer char_go and
    -- transform_pos but carry NO Context -- so every component and faction read on one comes
    -- back MISSING/-1/nil. The first run duly reported "CombatStateControl: them=MISSING,
    -- group: them=-1, kind: them=nil" about a goblin that was actively fighting Aurora. An
    -- instrument that reports absence when it means "I could not look" is worse than no
    -- instrument, and this tree has written that law down twice already.
    pcall(function() ch = iris_real_character and iris_real_character(ch) or ch end)
    local g = nil
    pcall(function() g = char_go(ch) end)
    pcall(function() o.body = tostring(go_name(g) or "?") end)
    pcall(function() o.group = tostring(griffin_group_hash_value(route3_ally_group_ctx(ch))) end)
    pcall(function()
        local cctx = route3_ally_group_ctx(ch)
        o.kind = tostring(cctx and cctx:get_field("CharacterKind"))
    end)
    if not g then return o end
    -- combat state: the decision layer's own opinion of itself
    pcall(function()
        local c = get_component(g, "app.CombatStateControl")
        if not c then o.csc = "MISSING"; return end
        o.csc = "present"
        local td = c:get_type_definition()
        for _, mn in ipairs({ "get_IsAngry", "isActiveAngryAttitude",
                              "get_IsEnableRequsetAngry", "get_AngryCount" }) do
            if td:get_method(mn) then
                pcall(function() o[mn:gsub("^get_", "")] = tostring(c:call(mn)) end)
            end
        end
        pcall(function()
            local f = c:call("get_CombatStatusFlag")
            if not f then o.CombatStatus = "nil"; return end
            local bits = {}
            for _, fd in ipairs(f:get_type_definition():get_fields() or {}) do
                local v = nil
                pcall(function() v = f:get_field(fd:get_name()) end)
                if type(v) == "number" or type(v) == "boolean" then
                    bits[#bits + 1] = tostring(fd:get_name()) .. "=" .. tostring(v)
                end
            end
            o.CombatStatus = #bits > 0 and table.concat(bits, ",") or "(no scalar fields)"
        end)
    end)
    -- the blackboard: what does its AI think it is looking at?
    pcall(function()
        local bb = get_component(g, "app.AIBlackBoardController")
        if not bb then o.bb = "MISSING"; return end
        o.bb = "present"
        pcall(function()
            local l = bb:call("get_EnemyActionTargetList")
            o.enemyList = tostring(l and l:call("get_Count"))
        end)
        pcall(function() o.bbReady = tostring(bb:call("get_Ready")) end)
        pcall(function()
            local t = bb:call("get_SelfAITarget")
            if not t then o.selfTarget = "nil"; return end
            local own = nil
            pcall(function() own = t:call("get_OwnerCharacter") end)
            if own == nil then pcall(function() own = t:call("get_Owner") end) end
            o.selfTarget = tostring(t:get_type_definition():get_name())
                .. "/owner=" .. tostring(own ~= nil and "SET" or "nil")
        end)
    end)
    -- hate, and whether the combat machinery is even switched on
    pcall(function()
        local hs = character_hate_system(ch, g)
        o.hateRank = tostring(hs and griffin_hate_rank_count(hs) or -1)
    end)
    -- ⭐ BattleStateCtrl -- the combat-ENTRY latch, and a FIELD on the Character (the census once
    -- called it "MISSING" by hunting for a component that does not exist). A body that has genuinely
    -- fought may carry state here that a fresh spawn does not.
    pcall(function()
        local bsc = ch:get_field("BattleStateCtrl")
        if not bsc then bsc = ch:call("get_BattleStateCtrl") end
        if not bsc then o.battleState = "MISSING"; return end
        local bits = {}
        for _, f in ipairs(bsc:get_type_definition():get_fields() or {}) do
            local fn = tostring(f:get_name() or "")
            local v = nil
            pcall(function() v = bsc:get_field(fn) end)
            if type(v) == "number" or type(v) == "boolean" then
                bits[#bits + 1] = (fn:gsub("^<", ""):gsub(">k__BackingField$", "")) .. "=" .. tostring(v)
            end
        end
        table.sort(bits)
        o.battleState = table.concat(bits, ",")
    end)
    -- ⭐⭐⭐⭐⭐ THE LATCH LAYER -- the only per-body state a real fight sets and a respawn clears.
    -- app.Ch253000 declares BattlePhaseCtrl : app.Ch253000BattlePhaseCtrl, whose phase enum is
    -- None=0 / Patrol=1 / PatrolContactPlayer=2 / PreBattle=3 / PreBattleContactPlayer=4 / Battle=5.
    -- ⭐ WHY THIS IS THE SHAPE OF THE ANSWER: Ch253ThinkFlag index 26 is Ch253000BattlePhase -- the
    -- think tree READS the phase as a root gate -- and the only other writers are the tree's own
    -- action nodes EmThkActCh253000ForceSetBattle / ForceSetPreBattle. So the phase gates the tree
    -- and the tree advances the phase: SELF-SEALING. No outside poke -- hate, faction, anger,
    -- components, nav, relationship, every single thing tried today -- can break into that loop.
    -- The one external escalator is the damage path, which is exactly and only "an enemy hit her".
    -- It also carries a LostPlayerTimer, i.e. the engine's own statement that the phase does not
    -- snap back when the foe vanishes -- which is Aurora's "she works forever after one fight".
    -- ⛔ ENUMERATED, NEVER GUESSED: the RSZ record serialises only PhaseTimer/LostPlayerTimer, so the
    -- phase field is runtime-only and its name must come from this read. Guessing it would be the
    -- same class of error as guessing a clip id.
    pcall(function()
        local c253 = get_component(g, "app.Ch253000")
        if not c253 then o.phase = "no Ch253000"; return end
        local bp = c253:get_field("BattlePhaseCtrl")
        if not bp then o.phase = "no BattlePhaseCtrl"; return end
        local bits = {}
        for _, f in ipairs(bp:get_type_definition():get_fields() or {}) do
            local fn = tostring(f:get_name() or "")
            local v = nil
            pcall(function() v = bp:get_field(fn) end)
            if type(v) == "number" or type(v) == "boolean" then
                bits[#bits + 1] = (fn:gsub("^<", ""):gsub(">k__BackingField$", "")) .. "=" .. tostring(v)
            end
        end
        table.sort(bits)
        o.phase = #bits > 0 and table.concat(bits, ",") or "(no scalar fields)"
    end)
    -- ⭐⭐⭐⭐ THE DECISION MODULE OBJECT -- never once read in this entire tree.
    -- The only AIDecisionMaker read anywhere is get_CurrentModuleType, a STORED ENUM that a hollow
    -- component leaves untouched -- so "module=1" has been exactly the same false comfort as
    -- "CombatStatusFlag=0". If <DecisionModule> is NULL she has no think table at all, which is
    -- what AI[self]=0 looks like from outside, and it would mean pacify_griffin disabling
    -- AIDecisionMaker on a HALF-BUILT body at register time (the file admits it is half-built)
    -- stopped awake()/start() from ever running -- the same lifecycle law, on the right component
    -- this time.
    pcall(function()
        local dm = get_component(g, "app.AIDecisionMaker")
        if not dm then o.decideModule = "MISSING"; return end
        local mod = nil
        pcall(function() mod = dm:get_field("<DecisionModule>k__BackingField") end)
        o.decideModule = (mod == nil) and "NULL"
            or tostring(mod:get_type_definition():get_full_name())
        pcall(function() o.decideInitSet = tostring(dm:get_field("<InitalSetType>k__BackingField")) end)
        pcall(function() o.thinkTable = tostring(dm:call("get_ThinkTableInitSetting") ~= nil) end)
    end)
    -- ⭐⭐ THE AISITUATION LAYER -- "what JOB does this AI have", and the one layer never examined
    -- today ([[dd2-aisituation-task-primitives]]). If a real fight assigns her a combat situation or
    -- task that a fresh summon lacks, this is where it shows -- and nothing else we have read all
    -- day would have seen it.
    pcall(function()
        local mgr = nil
        pcall(function() mgr = sdk.get_managed_singleton("app.AISituationManager") end)
        if not mgr then o.situation = "no manager"; return end
        local cid = nil
        pcall(function() cid = ch:call("get_CharacterID") end)
        if cid == nil then pcall(function() cid = ch:get_field("CharaID") end) end
        local agent = nil
        pcall(function() agent = mgr:call("getAgent(app.CharacterID)", cid) end)
        if not agent then o.situation = "no agent"; return end
        local n = "?"
        pcall(function()
            local tasks = agent:call("get_CurrentTasks")
            if not tasks then tasks = agent:get_field("CurrentTasks") end
            n = tostring(tasks and tasks:call("get_Count"))
        end)
        o.situation = "agent tasks=" .. tostring(n)
    end)
    pcall(function() o.thinkStop = tostring(ch:call("get_IsThinkStop")) end)
    for _, tn in ipairs({ "app.AIDecisionMaker", "app.NavigationAI", "app.AttackNoticeRequester",
                          "app.CombatStateControl", "app.AIBlackBoardController",
                          "app.LockOnTarget", "app.Monster", "app.EnemyCtrl", "app.HateSystem",
                          "app.ActionManager", "app.ActionInterface", "app.HitController",
                          "via.motion.MotionFsm2", "app.AISituationAgent" }) do
        pcall(function()
            local c = get_component(g, tn)
            o[tn:gsub("^app%.", "")] = (c == nil) and "MISSING" or tostring(c:call("get_Enabled"))
        end)
    end
    return o
end

-- ⭐⭐⭐⭐⭐ REPAIR THE HOLLOW COMBAT STATE MACHINE (2026-08-15 -- the dump-named root cause).
-- Clicking Attack hard-crashed the game, and the minidump named it exactly:
--   c0000005 READ +0xb8 (null this) -> app.MonsterCombatStatusAddBlend.start(behaviortree.ActionArg)
-- A behaviour-tree node whose job is to blend COMBAT STATUS, invoked on a null instance. So her
-- combat tree finally tried to RUN and died on the node that sets combat status -- which is why
-- CombatStatus has read 0 and IsEnableRequsetAngry false on every sample of this entire hunt.
-- Never a flag we failed to set: a tree node that could not exist.
-- ⛔ CAUSE: app.CombatStateControl was in critter_neutral_disable_components, and the law here is
-- that set_Enabled(true) resumes update() but NEVER re-runs awake()/start(). A component torn down
-- around its own initialisation comes back ENABLED BUT HOLLOW -- its AngryCtrl / Data / LotteryCtrl
-- never built -- and the tree node depending on them is null. It is removed from that list now, so
-- future bodies are fine; THIS function is for the ones already out in the world.
-- ⭐ app.CombatStateControl declares awake() and start(). Calling them is the documented missing
-- half of the enable.
-- ⛔ REPAIR ONLY WHAT IS BROKEN. It probes the required fields first and returns untouched if they
-- are populated, so a body that has survived a real fight -- the ones Aurora proved already work --
-- is never re-initialised underneath itself. Arity is read from the method definition, never
-- guessed: the blind-call law applies to lifecycle methods most of all.
function griffin_lease_repair_combat_state(gch, go)
    gch = gch or reacquire_griffin()
    if not (gch and go) then return "no body" end
    local csc = get_component and get_component(go, "app.CombatStateControl")
    if not csc then
        S.route3_csc_repair = "csc MISSING on this body"
        return S.route3_csc_repair
    end
    pcall(function()
        if csc:call("get_Enabled") ~= true then csc:call("set_Enabled", true) end
    end)
    -- which of its internals actually exist?
    local missing = {}
    for _, fn in ipairs({ "AngryCtrl", "AngryGaugeReqData", "LotteryCtrl", "Data",
                          "<CombatStatusFlag>k__BackingField", "<OwnerCharacter>k__BackingField" }) do
        local v, read_ok = nil, false
        pcall(function() v = csc:get_field(fn); read_ok = true end)
        if read_ok and v == nil then missing[#missing + 1] = (fn:gsub("^<", ""):gsub(">k__BackingField$", "")) end
    end
    if #missing == 0 then
        S.route3_csc_repair = "healthy (no re-init needed)"
        return S.route3_csc_repair
    end
    -- hollow: run the lifecycle the enable never did
    local ran = {}
    for _, mn in ipairs({ "awake", "start" }) do
        local n = nil
        pcall(function()
            local m = csc:get_type_definition():get_method(mn)
            if m then n = tonumber(m:get_num_params()) end
        end)
        if n == 0 then
            local ok = pcall(function() csc:call(mn) end)
            ran[#ran + 1] = mn .. (ok and "=ok" or "=throw")
        elseif n ~= nil then
            ran[#ran + 1] = mn .. "~" .. tostring(n) .. "p"
        end
    end
    -- re-probe: did the re-init actually build anything? A call with no readback is a wish.
    local still = {}
    for _, fn in ipairs({ "AngryCtrl", "AngryGaugeReqData", "LotteryCtrl", "Data" }) do
        local v = nil
        pcall(function() v = csc:get_field(fn) end)
        if v == nil then still[#still + 1] = fn end
    end
    S.route3_csc_repair = string.format("was-null[%s] ran[%s] still-null[%s]",
        table.concat(missing, ","), table.concat(ran, " "),
        #still > 0 and table.concat(still, ",") or "none")
    log.info("[IrisAttack] CSC REPAIR: " .. S.route3_csc_repair)
    return S.route3_csc_repair
end

-- ⭐⭐⭐⭐⭐⭐ THE ANSWER, MEASURED 2026-08-15 19:12 — **HER DECISION MODULE IS NULL**.
--   SELF DIFF vs previous lease: decideModule: was=NULL now=app.ThinkTableModule
-- On a freshly summoned body `app.AIDecisionMaker.<DecisionModule>` is **NULL**: she has no think
-- table, so she cannot decide ANYTHING. That is precisely what AI[self]=0 looks like from outside,
-- and it is why every single thing written to her all day -- hate, faction, anger, components, nav,
-- root motion, relationship, target type, battle group -- changed nothing. There was no brain to
-- read any of it.
-- ⭐ CAUSE: the spawner adopts the body on the FIRST frame it exists -> register_griffin ->
-- pacify_griffin -> set_griffin_puppet(true) -> disable_record(app.AIDecisionMaker), and the file's
-- own comment at that site admits the character "is still half-built at register time". So the
-- component is switched off across its own construction, awake()/start() never run, and the module
-- is never built. The documented law again: set_Enabled(true) resumes update() but NEVER re-runs
-- awake()/start(). I aimed that law at CombatStateControl this morning and it read healthy; it was
-- the right law on the wrong component.
-- ⭐ WHY A REAL HIT FIXES IT PERMANENTLY: a genuine damage REACTION drives the decision maker's own
-- callback -> requestSwitchModule -> switchModule, which builds the module lazily. Once built it
-- lives on that Character for the rest of its life -- so the Attack button works forever after, and
-- a re-summon is a NEW GameObject that gets pacified during construction all over again. That is
-- Aurora's observation, exactly, with no leftovers.
-- ⛔ REPAIR ONLY WHEN NULL, and read it back -- a lifecycle call with no readback is a wish.
function griffin_lease_repair_decision_module(gch, go)
    gch = gch or reacquire_griffin()
    if not (gch and go) then return "no body" end
    local dm = get_component and get_component(go, "app.AIDecisionMaker")
    if not dm then S.route3_dm_repair = "AIDecisionMaker MISSING"; return S.route3_dm_repair end
    pcall(function()
        if dm:call("get_Enabled") ~= true then dm:call("set_Enabled", true) end
    end)
    local mod = nil
    pcall(function() mod = dm:get_field("<DecisionModule>k__BackingField") end)
    if mod ~= nil then
        S.route3_dm_repair = "module present (no re-init needed)"
        return S.route3_dm_repair
    end
    -- hollow: run the lifecycle the disable skipped. Arity off the type definition, never guessed.
    local tried = {}
    local function try(mn)
        if mod ~= nil then return end
        local n = nil
        pcall(function()
            local m = dm:get_type_definition():get_method(mn)
            if m then n = tonumber(m:get_num_params()) end
        end)
        if n ~= 0 then tried[#tried + 1] = mn .. (n and ("~" .. n .. "p") or "=absent"); return end
        local ok = pcall(function() dm:call(mn) end)
        pcall(function() mod = dm:get_field("<DecisionModule>k__BackingField") end)
        tried[#tried + 1] = mn .. (ok and "=ok" or "=throw") .. "/" .. (mod ~= nil and "BUILT" or "null")
    end
    try("awake")
    try("start")
    try("initialChangeModule")
    try("reload")
    S.route3_dm_repair = string.format("was NULL -> %s [%s]",
        mod ~= nil and tostring(mod:get_type_definition():get_full_name()) or "STILL NULL",
        table.concat(tried, " "))
    log.info("[IrisAttack] DM REPAIR: " .. S.route3_dm_repair)
    return S.route3_dm_repair
end

-- ⭐⭐⭐⭐⭐ HER, VERSUS HERSELF (2026-08-15 -- Aurora's decisive observation).
-- "A goblin attacked her, she fought back. I despawned it, she calmed down. I spawned a NEW goblin
--  and clicked Attack -- and she went and attacked it. Dismiss and resummon her, fresh goblin,
--  Attack: nothing."
-- ⇒ THE ATTACK COMMAND WORKS. It works on a body that has already been in one real fight, and stops
-- working on a freshly summoned one. So the blocker is neither the command nor the enemy: it is a
-- STATE THE BODY ACQUIRES FROM A GENUINE FIGHT AND LOSES ON RESPAWN.
-- ⛔ Which means every comparison I have run today was against the wrong subject. Her vs a goblin
-- was never going to show it -- the difference is her vs HERSELF, before and after. This snapshots
-- the same body at every lease start and auto-diffs against the previous snapshot, so Aurora's own
-- sequence (resummon -> Attack fails -> get hit -> fight -> Attack works) prints the delta directly.
-- ⛔ Strictly read-only.
function griffin_lease_self_snapshot(gch, tag)
    local snapshot = griffin_lease_body_snapshot(gch, tag)
    local hist = S.route3_lease_snaps
    if type(hist) ~= "table" then hist = {}; S.route3_lease_snaps = hist end
    local prev = hist[#hist]
    hist[#hist + 1] = snapshot
    while #hist > 6 do table.remove(hist, 1) end
    if prev then
        local diffs = {}
        for k, v in pairs(snapshot) do
            if k ~= "who" and tostring(prev[k]) ~= tostring(v) then
                diffs[#diffs + 1] = string.format("%s: was=%s now=%s", k, tostring(prev[k]), tostring(v))
            end
        end
        for k, v in pairs(prev) do
            if snapshot[k] == nil then
                diffs[#diffs + 1] = string.format("%s: was=%s now=(absent)", k, tostring(v))
            end
        end
        table.sort(diffs)
        log.info("[IrisAttack] SELF DIFF vs previous lease: "
            .. (#diffs > 0 and table.concat(diffs, " | ") or "(IDENTICAL -- the difference is not in any field read here)"))
    end
    pcall(function()
        json.dump_file(tostring(MOD) .. "_lease_snapshots.json", hist)
    end)
    return snapshot
end

function griffin_lease_fighter_diff(gch, go, foe)
    local snap = griffin_lease_body_snapshot
    local mine = snap(gch, "COMPANION")
    local theirs = snap(foe, "FIGHTER")
    -- name the differences rather than making a human eyeball two blobs
    local diffs = {}
    for k, v in pairs(theirs) do
        if k ~= "who" and k ~= "body" and tostring(mine[k]) ~= tostring(v) then
            diffs[#diffs + 1] = string.format("%s: us=%s them=%s", k, tostring(mine[k]), tostring(v))
        end
    end
    table.sort(diffs)
    pcall(function()
        json.dump_file(tostring(MOD) .. "_fighter_diff.json",
            { companion = mine, fighter = theirs, diffs = diffs })
    end)
    log.info("[IrisAttack] FIGHTER DIFF vs " .. tostring(theirs.body) .. ": "
        .. (#diffs > 0 and table.concat(diffs, " | ") or "(identical on every field read)"))
    -- ⭐ And the fighter's RAW readings, not only the differences: a field that matches is just as
    -- much evidence as one that does not, and "CombatStatus is 0 on BOTH bodies" would rewrite the
    -- whole diagnosis. Print the working example in full so it can never be inferred by absence.
    log.info(string.format(
        "[IrisAttack] FIGHTER RAW %s: CombatStatus=%s IsAngry=%s enableAngry=%s angryAttitude=%s "
        .. "selfTarget=%s enemyList=%s hateRank=%s group=%s kind=%s | AIDecisionMaker=%s NavigationAI=%s "
        .. "AttackNoticeRequester=%s CombatStateControl=%s LockOnTarget=%s",
        tostring(theirs.body), tostring(theirs.CombatStatus), tostring(theirs.IsAngry),
        tostring(theirs.IsEnableRequsetAngry), tostring(theirs.isActiveAngryAttitude),
        tostring(theirs.selfTarget), tostring(theirs.enemyList), tostring(theirs.hateRank),
        tostring(theirs.group), tostring(theirs.kind), tostring(theirs.AIDecisionMaker),
        tostring(theirs.NavigationAI), tostring(theirs.AttackNoticeRequester),
        tostring(theirs.CombatStateControl), tostring(theirs.LockOnTarget)))
    return diffs
end

-- ⭐⭐⭐ IS SHE ACTUALLY DOING ANYTHING? (08-15 -- the reading that replaces the blind timer.)
-- A time cadence "depends on no reading that can lie", which is true and is also why it cannot
-- tell a griffin mid-lightning-charge from one stood still: it kicks both. A LIVE body moves
-- through FSM nodes or moves through SPACE; a parked one does neither. So: unchanged node AND
-- under `route3_lease_idle_move_m` of travel, for `route3_lease_idle_secs`, is the definition of
-- parked -- no whitelist, and every present and future authored move is protected for free.
-- (Same shape as the float un-stick's dwell test, which is the right idea already in the tree.)
-- ⛔ FAILS CLOSED. An unreadable node or position returns NOT-idle, so a blind instrument can only
-- ever make us do nothing -- never make us stomp her. An unreadable state is not a permit.
function griffin_lease_idle_for(lease, go, now)
    if not (lease and go) then return 0.0 end
    local node = nil
    pcall(function() node = read_griffin_fsm_node() end)
    local pos = nil
    pcall(function() pos = transform_pos(go) end)
    if not node or node == "" or node == "(unknown)" or not pos then
        lease.idle_since = nil
        return 0.0
    end
    local moved = 999.0
    local last = lease.idle_pos
    if last then
        local dx = (tonumber(pos.x) or 0.0) - (tonumber(last.x) or 0.0)
        local dy = (tonumber(pos.y) or 0.0) - (tonumber(last.y) or 0.0)
        local dz = (tonumber(pos.z) or 0.0) - (tonumber(last.z) or 0.0)
        moved = math.sqrt(dx * dx + dy * dy + dz * dz)
    end
    local budge = math.max(0.05, tonumber(C.route3_lease_idle_move_m) or 0.6)
    if tostring(node) ~= tostring(lease.idle_node or "") or moved > budge then
        lease.idle_node = tostring(node)
        lease.idle_pos = { x = pos.x, y = pos.y, z = pos.z }
        lease.idle_since = now
        return 0.0
    end
    if not lease.idle_since then lease.idle_since = now; return 0.0 end
    return now - lease.idle_since
end

function griffin_combat_lease_start(target)
    if C.route3_lease_enabled == false then return false end
    -- ⛔ 08-15 BUG: this used to bare-return true when a lease was already live, WITHOUT setting
    -- the order or the target -- so pressing Follow (which never ended the lease) and then Attack
    -- left a running lease, an unchanged "follow" order, and a button that silently did nothing.
    -- Re-point the existing lease at the new target instead of refusing.
    if griffin_combat_lease_active() then
        local L = S.route3_combat_lease
        L.target = target
        L.target_go = char_go(target)
        L.last_seen = os.clock()
        S.companion_order = "attack"
        S.companion_target = target
        S.companion_target_go = L.target_go
        status(tostring(C.route3_griffin_name or "Companion") .. " switches quarry")
        return true
    end
    local gch, go = reacquire_griffin()
    if not (gch and go and target) then return false end
    -- ⛔⛔⛔ RESOLVE THE REAL app.Character ONCE, HERE, BEFORE ANYTHING STORES IT (08-15).
    -- griffin_find_enemy sources from app.EnemyManager and its list items are NOT app.Characters:
    -- char_go and transform_pos work on them, everything else does not. On a READ that costs a wrong
    -- answer (it made the fighter diff report MISSING about a goblin mid-fight). On a WRITE into the
    -- relationship registry it costs an ACCESS VIOLATION -- the log caught ten c0000005s at exactly
    -- the 6s re-kick cadence, every one of them inside
    -- app.BattleRelationshipHolder.requestSetRelationshipFromTo, which is the same native call that
    -- preceded all three hard CTDs on 08-15. REFramework's VMContext absorbed them; that is luck,
    -- not safety.
    -- ⇒ Resolve at the SOURCE so every downstream consumer -- the wake, assert_hate, the provoke,
    -- the group copy, S.companion_target and its ten readers -- gets a real Character for free.
    pcall(function() target = (iris_real_character and iris_real_character(target)) or target end)
    local tgo = char_go(target)
    if not tgo then return false end
    -- ⛔ FAIL CLOSED. If it still has no readable Context it is not a body we may hand to the
    -- registry at all -- refuse the lease rather than spend the fight access-violating.
    local ctx_ok = false
    pcall(function() ctx_ok = (select(2, route3_ally_group_ctx(target)) ~= nil) end)
    if not ctx_ok then
        status("cannot lock onto that target")
        log.info("[IrisAttack] LEASE REFUSED: target has no readable Context (would AV the registry)")
        return false
    end
    local lease = { started = os.clock(), target = target, target_go = tgo,
                    last_seen = os.clock() }
    -- SNAPSHOT FIRST, and only then touch anything -- a lease that cannot restore is a one-way
    -- door, and this one moves her off the party faction.
    lease.prior_components = griffin_wake_combat_components(true, gch)
    -- ⭐⭐⭐⭐ REPAIR BEFORE ENGAGING -- and in this order. Waking the component is only half the
    -- enable; if its internals were never built, the very first thing her combat tree does is
    -- dereference a null and take the process with it (15:24 CTD). Repair, THEN provoke.
    pcall(function() griffin_lease_repair_combat_state(gch, go) end)
    -- ⭐⭐⭐⭐⭐⭐ AND THE ONE THAT ACTUALLY MATTERS: build her think table if she has none.
    -- Measured 19:12 -- decideModule was NULL on a fresh summon and app.ThinkTableModule after one
    -- real fight. Everything else in this function is decoration until she has a brain to read it.
    pcall(function() griffin_lease_repair_decision_module(gch, go) end)
    -- ⭐ THE IDENTITY. Copy the faction box straight off the body she is about to fight: it is a
    -- guaranteed-live monster group (measured 1895570358 for goblin, cyclops AND her own stashed
    -- wild value), which beats trusting S.route3_ally_orig -- memory records that stash can be
    -- poisoned with the party hash on reclaim.
    -- ⛔ THIS IS THE CRASH FIX. All three CTDs were party-group + kind 8 = a battle group the
    -- engine cannot represent. Wild group + kind 8 is what every monster in Battahl already is.
    -- ⭐ Capture the WANTED hash here, where griffin_group_copy_from has already resolved the real
    -- app.Character for us and read it back. The per-frame guard compares against this number, so
    -- it never has to re-read a Context-less EnemyManager item (which is what broke v1).
    -- ⭐⭐⭐⭐⭐ THE FACTION TRADE, RE-OPENED (2026-08-15). This file's own note records the measured
    -- trade-off that forced the wild identity:
    --   party group + kind 8 -> goblins ARE enemies (enemyList 19-35), but the battle group is
    --                           malformed = the three CTDs
    --   wild  group + kind 8 -> coherent and crash-free, but a monster-faction griffin correctly
    --                           classifies goblins as ALLIES = enemyList collapses to 0-4
    -- ⛔ We have spent this entire session asking why she will not fight, on a faction where SHE HAS
    -- NOTHING TO FIGHT. enemyList has read 2-6 all afternoon. She is not refusing; the field is empty.
    -- ⭐ The wild group was adopted for exactly ONE reason -- to stop the CTDs -- and all three
    -- causes of those CTDs have been found and fixed TODAY: griffin_attack_assert_hate at 60Hz
    -- (once per target now), GroupHash rewritten every frame (write-on-mismatch, measured
    -- hold=1300+/set=0 -- the engine never reverts it), and EnemyManager list items handed to
    -- requestSetRelationshipFromTo (resolved to real app.Characters, ten caught c0000005s gone).
    -- ⇒ Default OFF: keep her own identity, where the enemies are actually enemies. The relationship
    -- override and the hate door still protect the player, pawns and NPCs in both directions.
    if C.route3_lease_wild_group == true then
        local took9, after9, want9 = nil, nil, nil
        pcall(function() took9, after9, want9 = griffin_group_copy_from(gch, target) end)
        lease.group_set = took9
        lease.want_group = tonumber(want9)
    else
        lease.group_set = "kept (own faction)"
        lease.want_group = nil
    end
    -- ⭐⭐⭐⭐⭐⭐ CHARACTER KIND 8 -- the last measured difference from a body that fights.
    -- With her think table repaired, the fighter diff finally reads clean: decideModule,
    -- decideInitSet(207), thinkTable, bbReady, and every combat component are now IDENTICAL to an
    -- actively-fighting goblin. Exactly two differences remain -- group and KIND -- and she was
    -- sitting at kind 2.
    -- ⛔ route3_ally_join_party DOES set kind 8 (probe:5674-5684) whenever
    -- route3_companion_can_be_attacked is true... but griffin_order_disengage forces kind 2 on every
    -- stand-down (orders.lua, the CharacterKind branch) and nothing ever set it back. So every lease
    -- after the first ran on a party ally.
    -- ⭐ THE CODE'S OWN COMMENT AT probe:5675: "Kind 2 is socially calm but is EXCLUDED FROM NATIVE
    -- MONSTER TARGET SELECTION." A monster that is excluded from monster target selection is a
    -- monster with nothing to select.
    -- ⛔ SAFETY: kind 8 + PARTY group is the malformed identity behind all three 08-15 CTDs. kind 8
    -- + WILD group is what every monster in Battahl already is, and it is what we set together here
    -- -- never one without the other.
    pcall(function()
        local gctx = route3_ally_group_ctx(gch)
        if not gctx then return end
        lease.kind_prev = tonumber(gctx:get_field("CharacterKind"))
        if C.route3_lease_wild_group == true then
            gctx:set_field("CharacterKind", 8)
            lease.kind_set = tostring(gctx:get_field("CharacterKind"))
        end
    end)
    -- the AI tracer identifies her by address OR name; publish both, and reset its counters so each
    -- hunt's reading stands alone rather than accumulating across presses.
    pcall(function() S.route3_lease_go_name = tostring(go_name(go) or "") end)
    S.route3_lease_ai_self, S.route3_lease_ai_other, S.route3_lease_ai_logged = 0, 0, 0
    S.route3_lease_actions_passed = 0
    S.route3_lease_ttype_hits, S.route3_lease_ttype_calls = 0, 0
    S.route3_lease_ttype_seen, S.route3_lease_ttype_seen_n = nil, 0
    -- publish BEFORE the fight starts: ownership, friendly-fire and downed all key on this while
    -- she is off-party (see griffin_body_is_ours).
    pcall(function() rawset(_G, "IrisCombatLeaseAddr", go:get_address()) end)
    -- ⭐⭐⭐ THE LIFECYCLE RESET, and it must come AFTER the identity is in place so the state
    -- machine restarts as the thing she now is. Taming set_Enabled(false)'d her combat components;
    -- re-enabling them resumes update() but NEVER re-runs awake()/start(), so the combat state
    -- machine stays parked at cstate 0 -- which is exactly "sees 19 enemies, sits in
    -- Locomotion.Wait". resetActionAndAI is the one lifecycle-reset call in the tree, and July
    -- recorded it moving her Locomotion.Wait -> Attack.Attack01 (and hate rank 0 -> 1).
    -- ⛔ Safe HERE and only here: she is a parked body at this instant. Calling it on a body
    -- mid-native-action is a documented crash class.
    -- ⛔⛔⛔ THE PARKING BRAKES -- and I built this entire lease without them (08-15).
    -- The telemetry is the proof: module=1 (the COMBAT decision module), hate=1, enemyList=16,
    -- relForced climbing hard... and node=Locomotion.Wait. Her brain decided; her BODY stayed
    -- parked. Established hours earlier on the probe and then never carried across:
    -- C.puppet_motion_fsm is TRUE, and ~19 sites "restore" a body by writing
    -- set_motion_fsm_puppet(go, C.puppet_motion_fsm == true) -- the mod's restore path IS a
    -- re-puppet. A PUPPETED MotionFsm2 does not run its own transitions, so it can never leave
    -- Locomotion.Wait however good the enemy list is. Think-stop and nav are the same story: the
    -- probe released all of these on every run; the lease released none of them.
    pcall(function() restore_disabled() end)
    pcall(function() set_think_stop(gch, false) end)
    pcall(function() stop_navigation(gch, false) end)
    pcall(function() set_griffin_motion_speed(1.0) end)
    pcall(function() set_motion_fsm_puppet(go, false) end)
    pcall(function() gch:call("resetActionAndAI") end)
    -- ⭐⭐⭐ THE IGNITION (Aurora, 08-15: "get her out of Locomotion.Wait so she can natively start
    -- attacking"). Everything is primed -- module=1, hate=1, enemyList=16, puppet=false -- and she
    -- still never transitions. An AI parked in an idle node may never re-evaluate INTO combat;
    -- once it is IN a combat tree it has somewhere to go. So kick the door open and hand over.
    -- ⭐ griffin_wake_natural_combat IS that kick, and it already exists (probe:7775): it sets
    -- `BattleStateCtrl.<IsDetectArisenParty>k__BackingField = true` -- THE combat-entry latch, the
    -- thing a freshly spawned enemy gets for free at instantiation -- and fires the wake action
    -- nodes (route3_natural_wake_action_nodes = "CombatStateNormal,...").
    -- ⛔ FOR THE RECORD: BattleStateCtrl is a FIELD ON THE CHARACTER, not a component. The census
    -- reporting "BattleStateController=MISSING" was a false negative from the wrong lookup -- the
    -- latch was reachable all along. The unleash path calls this; the lease never did.
    -- ⛔ AND KEEP THE WAKE OFF THE AERIAL MOVES. route3_natural_wake_action_nodes ships as
    -- "CombatStateNormal,Ch253TakeoffLong,Ch253GaleAttack,Ch253AirLandingPressStartLoop" -- three
    -- of those four are FLIGHT moves, and firing them at a goblin standing next to her is exactly
    -- what Aurora saw: "random flying attack animations, then flight idle". For a commanded fight
    -- we want the state entry only; the actual strike comes from griffin_swing_once, which uses
    -- route3_attack_nodes ("Attack.Attack01", the ground move). Snapshot + restore so the wake list
    -- is untouched for every other caller.
    lease.wake_nodes_prior = C.route3_natural_wake_action_nodes
    C.route3_natural_wake_action_nodes = "CombatStateNormal"
    S.route3_combat_lease = lease
    S.companion_order = "attack"
    S.companion_target = target
    S.companion_target_go = tgo
    -- ⭐⭐⭐ HAND HER BODY BACK. The DRIVEN path clears all of this before it fights (see
    -- griffin_order_attack below) and the lease never did -- so pressing Attack while she was
    -- FOLLOWING left S.route3_companion_moving latched true, and our own onRootApply hook then
    -- returns SKIP_ORIGINAL on her every frame. Her root motion is EATEN: she animates each attack
    -- on the spot and can never close on a foe. That is the "walks in place, can't close on the
    -- target" bug the driven path's own comment describes, arriving through the back door.
    -- ⛔ Nothing clears that flag while a lease runs, because every writer of it lives in the
    -- follow driver, which the lease deliberately stands down. It has to be cleared here.
    S.route3_companion_moving = false
    S.route3_follow_running = false
    S.route3_follow_clip = nil
    S.route3_whistle_flyin = nil
    S.drive_pos, S.drive_rot = nil, nil
    S.route3_air_pos, S.route3_air_rot = nil, nil
    S.airborne = false
    S.flying = false
    -- release brake three, and let her WALK
    pcall(function() griffin_lease_root_motion(gch, true) end)
    pcall(function() stop_navigation(gch, false) end)
    -- ⭐⭐⭐⭐ GIVE HER A REASON TO FIGHT. The lease never wrote a single point of hate (08-15):
    -- griffin_order_attack returns at the lease branch BEFORE its own griffin_attack_assert_hate
    -- call, lease start never called it, and the tick is explicitly forbidden from calling it. So
    -- she had the wild faction, woken components, a valid enemy in her list -- and NOTHING had ever
    -- told her to be angry at it. assert_hate is also the only site of registBattleGroup, the
    -- membership every actually-fighting monster has and our ordered tame never did.
    -- ⛔ ONCE, HERE. This writes relationship + battle-group STRUCTURE, and hammering that is what
    -- hard-crashed the game three times on 08-15. The half that decays -- the hate RANKING -- is
    -- re-won on its own slow beat in the tick via griffin_lease_hate_beat.
    S.route3_attack_battle_reg = nil
    S.route3_lease_hate_writes = 0
    pcall(function() griffin_attack_assert_hate() end)
    -- ⭐⭐⭐⭐⭐ AND PULL THE TRIGGER: tell each body the other one just hit it...
    pcall(function() griffin_lease_mark_mutual_damage(gch, go, target, tgo) end)
    -- ...and then actually FORGE THE HIT. The field write alone is a record, not an event; the
    -- event is what the wolf supplied and what she has been waiting for all day.
    pcall(function() griffin_lease_provoke(gch, go, target, false) end)
    -- ...and then throw the actual punch on the enemy's behalf.
    pcall(function() griffin_lease_real_hit(gch, go, target) end)
    -- ⭐⭐⭐⭐ AND MAKE HER ANGRY. Field-measured 08-15: hate, faction, components, nav, root motion
    -- and the enemy list were ALL correct and she still read IsAngry=false / AngryCount=0 for 78
    -- straight seconds. Hate is what she is angry ABOUT; anger is what makes her act on it.
    pcall(function() griffin_lease_make_angry(gch) end)
    -- NOW kick the door: she enters battle mode with hate already on the books, not before it.
    pcall(function() griffin_wake_natural_combat(gch, target, true) end)
    -- ⭐ AND MEASURE OURSELVES AGAINST THE THING THAT WORKS, once, at the start of every hunt.
    -- Read-only; the target is a monster that is demonstrably fighting right now.
    pcall(function() griffin_lease_fighter_diff(gch, go, target) end)
    -- ⭐⭐⭐⭐⭐ AND SNAPSHOT HER AGAINST HER OWN PAST SELF. Aurora's sequence -- resummon, Attack
    -- (fails), get hit, fight, Attack (works) -- produces two snapshots of the SAME body either
    -- side of the thing that changes, and the diff between them is the answer.
    pcall(function()
        griffin_lease_self_snapshot(gch, string.format("lease#%d",
            (tonumber(S.route3_lease_snap_n) or 0) + 1))
        S.route3_lease_snap_n = (tonumber(S.route3_lease_snap_n) or 0) + 1
    end)
    local now0 = os.clock()
    lease.hate_at = now0
    lease.rekick_at = now0 + math.max(1.0, tonumber(C.route3_lease_rekick_secs) or 6.0)
    lease.target_addr = nil
    pcall(function() lease.target_addr = tgo:get_address() end)
    -- the calm burst clears hate every 0.5s and stands down for companion_order=="attack";
    -- setting the order above is what releases it, no manual zeroing needed.
    local nm = tostring(C.route3_griffin_name or "Companion")
    status(nm .. " goes hunting")
    log.info(string.format("[IrisAttack] LEASE START group_set=%s target=%s",
        tostring(lease.group_set), tostring(go_name(tgo))))
    return true
end

function griffin_combat_lease_end(reason)
    local lease = S.route3_combat_lease
    if not lease then return false end
    S.route3_combat_lease = nil
    pcall(function() rawset(_G, "IrisCombatLeaseAddr", nil) end)
    local gch = reacquire_griffin()
    -- restore components to EXACTLY what they were, then hand her identity back through the
    -- proven path: route3_ally_join_party is what put her on the party faction in the first place
    -- (it copies the player's boxed hash + sets kind + clears hate + arms the calm burst).
    if lease.wake_nodes_prior ~= nil then
        C.route3_natural_wake_action_nodes = lease.wake_nodes_prior
    end
    pcall(function() griffin_restore_combat_components(lease.prior_components, gch) end)
    -- ⭐⭐ PUT BACK EVERY BRAKE THE LEASE RELEASED -- symmetry, or the lease is a one-way door.
    -- Root motion must go back under the mount law: leaving it at Continuance on a body whose AI
    -- has just been re-disabled is the documented "ground skating" state.
    -- The live window and the swing grace are closed explicitly: either could be left open by a
    -- fallback forced swing fired in the lease's final seconds, and a stale grace also stands the
    -- float un-stick down -- i.e. it would disarm the only weld recovery in the tree.
    -- put her kind back exactly as we found it, before the party restore below runs
    pcall(function()
        local gctx = route3_ally_group_ctx(gch)
        if gctx and lease.kind_prev then gctx:set_field("CharacterKind", lease.kind_prev) end
    end)
    pcall(function() griffin_lease_root_motion(gch, false) end)
    pcall(function() griffin_attack_live_window_close("lease end") end)
    S.route3_swing_grace_until = 0.0
    S.route3_attack_battle_reg = nil
    -- ⭐ AND NORMALISE HER ONCE, HERE. route3_post_landing_recover_tick is the tree's universal
    -- "put this body back to neutral" net (idle clip, hate/targets cleared, nav parked, FSM back to
    -- Locomotion.Wait) and the lease stands it down for its whole life -- so if a native flight
    -- attack left her in an air node, nothing would ever bring her down. Arming it here is safe
    -- precisely because S.route3_combat_lease was cleared above: it fires on the next frame, once,
    -- against a companion that is ours again.
    S.route3_post_landing_recover_at = os.clock()
    pcall(function() route3_ally_join_party() end)
    pcall(function() clear_griffin_hate() end)
    pcall(function() clear_griffin_targets() end)
    S.companion_order = "follow"
    S.companion_target = nil
    S.companion_target_go = nil
    local nm = tostring(C.route3_griffin_name or "Companion")
    status(nm .. " stands down" .. (reason and (" - " .. reason) or ""))
    log.info("[IrisAttack] LEASE END: " .. tostring(reason)
        .. " hateBlocks=" .. tostring(S.route3_lease_hate_blocks or 0))
    return true
end

function griffin_combat_lease_tick()
    local lease = S.route3_combat_lease
    if not lease then return false end
    local gch, go = reacquire_griffin()
    if not (gch and go) then return griffin_combat_lease_end("body lost") end
    local now = os.clock()
    -- HARD CAP: she always comes home, whatever else goes wrong.
    if now - (tonumber(lease.started) or now) > (tonumber(C.route3_lease_max_secs) or 120.0) then
        return griffin_combat_lease_end("time")
    end
    -- interrupts that must win immediately
    if S.mounted == true then return griffin_combat_lease_end("mounted") end
    -- ⭐ ANY other order cancels the hunt. Follow/Come set companion_order directly and never
    -- routed through griffin_order_disengage, so a lease could keep running underneath a "follow"
    -- order -- the companion is then factionally wild while the UI says she is heeling. This is
    -- also the honest implementation of Aurora's "stop command": every order is a stop.
    if S.companion_order ~= "attack" then
        return griffin_combat_lease_end("order: " .. tostring(S.companion_order or "none"))
    end
    pcall(function()
        local d = rawget(_G, "IrisDownedAddrs")
        local a = go:get_address()
        if type(d) == "table" and a and d[a] then griffin_combat_lease_end("downed") end
    end)
    if not griffin_combat_lease_active() then return true end
    -- re-assert the wild faction: the engine reverts group writes (the documented law behind
    -- route3_ally_join_party's own per-beat re-assert), and a lapsed faction mid-fight would put
    -- her straight back into the party-group + kind-8 contradiction that CTD'd three times.
    -- ⛔⛔ `valid()` IS NOT AVAILABLE HERE. It is a file-LOCAL in every module that defines it and
    -- context.lua does not export it -- the third nil-global of the night after get_component and
    -- griffin_hate_system. It would have thrown inside pcall(griffin_combat_lease_tick), been
    -- swallowed, and STOPPED THE LEASE FROM TICKING AT ALL -- i.e. no exit conditions, no timeout,
    -- no stop: a companion permanently stuck as a wild monster. Not needed anyway:
    -- griffin_group_copy_from pcalls every access and no-ops on a dead body.
    -- ⭐⭐⭐⭐ WRITE THE FACTION ONLY WHEN IT IS ACTUALLY WRONG (08-15, Aurora: "a boss bar appears
    -- but every second it tries to disappear and reappear").
    -- ⛔ This used to call griffin_group_copy_from EVERY FRAME on the standing assumption that "the
    -- engine reverts group writes". That assumption has never been MEASURED, and GroupHash is
    -- battle-group STRUCTURE -- the same class of write this tree's own law says must never be
    -- hammered, and the class at the top of all three 08-15 crash stacks. A boss gauge that
    -- registers and unregisters once a second is the visible signature of exactly that churn: the
    -- engine cannot settle a combat state on a body whose team identity changes 60 times a second.
    -- ⭐ So: read first, write only on mismatch, and COUNT both. If `grpHold` climbs and `grpSet`
    -- stays at 1, the engine never reverted and the per-frame write was pure damage. If grpSet
    -- climbs too, the revert is real and we will have finally measured it instead of assuming it.
    -- ⛔ v1 OF THIS CHECK WAS BROKEN BY THE SAME TRAP AS THE DIFF (08-15): it read the WANTED hash
    -- off lease.target every frame, and lease.target is an app.EnemyManager list item with no
    -- readable Context -- so `want` was always nil, the comparison always "mismatched", and it wrote
    -- every single frame anyway (grp[hold=0 set=298] in 6s). Compare against the hash we RESOLVED
    -- ONCE at lease start instead; the wild monster group is a constant, so there is nothing to
    -- re-read per frame. This is the difference between a guard and a guard-shaped no-op.
    -- ⛔ Only when the lease actually swapped her faction. On her own identity there is nothing to
    -- re-assert and nothing to fight the engine over.
    if C.route3_lease_wild_group ~= true then
        lease.grp_hold = (tonumber(lease.grp_hold) or 0) + 1
    elseif lease.want_group then
        local have = nil
        pcall(function() have = tonumber(griffin_group_hash_value(route3_ally_group_ctx(gch))) end)
        if have ~= nil and have == lease.want_group then
            lease.grp_hold = (tonumber(lease.grp_hold) or 0) + 1
        else
            lease.grp_set = (tonumber(lease.grp_set) or 0) + 1
            pcall(function() griffin_group_copy_from(gch, lease.target) end)
        end
    elseif lease.target then
        -- no resolved target hash (start-time copy failed): fall back to the old behaviour rather
        -- than silently leaving her on the party faction mid-fight
        lease.grp_set = (tonumber(lease.grp_set) or 0) + 1
        pcall(function() griffin_group_copy_from(gch, lease.target) end)
    end
    -- ⭐⭐⭐ HOLD THE BRAKES OFF, EVERY FRAME. Releasing once at lease start is the losing move --
    -- the probe proved a one-shot puppet release reads back as PUPPET=true inside a single frame,
    -- because ~19 restore sites re-assert C.puppet_motion_fsm (which is TRUE). Same law as every
    -- other tick-war in this codebase: a single write never beats a per-frame writer.
    -- ⛔ These are cheap component/flag setters, NOT engine-container mutations -- unlike the
    -- relationship-registry WRITES that CTD'd three times tonight. Safe at frame rate.
    pcall(function() set_motion_fsm_puppet(go, false) end)
    pcall(function() set_think_stop(gch, false) end)
    -- ⭐⭐⭐ AND THE OTHER TWO BRAKES, which the lease was never holding off (08-15).
    -- (1) NAVIGATION. route3_post_landing_recover_tick, stop_griffin_animation and every pacify
    -- path call stop_navigation(ch, TRUE), and nothing here undid it -- a companion who has decided
    -- to fight but cannot path is indistinguishable from one who refuses to.
    -- (2) ROOT MOTION. See griffin_lease_root_motion: without it her attack animates in place.
    -- (3) THE ROOT-APPLY HOOK. S.route3_companion_moving latches true in the follow driver, and our
    -- onRootApply hook then SKIPs her root motion outright. The follow driver is stood down while
    -- the lease runs, so nothing else can ever clear it.
    pcall(function() stop_navigation(gch, false) end)
    pcall(function() griffin_lease_root_motion(gch, true) end)
    S.route3_companion_moving = false
    -- ⭐⭐⭐ REPUBLISH HER IDENTITY EVERY TICK, from the LIVE body (08-15).
    -- The AI tracer's match used a global stamped ONCE at lease start, and the decider log then
    -- showed a ch253000 choosing actions with an address AND a name that both disagreed with it
    -- (seen ch253000_00_19 @1066432048 vs ours ch253000_00 @1007537344). A cached identity cannot
    -- tell "that is a different griffin" from "our stamp went stale" -- and AI[self]=0, the number
    -- this entire investigation has rested on, is only meaningful if this match is right.
    pcall(function()
        rawset(_G, "IrisCombatLeaseAddr", go:get_address())
        S.route3_lease_go_name = tostring(go_name(go) or "")
        S.route3_lease_me = S.route3_lease_go_name .. "@" .. tostring(go:get_address())
    end)
    -- both hooks are load-installed, but a load-time miss must not mean "silently absent all
    -- session" -- retry from the tick, the pattern every other hook in this tree uses.
    pcall(function() griffin_install_lease_hate_door() end)
    pcall(function() griffin_install_lease_relationship_hook() end)
    pcall(function() griffin_install_lease_target_type_hook() end)
    pcall(function() griffin_install_lease_ai_tracer() end)
    -- ⭐ IS THE FIGHT OVER? Any live enemy in the radius keeps it going -- not just the original
    -- target, because she should finish the pack rather than stop at one kill.
    -- ⛔ THIS RUNS FIRST NOW. It used to sit at the very bottom, AFTER the ignition, so on the tick
    -- the lease ended we had already fired a fresh enemy-relationship write and an attack node at a
    -- corpse, on a body being handed back to the party faction in the same tick -- the two-owners
    -- condition the crash law warns about. Decide whether the fight is still on before touching her.
    local foe = nil
    pcall(function() foe = griffin_find_enemy(tonumber(C.route3_lease_radius) or 45.0) end)
    if foe then
        lease.last_seen = now
        -- ⭐⭐ STICKY QUARRY -- she finishes the one she is on. griffin_find_enemy returns the
        -- nearest enemy TO THE PLAYER, so re-pointing at whatever it returns each frame would flip
        -- the target back and forth every time Aurora walks between two foes. That matters far more
        -- than it looks: a switch re-registers the battle group and re-writes the relationship, so
        -- an oscillating target would hammer exactly the STRUCTURE writes behind the three CTDs.
        -- Only look for someone new once the current quarry is actually gone.
        local cur_gone = true
        if lease.target then
            pcall(function() cur_gone = (griffin_target_gone(lease.target) == true) end)
        end
        if cur_gone then
            -- ⛔ same resolution as lease start: never store an EnemyManager list item as the
            -- target, or the next re-kick hands it straight to the relationship registry.
            pcall(function() foe = (iris_real_character and iris_real_character(foe)) or foe end)
            local foe_ctx = false
            pcall(function() foe_ctx = (select(2, route3_ally_group_ctx(foe)) ~= nil) end)
            if not foe_ctx then foe = nil end
        end
        if cur_gone and foe then
            lease.target = foe
            lease.target_go = char_go(foe)
            -- ⭐ A NEW QUARRY IS A NEW ORDER. The old code re-pointed lease.target and stopped
            -- there, so after the first kill hate still sat on a corpse and S.companion_target --
            -- which the damage assist, the HUD, the status line and griffin_attack_assert_hate
            -- itself all read -- still named the dead one. Publish the switch, register properly.
            local addr = nil
            pcall(function() addr = lease.target_go and lease.target_go:get_address() end)
            -- ⛔ SECOND BELT: never re-assert structure faster than the hate beat, whatever the
            -- target does. A guard that depends on one condition holding is a guard that fails.
            if addr and addr ~= lease.target_addr
                and now - (tonumber(lease.assert_at) or -99.0) >= math.max(1.0, tonumber(C.route3_lease_hate_beat) or 2.0) then
                lease.target_addr = addr
                lease.assert_at = now
                lease.switches = (tonumber(lease.switches) or 0) + 1
                S.companion_target = foe
                S.companion_target_go = lease.target_go
                S.route3_attack_battle_reg = nil   -- new body, new battle-group membership
                pcall(function() griffin_attack_assert_hate() end)
                pcall(function() griffin_lease_mark_mutual_damage(gch, go, foe, lease.target_go) end)
                pcall(function() griffin_lease_provoke(gch, go, foe) end)
                lease.hate_at = now
                log.info("[IrisAttack] new quarry: " .. tostring(go_name(lease.target_go) or "?")
                    .. "  trigger=" .. tostring(S.route3_lease_ct or "?"))
            end
        end
    elseif now - (tonumber(lease.last_seen) or now) > (tonumber(C.route3_lease_quiet_secs) or 6.0) then
        return griffin_combat_lease_end("no enemies left")
    end
    -- ⭐ LEASE TELEMETRY, 2s throttle -- and it now runs BEFORE anything we do this tick.
    -- ⛔ It used to sit after the ignition, so `node=` was routinely a readback of a setCurrentNode
    -- we had performed microseconds earlier: the one line that is supposed to answer "is she
    -- fighting NATIVELY" was reporting our own write. Read her first, act second.
    -- ⭐⭐ `clip=` is the INDEPENDENT WITNESS. The FSM node and the un-stick's dwell counter both
    -- read the same getCurrentNodeName, so they cannot cross-check each other -- that is how the
    -- tree ended up with two contradictory theories of the same 71-second episode ("the reading
    -- went stale" vs "she was welded"). The motion layer is a different subsystem: a cycling frame
    -- against a static node = a PAINTED clip over a frozen FSM; a frozen frame = a genuine weld; a
    -- changing bank:id under a static node = the reader really is lying.
    if now >= (tonumber(lease.next_log) or 0.0) then
        lease.next_log = now + 2.0
        local node = "?"
        pcall(function() node = tostring(read_griffin_fsm_node() or "?") end)
        local clip = "?"
        pcall(function()
            local m = gch:call("get_Motion")
            local L = m and m:call("getLayer", 0)
            if not L then return end
            clip = string.format("%s:%s f%.0f/%.0f",
                tostring(L:call("get_MotionBankID")), tostring(L:call("get_MotionID")),
                tonumber(L:call("get_Frame")) or -1, tonumber(L:call("get_EndFrame")) or -1)
        end)
        pcall(function() griffin_ai_state_diag(gch) end)
        local el = tostring(tostring(S.route3_ai_state or ""):match("enemyList=(%-?%d+)") or "?")
        -- surface PUPPET too: it is the brake that was silently on for every run above
        local pup = tostring(tostring(S.route3_ai_state or ""):match("PUPPET=(%a+)") or "?")
        local nav = "?"
        pcall(function()
            local n = get_component and get_component(go, "app.NavigationAI")
            if n then nav = tostring(n:call("get_Enabled")) end
        end)
        local decide = "?"
        pcall(function() decide = tostring(griffin_combat_state_diag(gch) or "?") end)
        log.info(string.format(
            "[IrisAttack] lease %.0fs node=%s clip=%s AI[self=%s other=%s %s] TTYPE[%s hits=%s] grp[hold=%s set=%s] ANGRY[%s] idle=%.1fs kicks=%s switches=%s hate=%s nav=%s puppet=%s enemyList=%s relForced=%s hateBlocks=%s | %s",
            now - (tonumber(lease.started) or now), node, clip,
            tostring(S.route3_lease_ai_self or 0),
            tostring(S.route3_lease_ai_other or 0) .. " me=" .. tostring(S.route3_lease_me or "?"),
            "acts=" .. tostring(S.route3_lease_actions_passed or 0)
                .. " DM[" .. tostring(S.route3_dm_repair or "?")
                .. "] BG[" .. tostring(select(2, griffin_battle_group_status(gch)) or "?")
                .. " foe:" .. tostring(select(2, griffin_battle_group_status(lease.target)) or "?")
                .. "] CSC[" .. tostring(S.route3_csc_repair or "?") .. "]",
            tostring(S.route3_lease_ttype_status or "?"),
            tostring(S.route3_lease_ttype_hits or 0) .. "/" .. tostring(S.route3_lease_ttype_calls or 0),
            tostring(lease.grp_hold or 0), tostring(lease.grp_set or 0),
            tostring(S.route3_angry_status or lease.angry_note or "?"),
            tonumber(lease.idle_shown) or 0.0,
            tostring(lease.kicks or 0), tostring(lease.switches or 0),
            tostring(S.route3_lease_hate_writes or 0), nav, pup, el,
            tostring(S.route3_lease_rel_hits or 0),
            tostring(S.route3_lease_hate_blocks or 0), decide))
    end
    -- ⭐⭐ RE-WIN THE HATE. The ranking DECAYS -- that is the documented half where frequency really
    -- does matter -- so it needs a beat. Hate only: no relationship, no battle-group, no node.
    if now - (tonumber(lease.hate_at) or 0.0) >= math.max(0.5, tonumber(C.route3_lease_hate_beat) or 2.0) then
        lease.hate_at = now
        pcall(function() griffin_lease_hate_beat(gch, go, lease.target, lease.target_go) end)
        -- ⭐ RE-ARM THE TRIGGER. _LastDamageHitObject is a "most recent hit" slot -- anything else
        -- striking either body overwrites it, and a real fight generates those constantly. Re-assert
        -- it on the same slow beat as the hate so a stray hit from a third party cannot quietly
        -- re-point her at something we never ordered.
        pcall(function() griffin_lease_mark_mutual_damage(gch, go, lease.target, lease.target_go) end)
        -- ⭐⭐⭐⭐ AND KEEP HER ANGRY -- but ONLY while she isn't. griffin_lease_make_angry reads
        -- IsAngry first and returns untouched if she already is, so the instant her own AI holds
        -- the anger this stops writing anything at all. Anger has a gauge and a finishAngry, so it
        -- can lapse mid-fight; a beat that only acts on a measured false is the honest way to hold
        -- it without becoming a second driver.
        pcall(function()
            local a = griffin_lease_make_angry(gch)
            lease.angry_note = tostring(a or "?")
        end)
    end
    -- ⭐⭐⭐ THE RE-KICK -- and it is now GATED ON HER, not on a clock (08-15).
    -- ⛔ What was here fired every route3_attack_swing_period seconds unconditionally: a forced
    -- wake with force_action=true (which bypasses the very guard whose comment says it exists so
    -- this "never interrupts her mid-swing") plus griffin_swing_once, i.e. two raw setCurrentNode
    -- slams and a live window whose close re-parked her two frames later. It could not produce
    -- sustained native fighting: anything she started was overwritten within 2.2 seconds.
    -- ⭐ Native means native. Kick ONLY when she is provably parked -- unchanged node and no travel
    -- for route3_lease_idle_secs -- and then only re-latch her combat entry. No force_action, so
    -- griffin_wake_natural_combat's own active_attack/stuck_locomotion guards do their job; no
    -- forced node at all unless route3_lease_force_swing is explicitly turned on.
    local idle_for = griffin_lease_idle_for(lease, go, now)
    lease.idle_shown = idle_for
    if idle_for >= math.max(1.0, tonumber(C.route3_lease_idle_secs) or 4.0)
        and now >= (tonumber(lease.rekick_at) or 0.0) then
        lease.rekick_at = now + math.max(1.0, tonumber(C.route3_lease_rekick_secs) or 6.0)
        lease.kicks = (tonumber(lease.kicks) or 0) + 1
        lease.idle_since = now   -- one kick per parked episode, then watch again
        log.info(string.format("[IrisAttack] re-kick #%d after %.1fs parked in %s | %s",
            tonumber(lease.kicks) or 0, idle_for, tostring(lease.idle_node or "?"),
            tostring(lease.angry_note or "?")))
        -- ⛔ LIVENESS BEFORE THE WAKE (field 08-15 12:16:06): griffin_wake_natural_combat writes the
        -- relationship registry, and firing it at a stale target threw a native exception --
        -- "Exception thrown in REMethodDefinition::invoke for
        --  app.BattleRelationshipHolder.requestSetRelationshipFromTo" -- straight out of re-kick #5.
        -- REFramework caught that one; it is the same registry as the three CTDs, so never hand it
        -- a body that may already be gone.
        local tgt_ok = false
        pcall(function() tgt_ok = (lease.target ~= nil) and (griffin_target_gone(lease.target) ~= true) end)
        if tgt_ok then
            pcall(function() griffin_wake_natural_combat(gch, lease.target, false) end)
            -- ⭐⭐⭐ RE-FORGE THE HIT. A provocation decays -- hate ranks down, the anger gauge
            -- drains, ForceDamageInfo goes stale -- so a companion who was never actually struck
            -- can settle back to idle. This is the right and ONLY place for it: the re-kick is
            -- gated on her being PROVABLY parked (unchanged node + no travel for
            -- route3_lease_idle_secs), so it can never land mid-action. onUnbalance staggers, and
            -- staggering a griffin in the middle of her own attack is exactly the interruption
            -- this whole rewrite exists to stop.
            -- ⛔ FOE SIDE ONLY. Her side carries onUnbalance, and a stagger every re-kick is what
            -- took AI[self] from 19 to 0. Keep re-inviting the foe; never re-stagger her.
            pcall(function() griffin_lease_provoke(gch, go, lease.target, false) end)
            -- ⭐ and re-light it. Idle-gated, so this can only ever land on a body that has been
            -- provably doing nothing for route3_lease_idle_secs -- never mid-swing.
            pcall(function() griffin_lease_real_hit(gch, go, lease.target) end)
        end
        -- ⛔ OFF BY DEFAULT. A forced node is the DRIVEN translator, not native combat, and every
        -- one of them stomps whatever her AI had chosen. Kept only as a fallback lever.
        if C.route3_lease_force_swing == true then
            pcall(function() griffin_swing_once(nil) end)
        end
    end
    return true
end

function griffin_order_attack()
    if C.route3_attack_uses_unleash == true then
        return griffin_unleash()
    end
    if S.mounted == true then status("dismount before ordering an attack"); return false end
    local gch, go = reacquire_griffin()
    if not (gch and go) then status("no companion to command"); return false end
    -- the passive gate, ahead of everything: no target search, no state teardown, no order set.
    if griffin_species_is_passive(go) then
        local nm9 = tostring(C.route3_griffin_name or "This one")
        S.route3_tame_status = nm9 .. " is not a fighter"
        status(S.route3_tame_status)
        return false
    end
    local target = griffin_find_enemy(40.0)
    if not target then
        S.route3_tame_status = "no enemy in range to attack"
        status(S.route3_tame_status)
        return false
    end
    -- ⭐ NATIVE FIRST (08-15): hand her the wild identity + her combat components and let the
    -- engine hunt. The driven strike loop below stays as the fallback for when the lease refuses.
    if C.route3_lease_enabled ~= false and griffin_combat_lease_start(target) then
        return true
    end
    S.companion_order = "attack"
    S.companion_target = target
    S.companion_target_go = char_go(target)
    S.route3_attack_started = os.clock()
    -- hand her body fully back to the game: the follow system's moving flag
    -- makes the onRootApply hook EAT her root motion (walks in place, can't
    -- close on the target), and a live calm burst would pacify her every
    -- half second while the order re-angers her every two
    S.route3_companion_moving = false
    S.route3_follow_running = false
    S.route3_follow_clip = nil
    S.route3_ally_calm_until = 0.0
    -- defensive sweep: ANY stale driver state pins her the same way — an
    -- aborted whistle fly-in or a leftover ride/air snapshot keeps a driver
    -- tick or the root-apply hook owning her body
    S.route3_whistle_flyin = nil
    S.drive_pos = nil
    S.drive_rot = nil
    S.route3_air_pos = nil
    S.route3_air_rot = nil
    S.airborne = false
    S.flying = false
    -- live pin diagnostics for the telemetry line
    S.route3_attack_rootskip0 = tonumber(S.root_apply_blocks) or 0
    S.route3_attack_last_pos = nil
    S.route3_attack_moved = nil
    S.route3_attack_combat_no = nil
    S.route3_attack_rel_hits = 0
    S.route3_attack_rel_native = nil
    S.route3_attack_swing_at = 0.0
    S.route3_attack_hold_until = 0.0
    S.route3_attack_air_at = 0.0
    S.route3_attack_swings = 0
    S.route3_attack_node_index = 0
    S.route3_attack_air_node_index = 0
    S.route3_attack_last_forced_node = nil
    S.route3_attack_running = false
    S.route3_attack_dist = nil
    S.route3_attack_target_hp = nil
    S.route3_attack_damage_status = "damage=ready"
    S.route3_attack_dmg_dealt = 0
    S.route3_natural_damage_status = "assist=ready"
    S.route3_natural_damage_hits = 0
    S.route3_natural_damage_at = 0.0
    S.route3_aerial_attack = nil
    S.route3_aerial_phase = nil
    S.route3_aerial_status = "swoop=ready"
    S.route3_aerial_hits = 0
    S.route3_aerial_dist = nil
    -- DRIVER MODE: FSM LIVE + her action layer SILENCED. The other three
    -- corners all fail: FSM live + actions open = her AI snaps the forced
    -- node back to Wait (round 83); FSM puppeted = setCurrentNode is
    -- ignored entirely, the FSM stops updating (round 84). With actions
    -- blocked the AI has no hands left to grab the wheel.
    restore_disabled()
    set_think_stop(gch, false)
    stop_navigation(gch, true)
    set_motion_fsm_puppet(go, false)
    set_griffin_motion_speed(1.0)
    -- DRIVER-ERA IDENTITY: she fights as a PARTY CITIZEN (kind 2, party
    -- group). The monster-identity swap served the dead tree-cooperation
    -- era and BACKFIRES under the driver at the damage layer: monster-side
    -- hits on a monster target are same-side = friendly-fire filtered to
    -- nothing. Party-side hits damage monsters exactly like a pawn's.
    S.route3_attack_kind_prev = nil
    S.route3_attack_group_swapped = false
    S.route3_attack_battle_reg = nil
    griffin_attack_assert_hate()
    local tname = "(enemy)"
    pcall(function() tname = tostring(go_name(S.companion_target_go) or "(enemy)") end)
    status(tostring(C.route3_griffin_name or "Companion") .. " attacks " .. tname .. "!")
    return true
end
-- ⭐⭐⭐ THE NATIVE-COMBAT PROBE (2026-08-14). ONE QUESTION, ONE NUMBER: does a tamed
-- companion's AI ever classify a nearby enemy as an enemy?
-- `enemyList` = app.AIBlackBoardController.get_EnemyActionTargetList():get_Count(). In July it
-- read 0 with the griffin standing ON a goblin, and that single reading killed the native path
-- and forced the driven "translator" we still use. Aurora's call (08-14): re-test it, because
-- the toolkit has moved a long way since -- the live window (field-proven on the pounce), native
-- predation running on a RIDDEN body, and Bestiary/Puppeteer node firing all postdate that verdict.
-- ⛔ THIS PROBE PREDICTS NOTHING. It opens the live window, hands her brain back, points hate at
-- the nearest real enemy, and then just WATCHES enemyList for a few seconds.
--   enemyList climbs  -> native combat was never dead; the attack command should be native.
--   enemyList stays 0 -> July's wall is real, and we build the driver properly instead of guessing.
-- Safety: the live window carries its own watchdog + close, we restore nothing we did not change,
-- and the probe self-retires. Run it in the field, not in a village.
function griffin_combat_probe_start()
    local gch, go = reacquire_griffin()
    if not (gch and go) then status("no companion out to probe"); return false end
    if S.route3_combat_probe then status("probe already running"); return false end
    -- ⛔⛔ REFUSE ON A PASSIVE SPECIES. 08-14: the first run of this probe was taken with Quoth
    -- the CROW out (ch299410) and duly reported "enemyList NEVER LEFT 0 -- July's wall
    -- reproduces". That reading was worthless: a critter has no combat-targeting AI to begin
    -- with, so it is the one body guaranteed to answer zero whatever the truth is. A probe that
    -- can return a confident false negative is worse than no probe at all -- it would have
    -- retired the native attack path on the strength of a bird.
    -- ⭐ The question is only meaningful on a PREDATOR: wolf, panther, griffin, drake, garm.
    if griffin_species_is_passive(go) then
        local _, band0 = griffin_species_is_passive(go)
        S.route3_combat_probe_verdict =
            "REFUSED: " .. tostring(band0) .. " is a passive species -- probe a predator "
            .. "(wolf/griffin/drake), a critter cannot answer this question"
        status(S.route3_combat_probe_verdict)
        return false
    end
    local target = griffin_find_enemy(40.0)
    if not target then status("probe needs an enemy within 40m"); return false end
    S.companion_target = target
    S.companion_target_go = char_go(target)
    local secs = math.max(2.0, tonumber(C.route3_combat_probe_secs) or 8.0)
    S.route3_combat_probe = {
        started = os.clock(), ends = os.clock() + secs, next_sample = 0.0,
        samples = {}, target_name = tostring(go_name(S.companion_target_go) or "?"),
    }
    -- BEFORE: capture the untouched state so the dump can prove what we changed.
    pcall(function() griffin_ai_state_diag(gch) end)
    S.route3_combat_probe.before = tostring(S.route3_ai_state or "?")
    pcall(function()
        local gctx = route3_ally_group_ctx(gch)
        S.route3_combat_probe.kind = tostring(gctx and gctx:get_field("CharacterKind"))
    end)
    -- Hand the body back: un-park exactly what the mount parks, via the PROVEN window.
    pcall(function() restore_disabled() end)
    pcall(function() set_think_stop(gch, false) end)
    pcall(function() set_motion_fsm_puppet(go, false) end)
    pcall(function() stop_navigation(gch, false) end)
    pcall(function() set_griffin_motion_speed(1.0) end)
    pcall(function() griffin_attack_live_window_open("combat_probe", secs) end)
    -- ⭐⭐⭐ THE ONE NEW VARIABLE: wake AttackNoticeRequester (plus AIDecisionMaker / NavigationAI,
    -- which the probe already woke by other means). The enabled-diff against a live fighting
    -- cyclops named exactly these three as enabled-on-it / disabled-on-us, and AttackNoticeRequester
    -- is the one that stayed FALSE through every run tonight -- restore_disabled only restores what
    -- it personally disabled, and nothing had ever touched this component.
    -- Prior states are kept so the probe puts her back exactly as it found her.
    S.route3_combat_probe.prior_components = griffin_wake_combat_components(true, gch)
    -- ⭐ resetActionAndAI is the ONE lifecycle-reset call in the tree, and July's own notes
    -- record it moving her Locomotion.Wait -> Attack.Attack01 (a bare set_Enabled(true) resumes
    -- update() without re-running awake()/start(), so the combat state machine stays parked).
    -- ⛔ Safe HERE and only here: she is a parked body at this instant, not mid-native-action --
    -- calling it on a body mid-swing is a documented crash class.
    pcall(function() gch:call("resetActionAndAI") end)
    pcall(function() griffin_attack_assert_hate() end)
    status("combat probe: watching enemyList for " .. string.format("%.0f", secs) .. "s")
    return true
end

function griffin_combat_probe_tick()
    local pr = S.route3_combat_probe
    if not pr then return false end
    local now = os.clock()
    local gch, go = reacquire_griffin()
    if not (gch and go) then S.route3_combat_probe = nil; return false end
    -- ⭐⭐⭐ HOLD THE PUPPET OPEN, EVERY FRAME (08-15). The first run released it once at start and
    -- read PUPPET=true in all 30 samples. Cause: `C.puppet_motion_fsm` is TRUE -- the code default
    -- AND Aurora's live config -- and ~19 sites across the tree "restore" a body by writing
    -- `set_motion_fsm_puppet(go, C.puppet_motion_fsm == true)`. The mod's own RESTORE path is
    -- therefore a RE-PUPPET, and a one-shot release loses the race inside a single frame. That is
    -- the same shape as every other tick-war in this codebase: a 1-shot write never beats a
    -- per-frame writer.
    -- ⛔ Deliberately NOT flipping the global config: the ride/mount drive needs the puppet to
    -- steer her body, and turning it off tree-wide would break riding to answer one question. The
    -- probe holds it open for its own window only; the mod's restore sites reclaim it at the end.
    pcall(function() set_motion_fsm_puppet(go, false) end)
    -- ⛔⛔⛔ CALM SUPPRESSION IS NOW OFF BY DEFAULT (08-15, after two CTDs).
    -- Both crashes were the same fault at the same address --
    --   c0000005 app.EnemyManager.updateBattleGroupInfo <- app.EnemyManagerBehavior.update
    -- -- and the ONLY thing common to the crashing runs (and absent from the four clean ones) is
    -- PERSISTENT COMPANION HATE, which is what suppressing the calm burst produces. Run 4 kept the
    -- suppression and survived, so it is intermittent, not deterministic -- which is worse, not
    -- better. ⚠ THE UNCOMFORTABLE POSSIBILITY: the calm burst may be LOAD-BEARING, i.e. it may
    -- exist precisely BECAUSE a tamed body carrying live hate destabilises the battle-group walk.
    -- I had been calling it "our own safety net getting in the way"; that framing is now suspect.
    -- ⇒ The AttackNoticeRequester test below changes exactly ONE thing, so leave this alone.
    if pr.suppress_calm == true then
    -- ⭐⭐⭐ SUPPRESS OUR OWN CALM BURST (08-15). She sees 19 enemies with a free FSM and never
    -- leaves Locomotion.Wait -- so the question moved from "can she see?" to "why does she not
    -- WANT to?", and in DD2 that is the hate ranking.
    -- ⛔ AND OUR OWN CODE IS THE PRIME SUSPECT, for the third time this session:
    -- route3_ally_join_party (probe:5635) arms `route3_ally_calm_until = now + 12s` and calls
    -- clear_griffin_hate(); the calm burst then wipes her hate + targets on a 0.5s beat. It stands
    -- down only for `companion_order == "attack"` or an active unleash (stable.lua:632) -- and the
    -- probe is NEITHER, so it has been erasing the hate we assert, every half second, all along.
    -- griffin_unleash zeroes exactly these two for exactly this reason (probe:7811-7812, "would
    -- stomp our kind-8 back to kind 2 ... she reverts to a peaceful party member and just postures").
    S.route3_ally_calm_until = 0.0
    S.route3_ally_auto_at = 0.0
    end
    -- ⛔⛔⛔ DO NOT CALL griffin_attack_assert_hate() FROM HERE. 2026-08-15: I did, at 60Hz, and
    -- it HARD-CRASHED the game within seconds of pressing the probe next to a cyclops:
    --     c0000005 in app.EnemyManager.updateBattleGroupInfo <- app.EnemyManagerBehavior.update
    --     preceded by repeated app.BattleRelationshipHolder.requestSetBidirectionalRelationship
    --                        / app.BattleRelationshipHolder.requestSetRelationshipFromTo
    -- That function is NOT a cheap hate write -- its own header says it "persist[s] mutual
    -- hostility in the RELATIONSHIP REGISTRY the damage path actually reads" (probe:6404). That
    -- registry is a global engine structure EnemyManagerBehavior.update walks every frame, so
    -- rewriting it 60x/sec is a concurrent modification of a live container. It is called ONCE
    -- per order for a reason.
    -- ⛔ MY MISREADING, RECORDED SO IT IS NOT REPEATED: July's "frequency is everything" law is
    -- about addHateParam + updateHateRanking -- the hate RANKING, which decays and must be
    -- re-won. It is NOT a licence to hammer relationship/battle-group structure. Those are two
    -- different subsystems and only one of them tolerates per-frame writes.
    -- ⭐ The decay question is now answered by MEASUREMENT instead: hateRank is sampled 4x/sec
    -- below, so if hate lands and then decays we will simply watch it happen in the trace --
    -- better science than blindly out-spamming a system we had not identified.
    if now >= (tonumber(pr.next_sample) or 0.0) then
        pr.next_sample = now + 0.25
        -- ⛔⛔ 08-15: THE FIRST VERSION OF THIS READ WAS DEAD CODE AND PRINTED A CONFIDENT LIE.
        -- It called get_component(go, "app.AIBlackBoardController") -- but get_component is NOT
        -- among the names context.lua hands this file (see the import block at the top), so it
        -- resolved to a nil global, threw inside the pcall, and left el at the -1 sentinel on
        -- EVERY sample. peak stayed 0 and the probe reported "enemyList NEVER LEFT 0 -- July's
        -- wall reproduces" while griffin_ai_state_diag, on the very same line, was reading
        -- enemyList=21..35. It nearly retired the native attack path on a measurement of nothing.
        -- ⭐ FIX + LAW: do not re-implement a read that a working function already performs. Parse
        -- the numbers out of the string griffin_ai_state_diag just built -- it lives in the probe
        -- file where those locals are in scope, and it is the one already field-proven.
        pcall(function() griffin_ai_state_diag(gch) end)
        local line = tostring(S.route3_ai_state or "?")
        local el = tonumber(line:match("enemyList=(%-?%d+)") or "") or -1
        local pup = line:match("PUPPET=(%a+)")
        local mv = tonumber(line:match("moved=(%-?%d+)") or "") or 0
        -- ⭐⭐⭐ THE FSM NODE -- the datum this probe should have carried from the start, and the
        -- one July's whole verdict actually rested on ("fsm=Locomotion.Wait"). With the puppet now
        -- released and her STILL standing still, this is the fork:
        --   Locomotion.Wait / an idle node -> her DECISION layer is not choosing to fight
        --   an Attack.* node while moved stays ~0 -> she IS deciding, and MOVEMENT is being eaten
        -- Those need opposite fixes, so measure it rather than argue about it.
        local node = "?"
        pcall(function() node = tostring(read_griffin_fsm_node() or "?") end)
        pr.nodes = pr.nodes or {}
        if not pr.nodes[node] then pr.nodes[node] = 0; pr.node_order = (pr.node_order or 0) + 1 end
        pr.nodes[node] = pr.nodes[node] + 1
        -- ⭐ AND OUR OWN ROOT-MOTION EATER. orders.lua:237 documents it: the onRootApply hook
        -- SKIPs root motion for her body and counts every skip in S.root_apply_blocks. It should
        -- be inert here (its gate needs airborne + seat/proxy, or a live whistle fly-in) -- but
        -- "grep our own safety nets FIRST" is a law paid for with two days on the clearance net,
        -- so we measure the counter instead of assuming.
        local rb = tonumber(S.root_apply_blocks) or 0
        pr.rootblocks0 = pr.rootblocks0 or rb
        pr.rootblocks = rb - pr.rootblocks0
        -- ⭐⭐⭐ THE HATE RANKING -- July's ground truth, and the number 19 rounds never read.
        -- A truly-fighting griffin held 4 ranked hate targets; ours held 0, and "a monster with an
        -- empty ranking has nobody to fight -> it drifts off" (probe:3556-3559). enemyList says
        -- who she COULD fight; this says who she WANTS to. 0 here with 19 in enemyList is the
        -- whole explanation for Locomotion.Wait.
        -- ⛔ character_hate_system is the GLOBAL accessor; griffin_hate_system is a file-local in
        -- the probe and is NOT reachable from here (the same scope trap that made v1 lie).
        local hr = -1
        pcall(function()
            local hs9 = character_hate_system(gch, go)
            if hs9 then hr = tonumber(griffin_hate_rank_count(hs9)) or -1 end
        end)
        pr.peak_hate = math.max(tonumber(pr.peak_hate) or 0, hr)
        -- the combat-entry census (defined in the probe file, where get_component is in scope)
        local entry = "?"
        pcall(function() entry = tostring(griffin_combat_entry_census(gch) or "?") end)
        pr.entry_last = entry
        pr.samples[#pr.samples + 1] = string.format("%.2fs | node=%s hateRank=%d rootSkips=%d | %s | %s",
            now - (tonumber(pr.started) or now), node, hr, pr.rootblocks, entry, line)
        pr.peak_el = math.max(tonumber(pr.peak_el) or 0, el)
        pr.peak_moved = math.max(tonumber(pr.peak_moved) or 0, mv)
        pr.total_moved = (tonumber(pr.total_moved) or 0) + mv
        if pup == "false" then pr.puppet_released = true end
    end
    if now < (tonumber(pr.ends) or 0.0) then return true end
    -- REPORT
    S.route3_combat_probe = nil
    pcall(function() griffin_attack_live_window_close("probe end") end)
    -- put the body back exactly as we found it -- a probe that leaves a companion permanently
    -- combat-woken is no longer a probe, it is an undeclared feature.
    pcall(function() griffin_restore_combat_components(pr.prior_components, gch) end)
    -- ⭐⭐⭐ THE QUESTION MOVED (08-15, first honest run). enemyList is NOT the wall -- a tamed
    -- griffin/drake carries 21-35 entries in it, populated BEFORE we touch anything. She can see
    -- enemies perfectly well. What she does instead is NOTHING: moved=0mm/f with PUPPET=true in
    -- every sample, even though the probe calls set_motion_fsm_puppet(go,false) on the way in.
    -- So the verdict now reports the three facts separately instead of collapsing them into one
    -- misleading yes/no: can she SEE, did the puppet ever RELEASE, and did she MOVE.
    local peak = tonumber(pr.peak_el) or 0
    local moved = tonumber(pr.peak_moved) or 0
    local verdict
    if peak <= 0 then
        verdict = "she never classified an enemy (enemyList 0) -- acquisition IS the wall"
    elseif not pr.puppet_released then
        verdict = string.format(
            "sees %d enemies, but PUPPET never released (peak moved %dmm/f) -- the FREEZE is the wall, not acquisition",
            peak, moved)
    else
        -- name the node she actually SAT in -- the most-sampled one is the honest headline
        local top, topn = "?", -1
        for n9, c9 in pairs(pr.nodes or {}) do
            if c9 > topn then top, topn = n9, c9 end
        end
        local fighting = tostring(top):lower():find("attack", 1, true) ~= nil
        local hate = tonumber(pr.peak_hate) or -1
        if moved < 50 then
            verdict = string.format(
                "sees %d enemies, hateRank %d, STILL DID NOT MOVE -- sat in %s | %s",
                peak, hate, top, tostring(pr.entry_last or "?"))
        elseif not fighting then
            verdict = string.format("sees %d enemies, hateRank %d, never left %s | %s",
                peak, hate, top, tostring(pr.entry_last or "?"))
        else
            verdict = string.format("sees %d enemies, moved %dmm total, node %s -- SHE IS FIGHTING",
                peak, tonumber(pr.total_moved) or 0, top)
        end
    end
    pcall(function()
        json.dump_file(MOD .. "_combat_probe.json", {
            verdict = verdict, peak_enemy_list = peak, peak_moved_mm = moved,
            peak_hate_rank = tonumber(pr.peak_hate) or -1,
            combat_entry = tostring(pr.entry_last or "?"),
            total_moved_mm = tonumber(pr.total_moved) or 0,
            puppet_released = pr.puppet_released == true,
            root_apply_skips = tonumber(pr.rootblocks) or 0,
            nodes_seen = pr.nodes, target = pr.target_name,
            kind_at_start = pr.kind, before = pr.before, samples = pr.samples,
            time = os.date("%H:%M:%S"),
        })
    end)
    log.info("[IrisAttack] combat probe: " .. verdict)
    S.route3_combat_probe_verdict = verdict
    status("combat probe: " .. verdict)
    return true
end

function griffin_order_tick()
    -- FOLLOW / STAY / COME: the companion walks or runs after the player.
    -- Come = follow until arrival, then stay. Orders suspend while mounted.
    if S.world_paused == true then return false end
    -- ⭐⭐⭐ FERAL TEST = HANDS OFF, COMPLETELY (Aurora, 08-15: "surely if we shut everything off
    -- that we use to keep her a passive shell we control, that would return her to a normal
    -- griffin?"). Correct -- and v1 of the toggle did NOT do that. It flipped config flags and
    -- released think-stop/immunity/nav ONCE, while this order tick, the follow driver and the
    -- stable tick all kept running every single frame. Turning off flags is not the same as taking
    -- our hands off her.
    -- ⇒ In feral the entire companion driver stands down. Nothing of ours steers, parks, paces,
    -- pacifies or re-asserts anything. If she still will not fight a goblin with NOTHING of ours
    -- touching her, then the answer is not suppression at all and we stop looking for it there --
    -- which is a real result either way.
    -- ⛔ The lease tick keeps running so its faction/hate-door protection and its stop/restore
    -- still work; the DRIVING is what stands down.
    if rawget(_G, "IrisFeralTest") == true then
        pcall(griffin_combat_lease_tick)
        return true
    end
    -- the probe owns nothing and blocks nothing; it just watches while whatever else runs.
    pcall(griffin_combat_probe_tick)
    pcall(griffin_combat_lease_tick)
    -- EAT THAT command owns her while active (flight -> pounce -> feed); suspends orders -- but
    -- not against an explicit order or the player leaving. Ending it here rather than returning
    -- means she picks the new order up in this same tick, instead of standing still for a frame.
    if griffin_eat_active() then
        local cut = griffin_eat_interrupt_reason()
        if cut then griffin_eat_end(cut) else return griffin_eat_tick() end
    end
    -- UNLEASHED: her native combat AI drives. We only MONITOR — re-point her
    -- at a fresh foe when one dies, keep the player/party friend-shield fresh,
    -- and auto-recall if she runs out of enemies or the timer expires.
    if S.route3_unleashed == true then
        if S.mounted == true then griffin_recall(); return true end
        -- GLOBAL BACKSTOP: never stay unleashed forever. A target can despawn without a
        -- death signal, and other edge cases could strand her -- this hard cap on the
        -- whole command guarantees she always comes home. (Ordered-attack has a 90s cap.)
        if os.clock() - (tonumber(S.route3_unleash_started) or os.clock()) > (tonumber(C.route3_unleash_max_duration) or 120.0) then
            griffin_recall(); return true
        end
        -- APPROACH PHASE: fly her in to the target before native combat lights up.
        if S.route3_unleash_phase == "approach" then
            local at = S.companion_target
            if griffin_target_gone(at) then
                -- target gone mid-flight: pick the next, else stand down
                local nxt = griffin_find_prey_or_enemy(60.0)
                if nxt then
                    S.companion_target = nxt
                    S.companion_target_go = char_go(nxt)
                    S.route3_unleash_approach = { last_tick = os.clock() }
                    S.route3_unleash_empty_since = nil
                else
                    S.route3_unleash_empty_since = S.route3_unleash_empty_since or os.clock()
                    if os.clock() - S.route3_unleash_empty_since > 4.0 then griffin_recall(); return true end
                    return true
                end
            end
            S.route3_unleash_empty_since = nil
            pcall(function() set_griffin_puppet(true) end)   -- hold her drivable
            pcall(function() griffin_ai_state_diag(reacquire_griffin()) end)
            pcall(function() griffin_unleash_approach_tick() end)
            return true
        end
        -- RE-APPROACH: the target ran out of reach -> fly back after it (native AI
        -- won't chase). Use HORIZONTAL distance only: her OWN native combat lifts her
        -- vertically off the target (dive/gale), and a 3D metric would cross the 16m
        -- line straight up, flip to approach, then arrival (horizontal ~0) would
        -- instantly re-enter combat + resetActionAndAI on a mid-action body = crash.
        -- And ONLY flip while she is IDLE (not mid native attack): the flip re-pacifies,
        -- which toggles the FSM puppet on -- doing that mid-native-action is a crash class.
        pcall(function()
            local _, rgo = reacquire_griffin()
            local rtgo = S.companion_target_go or (S.companion_target and char_go(S.companion_target))
            local rgp = rgo and transform_pos(rgo)
            local rtp = rtgo and transform_pos(rtgo)
            if rgp and rtp then
                local dxh = (tonumber(rtp.x) or 0.0) - (tonumber(rgp.x) or 0.0)
                local dzh = (tonumber(rtp.z) or 0.0) - (tonumber(rgp.z) or 0.0)
                local dd = math.sqrt(dxh * dxh + dzh * dzh)
                pcall(function() read_griffin_fsm_node() end)
                local rfsm = tostring(S.last_fsm_node or ""):lower()
                local attacking = rfsm:find("attack", 1, true) or rfsm:find("gale", 1, true)
                    or rfsm:find("rush", 1, true) or rfsm:find("damage", 1, true)
                    or rfsm:find("catch", 1, true) or rfsm:find("stomp", 1, true)
                if dd > (tonumber(C.route3_unleash_reapproach) or 16.0) and not attacking then
                    S.route3_unleash_far_since = S.route3_unleash_far_since or os.clock()
                    if os.clock() - S.route3_unleash_far_since > 1.5 then
                        S.route3_unleash_phase = "approach"
                        S.route3_unleash_approach = { last_tick = os.clock(), t0 = os.clock() }
                        S.route3_unleash_far_since = nil
                    end
                else
                    S.route3_unleash_far_since = nil
                end
            end
        end)
        if S.route3_unleash_phase == "approach" then return true end   -- flipped back to fly-in
        local now = os.clock()
        -- PER-FRAME dead/despawned guard: run BEFORE any hate/provoke so we never fire
        -- native calls on a dangling target (destroyed GO = AV class). Retarget or recall.
        if griffin_target_gone(S.companion_target) then
            local nxt = griffin_find_prey_or_enemy(tonumber(C.route3_unleash_retarget_radius) or 35.0)
            if nxt then
                S.companion_target = nxt
                S.companion_target_go = char_go(nxt)
                S.route3_unleash_empty_since = nil
                -- set the new foe up fully now (no ≤1s gap where she has a target but
                -- no enemy-relationship): mark enemy + register + point hate
                local rgch = reacquire_griffin()
                pcall(function() griffin_set_relationship(rgch, nxt, "enemy", true) end)
                pcall(function() griffin_unleash_register_battle(rgch, nxt) end)
                pcall(function() griffin_unleash_point_hate() end)
            else
                S.route3_unleash_empty_since = S.route3_unleash_empty_since or now
                if now - S.route3_unleash_empty_since > 4.0 then griffin_recall(); return true end
                return true   -- no live target this frame: skip all native combat calls
            end
        end
        -- PER-FRAME (RiftSpeak [FOCUS] lesson): hate dominance must be re-asserted
        -- EVERY FRAME or the ~60Hz AI re-rank out-competes our 1Hz write and the
        -- target decays away. THIS is the target driver now (not the 1s beat).
        -- FOCUS-HATE (re-enabled): keeps the goblin her top hate so she stays locked
        -- on it now that the faction fix lets her see it as an enemy at all.
        pcall(function() griffin_focus_hate_tick() end)
        -- EVERY-FRAME UN-FREEZE (Aurora 2026-07-05: FSM reads Attack.Attack01 but she
        -- stands COMPLETELY frozen -> something re-freezes her between the 1s beats).
        -- The un-puppet / un-think-stop / full play-speed / nav-free only ran in the 1s
        -- beat, so a per-frame re-puppet or motion-speed-0 wins 59 frames out of 60 and
        -- locks her animation. Re-assert them EVERY frame while unleashed so nothing can
        -- win that race. (Same safe calls unleash already makes, just at frame rate.)
        pcall(function()
            local ugch, ugo = reacquire_griffin()
            if ugch and ugo then
                set_think_stop(ugch, false)
                set_motion_fsm_puppet(ugo, false)
                set_griffin_motion_speed(1.0)
                stop_navigation(ugch, false)
            end
        end)
        -- (native aggro-bait REMOVED: making the goblin hit her only kicked her into a
        -- frozen retaliation windup -- native combat never executes on a tamed body)
        pcall(function() griffin_ai_state_diag(reacquire_griffin()) end)
        if now - (tonumber(S.route3_unleash_beat) or 0.0) > 1.0 then
            S.route3_unleash_beat = now
            pcall(function() read_griffin_fsm_node() end)
            local tgt = S.companion_target
            if griffin_target_gone(tgt) then
                -- current prey down or despawned: find the next, else stand down
                local nxt = griffin_find_prey_or_enemy(tonumber(C.route3_unleash_retarget_radius) or 35.0)
                if nxt then
                    S.companion_target = nxt
                    S.companion_target_go = char_go(nxt)
                    local gch = reacquire_griffin()
                    pcall(function() griffin_set_relationship(gch, nxt, "enemy", true) end)
                    pcall(function() griffin_unleash_register_battle(gch, nxt) end)
                    pcall(function() griffin_unleash_point_hate() end)
                    S.route3_unleash_empty_since = nil
                else
                    -- no enemies for a grace period → auto-recall
                    S.route3_unleash_empty_since = S.route3_unleash_empty_since or now
                    if now - S.route3_unleash_empty_since > 4.0 then
                        griffin_recall()
                        return true
                    end
                end
            else
                S.route3_unleash_empty_since = nil
                -- keep battle-group bookkeeping fresh. NO point_hate / wake / provoke /
                -- nav-push / AI-reenable here: native combat is DEAD on a tamed body and
                -- all of it only jammed her into a frozen attack windup. The driven
                -- strike loop (griffin_unleash_combat_strike_tick) is the entire fight.
                local gch = reacquire_griffin()
                pcall(function() griffin_unleash_register_battle(gch, tgt) end)
                -- just keep her un-suppressed so our strike clips play
                pcall(function()
                    set_think_stop(gch, false)
                    set_motion_fsm_puppet(char_go(gch), false)
                    stop_navigation(gch, false)
                end)
                -- DIAGNOSTIC: the ACTUAL bodies + positions. The earlier 15m reading
                -- was bogus while she stood ON the goblin -- I need to see whether
                -- reacquire_griffin is even the body fighting, and the REAL distance.
                pcall(function()
                    local ggo3, tgo3 = char_go(gch), char_go(tgt)
                    local gp = ggo3 and transform_pos(ggo3)
                    local tp = tgo3 and transform_pos(tgo3)
                    local gn = tostring(go_name(ggo3) or "?")
                    local tn2 = tostring(go_name(tgo3) or "?")
                    if gp and tp then
                        local d2 = distance_sq(gp, tp)
                        local d = d2 and math.sqrt(d2) or -1
                        S.route3_unleash_dist = math.floor(d * 10) / 10
                        S.route3_unleash_diag = string.format("me=%s(%.0f,%.0f,%.0f)  tgt=%s(%.0f,%.0f,%.0f)",
                            gn:sub(1, 12), tonumber(gp.x) or 0, tonumber(gp.y) or 0, tonumber(gp.z) or 0,
                            tn2:sub(1, 12), tonumber(tp.x) or 0, tonumber(tp.y) or 0, tonumber(tp.z) or 0)
                    end
                end)
                -- SEAT DISABLED: the REAL gap is FACTION -- griffin & goblin share
                -- group 1895570358 (= allies), fixed above by copying her onto the
                -- party group. With a different faction her NATURAL updateEnemyTargetList
                -- populates the enemy list, so no risky manual seat (which failed on the
                -- List<GameObject> construction anyway).
                -- pcall(function() griffin_seat_enemy_target(gch, tgt) end)
            end
            -- keep the player/party friend-shield asserted (a new pawn or a
            -- relationship decay could otherwise expose you to a kind-8 her)
            local gch = reacquire_griffin()
            pcall(function() griffin_set_relationship(gch, get_player(), "friend", true) end)
            -- RE-ASSERT kind 8: her monster combat AI only runs at kind 8, and
            -- background systems keep trying to restore kind 2 (= she reverts
            -- to a posturing party member). Hold the monster identity.
            pcall(function()
                local hctx, ggc = route3_ally_group_ctx(gch)
                if hctx and tonumber(hctx:get_field("CharacterKind")) ~= 8 then
                    hctx:set_field("CharacterKind", 8)
                    S.route3_unleash_kind_reverts = (tonumber(S.route3_unleash_kind_reverts) or 0) + 1
                end
                -- hold the PLAYER faction every beat (engine reverts it) so the goblin
                -- stays a perceived cross-faction enemy and she can't aggro you
                local cur = griffin_group_hash_value(hctx, ggc)
                if ggc and cur ~= 2385506540 then
                    local _, sgc = route3_ally_group_ctx(get_player())
                    if sgc then
                        for _, f in ipairs({ "GroupHash", "DefaultGroupHash" }) do
                            local srcbox = nil
                            pcall(function() srcbox = sgc:get_field(f) end)
                            if srcbox then pcall(function() ggc:set_field(f, srcbox) end) end
                        end
                    end
                    S.route3_unleash_group_reverts = (tonumber(S.route3_unleash_group_reverts) or 0) + 1
                end
            end)
        end
        -- guaranteed non-null result: if native won't swing at point-blank, force
        -- her real strike clip + land damage (backs up the native combat handoff)
        pcall(function() griffin_unleash_combat_strike_tick() end)
        pcall(function() griffin_natural_damage_assist_tick() end)
        return true
    end
    local order = S.companion_order
    if order == "attack" then
        -- ⛔⛔ THE LEASE OWNS HER -- the native AI is driving, so this DRIVEN strike loop must not
        -- also run. Two writers on one body is the exact collision behind every crash tonight, and
        -- here it would be a scripted clip fighting a live combat FSM.
        -- ⭐ The order deliberately STAYS "attack": that is what stands the calm burst down
        -- (stable.lua:632, so her hate survives the fight) and what routes the Stay button into
        -- griffin_order_disengage -- i.e. it is what makes Aurora's "stop command" work at all.
        -- Only the driving is suppressed.
        if griffin_combat_lease_active() then return true end
        if S.mounted == true then griffin_order_disengage("rider mounted"); return true end
        local tgt = S.companion_target
        if not tgt or griffin_target_is_dead(tgt) then
            griffin_order_disengage(tgt and "target slain" or "target lost")
            return true
        end
        if os.clock() - (tonumber(S.route3_attack_started) or 0.0) > 90.0 then
            griffin_order_disengage("long enough")
            return true
        end
        -- keep the fury pointed at the ordered target
        if os.clock() - (tonumber(S.route3_attack_hate_at) or 0.0) > 2.0 then
            S.route3_attack_hate_at = os.clock()
            griffin_attack_assert_hate()
            read_griffin_fsm_node()
            -- pin diagnostics: who is holding her? rootskip counts OUR
            -- root-motion hook eating frames; moved = metres this beat;
            -- cstate = her CombatStatusFlag (0 = tree never committed)
            pcall(function()
                local csc = nil
                pcall(function() csc = S.griffin and S.griffin:get_field("<CombatStateControl>k__BackingField") end)
                if not csc then pcall(function() csc = S.griffin and S.griffin:call("get_CombatStateControl") end) end
                local flag = csc and csc:get_field("<CombatStatusFlag>k__BackingField")
                if flag then S.route3_attack_combat_no = tostring(flag:get_field("Data")) end
            end)
            -- is a REAL action object live in her slot after our request, or
            -- did only the motion play? "Invalid" = no action logic = no
            -- hit windows — that distinction picks the next lever
            pcall(function()
                local am = griffin_action_manager()
                local lst = am and am:get_field("CurrentActionList")
                local a0 = lst and lst:call("get_Item", 0)
                S.route3_attack_live_action = a0 and tostring(a0:call("ToString()")) or "nil"
            end)
            pcall(function() S.route3_attack_target_hp = griffin_read_target_hp(S.companion_target) end)
        end
        -- MANUAL COMBAT DRIVER: six rounds proved her decision tree will not
        -- volunteer (registration, hate, kind, group identity, forced
        -- relationship — cstate never left 0, relationship never queried).
        -- So we drive: the proven follow stepper walks her to the TARGET,
        -- and in strike range we force the real attack node on a beat —
        -- authored hitboxes, real damage, no cooperation required.
        local agch, ago = reacquire_griffin()
        if not (agch and ago) then return true end
        local tgo = S.companion_target_go or char_go(tgt)
        local agpos = transform_pos(ago)
        local tpos = tgo and transform_pos(tgo)
        if not (agpos and tpos) then return true end
        local adx = (tonumber(tpos.x) or 0.0) - (tonumber(agpos.x) or 0.0)
        local adz = (tonumber(tpos.z) or 0.0) - (tonumber(agpos.z) or 0.0)
        local adist = math.sqrt(adx * adx + adz * adz)
        S.route3_attack_dist = math.floor(adist * 10) / 10
        local strike = math.max(1.2, tonumber(C.route3_attack_strike_range) or 2.0)
        local assist_range = math.max(strike, tonumber(C.route3_natural_damage_range) or strike)
        local attack_hold = os.clock() < (tonumber(S.route3_attack_hold_until) or 0.0)
        if route3_aerial_attack_tick(agch, ago, tgt, tgo, agpos, tpos, adist) == true then
            return true
        end
        if adist > strike and not attack_hold then
            -- approach (gait hysteresis so the run clip doesn't stutter)
            local run = S.route3_attack_running == true
            if run then
                if adist < strike + 2.0 then run = false end
            else
                if adist > strike + 5.0 then run = true end
            end
            S.route3_attack_running = run
            local ivspd9 = 1.0   -- 08-12: the SPD gene is real legs in the attack chase too
            pcall(function()
                local st9 = _G.IrisIVState
                if st9 and tonumber(st9.spd) then ivspd9 = tonumber(st9.spd) end
            end)
            local step = math.min(adist - strike * 0.5,
                (run and (tonumber(C.route3_follow_run_step) or 0.14) or (tonumber(C.route3_follow_walk_step) or 0.06)) * ivspd9)
            local nx = (tonumber(agpos.x) or 0.0) + adx / adist * step
            local nz = (tonumber(agpos.z) or 0.0) + adz / adist * step
            local ny = tonumber(agpos.y) or 0.0
            pcall(function()
                local rp = transform_render_pos(ago)
                if rp then
                    local hit = route3_cast_ground_below(
                        (tonumber(rp.x) or 0.0) + adx / adist * step,
                        tonumber(agpos.y) or 0.0,
                        (tonumber(rp.z) or 0.0) + adz / adist * step,
                        4.0, 8.0
                    )
                    if hit and tonumber(hit.y) then
                        ny = tonumber(hit.y) + (tonumber(C.route3_ground_follow_offset) or 0.0)
                    end
                end
            end)
            local arot = make_quat_yaw(math.atan(adx, adz))
            local apos = make_position(nx, ny, nz)
            pcall(function() set_transform(ago, apos, arot) end)
            pcall(function() set_character_transform(agch, apos, arot) end)
            S.route3_companion_moving = true
            local clip = run and (tonumber(C.root_motion_run) or 200) or (tonumber(C.root_motion_walk) or 100)
            if S.route3_follow_clip ~= clip then
                S.route3_follow_clip = clip
                S.route3_follow_clip_at = os.clock()
                play_griffin_motion(clip, tonumber(C.root_motion_walk_bank) or 0, true)
            elseif route3_flap_layer_clip() ~= clip
                and (os.clock() - (tonumber(S.route3_follow_clip_at) or 0.0)) > 1.0 then
                S.route3_follow_clip_at = os.clock()
                play_griffin_motion(clip, tonumber(C.root_motion_walk_bank) or 0, true)
            end
            local since_air = os.clock() - (tonumber(S.route3_attack_air_at) or 0.0)
            local period = math.max(1.0, tonumber(C.route3_attack_swing_period) or 4.0)
            if adist > strike + 8.0 and since_air > period then
                S.route3_attack_air_at = os.clock()
                local air_node = griffin_attack_next_air_node()
                if air_node then
                    griffin_swing_once(air_node)
                    S.route3_attack_hold_until = os.clock() + math.max(0.6, tonumber(C.route3_attack_commit_seconds) or 1.25)
                end
            end
        else
            -- in strike range: her body is the game's again (the attack node
            -- carries its own root motion), face the prey, swing on the beat
            if S.route3_companion_moving == true then
                S.route3_companion_moving = false
                S.route3_follow_clip = nil
                S.route3_attack_running = false
                stop_griffin_animation()
            end
            local arot = make_quat_yaw(math.atan(adx, adz))
            pcall(function() set_transform(ago, agpos, arot) end)
            -- CHAIN the swings: re-swing the moment the previous attack action
            -- finishes (slot empties) rather than idling a fixed 4s — a single
            -- swing every 4s read as "refusing". A hard ceiling is the safety
            -- net if the slot read fails. Short debounce so we never spam
            -- mid-animation.
            local since = os.clock() - (tonumber(S.route3_attack_swing_at) or 0.0)
            pcall(function()
                local am = griffin_action_manager()
                local lst = am and am:get_field("CurrentActionList")
                local a0 = lst and lst:call("get_Item", 0)
                S.route3_attack_live_action = a0 and tostring(a0:call("ToString()")) or "nil"
            end)
            local slot = tostring(S.route3_attack_live_action or "")
            local action_done = slot == "" or slot == "nil" or slot:find("Invalid", 1, true) ~= nil
            local period = tonumber(C.route3_attack_swing_period) or 4.0
            if since > math.min(period, 1.2) and (action_done or since > period) then
                S.route3_attack_swing_at = os.clock()
                S.route3_attack_hold_until = os.clock() + math.max(0.6, tonumber(C.route3_attack_commit_seconds) or 1.25)
                griffin_swing_once(nil)
                -- DIRECT DAMAGE: her real attack animation plays, and since
                -- her shrunk colliders never connect, we drain the target's
                -- HP ourselves on each swing (she IS in strike range here)
                if C.route3_attack_direct_damage ~= false and adist <= assist_range then
                    pcall(function() griffin_apply_damage_to_target(C.route3_attack_damage_per_hit or 60.0) end)
                end
                -- refresh the slot read immediately so the next tick sees the
                -- new action and doesn't double-fire
                pcall(function()
                    local am = griffin_action_manager()
                    local lst = am and am:get_field("CurrentActionList")
                    local a0 = lst and lst:call("get_Item", 0)
                    S.route3_attack_live_action = a0 and tostring(a0:call("ToString()")) or "nil"
                end)
            end
            if C.route3_attack_direct_damage ~= false then
                pcall(function() griffin_natural_damage_assist_tick() end)
            end
        end
        return true
    end
    if S.route3_aerial_attack then route3_aerial_attack_clear("swoop=cancelled") end
    if order ~= "follow" and order ~= "come" then S.route3_companion_moving = false; return false end
    if S.mounted == true or S.route3_whistle_flyin then S.route3_companion_moving = false; return false end
    local gch, go = reacquire_griffin()
    if not (gch and go) then S.route3_companion_moving = false; return false end
    if S.airborne == true then return false end
    local pgo = char_go(get_player())
    local ppos = pgo and transform_pos(pgo)
    local gpos = transform_pos(go)
    if not (ppos and gpos) then return false end

    local dx = (tonumber(ppos.x) or 0.0) - (tonumber(gpos.x) or 0.0)
    local dz = (tonumber(ppos.z) or 0.0) - (tonumber(gpos.z) or 0.0)
    local dist = math.sqrt(dx * dx + dz * dz)
    local gap = math.max(2.0, tonumber(C.route3_follow_gap) or 5.0)
    if dist <= gap then
        if S.route3_companion_moving == true then
            S.route3_companion_moving = false
            S.route3_follow_clip = nil
            S.route3_follow_running = false
            stop_griffin_animation()
            if order == "come" then
                S.companion_order = "stay"
                status(tostring(C.route3_griffin_name or "Companion") .. " is here")
            end
        end
        return true
    end

    -- gait hysteresis: start running past run_at, keep running until well
    -- inside it — otherwise the gait flaps at the boundary and the run clip
    -- restarts every few frames (the stutter)
    local run_at = tonumber(C.route3_follow_run_at) or 14.0
    local run = S.route3_follow_running == true
    if run then
        if dist < run_at - 4.0 then run = false end
    else
        if dist > run_at then run = true end
    end
    S.route3_follow_running = run
    local ivspd9 = 1.0   -- 08-12: the SPD gene is real legs in the follow -- a fast
    pcall(function()     -- bloodline visibly keeps up, a slow one plods
        local st9 = _G.IrisIVState
        if st9 and tonumber(st9.spd) then ivspd9 = tonumber(st9.spd) end
    end)
    local step = math.min(dist - gap * 0.5,
        (run and (tonumber(C.route3_follow_run_step) or 0.14) or (tonumber(C.route3_follow_walk_step) or 0.06)) * ivspd9)
    local nx = (tonumber(gpos.x) or 0.0) + dx / dist * step
    local nz = (tonumber(gpos.z) or 0.0) + dz / dist * step
    local ny = tonumber(gpos.y) or 0.0
    pcall(function()
        local rp = transform_render_pos(go)
        if rp then
            local hit = route3_cast_ground_below(
                (tonumber(rp.x) or 0.0) + dx / dist * step,
                tonumber(gpos.y) or 0.0,
                (tonumber(rp.z) or 0.0) + dz / dist * step,
                4.0, 8.0
            )
            if hit and tonumber(hit.y) then
                ny = tonumber(hit.y) + (tonumber(C.route3_ground_follow_offset) or 0.0)
            end
        end
    end)

    -- stuck on scenery? cheat gracefully: a flier takes wing to you (the
    -- whistle approach), a ground mount quietly catches up
    local moved = 0.0
    if S.route3_follow_last_pos then
        moved = math.sqrt(math.max(0.0, distance_sq(gpos, S.route3_follow_last_pos) or 0.0))
    end
    S.route3_follow_last_pos = make_position(tonumber(gpos.x) or 0.0, tonumber(gpos.y) or 0.0, tonumber(gpos.z) or 0.0)
    if moved < step * 0.25 and S.route3_companion_moving == true then
        S.route3_follow_stuck_t = (tonumber(S.route3_follow_stuck_t) or 0.0) + 0.016
        if S.route3_follow_stuck_t > 2.5 then
            S.route3_follow_stuck_t = 0.0
            S.route3_companion_moving = false
            S.route3_follow_clip = nil
            if C.route3_allow_flight == true and route3_whistle_flyin_start() then
                status(tostring(C.route3_griffin_name or "Companion") .. " takes wing to reach you")
            else
                local catch = route3_find_safe_stable_spawn(gap + 1.0)
                if catch then
                    pcall(function() set_transform(go, catch, nil) end)
                    pcall(function() set_character_transform(gch, catch, nil) end)
                end
            end
            return true
        end
    else
        S.route3_follow_stuck_t = 0.0
    end

    local rot = make_quat_yaw(math.atan(dx, dz))
    local pos = make_position(nx, ny, nz)
    pcall(function() set_transform(go, pos, rot) end)
    pcall(function() set_character_transform(gch, pos, rot) end)
    S.route3_companion_moving = true

    local clip = run and (tonumber(C.root_motion_run) or 200) or (tonumber(C.root_motion_walk) or 100)
    if S.route3_follow_clip ~= clip then
        -- gait changed: switch the clip
        S.route3_follow_clip = clip
        S.route3_follow_clip_at = os.clock()
        play_griffin_motion(clip, tonumber(C.root_motion_walk_bank) or 0, true)
    elseif route3_flap_layer_clip() ~= clip
        and (os.clock() - (tonumber(S.route3_follow_clip_at) or 0.0)) > 1.0 then
        -- something else stole the layer: re-assert, but never more than 1/s
        S.route3_follow_clip_at = os.clock()
        play_griffin_motion(clip, tonumber(C.root_motion_walk_bank) or 0, true)
    end
    return true
end
function route3_whistle_tick()
    -- Zelda-style whistle: G brings your griffin to you (or summons a new one)
    if S.world_paused == true then return false end
    local down = false
    pcall(function() down = iris_kb(math.floor(tonumber(C.route3_whistle_key) or 71)) end)
    local pressed = down and S.route3_whistle_prev ~= true
    S.route3_whistle_prev = down
    if not pressed then return false end
    -- also refuse while CLIMBING a body: the whistle teleports + pacifies the very body
    -- you're clinging to -> the "beyblade" spin. Only whistle when free-standing.
    if S.mounted == true or S.player_climb_on_character == true or S.route3_whistle_flyin or griffin_eat_active() then return false end
    -- refuse until the world and the stable are fully awake: whistling into
    -- the wake-up window was a crash (scans/registration on a fragile state)
    if S.route3_stable == nil or not S.route3_world_ready_since
        or (os.clock() - (tonumber(S.route3_world_ready_since) or 0.0)) < 5.0 then
        status("(still waking up - try the whistle again in a few seconds)")
        return false
    end
    local name = tostring(C.route3_griffin_name or "Griffin")
    local gch = S.griffin
    local go = gch and char_go(gch) or nil
    if gch and go then
        if C.route3_whistle_flyin == true and route3_whistle_flyin_start() then return true end
        local pos, rot, detail = route3_find_safe_stable_spawn(C.route3_stable_spawn_distance)
        if pos then
            pcall(function() set_transform(go, pos, rot) end)
            pcall(function() set_character_transform(gch, pos, rot) end)
            stop_navigation(gch, true)
            pacify_griffin(nil)
            status(name .. " answers your whistle (" .. tostring(detail or "safe floor") .. ")")
        else
            status(name .. " cannot find safe floor nearby")
            return false
        end
    else
        -- impatience-proof: before summoning a NEW body, check whether the
        -- companion is already standing somewhere nearby (post-reset body)
        local rec = S.route3_tamed_record
        local whistle_guid = rec and tostring(rec.guid or ""):find("@", 1, true) and tostring(rec.guid) or nil
        local prefix = whistle_guid or (rec and tostring(rec.species or ""):match("ch%d+")) or nil
        local scan_note = "(no soul)"
        if prefix then
            local old_prefix = C.route3_tame_prefix
            C.route3_tame_prefix = prefix
            local body, info = griffin_find_wild(80.0)
            C.route3_tame_prefix = old_prefix
            scan_note = tostring(info or "?")
            -- species-prefix matches must still carry our ally context —
            -- never reconnect to a live WILD twin (see the reclaim guard)
            if body and not whistle_guid and not griffin_body_is_ours(body) then
                scan_note = scan_note .. " [wild twin - not ours]"
                body = nil
            end
            if body then
                -- gentle two-step: this G reconnects her; the NEXT G (or a
                -- walk over) does the fly-in — no violent same-frame combo
                register_griffin(body)
                S.route3_tamed_species = tostring(rec.species or "")
                griffin_species_profile_apply(S.route3_tamed_species)
                status(name .. " remembers you - whistle again to call them over")
                return true
            end
        end
        -- the scan failed: NEVER mint a body on the first whistle — surface
        -- what the scan saw (and write it to disk for offline diagnosis)
        -- and require a confirming second whistle
        if (tonumber(S.route3_whistle_confirm_until) or 0.0) < os.clock() then
            S.route3_whistle_confirm_until = os.clock() + 10.0
            S.route3_tame_status = "can't sense " .. name .. " nearby [" .. scan_note .. "]"
            pcall(function()
                -- name+KIND of every nearby body sharing the species prefix:
                -- distinguishes "body genuinely gone" from "body present but
                -- rejected" (guid mismatch + CharacterKind != 2). This is the
                -- data that pins a post-reset double-summon.
                local sp = tostring(rec and rec.species or ""):match("ch%d+") or ""
                local near = {}
                pcall(function()
                    local pgo = char_go(get_player())
                    local ppos = pgo and transform_pos(pgo)
                    local scene_mgr = sdk.get_native_singleton("via.SceneManager")
                    local scene_td = sdk.find_type_definition("via.SceneManager")
                    local scene = scene_mgr and sdk.call_native_func(scene_mgr, scene_td, "get_CurrentScene")
                    local comps = scene and scene:call("findComponents(System.Type)", sdk.typeof("app.Character"))
                    for _, comp in ipairs(system_array_to_table(comps) or {}) do
                        pcall(function()
                            local nm = tostring(go_name(char_go(comp)) or "")
                            if sp ~= "" and nm:find(sp, 1, true) then
                                local kind = "?"
                                pcall(function()
                                    local hctx = route3_ally_group_ctx(comp)
                                    kind = tostring(hctx and hctx:get_field("CharacterKind"))
                                end)
                                local d = (ppos and transform_pos(char_go(comp))) and math.floor(math.sqrt(distance_sq(transform_pos(char_go(comp)), ppos) or 0) * 10) / 10 or "?"
                                near[#near + 1] = { name = nm, kind = kind, dist = d, is_ours = griffin_body_is_ours(comp) }
                            end
                        end)
                    end
                end)
                json.dump_file(MOD .. "_whistle_scan.json", {
                    time = os.date("%H:%M:%S"),
                    looking_for = prefix,
                    guid_wanted = tostring(rec and rec.guid or "(none)"),
                    result = scan_note,
                    names_seen = S.route3_find_debug,
                    nearby_same_species = near,
                })
            end)
            status(S.route3_tame_status .. " - whistle again to summon a new body")
            return true
        end
        S.route3_whistle_confirm_until = 0.0
        S.route3_spawn_request = true
        status(name .. " is coming")
    end
    return true
end
function route3_ground_follow_tick(go)
    if S.route3_ground_jump_active == true then return false end
    if C.route3_ground_follow_enabled ~= true or S.airborne == true then
        S.last_route3_ground_follow = "(disabled)"
        S.last_route3_ground_delta = 0.0
        return false
    end
    local upos = transform_pos(go)
    local rpos = transform_render_pos(go)
    if not (upos and rpos) then
        S.last_route3_ground_follow = "no position"
        S.last_route3_ground_delta = 0.0
        return false
    end
    local hit = route3_cast_ground_below(
        tonumber(rpos.x) or 0.0,
        tonumber(upos.y) or 0.0,   -- cast_ground_below speaks UNIVERSAL y now (converts internally)
        tonumber(rpos.z) or 0.0,
        tonumber(C.route3_ground_follow_up) or 2.5,
        tonumber(C.route3_ground_follow_down) or 8.0
    )
    if not hit then
        S.last_route3_ground_follow = "miss"
        S.last_route3_ground_delta = 0.0
        return false
    end

    local desired = ((tonumber(hit.y) or tonumber(upos.y) or 0.0) + (tonumber(C.route3_ground_follow_offset) or 0.0))
        - (tonumber(upos.y) or 0.0)
    local max_adjust = math.max(0.0, tonumber(C.route3_ground_follow_max_adjust) or 0.35)
    local adjust = math.max(-max_adjust, math.min(max_adjust, desired))
    S.last_route3_ground_delta = adjust
    if math.abs(adjust) < 0.01 then
        S.last_route3_ground_follow = "grounded"
        S.route3_last_safe_pos = make_position(
            tonumber(upos.x) or 0.0,
            tonumber(upos.y) or 0.0,
            tonumber(upos.z) or 0.0
        )
        S.route3_last_safe_rot = transform_rot(go)
        S.route3_last_safe_clock = os.clock()
        return false
    end

    local pos = make_position(
        tonumber(upos.x) or 0.0,
        (tonumber(upos.y) or 0.0) + adjust,
        tonumber(upos.z) or 0.0
    )
    local ok = set_transform(go, pos, transform_rot(go))
    S.last_route3_ground_follow = ok and string.format("adjust %.2f", adjust) or "write failed"
    if ok then
        S.route3_last_safe_pos = pos
        S.route3_last_safe_rot = transform_rot(go)
        S.route3_last_safe_clock = os.clock()
    end
    return ok == true
end
function route3_order_hotkey_tick()
    local function edgek(vk, slot)
        vk = math.floor(tonumber(vk) or 0)
        if vk < 0x08 then return false end
        local down = false; pcall(function() down = iris_kb(vk) == true end)
        S.route3_order_keys = S.route3_order_keys or {}
        local was = S.route3_order_keys[slot] == true
        S.route3_order_keys[slot] = down
        return down and not was
    end
    local nm = tostring(C.route3_griffin_name or "Companion")
    if edgek(C.route3_key_follow, "follow") then
        if S.route3_unleashed == true then griffin_recall() end
        S.companion_order = "follow"; status(nm .. " follows you")
    end
    if edgek(C.route3_key_stay, "stay") then
        if S.route3_unleashed == true then griffin_recall()
        elseif S.companion_order == "attack" then griffin_order_disengage("ordered")
        else S.companion_order = "stay"; S.route3_companion_moving = false; stop_griffin_animation(); status(nm .. " stays") end
    end
    if edgek(C.route3_key_come, "come") then
        if S.route3_unleashed == true then griffin_recall() end
        S.companion_order = "come"; status(nm .. " is coming")
    end
    if edgek(C.route3_key_attack, "attack") then
        if S.route3_unleashed == true then griffin_recall() end
        griffin_order_attack()   -- owns the passive gate for BOTH paths (it runs before unleash)
    end
    if edgek(C.route3_key_eat, "eat") then griffin_eat_start("hotkey") end
end
