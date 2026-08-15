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
local get_player                       = ctx.get_player
local go_name                          = ctx.go_name
local griffin_action_manager           = ctx.griffin_action_manager
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

function griffin_combat_lease_start(target)
    if C.route3_lease_enabled == false then return false end
    if griffin_combat_lease_active() then return true end
    local gch, go = reacquire_griffin()
    if not (gch and go and target) then return false end
    local tgo = char_go(target)
    if not tgo then return false end
    local lease = { started = os.clock(), target = target, target_go = tgo,
                    last_seen = os.clock() }
    -- SNAPSHOT FIRST, and only then touch anything -- a lease that cannot restore is a one-way
    -- door, and this one moves her off the party faction.
    lease.prior_components = griffin_wake_combat_components(true, gch)
    -- ⭐ THE IDENTITY. Copy the faction box straight off the body she is about to fight: it is a
    -- guaranteed-live monster group (measured 1895570358 for goblin, cyclops AND her own stashed
    -- wild value), which beats trusting S.route3_ally_orig -- memory records that stash can be
    -- poisoned with the party hash on reclaim.
    -- ⛔ THIS IS THE CRASH FIX. All three CTDs were party-group + kind 8 = a battle group the
    -- engine cannot represent. Wild group + kind 8 is what every monster in Battahl already is.
    lease.group_set = griffin_group_copy_from(gch, target)
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
    pcall(function() griffin_wake_natural_combat(gch, target, true) end)
    S.route3_combat_lease = lease
    S.companion_order = "attack"
    S.companion_target = target
    S.companion_target_go = tgo
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
    if lease.target then
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
    -- both hooks are load-installed, but a load-time miss must not mean "silently absent all
    -- session" -- retry from the tick, the pattern every other hook in this tree uses.
    pcall(function() griffin_install_lease_hate_door() end)
    pcall(function() griffin_install_lease_relationship_hook() end)
    -- ⭐ LEASE TELEMETRY, 2s throttle. Without this every diagnosis needs a separate probe run and
    -- a screenshot; with it the log says what she is doing while she is doing it. The node name is
    -- the whole story: Locomotion.Wait = not engaging, Attack.* / Combat* = engaging.
    if now >= (tonumber(lease.next_log) or 0.0) then
        lease.next_log = now + 2.0
        local node = "?"
        pcall(function() node = tostring(read_griffin_fsm_node() or "?") end)
        pcall(function() griffin_ai_state_diag(gch) end)
        local el = tostring(tostring(S.route3_ai_state or ""):match("enemyList=(%-?%d+)") or "?")
        -- surface PUPPET too: it is the brake that was silently on for every run above
        local pup = tostring(tostring(S.route3_ai_state or ""):match("PUPPET=(%a+)") or "?")
        -- ⭐⭐⭐ IGNITION RETRY. One kick may not hold: if her AI drops straight back into the idle
        -- tree, re-latch and re-fire. The moment she STAYS out of Wait we stop kicking entirely and
        -- let the native AI drive -- that handover is the whole point, and the log records the
        -- exact second it happens so we know whether it held or she slid back.
        local waiting = tostring(node):find("Wait", 1, true) ~= nil
            or tostring(node):find("Idle", 1, true) ~= nil
        if waiting then
            lease.ignitions = (tonumber(lease.ignitions) or 0) + 1
            pcall(function() griffin_wake_natural_combat(gch, lease.target, true) end)
            -- and an actual attack node: requestActionCore is the route her own AI uses, and
            -- griffin_swing_once now opens a live window so the node carries real root motion.
            if C.route3_attack_ignite_swing ~= false then
                pcall(function() griffin_swing_once(nil) end)
            end
        elseif not lease.escaped then
            lease.escaped = true
            log.info(string.format(
                "[IrisAttack] ⭐ LEFT Locomotion.Wait after %d ignition(s) -> node=%s",
                tonumber(lease.ignitions) or 0, tostring(node)))
        end
        local decide = "?"
        pcall(function() decide = tostring(griffin_combat_state_diag(gch) or "?") end)
        log.info(string.format(
            "[IrisAttack] lease %.0fs node=%s ignitions=%s puppet=%s enemyList=%s relForced=%s hateBlocks=%s | %s",
            now - (tonumber(lease.started) or now), node,
            tostring(lease.ignitions or 0), pup, el,
            tostring(S.route3_lease_rel_hits or 0),
            tostring(S.route3_lease_hate_blocks or 0), decide))
    end
    -- IS THE FIGHT OVER? Any live enemy within the radius keeps it going -- not just the original
    -- target, because she should finish the pack rather than stop at one kill.
    local foe = nil
    pcall(function() foe = griffin_find_enemy(tonumber(C.route3_lease_radius) or 45.0) end)
    if foe then
        lease.last_seen = now
        lease.target = foe
        lease.target_go = char_go(foe)
    elseif now - (tonumber(lease.last_seen) or now) > (tonumber(C.route3_lease_quiet_secs) or 6.0) then
        return griffin_combat_lease_end("no enemies left")
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
