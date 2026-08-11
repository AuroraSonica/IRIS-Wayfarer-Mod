-- IrisMeshCollision.lua - EXACT-GEOMETRY player collision for the forged farmhouse (2026-07-21).
--
-- ⭐ ROUTE A, PROVEN by IrisMeshGraftProbe: a gm05_043 gimmick chassis is player-solid via its
-- collider[0] - which is a Layer-1 via.physics.MeshShape. set_Resource() it to ANY loaded _e.mcol
-- and the player collides with that exact geometry instantly. (Routes B set_Shape and C setColliders
-- transplant ALSO proven - spares if ever needed.)
--
-- Per standing house piece: spawn one invisible chassis at the piece's transform (position + yaw),
-- steal the piece's own loaded mcol holder (its collider[1] MeshShape resource), graft into the
-- chassis collider[0], register. Walls, slanted roof, pergola, tables - everything - gets its REAL
-- collision. Supersedes IrisHouseCollision.lua (oriented boxes) entirely.
--
-- DOOR EXCLUDED (sm80_252): grafting it would seal the doorway. The working door will be a door
-- GIMMICK (e.g. gm51_389) placed in the frame - next build step.
--
-- Needs _G.IrisForge (IrisHouseForge.lua) with piece_collision(). Run ADD after the house is BUILT
-- and streaming has settled (never concurrently - crash law). Log: IRIS/mesh_collision_log.txt

local M = {}

local CHASSIS_ID = 16
local CHASSIS_PATH = "AppSystem/Gimmick/Prefab/BarTest/gm05_043.pfb"
local SPAWN_SIG = "requestCreateInstance(app.PrefabController, app.GenerateInfo.GenerateInfoContainer, "
    .. "System.Int32, app.InstanceInfo, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>, "
    .. "System.Action`2<app.PrefabInstantiateResults,app.DummyArg>)"
local CONCURRENT = 4   -- 2026-08-10: conservative 3->4 trial; shared chassis removes per-job prefab churn

-- pieces that must NOT be solid (id prefix match): the door leaf - else the doorway seals
local SKIP_PREFIX = { "sm80_252" }
local DOOR_PIECE_PREFIX = "sm80_252"   -- the forged door leaf: its transform anchors the gimmick door

-- real DOOR gimmicks (native open/close interact) to stand in the frame. ids = Nick's SelectedGimmickID.
local DOORS = {
    { label = "gm05_046 - Door (single)",        id = 74,  path = "AppSystem/Gimmick/Prefab/Door/gm05_046.pfb" },
    { label = "gm05_047 - Door (single)",        id = 76,  path = "AppSystem/Gimmick/Prefab/Door/gm05_047.pfb" },
    { label = "gm05_063 - Door (single)",        id = 77,  path = "AppSystem/Gimmick/Prefab/Door/gm05_063.pfb" },
    { label = "gm80_031 - Door (single)",        id = 88,  path = "AppSystem/Gimmick/Prefab/Door/gm80_031.pfb" },
    { label = "gm80_085 - Door (single)",        id = 92,  path = "AppSystem/Gimmick/Prefab/Door/gm80_085.pfb" },
    { label = "gm80_123 - Door (single)",        id = 105, path = "AppSystem/Gimmick/Prefab/Door/gm80_123.pfb" },
    { label = "gm51_389 - Double door",          id = 111, path = "AppSystem/Gimmick/Prefab/Door/gm51_389.pfb" },
}
M.door_idx = 4         -- gm80_031 = Aurora's pick (2026-07-21); PHYSICS door (push, no prompt)
M.door_yaw = 180.0     -- extra yaw (deg) on top of the frame's rotation (Aurora's fitted value)
M.door_slide = 1.30    -- along-the-wall nudge (m) - Aurora's fitted value 2026-07-21
M.door_out = 0.07      -- out-of-the-wall nudge (m) - Aurora's fitted value
M.door_up = 0.0        -- height nudge (m)
M.door_autoclose = true -- physics door can't latch: when the player walks away, snap it back to its
                        -- seated closed pose (re-place at the fitted numbers - proven, invisible)
M.door_hide_forged = true   -- hide the forged (ghost) door leaf when the gimmick stands in
local door_rig = nil   -- { go, ux, uy, uz }
local door_hold = nil  -- door job held until the collision rigs finish + a breather (cold-load law)
local door_pfb = {}    -- via.Prefab cache per door path (auto-close respawns must not re-create)
local door_near = false -- auto-close edge trigger: snaps when you cross from near to far
local door_ac_f = 0

M.last = "(idle) - build the house (forge/homestead), wait for it to finish, then ADD MESH COLLISION"

local pending, active = {}, {}   -- graft jobs
local rigs = {}                  -- live { go, id, ux, uy, uz }
local retained = {}              -- stolen holders + refs: NEVER release (dangling-resource CTD law)

local function _log(s)
    pcall(function()
        local f = io.open("IRIS/mesh_collision_log.txt", "a")
        if f then f:write("[" .. os.date("%H:%M:%S") .. "] " .. tostring(s) .. "\n"); f:close() end
    end)
    pcall(function() if _G.IrisFlight then _G.IrisFlight.note("collision: " .. tostring(s)) end end)
end
local function _pos(x, y, z)
    local v = ValueType.new(sdk.find_type_definition("via.Position")); v.x, v.y, v.z = x or 0, y or 0, z or 0; return v
end
local function _player()
    local pl; pcall(function() local cm = sdk.get_managed_singleton("app.CharacterManager"); pl = cm and cm:call("get_ManualPlayer") end); return pl
end
local function _rp() local p, pl = nil, _player(); if pl then pcall(function() p = pl:call("get_GameObject"):call("get_Transform"):call("get_Position") end) end; return p end
local function _up() local p, pl = nil, _player(); if pl then pcall(function() p = pl:call("get_GameObject"):call("get_Transform"):call("get_UniversalPosition") end) end; return p end
local function _colliders(go)
    local pc; pcall(function() pc = go:call("getComponent(System.Type)", sdk.typeof("via.physics.Colliders")) end); return pc
end
local function _hide_tree(go, depth)
    if not go or (depth or 0) > 6 then return end
    pcall(function() go:call("set_DrawSelf", false) end)
    for _, tn in ipairs({ "via.render.Mesh", "via.render.CompositeMesh" }) do
        pcall(function() local mc = go:call("getComponent(System.Type)", sdk.typeof(tn)); if mc then mc:call("set_DrawSelf", false) end end)
    end
    pcall(function()
        local tf = go:call("get_Transform"); local child = tf and tf:call("get_Child")
        while child do local cgo = child:call("get_GameObject"); if cgo then _hide_tree(cgo, (depth or 0) + 1) end; child = child:call("get_Next") end
    end)
end
local function _skip(id)
    for _, p in ipairs(SKIP_PREFIX) do
        if id and id:sub(1, #p) == p then return true end
    end
    return false
end

-- the PROVEN route-A graft: steal piece col[1] holder -> chassis col[0] MeshShape set_Resource -> register
local function _graft(chassis_go, piece_go, id)
    local ppc = _colliders(piece_go)
    if not ppc then return false, "piece Colliders gone" end
    local holder, path
    local ok, err = pcall(function()
        local sh = ppc:call("getCollider", 1):call("get_Shape")
        path = sh:call("get_ResourcePath")
        holder = sh:call("get_Resource"):add_ref()
        pcall(function() holder:add_ref_permanent() end)   -- survive Reset Scripts (GC-release CTD)
    end)
    if not holder then return false, "holder steal failed: " .. tostring(err) end
    retained[#retained + 1] = holder
    local pc = _colliders(chassis_go)
    if not pc then return false, "chassis Colliders gone" end
    local gok, gerr = pcall(function()
        local c0 = pc:call("getCollider", 0)
        c0:call("get_Shape"):call("set_Resource", holder)
        pcall(function() c0:call("set_UpdateShape", true) end)
        pcall(function() c0:call("updateCollisionFilter") end)
        pcall(function() c0:call("updateBroadphase", true) end)
        pcall(function() pc:call("set_Static", true) end)
        pcall(function() pc:call("updatePose") end)
        pcall(function() pc:call("updateBroadphase") end)
    end)
    if not gok then return false, "graft failed: " .. tostring(gerr) end
    pcall(function() chassis_go:call("set_Name", "IrisRig_" .. tostring(id)) end)   -- adoptable post-reset
    pcall(_make_unbreakable, chassis_go)   -- pcall'd: protection must never abort the hide below
    _hide_tree(chassis_go, 0)
    _log("grafted " .. tostring(id) .. " <- " .. tostring(path))
    return true
end

local _remove_door, _build_door_job   -- forward decls: _add uses them; defined in the door section below
local _make_unbreakable               -- forward decl: _graft uses it; defined in the door section below
local _reuse_pool                     -- forward decl: pooled rigs can satisfy _add without regeneration
                                      -- (⛔ 2nd time this trap fired: luac can't catch nil-global calls)

local function _add()
    if (#rigs > 0 and not M.pooled) or #pending > 0 or #active > 0 then M.last = "collision already placed - REMOVE ALL first"; return end
    if not (_G.IrisForge and _G.IrisForge.piece_collision) then M.last = "IrisHouseForge not loaded (or old version w/o piece_collision)"; return end
    local st = _G.IrisForge.status and _G.IrisForge.status()
    if st and st.building then M.last = "house still building - wait for it to finish (streaming crash law)"; return end
    local pieces = _G.IrisForge.piece_collision()
    if not pieces or #pieces == 0 then M.last = "no house standing - build one first"; return end
    local rp, up = _rp(), _up()
    if not (rp and up) then M.last = "no player"; return end
    local Kx, Ky, Kz = up.x - rp.x, up.y - rp.y, up.z - rp.z   -- render -> universal
    -- FAST RETURN: a parked pool already owns the correct grafted MeshShapes. Validate every GO and
    -- every piece-id count, then move the rigs onto the newly visible house in one tick. Any doubt
    -- destroys the pool and falls through to the full proven generator below.
    if M.pooled and #rigs > 0 and _reuse_pool and _reuse_pool(pieces, Kx, Ky, Kz) then return end
    M.pool_verify_at, M.pool_reused_at = nil, nil
    -- Every rig uses the SAME gm05_043 prefab. The old route created and permanently retained 39
    -- identical via.Prefab handles per house. One ready handle can safely feed many independent
    -- PrefabControllers (the visual forge already instantiates repeated pieces this way).
    if not IrisCollisionChassisPrefab then
        pcall(function()
            IrisCollisionChassisPrefab = sdk.create_instance("via.Prefab"):add_ref()
            pcall(function() IrisCollisionChassisPrefab:add_ref_permanent() end)
            IrisCollisionChassisPrefab:set_Path(CHASSIS_PATH)
            pcall(function() IrisCollisionChassisPrefab:call("get_Ready") end)
        end)
        _log("CHASSIS CACHE: one permanent gm05_043 prefab created for all rigs")
    end
    M.collision_started_at, M.rigs_complete_logged, M.collision_complete_logged = os.clock(), false, false
    local doors = 0
    for _, p in ipairs(pieces) do
        if _skip(p.id) then
            doors = doors + 1
        else
            local px, rot
            pcall(function()
                local tf = p.go:call("get_Transform")
                px = tf:call("get_Position")
                rot = tf:call("get_Rotation")
            end)
            if px then
                pending[#pending + 1] = {
                    id = p.id, piece_go = p.go,
                    ux = px.x + Kx, uy = px.y + Ky, uz = px.z + Kz,
                    rot = rot and { x = rot.x, y = rot.y, z = rot.z, w = rot.w } or nil,
                    phase = "spawn", f = 0, prefab = IrisCollisionChassisPrefab,
                }
            end
        end
    end
    -- the working door is part of ADD but HELD until the rigs finish + a 2s breather (its pfb warms
    -- during the rig spawns) - one shot for the auto flow, but never a cold load in the hot tail
    _remove_door()
    local dj = _build_door_job()
    if dj then door_hold = dj end
    M.last = "grafting " .. #pending .. " jobs (" .. doors .. " ghost door skipped"
        .. (dj and ", real door queued)" or ", NO door job)") .. "..."
    _log(string.format("ADD: %d jobs queued (%d door-skipped%s), concurrency=%d shared-chassis=%s K(%.1f,%.1f,%.1f)",
        #pending, doors, dj and ", +door" or ", door FAILED", CONCURRENT,
        tostring(IrisCollisionChassisPrefab ~= nil), Kx, Ky, Kz))
end

-- find the forged door piece (its transform anchors the gimmick door)
local function _door_piece()
    if not (_G.IrisForge and _G.IrisForge.piece_collision) then return nil end
    for _, p in ipairs(_G.IrisForge.piece_collision() or {}) do
        if p.id and p.id:sub(1, #DOOR_PIECE_PREFIX) == DOOR_PIECE_PREFIX then return p end
    end
    return nil
end

_remove_door = function()
    if door_rig and door_rig.go then pcall(function() door_rig.go:call("destroy", door_rig.go) end) end
    door_rig, door_hold = nil, nil
end

-- build the door spawn-job from the current settings (shared by the manual button + auto ADD)
_build_door_job = function()
    local p = _door_piece()
    if not p then return nil, "no forged door piece standing (build the house first)" end
    local rp, up = _rp(), _up()
    if not (rp and up) then return nil, "no player" end
    local Kx, Ky, Kz = up.x - rp.x, up.y - rp.y, up.z - rp.z
    local px, rot
    pcall(function()
        local tf = p.go:call("get_Transform")
        px = tf:call("get_Position")
        rot = tf:call("get_Rotation")
    end)
    if not px then return nil, "door piece transform unreadable" end
    -- door-local nudges: rotate (slide, up, out) by the frame's yaw into world
    local sx, sy, sz = M.door_slide, M.door_up, M.door_out
    local wx, wy, wz = sx, sy, sz
    if rot then
        local qx, qy, qz, qw = rot.x, rot.y, rot.z, rot.w
        local tx = 2 * (qy * sz - qz * sy)
        local ty = 2 * (qz * sx - qx * sz)
        local tz = 2 * (qx * sy - qy * sx)
        wx = sx + qw * tx + (qy * tz - qz * ty)
        wy = sy + qw * ty + (qz * tx - qx * tz)
        wz = sz + qw * tz + (qx * ty - qy * tx)
    end
    local spec = DOORS[M.door_idx]
    -- extra yaw offset composed onto the frame rotation (yaw-only quats multiply cleanly)
    local half = math.rad(M.door_yaw) / 2
    local oy, ow = math.sin(half), math.cos(half)
    local frot = rot and { x = 0, y = rot.y * ow + rot.w * oy, z = 0, w = rot.w * ow - rot.y * oy }
        or { x = 0, y = oy, z = 0, w = ow }
    local job2 = {
        kind = "door", door_path = spec.path, door_id = spec.id, door_label = spec.label,
        piece_go = p.go,
        ux = px.x + wx + Kx, uy = px.y + wy + Ky, uz = px.z + wz + Kz,
        rot = frot, phase = "spawn", f = 0,
    }
    -- WARM the door pfb NOW (async load starts immediately; cached per path so auto-close respawns
    -- reuse it) - cold-loading at the tail of the auto sequence was a CTD suspect
    pcall(function()
        if not door_pfb[spec.path] then
            local pfb = sdk.create_instance("via.Prefab"):add_ref()
            pcall(function() pfb:add_ref_permanent() end)   -- survive Reset Scripts (GC-release CTD)
            pfb:set_Path(spec.path)
            door_pfb[spec.path] = pfb
        end
        job2.prefab = door_pfb[spec.path]
    end)
    return job2
end

-- the chassis is a BREAKABLE gimmick - the woodcut census (07-21 23:42) caught two rigs already
-- damaged (hp 252/1000): a monster could smash a hole in a wall's collision. Flip every rig (and
-- the door) to unbreakable via the gimmick-base API.
_make_unbreakable = function(go)
    -- belt AND braces: set_IsUnbreakable where it exists, AND disable the HitController outright
    -- (the rigs were STILL destructible after unbreakable-only - and a damaged gimmick re-draws
    -- its mesh, which is also how hidden "barrel tables" reappeared)
    local n = 0
    pcall(function()
        local arr = go:call("get_Components")
        local cnt = arr and arr:get_size() or 0
        for i = 0, (tonumber(cnt) or 0) - 1 do
            local c = arr:get_element(i)
            if c and pcall(function() c:call("set_IsUnbreakable", true) end) then n = n + 1 end
        end
    end)
    pcall(function()
        local hc = go:call("getComponent(System.Type)", sdk.typeof("app.HitController"))
        if hc then
            -- INTROSPECT, don't guess (blind set_field threw "invalid field" errors): call only the
            -- members the typedef actually declares, walking base types too
            -- THE REAL LEVERS (API-dumped 2026-07-22 00:30; Aurora called IsInvincible exactly):
            pcall(function() hc:call("set_IsInvincible", true) end)
            pcall(function() hc:call("set_IsDamageZero", true) end)
            pcall(function() hc:call("set_IsIgnoreDamageHit", true) end)
            pcall(function() hc:call("set_DamageCollisionOff", true) end)
            pcall(function() hc:call("set_DamageRate", 0.0) end)
            pcall(function() hc:call("set_Enabled", false) end)
            n = n + 100   -- marker: HC treatment applied
        end
    end)
    return n
end

-- the ghost leaf keeps its OBJECT collision even when hidden (hide = DrawSelf only) - the real door
-- swings closed into the invisible forged leaf and STOPS SHORT. Kill its colliders outright.
local function _disable_colliders(go, depth, count)
    -- via.physics.Colliders has NO set_Enabled (that guess failed SILENTLY in pcall). disable() is
    -- the real call. RECURSIVE: forged pieces come from a door TEMPLATE pfb whose leaf is a CHILD
    -- GameObject with its own colliders - root-only disable left the child leaf solid (round 2).
    count = count or { n = 0 }
    if not go or (depth or 0) > 6 then return count.n end
    pcall(function()
        local pc = go:call("getComponent(System.Type)", sdk.typeof("via.physics.Colliders"))
        if pc then pc:call("disable"); count.n = count.n + 1 end
    end)
    pcall(function()
        local tf = go:call("get_Transform"); local child = tf and tf:call("get_Child")
        while child do
            local cgo = child:call("get_GameObject")
            if cgo then _disable_colliders(cgo, (depth or 0) + 1, count) end
            child = child:call("get_Next")
        end
    end)
    if (depth or 0) == 0 then _log("ghost leaf colliders disable(): " .. count.n .. " components (tree)") end
    return count.n
end

-- LIVE fit: apply the current sliders to the STANDING door (no respawn) - position + rotation both
-- proven writable post-spawn. Makes hinge-hunting a 10-second job instead of respawn roulette.
local function _apply_fit_live()
    if not (door_rig and door_rig.go) then M.last = "no door standing - PLACE DOOR first"; return end
    local p = _door_piece()
    if not p then M.last = "no forged door piece (build the house first)"; return end
    local px, rot
    pcall(function()
        local tf = p.go:call("get_Transform")
        px = tf:call("get_Position")
        rot = tf:call("get_Rotation")
    end)
    if not px then M.last = "door piece transform unreadable"; return end
    local sx, sy, sz = M.door_slide, M.door_up, M.door_out
    local wx, wy, wz = sx, sy, sz
    if rot then
        local qx, qy, qz, qw = rot.x, rot.y, rot.z, rot.w
        local tx = 2 * (qy * sz - qz * sy)
        local ty = 2 * (qz * sx - qx * sz)
        local tz = 2 * (qx * sy - qy * sx)
        wx = sx + qw * tx + (qy * tz - qz * ty)
        wy = sy + qw * ty + (qz * tx - qx * tz)
        wz = sz + qw * tz + (qx * ty - qy * tx)
    end
    local half = math.rad(M.door_yaw) / 2
    local oy, ow = math.sin(half), math.cos(half)
    local frot = rot and { x = 0, y = rot.y * ow + rot.w * oy, z = 0, w = rot.w * ow - rot.y * oy }
        or { x = 0, y = oy, z = 0, w = ow }
    local ok = pcall(function()
        local tf = door_rig.go:call("get_Transform")
        local v = ValueType.new(sdk.find_type_definition("via.vec3"))
        v.x, v.y, v.z = px.x + wx, px.y + wy, px.z + wz
        tf:call("set_Position", v)
        local qt = ValueType.new(sdk.find_type_definition("via.Quaternion"))
        qt.x, qt.y, qt.z, qt.w = frot.x, frot.y, frot.z, frot.w
        tf:call("set_Rotation", qt)
    end)
    door_rig.rot = frot   -- keep the re-assert campaign aligned with the new fit
    M.last = ok and string.format("fit applied live: yaw=%.0f slide=%.2f out=%.2f up=%.2f",
        M.door_yaw, M.door_slide, M.door_out, M.door_up) or "live fit failed - see log"
    _log("DOOR live fit: " .. M.last)
end

local function _place_door()
    _remove_door()   -- re-place applies fresh settings
    local job2, err = _build_door_job()
    if not job2 then M.last = err or "door job failed"; return end
    pending[#pending + 1] = job2
    M.last = "placing door " .. job2.door_label .. " (yaw " .. M.door_yaw .. ")..."
    _log("DOOR place: " .. job2.door_label .. " yaw=" .. M.door_yaw
        .. string.format(" slide=%.2f out=%.2f up=%.2f", M.door_slide, M.door_out, M.door_up))
end

local function _remove_all()
    local n = 0
    for i = #rigs, 1, -1 do
        local r = rigs[i]
        if r and r.go then pcall(function() r.go:call("destroy", r.go) end); n = n + 1 end
        rigs[i] = nil
    end
    _remove_door()   -- the door is part of the shell: despawn takes it too
    pending, active, door_hold = {}, {}, nil
    M.pooled, M.pool_verify_at, M.pool_reused_at = false, nil, nil
    M.last = "removed " .. n .. " collision rigs + door"
end

-- Park completed collision below the current render frame instead of throwing away 39 expensive,
-- already-grafted gimmicks. Used only by Homestead despawn; the UI REMOVE ALL remains destructive.
-- Moving the Colliders pose + broadphase is the same native refresh used by the proven graft route.
local function _park_all()
    if #pending > 0 or #active > 0 or door_hold then
        _log("POOL PARK refused: collision still building -> hard remove")
        _remove_all()
        return false
    end
    if #rigs == 0 then _remove_door(); M.pooled, M.pool_verify_at = false, nil; return false end
    local rp = _rp()
    if not rp then _remove_all(); return false end
    _remove_door()   -- door is cheap and controller-driven; rebuild it fresh after pool reuse
    local moved = 0
    for i, r in ipairs(rigs) do
        local ok = pcall(function()
            r.go:call("get_Name")   -- validates that area unload has not killed the GO
            local tf = r.go:call("get_Transform")
            local v = ValueType.new(sdk.find_type_definition("via.vec3"))
            v.x, v.y, v.z = rp.x, rp.y - 5000.0 - i * 2.0, rp.z
            tf:call("set_Position", v)
            local pc = _colliders(r.go)
            if not pc then error("pooled rig has no Colliders") end
            pcall(function() pc:call("updatePose") end)
            pcall(function() pc:call("updateBroadphase") end)
            _hide_tree(r.go, 0)
            moved = moved + 1
        end)
        if not ok then break end
    end
    if moved ~= #rigs then
        _log(string.format("POOL PARK failed at %d/%d -> hard remove", moved, #rigs))
        _remove_all()
        return false
    end
    M.pooled, M.pool_verify_at = true, nil
    M.last = "parked " .. #rigs .. " collision rigs for instant return"
    _log("POOL PARK: " .. #rigs .. " rigs retained below world")
    return true
end

-- Rebind a validated parked pool to the current standing house. Duplicate ids are interchangeable:
-- each carries the same mesh resource, so matching within an id bucket is sufficient. We validate
-- the complete assignment before moving anything; a stale/dying scene object triggers full fallback.
_reuse_pool = function(pieces, Kx, Ky, Kz)
    local t0, buckets, assignments, wanted = os.clock(), {}, {}, 0
    for _, p in ipairs(pieces or {}) do
        if not _skip(p.id) then
            local px, rot
            pcall(function()
                local tf = p.go:call("get_Transform")
                px, rot = tf:call("get_Position"), tf:call("get_Rotation")
            end)
            if px then
                buckets[p.id] = buckets[p.id] or {}
                buckets[p.id][#buckets[p.id] + 1] = {
                    px = px, rot = rot and { x = rot.x, y = rot.y, z = rot.z, w = rot.w } or nil
                }
                wanted = wanted + 1
            end
        end
    end
    if wanted ~= #rigs then
        _log(string.format("POOL REUSE mismatch: house=%d pool=%d -> full build", wanted, #rigs))
        _remove_all()
        return false
    end
    for _, r in ipairs(rigs) do
        local bucket = buckets[r.id]
        local target = bucket and table.remove(bucket)
        local alive = false
        pcall(function() alive = r.go:call("get_Name") ~= nil and _colliders(r.go) ~= nil end)
        if not target or not alive then
            _log("POOL REUSE stale/missing rig " .. tostring(r.id) .. " -> full build")
            _remove_all()
            return false
        end
        assignments[#assignments + 1] = { rig = r, target = target }
    end
    local moved = 0
    for _, a in ipairs(assignments) do
        local ok = pcall(function()
            local tf, px, rot = a.rig.go:call("get_Transform"), a.target.px, a.target.rot
            local v = ValueType.new(sdk.find_type_definition("via.vec3"))
            v.x, v.y, v.z = px.x, px.y, px.z
            tf:call("set_Position", v)
            if rot then
                local q = ValueType.new(sdk.find_type_definition("via.Quaternion"))
                q.x, q.y, q.z, q.w = rot.x, rot.y, rot.z, rot.w
                tf:call("set_Rotation", q)
            end
            local pc = _colliders(a.rig.go)
            pc:call("set_Static", true)
            -- Moving the Colliders wrapper is not enough after a long park/rebase. Refresh the
            -- grafted collider itself as well; otherwise its GO can be alive while one MeshShape
            -- remains absent from the physics broadphase (observed as one walk-through wall).
            local c0 = pc:call("getCollider", 0)
            if c0 then
                pcall(function() c0:call("updateCollisionFilter") end)
                pcall(function() c0:call("updateBroadphase", true) end)
            end
            pc:call("updatePose")
            pc:call("updateBroadphase")
            a.rig.ux, a.rig.uy, a.rig.uz = px.x + Kx, px.y + Ky, px.z + Kz
            _make_unbreakable(a.rig.go)
            _hide_tree(a.rig.go, 0)
            moved = moved + 1
        end)
        if not ok then break end
    end
    if moved ~= #rigs then
        _log(string.format("POOL REUSE move failed at %d/%d -> full build", moved, #rigs))
        _remove_all()
        return false
    end
    M.pooled = false
    M.pool_verify_at = os.clock() + 5.0
    M.pool_reused_at = os.clock()
    M.collision_started_at, M.rigs_complete_logged, M.collision_complete_logged = os.clock(), true, false
    local dj = _build_door_job()
    if dj then pending[#pending + 1] = dj end   -- no 2s breather: no rig generation/load occurred
    M.last = "instant collision return: " .. moved .. " rigs reused" .. (dj and ", door finishing..." or "")
    _log(string.format("POOL REUSE: %d rigs repositioned in %.3fs%s", moved, os.clock() - t0,
        dj and ", warm door queued" or ", no door"))
    return true
end

-- pump: same staged pipeline as the boxes, but the shape phase does the route-A mesh graft
local rehide_f, rehide_bursts = 0, 0
local door_rot_f = 0
local rig_medic_f = 0
local pause_grace = 0
-- ⛔ PAUSE GUARD (2026-07-22): no spawn/graft/register steps while the world is paused - the
-- options menu can flip graphics settings (frame gen = device reset) mid-pipeline = CTD.
-- Flag names verified by the griffin pause probe (round 61).
local function _world_paused()
    local paused = false
    pcall(function()
        local pm = sdk.get_managed_singleton("app.PauseManager")
        if pm and pm:call("isPausedAny") == true then paused = true end
    end)
    if not paused then
        pcall(function()
            local gm = sdk.get_managed_singleton("app.GuiManager")
            if gm and (gm:call("get_IsDispPhotoModeAll") == true
                or gm:call("get_IsDispPhotoMode") == true
                or gm:call("isPausedGUI") == true) then paused = true end
        end)
    end
    return paused
end
re.on_application_entry("UpdateBehavior", function()
    if _world_paused() then pause_grace = os.clock() + 3.0; return end
    if os.clock() < pause_grace then return end
    -- A reused gimmick can remain callable briefly while its old scene is dying. Five seconds later,
    -- prove all pooled rigs survived; otherwise discard them and regenerate against the live house.
    if M.pool_verify_at and os.clock() >= M.pool_verify_at then
        M.pool_verify_at = nil
        local alive, refreshed = 0, 0
        for _, r in ipairs(rigs) do
            pcall(function()
                local pc = r.go:call("get_Name") and _colliders(r.go)
                if pc then
                    alive = alive + 1
                    -- Verification now proves registration work can still be issued, not merely
                    -- that the Lua wrapper exists. A second refresh five seconds after movement
                    -- also catches a MeshShape the streaming scene registered late.
                    pc:call("set_Static", true)
                    local c0 = pc:call("getCollider", 0)
                    if c0 then
                        pcall(function() c0:call("updateCollisionFilter") end)
                        pcall(function() c0:call("updateBroadphase", true) end)
                    end
                    pc:call("updatePose")
                    pc:call("updateBroadphase")
                    refreshed = refreshed + 1
                end
            end)
        end
        if alive == #rigs and refreshed == #rigs and alive > 0 then
            _log("POOL VERIFY: all " .. alive .. " reused rigs survived + broadphase refreshed")
        else
            _log(string.format("POOL VERIFY failed: %d/%d alive, %d refreshed -> automatic full collision rebuild",
                alive, #rigs, refreshed))
            _remove_all()
            _add()
        end
    end
    -- DOOR DEATH-WATCH (~1s): Aurora's inside-open bug - if the leaf GO DIES without us removing
    -- it (crushed against the wall chassis is the leading theory), log the smoking gun + respawn.
    door_watch_f = (door_watch_f or 0) + 1   -- _G on purpose (200-local cap)
    if door_watch_f >= 60 then
        door_watch_f = 0
        if door_rig and door_rig.go then
            local alive = pcall(function() return door_rig.go:call("get_Name") end)
            if not alive then
                _log("!! DOOR GO DIED unexpectedly (crushed by wall collision?) - respawning it")
                door_rig = nil
                _place_door()
            end
        end
    end
    -- RE-HIDE campaign: a single hide at graft time doesn't stick (the chassis mesh child streams in
    -- AFTER our hide under multi-spawn load -> visible "barrel tables"). Re-assert on all rigs ~1/s
    -- for ~30s after the last ADD, then stop (rigs are static; no need to walk forever).
    if #rigs > 0 and rehide_bursts > 0 then
        rehide_f = rehide_f + 1
        if rehide_f >= 60 then
            rehide_f = 0
            rehide_bursts = rehide_bursts - 1
            for _, r in ipairs(rigs) do if r.go then _hide_tree(r.go, 0) end end
        end
    end
    -- RIG MEDIC (~2s): even with every invincibility lever pulled, belt-and-braces - heal any rig
    -- that took damage back to full (setHp is API-proven), and SHOUT if one ever breaks (that's a
    -- collision hole; the log tells us invincibility still leaks and we escalate).
    rig_medic_f = rig_medic_f + 1
    if rig_medic_f >= 120 and #rigs > 0 then
        rig_medic_f = 0
        for _, r in ipairs(rigs) do
            pcall(function()
                if not r.go then return end
                if not r.brain then
                    local arr = r.go:call("get_Components")
                    local cn = arr and arr:get_size() or 0
                    for i = 0, (tonumber(cn) or 0) - 1 do
                        local c = arr:get_element(i)
                        if c and pcall(function() return c:call("getHp") end) then r.brain = c; break end
                    end
                end
                if not r.brain then return end
                -- protection is RE-ASSERTED, not one-shot (levers improved mid-session once already;
                -- standing rigs must always carry the newest protection without a rebuild)
                if not r.prot_at or os.clock() - r.prot_at > 10.0 then
                    r.prot_at = os.clock()
                    pcall(_make_unbreakable, r.go)
                end
                local broken = false
                pcall(function() broken = r.brain:call("get_IsBroken") == true end)
                if broken then
                    if not r.shouted then r.shouted = true; _log("!! RIG BROKEN: " .. tostring(r.id) .. " - collision hole; invincibility leaked") end
                    return
                end
                local hp = tonumber(r.brain:call("getHp")) or 0
                local mx = tonumber(r.brain:call("getMaxHp")) or 0
                if mx > 0 and hp < mx then
                    r.brain:call("setHp", mx)
                    _log("rig medic: healed " .. tostring(r.id) .. string.format(" %.0f->%.0f", hp, mx))
                end
            end)
        end
    end
    -- AUTO-CLOSE (~1/s): a physics door can't latch itself. When the player crosses from near (<4m)
    -- to far (>5.5m), re-place it at the fitted numbers = snaps to its seated closed pose while
    -- nobody's looking. Hysteresis stops thrash at the boundary.
    if door_rig and door_rig.go and M.door_autoclose then
        door_ac_f = door_ac_f + 1
        if door_ac_f >= 60 then
            door_ac_f = 0
            local up = _up()
            if up and door_rig.ux then
                local dx, dz = up.x - door_rig.ux, up.z - door_rig.uz
                local d2 = dx * dx + dz * dz
                -- ⛔ DEBOUNCE v2 (2026-07-22, Aurora's inside-the-house find): v1 counted FRAMES
                -- (~50ms = worthless) and the 5.5m far edge sits INSIDE the house - living in a
                -- room re-triggered the close every time. Now: far = 12m (properly outside/away)
                -- held for a continuous 2.0s wall-clock, absurd readings never count.
                if d2 < 16.0 then
                    door_near = true
                    door_far_since = nil   -- _G on purpose (200-local cap)
                elseif door_near and d2 > 256.0 and d2 < 1e10 then   -- 16m: the log proved 9m is still INSIDE the farmhouse - the far edge must clear the whole interior
                    door_far_since = door_far_since or os.clock()
                    if os.clock() - door_far_since >= 2.0 then
                        door_far_since = nil
                        door_near = false
                        -- distance logged: Aurora reports closes firing while she's still in the
                        -- area - the number convicts either the threshold or a position glitch
                        _log(string.format("DOOR auto-close (player walked away, d=%.1fm)", math.sqrt(d2)))
                        _place_door()
                    end
                else
                    door_far_since = nil
                end
            end
        end
    end
    -- door rotation re-assert campaign (~1/s while armed): the controller may fight set_Rotation
    if door_rig and door_rig.rot and door_rig.assert_until then
        if os.clock() >= door_rig.assert_until then
            door_rig.assert_until = nil
        else
            door_rot_f = door_rot_f + 1
            if door_rot_f >= 60 then
                door_rot_f = 0
                pcall(function()
                    local qt = ValueType.new(sdk.find_type_definition("via.Quaternion"))
                    qt.x, qt.y, qt.z, qt.w = door_rig.rot.x, door_rig.rot.y, door_rig.rot.z, door_rig.rot.w
                    door_rig.go:call("get_Transform"):call("set_Rotation", qt)
                end)
            end
        end
    end
    -- release the held door: rigs all done -> 2s breather -> spawn (pfb warmed during the rigs)
    if door_hold and #pending == 0 and #active == 0 then
        if not M.rigs_complete_logged then
            M.rigs_complete_logged = true
            _log(string.format("RIGS COMPLETE: %d in %.2fs", #rigs,
                M.collision_started_at and (os.clock() - M.collision_started_at) or 0))
        end
        door_hold.release_at = door_hold.release_at or (os.clock() + 2.0)
        if os.clock() >= door_hold.release_at then
            pending[#pending + 1] = door_hold
            _log("DOOR release: " .. tostring(door_hold.door_label) .. " (rigs done + breather)")
            door_hold = nil
        end
    end
    while #active < CONCURRENT and #pending > 0 do active[#active + 1] = table.remove(pending, 1) end
    if #active == 0 then return end
    rehide_bursts = 30   -- work in flight -> (re)arm the campaign
    for i = #active, 1, -1 do
        local q = active[i]
        local drop = false
        local ok, err = pcall(function()
            if q.phase == "spawn" then
                if not q.prefab then   -- door jobs arrive pre-warmed; chassis jobs load here
                    q.prefab = sdk.create_instance("via.Prefab"):add_ref()
                    pcall(function() q.prefab:add_ref_permanent() end)   -- survive Reset Scripts
                    q.prefab:set_Path(q.door_path or CHASSIS_PATH)
                end
                q.ctrl = sdk.create_instance("app.PrefabController"):add_ref()
                q.ctrl._Item = q.prefab
                local gi = sdk.create_instance("app.GenerateInfo.GenerateInfoContainer"):add_ref()
                local p = _pos(q.ux, q.uy, q.uz)
                gi._CommonInfo._InitialPosition = p
                gi._CommonInfo._ContextPosition = p
                -- ⛔⛔ NO _InitialAngle/_ContextAngle - EVER. On doors it CTDs (0/2 vs 4/4 without);
                -- on chassis it spawned fine but the one run that PROVED player-blocking (20:29) was
                -- WITHOUT it - angle-spawned gimmicks may init down a different path that breaks the
                -- graft. Everything spawns plain and rotates at the settle phase (the proven config).
                gi._CommonInfo._ObjectID._SelectedGimmickID = q.door_id or CHASSIS_ID
                q.gi = gi
                q.inst = sdk.create_instance("app.InstanceInfo"):add_ref()
                q.phase = "fire"; q.f = 0
            elseif q.phase == "fire" then
                q.f = q.f + 1
                if q.prefab:call("get_Ready") == true then
                    local m = sdk.find_type_definition("app.GenerateManager"):get_method(SPAWN_SIG)
                    m:call(sdk.get_managed_singleton("app.GenerateManager"), q.ctrl, q.gi, 0, q.inst, nil, nil)
                    q.phase = "wait"; q.f = 0
                elseif q.f > 600 then drop = true end
            elseif q.phase == "wait" then
                q.f = q.f + 1
                local go = q.inst["<Instance>k__BackingField"]
                if go then q.go = go; q.phase = "shape"; q.f = 0
                elseif q.f > 900 then drop = true end
            elseif q.phase == "shape" then
                q.f = q.f + 1
                if q.f >= 20 then   -- settle before mutating (same-tick = no-op law)
                    if q.rot then    -- match the piece's/frame's yaw BEFORE registering
                        pcall(function()
                            local qt = ValueType.new(sdk.find_type_definition("via.Quaternion"))
                            qt.x, qt.y, qt.z, qt.w = q.rot.x, q.rot.y, q.rot.z, q.rot.w
                            q.go:call("get_Transform"):call("set_Rotation", qt)
                        end)
                    end
                    if q.kind == "door" then
                        -- visible working door: no graft, no hide; optionally ghost the forged leaf.
                        -- rotation re-asserted for 10s in case the door controller fights set_Rotation
                        if M.door_hide_forged and q.piece_go then
                            _hide_tree(q.piece_go, 0)
                            _disable_colliders(q.piece_go)   -- else the real door closes INTO the ghost leaf
                            _log("DOOR: ghost leaf colliders disabled")
                        end
                        pcall(function() q.go:call("set_Name", "IrisDoor") end)   -- adoptable post-reset
                        local ub = _make_unbreakable(q.go)
                        _log("DOOR unbreakable set on " .. ub .. " components")
                        -- ⭐ SWING LIMITS (door probe 2026-07-22): gm80_031 is an app.Saloonlike
                        -- spring hinge with LimitMin/MaxDeg = ±90 - the "struggle" near the arc's
                        -- end is its own spring stop, no wall involved. Widen the limits.
                        pcall(function()
                            local lim = tonumber(M.door_limit_deg) or 130.0
                            local widened = 0
                            local function widen(go, depth)
                                if not go or depth > 3 then return end
                                pcall(function()
                                    local arr = go:call("get_Components")
                                    local n = 0
                                    pcall(function() n = arr:get_size() or 0 end)
                                    for i = 0, (tonumber(n) or 0) - 1 do
                                        pcall(function()
                                            local comp = arr:get_element(i)
                                            if comp:get_type_definition():get_field("LimitMaxDeg") then
                                                comp:set_field("LimitMinDeg", -lim)
                                                comp:set_field("LimitMaxDeg", lim)
                                                comp:set_field("LimitMin", -math.rad(lim))
                                                comp:set_field("LimitMax", math.rad(lim))
                                                widened = widened + 1
                                            end
                                        end)
                                    end
                                end)
                                pcall(function()
                                    local tf = go:call("get_Transform"); local ch = tf and tf:call("get_Child")
                                    while ch do widen(ch:call("get_GameObject"), depth + 1); ch = ch:call("get_Next") end
                                end)
                            end
                            widen(q.go, 0)
                            _log("DOOR swing limits widened to +/-" .. lim .. " deg on " .. widened .. " comps")
                        end)
                        door_rig = { go = q.go, rot = q.rot, assert_until = os.clock() + 10.0,
                                     ux = q.ux, uy = q.uy, uz = q.uz }
                        drop = true
                        M.last = "door placed - walk up and interact (fit with the sliders + RE-PLACE)"
                        _log("DOOR up")
                        if not M.collision_complete_logged then
                            M.collision_complete_logged = true
                            _log(string.format("COLLISION COMPLETE after %.2fs",
                                M.collision_started_at and (os.clock() - M.collision_started_at) or 0))
                        end
                    else
                        local gok, gerr = _graft(q.go, q.piece_go, q.id)
                        if not gok then _log("piece " .. tostring(q.id) .. ": " .. tostring(gerr)) end
                        rigs[#rigs + 1] = { go = q.go, id = q.id, ux = q.ux, uy = q.uy, uz = q.uz }
                        drop = true
                        M.last = "mesh collision: " .. #rigs .. " rigs down (" .. (#pending + #active - 1) .. " to go)"
                    end
                end
            end
        end)
        if not ok then _log("rig ERROR: " .. tostring(err)); drop = true end
        if drop then table.remove(active, i) end
    end
end)

_G.IrisCollision = {
    add = function() _add() end,
    remove = function() _remove_all() end,
    park = function() return _park_all() end,
    count = function() return M.pooled and 0 or #rigs end,
    pooled = function() return M.pooled == true end,
    recent_reuse = function(window)
        return M.pool_reused_at ~= nil
            and os.clock() - M.pool_reused_at < (tonumber(window) or 30.0)
    end,
    busy = function() return (#pending + #active) > 0 or door_hold ~= nil end,
    -- RE-ADOPT rigs + door that survived a script reset (named IrisRig_*/IrisDoor at placement):
    -- re-own, re-hide, re-protect - so an adopted house keeps invisible, unbreakable collision.
    adopt = function()
        if #rigs > 0 then return #rigs end   -- already owned this session (repeat adopts duplicated rigs 4x)
        local n, seen = 0, {}
        pcall(function()
            local sm = sdk.get_native_singleton("via.SceneManager")
            local smt = sdk.find_type_definition("via.SceneManager")
            local scene = sm and sdk.call_native_func(sm, smt, "get_CurrentScene")
            local comps = scene and scene:call("findComponents(System.Type)", sdk.typeof("app.gm05_042"))
            local cnt = 0
            pcall(function() cnt = comps:call("get_Length") or 0 end)
            if cnt == 0 then pcall(function() cnt = comps:get_size() or 0 end) end
            for i = 0, (tonumber(cnt) or 0) - 1 do
                pcall(function()
                    local c
                    pcall(function() c = comps:call("get_Item", i) end)
                    if not c then pcall(function() c = comps:get_element(i) end) end
                    local go = c and c:call("get_GameObject")
                    local nm = go and go:call("get_Name")
                    if nm and nm:sub(1, 8) == "IrisRig_" then
                        local addr = tostring(go:get_address())
                        if not seen[addr] then
                            seen[addr] = true
                            pcall(function() go = go:add_ref() end)
                            rigs[#rigs + 1] = { go = go, id = nm:sub(9) }
                            _make_unbreakable(go)
                            _hide_tree(go, 0)
                            n = n + 1
                        end
                    end
                end)
            end
            -- the door: single named GO
            local dgo
            pcall(function() dgo = scene:call("findGameObject(System.String)", "IrisDoor") end)
            if dgo and not door_rig then
                pcall(function() dgo = dgo:add_ref() end)
                local ux, uy, uz
                pcall(function()
                    local rp, up = _rp(), _up()
                    local p = dgo:call("get_Transform"):call("get_Position")
                    if rp and up and p then ux, uy, uz = p.x + (up.x - rp.x), p.y + (up.y - rp.y), p.z + (up.z - rp.z) end
                end)
                door_rig = { go = dgo, ux = ux, uy = uy, uz = uz }
                _make_unbreakable(dgo)
            end
        end)
        if n > 0 then
            rehide_bursts = 30
            M.last = "adopted " .. n .. " collision rigs" .. (door_rig and " + door" or "")
            _log("ADOPT: re-owned " .. n .. " rigs" .. (door_rig and " + door" or ""))
        end
        return n
    end,
}

re.on_draw_ui(function()
    if not imgui.tree_node("IRIS MESH COLLISION (exact-geometry, route A)") then return end
    imgui.text(M.last)
    imgui.text("Build the house, let it finish, then ADD. Every piece gets its REAL collision")
    imgui.text("(slanted roof included). Door piece is skipped so the doorway stays open.")
    imgui.text("!! NEVER Reset Scripts with a house standing - it CTDs. Restart the game instead.")
    imgui.text("")
    if imgui.button("ADD MESH COLLISION##imc") then _add() end
    imgui.same_line()
    if imgui.button("REMOVE ALL##imc") then _remove_all() end
    imgui.same_line()
    if imgui.button("HIDE CHASSIS NOW##imc") then
        for _, r in ipairs(rigs) do if r.go then _hide_tree(r.go, 0) end end
        rehide_bursts = 30
        M.last = "re-hide fired on " .. #rigs .. " rigs (+30s campaign)"
    end
    imgui.text("rigs: " .. #rigs .. "   queued: " .. (#pending + #active)
        .. (M.pooled and "   [PARKED FOR FAST RETURN]" or ""))
    imgui.text("")
    imgui.text("-- WORKING DOOR (gimmick in the frame; forged ghost leaf hidden) --")
    local c, changed = false, false
    c, M.door_idx = imgui.combo("door##imcd", M.door_idx, (function()
        local t = {}; for _, e in ipairs(DOORS) do t[#t + 1] = e.label end; return t
    end)())
    c, M.door_yaw   = imgui.slider_float("door yaw offset (deg)##imcd", M.door_yaw, -180.0, 180.0); changed = changed or c
    c, M.door_slide = imgui.slider_float("slide along wall (m)##imcd", M.door_slide, -2.0, 2.0); changed = changed or c
    c, M.door_out   = imgui.slider_float("out of wall (m)##imcd", M.door_out, -1.0, 1.0); changed = changed or c
    c, M.door_up    = imgui.slider_float("height (m)##imcd", M.door_up, -1.0, 1.0); changed = changed or c
    if M.door_limit_deg == nil then M.door_limit_deg = 130.0 end
    c, M.door_limit_deg = imgui.slider_float("swing limit (deg, applied on place)##imcd", M.door_limit_deg, 90.0, 175.0)
    -- FINE NUDGES (Aurora: "no precise control with the sliders") - 1cm / 0.5 deg steps, applied
    -- live like the sliders. (ctrl+click any slider also types an exact number.)
    local function _nudge(label, field, step)
        imgui.text(label)
        imgui.same_line()
        if imgui.button("-##imcdn" .. field) then M[field] = M[field] - step; changed = true end
        imgui.same_line()
        if imgui.button("+##imcdn" .. field) then M[field] = M[field] + step; changed = true end
        imgui.same_line()
    end
    _nudge("yaw", "door_yaw", 0.5)
    _nudge("slide", "door_slide", 0.01)
    _nudge("out", "door_out", 0.01)
    _nudge("up", "door_up", 0.01)
    imgui.text("")
    c, M.door_hide_forged = imgui.checkbox("hide forged door leaf##imcd", M.door_hide_forged)
    c, M.door_autoclose = imgui.checkbox("auto-close behind you (snaps shut when you walk away)##imcd", M.door_autoclose)
    -- sliders apply LIVE to a standing door (dragging should just move it - no extra button press)
    if changed and door_rig and door_rig.go then _apply_fit_live() end
    -- ARC TEST (the inward-swing stop): kills object collision on every RIG within 5m of the door,
    -- so one shove answers "is the wall mcol blocking the arc?" - press again to restore.
    if imgui.button(arc_test_off and "ARC TEST: restore wall collision##imcd" or "ARC TEST: kill wall collision near door##imcd") then
        if arc_test_off then
            for _, pc in ipairs(arc_test_off) do pcall(function() pc:call("enable") end) end
            arc_test_off = nil   -- _G on purpose (200-local cap)
            M.last = "arc test: wall collision restored"
        elseif door_rig then
            arc_test_off = {}
            for _, r in ipairs(rigs) do
                local dx, dz = (r.ux or 0) - door_rig.ux, (r.uz or 0) - door_rig.uz
                if dx * dx + dz * dz < 25.0 and r.go then
                    local function walk(go, depth)
                        if not go or depth > 3 then return end
                        pcall(function()
                            local pc = go:call("getComponent(System.Type)", sdk.typeof("via.physics.Colliders"))
                            if pc then pc:call("disable"); arc_test_off[#arc_test_off + 1] = pc end
                        end)
                        pcall(function()
                            local tf = go:call("get_Transform"); local ch = tf and tf:call("get_Child")
                            while ch do walk(ch:call("get_GameObject"), depth + 1); ch = ch:call("get_Next") end
                        end)
                    end
                    walk(r.go, 0)
                end
            end
            M.last = "arc test: " .. #arc_test_off .. " wall colliders OFF near the door - swing it NOW, then restore"
            _log(M.last)
        end
    end
    -- ARC TEST convicted the door ITSELF (walls ghosted, still stops) -> the swing limit lives in
    -- the gimmick's own fields. Dump everything to IRIS/door_probe.txt and find the angle lever.
    if imgui.button("DOOR PROBE (dump gimmick fields)##imcd") and door_rig and door_rig.go then
        pcall(function()
            local f = io.open("IRIS/door_probe.txt", "w")
            if not f then return end
            f:write("DOOR GIMMICK PROBE " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
            local function dump_go(go, indent, depth)
                if not go or depth > 4 then return end
                local nm = "?"; pcall(function() nm = go:call("get_Name") end)
                f:write(indent .. "GO: " .. tostring(nm) .. "\n")
                pcall(function()
                    local arr = go:call("get_Components")
                    local n = 0
                    pcall(function() n = arr:get_size() or 0 end)
                    for i = 0, (tonumber(n) or 0) - 1 do
                        pcall(function()
                            local comp = arr:get_element(i)
                            local td = comp:get_type_definition()
                            local tn = td:get_full_name()
                            f:write(indent .. "  comp: " .. tn .. "\n")
                            if tn:find("^app%.") then
                                local d = 0
                                while td and d < 3 do
                                    for _, fld in ipairs(td:get_fields()) do
                                        pcall(function()
                                            local v = fld:get_data(comp)
                                            local vs = tostring(v)
                                            if #vs > 60 then vs = vs:sub(1, 60) .. "..." end
                                            f:write(indent .. "    " .. fld:get_name() .. " = " .. vs .. "\n")
                                        end)
                                    end
                                    td = td:get_parent_type(); d = d + 1
                                end
                            end
                        end)
                    end
                end)
                pcall(function()
                    local tf = go:call("get_Transform"); local ch = tf and tf:call("get_Child")
                    while ch do dump_go(ch:call("get_GameObject"), indent .. "  ", depth + 1); ch = ch:call("get_Next") end
                end)
            end
            dump_go(door_rig.go, "", 0)
            f:close()
            M.last = "door probe -> IRIS/door_probe.txt"
        end)
    end
    if imgui.button("APPLY FIT LIVE (no respawn)##imcd") then _apply_fit_live() end
    imgui.same_line()
    if imgui.button("PLACE / RE-PLACE DOOR##imcd") then _place_door() end
    imgui.same_line()
    if imgui.button("REMOVE DOOR##imcd") then _remove_door() end
    imgui.tree_pop()
end)

re.on_script_reset(function()
    -- leak-safe: never destroy/release during reset (CTD law). REMOVE ALL during gameplay instead.
    for i = #rigs, 1, -1 do rigs[i] = nil end
    pending, active, door_rig, door_hold = {}, {}, nil, nil
end)

return M
