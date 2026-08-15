-- IrisUnicornPhotoProbe.lua -------------------------------------------------------
-- READ-ONLY diagnostic for "the unicorn goes invisible in photo mode and slowly
-- fades back in afterwards" (Aurora, 2026-08-15).
--
-- Established already, so the probe does NOT re-test these:
--   * NOT the reshaped mesh -- its bounding sphere/box were compared against the
--     v2.0 mesh and are correctly centred and LARGER (v2.0's bbox did not even
--     enclose the horn tip), so frustum culling cannot have worsened.
--   * NOT scale collapse -- the sparkle is re-glued to the horn joint every tick
--     and sits at normal head height while she is invisible.
--   * NOT camera-proximity fade -- Aurora moved the camera around and it persisted.
--
-- "Slowly reappeared" means an alpha ramp, so this samples the things that can
-- produce one: the Mesh component's enabled/draw flags, the transform scale, and
-- the material float params that drive dither/dissolve/camera-fade on
-- Character_Enemy_Default. Writes one CSV line per sample so the photo-mode
-- entry/exit shows up as a step change in whichever column is guilty.
--
-- ⛔ Nothing here writes to the game. It only reads.
---------------------------------------------------------------------------------

local MOD = "IrisUnicornPhotoProbe"
local LOG = "IrisUnicornPhotoProbe.csv"
local PERIOD = 0.25

local C = { logging = false }
local R = { next_at = 0, lines = {}, started = 0, last = "" }

local FLOATS = {
    "DitherFadeRate", "DitherFadeRate2", "DissolveRate", "DecayRate",
    "CameraFade_Start", "CameraFade_End", "Inhale_DitherFade", "Inhale_Rate",
    "Decay_Transition", "Corruption_DecayRate",
}

local function valid(o)
    if not o then return false end
    local ok, res = pcall(function() return o:get_reference_count() end)
    return ok and res ~= nil
end

local function get_component(go, name)
    if not valid(go) then return nil end
    local c
    pcall(function() c = go:call("getComponent(System.Type)",
        sdk.typeof(name)) end)
    return valid(c) and c or nil
end

-- murmur3 is what getMaterialVariableIndex keys on; IrisWildCats proves the shape.
local function mat_float(mesh, mat_idx, name)
    local v
    pcall(function()
        local idx = mesh:call("getMaterialVariableIndex", mat_idx,
            sdk.murmur_hash.calc32(name))
        if idx and idx >= 0 then
            v = mesh:call("getMaterialFloat", mat_idx, idx)
        end
    end)
    return v
end

-- ⛔ 08-15: the original hand-rolled scene walk (descend to get_Child, else get_Next)
-- NEVER BACKTRACKS at a dead end, so it walks one spine of the tree and finds nothing.
-- Read IrisWildHorses' own live table instead.
local function unicorn_bodies()
    local out = {}
    local api = rawget(_G, "__iris_wild_horses_api")
    local WH = rawget(_G, "__iris_wild_horses_v1")
    if not (WH and type(WH.horses) == "table") then
        return out, "IrisWildHorses state not loaded"
    end
    for _, st in pairs(WH.horses) do
        local go = st and st.game_object
        if valid(go) then
            local isu = false
            if api and api.is_unicorn then
                pcall(function() isu = api.is_unicorn(go) == true end)
            end
            if isu then out[#out + 1] = go end
        end
    end
    return out, nil
end

local function paused()
    local p = false
    pcall(function()
        local m = sdk.get_managed_singleton("app.PauseManager")
        if m and m:call("isPausedAny") == true then p = true end
    end)
    if not p then
        pcall(function()
            local gui = sdk.get_managed_singleton("app.GuiManager")
            if gui and (gui:call("get_IsDispPhotoModeAll") == true
                or gui:call("get_IsDispPhotoMode") == true) then p = true end
        end)
    end
    return p
end

local function sample()
    local bodies, why = unicorn_bodies()
    if why then R.last = why; return end
    if #bodies == 0 then R.last = "no unicorn in scene"; return end
    local go = bodies[1]
    local mesh = get_component(go, "via.render.Mesh")
    if not mesh then R.last = "no via.render.Mesh"; return end

    local t = string.format("%.2f", os.clock() - R.started)
    local row = { t, paused() and "PHOTO" or "play" }

    local en, draw, matnum = "?", "?", "?"
    pcall(function() en = tostring(mesh:call("get_Enabled")) end)
    pcall(function() draw = tostring(mesh:call("get_DrawSelf")) end)
    pcall(function() matnum = tostring(mesh:call("get_MaterialNum")) end)
    row[#row + 1] = en; row[#row + 1] = draw; row[#row + 1] = matnum

    local sx = "?"
    pcall(function()
        local tf = go:call("get_Transform")
        local s = tf and tf:call("get_LocalScale")
        if s then sx = string.format("%.3f", s.x) end
    end)
    row[#row + 1] = sx

    for _, n in ipairs(FLOATS) do
        local v = mat_float(mesh, 0, n)
        row[#row + 1] = (v == nil) and "-" or string.format("%.3f", v)
    end
    local line = table.concat(row, ",")
    R.lines[#R.lines + 1] = line
    R.last = line
end

re.on_frame(function()
    if not C.logging then return end
    local now = os.clock()
    if now < R.next_at then return end
    R.next_at = now + PERIOD
    pcall(sample)
end)

re.on_draw_ui(function()
    if not imgui.collapsing_header("IRIS - Unicorn photo-mode probe") then return end
    imgui.text("READ-ONLY. Start logging, enter photo mode, wait ~5s,")
    imgui.text("exit, wait for her to fade back, then Save.")
    local changed, value = imgui.checkbox("Logging", C.logging)
    if changed then
        C.logging = value
        if value then
            R.started = os.clock()
            R.lines = { "t,state,enabled,drawself,materials,scale,"
                .. table.concat(FLOATS, ",") }
        end
    end
    imgui.text("samples: " .. tostring(math.max(#R.lines - 1, 0)))
    imgui.text("last: " .. tostring(R.last))
    if imgui.button("Save CSV") then
        local ok = pcall(function()
            json.dump_file(LOG .. ".json", R.lines)
        end)
        R.last = ok and ("wrote data/" .. LOG .. ".json") or "save failed"
    end
end)

log.info("[" .. MOD .. "] loaded (read-only probe)")
