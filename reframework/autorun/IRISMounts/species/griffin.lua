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
    actions = {
        air = {
            Y = { id = "grab", label_key = "route3_hud_Y" },
            X = { id = "dive_bomb", label_key = "route3_hud_X" },
            A = { id = "loop", label_key = "route3_hud_A" },
            B = { id = "soar", label_key = "route3_hud_B" },
            L1 = { id = "descend", label_key = "route3_hud_L1" },
            L2 = { id = "air_special", label_key = "route3_hud_L2" },
            R1 = { id = "ascend", label_key = "route3_hud_R1" },
            R2 = { id = "air_heavy", label_key = "route3_hud_R2" },
        },
        ground = {
            Y = { id = "grab_or_charge", label_key = "route3_hudg_Y" },
            X = { id = "gale", label_key = "route3_hudg_X" },
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
