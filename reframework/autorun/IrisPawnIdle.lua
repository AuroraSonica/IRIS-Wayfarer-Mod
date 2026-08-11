-- ═════════════════════════════════════════════════════════════════════════════════════
-- IrisPawnIdle.lua — your pawn pottering about the homestead.
--
-- Aurora's ask: "pawns idling in and around the house — sweeping, watering crops, sitting
-- on a chair", picking whatever is actually there.
--
-- ⛔ THE PREMISE THAT IS ALREADY DEAD (settled 2026-08-08, do not re-hope):
--   **A WAITING PAWN DOES NOTHING.** Set to Wait at the homestead it rooted in place, arms
--   folded, and never touched the native seats sitting in every chair. DD2's pawn idle AI
--   only runs while FOLLOWING. So there is no "let the game do it" here (unlike seating,
--   where native won outright — do not over-generalise that win). We drive it.
--
-- ⭐⭐⭐ THE WALKER IS **IRISWALK**, AND RIFTSPEAK IS NOT REQUIRED (rewritten 2026-08-09).
--   Aurora: "I don't want people to *NEED* to have riftspeak installed to have IRIS working."
--   IrisWalk.lua drives the pawn through her OWN NATIVE NAVIGATION (setFollowObject onto an
--   IRIS-owned invisible breadcrumb), so doors, walls and stairs are the game's problem.
--
-- ⛔ THE EARLIER VERSION OF THIS HEADER SAID THE OPPOSITE AND WAS WRONG TWICE OVER:
--   1. It claimed `_come_to_pos` meant "no bridge needed". `_come_to_pos` IS a global — but
--      `_lead_stop` is a FORWARD-DECLARED LOCAL (llm_freetalk.lua:11684) and `LLMFreeTalk` is
--      a local table (:75). So IRIS could START a RiftSpeak walk and never CANCEL it. That is
--      the whole "» leading to (fetch-pos) « stuck on screen while the pawn does nothing" bug:
--      the lead kept driving and stomped every chore clip.
--   2. It treated the straight-line beeline as an unavoidable law and built a raycast + a
--      stuck timer to live with it. Native navigation does not beeline, so the raycast is now
--      belt-and-braces rather than the thing holding the feature up.
--
-- ⚠ The reachability raycast is KEPT anyway: it is cheap, and it stops the pawn being offered
--   something on the far side of a wall that she would path all the way around to reach.
--
-- ⛔ DELIBERATELY NOT USED IN v1:
--   • `InteractManager.requestInteractFromAI` — it is a MUTATING call into InteractManager,
--     the same family as the two CTDs on 08-09. It is not allowed to be a dependency.
--   • jacking the PLAYER for anything. Jacking a PAWN is fine (worst case a silly-looking
--     pawn); jacking the player is how a whole evening was lost to frozen controls.
-- ═════════════════════════════════════════════════════════════════════════════════════

local M = {
    -- ⛔ OFF BY DEFAULT. It drives her pawn around and shares one body with RiftSpeak;
    --    an on-by-default behaviour feature is exactly what HomeLife had to walk back.
    enabled      = false,
    plot_range   = 45.0,     -- only idle while she is at a homestead
    pawn_range   = 35.0,     -- and only if the pawn is near it too
    -- ⭐ ALL OF THESE ARE AURORA'S DIALLED-IN VALUES (08-09), not guesses. Do not "tidy" them.
    dwell_min    = 15.0,     -- seconds between activities
    dwell_max    = 45.0,
    reach_arrive = 1.2,      -- how close counts as arrived (metres) - tight, so she reaches the seat
    stuck_secs   = 8.0,      -- no progress for this long = abandon the target
    hold_secs    = 15.0,     -- how long the chore pose is held frozen before she is released
    -- ⭐ at the homestead she potters instead of trailing you. "To Me!" always overrides.
    stay_put     = true,
    -- ⛔ UNKNOWN UNTIL CAPTURED - see the lie branch in _perform. Do not fill these in from
    --   memory or by pattern-matching another bank; capture them off a real lie-down.
    lie_bank     = nil,
    lie_id       = nil,
    muster_ok    = 4.0,      -- this close to a route point counts as reached
    muster_retries = 2,      -- attempts per leg before skipping it (never grind at a wall)
    -- ⭐ ONE ENTRY PER KIND IN THE DRAW, however many of that kind exist. Turn a kind down to
    --   make it rarer, or to 0 to switch it off entirely.
    kind_weight  = { water = 0.3, sit = 1.2, cook = 0.7, lie = 1.0 },
    repeat_penalty = 0.7,    -- how much less likely the thing she JUST did is (0 = never twice)
    cooldown     = 150.0,    -- a failed target is not offered again for this long
    require_los  = false,    -- see the pick loop: avoidance replaced this gate
    ray_height   = 1.0,      -- chest height for the reachability cast
    log          = true,
}

local LOG = "IrisPawnIdle.log"
local function _log(s)
    if not M.log then return end
    pcall(function()
        local f = io.open(LOG, "a")
        if f then f:write(os.date("[%H:%M:%S] ") .. tostring(s) .. "\n"); f:close() end
    end)
end

local S = { at = 0, next_at = 0, job = nil, cool = {}, last = "idle" }

-- ═════════ THE MUSTER POINT ═════════
-- Aurora 08-09: "have the pawn walk into the middle of the homestead before going on its idling
-- routine - I can set a specific waypoint and that should carry over to all homestead plots".
-- ⭐ AND IT DOES, BECAUSE IT IS STORED IN THE HOUSE'S OWN FRAME, NOT THE WORLD'S. Every saved
--   plot records the house origin (ux,uy,uz universal) plus its `yaw` IN DEGREES. Take where you
--   are standing, subtract the house origin, un-rotate by that yaw, and what is left is "3m
--   forward, 2m right OF THE HOUSE" — which means the same thing at every plot you ever build.
--   Same frame the door lives in, which is why it carries the way Aurora expected.
-- ⚠ yaw is DEGREES here (IrisHomestead.lua:257 does math.deg(math.atan(fx,fz))), so every use
--   below converts. Feeding radians into this silently rotates the point to somewhere daft.
local MUSTER_FILE = "IRIS/pawn_muster.json"
local muster = nil        -- { f = forward metres, r = right metres, y = height offset }

-- forward = (sin yaw, cos yaw); right is perpendicular to it
local function _house_axes(yaw_deg)
    local y = math.rad(yaw_deg or 0)
    return math.sin(y), math.cos(y)
end

-- world delta -> house-local (forward, right)
local function _to_local(dx, dz, yaw_deg)
    local s, c = _house_axes(yaw_deg)
    return dx * s + dz * c, dx * c - dz * s
end

-- house-local (forward, right) -> world delta
local function _to_world(f, r, yaw_deg)
    local s, c = _house_axes(yaw_deg)
    return f * s + r * c, f * c - r * s
end

-- ⭐⭐ IT IS A ROUTE, NOT A POINT (Aurora 08-09: "she tries to walk directly and it doesn't
--   work"). The drive rung is root motion along her facing — there is NO pathfinding in it — so
--   a single far point behind the house is a pawn walking into a wall. A short chain of points
--   you record by WALKING IT yourself gives her the corners, and because every point is stored
--   in the house's frame the whole route carries to every plot exactly like the single point did.
--   ⇒ this is the manual version of what native navigation would do for free. If the "nearest
--     real gimmick" probe ever comes back working, this stops being necessary — but it is not
--     worth being stuck behind a wall while that question is open.
local function _muster_load()
    if muster ~= nil then return muster end
    local raw
    pcall(function() raw = json.load_file(MUSTER_FILE) end)
    if type(raw) ~= "table" then muster = false; return muster end
    -- accept the OLD single-point file shape ({f,r,y}) as a one-leg route
    if raw.f and not raw.pts then raw = { pts = { { f = raw.f, r = raw.r, y = raw.y } } } end
    if type(raw.pts) ~= "table" or #raw.pts == 0 then muster = false else muster = raw end
    return muster
end

local function _muster_save()
    pcall(function() json.dump_file(MUSTER_FILE, muster or {}) end)
end

-- the plot she is standing at, if any
local function _plot_at(up)
    local H = _G.IrisHomestead
    if not (H and H.nearest_plot and up) then return nil end
    local plot, d = H.nearest_plot(up)
    if not plot or (d or 1e9) > (M.plot_range or 45.0) then return nil end
    return plot
end

-- leg `i` of the route in UNIVERSAL coords, for the plot she is standing at
local function _muster_leg(up, i)
    local m = _muster_load(); if not m then return nil end
    local p = m.pts[i]; if not p then return nil end
    local plot = _plot_at(up); if not plot then return nil end
    local dx, dz = _to_world(p.f, p.r, plot.yaw)
    return { x = plot.ux + dx, y = plot.uy + (p.y or 0), z = plot.uz + dz }, plot, #m.pts
end

-- ── helpers ──────────────────────────────────────────────────────────────────────────
local function _sc(o, m) local r = nil; pcall(function() r = o:call(m) end); return r end
local function _sf(o, f) local r = nil; pcall(function() r = o[f] end); return r end

-- ⛔⛔ THE BUG THAT KILLED v1, AND IT WAS SILENT.
--   `app.PawnManager.get_MainPawn()` DOES NOT RETURN A CHARACTER. It returns a wrapper, and the
--   Character hangs off it as CachedCharacter. v1 used the raw wrapper, so `get_GameObject`
--   resolved to nothing, `_go(pawn)` came back nil, and the tick hit `if not (pgo and wgo) then
--   return end` EVERY TICK FOREVER — a bare return that sets no status, so the panel kept
--   displaying whatever it last said and the log stayed empty. Enabled, ticking, doing nothing,
--   and reporting nothing. RiftSpeak already knew this (llm_freetalk.lua:958 _unwrap_character);
--   I wrote the accessor from memory instead of copying the one that ships.
--   The final `or value` makes it a no-op where no unwrap is needed (the player), so both go
--   through the same door.
local function _unwrap_char(v)
    if not v then return nil end
    return _sc(v, "get_CachedCharacter")
        or _sf(v, "<CachedCharacter>k__BackingField") or _sf(v, "CachedCharacter")
        or _sc(v, "get_Character")
        or _sf(v, "<Character>k__BackingField") or _sf(v, "Character")
        or v
end

local function _player()
    local cm = sdk.get_managed_singleton("app.CharacterManager")
    if not cm then return nil end
    return _unwrap_char(_sf(cm, "<ManualPlayer>k__BackingField") or _sc(cm, "get_ManualPlayer"))
end

local function _pawn()
    local pm = sdk.get_managed_singleton("app.PawnManager")
    if not pm then return nil end
    return _unwrap_char(_sc(pm, "get_MainPawn") or _sc(pm, "getMainPawn")
        or _sf(pm, "<MainPawn>k__BackingField") or _sf(pm, "MainPawn"))
end

local function _go(ch)
    local g = nil
    pcall(function() g = ch:call("get_GameObject") end)
    return g
end

local function _upos(go)
    local p = nil
    pcall(function() p = go:call("get_Transform"):call("get_UniversalPosition") end)
    return p
end

local function _rpos(go)
    local p = nil
    pcall(function() p = go:call("get_Transform"):call("get_Position") end)
    return p
end

-- ⭐ ONE place that calls off a walk. `_lead_stop` IS a true global (llm_freetalk.lua:12495) and
--   `LLMFreeTalk.lead_stop` wraps it (:12186) — try the wrapper too, so a future refactor that
--   makes the bare one local cannot silently turn our stop button into a no-op.
local function _stop_walk(reason)
    local ok = false
    -- IRIS's own walker owns the pawn now; its stop also tells RiftSpeak if RiftSpeak is driving
    pcall(function()
        if _G.IrisWalk and _G.IrisWalk.stop then _G.IrisWalk.stop(reason); ok = true end
    end)
    if not ok then
        pcall(function()
            if type(_lead_stop) == "function" then _lead_stop(reason); ok = true end
        end)
    end
    return ok
end

local function _dist(a, b)
    if not (a and b) then return 1e9 end
    local dx, dz = a.x - b.x, a.z - b.z
    return math.sqrt(dx * dx + dz * dz)
end

-- ⭐ the reachability cast, same shape as IrisFarming's ground probe (layer 2 = world/terrain
--    collision). ⛔ FAILS OPEN: if the ray system will not initialise we allow the target
--    rather than silently disabling the whole feature — a probe that cannot run must not
--    masquerade as "everything is blocked".
local ray = { ready = false }
local function _ensure_ray()
    if ray.ready then return true end
    local ok = pcall(function()
        ray.system = sdk.get_native_singleton("via.physics.System")
        ray.method = sdk.find_type_definition("via.physics.System")
            :get_method("castRay(via.physics.CastRayQuery, via.physics.CastRayResult)")
        ray.query  = sdk.create_instance("via.physics.CastRayQuery"):add_ref()
        ray.result = sdk.create_instance("via.physics.CastRayResult"):add_ref()
        ray.query:clearOptions()
        ray.query:enableAllHits()
        ray.query:enableNearSort()
        ray.filter = ray.query:get_FilterInfo()
    end)
    ray.ready = ok and ray.system ~= nil and ray.query ~= nil and ray.filter ~= nil
    return ray.ready == true
end

local function _vec3(x, y, z)
    local v = ValueType.new(sdk.find_type_definition("via.vec3"))
    v.x, v.y, v.z = x, y, z
    return v
end

-- is there a clear line from the pawn to this spot? (RENDER coords — a raycast is world
-- collision, and transform reads are render space)
local function _reachable(from, to)
    if not _ensure_ray() then return true end
    local hits = 0
    pcall(function()
        ray.filter:set_Group(0); ray.filter:set_Layer(2); ray.filter:set_MaskBits(0)
        ray.result:clear()
        local h = M.ray_height or 1.0
        ray.query:call("setRay(via.vec3, via.vec3)",
            _vec3(from.x, from.y + h, from.z), _vec3(to.x, to.y + h, to.z))
        ray.method:call(ray.system, ray.query, ray.result)
        hits = ray.result:get_NumContactPoints() or 0
    end)
    return hits == 0
end

-- ── what is there to do around here? ─────────────────────────────────────────────────
-- Everything is discovered from the world, never from a hardcoded list: the pawn should
-- only ever do things Aurora has actually built.
-- The hidden native seat parked in every chair.
-- ⛔⛔ THIS NEVER MATCHED ANYTHING. Field scan 2026-08-09: a spawned gm80_257 does NOT report
-- its prefab name at runtime — its GameObject is called **"gmSeat"**, after the shared
-- gmSeat_fsm / gmSeat_skeleton rig the whole camp-seat family uses. Aurora's 20m dump showed a
-- "gmSeat" sitting at the same distance as every gm05_044 stool. So a name test for "gm80_257"
-- was silently false for every seat in the world, and pawn sit-targets could never be found.
-- Match the RIG name, and keep the prefab name (plus whatever the live seat owner advertises)
-- as extra accepted spellings.
local function _seat_names()
    local out = { "gmseat", "gm80_257", "gm80_065" }
    local r = _G.DD2NativeSeats
    if type(r) == "table" and type(r.prefab) == "string" then out[#out + 1] = r.prefab:lower() end
    return out
end

local function _is_seat_name(nm)
    local n = tostring(nm or ""):lower()
    if n == "" then return false end
    for _, s in ipairs(_seat_names()) do if n:find(s, 1, true) then return true end end
    return false
end

local function _scene()
    local s = nil
    pcall(function()
        s = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),
            sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    end)
    return s
end

-- ⛔⛔⛔ TWO COORDINATE SPACES, AND THEY DISAGREE BY HUNDREDS OF METRES.
--   `_come_to_pos` walks in **UNIVERSAL** space — its own first act is `_lpawn_upos()`
--   (llm_freetalk.lua:12712) and it subtracts the goal from that. The raycast walks in
--   **RENDER** space, because physics is render space. v2 converted everything to render and
--   handed render coords to the walker, so Lyra dutifully set off for a point the length of the
--   map away and kept going. She wasn't lost — she was going exactly where I sent her.
--   ⇒ EVERY CANDIDATE NOW CARRIES BOTH: `.u` for the walker and arrival, `.r` for the raycast.
--     Distances are safe in either space (the two differ by a pure translation) but ONLY ever
--     between two points in the SAME one.
local function _candidates(pawn_go)
    local out, sc = {}, _scene()
    local pu = pawn_go and _upos(pawn_go)
    local pr = pawn_go and _rpos(pawn_go)
    if not (sc and pu and pr) then return out end
    local comps = nil
    pcall(function() comps = sc:call("findComponents(System.Type)", sdk.typeof("app.GimmickBase")) end)
    local n = nil
    pcall(function() n = comps and comps:get_size() end)
    for i = 0, (n or 0) - 1 do
        pcall(function()
            local c = comps:get_element(i)
            local go = c and c:call("get_GameObject")
            if not go or go:call("get_Valid") ~= true then return end
            local nm = tostring(go:call("get_Name") or "")
            local kind
            if _is_seat_name(nm) then kind = "sit"
            elseif nm:find("gm80_256", 1, true) then kind = "cook"        -- cooking pot
            elseif nm:find("gm51_115", 1, true) then kind = "lie"         -- bed
            end
            if not kind then return end
            local u, r = _upos(go), _rpos(go)
            if not (u and r) then return end
            local d = _dist(pr, r)
            if d > 30.0 then return end
            local key = kind .. ":" .. string.format("%.1f_%.1f", u.x, u.z)
            if (S.cool[key] or 0) > os.clock() then return end
            -- copied into plain tables: a via.vec3 ValueType held across frames is a needless risk
            out[#out + 1] = { kind = kind, key = key, go = go, dist = d,
                              u = { x = u.x, y = u.y, z = u.z },
                              r = { x = r.x, y = r.y, z = r.z } }
        end)
    end
    -- crop beds come from farming's own data rather than a scene scan. They are stored in
    -- UNIVERSAL coords (ux/uy/uz - IrisFarming.lua:323), which is already what the walker wants;
    -- only the raycast copy needs converting down into render space.
    pcall(function()
        local F = _G.IrisFarming
        local beds = F and F.beds and F.beds()
        if not beds or #beds == 0 then return end
        local dx, dy, dz = pu.x - pr.x, pu.y - pr.y, pu.z - pr.z   -- universal -> render
        for _, b in ipairs(beds) do
            if b.ux and b.crop then                                -- only a PLANTED bed
                local r = { x = b.ux - dx, y = b.uy - dy, z = b.uz - dz }
                local d = _dist(pr, r)
                if d <= 30.0 then
                    local key = "water:" .. string.format("%.1f_%.1f", b.ux, b.uz)
                    if (S.cool[key] or 0) <= os.clock() then
                        -- ⭐ hold the LIVE bed (IrisFarming.beds() returns the real table), so
                        --   performing can mark this exact bed watered rather than guessing by
                        --   coordinate afterwards
                        out[#out + 1] = { kind = "water", key = key, dist = d, bed = b,
                                          u = { x = b.ux, y = b.uy, z = b.uz }, r = r }
                    end
                end
            end
        end
    end)
    return out
end

-- ── the performances ─────────────────────────────────────────────────────────────────
-- ⭐ changeMotion for the free-standing ones (no jack, no FSM risk); the chair uses a JACK
--   onto the hidden seat, because that seat owns the sit pose and the chair does not.
-- ⛔ MY VERSION WAS ON THE WRONG OBJECT. `changeMotion` lives on the motion LAYER, not on the
--   via.motion.Motion component, and the character exposes it via get_Motion — not a getComponent
--   off the GameObject. Copied verbatim from the one that demonstrably plays emotes every day
--   (llm_freetalk.lua:8364 _play_motion). Mine threw inside its pcall and returned "ok" anyway,
--   so the log cheerfully said "pawn: watering" while nothing whatsoever happened.
local function _play(ch, bank, id)
    local ok = false
    pcall(function()
        ch:call("get_Motion"):call("getLayer", 0):call(
            "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
            bank, id, 0.0, 6.0, 1, 1)
        ok = true
    end)
    return ok
end

-- the puppet walk FREEZES the FSM to hold its walk clip; without releasing it the chore clip is
-- queued behind a frozen state and never shows (llm_freetalk.lua:8347, and :9770 does exactly
-- this before its own post-arrival animation)
local function _fsm(ch, on)
    pcall(function()
        local h = ch:call("get_Human")
        if h and h.Fsm then h.Fsm:set_Enabled(on) end
    end)
end

-- ⭐⭐ EACH CHORE RUNS FOR AS LONG AS ITS OWN ANIMATION RUNS (Aurora 08-09: "for watering the
--   animation should only last for as long as it lasts, so it should do watering start >
--   watering end like the player does"). One shared `hold_secs` was wrong: a pose you HOLD (a
--   chair) and a clip that PLAYS OUT (a pour) are different things.
--   ⇒ a chore is now a SEQUENCE of steps, each with its own length, and the body is handed back
--     the moment the last one finishes — not at some arbitrary global timer.
-- ⚠ KEEP IN STEP WITH IrisFarming's water emote (its M.water_* values): bank 61, intro 3050 for
--   254 frames, then end 3052 for 190 frames, then release. Those are its proven numbers; the
--   loop (3051) is deliberately skipped there and skipped here for the same reason.
-- ⭐ The frame counts are only a FALLBACK: we ask the live motion layer for the real end frame
--   first, so a clip that is not the length we think it is still gets its full run.
local CHORES = {
    water = { { bank = 61, id = 3050, f = 254 }, { bank = 61, id = 3052, f = 190 } },
    -- cook is a repetitive stir; a held duration genuinely is the right model for it, and
    -- Aurora said as much ("for things like sitting etc a set time is fine")
    cook  = { { bank = 60, id = 1103, hold = true } },
}

local function _clip_secs(ch, fallback_f)
    local secs
    pcall(function()
        local ef = ch:call("get_Motion"):call("getLayer", 0):call("get_EndFrame")
        if type(ef) == "number" and ef > 1 then secs = ef / 60.0 end
    end)
    return secs or ((tonumber(fallback_f) or 120) / 60.0)
end

local function _perform(job)
    local ch = _pawn(); if not ch then return end
    -- ⛔⛔ ORDER IS THE WHOLE FIX. The lead must DIE before the clip is played, or the puppet's
    --   own motion drive stomps it the same frame. RiftSpeak's own callbacks all do this
    --   (_hi5_on_arrive / _boost_on_arrive: `lead = nil` FIRST, then the pose). v3 never closed
    --   the lead at all — hence "performing" -> "done" with » leading to (fetch-pos) « still up
    --   and Lyra stood at the crop doing nothing.
    -- ⭐ reason "arrived" is load-bearing: _lead_stop plants a real Wait for that reason only
    --   (llm_freetalk.lua:12503), so she stays put instead of jogging back to the Arisen.
    _stop_walk("arrived")
    -- ⭐⭐ THE PROVEN CLIP RECIPE, AND THE FREEZE IS NOT OPTIONAL (llm_freetalk.lua:15321-15327):
    --   enable the FSM, changeMotion, then freeze it IMMEDIATELY. Freezing kills the AI action
    --   state machine so NormalLocomotion cannot reset the clip, while the motion layer still
    --   plays it through. RiftSpeak's own comment: "Delaying the freeze let NormalLocomotion
    --   stomp it." Without this she would twitch for a frame and go back to standing about.
    -- ⚠ AND IT MUST BE RELEASED. A frozen FSM never thaws itself — `hold_secs` below is what
    --   stops us leaving Aurora's pawn a statue at the crop bed.
    _fsm(ch, true)
    -- ⭐ arm the per-chore sequence; the pump below runs it and hands the body back at its END
    local steps = CHORES[job.kind]
    if job.kind == "lie" and M.lie_bank and M.lie_id then
        steps = { { bank = M.lie_bank, id = M.lie_id, hold = true } }
    end
    if job.kind == "water" then
        -- ⭐ AND IT ACTUALLY COUNTS (Aurora 08-09: "otherwise people will think that's a bug").
        --   Watering an already-watered bed is still allowed as set dressing — pawn_water just
        --   returns false and changes nothing — but a DRY bed she waters really does get the
        --   day stamp, the wet tint and a save, exactly as if you had done it yourself.
        local did = false
        pcall(function()
            local F = _G.IrisFarming
            if F and F.water and job.bed then did = F.water(job.bed) == true end
        end)
        _log(did and "pawn: watering (bed marked watered)" or "pawn: watering (already wet - for show)")
    elseif job.kind == "cook" then
        _log("pawn: cooking")
    elseif job.kind == "lie" then
        -- ⛔⛔ I MADE THIS CLIP ID UP. `60/2245` was never captured from anything — it was a
        --   guess, which is the one thing the clip rules say never to do. It is now nil by
        --   default so she simply stands at the bed instead of playing a wrong or non-existent
        --   animation, and the id becomes real the moment it is CAPTURED rather than invented.
        -- ⭐ HOW TO CAPTURE IT: IrisHomeLife's `motion_tape` logs the player's layer-0 bank/id
        --   every time it changes (IrisHomeLife.lua:81 — "this is how we learn the real
        --   animation ids"). With the BED fix in this same pass, lie down on a bed yourself and
        --   read the MOTION: line in IrisHomeLife.log. Put that bank/id in `lie_bank`/`lie_id`
        --   below and the pawn does it too.
        if M.lie_bank and M.lie_id then
            _log(string.format("pawn: lying down (%d/%d)", M.lie_bank, M.lie_id))
        else
            _log("pawn: at the bed, but the lie-down clip id is not known yet "
                 .. "(capture it with IrisHomeLife's motion tape, then set lie_bank/lie_id)")
        end
    elseif job.kind == "sit" then
        -- ⛔⛔ THE OLD CODE HERE WAS AIMED AT THE WRONG BODY. It called
        --   `IrisHomeLife.jack_for(job.go, ...)`, and that function takes NO character — every
        --   path inside it resolves `CharacterManager:get_ManualPlayer()`. It was trying to jack
        --   **the Arisen** onto a chair the pawn had walked to. It never seated her, and had the
        --   guards not refused it, it would have yanked Aurora across the room.
        -- ⭐ THE RIGHT ANSWER IS TO DO NOTHING. IrisHomeLife spawns those hidden gm80_257 seats
        --   at `native_seat_range` 12m explicitly "so pawns/NPCs can use chairs you are nowhere
        --   near" (IrisHomeLife.lua:89) — the GAME seats her. Our job is only to walk her to the
        --   chair and then GET OUT OF THE WAY: no clip, no FSM freeze. A frozen FSM is precisely
        --   what would stop the native sit from ever starting.
        _log("pawn: at the chair - leaving her to the native seat")
    end
    -- ⛔ ONLY FREEZE WHEN A CLIP IS ACTUALLY PLAYING. The freeze exists to stop locomotion
    --   stomping a chore animation; with no animation it just locks her standing like a statue.
    --   • sit  - the NATIVE seat does the work, and a frozen FSM would stop it ever starting
    --   • lie  - no captured clip id yet, so there is nothing to protect
    if not steps then return end
    -- fire step 1 now, then freeze so locomotion cannot stomp it
    local s1 = steps[1]
    _play(ch, s1.bank, s1.id)
    _fsm(ch, false)
    S.seq = { steps = steps, i = 1,
              until_at = os.clock() + (s1.hold and (M.hold_secs or 15.0) or _clip_secs(ch, s1.f)) }
end

-- ⭐ THE PUMP. Advances a chore to its next clip when the current one has actually finished, and
--   releases her the instant the LAST one does. `hold = true` steps (the cook stir) use the
--   dwell-style timer instead, which is the right model for a repeating loop.
local function _seq_pump(now)
    local q = S.seq; if not q then return end
    if now < q.until_at then return end
    q.i = q.i + 1
    local st = q.steps[q.i]
    local ch = _pawn()
    if not st or not ch then
        S.seq = nil
        if ch then _fsm(ch, true) end          -- hand the body back the moment the clip ends
        S.last = "done"
        return
    end
    _play(ch, st.bank, st.id)
    q.until_at = now + (st.hold and (M.hold_secs or 15.0) or _clip_secs(ch, st.f))
end

-- ── the tick ─────────────────────────────────────────────────────────────────────────
local function _tick()
    if M.enabled == false then return end
    local now = os.clock()
    if now - S.at < 0.5 then return end
    S.at = now

    S.ticks = (S.ticks or 0) + 1   -- ⭐ proves the tick is ALIVE. Without this, "not running at
                                   --   all" and "running but returning early" look identical.

    -- ⛔ THAW. This runs BEFORE every early return on purpose: a frozen FSM that never gets
    --   released is a pawn permanently stuck mid-chore, and "she wandered out of range" or
    --   "you switched it off" must not be the thing that strands her that way.
    _seq_pump(now)

    -- ⛔ NO BARE RETURNS PAST HERE. Every one of these used to be `return` with no status, which
    --   is exactly how the wrapper bug stayed invisible: the panel simply kept its last string.
    local pl, pawn = _player(), _pawn()
    if not pl   then S.last = "no player yet";      return end
    if not pawn then S.last = "no main pawn yet";   return end
    local pgo, wgo = _go(pl), _go(pawn)
    if not pgo then S.last = "player has no GameObject"; return end
    if not wgo then S.last = "pawn has no GameObject (unwrap failed)"; return end

    -- ⛔ v1 gated on `IrisFarming.nearest_plot()`, which IS NOT ON THE BRIDGE - only
    --   beds/save/till/aim are (IrisFarming.lua:5757). `plot` would have been nil forever,
    --   so the gate returned "not at a plot" every tick and the whole feature was dead.
    --   A silent self-disable, invisible to luac and to the ordering checker.
    -- ⭐ The gate was redundant anyway: the candidate scan only ever finds things Aurora
    --   has actually BUILT (hidden seats, cookpot, bed, crop beds). No homestead, no
    --   candidates, nothing happens.
    -- ⛔ ORDER MATTERS AND IT BIT US: this used to be a bare `return`, ABOVE the job block. With
    --   the goal in the wrong space Lyra walked out of range, this fired, and the tick returned
    --   before the stuck detector could ever run — so the walk was never cancelled and she just
    --   kept going. An out-of-range pawn must CALL OFF the walk, not stop watching it.
    -- ⭐ STAY MODE tracks "is she pottering here": on while enabled AND she is in range of the
    --   homestead, off the moment either stops being true. Without the OFF half she would be
    --   left on Wait out in the world, which is a pawn abandoned in a field.
    local near = _dist(_upos(pgo), _upos(wgo)) <= (M.pawn_range or 35.0)
    pcall(function()
        if _G.IrisWalk and _G.IrisWalk.stay then
            local want = (M.enabled == true) and near and (M.stay_put ~= false)
            if _G.IrisWalk.stay() ~= want then _G.IrisWalk.stay(want) end
        end
    end)

    -- ⛔ HER ORDER OUTRANKS OURS. Pressing "To Me!" must actually bring her, so while a command
    --   of yours is live we do not start new chores at all — otherwise she would set off for a
    --   chair the moment she reached you.
    local yielding = false
    pcall(function() yielding = _G.IrisWalk and _G.IrisWalk.yielding and _G.IrisWalk.yielding() == true end)
    if yielding and not S.job then
        S.last = "waiting - you gave her an order"
        return
    end

    if _dist(_upos(pgo), _upos(wgo)) > (M.pawn_range or 35.0) then
        if S.job then
            _stop_walk("iris_idle_out_of_range")
            S.job = nil; S.next_at = now + 5.0
            _log("pawn wandered out of range - walk cancelled")
        end
        -- ⭐ leaving the homestead ARMS the muster again, so she re-gathers on the way back in
        --   rather than starting chores from wherever she re-entered
        S.mustered, S.muster_i, S.muster_tries = nil, 1, 0
        S.last = "pawn is not nearby"
        return
    end

    -- a job in flight: watch for arrival, and for it going nowhere
    -- ⭐ UNIVERSAL both sides: `job.u` is what we handed the walker, so this is the same yardstick
    --   it is steering by. Mixing in a render read here is how the last one went wrong.
    if S.job then
        local p = _upos(wgo)
        local d = _dist(p, S.job.u)
        if d <= (M.reach_arrive or 2.5) or S.arrived then
            _log(string.format("pawn arrived at %s (%.1fm, %s) - performing", S.job.kind, d,
                S.arrived and "walker said so" or "distance"))
            S.arrived = nil
            _perform(S.job)
            S.job = nil
            S.next_at = now + math.random(M.dwell_min or 18, M.dwell_max or 40)
            S.last = "performed"
            return
        end
        -- ⛔ ONE OWNER FOR FAILURE, AND IT IS THE WALKER. IrisWalk already runs a stuck detector
        --   (climb a rung) and a hard timeout; a second, shorter one here would cancel walks
        --   mid-climb and we would never learn which rung actually works. So we only step in
        --   when IrisWalk has let go — then the target was genuinely no good, and it cools down.
        -- ⚠ Also note the pace change makes journeys legitimately SLOW now: 12m at a stroll is
        --   ~8s, which the old 6s "stuck" timer would have called a failure.
        local walking = true
        pcall(function()
            if _G.IrisWalk and _G.IrisWalk.busy then walking = _G.IrisWalk.busy() == true end
        end)
        if not walking then
            S.cool[S.job.key] = now + (M.cooldown or 150.0)
            _log(string.format("walker gave up on %s (%.1fm short) - cooled down", S.job.kind, d))
            S.job = nil
            S.next_at = now + 6.0
            S.last = "gave up on an unreachable target"
        else
            S.job.best = math.min(S.job.best or 1e9, d)   -- panel display only
        end
        return
    end

    if now < S.next_at then
        S.last = string.format("dwelling (%.0fs to go)", S.next_at - now)
        return
    end

    -- ⭐ MUSTER FIRST. On arriving at a homestead she walks to your chosen spot once, then
    --   potters from there — so she starts from the middle of the plot instead of from wherever
    --   the party happened to dump her (often outside the fence, where half the candidates fail
    --   the line-of-sight test and she looks stuck).
    if not S.mustered then
        S.muster_i = S.muster_i or 1
        local up = _upos(wgo)
        local mp, _, total = _muster_leg(up, S.muster_i)
        if not mp then
            S.mustered = true                     -- no route set / no plot / route finished
            S.muster_i = nil
        else
            -- ⛔ ONE LEG AT A TIME, and a leg only ends when she is ACTUALLY there. Walking the
            --   whole route as a single far target is what put her nose against the wall.
            local away = _dist(up, mp)
            if away <= (M.muster_ok or 4.0) then
                S.muster_i = S.muster_i + 1
                if S.muster_i > (total or 1) then
                    S.mustered = true; S.muster_i = nil
                    _log("muster: route complete - starting the idle routine")
                    S.last = "mustered - idling from here"
                end
                return
            end
            local walking = false
            pcall(function() walking = _G.IrisWalk and _G.IrisWalk.busy and _G.IrisWalk.busy() == true end)
            if walking then
                S.last = string.format("walking the muster route (leg %d/%d, %.0fm)",
                    S.muster_i, total or 1, away)
                return
            end
            -- ⭐ not walking and not there = IrisWalk gave up on this leg (its own stuck/timeout).
            --   Do NOT re-issue it forever: skip to the next leg, and if the whole route is
            --   unreachable just idle where she stands. Grinding into a wall is worse than
            --   starting the routine from an odd spot.
            if S.muster_tries and S.muster_tries >= (M.muster_retries or 2) then
                _log(string.format("muster: leg %d unreachable - skipping it", S.muster_i))
                S.muster_i, S.muster_tries = S.muster_i + 1, 0
                if S.muster_i > (total or 1) then S.mustered = true; S.muster_i = nil end
                return
            end
            local started = false
            pcall(function()
                if _G.IrisWalk and _G.IrisWalk.to then
                    started = _G.IrisWalk.to({ u = mp, r = mp }) == true
                end
            end)
            S.muster_tries = (S.muster_tries or 0) + (started and 0 or 1)
            S.last = started
                and string.format("walking the muster route (leg %d/%d, %.0fm)", S.muster_i, total or 1, away)
                or "muster: the walker refused"
            if started then _log(string.format("muster: leg %d/%d (%.1fm)", S.muster_i, total or 1, away)) end
            return
        end
    end

    -- pick something to do
    local cands = _candidates(wgo)
    if #cands == 0 then S.last = "nothing to do here"; S.next_at = now + 8.0; return end

    -- ⛔⛔ ROLL THE **KIND** FIRST, NOT THE CANDIDATE (Aurora 08-09: "she's focusing on the
    --   watering"). The old picker was `cands[math.random(#cands)]` — uniform over CANDIDATES.
    --   A farm with ten crop beds and one chair therefore rolls water 10 times in 13. That is
    --   not bad luck, it is arithmetic, and it gets worse the more she plants.
    --   ⇒ every KIND is one entry in the draw regardless of how many of it exist, so one chair
    --     is as likely as a whole field. Then a random one OF that kind.
    -- ⭐ plus a repeat penalty, because a fair coin still lands the same way twice and "watered,
    --   then watered again" is what reads as broken to a player.
    local pw = _rpos(wgo)
    local by = {}
    for _, c in ipairs(cands) do
        by[c.kind] = by[c.kind] or {}
        by[c.kind][#by[c.kind] + 1] = c
    end
    local pick = nil
    for _ = 1, 8 do
        local total, roster = 0, {}
        for k, list in pairs(by) do
            if #list > 0 then
                local w = (M.kind_weight and M.kind_weight[k]) or 1.0
                if k == S.last_kind then w = w * (M.repeat_penalty or 0.3) end
                if w > 0 then
                    total = total + w
                    roster[#roster + 1] = { k = k, w = w }
                end
            end
        end
        if total <= 0 then break end
        local roll, acc = math.random() * total, 0
        local chosen = roster[#roster].k
        for _, e in ipairs(roster) do
            acc = acc + e.w
            if roll <= acc then chosen = e.k; break end
        end
        local list = by[chosen]
        local idx = math.random(#list)
        local c = list[idx]
        table.remove(list, idx)           -- ⛔ drop it so a rejected one cannot be re-rolled
        -- ⛔⛔ THE LINE-OF-SIGHT GATE IS NOW OFF BY DEFAULT, AND THAT IS THE POINT. It existed
        --   because the drive beelined, so anything behind a wall was unreachable and had to be
        --   refused. IrisWalk can now steer round obstacles, so refusing every target without a
        --   clear line just means she never goes INDOORS — the exact case Aurora wants tested.
        --   Set require_los = true to get the old cautious behaviour back.
        if (M.require_los ~= true) or _reachable(pw, c.r) then pick = c; break end
        S.cool[c.key] = now + 30.0        -- short cooldown: it may be reachable from elsewhere
    end
    if not pick then S.last = "nothing reachable"; S.next_at = now + 10.0; return end

    -- ⛔ guarded: RiftSpeak owns this walker, and its `lead` state is a local we cannot read.
    --   If it refuses (it is mid-lead, or puppet driving is off) we simply try again later
    --   rather than fighting it for the body.
    -- ⛔⛔ UNIVERSAL. `_come_to_pos` measures against `_lpawn_upos()`. Hand it render coords and
    --   it walks off the edge of the homestead, which is exactly what it did.
    -- ⭐⭐ IRIS'S OWN WALKER FIRST. RiftSpeak is no longer a prerequisite for pawn idles —
    --   IrisWalk drives the pawn through its NATIVE navigation (setFollowObject) and only
    --   falls through to RiftSpeak's puppet as its last rung, if that mod happens to be there.
    --   Aurora 08-09: IRIS must not force anyone to install the AI mod.
    local started = false
    pcall(function()
        if _G.IrisWalk and _G.IrisWalk.to then
            _G.IrisWalk.settings.arrive = M.reach_arrive or 2.5
            started = _G.IrisWalk.to(
                { u = pick.u, r = pick.r, go = pick.go },
                function() S.arrived = true end) == true
        end
    end)
    -- ⛔ NO RIFTSPEAK FALLBACK. It used to be here and it is deliberately gone: `_come_to_pos`
    --   is reachable but `_lead_stop` is NOT (a forward-declared local, llm_freetalk.lua:11684),
    --   so that path could START a walk it could never CANCEL. That is precisely the bug — the
    --   lead kept driving, stomped the chore clip, and left » leading to (fetch-pos) « on screen
    --   with the pawn stood there doing nothing. If IrisWalk cannot do it, we fix IrisWalk.
    if not started then
        S.last = "IrisWalk could not start a walk"
        S.next_at = now + 10.0
        return
    end
    if not started then
        S.last = "RiftSpeak's walker refused (busy?)"
        S.next_at = now + 10.0
        return
    end
    S.arrived = nil   -- a stale flag from a cancelled walk would fire this one instantly
    S.last_kind = pick.kind          -- feeds the repeat penalty on the next roll
    S.job = { kind = pick.kind, key = pick.key, go = pick.go, bed = pick.bed,
              u = pick.u, r = pick.r, best = pick.dist, moved_at = now }
    S.last = "walking to " .. pick.kind
    _log(string.format("pawn heading to %s (%.1fm)", pick.kind, pick.dist))
end

re.on_application_entry("UpdateBehavior", function() pcall(_tick) end)

re.on_script_reset(function()
    -- never leave the pawn mid-walk owned by a module that no longer exists
    if S.job then _stop_walk("iris_idle_reset") end
    -- ⛔ a script reset must NOT leave a frozen FSM behind: the module goes away, the statue stays
    pcall(function() local w = _pawn(); if w then _fsm(w, true) end end)
    -- ...nor a pawn parked on Wait with nothing left to un-park her
    pcall(function() if _G.IrisWalk and _G.IrisWalk.stay then _G.IrisWalk.stay(false) end end)
    S.seq = nil          -- drop any chore sequence mid-flight; the thaw above already ran
    S.job = nil
end)

re.on_draw_ui(function()
    if not imgui.tree_node("IRIS PAWN IDLE (pottering about the homestead)") then return end
    imgui.text("Your pawn wanders the homestead and uses what you have actually built.")
    imgui.text("status: " .. tostring(S.last))
    imgui.text("job: " .. (S.job and (S.job.kind .. string.format(" (%.1fm best)", S.job.best or -1)) or "none"))
    -- ⭐ if this number is not climbing, the tick is not running and NOTHING below matters.
    local wmode = "-"
    pcall(function() wmode = (_G.IrisWalk and _G.IrisWalk.mode and _G.IrisWalk.mode()) or "idle" end)
    imgui.text(string.format("ticks: %d   |   IrisWalk: %s", S.ticks or 0,
        _G.IrisWalk and ("loaded, rung=" .. tostring(wmode)) or "MISSING - IrisWalk.lua not loaded!"))
    local c
    c, M.enabled = imgui.checkbox("enabled (off by default - it drives your pawn)", M.enabled == true)
    c, M.stay_put = imgui.checkbox("she stays here instead of following you (\"To Me!\" overrides)",
        M.stay_put ~= false)
    pcall(function()
        if _G.IrisWalk and _G.IrisWalk.yielding and _G.IrisWalk.yielding() then
            imgui.text("   -> standing down: you gave her an order")
        end
    end)
    -- ⛔ "stop isn't stopping her" — and it genuinely wasn't, because `_lead_stop` DID fire and
    --   then the tick handed her a brand-new destination five seconds later. A panic button that
    --   only pauses is not a panic button. STOP now UNTICKS `enabled` as well, so it means stop.
    if imgui.button("STOP what the pawn is doing") then
        _stop_walk("iris_idle_panel")
        -- ⛔ thaw IMMEDIATELY: the panic button must never leave her frozen mid-chore
        local w = _pawn(); if w then _fsm(w, true) end
        S.seq = nil
        S.job = nil; M.enabled = false
        -- ⛔ the panic button must also give her BACK: leaving stay mode on would strand her
        --   on Wait with nothing left running to release it
        pcall(function() if _G.IrisWalk and _G.IrisWalk.stay then _G.IrisWalk.stay(false) end end)
        S.next_at = os.clock() + 5.0; S.last = "stopped by hand (also switched off)"
    end
    imgui.same_line()
    -- ⭐ testing without this means 18-40s of staring per attempt
    if imgui.button("do something NOW") then S.job = nil; S.next_at = 0; S.last = "forced" end
    -- ═════════ muster point ═════════
    imgui.separator()
    do
        local m = _muster_load()
        -- ⭐ WALK THE ROUTE YOURSELF, pressing "add" at each corner. She has no pathfinding, so
        --   the corners you walk ARE her path. Stored in the house frame -> works at every plot.
        imgui.text(m and string.format("muster route: %d point(s)", #m.pts)
                     or "muster route: none (she idles from wherever she is)")
        if m then
            for i, p in ipairs(m.pts) do
                imgui.text(string.format("   %d. %.1fm fwd, %.1fm right", i, p.f, p.r))
            end
        end
        if imgui.button("add a point where I'm standing") then
            local pl = _player(); local pgo2 = pl and _go(pl)
            local up = pgo2 and _upos(pgo2)
            local plot = up and _plot_at(up)
            if not plot then
                S.last = "no saved homestead plot here - SAVE one first"
            else
                local f, r = _to_local(up.x - plot.ux, up.z - plot.uz, plot.yaw)
                if not muster then muster = { pts = {} } end
                muster.pts[#muster.pts + 1] = { f = f, r = r, y = up.y - plot.uy }
                _muster_save()
                S.mustered, S.muster_i, S.muster_tries = nil, 1, 0
                _log(string.format("muster: added point %d (%.2f fwd, %.2f right) at plot '%s'",
                    #muster.pts, f, r, tostring(plot.name)))
                S.last = string.format("muster: %d point(s)", #muster.pts)
            end
        end
        imgui.same_line()
        if imgui.button("undo last") then
            if muster and muster.pts and #muster.pts > 0 then
                table.remove(muster.pts)
                if #muster.pts == 0 then muster = false end
                _muster_save(); S.last = "muster: removed the last point"
            end
        end
        imgui.same_line()
        if imgui.button("clear route") then
            muster = false; _muster_save()
            S.mustered, S.muster_i = nil, nil
            S.last = "muster route cleared"
        end
        if imgui.button("walk the route now") then
            S.mustered, S.muster_i, S.muster_tries = nil, 1, 0
            S.next_at = 0
        end
    end
    imgui.separator()
    if imgui.button("what can it see from here?") then
        local w = _pawn(); w = w and _go(w)
        local cs = w and _candidates(w) or {}
        -- ⭐ counts AND reachability per kind: this is what shows whether indoor things are
        --   being filtered out by the line-of-sight test rather than simply not existing
        local n, ok = {}, {}
        for _, x in ipairs(cs) do
            local r = _reachable(_rpos(w), x.r)
            n[x.kind] = (n[x.kind] or 0) + 1
            ok[x.kind] = (ok[x.kind] or 0) + (r and 1 or 0)
        end
        _log(string.format("SCAN: %d candidate(s)", #cs))
        for k, v in pairs(n) do
            _log(string.format("  %-6s x%-3d  %d reachable from here", k, v, ok[k] or 0))
        end
        for _, x in ipairs(cs) do
            _log(string.format("    %-6s %5.1fm  reachable=%s", x.kind, x.dist,
                tostring(_reachable(_rpos(w), x.r))))
        end
        local sum = {}
        for k, v in pairs(n) do sum[#sum + 1] = string.format("%s %d/%d", k, ok[k] or 0, v) end
        S.last = "scan: " .. (#sum > 0 and table.concat(sum, ", ") or "nothing")
    end
    imgui.separator()
    c, M.dwell_min  = imgui.slider_float("dwell min (s)", M.dwell_min or 18, 3, 120)
    c, M.dwell_max  = imgui.slider_float("dwell max (s)", M.dwell_max or 40, 5, 240)
    c, M.stuck_secs = imgui.slider_float("give up after (s)", M.stuck_secs or 6, 2, 20)
    c, M.hold_secs  = imgui.slider_float("hold the chore pose (s)", M.hold_secs or 8, 2, 30)
    imgui.separator()
    imgui.text("how often she picks each (0 = never):")
    for _, k in ipairs({ "water", "sit", "cook", "lie" }) do
        c, M.kind_weight[k] = imgui.slider_float(k, M.kind_weight[k] or 1.0, 0.0, 3.0)
    end
    c, M.repeat_penalty = imgui.slider_float("less likely to repeat", M.repeat_penalty or 0.3, 0.0, 1.0)
    imgui.separator()
    c, M.reach_arrive = imgui.slider_float("arrival radius (m)", M.reach_arrive or 2.5, 1.0, 6.0)
    c, M.log = imgui.checkbox("write the log", M.log)
    local n = 0
    for _, t in pairs(S.cool) do if t > os.clock() then n = n + 1 end end
    imgui.text(string.format("%d target(s) cooling down (unreachable / gave up)", n))
    imgui.tree_pop()
end)

-- ⭐ so IrisWalk can tell when a chore owns the body and keep its hands off (its drive re-aims
--   and re-fires the walk clip every frame, which is what made her vibrate and face the wrong way)
_G.IrisPawnIdle = {
    posing = function() return S.seq ~= nil end,
    busy   = function() return S.job ~= nil or S.seq ~= nil end,
}

_log("IrisPawnIdle loaded (disabled by default)")
