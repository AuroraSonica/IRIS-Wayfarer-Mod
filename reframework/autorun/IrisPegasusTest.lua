--[[--------------------------------------------------------------------------
IRIS - Pegasus mesh test harness                                    2026-08-11

Loads `character/ch/ch53_000/pegasus.mesh` (shipped by IRIS_09_pegasus.pak) and
swaps it onto ONE live griffin, per-instance. Wild griffins are untouched unless
you press the button. Nothing here is automatic.

FIRST-TEST SCOPE: mesh only, paired with the STOCK ch53_000.mdf2. The exported
mesh reproduces the vanilla 25-material table in the vanilla ORDER, so the live
material resource still resolves and no set_Material call is needed - which is
the safest possible swap (see notes below). Colours will therefore be the
GRIFFIN'S textures sampled through the pegasus UVs, i.e. scrambled. That is
EXPECTED for this build; it proves load + skin + animate. The white coat needs a
custom mdf2 + .tex, which is the next step.

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

local MESH_PATH  = "character/ch/ch53_000/pegasus.mesh"
local WARM_GATE  = 15.0      -- seconds of streaming before a holder may be built
local LOGTAG     = "[IrisPegasus] "

local C = { armed = false }
local R = {
    res = nil, holder = nil, warm_at = nil, failed = false,
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

-- ---------------------------------------------------------------- resources
local function warm()
    if R.failed or not C.armed then return false end
    if valid(R.holder) then return true end
    if not R.res then
        local ok = pcall(function()
            local res = sdk.create_resource("via.render.MeshResource", MESH_PATH)
            if res then res:add_ref(); R.res = res; R.warm_at = os.clock() end
        end)
        if not ok or not R.res then
            R.failed = true
            R.status = "resource NIL - is IRIS_09_pegasus.pak installed?"
            log(R.status); return false
        end
        log("pegasus mesh pinned; streaming (" .. WARM_GATE .. "s gate)")
    end
    local age = os.clock() - (R.warm_at or 0)
    if age < WARM_GATE then
        R.status = string.format("streaming %.0fs / %.0fs", age, WARM_GATE)
        return false
    end
    pcall(function()
        local h = R.res:create_holder("via.render.MeshResourceHolder")
        if h then h:add_ref(); R.holder = h end
    end)
    if valid(R.holder) then R.status = "pegasus mesh READY" else R.status = "holder build failed" end
    log(R.status)
    return valid(R.holder)
end

-- ------------------------------------------------------------------ griffins
local function griffins()
    local out = {}
    local mgr = sdk.get_managed_singleton("app.CharacterManager")
    if not mgr then return out end
    local ok = pcall(function()
        local list = mgr:call("get_EnemyContexts") or mgr:call("getEnemyList")
        if not list then return end
        local n = list:call("get_Count")
        for i = 0, (n or 0) - 1 do
            local e = list:call("get_Item", i)
            local go = e and (e:call("get_GameObject") or e)
            if go then
                local nm = go:call("get_Name")
                if nm and tostring(nm):find("ch253") then out[#out+1] = go end
            end
        end
    end)
    if not ok or #out == 0 then
        -- fallback: sweep the scene for a GameObject named ch253*
        pcall(function()
            local scn = sdk.call_native_func(
                sdk.get_native_singleton("via.SceneManager"),
                sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
            if not scn then return end
            local all = scn:call("findGameObjects(System.String)", "ch253")
            if not all then return end
            local n = all:call("get_Count") or 0
            for i = 0, n - 1 do out[#out+1] = all:call("get_Item", i) end
        end)
    end
    return out
end

local function find_mesh(go)
    local m = get_component(go, "via.render.Mesh")
    if m then return m end
    local t = go:call("get_Transform")
    if not t then return nil end
    local child = t:call("get_Child")
    while child do
        local cgo = child:call("get_GameObject")
        local cm = cgo and get_component(cgo, "via.render.Mesh")
        if cm then return cm end
        child = child:call("get_Next")
    end
    return nil
end

local function swap(go)
    if not valid(R.holder) then return false, "holder not ready" end
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

    local old = nil
    pcall(function() old = mesh:call("getMesh") or mesh:call("get_Mesh") end)
    pcall(function() mesh:call("set_Enabled", false) end)
    local ok, err = pcall(function() mesh:call("setMesh", R.holder) end)
    pcall(function() mesh:call("set_Enabled", true) end)

    if not ok then
        if old then
            pcall(function() mesh:call("set_Enabled", false) end)
            pcall(function() mesh:call("setMesh", old) end)
            pcall(function() mesh:call("set_Enabled", true) end)
        end
        -- a holder built from a warmed pinned resource that still throws is stale:
        -- drop the HOLDER only, never the pinned resource (dropping it restarts the
        -- ~12 s stream from zero and you can never win the race)
        R.holder = nil
        return false, "setMesh threw: " .. tostring(err) .. " | " .. note
    end
    R.swapped[#R.swapped+1] = { go = go, old = old, mesh = mesh }
    return true, "swapped (" .. note .. ")"
end

local function revert_all()
    local n = 0
    for _, s in ipairs(R.swapped) do
        pcall(function()
            s.mesh:call("set_Enabled", false)
            if s.old then s.mesh:call("setMesh", s.old) end
            s.mesh:call("set_Enabled", true)
        end)
        n = n + 1
    end
    R.swapped = {}
    return n
end

-- ----------------------------------------------------------------------- UI
re.on_frame(function()
    if C.armed and not R.failed and not valid(R.holder) then warm() end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("IRIS - Pegasus mesh test") then return end
    local ch
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
    imgui.tree_pop()
end)

log("loaded (disarmed). Tick Arm in the REFramework UI once the pak is installed.")
