-- Ordered compatibility migrations for legacy I.R.I.S. mount profiles.
--
-- This function is a mechanical extraction from GriffinRideProbe (IRIS).
-- Rule order and guards are intentionally unchanged. Species adapters will
-- absorb their own rules only after this exact pipeline passes a smoke test.

local M = {}

function M.apply(key, p, C, adapter)
    local migrated = false
    local is_griffin = adapter ~= nil and adapter.id == "griffin"
    local is_drake = adapter ~= nil and adapter.id == "drake"
    if is_griffin
        and math.floor(tonumber(p.route3_landing_descent_clip) or -1) == 5210 then
        p.route3_landing_descent_clip = 5031
        migrated = true
    end
    -- DRAKE (ch257) 2026-08-11: the profile was born as a raw griffin copy and most
    -- griffin ids don't exist in ch57 banks (= the T-poses). Every id below is
    -- name-verified against Animal Atlas ch257000. Guarded on the copy signature
    -- (glide 5190 = griffin add_pose_F, no such clip on ch57) so hand tuning after
    -- the migration is never overwritten.
    if is_drake
        and math.floor(tonumber(p.flap_glide_clip) or -1) == 5190 then
        p.flap_glide_clip = 5100              -- com_flight_loop (steady soar)
        p.flap_glide_bank = 0
        p.landing_motion = 400                -- com_Landing_Front (ch57 has no hover_landing family)
        p.landing_end_motion = 401
        p.route3_landing_descent_clip = 5101  -- com_flight_loop_Flapping (safe under movement)
        p.route3_jump_clip_start = 5210       -- com_Takeoff_normal: ch57 has no jump clips -> wing hop
        p.route3_jump_clip_mid = 5101
        p.route3_jump_clip_fall = 5101
        p.route3_jump_clip_land = 401
        p.route3_jump_native_bank = 0
        p.route3_jump_native_clip = 5210
        p.root_motion_run = 100               -- ch57 has NO run/dash clip; walk until the
        p.route3_allow_sprint = false         -- Furious-Charge gallop is built
        migrated = true
    end
    -- per-species keys added 2026-08-11 (glide bank + rise/dive nodes): backfill any
    -- profile saved before they existed, otherwise applying species A leaks species
    -- B's last values through the shared C.
    if p.flap_glide_bank == nil then
        p.flap_glide_bank = is_drake and 0 or 50
        migrated = true
    end
    if p.route3_rise_node_up == nil then
        if is_drake then
            p.route3_rise_node_up = "Fly.Hovering.Ch257_HoverUp"    -- quick ascend (verified in the
            p.route3_rise_node_down = "Fly.Hovering.Ch257_HoverDown" -- live ch257 node-tree dump)
        else
            p.route3_rise_node_up = "Fly.Flight.Ch253LoopTheLoopFlight"
            p.route3_rise_node_down = "Fly.Flight.Ch253LoopTheLoopFlight"
        end
        migrated = true
    end
    -- v3 2026-08-11 (field round 3, from Aurora's recordings): ⛔ STREAMED-CLIP LAW EXTENDS
    -- TO THE DRAKE -- 5100/5101 evaluate to NULL on her parked FSM (flat-splayed wing T-pose
    -- on video, exactly at the jump-mid/glide/descent phases that painted them). Resident-only
    -- everywhere: glide -1 (flap.lua's own drake design: "just keep flapping through a
    -- sprint" -- also stops the soar machinery painting griffin bank-50 dush clips), jump =
    -- launch clip held through the arc, landing descent = the front-landing approach clip.
    -- ⛔ v11 guard: node_up ~= "" limits this to PRE-v10 profiles. v10 deliberately sets
    -- glide back to 5100 (nodeless flight) -- without the guard this block re-fired on every
    -- auto-apply and ate v10's values (ascend -1 = dead A-press, glide -1 = dead soar).
    if is_drake
        and math.floor(tonumber(p.flap_glide_clip) or -1) == 5100
        and tostring(p.route3_rise_node_up or "") ~= ""
        and tostring(p.route3_rise_node_up or "") ~= "Fly.Hovering.HoverToFly" then
        p.flap_glide_clip = -1
        p.route3_landing_descent_clip = 400   -- com_Landing_Front approach (5101 = null T-pose)
        p.route3_jump_clip_mid = -1           -- hold the 5210 launch flap through the arc
        p.route3_jump_clip_fall = -1
        p.route3_rise_ascend_clip = -1        -- ascend clip was invisible (same clip as cruise
                                              -- flap); movement-only until Aurora picks a NODE
        migrated = true
    end
    -- v4 2026-08-11 (field round 4, Aurora's timing notes): jump wind-up + rise duration go
    -- per-species. Drake: her takeoff clip preps ~3s before the leap, so the arc waits for it;
    -- rise nodes retire with the burst window, so a longer burst = the node animation actually
    -- plays out. Landing descent 400 was the FULL landing clip = a mid-air impact -- descend on
    -- wing-beats (5210) instead; 401 stays the single touchdown.
    if p.route3_ground_jump_windup == nil then
        if is_drake then
            p.route3_ground_jump_windup = 2.0
            p.route3_rise_secs = 3.5
            p.route3_landing_descent_clip = 5210
            -- Aurora's field picks (round 4): travel nodes with the good flight animation
            p.route3_rise_node_up = "Fly.Flight.FlightPathTraceTarget"
            p.route3_rise_node_down = "Fly.Flight.FlightTarget"
        else
            p.route3_ground_jump_windup = tonumber(C.route3_ground_jump_windup) or 0.5
            p.route3_rise_secs = tonumber(C.route3_rise_secs) or 1.75
        end
        migrated = true
    end
    -- v7 2026-08-11: window-end retire per-species (drake ON -- her travel nodes sustain
    -- forever; griffin OFF -- LoopTheLoop must outlive its window).
    if p.route3_rise_retire_at_window == nil then
        p.route3_rise_retire_at_window = is_drake
        migrated = true
    end
    -- v6 2026-08-11: pawn seat goes per-species. Aurora's knock theory: player + pawn colliding
    -- on the back when nodes pitch the body. The drake's back is long -- seat the pawn well aft.
    if p.route3_pawn_ride_back == nil then
        p.route3_pawn_ride_back = is_drake and 3.0
            or (tonumber(C.route3_pawn_ride_back) or 0.0)
        migrated = true
    end
    -- ⭐ SELF-HEAL 2026-08-11: Aurora accidentally SAVED the drake's live tuning over the
    -- griffin's profile (SAVE captures the shared C under whichever body is active -- a design
    -- trap, see note at the SAVE button). A ch253 profile carrying drake fingerprints is
    -- corrupt: restore the known-good griffin block (captured from disk 2026-08-11, pre-
    -- corruption, plus this file's own migration backfills).
    if is_griffin
        and (tostring(p.route3_rise_node_up or ""):find("FlightPathTrace", 1, true)
            or tostring(p.route3_rise_node_up or ""):find("Ch257", 1, true)
            or p.route3_rise_retire_at_window == true) then
        p.flap_takeoff_clip = 5210; p.flap_seg_start = 127.0; p.flap_seg_end = 230.0
        p.flap_glide_clip = 501; p.flap_glide_bank = 50
        p.flap_clip_loops = false; p.flap_loop_seconds = 1.5
        p.route3_flap_blend_frames = 20.0
        p.takeoff_motion = 5210; p.landing_motion = 5030; p.landing_end_motion = 5032
        p.route3_landing_descent_clip = 5031
        p.route3_jump_clip_start = 422; p.route3_jump_clip_mid = 423
        p.route3_jump_clip_fall = 416; p.route3_jump_clip_land = 401
        p.route3_jump_native_bank = 0; p.route3_jump_native_clip = 440
        p.route3_rise_node_up = "Fly.Flight.Ch253LoopTheLoopFlight"
        p.route3_rise_node_down = "Fly.Flight.Ch253LoopTheLoopFlight"
        p.route3_rise_ascend_clip = 702; p.route3_rise_ascend_start_clip = 700
        p.route3_rise_descend_clip = 551; p.route3_rise_descend_start_clip = 550
        p.route3_rise_clip_bank = 50
        p.route3_ground_jump_windup = 0.5; p.route3_rise_secs = 1.75
        p.route3_pawn_ride_back = 0.0; p.route3_rise_retire_at_window = false
        p.route3_loopcam_dist = 14.0
        p.route3_allow_sprint = true; p.route3_allow_flight = true; p.route3_mountable = true
        p.root_motion_walk = 100; p.root_motion_run = 200; p.root_motion_idle = -1
        p.idle_motion = 0
        p.route3_seat_offset_x = 0.0; p.route3_seat_offset_y = 2.3; p.route3_seat_offset_z = 1.6
        p.spawn_scale = 0.55
        migrated = true
    end
    -- ⭐⭐ v10 2026-08-12 -- NODELESS FLIGHT (Aurora's call, and the right one): held travel
    -- nodes flicker the climb state natively (unhookable -- getter pin AND setter veto both
    -- failed on instruments), and that flicker IS the close-up camera AND the knocking. Drop
    -- the nodes entirely: ascend/descend/soar = movement + clip 5100 (com_flight_loop, the
    -- majestic locked-wing soar). ⚠ FIELD TEST: 5100 is in the streamed family -- if it
    -- paints as T-pose airborne, fall back to flap-base + additive hover poses (L1).
    if is_drake
        and tostring(p.route3_rise_node_up or "") == "Fly.Flight.FlightPathTraceTarget" then
        p.route3_rise_node_up = ""
        p.route3_rise_node_down = ""
        p.route3_rise_ascend_clip = 5100
        p.route3_rise_ascend_start_clip = -1
        p.route3_rise_descend_clip = 5100
        p.route3_rise_descend_start_clip = -1
        p.route3_rise_clip_bank = 0
        p.flap_glide_clip = 5100          -- B-soar = the same glide loop
        p.flap_glide_bank = 0
        p.route3_rise_retire_at_window = false   -- nothing to retire anymore
        p.route3_soar_directional = false -- directional soar sub-clips are griffin bank-50 ids
        migrated = true
    end
    if p.route3_soar_directional == nil then
        p.route3_soar_directional = not is_drake
        migrated = true
    end
    -- Drake rider v2 is the only active Drake flight-rider experiment in this development
    -- build.  An old per-species false value previously overrode the global migration after
    -- adopt, silently leaving Aurora in native grab and producing the storm.
    if is_drake and p.route3_air_seat ~= true then
        p.route3_air_seat = true
        migrated = true
    elseif p.route3_air_seat == nil then
        p.route3_air_seat = false
        migrated = true
    end
    -- v22 2026-08-13: the captured ch257 rig disproved the root-height theory. root really is
    -- ground-level; the saddle line is Spine_2/Spine_3. Give the air seat its own body-relative
    -- anchor/offset so fixing flight cannot move the native ground re-latch. Nil-only migration
    -- is idempotent and leaves any later hand tuning untouched.
    if p.route3_air_seat_joint == nil then
        if is_drake then
            p.route3_air_seat_joint = "Spine_2"
            p.route3_air_seat_offset_x = 0.0
            p.route3_air_seat_offset_y = -1.6
            p.route3_air_seat_offset_z = 0.0
        else
            p.route3_air_seat_joint = "root"
            p.route3_air_seat_offset_x = 0.0
            p.route3_air_seat_offset_y = tonumber(p.route3_seat_offset_y) or 2.3
            p.route3_air_seat_offset_z = tonumber(p.route3_seat_offset_z) or 1.6
        end
        migrated = true
    end
    -- v23 2026-08-14: one animated point plus the actor quaternion is not a saddle frame.
    -- The new basis follows the live spine tangent and shoulder line. Old offsets were
    -- compensation for the invalid axes, so reset them once on adoption; later tuning survives.
    if is_drake and math.floor(tonumber(p.route3_air_seat_frame_v) or 0) < 2 then
        p.route3_air_seat_joint = "Spine_2"
        p.route3_air_seat_offset_x = 0.0
        p.route3_air_seat_offset_y = 1.0
        p.route3_air_seat_offset_z = 0.0
        p.route3_air_seat_frame_v = 2
        migrated = true
    elseif p.route3_air_seat_frame_v == nil then
        p.route3_air_seat_frame_v = 2
        migrated = true
    end
    -- v13 (Aurora: "a long R3 descend has the drake start doing a take off animation"):
    -- 5210 IS her takeoff clip -- it was the landing-descent pick back when nothing else
    -- painted airborne. 5100 (the glide loop) paints reliably now (v10+ field-proven).
    -- Era-guarded on the air-seat key existing (v11 law: value matches need era guards).
    if is_drake and p.route3_air_seat ~= nil
        and math.floor(tonumber(p.route3_landing_descent_clip) or -1) == 5210 then
        p.route3_landing_descent_clip = 5100
        migrated = true
    end
    -- v24 2026-08-23: ch57 0:416 is com_Fall_Loop_Front -- the ordinary
    -- airborne fall/landing-approach loop, not a Damage.*Fall node. 5100 is the
    -- steady soar pose, which is why a long landing visibly snapped the drake
    -- back into cruise. Keep 5205 as the initial air-brake and 401 as touchdown;
    -- only replace the sustained descent beat. The exact 5100 signature preserves
    -- any later hand-picked landing clip.
    if is_drake and p.route3_air_seat ~= nil
        and math.floor(tonumber(p.route3_landing_descent_clip) or -1) == 5100 then
        p.route3_landing_descent_clip = 416
        -- The same clip is also the correct long-drop phase for a ground jump.
        -- Only fill the old disabled value; never overwrite a tested custom pick.
        if math.floor(tonumber(p.route3_jump_clip_fall) or -1) == -1 then
            p.route3_jump_clip_fall = 416
        end
        migrated = true
    end
    -- v25 2026-08-23: Aurora field-verified these exact native hover nodes with the
    -- root-fixed one-writer gearbox. They animate correctly, survive native-grab riders,
    -- and actually travel. Promote the former one-shot candidates to the Drake profile.
    -- The blank-node signature is the retired nodeless-flight profile, so later custom
    -- choices are never overwritten.
    if is_drake and p.route3_air_seat ~= nil
        and tostring(p.route3_rise_node_up or "") == ""
        and tostring(p.route3_rise_node_down or "") == "" then
        p.route3_rise_node_up = "Fly.Hovering.HoverToFly"
        p.route3_rise_node_down = "Fly.Hovering.Ch257_HoverDown"
        p.route3_rise_node_gearbox_distance = 12.0
        p.route3_rise_retire_at_window = false
        migrated = true
    elseif p.route3_rise_node_gearbox_distance == nil then
        p.route3_rise_node_gearbox_distance = 12.0
        migrated = true
    end
    -- v26: v3's pre-v10 streamed-clip migration accidentally matched the newly promoted
    -- HoverToFly default and deleted 5100 again. That is exactly why B still accelerated
    -- but no longer changed to the soar pose. Restore the verified Drake flight loop and,
    -- at the same time, give grounded B-sprint the authored ChargeAttack loop (50:1).
    -- Root motion remains suppressed; the existing terrain drive still owns translation.
    if is_drake
        and tostring(p.route3_rise_node_up or "") == "Fly.Hovering.HoverToFly"
        and tostring(p.route3_rise_node_down or "") == "Fly.Hovering.Ch257_HoverDown" then
        if math.floor(tonumber(p.flap_glide_clip) or -1) == -1 then
            p.flap_glide_clip = 5100
            p.flap_glide_bank = 0
            p.route3_soar_directional = false
            migrated = true
        end
        if math.floor(tonumber(p.root_motion_run) or -1) == 100 then
            p.root_motion_run = 1
            p.root_motion_run_bank = 50
            migrated = true
        elseif p.root_motion_run_bank == nil then
            p.root_motion_run_bank = 50
            migrated = true
        end
    elseif p.root_motion_run_bank == nil then
        p.root_motion_run_bank = 0
        migrated = true
    end
    -- ⭐ v11 2026-08-12 REPAIR: v3 re-fired after v10 (its glide==5100 trigger matched v10's
    -- intended value) and clobbered three v10 values on the very next auto-apply. Restore them.
    -- Signature = post-v10 (nodes cleared) but ascend dead -- exactly the clobbered state.
    if is_drake
        and tostring(p.route3_rise_node_up or "") == ""
        and math.floor(tonumber(p.route3_rise_ascend_clip) or -1) == -1 then
        p.route3_rise_ascend_clip = 5100
        p.route3_rise_descend_clip = 5100
        p.route3_rise_clip_bank = 0
        p.flap_glide_clip = 5100
        p.flap_glide_bank = 0
        if math.floor(tonumber(p.route3_landing_descent_clip) or -1) == 400 then
            p.route3_landing_descent_clip = 5210   -- v4's fix (400 = mid-air impact) re-asserted
        end
        migrated = true
    end
    -- ⭐ SELF-HEAL part 2 (08-11, found by full disk diff): the v4/v6 BACKFILLS seeded new keys
    -- from the live shared C "to preserve current tuning" -- but C held the DRAKE's tuning when
    -- the griffin's profile first gained those keys, so three drake values leaked in under the
    -- fingerprint radar. Heal them by exact leaked value (hand-tuning stays safe).
    if is_griffin then
        if tonumber(p.route3_ground_jump_windup) == 3.0 or tonumber(p.route3_ground_jump_windup) == 2.0 then
            p.route3_ground_jump_windup = 0.5; migrated = true
        end
        if tonumber(p.route3_rise_secs) == 3.5 then p.route3_rise_secs = 1.75; migrated = true end
        -- 0.9 = the ORIGINAL global tuning (recovered from the Wayfarer repo's 17:30 pre-chaos
        -- snapshot); my first heal's 0.0 stacked the pawn ON TOP of the Arisen
        if tonumber(p.route3_pawn_ride_back) == 3.0 or tonumber(p.route3_pawn_ride_back) == 0.0 then
            p.route3_pawn_ride_back = 0.9; migrated = true
        end
    end
    -- v8 2026-08-11 (camtrace verdict): the "native close-up" was TWO cameras both too close
    -- to a very large body -- the native cling cam locks to ~5.6m during Fly.* (measured), and
    -- OUR loopcam's griffin-tuned 14m is ALSO a close-up on a drake. Shot distance goes
    -- per-species; the drake films wide.
    if p.route3_loopcam_dist == nil then
        p.route3_loopcam_dist = is_drake and 28.0
            or (tonumber(C.route3_loopcam_dist) or 14.0)
        migrated = true
    end
    -- v9 2026-08-11: pawn 3m-aft seat reverted (knocking was NOT the pawn -- solo test proved
    -- it -- and the aft seat looked odd). "Normal" = 0.9, the original pre-split global tuning
    -- (Wayfarer repo 17:30 snapshot), NOT 0.0 -- zero stacks the pawn on the Arisen.
    if is_drake
        and (tonumber(p.route3_pawn_ride_back) == 3.0 or tonumber(p.route3_pawn_ride_back) == 0.0) then
        p.route3_pawn_ride_back = 0.9
        migrated = true
    end
    -- v5 2026-08-11: v4 shipped windup 3.0; Aurora field-timed it "about a second off" -> 2.0.
    -- Guarded on the exact v4 value so her own later hand-tuning is never overwritten.
    if is_drake and tonumber(p.route3_ground_jump_windup) == 3.0 then
        p.route3_ground_jump_windup = 2.0
        migrated = true
    end
    -- v2 2026-08-11 (field round 2): the rise CLIP set goes per-species (griffin's are
    -- bank-50 ids that don't exist on other species). Guarded on the new key being absent.
    if p.route3_rise_ascend_clip == nil then
        if is_drake then
            -- field verdict: Ch257_HoverUp fires+survives but is visually ~identical to
            -- normal flight. Ascend = the takeoff wing-burst CLIP instead (proven safe
            -- under movement -- it is her working takeoff); node cleared so the clip paints.
            p.route3_rise_node_up = ""
            p.route3_rise_ascend_start_clip = -1
            p.route3_rise_ascend_clip = 5210      -- com_Takeoff_normal wing burst
            p.route3_rise_descend_start_clip = -1
            p.route3_rise_descend_clip = -1       -- descend stays node-only (Ch257_HoverDown)
            p.route3_rise_clip_bank = 0
            p.route3_allow_sprint = true          -- v1 set false and that killed air-soar too; revert
            p.landing_motion = 5205               -- move_change_flight_to_hover = air-brake (400 was a
                                                  -- ground-impact clip painted MID-AIR = a knock source)
            p.idle_motion = 4                     -- com_idle_loop_watch: calm idle, no tail-lash
                                                  -- (knock-after-landing A/B test)
        else
            p.route3_rise_ascend_start_clip = 700 -- prior globals, unchanged behaviour
            p.route3_rise_ascend_clip = 702
            p.route3_rise_descend_start_clip = 550
            p.route3_rise_descend_clip = 551
            p.route3_rise_clip_bank = 50
        end
        migrated = true
    end
    -- v28 2026-08-25: finish the manual yaw during the useful half of the
    -- common-turn clip. The prior slow 2.45s profile reached 90 degrees before
    -- the visual hand-back and then snapped to 180.
    if is_drake then
        if (tonumber(p.route3_drake_turn_charge_fix_version) or 0) < 2 then
            p.route3_drake_turn_charge_fix_version = 2
            p.route3_drake_turn180_secs = 1.25
            p.route3_drake_turn180_motion_speed = 1.0
            -- Remove the disproven RB lunge experiment from old species records.
            p.route3_drake_charge_start_clip = nil
            p.route3_drake_charge_loop_clip = nil
            p.route3_drake_charge_end_clip = nil
            p.route3_drake_charge_speed = nil
            p.route3_drake_charge_damage = nil
            p.route3_drake_charge_contact_reach = nil
            migrated = true
        end
        if p.route3_drake_sprint_hitbox ~= false then
            p.route3_drake_sprint_hitbox = false
            migrated = true
        end
    end
    return migrated
end

return M
