-- Declarative Griffin adapter for the shared I.R.I.S. mount engine.
-- Behaviour remains in the legacy entry point during the staged extraction;
-- this file only answers identity and capability questions.

return {
    id = "griffin",
    display_name = "Griffin",
    chassis = { "ch253" },
    capabilities = {
        mountable = true,
        flight = true,
        mounted_combat = true,
        passenger = true,
        aerial_hit_reaction = true,
    },
    -- Binding metadata belongs to the Griffin adapter.  Mode and edge ownership
    -- deliberately do not: the established action state machines still decide
    -- when a held binding becomes a press and whether that press is eligible.
    bindings = {
        dive_bomb = {
            buttons_key = "route3_divebomb_buttons",
            key_key = "route3_divebomb_key",
        },
        dogfight = {
            buttons_key = "route3_dogfight_buttons",
            key_key = "route3_dogfight_key",
        },
        air_gust = {
            buttons_key = "route3_gustair_buttons",
            key_key = "route3_gust_key",
            compact_buttons = true,
        },
        air_press = {
            buttons_key = "route3_airpress_buttons",
            key_key = "route3_airpress_key",
            compact_buttons = true,
        },
        loop = {
            buttons_key = "route3_rise_buttons",
            key_key = "route3_rise_key",
            compact_buttons = true,
        },
        ground_gust = {
            buttons_key = "route3_gust_buttons",
            key_key = "route3_gust_key",
            blank_buttons = "west,square",
            compact_buttons = true,
        },
        ground_attack = {
            buttons_key = "route3_gatk_buttons",
            key_key = "route3_gatk_key",
            blank_buttons = "north,triangle",
            compact_buttons = true,
        },
        grab = {
            buttons_key = "route3_grab_buttons",
            key_key = "route3_grab_key",
        },
        eat = {
            buttons = "r2",
            default_key = 0x45,
        },
    },
    actions = {
        air = {
            Y = { id = "grab", label_key = "route3_hud_Y" },
            X = { id = "dive_bomb", label_key = "route3_hud_X" },
            A = { id = "loop", label_key = "route3_hud_A" },
            B = { id = "soar", label_key = "route3_hud_B" },
            L1 = { id = "descend", label_key = "route3_hud_L1" },
            L2 = { id = "air_gust", label_key = "route3_hud_L2" },
            R1 = { id = "ascend", label_key = "route3_hud_R1" },
            R2 = { id = "dogfight", label_key = "route3_hud_R2" },
        },
        ground = {
            Y = { id = "ground_attack", label_key = "route3_hudg_Y" },
            X = { id = "ground_gust", label_key = "route3_hudg_X" },
            A = { id = "take_off", label_key = "route3_hudg_A" },
            B = { id = "sprint", label_key = "route3_hudg_B" },
            L1 = { id = "ground_left_bumper", label_key = "route3_hudg_L1" },
            L2 = { id = "ground_left_trigger", label_key = "route3_hudg_L2" },
            R1 = { id = "take_off", label_key = "route3_hudg_R1" },
            R2 = { id = "eat", label_key = "route3_hudg_R2" },
        },
        charge_override = true,
        carrying_override = true,
        ground_eat_override = true,
    },
}
