-- IRIS domestic companion controller for DD2.
-- Owns the house-cat/dog prototype lifecycle, relationships, following,
-- commands and pickup experiments. Wild animals remain in IrisWildCats.

local MOD = "IrisPets"

local ok_spawn, SpawnRequest = pcall(require, "EnemySpawner/spawnRequest")

local PETS = {
    { code = "ch223000_00", name = "Wolf" },
    { code = "ch223001_00", name = "Redwolf A" },
    { code = "ch223001_01", name = "Redwolf B" },
    { code = "ch260001_00", name = "Warg" },
    { code = "ch260000_00", name = "Garm" },
    -- Dedicated resource, assigned only to this spawned body.  The prefab and
    -- ordinary pumas/panthers remain untouched.
    { code = "ch299200_A_00", name = "IRIS House Cat (rabbit host prototype)",
      housecat = true, scale = 1.0, puppet_walk = 100, puppet_jog = 200,
      puppet_run = 200, puppet_idle = 0 },
}

local HOUSECAT_MESH = "character/ch/iris_housecat/iris_housecat.mesh"
local HOUSECAT_WARM_GATE = 15.0

local DEFAULT = {
    enabled = true,
    selected_pet = 1,
    spawn_distance = 2.6,
    spawn_scale = 1.0,
    spawn_idle = true,
    friendly_to_party = true,
    friendly_to_npcs = true,
    hostile_to_enemies = true,
    follow_mode = "off", -- off | nav | native | puppet | warp
    follow_distance = 3.6,
    leash_distance = 18.0,
    follow_interval = 0.35,
    native_tick_seconds = 1.0,
    attack_radius = 45.0,
    hate_amount = 100.0,
    attack_hold_seconds = 20.0,
    passive_until_attack = true,
    guard_party_hate = true,
    block_party_hate = true,
    return_after_attack = true,
    stay_inert = true,
    stay_disable_ai = true,
    stay_lie_down = false,
    stay_lock_position = true,
    stay_lock_radius = 0.08,
    stay_idle_motion = 0,
    stay_idle_tick_seconds = 2.0,
    stay_after_pickup = true,
    stay_warp_fallback = false,
    lie_bank = 0,
    lie_start_motion = 87,
    lie_loop_motion = 88,
    lie_inert_delay_frames = 70,
    lie_action_node = "Ch223_LiedownStart",
    puppet_tick_seconds = 0.12,
    puppet_bank = 0,
    puppet_idle = 0,
    puppet_idle_sequence = "0",
    puppet_idle_tick_seconds = 2.0,
    puppet_settle_lock_position = true,
    puppet_settle_lock_radius = 0.15,
    puppet_release_ai_on_settle = false,
    puppet_rescue_enabled = true,
    puppet_rescue_distance = 14.0,
    puppet_rescue_stuck_enabled = false,
    puppet_rescue_seconds = 3.0,
    puppet_rescue_cooldown_seconds = 6.0,
    puppet_rescue_vertical = 2.2,
    puppet_rescue_min_progress = 0.2,
    puppet_walk = 200,
    puppet_jog = 300,
    puppet_run = 300,
    puppet_stop_radius = 0.8,
    puppet_jog_distance = 6.0,
    puppet_run_distance = 10.0,
    audition_bank = 0,
    audition_motion = 0,
    audition_step = 1,
    audition_disable_ai = true,
    audition_lock_position = true,
    pickup_window_seconds = 4.0,
    pickup_range = 2.2,
    pickup_lock_position = true,
    unsafe_direct_pickup = false,
    housecat_carry_scale = 0.72,
    colour_id = 0,
    -- Never restore this from config. create_resource on an unmounted path can
    -- crash before Lua receives an error; arm only after installing the test PAK.
    housecat_mesh_armed = false,
}

local function merge_config(dst, src)
    if type(src) ~= "table" then return dst end
    for k, v in pairs(src) do
        if type(DEFAULT[k]) == type(v) then dst[k] = v end
    end
    return dst
end

local C = merge_config(merge_config({}, DEFAULT), json.load_file(MOD .. ".json"))
-- Safety latch is session-only even if an older/dev config happened to save it.
C.housecat_mesh_armed = false

local S = {
    spawner = nil,
    pet = nil,
    pet_go = nil,
    pet_name = "(none)",
    last_status = "not started",
    relation_hits = 0,
    friend_hits = 0,
    hostile_hits = 0,
    last_follow_clock = 0,
    pending_spawn = false,
    stay_pos = nil,
    stay_rot = nil,
    last_attack = "(none)",
    attack_hold = nil,
    disabled = {},
    inert = false,
    puppet_last = -1,
    puppet_settle = nil,
    puppet_idle_index = 0,
    puppet_idle_next_clock = 0,
    puppet_stuck = nil,
    puppet_rescue_next_clock = 0,
    pickup_until_clock = 0,
    pickup_last = "(none)",
    pickup_pos = nil,
    pickup_rot = nil,
    was_carried = false,
    audition_on = false,
    audition_pos = nil,
    audition_rot = nil,
    stay_idle_next_clock = 0,
    root_test = nil,
    lie_hold = nil,
    frame = 0,
    last_hate_guard_clock = 0,
    native_call_style = nil,
    native_last = "(none)",
    housecat_res = nil,
    housecat_warm_at = nil,
    housecat_status = "disarmed",
    housecat_orig_mesh = nil,
    housecat_applied = false,
    housecat_spawn_prefab = nil,
    housecat_spawn_ctrl = nil,
    housecat_ground_scale = nil,
    housecat_carry_scaled = false,
}

local pets = {}
local restore_disabled
local clear_pet_hate
local read_field
local native_request_command
local calm_pet
local reacquire_pet
local start_pickup_window
local pickup_window_active
local pickup_pet_now
local return_to_player

local REL_NEUTRAL = sdk.to_ptr(0)
local REL_HOSTILE = sdk.to_ptr(1)
local REL_FRIEND = sdk.to_ptr(2)

local CMD_NONE = 0
local CMD_ATTACK = 1
local CMD_KEEP_OBSERVE = 2
local CMD_FOLLOW = 3

local function save_config()
    json.dump_file(MOD .. ".json", C)
end

local function status(msg)
    S.last_status = tostring(msg)
    log.info("[" .. MOD .. "] " .. S.last_status)
end

local function singleton(name)
    local obj = nil
    pcall(function() obj = sdk.get_managed_singleton(name) end)
    return obj
end

local function type_def(name)
    local td = nil
    pcall(function() td = sdk.find_type_definition(name) end)
    return td
end

local function type_name(obj)
    local name = "?"
    pcall(function()
        local td = obj and obj:get_type_definition()
        if td then name = td:get_full_name() end
    end)
    return tostring(name)
end

local function method_signature(method)
    if not method then return "?" end
    local name = "?"
    pcall(function() name = method:get_name() or "?" end)

    local params = {}
    pcall(function()
        for _, param_type in ipairs(method:get_param_types() or {}) do
            params[#params + 1] = param_type:get_full_name()
        end
    end)

    local ret = "?"
    pcall(function()
        local rt = method:get_return_type()
        if rt then ret = rt:get_full_name() end
    end)

    return tostring(name) .. "(" .. table.concat(params, ", ") .. ") -> " .. tostring(ret)
end

local function get_component(go, typename)
    if not go then return nil end
    local comp = nil
    pcall(function()
        local td = type_def(typename)
        if td then comp = go:call("getComponent(System.Type)", td:get_runtime_type()) end
    end)
    return comp
end

local function housecat_pin_mesh()
    if not C.housecat_mesh_armed then S.housecat_status = "disarmed"; return false end
    if S.housecat_res then return true end
    -- Deliberately not attempted until the user arms it after installing the PAK.
    local res = sdk.create_resource("via.render.MeshResource", HOUSECAT_MESH)
    if not res then
        S.housecat_status = "mesh resource NIL -- install w3_housecat_pak.pak"
        return false
    end
    res:add_ref()
    S.housecat_res, S.housecat_warm_at = res, os.clock()
    S.housecat_status = "mesh pinned; streaming for 15 seconds"
    status(S.housecat_status)
    return true
end

local function housecat_fresh_holder()
    if not housecat_pin_mesh() then return nil, S.housecat_status end
    local age = os.clock() - (S.housecat_warm_at or 0)
    if age < HOUSECAT_WARM_GATE then
        S.housecat_status = string.format("streaming %.0f / %.0f seconds", age, HOUSECAT_WARM_GATE)
        return nil, S.housecat_status
    end
    local holder = nil
    pcall(function()
        holder = S.housecat_res:create_holder("via.render.MeshResourceHolder")
        if holder then holder:add_ref() end
    end)
    if not holder then return nil, "fresh mesh holder failed" end
    return holder
end

local function housecat_apply_mesh()
    local spec = PETS[C.selected_pet] or PETS[1]
    if not spec.housecat then return true end
    local _, go = reacquire_pet()
    if not go then return false, "spawned house-cat body not ready" end
    local holder, why = housecat_fresh_holder()
    if not holder then return false, why end
    local mesh = get_component(go, "via.render.Mesh")
    if not mesh then return false, "house-cat body has no via.render.Mesh" end
    if not S.housecat_orig_mesh then
        pcall(function()
            S.housecat_orig_mesh = mesh:call("getMesh")
            if S.housecat_orig_mesh then S.housecat_orig_mesh:add_ref() end
        end)
    end
    pcall(function() mesh:call("set_Enabled", false) end)
    local ok, err = pcall(function() mesh:call("setMesh", holder) end)
    if not ok then ok, err = pcall(function() mesh:call("set_Mesh", holder) end) end
    pcall(function() mesh:call("set_Enabled", true) end)
    if not ok then
        if S.housecat_orig_mesh then
            pcall(function() mesh:call("setMesh", S.housecat_orig_mesh) end)
        end
        return false, "setMesh failed: " .. tostring(err)
    end
    S.housecat_applied = true
    S.housecat_status = "custom Witcher cat mesh applied to this pet only"
    status(S.housecat_status)
    return true
end

local function char_go(ch)
    local go = nil
    pcall(function() go = ch and ch:call("get_GameObject") end)
    return go
end

local function go_name(go)
    local name = nil
    pcall(function() name = go and go:call("get_Name") end)
    return tostring(name or "")
end

local function char_name(ch)
    return go_name(char_go(ch))
end

local function transform_pos(go)
    local pos = nil
    pcall(function() pos = go and go:call("get_Transform"):call("get_UniversalPosition") end)
    return pos
end

local function transform_rot(go)
    local rot = nil
    pcall(function() rot = go and go:call("get_Transform"):call("get_Rotation") end)
    return rot
end

local function make_position(x, y, z)
    local p = ValueType.new(sdk.find_type_definition("via.Position"))
    p.x = x or 0
    p.y = y or 0
    p.z = z or 0
    return p
end

local function pos_tuple(p)
    if not p then return nil end
    return { x = tonumber(p.x) or 0, y = tonumber(p.y) or 0, z = tonumber(p.z) or 0 }
end

local function rot_tuple(q)
    if not q then return nil end
    return {
        x = tonumber(q.x) or 0,
        y = tonumber(q.y) or 0,
        z = tonumber(q.z) or 0,
        w = tonumber(q.w) or 1,
    }
end

local function make_quat(t)
    if not t then return nil end
    local q = ValueType.new(sdk.find_type_definition("via.Quaternion"))
    q.x = t.x or 0
    q.y = t.y or 0
    q.z = t.z or 0
    q.w = t.w or 1
    return q
end

local function distance_sq(a, b)
    if not (a and b) then return nil end
    local dx = (tonumber(a.x) or 0) - (tonumber(b.x) or 0)
    local dy = (tonumber(a.y) or 0) - (tonumber(b.y) or 0)
    local dz = (tonumber(a.z) or 0) - (tonumber(b.z) or 0)
    return dx * dx + dy * dy + dz * dz
end

local function addr(obj)
    local a = nil
    pcall(function() a = obj and obj:get_address() end)
    return a
end

local function same_obj(a, b)
    if not (a and b) then return false end
    local aa, bb = addr(a), addr(b)
    return aa ~= nil and bb ~= nil and aa == bb
end

local function list_count(list)
    local n = nil
    pcall(function() n = list and list:call("get_Count") end)
    if type(n) ~= "number" then pcall(function() n = list and list:get_Count() end) end
    if type(n) ~= "number" then pcall(function() n = list and list:get_size() end) end
    return tonumber(n) or 0
end

local function list_get(list, i)
    local item = nil
    pcall(function() item = list and list:call("get_Item", i) end)
    if item == nil then pcall(function() item = list and list[i] end) end
    return item
end

local function pawn_cached_character(pawn)
    local ch = nil
    if pawn then
        pcall(function() ch = pawn:call("get_CachedCharacter") end)
        if not ch then pcall(function() ch = pawn:get_field("<CachedCharacter>k__BackingField") end) end
    end
    return ch
end

local function get_player()
    local cm = singleton("app.CharacterManager")
    local p = nil
    pcall(function() p = cm and cm:call("get_ManualPlayer") end)
    return p
end

local function player_catch_processor()
    local p = get_player()
    local h = nil
    pcall(function() h = p and p:call("get_Human") end)
    if not h and p then pcall(function() h = p:get_field("<Human>k__BackingField") end) end
    local hcp = nil
    pcall(function() hcp = h and h:call("get_CatchProcessor") end)
    if not hcp and h then pcall(function() hcp = h:get_field("<CatchProcessor>k__BackingField") end) end
    return hcp
end

local function character_catch_active(ch)
    local active = false
    pcall(function()
        local cc = ch and ch:call("get_CatchController")
        active = cc and cc:call("get_IsActive") == true
    end)
    if active then return true end
    pcall(function()
        local cc = ch and ch:get_field("<CatchController>k__BackingField")
        active = cc and cc:call("get_IsActive") == true
    end)
    return active == true
end

local function player_carrying()
    return character_catch_active(get_player())
end

local function pet_caught()
    return character_catch_active(select(1, reacquire_pet()))
end

local function player_front(distance, behind)
    local p = get_player()
    local pgo = char_go(p)
    if not pgo then return nil, nil end

    local pos, rot = nil, nil
    pcall(function()
        local tf = pgo:call("get_Transform")
        local pp = tf:call("get_UniversalPosition")
        local fwd = tf:call("get_AxisZ")
        rot = tf:call("get_Rotation")
        local sign = behind and -1 or 1
        pos = make_position(
            pp.x + sign * (fwd and fwd.x or 0) * (distance or 2.0),
            pp.y,
            pp.z + sign * (fwd and fwd.z or 0) * (distance or 2.0)
        )
    end)
    return pos, rot
end

local function player_radial_follow_target(pp, cp, distance)
    if not (pp and cp) then return nil end

    local dx = (tonumber(cp.x) or 0) - (tonumber(pp.x) or 0)
    local dz = (tonumber(cp.z) or 0) - (tonumber(pp.z) or 0)
    local len = math.sqrt(dx * dx + dz * dz)
    if len < 0.01 then
        return player_front(distance, true)
    end

    local radius = tonumber(distance) or 3.2
    return make_position(
        (tonumber(pp.x) or 0) + (dx / len) * radius,
        tonumber(pp.y) or 0,
        (tonumber(pp.z) or 0) + (dz / len) * radius
    )
end

local function is_pet(ch)
    return ch ~= nil and pets[ch] == true
end

local function is_dead(ch)
    local dead = false
    pcall(function() dead = ch and ch:call("get_IsDead") == true end)
    if dead then return true end
    pcall(function()
        local hp = ch and ch:call("get_Hp")
        if hp ~= nil and tonumber(hp) <= 0 then dead = true end
    end)
    return dead
end

local function is_player_or_party(ch)
    if not ch then return false end
    local p = get_player()
    if same_obj(ch, p) then return true end

    local ok = false
    pcall(function()
        local human = ch and ch:get_field("<Human>k__BackingField")
        ok = human and human:call("isPlayerOrPartyPawn") == true
    end)
    if ok == true then return true end

    local pm = singleton("app.PawnManager")
    if not pm then return false end

    local main_pawn = nil
    pcall(function() main_pawn = pm:call("get_MainPawn") end)
    if same_obj(ch, pawn_cached_character(main_pawn)) then return true end

    for _, getter in ipairs({ "get_PawnCharacterList", "get_AlivePawnCharacterList" }) do
        local list = nil
        pcall(function() list = pm:call(getter) end)
        local n = list_count(list)
        for i = 0, n - 1 do
            if same_obj(ch, list_get(list, i)) then return true end
        end
    end

    local party = nil
    pcall(function() party = pm:call("get_PartyPawnList") end)
    local n = list_count(party)
    for i = 0, n - 1 do
        local entry = list_get(party, i)
        if same_obj(ch, entry) or same_obj(ch, pawn_cached_character(entry)) then return true end
    end

    return false
end

local function is_player_or_party_go(go)
    if not go then return false end

    local pgo = char_go(get_player())
    if same_obj(go, pgo) then return true end

    local ch = nil
    pcall(function() ch = go:call("getComponent(System.Type)", sdk.typeof("app.Character")) end)
    return is_player_or_party(ch)
end

local function is_friendly_to_pet(ch)
    if not ch then return false end
    if is_pet(ch) then return true end
    if C.friendly_to_party and is_player_or_party(ch) then return true end
    if C.friendly_to_npcs then
        local prefix = char_name(ch):sub(1, 3)
        if prefix == "ch3" then return true end
    end
    return false
end

local function is_enemy_target(ch)
    if not ch or is_pet(ch) or is_dead(ch) then return false end
    local prefix = char_name(ch):sub(1, 3)
    if prefix ~= "ch2" then return false end
    local ec = nil
    pcall(function() ec = ch.EnemyCtrl or ch:get_field("EnemyCtrl") end)
    return ec ~= nil
end

local function register_pet(ch)
    if not ch then return false end
    pets = {}
    pets[ch] = true
    S.pet = ch
    S.pet_go = char_go(ch)
    S.pet_name = char_name(ch)
    S.relation_hits = 0
    S.friend_hits = 0
    S.hostile_hits = 0
    S.attack_hold = nil
    S.lie_hold = nil
    S.native_last = "(none)"
    if C.passive_until_attack then
        pcall(clear_pet_hate)
    end
    pcall(calm_pet, false, "register")
    status("registered pet " .. S.pet_name)
    return true
end

reacquire_pet = function()
    if S.pet and char_go(S.pet) then
        S.pet_go = char_go(S.pet)
        return S.pet, S.pet_go
    end

    if S.spawner and S.spawner.instances then
        for i = #S.spawner.instances, 1, -1 do
            local inst = S.spawner.instances[i]
            local ch = nil
            pcall(function() ch = inst.instance and inst.instance:get_Chara() end)
            if ch and not is_dead(ch) then
                register_pet(ch)
                return S.pet, S.pet_go
            end
        end
    end
    return nil, nil
end

local function clear_pet()
    restore_disabled()
    pets = {}
    S.pet = nil
    S.pet_go = nil
    S.pet_name = "(none)"
    S.stay_pos = nil
    S.stay_rot = nil
    S.last_attack = "(none)"
    S.attack_hold = nil
    S.root_test = nil
    S.lie_hold = nil
    S.inert = false
    S.puppet_last = -1
    S.puppet_settle = nil
    S.puppet_idle_next_clock = 0
    S.puppet_stuck = nil
    S.puppet_rescue_next_clock = 0
    S.pickup_until_clock = 0
    S.pickup_pos = nil
    S.pickup_rot = nil
    S.was_carried = false
    S.housecat_ground_scale = nil
    S.housecat_carry_scaled = false
    S.audition_on = false
    S.audition_pos = nil
    S.audition_rot = nil
    S.stay_idle_next_clock = 0
    S.housecat_orig_mesh = nil
    S.housecat_applied = false
    if S.housecat_spawn_ctrl then pcall(function() S.housecat_spawn_ctrl:release() end) end
    if S.housecat_spawn_prefab then pcall(function() S.housecat_spawn_prefab:release() end) end
    S.housecat_spawn_ctrl = nil
    S.housecat_spawn_prefab = nil
end

-- EnemySpawner only consults GenerateManager's ENEMY catalog, while rabbits
-- live in the wildlife catalog. Override this one SpawnRequest instance with
-- the rabbit's proven direct prefab; SpawnRequest still owns GenerateInfo,
-- lifecycle, post-processing and deletion exactly as before.
local function housecat_install_rabbit_prefab(spawner)
    if not spawner then return false, "no spawn request" end
    local prefab = sdk.create_instance("via.Prefab")
    if not prefab then return false, "via.Prefab creation failed" end
    prefab:add_ref()
    local path = "AppSystem/ch/ch299/Prefab/ch299200_A_00.pfb"
    local ok_path = pcall(function() prefab:call("set_Path", path) end)
    local exists = false
    pcall(function() exists = prefab:call("get_Exist") end)
    if not ok_path or not exists then
        pcall(function() prefab:release() end)
        return false, "rabbit prefab unavailable: " .. path
    end
    local ctrl = sdk.create_instance("app.PrefabController")
    if not ctrl then
        pcall(function() prefab:release() end)
        return false, "PrefabController creation failed"
    end
    ctrl:add_ref()
    local ok_ctrl = pcall(function() ctrl._Item = prefab end)
    if not ok_ctrl then ok_ctrl = pcall(function() ctrl:set_field("_Item", prefab) end) end
    if not ok_ctrl then
        pcall(function() ctrl:release() end)
        pcall(function() prefab:release() end)
        return false, "rabbit PrefabController assignment failed"
    end
    S.housecat_spawn_prefab = prefab
    S.housecat_spawn_ctrl = ctrl
    spawner.getPfbCtrl = function(_self, _char_id) return ctrl end
    return true, path
end

local function spawn_selected_pet()
    if not ok_spawn then
        status("EnemySpawner/spawnRequest could not be required")
        return
    end

    local spec = PETS[C.selected_pet] or PETS[1]
    if spec.housecat then
        status("house-cat spawn retired here; use Iris TAMING > House cat")
        return
    end
    local pos, rot = player_front(C.spawn_distance, false)
    if not pos then
        status("no player position; load into the world first")
        return
    end

    if S.spawner then
        pcall(function() S.spawner:deleteAll() end)
    end
    clear_pet()

    S.spawner = SpawnRequest:new()
    if spec.housecat then
        local prefab_ok, prefab_why = housecat_install_rabbit_prefab(S.spawner)
        if not prefab_ok then
            status("house-cat rabbit host failed: " .. tostring(prefab_why))
            S.spawner = nil
            return
        end
    end
    local spawn_cfg = {
        spawnIdle = C.spawn_idle == true,
        instLimit = 1,
        spawnMultiple = { enable = false, qty = 1 },
        ovrScale = {
            enable = (tonumber(spec.scale or C.spawn_scale) or 1.0) ~= 1.0,
            scale = tonumber(spec.scale or C.spawn_scale) or 1.0,
            normalizeSpeed = false,
        },
    }
    S.spawner:updateConfig(spawn_cfg)
    S.spawner:requestAddInstances(spec.code, pos, rot, spawn_cfg, 1)
    S.pending_spawn = true
    status("spawn requested: " .. spec.name .. " (" .. spec.code .. ")")
end

local function delete_pet()
    if S.spawner then
        pcall(function() S.spawner:deleteAll() end)
    end
    clear_pet()
    C.follow_mode = "off"
    status("pet deleted")
end

local function set_transform(go, pos, rot)
    if not (go and pos) then return false, "no object/position" end
    local ok, err = pcall(function()
        local tf = go:call("get_Transform")
        tf:call("set_UniversalPosition", pos)
        if rot then tf:call("set_Rotation", rot) end
    end)
    if ok then return true, "Transform.set" end
    return false, tostring(err)
end

local function warp_pet_to(pos, rot)
    local ch, go = reacquire_pet()
    if not (ch and go and pos) then return false, "no pet/position" end
    return set_transform(go, pos, rot)
end

local function pet_hate_system()
    local ch, go = reacquire_pet()
    local hs = nil
    pcall(function() hs = ch and ch:call("get_HateSystem") end)
    if not hs then hs = get_component(go, "app.HateSystem") end
    return hs
end

clear_pet_hate = function()
    local hs = pet_hate_system()
    local ok = false
    if hs then ok = pcall(function() hs:call("clearAllHate") end) end
    return ok
end

local function set_enabled(obj, enabled)
    if not obj then return false end
    local ok = pcall(function() obj:call("set_Enabled", enabled) end)
    if not ok then ok = pcall(function() obj:call("set_Enabled(System.Boolean)", enabled) end) end
    return ok
end

local function disable_record(obj, label)
    if not obj or S.disabled[obj] then return false end
    local was = true
    pcall(function()
        local v = obj:call("get_Enabled")
        if type(v) == "boolean" then was = v end
    end)
    if set_enabled(obj, false) then
        S.disabled[obj] = { obj = obj, label = label or "?", was = was }
        return true
    end
    return false
end

restore_disabled = function()
    for obj, rec in pairs(S.disabled) do
        if rec and rec.was ~= false then set_enabled(obj, true) end
        S.disabled[obj] = nil
    end
end

local function set_think_stop(ch, enabled)
    if not ch then return false end
    local ok = false
    ok = pcall(function() ch:set_field("_IsThinkStop", enabled) end) or ok
    ok = pcall(function() ch:set_field("<IsThinkStop>k__BackingField", enabled) end) or ok
    ok = pcall(function() ch:call("set_IsThinkStop(System.Boolean)", enabled) end) or ok
    ok = pcall(function() ch:call("set_IsThinkStop", enabled) end) or ok
    return ok
end

local function get_nav_ai(ch)
    local nav = nil
    pcall(function() nav = ch and ch:get_field("<NavigationAI>k__BackingField") end)
    if not nav then pcall(function() nav = ch and ch:call("get_NavigationAI") end) end
    if not nav then nav = get_component(char_go(ch), "app.NavigationAI") end
    if not nav then
        local _, go = reacquire_pet()
        nav = get_component(go, "app.NavigationAI")
    end
    return nav
end

local function stop_pet_navigation(stop)
    local ch = reacquire_pet()
    local nav = get_nav_ai(ch)
    local ok = false
    if nav then
        ok = pcall(function() nav:call("set_IsStopCalled", stop == true) end)
            or pcall(function() nav:set_field("IsStopCalled", stop == true) end)
    end
    return ok
end

local function set_pet_ai_disabled(disabled)
    local ch, go = reacquire_pet()
    if disabled then
        if not go then return 0 end
        local count = 0
        for _, typename in ipairs({ "app.AIDecisionMaker", "app.NavigationAI" }) do
            local comp = get_component(go, typename)
            if disable_record(comp, typename) then count = count + 1 end
        end
        return count
    end

    restore_disabled()
    if ch then
        set_think_stop(ch, false)
        pcall(function() ch:call("resetActionAndAI") end)
    end
    stop_pet_navigation(false)
    return 0
end

local function clear_pet_targets()
    local _, go = reacquire_pet()
    if not go then return false end
    local ok_any = false

    local lock_on = get_component(go, "app.LockOnTarget")
    if lock_on then
        ok_any = pcall(function() lock_on:set_field("TargetData", nil) end) or ok_any
    end

    local target_info = get_component(go, "app.AIActionTargetInfoController")
    if target_info then
        local instances = nil
        pcall(function() instances = target_info:get_field("<TargetInstances>k__BackingField") end)
        if instances then ok_any = pcall(function() instances:call("Clear") end) or ok_any end

        local general_points = nil
        pcall(function() general_points = target_info:get_field("<AITargetGeneralPoints>k__BackingField") end)
        if general_points then ok_any = pcall(function() general_points:call("Clear") end) or ok_any end
    end

    local bb = get_component(go, "app.AIBlackBoardController")
    if bb then
        ok_any = pcall(function() bb:call("clearEnemyTargetList") end) or ok_any
        ok_any = pcall(function() bb:call("updateEnemyTargetList") end) or ok_any
    end

    return ok_any
end

calm_pet = function(restore_ai, label)
    local ch = reacquire_pet()
    if not ch then status("no pet to calm"); return false end

    S.attack_hold = nil
    S.lie_hold = nil
    S.puppet_settle = nil
    clear_pet_hate()
    clear_pet_targets()
    stop_pet_navigation(true)
    if restore_ai ~= false then
        set_pet_ai_disabled(false)
        pcall(function() ch:call("resetActionAndAI") end)
    end
    clear_pet_hate()
    S.native_last = "calmed"
    if label ~= false then status("pet calmed" .. (label and (" (" .. tostring(label) .. ")") or "")) end
    return true
end

local function set_pet_inert(enabled)
    local ch = reacquire_pet()
    if not ch then return false end
    S.inert = enabled == true
    if S.inert then
        clear_pet_hate()
        stop_pet_navigation(true)
        set_think_stop(ch, true)
        if C.stay_disable_ai then set_pet_ai_disabled(true) end
        return true
    end

    set_think_stop(ch, false)
    stop_pet_navigation(false)
    pcall(function() ch:call("resetActionAndAI") end)
    return true
end

local function pet_motion_layer()
    local ch = reacquire_pet()
    local layer = nil
    pcall(function() layer = ch and ch:call("get_Motion"):call("getLayer", 0) end)
    return layer
end

local function current_motion_ids()
    local layer = pet_motion_layer()
    if not layer then return nil, nil end
    local bank, mid = nil, nil
    pcall(function() bank = layer:call("get_MotionBankID") end)
    pcall(function() mid = layer:call("get_MotionID") end)
    return tonumber(bank), tonumber(mid)
end

local function current_motion_label()
    local bank, mid = current_motion_ids()
    if bank == nil or mid == nil then return "?" end
    return tostring(bank) .. ":" .. tostring(mid)
end

local function parse_motion_sequence(text, fallback)
    local seq = {}
    for raw in tostring(text or ""):gmatch("[^,%s]+") do
        local n = tonumber(raw)
        if n and n >= 0 then seq[#seq + 1] = math.floor(n) end
    end
    if #seq == 0 and fallback and fallback >= 0 then seq[1] = math.floor(fallback) end
    return seq
end

local function play_pet_motion(bank, motion_id)
    local layer = pet_motion_layer()
    if not layer then return false end
    return pcall(function()
        layer:call(
            "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
            bank, motion_id, 0.0, 6.0, 1, 1
        )
    end)
end

local function request_pet_action_node(node, priority, layer)
    local ch = reacquire_pet()
    if not (ch and node and node ~= "") then return false end
    local am = nil
    pcall(function() am = ch:get_field("<ActionManager>k__BackingField") end)
    if not am then pcall(function() am = ch:call("get_ActionManager") end) end
    if not am then return false end
    return pcall(function()
        am:call("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)",
            priority or 10, tostring(node), layer or 0)
    end)
end

local function prepare_manual_motion()
    local ch, go = reacquire_pet()
    if not (ch and go) then return false end
    C.follow_mode = "off"
    S.stay_pos = nil
    S.stay_rot = nil
    S.lie_hold = nil
    S.audition_on = true
    S.audition_pos = pos_tuple(transform_pos(go))
    S.audition_rot = rot_tuple(transform_rot(go))
    clear_pet_hate()
    clear_pet_targets()
    set_think_stop(ch, false)
    stop_pet_navigation(true)
    if C.audition_disable_ai then set_pet_ai_disabled(true) end
    save_config()
    return true
end

local function stop_audition()
    S.audition_on = false
    S.audition_pos = nil
    S.audition_rot = nil
    set_pet_ai_disabled(false)
    stop_pet_navigation(false)
    status("audition stopped")
end

local function audition_tick()
    if not S.audition_on then return end
    local ch, go = reacquire_pet()
    if not (ch and go) then S.audition_on = false; return end

    clear_pet_hate()
    stop_pet_navigation(true)
    if C.audition_disable_ai then set_pet_ai_disabled(true) end

    if C.audition_lock_position and S.audition_pos then
        local cp = transform_pos(go)
        local anchor = make_position(S.audition_pos.x, S.audition_pos.y, S.audition_pos.z)
        local drift_d2 = distance_sq(cp, anchor) or 0
        if drift_d2 > 0.0025 then
            set_transform(go, anchor, make_quat(S.audition_rot))
        end
    end
end

local function audition_motion(delta)
    delta = tonumber(delta) or 0
    if delta ~= 0 then
        local step = math.max(1, math.floor(tonumber(C.audition_step) or 1))
        C.audition_motion = math.max(0, math.floor((tonumber(C.audition_motion) or 0) + delta * step))
    end

    prepare_manual_motion()
    local ok = play_pet_motion(C.audition_bank, C.audition_motion)
    save_config()
    status("audition motion " .. tostring(C.audition_bank) .. ":" .. tostring(C.audition_motion) .. " ok=" .. tostring(ok))
end

local function capture_current_motion(kind)
    local bank, mid = current_motion_ids()
    if not (bank and mid) then status("no current motion to capture"); return end

    if kind == "idle" then
        C.puppet_bank = bank
        C.puppet_idle = mid
        C.puppet_idle_sequence = tostring(mid)
    elseif kind == "lie_start" then
        C.lie_bank = bank
        C.lie_start_motion = mid
    elseif kind == "lie_loop" then
        C.lie_bank = bank
        C.lie_loop_motion = mid
    elseif kind == "audition" then
        C.audition_bank = bank
        C.audition_motion = mid
    end

    save_config()
    status("captured current motion as " .. tostring(kind) .. ": " .. tostring(bank) .. ":" .. tostring(mid))
end

local function play_puppet_settle_idle(force)
    local now = os.clock()
    if not force and now < (S.puppet_idle_next_clock or 0) then return false end

    local spec = PETS[C.selected_pet] or PETS[1]
    local spec_idle = spec.housecat and spec.puppet_idle or nil
    local seq = spec_idle ~= nil and { tonumber(spec_idle) or 0 }
        or parse_motion_sequence(C.puppet_idle_sequence, tonumber(C.puppet_idle) or 0)
    if #seq == 0 then return false end

    S.puppet_idle_index = ((S.puppet_idle_index or 0) % #seq) + 1
    local motion_id = seq[S.puppet_idle_index]
    set_think_stop(reacquire_pet(), false)
    local bank = (spec.housecat and tonumber(spec.puppet_bank)) or tonumber(C.puppet_bank) or 0
    local ok = play_pet_motion(bank, motion_id)
    S.puppet_idle_next_clock = now + math.max(0.25, tonumber(C.puppet_idle_tick_seconds) or 2.0)
    S.puppet_last = -1
    return ok, motion_id
end

local function start_lie_down_stay()
    local ch, go = reacquire_pet()
    if not (ch and go) then status("no pet to lie/stay"); return false end

    S.stay_pos = pos_tuple(transform_pos(go))
    S.stay_rot = rot_tuple(transform_rot(go))
    C.follow_mode = "off"
    S.attack_hold = nil
    S.lie_hold = {
        until_frame = S.frame + math.max(1, math.floor(tonumber(C.lie_inert_delay_frames) or 70)),
        loop_motion = math.floor(tonumber(C.lie_loop_motion) or 88),
        done = false,
    }

    clear_pet_hate()
    clear_pet_targets()
    set_think_stop(ch, false)
    set_pet_ai_disabled(true)
    stop_pet_navigation(true)
    local ok = play_pet_motion(C.lie_bank, C.lie_start_motion)
    status("lie-down stay start motion=" .. tostring(C.lie_start_motion) .. " ok=" .. tostring(ok))
    return ok
end

local function lie_hold_tick()
    local hold = S.lie_hold
    if not hold or hold.done then return end
    if S.frame < (hold.until_frame or 0) then return end

    play_pet_motion(C.lie_bank, hold.loop_motion)
    hold.done = true
    set_pet_inert(true)
    S.last_status = "lie-down stay loop motion=" .. tostring(hold.loop_motion) .. " inert"
end

local function start_root_motion_test(motion_id)
    local _, go = reacquire_pet()
    if not go then status("no pet for root-motion test"); return end
    S.root_test = {
        start = pos_tuple(transform_pos(go)),
        motion_id = motion_id or C.puppet_run,
        until_frame = S.frame + 150,
        moved = 0.0,
    }
    set_pet_ai_disabled(true)
    stop_pet_navigation(true)
    clear_pet_hate()
    play_pet_motion(C.puppet_bank, S.root_test.motion_id)
    status("root-motion test started clip=" .. tostring(S.root_test.motion_id))
end

local function stop_root_motion_test()
    S.root_test = nil
    set_pet_ai_disabled(false)
    status("root-motion test stopped")
end

local function root_motion_test_tick()
    local rt = S.root_test
    if not rt then return end
    local _, go = reacquire_pet()
    if not go then S.root_test = nil; return end
    if (S.frame % 20) == 0 then play_pet_motion(C.puppet_bank, rt.motion_id) end
    local now = transform_pos(go)
    if now and rt.start then
        local d2 = distance_sq(now, rt.start)
        rt.moved = d2 and math.sqrt(d2) or rt.moved
    end
    if S.frame >= (rt.until_frame or 0) then
        local moved = rt.moved or 0.0
        S.root_test = nil
        set_pet_ai_disabled(false)
        status(string.format("root-motion clip %d moved %.2fm / 150f", rt.motion_id, moved))
    end
end

local function face_pet_towards(dx, dz)
    local _, go = reacquire_pet()
    if not go then return false end
    if (dx * dx + dz * dz) < 0.001 then return false end
    local yaw = math.atan(dx, dz)
    return pcall(function()
        local q = ValueType.new(sdk.find_type_definition("via.Quaternion"))
        q.x = 0
        q.y = math.sin(yaw / 2.0)
        q.z = 0
        q.w = math.cos(yaw / 2.0)
        go:call("get_Transform"):call("set_Rotation", q)
    end)
end

local function nav_request_to_player(ch)
    local p = get_player()
    local pgo = char_go(p)
    if not (ch and pgo) then return false end
    local nav = get_nav_ai(ch)
    if not nav then return false end
    pcall(function() nav:call("set_IsStopCalled", false) end)
    return pcall(function() nav:call("navigationRequest(via.GameObject)", pgo) end)
end

local function set_follow_mode(mode)
    mode = mode or "off"
    S.stay_pos = nil
    S.stay_rot = nil
    S.puppet_last = -1
    S.puppet_settle = nil
    S.puppet_idle_next_clock = 0
    S.puppet_stuck = nil
    set_pet_inert(false)
    set_pet_ai_disabled(false)
    C.follow_mode = mode

    if mode == "puppet" then
        set_pet_ai_disabled(true)
        stop_pet_navigation(true)
    elseif mode == "native" then
        stop_pet_navigation(false)
        pcall(function() native_request_command(CMD_FOLLOW, get_player()) end)
    elseif mode == "nav" then
        stop_pet_navigation(false)
    elseif mode == "warp" then
        stop_pet_navigation(false)
    end

    save_config()
    status("follow " .. mode)
end

local function puppet_rescue_check(cp, target, target_dist)
    if not C.puppet_rescue_enabled then return false end
    local now = os.clock()
    if now < (S.puppet_rescue_next_clock or 0) then return false end
    if pickup_window_active() or player_carrying() or pet_caught() then
        S.puppet_stuck = nil
        return false
    end

    local stop_radius = tonumber(C.puppet_stop_radius) or 0.8
    local rescue_distance = tonumber(C.puppet_rescue_distance) or 8.0
    local rescue_vertical = tonumber(C.puppet_rescue_vertical) or 1.2
    local rescue_seconds = tonumber(C.puppet_rescue_seconds) or 1.4
    local min_progress = tonumber(C.puppet_rescue_min_progress) or 0.2
    local vertical = math.abs((tonumber(cp.y) or 0) - (tonumber(target.y) or 0))
    local reason = nil

    if target_dist > rescue_distance then
        reason = string.format("distance %.1f", target_dist)
    elseif target_dist > (stop_radius + 0.6) and vertical > rescue_vertical then
        reason = string.format("vertical %.1f", vertical)
    else
        if C.puppet_rescue_stuck_enabled then
            local st = S.puppet_stuck
            if not st then
                S.puppet_stuck = { best = target_dist, since = now }
            elseif target_dist < ((tonumber(st.best) or target_dist) - min_progress) then
                st.best = target_dist
                st.since = now
            elseif target_dist > (stop_radius + 0.6) and (now - (tonumber(st.since) or now)) > rescue_seconds then
                reason = string.format("stuck %.1fs", now - (tonumber(st.since) or now))
            end
        end
    end

    if not reason then return false end
    S.puppet_stuck = nil
    S.puppet_rescue_next_clock = now + math.max(1.0, tonumber(C.puppet_rescue_cooldown_seconds) or 6.0)
    return_to_player()
    S.last_status = "puppet rescue: " .. reason
    return true
end

local function puppet_follow_tick(ch, go, pp, cp, dist)
    local follow_radius = tonumber(C.follow_distance) or 3.2
    local target, player_pos = player_radial_follow_target(pp, cp, follow_radius), pp
    if not target then return false end

    if player_carrying() or pet_caught() then
        set_pet_ai_disabled(false)
        S.puppet_settle = nil
        S.puppet_stuck = nil
        S.last_status = "puppet paused: carry active"
        return true
    end

    if pickup_window_active() then
        set_think_stop(ch, false)
        stop_pet_navigation(true)
        clear_pet_hate()
        S.puppet_settle = nil
        S.puppet_stuck = nil
        if C.pickup_lock_position and S.pickup_pos then
            local anchor = make_position(S.pickup_pos.x, S.pickup_pos.y, S.pickup_pos.z)
            local drift_d2 = distance_sq(cp, anchor) or 0
            if drift_d2 > 0.01 then
                set_transform(go, anchor, make_quat(S.pickup_rot))
            end
        end
        play_puppet_settle_idle(false)
        face_pet_towards(player_pos.x - cp.x, player_pos.z - cp.z)
        S.last_status = "puppet held for pickup"
        return true
    end

    local target_d2 = distance_sq(cp, target)
    local target_dist = target_d2 and math.sqrt(target_d2) or dist
    if dist <= follow_radius then target_dist = 0.0 end
    local stop_radius = tonumber(C.puppet_stop_radius) or 0.8

    if target_dist <= stop_radius then
        if C.puppet_release_ai_on_settle then
            set_pet_ai_disabled(false)
        else
            set_pet_ai_disabled(true)
        end
        stop_pet_navigation(true)
        if not S.attack_hold then clear_pet_hate() end
        S.puppet_stuck = nil

        if not S.puppet_settle then
            S.puppet_settle = {
                pos = pos_tuple(cp),
                entered_clock = os.clock(),
            }
            S.puppet_idle_next_clock = 0
        end

        local idle_ok, idle_motion = play_puppet_settle_idle(S.puppet_last ~= -1)
        face_pet_towards(player_pos.x - cp.x, player_pos.z - cp.z)

        if C.puppet_settle_lock_position and S.puppet_settle.pos then
            local anchor = make_position(S.puppet_settle.pos.x, S.puppet_settle.pos.y, S.puppet_settle.pos.z)
            local drift_d2 = distance_sq(cp, anchor) or 0
            local lock_radius = tonumber(C.puppet_settle_lock_radius) or 0.15
            if drift_d2 > (lock_radius * lock_radius) then
                set_transform(go, anchor, nil)
            end
        end

        S.last_status = string.format(
            "puppet settle player=%.1f target=%.1f idle=%s/%s motion=%s",
            dist,
            target_dist,
            tostring(idle_ok),
            tostring(idle_motion or "-"),
            current_motion_label()
        )
        return true
    end

    S.puppet_settle = nil
    S.puppet_idle_next_clock = 0
    set_think_stop(ch, false)
    set_pet_ai_disabled(true)
    stop_pet_navigation(true)
    if not S.attack_hold then clear_pet_hate() end

    if puppet_rescue_check(cp, target, target_dist) then return true end

    local dx = target.x - cp.x
    local dz = target.z - cp.z
    face_pet_towards(dx, dz)

    local spec = PETS[C.selected_pet] or PETS[1]
    local bank = (spec.housecat and tonumber(spec.puppet_bank)) or tonumber(C.puppet_bank) or 0
    local want = (spec.housecat and tonumber(spec.puppet_walk)) or C.puppet_walk
    if target_dist > C.puppet_run_distance then
        want = (spec.housecat and tonumber(spec.puppet_run)) or C.puppet_run
    elseif target_dist > C.puppet_jog_distance then
        want = (spec.housecat and tonumber(spec.puppet_jog)) or C.puppet_jog
    end

    local cur = current_motion_label()
    local expected = tostring(bank) .. ":" .. tostring(want)
    if S.puppet_last ~= want or cur ~= expected then
        play_pet_motion(bank, want)
        S.puppet_last = want
    end

    S.last_status = string.format("puppet follow player=%.1f target=%.1f clip=%d motion=%s", dist, target_dist, want, current_motion_label())
    return true
end

local function follow_tick()
    if not C.enabled or C.follow_mode == "off" then return end
    if S.audition_on then return end
    if S.attack_hold then return end
    if S.stay_pos then return end
    local now = os.clock()
    local tick_seconds = tonumber(C.follow_interval) or 0.35
    if C.follow_mode == "puppet" then
        tick_seconds = tonumber(C.puppet_tick_seconds) or 0.12
    elseif C.follow_mode == "native" then
        tick_seconds = tonumber(C.native_tick_seconds) or 1.0
    end
    if now - (S.last_follow_clock or 0) < tick_seconds then return end
    S.last_follow_clock = now

    local ch, go = reacquire_pet()
    local p = get_player()
    local pgo = char_go(p)
    if not (ch and go and pgo) then return end

    local cp = transform_pos(go)
    local pp = transform_pos(pgo)
    local d2 = distance_sq(cp, pp)
    if not d2 then return end
    local dist = math.sqrt(d2)

    if C.follow_mode == "puppet" then
        puppet_follow_tick(ch, go, pp, cp, dist)
        return
    end

    if C.follow_mode == "native" then
        local ok = native_request_command(CMD_FOLLOW, p)
        S.last_status = string.format("native follow request d=%.1f ok=%s %s", dist, tostring(ok), tostring(S.native_last))
        return
    end

    if C.follow_mode == "nav" and dist > (C.follow_distance + 0.75) and dist < C.leash_distance then
        if nav_request_to_player(ch) then
            S.last_status = string.format("nav follow request d=%.1f", dist)
            return
        end
    end

    if dist > (C.follow_distance + 0.75) then
        local pos, rot = player_front(C.follow_distance, true)
        local ok, how = warp_pet_to(pos, rot)
        S.last_status = string.format("warp follow d=%.1f ok=%s via %s", dist, tostring(ok), tostring(how))
    end
end

local function stay_tick()
    if not (S.stay_pos and S.stay_rot) then return end
    if S.lie_hold and not S.lie_hold.done then return end
    local now = os.clock()
    if now - (S.last_follow_clock or 0) < 0.25 then return end
    S.last_follow_clock = now
    if C.stay_inert then
        set_pet_inert(true)
        if C.stay_lock_position then
            local _, go = reacquire_pet()
            local cp = transform_pos(go)
            local anchor = make_position(S.stay_pos.x, S.stay_pos.y, S.stay_pos.z)
            local drift_d2 = distance_sq(cp, anchor) or 0
            local lock_radius = tonumber(C.stay_lock_radius) or 0.08
            if drift_d2 > (lock_radius * lock_radius) then
                set_transform(go, anchor, make_quat(S.stay_rot))
            end
        end
        if now >= (S.stay_idle_next_clock or 0) and (tonumber(C.stay_idle_motion) or -1) >= 0 then
            play_pet_motion(C.puppet_bank, C.stay_idle_motion)
            S.stay_idle_next_clock = now + math.max(0.5, tonumber(C.stay_idle_tick_seconds) or 2.0)
        end
        S.last_status = "stay inert: locked/think-stop/navigation-stop asserted"
        return
    end
    if C.stay_warp_fallback then
        local ok, how = warp_pet_to(make_position(S.stay_pos.x, S.stay_pos.y, S.stay_pos.z), make_quat(S.stay_rot))
        S.last_status = "stay warp fallback ok=" .. tostring(ok) .. " via " .. tostring(how)
    end
end

local function start_stay()
    local _, go = reacquire_pet()
    if not go then status("no pet to stay"); return end
    if C.stay_lie_down then
        start_lie_down_stay()
        return
    end
    S.stay_pos = pos_tuple(transform_pos(go))
    S.stay_rot = rot_tuple(transform_rot(go))
    C.follow_mode = "off"
    S.attack_hold = nil
    S.audition_on = false
    S.stay_idle_next_clock = 0
    if C.stay_inert then set_pet_inert(true) end
    if (tonumber(C.stay_idle_motion) or -1) >= 0 then play_pet_motion(C.puppet_bank, C.stay_idle_motion) end
    status(C.stay_inert and "stay inert set" or "stay set")
end

local function stop_stay()
    S.stay_pos = nil
    S.stay_rot = nil
    S.lie_hold = nil
    S.stay_idle_next_clock = 0
    set_pet_inert(false)
    status("stay cleared")
end

return_to_player = function()
    local pos, rot = player_front(C.follow_distance, true)
    if not pos then status("no player position for return"); return end
    S.stay_pos = nil
    S.stay_rot = nil
    S.lie_hold = nil
    set_pet_inert(false)
    calm_pet(true, false)
    local ok, how = warp_pet_to(pos, rot)
    status("return to me ok=" .. tostring(ok) .. " via " .. tostring(how))
end

start_pickup_window = function()
    local _, go = reacquire_pet()
    S.pickup_until_clock = os.clock() + math.max(0.5, tonumber(C.pickup_window_seconds) or 4.0)
    S.pickup_pos = go and pos_tuple(transform_pos(go)) or nil
    S.pickup_rot = go and rot_tuple(transform_rot(go)) or nil
    S.puppet_settle = nil
    S.puppet_stuck = nil
    set_pet_ai_disabled(false)
    stop_pet_navigation(true)
    clear_pet_hate()
    if (tonumber(C.puppet_idle) or -1) >= 0 then play_pet_motion(C.puppet_bank, C.puppet_idle) end
    status("pickup hold open for " .. tostring(C.pickup_window_seconds) .. "s")
end

pickup_window_active = function()
    return os.clock() < (S.pickup_until_clock or 0)
end

local function pickup_hold_tick()
    if not pickup_window_active() then return end
    if player_carrying() or pet_caught() then return end

    local ch, go = reacquire_pet()
    if not (ch and go) then return end

    set_think_stop(ch, false)
    stop_pet_navigation(true)
    clear_pet_hate()

    if C.pickup_lock_position and S.pickup_pos then
        local cp = transform_pos(go)
        local anchor = make_position(S.pickup_pos.x, S.pickup_pos.y, S.pickup_pos.z)
        local drift_d2 = distance_sq(cp, anchor) or 0
        if drift_d2 > 0.01 then
            set_transform(go, anchor, make_quat(S.pickup_rot))
        end
    end
end

pickup_pet_now = function()
    local ch, go = reacquire_pet()
    local p = get_player()
    local pgo = char_go(p)
    if not (ch and go and pgo) then status("pickup failed: no pet/player"); return false end

    local d2 = distance_sq(transform_pos(go), transform_pos(pgo))
    local d = d2 and math.sqrt(d2) or 999.0
    if d > (tonumber(C.pickup_range) or 2.2) then
        status(string.format("pickup refused: %.1fm > %.1fm", d, tonumber(C.pickup_range) or 2.2))
        return false
    end

    start_pickup_window()
    if not C.unsafe_direct_pickup then
        S.pickup_last = string.format("direct pickup disabled; hold opened d=%.1f", d)
        status(S.pickup_last)
        return false
    end

    local hcp = player_catch_processor()
    local ok = false
    if hcp then
        ok = pcall(function() hcp:call("startBridalCarry(app.Character)", ch) end)
        if not ok then ok = pcall(function() hcp:call("startBridalCarry", ch) end) end
    end

    S.pickup_last = string.format("direct pickup d=%.1f ok=%s", d, tostring(ok))
    status(S.pickup_last)
    return ok
end

local function housecat_set_root_scale(multiplier)
    if not (S.housecat_applied and S.housecat_ground_scale) then return false end
    local _, go = reacquire_pet()
    if not go then return false end

    local base = S.housecat_ground_scale
    local m = tonumber(multiplier) or 1.0
    local scale = Vector3f.new(base.x * m, base.y * m, base.z * m)
    local ok = false
    pcall(function()
        local tf = go:call("get_Transform")
        if tf then
            ok = pcall(function() tf:call("set_LocalScale", scale) end)
            if not ok then ok = pcall(function() tf:call("set_Scale", scale) end) end
        end
    end)
    return ok
end

local function housecat_carry_scale_tick(active)
    if not S.housecat_applied then return end

    if active then
        if not S.housecat_carry_scaled then
            local _, go = reacquire_pet()
            local current = nil
            pcall(function()
                local tf = go and go:call("get_Transform")
                current = tf and tf:call("get_LocalScale")
            end)
            S.housecat_ground_scale = {
                x = current and tonumber(current.x) or 1.0,
                y = current and tonumber(current.y) or 1.0,
                z = current and tonumber(current.z) or 1.0,
            }
            S.housecat_carry_scaled = true
        end
        housecat_set_root_scale(tonumber(C.housecat_carry_scale) or 0.72)
        return
    end

    if S.housecat_carry_scaled then
        housecat_set_root_scale(1.0)
        S.housecat_carry_scaled = false
        S.housecat_ground_scale = nil
    end
end

local function carry_state_tick()
    local active = player_carrying() or pet_caught()
    housecat_carry_scale_tick(active)
    if active then
        if not S.was_carried then
            S.was_carried = true
            status("carry active")
        end
        set_pet_ai_disabled(false)
        clear_pet_hate()
        return
    end

    if not S.was_carried then return end
    S.was_carried = false
    S.pickup_until_clock = 0
    clear_pet_hate()

    if C.follow_mode == "puppet" then
        S.puppet_last = -1
        S.puppet_settle = nil
        S.puppet_stuck = nil
        status("carry ended: puppet follow resumes")
        return
    end

    if C.stay_after_pickup then
        start_stay()
        status("carry ended: stay set")
    else
        calm_pet(true, "carry ended")
    end
end

local function sweep_characters()
    local els = nil
    pcall(function()
        local sm = sdk.get_native_singleton("via.SceneManager")
        local scene = sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        local comps = scene and scene:call("findComponents(System.Type)", sdk.find_type_definition("app.Character"):get_runtime_type())
        els = comps and comps:get_elements()
    end)
    return els or {}
end

local function nearest_enemy(origin, radius)
    local best, best_d2 = nil, nil
    local max_d2 = (radius or 45.0) * (radius or 45.0)
    for _, ch in ipairs(sweep_characters()) do
        if is_enemy_target(ch) then
            local pos = transform_pos(char_go(ch))
            local d2 = distance_sq(origin, pos)
            if d2 and d2 <= max_d2 and (not best_d2 or d2 < best_d2) then
                best = ch
                best_d2 = d2
            end
        end
    end
    return best, best_d2
end

local function pet_component(typename)
    local _, go = reacquire_pet()
    return get_component(go, typename)
end

local function apply_pet_attack_hate(enemy, ego)
    local ch = reacquire_pet()
    if not (ch and enemy and ego) then return false end

    local hs = nil
    pcall(function() hs = ch:call("get_HateSystem") end)
    if not hs then hs = pet_component("app.HateSystem") end

    local ok = false
    if hs then
        ok = pcall(function()
            pcall(function() hs:call("clearAllHate") end)
            hs:call("addHateParam(via.GameObject, app.HateRecvCategory, app.HateSystem.WriteType, System.Single, System.Single, System.Single, System.Single)",
                ego, 2, 1, C.hate_amount, C.hate_amount * 0.5, C.hate_amount * 0.5, 60.0)
            pcall(function() hs:call("setForceTotalHate", ego, C.hate_amount, C.hate_amount, C.hate_amount) end)
            pcall(function() hs:call("setCustomRate(via.GameObject, System.Single)", ego, C.hate_amount) end)
            pcall(function() hs:call("updateHateRanking") end)
        end)
    end

    local gp = pet_component("app.goalplanning.AIGoalPlanning")
    local bb = pet_component("app.AIBlackBoardController")
    pcall(function() if bb then bb:call("updateEnemyTargetList") end end)
    pcall(function() if gp then gp:call("sortAIActionTargets"); gp:call("updateSortTarget") end end)
    return ok
end

local function force_attack_nearest()
    local ch, go = reacquire_pet()
    if not (ch and go) then status("no pet to command"); return end

    local origin = transform_pos(go) or transform_pos(char_go(get_player()))
    local enemy, d2 = nearest_enemy(origin, tonumber(C.attack_radius) or 45.0)
    local ego = char_go(enemy)
    if not (enemy and ego) then
        S.last_attack = "no hostile in radius"
        status(S.last_attack)
        return
    end

    set_pet_inert(false)
    if C.follow_mode == "puppet" then set_pet_ai_disabled(false) end

    local ok = apply_pet_attack_hate(enemy, ego)
    S.attack_hold = {
        enemy = enemy,
        go = ego,
        until_clock = os.clock() + (tonumber(C.attack_hold_seconds) or 20.0),
        next_assert = 0,
    }

    S.last_attack = string.format("%s d=%.1f hate=%s", char_name(enemy), math.sqrt(d2 or 0), tostring(ok))
    status("attack nearest: " .. S.last_attack)
end

local function force_native_attack_nearest()
    local _, go = reacquire_pet()
    if not go then status("no pet to native attack"); return end

    local origin = transform_pos(go) or transform_pos(char_go(get_player()))
    local enemy, d2 = nearest_enemy(origin, tonumber(C.attack_radius) or 45.0)
    if not enemy then
        S.last_attack = "no hostile in radius"
        status(S.last_attack)
        return
    end

    set_pet_inert(false)
    set_pet_ai_disabled(false)
    local ok = native_request_command(CMD_ATTACK, enemy)
    S.last_attack = string.format("native %s d=%.1f ok=%s %s", char_name(enemy), math.sqrt(d2 or 0), tostring(ok), tostring(S.native_last))
    status("native attack nearest: " .. S.last_attack)
end

local function attack_hold_tick()
    local hold = S.attack_hold
    if not hold then return end
    if os.clock() > (hold.until_clock or 0) or is_dead(hold.enemy) then
        S.attack_hold = nil
        if C.passive_until_attack then clear_pet_hate() end
        if C.return_after_attack and C.follow_mode == "puppet" then
            local _, go = reacquire_pet()
            local pgo = char_go(get_player())
            local cp, pp = transform_pos(go), transform_pos(pgo)
            local d2 = distance_sq(cp, pp)
            if d2 and d2 > ((tonumber(C.leash_distance) or 18.0) * (tonumber(C.leash_distance) or 18.0)) then
                return_to_player()
            else
                set_pet_ai_disabled(true)
                stop_pet_navigation(true)
            end
        end
        status("attack hold ended")
        return
    end
    if os.clock() < (hold.next_assert or 0) then return end
    hold.next_assert = os.clock() + 0.35
    apply_pet_attack_hate(hold.enemy, hold.go)
end

local function hate_guard_tick()
    if not C.enabled then return end
    if S.attack_hold then return end
    if not (C.passive_until_attack or C.guard_party_hate) then return end
    local now = os.clock()
    if now - (S.last_hate_guard_clock or 0) < 0.20 then return end
    S.last_hate_guard_clock = now
    clear_pet_hate()
end

read_field = function(obj, names)
    if not obj then return nil end
    for _, name in ipairs(names) do
        local value = nil
        pcall(function() value = obj:get_field(name) end)
        if value ~= nil then return value, name end
    end
    return nil, nil
end

local function pet_canine_component()
    local _, go = reacquire_pet()
    if not go then return nil end
    for _, typename in ipairs({ "app.Ch223001", "app.Ch223000", "app.Ch223002", "app.Ch223" }) do
        local comp = get_component(go, typename)
        if comp then return comp, typename end
    end
    return nil, nil
end

local function pet_command_ctrl()
    local comp = pet_canine_component()
    local ctrl = nil
    if comp then
        ctrl = read_field(comp, {
            "_Ch223001CommandCtrl",
            "<Ch223001CommandCtrl>k__BackingField",
            "Ch223001CommandCtrl",
            "CommandCtrl",
            "_CommandCtrl",
            "<CommandCtrl>k__BackingField",
        })
    end
    return ctrl
end

local function command_snapshot(ctrl)
    if not ctrl then return "no command ctrl" end
    local current, leader, target = "?", "?", "?"
    pcall(function() current = ctrl:call("getCurrentCommand") end)
    pcall(function() leader = char_name(ctrl:call("getCommandLeader")) end)
    pcall(function() target = char_name(ctrl:call("getCommandTarget")) end)
    return "current=" .. tostring(current) .. " leader=" .. tostring(leader) .. " target=" .. tostring(target)
end

local function current_command_value(ctrl)
    local current = nil
    pcall(function() current = ctrl and ctrl:call("getCurrentCommand") end)
    return tonumber(current) or 0
end

local function set_command_info_field(info, names, value)
    if not (info and value ~= nil) then return false end
    local ok_any = false
    for _, name in ipairs(names) do
        local ok = pcall(function() info:set_field(name, value) end)
        if ok then ok_any = true end
    end
    return ok_any
end

local function make_command_info(command_type, leader, target)
    local info = nil
    pcall(function() info = sdk.create_instance("app.Ch223001CommandCtrl.CommandInfo"):add_ref() end)
    if not info then pcall(function() info = sdk.create_instance("app.Ch223001CommandCtrl.CommandInfo") end) end
    if not info then return nil, "create failed" end

    set_command_info_field(info, {
        "CommandType",
        "_CommandType",
        "<CommandType>k__BackingField",
        "Type",
        "_Type",
        "Command",
        "_Command",
        "<Command>k__BackingField",
        "CurrentCommand",
        "_CurrentCommand",
    }, command_type)

    set_command_info_field(info, {
        "CommandLeader",
        "_CommandLeader",
        "<CommandLeader>k__BackingField",
        "Leader",
        "_Leader",
        "<Leader>k__BackingField",
    }, leader)

    set_command_info_field(info, {
        "CommandTarget",
        "_CommandTarget",
        "<CommandTarget>k__BackingField",
        "Target",
        "_Target",
        "<Target>k__BackingField",
    }, target)

    return info, "created"
end

native_request_command = function(command_type, target_ch)
    local ch = reacquire_pet()
    local ctrl = pet_command_ctrl()
    if not (ch and ctrl) then
        S.native_last = "no command ctrl"
        return false
    end

    local leader = get_player()
    local target = target_ch or leader
    if not leader then
        S.native_last = "no leader/player"
        return false
    end

    local target_go = char_go(target)
    local leader_go = char_go(leader)
    local canine_comp = pet_canine_component()
    local tries = {}

    local function attempt(label, fn)
        local ok, result = pcall(fn)
        if ok then
            local cur = current_command_value(ctrl)
            tries[#tries + 1] = label .. "=ok/current" .. tostring(cur)
            if command_type == CMD_NONE or cur == command_type then
                S.native_call_style = label
                S.native_last = label .. " " .. command_snapshot(ctrl)
                return true, result
            end
        else
            tries[#tries + 1] = label .. "=false"
        end
        return false, result
    end

    local ok = attempt("request(type)", function()
        return ctrl:call("requestCommand(app.Ch223001CommandCtrl.CommandType)", command_type)
    end)
    if ok then return true end

    if canine_comp then
        ok = attempt("receive(self,type)", function()
            return ctrl:call("receiveCommand(app.Ch223001, app.Ch223001CommandCtrl.CommandType)", canine_comp, command_type)
        end)
        if ok then return true end
    end

    local info = make_command_info(command_type, leader, target)
    if info then
        ok = attempt("request(info)", function()
            return ctrl:call("requestCommand(app.Ch223001CommandCtrl.CommandInfo)", info)
        end)
        if ok then return true end
        ok = attempt("request(info/no-sig)", function() return ctrl:call("requestCommand", info) end)
        if ok then return true end
        ok = attempt("receive(info)", function()
            return ctrl:call("receiveCommand(app.Ch223001CommandCtrl.CommandInfo)", info)
        end)
        if ok then return true end
        ok = attempt("receive(info/no-sig)", function() return ctrl:call("receiveCommand", info) end)
        if ok then return true end
    end

    local candidates = {
        {
            "request(type,leader,target)",
            function() return ctrl:call("requestCommand", command_type, leader, target) end,
        },
        {
            "request(type,target)",
            function() return ctrl:call("requestCommand", command_type, target) end,
        },
        {
            "request(type,leaderGO,targetGO)",
            function() return ctrl:call("requestCommand", command_type, leader_go, target_go) end,
        },
        {
            "request(leader,target,type)",
            function() return ctrl:call("requestCommand", leader, target, command_type) end,
        },
        {
            "receive(type,leader,target)",
            function() return ctrl:call("receiveCommand", command_type, leader, target) end,
        },
        {
            "receive(type,target)",
            function() return ctrl:call("receiveCommand", command_type, target) end,
        },
    }

    for _, candidate in ipairs(candidates) do
        local ok = attempt(candidate[1], candidate[2])
        if ok then return true end
    end

    S.native_last = "failed: " .. table.concat(tries, ", ")
    return false
end

local function apply_colour_id()
    local _, go = reacquire_pet()
    if not go then status("no pet to colour"); return end

    local colour = math.floor(tonumber(C.colour_id) or 0)
    local touched = {}

    local function try_context(label, obj)
        if not obj then return end
        local ok = pcall(function() obj:set_field("_ColorID", colour) end)
        if ok then touched[#touched + 1] = label .. "._ColorID" end
        ok = pcall(function() obj:call("setColorID(System.Int32)", colour) end)
        if ok then touched[#touched + 1] = label .. ".setColorID(i32)" end
        ok = pcall(function() obj:call("setColorID", colour) end)
        if ok then touched[#touched + 1] = label .. ".setColorID" end
    end

    for _, typename in ipairs({ "app.Ch223001", "app.Ch223000", "app.Ch223002", "app.Ch223" }) do
        local comp = get_component(go, typename)
        try_context(typename, comp)
        local my_ctx = read_field(comp, {
            "<MyContext>k__BackingField",
            "MyContext",
            "_MyContext",
            "Context",
            "<Context>k__BackingField",
        })
        try_context(typename .. ".MyContext", my_ctx)
        local ctx = read_field(comp, { "DedicatedParameter", "<DedicatedParameter>k__BackingField", "_DedicatedParameter", "Context", "<Context>k__BackingField" })
        try_context(typename .. ".DedicatedParameter", ctx)
    end

    if #touched == 0 then
        status("colour id write found no known canine context")
    else
        status("colour id " .. tostring(colour) .. " wrote " .. table.concat(touched, ", "))
    end
end

local function dump_pet_probe()
    local ch, go = reacquire_pet()
    local lines = { "== IrisPets dump ==" }
    lines[#lines + 1] = "pet=" .. tostring(ch) .. " go=" .. tostring(go) .. " name=" .. tostring(S.pet_name)
    lines[#lines + 1] = "native=" .. tostring(S.native_last)
    lines[#lines + 1] = "command=" .. command_snapshot(pet_command_ctrl())
    if not go then
        json.dump_file(MOD .. "_dump.json", { lines = lines })
        status("dump wrote no-pet state")
        return
    end

    local function append_object_detail(label, obj)
        if not obj then return end
        local td = nil
        pcall(function() td = obj:get_type_definition() end)
        if not td then return end
        lines[#lines + 1] = "DETAIL " .. tostring(label) .. " type=" .. tostring(td:get_full_name())
        pcall(function()
            for _, m in ipairs(td:get_methods() or {}) do
                local mn = m:get_name() or "?"
                local lo = mn:lower()
                if lo:find("command") or lo:find("follow") or lo:find("attack") or lo:find("target")
                    or lo:find("clear") or lo:find("reset") or lo:find("set") or lo:find("request") then
                    lines[#lines + 1] = "  m " .. method_signature(m)
                end
            end
        end)
        pcall(function()
            for _, f in ipairs(td:get_fields() or {}) do
                local fn = f:get_name() or "?"
                local fl = fn:lower()
                local dump_all = tostring(label):find("CommandInfo") ~= nil or tostring(td:get_full_name()):find("CommandInfo") ~= nil
                if dump_all or fl:find("command") or fl:find("follow") or fl:find("attack") or fl:find("target")
                    or fl:find("context") or fl:find("color") or fl:find("think") then
                    local val = nil
                    pcall(function() val = f:get_data(obj) end)
                    local ftype = "?"
                    pcall(function() ftype = f:get_type():get_full_name() end)
                    lines[#lines + 1] = "  f " .. tostring(ftype) .. " " .. fn .. " = " .. tostring(val)
                    if val and (fl:find("command") or fl:find("target") or fl:find("leader")) then
                        append_object_detail(tostring(label) .. "." .. fn, val)
                    end
                end
            end
        end)
    end

    pcall(function()
        local comps = go:call("get_Components")
        local els = comps and comps:get_elements()
        lines[#lines + 1] = "components=" .. tostring(els and #els or 0)
        for _, comp in ipairs(els or {}) do
            local td = comp and comp:get_type_definition()
            local tn = td and td:get_full_name() or "?"
            local lo = tn:lower()
            if lo:find("ch223") or lo:find("hate") or lo:find("target") or lo:find("navigation") or lo:find("decision") or lo:find("enemy") then
                lines[#lines + 1] = "COMP " .. tn
                for _, f in ipairs(td:get_fields() or {}) do
                    local fn = f:get_name()
                    local fl = fn:lower()
                    if fl:find("color") or fl:find("command") or fl:find("target") or fl:find("hate") or fl:find("navigation") or fl:find("decision") or fl:find("enemy") or fl:find("context") then
                        local val = nil
                        pcall(function() val = f:get_data(comp) end)
                        local ftype = "?"
                        pcall(function() ftype = f:get_type():get_full_name() end)
                        lines[#lines + 1] = "  f " .. tostring(ftype) .. " " .. fn .. " = " .. tostring(val)
                        if fl:find("command") or fl:find("context") or fl:find("target") then
                            append_object_detail(tn .. "." .. fn, val)
                        end
                    end
                end
            end
        end
    end)

    json.dump_file(MOD .. "_dump.json", { lines = lines })
    status("dump wrote data/" .. MOD .. "_dump.json")
end

local rel_method = nil
pcall(function()
    rel_method = sdk.find_type_definition("app.BattleRelationshipHolder"):get_method("getRelationshipFromTo(app.Character, app.Character)")
end)

if rel_method then
    sdk.hook(rel_method,
        function(args)
            thread.get_hook_storage().irispets_args = (
                C.enabled
                and sdk.to_int64(args[3]) ~= 0
                and sdk.to_int64(args[4]) ~= 0
                and next(pets) ~= nil
            ) and args or nil
        end,
        function(retval)
            local args = thread.get_hook_storage().irispets_args
            if not args then return retval end

            local a, b = nil, nil
            local ok = pcall(function()
                a = sdk.to_managed_object(args[3])
                b = sdk.to_managed_object(args[4])
            end)
            if not (ok and a and b) then return retval end

            local a_pet = is_pet(a)
            local b_pet = is_pet(b)
            if not (a_pet or b_pet) then return retval end

            local other = a_pet and b or a
            S.relation_hits = S.relation_hits + 1

            if is_friendly_to_pet(other) then
                S.friend_hits = S.friend_hits + 1
                return REL_FRIEND
            end

            if C.hostile_to_enemies and is_enemy_target(other) then
                S.hostile_hits = S.hostile_hits + 1
                return REL_HOSTILE
            end

            return REL_NEUTRAL
        end
    )
else
    status("relationship hook method not found")
end

local hate_add_method = nil
pcall(function()
    hate_add_method = sdk.find_type_definition("app.HateSystem"):get_method(
        "addHateParam(via.GameObject, app.HateRecvCategory, app.HateSystem.WriteType, System.Single, System.Single, System.Single, System.Single)"
    )
end)

if hate_add_method then
    sdk.hook(hate_add_method,
        function(args)
            if not (C.enabled and C.block_party_hate and next(pets) ~= nil) then return sdk.PreHookResult.CALL_ORIGINAL end

            local hs, target_go = nil, nil
            pcall(function()
                hs = sdk.to_managed_object(args[2])
                target_go = sdk.to_managed_object(args[3])
            end)
            if not (hs and target_go) then return sdk.PreHookResult.CALL_ORIGINAL end

            local pet_hs = pet_hate_system()
            if same_obj(hs, pet_hs) and is_player_or_party_go(target_go) then
                pcall(clear_pet_hate)
                return sdk.PreHookResult.SKIP_ORIGINAL
            end

            return sdk.PreHookResult.CALL_ORIGINAL
        end,
        nil
    )
else
    status("hate add hook method not found")
end

re.on_application_entry("UpdateBehavior", function()
    S.frame = S.frame + 1

    if S.spawner then
        pcall(function()
            S.spawner:updateInstanceCounts()
            S.spawner:requestSpawnOutstanding()
            if S.spawner:hasAnyOutstandingPostProc() then S.spawner:processPostProc() end
        end)
    end

    if S.pending_spawn then
        local ch = nil
        pcall(function()
            local inst = S.spawner and S.spawner.instances and S.spawner.instances[1]
            ch = inst and inst.instance and inst.instance:get_Chara()
        end)
        if ch then
            S.pending_spawn = false
            register_pet(ch)
            if C.colour_id and C.colour_id ~= 0 then apply_colour_id() end
            local spec = PETS[C.selected_pet] or PETS[1]
            if spec.housecat then
                local ok, why = housecat_apply_mesh()
                if not ok then status("house-cat mesh swap failed: " .. tostring(why)) end
            end
        end
    end

    pcall(root_motion_test_tick)
    pcall(lie_hold_tick)
    pcall(audition_tick)
    pcall(pickup_hold_tick)
    pcall(carry_state_tick)
    pcall(attack_hold_tick)
    pcall(hate_guard_tick)
    pcall(follow_tick)
    pcall(stay_tick)
end)

-- Catch positioning can update after ordinary behaviour. Reassert only the
-- house-cat carry multiplier here; the original standing scale is restored as
-- soon as the carry state ends.
re.on_application_entry("LateUpdateBehavior", function()
    if S.housecat_carry_scaled then
        pcall(housecat_set_root_scale, tonumber(C.housecat_carry_scale) or 0.72)
    end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("IRIS Pets (house cat / dog)") then return end

    local changed = false
    local chg

    chg, C.enabled = imgui.checkbox("Enabled", C.enabled); changed = changed or chg
    chg, C.selected_pet = imgui.combo("Animal", C.selected_pet, (function()
        local names = {}
        for _, pet in ipairs(PETS) do names[#names + 1] = pet.name .. " (" .. pet.code .. ")" end
        return names
    end)()); changed = changed or chg

    chg, C.spawn_distance = imgui.drag_float("Spawn distance", C.spawn_distance, 0.1, 1.0, 8.0); changed = changed or chg
    chg, C.spawn_scale = imgui.drag_float("Scale", C.spawn_scale, 0.05, 0.25, 3.0); changed = changed or chg
    chg, C.spawn_idle = imgui.checkbox("Spawn idle", C.spawn_idle); changed = changed or chg

    local spec = PETS[C.selected_pet] or PETS[1]
    if spec.housecat then
        imgui.text("RETIRED: house cats are now owned by Iris TAMING.")
        imgui.text("Open Iris TAMING > House cat (IRIS companion).")
    end

    if imgui.button("Spawn / replace pet") then spawn_selected_pet() end
    imgui.same_line()
    if imgui.button("Delete pet") then delete_pet() end
    imgui.same_line()
    if imgui.button("Calm pet") then calm_pet(true, "button") end

    imgui.separator()
    chg, C.friendly_to_party = imgui.checkbox("Friendly to player/pawns", C.friendly_to_party); changed = changed or chg
    chg, C.friendly_to_npcs = imgui.checkbox("Friendly to NPCs", C.friendly_to_npcs); changed = changed or chg
    chg, C.hostile_to_enemies = imgui.checkbox("Hostile to enemies", C.hostile_to_enemies); changed = changed or chg
    chg, C.passive_until_attack = imgui.checkbox("Passive until attack command", C.passive_until_attack); changed = changed or chg
    chg, C.guard_party_hate = imgui.checkbox("Clear hate while passive", C.guard_party_hate); changed = changed or chg
    chg, C.block_party_hate = imgui.checkbox("Block player/pawn hate", C.block_party_hate); changed = changed or chg

    imgui.text("Pet: " .. tostring(S.pet_name))
    imgui.text(string.format("Relationship hits: total=%d friend=%d hostile=%d", S.relation_hits, S.friend_hits, S.hostile_hits))

    imgui.separator()
    chg, C.follow_distance = imgui.drag_float("Follow distance", C.follow_distance, 0.1, 1.0, 8.0); changed = changed or chg
    chg, C.leash_distance = imgui.drag_float("Leash distance", C.leash_distance, 0.5, 4.0, 40.0); changed = changed or chg
    chg, C.follow_interval = imgui.drag_float("Follow tick seconds", C.follow_interval, 0.01, 0.05, 2.0); changed = changed or chg
    if imgui.button("Follow: nav") then set_follow_mode("nav") end
    imgui.same_line()
    if imgui.button("Follow: native pack") then set_follow_mode("native") end
    imgui.same_line()
    if imgui.button("Follow: puppet") then set_follow_mode("puppet") end
    imgui.same_line()
    if imgui.button("Follow: warp") then set_follow_mode("warp") end
    imgui.same_line()
    if imgui.button("Stop follow") then set_follow_mode("off") end
    if imgui.button("Return to me") then return_to_player() end
    imgui.same_line()
    if imgui.button("Hold for pickup") then start_pickup_window() end
    imgui.same_line()
    if imgui.button("Stay here") then start_stay() end
    imgui.same_line()
    if imgui.button("Clear stay") then stop_stay() end
    imgui.same_line()
    if imgui.button("Native observe") then native_request_command(CMD_KEEP_OBSERVE, get_player()); status("native observe: " .. tostring(S.native_last)) end
    imgui.text("Follow mode: " .. tostring(C.follow_mode))
    imgui.text("Native command is Redwolf-pack behaviour; puppet is the useful pet follow.")
    chg, C.native_tick_seconds = imgui.drag_float("Native tick seconds", C.native_tick_seconds, 0.05, 0.25, 5.0); changed = changed or chg
    chg, C.stay_inert = imgui.checkbox("Stay uses inert think-stop", C.stay_inert); changed = changed or chg
    chg, C.stay_disable_ai = imgui.checkbox("Stay hard-disables AI/nav", C.stay_disable_ai); changed = changed or chg
    chg, C.stay_lie_down = imgui.checkbox("Stay tries lie-down first", C.stay_lie_down); changed = changed or chg
    chg, C.stay_lock_position = imgui.checkbox("Stay locks position", C.stay_lock_position); changed = changed or chg
    chg, C.stay_lock_radius = imgui.drag_float("Stay lock radius", C.stay_lock_radius, 0.01, 0.0, 1.0); changed = changed or chg
    chg, C.stay_idle_motion = imgui.drag_int("Stay idle motion (-1 none)", C.stay_idle_motion, 1, -1, 2000); changed = changed or chg
    chg, C.stay_idle_tick_seconds = imgui.drag_float("Stay idle tick seconds", C.stay_idle_tick_seconds, 0.1, 0.25, 20.0); changed = changed or chg
    chg, C.stay_after_pickup = imgui.checkbox("Stay after pickup putdown", C.stay_after_pickup); changed = changed or chg
    chg, C.stay_warp_fallback = imgui.checkbox("Stay warp fallback", C.stay_warp_fallback); changed = changed or chg
    imgui.text("Current motion: " .. current_motion_label())
    if imgui.button("Capture current as idle") then capture_current_motion("idle") end
    imgui.same_line()
    if imgui.button("Capture current as lie start") then capture_current_motion("lie_start") end
    imgui.same_line()
    if imgui.button("Capture current as lie loop") then capture_current_motion("lie_loop") end
    chg, C.lie_bank = imgui.drag_int("Lie bank", C.lie_bank, 1, 0, 200); changed = changed or chg
    chg, C.lie_start_motion = imgui.drag_int("Lie start motion", C.lie_start_motion, 1, 0, 2000); changed = changed or chg
    chg, C.lie_loop_motion = imgui.drag_int("Lie loop motion", C.lie_loop_motion, 1, 0, 2000); changed = changed or chg
    chg, C.lie_inert_delay_frames = imgui.drag_int("Lie inert delay frames", C.lie_inert_delay_frames, 1, 1, 240); changed = changed or chg
    chg, C.lie_action_node = imgui.input_text("Lie action node", C.lie_action_node); changed = changed or chg
    if imgui.button("Test lie start motion") then play_pet_motion(C.lie_bank, C.lie_start_motion); status("test lie start motion " .. tostring(C.lie_start_motion)) end
    imgui.same_line()
    if imgui.button("Stay lie down") then start_lie_down_stay() end
    imgui.same_line()
    if imgui.button("Request lie action") then status("lie action " .. tostring(C.lie_action_node) .. " ok=" .. tostring(request_pet_action_node(C.lie_action_node, 10, 0))) end
    chg, C.puppet_tick_seconds = imgui.drag_float("Puppet tick seconds", C.puppet_tick_seconds, 0.01, 0.03, 0.75); changed = changed or chg
    chg, C.puppet_bank = imgui.drag_int("Puppet bank", C.puppet_bank, 1, 0, 200); changed = changed or chg
    chg, C.puppet_idle = imgui.drag_int("Puppet idle clip (-1 none)", C.puppet_idle, 1, -1, 2000); changed = changed or chg
    chg, C.puppet_idle_sequence = imgui.input_text("Puppet idle sequence", C.puppet_idle_sequence); changed = changed or chg
    chg, C.puppet_idle_tick_seconds = imgui.drag_float("Puppet idle tick seconds", C.puppet_idle_tick_seconds, 0.1, 0.25, 20.0); changed = changed or chg
    chg, C.puppet_settle_lock_position = imgui.checkbox("Puppet locks settle position", C.puppet_settle_lock_position); changed = changed or chg
    chg, C.puppet_settle_lock_radius = imgui.drag_float("Puppet settle lock radius", C.puppet_settle_lock_radius, 0.01, 0.0, 1.5); changed = changed or chg
    chg, C.puppet_release_ai_on_settle = imgui.checkbox("Puppet releases AI near player", C.puppet_release_ai_on_settle); changed = changed or chg
    chg, C.puppet_rescue_enabled = imgui.checkbox("Puppet edge/stuck rescue", C.puppet_rescue_enabled); changed = changed or chg
    chg, C.puppet_rescue_distance = imgui.drag_float("Puppet rescue distance", C.puppet_rescue_distance, 0.5, 2.0, 40.0); changed = changed or chg
    chg, C.puppet_rescue_stuck_enabled = imgui.checkbox("Puppet stuck timer rescue", C.puppet_rescue_stuck_enabled); changed = changed or chg
    chg, C.puppet_rescue_seconds = imgui.drag_float("Puppet stuck seconds", C.puppet_rescue_seconds, 0.1, 0.3, 8.0); changed = changed or chg
    chg, C.puppet_rescue_cooldown_seconds = imgui.drag_float("Puppet rescue cooldown", C.puppet_rescue_cooldown_seconds, 0.5, 1.0, 30.0); changed = changed or chg
    chg, C.puppet_rescue_vertical = imgui.drag_float("Puppet vertical rescue", C.puppet_rescue_vertical, 0.1, 0.3, 8.0); changed = changed or chg
    chg, C.puppet_rescue_min_progress = imgui.drag_float("Puppet min progress", C.puppet_rescue_min_progress, 0.05, 0.0, 2.0); changed = changed or chg
    chg, C.puppet_walk = imgui.drag_int("Puppet walk clip", C.puppet_walk, 1, 0, 2000); changed = changed or chg
    chg, C.puppet_jog = imgui.drag_int("Puppet jog clip", C.puppet_jog, 1, 0, 2000); changed = changed or chg
    chg, C.puppet_run = imgui.drag_int("Puppet run clip", C.puppet_run, 1, 0, 2000); changed = changed or chg
    chg, C.puppet_stop_radius = imgui.drag_float("Puppet target stop radius", C.puppet_stop_radius, 0.05, 0.1, 3.0); changed = changed or chg
    chg, C.puppet_jog_distance = imgui.drag_float("Puppet jog distance", C.puppet_jog_distance, 0.5, 2.0, 20.0); changed = changed or chg
    chg, C.puppet_run_distance = imgui.drag_float("Puppet run distance", C.puppet_run_distance, 0.5, 3.0, 40.0); changed = changed or chg
    chg, C.pickup_window_seconds = imgui.drag_float("Pickup window seconds", C.pickup_window_seconds, 0.25, 0.5, 15.0); changed = changed or chg
    chg, C.pickup_range = imgui.drag_float("Pickup range", C.pickup_range, 0.1, 0.5, 4.0); changed = changed or chg
    chg, C.pickup_lock_position = imgui.checkbox("Pickup hold locks position", C.pickup_lock_position); changed = changed or chg
    chg, C.unsafe_direct_pickup = imgui.checkbox("Enable unsafe direct pickup call", C.unsafe_direct_pickup); changed = changed or chg
    if C.unsafe_direct_pickup then
        if imgui.button("Unsafe direct pickup") then pickup_pet_now() end
    end
    imgui.text("Pickup: " .. tostring(S.pickup_last))
    chg, C.audition_bank = imgui.drag_int("Audition bank##audition_bank_value", C.audition_bank, 1, 0, 200); changed = changed or chg
    chg, C.audition_motion = imgui.drag_int("Audition motion##audition_motion_value", C.audition_motion, 1, 0, 2000); changed = changed or chg
    chg, C.audition_step = imgui.drag_int("Audition step##audition_step_value", C.audition_step, 1, 1, 100); changed = changed or chg
    chg, C.audition_disable_ai = imgui.checkbox("Audition disables AI/nav##audition_disable_ai_toggle", C.audition_disable_ai); changed = changed or chg
    chg, C.audition_lock_position = imgui.checkbox("Audition locks position##audition_lock_toggle", C.audition_lock_position); changed = changed or chg
    if imgui.button("Audition motion##audition_motion_button") then audition_motion(0) end
    imgui.same_line()
    if imgui.button("- audition##audition_prev_button") then audition_motion(-1) end
    imgui.same_line()
    if imgui.button("+ audition##audition_next_button") then audition_motion(1) end
    imgui.same_line()
    if imgui.button("Capture current as audition##capture_audition_button") then capture_current_motion("audition") end
    imgui.same_line()
    if imgui.button("Stop audition##stop_audition_button") then stop_audition() end
    if imgui.button("Test root-motion run clip") then start_root_motion_test(C.puppet_run) end
    imgui.same_line()
    if imgui.button("Stop root-motion test") then stop_root_motion_test() end
    if S.root_test then imgui.text(string.format("Root test: clip=%s moved=%.2fm", tostring(S.root_test.motion_id), S.root_test.moved or 0.0)) end

    imgui.separator()
    chg, C.attack_radius = imgui.drag_float("Attack search radius", C.attack_radius, 1.0, 5.0, 120.0); changed = changed or chg
    chg, C.hate_amount = imgui.drag_float("Attack hate", C.hate_amount, 5.0, 10.0, 9999.0); changed = changed or chg
    chg, C.attack_hold_seconds = imgui.drag_float("Attack hold seconds", C.attack_hold_seconds, 0.5, 1.0, 120.0); changed = changed or chg
    chg, C.return_after_attack = imgui.checkbox("Return after attack hold", C.return_after_attack); changed = changed or chg
    if imgui.button("Attack nearest hostile") then force_attack_nearest() end
    imgui.same_line()
    if imgui.button("Native attack nearest (unsafe)") then force_native_attack_nearest() end
    imgui.text("Last attack: " .. tostring(S.last_attack))
    imgui.text("Native command: " .. tostring(S.native_last))

    imgui.separator()
    chg, C.colour_id = imgui.drag_int("Colour ID", C.colour_id, 1, 0, 15); changed = changed or chg
    if imgui.button("Apply colour ID") then apply_colour_id() end
    imgui.same_line()
    if imgui.button("Dump pet internals") then dump_pet_probe() end

    imgui.separator()
    imgui.text(S.last_status)

    if changed then save_config() end
    imgui.tree_pop()
end)

status("loaded")
