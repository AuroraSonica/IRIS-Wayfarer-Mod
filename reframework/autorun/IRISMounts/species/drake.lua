-- Drake adapter for the shared I.R.I.S. mount engine.
-- Identity, capabilities, bindings and mounted combat payloads live here;
-- generic attack execution remains owned by the runtime and is injected below.

local adapter = {
    id = "drake",
    display_name = "Drake",
    chassis = { "ch257" },
    capabilities = {
        mountable = true,
        flight = true,
        mounted_combat = true,
        passenger = true,
        aerial_hit_reaction = true,
        native_grab_rider = true,
        native_breath = true,
    },
    actions = {
        combat_priority = { "X", "L2", "R2", "Y" },
        air = {
            Y = { id = "grand_magic", label = function(C)
                return math.floor(tonumber(C.route3_drake_air_y_variant) or 1) == 1
                    and "Grand Magic" or "Hover Breath"
            end },
            X = { id = "forward_breath", label = "Forward Breath" },
            A = { id = "quick_rise", label = "Quick Rise" },
            B = { id = "soar", label = "Soar" },
            L1 = { id = "descend", label = "Descend" },
            L2 = { id = "hover_magic_1", label = "Hover Magic I" },
            R1 = { id = "ascend", label = "Ascend" },
            R2 = { id = "hover_magic_2", label = "Hover Magic II" },
        },
        ground = {
            Y = { id = "bite_combo", label = "Bite" },
            X = { id = "ground_breath", label = function(C)
                return math.floor(tonumber(C.route3_drake_ground_x_variant) or 1) == 2
                    and "Forward Breath" or "Flame Cleave"
            end },
            A = { id = "jump", label = "Jump" },
            B = { id = "sprint", label = "Sprint" },
            L1 = { id = "ground_left_bumper", label = "" },
            L2 = { id = "back_jump_breath", label = "Back-Jump Breath" },
            R1 = { id = "ground_right_bumper", label = "" },
            R2 = { id = "tail_cleave", label = "Tail Cleave" },
        },
        carrying_override = true,
        ground_eat_override = false,
    },
}

-- Drake owns the meaning and authored payload of its combat actions. The
-- runtime supplies the two generic executors so this adapter never reaches
-- into the entry point through inherited globals.
function adapter.create_action_handlers(runtime)
    assert(type(runtime) == "table", "Drake action runtime must be a table")
    local C = assert(runtime.config, "Drake action runtime requires config")
    local route3_drake_attack_start = assert(runtime.attack_start,
        "Drake action runtime requires attack_start")
    local route3_drake_motion_attack_start = assert(runtime.motion_attack_start,
        "Drake action runtime requires motion_attack_start")
    return {
        forward_breath = function(cam)
            -- Restore the field-proven baseline. It has a brief grounded pose at the fire beat,
            -- but it is the one aerial breath Aurora confirmed actually produces a usable stream.
            return route3_drake_attack_start(C.route3_drake_air_x_node, "Forward Breath", 5.2,
                "Fly.HoverAttack.Ch257_HoverBreathF_End", 3.5,
                { prime_node = "Fly.Hovering.HoverToFly", prime_secs = 0.18,
                    reach = 40.0, width = 30.0, vertical = 40.0,
                    aim_deg = 180.0, fire_track = true,
                    cam_fixed = true, cam_stabilise = true,
                    cam_side_deg = cam.air_fire_cam_side,
                    cam_dist = cam.air_fire_cam_dist, cam_height = cam.air_fire_cam_height,
                    cam_look_height = cam.air_fire_cam_look, cam_y_bias = 0.35,
                    cam_bias = 0.62 })
        end,
        ground_breath = function(cam)
            local ground_x_variant = math.max(1, math.min(2,
                math.floor(tonumber(C.route3_drake_ground_x_variant) or 1)))
            if ground_x_variant == 2 then
                -- This is the Drake's authored straight-ahead ground stream,
                -- not the aerial hover breath painted onto a grounded body.
                return route3_drake_attack_start(C.route3_drake_ground_forward_node,
                    "Forward Ground Breath", 5.2,
                    C.route3_drake_ground_forward_end_node, 3.5,
                    { prime_node = "Fly.Hovering.HoverToFly", prime_secs = 0.18,
                        reach = 40.0, width = 30.0, vertical = 30.0,
                        aim_deg = 180.0, fire_track = true,
                        cam_fixed = true, cam_stabilise = true,
                        cam_side_deg = cam.ground_fire_cam_side,
                        cam_dist = cam.ground_fire_cam_dist,
                        cam_height = cam.ground_fire_cam_height,
                        cam_look_height = cam.ground_fire_cam_look,
                        cam_bias = 0.62 })
            end
            return route3_drake_motion_attack_start("Flame Cleave", {
                { label = "Flame Cleave", bank = 50, clip = 17, secs = 4.2,
                    -- A clip alone can draw flame while owning no native damage
                    -- transaction. Request its real action node first, then keep
                    -- the proven clip paint so the authored cleave remains visible.
                    node = C.route3_drake_ground_x_node,
                    joints = { "Jaw_0" }, reach = 20.0, fire_track = true,
                    prime_node = "Fly.Hovering.HoverToFly", prime_secs = 0.18,
                    visual_reassert = true, reassert_after = 0.25,
                    cam_side_deg = cam.ground_fire_cam_side, cam_dist = cam.ground_fire_cam_dist,
                    cam_height = cam.ground_fire_cam_height, cam_look_height = cam.ground_fire_cam_look,
                    cam_bias = 0.62 },
            })
        end,
        hover_magic_1 = function(cam)
            -- Atlas truth: 137/138/139 are the authored hover-small-magic
            -- start/LOOP/end triplet. The node-only probe omitted 138 and the
            -- action graph quite correctly fell back to grounded Wait.
            return route3_drake_motion_attack_start("Hover Magic I (native payload probe)", {
                { label = "Hover Magic I: wind-up", bank = 50, clip = 137, secs = 3.0,
                    auto_advance = true, link_frac = 0.94, link_secs = 2.75,
                    prime_node = "Fly.Hovering.HoverToFly", prime_secs = 0.18,
                    reach = 40.0, cam_fixed = true, cam_stabilise = true,
                    cam_subject = "drake", cam_side_deg = cam.magic_cam_side,
                    cam_dist = cam.magic_cam_dist, cam_height = cam.magic_cam_height,
                    cam_look_height = cam.magic_cam_look, cam_y_bias = 0.0, cam_bias = 0.0 },
                { label = "Hover Magic I: channel", bank = 50, clip = 138, secs = 2.2,
                    auto_advance = true, link_frac = 0.94, link_secs = 1.8,
                    reach = 40.0, cam_fixed = true, cam_stabilise = true,
                    cam_subject = "drake", cam_side_deg = cam.magic_cam_side,
                    cam_dist = cam.magic_cam_dist, cam_height = cam.magic_cam_height,
                    cam_look_height = cam.magic_cam_look, cam_y_bias = 0.0, cam_bias = 0.0 },
                { label = "Hover Magic I: release", bank = 50, clip = 139, secs = 2.4,
                    reach = 40.0, cam_fixed = true, cam_stabilise = true,
                    cam_subject = "drake", cam_side_deg = cam.magic_cam_side,
                    cam_dist = cam.magic_cam_dist, cam_height = cam.magic_cam_height,
                    cam_look_height = cam.magic_cam_look, cam_y_bias = 0.0, cam_bias = 0.0 },
            })
        end,
        back_jump_breath = function(cam)
            -- The node owns the native payload; clip 30 immediately paints the
            -- proper jump choreography over the generic grounded fire pose that
            -- the action graph otherwise selected under rider control.
            return route3_drake_motion_attack_start("Back-Jump Breath", {
                { label = "Back-Jump Breath", bank = 50, clip = 30, secs = 4.8,
                    -- Preserve clip 30's jump choreography, but let the native
                    -- BackJumpBreath action own the fire emitter and damage data.
                    node = C.route3_drake_ground_l2_node,
                    joints = { "Jaw_0" }, reach = 20.0, fire_track = true,
                    prime_node = "Fly.Hovering.HoverToFly", prime_secs = 0.18,
                    visual_reassert = true, reassert_after = 0.25,
                    cam_side_deg = cam.ground_fire_cam_side, cam_dist = cam.ground_fire_cam_dist,
                    cam_height = cam.ground_fire_cam_height, cam_look_height = cam.ground_fire_cam_look,
                    cam_bias = 0.62 },
            })
        end,
        hover_magic_2 = function(cam)
            return route3_drake_motion_attack_start("Hover Magic II (native payload probe)", {
                { label = "Hover Magic II: wind-up", bank = 50, clip = 140, secs = 3.0,
                    auto_advance = true, link_frac = 0.94, link_secs = 2.75,
                    prime_node = "Fly.Hovering.HoverToFly", prime_secs = 0.18,
                    reach = 40.0, cam_fixed = true, cam_stabilise = true,
                    cam_subject = "drake", cam_side_deg = cam.magic_cam_side,
                    cam_dist = cam.magic_cam_dist, cam_height = cam.magic_cam_height,
                    cam_look_height = cam.magic_cam_look, cam_y_bias = 0.0, cam_bias = 0.0 },
                { label = "Hover Magic II: channel", bank = 50, clip = 141, secs = 2.2,
                    auto_advance = true, link_frac = 0.94, link_secs = 1.8,
                    reach = 40.0, cam_fixed = true, cam_stabilise = true,
                    cam_subject = "drake", cam_side_deg = cam.magic_cam_side,
                    cam_dist = cam.magic_cam_dist, cam_height = cam.magic_cam_height,
                    cam_look_height = cam.magic_cam_look, cam_y_bias = 0.0, cam_bias = 0.0 },
                { label = "Hover Magic II: release", bank = 50, clip = 142, secs = 2.4,
                    reach = 40.0, cam_fixed = true, cam_stabilise = true,
                    cam_subject = "drake", cam_side_deg = cam.magic_cam_side,
                    cam_dist = cam.magic_cam_dist, cam_height = cam.magic_cam_height,
                    cam_look_height = cam.magic_cam_look, cam_y_bias = 0.0, cam_bias = 0.0 },
            })
        end,
        tail_cleave = function()
            return route3_drake_motion_attack_start("Tail Cleave", {
                { label = "Tail Cleave 180", bank = 50,
                    clip = math.floor(tonumber(C.route3_drake_tail_turn_right_clip) or 955),
                    turn_clips = {
                        left = math.floor(tonumber(C.route3_drake_tail_turn_left_clip) or 950),
                        right = math.floor(tonumber(C.route3_drake_tail_turn_right_clip) or 955),
                    },
                    secs = math.max(1.0, tonumber(C.route3_drake_tail_turn_secs) or 3.5),
                    joints = {}, reach = 24.0, width = 24.0, vertical = 16.0,
                    rear_aim = true, aim_secs = 1.15 },
            })
        end,
        grand_magic = function(cam)
            if math.floor(tonumber(C.route3_drake_air_y_variant) or 1) == 1 then
                -- Unused large airborne spell: the atlas maps HoverMagicL to
                -- the dedicated hover-big triplet 146/147/148. This is genuinely
                -- distinct from Forward Breath and from LT/RT's two small spells.
                return route3_drake_motion_attack_start("Hover Magic L (Grand)", {
                    { label = "Hover Magic L: wind-up", bank = 50, clip = 146, secs = 3.6,
                        auto_advance = true, link_frac = 0.94, link_secs = 3.2,
                        prime_node = "Fly.Hovering.HoverToFly", prime_secs = 0.18,
                        reach = 45.0, cam_fixed = true, cam_stabilise = true,
                        cam_subject = "drake", cam_side_deg = cam.magic_cam_side,
                        cam_dist = cam.magic_cam_dist, cam_height = cam.magic_cam_height,
                        cam_look_height = cam.magic_cam_look, cam_y_bias = 0.0, cam_bias = 0.0 },
                    { label = "Hover Magic L: channel", bank = 50, clip = 147, secs = 3.0,
                        auto_advance = true, link_frac = 0.94, link_secs = 2.5,
                        reach = 45.0, cam_fixed = true, cam_stabilise = true,
                        cam_subject = "drake", cam_side_deg = cam.magic_cam_side,
                        cam_dist = cam.magic_cam_dist, cam_height = cam.magic_cam_height,
                        cam_look_height = cam.magic_cam_look, cam_y_bias = 0.0, cam_bias = 0.0 },
                    { label = "Hover Magic L: release", bank = 50, clip = 148, secs = 3.2,
                        reach = 45.0, cam_fixed = true, cam_stabilise = true,
                        cam_subject = "drake", cam_side_deg = cam.magic_cam_side,
                        cam_dist = cam.magic_cam_dist, cam_height = cam.magic_cam_height,
                        cam_look_height = cam.magic_cam_look, cam_y_bias = 0.0, cam_bias = 0.0 },
                })
            end
            -- The full HoverBreath node drops to grounded Wait and emits no
            -- flame when rider-requested. Direct clip 102 is the field-proven
            -- native downward burst, retained as the selectable fallback.
            return route3_drake_motion_attack_start("Hover Breath (short downward burst)", {
                { label = "Hover Breath", bank = 50, clip = 102, secs = 4.6,
                    joints = { "Jaw_0" }, reach = 40.0, width = 30.0,
                    vertical = 40.0, aim_deg = 180.0, fire_track = true,
                    cam_fixed = true, cam_stabilise = true,
                    prime_node = "Fly.Hovering.HoverToFly", prime_secs = 0.18,
                    visual_reassert = true, reassert_after = 0.25,
                    cam_side_deg = cam.air_fire_cam_side, cam_dist = cam.air_fire_cam_dist,
                    cam_height = cam.air_fire_cam_height,
                    cam_look_height = cam.air_fire_cam_look,
                    cam_y_bias = 0.35, cam_bias = 0.55 },
            })
        end,
        bite_combo = function()
            -- Bestiary's own Drake sequence: BiteR -> BiteL -> native three-bite finisher.
            -- A further Y press buffers each link, exactly like the wolf combo.
            return route3_drake_motion_attack_start("Bite Combo", {
                { label = "Bite R", bank = 50, clip = 6, secs = 1.75,
                    link_frac = 0.72, joints = { "Jaw_0" },
                    reach = tonumber(C.route3_drake_bite_lock_reach) or 28.0,
                    width = 24.0, vertical = 22.0,
                    contact_assist = true, approach_stop = 0.42,
                    approach_max = tonumber(C.route3_drake_bite_follow_max) or 8.0,
                    approach_secs = 1.0,
                    approach_speed = tonumber(C.route3_drake_bite_follow_speed) or 14.0,
                    contact_follow = true, follow_stop = 0.12,
                    follow_max = tonumber(C.route3_drake_bite_follow_max) or 8.0,
                    follow_secs = 1.30,
                    follow_speed = tonumber(C.route3_drake_bite_follow_speed) or 14.0,
                    head_track = true, head_track_secs = 1.30, head_track_cap_deg = 55.0,
                    collider_scale = tonumber(C.route3_drake_bite_collider_scale) or 1.85 },
                { label = "Bite L", bank = 50, clip = 5, secs = 1.75,
                    link_frac = 0.72, joints = { "Jaw_0" },
                    reach = tonumber(C.route3_drake_bite_lock_reach) or 28.0,
                    width = 24.0, vertical = 22.0,
                    contact_assist = true, approach_stop = 0.42,
                    approach_max = tonumber(C.route3_drake_bite_follow_max) or 8.0,
                    approach_secs = 1.0,
                    approach_speed = tonumber(C.route3_drake_bite_follow_speed) or 14.0,
                    contact_follow = true, follow_stop = 0.12,
                    follow_max = tonumber(C.route3_drake_bite_follow_max) or 8.0,
                    follow_secs = 1.30,
                    follow_speed = tonumber(C.route3_drake_bite_follow_speed) or 14.0,
                    head_track = true, head_track_secs = 1.30, head_track_cap_deg = 55.0,
                    collider_scale = tonumber(C.route3_drake_bite_collider_scale) or 1.85 },
                { label = "Bite finisher", bank = 50, clip = 3, secs = 3.8,
                    joints = { "Jaw_0" },
                    reach = tonumber(C.route3_drake_bite_lock_reach) or 28.0,
                    width = 24.0, vertical = 22.0,
                    contact_assist = true, approach_stop = 0.42,
                    approach_max = tonumber(C.route3_drake_bite_follow_max) or 8.0,
                    approach_secs = 1.0,
                    approach_speed = tonumber(C.route3_drake_bite_follow_speed) or 14.0,
                    contact_follow = true, follow_stop = 0.12,
                    follow_max = tonumber(C.route3_drake_bite_follow_max) or 8.0,
                    follow_secs = 1.55,
                    follow_speed = tonumber(C.route3_drake_bite_follow_speed) or 14.0,
                    head_track = true, head_track_secs = 1.55, head_track_cap_deg = 55.0,
                    collider_scale = tonumber(C.route3_drake_bite_collider_scale) or 1.85 },
            }, "Y")
        end,
    }
end

return adapter
