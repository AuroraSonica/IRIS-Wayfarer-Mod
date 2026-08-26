-- Species-profile persistence for the shared I.R.I.S. mount engine.
--
-- The store owns file I/O, capture and application. Species-specific migration
-- rules remain at the call site for this extraction step; after an in-game
-- smoke test those rules can move into the declarative species adapters.

local M = {}

-- Exact compatibility schema used by GriffinRideProbe (IRIS). Keeping this
-- list intact preserves the existing JSON shape while the entry point is split.
M.compatibility_keys = {
    "flap_takeoff_clip", "flap_seg_start", "flap_seg_end", "flap_glide_clip",
    "flap_clip_loops", "flap_loop_seconds",
    "takeoff_motion", "landing_motion", "landing_end_motion",
    "route3_jump_clip_start", "route3_jump_clip_mid", "route3_jump_clip_fall", "route3_jump_clip_land", "route3_landing_descent_clip",
    "route3_jump_native_bank", "route3_jump_native_clip",
    "flap_glide_bank", "route3_rise_node_up", "route3_rise_node_down",
    "route3_rise_node_gearbox_distance",
    "route3_rise_ascend_clip", "route3_rise_ascend_start_clip",
    "route3_rise_descend_clip", "route3_rise_descend_start_clip", "route3_rise_clip_bank",
    "route3_ground_jump_windup", "route3_rise_secs", "route3_pawn_ride_back",
    "route3_rise_retire_at_window", "route3_loopcam_dist", "route3_soar_directional",
    "route3_flap_blend_frames", "route3_allow_sprint", "route3_allow_flight",
    "route3_mountable",
    "route3_drake_bite_lock_reach", "route3_drake_bite_follow_max",
    "route3_drake_bite_follow_speed", "route3_drake_bite_neck_x_deg",
    "route3_drake_bite_neck_y_deg", "route3_drake_bite_neck_z_deg",
    "route3_drake_bite_height_axis", "route3_drake_bite_height_sign",
    "route3_drake_bite_pitch_strength", "route3_drake_bite_pitch_preview",
    "route3_drake_fire_cam_height", "route3_drake_fire_cam_look_height",
    "route3_drake_fire_cam_dist", "route3_drake_fire_cam_side_deg",
    "route3_drake_air_fire_cam_height", "route3_drake_air_fire_cam_look_height",
    "route3_drake_air_fire_cam_dist", "route3_drake_air_fire_cam_side_deg",
    "route3_drake_fire_aim_x_gain", "route3_drake_fire_aim_y_gain",
    "route3_drake_fire_aim_z_gain", "route3_drake_fire_aim_cap_deg",
    "route3_drake_fire_aim_strength",
    "route3_drake_air_fire_aim_x_gain", "route3_drake_air_fire_aim_y_gain",
    "route3_drake_air_fire_aim_z_gain", "route3_drake_air_fire_aim_cap_deg",
    "route3_drake_air_fire_aim_strength",
    "route3_drake_magic_cam_side_deg", "route3_drake_magic_cam_dist",
    "route3_drake_magic_cam_height", "route3_drake_magic_cam_look_height",
    "route3_drake_camera_scenery_swap", "route3_drake_ground_sprint_speed_scale",
    "route3_drake_sprint_hitbox", "route3_drake_sprint_damage_scale",
    "route3_drake_turn180_enabled", "route3_drake_turn180_left_clip",
    "route3_drake_turn180_right_clip", "route3_drake_turn180_secs",
    "route3_drake_turn180_motion_speed", "route3_drake_turn_charge_fix_version",
    "route3_drake_tail_turn_left_clip", "route3_drake_tail_turn_right_clip",
    "route3_drake_tail_turn_secs",
    "route3_drake_mute_magic_voice", "route3_drake_air_y_variant",
    "route3_seat_offset_x", "route3_seat_offset_y", "route3_seat_offset_z",
    "route3_air_seat_joint", "route3_air_seat_offset_x", "route3_air_seat_offset_y", "route3_air_seat_offset_z",
    "route3_air_seat_frame_v",
    "route3_air_seat",
    "spawn_scale", "route3_landing_height_offset",
    "root_motion_walk", "root_motion_run", "root_motion_run_bank", "root_motion_idle", "idle_motion",
}

local function set_status(options, value)
    if type(options.on_status) == "function" then
        options.on_status(value)
    elseif type(options.state) == "table" then
        options.state[options.status_field or "profile_status"] = value
    end
end

function M.new(options)
    assert(type(options) == "table", "profile store options must be a table")
    assert(type(options.json) == "table", "profile store requires a json API")
    assert(type(options.path) == "string" and options.path ~= "", "profile store requires a path")
    assert(type(options.config) == "table", "profile store requires a config table")
    assert(type(options.keys) == "table", "profile store requires a key schema")

    local store = {}

    function store:resolve_key(key)
        if not key and type(options.current_key) == "function" then
            key = options.current_key()
        end
        return tostring(key or "")
    end

    function store:load_all()
        local all = nil
        pcall(function() all = options.json.load_file(options.path) end)
        return all
    end

    function store:write_all(all)
        pcall(function() options.json.dump_file(options.path, all) end)
    end

    function store:save(key)
        key = self:resolve_key(key)
        local all = self:load_all() or {}
        local profile = {}
        for _, field in ipairs(options.keys) do profile[field] = options.config[field] end
        all[key] = profile
        self:write_all(all)
        set_status(options, "saved profile: " .. key)
        return true
    end

    function store:open(key)
        key = self:resolve_key(key)
        local all = self:load_all()
        local profile = all and all[key]
        if not profile then
            set_status(options, "no saved profile for " .. key .. " (using current tuning)")
            return all, nil, key
        end
        return all, profile, key
    end

    function store:finish(all, profile, key, migrated)
        for _, field in ipairs(options.keys) do
            if profile[field] ~= nil then options.config[field] = profile[field] end
        end
        if migrated then self:write_all(all) end
        set_status(options, "applied profile: " .. tostring(key))
        return true
    end

    function store:apply(key)
        local all, profile
        all, profile, key = self:open(key)
        if not profile then return false end
        local migrated = false
        if type(options.migrate) == "function" then
            migrated = options.migrate(key, profile, options.config) == true
        end
        return self:finish(all, profile, key, migrated)
    end

    return store
end

return M
