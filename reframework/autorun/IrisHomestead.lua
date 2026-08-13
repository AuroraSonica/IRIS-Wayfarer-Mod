-- IrisHomestead.lua - SET-PLOT authoring + (later) buy flow, in ONE menu.
--
-- The pivot (2026-07-18): instead of fighting runtime "build anywhere" (ground shove, off-centre
-- clipping, scenery detection), we CURATE plots by hand - the way every shipping housing game does
-- (Skyrim Hearthfire, FF14 wards). The author scouts the world, CHECKs a spot is genuinely flat &
-- clear, SPAWNs the farmhouse to eyeball it, and SAVEs the exact transform under a name (with a
-- teleport button, like IrisTaming's griffin rest spots). Later: signposts + buy at each saved plot.
--
-- Because plots are hand-picked, the CHECK is STRICT (flat + no cliffs/trees/rocks/scenery) - the
-- OPPOSITE of the grass-pad tool, which existed to MAKE bad ground usable. Here the house sits on
-- real terrain (the farmhouse has its own knoll/foundation for minor unevenness).
--
-- Drives the house build through _G.IrisForge (the forge stays the spawn engine). Persists to
-- IRIS/iris_plots.json. Teleport = TimeSkipManager:requestPlayerWarp (IrisTaming's recipe).

local M = {}
local PLOTS_FILE = "IRIS/iris_plots.json"

-- farmhouse footprint envelope (blueprint 093025: pieces span house-local ~-6..+6 = ~13m square)
local FARMHOUSE = { size = 13.0 }

M.last     = "(idle) - face a spot, CHECK it, SPAWN the farmhouse, SAVE if it looks natural"
M.dist     = 7.0            -- how far ahead of you the farmhouse spawns
M.lift     = 0.2            -- raise the house this much above ground so the floor clears cut-grass stubble
M.yaw      = 0.0            -- extra house yaw (deg) on top of your facing
M.flat_tol = 2.0           -- max height spread across the footprint that still counts as FLAT (m).
                           -- lenient by default (the farmhouse has its own knoll for minor slope);
                           -- tighten the slider if you want only billiard-flat plots.
M.scenery_h = 1.8          -- a collision hit this far ABOVE the ground = scenery/rock/trunk (m)
M.cliff_ny = 0.40          -- surface normal.y below this = a genuine cliff face (slopes pass)
M.plot_name = "Plot 1"
M.check    = "(not checked)"
M.plots    = nil           -- loaded lazily
M.clear_radius = 10.5      -- grass-clear radius under the house (picnic-style foliage hide)
local last_anchor = nil    -- the transform the last SPAWN used (what SAVE records)
local grass_job = nil      -- budgeted foliage clear/restore job
local grass_campaign = nil -- post-build multi-pass clear (foliage streams in gradually after a teleport,
                           -- so ONE clear catches only what's loaded; re-clear for ~16s to catch the rest)
local hidden = {}          -- [{comp,i,vis}] currently-hidden foliage instances (for restore)
local GRASS_BUDGET = 200   -- foliage writes per tick (FREEZE LAW: 274k in one tick froze the game)

-- Streaming can retire a Foliage component or reshuffle its instances while
-- a budgeted job still holds Lua proxies. Validate at write time and select
-- the exact overload; the loose method name caused 264 native AVs in one
-- grass pass on 2026-08-05.
local function _set_foliage_visibility(comp, index, visible)
    if not comp or not sdk.is_managed_object(comp) then return false end
    index = tonumber(index)
    if not index or index < 0 then return false end
    local count = nil
    pcall(function() count = tonumber(comp:call("get_InstanceCount")) end)
    if not count or index >= count then return false end
    return pcall(function()
        comp:call("setVisibility(System.UInt32, System.Boolean)", index, visible)
    end)
end
local pending_rebuild = nil -- deferred rebuild: build ONLY after teleport streaming settles (else CTD)
local last_warp_at = -999  -- os.clock() of the last teleport
local SETTLE = 12.0        -- s to wait after a teleport before building (streaming must finish first;
                          -- 8s wasn't always enough for a big-area teleport)
local pending_grass = nil  -- auto-clear grass AFTER a build finishes (build+grass overlap = CTD)
local pending_collision = nil -- auto-place MESH collision after a build finishes (IrisMeshCollision);
                              -- sequenced BEFORE grass so gimmick spawns never overlap foliage writes
M.auto = true              -- proximity auto spawn/despawn of saved plots (the buy-flow behavior). ON by
                           -- default: walk up to your plot, the house appears; leave, it vanishes.
M.show_loading = true      -- on-screen "preparing your homestead..." while an auto/rebuild spawn runs
local SPAWN_RANGE = 120.0  -- spawn a plot's house within this many m (universal); render coords valid here
local DESPAWN_RANGE = 175.0-- despawn beyond this (hysteresis vs SPAWN_RANGE) = "out of draw distance"
local auto_spawned = nil   -- the saved plot rec whose house is currently auto-up
local adopt_verify = nil   -- {rec, at}: a zombie-adopt must PROVE its pieces survived (see below)
local auto_at = 0          -- proximity-check throttle
local last_manual_at = -999 -- os.clock() of the last MANUAL spawn/despawn/rebuild
local MANUAL_COOLDOWN = 20.0 -- s AUTO backs off after any manual action (don't fight live authoring)
local startup_at = os.clock() -- reset on every script (re)load; AUTO waits SETTLE past this so it can
                              -- never fire a build DURING the initial cold-load streaming (= CTD)
local pause_grace = 0      -- ⛔ PAUSE GUARD (2026-07-22, Aurora's frame-gen crash): NO spawn/build/
                           -- grass/collision work while the world is paused (options menu can flip
                           -- graphics settings = device reset mid-instantiate = CTD), + a short
                           -- grace after unpause so streaming/device recovery settles first
-- ⛔ SAVE-LOAD CRASH FIX (2026-07-21, flight-recorder-diagnosed): startup_at counts from SCRIPT load
-- (= the main menu), so loading a save minutes later sails past the gate and AUTO builds DURING
-- world stream-in = CTD (reproducible: Aurora's save sits AT her plot). Detect the load-in itself:
-- player nil->present, or a >50m jump we didn't cause, counts as a warp -> hold SETTLE from THERE.
local had_player = false   -- was the player present last auto tick?
local last_auto_pos = nil  -- player universal pos last auto tick (jump detector)

-- ── helpers ──────────────────────────────────────────────────────────────────────────────
local function _log(s)
    pcall(function()
        local f = io.open("IRIS/homestead_log.txt", "a")
        if f then f:write(string.format("[%s] %s\n", os.date("%H:%M:%S"), tostring(s))); f:close() end
    end)
    pcall(function() if _G.IrisFlight then _G.IrisFlight.note("homestead: " .. tostring(s)) end end)
end
local function _rvec(x, y, z)
    if Vector4f and Vector4f.new then return Vector4f.new(x, y, z, 1.0) end
    if Vector3f and Vector3f.new then return Vector3f.new(x, y, z) end
    local v = ValueType.new(sdk.find_type_definition("via.vec3")); v.x, v.y, v.z = x, y, z; return v
end
local function _player()
    local pl
    pcall(function()
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        pl = cm and cm:call("get_ManualPlayer")
    end)
    return pl
end
local function _player_tf()
    local tf, pl = nil, _player()
    if pl then pcall(function() tf = pl:call("get_GameObject"):call("get_Transform") end) end
    return tf
end
local function _player_pos()      -- render
    local p, tf = nil, _player_tf()
    if tf then pcall(function() p = tf:call("get_Position") end) end
    return p
end
local function _player_upos()     -- universal (for teleport)
    local p, tf = nil, _player_tf()
    if tf then pcall(function() p = tf:call("get_UniversalPosition") end) end
    return p
end
local function _facing()          -- normalised (fx,fz) render forward
    local fx, fz, tf = 0.0, 1.0, _player_tf()
    if tf then
        local f; pcall(function() f = tf:call("get_AxisZ") end)
        if f then local l = math.sqrt(f.x * f.x + f.z * f.z); if l > 0.001 then fx, fz = f.x / l, f.z / l end end
    end
    return fx, fz
end

-- downward terrain ray (proven TerrainClimber/_SharedCore pattern); RENDER space, Layer 2, re-assert
-- the filter every cast. Returns { y=ground(nearest to seed), ny=normal.y, topy=highest hit } or nil.
local nray = {}
local function _ensure_ray()
    if nray.ready then return true end
    local ok = pcall(function()
        nray.system = sdk.get_native_singleton("via.physics.System")
        nray.method = sdk.find_type_definition("via.physics.System")
            :get_method("castRay(via.physics.CastRayQuery, via.physics.CastRayResult)")
        nray.contact_td = sdk.find_type_definition("via.physics.ContactPoint")
        nray.query = sdk.create_instance("via.physics.CastRayQuery"):add_ref()
        nray.result = sdk.create_instance("via.physics.CastRayResult"):add_ref()
        nray.query:clearOptions(); nray.query:enableAllHits(); nray.query:enableNearSort()
        nray.filter = nray.query:get_FilterInfo()
    end)
    nray.ready = ok and nray.system and nray.query and nray.result and nray.filter
    return nray.ready == true
end
local function _ground_at(px, pz, near_y)
    if not _ensure_ray() then return nil end
    local out = nil
    pcall(function()
        nray.filter:set_Group(0); nray.filter:set_Layer(2); nray.filter:set_MaskBits(0)
        nray.result:clear()
        nray.query:call("setRay(via.vec3, via.vec3)", _rvec(px, near_y + 40.0, pz), _rvec(px, near_y - 60.0, pz))
        nray.method:call(nray.system, nray.query, nray.result)
        local n = nray.result:get_NumContactPoints() or 0
        local bestd, gy, gny, topy = 1e18, nil, 1.0, -1e18
        for k = 0, n - 1 do
            local c = nray.result:call("getContactPoint(System.UInt32)", k)
            local p = c and sdk.get_native_field(c, nray.contact_td, "Position")
            if p then
                if p.y > topy then topy = p.y end
                local d = math.abs(p.y - near_y)
                if d < bestd then
                    bestd = d; gy = p.y
                    local nm = sdk.get_native_field(c, nray.contact_td, "Normal")
                    gny = (nm and nm.y) or 1.0
                end
            end
        end
        if gy then out = { y = gy, ny = gny, topy = topy } end
    end)
    return out
end

-- count SpeedTree (tree/bush) foliage instances whose world pos falls inside the footprint square
local function _trees_in_footprint(cx, cz, half)
    local found, budget = 0, 0
    pcall(function()
        local smgr = sdk.get_native_singleton("via.SceneManager")
        local scene = smgr and sdk.call_native_func(smgr, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        local arr = scene and scene:call("findComponents(System.Type)", sdk.typeof("via.landscape.Foliage"))
        local n = arr and arr:get_size() or 0
        for i = 0, n - 1 do
            local c = arr:get_element(i)
            if c then
                local speed = false
                pcall(function() speed = c:call("isSpeedTreeMesh", 0) == true end)
                if speed then
                    local cnt = 0; pcall(function() cnt = tonumber(c:call("get_InstanceCount")) or 0 end)
                    for k = 0, math.min(cnt, 4000) - 1 do
                        budget = budget + 1
                        local wp; pcall(function() wp = c:call("getWorldPosition", k) end)
                        if wp and math.abs(wp.x - cx) <= half and math.abs(wp.z - cz) <= half then
                            found = found + 1
                            if found >= 5 then return end
                        end
                        if budget > 40000 then return end   -- hard cap: never freeze on a giant forest
                    end
                end
            end
        end
    end)
    return found
end

-- STRICT scout: is this spot genuinely flat AND clear (no cliffs/scenery/trees)? returns ok, reasons
local function _scout(cx, cz, gy0, half)
    -- sample the HOUSE footprint (~6.5m half), not a wide margin - the old 11m reach caught distant
    -- slope and inflated every spread reading.
    local base = FARMHOUSE.size / 2
    local rings = { { 0, 1 }, { base * 0.55, 8 }, { base, 8 } }
    local ys, reasons, minny, worst_sc = {}, {}, 1.0, 0.0
    for _, ring in ipairs(rings) do
        local r, pts = ring[1], ring[2]
        for a = 0, pts - 1 do
            local ang = a * (2 * math.pi / pts)
            local hx, hz = cx + math.cos(ang) * r, cz + math.sin(ang) * r
            local h = _ground_at(hx, hz, gy0)
            if not h then
                reasons[#reasons + 1] = string.format("edge/hole@%.0fm", r)
            else
                ys[#ys + 1] = h.y
                if h.ny < minny then minny = h.ny end
                if h.ny < M.cliff_ny then reasons[#reasons + 1] = string.format("CLIFF@%.0fm(ny=%.2f)", r, h.ny) end
                local over = h.topy - h.y
                if over > worst_sc then worst_sc = over end
                if over > M.scenery_h then reasons[#reasons + 1] = string.format("SCENERY@%.0fm(+%.1fm)", r, over) end
            end
        end
    end
    local spread = 0.0
    if #ys > 0 then
        local lo, hi = ys[1], ys[1]
        for _, y in ipairs(ys) do if y < lo then lo = y end; if y > hi then hi = y end end
        spread = hi - lo
    end
    if spread > M.flat_tol then reasons[#reasons + 1] = string.format("NOT FLAT (%.1fm spread)", spread) end
    local trees = _trees_in_footprint(cx, cz, half)
    if trees > 0 then reasons[#reasons + 1] = trees .. (trees >= 5 and "+" or "") .. " tree/bush in footprint" end
    _log(string.format("SCOUT @(%.1f,%.1f) spread=%.2f minNy=%.2f overhang=%.1f trees=%d -> %s",
        cx, cz, spread, minny, worst_sc, trees, (#reasons == 0) and "CLEAR" or table.concat(reasons, " ")))
    return (#reasons == 0), reasons, spread
end

-- the forward footprint centre (where CHECK looks and SPAWN builds), + its ground height
local function _forward_center()
    local rp = _player_pos(); if not rp then return nil end
    local fx, fz = _facing()
    local half = FARMHOUSE.size / 2 + 1.0
    local off = M.dist
    local rcx, rcz = rp.x + fx * off, rp.z + fz * off
    local g = _ground_at(rcx, rcz, rp.y)
    local gy = g and g.y or rp.y
    local yaw = math.deg(math.atan(fx, fz)) + M.yaw
    return { rcx = rcx, rcz = rcz, gy = gy, yaw = yaw, half = half, fx = fx, fz = fz }
end

-- ── grass clear (picnic recipe: hide via.landscape.Foliage instances under the house) ────
-- ⛔⛔ GRASS BUG, FINAL FORM (2026-07-21 night, diagnosed by the new logging): in dense areas ~58
-- components pass the proximity cull and their combined instances blow ANY one-tick cap before the
-- scan reaches the house's patch -> "0 found CAPPED" on every pass = grass stays, deterministically.
-- A one-tick scan and an anti-freeze cap are fundamentally incompatible in dense areas. FIX: the
-- collector is now a BUDGETED MULTI-TICK JOB - 10k instance reads/tick (the 274k one-tick freeze is
-- the law), no cap, nothing dropped; finishes in a fraction of a second spread over frames.
local grass_scan = nil
local SCAN_BUDGET = 10000

local function _clear_grass(cx, cz, radius)
    if grass_scan then return end
    -- phase A (one tick, cheap): proximity-cull components via instance-0 proxy (patch can sprawl,
    -- so the margin stays generous - the expensive part is now spread over ticks, not capped)
    local near, comps = {}, 0
    pcall(function()
        local smgr = sdk.get_native_singleton("via.SceneManager")
        local scene = smgr and sdk.call_native_func(smgr, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        local arr = scene and scene:call("findComponents(System.Type)", sdk.typeof("via.landscape.Foliage"))
        local n = arr and arr:get_size() or 0
        local near2 = (radius + 200.0) * (radius + 200.0)
        for ci = 0, n - 1 do
            local c = arr:get_element(ci)
            if c then
                comps = comps + 1
                local cnt = 0; pcall(function() cnt = tonumber(c:call("get_InstanceCount")) or 0 end)
                if cnt > 0 then
                    local p0; pcall(function() p0 = c:call("getWorldPosition", 0) end)
                    if p0 then
                        local dx, dz = p0.x - cx, p0.z - cz
                        if dx * dx + dz * dz <= near2 then near[#near + 1] = { comp = c, cnt = cnt } end
                    end
                end
            end
        end
    end)
    grass_scan = { cx = cx, cz = cz, r2 = radius * radius, radius = radius,
                   near = near, ci = 1, ii = 0, work = {}, checked = 0, comps = comps }
    M.last = "scanning foliage near the house (" .. #near .. " patches, budgeted)..."
end

local function _restore_grass()
    if #hidden == 0 then M.last = "no hidden grass to restore"; return end
    grass_job = { mode = "restore", work = hidden, cursor = 1 }
    M.last = "restoring " .. #hidden .. " grass instances..."
end

-- a house that SURVIVED a script reset (forge pieces are named IrisHouse_<id> at build): if any
-- distinctive piece exists in the scene, a house is standing that THIS session doesn't own - the
-- auto flow must ADOPT it, not build a duplicate through it. (Houses built before the naming
-- change are invisible to this check - one game restart clears them.)
local function _zombie_house_standing()
    local found = false
    pcall(function()
        local smgr = sdk.get_native_singleton("via.SceneManager")
        local scene = smgr and sdk.call_native_func(smgr, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        if not scene then return end
        for _, nm in ipairs({ "IrisHouse_sm62_033_00", "IrisHouse_sm80_252_00",
                              "IrisHouse_sm51_300_00", "IrisHouse_sm62_099_00" }) do
            local go
            pcall(function() go = scene:call("findGameObject(System.String)", nm) end)
            if go then found = true; return end
        end
    end)
    return found
end

-- ── actions ──────────────────────────────────────────────────────────────────────────────
local function _check()
    local c = _forward_center(); if not c then M.last = "no player"; return end
    local ok, reasons = _scout(c.rcx, c.rcz, c.gy, c.half)
    M.check = ok and "CLEAR - flat & unobstructed, good plot" or ("BLOCKED: " .. table.concat(reasons, ", "))
    M.last = "CHECK -> " .. M.check
end

local function _spawn()
    local c = _forward_center(); if not c then M.last = "no player"; return end
    if not _G.IrisForge then M.last = "IrisHouseForge not loaded (need it for the house prefabs)"; return end
    local st = _G.IrisForge.status()
    if st and st.building then M.last = "still building - wait for it to finish"; return end
    -- clear the old HOUSE only: a standing TERRACE pad must survive the re-spawn ritual
    -- (despawn_house is the terrace-aware forge lane; old forge falls back to full despawn)
    if st and ((st.house ~= nil and st.house or st.instances) or 0) > 0 then
        if _G.IrisForge.despawn_house then _G.IrisForge.despawn_house() else _G.IrisForge.despawn() end
        _restore_grass()
        if _G.IrisCollision then
            if _G.IrisCollision.park then _G.IrisCollision.park()
            elseif _G.IrisCollision.remove then _G.IrisCollision.remove() end
        end
    end
    -- hand the forge the anchor via the bridge, then build the full farmhouse there.
    -- lift the house slightly so its floor sits above the cut-grass stubble (baked into the saved Y).
    _G.IrisPlot = { x = c.rcx, y = c.gy + M.lift, z = c.rcz, yaw = c.yaw, live = true }
    last_anchor = { ax = c.rcx, ay = c.gy + M.lift, az = c.rcz, yaw = c.yaw }
    _G.IrisForge.build_on_plot()
    -- collision then grass, each ONLY after the build finishes (sequenced, never concurrent - CTD law)
    pending_collision = { seen = false }
    pending_grass = { radius = M.clear_radius }
    M.last = "SPAWN: building the farmhouse (collision + grass auto-apply once it's up)..."
    _log(string.format("SPAWN farmhouse anchor(%.1f,%.1f,%.1f) yaw=%.1f", c.rcx, c.gy, c.rcz, c.yaw))
end

local function _despawn()
    if _G.IrisForge then _G.IrisForge.despawn() end
    if _G.IrisCollision then
        if _G.IrisCollision.park then _G.IrisCollision.park()
        elseif _G.IrisCollision.remove then _G.IrisCollision.remove() end
    end
    if _G.IrisQuarry and _G.IrisQuarry.despawn then pcall(_G.IrisQuarry.despawn) end
    if _G.IrisPlot then _G.IrisPlot.live = false end
    _restore_grass()
    M.last = "despawned the house; restoring grass..."
end

local function _plots()
    if not M.plots then M.plots = (json.load_file(PLOTS_FILE) or {}) end
    return M.plots
end

-- bridge for IrisDeedSign (the purchase flow): read + persist the plot list.
-- rec.owned semantics: nil/true = owned (every pre-flow plot is grandfathered), false = FOR SALE.
_G.IrisHomesteadPlots = {
    list = _plots,
    save = function() pcall(function() json.dump_file(PLOTS_FILE, _plots()) end) end,
    -- Dependency gate for furnishings/farming: unlike Forge.status(), this includes the quiet
    -- render-rebase wait BEFORE a build and the hand-off gap BEFORE collision starts.
    busy = function()
        local st = _G.IrisForge and _G.IrisForge.status and _G.IrisForge.status()
        local awaiting_stable_frame = M.auto and had_player
            and os.clock() <= last_warp_at + ((M.fast ~= false) and 5.0 or SETTLE)
        return awaiting_stable_frame or pending_rebuild ~= nil or pending_collision ~= nil
            or (st and st.building) == true
    end,
}

local function _save()
    if not last_anchor then M.last = "SPAWN a farmhouse first, then SAVE its exact spot"; return end
    local rp, up = _player_pos(), _player_upos()
    -- store the HOUSE's UNIVERSAL (stable) position. render coords float around a shifting rebase
    -- origin, so we convert the house's render anchor to universal: universal = render + (upos - rpos).
    local kx = (rp and up) and (up.x - rp.x) or 0
    local ky = (rp and up) and (up.y - rp.y) or 0
    local kz = (rp and up) and (up.z - rp.z) or 0
    local p = _plots()
    local hux, huy, huz = last_anchor.ax + kx, last_anchor.ay + ky, last_anchor.az + kz   -- house universal
    local rec = {
        name = M.plot_name,
        ux = hux, uy = huy, uz = huz,                                        -- house universal (build)
        -- arrival = EXACTLY where you stand now: proven-valid ground (you're standing on it) AND outside
        -- the house (you spawned it ahead of you). Pushing further out landed off this narrow ledge ->
        -- spawned underground. Your own spot is the safest teleport target.
        tx = (up and up.x or hux), ty = (up and up.y or huy), tz = (up and up.z or huz),
        yaw = last_anchor.yaw,
        house = "farm_complete",
        clear_radius = M.clear_radius,   -- each plot remembers its own grass-clear radius
    }
    p[#p + 1] = rec
    local ok = pcall(function() json.dump_file(PLOTS_FILE, p) end)
    M.last = ok and ("SAVED plot '" .. rec.name .. "' (" .. #p .. " total) -> " .. PLOTS_FILE)
                 or "SAVE FAILED (see homestead log)"
    _log(M.last .. string.format(" universal(%.1f,%.1f,%.1f)", rec.ux, rec.uy, rec.uz))
end

local function _warp(x, y, z)
    pcall(function()
        local tm = sdk.get_managed_singleton("app.TimeManager")
        local tsm = sdk.get_managed_singleton("app.TimeSkipManager")
        if not (tm and tsm) then return end
        local pos = ValueType.new(sdk.find_type_definition("via.Position")); pos.x, pos.y, pos.z = x, y, z
        local tf = _player_tf()
        local rot = tf and tf:call("get_Rotation")
        tsm:call("requestPlayerWarp",
            tm:call("get_InGameHour"), tm:call("get_InGameMinute"), tm:call("get_InGameDay"),
            pos, rot, nil, true, true)
    end)
    last_warp_at = os.clock()   -- REBUILD will wait SETTLE seconds past this before building
    M.last = "warping to plot... (wait for it to load before REBUILD)"
end

local function _rebuild_saved(rec)
    if not _G.IrisForge then M.last = "IrisHouseForge not loaded"; return end
    -- DEFER the build until the area has settled after any recent teleport - building DURING active
    -- streaming CTDs. Wait until SETTLE seconds past the last warp (or now, if that's already passed).
    local at = math.max(os.clock(), last_warp_at + ((M.fast ~= false) and 5.0 or SETTLE))
    pending_rebuild = { rec = rec, at = at }
    local secs = math.max(0, at - os.clock())
    M.last = secs > 0.5
        and string.format("rebuild '%s' in %.0fs (letting the area settle after teleport)...", tostring(rec.name), secs)
        or ("rebuilding '" .. tostring(rec.name) .. "'...")
end

local function _delete_saved(i)
    local p = _plots()
    if p[i] then
        local nm = p[i].name
        table.remove(p, i)
        pcall(function() json.dump_file(PLOTS_FILE, p) end)
        M.last = "deleted plot '" .. tostring(nm) .. "'"
    end
end

-- ── pump: deferred rebuild (post-teleport settle) + budgeted grass clear/restore ─────────
-- pause menu / photo mode: flag names VERIFIED by the griffin pause probe (round 61)
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
    -- ⛔ PAUSE GUARD: while paused (menu/photo mode) NOTHING spawns, clears, or grafts; deferred
    -- work slides forward and gets a 3s post-unpause grace (frame-gen toggles reset the device)
    if _world_paused() then
        pause_grace = os.clock() + 3.0
        if pending_rebuild then pending_rebuild.at = math.max(pending_rebuild.at, pause_grace) end
        return
    end
    if os.clock() < pause_grace then return end

    -- deferred rebuild: build once the teleport streaming has settled (building mid-stream CTDs)
    if pending_rebuild and os.clock() >= pending_rebuild.at then
        local rec = pending_rebuild.rec; pending_rebuild = nil
        local rp, up = _player_pos(), _player_upos()
        if rp and up then
            -- saved UNIVERSAL -> CURRENT render: render = universal - (playerUniversal - playerRender)
            local rx = (rec.ux or rec.ax or 0) - (up.x - rp.x)
            local ry = (rec.uy or rec.ay or 0) - (up.y - rp.y)
            local rz = (rec.uz or rec.az or 0) - (up.z - rp.z)
            _G.IrisPlot = { x = rx, y = ry, z = rz, yaw = rec.yaw or 0, live = true }
            last_anchor = { ax = rx, ay = ry, az = rz, yaw = rec.yaw or 0 }
            if _G.IrisForge then _G.IrisForge.build_on_plot() end
            pending_collision = { seen = false }
            pending_grass = { radius = (rec.clear_radius or M.clear_radius) }
            M.last = "building '" .. tostring(rec.name) .. "' (settled). Grass auto-clears once it's up."
            _log(string.format("REBUILD (settled) '%s' -> render(%.1f,%.1f,%.1f)", tostring(rec.name), rx, ry, rz))
        else
            M.last = "rebuild aborted: no player"
        end
    end

    -- auto-clear grass AFTER the build finishes (build + grass must NOT overlap = CTD). Wait for the
    -- forge to report building, then finished + house actually standing, THEN start the clear CAMPAIGN.
    if pending_grass then
        local st = _G.IrisForge and _G.IrisForge.status()
        local building = st and st.building
        local up = st and (st.instances or 0) > 0
        if building then pending_grass.seen = true end
        local col_busy = pending_collision ~= nil
            or (_G.IrisCollision and _G.IrisCollision.busy and _G.IrisCollision.busy())
        if pending_grass.seen and not building and up and not col_busy then
            local R = pending_grass.radius; pending_grass = nil
            -- 8 passes @2s = ~16s of coverage: catches foliage that streams in AFTER a teleport (the
            -- single-shot clear only ever got the handful loaded at that instant = the 0/16 bug).
            grass_campaign = { radius = R, passes = 8, next_at = os.clock() + 1.0 }
            _log("grass campaign START (radius " .. R .. ", 8 passes)")
            pending_quarry = true   -- _G on purpose; quarry spawns AFTER grass ends (never overlap foliage writes)
        end
    end

    -- the campaign itself: every 2s, re-clear at the LIVE house bounds centre. Each pass hides only the
    -- foliage that is currently VISIBLE, so newly-streamed grass gets caught and nothing double-records.
    -- the multi-tick foliage scan: SCAN_BUDGET position reads per tick, no cap, nothing dropped
    if grass_scan and not grass_job then
        local s = grass_scan
        local reads = 0
        local ok = pcall(function()
            while s.ci <= #s.near and reads < SCAN_BUDGET do
                local e = s.near[s.ci]
                while s.ii < e.cnt and reads < SCAN_BUDGET do
                    local wp; pcall(function() wp = e.comp:call("getWorldPosition", s.ii) end)
                    reads = reads + 1
                    if wp then
                        local dx, dz = wp.x - s.cx, wp.z - s.cz
                        if dx * dx + dz * dz <= s.r2 then s.work[#s.work + 1] = { comp = e.comp, i = s.ii } end
                    end
                    s.ii = s.ii + 1
                end
                if s.ii >= e.cnt then s.ci = s.ci + 1; s.ii = 0 end
            end
        end)
        s.checked = s.checked + reads
        if not ok then
            _log("grass scan ERROR mid-pass - dropping this pass")
            grass_scan = nil
        elseif s.ci > #s.near then
            grass_scan = nil
            if #s.work == 0 then
                M.last = "no foliage found to clear here"
                _log(string.format("grass clear: 0 found @(%.1f,%.1f) r=%.1f [comps=%d near=%d checked=%d]",
                    s.cx, s.cz, s.radius, s.comps, #s.near, s.checked))
            else
                grass_job = { mode = "clear", work = s.work, cursor = 1 }
                M.last = "clearing " .. #s.work .. " grass instances under the house (budgeted)..."
                _log(string.format("grass clear: %d instances within %.1fm of (%.1f,%.1f) [near=%d checked=%d]",
                    #s.work, s.radius, s.cx, s.cz, #s.near, s.checked))
            end
        end
    end

    if grass_campaign and not grass_job and not grass_scan and os.clock() >= grass_campaign.next_at then
        local b = _G.IrisForge and _G.IrisForge.bounds and _G.IrisForge.bounds()
        if b then _clear_grass((b.min.x + b.max.x) / 2, (b.min.z + b.max.z) / 2, grass_campaign.radius)
        else _log("grass pass SKIPPED: forge bounds() nil (no standing house?)") end
        grass_campaign.passes = grass_campaign.passes - 1
        grass_campaign.next_at = os.clock() + 2.0
        if grass_campaign.passes <= 0 then
            grass_campaign = nil
            -- THE QUARRY: the deed comes with stone - spawned only now, with build, collision AND
            -- grass all done (the sequencing law: gimmick spawns never overlap foliage writes)
            if pending_quarry then
                pending_quarry = nil
                pcall(function()
                    local rec = auto_spawned
                    if _G.IrisQuarry and rec and rec.ux then
                        _G.IrisQuarry.spawn(rec.ux, rec.uy or 0, rec.uz)
                    end
                end)
            end
        end
    end

    -- auto-place MESH collision AFTER the build finishes (sequenced BEFORE the grass campaign so the
    -- chassis gimmick spawns never overlap foliage writes; grass gates on IrisCollision.busy below)
    if pending_collision then
        local st = _G.IrisForge and _G.IrisForge.status()
        local building = st and st.building
        local up = st and (st.instances or 0) > 0
        if building then pending_collision.seen = true end
        if pending_collision.seen and not building and up then
            -- ⛔ 08-12 (reviewer blocker 3): the flag used to clear BEFORE add() - a refused
            -- add() (rigs standing, mid-build race, no player) silently lost collision
            -- forever. Now: call, VERIFY it took (jobs pending or rigs standing), and only
            -- then consume. A refusal retries next pass, capped at 12 strikes (~loud drop).
            local took = false
            if _G.IrisCollision and _G.IrisCollision.add then
                _G.IrisCollision.add()
                pcall(function()
                    local C9 = _G.IrisCollision
                    took = (C9.busy and C9.busy() == true)
                        or (C9.count and (tonumber(C9.count()) or 0) > 0)
                        or (C9.pooled and C9.pooled() == true)
                end)
            end
            if took then
                pending_collision = nil
                _log("auto collision: rigs queued")
            else
                pending_collision.strikes = (tonumber(pending_collision.strikes) or 0) + 1
                if pending_collision.strikes >= 12 then
                    pending_collision = nil
                    _log("auto collision: add() refused 12 passes - DROPPED (see collision panel)")
                elseif pending_collision.strikes == 1 or pending_collision.strikes % 4 == 0 then
                    _log("auto collision: add() refused (strike " .. pending_collision.strikes .. ") - retrying")
                end
            end
        end
    end

    -- proximity auto spawn/despawn of saved plots = the buy-flow: house exists at the plot, appears
    -- when you're near, vanishes when you leave (also = "despawn outside draw distance").
    if M.auto and os.clock() >= auto_at then
        -- A parked, already-verified collision pool marks a same-session RETURN, never a cold boot.
        -- Poll that arrival more closely so a one-second auto cadence does not dominate an otherwise
        -- sub-second reuse. No pool keeps the proven conservative cadence and stability law.
        hs_pool_ready = false   -- _G on purpose (this callback is near Lua's 200-local ceiling)
        pcall(function()
            hs_pool_ready = _G.IrisCollision and _G.IrisCollision.pooled
                and _G.IrisCollision.pooled() == true
        end)
        auto_at = os.clock() + (hs_pool_ready and 0.25 or 1.0)
        local up = _player_upos()
        -- load-in / external-warp detection: EITHER trips the same settle-defer as our own teleports
        if up and not had_player then
            -- save load-in streams HARDER than a teleport: 12s settle crashed once (00:35 black box,
            -- died mid-piece-load) - hold 6s extra on this path only
            -- ⚠ FAST SPAWN (Aurora 07-23): the 24s total predates the boot warmer + gentle pace +
            -- pause guards; with all pfbs menu-hot the streaming race is far smaller. fast = 8s
            -- total on load-in. If fast EVER crashes here, that's the experiment's answer - off it goes.
            -- ⛔ COLD BOOTS ALWAYS GET THE FULL SETTLE (2026-07-24, the fast experiment's
            -- verdict: a load-in build "SPAWNED" all 40 pieces into a still-rebasing render
            -- frame - invisible house, hint on open grass). FAST stays for warps/resets only;
            -- the ground probe is ALSO barred during the cold window (ground exists before
            -- the frame settles - existence isn't stability).
            last_warp_at = os.clock() + 12.0   -- the fallback CEILING; the stability probe
                                               -- (frozen frame 3s + ground x3) builds sooner
            hs_probe_hits = 0   -- fresh area = fresh proof required
            hs_delta_last, hs_delta_since = nil, nil   -- rebase-stability clock restarts
            _G.IrisForgeGentleUntil = os.clock() + 90.0   -- and the forge paces gently through the window
            _log("auto: player appeared (save load-in?) -> settling " .. (SETTLE + 12.0) .. "s before any build (gentle forge)")
            adopt_verify = nil   -- a new load-in supersedes any pending adopt verification
        elseif up and last_auto_pos then
            local jx, jz = up.x - last_auto_pos.x, up.z - last_auto_pos.z
            if jx * jx + jz * jz > 50.0 * 50.0 then
                last_warp_at = os.clock()
                hs_probe_hits = 0   -- fresh area = fresh streaming proof required
                hs_delta_last, hs_delta_since = nil, nil
                -- A short fast-travel can stream the foliage out and back without AUTO ever
                -- observing three far-away ticks, so the house survives and no rebuild occurs.
                -- The world's foliage visibility does NOT survive that round trip, however: the
                -- old hidden[] refs say "hidden" while freshly-streamed grass is visible again.
                -- Cancel any pass aimed at the departing world and arm a fresh pass for the final
                -- landing. The standing-house branch below waits for build/collision to be idle,
                -- so this never revives the crash-prone "write foliage during streaming" path.
                grass_campaign, grass_scan = nil, nil
                if grass_job and grass_job.mode == "clear" then grass_job = nil end
                hs_grass_refresh_at = os.clock() + 2.0   -- _G on purpose (file is near Lua's local limit)
                _G.IrisForgeGentleUntil = os.clock() + 75.0   -- ferrystone arrivals stream just as hard
                _log("auto: >50m position jump (fast travel?) -> settling before any build (gentle forge)")
            end
        end
        had_player = up ~= nil
        if up then last_auto_pos = { x = up.x, z = up.z } end
        -- the adopt-claim verification: are the adopted pieces still standing 5s later - AND
        -- standing WHERE THE PLOT IS? (08-05, the second face of the mirage: the pieces are
        -- folderless GOs that SURVIVE a save-load, but their transforms are render-space from the
        -- OLD world - after the rebase they stand somewhere else entirely. Existence isn't the
        -- test; position is.)
        if adopt_verify and os.clock() >= adopt_verify.at then
            local rec = adopt_verify.rec
            adopt_verify = nil
            local standing = _zombie_house_standing()
            local misplaced = false
            if standing and rec and rec.ux then
                pcall(function()
                    local smgr = sdk.get_native_singleton("via.SceneManager")
                    local scene = smgr and sdk.call_native_func(smgr, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
                    local go
                    for _, nm in ipairs({ "IrisHouse_sm62_033_00", "IrisHouse_sm80_252_00",
                                          "IrisHouse_sm51_300_00", "IrisHouse_sm62_099_00" }) do
                        if not go then pcall(function() go = scene:call("findGameObject(System.String)", nm) end) end
                    end
                    if not go then return end
                    local pr = go:call("get_Transform"):call("get_Position")
                    local rp, up2 = _player_pos(), _player_upos()
                    if not (pr and rp and up2) then return end
                    -- piece universal = piece render + (player universal - player render)
                    local pux = pr.x + (up2.x - rp.x)
                    local puz = pr.z + (up2.z - rp.z)
                    local dx, dz = pux - rec.ux, puz - rec.uz
                    misplaced = (dx * dx + dz * dz) > 30.0 * 30.0
                    if misplaced then
                        _log(string.format("auto: adopted pieces stand at universal(%.0f,%.0f) but the plot is (%.0f,%.0f) - STALE WORLD PIECES",
                            pux, puz, rec.ux, rec.uz))
                    end
                end)
            end
            if not standing or misplaced then
                _log("auto: adopt was a MIRAGE (" .. (standing and "misplaced" or "died") .. ") -> dropping refs, real rebuild")
                pcall(_despawn)          -- the forge holds the stale pieces; despawn destroys them
                                         -- and clears house_up so the rebuild can actually run
                auto_spawned = rec
                _rebuild_saved(rec)
            end
        end
        local st = _G.IrisForge and _G.IrisForge.status()
        local house_up = st and (st.instances or 0) > 0
        local busy = (st and st.building) or pending_rebuild ~= nil or pending_grass ~= nil or grass_job ~= nil
        -- RETURN REFRESH: when the house itself never despawned during a quick round trip, there is
        -- no rebuild to trigger pending_grass. Re-clear only after the FINAL position jump, only
        -- while actually back beside that standing house, and only once collision is quiet.
        if hs_grass_refresh_at and os.clock() >= hs_grass_refresh_at
           and up and house_up and auto_spawned
           and not busy and not grass_campaign and not grass_scan then
            local dx, dz = (auto_spawned.ux or 0) - up.x, (auto_spawned.uz or 0) - up.z
            local col_busy = pending_collision ~= nil
                or (_G.IrisCollision and _G.IrisCollision.busy and _G.IrisCollision.busy())
            if dx * dx + dz * dz < SPAWN_RANGE * SPAWN_RANGE and not col_busy then
                local R = auto_spawned.clear_radius or M.clear_radius
                grass_campaign = { radius = R, passes = 8, next_at = os.clock() }
                hs_grass_refresh_at = nil
                _log("grass RETURN REFRESH start (standing house survived travel; radius " .. R .. ")")
            end
        end
        if up and not busy then
            if auto_spawned and not house_up then auto_spawned = nil end   -- stale reservation
            if house_up and auto_spawned then
                -- state enforcement: a FOR-SALE / CONSTRUCTION plot must not keep its house
                -- (reset-while-standing, whatever the lane) - tear it down, the sign takes over
                if auto_spawned.owned == false or auto_spawned.built == false then
                    _despawn(); auto_spawned = nil
                    M.last = "auto: plot no longer built-status -> house down, sign takes over"
                    return
                end
                local dx, dz = (auto_spawned.ux or 0) - up.x, (auto_spawned.uz or 0) - up.z
                local dist = math.sqrt(dx * dx + dz * dz)
                -- ⛔ DEBOUNCE (2026-07-22, door-bump bug): a physics shove (walking into the door)
                -- can produce ONE garbage position frame that reads "out of range" and despawned
                -- the whole house mid-visit. Out-of-range must now persist 3 consecutive checks,
                -- and absurd readings (position glitch, not travel) never count.
                if dist > DESPAWN_RANGE and dist < 100000.0 then
                    hs_despawn_strikes = (hs_despawn_strikes or 0) + 1   -- _G on purpose (200-local cap)
                    if hs_despawn_strikes >= 3 then
                        hs_despawn_strikes = 0
                        _despawn(); auto_spawned = nil
                        M.last = "auto: out of range -> despawned the house"
                    end
                else
                    hs_despawn_strikes = 0
                end
            elseif not house_up and not auto_spawned then
                local p, near, neard = _plots(), nil, 1e18
                for _, rec in ipairs(p) do
                    local dx, dz = (rec.ux or 0) - up.x, (rec.uz or 0) - up.z
                    local d = dx * dx + dz * dz
                    if d < neard then neard = d; near = rec end
                end
                local settled = os.clock() > last_warp_at + ((M.fast ~= false) and 5.0 or SETTLE)
                    and os.clock() > startup_at + ((M.fast ~= false) and 4.0 or SETTLE)  -- never build mid cold-load
                -- FAST: the timers are a PROXY for "streaming delivered the plot". Ask the world
                -- directly instead: ground collision AT THE PLOT = the land is in. 3 consecutive
                -- probe hits (0.4s apart) end the wait early - build starts the moment the ground
                -- exists, not when a stopwatch says so. (Aurora 07-23: "as soon as the player loads")
                if (M.fast ~= false) and not settled and near and math.sqrt(neard) < SPAWN_RANGE then
                    if (hs_probe_hits or 0) >= (hs_pool_ready and 2 or 3) then
                        settled = true
                    elseif os.clock() - (hs_probe_at or 0) > 0.4 then   -- _G on purpose (200-local cap)
                        hs_probe_at = os.clock()
                        local rp2 = _player_pos()
                        local g, stable = nil, false
                        if rp2 then
                            local kx, ky, kz = up.x - rp2.x, up.y - rp2.y, up.z - rp2.z
                            -- ⭐ REBASE STABILITY (07-24, the invisible-house verdict): ground
                            -- EXISTING isn't enough - the universal-render offset must have
                            -- stopped MOVING. Drift resets the stability clock; 3s frozen +
                            -- 3 ground hits = genuinely settled, even seconds after a cold boot.
                            local drift = hs_delta_last
                                and (math.abs(kx - hs_delta_last.x) + math.abs(ky - hs_delta_last.y) + math.abs(kz - hs_delta_last.z))
                                or 1e9
                            if drift > 0.05 then hs_delta_since = os.clock() end
                            hs_delta_last = { x = kx, y = ky, z = kz }
                            -- POOL RETURN FAST-PROOF: collision and resources are already hot; only
                            -- prove the render-origin delta stopped moving. 1.5s + two ground hits is
                            -- deliberately still not same-frame. Cold/no-pool keeps 3s + three hits.
                            stable = os.clock() - (hs_delta_since or os.clock())
                                > (hs_pool_ready and 1.5 or 3.0)
                            if stable then
                                g = _ground_at((near.ux or 0) - kx, (near.uz or 0) - kz, (near.uy or 0) - ky)
                            end
                        end
                        hs_probe_hits = (stable and g) and ((hs_probe_hits or 0) + 1) or 0
                        if hs_probe_hits >= (hs_pool_ready and 2 or 3) then
                            settled = true
                            -- pull the warp clock back too, or _rebuild_saved re-defers the build
                            last_warp_at = math.min(last_warp_at, os.clock() - 30.0)
                            _log(hs_pool_ready
                                and "pool-fast: frame stable 1.5s + ground x2 -> building NOW"
                                or "fast: frame stable 3s + ground x3 -> building NOW")
                        end
                    end
                end
                if near and math.sqrt(neard) < SPAWN_RANGE and settled
                   and os.clock() > last_manual_at + ((M.fast ~= false) and 6.0 or MANUAL_COOLDOWN) then   -- don't fight live authoring
                    if near.owned == false or near.built == false then
                        -- FOR SALE or CONSTRUCTION: no house - the signpost stands instead.
                        -- IrisDeedSign owns purchase + the materials gate; when it flips
                        -- rec.built, this branch builds on the next pass.
                        pcall(function() if _G.IrisDeedSign then _G.IrisDeedSign.ensure_sign(near) end end)
                    elseif _zombie_house_standing() then
                        -- a house SURVIVED a script reset (permanent-ref fix): RE-ADOPT it fully -
                        -- forge re-owns the pieces (house_up flips true = no once-a-second re-adopt
                        -- loop), collision re-owns + re-hides + re-protects rigs/door, and the grass
                        -- (which the reset RESTORED by design) gets a fresh clear campaign.
                        local adopted = 0
                        pcall(function() adopted = (_G.IrisForge.adopt and _G.IrisForge.adopt()) or 0 end)
                        if adopted > 0 then
                            pcall(function() if _G.IrisCollision and _G.IrisCollision.adopt then _G.IrisCollision.adopt() end end)
                            auto_spawned = near
                            grass_campaign = { radius = (near.clear_radius or M.clear_radius), passes = 8, next_at = os.clock() + 1.0 }
                            M.last = "auto: ADOPTED standing house at '" .. tostring(near.name) .. "' (" .. adopted .. " pieces)"
                            _log("auto: ZOMBIE ADOPT '" .. tostring(near.name) .. "' pieces=" .. adopted .. " (+rigs/door/grass)")
                            -- ⛔⛔ THE ZOMBIE MIRAGE (Aurora 08-05: "reloaded into the game but my
                            -- house isn't spawning"). Loading a SAVE without restarting the app
                            -- leaves the DYING world's house enumerable for a moment - the adopt
                            -- grabbed 40 pieces that the load then destroyed, and the flow thought
                            -- the house was up. An adopt is now a CLAIM, verified 5s later: if the
                            -- pieces are gone by then, it was a mirage and the real rebuild runs.
                            adopt_verify = { rec = near, at = os.clock() + 5.0 }
                        else
                            -- names were seen but re-own failed: fall back to a plain rebuild
                            auto_spawned = near
                            _rebuild_saved(near)
                            _log("auto: zombie detected but adopt returned 0 -> plain rebuild")
                        end
                    else
                        auto_spawned = near
                        _rebuild_saved(near)   -- convert + settle-defer + build + auto-grass
                        M.last = "auto: near '" .. tostring(near.name) .. "' -> spawning..."
                    end
                end
            end
        end
    end

    if not grass_job then return end
    local done = 0
    while grass_job.cursor <= #grass_job.work and done < GRASS_BUDGET do
        local w = grass_job.work[grass_job.cursor]
        pcall(function()
            if grass_job.mode == "clear" then
                -- ONLY hide currently-visible foliage: multi-pass safe (a later pass won't re-record an
                -- already-hidden instance) AND restore-correct (we capture its true prior visibility).
                local vis; pcall(function() vis = w.comp:call("getVisibility", w.i) end)
                if vis ~= false then
                    if _set_foliage_visibility(w.comp, w.i, false) then
                        hidden[#hidden + 1] = { comp = w.comp, i = w.i, vis = vis }
                        grass_job.hid = (grass_job.hid or 0) + 1
                    end
                end
            else
                _set_foliage_visibility(w.comp, w.i, (w.vis == nil) and true or w.vis)
            end
        end)
        grass_job.cursor = grass_job.cursor + 1
        done = done + 1
    end
    if grass_job.cursor > #grass_job.work then
        local mode = grass_job.mode
        if mode == "clear" then
            _log(string.format("grass pass: %d newly hidden (%d total hidden)", grass_job.hid or 0, #hidden))
            M.last = "grass cleared (" .. #hidden .. " hidden under house)"
        else
            hidden = {}
            M.last = "grass restored"
        end
        grass_job = nil
    end
end)

-- state bridge for the flight recorder: name anything in flight (deferred jobs were a black-box
-- blind spot - a crash during the rebuild-defer window read as "idle")
_G.IrisHomestead = {
    -- ⭐ READ-ONLY plot access for other IRIS modules. Every saved plot carries the house origin
    --   (ux,uy,uz, UNIVERSAL) and its `yaw` in DEGREES, which together define the house's own
    --   frame — so anything expressed as an offset in that frame (a door, a pawn muster point)
    --   lands in the same relative spot at EVERY plot, exactly as Aurora expects.
    plots = function() return _plots() end,
    -- the saved plot whose house origin is nearest a universal position, + its distance
    nearest_plot = function(up)
        if not (up and up.x) then return nil end
        local best, bd
        for _, r in ipairs(_plots() or {}) do
            if r.ux then
                local dx, dz = r.ux - up.x, r.uz - up.z
                local d = math.sqrt(dx * dx + dz * dz)
                if not bd or d < bd then best, bd = r, d end
            end
        end
        return best, bd
    end,
    inflight = function()
        local t = {}
        if pending_rebuild then t[#t + 1] = "REBUILD-DEFER" end
        if pending_collision then t[#t + 1] = "COLLISION-PENDING" end
        if pending_grass then t[#t + 1] = "GRASS-PENDING" end
        if grass_campaign then t[#t + 1] = "GRASS-CAMPAIGN" end
        if grass_job then t[#t + 1] = "GRASS-JOB" end
        return (#t > 0) and table.concat(t, "+") or nil
    end,
}

-- ── UI (single menu) ─────────────────────────────────────────────────────────────────────
-- ── ADJUST STANDING HOUSE (Aurora's placement pain: guess -> build -> despawn -> retry). Nudge
-- the ALREADY-BUILT house live (visual pieces move instantly; collision stays put until APPLY),
-- then one APPLY bakes the new anchor into last_anchor + the live plot rec and rebuilds ONCE.
local function _adj_quat_yaw(deg)
    local h = math.rad(deg) / 2
    return { x = 0, y = math.sin(h), z = 0, w = math.cos(h) }
end
local function _adj_qmul(a, b)
    return {
        w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
        x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
    }
end
-- ── KIT DIFF (the capture expedition tool): stand at the REAL farmhouse, press the button -
-- every environment prop mesh within 45m gets dumped with world transform and marked HAVE (in
-- the kit) or MISS. The MISS lines + the HAVE anchors are everything needed to add the missing
-- pieces (annex roof! fences!) to the kit json offline.
local function _kit_diff()
    local kit = {}
    pcall(function()
        local h = json.load_file("IRIS/forge_house_farm_complete.json")
        for _, s in ipairs((h and h.specs) or {}) do kit[s.id] = true end
    end)
    local rp = _player_pos()
    if not rp then M.last = "no player"; return end
    local f = io.open("IRIS/farmhouse_diff.txt", "w")
    if not f then M.last = "cannot open farmhouse_diff.txt"; return end
    f:write("KIT DIFF " .. os.date("%Y-%m-%d %H:%M:%S") .. string.format("  player(%.2f,%.2f,%.2f)\n", rp.x, rp.y, rp.z))
    f:write("kit ids known: " .. tostring(next(kit) and "yes" or "NONE (json missing?)") .. "\n\n")
    local have_n, miss_n, seen = 0, 0, {}
    pcall(function()
        local sm = sdk.get_native_singleton("via.SceneManager")
        local scene = sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        local comps = scene:call("findComponents(System.Type)", sdk.typeof("via.render.Mesh"))
        local n = 0
        pcall(function() n = comps:call("get_Length") or 0 end)
        if n == 0 then pcall(function() n = comps:get_size() or 0 end) end
        for i = 0, (tonumber(n) or 0) - 1 do
            pcall(function()
                local c
                pcall(function() c = comps:call("get_Item", i) end)
                if not c then pcall(function() c = comps:get_element(i) end) end
                if not c then return end
                local go = c:call("get_GameObject")
                local addr = tostring(go)
                if seen[addr] then return end
                local tf = go:call("get_Transform")
                local pos = tf:call("get_Position")
                local dx, dy, dz = pos.x - rp.x, pos.y - rp.y, pos.z - rp.z
                if dx * dx + dy * dy + dz * dz > 45.0 ^ 2 then return end
                local path
                local mr = c:call("getMesh")
                if mr then
                    if not pcall(function() path = tostring(mr:call("get_ResourcePath")) end) then
                        path = tostring(mr)
                    end
                end
                -- ANY environment mesh (the annex shed proved buildings live outside props/)
                if not path or not path:lower():find("environment/") then return end
                seen[addr] = true
                local id = path:match("([%w_]+)%.mesh") or "?"
                local rot = tf:call("get_Rotation")
                local tag
                if kit[id] then tag = "HAVE"; have_n = have_n + 1 else tag = "MISS"; miss_n = miss_n + 1 end
                f:write(string.format("%s  %s  pos(%.3f,%.3f,%.3f)  rot(%.4f,%.4f,%.4f,%.4f)  %s\n",
                    tag, id, pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w, path))
            end)
        end
    end)
    f:write(string.format("\nsummary: %d HAVE, %d MISS\n", have_n, miss_n))
    f:close()
    M.last = string.format("KIT DIFF -> IRIS/farmhouse_diff.txt (%d have, %d MISSING)", have_n, miss_n)
    _log(M.last)
end

-- v3 PREVIEW = RESPAWN (transform writes land but static-baked rendering never repaints - proven
-- by readback + blink tests): on slider-settle, despawn the visual pieces and re-instantiate at
-- the adjusted anchor. Prefabs are hot and permanent, so a full re-appear takes ~a second.
local function _adj_rebuild_preview()
    if not (hs_adj and last_anchor and _G.IrisForge) then return end
    pcall(function() _G.IrisForge.despawn() end)
    _G.IrisPlot = {
        x = last_anchor.ax + hs_adj.x,
        y = last_anchor.ay + hs_adj.y,
        z = last_anchor.az + hs_adj.z,
        yaw = (last_anchor.yaw or 0) + hs_adj.yaw,
        live = true,
    }
    pcall(function() _G.IrisForge.build_on_plot() end)
end

re.on_draw_ui(function()
    if not imgui.tree_node("IRIS HOMESTEAD (scout -> check -> spawn -> save plots)") then return end
    imgui.text(M.last)
    if imgui.tree_node("ADJUST STANDING HOUSE (nudge -> settles -> respawns there)##ihs_adj") then
        if not hs_adj then
            imgui.text("nudge the built house (pieces respawn ~1s after you stop dragging)")
            if imgui.button("START ADJUSTING##ihs_adj") then
                if last_anchor then
                    hs_adj = { x = 0, y = 0, z = 0, yaw = 0 }
                    M.last = "adjusting: drag a slider, the house re-appears at the new spot"
                else
                    M.last = "no built house this session - SPAWN one first"
                end
            end
        else
            local ac, ch = false, false
            ac, hs_adj.x = imgui.slider_float("offset X (m)##ihs_adj", hs_adj.x, -4.0, 4.0); ch = ch or ac
            ac, hs_adj.y = imgui.slider_float("offset Y (m) [up/down]##ihs_adj", hs_adj.y, -3.0, 3.0); ch = ch or ac
            ac, hs_adj.z = imgui.slider_float("offset Z (m)##ihs_adj", hs_adj.z, -4.0, 4.0); ch = ch or ac
            ac, hs_adj.yaw = imgui.slider_float("rotate (deg)##ihs_adj", hs_adj.yaw, -180.0, 180.0); ch = ch or ac
            if ch then hs_adj.settle_at = os.clock() + 0.5 end
            if hs_adj.settle_at and os.clock() >= hs_adj.settle_at then
                hs_adj.settle_at = nil
                local st = _G.IrisForge and _G.IrisForge.status()
                if st and st.building then
                    hs_adj.settle_at = os.clock() + 0.5   -- mid-build: wait our turn
                else
                    _adj_rebuild_preview()
                end
            end
            imgui.text("(ctrl+click a slider to type; collision/door stay put until APPLY)")
            if imgui.button("APPLY & REBUILD HERE##ihs_adj") then
                last_anchor.ax = last_anchor.ax + hs_adj.x
                last_anchor.ay = last_anchor.ay + hs_adj.y
                last_anchor.az = last_anchor.az + hs_adj.z
                last_anchor.yaw = (last_anchor.yaw or 0) + hs_adj.yaw
                -- live saved plot? bake the delta into the rec + persist
                if auto_spawned and auto_spawned.ux then
                    auto_spawned.ux = auto_spawned.ux + hs_adj.x
                    auto_spawned.uy = (auto_spawned.uy or 0) + hs_adj.y
                    auto_spawned.uz = auto_spawned.uz + hs_adj.z
                    auto_spawned.yaw = (auto_spawned.yaw or 0) + hs_adj.yaw
                    pcall(function() json.dump_file(PLOTS_FILE, _plots()) end)
                end
                local rec = auto_spawned
                hs_adj = nil
                last_manual_at = os.clock()
                _despawn()
                if rec then
                    pending_rebuild = { rec = rec, at = os.clock() + 4.0 }
                    M.last = "APPLIED - rebuilding at the adjusted spot (plot updated)"
                else
                    -- manual build: rebuild at the adjusted anchor via the plot bridge, then
                    -- SAVE PLOT records the corrected spot
                    pcall(function()
                        _G.IrisPlot = { x = last_anchor.ax, y = last_anchor.ay, z = last_anchor.az,
                                        yaw = last_anchor.yaw or 0, live = true }
                        if _G.IrisForge then _G.IrisForge.build_on_plot() end
                    end)
                    M.last = "APPLIED - rebuilding at the adjusted anchor. SAVE PLOT keeps this spot."
                end
            end
            imgui.same_line()
            if imgui.button("CANCEL (snap back)##ihs_adj") then
                hs_adj.x, hs_adj.y, hs_adj.z, hs_adj.yaw = 0, 0, 0, 0
                _adj_rebuild_preview()   -- respawn at the original anchor
                hs_adj = nil
                M.last = "adjust cancelled - house back where it was"
            end
        end
        imgui.tree_pop()
    end
    if imgui.button("KIT DIFF (stand at the REAL farmhouse / any fence)##ihs_diff") then
        local ok, err = pcall(_kit_diff)
        if not ok then M.last = "kit diff ERROR: " .. tostring(err) end
    end
    if _G.IrisForge then
        local st = _G.IrisForge.status()
        if st then imgui.text("forge: " .. tostring(st.last) .. (st.building and "   [building...]" or "")) end
    end
    imgui.text("")

    -- setup (one-time per session)
    if imgui.tree_node("Setup (one-time: forge the house prefabs)##ihs_setup") then
        imgui.text("Run this ONCE per game session before spawning. Skips the crashy LOAD ALL.")
        if imgui.button("FORGE PREFABS##ihs_forge") then
            if _G.IrisForge then _G.IrisForge.forge_all() else M.last = "IrisHouseForge not loaded" end
        end
        imgui.tree_pop()
    end

    imgui.separator()
    imgui.text("1) Stand where you want the plot, facing it. 2) CHECK. 3) SPAWN. 4) SAVE.")
    local c
    c, M.dist = imgui.slider_float("spawn distance ahead##ihs", M.dist, 4.0, 20.0)
    c, M.yaw  = imgui.slider_float("house yaw (deg)##ihs", M.yaw, -180.0, 180.0)
    c, M.lift = imgui.slider_float("house lift (raise floor over grass)##ihs", M.lift, 0.0, 1.0)

    imgui.text("check result: " .. M.check)
    if imgui.button("CHECK SITE (flat & clear?)##ihs") then _check() end
    imgui.same_line()
    if imgui.button("SPAWN FARMHOUSE##ihs") then last_manual_at = os.clock(); _spawn() end
    imgui.same_line()
    if imgui.button("DESPAWN##ihs") then last_manual_at = os.clock(); _despawn() end
    -- TERRACE: flat walkable pad for bumpy spots. Publishes the SAME forward anchor SPAWN
    -- uses, so pad and house share a centre - press it, DON'T MOVE, then SPAWN FARMHOUSE.
    if imgui.button("BUILD TERRACE (bumpy ground: press FIRST, stand still, then SPAWN)##ihs_ter") then
        last_manual_at = os.clock()
        if not (_G.IrisForge and _G.IrisForge.terrace) then
            M.last = "forge not loaded (or an old IrisHouseForge without the terrace lane)"
        else
            local tc = _forward_center()
            if not tc then M.last = "no player" else
                _G.IrisPlot = { x = tc.rcx, y = tc.gy + M.lift, z = tc.rcz, yaw = tc.yaw, live = true }
                last_anchor = { ax = tc.rcx, ay = tc.gy + M.lift, az = tc.rcz, yaw = tc.yaw }
                _G.IrisForge.terrace()
            end
        end
    end
    if imgui.button("GROUND-REACH NOW (stretch floating wall bottoms to the ground)##ihs_gr") then
        last_manual_at = os.clock()
        if _G.IrisForge and _G.IrisForge.ground_reach then _G.IrisForge.ground_reach()
        else M.last = "forge not loaded (or an old IrisHouseForge without ground-reach)" end
    end

    -- ── HOME LIFE: sit in the chairs, lie in the beds, ring the bells ────────────────
    -- The feature itself is fully automatic (walk up, press E / A) — this section exists
    -- for the one failure mode that is otherwise invisible: "I'm stood at my chair and
    -- no label appears." The dump shows every jackable thing near you, what IRIS decided
    -- it was, and — crucially — the ones it REFUSED and why, so the blacklist is
    -- auditable rather than a silent shrug.
    if imgui.tree_node("HOME LIFE (sit / lie / ring — furniture you can actually use)##ihs_hl") then
        -- guarded: this section reaches into ANOTHER module, so a change over there must not
        -- be able to skip our tree_pop() and corrupt the whole imgui overlay.
        pcall(function()
        if not _G.IrisHomeLife then
            imgui.text("   IrisHomeLife.lua is not loaded.")
        else
            local HL = _G.IrisHomeLife.cfg
            c, HL.enabled = imgui.checkbox("enabled##ihs_hl", HL.enabled ~= false)
    c, HL.prompt  = imgui.checkbox("show the native B prompt##ihs_hl", HL.prompt ~= false)
            c, HL.reach   = imgui.slider_float("reach (m)##ihs_hl", HL.reach or 1.9, 0.8, 4.0)
            -- the chair family does not carry an authored sit-down clip, so the jack never
            -- walks her onto the seat: we deliver her there ourselves. Which way a given
            -- prefab's forward axis points is not knowable per-prefab, hence the flip.
            c, HL.seat_snap = imgui.checkbox("slide onto the seat before sitting##ihs_hl", HL.seat_snap ~= false)
            c, HL.seat_flip = imgui.checkbox("flip seat facing (if she sits backwards)##ihs_hl", HL.seat_flip == true)
            -- A/B switch: OFF jacks the chair itself (pose plays wherever you stand, because
            -- chair prefabs carry no skeleton for the jack to anchor to); ON spawns Capcom's
            -- invisible gm80_166 seat at the chair and jacks that instead.
            c, HL.proxy_seat = imgui.checkbox("chairs: use the invisible seat (gm80_166)##ihs_hl", HL.proxy_seat ~= false)

            local nr = _G.IrisHomeLife.near()
            imgui.text(nr and string.format("   in front of you: %s  ->  %s  (%s, entry '%s')",
                    tostring(nr.name), tostring(nr.verb), tostring(nr.kind), tostring(nr.entry))
                or "   in front of you: nothing usable")
            if _G.IrisHomeLife.busy() then
                imgui.text("   POSE ACTIVE - move to get up")
                if imgui.button("FORCE RELEASE##ihs_hl") then _G.IrisHomeLife.release("panel") end
            end

            if imgui.button("WHAT'S AROUND ME? (12m)##ihs_hl_d") then
                M.hl_dump = _G.IrisHomeLife.dump(12.0)
            end
            for _, r in ipairs(M.hl_dump or {}) do
                imgui.text(string.format("   %5.1fm %+5.1fy  %-22s %s", r.dist, r.dy,
                    tostring(r.name),
                    r.ban and ("REFUSED: " .. tostring(r.ban))
                          or string.format("%s / %s / %s (%d states)", tostring(r.verb),
                                tostring(r.kind), tostring(r.mode), r.states or 0)))
            end
        end
        end)
        imgui.tree_pop()
    end

    c, M.clear_radius = imgui.slider_float("grass-clear radius##ihs", M.clear_radius, 4.0, 15.0)
    if imgui.button("CLEAR GRASS UNDER HOUSE##ihs") then
        local b = _G.IrisForge and _G.IrisForge.bounds and _G.IrisForge.bounds()
        if b then
            _clear_grass((b.min.x + b.max.x) / 2, (b.min.z + b.max.z) / 2, M.clear_radius)
        else
            local ct = _forward_center()
            if ct then _clear_grass(ct.rcx, ct.rcz, M.clear_radius) end
        end
    end
    imgui.same_line()
    if imgui.button("RESTORE GRASS##ihs") then _restore_grass() end
    imgui.text("   (grass auto-clears after each build; these buttons re-tune it manually)")

    if imgui.tree_node("strictness (tune while scouting)##ihs_str") then
        c, M.flat_tol  = imgui.slider_float("max flatness spread (m)##ihs", M.flat_tol, 0.2, 3.0)
        c, M.scenery_h = imgui.slider_float("scenery height over ground (m)##ihs", M.scenery_h, 0.5, 5.0)
        c, M.cliff_ny  = imgui.slider_float("cliff steepness (normal.y)##ihs", M.cliff_ny, 0.2, 0.9)
        imgui.tree_pop()
    end

    imgui.separator()
    c, M.plot_name = imgui.input_text("plot name##ihs", M.plot_name)
    if imgui.button("SAVE THIS PLOT##ihs") then _save() end
    imgui.text("   (SPAWN first, position it right, then SAVE the exact transform)")

    imgui.separator()
    local prev_auto = M.auto
    c, M.auto = imgui.checkbox("AUTO spawn/despawn nearest plot by proximity (buy-flow test)##ihs", M.auto)
    if M.auto and not prev_auto then last_warp_at = os.clock() end   -- fresh settle wait on enable
    c, M.fast = imgui.checkbox("FAST SPAWN (ON by default: ~5s settles + ground-probe early start)##ihs_fast", M.fast ~= false)
    imgui.text("  ⚠ if a build EVER crashes mid-spawn, untick this and tell Iris - that's the experiment")
    local p = _plots()
    imgui.text("SAVED PLOTS (" .. #p .. "):")
    for i = 1, #p do
        local rec = p[i]
        -- state chip: FOR SALE (owned=false) / BUILT (this plot's house is the standing one) / OWNED
        local state = (rec.owned == false) and "[FOR SALE]"
            or (rec.built == false) and "[CONSTRUCTION: gathering]"
            or ((auto_spawned == rec) and "[BUILT]" or "[OWNED, not built]")
        imgui.text(string.format("  %d. %s  %s", i, tostring(rec.name), state))
        imgui.same_line()
        if imgui.button("TELEPORT##ihs_tp" .. i) then _warp(rec.tx or rec.ux or rec.ax, rec.ty or rec.uy or rec.ay, rec.tz or rec.uz or rec.az) end
        imgui.same_line()
        if imgui.button("REBUILD##ihs_rb" .. i) then last_manual_at = os.clock(); _rebuild_saved(rec) end
        imgui.same_line()
        if imgui.button("DELETE##ihs_del" .. i) then _delete_saved(i) end
        imgui.same_line()
        if rec.owned == false then
            if imgui.button("MARK OWNED (skip purchase)##ihs_own" .. i) then
                rec.owned = true
                pcall(function() if _G.IrisDeedSign and _G.IrisDeedSign.active() == rec then _G.IrisDeedSign.remove_sign() end end)
                _G.IrisHomesteadPlots.save()
            end
        else
            -- the full-loop test reset (Aurora 07-23): house down, plot back to FOR SALE,
            -- sign regrows on the auto loop's next pass -> purchase -> build, repeatable
            if imgui.button("SELL / RESET TO FOR-SALE##ihs_fs" .. i) then
                -- ALWAYS tear down (Aurora's for-sale-plot-with-a-house bug: the standing
                -- house isn't always auto_spawned's record - adopted/manual builds slip by)
                _despawn(); auto_spawned = nil
                -- the furnishings sell WITH the house (half back each; never orphaned)
                local fref, fn = 0, 0
                pcall(function()
                    if _G.IrisFurnish and _G.IrisFurnish.sell_plot then
                        fref, fn = _G.IrisFurnish.sell_plot(rec.name)
                    end
                end)
                -- the house itself refunds half the plot price when it was owned
                local href = 0
                if rec.owned ~= false then
                    href = 10000   -- half the 20,000 G deed (TODO: read the live price from IrisDeedSign)
                    pcall(function()
                        local im = sdk.get_managed_singleton("app.ItemManager")
                        local cur = tonumber(im:get_field("_Version"))
                        if cur then im:set_field("_Version", cur + href) end
                    end)
                end
                rec.owned = false
                rec.built = nil
                _G.IrisHomesteadPlots.save()
                M.last = string.format("plot '%s' SOLD: +%d G house, +%d G for %d furnishings; FOR SALE again",
                    tostring(rec.name), href, fref, fn)
            end
        end
    end

    imgui.tree_pop()
end)

-- ── on-screen "your house is loading" notice (auto/rebuild spawn takes ~15s: stream + build) ──
re.on_frame(function()
    if not M.show_loading then return end
    -- "loading" means ALL of it (Aurora): keep the notice up until the COLLISION rigs are placed
    -- too, not just the visible build - a house you can walk through isn't done loading
    local show = pending_rebuild ~= nil or pending_collision ~= nil
    if not show then
        local st = _G.IrisForge and _G.IrisForge.status()
        if st and st.building and auto_spawned then show = true end
    end
    if not show and auto_spawned then
        pcall(function()
            if _G.IrisCollision and _G.IrisCollision.busy and _G.IrisCollision.busy() then show = true end
        end)
    end
    if not show then return end
    local msg = "Preparing your homestead... give it a moment."
    local dw = 1920
    pcall(function() local ds = imgui.get_display_size(); if ds and ds.x then dw = ds.x end end)
    local x = dw * 0.5 - 150
    -- ⭐ ONE ON-SCREEN FACE (07-21): shared d2d serif (IrisFont draws its own shadow); the
    -- hand-rolled shadow + draw.text pair below is the no-d2d fallback.
    local F = _G.IrisFont
    if F and F.text and F.text(msg, x, 80, 0xFFFFFFFF, 19) then return end
    pcall(function() draw.text(msg, x + 1, 81, 0xFF000000) end)   -- shadow
    pcall(function() draw.text(msg, x, 80, 0xFFFFFFFF) end)
end)

re.on_script_reset(function()
    M.plots = nil
    pending_rebuild, pending_grass, pending_collision, auto_spawned = nil, nil, nil, nil
    grass_campaign, grass_job, grass_scan = nil, nil, nil
    -- restore any hidden foliage so a reload never leaves permanent bald patches
    pcall(function()
        for _, w in ipairs(hidden) do
            _set_foliage_visibility(w.comp, w.i, (w.vis == nil) and true or w.vis)
        end
    end)
    hidden = {}
end)

return M
