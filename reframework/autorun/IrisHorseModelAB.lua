-- IrisHorseModelAB.lua ---------------------------------------------------------
-- A/B test rig for the IRIS horse BODY.
--
-- Model A = the shipped body (character/ch/ch99_011/horse.mesh) + the stock
--           horse.mdf2, loaded by IrisWildHorses.lua exactly as always. Untouched.
-- Model B = character/ch/ch99_011/horse2.mesh, shipped by
--           IRIS_HorseModelB_v1.0_FluffyMod.zip (pak entry IRIS_09_horse2.pak).
--
-- ⭐ v1.0: B is now A ITSELF, reshaped. Nine builds were spent growing a mane onto a
-- different donor body before Aurora pointed out the obvious: A already HAS an
-- artist-sculpted mane, forelock and tail fused into its shell, plus a real painted
-- albedo and clean non-overlapping UVs. Only its legs and body were wrong. So v1.0
-- keeps all of that and applies a parametric scale field measured off the GLB donor.
--
-- B reproduces A's own VANILLA four-material table in the vanilla order
-- (body_mat, eye_mat, oral_mat, vfx_mat) with the same 3-vert dummies A ships, so the
-- STOCK horse.mdf2 resolves unchanged. UV1 and UV2 are BIT-IDENTICAL to A's -- only
-- vertex positions moved -- so the existing horse texture lands exactly as it does now.
--
-- ⛔ DEFAULT DISARMED. sdk.create_resource on a path the engine cannot serve is an
--    INSTANT c000001d, not a nil return, so nothing touches the pak until Aurora
--    ticks Arm.
-- ⛔ COLD-RESOURCE LAW: create_resource is ASYNC. Pin at ARM, wait out a gate, and
--    build a FRESH holder for every body (holders go stale between conversions).
-- ⛔ EyeGlowController is neutralised BEFORE set_Material -- it caches per-material
--    accessors and a swap leaves them dangling (the c0000005 in every unicorn dump).
---------------------------------------------------------------------------------

local MOD = "IrisHorseModelAB"
local MESH_PATH_B = "character/ch/ch99_011/horse2.mesh"
local MDF_PATH_B  = "character/ch/ch99_011/horse2.mdf2"
local WARM_GATE = 15.0
local RETRY_PERIOD = 2.0

local reflog = log -- capture BEFORE any shadowing

-- ⛔ v0.4 checkerboarded the ENTIRE body because horse2.mdf2 was produced by
-- re_mdf.exportfile -- that round-trip does NOT survive for DD2, and the unicorn
-- had already retreated from custom mdf2s for the same reason. v0.5/v0.6 dropped
-- the mdf2 entirely and faked the mane with PALETTE-UV.
-- ⭐ v0.7 brings the mdf2 back the ONLY way that works: horse.mdf2 is cloned and
-- BYTE-PATCHED in place (rs_tools/horse_mane_tex/rs_patch_horse2_mdf.py) -- four
-- u64 pointers and two same-slot UTF-16 strings, nothing re-serialised, file size
-- byte-identical. eye_mat and body_mat are provably untouched.
-- ⛔ STILL TRUE: create_resource on a path the pak does not contain is an INSTANT
-- c000001d, not a nil return. So use_custom_mdf must be false unless the v0.7 pak
-- (which carries horse2.mdf2 AND both horse_mane_*.tex) is actually installed.
-- ⛔⛔ CONFIG GENERATION. v0.8 shipped with use_custom_mdf defaulting true, but the
-- saved data/IrisHorseModelAB.json still held the v0.5-era `false` and load_config
-- restored it -- so the mesh swapped, set_Material never ran, and mane+tail sampled
-- the DOE BODY ATLAS (a deer's face, teeth and gums, painted across the mane).
-- The hair texture had never once been applied in game. Any saved config older than
-- CFG_GEN has its use_custom_mdf IGNORED in favour of the default below.
-- ⭐ v1.0 CHANGES THE WHOLE APPROACH. Model B is no longer the GLB body with a
-- synthesised mane. It is the SHIPPED horse (Model A) with its legs and body reshaped
-- to Model B's proportions: chest +13.8%, barrel +8.4%, neck +7.8%, foreleg thickness
-- +31%. A's artist-sculpted mane, forelock and tail are kept exactly as they are.
-- ⛔ THEREFORE horse2.mdf2 AND the horse_mane_*.tex ARE NO LONGER IN THE PAK. The mesh
-- reproduces A's own vanilla 4-material table, so the STOCK horse.mdf2 is what we want.
-- use_custom_mdf is forced false and there is no UI toggle: create_resource on a path
-- the pak does not contain is an INSTANT c000001d, and a saved `true` from v0.9 would
-- otherwise fire it at arm time. CFG_GEN bumped so that saved value can never load.
local CFG_GEN = 3
local C = {
    armed = false,
    auto_apply = true,
    use_custom_mdf = false,
    cfg_gen = CFG_GEN,
}

local R = {
    res_mesh = nil, res_mdf = nil,
    warm_at = nil,
    failed = false,
    status = "disarmed",
    orig_mesh = {},   -- address -> original mesh holder
    orig_mdf  = {},   -- address -> original material
    swapped = {},
    next_scan = 0,
    last_result = "",
}

local function say(message)
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

local function set_mesh_enabled(mesh, enabled)
    pcall(function() mesh:call("set_Enabled", enabled == true) end)
end

local CONFIG_FILE = "IrisHorseModelAB.json"
local function save_config() pcall(function() json.dump_file(CONFIG_FILE, C) end) end
local function load_config()
    pcall(function()
        local saved = json.load_file(CONFIG_FILE)
        if type(saved) ~= "table" then return end
        if type(saved.auto_apply) == "boolean" then C.auto_apply = saved.auto_apply end
        -- ⛔ NEVER restored. The v1.0 pak ships horse2.mesh ONLY; a saved `true` from
        -- v0.9 would fire create_resource at a path that no longer exists = instant CTD.
        C.use_custom_mdf = false
        C.cfg_gen = CFG_GEN
        -- `armed` is deliberately NOT restored: a saved-on arm would fire
        -- create_resource at boot on a machine where the pak had been uninstalled.
    end)
end

---------------------------------------------------------------------------------

local function pin_resources()
    if R.failed then return end
    if not R.res_mesh then
        pcall(function()
            local res = sdk.create_resource("via.render.MeshResource", MESH_PATH_B)
            if res then res:add_ref(); R.res_mesh = res; R.warm_at = os.clock() end
        end)
        if not R.res_mesh then
            R.failed = true
            R.status = "horse2.mesh resource NIL -- is IRIS_09_horse2.pak installed?"
            say(R.status); return
        end
        say("horse2.mesh pinned; streaming (" .. WARM_GATE .. "s gate)")
    end
    if C.use_custom_mdf and not R.res_mdf then
        pcall(function()
            local res = sdk.create_resource("via.render.MeshMaterialResource", MDF_PATH_B)
            if res then res:add_ref(); R.res_mdf = res end
        end)
        if R.res_mdf then say("horse2.mdf2 pinned")
        else say("WARNING: horse2.mdf2 resource NIL -- falling back to mesh-only swap") end
    end
end

-- Fresh holders every body. Returns mesh_holder, mdf_holder, reason.
local function fresh_holders()
    if not C.armed then return nil, nil, "disarmed" end
    if R.failed then return nil, nil, "failed" end
    if not R.res_mesh then
        pin_resources()
        if not R.res_mesh then return nil, nil, "failed" end
    end
    local age = os.clock() - (R.warm_at or 0)
    if age < WARM_GATE then
        R.status = string.format("streaming (%.0fs / %.0fs)", age, WARM_GATE)
        return nil, nil, "warming"
    end
    local mh = nil
    pcall(function()
        mh = R.res_mesh:create_holder("via.render.MeshResourceHolder")
        if mh then mh:add_ref() end
    end)
    if not valid(mh) then return nil, nil, "mesh holder build failed" end
    local dh = nil
    if C.use_custom_mdf and R.res_mdf then
        pcall(function()
            dh = R.res_mdf:create_holder("via.render.MeshMaterialResourceHolder")
            if dh then dh:add_ref() end
        end)
        if not valid(dh) then dh = nil end
    end
    return mh, dh
end

---------------------------------------------------------------------------------

local function scene_characters()
    local out = {}
    pcall(function()
        local singleton = sdk.get_native_singleton("via.SceneManager")
        if not singleton then return end
        local scene = sdk.call_native_func(singleton,
            sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        if not scene then return end
        local found = scene:call("findComponents(System.Type)", sdk.typeof("app.Character"))
        if not found then return end
        local count = found:call("get_Count") or 0
        for i = 0, count - 1 do
            local item = found:call("get_Item", i)
            if item then out[#out + 1] = item end
        end
    end)
    return out
end

local function live_horses()
    local api = rawget(_G, "__iris_wild_horses_api")
    local out = {}
    if not (api and api.is_horse) then return out, "IrisWildHorses API not loaded" end
    for _, character in ipairs(scene_characters()) do
        local go = nil
        pcall(function() go = character:call("get_GameObject") end)
        if valid(go) then
            local ok, is_horse = pcall(api.is_horse, go)
            if ok and is_horse then out[#out + 1] = go end
        end
    end
    return out, nil
end

---------------------------------------------------------------------------------

local function neutralise_eye_glow(go)
    local what = "app.Monster not found"
    pcall(function()
        local monster = get_component(go, "app.Monster")
        if not monster then return end
        what = "Monster found, EyeGlowController field nil"
        local ctrl = monster:get_field("EyeGlowController")
        if not ctrl then return end
        pcall(function() ctrl:call("resetController") end)
        pcall(function() ctrl:call("set_IsInitialized", false) end)
        pcall(function() ctrl:call("set_InitializeFailed", true) end)
        what = "reset + init latch set"
    end)
    return what
end

local function set_material(mesh, holder)
    local ok = pcall(function() mesh:call("set_Material", holder) end)
    if not ok then ok = pcall(function() mesh:call("setMaterial", holder) end) end
    return ok
end

local function swap_body(go, mesh_holder, mdf_holder)
    local address = object_address(go)
    if not address then return false, "no address" end
    local mesh = get_component(go, "via.render.Mesh")
    if not mesh then return false, "no via.render.Mesh on the body" end

    if R.orig_mesh[address] == nil then
        local om = nil
        pcall(function() om = mesh:call("getMesh") end)
        if om then pcall(function() om:add_ref() end); R.orig_mesh[address] = om end
        local od = nil
        pcall(function() od = mesh:call("get_Material") end)
        if od then pcall(function() od:add_ref() end); R.orig_mdf[address] = od end
    end

    neutralise_eye_glow(go)
    set_mesh_enabled(mesh, false)
    local mesh_ok, mesh_err = pcall(function() mesh:call("setMesh", mesh_holder) end)
    local mdf_ok = true
    if mesh_ok and mdf_holder then mdf_ok = set_material(mesh, mdf_holder) end
    set_mesh_enabled(mesh, true)

    if not (mesh_ok and mdf_ok) then
        -- never leave a body half-swapped
        set_mesh_enabled(mesh, false)
        if R.orig_mesh[address] then
            pcall(function() mesh:call("setMesh", R.orig_mesh[address]) end)
        end
        if R.orig_mdf[address] then set_material(mesh, R.orig_mdf[address]) end
        set_mesh_enabled(mesh, true)
        return false, (mesh_ok and "set_Material failed" or tostring(mesh_err))
    end
    R.swapped[address] = true
    return true
end

local function apply_model_b(only_new)
    if not C.armed then R.last_result = "disarmed"; return end
    local horses, why = live_horses()
    if why then R.last_result = why; return end
    if #horses == 0 then
        if not only_new then R.last_result = "no live IRIS horses found" end
        return
    end
    local done, skipped, failed, last_err = 0, 0, 0, ""
    for _, go in ipairs(horses) do
        local address = object_address(go)
        if only_new and address and R.swapped[address] then
            skipped = skipped + 1
        else
            local mh, dh, reason = fresh_holders()
            if not mh then
                R.last_result = "Model B not ready: " .. tostring(reason); return
            end
            local ok, err = swap_body(go, mh, dh)
            if ok then done = done + 1 else failed = failed + 1; last_err = err or "" end
        end
    end
    if done > 0 or failed > 0 or not only_new then
        R.last_result = string.format("Model B applied to %d, %d already on B, %d failed %s",
            done, skipped, failed, (failed > 0) and ("| " .. last_err) or "")
        say(R.last_result)
    end
end

local function revert_model_a()
    local horses, why = live_horses()
    if why then R.last_result = why; return end
    local done, failed = 0, 0
    for _, go in ipairs(horses) do
        local address = object_address(go)
        local bm = address and R.orig_mesh[address]
        local bd = address and R.orig_mdf[address]
        local mesh = get_component(go, "via.render.Mesh")
        if bm and mesh then
            neutralise_eye_glow(go)
            set_mesh_enabled(mesh, false)
            local ok = pcall(function() mesh:call("setMesh", bm) end)
            if bd then set_material(mesh, bd) end
            set_mesh_enabled(mesh, true)
            if ok then done = done + 1; R.swapped[address] = nil else failed = failed + 1 end
        end
    end
    R.last_result = string.format("reverted %d to Model A, %d failed", done, failed)
    say(R.last_result)
end

---------------------------------------------------------------------------------

re.on_frame(function()
    if not (C.armed and C.auto_apply) then return end
    local now = os.clock()
    if now < R.next_scan then return end
    R.next_scan = now + RETRY_PERIOD
    pcall(apply_model_b, true)
end)

re.on_draw_ui(function()
    if not imgui.collapsing_header("IRIS - Horse Model A/B") then return end
    imgui.text("A = horse.mesh (shipped)   B = horse2.mesh (A reshaped)")
    imgui.text("Needs IRIS_HorseModelB_v1.0_FluffyMod.zip installed in Fluffy.")
    imgui.separator()

    local changed, value = imgui.checkbox(
        "ARM (loads the pak -- only tick this with the pak installed)", C.armed)
    if changed then
        C.armed = value
        if C.armed then R.failed = false; R.status = "arming"; pin_resources()
        else R.status = "disarmed" end
        save_config()
    end
    changed, value = imgui.checkbox("Keep new horses on Model B", C.auto_apply)
    if changed then C.auto_apply = value; save_config() end
    imgui.text("B = the shipped horse reshaped to the new model's legs/body.")
    imgui.text("Mane, tail and texture are A's own -- stock horse.mdf2, no custom mdf2.")

    imgui.separator()
    if imgui.button("Apply Model B to live horses now") then pcall(apply_model_b, false) end
    imgui.same_line()
    if imgui.button("Revert to Model A") then pcall(revert_model_a) end
    if imgui.button("Count live IRIS horses") then
        local horses, why = live_horses()
        R.last_result = why or (tostring(#horses) .. " live IRIS horse body(ies) in scene")
    end
    imgui.same_line()
    -- The engine REUSES GameObject addresses; a recycled one can make auto-apply
    -- think a fresh body is already swapped and leave it on A.
    if imgui.button("Clear swap cache") then
        R.swapped, R.orig_mesh, R.orig_mdf = {}, {}, {}
        R.last_result = "swap cache cleared -- next pass re-applies to every body"
    end

    imgui.separator()
    if C.armed and R.res_mesh and R.warm_at then
        local age = os.clock() - R.warm_at
        R.status = (age < WARM_GATE)
            and string.format("streaming (%.0fs / %.0fs)", age, WARM_GATE)
            or "ready (mesh swap, stock horse.mdf2)"
    end
    imgui.text("status : " .. tostring(R.status))
    imgui.text("result : " .. tostring(R.last_result))
end)

load_config()
say("loaded (DISARMED -- tick Arm once IRIS_09_horse2.pak is installed)")
