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

local function spawn_resident(rec, ax, ay, az, slot)
    if not ok_spawn then return false end
    B.spawner = B.spawner or SpawnRequest:new()
    -- placement: a deterministic ring slot per resident (stable spots, no pile-ups)
    local ang = (slot * 2.399963)   -- golden angle: spreads any count evenly
    local rad = (tonumber(C.ring_min) or 4.0)
        + (slot % 3) * ((tonumber(C.ring_max) or 12.0) - (tonumber(C.ring_min) or 4.0)) / 3.0
    -- ⛔⛔ 08-12 FINAL: `requestAddInstances` takes **UNIVERSAL** positions -- proven by
    -- Drac landing at exactly (my render point re-read as universal): body at
    -- (-372, 15, 1160) = my (-118, 15, 12) shifted by the player's 256/-1152 offsets,
    -- match to the metre. The plot anchor is ALREADY universal: feed it RAW. (The old
    -- "spawner speaks render" note was a different API surface -- law sharpened.)
    local ux = ax + math.sin(ang) * rad
    local uz = az + math.cos(ang) * rad
    pcall(function()
        log.info(string.format("[IrisHomesteadBox] spawn point %s: UNIVERSAL(%.1f, %.1f, %.1f)",
            tostring(rec.name), ux, ay, uz))
    end)
    -- +2.5: the anchor Y is measured AT THE DEED SIGN; on sloped plots a ring spot can
    -- sit higher, and a surface-height spawn buries the body (Aurora heard Drac singing
    -- underground). Drop-in from above -- the engine settles bodies onto the ground.
    local pos = make_position(ux, ay + 2.5, uz)      -- via.Position doubles, UNIVERSAL, raw
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
        B.bodies[rec.id] = { addr = nil, name = rec.name, code = code, at = os.clock() }
        pcall(function() log.info("[IrisHomesteadBox] resident spawning: " .. tostring(rec.name)
            .. " (" .. tostring(code) .. ") scale " .. string.format("%.2f", sc)) end)
    end
    return ok
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
                local slot = table.remove(unbound, 1)
                if not slot then break end
                slot.e.addr = addr
                slot.e.verify_at = os.clock() + 3.0   -- position read-back receipt (below)
                B.addrs[addr] = slot.id
                pcall(function()
                    local b = bridge()
                    if b and b.register_resident_body then b.register_resident_body(ch) end
                end)
                pcall(function() log.info("[IrisHomesteadBox] resident settled: " .. tostring(slot.e.name)) end)
            end
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
