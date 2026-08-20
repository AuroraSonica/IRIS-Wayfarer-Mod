-- IrisSkelProbe.lua -- read-only skeleton probe. Answers ONE question:
-- when we swap a custom mesh onto a creature, does the engine take the joint
-- set from OUR mesh, or does it remap our bones onto the host prefab's joints?
--
-- WHY A BASE-POSE READ AND NOT A LIVE ONE: the motlist bakes a CONSTANT
-- translation key for every bone on every frame (measured 08-19 -- e.g.
-- L_FrontLeg_Upper holds (0.1445, 0.0004, 0.0004) for all 65 frames of the
-- walk). So the animation overwrites live local positions with the RABBIT's
-- bone offsets regardless of what our mesh declares. Live positions therefore
-- prove nothing. Only the BASE (bind) pose is decisive.
--
-- This script writes nothing and touches no game state. Safe to leave loaded.

local PROBE = {
    -- Rabbit ch99_200 reference offsets, read straight out of the shipped
    -- motlist's constant translation tracks. If the engine is honouring our
    -- mesh's skeleton, a cat-proportioned build must NOT match these.
    rabbit = {
        ["L_FrontLeg_Upper"] = { 0.1445, 0.0004, 0.0004 },
        ["L_FrontLeg_Lower"] = { 0.0871, 0.0000, 0.0091 },
        ["L_RearLeg_Upper"]  = { 0.0754, -0.0108, -0.0742 },
        ["L_RearLeg_Lower"]  = { 0.1682, 0.0011, -0.0050 },
        ["Spine_3"]          = { 0.0790, 0.0006, -0.0009 },
        ["Neck_0"]           = { 0.0160, -0.0052, -0.0018 },
        ["Head_0"]           = { 0.0015, 0.0689, 0.0656 },
        ["Tail"]             = { 0.0010, -0.0768, -0.1761 },
    },
    order = { "Spine_3", "Neck_0", "Head_0", "Tail",
              "L_FrontLeg_Upper", "L_FrontLeg_Lower",
              "L_RearLeg_Upper", "L_RearLeg_Lower" },
    -- a creature carrying these is on the rabbit rig
    signature = { "L_FrontLeg_Upper", "Tail", "Head_0" },
    last = {},
    api = "(not probed yet)",
    found = 0,
}

local function try(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

-- Which getter actually exists on a joint?  Probed once, reported in the UI so
-- the API question is settled without spending a game restart.
local GETTERS = { "get_BaseLocalPosition", "get_BasePosition",
                  "get_LocalPosition", "get_Position" }

local function read_joint(joint)
    local out = {}
    for _, name in ipairs(GETTERS) do
        local v = try(function() return joint:call(name) end)
        if v and v.x then out[name] = { v.x, v.y, v.z } end
    end
    return out
end

local function rabbit_rigged(go)
    local tf = try(function() return go:call("get_Transform") end)
    if not tf then return nil end
    for _, bone in ipairs(PROBE.signature) do
        if not try(function() return tf:call("getJointByName", bone) end) then
            return nil
        end
    end
    return tf
end

local function characters()
    local out = {}
    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm then return out end
    local scene = try(function()
        return sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"),
                                    "get_CurrentScene")
    end)
    if not scene then return out end
    local list = try(function()
        return scene:call("findComponents(System.Type)", sdk.typeof("app.Character"))
    end)
    if not list then return out end
    local n = try(function() return list:get_size() end) or 0
    for i = 0, n - 1 do
        local c = try(function() return list:get_Item(i) end)
        local go = c and try(function() return c:call("get_GameObject") end)
        if go then out[#out + 1] = go end
    end
    return out
end

local function delta(a, b)
    local d = 0.0
    for i = 1, 3 do d = math.max(d, math.abs((a[i] or 0) - (b[i] or 0))) end
    return d
end

-- WHICH MESH IS ACTUALLY BOUND?  Identical probe numbers could mean either
-- "engine ignored our skeleton" or "our mesh never loaded" -- and those need
-- opposite fixes.  The Stray build has 3 submeshes/materials where the old W3
-- cat had 1, so the material count alone separates them.
local function mesh_report(go)
    local mesh = try(function() return go:call("getComponent",
        sdk.typeof("via.render.Mesh")) end)
    if not mesh then return { error = "no via.render.Mesh component" } end
    local out = {}
    for _, getter in ipairs({ "get_MaterialNum", "get_MaterialCount",
                              "get_NumMaterials", "get_MeshMaterialNum" }) do
        local v = try(function() return mesh:call(getter) end)
        if type(v) == "number" then out[getter] = v end
    end
    local res = try(function() return mesh:call("get_Mesh") end)
    if res then
        for _, getter in ipairs({ "get_ResourcePath", "get_Path", "ToString" }) do
            local v = try(function() return res:call(getter) end)
            if type(v) == "string" and #v > 0 then out[getter] = v end
        end
        local vcount = try(function() return res:call("get_VertexCount") end)
        if type(vcount) == "number" then out.get_VertexCount = vcount end
    else
        out.mesh_resource = "get_Mesh returned nil"
    end
    return out
end

function PROBE.run()
    PROBE.last = {}
    PROBE.found = 0
    local apis = {}
    for _, go in ipairs(characters()) do
        local tf = rabbit_rigged(go)
        if tf then
            PROBE.found = PROBE.found + 1
            local name = try(function() return go:call("get_Name") end) or "?"
            local rows = { name = tostring(name), mesh = mesh_report(go) }
            for _, bone in ipairs(PROBE.order) do
                local joint = try(function() return tf:call("getJointByName", bone) end)
                if joint then
                    local vals = read_joint(joint)
                    for k in pairs(vals) do apis[k] = true end
                    rows[bone] = vals
                end
            end
            PROBE.last[#PROBE.last + 1] = rows
        end
    end
    local names = {}
    for k in pairs(apis) do names[#names + 1] = k end
    table.sort(names)
    PROBE.api = #names > 0 and table.concat(names, ", ") or "NONE of the candidates exist"
    log.info("[IrisSkelProbe] rabbit-rigged bodies: " .. tostring(PROBE.found)
             .. " | joint getters available: " .. PROBE.api)
    for _, rows in ipairs(PROBE.last) do
        for k, v in pairs(rows.mesh or {}) do
            log.info(string.format("[IrisSkelProbe] %s MESH %-22s %s",
                                   rows.name, k, tostring(v)))
        end
        for _, bone in ipairs(PROBE.order) do
            local vals = rows[bone]
            if vals then
                for getter, v in pairs(vals) do
                    local ref = PROBE.rabbit[bone]
                    local verdict = ""
                    if ref then
                        local d = delta(v, ref)
                        verdict = string.format("  |rabbit-delta %.4f m %s", d,
                                                d < 0.005 and "== RABBIT" or "!= rabbit")
                    end
                    log.info(string.format("[IrisSkelProbe] %s %-18s %-22s (%.4f, %.4f, %.4f)%s",
                        rows.name, bone, getter, v[1], v[2], v[3], verdict))
                end
            end
        end
    end
end

re.on_draw_ui(function()
    if not imgui.tree_node("Iris SKELETON PROBE") then return end
    imgui.text("Read-only. Answers: does a swapped mesh bring its own skeleton?")
    imgui.text("Joint getters found: " .. PROBE.api)
    imgui.text("Rabbit-rigged bodies last scan: " .. tostring(PROBE.found))
    if imgui.button("Probe skeleton now") then PROBE.run() end
    imgui.text("Results also go to the REFramework log.")
    for _, rows in ipairs(PROBE.last) do
        if imgui.tree_node(tostring(rows.name)) then
            imgui.text("-- BOUND MESH (3 materials = Stray build, 1 = old W3 cat) --")
            for k, v in pairs(rows.mesh or {}) do
                imgui.text(string.format("   %-22s %s", k, tostring(v)))
            end
            imgui.text("-- JOINTS --")
            for _, bone in ipairs(PROBE.order) do
                local vals = rows[bone]
                if vals then
                    for getter, v in pairs(vals) do
                        local ref = PROBE.rabbit[bone]
                        local tag = ""
                        if ref then
                            local d = delta(v, ref)
                            tag = string.format("   [%s %.4f]",
                                d < 0.005 and "RABBIT" or "not-rabbit", d)
                        end
                        imgui.text(string.format("%-18s %-22s %.4f, %.4f, %.4f%s",
                            bone, getter, v[1], v[2], v[3], tag))
                    end
                end
            end
            imgui.tree_pop()
        end
    end
    imgui.tree_pop()
end)

log.info("[IrisSkelProbe] loaded (read-only)")
