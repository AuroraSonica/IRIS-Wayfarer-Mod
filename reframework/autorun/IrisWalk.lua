-- ═════════════════════════════════════════════════════════════════════════════════════
-- IrisWalk.lua — IRIS's OWN pawn walker. ⛔ NO RIFTSPEAK REQUIRED.
--
-- Aurora 2026-08-09: "I don't want people to *NEED* to have riftspeak installed to have IRIS
-- working - that would read like I'm forcing them to get my AI mod that anti-AI people will jump
-- to malicious intent." That is a DISTRIBUTION requirement, not a technical preference, so it
-- outranks convenience: IRIS must walk a pawn on its own. RiftSpeak, when present, is a BONUS
-- rung — never a prerequisite.
--
-- ⭐⭐⭐ THE MECHANISM IS **ROOT-MOTION DRIVE + RAYCAST OBSTACLE STEERING**.
--       walk clip (bank 0 / id 100) aimed at the goal, with physics probes steering round
--       whatever is in the way.
-- ⛔ A* OVER app.AIWorldGraphManager IS BUILT BUT OFF (M.use_route). The graph is BAKED MAP DATA
--   and knows nothing about a homestead IrisHouseForge spawns at RUNTIME, so its routes run
--   straight through our walls and hand the steering a wrong aim point to fight. It is kept only
--   for possible long cross-map walks over the real road network.
--
-- ⛔⛔ THE ONE LAW THAT EXPLAINS EVERY FAILURE BEFORE IT:
--   **`setDestination` is a PARAMETER, not a COMMAND.** Nothing moves unless an active behaviour
--   in the character's decision layer is running a move action that CONSUMES that destination.
--   A borrowed child NPC works because its schedule AI is already executing a walk-to-destination
--   behaviour and a hook can redirect it mid-flight. The MAIN PAWN's movement is issued by
--   party-level authorities (app.goalplanning.PLPartyAIGoalPlanning, app.PLPartyFormationController),
--   so there IS no consumer and the value we write is never read.
--   ⇒ bare-object follow, all three nav controller classes, the steer hook, AND the formation
--     slot all failed for that single reason. None of them had a consumer.
-- ⛔ CORROBORATION: RiftSpeak never once calls setDestination on the main pawn in 19k lines.
--   Every main-pawn move there is setFollowObject onto a REAL body, or a root-motion puppet
--   driven along an A* route. They hit this wall years ago and built around it.
--
-- ⭐ SO THE DRIVE RUNG WAS ALWAYS RIGHT — IT WAS MISSING A ROUTE, NOT A MECHANISM. Root motion
--   has a consumer by definition (the clip moves the body). Point it at the next NODE of a real
--   path instead of at the far goal and the beeline dissolves: consecutive graph nodes are
--   metres apart and on-mesh. The other rungs are kept only as fallbacks.
--
-- ⛔ THE ONE API DETAIL THAT IS EASY TO GET WRONG, AND I NEARLY DID:
--   `setFollowObject` is called on the RAW `app.PawnManager.get_MainPawn()` WRAPPER
--   (RiftSpeak's `_lpawn_obj`), NOT on the unwrapped Character. Positions/motion/FSM are the
--   other way round — those need the CachedCharacter. Two different objects, both called "the
--   pawn". Mixing them up is silent: a pcall eats it and nothing moves.
--
-- ⭐ RIFTSPEAK BORROWS AN NPC as its breadcrumb (hides it, kills its collision, teleports it
--   about) because it needs a body the follow controller will accept. IRIS does not have to:
--   IrisFarming.lua:1027 already creates bare GameObjects via
--   `via.GameObject.create(System.String)`. If the follow controller rejects a bare object we
--   fall through to the NPC trick — but we try the clean route first.
--
-- ⭐ SELF-PROVING LADDER. No rung is trusted because it "should" work. `to()` picks the
--   cheapest rung, and the tick WATCHES whether she actually closed any distance. No progress
--   inside `stuck_secs` and it climbs to the next rung and says so in the log. So the field
--   test IS the probe: whatever ends up in `IrisWalk.mode()` is what genuinely drives a pawn
--   in this build of DD2.
--
-- PUBLIC API (all under _G.IrisWalk):
--   IrisWalk.to(dest, on_arrive)  dest = { u = {x,y,z}, r = {x,y,z}, go = optional GameObject }
--                                 -> true if a walk started
--   IrisWalk.stop(reason)         -> release the pawn
--   IrisWalk.arrived()            -> true once she is inside `arrive`
--   IrisWalk.mode()               -> which rung is driving ("crumb" / "target")
--   IrisWalk.busy()               -> is a walk in flight
-- ═════════════════════════════════════════════════════════════════════════════════════

local M = {
    arrive     = 2.5,      -- metres that count as "there"
    stuck_secs = 5.0,      -- no real progress for this long -> give up
    check_every = 1.0,     -- ⛔ progress is sampled on THIS window, never frame-to-frame
    check_move  = 0.45,    -- metres she must cover per window to count as still walking
    give_up    = 40.0,     -- absolute ceiling on one walk
    -- ⭐⭐ WALK, DON'T RUN (Aurora 08-09). With setFollowObject the pawn picks her own pace from
    --   how FAR the follow target is: park it on the destination 12m away and she sprints. So we
    --   never park it on the destination — the crumb is kept a couple of metres ahead of her and
    --   dragged along, which reads as a walk the whole way. This is the same trick RiftSpeak uses
    --   to lead the player (its LEAD_AHEAD breadcrumb), turned down low.
    --   Bigger number = more urgency. ~2m strolls, ~8m jogs, 15m+ runs.
    pace       = 2.2,
    -- ⭐ "can we make it so the pawn only walks and doesn't run?" — this is that switch. The
    --   drive rung has a real gearbox (walk 100 / jog 200), so ON means she strolls everywhere
    --   no matter how far the target is.
    always_walk = true,
    jog_over    = 14.0,    -- only consulted when always_walk is off
    -- ⭐ how long a pawn command of YOURS suspends stay mode. Press "To Me!" and she comes and
    --   stays with you for this long before drifting back to pottering.
    yield_secs  = 90.0,
    -- ⛔⛔ WHAT THE ORDERS ACTUALLY DO (Aurora 08-09, correcting me): **"Go!" DOES NOT SEND HER
    --   ANYWHERE — it makes her TAKE THE FRONT.** I had written that Go "frees her from following
    --   while leaving her idle behaviours alive", which was invention. Go = run ahead and lead;
    --   it would have made her scout the road, not potter round the homestead.
    --   The real menu is: 1 come (to me) · 2 go (take point) · 3 help (engage) · 4 wait (hold).
    -- ⚠ SO THERE IS NO GOOD ORDER FOR "STAY HERE AND POTTER". Wait is the only one that stops her
    --   following, and Wait is exactly what kills native seat use (a waiting pawn does nothing —
    --   IrisPawnIdle's header). Go sends her ahead. That tension is unresolved, which is another
    --   reason the default below is to issue NOTHING and simply drop the follow target.
    -- ⛔ 0 = ISSUE NO ORDER AT ALL, and that is now the default (Aurora 08-09: "now the idling is
    --   setting the Go! action"). Every tryUpdatePawnOrder is a visible command AND an audible
    --   bark, and firing one as a side effect of idling is intrusive however rarely it happens.
    --   Dropping the follow target already stops her chasing the Arisen; the order was belt-and
    --   braces and it is not worth the noise. Set to 2 (Go) or 4 (Wait) only if you want it.
    stay_order  = 0,
    nav_replan  = 1.5,     -- seconds before the steer re-plans to an unmoved goal (too low = the
                           -- chokepoint/stair flip-flop RiftSpeak documents)
    nav_push    = 0.33,    -- seconds between DIRECT setDestination pushes (~20 frames, as :1543)
    stay_leash  = 22.0,    -- only re-issue if she has drifted this far with no job of ours
    -- ⭐ local obstacle avoidance (the ONLY thing that sees a runtime-built house)
    avoid       = true,
    portal      = true,    -- route via the house door when start/goal straddle it
    portal_step = 1.7,
    trust_node  = 3.5,     -- within this of our own waypoint, ignore avoidance and go straight
    roof_up     = 6.0,     -- how far up to look for a roof when deciding indoors/outdoors     -- metres either side of the doorway for the transit points
    ignore_door = true,    -- ⛔ the forged door is a closed PUSH leaf: walk through it, see _clear
    use_route   = false,   -- ⛔ see the drive engage: the nav graph is blind to our buildings
    probe_dist  = 4.5,     -- how far ahead she looks for a wall
    probe_height = 1.0,    -- chest height, so the cast clears kerbs and grass
    -- ⛔ a step-down bigger than this counts as a CLIFF and that heading is refused outright
    max_drop    = 2.5,     -- a step-down bigger than this is a CLIFF; that heading is refused
    -- ⛔ TIGHT ON PURPOSE. The two portal points sit only ~3.4m apart either side of the door;
    --   at 1.8m she "arrives" at the first while still short and cuts the corner into the frame.
    node_reach  = 0.9,     -- how close counts as reaching a route node
    stay_cooldown = 30.0,  -- ...and never more often than this (each order is an audible bark)
    log        = true,
}

local LOG = "IrisWalk.log"
local function _log(s)
    if not M.log then return end
    pcall(function()
        local f = io.open(LOG, "a")
        if f then f:write(os.date("[%H:%M:%S] ") .. tostring(s) .. "\n"); f:close() end
    end)
end

local S = { job = nil, crumb = nil, last = "idle" }

-- ── the two faces of "the pawn" ──────────────────────────────────────────────────────
local function _sc(o, m) local r; pcall(function() r = o:call(m) end); return r end
-- ...and the version that takes arguments (findNearNode / toNode / get_Item all need one)
local function _sc2(o, m, ...) local a = { ... }; local r
    pcall(function() r = o:call(m, table.unpack(a)) end); return r end
local function _sf(o, f) local r; pcall(function() r = o[f] end); return r end

-- the WRAPPER: this is what owns setFollowObject
local function _pawn_obj()
    local pm = sdk.get_managed_singleton("app.PawnManager")
    if not pm then return nil end
    return _sc(pm, "get_MainPawn") or _sc(pm, "getMainPawn")
end

-- the CHARACTER: this is what owns transform / motion / FSM
local function _pawn_char()
    local v = _pawn_obj()
    if not v then return nil end
    return _sc(v, "get_CachedCharacter")
        or _sf(v, "<CachedCharacter>k__BackingField") or _sf(v, "CachedCharacter")
        or _sc(v, "get_Character") or v
end

local function _player_char()
    local cm = sdk.get_managed_singleton("app.CharacterManager")
    if not cm then return nil end
    local v = _sf(cm, "<ManualPlayer>k__BackingField") or _sc(cm, "get_ManualPlayer")
    return v and (_sc(v, "get_CachedCharacter") or v) or nil
end

local function _go_of(ch) return _sc(ch, "get_GameObject") end

local function _upos(ch)
    local p; pcall(function() p = ch:call("get_GameObject"):call("get_Transform"):call("get_UniversalPosition") end)
    return p
end

local function _rpos(ch)
    local p; pcall(function() p = ch:call("get_GameObject"):call("get_Transform"):call("get_Position") end)
    return p
end

local function _d2(a, b)
    if not (a and b) then return 1e18 end
    local dx, dz = (a.x or 0) - (b.x or 0), (a.z or 0) - (b.z or 0)
    return dx * dx + dz * dz
end

-- ── the follow call ──────────────────────────────────────────────────────────────────
-- ⛔ on the WRAPPER. Returns whether the call itself resolved — NOT whether she will actually
--   walk. Only the tick can tell us that, which is the whole reason the ladder exists.
local function _follow(go)
    local mp = _pawn_obj()
    if not (mp and go) then return false end
    local ok = pcall(function() mp:call("setFollowObject", go) end)
    return ok
end

-- ── the breadcrumb ───────────────────────────────────────────────────────────────────
-- ⚠ A BARE CREATED GAMEOBJECT'S TRANSFORM IS **RENDER** SPACE (IrisFarming.lua:1022 says so in
--   as many words). A borrowed NPC accepts set_UniversalPosition; ours does not necessarily, so
--   we place it in render space and keep universal purely for measuring.
local function _crumb()
    if S.crumb then
        local alive = false
        pcall(function() alive = S.crumb:call("get_Valid") == true end)
        if alive then return S.crumb end
        S.crumb = nil
    end
    local go
    pcall(function()
        go = sdk.find_type_definition("via.GameObject"):get_method("create(System.String)")
            :call(nil, "IrisWalkCrumb")
    end)
    if not go then _log("crumb: GameObject create failed"); return nil end
    pcall(function() go = go:add_ref() end)
    -- invisible, but it must still UPDATE or its transform will not settle
    pcall(function() go:call("set_DrawSelf", false); go:call("set_UpdateSelf", true) end)
    S.crumb = go
    _log("crumb: created")
    return go
end

local function _put_crumb(x, y, z)
    local go = _crumb(); if not go then return false end
    local ok = false
    pcall(function()
        local tf = go:call("get_Transform")
        local v = ValueType.new(sdk.find_type_definition("via.vec3"))
        v.x, v.y, v.z = x, y, z
        tf:call("set_Position", v)
        ok = true
    end)
    return ok
end

-- ⭐ THE PACE CONTROL. Put the crumb `pace` metres from the pawn ALONG the line to the goal,
--   never further, and never past the goal itself. She is therefore always chasing something
--   just in front of her nose, which is a walk — and the crumb is re-dragged every tick, so the
--   whole journey happens at that pace instead of a sprint that brakes at the end.
local function _drag_crumb(job, here_r)
    if not (job.r and here_r) then return false end
    local dx, dz = job.r.x - here_r.x, job.r.z - here_r.z
    local d = math.sqrt(dx * dx + dz * dz)
    if d < 0.001 then return _put_crumb(job.r.x, job.r.y, job.r.z) end
    local step = math.min(M.pace or 2.2, d)     -- clamp: never overshoot the real destination
    local t = step / d
    -- height comes from the DESTINATION, not the pawn: on steps the goal's y is what pulls her up
    return _put_crumb(here_r.x + dx * t, job.r.y, here_r.z + dz * t)
end

-- ═════════ THE FORMATION SLOT: the layer that actually WINS ═════════
-- ⭐⭐⭐ FOUND BY OBSERVING THE PALACE (Aurora's idea). When the game takes the pawn off you at
--   the palace door, one thing collapses:
--       FormationEvaluator.get_CurrentFormationOffset   (0.8,0.0,10.8) -> (0.0,0.0,0.0)
--   `app.FormationEvaluator` is the PARTY FORMATION system: it holds the slot a pawn is trying
--   to stand in, and `get_CurrentPosition` is that slot marching through the world behind you.
--
--   THIS IS WHY EVERYTHING ELSE FAILED. setFollowObject, setDestination and root motion all sit
--   BELOW the follower and were fighting it. Formation is the layer ABOVE — it decides where the
--   follower is trying to go in the first place. Move the slot and the follow AI is not an
--   opponent any more, it is the engine: it walks her there, around walls, because walking her
--   around walls behind you is its entire job.
--
-- ⛔ AND IT IS WRITABLE — the component dump says so outright:
--       set_CurrentPosition(1)   setCurrentPosition(1)   set_RelativeBestPos(1)
--       set_IsCorrectFormation(1)   updateFormationOffset(0)
--
-- ⚠ `update()` recomputes the slot from the player every frame, so a one-off write is erased
--   immediately. Same lesson as the nav steer: HOOK the setter and rewrite its argument, so our
--   value survives the recompute instead of racing it.
-- ⚠ The argument type is NOT in the dump (it only prints arg COUNTS). via.Position and via.vec3
--   are both plausible and both silently accept a wrong shape, so this TRIES BOTH ONCE and logs
--   which one took, rather than me picking one and hoping.
local FORM = { hooked = false, addr = 0, tgt = nil, in_steer = false, vt = nil }

local function _form_comp(ch)
    local c
    pcall(function()
        c = ch:call("get_GameObject")
              :call("getComponent(System.Type)", sdk.typeof("app.FormationEvaluator"))
    end)
    return c
end

-- write the slot, discovering the value type on first use and remembering it
local function _form_write(comp, u)
    local function try(tn)
        local ok = false
        pcall(function()
            local v = ValueType.new(sdk.find_type_definition(tn))
            v.x, v.y, v.z = u.x, u.y, u.z
            comp:call("set_CurrentPosition", v)
            ok = true
        end)
        return ok
    end
    if FORM.vt then return try(FORM.vt) end
    for _, tn in ipairs({ "via.Position", "via.vec3" }) do
        if try(tn) then
            FORM.vt = tn
            _log("formation: slot writes accept " .. tn)
            return true
        end
    end
    _log("⛔ formation: neither via.Position nor via.vec3 was accepted by set_CurrentPosition")
    return false
end

local function _install_form_hook()
    if FORM.hooked then return end
    local td = sdk.find_type_definition("app.FormationEvaluator")
    local m = td and (td:get_method("set_CurrentPosition") or td:get_method("setCurrentPosition"))
    if not m then _log("formation: no set_CurrentPosition to hook"); return end
    FORM.hooked = pcall(function()
        sdk.hook(m, function(args)
            if not (FORM.tgt and FORM.addr ~= 0 and not FORM.in_steer) then return end
            local got, this = pcall(sdk.to_managed_object, args[2])
            if not (got and this) then return end
            local addr = 0; pcall(function() addr = this:get_address() end)
            if addr ~= FORM.addr then return end
            -- rewrite the slot to OUR spot, then let the original be skipped
            FORM.in_steer = true
            _form_write(this, FORM.tgt)
            FORM.in_steer = false
            return sdk.PreHookResult.SKIP_ORIGINAL
        end, nil)
    end) == true
    _log("formation hook " .. (FORM.hooked and "installed" or "FAILED"))
end

local function _form_to(ch, u)
    _install_form_hook()
    local comp = _form_comp(ch); if not comp then return false end
    pcall(function() FORM.addr = comp:get_address() or 0 end)
    if FORM.addr == 0 then return false end
    FORM.tgt = { x = u.x, y = u.y, z = u.z }
    FORM.in_steer = true
    local ok = _form_write(comp, u)
    FORM.in_steer = false
    return ok
end

local function _form_release()
    FORM.tgt, FORM.addr = nil, 0
end

-- ═════════ THE NATIVE NAVMESH: the real answer to walls ═════════
-- ⭐⭐⭐ Aurora pointed at this ("look at the child follow for RiftSpeak if need be") and it is
--   the whole thing. RiftSpeakCarrySpike.lua:1684, in its own words:
--       "use NPCNavigationController:setDestination and let the native navmesh solve walls/stairs"
--   That is DD2's own pathfinder. No breadcrumb, no borrowed NPC, no root-motion beeline — you
--   hand the controller a destination and the game routes the character around the house.
--
-- ⛔ EXACT SHAPES, COPIED NOT REMEMBERED (RiftSpeakCarrySpike.lua:184-191 and :274):
--   • the controller: <NavigationController>k__BackingField, else get_NavigationController(),
--     else getComponent(app.NPCNavigationController)  — three rungs, because which one answers
--     varies by body.
--   • the argument is **via.Position**, NOT via.vec3. via.Position is doubles; handing it a
--     vec3 is the silent-underflow class of bug that has cost this project whole evenings.
--   • RE-ISSUE ON A THROTTLE (that file uses every 20 frames): her own AI issues competing
--     destinations, so one call gets overwritten. Spamming every frame causes indecision.
--
-- ⚠ THE ONE KNOWN LIMIT, from the same file's config (line 50): "native nav accepts targets but
--   does not enter locomotion for BORROWED children" — i.e. an inert summoned body takes the
--   target and never walks. A MAIN PAWN is not inert; she has a live AI and full locomotion, so
--   this should actually drive her. Should, not does — which is why it is a ladder rung and the
--   tick measures whether she closed any distance before falling through to the beeline.
local function _nav_ctrl(ch)
    local ctrl
    pcall(function() ctrl = ch:get_field("<NavigationController>k__BackingField") end)
    if not ctrl then pcall(function() ctrl = ch:call("get_NavigationController") end) end
    if not ctrl then
        pcall(function()
            ctrl = ch:call("get_GameObject")
                     :call("getComponent(System.Type)", sdk.typeof("app.NPCNavigationController"))
        end)
    end
    return ctrl
end

-- ⛔⛔⛔ CALLING setDestination IS NOT ENOUGH, AND THE LOG PROVED IT: "nav" engaged on every
--   attempt and every time came back "no progress -> climbed to drive". Her own AI issues its
--   OWN destination many times a second (follow-the-Arisen, schedule, combat), so ours is
--   overwritten within a frame or two and she never sets off.
-- ⭐ THE ANSWER IS RIFTSPEAK'S "STEER ENGINE" (RiftSpeakCarrySpike.lua:218): HOOK setDestination
--   and REWRITE native's own calls to our target, then SKIP_ORIGINAL. Her native pipeline then
--   walks her to OUR spot using the game's navmesh — which is what solves walls and stairs.
-- ⛔ AND IT IS ON THE **BASE** CLASS. That file says so outright at :224 —
--     "app.CharacterNavigationController -- BASE class: this is the call that actually fires
--      (proven)"
--   I hooked app.NPCNavigationController, which is why nothing happened.
local NAV = { hooked = false, addr = 0, tgt = nil, in_steer = false, issued = nil, at = 0 }

-- ⭐⭐⭐ THE PAWN HAS ITS OWN CONTROLLER CLASS, AND ITS OWN setDestination.
--   IrisPawnObserve's API dump, straight off the live object:
--       API NavigationController = app.PawnNavigationController
--       ... setDestination(1) ...
--   Not app.NPCNavigationController (my first guess) and not only the
--   app.CharacterNavigationController base (my second). The derived class OVERRIDES the method,
--   so a hook on the base never intercepted the calls her follow AI was making — which is
--   exactly why the steer looked installed and did nothing at all.
--   ⇒ hook EVERY class in the chain that declares it. The base still matters for NPCs.
local NAV_TYPES = {
    "app.PawnNavigationController",       -- ⭐ the pawn's own, PROVEN by the dump
    "app.CharacterNavigationController",  -- the base (RiftSpeak's child route)
    "app.NPCNavigationController",
}

-- ⚠ RiftSpeak installs its own hook on the BASE class and warns "never install a second hook on
--   this method" — but that warning is about ITS two clients sharing ONE hook, which we cannot
--   join without editing their file. Ours does nothing at all unless IRIS is actively driving
--   AND the controller address is our pawn's, so the two only ever act on different bodies.
--   If they ever fight, this is the first place to look.
local function _nav_hook_one(m)
    return pcall(function()
        sdk.hook(m, function(args)
            if not (NAV.tgt and NAV.addr ~= 0 and not NAV.in_steer) then return end
            local got, this = pcall(sdk.to_managed_object, args[2])
            if not (got and this) then return end
            local addr = 0; pcall(function() addr = this:get_address() end)
            if addr ~= NAV.addr then return end
            local tg = NAV.tgt
            -- re-plan only when the goal actually MOVES or the throttle expires; replanning every
            -- frame is what caused RiftSpeak's "chokepoint/stair flip-flop"
            local moved = (not NAV.issued)
                or math.abs(tg.x - NAV.issued.x) > 0.3 or math.abs(tg.z - NAV.issued.z) > 0.3
            if moved or (os.clock() - (NAV.at or 0)) > (M.nav_replan or 1.5) then
                NAV.in_steer = true
                pcall(function()
                    local p = ValueType.new(sdk.find_type_definition("via.Position"))
                    p.x, p.y, p.z = tg.x, tg.y, tg.z
                    this:call("setDestination(via.Position)", p)
                end)
                NAV.in_steer = false
                NAV.issued, NAV.at = { x = tg.x, y = tg.y, z = tg.z }, os.clock()
            end
            return sdk.PreHookResult.SKIP_ORIGINAL
        end, nil)
    end)
end

local function _install_nav_hook()
    if NAV.hooked then return end
    local any = false
    for _, tn in ipairs(NAV_TYPES) do
        local td = sdk.find_type_definition(tn)
        local m = td and td:get_method("setDestination(via.Position)")
        if m then
            local ok = _nav_hook_one(m)
            _log(string.format("nav hook %-38s %s", tn, ok and "ok" or "FAILED"))
            any = any or (ok == true)
        else
            _log(string.format("nav hook %-38s no setDestination(via.Position)", tn))
        end
    end
    NAV.hooked = any
    if not any then _log("⛔ no navigation hook installed at all") end
end

-- arm the steer: remember which controller is ours, and where she is going
local function _nav_to(ch, u)
    _install_nav_hook()
    if not NAV.hooked then return false end
    local ctrl = _nav_ctrl(ch); if not ctrl then return false end
    pcall(function() NAV.addr = ctrl:get_address() or 0 end)
    if NAV.addr == 0 then return false end
    NAV.tgt, NAV.issued = { x = u.x, y = u.y, z = u.z }, nil
    -- kick it off directly too: her AI may not call setDestination for a while, and the hook
    -- only rewrites calls that actually happen
    local ok = false
    pcall(function()
        NAV.in_steer = true
        local p = ValueType.new(sdk.find_type_definition("via.Position"))
        p.x, p.y, p.z = u.x, u.y, u.z
        ctrl:call("setDestination(via.Position)", p)
        NAV.in_steer = false
        ok = true
    end)
    return ok
end

local function _nav_release()
    NAV.tgt, NAV.issued, NAV.addr = nil, nil, 0
end

-- ═════════ THE ROUTE: A* over the game's own nav graph ═════════
-- ⭐⭐⭐ THE ACTUAL ANSWER, and it reframes every failure today (research pass 08-09):
--   **`setDestination` is a PARAMETER, not a COMMAND.** Nothing moves unless some active
--   behaviour in the character's decision layer is running a move action that CONSUMES that
--   destination. RiftSpeakCarrySpike's child steer works because the child's schedule AI is
--   already executing a walk-to-destination behaviour and the hook merely redirects it in
--   flight (RiftSpeakCarrySpike.lua:218-224). The MAIN PAWN's movement is issued by party-level
--   authorities (app.goalplanning.PLPartyAIGoalPlanning, app.PLPartyFormationController), so
--   there is no consumer and the value we write is simply never read.
--   ⇒ That single mechanism explains ALL of it: the bare-object follow, the three nav classes,
--     the steer hook, and the formation slot. None of them had a consumer.
-- ⛔ CORROBORATION: RiftSpeak never once calls setDestination on the main pawn in 19k lines.
--   Every main-pawn move there is setFollowObject onto a REAL body, or a root-motion puppet
--   driven along an A* route. They hit this wall and built around it.
--
-- ⭐ SO THE DRIVE RUNG WAS ALREADY RIGHT — IT WAS JUST MISSING A ROUTE. Root motion goes where
--   she is pointed; point her at the NEXT NODE of a real path instead of at the far goal and the
--   beeline problem dissolves, because consecutive graph nodes are metres apart and on-mesh.
--
-- ⛔ API COPIED FROM llm_freetalk.lua:12266-12335, NOT REMEMBERED:
--   graph  = sdk.get_managed_singleton("app.AIWorldGraphManager")
--   start  = graph:call("findNearNode", <via.Position>, 0)     -- graphIdx 0 = the one graph
--   links  = node.Links  -> links:get_Count() / links:get_Item(j)
--   next   = graph:call("toNode", linkId, 0)
--   pos    = node._Pos (or node:get_Pos())
local ROUTE_CAP = 600          -- expansion ceiling; a homestead route is a few dozen nodes

local function _vpos(x, y, z)
    local p = ValueType.new(sdk.find_type_definition("via.Position"))
    p.x, p.y, p.z = x, y, z
    return p
end

local function _npos(n) return _sf(n, "_Pos") or _sc(n, "get_Pos") end
local function _naddr(n) local a; pcall(function() a = n:get_address() end); return a end

local function _graph() return sdk.get_managed_singleton("app.AIWorldGraphManager") end

-- A* from one universal position to another. Returns an array of {x,y,z} or nil.
local function _route(fromU, toU)
    local g = _graph(); if not g then return nil end
    local sn = _sc2(g, "findNearNode", _vpos(fromU.x, fromU.y, fromU.z), 0)
    local gn = _sc2(g, "findNearNode", _vpos(toU.x, toU.y, toU.z), 0)
    if not (sn and gn) then return nil end
    local sk, gk = _naddr(sn), _naddr(gn)
    if not (sk and gk) then return nil end
    if sk == gk then return { { x = toU.x, y = toU.y, z = toU.z } } end

    local obj, pos = { [sk] = sn }, { [sk] = _npos(sn) }
    local gp = _npos(gn)
    if not (pos[sk] and gp) then return nil end
    local function h(p) local dx, dz = p.x - gp.x, p.z - gp.z; return math.sqrt(dx * dx + dz * dz) end

    local gcost, came, closed, open = { [sk] = 0 }, {}, {}, { [sk] = true }
    local found, exp = false, 0
    while exp < ROUTE_CAP do
        -- cheapest open node (linear scan: routes here are short, a heap is not worth the code)
        local ck, best
        for k in pairs(open) do
            local f = (gcost[k] or 1e9) + h(pos[k])
            if not best or f < best then best, ck = f, k end
        end
        if not ck then break end
        if ck == gk then found = true; break end
        open[ck] = nil; closed[ck] = true; exp = exp + 1

        local links = _sf(obj[ck], "Links") or _sc(obj[ck], "get_Links")
        local cnt = links and (_sc(links, "get_Count") or 0) or 0
        for j = 0, cnt - 1 do
            local nid = _sc2(links, "get_Item", j)
            local nn = nid and _sc2(g, "toNode", nid, 0)
            local k = nn and _naddr(nn)
            if nn and k and not closed[k] then
                if not obj[k] then obj[k] = nn; pos[k] = _npos(nn) end
                if pos[k] then
                    local a, b = pos[ck], pos[k]
                    local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
                    local flat = math.sqrt(dx * dx + dz * dz)
                    -- ⚠ reject wall-like traversal edges (unavailable ladders/mantles/cliffs stay
                    --   in the raw graph). Height alone cannot tell them from a rising road, so
                    --   reject only when STEEP relative to horizontal run — llm_freetalk:12325-12333.
                    local grade = math.abs(dy) / math.max(flat, 0.25)
                    local wall = (math.abs(dy) > 3.0 and grade > 0.45)
                              or (math.abs(dy) > 1.25 and grade > 0.95)
                    if not wall then
                        local ng = (gcost[ck] or 0) + flat
                        if ng < (gcost[k] or 1e9) then
                            gcost[k], came[k] = ng, ck
                            open[k] = true
                        end
                    end
                end
            end
        end
    end
    if not found then return nil end

    local out, k = {}, gk
    while k do
        local p = pos[k]
        if p then table.insert(out, 1, { x = p.x, y = p.y, z = p.z }) end
        k = came[k]
    end
    if #out == 0 then return nil end
    -- the graph node nearest the goal is not the goal; finish at the real spot
    out[#out + 1] = { x = toU.x, y = toU.y, z = toU.z }
    return out
end

-- ═════════ THE DRIVE: how the pawn ACTUALLY moves ═════════
-- ⭐⭐⭐ PORTED FROM WHAT WAS DEMONSTRABLY WORKING. Aurora, correctly: "we know the move is
--   possible because it was working before." It was — via RiftSpeak's `_lead_puppet_tick`, and
--   there is no position write anywhere in it. The pawn moves on the **ROOT MOTION OF A
--   LOCOMOTION CLIP** (llm_freetalk.lua:14899 "legs (L0) + root motion"):
--       freeze the FSM  ->  play a walk/jog clip on bank 0 layer 0  ->  turn her to aim
--   The clip walks her forward; we only decide which way she is pointing. No teleporting, no
--   nav graph, no NPC to borrow, nothing of RiftSpeak's needed — this is ~60 lines of IRIS.
--
-- THE GEARBOX (cfg.lead_*_motion, llm_freetalk.lua:14209-14210): 0 idle / 100 walk / 200 jog /
--   300 run, all on bank `lead_run_bank`=0, layer `lead_run_layer`=0.
--   ⇒ Aurora's "can we make it so the pawn only walks and doesn't run?" is simply: pick 100.
--
-- ⚠ THE HONEST COST: root motion goes where she is POINTED. There is no pathfinding here, so
--   this beelines — the very thing the native-navigation route would have fixed. It is what
--   RiftSpeak has always done and it worked fine around the homestead, and IrisPawnIdle's
--   reachability raycast already refuses targets without line of sight. If the "nearest real
--   gimmick" probe turns out to work, THAT rung gets promoted above this one and we inherit
--   real pathing; until then, this is the rung that actually moves her.
local BANK, LAYER = 0, 0
local GEAR = { idle = 0, walk = 100, jog = 200, run = 300 }

local function _fsm(ch, on)
    pcall(function()
        local h = ch:call("get_Human")
        if h and h.Fsm then h.Fsm:set_Enabled(on) end
    end)
end

local function _play(ch, bank, id)
    pcall(function()
        ch:call("get_Motion"):call("getLayer", LAYER):call(
            "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
            bank, id, 0.0, 6.0, 1, 1)
    end)
end

local function _motion_id(ch)
    local id
    pcall(function() id = ch:call("get_Motion"):call("getLayer", LAYER):call("get_MotionID") end)
    return id
end

-- steer + gear, once per frame
local YAW_SLEW = 0.14   -- max radians of turn per frame; stops a single-frame flip spinning her
-- ⛔⛔ NEVER DRIVE A POSED PAWN (Aurora 08-09: "she wasn't facing the crops and was vibrating
--   violently as if trying to get away"). Both symptoms are this function: it re-aims her EVERY
--   frame, and its gear check `_motion_id(ch) ~= want` is TRUE on every single frame while a
--   chore clip is playing — so it re-fired the walk clip continuously, which restarts it at
--   frame 0 each time. That is the vibration, and the rotation is why she faced the wrong way.
--   A chore owns the body; if one is running we do not touch her at all.
local function _posed()
    local p = false
    pcall(function() p = _G.IrisPawnIdle and _G.IrisPawnIdle.posing and _G.IrisPawnIdle.posing() == true end)
    return p
end

-- ═════════ THE DOORWAY PORTAL ═════════
-- ⛔ THE LIMIT GREEDY STEERING CANNOT PASS (Aurora 08-10: "if I go to the side of the house
--   outside and do it, she doesn't go out the door, she walks to the wall"). From inside a room
--   the goal direction points AT a wall, and the fan only turns +/-130 degrees — nothing in a
--   local probe can know the door is BEHIND her. Steering handles convex obstacles; a room is
--   the opposite of convex.
-- ⭐ BUT THE DOOR DOES NOT NEED DISCOVERING — IT IS A CONSTANT IN THE HOUSE KIT.
--   Every forge kit contains exactly one `sm80_252*` door placement with an offset and a pure-yaw
--   rotation, e.g. farm_complete: r=+4.421 f=-0.865 yaw=107.28. The forge's own local->world
--   mapping (IrisHouseForge.lua:212-215 `_yaw_offset`) sends local +Z to (sin θ, cos θ), and that
--   is the doorway's outward normal. Both are in the HOUSE frame, which IrisPawnIdle proved is
--   algebraically the same frame as the muster points (r = off.x, f = off.z), so this carries to
--   every plot of that house type with no per-plot work.
-- ⇒ if she and her goal are on OPPOSITE sides of the door plane, walk the portal first: the near
--   side, then the far side, then the goal. Steering still does all the real work — this only
--   supplies the one waypoint it cannot deduce.
-- ⛔ MOVED UP: _indoors (just below) needs _ensure_ray, and in Lua a local referenced before
--   its declaration binds to a nil GLOBAL instead — silently, at runtime.
local ray = { ready = false }
local function _ensure_ray()
    if ray.ready then return true end
    local ok = pcall(function()
        ray.system = sdk.get_native_singleton("via.physics.System")
        ray.method = sdk.find_type_definition("via.physics.System")
            :get_method("castRay(via.physics.CastRayQuery, via.physics.CastRayResult)")
        ray.query  = sdk.create_instance("via.physics.CastRayQuery"):add_ref()
        ray.result = sdk.create_instance("via.physics.CastRayResult"):add_ref()
        ray.query:clearOptions(); ray.query:enableAllHits(); ray.query:enableNearSort()
        ray.filter = ray.query:get_FilterInfo()
    end)
    ray.ready = ok and ray.system ~= nil and ray.query ~= nil and ray.filter ~= nil
    return ray.ready == true
end

-- ⭐ INDOORS = SOMETHING SOLID OVERHEAD. Cast up from head height; a roof hits, open sky does
--   not. Universal in, render for the cast (physics is render space).
-- ⚠ fails OUTDOORS if the ray system is unavailable, which degrades to "no portal" — i.e. plain
--   steering, the behaviour we already had — rather than routing her through a door she may not
--   need. A wrong "indoors" would send her out of a building she was never in.
local function _indoors(u)
    if not _ensure_ray() then return false end
    local ch = _pawn_char(); if not ch then return false end
    local pu, pr = _upos(ch), _rpos(ch)
    if not (pu and pr) then return false end
    local rx = u.x - (pu.x - pr.x)
    local ry = u.y - (pu.y - pr.y)
    local rz = u.z - (pu.z - pr.z)
    local hits = 0
    pcall(function()
        ray.filter:set_Group(0); ray.filter:set_Layer(2); ray.filter:set_MaskBits(0)
        ray.result:clear()
        local function v3(x, y, z)
            local v = ValueType.new(sdk.find_type_definition("via.vec3")); v.x, v.y, v.z = x, y, z; return v
        end
        ray.query:call("setRay(via.vec3, via.vec3)",
            v3(rx, ry + 1.7, rz), v3(rx, ry + (M.roof_up or 6.0), rz))
        ray.method:call(ray.system, ray.query, ray.result)
        hits = ray.result:get_NumContactPoints() or 0
    end)
    return hits > 0
end

local DOOR = {}          -- house name -> { r, f, nr, nf } or false

local function _door_for(house)
    if DOOR[house] ~= nil then return DOOR[house] end
    local d = false
    pcall(function()
        local kit = json.load_file("IRIS/forge_house_" .. tostring(house) .. ".json")
        for _, pl in ipairs((kit and kit.placements) or {}) do
            if not d and tostring(pl.id or ""):sub(1, 8) == "sm80_252" then
                local th = 2 * math.atan(pl.rot.y or 0, pl.rot.w or 1)
                d = { r = pl.off.x, f = pl.off.z, nr = math.sin(th), nf = math.cos(th) }
            end
        end
    end)
    DOOR[house] = d
    if d then _log(string.format("door for '%s': r=%.2f f=%.2f n=(%.2f,%.2f)", tostring(house), d.r, d.f, d.nr, d.nf))
    else _log("no sm80_252 door found for house '" .. tostring(house) .. "'") end
    return d
end

-- universal -> house-local (forward, right); same maths as IrisPawnIdle.lua:98-108
local function _house_local(u, plot)
    local y = math.rad(plot.yaw or 0)
    local sn, cs = math.sin(y), math.cos(y)
    local dx, dz = u.x - plot.ux, u.z - plot.uz
    return dx * sn + dz * cs, dx * cs - dz * sn      -- f, r
end

local function _house_world(f, r, plot, uy)
    local y = math.rad(plot.yaw or 0)
    local sn, cs = math.sin(y), math.cos(y)
    return { x = plot.ux + f * sn + r * cs, y = uy, z = plot.uz + f * cs - r * sn }
end

-- if start and goal straddle the doorway, return the two transit points (near first)
local function _portal(fromU, toU)
    local H = _G.IrisHomestead
    if not (H and H.nearest_plot) then return nil end
    local plot, pd = H.nearest_plot(fromU)
    if not plot or (pd or 1e9) > 60.0 then return nil end
    local d = _door_for(plot.house); if not d then return nil end
    -- ⛔⛔ AN INFINITE PLANE THROUGH THE DOOR IS THE WRONG TEST, AND THIS IS THE CASE THAT PROVED
    --   IT (Aurora 08-10: standing round the side/back, "she walks around in circles inside and
    --   doesn't go to the door first"). A plane only separates "in front of the door wall" from
    --   "behind it" — stand at the BACK of the house and you are on the same side of that plane
    --   as the whole interior, so the straddle test said "same side" and no portal was offered.
    -- ⭐ THE QUESTION IS "IS THIS POINT INDOORS", AND PHYSICS ANSWERS IT: indoors means there is
    --   a ROOF overhead. One upward cast per endpoint, no geometry knowledge, works for any
    --   house kit and any shape — and it is the same collision the walls come from, which the
    --   AIM COLLISION PROBE confirmed layer 2 can see (GO: IrisRig_*).
    local ia, ib = _indoors(fromU), _indoors(toU)
    if ia == ib then return nil end                      -- both in or both out: steering can cope
    -- the door's own normal says which transit point is the outdoor one
    local step = M.portal_step or 1.7
    local outp = { r = d.r + d.nr * step, f = d.f + d.nf * step }
    local inp  = { r = d.r - d.nr * step, f = d.f - d.nf * step }
    local first  = ia and inp or outp                    -- start on HER side of the doorway
    local second = ia and outp or inp
    _log(string.format("portal: %s -> %s through the doorway",
        ia and "indoors" or "outdoors", ib and "indoors" or "outdoors"))
    return { _house_world(first.f,  first.r,  plot, fromU.y),
             _house_world(second.f, second.r, plot, toU.y),
             { x = toU.x, y = toU.y, z = toU.z } }
end

-- ═════════ LOCAL OBSTACLE STEERING ═════════
-- ⭐⭐⭐ THE REASON NO NATIVE PATHFINDER COULD EVER WORK HERE (Aurora 08-09, and it is the whole
--   answer): "they aren't real walls, they are faked by our house forge system."
--   `app.AIWorldGraph` is BAKED GAME DATA. The homestead is spawned at RUNTIME by IrisHouseForge
--   with collision added by IrisMeshCollision — so to the navigation graph that building simply
--   DOES NOT EXIST. No nodes around it, no edges blocked by it. A flawless native pathfinder
--   would still route straight through, because it is routing across what the game thinks is an
--   empty field. The drawn path proved it: four nodes bunched at her feet and one long line
--   through a stone wall.
-- ⇒ PHYSICS is the only system that knows the house is there, because IrisMeshCollision gave it
--   real colliders. So we avoid obstacles by CASTING AT THEM, not by asking for a route.
-- ⚠ This is deliberately simple steering, not pathfinding: probe the way ahead, and if it is
--   blocked, fan out left and right and walk the clearest direction that still makes progress.
--   For a convex-ish building that is enough; it is not a maze solver and does not pretend to be.

-- ⛔ RENDER space: physics is render space, and these probes are physics.
--   FAILS OPEN — a probe that cannot run must not make everything look blocked.
-- ⛔⛔⛔ THE DOOR IS A CLOSED PHYSICS LEAF, AND IT IS WHY SHE CAN NEVER GET INSIDE.
--   IrisMeshCollision leaves the doorway HOLE open (SKIP_PREFIX "sm80_252", :29-30) — but then
--   spawns a real door gimmick into it (`M.door_idx = 4` :42) that AUTO-CLOSES
--   (`M.door_autoclose = true` :47, "physics door can't latch ... snap it back to its seated
--   closed pose"). So a chest-height probe at the doorway hits solid door and the steering
--   correctly concludes "wall" — and correctly refuses the only way in.
--   ⇒ IGNORE CONTACTS OWNED BY THE DOOR. It is a PUSH door with no prompt, so she can simply
--     walk through it; we just must not mistake it for masonry.
-- ⛔ Only the door is forgiven. Furniture and walls must still block, so this filters by the
--   exact GameObject name IrisMeshCollision assigns (:573 set_Name "IrisDoor"), not by "ignore
--   everything thin".
-- ⚠ contact -> owner is read with getContactCollidable(i):get_GameObject() (IrisHouseForge.lua:1201).
local function _hits_ignoring_door()
    local n = ray.result:get_NumContactPoints() or 0
    if n == 0 then return 0 end
    local solid = 0
    for i = 0, n - 1 do
        local skip = false
        pcall(function()
            local col = ray.result:call("getContactCollidable(System.UInt32)", i)
            local go  = col and col:call("get_GameObject")
            local nm  = go and tostring(go:call("get_Name") or "")
            if nm == "IrisDoor" then skip = true end
        end)
        if not skip then solid = solid + 1 end
    end
    return solid
end

local function _clear(fromR, tx, tz)
    if not _ensure_ray() then return true end
    local hits = 0
    pcall(function()
        ray.filter:set_Group(0); ray.filter:set_Layer(2); ray.filter:set_MaskBits(0)
        ray.result:clear()
        local h = M.probe_height or 1.0
        local function v3(x, y, z)
            local v = ValueType.new(sdk.find_type_definition("via.vec3")); v.x, v.y, v.z = x, y, z; return v
        end
        ray.query:call("setRay(via.vec3, via.vec3)",
            v3(fromR.x, fromR.y + h, fromR.z), v3(tx, fromR.y + h, tz))
        ray.method:call(ray.system, ray.query, ray.result)
        hits = (M.ignore_door ~= false) and _hits_ignoring_door() or (ray.result:get_NumContactPoints() or 0)
    end)
    return hits == 0
end

-- ⛔⛔ A CLIFF IS INVISIBLE TO A FORWARD CAST (Aurora 08-09: "this house is right next to a sheer
--   drop and she decided to back off and went down the sheer drop"). Open air is the CLEAREST
--   possible forward probe — nothing to hit — so ledge-walking scored as the best heading of all.
--   ⇒ every candidate is also probed DOWNWARD: no ground within `max_drop` = not a direction,
--     however clear it looks. This is the same ground-probe shape IrisFarming uses for beds.
-- ⚠ FAILS CLOSED, unlike the wall probe: if the downward cast cannot run we must NOT assume
--   there is floor. Walking her off a cliff is far worse than refusing to move.
local function _ground_ok(hereR, tx, tz)
    -- ⛔ FAIL CLOSED, and it did not (caught in review): this returned `true` when the ray system
    --   was unavailable, directly contradicting its own comment above. "No floor" is the safe
    --   assumption for a cliff guard — refusing to move beats walking her off a ledge.
    if not _ensure_ray() then return false end
    local hits = 0
    pcall(function()
        ray.filter:set_Group(0); ray.filter:set_Layer(2); ray.filter:set_MaskBits(0)
        ray.result:clear()
        local function v3(x, y, z)
            local v = ValueType.new(sdk.find_type_definition("via.vec3")); v.x, v.y, v.z = x, y, z; return v
        end
        -- from just above her knee height at the probe point, straight down past the drop limit
        ray.query:call("setRay(via.vec3, via.vec3)",
            v3(tx, hereR.y + 1.0, tz), v3(tx, hereR.y - (M.max_drop or 2.5), tz))
        ray.method:call(ray.system, ray.query, ray.result)
        hits = ray.result:get_NumContactPoints() or 0
    end)
    return hits > 0
end

-- a heading is only usable if it is BOTH unobstructed and has floor under it
local function _usable(hereR, dirx, dirz)
    local look = M.probe_dist or 4.5
    local tx, tz = hereR.x + dirx * look, hereR.z + dirz * look
    if not _clear(hereR, tx, tz) then return false end
    -- check the near step too, not just the far point: a narrow ledge between here and there
    -- passes a far-point test and still drops her
    local mx, mz = hereR.x + dirx * (look * 0.5), hereR.z + dirz * (look * 0.5)
    return _ground_ok(hereR, mx, mz) and _ground_ok(hereR, tx, tz)
end

-- pick a heading: straight at the goal if usable, otherwise the smallest turn that is
local function _steer(hereR, dirx, dirz)
    -- ⛔⛔ NO PROBES MEANS NO AVOIDANCE, NOT PARALYSIS. I made _ground_ok fail CLOSED (correct on
    --   its own: never assume floor). But combined with an uninitialised ray system that makes
    --   EVERY heading report "no floor", so _steer returns nil, the drive plays idle and she
    --   stands still for ever — which is exactly the "motion id 0 / 0.00 m/s / no rung worked"
    --   Aurora hit. A missing probe must degrade to the OLD straight-line drive, never to a
    --   pawn that cannot move at all.
    if not _ensure_ray() then
        if not S.warned_ray then
            S.warned_ray = true
            _log("⛔ raycast system unavailable - obstacle avoidance is OFF (straight line)")
        end
        return dirx, dirz, false
    end
    if _usable(hereR, dirx, dirz) then S.side = nil; return dirx, dirz, false end
    -- ⭐ COMMIT TO A SIDE (Aurora: "sometimes it will go very weird ways"). A symmetric fan flips
    --   left/right as the geometry shifts and she weaves. Once she starts going round something,
    --   keep trying that side first until she is clear again — that is what turns a wander into
    --   walking along the wall.
    local order = { 30, -30, 55, -55, 80, -80, 105, -105, 130, -130 }
    if S.side == "L" then order = { -30, -55, -80, -105, -130, 30, 55, 80, 105, 130 }
    elseif S.side == "R" then order = { 30, 55, 80, 105, 130, -30, -55, -80, -105, -130 } end
    for _, deg in ipairs(order) do
        local a = math.rad(deg)
        local c, s = math.cos(a), math.sin(a)
        local nx, nz = dirx * c - dirz * s, dirx * s + dirz * c
        if _usable(hereR, nx, nz) then
            S.side = (deg > 0) and "R" or "L"
            return nx, nz, true
        end
    end
    -- ⛔ nowhere is both clear AND solid: STOP rather than pick the least-bad direction. The old
    --   version returned the straight-ahead heading here, which on a clifftop means stepping off.
    return nil, nil, true
end

local function _drive(job, ch, here, dist)
    if _posed() then return end
    -- ⭐ STEER AT THE NEXT ROUTE NODE, not the far goal. This is the whole fix: consecutive
    --   AIWorldGraph nodes are a few metres apart and on-mesh, so a straight line between them
    --   is safe. The path does the avoiding; root motion just follows it.
    local aim = job.u
    if job.path then
        while job.pp and job.pp <= #job.path do
            local w = job.path[job.pp]
            local wx, wz = w.x - here.x, w.z - here.z
            if math.sqrt(wx * wx + wz * wz) > (M.node_reach or 1.8) then break end
            job.pp = job.pp + 1        -- reached this node, aim at the next
        end
        if job.pp and job.pp <= #job.path then aim = job.path[job.pp] end
    end
    local dx, dz = aim.x - here.x, aim.z - here.z
    local len = math.sqrt(dx * dx + dz * dz)
    if len > 0.0001 then
        -- ⭐ AVOID WHAT THE NAV GRAPH CANNOT SEE. Steering happens in RENDER space (physics), so
        --   the direction is normalised here and probed off her render position.
        local ux, uz = dx / len, dz / len
        local hr = _rpos(ch)
        -- ⛔⛔ DO NOT DODGE A WAYPOINT WE PUT THERE ON PURPOSE. The forward probe looks 4.5m
        --   ahead but a doorway is ~1.2m wide, so on the approach the probe hits the wall BESIDE
        --   the opening and steering turns her away from the exact point that gets her through.
        --   Avoidance and the portal were pulling opposite ways at the threshold — she covered
        --   5.3m, reached the door, and stalled there (Aurora 08-10: "walked around indoors but
        --   didn't get out").
        -- ⭐ Inside `trust_node` metres of one of OUR OWN path nodes, drive straight at it. Those
        --   points are derived from the door's own transform and are clear by construction; the
        --   probes are for geometry we did NOT choose.
        local trusting = false
        if job.path and job.pp and job.pp <= #job.path then
            local w = job.path[job.pp]
            local wx, wz = w.x - here.x, w.z - here.z
            trusting = math.sqrt(wx * wx + wz * wz) <= (M.trust_node or 3.5)
        end
        job.trusting = trusting
        if hr and M.avoid ~= false and not trusting then
            local sx, sz, dodging = _steer(hr, ux, uz)
            job.dodging = dodging
            if not sx then
                -- ⛔ boxed in with no safe heading: HOLD STILL. Standing still is always
                --   recoverable; the stuck timer ends the walk in a few seconds. Guessing here
                --   is what put her over the cliff.
                _play(ch, BANK, GEAR.idle)
                job.penned = true
                return
            end
            job.penned = nil
            ux, uz = sx, sz
        end
        local yaw = math.atan(ux, uz)
        if job.yaw then                          -- slew-limit (llm_freetalk.lua:15040)
            local d = yaw - job.yaw
            while d > math.pi do d = d - 2 * math.pi end
            while d < -math.pi do d = d + 2 * math.pi end
            if d > YAW_SLEW then d = YAW_SLEW elseif d < -YAW_SLEW then d = -YAW_SLEW end
            yaw = job.yaw + d
        end
        job.yaw = yaw
        pcall(function()
            local q = ValueType.new(sdk.find_type_definition("via.Quaternion"))
            q.x = 0; q.y = math.sin(yaw / 2); q.z = 0; q.w = math.cos(yaw / 2)
            ch:call("get_GameObject"):call("get_Transform"):call("set_Rotation", q)
        end)
    end
    -- ⛔ ONLY RE-FIRE ON A GEAR CHANGE. changeMotion every frame restarts the clip at frame 0,
    --   which is a pawn twitching on the spot forever instead of walking (:14863 checks the
    --   live MotionID for exactly this reason).
    local want = GEAR.walk
    if not M.always_walk and dist > (M.jog_over or 14.0) then want = GEAR.jog end
    if _motion_id(ch) ~= want then _play(ch, BANK, want) end
end

-- ═════════ PAWN ORDERS: "stay here", and noticing when YOU countermand it ═════════
-- Aurora 08-09: "when the pawn is in the vicinity of the homestead, it should not follow you by
-- default ... and only actually follow or be around you if the player actively presses To Me!"
--
-- ⛔ `app.PawnOrderController` IS NOT A SINGLETON. There is no get_ managed singleton for it —
--   you capture a live instance by hooking its per-frame update() and taking `args[2]` (the
--   `this` pointer). Copied from llm_freetalk.lua:8021, which says so in as many words. Trying
--   to fetch it any other way returns nil and the orders silently do nothing.
-- Order values (app.PawnOrderController.PawnOrder): 1 come, 2 go, 3 help, 4 wait.
local ORDER = { come = 1, go = 2, help = 3, wait = 4 }
local PO = { controller = nil, hooked = false, player_order_at = 0, player_order = nil }

local function _install_order_hook()
    if PO.hooked then return end
    local td = sdk.find_type_definition("app.PawnOrderController")
    if not td then return end
    local upd = td:get_method("update") or td:get_method("lateUpdate")
    if upd then
        pcall(function()
            sdk.hook(upd, function(args)
                if not PO.controller then
                    pcall(function() PO.controller = sdk.to_managed_object(args[2]) end)
                end
            end, function(r) return r end)
        end)
    end
    -- ⭐ WATCH, DO NOT BLOCK. RiftSpeak hooks this same method to SKIP the player's d-pad
    --   commands while it drives; we deliberately let every one through and just note it. The
    --   whole point is that "To Me!" must always win — IRIS yields to you, never the reverse.
    local tum = td:get_method("tryUpdatePawnOrder")
    if tum then
        pcall(function()
            sdk.hook(tum, function(args)
                pcall(function()
                    if not PO.controller then PO.controller = sdk.to_managed_object(args[2]) end
                    -- args[3] is the order value; ours are issued with PO.mine set so we can
                    -- tell OUR "wait" apart from YOUR d-pad press
                    if not PO.mine then
                        PO.player_order = sdk.to_int64(args[3]) & 0xFFFFFFFF
                        PO.player_order_at = os.clock()
                    end
                end)
                return sdk.PreHookResult.CALL_ORIGINAL
            end, function(r) return r end)
        end)
    end
    PO.hooked = true
    _log("pawn-order hook installed")
end

local function _order(v)
    if not v or v == 0 then return false end   -- 0 = deliberately silent, see M.stay_order
    if not PO.controller then return false end
    PO.mine = true                                   -- so our own order is not read as yours
    local ok = pcall(function() PO.controller:call("tryUpdatePawnOrder", v) end)
    PO.mine = nil
    return ok
end

-- did YOU press a pawn command in the last `secs`? (1 = "To Me!")
local function _player_ordered(secs, which)
    if not PO.player_order then return false end
    if os.clock() - (PO.player_order_at or 0) > (secs or 90) then return false end
    return which == nil or PO.player_order == which
end

-- ── starting a walk ──────────────────────────────────────────────────────────────────
-- RUNG 1 "crumb" : follow an IRIS-owned invisible object DRAGGED just ahead of her. First
--                  because it is the only rung where we control the pace.
-- RUNG 2 "target": follow the destination object itself. No pace control (she will run at a
--                  far one) but it needs no created object, so it survives if `create` is
--                  refused in some scene.
--
-- ⛔⛔ THERE IS DELIBERATELY NO RIFTSPEAK RUNG, AND THAT IS A DESIGN DECISION, NOT AN OMISSION.
--   1. Aurora 08-09: IRIS must never require the AI mod. A rung that silently engages it makes
--      RiftSpeak load-bearing again the moment the native route has an off day.
--   2. We could not stop it safely even if we wanted to. `_lead_stop` is a FORWARD-DECLARED
--      LOCAL (llm_freetalk.lua:11684) and `LLMFreeTalk` is a local table (:75), so neither is
--      reachable from here. Only `_G.__RiftSpeak_LLMFreeTalk_Module` gets us in, and building on
--      a double-underscore internal is exactly the coupling we are removing. Starting a walk we
--      cannot cancel is how the » leading to (fetch-pos) « label got stuck on with the pawn
--      standing there doing nothing.
--   3. No lead means NO LABEL — Aurora's "the label thing needs to be for Iris not RiftSpeak"
--      solves itself, with her RiftSpeak settings untouched.
-- ⛔⛔ FIELD RESULT 2026-08-09: **"crumb" DOES NOT WORK.** Nine consecutive walks, every one
--   "FAILED - no rung moved her", never a single metre closed. A bare `via.GameObject.create`
--   object is NOT a valid follow body — the call is ACCEPTED (no throw, so `_follow` returns
--   true) and then simply ignored, which is why the ladder had to measure movement rather than
--   trust the return value. RiftSpeak borrows a real NPC for precisely this reason and I hoped
--   to skip that step; the game says no.
--   ⇒ "target" (a REAL scene gimmick — chair, cookpot, bed) is now tried FIRST. It has never
--     actually run: every failed job above was `water`, and crop beds have no GameObject, so
--     the ladder skipped straight past it to failure. Whether a gimmick is a valid follow body
--     is still genuinely UNKNOWN, and the probe buttons in the panel exist to settle it.
-- ⛔⛔ ORDER CHANGED 08-09, AND THIS IS WHY: with "drive" first the ladder NEVER CLIMBED, because
--   drive always "works" — she moves, just in a straight line into a wall. So "target", the one
--   rung that would give us the GAME's own navigation (and therefore doors, corners and walls
--   for free), had still never run once. Trying it first costs at most ~5s of standing still
--   before the ladder falls back to drive, and it finally answers the question by itself instead
--   of waiting on a probe button.
-- ⚠ "target" needs a real scene object to follow, so it only applies to chairs/cookpots/beds.
--   Crop beds and muster points have no GameObject and still fall through to drive.
-- ⭐ "nav" FIRST: it is the only rung that can route AROUND anything. "drive" beelines and
--   "target"/"crumb" depend on a follow body we have not proven. If nav works, everything else
--   here becomes dead weight and the muster ROUTE stops being necessary at all.
-- ⭐ "formation" FIRST: it is the only rung that works WITH the follow AI instead of against it.
-- ⛔ ORDER FLIPPED 08-09 after the research pass: "drive" is the ONLY rung with a consumer for
--   its movement (root motion), and it now has a real A* route, so it leads. The others are kept
--   only as fallbacks and are all known to lack a consumer on a main pawn.
-- ⛔⛔ THE LADDER IS DOWN TO ONE RUNG, DELIBERATELY. formation / nav / target / crumb are all
--   PROVEN to have no consumer on a main pawn (see the header): they accept their writes and she
--   never moves. Leaving them in meant that after any stall she burned ~15s cycling through three
--   rungs that cannot work, which reads as "she just stands there". Drive is the only mechanism
--   with a consumer (the walk clip moves the body), so it is the only rung.
--   The code for the others is kept above ONLY as documentation of what was tried.
local RUNGS = { "drive" }

local function _engage(rung, job)
    if rung == "drive" then
        local ch = _pawn_char(); if not ch then return false end
        -- ⭐ build the route ONCE at engage. No route (indoors, off-graph, too far) is not fatal:
        --   we fall back to the old straight line, which is what we had anyway.
        -- ⛔⛔ THE A* ROUTE IS OFF BY DEFAULT, AND IT IS NOT A TUNING CHOICE — IT ACTIVELY HARMS.
        --   app.AIWorldGraph is baked map data and knows nothing about a house IrisHouseForge
        --   spawned at runtime, so its "route" cheerfully passes through the back wall. That
        --   gives the local steering a WRONG aim point to fight, which is worse than no route:
        --   aiming straight at the goal at least points her the right way while the probes work
        --   round the obstacle. (Aurora 08-09: "this A* route is trying to go through the back
        --   wall to get into the house for the muster point.")
        --   ⚠ It may still be worth ON for LONG cross-map walks, where the graph IS the real
        --     road network and there is no player-built geometry in the way. Hence a switch, not
        --     a deletion.
        -- ⭐ the doorway portal first: it is the one waypoint local steering cannot deduce
        local here = _upos(ch)
        job.path = (M.portal ~= false) and here and _portal(here, job.u) or nil
        local from = (not job.path) and (M.use_route == true) and here or nil
        job.path = job.path or (from and _route(from, job.u)) or nil
        job.pp = job.path and 1 or nil
        _log(job.path and string.format("route: %d node(s)", #job.path)
                       or "route: none found - straight line")
        _fsm(ch, false)
        job.driving = true
        return true
    elseif rung == "formation" then
        local ch = _pawn_char(); if not ch then return false end
        return _form_to(ch, job.u)
    elseif rung == "nav" then
        local ch = _pawn_char(); if not ch then return false end
        if not _nav_to(ch, job.u) then return false end
        job.nav_at = 0
        return true
    elseif rung == "crumb" then
        local ch = _pawn_char()
        local here = ch and _rpos(ch)
        if not _drag_crumb(job, here) then return false end
        return _follow(S.crumb)
    elseif rung == "target" then
        if not job.go then return false end
        return _follow(job.go)
    end
    return false
end

function _G.IrisWalk_to(dest, on_arrive)
    if not (dest and dest.u) then return false end
    local ch = _pawn_char(); if not ch then return false end
    local now = os.clock()
    local job = {
        u = dest.u, r = dest.r or dest.u, go = dest.go,
        on_arrive = on_arrive, rung = 1,
        started = now, moved_at = now, best = math.sqrt(_d2(_upos(ch), dest.u)),
    }
    while job.rung <= #RUNGS and not _engage(RUNGS[job.rung], job) do
        _log(string.format("rung '%s' would not engage - climbing", RUNGS[job.rung]))
        job.rung = job.rung + 1
    end
    if job.rung > #RUNGS then
        S.last = "no walker rung engaged"
        _log("⛔ NO RUNG ENGAGED - the pawn cannot be walked in this build")
        return false
    end
    S.job = job
    S.last = "walking (" .. RUNGS[job.rung] .. ")"
    _log(string.format("walk: %.1fm out via '%s'", job.best, RUNGS[job.rung]))
    return true
end

function _G.IrisWalk_stop(reason)
    if S.job then _log("walk: stop (" .. tostring(reason or "?") .. ")") end
    -- ⛔⛔ GIVE THE BODY BACK. The drive rung FREEZES her FSM to own the clip; if a stop can
    --   leave that frozen, the pawn is a statue and no later code will ever thaw her. Every
    --   exit from a walk goes through here, which is why the release lives here and nowhere else.
    if S.job and S.job.driving then
        local ch = _pawn_char()
        if ch then _play(ch, BANK, GEAR.idle); _fsm(ch, true) end
    end
    -- ⛔ DROP THE STEER. While NAV.tgt is set the hook SKIPS every native setDestination on her
    --   controller — leaving it armed would hijack her navigation permanently, so her AI could
    --   never path anywhere again. This must run on EVERY exit from a walk.
    _nav_release()
    -- ⛔ AND THE FORMATION SLOT. While FORM.tgt is set the hook rewrites every recompute, which
    --   means she is PINNED to that spot and can never follow the party again. This is the most
    --   dangerous thing in this file to leave armed.
    _form_release()
    S.job = nil
    S.last = "stopped: " .. tostring(reason or "?")
    -- ⛔⛔ DO NOT HAND HER BACK TO FOLLOWING BY DEFAULT. This used to end every chore with
    --   `setFollowObject(player)`, which is precisely the "she keeps trailing me around the
    --   homestead" behaviour — IRIS was actively re-attaching her to the Arisen after each job.
    --   `stay` mode leaves her where she ends up; only an explicit release restores following.
    if S.stay then
        -- ⛔ issue NOTHING here. _stay_tick owns the ordering and deliberately stays quiet;
        --   barking an order at the end of every single chore is exactly the annoyance Aurora
        --   reported. Dropping the follow target is enough to stop her chasing the Arisen.
        -- ⚠ RE-ANCHOR TO WHERE SHE IS, never to nil: a nil anchor means "never ordered yet", so
        --   _stay_tick would fire a fresh order — and a bark — after every single chore.
        local ch = _pawn_char()
        local p = ch and _upos(ch)
        if p then S.stay_anchor = { x = p.x, z = p.z } end
    else
        local ply = _player_char()
        if ply then _follow(_go_of(ply)) end
    end
    -- ⚠ DEFENSIVE ONLY, NOT A DEPENDENCY. IRIS never starts a RiftSpeak lead any more, but an
    --   older build of this mod did, and a stuck lead survives a script reset. If RiftSpeak is
    --   installed AND something left one running, clear it. `_lead_stop` and `LLMFreeTalk` are
    --   both locals over there, so the exported module table is the only door.
    pcall(function()
        local rs = _G.__RiftSpeak_LLMFreeTalk_Module
        if rs and rs.lead_stop then rs.lead_stop(reason or "iris_walk_stop") end
    end)
end

-- ── the watcher ──────────────────────────────────────────────────────────────────────
-- ⭐ DISTANCE IS THE TRUTH. RiftSpeak learned the same thing the hard way (llm_freetalk.lua:9639
--   — "its own arrival callback does not reliably fire for a close static goal ... the lead hung
--   on fetch-pos"), so arrival is measured, never trusted to a callback.
local function _tick()
    local job = S.job; if not job then return end
    local ch = _pawn_char(); if not ch then return end
    local now = os.clock()
    local here = _upos(ch); if not here then return end
    local d = math.sqrt(_d2(here, job.u))

    if d <= (M.arrive or 2.5) then
        -- ⛔ release the body BEFORE the callback: the caller's very next act is usually to play
        --   a chore clip, and it cannot while we still hold her FSM frozen on a walk cycle.
        if job.driving then _play(ch, BANK, GEAR.idle); _fsm(ch, true) end
        _nav_release()          -- arrived: hand her navigation back to her own AI
        _form_release()         -- ...and her formation slot, or she stands there forever
        S.job = nil
        S.last = string.format("arrived (%s)", RUNGS[job.rung])
        _log(string.format("walk: arrived within %.1fm via '%s'", d, RUNGS[job.rung]))
        if job.on_arrive then pcall(job.on_arrive) end
        return
    end

    -- ⭐ NAV: re-issue the destination on a throttle. Her own AI keeps issuing competing
    --   destinations, so a single call gets overwritten and she stops; every frame causes
    --   indecision. RiftSpeakCarrySpike uses ~20 frames, so ~0.33s here.
    if RUNGS[job.rung] == "formation" then
        -- keep the slot fresh; the hook rewrites every recompute to it
        FORM.tgt = job.u
    elseif RUNGS[job.rung] == "nav" then
        NAV.tgt = job.u
        -- ⛔⛔ THE PARTY FOLLOW AI IS THE COMPETITOR (Aurora 08-09: "she kept running into and
        --   jumping at the wall ... she's not really noticing a wall in the way"). That is not
        --   navigation failing to route — it is FOLLOW winning. RiftSpeak's steer is proven on a
        --   BORROWED CHILD, which has no party AI; the main pawn has a live follow-the-Arisen
        --   drive that pulls her in a straight line at the player and vaults whatever is between.
        --   Navigation can't be authoritative while something else is steering the same body.
        --   ⇒ drop the follow target for the duration of a nav walk, restore it on release.
        if not job.unfollowed then
            job.unfollowed = true
            pcall(function()
                local mp = _pawn_obj()
                if mp then mp:call("setFollowObject", nil) end
            end)
            _log("nav: dropped the follow target so navigation can steer")
        end
        -- ⭐ ALSO ISSUE IT DIRECTLY ON A THROTTLE. RiftSpeakCarrySpike:1543 does both — the hook
        --   only rewrites calls that native actually makes, and a pawn who is not currently
        --   pathing makes none, so the hook alone can sit there doing nothing.
        if now - (job.nav_at or 0) > (M.nav_push or 0.33) then
            job.nav_at = now
            local ctrl = _nav_ctrl(ch)
            if ctrl then
                pcall(function()
                    NAV.in_steer = true
                    local p = ValueType.new(sdk.find_type_definition("via.Position"))
                    p.x, p.y, p.z = job.u.x, job.u.y, job.u.z
                    ctrl:call("setDestination(via.Position)", p)
                    NAV.in_steer = false
                end)
            end
        end
    elseif RUNGS[job.rung] == "drive" then
        _drive(job, ch, here, d)
    elseif RUNGS[job.rung] == "crumb" then
        -- drag the crumb: both the pace control and a re-assert (a freshly created GameObject
        -- can have its transform stomped in its first frames)
        _drag_crumb(job, _rpos(ch))
        _follow(S.crumb)   -- her own AI can drop the follow target when it retargets
    end

    -- ⛔⛔ PROGRESS IS "DID SHE MOVE", NOT "IS SHE CLOSER". With obstacle avoidance she walks
    --   AWAY from the goal to get round a building, so distance-to-goal rises for several
    --   seconds — the old test read that as stuck and abandoned the walk exactly when the
    --   avoidance was working. Measure actual displacement instead.
    -- ⛔⛔ SAMPLE OVER A TIME WINDOW, NOT BETWEEN FRAMES. This compared her position on
    --   CONSECUTIVE TICKS: at a 1.3 m/s walk that is ~0.02 m per frame, always under the 0.25 m
    --   threshold, so "moved" was false on virtually every frame and the 5s stuck timer tripped
    --   no matter how well she was walking. With drive as the only rung that ends the walk
    --   outright — which is exactly why Aurora had to keep pressing the button to get her there.
    -- ⭐ A checkpoint every `check_every` seconds, needing `check_move` metres, measures real
    --   progress: a walking pawn clears ~1.3m in a second, a wedged one clears nothing.
    if not job.chk_at or (now - job.chk_at) >= (M.check_every or 1.0) then
        local prev = job.chk_pos
        job.chk_at, job.chk_pos = now, { x = here.x, y = here.y, z = here.z }
        if not prev or _d2(here, prev) > ((M.check_move or 0.45) ^ 2) then
            job.moved_at = now
        end
    end
    job.best = math.min(job.best or 1e9, d)   -- panel readout only
    if (now - (job.moved_at or now)) <= (M.stuck_secs or 5.0) then return end

    if now - (job.moved_at or now) > (M.stuck_secs or 5.0) then
        -- ⭐ THIS is the self-proving part: she did not move, so the rung we chose does not
        --   actually drive a pawn. Climb, and record which one finally did.
        job.rung = job.rung + 1
        while job.rung <= #RUNGS and not _engage(RUNGS[job.rung], job) do
            job.rung = job.rung + 1
        end
        if job.rung > #RUNGS then
            _log(string.format("walk: FAILED - no rung moved her (still %.1fm out)", d))
            S.last = "no rung could move her"
            _G.IrisWalk_stop("no rung worked")
            return
        end
        job.moved_at, job.best = now, d
        S.last = "walking (" .. RUNGS[job.rung] .. ")"
        _log(string.format("walk: no progress -> climbed to rung '%s'", RUNGS[job.rung]))
    end

    if now - (job.started or now) > (M.give_up or 25.0) then
        _log(string.format("walk: gave up after %.0fs (%.1fm short)", M.give_up or 25.0, d))
        _G.IrisWalk_stop("timeout")
    end
end

re.on_application_entry("UpdateBehavior", function() pcall(_tick) end)

re.on_script_reset(function()
    -- ⛔ unconditional thaw: a reset with a frozen FSM leaves the pawn locked mid-stride and
    --   this module will not exist to fix it
    pcall(function() local ch = _pawn_char(); if ch then _fsm(ch, true) end end)
    -- ⛔⛔ and the steer MUST be dropped: the hook survives a script reset, so an armed NAV.tgt
    --   would keep skipping her real navigation forever with nothing left to clear it
    pcall(_nav_release)
    pcall(_form_release)   -- the hook survives a script reset; an armed slot would pin her for good
    if S.job then pcall(function() _G.IrisWalk_stop("script reset") end) end
    -- ⛔ destroy the breadcrumb or a reset leaks one invisible GameObject per reload
    pcall(function() if S.crumb then S.crumb:call("destroy", S.crumb) end end)
    S.crumb = nil
end)

-- ⭐ STAY MODE. While on, the pawn is told to Wait whenever she is not mid-chore, so she stops
--   trailing the Arisen and potters where she is. Re-asserted on a slow timer rather than every
--   frame: spamming tryUpdatePawnOrder would fight the game's own UI and stop YOUR d-pad press
--   ever landing.
-- ⛔⛔ TWO THINGS THIS MUST NOT DO, BOTH LEARNED THE HARD WAY:
--   1. **DO NOT RE-ISSUE ON A TIMER.** Aurora 08-09: "it automatically does a pawn command every
--      time, which would get annoying for the player to hear." Every tryUpdatePawnOrder makes
--      the pawn BARK. There is no getter for the current order anywhere in the codebase, so we
--      cannot poll-and-compare — instead we issue ONCE and only re-issue on EVIDENCE that her
--      follow AI has reclaimed her (she drifted a long way with no job of ours running).
--   2. **DO NOT USE `wait`.** IrisPawnIdle's own header records it: a WAITING pawn does nothing —
--      set to Wait she roots in place, arms folded, and never touches the native seats that
--      IrisHomeLife spawns into every chair *specifically so pawns can use them*
--      (IrisHomeLife.lua:89 "so pawns/NPCs can use chairs you are nowhere near").
--      ⛔ CORRECTED 08-09: `go` does NOT free her from following - it makes her TAKE THE
--      FRONT and lead. There is no order that means "stay here and potter", so we issue none.
local function _stay_tick()
    if not S.stay then return end
    if S.job then S.stay_anchor = nil; return end  -- mid-walk: the drive owns her
    local now = os.clock()
    -- ⭐ YOU ALWAYS WIN. A "To Me!" (order 1) suspends stay entirely for `yield_secs`, so she
    --   comes to you and stays came-to. Any other command of yours (Go/Help/Wait) counts too —
    --   if you have just told her something, IRIS does not argue with it.
    if _player_ordered(M.yield_secs or 90) then
        S.stay_note = string.format("yielding to your order for %.0fs",
            (M.yield_secs or 90) - (now - (PO.player_order_at or 0)))
        return
    end
    -- where is she, and has she wandered off since we last told her to stop following?
    local ch = _pawn_char()
    local here = ch and _upos(ch)
    if not here then return end

    if not S.stay_anchor then
        -- first time in stay mode: ONE order, one bark, then we leave her alone
        S.stay_anchor = { x = here.x, z = here.z }
        S.stay_at = now
        _order(M.stay_order or 0)
        S.stay_note = "told once to stop following"
        _log("stay: issued order " .. tostring(M.stay_order or 0) .. " (once)")
        return
    end

    -- ⭐ RE-ISSUE ONLY ON EVIDENCE. If she has travelled a long way from where we left her and
    --   we did not send her, the party AI has taken her back — that, and only that, earns
    --   another bark. Pottering a few metres to a chair must NOT trigger it.
    local dx, dz = here.x - S.stay_anchor.x, here.z - S.stay_anchor.z
    local drift = math.sqrt(dx * dx + dz * dz)
    if drift > (M.stay_leash or 22.0) and (now - (S.stay_at or 0)) > (M.stay_cooldown or 30.0) then
        S.stay_anchor = { x = here.x, z = here.z }
        S.stay_at = now
        _order(M.stay_order or 0)
        _log(string.format("stay: she drifted %.0fm - re-issued", drift))
        S.stay_note = "re-issued after drifting"
        return
    end
    S.stay_note = string.format("left alone (%.0fm from anchor)", drift)
end

re.on_application_entry("UpdateBehavior", function() pcall(_install_order_hook); pcall(_stay_tick) end)

_G.IrisWalk = {
    to      = function(dest, cb) return _G.IrisWalk_to(dest, cb) end,
    stop    = function(reason) return _G.IrisWalk_stop(reason) end,
    busy    = function() return S.job ~= nil end,
    mode    = function() return S.job and RUNGS[S.job.rung] or nil end,
    status  = function() return S.last end,
    -- stay(true) = stop following the Arisen and hold position between chores.
    -- ⚠ Turning it OFF also hands her back to following, so a feature that switches it on is
    --   responsible for switching it off (IrisPawnIdle does, on disable/stop/reset).
    stay    = function(on)
        if on == nil then return S.stay == true end
        local was = S.stay
        S.stay = on == true
        if was and not S.stay then
            local ply = _player_char()
            if ply then _follow(_go_of(ply)) end
            _order(ORDER.come)      -- back to normal party behaviour
            _log("stay mode OFF - following again")
        elseif S.stay and not was then
            _log("stay mode ON - she will hold position between chores")
        end
        return S.stay
    end,
    -- true if the player has issued a pawn command recently (IRIS should keep out of the way)
    yielding = function() return _player_ordered(M.yield_secs or 90) end,
    settings = M,
}

-- ═════════ SEE THE PATH (Aurora 08-09: "would be good if we could draw the path just for
--   testing"). Right, and overdue: the log says "route: 5 node(s)" then "no progress", and
--   without seeing the path there is no way to tell a BAD ROUTE from a route she never walked.
-- ⚠ world coords here are RENDER space — draw.world_to_screen takes what get_Position gives,
--   not universal (IrisFarming.lua:3614 does exactly this). The route is in UNIVERSAL, so it is
--   converted with the pawn's own delta before drawing.
re.on_frame(function()
    if not (M.draw_path and S.job and S.job.path) then return end
    pcall(function()
        local ch = _pawn_char(); if not ch then return end
        local pu, pr = _upos(ch), _rpos(ch)
        if not (pu and pr) then return end
        local dx, dy, dz = pu.x - pr.x, pu.y - pr.y, pu.z - pr.z   -- universal -> render
        local prev
        for i, w in ipairs(S.job.path) do
            local sp = draw.world_to_screen(Vector3f.new(w.x - dx, w.y - dy + 0.3, w.z - dz))
            if sp then
                -- the node she is currently aiming at is the bright one
                local col = (i == S.job.pp) and 0xFF00FF66 or 0xFFFFCC44
                draw.filled_circle(sp.x, sp.y, (i == S.job.pp) and 7 or 4, col, 12)
                draw.text(tostring(i), sp.x + 8, sp.y - 6, col)
                if prev then draw.line(prev.x, prev.y, sp.x, sp.y, 0xFFFFCC44) end
                prev = sp
            else
                prev = nil     -- off-screen: do not draw a line across the whole view
            end
        end
    end)
end)

re.on_draw_ui(function()
    if not imgui.tree_node("IRIS WALK (IRIS's own pawn walker - no RiftSpeak needed)") then return end
    -- ⭐ IS THE CLIP EVEN PLAYING, AND IS SHE MOVING? "route: 5 node(s)" followed by "no
    --   progress" means the drive is doing NOTHING — so before blaming the path, prove whether
    --   the walk clip took and whether root motion translates her at all.
    do
        local ch = _pawn_char()
        local mid = ch and _motion_id(ch)
        local p = ch and _upos(ch)
        local moved = "-"
        if p then
            if S.dbg_p then
                moved = string.format("%.2f m/s", math.sqrt(_d2(p, S.dbg_p)) / 0.5)
            end
            if not S.dbg_at or (os.clock() - S.dbg_at) > 0.5 then
                S.dbg_p, S.dbg_at = { x = p.x, y = p.y, z = p.z }, os.clock()
            end
        end
        imgui.text(string.format("motion id: %s (want walk=100)   |   she is moving: %s",
            tostring(mid), moved))
        imgui.text(string.format("probes: %s   |   penned: %s   |   dodging: %s",
            _ensure_ray() and "ready" or "NOT AVAILABLE (avoidance off)",
            tostring(S.job and S.job.penned or false),
            tostring(S.job and S.job.dodging or false)))
        imgui.text("trusting own waypoint (avoidance off): " ..
            tostring(S.job and S.job.trusting or false))
        imgui.text(string.format("path: %s   aiming at node %s",
            S.job and S.job.path and (#S.job.path .. " nodes") or "none",
            tostring(S.job and S.job.pp or "-")))
    end
    -- ⭐ app.NavigationAI.EnableAppObstacleAvoidance — DD2's OWN raycast-based local avoidance
    --   (app.AppNavigationObstacle), which is physics-driven and therefore ALREADY sees our
    --   grafted .mcol house collision without being told anything. Field confirmed in the RSZ
    --   dump on app.NavigationAI alongside AppNavObstacleAgent.
    -- ⚠ PER-CHARACTER and NOT save-persisted, unlike the AIMapEffector routes — which is exactly
    --   why this is the only one of the four worth touching without a teardown design.
    -- ⛔ READ FIRST, and the reading is the point: if it is already ON, then native avoidance is
    --   running and being outvoted by the party AI, and we have learned that for free.
    do
        local ch = _pawn_char()
        local ai
        if ch then
            pcall(function() ai = ch:get_field("<NavigationAI>k__BackingField") end)
            if not ai then pcall(function() ai = ch:call("get_NavigationAI") end) end
        end
        local cur = "?"
        if ai then pcall(function() cur = tostring(ai:get_field("EnableAppObstacleAvoidance")) end) end
        imgui.text("native obstacle avoidance (EnableAppObstacleAvoidance): " ..
            (ai and cur or "NavigationAI not found"))
        if ai and imgui.button("turn native avoidance ON") then
            local ok = pcall(function() ai:set_field("EnableAppObstacleAvoidance", true) end)
            _log("EnableAppObstacleAvoidance := true (" .. tostring(ok) .. ")")
            S.last = ok and "native avoidance switched on" or "could not set it"
        end
    end
    local dc
    dc, M.draw_path = imgui.checkbox("draw the route in the world", M.draw_path == true)
    imgui.text("status: " .. tostring(S.last))
    imgui.text("rung: " .. tostring(S.job and RUNGS[S.job.rung] or "-")
        .. "   |   crumb: " .. (S.crumb and "made" or "not yet"))
    imgui.text("(IRIS drives this natively - RiftSpeak is not used and not required)")
    -- ⭐ walk her to where YOU are stood: the one test that needs no homestead and no props
    if imgui.button("walk the pawn to me") then
        local ply = _player_char()
        local u, r = ply and _upos(ply), ply and _rpos(ply)
        if u and r then
            _G.IrisWalk_to({ u = { x = u.x, y = u.y, z = u.z },
                             r = { x = r.x, y = r.y, z = r.z } },
                           function() _log("test: reached the Arisen") end)
        end
    end
    imgui.same_line()
    if imgui.button("stop walking") then _G.IrisWalk_stop("panel") end

    -- ═════════ FOLLOW-BODY PROBE ═════════
    -- ⭐ THE ONE QUESTION LEFT: what counts as a valid follow body? These bypass the ladder and
    --   point `setFollowObject` at one candidate, with NO destination logic in the way. Press
    --   one, watch her for a few seconds, and whichever makes her move is the answer.
    --   "the Arisen" is the CONTROL: it is known to work, so if even that does nothing then the
    --   problem is setFollowObject itself and not the body we are handing it.
    imgui.separator()
    imgui.text("follow-body probe - press one, watch her for ~5s:")
    if imgui.button("follow: the Arisen (control - should work)") then
        local ply = _player_char()
        local ok = ply and _follow(_go_of(ply))
        _log("PROBE arisen -> call " .. tostring(ok)); S.last = "probe: following the Arisen"
    end
    if imgui.button("follow: a bare IRIS object (known: does nothing)") then
        local ch = _pawn_char()
        local here = ch and _rpos(ch)
        if here then
            _put_crumb(here.x + 6.0, here.y, here.z)   -- 6m to one side of her
            local ok = _follow(S.crumb)
            _log("PROBE crumb -> call " .. tostring(ok)); S.last = "probe: following a bare object"
        end
    end
    if imgui.button("follow: the nearest real gimmick (THE test)") then
        -- ⭐ a real scene object with an actual body. If this moves her, IRIS has its walker and
        --   we only need a gimmick near each destination.
        local ch = _pawn_char()
        local here = ch and _rpos(ch)
        local best, bd, bname
        pcall(function()
            local sc = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),
                sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
            local comps = sc and sc:call("findComponents(System.Type)", sdk.typeof("app.GimmickBase"))
            for i = 0, (comps and comps:get_size() or 0) - 1 do
                pcall(function()
                    local go = comps:get_element(i):call("get_GameObject")
                    if not (go and go:call("get_Valid") == true) then return end
                    local p = go:call("get_Transform"):call("get_Position")
                    local d = math.sqrt(_d2(here, p))
                    if d > 3.0 and (not bd or d < bd) then
                        bd, best, bname = d, go, tostring(go:call("get_Name"))
                    end
                end)
            end
        end)
        if best then
            local ok = _follow(best)
            _log(string.format("PROBE gimmick '%s' at %.1fm -> call %s", tostring(bname), bd or -1, tostring(ok)))
            S.last = string.format("probe: following %s (%.1fm)", tostring(bname), bd or -1)
        else
            _log("PROBE gimmick: none found"); S.last = "probe: no gimmick nearby"
        end
    end
    imgui.separator()
    local c
    c, M.arrive     = imgui.slider_float("arrival (m)", M.arrive or 2.5, 1.0, 6.0)
    c, M.stuck_secs = imgui.slider_float("climb a rung after (s)", M.stuck_secs or 5.0, 2.0, 15.0)
    -- ⭐ "walk, don't run". On the DRIVE rung this picks the actual walk clip (gear 100); on the
    --   crumb rung the `pace` slider below does the same job by keeping the target close.
    c, M.always_walk = imgui.checkbox("always walk (never jog or run)", M.always_walk ~= false)
    c, M.pace       = imgui.slider_float("crumb pace (low = walk, high = run)", M.pace or 2.2, 1.0, 20.0)
    c, M.log        = imgui.checkbox("write the log", M.log)
    imgui.tree_pop()
end)

_log("IrisWalk loaded")
