-- ReyDauGriffinPort.lua
--
-- Per-instance Rey Dau appearance for Griffins.
--
-- IMPORTANT: never call setMesh on a live Griffin's native skinned renderer.
-- DD2 does not rebuild that renderer's joint bindings and can crash.  Instead,
-- this script creates a child visual GameObject, enables Transform's native
-- SameJointsConstraint so it shares the parent Griffin skeleton, then adds the
-- Rey renderer to that child.  The resource is bound while the child is hidden,
-- verified, revealed, and only then is the untouched native renderer hidden.
-- Restore is therefore just an enable/disable operation.

local STATE_KEY = "__lyra_rey_dau_griffin_port_v8"
local previous = rawget(_G, STATE_KEY)
if previous then previous.active = false end

local S = {
    active = true,
    generation = (previous and previous.generation or 0) + 1,
    status = "Ready. Ordinary Griffins remain ordinary.",
    phase = "idle",
    resources = {},
    held_refs = {},
    conversions = {},
    pending = nil,
    spawner = nil,
    spawned_character = nil,
    spawned_game_object = nil,
    spawn_count = previous and previous.spawn_count or 0,
    conversion_count = previous and previous.conversion_count or 0,
}
rawset(_G, STATE_KEY, S)

local this_generation = S.generation
local GRIFFIN_CODE = "ch253000_00"
local GRIFFIN_PREFIX = "ch253000"
local REY_MESH_PATH = "riftspeak/rey_dau/rey_dau_griffin_v9.mesh"
local REY_MDF_PATH = "riftspeak/rey_dau/ch53_000_rey_dau.mdf2"
local SPAWN_DISTANCE = 18.0
local MAX_NEAREST_DISTANCE = 120.0
local ok_spawn, SpawnRequest = pcall(require, "EnemySpawner/spawnRequest")
local position_type = sdk.find_type_definition("via.Position")

local function report(message)
    S.status = tostring(message)
    pcall(function() log.info("[ReyDauGriffinPort] " .. S.status) end)
end

local function valid(object)
    if not object then return false end
    local ok, value = pcall(function() return object:call("get_Valid") end)
    return (not ok) or value ~= false
end

local function elements(array)
    if not array then return {} end
    local values = {}
    local ok = pcall(function() values = array:get_elements() or {} end)
    if ok then return values end
    local count = 0
    pcall(function() count = tonumber(array:call("get_Count")) or 0 end)
    if count == 0 then pcall(function() count = tonumber(array:call("get_Length")) or 0 end) end
    for index = 0, count - 1 do
        local value = nil
        pcall(function() value = array[index] end)
        if not value then pcall(function() value = array:call("get_Item", index) end) end
        if value then values[#values + 1] = value end
    end
    return values
end

local function make_position(x, y, z)
    local value = ValueType.new(position_type)
    value.x = tonumber(x) or 0.0
    value.y = tonumber(y) or 0.0
    value.z = tonumber(z) or 0.0
    return value
end

local function get_component(game_object, type_name)
    local component = nil
    pcall(function()
        component = game_object and game_object:call(
            "getComponent(System.Type)", sdk.typeof(type_name)
        )
    end)
    return component
end

local function game_object_of(character)
    local game_object = nil
    pcall(function() game_object = character and character:call("get_GameObject") end)
    return game_object
end

local function transform_of(game_object)
    local transform = nil
    pcall(function() transform = game_object and game_object:call("get_Transform") end)
    return transform
end

local function universal_position(game_object)
    local position = nil
    local transform = transform_of(game_object)
    pcall(function() position = transform and transform:call("get_UniversalPosition") end)
    if not position then pcall(function() position = transform and transform:call("get_Position") end) end
    return position
end

local function same_object(a, b)
    if not a or not b then return false end
    if a == b then return true end
    local ap, bp = nil, nil
    pcall(function() ap = sdk.to_ptr(a) end)
    pcall(function() bp = sdk.to_ptr(b) end)
    return ap ~= nil and bp ~= nil and tostring(ap) == tostring(bp)
end

local function object_key(object)
    local pointer = nil
    pcall(function() pointer = sdk.to_ptr(object) end)
    return tostring(pointer or object)
end

local function set_enabled(component, enabled)
    if component then pcall(function() component:call("set_Enabled", enabled == true) end) end
end

local function set_draw(game_object, enabled)
    if not game_object then return end
    pcall(function() game_object:call("set_DrawSelf", enabled == true) end)
    pcall(function() game_object:call("set_UpdateSelf", true) end)
end

local function character_code(character)
    local code = nil
    pcall(function() code = character:call("get_CharaIDString") end)
    if code == nil then pcall(function() code = character:call("getCharaIDString") end) end
    return tostring(code or "")
end

local function is_griffin(character)
    return string.sub(character_code(character), 1, #GRIFFIN_PREFIX) == GRIFFIN_PREFIX
end

local function current_scene()
    local scene = nil
    pcall(function()
        local manager = sdk.get_native_singleton("via.SceneManager")
        scene = manager and sdk.call_native_func(
            manager, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene"
        )
    end)
    if not scene then
        pcall(function()
            local manager = sdk.get_managed_singleton("via.SceneManager")
            scene = manager and manager:call("get_CurrentScene")
        end)
    end
    return scene
end

local function player_game_object()
    local game_object = nil
    pcall(function()
        local manager = sdk.get_managed_singleton("app.CharacterManager")
        local player = manager and manager:call("get_ManualPlayer")
        game_object = player and player:call("get_GameObject")
    end)
    return game_object
end

local function distance_squared(a, b)
    if not a or not b then return math.huge end
    local dx = (tonumber(a.x) or 0.0) - (tonumber(b.x) or 0.0)
    local dy = (tonumber(a.y) or 0.0) - (tonumber(b.y) or 0.0)
    local dz = (tonumber(a.z) or 0.0) - (tonumber(b.z) or 0.0)
    return dx * dx + dy * dy + dz * dz
end

local function nearest_griffin()
    if valid(S.spawned_character) and is_griffin(S.spawned_character) then
        local go = game_object_of(S.spawned_character)
        local record = go and S.conversions[object_key(go)]
        if not record or not record.applied then return S.spawned_character, go, 0.0 end
    end

    local scene = current_scene()
    local origin = universal_position(player_game_object())
    if not scene or not origin then return nil, nil, math.huge end

    local components = nil
    pcall(function()
        components = scene:call("findComponents(System.Type)", sdk.typeof("app.Character"))
    end)
    local best_character, best_go, best_d2 = nil, nil, math.huge
    for _, character in ipairs(elements(components)) do
        if valid(character) and is_griffin(character) then
            local go = game_object_of(character)
            local key = go and object_key(go)
            local record = key and S.conversions[key]
            if go and (not record or not record.applied) then
                local d2 = distance_squared(origin, universal_position(go))
                if d2 < best_d2 then
                    best_character, best_go, best_d2 = character, go, d2
                end
            end
        end
    end
    return best_character, best_go, math.sqrt(best_d2)
end

local function create_holder(resource_type, holder_type, path)
    local resource, holder = nil, nil
    local ok, err = pcall(function()
        resource = sdk.create_resource(resource_type, path)
        if not resource then error("create_resource returned nil for " .. path) end
        resource = resource:add_ref()
        holder = resource:create_holder(holder_type)
        if not holder then error("create_holder returned nil for " .. path) end
        holder = holder:add_ref()
    end)
    if not ok then return nil, nil, err end
    S.held_refs[#S.held_refs + 1] = resource
    S.held_refs[#S.held_refs + 1] = holder
    return resource, holder, nil
end

local function ensure_resources()
    if valid(S.resources.mesh_holder) and valid(S.resources.mdf_holder) then return true end
    local mesh_resource, mesh_holder, mesh_err = create_holder(
        "via.render.MeshResource", "via.render.MeshResourceHolder", REY_MESH_PATH
    )
    if not mesh_holder then
        report("Rey mesh resource failed to load: " .. tostring(mesh_err))
        return false
    end
    local mdf_resource, mdf_holder, mdf_err = create_holder(
        "via.render.MeshMaterialResource", "via.render.MeshMaterialResourceHolder", REY_MDF_PATH
    )
    if not mdf_holder then
        report("Rey material resource failed to load: " .. tostring(mdf_err))
        return false
    end
    S.resources = {
        mesh_resource = mesh_resource,
        mesh_holder = mesh_holder,
        mdf_resource = mdf_resource,
        mdf_holder = mdf_holder,
    }
    return true
end

local function queue_nearest_conversion()
    if S.pending then
        report("A renderer operation is already in progress.")
        return
    end
    local character, game_object, distance = nearest_griffin()
    if not game_object or distance > MAX_NEAREST_DISTANCE then
        report("No unconverted Griffin found within 120 metres.")
        return
    end
    S.pending = {
        kind = "convert",
        character = character,
        game_object = game_object,
        distance = distance,
        step = "load",
        wait_frames = 0,
    }
    S.phase = "converting"
    report(string.format("Queued the nearest Griffin (%.1fm) for safe Rey renderer attachment.", distance))
end

local function fail_pending(message)
    local job = S.pending
    if job then
        set_enabled(job.overlay, false)
        set_draw(job.overlay_game_object, false)
        set_enabled(job.original, true)
    end
    S.pending = nil
    S.phase = "idle"
    report(message)
end

local function process_conversion()
    local job = S.pending
    if not job or job.kind ~= "convert" then return end
    if not valid(job.game_object) then
        fail_pending("The selected Griffin despawned before conversion completed.")
        return
    end

    if job.step == "load" then
        if not ensure_resources() then fail_pending(S.status); return end
        job.step = "create_overlay"
        return
    end

    if job.step == "create_overlay" then
        job.original = get_component(job.game_object, "via.render.Mesh")
        if not job.original then
            fail_pending("Selected Griffin has no native Mesh component.")
            return
        end
        local overlay_game_object, overlay_transform, overlay = nil, nil, nil
        local ok, err = pcall(function()
            local create = sdk.find_type_definition("via.GameObject"):get_method(
                "create(System.String)"
            )
            overlay_game_object = create:call(
                nil, "ReyDauVisualProxy_" .. tostring(S.conversion_count + 1)
            )
            if not overlay_game_object then error("GameObject.create returned nil") end
            overlay_game_object = overlay_game_object:add_ref()
            -- GameObject.create allocates the object, but DD2's proven runtime
            -- component path still runs the native constructor before attaching
            -- render components.  Without this, a Mesh can draw while never
            -- constructing its material/texture instances (pink checkerboard).
            overlay_game_object:call(".ctor")
            set_draw(overlay_game_object, false)
            overlay_transform = overlay_game_object:call("get_Transform")
            local parent_transform = job.game_object:call("get_Transform")
            if not overlay_transform or not parent_transform then
                error("visual or Griffin transform unavailable")
            end
            overlay_transform:call("set_Parent", parent_transform)
            overlay_transform:call("set_LocalPosition", Vector3f.new(0.0, 0.0, 0.0))
            overlay_transform:call("set_LocalRotation", Quaternion.new(0.0, 0.0, 0.0, 1.0))
            overlay_transform:call("set_LocalScale", Vector3f.new(1.0, 1.0, 1.0))
            overlay_transform:call("set_SameJointsConstraint", true)
            overlay = overlay_game_object:call(
                "createComponent(System.Type)", sdk.typeof("via.render.Mesh")
            )
            if not overlay then error("Mesh component creation returned nil") end
            overlay = overlay:add_ref()
            overlay:call(".ctor()")
        end)
        if not ok or not overlay then
            job.overlay_game_object = overlay_game_object
            fail_pending("DD2 refused the child visual proxy: " .. tostring(err))
            return
        end
        local constraint = false
        pcall(function() constraint = overlay_transform:call("get_SameJointsConstraint") == true end)
        if not constraint then
            job.overlay_game_object = overlay_game_object
            job.overlay = overlay
            fail_pending("DD2 did not accept SameJointsConstraint on the child proxy.")
            return
        end
        job.overlay_game_object = overlay_game_object
        job.overlay_transform = overlay_transform
        job.overlay = overlay
        -- DrawSelf keeps the proxy invisible.  The Mesh itself must remain
        -- enabled so DD2 can create its material instances and stream every
        -- texture referenced by the dynamically assigned MDF.
        set_enabled(job.overlay, true)
        S.held_refs[#S.held_refs + 1] = overlay_game_object
        S.held_refs[#S.held_refs + 1] = overlay_transform
        S.held_refs[#S.held_refs + 1] = overlay
        job.wait_frames = 4
        job.step = "wait_to_bind"
        return
    end

    if job.step == "wait_to_bind" then
        job.wait_frames = job.wait_frames - 1
        if job.wait_frames <= 0 then job.step = "bind" end
        return
    end

    if job.step == "bind" then
        local mesh_ok = pcall(function() job.overlay:call("setMesh", S.resources.mesh_holder) end)
        if not mesh_ok then
            mesh_ok = pcall(function() job.overlay:call("set_Mesh", S.resources.mesh_holder) end)
        end
        local mdf_ok = pcall(function() job.overlay:call("set_Material", S.resources.mdf_holder) end)
        if not mdf_ok then
            mdf_ok = pcall(function() job.overlay:call("setMaterial", S.resources.mdf_holder) end)
        end
        if not mesh_ok or not mdf_ok then
            fail_pending(string.format(
                "Overlay binding failed safely (mesh=%s material=%s); native Griffin retained.",
                tostring(mesh_ok), tostring(mdf_ok)
            ))
            return
        end
        -- Let the hidden, enabled renderer build its material instances and
        -- submit the MDF's dependent TEX resources before we expose it.
        job.wait_frames = 12
        job.step = "verify"
        return
    end

    if job.step == "verify" then
        job.wait_frames = job.wait_frames - 1
        if job.wait_frames > 0 then return end
        local mesh_readback, mdf_readback = nil, nil
        pcall(function() mesh_readback = job.overlay:call("getMesh") end)
        if not mesh_readback then pcall(function() mesh_readback = job.overlay:call("get_Mesh") end) end
        pcall(function() mdf_readback = job.overlay:call("get_Material") end)
        if not mesh_readback or not mdf_readback then
            fail_pending("Overlay resource readback failed; native Griffin retained.")
            return
        end
        local constraint = false
        pcall(function()
            constraint = job.overlay_transform:call("get_SameJointsConstraint") == true
        end)
        if not constraint then
            fail_pending("Child proxy lost SameJointsConstraint; native Griffin retained.")
            return
        end
        -- Refresh the constraint after the Mesh has built its joint palette.
        pcall(function()
            job.overlay_transform:call("set_SameJointsConstraint", false)
            job.overlay_transform:call("set_SameJointsConstraint", true)
        end)
        local shared_joints = {}
        pcall(function()
            shared_joints = elements(job.overlay_transform:call("get_Joints"))
        end)
        job.proxy_joint_count = #shared_joints
        set_draw(job.overlay_game_object, true)
        set_enabled(job.overlay, true)
        job.wait_frames = 2
        job.step = "reveal"
        return
    end

    if job.step == "reveal" then
        job.wait_frames = job.wait_frames - 1
        if job.wait_frames > 0 then return end
        set_enabled(job.original, false)
        local key = object_key(job.game_object)
        S.conversions[key] = {
            game_object = job.game_object,
            character = job.character,
            original = job.original,
            overlay_game_object = job.overlay_game_object,
            overlay_transform = job.overlay_transform,
            overlay = job.overlay,
            applied = true,
        }
        S.conversion_count = S.conversion_count + 1
        S.last_conversion_key = key
        S.pending = nil
        S.phase = "idle"
        S.last_proxy_joint_count = job.proxy_joint_count
        report(string.format(
            "Converted one Griffin to Rey Dau (proxy reports %d shared joints). AI, attacks and collision remain Griffin-native.",
            job.proxy_joint_count or 0
        ))
    end
end

local function restore_last_conversion()
    if S.pending then
        report("Wait for the current renderer operation to finish first.")
        return
    end
    local record = S.last_conversion_key and S.conversions[S.last_conversion_key]
    if not record or not record.applied or not valid(record.game_object) then
        report("No live converted Griffin is available to restore.")
        return
    end
    set_enabled(record.overlay, false)
    set_draw(record.overlay_game_object, false)
    set_enabled(record.original, true)
    record.applied = false
    report("Restored the last converted creature's native Griffin renderer.")
end

local function player_spawn_transform()
    local position, rotation = nil, nil
    local ok, err = pcall(function()
        local game_object = player_game_object()
        local transform = transform_of(game_object)
        if not transform then error("player transform unavailable") end
        local current = transform:call("get_UniversalPosition")
        local forward = transform:call("get_AxisZ")
        rotation = transform:call("get_Rotation")
        position = make_position(
            current.x + (forward and forward.x or 0.0) * SPAWN_DISTANCE,
            current.y,
            current.z + (forward and forward.z or 0.0) * SPAWN_DISTANCE
        )
    end)
    if not ok then return nil, nil, err end
    return position, rotation, nil
end

local function spawn_normal_griffin()
    if not ok_spawn or not SpawnRequest then
        report("Cannot spawn: EnemySpawner/spawnRequest is unavailable.")
        return
    end
    if S.spawner then
        report("This tool already owns a spawned Griffin. Despawn it first.")
        return
    end
    local position, rotation, transform_err = player_spawn_transform()
    if not position then
        report("Cannot spawn until the player is in the world: " .. tostring(transform_err))
        return
    end
    local ok, err = pcall(function()
        local config = {
            spawnIdle = false,
            instLimit = 1,
            spawnMultiple = { enable = false, qty = 1 },
            ovrScale = { enable = false, scale = 1.0, normalizeSpeed = false },
            postProcScale = false,
        }
        S.spawner = SpawnRequest:new()
        S.spawner:updateConfig(config)
        S.spawner:requestAddInstances(GRIFFIN_CODE, position, rotation, config, 1)
    end)
    if not ok then
        S.spawner = nil
        report("Griffin spawn setup failed: " .. tostring(err))
        return
    end
    S.spawn_count = S.spawn_count + 1
    S.phase = "spawning"
    S.spawn_started_at = os.clock()
    report("Spawning one normal Griffin 18 metres ahead.")
end

local function tick_spawner()
    if not S.spawner then return end
    pcall(function()
        S.spawner:updateInstanceCounts()
        S.spawner:requestSpawnOutstanding()
        if S.spawner:hasAnyOutstandingPostProc() then S.spawner:processPostProc() end
    end)
    if not valid(S.spawned_character) then
        pcall(function()
            local entry = S.spawner.instances and S.spawner.instances[1]
            S.spawned_character = entry and entry.instance and entry.instance:get_Chara()
            S.spawned_game_object = entry and entry.instance and entry.instance:get_Instance()
        end)
        if valid(S.spawned_character) then
            S.phase = "idle"
            report("Normal Griffin spawned. Use CONVERT NEAREST GRIFFIN when ready.")
        elseif os.clock() - (S.spawn_started_at or os.clock()) > 30.0 then
            S.phase = "idle"
            report("The Griffin spawn request timed out.")
        end
    end
end

local function despawn_ours()
    if S.spawner then
        pcall(function()
            local entry = S.spawner.instances and S.spawner.instances[1]
            local game_object = entry and entry.instance and entry.instance:get_Instance()
            if game_object then game_object:destroy(game_object) end
        end)
    end
    S.spawner = nil
    S.spawned_character = nil
    S.spawned_game_object = nil
    if S.phase == "spawning" then S.phase = "idle" end
    report("Despawned this tool's Griffin.")
end

re.on_application_entry("UpdateBehavior", function()
    local state = rawget(_G, STATE_KEY)
    if not state or not state.active or state.generation ~= this_generation then return end
    tick_spawner()
    process_conversion()
end)

re.on_draw_ui(function()
    local state = rawget(_G, STATE_KEY)
    if not state or not state.active or state.generation ~= this_generation then return end
    if not imgui.tree_node("Rey Dau / Griffin switcher##rey_dau_griffin") then return end

    imgui.text("Ordinary Griffins remain native. Conversion affects one live Griffin only.")
    imgui.text("A child proxy shares the Griffin joints; its native renderer remains untouched.")
    imgui.text("Selects this tool's spawn first, otherwise the nearest Griffin within 120m.")
    if imgui.button("SPAWN NORMAL GRIFFIN##rey_dau_spawn_griffin") then
        spawn_normal_griffin()
    end
    if imgui.button("CONVERT NEAREST GRIFFIN TO REY DAU##rey_dau_convert") then
        queue_nearest_conversion()
    end
    if imgui.button("RESTORE LAST CONVERTED GRIFFIN##rey_dau_restore") then
        restore_last_conversion()
    end
    if imgui.button("DESPAWN MINE##rey_dau_despawn") then
        despawn_ours()
    end

    imgui.text("Phase: " .. tostring(state.phase))
    imgui.text(string.format(
        "Spawn requests: %d | successful conversions: %d",
        state.spawn_count or 0, state.conversion_count or 0
    ))
    imgui.text("Status: " .. tostring(state.status))
    if state.last_proxy_joint_count ~= nil then
        imgui.text("Last proxy shared-joint count: " .. tostring(state.last_proxy_joint_count))
    end
    imgui.tree_pop()
end)

re.on_script_reset(function()
    local state = rawget(_G, STATE_KEY)
    if state and state.generation == this_generation then state.active = false end
end)
