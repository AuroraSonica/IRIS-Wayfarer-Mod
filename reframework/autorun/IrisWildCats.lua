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
local PACK_FRAME_WINDOW = 360
local PACK_RADIUS = 70.0
local PACK_RADIUS_SQ = PACK_RADIUS * PACK_RADIUS
-- Ceiling on how many spawns one roll can claim. A native wolf pack is a few animals arriving
-- in the same burst; without a cap, repeated manual spawns all inherit one decision.
local PACK_MAX_MEMBERS = 6

local PANTHER_MATERIALS = {
    ch23_001_body_mat = {0.115, 0.125, 0.145, 1.0},
    ch23_001_head_mat = {0.105, 0.115, 0.135, 1.0},
    ch23_001_fur1_mat = {0.165, 0.175, 0.195, 1.0},
    ch23_001_fur2_mat = {0.145, 0.155, 0.180, 1.0},
    ch23_001_eye_mat = {1800.0, 55.0, 0.0, 1.0},
}
local PANTHER_EYE_EMISSIVE = {5.0, 2.2, 0.04, 1.0}

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

local function apply_panther_material(character)
    local writes = 0
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

local function refresh_cats()
    local frame = S.frame or 0
    local targets = collect_wolf_family(S.sweep_source or 3)
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
            if frame - record.first_frame <= 480 and frame - record.last_apply >= 60 then
                local writes = apply_panther_material(item.character)
                if writes > 0 then
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
    for _, path in ipairs(manifest.trigger_list_paths or {}) do
        local instance = create_userdata_any(
            "soundlib.SoundTriggerInfoListData", path)
        if instance then
            trigger_instances[#trigger_instances + 1] = instance
        else
            report("cat trigger-list USER unresolved: " .. tostring(path))
        end
    end

    -- CRASH MITIGATION: register once per game process (see IrisWildHorses;
    -- repeated re-registration = suspected Wwise bank-state rot).
    if rawget(_G, "__iris_audio_loaded_cats") ~= address then
        local load_ok, load_err = pcall(function()
            dispatcher:call(
                "loadContainableUserData(soundlib.SoundContainableUserData)",
                bank_instance)
            for _, instance in ipairs(trigger_instances) do
                dispatcher:call(
                    "loadContainableUserData(soundlib.SoundContainableUserData)",
                    instance)
            end
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
    for _, entry in ipairs(manifest.events) do
        local bucket = A.categories[entry.category]
        if not bucket then
            bucket = {}
            A.categories[entry.category] = bucket
        end
        bucket[#bucket + 1] = {name = entry.name, event_id = entry.event_id}
    end
    A.registration = {
        dispatcher = dispatcher,
        dispatcher_address = address,
        bank_instance = bank_instance,
        trigger_instances = trigger_instances,
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
                    if not A.template_trigger then
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
local function ensure_vocal_ids(cat)
    if A.vocal_ids then return A.vocal_ids end
    local wwise = get_component(cat, "app.WwiseContainerApp")
    if not wwise then return nil end
    local found = {}
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
    if total == 0 then return nil end
    A.vocal_ids = found
    report("cat vocal catalogue: " .. tostring(total) .. " trigger ids")
    return found
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

-- The cat triggers are cloned from DOE voice data, so their authored
-- _OffsetJointHash names a doe skeleton joint that does not exist on the
-- wolf chassis — createRequestInfo returns nil for it. Create with the
-- authored joint first, then fall back to joint 0 (object root).
local function create_request(dispatcher, trigger, target, joint_hash)
    local request = nil
    local ok, err = pcall(function()
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

local function post_throttled()
    local now = os.clock()
    local last = tonumber(rawget(_G, "__iris_audio_last_post")) or 0
    if now - last < 0.03 then return true end
    rawset(_G, "__iris_audio_last_post", now)
    return false
end

local function post_request(dispatcher, trigger, target)
    if post_throttled() then return false, "post throttled" end
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
    local ok = pcall(function()
        request = request:add_ref()
        request["<Container>k__BackingField"] = dispatcher
        dispatcher:call("trigger(soundlib.SoundManager.RequestInfo)", request)
    end)
    return ok
end

local function post_via_template(dispatcher, event_id, target)
    if post_throttled() then return false, "post throttled" end
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
    local trigger = A.triggers_by_event[event_id]
    local direct_err = nil
    if trigger then
        local ok
        ok, direct_err = post_request(dispatcher, trigger, target)
        if ok then return true end
    end
    local template_ok, template_err = post_via_template(
        dispatcher, event_id, target)
    if template_ok then return true end
    -- Custom-loaded triggers can sour after repeated script resets while the
    -- NATIVE wolf trigger keeps working (the horse module survived resets the
    -- same way, via its native doe template). Force the native route once.
    if A.template_trigger and A.template_trigger ~= A.native_template then
        A.template_trigger = nil
        local native_ok, native_err = post_via_template(
            dispatcher, event_id, target)
        if native_ok then return true end
        template_err = tostring(template_err) .. " | native: "
            .. tostring(native_err)
    end
    return false, (direct_err and (tostring(direct_err) .. " | ") or "")
        .. "template: " .. tostring(template_err)
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
    local ok, err = post_event(entry.event_id, target)
    if ok then A.last_played = entry.name end
    return ok, err
end

-- ---------------------------------------------------------------------------
-- Vocal replacement router (vocals only — footsteps stay native wolf)
-- ---------------------------------------------------------------------------

local function registered_cat_ancestor(game_object)
    local current = game_object
    for _ = 1, 8 do
        if not valid(current) then return nil end
        local address = object_address(current)
        local record = address and REGISTRY[address]
        if record and (record.kind == "puma" or record.kind == "panther") then
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

local function cat_state_for(game_object)
    local address = object_address(game_object)
    return address and S.cats[tostring(address)] or nil
end

local trigger_method = sdk.find_type_definition("app.WwiseContainerApp")
    :get_method("trigger(soundlib.SoundManager.RequestInfo)")
local trigger_hook_installed = false
local function install_trigger_hook()
    if trigger_hook_installed or not trigger_method then return end
    trigger_hook_installed = true
    sdk.hook(trigger_method, function(args)
        if S.generation ~= GENERATION then return end
        if not (C.enabled and C.replace_wolf_vocals) then return end
        local container, request = nil, nil
        pcall(function() container = sdk.to_managed_object(args[2]) end)
        pcall(function() request = sdk.to_managed_object(args[3]) end)
        if not container or not request then return end
        local owner = nil
        pcall(function() owner = container:call("get_GameObject") end)
        local cat = registered_cat_ancestor(owner)
        if not cat then return end
        local trigger_id = 0
        pcall(function()
            trigger_id = normal_u32(request:call("get_TriggerId")) or 0
        end)
        local vocal_ids = ensure_vocal_ids(cat)
        if not (vocal_ids and vocal_ids[trigger_id]) then return end

        local state = cat_state_for(cat)
        if state and state.death_played then
            return sdk.PreHookResult.SKIP_ORIGINAL
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
    if state.frame % 30 == 0 then refresh_cats() end
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
