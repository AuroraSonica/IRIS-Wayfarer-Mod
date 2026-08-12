-- I.R.I.S. -- THE HOMESTEAD BOX (2026-08-11, slice 2 v1)
-- Souls sent home ([H] in the Stable Screen) get LIVE BODIES at the owned plot: they
-- spawn when you approach, wander on their own docile AI, wear their size genes, carry
-- nameplates, and can be milked/tended (IrisFarming's produce gate accepts residents).
-- Despawn when you leave -- villager rules; the SOUL in the stable json is what persists.
--
-- Machinery: the probe's own proven EnemySpawner recipe (SpawnRequest:new + getCharID
-- with the band_A_00 healing rule + requestAddInstances). Coordinates: plots store two
-- anchors (t* and u*) -- the spawner speaks RENDER, and the debug marker toggle exists
-- precisely so the field test can catch a wrong-space pick (the coord law).
--
-- v1 HONESTY: docile species (critters, ox) are the target residents. Predators (wolf/
-- drake...) DO spawn and the party won't attack them (resident bodies register into the
-- probe's protection table), but their own aggro toward YOU is not yet pacified -- send
-- the sheep home before the wolves.

local ok_spawn, SpawnRequest = pcall(require, "EnemySpawner/spawnRequest")

-- ⛔ 08-12 (chicken named Mootilda): the reacquire's once-flag lived on B, which PERSISTS
-- across script resets -- so the reacquire ran once per game session, not once per load,
-- and every later reset fell through to blind order-binding. A FILE-LOCAL genuinely
-- resets on every reload; that is the whole point of it.
local reacquired_this_load = false

-- ⭐ 08-12 (Aurora: "despawn them BEFORE the reset -- can we detect that?"): yes --
-- re.on_script_reset fires as the scripts tear down, while the spawner's managed
-- wrappers are still ALIVE and can really delete their bodies. Clean exit, clean
-- re-entry: the sweep respawns everyone fresh on the next approach. The reacquire
-- below survives as the safety net for paths that never fire this (a crash kills
-- the bodies with the game anyway).
re.on_script_reset(function()
    pcall(function()
        if B.spawner then B.spawner:deleteAll() end
        B.bodies = {}
        B.addrs = {}
        B.near = false
        log.info("[IrisHomesteadBox] script reset detected - residents despawned cleanly")
    end)
end)

local CFG = "IrisHomesteadBox.json"
local C = {
    enabled = true,
    near_radius = 90.0,      -- approach: bodies appear
    far_radius = 130.0,      -- leave: bodies despawn (hysteresis)
    ring_min = 4.0, ring_max = 12.0,   -- resident placement ring around the plot anchor
    max_residents = 8,
    use_t_anchor = true,     -- plot anchor: t* (deed sign space) vs u* -- field-verified via the marker
    debug_marker = false,    -- draw the plot anchor + resident states on screen
}
pcall(function()
    local d = json.load_file(CFG)
    if type(d) == "table" then for k, v in pairs(d) do if C[k] ~= nil then C[k] = v end end end
end)
local function save_cfg() pcall(function() json.dump_file(CFG, C) end) end

local B = _G.IrisHomesteadBox or {}
_G.IrisHomesteadBox = B
B.bodies = B.bodies or {}     -- rec.id -> { addr = go addr, name, at }
B.addrs = B.addrs or {}       -- go addr -> rec.id (produce gate + fast lookup)
B.spawner = B.spawner or nil
B.near = B.near or false

-- the produce gate's question (IrisFarming): is this GO one of the homestead's animals?
B.is_resident = function(go_addr)
    return go_addr ~= nil and B.addrs[go_addr] ~= nil
end
-- the stable's question (08-12, Aurora: "you should need to go up to them at the home
-- to actually return them"): may a home soul be called back RIGHT NOW? Yes only when
-- standing at the homestead -- or when this module is disabled (never strand a soul).
B.can_collect = function()
    if C.enabled == false then return true end
    return B.near == true
end

local function bridge() return rawget(_G, "IrisGriffinBridge") end

local plots_cache = nil
local function owned_plots()
    if plots_cache then return plots_cache end
    plots_cache = {}
    pcall(function()
        local d = json.load_file("IRIS/iris_plots.json")
        for _, p in ipairs(d or {}) do
            if p.owned == true then plots_cache[#plots_cache + 1] = p end
        end
    end)
    return plots_cache
end

local function plot_anchor(p)
    if C.use_t_anchor ~= false then return p.tx, p.ty, p.tz end
    return p.ux, p.uy, p.uz
end

local function player_go()
    local go = nil
    pcall(function()
        local pl = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
        go = pl and pl:call("get_GameObject")
    end)
    return go
end

-- ⛔⛔ THE COORD LAW, PAID FOR TWICE (08-12, the receipts: d=19m at boot -> d=1142m ten
-- seconds later, no ferrystone): plot anchors are UNIVERSAL, my player read was RENDER,
-- and the two spaces shear apart the moment the game re-bases its tiles. Distance is
-- measured universal-vs-universal; the SPAWNER speaks RENDER, so anchors convert through
-- the player's own universal-render offset at the moment of use (the taming recipe).
local function player_spaces()
    local u, r = nil, nil
    pcall(function()
        local pgo = player_go()
        local tr = pgo and pgo:call("get_Transform")
        if not tr then return end
        u = tr:call("get_UniversalPosition")
        r = tr:call("get_Position")
    end)
    return u, r
end

-- ⛔ 08-12 round 2 (Drac spawned at coordinate twenty million): absolute-space
-- conversion arithmetic garbaged out. The doe-hunt's surviving recipe is
-- TRANSLATION-INVARIANT placement: the spaces differ by a pure translation, so
-- PLAYER_RENDER + (TARGET_UNIVERSAL - PLAYER_UNIVERSAL) is the target in render space,
-- built from small deltas. Only valid while NEAR -- which the 90m gate guarantees.
local function render_point_near(ax, ay, az)
    local u, r = player_spaces()
    if not (u and r) then return nil end
    return r.x + (ax - u.x), r.y + (ay - u.y), r.z + (az - u.z)
end

-- ⛔⛔ 08-12, THE FINAL COORD LESSON (Drac at X=20,304,876 with sane, MOVING Y/Z -- a
-- live bat wandering at coordinate twenty million): the spawner's position argument is
-- **via.Position (DOUBLES)**, not Vector3f -- a float vector reinterpreted as doubles
-- mangles X exactly like this. The probe's own make_position exists for this reason.
local function make_position(x, y, z)
    local p = ValueType.new(sdk.find_type_definition("via.Position"))
    p.x = x or 0
    p.y = y or 0
    p.z = z or 0
    return p
end
local function make_quat_identity()
    local q = ValueType.new(sdk.find_type_definition("via.Quaternion"))
    q.x = 0; q.y = 0; q.z = 0; q.w = 1
    return q
end

local function home_rows()
    local out = {}
    pcall(function()
        local b = bridge()
        local rows = b and b.stable_list and b.stable_list() or nil
        for _, r in ipairs(rows or {}) do
            if r.home then out[#out + 1] = r end
        end
    end)
    return out
end

local function despawn_all(why)
    if B.spawner then pcall(function() B.spawner:deleteAll() end) end
    B.bodies = {}
    B.addrs = {}
    if why then pcall(function() log.info("[IrisHomesteadBox] residents despawned (" .. tostring(why) .. ")") end) end
end

local function heal_code(sp, code)
    -- the probe's band_A_00 healing rule, verbatim in spirit
    local band = tostring(code or ""):match("ch%d+")
    local cid = nil
    pcall(function() cid = sp:getCharID(code) end)
    if cid and code ~= band then return code end
    if not band then return nil end
    local pick = nil
    pcall(function()
        local byName = sp.enums and sp.enums.charID and sp.enums.charID.byName
        if not byName then return end
        if byName[band .. "_A_00"] then pick = band .. "_A_00" return end
        for nm in pairs(byName) do
            nm = tostring(nm)
            if nm:find(band, 1, true) == 1 and nm ~= band then
                if not pick or #nm < #pick then pick = nm end
            end
        end
    end)
    return pick or code
end

-- ⛔⛔ 08-12 (Tails the drake, sent [H]ome, spawned as a FULL BOSS ENCOUNTER -- "Arisen...
-- Stand against me!" -- and torched the house): resident bodies keep their OWN combat AI,
-- and v1 has no predator calm. Only DOCILE species get bodies in the yard; predators keep
-- their [Home] flag but stay "indoors" (no body) until the calm arc ships.
local DOCILE = {
    ch299200 = true, ch299210 = true,                    -- rabbit, rat
    ch299400 = true, ch299410 = true, ch299430 = true,   -- bat, crow, bird
    ch299220 = true, ch299221 = true,                    -- fowl
    ch299003 = true,                                     -- ox
}

local function spawn_resident(rec, ax, ay, az, slot)
    if not ok_spawn then return false end
    local band0 = tostring(rec.species or ""):match("ch%d+") or ""
    if not DOCILE[band0] then
        B.warned_pred = B.warned_pred or {}
        if not B.warned_pred[rec.id] then
            B.warned_pred[rec.id] = true
            pcall(function() log.info("[IrisHomesteadBox] " .. tostring(rec.name)
                .. " stays indoors -- the yard cannot yet hold a predator's temper (calm arc pending)") end)
        end
        return false
    end
    B.spawner = B.spawner or SpawnRequest:new()
    -- placement: a deterministic ring slot per resident (stable spots, no pile-ups)
    -- ⛔⛔ 08-12 FINAL: `requestAddInstances` takes **UNIVERSAL** positions -- proven by
    -- Drac landing at exactly (my render point re-read as universal): body at
    -- (-372, 15, 1160) = my (-118, 15, 12) shifted by the player's 256/-1152 offsets,
    -- match to the metre. The plot anchor is ALREADY universal: feed it RAW. (The old
    -- "spawner speaks render" note was a different API surface -- law sharpened.)
    -- ⭐ 08-12 SAFE FLOOR (Mootilda in the stream below the cliff edge): the ring was
    -- terrain-blind. Every candidate is GROUND-PROBED (route3_cast_ground_below: x/z
    -- render in, universal contact y out); a floor >2m below the anchor is a cliff
    -- edge or water -- walk the golden angle to the next candidate. The accepted spot
    -- also fixes Y to just above the TRUE floor (better than the old blind +2.5).
    local ux, uz, uy = nil, nil, ay + 2.5
    local cast9 = rawget(_G, "route3_cast_ground_below")
    for try9 = 0, 7 do
        local a9 = ((slot + try9 * 11) * 2.399963)
        local r9 = (tonumber(C.ring_min) or 4.0)
            + ((slot + try9) % 3) * ((tonumber(C.ring_max) or 12.0) - (tonumber(C.ring_min) or 4.0)) / 3.0
        local cx9 = ax + math.sin(a9) * r9
        local cz9 = az + math.cos(a9) * r9
        if type(cast9) ~= "function" then ux, uz = cx9, cz9 break end
        local rx9, _, rz9 = render_point_near(cx9, ay, cz9)
        local hit9 = nil
        if rx9 then pcall(function() hit9 = cast9(rx9, ay + 3.0, rz9) end) end
        local hy9 = hit9 and tonumber(hit9.y) or nil
        if hy9 and (ay - hy9) < 2.0 and (hy9 - ay) < 3.0 then
            ux, uz, uy = cx9, cz9, hy9 + 1.2
            break
        end
        pcall(function() log.info(string.format(
            "[IrisHomesteadBox] ring candidate %d rejected for %s (floor dy=%s)",
            try9, tostring(rec.name), hy9 and string.format("%.1f", hy9 - ay) or "no hit")) end)
        if try9 == 7 and not ux then ux, uz = cx9, cz9 end   -- every probe failed: last spot, blind Y
    end
    pcall(function()
        log.info(string.format("[IrisHomesteadBox] spawn point %s: UNIVERSAL(%.1f, %.1f, %.1f)",
            tostring(rec.name), ux, uy, uz))
    end)
    local pos = make_position(ux, uy, uz)            -- via.Position doubles, UNIVERSAL, raw
    local rot = make_quat_identity()                 -- rot is a QUATERNION (the doe-spawn recipe)
    -- scale: species-true base x the resident's own size gene (the ONE calculator)
    local sc = 1.0
    pcall(function()
        local band = tostring(rec.species or ""):match("ch%d+") or ""
        local big = band == "ch253000" or band == "ch257000" or band == "ch257001"
            or band == "ch254000" or band == "ch258000"
        local base = big and 0.55 or 1.0
        local gene = rec.iv and tonumber(rec.iv.size) or 15
        sc = base * (iris_size_mult_for and iris_size_mult_for(rec.species, gene, base) or 1.0)
    end)
    local cfg = {
        spawnIdle = true,
        instLimit = tonumber(C.max_residents) or 8,
        spawnMultiple = { enable = false, qty = 1 },
        ovrScale = { enable = math.abs(sc - 1.0) > 0.01, scale = sc, normalizeSpeed = false },
    }
    pcall(function() B.spawner:updateConfig(cfg) end)
    -- a resident ch223 must never roll the wild-cat conversion
    if tostring(rec.species or ""):find("ch223", 1, true) then
        pcall(function()
            local capi = rawget(_G, "__iris_wild_cats_api")
            if capi and capi.claim_next then capi.claim_next("vanilla") end
        end)
    end
    local code = heal_code(B.spawner, tostring(rec.species or ""))
    local cid = nil
    pcall(function() cid = B.spawner:getCharID(code) end)
    if not cid then
        pcall(function() log.info("[IrisHomesteadBox] no CharacterID for " .. tostring(code) .. " -- resident skipped") end)
        return false
    end
    local ok = pcall(function() B.spawner:requestAddInstances(code, pos, rot, cfg, 1) end)
    if ok then
        B.bodies[rec.id] = { addr = nil, name = rec.name, code = code, at = os.clock(),
            want = { x = ux, y = uy, z = uz } }   -- the probed safe spot (the river check reads it)
        pcall(function() log.info("[IrisHomesteadBox] resident spawning: " .. tostring(rec.name)
            .. " (" .. tostring(code) .. ") scale " .. string.format("%.2f", sc)) end)
    end
    return ok
end

-- ⛔ 08-12 (Clucky: killed at her own homestead for +6 XP): residents had NO protection --
-- the party friend-shield only shapes pawn TARGETING, not the player's sword. The ritual
-- shield recipe (IrisTaming's set_immunity, replicated): the body's HitController refuses
-- all damage and drops its hit collision. Applied at settle + re-asserted every few
-- seconds (world streaming can rebuild components under a standing body).
local function resident_shield(ch)
    pcall(function()
        local go = ch and ch:call("get_GameObject")
        local hc = go and go:call("getComponent(System.Type)", sdk.typeof("app.HitController"))
        if not hc then return end
        for _, sig in ipairs({ "set_IsDamageZero", "set_IsIgnoreDamageHit", "set_DamageCollisionOff" }) do
            pcall(function() hc:call(sig, true) end)
        end
    end)
end

local function adopt_new_instances()
    -- bind freshly-constructed bodies to their records (order of request = order of
    -- instances), publish addrs, and register them into the probe's protection table
    -- so pawns treat residents as family (the unconditional party friend-shield).
    pcall(function()
        if not (B.spawner and B.spawner.instances) then return end
        local unbound = {}
        for id, e in pairs(B.bodies) do
            if not e.addr then unbound[#unbound + 1] = { id = id, e = e } end
        end
        if #unbound == 0 then return end
        table.sort(unbound, function(a, b) return (a.e.at or 0) < (b.e.at or 0) end)
        -- CENSUS (the two-bodies theory): every instance in the table at adoption time --
        -- a lingering husk from an earlier bad spawn would bind the record to the WRONG
        -- body while the fresh one stands unclaimed at the plot
        pcall(function()
            for i = 1, #B.spawner.instances do
                local inst = B.spawner.instances[i]
                local ch = inst.instance and inst.instance:get_Chara()
                local go = ch and ch:call("get_GameObject")
                if go then
                    local p = go:call("get_Transform"):call("get_Position")
                    local a = go:get_address()
                    log.info(string.format("[IrisHomesteadBox] census #%d: %s pos(%.1f, %.1f, %.1f) %s",
                        i, tostring(go:call("get_Name")), p.x, p.y, p.z,
                        B.addrs[a] and ("BOUND to " .. tostring(B.addrs[a])) or "unbound"))
                end
            end
        end)
        for i = 1, #B.spawner.instances do
            local inst = B.spawner.instances[i]
            local ch = nil
            pcall(function() ch = inst.instance and inst.instance:get_Chara() end)
            local go = nil
            pcall(function() go = ch and ch:call("get_GameObject") end)
            local addr = nil
            pcall(function() addr = go and go:get_address() end)
            if addr and not B.addrs[addr] then
                -- ⛔ 08-12 (the name swap): binding by ORDER alone crossed a hen onto an ox
                -- record. The species band must agree -- an instance only binds to a slot
                -- whose requested code shares its band.
                local iband = tostring(go and go:call("get_Name") or ""):match("ch%d+")
                local slot = nil
                for ui = 1, #unbound do
                    if tostring(unbound[ui].e.code or ""):match("ch%d+") == iband then
                        slot = table.remove(unbound, ui)
                        break
                    end
                end
                if not slot then goto next_instance end
                slot.e.addr = addr
                slot.e.ch = ch   -- kept for the shield heartbeat
                slot.e.verify_at = os.clock() + 3.0   -- position read-back receipt (below)
                B.addrs[addr] = slot.id
                resident_shield(ch)
                pcall(function()
                    local b = bridge()
                    if b and b.register_resident_body then b.register_resident_body(ch) end
                end)
                pcall(function() log.info("[IrisHomesteadBox] resident settled: " .. tostring(slot.e.name)) end)
            end
            ::next_instance::
        end
    end)
end

-- ⛔ 08-12 (the "requested, body not constructed yet" bat): the spawner lib is a QUEUE --
-- requests only become bodies when the pump runs each tick. The probe pumps its four
-- spawners with exactly this trio; without it, requestAddInstances waits forever.
re.on_application_entry("UpdateBehavior", function()
    if C.enabled == false or not B.spawner then return end
    local paused = false
    pcall(function() paused = type(griffin_world_paused) == "function" and griffin_world_paused() == true end)
    if paused then return end
    pcall(function()
        B.spawner:updateInstanceCounts()
        B.spawner:requestSpawnOutstanding()
        if B.spawner:hasAnyOutstandingPostProc() then B.spawner:processPostProc() end
    end)
end)

local sweep_at = 0.0
re.on_frame(function()
    if C.enabled == false then return end
    local now = os.clock()
    if now < sweep_at then return end
    sweep_at = now + 1.5
    pcall(function()
        local pu = select(1, player_spaces())
        if not pu then
            if next(B.bodies) then despawn_all("player lost (load?)") end
            return
        end
        local pp = pu   -- UNIVERSAL, same space as the plot anchors
        local plots = owned_plots()
        if #plots == 0 then return end
        -- v1: single owned plot (Aurora owns one); nearest-owned when more arrive
        local p = plots[1]
        local best_d2 = nil
        for _, cand in ipairs(plots) do
            local ax, ay, az = plot_anchor(cand)
            local dx, dz = ax - pp.x, az - pp.z
            local d2 = dx * dx + dz * dz
            if not best_d2 or d2 < best_d2 then best_d2 = d2; p = cand end
        end
        local ax, ay, az = plot_anchor(p)
        local d = math.sqrt(best_d2 or 1e12)
        -- receipts (the missing-bat lesson: a silent sweep cannot be diagnosed) --
        -- the shield heartbeat: never let a resident stand unshielded for long
        if (tonumber(B.shield_at) or 0.0) < now then
            B.shield_at = now + 3.0
            for _, e in pairs(B.bodies) do
                if e.ch then resident_shield(e.ch) end
            end
        end
        -- 10s heartbeat naming the plot, the distance, and the roster
        if (tonumber(B.dbg_at) or 0.0) < now then
            B.dbg_at = now + 10.0
            local souls = #home_rows()
            pcall(function() log.info(string.format(
                "[IrisHomesteadBox] plot '%s' anchor=%s d=%.0fm near=%s homeSouls=%d bodiesOut=%d",
                tostring(p.name), (C.use_t_anchor ~= false) and "t" or "u", d,
                tostring(B.near), souls, (function() local c = 0 for _ in pairs(B.bodies) do c = c + 1 end return c end)())) end)
        end
        if B.near and d > (tonumber(C.far_radius) or 130.0) then
            B.near = false
            despawn_all("left the homestead")
            return
        end
        if not B.near and d <= (tonumber(C.near_radius) or 90.0) then
            B.near = true
        end
        if not B.near then return end
        -- ⛔ never birth bodies while paused (the pause-spawn law); just wait a sweep
        local paused = false
        pcall(function() paused = type(griffin_world_paused) == "function" and griffin_world_paused() == true end)
        if paused then return end
        local rows = home_rows()
        -- ⛔ 08-12 (THREE Mootildas): a script reset invalidates the old managed wrappers --
        -- body resolution failed, the module concluded "no bodies" and spawned fresh while
        -- the orphans grazed on. THE REACQUIRE (the tamed-creature detection, ported): once
        -- per load, scan the scene near the plot, RE-BIND band-matching bodies to their
        -- records, and purge true surplus (unshield + WARP off the farm -- the eviction
        -- law: never destroy).
        if not reacquired_this_load then
            reacquired_this_load = true
            pcall(function()
                B.addrs = {}
                for _, e0 in pairs(B.bodies) do e0.addr = nil; e0.ch = nil end
                local comp_addr = nil
                pcall(function()
                    local b0 = bridge()
                    local gch0 = b0 and b0.griffin and b0.griffin()
                    local go0 = gch0 and gch0:call("get_GameObject")
                    comp_addr = go0 and go0:get_address()
                end)
                local sm0 = sdk.get_native_singleton("via.SceneManager")
                local smt0 = sdk.find_type_definition("via.SceneManager")
                local scene0 = sm0 and sdk.call_native_func(sm0, smt0, "get_CurrentScene")
                local comps0 = scene0 and scene0:call("findComponents(System.Type)", sdk.typeof("app.Character"))
                local n0 = 0
                pcall(function() n0 = comps0:call("get_Length") or 0 end)
                if n0 == 0 then pcall(function() n0 = comps0:get_size() or 0 end) end
                local strays = {}
                for i0 = 0, (tonumber(n0) or 0) - 1 do
                    pcall(function()
                        local ch0 = comps0:call("get_Item", i0) or comps0[i0]
                        local go0 = ch0 and ch0:call("get_GameObject")
                        if not go0 then return end
                        local addr0 = go0:get_address()
                        if addr0 == comp_addr then return end
                        local band0 = tostring(go0:call("get_Name") or ""):match("ch%d+")
                        if not (band0 and DOCILE[band0]) then return end
                        local u0 = go0:call("get_Transform"):call("get_UniversalPosition")
                        local dx0, dz0 = u0.x - ax, u0.z - az
                        if dx0 * dx0 + dz0 * dz0 > 35.0 * 35.0 then return end
                        strays[#strays + 1] = { ch = ch0, go = go0, addr = addr0, band = band0 }
                    end)
                end
                for _, r0 in ipairs(rows) do
                    if not (B.bodies[r0.id] and B.bodies[r0.id].addr) then
                        local rband0 = tostring(r0.species or ""):match("ch%d+")
                        for si0, s0 in ipairs(strays) do
                            if s0 and s0.band == rband0 then
                                B.bodies[r0.id] = B.bodies[r0.id] or { name = r0.name, at = os.clock() }
                                local e0 = B.bodies[r0.id]
                                e0.addr = s0.addr; e0.ch = s0.ch
                                B.addrs[s0.addr] = r0.id
                                resident_shield(s0.ch)
                                pcall(function()
                                    local b0 = bridge()
                                    if b0 and b0.register_resident_body then b0.register_resident_body(s0.ch) end
                                end)
                                strays[si0] = false
                                pcall(function() log.info("[IrisHomesteadBox] REACQUIRED "
                                    .. tostring(r0.name) .. " after reload (no duplicate spawned)") end)
                                break
                            end
                        end
                    end
                end
                for _, s0 in ipairs(strays) do
                    if s0 then
                        pcall(function()
                            local hc0 = s0.go:call("getComponent(System.Type)", sdk.typeof("app.HitController"))
                            if hc0 then
                                for _, sig0 in ipairs({ "set_IsDamageZero", "set_IsIgnoreDamageHit", "set_DamageCollisionOff" }) do
                                    pcall(function() hc0:call(sig0, false) end)
                                end
                            end
                            -- warp target ground-probed when the rig allows; wild again, elsewhere
                            local wx0, wz0 = ax + 120.0, az + 120.0
                            local wy0 = ay + 10.0
                            pcall(function()
                                local cast0 = rawget(_G, "route3_cast_ground_below")
                                local rx0, _, rz0 = render_point_near(wx0, ay, wz0)
                                local hit0 = cast0 and rx0 and cast0(rx0, ay + 30.0, rz0) or nil
                                if hit0 and tonumber(hit0.y) then wy0 = tonumber(hit0.y) + 1.5 end
                            end)
                            s0.go:call("get_Transform"):call("set_UniversalPosition", make_position(wx0, wy0, wz0))
                            log.info("[IrisHomesteadBox] surplus " .. tostring(s0.band)
                                .. " unshielded + warped off the farm (the duplication purge)")
                        end)
                    end
                end
            end)
        end
        -- spawn missing residents (deterministic slot per row order)
        local n = 0
        for i, r in ipairs(rows) do
            n = n + 1
            if n > (tonumber(C.max_residents) or 8) then break end
            if not B.bodies[r.id] then
                spawn_resident(r, ax, ay, az, i)
            end
        end
        -- retire bodies whose souls left home (called back / released / renamed away)
        local live_ids = {}
        for _, r in ipairs(rows) do live_ids[r.id] = true end
        for id, e in pairs(B.bodies) do
            if not live_ids[id] then
                -- no per-instance delete in the lib: rebuild the yard on the next pass
                despawn_all("roster changed")
                break
            end
        end
        adopt_new_instances()
        -- READ-BACK RECEIPT (Aurora: "still a million miles away"): 3s after settle, log
        -- the body's position through BOTH accessors. Garbage in both = accessor problem
        -- on this body class; sane-but-far = the engine/AI genuinely moved it; sane-and-
        -- near = the locator/plate were lying and the bat was home all along.
        for id, e in pairs(B.bodies) do
            if e.addr and e.verify_at and now >= e.verify_at then
                e.verify_at = nil
                pcall(function()
                    local go = nil
                    for i = 1, #B.spawner.instances do
                        local inst = B.spawner.instances[i]
                        local ch = inst.instance and inst.instance:get_Chara()
                        local g = ch and ch:call("get_GameObject")
                        if g and g:get_address() == e.addr then go = g break end
                    end
                    if not go then return end
                    local tr = go:call("get_Transform")
                    local r = tr:call("get_Position")
                    local u = tr:call("get_UniversalPosition")
                    local pu = select(1, player_spaces())
                    local d = pu and u and math.sqrt((u.x - pu.x) ^ 2 + (u.z - pu.z) ^ 2) or -1
                    log.info(string.format(
                        "[IrisHomesteadBox] READBACK %s: render(%.1f, %.1f, %.1f) universal(%.1f, %.1f, %.1f) d_universal=%.1fm",
                        tostring(e.name), r.x, r.y, r.z, u.x, u.y, u.z, d))
                    -- ⛔ 08-12 (Mootilda IN THE RIVER despite a safe-floor request): big-agent
                    -- spawns SNAP TO THEIR OWN NAVMESH -- the ox-sized navmesh on this
                    -- riverside plot lives on the bank below, so the engine relocated her
                    -- ~8m down and 5m sideways, ignoring our Y entirely. Post-settle
                    -- correction: warp the body back to the probed spot and CUT its
                    -- MonsterNavigationController (the yoke's census law: that component IS
                    -- the transform's driver) so the engine cannot walk it back down. She
                    -- stands and idles at the plot; the roam leash is slice 3's business.
                    if e.want and u and tonumber(u.y) < (tonumber(e.want.y) or 0.0) - 2.5 then
                        pcall(function()
                            tr:call("set_UniversalPosition",
                                make_position(e.want.x, e.want.y + 0.4, e.want.z))
                        end)
                        pcall(function()
                            local ch9 = nil
                            for i = 1, #B.spawner.instances do
                                local inst = B.spawner.instances[i]
                                local c9 = inst.instance and inst.instance:get_Chara()
                                local g9 = c9 and c9:call("get_GameObject")
                                if g9 and g9:get_address() == e.addr then ch9 = c9 break end
                            end
                            local g9 = ch9 and ch9:call("get_GameObject")
                            local mn9 = g9 and g9:call("getComponent(System.Type)", sdk.typeof("app.MonsterNavigationController"))
                            if mn9 then mn9:call("set_Enabled", false) end
                        end)
                        e.parked = true
                        pcall(function() log.info(string.format(
                            "[IrisHomesteadBox] %s settled %.1fm BELOW the safe spot (navmesh pulled it down) - warped home and PARKED (nav muscle cut)",
                            tostring(e.name), (tonumber(e.want.y) or 0.0) - tonumber(u.y))) end)
                    end
                end)
            end
        end
    end)
end)

-- nameplates + debug marker (d2d text over the imgui-free world = IrisFont territory)
re.on_frame(function()
    if C.enabled == false then return end
    pcall(function()
        if not (B.near and next(B.bodies)) then
            if not C.debug_marker then return end
        end
        local F = _G.IrisFont
        if C.debug_marker then
            for _, p in ipairs(owned_plots()) do
                local ax, ay, az = plot_anchor(p)
                local mx, my, mz = render_point_near(ax, ay, az)   -- draw wants RENDER too
                if not mx then mx, my, mz = ax, ay, az end
                local sp = draw.world_to_screen(Vector3f.new(mx, my + 1.5, mz))
                if sp then
                    local s = "[PLOT] " .. tostring(p.name or "?")
                    if not (F and F.text and F.text(s, sp.x, sp.y, 0xFFFFD080, 16)) then
                        draw.text(s, sp.x, sp.y, 0xFFFFD080)
                    end
                end
            end
        end
        if not (B.spawner and B.spawner.instances) then return end
        for i = 1, #B.spawner.instances do
            pcall(function()
                local inst = B.spawner.instances[i]
                local ch = inst.instance and inst.instance:get_Chara()
                local go = ch and ch:call("get_GameObject")
                local addr = go and go:get_address()
                local id = addr and B.addrs[addr]
                if not id then return end
                local e = B.bodies[id]
                local pos = go:call("get_Transform"):call("get_Position")
                local sp = draw.world_to_screen(Vector3f.new(pos.x, pos.y + 1.1, pos.z))
                if sp and e then
                    local s = tostring(e.name or "?")
                    if not (F and F.text and F.text(s, sp.x - #s * 3.5, sp.y, 0xFFB8E8B8, 16)) then
                        draw.text(s, sp.x - #s * 3.5, sp.y, 0xFFB8E8B8)
                    end
                end
            end)
        end
    end)
end)

re.on_draw_ui(function()
    if imgui.tree_node("IRIS Homestead Box (creatures live at the plot)") then
        local ch, v
        ch, v = imgui.checkbox("enabled", C.enabled ~= false)
        if ch then C.enabled = v; save_cfg(); if not v then despawn_all("disabled") end end
        ch, v = imgui.checkbox("debug: mark the plot anchor + names", C.debug_marker == true)
        if ch then C.debug_marker = v; save_cfg() end
        ch, v = imgui.checkbox("anchor = t* coords (untick to try u*)", C.use_t_anchor ~= false)
        if ch then C.use_t_anchor = v; save_cfg(); despawn_all("anchor flipped") end
        local n = 0
        for _ in pairs(B.bodies) do n = n + 1 end
        imgui.text(string.format("near: %s | residents out: %d | home souls: %d",
            tostring(B.near), n, #home_rows()))
        -- LOCATOR (Aurora: "confirm they're actually spawning and not, like, in the
        -- ground"): every tracked body with live coordinates, distance, and height
        -- relative to YOU -- readable even when the body is buried or off-screen
        pcall(function()
            -- ⛔ 08-12 FINAL FORM (the 20-million bat was a via.Position spawn-arg bug; the
            -- 1167m bat was THIS line mixing spaces one last time -- spawner-born bodies
            -- report universal == their render values): measure RENDER vs RENDER, the two
            -- numbers proven real. Same-space or no space.
            local pp = select(2, player_spaces())
            if not (B.spawner and B.spawner.instances) then
                if next(B.bodies) then imgui.text("  (bodies requested, spawner has no instances -- spawn refused?)") end
                return
            end
            local shown = {}
            for i = 1, #B.spawner.instances do
                pcall(function()
                    local inst = B.spawner.instances[i]
                    local ch = inst.instance and inst.instance:get_Chara()
                    local go = ch and ch:call("get_GameObject")
                    if not go then return end
                    local addr = go:get_address()
                    local id = B.addrs[addr]
                    local e = id and B.bodies[id]
                    local pos = go:call("get_Transform"):call("get_Position")   -- RENDER, like pp
                    local line
                    if pp then
                        local dx, dy, dz = pos.x - pp.x, pos.y - pp.y, pos.z - pp.z
                        local dist = math.sqrt(dx * dx + dz * dz)
                        line = string.format("  %s  @(%.0f, %.1f, %.0f)  %.0fm away, %.1fm %s you",
                            tostring(e and e.name or "(unbound body)"), pos.x, pos.y, pos.z,
                            dist, math.abs(dy), dy >= 0 and "ABOVE" or "BELOW")
                    else
                        line = string.format("  %s  @(%.0f, %.1f, %.0f)",
                            tostring(e and e.name or "(unbound body)"), pos.x, pos.y, pos.z)
                    end
                    imgui.text(line)
                    if id then shown[id] = true end
                end)
            end
            for id, e in pairs(B.bodies) do
                if not shown[id] and not e.addr then
                    imgui.text("  " .. tostring(e.name or "?") .. "  (requested, body not constructed yet)")
                end
            end
        end)
        if imgui.button("DEV: teleport me to the first resident") then
            pcall(function()
                local target = nil
                for i = 1, #(B.spawner and B.spawner.instances or {}) do
                    local inst = B.spawner.instances[i]
                    local ch = inst.instance and inst.instance:get_Chara()
                    local go = ch and ch:call("get_GameObject")
                    if go and B.addrs[go:get_address()] then target = go break end
                end
                if not target then B.tp_msg = "no resident body"; return end
                -- the body's RENDER pos converted to true universal through the player's
                -- own offset (bodies report universal==render; raw use would fling her)
                local bp = target:call("get_Transform"):call("get_Position")
                local u, r = player_spaces()
                if not (bp and u and r) or math.abs(bp.x) > 100000 or math.abs(bp.z) > 100000 then
                    B.tp_msg = "body position UNREADABLE - that IS the diagnosis"
                    return
                end
                local tx = bp.x + (u.x - r.x)
                local ty = bp.y + (u.y - r.y)
                local tz = bp.z + (u.z - r.z)
                local pgo = player_go()
                local ptr = pgo and pgo:call("get_Transform")
                if ptr then
                    ptr:call("set_UniversalPosition", make_position(tx + 2.0, ty + 0.5, tz + 2.0))
                    B.tp_msg = string.format("teleported beside the resident (render %.0f, %.0f, %.0f)", bp.x, bp.y, bp.z)
                end
            end)
        end
        if B.tp_msg then imgui.text(tostring(B.tp_msg)) end
        if imgui.button("despawn residents now") then despawn_all("manual") end
        if imgui.button("force respawn now (despawn + immediate rebuild)") then
            despawn_all("forced respawn")
            B.near = false   -- next sweep re-enters the yard fresh
        end
        imgui.tree_pop()
    end
end)
