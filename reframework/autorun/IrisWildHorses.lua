-- IrisWildHorses.lua
--
-- I.R.I.S. — Wild Horses: the consolidated horse/doe variant module.
-- Supersedes HorseDoeVariant.lua, HorseDoeLocomotionProbe.lua,
-- HorseFullAudio.lua and the HorseOxSoundProbe routing (retired to
-- autorun_disabled). One panel, everything automatic:
--
--   * a configurable share of newly spawned does become horses
--     (mesh + material + scale swap, proven ScaleMediator spawn hook)
--   * custom walk/trot/gallop locomotion auto-mapped onto horses only
--     (dynamic motion bank 901, proven changeMotion route)
--   * the full 38-event custom Wwise sound set auto-loaded and routed:
--     gait-matched hoofbeats replace doe foot contacts, ALL inherited doe
--     audio is suppressed on horses (catalogue-enumerated, not hand-listed),
--     ambient snorts/nickers while idle, hurt/death from real HP changes,
--     landing sounds after hops. No native sound is replaced globally;
--     real Does are untouched.
--
-- Registry contract (shared with AnimalWwiseRecorder and future modules):
-- _G.__lyra_animal_audio_variants[go_address] =
--     {kind = "horse", game_object, transform, marked_at}

local MOD = "IrisWildHorses"
local CONFIG_FILE = MOD .. ".json"

local DOE_PREFIX = "ch299011"
local HORSE_MESH_PATH = "character/ch/ch99_011/horse.mesh"
local HORSE_MDF_PATH = "character/ch/ch99_011/horse.mdf2"
-- UNICORN body: the horse geometry re-split into body / horn / mane submeshes, paired
-- with a 5-material mdf2 (body_mat, eye_mat, oral_mat=HORN, vfx_mat, mane_mat).
-- Ships in IRIS_08_unicorn.pak. ⛔ Only ever requested when C.unicorn_mesh_enabled is
-- ON, because sdk.create_resource on a path the engine cannot serve is an INSTANT
-- CRASH, not a nil return -- so a missing pak must never be discovered at runtime.
local UNICORN_MESH_PATH = "character/ch/ch99_011/unicorn.mesh"
-- v1.2 mdf2: STILL the vanilla FOUR-material table (adding a 5th is what CTD'd twice), but
-- with body_mat AND oral_mat's BaseDielectricMap repointed to systems/rendering/nullwhite.tex.
-- ⭐ THAT is what finally makes colour work: BaseColor MULTIPLIES the albedo, so against the
-- brown horse texture no value could ever produce white. Against a WHITE albedo, BaseColor
-- can produce any colour at all -- including true white. NormalRoughnessMap is left pointing
-- at the real horse/doe normals, so every bit of muscle and surface detail survives; only the
-- brown pigment is gone.
local UNICORN_MDF_PATH = "character/ch/ch99_011/unicorn.mdf2"
local MOTLIST_PATH = "character/ch/ch99_011/horse_locomotion.motlist"
-- ox-skeleton retarget of the same three gaits (Plan F chassis)
local OX_MOTLIST_PATH = "character/ch/ch99_003/horse_ox_locomotion.motlist"
local CUSTOM_BANK = 901
local LAYER = 0
local MANIFEST_FILE = "HorseAudioManifest.json"
local READY_DELAY_FRAMES = 180

local REGISTRY_KEY = "__lyra_animal_audio_variants"
local REGISTRY = rawget(_G, REGISTRY_KEY) or {}
rawset(_G, REGISTRY_KEY, REGISTRY)
local AUDIO_API_KEY = "__lyra_horse_custom_audio_api"

-- Native bank-0 doe locomotion -> custom horse motions (proven mapping).
local AUTO_MAP = {
    [100] = {id = 1, name = "Horse_Walk"},       -- walk_loop
    [200] = {id = 3, name = "Horse_Gallop"},     -- run_loop
    [206] = {id = 2, name = "Horse_Trot start"}, -- run_start
    [212] = {id = 2, name = "Horse_Trot end"},   -- run_end
}

-- Shared limb-contact trigger channels (same IDs on doe/ox/horse variants).
local FOOT_IDS = {
    [673994548] = true, [2217285698] = true,
    [2372138774] = true, [3009711778] = true,
}
local DOE_LEAP_EFFECT_IDS = {
    [523574438] = true, [1641988791] = true,
    [2219785498] = true, [1558213002] = true,
}
-- Native doe voice triggers: the game fires these when the animal SHOULD
-- vocalise (grabbed, alarmed, fleeing). Replaced with horse vocals so those
-- moments stay voiced instead of muted.
local DOE_VOICE_IDS = {
    [170445746] = true, [298825713] = true, [713062116] = true,
    [1088411087] = true, [1367979266] = true, [1558213002] = true,
}
local REQUEST_SIGNATURE = table.concat({
    "createRequestInfo(soundlib.SoundTriggerInfo, via.GameObject, via.GameObject, ",
    "System.UInt32, System.Boolean, System.Boolean, System.UInt32, ",
    "via.simplewwise.CallbackType, ",
    "System.Action`1<soundlib.SoundManager.RequestInfo>, ",
    "System.Action`1<soundlib.SoundManager.RequestInfo>, ",
    "System.Action`1<soundlib.SoundManager.RequestInfo>, ",
    "System.Action`1<soundlib.SoundManager.RequestInfo>)",
})
local NATIVE_DOE_TRIGGER_IDS = {
    170445746, 298825713, 713062116, 1088411087, 1367979266, 1558213002,
}

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------

local C = {
    enabled = true,
    horse_chance = 0.25,
    horse_scale = 1.75,
    horse_speed = 1.2,
    horse_hp = 1000,
    -- ⛔ CRASH SUSPECTS (2026-08-08): both of these register a CUSTOM MOTLIST as a
    -- dynamic motion bank on a live converted horse, and the 08-08 crashes landed
    -- ~0.8s after exactly that (c0000005 on a motion worker thread). The crash-day
    -- ledger's open suspect was this same resource ("zstd+checksum-0 motlist entry...
    -- possible hollow resource at register_bank"). Turn BOTH off = horses that look
    -- right and walk like does, no custom banks registered anywhere -- the safe mode
    -- AND the bisect (901 vs 902 vs the render swap).
    custom_locomotion_enabled = true,   -- bank 901: walk/trot/gallop gaits
    jump_pack_enabled = true,           -- bank 902: Gallop_Jump / Jump_toIdle / Buck
    -- The multi-trigger Wwise graph passed the live horse isolation run on
    -- 2026-08-05; new installs can use the custom horse bank.
    audio_enabled = true,
    hurt_vocal_min_s = 5,
    hurt_vocal_max_s = 10,
    -- `hurt_*` are very short impact barks. Aurora asked for an audible pained
    -- NEIGH, so damage uses the proper neigh family while retaining the gate.
    hurt_vocal_category = "alert",
    suppress_doe_audio = true,   -- 08-07: the custom voice finally plays
                                 -- (trigger routing) -- doe vocals off
    suppress_vocal_migrated = false,   -- one-shot config migration flag
    ambient_vocal_migrated = false,    -- one-shot: ambient vocals on
    ambient_band_migrated = false,     -- one-shot: 60-120s -> 20-45s
    ambient_enabled = true,   -- 08-07: was NEVER on -- the whole reason
                              -- "no idle sounds at all" (panel proved
                              -- posting healthy; this gate was closed)
    contact_spacing_ms = 45,
    walk_max_speed = 2.5,
    trot_max_speed = 6.0,
    ambient_min_s = 60,
    ambient_max_s = 120,
    -- The doe->climb-rig prefab swap needs its pfb pak (never shippable; the
    -- ch299011_h_00 route was walled July 21). Machinery kept but OFF: no
    -- staging, no GenerateManager hooks unless this is deliberately flipped.
    climb_prefab_swap = false,

    -- UNICORN (Phase 1, 2026-08-10) -- a rare sub-variant of an already-converted
    -- horse. Lua ONLY: no pak, no mesh, no mdf2, no horn. The body stays the same
    -- horse.mesh; only per-instance MATERIAL params and a follower EFX differ, so
    -- a unicorn is registered as kind="horse" with variant="unicorn" beside it.
    -- Every kind=="horse" consumer (~15 across the install) keeps working untouched.
    unicorn_enabled = true,
    unicorn_chance = 0.05,        -- share of HORSES (not of does) that turn unicorn
    unicorn_night_only = true,    -- gates the SPAWN ROLL only; see the panel note
    -- TWO separate emissive systems on Character_Enemy_Default; keeping them on one
    -- slider is what produced the blown-white horse on the first in-game test.
    unicorn_glow = 1.0,           -- RIM light: glows the silhouette, coat stays visible
    -- 08-11: default 0 for the Rapidash look -- a WHITE coat wants no body emission.
    unicorn_body_glow = 0.0,      -- FULL-SURFACE emission: erases the coat past ~0.4
    -- The horn is its own material (oral_mat), so it glows independently of the coat.
    unicorn_horn_glow = 1.4,
    unicorn_mane_glow = 0.9,      -- mane_mat, independent again
    -- ⛔ OFF until IRIS_08_unicorn.pak is installed. Flipping this on without the pak
    -- means create_resource on an unservable path = instant CTD. Default-off is the
    -- only safe default for an asset the script cannot verify from Lua.
    unicorn_mesh_enabled = false,
    -- EXPERIMENT: BaseColor multiplies the albedo so it can only ever DARKEN. MaskColor
    -- may be a colour replace. Untested on this chassis -- build_horse_material.py
    -- deliberately zeroes it. If it works, a white coat costs nothing.
    unicorn_maskcolor = false,
    unicorn_maskcolor_rate = 1.0,
    -- ⛔ v1.1 (stock horse.mdf2) is PROVEN STABLE; every custom-mdf2 build so far has
    -- CTD'd in EyeGlowController.onUpdate regardless of material count. Default OFF =
    -- the safe, working unicorn (dark accents). ON = the white-albedo experiment, now
    -- with the full-tree EyeGlow sweep + a log line proving whether it disabled anything.
    unicorn_custom_mdf = false,
    -- Iridescent shimmer: cycles the EMISSIVE hue while the coat stays white/pink.
    unicorn_rainbow = true,
    unicorn_rainbow_speed = 0.12,  -- full hue cycles per second

    -- SPARKLE. ⛔ NOT a plain .efx path -- Aurora's chosen effect is addressed the way
    -- Nick's devtools Efx player addresses it: an ObjectEffectManager2 external data
    -- CONTAINER (.pfb) + a named element group + an element index. The old
    -- create_resource("via.effect.EffectResource", "<path>.efx") route cannot express
    -- that, so this now uses via.effect.script.ObjectEffectManager2.requestEffect --
    -- which is strictly better anyway: passing the creature as the follow target makes
    -- the ENGINE attach and track it, so there is no per-frame set_Position, no loop
    -- watchdog and no emitter GameObject of ours to leak.
    unicorn_efx_enabled = true,
    -- ch00 = the PLAYER's container, so the request is issued through the PLAYER's
    -- effect manager with the unicorn passed as the follow target (source and target
    -- are separate in the devtools UI for exactly this reason).
    unicorn_efx_container = "VFX/Effects/Character/ch00/13_ch00_Ref.pfb",
    unicorn_efx_element = "104_MagicBook",
    unicorn_efx_index = 2,
    -- Blank = auto-pick a joint that actually exists on the HORSE skeleton.
    -- ⛔ Never default to a player joint name like L_Breast: it does not exist here.
    unicorn_efx_joint = "",
    unicorn_efx_interval = 2.0,   -- re-request cadence (the burst is not a loop)
    unicorn_efx_color = true,     -- tint the sparkle to match the coat / rainbow
    -- ⭐ AUTO-BOLT (08-11): hand-dialling XYZ offsets against a moving head is
    -- hopeless (Aurora, correctly). Measured invariant from the rest pose: the horn
    -- tip sits on the Neck_3→Head_0 line EXTENDED -- tip = N + 3.19*(H - N), within
    -- 2 cm. Both joints are live at runtime, so the offset computes itself every
    -- re-fire, rotates with the head and scales with the body. One slider slides the
    -- sparkle along the horn axis; that is the only control anyone needs.
    unicorn_efx_auto = true,
    unicorn_efx_tip = 1.0,        -- 0 = horn base, 1 = tip, >1 = floating past the tip
    -- Offset from the attach joint. In FOLLOW mode requestEffect's vec3 arg is an
    -- offset, not a world position -- that is the lever for placing the burst.
    unicorn_efx_ox = 0.0,
    unicorn_efx_oy = 0.0,
    unicorn_efx_oz = 0.0,
    unicorn_efx_scale = 1.0,
    -- Seconds/frames of the effect to skip, to cut a smoke intro off the front.
    -- ⚠ Only takes if the effect object exposes a seek method -- "Dump effect API"
    -- in the panel writes the real method list so this can be wired exactly.
    unicorn_efx_skip = 0.0,
    unicorn_reassert_s = 2.0,     -- 0 disables the periodic material re-assert
    -- ⭐ "BASE" HP on purpose (Aurora 08-11): a per-creature Pokémon-style IV
    -- system is planned -- REGISTRY rec.base_hp is the reserved per-creature
    -- override slot; these are the species defaults the damage hook falls to.
    unicorn_hp = 1000.0,
    -- Unicorn Blessing (gather -> thrust -> healing circle).
    blessing_enabled = true,
    blessing_key = 66,            -- VK code; 66 = B
    blessing_range = 5.0,         -- how near the unicorn you must stand to cast
    blessing_radius = 4.0,        -- heal circle radius
    blessing_cooldown = 120.0,    -- per-unicorn seconds
    -- Unicorns are rare: a hunter who kills one instead of taming it gets a
    -- real prize (bonus on top of the native kill award). Aurora 08-11.
    unicorn_kill_exp = 10000,
    -- Aurora's pick 08-11 via NicksDevtools shell caster: jobmagic index 24.
    blessing_shell_idx = 24,
    blessing_shell_path =
        "AppSystem/shell/userdata/humanshellparamdata_jobmagic.user",
}

local function load_config()
    local data = nil
    pcall(function() data = json.load_file(CONFIG_FILE) end)
    if type(data) ~= "table" then return end
    for key, default in pairs(C) do
        if type(default) == "boolean" then
            if data[key] ~= nil then C[key] = data[key] == true end
        elseif type(default) == "string" then
            -- ⛔ 08-10: without this branch the numeric one below runs tonumber() on a
            -- string value, gets nil, and falls back to the DEFAULT on every single
            -- load -- silently erasing the unicorn efx container/element/joint paths
            -- the moment they were saved. These are the module's first string keys.
            if type(data[key]) == "string" then C[key] = data[key] end
        elseif data[key] ~= nil then
            C[key] = tonumber(data[key]) or default
        end
    end
    C.horse_chance = math.max(0.0, math.min(1.0, C.horse_chance))
    -- A hand-edited "unicorn_chance = 5" would otherwise make every night horse a
    -- unicorn; horse_chance has been clamped since day one for the same reason.
    C.unicorn_chance = math.max(0.0, math.min(1.0, C.unicorn_chance))
    C.unicorn_glow = math.max(0.0, math.min(8.0, C.unicorn_glow))
    C.unicorn_body_glow = math.max(0.0, math.min(4.0, C.unicorn_body_glow))
    C.unicorn_horn_glow = math.max(0.0, math.min(6.0, C.unicorn_horn_glow))
    C.unicorn_mane_glow = math.max(0.0, math.min(6.0, C.unicorn_mane_glow))
    C.unicorn_rainbow_speed = math.max(0.0, math.min(3.0, C.unicorn_rainbow_speed))
    C.unicorn_efx_index = math.max(0, math.floor(C.unicorn_efx_index or 0))
    C.unicorn_efx_interval = math.max(0.25, math.min(30.0, C.unicorn_efx_interval))
    -- migration: the old auto-bolt scale ran 1.5-5.0 (line-multiple semantics);
    -- v2 is 0..2 along the actual horn. Old saved values collapse to the tip.
    if C.unicorn_efx_tip > 2.0 then C.unicorn_efx_tip = 1.0 end
    C.unicorn_efx_tip = math.max(0.0, math.min(2.0, C.unicorn_efx_tip))
    C.unicorn_efx_scale = math.max(0.05, math.min(20.0, C.unicorn_efx_scale))
    C.unicorn_efx_skip = math.max(0.0, math.min(300.0, C.unicorn_efx_skip))
    C.unicorn_reassert_s = math.max(0.0, math.min(30.0, C.unicorn_reassert_s))
    C.horse_scale = math.max(0.25, math.min(4.0, C.horse_scale))
    -- 08-07: the old 60-120s floor is GONE -- that spacing was tuned
    -- when the "chatter" was the doe's NATIVE bleats (our vocals never
    -- played pre-routing-fix). Doe muted now, so 60-120s of true
    -- silence read as "no idle sounds at all". Sanity clamps only:
    if C.ambient_min_s < 10 then C.ambient_min_s = 10 end
    if C.ambient_max_s < C.ambient_min_s then
        C.ambient_max_s = C.ambient_min_s + 15
    end
    -- Migration 07-22: horses tank like oxen, stride a touch faster.
    if (C.horse_hp or 0) < 1000 then C.horse_hp = 1000 end
    if C.horse_speed < 1.2 then C.horse_speed = 1.2 end
end

local function save_config()
    pcall(function() json.dump_file(CONFIG_FILE, C) end)
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local S = rawget(_G, "__iris_wild_horses_v1") or {}
rawset(_G, "__iris_wild_horses_v1", S)
S.generation = (S.generation or 0) + 1
local GENERATION = S.generation
S.frame = S.frame or 0
S.status = "initialising"
S.decisions = {}
S.pending_swaps = {}
-- ⛔ 08-10: this was a BOOLEAN `force_next_horse`. It is now a STRING variant name
-- ("horse" | "unicorn" | nil) so that a forced conversion is DETERMINISTIC. The old
-- boolean bypassed only the CHANCE roll in handle_spawn, so any sub-variant sub-roll
-- re-fired on every stable restore and zone load -- a tamed horse could come back a
-- unicorn and a unicorn come back a horse. All 7 former write/read sites updated.
S.force_next_variant = nil
S.force_next_horse = nil   -- retired name, left nil so any stale reader sees false-y
-- Follower-EFX bookkeeping, keyed by unicorn game-object address. PERSISTS across a
-- script reload (same reasoning as S.pins) because the emitter GameObjects outlive the
-- reload: a fresh table would orphan every live sparkle -- the previous generation's
-- frame hook is dead, so they would freeze mid-air and never be reaped.
S.unicorns = S.unicorns or {}
-- Material writes ride their OWN queue. ⛔ They must NOT go into S.pending_swaps: that
-- queue's drain loop feeds every entry to apply_horse(), which would re-run the whole
-- mesh+mdf swap (and its rollback path) on an already-converted horse.
S.pending_materials = {}
S.next_cleanup = 0.0
S.spawned_does = S.spawned_does or 0
S.horse_decisions = S.horse_decisions or 0
S.applied = S.applied or 0
S.failures = S.failures or 0
S.horses = {}
S.next_sample = 0.0
-- staggered-arm bookkeeping restarts every load (a reset mid-session must
-- re-run the whole sequence, since per-load hooks need reinstalling)
S.arm_ready_frame = nil
S.arm_step = nil
S.pins = S.pins or {}
S.audio = {
    registration = nil,
    manifest = nil,
    triggers_by_event = {},
    categories = {},
    last_pick = {},
    template_trigger = nil,
    native_template = nil,
    direct_count = 0,
    next_auto_prepare = 0,
    last_played = nil,
    suppress_set = nil,
    suppressed = 0,
    contacts_replaced = 0,
    pending_contacts = {},
    last_contact = {},
}
S.audio_status = "audio idle"

-- ⛔ The local is NAMED `log`, which shadows REFramework's `log` global — so
-- `log.info` inside the body would index this very function and throw. That is
-- why this module's output never reached re2_framework_log.txt (invisible all
-- of 2026-08-05's crash hunt). Capture the global BEFORE shadowing it.
local reflog = log
local function log(message)
    local line = "[" .. MOD .. "] " .. tostring(message)
    pcall(function() reflog.info(line) end)
    pcall(function() print(line) end)
end

local function valid(object)
    if not object then return false end
    local ok, value = pcall(function() return object:call("get_Valid") end)
    return (not ok) or value ~= false
end

local function object_address(object)
    local address = nil
    pcall(function() address = tonumber(object:get_address()) end)
    return address
end

local function get_component(game_object, type_name)
    if not valid(game_object) then return nil end
    local component = nil
    pcall(function()
        component = game_object:call(
            "getComponent(System.Type)", sdk.typeof(type_name))
    end)
    return valid(component) and component or nil
end

local function collection_count(collection)
    local count = nil
    if collection then
        pcall(function() count = collection:call("get_Count") end)
        if count == nil then pcall(function() count = collection:get_Count() end) end
    end
    return tonumber(count) or 0
end

local function normal_u32(value)
    value = tonumber(value)
    if not value then return nil end
    if value < 0 then value = value + 0x100000000 end
    return value
end

-- ---------------------------------------------------------------------------
-- UNICORN (Phase 1, 2026-08-10) -- material recolour + follower sparkle.
-- ⚠ Everything hangs off ONE local table on purpose: Lua caps a scope at 200
-- locals and this file is already dense (the same reason IrisWoodcutting parks
-- chip_fx_live on _G). A table of functions costs one local instead of a dozen.
-- ---------------------------------------------------------------------------

local UNI = {
    hash_method = nil,     -- nil = untried, false = unavailable, else the method
    hashes = {},
    efx_ids = nil,         -- cached {container_index, container_id} lookup
    efx_ids_key = nil,     -- the container|element string that cache belongs to
    pl_mgr = nil,          -- the PLAYER's ObjectEffectManager2 (owns the ch00 pfb)
    pl_mgr_go = nil,       -- its GameObject, revalidated before the cache is trusted
    efx_status = "efx idle",
    last_writes = 0,
    last_attempted = 0,
    last_write_detail = "no write yet",
}

-- ✅ 2026-08-10 FIELD-CONFIRMED on a live ch99_011: 22/22 params landed, so every
-- name below is correct AND setMaterialFloat works on via.render.Mesh (it was
-- unproven -- IrisWildCats only ever writes float4s).
--
-- ⛔ FIRST IN-GAME RESULT: a pure white blown-out silhouette, no coat visible at all
-- (Aurora). The ground bounce was correctly violet, so the COLOUR was right and the
-- INTENSITY was ~10x too hot -- the body was clipping to white. Root cause was
-- design, not tuning: this shader has TWO independent emissive systems and the wrong
-- one was carrying the effect.
--   * Emissive_*        = FULL-BODY emission. Turns the whole surface into a light
--                         source, which erases albedo, shading and form. Subtle only.
--   * RimLight_Emissive_* = SILHOUETTE-EDGE emission. Glows the rim and leaves the lit
--                         surface intact. THIS is the "magical creature" read, and it
--                         is now the primary effect.
-- Colours are kept <= 1.0 (they were 1.65-2.60, already clipping before any intensity
-- multiplier was applied on top).
-- ✅ 2nd in-game pass (Aurora): rim 0.00 / body 0.67 read as a SOLID coloured horse with
-- form and shading intact -- so body glow is the right lever after all, it just needed
-- sane scaling. Direction chosen from that shot: white/pink coat with a rainbow shimmer.
-- ⭐ Galarian-Rapidash target (Aurora's ref, 08-11): WHITE coat, dark indigo horn with a
-- glow, pastel mane. The mane is NOT reachable yet -- it is welded into the body shell
-- (one 15,837-vert part) and all four material slots are spoken for, so a pastel mane
-- needs a geometry split PLUS a fifth material (i.e. a custom unicorn.mdf2).
UNI.BODY_COLOR = {1.00, 1.00, 1.00, 1.0}   -- white coat
UNI.HORN_COLOR = {0.30, 0.14, 0.46, 1.0}   -- dark indigo horn
UNI.MANE_COLOR = {0.72, 0.96, 0.92, 1.0}   -- pale mint mane/tail (pink comes from
                                           -- the shimmer riding its emissive)
UNI.GLOW_COLOR = {0.62, 0.34, 0.95, 1.0}   -- violet emissive (when rainbow is OFF)
UNI.RIM_COLOR  = {0.62, 0.72, 1.00, 1.0}   -- cool silhouette light

-- Hue cycling for the iridescent look. s/v of 1 keeps it saturated; the caller scales.
function UNI.hsv(hue, sat, val)
    hue = hue % 1.0
    local i = math.floor(hue * 6.0)
    local f = hue * 6.0 - i
    local p = val * (1.0 - sat)
    local q = val * (1.0 - f * sat)
    local t = val * (1.0 - (1.0 - f) * sat)
    local m = i % 6
    if m == 0 then return {val, t, p, 1.0}
    elseif m == 1 then return {q, val, p, 1.0}
    elseif m == 2 then return {p, val, t, 1.0}
    elseif m == 3 then return {p, q, val, 1.0}
    elseif m == 4 then return {t, p, val, 1.0}
    else return {val, p, q, 1.0} end
end

-- The live emissive colour: a rainbow sweep, or the fixed pink. Saturation is held
-- below 1 so the coat reads pearlescent rather than poster-paint.
function UNI.glow_color()
    if not C.unicorn_rainbow then return UNI.GLOW_COLOR end
    return UNI.hsv(os.clock() * (C.unicorn_rainbow_speed or 0.12), 0.55, 1.0)
end

function UNI.scaled(rgba, k)
    return {rgba[1] * k, rgba[2] * k, rgba[3] * k, rgba[4] or 1.0}
end

-- Re-fetched per call rather than cached: this only runs when a doe spawns, and a
-- cached managed singleton goes stale across a title-screen return. FAILS CLOSED --
-- if the API ever moves we get no unicorns, rather than unicorns everywhere.
-- Is this body the ACTIVE stable companion? Used to keep the panel's global force flag
-- away from a body whose identity belongs to the stable record.
function UNI.is_companion_body(game_object)
    if not valid(game_object) then return false end
    local same = false
    pcall(function()
        local bridge = rawget(_G, "IrisGriffinBridge")
        local character = bridge and bridge.griffin and bridge.griffin()
        local go = character and character:call("get_GameObject")
        if valid(go) then
            same = object_address(go) == object_address(game_object)
        end
    end)
    return same
end

function UNI.is_night()
    local night = false
    pcall(function()
        local tm = sdk.get_managed_singleton("app.TimeManager")
        if tm then night = tm:call("isNight") == true end
    end)
    return night
end

function UNI.hash(name)
    if UNI.hash_method == nil then
        local found = nil
        pcall(function()
            found = sdk.find_type_definition("via.murmur_hash")
                :get_method("calc32(System.String)")
        end)
        -- false is the "tried and failed" sentinel. Leaving it nil on failure would
        -- re-enter this branch (and re-log) on every single variable lookup.
        UNI.hash_method = found or false
        if not found then
            log("unicorn: via.murmur_hash.calc32 unavailable -- every material "
                .. "write will no-op (this is IrisWildCats' hash dependency)")
        end
    end
    if not UNI.hash_method then return nil end
    if UNI.hashes[name] == nil then
        pcall(function() UNI.hashes[name] = UNI.hash_method:call(nil, name) end)
    end
    return UNI.hashes[name]
end

-- Bounds-checked lookup, ported from IrisWildCats set_float4. A variable index
-- outside [0, getMaterialVariableNum) must never reach a setter.
function UNI.var_index(mesh, material_index, variable_name)
    local name_hash = UNI.hash(variable_name)
    if not name_hash then return -1 end
    local variable_index, variable_count = -1, 0
    pcall(function()
        variable_index = tonumber(mesh:call("getMaterialVariableIndex",
            material_index, name_hash)) or -1
        variable_count = tonumber(mesh:call("getMaterialVariableNum",
            material_index)) or 0
    end)
    if variable_index < 0 or variable_index >= variable_count then return -1 end
    return variable_index
end

function UNI.set_float4(mesh, material_index, variable_name, values)
    local vi = UNI.var_index(mesh, material_index, variable_name)
    if vi < 0 then return false end
    return (pcall(function()
        mesh:call("setMaterialFloat4", material_index, vi,
            Vector4f.new(values[1], values[2], values[3], values[4] or 1.0))
    end))
end

-- ⚠ setMaterialFloat's existence and arity on via.render.Mesh are NOT proven in
-- this install (IrisWildCats only ever writes float4s). If the signature differs
-- these return false and show up as a shortfall in the logged write count -- they
-- cannot crash, and every float4 write still lands.
function UNI.set_float(mesh, material_index, variable_name, value)
    local vi = UNI.var_index(mesh, material_index, variable_name)
    if vi < 0 then return false end
    return (pcall(function()
        mesh:call("setMaterialFloat", material_index, vi, value)
    end))
end

-- Returns writes, attempted. writes == 0 means the material was not resident yet
-- (or the names are wrong) -- the caller retries on that.
function UNI.apply_material(game_object)
    local writes, attempted, missed = 0, 0, {}
    pcall(function()
        local mesh = get_component(game_object, "via.render.Mesh")
        if not mesh then return end
        local count = tonumber(mesh:call("get_MaterialNum")) or 0
        -- rim = the silhouette glow (the star); body = full-surface emission, which
        -- is what blew the coat out on the first in-game test. Independent sliders.
        local glow = C.unicorn_glow or 1.0
        local body_glow = C.unicorn_body_glow or 0.0
        local glow_rgba = UNI.scaled(UNI.glow_color(), body_glow)
        local rim_rgba = UNI.scaled(UNI.RIM_COLOR, glow)
        for mi = 0, count - 1 do
            local name = tostring(mesh:call("getMaterialName", mi) or "")
            -- horse.mdf2 ships body_mat / eye_mat / oral_mat / vfx_mat. Recolour the
            -- coat and the muzzle; leave the eye and the vfx emitter alone.
            local is_horn = name:find("oral_mat") ~= nil
            local is_mane = name:find("mane_mat") ~= nil
            if name:find("body_mat") or is_horn or is_mane then
                -- ⭐ THREE INDEPENDENT PARTS on unicorn.mesh: the coat (body_mat), the
                -- HORN (oral_mat -- an unused 1-tri dummy slot on a plain horse) and the
                -- MANE+TAIL (mane_mat, the 5th material added to unicorn.mdf2). All three
                -- run Character_Enemy_Default, so each takes the identical param set on
                -- its own addressable slot.
                -- ⭐ v1.3: with the PAINTED Rapidash texture active, the colours live in
                -- the pixels -- BaseColor must be pure white on every part or it would
                -- MULTIPLY against the pastels (indigo tint x teal mane = mud). Without
                -- the texture (safe mode), the runtime tints carry the look as before.
                local painted = C.unicorn_custom_mdf
                local base_rgba = painted and {1.0, 1.0, 1.0, 1.0}
                    or (is_horn and UNI.HORN_COLOR)
                    or (is_mane and UNI.MANE_COLOR) or UNI.BODY_COLOR
                local emit_amt = (is_horn and (C.unicorn_horn_glow or 0.0))
                    or (is_mane and (C.unicorn_mane_glow or 0.0)) or body_glow
                local emit_rgba = UNI.scaled(UNI.glow_color(), emit_amt)
                local float4s = {
                    {"BaseColor", base_rgba},
                    -- ⛔ NO UNDERSCORE. body_mat runs Character_Enemy_Default, whose
                    -- emissives are EmissiveColor1/2. The underscored Emissive_Color1/2
                    -- that IrisWildCats writes belong to Character_Enemy_EYE and would
                    -- silently resolve to index -1 here.
                    {"EmissiveColor1", emit_rgba},
                    {"EmissiveColor2", emit_rgba},
                    {"RimLight_Emissive_Color_A", rim_rgba},
                    {"RimLight_Emissive_Color_B", rim_rgba},
                }
                for _, pair in ipairs(float4s) do
                    attempted = attempted + 1
                    if UNI.set_float4(mesh, mi, pair[1], pair[2]) then
                        writes = writes + 1
                    else
                        missed[#missed + 1] = pair[1]
                    end
                end
                local floats = {
                    -- Full-body emission OFF unless explicitly dialled up. At the old
                    -- 1.4x it clipped the entire horse to white even with the slider
                    -- pulled down to 0.64. The HORN is free to burn much brighter --
                    -- it is a small surface, so it reads as a glow, not a blowout.
                    {"Emissive_Enable", (emit_amt > 0.001) and 1.0 or 0.0},
                    {"Emissive_Intensity", 0.22 * emit_amt},
                    -- The silhouette glow -- this one is meant to be seen.
                    {"Use_RimLightEmissive", 1.0},
                    {"RimLight_Emissive_intensity", 0.9 * glow},
                    -- a touch of gloss on the horn reads as crystalline/polished
                    {"Metallic", is_horn and 0.35 or 0.0},
                    -- horn polished, mane soft and hair-like, coat in between
                    {"Roughness", (is_horn and 0.18) or (is_mane and 0.60) or 0.40},
                }
                for _, pair in ipairs(floats) do
                    attempted = attempted + 1
                    if UNI.set_float(mesh, mi, pair[1], pair[2]) then
                        writes = writes + 1
                    else
                        missed[#missed + 1] = pair[1]
                    end
                end
                -- ⛔⛔ 08-11 CORRECTION: BaseColor MULTIPLIES the albedo texture. On a
                -- brown horse, BaseColor {1,1,1} means "unchanged" and there is NO value
                -- that can lighten it -- a white coat is simply not reachable that way.
                -- (Every colour we have seen so far was EMISSIVE, not BaseColor.)
                -- MaskColor may be a colour REPLACE rather than a multiply.
                -- build_horse_material.py deliberately zeroes it, so this is the first
                -- time it has ever been driven on this chassis. Free to test, and if it
                -- works the white coat costs nothing.
                if C.unicorn_maskcolor then
                    for _, pair in ipairs({
                        {"MaskColor_Enable", 1.0},
                        {"MaskColor_BlendRate", C.unicorn_maskcolor_rate or 1.0},
                        {"MaskColor_BlendMode", 0.0},
                    }) do
                        attempted = attempted + 1
                        if UNI.set_float(mesh, mi, pair[1], pair[2]) then
                            writes = writes + 1
                        else missed[#missed + 1] = pair[1] end
                    end
                    attempted = attempted + 1
                    if UNI.set_float4(mesh, mi, "MaskColor", base_rgba) then
                        writes = writes + 1
                    else missed[#missed + 1] = "MaskColor" end
                end
            end
        end
    end)
    UNI.last_writes, UNI.last_attempted = writes, attempted
    UNI.last_write_detail = (#missed > 0)
        and ("missed: " .. table.concat(missed, ", "))
        or "every param landed"
    return writes, attempted
end

-- ⛔⛔ 08-10: re-running setMesh/set_Material does NOT undo per-instance
-- setMaterialFloat4 writes -- the params live on the mesh's material INSTANCE, not on
-- the shared resource, so re-assigning the same resource leaves every override in
-- place. The demote path relied on that and left Chad a frozen unicorn. A revert has
-- to write the stock values back EXPLICITLY.
-- Stock values are the ones tools\build_horse_material.py bakes into horse.mdf2:
-- BaseColor [1,1,1,1], Metallic 0.0, Roughness 1.0, no emissive.
function UNI.reset_material(game_object)
    local writes = 0
    pcall(function()
        local mesh = get_component(game_object, "via.render.Mesh")
        if not mesh then return end
        local count = tonumber(mesh:call("get_MaterialNum")) or 0
        local black = {0.0, 0.0, 0.0, 1.0}
        for mi = 0, count - 1 do
            local name = tostring(mesh:call("getMaterialName", mi) or "")
            if name:find("body_mat") or name:find("oral_mat")
                or name:find("mane_mat") then
                for _, pair in ipairs({
                    {"BaseColor", {1.0, 1.0, 1.0, 1.0}},
                    {"EmissiveColor1", black}, {"EmissiveColor2", black},
                    {"RimLight_Emissive_Color_A", black},
                    {"RimLight_Emissive_Color_B", black},
                }) do
                    if UNI.set_float4(mesh, mi, pair[1], pair[2]) then
                        writes = writes + 1
                    end
                end
                for _, pair in ipairs({
                    {"Emissive_Enable", 0.0}, {"Emissive_Intensity", 0.0},
                    {"Use_RimLightEmissive", 0.0},
                    {"RimLight_Emissive_intensity", 0.0},
                    {"Metallic", 0.0}, {"Roughness", 1.0},
                }) do
                    if UNI.set_float(mesh, mi, pair[1], pair[2]) then
                        writes = writes + 1
                    end
                end
            end
        end
    end)
    return writes
end

-- Promote a LIVE horse to unicorn. ⛔ Must queue BOTH a mesh re-swap (horn + split-mane
-- geometry) and the material write -- the three promote paths originally queued only the
-- material, which leaves a recoloured but HORNLESS horse. Ordering matters: the mesh swap
-- runs first (due now) and the material 0.1 s later, because set_Material resets every
-- per-instance param we are about to write.
function UNI.queue_promote(address, game_object)
    local rec = S.unicorns[address]
        or {game_object = game_object, next_efx = 0.0, next_reassert = 0.0}
    rec.game_object = game_object
    S.unicorns[address] = rec
    local now = os.clock()
    if C.unicorn_mesh_enabled then
        local tf = nil
        pcall(function() tf = game_object:call("get_Transform") end)
        if valid(tf) then
            S.pending_swaps[#S.pending_swaps + 1] = {
                go = game_object, transform = tf, due = now,
                attempts = 0, variant = "unicorn"}
        end
    end
    S.pending_materials[#S.pending_materials + 1] = {
        go = game_object, address = address, due = now + 0.10, attempts = 0}
end

-- Rainbow tick. Writes ONLY the two emissive colours -- the full apply_material walk
-- (11 params x 2 materials, each a murmur hash + two managed calls) has no business
-- running at animation rate. Silent by design: it must never spam the log.
function UNI.tint(game_object)
    local body_glow = C.unicorn_body_glow or 0.0
    local horn_glow = C.unicorn_horn_glow or 0.0
    local mane_glow = C.unicorn_mane_glow or 0.0
    if body_glow <= 0.001 and horn_glow <= 0.001 and mane_glow <= 0.001 then return end
    local hue = UNI.glow_color()
    local body_rgba = UNI.scaled(hue, body_glow)
    local horn_rgba = UNI.scaled(hue, horn_glow)
    local mane_rgba = UNI.scaled(hue, mane_glow)
    pcall(function()
        local mesh = get_component(game_object, "via.render.Mesh")
        if not mesh then return end
        local count = tonumber(mesh:call("get_MaterialNum")) or 0
        for mi = 0, count - 1 do
            local name = tostring(mesh:call("getMaterialName", mi) or "")
            local is_horn = name:find("oral_mat") ~= nil
            local is_mane = name:find("mane_mat") ~= nil
            if name:find("body_mat") or is_horn or is_mane then
                -- With the coat white and body_glow 0, the shimmer lands on the HORN and
                -- the MANE -- which is exactly the Rapidash read.
                local rgba = (is_horn and horn_rgba)
                    or (is_mane and mane_rgba) or body_rgba
                UNI.set_float4(mesh, mi, "EmissiveColor1", rgba)
                UNI.set_float4(mesh, mi, "EmissiveColor2", rgba)
            end
        end
    end)
end

-- ---------------------------------------------------------------------------
-- SPARKLE via ObjectEffectManager2.requestEffect (the route Nick's devtools Efx
-- player uses; read-only reference, that mod is never edited).
-- ⭐ Passing the creature as the FOLLOW TARGET makes the engine attach and track the
-- effect itself: no per-frame set_Position, no loop watchdog, and no emitter
-- GameObject of ours that could leak across a zone transition. Teardown is
-- container:finishAll().
-- ---------------------------------------------------------------------------

function UNI.effect_manager(game_object)
    if not valid(game_object) then return nil end
    return get_component(game_object, "via.effect.script.ObjectEffectManager2")
        or get_component(game_object, "via.effect.script.ObjectEffectManager")
end

-- The container we want (ch00) lives on the PLAYER's manager, not the horse's, so the
-- request is issued through the player and merely aimed at the unicorn.
function UNI.player_manager()
    if valid(UNI.pl_mgr_go) and UNI.pl_mgr then return UNI.pl_mgr end
    UNI.pl_mgr, UNI.pl_mgr_go = nil, nil
    pcall(function()
        -- ⛔ get_ManualPlayer lives on app.CharacterManager, NOT app.PlayerManager.
        -- Guessing the wrong singleton here made player_manager() return nil, which
        -- made spawn_efx bail silently -- the "sparkles never appeared" bug, 08-10.
        -- Every other IRIS/third-party file resolves the player this exact way.
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local pl = cm and cm:call("get_ManualPlayer")
        local go = pl and pl:call("get_GameObject")
        if valid(go) then
            UNI.pl_mgr, UNI.pl_mgr_go = UNI.effect_manager(go), go
        end
    end)
    return UNI.pl_mgr
end

-- Resolve the panel's container path + element NAME into the numeric triple
-- requestEffect wants. Cached: the walk enumerates a managed dictionary.
function UNI.resolve_effect_id()
    if UNI.efx_ids and UNI.efx_ids_key == (C.unicorn_efx_container .. "|"
        .. C.unicorn_efx_element) then
        return UNI.efx_ids
    end
    local mgr = UNI.player_manager()
    if not mgr then
        UNI.efx_status = "efx: player effect manager not found yet"
        return nil
    end
    local found = nil
    pcall(function()
        local containers = mgr.ExternalDataContainers
        local total = collection_count(containers)
        for ci = 0, total - 1 do
            local path = ""
            pcall(function()
                path = tostring(containers[ci].DataContainer:get_Path() or "")
            end)
            if path:lower() == tostring(C.unicorn_efx_container):lower() then
                local map = containers[ci].StandardDataMap
                local enumerator = map:GetEnumerator()
                while enumerator:MoveNext() do
                    local entry = enumerator:get_Current()
                    local name = ""
                    pcall(function()
                        name = tostring(
                            entry.value:get_GameObject():get_Name() or "")
                    end)
                    if name == tostring(C.unicorn_efx_element) then
                        found = {container_index = ci, container_id = entry.key,
                                 element_name = name, container_path = path}
                        return
                    end
                end
                return
            end
        end
    end)
    UNI.efx_ids = found
    UNI.efx_ids_key = C.unicorn_efx_container .. "|" .. C.unicorn_efx_element
    UNI.efx_status = found
        and ("efx resolved: container " .. found.container_index
             .. " / id " .. tostring(found.container_id))
        or ("efx NOT resolved -- no container '" .. tostring(C.unicorn_efx_container)
            .. "' with element '" .. tostring(C.unicorn_efx_element) .. "'")
    return found
end

-- ⛔ A player joint name (L_Breast etc.) does NOT exist on the doe/horse skeleton.
-- Pick one that actually does, preferring something high on the body.
function UNI.pick_joint(game_object)
    if tostring(C.unicorn_efx_joint or "") ~= "" then return C.unicorn_efx_joint end
    local chosen, first = nil, nil
    pcall(function()
        local joints = game_object:call("get_Transform"):call("get_Joints")
        local total = collection_count(joints)
        -- ⛔⛔ Attach to the bone that actually DRIVES THE HORN, not the one named "Head".
        -- Measured on this mesh: every vertex within 5.5 cm of the horn base is 100%
        -- Neck_3 and ZERO Head_0 -- the horse was nearest-surface transferred onto the
        -- SMALLER doe skeleton, so its face landed over the neck bones. Picking Head_0
        -- made the sparkle drift off the horn whenever the head moved: the exact same
        -- divergence that made the HORN ITSELF float before it was reweighted.
        -- ⇒ Neck_3 first, so the sparkle and the horn share one driver and cannot part.
        local want = {"neck_3", "neck", "head", "spine", "hip", "root"}
        for _, needle in ipairs(want) do
            for ji = 0, total - 1 do
                local name = tostring(joints[ji]:call("get_Name") or "")
                if first == nil and name ~= "" then first = name end
                if name:lower():find(needle, 1, true) then
                    chosen = name
                    return
                end
            end
        end
    end)
    return chosen or first
end

-- Rotate v by quaternion q (pure math -- no engine API to guess at): v' = v + w*t + q×t
-- where t = 2*(q×v). conj=true rotates by the inverse (unit quaternion conjugate).
function UNI.qrot(q, v, conj)
    local qx, qy, qz, qw = q.x, q.y, q.z, q.w
    if conj then qx, qy, qz = -qx, -qy, -qz end
    local tx = 2.0 * (qy * v.z - qz * v.y)
    local ty = 2.0 * (qz * v.x - qx * v.z)
    local tz = 2.0 * (qx * v.y - qy * v.x)
    return Vector3f.new(
        v.x + qw * tx + (qy * tz - qz * ty),
        v.y + qw * ty + (qz * tx - qx * tz),
        v.z + qw * tz + (qx * ty - qy * tx))
end

function UNI.kill_efx(address)
    local entry = S.unicorns[address]
    if not entry then return end
    if entry.container then
        -- ⛔ 08-11: finishAll is the SOFT stop -- "stop emitting, let live particles
        -- decay". A LOOPING element (11) ignores it, so the first container survived
        -- every "re-fire" forever, frozen at its birth position -- which is why no
        -- slider ever visibly did anything. killAll is the hard kill.
        local killed = pcall(function() entry.container:call("killAll") end)
        if not killed then
            pcall(function() entry.container:call("finishAll") end)
        end
    end
    entry.container = nil
end

function UNI.spawn_efx(address)
    local entry = S.unicorns[address]
    if not (entry and C.unicorn_efx_enabled) then return false end
    -- Each failure sets efx_status: a silent bail is how the first version hid a
    -- wrong-singleton bug for a whole test cycle. The panel names the failing step.
    local mgr = UNI.player_manager()
    if not mgr then
        UNI.efx_status = "efx: no ObjectEffectManager2 on the player yet"
        return false
    end
    local ids = UNI.resolve_effect_id()   -- sets its own status on failure
    if not ids then return false end
    local target = entry.game_object
    if not valid(target) then
        UNI.efx_status = "efx: unicorn body went invalid"
        return false
    end
    local joint = entry.joint or UNI.pick_joint(target)
    if not joint then
        UNI.efx_status = "efx: found no joint on the horse skeleton"
        return false
    end
    entry.joint = joint

    -- Re-requesting without stopping the previous one stacks emitters forever.
    UNI.kill_efx(address)

    local container = nil
    pcall(function()
        local effect_id = sdk.create_instance("via.effect.script.EffectID")
        effect_id.ContainerID = ids.container_id
        effect_id.ElementID = C.unicorn_efx_index or 0
        effect_id.DataContainerIndex = ids.container_index
        effect_id.IsContainerIDOnly = false
        effect_id.IsElementIDOnly = false
        local transform = target:call("get_Transform")
        local rotation = transform:call("get_Rotation")
        -- ⭐ "BOLT IT TO THE HORN" (Aurora, after the first head-turn): follow mode
        -- tracks the joint's POSITION but the offset vec3 stays fixed in WORLD
        -- orientation -- so a dipped head swings the horn away from the sparkle.
        -- Fix: capture the dialled offset in JOINT-LOCAL space once (against the
        -- joint's rotation at calibration), then re-express it through the joint's
        -- CURRENT rotation on every re-fire. At the panel's re-fire cadence the
        -- sparkle re-glues itself continuously, so it turns WITH the head.
        local off = Vector3f.new(C.unicorn_efx_ox or 0.0, C.unicorn_efx_oy or 0.0,
            C.unicorn_efx_oz or 0.0)
        if C.unicorn_efx_auto then
            -- ⭐⭐ AUTO-BOLT v2 -- EXACT, from the armature. v1 approximated the horn
            -- as the extended Neck_3→Head_0 line; wrong, because Head_0 bends
            -- independently of Neck_3 while the horn is RIGID to Neck_3, and the
            -- doe joints don't sit where the horse's visible anatomy is.
            -- Blender ground truth (rest pose, Neck_3's own frame -- the horn runs
            -- along the joint's local X): base (0.16901, 0.01193, 0),
            -- tip (0.36662, -0.01930, 0). Reprojection verified to the mm.
            -- Runtime: point = lerp(base,tip,t) * body_scale rotated by the joint's
            -- LIVE rotation = a world offset from the joint that is exact in every
            -- pose. Recomputed each re-fire, so it stays glued through head motion.
            pcall(function()
                local jn = transform:call("getJointByName(System.String)", "Neck_3")
                if jn then
                    local q = jn:call("get_Rotation")
                    local t = C.unicorn_efx_tip or 1.0
                    local s = C.horse_scale or 1.0
                    local lx = (0.16901 + (0.36662 - 0.16901) * t) * s
                    local ly = (0.01193 + (-0.01930 - 0.01193) * t) * s
                    -- 08-11 v3: the trim is applied in WORLD axes. v2 used the horse-
                    -- body frame, and four spawns proved that wrong: the error swung
                    -- with each horse's FACING (right of eye / horn base / tip / left
                    -- of snout, same numbers), because element 11's authored particle
                    -- cloud is WORLD-fixed -- it ignores the rotation argument -- so a
                    -- body-rotating compensation points a different compass direction
                    -- per horse. A world-frame trim cancels a world-fixed offset
                    -- identically for every horse. (If misplacement now varies with
                    -- the CAMERA instead, the cloud is billboard/camera-authored and
                    -- no static trim can pin it -- pick a different element then.)
                    off = UNI.qrot(q, Vector3f.new(lx, ly, 0.0), false)
                    off = Vector3f.new(
                        off.x + (C.unicorn_efx_ox or 0.0),
                        off.y + (C.unicorn_efx_oy or 0.0),
                        off.z + (C.unicorn_efx_oz or 0.0))
                    joint = "Neck_3"
                    entry.joint = joint
                    pcall(function()
                        local jp = jn:call("get_Position")
                        R.efx_bolt_debug = string.format(
                            "bolt: Neck_3 world (%.1f, %.1f, %.1f) | anchor+trim"
                            .. " world off (%.2f, %.2f, %.2f)",
                            jp.x, jp.y, jp.z, off.x, off.y, off.z)
                    end)
                end
            end)
        else
            pcall(function()
                local jj = transform:call("getJointByName(System.String)", joint)
                local jr = jj and jj:call("get_Rotation")
                if jr then
                    local key = string.format("%.3f|%.3f|%.3f", off.x, off.y, off.z)
                    if entry.off_key ~= key or not entry.local_off then
                        -- sliders moved (or first fire): what the user SEES now is the
                        -- truth -- capture it relative to the joint's current rotation
                        entry.local_off = UNI.qrot(jr, off, true)
                        entry.off_key = key
                    end
                    off = UNI.qrot(jr, entry.local_off, false)
                end
            end)
        end
        container = mgr:call(
            "requestEffect(via.effect.script.EffectID, via.vec3, via.Quaternion, "
            .. "via.GameObject, System.String, "
            .. "via.effect.script.EffectManager.WwiseTriggerInfo)",
            effect_id,
            off,
            rotation,
            target,                  -- the ENGINE tracks this GameObject
            joint,
            nil)
    end)
    entry.container = container
    entry.mp_cleared = nil   -- a fresh container needs MaintainPosition cleared again
    if not container then
        UNI.efx_status = string.format(
            "efx: requestEffect returned nil (dcIndex %s / id %s / element %s / joint %s)",
            tostring(ids.container_index), tostring(ids.container_id),
            tostring(C.unicorn_efx_index), tostring(joint))
        return false
    end
    UNI.efx_status = string.format("efx firing: element %s at joint %s",
        tostring(C.unicorn_efx_index), tostring(joint))
    UNI.apply_effect_extras(container)
    if container and C.unicorn_efx_color then
        -- Tint to match the coat, so the sparkle rides the rainbow too.
        pcall(function() UNI.tint_effect(container, UNI.glow_color()) end)
    end
    entry.next_efx = os.clock() + (C.unicorn_efx_interval or 2.0)
    return container ~= nil
end

-- effect:set_Color wants a via.Color of BYTES, not floats.
-- ⛔⛔ 08-10, THE INVISIBLE-SPARKLE BUG: this used colour:call("set_r", ...). On a
-- ValueType that silently no-ops, leaving the via.Color ZERO-INITIALISED -- which is
-- TRANSPARENT BLACK. set_Color then rendered the effect invisible while
-- requestEffect had genuinely succeeded and every status line said "efx firing".
-- NicksDevtools uses DIRECT property calls (c:set_r(...)); so do we now, and the
-- colour is only applied if it was actually built.
function UNI.tint_effect(container, rgba)
    local entries = container.CreatedEffects and container.CreatedEffects._entries
    local value = entries and entries[0] and entries[0].value
    local effect = value and value._items and value._items[0]
    if not effect then return false end
    local ok_valid = false
    pcall(function() ok_valid = effect:get_Valid() ~= false end)
    if not ok_valid then return false end
    local built, colour = false, nil
    pcall(function()
        colour = ValueType.new(sdk.find_type_definition("via.Color"))
        colour:set_r(math.floor(math.min(1.0, math.max(0.0, rgba[1])) * 255))
        colour:set_g(math.floor(math.min(1.0, math.max(0.0, rgba[2])) * 255))
        colour:set_b(math.floor(math.min(1.0, math.max(0.0, rgba[3])) * 255))
        colour:set_a(255)
        built = true
    end)
    -- Never push a colour we could not build -- that is exactly how the effect went
    -- invisible. Untinted-but-visible beats tinted-and-gone.
    if not built then
        UNI.tint_failed = true
        return false
    end
    local applied = pcall(function() effect:set_Color(colour) end)
    UNI.tint_failed = not applied
    return applied
end

-- Reach the live effect object inside a returned container.
function UNI.container_effect(container)
    local effect = nil
    pcall(function()
        local entries = container.CreatedEffects and container.CreatedEffects._entries
        local value = entries and entries[0] and entries[0].value
        effect = value and value._items and value._items[0]
    end)
    return effect
end

-- Ask the TYPE whether a method exists before calling it. pcall alone is a poor test
-- (a missing method and a method that threw look identical), and this whole subsystem
-- has already lost a test cycle to a silent no-op.
function UNI.has_method(object, name)
    local has = false
    pcall(function()
        has = object:get_type_definition():get_method(name) ~= nil
    end)
    return has
end

-- Scale + intro-skip. Both are BEST EFFORT: the exact method names on this effect type
-- are unverified, so each is probed against the type and the panel reports which one
-- actually took. Use "Dump effect API" to get the real list if these all miss.
function UNI.apply_effect_extras(container)
    local applied, missed = {}, {}
    local effect = UNI.container_effect(container)
    if not effect then
        UNI.efx_extras = "no effect object in container"
        return
    end
    local scale = C.unicorn_efx_scale or 1.0
    if math.abs(scale - 1.0) > 0.001 then
        local done = nil
        for _, name in ipairs({"set_Scale", "setScale", "set_EffectScale"}) do
            if not done and UNI.has_method(effect, name) then
                if pcall(function() effect:call(name, scale) end) then done = name end
            end
        end
        if not done then
            -- fall back to the effect's own GameObject transform
            pcall(function()
                local go = effect:call("get_GameObject")
                local tf = go and go:call("get_Transform")
                if tf then
                    tf:call("set_LocalScale", Vector3f.new(scale, scale, scale))
                    done = "transform.set_LocalScale"
                end
            end)
        end
        if done then applied[#applied + 1] = "scale=" .. done
        else missed[#missed + 1] = "scale" end
    end
    local skip = C.unicorn_efx_skip or 0.0
    if skip > 0.001 then
        local done = nil
        for _, name in ipairs({"set_Frame", "setFrame", "set_Time",
                               "set_StartFrame", "set_CurrentFrame"}) do
            if not done and UNI.has_method(effect, name) then
                if pcall(function() effect:call(name, skip) end) then done = name end
            end
        end
        if done then applied[#applied + 1] = "skip=" .. done
        else missed[#missed + 1] = "skip" end
    end
    UNI.efx_extras = (#applied > 0 and table.concat(applied, ", ") or "none applied")
        .. (#missed > 0 and ("  |  NO API FOR: " .. table.concat(missed, ", ")) or "")
end

-- ⭐ 08-11 GLUE TICK: element 11 is a LOOPING effect -- it keeps whatever position its
-- FIRST fire computed, forever ("based on what position the horse was in when spawned"
-- -- Aurora, correctly). The engine's joint-follow does nothing for it either. So stop
-- trusting fire-time offsets entirely: every tick, write the effect GameObject's
-- transform to joint pos + horn anchor (joint frame, live) + trim (world axes). The
-- same transform route the scale fallback already proved (transform.set_LocalScale).
function UNI.glue_efx(entry, go)
    pcall(function()
        if not valid(go) then return end
        local tf = go:call("get_Transform")
        if not tf then return end
        local jn = entry.glue_joint
        if not jn then
            jn = tf:call("getJointByName(System.String)", "Neck_3")
            entry.glue_joint = jn
        end
        if not jn then return end
        local jp = jn:call("get_Position")
        local q = jn:call("get_Rotation")
        if not (jp and q) then return end
        local t = C.unicorn_efx_tip or 1.0
        local s = C.horse_scale or 1.0
        local anchor = UNI.qrot(q, Vector3f.new(
            (0.16901 + (0.36662 - 0.16901) * t) * s,
            (0.01193 + (-0.01930 - 0.01193) * t) * s, 0.0), false)
        -- ⭐ v2, via the dumped effect API (IrisUnicornEfxApi.json): element 11's
        -- EffectPlayer has MaintainPosition -- engine-speak for "keep the spawn-time
        -- world position even though a follow target was given". That IS the frozen
        -- sparkle. Clear it once so the engine's own joint-follow engages, then steer
        -- the RUNNING container with setOffset (offset = relative to the followed
        -- joint): anchor recomputed from the live joint rotation + world trim.
        -- The old transform.set_Position write did nothing -- particles don't take
        -- their GameObject's transform after spawn.
        if not entry.mp_cleared then
            pcall(function()
                local eff = UNI.container_effect(entry.container)
                if eff then eff:call("set_MaintainPosition", false) end
            end)
            entry.mp_cleared = true
        end
        local off = Vector3f.new(
            anchor.x + (C.unicorn_efx_ox or 0.0),
            anchor.y + (C.unicorn_efx_oy or 0.0),
            anchor.z + (C.unicorn_efx_oz or 0.0))
        if pcall(function() entry.container:call("setOffset", off) end) then
            UNI.glue_status = "glued (container.setOffset + follow)"
        elseif pcall(function()
                entry.container:call("commandSetOffset", off) end) then
            UNI.glue_status = "glued (container.commandSetOffset + follow)"
        else
            UNI.glue_status = "glue FAILED: setOffset threw"
        end
    end)
end

-- Writes every method on the live effect + container to data/IrisUnicornEfxApi.json so
-- scale/seek can be wired against what actually exists instead of guessed at.
function UNI.dump_effect_api()
    local out = {}
    for _, entry in pairs(S.unicorns) do
        if entry.container then
            pcall(function()
                local ctd = entry.container:get_type_definition()
                out[#out + 1] = "== CONTAINER: " .. tostring(ctd:get_full_name())
                for _, m in ipairs(ctd:get_methods() or {}) do
                    out[#out + 1] = "  container." .. tostring(m:get_name())
                end
            end)
            local effect = UNI.container_effect(entry.container)
            if effect then
                pcall(function()
                    local td = effect:get_type_definition()
                    out[#out + 1] = "== EFFECT: " .. tostring(td:get_full_name())
                    while td do
                        out[#out + 1] = "  -- from " .. tostring(td:get_full_name())
                        for _, m in ipairs(td:get_methods() or {}) do
                            out[#out + 1] = "  " .. tostring(m:get_name())
                        end
                        td = td:get_parent_type()
                    end
                end)
            else
                out[#out + 1] = "== no effect object inside the container"
            end
            break
        end
    end
    if #out == 0 then out[1] = "no live sparkle to inspect -- spawn a unicorn first" end
    json.dump_file("IrisUnicornEfxApi.json", out)
    UNI.efx_status = "wrote " .. #out .. " lines to data/IrisUnicornEfxApi.json"
end

-- Fire the effect on the PLAYER exactly the way Aurora's working devtools audition did.
-- The clean bisect: if this shows sparkles and the unicorn does not, the API call is
-- right and the problem is cross-character attachment. If neither shows, it is the call.
function UNI.test_fire_player()
    local mgr = UNI.player_manager()
    local ids = UNI.resolve_effect_id()
    if not (mgr and ids and valid(UNI.pl_mgr_go)) then
        UNI.efx_status = "player test: no manager or container"
        return false
    end
    local container = nil
    pcall(function()
        local effect_id = sdk.create_instance("via.effect.script.EffectID")
        effect_id.ContainerID = ids.container_id
        effect_id.ElementID = C.unicorn_efx_index or 0
        effect_id.DataContainerIndex = ids.container_index
        effect_id.IsContainerIDOnly = false
        effect_id.IsElementIDOnly = false
        local tf = UNI.pl_mgr_go:call("get_Transform")
        container = mgr:call(
            "requestEffect(via.effect.script.EffectID, via.vec3, via.Quaternion, "
            .. "via.GameObject, System.String, "
            .. "via.effect.script.EffectManager.WwiseTriggerInfo)",
            effect_id, Vector3f.new(0, 0, 0), tf:call("get_Rotation"),
            UNI.pl_mgr_go, "L_Breast", nil)
    end)
    UNI.efx_status = container
        and "player test: FIRED on L_Breast (untinted) -- if you see it here but not on"
            .. " the unicorn, cross-character attachment is the problem"
        or "player test: requestEffect returned nil"
    return container ~= nil
end

rawset(_G, "__iris_wild_horses_unicorn", UNI)

local function registered_horses()
    local horses = {}
    for _, record in pairs(REGISTRY) do
        if record.kind == "horse" and valid(record.game_object) then
            horses[#horses + 1] = record
        end
    end
    return horses
end

local function first_horse()
    local records = registered_horses()
    return records[1] and records[1].game_object or nil
end

-- Walk a game object's transform ancestry up to a registered horse root.
-- Sound emitters can live on child GameObjects of the horse.
local function registered_horse_ancestor(game_object)
    local current = game_object
    for _ = 1, 8 do
        if not valid(current) then return nil end
        local address = object_address(current)
        local record = address and REGISTRY[address]
        if record and record.kind == "horse" then return current end
        local parent_go = nil
        pcall(function()
            local transform = current:call("get_Transform")
            local parent = transform and transform:call("get_Parent")
            parent_go = parent and parent:call("get_GameObject") or nil
        end)
        if not parent_go then return nil end
        current = parent_go
    end
    return nil
end

-- Defined here (not up in the UNI block) because it closes over
-- registered_horse_ancestor, which is declared below UNI. Assigning a table field
-- costs no local, so the 200-local budget is untouched either way.
-- Queries legitimately arrive on CHILD GameObjects (sound emitters, the sparkle
-- follower), so a raw REGISTRY[address] lookup would answer false for a real unicorn.
function UNI.is_unicorn(game_object)
    local root = registered_horse_ancestor(game_object)
    if not root then return nil end
    local address = object_address(root)
    local record = address and REGISTRY[address]
    if record and record.variant == "unicorn" then return root end
    return nil
end

-- ---------------------------------------------------------------------------
-- Spawn: doe -> horse (mesh/material/scale, registry producer)
-- ---------------------------------------------------------------------------

local R = {
    mesh_holder = nil,
    mdf_holder = nil,
    resource_status = "not loaded",
}

local function load_render_resources()
    if valid(R.mesh_holder) and valid(R.mdf_holder) then return true end
    local mesh_holder, mdf_holder = nil, nil
    pcall(function()
        local resource = sdk.create_resource(
            "via.render.MeshResource", HORSE_MESH_PATH)
        if resource then
            mesh_holder = resource:create_holder("via.render.MeshResourceHolder")
            if mesh_holder then mesh_holder:add_ref() end
        end
    end)
    pcall(function()
        local resource = sdk.create_resource(
            "via.render.MeshMaterialResource", HORSE_MDF_PATH)
        if resource then
            mdf_holder = resource:create_holder(
                "via.render.MeshMaterialResourceHolder")
            if mdf_holder then mdf_holder:add_ref() end
        end
    end)
    R.mesh_holder, R.mdf_holder = mesh_holder, mdf_holder
    if valid(mesh_holder) and valid(mdf_holder) then
        R.resource_status = "horse mesh resources loaded"
        return true
    end
    R.resource_status = "horse mesh resource load failed (is the pak installed?)"
    return false
end

-- Unicorn body/horn/mane mesh + its 5-material mdf2. Lazily loaded and ONLY when the
-- user has confirmed the pak is installed -- see the unicorn_mesh_enabled comment.
-- ⛔⛔ v1.1 REDESIGN after TWO CTDs. v1.0 shipped a custom 5-material unicorn.mdf2
-- (adding mane_mat). Both resources loaded fine and the swap completed -- then the game
-- died ~11 ms later inside app.EyeGlowController.onUpdate. Disabling that controller
-- first (the ox path's recipe) did NOT fix it -- and that recipe was never proven, since
-- the ox mesh has never existed in any pak.
-- ⇒ ROOT-CAUSE FIX instead of another symptom patch: unicorn.mesh now carries the
-- VANILLA FOUR-material table (body_mat, eye_mat, oral_mat, vfx_mat) with horn AND mane
-- merged onto oral_mat, so it pairs with the FIELD-PROVEN horse.mdf2 and the material
-- COUNT never changes on a live body. No custom mdf2 is shipped at all.
-- ⭐⭐⭐ 08-11 REDESIGN (three failed boots taught this): the unicorn mesh takes
-- ~10-12 s to STREAM. The old code built resource+holder in one breath and kept a ref
-- only on the HOLDER -- so a hollow holder meant the heal dropped everything, the
-- engine EVICTED the half-streamed resource, and the rebuild started streaming from
-- scratch. Retries every ~6 s were resetting a 12-second timer forever; the one boot
-- that worked simply got an 11.5 s gap by luck (log diff 10:46 vs 10:58).
-- New shape: PIN the resources once (add_ref, kept in R.uni_*_res) so streaming is
-- paid exactly once per session, and only wrap holders after a real warm gate.
-- Returns (ok, why): why == "warming" means DEFER the swap, not fall back to horse.
local UNICORN_MESH_GATE = 15.0
local function load_unicorn_resources()
    if not C.unicorn_mesh_enabled then return false, "disabled" end
    if valid(R.uni_mesh_holder) then return true end
    if R.uni_failed then return false, "failed" end
    -- Stage 1: pin the raw resources and let the engine stream them. No holders yet.
    if not R.uni_mesh_res then
        pcall(function()
            local res = sdk.create_resource(
                "via.render.MeshResource", UNICORN_MESH_PATH)
            if res then
                res:add_ref()
                R.uni_mesh_res = res
                -- ⭐ 08-11 v2: "Reset scripts" DESTROYS the whole Lua state (_G
                -- included -- the first stamp attempt there was wrong), but the
                -- engine-side resource survives our leaked add_ref. So the stamp
                -- lives in a json file, guarded by process identity: os.time() -
                -- os.clock() ≈ the PROCESS START wall time, identical across reloads
                -- of one game session and different after a real game restart --
                -- which is exactly when the stream genuinely must be re-paid.
                local now_wall, now_clock = os.time(), os.clock()
                local stamp = nil
                pcall(function() stamp = json.load_file("IrisUnicornWarm.json") end)
                if stamp and stamp.wall and stamp.clock
                    and math.abs((stamp.wall - stamp.clock)
                        - (now_wall - now_clock)) < 10 then
                    R.uni_mesh_warm_at = stamp.clock
                else
                    R.uni_mesh_warm_at = now_clock
                    pcall(function()
                        json.dump_file("IrisUnicornWarm.json",
                            {wall = now_wall, clock = now_clock})
                    end)
                end
            end
        end)
        if not R.uni_mesh_res then
            R.uni_failed = true
            R.unicorn_status =
                "unicorn mesh resource NIL -- is IRIS_08_unicorn.pak installed?"
            log(R.unicorn_status)
            return false, "failed"
        end
        log("unicorn resources pinned; streaming ("
            .. UNICORN_MESH_GATE .. "s gate before first use)")
    end
    -- The white-albedo mdf2 loads ONLY when its experiment toggle is armed; the safe
    -- default pairs the unicorn mesh with the field-proven stock horse.mdf2 (v1.1).
    if C.unicorn_custom_mdf and not R.uni_mdf_res then
        pcall(function()
            local res = sdk.create_resource(
                "via.render.MeshMaterialResource", UNICORN_MDF_PATH)
            if res then
                res:add_ref()
                R.uni_mdf_res = res
                R.uni_mdf_warm_at = os.clock()
            end
        end)
    end
    -- Stage 2: refuse to build holders until the pinned resources have streamed.
    local age = os.clock() - (R.uni_mesh_warm_at or 0)
    if age < UNICORN_MESH_GATE then
        R.unicorn_status = string.format(
            "unicorn resources streaming (%.0fs / %.0fs)", age, UNICORN_MESH_GATE)
        return false, "warming"
    end
    local mesh_holder = nil
    pcall(function()
        mesh_holder = R.uni_mesh_res:create_holder("via.render.MeshResourceHolder")
        if mesh_holder then mesh_holder:add_ref() end
    end)
    local mdf_holder = nil
    if C.unicorn_custom_mdf and R.uni_mdf_res then
        pcall(function()
            mdf_holder = R.uni_mdf_res:create_holder(
                "via.render.MeshMaterialResourceHolder")
            if mdf_holder then mdf_holder:add_ref() end
        end)
    end
    R.uni_mesh_holder, R.uni_mdf_holder = mesh_holder, mdf_holder
    if valid(mesh_holder) and (not C.unicorn_custom_mdf or valid(mdf_holder)) then
        R.unicorn_status = C.unicorn_custom_mdf
            and "unicorn mesh + white-albedo mdf2 loaded (EXPERIMENT armed)"
            or "unicorn mesh loaded (stock horse.mdf2 -- safe mode)"
        log(R.unicorn_status)
        return true
    end
    R.uni_failed = true
    R.unicorn_status = "unicorn holder build FAILED after warm gate"
    log(R.unicorn_status)
    return false, "failed"
end

-- Diagnostic for the 08-11 morning failure: the boot-warmed unicorn holder AV'd in
-- setMesh SIX MINUTES after creation, three does in a row, while horse setMesh worked
-- on the same bodies -- so either the engine can't find unicorn.mesh this boot (pak
-- mount problem) or the resource stub never streams. This asks the engine directly and
-- prints the horse mesh (known good) alongside as the control.
UNI.probe_resources = function()
    local lines = {}
    local function probe(kind, path)
        local ok, res = pcall(sdk.create_resource, kind, path)
        if not ok or not res then
            lines[#lines + 1] = path .. ": create_resource NIL/threw ("
                .. tostring(res) .. ")"
            return
        end
        local states = {}
        for _, m in ipairs({"get_Loaded", "get_Ready", "get_ResourceState",
                            "get_State", "get_Path"}) do
            local mok, v = pcall(function() return res:call(m) end)
            if mok and v ~= nil then
                states[#states + 1] = m .. "=" .. tostring(v)
            end
        end
        lines[#lines + 1] = path .. ": resource OK | "
            .. ((#states > 0) and table.concat(states, " ")
                or "no state getter answered")
    end
    probe("via.render.MeshResource", HORSE_MESH_PATH)
    probe("via.render.MeshResource", UNICORN_MESH_PATH)
    probe("via.render.MeshMaterialResource", UNICORN_MDF_PATH)
    probe("via.render.TextureResource",
        "character/ch/ch99_011/unicorn_body_albd.tex")
    for _, l in ipairs(lines) do log("resource probe: " .. l) end
    R.unicorn_status = "probe done -- see re2_framework_log (resource probe lines)"
    return lines
end

local function character_id(character)
    local id = nil
    pcall(function() id = character:call("get_CharaIDString") end)
    if id == nil then pcall(function() id = character:call("getCharaIDString") end) end
    return tostring(id or "")
end

local function set_mesh_enabled(mesh, enabled)
    pcall(function() mesh:call("set_Enabled", enabled == true) end)
end

-- Keep the native damage-rate path neutral. Horse durability is implemented
-- exactly once in updateDamageHp below. An old discriminator test left this
-- at 0.05 and then also scaled updateDamageHp, making horses effectively
-- invulnerable (about 80 doe health pools at the default 1,000 HP setting).
local DAMAGE_RATE_STATE = {logged = false}

local function normalise_damage_rate(game_object)
    local hc = get_component(game_object, "app.HitController")
    if not hc then return false end
    local ok = pcall(function() hc:call("set_DamageRate", 1.0) end)
    if not DAMAGE_RATE_STATE.logged then
        DAMAGE_RATE_STATE.logged = true
        log("horse native damage rate normalised to 1.0: " .. tostring(ok))
    end
    return ok
end

-- THE definitive HP lever (07-22, after set_DamageRate writes provably lost
-- to pipeline recompute): pre-hook app.HitController.updateDamageHp and
-- scale the damage BEFORE application. Signature per the griffin dump:
-- updateDamageHp(DamageInfo, amount, bool) with Damage/FixedDamage fields.
local DMG_HOOK = {installed = false, scaled = 0}

local function install_damage_hook()
    if DMG_HOOK.installed then return end
    local td = sdk.find_type_definition("app.HitController")
    local method = td and td:get_method("updateDamageHp")
    if not method then
        log("damage hook: updateDamageHp not found")
        return
    end
    DMG_HOOK.installed = true
    sdk.hook(method, function(args)
        pcall(function()
            local hc = sdk.to_managed_object(args[2])
            if not hc then return end
            local go = nil
            pcall(function() go = hc:call("get_GameObject") end)
            if not go or not registered_horse_ancestor(go) then return end
            -- Variant-aware base HP. rec.base_hp is the reserved slot for the
            -- planned per-creature IV system -- when a roll writes it, this
            -- whole pipeline honors it with no further changes. Both clamps
            -- kept deliberately (reviewer: the 0.05 floor is a designed limit).
            local base = C.horse_hp
            pcall(function()
                local rec = REGISTRY[object_address(go)]
                if rec then
                    base = rec.base_hp
                        or (rec.variant == "unicorn" and C.unicorn_hp)
                        or C.horse_hp
                end
            end)
            local rate = math.max(0.05, math.min(1.0,
                250.0 / math.max(250.0, base)))
            -- updateDamageHp receives the final amount separately. Scaling
            -- DamageInfo as well as this amount double-counts the reduction
            -- and mutates shared attack data seen by other damage hooks.
            pcall(function()
                local amount = sdk.to_float(args[4])
                if amount and amount > 0 then
                    args[4] = sdk.float_to_ptr(amount * rate)
                end
            end)
            DMG_HOOK.scaled = DMG_HOOK.scaled + 1
        end)
    end, function(retval) return retval end)
    log("damage hook installed on updateDamageHp")
end

-- ⛔ DEFERRED BOOT (2026-08-05): nothing engine-facing runs at script load or
-- on the title screen — no prefab standby, no native hooks, no resource
-- creation. Everything arms on the first frame where the player exists
-- (see the arming block at the top of the frame loop). Preload crashes with
-- this module active forced the change; in-game behavior is unchanged.
local WORLD_ARMED = false

local function world_ready()
    local ready = false
    pcall(function()
        local manager = sdk.get_managed_singleton("app.CharacterManager")
        ready = manager ~= nil and manager:call("get_ManualPlayer") ~= nil
    end)
    return ready == true
end

-- setHp cascade (griffin-proven overload ladder)
local function set_hp(game_object, value)
    local hc = get_component(game_object, "app.HitController")
    if not hc then return false end
    for _, attempt in ipairs({
        function() hc:call("setHp(System.Single, System.Boolean, System.Int32)",
                           value * 1.0, true, 0) end,
        function() hc:call("setHp(System.Single, System.Boolean)",
                           value * 1.0, true) end,
        function() hc:call("setHp(System.Single)", value * 1.0) end,
        function() hc:call("set_Hp(System.Single)", value * 1.0) end,
    }) do
        if pcall(attempt) then return true end
    end
    return false
end

-- ⛔⛔ LIVENESS GATE (2026-08-08, Aurora's own diagnosis: "is it trying to convert
-- corpses or something?" -- yes, it was). This module had NO aliveness test anywhere:
-- handle_spawn accepted any doe-ID character, and the boot catch-up sweep feeds it
-- every character in the scene INCLUDING corpses and bodies mid-despawn. Converting a
-- dying/dead body means we swap its mesh+material and register dynamic motion banks on
-- a GameObject the engine is already tearing down -- which is exactly the crash pair
-- seen on 08-08: `via.Component.get_GameObject` throwing InvalidOperationException
-- (component on a dead GO) 240ms before a conversion, and a c0000005 inside
-- `app.AutoDestroyDistributorUnit.autoDestroyCharaInstance` (the despawner) as
-- converted does streamed out. Never touch a body the engine is finished with.
local function doe_is_alive(character)
    if not character then return false end
    local dead = false
    pcall(function() dead = character:call("get_IsDead") == true end)
    if dead then return false end
    pcall(function()
        local hp = character:call("get_Hp")
        if hp ~= nil and tonumber(hp) <= 0 then dead = true end
    end)
    return not dead
end

local function apply_horse(job)
    if not (job and valid(job.go)) then return false, "doe despawned" end
    -- re-check at APPLY time, not just at decision time: the swap is deferred ~0.15s
    -- and the body can die or begin despawning inside that window.
    local live_ch = get_component(job.go, "app.Character")
    if not doe_is_alive(live_ch) then return false, "doe died before the swap" end
    if not load_render_resources() then return false, R.resource_status end

    local mesh = get_component(job.go, "via.render.Mesh")
    if not mesh then return false, "doe render mesh not ready" end

    local old_mesh, old_mdf = nil, nil
    pcall(function() old_mesh = mesh:call("getMesh") end)
    pcall(function() old_mdf = mesh:call("get_Material") end)

    -- ⭐ A UNICORN gets a DIFFERENT BODY: unicorn.mesh carries the horn as its own
    -- submesh (oral_mat) and the mane split out onto mane_mat. Falls back to the plain
    -- horse pair whenever the pak is absent or disabled, so the variant still works
    -- as a pure recolour if the asset never loads.
    local use_mesh, use_mdf = R.mesh_holder, R.mdf_holder
    local unicorn_body = false
    if job.variant == "unicorn" and C.unicorn_mesh_enabled then
        -- ⭐ 08-11: NEVER reuse a holder across conversions. The holder that served
        -- unicorn #1 goes stale by the next body -- sometimes it throws (the heal
        -- catches that), sometimes it silently attaches NOTHING: "render swap
        -- complete", invisible unicorn, material job reads 0 vars for 4 s (log
        -- 11:35). Holders are cheap wrappers; the streamed resource stays pinned,
        -- and a fresh holder from it works the same millisecond (proven 11:33:29).
        R.uni_mesh_holder, R.uni_mdf_holder = nil, nil
        local ok, why = load_unicorn_resources()
        if not ok and why == "warming" then
            -- Pinned resources still streaming (paid once per session, ~15 s at arm).
            -- DEFER: setMesh on a not-yet-streamed resource is the AV that tore three
            -- doe bodies on 08-11 and likely seeded the 10:59 teleport-load crash.
            return false, R.unicorn_status
        end
        if ok then
            use_mesh = R.uni_mesh_holder
            -- Custom mdf2 only when the experiment is armed; otherwise the swap keeps
            -- the stock horse.mdf2 = the v1.1 configuration proven crash-free. The old
            -- 4 s mdf age gate is subsumed by the mesh gate in load_unicorn_resources.
            if C.unicorn_custom_mdf and valid(R.uni_mdf_holder) then
                use_mdf = R.uni_mdf_holder
            end
            unicorn_body = true
        end
        -- hard failure (pak missing) falls through to the plain horse pair on purpose
    end

    -- ⛔⛔ 2026-08-11 CTD: first unicorn spawn crashed in app.EyeGlowController.onUpdate
    -- (inside app.Monster.update). This module's own ox path already documents why:
    -- "set_Material on a live monster = EyeGlowController AV (cached material instances
    -- dangle). So: disable EyeGlowController FIRST, then swap both."
    -- The plain horse gets away with it because horse.mdf2 keeps the vanilla FOUR-entry
    -- table; unicorn.mdf2 has FIVE, so the controller's cached instances no longer line
    -- up and it dereferences a dangling one on its next update.
    -- Left DISABLED afterwards on purpose -- re-enabling re-caches against the very
    -- layout that broke it, and the doe eye-glow is a subtle effect a unicorn with a
    -- glowing horn does not need. Only applied on the unicorn path: the plain horse
    -- swap is field-proven and is deliberately left untouched.
    -- ⛔⛔ v1.2 STILL crashed in EyeGlowController.onUpdate WITH this guard in place and
    -- WITH a four-material mdf2 -- so the count theory is dead, and the root-GO
    -- get_component likely never found the controller (child GameObject). Timeline that
    -- proves the shape: v1.0 custom mdf2 = crash; v1.1 STOCK horse.mdf2 = worked; v1.2
    -- custom mdf2 = crash. ⇒ it is ANY custom mdf2 on this body. The guard now walks
    -- the WHOLE child tree and LOGS what it found, so the next log tells us whether the
    -- controller was actually disabled -- no more silent guessing.
    -- ⭐⭐ 08-11 ROOT CAUSE, finally: app.EyeGlowController is NOT a via component --
    -- its il2cpp parent is System.Object -- so the old child-tree get_component sweep
    -- could never find it ("disabled 0 instance(s)" every single time). It lives as a
    -- FIELD on the body's app.Monster component and caches per-material accessors in
    -- MaterialAccessDict; set_Material turns those into dangling pointers and its next
    -- onUpdate is the exact c0000005 in every v1.0/v1.2/08-11 crash dump.
    -- resetController() drops the cache; the InitializeFailed latch stops tryInitialize
    -- from re-caching against a material layout it does not understand. Doe eye-glow is
    -- lost on unicorns only -- a creature with a glowing horn will cope.
    if unicorn_body then
        local neutralised = "app.Monster component not found"
        pcall(function()
            local monster = get_component(job.go, "app.Monster")
            if not monster then return end
            neutralised = "Monster found, EyeGlowController field nil"
            local ctrl = monster:get_field("EyeGlowController")
            if not ctrl then return end
            pcall(function() ctrl:call("resetController") end)
            pcall(function() ctrl:call("set_IsInitialized", false) end)
            pcall(function() ctrl:call("set_InitializeFailed", true) end)
            neutralised = "reset + init latch set"
        end)
        log("unicorn swap: EyeGlowController via app.Monster field -- " .. neutralised)
    end

    set_mesh_enabled(mesh, false)
    -- ⚠ Capture WHICH setter threw and WHY. "mesh/material setter failed; rolled back"
    -- on its own is undiagnosable, and this path has already burned several in-game
    -- cycles guessing. Also record holder validity: a holder that went stale between
    -- conversions is the prime suspect for an INTERMITTENT unicorn-only failure.
    local mesh_ok, mesh_err = pcall(function() mesh:call("setMesh", use_mesh) end)
    local mdf_ok, mdf_err = pcall(function() mesh:call("set_Material", use_mdf) end)
    if not mdf_ok then
        mdf_ok, mdf_err = pcall(function() mesh:call("setMaterial", use_mdf) end)
    end
    set_mesh_enabled(mesh, true)

    if not (mesh_ok and mdf_ok) then
        -- Never leave a doe half-swapped when a setter fails.
        set_mesh_enabled(mesh, false)
        if old_mesh then pcall(function() mesh:call("setMesh", old_mesh) end) end
        if old_mdf then pcall(function() mesh:call("set_Material", old_mdf) end) end
        set_mesh_enabled(mesh, true)
        -- ⭐ HEAL v2: drop the HOLDERS only -- the pinned resources (R.uni_*_res)
        -- must survive, or the engine evicts the streamed data and the next rebuild
        -- restarts the ~12 s stream from zero (the 08-11 infinite-doe loop). If a
        -- holder built from a warmed, pinned resource STILL throws three times,
        -- something deeper is wrong: unpin everything and restream once, fresh.
        if unicorn_body and not mesh_ok then
            R.uni_mesh_holder, R.uni_mdf_holder, R.uni_failed = nil, nil, false
            R.uni_heals = (R.uni_heals or 0) + 1
            if R.uni_heals >= 3 then
                if R.uni_mesh_res then
                    pcall(function() R.uni_mesh_res:release() end)
                end
                if R.uni_mdf_res then
                    pcall(function() R.uni_mdf_res:release() end)
                end
                R.uni_mesh_res, R.uni_mdf_res, R.uni_heals = nil, nil, 0
                pcall(function() json.dump_file("IrisUnicornWarm.json", {}) end)
                log("unicorn resources UNPINNED for a full restream "
                    .. "(3 setMesh throws from a warmed holder)")
            else
                log("unicorn holder dropped for rebuild (resources stay pinned)")
            end
        end
        return false, string.format(
            "setter failed; rolled back | variant=%s unicorn_body=%s | setMesh ok=%s err=%s"
            .. " | set_Material ok=%s err=%s | holders: uni=%s horse=%s mdf=%s",
            tostring(job.variant), tostring(unicorn_body),
            tostring(mesh_ok), tostring(mesh_err),
            tostring(mdf_ok), tostring(mdf_err),
            tostring(valid(R.uni_mesh_holder)), tostring(valid(R.mesh_holder)),
            tostring(valid(R.mdf_holder)))
    end

    if math.abs(C.horse_scale - 1.0) > 0.001 and valid(job.transform) then
        local scale = C.horse_scale
        pcall(function()
            job.transform:call("set_LocalScale", Vector3f.new(scale, scale, scale))
        end)
    end

    local address = object_address(job.go)
    if address then
        REGISTRY[address] = {
            kind = "horse",
            -- ⭐ SIBLING FIELD, deliberately NOT a new kind. Every kind=="horse"
            -- consumer here and across the install keeps matching, so a unicorn
            -- inherits the scale guard, the 30 s reaper, the audio router, the gait
            -- driver and the HP hook for free. A kind="unicorn" would have failed
            -- registered_horse_ancestor and spun the stable restore forever.
            variant = job.variant,
            game_object = job.go,
            transform = job.transform,
            marked_at = os.clock(),
        }
        if job.variant == "unicorn" then
            S.unicorns[address] = S.unicorns[address]
                or {game_object = job.go, next_efx = 0.0, next_reassert = 0.0}
            S.unicorns[address].game_object = job.go
            -- ⛔ The material write rides its OWN queue. It must never be appended to
            -- S.pending_swaps, whose drain loop hands every entry to apply_horse() --
            -- that would re-run this entire mesh+mdf swap (and its rollback path) on
            -- an already-converted body. Deferred rather than inline because
            -- set_Material fired microseconds ago and getMaterialVariableNum
            -- legitimately reads 0 until the material is resident.
            S.pending_materials[#S.pending_materials + 1] = {
                go = job.go,
                address = address,
                due = os.clock() + 0.10,
                attempts = 0,
            }
        end
    end
    normalise_damage_rate(job.go)

    S.applied = S.applied + 1
    S.status = "horse applied (" .. tostring(S.applied) .. " total)"
    log(S.status .. "; render swap complete")
    return true
end

local function handle_spawn(transform, forced_variant)
    if not (C.enabled and valid(transform)) then return end
    local game_object = nil
    pcall(function() game_object = transform:call("get_GameObject") end)
    if not valid(game_object) then return end
    local character = get_component(game_object, "app.Character")
    if not character then return end
    if not string.find(character_id(character), "^" .. DOE_PREFIX) then return end

    -- ScaleMediator can fire repeatedly for one creature; one stable decision
    -- per transform instance.
    local key = tostring(transform)
    if S.decisions[key] then return end

    -- ⛔ corpses and dying bodies are NOT conversion candidates (see the liveness law
    -- above apply_horse). The boot catch-up sweep hands this function every character
    -- in the scene, so without this a corpse in view at load became a "horse".
    -- ⚠ The rejection is CACHED as a decision: ScaleMediator re-fires for the same body
    -- constantly, and an early return ABOVE the cache made every corpse in the area a
    -- permanent re-evaluation (two managed calls per body per fire) -- a frame-rate leak.
    -- Death is permanent, so one decision is correct and final.
    if not doe_is_alive(character) then
        S.decisions[key] = {transform = transform, decided_at = os.clock(), dead = true}
        return
    end

    -- ⛔ SKIP takes priority over both the force flag and the chance roll. IrisTaming's hunt
    -- conjures a doe as quarry; at horse_chance 0.25 roughly one in four of those would become
    -- a horse, and the hunt must never hand you your own horse to kill (it refuses horses as
    -- prey, so the ritual would instead stall with no valid quarry).
    local skip = S.skip_next_doe
    S.skip_next_doe = false
    -- ⭐ 08-10: a forced variant now arrives as an ARGUMENT for the deterministic
    -- callers (convert_doe, the stable restore). The global flag survives only for
    -- the panel/API "force next spawn" buttons, which genuinely have no transform to
    -- aim at. This matters: handle_spawn early-returns above (dead body, wrong chara
    -- id, cached decision) WITHOUT reaching the consume line below, so a global flag
    -- can leak onto the next unrelated doe. Leaking a horse was benign; leaking a
    -- "unicorn" would bypass the night gate on a random animal. An argument cannot leak.
    local forced = forced_variant
    if not forced then
        -- ⛔ 08-10 (Aurora): "Force next doe to UNICORN" repainted CHAD, her tamed
        -- horse. The ScaleMediator reports his re-summoned body before the 1 Hz stable
        -- restore can claim it, so the global flag got eaten by a companion whose
        -- identity belongs to the stable record. Leave the flag armed for the next
        -- genuinely WILD doe and let the restore convert him deterministically.
        -- (Narrow on purpose: with no flag pending, companion bodies still take the
        -- ordinary path that has been working, and the restore corrects them anyway.)
        if S.force_next_variant and UNI.is_companion_body(game_object) then
            S.decisions[key] = {transform = transform, decided_at = os.clock(),
                deferred = true}
            return
        end
        forced = S.force_next_variant
        S.force_next_variant = nil
    end
    local horse, variant = false, nil
    if not skip then
        if forced then
            -- forced == deterministic: NEVER re-roll here. The old boolean bypassed
            -- only the chance roll, so a sub-variant sub-roll re-fired on every
            -- stable restore and zone load.
            horse = true
            if forced == "unicorn" then variant = "unicorn" end
        elseif math.random() < C.horse_chance then
            horse = true
            if C.unicorn_enabled
                and (not C.unicorn_night_only or UNI.is_night())
                and math.random() < C.unicorn_chance then
                variant = "unicorn"
            end
        end
    end
    S.decisions[key] = {transform = transform, decided_at = os.clock()}
    S.spawned_does = S.spawned_does + 1
    if horse then
        S.horse_decisions = S.horse_decisions + 1
        S.pending_swaps[#S.pending_swaps + 1] = {
            go = game_object,
            transform = transform,
            due = os.clock() + 0.15,
            attempts = 0,
            variant = variant,
        }
    end
end

-- ---------------------------------------------------------------------------
-- CLIMB-RIG prefab swap (plan F2, 2026-07-21): every doe request is served
-- from ch299011_h_00.pfb — a byte-verified doe clone carrying the OX's
-- authored climb rig (SkinningMeshColliderSet + ch99_003 clsm). The rig is
-- inert on ordinary does; horses inherit native climbability. Chara ID is
-- untouched (stays the real doe), so no restore bookkeeping is needed.
-- Requires patch_038 (the pfb) to be mounted.
-- ---------------------------------------------------------------------------

local CLIMB_PREFAB_PATH = "AppSystem/ch/ch299/prefab/ch299011_h_00.pfb"
local DOE_CHARA_FIELD = "ch299011_A_00"

local CR = {resource = nil, swapped = 0, status = "climb prefab swap OFF"}

-- Deferred + gated: staging a standby prefab is an engine load kicked off the
-- moment this ran, which used to happen at SCRIPT LOAD during preload. Now it
-- only runs from install_climb_prefab_swap(), and only if C.climb_prefab_swap.
local function stage_climb_prefabs()
    pcall(function()
        local prefab = sdk.create_instance("via.Prefab")
        if not prefab then error("via.Prefab instance was nil") end
        prefab:add_ref()
        prefab:set_Path(CLIMB_PREFAB_PATH)
        -- set_Standby(true) = "load and keep this" — without it a cold custom
        -- path never becomes ready (EnemySpawner/guild_contracts/IrisTaming all
        -- do this; the cat module got away without it because wolf prefabs are
        -- already resident).
        pcall(function() prefab:call("set_Standby", true) end)
        local controller = sdk.create_instance("app.PrefabController")
        if not controller then error("app.PrefabController instance was nil") end
        controller:add_ref()
        controller._Item = prefab
        CR.prefab = prefab
        CR.controller = controller
        CR.status = "climb prefab staged"
    end)

    pcall(function()
        local td = sdk.find_type_definition("app.CharacterID")
        for _, field in ipairs(td:get_fields() or {}) do
            if field:is_static()
                and tostring(field:get_name() or "") == DOE_CHARA_FIELD then
                CR.doe_id = field:get_data()
                break
            end
        end
    end)

    -- CONTROL: identical staging against a known-native path. Its ready-state
    -- vs ours discriminates staging-code vs pak/content failures.
    pcall(function()
        local prefab = sdk.create_instance("via.Prefab")
        prefab:add_ref()
        prefab:set_Path("AppSystem/ch/ch299/prefab/ch299011_a_00.pfb")
        pcall(function() prefab:call("set_Standby", true) end)
        CR.control_prefab = prefab
    end)
end

local function climb_prefab_ready()
    if not (CR.prefab and CR.controller and CR.doe_id ~= nil) then
        return false
    end
    local ready = false
    pcall(function() ready = CR.prefab:call("get_Ready") == true end)
    return ready
end

local function swap_doe_request(args, controller_index, container_index)
    if not C.enabled or not climb_prefab_ready() then return end
    local container = sdk.to_managed_object(args[container_index])
    local chara_id = nil
    pcall(function()
        chara_id = container._CommonInfo._ObjectID._SelectedCharacterID
    end)
    if chara_id == nil or chara_id ~= CR.doe_id then return end
    args[controller_index] = sdk.to_ptr(CR.controller)
    CR.swapped = CR.swapped + 1
end

local function install_climb_prefab_swap()
    if not C.climb_prefab_swap then
        CR.status = "climb prefab swap OFF (needs the pfb pak; route walled)"
        return
    end
    stage_climb_prefabs()
    if rawget(_G, "__iris_horse_climb_prefab_hooked") then return end
    local manager = sdk.find_type_definition("app.GenerateManager")
    pcall(function()
        local method = manager and manager:get_method(
            "requestCreateInstance(app.GeneratorCategory, app.PrefabController, "
            .. "app.GenerateInfo.GenerateInfoContainer, System.Int32, "
            .. "System.Action`2<app.PrefabInstantiateResults,app.DummyArg>, "
            .. "System.Action`2<app.PrefabInstantiateResults,app.DummyArg>)"
        )
        if method then
            sdk.hook(method, function(args)
                pcall(swap_doe_request, args, 4, 5)
            end, function(retval) return retval end)
        end
    end)
    pcall(function()
        local method = manager and manager:get_method(
            "requestCreateInstance(app.PrefabController, "
            .. "app.GenerateInfo.GenerateInfoContainer, System.Int32, app.InstanceInfo, "
            .. "System.Action`2<app.PrefabInstantiateResults,app.DummyArg>, "
            .. "System.Action`2<app.PrefabInstantiateResults,app.DummyArg>)"
        )
        if method then
            sdk.hook(method, function(args)
                pcall(swap_doe_request, args, 3, 4)
            end, function(retval) return retval end)
        end
    end)
    rawset(_G, "__iris_horse_climb_prefab_hooked", true)
end

local scale_type = sdk.find_type_definition("app.ScaleMediator")
local scale_method = scale_type and scale_type:get_method(
    "setLocalScale(app.ScaleMediator.ID, via.vec3)") or nil
local scale_hook_installed = false
local function install_scale_hook()
    if scale_hook_installed then return end
    scale_hook_installed = true
    if not scale_method then
        S.status = "ScaleMediator spawn method not found"
        log(S.status)
        return
    end
    sdk.hook(
        scale_method,
        function(args)
            thread.get_hook_storage().iris_horse_mediator =
                sdk.to_managed_object(args[2])
        end,
        function(retval)
            if S.generation == GENERATION then
                local mediator = thread.get_hook_storage().iris_horse_mediator
                local transform = nil
                if mediator then
                    pcall(function() transform = mediator:get_field("_Transform") end)
                    if not transform then
                        pcall(function() transform = mediator._Transform end)
                    end
                end
                handle_spawn(transform)
            end
            return retval
        end
    )
end

-- ---------------------------------------------------------------------------
-- Locomotion: dynamic bank 901 + native->custom auto-mapping
-- ---------------------------------------------------------------------------

local L = {
    holder = nil,
    resource_attempted = false,
    resource_status = "motlist not loaded",
}

local function load_motlist()
    if not C.custom_locomotion_enabled then
        L.resource_status = "custom locomotion disabled in config"
        return false
    end
    if valid(L.holder) then return true end
    if L.resource_attempted then return false end
    L.resource_attempted = true
    log("locomotion boundary: creating custom motlist resource")
    local holder = nil
    local ok = pcall(function()
        local resource = sdk.create_resource(
            "via.motion.MotionListResource", MOTLIST_PATH)
        if resource then
            resource = resource:add_ref()
            S.pins[#S.pins + 1] = resource
            holder = resource:create_holder("via.motion.MotionListResourceHolder")
            if holder then
                holder = holder:add_ref()
                S.pins[#S.pins + 1] = holder
            end
        end
    end)
    L.holder = holder
    if ok and valid(holder) then
        L.resource_status = "motlist loaded"
        log("locomotion boundary: custom motlist holder loaded")
        return true
    end
    L.resource_status = "motlist load FAILED (is the pak installed?)"
    log(L.resource_status)
    return false
end

local L_ox = {
    holder = nil,
    resource_attempted = false,
}

local function load_ox_motlist()
    if valid(L_ox.holder) then return true end
    if L_ox.resource_attempted then return false end
    L_ox.resource_attempted = true
    local holder = nil
    pcall(function()
        local resource = sdk.create_resource(
            "via.motion.MotionListResource", OX_MOTLIST_PATH)
        if resource then
            resource = resource:add_ref()
            S.pins[#S.pins + 1] = resource
            holder = resource:create_holder("via.motion.MotionListResourceHolder")
            if holder then
                holder = holder:add_ref()
                S.pins[#S.pins + 1] = holder
            end
        end
    end)
    L_ox.holder = holder
    return valid(holder)
end

local function register_bank_ox(state, motion)
    if not (state and valid(motion) and load_ox_motlist()) then return false end
    local motion_key = tostring(object_address(motion) or motion)
    if state.bank_registered and state.motion_key == motion_key then return true end
    local ok, err = pcall(function()
        local count = tonumber(motion:call("getDynamicMotionBankCount")) or 0
        local bank, index = nil, count
        for i = 0, count - 1 do
            local candidate = motion:call("getDynamicMotionBank", i)
            local candidate_id = nil
            if candidate then
                pcall(function() candidate_id = candidate:call("get_BankID") end)
            end
            if tonumber(candidate_id) == CUSTOM_BANK then
                bank, index = candidate, i
                break
            end
        end
        if not bank then
            motion:call("setDynamicMotionBankCount", count + 1)
            bank = sdk.create_instance("via.motion.DynamicMotionBank")
            bank = bank and bank:add_ref() or nil
            if not bank then error("could not create DynamicMotionBank") end
            S.pins[#S.pins + 1] = bank
        end
        bank:call("set_MotionList", L_ox.holder)
        bank:call("set_OverwriteBankID", true)
        bank:call("set_BankID", CUSTOM_BANK)
        motion:call("setDynamicMotionBank", index, bank)
    end)
    state.motion_key = motion_key
    state.bank_registered = ok
    if not ok then log("ox bank registration failed: " .. tostring(err)) end
    return ok
end

local function character_motion(game_object)
    local character = get_component(game_object, "app.Character")
    if not character then return nil, nil, nil end
    local motion = nil
    pcall(function() motion = character:call("get_Motion") end)
    if not valid(motion) then
        motion = get_component(game_object, "via.motion.Motion")
    end
    if not valid(motion) then return character, nil, nil end
    local layer = nil
    pcall(function() layer = motion:call("getLayer", LAYER) end)
    return character, motion, valid(layer) and layer or nil
end

local function register_bank(state, motion)
    if not (state and valid(motion) and load_motlist()) then return false end
    local motion_key = tostring(object_address(motion) or motion)
    if state.bank_registered and state.motion_key == motion_key then return true end
    log("locomotion boundary: registering dynamic bank 901 on horse "
        .. tostring(state.key))
    local ok, err = pcall(function()
        local count = tonumber(motion:call("getDynamicMotionBankCount")) or 0
        local bank, index = nil, count
        for i = 0, count - 1 do
            local candidate = motion:call("getDynamicMotionBank", i)
            local candidate_id = nil
            if candidate then
                pcall(function() candidate_id = candidate:call("get_BankID") end)
            end
            if tonumber(candidate_id) == CUSTOM_BANK then
                bank, index = candidate, i
                break
            end
        end
        if not bank then
            motion:call("setDynamicMotionBankCount", count + 1)
            bank = sdk.create_instance("via.motion.DynamicMotionBank")
            bank = bank and bank:add_ref() or nil
            if not bank then error("could not create DynamicMotionBank") end
            S.pins[#S.pins + 1] = bank
        end
        bank:call("set_MotionList", L.holder)
        bank:call("set_OverwriteBankID", true)
        bank:call("set_BankID", CUSTOM_BANK)
        motion:call("setDynamicMotionBank", index, bank)
    end)
    state.motion_key = motion_key
    state.bank_registered = ok
    if ok then
        log("locomotion boundary: dynamic bank 901 registered")
    else
        log("bank registration failed: " .. tostring(err))
    end
    return ok
end

-- JUMP PACK (2026-08-06): Gallop_Jump / Jump_toIdle / Buck as their OWN motlist
-- (horse_jump_pack.motlist, Fluffy-served) on a SECOND dynamic bank -- the
-- proven 901 recipe verbatim, so the working gait motlist is never touched.
-- ONE local (the file runs near Lua's 200-local ceiling); methods live on it.
local JP = {
    path = "character/ch/ch99_011/horse_jump_pack.motlist",
    bank = 902,
    holder = nil,
    attempted = false,
    status = "jump motlist not loaded",
}

function JP.load()
    if valid(JP.holder) then return true end
    if JP.attempted then return false end
    JP.attempted = true
    local holder = nil
    pcall(function()
        local resource = sdk.create_resource(
            "via.motion.MotionListResource", JP.path)
        if resource then
            resource = resource:add_ref()
            S.pins[#S.pins + 1] = resource
            holder = resource:create_holder("via.motion.MotionListResourceHolder")
            if holder then
                holder = holder:add_ref()
                S.pins[#S.pins + 1] = holder
            end
        end
    end)
    JP.holder = holder
    JP.status = valid(holder) and "jump motlist loaded"
        or "jump motlist FAILED (IRIS Horse Jump Pack installed in Fluffy + game restarted?)"
    log("jump pack: " .. JP.status)
    return valid(holder)
end

function JP.register(state, motion)
    if C.jump_pack_enabled == false then return false end
    if not (state and valid(motion) and JP.load()) then return false end
    local motion_key = tostring(object_address(motion) or motion)
    if state.jump_bank_registered and state.jump_motion_key == motion_key then return true end
    local ok, err = pcall(function()
        local count = tonumber(motion:call("getDynamicMotionBankCount")) or 0
        local bank, index = nil, count
        for i = 0, count - 1 do
            local candidate = motion:call("getDynamicMotionBank", i)
            local candidate_id = nil
            if candidate then
                pcall(function() candidate_id = candidate:call("get_BankID") end)
            end
            if tonumber(candidate_id) == JP.bank then
                bank, index = candidate, i
                break
            end
        end
        if not bank then
            motion:call("setDynamicMotionBankCount", count + 1)
            bank = sdk.create_instance("via.motion.DynamicMotionBank")
            bank = bank and bank:add_ref() or nil
            if not bank then error("could not create DynamicMotionBank") end
            S.pins[#S.pins + 1] = bank
        end
        bank:call("set_MotionList", JP.holder)
        bank:call("set_OverwriteBankID", true)
        bank:call("set_BankID", JP.bank)
        motion:call("setDynamicMotionBank", index, bank)
    end)
    state.jump_motion_key = motion_key
    state.jump_bank_registered = ok
    if ok then
        log("jump pack: dynamic bank 902 registered on horse " .. tostring(state.key))
    else
        log("jump pack: bank registration failed: " .. tostring(err))
    end
    return ok
end

-- takes: 1 = Gallop_Jump (gather f1-18, apex ~f50, land f58-74 at 60fps),
-- 2 = Jump_toIdle (leap settling to standstill), 3 = the rodeo Buck.
-- Takes a GAME OBJECT (first_horse() returns one, not a state -- 08-06: the
-- first build read .layer off a GO and reported "no motion layer") and
-- resolves motion/layer live, the ox-gait-test pattern.
function JP.play(game_object, motion_id, label)
    if not valid(game_object) then S.status = "jump pack: no live horse"; return false end
    local character, motion, layer = character_motion(game_object)
    if not (valid(motion) and valid(layer)) then
        S.status = "jump pack: horse motion/layer not ready"; return false
    end
    JP.state = JP.state or { key = "jump_test" }
    if not JP.register(JP.state, motion) then
        S.status = "jump pack: " .. tostring(JP.status)
        return false
    end
    local ok = pcall(function()
        layer:call(
            "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
            JP.bank, motion_id, 0.0, 4.0, 1, 1)
        pcall(function() layer:call("set_Speed", 1.0) end)
    end)
    S.status = ok and ("jump pack: playing " .. tostring(label))
        or ("jump pack: changeMotion failed for " .. tostring(label))
    return ok
end

-- RITUAL PACK (2026-08-11): Idle_Headlow / Attack_Headbutt / Eating as their own
-- motlist (horse_ritual_pack.motlist, Fluffy-served loose like the jump pack) on
-- dynamic bank 903 -- the 902 recipe verbatim. Takes: 1 = RitualGather (202 f
-- @60, the Blessing wind-up), 2 = RitualThrust (64 f, the strike -- healing
-- circle summons here), 3 = Eat (362 f, unicorn ritual + doe graze replacement).
-- ONE local; methods live on it (the file runs near Lua's 200-local ceiling).
local RP = {
    path = "character/ch/ch99_011/horse_ritual_pack.motlist",
    bank = 903,
    holder = nil,
    attempted = false,
    status = "ritual motlist not loaded",
}

function RP.load()
    if valid(RP.holder) then return true end
    if RP.attempted then return false end
    RP.attempted = true
    local holder = nil
    pcall(function()
        local resource = sdk.create_resource(
            "via.motion.MotionListResource", RP.path)
        if resource then
            resource = resource:add_ref()
            S.pins[#S.pins + 1] = resource
            holder = resource:create_holder("via.motion.MotionListResourceHolder")
            if holder then
                holder = holder:add_ref()
                S.pins[#S.pins + 1] = holder
            end
        end
    end)
    RP.holder = holder
    RP.status = valid(holder) and "ritual motlist loaded"
        or "ritual motlist FAILED (IRIS Horse Ritual Pack installed in Fluffy + game restarted?)"
    log("ritual pack: " .. RP.status)
    return valid(holder)
end

function RP.register(state, motion)
    if not (state and valid(motion) and RP.load()) then return false end
    local motion_key = tostring(object_address(motion) or motion)
    if state.ritual_bank_registered and state.ritual_motion_key == motion_key then
        return true
    end
    local ok, err = pcall(function()
        local count = tonumber(motion:call("getDynamicMotionBankCount")) or 0
        local bank, index = nil, count
        for i = 0, count - 1 do
            local candidate = motion:call("getDynamicMotionBank", i)
            local candidate_id = nil
            if candidate then
                pcall(function() candidate_id = candidate:call("get_BankID") end)
            end
            if tonumber(candidate_id) == RP.bank then
                bank, index = candidate, i
                break
            end
        end
        if not bank then
            motion:call("setDynamicMotionBankCount", count + 1)
            bank = sdk.create_instance("via.motion.DynamicMotionBank")
            bank = bank and bank:add_ref() or nil
            if not bank then error("could not create DynamicMotionBank") end
            S.pins[#S.pins + 1] = bank
        end
        bank:call("set_MotionList", RP.holder)
        bank:call("set_OverwriteBankID", true)
        bank:call("set_BankID", RP.bank)
        motion:call("setDynamicMotionBank", index, bank)
    end)
    state.ritual_motion_key = motion_key
    state.ritual_bank_registered = ok
    if ok then
        log("ritual pack: dynamic bank 903 registered on horse " .. tostring(state.key))
    else
        log("ritual pack: bank registration failed: " .. tostring(err))
    end
    return ok
end

function RP.play(game_object, motion_id, label, speed)
    if not valid(game_object) then S.status = "ritual pack: no live horse"; return false end
    local character, motion, layer = character_motion(game_object)
    if not (valid(motion) and valid(layer)) then
        S.status = "ritual pack: horse motion/layer not ready"; return false
    end
    RP.state = RP.state or { key = "ritual_test" }
    if not RP.register(RP.state, motion) then
        S.status = "ritual pack: " .. tostring(RP.status)
        return false
    end
    local ok = pcall(function()
        layer:call(
            "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
            RP.bank, motion_id, 0.0, 4.0, 1, 1)
        pcall(function() layer:call("set_Speed", speed or 1.0) end)
    end)
    S.status = ok and ("ritual pack: playing " .. tostring(label))
        or ("ritual pack: changeMotion failed for " .. tostring(label))
    return ok
end

local function read_layer(layer)
    if not valid(layer) then return nil end
    local sample = {}
    pcall(function() sample.bank = tonumber(layer:call("get_MotionBankID")) end)
    pcall(function() sample.id = tonumber(layer:call("get_MotionID")) end)
    pcall(function() sample.frame = tonumber(layer:call("get_Frame")) end)
    pcall(function() sample.end_frame = tonumber(layer:call("get_EndFrame")) end)
    if sample.bank == nil or sample.id == nil then return nil end
    return sample
end

local function issue_custom(state, motion_id, interpolation)
    if not (state and register_bank(state, state.motion) and valid(state.layer)) then
        return false
    end
    log(string.format(
        "locomotion boundary: requesting bank %d motion %d",
        CUSTOM_BANK, motion_id))
    local ok = pcall(function()
        state.layer:call(
            "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
            CUSTOM_BANK, motion_id, 0.0, interpolation or 0.0, 1, 1)
        -- Movement comes from clip root motion, so playback speed IS travel
        -- speed; the frame-synced hoofbeats track it automatically.
        pcall(function() state.layer:call("set_Speed", C.horse_speed) end)
    end)
    return ok
end

local function maintain_locomotion(state)
    if not C.custom_locomotion_enabled then return end
    if not (state and valid(state.layer)) then return end
    -- The rodeo owns the horse's body while active (it drives the native
    -- hop clip our AUTO_MAP would otherwise replace with a trot).
    if rawget(_G, "__iris_horse_rodeo_active_addr") == state.key then
        return
    end
    -- The Blessing owns the body the same way while its ritual runs -- without
    -- this, the FSM re-issues bank-0 gaits mid-ritual and AUTO_MAP stomps the
    -- ritual clip (the exact cause of the test-button drift).
    if RP.blessing and RP.blessing.addr == state.key then return end
    local live = state.live
    if not live then return end
    if live.bank == 0 then
        local replacement = AUTO_MAP[live.id]
        if replacement then
            if issue_custom(state, replacement.id, 4.0) then
                if state.auto_name ~= replacement.name then
                    log("locomotion boundary: gait changed to "
                        .. tostring(replacement.name))
                end
                state.auto_name = replacement.name
                state.live = read_layer(state.layer) or state.live
            end
        else
            state.auto_name = nil
        end
    elseif live.bank ~= CUSTOM_BANK then
        state.auto_name = nil
    end
end

-- OX chassis full remap: native ox motion requests -> retargeted doe/horse
-- catalogue in bank 901 (horse_ox_locomotion.motlist, 66 takes). Keys are
-- "bank:id" from the live capture 07-22; id scheme: X00=loop X06=start
-- X12=end, turns 450-453, dmg bank 10 in slot-tens, liv bank 60.
-- Ruminate (bank 60) intentionally unmapped - no doe twin, ox clips play.
-- FULL generated table (data/PlanF_OxHorse/ox_remap_generated.lua): derived
-- from the motlist slot maps via the id algebra — loops X00/starts X06/ends
-- X12, dmg id = slot*10, liv blocks of 10 with +0 start/+1 loop/+9 end.
local OX_REMAP = {
    ["0:0"] = 14, ["0:1"] = 15, ["0:2"] = 13,
    ["0:100"] = 1, ["0:106"] = 30, ["0:112"] = 26,
    ["0:200"] = 2, ["0:206"] = 19, ["0:212"] = 17,
    ["0:300"] = 3, ["0:306"] = 8, ["0:312"] = 6,
    ["0:400"] = 16, ["0:416"] = 11,
    ["0:450"] = 22, ["0:451"] = 23, ["0:452"] = 24, ["0:453"] = 25,
    ["10:0"] = 43, ["10:10"] = 42, ["10:20"] = 44, ["10:30"] = 45,
    ["10:40"] = 43, ["10:50"] = 42, ["10:60"] = 44, ["10:70"] = 45,
    ["10:80"] = 39, ["10:90"] = 38, ["10:100"] = 40, ["10:110"] = 41,
    ["10:120"] = 47, ["10:130"] = 46, ["10:140"] = 48,
    ["10:150"] = 50, ["10:160"] = 49, ["10:170"] = 51, ["10:180"] = 52,
    ["10:190"] = 36, ["10:200"] = 35, ["10:210"] = 37,
    ["10:220"] = 36, ["10:230"] = 36, ["10:240"] = 36, ["10:250"] = 36,
    ["10:260"] = 50, ["10:270"] = 50, ["10:280"] = 50, ["10:290"] = 50,
    ["10:300"] = 47, ["10:310"] = 47, ["10:320"] = 47, ["10:330"] = 47,
    ["10:340"] = 53, ["10:370"] = 34, ["10:380"] = 34,
    ["10:390"] = 33, ["10:400"] = 33, ["10:410"] = 32, ["10:420"] = 32,
    ["10:430"] = 31, ["10:440"] = 31, ["10:460"] = 54,
    ["60:0"] = 57, ["60:1"] = 56, ["60:9"] = 55,
    ["60:10"] = 60, ["60:11"] = 59, ["60:19"] = 58,
    ["60:20"] = 66, ["60:21"] = 65, ["60:29"] = 64,
    ["60:40"] = 61, ["60:41"] = 62, ["60:49"] = 63,
}

-- takes that must sustain (manifest ids with _loop names + the gaits);
-- enforced in software so REE-CE loop flags can't break them
local OX_LOOP_TAKES = {
    [1] = true, [2] = true, [3] = true, [5] = true, [7] = true,
    [11] = true, [14] = true, [18] = true, [27] = true, [28] = true,
    [29] = true, [33] = true, [35] = true, [36] = true, [37] = true,
    [56] = true, [59] = true, [62] = true, [65] = true,
}

local function ox_remap_tick()
    local st = S.ox_remap
    if not (st and st.enabled and valid(st.go)) then return end
    local character, motion, layer = character_motion(st.go)
    if not (valid(motion) and valid(layer)) then return end
    st.motion = motion
    local sample = read_layer(layer)
    if not sample then return end
    if sample.bank == CUSTOM_BANK then
        st.last_native = nil
        -- software loop: when a sustain take nears its final frame,
        -- re-issue it with zero blend (seamless wrap)
        if OX_LOOP_TAKES[sample.id] and sample.frame and sample.end_frame
            and sample.end_frame > 2
            and sample.frame >= sample.end_frame - 2 then
            pcall(function()
                layer:call(
                    "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                    CUSTOM_BANK, sample.id, 0.0, 0.0, 1, 1)
            end)
            st.loops = (st.loops or 0) + 1
        end
        return
    end
    local key = tostring(sample.bank) .. ":" .. tostring(sample.id)
    if key == st.last_native then return end
    st.last_native = key
    local target = OX_REMAP[key]
    if target then
        if not register_bank_ox(st, motion) then return end
        local ok = pcall(function()
            layer:call(
                "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                CUSTOM_BANK, target, 0.0, 4.0, 1, 1)
            layer:call("set_Speed", 1.0)
        end)
        if ok then
            st.swaps = (st.swaps or 0) + 1
            st.last_swap = key .. " -> " .. tostring(target)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Audio: bank loading + template posting (proven robust route)
-- ---------------------------------------------------------------------------

local A = S.audio

local function player_wwise_container()
    local character = nil
    pcall(function()
        local manager = sdk.get_managed_singleton("app.CharacterManager")
        character = manager and manager:call("get_ManualPlayer") or nil
        local inner = character and character:call("get_Character") or nil
        character = inner or character
    end)
    if not character then return nil end
    local wwise = nil
    pcall(function()
        wwise = character:get_field("<WwiseContainer>k__BackingField")
    end)
    if not wwise then
        pcall(function() wwise = character:call("get_WwiseContainer") end)
    end
    return valid(wwise) and wwise or nil
end

local function load_manifest()
    if A.manifest then return A.manifest end
    local data = nil
    pcall(function() data = json.load_file(MANIFEST_FILE) end)
    if not data or type(data.events) ~= "table" then
        S.audio_status = "manifest data/" .. MANIFEST_FILE .. " missing"
        return nil
    end
    A.manifest = data
    return data
end

local function create_userdata_any(type_name, path)
    for _, candidate in ipairs({path, path .. ".2"}) do
        local instance = nil
        pcall(function()
            instance = sdk.create_userdata(type_name, candidate)
            if instance then
                pcall(function() instance = instance:add_ref() end)
            end
        end)
        if instance then return instance end
    end
    return nil
end

local function find_trigger_in_list_data(list_data, trigger_id)
    if not list_data then return nil end
    local triggers = nil
    pcall(function() triggers = list_data._TriggerInfoList end)
    for index = 0, collection_count(triggers) - 1 do
        local trigger = triggers[index]
        local current_id = nil
        pcall(function() current_id = tonumber(trigger._TriggerId) end)
        if current_id == trigger_id then return trigger end
    end
    return nil
end

local function audio_prepare()
    local manifest = load_manifest()
    if not manifest then return false end
    local dispatcher = player_wwise_container()
    if not dispatcher then
        S.audio_status = "player Wwise dispatcher is not ready"
        return false
    end
    local address = object_address(dispatcher)
    if A.registration and A.registration.dispatcher_address == address then
        return true
    end
    A.template_trigger = nil

    local bank_instance = create_userdata_any(
        "soundlib.SoundBankListData", manifest.bank_list_path)
    if not bank_instance then
        S.audio_status = "bank-list USER unresolved"
        return false
    end
    local trigger_instances = {}
    local registration_trigger_instance = nil
    for _, path in ipairs(manifest.trigger_list_paths or {}) do
        local instance = create_userdata_any(
            "soundlib.SoundTriggerInfoListData", path)
        if instance then
            trigger_instances[#trigger_instances + 1] = instance
            if path == manifest.registration_trigger_path then
                registration_trigger_instance = instance
            end
        end
    end
    if not registration_trigger_instance then
        S.audio_status = "registration trigger-list USER unresolved"
        return false
    end

    -- CRASH MITIGATION (Wwise AV watch, AK::WriteBytesCount ×2 on 07-21):
    -- register the banks with the dispatcher ONCE per game process. Every
    -- script reset used to re-register the same bank ids — suspected Wwise
    -- bank-state rot (also the createRequestInfo-nil pollution).
    if rawget(_G, "__iris_audio_loaded_horse") ~= address then
        local load_ok, load_err = pcall(function()
            dispatcher:call(
                "loadContainableUserData(soundlib.SoundContainableUserData)",
                bank_instance)
            -- Every one of the seven cloned trigger lists references the
            -- SAME horse_audio_es bank. Registering all seven made the audio
            -- thread process the same bank seven times and ended in c000001d
            -- immediately after this function returned (17:02:38). Register
            -- the proven primary list once; the other deserialised lists are
            -- retained only as native SoundTriggerInfo object catalogues.
            dispatcher:call(
                "loadContainableUserData(soundlib.SoundContainableUserData)",
                registration_trigger_instance)
        end)
        if not load_ok then
            S.audio_status = "loadContainableUserData failed: "
                .. tostring(load_err)
            return false
        end
        rawset(_G, "__iris_audio_loaded_horse", address)
    end

    A.triggers_by_event = {}
    A.categories = {}
    -- 08-07 (Aurora: NO vocals ever, idle included -- and no land bang,
    -- and probably no walk/trot hooves either): only the PRIMARY trigger
    -- list is registered with the dispatcher (the 07-21 c000001d fix) and
    -- the primary file holds ONLY death + gallop -- exactly the sounds
    -- that have ever been heard. Track which events are registered so
    -- post_event can route everything else through template posting.
    A.registered_events = {}
    for _, entry in ipairs(manifest.events) do
        local bucket = A.categories[entry.category]
        if not bucket then
            bucket = {}
            A.categories[entry.category] = bucket
        end
        bucket[#bucket + 1] = {name = entry.name, event_id = entry.event_id}
        if entry.trigger_file == manifest.registration_trigger_path then
            A.registered_events[entry.event_id] = true
        end
    end
    A.registration = {
        dispatcher = dispatcher,
        dispatcher_address = address,
        bank_instance = bank_instance,
        trigger_instances = trigger_instances,
        registration_trigger_instance = registration_trigger_instance,
        ready_frame = S.frame + READY_DELAY_FRAMES,
        poll_until_frame = S.frame + 900,
    }
    A.direct_count = 0
    S.audio_status = string.format(
        "audio graph root loaded once; %d trigger files deserialised; settling",
        #trigger_instances)
    log(S.audio_status)
    return true
end

local function audio_ready()
    return A.registration ~= nil
        and S.frame >= (A.registration.ready_frame or 0)
end

local function resolve_pending_triggers()
    local registration = A.registration
    local manifest = A.manifest
    if not registration or not manifest then return end
    if S.frame > (registration.poll_until_frame or 0) then return end
    local direct = 0
    for _, entry in ipairs(manifest.events) do
        if not A.triggers_by_event[entry.event_id] then
            for _, instance in ipairs(registration.trigger_instances) do
                local trigger = find_trigger_in_list_data(
                    instance, entry.event_id)
                if trigger then
                    A.triggers_by_event[entry.event_id] = trigger
                    -- template MUST come from the REGISTERED list, or
                    -- template posts get dropped exactly like direct
                    -- posts from unregistered lists (08-07)
                    if not A.template_trigger
                        and A.registered_events
                        and A.registered_events[entry.event_id] then
                        A.template_trigger = trigger
                    end
                    break
                end
            end
        end
        if A.triggers_by_event[entry.event_id] then direct = direct + 1 end
    end
    A.direct_count = direct
end

local function find_native_trigger(wwise, trigger_id)
    local function scan_trigger_lists(lists)
        for list_index = 0, collection_count(lists) - 1 do
            local triggers = nil
            pcall(function() triggers = lists[list_index]._TriggerInfoList end)
            for trigger_index = 0, collection_count(triggers) - 1 do
                local trigger = triggers[trigger_index]
                local current_id = nil
                pcall(function() current_id = tonumber(trigger._TriggerId) end)
                if current_id == trigger_id then return trigger end
            end
        end
        return nil
    end
    local all_lists = nil
    pcall(function() all_lists = wwise:call("get_AllTriggerInfoListData") end)
    local found = scan_trigger_lists(all_lists)
    if found then return found end
    local user_data = nil
    pcall(function() user_data = wwise._UserDataList end)
    found = scan_trigger_lists(user_data)
    if found then return found end
    for bank_index = 0, collection_count(user_data) - 1 do
        local lists = nil
        pcall(function() lists = user_data[bank_index]._UserDataList end)
        found = scan_trigger_lists(lists)
        if found then return found end
    end
    return nil
end

local function native_template_for(target)
    if valid(A.native_template) then return A.native_template end
    local wwise = get_component(target, "app.WwiseContainerApp")
    if not wwise then return nil end
    for _, trigger_id in ipairs(NATIVE_DOE_TRIGGER_IDS) do
        local trigger = find_native_trigger(wwise, trigger_id)
        if trigger then
            A.native_template = trigger
            return trigger
        end
    end
    return nil
end

-- Global post throttle: never hammer the Wwise request path. 08-07 TWO
-- LANES (the log showed every "missing" sound was the SECOND of a pair:
-- jump = hoof slam + whinny, landing = bang + snort, idle vocal vs the
-- hoof cadence -- the single 30ms window always fed the hooves and
-- starved the voice): hooves and vocals each get their own window, so a
-- hoof and a vocal can share a frame while neither lane can hammer.
local function post_throttled(lane)
    local key = "__iris_audio_last_post_" .. (lane or "vocal")
    local now = os.clock()
    local last = tonumber(rawget(_G, key)) or 0
    if now - last < 0.03 then return true end
    rawset(_G, key, now)
    return false
end

local function post_request(dispatcher, trigger, target, lane)
    if post_throttled(lane) then return false end
    local joint_hash = 0
    pcall(function() joint_hash = tonumber(trigger._OffsetJointHash) or 0 end)
    local request = nil
    local ok = pcall(function()
        request = dispatcher:call(
            REQUEST_SIGNATURE,
            trigger, target, target, joint_hash,
            false, false, 0, 0, nil, nil, nil, nil)
        if request then
            request = request:add_ref()
            request["<Container>k__BackingField"] = dispatcher
            dispatcher:call("trigger(soundlib.SoundManager.RequestInfo)", request)
        end
    end)
    return ok and request ~= nil
end

local function post_via_template(dispatcher, event_id, target, lane)
    if post_throttled(lane) then return false, "post throttled" end
    local template = A.template_trigger
    if not valid(template) then
        A.template_trigger = nil
        template = native_template_for(target)
    end
    if not template then return false, "no template trigger available" end
    local function retire_template()
        if template == A.native_template then A.native_template = nil end
        if template == A.template_trigger then A.template_trigger = nil end
    end
    local original = nil
    pcall(function() original = tonumber(template._EventId) end)
    if not original then
        retire_template()
        return false, "template event ID unreadable"
    end
    local joint_hash = 0
    pcall(function() joint_hash = tonumber(template._OffsetJointHash) or 0 end)
    local request = nil
    local create_ok, create_err = pcall(function()
        template._EventId = event_id
        request = dispatcher:call(
            REQUEST_SIGNATURE,
            template, target, target, joint_hash,
            false, false, 0, 0, nil, nil, nil, nil)
    end)
    local restore_ok = pcall(function() template._EventId = original end)
    local restored = nil
    pcall(function() restored = tonumber(template._EventId) end)
    if not restore_ok or restored ~= original then
        retire_template()
        return false, "template restore failed; retired"
    end
    if not create_ok then return false, tostring(create_err) end
    if not request then return false, "createRequestInfo returned nil" end
    request = request:add_ref()
    local copied = nil
    pcall(function() copied = tonumber(request._EventId) end)
    if copied ~= event_id then
        return false, "request did not copy the target event ID"
    end
    local post_ok, post_err = pcall(function()
        request["<Container>k__BackingField"] = dispatcher
        dispatcher:call("trigger(soundlib.SoundManager.RequestInfo)", request)
    end)
    if not post_ok then return false, tostring(post_err) end
    return true
end

local function post_event(event_id, target, lane)
    if not (C.audio_enabled and audio_ready()) then
        return false, "audio not loaded/settled"
    end
    if not valid(target) then return false, "target invalid" end
    local dispatcher = A.registration.dispatcher
    if not valid(dispatcher) then
        A.registration = nil
        return false, "dispatcher went stale; reloading"
    end
    -- 08-07: direct-posting a trigger from an UNREGISTERED list "succeeds"
    -- (request created + triggered) but the audio thread silently drops
    -- it -- so the template fallback never ran and every non-primary
    -- event (walk/trot/land/alert/nicker/snort/hurt 1-3) played nothing.
    -- Unregistered events go STRAIGHT to template posting on a
    -- registered trigger (the ritual-music bank's proven recipe).
    local trigger = A.triggers_by_event[event_id]
    local registered = A.registered_events
        and A.registered_events[event_id]
    if trigger and registered
        and post_request(dispatcher, trigger, target, lane) then
        return true
    end
    return post_via_template(dispatcher, event_id, target, lane)
end

local function play_category(category, target)
    local bucket = A.categories[category]
    if not bucket or #bucket == 0 then
        return false, "no sounds in category " .. tostring(category)
    end
    local index = 1
    if #bucket > 1 then
        index = math.random(#bucket)
        if index == A.last_pick[category] then
            index = (index % #bucket) + 1
        end
    end
    A.last_pick[category] = index
    local entry = bucket[index]
    local hoof_lane = category == "walk" or category == "trot"
        or category == "gallop" or category == "land"
    local ok, err = post_event(entry.event_id, target,
        hoof_lane and "hoof" or "vocal")
    if ok then
        A.last_played = entry.name
    else
        -- 08-07 (Aurora: "no horse noises at all" after the doe-vocal
        -- flip): every silent drop NAMES ITSELF, throttled to 1 line/2s
        local nowl = os.clock()
        if nowl - (A.last_fail_log or 0) > 2.0 then
            A.last_fail_log = nowl
            log("audio post FAILED [" .. tostring(entry.name) .. "]: "
                .. tostring(err))
        end
    end
    return ok, err
end

-- ---------------------------------------------------------------------------
-- Frame-synced hoofbeat cadence
--
-- The custom horse clips do NOT emit the doe's foot-contact events, so
-- animation-event replacement is silent whenever bank-901 motions play.
-- Instead, hoofbeats are scheduled from the playing clip's own frame phase
-- with real horse gait patterns: walk 4-beat, trot 2-beat, gallop 3-beat.
-- ---------------------------------------------------------------------------

local GAIT_BEATS = {
    [1] = {category = "walk", beats = {0.05, 0.30, 0.55, 0.80}},
    [2] = {category = "trot", beats = {0.10, 0.60}},
    [3] = {category = "gallop", beats = {0.05, 0.17, 0.29}},
}

local function update_cadence(state)
    state.cadence_active = false
    if not (C.audio_enabled and audio_ready()) then return end
    if state.death_played then return end
    local live = state.live
    if not live or live.bank ~= CUSTOM_BANK then
        state.cadence_phase = nil
        return
    end
    local gait = GAIT_BEATS[live.id]
    if not gait then
        state.cadence_phase = nil
        return
    end
    if (state.smoothed_speed or 0) < 0.3 then
        state.cadence_phase = nil
        return
    end
    state.cadence_active = true
    local end_frame = tonumber(live.end_frame) or 0
    local frame = tonumber(live.frame) or 0
    if end_frame <= 1 then return end
    local phase = (frame % end_frame) / end_frame
    local previous = state.cadence_phase
    state.cadence_phase = phase
    if previous == nil then return end
    local crossed = false
    for _, beat in ipairs(gait.beats) do
        if previous <= phase then
            if beat > previous and beat <= phase then crossed = true end
        else
            -- Clip looped between samples.
            if beat > previous or beat <= phase then crossed = true end
        end
    end
    if crossed then
        play_category(gait.category, state.game_object)
    end
end

-- ---------------------------------------------------------------------------
-- Doe audio suppression + gait-matched replacement (the router)
-- ---------------------------------------------------------------------------

-- Enumerate every trigger id in the horse's inherited doe catalogue once;
-- suppressing that set silences ALL doe audio without hand-listing IDs.
local function ensure_suppress_set(horse)
    if A.suppress_set then return A.suppress_set end
    local wwise = get_component(horse, "app.WwiseContainerApp")
    if not wwise then return nil end
    local found = {}
    local total = 0
    pcall(function()
        local user_data = wwise._UserDataList
        for bank_index = 0, collection_count(user_data) - 1 do
            local lists = nil
            pcall(function() lists = user_data[bank_index]._UserDataList end)
            for list_index = 0, collection_count(lists) - 1 do
                local triggers = nil
                pcall(function()
                    triggers = lists[list_index]._TriggerInfoList
                end)
                for index = 0, collection_count(triggers) - 1 do
                    local id = nil
                    pcall(function()
                        id = normal_u32(triggers[index]._TriggerId)
                    end)
                    if id and not found[id] then
                        found[id] = true
                        total = total + 1
                    end
                end
            end
        end
    end)
    if total == 0 then return nil end
    for id in pairs(DOE_LEAP_EFFECT_IDS) do found[id] = true end
    -- Foot contacts are handled separately (replaced, not just suppressed).
    A.suppress_set = found
    log("doe suppression catalogue: " .. tostring(total) .. " trigger ids")
    return found
end

local function horse_state_for(game_object)
    local address = object_address(game_object)
    return address and S.horses[tostring(address)] or nil
end

local function gait_category(horse)
    local state = horse_state_for(horse)
    local speed = state and state.smoothed_speed or 0
    if speed > C.trot_max_speed then return "gallop" end
    if speed > C.walk_max_speed then return "trot" end
    return "walk"
end

local trigger_method = sdk.find_type_definition("app.WwiseContainerApp")
    :get_method("trigger(soundlib.SoundManager.RequestInfo)")
local trigger_hook_installed = false
local function install_horse_trigger_hook()
    if trigger_hook_installed or not trigger_method then return end
    trigger_hook_installed = true
    sdk.hook(trigger_method, function(args)
        if S.generation ~= GENERATION then return end
        if not (C.enabled and C.suppress_doe_audio) then return end
        local container, request = nil, nil
        pcall(function() container = sdk.to_managed_object(args[2]) end)
        pcall(function() request = sdk.to_managed_object(args[3]) end)
        if not container or not request then return end
        local owner = nil
        pcall(function() owner = container:call("get_GameObject") end)
        local horse = registered_horse_ancestor(owner)
        if not horse then return end
        local trigger_id = 0
        pcall(function()
            trigger_id = normal_u32(request:call("get_TriggerId")) or 0
        end)

        if FOOT_IDS[trigger_id] then
            local state = horse_state_for(horse)
            if state and state.death_played then
                -- Ragdoll ground impacts after death: silence, and never let
                -- them steal the voice playing the death cry.
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
            if state and os.clock() <= (state.hop_until or -1) then
                -- Landing after a hop: one land sound, no clop.
                if os.clock() > (state.next_land or 0) then
                    state.next_land = os.clock() + 1.0
                    A.pending_contacts[#A.pending_contacts + 1] = {
                        horse = horse, category = "land",
                    }
                end
            elseif not (state and state.cadence_active) then
                -- Native-motion contacts only; while a custom clip plays the
                -- frame-synced cadence owns the hoofbeats.
                A.pending_contacts[#A.pending_contacts + 1] = {
                    horse = horse, category = nil,  -- gait decided at drain
                }
            end
            return sdk.PreHookResult.SKIP_ORIGINAL
        end

        if DOE_VOICE_IDS[trigger_id] then
            local state = horse_state_for(horse)
            if state and not state.death_played then
                local now = os.clock()
                if (state.smoothed_speed or 0) >= C.walk_max_speed then
                    -- alarmed/fleeing/grabbed: rare and meaningful — keep a
                    -- short limiter and always neigh
                    if now > (state.next_vocal or 0) then
                        state.next_vocal = now + 6.0
                        A.pending_contacts[#A.pending_contacts + 1] = {
                            horse = horse, category = "alert",
                        }
                    end
                else
                    -- idle bleat-replacements SHARE the ambient budget: the
                    -- doe vocalises every 5-10s and a 2s limiter made the
                    -- horse a chatterbox (Aurora). One idle vocal per
                    -- ambient interval, total.
                    if state.ambient_next and now >= state.ambient_next then
                        state.ambient_next = now + math.random(
                            C.ambient_min_s, C.ambient_max_s)
                        local roll = math.random(10)
                        local category = roll <= 5 and "alert"
                            or (roll <= 8 and "snort" or "nicker")
                        A.pending_contacts[#A.pending_contacts + 1] = {
                            horse = horse, category = category,
                        }
                    end
                end
            end
            return sdk.PreHookResult.SKIP_ORIGINAL
        end

        if DOE_LEAP_EFFECT_IDS[trigger_id] then
            local state = horse_state_for(horse)
            if state then state.hop_until = os.clock() + 0.9 end
            return sdk.PreHookResult.SKIP_ORIGINAL
        end

        local suppress = ensure_suppress_set(horse)
        if suppress and suppress[trigger_id] then
            A.suppressed = A.suppressed + 1
            return sdk.PreHookResult.SKIP_ORIGINAL
        end
        -- anything reaching here on a HORSE escaped every suppression list:
        -- log it so stray doe sounds (the jump noise) can be identified
        log("horse trigger PASSTHROUGH id=" .. tostring(trigger_id))
    end, function(retval) return retval end)
end

local function drain_contacts()
    if #A.pending_contacts == 0 then return end
    local pending = A.pending_contacts
    A.pending_contacts = {}
    if not (C.audio_enabled and audio_ready()) then return end
    local now = os.clock()
    local spacing = math.max(0, C.contact_spacing_ms) / 1000.0
    local handled = {}
    for _, item in ipairs(pending) do
        local key = tostring(object_address(item.horse) or item.horse)
        local state = horse_state_for(item.horse)
        if not handled[key] and valid(item.horse)
            and not (state and state.death_played) then
            handled[key] = true
            if item.category
                or now - (A.last_contact[key] or -1000) >= spacing then
                local category = item.category or gait_category(item.horse)
                if play_category(category, item.horse) then
                    A.last_contact[key] = now
                    A.contacts_replaced = A.contacts_replaced + 1
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- HP watcher (hurt/death), ambient vocals
-- ---------------------------------------------------------------------------

local function read_hp(game_object)
    local character = get_component(game_object, "app.Character")
    if not character then return nil end
    local value = nil
    -- Use the same damage authority as the companion HUD/downed system. On a
    -- grafted horse Character.get_Hp can remain full while the receiving
    -- HitController moves, which previously silenced hurt vocals too.
    pcall(function()
        local resolver = rawget(_G, "griffin_downed_hit_controller")
        local addr = game_object and game_object:get_address()
        local hc = resolver and resolver(character, addr)
            or get_component(game_object, "app.HitController")
        value = hc and tonumber(hc:call("get_Hp")) or nil
    end)
    pcall(function()
        local hit_point = value == nil and character:call("get_HitPoint") or nil
        if value == nil and hit_point then
            value = tonumber(hit_point:call("get_Value"))
        end
    end)
    if value == nil then
        pcall(function() value = tonumber(character:call("get_Hp")) end)
    end
    return value
end

local function update_health(state, now)
    local hp = read_hp(state.game_object)
    if hp == nil then return end
    -- DamageRateCalc can recompute this field, so keep the native path neutral
    -- while updateDamageHp supplies the one intended durability multiplier.
    normalise_damage_rate(state.game_object)
    local previous = state.hp
    state.hp = hp
    if previous == nil then return end
    if hp <= 0 and previous > 0 and not state.death_played then
        state.death_played = true
        play_category("death", state.game_object)
    elseif hp < previous and hp > 0 then
        if now > (state.next_hurt or 0) then
            local lo = math.max(1, math.floor(tonumber(C.hurt_vocal_min_s) or 5))
            local hi = math.max(lo, math.floor(tonumber(C.hurt_vocal_max_s) or 10))
            state.next_hurt = now + math.random(lo, hi)
            local category = tostring(C.hurt_vocal_category or "alert")
            local ok = play_category(category, state.game_object)
            if ok then
                log("damage vocal: " .. tostring(A.last_played)
                    .. " (next in " .. tostring(state.next_hurt - now) .. "s min)")
            end
        end
    end
end

local function update_ambient(state, now)
    if not (C.ambient_enabled and C.audio_enabled and audio_ready()) then return end
    if state.death_played then return end
    if S.game_paused then
        -- The ambient timer is wall-clock; hold it through pause menus and
        -- give a short grace after unpausing.
        state.ambient_next = math.max(state.ambient_next or 0, now + 3.0)
        return
    end
    if not state.ambient_next then
        state.ambient_next = now + math.random(C.ambient_min_s, C.ambient_max_s)
        return
    end
    -- 08-07: reloads keep horse states -- a timer armed under the old
    -- 60-120s band must not outlive the re-band
    if state.ambient_next > now + C.ambient_max_s then
        state.ambient_next = now + math.random(C.ambient_min_s, C.ambient_max_s)
    end
    if now < state.ambient_next then return end
    state.ambient_next = now + math.random(C.ambient_min_s, C.ambient_max_s)
    if (state.smoothed_speed or 0) < 1.0 then
        -- Mix: snort 50% / nicker 30% / neigh 20%.
        local roll = math.random(10)
        local category = roll <= 5 and "snort" or (roll <= 8 and "nicker" or "alert")
        log("ambient vocal: " .. category)
        play_category(category, state.game_object)
    end
end

-- ---------------------------------------------------------------------------
-- Per-horse state loop (20 Hz)
-- ---------------------------------------------------------------------------

local function update_horse(record, now)
    if not (record.kind == "horse" and valid(record.game_object)) then return end
    local key = tostring(object_address(record.game_object) or record.game_object)
    local state = S.horses[key]
    if not state then
        state = {key = key}
        S.horses[key] = state
    end
    state.game_object = record.game_object
    state.transform = record.transform
    state.seen_at = now

    local character, motion, layer = character_motion(record.game_object)
    state.character, state.motion, state.layer = character, motion, layer
    -- ⛔ DEAD HORSES GET NOTHING (2026-08-08 liveness law -- `valid()` only proves the
    -- managed object exists, and a CORPSE passes it happily). Registering motion banks
    -- and driving custom clips on a body the engine is despawning is the documented
    -- crash pair; once she's dead the corpse just keeps the horse mesh and lies there.
    if not doe_is_alive(character) then
        state.dead = true
        return
    end
    state.dead = false
    if valid(motion) then
        register_bank(state, motion)
        JP.register(state, motion)   -- every live horse carries the jump pack (bank 902)
    end
    state.live = read_layer(layer)
    maintain_locomotion(state)
    state.live = read_layer(layer) or state.live
    -- The doe AI likes resetting layer speed; re-assert ours while a custom
    -- clip is playing.
    if state.live and state.live.bank == CUSTOM_BANK then
        pcall(function() state.layer:call("set_Speed", C.horse_speed) end)
    end
    update_cadence(state)

    -- Kinematics for gait selection (smoothed, teleport-guarded).
    local position = nil
    pcall(function()
        local transform = record.transform
        if not valid(transform) then
            transform = record.game_object:call("get_Transform")
        end
        position = transform and transform:call("get_Position") or nil
    end)
    if position then
        if state.last_position and state.last_position_time then
            local dt = now - state.last_position_time
            if dt > 0.0001 and dt < 0.5 then
                local dx = position.x - state.last_position.x
                local dy = position.y - state.last_position.y
                local dz = position.z - state.last_position.z
                local speed = math.sqrt(dx * dx + dy * dy + dz * dz) / dt
                if speed < 40 then
                    local previous = state.smoothed_speed or 0
                    state.smoothed_speed = previous + (speed - previous) * 0.3
                end
            end
        end
        state.last_position = {
            x = position.x, y = position.y, z = position.z,
        }
        state.last_position_time = now
    end

    update_health(state, now)
    update_ambient(state, now)
end

-- ---------------------------------------------------------------------------
-- Shared audio API (kept for AnimalWwiseRecorder / future modules)
-- ---------------------------------------------------------------------------

local AUDIO_API = {generation = GENERATION, full_set = true, iris = true}
function AUDIO_API.prepare() return audio_prepare() end
function AUDIO_API.is_ready() return audio_ready() end
function AUDIO_API.play_on(game_object)
    return play_category(gait_category(game_object), game_object)
end
function AUDIO_API.play_category(category, game_object)
    return play_category(category, game_object or first_horse())
end
-- 08-07 (rodeo kick impact): post an ARBITRARY event id -- any event
-- resolvable in the currently-loaded Wwise banks (native skill impacts
-- included) goes out through the template-post route. Own "fx" lane so
-- it never fights hooves or vocals.
function AUDIO_API.play_event(event_id, game_object, lane)
    local id = tonumber(event_id)
    if not id then return false, "bad event id" end
    -- 08-07 r25 (every native id posted "true" but SILENT): the ids from
    -- the sound browser are TRIGGER ids of REAL SoundTriggerInfo objects
    -- on the PLAYER's own registered lists -- posting a real object via
    -- soundlib.SoundContainer is what actually makes sound (Nick's
    -- SoundPlayer recipe, the very tool Aurora picked them with).
    -- Stuffing a foreign id into our custom template's _EventId posts a
    -- well-formed request for NOTHING.
    local posted = false
    pcall(function()
        local wwise = player_wwise_container()
        local pgo = wwise and wwise:call("get_GameObject")
        local sc = pgo and get_component(pgo, "soundlib.SoundContainer")
        if not (wwise and sc) then return end
        A.native_trig_cache = A.native_trig_cache or {}
        local trig = A.native_trig_cache[id]
        if not valid(trig) then
            trig = nil
            local ud = wwise._UserDataList
            for i = 0, collection_count(ud) - 1 do
                local lists = nil
                pcall(function() lists = ud[i]._UserDataList end)
                for j = 0, collection_count(lists) - 1 do
                    local tl = nil
                    pcall(function()
                        tl = lists[j]._TriggerInfoList
                    end)
                    for k2 = 0, collection_count(tl) - 1 do
                        local t = tl[k2]
                        local tid = nil
                        pcall(function()
                            tid = normal_u32(t._TriggerId)
                        end)
                        if tid == id then
                            trig = t
                            break
                        end
                    end
                    if trig then break end
                end
                if trig then break end
            end
            A.native_trig_cache[id] = trig
        end
        if not trig then return end
        local tgt = valid(game_object) and game_object or pgo
        local joint = 0
        pcall(function()
            joint = tonumber(trig._OffsetJointHash) or 0
        end)
        local req = sc:call(REQUEST_SIGNATURE,
            trig, tgt, tgt, joint, false, false, 0, 0,
            nil, nil, nil, nil)
        if req then
            req = req:add_ref()
            req["<Container>k__BackingField"] = sc
            sc:call("trigger(soundlib.SoundManager.RequestInfo)", req)
            posted = true
        end
    end)
    if posted then return true end
    -- not on the player's lists -- fall back to the custom-bank route
    return post_event(id, game_object or first_horse(), lane or "fx")
end
rawset(_G, AUDIO_API_KEY, AUDIO_API)

-- ---------------------------------------------------------------------------
-- Frame loop
-- ---------------------------------------------------------------------------

-- tiny cross-module API (rodeo's one-button mount summon)
rawset(_G, "__iris_wild_horses_api", {
    -- Kept under the original name as a SHIM so IrisHorseRodeo.lua:9790 and any other
    -- external caller keeps working with no cross-file edit.
    force_next_horse = function() S.force_next_variant = "horse" end,
    force_next_unicorn = function() S.force_next_variant = "unicorn" end,
    -- The opposite: guarantee the NEXT doe spawn stays a doe. IrisTaming's hunt calls this
    -- immediately before conjuring its quarry.
    skip_next_horse = function() S.skip_next_doe = true end,
    -- rodeo's summon hands its spawned doe straight in: direct spawns can
    -- miss the ScaleMediator hook (it only fires when the engine applies a
    -- scale), so the summon flow must not rely on the mediator path
    -- SAFE TO CALL REPEATEDLY (the rodeo retries until verified): skips
    -- while already converted or while an apply job is in flight, and
    -- re-decides when a chance-roll lost or an apply window burned out
    -- 08-10: optional 2nd arg. Old 1-arg calls still mean "horse".
    convert_doe = function(transform, variant)
        if not valid(transform) then return end
        variant = (variant == "unicorn") and "unicorn" or "horse"
        local game_object = nil
        pcall(function() game_object = transform:call("get_GameObject") end)
        local address = game_object and object_address(game_object)
        local record = address and REGISTRY[address]
        if record and record.kind == "horse" then
            -- Already converted. ⚠ If the caller asked for a UNICORN and this body
            -- came back a plain horse (the mediator path can win the race), UPGRADE
            -- in place -- material only, never a second mesh swap. Without this the
            -- "call repeatedly until verified" contract can settle on the WRONG
            -- variant and report success.
            if variant == "unicorn" and record.variant ~= "unicorn" then
                record.variant = "unicorn"
                UNI.queue_promote(address, game_object)   -- mesh AND material
            end
            return -- done
        end
        for _, job in ipairs(S.pending_swaps) do
            if job.transform == transform then return end -- applying now
        end
        -- a mediator-path decision may have rolled AGAINST horse (or a
        -- previous apply failed out); the summon wants a horse — re-decide
        S.decisions[tostring(transform)] = nil
        -- ⭐ passed as an ARGUMENT, not via the global force flag: this call targets
        -- ONE specific body, and handle_spawn can early-return without consuming a
        -- global -- which would then leak the variant onto the next unrelated doe.
        pcall(handle_spawn, transform, variant)
    end,
    status = function() return tostring(S.status) end,
    -- 07-24 (Aurora #6): is this game object a CONVERTED horse (vs a wild
    -- doe)? Both are ch299011; only the registry knows the difference.
    is_horse = function(game_object)
        return registered_horse_ancestor(game_object) ~= nil
    end,
    -- 08-10: a unicorn is ALSO a horse (kind=="horse"), so is_horse stays true for
    -- it by design -- that is what keeps the ~15 downstream consumers working.
    is_unicorn = function(game_object)
        return UNI.is_unicorn(game_object) ~= nil
    end,
    -- JUMP PACK (08-06): bank 902 = horse_jump_pack.motlist, registered on
    -- every live horse by the per-frame tick. Returns nil until the motlist
    -- resource is actually loaded, so callers can fall back gracefully.
    jump_pack = function()
        if not valid(JP.holder) then return nil end
        return { bank = JP.bank, jump = 1, land = 2, buck = 3 }
    end,
    -- Ritual pack (bank 903) for the rodeo's RIDDEN blessing: the rodeo owns
    -- the mounted body's motion, so it plays gather/thrust itself and calls
    -- blessing_strike for the circle + heal at the moment of the headbutt.
    ritual_pack = function()
        if not RP.load() then return nil end
        return { bank = RP.bank, gather = 1, thrust = 2, eat = 3 }
    end,
    blessing_strike = function(go)
        if not valid(go) then return nil end
        local healed = nil
        pcall(function()
            local tf = go:call("get_Transform")
            local p = tf:call("get_Position")
            local rot = tf:call("get_Rotation")
            local fwd = UNI.qrot(rot, Vector3f.new(0.0, 0.0, 1.0), false)
            local circle = Vector3f.new(
                p.x + fwd.x * 1.6, p.y, p.z + fwd.z * 1.6)
            RP.spawn_circle(go, circle, rot)
            healed = RP.heal_party(circle)
            RP.heal_full(go, "unicorn (ridden strike)")
        end)
        return healed
    end,
})

-- ---------------------------------------------------------------------------
-- UNICORN BLESSING (2026-08-11, work-order build; 18-issue adversarial review
-- applied). Aurora's design: hold-key near your unicorn -> she lowers her horn
-- (RitualGather) -> thrusts (RitualThrust) -> a healing circle blooms at the
-- strike -> everyone inside it (and she) heals to full. All state on RP
-- (200-local ceiling law); cooldowns persist OUTSIDE the per-ritual table.
-- ---------------------------------------------------------------------------

RP.cooldowns = RP.cooldowns or {}   -- addr -> {t, rec}; rec identity catches address reuse
RP.blessing = nil
RP.blessing_status = "idle"

function RP.player_go()
    local go = nil
    pcall(function()
        local mgr = sdk.get_managed_singleton("app.CharacterManager")
        local chr = mgr and mgr:call("get_ManualPlayer")
        go = chr and chr:call("get_GameObject")
    end)
    return valid(go) and go or nil
end

function RP.go_pos(go)
    local pos = nil
    pcall(function() pos = go:call("get_Transform"):call("get_Position") end)
    return pos
end

function RP.native_max_hp(go)
    local hc = get_component(go, "app.HitController")
    if not hc then return nil end
    for _, name in ipairs({"get_MaxHitPoint", "get_MaxHp", "get_HpMax"}) do
        local v = nil
        if pcall(function() v = hc:call(name) end) then
            v = tonumber(v)
            if v and v > 0 then return v end
        end
    end
    return nil
end

function RP.heal_full(go, label)
    if not valid(go) then return false end
    local max = RP.native_max_hp(go)
    if not max then
        log("blessing: no max-hp getter answered for " .. tostring(label))
        return false
    end
    local ok = set_hp(go, max)
    local after = nil
    pcall(function()
        local hc = get_component(go, "app.HitController")
        after = hc and tonumber(hc:call("get_Hp"))
    end)
    -- Read-back logged on purpose: the reviewer flagged setter/getter scale as
    -- unverified on players/pawns -- the first in-game cast proves it here.
    log(string.format("blessing: heal %s max=%.0f setHp ok=%s readback=%s",
        tostring(label), max, tostring(ok), tostring(after)))
    return ok
end

function RP.heal_party(center)
    local healed = 0
    local function near(go)
        local p = go and RP.go_pos(go)
        if not (p and center) then return false end
        local dx, dy, dz = p.x - center.x, p.y - center.y, p.z - center.z
        return (dx * dx + dy * dy + dz * dz)
            <= (C.blessing_radius * C.blessing_radius)
    end
    local player = RP.player_go()
    if player and near(player) and RP.heal_full(player, "player") then
        healed = healed + 1
    end
    pcall(function()
        local pm = sdk.get_managed_singleton("app.PawnManager")
        if not pm then
            log("blessing: no app.PawnManager singleton")
            return
        end
        for _, getter in ipairs({"get_PartyPawnCharacterList",
                                 "getPartyPawnList", "get_PartyPawnList"}) do
            local list = nil
            if pcall(function() list = pm:call(getter) end) and list then
                local count = 0
                pcall(function() count = tonumber(list:call("get_Count")) end)
                for i = 0, (count or 0) - 1 do
                    pcall(function()
                        local chr = list:call("get_Item", i)
                        local go = chr and chr:call("get_GameObject")
                        if valid(go) and near(go)
                            and RP.heal_full(go, "pawn " .. i) then
                            healed = healed + 1
                        end
                    end)
                end
                return
            end
        end
        log("blessing: no pawn-list getter answered on app.PawnManager")
    end)
    return healed
end

function RP.shell_param_count()
    local count = 0
    pcall(function()
        count = tonumber(RP.shell_udata.ShellParams._items:get_size()) or 0
    end)
    if count == 0 then
        pcall(function() count = #RP.shell_udata.ShellParams._items end)
    end
    return tonumber(count) or 0
end

function RP.spawn_circle(owner_go, pos, rot)
    if not RP.shell_udata then
        RP.blessing_status = "shell userdata not warmed (arm step 5b)"
        return false
    end
    local ok, err = pcall(function()
        local count = RP.shell_param_count()
        if count <= 0 then error("ShellParams empty") end
        local idx = math.max(0, math.min(count - 1,
            math.floor(C.blessing_shell_idx or 0)))
        local param = RP.shell_udata.ShellParams._items[idx]
        if not param then error("shell param nil at index " .. idx) end
        -- ⛔ Reviewer blocker: the shell's collider is LIVE for its first
        -- frame(s), before the post-instance neuter can land. Zero the attack
        -- on the PARAM first (SkillMaker :5499) so even that window is safe.
        pcall(function() param["<AttackRate>k__BackingField"] = 0.0 end)
        if not RP.shell_req then
            local req = sdk.create_instance("app.ShellRequest.ShellCreateInfo")
            req = req and req:add_ref()
            if req then S.pins[#S.pins + 1] = req end
            RP.shell_req = req    -- ONE pinned request, hash rewritten per cast
        end
        if not RP.shell_req then error("ShellCreateInfo instance nil") end
        RP.shell_req.ShellParamIdHash = param._ShellParamIdHash
        local mgr = sdk.get_managed_singleton("app.ShellManager")
        if not mgr then error("no app.ShellManager") end
        RP.shell_req_id = mgr:call(
            "requestCreateShell(via.GameObject, via.vec3, via.Quaternion, "
            .. "app.ShellRequest.ShellCreateInfo, app.ShellParamData, "
            .. "app.ShellRequest.EventCreateShellSuccess, "
            .. "app.ShellRequest.EventBeforeShellInstantiate)",
            owner_go, pos, rot, RP.shell_req, RP.shell_udata, nil, nil)
        RP.shell_poll_left = 120
    end)
    if not ok then
        RP.blessing_status = "circle spawn failed: " .. tostring(err)
        log("blessing: " .. RP.blessing_status)
    end
    return ok == true
end

-- Belt over the braces: once the instance exists, hard-neuter it (decorative).
function RP.neuter_poll()
    if not (RP.shell_req_id and RP.shell_poll_left) then return end
    RP.shell_poll_left = RP.shell_poll_left - 1
    if RP.shell_poll_left <= 0 then
        log("blessing: shell instance never appeared for neutering (id "
            .. tostring(RP.shell_req_id) .. ")")
        RP.shell_req_id, RP.shell_poll_left = nil, nil
        return
    end
    pcall(function()
        local mgr = sdk.get_managed_singleton("app.ShellManager")
        local dict = mgr and mgr["<InstantiatedShellDict>k__BackingField"]
        local entry = dict and dict[RP.shell_req_id]
        local inst = entry and entry["<Shell>k__BackingField"]
        if not inst then return end
        pcall(function() inst["<ColliderStep>k__BackingField"] = 99999 end)
        pcall(function()
            inst:call("get_HitCtrl")
                :call("get_CachedRequestSetCollider"):call("set_Enabled", false)
        end)
        log("blessing: circle shell neutered (decorative)")
        RP.shell_req_id, RP.shell_poll_left = nil, nil
    end)
end

function RP.nearest_unicorn(range)
    local player = RP.player_go()
    local ppos = player and RP.go_pos(player)
    if not ppos then return nil end
    local best_addr, best_rec = nil, nil
    local best_d2 = (range or 5.0) * (range or 5.0)
    for addr, rec in pairs(REGISTRY) do
        if rec.variant == "unicorn" and valid(rec.game_object) then
            local p = RP.go_pos(rec.game_object)
            if p then
                local dx, dy, dz = p.x - ppos.x, p.y - ppos.y, p.z - ppos.z
                local d2 = dx * dx + dy * dy + dz * dz
                if d2 <= best_d2 then
                    best_addr, best_rec, best_d2 = addr, rec, d2
                end
            end
        end
    end
    return best_addr, best_rec
end

function RP.try_cast()
    local addr, rec = RP.nearest_unicorn(C.blessing_range)
    if not addr then
        RP.blessing_status = "no unicorn within range"
        return false
    end
    local cd = RP.cooldowns[addr]
    if cd and cd.rec == rec
        and os.clock() - cd.t < (C.blessing_cooldown or 120) then
        RP.blessing_status = string.format("cooling down (%.0fs left)",
            (C.blessing_cooldown or 120) - (os.clock() - cd.t))
        return false
    end
    local go = rec.game_object
    local character, motion, layer = character_motion(go)
    if not (valid(motion) and valid(layer)) then
        RP.blessing_status = "unicorn motion/layer not ready"
        return false
    end
    local pos, rot = nil, nil
    pcall(function()
        local tf = go:call("get_Transform")
        pos, rot = tf:call("get_Position"), tf:call("get_Rotation")
    end)
    if not (pos and rot) then
        RP.blessing_status = "unicorn transform unreadable"
        return false
    end
    RP.blessing = {
        addr = addr, rec = rec, layer = layer,
        pos = pos, rot = rot,
        phase = "gather", t0 = os.clock(), struck = false,
    }
    -- 2x: Aurora 08-11, "the initial idle should probably be half the length"
    RP.play(go, 1, "RitualGather", 2.0)
    RP.blessing_status = "gather"
    log("blessing: ritual started on unicorn " .. tostring(addr))
    return true
end

function RP.blessing_cleanup(aborted)
    local b = RP.blessing
    RP.blessing = nil
    if not b then return end
    if not aborted then
        RP.cooldowns[b.addr] = {t = os.clock(), rec = b.rec}
    end
    RP.blessing_status = aborted and "aborted" or "complete"
    log("blessing: " .. RP.blessing_status)
end

function RP.layer_frames(layer)
    local frame, endframe = nil, nil
    pcall(function() frame = tonumber(layer:call("get_Frame")) end)
    pcall(function() endframe = tonumber(layer:call("get_EndFrame")) end)
    return frame, endframe
end

-- Phase transitions ride the LIVE layer frame (atlas law: authored frame
-- counts are not wall time); wall-clock acts only as a watchdog. The first
-- 0.5s of every phase ignores frame reads -- changeMotion blends over ~4
-- frames and get_Frame briefly reports the OUTGOING clip.
function RP.blessing_tick()
    local now = os.clock()
    if C.blessing_enabled and not RP.blessing then
        local down = false
        pcall(function()
            down = reframework:is_key_down(C.blessing_key or 66) == true
        end)
        if down then
            RP.hold_t0 = RP.hold_t0 or now
            if now - RP.hold_t0 >= 0.4 then
                RP.hold_t0 = nil
                RP.try_cast()
            end
        else
            RP.hold_t0 = nil
        end
    end
    RP.neuter_poll()
    local b = RP.blessing
    if not b then return end
    local rec = REGISTRY[b.addr]
    if rec ~= b.rec or not (rec and valid(rec.game_object)) then
        return RP.blessing_cleanup(true)
    end
    local go = rec.game_object
    -- Gentle pin, position AND rotation, every frame of the ritual. The
    -- locomotion stomp is already prevented by the maintain_locomotion yield;
    -- this catches residual clip/physics drift.
    pcall(function()
        local tf = go:call("get_Transform")
        tf:call("set_Position", b.pos)
        tf:call("set_Rotation", b.rot)
    end)
    local t = now - b.t0
    local frame, endframe = RP.layer_frames(b.layer)
    if b.phase == "gather" then
        local done = (t > 0.5 and frame and endframe and endframe > 0
            and frame >= endframe - 6) or t > 2.2
        if done then
            b.phase, b.t0, b.struck = "thrust", now, false
            RP.play(go, 2, "RitualThrust")
            RP.blessing_status = "thrust"
        end
    elseif b.phase == "thrust" then
        if not b.struck and ((frame and t > 0.3 and frame >= 36) or t > 0.7) then
            b.struck = true
            local circle = nil
            pcall(function()
                local fwd = UNI.qrot(b.rot, Vector3f.new(0.0, 0.0, 1.0), false)
                local p = go:call("get_Transform"):call("get_Position")
                circle = Vector3f.new(
                    p.x + fwd.x * 1.6, p.y, p.z + fwd.z * 1.6)
            end)
            circle = circle or b.pos
            RP.spawn_circle(go, circle, b.rot)
            pcall(function() play_category("nicker", go) end)
            local healed = RP.heal_party(circle)
            RP.heal_full(go, "unicorn")
            RP.blessing_status = string.format(
                "blessing struck -- %d party healed", healed)
        end
        local done = (t > 0.5 and frame and endframe and endframe > 0
            and frame >= endframe - 4) or t > 2.5
        if done then b.phase, b.t0 = "linger", now end
    elseif b.phase == "linger" then
        if t > 3.0 then RP.blessing_cleanup(false) end
    end
end

-- Unicorn kill bounty: set_Exp + checkLevelUp(true) is the PROVEN growth
-- recipe (dd2-xp-discipline-edit, in-game verified 06-23 -- raw set_Exp alone
-- never levels; checkLevelUp fires the event and applies stat gains).
function RP.grant_kill_exp()
    local amount = math.floor(C.unicorn_kill_exp or 0)
    if amount <= 0 then return end
    local ok, err = pcall(function()
        local mgr = sdk.get_managed_singleton("app.CharacterManager")
        local chr = mgr and mgr:call("get_ManualPlayer")
        local human = chr and chr:call("get_Human")
        local sc = human and human:call("get_StatusContext")
        if not sc then error("no HumanStatusContext") end
        local cur = tonumber(sc:call("get_Exp")) or 0
        sc:call("set_Exp", cur + amount)
        human:call("checkLevelUp", true)
    end)
    log("unicorn bounty: +" .. amount .. " exp -- ok=" .. tostring(ok)
        .. (ok and "" or (" err=" .. tostring(err))))
    S.status = "unicorn slain -- +" .. amount .. " bonus exp"
end

-- ⭐ 08-11: "Reset scripts" destroys the ENTIRE Lua state (_G included -- proven
-- today), so the old "bookkeeping persists across reload" comment was wrong: every
-- reset ORPHANED the live sparkle emitters -- unkillable, frozen at their last
-- offset (the "there's 2 of them" sighting). This hook runs BEFORE the state dies:
-- kill every emitter so the next generation re-fires cleanly from saved config.
re.on_script_reset(function()
    pcall(function()
        for address in pairs(S.unicorns) do UNI.kill_efx(address) end
    end)
end)

re.on_frame(function()
    if S.generation ~= GENERATION then return end
    S.frame = S.frame + 1
    if not C.enabled then return end
    -- STAGGERED deferred boot (2026-08-05): one action every ~1.5 s after a
    -- 10-second quiet hold, each logged, offset +45 frames from IrisWildCats
    -- so the two modules' steps interleave distinctly in the log. The crash
    -- timestamp names the guilty step — or clears both modules if the game
    -- dies during the quiet phase.
    if not WORLD_ARMED then
        if not S.arm_ready_frame then
            if S.frame % 30 ~= 0 then return end
            if not world_ready() then return end
            S.arm_ready_frame = S.frame
            -- 08-07 COLLAPSED (the crash-day queue's own plan: "collapse
            -- timings once stable, keep the step logging"): the forensic
            -- 1365-frame hold + 90-frame steps made every reset ~30 s of
            -- doe before the horse appeared. Killers were devtools
            -- disable-aggro + shader cache, not these steps -- all
            -- exonerated on tape. Offset +45 from IrisWildCats kept.
            -- 08-07 r2 (Aurora: "load faster"): collapsed AGAIN, 165->60
            -- quiet + 15->5 step spacing (~4.3s -> ~1.5s to armed). The
            -- step logging stays -- if a crash ever returns, the last
            -- logged step still names the guilty stage.
            log("world live; holding quiet for 60 frames before arming")
            return
        end
        local elapsed = S.frame - S.arm_ready_frame
        if elapsed < 60 then return end
        local step = S.arm_step or 0
        if elapsed < 60 + step * 5 then return end
        S.arm_step = step + 1
        if step == 0 then
            log("arm step 1a: create horse MESH resource")
            pcall(function()
                local resource = sdk.create_resource(
                    "via.render.MeshResource", HORSE_MESH_PATH)
                if resource then
                    R.mesh_holder = resource:create_holder(
                        "via.render.MeshResourceHolder")
                    if R.mesh_holder then R.mesh_holder:add_ref() end
                end
            end)
            log("mesh resource holder valid: " .. tostring(valid(R.mesh_holder)))
        elseif step == 1 then
            log("arm step 1b: create horse MDF MATERIAL resource")
            pcall(function()
                local resource = sdk.create_resource(
                    "via.render.MeshMaterialResource", HORSE_MDF_PATH)
                if resource then
                    R.mdf_holder = resource:create_holder(
                        "via.render.MeshMaterialResourceHolder")
                    if R.mdf_holder then R.mdf_holder:add_ref() end
                end
            end)
            log("mdf resource holder valid: " .. tostring(valid(R.mdf_holder)))
            if valid(R.mesh_holder) and valid(R.mdf_holder) then
                R.resource_status = "horse mesh resources loaded"
            end
        elseif step == 2 then
            log("arm step 2: installing Wwise trigger hook")
            install_horse_trigger_hook()
        elseif step == 3 then
            log("arm step 3: installing damage hook")
            install_damage_hook()
        elseif step == 4 then
            log("arm step 4: installing ScaleMediator spawn hook")
            install_scale_hook()
        else
            log("arm step 5: frame work live (conversions + locomotion + audio)")
            install_climb_prefab_swap()
            -- ⭐ 08-11 WARM THE UNICORN MESH AT BOOT, minutes before any spawn can use
            -- it. Root cause of "first unicorn invisible, then every retry throws":
            -- the COLD create_resource trap (documented for EFX in IrisWoodcutting) --
            -- create_resource is ASYNC, so a holder made and USED in the same breath
            -- wraps a HOLLOW resource: the first setMesh "succeeds" but renders
            -- nothing, and the hollow holder then throws on every later setMesh.
            -- The one session that worked was the one where the load happened long
            -- before the spawn. This arm step runs ~15 s after boot = plenty of lead.
            if C.unicorn_mesh_enabled then load_unicorn_resources() end
            -- Own logged step (reviewer: one action per step, so a crash names
            -- it). Userdata is ASYNC like resources -- warmed here, first used
            -- at a cast minutes later.
            log("arm step 5b: warming blessing shell userdata ("
                .. tostring(C.blessing_shell_path) .. ")")
            pcall(function()
                local udata = sdk.create_userdata("app.ShellParamData",
                    C.blessing_shell_path)
                if udata then
                    udata:add_ref()
                    S.pins[#S.pins + 1] = udata
                    RP.shell_udata = udata
                end
            end)
            WORLD_ARMED = true
            -- 08-07 r2 CATCH-UP SWEEP (Aurora: "load faster"): does that
            -- spawned BEFORE the ScaleMediator hook installed never fire
            -- it, so on every area load the first herd stayed vanilla
            -- until fresh spawns rolled. Feed every live character
            -- through handle_spawn once -- it filters (doe prefix,
            -- per-transform decision dedup) and rolls exactly like a
            -- hook-caught spawn.
            pcall(function()
                local swept = 0
                local scene_manager = sdk.get_native_singleton(
                    "via.SceneManager")
                local scene_type = sdk.find_type_definition(
                    "via.SceneManager")
                local scene = sdk.call_native_func(
                    scene_manager, scene_type, "get_CurrentScene()")
                local list = scene and scene:call(
                    "findComponents(System.Type)",
                    sdk.typeof("app.Character"))
                local elements = {}
                pcall(function() elements = list:get_elements() end)
                for _, character in ipairs(elements) do
                    pcall(function()
                        local go = character:call("get_GameObject")
                        local tf = valid(go)
                            and go:call("get_Transform")
                        if tf then
                            handle_spawn(tf)
                            swept = swept + 1
                        end
                    end)
                end
                log(string.format(
                    "catch-up sweep: %d characters fed to handle_spawn",
                    swept))
            end)
        end
        return
    end
    local now = os.clock()

    -- A horse stored in the shared IRIS stable still serialises on the
    -- native doe chassis (ch299011). On restore/switch the new body must be
    -- converted deterministically; applying the ordinary 25% world roll
    -- would bring a tamed horse back as a doe three times out of four.
    if now >= (tonumber(S.next_stable_horse_check) or 0.0) then
        S.next_stable_horse_check = now + 1.0
        pcall(function()
            local bridge = rawget(_G, "IrisGriffinBridge")
            local info = bridge and bridge.companion_info
                and bridge.companion_info()
            if not (info and info.kind == "horse") then return end
            local character = bridge.griffin and bridge.griffin()
            local game_object = character
                and character:call("get_GameObject")
            if not valid(game_object) then return end
            -- ⭐ 08-10: passed as an ARGUMENT so the restore is DETERMINISTIC, and
            -- `variant` now genuinely arrives (companion_info projects it).
            local want = (info.variant == "unicorn") and "unicorn" or "horse"
            local root = registered_horse_ancestor(game_object)

            if root then
                -- ⭐⭐ SELF-HEAL. Aurora 08-10: clicking "Force next doe to UNICORN" and
                -- then summoning a tamed HORSE produced a unicorn. The panel's global
                -- force flag is consumed by whichever doe the ScaleMediator reports
                -- next -- INCLUDING a companion body the stable is about to claim, and
                -- the mediator wins that race. Rather than fight the race, the STABLE
                -- RECORD IS AUTHORITATIVE: if the live body disagrees with it, the body
                -- gets corrected, never the record.
                local addr = object_address(root)
                local rec = addr and REGISTRY[addr]
                if not rec then return end
                local live = (rec.variant == "unicorn") and "unicorn" or "horse"
                if live == want then return end
                if want == "unicorn" then
                    rec.variant = "unicorn"
                    UNI.queue_promote(addr, root)   -- mesh AND material
                else
                    -- Demote. ⛔ The first version queued another apply_horse here on
                    -- the theory that set_Material repaints the body. IT DOES NOT --
                    -- per-instance material params survive re-assigning the same
                    -- resource, so Chad stayed a frozen unicorn (out of S.unicorns, so
                    -- no rainbow and no sparkle either: one bug, three symptoms).
                    -- The revert has to write the stock values back explicitly.
                    UNI.kill_efx(addr)
                    S.unicorns[addr] = nil
                    rec.variant = nil
                    -- ⛔ Cancel any material job already queued for this body, or it
                    -- lands AFTER the reset and paints it straight back to a unicorn.
                    for qi = #S.pending_materials, 1, -1 do
                        if S.pending_materials[qi].address == addr then
                            table.remove(S.pending_materials, qi)
                        end
                    end
                    UNI.reset_material(root)
                    -- ⚠ With unicorn.mesh in play the demote must also put the BODY
                    -- back: a demoted unicorn is still wearing horn+mane geometry
                    -- otherwise. Re-running apply_horse with variant=nil re-swaps to
                    -- the plain horse mesh (reset_material above clears the params,
                    -- which set_Material alone would NOT do).
                    if C.unicorn_mesh_enabled then
                        local tf = root:call("get_Transform")
                        if valid(tf) then
                            S.pending_swaps[#S.pending_swaps + 1] = {
                                go = root, transform = tf, due = now,
                                attempts = 0, variant = nil}
                        end
                    end
                end
                log("stable variant self-heal: live '" .. live
                    .. "' corrected to '" .. want .. "' from the stable record")
                return
            end

            local transform = game_object:call("get_Transform")
            if not valid(transform) then return end
            for _, job in ipairs(S.pending_swaps) do
                if job.transform == transform then return end
            end
            S.decisions[tostring(transform)] = nil
            -- Drop any stale panel force flag: this body's identity comes from the
            -- stable, and a leftover flag would otherwise hit the NEXT wild doe too.
            S.force_next_variant = nil
            handle_spawn(transform, want)
            log("stable horse restore: forced ch299011 body into "
                .. want .. " conversion")
        end)
    end

    ox_remap_tick()

    -- OX motion-id capture: sample the observed ox's layer every frame and
    -- record (bank, id, end_frame) transitions -> data/OxMotionCapture.json.
    -- Matches ids to clip names offline via frame counts in
    -- data/PlanF_OxHorse/ox_motlist_slot_map.json.
    local cap = S.ox_capture
    if cap and cap.enabled and valid(cap.go) then
        pcall(function()
            local _, _, layer = character_motion(cap.go)
            local sample = read_layer(layer)
            if sample then
                local key = tostring(sample.bank) .. ":" .. tostring(sample.id)
                if key ~= cap.last_key then
                    cap.last_key = key
                    cap.seq[#cap.seq + 1] = {
                        t = math.floor(now * 10) / 10,
                        bank = sample.bank,
                        id = sample.id,
                        end_frame = sample.end_frame,
                    }
                    if #cap.seq % 5 == 0 or #cap.seq == 1 then
                        json.dump_file("OxMotionCapture.json", cap.seq)
                    end
                end
            end
        end)
    end

    -- Deferred mesh swaps (renderer needs a beat after spawn).
    for index = #S.pending_swaps, 1, -1 do
        local job = S.pending_swaps[index]
        if now >= job.due then
            job.attempts = job.attempts + 1
            local ok, reason = apply_horse(job)
            if ok or job.attempts >= 20 or not valid(job.go) then
                if not ok then
                    S.failures = S.failures + 1
                    S.status = "horse swap failed: " .. tostring(reason)
                    log(S.status)
                end
                table.remove(S.pending_swaps, index)
            else
                job.due = now + 0.20
            end
        end
    end

    -- UNICORN material writes ride their OWN queue (see apply_horse -- they must
    -- never be appended to S.pending_swaps). RETRIED UNTIL A WRITE ACTUALLY LANDS:
    -- getMaterialVariableNum legitimately reads 0 until the freshly-swapped material
    -- is resident, and a single deferred attempt would leave an ordinary-looking
    -- horse with no error logged anywhere.
    for index = #S.pending_materials, 1, -1 do
        local job = S.pending_materials[index]
        if now >= job.due then
            job.attempts = job.attempts + 1
            local writes = 0
            if valid(job.go) then writes = UNI.apply_material(job.go) end
            if writes > 0 or job.attempts >= 20 or not valid(job.go) then
                if writes > 0 then
                    log(string.format(
                        "unicorn material applied: %d/%d params -- %s",
                        writes, UNI.last_attempted, UNI.last_write_detail))
                else
                    log("unicorn material FAILED after " .. job.attempts
                        .. " attempts -- " .. UNI.last_write_detail)
                end
                table.remove(S.pending_materials, index)
            else
                job.due = now + 0.20
            end
        end
    end

    -- UNICORN follower sparkle + periodic material re-assert.
    -- This loop is ALSO the EFX teardown: the 30 s reaper below deletes the REGISTRY
    -- record, this notices the record is gone and destroys the emitter. One owner for
    -- the lifecycle rather than two bookkeeping stores that can drift apart.
    -- UNICORN upkeep: rainbow tint, periodic material re-assert, sparkle lifecycle.
    -- ⭐ No position writing here -- requestEffect's follow mode makes the ENGINE track
    -- the creature, which also means nothing to fix up across a zone transition.
    -- This loop is ALSO the teardown: the 30 s reaper below drops the REGISTRY record,
    -- this notices and calls finishAll. One owner for the lifecycle.
    for address, entry in pairs(S.unicorns) do
        local record = REGISTRY[address]
        local alive = record and record.variant == "unicorn"
            and valid(record.game_object)
        if not alive then
            UNI.kill_efx(address)
            S.unicorns[address] = nil
        else
            entry.game_object = record.game_object
            -- Rainbow: emissive colours only, ~20 Hz. The full 22-param walk stays on
            -- the slow re-assert -- it has no business running at animation rate.
            if C.unicorn_rainbow and now >= (entry.next_tint or 0)
                and ((C.unicorn_body_glow or 0) > 0.001
                     or (C.unicorn_horn_glow or 0) > 0.001) then
                entry.next_tint = now + 0.05
                UNI.tint(record.game_object)
                if entry.container and C.unicorn_efx_color then
                    pcall(function()
                        UNI.tint_effect(entry.container, UNI.glow_color())
                    end)
                end
            end
            -- Sparkle re-request cadence (harmless for looping elements like 11 --
            -- spawn_efx finishes the previous container first, so no stacking).
            if C.unicorn_efx_enabled and now >= (entry.next_efx or 0) then
                entry.next_efx = now + (C.unicorn_efx_interval or 2.0)
                UNI.spawn_efx(address)
            elseif not C.unicorn_efx_enabled and entry.container then
                UNI.kill_efx(address)
            end
            -- Blessing HP: heal to full once per unicorn registration (the
            -- 1000 "base HP" is damage scaling, so this just tops the native
            -- pool; rec.base_hp is the future IV override).
            if not entry.hp_boosted then
                entry.hp_boosted = true
                pcall(function()
                    RP.heal_full(record.game_object, "unicorn promote")
                end)
            end
            -- Kill bounty: granted once, the frame the body reads dead.
            if not entry.exp_granted then
                pcall(function()
                    local ch = get_component(record.game_object,
                        "app.Character")
                    if ch and ch:call("get_IsDead") == true then
                        entry.exp_granted = true
                        RP.grant_kill_exp()
                    end
                end)
            end
            -- ⭐ glue tick (20 Hz): looping effects keep their FIRST fire position
            -- forever, so the bolt is enforced by writing the effect's transform,
            -- not by fire-time offsets. See UNI.glue_efx.
            if C.unicorn_efx_enabled and C.unicorn_efx_auto and entry.container
                and now >= (entry.next_glue or 0) then
                entry.next_glue = now + 0.05
                UNI.glue_efx(entry, record.game_object)
            end
            if (C.unicorn_reassert_s or 0) > 0
                and now >= (entry.next_reassert or 0) then
                entry.next_reassert = now + C.unicorn_reassert_s
                pcall(function() UNI.apply_material(record.game_object) end)
            end
        end
    end

    -- Blessing ritual state machine + shell neuter poll + cast-key hold.
    if WORLD_ARMED then pcall(RP.blessing_tick) end

    -- Audio auto-load once any horse exists.
    if C.audio_enabled and not A.registration
        and S.frame >= (A.next_auto_prepare or 0) then
        if first_horse() and player_wwise_container() then
            A.next_auto_prepare = S.frame + 600
            audio_prepare()
        end
    end
    resolve_pending_triggers()
    drain_contacts()
    -- skill-impact audition (08-07): step through Aurora's browser ids
    if S.fx_audition then
        local a = S.fx_audition
        if os.clock() >= (a.next_t or 0) then
            -- 08-07: MEAT_DMG family (Aurora's second find -- damage
            -- banks are resident, the JOB01 skill ids posted silent)
            local ids = {
                263026718, 542625148, 3032922912, 2034376889,
                4006873589, 4207351981, 2431987538, 1424345547,
                2387725328, 1450260778,
            }
            a.idx = (a.idx or 0) + 1
            local id = ids[a.idx]
            if not id then
                S.fx_audition = nil
                S.fx_audition_status = "audition done -- which number?"
            else
                a.next_t = os.clock() + 1.5
                local ok = AUDIO_API.play_event(id, first_horse())
                local line = string.format(
                    "fx audition %d/%d: id=%d posted=%s",
                    a.idx, #ids, id, tostring(ok))
                log(line)
                S.fx_audition_status = line
            end
        end
    end

    -- 20 Hz per-horse maintenance.
    if now >= S.next_sample then
        S.next_sample = now + 0.05
        -- Pause/photo-mode detection: flag names VERIFIED by the griffin
        -- pause probe (round 61) — PauseManager.isPausedAny + GuiManager
        -- photo-mode/GUI-pause getters.
        S.game_paused = false
        pcall(function()
            local manager = sdk.get_managed_singleton("app.PauseManager")
            if manager and manager:call("isPausedAny") == true then
                S.game_paused = true
            end
        end)
        if not S.game_paused then
            pcall(function()
                local gui = sdk.get_managed_singleton("app.GuiManager")
                if gui then
                    if gui:call("get_IsDispPhotoModeAll") == true
                        or gui:call("get_IsDispPhotoMode") == true
                        or gui:call("isPausedGUI") == true then
                        S.game_paused = true
                    end
                end
            end)
        end
        for _, record in pairs(REGISTRY) do
            update_horse(record, now)
        end
        for key, state in pairs(S.horses) do
            if now - (state.seen_at or 0) > 2.0
                or not valid(state.game_object) then
                S.horses[key] = nil
            end
        end
    end

    -- SCALE GUARD (07-23 "the horse has become tiny"; 07-24 Aurora #5 "it
    -- keeps shrinking to half then back"): the engine's ScaleMediator —
    -- AND, once tamed, the griffin stable's per-frame 0.75 "rider size"
    -- target (griffin_apply_body_scale) — stomp the converted horse.
    -- Run EVERY FRAME now (was 1s → that made the shrink/return oscillate
    -- against the per-frame griffin write). IrisWildHorses loads AFTER the
    -- griffin probe, so this is the last writer each frame = horse_scale
    -- wins, steady. Writes only on drift, so it's cheap.
    for _, record in pairs(REGISTRY) do
        if record.kind == "horse" and valid(record.game_object) then
            pcall(function()
                local transform = record.game_object:call("get_Transform")
                local scale = transform:call("get_LocalScale")
                if math.abs((scale.x or 0) - C.horse_scale) > 0.01 then
                    transform:call("set_LocalScale", Vector3f.new(
                        C.horse_scale, C.horse_scale, C.horse_scale))
                end
            end)
        end
    end

    -- Housekeeping: stale decisions + dead registry records.
    if now >= S.next_cleanup then
        S.next_cleanup = now + 30.0
        for key, decision in pairs(S.decisions) do
            if now - (decision.decided_at or now) > 600.0
                or not valid(decision.transform) then
                S.decisions[key] = nil
            end
        end
        for address, record in pairs(REGISTRY) do
            if record.kind == "horse" and not valid(record.game_object) then
                REGISTRY[address] = nil
            end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- UI: one panel
-- ---------------------------------------------------------------------------

re.on_draw_ui(function()
    if S.generation ~= GENERATION then return end
    if not imgui.collapsing_header("IRIS - Wild Horses") then return end

    local changed, value
    changed, value = imgui.checkbox("Enabled##iris_horses", C.enabled)
    if changed then C.enabled = value; save_config() end

    changed, value = imgui.slider_float(
        "Horse share of doe spawns", C.horse_chance, 0.0, 1.0, "%.2f")
    if changed then C.horse_chance = value; save_config() end

    changed, value = imgui.slider_float("Horse scale", C.horse_scale, 0.5, 2.5)
    if changed then C.horse_scale = value; save_config() end

    changed, value = imgui.slider_float(
        "Horse speed", C.horse_speed, 0.8, 1.5, "%.2f")
    if changed then C.horse_speed = value; save_config() end

    changed, value = imgui.checkbox(
        "Custom walk / trot / gallop", C.custom_locomotion_enabled)
    if changed then
        C.custom_locomotion_enabled = value
        if value then L.resource_attempted = false; load_motlist() end
        save_config()
    end
    -- Bank 902 (Gallop_Jump / Jump_toIdle / Buck) as its own switch, so the two custom
    -- motlists can be halved independently. Added during the 08-09 mount-crash hunt; that
    -- crash turned out to be an untyped GUI write in IrisHorseRodeo, so the motlists are
    -- NOT implicated -- the switches simply stay useful for future animation bisects.
    changed, value = imgui.checkbox("Jump / buck pack (bank 902)", C.jump_pack_enabled ~= false)
    if changed then C.jump_pack_enabled = value; save_config() end

    changed, value = imgui.checkbox("Horse sounds", C.audio_enabled)
    if changed then C.audio_enabled = value; save_config() end
    imgui.same_line()
    changed, value = imgui.checkbox("Silence doe sounds", C.suppress_doe_audio)
    if changed then C.suppress_doe_audio = value; save_config() end
    imgui.same_line()
    changed, value = imgui.checkbox("Ambient vocals", C.ambient_enabled)
    if changed then C.ambient_enabled = value; save_config() end

    if imgui.button("Force next doe to horse") then
        S.force_next_variant = "horse"
        S.status = "next newly spawned doe will be a horse"
    end
    imgui.same_line()
    if imgui.button("Force next doe to UNICORN") then
        S.force_next_variant = "unicorn"
        S.status = "next newly spawned doe will be a UNICORN"
    end
    imgui.same_line()
    if imgui.button("Reload resources") then
        load_render_resources()
        L.resource_attempted = false
        load_motlist()
    end
    imgui.same_line()
    if imgui.button("Probe unicorn resources") then
        UNI.probe_resources()
    end

    local live = 0
    for _ in pairs(S.horses) do live = live + 1 end
    imgui.text(string.format(
        "Doe spawns: %d | horses: %d | applied: %d | failed: %d | live now: %d",
        S.spawned_does, S.horse_decisions, S.applied, S.failures, live))
    imgui.text(string.format(
        "Audio: %s | direct triggers: %d | contacts: %d | doe sounds muted: %d",
        (C.audio_enabled and audio_ready()) and "READY"
            or (A.registration and "settling" or "waiting for a horse"),
        A.direct_count or 0, A.contacts_replaced or 0, A.suppressed or 0))
    imgui.text("Locomotion resource: " .. tostring(L.resource_status))
    imgui.text("Audio status: " .. tostring(S.audio_status))
    if A.last_played then
        imgui.text("Last sound: " .. tostring(A.last_played))
    end
    imgui.text("Status: " .. tostring(S.status))

    if imgui.tree_node("Unicorn##iris_wild_horses_unicorn") then
        changed, value = imgui.checkbox(
            "Unicorns enabled##uni_on", C.unicorn_enabled)
        if changed then C.unicorn_enabled = value; save_config() end

        changed, value = imgui.slider_float(
            "Unicorn share of HORSES", C.unicorn_chance, 0.0, 1.0, "%.3f")
        if changed then C.unicorn_chance = value; save_config() end

        changed, value = imgui.checkbox(
            "Night spawns only##uni_night", C.unicorn_night_only)
        if changed then C.unicorn_night_only = value; save_config() end
        -- Say the quiet part out loud: this gates the SPAWN ROLL, not the creature.
        imgui.text("  (gates the roll at spawn time -- a unicorn that spawned")
        imgui.text("   at night stays a unicorn through the following day)")

        -- ⛔ These two were ONE slider and that made the first build a blown-white
        -- silhouette: the full-surface emissive drowned the coat at any usable value.
        -- Rim glows the outline and leaves the coat readable; body emits everywhere.
        local repaint_all = function()
            for _, rec in pairs(REGISTRY) do
                if rec.variant == "unicorn" and valid(rec.game_object) then
                    pcall(function() UNI.apply_material(rec.game_object) end)
                end
            end
        end

        changed, value = imgui.slider_float(
            "Rim glow (silhouette)", C.unicorn_glow, 0.0, 4.0, "%.2f")
        if changed then
            C.unicorn_glow = value; save_config(); repaint_all()
        end

        changed, value = imgui.slider_float(
            "Body glow (whole surface)", C.unicorn_body_glow, 0.0, 2.0, "%.2f")
        if changed then
            C.unicorn_body_glow = value; save_config(); repaint_all()
        end
        imgui.text("  (body glow past ~0.4 starts washing the coat out;")
        imgui.text("   0 = coat and shading fully intact, rim glow only)")

        -- The horn lives on its OWN material (oral_mat), so it burns independently of
        -- the coat -- a small surface can take far more emissive before it blows out.
        -- v1.1: horn AND mane share oral_mat, so one control drives both. Splitting them
        -- needed a 5th material, and that is what crashed twice.
        changed, value = imgui.slider_float(
            "Horn + mane glow", C.unicorn_horn_glow, 0.0, 4.0, "%.2f")
        if changed then
            C.unicorn_horn_glow = value; save_config(); repaint_all()
        end

        -- ⛔ The one switch that can CRASH if flipped without the asset installed.
        changed, value = imgui.checkbox(
            "Unicorn BODY mesh (horn + split mane)##uni_mesh", C.unicorn_mesh_enabled)
        if changed then
            C.unicorn_mesh_enabled = value
            R.uni_failed = false            -- allow one fresh attempt after a toggle
            save_config()
        end
        imgui.text("  ⛔ install IRIS_08_unicorn.pak FIRST -- requesting a path the")
        imgui.text("   engine cannot serve is an instant CTD, not a failed load.")
        imgui.text("  mesh: " .. tostring(R.unicorn_status or "not requested yet"))

        -- ⛔ Every custom-mdf2 build so far CTD'd in EyeGlowController.onUpdate (v1.0
        -- five-mat AND v1.2 four-mat), while stock horse.mdf2 (v1.1) is proven stable.
        changed, value = imgui.checkbox(
            "WHITE-ALBEDO mdf2 (EXPERIMENT -- has crashed; sweep now logged)##uni_cmdf",
            C.unicorn_custom_mdf)
        if changed then
            C.unicorn_custom_mdf = value
            R.uni_failed = false
            R.uni_mdf_holder = nil
            save_config()
            -- warm IMMEDIATELY on arming, so the 4 s age gate starts counting now
            -- rather than at the next spawn (which would defer that spawn pointlessly)
            if value then load_unicorn_resources() end
        end
        imgui.text("  off = stock horse.mdf2, stable, dark horn/mane accents")
        imgui.text("  on  = white coat possible; if it crashes, copy the log FIRST")

        -- ⛔ BaseColor MULTIPLIES the albedo -- it can darken but never lighten, so a
        -- white coat is simply unreachable that way. MaskColor may be a colour REPLACE.
        changed, value = imgui.checkbox(
            "Try MaskColor (may allow a WHITE coat)##uni_mask", C.unicorn_maskcolor)
        if changed then
            C.unicorn_maskcolor = value
            if not value then
                for _, rec in pairs(REGISTRY) do
                    if rec.variant == "unicorn" and valid(rec.game_object) then
                        pcall(function() UNI.reset_material(rec.game_object) end)
                    end
                end
            end
            save_config(); repaint_all()
        end
        changed, value = imgui.slider_float(
            "MaskColor blend", C.unicorn_maskcolor_rate, 0.0, 1.0, "%.2f")
        if changed then
            C.unicorn_maskcolor_rate = value; save_config(); repaint_all()
        end

        changed, value = imgui.checkbox(
            "Rainbow shimmer##uni_rainbow", C.unicorn_rainbow)
        if changed then C.unicorn_rainbow = value; save_config(); repaint_all() end
        changed, value = imgui.slider_float(
            "Shimmer speed (cycles/s)", C.unicorn_rainbow_speed, 0.0, 1.0, "%.3f")
        if changed then C.unicorn_rainbow_speed = value; save_config() end

        imgui.text("--- Sparkle (ObjectEffectManager2, engine-followed) ---")
        changed, value = imgui.checkbox(
            "Sparkle enabled##uni_efx_on", C.unicorn_efx_enabled)
        if changed then
            C.unicorn_efx_enabled = value; save_config()
            if not value then
                for address in pairs(S.unicorns) do UNI.kill_efx(address) end
            end
        end
        imgui.text("Container .pfb:")
        changed, value = imgui.input_text(
            "##uni_efx_container", C.unicorn_efx_container or "")
        if changed then
            C.unicorn_efx_container = tostring(value or "")
            UNI.efx_ids, UNI.efx_ids_key = nil, nil
            save_config()
        end
        imgui.text("Element group:")
        changed, value = imgui.input_text(
            "##uni_efx_element", C.unicorn_efx_element or "")
        if changed then
            C.unicorn_efx_element = tostring(value or "")
            UNI.efx_ids, UNI.efx_ids_key = nil, nil
            save_config()
        end
        changed, value = imgui.slider_int(
            "Element index", C.unicorn_efx_index, 0, 24)
        if changed then C.unicorn_efx_index = value; save_config() end
        imgui.text("Joint (blank = auto-pick on the HORSE skeleton):")
        changed, value = imgui.input_text(
            "##uni_efx_joint", C.unicorn_efx_joint or "")
        if changed then
            C.unicorn_efx_joint = tostring(value or "")
            for _, e in pairs(S.unicorns) do e.joint = nil end
            save_config()
        end
        -- ⛔ Do NOT paste a player joint name here (L_Breast etc.) -- the horse rides
        -- the doe skeleton and those joints simply do not exist on it.
        changed, value = imgui.slider_float(
            "Re-fire every (s)", C.unicorn_efx_interval, 0.25, 10.0, "%.2f")
        if changed then C.unicorn_efx_interval = value; save_config() end

        changed, value = imgui.checkbox(
            "BOLT to horn tip (auto -- recommended)##uni_efx_auto", C.unicorn_efx_auto)
        if changed then C.unicorn_efx_auto = value; save_config() end
        changed, value = imgui.slider_float(
            "Position along horn", C.unicorn_efx_tip, 0.0, 2.0, "%.2f")
        if changed then C.unicorn_efx_tip = value; save_config() end
        imgui.text("  (0 = horn base, 1 = tip, 2 = floating past the tip;")
        imgui.text("   trim sliders below = WORLD-axis nudge on the anchor -- tune it")
        imgui.text("   ONCE on any unicorn and it holds for every horse, any facing;")
        imgui.text("   Y is up; X/Z are compass axes. Re-fires INSTANTLY per change)")
        if R.efx_bolt_debug then imgui.text("  " .. R.efx_bolt_debug) end

        -- Trim in the horse-body frame; every nudge kills + re-fires the emitter so
        -- the feedback loop is immediate (slider-lag made hand-tuning impossible).
        local function refire_now()
            for address, e in pairs(S.unicorns) do
                e.next_efx = 0.0
                UNI.kill_efx(address)
            end
        end
        changed, value = imgui.slider_float(
            "Trim X (world)", C.unicorn_efx_ox, -3.0, 3.0, "%.2f")
        if changed then C.unicorn_efx_ox = value; save_config(); refire_now() end
        changed, value = imgui.slider_float(
            "Trim up (Y)", C.unicorn_efx_oy, -3.0, 3.0, "%.2f")
        if changed then C.unicorn_efx_oy = value; save_config(); refire_now() end
        changed, value = imgui.slider_float(
            "Trim Z (world)", C.unicorn_efx_oz, -3.0, 3.0, "%.2f")
        if changed then C.unicorn_efx_oz = value; save_config(); refire_now() end
        changed, value = imgui.slider_float(
            "Sparkle scale", C.unicorn_efx_scale, 0.05, 6.0, "%.2f")
        if changed then C.unicorn_efx_scale = value; save_config() end
        changed, value = imgui.slider_float(
            "Skip intro (frames/s)", C.unicorn_efx_skip, 0.0, 120.0, "%.1f")
        if changed then C.unicorn_efx_skip = value; save_config() end
        imgui.text("  (scale + skip are BEST EFFORT -- the status line below says")
        imgui.text("   which method took. If it says NO API, use Dump effect API.)")

        if imgui.button("Re-fire sparkle now##uni_efx_refire") then
            for address, e in pairs(S.unicorns) do
                e.next_efx = 0.0
                e.joint = nil        -- re-pick, so a changed preference actually applies
                UNI.kill_efx(address)
            end
            S.status = "sparkle re-fired with current offset/scale + joint re-picked"
        end
        imgui.same_line()
        if imgui.button("Dump effect API##uni_efx_api") then
            UNI.dump_effect_api()
        end
        changed, value = imgui.checkbox(
            "Tint sparkle to coat##uni_efx_col", C.unicorn_efx_color)
        if changed then C.unicorn_efx_color = value; save_config() end

        local unicorns, emitters = 0, 0
        for address, entry in pairs(S.unicorns) do
            local rec = REGISTRY[address]
            if rec and rec.variant == "unicorn" then unicorns = unicorns + 1 end
            if entry.container then emitters = emitters + 1 end
        end
        imgui.text(string.format("Live unicorns: %d | sparkles: %d | night: %s",
            unicorns, emitters, tostring(UNI.is_night())))
        for _, entry in pairs(S.unicorns) do
            if entry.joint then
                imgui.text("Attached joint: " .. tostring(entry.joint))
                break
            end
        end
        imgui.text(string.format("Last material write: %d/%d -- %s",
            UNI.last_writes, UNI.last_attempted, tostring(UNI.last_write_detail)))
        imgui.text("EFX: " .. tostring(UNI.efx_status))
        if UNI.glue_status then imgui.text("Glue: " .. tostring(UNI.glue_status)) end
        if UNI.tint_failed then
            imgui.text("  ⚠ sparkle TINT failed -- effect left at its native colour")
        end
        imgui.text("Scale/skip: " .. tostring(UNI.efx_extras or "not attempted"))

        -- Diagnose the sparkle WITHOUT needing a live unicorn: resolves the container
        -- and reports through the EFX status line above.
        if imgui.button("Test fire on PLAYER##uni_efx_player") then
            UNI.test_fire_player()
        end
        imgui.same_line()
        if imgui.button("Test EFX resolve##uni_efx_test") then
            UNI.efx_ids, UNI.efx_ids_key = nil, nil
            local mgr = UNI.player_manager()
            if not mgr then
                UNI.efx_status = "efx: no ObjectEffectManager2 on the player"
            else
                UNI.resolve_effect_id()
            end
        end
        imgui.same_line()
        if imgui.button("List EFX containers##uni_efx_list") then
            local names = {}
            pcall(function()
                local mgr = UNI.player_manager()
                local containers = mgr and mgr.ExternalDataContainers
                for ci = 0, collection_count(containers) - 1 do
                    pcall(function()
                        names[#names + 1] = tostring(
                            containers[ci].DataContainer:get_Path() or "?")
                    end)
                end
            end)
            json.dump_file("IrisUnicornEfxContainers.json", names)
            UNI.efx_status = "wrote " .. #names
                .. " container paths to data/IrisUnicornEfxContainers.json"
        end

        if imgui.button("Repaint live unicorns##uni_repaint") then
            local n = 0
            for _, rec in pairs(REGISTRY) do
                if rec.variant == "unicorn" and valid(rec.game_object) then
                    pcall(function() UNI.apply_material(rec.game_object) end)
                    n = n + 1
                end
            end
            S.status = "repainted " .. n .. " unicorn(s)"
        end
        imgui.same_line()
        -- Turns the NEAREST registered horse into a unicorn on the spot. The fastest
        -- way to see the material without waiting on a spawn roll.
        if imgui.button("Upgrade nearest horse to unicorn##uni_upgrade") then
            local done = false
            for address, rec in pairs(REGISTRY) do
                if not done and rec.kind == "horse"
                    and rec.variant ~= "unicorn" and valid(rec.game_object) then
                    rec.variant = "unicorn"
                    UNI.queue_promote(address, rec.game_object)   -- mesh AND material
                    done = true
                end
            end
            S.status = done and "upgrading a live horse to unicorn"
                or "no plain horse registered to upgrade"
        end

        if imgui.tree_node("Blessing##iris_uni_blessing") then
            changed, value = imgui.checkbox(
                "Blessing enabled (hold cast key near your unicorn)",
                C.blessing_enabled)
            if changed then C.blessing_enabled = value; save_config() end
            changed, value = imgui.drag_int(
                "Cast key (VK code -- 66=B, 71=G, 85=U)", C.blessing_key, 1, 8, 255)
            if changed then C.blessing_key = value; save_config() end
            changed, value = imgui.slider_float(
                "Cast range (m)", C.blessing_range, 2.0, 15.0, "%.1f")
            if changed then C.blessing_range = value; save_config() end
            changed, value = imgui.slider_float(
                "Circle heal radius (m)", C.blessing_radius, 1.0, 12.0, "%.1f")
            if changed then C.blessing_radius = value; save_config() end
            changed, value = imgui.slider_float(
                "Cooldown (s)", C.blessing_cooldown, 0.0, 600.0, "%.0f")
            if changed then C.blessing_cooldown = value; save_config() end
            changed, value = imgui.slider_float(
                "Unicorn base HP", C.unicorn_hp, 250.0, 5000.0, "%.0f")
            if changed then C.unicorn_hp = value; save_config() end
            changed, value = imgui.slider_float(
                "Kill bonus EXP", C.unicorn_kill_exp, 0.0, 50000.0, "%.0f")
            if changed then C.unicorn_kill_exp = value; save_config() end
            changed, value = imgui.input_text(
                "Shell catalog .user", C.blessing_shell_path)
            if changed then
                C.blessing_shell_path = value
                save_config()
                RP.shell_udata = nil   -- re-warm from the new path
                pcall(function()
                    local udata = sdk.create_userdata(
                        "app.ShellParamData", C.blessing_shell_path)
                    if udata then
                        udata:add_ref()
                        S.pins[#S.pins + 1] = udata
                        RP.shell_udata = udata
                    end
                end)
            end
            local shells = RP.shell_udata and RP.shell_param_count() or 0
            changed, value = imgui.slider_int(
                string.format("Circle shell index (0-%d)", math.max(0, shells - 1)),
                C.blessing_shell_idx, 0, math.max(0, shells - 1))
            if changed then C.blessing_shell_idx = value; save_config() end
            imgui.text("  (pick the mage HEALING RING visually with the test")
            imgui.text("   button -- shells are forced decorative both ways)")
            if imgui.button("Cast now (nearest unicorn)##uni_bless_cast") then
                RP.try_cast()
            end
            imgui.same_line()
            if imgui.button("Test circle at PLAYER##uni_bless_test") then
                pcall(function()
                    local pgo = RP.player_go()
                    local pos = pgo and RP.go_pos(pgo)
                    local rot = pgo
                        and pgo:call("get_Transform"):call("get_Rotation")
                    if pgo and pos and rot then
                        RP.spawn_circle(pgo, pos, rot)
                        RP.blessing_status = "test circle fired (shell idx "
                            .. tostring(C.blessing_shell_idx) .. ")"
                    else
                        RP.blessing_status = "test circle: no player"
                    end
                end)
            end
            imgui.text("Blessing: " .. tostring(RP.blessing_status))
            imgui.text("Shell userdata: "
                .. (RP.shell_udata and ("warmed, " .. shells .. " params")
                    or "NOT warmed"))
            imgui.tree_pop()
        end
        imgui.tree_pop()
    end

    if imgui.tree_node("Advanced##iris_wild_horses") then
        changed, value = imgui.slider_float(
            "walk/trot threshold (m/s)", C.walk_max_speed, 0.5, 6.0)
        if changed then C.walk_max_speed = value; save_config() end
        changed, value = imgui.slider_float(
            "trot/gallop threshold (m/s)", C.trot_max_speed, 2.0, 12.0)
        if changed then C.trot_max_speed = value; save_config() end
        changed, value = imgui.slider_int(
            "hoof spacing (ms)", C.contact_spacing_ms, 15, 120)
        if changed then C.contact_spacing_ms = value; save_config() end
        -- 08-07 (rodeo kick impact hunt): Aurora's skill-browser event
        -- ids -- plays each 1.5s apart with a log line; she notes which
        -- NUMBER actually sounds, that id becomes C.kick_hit_event in
        -- the rodeo config
        if imgui.button("SKILL IMPACT AUDITION (10 ids, 1.5s apart)") then
            S.fx_audition = {idx = 0, next_t = 0}
        end
        if S.fx_audition_status then
            imgui.text(tostring(S.fx_audition_status))
        end
        imgui.text("Category tests (first horse):")
        for _, category in ipairs({
            "walk", "trot", "gallop", "land", "snort",
            "nicker", "alert", "hurt", "death",
        }) do
            if imgui.button(category .. "##iris_horse_test") then
                play_category(category, first_horse())
            end
            imgui.same_line()
        end
        imgui.new_line()
        imgui.text("Jump pack tests (first horse):")
        if imgui.button("JUMP##iris_horse_jp") then JP.play(first_horse(), 1, "Gallop_Jump") end
        imgui.same_line()
        if imgui.button("JUMP+LAND##iris_horse_jp") then JP.play(first_horse(), 2, "Jump_toIdle") end
        imgui.same_line()
        if imgui.button("BUCK##iris_horse_jp") then JP.play(first_horse(), 3, "Buck") end
        imgui.same_line()
        if imgui.button("Reload jump motlist##iris_horse_jp") then
            JP.attempted = false; JP.holder = nil; JP.load()
        end
        imgui.text("Jump motlist: " .. tostring(JP.status))
        imgui.text("Ritual pack tests (first horse):")
        if imgui.button("GATHER##iris_horse_rp") then
            RP.play(first_horse(), 1, "RitualGather")
        end
        imgui.same_line()
        if imgui.button("THRUST##iris_horse_rp") then
            RP.play(first_horse(), 2, "RitualThrust")
        end
        imgui.same_line()
        if imgui.button("EAT##iris_horse_rp") then
            RP.play(first_horse(), 3, "Eat")
        end
        imgui.same_line()
        if imgui.button("Reload ritual motlist##iris_horse_rp") then
            RP.attempted = false; RP.holder = nil; RP.load()
        end
        imgui.text("Ritual motlist: " .. tostring(RP.status))
        imgui.new_line()
        imgui.text("Mesh: " .. tostring(R.resource_status))
        imgui.text("Motlist: " .. tostring(L.resource_status))
        local control_ready = false
        pcall(function()
            control_ready = CR.control_prefab
                and CR.control_prefab:call("get_Ready") == true
        end)
        imgui.text(string.format(
            "Climb rig: %s | ready %s | CONTROL(native doe pfb) ready %s | swapped: %d",
            tostring(CR.status), tostring(climb_prefab_ready()),
            tostring(control_ready), CR.swapped))
        -- PLAN F1 MESH TEST: the ox-skeleton horse mesh (re-bound tonight in
        -- Blender, round-trip verified) applied to a live ox — bind-pose
        -- correct by construction, so the horse should STAND like the ox
        -- stands, no rotation, no float.
        if imgui.button("TEST: OX-SKELETON horse mesh on nearest ox") then
            local best = nil
            pcall(function()
                local scene_manager = sdk.get_native_singleton("via.SceneManager")
                local scene_type = sdk.find_type_definition("via.SceneManager")
                local scene = sdk.call_native_func(
                    scene_manager, scene_type, "get_CurrentScene()")
                local list = scene and scene:call(
                    "findComponents(System.Type)", sdk.typeof("app.Character"))
                local elements = {}
                pcall(function() elements = list:get_elements() end)
                for _, character in ipairs(elements) do
                    local id = ""
                    pcall(function()
                        id = tostring(character:call("get_CharaIDString"))
                    end)
                    if id:match("^ch299003") then
                        pcall(function()
                            best = character:call("get_GameObject")
                        end)
                        break
                    end
                end
            end)
            if not (best and valid(best)) then
                S.status = "oxmesh: no ox (ch299003) within range"
            else
                if not R.horseox_holder then
                    pcall(function()
                        local resource = sdk.create_resource(
                            "via.render.MeshResource",
                            "character/ch/ch99_003/horseox.mesh")
                        if resource then
                            R.horseox_holder = resource:create_holder(
                                "via.render.MeshResourceHolder")
                            if R.horseox_holder then
                                R.horseox_holder:add_ref()
                            end
                        end
                    end)
                end
                -- the horseox mesh carries the OX material table (body_mat,
                -- horn_mat, ...) and pairs with the ox's native _a mdf.
                -- setMesh WITHOUT set_Material = invisible (bindings still
                -- describe the old mesh); set_Material on a live monster =
                -- EyeGlowController AV (cached material instances dangle).
                -- So: disable EyeGlowController FIRST, then swap both.
                if not R.oxmdf_holder then
                    pcall(function()
                        local resource = sdk.create_resource(
                            "via.render.MeshMaterialResource",
                            "character/ch/ch99_003/ch99_003_a.mdf2")
                        if resource then
                            R.oxmdf_holder = resource:create_holder(
                                "via.render.MeshMaterialResourceHolder")
                            if R.oxmdf_holder then
                                R.oxmdf_holder:add_ref()
                            end
                        end
                    end)
                end
                if not R.horseox_holder then
                    S.status = "oxmesh: horseox mesh resource not loaded"
                elseif not R.oxmdf_holder then
                    S.status = "oxmesh: ox mdf resource not loaded"
                else
                    local mesh = get_component(best, "via.render.Mesh")
                    if not mesh then
                        S.status = "oxmesh: ox has no mesh component"
                    else
                        -- stash originals once for the RESTORE button
                        if not R.ox_backup then
                            local old_mesh, old_mdf = nil, nil
                            pcall(function() old_mesh = mesh:call("getMesh") end)
                            pcall(function() old_mdf = mesh:call("get_Material") end)
                            R.ox_backup = { go = best, mesh = old_mesh, mdf = old_mdf }
                        end
                        local glow_off = false
                        pcall(function()
                            local glow = get_component(best, "app.EyeGlowController")
                            if glow then
                                glow:call("set_Enabled", false)
                                glow_off = true
                            end
                        end)
                        set_mesh_enabled(mesh, false)
                        local ok1 = pcall(function()
                            mesh:call("setMesh", R.horseox_holder)
                        end)
                        local ok2 = pcall(function()
                            mesh:call("set_Material", R.oxmdf_holder)
                        end)
                        if not ok2 then
                            ok2 = pcall(function()
                                mesh:call("setMaterial", R.oxmdf_holder)
                            end)
                        end
                        set_mesh_enabled(mesh, true)
                        S.status = string.format(
                            "oxmesh: applied mesh=%s mdf=%s eyeglow_off=%s "
                            .. "-> should STAND like an ox-shaped horse!",
                            tostring(ok1), tostring(ok2), tostring(glow_off))
                    end
                end
            end
        end
        local rm = S.ox_remap
        local rm_on = rm and rm.enabled or false
        local changed_rm, want_rm = imgui.checkbox(
            "OX REMAP: full horse behaviour on nearest ox##oxremap", rm_on)
        if changed_rm then
            if want_rm then
                local target = nil
                pcall(function()
                    local scene_manager = sdk.get_native_singleton("via.SceneManager")
                    local scene_type = sdk.find_type_definition("via.SceneManager")
                    local scene = sdk.call_native_func(
                        scene_manager, scene_type, "get_CurrentScene()")
                    local list = scene and scene:call(
                        "findComponents(System.Type)", sdk.typeof("app.Character"))
                    local elements = {}
                    pcall(function() elements = list:get_elements() end)
                    for _, character in ipairs(elements) do
                        local id = ""
                        pcall(function()
                            id = tostring(character:call("get_CharaIDString"))
                        end)
                        if id:match("^ch299003") then
                            pcall(function()
                                target = character:call("get_GameObject")
                            end)
                            break
                        end
                    end
                end)
                if target then
                    -- wake the brain: gait buttons think-stop the ox and
                    -- nothing else restores it
                    pcall(function()
                        local ch = get_component(target, "app.Character")
                        if ch then ch:call("set_IsThinkStop", false) end
                    end)
                    S.ox_remap = {enabled = true, go = target, key = "ox_remap",
                                  swaps = 0}
                    S.status = "oxremap: LIVE on nearest ox (AI in charge)"
                else
                    S.status = "oxremap: no ox found"
                end
            elseif rm then
                rm.enabled = false
                S.status = "oxremap: off after " .. tostring(rm.swaps or 0)
                    .. " swaps"
            end
        end
        if rm and rm.enabled then
            imgui.text(string.format("  remap live: %d swaps | %d loops | last: %s",
                rm.swaps or 0, rm.loops or 0, tostring(rm.last_swap or "-")))
        end
        local cap = S.ox_capture
        local cap_on = cap and cap.enabled or false
        local changed_cap, want_cap = imgui.checkbox(
            "OX: capture motion ids (walk near an ox, let it behave)##oxcap",
            cap_on)
        if changed_cap then
            if want_cap then
                local target = nil
                pcall(function()
                    local scene_manager = sdk.get_native_singleton("via.SceneManager")
                    local scene_type = sdk.find_type_definition("via.SceneManager")
                    local scene = sdk.call_native_func(
                        scene_manager, scene_type, "get_CurrentScene()")
                    local list = scene and scene:call(
                        "findComponents(System.Type)", sdk.typeof("app.Character"))
                    local elements = {}
                    pcall(function() elements = list:get_elements() end)
                    for _, character in ipairs(elements) do
                        local id = ""
                        pcall(function()
                            id = tostring(character:call("get_CharaIDString"))
                        end)
                        if id:match("^ch299003") then
                            pcall(function()
                                target = character:call("get_GameObject")
                            end)
                            break
                        end
                    end
                end)
                if target then
                    S.ox_capture = {enabled = true, go = target,
                                    last_key = nil, seq = {}}
                    S.status = "oxcap: capturing nearest ox motion ids"
                else
                    S.status = "oxcap: no ox found to observe"
                end
            elseif cap then
                cap.enabled = false
                pcall(function() json.dump_file("OxMotionCapture.json", cap.seq) end)
                S.status = "oxcap: stopped, " .. tostring(#cap.seq)
                    .. " transitions -> data/OxMotionCapture.json"
            end
        end
        if cap and cap.enabled then
            local last = cap.seq[#cap.seq]
            imgui.text(string.format(
                "  capturing: %d transitions | last bank=%s id=%s end=%s",
                #cap.seq, last and last.bank or "-", last and last.id or "-",
                last and last.end_frame or "-"))
        end
        if imgui.button("DEBUG: dump horse HP api##hpdump") then
            local target, tkind = nil, "none"
            for _, entry in pairs(REGISTRY) do
                if entry.kind == "horse" and valid(entry.game_object) then
                    target = entry.game_object; tkind = "registry horse"
                    break
                end
            end
            if not target then
                S.status = "hpdump: no live horse in registry"
            else
                local lines = {"hpdump on " .. tkind}
                local hc = get_component(target, "app.HitController")
                lines[#lines + 1] = "HitController: " .. tostring(hc ~= nil)
                if hc then
                    pcall(function()
                        local td = hc:get_type_definition()
                        lines[#lines + 1] = "type: " .. td:get_full_name()
                        for _, method in ipairs(td:get_methods()) do
                            local name = method:get_name()
                            if name:find("[Mm]ax") or name:find("^set")
                                or name:find("[Hh]p") then
                                lines[#lines + 1] = "  m: " .. name
                            end
                        end
                        for _, field in ipairs(td:get_fields()) do
                            local name = field:get_name()
                            if name:find("[Mm]ax") or name:find("[Hh]it")
                                or name:find("[Hh]p") then
                                lines[#lines + 1] = "  f: " .. name
                            end
                        end
                    end)
                    for _, getter in ipairs({"get_Hp", "get_MaxHitPoint",
                                             "get_MaxHp", "get_HpMax"}) do
                        pcall(function()
                            lines[#lines + 1] = getter .. " = "
                                .. tostring(hc:call(getter))
                        end)
                    end
                end
                pcall(function() json.dump_file("HorseHpDump.json", lines) end)
                log(table.concat(lines, " | "))
                S.status = "hpdump: data/HorseHpDump.json (" .. #lines .. " lines)"
            end
        end
        if imgui.button("RESTORE native mesh on the test ox") then
            if not (R.ox_backup and valid(R.ox_backup.go)) then
                S.status = "oxmesh: no backed-up ox to restore"
            else
                local mesh = get_component(R.ox_backup.go, "via.render.Mesh")
                if not mesh then
                    S.status = "oxmesh: backed-up ox has no mesh component"
                else
                    set_mesh_enabled(mesh, false)
                    local ok1 = false
                    if R.ox_backup.mesh then
                        ok1 = pcall(function()
                            mesh:call("setMesh", R.ox_backup.mesh)
                        end)
                    end
                    local ok2 = false
                    if R.ox_backup.mdf then
                        ok2 = pcall(function()
                            mesh:call("set_Material", R.ox_backup.mdf)
                        end)
                    end
                    set_mesh_enabled(mesh, true)
                    pcall(function()
                        local glow = get_component(
                            R.ox_backup.go, "app.EyeGlowController")
                        if glow then glow:call("set_Enabled", true) end
                    end)
                    S.status = string.format(
                        "oxmesh: restored mesh=%s mdf=%s",
                        tostring(ok1), tostring(ok2))
                    R.ox_backup = nil
                end
            end
        end
        -- PLAN F: play the RETARGETED ox-skeleton horse gaits (bank 901,
        -- horse_ox_locomotion.motlist) on the nearest ox. IDs 1/2/3 =
        -- walk/trot/gallop, matching the REE-CE take order.
        local ox_play_id = nil
        if imgui.button("OX GAIT: walk##oxgait1") then ox_play_id = 1 end
        imgui.same_line()
        if imgui.button("trot##oxgait2") then ox_play_id = 2 end
        imgui.same_line()
        if imgui.button("gallop##oxgait3") then ox_play_id = 3 end
        if ox_play_id then
            local best = nil
            pcall(function()
                local scene_manager = sdk.get_native_singleton("via.SceneManager")
                local scene_type = sdk.find_type_definition("via.SceneManager")
                local scene = sdk.call_native_func(
                    scene_manager, scene_type, "get_CurrentScene()")
                local list = scene and scene:call(
                    "findComponents(System.Type)", sdk.typeof("app.Character"))
                local elements = {}
                pcall(function() elements = list:get_elements() end)
                for _, character in ipairs(elements) do
                    local id = ""
                    pcall(function()
                        id = tostring(character:call("get_CharaIDString"))
                    end)
                    if id:match("^ch299003") then
                        pcall(function()
                            best = character:call("get_GameObject")
                        end)
                        break
                    end
                end
            end)
            if not (best and valid(best)) then
                S.status = "oxgait: no ox (ch299003) found nearby"
            elseif not load_ox_motlist() then
                S.status = "oxgait: ox motlist not loaded (pak installed?)"
            else
                S.ox_gait_state = S.ox_gait_state or {key = "ox_gait"}
                local temp_state = S.ox_gait_state
                local character, motion, layer = character_motion(best)
                temp_state.motion = motion
                if not (valid(motion) and valid(layer)) then
                    S.status = "oxgait: ox motion/layer not ready"
                elseif not register_bank_ox(temp_state, motion) then
                    S.status = "oxgait: bank 901 registration failed on the ox"
                else
                    pcall(function()
                        if character then
                            character:call("set_IsThinkStop", true)
                        end
                    end)
                    -- live leg-IK/ground solvers re-solve ankle chains against
                    -- OX segment lengths while our clips impose HORSE lengths
                    -- -> rubber legs. Disable every IK-flavoured component
                    -- while a custom gait drives the skeleton.
                    local ik_off = {}
                    pcall(function()
                        local comps = best:call("get_Components")
                        local n = comps and comps:call("get_Count") or 0
                        for i = 0, n - 1 do
                            local comp = comps:call("get_Item", i)
                            local tname = ""
                            pcall(function()
                                tname = comp:get_type_definition():get_full_name()
                            end)
                            if tname:find("[Ii]k") or tname:find("GroundFixer")
                                or tname:find("SlopeBody") then
                                local off = pcall(function()
                                    comp:call("set_Enabled", false)
                                end)
                                if off then
                                    ik_off[#ik_off + 1] = tname
                                end
                            end
                        end
                    end)
                    local ok = pcall(function()
                        layer:call(
                            "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                            CUSTOM_BANK, ox_play_id, 0.0, 0.3, 1, 1)
                        layer:call("set_Speed", 1.0)
                    end)
                    log("oxgait IK disabled: " .. table.concat(ik_off, ", "))
                    S.status = "oxgait: id " .. ox_play_id .. " -> "
                        .. tostring(ok) .. " | IK off: " .. tostring(#ik_off)
                        .. " (names in log)"
                end
            end
        end
        -- PLAN F probe: the OX (ch299003) is a natively climbable quadruped
        -- in the doe's family. If the horse mesh sits acceptably on the ox
        -- skeleton, the horse becomes an ox-chassis creature and mounting
        -- is native. This button answers the one open question: proportions.
        if imgui.button("TEST: horse mesh on nearest OX (plan F)") then
            local player_pos = nil
            pcall(function()
                local manager = sdk.get_managed_singleton("app.CharacterManager")
                local character = manager and manager:call("get_ManualPlayer")
                local inner = character and character:call("get_Character")
                character = inner or character
                local go = character and character:call("get_GameObject")
                local tf = go and go:call("get_Transform")
                player_pos = tf and tf:call("get_UniversalPosition")
            end)
            local best, best_d = nil, 50
            pcall(function()
                local scene_manager = sdk.get_native_singleton("via.SceneManager")
                local scene_type = sdk.find_type_definition("via.SceneManager")
                local scene = sdk.call_native_func(
                    scene_manager, scene_type, "get_CurrentScene()")
                local list = scene and scene:call(
                    "findComponents(System.Type)", sdk.typeof("app.Character"))
                local elements = {}
                pcall(function() elements = list:get_elements() end)
                for _, character in ipairs(elements) do
                    local id = ""
                    pcall(function()
                        id = tostring(character:call("get_CharaIDString"))
                    end)
                    if id:match("^ch299003") then
                        local go = nil
                        pcall(function() go = character:call("get_GameObject") end)
                        if valid(go) and player_pos then
                            local tf, pos = nil, nil
                            pcall(function()
                                tf = go:call("get_Transform")
                                pos = tf and tf:call("get_UniversalPosition")
                            end)
                            if pos then
                                local dx = pos.x - player_pos.x
                                local dz = pos.z - player_pos.z
                                local d = math.sqrt(dx * dx + dz * dz)
                                if d < best_d then best, best_d = go, d end
                            end
                        end
                    end
                end
            end)
            if not best then
                S.status = "plan F: no ox (ch299003) within 50m"
            elseif not load_render_resources() then
                S.status = "plan F: horse mesh resources not loaded"
            else
                local mesh = get_component(best, "via.render.Mesh")
                if not mesh then
                    S.status = "plan F: ox has no mesh component"
                else
                    set_mesh_enabled(mesh, false)
                    local ok1 = pcall(function()
                        mesh:call("setMesh", R.mesh_holder)
                    end)
                    local ok2 = pcall(function()
                        mesh:call("set_Material", R.mdf_holder)
                    end)
                    if not ok2 then
                        ok2 = pcall(function()
                            mesh:call("setMaterial", R.mdf_holder)
                        end)
                    end
                    set_mesh_enabled(mesh, true)
                    S.status = string.format(
                        "plan F: horse mesh on ox -> mesh=%s mdf=%s "
                        .. "(judge the proportions + try climbing it!)",
                        tostring(ok1), tostring(ok2))
                end
            end
        end
        imgui.tree_pop()
    end
end)

load_config()
-- 08-07 one-shot migration (Aurora: "the horse idling is only using doe
-- sounds"): older saved configs carry suppress_doe_audio=false from the
-- era when our vocals never played (unregistered-list drop). Now that the
-- full custom voice works, flip it ON once; her manual choice after this
-- sticks because the migration flag persists in the config.
if not C.suppress_vocal_migrated then
    C.suppress_vocal_migrated = true
    C.suppress_doe_audio = true
    save_config()
end
-- 08-07 one-shot #2 (Aurora: buttons all work, "no idle sounds at all"
-- + the panel screenshot showed Ambient vocals UNTICKED): ambient was
-- default-false since birth. Turn the idle voice on once; her manual
-- choice afterwards sticks.
if not C.ambient_vocal_migrated then
    C.ambient_vocal_migrated = true
    C.ambient_enabled = true
    save_config()
end
-- 08-07 one-shot #3: stored configs carry the old 60-120s band; pull it
-- to 20-45s now that the doe is muted and our vocals are the only idle
-- voice. Slider changes after this stick.
if not C.ambient_band_migrated then
    C.ambient_band_migrated = true
    C.ambient_min_s, C.ambient_max_s = 20, 45
    save_config()
end
log("loaded; arming deferred until the world is live")
