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
function griffin_order_disengage(reason)
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
function griffin_order_attack()
    if C.route3_attack_uses_unleash == true then
        return griffin_unleash()
    end
    if S.mounted == true then status("dismount before ordering an attack"); return false end
    local gch, go = reacquire_griffin()
    if not (gch and go) then status("no companion to command"); return false end
    local target = griffin_find_enemy(40.0)
    if not target then
        S.route3_tame_status = "no enemy in range to attack"
        status(S.route3_tame_status)
        return false
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
function griffin_order_tick()
    -- FOLLOW / STAY / COME: the companion walks or runs after the player.
    -- Come = follow until arrival, then stay. Orders suspend while mounted.
    if S.world_paused == true then return false end
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
        griffin_order_attack()
    end
    if edgek(C.route3_key_eat, "eat") then griffin_eat_start("hotkey") end
end
