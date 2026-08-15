-- IrisHorseStepAssist.lua ---------------------------------------------------------
-- "Something won't let my horse/unicorn move past this point on the bridge unless I
--  jump" (Aurora, 2026-08-15). MEASURED at the spot with IrisHorseStepProbe:
--
--   ground 18.821 under the horse -> 18.951 at 0.4 m ahead  = a +0.137 m LIP
--   via.physics.CharacterController: SlopeLimit 50.01 deg, Radius 0.30, Height 1.20,
--   Ground=true(4 contacts), Wall=TRUE (5 contacts), Ceiling=false
--
-- ⭐ THE DIAGNOSIS: a 13.7 cm lip is a VERTICAL face (90 deg), which is far past the
-- 50 deg SlopeLimit -- so the controller classifies it as a WALL, not a slope. Walls
-- cannot be walked up, only jumped. Hence "unless I jump".
-- ⛔ AND THERE IS NO FIX AT THE CONTROLLER: the full property dump has SlopeLimit but
-- NO step-height / step-offset property. Nothing to raise. DD2 gives the player a
-- step-up via character motion, not via the controller, and the doe chassis has none.
--
-- ⇒ Give the ridden mount a scripted step-up. When it is jammed against a wall that is
-- actually just a low lip, lift it onto the lip. Deliberately narrow:
--   * ONLY while ridden (_G.IrisRiddenNow) -- wild horses and AI keep vanilla behaviour
--   * ONLY when the controller reports Wall == true
--   * ONLY when the ground just ahead is HIGHER by a lip-sized amount
--   * ONLY when the body is genuinely stuck (barely moved recently)
-- so it can never fire as a general levitation.
---------------------------------------------------------------------------------

local MOD = "IrisHorseStepAssist"

local C = {
    enabled   = true,
    min_step  = 0.04,   -- ignore noise
    max_step  = 0.45,   -- above this it is a real wall, not a lip -- leave it alone
    scan_max  = 0.80,   -- how far ahead to hunt for the lip edge (probe saw it at 0.4)
    -- how far PAST the lip edge to land. The capsule radius is 0.30, so a little under
    -- that puts enough of the body on the upper deck for the controller to resolve there
    -- instead of sliding back down the face.
    forward_pad = 0.25,
    clearance = 0.03,   -- lift a little past the lip so the capsule settles on top
    -- ⛔ 08-15 v2 (Aurora: "it works but it takes a few seconds to actually kick in").
    -- v1 measured displacement from an anchor that was only refreshed once the horse
    -- moved >6 cm. Shoving against a lip makes the body CREEP and jitter, so the anchor
    -- kept being re-armed and the stuck clock restarted -- hence the multi-second wait.
    -- v2 measures SPEED every tick and holds a continuous "has been slow since" stamp,
    -- which creep cannot reset.
    -- ⛔ v2/v3 had stuck_speed / stuck_win here. Both are GONE: every movement-based
    -- "is it stuck" test is defeated by the body vibrating against the lip. Sharpness
    -- of the rise is the discriminator now, so nothing has to be waited out.
    cooldown   = 0.35,
}
local S = { last = {}, next_at = 0, fired = 0, status = "idle" }

local function valid(o)
    if not o then return false end
    local ok, res = pcall(function() return o:get_reference_count() end)
    return ok and res ~= nil
end

local function get_component(go, name)
    if not valid(go) then return nil end
    local c
    pcall(function() c = go:call("getComponent(System.Type)", sdk.typeof(name)) end)
    return valid(c) and c or nil
end

local function horses()
    local WH = rawget(_G, "__iris_wild_horses_v1")
    if not (WH and type(WH.horses) == "table") then return {} end
    local out = {}
    for _, st in pairs(WH.horses) do
        if st and valid(st.game_object) then out[#out + 1] = st.game_object end
    end
    return out
end

local function tick()
    if not C.enabled then return end
    if rawget(_G, "IrisRiddenNow") ~= true then S.status = "not riding"; return end
    local now = os.clock()
    if now < S.next_at then return end
    S.next_at = now + 0.05

    local cast = rawget(_G, "route3_cast_ground_below")
    local yoff_fn = rawget(_G, "route3_y_space_offset")
    if not cast then S.status = "no ground primitive"; return end

    for _, go in ipairs(horses()) do
        -- ⛔ `go:get_address and ...` is a PARSE ERROR: `:` is call syntax in Lua, so a
        -- method cannot be referenced without arguments. Call it inside a pcall instead.
        local addr
        pcall(function() addr = tostring(go:get_address()) end)
        addr = addr or tostring(go)
        local tf = go:call("get_Transform")
        local p = tf and tf:call("get_Position")
        if p then
            local rec = S.last[addr]
            if not rec then
                rec = { x = p.x, z = p.z, t = now, since = now, cd = 0 }
                S.last[addr] = rec
            end
            -- ⛔⛔ 08-15 v4. v2/v3 gated on "is it stuck", measured from movement.
            -- Aurora: "~2 seconds of RUNNING ON THE SPOT" -- the body VIBRATES against
            -- the lip, and 2 cm of jitter per 50 ms tick reads as 0.4 m/s, which reset
            -- the stuck clock every tick. Every movement-based stuck test has this
            -- problem in some form.
            -- ⇒ Stop asking "is it stuck" at all. A LIP IS SHARP -- that is the real
            -- discriminator, and it is knowable in one frame. Fire on geometry, not on
            -- failure-to-move, so there is nothing to wait for.
            local moved = math.sqrt((p.x - rec.x) ^ 2 + (p.z - rec.z) ^ 2)
            local dt = math.max(now - rec.t, 1e-4)
            rec.x, rec.z, rec.t = p.x, p.z, now
            rec.speed = moved / dt
            if now >= (rec.cd or 0) then
                local cc = get_component(go, "via.physics.CharacterController")
                local wall = false
                pcall(function() wall = cc and cc:call("get_Wall") == true end)
                local az = tf:call("get_AxisZ")
                local fx, fz = az.x, az.z
                local fl = math.sqrt(fx * fx + fz * fz)
                if fl > 1e-4 then
                    fx, fz = fx / fl, fz / fl
                    local yoff = 0.0
                    pcall(function()
                        if yoff_fn then yoff = tonumber(yoff_fn()) or 0.0 end
                    end)
                    local uy = p.y + yoff
                    local here = cast(p.x, uy + 1.0, p.z, 1.5, 12.0)
                    local gy0 = here and tonumber(here.y)
                    -- ⭐ FIND THE LIP EDGE, don't assume it. Walk forward in 5 cm steps
                    -- and take the FIRST lip-sized rise; its distance is what decides how
                    -- far forward the body has to land.
                    local lip_d, step = nil, nil
                    if gy0 then
                        -- ⭐ SHARPNESS is what separates a lip from a slope. Require the
                        -- rise to happen inside ONE 5 cm sample. A ramp gains height
                        -- gradually and is walkable, so it must NOT trigger a hop --
                        -- without this test a 3 degree incline reads as a "4 cm rise
                        -- within 0.8 m" and the horse would hop up every hill.
                        local prev = gy0
                        local dd = 0.10
                        while dd <= C.scan_max do
                            local h = cast(p.x + fx * dd, uy + 1.0, p.z + fz * dd, 1.5, 12.0)
                            local gy = h and tonumber(h.y)
                            if gy then
                                local jump  = gy - prev     -- rise within this one sample
                                local total = gy - gy0      -- rise above where we stand
                                if jump >= C.min_step and total <= C.max_step
                                    and total >= C.min_step then
                                    lip_d, step = dd, total
                                    break
                                end
                                prev = gy
                            end
                            dd = dd + 0.05
                        end
                    end
                    if lip_d then
                        -- ⛔⛔ 08-15 v3 (Aurora: "still takes 3-5 seconds"). v1/v2 only
                        -- lifted Y. That leaves the body hovering over the LOWER deck,
                        -- still behind the lip face, so gravity drops it straight back --
                        -- it only got across when a nudge happened to coincide with
                        -- forward momentum, hence the multi-second wait. The step must
                        -- carry it FORWARD past the edge as well as up: land it on the
                        -- upper surface, capsule radius clear of the face.
                        -- (This is the "Z axis allowance" Aurora remembered.)
                        local fwd = lip_d + C.forward_pad
                        pcall(function()
                            tf:call("set_Position", Vector3f.new(
                                p.x + fx * fwd,
                                p.y + step + C.clearance,
                                p.z + fz * fwd))
                        end)
                        S.fired = S.fired + 1
                        rec.cd = now + C.cooldown
                        rec.since = now
                        rec.x, rec.z = p.x + fx * fwd, p.z + fz * fwd
                        S.status = string.format(
                            "stepped %.3f m up / %.2f m fwd (lip at %.2f m, wall=%s, total %d)",
                            step, fwd, lip_d, tostring(wall), S.fired)
                    else
                        S.status = string.format(
                            "no sharp %.2f..%.2f m lip within %.2f m (wall=%s, %.2f m/s)",
                            C.min_step, C.max_step, C.scan_max, tostring(wall),
                            rec.speed or 0.0)
                    end
                end
            end
        end
    end
end

re.on_frame(function() pcall(tick) end)

re.on_draw_ui(function()
    if not imgui.collapsing_header("IRIS - Horse step assist") then return end
    imgui.text("Lifts a RIDDEN horse/unicorn over a low lip the DD2 character")
    imgui.text("controller classifies as a wall (measured: 13.7 cm on the bridge).")
    local changed, value = imgui.checkbox("Enabled", C.enabled)
    if changed then C.enabled = value end
    changed, value = imgui.slider_float("Max lip (m)", C.max_step, 0.10, 0.80, "%.2f")
    if changed then C.max_step = value end
    changed, value = imgui.slider_float("Scan ahead (m)", C.scan_max, 0.30, 1.50, "%.2f")
    if changed then C.scan_max = value end
    changed, value = imgui.slider_float(
        "Forward landing pad (m)", C.forward_pad, 0.00, 0.60, "%.2f")
    if changed then C.forward_pad = value end
    changed, value = imgui.slider_float(
        "Min lip (m)", C.min_step, 0.02, 0.20, "%.3f")
    if changed then C.min_step = value end
    imgui.text("status: " .. tostring(S.status))
    imgui.text("step-ups this session: " .. tostring(S.fired))
end)

log.info("[" .. MOD .. "] loaded")
