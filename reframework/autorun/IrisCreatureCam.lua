-- IrisCreatureCam.lua -- frames the ACTIVE TAMED companion for the "Customize" screen.
-- Ported from RiftSpeakCreatorCamera: post-hooks app.MainCameraController.lateUpdate so our
-- camera pose holds each frame. Subject = the active companion (iris_active_go, main mod).
-- Distance/height scale with the creature's species (no bounding-box API exists in DD2, so
-- per-species constants -- confirmed by research). Camera-only: never writes the creature.

local CAM = {
    on = false,
    dist = 3.2, height = 0.7, aim_drop = 0.0,
    orbit_deg = 0, elev_deg = 10,
    fwd_sign = 1, zfwd = -1, rsign = 1,
    hooked = false, info = "idle",
    manual = false,   -- true once the user drags, so species auto-fit stops overriding
}

-- per-species framing (front distance, aim height above the ground point, elevation angle)
local SIZE = {
    Griffin = { dist = 7.5, height = 2.3, elev = 12 },
    Wolf    = { dist = 3.2, height = 0.7, elev = 10 },
    Dog     = { dist = 2.7, height = 0.6, elev = 10 },
    Crow    = { dist = 1.3, height = 0.35, elev = 8 },
    Bird    = { dist = 1.3, height = 0.35, elev = 8 },
    Bat     = { dist = 1.3, height = 0.35, elev = 8 },
    Doe     = { dist = 3.6, height = 0.9, elev = 10 },
    Goat    = { dist = 2.7, height = 0.7, elev = 10 },
    Chicken = { dist = 1.4, height = 0.35, elev = 8 },
    Saurian = { dist = 3.6, height = 0.9, elev = 10 },
    Goblin  = { dist = 3.0, height = 1.1, elev = 8 },
    -- small ground critters: close + low so you can actually see them (Aurora)
    Rabbit  = { dist = 0.9, height = 0.18, elev = 9 },
    Rat     = { dist = 0.7, height = 0.13, elev = 8 },
    Seabird = { dist = 1.3, height = 0.35, elev = 8 },
    Drake   = { dist = 7.5, height = 2.3, elev = 12 },
    Ox      = { dist = 5.0, height = 1.6, elev = 11 },
}
-- fallback for any UNLISTED creature: frame close (most untamed criters are small); big ones are listed.
local SIZE_DEFAULT = { dist = 1.5, height = 0.35, elev = 9 }

local function type_name(nm)
    nm = tostring(nm or "")
    if nm:find("ch253", 1, true) then return "Griffin" end
    if nm:find("ch223001", 1, true) then return "Dog" end
    if nm:find("ch223", 1, true) then return "Wolf" end
    if nm:find("ch299410", 1, true) then return "Crow" end
    if nm:find("ch299430", 1, true) then return "Bird" end
    if nm:find("ch299400", 1, true) then return "Bat" end
    if nm:find("ch299011", 1, true) then return "Doe" end
    if nm:find("ch299020", 1, true) then return "Goat" end
    if nm:find("ch299221", 1, true) then return "Chicken" end
    if nm:find("ch221", 1, true) then return "Saurian" end
    if nm:find("ch220", 1, true) then return "Goblin" end
    return "Creature"
end

-- ===== math =====
local function norm3(x, y, z)
    local l = math.sqrt(x * x + y * y + z * z)
    if l < 1e-6 then return 0, 0, 1 end
    return x / l, y / l, z / l
end
local function cross(ax, ay, az, bx, by, bz)
    return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
end

-- the framed GameObject: an explicit override (the scout-drone bird) wins; otherwise the main
-- mod's active companion. NEVER repoint iris_active_go itself -- other systems read that global.
local function subject_go()
    if CAM.override_go and CAM.override_go.call then return CAM.override_go end
    local g = nil
    pcall(function() if iris_active_go then g = iris_active_go() end end)
    if g and g.call then return g end
    return nil
end

local function go_name(go)
    local n = "?"
    pcall(function() n = go:call("get_Name") end)
    return tostring(n or "?")
end

local function subject_pos(go)
    -- render-space world position of the creature (the camera works in render space)
    local p = nil
    pcall(function() p = go:call("get_Transform"):call("get_Position") end)
    return p
end
local function subject_forward(go)
    local fx, fz = 0, 1
    pcall(function()
        local q = go:call("get_Transform"):call("get_Rotation")
        fx = 2 * (q.x * q.z + q.w * q.y)
        fz = 1 - 2 * (q.x * q.x + q.y * q.y)
    end)
    return fx, fz
end

local function cam_xform()
    local cam = sdk.get_primary_camera(); if not cam then return nil end
    local xf; pcall(function() xf = cam:call("get_GameObject"):call("get_Transform") end); return xf
end
local function set_pos(xf, x, y, z)
    pcall(function() local p = xf:call("get_Position"); p.x = x; p.y = y; p.z = z; xf:call("set_Position", p) end)
end
local function set_rot(xf, x, y, z, w)
    pcall(function() local q = xf:call("get_Rotation"); q.x = x; q.y = y; q.z = z; q.w = w; xf:call("set_Rotation", q) end)
end

local function autofit(go)
    -- use the species framing if listed, else the SMALL fallback (a rabbit/rat kept the far griffin
    -- default before = you couldn't see them). Always applies so switching creatures re-frames cleanly.
    local t = SIZE[type_name(go_name(go))] or SIZE_DEFAULT
    CAM.dist = t.dist; CAM.height = t.height; CAM.elev_deg = t.elev
end

-- ===== framing (camera only), applied in the lateUpdate post-hook =====
local function apply_camera()
    local go = subject_go(); if not go then CAM.info = "no active companion"; return end
    local base = subject_pos(go); if not base then CAM.info = "no subject pos"; return end
    local aim = { x = base.x, y = base.y + CAM.height - CAM.aim_drop, z = base.z }
    -- orbit basis: a FORCED heading (the scout's travel direction) decouples the camera from the
    -- bird's own model rotation -- otherwise the cam is welded to whichever way the bird is turned,
    -- so turning the bird also turns the cam and left/right can never be made correct. With a
    -- forced heading the cam is always relative to travel; the bird facing is an independent knob.
    local rfx, rfz
    if CAM.forced_yaw ~= nil then rfx, rfz = math.sin(CAM.forced_yaw), math.cos(CAM.forced_yaw)
    else rfx, rfz = subject_forward(go) end
    rfx, rfz = rfx * CAM.fwd_sign, rfz * CAM.fwd_sign
    local nl = math.sqrt(rfx * rfx + rfz * rfz); if nl < 1e-6 then rfx, rfz, nl = 0, 1, 1 end
    rfx, rfz = rfx / nl, rfz / nl
    local th = math.rad(CAM.orbit_deg); local cs, sn = math.cos(th), math.sin(th)
    local dx = rfx * cs - rfz * sn
    local dz = rfx * sn + rfz * cs
    local el = math.rad(CAM.elev_deg or 0)
    local hd = CAM.dist * math.cos(el)
    local cx = aim.x + dx * hd
    local cy = aim.y + CAM.dist * math.sin(el)
    local cz = aim.z + dz * hd
    local fx, fy, fz = norm3(aim.x - cx, aim.y - cy, aim.z - cz)
    fx, fy, fz = fx * CAM.zfwd, fy * CAM.zfwd, fz * CAM.zfwd
    local rx, ry, rz = cross(0, 1, 0, fx, fy, fz)
    local rl = math.sqrt(rx * rx + ry * ry + rz * rz); if rl < 1e-6 then rx, ry, rz, rl = 1, 0, 0, 1 end
    rx, ry, rz = rx / rl * CAM.rsign, ry / rl * CAM.rsign, rz / rl * CAM.rsign
    local ux, uy, uz = cross(fx, fy, fz, rx, ry, rz)
    local m00, m01, m02 = rx, ux, fx
    local m10, m11, m12 = ry, uy, fy
    local m20, m21, m22 = rz, uz, fz
    local qx, qy, qz, qw
    local tr = m00 + m11 + m22
    if tr > 0 then
        local s = math.sqrt(tr + 1.0) * 2
        qw = 0.25 * s; qx = (m21 - m12) / s; qy = (m02 - m20) / s; qz = (m10 - m01) / s
    elseif m00 > m11 and m00 > m22 then
        local s = math.sqrt(1.0 + m00 - m11 - m22) * 2
        qw = (m21 - m12) / s; qx = 0.25 * s; qy = (m01 + m10) / s; qz = (m02 + m20) / s
    elseif m11 > m22 then
        local s = math.sqrt(1.0 + m11 - m00 - m22) * 2
        qw = (m02 - m20) / s; qx = (m01 + m10) / s; qy = 0.25 * s; qz = (m12 + m21) / s
    else
        local s = math.sqrt(1.0 + m22 - m00 - m11) * 2
        qw = (m10 - m01) / s; qx = (m02 + m20) / s; qy = (m12 + m21) / s; qz = 0.25 * s
    end
    local xf = cam_xform(); if not xf then CAM.info = "no camera"; return end
    set_pos(xf, cx, cy, cz)
    set_rot(xf, qx, qy, qz, qw)
    CAM.info = string.format("framing %s", type_name(go_name(go)))
end

-- hook so our pose holds (runs right after the controller each frame)
do
    local ok = pcall(function()
        local td = sdk.find_type_definition("app.MainCameraController")
        local m = td and td:get_method("lateUpdate")
        if m then
            sdk.hook(m, function() end, function(retval)
                if CAM.on then pcall(apply_camera) end
                return retval
            end)
            CAM.hooked = true
        end
    end)
    if not ok then CAM.hooked = false end
end

-- also apply in on_frame so the framing HOLDS even when the world is frozen (the customize
-- screen pauses the game, which can halt MainCameraController.lateUpdate)
re.on_frame(function()
    if CAM.on then pcall(apply_camera) end
end)

-- ===== public API (the Customize panel drives this) =====
_G.IrisCreatureCam = {
    set_on = function(on)
        local go = subject_go()
        if on and not go then CAM.info = "no active companion to frame"; return false end
        if on and not CAM.manual then autofit(go) end   -- fit the frame to the species
        if on and not CAM.override_go then CAM.orbit_deg = 0 end   -- don't clobber the scout's chase orbit
        CAM.on = (on == true)
        return CAM.on
    end,
    is_on = function() return CAM.on end,
    orbit = function(d) CAM.orbit_deg = (CAM.orbit_deg + (tonumber(d) or 0)) % 360; CAM.manual = true end,
    zoom = function(d) CAM.dist = math.max(0.15, CAM.dist + (tonumber(d) or 0)); CAM.manual = true end,   -- lower floor so you can zoom right into tiny critters (Aurora)
    reset_fit = function() CAM.manual = false; local go = subject_go(); if go then autofit(go) end end,
    info = function() return CAM.info end,
    -- SCOUT DRONE: frame an explicit target (the flying bird) instead of the active companion
    set_target = function(go)
        CAM.override_go = (go and go.call) and go or nil
        if CAM.override_go then
            -- a CHASE view. Camera orbits the FORCED travel heading (set_heading each frame), so
            -- orbit_deg=180 = behind the travel = a true chase, independent of the bird's facing.
            CAM.dist = 2.8; CAM.height = 0.45; CAM.elev_deg = 16.0; CAM.orbit_deg = 180; CAM.manual = true; CAM.forced_yaw = nil
        end
        return CAM.override_go ~= nil
    end,
    -- the scout feeds the bird's TRAVEL heading here every frame; the camera orbits THIS, not the
    -- bird's model rotation (which the model-face offset would otherwise fight)
    set_heading = function(y) CAM.forced_yaw = tonumber(y) end,
    -- right-stick free-look during scout: orbit yaw around the bird + pitch the elevation
    nudge = function(dyaw, delev)
        if not CAM.override_go then return end
        CAM.orbit_deg = (CAM.orbit_deg + (tonumber(dyaw) or 0.0)) % 360
        CAM.elev_deg = math.max(-35.0, math.min(80.0, (CAM.elev_deg or 0.0) + (tonumber(delev) or 0.0)))
        CAM.manual = true
    end,
    clear_target = function() CAM.override_go = nil; CAM.manual = false; CAM.orbit_deg = 0; CAM.elev_deg = 10; CAM.forced_yaw = nil end,
    get_target = function() return CAM.override_go end,
}

-- optional dev tree (framing tuning) -- lives under its own collapsed node
re.on_draw_ui(function()
    if not imgui.tree_node("I.R.I.S. creature camera") then return end
    imgui.text(CAM.hooked and "lateUpdate hook: ACTIVE" or "lateUpdate hook: FAILED")
    local was = CAM.on
    _, CAM.on = imgui.checkbox("frame the active companion", CAM.on)
    if CAM.on ~= was then _G.IrisCreatureCam.set_on(CAM.on) end
    _, CAM.dist = imgui.drag_float("distance", CAM.dist, 0.05, 0.5, 15.0)
    _, CAM.height = imgui.drag_float("aim height", CAM.height, 0.02, -1.0, 4.0)
    _, CAM.orbit_deg = imgui.drag_float("orbit deg", CAM.orbit_deg, 1.0, -180.0, 180.0)
    _, CAM.elev_deg = imgui.drag_float("elevation deg", CAM.elev_deg, 0.5, -40.0, 60.0)
    if imgui.button("re-fit to species") then _G.IrisCreatureCam.reset_fit() end
    imgui.text(tostring(CAM.info))
    imgui.tree_pop()
end)
