--[[--------------------------------------------------------------------------
IRIS / LYRA - Pegasus mesh test harness                             2026-08-11

Loads `character/ch/ch53_000/pegasus.mesh` (shipped by IRIS_09_pegasus.pak) and
swaps it onto ONE live griffin, per-instance. Wild griffins are untouched unless
you press the button. Nothing here is automatic.

Mesh-only diagnostics are paired with the STOCK ch53_000.mdf2, so scrambled
colour is expected. White-coat releases add a custom 25-slot MDF and texture.
Enable the material checkbox only when one of those packages is installed.

⛔ SAFETY: `sdk.create_resource` on a path the engine cannot serve is an INSTANT
CTD (c000001d), so this script does NOTHING until you tick "Arm". Only arm it
once the pak is actually installed.

⛔ EyeGlowController: on a live app.Monster it caches per-material accessors and
its next onUpdate dereferences them. It is NOT a via component (il2cpp parent is
System.Object) - get_component can never find it. It lives as a FIELD on the
body's app.Monster. We neutralise it before touching the renderer even though we
do not change the material count, because a mesh swap alone still re-registers
the render surface.
----------------------------------------------------------------------------]]

local MESH_PATH      = "character/ch/ch53_000/pegasus.mesh"
local MATERIAL_PATH  = "riftspeak/pegasus/pegasus.mdf2"
local LOGTAG         = "[IrisPegasus] "

-- ⛔ STREAMING WARM GATE (restored 08-19): create_resource returns while the
-- mesh is still STREAMING from disk; setMesh on a half-streamed resource skins
-- partial buffers = the crumpled "pulsating bag" that ate a whole day of false
-- mesh forensics. The holder object exposes no readiness signal our valid()
-- can read (the pcall fallback rubber-stamped it), so the field-proven fixed
-- wait from v0.1-v0.10 is back. Do not remove it again without a REAL signal.
local WARM_SECONDS = 15.0

local C = { armed = false, use_custom_material = false }
local R = {
    res = nil, holder = nil, failed = false,
    mdf_res = nil, mdf_holder = nil,
    warm_started = nil,
    status = "disarmed", last = "", swapped = {},
}

local function log(s) print(LOGTAG .. tostring(s)) end
local function valid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:call("valid") end)
    if ok and v ~= nil then return v end
    return true
end
local function get_component(go, tname)
    if not go then return nil end
    local ok, c = pcall(function()
        return go:call("getComponent(System.Type)",
            sdk.typeof(tname))
    end)
    if ok then return c end
    return nil
end

local function warm_remaining()
    if not R.warm_started then return WARM_SECONDS end
    return math.max(0.0, WARM_SECONDS - (os.clock() - R.warm_started))
end

local function resources_ready()
    return valid(R.holder)
        and (not C.use_custom_material or valid(R.mdf_holder))
        and warm_remaining() <= 0.0
end

-- ---------------------------------------------------------------- resources
local function warm()
    if R.failed or not C.armed then return false end
    if resources_ready() then return true end
    if not R.res then
        local ok = pcall(function()
            local res = sdk.create_resource("via.render.MeshResource", MESH_PATH)
            if res then res:add_ref(); R.res = res end
        end)
        if not ok or not R.res then
            R.failed = true
            R.status = "resource NIL - is IRIS_09_pegasus.pak installed?"
            log(R.status); return false
        end
        R.warm_started = os.clock()
        log("Pegasus mesh resource pinned - streaming warm-up started")
    end
    if C.use_custom_material and not R.mdf_res then
        local ok = pcall(function()
            local res = sdk.create_resource(
                "via.render.MeshMaterialResource", MATERIAL_PATH)
            if res then res:add_ref(); R.mdf_res = res end
        end)
        if not ok or not R.mdf_res then
            R.failed = true
            R.status = "material resource NIL - install a white-coat package"
            log(R.status); return false
        end
        log("Pegasus material resource pinned")
    end
    -- create_resource has already resolved the resource path.  The holder is
    -- the engine-supported lifetime/streaming handle, so build it immediately;
    -- the old fixed 15-second os.clock gate added latency without providing a
    -- meaningful readiness signal.
    pcall(function()
        if not valid(R.holder) then
            local h = R.res:create_holder("via.render.MeshResourceHolder")
            if h then h:add_ref(); R.holder = h end
        end
    end)
    if C.use_custom_material then
        pcall(function()
            if not valid(R.mdf_holder) then
                local h = R.mdf_res:create_holder("via.render.MeshMaterialResourceHolder")
                if h then h:add_ref(); R.mdf_holder = h end
            end
        end)
    end
    if resources_ready() then
        R.status = C.use_custom_material and "mesh + white coat READY"
            or "pegasus mesh READY (stock material)"
        log(R.status)
    elseif valid(R.holder) and warm_remaining() > 0.0 then
        R.status = string.format("streaming warm-up: %.0fs left - DO NOT swap yet",
            warm_remaining())
    else
        R.status = "holder build failed"
        log(R.status)
    end
    return resources_ready()
end

-- ------------------------------------------------------------------ griffins
-- Enumeration copied from the field-proven sweep in `GriffinRideProbe - Iris.lua`
-- (~:9323). My first attempt guessed at `get_EnemyContexts` and found nothing while
-- the taming panel was happily listing ch253000_00 two lines above it.
-- ⚠ TAMED bodies leave the enemy list (the ally switch removes them), so the scene
-- component sweep is not optional - it is the only one that sees a tamed griffin.
local function char_go(ch)
    if not ch then return nil end
    local go = nil
    pcall(function() go = ch:call("get_GameObject") end)
    return go or ch
end

local function griffins()
    local out, seenmap, names = {}, {}, {}
    local function consider(ch)
        local go = char_go(ch)
        if not go then return end
        local nm = nil
        pcall(function() nm = go:call("get_Name") end)
        nm = tostring(nm or "")
        if #names < 10 then names[#names+1] = nm end
        if not nm:find("ch253", 1, true) then return end
        local addr = nil
        pcall(function() addr = go:get_address() end)
        local key = tostring(addr or nm)
        if seenmap[key] then return end
        seenmap[key] = true
        out[#out+1] = go
    end
    local function sweep(mgr_name, getters)
        pcall(function()
            local mgr = sdk.get_managed_singleton(mgr_name)
            if not mgr then return end
            for _, g in ipairs(getters) do
                local list = nil
                pcall(function() list = mgr:call(g) end)
                local n = 0
                pcall(function() n = list and list:call("get_Count") or 0 end)
                if (tonumber(n) or 0) > 0 then
                    for i = 0, n - 1 do
                        pcall(function() consider(list:call("get_Item", i)) end)
                    end
                    return
                end
            end
        end)
    end
    sweep("app.CharacterManager",
        { "get_CharacterList", "getCharacterList", "get_AllCharacterList", "get_CharacterAll" })
    if #out == 0 then
        sweep("app.EnemyManager",
            { "get_EnemyList", "getAllEnemies", "get_ActiveEnemyList", "get_EnemyCharacterList" })
    end
    if #out == 0 then
        pcall(function()
            local sm  = sdk.get_native_singleton("via.SceneManager")
            local smt = sdk.find_type_definition("via.SceneManager")
            local scene = sdk.call_native_func(sm, smt, "get_CurrentScene")
            if not scene then return end
            local comps = scene:call("findComponents(System.Type)", sdk.typeof("app.Character"))
            if not comps then return end
            local arr = comps
            pcall(function() arr = comps:get_elements() end)
            for _, comp in ipairs(arr or {}) do pcall(function() consider(comp) end) end
        end)
    end
    R.scan = table.concat(names, " | ")
    return out
end

-- the body normally carries ONE via.render.Mesh holding every material (proven on the
-- wolf and the doe), but walk the whole subtree rather than one level in case the
-- griffin nests it
local function find_mesh(go, depth)
    depth = depth or 0
    if not go or depth > 6 then return nil end
    local m = get_component(go, "via.render.Mesh")
    if m then return m end
    local t = nil
    pcall(function() t = go:call("get_Transform") end)
    if not t then return nil end
    local child = nil
    pcall(function() child = t:call("get_Child") end)
    while child do
        local cgo = nil
        pcall(function() cgo = child:call("get_GameObject") end)
        local cm = cgo and find_mesh(cgo, depth + 1)
        if cm then return cm end
        local nxt = nil
        pcall(function() nxt = child:call("get_Next") end)
        child = nxt
    end
    return nil
end

-- read back what the live renderer actually has, so a bad swap is diagnosable
-- instead of a guess (this is the step that would have saved days on Akamaru)
local function probe(go)
    local mesh = find_mesh(go)
    if not mesh then return "no via.render.Mesh found" end
    local n = 0
    pcall(function() n = mesh:call("get_MaterialNum") or 0 end)   -- NOT getMaterialCount
    local names = {}
    for i = 0, math.min(n, 30) - 1 do
        local nm = nil
        pcall(function() nm = mesh:call("getMaterialName", i) end)
        names[#names+1] = tostring(nm or "?")
    end
    return string.format("materials=%d: %s", n, table.concat(names, ", "))
end

local function swap(go)
    if not resources_ready() then return false, "resource holders not ready" end
    local mesh = find_mesh(go)
    if not mesh then return false, "no via.render.Mesh on this griffin" end

    -- neutralise EyeGlowController via the app.Monster FIELD (not a component)
    local note = "no app.Monster"
    pcall(function()
        local monster = get_component(go, "app.Monster")
        if not monster then return end
        note = "Monster ok, EyeGlowController nil"
        local ctrl = monster:get_field("EyeGlowController")
        if not ctrl then return end
        pcall(function() ctrl:call("resetController") end)
        pcall(function() ctrl:call("set_IsInitialized", false) end)
        pcall(function() ctrl:call("set_InitializeFailed", true) end)
        note = "EyeGlowController reset + latched"
    end)

    local old, old_mat = nil, nil
    pcall(function() old = mesh:call("getMesh") end)
    if not old then pcall(function() old = mesh:call("get_Mesh") end) end
    if C.use_custom_material then
        pcall(function() old_mat = mesh:call("get_Material") end)
        if not old_mat then pcall(function() old_mat = mesh:call("getMaterial") end) end
    end
    pcall(function() mesh:call("set_Enabled", false) end)
    local ok, err = pcall(function() mesh:call("setMesh", R.holder) end)
    if ok and C.use_custom_material then
        local mat_ok, mat_err = pcall(function()
            mesh:call("set_Material", R.mdf_holder)
        end)
        if not mat_ok then
            mat_ok, mat_err = pcall(function()
                mesh:call("setMaterial", R.mdf_holder)
            end)
        end
        if not mat_ok then ok = false; err = mat_err end
    end
    pcall(function() mesh:call("set_Enabled", true) end)

    if not ok then
        pcall(function() mesh:call("set_Enabled", false) end)
        if old then pcall(function() mesh:call("setMesh", old) end) end
        if old_mat then
            local restored = pcall(function() mesh:call("set_Material", old_mat) end)
            if not restored then pcall(function() mesh:call("setMaterial", old_mat) end) end
        end
        pcall(function() mesh:call("set_Enabled", true) end)
        -- a holder built from a warmed pinned resource that still throws is stale:
        -- drop the HOLDER only, never the pinned resource (dropping it restarts the
        -- ~12 s stream from zero and you can never win the race)
        R.holder = nil
        return false, "setMesh threw: " .. tostring(err) .. " | " .. note
    end
    -- ⛔ use-after-free law: pin the cached originals or the engine frees them
    -- once they leave the renderer, and Revert restores a dangling ref (the
    -- "Griff disappears on revert" bug). Released again in revert_all().
    if old then pcall(function() old:add_ref() end) end
    if old_mat then pcall(function() old_mat:add_ref() end) end
    R.swapped[#R.swapped+1] = {
        go = go, old = old, old_mat = old_mat, mesh = mesh,
        used_custom_material = C.use_custom_material,
    }
    return true, "swapped (" .. note .. ")"
end

local function revert_all()
    local n = 0
    for _, s in ipairs(R.swapped) do
        pcall(function()
            s.mesh:call("set_Enabled", false)
            if s.old then s.mesh:call("setMesh", s.old) end
            if s.used_custom_material and s.old_mat then
                local restored = pcall(function()
                    s.mesh:call("set_Material", s.old_mat)
                end)
                if not restored then
                    pcall(function() s.mesh:call("setMaterial", s.old_mat) end)
                end
            end
            s.mesh:call("set_Enabled", true)
        end)
        if s.old then pcall(function() s.old:release() end) end
        if s.old_mat then pcall(function() s.old_mat:release() end) end
        n = n + 1
    end
    R.swapped = {}
    return n
end

-- ----------------------------------------------------------------------- UI
re.on_frame(function()
    if C.armed and not R.failed then
        if not resources_ready() then
            warm()
        elseif tostring(R.status):find("warm%-up") then
            R.status = C.use_custom_material and "mesh + white coat READY"
                or "pegasus mesh READY (stock material)"
        end
    end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("IRIS - Pegasus mesh test") then return end
    local ch
    if not C.armed then
        _, C.use_custom_material = imgui.checkbox(
            "Use custom white coat material", C.use_custom_material)
        if C.use_custom_material then
            imgui.text_colored("Requires a white-coat package; a missing resource can CTD.",
                0xFF66AAFF)
        end
    else
        imgui.text("material: " .. (C.use_custom_material and "custom white coat" or "stock Griffin"))
    end
    ch, C.armed = imgui.checkbox("Arm (only after the pak is installed)", C.armed)
    if ch and C.armed then R.failed = false; R.status = "arming"; warm() end
    imgui.text("status: " .. tostring(R.status))
    imgui.text("swapped bodies: " .. tostring(#R.swapped))
    if R.last ~= "" then imgui.text("last: " .. R.last) end
    if imgui.button("Swap ALL griffins in scene") then
        local g = griffins()
        if #g == 0 then R.last = "no griffin found in scene"
        else
            local okn, msg = 0, ""
            for _, go in ipairs(g) do
                local ok, m = swap(go)
                if ok then okn = okn + 1 else msg = m end
            end
            R.last = string.format("%d/%d swapped %s", okn, #g, msg)
        end
        log(R.last)
    end
    if imgui.button("Revert all") then
        R.last = "reverted " .. revert_all(); log(R.last)
    end
    if imgui.button("Count griffins") then
        R.last = "griffins found: " .. #griffins(); log(R.last)
    end
    if imgui.button("Probe first griffin (materials)") then
        local g = griffins()
        R.last = (#g == 0) and "no griffin found" or probe(g[1])
        log(R.last)
    end
    if R.scan and R.scan ~= "" then
        imgui.text_colored("scanned: " .. R.scan, 0xFF9999FF)
    end
    imgui.tree_pop()
end)

log("loaded (disarmed). Tick Arm in the REFramework UI once the pak is installed.")
