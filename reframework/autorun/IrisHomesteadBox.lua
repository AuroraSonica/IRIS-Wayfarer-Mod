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
    -- log FIRST (receipts round 2: the log line never appeared -- either this never
    -- fires or something above it died silently; now the log cannot be skipped)
    pcall(function() log.info("[IrisHomesteadBox] script reset detected - despawning residents") end)
    pcall(function() if B.spawner then B.spawner:deleteAll() end end)
    pcall(function()
        B.bodies = {}
        B.addrs = {}
        B.near = false
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
    -- THE HERD BELL (08-12): registered by position from the panel; the loader only
    -- restores DECLARED keys, so these must exist here or the bell forgets on reload
    bell_set = false, bell_x = 0.0, bell_y = 0.0, bell_z = 0.0,
    -- ⛔ these MUST be declared here: the loader below only restores keys that already exist
    -- in C, so an undeclared setting is silently dropped on every reload.
    bell_prompts   = true,    -- at a homestead: take "Await Oxcart" off the bell post
    bell_hide_sign = true,    -- ...and the notice-board "Examine" on the same post
    bell_dialog    = true,    -- ringing the bell opens the "who should come" dialog
    bell_plot_r    = 60.0,    -- how near an owned plot anchor a post counts as "homestead"
    bell_own_r     = 3.0,     -- how near a PLACED bell record a post must stand to be "ours"
    -- ⛔ KNOWN-BAD, default OFF: zeroing the timeskip args set the world to permanent midnight
    -- (Aurora, 08-13). Kept only as a documented switch -- see bell_neuter below.
    bell_neuter_skip = false,
}
pcall(function()
    local d = json.load_file(CFG)
    if type(d) == "table" then for k, v in pairs(d) do if C[k] ~= nil then C[k] = v end end end
end)
local function save_cfg() pcall(function() json.dump_file(CFG, C) end) end

local B = _G.IrisHomesteadBox or {}
_G.IrisHomesteadBox = B

-- ⛔⛔⛔ 08-13, THE BUG THAT KILLED THE WHOLE BELL SLICE, and it is this repo's oldest law
-- ([[lua-syntax-check]]): **a `local function` does not exist above its own definition.**
-- `nearest_bell_dist` (below) calls `player_spaces()`, but that was declared `local function`
-- ~130 lines FURTHER DOWN -- so the call compiled to a GLOBAL lookup, found nil, and threw
-- "attempt to call a nil value" into the pcall that wraps it. Silently. Every single time.
-- Consequences, all of which read in the field as separate mysteries:
--   * nearest_bell_dist() always returned nil -> at_the_bell() was ALWAYS false
--   * bell_neuter() returned on its first line -> the Await timeskip was NEVER neutered
--   * the "Ring for the Herd" prompt block never ran -> the tap-to-ring path was unreachable
-- The `bell scan: N` log line still printed because it sits ABOVE the faulting call - which is
-- exactly why this looked like "the scan is wrong" and not "the function is dead".
-- FIX: forward-declare both, and ASSIGN to the forward locals below (⛔ writing
-- `local function player_spaces()` again down there would create a NEW local that shadows
-- this one and the bug would survive the fix).
local player_go, player_spaces

-- ⛔ 08-12 (Aurora: "I don't want the oxcart timeskip in the homestead -- remove it"):
-- the Await-Oxcart hold calls app.TimeSkipManager:requestOxcartWarp(hour, min, day, ...)
-- (dump-verified dedicated method). We never SKIP the call (a null RequestData into an
-- unknown caller is CTD roulette) -- we NEUTER it: within homestead radius the skip
-- becomes 0h 0m 0d. A blink of fade, no hours lost, no cart. Everywhere else: untouched.
-- ⭐ 08-12 (Aurora: "I wanted the BELL to be the spot -- anyone can put a bell anywhere,
-- or have multiple bells"): bells are AUTO-DISCOVERED, never registered. The dump's
-- receipt: OxcartManager holds a `_gm63_042_01` field -- app.Gm63_042_01 IS the
-- oxcart-stop post class. Scene-scan for the component = every bell post in the world,
-- cached 4s; nearest one within reach is THE bell. (The panel registration survives as
-- a silent fallback for exotic bells the class scan misses.)
-- returns: distance (or nil), and the nearest bell record { ux, uy, uz } for the walk target
local function nearest_bell_dist()
    local best, best_b = nil, nil
    pcall(function()
        local now = os.clock()
        if not (B.bells and now < (tonumber(B.bells_at) or 0.0)) then
            -- 08-13 STUTTER (Aurora's A/B named the box): a SCENE-WIDE findComponents
            -- sweep every 4s is a rhythmic hitch. Bells do not move - 30s is plenty.
            B.bells_at = now + 30.0
            B.bells = {}
            local sm = sdk.get_native_singleton("via.SceneManager")
            local smt = sdk.find_type_definition("via.SceneManager")
            local scene = sm and sdk.call_native_func(sm, smt, "get_CurrentScene")
            -- ⛔⛔ 08-13 THE CLASS WAS WRONG. `app.Gm63_042_01` is a lockable GATE/DOOR gimmick
            -- (dump: DoorStartOpenSE / OpenSec / LockObj / CheckOpenPressId) with no interact
            -- point and no prefab -- it was inferred from an `OxcartManager._gm63_042_01` field
            -- that turns out to be a single gate reference. THE REAL BELL IS `app.Gm50_036_Bell`
            -- (prefabs gm50_036 / _01 / _02 / _03; IrisHomeLife.lua:415-421 already classified it
            -- as the Ring one-shot, and Aurora's placed bell is gm50_036_02).
            local comps = scene and scene:call("findComponents(System.Type)", sdk.typeof("app.Gm50_036_Bell"))
            local n = 0
            pcall(function() n = comps:call("get_Length") or 0 end)
            if n == 0 then pcall(function() n = comps:get_size() or 0 end) end
            for i = 0, (tonumber(n) or 0) - 1 do
                pcall(function()
                    local c = comps:call("get_Item", i) or comps[i]
                    local g = c:call("get_GameObject")
                    local tr = g:call("get_Transform")
                    local p = tr:call("get_Position")
                    -- ⭐ store BOTH spaces. The distance test below is render-vs-render, but the
                    -- herd walks in UNIVERSAL (call_tick reads get_UniversalPosition) -- taking a
                    -- walk target out of the render cache is the coord shear this file has a law
                    -- about. Read the universal off the SAME transform, in the same breath.
                    local u = tr:call("get_UniversalPosition")
                    B.bells[#B.bells + 1] = { x = p.x, y = p.y, z = p.z,
                                              ux = u and u.x, uy = u and u.y, uz = u and u.z }
                end)
            end
            if B.bell_scan_n ~= #B.bells then
                B.bell_scan_n = #B.bells
                pcall(function() log.info("[IrisHomesteadBox] bell scan: " .. #B.bells .. " oxcart-stop post(s) in the scene") end)
            end
        end
        local pu9, pr = player_spaces()
        if not pr then return end
        for _, b in ipairs(B.bells or {}) do
            local d = math.sqrt((b.x - pr.x) ^ 2 + (b.z - pr.z) ^ 2)
            if not best or d < best then best = d; best_b = b end
        end
        -- fallback: a hand-registered spot still counts (universal-space compare)
        if C.bell_set == true and pu9 then
            local d = math.sqrt((pu9.x - C.bell_x) ^ 2 + (pu9.z - C.bell_z) ^ 2)
            if not best or d < best then
                best = d
                best_b = { ux = C.bell_x, uy = C.bell_y, uz = C.bell_z }
            end
        end
    end)
    return best, best_b
end

-- how close counts as "at the bell". Was an inline 4.5 in three places while the UI text said
-- 3m; one name so they can never drift apart again.
local BELL_REACH = 4.5

local function at_the_bell()
    local d = nearest_bell_dist()
    return d ~= nil and d <= BELL_REACH
end

-- ⛔⛔⛔ 08-13 THE NEUTER IS RETIRED, AND IT IS OFF BY DEFAULT. Aurora's field report:
-- "it seems to have made the world permanently night time." That is exactly what this did.
-- These args are not a DELTA to skip, they are the TARGET time -- so writing 0/0/0 set the
-- clock to 00:00 and, worse, plausibly day 0 (the farming growth clock and the breeding
-- gestation clock both read app.TimeManager get_InGameDay, so a zeroed day is not cosmetic).
-- It never fired before today only because at_the_bell() was dead (the law at the top of this
-- file); fixing that function is what let this loose.
-- ⇒ The right fix for "no Await Oxcart at home" is to REMOVE THE PROMPT (bell_points_tick),
-- not to corrupt the clock behind it. Left in place, disabled, purely so the reasoning
-- survives with the code: turning `bell_neuter_skip` back on is a known-bad idea.
local function bell_neuter(args, label)
    if C.bell_neuter_skip ~= true then return end
    if not at_the_bell() then return end
    pcall(function()
        args[3] = sdk.to_ptr(0)   -- hour   ⛔ TARGET, not delta -- this is the midnight bug
        args[4] = sdk.to_ptr(0)   -- min
        args[5] = sdk.to_ptr(0)   -- day    ⛔ and this one moves the farming/gestation clock
    end)
    -- ⭐ 08-13 THIS IS NOW A PURE AIRBAG, and that is a deliberate downgrade. It used to also
    -- fire B.call_all() and a toast ("the neutered hold IS a bell-pull") -- but it had never
    -- actually run once (at_the_bell() was dead, see the law at the top of this file), and now
    -- that it CAN run, the Await prompt it was compensating for is removed outright by
    -- bell_points_tick and ringing is the interact hook's job. Leaving the call in here would
    -- mean a hold fired a second, competing herd-call behind the dialog -- and three methods
    -- are hooked, of which `request` is very likely the internal delegate of the other two, so
    -- it would fire more than once per press. Neuter the skip, say so, do nothing else.
    pcall(function() log.info("[IrisHomesteadBox] " .. tostring(label)
        .. " at the bell -> timeskip neutered (airbag; the prompt should already be gone)") end)
end

if not _G.IrisHomesteadOxcartWarpHook2 then
    pcall(function()
        local td = sdk.find_type_definition("app.TimeSkipManager")
        -- the Await is a WAIT-IN-PLACE: hook BOTH the plain skip and the cart warp
        -- (the first hook watched only the warp -- the log stayed silent, the receipt)
        for _, mn in ipairs({ "requestTimeSkip", "requestOxcartWarp", "request" }) do
            local m = td and td:get_method(mn)
            if m then
                local label = mn
                sdk.hook(m, function(args) bell_neuter(args, label) end, function(r) return r end)
                pcall(function() log.info("[IrisHomesteadBox] bell-neuter hook installed on " .. label) end)
            else
                pcall(function() log.info("[IrisHomesteadBox] bell-neuter: method NOT FOUND: " .. tostring(mn)) end)
            end
        end
        _G.IrisHomesteadOxcartWarpHook2 = true
    end)
end
B.bodies = B.bodies or {}     -- rec.id -> { addr = go addr, name, at }
B.addrs = B.addrs or {}       -- go addr -> rec.id (produce gate + fast lookup)
B.spawner = B.spawner or nil
B.near = B.near or false

-- the produce gate's question (IrisFarming): is this GO one of the homestead's animals?
B.is_resident = function(go_addr)
    return go_addr ~= nil and B.addrs[go_addr] ~= nil
end
B.resident_id = function(go_addr)
    return go_addr ~= nil and B.addrs[go_addr] or nil
end
B.resident_name = function(go_addr)
    local id = go_addr ~= nil and B.addrs[go_addr] or nil
    local e = id and B.bodies[id] or nil
    return e and e.name or nil
end
-- the stable's question (08-12, Aurora: "you should need to go up to them at the home
-- to actually return them"): may a home soul be called back RIGHT NOW? Yes only when
-- standing at the homestead -- or when this module is disabled (never strand a soul).
B.can_collect = function()
    if C.enabled == false then return true end
    return B.near == true
end

local function bridge() return rawget(_G, "IrisGriffinBridge") end

-- ⭐⭐⭐ ROUND 10 - THE NATIVE AIM EXEMPTION (08-13, aim-probe receipts + il2cpp).
-- Component surgery lost 9 rounds because the swing homing is app.LockOnController,
-- which feeds setAimTargetInfoToCharacter - and it filters targets by ASKING, not by
-- reading the target's components. It already exempts two classes natively: neutral/
-- friend animals and THE OXCART OX (isAnimalWithoutOxcart - why the cart ox never
-- draws swings). Residents claim the same exemptions: all three filter questions
-- answer "not a targetable animal" for our registered bodies. Components stay WHOLE
-- (HC/LockOn/Hate all restorable) - the game simply never considers them.
-- Hooks persist across script resets; closures read _G fresh each call (pin-safe).
if not B.aim_exempt_hooked then
    B.aim_exempt_hooked = true
    local function is_res_ch(ch)
        local ra = rawget(_G, "IrisResidentChAddrs")
        return ra ~= nil and ch ~= nil and ra[ch:get_address()] == true
    end
    pcall(function()
        sdk.hook(sdk.find_type_definition("app.LockOnController")
            :get_method("isAnimalWithoutOxcart(app.Character)"),
            function(args)
                local hit = false
                pcall(function()
                    hit = is_res_ch(sdk.to_managed_object(args[2]))
                end)
                thread.get_hook_storage().iris_res_exempt = hit
            end,
            function(retval)
                if thread.get_hook_storage().iris_res_exempt then
                    return sdk.to_ptr(false)
                end
                return retval
            end)
        pcall(function() log.info("[IrisHomesteadBox] aim exemption armed: isAnimalWithoutOxcart") end)
    end)
    for _, mname in ipairs({
        "isCharacterWithoutNeutralOrFriendAnimal(app.LockOnTargetWork)",
        "isTargetEnableLockOn(app.LockOnTargetWork)",
    }) do
        pcall(function()
            sdk.hook(sdk.find_type_definition("app.LockOnController"):get_method(mname),
                function(args)
                    local hit = false
                    pcall(function()
                        local work = sdk.to_managed_object(args[3])
                        hit = is_res_ch(work and work:call("get_Character"))
                    end)
                    thread.get_hook_storage().iris_res_exempt2 = hit
                end,
                function(retval)
                    if thread.get_hook_storage().iris_res_exempt2 then
                        return sdk.to_ptr(false)
                    end
                    return retval
                end)
            pcall(function() log.info("[IrisHomesteadBox] aim exemption armed: " .. mname) end)
        end)
    end
end

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

player_go = function()          -- ⛔ assignment, NOT `local function` (see the law above)
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
player_spaces = function()      -- ⛔ assignment, NOT `local function` (see the law above)
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

-- Physics is render-space.  The herd target and resident positions are universal,
-- so the player's live universal/render delta is the only safe conversion.  This
-- ray uses static world collision only: an animal or the bell itself cannot block it.
local bell_ray = { ready = false }
local function bell_ray_ready()
    if bell_ray.ready then return true end
    local ok = pcall(function()
        bell_ray.system = sdk.get_native_singleton("via.physics.System")
        bell_ray.method = sdk.find_type_definition("via.physics.System")
            :get_method("castRay(via.physics.CastRayQuery, via.physics.CastRayResult)")
        bell_ray.query = sdk.create_instance("via.physics.CastRayQuery"):add_ref()
        bell_ray.result = sdk.create_instance("via.physics.CastRayResult"):add_ref()
        bell_ray.query:clearOptions(); bell_ray.query:enableAllHits(); bell_ray.query:enableNearSort()
        bell_ray.filter = bell_ray.query:get_FilterInfo()
    end)
    bell_ray.ready = ok and bell_ray.system ~= nil and bell_ray.method ~= nil
        and bell_ray.query ~= nil and bell_ray.result ~= nil and bell_ray.filter ~= nil
    return bell_ray.ready == true
end

local function bell_path_clear(from_u, to_u)
    if not (from_u and to_u) or not bell_ray_ready() then return true end -- fail open
    local pu, pr = player_spaces()
    if not (pu and pr) then return true end
    local tx, ty, tz = to_u.x or to_u.ux, to_u.y or to_u.uy, to_u.z or to_u.uz
    if not (tx and ty and tz) then return true end
    local dx, dz = tx - from_u.x, tz - from_u.z
    local d = math.sqrt(dx * dx + dz * dz)
    if d <= 3.0 then return true end
    -- Stop short of the bell post: it is the destination, not an obstruction.
    local trim = math.min(1.5, d * 0.25)
    tx, tz = tx - dx / d * trim, tz - dz / d * trim
    local ox, oy, oz = pu.x - pr.x, pu.y - pr.y, pu.z - pr.z
    local hits = 0
    pcall(function()
        local function v3(x, y, z)
            local v = ValueType.new(sdk.find_type_definition("via.vec3"))
            v.x, v.y, v.z = x, y, z
            return v
        end
        bell_ray.filter:set_Group(0); bell_ray.filter:set_Layer(2); bell_ray.filter:set_MaskBits(0)
        bell_ray.result:clear()
        bell_ray.query:call("setRay(via.vec3, via.vec3)",
            v3(from_u.x - ox, from_u.y - oy + 0.8, from_u.z - oz),
            v3(tx - ox, ty - oy + 0.8, tz - oz))
        bell_ray.method:call(bell_ray.system, bell_ray.query, bell_ray.result)
        hits = tonumber(bell_ray.result:get_NumContactPoints()) or 0
    end)
    return hits == 0
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
    -- ⭐ 08-12 SPAWN PINS (the Homestead Screen's core, shipped early): a soul with a
    -- personal pin spawns THERE -- where the player stood to set it (known-good ground,
    -- +0.6 drop-in) -- and skips the ring lottery entirely.
    if type(rec.home_pin) == "table" and tonumber(rec.home_pin.x) then
        ux, uy, uz = tonumber(rec.home_pin.x), (tonumber(rec.home_pin.y) or ay) + 0.6, tonumber(rec.home_pin.z)
    end
    for try9 = 0, 7 do
        if ux then break end   -- pinned: the ring never runs
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
        -- ⭐ 08-13 (Aurora: "everyone at home looks very large"): the companion path also
        -- multiplies the body's innate wild variance (rec.wild_base, 0.85-1.15) - home
        -- bodies now wear it too, so a resident is EXACTLY its summoned size
        local wb = tonumber(rec.wild_base)
        if wb and wb > 0.5 and wb < 1.5 then sc = sc * wb end
        -- 08-12 BREEDING slice 1: newborns are SMALL -- 0.45x at birth easing to their
        -- full gene size across the growth days (the in-game clock)
        local d0, d1 = tonumber(rec.growth_born), tonumber(rec.growth_mature)
        if d0 and d1 then
            local b9 = bridge()
            local day9 = b9 and b9.breed_day and b9.breed_day() or nil
            if day9 and day9 < d1 then
                sc = sc * (0.45 + 0.55 * math.max(0.0, math.min(1.0, (day9 - d0) / math.max(1, d1 - d0))))
            end
        end
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
            want = { x = ux, y = uy, z = uz },
            spawn = { x = ux, y = uy, z = uz } } -- immutable fall-return point
        pcall(function() log.info("[IrisHomesteadBox] resident spawning: " .. tostring(rec.name)
            .. " (" .. tostring(code) .. ") scale " .. string.format("%.2f", sc)) end)
    end
    return ok
end

-- ⭐ 08-12 FAST-TRACKED (Aurora: "the bell moving creatures... to help fix this"): THE
-- CALL. Every resident walks to the player -- the fix for wall-stuck and river-strayed
-- bodies, and the breeding gather. v1 trigger: the call key (K) near the plot + the
-- panel button; the oxcart bell's Examine interact takes over in the bell slice.
-- Movement = the yoke recipe: think stop + FSM parked + walk clip + position steps
-- (the sliding law: clips must own the body or hooves slide).
local function call_clip(ch, bank, id)
    pcall(function()
        local mo = ch:call("get_Motion")
        local layer = mo and mo:call("getLayer", 0)
        if layer then
            layer:call("changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                bank, id, 0.0, 8.0, 1, 1)
        end
    end)
end

local function call_hold(ch, go, hold)
    pcall(function() ch:call("set_IsThinkStop(System.Boolean)", hold == true) end)
    pcall(function()
        local fsm = go:call("getComponent(System.Type)", sdk.typeof("via.motion.MotionFsm2"))
        if fsm then fsm:call("set_Enabled", hold ~= true) end
    end)
    -- ⛔ 08-12 (Aurora: "they stutter over... the ox slid back after it arrived"): the
    -- NAV CONTROLLER translates the TRANSFORM directly (the yoke rite's law) - it fights
    -- every universal step of the call walk, and after the handback it walks the body
    -- straight back to its old anchor. Cut the muscle when the call starts and LEAVE it
    -- cut at arrival (the arrival comment always promised "nav safely cut" - now it is).
    -- Critters without a nav controller are untouched.
    pcall(function()
        local nav = go:call("getComponent(System.Type)", sdk.typeof("app.MonsterNavigationController"))
        if nav then nav:call("set_Enabled", false) end
    end)
end

-- ⭐ 08-13 THE WALK TARGET (Aurora: "when you select one, it moves them to the bell").
-- `tgt` = { ux, uy, uz } in UNIVERSAL space, or nil for "walk to whoever rang" (the player).
-- ⛔ It must be universal: call_tick measures with get_UniversalPosition, and B.bells caches
-- render as well -- handing it a render point is the coord shear this file already has scars from.
local function bell_gather_target(tgt)
    if not tgt then return nil end
    local pu = select(1, player_spaces())
    local tx, tz = tonumber(tgt.x or tgt.ux), tonumber(tgt.z or tgt.uz)
    if not (pu and tx and tz) then return tgt end
    -- Gather on the RINGER'S side of the bell. The decorative homestead wall has enough
    -- physical presence to stop the puppet, but not enough query presence for the LOS cast;
    -- steering to the bell centre therefore accepted the wrong side of it. A point 1.8m
    -- towards the player is both reachable and visibly "at the bell".
    local dx, dz = (tonumber(pu.x) or tx) - tx, (tonumber(pu.z) or tz) - tz
    local dl = math.sqrt(dx * dx + dz * dz)
    if dl < 0.20 then dx, dz, dl = 1.0, 0.0, 1.0 end
    return { x = tx + dx / dl * 1.8, y = tonumber(pu.y) or tonumber(tgt.y or tgt.uy) or 0.0,
        z = tz + dz / dl * 1.8, bell = true }
end

B.call_all = function(tgt)
    local n = 0
    for _, e in pairs(B.bodies) do
        if e.ch and e.addr then
            e.calling = true; e.call_clip_on = nil; e.parked = nil
            e.call_los_at = nil; e.call_prog = nil; n = n + 1
        end
    end
    B.call_target = bell_gather_target(tgt)
    B.call_until = os.clock() + 45.0
    B.call_last = nil     -- the first tick must not bill itself for the idle gap since the last call
    pcall(function() log.info("[IrisHomesteadBox] THE CALL: " .. n .. " resident(s) called to "
        .. (tgt and "the bell" or "the player")) end)
    return n
end

-- ⭐ 08-12 THE HOMESTEAD SCREEN: call ONE resident by soul id (the Animals tab's
-- "call this one"). Same machinery as call_all - only the one body gets e.calling.
B.call_one = function(id, tgt)
    local e = B.bodies[id]
    if not (e and e.ch and e.addr) then return false end
    e.calling = true
    e.call_clip_on = nil
    e.parked = nil
    e.call_los_at = nil
    e.call_prog = nil
    B.call_target = bell_gather_target(tgt)
    B.call_until = os.clock() + 45.0
    B.call_last = nil
    pcall(function() log.info("[IrisHomesteadBox] THE CALL (one): " .. tostring(e.name) .. " called to "
        .. (tgt and "the bell" or "the player")) end)
    return true
end

local function call_tick(now)
    if not B.call_until then return end
    if now > B.call_until then
        for _, e in pairs(B.bodies) do
            if e.calling then
                pcall(function()
                    local go = e.ch:call("get_GameObject")
                    local tr = go:call("get_Transform")
                    local u = tr:call("get_UniversalPosition")
                    if B.call_target then
                        local tg = B.call_target
                        local tx, ty, tz = tg.x or tg.ux, tg.y or tg.uy, tg.z or tg.uz
                        local p = { x = tx, y = ty + 0.25, z = tz }
                        tr:call("set_UniversalPosition", make_position(p.x, p.y, p.z))
                        e.want = { x = p.x, y = p.y, z = p.z }
                        e.parked = true
                        call_hold(e.ch, go, true); call_clip(e.ch, 0, 0)
                    else
                        call_hold(e.ch, go, false)
                    end
                end)
                e.calling, e.call_prog, e.call_clip_on = nil, nil, nil
            end
        end
        B.call_until = nil
        B.call_target = nil
        return
    end
    local pu, pr = player_spaces()
    if not (pu and pr) then return end
    -- ⭐ 08-13 steer to the BELL when one rang, else to the player (the K key / panel button).
    local tg = B.call_target or pu
    local dt = math.max(0.005, math.min(0.1, now - (tonumber(B.call_last) or now)))
    B.call_last = now
    local live = 0
    for _, e in pairs(B.bodies) do
        if e.calling and e.ch then
            pcall(function()
                local go = e.ch:call("get_GameObject")
                local tr = go:call("get_Transform")
                local u = tr:call("get_UniversalPosition")
                -- ⛔ the ARRIVAL test below must measure against the SAME point we steer at:
                -- steering at the bell while testing arrival against the player would leave
                -- them shuffling at the bell forever whenever she stepped away from it.
                local dx, dz = (tg.x or tg.ux) - u.x, (tg.z or tg.uz) - u.z
                local dd = math.sqrt(dx * dx + dz * dz)
                local arrival = B.call_target and 1.15 or 3.0
                if dd < arrival then
                    -- arrived: hand the body back (small ones resume their wander at
                    -- your feet; parked bigs stand with you, nav still safely cut).
                    -- ⭐ 08-12: the arrival spot becomes the body's new truth - without
                    -- this, the navmesh-snap verifier warps it back to the OLD want.
                    e.calling = nil
                    e.call_prog = nil
                    -- ⭐ 08-13 (Aurora: "when they arrive at the bell, they stay in
                    -- that proximity"): the arrival spot IS the new want/home truth,
                    -- so the verifier and any re-place keep them by the bell.
                    e.want = { x = u.x, y = u.y, z = u.z }
                    if B.call_target then
                        -- Bell calls are a gather-and-stay command.  Keep the AI parked
                        -- and put the rig into a single standing idle once it arrives.
                        e.parked = true
                        call_hold(e.ch, go, true)
                        call_clip(e.ch, 0, 0)
                    else
                        e.parked = nil
                        call_hold(e.ch, go, false)
                    end
                    return
                end
                live = live + 1
                -- A wall or terrain ridge between resident and bell cannot be solved by
                -- transform-stepping.  Detect it immediately and carry the animal to the
                -- near side of the bell instead of making it wait for the stuck timer.
                if B.call_target and now >= (tonumber(e.call_los_at) or 0.0) then
                    e.call_los_at = now + 0.35
                    if not bell_path_clear(u, tg) then
                        local tx, ty, tz = tg.x or tg.ux, tg.y or tg.uy, tg.z or tg.uz
                        local px, pz = tx, tz
                        local py = ty + 0.25
                        tr:call("set_UniversalPosition", make_position(px, py, pz))
                        e.want = { x = px, y = py, z = pz }
                        e.calling, e.call_prog, e.call_clip_on = nil, nil, nil
                        e.parked = true
                        call_hold(e.ch, go, true); call_clip(e.ch, 0, 0)
                        pcall(function() log.info("[IrisHomesteadBox] " .. tostring(e.name)
                            .. " had no line of sight to the bell - carried beside it and parked") end)
                        return
                    end
                end
                -- ⭐ 08-13 STUCK RESCUE: watch progress TOWARDS the bell, not raw
                -- displacement. A resident scraping sideways along Ratina's decorative
                -- homestead wall moves plenty but never closes the distance, so the old
                -- position-only test could run forever. Gain 0.35m = refresh the timer;
                -- otherwise four seconds is enough evidence that the puppet path is lost.
                local pg = e.call_prog
                if not pg then
                    e.call_prog = { best_d = dd, t = now }
                elseif dd < (tonumber(pg.best_d) or dd) - 0.35 then
                    pg.best_d, pg.t = dd, now
                elseif B.call_target and (now - (tonumber(pg.t) or now)) > 4.0 then
                    local tx, ty, tz = tg.x or tg.ux, tg.y or tg.uy, tg.z or tg.uz
                    local px, pz = tx, tz
                    local py = (ty or u.y) + 0.25
                    tr:call("set_UniversalPosition", make_position(px, py, pz))
                    e.want = { x = px, y = py, z = pz }
                    e.calling, e.call_prog, e.call_clip_on = nil, nil, nil
                    e.parked = true
                    call_hold(e.ch, go, true); call_clip(e.ch, 0, 0)
                    pcall(function() log.info("[IrisHomesteadBox] " .. tostring(e.name)
                        .. " made no progress towards the bell for 4s - carried beside it and parked") end)
                    return
                end
                call_hold(e.ch, go, true)
                if not e.call_clip_on then
                    e.call_clip_on = true
                    call_clip(e.ch, 0, 100)   -- com_walk_loop, the ch99 rig convention
                end
                local step = math.min(dd, 1.7 * dt)
                tr:call("set_UniversalPosition",
                    make_position(u.x + dx / dd * step, u.y, u.z + dz / dd * step))
                local yaw = math.atan(dx, dz)
                local q = make_quat_identity()
                q.y = math.sin(yaw / 2.0); q.w = math.cos(yaw / 2.0)
                tr:call("set_Rotation", q)
            end)
        end
    end
    if live == 0 then B.call_until = nil; B.call_target = nil end
end

-- Continuous cliff/fall guard.  Spawn is deliberately immutable: bell calls may move
-- `want`, but a falling animal always returns to the safe ground-probed point it entered
-- the homestead at, exactly as the Animals screen promises.
local safety_at = 0.0
local function resident_safety_tick(now)
    if now < safety_at then return end
    safety_at = now + 0.12
    local cast = rawget(_G, "route3_cast_ground_below")
    for _, e in pairs(B.bodies) do
        if e.ch and e.spawn then pcall(function()
            local go = e.ch:call("get_GameObject")
            local tr = go and go:call("get_Transform")
            local u = tr and tr:call("get_UniversalPosition")
            local r = tr and tr:call("get_Position")
            if not (u and r) then return end
            -- A rescue is itself a downward settle: we place the body 0.4 m over
            -- its anchor and the controller lowers it onto the floor.  The old
            -- detector interpreted that normal settle as another fall every
            -- 120 ms, especially when the optional ground probe returned nil.
            -- Give the controller time to settle and never turn an unavailable
            -- probe into `math.huge` (which means "definite abyss").
            if now < (tonumber(e.safety_recover_until) or 0.0) then
                e.safety_y = tonumber(u.y)
                e.safety_fall = nil
                return
            end
            local last_y = tonumber(e.safety_y)
            local falling = last_y ~= nil and tonumber(u.y) < last_y - 0.18
            e.safety_y = tonumber(u.y)
            local floor = nil
            if type(cast) == "function" then
                pcall(function() floor = cast(r.x, u.y, r.z, 0.7, 6.0) end)
            end
            local floor_gap = floor and (tonumber(u.y) - tonumber(floor.y)) or nil
            local below_spawn = tonumber(u.y) < (tonumber(e.spawn.y) or 0.0) - 2.5
            -- A valid ray can confirm a drop immediately.  If the ray is
            -- unavailable, require a continuous fall of both time and distance;
            -- one noisy Y sample or an ordinary 40 cm spawn settle is not a fall.
            local unsupported_fall = false
            if falling and (not floor_gap or floor_gap > 1.8) then
                if not e.safety_fall then
                    e.safety_fall = { at = now, y = last_y or tonumber(u.y) }
                end
                local sf = e.safety_fall
                unsupported_fall = floor_gap ~= nil
                    or (now - (tonumber(sf.at) or now) >= 0.45
                        and (tonumber(sf.y) or tonumber(u.y)) - tonumber(u.y) >= 1.0)
            elseif not falling or (floor_gap and floor_gap <= 1.0) then
                e.safety_fall = nil
            end
            if below_spawn or unsupported_fall then
                tr:call("set_UniversalPosition", make_position(
                    e.spawn.x, (tonumber(e.spawn.y) or 0.0) + 0.4, e.spawn.z))
                e.want = { x = e.spawn.x, y = e.spawn.y, z = e.spawn.z }
                e.calling, e.call_prog, e.call_clip_on = nil, nil, nil
                e.parked = true
                e.safety_y = (tonumber(e.spawn.y) or 0.0) + 0.4
                e.safety_fall = nil
                e.safety_recover_until = now + 2.0
                call_hold(e.ch, go, true); call_clip(e.ch, 0, 0)
                pcall(function() log.info("[IrisHomesteadBox] " .. tostring(e.name)
                    .. " was detected falling - returned to its safe spawn point") end)
            end
        end) end
    end
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
        -- ⭐⭐ 08-13 AIM PROBE VERDICT (the dump receipts): LockOnTarget AND
        -- AIActionTargetInfoController were both confirmed DISABLED on the live
        -- chicken while the hoe still homed - our levers stick, they were just the
        -- wrong ones. The ONLY targeting component still enabled on the resident:
        -- app.HateSystem, the combat-participation ledger - and the round-6 suspects
        -- ladder's unreached last rung ("then the hate side"). Hate goes OFF, and
        -- the HitController comes BACK - if hate is the homing's true handle, the
        -- animals keep their whole bodies (milk/eggs/interacts) at the same time.
        pcall(function() hc:call("set_Enabled", true) end)
        pcall(function()
            local hs = go:call("getComponent(System.Type)", sdk.typeof("app.HateSystem"))
            if hs then hs:call("set_Enabled", false) end
        end)
        -- ⭐ 08-13 round 7 (Aurora's clean experiment: re-stable Clucky = hoe fine;
        -- near the rat = auto-aim at the rat - 100% the resident BODIES): the aim's
        -- physical handle is app.LockOnTarget (the probe clears its TargetData to
        -- de-target the griffin). No component, no handle, nothing to acquire.
        pcall(function()
            local lo = go:call("getComponent(System.Type)", sdk.typeof("app.LockOnTarget"))
            if lo then
                pcall(function() lo:set_field("TargetData", nil) end)
                lo:call("set_Enabled", false)
            end
        end)
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

-- ══════════════════════════════════════════════════════════════════════════════════════
-- THE HOMESTEAD BELL POST: deciding which of its three prompts the player may use
-- ══════════════════════════════════════════════════════════════════════════════════════
-- Aurora 08-13: "I only want the bell interaction to work and not the await oxcart... just
-- replace 'Await oxcart' entirely with the examine bell ring (but only in a homestead plot)."
--
-- ⭐ THE SHAPE OF THE PROBLEM (offline prefab table + catalog.json, not guessed): ONE prefab
-- (gm50_036_02) carries THREE interact points on THREE different owner components:
--     app.Gm50_036       IconType 12 WaitOxcart  CharacterType 1 (Player)  <- Capcom lit this
--     app.Gm50_036_Bell  IconType  0 Search      CharacterType 8 (Human)   <- the RING
--     app.gm81_128       IconType  0 Search      CharacterType 1 (Player)  <- notice board
-- So "Await Oxcart" was never ours to remove by NOT adding it -- it ships player-capable.
-- The fix is the exact INVERSE of Interactables.lua's Engine A unlock: a per-point data write
-- clearing the Player bit. Same field, same readback discipline, same restore.
--
-- ⛔⛔ WE WALK THE BELL'S OWN GAMEOBJECT, NEVER SCAN BY CLASS. `app.gm81_128` is ALSO the
-- class of the homestead DEED SIGN -- a scene-wide scan that neutered gm81_128 near a plot
-- would take away the sign Aurora buys and manages her plots with. Starting from the bell
-- component and walking ITS GameObject's components cannot reach any other object.
--
-- ⛔ 1 -> 8 (Human), never 1 -> 0. CharacterType 8 is a proven-legal authored value (405
-- NPC-only points ship with it, and it is what Interactables' restore writes back); an empty
-- mask is authored nowhere in the game and is untested.
local BELL_LOCK_ICON = { [12] = "Await Oxcart", [0] = "signboard" }
local bell_pts = {}          -- [point addr] = { point, old_ct, tag }
local bell_scan_at = 0.0
local bell_census_done = {}  -- [go addr] = true, so the diagnostic prints once per post

local function _addr(o)
    local a = nil
    pcall(function() a = o:get_address() end)
    return a
end

local function _arr(list)
    local out = {}
    if not list then return out end
    pcall(function()
        -- ⚠ per-item pcall: one throwing element must not abandon the whole array (a single
        -- outer pcall would silently return a SHORT list, which reads exactly like "the scene
        -- doesn't have that component").
        local n = nil
        pcall(function() n = tonumber(list:call("get_Length")) end)
        if n == nil then pcall(function() n = tonumber(list:get_size()) end) end
        for i = 0, (n or 0) - 1 do
            local v = nil
            pcall(function() v = list:call("get_Item", i) end)
            if v == nil then pcall(function() v = list[i] end) end
            if v then out[#out + 1] = v end
        end
    end)
    return out
end

-- write one point's CharacterType, verify the readback, and remember the old value.
-- Returns true only when the engine agreed.
local function bell_set_ct(point, new_ct, tag)
    local a = _addr(point)
    if not a then return false end
    local ct = nil
    pcall(function() ct = tonumber(point:get_field("CharacterType")) end)
    if ct == nil or ct == new_ct then return false end
    local wrote = pcall(function() point:set_field("CharacterType", new_ct) end)
    local rb = nil
    if wrote then pcall(function() rb = tonumber(point:get_field("CharacterType")) end) end
    if rb ~= new_ct then
        pcall(function() log.info("[IrisHomesteadBox] bell point " .. tostring(tag)
            .. ": CharacterType write REFUSED (" .. tostring(ct) .. " -> " .. tostring(new_ct)
            .. ", readback " .. tostring(rb) .. ")") end)
        return false
    end
    if bell_pts[a] == nil then bell_pts[a] = { point = point, old_ct = ct, tag = tag } end
    pcall(function() log.info("[IrisHomesteadBox] bell point " .. tostring(tag)
        .. ": CharacterType " .. tostring(ct) .. " -> " .. tostring(new_ct)) end)
    return true
end

local function bell_points_restore(why)
    local n = 0
    for a, r in pairs(bell_pts) do
        -- ⛔ these are managed wrappers cached across ticks; after an area change they can
        -- point at freed data, and a pcall does NOT catch an access violation -- but it does
        -- catch the ordinary "invalid object" throw, which is the common case. Callers must
        -- also DROP the table without writing when the world went away (see the sweep).
        pcall(function() r.point:set_field("CharacterType", r.old_ct) end)
        bell_pts[a] = nil
        n = n + 1
    end
    if n > 0 then
        pcall(function() log.info("[IrisHomesteadBox] bell points restored: " .. n
            .. " (" .. tostring(why) .. ")") end)
    end
end

-- forget every cached point WITHOUT writing to it (the world is gone / the wrappers are stale)
local function bell_points_forget(why)
    local n = 0
    for a in pairs(bell_pts) do bell_pts[a] = nil; n = n + 1 end
    bell_census_done = {}
    if n > 0 then
        pcall(function() log.info("[IrisHomesteadBox] bell points dropped unwritten: " .. n
            .. " (" .. tostring(why) .. ")") end)
    end
end

-- ⭐⭐ 08-13 (Aurora: "can I just confirm the removal of the await oxcart is only for the
-- oxcart bells in the homestead? I don't want to break the normally placed in-world ones which
-- need that action."). A plot RADIUS alone does not promise that -- if the game happened to
-- author a real oxcart stop within the radius of her plot, the radius would silence it too.
-- ⇒ THE REAL GATE IS IDENTITY: a post is only touched if it stands where SHE PLACED a bell,
-- read from the furnish system's own record file. A world oxcart stop is not in that file, so
-- it can never match, whatever the distance.
local placed_bells, placed_bells_at = nil, 0.0
local function placed_bell_list()
    local now = os.clock()
    if placed_bells and now < placed_bells_at then return placed_bells end
    -- ⛔ 08-13 THE STUTTER'S TRUE SOURCE (survived the scan fix): a DISK json read
    -- + parse every 5s. Furniture changes only when Aurora places it - 120s cache;
    -- a freshly placed bell answers within two minutes, the frame-time every 5s.
    placed_bells_at = now + 120.0
    local out = {}
    pcall(function()
        local d = json.load_file("IRIS/iris_furniture.json")
        for _, r in ipairs(d or {}) do
            local gid = tostring(r.gid or "")
            -- every oxcart-bell prefab: gm50_036, _01, _02, _03
            if gid:match("^gm50_036") and tonumber(r.ux) and tonumber(r.uz) then
                out[#out + 1] = { x = tonumber(r.ux), y = tonumber(r.uy) or 0.0, z = tonumber(r.uz) }
            end
        end
    end)
    placed_bells = out
    return placed_bells
end

-- does a post at this UNIVERSAL position correspond to a bell Aurora placed herself?
local function is_placed_bell(u, radius)
    local r = tonumber(radius) or 3.0
    for _, b in ipairs(placed_bell_list()) do
        local dx, dz = b.x - u.x, b.z - u.z
        if dx * dx + dz * dz <= r * r then return true end
    end
    return false
end

-- is this world position inside one of the owned plots? (UNIVERSAL space, like plot anchors)
local function near_owned_plot(ux, uz, radius)
    local r = tonumber(radius) or 60.0
    for _, p in ipairs(owned_plots()) do
        local ax, _, az = plot_anchor(p)
        if ax and az then
            local dx, dz = ax - ux, az - uz
            if dx * dx + dz * dz <= r * r then return true end
        end
    end
    return false
end

-- patch every interact point on ONE component. `role` decides the rule.
local function bell_patch_comp(comp, tn, role, census)
    pcall(function()
        -- BOTH lists must be written: the authored template and the live runtime copy the
        -- InteractiveObject serves from (Interactables' law).
        local lists = {}
        pcall(function() lists[#lists + 1] = comp:get_field("InteractiveObjectDataList") end)
        local io = nil
        pcall(function() io = comp.InteractiveObject end)
        if not io then pcall(function() io = comp:get_field("InteractiveObject") end) end
        if io then pcall(function() lists[#lists + 1] = io:get_field("DataList") end) end

        for _, list in ipairs(lists) do
            for idx, point in ipairs(_arr(list)) do
                local icon, ct
                pcall(function() icon = tonumber(point:get_field("IconType")) end)
                pcall(function() ct = tonumber(point:get_field("CharacterType")) end)
                if census then
                    local cpi = nil
                    if io then pcall(function() cpi = io:call("canPlayerInteract", idx - 1) end) end
                    pcall(function() log.info(string.format(
                        "[IrisHomesteadBox] bell census: %s point[%d] icon=%s ct=%s canPlayerInteract=%s",
                        tn, idx - 1, tostring(icon), tostring(ct), tostring(cpi))) end)
                end
                if icon and ct then
                    local player_bit = (ct % 2) == 1
                    local human_bit = (math.floor(ct / 8) % 2) == 1
                    if role == "await" and icon == 12 and player_bit then
                        bell_set_ct(point, (ct == 1) and 8 or (ct - 1), "Await Oxcart")
                    elseif role == "sign" and icon == 0 and player_bit then
                        bell_set_ct(point, (ct == 1) and 8 or (ct - 1), "signboard")
                    elseif role == "ring" and icon == 0 and human_bit and not player_bit then
                        -- ⭐ light the RING ourselves rather than depending on Interactables'
                        -- name-normalised unlock: a SPAWNED gimmick can report a rig name its
                        -- catalog key never matches ("a spawned gm80_257 reports gmSeat"), in
                        -- which case that unlock silently never reaches this point and there
                        -- is no prompt to ring at all.
                        bell_set_ct(point, ct + 1, "ring the bell")
                    end
                end
            end
        end
    end)
end

-- find every component of `type_name` whose GameObject passes `accept(universal_pos)`.
local function bell_each(scene, type_name, accept, fn)
    pcall(function()
        local comps = scene:call("findComponents(System.Type)", sdk.typeof(type_name))
        for _, c in ipairs(_arr(comps)) do
            pcall(function()
                local go = c:call("get_GameObject")
                local tr = go and go:call("get_Transform")
                local u = tr and tr:call("get_UniversalPosition")
                if not u then return end
                if not accept(u) then return end
                local ga = _addr(go)
                local key = tostring(ga) .. "|" .. type_name
                local census = (ga ~= nil and not bell_census_done[key])
                if census then bell_census_done[key] = true end
                fn(c, go, u, census)
            end)
        end
    end)
end

local function bell_points_tick(now)
    if C.bell_prompts == false then return end
    if now < bell_scan_at then return end
    bell_scan_at = now + 2.0
    -- ⚠ re-asserted on a cadence rather than written once: the WaitOxcart point's component
    -- carries IsRegistInteractAuto = 0, i.e. its owner registers it itself and may re-stamp
    -- the runtime copy from the authored template on a state change.
    pcall(function()
        local sm = sdk.get_native_singleton("via.SceneManager")
        local smt = sdk.find_type_definition("via.SceneManager")
        local scene = sm and sdk.call_native_func(sm, smt, "get_CurrentScene")
        if not scene then return end

        -- ⛔⛔ 08-13 FIELD RECEIPT, and it killed the previous version outright. The census
        -- printed exactly ONE line -- `app.Gm50_036_Bell point[0]` -- and no app.Gm50_036 at
        -- all, so the Await Oxcart point does NOT live on the bell's GameObject. The post is
        -- several GameObjects, one per owner component. Walking the bell's own components can
        -- never reach the sign, which is why "Await Oxcart (Hold)" survived the last build.
        -- ⇒ find each owner class SEPARATELY, scene-wide, and gate each by position.
        -- ⛔⛔ BOTH gates, and the second one is the promise: near an owned plot AND standing
        -- exactly where the furnish system records that SHE placed a bell. A vanilla oxcart
        -- stop is in no record file, so no distance makes it eligible.
        local function in_plot(u)
            if not near_owned_plot(u.x, u.z, C.bell_plot_r) then return false end
            if not is_placed_bell(u, C.bell_own_r) then return false end
            return true
        end

        -- 1) the BELL itself -> light the ring. Also remember where the posts are, so the
        --    notice board can be identified by standing ON one.
        local posts = {}
        bell_each(scene, "app.Gm50_036_Bell", in_plot, function(c, go, u, census)
            posts[#posts + 1] = u
            bell_patch_comp(c, "app.Gm50_036_Bell", "ring", census)
        end)

        -- 2) "Await Oxcart" -> app.Gm50_036. ✅ Safe to sweep scene-wide: that class is ONLY
        --    the oxcart-stop post, so the plot radius is the whole gate it needs.
        bell_each(scene, "app.Gm50_036", in_plot, function(c, go, u, census)
            bell_patch_comp(c, "app.Gm50_036", "await", census)
        end)

        -- 3) the notice board -> app.gm81_128. ⛔⛔ THAT CLASS IS ALSO THE HOMESTEAD DEED SIGN,
        --    the thing Aurora buys and manages plots with. A plot-radius sweep would silence
        --    it. So this one is gated on being physically INSIDE a bell post (2m) -- a deed
        --    sign standing 2m inside the bell is not a thing.
        if C.bell_hide_sign ~= false and #posts > 0 then
            bell_each(scene, "app.gm81_128", function(u)
                if not in_plot(u) then return false end
                for _, p in ipairs(posts) do
                    local dx, dy, dz = p.x - u.x, (p.y or 0) - (u.y or 0), p.z - u.z
                    if dx * dx + dy * dy + dz * dz <= 2.0 * 2.0 then return true end
                end
                return false
            end, function(c, go, u, census)
                bell_patch_comp(c, "app.gm81_128", "sign", census)
            end)
        end
    end)
end

-- ══════════════════════════════════════════════════════════════════════════════════════
-- THE RING: a native dialog asking who should come
-- ══════════════════════════════════════════════════════════════════════════════════════
-- ⛔ RetVal (il2cpp app.ui010101.RetVal, authoritative -- three modules in this tree carry a
-- WRONG mapping in their comments and self-correct later): Sel0=1 Sel1=2 Sel2=3 Sel3=4 Cancel=5
local DLG_TYPE = 14          -- app.GuiDefine.GuiType.Dialog
local PER_PAGE = 3
local dlg = { open = false, baseline = nil, opened_at = 0, phase = nil,
              nil_since = nil, closed_at = 0, page = 0, opts = nil, more = false, tgt = nil }
local ring_pending = nil     -- os.clock() at which the ring's dialog should open

local function _gm() return sdk.get_managed_singleton("app.GuiManager") end

local function _dialog_pick()
    local p
    pcall(function()
        local gm = _gm()
        local rv = gm and gm:call("getDialogState")
        if rv == nil then return end
        if type(rv) == "number" then p = rv
        else pcall(function() p = sdk.to_int64(rv) & 0xFFFFFFFF end) end
    end)
    return p
end

local function _close_dialog()
    pcall(function()
        local gm = _gm()
        local d = gm and gm:get_field("Dialog")
        if d then d:call("reqClose") end
        if gm then gm:call("requestHideGuiType", DLG_TYPE) end
    end)
    dlg.open, dlg.phase, dlg.nil_since, dlg.opts = false, nil, nil, nil
    dlg.closed_at = os.clock()
    if _G.IrisNativeDialogOwner and _G.IrisNativeDialogOwner.who == "homesteadbox" then
        _G.IrisNativeDialogOwner = nil
    end
end
pcall(_close_dialog)   -- softlock guard: a reload must never strand a paused dialog

-- ⛔ SIX other IRIS modules poll the SAME singleton getDialogState and none of them publishes
-- ownership, so two readers can both act on one pick. Ask the dialog itself whether it is
-- already on screen, and publish a claim for everyone who comes after us.
local function _dialog_busy_elsewhere()
    if _G.IrisFurnishUIOpen or _G.IrisFurnishFootprint or _G.IrisStableUIOpen then return true end
    local o = _G.IrisNativeDialogOwner
    if o and o.who ~= "homesteadbox" and (os.clock() - (tonumber(o.at) or 0)) < 60.0 then return true end
    local disp = nil
    pcall(function()
        local gm = _gm()
        local d = gm and gm:get_field("Dialog")
        if d then disp = d:call("get_IsDisp") end
    end)
    return disp == true
end

local function _show_dialog(prompt, o1, o2, o3, o4, phase)
    pcall(function()
        local gm = _gm()
        local d = gm and gm:get_field("Dialog")
        if not d then return end
        pcall(function() d:set_field("Ret", 0) end)   -- belt & braces; the baseline is the real mechanism
        gm:call("requestGuiType", DLG_TYPE)
        -- arg 20 = restrain_input_time. Every other module passes 0.0; 0.3 buys native input
        -- restraint over the B-release edge that opened us, on top of our own debounce.
        d:call("reqDisp", prompt, o1 or "", o2 or "", o3 or "", o4 or "",
            true, 0, true, 58, 0, -1, nil,
            false, false, false, false, false, false, true, 0.3)
        dlg.open, dlg.opened_at, dlg.baseline = true, os.clock(), _dialog_pick()
        dlg.phase, dlg.nil_since = phase, nil
        _G.IrisNativeDialogOwner = { who = "homesteadbox", at = os.clock() }
    end)
end

-- the animal picker page. ⭐ A CANCEL ON EVERY PAGE: when the list paginates we show TWO
-- animals and keep BOTH tail options -- IrisFarming shipped the 3+one-tail version and it left
-- a paginated list with no visible way out on page one.
local function _show_pick_page(page)
    local rows = home_rows()
    if #rows == 0 then
        _close_dialog()
        pcall(function()
            local T = rawget(_G, "IrisTaming")
            if T and T.prompt then T.prompt("THE BELL RINGS", "Nobody is home to answer it.", 4.0, 0xFFB0C0FF) end
        end)
        return
    end
    local per = (#rows > PER_PAGE) and (PER_PAGE - 1) or PER_PAGE
    local first = page * per
    local opts = {}
    for i = 1, per do
        local r = rows[first + i]
        if r then opts[#opts + 1] = r end
    end
    if #opts == 0 then                      -- ran off the end: wrap to page 0
        -- ⛔ `page` itself must be reset, not just dlg.page -- the assignment below writes
        -- `page` back onto dlg and would otherwise restore the off-the-end value, so the
        -- next "More..." would page into nothing again, forever.
        page = 0
        first, opts = 0, {}
        for i = 1, per do
            local r = rows[i]
            if r then opts[#opts + 1] = r end
        end
    end
    local more = (first + #opts) < #rows
    local labels = {}
    for i, r in ipairs(opts) do
        labels[i] = tostring(r.name or "?") .. (r.label and ("  (" .. tostring(r.label) .. ")") or "")
    end
    dlg.opts, dlg.more, dlg.page = opts, more, page
    labels[#labels + 1] = more and "More..." or "Cancel"
    if more then labels[#labels + 1] = "Cancel" end
    _show_dialog("Who should come to the bell?", labels[1], labels[2], labels[3], labels[4], "pick")
end

local function _bell_target()
    local _, b = nearest_bell_dist()
    if b and b.ux then return { ux = b.ux, uy = b.uy, uz = b.uz } end
    return nil
end

local function _ring_open()
    if dlg.open or _dialog_busy_elsewhere() then
        pcall(function() log.info("[IrisHomesteadBox] ring: another dialog owns the screen - skipped") end)
        return
    end
    local rows = home_rows()
    if #rows == 0 then
        pcall(function()
            local T = rawget(_G, "IrisTaming")
            if T and T.prompt then T.prompt("THE BELL RINGS", "Nobody is home to answer it.", 4.0, 0xFFB0C0FF) end
        end)
        return
    end
    dlg.tgt = _bell_target()
    dlg.page = 0
    _show_dialog("The bell rings out across the homestead. Who should come?",
        "All animals", "Select an animal", "Cancel", nil, "bell")
end

local function _dialog_tick()
    if not dlg.open then
        if ring_pending and os.clock() >= ring_pending then
            ring_pending = nil
            _ring_open()
        end
        return
    end
    local now = os.clock()
    local raw = _dialog_pick()
    -- LIVENESS: a live dialog answers with a number (0 while untouched). Sustained nil means
    -- something else took the screen -- better than waiting out the 30s stuck guard.
    if raw == nil then
        dlg.nil_since = dlg.nil_since or now
        if now - dlg.nil_since > 1.5 then _close_dialog(); return end
    else
        dlg.nil_since = nil
    end
    local p = raw
    if p ~= nil and p ~= dlg.baseline then dlg.baseline = p else p = nil end
    if p ~= nil and (now - dlg.opened_at) < 0.25 then p = nil end     -- debounce
    if p == nil then
        if now - dlg.opened_at > 30.0 then _close_dialog() end
        return
    end

    if dlg.phase == "bell" then
        if p == 1 then
            local tgt = dlg.tgt
            _close_dialog()
            B.call_all(tgt)
        elseif p == 2 then
            _close_dialog()
            -- a breath between a dialog and its follow-up (the deed sign's law)
            dlg.next_at, dlg.next_page = now + 0.35, 0
        else
            _close_dialog()
        end
        return
    end

    if dlg.phase == "pick" then
        local opts, more = dlg.opts or {}, dlg.more
        local n = #opts
        if p >= 1 and p <= n then
            local row = opts[p]
            local tgt = dlg.tgt
            _close_dialog()
            if row and row.id then
                local okc = B.call_one(row.id, tgt)
                if not okc then
                    pcall(function()
                        local T = rawget(_G, "IrisTaming")
                        if T and T.prompt then T.prompt(tostring(row.name),
                            "is home, but has no body out here to walk.", 4.0, 0xFFB0C0FF) end
                    end)
                end
            end
        elseif more and p == n + 1 then
            _close_dialog()
            dlg.next_at, dlg.next_page = now + 0.35, (dlg.page or 0) + 1
        else
            _close_dialog()   -- the tail Cancel, or the native Cancel (5)
        end
        return
    end
    _close_dialog()
end

-- the deferred follow-up (page turns and the bell -> picker handoff)
local function _dialog_followup()
    if dlg.next_at and not dlg.open and os.clock() >= dlg.next_at then
        local pg = dlg.next_page or 0
        dlg.next_at, dlg.next_page = nil, nil
        _show_pick_page(pg)
    end
end

-- ⛔ THE READER RUNS FIRST AND UNGUARDED. Our own dialog pauses the world (is_pause=true), so
-- a reader sitting behind a pause guard can never see the answer -- that is a softlock, and it
-- is a law this repo wrote in blood (the deed sign).
re.on_application_entry("UpdateBehavior", function()
    if C.enabled == false then return end
    pcall(_dialog_tick)
    pcall(_dialog_followup)
end)

-- ⭐ THE TRIGGER: observe the bell's OWN native interact STARTING. We never skip it, never
-- cancel it, never call into the interact system -- we only notice that it fired.
-- ⭐⭐ 08-13 MOVED onEnd -> onStart (Aurora: "can we have the dialogue appear before the ring?
-- Right now it feels weird to ring the bell and wait 5 seconds for the dialogue box"). She is
-- right, and the old placement was the cause: onEndInteractBase does not fire until the whole
-- ring animation has played out. Firing at the START means the dialog opens on the next game
-- tick -- and because the dialog pauses the world (is_pause), the ring is held at its first
-- frame BEHIND the menu and only plays out once she has answered. So the dialogue really does
-- come first.
-- ⚠ Opening a dialog during a live interact is not new ground: IrisDeedSign ships exactly this
-- (it preempts the requestGuiType that the native Examine itself raises). What is forbidden is
-- driving the interact FLOW -- cancelInteract / endInteract / abort -- and we do none of that.
-- ⛔ THE ORPHAN LAW: REFramework hooks are permanent for the process, and a script reset
-- leaves the OLD closure installed with its OLD upvalues -- so a hook body written inline can
-- only ever be changed by restarting the game. Route it through a _G entry point that every
-- generation re-assigns, and edits take effect on a plain reset. (This is the same pattern
-- IrisWeaponMount uses for its action-block hook.)
_G.IrisHomesteadBellRing = function(bell_u)
    if C.enabled == false or C.bell_dialog == false then return end
    if not B.near then return end
    -- ⛔ IDENTITY, not proximity: only a bell SHE PLACED opens the herd dialog. Ringing a real
    -- world oxcart-stop bell that happens to be near the plot behaves exactly as vanilla.
    if not (bell_u and is_placed_bell(bell_u, C.bell_own_r)) then return end
    -- next tick, not this one: the dialog is raised from our own UpdateBehavior pump, never
    -- from inside the engine's interact callback.
    ring_pending = os.clock() + 0.02
    pcall(function() log.info("[IrisHomesteadBox] the bell is being rung - opening the herd dialog") end)
end

if not _G.IrisHomesteadBellRingHook then
    pcall(function()
        local td = sdk.find_type_definition("app.Gm50_036_Bell")
        local m = td and td:get_method("onStartInteractBase(System.UInt32, app.Character)")
        if not m then
            pcall(function() log.info("[IrisHomesteadBox] ring hook: onStartInteractBase NOT FOUND on app.Gm50_036_Bell") end)
            return
        end
        -- the PRE pass only reads WHICH bell this is; the POST pass acts. (args[2] = `this`.)
        local ringing_u = nil
        sdk.hook(m,
            function(args)
                ringing_u = nil
                pcall(function()
                    local comp = sdk.to_managed_object(args[2])
                    local go = comp and comp:call("get_GameObject")
                    local tr = go and go:call("get_Transform")
                    local u = tr and tr:call("get_UniversalPosition")
                    if u then ringing_u = { x = u.x, y = u.y, z = u.z } end
                end)
            end,
            function(retval)
                pcall(function()
                    local f = rawget(_G, "IrisHomesteadBellRing")
                    if type(f) == "function" then f(ringing_u) end
                end)
                return retval
            end)
        _G.IrisHomesteadBellRingHook = true
        pcall(function() log.info("[IrisHomesteadBox] ring hook installed on app.Gm50_036_Bell.onStartInteractBase") end)
    end)
end

-- ⛔ A SECOND reset handler, deliberately down HERE. The one at the top of this file was
-- written before any of this existed, and a closure cannot capture a `local` that is declared
-- after it -- referencing bell_points_restore up there would compile to a nil global and fail
-- silently, which is the exact bug that killed the bell slice in the first place.
re.on_script_reset(function()
    pcall(function() bell_points_restore("script reset") end)
    pcall(_close_dialog)          -- never strand a paused dialog across a reload
    pcall(function()
        B.call_until, B.call_target, B.call_paused_at = nil, nil, nil
    end)
end)

-- ⛔ 08-12 (the "requested, body not constructed yet" bat): the spawner lib is a QUEUE --
-- requests only become bodies when the pump runs each tick. The probe pumps its four
-- spawners with exactly this trio; without it, requestAddInstances waits forever.
re.on_application_entry("UpdateBehavior", function()
    if C.enabled == false then return end
    local paused = false
    pcall(function() paused = type(griffin_world_paused) == "function" and griffin_world_paused() == true end)
    if paused then
        -- ⛔ 08-13 FREEZE THE CALL CLOCK ACROSS A PAUSE. call_until/call_last are WALL clock,
        -- and our own native dialog pauses the world (reqDisp is_pause=true) -- so picking an
        -- animal out of a menu used to spend the walk window standing still in a paused world,
        -- and the first tick after the unpause would bill itself for the entire pause.
        if B.call_until and not B.call_paused_at then B.call_paused_at = os.clock() end
        return
    end
    if B.call_paused_at then
        local held = os.clock() - B.call_paused_at
        if B.call_until then B.call_until = B.call_until + held end
        B.call_paused_at = nil
        B.call_last = nil          -- next dt starts fresh, not `held` seconds wide
    end
    -- ⭐⭐ 08-13 THE CALL MOVES HERE, AND THAT IS THE WHOLE FIX FOR "they barely move".
    -- call_tick used to be driven from the on_frame sweep, which self-throttles to 1.5s, while
    -- its own dt is clamped to 0.1 -- so a resident advanced 1.7 * 0.1 = 17cm every 1.5s
    -- (~0.11 m/s), about 5m of travel in the entire 45s window, and anything further away
    -- than that never reached the 3m arrival radius at all. On UpdateBehavior the dt is real
    -- and the walk runs at its intended 1.7 m/s.
    -- ⛔ It sits AFTER the pause gate on purpose: set_UniversalPosition writes on a paused
    -- world are the pause-spawn crash family. It sits BEFORE the spawner guard because the
    -- herd must still walk in a session where the spawner never came up.
    pcall(function() call_tick(os.clock()) end)
    pcall(function() resident_safety_tick(os.clock()) end)
    if not B.spawner then return end
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
            -- ⛔ DROP the cached interact points WITHOUT writing to them. A load screen means
            -- the old scene is going away; those are managed wrappers onto data that may
            -- already be freed, and a pcall does not catch an access violation. The fresh
            -- scene's posts get re-locked by the next scan anyway.
            bell_points_forget("player lost (load?)")
            return
        end
        local pp = pu   -- UNIVERSAL, same space as the plot anchors
        local plots = owned_plots()
        if #plots == 0 then bell_points_restore("no owned plots"); return end
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
        -- THE CALL: movement tick + triggers. (1) K near the plot (the blunt lever).
        -- (2) ⭐ THE HERD BELL (08-12, Aurora: "is there any reason we can't do the bell
        -- now?"): the bell is REGISTERED BY POSITION (stand at it, press the panel
        -- button) -- no gimmick identity needed. A TAP of interact (pad B / keyboard F)
        -- within 3m of the registered bell rings it natively (the Examine fires
        -- untouched -- free anim + sound) AND calls the herd. A HOLD stays the Await
        -- timeskip, unaffected: tap and hold part ways at 0.35s.
        -- (call_tick moved to UpdateBehavior 08-13 -- this sweep is 1.5s and was starving it)
        -- ⭐ the bell post's prompts: locked while you are at the homestead, handed straight
        -- back the moment you leave, so world oxcart stops are never touched.
        if B.near then bell_points_tick(now) else bell_points_restore("left the homestead") end
        if B.near then
            local kd = false
            pcall(function() kd = type(iris_kb) == "function" and iris_kb(0x4B) == true end)
            if kd and not B.call_key_prev then B.call_all() end
            B.call_key_prev = kd
            -- ⛔⛔ 08-13 THE PHANTOM PUBLISHER IS GONE, and removing it is part of the
            -- one-prompt-at-a-time fix. This block used to publish "Ring for the Herd (tap)"
            -- into the shared arbiter with dist<=4.5 -- close enough to WIN it -- while its own
            -- tap sampler was unreachable dead code (it lived in this 1.5s-throttled sweep and
            -- required a press+release inside 0.35s, which two samples 1.5s apart can never
            -- observe). So standing at the bell it could out-bid milking or a chore and then do
            -- nothing at all: a prompt that silences everyone and answers to no one. That was
            -- harmless while nobody consulted the arbiter; now that taming does, it would be a
            -- real blocker.
            -- ⇒ The bell is served by its OWN NATIVE interact now (the ring hook opens the herd
            -- dialog), so it needs no IRIS prompt and no key of its own. K remains as the blunt
            -- lever, and the panel button as the dev path.
            B.bell_down_t = nil
            pcall(function()
                if _G.IrisPrompt then
                    _G.IrisPrompt.set("herd_bell", "")
                    if _G.IrisPrompt.clear_slot then _G.IrisPrompt.clear_slot("herd_bell") end
                end
            end)
        end
        -- the shield heartbeat: never let a resident stand unshielded for long.
        -- ⭐ 08-13 (Aurora's receipt: "summoned pets never draw my swings" - residents
        -- do): the relationship hook matched mounts{} by WRAPPER identity; residents
        -- registered with OUR wrappers matched nothing. Publish the live CHARACTER
        -- addresses every heartbeat - the hook now matches residents by ADDRESS (the
        -- HoldWolf pattern, the proven cure for the wrapper-identity disease).
        if (tonumber(B.shield_at) or 0.0) < now then
            -- 08-13 STUTTER (the A/B named the box): shielding the WHOLE roster in
            -- one frame every 3s was the rhythm Aurora felt. Round-robin: ONE body
            -- per 0.7s beat - the flags are sticky, so each body is still re-asserted
            -- every few seconds; the address publish is cheap and stays whole.
            B.shield_at = now + 0.7
            local ids = {}
            for id in pairs(B.bodies) do ids[#ids + 1] = id end
            table.sort(ids)
            if #ids > 0 then
                B.shield_i = ((tonumber(B.shield_i) or 0) % #ids) + 1
                local e1 = B.bodies[ids[B.shield_i]]
                if e1 and e1.ch then resident_shield(e1.ch) end
            end
            local chaddrs = {}
            for _, e in pairs(B.bodies) do
                if e.ch then pcall(function() chaddrs[e.ch:get_address()] = true end) end
            end
            _G.IrisResidentChAddrs = chaddrs
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
        -- eviction enforcement (the tameable-hen law): re-assert every exile until its
        -- mover surrenders; expired entries fall away, dead wrappers are eaten by pcall
        if B.evict then
            for i9 = #B.evict, 1, -1 do
                local ev = B.evict[i9]
                if os.clock() > (tonumber(ev.until_t) or 0) then
                    table.remove(B.evict, i9)
                else
                    pcall(function()
                        ev.ch:call("set_IsThinkStop(System.Boolean)", true)
                        ev.ch:call("get_GameObject"):call("get_Transform")
                            :call("set_UniversalPosition", make_position(ev.x, ev.y, ev.z))
                    end)
                end
            end
        end
        -- ⭐ 08-13 05:00 (the targeting hunt needs receipts, Aurora needs her farm NOW):
        -- HERD INDOORS - one checkbox empties the yard (deleteAll, the proven despawn)
        -- and holds it empty; untick and the herd returns on the next pass. Farming in
        -- peace while the acquisition mystery waits for a fresh session.
        if C.herd_indoors == true then
            if next(B.bodies) then despawn_all("herd sent indoors") end
            return
        end
        local rows = home_rows()
        -- ⛔ 08-12 (THREE Mootildas): a script reset invalidates the old managed wrappers --
        -- body resolution failed, the module concluded "no bodies" and spawned fresh while
        -- the orphans grazed on. THE REACQUIRE (the tamed-creature detection, ported): once
        -- per load, scan the scene near the plot, RE-BIND band-matching bodies to their
        -- records, and purge true surplus (unshield + WARP off the farm -- the eviction
        -- law: never destroy).
        -- ⛔⛔ 08-13 (the hoe aimed at a stray chicken - Aurora named it): wild doubles
        -- left by the PRE-nav-fix evictions are valid ATTACK TARGETS standing in the
        -- crops, and the swing homing steered every hoe strike at them. The census was
        -- once-per-load by design; it now re-runs every 2 minutes (and by panel button)
        -- so band-surplus strays are always purged off the farm - with the nav cut,
        -- warped means gone.
        if os.clock() > (tonumber(B.resweep_at) or 0) then
            B.resweep_at = os.clock() + 120.0
            reacquired_this_load = false
        end
        if not reacquired_this_load then
            -- ⛔⛔ 08-13 02:48 receipts ("reacquire scan: 6 strays (0 home records)" ->
            -- the WHOLE herd purged as surplus, then respawned = the duplication): the
            -- bridge's stable may not have woken this early in the load. NEVER classify
            -- with an empty roster - wait for records before consuming the one pass.
            if #rows == 0 then return end
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
                        -- ⛔ 08-13 (ZERO "REACQUIRED" lines EVER, receipts): the one-step
                        -- `get_Item or [i]` THREW on this build's arrays and the per-item
                        -- pcall ate it - the scan walked every character and found nothing,
                        -- so every reset spawned duplicates over the survivors. Two-step
                        -- access (the file's own pattern everywhere else).
                        local ch0
                        pcall(function() ch0 = comps0:call("get_Item", i0) end)
                        if not ch0 then pcall(function() ch0 = comps0:get_element(i0) end) end
                        local go0 = ch0 and ch0:call("get_GameObject")
                        if not go0 then return end
                        local addr0 = go0:get_address()
                        if addr0 == comp_addr then return end
                        local band0 = tostring(go0:call("get_Name") or ""):match("ch%d+")
                        if not (band0 and DOCILE[band0]) then return end
                        local u0 = go0:call("get_Transform"):call("get_UniversalPosition")
                        local dx0, dz0 = u0.x - ax, u0.z - az
                        -- 60m: a called/wandered body must not slip the net (35m did)
                        if dx0 * dx0 + dz0 * dz0 > 60.0 * 60.0 then return end
                        strays[#strays + 1] = { ch = ch0, go = go0, addr = addr0, band = band0,
                            u = { x = u0.x, y = u0.y, z = u0.z } }
                    end)
                end
                pcall(function() log.info("[IrisHomesteadBox] reacquire scan: " .. #strays
                    .. " stray docile body(ies) within 60m (" .. tostring(#rows) .. " home records)") end)
                for _, r0 in ipairs(rows) do
                    if not (B.bodies[r0.id] and B.bodies[r0.id].addr) then
                        local rband0 = tostring(r0.species or ""):match("ch%d+")
                        for si0, s0 in ipairs(strays) do
                            if s0 and s0.band == rband0 then
                                B.bodies[r0.id] = B.bodies[r0.id] or { name = r0.name, at = os.clock() }
                                local e0 = B.bodies[r0.id]
                                e0.addr = s0.addr; e0.ch = s0.ch
                                if not e0.spawn then
                                    local pin0 = type(r0.home_pin) == "table" and r0.home_pin or nil
                                    e0.spawn = pin0 and { x = pin0.x, y = pin0.y, z = pin0.z }
                                        or { x = s0.u.x, y = s0.u.y, z = s0.u.z }
                                end
                                e0.want = e0.want or { x = e0.spawn.x, y = e0.spawn.y, z = e0.spawn.z }
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
                            -- ⛔ NAV LAW (the un-evicted twin ox, 02:48): an active nav
                            -- controller snaps the body back the frame after a one-shot
                            -- warp. Cut the muscle + think-stop FIRST; the stray stays sent.
                            pcall(function()
                                local nav0 = s0.go:call("getComponent(System.Type)", sdk.typeof("app.MonsterNavigationController"))
                                if nav0 then nav0:call("set_Enabled", false) end
                            end)
                            pcall(function() s0.ch:call("set_IsThinkStop(System.Boolean)", true) end)
                            local hc0 = s0.go:call("getComponent(System.Type)", sdk.typeof("app.HitController"))
                            if hc0 then
                                pcall(function() hc0:call("set_Enabled", true) end)
                                for _, sig0 in ipairs({ "set_IsDamageZero", "set_IsIgnoreDamageHit", "set_DamageCollisionOff" }) do
                                    pcall(function() hc0:call(sig0, false) end)
                                end
                            end
                            pcall(function()
                                local hs0 = s0.go:call("getComponent(System.Type)", sdk.typeof("app.HateSystem"))
                                if hs0 then hs0:call("set_Enabled", true) end
                            end)
                            pcall(function()
                                local lo0 = s0.go:call("getComponent(System.Type)", sdk.typeof("app.LockOnTarget"))
                                if lo0 then lo0:call("set_Enabled", true) end
                            end)
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
                            B.evict = B.evict or {}
                            B.evict[#B.evict + 1] = { ch = s0.ch, x = wx0, y = wy0, z = wz0,
                                until_t = os.clock() + 15.0 }
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
                -- ⭐ 08-13 (Aurora: "return one to the stable and the WHOLE yard blinks"):
                -- the lib has no per-instance delete, but the duplication purge's eviction
                -- recipe works one body at a time - unshield + ground-probed warp off the
                -- farm (WARP never destroy). The rest of the herd never notices; streaming
                -- retires the stray when the area turns over.
                pcall(function()
                    local go9 = e.ch and e.ch:call("get_GameObject")
                    if go9 then
                        -- the same nav law: cut before the warp or the body walks home
                        pcall(function()
                            local nav9 = go9:call("getComponent(System.Type)", sdk.typeof("app.MonsterNavigationController"))
                            if nav9 then nav9:call("set_Enabled", false) end
                        end)
                        pcall(function() e.ch:call("set_IsThinkStop(System.Boolean)", true) end)
                        local hc9 = go9:call("getComponent(System.Type)", sdk.typeof("app.HitController"))
                        if hc9 then
                            pcall(function() hc9:call("set_Enabled", true) end)
                            for _, sig9 in ipairs({ "set_IsDamageZero", "set_IsIgnoreDamageHit", "set_DamageCollisionOff" }) do
                                pcall(function() hc9:call(sig9, false) end)
                            end
                        end
                        pcall(function()
                            local hs9 = go9:call("getComponent(System.Type)", sdk.typeof("app.HateSystem"))
                            if hs9 then hs9:call("set_Enabled", true) end
                        end)
                        pcall(function()
                            local lo9 = go9:call("getComponent(System.Type)", sdk.typeof("app.LockOnTarget"))
                            if lo9 then lo9:call("set_Enabled", true) end
                        end)
                        local wx9, wz9 = ax + 120.0, az + 120.0
                        local wy9 = ay + 10.0
                        pcall(function()
                            local cast9 = rawget(_G, "route3_cast_ground_below")
                            local rx9, _, rz9 = render_point_near(wx9, ay, wz9)
                            local hit9 = cast9 and rx9 and cast9(rx9, ay + 30.0, rz9) or nil
                            if hit9 and tonumber(hit9.y) then wy9 = tonumber(hit9.y) + 1.5 end
                        end)
                        go9:call("get_Transform"):call("set_UniversalPosition", make_position(wx9, wy9, wz9))
                    end
                    if e.addr then B.addrs[e.addr] = nil end
                    -- ⛔ 08-13 (the tameable hen at the wall): a critter's own mover
                    -- rejects a ONE-SHOT warp just like the monster nav did - enforce
                    -- the exile for 15s until whatever drives it gives up
                    B.evict = B.evict or {}
                    B.evict[#B.evict + 1] = { ch = e.ch, x = wx9, y = wy9, z = wz9,
                        until_t = os.clock() + 15.0 }
                    log.info("[IrisHomesteadBox] " .. tostring(e.name or id)
                        .. " left home - evicted quietly (no yard rebuild)")
                end)
                B.bodies[id] = nil
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
        -- ⭐ 08-13 (names vanished the FIRST time reacquire truly worked): the old loop
        -- walked the spawner's instance list, and reacquired bodies were never in this
        -- load's spawner. Draw from the bound bodies themselves - spawned or reacquired.
        for _, e in pairs(B.bodies) do
            pcall(function()
                if not e.ch then return end
                local go = e.ch:call("get_GameObject")
                local pos = go:call("get_Transform"):call("get_Position")
                local sp = draw.world_to_screen(Vector3f.new(pos.x, pos.y + 1.1, pos.z))
                if sp then
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
                    -- ⭐ 08-12 spawn pins: stand where you want them to live, press this
                    if id and imgui.button("pin " .. tostring(e and e.name or "?") .. "'s spot HERE##pin_" .. tostring(id)) then
                        pcall(function()
                            local pu9 = select(1, player_spaces())
                            local b9 = bridge()
                            if pu9 and b9 and b9.set_home_pin then
                                local _, m9 = b9.set_home_pin(id, pu9.x, pu9.y, pu9.z)
                                B.tp_msg = tostring(m9)
                            end
                        end)
                    end
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
        if imgui.button("CALL the herd to me now (in-game key: K at the plot)") then B.call_all() end
        local hi_c, hi_v = imgui.checkbox("HERD INDOORS (empty the yard - farm in peace)", C.herd_indoors == true)
        if hi_c then C.herd_indoors = hi_v; pcall(save_cfg) end
        if imgui.button("SWEEP STRAYS NOW (wild doubles draw the hoe's aim)") then
            B.resweep_at = 0.0
            reacquired_this_load = false
        end
        if imgui.button("REGISTER the herd bell HERE (stand at the bell first)") then
            pcall(function()
                local pu2 = select(1, player_spaces())
                if pu2 then
                    C.bell_x, C.bell_y, C.bell_z = pu2.x, pu2.y, pu2.z
                    C.bell_set = true
                    save_cfg()
                    B.tp_msg = string.format("herd bell registered at (%.0f, %.0f, %.0f) - tap B/F within 3m", pu2.x, pu2.y, pu2.z)
                end
            end)
        end
        if C.bell_set == true then imgui.text(string.format("herd bell: (%.0f, %.0f, %.0f)", C.bell_x, C.bell_y or 0, C.bell_z)) end
        if imgui.button("despawn residents now") then despawn_all("manual") end
        if imgui.button("force respawn now (despawn + immediate rebuild)") then
            despawn_all("forced respawn")
            B.near = false   -- next sweep re-enters the yard fresh
        end
        imgui.tree_pop()
    end
end)
