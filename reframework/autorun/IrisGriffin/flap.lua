-- I.R.I.S. griffin -- wing flap and wing-pose visuals.
--
-- Everything that decides what her wings LOOK like in the air: the resident flap loop driven off
-- the takeoff clip, the glide/soar poses, the direct wing-joint posing, and the capture/replay
-- probes those were built from. It owns no flight physics -- position and rotation belong to the
-- seat drive -- so a mistake here is visibly wrong but never dangerous.
--
-- Extracted from the main script as the first module of the split, chosen because it is checked
-- by eye on every single flight.

local ctx = require("IrisGriffin.context")
local C, S = ctx.C, ctx.S
local MOD                              = ctx.MOD
local status                      = ctx.status
local get_component               = ctx.get_component
local table_count                 = ctx.table_count
local motion_tag                  = ctx.motion_tag
local get_griffin_motion_component = ctx.get_griffin_motion_component
local play_griffin_motion         = ctx.play_griffin_motion
local set_griffin_motion_speed    = ctx.set_griffin_motion_speed
-- forward-declared file-locals: these READ like globals in the original file but are not
local reacquire_griffin           = ctx.reacquire_griffin
local system_array_to_table       = ctx.system_array_to_table

-- PROTOTYPE flap mode A: loop a RESIDENT takeoff clip for real authored wing-flapping.
-- The takeoff clips (5210 + siblings) are the ONLY resident clips with genuine feathered
-- flaps, and they play from the parked/puppet FSM without the streamed-clip null crash
-- that kills 5101/5000. While moving we re-trigger the clip on a cadence so the wings keep
-- beating; while hovering we hold a resident glide pose. Position stays transform-driven,
-- so the clip's own root motion is ignored. Global (not local) to dodge the 200-local cap.
function route3_flap_layer_frame()
    local motion = get_griffin_motion_component()
    local frame = nil
    pcall(function()
        local layer = motion and motion:call("getLayer", 0)
        frame = layer and tonumber(layer:call("get_Frame"))
    end)
    return frame
end

function route3_flap_layer_clip()
    local motion = get_griffin_motion_component()
    local clip = nil
    pcall(function()
        local layer = motion and motion:call("getLayer", 0)
        clip = layer and tonumber(layer:call("get_MotionID"))
    end)
    return clip
end

function route3_flap_layer_end()
    local motion = get_griffin_motion_component()
    local frame = nil
    pcall(function()
        local layer = motion and motion:call("getLayer", 0)
        frame = layer and tonumber(layer:call("get_EndFrame"))
    end)
    return frame
end

function route3_flap_play_from(clip, frame)
    -- re-trigger the same clip at a start frame WITH a crossfade: a blended
    -- loop seam instead of the hard set_Frame snap. Blend length is tunable —
    -- longer blends hide pose mismatch on clips with no clean loop window.
    local motion = get_griffin_motion_component()
    local ok = false
    pcall(function()
        local layer = motion and motion:call("getLayer", 0)
        if layer then
            layer:call(
                "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                0, clip, tonumber(frame) or 0.0, math.max(2.0, tonumber(C.route3_flap_blend_frames) or 8.0), 1, 1
            )
            ok = true
        end
    end)
    return ok
end

function route3_flap_set_root_controllers(enabled)
    -- app.Forward/InertiaRootMotionController are the app-layer components that
    -- APPLY a clip's root displacement to the character — the actual hijackers
    -- when a self-propelling flight loop like 5101 plays. Off in the air,
    -- back on at landing/dismount so the released griffin moves normally.
    local _, go = reacquire_griffin()
    if not go then return false end
    local any = false
    for _, tn in ipairs({ "app.ForwardRootMotionController", "app.InertiaRootMotionController" }) do
        local comp = get_component(go, tn)
        if comp then
            pcall(function() comp:call("set_Enabled", enabled == true) end)
            any = true
        end
    end
    S.route3_flap_root_ctrl_state = enabled == true and "enabled" or "DISABLED (flight)"
    return any
end

function route3_flap_kill_root_motion()
    -- flight loops like 5101 self-propel via root motion and hijack the ride
    local motion = get_griffin_motion_component()
    if motion then
        local mode = math.max(0, math.floor(tonumber(C.root_motion_suppressed_play_mode) or 0))
        pcall(function() motion:call("set_RootMotion(via.motion.RootPlayMode)", mode) end)
        pcall(function() motion:call("set_RootScaleDisabled(System.Boolean)", true) end)
    end
    route3_flap_set_root_controllers(false)
    return true
end

function route3_flap_play_overlay(clip)
    -- paint the flap clip on layer 1 instead of layer 0: root motion is
    -- normally extracted from the base layer only, so an overlay flap
    -- animates the wings without steering the body
    local motion = get_griffin_motion_component()
    local ok = false
    pcall(function()
        local layer = motion and motion:call("getLayer", 1)
        if layer then
            layer:call(
                "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                0, clip, 0.0, 8.0, 1, 1
            )
            ok = true
        end
    end)
    return ok
end

function route3_flap_overlay_clip()
    local motion = get_griffin_motion_component()
    local clip = nil
    pcall(function()
        local layer = motion and motion:call("getLayer", 1)
        clip = layer and tonumber(layer:call("get_MotionID"))
    end)
    return clip
end

function route3_flap_clear_overlay()
    -- release layer 1 so the wings stop flapping once we are back on the ground
    local motion = get_griffin_motion_component()
    local ok = false
    pcall(function()
        local layer = motion and motion:call("getLayer", 1)
        if not layer then return end
        -- 0xFFFFFFFF is what an empty layer reports as its motion id
        local cleared = pcall(function()
            layer:call(
                "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                0, 4294967295, 0.0, 8.0, 1, 1
            )
        end)
        if not cleared then pcall(function() layer:call("clearMotion") end) end
        ok = true
    end)
    return ok
end

function route3_flap_seek(frame)
    local motion = get_griffin_motion_component()
    local ok = false
    pcall(function()
        local layer = motion and motion:call("getLayer", 0)
        if layer then
            layer:call("set_Frame", tonumber(frame) or 0.0)
            ok = true
        end
    end)
    return ok
end

function route3_flap_takeoff_tick(now)
    if C.flap_mode ~= 1 or S.airborne ~= true then return false end
    if C.route3_native_flight_anim == true then return false end
    if now <= (S.audition_until_clock or 0) then return true end
    if now < (tonumber(S.route3_air_visual_block_until) or 0.0) then
        S.route3_air_visual_status = "flapA transition grace"
        return true
    end
    local moving = (math.abs(tonumber(S.last_character_root_forward) or 0.0)
        + math.abs(tonumber(S.last_character_root_side) or 0.0)
        + math.abs(tonumber(S.last_character_root_vertical) or 0.0)
        + math.abs(tonumber(S.last_character_root_turn_input) or 0.0)) > 0.05
    -- R3 landing: play the real landing sequence instead of cruise beats —
    -- hover_landing_start once, then hover_landing_loop for the descent
    -- (touchdown plays hover_landing_end from route3_finish_landing)
    if S.route3_landing_requested == true then
        if S.route3_flap_phase ~= "landing" then
            S.route3_flap_phase = "landing"
            play_griffin_motion(tonumber(C.landing_motion) or 5030, tonumber(C.landing_bank) or 0, true)
            S.route3_flap_landing_loop_at = now + 0.9
            S.route3_air_visual_status = "flapA landing start"
        elseif S.route3_flap_landing_loop_at and now >= S.route3_flap_landing_loop_at then
            S.route3_flap_landing_loop_at = nil
            play_griffin_motion(tonumber(C.route3_landing_descent_clip) or 5031, 0, true)
            S.route3_air_visual_status = "flapA landing descent loop"
        end
        return true
    end
    -- bird logic (Aurora's design): wings BEAT while hovering and cruising,
    -- and lock into the SOAR pose only while sprinting; landing always beats.
    -- Species with no soar clip (drakes) just keep flapping through a sprint.
    local sprinting = S.last_character_root_move_run == true and moving
        and S.route3_going_backward ~= true   -- Aurora: don't soar when holding B backwards
        and (tonumber(C.flap_glide_clip) or -1) >= 0
    local clip = math.floor(tonumber(C.flap_takeoff_clip) or 5210)
    local soar = math.floor(tonumber(C.flap_glide_clip) or 5190)
    local soar_bank = math.floor(tonumber(C.flap_glide_bank) or 0)
    local seg_start = math.max(0.0, tonumber(C.flap_seg_start) or 100.0)
    local seg_end = math.max(seg_start + 10.0, tonumber(C.flap_seg_end) or 200.0)
    -- Leaving the soar drops the lead-in window, so the next entry plays the intro again rather
    -- than snapping straight to the loop pose. Done here rather than in an else branch: this
    -- if/elseif chain ends in a catch-all that paints the beat, and splitting it put that
    -- catch-all back in play DURING a sprint, repainting the flap clip over the soar every frame.
    if not sprinting then S.route3_soar_intro_until = nil end
    if sprinting then
        -- DIRECTIONAL SOAR (Aurora): bank into turns + tuck for a dive using the dush
        -- clips (bank 50). vertical = ascend-descend (descending = vertical<0); turn_input
        -- is the yaw/strafe axis (sign = side). Pick the DOMINANT input; a dive wins ties.
        local desired, desired_bank = soar, soar_bank
        if C.route3_soar_directional ~= false then
            -- ⭐ HYSTERESIS (Aurora 2026-08-08: "the sprint animation doesn't loop
            -- properly -- about 2 full loops then a small but noticeable jitter").
            -- The pose is re-chosen EVERY frame against one hard threshold, so a stick
            -- resting near it chatters across the boundary and each crossing re-fires
            -- changeMotion -- a restart seam mid-loop, at irregular intervals. Classic
            -- cure: it takes MORE input to enter a directional pose than to keep it.
            local dead = tonumber(C.route3_soar_dir_deadzone) or 0.3
            local cur_dir = S.route3_soar_dir_clip
            local in_dir = (cur_dir ~= nil and cur_dir >= 0 and cur_dir ~= soar)
            if in_dir then
                dead = dead * math.max(0.1, math.min(1.0,
                    tonumber(C.route3_soar_dir_hysteresis) or 0.6))
            end
            local turn_in = tonumber(S.last_character_root_turn_input) or 0.0
            if math.abs(turn_in) < 0.01 then turn_in = tonumber(S.last_character_root_side) or 0.0 end
            local vert = tonumber(S.last_character_root_vertical) or 0.0
            local desc_mag = (vert < -dead) and (-vert) or 0.0
            local turn_mag = (math.abs(turn_in) > dead) and math.abs(turn_in) or 0.0
            local dbank = math.floor(tonumber(C.route3_soar_dir_bank) or 50)
            -- ASCEND had no branch at all: climbing while soaring just held the level pose.
            -- ch53 ships a purpose-built directional set in bank 0 -- flight_add_pose F/L/R/U/D
            -- (5190/5192/5193/5194/5195) -- and 5194 is the nose-up one. It carries its own bank
            -- because that family is bank 0 while the dush banking clips are bank 50.
            local asc_clip = math.floor(tonumber(C.route3_soar_ascend_clip) or -1)
            local asc_mag = (vert > dead) and vert or 0.0
            if asc_mag > 0.0 and asc_mag >= turn_mag and asc_clip >= 0 then
                desired = asc_clip
                desired_bank = math.floor(tonumber(C.route3_soar_ascend_bank) or 0)
            elseif desc_mag > 0.0 and desc_mag >= turn_mag then
                desired, desired_bank = math.floor(tonumber(C.route3_soar_descend_clip) or 551), dbank
            elseif turn_mag > 0.0 then
                local left = turn_in > 0.0   -- (flipped: Aurora reported L/R were mirrored)
                if C.route3_soar_turn_invert == true then left = not left end
                desired = math.floor(left and (tonumber(C.route3_soar_left_clip) or 531)
                    or (tonumber(C.route3_soar_right_clip) or 541))
                desired_bank = dbank
            end
        end
        -- LEAD-IN (Aurora): 50:500 atk_high_altitude_start is the authored ENTRY to 501's loop, so
        -- playing it once on the way in gives her a real transition into the soar instead of the
        -- pose appearing between frames. Only on ENTERING the phase -- a direction change mid-soar
        -- keeps swapping poses directly, or every turn would replay the intro.
        local intro = math.floor(tonumber(C.route3_soar_start_clip) or -1)
        if S.route3_flap_phase ~= "soar" and intro >= 0 then
            S.route3_flap_phase = "soar"
            S.route3_soar_dir_clip = nil    -- force the pose to be (re)chosen once the intro ends
            S.route3_soar_intro_until = now + math.max(0.1, tonumber(C.route3_soar_start_secs) or 0.7)
            play_griffin_motion(intro, math.floor(tonumber(C.route3_soar_start_bank) or 50), true)
            S.route3_air_visual_status = "flapA soar-start " .. tostring(intro)
        elseif (tonumber(S.route3_soar_intro_until) or 0.0) > now then
            -- the lead-in owns the layer until it has played out
        elseif S.route3_flap_phase ~= "soar" or S.route3_soar_dir_clip ~= desired then
            -- ⭐ MINIMUM DWELL (same fix as the hysteresis above, second half): even with
            -- hysteresis a deliberate wiggle can order two swaps back to back, and every
            -- swap restarts a clip mid-cycle. Hold each pose briefly before allowing the
            -- next one -- the wings finish their beat instead of snapping. Entering the
            -- soar phase for the FIRST time is exempt (nothing to interrupt).
            local dwell = math.max(0.0, tonumber(C.route3_soar_dir_dwell) or 0.35)
            local since = now - (tonumber(S.route3_soar_dir_at) or -1.0e9)
            if S.route3_flap_phase == "soar" and S.route3_soar_dir_clip ~= nil
                and since < dwell then
                S.route3_air_visual_status = string.format(
                    "flapA soar %s:%s (holding %.2fs)", tostring(soar_bank),
                    tostring(S.route3_soar_dir_clip), dwell - since)
            else
                S.route3_flap_phase = "soar"
                S.route3_soar_dir_clip = desired
                S.route3_soar_dir_at = now
                if desired >= 0 then play_griffin_motion(desired, desired_bank, true) end
                S.route3_air_visual_status = "flapA soar " .. tostring(desired_bank) .. ":" .. tostring(desired)
            end
        end
    elseif C.flap_clip_loops == true then
        -- clip is a natural loop (e.g. 5101 flight_loop_flapping): keep it on the layer
        if C.flap_overlay_layer == true then
            -- base layer holds the soar pose, the flap loop paints layer 1 on top
            if S.route3_flap_phase ~= "beat" or route3_flap_overlay_clip() ~= clip then
                S.route3_flap_phase = "beat"
                S.route3_flap_last = now
                if soar >= 0 and route3_flap_layer_clip() ~= soar then
                    play_griffin_motion(soar, soar_bank, true)
                end
                route3_flap_play_overlay(clip)
                route3_flap_kill_root_motion()
                S.route3_air_visual_status = "flapA OVERLAY loop L1 0:" .. tostring(clip)
            elseif (now - (tonumber(S.route3_flap_rootkill_last) or 0.0)) >= 1.0 then
                S.route3_flap_rootkill_last = now
                route3_flap_kill_root_motion()
            end
        elseif S.route3_flap_phase ~= "beat" or route3_flap_layer_clip() ~= clip then
            S.route3_flap_phase = "beat"
            S.route3_flap_last = now
            play_griffin_motion(clip, 0, true)
            route3_flap_kill_root_motion()
            S.route3_air_visual_status = "flapA native loop 0:" .. tostring(clip)
        elseif (now - (tonumber(S.route3_flap_rootkill_last) or 0.0)) >= 1.0 then
            -- keep root motion suppressed: the engine can re-enable it on us
            S.route3_flap_rootkill_last = now
            route3_flap_kill_root_motion()
        end
    else
        if S.route3_flap_phase ~= "beat" then
            S.route3_flap_phase = "beat"
            S.route3_flap_last = now
            S.route3_flap_seeked = false
            if route3_flap_layer_clip() ~= clip then
                -- streamed clips (5101) take a moment to actually land on the
                -- layer: request it and DO NOT seek until it is really there,
                -- or the seek can cancel the swap and leave the old clip playing
                play_griffin_motion(clip, 0, true)
                S.route3_flap_load_request = now
                S.route3_air_visual_status = string.format("flapA loading 0:%d ...", clip)
            else
                route3_flap_seek(seg_start)
                S.route3_flap_seeked = true
                S.route3_air_visual_status = string.format("flapA beat 0:%d seg %.0f-%.0f", clip, seg_start, seg_end)
            end
        else
            local layer_clip = route3_flap_layer_clip()
            if layer_clip ~= clip then
                if (now - (tonumber(S.route3_flap_load_request) or 0.0)) >= 0.75 then
                    play_griffin_motion(clip, 0, true)
                    S.route3_flap_load_request = now
                end
                S.route3_air_visual_status = string.format("flapA waiting for 0:%d (layer has 0:%s)", clip, tostring(layer_clip))
                return true
            end
            -- clamp to the clip's real length so a too-high end slider can't
            -- park the playhead at the clip end forever
            local layer_end = tonumber(route3_flap_layer_end()) or 0.0
            if layer_end > 1.0 and seg_end > layer_end - 0.5 then
                seg_end = layer_end - 0.5
                if seg_start >= seg_end - 5.0 then seg_start = math.max(0.0, seg_end - 30.0) end
            end
            if S.route3_flap_seeked ~= true then
                route3_flap_seek(seg_start)
                S.route3_flap_seeked = true
            end
            -- seek-loop: keep the playhead inside the beat segment, no clip restarts
            local frame = route3_flap_layer_frame()
            if frame ~= nil then
                if frame >= seg_end or frame < seg_start - 12.0 then
                    if frame < seg_start - 12.0 and (now - (tonumber(S.route3_flap_last_blend) or -10.0)) < 1.0 then
                        -- blend re-entry landed at the clip start: the start-frame
                        -- argument is not honoured — stop using blended wraps
                        S.route3_flap_blend_unsupported = true
                    end
                    local wrapped = false
                    if C.flap_loop_blend == true and S.route3_flap_blend_unsupported ~= true and frame >= seg_end then
                        wrapped = route3_flap_play_from(clip, seg_start)
                        if wrapped then S.route3_flap_last_blend = now end
                    end
                    if not wrapped then
                        if not route3_flap_seek(seg_start) then
                            -- seeking unsupported: fall back to the old full restart
                            play_griffin_motion(clip, 0, true)
                        end
                    end
                    S.route3_flap_last = now
                end
                S.route3_air_visual_status = string.format(
                    "flapA loop 0:%d seg %.0f-%.0f len %.0f f=%.0f",
                    clip, seg_start, seg_end, layer_end, frame
                )
            elseif (now - (tonumber(S.route3_flap_last) or 0.0)) >= math.max(0.4, tonumber(C.flap_loop_seconds) or 1.5) then
                S.route3_flap_last = now
                play_griffin_motion(clip, 0, true)
                S.route3_air_visual_status = "flapA restart (no frame read) 0:" .. tostring(clip)
            end
        end
    end
    return true
end

-- PROTOTYPE flap presets -- one-click flight-animation routes to compare in-game.
function route3_wing_probe_refreeze_tick(now)
    if (tonumber(S.route3_wing_probe_refreeze_at) or 0.0) <= 0.0 then return false end
    if now < (tonumber(S.route3_wing_probe_refreeze_at) or 0.0) then return true end
    set_griffin_motion_speed(0.0)
    S.route3_wing_probe_status = "refrozen: " .. tostring(S.route3_wing_probe_refreeze_reason or "timed")
    S.route3_wing_probe_refreeze_at = 0.0
    S.route3_wing_probe_refreeze_reason = "(none)"
    return true
end

function route3_wing_joint_names()
    local out = {}
    for raw in tostring(C.route3_wing_joint_pose_joints or ""):gmatch("[^,%s]+") do
        out[#out + 1] = tostring(raw)
    end
    return out
end

function route3_wing_joint_axis()
    local axis = math.floor(tonumber(C.route3_wing_joint_pose_axis) or 1)
    if axis < 1 or axis > 3 then axis = 1 end
    if axis == 1 then return 1.0, 0.0, 0.0, "X" end
    if axis == 2 then return 0.0, 1.0, 0.0, "Y" end
    return 0.0, 0.0, 1.0, "Z"
end

function route3_wing_capture_names(tf)
    local out = {}
    local spec = tostring(C.route3_wing_capture_joints or "AUTO_WINGS")
    if spec == "" or spec:upper() == "AUTO_WINGS" or spec == "*" then
        local joints = {}
        pcall(function() joints = system_array_to_table(tf and tf:call("get_Joints")) end)
        for _, joint in ipairs(joints or {}) do
            local name = nil
            pcall(function() name = joint and joint:call("get_Name") end)
            name = tostring(name or "")
            if name:find("Wing", 1, true) then
                out[#out + 1] = name
            end
        end
        return out
    end
    for raw in spec:gmatch("[^,%s]+") do
        raw = raw:gsub("^%s+", ""):gsub("%s+$", "")
        if raw ~= "" then out[#out + 1] = raw end
    end
    return out
end

function route3_wing_sample_rot(item)
    if not item then return nil end
    return item.rot or item
end

function route3_wing_sample_pos(item)
    if not item then return nil end
    return item.pos
end

function route3_wing_capture_tick(now)
    if S.route3_wing_capture_active ~= true then return false end
    return route3_wing_capture_tick_phase(now, "motion")
end

function route3_wing_capture_tick_phase(now, phase)
    if S.route3_wing_capture_active ~= true then return false end
    if C.route3_wing_capture_late_update == true and phase ~= "late" then
        S.route3_wing_capture_status = "capture waiting for LateUpdate"
        return false
    end
    now = now or os.clock()
    local _, go = reacquire_griffin()
    local tf = go and go:call("get_Transform")
    if not tf then
        S.route3_wing_capture_active = false
        S.route3_wing_capture_status = "capture failed: no transform"
        status(S.route3_wing_capture_status)
        return false
    end
    local started = tonumber(S.route3_wing_capture_started_at) or now
    local sample_from = tonumber(S.route3_wing_capture_sample_from) or started
    if now < sample_from then
        S.route3_wing_capture_status = string.format("capture settling %.2fs", sample_from - now)
        return true
    end
    local elapsed = now - started
    local seconds = math.max(0.1, tonumber(C.route3_wing_capture_seconds) or 1.25)
    local interval = math.max(0.01, tonumber(C.route3_wing_capture_sample_interval) or 0.04)
    if now - (tonumber(S.route3_wing_capture_last_sample) or 0.0) >= interval then
        if not S.route3_wing_capture_names or #S.route3_wing_capture_names == 0 then
            S.route3_wing_capture_names = route3_wing_capture_names(tf)
        end
        if not S.route3_wing_capture_baseline then
            local baseline, baseline_hits = route3_read_wing_capture_sample(tf, S.route3_wing_capture_names or route3_wing_capture_names(tf))
            if baseline_hits > 0 then S.route3_wing_capture_baseline = baseline end
        end
        local sample, hits = route3_read_wing_capture_sample(tf, S.route3_wing_capture_names or route3_wing_capture_names(tf))
        S.route3_wing_capture_last_sample = now
        if hits > 0 then
            table.insert(S.route3_wing_capture_samples, { t = elapsed, joints = sample, raw_hits = hits })
        end
    end
    if elapsed < seconds then
        S.route3_wing_capture_status = string.format(
            "capturing %.2f/%.2fs samples=%d",
            elapsed,
            seconds,
            #(S.route3_wing_capture_samples or {})
        )
        return true
    end

    S.route3_wing_capture_active = false
    local out = {
        time = os.date("%Y-%m-%d %H:%M:%S"),
        mode = "exact-local-posrot-v1",
        source = motion_tag(C.route3_wing_capture_bank, C.route3_wing_capture_motion),
        duration = seconds,
        joints = S.route3_wing_capture_names or route3_wing_capture_names(tf),
        baseline_hits = S.route3_wing_capture_baseline and table_count(S.route3_wing_capture_baseline) or 0,
        samples = S.route3_wing_capture_samples or {},
    }
    route3_close_wing_capture_loop(out)
    pcall(function() json.dump_file(MOD .. "_wing_capture.json", out) end)
    S.route3_wing_capture_data = out
    S.route3_wing_capture_status = string.format("captured %d wing frames -> %s_wing_capture.json", #(out.samples or {}), MOD)
    status(S.route3_wing_capture_status)
    return true
end

function route3_wing_replay_auto_tick(now)
    if C.route3_wing_replay_auto ~= true then return false end
    if C.route3_native_flight_anim == true then return false end
    if S.airborne ~= true then return false end
    if C.route3_wing_replay_enabled == true then return false end
    if S.route3_wing_replay_user_stopped == true then return false end
    if S.route3_wing_replay_auto_failed == true then return false end
    now = now or os.clock()
    -- let the one-shot takeoff clip finish before the captured flap takes over
    if now < (tonumber(S.route3_air_visual_block_until) or 0.0) then return false end
    if not route3_enable_captured_wing_replay() then
        S.route3_wing_replay_auto_failed = true
        S.route3_wing_replay_status = "auto flap unavailable: no captured wing data"
        return false
    end
    S.route3_wing_replay_status = "auto flap engaged"
    return true
end

function route3_flap_after_action()
    -- POST-ACTION FLAP HYGIENE (the double-flap fix), callable from EVERY special-action exit.
    -- The regression: only the dive bomb's exit ran this (via restore_flight_base); the grab's
    -- throw/drop/eat exits never did -> stale flap state -> the double flap came back on drops.
    if S.airborne == true then
        route3_restore_flight_base()   -- glide back on base + overlay/phase reset
    else
        pcall(function() route3_flap_clear_overlay() end)
        S.route3_flap_phase = nil
        S.route3_soar_dir_clip = nil
    end
end
