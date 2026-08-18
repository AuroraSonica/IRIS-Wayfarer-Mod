-- IrisWildCats.lua
--
-- I.R.I.S. — Wild Cats: consolidated Puma/Panther module. Supersedes
-- PumaPantherPackRandomiser.lua (retired to autorun_disabled) and adds the
-- full custom cat vocal set. One panel, everything automatic:
--
--   * one roll per nearby wolf spawn burst: a configurable share becomes
--     Puma (native Redwolf A chassis, custom mesh pak) or Panther (native
--     Redwolf B chassis, per-instance darkened materials + eye emissive)
--   * cats keep native wolf movement and FOOTSTEPS; only VOCALS change:
--     wolf voice triggers on cats are replaced with growls/snarls/roars
--     (the game picks the moments, we pick the species), hurt/death come
--     from real HP changes, idle growls/purrs play ambiently
--   * no native mesh or sound is replaced; ordinary wolves are untouched
--
-- Spawn-side state deliberately ADOPTS the randomiser's shared key
-- (__lyra_puma_panther_pack_randomiser_v2): its native GenerateManager hooks
-- survive script resets and dispatch through state.process_spawn_request, so
-- this module replaces the policy without stacking hooks.

local MOD = "IrisWildCats"
local CONFIG_FILE = MOD .. ".json"
local MANIFEST_FILE = "PumaAudioManifest.json"
local READY_DELAY_FRAMES = 180

local SPAWN_STATE_KEY = "__lyra_puma_panther_pack_randomiser_v2"
local REGISTRY_KEY = "__lyra_animal_audio_variants"
local REGISTRY = rawget(_G, REGISTRY_KEY) or {}
rawset(_G, REGISTRY_KEY, REGISTRY)

local MONSTER_CATEGORY = 3
local WOLF_NAME = "ch223000_00"
local PUMA_NAME = "ch223001_00"
local PANTHER_NAME = "ch223001_01"
local PUMA_PREFAB = "AppSystem/ch/ch223/prefab/ch223001_00.pfb"
local PANTHER_PREFAB = "AppSystem/ch/ch223/prefab/ch223001_01.pfb"

-- ⭐⭐⭐ THE PANTHER'S OWN MATERIAL, THE WAY THIS CODEBASE ACTUALLY DOES IT.
-- Aurora: "why have we abandoned the separate panther mesh? there's no reason why it
-- shouldn't work - we have horses and unicorns working." She was right, and the reason my
-- version failed is that I invented a mechanism nobody here uses: byte-patching
-- ch223001_01.pfb to point at ch23_002. That prefab never reached get_Ready across four
-- builds. The UNICORN never patches a prefab -- IrisWildHorses ships the asset in a pak and
-- swaps it onto the LIVE BODY at runtime (create_resource -> add_ref -> warm -> holder ->
-- setMesh/set_Material). That route is field-proven on this install.
--
-- ⭐ AND WE ONLY NEED HALF OF IT: puma and panther share identical GEOMETRY, so there is
-- nothing to setMesh. Swapping only the MATERIAL gives the panther its own charcoal coat
-- (relative contrast 0.61 vs the 0.21 a BaseColor multiply can reach), its own eye atlas
-- with the painted gold iris, and Emissive_Color1/2 baked yellow in the mdf2 itself.
local PANTHER_MDF_PATH = "character/ch/ch23_002/ch23_002.mdf2"
-- ⛔ COLD create_resource IS ASYNC (unicorn law, log-proven): a holder built and used
-- immediately wraps a HOLLOW resource -- the first swap "succeeds" rendering nothing, and
-- that holder then throws forever while valid() still reports true. Pin at arm, gate, and
-- only then build the holder.
-- ⭐ 5 s, not the unicorn's 15. That gate guarded a 1 MB MESH swap where a hollow
-- resource AVs; ours is a 64 KB mdf2, it is warmed at arm step 5 (boot) so in practice
-- the gate is long paid before any cat spawns, and a too-early holder is now SAFE anyway:
-- set_Material throwing drops the holder and the next retry rebuilds it from the cached
-- resource. Aurora's packs roll wolves, then pumas, and only then panthers -- by which
-- point a 15 s gate is pure dead time.
local PANTHER_MDF_GATE = 5.0
local PACK_FRAME_WINDOW = 360
local PACK_RADIUS = 70.0
local PACK_RADIUS_SQ = PACK_RADIUS * PACK_RADIUS
-- Ceiling on how many spawns one roll can claim. A native wolf pack is a few animals arriving
-- in the same burst; without a cap, repeated manual spawns all inherit one decision.
local PACK_MAX_MEMBERS = 6

-- ⭐ RUNTIME RECOLOUR IS THE PANTHER'S ROUTE AGAIN (2026-08-15). The ch23_002 experiment
-- -- giving the panther its own mesh/mdf2/textures via a redirected ch223001_01.pfb --
-- never once reached get_Ready, through four builds, and cost several field round-trips.
-- Reverted. BaseColor is a MULTIPLY, so it preserves RELATIVE contrast (std/mean) even
-- though absolute std drops; the coat lands at ~0.21 relative against the 0.61 a purpose
-- built charcoal texture achieved. Visibly less rich, but the new derived NRMR carries
-- most of the surface read, which is why this route never looked rubbery in the field.
--
-- ⭐⭐ AND THE EYES WORK NOW. These writes always went to ch23_001_eye_mat, but until the
-- eye caps became a REAL submesh that material had nothing but a 1 mm dummy triangle
-- parked at the Hip, so the yellow was painting an invisible speck. With real eye
-- geometry the emissive finally lands.
local PANTHER_MATERIALS = {
    -- retuned to hit the same charcoal the texture build was aiming for (mean ~0.078 on
    -- an albedo whose own mean is ~0.60), with the faint cool cast kept.
    ch23_001_body_mat = {0.130, 0.140, 0.160, 1.0},
    ch23_001_head_mat = {0.120, 0.130, 0.150, 1.0},
    ch23_001_fur1_mat = {0.165, 0.175, 0.195, 1.0},
    ch23_001_fur2_mat = {0.145, 0.155, 0.180, 1.0},
    -- ⛔ WAS {1800, 55, 0}: a 1800x multiply was harmless while eye_mat drew nothing, but
    -- against real eyeballs it blows the iris to a flat white-orange disc. Her painted
    -- gold iris only needs a warm tint over it.
    ch23_001_eye_mat = {1.00, 0.85, 0.25, 1.0},
}
-- ⛔ the old {5.0, 2.2, 0.04} normalises to G/R = 0.44, which reads ORANGE. Aurora asked
-- for yellow; G/R near 0.8 gets there. Emissive_Intensity on this material is already 8.2.
local PANTHER_EYE_EMISSIVE = {2.20, 1.70, 0.08, 1.0}

local REQUEST_SIGNATURE = table.concat({
    "createRequestInfo(soundlib.SoundTriggerInfo, via.GameObject, via.GameObject, ",
    "System.UInt32, System.Boolean, System.Boolean, System.UInt32, ",
    "via.simplewwise.CallbackType, ",
    "System.Action`1<soundlib.SoundManager.RequestInfo>, ",
    "System.Action`1<soundlib.SoundManager.RequestInfo>, ",
    "System.Action`1<soundlib.SoundManager.RequestInfo>, ",
    "System.Action`1<soundlib.SoundManager.RequestInfo>)",
})

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------

local C = {
    enabled = true,
    cat_pack_chance = 0.33,
    panther_share = 0.50,
    audio_enabled = true,
    replace_wolf_vocals = true,
    ambient_enabled = true,
    -- Trace-proven start-loop vocal.  3982150705 belongs to the 4612 END clip;
    -- the old learner accepted every clip in the sequence and therefore saved
    -- the final breath/close event over the actual 4610 howl request.
    wolf_howl_trigger_id = 3274161328,
    -- Filled only from a genuinely running wild-wolf HowlingStart action. Trigger
    -- 3274161328 was disproved in the field (it belongs to motion 0:300), so a
    -- saved native event ID—not that historical guess—drives mounted playback.
    wolf_howl_event_id = 0,
    -- ⛔ OFF SINCE THE ch23_002 SPLIT. The panther used to be the puma mesh recoloured at
    -- runtime: BaseColor = {0.115, 0.125, 0.145} on every material. That is a flat 12%
    -- MULTIPLY, and a multiply cannot add contrast -- it took the coat's albedo std from
    -- 0.128 down to 0.015, which is exactly the "rubbery" look Aurora reported. It also
    -- made yellow eyes impossible: the eyes rode body_mat, so their brightest achievable
    -- value was 0.115. The panther now owns ch23_002.mesh + ch23_002.mdf2 with a purpose
    -- built charcoal coat (std 0.049 on a 0.079 mean) and Emissive_Color1/2 patched gold
    -- in the material itself. Leaving this on would double-darken a coat that is already
    -- dark. It is inert anyway -- the table is keyed on ch23_001_* names and the panther's
    -- materials are ch23_002_* now -- but inert-and-retrying every 60 frames is not free.
    -- ⭐ BACK ON. Turned off when the panther briefly had its own ch23_002 material set;
    -- that experiment is reverted (it never loaded), so this is once again the ONLY thing
    -- that makes a panther black. See the PANTHER_MATERIALS note above.
    recolour_panther_material = true,
    -- ⭐ Prefer the panther's OWN ch23_002 material (real charcoal textures + gold iris +
    -- baked yellow emissive) over the runtime BaseColor tint. Falls back to the tint
    -- automatically if the pak is missing or the resource never streams, so turning the
    -- pak off degrades to the old look rather than to a tawny panther.
    panther_own_material = true,
    -- Restore the original audible baseline. The accepted flat bank has no
    -- attenuation graph; RequestInfo positioning only adds a hard cull. A
    -- separate volume-tier build can supply distance falloff after this route
    -- is confirmed stable.
    spatial_audio = false,
    spatial_src_gameobj = false,   -- legacy config key; deliberately ignored
    -- ⭐ Scales the event's attenuation DISTANCE. 1.0 = as authored. Higher = audible
    -- further out (a gentler falloff), lower = drops off sooner. If the cloned events
    -- carry no attenuation ShareSet at all this will do nothing, and the real fix is to
    -- re-author the bank -- which is exactly what the field test tells us.
    attenuation_scale = 1.0,
}

local function load_config()
    local data = nil
    pcall(function() data = json.load_file(CONFIG_FILE) end)
    if type(data) ~= "table" then
        -- Missing/empty config: write a valid one so the JSON loader stops
        -- logging parse errors on every reset.
        pcall(function() json.dump_file(CONFIG_FILE, C) end)
        return
    end
    for key, default in pairs(C) do
        if type(default) == "boolean" then
            if data[key] ~= nil then C[key] = data[key] == true end
        elseif data[key] ~= nil then
            C[key] = tonumber(data[key]) or default
        end
    end
    C.cat_pack_chance = math.max(0.0, math.min(1.0, C.cat_pack_chance))
    C.panther_share = math.max(0.0, math.min(1.0, C.panther_share))
end

local function save_config()
    pcall(function() json.dump_file(CONFIG_FILE, C) end)
end

-- ---------------------------------------------------------------------------
-- Shared spawn state (adopted from the randomiser) + module state
-- ---------------------------------------------------------------------------

local S = rawget(_G, SPAWN_STATE_KEY) or {}
rawset(_G, SPAWN_STATE_KEY, S)
S.generation = (S.generation or 0) + 1
local GENERATION = S.generation
if S.enabled == nil then S.enabled = true end
S.active = true
S.frame = S.frame or 0
S.status = "Initialising IRIS Wild Cats."
S.wolf_requests = S.wolf_requests or 0
S.conversions = S.conversions or 0
S.packs_rolled = S.packs_rolled or 0
S.vanilla_packs = S.vanilla_packs or 0
S.puma_packs = S.puma_packs or 0
S.panther_packs = S.panther_packs or 0
S.puma_wolves = S.puma_wolves or 0
S.panther_wolves = S.panther_wolves or 0
S.not_ready_packs = S.not_ready_packs or 0
S.panther_targets = S.panther_targets or 0
S.panther_material_writes = S.panther_material_writes or 0
S.force_next = nil
S.recent_packs = {}
S.panther_seen = S.panther_seen or {}
S.pending_panther_groups = S.pending_panther_groups or {}
S.known_character_addresses = S.known_character_addresses or {}
S.category_restore_stack = {}
S.instance_restore_stack = {}
S.cats = {}
S.next_sample = 0.0
-- staggered-arm bookkeeping restarts every load (a reset mid-session must
-- re-run the whole sequence, since per-load hooks need reinstalling)
S.arm_ready_frame = nil
S.arm_step = nil
S.sweep_source = nil
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
    vocal_ids = nil,
    suppressed = 0,
    replaced = 0,
    pending_vocals = {},
    pending_direct = {},
    pending_wolf_calls = {},
    wolf_howl_trigger_id = nil,
    wolf_howl_heard_at = nil,
    -- Decoded from DD2's ch223000_vo_m bank and inspected as spectra: these
    -- are the two long, sustained harmonic calls (the first is the clearest
    -- The two long IDs decoded from ch223's VO bank are WEM media IDs, not Wwise
    -- event IDs. Posting them as events succeeds at the API boundary but is silent.
    wolf_howl_event_ids = {},
}
S.audio_status = "audio idle"

for _, pending_group in ipairs(S.pending_panther_groups) do
    if (pending_group.assigned or 0) < (pending_group.expected or 0) then
        pending_group.first_frame = S.frame or 0
    end
end

local function report(message)
    S.status = tostring(message)
    pcall(function() log.info("[" .. MOD .. "] " .. S.status) end)
end

local function valid(object)
    if not object then return false end
    local ok, value = pcall(function() return object:call("get_Valid") end)
    -- A destroyed streamed character throws InvalidOperationException here.
    -- Treating that throw as "valid" kept its dead components in REGISTRY and
    -- hammered get_GameObject every frame after the cat had gone.
    return ok and value ~= false
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
-- Spawn conversion (ported from PumaPantherPackRandomiser v2, unchanged
-- mechanics; pack chance / panther share now come from the config)
-- ---------------------------------------------------------------------------

local mesh_type = sdk.typeof("via.render.Mesh")
local hash_method = nil
pcall(function()
    hash_method = sdk.find_type_definition("via.murmur_hash"):get_method("calc32(System.String)")
end)
local hashes = {}

local function find_character_id(field_name)
    local value = nil
    local ok, err = pcall(function()
        local td = sdk.find_type_definition("app.CharacterID")
        if not td then error("app.CharacterID type was not found") end
        for _, field in ipairs(td:get_fields() or {}) do
            if field:is_static() and tostring(field:get_name() or "") == field_name then
                value = field:get_data()
                break
            end
        end
    end)
    if not ok then return nil, tostring(err) end
    if value == nil then return nil, "static field " .. field_name .. " was not found" end
    return value, nil
end

S.wolf_id, S.wolf_id_error = find_character_id(WOLF_NAME)
S.puma_id, S.puma_id_error = find_character_id(PUMA_NAME)
S.panther_id, S.panther_id_error = find_character_id(PANTHER_NAME)

local function read_character_id(container)
    local value = nil
    pcall(function()
        value = container._CommonInfo._ObjectID._SelectedCharacterID
    end)
    return value
end

local function write_character_id(container, value)
    local ok, err = pcall(function()
        if not container then error("GenerateInfo container was nil") end
        container._CommonInfo._ObjectID._SelectedCharacterID = value
        if container._CommonInfo._ObjectID._SelectedCharacterID ~= value then
            error("CharacterID read-back did not match the selected cat chassis")
        end
    end)
    return ok, ok and nil or tostring(err)
end

local function read_spawn_position(container)
    local result = nil
    pcall(function()
        local common = container and container:get_field("_CommonInfo")
        local pos = common and common:get_field("_InitialPosition")
        if not pos then pos = common and common:get_field("_ContextPosition") end
        if pos then
            local x, y, z = tonumber(pos.x), tonumber(pos.y), tonumber(pos.z)
            if x and y and z then result = {x = x, y = y, z = z} end
        end
    end)
    return result
end

local function stage_chassis(label, path)
    local result = {label = label, path = path, prefab = nil, controller = nil}
    local ok, err = pcall(function()
        local prefab = sdk.create_instance("via.Prefab")
        if not prefab then error("via.Prefab instance was nil") end
        prefab:add_ref()
        prefab:set_Path(path)
        -- get_Ready alone is not proof that a newly-created Prefab has a
        -- populated instantiate graph. Standby forces the native chassis to
        -- finish loading and pins it before a world-spawn request can use the
        -- controller. The 16:06 crash was an execInstantiate AV from a
        -- ready-but-hollow mid-world Prefab.
        prefab:call("set_Standby", true)
        local controller = sdk.create_instance("app.PrefabController")
        if not controller then error("app.PrefabController instance was nil") end
        controller:add_ref()
        controller._Item = prefab
        result.prefab = prefab
        result.controller = controller
    end)
    if not ok then result.error = tostring(err) end
    return result
end

-- Hooks, audio and scene sweeps remain deferred until the player exists.
-- Native chassis staging is the deliberate exception: DD2 must populate and
-- pin these Prefabs during preload, before any hooked spawn can consume them.
local WORLD_ARMED = false

local function world_ready()
    local ready = false
    pcall(function()
        local manager = sdk.get_managed_singleton("app.CharacterManager")
        ready = manager ~= nil and manager:call("get_ManualPlayer") ~= nil
    end)
    return ready == true
end

local function stage_native_chassis()
    if not (S.puma_resource and S.puma_resource.prefab) then
        S.puma_resource = stage_chassis("Puma", PUMA_PREFAB)
    end
    if not (S.panther_resource and S.panther_resource.prefab) then
        S.panther_resource = stage_chassis("Panther", PANTHER_PREFAB)
    end
    if (S.puma_resource and S.puma_resource.error)
        or (S.panther_resource and S.panther_resource.error) then
        report("Resource staging failed: "
            .. tostring(S.puma_resource and S.puma_resource.error)
            .. " | " .. tostring(S.panther_resource and S.panther_resource.error))
    end
end

-- ⛔ STAGE AT SCRIPT LOAD (July-proven semantics, restored 2026-08-05 evening).
-- Staging these prefabs MID-WORLD (the deferred-arming experiment) produced
-- ready-but-hollow prefabs: get_Ready reported true, the conversion swapped in
-- our controller, and the engine AV'd 34 ms later instantiating from a husk —
-- on tape at 16:06:16. Prefabs must be staged during preload, where they were
-- staged all July. Hooks and frame work stay deferred; ONLY staging is early.
stage_native_chassis()

local function resource_ready(resource)
    if not resource or not resource.prefab or not resource.controller then return false end
    local ready = false
    pcall(function() ready = resource.prefab:call("get_Ready") == true end)
    return ready
end

local function position_distance_sq(a, b)
    if not a or not b then return nil end
    local dx = a.x - b.x
    local dy = a.y - b.y
    local dz = a.z - b.z
    return dx * dx + dy * dy + dz * dz
end

local function copy_address_set(source)
    local result = {}
    for address, present in pairs(source or {}) do
        if present then result[address] = true end
    end
    return result
end

local function choose_new_pack_kind()
    if S.force_next then
        local forced = S.force_next
        S.force_next = nil
        return forced, "forced"
    end
    local roll = math.random()
    if roll >= C.cat_pack_chance then return "vanilla", roll end
    if math.random() < C.panther_share then return "panther", roll end
    return "puma", roll
end

local function find_or_create_pack(position, source)
    local frame = S.frame or 0
    for index = #S.recent_packs, 1, -1 do
        local pack = S.recent_packs[index]
        local age = frame - (pack.last_frame or frame)
        if age > PACK_FRAME_WINDOW then
            table.remove(S.recent_packs, index)
        else
            local distance_sq = position_distance_sq(position, pack.position)
            local same_burst = distance_sq and distance_sq <= PACK_RADIUS_SQ
            if (not position or not pack.position) and age <= 12 then same_burst = true end
            -- ⛔ The window must be measured from when the pack STARTED, not from its last
            -- join. Refreshing last_frame on every join made the window slide forever: spawn
            -- wolves one at a time from one spot and they ALL inherit the first roll, so a
            -- single cat roll turned every later wolf into a cat (Aurora, 2026-07-25).
            local burst_age = frame - (pack.first_frame or frame)
            if burst_age > PACK_FRAME_WINDOW then same_burst = false end
            -- A real pack is a handful of animals, not an unbounded queue.
            if (pack.members or 0) >= PACK_MAX_MEMBERS then same_burst = false end
            if same_burst then
                pack.last_frame = frame
                pack.members = (pack.members or 0) + 1
                return pack, false
            end
        end
    end

    local kind, roll = choose_new_pack_kind()
    if kind == "puma" and not resource_ready(S.puma_resource) then
        kind = "vanilla"
        S.not_ready_packs = (S.not_ready_packs or 0) + 1
    elseif kind == "panther" and not resource_ready(S.panther_resource) then
        kind = "vanilla"
        S.not_ready_packs = (S.not_ready_packs or 0) + 1
    end

    local pack = {
        kind = kind,
        roll = roll,
        position = position,
        source = source,
        first_frame = frame,
        last_frame = frame,
        members = 1,
    }
    if kind == "panther" then
        local group = {
            baseline = copy_address_set(S.known_character_addresses),
            position = position,
            first_frame = frame,
            expected = 0,
            assigned = 0,
        }
        pack.panther_group = group
        S.pending_panther_groups[#S.pending_panther_groups + 1] = group
    end
    S.recent_packs[#S.recent_packs + 1] = pack
    S.packs_rolled = (S.packs_rolled or 0) + 1
    if kind == "puma" then
        S.puma_packs = (S.puma_packs or 0) + 1
    elseif kind == "panther" then
        S.panther_packs = (S.panther_packs or 0) + 1
    else
        S.vanilla_packs = (S.vanilla_packs or 0) + 1
    end
    return pack, true
end

local function queue_container_restore(stack_name, container)
    local stack = S[stack_name]
    if type(stack) ~= "table" then
        stack = {}
        S[stack_name] = stack
    end
    stack[#stack + 1] = container
end

local function restore_spawn_container(stack_name, retval)
    local state = rawget(_G, SPAWN_STATE_KEY)
    if not state then return retval end
    local stack = state[stack_name]
    local container = type(stack) == "table" and table.remove(stack) or nil
    if container and state.wolf_id then
        local restored, restore_err = write_character_id(container, state.wolf_id)
        if not restored then
            report("Failed to restore EnemySpawner's Wolf request: " .. tostring(restore_err))
        end
    end
    return retval
end

-- Forensic switch (2026-08-05 crash hunt): true = log every wolf request but
-- never convert. The killer turned out to be raw-served horse.mdf2, not the
-- spawn pipeline — conversions are exonerated and live again.
local OBSERVE_ONLY = false

local function process_spawn_request(args, controller_index, container_index, source, restore_stack_name)
    local state = rawget(_G, SPAWN_STATE_KEY)
    if not state or not state.active or not state.enabled or not C.enabled then
        return
    end

    local container = sdk.to_managed_object(args[container_index])
    local character_id = read_character_id(container)
    if character_id == nil or character_id ~= state.wolf_id then return end

    -- ⭐ CLAIMED SPAWN (2026-08-11): a stable summon must come out exactly its recorded
    -- species. The griffin bridge claims the next wolf request BEFORE summoning; a claimed
    -- request never touches pack logic at all (a summon landing near a recent wild pack
    -- would otherwise JOIN it and inherit its cat roll -- force_next only guards NEW
    -- packs). Claims expire so a summon that never materialises can't eat a wild spawn
    -- minutes later.
    local claim = state.claim_next
    if claim then
        state.claim_next = nil
        if os.clock() <= (tonumber(claim.until_t) or 0.0) then
            state.claimed_spawns = (state.claimed_spawns or 0) + 1
            report(string.format("SPAWN TAPE: wolf request via %s -> CLAIMED (%s), no pack roll",
                source, tostring(claim.kind)))
            return  -- vanilla body, untouched, and no pack membership consumed
        end
        -- stale claim: discard it and fall through to the normal wild roll
    end

    state.wolf_requests = (state.wolf_requests or 0) + 1
    state.last_source = source
    local pack, is_new = find_or_create_pack(read_spawn_position(container), source)
    state.last_pack = string.format(
        "%s (%d member%s)", pack.kind, pack.members, pack.members == 1 and "" or "s")
    report(string.format("SPAWN TAPE: wolf request via %s -> pack %s, member %d%s",
        source, pack.kind, pack.members, OBSERVE_ONLY and " [observe-only]" or ""))

    if pack.kind == "vanilla" then
        if is_new then report("Rolled a vanilla wolf pack.") end
        return
    end

    if OBSERVE_ONLY then
        state.observed_conversions = (state.observed_conversions or 0) + 1
        report(string.format(
            "SPAWN TAPE: would convert member %d to %s -- SKIPPED (observe-only)",
            pack.members, pack.kind))
        return
    end

    local target_id = pack.kind == "panther" and state.panther_id or state.puma_id
    local resource = pack.kind == "panther" and state.panther_resource or state.puma_resource
    if not target_id or not resource_ready(resource) then
        pack.kind = "vanilla"
        report("Cat resource became unavailable; this pack remains vanilla.")
        return
    end

    local wrote, write_err = write_character_id(container, target_id)
    if not wrote then
        pack.kind = "vanilla"
        report("Cat chassis mutation failed; this pack remains vanilla: " .. tostring(write_err))
        return
    end

    args[controller_index] = sdk.to_ptr(resource.controller)
    queue_container_restore(restore_stack_name, container)
    state.conversions = (state.conversions or 0) + 1
    if pack.kind == "panther" then
        state.panther_wolves = (state.panther_wolves or 0) + 1
        if pack.panther_group then
            pack.panther_group.expected = (pack.panther_group.expected or 0) + 1
            pack.panther_group.last_frame = state.frame or 0
        end
    else
        state.puma_wolves = (state.puma_wolves or 0) + 1
    end
    report(string.format("Converted wolf %d in this burst to %s.", pack.members, pack.kind))
end

-- The native hooks (which survive script resets) dispatch through this slot.
S.process_spawn_request = process_spawn_request

-- ⭐ BRIDGE API (2026-08-11): GriffinRideProbe has called
-- _G.__iris_wild_cats_api.claim_next("vanilla") before every ch223 stable summon since
-- 08-08 -- but this side was never built, so the call silently no-op'd (rawget returned
-- nil inside a pcall) and summoned companions kept rolling the wild cat chance. The claim
-- lives on the SHARED state so the reset-surviving native hooks see it.
rawset(_G, "__iris_wild_cats_api", {
    claim_next = function(kind)
        S.claim_next = { kind = tostring(kind or "vanilla"), until_t = os.clock() + 8.0 }
    end,
    clear_claim = function() S.claim_next = nil end,
})

local function on_category_spawn_request(args)
    local ok_category, category = pcall(sdk.to_int64, args[3])
    if not ok_category or category ~= MONSTER_CATEGORY then return end
    local state = rawget(_G, SPAWN_STATE_KEY)
    local handler = state and state.process_spawn_request
    if handler then
        handler(args, 4, 5, "natural world", "category_restore_stack")
    end
end

local function on_instance_spawn_request(args)
    local state = rawget(_G, SPAWN_STATE_KEY)
    local handler = state and state.process_spawn_request
    if handler then
        handler(args, 3, 4, "InstanceInfo / EnemySpawner", "instance_restore_stack")
    end
end

local function install_hooks_once()
    if S.hook_attempted then return end
    S.hook_attempted = true
    local manager = sdk.find_type_definition("app.GenerateManager")

    local category_ok, category_err = pcall(function()
        local method = manager and manager:get_method(
            "requestCreateInstance(app.GeneratorCategory, app.PrefabController, "
            .. "app.GenerateInfo.GenerateInfoContainer, System.Int32, "
            .. "System.Action`2<app.PrefabInstantiateResults,app.DummyArg>, "
            .. "System.Action`2<app.PrefabInstantiateResults,app.DummyArg>)"
        )
        if not method then error("natural-world overload not found") end
        sdk.hook(method, on_category_spawn_request, function(retval)
            return restore_spawn_container("category_restore_stack", retval)
        end)
        S.category_hook_installed = true
    end)

    local instance_ok, instance_err = pcall(function()
        local method = manager and manager:get_method(
            "requestCreateInstance(app.PrefabController, "
            .. "app.GenerateInfo.GenerateInfoContainer, System.Int32, app.InstanceInfo, "
            .. "System.Action`2<app.PrefabInstantiateResults,app.DummyArg>, "
            .. "System.Action`2<app.PrefabInstantiateResults,app.DummyArg>)"
        )
        if not method then error("InstanceInfo overload not found") end
        sdk.hook(method, on_instance_spawn_request, function(retval)
            return restore_spawn_container("instance_restore_stack", retval)
        end)
        S.instance_hook_installed = true
    end)

    S.hook_installed = S.category_hook_installed or S.instance_hook_installed
    if not S.hook_installed then
        S.hook_attempted = false
        report("Spawn hooks failed: " .. tostring(category_err) .. " | " .. tostring(instance_err))
    elseif not category_ok or not instance_ok then
        report("Only one spawn path is available; see REFramework log.")
    end
end

-- ---------------------------------------------------------------------------
-- Panther materials (ported unchanged)
-- ---------------------------------------------------------------------------

local function hash(name)
    if not hash_method then return nil end
    if hashes[name] == nil then hashes[name] = hash_method:call(nil, name) end
    return hashes[name]
end

local function set_float4(mesh, material_index, variable_name, values)
    local name_hash = hash(variable_name)
    if not name_hash then return false end
    local variable_index = -1
    local variable_count = 0
    pcall(function()
        variable_index = tonumber(mesh:call("getMaterialVariableIndex", material_index, name_hash)) or -1
        variable_count = tonumber(mesh:call("getMaterialVariableNum", material_index)) or 0
    end)
    if variable_index < 0 or variable_index >= variable_count then return false end
    return pcall(function()
        mesh:call(
            "setMaterialFloat4",
            material_index,
            variable_index,
            Vector4f.new(values[1], values[2], values[3], values[4] or 1.0)
        )
    end)
end

-- Pin -> warm -> holder, mirroring IrisWildHorses.load_unicorn_resources.
local function load_panther_mdf()
    if S.pmdf_holder then return true end
    if S.pmdf_failed then return false, S.pmdf_status end
    if not S.pmdf_res then
        pcall(function()
            local res = sdk.create_resource("via.render.MeshMaterialResource",
                PANTHER_MDF_PATH)
            if res then
                res:add_ref()
                S.pmdf_res = res
                S.pmdf_warm_at = os.clock()
            end
        end)
        if not S.pmdf_res then
            S.pmdf_failed = true
            S.pmdf_status = "panther mdf2 resource NIL -- is the ch23_002 pak installed?"
            report(S.pmdf_status)
            return false, S.pmdf_status
        end
        S.pmdf_status = "panther mdf2 pinned; streaming"
        report(S.pmdf_status)
    end
    local age = os.clock() - (S.pmdf_warm_at or 0)
    if age < PANTHER_MDF_GATE then
        S.pmdf_status = string.format("panther mdf2 streaming (%.0fs / %.0fs)",
            age, PANTHER_MDF_GATE)
        -- ⛔ "warming" IS NOT "failed" (Aurora: the first panther came out a recoloured
        -- puma, a later one was correct). The caller MUST be able to tell them apart --
        -- falling back to the BaseColor tint while the real material is still streaming
        -- paints a body that is about to get the good material anyway.
        return false, "warming"
    end
    local holder = nil
    pcall(function()
        holder = S.pmdf_res:create_holder("via.render.MeshMaterialResourceHolder")
        if holder then holder:add_ref() end
    end)
    if not holder then
        S.pmdf_failed = true
        S.pmdf_status = "panther mdf2 holder build FAILED after warm gate"
        report(S.pmdf_status)
        return false, S.pmdf_status
    end
    S.pmdf_holder = holder
    S.pmdf_status = "panther mdf2 loaded (ch23_002)"
    report(S.pmdf_status)
    return true
end


-- ⛔⛔ set_Material ON A LIVE MONSTER DANGLES app.EyeGlowController'S CACHED ACCESSORS and
-- its next onUpdate is a c0000005. The controller is NOT a via component -- get_component
-- sweeps can never find it -- it is a FIELD on the body's app.Monster. Neutralise it
-- FIRST and leave it latched off (re-enabling re-caches against the layout that broke it).
local function neutralise_eyeglow(game_object)
    local done = "no app.Monster"
    pcall(function()
        local monster = game_object:call("getComponent(System.Type)",
            sdk.typeof("app.Monster"))
        if not monster then return end
        local ctrl = monster:get_field("EyeGlowController")
        if not ctrl then done = "Monster found, EyeGlowController field nil" return end
        pcall(function() ctrl:call("resetController") end)
        pcall(function() ctrl:call("set_IsInitialized", false) end)
        pcall(function() ctrl:call("set_InitializeFailed", true) end)
        done = "EyeGlowController latched off"
    end)
    return done
end


-- Swap the panther onto its OWN material. Returns true once a body is wearing ch23_002.
local function apply_panther_mdf(character)
    if not C.panther_own_material then return false, "disabled" end
    local ok, why = load_panther_mdf()
    if not ok then return false, why end
    local swapped = false
    pcall(function()
        local game_object = character:get_GameObject()
        local mesh = game_object and game_object:call("getComponent(System.Type)", mesh_type)
        if not mesh then return end
        neutralise_eyeglow(game_object)
        local done = pcall(function() mesh:call("set_Material", S.pmdf_holder) end)
        if done then
            swapped = true
            S.panther_mdf_swaps = (S.panther_mdf_swaps or 0) + 1
            -- ⛔⛔ set_Material DOES NOT UNDO setMaterialFloat4 -- per-instance params live
            -- on the material INSTANCE and survive re-assigning the resource (the single
            -- most expensive law from the unicorn build). If this body was tinted by the
            -- fallback before the real material arrived, that tint is STILL on it and
            -- would double-darken an already-charcoal coat. Any revert must be explicit.
            local count = tonumber(mesh:call("get_MaterialNum")) or 0
            for mi = 0, count - 1 do
                local mn = tostring(mesh:call("getMaterialName", mi) or "")
                if PANTHER_MATERIALS[mn] then
                    set_float4(mesh, mi, "BaseColor", {1.0, 1.0, 1.0, 1.0})
                end
            end
        else
            -- a throw here means the holder is hollow: drop it so the next retry builds a
            -- fresh one from the now-cached resource. Retrying a hollow holder never works.
            S.pmdf_holder, S.pmdf_failed = nil, false
            S.pmdf_status = "panther set_Material threw; holder dropped for rebuild"
        end
    end)
    return swapped
end


local function apply_panther_material(character)
    local writes = 0
    -- ⭐ THE MATERIAL SWAP WINS WHEN IT IS AVAILABLE. Its textures are already charcoal
    -- with a gold iris, so tinting BaseColor on top would only double-darken it.
    local swapped, why = apply_panther_mdf(character)
    if swapped then return 0, "mdf2" end
    -- ⛔ AND WAIT RATHER THAN TINT WHILE IT STREAMS. Tinting during the warm gate is what
    -- produced Aurora's "first panther was a recoloured puma, a later one was correct":
    -- the fallback fired, painted the body, and the retry window then closed before the
    -- real material was ready. Returning here leaves the body vanilla for a few seconds
    -- and lets the retry land the genuine article.
    if why == "warming" then return 0, "warming" end
    if not C.recolour_panther_material then return 0, "off" end
    pcall(function()
        local game_object = character:get_GameObject()
        local mesh = game_object and game_object:call("getComponent(System.Type)", mesh_type)
        if not mesh then return end
        local count = tonumber(mesh:call("get_MaterialNum")) or 0
        for material_index = 0, count - 1 do
            local material_name = tostring(mesh:call("getMaterialName", material_index) or "")
            local base = PANTHER_MATERIALS[material_name]
            if base and set_float4(mesh, material_index, "BaseColor", base) then
                writes = writes + 1
            end
            if material_name == "ch23_001_eye_mat" then
                if set_float4(mesh, material_index, "Emissive_Color1", PANTHER_EYE_EMISSIVE) then
                    writes = writes + 1
                end
                if set_float4(mesh, material_index, "Emissive_Color2", PANTHER_EYE_EMISSIVE) then
                    writes = writes + 1
                end
            end
        end
    end)
    return writes
end

local function list_elements(collection)
    if not collection then return {} end
    local ok, elements = pcall(function() return collection:get_elements() end)
    if ok and type(elements) == "table" then return elements end
    local result = {}
    local enum_ok, enumerator = pcall(function()
        return collection:call("GetEnumerator")
    end)
    if not enum_ok or not enumerator then return result end
    while true do
        local move_ok, more = pcall(function()
            return enumerator:call("MoveNext")
        end)
        if not move_ok or not more then break end
        local current = nil
        pcall(function() current = enumerator:call("get_Current") end)
        if current then result[#result + 1] = current end
    end
    return result
end

local wolf_current_action_name

local function collect_wolf_family(max_source)
    max_source = max_source or 3
    local found, seen = {}, {}
    local function consider(character)
        if not character then return end
        local id = nil
        pcall(function() id = character:get_CharaIDString() end)
        if id ~= WOLF_NAME and id ~= PUMA_NAME and id ~= PANTHER_NAME then return end
        local address = nil
        pcall(function() address = tostring(character:get_address()) end)
        if not address then return end
        if seen[address] then return end
        seen[address] = true
        local game_object, position = nil, nil
        pcall(function()
            game_object = character:get_GameObject()
            local transform = game_object and game_object:call("get_Transform")
            position = transform and transform:call("get_UniversalPosition")
        end)
        found[#found + 1] = {
            character = character,
            game_object = game_object,
            address = address,
            id = id,
            position = position,
        }
    end

    if max_source >= 1 then
        local manager = sdk.get_managed_singleton("app.CharacterManager")
        if manager then
            for _, method_name in ipairs({"get_CharacterList", "getCharacterList", "get_NpcCharacterList"}) do
                local collection = nil
                pcall(function() collection = manager:call(method_name) end)
                for _, character in ipairs(list_elements(collection)) do consider(character) end
            end
        end
    end

    if max_source >= 2 then
        local situation = sdk.get_managed_singleton("app.AISituationManager")
        if situation then
            for index = 0, 300 do
                local agent, character = nil, nil
                pcall(function() agent = situation:call("getAgent", index) end)
                pcall(function() character = agent and agent:call("get_Chara") end)
                consider(character)
            end
        end
    end

    if max_source >= 3 then
        pcall(function()
            local scene_manager = sdk.get_native_singleton("via.SceneManager")
            local scene_manager_type = sdk.find_type_definition("via.SceneManager")
            local scene = sdk.call_native_func(scene_manager, scene_manager_type, "get_CurrentScene()")
            local components = scene and scene:call("findComponents(System.Type)", sdk.typeof("app.Character"))
            for _, character in ipairs(list_elements(components)) do consider(character) end
        end)
    end
    return found
end

local function refresh_cats(source_limit)
    local frame = S.frame or 0
    local targets = collect_wolf_family(source_limit or S.sweep_source or 3)
    local present, current_addresses, id_counts = {}, {}, {}
    for _, item in ipairs(targets) do
        present[item.address] = item
        current_addresses[item.address] = true
        id_counts[item.id] = (id_counts[item.id] or 0) + 1
        if item.id == PANTHER_NAME and not S.panther_seen[item.address] then
            S.panther_seen[item.address] = {
                first_frame = frame,
                last_apply = -1000,
                applies = 0,
            }
        end
    end

    for index = #S.pending_panther_groups, 1, -1 do
        local group = S.pending_panther_groups[index]
        local age = frame - (group.first_frame or frame)
        if age > 900 or (group.assigned or 0) >= (group.expected or 0) then
            table.remove(S.pending_panther_groups, index)
        else
            local candidates = {}
            for _, item in ipairs(targets) do
                if not group.baseline[item.address] and not S.panther_seen[item.address] then
                    local distance_sq = position_distance_sq(group.position, item.position)
                    if age <= 180
                        or (distance_sq and distance_sq <= PACK_RADIUS_SQ * 2.25)
                    then
                        candidates[#candidates + 1] = {
                            item = item,
                            distance_sq = distance_sq or math.huge,
                        }
                    end
                end
            end
            table.sort(candidates, function(a, b)
                return a.distance_sq < b.distance_sq
            end)
            local remaining = (group.expected or 0) - (group.assigned or 0)
            for candidate_index = 1, math.min(remaining, #candidates) do
                local item = candidates[candidate_index].item
                S.panther_seen[item.address] = {
                    first_frame = frame,
                    last_apply = -1000,
                    applies = 0,
                }
                group.assigned = (group.assigned or 0) + 1
            end
        end
    end

    local visible_panthers = 0
    for address, record in pairs(S.panther_seen) do
        local item = present[address]
        if item then
            visible_panthers = visible_panthers + 1
            record.last_seen = frame
            -- ⛔⛔ 480 FRAMES IS 8 SECONDS AND THE MATERIAL WARM GATE IS 15. The retry
            -- window used to close BEFORE ch23_002.mdf2 could possibly be ready, so the
            -- first panther of a session was permanently stuck on whatever the fallback
            -- had painted. 1800 frames (30 s) clears the gate with room to spare.
            if not record.done
                and frame - record.first_frame <= 1800
                and frame - record.last_apply >= 60 then
                local writes, mode = apply_panther_material(item.character)
                -- ⭐ REMEMBER WHICH ROUTE EACH BODY ACTUALLY GOT (Aurora: "I can't tell if
                -- the panther is the actual mesh or a coloured puma"). She should never
                -- have to judge that by eye -- the two look deliberately similar. Once a
                -- body is on ch23_002 it is done: stop re-applying so a later retry cannot
                -- paint a tint over a material that is already correct.
                record.mode = mode or record.mode
                if mode == "mdf2" then
                    record.last_apply = frame
                    record.done = true
                elseif writes > 0 then
                    record.last_apply = frame
                    record.applies = record.applies + 1
                    S.panther_material_writes = (S.panther_material_writes or 0) + writes
                end
            end
        elseif frame - (record.last_seen or frame) > 600 then
            S.panther_seen[address] = nil
        end
    end
    S.panther_targets = visible_panthers
    -- tally which route the LIVE panthers are actually wearing, for the panel
    local n_mdf, n_tint, n_warm = 0, 0, 0
    for _, record in pairs(S.panther_seen) do
        if record.mode == "mdf2" then n_mdf = n_mdf + 1
        elseif record.mode == "warming" then n_warm = n_warm + 1
        elseif record.mode then n_tint = n_tint + 1 end
    end
    S.panther_modes = string.format("%d on ch23_002 | %d on tint | %d warming",
        n_mdf, n_tint, n_warm)

    -- ⭐ DUMP THE VOCAL-HOOK COUNTERS TO DISK. Aurora should not have to transcribe a
    -- debug line off a screenshot for me -- she plays, the file records, I read it. Every
    -- ~5 s, cheap, and it survives the session so a howl heard once is still evidence.
    if (S.frame % 300) == 0 then
        pcall(function()
            local dg = A.dbg or {}
            json.dump_file("IrisWildCats_audio.json", {
                seen = dg.seen or 0,
                no_vocal_id = dg.no_vocal_id or 0,
                last_miss_id = dg.last_miss_id or 0,
                no_cat = dg.no_cat or 0,
                last_owner = tostring(dg.last_owner or "-"),
                replaced = dg.replaced or 0,
                suppressed = A.suppressed or 0,
                catalogue_ids = A.vocal_ids and (function()
                    local c = 0
                    for _ in pairs(A.vocal_ids) do c = c + 1 end
                    return c
                end)() or -1,
                audio_status = tostring(S.audio_status or "-"),
                trigger_method_ok = S.trigger_method_ok == true,
                trigger_hook_ok = S.trigger_hook_ok == true,
                wolf_howl_post = A.wolf_howl_last_post,
                wolf_trigger_trace = A.wolf_trigger_trace or {},
                cats_visible = (S.puma_targets or 0) + visible_panthers,
                replace_enabled = C.replace_wolf_vocals == true,
            })
        end)
    end
    S.known_character_addresses = current_addresses

    -- Registry contract: every visible Redwolf A IS a puma (the chassis mesh
    -- is the puma model), every claimed/self-identified Redwolf B a panther.
    for _, item in ipairs(targets) do
        local kind = nil
        if item.id == PUMA_NAME then
            kind = "puma"
        elseif item.id == PANTHER_NAME or S.panther_seen[item.address] then
            kind = "panther"
        end
        if kind and valid(item.game_object) then
            local go_address = object_address(item.game_object)
            if go_address then
                local record = REGISTRY[go_address]
                if not record or record.kind ~= kind then
                    REGISTRY[go_address] = {
                        kind = kind,
                        game_object = item.game_object,
                        marked_at = os.clock(),
                    }
                end
            end
        end
    end
    for address, record in pairs(REGISTRY) do
        if (record.kind == "puma" or record.kind == "panther")
            and not valid(record.game_object) then
            REGISTRY[address] = nil
        end
    end

    local labels = {}
    for id, count in pairs(id_counts) do
        labels[#labels + 1] = id .. " x" .. tostring(count)
    end
    table.sort(labels)
    S.detected_wolf_ids = #labels > 0 and table.concat(labels, ", ") or "none"
end

-- ---------------------------------------------------------------------------
-- Audio: bank loading + template posting (proven route from IrisWildHorses)
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

local function force_nearest_wild_wolf_howl()
    local player_pos = nil
    pcall(function()
        local manager = sdk.get_managed_singleton("app.CharacterManager")
        local player = manager and manager:call("get_ManualPlayer") or nil
        local go = player and player:call("get_GameObject") or nil
        player_pos = go and go:call("get_Transform")
            :call("get_UniversalPosition") or nil
    end)
    local best, best_d2 = nil, math.huge
    for _, item in ipairs(collect_wolf_family(2)) do
        if item.id == WOLF_NAME and valid(item.character) and item.position then
            local action = wolf_current_action_name(item.character)
            -- Shadow's mounted/passive graph reports Invalid. Only a real AI wolf
            -- can teach us the audible action event.
            if action and not action:find("Invalid", 1, true) then
                local dx = (player_pos and player_pos.x or item.position.x)
                    - item.position.x
                local dz = (player_pos and player_pos.z or item.position.z)
                    - item.position.z
                local d2 = dx * dx + dz * dz
                if d2 < best_d2 then best, best_d2 = item, d2 end
            end
        end
    end
    if not best then return false, "no valid-graph wild wolf nearby" end
    local requested = false
    -- Arm the exact body before the synchronous action request.  Some builds
    -- expose only a generic CurrentActionList string while the Wwise event is
    -- posted; the selected valid-graph body is a stronger discriminator than
    -- trying to infer a howl from an unrelated running/attack vocal.
    A.howl_capture_target_addr = object_address(best.game_object)
    A.howl_capture_until = os.clock() + 2.5
    pcall(function()
        local character = best.character
        character:call("set_IsThinkStop", false)
        local manager = character["<ActionManager>k__BackingField"]
            or character:call("get_ActionManager")
        manager:call(
            "requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)",
            0, "Ch223HowlingStartLoop", 0)
        requested = true
    end)
    if not requested then
        A.howl_capture_target_addr, A.howl_capture_until = nil, nil
    end
    return requested, requested and "wild-wolf howl requested; listening for native event"
        or "wild-wolf howl request failed"
end

local function audio_player_game_object()
    local game_object = nil
    pcall(function()
        local manager = sdk.get_managed_singleton("app.CharacterManager")
        local character = manager and manager:call("get_ManualPlayer") or nil
        local inner = character and character:call("get_Character") or nil
        character = inner or character
        game_object = character and character:call("get_GameObject") or nil
    end)
    return valid(game_object) and game_object or nil
end

local function audio_position(game_object)
    local position = nil
    pcall(function()
        local transform = game_object and game_object:call("get_Transform")
        position = transform and transform:call("get_UniversalPosition") or nil
    end)
    return position
end

local function distance_tier_event(entry, target)
    local ids = entry and entry.tier_event_ids
    local distance_data = A.manifest and A.manifest.distance_volume
    local profiles = distance_data and distance_data.profiles_metres
    local limits = profiles and profiles[entry.distance_profile or "vocal"]
    if type(ids) ~= "table" or type(limits) ~= "table" then
        return entry and entry.event_id or nil, nil, 1
    end
    local source = audio_position(target)
    local listener = audio_position(audio_player_game_object())
    if not source or not listener then
        return ids[1] or entry.event_id, nil, 1
    end
    local dx = source.x - listener.x
    local dy = source.y - listener.y
    local dz = source.z - listener.z
    local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
    local scale = math.max(0.25, tonumber(C.attenuation_scale) or 1.0)
    for index, limit in ipairs(limits) do
        if distance <= (tonumber(limit) or 0) * scale then
            return tonumber(ids[index]) or entry.event_id, distance, index
        end
    end
    return nil, distance, #limits + 1
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
        S.audio_status = "cat bank-list USER unresolved (is patch_037 mounted?): "
            .. tostring(manifest.bank_list_path)
        report(S.audio_status)
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
        else
            report("cat trigger-list USER unresolved: " .. tostring(path))
        end
    end
    if not registration_trigger_instance then
        S.audio_status = "cat registration trigger-list USER unresolved"
        return false
    end

    -- CRASH MITIGATION: register once per game process (see IrisWildHorses;
    -- repeated re-registration = suspected Wwise bank-state rot).
    if rawget(_G, "__iris_audio_loaded_cats") ~= address then
        local load_ok, load_err = pcall(function()
            dispatcher:call(
                "loadContainableUserData(soundlib.SoundContainableUserData)",
                bank_instance)
            -- All four catalogues reference the same imported bank. Loading
            -- every list makes Wwise process that bank four times; the Horse
            -- path already documented this exact AK::WriteBytesCount crash.
            -- Register the root once and retain the others only as catalogues.
            dispatcher:call(
                "loadContainableUserData(soundlib.SoundContainableUserData)",
                registration_trigger_instance)
        end)
        if not load_ok then
            S.audio_status = "loadContainableUserData failed: "
                .. tostring(load_err)
            return false
        end
        rawset(_G, "__iris_audio_loaded_cats", address)
    end

    A.triggers_by_event = {}
    A.categories = {}
    A.registered_events = {}
    for _, entry in ipairs(manifest.events) do
        local bucket = A.categories[entry.category]
        if not bucket then
            bucket = {}
            A.categories[entry.category] = bucket
        end
        bucket[#bucket + 1] = {
            name = entry.name,
            event_id = entry.event_id,
            tier_event_ids = entry.tier_event_ids,
            distance_profile = entry.distance_profile,
        }
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
        "cat audio graph loaded (%d trigger files); settling",
        #trigger_instances)
    report(S.audio_status)
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
                    if not A.template_trigger and A.registered_events
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

-- Wolf vocal trigger ids: enumerated at runtime from the cat's own inherited
-- catalogue, restricted to USER lists whose path contains "_vo" — vocals
-- only, so native footsteps and effects stay untouched.
-- ⛔⛔ HARVEST FROM EVERY CAT AND **MERGE** -- DO NOT FREEZE ON THE FIRST ONE.
-- (Aurora: "pumas are using the wolf sounds, panthers are using cat sounds".) The
-- catalogue used to cache whichever cat vocalised first and never look again, so if the
-- two variants do not share every vocal trigger id, only the first type ever matched. The
-- counters named it: after the gate reorder `no_vocal_id` counts ONLY cats whose id is
-- absent from the catalogue, and it sat at 42 while panthers worked perfectly.
-- Merging is also self-healing -- any future variant harvests itself on its first miss.
local function harvest_vocal_ids(cat)
    local wwise = get_component(cat, "app.WwiseContainerApp")
    if not wwise then return A.vocal_ids end
    local found = A.vocal_ids or {}
    local total = 0
    pcall(function()
        local user_data = wwise._UserDataList
        for bank_index = 0, collection_count(user_data) - 1 do
            local bank = user_data[bank_index]
            local lists = nil
            pcall(function() lists = bank._UserDataList end)
            for list_index = 0, collection_count(lists) - 1 do
                local list = lists[list_index]
                local path = ""
                pcall(function() path = tostring(list:call("get_Path")) end)
                if string.find(string.lower(path), "_vo", 1, true) then
                    local triggers = nil
                    pcall(function() triggers = list._TriggerInfoList end)
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
        end
    end)
    if total == 0 then return A.vocal_ids end
    A.vocal_ids = found
    local grand = 0
    for _ in pairs(found) do grand = grand + 1 end
    A.vocal_id_count = grand
    report(string.format("cat vocal catalogue: +%d new ids (%d total)", total, grand))
    return found
end


local function ensure_vocal_ids(cat)
    if A.vocal_ids then return A.vocal_ids end
    return harvest_vocal_ids(cat)
end

local function native_template_for(target)
    if valid(A.native_template) then return A.native_template end
    local wwise = get_component(target, "app.WwiseContainerApp")
    if not wwise then return nil end
    local vocal_ids = ensure_vocal_ids(target)
    if not vocal_ids then return nil end
    local found = nil
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
                    local trigger = triggers[index]
                    local id = nil
                    pcall(function() id = normal_u32(trigger._TriggerId) end)
                    if id and vocal_ids[id] then
                        found = trigger
                        return
                    end
                end
            end
        end
    end)
    if found then A.native_template = found end
    return found
end

-- Resolve one particular native vocal instead of taking the first entry in
-- the VO list. The latter is how the ridden "howl" accidentally became a
-- pain cry: catalogue membership tells us only that an event is vocal, not
-- what the event means.
local function native_trigger_for_id(target, wanted)
    wanted = normal_u32(wanted)
    if not wanted then return nil end
    local wwise = get_component(target, "app.WwiseContainerApp")
    if not wwise then return nil end
    local found = nil
    pcall(function()
        local user_data = wwise._UserDataList
        for bank_index = 0, collection_count(user_data) - 1 do
            local lists = nil
            pcall(function() lists = user_data[bank_index]._UserDataList end)
            for list_index = 0, collection_count(lists) - 1 do
                local triggers = nil
                pcall(function() triggers = lists[list_index]._TriggerInfoList end)
                for index = 0, collection_count(triggers) - 1 do
                    local trigger = triggers[index]
                    local id = nil
                    pcall(function() id = normal_u32(trigger._TriggerId) end)
                    if id == wanted then found = trigger; return end
                end
                if found then return end
            end
            if found then return end
        end
    end)
    return found
end

local function native_trigger_for_event(target, wanted)
    wanted = normal_u32(wanted)
    if not wanted then return nil end
    local wwise = get_component(target, "app.WwiseContainerApp")
    if not wwise then return nil end
    local found = nil
    pcall(function()
        local user_data = wwise._UserDataList
        for bank_index = 0, collection_count(user_data) - 1 do
            local lists = nil
            pcall(function() lists = user_data[bank_index]._UserDataList end)
            for list_index = 0, collection_count(lists) - 1 do
                local triggers = nil
                pcall(function() triggers = lists[list_index]._TriggerInfoList end)
                for index = 0, collection_count(triggers) - 1 do
                    local trigger = triggers[index]
                    local event_id = nil
                    pcall(function() event_id = normal_u32(trigger._EventId) end)
                    if event_id == wanted then found = trigger; return end
                end
                if found then return end
            end
            if found then return end
        end
    end)
    return found
end

-- The cat triggers are cloned from DOE voice data, so their authored
-- _OffsetJointHash names a doe skeleton joint that does not exist on the
-- wolf chassis — createRequestInfo returns nil for it. Create with the
-- authored joint first, then fall back to joint 0 (object root).
local function create_request(dispatcher, trigger, target, joint_hash)
    local request = nil
    local ok, err = pcall(function()
        -- The custom trigger only resolves in the converted creature's full
        -- GameObject context. Attempts to substitute the player in either
        -- slot return nil, so retain the original field-proven call shape.
        request = dispatcher:call(
            REQUEST_SIGNATURE,
            trigger, target, target, joint_hash,
            false, false, 0, 0, nil, nil, nil, nil)
    end)
    -- Distinguish "the call threw" from "the call returned nil".
    if not ok then
        A.last_create_error = "threw: " .. tostring(err)
    elseif not request then
        A.last_create_error = "returned nil (joint " .. tostring(joint_hash) .. ")"
    else
        A.last_create_error = nil
    end
    return request
end

wolf_current_action_name = function(character)
    local name = nil
    pcall(function()
        local manager = character and (character["<ActionManager>k__BackingField"]
            or character:call("get_ActionManager")) or nil
        local list = manager and (manager.CurrentActionList
            or manager:get_field("CurrentActionList")) or nil
        local entry = list and (list[0] or list:call("get_Item", 0)) or nil
        if entry then name = tostring(entry:call("ToString()") or "") end
    end)
    if name == "" or name == "nil" then return nil end
    return name
end

local function position_request_at(request, target)
    if not (request and C.spatial_audio) then return end
    local position = nil
    pcall(function()
        local tf = target and target:call("get_Transform")
        position = tf and tf:call("get_UniversalPosition") or nil
    end)
    if not position then
        pcall(function()
            local tf = target and target:call("get_Transform")
            position = tf and tf:call("get_Position") or nil
        end)
    end
    if position then pcall(function() request:call("set_Position", position) end) end
    pcall(function() request:call("set_Positioned", true) end)
    pcall(function()
        request:call("set_AttenuationScalingFactor",
            tonumber(C.attenuation_scale) or 1.0)
    end)
    -- Deliberately no set_SrcGameObj(target): position is data; the live cat
    -- must never become an object owned by the player's custom-bank dispatcher.
end

local function post_throttled()
    local now = os.clock()
    local last = tonumber(rawget(_G, "__iris_audio_last_post")) or 0
    if now - last < 0.03 then return true end
    rawset(_G, "__iris_audio_last_post", now)
    return false
end

local function post_request(dispatcher, trigger, target, throttle_claimed)
    if not throttle_claimed and post_throttled() then
        return false, "post throttled"
    end
    local joint_hash = 0
    pcall(function() joint_hash = tonumber(trigger._OffsetJointHash) or 0 end)
    local request = create_request(dispatcher, trigger, target, joint_hash)
    if not request and joint_hash ~= 0 then
        request = create_request(dispatcher, trigger, target, 0)
    end
    if not request then
        return false, "direct createRequestInfo failed: "
            .. tostring(A.last_create_error or "no detail")
    end
    -- ⭐⭐ MAKE THE VOICE ACTUALLY 3D. (Aurora: "it doesn't get quieter, it just stops at
    -- a certain distance".) That is a positioned voice with no attenuation curve -- full
    -- volume out to the cull radius, then nothing. The engine hands us the levers on the
    -- request itself (dumped from soundlib.SoundManager.RequestInfo):
    --   Positioned               -- 3D at all, vs a 2D voice pinned to the listener
    --   SrcGameObj               -- WHICH object the voice emits from
    --   AttenuationScalingFactor -- scales the event's attenuation distance
    -- ⛔ Set these BEFORE trigger(); after it the voice is already playing and a late
    -- write does nothing. Every one is wrapped individually -- a missing setter on some
    -- future patch must not take the whole post down with it.
    position_request_at(request, target)
    local ok = pcall(function()
        request = request:add_ref()
        request["<Container>k__BackingField"] = dispatcher
        dispatcher:call("trigger(soundlib.SoundManager.RequestInfo)", request)
    end)
    return ok
end

local function post_via_template(dispatcher, event_id, target, throttle_claimed)
    if not throttle_claimed and post_throttled() then
        return false, "post throttled"
    end
    -- A failed direct custom trigger is not a useful template for itself.
    -- Use a request shape authored for this wolf chassis, then substitute
    -- only the imported cat event ID (the proven Wild Horses route).
    local template = native_template_for(target)
    if not valid(template) then template = A.template_trigger end
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
        request = create_request(dispatcher, template, target, joint_hash)
        if not request and joint_hash ~= 0 then
            request = create_request(dispatcher, template, target, 0)
        end
    end)
    local restore_ok = pcall(function() template._EventId = original end)
    local restored = nil
    pcall(function() restored = tonumber(template._EventId) end)
    if not restore_ok or restored ~= original then
        retire_template()
        return false, "template restore failed; retired"
    end
    if not create_ok then return false, tostring(create_err) end
    if not request then
        return false, "createRequestInfo failed: "
            .. tostring(A.last_create_error or "no detail")
    end
    request = request:add_ref()
    local copied = nil
    pcall(function() copied = tonumber(request._EventId) end)
    if copied ~= event_id then
        return false, "request did not copy the target event ID"
    end
    local post_ok, post_err = pcall(function()
        request["<Container>k__BackingField"] = dispatcher
        position_request_at(request, target)
        dispatcher:call("trigger(soundlib.SoundManager.RequestInfo)", request)
    end)
    if not post_ok then return false, tostring(post_err) end
    return true
end

local function post_event(event_id, target)
    if not (C.audio_enabled and audio_ready()) then
        return false, "cat audio not loaded/settled"
    end
    if not valid(target) then return false, "target invalid" end
    local dispatcher = A.registration.dispatcher
    if not valid(dispatcher) then
        A.registration = nil
        return false, "dispatcher went stale; reloading"
    end

    -- Claim the Wwise throttle once per logical sound. Previously the direct
    -- attempt consumed it, so the native-template fallback was *always*
    -- rejected as "post throttled" in the same frame.
    if post_throttled() then return false, "post throttled" end
    local trigger = A.triggers_by_event[event_id]
    local direct_err = nil
    -- The custom cat bank belongs to the registration dispatcher. A native cat
    -- container accepts the request wrapper but drops the unknown custom event later.
    -- Position the request at the cat; do not change the bank-owning dispatcher.
    if trigger and A.registered_events and A.registered_events[event_id] then
        local ok
        ok, direct_err = post_request(dispatcher, trigger, target, true)
        if ok then A.last_emitter = "custom/spatial" return true end
    end
    local template_ok, template_err = post_via_template(
        dispatcher, event_id, target, true)
    if template_ok then A.last_emitter = "custom/spatial/template" return true end
    direct_err = (direct_err and (tostring(direct_err) .. " | ") or "")
        .. "custom template: " .. tostring(template_err)
    return false, tostring(direct_err)
end

local function play_category(category, target)
    if (tonumber(A.post_fail_n) or 0) >= 3
        and os.clock() < (tonumber(A.post_cool) or 0.0) then
        return false, "cat audio circuit open (cooling down)"
    end
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
    local event_id, distance, tier = distance_tier_event(entry, target)
    A.last_audio_distance = distance
    A.last_audio_tier = tier
    if not event_id then
        A.last_played = entry.name .. " (out of range)"
        A.post_fail_n = 0
        return true, "beyond distance-volume range"
    end
    local ok, err = post_event(event_id, target)
    if ok then
        A.last_played = entry.name
        A.post_fail_n = 0
    else
        A.post_fail_n = (tonumber(A.post_fail_n) or 0) + 1
        if A.post_fail_n >= 3 then
            A.post_cool = os.clock() + 300.0
            if A.post_fail_n == 3 then
                report("cat audio circuit OPEN: 3 consecutive post failures; cooling for 5 minutes")
            end
        end
    end
    return ok, err
end

-- ---------------------------------------------------------------------------
-- Vocal replacement router (vocals only — footsteps stay native wolf)
-- ---------------------------------------------------------------------------

local function registered_cat_ancestor(game_object)
    local current = game_object
    for _ = 1, 8 do
        if not valid(current) then return nil end
        local mounted_cat = rawget(_G, "__iris_rodeo_is_mounted_cat")
        if mounted_cat then
            local yes = false
            pcall(function() yes = mounted_cat(current) == true end)
            if yes then return current end
        end
        local address = object_address(current)
        local record = address and REGISTRY[address]
        if record and (record.kind == "puma" or record.kind == "panther") then
            return current
        end
        -- ⛔⛔ THE REGISTRY IS NOT AUTHORITATIVE FOR PUMAS. Panthers are recorded at
        -- CONVERSION time (S.panther_seen), but a puma only ever enters REGISTRY if the
        -- world scan happens to catch it -- and the panel routinely reads "Detected: none"
        -- while a puma is stood in front of you. That asymmetry is precisely why pumas
        -- kept their wolf vocals while panthers sounded right: the counter caught the body
        -- being turned away with `no_cat 513 (last owner ch223001_00)` -- rejecting the
        -- puma chassis BY NAME. The GameObject name carries the chassis id, so trust it
        -- directly rather than depending on a scan that may never have run.
        local name = nil
        pcall(function() name = tostring(current:call("get_Name") or "") end)
        local by_name = nil
        if name and name:find(PANTHER_NAME, 1, true) then
            by_name = "panther"
        elseif name and name:find(PUMA_NAME, 1, true) then
            by_name = "puma"
        end
        if by_name then
            -- ⭐ ADOPT IT INTO THE REGISTRY, don't just wave it through. Returning the
            -- GameObject alone made the puma MUTE rather than wolf-voiced: the hook
            -- suppressed the wolf vocal, then asked cat_state_for() for the per-cat state
            -- that decides which cat sound to queue -- and S.cats is only ever populated
            -- by update_cat(), which iterates REGISTRY. No record, no state, no
            -- replacement, silence. Registering here fixes every REGISTRY consumer for
            -- pumas at once (speed tracking, vocal category, HP/death), not just audio.
            if address and not REGISTRY[address] then
                REGISTRY[address] = {
                    kind = by_name,
                    game_object = current,
                    marked_at = os.clock(),
                }
            end
            return current
        end
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

-- The semantic-howl learner must also see ordinary wolves.  The previous hook
-- claimed it did, but returned at the `not cat` gate before reaching the learner,
-- so Shadow could wait forever for a trigger that was never allowed to be seen.
local function ch223_ancestor(game_object)
    local current = game_object
    for _ = 1, 8 do
        if not valid(current) then return nil, nil end
        local character, id, name = nil, "", ""
        pcall(function()
            character = get_component(current, "app.Character")
            id = character and tostring(character:call("get_CharaIDString") or "") or ""
            name = tostring(current:call("get_Name") or "")
        end)
        if id:match("^ch223") or name:find("ch223", 1, true) then
            return current, character
        end
        local parent_go = nil
        pcall(function()
            local transform = current:call("get_Transform")
            local parent = transform and transform:call("get_Parent")
            parent_go = parent and parent:call("get_GameObject") or nil
        end)
        if not parent_go then return nil, nil end
        current = parent_go
    end
    return nil, nil
end

local function cat_state_for(game_object)
    local address = object_address(game_object)
    return address and S.cats[tostring(address)] or nil
end

-- ⭐ 08-13 RIDDEN CAT VOICE (Aurora: "the cat isn't making any sound when riding"):
-- the rodeo costume think-stops the body, so the native vocal triggers - and the
-- wolf-vocal replacer with them - go quiet the moment a cat is armed for riding.
-- Export the voice + the registry check so the rodeo can speak for it directly
-- (chassis id can NOT discriminate: Shadow the wolf is ch223 like the cats -
-- only the registry knows which bodies wear a cat).
pcall(function()
    local api = rawget(_G, "__iris_wild_cats_api")
    if not api then return end
    api.play = function(category, target_go)
        if not A.registration then pcall(audio_prepare) end
        local ok, err = play_category(category, target_go)
        if ok then return true end
        -- A newly summoned cat can be mounted inside the bank's 180-frame
        -- settle window. Keep the requested voice and post it once ready;
        -- previously that first refusal was simply lost.
        A.pending_direct[#A.pending_direct + 1] = {
            category = category, target = target_go,
            expires = os.clock() + 4.0, next_at = os.clock() + 0.25,
        }
        return false, err
    end
    api.is_cat = function(game_object)
        return registered_cat_ancestor(game_object) ~= nil
    end
    -- ⭐ 08-14 (Aurora: a wild puma's native B prompt read "Tame the Dog"). IrisTaming's
    -- creature_label has asked __iris_wild_cats_api.cat_kind since 08-05 - and this side never
    -- exported it, so the ask was DEAD every frame and every ch223001 body fell through to the
    -- "Dog" rung of the ladder. It also silently killed is_cat() over there, which is what has
    -- kept the whole FELINE rite (THE SIT instead of the howl) from ever running.
    -- REGISTRY FIRST (truth for any body a sweep has seen), CHASSIS ID second - and the id rung
    -- is not a guess, it is the identical rule refresh_cats builds the registry from: with the
    -- IRIS cat pak the Redwolf prefabs ARE the cats, _00 puma, _01 panther. The id rung also
    -- covers the sweep's lag (a full pass every 300 frames), so a cat you walk up to the instant
    -- it streams in still names itself.
    api.cat_kind = function(game_object)
        local host = registered_cat_ancestor(game_object) or game_object
        if not valid(host) then return nil end
        local address = object_address(host)
        local record = address and REGISTRY[address]
        if record and (record.kind == "puma" or record.kind == "panther") then
            return record.kind
        end
        local id = nil
        pcall(function()
            local character = get_component(host, "app.Character")
            id = character and character:call("get_CharaIDString") or nil
        end)
        if id == nil then pcall(function() id = host:call("get_Name") end) end
        id = tostring(id or "")
        if id:find(PANTHER_NAME, 1, true) then return "panther" end
        if id:find(PUMA_NAME, 1, true) then return "puma" end
        return nil
    end
    local function play_exact_wolf_howl(target_go)
        -- Use the event captured from a REAL, valid-graph wild-wolf howl. Shadow's
        -- parked graph cannot emit that action event, but her native ch223 Wwise
        -- container owns the same bank. Build the request from one of her valid
        -- vocal templates and substitute only the proven howl event ID.
        local event_id = normal_u32(A.wolf_howl_event_id)
        local dispatcher = get_component(target_go, "app.WwiseContainerApp")
        local template = native_template_for(target_go)
        local played, detail = false, nil
        if event_id and event_id > 0 and dispatcher and template then
            local original = nil
            pcall(function() original = tonumber(template._EventId) end)
            if original then
                A.manual_wolf_post_depth = (tonumber(A.manual_wolf_post_depth) or 0) + 1
                local ok, err = pcall(function() template._EventId = event_id end)
                if ok then played, detail = post_request(dispatcher, template, target_go) end
                pcall(function() template._EventId = original end)
                A.manual_wolf_post_depth = math.max(0,
                    (tonumber(A.manual_wolf_post_depth) or 1) - 1)
                if not ok then detail = tostring(err) end
            end
        end
        A.wolf_howl_last_post = {
            ok = played == true,
            route = played and "captured native ch223 howl event"
                or (event_id and (detail or "native howl event post failed")
                    or "real wild-wolf howl event not captured yet"),
            trigger_id = normal_u32(A.wolf_howl_trigger_id),
            event_id = event_id, at = os.clock(),
        }
        return played == true
    end
    api.play_wolf_howl = play_exact_wolf_howl
    -- 08-18 wyrm maul pain cries: post one of the TARGET's own triggers on
    -- its own container. Manual posts play on think-stopped bodies -- the
    -- ridden-cat voice above is the standing proof.
    -- 08-18: the wolf's harvested VO trigger ids, sorted -- lets the rodeo
    -- run a sound-browser-style picker for the maul growl.
    api.wolf_vocal_ids = function(target_go)
        local ids = ensure_vocal_ids(target_go)
        if not ids then return nil end
        local out = {}
        for id in pairs(ids) do out[#out + 1] = id end
        table.sort(out)
        return out
    end
    api.play_trigger_on = function(target_go, trigger_id)
        if not (valid(target_go) and tonumber(trigger_id)) then
            return false, "bad args"
        end
        local dispatcher = get_component(target_go, "app.WwiseContainerApp")
        if not dispatcher then return false, "no WwiseContainerApp" end
        local trig = native_trigger_for_id(target_go, trigger_id)
        if not trig then return false, "trigger not on target's lists" end
        return post_request(dispatcher, trig, target_go, true)
    end
    api.get_wolf_howl_status = function()
        return A.wolf_howl_last_post, A.wolf_trigger_trace
    end
    api.play_wolf_call = function(target_go, exact_only)
        if play_exact_wolf_howl(target_go) then return true end
        if exact_only ~= true then
            local dispatcher = get_component(target_go, "app.WwiseContainerApp")
            local trigger = native_trigger_for_id(target_go, A.wolf_howl_trigger_id)
            if dispatcher and trigger then
                return post_request(dispatcher, trigger, target_go)
            end
        end
        -- Give a native howl action time to emit and teach us its exact trigger.
        -- Never substitute a feline bank for a wolf: silence is preferable to
        -- Shadow roaring like Mia, and Horse Rodeo now wakes the real howl node.
        A.pending_wolf_calls[#A.pending_wolf_calls + 1] = {
            target = target_go, since = os.clock(), at = os.clock() + 0.48,
        }
        return false -- queued is not audible; let the caller use its deterministic fallback
    end
end)

local trigger_method = sdk.find_type_definition("app.WwiseContainerApp")
    :get_method("trigger(soundlib.SoundManager.RequestInfo)")
local trigger_hook_installed = false
local function install_trigger_hook()
    -- (08-13: stood down during the mount-CTD hunt and EXONERATED. Restored.)
    -- ⭐ Record the state where the DUMP can see it. `trigger_method` is a file-local
    -- declared far below the sweep that writes IrisWildCats_audio.json, so referencing it
    -- there would silently resolve to a nil GLOBAL -- and "hook never installed" would be
    -- indistinguishable from "hook installed but never fired". They need completely
    -- different fixes, so the dump must be able to tell them apart.
    S.trigger_method_ok = trigger_method ~= nil
    if trigger_hook_installed or not trigger_method then
        S.trigger_hook_ok = false
        return
    end
    trigger_hook_installed = true
    S.trigger_hook_ok = true
    -- ⛔ DISCARD ANY CACHED CATALOGUE AT ARM. `A` lives in _G and survives a script
    -- reload, so a catalogue learned from the wrong chassis would outlive the very fix
    -- for it -- and the symptom (wolf sounds continuing) is identical either way.
    A.vocal_ids = nil
    sdk.hook(trigger_method, function(args)
        if S.generation ~= GENERATION then return end
        -- 08-18 wyrm maul pain cries: the rodeo opens a short watch window
        -- after each real hit on its prey; those posts must be seen even
        -- with wolf-vocal replacement off.
        local prey_watch = rawget(_G, "IrisWyrmPreyVocalWatch")
        local prey_hot = prey_watch ~= nil
            and os.clock() <= (tonumber(prey_watch.until_t) or 0.0)
        if not (C.enabled and C.replace_wolf_vocals) and not prey_hot then
            return
        end
        local container, request = nil, nil
        pcall(function() container = sdk.to_managed_object(args[2]) end)
        pcall(function() request = sdk.to_managed_object(args[3]) end)
        if not container or not request then return end
        local owner = nil
        pcall(function() owner = container:call("get_GameObject") end)
        local trigger_id = 0
        local event_id = 0
        pcall(function()
            trigger_id = normal_u32(request:call("get_TriggerId")) or 0
            event_id = normal_u32(request:call("get_EventId")) or 0
        end)
        -- 08-18 PREY HURT-VOCAL CAPTURE: inside the rodeo's watch window,
        -- a post whose owner is the current prey AND whose trigger lives on
        -- a "_vo" list is that species' pain cry -- record it so the pinned
        -- maul (think-stop mutes native FSM vocals) can speak for the prey,
        -- exactly the way the ridden-cat voice speaks for a parked cat.
        if prey_hot and container and event_id ~= 0 then
            local matched = false
            local probe = owner
            for _ = 1, 5 do
                if not probe then break end
                if object_address(probe) == prey_watch.addr then
                    matched = true
                    break
                end
                local parent = nil
                pcall(function()
                    local tf = probe:call("get_Transform")
                    local ptf = tf and tf:call("get_Parent")
                    parent = ptf and ptf:call("get_GameObject")
                end)
                probe = parent
            end
            if matched then
                -- targeted "_vo" check on the poster's OWN lists -- never
                -- through ensure_vocal_ids, whose cache is the wolf's
                -- catalogue and must not be polluted with goblin ids.
                local is_vo = false
                pcall(function()
                    local user_data = container._UserDataList
                    for bank_index = 0, collection_count(user_data) - 1 do
                        local lists = nil
                        pcall(function()
                            lists = user_data[bank_index]._UserDataList
                        end)
                        for list_index = 0, collection_count(lists) - 1 do
                            local list = lists[list_index]
                            local triggers = nil
                            pcall(function()
                                triggers = list._TriggerInfoList
                            end)
                            for index = 0, collection_count(triggers) - 1 do
                                local id = nil
                                pcall(function()
                                    id = normal_u32(
                                        triggers[index]._TriggerId)
                                end)
                                if id == trigger_id then
                                    local path = ""
                                    pcall(function()
                                        path = tostring(
                                            list:call("get_Path"))
                                    end)
                                    is_vo = string.find(
                                        string.lower(path), "_vo", 1, true)
                                        ~= nil
                                    return
                                end
                            end
                        end
                    end
                end)
                if is_vo then
                    local store = rawget(_G, "IrisWyrmPreyHurtVocal")
                    if type(store) ~= "table" then store = {} end
                    local keys = 0
                    for _ in pairs(store) do keys = keys + 1 end
                    if keys > 32 then store = {} end
                    store[prey_watch.addr] = {
                        trigger_id = trigger_id, event_id = event_id,
                        at = os.clock(),
                    }
                    rawset(_G, "IrisWyrmPreyHurtVocal", store)
                    pcall(function()
                        log.info(string.format(
                            "[%s] [WYRM-AUDIO] prey HURT vocal captured: trigger=%u event=%u",
                            MOD, trigger_id, event_id))
                    end)
                end
            end
        end
        if not (C.enabled and C.replace_wolf_vocals) then return end
        -- Mounted howl receipt.  Keep the last 32 Wwise requests originating
        -- from a ch223 while a wyrm combat lease is live.  This reveals whether
        -- motion 4610/4611 emitted a real native vocal trigger, and whether our
        -- manual retry merely constructed a silent request.  It is event-driven,
        -- so there is no per-frame audio logging cost.
        local mounted_lease = rawget(_G, "IrisWyrmNativeAttackLease")
        if mounted_lease then
            local mounted_go, mounted_ch = ch223_ancestor(owner)
            if mounted_go and mounted_ch then
                local bank, motion_id, motion_frame = -1, -1, -1
                pcall(function()
                    local motion = mounted_ch:call("get_Motion")
                    local layer = motion and motion:call("getLayer", 0)
                    bank = layer and tonumber(layer:call("get_MotionBankID")) or -1
                    motion_id = layer and tonumber(layer:call("get_MotionID")) or -1
                    motion_frame = layer and tonumber(layer:call("get_Frame")) or -1
                end)
                A.wolf_trigger_trace = type(A.wolf_trigger_trace) == "table"
                    and A.wolf_trigger_trace or {}
                A.wolf_trigger_trace[#A.wolf_trigger_trace + 1] = {
                    at = os.clock(), trigger_id = trigger_id, event_id = event_id,
                    source = (tonumber(A.manual_wolf_post_depth) or 0) > 0
                        and "manual" or "native",
                    bank = bank, motion_id = motion_id, frame = motion_frame,
                }
                while #A.wolf_trigger_trace > 32 do
                    table.remove(A.wolf_trigger_trace, 1)
                end
                pcall(function()
                    log.info(string.format(
                        "[%s] [WYRM-AUDIO] %s trigger=%u event=%u motion=%s:%s frame=%.1f",
                        MOD, A.wolf_trigger_trace[#A.wolf_trigger_trace].source,
                        trigger_id, event_id, tostring(bank), tostring(motion_id), motion_frame))
                end)
            end
        end
        -- Learn before the cat-only replacement gate.  Require membership in
        -- ch223's harvested vocal catalogue so a footstep or magic accent which
        -- happens during the same motion can never become Shadow's "howl".
        local wolf_go, wolf_ch = ch223_ancestor(owner)
        if wolf_go and wolf_ch
            and (tonumber(A.manual_wolf_post_depth) or 0) == 0
            and rawget(_G, "IrisWyrmNativeAttackLease") == nil then
            local vocal_ids = ensure_vocal_ids(wolf_go)
            if vocal_ids and vocal_ids[trigger_id] then
                local bank, motion_id, motion_frame = -1, -1, -1
                pcall(function()
                    local motion = wolf_ch:call("get_Motion")
                    local layer = motion and motion:call("getLayer", 0)
                    bank = layer and tonumber(layer:call("get_MotionBankID")) or -1
                    motion_id = layer and tonumber(layer:call("get_MotionID")) or -1
                    motion_frame = layer and tonumber(layer:call("get_Frame")) or -1
                end)
                -- Preserve the full native vocal sequence from an ordinary,
                -- unmounted wolf.  The former learner guessed that the only
                -- request seen during forced motion 4610 was the howl; field
                -- audio disproved that.  A naturally audible howl is the sole
                -- trustworthy reference. JSON is deferred off the Wwise hook.
                A.wolf_natural_vocal_trace = type(A.wolf_natural_vocal_trace)
                    == "table" and A.wolf_natural_vocal_trace or {}
                local action_name = wolf_current_action_name(wolf_ch)
                local capture_armed = A.howl_capture_target_addr ~= nil
                    and object_address(wolf_go) == A.howl_capture_target_addr
                    and os.clock() <= (tonumber(A.howl_capture_until) or 0.0)
                A.wolf_natural_vocal_trace[#A.wolf_natural_vocal_trace + 1] = {
                    at = os.clock(), trigger_id = trigger_id,
                    event_id = event_id, action = action_name,
                    capture_armed = capture_armed,
                    bank = bank, motion_id = motion_id, frame = motion_frame,
                }
                while #A.wolf_natural_vocal_trace > 64 do
                    table.remove(A.wolf_natural_vocal_trace, 1)
                end
                A.save_wolf_natural_vocal_trace = true
                -- Only the start-loop owns the howl vocal.  Accepting 4612 made
                -- the last end-clip request overwrite it with a silent close.
                if event_id > 0 and (capture_armed
                    or (action_name
                        and action_name:find("HowlingStart", 1, true))) then
                    A.wolf_howl_trigger_id = trigger_id
                    A.wolf_howl_event_id = event_id
                    A.wolf_howl_heard_at = os.clock()
                    A.howl_capture_target_addr, A.howl_capture_until = nil, nil
                    S.audio_status = "captured genuine wild-wolf howl event "
                        .. tostring(event_id)
                    if tonumber(C.wolf_howl_trigger_id) ~= trigger_id
                        or tonumber(C.wolf_howl_event_id) ~= event_id then
                        C.wolf_howl_trigger_id = trigger_id
                        C.wolf_howl_event_id = event_id
                        -- Never perform JSON I/O inside the Wwise pre-hook.
                        A.save_howl_trigger = true
                    end
                end
            end
        end
        -- ⭐ WHY-COUNTERS. Posting demonstrably works (the panel test plays pain_03) yet
        -- "vocals replaced: 0" in the field, so the hook is being turned away at one of
        -- exactly two gates. Counting them costs nothing and ends the guessing: if
        -- no_vocal_id dominates, the catalogue never learned this wolf's VO trigger ids;
        -- if no_cat dominates, the sound's owner GameObject is not resolving back to a
        -- registered cat (the container's owner is often a CHILD of the character).
        A.dbg = A.dbg or {seen = 0, no_vocal_id = 0, no_cat = 0, replaced = 0}
        A.dbg.seen = A.dbg.seen + 1
        -- ⛔⛔⛔ RESOLVE THE CAT **BEFORE** BUILDING THE VOCAL CATALOGUE. This hook fires
        -- for EVERY Wwise trigger in the game, and ensure_vocal_ids() caches the FIRST
        -- non-empty result GLOBALLY. Called with the raw sound owner it therefore learned
        -- whichever creature happened to vocalise first -- the field counters caught it
        -- red-handed: 72 sounds owned by `ch299420_A_00_1` sailed through the vocal-id
        -- gate, which is only possible if the cached ids belong to THAT chassis. Real wolf
        -- vocals on cats then never matched, so `replaced` sat at 1 instead of hundreds.
        -- Gate on "is this a cat" first, and the catalogue can only ever be a cat's.
        local cat = nil
        local mounted_audio = rawget(_G, "__iris_rodeo_mounted_cat_audio_owner")
        if mounted_audio then
            pcall(function() cat = mounted_audio(owner, container) end)
        end
        if not cat then cat = registered_cat_ancestor(owner) end
        if not cat then
            A.dbg.no_cat = A.dbg.no_cat + 1
            pcall(function()
                A.dbg.last_owner = tostring(owner and owner:call("get_Name") or "nil")
            end)
            return
        end

        local vocal_ids = ensure_vocal_ids(cat)
        if not (vocal_ids and vocal_ids[trigger_id]) then
            -- ⭐ SELF-HEAL: a miss ON A CAT means the catalogue has never seen THIS cat's
            -- bank -- which is exactly how pumas ended up on wolf sounds while panthers
            -- were fine. Re-harvest from this animal and merge, throttled so a genuinely
            -- non-vocal id cannot spin the bank walk every frame.
            if os.clock() >= (A.next_harvest or 0) then
                A.next_harvest = os.clock() + 1.0
                vocal_ids = harvest_vocal_ids(cat)
            end
            if not (vocal_ids and vocal_ids[trigger_id]) then
                A.dbg.no_vocal_id = A.dbg.no_vocal_id + 1
                A.dbg.last_miss_id = trigger_id
                return
            end
        end
        A.dbg.replaced = A.dbg.replaced + 1

        local state = cat_state_for(cat)
        if state and state.death_played then
            return sdk.PreHookResult.SKIP_ORIGINAL
        end
        -- ⛔ NO STATE YET = A SILENT CAT. update_cat only builds the per-cat state on the
        -- next sweep after the body is registered, so the very first vocal of a freshly
        -- adopted puma would be suppressed with nothing queued in its place. Queue a
        -- sensible default instead -- a muted cat is worse than a slightly generic growl.
        if not state and os.clock() >= (A.next_orphan_vocal or 0) then
            A.next_orphan_vocal = os.clock() + 2.0
            A.pending_vocals[#A.pending_vocals + 1] = {cat = cat, category = "growl"}
        end
        if state and os.clock() > (state.next_vocal or 0) then
            state.next_vocal = os.clock() + 2.0
            local speed = state.smoothed_speed or 0
            local category
            if speed > 4.0 or os.clock() < (state.aggro_until or 0) then
                category = "attack"
            elseif speed > 1.0 then
                category = "alert"
            else
                category = math.random(10) <= 7 and "growl" or "alert"
            end
            A.pending_vocals[#A.pending_vocals + 1] = {
                cat = cat, category = category,
            }
        end
        A.suppressed = A.suppressed + 1
        return sdk.PreHookResult.SKIP_ORIGINAL
    end, function(retval) return retval end)
end

local function drain_vocals()
    if #A.pending_vocals == 0 then return end
    local pending = A.pending_vocals
    A.pending_vocals = {}
    if not (C.audio_enabled and audio_ready()) then return end
    for _, item in ipairs(pending) do
        local state = cat_state_for(item.cat)
        if valid(item.cat) and not (state and state.death_played) then
            if play_category(item.category, item.cat) then
                A.replaced = A.replaced + 1
            end
        end
    end
end

local function drain_direct_audio()
    if #A.pending_direct > 0 and C.audio_enabled and audio_ready() then
        local keep, now = {}, os.clock()
        for _, item in ipairs(A.pending_direct) do
            if now <= (tonumber(item.expires) or 0) and valid(item.target) then
                if now < (tonumber(item.next_at) or 0) then
                    keep[#keep + 1] = item
                elseif not play_category(item.category, item.target) then
                    item.next_at = now + 0.25
                    keep[#keep + 1] = item
                end
            end
        end
        A.pending_direct = keep
    end
    if #A.pending_wolf_calls == 0 then return end
    local keep, now = {}, os.clock()
    for _, item in ipairs(A.pending_wolf_calls) do
        if now < (tonumber(item.at) or now) then
            keep[#keep + 1] = item
        elseif valid(item.target) then
            -- If this very move produced the native howl, it has already been
            -- heard; posting it a second time would overlap itself.
            local heard = tonumber(A.wolf_howl_heard_at) or 0
            if heard < (tonumber(item.since) or 0) then
                local dispatcher = get_component(item.target, "app.WwiseContainerApp")
                local trigger = native_trigger_for_id(
                    item.target, A.wolf_howl_trigger_id)
                if dispatcher and trigger then
                    post_request(dispatcher, trigger, item.target)
                elseif now < (tonumber(item.since) or now) + 4.0 then
                    item.at = now + 0.10
                    keep[#keep + 1] = item
                end
            end
        end
    end
    A.pending_wolf_calls = keep
end

-- ---------------------------------------------------------------------------
-- Per-cat state: speed, HP hurt/death, ambient growls/purrs
-- ---------------------------------------------------------------------------

local function read_hp(game_object)
    local character = get_component(game_object, "app.Character")
    if not character then return nil end
    local value = nil
    pcall(function()
        local hit_point = character:call("get_HitPoint")
        if hit_point then
            value = tonumber(hit_point:call("get_Value"))
        end
    end)
    if value == nil then
        pcall(function() value = tonumber(character:call("get_Hp")) end)
    end
    return value
end

local function update_cat(record, now)
    if not valid(record.game_object) then return end
    local key = tostring(object_address(record.game_object) or record.game_object)
    local state = S.cats[key]
    if not state then
        state = {key = key}
        S.cats[key] = state
    end
    state.game_object = record.game_object
    state.seen_at = now

    local position = nil
    pcall(function()
        local transform = record.game_object:call("get_Transform")
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
        state.last_position = {x = position.x, y = position.y, z = position.z}
        state.last_position_time = now
    end

    local hp = read_hp(record.game_object)
    if hp ~= nil then
        local previous = state.hp
        state.hp = hp
        if previous ~= nil then
            if hp <= 0 and previous > 0 and not state.death_played then
                state.death_played = true
                play_category("death", state.game_object)
            elseif hp < previous and hp > 0 then
                state.aggro_until = now + 6.0
                if now > (state.next_hurt or 0) then
                    state.next_hurt = now + 1.5
                    play_category("hurt", state.game_object)
                end
            end
        end
    end

    if C.ambient_enabled and C.audio_enabled and audio_ready()
        and not state.death_played then
        if S.game_paused then
            state.ambient_next = math.max(state.ambient_next or 0, now + 3.0)
        elseif not state.ambient_next then
            state.ambient_next = now + math.random(15, 35)
        elseif now >= state.ambient_next then
            state.ambient_next = now + math.random(15, 35)
            if (state.smoothed_speed or 0) < 1.0 then
                -- Growl 75% / purr 25% while idle.
                local category = math.random(4) <= 3 and "growl" or "purr"
                play_category(category, state.game_object)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Frame loop
-- ---------------------------------------------------------------------------

load_config()
-- One-time repair for configs learnt by the old whole-sequence learner.  The
-- field trace identified 3274161328 on 4610 and 3982150705 on 4612 in the same
-- LT press; Aurora heard no howl because we manually replayed the latter.
if tonumber(C.wolf_howl_trigger_id) == 3982150705
    or (tonumber(C.wolf_howl_trigger_id) or 0) <= 0 then
    C.wolf_howl_trigger_id = 3274161328
    save_config()
end
A.wolf_howl_trigger_id = tonumber(C.wolf_howl_trigger_id) or 0
if A.wolf_howl_trigger_id <= 0 then A.wolf_howl_trigger_id = nil end
A.wolf_howl_event_id = tonumber(C.wolf_howl_event_id) or 0
if A.wolf_howl_event_id <= 0 then A.wolf_howl_event_id = nil end
-- RequestInfo positioning only added a hard cull to the flat custom bank.
-- Pre-gained event tiers now provide distance volume without touching the
-- working creature-bound request, so the legacy path remains disabled.
C.spatial_audio = false
if not S.wolf_id or not S.puma_id or not S.panther_id then
    report("Character IDs unavailable: " .. tostring(S.wolf_id_error) .. " | "
        .. tostring(S.puma_id_error) .. " | " .. tostring(S.panther_id_error))
else
    report("IRIS Wild Cats installed; arming deferred until the world is live.")
end

re.on_application_entry("UpdateBehavior", function()
    local state = rawget(_G, SPAWN_STATE_KEY)
    if not state or not state.active or state.generation ~= GENERATION then return end
    state.frame = (state.frame or 0) + 1
    if A.save_howl_trigger then
        A.save_howl_trigger = nil
        save_config()
    end
    if A.save_wolf_natural_vocal_trace then
        A.save_wolf_natural_vocal_trace = nil
        pcall(function()
            json.dump_file("IrisWolfNaturalVocalTrace.json", {
                generated_at = os.date("%Y-%m-%d %H:%M:%S"),
                vocals = A.wolf_natural_vocal_trace or {},
            })
        end)
    end
    if not C.enabled then return end
    -- STAGGERED deferred boot (2026-08-05): the all-at-once arm crashed the
    -- game 58 ms after firing, but that window spans four separate actions.
    -- Now: 10 quiet seconds after the player exists, then ONE action every
    -- ~1.5 s with a log line each — the crash log names the guilty step, or
    -- clears this module entirely if the game dies during the quiet phase.
    if not WORLD_ARMED then
        if not S.arm_ready_frame then
            if state.frame % 30 ~= 0 then return end
            if not world_ready() then return end
            S.arm_ready_frame = state.frame
            report("world live; holding quiet for 600 frames before arming")
            return
        end
        local elapsed = state.frame - S.arm_ready_frame
        if elapsed < 600 then return end
        local step = S.arm_step or 0
        if elapsed < 600 + step * 90 then return end
        S.arm_step = step + 1
        if step == 0 then
            -- Read-only probe: is our pak content actually mounted right now?
            -- Fluffy renumbers the patch chain freely; if the cat mesh path
            -- doesn't resolve, staging the puma prefab is a delayed death.
            local custom, control = nil, nil
            pcall(function()
                custom = sdk.create_resource("via.render.MeshResource",
                    "character/ch/ch23_001/ch23_001.mesh")
            end)
            pcall(function()
                control = sdk.create_resource("via.render.MeshResource",
                    "character/ch/ch23_000/ch23_000.mesh")
            end)
            report(string.format(
                "arm step 1 mount check: custom cat mesh %s | vanilla wolf mesh %s",
                custom and "RESOLVED" or "MISSING",
                control and "RESOLVED" or "MISSING"))
        elseif step == 1 then
            -- Prefabs are staged at SCRIPT LOAD (hollow-prefab law) — this
            -- step only verifies and reports readiness, it must never restage.
            report(string.format(
                "arm step 2: chassis staged at load -- puma ready %s | panther ready %s",
                tostring(resource_ready(S.puma_resource)),
                tostring(resource_ready(S.panther_resource))))
        elseif step == 2 then
            report("arm step 3: installing Wwise trigger hook")
            install_trigger_hook()
        elseif step == 3 then
            report("arm step 4: installing GenerateManager spawn hooks")
            install_hooks_once()
        else
            report("arm step 5: frame work live -- sweeps OFF, phasing in")
            -- ⭐ WARM THE PANTHER MATERIAL AT BOOT, NEVER LAZILY ON THE FIRST PANTHER.
            -- Exactly the unicorn's law: cold create_resource is async, so the 15 s stream
            -- gate has to be paid by SOMETHING. Paying it here, minutes before any cat
            -- spawns, means the first panther is instant instead of arriving vanilla and
            -- waiting for a retry.
            pcall(function() load_panther_mdf() end)

            -- ⭐ ONE-SHOT SOUND-API DUMP. Aurora: the vocals now cut out at a radius
            -- instead of fading, which is the signature of an event with NO attenuation
            -- ShareSet -- full volume until the cull distance, then nothing. Attenuation
            -- is authored into the BANK, so the only Lua-side fix is to drive volume (or
            -- an RTPC) per post from the listener distance. Whether that is even possible
            -- depends on what RequestInfo and the container actually expose, and there is
            -- no il2cpp dump on this machine to read it from. Ask the engine once.
            pcall(function()
                if S.sound_api_dumped then return end
                S.sound_api_dumped = true
                local out = {}
                local function dump(type_name, want)
                    local td = sdk.find_type_definition(type_name)
                    if not td then out[type_name] = "TYPE NOT FOUND" return end
                    local fields, methods = {}, {}
                    pcall(function()
                        for _, f in ipairs(td:get_fields() or {}) do
                            local n = f:get_name()
                            if not want or n:lower():find(want) then
                                fields[#fields + 1] = n .. " : "
                                    .. tostring(f:get_type():get_full_name())
                            end
                        end
                    end)
                    pcall(function()
                        for _, m in ipairs(td:get_methods() or {}) do
                            local n = m:get_name()
                            if not want or n:lower():find(want) then
                                methods[#methods + 1] = n
                            end
                        end
                    end)
                    out[type_name] = {fields = fields, methods = methods}
                end
                dump("soundlib.SoundManager.RequestInfo", nil)
                dump("soundlib.SoundTriggerInfo", nil)
                dump("app.WwiseContainerApp", "volume")
                dump("via.wwise.WwiseContainer", "volume")
                dump("app.WwiseContainerApp", "rtpc")
                json.dump_file("IrisWildCats_soundapi.json", out)
                report("sound API dumped -> data/IrisWildCats_soundapi.json")
            end)
            S.sweep_source = 0
            WORLD_ARMED = true
        end
        return
    end
    -- Sweep sources phase in one at a time, ~3 s apart, so the crash log can
    -- name the exact enumeration that dies against a streaming world:
    -- phase 1 = CharacterManager lists, 2 = +AISituation agents,
    -- phase 3 = +scene-wide findComponents.
    if (S.sweep_source or 0) < 3 then
        local phase = math.min(3,
            math.floor((state.frame - S.arm_ready_frame - 960) / 180))
        if phase > (S.sweep_source or 0) then
            S.sweep_source = phase
            report("sweep phase " .. phase .. ": " .. ({
                "CharacterManager lists",
                "+ AISituation agent walk",
                "+ scene-wide findComponents",
            })[phase])
        end
    end
    -- Registry maintenance used to perform 301 AISituation calls plus a
    -- scene-wide app.Character enumeration every 30 frames, forever.  Keep
    -- that expensive recovery path responsive only while a newly converted
    -- panther group is waiting to be identified.  Established cats need only
    -- the CharacterManager list, with a sparse full sweep for streamed strays.
    local panther_pending = #S.pending_panther_groups > 0
    if panther_pending and state.frame % 30 == 0 then
        refresh_cats(3)
    elseif state.frame % 300 == 0 then
        refresh_cats(3)
    elseif state.frame % 120 == 0 then
        refresh_cats(1)
    end
    if not state.resources_reported
        and resource_ready(state.puma_resource)
        and resource_ready(state.panther_resource)
    then
        state.resources_reported = true
        report("Ready: wolf packs now roll cats at the configured share.")
    end

    if C.audio_enabled and not A.registration
        and state.frame >= (A.next_auto_prepare or 0) then
        local any_cat = false
        for _, record in pairs(REGISTRY) do
            if (record.kind == "puma" or record.kind == "panther")
                and valid(record.game_object) then
                any_cat = true
                break
            end
        end
        if any_cat and player_wwise_container() then
            A.next_auto_prepare = state.frame + 600
            audio_prepare()
        end
    end
    resolve_pending_triggers()
    drain_vocals()
    drain_direct_audio()

    local now = os.clock()
    if now >= S.next_sample then
        S.next_sample = now + 0.05
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
            if record.kind == "puma" or record.kind == "panther" then
                update_cat(record, now)
            end
        end
        for key, state in pairs(S.cats) do
            if now - (state.seen_at or 0) > 5.0
                or not valid(state.game_object) then
                S.cats[key] = nil
            end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- UI: one panel
-- ---------------------------------------------------------------------------

local function first_cat()
    for _, record in pairs(REGISTRY) do
        if (record.kind == "puma" or record.kind == "panther")
            and valid(record.game_object) then
            return record.game_object
        end
    end
    -- Registry can lag behind a freshly spawned cat: scan live and register.
    refresh_cats()
    for _, record in pairs(REGISTRY) do
        if (record.kind == "puma" or record.kind == "panther")
            and valid(record.game_object) then
            return record.game_object
        end
    end
    return nil
end

re.on_draw_ui(function()
    local state = rawget(_G, SPAWN_STATE_KEY)
    if not state or state.generation ~= GENERATION then return end
    if not imgui.collapsing_header("IRIS - Wild Cats") then return end

    local changed, value
    changed, value = imgui.checkbox("Enabled##iris_cats", C.enabled)
    if changed then
        C.enabled = value
        S.enabled = value
        S.recent_packs = {}
        save_config()
    end

    changed, value = imgui.slider_float(
        "Cat share of wolf packs", C.cat_pack_chance, 0.0, 1.0, "%.2f")
    if changed then C.cat_pack_chance = value; save_config() end

    changed, value = imgui.slider_float(
        "Panther share of cats", C.panther_share, 0.0, 1.0, "%.2f")
    if changed then C.panther_share = value; save_config() end

    changed, value = imgui.checkbox("Cat sounds", C.audio_enabled)
    if changed then C.audio_enabled = value; save_config() end
    imgui.same_line()
    changed, value = imgui.checkbox("Replace wolf vocals", C.replace_wolf_vocals)
    if changed then C.replace_wolf_vocals = value; save_config() end
    imgui.same_line()
    changed, value = imgui.checkbox("Ambient growls", C.ambient_enabled)
    if changed then C.ambient_enabled = value; save_config() end

    if imgui.button("Force next pack: PUMAS") then
        S.force_next = "puma"
        S.recent_packs = {}
    end
    imgui.same_line()
    if imgui.button("Force next pack: PANTHERS") then
        S.force_next = "panther"
        S.recent_packs = {}
    end
    imgui.same_line()
    if imgui.button("Clear forced") then S.force_next = nil end

    imgui.text(string.format(
        "Packs: %d rolled | %d Wolf | %d Puma | %d Panther | members: %d/%d",
        S.packs_rolled or 0, S.vanilla_packs or 0, S.puma_packs or 0,
        S.panther_packs or 0, S.puma_wolves or 0, S.panther_wolves or 0))
    imgui.text(string.format(
        "Audio: %s | direct: %d | vocals replaced: %d | muted: %d",
        (C.audio_enabled and audio_ready()) and "READY"
            or (A.registration and "settling" or "waiting for a cat"),
        A.direct_count or 0, A.replaced or 0, A.suppressed or 0))
    if A.last_played then
        imgui.text("Last sound: " .. tostring(A.last_played))
    end
    if imgui.button("Load cat audio now") then audio_prepare() end
    imgui.text("Audio status: " .. tostring(S.audio_status))
    imgui.text("Detected: " .. tostring(S.detected_wolf_ids or "none"))
    imgui.text("Status: " .. tostring(S.status))

    if imgui.tree_node("Advanced##iris_wild_cats") then
        imgui.text("Hooks: natural-world "
            .. (S.category_hook_installed and "OK" or "MISSING")
            .. " | spawner "
            .. (S.instance_hook_installed and "OK" or "MISSING"))
        imgui.text("Resources: puma "
            .. tostring(resource_ready(S.puma_resource))
            .. " | panther " .. tostring(resource_ready(S.panther_resource)))
        local dg = A.dbg or {}
        imgui.text(string.format(
            "Vocal hook: seen %d | no_vocal_id %d (last %s) | no_cat %d (last owner %s)"
            .. " | replaced %d | catalogue %d ids",
            dg.seen or 0, dg.no_vocal_id or 0, tostring(dg.last_miss_id or "-"),
            dg.no_cat or 0, tostring(dg.last_owner or "-"), dg.replaced or 0,
            A.vocal_id_count or 0))
        imgui.text("Panther material: " .. tostring(S.pmdf_status or "not requested")
            .. " | swaps " .. tostring(S.panther_mdf_swaps or 0))
        imgui.text("Live panthers: " .. tostring(S.panther_modes or "none tracked"))
        imgui.text("Distance volume: four safe bank tiers")
        imgui.text("  last emitter: " .. tostring(A.last_emitter or "-")
            .. " | tier " .. tostring(A.last_audio_tier or "-")
            .. " | metres " .. (A.last_audio_distance
                and string.format("%.1f", A.last_audio_distance) or "-"))
        local at_changed, at_value = imgui.slider_float(
            "Distance-volume range scale", C.attenuation_scale or 1.0, 0.25, 3.0, "%.2f")
        if at_changed then C.attenuation_scale = at_value; save_config() end
        imgui.text("  staging error: puma "
            .. tostring(S.puma_resource and S.puma_resource.error or "none")
            .. " | panther "
            .. tostring(S.panther_resource and S.panther_resource.error or "none"))

        -- ⛔ THE PANTHER CHASSIS HAS NEVER LOADED SINCE ITS PREFAB WAS REDIRECTED TO
        -- ch23_002 (2026-08-15). get_Ready alone cannot say WHICH referenced resource is
        -- refusing, so stop guessing and ask the engine directly: probe every path the
        -- redirected prefab depends on, with the working ch23_001 set as the control. If
        -- the ch23_002 mesh/mdf2 resolve but the prefab still will not ready, the fault is
        -- inside the prefab patch; if they do not resolve, it is the pak/paths.
        if imgui.button("PROBE: ch23_002 resource resolution") then
            local out = {}
            local function probe(kind, path)
                local res = nil
                local ok, err = pcall(function()
                    res = sdk.create_resource(kind, path)
                end)
                out[#out + 1] = path:match("[^/]+$") .. "="
                    .. (res and "OK" or (ok and "nil" or "throw"))
            end
            probe("via.render.MeshResource", "character/ch/ch23_001/ch23_001.mesh")
            probe("via.render.MeshResource", "character/ch/ch23_002/ch23_002.mesh")
            probe("via.render.MeshResource", "character/ch/ch23_002/ch23_002.mdf2")
            probe("via.Prefab", "AppSystem/ch/ch223/prefab/ch223001_00.pfb")
            probe("via.Prefab", "AppSystem/ch/ch223/prefab/ch223001_01.pfb")
            -- and a FRESH prefab instance, in case the one staged at load is just stale
            local fresh_ready = "n/a"
            pcall(function()
                local p = sdk.create_instance("via.Prefab")
                if p then
                    p:add_ref()
                    p:set_Path("AppSystem/ch/ch223/prefab/ch223001_01.pfb")
                    p:call("set_Standby", true)
                    fresh_ready = tostring(p:call("get_Ready"))
                end
            end)
            S.probe_status = table.concat(out, " | ") .. "  || fresh panther prefab ready="
                .. fresh_ready
            report("PROBE: " .. tostring(S.probe_status))
        end
        if S.probe_status then
            imgui.text("Probe: " .. tostring(S.probe_status))
        end
        if imgui.button("Test: growl on PLAYER (target discriminator)") then
            local player_go = nil
            pcall(function()
                local manager = sdk.get_managed_singleton("app.CharacterManager")
                local character = manager and manager:call("get_ManualPlayer")
                local inner = character and character:call("get_Character")
                character = inner or character
                player_go = character and character:call("get_GameObject")
            end)
            if not player_go then
                S.audio_status = "player GameObject unavailable"
            else
                local ok, err = play_category("growl", player_go)
                S.audio_status = ok and "played growl on PLAYER — target was the problem"
                    or ("player-target growl refused: " .. tostring(err))
            end
        end
        if imgui.button("Test: NATIVE wolf vocal on cat (trigger discriminator)") then
            local cat = first_cat()
            local template = cat and native_template_for(cat)
            if not cat then
                S.audio_status = "native test: no live cat"
            elseif not template then
                S.audio_status = "native test: no wolf vocal template found"
            elseif not (A.registration and valid(A.registration.dispatcher)) then
                S.audio_status = "native test: dispatcher not ready"
            else
                local ok, err = post_request(
                    A.registration.dispatcher, template, cat)
                S.audio_status = ok
                    and "native wolf vocal POSTED on cat — listen for a howl"
                    or ("native-on-cat refused: " .. tostring(err))
            end
        end
        if imgui.button("CAPTURE howl from nearest WILD wolf") then
            local ok, detail = force_nearest_wild_wolf_howl()
            S.audio_status = (ok and "capture armed: " or "capture refused: ")
                .. tostring(detail)
        end
        imgui.text("Category tests (first cat):")
        for _, category in ipairs({
            "growl", "alert", "attack", "hurt", "death", "purr",
        }) do
            if imgui.button(category .. "##iris_cat_test") then
                local target = first_cat()
                if not target then
                    S.audio_status = category
                        .. " refused: no live cat found to play on"
                else
                    local ok, err = play_category(category, target)
                    S.audio_status = ok
                        and ("played " .. tostring(A.last_played))
                        or (category .. " refused: " .. tostring(err))
                end
            end
            imgui.same_line()
        end
        imgui.new_line()
        imgui.tree_pop()
    end
end)

report("loaded; automatic cat packs + vocals")
