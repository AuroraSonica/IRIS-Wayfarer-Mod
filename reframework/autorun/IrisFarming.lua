-- IrisFarming.lua - homestead GARDENING / FARMING  (slice 2 rewrite, 2026-07-24, Iris for Aurora)
-- ============================================================================================
-- STARDEW RULES, DD2 BODY. Rewritten from the numpad prototype after Aurora's call: "numkeys
-- don't really work, we have the whole homestead process to crib" + "water a crop once per day".
--
--   HOE in hand, stand on your plot  -> prompt: TILL  -> the growth is cleared to bare earth
--   stand at a tilled bed            -> prompt: SOW   -> NATIVE dialog picks the seed
--   stand at a sown bed              -> prompt: WATER -> once per IN-GAME DAY
--   a day passes WATERED             -> the crop advances one day of growth
--   a day passes DRY                 -> no growth, and the dry streak climbs: WILT then DEATH
--   ripe                             -> prompt: HARVEST -> grade depends on how you tended it
--
-- ⭐ ONE context-sensitive interact key, exactly like walking up to the deed sign. No key per
--    action, no numpad. The prompt tells you what the button does where you're standing.
-- ⭐ TIME IS IN-GAME DAYS (app.TimeManager get_InGameDay) - sleep/rest advances the farm, not a
--    wall-clock stopwatch. Watering is once-per-day and REQUIRED for that day to count.
--
-- Cribbed wholesale (no new engine tech): native dialog = IrisDeedSign (reqDisp/getDialogState,
-- RetVal None=0 Sel0=1 Sel1=2 Sel2=3 Sel3=4 Cancel=5); prop spawn = IrisFurnish (GenerateManager,
-- setInitialAngle-ONLY); till-the-earth = IrisHomestead's foliage hide; hide RE-ASSERT = the
-- 07-24 wild-tree despawn lesson; item grant = IrisWoodcutting; tool-in-hand = the wp child scan.
--
-- SEEDS: virtual bag today. Every crop row has `seed_item` - set it to a real Content Editor item
-- id and that crop instantly sources from the REAL inventory instead. That's the only change
-- needed when Aurora authors the seed items + icons.
-- ============================================================================================

local M = {
    enabled      = true,
    -- ── interaction (Aurora 07-25, second pass: "instead of having the hoe bring up a menu...
    --    put something on the ground to make it look like a dirt mound, then press B to select a
    --    seed to put in it and then have the option to water it").
    --    So: the HOE ONLY TILLS. Everything else is the tend button at a finished bed. ──
    tend_key     = 0x45,     -- keyboard E: sow / water / harvest at the bed you're stood at
    -- ⛔ THE LABEL LIED (Aurora 08-04: "the label says E/B, but it's A on the controller that
    -- brings the menu up"). She was right, and the BUTTON was never the bug - the NAME was.
    -- via.hid.GamePadButton has NO field called "B"; the resolver's fallback chain quietly walked
    -- past it to "RDown", which on an Xbox pad IS the A button. So the accident landed on exactly
    -- the right key - A is DD2's own interact/confirm - while the label advertised B, which is
    -- dodge/cancel and would have fought the game. Now the engine field is named honestly and the
    -- label is derived from it, so the two can never drift apart again.
    -- ⭐ MOVED TO B 08-09 (Aurora): B is DD2's own interact button, so our prompts now
    --   match every native one. Resolved through _G.IrisPad, which logs the REAL field
    --   list once - there is no field literally called "B", which is how this module
    --   spent weeks advertising a button it was not reading.
    tend_pad     = "Cancel",
    block_dodge  = true,     -- B is also dodge/dash; suppress it while stood at a bed
    -- ⛔ KEYED ON via.hid.GamePadButton FIELD NAMES, and the SEMANTIC ones are real fields too.
    --   `tend_pad = "Cancel"` resolved perfectly (no "not a field" line in the log) but there was
    --   no Cancel row here, so every prompt fell through to `or n` and printed the raw enum name:
    --   "[E / Cancel]  Water the Potato". The button was right; only the letter was wrong.
    pad_labels   = { RDown = "A", RRight = "B", RLeft = "X", RUp = "Y",
                     LDown = "D-Down", LUp = "D-Up", LLeft = "D-Left", LRight = "D-Right",
                     Decide = "A", Cancel = "B", Sub1 = "X", Sub2 = "Y",
                     Select = "A", Back = "B" },
    debug_key    = 0,        -- optional VK to fire a HOE strike without a hoe while testing
    hud          = false,    -- on-screen status line: off; the bed and crop show their own state
    ring         = true,     -- the ground ring showing exactly where a hoe swing will land
    bed_prompt   = true,     -- ⭐ world-space label over the bed you're stood at, naming the one
                             -- action available ("[E / B] Plant seeds"). NOT the old top-left nag.
    prompt_height = 0.9,     -- metres above the bed to float the label
    ui_grace     = 0.6,      -- seconds after the REF overlay closes in which a swing won't till
    -- ⭐ RAIN WATERS THE FARM. rain_looks is keyed BY LOOK ID; 4/5 are RiftSpeak's storm ids
    -- and are a GUESS until the weather probe names the real one in the log (see _rain_tick).
    rain_water   = true,
    rain_looks   = { [4] = true, [5] = true },
    -- ⭐ A IS ALSO JUMP. While you're stood on a bed (within act_radius) or our menu is open, the
    -- jump input is eaten so an interact doesn't hop. Positional, not keypress-driven - see the
    -- hook. Off = you'll jump every time you tend.
    -- ⛔ OFF (Aurora 08-09: "disable the jump suppression on all the interactables now that we
    --   use B instead of A"). Jump is A; our interact moved to B, so eating A no longer buys
    --   anything and only takes a control away from the player while they stand at a bed.
    -- ⚠ block_dodge STAYS ON: B *is* dodge/dash, so that collision is real and still needs it.
    block_jump   = false,
    -- ⭐ NO FARMING INDOORS (Aurora 08-04: "I was able to make farmland inside the actual house").
    -- Detected by casting UP, so it covers every interior in the game, not just a house she built.
    block_indoors = true,
    roof_height  = 6.0,      -- a ceiling within this many metres = indoors. ⭐ 6, not the 4 this
                             -- shipped with - Aurora field-tested both: "4 was too lenient".
                             -- Raise further if a real outdoor spot under an arch is refused.
    -- ── the tilled-earth marker ──
    -- ⛔ OFF BY DEFAULT (Aurora 07-26): gm51_573 "Burial mound" is not a heap of soil, it's a
    -- cluster of HUGE BOULDERS, and it ignored ScaleRate entirely - nine of them spawned around
    -- the homestead and trapped her inside. Never enable a mound prop that hasn't been eyeballed
    -- in-game first, and use "DESTROY mounds nearby" in the panel to clear a bad one.
    mound_show   = true,        -- ✅ the custom mesh now ships in re_chunk_000.pak.patch_047.pak
    -- ⭐ CUSTOM MESH (Aurora's Rodin/Blender seed bed), pak path WITHOUT the extension - the
    -- griffin egg's convention. Set to "" to fall back to the gimmick prop below.
    mound_mesh   = "custom_tex/iris/farmland",
    -- ⭐ BACK ON (2026-08-08). I disabled this after a CTD and Aurora corrected me: the pot
    -- jack had already worked repeatedly, and the campfire's cooking is a CUTSCENE, so there
    -- is no clip to steal instead. Her field evidence beats my caution.
    -- ⚠ I then guessed the RECIPE was at fault (Omelette outputs 34725, a custom Content
    -- Editor item) — Aurora says she has cooked it successfully before, so that is out too.
    -- ⇒ TWO wrong theories in a row means STOP THEORISING. The grant is now announced in the
    -- log BEFORE it happens, which splits the remaining possibilities cleanly:
    --   crash BEFORE "about to grant"  => the jack / animation path
    --   crash AFTER  "about to grant"  => the item grant
    -- Whatever else changed around it (native seats spawning, the camera pull) is in the same
    -- window and equally unproven. The log decides; nothing else has this session.
    -- ⛔⛔⛔ OFF ON EVIDENCE, NOT CAUTION (2026-08-08). The log ends INSIDE the native call,
    -- three times running, with the tape disabled so nothing of ours was in the way:
    --     jack_for: gm80_256 entry 'ActStart' for 10.0s
    --     ABOUT TO JACK: gm80_256 state='ActStart' fsm=true owner_valid=true
    --     <no "survived the jack call">
    -- ⇒ **jacking gm80_256 with ActStart is a hard CTD.** ActStart came from a generic entry
    -- ladder — it is a guess, and gm80_256's FSM evidently cannot take it. Do not re-enable
    -- this without a state name READ from the pot's own FSM.
    -- ⭐ THE RIGHT ROUTE FOR THE ANIMATION IS `changeMotion`, NOT A JACK: mount gm80_256's own
    -- motlist as a dynamic bank (8000+) and play the cooking clip resolved BY NAME — the
    -- proven Bestiary/Motion.lua recipe. No FSM is driven, so there is nothing to crash.
    cook_jack       = false,  -- ⛔ CTD - see above. changeMotion route instead.
    cook_anim       = true,   -- ⭐ the REAL cooking triad (bank 60: 1103 start/1104 loop/1105 end)
    cook_jack_secs  = 10.0,   -- how long the stirring runs before the dish appears
    mound_gid    = "gm50_097",  -- fallback only: Haystack. ⛔ gimmicks bring COLLISION with them
                                -- (that's what walled her in) - the mesh route has none.
    mound_scale  = 1.0,         -- the mesh is already authored at ~0.92 x 1.40m real size
    mound_tilt   = true,        -- ⭐ probe the 4 corners and TILT the bed to lie along the slope,
                                -- instead of one flat height that floats at one end and buries the other
    tilt_cap     = 35.0,        -- degrees; a bad probe shouldn't stand a bed on its end
    ground_probe = 3.0,         -- how far down to look for ground
    -- ⭐ +5cm IS THE ANSWER (Aurora 08-04, after testing the deepened mesh on many beds: "the
    -- farmland looks good as it is, but the bed+5cm option looks best on all of them"). It was a
    -- slider defaulting to nil/0, so every session started wrong and had to be nudged by hand.
    -- Now it's the shipped default. The slider stays for terrain that disagrees.
    mound_lift   = 0.05,
    mound_sink   = 0.0,         -- ⚠ back to 0: with the 4-corner fit the placed Y IS the ground,
                                -- and 6cm of extra sink on an 8.7cm-tall bed buried most of it.
                                -- Live slider in the panel; ~30% is already baked into the origin.
    -- ⭐⭐ THE SPROUT MESH (Aurora 08-04). A young crop is currently the FINISHED gather node at
    -- 18% scale, which makes a day-one apple a doll's-house apple tree. Her fix: use one of the
    -- pure scenery meshes the Vernworth probe turned up - the "corn" - scaled right down, so every
    -- crop reads as a generic green shoot until it's grown enough to become itself.
    -- ⛔ EMPTY UNTIL AUDITIONED. Three candidates came back from that probe with no gimmick and no
    -- prefab behind them; which one is the corn is a question only your eyes can answer:
    --     Environment/Props/sm8X/sm82/sm82_081/sm82_081_00   (x16 near the farm)
    --     Environment/Props/sm5X/sm51/sm51_543/sm51_543_00   (x36 - the leading suspect)
    --     Environment/Props/sm5X/sm50/sm50_079/sm50_079_00   (x55)
    -- Paste each into the panel's MESH AUDITIONER, look at it, then put the winner here.
    -- ✅ AURORA-EYEBALLED 08-04 ("make this small enough and it might just work"): sm82_009, the
    -- "Random plant" generic leafy mesh - the same plant the vegetables' own gather node shows,
    -- so the shoot grows INTO the thing it resembles. The audition law is satisfied.
    sprout_mesh  = "Environment/Props/sm8X/sm82/sm82_009/sm82_009_00",
    sprout_until = 0.85,     -- growth fraction below which the bed shows the shoot, not the plant.
                             -- ⭐ 0.85, not 0.5 (Aurora 08-05: "still making a full harvestable
                             -- plant on day 2/4") - the gather-node meshes carry RIPE BERRIES at
                             -- any scale, so no size tricks make them read as immature. The shoot
                             -- holds until nearly ripe; the real plant appears for the final
                             -- stretch and ripeness follows quickly.
    sprout_scale = 0.22,     -- the shoot's size at full sprout stage ("small enough": the mesh is
                             -- a ~1m bush at 1.0 - 0.22 reads as a hand-height seedling)
    sprout_rise  = 0.0,      -- nudge it up/down out of the bed
    -- ⭐ ROW BUILDING: the mesh's REAL footprint, so snapped patches butt up seamlessly
    bed_len      = 1.40,        -- along its facing
    bed_wid      = 0.95,        -- across
    snap         = true,        -- inherit a neighbour's angle + land on its grid
    snap_dist    = 3.0,         -- look this far for a bed to line up with
    yaw_step     = 90.0,        -- with nothing to snap to, square the angle to this step
    -- ── the tool ──
    hoe_weapon_id = 47220,   -- the CE hoe, bundle "IRIS Tools - Hoe" (pickaxe=47200, woodaxe=47210)
    hoe_item_id   = 34713,   -- its inventory item (for the panel's "give me one" button)
    hoe_bypass    = true,    -- ⚠ DEV: the hoe now EXISTS - flip this false once you're holding it,
                             -- so tilling actually requires the tool. Left on so nothing is blocked
                             -- if the Content Editor bundle hasn't been imported yet.
    -- ── distances (metres) ──
    plot_range   = 30.0,     -- must be this close to a BUILT plot to farm at all
    act_radius   = 2.2,      -- a bed answers your interact from this far
    bed_spacing  = 0.80,     -- ⛔ must stay UNDER bed_wid (0.95) or a snapped neighbour would be
                             -- rejected as "too close" and a row could never form
    till_ahead   = 1.8,      -- a new bed appears this far in front of you
    till_clear   = 1.6,      -- foliage cleared around a bed. Was 1.3 = SHORTER than the mesh's own
                             -- 1.40m length, so grass survived at both ends and grew through it.
    spawn_radius = 40.0,     -- crop props stream in within this of the player
    -- ── the watering emote (Aurora found it 07-25: the clip CARRIES ITS OWN watering can, so
    --    there's no prop to spawn). 3051 is the middle LOOP and is deliberately skipped - looping
    --    a watering animation just makes chores tedious. Intro straight into the finish. ──
    water_bank    = 61,
    water_intro   = 3050, water_intro_f = 254,   -- frames, /60 like the house-build clips
    water_end     = 3052, water_end_f   = 190,
    water_emote   = true,
    water_sheathe_s = 1.3,   -- put the weapon away, THEN water (also spans the menu's unpause);
                             -- long enough for the sheathe animation to finish before the freeze
    -- ⭐ watered soil looks DARK (Aurora 08-04). Attempted live on the bed material; if the mdf2
    -- exposes no colour variable the log says so and the fallback is a wet-mdf2 pak variant.
    wet_tint     = true,
    wet_dark     = 0.32,     -- multiplier while watered (1.0 = no change). 0.55 read too subtle
                             -- in the field (Aurora 08-05: "needs to contrast stronger vs dry")
    wet_delay    = 3.5,      -- seconds after the water press before the soil darkens (mid-pour)
    -- ── plot map markers ──
    plot_markers  = true,
    plot_icon_id   = 0,
    plot_icon_type = 22,     -- ⭐ 22 = the HOUSE glyph (Aurora found it 08-05). 18=Inn,
                             -- 25=guild-contract's pick, 27=Riftstone, 67=Settlement
    -- ⛔ ABGR, not ARGB (Aurora 08-05: "it's very blue for some reason" - 0xFFFF8800 was amber in
    -- ARGB and reads BLUE in ABGR; the ring-colour law claims its second module). Amber = 0xFF0088FF.
    plot_icon_color = 0xFF0088FF,  -- ABGR amber; 0 = the glyph's own colour
    plot_icon_custom = true,       -- ⭐ PROBE (08-05): for-sale plots try Aurora's plot-sign art
                                   -- (iris_plotsign_icon.tex) instead of the glyph - unproven route,
                                   -- repoints the marker's own Icon control at a loose custom .tex
    -- ── plot surveyor (candidate spots on the map + warp) ──
    survey_markers = true,
    survey_icon_type = 27,         -- riftstone glyph for candidates (distinct from the house)
    survey_icon_color = 0xFF00FF00, -- ABGR green
    prospect = false,              -- ⭐ passive flat-empty-ground scanner while roaming (panel toggle)
    prospect_every = 4.0,          -- seconds between prospect samples
    prospect_gap = 120,            -- min metres from any existing candidate/plot
    prospect_gim_r = 30,           -- a gimmick within this radius disqualifies the spot
    prospect_ring = 90,            -- aerial sweep radius: each tick samples a rotating fan out to this
    -- ── chore emotes + animal produce (08-05, Aurora's clip picks) ──
    cook_emote = true,  cook_bank = 60, cook_clip = 6050, cook_f = 240,   -- stirring stand-in
    animal_produce = true,
    milk_bank = 60, milk_clip = 6050, milk_f = 240,                       -- same clip as placeholder
    -- comma-separated GameObject-name tokens. Ids read from EnemySpawner/charRef.lua (read-only,
    -- never edit other mods): ch299003_A = Ox COW (incl. harness variants A_10/20/50/60),
    -- ch299003_B = the BULL (excluded by the token), ch299221 = Chicken, ch299220 = Rooster
    -- (excluded - roosters don't lay). The SCAN probe verifies the live GO names if these miss.
    milk_ids = "ch299003_A", egg_ids = "ch299221",
    -- 08-13 4.0 -> 7.0 (Aurora: "can't get milk from the cow"): the scan measures to
    -- the GO PIVOT, and a size-gened cow's pivot sits metres from the flank you stand
    -- at - tiny Clucky passed, the mountain failed. Call sites also floor at 7.
    animal_range = 7.0,
    -- ── monster guard: no aggressive spawns near any plot ──
    monster_guard = true,
    monster_guard_r = 120,   -- metres around every plot (Aurora: "100m+")
    -- ── the cooking fire (the invisible campfire under the cookpot furniture) ──
    cookfire_gid  = "gm51_381",  -- the campfire gimmick; 382/383 are the variants if 381 misbehaves
    cookfire_hide = true,        -- hide the campfire's meshes (the pot provides the visual)
    -- ── the day model (Stardew) ──
    wilt_after   = 2,        -- dry this many days -> WILTING
    die_after    = 4,        -- dry this many days -> dead, bed returns to bare soil
    scale_min    = 0.18,     -- a day-one sprout; matures to 1.0
    tick_every   = 0.5,
    last         = "farming ready",
}

-- ── the crop table ────────────────────────────────────────────────────────────────────────
-- `gid`       = the real in-game gather-node prop you watch grow
-- `base/ripe/rot` = real item ids. ONLY fruits + Harspud have Ripened/Rotten variants; herbs and
--                flowers are single items, so those grade by QUANTITY instead (see do_harvest).
-- `days`      = in-game days of WATERED growth to ripen
-- `seed_item` = nil -> virtual seed bag. Set to a Content Editor item id -> REAL inventory.
--               (Aurora's plan: distinct seed ITEM per crop, all sharing ONE seedbag icon.)
-- `base = nil` = a crop AWAITING its Content Editor item (the vegetables). It stays hidden from
--               the sow dialog until the id is filled in - see _pending().
-- ⭐ 21 CROPS (expanded 07-25 on Aurora's call: "I'd rather give players as many options as
--    possible"). seed_item ids are LIVE: bundle "IRIS - Seeds" 34730-34750; the vegetables' own
--    items are "IRIS - Vegetables" 34720-34722. Table + bundles are GENERATED together by the
--    scratchpad script mk_farm_all.py - edit there and regenerate so they can't drift apart.
-- ⚠ The expansion herbs/flowers have no dedicated gather node, so they grow as gm82_009 (the
--    generic leafy plant) like the vegetables; the new berries borrow the cranberry bush.
M.crops = {
    -- HERBS
    { key = "harspud", name = "Harspud", cat = "Herbs", gid = "gm82_020", base = 49, ripe = 50, rot = 51, days = 3, seed_item = 34730 },
    { key = "greenwarish", name = "Greenwarish", cat = "Herbs", gid = "gm82_009", base = 184, days = 3, seed_item = 34731 },
    { key = "pitywort", name = "Pitywort", cat = "Herbs", gid = "gm82_009", base = 186, days = 3, seed_item = 34742 },
    { key = "morningtide", name = "Morningtide", cat = "Herbs", gid = "gm82_009", base = 187, days = 3, seed_item = 34743 },
    { key = "goldthistle", name = "Goldthistle", cat = "Herbs", gid = "gm82_009", base = 192, days = 3, seed_item = 34744 },
    { key = "syrupwort", name = "Syrupwort Leaf", cat = "Herbs", gid = "gm82_009", base = 193, days = 3, seed_item = 34745 },
    -- FRUIT
    { key = "apple", name = "Apple", cat = "Fruit", gid = "gm82_013", base = 1, ripe = 2, rot = 3, days = 5, seed_item = 34732 },
    { key = "grapes", name = "Grapes", cat = "Fruit", gid = "gm82_012", base = 4, ripe = 5, rot = 6, days = 5, seed_item = 34733 },
    { key = "quince", name = "Quince", cat = "Fruit", gid = "gm82_014", base = 7, ripe = 8, rot = 9, days = 5, seed_item = 34734 },
    { key = "cranberry", name = "Cranberry", cat = "Fruit", gid = "gm82_011", base = 16, ripe = 17, rot = 18, days = 4, seed_item = 34735 },
    { key = "raspberry", name = "Raspberry", cat = "Fruit", gid = "gm82_011", base = 13, ripe = 14, rot = 15, days = 4, seed_item = 34747 },
    { key = "blueberry", name = "Blueberry", cat = "Fruit", gid = "gm82_011", base = 19, ripe = 20, rot = 21, days = 4, seed_item = 34748 },
    { key = "strawberry", name = "Strawberry", cat = "Fruit", gid = "gm82_011", base = 22, ripe = 23, rot = 24, days = 4, seed_item = 34749 },
    { key = "fig", name = "Fig", cat = "Fruit", gid = "gm82_013", base = 10, ripe = 11, rot = 12, days = 5, seed_item = 34750 },
    -- FLOWERS
    { key = "sunbloom", name = "Sunbloom", cat = "Flowers", gid = "gm82_010", base = 505, days = 2, seed_item = 34736 },
    { key = "noonbloom", name = "Noonbloom", cat = "Flowers", gid = "gm82_030", base = 510, days = 3, seed_item = 34737 },
    { key = "moonglow", name = "Moonglow", cat = "Flowers", gid = "gm82_018", base = 185, days = 3, seed_item = 34738 },
    { key = "grandpetal", name = "Grandpetal", cat = "Flowers", gid = "gm82_009", base = 191, days = 3, seed_item = 34746 },
    -- VEGETABLES: DD2 has no veg item AND no veg mesh - and needs neither. They grow as gm82_009
    -- ("Random plant", the generic leafy gather node) and hand over AURORA'S custom item at
    -- harvest, so a vegetable costs one icon + one CE item entry. ZERO 3D work.
    { key = "potato", name = "Potato", cat = "Vegetables", gid = "gm82_009", base = 34720, days = 4, seed_item = 34739 },
    { key = "pepper", name = "Pepper", cat = "Vegetables", gid = "gm82_009", base = 34721, days = 4, seed_item = 34740 },
    { key = "carrot", name = "Carrot", cat = "Vegetables", gid = "gm82_009", base = 34722, days = 4, seed_item = 34741 },
}
-- a crop with no yield item yet = awaiting Content Editor; never offered for sowing
local function _pending(c) return not c.base end

-- ⭐ EXPANSION CANDIDATES (Aurora 07-25: "is it worth having seeds for the other herbs too?").
-- These are real gatherable plants with real economic use; the dump captures their combine tables
-- so seeds + vanilla-preserving recipes can be generated for the whole batch in one pass.
-- ⚠ None has a dedicated gm82 gather node, so they'd grow as gm82_009 (the generic plant) like
-- the vegetables do - mechanically identical, visually samey. Berries can borrow gm82_011.
M.dump_candidates = {
    [186] = "Pitywort", [187] = "Morningtide", [191] = "Grandpetal",
    [192] = "Goldthistle", [193] = "Syrupwort Leaf",
    [13] = "Raspberry", [14] = "Ripened Raspberry", [15] = "Rotten Raspberry",
    [19] = "Blueberry", [20] = "Ripened Blueberry", [21] = "Rotten Blueberry",
    [22] = "Strawberry", [23] = "Ripened Strawberry", [24] = "Rotten Strawberry",
    [10] = "Fig", [11] = "Ripened Fig", [12] = "Rotten Fig",
}

local GARDEN_FILE = "IRIS/garden.json"
local PATHS_FILE  = "IRIS/furnish_paths.json"
local LOG_FILE    = "IRIS/farming_log.txt"

-- ── logging (plain relative path: io.open is ALREADY rooted at the data dir) ──
local function _log(s)
    pcall(function()
        local f = io.open(LOG_FILE, "a")
        if f then f:write("[" .. os.date("%H:%M:%S") .. "] " .. tostring(s) .. "\n"); f:close() end
    end)
    M.last = tostring(s)
end

local function _crop(k) for _, c in ipairs(M.crops) do if c.key == k then return c end end end

-- ── persistence ───────────────────────────────────────────────────────────────────────────
-- beds = { {ux,uy,uz,plot,yaw, crop=key|nil, grown=0, watered_day=n, dry=0, missed=0} }
local beds, seeds, meta = {}, {}, { last_day = nil }
local function _save()
    pcall(function()
        local out = { beds = {}, seeds = seeds, last_day = meta.last_day }
        for _, b in ipairs(beds) do
            if not b.ephemeral then
            out.beds[#out.beds + 1] = { ux = b.ux, uy = b.uy, uz = b.uz, plot = b.plot, yaw = b.yaw,
                crop = b.crop, grown = b.grown or 0, watered_day = b.watered_day,
                dry = b.dry or 0, missed = b.missed or 0, lift = b.lift or 0 }
            end
        end
        json.dump_file(GARDEN_FILE, out)
    end)
end
local function _load()
    pcall(function()
        local d = json.load_file(GARDEN_FILE)
        if type(d) == "table" then
            seeds = d.seeds or {}
            meta.last_day = d.last_day
            beds = {}
            for _, r in ipairs(d.beds or {}) do
                beds[#beds + 1] = { ux = r.ux, uy = r.uy, uz = r.uz, plot = r.plot, yaw = r.yaw or 0,
                    crop = r.crop, grown = r.grown or 0, watered_day = r.watered_day,
                    dry = r.dry or 0, missed = r.missed or 0, lift = r.lift or 0,
                    live = nil, hidden = {} }
            end
        end
    end)
    M.paths = json.load_file(PATHS_FILE) or {}
end

-- ── player / coords ───────────────────────────────────────────────────────────────────────
local function _pch() local c; pcall(function() c = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer") end); return c end
local function _ptf() local tf; pcall(function() tf = _pch():call("get_GameObject"):call("get_Transform") end); return tf end
local function _ppos() local tf = _ptf(); local p; if tf then pcall(function() p = tf:call("get_Position") end) end return p end
local function _pupos() local tf = _ptf(); local p; if tf then pcall(function() p = tf:call("get_UniversalPosition") end) end return p end
local function _delta()
    local up, rp = _pupos(), _ppos()
    if up and rp then return { x = up.x - rp.x, y = up.y - rp.y, z = up.z - rp.z } end
end
local function _pfwd()
    local fx, fz = 0, 1
    pcall(function()
        local tf = _ptf(); if not tf then return end
        local q = tf:call("get_Rotation")
        local x, y, z, w = q.x, q.y, q.z, q.w
        fx = 2 * (x * z + w * y); fz = 1 - 2 * (x * x + y * y)
        local l = math.sqrt(fx * fx + fz * fz); if l > 1e-4 then fx, fz = fx / l, fz / l end
    end)
    return fx, fz
end

-- ── the in-game clock (proven: RiftSpeakChildProfile + IrisTaming read these) ──────────────
-- ⛔ DAY-0 TRAP (found in Aurora's log 07-25: "day 293" then "day 0" after a script reset).
-- On a reset at the title/loading screen the clock reads 0. Treating that as a real day made
-- _advance_days rewind last_day to 0, so the moment the true day (293) came back it counted 293
-- elapsed days: every crop would have instantly withered. Day 0 is NO CLOCK, not day zero.
local function _today()
    local d
    pcall(function()
        local tm = sdk.get_managed_singleton("app.TimeManager")
        if tm then d = tonumber(tm:call("get_InGameDay")) end
    end)
    d = d and math.floor(d) or nil
    if not d or d <= 0 then return nil end
    return d
end
local function _hour()
    local h
    pcall(function()
        local tm = sdk.get_managed_singleton("app.TimeManager")
        if tm then h = tonumber(tm:call("get_InGameHour")) end
    end)
    return h or 0
end

-- ── the plot gate ─────────────────────────────────────────────────────────────────────────
local function _nearest_plot()
    local best, bd
    pcall(function()
        local up = _pupos(); if not up then return end
        for _, pr in ipairs(_G.IrisHomesteadPlots and _G.IrisHomesteadPlots.list() or {}) do
            if pr.owned ~= false and pr.built ~= false then
                local dx, dz = (pr.ux or 0) - up.x, (pr.uz or 0) - up.z
                local dd = dx * dx + dz * dz
                if not bd or dd < bd then bd = dd; best = pr end
            end
        end
    end)
    return best, bd and math.sqrt(bd) or nil
end

-- ── the HOE in hand (mirrors IrisWoodcutting's wp child scan) ─────────────────────────────
-- (a head-tracking variant was drafted here - reading the weapon GO's grip and projecting a haft
--  length down its own axis to find the true impact point. Aurora called it: the fixed `till_ahead`
--  ring already lands where the swing does, so the extra machinery earns nothing. Left out.)
-- ⚠ TWO CHECKS, deliberately. `_hoe_equipped()` is the honest "is weapon 47220 actually in your
-- hands" scan; `_hoe_in_hand()` is that OR the dev bypass. The RING must use the strict one -
-- with the bypass on (its default) the loose check is always true, so the marker hung on screen
-- permanently whether or not a hoe was out (Aurora 07-26).
local function _hoe_equipped()
    local found = false
    pcall(function()
        local tf = _ptf(); if not tf then return end
        local child = tf:call("get_Child")
        while child do
            local cgo = child:call("get_GameObject")
            local nm = tostring(cgo and cgo:call("get_Name") or "")
            if nm:find("^wp") then
                local w = cgo:call("getComponent(System.Type)", sdk.typeof("app.Weapon"))
                if w then
                    local id
                    pcall(function() id = w:get_field("ID") end)
                    if id == nil then pcall(function() id = w:get_field("<ID>k__BackingField") end) end
                    if id == nil then pcall(function() id = w:call("get_ID") end) end
                    if tonumber(id) == M.hoe_weapon_id then found = true end
                end
            end
            if found then break end
            child = child:call("get_Next")
        end
    end)
    return found
end
local function _hoe_in_hand() return M.hoe_bypass or _hoe_equipped() end

-- ── TILLING THE EARTH: hide the foliage in a small radius (IrisHomestead's grass-clear recipe;
--    re-asserted like the 07-24 wild-tree fix, because streaming pops hidden instances back) ──
-- ⚠ tills keep logging "0 foliage cleared" while the bed is visibly buried in tall grass, so this
-- also reports how much foliage EXISTS nearby: 0 components = this grass isn't via.landscape.Foliage
-- at all (a different system we'd need to find), rather than the radius being too small.
-- ⛔⛔ WHY THE GRASS SURVIVED (Aurora 08-04: "I tried hoeing the ground with some grass/scenery
-- around it and it didn't clear the grass"). It was NEVER a wrong foliage type - the earlier
-- "this grass is NOT via.landscape.Foliage / nearest instance 84m away" readings were the LIE of
-- a scan that died before it arrived. This was a ONE-TICK scan over EVERY Foliage component in
-- the scene with a 60k anti-freeze cap and a bare `return` when it blew - and IrisHomestead had
-- already diagnosed exactly this failure and written the fix in its own margin:
--
--   "in dense areas ~58 components pass the cull and their combined instances blow ANY one-tick
--    cap before the scan reaches the house's patch -> 0 found on every pass, deterministically.
--    A one-tick scan and an anti-freeze cap are fundamentally incompatible in dense areas."
--
-- In thick grass the budget was spent on far-off patches and the bail-out fired before the cursor
-- ever reached the bed. The "nearest" figure it then printed was just the nearest patch it had
-- managed to look at - which is why it read 15-84m while she stood waist-deep in the stuff.
--
-- FIX = the homestead's proven shape, both halves of it:
--   1. PROXIMITY CULL first (one cheap tick, instance-0 proxy) so distant patches never enter the
--      work at all - this alone removes most of the load;
--   2. BUDGETED MULTI-TICK scan, no cap, nothing dropped. 274k instance reads in ONE tick is the
--      freeze law; 10k per tick clears in a fraction of a second and drops nothing.
local clear_jobs = {}            -- budgeted foliage clears in flight (one per till, FIFO)
local CLEAR_SCAN_BUDGET = 10000  -- instance reads per tick. The freeze law, not a cap on work.

-- Foliage components and their instance indices are streaming-owned. A Lua
-- proxy may outlive either one, and the short overload name can resolve to an
-- unsafe native thunk. Validate both and call the exact UInt32 overload; this
-- prevents the c0000005 burst seen during the 16:32 grass pass.
local function _set_foliage_visibility(comp, index, visible)
    if not comp or not sdk.is_managed_object(comp) then return false end
    index = tonumber(index)
    if not index or index < 0 then return false end
    local count = nil
    pcall(function() count = tonumber(comp:call("get_InstanceCount")) end)
    if not count or index >= count then return false end
    return pcall(function()
        comp:call("setVisibility(System.UInt32, System.Boolean)", index, visible)
    end)
end

local function _till_clear(cx, cz, radius, into)
    -- phase A: cull by instance-0 proxy. A patch can sprawl, so the margin stays generous -
    -- the expensive part is now spread over ticks rather than thrown away.
    local near, comps = {}, 0
    pcall(function()
        local smgr = sdk.get_native_singleton("via.SceneManager")
        local scene = smgr and sdk.call_native_func(smgr, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        local arr = scene and scene:call("findComponents(System.Type)", sdk.typeof("via.landscape.Foliage"))
        local n = arr and arr:get_size() or 0
        comps = tonumber(n) or 0
        local near2 = (radius + 200.0) * (radius + 200.0)
        for ci = 0, comps - 1 do
            local c = arr:get_element(ci)
            if c then
                local cnt = 0
                pcall(function() cnt = tonumber(c:call("get_InstanceCount")) or 0 end)
                if cnt > 0 then
                    local p0
                    pcall(function() p0 = c:call("getWorldPosition", 0) end)
                    if p0 then
                        local dx, dz = p0.x - cx, p0.z - cz
                        if dx * dx + dz * dz <= near2 then near[#near + 1] = { comp = c, cnt = cnt } end
                    end
                end
            end
        end
    end)
    clear_jobs[#clear_jobs + 1] = { cx = cx, cz = cz, r2 = radius * radius, radius = radius,
                                    near = near, ci = 1, ii = 0, into = into, hid = 0, comps = comps }
    return 0   -- ⚠ the count is no longer known synchronously; the job logs its own total
end

-- phase B: walk the culled patches over as many ticks as it takes, hiding what falls in radius.
local function _pump_till_clears()
    local job = clear_jobs[1]
    if not job then return end
    local budget = 0
    while job.ci <= #job.near and budget < CLEAR_SCAN_BUDGET do
        local e = job.near[job.ci]
        if job.ii >= e.cnt then
            job.ci, job.ii = job.ci + 1, 0
        else
            pcall(function()
                local wp = e.comp:call("getWorldPosition", job.ii)
                if wp then
                    local dx, dz = wp.x - job.cx, wp.z - job.cz
                    if dx * dx + dz * dz <= job.r2 then
                        -- only hide what's currently VISIBLE, so a re-assert can't double-record
                        -- an instance and the restore stays truthful
                        local vis
                        pcall(function() vis = e.comp:call("getVisibility", job.ii) end)
                        if vis ~= false then
                            if _set_foliage_visibility(e.comp, job.ii, false) then
                                job.into[#job.into + 1] = { comp = e.comp, i = job.ii, x = wp.x, z = wp.z }
                                job.hid = job.hid + 1
                            end
                        end
                    end
                end
            end)
            job.ii = job.ii + 1
            budget = budget + 1
        end
    end
    if job.ci > #job.near then
        _log(string.format("foliage clear: %d hidden within %.1fm (%d patch(es) near, %d component(s) in scene)",
            job.hid, job.radius, #job.near, job.comps))
        table.remove(clear_jobs, 1)
    end
end
local _reassert_at = 0.0
local function _reassert_tilled()
    if os.clock() - _reassert_at < 1.5 then return end
    _reassert_at = os.clock()
    for _, b in ipairs(beds) do
        for _, h in ipairs(b.hidden or {}) do
            pcall(function()
                local wp = h.comp:call("getWorldPosition", h.i)
                if wp then
                    local dx, dz = wp.x - h.x, wp.z - h.z
                    if dx * dx + dz * dz <= 1.0 then
                        _set_foliage_visibility(h.comp, h.i, false)
                    end
                end
            end)
        end
    end
end

-- ── prop spawn (mirrored from IrisFurnish: GenerateManager, setInitialAngle ONLY) ──────────
local jobs, seq = {}, 0
local function _euler_quat(yaw, pitch, roll)
    local cy, sy = math.cos(math.rad(yaw) / 2), math.sin(math.rad(yaw) / 2)
    local cp, sp = math.cos(math.rad(pitch) / 2), math.sin(math.rad(pitch) / 2)
    local cr, sr = math.cos(math.rad(roll) / 2), math.sin(math.rad(roll) / 2)
    return { w = cy * cp * cr + sy * sp * sr, x = cy * sp * cr + sy * cp * sr,
             y = sy * cp * cr - cy * sp * sr, z = cy * cp * sr - sy * sp * cr }
end
local function _queue_spawn(gid_name, x, y, z, yaw, on_go, scale)
    local gid
    pcall(function()
        local fld = sdk.find_type_definition("app.GimmickID"):get_field((gid_name:gsub("^gm", "Gm")))
        if fld then gid = fld:get_data() end
    end)
    if not gid then _log("no GimmickID enum for " .. gid_name); return false end
    jobs[#jobs + 1] = { gid = gid, name = gid_name, x = x, y = y, z = z, yaw = yaw or 0,
        scale = scale or 1.0, stage = "prefab", f = 0, on_go = on_go }
    return true
end
local function _pump_jobs()
    for i = #jobs, 1, -1 do
        local q = jobs[i]
        local drop = false
        if q.stage == "prefab" then
            local ok = pcall(function()
                local prefab = sdk.create_instance("via.Prefab"):add_ref()
                prefab:set_Path((M.paths and M.paths[q.name]) or ("AppSystem/gimmick/prefab/gather/" .. q.name .. ".pfb"))
                pcall(function() prefab:set_Standby(true) end)
                local ctrl = sdk.create_instance("app.PrefabController"):add_ref()
                ctrl._Item = prefab
                pcall(function() ctrl:get_Item():set_Standby(true) end)
                local inst = sdk.create_instance("app.InstanceInfo"):add_ref()
                local container
                pcall(function() container = inst:get_Container() end)
                if not container then container = sdk.create_instance("app.GenerateInfo.GenerateInfoContainer"):add_ref() end
                local pos = ValueType.new(sdk.find_type_definition("via.Position"))
                pos.x, pos.y, pos.z = q.x, q.y, q.z
                local cat = 5
                pcall(function()
                    local f2 = sdk.find_type_definition("app.GeneratorCategory"):get_field("Gimmick")
                    if f2 then cat = f2:get_data() end
                end)
                pcall(function() container._CommonInfo._Category = cat end)
                pcall(function() container._CommonInfo._ObjectID._SelectedGimmickID = q.gid end)
                pcall(function() container._CommonInfo._InitialPosition = pos end)
                pcall(function() container._CommonInfo._ContextPosition = pos end)
                pcall(function() container._CommonInfo:setContextPosition(pos) end)
                pcall(function()
                    local eq = _euler_quat(q.yaw or 0, 0, 0)
                    local rqt = ValueType.new(sdk.find_type_definition("via.Quaternion"))
                    rqt.x, rqt.y, rqt.z, rqt.w = eq.x, eq.y, eq.z, eq.w
                    container._CommonInfo:setInitialAngle(rqt)
                end)
                pcall(function() container._StatusInfo["<ScaleRate>k__BackingField"] = q.scale or 1.0 end)
                q.prefab, q.ctrl, q.inst, q.container = prefab, ctrl, inst, container
            end)
            -- ⛔ these drops used to be SILENT, which is why "no mounds appear" produced an empty
            -- log and looked like success (Aurora 07-25). Every failure path now says so.
            if ok and q.prefab then q.stage = "wait"; q.f = 0
            else drop = true; _log("spawn SETUP FAILED for " .. tostring(q.name) .. " (path/prefab build)") end
        elseif q.stage == "wait" then
            q.f = q.f + 1
            local ready = false
            pcall(function() ready = q.prefab:get_Ready() == true end)
            if ready then
                seq = seq + 1
                local okr = pcall(function()
                    local gen = sdk.get_managed_singleton("app.GenerateManager")
                    gen:call("requestCreateInstance(app.PrefabController, app.GenerateInfo.GenerateInfoContainer, System.Int32, app.InstanceInfo, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>)",
                        q.ctrl, q.container, 760000 + seq, q.inst, nil, nil)
                end)
                if okr then q.stage = "poll"; q.f = 0
                else drop = true; _log("requestCreateInstance THREW for " .. tostring(q.name)) end
            elseif q.f > 1500 then
                drop = true
                _log("prefab NEVER became ready: " .. tostring(q.name) .. " path=" ..
                    tostring((M.paths and M.paths[q.name]) or "(fallback gather/ path)"))
            end
        elseif q.stage == "poll" then
            q.f = q.f + 1
            local go
            pcall(function() go = q.inst:get_Instance() end)
            if not go then pcall(function() go = q.inst["<Instance>k__BackingField"] end) end
            if go then
                pcall(function() go = go:add_ref() end)
                if q.on_go then pcall(q.on_go, go) end
                drop = true
            elseif q.f > 1500 then _log("spawn TIMED OUT: " .. tostring(q.name)); drop = true end
        end
        if drop then table.remove(jobs, i) end
    end
end

-- ── items: grant the harvest, count/consume seeds ─────────────────────────────────────────
local function _grant_item(id, n)
    if not id then return 0 end
    local ok = pcall(function()
        local im = sdk.get_managed_singleton("app.ItemManager")
        local gm = sdk.find_type_definition("app.ItemManager"):get_method(
            "getItem(System.Int32, System.Int32, app.Character, System.Boolean, System.Boolean, System.Boolean, app.ItemManager.GetItemEventType, System.Boolean, System.Boolean)")
        gm:call(im, id, n, _pch(), true, false, false, nil, true, false)
    end)
    return ok and n or 0
end
local function _count_item(id)
    local n
    pcall(function()
        local im = sdk.get_managed_singleton("app.ItemManager")
        local ch = _pch()
        if im and ch then n = tonumber(im:call("getHaveNum(System.Int32, app.Character)", id, ch)) end
    end)
    return n
end
-- seeds: REAL inventory when the crop has a Content Editor item id, else the virtual bag
local function _seed_count(c)
    if _pending(c) then return 0 end          -- awaiting its Content Editor item: not sowable yet
    if c.seed_item then return _count_item(c.seed_item) or 0 end
    return seeds[c.key] or 0
end
local function _seed_take(c, n)
    n = n or 1
    if c.seed_item then
        local ok = pcall(function()
            local im = sdk.get_managed_singleton("app.ItemManager")
            im:call("deleteItem(System.Int32, System.Int32, app.Character)", c.seed_item, n, _pch())
        end)
        return ok
    end
    if (seeds[c.key] or 0) < n then return false end
    seeds[c.key] = (seeds[c.key] or 0) - n
    return true
end
-- dev top-up: grants the REAL seed item once authored, else fills the virtual bag
local function _seed_give(c, n)
    if c.seed_item then _grant_item(c.seed_item, n or 5)
    else seeds[c.key] = (seeds[c.key] or 0) + (n or 5); _save() end
end

-- ── the native dialog (IrisDeedSign's machinery; RetVal None=0 Sel0=1 Sel1=2 Sel2=3 Sel3=4 Cancel=5) ──
local DIALOG_GUITYPE = 14
local dlg = { open = false, baseline = nil, opened_at = 0, phase = nil, opts = nil }
local function _dialog_pick()
    local p
    pcall(function()
        local gm = sdk.get_managed_singleton("app.GuiManager")
        local rv = gm and gm:call("getDialogState")
        if rv == nil then return end
        if type(rv) == "number" then p = rv else pcall(function() p = sdk.to_int64(rv) & 0xFFFFFFFF end) end
    end)
    return p
end
local function _show_dialog(prompt, o1, o2, o3, o4, phase)
    local ok = pcall(function()
        local gm = sdk.get_managed_singleton("app.GuiManager")
        local dialog = gm and gm:get_field("Dialog")
        if not dialog then return end
        gm:call("requestGuiType", DIALOG_GUITYPE)
        dialog:call("reqDisp", prompt, o1 or "", o2 or "", o3 or "", o4 or "",
            true, 0, true, 58, 0, -1, nil,
            false, false, false, false, false, false, true, 0.0)
        dlg.open = true; dlg.opened_at = os.clock(); dlg.baseline = _dialog_pick(); dlg.phase = phase
        dlg.nil_since = nil   -- fresh dialog: the liveness watch starts clean
    end)
    if not ok then _log("reqDisp FAILED") end
end
local function _close_dialog()
    pcall(function()
        local gm = sdk.get_managed_singleton("app.GuiManager")
        local dialog = gm and gm:get_field("Dialog")
        if dialog then dialog:call("reqClose") end
        gm:call("requestHideGuiType", DIALOG_GUITYPE)
    end)
    dlg.open = false; dlg.phase = nil; dlg.opts = nil; dlg.nil_since = nil
    -- ⛔ THE DOUBLE-CANCEL (Aurora 08-05: "the menu needs cancel twice to leave"). While the
    -- dialog is open the pad-edge tracker freezes, so the very press that picked "Cancel" is
    -- still an unseen edge after close - and it re-opened the menu, making the SECOND cancel
    -- necessary. A short grace after any close swallows that leftover press.
    dlg.closed_at = os.clock()
end

-- ── player motion (the watering-can emote; same route as the house-build clips) ────────────
local function _play_clip(bank, clip)
    local ok = pcall(function()
        _pch():call("get_Motion"):call("getLayer", 0):call(
            "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
            bank, clip, 0.0, 6.0, 1, 1)
    end)
    return ok
end
-- ⛔ THE FSM MUST BE HELD FOR THE EMOTE (08-04: "still not emoting" even after the sheathe
-- pre-stage). A bare changeMotion only survives while nothing else drives layer 0 - standing
-- perfectly idle it worked, but the sheathe ACTION (and any FSM state at all) re-drives the layer
-- the same frame and the clip never shows. The woodcutter's gather does exactly this freeze.
local function _pfsm(en)
    pcall(function()
        local h = _pch():call("get_Human")
        if h and h.Fsm then h.Fsm:set_Enabled(en) end
    end)
end

-- ── the growth model, in DAYS ─────────────────────────────────────────────────────────────
local function _bed_state(b)
    local c = b.crop and _crop(b.crop)
    if not c then return nil end
    local ripe = (b.grown or 0) >= (c.days or 3)
    local dry = b.dry or 0
    local wilting = dry >= (M.wilt_after or 2)
    return { crop = c, ripe = ripe, dry = dry, wilting = wilting,
             frac = math.min(1.0, (b.grown or 0) / math.max(1, c.days or 3)) }
end
-- roll the farm forward when the in-game day advances (Stardew: a day only counts if watered)
local function _advance_days()
    local today = _today(); if not today then return end
    if meta.last_day == nil then meta.last_day = today; return end
    if today <= meta.last_day then
        if today < meta.last_day then meta.last_day = today end   -- NG+/save load rewound the clock
        return
    end
    local elapsed = today - meta.last_day
    local grew, died = 0, 0
    for i = #beds, 1, -1 do
        local b = beds[i]
        if b.crop then
            -- the day that just ENDED counts only if it was watered during it
            if b.watered_day == meta.last_day then
                b.grown = (b.grown or 0) + 1; b.dry = 0; grew = grew + 1
            else
                b.dry = (b.dry or 0) + 1; b.missed = (b.missed or 0) + 1
            end
            -- any further skipped days were all dry
            if elapsed > 1 then
                b.dry = (b.dry or 0) + (elapsed - 1)
                b.missed = (b.missed or 0) + (elapsed - 1)
            end
            if (b.dry or 0) >= (M.die_after or 4) then
                _log(string.format("%s at (%.0f,%.0f) WITHERED - %d days without water", b.crop, b.ux, b.uz, b.dry))
                b.crop, b.grown, b.watered_day, b.dry, b.missed = nil, 0, nil, 0, 0
                if b.live then pcall(function() b.live:call("destroy", b.live) end); b.live = nil end
                died = died + 1
            end
        end
    end
    meta.last_day = today
    _save()
    if grew > 0 or died > 0 then
        _log(string.format("day %d: %d crop(s) grew, %d withered", today, grew, died))
    end
end

-- ── crop props: stream in near the player, scale by growth, lean when wilting ──────────────
local function _apply_transform(b)
    if not b.live then return end
    pcall(function()
        local d = _delta(); if not d then return end
        local st = _bed_state(b); if not st then return end
        local sc = (M.scale_min or 0.18) + (1.0 - (M.scale_min or 0.18)) * st.frac
        -- ⭐ with a SPROUT stage in front (08-04, Aurora: "at day 2/4 the cranberry bush is full
        -- and pickable"), the real plant only appears past sprout_until - so its scale restarts
        -- SMALL there (0.55) and reaches full size only at ripeness, instead of looking done at
        -- half growth. Without a sprout mesh the old ramp stands.
        if tostring(M.sprout_mesh or "") ~= "" then
            local su = math.min(0.95, M.sprout_until or 0.5)
            local f = math.max(0.0, math.min(1.0, (st.frac - su) / (1.0 - su)))
            sc = 0.55 + 0.45 * f
        end
        if st.wilting then
            local w = math.min(1.0, (st.dry - (M.wilt_after or 2)) / math.max(1, (M.die_after or 4) - (M.wilt_after or 2)))
            sc = sc * (1.0 - 0.3 * w)
        end
        local gt = b.live:call("get_Transform")
        gt:call("set_Position", Vector3f.new(b.ux - d.x, b.uy - d.y, b.uz - d.z))
        gt:call("set_LocalScale", Vector3f.new(sc, sc, sc))
        local pitch = st.wilting and 20.0 or 0.0
        local q = _euler_quat(b.yaw or 0, pitch, 0)
        local qt = ValueType.new(sdk.find_type_definition("via.Quaternion"))
        qt.x, qt.y, qt.z, qt.w = q.x, q.y, q.z, q.w
        gt:call("set_Rotation", qt)
    end)
end
-- ⭐ IS THERE GROUND UNDER THE TILL SPOT? (Aurora 07-26: "can the crosshair show red if there's
-- no ground - looking over a cliff edge, using it inside the house"). Cast straight down through
-- the spot; layer 2 is the world/terrain collision the woodcutter's trunk test uses.
local ray = { ready = false }
local function _ensure_ray()
    if ray.ready then return true end
    local ok = pcall(function()
        ray.system = sdk.get_native_singleton("via.physics.System")
        ray.method = sdk.find_type_definition("via.physics.System")
            :get_method("castRay(via.physics.CastRayQuery, via.physics.CastRayResult)")
        ray.query = sdk.create_instance("via.physics.CastRayQuery"):add_ref()
        ray.result = sdk.create_instance("via.physics.CastRayResult"):add_ref()
        ray.contact_td = sdk.find_type_definition("via.physics.ContactPoint")
        ray.query:clearOptions()
        ray.query:enableAllHits()
        ray.query:enableNearSort()
        ray.filter = ray.query:get_FilterInfo()
    end)
    ray.ready = ok and ray.system ~= nil and ray.query ~= nil and ray.result ~= nil and ray.filter ~= nil
    return ray.ready == true
end
local function _vec3(x, y, z)
    local v = ValueType.new(sdk.find_type_definition("via.vec3")); v.x, v.y, v.z = x or 0, y or 0, z or 0; return v
end
-- render-space x/z, starting y. Returns the ground's Y at that spot, or nil if there's nothing
-- below within `down` metres. (Reads the contact point rather than just counting hits, so the
-- same probe answers both "is there ground?" and "how high is it?")
-- ⛔ A contact point's position is read with sdk.get_native_field(c, contact_td, "Position") -
-- NOT c:call("get_Position"). Getting that wrong made every probe return nil, so the ring went
-- RED on perfectly flat grass and refused every swing (Aurora 07-26). Proven in IrisHomestead.
-- The ray is also cast LONG (+8/-20) like the homestead's: a short ray from the player's own Y
-- misses whenever the ground sits a little above or below their feet.
local function _ground_y(rx, ry, rz, down)
    if not _ensure_ray() then return nil end
    local best, bestd = nil, 1e18
    pcall(function()
        ray.filter:set_Group(0); ray.filter:set_Layer(2); ray.filter:set_MaskBits(0)
        ray.result:clear()
        ray.query:call("setRay(via.vec3, via.vec3)",
            _vec3(rx, ry + 8.0, rz), _vec3(rx, ry - math.max(20.0, (down or 3.0) * 4), rz))
        ray.method:call(ray.system, ray.query, ray.result)
        local n = ray.result:get_NumContactPoints() or 0
        for k = 0, n - 1 do
            local c = ray.result:call("getContactPoint(System.UInt32)", k)
            local p = c and sdk.get_native_field(c, ray.contact_td, "Position")
            if p then
                local d = math.abs(p.y - ry)          -- the surface nearest your own height
                if d < bestd then bestd = d; best = p.y end
            end
        end
    end)
    if best and math.abs(best - ry) > (down or 3.0) then return nil end   -- too far to count as "under"
    return best
end
-- ⭐⭐ IS THERE A ROOF OVER THIS SPOT? (Aurora 08-04: "I was able to make farmland inside the actual
-- house, not sure if we can detect the house somehow so it can't be done inside?")
-- The obvious fix - ask IrisHomestead for the house footprint and exclude it - is the WRONG one:
-- it only knows about a house SHE built, so it would still let you till inside an inn, a cave, or
-- any interior in the game. Cast UP instead. A ceiling within a few metres means you're indoors,
-- whoever built it and whatever it is. Same layer 2 (world/static) the ground probe uses, so
-- grass, foliage and NPCs are invisible to it and can't produce a phantom roof.
-- ⚠ Known cost: a solid stone archway or a deep balcony overhang reads as "indoors" too. That's
-- the right way round to be wrong - refusing an odd outdoor spot beats beds growing through a
-- floorboard - and `roof_height` tunes it in the panel if a real spot is being refused.
local function _ceiling_above(rx, ry, rz, up)
    if not _ensure_ray() then return nil end
    local reach = up or 4.0
    local best
    pcall(function()
        ray.filter:set_Group(0); ray.filter:set_Layer(2); ray.filter:set_MaskBits(0)
        ray.result:clear()
        -- start just ABOVE the floor, so the ground we're standing on is never the "ceiling"
        ray.query:call("setRay(via.vec3, via.vec3)",
            _vec3(rx, ry + 0.5, rz), _vec3(rx, ry + reach, rz))
        ray.method:call(ray.system, ray.query, ray.result)
        local n = ray.result:get_NumContactPoints() or 0
        for k = 0, n - 1 do
            local c = ray.result:call("getContactPoint(System.UInt32)", k)
            local p = c and sdk.get_native_field(c, ray.contact_td, "Position")
            if p and p.y > ry + 0.5 then
                local h = p.y - ry
                if not best or h < best then best = h end   -- the LOWEST thing overhead
            end
        end
    end)
    return best
end
-- deliberately INDEPENDENT of _ground_y: a plain hit count can't fail on a field-name mistake,
-- and this one gates whether you may farm at all
local function _ground_under(rx, ry, rz, down)
    if not _ensure_ray() then return true end        -- no ray = fail OPEN, never block on a probe
    local hits = 0
    pcall(function()
        ray.filter:set_Group(0); ray.filter:set_Layer(2); ray.filter:set_MaskBits(0)
        ray.result:clear()
        ray.query:call("setRay(via.vec3, via.vec3)",
            _vec3(rx, ry + 2.0, rz), _vec3(rx, ry - (down or 3.0), rz))
        ray.method:call(ray.system, ray.query, ray.result)
        hits = ray.result:get_NumContactPoints() or 0
    end)
    return hits > 0
end

-- ══ THE SEED BED as a CUSTOM MESH (Aurora's Rodin/Blender asset) ═══════════════════════════
-- Ported from the griffin-egg pipeline in IrisTaming (the one custom-pak mesh we've landed).
-- ⚠ NOT a gimmick: a custom mesh has no GimmickID, so this is a bare GameObject carrying a
-- via.render.Mesh. That's also the RIGHT answer here - a gimmick drags its COLLISION along, which
-- is exactly what walled Aurora inside the boulders. A soil patch should be walk-through.
-- ⛔ THE THREE LAWS THE EGG TAUGHT:
--   1. COLD RESOURCES LIE - create + hold refs at load, then give the streamer a beat.
--   2. HOLDER-BIND: setMesh with a raw resource silently no-ops. Wrap in create_holder(...).
--   3. NEVER SAME-FRAME, and bind TWICE - "a cold first bind renders nothing", so re-bind ~1.2s
--      later. get_MaterialNum() > 0 is the proof it took.
local mres = { warmed = false, ok = nil, held = {} }
local audition = nil          -- the mesh auditioner's live carrier (bind/cure phases, see the pump)
local function _warm_mound_mesh()
    if mres.warmed then return mres.ok end
    mres.warmed = true
    local base = M.mound_mesh
    if not base or base == "" then mres.ok = false; return false end
    pcall(function()
        local r1 = sdk.create_resource("via.render.MeshResource", base .. ".mesh")
        if not r1 then
            mres.ok = false
            _log("mound mesh NOT FOUND ('" .. base .. ".mesh') - IRIS pak not mounted? (needs a FULL game restart)")
            return
        end
        mres.held[#mres.held + 1] = r1:add_ref()
        local r2 = sdk.create_resource("via.render.MeshMaterialResource", base .. ".mdf2")
        if r2 then mres.held[#mres.held + 1] = r2:add_ref() end
        mres.ok = true
        _log("mound mesh warmed OK: " .. base)
    end)
    return mres.ok
end
-- ⭐⭐ WARM AT LOAD, NOT AT FIRST BIND (Aurora 2026-08-08: "farmland is visible with reset
-- scripts, just need to make sure it will be visible when it is generated again").
-- That symptom is law #1 above being broken. The warm was LAZY — `_warm_mound_mesh()` ran
-- from the spawn path at line ~1527, so the very first bed created the resource and bound
-- against it in the same breath, with no beat for the streamer to actually resolve it. Cold
-- resources lie: the bind reports MaterialNum=1 and draws nothing. A script reset "fixed" it
-- only because by then the resource had been resident for minutes.
-- ⇒ warm ~5s after load, so the first bed of the session binds against a hot resource like
-- every later one does. The bind→cure re-pass below stays as the second line of defence.
-- ⛔ state lives on `mres`, not a new file-scope local — this chunk is near Lua's 200-local
-- ceiling and IrisHouseForge already had to be refactored for exactly that.
re.on_frame(function()
    if mres.warmed then return end
    if not mres.boot_at then mres.boot_at = os.clock() + 5.0; return end
    if os.clock() >= mres.boot_at then pcall(_warm_mound_mesh) end
end)

local function _bind_mound_mesh(mc, base_override)
    -- base_override = an AUDITION bed's own mesh (b.mound_base); nil = the normal farmland
    local base = base_override or M.mound_mesh
    pcall(function()
        local res = sdk.create_resource("via.render.MeshResource", base .. ".mesh")
        if res then
            res = res:add_ref(); mres.held[#mres.held + 1] = res
            local hold = res:create_holder("via.render.MeshResourceHolder"):add_ref()
            mres.held[#mres.held + 1] = hold
            if not pcall(function() mc:call("setMesh", hold) end) then mc:call("set_Mesh", hold) end
        end
    end)
    pcall(function()
        local mt = sdk.create_resource("via.render.MeshMaterialResource", base .. ".mdf2")
        if mt then
            mt = mt:add_ref(); mres.held[#mres.held + 1] = mt
            local mh = mt:create_holder("via.render.MeshMaterialResourceHolder"):add_ref()
            mres.held[#mres.held + 1] = mh
            if not pcall(function() mc:call("set_Material", mh) end) then mc:call("setMaterial", mh) end
        end
    end)
    pcall(function() mc:call("set_Enabled", true) end)
end
-- a bare-GameObject prop's transform is RENDER space (unlike the gimmick spawn, which is universal)
local function _spawn_mound_mesh(b)
    local d = _delta(); if not d then return false end
    local go
    pcall(function()
        go = sdk.find_type_definition("via.GameObject"):get_method("create(System.String)"):call(nil, "IrisSeedBed")
    end)
    if not go then _log("seed bed: GameObject create failed"); return false end
    pcall(function() go = go:add_ref() end)
    pcall(function() go:call("set_DrawSelf", true); go:call("set_UpdateSelf", true) end)
    local mc
    pcall(function() mc = go:call("createComponent(System.Type)", sdk.typeof("via.render.Mesh")) end)
    if not mc then
        pcall(function() go:call("destroy", go) end)
        _log("seed bed: Mesh component create failed"); return false
    end
    pcall(function()
        local t = go:call("get_Transform")
        local rx, ry, rz = b.ux - d.x, b.uy - d.y, b.uz - d.z

        -- ⭐ SIT FLUSH ON A SLOPE (Aurora 07-26: "part of it is floating but part is also under the
        -- grass"). A single height can never fit sloped ground - the bed has to TILT. Probe the
        -- four corners, take the mean for height and the corner differences for pitch/roll, so the
        -- mesh lies along the terrain instead of skewering it.
        local yaw = b.yaw or 0
        local ryaw = math.rad(yaw)
        local ffx, ffz = math.sin(ryaw), math.cos(ryaw)      -- along its length
        local rrx, rrz = ffz, -ffx                           -- across its width
        local hl, hw = (M.bed_len or 1.40) * 0.5, (M.bed_wid or 0.95) * 0.5
        local pitch, roll = 0.0, 0.0
        local saved_ry, rejected = ry, 0
        local function probe(al, ac)
            local gy = _ground_y(rx + ffx * al + rrx * ac, saved_ry,
                                 rz + ffz * al + rrz * ac, M.ground_probe or 3.0)
            -- The saved bed Y is the terrain height established when the plot was tilled. On a
            -- return, house/furniture collision may spawn before this mesh and become the nearest
            -- layer-2 ray hit (observed: 15.30 -> 16.41). That is not the ground and must not hoist
            -- the soil mound. Genuine footprint slope here is under 0.3m; 0.6m leaves ample room.
            if gy and math.abs(gy - saved_ry) > 0.60 then rejected = rejected + 1; return nil end
            return gy
        end
        local fL, bL = probe(hl, -hw), probe(-hl, -hw)        -- front/back on the left
        local fR, bR = probe(hl, hw), probe(-hl, hw)          -- front/back on the right
        -- ⭐ SAMPLE THE MIDDLE TOO (Aurora 07-26: "partially submerged in the scenery/ground" - the
        -- green showing through is the FLOOR, not grass). Four corners only describe a plane; any
        -- bump BETWEEN them punches straight through the bed. Edge midpoints + centre catch those.
        -- ⭐ DENSE GRID (Aurora 07-26: one bed still sat in "a raised bump right where the mound
        -- is"). 9 points still straddle a small rise. A grid across the whole footprint catches
        -- far more of them. ⚠ It cannot catch a bump that is only VISUAL - terrain detail with no
        -- collision is invisible to a raycast, which is what the per-bed lift below is for.
        local ys = {}
        local NX = math.max(2, math.floor(M.probe_grid or 5))
        local NZ = math.max(2, math.floor((M.probe_grid or 5) * 0.6 + 0.5))
        for i = 0, NX - 1 do
            for k = 0, NZ - 1 do
                local al = -hl + (2 * hl) * (i / (NX - 1))
                local ac = -hw + (2 * hw) * (k / (NZ - 1))
                local v = probe(al, ac)
                if v then ys[#ys + 1] = v end
            end
        end
        if #ys > 0 then
            local sum, hi = 0, -1e9
            for _, v in ipairs(ys) do sum = sum + v; if v > hi then hi = v end end
            -- "mean" lies along the average surface (can dip into a bump); "max" rides the HIGHEST
            -- sample so nothing can ever poke through, at the cost of floating slightly in a dip.
            ry = (M.fit_mode == "max") and hi or (sum / #ys)
            if M.mound_tilt ~= false and fL and bL and fR and bR then
                local front, back = (fL + fR) * 0.5, (bL + bR) * 0.5
                local left, right = (fL + bL) * 0.5, (fR + bR) * 0.5
                -- ⚠ the SIGN of these depends on the euler convention and I can't see the result
                -- from here - flip either in the panel if a bed digs its end in instead of lying
                -- along the slope. Aurora's log: corners 14.34/14.55/14.38/14.58, back 22cm higher
                -- than front, so a wrong pitch sign buries the back edge exactly as reported.
                pitch = -math.deg(math.atan(front - back, M.bed_len or 1.40)) * (M.pitch_sign or 1)
                roll  =  math.deg(math.atan(right - left, M.bed_wid or 0.95)) * (M.roll_sign or 1)
                local cap = M.tilt_cap or 35.0                -- don't let a bad probe stand it on end
                if pitch > cap then pitch = cap elseif pitch < -cap then pitch = -cap end
                if roll > cap then roll = cap elseif roll < -cap then roll = -cap end
            end
        end

        local v = ValueType.new(sdk.find_type_definition("via.vec3"))
        -- b.lift = THIS bed's own nudge, saved with it. The global settings get you 90% of the way;
        -- this handles the one bed sitting on something the probe can't see.
        v.x, v.y, v.z = rx, ry - (M.mound_sink or 0.0) + (M.mound_lift or 0.0) + (b.lift or 0.0), rz
        t:call("set_Position", v)
        local s = M.mound_scale or 1.0
        local sv = ValueType.new(sdk.find_type_definition("via.vec3"))
        sv.x, sv.y, sv.z = s, s, s
        if not pcall(function() t:call("set_LocalScale", sv) end) then pcall(function() t:call("set_Scale", sv) end) end
        local q = _euler_quat(yaw, pitch, roll)
        local qt = ValueType.new(sdk.find_type_definition("via.Quaternion"))
        qt.x, qt.y, qt.z, qt.w = q.x, q.y, q.z, q.w
        t:call("set_Rotation", qt)
        b.fit_pitch, b.fit_roll, b.fit_y = pitch, roll, ry
        -- the numbers behind a bad fit: is it sunk (placed Y far under the bed's own Y), or is it
        -- sitting right and just BURIED IN GRASS (corners found, tilt sane, but foliage uncleared)?
        _log(string.format("bed fit [%s, %d samples, %d collision-height rejected]: bedY %.2f -> groundY %.2f (%+.2f) | corners %s | spread %.2fm | pitch %.1f roll %.1f | placed %.2f",
            M.fit_mode == "max" and "highest" or "average", #ys,
            rejected,
            b.uy - d.y, ry, ry - (b.uy - d.y),
            table.concat({ fL and string.format("%.2f", fL) or "-", bL and string.format("%.2f", bL) or "-",
                           fR and string.format("%.2f", fR) or "-", bR and string.format("%.2f", bR) or "-" }, "/"),
            (function() local lo, hi = 1e9, -1e9
                for _, v in ipairs(ys) do if v < lo then lo = v end; if v > hi then hi = v end end
                return (#ys > 0) and (hi - lo) or 0 end)(),
            pitch, roll, ry - (M.mound_sink or 0.0) + (M.mound_lift or 0.0)))
    end)
    b.mound, b.mound_mc, b.mound_stage, b.mound_at = go, mc, "bind", os.clock()
    -- ⭐ CLEAR THE GRASS HERE, not just at till time (Aurora 07-26: "it didn't clear the grass
    -- covering it"). `b.hidden` is NOT persisted, so after any reload a saved bed came back with an
    -- empty hide-list and the foliage returned - the grass grew straight back through the mesh.
    -- Re-clearing whenever the bed's prop streams in makes it self-healing across reloads.
    b.hidden = b.hidden or {}
    -- ⚠ the clear is a BUDGETED JOB now, so b.hidden stays empty for a tick or two after it's
    -- queued. Without this latch the "is it empty?" test would pass every frame and queue a fresh
    -- job per frame until the first one finished - hundreds of duplicate scans.
    if #b.hidden == 0 and not b.clearing then
        b.clearing = true
        _till_clear(b.ux - d.x, b.uz - d.z, M.till_clear or 1.3, b.hidden)
        _log(string.format("bed at (%.0f,%.0f): foliage clear queued on spawn", b.ux, b.uz))
    end
    return true
end
-- generic mesh bind for an arbitrary path (the auditioner) - same holder + double-bind laws
local function _bind_path(mc, base)
    pcall(function()
        local res = sdk.create_resource("via.render.MeshResource", base .. ".mesh")
        if res then
            res = res:add_ref(); mres.held[#mres.held + 1] = res
            local hold = res:create_holder("via.render.MeshResourceHolder"):add_ref()
            mres.held[#mres.held + 1] = hold
            if not pcall(function() mc:call("setMesh", hold) end) then mc:call("set_Mesh", hold) end
        end
    end)
    pcall(function()
        local mt = sdk.create_resource("via.render.MeshMaterialResource", base .. ".mdf2")
        if mt then
            mt = mt:add_ref(); mres.held[#mres.held + 1] = mt
            local mh = mt:create_holder("via.render.MeshMaterialResourceHolder"):add_ref()
            mres.held[#mres.held + 1] = mh
            if not pcall(function() mc:call("set_Material", mh) end) then pcall(function() mc:call("setMaterial", mh) end) end
        end
    end)
    pcall(function() mc:call("set_Enabled", true) end)
end

-- ⭐⭐ THE SPROUT STAGE (Aurora 08-04: "instead of making a lower scale version of the actual bush,
-- can we use the 'corn' scenery we found (scaled down)? I reckon a small corn plant in the bed
-- would look like a growing plant"). She's right, and it fixes a real ugliness: a day-one crop is
-- currently the FINISHED gather node shrunk to 18%, so an apple tree sprout is a tiny apple tree,
-- fruit and all. A generic green shoot reads as "something is coming up" for every crop at once.
--
-- This is only possible because of what the Vernworth probe turned up: sm82_081 / sm51_543 /
-- sm50_079 near the farm are PURE MESHES with no gimmick and no prefab behind them. The bed's own
-- custom-mesh route spawns a mesh PATH, so any of them can be a crop visual - the sprout doesn't
-- need to be a gather node at all, and brings no collision with it.
-- ⛔ Which of the three is the corn is NOT yet known - it has to be eyeballed with the auditioner.
-- So M.sprout_mesh ships EMPTY and the old shrink-the-gimmick behaviour stays until she fills it
-- in. Never ship a mesh path that hasn't been seen in-game; gm51_573 "Burial mound" taught us that.
local function _spawn_sprout_mesh(b)
    local base = tostring(M.sprout_mesh or "")
    if base == "" then return false end
    local d = _delta(); if not d then return false end
    local go
    pcall(function()
        go = sdk.find_type_definition("via.GameObject"):get_method("create(System.String)"):call(nil, "IrisSprout")
    end)
    if not go then _log("sprout: GameObject create failed"); return false end
    pcall(function() go = go:add_ref() end)
    pcall(function() go:call("set_DrawSelf", true); go:call("set_UpdateSelf", true) end)
    local mc
    pcall(function() mc = go:call("createComponent(System.Type)", sdk.typeof("via.render.Mesh")) end)
    if not mc then
        pcall(function() go:call("destroy", go) end)
        _log("sprout: Mesh component create failed"); return false
    end
    b.sprout, b.sprout_mc, b.sprout_stage, b.sprout_at = go, mc, "bind", os.clock()
    _log("sprout carrier up for " .. tostring(b.crop) .. " ('" .. base .. "') - binding")
    return true
end

-- the sprout sits on the bed and GROWS: it scales with the same 0..1 fraction the real prop uses,
-- so the shoot visibly gets taller each watered day until it hands over to the finished plant.
local function _apply_sprout(b)
    if not b.sprout then return end
    pcall(function()
        local d = _delta(); if not d then return end
        local st = _bed_state(b); if not st then return end
        local t = b.sprout:call("get_Transform")
        local v = ValueType.new(sdk.find_type_definition("via.vec3"))
        v.x = b.ux - d.x
        v.y = (b.fit_y or (b.uy - d.y)) + (M.mound_lift or 0.0) + (b.lift or 0.0) + (M.sprout_rise or 0.0)
        v.z = b.uz - d.z
        t:call("set_Position", v)
        -- grow across the sprout window only, so the shoot reaches full sprout size right as the
        -- real plant takes over - no visible pop from a half-grown shoot to a full bush
        local win = math.max(0.01, M.sprout_until or 0.5)
        local f = math.min(1.0, (st.frac or 0) / win)
        local s = (M.sprout_scale or 0.30) * (0.45 + 0.55 * f)
        local sv = ValueType.new(sdk.find_type_definition("via.vec3"))
        sv.x, sv.y, sv.z = s, s, s
        if not pcall(function() t:call("set_LocalScale", sv) end) then pcall(function() t:call("set_Scale", sv) end) end
        local q = _euler_quat(b.yaw or 0, b.fit_pitch or 0, b.fit_roll or 0)
        local qt = ValueType.new(sdk.find_type_definition("via.Quaternion"))
        qt.x, qt.y, qt.z, qt.w = q.x, q.y, q.z, q.w
        t:call("set_Rotation", qt)
    end)
end

local function _drop_sprout(b)
    if b.sprout then pcall(function() b.sprout:call("destroy", b.sprout) end) end
    b.sprout, b.sprout_mc, b.sprout_stage, b.sprout_at = nil, nil, nil, nil
end

-- ⭐ TESTING AID (Aurora 2026-08-08): "grow all nearby crops ready to gather" so a bed full of
-- fresh seed can be harvested immediately instead of waiting several in-game days per test.
-- Ripeness is simply `grown >= crop.days`, so we set grown to the target, mark the bed watered
-- today and clear the dry/missed counters — a force-grown crop reads as a WELL-TENDED one, so
-- the harvest grade is the good-case grade rather than a wilted accident.
-- ⛔ Drops the live prop and the sprout so the visual respawns at full ripe size; leaving the
-- old carrier up would show a half-grown plant on a bed the game now considers ready.
local function _grow_nearby(radius)
    local up = _pupos(); if not up then return 0 end
    local r2 = (tonumber(radius) or 25.0) ^ 2
    local n, today = 0, _today()
    for _, b in ipairs(beds) do
        if b.crop then
            local dx, dz = (b.ux or 0) - up.x, (b.uz or 0) - up.z
            if dx * dx + dz * dz <= r2 then
                local c = _crop(b.crop)
                if c then
                    b.grown = math.max(b.grown or 0, c.days or 3)
                    b.dry, b.missed = 0, 0
                    b.watered_day = today
                    if b.live then pcall(function() b.live:call("destroy", b.live) end); b.live = nil end
                    b.pending = nil
                    _drop_sprout(b)
                    n = n + 1
                end
            end
        end
    end
    if n > 0 then _save(); _log(string.format("TEST: force-grew %d crop(s) to ripe", n)) end
    return n
end

-- runs the bind -> cure phases for any bed whose carrier is up
local function _pump_mound_binds()
    local now = os.clock()
    -- the auditioner rides the same phases
    if audition and audition.mc then
        if audition.stage == "bind" and now > (audition.at or 0) then
            pcall(function() audition.mc:call("set_Enabled", false) end)
            _bind_path(audition.mc, audition.base)
            audition.stage, audition.at = "cure", now + 1.2
        elseif audition.stage == "cure" and now >= (audition.at or 0) then
            _bind_path(audition.mc, audition.base)          -- the curative re-bind
            local mn = "?"
            pcall(function() mn = tostring(audition.mc:call("get_MaterialNum")) end)
            -- ⭐⭐ THE SCENERY PIVOT LIE, AND WHY NOTHING APPEARED (Aurora 08-04: "I tried the meshes
            -- but nothing appeared at all no matter how many times I clicked"). The log proved all
            -- three BOUND - MaterialNum 3, 1 and 2 - so the paths and the resources were fine.
            -- These are CHUNK-BAKED props: their vertices carry the world offset they sit at inside
            -- their environment chunk, so the GameObject origin can be 100m+ from the geometry. We
            -- put the origin at her feet and the actual mesh landed streets away.
            -- FIX = read the bound mesh's own bounding box and shove the carrier by MINUS its
            -- centre, which drags the geometry onto the spot she's looking at. Logged either way,
            -- so a mesh that still doesn't show is a different failure and we'll know it.
            -- ⛔ v1 guessed "get_BoundingBox" and logged "no bounding box readable" - the name
            -- doesn't exist on via.render.Mesh. v2 GUESSES NOTHING: walk the component's real
            -- method list (and its mesh resource's) for anything AABB-shaped, try each zero-arg
            -- one, and take the first result that yields a min/max pair. The names it finds are
            -- logged once, so the working one can be hard-coded afterwards.
            local cx, cy, cz, sx, sy, sz
            local tried = {}
            pcall(function()
                local function corners(bb)
                    if not bb then return end
                    local mn2, mx2
                    for _, f in ipairs({ "minpos", "MinPos", "_MinPos", "min" }) do
                        if mn2 == nil then pcall(function() mn2 = bb:get_field(f) end) end
                    end
                    for _, f in ipairs({ "maxpos", "MaxPos", "_MaxPos", "max" }) do
                        if mx2 == nil then pcall(function() mx2 = bb:get_field(f) end) end
                    end
                    if mn2 == nil then pcall(function() mn2 = bb.minpos end) end
                    if mx2 == nil then pcall(function() mx2 = bb.maxpos end) end
                    if mn2 and mx2 and mn2.x and mx2.x then return mn2, mx2 end
                end
                local function scan(obj)
                    if not obj or cx then return end
                    local td
                    pcall(function() td = obj:get_type_definition() end)
                    if not td then return end
                    for _, m in ipairs(td:get_methods()) do
                        if cx then break end
                        local n = m:get_name() or ""
                        if (n:lower():find("aabb") or n:lower():find("bound")) and m:get_num_params() == 0 then
                            tried[#tried + 1] = td:get_full_name() .. "." .. n
                            local bb
                            pcall(function() bb = obj:call(n .. "()") end)
                            if bb == nil then pcall(function() bb = m:invoke(obj, {}) end) end
                            local mn2, mx2 = corners(bb)
                            if mn2 then
                                cx, cy, cz = (mn2.x + mx2.x) * 0.5, (mn2.y + mx2.y) * 0.5, (mn2.z + mx2.z) * 0.5
                                sx, sy, sz = mx2.x - mn2.x, mx2.y - mn2.y, mx2.z - mn2.z
                                audition.aabb_world = n:lower():find("world") ~= nil
                                tried[#tried] = tried[#tried] .. " <== WORKED"
                            end
                        end
                    end
                end
                scan(audition.mc)
                if not cx then
                    local res
                    pcall(function() res = audition.mc:call("getMesh") end)
                    if not res then pcall(function() res = audition.mc:call("get_Mesh") end) end
                    scan(res)
                end
            end)
            if #tried > 0 then _log("audition AABB probe: " .. table.concat(tried, ", ")) end
            if cx then
                -- displacement: a LOCAL box's centre IS the baked offset; a WORLD box's offset is
                -- measured from wherever the carrier actually stands
                local off = math.sqrt(cx * cx + cz * cz)
                if audition.aabb_world and audition.go then
                    pcall(function()
                        local p = audition.go:call("get_Transform"):call("get_Position")
                        local dx, dz = cx - p.x, cz - p.z
                        off = math.sqrt(dx * dx + dz * dz)
                    end)
                end
                _log(string.format("audition '%s' bound, MaterialNum=%s | size %.1fx%.1fx%.1fm | geometry centre is %.1fm from the origin",
                    tostring(audition.base), mn, sx or -1, sy or -1, sz or -1, off))
                -- only re-centre when it's actually displaced; a well-behaved prop is left alone
                if off > 2.0 and audition.go then
                    pcall(function()
                        local t = audition.go:call("get_Transform")
                        local p = t:call("get_Position")
                        local v = ValueType.new(sdk.find_type_definition("via.vec3"))
                        if audition.aabb_world then
                            -- WORLD box: the geometry is AT (cx,cy,cz); shift the carrier by the
                            -- difference so the geometry lands on the carrier's spot
                            v.x, v.y, v.z = p.x + (p.x - cx), p.y + (p.y - cy) + (sy or 0) * 0.5, p.z + (p.z - cz)
                        else
                            -- LOCAL box: the baked offset IS the centre; subtract it
                            v.x, v.y, v.z = p.x - cx, p.y - cy + (sy or 0) * 0.5, p.z - cz
                        end
                        t:call("set_Position", v)
                    end)
                    _log("audition RE-CENTRED by " .. string.format("%.1fm (%s box)", off,
                        audition.aabb_world and "world" or "local") .. " - it should be in front of you now")
                end
            else
                _log("audition '" .. tostring(audition.base) .. "' bound, MaterialNum=" .. mn
                    .. " | ⚠ no bounding box readable - if you can't see it, it's the chunk-pivot offset")
            end
            -- READBACK: the final truth about the carrier, so "invisible" is never a guess again
            pcall(function()
                local t = audition.go and audition.go:call("get_Transform")
                local p = t and t:call("get_Position")
                local sc = t and t:call("get_LocalScale")
                local q; pcall(function() q = t and t:call("get_Rotation") end)
                _log(string.format("audition readback: pos(%.1f,%.1f,%.1f) scale(%.2f,%.2f,%.2f) rot(%.2f,%.2f,%.2f,%.2f)",
                    p and p.x or -1, p and p.y or -1, p and p.z or -1,
                    sc and sc.x or -1, sc and sc.y or -1, sc and sc.z or -1,
                    q and q.x or -9, q and q.y or -9, q and q.z or -9, q and q.w or -9))
            end)
            audition.stage, audition.mc = "done", nil
        end
    end
    for _, b in ipairs(beds) do
        if b.mound_mc and b.mound_stage == "bind" and now > (b.mound_at or 0) then
            pcall(function() b.mound_mc:call("set_Enabled", false) end)
            _bind_mound_mesh(b.mound_mc, b.mound_base)
            b.mound_stage, b.mound_at = "cure", now + 1.2
        elseif b.mound_mc and b.mound_stage == "cure" and now >= (b.mound_at or 0) then
            _bind_mound_mesh(b.mound_mc, b.mound_base)          -- the curative re-bind
            local mn = "?"
            pcall(function() mn = tostring(b.mound_mc:call("get_MaterialNum")) end)
            _log("seed bed bound, MaterialNum=" .. mn .. " (>0 = the mesh took)")
            b.mound_stage, b.mound_mc = "done", nil
        end
        -- the sprout rides the same three laws: warm, holder-bind, then a curative re-bind
        if b.sprout_mc and b.sprout_stage == "bind" and now > (b.sprout_at or 0) then
            pcall(function() b.sprout_mc:call("set_Enabled", false) end)
            _bind_path(b.sprout_mc, tostring(M.sprout_mesh or ""))
            b.sprout_stage, b.sprout_at = "cure", now + 1.2
        elseif b.sprout_mc and b.sprout_stage == "cure" and now >= (b.sprout_at or 0) then
            _bind_path(b.sprout_mc, tostring(M.sprout_mesh or ""))
            local mn = "?"
            pcall(function() mn = tostring(b.sprout_mc:call("get_MaterialNum")) end)
            _log("sprout bound, MaterialNum=" .. mn .. " (>0 = the mesh took)")
            b.sprout_stage, b.sprout_mc = "done", nil
        end
    end
end


-- ⭐ WET SOIL DARKENING (Aurora 08-04: "can we have the farmland darken when it's watered?").
-- Live material write on the bed's own mesh: find any material variable with "Color" in its name
-- and multiply it down while the bed is watered today. Everything is probed, attempted and LOGGED
-- once, so if this mdf2 exposes no colour variable the log says exactly that and the fallback is
-- a pre-darkened wet-mdf2 in the pak (⚠ mdf2 strings are OFFSET-LOCKED - a wet variant must keep
-- every path the same length, e.g. frm_ALBD -> wet_ALBD).
local tint_logged = false
local function _bed_tint(b, wet)
    if not (b.mound and M.wet_tint ~= false) then return end
    pcall(function()
        local mc = b.mound:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
        if not mc then return end
        local n = tonumber(mc:call("get_MaterialNum")) or 0
        local k = wet and (M.wet_dark or 0.55) or 1.0
        local wrote = 0
        for mi = 0, n - 1 do
            local vn = 0
            pcall(function() vn = tonumber(mc:call("getMaterialVariableNum", mi)) or 0 end)
            for vi = 0, vn - 1 do
                local nm
                pcall(function() nm = tostring(mc:call("getMaterialVariableName", mi, vi)) end)
                if nm and nm:lower():find("color") then
                    local ok = false
                    pcall(function()
                        local v4 = ValueType.new(sdk.find_type_definition("via.Float4"))
                        v4.x, v4.y, v4.z, v4.w = k, k, k, 1.0
                        mc:call("setMaterialFloat4", mi, vi, v4)
                        ok = true
                    end)
                    if ok then wrote = wrote + 1 end
                    if not tint_logged then
                        _log("wet tint: variable '" .. nm .. "' -> " .. (ok and "SET" or "set FAILED"))
                    end
                end
            end
        end
        if not tint_logged then
            tint_logged = true
            if wrote == 0 then
                _log(string.format("wet tint: NO colour variable on %d material(s) - needs the wet-mdf2 pak route", n))
            end
        end
        if wrote > 0 then b.wet_applied = wet end
    end)
end

-- ── ⭐⭐ THE COOKING FIRE (Aurora 08-04: "putting an invisible campfire with the cookpot to let
-- them interact and cook with it"). Spawn a real campfire where her cookpot furniture stands, then
-- hide its MESHES, so the wood is invisible under the pot. Streams in/out by range like crops;
-- persists its spots to cookfire.json.
-- ⛔⛔ THIS COMMENT USED TO CLAIM "no separate cook system to mod - the campfire's own interaction IS
-- the cooking UI", AND THAT WAS FALSE — contradicted twice in this very file (the 08-04 field note
-- that gm51_381 "spawns a LIT tripod-cauldron visual but carries NO cook interaction", and the
-- cookpot-menu header's "the camp cook UI proved system-driven, five gimmick candidates, no prompt,
-- so the pot cooks through OUR dialog instead"). It sat directly above this still-live code that was
-- written on its premise. Corrected 2026-08-12 — a stale premise in a comment above working code is
-- how the LB-swing bug survived eight days.
-- ⇒ WHAT THIS FEATURE ACTUALLY BUYS: a lit fire and NPC/pawn ambience under the pot. It does NOT
-- supply a cook prompt to anybody — ours does (see `cookpot.gids`). Currently dormant: cookfire.json
-- holds `{"fires": null}`, so `_tick_cookfires` spawns nothing until the panel button places one.
local COOKFIRE_FILE = "IRIS/cookfire.json"
local cookfires = {}
pcall(function()
    local d = json.load_file(COOKFIRE_FILE)
    if d and d.fires then cookfires = d.fires end
end)
local function _save_cookfires() pcall(function() json.dump_file(COOKFIRE_FILE, { fires = cookfires }) end) end
-- hide every render mesh on the gimmick AND its children (a prefab nests its visuals)
local function _hide_mesh_tree(go, depth)
    local hid = 0
    if not go or (depth or 0) > 6 then return 0 end
    pcall(function()
        local arr = go:call("getComponents(System.Type)", sdk.typeof("via.render.Mesh"))
        local n = arr and arr:get_size() or 0
        for i = 0, n - 1 do
            pcall(function() arr:get_element(i):call("set_Enabled", false); hid = hid + 1 end)
        end
        local t = go:call("get_Transform")
        -- LINKED-LIST child walk (get_Child/get_Next - the _pickaxe_wp_go pattern); the
        -- count/index API silently saw no children ("0 mesh(es) hidden", twice)
        local child = t:call("get_Child")
        while child do
            pcall(function()
                local cgo = child:call("get_GameObject")
                hid = hid + _hide_mesh_tree(cgo, (depth or 0) + 1)
            end)
            child = child:call("get_Next")
        end
    end)
    return hid
end
local function _tick_cookfires()
    local up = _pupos(); if not up then return end
    for _, cf in ipairs(cookfires) do
        local dx, dz = cf.ux - up.x, cf.uz - up.z
        local near = (dx * dx + dz * dz) <= (M.spawn_radius * M.spawn_radius)
        if near and not cf.live and not cf.pending then
            cf.pending = os.clock()
            local ok = _queue_spawn(M.cookfire_gid or "gm51_381", cf.ux, cf.uy, cf.uz, cf.yaw or 0, function(go)
                cf.live = go; cf.pending = nil
                if M.cookfire_hide ~= false then
                    local n = _hide_mesh_tree(go, 0)
                    _log("cooking fire up - " .. n .. " mesh(es) hidden (the pot provides the visual)")
                else
                    _log("cooking fire up (visible)")
                end
            end, 1.0)
            if not ok then
                cf.pending = nil
                _log("cooking fire: spawn queue REFUSED for " .. tostring(M.cookfire_gid))
            else
                _log("cooking fire: queued " .. tostring(M.cookfire_gid))
            end
        elseif cf.pending and os.clock() - cf.pending > 20.0 then
            cf.pending = nil
        elseif cf.live and not near then
            pcall(function() cf.live:call("destroy", cf.live) end); cf.live = nil
        end
    end
end

local lc = { at = 0 }
local function _tick_props()
    if os.clock() - lc.at < (M.tick_every or 0.5) then return end
    lc.at = os.clock()
    local up = _pupos(); if not up then return end
    for _, b in ipairs(beds) do
        local dx, dz = b.ux - up.x, b.uz - up.z
        local near = (dx * dx + dz * dz) <= (M.spawn_radius * M.spawn_radius)
        -- ⭐ SPROUT vs FINISHED PLANT. While the crop is below the sprout window the bed shows the
        -- little shoot mesh and the real gather node is NOT spawned at all - so an apple crop is a
        -- green shoot for its first days instead of a doll's-house apple tree. They swap at the
        -- threshold. With no sprout mesh configured this stays false and nothing changes.
        local sprouting = false
        if b.crop and tostring(M.sprout_mesh or "") ~= "" then
            local st = _bed_state(b)
            sprouting = (st ~= nil) and not st.ripe and (st.frac or 0) < (M.sprout_until or 0.5)
        end
        if b.crop and near and not sprouting and not b.live and not b.pending then
            local c = _crop(b.crop)
            local d = _delta()
            if c and d then
                b.pending = os.clock()
                -- ⛔ SPAWN TAKES UNIVERSAL COORDS. The GenerateManager container's _InitialPosition
                -- is a via.Position (universal doubles); handing it render coords made the engine
                -- subtract the rebase offset a SECOND time and the props landed ~1000m away
                -- (Aurora 07-26: QUEUED render(-244.7,16.7,-251.4) -> UP render(-628.7,16.7,644.6)).
                -- IrisFurnish always passed universal, which is why furniture never had this bug.
                local rx, ry, rz = b.ux, b.uy, b.uz
                _log(string.format("crop QUEUED %s (%s) at universal(%.1f,%.1f,%.1f)", c.name, c.gid, rx, ry, rz))
                local ok = _queue_spawn(c.gid, rx, ry, rz, b.yaw or 0, function(go)
                    b.live = go; b.pending = nil; _apply_transform(b)
                    local p; pcall(function() p = go:call("get_Transform"):call("get_Position") end)
                    _log(string.format("crop UP %s at render(%.1f,%.1f,%.1f)", c.gid,
                        p and p.x or -1, p and p.y or -1, p and p.z or -1))
                end, M.scale_min)
                if not ok then b.pending = nil; _log("crop spawn REFUSED for " .. tostring(c.gid)) end
            end
        elseif b.pending and type(b.pending) == "number" and os.clock() - b.pending > 20.0 then
            b.pending = nil
            _log("crop spawn never returned - retrying")
        elseif b.live and b.crop then
            -- ⭐ NATIVE B-GATHER DETECTION (08-04). A ripe crop is a REAL gather node, so the game
            -- offers its own Gather on it. If the player takes it, the node is consumed OUTSIDE
            -- our harvest flow - and without this check the bed still thought it was ripe and
            -- re-grew the visual: infinite (and for vegetables, WRONG) items. A b.live that WE
            -- didn't destroy going invalid = the player just gathered it natively. Interim rule:
            -- the bed clears (native pickup was the payout, no double-dip); the DROP-REPOINT plan
            -- (make the native gather grant OUR graded items) rides on the probe below.
            local dead = false
            pcall(function() dead = b.live:call("get_Valid") == false end)
            if dead then
                b.live = nil
                local nm = (_crop(b.crop) or {}).name or b.crop
                b.crop, b.grown, b.watered_day, b.dry, b.missed = nil, 0, nil, 0, 0
                _save()
                _log("'" .. tostring(nm) .. "' was gathered NATIVELY (B) - bed cleared, re-sow it")
            elseif not near then
                pcall(function() b.live:call("destroy", b.live) end); b.live = nil
            else
                _apply_transform(b)
            end
        elseif b.live and (not near or not b.crop) then
            pcall(function() b.live:call("destroy", b.live) end); b.live = nil
        elseif b.live then
            _apply_transform(b)
        end
        -- WET DARKENING: track the watered state onto the bed material (re-asserts after mound
        -- respawns too, because b.wet_applied is cleared when the mound is dropped)
        if b.mound then
            local wet = (b.crop ~= nil) and (b.watered_day == _today())
            -- hold the darkening until the pour actually reaches the soil
            if wet and b.tint_at and os.clock() < b.tint_at then wet = b.wet_applied == true end
            if b.wet_applied ~= wet then
                _bed_tint(b, wet)
                if wet then b.tint_at = nil end
            end
        end
        -- THE SPROUT: the shoot that stands in for the plant while it's still coming up
        if sprouting and near and not b.sprout then
            if b.live then pcall(function() b.live:call("destroy", b.live) end); b.live = nil end
            _spawn_sprout_mesh(b)
        elseif b.sprout and (not near or not sprouting) then
            _drop_sprout(b)          -- out of range, harvested, uprooted, or grown past the window
        elseif b.sprout then
            _apply_sprout(b)
        end
        -- THE MOUND: a bed must be VISIBLE the moment it's hoed, before anything is sown
        -- (Aurora 07-25 - clearing the grass alone left nothing to aim at). Streams like the crop.
        if M.mound_show and near and not b.mound and not b.mound_pending and M.mound_mesh ~= "" then
            -- CUSTOM MESH route (Aurora's farmland asset): bare GameObject, no collision
            if b.mound_base or _warm_mound_mesh() then _spawn_mound_mesh(b) else b.mound_pending = os.clock() end
        elseif M.mound_show and near and not b.mound and not b.mound_pending then
            local d = _delta()
            if d then
                b.mound_pending = os.clock()   -- a TIMESTAMP, not `true`: a spawn that never calls
                                               -- back left this stuck forever and the mound never retried
                -- UNIVERSAL, not render - see the crop spawn above for why
                local rx, ry, rz = b.ux, b.uy - (M.mound_sink or 0.0), b.uz
                _log(string.format("mound QUEUED %s at universal(%.1f,%.1f,%.1f) scale %.2f",
                    tostring(M.mound_gid), rx, ry, rz, M.mound_scale or 0.35))
                local ok = _queue_spawn(M.mound_gid or "gm51_573", rx, ry, rz, b.yaw or 0, function(go)
                    b.mound = go; b.mound_pending = nil
                    local p, nm
                    pcall(function() p = go:call("get_Transform"):call("get_Position") end)
                    pcall(function() nm = tostring(go:call("get_Name")) end)
                    local dd = _delta()
                    local ex, ez = b.ux - ((dd and dd.x) or 0), b.uz - ((dd and dd.z) or 0)
                    local off = (p and dd) and math.sqrt((p.x - ex) ^ 2 + (p.z - ez) ^ 2) or -1
                    _log(string.format("mound UP '%s' render(%.1f,%.1f,%.1f) expected(%.1f,_,%.1f) off by %.1fm",
                        tostring(nm), p and p.x or -1, p and p.y or -1, p and p.z or -1, ex, ez, off))
                end, M.mound_scale or 0.35)
                if not ok then b.mound_pending = nil; _log("mound spawn REFUSED (no GimmickID?)") end
            end
        elseif b.mound_pending and type(b.mound_pending) == "number"
            and os.clock() - b.mound_pending > 20.0 then
            b.mound_pending = nil            -- give up and let the next pass try again
            _log("mound spawn never returned - retrying")
        elseif b.mound and (not near or not M.mound_show) then
            pcall(function() b.mound:call("destroy", b.mound) end); b.mound = nil
        end
    end
end
-- ⭐ EMERGENCY CLEANUP (Aurora 07-26: "the mounds are HUGE stone gimmicks that I am now trapped
-- inside"). A script reset reloads `beds` from JSON with no prop refs, so anything already spawned
-- is ORPHANED and survives until an area reload - our own handles can't reach it. So sweep by
-- POSITION instead, exactly like IrisFurnish's _destroy_at: kill every gimmick standing near a
-- bed, tracked or not. Also clears the refs so the props respawn cleanly afterwards.
local function _sweep_bed_props(radius)
    local killed = 0
    local d = _delta(); if not d then _log("cleanup: no player"); return 0 end
    local r2 = (radius or 5.0) ^ 2
    pcall(function()
        local smgr = sdk.get_native_singleton("via.SceneManager")
        local scene = smgr and sdk.call_native_func(smgr, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        local arr = scene and scene:call("findComponents(System.Type)", sdk.typeof("app.GimmickBase"))
        local n = arr and arr:get_size() or 0
        local kill = {}
        for i = 0, (tonumber(n) or 0) - 1 do
            pcall(function()
                local c = arr:get_element(i)
                local go = c:call("get_GameObject")
                local p = go:call("get_Transform"):call("get_Position")
                -- near a BED...
                local hit = false
                for _, b in ipairs(beds) do
                    local bx, bz = b.ux - d.x, b.uz - d.z      -- bed in RENDER space
                    local dx, dz = p.x - bx, p.z - bz
                    if dx * dx + dz * dz <= r2 then hit = true; break end
                end
                -- ...or near YOU, so audition props spawned at your feet get cleared too
                if not hit then
                    local rp = _ppos()
                    if rp then
                        local dx, dz = p.x - rp.x, p.z - rp.z
                        if dx * dx + dz * dz <= r2 then hit = true end
                    end
                end
                if hit then kill[#kill + 1] = go end
            end)
        end
        for _, go in ipairs(kill) do
            pcall(function() go:call("destroy", go); killed = killed + 1 end)
        end
    end)
    for _, b in ipairs(beds) do
        b.mound, b.live, b.mound_pending, b.pending = nil, nil, nil, nil
        b.mound_mc, b.mound_stage, b.mound_at = nil, nil, nil
    end
    _log(string.format("cleanup: destroyed %d gimmick(s) within %.1fm of %d bed(s)", killed, radius or 5.0, #beds))
    return killed
end

-- every prop a bed owns, gone (used when a bed is removed or the mound prop is swapped)
local function _drop_bed_props(b)
    if b.live then pcall(function() b.live:call("destroy", b.live) end); b.live = nil end
    if b.mound then pcall(function() b.mound:call("destroy", b.mound) end); b.mound = nil end
    -- the custom-mesh carrier's bind state dies with it, or _pump_mound_binds keeps poking a
    -- component whose GameObject is gone
    b.pending, b.mound_pending, b.mound_mc, b.mound_stage, b.mound_at = nil, nil, nil, nil, nil
    b.clearing = nil   -- so a re-spawned bed is allowed to queue a fresh foliage clear
    b.wet_applied = nil -- a fresh mound spawns untinted; the tick re-darkens a watered bed
    _drop_sprout(b)    -- the shoot carrier is a bed prop too, and leaks if it's forgotten here
end

-- ── finding beds ──────────────────────────────────────────────────────────────────────────
-- the bed AT a given spot: what the HOE acts on, since the hoe strikes the ring position out in
-- front of you, not the ground you're stood on. (_nearest_bed below is player-centred and is what
-- the TEND button uses - you stand on a bed to sow or water it.)
local function _bed_at(ux, uz, radius)
    local r2 = (radius or M.bed_spacing or 1.6) ^ 2
    local best, bd
    for _, b in ipairs(beds) do
        local dx, dz = b.ux - ux, b.uz - uz
        local dd = dx * dx + dz * dz
        if dd <= r2 and (not bd or dd < bd) then bd = dd; best = b end
    end
    return best
end

-- where a hoe swing lands, in universal coords (the ring draws this exact spot).
-- ⭐ AIM LATCH (Aurora 07-26: "the animation moved it forward a bit and ended up destroying the
-- adjacent one, even though the crosshair was green when I pressed the button"). The swing
-- animation drives the player forward, so by the time the strike lands at impact_delay the spot
-- has drifted - green becomes amber and a bed gets levelled instead of made. IrisWoodcutting calls
-- _G.IrisFarming.aim() the moment the swing ACTION fires; the strike then uses that frozen spot.
local aim = { x = nil, y = nil, z = nil, at = 0 }
local function _till_spot(live)
    if not live and aim.x and (os.clock() - (aim.at or 0)) < (M.aim_hold or 2.0) then
        return aim.x, aim.y, aim.z
    end
    local up = _pupos(); if not up then return nil end
    local fx, fz = _pfwd()
    return up.x + fx * M.till_ahead, up.y, up.z + fz * M.till_ahead
end
local function _aim_latch()
    local x, y, z = _till_spot(true)          -- always the LIVE spot, never a stale latch
    if x then
        local fx, fz = _pfwd()
        aim.x, aim.y, aim.z, aim.at = x, y, z, os.clock()
        aim.yaw = math.deg(math.atan(fx, fz))  -- freeze the FACING too, or a turn mid-swing skews it
    end
end
local function _aim_clear() aim.x, aim.y, aim.z, aim.yaw, aim.at = nil, nil, nil, nil, 0 end

local function _nearest_bed()
    local up = _pupos(); if not up then return nil end
    local best, bd
    for _, b in ipairs(beds) do
        local dx, dz = b.ux - up.x, b.uz - up.z
        local dd = dx * dx + dz * dz
        if not bd or dd < bd then bd = dd; best = b end
    end
    if best and bd <= (M.act_radius * M.act_radius) then return best, math.sqrt(bd) end
end
-- (relocated below _nearest_bed 08-04: defined above it, the call compiled as a nil GLOBAL
-- and crashed the button - the ordering law's fifth catch this project)
-- ⭐ NATIVE-GATHER PROBE (08-04): dump every Item/Drop-ish field on the nearest live crop gimmick.
-- This is the data the DROP-REPOINT plan needs - if the node's granted item is a writable field,
-- native B-gather can hand out OUR graded items and the whole harvest becomes native-feeling.
local function _probe_gather_fields()
    local b = _nearest_bed()
    if not (b and b.live) then _log("gather probe: stand at a bed whose crop prop is spawned"); return end
    pcall(function()
        local go = b.live
        local seen = 0
        local function scan_obj(obj, label)
            local td
            pcall(function() td = obj:get_type_definition() end)
            if not td then return end
            for _, f in ipairs(td:get_fields()) do
                local fn = f:get_name() or ""
                if fn:lower():find("item") or fn:lower():find("drop") or fn:lower():find("pick") then
                    local v = "?"
                    pcall(function() v = tostring(f:get_data(obj)) end)
                    _log("gather probe: " .. label .. "." .. fn .. " = " .. v)
                    seen = seen + 1
                end
            end
        end
        local arr = go:call("get_Components")
        local n = arr and arr:get_size() or 0
        for i = 0, n - 1 do
            local c = arr:get_element(i)
            local tn = "?"
            pcall(function() tn = c:get_type_definition():get_full_name() end)
            scan_obj(c, tn)
            -- ⭐ v2 (08-04): the name-matching pass only surfaced 4 fields (IsGivedItem,
            -- _BackStageDropDataID, OnGatherItem) - the actual drop table sits deeper. Dump EVERY
            -- field of the app.Gm* component itself, capped, so the item linkage shows.
            if tn:find("^app%.Gm") then
                local dumped = 0
                pcall(function()
                    local td = c:get_type_definition()
                    while td and dumped < 60 do
                        for _, f in ipairs(td:get_fields()) do
                            if dumped >= 60 then break end
                            local fn = f:get_name() or "?"
                            local v = "?"
                            pcall(function() v = tostring(f:get_data(c)) end)
                            _log("  GMFULL " .. tn .. "." .. fn .. " = " .. v)
                            dumped = dumped + 1
                            -- v3: GatherContext is a managed object - ITS fields are where the
                            -- granted item must live. One level deep, capped.
                            if fn == "GatherContext" or fn == "<CompGenerateInfo>k__BackingField" then
                                pcall(function()
                                    local sub = f:get_data(c)
                                    local std = sub and sub:get_type_definition()
                                    local sdumped = 0
                                    while std and sdumped < 40 do
                                        for _, sf in ipairs(std:get_fields()) do
                                            if sdumped >= 40 then break end
                                            local sv = "?"
                                            pcall(function() sv = tostring(sf:get_data(sub)) end)
                                            _log("    GCTX " .. fn .. "." .. (sf:get_name() or "?") .. " = " .. sv)
                                            sdumped = sdumped + 1
                                        end
                                        std = std:get_parent_type()
                                    end
                                end)
                            end
                        end
                        td = td:get_parent_type()   -- walk the base classes: GmGatherBase etc
                    end
                end)
            end
        end
        _log("gather probe: done - " .. seen .. " field(s) over " .. n .. " component(s)")
    end)
end


-- ── THE FOUR ACTIONS ──────────────────────────────────────────────────────────────────────
-- TILLING IS A HOE SWING (Aurora 07-25), not a button prompt: IrisWoodcutting's swing gate sees a
-- kind="SOIL" tool in hand and calls _G.IrisFarming.till("swing") at the impact frame.
-- ⭐ ALIGNMENT + SNAPPING, shared by the SWING and the RING (Aurora 07-26 rows + 08-05 auto-aim).
-- Nearest existing bed within snap_dist: inherit its EXACT yaw and land on ITS grid, so patches
-- butt into a continuous row - and because the ring runs the same math, the crosshair visibly
-- LOCKS onto the next free cell as you aim around a row. Nothing near? Square the yaw to a step.
local function _snap_spot(ux, uy, uz, yaw)
    local anchor, ad
    local snap_lift = 0.0
    for _, b in ipairs(beds) do
        local dx, dz = b.ux - ux, b.uz - uz
        local dd = dx * dx + dz * dz
        if dd <= (M.snap_dist or 3.0) ^ 2 and (not ad or dd < ad) then ad = dd; anchor = b end
    end
    if M.snap ~= false and anchor then
        yaw = anchor.yaw or 0
        local ry = math.rad(yaw)
        local afx, afz = math.sin(ry), math.cos(ry)      -- matches _pfwd's atan(fx,fz)
        local arx, arz = afz, -afx
        local ox, oz = ux - anchor.ux, uz - anchor.uz
        local along = ox * afx + oz * afz
        local across = ox * arx + oz * arz
        local L, W = M.bed_len or 1.40, M.bed_wid or 0.95
        local na = math.floor(along / L + 0.5)
        local nc = math.floor(across / W + 0.5)
        -- na==0,nc==0 = the anchor's own cell IS the target: that's how you aim the UNDO (and the
        -- ring shows amber there). The old push-away guard made beds untargetable (Aurora 08-05:
        -- "you can't snap to undo farmland"). do_till never sees this case - _hoe_strike's bed
        -- check catches it first.
        ux = anchor.ux + afx * (na * L) + arx * (nc * W)
        uz = anchor.uz + afz * (na * L) + arz * (nc * W)
        uy = anchor.uy
        snap_lift = anchor.lift or 0.0
    elseif M.snap ~= false then
        local step = M.yaw_step or 90.0
        if step > 0 then yaw = math.floor(yaw / step + 0.5) * step end
    end
    return ux, uy, uz, yaw, snap_lift, anchor
end

-- ⭐ THE CROSSHAIR PICKS THE BED (Aurora 08-05: "possible for that auto aim marker to also decide
-- which crop you're looking at for seeds/watering?"). With the hoe out, the tend key and the bed
-- prompt follow the RING's snapped target; empty-handed they fall back to the nearest bed.
local function _target_bed()
    if _hoe_equipped() then
        local ok, bhit = pcall(function()
            local ux, _uy, uz = _till_spot(true)
            if not ux then return nil end
            local fx, fz = _pfwd()
            local sx, _sy, sz = _snap_spot(ux, 0, uz, math.deg(math.atan(fx, fz)))
            return _bed_at(sx, sz)
        end)
        if ok and bhit then return bhit end
    end
    return _nearest_bed()
end

local function do_till(how)
    local plot, dist = _nearest_plot()
    if not plot or (dist or 999) > M.plot_range then
        if how == "swing" then _log("hoe swing: not at a built homestead") end
        return
    end
    local up = _pupos(); if not up then return end
    local fx, fz = _pfwd()
    -- the LATCHED spot (frozen when the swing began), so the animation's forward lunge can't move
    -- the bed after you committed. Falls back to live if nothing was latched.
    local ux, uy, uz = _till_spot()
    if not ux then ux, uy, uz = up.x + fx * M.till_ahead, up.y, up.z + fz * M.till_ahead end
    local yaw = aim.yaw or math.deg(math.atan(fx, fz))
    -- nothing under the spot = a cliff edge, a doorway, an upstairs floor. Refuse it; the ring
    -- already went red, so this only catches a swing made anyway.
    local d0 = _delta()
    if d0 and not _ground_under(ux - d0.x, up.y - d0.y, uz - d0.z, M.ground_probe or 2.5) then
        _log("no ground there to break")
        return
    end
    -- ⛔ NOT UNDER A ROOF. Crops need sky; more to the point, a bed tilled on a floorboard is a
    -- saved bed that will keep re-spawning its mesh through the floor forever.
    if M.block_indoors ~= false and d0 then
        local h = _ceiling_above(ux - d0.x, up.y - d0.y, uz - d0.z, M.roof_height or 4.0)
        if h then
            _log(string.format("there's a roof %.1fm overhead - crops need open sky", h))
            return
        end
    end

    -- (snapping now lives in _snap_spot so the target RING can PREVIEW it - Aurora 08-05's
    -- "auto-aim": the ring itself jumps onto the row grid, MMO-target style, before you commit)
    local snap_lift
    ux, uy, uz, yaw, snap_lift = _snap_spot(ux, uy, uz, yaw)

    for _, b in ipairs(beds) do
        local dx, dz = b.ux - ux, b.uz - uz
        if dx * dx + dz * dz < (M.bed_spacing * M.bed_spacing) then
            _log("too close to an existing bed"); return
        end
    end
    local d = _delta()
    local bed = { ux = ux, uy = uy, uz = uz, plot = plot.name, yaw = yaw,
        crop = nil, grown = 0, dry = 0, missed = 0, hidden = {}, lift = snap_lift }
    -- clear the growth in RENDER space (foliage lives there), leaving bare earth
    if d then _till_clear(ux - d.x, uz - d.z, M.till_clear or 1.3, bed.hidden) end
    beds[#beds + 1] = bed
    _save()
    _log(string.format("tilled a bed at (%.1f,%.1f) yaw %.0f%s - %d foliage cleared",
        ux, uz, yaw, anchor and " [snapped to the row]" or "", #bed.hidden))
end

-- SOWING IS TWO-STEP: the native dialog holds only 4 options and the crop table is 12+, so you
-- pick a CATEGORY first, then the seed. Within a category, a 4th "More..." slot pages onward.
local function _cats_with_seed()
    local order, seen = {}, {}
    for _, c in ipairs(M.crops) do
        if _seed_count(c) > 0 and not seen[c.cat] then seen[c.cat] = true; order[#order + 1] = c.cat end
    end
    return order
end
local function _crops_in_cat(cat)
    local t = {}
    for _, c in ipairs(M.crops) do if c.cat == cat and _seed_count(c) > 0 then t[#t + 1] = c end end
    return t
end
-- ⭐ EVERY PAGE ENDS IN AN ESCAPE (Aurora 07-26: "the seed place option has no back/quit button").
-- 3 entries per page; the 4th slot is "More..." while pages remain and "Cancel" on the last one,
-- so you can always reach a way out. Esc / pad-B still cancel natively too (RetVal 5).
local PER_PAGE = 3
-- ⭐ A CANCEL ON EVERY PAGE (Aurora 2026-08-08: "it'd be good if the cookpot could have a
-- cancel button on the front page too"). The dialog gives four selectable slots, and v1 spent
-- the last one on EITHER "More..." OR "Cancel" — so any list long enough to paginate had no
-- visible way out on page one. When the list paginates we show two items instead of three and
-- keep both tail options. Per-page count depends only on #items, so page arithmetic stays
-- consistent across pages.
local function _paged_dialog(prompt, items, labeller, page, phase)
    local per = (#items > 3) and (PER_PAGE - 1) or PER_PAGE
    local start = (page - 1) * per
    local opts, labels = {}, {}
    for i = 1, per do
        local it = items[start + i]
        if it then opts[#opts + 1] = it; labels[#labels + 1] = labeller(it) end
    end
    local more = (start + per) < #items
    if more then labels[#labels + 1] = "More..." end
    labels[#labels + 1] = "Cancel"
    dlg.opts, dlg.page, dlg.more = opts, page, more
    _show_dialog(prompt, labels[1], labels[2], labels[3], labels[4], phase)
end
local function _show_seed_page(cat, page)
    dlg.cat = cat
    _paged_dialog("Sow which seed?", _crops_in_cat(cat),
        function(c) return string.format("%s (%d)", c.name, _seed_count(c)) end, page, "sow_pick")
end
local function do_sow(b)
    local cats = _cats_with_seed()
    if #cats == 0 then _log("no seeds - buy some, or combine 2 of a crop to make seed"); return end
    dlg.bed = b
    if #cats == 1 then _show_seed_page(cats[1], 1); return end   -- only one kind: skip the menu
    dlg.cats = cats
    _paged_dialog("Sow what?", cats, function(c) return c end, 1, "sow_cat")
end

-- the watering performance: intro clip -> (skip the loop) -> finishing clip. Driven from the
-- pump so the second clip fires when the first has actually run its length.
local wat = { stage = nil, at = 0 }
local function _water_emote_start()
    if not M.water_emote then return end
    -- ⛔ RE-ENTRANCY (Aurora 08-05: dev+1 day mid-emote + immediate re-water OVERWROTE wat.wp -
    -- the first pour's disabled mesh comps were orphaned and the hoe went perma-invisible).
    -- One pour at a time; the watering DATA still applies, only the second emote is refused.
    if wat.stage then _log("watering: emote already in progress - data applied, emote skipped") return end
    -- ⛔ WHY THE EMOTE STOPPED PLAYING (Aurora 08-04: "water currently isn't animating at all"):
    -- do_water used to fire straight off the tend key; since the BED MENU it fires the instant
    -- the dialog closes - and our dialog PAUSES THE WORLD (the deed-sign law), so a clip painted
    -- on the very frame of unpause was swallowed by the FSM resuming. The fix is a "sheathe"
    -- pre-stage, which also delivers her other ask: the character puts the weapon away first
    -- (FastSheatheWeapon, priority 10 - the woodcutter's proven self-request; harmless if the
    -- weapon is already sheathed) and the clip starts only after that beat.
    -- ⚠ 08-04 v2: was FastSheatheWeapon, fire-and-forget, freeze at 0.9s - the weapon stayed in
    -- hand (the request either didn't take or the freeze caught the sheathe mid-animation).
    -- Now: plain SheatheWeapon (the standing-idle variant in the action log), the result is
    -- LOGGED, and the freeze waits 1.3s so the put-away can actually finish.
    local okc = false
    pcall(function()
        local am = _pch():call("get_ActionManager")
        okc = pcall(function()
            am:call("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)",
                10, "SheatheWeapon", 0)
        end)
    end)
    _log("watering: sheathe requested (ok=" .. tostring(okc) .. ")")
    wat.stage, wat.at = "sheathe", os.clock()
end
local function _water_emote_pump()
    if not wat.stage then return end
    local dt = os.clock() - (wat.at or 0)
    if wat.stage == "sheathe" and dt >= (M.water_sheathe_s or 0.9) then
        _pfsm(false)         -- hold the body: the FSM re-drives layer 0 every frame otherwise
        -- ⭐ HIDE THE HELD WEAPON for the emote (08-04: the sheathe request reported ok=true and
        -- the tool STAYED in her hand - whether the action was silently rejected or the freeze
        -- caught it mid-animation, a visual hide cannot be refused. The clip carries its own
        -- watering can; the tool comes back the moment the emote ends.)
        wat.wp = {}
        pcall(function()
            -- ⛔ via.Transform children are a LINKED LIST here: get_Child() (no index) then
            -- get_Next() - the count/index API my first version used silently returned nothing
            -- ("0 weapon(s) hidden"). The pattern is _pickaxe_wp_go's, proven on this exact walk.
            -- ⛔ TOOLS ONLY (the arrow lesson): a bare ^wp name match also catches arrow/quiver
            -- props. Only a child whose app.Weapon ID is one of OUR tools is the thing in her
            -- hand for farming - everything else is the game's business.
            local TOOL_WP = { [47200] = true, [47210] = true, [47220] = true }
            local tf = _ptf()
            local child = tf:call("get_Child")
            while child do
                pcall(function()
                    local go = child:call("get_GameObject")
                    local nm = go and tostring(go:call("get_Name")) or ""
                    if nm:find("^wp") and go:call("get_DrawSelf") ~= false then
                        local w = go:call("getComponent(System.Type)", sdk.typeof("app.Weapon"))
                        local id
                        if w then
                            pcall(function() id = w:get_field("ID") end)
                            if id == nil then pcall(function() id = w:get_field("<ID>k__BackingField") end) end
                            if id == nil then pcall(function() id = w:call("get_ID") end) end
                        end
                        if TOOL_WP[tonumber(id) or -1] then
                            -- ⛔ set_DrawSelf on the wp GO does NOT stop the weapon rendering
                            -- (00:25 log: 'wp02_000_00 id=47220 HIDDEN' and the tool stayed in her
                            -- hand). Kill the MESH COMPONENTS themselves - self + children - and
                            -- remember each one so the restore is exact, never a sweep.
                            local function eat(g, depth)
                                if not g or depth > 4 then return end
                                pcall(function()
                                    -- SINGULAR getComponent - the reskin's proven call on this
                                    -- exact GO; getComponents(plural) returned NOTHING (log:
                                    -- "0 mesh comp(s) disabled" while the weapon kept drawing)
                                    local mcp = g:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
                                    if mcp and mcp:call("get_Enabled") ~= false then
                                        mcp:call("set_Enabled", false)
                                        wat.wp[#wat.wp + 1] = mcp
                                    end
                                    local c2 = g:call("get_Transform"):call("get_Child")
                                    while c2 do
                                        pcall(function() eat(c2:call("get_GameObject"), depth + 1) end)
                                        c2 = c2:call("get_Next")
                                    end
                                end)
                            end
                            eat(go, 0)
                            _log("watering hide: '" .. nm .. "' id=" .. tostring(id) .. " -> " .. #wat.wp .. " mesh comp(s) disabled")
                        else
                            _log("watering hide: '" .. nm .. "' id=" .. tostring(id) .. " skipped (not a tool id)")
                        end
                    end
                end)
                child = child:call("get_Next")
            end
        end)
        local ok = _play_clip(M.water_bank or 61, M.water_intro or 3050)
        _log("watering: intro clip " .. (ok and ("playing (FSM held, " .. #wat.wp .. " weapon(s) hidden)") or "FAILED to play"))
        if not ok then
            _pfsm(true)
            for _, g in ipairs(wat.wp or {}) do pcall(function() g:call("set_Enabled", true) end) end
            wat.wp = nil; wat.stage = nil; return
        end
        wat.stage, wat.at = "intro", os.clock()
    elseif wat.stage == "intro" and dt >= (M.water_intro_f or 254) / 60.0 then
        _play_clip(M.water_bank or 61, M.water_end or 3052)
        wat.stage, wat.at = "end", os.clock()
    elseif wat.stage == "end" and dt >= (M.water_end_f or 190) / 60.0 then
        wat.stage = nil
        _pfsm(true)          -- hand the body back; the FSM takes over on the next input
        for _, g in ipairs(wat.wp or {}) do pcall(function() g:call("set_Enabled", true) end) end
        wat.wp = nil
    end
end
-- ── ⭐ CHORE EMOTES (08-05): a generalised clip SEQUENCER on the watering pump's proven laws
-- (sheathe beat -> FSM hold -> hide only OUR tool meshes -> play -> exact restore). Watering
-- keeps its own field-verified pump untouched; this drives COOKING (60:6050 stirring stand-in),
-- MILKING (same clip as placeholder) and the CHICKEN egg chain (60:6020 kneel -> 6022 pickup ->
-- 6023 stand), all Aurora's clip picks. One chore at a time, and never while watering.
local chore = { stage = nil, at = 0, seq = nil, i = 0, wp = nil }
local function _hide_tool_meshes()
    -- the watering hide, verbatim laws: linked-list child walk, tools-only (the arrow lesson),
    -- SINGULAR getComponent, kill mesh comps self+children and remember each for exact restore
    local hidden = {}
    pcall(function()
        local TOOL_WP = { [47200] = true, [47210] = true, [47220] = true }
        local tf = _ptf()
        local child = tf:call("get_Child")
        while child do
            pcall(function()
                local go = child:call("get_GameObject")
                local nm = go and tostring(go:call("get_Name")) or ""
                if nm:find("^wp") and go:call("get_DrawSelf") ~= false then
                    local w = go:call("getComponent(System.Type)", sdk.typeof("app.Weapon"))
                    local id
                    if w then
                        pcall(function() id = w:get_field("ID") end)
                        if id == nil then pcall(function() id = w:get_field("<ID>k__BackingField") end) end
                        if id == nil then pcall(function() id = w:call("get_ID") end) end
                    end
                    if TOOL_WP[tonumber(id) or -1] then
                        local function eat(g, depth)
                            if not g or depth > 4 then return end
                            pcall(function()
                                local mcp = g:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
                                if mcp and mcp:call("get_Enabled") ~= false then
                                    mcp:call("set_Enabled", false)
                                    hidden[#hidden + 1] = mcp
                                end
                                local c2 = g:call("get_Transform"):call("get_Child")
                                while c2 do
                                    pcall(function() eat(c2:call("get_GameObject"), depth + 1) end)
                                    c2 = c2:call("get_Next")
                                end
                            end)
                        end
                        eat(go, 0)
                    end
                end
            end)
            child = child:call("get_Next")
        end
    end)
    return hidden
end
-- on_done (optional): the ITEM GRANT, deferred to the end of the animation (Aurora 08-05:
-- "don't actually get the item until the animation is done"). LAW: it fires EXACTLY ONCE on
-- every path - normal finish, clip failure, or the chore not starting at all - because by the
-- time we're called the cost is already paid (ingredients deleted / day-key marked); a broken
-- emote must never eat the goods.
-- on_first (optional, 08-13): fires the instant the FIRST clip starts playing, i.e. after the
-- sheathe beat, not at the button press. Added for the weapon plaque (Aurora: "can we have the
-- item pickup happen at the same time as the animation?"). ⛔ Do NOT do this by calling the
-- work before _chore_start -- the sheathe beat means the clip is still ~1.3s away at that
-- point, so the item would visibly move before she has even reached for it.
local function _chore_start(seq, label, on_done, on_first)
    if wat.stage or chore.stage then
        _log("chore '" .. tostring(label) .. "': another emote is running - skipped")
        if on_first then pcall(on_first) end
        if on_done then pcall(on_done) end
        return
    end
    if not seq or #seq == 0 then
        if on_first then pcall(on_first) end
        if on_done then pcall(on_done) end
        return
    end
    chore.done, chore.first = on_done, on_first
    -- the same sheathe beat as watering: our dialog pauses the world, and a clip painted on the
    -- unpause frame is eaten by the FSM resuming (the deed-sign law)
    pcall(function()
        _pch():call("get_ActionManager"):call(
            "requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)",
            10, "SheatheWeapon", 0)
    end)
    chore.seq, chore.i, chore.label = seq, 0, label
    chore.stage, chore.at = "sheathe", os.clock()
end
local function _chore_pump()
    if not chore.stage then return end
    local dt = os.clock() - (chore.at or 0)
    if chore.stage == "sheathe" and dt >= (M.water_sheathe_s or 1.3) then
        _pfsm(false)
        chore.wp = _hide_tool_meshes()
        chore.i = 1
        local c = chore.seq[1]
        local ok = _play_clip(c[1], c[2])
        _log("chore '" .. tostring(chore.label) .. "': clip 1/" .. #chore.seq ..
            (ok and " playing" or " FAILED"))
        if not ok then
            _pfsm(true)
            for _, g in ipairs(chore.wp or {}) do pcall(function() g:call("set_Enabled", true) end) end
            chore.wp, chore.stage, chore.seq = nil, nil, nil
            local f0 = chore.first; chore.first = nil
            if f0 then pcall(f0) end
            local d = chore.done; chore.done = nil
            if d then pcall(d) end   -- grant anyway: the cost is already paid
            return
        end
        -- ⭐ 08-13 the first clip is now actually playing -- this is "at the same time as the
        --   animation", as opposed to at the button press (a sheathe beat earlier).
        local f1 = chore.first; chore.first = nil
        if f1 then pcall(f1) end
        chore.stage, chore.at = "play", os.clock()
    elseif chore.stage == "play" then
        local c = chore.seq[chore.i]
        if dt >= (c[3] or 120) / 60.0 then
            -- ⭐ 08-13 OPTIONAL PER-STEP CALLBACK, seq entry = {bank, clip, frames, on_step}.
            --   Fires as THIS clip ends, i.e. exactly on the seam between two clips. Added for
            --   the weapon plaque (Aurora: "hand out 6200 > item place > hand return 6202") --
            --   the sword must appear on the wall AT the seam, not after the hand comes back.
            --   The alternative, two separate emote calls, re-runs the 1.3s sheathe beat and
            --   re-freezes the FSM between them = a visible hitch mid-gesture.
            if type(c[4]) == "function" then pcall(c[4]) end
            if chore.i < #chore.seq then
                chore.i = chore.i + 1
                local nc = chore.seq[chore.i]
                _play_clip(nc[1], nc[2])
                chore.at = os.clock()
            else
                chore.stage, chore.seq = nil, nil
                _pfsm(true)
                for _, g in ipairs(chore.wp or {}) do pcall(function() g:call("set_Enabled", true) end) end
                chore.wp = nil
                local d = chore.done; chore.done = nil
                if d then pcall(d) end   -- the animation earned it: hand the item over NOW
            end
        end
    end
end

-- ⛔ REMOVED 07-25: the "set aside seed from your produce" conversion and its dialog.
-- The NATIVE recipes now cover it (combine 2 of a crop -> 2 seeds, bundle "IRIS - Seed Recipes",
-- including the Ripened and Rotten variants), so a second Lua route only added another menu for
-- the hoe to cycle through. Aurora: "we don't need the 'make seeds from which fruit' option
-- because we have the native recipes now."

local function do_water(b)
    local today = _today()
    if not today then _log("no clock"); return end
    if b.watered_day == today then _log("already watered today"); return end
    b.watered_day = today
    b.dry = 0
    -- ⭐ the soil darkens MID-POUR, not at the button press (Aurora 08-04: "the ground instantly
    -- goes darker - it needs to wait till midway through the animation"). sheathe 0.9s + the
    -- intro's reach-down puts the water hitting soil at roughly this mark. Loaded saves that are
    -- already watered have no tint_at, so they darken immediately - correct: the pour is long past.
    b.tint_at = os.clock() + (M.wet_delay or 3.5)
    _save()
    _water_emote_start()
    _log("watered - it will grow when the day turns")
end

-- ⭐ THE PAWN'S WATERING (Aurora 08-09: "if she waters unwatered plots it should probably change
--   the state ... otherwise people will think that's a bug"). Identical state change to the
--   player's do_water — day stamp, dry reset, mid-pour tint, save — but WITHOUT
--   `_water_emote_start()`, which drives the ARISEN's body. The pawn plays her own clip.
-- ⚠ KEEP IN STEP WITH do_water ABOVE (only the emote line differs). Writing it out beats
--   temporarily swapping out _water_emote_start to reuse do_water: that trick works today only
--   because the local happens to be in scope, and it would fail silently the moment the emote
--   moved or gained a second call site.
-- Returns true only if it actually changed something, so the caller can tell a real chore from
-- set dressing on a bed that was already watered today.
local function pawn_water(b)
    if not (b and b.crop) then return false end
    local today = _today(); if not today then return false end
    if b.watered_day == today then return false end      -- already done; she may still mime it
    b.watered_day = today
    b.dry = 0
    b.tint_at = os.clock() + (M.wet_delay or 3.5)        -- soil darkens mid-pour, not on contact
    _save()
    _log("pawn watered a bed - it will grow when the day turns")
    return true
end

local function do_harvest(b)
    local st = _bed_state(b); if not st then return end
    local c = st.crop
    -- TWO GRADING MODES. Fruits + Harspud own real Ripened/Rotten items, so tending shows up as a
    -- BETTER ITEM. Herbs and flowers are single items (no variants exist), so there tending shows
    -- up as a BIGGER PICK instead. Either way, watering every day is what pays.
    local id, n, grade
    local tiered = c.ripe or c.rot
    if st.wilting then
        id, n, grade = (tiered and (c.rot or c.base)) or c.base, 1, tiered and "ROTTEN" or "poor (1)"
    elseif (b.missed or 0) > 0 then
        id, n, grade = c.base, tiered and math.random(1, 2) or 2, tiered and "plain" or "fair (2)"
    else
        id, n, grade = (tiered and (c.ripe or c.base)) or c.base,
                       tiered and math.random(2, 3) or 4, tiered and "RIPENED" or "BOUNTIFUL (4)"
    end
    local got = _grant_item(id, n)
    if b.live then pcall(function() b.live:call("destroy", b.live) end); b.live = nil end
    b.crop, b.grown, b.watered_day, b.dry, b.missed = nil, 0, nil, 0, 0   -- bed stays tilled: re-sow it
    _save()
    if c.kind == "flower" then _log("picked " .. c.name .. " (flower - decorative)")
    else _log(string.format("harvested %s x%d (%s)", c.name, got, grade)) end
end

-- ── ⭐⭐⭐ NATIVE B-GATHER = OUR HARVEST (08-05). The tracer found it: the grant is
-- `app.Gm82_0XX.giveItem`, fired exactly twice on one gather (everything else was frame noise).
-- Hook it per crop-gimmick class: when the gathered gimmick is one of OUR beds' props, SKIP the
-- native grant (which pays the node's own table - Aurora B-gathered a blueberry and got a
-- STRAWBERRY) and pay the same graded harvest the A-menu gives. Native prompt, native animation,
-- our economy - and the double-dip (native item + menu harvest) dies with it, because the bed
-- clears the moment either door is used. The node's own consumption continues natively; the
-- consumed-detection tidies b.live afterwards.
local function _native_harvest_grant(b)
    local st = _bed_state(b); if not st then return end
    local c = st.crop
    local id, n, grade
    local tiered = c.ripe or c.rot
    if not st.ripe then
        -- picked early (the pick gate should stop this, but belt-and-braces): a tiny consolation,
        -- never the full harvest - early picking must not beat patience
        id, n, grade = c.base, 1, "UNRIPE (1)"
    elseif st.wilting then
        id, n, grade = (tiered and (c.rot or c.base)) or c.base, 1, tiered and "ROTTEN" or "poor (1)"
    elseif (b.missed or 0) > 0 then
        id, n, grade = c.base, tiered and math.random(1, 2) or 2, tiered and "plain" or "fair (2)"
    else
        id, n, grade = (tiered and (c.ripe or c.base)) or c.base,
                       tiered and math.random(2, 3) or 4, tiered and "RIPENED" or "BOUNTIFUL (4)"
    end
    local got = _grant_item(id, n)
    b.crop, b.grown, b.watered_day, b.dry, b.missed = nil, 0, nil, 0, 0
    _save()
    _log(string.format("NATIVE gather -> %s x%d (%s) - bed cleared, re-sow it", c.name, got, grade))
end
local nharv = { armed = 0, recent = {} }
pcall(function()
    local classes = {}
    for _, c in ipairs(M.crops) do classes["app.Gm" .. c.gid:sub(3)] = true end
    for tn in pairs(classes) do
        pcall(function()
            local td = sdk.find_type_definition(tn)
            if not td then return end
            local m
            for _, mm in ipairs(td:get_methods()) do
                if mm:get_name() == "giveItem" then m = mm; break end
            end
            if not m then return end
            sdk.hook(m, function(args)
                -- ⛔ giveItem fires TWICE per gather (the trace showed it). v1 matched on b.crop,
                -- so fire #1 granted + cleared the bed and fire #2 no longer matched - the native
                -- table paid out anyway (Aurora: "3 ripened cranberries AND 1 strawberry").
                -- Match on the GIMMICK alone; grant only while the bed still has its crop, and
                -- swallow every further fire from our node silently.
                -- ⛔⛔ v3 (08-05): carrots also paid a random HERB - the veg grow on gm82_009,
                -- GREENWARISH'S node, so any fire that slips the address match pays the herb
                -- table. Two ways a fire slips: consumed-detection nils b.live between fires,
                -- and some fires arrive from a CHILD GameObject with a different address. Nets:
                -- a swallow LEDGER (an address we've granted for stays swallowed 5s) and a
                -- POSITION fallback (a gather within 2m of one of our beds is ours regardless
                -- of which object it fired from - universal coords, so rebase-safe).
                local now = os.clock()
                local mine_b, addr = nil, nil
                pcall(function()
                    local this = sdk.to_managed_object(args[2])
                    local go = this and this:call("get_GameObject")
                    if not go then return end
                    addr = go:get_address()
                    if nharv.recent[addr] and now < nharv.recent[addr] then mine_b = "ledger"; return end
                    for _, b in ipairs(beds) do
                        if b.live and b.live:get_address() == addr then mine_b = b; return end
                    end
                    local tr = go:call("get_Transform")
                    local p = tr and tr:call("get_Position")
                    local d = _delta()
                    if p and d then
                        local gx, gz = p.x + d.x, p.z + d.z
                        for _, b in ipairs(beds) do
                            local dx, dz = gx - (b.ux or 1e9), gz - (b.uz or 1e9)
                            if dx * dx + dz * dz < 4.0 then mine_b = b; return end
                        end
                    end
                end)
                if mine_b then
                    if addr then nharv.recent[addr] = now + 5 end
                    local acted = mine_b ~= "ledger" and mine_b.crop ~= nil
                    if acted then pcall(function() _native_harvest_grant(mine_b) end) end
                    _log("giveItem from OUR node: " .. (acted and "GRANTED ours" or "swallowed (repeat fire)"))
                    return sdk.PreHookResult.SKIP_ORIGINAL
                end
                -- a WILD gather node: none of our business, native grant proceeds untouched
            end, function(r) return r end)
            nharv.armed = nharv.armed + 1
        end)
    end
    _log("native harvest armed on " .. nharv.armed .. " gimmick class(es) (giveItem skip-and-replace)")
end)

-- ── CONTEXT: what does the interact button do where I'm standing? ──────────────────────────
-- ⭐⭐ THE WHOLE FARM IS ONE SWING (Aurora 07-25: "remove the contextual button press things...
-- go with the natural hit the ground with the hoe, plant the seed in the spot, and water").
-- There are no prompts and no interact key. You work the plot with the tool in your hands, and
-- what the swing DOES depends on what is under it:
--     bare ground        -> till a new bed
--     bare tilled bed    -> sow (the native dialog picks the seed), or set aside seed from
--                           produce when you're carrying crops but no seed
--     growing, dry       -> water it (the watering emote brings its own can)
--     growing, watered   -> nothing to do today
--     ripe               -> harvest
-- IrisWoodcutting's swing gate calls this at the impact frame for any kind="SOIL" tool.
-- THE HOE ONLY BREAKS GROUND. It never opens a menu (Aurora 07-25: "the hoe is just cycling
-- through the different menus"). Swing it on open ground and a mound appears; swing it at a bed
-- that already exists and it says so rather than doing something you didn't ask for.
-- ⛔ STRAY-SWING GUARD (Aurora 07-26: "I keep clicking back into the game and she swings the hoe").
-- The click that dismisses the REFramework overlay lands in the game as an attack. We can't stop
-- the animation, but we can refuse to TILL for it - a bed you never asked for is the annoying part.
local ui = { open = false, closed_at = -99 }
re.on_frame(function()
    local now = false
    pcall(function() now = reframework:is_drawing_ui() == true end)
    if ui.open and not now then ui.closed_at = os.clock() end
    ui.open = now
end)
local function _stray_swing()
    -- ⛔ ONLY the grace window AFTER the overlay closes. Blocking while it's OPEN was far too
    -- greedy: Aurora tests with the panel up, so every single swing was refused ("hoe swing
    -- ignored (just came back from the menu)" over and over) and no bed could be made. The
    -- accident we're actually guarding against is the click that DISMISSES the overlay landing in
    -- the game as an attack - and that swing arrives just after the close, which this still catches.
    return (os.clock() - (ui.closed_at or -99)) < (M.ui_grace or 0.6)
end
-- a game menu is up. ⛔ Only ACTIONS check this - the dialog reader must stay unguarded, because
-- our own dialog pauses the world and guarding the reader would softlock it (the deed-sign law).
-- ⭐ HIDE THE WORLD HUD WHILE A MENU IS UP (Aurora 08-09: the hoe ring and bed markers
--   drew straight over the storage screen). ⚠ This is NOT the settle gate that was removed
--   earlier today, and the difference is the whole point:
--     OLD, BAD: `get_IsLoadGui` armed `settle_until = now + 15s`, so ANY full-screen GUI
--               blanked the HUD for fifteen seconds AFTER it closed.
--     THIS:     `isPausedAny` is true only WHILE the menu is actually up, so the ring comes
--               back the instant you close it. Instantaneous state, not a timed blackout.
--   ⛔ DRAWS ONLY. The dialog READER must never be gated on pause - our own dialog pauses
--   the world, so guarding the reader would softlock it (the deed-sign law).
local function _hud_hidden()
    local h = false
    pcall(function()
        local pm = sdk.get_managed_singleton("app.PauseManager")
        if pm and pm:call("isPausedAny") == true then h = true end
    end)
    if h then return true end
    pcall(function() if reframework:is_drawing_ui() then h = true end end)
    return h
end

local function _game_paused()
    local p = false
    pcall(function()
        local pm = sdk.get_managed_singleton("app.PauseManager")
        if pm and pm:call("isPausedAny") == true then p = true end
    end)
    return p
end

local function _hoe_strike(how)
    if how == "swing" and _stray_swing() then
        _log("hoe swing ignored (just came back from the menu)")
        return
    end
    -- the strike is scheduled on os.clock, which keeps ticking through a pause - so a swing
    -- started before opening a menu could otherwise land while the game is frozen
    if _game_paused() then return end
    local plot, dist = _nearest_plot()
    if not plot or (dist or 999) > M.plot_range then
        if how == "swing" then _log("hoe swing: not at a built homestead") end
        return
    end
    -- the hoe acts on the LATCHED spot it aimed at when the swing began (see the aim latch),
    -- not wherever the lunge has carried you by the impact frame
    local sx, _sy, sz = _till_spot()
    -- ⛔ THE RING LIED UNTIL 08-05: the crosshair previewed the SNAPPED cell but the strike
    -- consulted the RAW latched spot - Aurora aimed at the empty cell right of a bed and the
    -- swing removed the bed in front instead. Snap FIRST; everything after acts where the ring
    -- pointed, including the bed-at check that decides till vs undo.
    if sx then
        local fx2, fz2 = _pfwd()
        local syaw = aim.yaw or math.deg(math.atan(fx2, fz2))
        sx, _sy, sz = _snap_spot(sx, _sy or 0, sz, syaw)
    end
    local b = sx and _bed_at(sx, sz)
    if b then
        -- ⭐ THE UNDO: swinging at an EMPTY bed turns the soil back flat. Symmetric with tilling,
        -- needs no menu or extra key, and it's the natural fix for a bed made by mistake or set
        -- down crooked. A bed with something GROWING in it is never removed by a swing.
        if not b.crop then
            _drop_bed_props(b)
            for i = #beds, 1, -1 do if beds[i] == b then table.remove(beds, i) end end
            _save()
            _log("levelled the empty bed back over (swing again to re-cut it)")
            _aim_clear()
        else
            -- ⭐ UPROOT (Aurora 08-04: "there's no way to clear a planted seed once it's in").
            -- The hoe is the right tool for it - it's what tills and what levels an empty bed, so
            -- it should also be what digs up a crop you sowed by mistake. But she ALSO told me
            -- "I keep clicking back into the game and she swings the hoe", and a stray swing that
            -- silently destroys five in-game days of growth is a worse bug than no uproot at all.
            -- So it's ARM-THEN-CONFIRM: the first swing only warns, and a second swing inside the
            -- window does the deed. Walk away and it disarms itself. The seed is NOT refunded -
            -- it's in the ground, and a free undo would make sowing consequence-free.
            -- ⛔ THE HOE NEVER UPROOTS (Aurora 08-04: "I tried uprooting and it didn't seem to
            -- work - I think it might be better to do it with a keyboard button and then have a
            -- confirmation menu"). The swing-twice-to-confirm scheme asked her to land two hoe
            -- swings on the same bed inside 5s, which is fiddly to aim and gave no feedback when
            -- the second swing missed. Uprooting now lives in the bed menu behind a real yes/no,
            -- and a growing crop is once again something the hoe simply refuses to touch.
            local st = _bed_state(b)
            local kn = (M.tend_key == 0x45) and "E" or string.format("key %X", M.tend_key or 0)
            _log(string.format("%s is growing here (%d/%d days) - press %s / %s to tend or uproot it",
                -- ⚠ NOT _pad_label() - that lives with the PAD reader further down the file, and a
                -- local referenced above its definition resolves to a nil global. Config-only here.
                st and st.crop.name or "something", b.grown or 0, st and st.crop.days or 0, kn,
                (M.pad_labels and M.pad_labels[M.tend_pad]) or tostring(M.tend_pad)))
        end
        return
    end
    do_till(how)          -- nothing underfoot: break new ground
    _aim_clear()          -- the latch belongs to ONE swing
end

-- THE TEND BUTTON at a finished bed: sow an empty one, water a thirsty one, pick a ripe one.
-- ⭐⭐ THE BED MENU (Aurora 08-04: "maybe it could just be an interact button on A/E that brings up
-- a menu for water or uproot"). The tend button used to CYCLE - it picked one action from the bed's
-- state and did it silently, which meant an action you wanted was unreachable whenever the state
-- disagreed with you. That's exactly how the uproot became untestable and how a wrongly-"watered"
-- bed could never be watered. A menu makes every legal action visible and reachable at all times.
-- ── ⭐⭐ THE COOKPOT MENU (Aurora 08-05: "I like the custom cook menu - keep the normal meat
-- cooking recipes and add our custom ones"). The camp cook UI proved system-driven (five gimmick
-- candidates, no prompt), so the pot cooks through OUR dialog instead: stand at a placed Cooking
-- pot furnishing, press the tend key, pick a recipe. v1 ships the three NATIVE meat conversions
-- (the +3 id mapping the cooking probe found); the custom dish slots switch on the moment their
-- Content Editor items exist (same _pending pattern as the vegetable crops).
-- ⚠ stirring emote: wanted, not yet found - a bank-60/61 clip audition job for a later session.
M.cook_recipes = {
    -- CUSTOM DISHES first (Aurora 08-05), CE bundle "IRIS - Cooked Dishes":
    { label = "Vegetable Stew", ins = { { 34721, 1 }, { 34722, 1 }, { 34720, 1 } }, out = { 34723, 1 } }, -- pepper+carrot+potato
    { label = "Berry Tart",     ins = { { 19, 2 }, { 31701, 1 } },                  out = { 34724, 1 } }, -- 2 blueberry + egg
    { label = "Omelette",       ins = { { 31701, 2 }, { 31700, 1 } },               out = { 34725, 1 } }, -- 2 egg + milk
    -- the standard meat conversions at the end:
    { label = "Beast Steak",        ins = { { 25, 1 } }, out = { 28, 1 } },   -- Scrag of Beast
    { label = "Prime Beast Steak",  ins = { { 26, 1 } }, out = { 29, 1 } },   -- Aged Beast Meat
    { label = "Charred Meat",       ins = { { 27, 1 } }, out = { 30, 1 } },   -- Rotten Beast Meat
}
local function _cookable(r)
    if not r.out then return false end          -- dish item not authored yet
    for _, ing in ipairs(r.ins) do
        if (_count_item(ing[1]) or 0) < ing[2] then return false end
    end
    return true
end
local cookpot = { at = 0, near = false }
-- ⛔ FACE WHAT YOU INTERACT WITH (Aurora 2026-08-08: pressing A at the bed kept opening the
-- cookpot menu, because the pot stood right beside it). Proximity is not intent — in a
-- furnished room several interactables are always within arm's reach, and the only signal
-- that says which one you MEAN is which one you are looking at. Stored on the `cookpot`
-- table rather than as a new file-scope local: this chunk is near Lua's 200-local ceiling.
cookpot.face_dot = 0.34          -- cos(~70°): a generous cone, not a laser
-- ⛔ TAKES A DELTA, NOT A POINT. v1 only accepted UNIVERSAL coords, so it could only gate the
-- saved-furniture path — and the fallback scan below works in RENDER space and went ungated,
-- which is why Aurora still got the cookpot menu while facing the pillows. A direction is
-- space-agnostic; a position is not. Gate on the delta and both paths can share one check.
function cookpot.facing_d(dx, dz)
    local ok = false
    pcall(function()
        local pl = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
        local tf = pl and pl:call("get_GameObject"):call("get_Transform")
        if not tf then return end
        local q = tf:call("get_Rotation")
        local yaw = math.atan(2.0 * (q.w * q.y + q.x * q.z), 1.0 - 2.0 * (q.y * q.y + q.x * q.x))
        local l = math.sqrt(dx * dx + dz * dz)
        if l < 0.35 then ok = true; return end       -- stood on top of it: facing is meaningless
        ok = ((math.sin(yaw) * dx + math.cos(yaw) * dz) / l) >= (cookpot.face_dot or 0.34)
    end)
    return ok
end
function cookpot.facing(tx, tz)
    local up = _pupos(); if not up then return true end
    return cookpot.facing_d(tx - up.x, tz - up.z)
end
function cookpot.live_near()
    local up, p = _pupos(), cookpot.pos
    if not (up and p) then return false end
    local dx, dz = p.x - up.x, p.z - up.z
    return dx * dx + dz * dz <= 6.25 and cookpot.facing_d(dx, dz)
end
-- ⭐⭐⭐ WHAT COUNTS AS A COOKING SURFACE (Aurora 08-12: "we have this native B cook prompt on the
-- cookpot in my homestead but it doesn't go over EVERY cookpot/stove — can we get this prompt added
-- to every cookpot/stove/campfire gimmick you can spawn in IRIS furnish?").
-- It was ONE id, hard-coded in three places. Her save has BOTH `gm80_256` "Cooking pot" (the hanging
-- cauldron indoors, which prompted) AND `gm51_381` "Campfire" (the lit tripod cauldron outdoors,
-- which did not) — same plot, same session, one of the two recognised.
--
-- ⭐ WHY THIS IS A DATA CHANGE AND NOT A FIGHT WITH THE ENGINE: the Cook prompt is OURS end to end.
-- `data/Interactables/catalog.json` records these gimmicks as pc=0 / v=["Search"] — not
-- player-interactable at all — and waking a NATIVE Cook is closed research: five readings taken 2s
-- after a *successful* setHaveMeat(true) still gave isInteractEnable=false / canPlayerInteract=false,
-- because the gate is CAMP CONTEXT, and InteractManager:register() is a 3/3 CTD wall
-- (INTERACTABLES_HANDOVER.md; dd2-interact-prompt-hijack). None of that is in our way: `_cookpot_near`
-- decides, IrisPromptBar draws the label inside the game's real ui020701 frame, and `_show_cook_menu`
-- is our own dialog. So "where can I cook" is nothing more than this table.
--
-- ⚠ THE FURNISH CATALOG'S LABEL LIES ABOUT THREE OF THESE. It calls gm51_381/382/383 "Campfire"
-- (a label inherited from the base gid), while Nick's own gimmick index names their _00/_01 variants
-- "Cooking pot" — and Aurora's screenshot settles it: her placed gm51_381 renders as a tripod
-- cauldron of stew over a fire. Trust the mesh, not the label.
--
-- ⛔ NOTE ON SCOPE: these live on the `cookpot` table, NOT as new file-scope locals. IrisFarming is
-- ~5900 lines and Lua caps a chunk at 200 locals; `cookpot` already carries this feature's helpers
-- (facing/facing_d/live_near), so it is the right home and it costs zero local slots.
cookpot.gids = {
    ["gm80_256"] = "cooking pot",     -- the hanging cauldron; the one that already worked
    ["gm51_381"] = "campfire pot",    -- Aurora's outdoor tripod cauldron (screenshot, 08-12)
    ["gm51_382"] = "campfire pot",
    ["gm51_383"] = "campfire pot",
    -- The camp stew pots — these five plus gm80_256 are the six prefabs carrying the game's own
    -- Cook verb (per data/Interactables/catalog.json). Listed whether or not they are in the furnish
    -- catalog today: recognising an id costs one table lookup, so anything she places later works
    -- the day she places it instead of needing this table edited again.
    ["gm80_060"] = "camp stew pot",
    ["gm80_061"] = "camp stew pot",
    ["gm80_062"] = "camp stew pot",
    ["gm80_063"] = "camp stew pot",
    ["gm80_064"] = "camp stew pot",
}
-- variants carry an _NN suffix the base id does not ("gm51_381_00", "gm51_381_01") and the furnish
-- catalog ships those as their own rows, so fall back to the base id rather than enumerate suffixes.
function cookpot.gid_ok(gid)
    if not gid then return nil end
    local g = tostring(gid)
    if cookpot.gids[g] then return cookpot.gids[g] end
    local base = g:match("^(gm%d+_%d+)")
    return base and cookpot.gids[base] or nil
end
-- does a LIVE GameObject's name name a cooking surface? ⚠ a SPAWNED gimmick reports its RIG name,
-- not its prefab id (a live gm80_257 calls itself "gmSeat"), so this branch reliably catches
-- WORLD-authored pots and fires; her own placements are caught by the furnish-record branch.
-- ⚡ ONE match + ONE lookup, deliberately NOT a loop over the set: this is called against every
-- app.GimmickBase in the scene (500+ in a town, and a 9ms scan there is already on record as a
-- visible hitch), so it has to stay O(1) per object. The pattern also strips a variant's `_00`/`_01`
-- tail for free — `gm51_381_00` matches as `gm51_381` because the second `%d+` stops at the suffix.
function cookpot.name_ok(nm)
    if not nm or nm == "" then return nil end
    local base = nm:match("gm%d+_%d+")
    return base and cookpot.gids[base] or nil
end
-- Cook at pots and campfires the GAME placed too, not only at ours. This branch already existed for
-- gm80_256, so widening the id set widens it as a side effect — made explicit and switchable rather
-- than left as an accident. Off = only furniture Aurora placed herself offers Cook.
M.cook_world = true

-- the live pot GameObject nearest the player, so we can jack its OWN cooking animation.
-- The saved-furniture path only knows coordinates, so this is how we get a real object.
function cookpot.find_go()
    local best, bd = nil, 6.25
    pcall(function()
        local rp = _ppos(); if not rp then return end
        local smgr = sdk.get_native_singleton("via.SceneManager")
        local scene = smgr and sdk.call_native_func(smgr,
            sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        local arr = scene and scene:call("findComponents(System.Type)", sdk.typeof("app.GimmickBase"))
        for i = 0, (tonumber(arr and arr:get_size() or 0) or 0) - 1 do
            pcall(function()
                local go = arr:get_element(i):call("get_GameObject")
                if cookpot.name_ok(tostring(go:call("get_Name") or "")) then
                    local pp = go:call("get_Transform"):call("get_Position")
                    local dx, dz = pp.x - rp.x, pp.z - rp.z
                    local dd = dx * dx + dz * dz
                    if dd <= bd then best, bd = go, dd end
                end
            end)
        end
    end)
    return best
end
local function _cookpot_near()
    -- placed cooking furnishings live in IrisFurnish's save; cheap cached read
    -- ⚠ the 5s cache means a piece placed seconds ago is not cookable until the cache turns over.
    if os.clock() - cookpot.at > 5.0 then
        cookpot.at = os.clock()
        cookpot.recs = nil
        pcall(function()
            local placed = json.load_file("IRIS/iris_furniture.json")
            if placed then
                cookpot.recs = {}
                for _, r in ipairs(placed) do
                    -- was `r.gid == "gm80_256"`: one id, so her placed campfire cauldron was invisible
                    if cookpot.gid_ok(r.gid) then cookpot.recs[#cookpot.recs + 1] = r end
                end
            end
        end)
    end
    local up = _pupos(); if not up then return false end
    cookpot.why = "no placed cookpot/campfire within 2.5m"
    local best = 1e9
    for _, r in ipairs(cookpot.recs or {}) do
        local dx, dz = (r.ux or 0) - up.x, (r.uz or 0) - up.z
        local dd = dx * dx + dz * dz
        if dd < best then best = dd end
        if dd <= 6.25 and cookpot.facing(r.ux or 0, r.uz or 0) then
            cookpot.pos = { x = r.ux, y = r.uy or up.y, z = r.uz }   -- for the floating prompt
            return true
        end
    end
    -- fallback: ANY cooking gimmick actually standing near the player (catches pots spawned through
    -- other routes than the furnish save, and — with M.cook_world on — the game's own world pots
    -- and campfires, which have never offered a native Cook outside an active camp).
    local found = false
    pcall(function()
        if M.cook_world == false then return end
        local rp = _ppos(); if not rp then return end
        local smgr = sdk.get_native_singleton("via.SceneManager")
        local scene = smgr and sdk.call_native_func(smgr, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        local arr = scene and scene:call("findComponents(System.Type)", sdk.typeof("app.GimmickBase"))
        local n = arr and arr:get_size() or 0
        for i = 0, (tonumber(n) or 0) - 1 do
            if found then break end
            pcall(function()
                local go = arr:get_element(i):call("get_GameObject")
                if cookpot.name_ok(tostring(go:call("get_Name") or "")) then
                    local pp = go:call("get_Transform"):call("get_Position")
                    local dx, dz = pp.x - rp.x, pp.z - rp.z
                    if dx * dx + dz * dz <= 6.25 and cookpot.facing_d(dx, dz) then
                        found = true
                        cookpot.go = go        -- kept so we can jack the pot's own cook animation
                        local dlt = _delta()
                        if dlt then cookpot.pos = { x = pp.x + dlt.x, y = pp.y + dlt.y, z = pp.z + dlt.z } end
                    end
                end
            end)
        end
    end)
    if found then return true end
    cookpot.why = string.format("%d placed cook rec(s), nearest %.1fm; no live cooking gimmick "
        .. "within 2.5m (world scan %s)",
        #(cookpot.recs or {}), best < 1e8 and math.sqrt(best) or -1,
        M.cook_world == false and "OFF" or "on")
    return false
end
local function _show_cook_menu()
    local avail = {}
    for _, r in ipairs(M.cook_recipes) do
        if r.out then avail[#avail + 1] = r end   -- authored recipes only; counts shown per item
    end
    if #avail == 0 then _log("nothing to cook - no recipes authored yet"); return end
    _paged_dialog("Cook what?", avail, function(r)
        local ok = _cookable(r)
        return r.label .. (ok and "" or "  (missing ingredients)")
    end, 1, "cook")
end

local function _show_bed_menu(b)
    local st = _bed_state(b); if not st then return end
    local acts, labels = {}, {}
    if st.ripe then
        acts[#acts + 1] = "harvest"; labels[#labels + 1] = "Harvest the " .. st.crop.name
    end
    if b.watered_day ~= _today() then
        acts[#acts + 1] = "water";   labels[#labels + 1] = "Water it"
    else
        acts[#acts + 1] = "watered"; labels[#labels + 1] = "Already watered today"
    end
    acts[#acts + 1] = "uproot";      labels[#labels + 1] = "Uproot the " .. st.crop.name
    dlg.bed, dlg.acts = b, acts
    dlg.opts = acts                  -- the reader's generic "4th slot = Cancel" rule keys off this
    dlg.more = false
    labels[#labels + 1] = "Cancel"
    _show_dialog(string.format("%s - %d/%d days", st.crop.name, b.grown or 0, st.crop.days),
        labels[1], labels[2], labels[3], labels[4], "bed_act")
end

-- ── ⭐ ANIMAL PRODUCE (08-05): milk from ox-cows, eggs from chickens - the tend key on a live
-- animal. We do NOT yet know the character ids (never guess ids), so matching is by GO-name
-- token lists (M.milk_ids / M.egg_ids) that the SCAN probe fills: stand by the animal, press
-- the panel's "SCAN animals nearby", read the names it logs, paste the ch-token in the box.
-- Once per animal per in-game day (Stardew rules), keyed by name + a 5m position grid.
local ani = { days = nil }
local ANI_FILE = "IRIS/animal_produce.json"
local function _ani_days()
    if not ani.days then ani.days = json.load_file(ANI_FILE) or {} end
    return ani.days
end
local function _scan_animals(radius)
    local found = {}
    pcall(function()
        local smgr = sdk.get_native_singleton("via.SceneManager")
        local scene = smgr and sdk.call_native_func(smgr, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        if not scene then return end
        local comps = scene:call("findComponents(System.Type)", sdk.typeof("app.Character"))
        local n = comps and (comps.get_size and comps:get_size() or #comps) or 0
        local pp = _ppos(); if not pp then return end
        for i = 0, n - 1 do
            pcall(function()
                local ch = comps.get_element and comps:get_element(i) or comps[i]
                local go = ch and ch:call("get_GameObject")
                local tr = go and go:call("get_Transform")
                local p = tr and tr:call("get_Position")
                if p then
                    local dx, dy, dz = p.x - pp.x, p.y - pp.y, p.z - pp.z
                    local d2 = dx * dx + dy * dy + dz * dz
                    if d2 < radius * radius then
                        found[#found + 1] = { go = go, name = tostring(go:call("get_Name")), dist = math.sqrt(d2), pos = p }
                    end
                end
            end)
        end
        table.sort(found, function(a, b) return a.dist < b.dist end)
    end)
    return found
end
local function _match_tokens(name, csv)
    local nl = name:lower()
    for tok in tostring(csv or ""):gmatch("[^,%s]+") do
        if #tok > 1 and nl:find(tok:lower(), 1, true) then return true end
    end
    return false
end
-- ── ANIMAL HOLD + VOICE (Aurora 08-06: "make the creature stop and hold still, then moo/
-- cluck"). HOLD = app.Character set_IsThinkStop, the taming yield freeze (beasts animate
-- fine while think-stopped); released in the same on_done that grants the item, so every
-- exit path lets the animal go. VOICE = the creature's OWN vocal bank, never a guessed id:
-- the wild-cats catalogue walk (WwiseContainerApp._UserDataList -> lists whose path has
-- "_vo" -> _TriggerInfoList), then post one of ITS OWN triggers back at it. Whatever plays,
-- it's a sound this species ships with.
local anivoc = { cat = {} }
local ANIVOC_SIG = table.concat({
    "createRequestInfo(soundlib.SoundTriggerInfo, via.GameObject, via.GameObject, ",
    "System.UInt32, System.Boolean, System.Boolean, System.UInt32, ",
    "via.simplewwise.CallbackType, ",
    "System.Action`1<soundlib.SoundManager.RequestInfo>, ",
    "System.Action`1<soundlib.SoundManager.RequestInfo>, ",
    "System.Action`1<soundlib.SoundManager.RequestInfo>, ",
    "System.Action`1<soundlib.SoundManager.RequestInfo>)",
})
local function _ani_count(col)
    local c; pcall(function() c = col:call("get_Count") end)
    return tonumber(c) or 0
end
local function _ani_vocals(go)
    local addr = go:get_address()
    if anivoc.cat[addr] then return anivoc.cat[addr] end
    local out = {}
    pcall(function()
        local ww = go:call("getComponent(System.Type)", sdk.typeof("app.WwiseContainerApp"))
        if not ww then return end
        local banks = ww._UserDataList
        for bi = 0, _ani_count(banks) - 1 do
            local lists; pcall(function() lists = banks[bi]._UserDataList end)
            for li = 0, _ani_count(lists) - 1 do
                local lst = lists[li]
                local path = ""; pcall(function() path = tostring(lst:call("get_Path")):lower() end)
                if path:find("_vo", 1, true) then
                    local trigs; pcall(function() trigs = lst._TriggerInfoList end)
                    for ti = 0, _ani_count(trigs) - 1 do
                        pcall(function() out[#out + 1] = trigs[ti] end)
                    end
                end
            end
        end
    end)
    anivoc.cat[addr] = out
    _log("animal voice: " .. tostring(go:call("get_Name")) .. " catalogue = " .. #out .. " vocal trigger(s)")
    return out
end
local function _ani_moo(go)
    if M.animal_voice == false then return end
    pcall(function()
        local vs = _ani_vocals(go)
        if #vs == 0 then return end
        local trig = vs[math.random(1, #vs)]
        local ww = go:call("getComponent(System.Type)", sdk.typeof("app.WwiseContainerApp"))
        if not ww then return end
        local jh = 0; pcall(function() jh = tonumber(trig._OffsetJointHash) or 0 end)
        local req
        pcall(function() req = ww:call(ANIVOC_SIG, trig, go, go, jh, false, false, 0, 0, nil, nil, nil, nil) end)
        if not req and jh ~= 0 then
            pcall(function() req = ww:call(ANIVOC_SIG, trig, go, go, 0, false, false, 0, 0, nil, nil, nil, nil) end)
        end
        if not req then _log("animal voice: createRequestInfo refused (see wild-cats recipe)"); return end
        pcall(function()
            req = req:add_ref()
            req["<Container>k__BackingField"] = ww
            ww:call("trigger(soundlib.SoundManager.RequestInfo)", req)
        end)
    end)
end
local function _ani_hold(go, stop)
    pcall(function()
        local ch = go:call("getComponent(System.Type)", sdk.typeof("app.Character"))
        if not ch then return end
        if pcall(function() ch:call("set_IsThinkStop(System.Boolean)", stop == true) end) then return end
        pcall(function() ch:call("set_IsThinkStop", stop == true) end)
    end)
end
-- play a clip on the THINK-STOPPED animal's layer 0 (the taming creature-clip recipe verbatim;
-- 8-frame blend so a stand-up flows from whatever pose it held). Atlas-verified ox clips:
-- 60:49 liv_sit_to_idle (stand up), 0:0 com_idle_loop (standing idle).
local function _ani_clip(go, bank, id)
    pcall(function()
        local ch = go:call("getComponent(System.Type)", sdk.typeof("app.Character"))
        local layer = ch and ch:call("get_Motion"):call("getLayer", 0)
        if layer then
            layer:call("changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                math.floor(bank or 0), math.floor(id or 0), 0.0, 8.0, 1, 1)
        end
    end)
end
local aniq = {}   -- deferred animal clips: { at, go, bank, id }
local function _aniq_pump()
    for i = #aniq, 1, -1 do
        if os.clock() >= aniq[i].at then
            _ani_clip(aniq[i].go, aniq[i].bank, aniq[i].id)
            table.remove(aniq, i)
        end
    end
end
-- ── 08-11 PRODUCE GATES (Aurora): milk/eggs come only from a LIVING, TAMED animal.
-- (a) a corpse gives nothing -- get_IsDead on the body's app.Character (the taming
--     module's proven dead-read); (b) only the stable-summoned ACTIVE companion
--     produces -- a wild ox/hen is not yours to tend. Shared by the tend key AND the
--     label scan below, so the prompt and the grant can never disagree.
local function _ani_eligible(a)
    local dead = false
    pcall(function()
        local ch = a.go:call("getComponent(System.Type)", sdk.typeof("app.Character"))
        if ch then dead = ch:call("get_IsDead") == true end
    end)
    if dead then return false, "a corpse gives nothing" end
    local tamed = false
    pcall(function()
        local b = rawget(_G, "IrisGriffinBridge")
        tamed = (b and b.is_companion_body and b.is_companion_body(a.go) == true) or false
    end)
    -- 08-11 HOMESTEAD BOX: the yard's residents produce too (Aurora's whole point --
    -- milk the ox and collect the eggs AT the farm)
    if not tamed then
        pcall(function()
            local hb = rawget(_G, "IrisHomesteadBox")
            tamed = (hb and hb.is_resident and hb.is_resident(a.go:get_address()) == true) or false
        end)
    end
    if not tamed then return false, "only a tamed, stable-summoned animal produces" end
    return true
end
local function _try_animal_produce()
    if M.animal_produce == false then return false end
    for _, a in ipairs(_scan_animals(math.max(tonumber(M.animal_range) or 7.0, 7.0))) do
        local kind = (_match_tokens(a.name, M.milk_ids) and "milk")
                  or (_match_tokens(a.name, M.egg_ids) and "egg") or nil
        if kind then
            local ok9, why9 = _ani_eligible(a)
            if not ok9 then _log(kind .. ": " .. tostring(why9)); kind = nil end
        end
        if kind == "milk" then
            -- 08-12 (the forced bull randomisation): GENDER OUTRANKS CHASSIS. The world
            -- spawns only cow-band oxen, so some present as bulls by IRIS's roll -- and a
            -- bull has nothing to give. Record gender first (tamed truth), then the roll.
            local g9 = nil
            pcall(function()
                local b9 = rawget(_G, "IrisGriffinBridge")
                g9 = b9 and b9.body_gender and b9.body_gender(a.go:get_address()) or nil
            end)
            if g9 == nil then
                pcall(function()
                    local sp9 = rawget(_G, "IrisSpecies")
                    g9 = sp9 and sp9.gender and sp9.gender(a.go) or nil
                end)
            end
            if g9 == "male" then _log("milk: a bull has nothing to give"); kind = nil end
        end
        if kind then
            local d = _delta() or { x = 0, z = 0 }
            local key = string.format("%s@%d,%d", a.name,
                math.floor((a.pos.x + d.x) / 5), math.floor((a.pos.z + d.z) / 5))
            -- 08-12 (Mootilda milked twice): the grid key breaks the moment the animal WALKS
            -- out of its 5m cell -- a wanderer reads as a new animal. Latch by BODY ADDRESS
            -- too (follows it anywhere this session); the grid key stays as the backstop for
            -- penned animals across a game restart. Either latch counts.
            local akey = nil
            pcall(function() akey = "a" .. tostring(a.go:get_address()) end)
            local today = _today()
            local days = _ani_days()
            if today and (days[key] == today or (akey and days[akey] == today)) then
                _log(kind .. ": this animal has already given today - come back tomorrow")
                return true
            end
            _ani_hold(a.go, true)   -- stand still, friend - released in on_done on every path
            _ani_moo(a.go)          -- its own moo/cluck from its own bank
            if kind == "milk" then
                -- a lying ox gets milked standing (Aurora 08-06): stand-up clip now, settle
                -- into the standing idle once it's up. Both atlas-verified for ch299003.
                _ani_clip(a.go, 60, 49)
                aniq[#aniq + 1] = { at = os.clock() + 2.2, go = a.go, bank = 0, id = 0 }
                -- 08-11 LUCK (IV system): a fortunate animal doubles its gift, luck/62 chance
                local n9 = 1
                pcall(function()
                    local b = rawget(_G, "IrisGriffinBridge")
                    local lk = b and b.active_luck and tonumber(b.active_luck()) or 0
                    if lk > 0 and math.random() < (lk / 60.0) then n9 = 2 end
                end)
                _chore_start({ { M.milk_bank or 60, M.milk_clip or 6050, M.milk_f or 240 } }, "milking", function()
                    _ani_hold(a.go, false)
                    local got = _grant_item(31700, n9)
                    _log("milked " .. a.name .. " -> Milk x" .. tostring(got or n9)
                        .. (n9 > 1 and " (fortune smiles on this one)" or ""))
                end)
            else
                local n9 = 1
                pcall(function()
                    local b = rawget(_G, "IrisGriffinBridge")
                    local lk = b and b.active_luck and tonumber(b.active_luck()) or 0
                    if lk > 0 and math.random() < (lk / 60.0) then n9 = 2 end
                end)
                _chore_start({ { 60, 6020, 35 }, { 60, 6022, 140 }, { 60, 6023, 90 } }, "egg pickup", function()
                    _ani_hold(a.go, false)
                    local got = _grant_item(31701, n9)
                    _log("collected from " .. a.name .. " -> Fresh Egg x" .. tostring(got or n9)
                        .. (n9 > 1 and " (fortune smiles on this one)" or ""))
                end)
            end
            if today then
                days[key] = today
                if akey then days[akey] = today end
                pcall(function() json.dump_file(ANI_FILE, days) end)
            end
            return true
        end
    end
    return false
end
-- ── GRAB SHIELD (Aurora 08-06: pressing tend "did the animation but the chicken had a huge
-- blood spatter" + "grabs and climbs the cow"). E/A is ALSO the native grab: the same press
-- that milks was seizing the hen (requestTryCatch = pickup for critters, CLING-climb for big
-- beasts - the rodeo's horse-deadlift lesson). While a milk/egg animal is in tend range the
-- PLAYER's requestTryCatch is skipped whole; pawns keep their hands. ani.near_now is published
-- by the prompt's throttled scan (further down, with the world-space label + jump gate).
pcall(function()
    local td = sdk.find_type_definition("app.Human")
    local m = td and (td:get_method("requestTryCatch(app.Human.TryCatchType, System.Boolean, System.Boolean, System.Boolean)")
        or td:get_method("requestTryCatch"))
    if not m then _log("animal produce: requestTryCatch not found - native grab NOT shielded"); return end
    sdk.hook(m, function(args)
        if ani.near_now ~= true then return end
        local ok, mine = pcall(function()
            local this = sdk.to_managed_object(args[1])
            local ph = _pch():call("get_Human")
            return this ~= nil and ph ~= nil and this:get_address() == ph:get_address()
        end)
        if ok and mine then return sdk.PreHookResult.SKIP_ORIGINAL end
    end, function(r) return r end)
    _log("animal produce: player grab/cling shielded while a milk/egg animal is in reach")
end)
-- ── ⭐⭐ MONSTER GUARD (Aurora 08-05: "I just teleported to my home and there's an armoured
-- cyclops right next to it"). No aggressive monster within monster_guard_r of ANY plot.
-- Two layers:
--   1. SPAWN INTERCEPT: pre-hook the GenerateManager door (the EncounterLab signature) - if the
--      prefab is a monster and the container's _InitialPosition (UNIVERSAL, the spawn law) lands
--      inside a guard ring, SKIP_ORIGINAL. The monster is never born.
--   2. LIVE SWEEP: every 5s while the player is near a plot, destroy monsters already standing
--      inside the ring (the cyclops that moved in before the intercept was armed).
-- SPECIES POLICY, not a roster: ch2xx = monster EXCEPT ch253 (griffin - tameable, and IrisTaming's
-- roster isn't reachable from here) and ALL ch299* (wildlife: horses/cats/oxen/deer - the tame
-- kingdom). Wrong side of the line = a deleted companion; this line can never do that.
-- settle_until = the WORLD-SETTLE GATE (Aurora 08-06: load-at-homestead stuck on the loading
-- screen; our prompts even drew ON it). While the world assembles, the door intercept must
-- let every spawn pass - skipping one the LOADER awaits = a load that never completes - and
-- the wake-drift guard must hold fire. Extended by _wdg_tick whenever the player is missing
-- or the player GO address changes; the eviction sweep cleans up anything that slipped in.
local mguard = { swept_at = 0, blocked = 0, swept = 0, settle_until = os.clock() + 8.0 }
-- ⭐ TAME EXEMPTION (Aurora 08-05: "worried this might evict tamed griffins and wolves...
-- chimera and garm will be tamable too"). IrisTaming publishes its live roster by reference
-- (_G.IrisTamedRoster, [ch] = rec); anything in the family is untouchable REGARDLESS of
-- species. The ch253/ch299 species exemptions stay as the backstop for when taming isn't
-- loaded. Future summon code can also set _G.IrisFriendlySpawnUntil = os.clock()+N to let a
-- friendly spawn through the door intercept.
local function _mg_is_tamed(go_addr)
    local ok, tamed = pcall(function()
        local r = _G.IrisTamedRoster
        if not r then return false end
        for tch in pairs(r) do
            local a
            pcall(function() a = tch:call("get_GameObject"):get_address() end)
            if a == go_addr then return true end
        end
        return false
    end)
    return ok and tamed
end
local function _mg_is_monster(s)
    s = tostring(s or "")
    local id = s:match("ch(%d%d%d)")
    if not id then return false end
    if id:sub(1, 1) ~= "2" then return false end
    if id == "253" or id == "299" then return false end
    return true
end
local function _mg_near_plot(ux, uz)
    local r = M.monster_guard_r or 120
    for _, pr in ipairs(_G.IrisHomesteadPlots and _G.IrisHomesteadPlots.list() or {}) do
        local dx, dz = (pr.ux or 1e9) - ux, (pr.uz or 1e9) - uz
        if dx * dx + dz * dz < r * r then return true end
    end
    -- GRIFFIN NEST rings (Aurora 08-06: "stop bosses that aren't griffins from spawning ~50m
    -- around griffin nests"). IrisTaming publishes the surveyed nests by reference (universal
    -- coords). Species policy upstream already exempts ch253 + all wildlife, so inside these
    -- rings ONLY non-griffin monsters are blocked/evicted - the mother keeps her home.
    local nr = M.nest_guard_r or 50
    for _, n in ipairs(_G.IrisGriffinNests or {}) do
        local dx, dz = (tonumber(n.x) or 1e9) - ux, (tonumber(n.z) or 1e9) - uz
        if dx * dx + dz * dz < nr * nr then return true end
    end
    return false
end
pcall(function()
    local sig = "requestCreateInstance(app.PrefabController, app.GenerateInfo.GenerateInfoContainer, "
        .. "System.Int32, app.InstanceInfo, "
        .. "System.Action`2<app.PrefabInstantiateResults,app.DummyArg>, "
        .. "System.Action`2<app.PrefabInstantiateResults,app.DummyArg>)"
    local m = sdk.find_type_definition("app.GenerateManager"):get_method(sig)
    if not m then _log("monster guard: generate door not found (signature drift?)"); return end
    sdk.hook(m, function(args)
        if M.monster_guard == false then return end
        if os.clock() < (tonumber(mguard.settle_until) or 0) then return end   -- world still assembling: never block the loader
        if os.clock() < (tonumber(_G.IrisFriendlySpawnUntil) or 0) then return end   -- taming summons pass
        local block = false
        pcall(function()
            local pfb = sdk.to_managed_object(args[3])
            local path = pfb and pfb:call("get_Item"):call("get_Path")
            if not (path and _mg_is_monster(path)) then return end
            local cont = sdk.to_managed_object(args[4])
            local pos = cont and cont._CommonInfo and cont._CommonInfo._InitialPosition
            if pos and _mg_near_plot(pos.x, pos.z) then block = true end
        end)
        if block then
            -- ⛔⛔ NEVER SKIP_ORIGINAL this door (08-06 second CTD: the SAME ogre
            -- setNextTarget stack with ZERO evictions - but 3 BLOCKED spawns 28s before.
            -- Monsters spawn in GROUPS; vetoing some members leaves the group's ledger
            -- pointing at creatures that were never born = the destroy() dangle, one door
            -- over). REDIRECT instead: rewrite _InitialPosition ~300m off the ring and let
            -- the birth complete FULLY natively - every member truly exists, just far away.
            local moved = false
            pcall(function()
                local cont = sdk.to_managed_object(args[4])
                local cc = cont._CommonInfo
                local ip = cc._InitialPosition
                local pu; pcall(function() pu = _pupos() end)
                local vx = ip.x - (pu and pu.x or (ip.x - 1.0))
                local vz = ip.z - (pu and pu.z or ip.z)
                local l = math.sqrt(vx * vx + vz * vz)
                if l < 1.0 then vx, vz, l = 1.0, 0.0, 1.0 end
                local v = ValueType.new(sdk.find_type_definition("via.Position"))
                v.x = ip.x + vx / l * 300.0
                v.y = ip.y + 10.0
                v.z = ip.z + vz / l * 300.0
                cc._InitialPosition = v
                local rb = cc._InitialPosition
                moved = rb and math.abs(rb.x - v.x) < 0.5 or false
            end)
            mguard.blocked = mguard.blocked + 1
            _log("monster guard: REDIRECTED a monster spawn (" .. mguard.blocked .. " total)"
                .. (moved and " - born 300m off the ring" or " - position write failed; it spawns in place, the sweep walks it out"))
        end
    end, function(r) return r end)
    _log("monster guard: generate door armed")
end)
-- the settle gate's KEEPER (Aurora 08-06 round 2: a load stuck AWAY from the homestead - the
-- update-loop-based maintenance can't be trusted to run during loads). Frames DO run during
-- loading screens (images 59/60 render at 92-99 FPS), so this tiny on_frame reads the game's
-- OWN loading flag - app.GuiManager get_IsLoadGui, timtam's shipped pattern (their recipe,
-- our code) - and holds every guard down while a load GUI is up + 15s after it drops.
re.on_frame(function()
    if os.clock() - (mguard.keeper_at or 0) < 0.25 then return end
    mguard.keeper_at = os.clock()
    pcall(function()
        local gm = sdk.get_managed_singleton("app.GuiManager")
        -- ⛔⛔ NEVER ARM THE GATE FOR OUR OWN DIALOG (Aurora 2026-08-08: "every interaction
        -- turns off farming for about 10 seconds - the hoe reticule and context labels
        -- disappear"). The settle gate switches off EXACTLY those things, and its only
        -- trigger is this loading-GUI read. Our sow/cook menus are native GUI, so if
        -- get_IsLoadGui reports true for any full-screen GUI, then every single menu we open
        -- arms a 15s blackout — which is precisely the reported symptom.
        if dlg.open then return end
        if gm and gm:call("get_IsLoadGui") == true then
            -- log it, throttled: the gate has been invisible until now, and an invisible
            -- gate that silently disables half the mod is how this went unnoticed for days
            if os.clock() - (mguard.said_at or 0) > 5.0 then
                mguard.said_at = os.clock()
                _log("settle gate: armed +15s by get_IsLoadGui (loading screen or a full-screen GUI)")
            end
            mguard.settle_until = os.clock() + 15.0
        end
    end)
end)
local function _mg_sweep()
    if M.monster_guard == false then return end
    local now = os.clock()
    if now - mguard.swept_at < 5.0 then return end
    mguard.swept_at = now
    -- ⛔⛔ THE STUCK-LOAD CULPRIT (08-06, farming_log 02:50:10: NINE evictions mid-load).
    -- Destroying half-initialized characters while the world assembles leaves the loader
    -- waiting on them forever. The sweep - not the door - was the hang all along; it now
    -- honors the same settle gate and evicts 15s AFTER the load completes instead.
    if now < (tonumber(mguard.settle_until) or 0) then return end
    pcall(function()
        local up = _pupos(); local d = _delta()
        if not (up and d) then return end
        if not _mg_near_plot(up.x, up.z) then return end   -- only patrol while she's home-ish
        local smgr = sdk.get_native_singleton("via.SceneManager")
        local scene = smgr and sdk.call_native_func(smgr, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        if not scene then return end
        local comps = scene:call("findComponents(System.Type)", sdk.typeof("app.Character"))
        local n = comps and (comps.get_size and comps:get_size() or #comps) or 0
        for i = 0, n - 1 do
            pcall(function()
                local ch = comps.get_element and comps:get_element(i) or comps[i]
                local go = ch and ch:call("get_GameObject")
                local nm = go and tostring(go:call("get_Name")) or ""
                if not _mg_is_monster(nm) then return end
                if _mg_is_tamed(go:get_address()) then
                    _log("monster guard: " .. nm .. " is FAMILY - left in peace")
                    return
                end
                local p = go:call("get_Transform"):call("get_Position")
                if p and _mg_near_plot(p.x + d.x, p.z + d.z) then
                    -- ⛔⛔ NEVER destroy() a live native monster (08-06 CTD: an OGRE's
                    -- Ch251CheckGender.setNextTarget walked its target list 21s after we
                    -- destroy()'d an evictee - raw destroy skips the death pipeline, so no
                    -- other AI is ever told its target is gone). TRUE eviction instead:
                    -- warp it ~300m straight away from the player - outside every ring,
                    -- beyond streaming range, where the game's own lifecycle culls it
                    -- cleanly. Nothing is destroyed, so nothing can dangle.
                    local mux, muy, muz = p.x + d.x, p.y + d.y, p.z + d.z
                    local vx, vz = mux - (up and up.x or (mux - 1)), muz - (up and up.z or muz)
                    local l = math.sqrt(vx * vx + vz * vz)
                    if l < 1.0 then vx, vz, l = 1.0, 0.0, 1.0 end
                    local v = ValueType.new(sdk.find_type_definition("via.Position"))
                    v.x = mux + vx / l * 300.0
                    v.y = muy + 15.0
                    v.z = muz + vz / l * 300.0
                    go:call("get_Transform"):call("set_UniversalPosition", v)
                    mguard.swept = mguard.swept + 1
                    _log("monster guard: EVICTED " .. nm .. " - walked 300m off the property")
                end
            end)
        end
    end)
end
-- ── ⭐ WAKE-DRIFT GUARD (Aurora 08-06: "sleep in a homestead bed -> wake at the last place
-- you rested / maybe Battahl's default"). Sleeping outside a REGISTERED rest point lets the
-- game hand you to its own wake spot - we can't register our bed with the inn system, so we
-- un-teleport instead. Destination-agnostic: wherever the game sent you, you come back.
-- Mechanics: the sleep fade advances the clock GRADUALLY (spinning-sky time-lapse) and the
-- teleport lands at the END - so a single-tick clock-jump test would miss it. Instead:
--   * a tick that advances >=20 in-game minutes marks time as "fast" for 15s real time;
--   * the ANCHOR (your bedside) only updates on normal-time ticks - it freezes when the
--     time-lapse starts;
--   * materialising >50m from a frozen anchor that sat inside a plot ring, while the fast
--     window (+10s grace) is hot -> requestPlayerWarp back to the anchor at the NEW clock
--     (time passes, the trip doesn't).
-- Never false-fires on: our own teleports (no fast time - anchor just follows), campfire
-- waits (no movement), ferrystones (no clock jump), save-loads (player GO address changes
-- -> full reseed). Known accepted quirk: napping on an oxcart you BOARDED inside a plot
-- ring would bounce you back to the stop - the ring would have to cover a station first.
local wdg = { at = 0 }
local function _wdg_tick()
    if M.wake_guard == false then return end
    local now = os.clock()
    if now - (wdg.at or 0) < 0.5 then return end
    wdg.at = now
    pcall(function()
        local pgo = _pch():call("get_GameObject")
        local addr = pgo and pgo:get_address()
        local up = _pupos()
        local tm = sdk.get_managed_singleton("app.TimeManager")
        if not (addr and up and tm) then
            -- no player = a loading screen (or menu): keep the settle gate hot
            if os.clock() - (mguard.said_at or 0) > 5.0 then
                mguard.said_at = os.clock()
                _log(string.format("settle gate: armed +20s - player unreadable (addr=%s pos=%s time=%s)",
                    tostring(addr ~= nil), tostring(up ~= nil), tostring(tm ~= nil)))
            end
            mguard.settle_until = os.clock() + 20.0
            return
        end
        local day = tonumber(tm:call("get_InGameDay")) or 0
        local mins = day * 1440 + (tonumber(tm:call("get_InGameHour")) or 0) * 60
                     + (tonumber(tm:call("get_InGameMinute")) or 0)
        if wdg.addr ~= addr then   -- first seed or a save-load: start fresh, never fire
            _log(string.format("settle gate: armed +20s - player GO address changed (%s -> %s)",
                tostring(wdg.addr), tostring(addr)))
            wdg.addr, wdg.mins = addr, mins
            wdg.anchor, wdg.fast_until = nil, nil
            mguard.settle_until = os.clock() + 20.0   -- new world: door intercept stands down
        end
        local fast = (mins - (wdg.mins or mins)) >= 20
        wdg.mins = mins
        if fast then wdg.fast_until = now + 15.0 end
        local a = wdg.anchor
        if a and now >= (tonumber(mguard.settle_until) or 0)   -- never warp while the world assembles
            and now < (wdg.fast_until or 0) + 10.0 then
            local dx, dz = up.x - a.ux, up.z - a.uz
            if dx * dx + dz * dz > 50 * 50 and _mg_near_plot(a.ux, a.uz) then
                local tsm = sdk.get_managed_singleton("app.TimeSkipManager")
                local pos = ValueType.new(sdk.find_type_definition("via.Position"))
                pos.x, pos.y, pos.z = a.ux, a.uy + 0.6, a.uz
                tsm:call("requestPlayerWarp",
                    tm:call("get_InGameHour"), tm:call("get_InGameMinute"), tm:call("get_InGameDay"),
                    pos, _ptf():call("get_Rotation"), nil, true, true)
                wdg.anchor, wdg.fast_until = nil, nil
                _log(string.format("wake-drift guard: slept at the homestead, the game moved you %.0fm away - warped back to the bedside", math.sqrt(dx * dx + dz * dz)))
                return
            end
        end
        if not fast and now > (wdg.fast_until or 0) then
            wdg.anchor = { ux = up.x, uy = up.y, uz = up.z }
        end
    end)
end
local function _tend()
    local plot, dist = _nearest_plot()
    if not plot or (dist or 999) > M.plot_range then
        -- away from home the tend key STILL milks/collects (Aurora 08-06: "no option to milk
        -- these oxen in this farm" - the plot gate was eating the animal branch before it ran).
        -- The cow is the requirement, not the address. Beds/cookpots stay plot-bound below.
        _try_animal_produce()
        return
    end
    local b = _target_bed()
    if not b then
        -- no bed underfoot: the same key COOKS when you're stood at a placed Cooking pot,
        -- and MILKS/COLLECTS when you're stood at a matched animal
        if _cookpot_near() then _show_cook_menu()
        elseif _try_animal_produce() then -- handled (grant or already-today message)
        else _log("tend: no bed here; " .. tostring(cookpot.why or "no cookpot data")) end
        return
    end
    if not b.crop then
        if #_cats_with_seed() > 0 then do_sow(b)
        else _log("no seed in your pack - buy some, or combine 2 of a crop to make seed") end
        return
    end
    _show_bed_menu(b)
end

-- ── input ─────────────────────────────────────────────────────────────────────────────────
_load()
-- ⛔ ORPHAN CARRIER SWEEP (08-05): mound/sprout/audition carriers are folderless GameObjects and
-- SURVIVE a script reset - the reloaded beds then spawn FRESH carriers while the old ones linger,
-- and a bed removed after a reset leaves its pre-reset mound standing forever. Every carrier is
-- ours by name; destroy them all at load and let the bed tick respawn what should exist.
pcall(function()
    local smgr = sdk.get_native_singleton("via.SceneManager")
    local scene = smgr and sdk.call_native_func(smgr, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    local swept = 0
    for _, nm in ipairs({ "IrisSeedBed", "IrisSprout", "IrisAudition" }) do
        for _ = 1, 60 do
            local go = scene and scene:call("findGameObject(System.String)", nm)
            if not go then break end
            go:call("destroy", go); swept = swept + 1
        end
    end
    if swept > 0 then _log("orphan sweep: " .. swept .. " stale carrier(s) from before the reset destroyed") end
end)
-- forward declaration (the ORDERING LAW, 6th catch): the update loop below calls this, but the
-- surveyor block that defines it lives after the loop in the file. `function _svy_prospect_tick`
-- down there assigns THIS local; the call is nil-guarded until then.
local _svy_prospect_tick
local KEY = {}
local function _edge(vk)
    local now = false
    pcall(function() now = iris_kb(vk) == true end)   -- gated read (000IrisInputGate): dead while the overlay / any text box is open
    local was = KEY[vk]; KEY[vk] = now
    return now and not was
end
-- gamepad reader for the tend button (the hoe still needs no key - it's a swing)
local PAD = { names = {}, prev = 0 }
pcall(function()
    local t = sdk.find_type_definition("via.hid.GamePadButton")
    for _, f in ipairs(t:get_fields()) do pcall(function() PAD.names[f:get_name()] = f:get_data() end) end
end)
-- ⛔ THE SILENT-FALLTHROUGH TRAP: this used to try {name, "B", "Circle", "RDown", "Decide"} and
-- return the first that existed, saying nothing. "B" and "Circle" are NOT fields of
-- via.hid.GamePadButton, so every lookup slid down to RDown (= Xbox A) while M.tend_pad still
-- read "B" and the on-screen prompt dutifully printed the wrong letter. It now resolves ONCE and
-- LOGS what it actually landed on, so a name that doesn't exist can never masquerade as one that
-- does. PAD.resolved is also what the prompt reads, so the label is the truth by construction.
local function _pad_bit(name)
    local want = tostring(name or "")
    if PAD.resolved_for == want then return PAD.resolved or 0 end
    PAD.resolved_for = want
    if PAD.names[want] then
        PAD.resolved, PAD.resolved_name = PAD.names[want], want
    else
        -- a bad name falls back, but LOUDLY and to the game's own confirm button
        PAD.resolved, PAD.resolved_name = PAD.names["RDown"] or 0, PAD.names["RDown"] and "RDown" or nil
        _log(string.format("gamepad: '%s' is not a via.hid.GamePadButton field -> using %s",
            want, tostring(PAD.resolved_name or "NOTHING")))
    end
    return PAD.resolved or 0
end
-- ⭐⭐ EAT THE JUMP (Aurora 08-04: "we'll need to disable jump when pressing A to interact with the
-- plot"). A is DD2's jump, so every interact was also a hop. Nick's devtools proved the shape:
-- sdk.hook a method on app.PlayerInputProcessor and return SKIP_ORIGINAL from the pre-hook.
-- ⛔ THE GATE IS "AM I STANDING AT A BED", NOT "WAS A JUST PRESSED". Keying it off our own keypress
-- would be a race - the engine's input pass and our UpdateBehavior tick have no guaranteed order,
-- so the jump could fire before we ever saw the button. A continuous positional gate has no such
-- window, and it's the behaviour you actually want: while you're stood on a bed, A means tend.
-- ⚠ The method NAME is a guess, so this enumerates every Jump-ish method on the processor and LOGS
-- them. If jumping still happens, that log line names the method to add to the list.
-- ⛔⛔ THE INPUT-PROCESSOR ROUTE WAS WRONG AND GAME-BREAKING (Aurora 08-04: "when making a bed it
-- stops ALL movement controls and not just jump"). v1 hooked app.PlayerInputProcessor by guessed
-- method name and returned SKIP_ORIGINAL. Those methods are not a jump handler - they're a stage of
-- the input pipeline that locomotion also runs through, so skipping one froze the whole character.
-- ⭐ THE RIGHT LEVEL IS THE ACTION, NOT THE INPUT. IrisWoodcutting already proved the shape: hook
-- `app.ActionManager.requestActionCore`, match the requested action BY NAME, and block only that
-- name. Nothing else in the pipeline is touched, so movement, camera and dodge are untouched too.
-- ⚠ ITS OWN HARD-WON LAW APPLIES: blocking a link the FSM needs wedges the action graph. Jump is a
-- far more self-contained node than the attack chains that taught that lesson, and this only fires
-- while you're stood on a bed, but the name list stays deliberately narrow.
local jump_block = { on = false, seen = {} }
pcall(function()
    local m = sdk.find_type_definition("app.ActionManager")
        :get_method("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)")
    if not m then _log("jump block: requestActionCore not found"); return end
    sdk.hook(m, function(args)
        if not jump_block.on then return end
        local block = false
        pcall(function()
            -- the PLAYER's ActionManager only: pawns and enemies request through this too
            local cm = sdk.get_managed_singleton("app.CharacterManager")
            local pl = cm and cm:call("get_ManualPlayer")
            local pam = pl and pl:call("get_ActionManager")
            local am = sdk.to_managed_object(args[2])
            if not (am and pam and am:get_address() == pam:get_address()) then return end
            local name = sdk.to_managed_object(args[4])
            local s = name and tostring(name:call("ToString()")) or ""
            -- ⭐ B is DD2's dodge/dash as well as its interact, so moving our button to
            -- B means suppressing dodge exactly as A required suppressing jump.
            -- Matched BY NAME, logged once per distinct action so an unseen variant
            -- names itself in the log instead of us guessing at it.
            if s:find("Jump")
               or (M.block_dodge ~= false and (s:find("Dodge") or s:find("Dash")
                   or s:find("StepAvoid") or s:find("Avoid"))) then
                -- log each distinct name ONCE, so the exact node is on record if this ever needs
                -- narrowing further (the woodcutter's self-reporting trick)
                if not jump_block.seen[s] then
                    jump_block.seen[s] = true
                    _log("jump block: blocking action '" .. s .. "' at a bed")
                end
                block = true
            end
        end)
        -- ⛔ the pcall above CANNOT return SKIP_ORIGINAL - it would escape the closure, not the
        -- hook. Set `block` in there and act on it out here. Straight from IrisWoodcutting.
        if block then return sdk.PreHookResult.SKIP_ORIGINAL end
    end, function(r) return r end)
    _log("jump block: hooked requestActionCore (action-level, input pipeline untouched)")
end)

-- the human-facing letter for whatever the pad actually resolved to
local function _pad_label()
    _pad_bit(M.tend_pad)
    local n = PAD.resolved_name or tostring(M.tend_pad or "")
    return (M.pad_labels and M.pad_labels[n]) or n
end
local function _pad_raw()
    local cur = 0
    pcall(function()
        local pm = sdk.get_native_singleton("via.hid.GamePad")
        local dev = pm and sdk.call_native_func(pm, sdk.find_type_definition("via.hid.GamePad"), "get_MergedDevice")
        if dev then cur = math.floor(dev:call("get_Button") or 0) end
    end)
    return cur
end
local function _pad_edge()
    local bit = _pad_bit(M.tend_pad)
    if bit == 0 then return false end
    local cur = _pad_raw()
    local hit = (cur & bit) == bit and (PAD.prev & bit) ~= bit
    PAD.prev = cur
    return hit
end

re.on_application_entry("UpdateBehavior", function()
    if not M.enabled then return end

    -- the dialog reader runs FIRST and unguarded (the deed-sign law: our dialog pauses the world)
    if dlg.open then
        -- ⭐⭐ LIVENESS, not just a timeout (08-08). `dlg.open` gates the ring AND both labels,
        -- so any path that leaves it stuck blinds the HUD - and the only escape used to be a
        -- THIRTY SECOND stuck-guard. Cheap real signal, using the API we already call:
        -- an OPEN dialog reports a state (None=0 while untouched); a dialog that has GONE
        -- reports nil. So nil for a sustained moment means it is genuinely gone, and unlike
        -- the 30s backstop this cannot be confused with the player reading the menu slowly.
        -- ⚠ Must read the RAW return - the baseline comparison below nils `p` on every
        -- unchanged frame, so testing that would call a perfectly healthy dialog dead.
        local raw = _dialog_pick()
        if raw == nil then
            dlg.nil_since = dlg.nil_since or os.clock()
            if os.clock() - dlg.nil_since > 1.5 then
                _log("dialog vanished without a pick (menu/cutscene took it) - closing so the HUD returns")
                _close_dialog(); return
            end
        else
            dlg.nil_since = nil
        end
        local p = raw
        if p ~= nil and p ~= dlg.baseline then dlg.baseline = p else p = nil end
        if p ~= nil and os.clock() - dlg.opened_at < 0.25 then p = nil end
        if p == nil and os.clock() - dlg.opened_at > 30.0 then _close_dialog(); return end
        if p ~= nil then
            if p == 5 then _close_dialog(); return end          -- native Cancel (Esc / pad B)
            -- the 4th slot sits one past the offered entries: "More..." while pages remain,
            -- otherwise "Cancel" - so every page has a visible way out
            if dlg.opts and p == #dlg.opts + 1 and not dlg.more then _close_dialog(); return end
            if dlg.phase == "sow_cat" then
                if dlg.more and p == #dlg.opts + 1 then
                    local page = (dlg.page or 1) + 1
                    local cats = dlg.cats
                    _close_dialog()
                    dlg.cats = cats
                    _paged_dialog("Sow what?", cats, function(c) return c end, page, "sow_cat")
                    return
                end
                local cat = dlg.opts and dlg.opts[p]
                _close_dialog()
                if cat then _show_seed_page(cat, 1) end
            elseif dlg.phase == "sow_pick" then
                -- the "More..." slot sits one past the offered crops
                if dlg.more and p == #dlg.opts + 1 then
                    local cat, page = dlg.cat, (dlg.page or 1) + 1
                    _close_dialog()
                    _show_seed_page(cat, page)
                elseif dlg.opts and dlg.opts[p] then
                    local c, b = dlg.opts[p], dlg.bed
                    _close_dialog()
                    if b and not b.crop and _seed_take(c, 1) then
                        b.crop, b.grown, b.dry, b.missed = c.key, 0, 0, 0
                        -- ⛔ A FRESHLY SOWN BED IS **DRY** (Aurora 08-04: "when the seed is planted
                        -- it starts watered? and currently no way to actually water"). This used to
                        -- set watered_day = today as a courtesy - "sown ground counts as watered".
                        -- That single line caused BOTH symptoms she reported: the label read
                        -- "watered" the instant she planted, AND because the tend button only
                        -- offered water when the bed was dry, day one could never be watered at all.
                        -- Planting and watering are two separate chores in Stardew, and that's the
                        -- whole first-day loop. Leave it dry.
                        b.watered_day = nil
                        _save()
                        _log(string.format("sowed %s - %d in-game days of watered growth to ripen", c.name, c.days))
                    end
                else _close_dialog() end
            elseif dlg.phase == "bed_act" then
                local act, b = dlg.acts and dlg.acts[p], dlg.bed
                _close_dialog()
                if b and act == "harvest" then do_harvest(b)
                elseif b and act == "water" then do_water(b)
                elseif b and act == "watered" then
                    _log("already watered today - come back tomorrow")
                elseif b and act == "uproot" then
                    -- ⛔ CONFIRM, ALWAYS. Uprooting throws away every day of growth and refunds
                    -- nothing, so it never happens on a single button press. This replaces the
                    -- swing-twice-with-the-hoe scheme, which she couldn't get to fire at all.
                    local st = _bed_state(b)
                    dlg.bed = b
                    dlg.opts, dlg.acts, dlg.more = { "yes" }, { "yes" }, false
                    _show_dialog("Uproot the " .. (st and st.crop.name or "crop") .. "? Nothing is refunded.",
                        "Yes, dig it up", "No, leave it", nil, nil, "uproot_ok")
                end
            elseif dlg.phase == "uproot_ok" then
                local b = dlg.bed
                local yes = (p == 1)
                _close_dialog()
                if yes and b and b.crop then
                    local nm = (_crop(b.crop) or {}).name or b.crop
                    b.crop, b.grown, b.dry, b.missed = nil, 0, 0, 0
                    b.sown_day, b.watered_day = nil, nil
                    if b.live then pcall(function() b.live:call("destroy", b.live) end); b.live = nil end
                    _drop_sprout(b); b.pending = nil
                    _save()
                    _log("uprooted " .. tostring(nm) .. " - the bed is bare soil again")
                end
            elseif dlg.phase == "cook" then
                if dlg.more and p == #dlg.opts + 1 then
                    local page = (dlg.page or 1) + 1
                    _close_dialog()
                    local avail = {}
                    for _, r in ipairs(M.cook_recipes) do if r.out then avail[#avail + 1] = r end end
                    _paged_dialog("Cook what?", avail, function(r)
                        return r.label .. (_cookable(r) and "" or "  (missing ingredients)")
                    end, page, "cook")
                elseif dlg.opts and dlg.opts[p] then
                    local r = dlg.opts[p]
                    _close_dialog()
                    if _cookable(r) then
                        for _, ing in ipairs(r.ins) do
                            pcall(function()
                                sdk.get_managed_singleton("app.ItemManager"):call(
                                    "deleteItem(System.Int32, System.Int32, app.Character)", ing[1], ing[2], _pch())
                            end)
                        end
                        -- ⭐ THE POT'S OWN COOKING ANIMATION (Aurora 2026-08-08: she found the
                        -- cookpot is jackable and does a real cooking motion — far better than
                        -- our mimed stir). Timed, not move-to-cancel: stirring is a task, so it
                        -- runs its span and hands control back on its own.
                        -- ⛔ Only reached AFTER a recipe was chosen and the ingredients were
                        -- consumed, so cancelling the menu never plays it — which is what she
                        -- asked for. The dish is granted by on_done, which IrisHomeLife
                        -- guarantees fires exactly once even if the jack is refused outright.
                        local pot = (M.cook_jack ~= false) and cookpot.find_go() or nil
                        -- ⭐⭐⭐ THE REAL COOKING ANIMATION, CAPTURED NOT GUESSED (2026-08-08).
                        -- Aurora cooked at a campfire with the motion tape running:
                        --   bank=0 id=1103  (start, ~1s) -> 1104 (loop, ~12s) -> 1105 (end, ~3s)
                        -- isolated by a 29s gap and followed by plain idles. The tape's "bank 0"
                        -- is our bank 60: the same run logged 2000/2010/2020 when she sat in a
                        -- chair, which is sit_chair01's known start/loop/end in liv_split.
                        -- ⇒ played with changeMotion through the existing chore system. NO jack,
                        -- so none of the CTD risk that made jacking gm80_256 unusable.
                        if M.cook_anim ~= false then
                            _chore_start({ { 60, 1103, 60 }, { 60, 1104, 360 }, { 60, 1105, 180 } },
                                "cooking", function()
                                    _log(string.format("about to grant '%s' -> item id %s x%s",
                                        r.label, tostring(r.out[1]), tostring(r.out[2])))
                                    local got = _grant_item(r.out[1], r.out[2])
                                    _log("cooked: " .. r.label .. " x" .. tostring(got or r.out[2]))
                                end)
                        elseif pot and _G.IrisHomeLife and _G.IrisHomeLife.jack_for
                           and _G.IrisHomeLife.jack_for(pot, M.cook_jack_secs or 10.0,
                                { "Cook", "Cooking", "CookStart", "StartAction", "ActStart" },
                                function()
                                    -- ⛔ ANNOUNCE BEFORE GRANTING. A crash inside _grant_item
                                    -- leaves no trace otherwise, and "which item id was it"
                                    -- is the single fact that identifies a bad custom dish.
                                    _log(string.format("about to grant '%s' -> item id %s x%s%s",
                                        r.label, tostring(r.out[1]), tostring(r.out[2]),
                                        (tonumber(r.out[1]) or 0) > 31000
                                            and "   <- CUSTOM Content Editor item" or ""))
                                    local got = _grant_item(r.out[1], r.out[2])
                                    _log("cooked (pot animation): " .. r.label .. " x" .. tostring(got or r.out[2]))
                                end) then
                            -- the pot is doing the work; skip the mimed emote entirely
                        elseif M.cook_emote ~= false then
                            _chore_start({ { M.cook_bank or 60, M.cook_clip or 6050, M.cook_f or 240 } }, "cooking", function()
                                local got = _grant_item(r.out[1], r.out[2])
                                _log("cooked: " .. r.label .. " x" .. tostring(got or r.out[2]))
                            end)
                        else
                            local got = _grant_item(r.out[1], r.out[2])
                            _log("cooked: " .. r.label .. " x" .. tostring(got or r.out[2]))
                        end
                    else
                        _log("missing ingredients for " .. r.label)
                    end
                else _close_dialog() end
            end
        end
        return
    end

    _pump_jobs()
    _pump_mound_binds()      -- the custom-mesh bind/cure phases (never same-frame)
    _pump_till_clears()      -- the budgeted foliage clear (10k instance reads/tick, nothing dropped)
    _water_emote_pump()
    _chore_pump()
    _aniq_pump()
    if _svy_prospect_tick then _svy_prospect_tick() end
    _mg_sweep()
    _wdg_tick()
    _advance_days()
    _tick_props()
    _tick_cookfires()
    _reassert_tilled()

    -- ⛔ PAUSE GATE (Aurora 07-26: "the 'what seeds do you want to plant' option can't come up
    -- during pause"). The dialog READER above stays unguarded on purpose - our own dialog pauses
    -- the world, so guarding it would softlock (the deed-sign law) - but nothing may START an
    -- action while a game menu is up.
    if _game_paused() then PAD.prev = _pad_raw(); return end   -- keep the pad edge in sync while blocked

    -- the TEND button (sow / water / harvest at the bed underfoot). The hoe still has no key.
    -- Both are read every tick: `or` short-circuits, and skipping _pad_edge() desyncs PAD.prev.
    local kb, pad = _edge(M.tend_key or 0), _pad_edge()
    -- ⛔ ONE ACTION AT A TIME (Aurora 08-09). Several IRIS modules read the same button, so
    --   overlapping reaches used to fire BOTH - and the loser fired again the moment the
    --   winner's menu closed. The arbiter (IrisPromptBar) picks the NEAREST interactable, and
    --   the GAME's own interact outranks all of ours. Edges are still consumed above, so a
    --   refused press cannot fire later once we become the winner.
    local mine, prompt_owner = true, nil
    if _G.IrisPrompt then
        if _G.IrisPrompt.native_busy() then mine = false
        else
            local w = _G.IrisPrompt.winner()
            prompt_owner = w
            if w and w ~= "farm_bed" and w ~= "cookpot" and w ~= "farm_animal" then mine = false end
        end
    end
    if (kb or pad) and mine and os.clock() - (dlg.closed_at or 0) > 0.35 then
        -- Execute the action the winning native prompt actually advertised. `_tend()` has a
        -- historical bed-first precedence which is correct as a fallback, but could otherwise
        -- show "Collect egg" for the nearer hen and open a bed menu behind it.
        if prompt_owner == "farm_animal" then _try_animal_produce()
        elseif prompt_owner == "cookpot" then
            if cookpot.live_near() then _show_cook_menu()
            elseif _G.IrisPrompt then _G.IrisPrompt.clear("cookpot") end
        else _tend() end
    end

    -- refresh the jump gate ONCE per tick, so the native hook only ever reads a cached boolean and
    -- never does a bed scan inside the engine's input pass
    if M.block_jump ~= false then
        local b = _nearest_bed()
        -- the cookpot counts too (Aurora 08-05: "suppress jump like the farmland") - A must cook,
        -- not hop. near_now is published by the prompt's throttled check, so this stays cheap.
        jump_block.on = dlg.open or (b ~= nil) or (cookpot.near_now == true) or (ani.near_now == true)
    else
        jump_block.on = dlg.open
    end
    if (M.debug_key or 0) ~= 0 and _edge(M.debug_key) then _hoe_strike("debug") end
end)

-- ── ⭐ THE HOE TARGET RING (Aurora 07-26: "would it be possible to put a crosshair on the ground
-- for where the hoe is going to actually hit?"). No photomode needed - the till spot is already
-- computed exactly (player + facing * till_ahead), so we ring it. Points are placed on a circle in
-- WORLD space and projected individually, so the ring lies flat on the ground in proper
-- perspective instead of being a flat screen circle.
--   GREEN  = a swing here breaks new ground
--   AMBER  = too close to an existing bed (the swing will be refused) - shows the spacing rule
-- ⛔ draw.* takes ABGR (0xAABBGGRR), NOT ARGB - reframework-d2d/IrisFont are the ARGB ones.
-- The first pass authored these as ARGB: green survived only because 7C-E8-7C is symmetric, while
-- amber E8-A2-4A came out as light BLUE with red and blue swapped (Aurora 07-26: "what's the
-- difference between blue and green?"). Write ring colours ABGR.
re.on_frame(function()
    if not (M.enabled and M.ring) or dlg.open or _hud_hidden() then return end
    -- ⛔⛔ THE SETTLE GATE NO LONGER BLINDS THE HUD (Aurora 08-08, second report: "the labels
    -- keep disappearing if you plant a seed, or equip the hoe - it also makes the hoe reticule
    -- disappear"). The 08-06 fix (`if dlg.open then return end` at the arm site, :2969) only
    -- covered OUR dialogs, so it could never have worked for the INVENTORY: equipping the hoe
    -- is a full-screen native GUI, get_IsLoadGui goes true, and a 15s blackout arms. Planting a
    -- seed hit the same thing through the back door - _close_dialog() clears dlg.open while the
    -- native GUI is still tearing down, so the gate armed in the gap.
    -- ⭐ THE REAL BUG IS THE COUPLING, not the arm condition. The settle gate exists to stop
    -- MONSTER EVICTION and DOOR WARPS running while the world assembles (they hung a load).
    -- A ground ring and a floating label cannot hang anything. Gating them on it was collateral
    -- damage, and no arm-condition patch can fix a gate that should never have applied here.
    -- ⇒ the gate keeps its real job (:2990, :3086) and lets go of the HUD.
    pcall(function()
        if not _hoe_equipped() then return end   -- STRICT: the marker belongs to the tool, not the bypass
        local plot, dist = _nearest_plot()
        if not plot or (dist or 999) > M.plot_range then return end
        local up = _pupos(); local d = _delta()
        if not (up and d) then return end
        local ux, _uy, uz = _till_spot(true)
        if not ux then return end
        -- ⭐ AUTO-AIM (08-05): run the SAME snap the swing will - the ring locks onto the row
        -- grid, so "the cell next to that bed" is something you see before you commit
        local pfx, pfz = _pfwd()
        local sux, _suy, suz = _snap_spot(ux, up.y, uz, math.deg(math.atan(pfx, pfz)))
        ux, uz = sux, suz
        -- the ring says what THIS swing will do, at the exact spot it lands (ABGR colours):
        --   green = cut a new bed · amber = level this empty bed back over (the undo)
        --   red   = something is growing here; the swing leaves it alone
        local b = _bed_at(ux, uz)
        local col = 0xFF7CE87C                                   -- green: new ground
        if b then col = b.crop and 0xFF6060FF or 0xFF4AA2E8       -- red: protected · amber: undo
        elseif not _ground_under(ux - d.x, up.y - d.y, uz - d.z, M.ground_probe or 2.5) then
            col = 0xFF4040FF                                      -- RED: nothing to till (cliff edge)
        elseif M.block_indoors ~= false
            and _ceiling_above(ux - d.x, up.y - d.y, uz - d.z, M.roof_height or 4.0) then
            col = 0xFF4040FF                                      -- RED: there's a roof over this spot
        end
        local cx, cy, cz = ux - d.x, up.y - d.y, uz - d.z      -- ring is drawn in RENDER space
        local r = (M.bed_spacing or 1.6) * 0.5
        local n = 24
        for i = 0, n - 1 do
            local a = (i / n) * math.pi * 2
            local sp = draw.world_to_screen(Vector3f.new(cx + math.cos(a) * r, cy + 0.05, cz + math.sin(a) * r))
            if sp then draw.filled_circle(sp.x, sp.y, 2.5, col, 6) end
        end
        local mid = draw.world_to_screen(Vector3f.new(cx, cy + 0.05, cz))
        if mid then draw.filled_circle(mid.x, mid.y, 3.5, col, 8) end

        -- ⭐ EXISTING BEDS get a ring too (Aurora 07-26: "when I hoe the ground I'm not seeing
        -- anything appear"). Beds WERE being made - the mound prop is just switched off until her
        -- custom mesh lands, so a finished bed was invisible and the next swing silently undid it.
        -- This needs no asset at all and stays useful afterwards.
        --   dim brown = bare soil · green = growing · bright = RIPE · red = wilting   (ABGR)
        for _, b in ipairs(beds) do
            local bdx, bdz = b.ux - up.x, b.uz - up.z
            if bdx * bdx + bdz * bdz < 400.0 then          -- within 20m
                local bc = 0xC04A80A8                       -- bare tilled soil (dim brown)
                local st = b.crop and _bed_state(b)
                if st then
                    if st.ripe then bc = 0xFF60FFC0
                    elseif st.wilting then bc = 0xFF5050FF
                    else bc = 0xC060C070 end
                end
                local bx, by, bz = b.ux - d.x, b.uy - d.y, b.uz - d.z
                local br = (M.bed_spacing or 1.6) * 0.45
                for i = 0, 11 do
                    local a = (i / 12) * math.pi * 2
                    local s2 = draw.world_to_screen(Vector3f.new(bx + math.cos(a) * br, by + 0.04, bz + math.sin(a) * br))
                    if s2 then draw.filled_circle(s2.x, s2.y, 2.0, bc, 5) end
                end
            end
        end
    end)
end)

-- ⭐⭐ CONTEXT PROMPT AT THE BED (Aurora 07-27: "if you approach tilled soil a thing should appear
-- saying press [button] to plant seeds - because right now it seems like guesswork"). This is NOT
-- the old top-left nag she had removed: it's a WORLD-SPACE label floating over the bed you're
-- actually standing at, naming the one action available there. It appears only when there IS
-- something to do, and never during a dialog.
re.on_frame(function()
    if not M.enabled or dlg.open or _hud_hidden() or not (M.bed_prompt ~= false) then return end
    -- ⛔ settle gate deliberately NOT consulted here - see the ring's note (08-08). A label
    -- cannot hang a load, and gating it here is what blanked the HUD on every menu.
    pcall(function()
        local b = _target_bed()
        if not b then return end
        local d = _delta(); if not d then return end
        local verb
        if not b.crop then
            if #_cats_with_seed() > 0 then
                verb = "Plant seeds"
            else
                verb = "Tilled soil - no seed in your pack"
            end
        else
            local st = _bed_state(b)
            if st and st.ripe then verb = "Harvest the " .. st.crop.name
            elseif st and b.watered_day ~= _today() then verb = "Water the " .. st.crop.name
            elseif st then
                verb = string.format("%s  %d/%d days  (watered)", st.crop.name, b.grown or 0, st.crop.days)
            end
        end
        if not verb then return end
        -- ⭐ publish a SHORT verb to the game's own button panel (IrisPromptBar), so it reads
        --   "B Sow" instead of "B Dash" (Aurora 08-09). The world label keeps the long form -
        --   the panel has room for a word, not a sentence. Priority 10: ambient, so a
        --   deliberate walk-up like the weapon plaque (20) out-ranks a bed you stand near.
        if _G.IrisPrompt then
            local short = (not b.crop and #_cats_with_seed() > 0) and "Plant seeds"
                or (verb:find("^Harvest") and verb)
                or (verb:find("^Water") and verb) or nil
            local bd = 1e9
            pcall(function()
                local up = _pupos()
                if up and b.ux then
                    local dx, dz = b.ux - up.x, b.uz - up.z
                    bd = math.sqrt(dx * dx + dz * dz)
                end
            end)
            if short then
                local bp = Vector3f.new(b.ux - d.x, b.uy - d.y + (M.prompt_height or 0.9), b.uz - d.z)
                _G.IrisPrompt.set("farm_bed", short, 10, bd, bp, nil)
            else
                _G.IrisPrompt.clear("farm_bed")
            end
        end
        -- No button action exists for watered crops or empty seed inventories. Do not dress
        -- informational crop state up as an interaction prompt.
        local actionable = (not b.crop and #_cats_with_seed() > 0)
            or verb:find("^Harvest") or verb:find("^Water")
        if not actionable then return end
        -- Native ui020701 is the sole action prompt. A legacy fallback lingers for a cached
        -- scan after the native guide withdraws, producing a false gold prompt out of range.
    end)
end)

-- ══ ⭐⭐ PLOT SURVEYOR (Aurora 08-05: "markers on the map on potentially viable places... with
-- teleporters like the griffin rest nodes"). The game proposes, she disposes:
--   1. GENERATE: enumerate app.AIKeyLocation for camp-named entries - Capcom's own designers
--      chose those spots as flat, safe and quest-free, so they seed the candidate list.
--      Positions come from app.AIAreaManager:getKeyLocationNode():get_UniversalPosition(),
--      which works WITHOUT streaming (the devtools/griffin-nest lesson: named AI concepts are global).
--   2. Candidates render as their own map markers (green, own glyph) with hover names.
--   3. WARP: app.TimeSkipManager:requestPlayerWarp at the current clock = pure position warp
--      (devtools' shipped pattern, our own code).
--   4. SURVEY HERE: a 5x5 raycast grid over ~14m - height spread, missing-ground count, roof
--      check - the same _ground_y/_ceiling_above probes the beds trust.
--   5. She places the real plot with the existing homestead flow; DISMISS hides a candidate.
local svy = { verdict = nil }
local SVY_FILE = "IRIS/survey_candidates.json"
local function _svy()
    if not svy.list then svy.list = json.load_file(SVY_FILE) or {} end
    return svy.list
end
local function _svy_save() pcall(function() json.dump_file(SVY_FILE, _svy()) end) end
-- ⛔ CAMP SEEDING REMOVED (Aurora 08-05: "they already have set gimmicks in the place where
-- people set up camps - I don't want to interfere with that"). She's right: the camp IS the
-- flat spot, so a candidate there collides with the camp system. AIKeyLocation survives only
-- as a NAMER - candidates get christened after the nearest known location for orientation.
local function _svy_locs()
    if svy.locs then return svy.locs end
    svy.locs = {}
    pcall(function()
        local td = sdk.find_type_definition("app.AIKeyLocation")
        local am = sdk.get_managed_singleton("app.AIAreaManager")
        for _, f in ipairs(td:get_fields()) do
            local nm = f:get_name()
            if nm ~= "value__" and f:is_static() then
                pcall(function()
                    local node = am:call("getKeyLocationNode", f:get_data(nil))
                    local up = node and node:call("get_UniversalPosition")
                    if up then svy.locs[#svy.locs + 1] = { name = nm, x = up.x, z = up.z } end
                end)
            end
        end
    end)
    _log("surveyor: location namer cached " .. #svy.locs .. " known place(s)")
    return svy.locs
end
local function _svy_near_name(ux, uz)
    local best, bd = nil, 1e18
    for _, l in ipairs(_svy_locs()) do
        local dx, dz = l.x - ux, l.z - uz
        local d = dx * dx + dz * dz
        if d < bd then bd = d; best = l end
    end
    if best then return string.format("near %s (%.0fm)", best.name, math.sqrt(bd)) end
    return "unknown parts"
end
-- shared scoring core: spread / misses / roof at a RENDER-space centre
local function _survey_score(rx, ry, rz)
    local hs, fails = {}, 0
    for gx = -2, 2 do
        for gz = -2, 2 do
            local y = _ground_y(rx + gx * 3.5, ry, rz + gz * 3.5, 6.0)
            if y then hs[#hs + 1] = y else fails = fails + 1 end
        end
    end
    if #hs == 0 then return nil end
    local mn, mx = math.huge, -math.huge
    for _, y in ipairs(hs) do mn = math.min(mn, y); mx = math.max(mx, y) end
    return mx - mn, fails, _ceiling_above(rx, ry, rz, 6.0)
end
-- ⭐⭐ THE PROSPECTOR: passive scanning while she roams. Raycasts only work where the world is
-- STREAMED - i.e. around the player - so the tool samples the ground under her travels instead
-- of pretending it can scan the map from nowhere. A spot qualifies when: flat (spread < 0.9m,
-- no misses), roofless, ZERO gimmicks within prospect_gim_r, and not within prospect_gap of any
-- existing candidate/plot. Qualifiers self-mark as green map candidates named by _svy_near_name.
-- ⭐ the FLIGHT-DEPTH ground finder: from a griffin the terrain is 100m+ below, far past
-- _ground_y's ~20m reach (Aurora 08-05: "if I fly on the griffin it says no ground found").
-- Long cast, TOPMOST contact = the ground under this column, whatever height we're at.
local function _ground_top(rx, ry, rz)
    if not _ensure_ray() then return nil end
    local best
    pcall(function()
        ray.filter:set_Group(0); ray.filter:set_Layer(2); ray.filter:set_MaskBits(0)
        ray.result:clear()
        ray.query:call("setRay(via.vec3, via.vec3)",
            _vec3(rx, ry + 5.0, rz), _vec3(rx, ry - 400.0, rz))
        ray.method:call(ray.system, ray.query, ray.result)
        local n = ray.result:get_NumContactPoints() or 0
        for k = 0, n - 1 do
            local c = ray.result:call("getContactPoint(System.UInt32)", k)
            local p = c and sdk.get_native_field(c, ray.contact_td, "Position")
            if p and p.y < ry + 5.0 and (not best or p.y > best) then best = p.y end
        end
    end)
    return best
end
function _svy_prospect_tick()   -- assigns the forward local declared above the update loop
    if not M.prospect then svy.announced = nil; return end
    local now = os.clock()
    if now - (svy.ticked or 0) < (M.prospect_every or 4.0) then return end
    svy.ticked = now
    if not svy.announced then
        svy.announced = true
        -- round 1 field lesson: it ran silently OFF and Aurora couldn't tell - announce loudly
        _log(string.format("PROSPECTOR ACTIVE: sampling %d spots out to %.0fm every %.0fs",
            8, M.prospect_ring or 90, M.prospect_every or 4.0))
    end
    pcall(function()
        local up, d = _pupos(), _delta()
        if not (up and d) then return end
        local prx, pry, prz = up.x - d.x, up.y - d.y, up.z - d.z
        -- ⭐ RING SAMPLING (Aurora 08-05: "running around defeats the purpose"): each tick tests
        -- a rotating fan of spots out to prospect_ring around the player - a griffin lap sweeps
        -- a whole corridor instead of the single point underfoot. The rotation angle advances by
        -- the golden angle so successive ticks fill different bearings, never the same spokes.
        svy.rot = ((svy.rot or 0) + 2.39996) % (2 * math.pi)
        local ringR = M.prospect_ring or 90
        local samples = { { 0, 0 } }
        for s = 0, 6 do
            local a = svy.rot + s * (2 * math.pi / 7)
            local r = (s % 2 == 0) and ringR or (ringR * 0.55)
            samples[#samples + 1] = { math.cos(a) * r, math.sin(a) * r }
        end
        local gap = M.prospect_gap or 120
        local gr = M.prospect_gim_r or 30
        -- fetch the gimmick list ONCE per tick; only consulted for samples that pass flatness
        local comps, ncomp = nil, 0
        local marked = 0
        for _, off in ipairs(samples) do
            if marked >= 2 then break end
            local rx, rz = prx + off[1], prz + off[2]
            local ux, uz = rx + d.x, rz + d.z
            -- spacing vs existing candidates AND plots, at the SAMPLE point
            local clear = true
            for _, sc in ipairs(_svy()) do
                local dx, dz = (sc.ux or 0) - ux, (sc.uz or 0) - uz
                if dx * dx + dz * dz < gap * gap then clear = false; break end
            end
            if clear then
                for _, pr in ipairs(_G.IrisHomesteadPlots and _G.IrisHomesteadPlots.list() or {}) do
                    local dx, dz = (pr.ux or 0) - ux, (pr.uz or 0) - uz
                    if dx * dx + dz * dz < gap * gap then clear = false; break end
                end
            end
            if clear then
                local gy = _ground_top(rx, pry, rz)
                if gy then
                    local spread, fails, roof = _survey_score(rx, gy + 1.0, rz)
                    if spread and spread < 0.9 and fails == 0 and not roof then
                        if not comps then
                            pcall(function()
                                local smgr = sdk.get_native_singleton("via.SceneManager")
                                local scene = smgr and sdk.call_native_func(smgr, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
                                comps = scene and scene:call("findComponents(System.Type)", sdk.typeof("app.GimmickBase"))
                                ncomp = comps and (comps.get_size and comps:get_size() or #comps) or 0
                            end)
                        end
                        local blocked = false
                        for i = 0, ncomp - 1 do
                            pcall(function()
                                local g = comps.get_element and comps:get_element(i) or comps[i]
                                local go = g and g:call("get_GameObject")
                                local nm = go and tostring(go:call("get_Name")) or ""
                                if nm:find("^Iris") then return end   -- our own spawns don't count
                                -- ⭐ GATHER NODES DON'T DISQUALIFY (08-05): gm82 pick-bushes
                                -- carpet every pretty meadow - a "no gimmicks" rule that counts
                                -- them rejects exactly the ground Aurora wants. A herb bush is
                                -- scenery to a homestead; camps/chests/quest props still block.
                                if nm:lower():find("^gm82") then return end
                                local p = go and go:call("get_Transform"):call("get_Position")
                                if p then
                                    local dx, dz = p.x - rx, p.z - rz
                                    if dx * dx + dz * dz < gr * gr then blocked = true end
                                end
                            end)
                            if blocked then break end
                        end
                        if not blocked then
                            local nm = _svy_near_name(ux, uz)
                            _svy()[#_svy() + 1] = { key = string.format("prospect_%d_%d", math.floor(ux), math.floor(uz)),
                                name = nm, ux = ux, uy = gy + d.y, uz = uz, status = "new" }
                            marked = marked + 1
                            _log(string.format("PROSPECTOR: flat empty ground marked - %s (spread %.2fm)", nm, spread))
                        end
                    end
                end
            end
        end
        if marked > 0 then _svy_save() end
    end)
end
local function _svy_warp(rec)
    local ok, err = pcall(function()
        local tm = sdk.get_managed_singleton("app.TimeManager")
        local tsm = sdk.get_managed_singleton("app.TimeSkipManager")
        local pos = ValueType.new(sdk.find_type_definition("via.Position"))
        pos.x = rec.ux; pos.y = (rec.uy or 0) + 0.6; pos.z = rec.uz
        tsm:call("requestPlayerWarp",
            tm:call("get_InGameHour"), tm:call("get_InGameMinute"), tm:call("get_InGameDay"),
            pos, _ptf():call("get_Rotation"), nil, true, true)
    end)
    _log("surveyor: warp to " .. tostring(rec.name) .. (ok and "" or (" FAILED " .. tostring(err))))
end
local function _survey_here()
    local up, d = _pupos(), _delta()
    if not (up and d) then return "no player position" end
    local spread, fails, roof = _survey_score(up.x - d.x, up.y - d.y, up.z - d.z)
    if not spread then return "NO ground readable - area not streamed in yet?" end
    local verdict
    if roof then verdict = "ROOFED - indoors or under an overhang"
    elseif fails > 0 then verdict = string.format("EDGE - %d/25 probes found no ground (cliff/water?)", fails)
    elseif spread < 0.9 then verdict = "GOOD - flat enough for a plot"
    else verdict = string.format("SLOPED - %.1fm height spread", spread) end
    return string.format("%s  (spread %.2fm over 14m, %d/25 misses%s)",
        verdict, spread, fails, roof and string.format(", roof at %.1fm", roof) or "")
end

-- ⭐⭐⭐ PLOT MAP MARKERS v3 (Aurora 08-05: "just port the whole riftspeak map marker"). This is
-- the guild_contracts mod's SHIPPED, POST-PATCH implementation ported whole (their pattern, our
-- code - never editing theirs), which carries three hard-won fixes my v2 re-derivation lacked:
--   1. addMapIconInfoList's 2nd arg is 3 now, not 0 (changed in a game update);
--   2. a NEW 6th arg exists post-patch - unknowable statically, so it's CAPTURED live from the
--      game's own addMapIconInfoList calls each map open (_arg8);
--   3. the slot index is a BOXED Int32 passed BY ADDRESS, and it must be a RESERVED slot at the
--      END of the render array (limit-1-k) - inferring "next free" from MapIconInfoList desyncs
--      from the fixed-size MapIcon render array when a waypoint pin exists, colliding slots.
-- Plus: get_Valid before touching the map object, onDestroy hook nils the cached ref (a stale
-- managed ref can hard-crash, not just error), and colour via boxed-uint set_Color + updateMapIcon.
-- Self-cleaning: the map rebuilds each open. IconType = the glyph (panel cycler hunts the signpost).
local pmk = { adds = 0, last = "(open the map to inject)", names = {} }
-- ⭐ MARKER LABELS (the DeedSign message-override pattern, our own proven code): each plot gets a
-- DETERMINISTIC guid (fixed prefix + index); the map resolves marker names through
-- via.gui.message.get(Guid), so a hook hands back the plot's name when OUR guid is fetched.
local function _plot_guid_str(k) return string.format("5a1a7e11-0000-4abc-9def-%012d", k) end
pcall(function()
    -- BOTH message lanes, exactly as IrisDeedSign learned the hard way ("the label never appeared
    -- through get(System.Guid) alone - it travels another lane"): every Guid-taking
    -- via.gui.message.get overload + app.MessageManager.getMessage(Guid).
    local function _pmk_pre(args)
        pcall(function()
            thread.get_hook_storage().g = sdk.to_valuetype(args[2], "System.Guid"):ToString()
        end)
    end
    local function _pmk_post(retval)
        local out = retval
        pcall(function()
            local g = thread.get_hook_storage().g
            if not g then return end
            local nm = pmk.names[g] or pmk.names[tostring(g):lower()] or pmk.names[tostring(g):upper()]
            if nm then
                out = sdk.to_ptr(sdk.create_managed_string(nm))
                if not pmk.label_hit then pmk.label_hit = true; _log("marker label: guid matched -> '" .. nm .. "'") end
            end
        end)
        return out
    end
    local hooked = 0
    local td = sdk.find_type_definition("via.gui.message")
    if td then
        for _, m in ipairs(td:get_methods()) do
            pcall(function()
                if m:get_name() == "get" then
                    local ps = m:get_param_types()
                    if ps and #ps >= 1 and ps[1]:get_full_name() == "System.Guid" then
                        sdk.hook(m, _pmk_pre, _pmk_post)
                        hooked = hooked + 1
                    end
                end
            end)
        end
    end
    pcall(function()
        local mm = sdk.find_type_definition("app.MessageManager"):get_method("getMessage(System.Guid)")
        if mm then sdk.hook(mm, _pmk_pre, _pmk_post); hooked = hooked + 1 end
    end)
    _log("marker labels armed on " .. hooked .. " message surface(s)")
end)
pcall(function()
    local ui_t            = sdk.find_type_definition("app.ui040205")
    local m_setup         = ui_t and ui_t:get_method("setupMapIcon")
    local m_addIcon       = ui_t and ui_t:get_method("addMapIconInfoList")
    local m_destr         = ui_t and ui_t:get_method("onDestroy")
    local mii_t           = sdk.find_type_definition("app.GuiManager.MapIconInfo")
    local int_t           = sdk.find_type_definition("System.Int32")
    local int_off         = int_t and int_t:get_field("m_value"):get_offset_from_base()
    local uint_t          = sdk.find_type_definition("System.UInt32")
    local uint_off        = uint_t and uint_t:get_field("m_value"):get_offset_from_base()
    local guid_parse      = sdk.find_type_definition("System.Guid"):get_method("Parse")
    if not (m_setup and m_addIcon and mii_t and int_off and guid_parse) then
        _log("plot markers v3: map API not found (post-patch rename?)"); return
    end
    -- ⭐ CUSTOM SIGN ICON PROBE (08-05, Aurora's plot-sign art). We already own each marker's
    -- Icon control (set_Color proves it), so try repointing its TEXTURE at the loose
    -- iris_plotsign_icon.tex. Unproven: first run DUMPS the control's real type + every
    -- texture/path/uv/sprite-ish method to the farming log, then tries the obvious setters.
    -- Whatever the log names is what the next round hard-codes.
    -- v2 (08-05): round 1 learned the Icon is app.GUIBase.MapIconRef - a REF wrapper, not the
    -- texture control (its own type declares no tex methods; set_Texture resolved somewhere up
    -- the base chain and visibly did nothing - the glyph stayed the house). Two suspects, both
    -- addressed here: (a) the REAL via.gui control hides in a FIELD of the ref - so dump the
    -- full type chain once and AUTO-DESCEND into managed fields hunting anything with
    -- set_Texture/TextureSet; (b) the game re-stamps the icon per frame - so every applied
    -- target registers in sign.live and the map's own update hook RE-ASSERTS it (the law that
    -- fixed the tooltip). sign.live clears on each map open (the refs die with the rebuild).
    local sign = { probed = false, live = {} }
    local function _type_has(obj, mname)
        local ok, found = pcall(function()
            local td = obj:get_type_definition()
            while td do
                if td:get_method(mname) then return true end
                td = td:get_parent_type()
            end
            return false
        end)
        return ok and found
    end
    -- v3 (08-05, round 2 verdict: house GONE but blank): the dump named the anatomy -
    -- MapIconRef.Tex + .TexBG are via.gui.Texture controls, and v2 stamped BOTH (TexBG is the
    -- backdrop - leave it alone). Blank = the ATLAS REGION: the control still samples the house
    -- glyph's little window into our 1024 texture, which is transparent corner. So: setTexture
    -- on Tex ONLY, then find + reset the region to cover the whole texture. via.gui.Texture's
    -- real region method names are unknown - enumerate anything region/uv/rect/size-ish ONCE,
    -- log it, and try the obvious setters.
    local function _sign_apply(ic)
        if not sign.holder then return end
        pcall(function()
            local tex = nil
            pcall(function() tex = ic.Tex end)
            if not tex then return end
            tex:call("setTexture", sign.holder)
            if not sign.tex_dumped then
                sign.tex_dumped = true
                pcall(function()
                    local td = tex:get_type_definition()
                    local names = {}
                    while td do
                        for _, m in ipairs(td:get_methods()) do
                            local n = m:get_name():lower()
                            if n:find("region") or n:find("uv") or n:find("rect") or n:find("size") or n:find("clip") then
                                names[#names + 1] = m:get_name()
                            end
                        end
                        td = td:get_parent_type()
                    end
                    _log("sign tex methods (region-ish): " .. table.concat(names, " "))
                end)
                pcall(function()
                    local rs = tex:call("get_RegionSize")
                    local rp = tex:call("get_RegionPos")
                    _log(string.format("sign region now: pos=%s,%s size=%s,%s",
                        tostring(rp and rp.x), tostring(rp and rp.y),
                        tostring(rs and (rs.w or rs.x)), tostring(rs and (rs.h or rs.y))))
                end)
            end
            -- v4 (08-05): the region dump named the REAL via.gui.Texture window API - no
            -- RegionPos/Size (both nil'd); the controls are Rect(L/T/W/H) in texture pixels,
            -- UV(U/V/W/H) normalised, UVType, and a UVSequence/PatternNo atlas-cell selector.
            -- The faint amber smudge on Aurora's map = our sign sampled through the old
            -- stamp-sized cell window. Open every window to the full 1024 texture and log the
            -- before-values once so the next refinement is informed.
            if not sign.uv_logged then
                sign.uv_logged = true
                pcall(function()
                    _log(string.format("sign UV before: type=%s seq=%s pat=%s rect=%s,%s %sx%s uv=%s,%s %sx%s",
                        tostring(tex:call("get_UVType")), tostring(tex:call("get_UVSequenceNo")),
                        tostring(tex:call("get_UVPatternNo")),
                        tostring(tex:call("get_RectL")), tostring(tex:call("get_RectT")),
                        tostring(tex:call("get_RectW")), tostring(tex:call("get_RectH")),
                        tostring(tex:call("get_UVU")), tostring(tex:call("get_UVV")),
                        tostring(tex:call("get_UVW")), tostring(tex:call("get_UVH"))))
                end)
            end
            pcall(function() tex:call("set_UVType", 0) end)
            pcall(function() tex:call("set_RectL", 0) end)
            pcall(function() tex:call("set_RectT", 0) end)
            pcall(function() tex:call("set_RectW", 1024) end)
            pcall(function() tex:call("set_RectH", 1024) end)
            pcall(function() tex:call("set_UVU", 0.0) end)
            pcall(function() tex:call("set_UVV", 0.0) end)
            pcall(function() tex:call("set_UVW", 1.0) end)
            pcall(function() tex:call("set_UVH", 1.0) end)
        end)
    end
    local function _plot_sign_icon(ui_icon)
        local ic = ui_icon.Icon
        if not ic then return end
        if not sign.probed then
            sign.probed = true
            pcall(function()
                sign.res = sdk.create_resource("via.render.TextureResource", "iris/icons/iris_plotsign_icon.tex")
                if sign.res then sign.res:add_ref() end
                sign.holder = sign.res and sign.res:create_holder("via.render.TextureResourceHolder")
                if sign.holder then sign.holder:add_ref() end
                _log("sign probe2: res=" .. tostring(sign.res ~= nil) .. " holder=" .. tostring(sign.holder ~= nil))
            end)
            -- one-time deep dump: the WHOLE type chain, fields AND methods, so next round can
            -- hard-code whatever this names
            pcall(function()
                local td = ic:get_type_definition()
                while td do
                    local fl, ml = {}, {}
                    for _, f in ipairs(td:get_fields()) do fl[#fl + 1] = f:get_name() end
                    for _, m in ipairs(td:get_methods()) do ml[#ml + 1] = m:get_name() end
                    _log("sign dump [" .. td:get_full_name() .. "] fields: " .. table.concat(fl, " "))
                    _log("sign dump [" .. td:get_full_name() .. "] methods: " .. table.concat(ml, " "))
                    td = td:get_parent_type()
                end
            end)
            -- v3: the descend answered (Tex + TexBG, via.gui.Texture, setTexture) - hard-coded
            -- in _sign_apply now, TexBG deliberately untouched
        end
        if not sign.holder then return end
        _sign_apply(ic)
        sign.live[#sign.live + 1] = ic     -- the update hook re-asserts these every frame
    end
    local ui_map, arg8 = nil, nil
    sdk.hook(m_addIcon, function(args) arg8 = args[8] end, nil)     -- the post-patch 6th arg, fresh each open
    sdk.hook(m_setup,
        function(args) ui_map = sdk.to_managed_object(args[2]); sign.live = {} end,   -- refs die with each rebuild
        function(retval)
            pcall(function()
                local this = ui_map
                if not (this and M.enabled and M.plot_markers ~= false and arg8) then return end
                local v_ok, v = pcall(this.get_Valid, this)
                if not v_ok or not v then return end
                local ok_il, icon_limit = pcall(function() return this.MapIcon:get_Length() end)
                if not ok_il or not icon_limit then return end
                local k = 0
                for _, pr in ipairs(_G.IrisHomesteadPlots and _G.IrisHomesteadPlots.list() or {}) do
                    k = k + 1
                    local slot = icon_limit - k          -- reserved from the END, one per plot
                    if slot < 1 then break end
                    local vec3 = Vector3f.new(pr.ux or 0, pr.uy or 0, pr.uz or 0)
                    if this:isInDispRange(vec3) then
                        local idx_obj = int_t:create_instance():add_ref()
                        idx_obj:write_dword(int_off, slot)
                        local info = mii_t:create_instance():add_ref()
                        info.IsEnable = true; info.IsNavi = false; info.IconId = M.plot_icon_id or 0
                        info.SortNo = 0; info.IconType = M.plot_icon_type or 67; info.Timing = 0
                        info.Pos = vec3; info.Area = -1; info.LocalArea = 0
                        info.IsDispAllArea = true
                        -- position->label point for the TOOLTIP hook below (the mechanism that
                    -- actually renders; the guid lane stays as belt-and-braces)
                    pmk.points = pmk.points or {}
                    pmk.points[k] = { x = pr.ux or 0, z = pr.uz or 0, label = pr.name or "Homestead Plot" }
                    local gs = _plot_guid_str(k)
                    pmk.names[gs:upper()] = pr.name or "Homestead Plot"
                    pmk.names[gs:lower()] = pr.name or "Homestead Plot"
                    local NAME_GUID = guid_parse(nil, gs)
                    local ui_icon = this:addMapIconInfoList(info, 3,
                            idx_obj:get_address() + int_off, -1, NAME_GUID, arg8)
                        -- for-sale plots wear Aurora's SIGN ART in its own natural colours
                        -- (the amber multiply oranged the parchment - Aurora 08-05); owned
                        -- plots keep the amber house glyph
                        local use_sign = M.plot_icon_custom and pr.owned == false
                        if ui_icon and uint_t then
                            local cv = use_sign and 0xFFFFFFFF or (M.plot_icon_color or 0)
                            if cv ~= 0 then
                                local col = uint_t:create_instance():add_ref()
                                col:write_dword(uint_off, cv)
                                pcall(function() ui_icon.Icon:set_Color(col:get_address() + uint_off) end)
                            end
                        end
                        if ui_icon and use_sign then
                            pcall(function() _plot_sign_icon(ui_icon) end)
                        end
                        if ui_icon then
                            pmk.adds = pmk.adds + 1
                            pmk.last = "injected (type " .. tostring(M.plot_icon_type or 67) .. ", slot " .. slot .. ")"
                        else
                            pmk.last = "addMapIconInfoList returned nil"
                        end
                    else
                        pmk.last = "plot out of display range this open"
                    end
                end
                -- ⭐⭐ SURVEY CANDIDATES on the same marker lane (green, own glyph). Same reserved-
                -- slot ladder (k keeps counting down from the end), same tooltip point registry.
                if M.survey_markers ~= false then
                    for _, sc in ipairs(_svy()) do
                        if sc.status == "new" then
                            k = k + 1
                            local slot = icon_limit - k
                            if slot < 1 then break end
                            local vec3 = Vector3f.new(sc.ux or 0, sc.uy or 0, sc.uz or 0)
                            if this:isInDispRange(vec3) then
                                local idx_obj = int_t:create_instance():add_ref()
                                idx_obj:write_dword(int_off, slot)
                                local info = mii_t:create_instance():add_ref()
                                info.IsEnable = true; info.IsNavi = false; info.IconId = 0
                                info.SortNo = 0; info.IconType = M.survey_icon_type or 27; info.Timing = 0
                                info.Pos = vec3; info.Area = -1; info.LocalArea = 0
                                info.IsDispAllArea = true
                                pmk.points = pmk.points or {}
                                pmk.points[k] = { x = sc.ux or 0, z = sc.uz or 0, label = "Survey: " .. tostring(sc.name) }
                                local gs = _plot_guid_str(k)
                                pmk.names[gs:upper()] = "Survey: " .. tostring(sc.name)
                                pmk.names[gs:lower()] = "Survey: " .. tostring(sc.name)
                                local ui_icon = this:addMapIconInfoList(info, 3,
                                    idx_obj:get_address() + int_off, -1, guid_parse(nil, gs), arg8)
                                if ui_icon and uint_t then
                                    local col = uint_t:create_instance():add_ref()
                                    col:write_dword(uint_off, M.survey_icon_color or 0xFF00FF00)  -- ABGR green
                                    pcall(function() ui_icon.Icon:set_Color(col:get_address() + uint_off) end)
                                end
                                if ui_icon then pmk.adds = pmk.adds + 1 end
                            end
                        end
                    end
                end
                -- ⭐ THE HOVER NAME IS PER-TYPE, NOT PER-MARKER (08-05, the blank label with both
                -- message lanes hooked and the guid never fetched): the map resolves names through
                -- its IconMsgDict (MapIconType -> name guid), and type 22 has NO entry - blank by
                -- the game's own bookkeeping. So REGISTER one: dict[type] = our guid, and the
                -- already-armed message hooks translate that guid to the plot's name on hover.
                pcall(function()
                    local ty = M.plot_icon_type or 22
                    local dict = this:get_field("IconMsgDict")
                    if dict then
                        local gs = _plot_guid_str(1)
                        local plots = _G.IrisHomesteadPlots and _G.IrisHomesteadPlots.list() or {}
                        local label = (#plots == 1 and plots[1].name) or "Homestead"
                        pmk.names[gs] = label
                        pmk.names[gs:upper()] = label
                        -- ⛔ OVERWRITE, don't defer (08-05: ContainsKey(22) was TRUE - the game
                        -- ships an entry for type 22 whose message renders EMPTY, and the polite
                        -- add-if-absent skipped it silently, label stayed blank). Capture what was
                        -- there for the log, then take the slot.
                        local prev = "none"
                        pcall(function()
                            local pg = dict:call("get_Item", ty)
                            if pg then prev = tostring(sdk.to_valuetype and pg or pg) end
                        end)
                        local g = guid_parse(nil, gs)
                        local okset = pcall(function() dict:call("set_Item", ty, g) end)
                        if not okset then okset = pcall(function() dict:call("Add", ty, g) end) end
                        if not pmk.dict_logged then
                            pmk.dict_logged = true
                            _log("marker label: IconMsgDict[" .. ty .. "] " .. (okset and "OVERWRITTEN" or "WRITE FAILED")
                                .. " (was " .. prev .. ") -> '" .. label .. "'")
                        end
                    end
                end)
                pcall(function() this:updateMapIcon() end)
            end)
            return retval
        end)
    -- ⛔ sign.live MUST die with the map (08-05 crash while walking, map closed: the update hook
    -- can still fire and a STALE MapIconRef is a hard crash, not an error - this block's own law,
    -- re-learned). Cleared on destroy AND on open.
    if m_destr then sdk.hook(m_destr, function() end, function(r) ui_map = nil; sign.live = {}; return r end) end
    -- ⭐⭐ THE TOOLTIP, from RiftSpeak's SHIPPED saved-places feature (llm_freetalk.lua), which hit
    -- OUR EXACT wall and wrote it down: "the hover tooltip resolves its text through a path the
    -- message hooks don't always catch (observed: blank black tooltip)". Their cure, ported whole:
    -- on setupIconName AND on every map update (a one-shot write gets stomped - "SET but
    -- invisible" - the re-assert-wins law), take this.SelectedIcon, read its Pos (three fallback
    -- shapes), match OUR markers by position (~4m), and write the label into this.TxtName via
    -- set_Message - NOT set_Text, which "exists but paints nothing" (their live probe).
    local function _tooltip_fix(this)
        if not (this and pmk.points and M.plot_markers ~= false) then return end
        -- the sign texture rides the same every-frame re-assert (a one-shot write gets stomped);
        -- only while the map object reports Valid - stale refs hard-crash
        if M.plot_icon_custom and #sign.live > 0 then
            local v_ok, v = pcall(function() return this:get_Valid() end)
            if v_ok and v then
                for _, ic in ipairs(sign.live) do pcall(function() _sign_apply(ic) end) end
            else
                sign.live = {}
            end
        end
        pcall(function()
            local sel = this.SelectedIcon
            if not sel then return end
            local pos = nil
            pcall(function() pos = sel.Pos end)
            if not (pos and pos.x) then pcall(function() pos = sel:call("get_Pos") end) end
            if not (pos and pos.x) then pcall(function() local inf = sel.Info; pos = inf and inf.Pos end) end
            if not (pos and pos.x) then return end
            local best, bd
            for _, pnt in pairs(pmk.points) do
                local dx, dz = pnt.x - pos.x, pnt.z - pos.z
                local d = dx * dx + dz * dz
                if d < 16.0 and (not bd or d < bd) then best, bd = pnt.label, d end
            end
            if not best then return end
            local txt = this.TxtName
            if txt then
                if not pcall(function() txt:call("set_Message", best) end) then
                    pcall(function() txt:call("set_Text", best) end)
                end
                if not pmk.tip_logged then pmk.tip_logged = true; _log("marker tooltip SET: '" .. tostring(best) .. "'") end
            end
        end)
    end
    pcall(function()
        if ui_t:get_method("setupIconName") then
            sdk.hook(ui_t:get_method("setupIconName"),
                function(args) ui_map = sdk.to_managed_object(args[2]) end,
                function(retval) _tooltip_fix(ui_map); return retval end)
        end
    end)
    pcall(function()
        if ui_t:get_method("update") then
            sdk.hook(ui_t:get_method("update"),
                function(args) ui_map = sdk.to_managed_object(args[2]) end,
                function(retval) _tooltip_fix(ui_map); return retval end)
        end
    end)
    _log("plot markers v3: guild-contracts-pattern hooks armed (+ RiftSpeak tooltip fix)")
end)

-- ⭐ PLOT-NAME BANNER (Aurora 08-05: "have the plot names show up like when you enter an area,
-- e.g. 'Vernworth' in the bottom left"). Drawn with OUR renderer (IrisFont), never the game's GUI
-- - the key-guide crashes taught that lesson three times. Fades in, holds, fades out; re-arms
-- only after you leave the plot, exactly like the native area banners.
local pbn = { at = 0, last = nil, shown_at = nil, txt = nil }
re.on_frame(function()
    if not M.enabled or M.plot_banner == false then return end
    pcall(function()
        if os.clock() - pbn.at > 2.0 then
            pbn.at = os.clock()
            local plot, dist = _nearest_plot()
            local here = (plot and (dist or 999) <= (M.plot_range or 30.0)) and plot.name or nil
            if here and here ~= pbn.last then
                pbn.txt, pbn.shown_at = here, os.clock()
            end
            pbn.last = here   -- leaving the plot re-arms the banner for the next visit
        end
        if not (pbn.txt and pbn.shown_at) then return end
        local age = os.clock() - pbn.shown_at
        local FADE_IN, HOLD, FADE_OUT = 0.5, 3.2, 0.9
        if age > FADE_IN + HOLD + FADE_OUT then pbn.txt = nil; return end
        local a = 1.0
        if age < FADE_IN then a = age / FADE_IN
        elseif age > FADE_IN + HOLD then a = 1.0 - (age - FADE_IN - HOLD) / FADE_OUT end
        local sh = 1080
        pcall(function() local ok, _, h = pcall(d2d.surface_size); if ok and h and h > 0 then sh = h end end)
        local alpha = math.floor(255 * math.max(0, math.min(1, a)))
        local F = _G.IrisFont
        local col = alpha * 0x1000000 + 0xEAD8B0          -- the furnish screen's parchment tone
        if not (F and F.text and F.text(pbn.txt, 84, sh - 176, col, 30)) then
            draw.text(pbn.txt, 84, sh - 176, alpha * 0x1000000 + 0xB0D8EA)   -- ABGR fallback
        end
    end)
end)

-- ⭐ COOKPOT PROMPT (Aurora 08-05: "like the seeds it needs a context prompt label above it").
-- Same world-space style as the bed prompt; the state check is throttled, the draw is per-frame.
local ckp = { at = 0, near = false }
re.on_frame(function()
    if not M.enabled or dlg.open or _hud_hidden() or not (M.bed_prompt ~= false) then return end
    -- ⛔ settle gate deliberately NOT consulted here - see the ring's note (08-08). A label
    -- cannot hang a load, and gating it here is what blanked the HUD on every menu.
    pcall(function()
        -- The expensive object search is throttled; this cheap position/facing validation is
        -- not. Withdraw both the prompt and B action on the first frame after leaving it.
        if ckp.near and not cookpot.live_near() then
            ckp.near, cookpot.near_now = false, false
            if _G.IrisPrompt then _G.IrisPrompt.clear("cookpot") end
        end
        if os.clock() - ckp.at > 0.3 then
            ckp.at = os.clock()
            local b = _nearest_bed()
            ckp.near = (b == nil) and _cookpot_near() or false   -- the bed prompt wins when both apply
            cookpot.near_now = ckp.near                          -- published for the jump gate
        end
        if not (ckp.near and cookpot.pos) then return end
        local d = _delta(); if not d then return end
        if _G.IrisPrompt then
            local cd = 1e9
            pcall(function()
                local up = _pupos()
                if up and cookpot.pos then
                    local dx, dz = cookpot.pos.x - up.x, cookpot.pos.z - up.z
                    cd = math.sqrt(dx * dx + dz * dz)
                end
            end)
            local cp = Vector3f.new(cookpot.pos.x - d.x, cookpot.pos.y - d.y + 1.1,
                                    cookpot.pos.z - d.z)
            _G.IrisPrompt.set("cookpot", "Cook", 15, cd, cp, cookpot.go)
        end
        -- No legacy gold label fallback: when ui020701 withdraws, the action is gone too.
    end)
end)

-- ── ANIMAL PROMPT (Aurora 08-06: label parity with beds/cookpot for the chicken/ox). One
-- throttled scan (0.3s) finds the nearest matched milk/egg animal and publishes ani.near_now
-- for its three consumers: this world-space label, the jump gate (A must milk, not hop), and
-- the grab shield (E must milk, not seize). Positions from _scan_animals are RENDER space -
-- no delta subtraction (unlike the cookpot's stored-universal pos above).
local anivis = { at = 0 }
re.on_frame(function()
    if not M.enabled or dlg.open or _hud_hidden() then return end
    -- ⛔ settle gate deliberately NOT consulted here - see the ring's note (08-08). A label
    -- cannot hang a load, and gating it here is what blanked the HUD on every menu.
    pcall(function()
        if os.clock() - anivis.at > 0.3 then
            anivis.at = os.clock()
            anivis.near = nil
            if M.animal_produce ~= false then
                for _, a in ipairs(_scan_animals(math.max(tonumber(M.animal_range) or 7.0, 7.0))) do
                    local kind = (_match_tokens(a.name, M.milk_ids) and "Milk")
                              or (_match_tokens(a.name, M.egg_ids) and "Collect egg") or nil
                    -- 08-11: dead or wild animals get no label (and thus no jump gate /
                    -- grab shield) -- same gates as the grant, see _ani_eligible.
                    if kind and not _ani_eligible(a) then kind = nil end
                    -- 08-12 (Aurora: a "Milk" prompt on the BULL that does nothing): the
                    -- label wears the same gender gate as the grant -- he has none to give
                    if kind == "Milk" then
                        local g9 = nil
                        pcall(function()
                            local b9 = rawget(_G, "IrisGriffinBridge")
                            g9 = b9 and b9.body_gender and b9.body_gender(a.go:get_address()) or nil
                        end)
                        if g9 == nil then
                            pcall(function()
                                local sp9 = rawget(_G, "IrisSpecies")
                                g9 = sp9 and sp9.gender and sp9.gender(a.go) or nil
                            end)
                        end
                        if g9 == "male" then kind = nil end
                    end
                    if kind then
                        -- same day-key as the grant, so label and ledger can never disagree
                        local done = false
                        pcall(function()
                            local d, today = _delta(), _today()
                            if d and today then
                                local key = string.format("%s@%d,%d", a.name,
                                    math.floor((a.pos.x + d.x) / 5), math.floor((a.pos.z + d.z) / 5))
                                done = (_ani_days()[key] == today)
                            end
                        end)
                        anivis.near = { kind = kind, pos = a.pos, go = a.go,
                                        dist = a.dist, done = done }
                        break
                    end
                end
            end
            ani.near_now = anivis.near ~= nil and anivis.near.done ~= true
        end
        local nr = anivis.near
        if not (nr and M.bed_prompt ~= false) then return end
        if nr.done then
            if _G.IrisPrompt then _G.IrisPrompt.clear("farm_animal") end
            return -- no action remains today, so no interaction-shaped label
        else
            if _G.IrisPrompt then
                local ap = Vector3f.new(nr.pos.x, nr.pos.y + 1.5, nr.pos.z)
                _G.IrisPrompt.set("farm_animal", nr.kind, 18, nr.dist or 1e9, ap, nr.go)
            end
        end
        -- Native ui020701 is the sole Milk / Collect egg action prompt.
    end)
end)

-- ── on-screen text: OFF by default (Aurora 07-25: "remove the message in the top left").
-- The plot speaks for itself - a dry crop visibly droops and shrinks, a ripe one stands full
-- height. M.hud = true brings back a single status line when you're stood at a bed, for testing.
re.on_frame(function()
    if not (M.enabled and M.hud) or dlg.open or _hud_hidden() then return end
    pcall(function()
        local F = _G.IrisFont; if not F then return end
        local b = _nearest_bed(); if not b then return end
        local st = b.crop and _bed_state(b)
        if not st then F.text("bare soil", 24, 52, 0xCCBFE8B0, 18); return end
        F.text(string.format("%s  %d/%d days%s", st.crop.name, b.grown or 0, st.crop.days,
            st.ripe and "  RIPE" or (b.watered_day == _today() and "  watered" or "  dry")),
            24, 52, 0xCCBFE8B0, 18)
        if st.wilting then
            local left = math.max(0, (M.die_after or 4) - (st.dry or 0))
            F.text(string.format("WILTING - %d day(s) of drought left", left), 24, 76, 0xFFE29A6A, 18)
        end
    end)
end)

-- ── NATIVE-PICK GATE: a spawned gm82 gather node carries its own "pick" interact. Left alone
--    that lets you harvest a sprout instantly and skip the whole farm. Hook each crop type's
--    onStartInteract and SKIP it while the crop isn't ripe (our harvest owns the ripe case). ──
local gate = { armed = 0 }
local function _arm_pick_gate()
    for _, c in ipairs(M.crops) do
        pcall(function()
            -- ⛔ capital G: the class is app.Gm82_020, not app.gm82_020 (the gather probe printed
            -- the real name; the lowercase lookup silently armed NOTHING - "armed on 0 crop types")
            local td = sdk.find_type_definition("app.Gm" .. c.gid:sub(3))
            local m = td and td:get_method("onStartInteract(System.UInt32, app.Character)")
            if not m then return end
            sdk.hook(m, function(args)
                -- v2 (08-05): match THE INTERACTED GIMMICK, not the player's nearest bed - the
                -- old check could block a ripe pepper because an UNRIPE bed stood closer to the
                -- player (Aurora: no native button on her ripe veg). Also: the pawn toggle - by
                -- her design call pawns MAY loot the plants, but players who want the visual of
                -- a full garden can turn it off.
                local block = false
                pcall(function()
                    local this = sdk.to_managed_object(args[2])
                    local go = this and this:call("get_GameObject")
                    if not go then return end
                    local addr = go:get_address()
                    for _, b in ipairs(beds) do
                        if b.live and b.live:get_address() == addr then
                            local st = b.crop and _bed_state(b)
                            if not (st and st.ripe) then block = true; return end
                            if M.pawn_gather == false then
                                -- signature (System.UInt32, app.Character): args[3] is the UINT -
                                -- the character is args[4], and only args[4] (to_managed_object on
                                -- a raw int is undefined behaviour, never "try both")
                                local ch = sdk.to_managed_object(args[4])
                                local pl
                                pcall(function() pl = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer") end)
                                if ch and pl and ch:get_address() ~= pl:get_address() then block = true end
                            end
                            return
                        end
                    end
                end)
                if block then return sdk.PreHookResult.SKIP_ORIGINAL end
            end, function(r) return r end)
            gate.armed = gate.armed + 1
        end)
    end
    _log("native-pick gate armed on " .. gate.armed .. " crop type(s)")
end
_arm_pick_gate()

-- ── ⭐ RAIN WATERS THE FARM (Aurora 08-08: "if it's raining when you're in the vicinity of
--    farmland, can they be automatically watered?") ────────────────────────────────────────
-- Stardew's own rule, and it needs no new state: a rainy day just sets `watered_day`, exactly
-- as do_water does, minus the watering-can emote (nobody is pouring anything).
--
-- ⛔ NOBODY IN THIS INSTALL EVER *READS* THE WEATHER. RiftSpeak's world_tools drives it
--    (`changeWeatherLook(n, 0)`, world_tools.lua:105) but only ever WRITES, so the current-look
--    getter is genuinely unknown - and I will not hardcode a guessed method name. That is the
--    exact mistake that armed the pick gate on 0 crops for 554 log lines.
-- ⇒ SELF-RESOLVING + LOUD: the first tick dumps every numeric field and every zero-arg numeric
--    method on app.WeatherManager, then latches the first candidate returning a number. While
--    it is actually raining, read IRIS/farming_log.txt - the look id that CHANGED is sitting
--    there; put it in `rain_looks`. Until then this does nothing, which is the right failure.
-- ⭐ RiftSpeak maps its [WEATHER: storm] tag to looks 4 and 5, so those are the default guess.
local rain = { at = 0, acc = nil, dumped = false, said = 0, last = nil }

local function _weather_look()
    local wm = nil
    pcall(function() wm = sdk.get_managed_singleton("app.WeatherManager") end)
    if not wm then return nil end

    if not rain.dumped then
        rain.dumped = true
        pcall(function()
            local td = wm:get_type_definition()
            local fs, ms = {}, {}
            for _, f in ipairs(td:get_fields() or {}) do
                pcall(function()
                    local v = wm:get_field(f:get_name())
                    if type(v) == "number" then fs[#fs + 1] = f:get_name() .. "=" .. tostring(v) end
                end)
            end
            for _, m in ipairs(td:get_methods() or {}) do
                pcall(function()
                    local nm = m:get_name()
                    if #(m:get_param_types() or {}) == 0 and nm:sub(1, 3) ~= "set" then
                        local v = wm:call(nm)
                        if type(v) == "number" then ms[#ms + 1] = nm .. "()=" .. tostring(v) end
                    end
                end)
            end
            _log("WEATHER PROBE numeric fields: " .. table.concat(fs, ", "))
            _log("WEATHER PROBE numeric zero-arg methods: " .. table.concat(ms, ", "))
            _log("WEATHER PROBE: whichever of these CHANGES when rain starts is the look id.")
        end)
    end

    if rain.acc == nil then
        -- ⛔⛔ ORDER MATTERS, AND v1 GOT IT WRONG (field log 23:11:02). The probe dumped
        --   `_NowWeatherEnum=4` / `get_NowWeatherEnum()=4` alongside `getNowWeather()=0`, and
        --   v1 listed getNowWeather FIRST - so the resolver latched a name that EXISTS and
        --   RETURNS A NUMBER but is not the current weather, and reported look 0 in the rain.
        -- ⭐ THE LAW, sharpened: "never fall back silently" is not enough. A candidate that
        --   resolves and returns a plausible value can still be the WRONG one. Prefer the most
        --   specifically-named accessor, and log the whole set so the mapping is checkable.
        local cands = {
            { "m", "get_NowWeatherEnum" }, { "f", "_NowWeatherEnum" },
            { "m", "getNowWeatherInside" },
            { "m", "getNowWeather" }, { "m", "getWeather" }, { "m", "getNowWeatherLook" },
            { "f", "_NowWeather" },   { "f", "_Weather" },   { "f", "_WeatherLook" },
        }
        for _, c in ipairs(cands) do
            local v = nil
            pcall(function() v = (c[1] == "m") and wm:call(c[2]) or wm:get_field(c[2]) end)
            if type(v) == "number" then
                rain.acc = c
                _log("weather accessor resolved: " .. c[2] .. " -> " .. tostring(v))
                break
            end
        end
        -- ⛔ never fall through silently on a name that doesn't exist (the _pad_bit law)
        if rain.acc == nil then
            rain.acc = false
            _log("weather: NO accessor resolved - rain watering is INERT. Read the probe dump above.")
        end
    end
    if rain.acc == false then return nil end

    local v = nil
    pcall(function() v = (rain.acc[1] == "m") and wm:call(rain.acc[2]) or wm:get_field(rain.acc[2]) end)
    return type(v) == "number" and v or nil
end

local function _rain_tick()
    if M.rain_water == false then return end
    local now = os.clock()
    if now - rain.at < 5.0 then return end
    rain.at = now
    if _game_paused() or dlg.open then return end

    local look = _weather_look()
    if look == nil then return end
    if look ~= rain.last then
        rain.last = look
        -- ⭐ snapshot the WHOLE weather set on every change, not just the one we act on. If 4
        -- turns out not to be rain, the next transition names the right value with no extra
        -- round trip - which is what the first version cost us.
        local snap = {}
        pcall(function()
            local wm = sdk.get_managed_singleton("app.WeatherManager")
            for _, c in ipairs({ { "m", "get_NowWeatherEnum" }, { "f", "_BeforeWeather" },
                                 { "m", "getNowWeatherInside" }, { "m", "getNowWeather" },
                                 { "m", "getNowArea" } }) do
                local v = nil
                pcall(function() v = (c[1] == "m") and wm:call(c[2]) or wm:get_field(c[2]) end)
                snap[#snap + 1] = c[2] .. "=" .. tostring(v)
            end
        end)
        _log("weather is now " .. tostring(look)
             .. ((M.rain_looks or {})[look] and "  (RAIN - the farm drinks)" or "")
             .. "  [" .. table.concat(snap, ", ") .. "]")
    end
    if not (M.rain_looks or {})[look] then return end

    local today = _today()
    if not today then return end                      -- the day-0 trap
    local plot, dist = _nearest_plot()
    if not plot or (dist or 999) > (M.plot_range or 40) then return end

    local n = 0
    for _, b in ipairs(beds) do
        if b.crop and b.watered_day ~= today then
            b.watered_day = today
            b.dry = 0
            b.tint_at = now + 0.5                     -- soil darkens at once: it IS raining
            n = n + 1
        end
    end
    if n > 0 then
        _save()
        if now - rain.said > 30.0 then
            rain.said = now
            _log(string.format("RAIN watered %d bed(s) at '%s' - no can needed", n, tostring(plot)))
        end
    end
end

re.on_frame(function() pcall(_rain_tick) end)

-- ── COMBINE-TABLE DUMP (for authoring native crafting recipes safely) ─────────────────────
-- Aurora was right that crafting IS moddable: Content Editor registers an `item_combination`
-- entity (autorun/editors/items/item_combinations.lua). Its own comments give the semantics:
--   material: itemId + anyOf(_CombineRecipe._PairList) => _CombineItem   ("Experiment" tab)
--   mix:      anyOf(_MaterialA) + anyOf(_MaterialB) => _ItemId           ("Use recipe" tab)
-- ⛔ FOOTGUN (item_combinations.lua:135-137): a bundle entry that OMITS `material` REMOVES that
-- item's whole vanilla combine table, and the mix array is index-mapped with extras deleted. So
-- we must never hand-author a recipe onto a vanilla herb/fruit without its CURRENT contents.
-- This dump captures exactly that, for our produce AND our seeds, so the bundle can EXTEND.
local function _dump_combines()
    local out = { produce = {}, seed = {}, candidate = {}, note = "IRIS combine dump" }
    local ok, err = pcall(function()
        local im = sdk.get_managed_singleton("app.ItemManager")
        local mix
        pcall(function() mix = im:get_field("ItemMixData") end)
        if not mix then pcall(function() mix = im:call("get_ItemMixData") end) end
        if not mix then error("ItemMixData not reachable") end

        local want = {}
        for _, c in ipairs(M.crops) do
            if c.base then want[c.base] = { name = c.name, role = "produce" } end
            -- ⭐ 07-25 (Aurora: "ripened version can't turn into seeds"): the Ripened/Rotten
            -- variants are separate items with their OWN combine tables, so they need dumping
            -- before they can be given seed recipes.
            if c.ripe then want[c.ripe] = { name = "Ripened " .. c.name, role = "produce" } end
            if c.rot then want[c.rot] = { name = "Rotten " .. c.name, role = "produce" } end
            if c.seed_item then want[c.seed_item] = { name = c.name .. " Seeds", role = "seed" } end
        end
        -- CANDIDATE crops for the herb/berry expansion (Aurora 07-25). Dumped now so the whole
        -- batch can be authored from one run; ids from data/IrisTaming_item_catalog.json.
        for id, nm in pairs(M.dump_candidates or {}) do
            if not want[id] then want[id] = { name = nm, role = "candidate" } end
        end

        -- _MaterialList: the per-material recipe tables
        local ml
        pcall(function() ml = mix:get_field("_MaterialList") end)
        local n = 0
        pcall(function() n = tonumber(ml:call("get_Count")) or 0 end)
        if n == 0 then pcall(function() n = tonumber(ml:call("get_size")) or 0 end) end
        for i = 0, n - 1 do
            pcall(function()
                local it
                pcall(function() it = ml:call("get_Item", i) end)
                if not it then pcall(function() it = ml[i] end) end
                if not it then return end
                local id = tonumber(it:get_field("_ItemID"))
                if not (id and want[id]) then return end
                local rec = { id = id, name = want[id].name, role = want[id].role, recipes = {} }
                local cr = it:get_field("_CombineRecipe")
                local cn = 0
                pcall(function() cn = tonumber(cr:call("get_Count")) or 0 end)
                if cn == 0 then pcall(function() cn = tonumber(cr:call("get_size")) or 0 end) end
                for k = 0, cn - 1 do
                    pcall(function()
                        local r
                        pcall(function() r = cr:call("get_Item", k) end)
                        if not r then pcall(function() r = cr[k] end) end
                        if not r then return end
                        local pl, pn = {}, 0
                        local plist = r:get_field("_PairList")
                        pcall(function() pn = tonumber(plist:call("get_Count")) or 0 end)
                        if pn == 0 then pcall(function() pn = tonumber(plist:call("get_size")) or 0 end) end
                        for q = 0, pn - 1 do
                            pcall(function()
                                local v
                                pcall(function() v = plist:call("get_Item", q) end)
                                if v == nil then pcall(function() v = plist[q] end) end
                                if v ~= nil then pl[#pl + 1] = tonumber(v) end
                            end)
                        end
                        rec.recipes[#rec.recipes + 1] = {
                            CombineItem = tonumber(r:get_field("_CombineItem")),
                            CombineMakeNum = tonumber(r:get_field("_CombineMakeNum")),
                            Rare = r:get_field("_Rare") and true or false,
                            PairList = pl,
                        }
                    end)
                end
                out[rec.role] = out[rec.role] or {}
                local bucket = out[rec.role]
                bucket[#bucket + 1] = rec
            end)
        end

        -- _Params: the mix ("Use recipe") rows, recorded so we never truncate them either
        out.mix_rows = {}
        local ps, pc = nil, 0
        pcall(function() ps = mix:get_field("_Params") end)
        pcall(function() pc = tonumber(ps:call("get_size")) or 0 end)
        if pc == 0 then pcall(function() pc = tonumber(ps:call("get_Count")) or 0 end) end
        for i = 0, pc - 1 do
            pcall(function()
                local p
                pcall(function() p = ps[i] end)
                if not p then pcall(function() p = ps:call("get_Item", i) end) end
                if not p then return end
                local rid = tonumber(p:get_field("_ItemId"))
                if rid and want[rid] then
                    out.mix_rows[#out.mix_rows + 1] = { result = rid, name = want[rid].name }
                end
            end)
        end
        out.material_list_total = n
        out.mix_params_total = pc
    end)
    out.error = (not ok) and tostring(err) or nil
    pcall(function() json.dump_file("IRIS/combine_dump.json", out) end)
    _log(string.format("combine dump: %d produce / %d seed / %d candidate tables, %d material entries scanned%s",
        #out.produce, #(out.seed or {}), #(out.candidate or {}), out.material_list_total or 0,
        out.error and (" ERROR " .. out.error) or ""))
end

-- ── COOKING PROBE (Aurora 07-25: "interrogate whether we can add our own cooking recipes") ──
-- Offline evidence is inconclusive: Content Editor ships NO cooking editor (only items/weapons/
-- combinations) and the partial RSZ dump shows no cook param types. After being wrong about
-- crafting, that is NOT enough to call it impossible - so ask the LIVE game instead. This lists
-- every cooking/camp-shaped singleton, type and field it can actually find.
local function _probe_cooking()
    local lines = { "IRIS COOKING PROBE " .. os.date("%Y-%m-%d %H:%M:%S"), "" }
    local function w(s) lines[#lines + 1] = tostring(s) end

    -- 1. which candidate TYPES exist at all?
    w("== TYPES ==")
    for _, tn in ipairs({
        "app.CookManager", "app.CookingManager", "app.ItemCookParam", "app.CookRecipeParam",
        "app.ItemCookData", "app.CampManager", "app.CampController", "app.CampRequestItemUseInfo",
        "app.ItemMixData", "app.ItemMixParam", "app.ItemMixMaterialParam", "app.FoodManager",
        "app.ItemCookRecipeParam", "app.CampCookController", "app.GimmickCookPot",
    }) do
        local td = sdk.find_type_definition(tn)
        w(string.format("  %-34s %s", tn, td and "EXISTS" or "-"))
    end

    -- 2. singletons + any cook/food/recipe-ish members on them
    w("")
    w("== SINGLETON MEMBERS matching cook/food/recipe/mix ==")
    for _, sn in ipairs({ "app.ItemManager", "app.CampManager", "app.GimmickManager" }) do
        local ok = pcall(function()
            local s = sdk.get_managed_singleton(sn)
            if not s then w("  " .. sn .. ": singleton NOT live"); return end
            local td = s:get_type_definition()
            w("  " .. sn .. " -> " .. tostring(td and td:get_full_name()))
            for _, f in ipairs((td and td:get_fields()) or {}) do
                local n = tostring(f:get_name()):lower()
                if n:find("cook") or n:find("food") or n:find("recipe") or n:find("mix") then
                    local val = "?"
                    pcall(function() val = tostring(s:get_field(f:get_name())) end)
                    w(string.format("      field %-34s = %s", f:get_name(), val))
                end
            end
            for _, m in ipairs((td and td:get_methods()) or {}) do
                local n = tostring(m:get_name()):lower()
                if n:find("cook") or n:find("food") or n:find("recipe") then
                    w("      method " .. m:get_name())
                end
            end
        end)
        if not ok then w("  " .. sn .. ": probe threw") end
    end

    -- 3. the camp gimmicks we could hide under the cooking-pot furniture
    w("")
    w("== CAMP GIMMICKS (all spawnable from AppSystem/gimmick/prefab/camp/) ==")
    for _, g in ipairs({ "gm80_079", "gm51_381", "gm51_382", "gm51_383", "gm80_256" }) do
        local has_enum, has_type = false, nil
        pcall(function()
            has_enum = sdk.find_type_definition("app.GimmickID"):get_field((g:gsub("^gm", "Gm"))) ~= nil
        end)
        pcall(function()
            local td = sdk.find_type_definition("app." .. g)
            if td then has_type = td:get_full_name() end
        end)
        w(string.format("  %-10s GimmickID=%s  component type=%s", g, tostring(has_enum), tostring(has_type)))
        -- what interact methods does its component expose? (the "give the cookpot a campfire" route)
        pcall(function()
            local td = sdk.find_type_definition("app." .. g)
            for _, m in ipairs((td and td:get_methods()) or {}) do
                local n = tostring(m:get_name())
                if n:lower():find("interact") or n:lower():find("cook") or n:lower():find("jack") then
                    w("        " .. n)
                end
            end
        end)
    end

    -- 4. WHERE DOES raw->cooked LIVE? (Aurora 07-25: campfire cooking is 1 meat -> 1 dish, NOT a
    -- two-ingredient recipe, so it is NOT the ItemMix system.) The meat chain suggests a mapping:
    -- Scrag 25 -> Steak 28, Aged 26 -> 29, Rotten 27 -> 30 (a consistent +3, freshness preserved).
    -- Dump every field ItemDataParam actually has, so a cook/result field can't hide from us.
    w("")
    w("== app.ItemDataParam FIELDS (looking for a cooked-result mapping) ==")
    pcall(function()
        local td = sdk.find_type_definition("app.ItemDataParam")
        for _, f in ipairs((td and td:get_fields()) or {}) do
            local ft = "?"
            pcall(function() ft = tostring(f:get_type():get_full_name()) end)
            w(string.format("   %-40s %s", f:get_name(), ft))
        end
    end)

    w("")
    w("== app.ItemManager METHODS matching item/recipe/data/cook ==")
    pcall(function()
        local td = sdk.find_type_definition("app.ItemManager")
        for _, m in ipairs((td and td:get_methods()) or {}) do
            local n = tostring(m:get_name())
            local ln = n:lower()
            if ln:find("recipe") or ln:find("cook") or ln:find("getitemdata") or ln:find("getdata")
                or ln:find("itemparam") or ln:find("mix") then
                -- REFramework API: get_param_types() / get_return_type() (get_params() doesn't
                -- exist, which is why the first pass printed bare names)
                local sig = n
                pcall(function()
                    local ps = {}
                    for _, pt in ipairs(m:get_param_types() or {}) do
                        ps[#ps + 1] = tostring(pt:get_full_name())
                    end
                    local rt = m:get_return_type()
                    sig = string.format("%s(%s) -> %s", n, table.concat(ps, ", "),
                        tostring(rt and rt:get_full_name()))
                end)
                w("   " .. sig)
            end
        end
    end)

    -- 5. read the LIVE params of the meat chain: whichever field differs between raw 25 and its
    -- cooked form 28 (beyond the obvious) is our candidate for the cook mapping
    w("")
    w("== LIVE ItemDataParam values for the meat chain ==")
    pcall(function()
        local im = sdk.get_managed_singleton("app.ItemManager")
        local getters = { "getItemData(System.Int32)", "get_ItemData(System.Int32)",
                          "getItemDataParam(System.Int32)", "getItemParam(System.Int32)" }
        local getter
        local td = sdk.find_type_definition("app.ItemManager")
        for _, g in ipairs(getters) do
            if td and td:get_method(g) then getter = g; break end
        end
        w("   lookup method: " .. tostring(getter))
        if not getter then return end
        local ftd = sdk.find_type_definition("app.ItemDataParam")
        for _, id in ipairs({ 25, 26, 27, 28, 29, 30, 31, 49 }) do
            local p
            pcall(function() p = im:call(getter, id) end)
            if p then
                local bits = {}
                for _, f in ipairs((ftd and ftd:get_fields()) or {}) do
                    local n = f:get_name()
                    local v
                    pcall(function() v = p:get_field(n) end)
                    if type(v) == "number" and v ~= 0 then bits[#bits + 1] = n .. "=" .. tostring(v) end
                end
                w(string.format("   item %-4d %s", id, table.concat(bits, " ")))
            else
                w(string.format("   item %-4d (lookup returned nil)", id))
            end
        end
    end)

    -- 6. getRecipeList is the last place a raw->cooked mapping can be hiding (there is no cook
    -- field on ItemDataParam - verified). Call it and describe whatever comes back.
    w("")
    w("== getRecipeList / mix-material interrogation ==")
    pcall(function()
        local im = sdk.get_managed_singleton("app.ItemManager")
        local td = sdk.find_type_definition("app.ItemManager")
        for _, mn in ipairs({ "getRecipeList", "getItemMixParam", "isMixMaterial" }) do
            local m = td and td:get_method(mn)
            if not m then w("   " .. mn .. ": not found"); goto continue end
            local np = 0
            pcall(function() np = #(m:get_param_types() or {}) end)
            w(string.format("   %s: %d param(s)", mn, np))
            if np == 0 then
                local r
                local ok = pcall(function() r = im:call(mn) end)
                w("      call -> " .. (ok and tostring(r) or "THREW"))
                if r then
                    pcall(function()
                        local rtd = r:get_type_definition()
                        w("      type: " .. tostring(rtd and rtd:get_full_name()))
                        local n2 = 0
                        pcall(function() n2 = tonumber(r:call("get_Count")) or 0 end)
                        if n2 == 0 then pcall(function() n2 = tonumber(r:call("get_size")) or 0 end) end
                        w("      count: " .. tostring(n2))
                        for i = 0, math.min(n2, 6) - 1 do
                            pcall(function()
                                local el
                                pcall(function() el = r:call("get_Item", i) end)
                                if not el then pcall(function() el = r[i] end) end
                                if el then
                                    local etd = el:get_type_definition()
                                    local bits = {}
                                    for _, f in ipairs((etd and etd:get_fields()) or {}) do
                                        local v
                                        pcall(function() v = el:get_field(f:get_name()) end)
                                        if type(v) == "number" or type(v) == "boolean" then
                                            bits[#bits + 1] = f:get_name() .. "=" .. tostring(v)
                                        end
                                    end
                                    w(string.format("      [%d] %s  %s", i,
                                        tostring(etd and etd:get_full_name()), table.concat(bits, " ")))
                                end
                            end)
                        end
                    end)
                end
            else
                -- one-arg forms: ask about a raw meat (25 = Scrag of Beast)
                local r
                local ok = pcall(function() r = im:call(mn, 25) end)
                w("      call(25) -> " .. (ok and tostring(r) or "THREW"))
            end
            ::continue::
        end
    end)

    pcall(function()
        local f = io.open("IRIS/cooking_probe.txt", "w")
        if f then f:write(table.concat(lines, "\n") .. "\n"); f:close() end
    end)
    _log("cooking probe written to IRIS/cooking_probe.txt (" .. #lines .. " lines)")
end

-- ── dev panel ─────────────────────────────────────────────────────────────────────────────
re.on_draw_ui(function()
    if not imgui.tree_node("IRIS FARMING (gardening)") then return end
    local ch
    ch, M.enabled = imgui.checkbox("enabled", M.enabled)
    imgui.text("last: " .. tostring(M.last))
    local today = _today()
    imgui.text(string.format("in-game day %s, hour %d   beds %d   pick-gate %d",
        tostring(today), _hour(), #beds, gate.armed))
    local _b = _nearest_bed()
    if _b then
        local _st = _b.crop and _bed_state(_b)
        imgui.text("under the hoe: " .. (_st and string.format("%s %d/%d days, %s", _st.crop.name,
            _b.grown or 0, _st.crop.days, _st.ripe and "RIPE" or (_b.watered_day == today and "watered" or "DRY"))
            or "bare tilled soil"))
    else
        imgui.text("under the hoe: open ground (a swing breaks new soil)")
    end
    -- live ground probe at the exact till spot: the diagnostic when the ring is red and shouldn't be
    do
        local sx, sy, sz = _till_spot(true)
        local dd = _delta()
        if sx and dd then
            local solid = _ground_under(sx - dd.x, sy - dd.y, sz - dd.z, M.ground_probe or 3.0)
            local gy = _ground_y(sx - dd.x, sy - dd.y, sz - dd.z, M.ground_probe or 3.0)
            imgui.text(string.format("ground probe: %s | groundY %s | your Y %.2f | ray ready %s",
                solid and "SOLID" or "NOTHING (ring red)",
                gy and string.format("%.2f", gy) or "unreadable",
                sy - dd.y, tostring(_ensure_ray())))
        end
    end
    imgui.separator()

    imgui.text(string.format("THE HOE:  weapon %d / item %d   in hand: %s",
        M.hoe_weapon_id, M.hoe_item_id or 0,
        _hoe_equipped() and "YES (real)" or (M.hoe_bypass and "no - but BYPASSED" or "no")))
    ch, M.hoe_bypass = imgui.checkbox("DEV bypass (till without the hoe equipped)", M.hoe_bypass)
    if imgui.button("give me a Hoe") then
        local n = _grant_item(M.hoe_item_id, 1)
        _log(n > 0 and "granted the Hoe - equip it, then untick the bypass" or "hoe grant FAILED (import the CE bundle?)")
    end
    local hid, hv = imgui.input_text("hoe CE weapon id##hoe", tostring(M.hoe_weapon_id))
    if hid then M.hoe_weapon_id = tonumber(hv) or M.hoe_weapon_id end
    imgui.text("  (pickaxe 47200 / woodaxe 47210 live in IrisWoodcutting's TOOL_IDS)")
    imgui.separator()

    imgui.text("SEEDS (real Content Editor items where seed_item is set):")
    -- testing aid: plant a bed's worth of seed, press this, harvest immediately
    if imgui.button("GROW ALL NEARBY CROPS TO RIPE (25m, testing)") then
        M.last_grow = string.format("force-grew %d crop(s)", _grow_nearby(25.0))
    end
    if M.last_grow then imgui.text("   " .. M.last_grow) end

    if imgui.button("+5 of everything sowable") then
        for _, cc in ipairs(M.crops) do if not _pending(cc) then _seed_give(cc, 5) end end
    end
    local shown = {}
    for _, cc in ipairs(M.crops) do
        if not shown[cc.cat] then
            shown[cc.cat] = true
            imgui.text(cc.cat .. ":")
        end
        if _pending(cc) then
            imgui.text(string.format("   %-12s AWAITING Content Editor item id (grows as %s)", cc.name, cc.gid))
        else
            imgui.text(string.format("   %-12s x%-3d  %d days  %s", cc.name, _seed_count(cc), cc.days,
                cc.seed_item and ("seed item " .. cc.seed_item) or "(virtual seed)"))
            imgui.same_line(); if imgui.button("+5##s" .. cc.key) then _seed_give(cc, 5) end
        end
    end
    imgui.separator()

    -- ⚠ the visible grass is NOT via.landscape.Foliage: the clear reports the nearest Foliage
    -- instance 15-84m away while you stand in thick grass. This names whatever IS rendering it.
    if imgui.button("PROBE what the grass actually is") then
        local lines = { "IRIS GRASS PROBE " .. os.date("%H:%M:%S"), "" }
        pcall(function()
            local up = _pupos(); local d = _delta()
            if not (up and d) then lines[#lines + 1] = "no player"; return end
            local px, pz = up.x - d.x, up.z - d.z
            local smgr = sdk.get_native_singleton("via.SceneManager")
            local scene = smgr and sdk.call_native_func(smgr, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
            -- every component type with an instance within 8m of you, counted
            local seen = {}
            for _, tn in ipairs({ "via.landscape.Foliage", "via.render.Mesh", "via.render.CompositeMesh",
                                  "via.landscape.Terrain", "via.render.InstancedMesh", "via.landscape.Grass",
                                  "via.landscape.FoliageGroup", "via.render.SpeedTree" }) do
                local td = sdk.find_type_definition(tn)
                if not td then lines[#lines + 1] = string.format("  %-34s TYPE DOES NOT EXIST", tn)
                else
                    local arr = scene and scene:call("findComponents(System.Type)", sdk.typeof(tn))
                    local n = arr and arr:get_size() or 0
                    local near = 0
                    for i = 0, math.min(tonumber(n) or 0, 4000) - 1 do
                        pcall(function()
                            local c = arr:get_element(i)
                            local go = c:call("get_GameObject")
                            local p = go and go:call("get_Transform"):call("get_Position")
                            if p then
                                local dx, dz = p.x - px, p.z - pz
                                if dx * dx + dz * dz < 64.0 then
                                    near = near + 1
                                    local nm = tostring(go:call("get_Name") or "?")
                                    seen[tn .. " :: " .. nm] = (seen[tn .. " :: " .. nm] or 0) + 1
                                end
                            end
                        end)
                    end
                    lines[#lines + 1] = string.format("  %-34s total %-6s within 8m: %d", tn, tostring(n), near)
                end
            end
            lines[#lines + 1] = ""
            lines[#lines + 1] = "== named objects within 8m =="
            for k, v in pairs(seen) do lines[#lines + 1] = string.format("   %-70s x%d", k, v) end
        end)
        pcall(function()
            local f = io.open("IRIS/grass_probe.txt", "w")
            if f then f:write(table.concat(lines, "\n") .. "\n"); f:close() end
        end)
        _log("grass probe -> IRIS/grass_probe.txt (" .. #lines .. " lines)")
    end
    -- ⭐ SCENERY MESH PATHS (Aurora 07-27: "are you sure we can't reach them somehow? like how we
    -- reached houses?"). She's right that the earlier probe couldn't answer this: it filtered on the
    -- GameObject's TRANSFORM POSITION, but a scenery mesh's GO sits at a CHUNK ORIGIN that can be
    -- 100m from the geometry you're stood on (the same pivot problem that broke Rock Sense). So
    -- don't filter by distance - read every mesh's RESOURCE PATH, which is how the houses were
    -- reached: learn the path, then spawn our own prop with that mesh.
    -- ⭐ MESH AUDITIONER (07-27). The probe proves sm scenery meshes have real resource paths but no
    -- gimmick/prefab - and the farmland prop route spawns a MESH PATH, so ANY game scenery mesh can
    -- be a crop visual. Type a path, spawn it, look at it. This is how we find out what sm82_081 is.
    -- ── ⭐ WEAPON VISUAL RESCUE (the stray-arrow fix: my old reset handler force-showed every wp
    -- child, revealing props the game keeps hidden - and nothing native re-hides them. This lists
    -- the player's wp children so the wrongly-shown one can be re-hidden by hand, no restart.) ──
    -- the invisible-tool rescue: watering hides tools by DISABLING MESH COMPONENTS, so the
    -- DrawSelf toggles below can't bring one back - this re-enables every mesh comp on every
    -- tool wp child (self + linked children), which is exactly the set the watering touches
    if imgui.button("RESTORE tool visibility (fix an invisible hoe/pickaxe/axe)##wvres") then
        local n = 0
        pcall(function()
            local TOOL_WP = { [47200] = true, [47210] = true, [47220] = true }
            local tf = _ptf()
            local child = tf and tf:call("get_Child")
            while child do
                pcall(function()
                    local go = child:call("get_GameObject")
                    if tostring(go:call("get_Name") or ""):find("^wp") then
                        local w = go:call("getComponent(System.Type)", sdk.typeof("app.Weapon"))
                        local id
                        if w then
                            pcall(function() id = w:get_field("ID") end)
                            if id == nil then pcall(function() id = w:get_field("<ID>k__BackingField") end) end
                        end
                        if TOOL_WP[tonumber(id) or -1] then
                            local function fix(g, depth)
                                if not g or depth > 4 then return end
                                pcall(function()
                                    local mcp = g:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
                                    if mcp and mcp:call("get_Enabled") == false then
                                        mcp:call("set_Enabled", true); n = n + 1
                                    end
                                    local c2 = g:call("get_Transform"):call("get_Child")
                                    while c2 do
                                        pcall(function() fix(c2:call("get_GameObject"), depth + 1) end)
                                        c2 = c2:call("get_Next")
                                    end
                                end)
                            end
                            fix(go, 0)
                        end
                    end
                end)
                child = child:call("get_Next")
            end
        end)
        _log("tool visibility restore: " .. n .. " mesh comp(s) re-enabled")
    end
    if imgui.tree_node("weapon visuals (fix a stray arrow / hidden tool)##wvfix") then
        pcall(function()
            local tf = _ptf()
            local child = tf and tf:call("get_Child")
            local i = 0
            while child and i < 24 do
                i = i + 1
                pcall(function()
                    local go = child:call("get_GameObject")
                    local nm = tostring(go:call("get_Name") or "?")
                    if nm:find("^wp") then
                        local vis = go:call("get_DrawSelf") ~= false
                        imgui.text(string.format("%-14s %s", nm, vis and "SHOWN" or "hidden"))
                        imgui.same_line()
                        if imgui.button((vis and "HIDE" or "SHOW") .. "##wv" .. i) then
                            go:call("set_DrawSelf", not vis)
                            _log("weapon visual: " .. nm .. " -> " .. (vis and "hidden" or "shown"))
                        end
                    end
                end)
                child = child:call("get_Next")
            end
        end)
        imgui.tree_pop()
    end
    imgui.spacing()
    -- ── ⭐ THE COOKING FIRE ──
    imgui.text("COOKING FIRE (stand at your cookpot, place - the campfire's cook prompt, wood hidden):")
    if imgui.button("PLACE cooking fire here##ckf") then
        local up = _pupos()
        local fx, fz = _pfwd()
        if up then
            cookfires[#cookfires + 1] = { ux = up.x + fx * 0.4, uy = up.y, uz = up.z + fz * 0.4,
                                          yaw = math.deg(math.atan(fx, fz)) }
            _save_cookfires()
            _log("cooking fire placed - it streams in within a moment")
        end
    end
    imgui.same_line()
    if imgui.button("REMOVE nearest cooking fire##ckf") then
        local up = _pupos()
        if up then
            local bi, bd
            for i, cf in ipairs(cookfires) do
                local dx, dz = cf.ux - up.x, cf.uz - up.z
                local dd = dx * dx + dz * dz
                if not bd or dd < bd then bd = dd; bi = i end
            end
            if bi and bd and bd < 100.0 then
                local cf = cookfires[bi]
                if cf.live then pcall(function() cf.live:call("destroy", cf.live) end) end
                table.remove(cookfires, bi)
                _save_cookfires()
                _log("cooking fire removed")
            else _log("no cooking fire within 10m") end
        end
    end
    imgui.same_line()
    local cc; cc, M.cookfire_hide = imgui.checkbox("hide the wood##ckf", M.cookfire_hide ~= false)
    -- ⚠ gm51_381 field-tested 08-04: spawns a LIT tripod-cauldron visual but carries NO cook
    -- interaction - the camp cook flow may live on the campsite object instead. Iterate:
    imgui.text("  fire gimmick: " .. tostring(M.cookfire_gid) .. "   (new fires use the selected id)")
    -- gm80_069: the campsite object that carries an 'InteractActionMarker' child (the camp probe,
    -- 08-05) - the strongest candidate for a REAL interact prompt of its own
    for ci, cand in ipairs({ "gm80_069", "gm51_381", "gm51_382", "gm51_383", "gm80_079", "gm80_256" }) do
        if ci > 1 then imgui.same_line() end
        if imgui.button(cand .. "##ckfg" .. ci) then M.cookfire_gid = cand; _log("cooking fire gimmick -> " .. cand) end
    end
    imgui.spacing()
    -- ⭐ GATHER TRACER (08-05): GatherContext held counts/flags but NO item id - the grant is
    -- data-driven at gather time. So trace the CALL instead: hook every gather/item-ish method on
    -- the crop gimmick's class tree (log-only), then natively B-gather a crop - whichever methods
    -- fire are where a skip-and-replace hook can make native gather grant OUR items.
    -- ⛔⛔ TRACER RETIRED (08-05): it answered the question (the grant = app.Gm*.giveItem, now
    -- hooked for real above) and it also LAGGED THE GAME TO DEATH - one of its nine hooks landed
    -- on app.GimmickBase.set_CompPickUpCtrl, ~1000 calls/sec scene-wide, a log line per call
    -- (84,130 lines). Hooks are permanent until game restart, so a mass log-only tracer over a
    -- class TREE is never safe to ship as a button. If tracing is ever needed again: exclude
    -- get_/set_, stop the walk at the app.Gm* leaf class, and log each method ONCE.
    if imgui.button("PROBE the crop gimmick's drop fields (for native B-gather repoint)##gp") then
        _probe_gather_fields()
    end
    imgui.text("  ^ stand at a bed whose plant is visible; results land in the farming log")
    -- ⭐⭐ THE COOK-PROMPT HUNT (Aurora 08-04: "probe the cookpot at a campsite to see how to get
    -- the cook interaction"). Stand AT A REAL CAMPSITE next to the kettle and press: every gimmick
    -- within 10m gets its GO name + FULL component list + child GO names dumped to the log. The
    -- component that only the kettle carries = the machinery the cook prompt hangs off.
    if imgui.button("PROBE nearby gimmicks (stand at a REAL campsite kettle)##cp") then
        pcall(function()
            local rp = _ppos(); if not rp then return end
            local smgr = sdk.get_native_singleton("via.SceneManager")
            local scene = smgr and sdk.call_native_func(smgr, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
            local arr = scene and scene:call("findComponents(System.Type)", sdk.typeof("app.GimmickBase"))
            local n = arr and arr:get_size() or 0
            local dumped, lines = 0, 0
            _log("== CAMP PROBE: gimmicks within 10m ==")
            for i = 0, (tonumber(n) or 0) - 1 do
                if dumped >= 8 or lines > 90 then break end
                pcall(function()
                    local c = arr:get_element(i)
                    local go = c:call("get_GameObject")
                    local p = go:call("get_Transform"):call("get_Position")
                    local dx, dz = p.x - rp.x, p.z - rp.z
                    if dx * dx + dz * dz <= 100.0 then
                        dumped = dumped + 1
                        _log(string.format("GIMMICK '%s' (%.1fm):", tostring(go:call("get_Name")), math.sqrt(dx * dx + dz * dz)))
                        local comps = go:call("get_Components")
                        local cn = comps and comps:get_size() or 0
                        for k = 0, cn - 1 do
                            pcall(function()
                                _log("   comp " .. comps:get_element(k):get_type_definition():get_full_name())
                                lines = lines + 1
                            end)
                        end
                        -- children (LINKED walk), names only - the kettle is often a child part
                        local child = go:call("get_Transform"):call("get_Child")
                        while child and lines < 120 do
                            pcall(function()
                                _log("   child GO '" .. tostring(child:call("get_GameObject"):call("get_Name")) .. "'")
                                lines = lines + 1
                            end)
                            child = child:call("get_Next")
                        end
                    end
                end)
            end
            _log("== CAMP PROBE done: " .. dumped .. " gimmick(s) dumped ==")
        end)
    end
    imgui.spacing()
    -- ── plot map markers: find the signpost by eye ──
    imgui.text("PLOT MAP MARKERS (cycle the TYPE, then re-open the map - it rebuilds each open):")
    local mi
    mi, M.plot_icon_type = imgui.drag_int("icon TYPE (the glyph: 18 inn, 27 riftstone, 67 settlement)##pmk", M.plot_icon_type or 67, 1, 0, 120)
    mi, M.plot_icon_id = imgui.drag_int("icon id (fine variant, usually 0)##pmk2", M.plot_icon_id or 0, 1, 0, 60)
    imgui.text("  status: " .. tostring(pmk.last) .. "  (" .. tostring(pmk.adds) .. " injected total)")
    imgui.spacing()
    imgui.text("AUDITION any scenery mesh (paths come from the probe below):")
    -- ⭐ ONE-CLICK CANDIDATES (Aurora 08-04: "not sure how to actually audition the mesh - is there
    -- a dropdown/easier way to do this?"). Fair - the box wanted a 50-character path typed by hand
    -- with no indication of what to type. These are the three no-gimmick meshes the Vernworth probe
    -- found by the farm; one click sets the path AND spawns it. The box stays for anything else.
    -- ⭐ IDENTIFIED BY AURORA'S EYES 08-04 (the catalog law): sm51_543 = HAYBALE, sm82_081 = a
    -- bunch of BAGS, sm50_079 = a SCONCE. None is corn - the Vernworth "corn" is baked chunk art,
    -- confirmed unusable. The haybale is a keeper (homestead decor). New sprout candidate:
    -- sm82_009 = the "Random plant" generic leafy mesh, the very plant the vegetables grow as.
    local CANDIDATES = {
        { "sm82_009  (generic leafy plant - SPROUT candidate)", "Environment/Props/sm8X/sm82/sm82_009/sm82_009_00" },
        { "sm51_543  (HAYBALE - decor keeper)", "Environment/Props/sm5X/sm51/sm51_543/sm51_543_00" },
        { "farmland (sanity - our own mesh)",  "custom_tex/iris/farmland" },
    }
    local ac, av = imgui.input_text("mesh path (no extension)##aud", tostring(M.audition_path or CANDIDATES[1][2]))
    if ac then M.audition_path = av end
    local want_spawn = false
    for ci, cand in ipairs(CANDIDATES) do
        if imgui.button("try " .. cand[1] .. "##audc" .. ci) then
            M.audition_path = cand[2]
            want_spawn = true
        end
    end
    -- ⭐ and the button that closes the loop: whatever you're looking at becomes the sprout
    if imgui.button("USE THIS AS THE SPROUT MESH##aud") then
        M.sprout_mesh = tostring(M.audition_path or "")
        for _, b in ipairs(beds) do _drop_sprout(b) end
        _log("sprout mesh set to '" .. tostring(M.sprout_mesh) .. "'")
    end
    -- ⛔ DEBOUNCE (Aurora 08-04, the log's smoking gun: five "carrier up - binding" lines a second
    -- apart, and NO "bound" line ever). Every click REPLACED the audition mid-bind - resetting the
    -- ~2.4s bind→cure timer and orphaning the previous carrier - and since a pivot-displaced mesh
    -- shows nothing at first, clicking again was the natural thing to do. So the probe never ran
    -- even once. Now: while one is binding, further clicks are refused with a countdown instead.
    local aud_busy = audition and audition.stage and audition.stage ~= "done"
    if aud_busy then
        imgui.text(string.format("  ... binding '%s' - give it ~3s (the double-bind law)", tostring(audition.base)))
    end
    if (imgui.button("SPAWN it in front of me##aud") or want_spawn) and not aud_busy then
        -- ⭐⭐⭐ THE AUDITIONER NO LONGER HAS ITS OWN SPAWN PATH (08-04, after five rounds of the
        -- carrier being provably perfect - bound, positioned, scaled, rotated, even floated at
        -- chest height - and still invisible while the IDENTICAL farmland mesh renders fine as a
        -- bed). Whatever the bare-carrier route is missing, the BED PIPELINE has it. So an
        -- audition now IS a bed: an EPHEMERAL entry in `beds` (never saved, gone on reset)
        -- carrying its own mound_base, and the ordinary machinery - ground fit, warm, holder-bind,
        -- double-bind, foliage clear - does every step exactly as it does for real farmland.
        local base = tostring(M.audition_path or "")
        local up = _pupos()
        if up and base ~= "" then
            local r1 = nil
            pcall(function() r1 = sdk.create_resource("via.render.MeshResource", base .. ".mesh") end)
            if not r1 then
                _log("audition: mesh NOT FOUND '" .. base .. ".mesh'")
            else
                pcall(function() mres.held[#mres.held + 1] = r1:add_ref() end)
                local fx, fz = _pfwd()
                local bed = { ux = up.x + fx * 2.5, uy = up.y, uz = up.z + fz * 2.5,
                    plot = "audition", yaw = math.deg(math.atan(fx, fz)),
                    crop = nil, grown = 0, dry = 0, missed = 0, hidden = {},
                    ephemeral = true, mound_base = base }
                beds[#beds + 1] = bed
                _log("audition bed queued for '" .. base .. "' - the bed pipeline will stream it in (~2s)")
            end
        end
    end
    imgui.same_line()
    if imgui.button("clear auditions##aud") then
        if audition and audition.go then pcall(function() audition.go:call("destroy", audition.go) end) end
        audition = nil
        -- the new-style auditions are ephemeral BEDS: drop their props and pull them from the list
        for i = #beds, 1, -1 do
            if beds[i].ephemeral then _drop_bed_props(beds[i]); table.remove(beds, i) end
        end
        -- ⭐ ORPHAN SWEEP: the click-storm era replaced carriers mid-bind without destroying them,
        -- so the scene can hold IrisAudition GameObjects this session doesn't track. Name sweep.
        local swept = 0
        pcall(function()
            local smgr = sdk.get_native_singleton("via.SceneManager")
            local scene = smgr and sdk.call_native_func(smgr, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
            while scene do
                local go = scene:call("findGameObject(System.String)", "IrisAudition")
                if not go then break end
                go:call("destroy", go); swept = swept + 1
                if swept > 30 then break end
            end
        end)
        _log("audition cleared" .. (swept > 0 and (" (+ " .. swept .. " orphan(s) swept)") or ""))
    end
    imgui.separator()
    if imgui.button("PROBE scenery MESH PATHS (the house route)") then
        local out = { "IRIS SCENERY MESH PATH PROBE " .. os.date("%Y-%m-%d %H:%M:%S"), "" }
        pcall(function()
            local up = _pupos(); local dd = _delta()
            local px, pz = (up and dd) and (up.x - dd.x) or 0, (up and dd) and (up.z - dd.z) or 0
            local smgr = sdk.get_native_singleton("via.SceneManager")
            local scene = smgr and sdk.call_native_func(smgr, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
            local seen = {}
            for _, tn in ipairs({ "via.render.Mesh", "via.render.CompositeMesh" }) do
                local arr = scene and scene:call("findComponents(System.Type)", sdk.typeof(tn))
                local n = (arr and arr:get_size()) or 0
                for i = 0, (tonumber(n) or 0) - 1 do
                    pcall(function()
                        local c = arr:get_element(i)
                        local mr = c:call("getMesh")
                        if not mr then pcall(function() mr = c:call("get_Mesh") end) end
                        local path
                        pcall(function() path = tostring(mr:call("get_ResourcePath")) end)
                        if not path or path == "nil" then return end
                        -- distance is only a HINT here (the GO pivot lies); keep the smallest seen
                        local d9 = 9e9
                        pcall(function()
                            local p = c:call("get_GameObject"):call("get_Transform"):call("get_Position")
                            if p then local a, b = p.x - px, p.z - pz; d9 = math.sqrt(a * a + b * b) end
                        end)
                        local e = seen[path]
                        if not e then seen[path] = { n = 1, d = d9, t = tn }
                        else e.n = e.n + 1; if d9 < e.d then e.d = d9 end end
                    end)
                end
            end
            -- FARM-ish paths first, then everything else by nearest pivot
            local farm, rest = {}, {}
            for path, e in pairs(seen) do
                local lp = path:lower()
                local row = string.format("  %-72s x%-4d pivot %6.1fm  [%s]", path, e.n, e.d, e.t)
                if lp:find("field") or lp:find("farm") or lp:find("soil") or lp:find("hatake")
                    or lp:find("mound") or lp:find("dirt") or lp:find("crop") or lp:find("corn")
                    or lp:find("vege") or lp:find("plant") or lp:find("furrow") then
                    farm[#farm + 1] = row
                else rest[#rest + 1] = { row = row, d = e.d } end
            end
            table.sort(farm)
            table.sort(rest, function(a, b) return a.d < b.d end)
            out[#out + 1] = "== FARM-LIKE PATHS (field/farm/soil/mound/crop/corn/plant...) =="
            if #farm == 0 then out[#out + 1] = "  (none matched by name)" end
            for _, r in ipairs(farm) do out[#out + 1] = r end
            -- ⭐ ALL scenery props, complete. The nearest-60 list gets flooded by character and
            -- equipment meshes (all pivoting at 0.0m on their owner), so the one prop we're hunting
            -- never survived the cut. Environment/Props is the house-route currency - list it whole.
            out[#out + 1] = ""
            out[#out + 1] = "== ALL Environment/Props (COMPLETE - this is the spawnable-scenery set) =="
            local props = {}
            for path, e in pairs(seen) do
                if path:find("Environment/Props") or path:find("environment/props") then
                    props[#props + 1] = { row = string.format("  %-64s x%-4d pivot %6.1fm", path, e.n, e.d), n = e.n }
                end
            end
            table.sort(props, function(a, b) return a.n > b.n end)   -- most instances first
            if #props == 0 then out[#out + 1] = "  (none)" end
            for _, r in ipairs(props) do out[#out + 1] = r.row end

            out[#out + 1] = ""
            out[#out + 1] = "== NEAREST 60 BY PIVOT (pivot is unreliable for scenery - names matter more) =="
            for i = 1, math.min(60, #rest) do out[#out + 1] = rest[i].row end
            out[#out + 1] = ""
            out[#out + 1] = string.format("(%d unique mesh paths in the scene)", #farm + #rest)
        end)
        pcall(function()
            local f = io.open("IRIS/scenery_paths.txt", "w")
            if f then f:write(table.concat(out, "\n") .. "\n"); f:close() end
        end)
        _log("scenery path probe -> IRIS/scenery_paths.txt (" .. #out .. " lines)")
    end
    if imgui.button("PROBE cooking (can we add our own recipes?)") then _probe_cooking() end
    imgui.same_line()
    if imgui.button("DUMP combine tables (for native crafting recipes)") then _dump_combines() end
    imgui.text("  writes IRIS/combine_dump.json - needed before authoring item_combination bundles,")
    imgui.text("  because a CE entry without 'material' DELETES that item's vanilla recipes.")
    imgui.separator()

    imgui.text("THE TILLED MOUND (what a hoed bed looks like before anything grows):")
    -- ⭐ AUDITION ONE, NOT NINE (the boulder lesson): spawn a single candidate at your feet so it
    -- can be looked at and walked into before it's turned on for every bed.
    imgui.text("  audition a stand-in at your feet (walk into it - if it blocks you, it's wrong):")
    local CANDIDATES = {
        { "gm80_222", "Table decor - FLAT, 1.0x0.8x0.2m (best shape found)" },
        { "gm80_216", "Table decor - flat, 1.8x0.9x0.33m" },
        { "gm50_097", "Haystack" },
        { "gm80_103", "Sacks" },
    }
    for ci, cand in ipairs(CANDIDATES) do
        if imgui.button("try " .. cand[1] .. "##aud" .. ci) then
            local up = _pupos(); local fx, fz = _pfwd()
            if up then
                _queue_spawn(cand[1], up.x + fx * 2.0, up.y, up.z + fz * 2.0, 0, function(go)
                    _log("audition prop " .. cand[1] .. " up - walk into it, then 'DESTROY mounds nearby' to clear")
                end, M.mound_scale or 1.0)
                _log("auditioning " .. cand[1] .. " at " .. cand[2])
            end
        end
        imgui.same_line(); imgui.text(cand[2])
    end
    imgui.text("  (clear them with DESTROY below, then set 'mound gimmick' to whichever you liked)")
    if imgui.button("DESTROY mounds nearby (get me out / clear a bad prop)") then
        _sweep_bed_props(6.0)
    end
    imgui.text("  ^ sweeps EVERY gimmick within 6m of a bed - orphans from a script reset included")
    local mch
    mch, M.mound_show = imgui.checkbox("show the mound prop", M.mound_show)
    imgui.text("  ⛔ audition a prop with ONE bed before ticking this: gm51_573 'Burial mound' is")
    imgui.text("     a cluster of huge boulders and ignored the scale entirely.")
    imgui.text(string.format("  custom mesh: %s  [%s]", tostring(M.mound_mesh),
        M.mound_mesh == "" and "disabled - using the gimmick below"
        or (mres.warmed and (mres.ok and "PAK MOUNTED, resources resolved" or "NOT FOUND - pak not mounted?")
            or "not warmed yet")))
    local mc2, mv2 = imgui.input_text("custom mesh path (no extension)##mm", tostring(M.mound_mesh))
    if mc2 then M.mound_mesh = mv2; mres.warmed = false; mres.ok = nil end
    -- live fit controls: change any of these and every bed respawns so you see it at once
    local fit = mch or false      -- toggling the prop on/off also needs a respawn
    local f1; f1, M.mound_sink = imgui.slider_float("sink into ground (m)##mg", M.mound_sink or 0.0, -0.30, 0.60); fit = fit or f1
    local f2; f2, M.mound_scale = imgui.slider_float("size##mg", M.mound_scale or 1.0, 0.20, 3.0); fit = fit or f2
    local f8; f8, M.mound_tilt = imgui.checkbox("lie flat on slopes (probe 4 corners, tilt to match)##mg", M.mound_tilt ~= false); fit = fit or f8
    local f9; f9, M.tilt_cap = imgui.slider_float("max tilt (deg)##mg", M.tilt_cap or 35.0, 0.0, 60.0); fit = fit or f9
    -- the tilt SIGN can't be verified from outside the game; flip and watch, it respawns instantly
    if imgui.button("flip PITCH sign##mg") then M.pitch_sign = -(M.pitch_sign or 1); fit = true end
    imgui.same_line()
    if imgui.button("flip ROLL sign##mg") then M.roll_sign = -(M.roll_sign or 1); fit = true end
    imgui.same_line()
    imgui.text(string.format("pitch %+d  roll %+d", M.pitch_sign or 1, M.roll_sign or 1))
    -- height rule: 9 points are sampled (corners, edge midpoints, centre)
    if imgui.button((M.fit_mode == "max" and "height: HIGHEST sample (never sinks)"
        or "height: AVERAGE (can dip into a bump)") .. "##mg") then
        M.fit_mode = (M.fit_mode == "max") and "mean" or "max"; fit = true
    end
    imgui.same_line(); imgui.text("<- click to swap")
    local f10; f10, M.mound_lift = imgui.slider_float("extra lift, ALL beds (m)##mg", M.mound_lift or 0.0, -0.20, 0.40); fit = fit or f10
    local f11; f11, M.probe_grid = imgui.slider_int("ground samples across##mg", math.floor(M.probe_grid or 5), 2, 9); fit = fit or f11
    -- ⭐ PER-BED NUDGE: the answer to "it isn't one size fits all". A bump with no collision is
    -- invisible to the probe, so that one bed needs its own lift - saved with it, not global.
    do
        local nb = _nearest_bed()
        if nb then
            imgui.text(string.format("THIS BED (%.0f,%.0f) own lift: %+.3fm", nb.ux, nb.uz, nb.lift or 0.0))
            local changed = false
            if imgui.button("bed -1cm##bl") then nb.lift = (nb.lift or 0) - 0.01; changed = true end
            imgui.same_line(); if imgui.button("bed +1cm##bl") then nb.lift = (nb.lift or 0) + 0.01; changed = true end
            imgui.same_line(); if imgui.button("bed +5cm##bl") then nb.lift = (nb.lift or 0) + 0.05; changed = true end
            imgui.same_line(); if imgui.button("reset##bl") then nb.lift = 0.0; changed = true end
            if changed then
                _save()
                if nb.mound then pcall(function() nb.mound:call("destroy", nb.mound) end) end
                nb.mound, nb.mound_mc, nb.mound_stage, nb.mound_pending = nil, nil, nil, nil
            end
        else
            imgui.text("THIS BED: stand on a bed to nudge it individually")
        end
    end
    local _b0 = _nearest_bed()
    if _b0 and _b0.fit_pitch then
        imgui.text(string.format("  nearest bed fitted: pitch %.1f  roll %.1f  groundY %.2f",
            _b0.fit_pitch, _b0.fit_roll or 0, _b0.fit_y or 0))
    end
    imgui.text("ROWS: snapping makes patches inherit a neighbour's angle and butt up to it")
    local f3; f3, M.snap = imgui.checkbox("snap new beds into rows##mg", M.snap ~= false)
    local f4; f4, M.bed_len = imgui.slider_float("bed length (m, along facing)##mg", M.bed_len or 1.40, 0.4, 3.0)
    local f5; f5, M.bed_wid = imgui.slider_float("bed width (m, across)##mg", M.bed_wid or 0.95, 0.4, 3.0)
    local f6; f6, M.snap_dist = imgui.slider_float("snap search (m)##mg", M.snap_dist or 3.0, 0.5, 8.0)
    local f7; f7, M.yaw_step = imgui.slider_float("angle step with no neighbour (deg)##mg", M.yaw_step or 90.0, 0.0, 90.0)
    imgui.text("  (bed length/width should match the MESH's real footprint or rows will gap/overlap)")
    if fit then
        for _, b in ipairs(beds) do
            if b.mound then pcall(function() b.mound:call("destroy", b.mound) end) end
            b.mound, b.mound_mc, b.mound_stage, b.mound_pending = nil, nil, nil, nil
        end
    end
    -- ⛔ A SECOND pair of size/sink sliders used to live here. They shared an imgui ID with the
    -- ones above AND wrote the same variables through different clamp ranges, so the two fought
    -- every frame - which made the respawn-on-change block above destroy every mound CONTINUOUSLY
    -- and no bed ever kept a prop (Aurora 07-26: "no mounds are being created anymore").
    -- One control per setting. The imgui "conflicting ID" warning was the tell.
    local gc, gv = imgui.input_text("fallback gimmick##mg_gid", tostring(M.mound_gid))
    if gc then M.mound_gid = gv; fit = true end
    imgui.text("  fallback only, used when the custom mesh path is empty")
    imgui.separator()

    if imgui.button("TILL here") then do_till() end
    imgui.same_line(); if imgui.button("SOW here") then local b = _nearest_bed(); if b then do_sow(b) end end
    imgui.same_line(); if imgui.button("WATER here") then local b = _nearest_bed(); if b then do_water(b) end end
    imgui.same_line(); if imgui.button("HARVEST here") then local b = _nearest_bed(); if b then do_harvest(b) end end
    -- ⭐ THE DAY BUTTON AURORA LOOKED FOR AND DIDN'T FIND (08-04: "the dev button to make a day go
    -- past doesn't seem to work" - it didn't exist). Rewinding last_day makes _advance_days see
    -- one elapsed day without touching the game clock; watered beds grow, dry ones streak.
    if imgui.button("DEV: +1 day (grow watered beds)##dday") then
        local today = _today()
        if today then
            -- ⛔ v1 only rewound last_day - but growth requires watered_day == last_day, and a bed
            -- watered TODAY carries today's number, so it read as DRY and gained a missed-day
            -- (Aurora: "the dev button doesn't work", crop stuck 0/3 + already-watered). The whole
            -- day shifts together: today's waterings become yesterday's, then the day turns.
            for _, b in ipairs(beds) do
                if b.crop and b.watered_day == today then b.watered_day = today - 1 end
            end
            meta.last_day = today - 1
            _advance_days()
            _save()
            _log("DEV: advanced the farm one day (watered beds grew)")
        else _log("DEV day: no in-game clock right now (title screen / day 0)") end
    end
    -- the uproot, without needing to line a hoe swing up twice while testing
    imgui.same_line()
    if imgui.button("UPROOT here") then
        local b = _nearest_bed()
        if b and b.crop then
            local nm = (_crop(b.crop) or {}).name or b.crop
            b.crop, b.grown, b.dry, b.missed, b.uproot_armed = nil, 0, 0, 0, nil
            b.sown_day, b.watered_day = nil, nil
            if b.live then pcall(function() b.live:call("destroy", b.live) end); b.live = nil end
            _drop_sprout(b); b.pending = nil
            _save(); _log("uprooted " .. tostring(nm) .. " (panel)")
        end
    end

    -- ── the sprout mesh: paste an auditioned path here to give young crops a shoot ──
    imgui.spacing()
    local sc, sv = imgui.input_text("sprout mesh (blank = shrink the plant)##sp", tostring(M.sprout_mesh or ""))
    if sc then M.sprout_mesh = sv end
    imgui.text("  candidates: sm82_081 / sm51_543 / sm50_079 - audition one below, then paste it here")
    local s1; s1, M.sprout_until = imgui.slider_float("shoot until this much grown##sp", M.sprout_until or 0.5, 0.0, 1.0)
    local s2; s2, M.sprout_scale = imgui.slider_float("shoot size##sp", M.sprout_scale or 0.30, 0.02, 1.5)
    local s3; s3, M.sprout_rise  = imgui.slider_float("shoot height nudge (m)##sp", M.sprout_rise or 0.0, -0.5, 1.0)
    if sc or s1 or s2 or s3 then
        -- drop every live shoot so the new path/size is picked up on the next tick
        for _, b in ipairs(beds) do _drop_sprout(b) end
    end
    if imgui.button("DEV: pretend a day passed") then
        if meta.last_day then meta.last_day = meta.last_day - 1; _advance_days() end
    end
    imgui.same_line(); if imgui.button("remove nearest bed") then
        local b = _nearest_bed()
        if b then
            _drop_bed_props(b)      -- crop AND mound, or the mound outlives the bed
            for i = #beds, 1, -1 do if beds[i] == b then table.remove(beds, i) end end
            _save(); _log("bed removed")
        end
    end
    imgui.separator()

    if imgui.tree_node("tuning") then
        ch, M.wilt_after = imgui.drag_int("dry days -> wilt", math.floor(M.wilt_after), 1, 1, 10)
        ch, M.die_after  = imgui.drag_int("dry days -> death", math.floor(M.die_after), 1, 2, 20)
        ch, M.act_radius = imgui.drag_float("interact reach (m)", M.act_radius, 0.1, 0.8, 6.0)
        ch, M.till_ahead = imgui.drag_float("till ahead (m)", M.till_ahead, 0.1, 0.5, 5.0)
        ch, M.pawn_gather = imgui.checkbox("pawns may harvest ripe crops (off = the garden keeps its visual)", M.pawn_gather ~= false)
        ch, M.block_jump = imgui.checkbox("eat the jump while stood on a bed (A = tend, not hop)", M.block_jump ~= false)
        ch, M.block_indoors = imgui.checkbox("refuse to till under a roof (no farming indoors)", M.block_indoors ~= false)
        ch, M.roof_height = imgui.slider_float("...a ceiling this close counts as indoors (m)", M.roof_height or 4.0, 1.5, 10.0)
        ch, M.till_clear = imgui.drag_float("till clear radius (m)", M.till_clear, 0.1, 0.4, 4.0)
        ch, M.bed_spacing = imgui.drag_float("min bed spacing (m)", M.bed_spacing, 0.1, 0.5, 5.0)
        ch, M.scale_min  = imgui.drag_float("sprout size", M.scale_min, 0.01, 0.05, 0.9)
        for _, cc in ipairs(M.crops) do
            ch, cc.days = imgui.drag_int(cc.name .. " days##d", math.floor(cc.days), 1, 1, 30)
        end
        imgui.tree_pop()
    end

    if imgui.tree_node("display / testing") then
        ch, M.ring = imgui.checkbox("ground ring showing where a hoe swing lands (green ok / amber too close)", M.ring)
        ch, M.bed_prompt = imgui.checkbox("native B prompts for beds, cookpots and animal produce", M.bed_prompt ~= false)
        ch, M.cook_world = imgui.checkbox("...and at the GAME's own cookpots/campfires, not just yours##cw", M.cook_world ~= false)
        imgui.text("  (" .. tostring(cookpot.why or "-") .. ")")
        ch, M.prompt_height = imgui.slider_float("prompt height above bed (m)##pr", M.prompt_height or 0.9, 0.0, 2.5)
        ch, M.hud = imgui.checkbox("on-screen status line (off = the crops speak for themselves)", M.hud)
        local kc, kv = imgui.input_text("DEBUG strike key (VK hex, 0 = off)##k", string.format("%X", M.debug_key or 0))
        if kc then M.debug_key = tonumber(kv, 16) or 0 end
        imgui.text("  fires a hoe strike without a hoe - testing only; the real interface is the swing")
        imgui.tree_pop()
    end

    if imgui.tree_node("WATERING EMOTE (61:3050 -> 61:3052, can included)") then
        ch, M.water_emote = imgui.checkbox("play the emote when watering", M.water_emote)
        imgui.text("Aurora 07-25: the clip carries its own watering can - no prop needed.")
        imgui.text("3051 (the middle LOOP) is skipped on purpose: looping = tedious chore.")
        M.water_intro = math.floor(tonumber(M.water_intro) or 3050)
        M.water_end = math.floor(tonumber(M.water_end) or 3052)
        M.water_intro_f = math.floor(tonumber(M.water_intro_f) or 254)
        M.water_end_f = math.floor(tonumber(M.water_end_f) or 190)
        ch, M.water_intro = imgui.drag_int("intro clip", M.water_intro, 1, 0, 20000)
        ch, M.water_intro_f = imgui.drag_int("intro frames", M.water_intro_f, 1, 1, 2000)
        ch, M.water_end = imgui.drag_int("finish clip", M.water_end, 1, 0, 20000)
        ch, M.water_end_f = imgui.drag_int("finish frames", M.water_end_f, 1, 1, 2000)
        imgui.text(string.format("total ~%.1fs   stage now: %s",
            (M.water_intro_f + M.water_end_f) / 60.0, tostring(wat.stage or "idle")))
        if imgui.button("PLAY the full watering emote") then _water_emote_start() end
        imgui.tree_pop()
    end

    if imgui.tree_node("COOKING & ANIMAL PRODUCE (milk / eggs)") then
        ch, M.cook_emote = imgui.checkbox("stirring emote when cooking (60:6050 stand-in)", M.cook_emote ~= false)
        M.cook_clip = math.floor(tonumber(M.cook_clip) or 6050)
        M.cook_f = math.floor(tonumber(M.cook_f) or 240)
        ch, M.cook_clip = imgui.drag_int("cook clip (bank 60)", M.cook_clip, 1, 0, 20000)
        ch, M.cook_f = imgui.drag_int("cook frames", M.cook_f, 1, 1, 2000)
        if imgui.button("PLAY the cook emote") then
            _chore_start({ { M.cook_bank or 60, M.cook_clip, M.cook_f } }, "cook test")
        end
        imgui.separator()
        ch, M.animal_produce = imgui.checkbox("tend key on an animal = milk / collect eggs", M.animal_produce ~= false)
        imgui.text("Match is by GameObject-NAME tokens. Stand next to the animal,")
        imgui.text("press SCAN, read the log, paste its ch-token into the right box.")
        ch, M.milk_ids = imgui.input_text("MILK name tokens (comma sep)", M.milk_ids or "")
        ch, M.egg_ids = imgui.input_text("EGG name tokens (comma sep)", M.egg_ids or "")
        if imgui.button("SCAN animals nearby (8m) -> log") then
            local list = _scan_animals(8.0)
            _log("animal scan: " .. #list .. " character(s) within 8m")
            for i, a in ipairs(list) do
                if i <= 20 then _log(string.format("  %.1fm  %s", a.dist, a.name)) end
            end
        end
        if imgui.button("PLAY the egg-pickup chain (6020>6022>6023)") then
            _chore_start({ { 60, 6020, 35 }, { 60, 6022, 140 }, { 60, 6023, 90 } }, "egg test")
        end
        if imgui.button("PLAY the milk emote") then
            _chore_start({ { M.milk_bank or 60, M.milk_clip or 6050, M.milk_f or 240 } }, "milk test")
        end
        imgui.text("chore stage now: " .. tostring(chore.stage or "idle"))
        imgui.tree_pop()
    end

    if imgui.tree_node("PLOT SURVEYOR (candidate spots + warp)") then
        ch, M.survey_markers = imgui.checkbox("show candidates on the big map (green)", M.survey_markers ~= false)
        ch, M.prospect = imgui.checkbox("PROSPECTOR: auto-mark flat EMPTY ground while I roam", M.prospect == true)
        imgui.text("(flat + roofless + no gimmick within " .. tostring(M.prospect_gim_r or 30) .. "m, min "
            .. tostring(M.prospect_gap or 120) .. "m apart - ride around and it collects)")
        if imgui.button("SURVEY here (flatness check)") then svy.verdict = _survey_here() end
        if svy.verdict then imgui.text("here: " .. svy.verdict) end
        if imgui.button("mark candidate HERE (manual)") then
            local up = _pupos()
            if up then
                _svy()[#_svy() + 1] = { key = string.format("manual_%d", #_svy() + 1),
                    name = string.format("Manual spot %d", #_svy() + 1),
                    ux = up.x, uy = up.y, uz = up.z, status = "new" }
                _svy_save(); _log("surveyor: manual candidate marked here")
            end
        end
        local upn = _pupos()
        local shown = 0
        for i, sc in ipairs(_svy()) do
            if sc.status == "new" then
                shown = shown + 1
                local dist = -1
                if upn then
                    local dx, dz = (sc.ux or 0) - upn.x, (sc.uz or 0) - upn.z
                    dist = math.sqrt(dx * dx + dz * dz)
                end
                imgui.text(string.format("%s  (%.0fm)", tostring(sc.name), dist))
                imgui.same_line()
                if imgui.button("WARP##svy" .. i) then _svy_warp(sc) end
                imgui.same_line()
                if imgui.button("DISMISS##svy" .. i) then sc.status = "dismissed"; _svy_save() end
            end
        end
        if shown == 0 then imgui.text("no candidates yet - GENERATE, or mark spots manually") end
        if imgui.button("restore ALL dismissed") then
            for _, sc in ipairs(_svy()) do if sc.status == "dismissed" then sc.status = "new" end end
            _svy_save()
        end
        imgui.separator()
        ch, M.monster_guard = imgui.checkbox("MONSTER GUARD: no aggressive spawns near any plot", M.monster_guard ~= false)
        M.monster_guard_r = math.floor(tonumber(M.monster_guard_r) or 120)
        ch, M.monster_guard_r = imgui.drag_int("guard radius (m)", M.monster_guard_r, 5, 30, 400)
        imgui.text(string.format("blocked %d spawn(s), evicted %d squatter(s). Griffins + wildlife exempt.",
            mguard.blocked, mguard.swept))
        ch, M.wake_guard = imgui.checkbox("WAKE-DRIFT GUARD: sleep at the homestead = wake AT the homestead", M.wake_guard ~= false)
        imgui.tree_pop()
    end

    if imgui.tree_node("beds") then
        for i, b in ipairs(beds) do
            local st = _bed_state(b)
            imgui.text(string.format("%d: %s @(%.0f,%.0f) %s", i, b.crop or "(bare soil)", b.ux, b.uz,
                st and string.format("%d/%d days, dry %d%s", b.grown or 0, st.crop.days, b.dry or 0,
                    st.ripe and " RIPE" or (st.wilting and " WILTING" or "")) or ""))
        end
        imgui.tree_pop()
    end

    imgui.tree_pop()
end)

-- bridge: IrisWoodcutting's swing gate calls this when a kind="SOIL" tool lands a swing. The name
-- stays `till` for compatibility, but it's the full context strike: till / sow / water / harvest.
-- `aim` is called the moment the swing ACTION fires, freezing the target before the animation
-- lunges the player forward (see the aim latch above).
-- a script reset mid-emote must not leave the player's FSM disabled (a frozen body with no owner)
re.on_script_reset(function()
    pcall(function()
        local pl = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
        local h = pl:call("get_Human")
        if h and h.Fsm then h.Fsm:set_Enabled(true) end
        -- ⛔⛔ NO BLANKET wp SHOW (Aurora 08-04: "a weird arrow in my hand that I can never get
        -- rid of" - the RiftSpeak bug reborn). Force-showing EVERY wp child also reveals props the
        -- game deliberately keeps hidden (stowed arrows and the like), and nothing ever re-hides
        -- them. Only what the watering hid gets restored, and only by its own end/failure paths;
        -- a reset mid-pour leaves the TOOL hidden until re-equipped - rare and harmless next to
        -- a permanent phantom arrow.
    end)
end)

-- ⚠ `beds` hands back the LIVE table, so callers hold real bed references (IrisPawnIdle relies
--   on that to water the exact bed it walked to). `water` is the pawn-side entry point.
-- ⭐ 08-13 `emote` (Aurora: "a small grab animation for picking up/putting down a weapon on
--   your wall"). IrisWeaponMount drives the SAME sequencer the chores use rather than growing
--   its own FSM freeze - one implementation of the hold/restore means one place a softlock can
--   ever be fixed. Contract: emote(seq, label, on_done) where seq = { {bank, clip, frames}, ... }
--   and on_done fires EXACTLY ONCE on every path (finish, clip failure, or refusal because
--   another emote is running) - so a caller may safely defer real work to it.
_G.IrisFarming = { beds = function() return beds end, save = _save, till = _hoe_strike,
                   aim = _aim_latch, water = pawn_water, emote = _chore_start }
_log(string.format("IrisFarming loaded: %d bed(s), %d crop types, day %s", #beds, #M.crops, tostring(_today())))
