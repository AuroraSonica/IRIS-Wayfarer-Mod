-- IrisHorseStepProbe.lua ----------------------------------------------------------
-- "Something won't let my horse/unicorn move past this point on the bridge unless
--  I jump" (Aurora, 2026-08-15).
--
-- ⭐ The tell is JUMPING CLEARS IT. A wall cannot be jumped through, so the blocker
-- is LOW: either a lip/step taller than the doe chassis' step height, or the bridge
-- deck not registering as ground so the mover refuses to walk onto nothing.
-- Those two look identical from the saddle and need opposite fixes, so measure first.
--
-- What this does, at the spot where she is stuck:
--   1. samples GROUND HEIGHT every 0.2 m forward from the horse, out to 3.5 m
--      -> a LIP shows as a sudden positive step in the profile
--      -> a NON-REGISTERING DECK shows as a chasm (huge drop / no hit)
--   2. dumps via.physics.CharacterController's properties on the horse, so the
--      measured step can be compared against the controller's actual limit
--
-- Uses route3_cast_ground_below from GriffinRideProbe (the ONE proven ground
-- primitive). ⛔ Its contract: x/z RENDER space, y UNIVERSAL in and out, and it
-- keeps the HIGHEST contact at or below (start + 1.0) -- so the start height is
-- "how high can something be and still count as ground". Started LOW on purpose.
--
-- ⛔ READ-ONLY. Nothing here writes to the game.
---------------------------------------------------------------------------------

local MOD = "IrisHorseStepProbe"
local R = { lines = {}, last = "not run" }

local function valid(o)
    if not o then return false end
    local ok, res = pcall(function() return o:get_reference_count() end)
    return ok and res ~= nil
end

local function get_component(go, name)
    if not valid(go) then return nil end
    local c
    pcall(function()
        c = go:call("getComponent(System.Type)", sdk.typeof(name))
    end)
    return valid(c) and c or nil
end

-- ⛔ 08-15 THE FIRST VERSION FOUND NOTHING ("no IRIS horse found near you", even while
-- riding). It walked the scene as: descend to get_Child, else get_Next -- which never
-- BACKTRACKS when a branch dead-ends, so it only ever walks one spine of the tree and
-- misses nearly every object. Do not hand-roll scene walks.
-- ⭐ IrisWildHorses already publishes its live bodies: the global `__iris_wild_horses_v1`
-- holds `.horses[key].game_object` for every converted horse/unicorn. Read that.
local function horse_body()
    local WH = rawget(_G, "__iris_wild_horses_v1")
    if not (WH and type(WH.horses) == "table") then
        return nil, "IrisWildHorses state not loaded (__iris_wild_horses_v1.horses)"
    end
    local player
    pcall(function()
        player = sdk.get_managed_singleton("app.CharacterManager")
            :call("get_ManualPlayer")
    end)
    local pp
    if valid(player) then
        pcall(function() pp = player:call("get_Transform"):call("get_Position") end)
    end
    local best, bestd, seen = nil, 1e9, 0
    for _, st in pairs(WH.horses) do
        local go = st and st.game_object
        if valid(go) then
            seen = seen + 1
            local p
            pcall(function() p = go:call("get_Transform"):call("get_Position") end)
            if p then
                local d = pp and math.sqrt((p.x - pp.x) ^ 2 + (p.y - pp.y) ^ 2
                    + (p.z - pp.z) ^ 2) or 0.0
                if d < bestd then best, bestd = go, d end
            end
        end
    end
    if not best then
        return nil, string.format("no live horse in __iris_wild_horses_v1.horses (%d entries)", seen)
    end
    return best, nil, bestd, seen
end

local function run()
    R.lines = {}
    local function put(s) R.lines[#R.lines + 1] = s; log.info("[" .. MOD .. "] " .. s) end

    local cast = rawget(_G, "route3_cast_ground_below")
    local yoff_fn = rawget(_G, "route3_y_space_offset")
    if not cast then R.last = "route3_cast_ground_below missing (is GriffinRideProbe loaded?)"; return end

    local go, why, dist, seen = horse_body()
    if not go then R.last = why; put(tostring(why)); return end
    put(string.format("found horse %.2f m away (%d live in the horses table)",
        tonumber(dist) or -1, tonumber(seen) or -1))
    local tf = go:call("get_Transform")
    local p = tf:call("get_Position")
    local az = tf:call("get_AxisZ")
    local fx, fz = az.x, az.z
    local fl = math.sqrt(fx * fx + fz * fz)
    if fl < 1e-4 then R.last = "no forward axis"; return end
    fx, fz = fx / fl, fz / fl
    local yoff = 0.0
    pcall(function() if yoff_fn then yoff = tonumber(yoff_fn()) or 0.0 end end)
    local uy = p.y + yoff                      -- render -> universal for the cast

    put(string.format("horse at render(%.2f, %.2f, %.2f) fwd(%.2f, %.2f) yoff=%.3f",
        p.x, p.y, p.z, fx, fz, yoff))

    -- GROUND PROFILE AHEAD. Start the ray LOW (uy + 1.0) so a railing or an arch
    -- overhead cannot be mistaken for the deck (the canopy law).
    put("dist_m,ground_y,delta_from_horse,step_from_prev")
    local prev = nil
    for i = -2, 17 do
        local d = i * 0.2
        local sx, sz = p.x + fx * d, p.z + fz * d
        local hit = cast(sx, uy + 1.0, sz, 1.5, 12.0)
        local gy = hit and tonumber(hit.y) or nil
        local rel = gy and (gy - uy) or nil
        local step = (gy and prev) and (gy - prev) or nil
        put(string.format("%.1f,%s,%s,%s", d,
            gy and string.format("%.3f", gy) or "NO_HIT",
            rel and string.format("%+.3f", rel) or "-",
            step and string.format("%+.3f", step) or "-"))
        prev = gy or prev
    end

    -- CharacterController limits, to compare the measured step against
    local cc = get_component(go, "via.physics.CharacterController")
    if not cc then
        put("via.physics.CharacterController: NOT FOUND on the horse")
    else
        put("-- via.physics.CharacterController --")
        pcall(function()
            local td = sdk.find_type_definition("via.physics.CharacterController")
            for _, m in ipairs(td:get_methods()) do
                local n = m:get_name()
                if n:sub(1, 4) == "get_" and m:get_num_params() == 0 then
                    local ok2, v = pcall(function() return cc:call(n) end)
                    if ok2 and (type(v) == "number" or type(v) == "boolean") then
                        put(string.format("  %s = %s", n, tostring(v)))
                    end
                end
            end
        end)
    end
    R.last = "done -- " .. tostring(#R.lines) .. " lines (also in the REFramework log)"
end

re.on_draw_ui(function()
    if not imgui.collapsing_header("IRIS - Horse step probe (bridge)") then return end
    imgui.text("Ride to the spot where the horse WILL NOT walk forward,")
    imgui.text("stop facing the blocked direction, then press Measure.")
    imgui.text("READ-ONLY.")
    if imgui.button("Measure ahead") then pcall(run) end
    imgui.same_line()
    if imgui.button("Save JSON") then
        local ok = pcall(function() json.dump_file("IrisHorseStepProbe.json", R.lines) end)
        R.last = ok and "wrote data/IrisHorseStepProbe.json" or "save failed"
    end
    imgui.text("status: " .. tostring(R.last))
    for i = 1, math.min(#R.lines, 30) do imgui.text(R.lines[i]) end
end)

log.info("[" .. MOD .. "] loaded (read-only)")
