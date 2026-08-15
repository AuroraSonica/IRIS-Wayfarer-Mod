-- IrisAnimLab.lua -- ⭐ THE CREATURE ANIMATION LAB (2026-08-14)
--
-- One panel that answers "what can THIS creature actually do?" for whichever tamed body is out.
--
--   1. IDENTITY  -- ch id, variant key, friendly species, the stable record (name/gender/kind),
--                   who else claims this body, plus a LIVE readout of the motion layers and of
--                   every FSM tree's current node.
--   2. MOTION LIBRARY -- every real bank:id on that body, browsed with the RiftSpeakDevDebug
--                   stepper layout (-10/-1/+1/+10, auto-play, layer, freeze). Empty ids can never
--                   appear: the catalogue IS the engine's own enumeration.
--   3. NODE LIBRARY   -- every FSM node name on that body (all four trees), browsed with the
--                   Griffin Ride Probe picker layout (filter -> combo -> fire), plus RESET and
--                   kill switches.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- ⛔⛔⛔ WHY THIS FILE IS MOSTLY SAFETY CODE
--
-- A "play every clip in the library" button is, built naively, a crash generator. The laws it
-- has to obey, all of them paid for with real CTDs:
--
--  L1  A clip's `.mot` DATA only streams while the FSM sits in a node of that clip's family.
--      Parked, a griffin's flight clips (0:5000-0:5210) are NULL POINTERS. changeMotion on one is
--      a native access violation. Enumeration does NOT save you -- getMotionInfoByIndex reports
--      metadata for clips whose data is not resident.
--  L2  ⛔ pcall CANNOT CATCH ANY OF IT. The engine AVs one or two frames AFTER your Lua returned
--      ok=true. An `ok=true` proves nothing. The only real instrument is a tape on disk.
--  L3  Think-stop ALONE leaves the FSM owning layer 0, so a painted clip never shows. Clips only
--      SHOW with via.motion.MotionFsm2 disabled.
--  L4  ...but a THINK-STOPPED body playing a streamed clip is a native AV. So the safe puppet is
--      think ALIVE + MotionFsm2 off. Never think-stop a body you are about to fly.
--  L5  ONE OWNER OF LAYER 0. A painted clip plus a running native node on the same layer is the
--      two-owner AV signature behind the eleven-CTD clip-5010 tape.
--  L6  A wrong-KIND clip is as lethal as a wrong id. Additive poses (the *_add_pose family) are
--      valid only layered over a base loop on L1; evaluated as a base L0 pose they mangle the body.
--  L7  Node names must be validated against the LIVE tree -- an unknown name in setCurrentNode is
--      a native crash. And validation must fail CLOSED: the griffin's own guard fails OPEN on a
--      zero-node read, which would wave every typo through.
--  L8  Cross-tree node fires (Locomotion.Wait -> Fly.*) were all three 2026-07-26 CTDs.
--  L9  requestAction/requestActionCore are SILENTLY REJECTED unless IsRejectRequestOnDefault is
--      cleared first. Clear -> fire -> RESTORE. A fire that "did nothing" is usually this.
--  L10 A frozen FSM must be thawed on EVERY exit path, including re.on_script_reset -- otherwise a
--      reload strands a think-stopped, FSM-disabled statue nothing will ever restore.
--  L11 Never hammer: repeatedly forcing state onto a parked FSM is a known hard-crash class here.
--  L12 Never sdk.hook anything (no unhook exists; an orphan outlives a reset). This file hooks
--      NOTHING -- every call is a query or a direct one-shot.
--
-- THE THREE DEFENCES BUILT ON TOP OF THOSE LAWS:
--
--  ⭐ WITNESS LEDGER  -- every bank:id the body plays of its OWN accord is proof that clip's data
--     is resident. Recorded per species to data/IrisAnimLab_witness.json and shown as ✅. Ordinary
--     play sessions grow a verified safe-list; the tool gets safer the more you use it.
--  ⭐ CRASH TAPE      -- a latch written to disk BEFORE every risky fire and cleared after. If the
--     game dies mid-call, the next launch reads the open latch, names the exact clip or node that
--     killed it, and adds it to a persistent ☠ KILLED list that is refused from then on. This is
--     the only instrument that works when pcall cannot (L2).
--  ⭐ ONE-SHOT ARMS   -- overriding a refusal needs a ⛔ tick that clears itself after a single
--     use. Nothing dangerous can ever be left armed, and nothing dangerous is armed at load.
--
-- Files it writes, all under reframework/data/ :
--   IrisAnimLab.json                                  panel config
--   IrisAnimLab_witness.json                          proven-resident clips, per ch id
--   IrisAnimLab_tape.json                             the crash latch + the ☠ killed list
--   IRIS Node Atlas/IrisNodes_<chid>_<Species>.json   node atlas per creature
--   IRIS Node Atlas/IrisMotions_<chid>.json           motion atlas from a live rescan
-- It READS the existing motion atlases (data/IrisTaming_atlas_<chid>.json, the same files mirrored
-- in reframework/Animal Atlas/) so a known creature's library is one click away with no rescan.
-- ════════════════════════════════════════════════════════════════════════════════════════════

local MOD          = "IrisAnimLab"
local CFG_FILE     = "IrisAnimLab.json"
local WITNESS_FILE = "IrisAnimLab_witness.json"
local TAPE_FILE    = "IrisAnimLab_tape.json"
local NODE_DIR     = "IRIS Node Atlas"
local CFG_VERSION  = 1

-- ============================================================================================
-- CONFIG  (a saved file outranks these defaults, so any default change needs a version bump)
-- ============================================================================================
local DEF = {
    cfg_version      = CFG_VERSION,

    -- ⛔⛔⛔ UNSAFE MODE (Aurora, 08-14: "I don't care if it crashes, that's part of the test").
    -- This is a LAB. Every guard below becomes an ADVISORY: the panel still shows ⛔/⚠ on a clip or
    -- node it considers dangerous, but nothing is refused. Deliberately NOT force-reset at load --
    -- it fires nothing by itself, so it cannot re-crash you on relaunch; it only changes what
    -- happens when YOU click. The ☠ KILLED list survives it, because a thing that already took the
    -- game down is data, not a guess.
    unsafe           = false,

    target_mode      = "companion",   -- companion | nearest | pinned

    -- motion browser
    bank             = 0,
    motion           = 0,
    layer            = 0,
    auto_play        = true,
    hold_mode        = true,          -- ⛔ L3: FSM off = the clip actually shows and holds
    think_stop       = false,         -- ⛔ L4: lethal with streamed clips; stays off by default
    blend_frames     = 8.0,
    clip_filter      = "",
    -- ⛔ every hold needs an absolute ceiling that cannot fail. Walk away mid-experiment and the
    -- creature would otherwise stay a statue forever. 0 disables it (hold until you say stop).
    hold_ceiling_sec = 180,

    -- residency guards
    safe_ceiling     = 400,           -- the griffin mod's own hard-reject threshold for parked play
    ceiling_bank0_only = true,        -- ⭐ the ceiling is a BANK-0 rule: bank 0 is where every
                                      -- documented streamed-clip AV lives. Outside bank 0 a clip
                                      -- that needs node context T-POSES, it does not crash --
                                      -- so it warns instead of refusing. false = paranoid mode.
    guard_ceiling    = true,
    guard_additive   = true,          -- ⛔ L6: refuse *_add_pose clips on layer 0
    guard_claimed    = true,          -- ⛔ refuse a body another IRIS module is puppeting
    guard_killed     = true,          -- ⛔ refuse anything the crash tape caught killing us

    -- scan
    deep_bank0       = true,
    deep_bank0_max   = 8000,
    scan_budget      = 400,

    -- node browser
    node_filter      = "",
    node_fire_mode   = "requestAction",
    node_layer       = 0,
    node_clear_reject = true,
    reject_restore_frames = 12,
    -- ⭐ A node fired ONCE at a parked companion is stomped within a frame: IRIS keeps its own
    -- clip painted on layer 0 and the FSM disabled, so our node never gets to run and you see
    -- nothing at all. Re-assert it on the documented-safe cadence instead.
    -- ⛔ LAW 14: NEVER hammer an FSM every frame -- ~100 requests/sec is a known hard-crash class
    -- in this codebase (it killed the cookpot). ~0.15s spacing, ~8 attempts, then stop.
    node_reassert    = true,
    node_reassert_secs = 2.0,
    node_reassert_gap  = 0.15,
    node_reassert_max  = 8,

    -- ⭐⭐ THE GRIFFIN NODE RECIPE (ported from route3_rise_start_clip + griffin_node_exit_pump).
    -- PREP frees the body so a node can physically run, then RESTORE pumps it back to the node it
    -- was in and puts every flag back the way it was -- the same shape the mount's rise/dive uses.
    node_prep        = true,
    node_fire_layer4 = true,   -- the rise path fires the leaf on layer 4 AND layer 0, in that order
    node_autorestore = true,   -- restore automatically once the assert window closes
    node_restore_secs = 1.5,   -- exit-pump ceiling: a pump that can wedge is worse than the bug
    node_restore_gap  = 0.10,

    node_blocklist   = "PreSwoop,HoverBackward,Hovering",
    guard_crosstree  = true,
    -- ⭐ cross-tree HARD-refuses setCurrentNode (the raw slam) but only WARNS on requestAction /
    -- requestActionCore, which validate the transition themselves. true = refuse on every door.
    crosstree_blocks_requests = false,
    node_reset_neutral = true,
}

local C = {}
for k, v in pairs(DEF) do C[k] = v end

local S = {
    status        = "idle -- summon a tamed creature, or stand near any body",
    target = nil, target_go = nil, target_key = nil, pinned = nil,
    ident = nil, cat = nil, nodes = nil, scan = nil,
    witness = {}, witness_dirty = false,
    killed = {},                 -- [chid] = { ["clip 0:5100"]=true, ["node Fly.X"]=true }
    tape = nil,                  -- the open latch, if the last session died inside a fire
    last_play = nil, verify = nil,
    frame = 0, last_tick = 0.0, defer = {},
    arm_ceiling = false, arm_crosstree = false, arm_killed = false,
    froze = nil, reject = nil, node_fired = nil,
    node_pick = 1, broken_scan = 0,
}

-- ============================================================================================
-- HELPERS  (namespaced so the chunk stays far under Lua's 200-local ceiling)
-- ============================================================================================
-- ⛔ ALL FOUR NAMESPACE TABLES ARE DECLARED HERE, TOGETHER, ON PURPOSE.
-- A name that is not an in-scope local at COMPILE time silently becomes a global lookup, and a
-- global that is nil at runtime fails silently inside the pcall that wraps it -- the exact
-- "local does not exist above its own definition" trap luac cannot catch. H.panic legitimately
-- needs to call ND.prep_finish (a node prep must never survive a panic), and ND was declared 500
-- lines below it, so that call was compiling to `_ENV.ND` and quietly doing nothing.
-- Members are still ASSIGNED further down; only the declarations are hoisted.
local H, MO, ND, UI = {}, {}, {}, {}

function H.sc(o, m, ...)
    if not o then return nil end
    local a = { ... }
    local ok, r = pcall(function() return o:call(m, table.unpack(a)) end)
    if ok then return r end
    return nil
end

function H.singleton(n)
    local ok, v = pcall(function() return sdk.get_managed_singleton(n) end)
    return ok and v or nil
end

function H.comp(go, tn)
    if not go then return nil end
    local ok, c = pcall(function() return go:call("getComponent(System.Type)", sdk.typeof(tn)) end)
    return ok and c or nil
end

function H.char_go(ch)
    if not ch then return nil end
    local ok, go = pcall(function() return ch:call("get_GameObject") end)
    return ok and go or nil
end

function H.go_name(go)
    local ok, n = pcall(function() return go and go:call("get_Name") end)
    return (ok and n ~= nil) and tostring(n) or ""
end

function H.addr(o)
    local ok, a = pcall(function() return o and o:get_address() end)
    return ok and a or nil
end

function H.upos(go)
    local ok, p = pcall(function() return go:call("get_Transform"):call("get_UniversalPosition") end)
    return ok and p or nil
end

function H.dist(a, b)
    if not (a and b) then return 1e9 end
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- ⛔ the ONLY player getter that works post-patch (reframework-postpatch-gotchas 2c)
function H.player()
    local cm = H.singleton("app.CharacterManager")
    local ok, p = pcall(function() return cm and cm:call("get_ManualPlayer") end)
    return ok and p or nil
end

-- ⛔ the one question every guard asks first. In unsafe mode a guard may still WARN, never refuse.
function H.unsafe() return C.unsafe == true end

function H.status(m)
    S.status = tostring(m)
    pcall(function() log.info("[" .. MOD .. "] " .. tostring(m)) end)
end

-- Cross-file bridges are resolved LAZILY every call, never cached at load: autorun load order is
-- not guaranteed and a nil captured at load never heals (the dead-rays cross-file law).
function H.bridge()
    local b = rawget(_G, "IrisGriffinBridge")
    return (type(b) == "table") and b or nil
end

function H.species_name(go)
    local n = nil
    pcall(function()
        local sp = rawget(_G, "IrisSpecies")
        if sp and sp.name then n = sp.name(go) end
    end)
    if n and n ~= "" then return tostring(n) end
    pcall(function()
        local f = rawget(_G, "iris_type_name")     -- the griffin probe's namer (a true global)
        if type(f) == "function" then n = f(H.go_name(go)) end
    end)
    return (n and n ~= "" and tostring(n)) or nil
end

function H.motion_of(ch) return H.sc(ch, "get_Motion") end

function H.layer_of(ch, idx)
    local m = H.motion_of(ch)
    if not m then return nil end
    return H.sc(m, "getLayer", math.floor(tonumber(idx) or 0))
end

function H.fsm_of(go) return H.comp(go, "via.motion.MotionFsm2") end

function H.action_manager(ch)
    if not ch then return nil end
    local am = nil
    pcall(function() am = ch:get_field("<ActionManager>k__BackingField") end)
    if am then return am end
    return H.sc(ch, "get_ActionManager")
end

function H.defer(frames, fn)
    S.defer[#S.defer + 1] = { frames = math.max(1, math.floor(tonumber(frames) or 1)), fn = fn }
end

-- ── files ------------------------------------------------------------------------------------
function H.save_config() pcall(function() json.dump_file(CFG_FILE, C) end) end

function H.load_config()
    local d = nil
    pcall(function() d = json.load_file(CFG_FILE) end)
    if type(d) ~= "table" then return end
    -- ⛔ griffin-mount v7's lesson: without a version gate the saved file silently wins over every
    -- new default and the "fix" is a no-op the user can never see.
    if math.floor(tonumber(d.cfg_version) or 0) ~= CFG_VERSION then return end
    for k, v in pairs(d) do
        if DEF[k] ~= nil and type(v) == type(DEF[k]) then C[k] = v end
    end
    -- ⛔ nothing dangerous may survive a restart, whatever the file says
    C.think_stop = false
end

function H.save_witness()
    pcall(function() json.dump_file(WITNESS_FILE, S.witness) end)
    S.witness_dirty = false
end

function H.load_witness()
    local d = nil
    pcall(function() d = json.load_file(WITNESS_FILE) end)
    if type(d) ~= "table" then return end
    -- ⛔ SANITISE. An early build recorded the layer's "no motion" sentinel (0xFFFFFFFF =
    -- 4294967295) as though it were a clip, so existing ledgers carry entries like "0:4294967295".
    -- Harmless in practice (the catalogue gate refuses anything the enumerator never returned) but
    -- it is a lie in the safe-list, and a safe-list that lies is worth nothing. Self-healing.
    local dropped = 0
    for chid, set in pairs(d) do
        if type(set) == "table" then
            for k in pairs(set) do
                if tostring(k):find("4294967295", 1, true) then set[k] = nil; dropped = dropped + 1 end
            end
        end
    end
    S.witness = d
    if dropped > 0 then S.witness_dirty = true end
end

-- ============================================================================================
-- ⭐ THE CRASH TAPE -- the only instrument that works when pcall cannot (L2)
-- ============================================================================================
-- Before any fire that could AV, we write {open=true, what=...} to disk. After it survives a few
-- frames we write {open=false}. If the game dies in between, the latch is still open at the next
-- launch: we name the killer and add it to the persistent ☠ list, which is refused from then on.

function H.tape_save(payload)
    pcall(function() json.dump_file(TAPE_FILE, payload) end)
end

function H.tape_load()
    local d = nil
    pcall(function() d = json.load_file(TAPE_FILE) end)
    if type(d) ~= "table" then return end
    S.killed = (type(d.killed) == "table") and d.killed or {}
    if d.open == true and d.what then
        local chid = tostring(d.chid or "unknown")
        S.killed[chid] = S.killed[chid] or {}
        S.killed[chid][tostring(d.what)] = true
        S.tape = { what = tostring(d.what), chid = chid }
        H.tape_flush(false, nil, nil)
        H.status("⛔ LAST SESSION DIED FIRING  " .. tostring(d.what) .. "  on " .. chid
            .. "  -- added to the ☠ KILLED list and refused from now on")
    end
end

function H.tape_flush(open, what, chid)
    H.tape_save({ open = open == true, what = what, chid = chid, killed = S.killed })
end

function H.is_killed(chid, what)
    local k = S.killed[tostring(chid or "")]
    return type(k) == "table" and k[tostring(what)] == true
end

function H.tape_open(what, chid)
    H.tape_flush(true, what, chid)
    -- ⛔ TOKENED. The close is deferred, so two fires inside the window used to cross: fire A's
    -- timer would close fire B's latch, and if B then AV'd the next launch read a CLEAN tape --
    -- no killer named, nothing added to the ☠ list, and the same clip offered again as safe.
    -- Losing the one instrument that works when pcall cannot is the worst possible failure here.
    S.tape_token = (tonumber(S.tape_token) or 0) + 1
    local mine = S.tape_token
    H.defer(12, function()
        if S.tape_token == mine then H.tape_flush(false, nil, nil) end
    end)
end

H.load_config()
H.load_witness()
H.tape_load()

-- ============================================================================================
-- TARGET
-- ============================================================================================

-- ⛔ ADDRESS-CLASS LAW: IrisGriffinBridge.griffin() returns the CHARACTER first and the GAMEOBJECT
-- second, and the two have different addresses. Everything address-keyed here uses the GameObject.
function H.companion()
    local b = H.bridge()
    if not (b and b.griffin) then return nil, nil end
    local ch, go = nil, nil
    pcall(function() ch, go = b.griffin() end)
    if ch and not go then go = H.char_go(ch) end
    if ch and go then return ch, go end
    return nil, nil
end

-- ⛔ findComponents returns a REFramework SystemArray: walk it with get_size()/get_element(i).
-- get_Count answers correctly while get_Item returns nil for EVERY element -- a half-working guess
-- that produces a confident zero. So we count unreadable elements and shout instead of concluding.
-- ⚠ PERF: this is a full-scene findComponents sweep over every app.Character. resolve_target calls
-- it every frame whenever no companion is out, and DD2 is hard CPU-bound with mods already eating
-- ~25-35% of the frame. Cached for half a second -- a creature cannot walk out of a 40m radius in
-- that time, and it takes the cost from per-frame to twice a second.
function H.nearest_creature()
    local now = os.clock()
    local nc = S.near
    if nc and (now - nc.t) < 0.5 then
        -- a cached body can still be destroyed under us; re-derive the GO and drop it if it went
        if nc.ch and H.char_go(nc.ch) then return nc.ch, nc.go end
        if not nc.ch then return nil, nil end
    end
    S.near = { t = now }

    local pgo = H.char_go(H.player())
    local pp = pgo and H.upos(pgo)
    if not pp then return nil, nil end
    local self_addr = H.addr(pgo)
    local best, best_go, best_d = nil, nil, 40.0
    local seen, unread = 0, 0
    pcall(function()
        local sm = sdk.get_native_singleton("via.SceneManager")
        local smt = sdk.find_type_definition("via.SceneManager")
        local scene = sm and sdk.call_native_func(sm, smt, "get_CurrentScene")
        local comps = scene and scene:call("findComponents(System.Type)", sdk.typeof("app.Character"))
        if not comps then return end
        local n = 0
        pcall(function() n = comps:get_size() or 0 end)
        if (tonumber(n) or 0) == 0 then pcall(function() n = tonumber(comps:call("get_Length")) or 0 end) end
        for i = 0, (tonumber(n) or 0) - 1 do
            seen = seen + 1
            local ch = nil
            pcall(function() ch = comps:get_element(i) end)
            if ch == nil then pcall(function() ch = comps:call("get_Item", i) end) end
            if ch == nil then
                unread = unread + 1
            else
                pcall(function()
                    local go = H.char_go(ch)
                    local nm = go and H.go_name(go) or ""
                    if go and H.addr(go) ~= self_addr
                        and nm:find("ch", 1, true) == 1 and not nm:find("ch000", 1, true) then
                        local p = H.upos(go)
                        local d = p and H.dist(p, pp) or 1e9
                        if d < best_d then best_d = d; best = ch; best_go = go end
                    end
                end)
            end
        end
    end)
    S.broken_scan = (seen > 0 and unread == seen) and seen or 0
    S.near = { t = os.clock(), ch = best, go = best_go }
    return best, best_go
end

function H.resolve_target()
    local ch, go = nil, nil
    local mode = tostring(C.target_mode or "companion")

    if mode == "pinned" and S.pinned then
        ch = S.pinned
        go = H.char_go(ch)
        if not go then S.pinned = nil; ch = nil end
    end
    if not ch and mode ~= "nearest" then ch, go = H.companion() end
    if not ch then ch, go = H.nearest_creature() end

    -- ⛔ address-reuse hazard: a destroyed body's allocation can be handed to the next spawn, and an
    -- address-only cache key would then serve the OLD creature's catalogue for the NEW body. The GO
    -- name is part of the key so a re-used allocation with a different creature invalidates cleanly.
    local key = go and (tostring(H.addr(go)) .. "|" .. H.go_name(go)) or nil
    if key ~= S.target_key then
        S.target_key = key
        S.cat, S.nodes, S.scan, S.ident, S.verify = nil, nil, nil, nil, nil
        S.node_pick = 1
    end
    S.target, S.target_go = ch, go
    return ch, go
end

-- ── who else claims this body? two puppeteers on one body is a crash ---------------------------
function H.claims(go)
    local out = {}
    if not go then return out end
    local a = H.addr(go)
    pcall(function()
        local d = rawget(_G, "IrisDownedAddrs")
        if type(d) == "table" and a and d[a] then out[#out + 1] = "DOWNED (griffin mod owns its animation)" end
    end)
    pcall(function()
        local b = H.bridge()
        if b and b.is_mounted and b.is_mounted(go) == true then out[#out + 1] = "MOUNTED (you are riding it)" end
    end)
    pcall(function()
        local r = rawget(_G, "IrisRiddenNow")
        if r ~= nil and a and ((type(r) == "table" and r[a]) or r == a) then out[#out + 1] = "RIDDEN (rodeo)" end
    end)
    pcall(function()
        local hb = rawget(_G, "IrisHomesteadBox")
        if type(hb) == "table" and hb.is_resident and a and hb.is_resident(a) then
            out[#out + 1] = "homestead resident"
        end
    end)
    return out
end

function H.blocking_claim(go)
    for _, c in ipairs(H.claims(go)) do
        if c:find("DOWNED", 1, true) or c:find("MOUNTED", 1, true) or c:find("RIDDEN", 1, true) then
            return c
        end
    end
    return nil
end

-- ── identity -----------------------------------------------------------------------------------
function H.identity()
    if S.ident and S.ident.key == S.target_key then return S.ident end
    local go = S.target_go
    if not go then S.ident = nil; return nil end
    local raw = H.go_name(go)
    local base = raw:match("^[^@]+") or raw
    local id = {
        key     = S.target_key,
        raw     = raw,
        chid    = base:match("ch%d+") or "unknown",
        vkey    = base:match("ch%d+_%a_%d+") or base:match("ch%d+_%d+") or nil,
        species = H.species_name(go) or nil,
        record  = nil,
        is_companion = false,
    }
    pcall(function()
        local b = H.bridge()
        if b and b.is_companion_body then id.is_companion = b.is_companion_body(go) == true end
    end)
    if not id.is_companion then
        pcall(function()
            local _, cgo = H.companion()
            id.is_companion = (cgo ~= nil) and (H.addr(cgo) == H.addr(go))
        end)
    end
    -- ⛔ the stable's "live" record describes the SUMMONED COMPANION. Attaching it to whatever body
    -- happens to be targeted put the griffin's name, gender and kind on a wild wolf -- and that
    -- wrong label was then baked into the motion library header too.
    if id.is_companion then
        pcall(function()
            local b = H.bridge()
            local list = b and b.stable_list and b.stable_list()
            if type(list) ~= "table" then return end
            for _, r in ipairs(list) do if r.live then id.record = r end end
        end)
    end
    S.ident = id
    return id
end

function H.chid() local id = H.identity(); return id and id.chid or "unknown" end

function H.label()
    local id = H.identity()
    if not id then return "(no body)" end
    local bits = { id.species or id.chid }
    if id.record and id.record.name and id.record.name ~= "" then
        bits[#bits + 1] = "\"" .. tostring(id.record.name) .. "\""
    end
    bits[#bits + 1] = id.chid
    return table.concat(bits, "  ")
end

-- ============================================================================================
-- FSM STATE  -- everything WE switch off is remembered so PANIC can put it all back (L10)
-- ============================================================================================

function H.set_fsm(go, on)
    local f = H.fsm_of(go)
    if not f then return false end
    return pcall(function() f:call("set_Enabled", on == true) end)
end

function H.fsm_enabled(go)
    local v = H.sc(H.fsm_of(go), "get_Enabled")
    if v == nil then return nil end
    return v == true
end

function H.set_puppet(go, on)
    local f = H.fsm_of(go)
    if not f then return false end
    return pcall(function() f:call("set_PuppetMode", on == true) end)
end

-- ⛔ griffin-mount v6b: NEVER write <IsThinkStop>k__BackingField. An invalid field write is a C++
-- throw that propagates THROUGH pcall and aborts the calling function mid-body. Method only.
function H.set_think_stop(ch, stop)
    if not ch then return false end
    if pcall(function() ch:call("set_IsThinkStop(System.Boolean)", stop == true) end) then return true end
    if pcall(function() ch:call("set_IsThinkStop", stop == true) end) then return true end
    return false
end

-- ⛔ S.froze stores the HANDLES, not just a key. Keying it to S.target_key alone stranded bodies:
-- hold a wild wolf, walk on, the nearest-body target moves to something else, and lab_holds() went
-- false while the wolf stayed FSM-disabled for the rest of the session -- PANIC, unfreeze and even
-- the hold ceiling all acted on the NEW target and could never reach it again.
function H.mark_frozen(what)
    if not (S.froze and S.froze.key == S.target_key) then
        S.froze = { key = S.target_key, ch = S.target, go = S.target_go, t = os.clock() }
    end
    S.froze.ch, S.froze.go = S.target, S.target_go
    S.froze.t = os.clock()
    S.froze[what] = true
end

-- true when the lab is holding ANY body -- not merely the one currently targeted
function H.lab_holds()
    return (S.froze ~= nil and (S.froze.fsm or S.froze.think or S.froze.puppet)) == true
end

-- true when the held body IS the one on screen (drives the UI's orange banner)
function H.holds_target()
    return H.lab_holds() and S.froze.key == S.target_key
end

-- want_fsm: nil/true = enable, false = leave it disabled (restoring a pre-existing park)
function H.thaw(ch, go, want_fsm)
    if go then H.set_fsm(go, want_fsm ~= false); H.set_puppet(go, false) end
    if ch then H.set_think_stop(ch, false) end
end

-- ⛔ ONLY UNDO WHAT WE DID. `FSM enabled: false` does not mean the lab froze it -- IRIS parks
-- companions with MotionFsm2 already off and paints an idle on them (a summoned bat sits like
-- that permanently). Blindly restoring "enabled = true" would un-park a creature another module
-- is deliberately holding. So a freeze records the PREVIOUS state and an automatic release puts
-- that back; only an explicit user action (Unfreeze / PANIC) forces the FSM on.
function H.unfreeze(force)
    local prev = S.froze and S.froze.prev_fsm or nil
    if S.froze then
        pcall(function() H.thaw(S.froze.ch, S.froze.go, force and true or prev) end)
    end
    if force then H.thaw(S.target, S.target_go, true) end
    S.froze = nil
end

function H.restore_reject()
    local st = S.reject
    if not st then return end
    S.reject = nil
    pcall(function()
        local am = H.action_manager(st.ch)
        if am then am:call("set_IsRejectRequestOnDefault(System.Boolean)", st.prev == true) end
    end)
end

function H.panic()
    H.restore_reject()
    H.thaw(S.target, S.target_go)
    pcall(function()
        local m = H.motion_of(S.target)
        if m then m:call("set_PlaySpeed", 1.0) end
    end)
    -- ⛔ the HELD body first and foremost: the target may have drifted off it since we froze it,
    -- and that body is the one actually standing frozen in the world.
    if S.froze then pcall(function() H.thaw(S.froze.ch, S.froze.go) end) end
    -- and the companion too, for the same reason
    pcall(function()
        local cch, cgo = H.companion()
        H.thaw(cch, cgo)
    end)
    -- ⛔ a prep left outstanding would keep the body accepting every default request forever;
    -- put its snapshot back before we forget it, then force everything live.
    if S.node_prep then pcall(function() ND.prep_finish("panic") end) end
    S.node_hold, S.node_exit, S.node_prep = nil, nil, nil
    pcall(function() H.thaw(S.target, S.target_go, true) end)
    H.tape_flush(false, nil, nil)
    S.froze, S.scan, S.verify = nil, nil, nil
    S.arm_ceiling, S.arm_crosstree, S.arm_killed = false, false, false
    C.think_stop = false
    H.status("PANIC: FSM on, think-stop off, puppet off, speed 1.0, prep restored, tape closed, arms cleared")
end

-- ============================================================================================
-- MOTION SIDE
-- ============================================================================================
-- (MO declared at the top with H/ND/UI)

function MO.key(bank, id) return tostring(math.floor(bank)) .. ":" .. tostring(math.floor(id)) end

function MO.witnessed(chid, bank, id)
    local w = S.witness[tostring(chid or "")]
    return type(w) == "table" and w[MO.key(bank, id)] == true
end

-- ⛔ L6: additive poses are valid only as an L1 overlay on a base loop. Painted as a base L0 pose
-- they mangle the body -- the same signature as the eleven-CTD clip-5010 tape. The names say so.
function MO.is_additive(name)
    local n = tostring(name or ""):lower()
    return n:find("add_pose", 1, true) ~= nil or n:find("addpose", 1, true) ~= nil
        or n:find("_add_", 1, true) ~= nil or n:match("_add$") ~= nil
end

function MO.index(clips, chid, label, source)
    local banks, by_bank, by_key, seenb = {}, {}, {}, {}
    for i, e in ipairs(clips or {}) do
        local b, id = math.floor(tonumber(e.bank) or 0), math.floor(tonumber(e.id) or 0)
        if not seenb[b] then seenb[b] = true; banks[#banks + 1] = b; by_bank[b] = {} end
        local k = MO.key(b, id)
        if not by_key[k] then
            by_key[k] = i
            by_bank[b][#by_bank[b] + 1] = id
        end
    end
    table.sort(banks)
    for _, b in ipairs(banks) do table.sort(by_bank[b]) end
    S.cat = { chid = chid, label = label, source = source,
              clips = clips, banks = banks, by_bank = by_bank, by_key = by_key }
    if #banks > 0 and not by_bank[math.floor(tonumber(C.bank) or 0)] then
        C.bank = banks[1]
        local l = by_bank[C.bank]
        C.motion = (l and l[1]) or 0
    end
    return S.cat
end

function MO.clip_at(bank, id)
    if not S.cat then return nil end
    local i = S.cat.by_key[MO.key(bank, id)]
    return i and S.cat.clips[i] or nil
end

-- ── load an already-scanned atlas ---------------------------------------------------------------
-- IrisTaming's deep scan already catalogued 25 creatures into data/IrisTaming_atlas_<chid>.json
-- (the files mirrored in reframework/Animal Atlas/). One click, no rescan, nothing touched.
function MO.load_atlas()
    local chid = H.chid()
    if chid == "unknown" then H.status("no body to load an atlas for"); return false end
    local d, from = nil, nil
    for _, p in ipairs({
        "IrisTaming_atlas_" .. chid .. ".json",
        NODE_DIR .. "/IrisMotions_" .. chid .. ".json",
    }) do
        if not d then pcall(function()
            local x = json.load_file(p)
            if type(x) == "table" and type(x.clips) == "table" and #x.clips > 0 then d = x; from = p end
        end) end
    end
    if not d then
        H.status("no atlas for " .. chid .. " in data/ -- click Rescan once and it will be written")
        return false
    end
    MO.index(d.clips, chid, H.label(), "atlas: " .. tostring(from))
    H.status(string.format("atlas loaded: %d clips in %d banks (%s)", #S.cat.clips, #S.cat.banks, chid))
    return true
end

-- ── live scan ------------------------------------------------------------------------------------
-- Pure queries. getMotionInfo/getMotionInfoByIndex never touch the body: the creature does not so
-- much as blink while this runs, and it is safe on a paused game.
function MO.scan_start()
    local m = S.target and H.motion_of(S.target)
    if not m then H.status("no via.motion.Motion on the target"); return false end
    local banks, have = {}, {}
    for b = 0, 300 do
        local cnt = 0
        pcall(function() cnt = tonumber(m:call("getMotionCount", b)) or 0 end)
        if cnt > 0 and not have[b] then have[b] = true; banks[#banks + 1] = b end
    end
    -- second opinion: the bank-object enumeration occasionally lists a bank getMotionCount misses
    pcall(function()
        for _, pair in ipairs({ { "getActiveMotionBankCount", "getActiveMotionBank" },
                                { "getMotionBankCount", "getMotionBank" } }) do
            local n = H.sc(m, pair[1]) or 0
            for i = 0, math.min((tonumber(n) or 0) - 1, 256) do
                local bo = H.sc(m, pair[2], i)
                local bid = bo and H.sc(bo, "get_BankID")
                if type(bid) == "number" and not have[bid] then
                    have[bid] = true; banks[#banks + 1] = math.floor(bid)
                end
            end
        end
    end)
    table.sort(banks)
    if #banks == 0 then H.status("that body reports no motion banks"); return false end

    S.scan = { key = S.target_key, banks = banks, bi = 1, phase = "enum", i = 0,
               found = {}, seen = {},
               minfo = ValueType.new(sdk.find_type_definition("via.motion.MotionInfo")) }
    H.status(string.format("SCAN: %d banks queued", #banks))
    return true
end

function MO.scan_tick()
    local sc = S.scan
    if not sc then return end
    if sc.key ~= S.target_key then S.scan = nil; return end
    local m = S.target and H.motion_of(S.target)
    if not m then S.scan = nil; H.status("SCAN aborted -- body went away"); return end

    local budget, used = math.max(50, math.floor(tonumber(C.scan_budget) or 400)), 0

    local function record(bank, mid, mname, ef)
        local k = MO.key(bank, mid)
        if sc.seen[k] then return end
        sc.seen[k] = true
        sc.found[#sc.found + 1] = { bank = math.floor(bank), id = math.floor(mid),
            name = tostring(mname or "?"), endframe = math.floor(tonumber(ef) or 0) }
    end

    while used < budget do
        if sc.phase == "enum" then
            local bank = sc.banks[sc.bi]
            if not bank then
                sc.phase = (C.deep_bank0 == true) and "sweep0" or "done"
                sc.i = 0
            else
                local cnt = 0
                pcall(function() cnt = tonumber(m:call("getMotionCount", bank)) or 0 end)
                if sc.i >= cnt then
                    sc.bi = sc.bi + 1; sc.i = 0
                else
                    local okx = pcall(function()
                        m:call("getMotionInfoByIndex(System.UInt32, System.UInt32, via.motion.MotionInfo)",
                            bank, sc.i, sc.minfo)
                    end)
                    if okx then
                        local mid, mn, ef = nil, nil, nil
                        pcall(function() mid = sc.minfo:get_MotionID() end)
                        pcall(function() mn = sc.minfo:get_MotionName() end)
                        pcall(function() ef = sc.minfo:call("get_MotionEndFrame") end)
                        if tonumber(mid) then record(bank, tonumber(mid), mn, ef) end
                    end
                    sc.i = sc.i + 1; used = used + 1
                end
            end

        elseif sc.phase == "sweep0" then
            -- ⭐ bank 0 ONLY. Index enumeration under-reports it (IrisTaming saw 0:100 play while
            -- the catalogue denied it existed). getMotionInfo returns TRUE only for a real clip.
            -- ⛔ Never sweep any OTHER bank this way -- hammering invalid params on a live body is
            -- what made the original lab unstable.
            local maxid = math.floor(tonumber(C.deep_bank0_max) or 8000)
            if sc.i > maxid then
                sc.phase = "done"
            else
                local id = sc.i
                pcall(function()
                    local ok = m:call("getMotionInfo(System.UInt32, System.UInt32, via.motion.MotionInfo)",
                        0, id, sc.minfo)
                    if ok == true then
                        local mn, ef = nil, nil
                        pcall(function() mn = sc.minfo:get_MotionName() end)
                        pcall(function() ef = sc.minfo:call("get_MotionEndFrame") end)
                        record(0, id, mn, ef)
                    end
                end)
                sc.i = id + 1; used = used + 1
            end

        else
            local chid = H.chid()
            table.sort(sc.found, function(a, b)
                if a.bank ~= b.bank then return a.bank < b.bank end
                return a.id < b.id
            end)
            MO.index(sc.found, chid, H.label(), "live scan")
            local id = H.identity()
            local payload = {
                target = id and id.raw or nil,          -- IrisTaming's key, kept for compatibility
                chid = chid, species = id and id.species or nil, body = id and id.raw or nil,
                banks = sc.banks, count = #sc.found, clips = sc.found,
            }
            -- the lab's own record, always written
            pcall(function() json.dump_file(NODE_DIR .. "/IrisMotions_" .. chid .. ".json", payload) end)

            -- ⭐ AND feed the SHARED library. data/IrisTaming_atlas_<chid>.json is the file the
            -- Animal Atlas folder is mirrored from, and the whole "grep the atlas by NAME, never
            -- guess an id" workflow reads it. A scan that only wrote somewhere else would leave
            -- that pipeline stale. ⛔ NEVER REGRESS IT: only overwrite when this scan found MORE
            -- clips than the file already holds, so a partial read can never destroy a good atlas.
            local shared, prev = "IrisTaming_atlas_" .. chid .. ".json", 0
            pcall(function()
                local old = json.load_file(shared)
                if type(old) == "table" and type(old.clips) == "table" then prev = #old.clips end
            end)
            local wrote_shared = false
            if #sc.found > prev then
                pcall(function() json.dump_file(shared, payload); wrote_shared = true end)
            end
            H.status(string.format("SCAN done: %d clips in %d banks -> browser + data/%s/IrisMotions_%s.json%s",
                #sc.found, #S.cat.banks, NODE_DIR, chid,
                wrote_shared and (" + data/" .. shared .. " (was " .. prev .. " clips)")
                             or (prev > 0 and (" (kept the existing " .. prev .. "-clip atlas -- it is not smaller)") or "")))
            S.scan = nil
            return
        end
    end
end

-- ── stepping (empty ids cannot appear: the lists ARE the enumerated ids) --------------------------
function MO.step_in(list, value, dir)
    if not list or #list == 0 then return value end
    if dir > 0 then
        for _, v in ipairs(list) do if v > value then return v end end
        return list[#list]
    end
    for i = #list, 1, -1 do if list[i] < value then return list[i] end end
    return list[1]
end

function MO.step(list, value, n)
    local v, dir = value, (n > 0 and 1 or -1)
    for _ = 1, math.abs(n) do v = MO.step_in(list, v, dir) end
    return v
end

function MO.pos(list, value)
    if not list then return 0, 0 end
    for i, v in ipairs(list) do if v == value then return i, #list end end
    return 0, #list
end

-- ── the residency verdict, shown in the UI and enforced in play() ---------------------------------
-- ⛔ These are INDEPENDENT flags, not a priority chain. An earlier draft returned one "kind" and
-- the caller tested it with elseif -- so an additive clip that was ALSO an unwitnessed high id
-- reported only "additive", and moving it to layer 1 slipped it past the residency gate entirely.
-- Every hazard a clip carries has to be answered on its own.
-- ⛔⛔ THE CEILING IS A BANK-0 RULE, NOT A GLOBAL ONE. Applying it to every bank was my mistake and
-- it made the tool useless on ordinary creatures: a tamed bat's whole library is 28 clips across 6
-- banks, and bank 10's `ch99_400_dmg_blown_start_F` (a damage reaction, id 500) got refused as if
-- it were griffin flight data.
--
-- What the evidence actually says:
--   * Every documented streamed-clip AV is in BANK 0 -- the `com_` family on the big fliers
--     (griffin 5000/5030-5032/5100/5101/5210, drake 5100/5101). Bank 0 is where a creature's base
--     locomotion AND its streamed flight families both live, which is exactly why it is dangerous.
--   * Clips in other banks that need node context (bank 50 attacks) are documented to T-POSE when
--     played raw -- ugly, recoverable, NOT a crash. That deserves a warning, never a refusal.
-- So: refuse in bank 0 above the ceiling; warn elsewhere. `ceiling_bank0_only = false` restores
-- the old paranoid behaviour for a species you do not trust yet.
function MO.flags(bank, id)
    local chid = H.chid()
    local e = MO.clip_at(bank, id)
    local over = id >= math.floor(tonumber(C.safe_ceiling) or 400)
    local bank0 = (math.floor(bank) == 0)
    return {
        killed    = H.is_killed(chid, "clip " .. MO.key(bank, id)),
        additive  = (e ~= nil) and MO.is_additive(e.name) or false,
        witnessed = MO.witnessed(chid, bank, id),
        -- hot = actually refused; warn = advisory only
        hot       = over and (bank0 or C.ceiling_bank0_only == false),
        warn      = over and not bank0 and C.ceiling_bank0_only ~= false,
    }
end

-- flags, plus the single worst headline for the UI
function MO.verdict(bank, id)
    local f = MO.flags(bank, id)
    if f.killed then
        return f, "killed", "☠ this clip crashed the game before (crash tape). Refused."
    end
    if f.additive then
        return f, "additive", "⚠ ADDITIVE pose -- valid only layered on L1 over a base loop. "
            .. "As a base L0 clip it mangles the body (the clip-5010 signature)."
    end
    if f.hot and not f.witnessed then
        return f, "hot", "⛔ BANK 0, id >= the ceiling, never witnessed. Bank 0 holds the STREAMED "
            .. "families (griffin/drake flight): painting one cold is the uncatchable null AV. Let "
            .. "the creature play it once -- it turns ✅ the moment it does -- or tick the ⛔ ARM."
    end
    if f.witnessed then
        return f, "witnessed", "✅ witnessed resident -- this clip has genuinely run on this body, always safe"
    end
    if f.warn and not f.witnessed then
        return f, "warn", "⚠ high id outside bank 0. Clips that need node context (bank-50 attacks "
            .. "and friends) T-POSE when played raw -- ugly and recoverable, not a crash. Allowed."
    end
    return f, "ok", "(resident family -- normally safe)"
end

-- ============================================================================================
-- PLAY
-- ============================================================================================
function MO.play()
    -- unsafe mode can fire a raw bank:id with nothing scanned at all -- typing an id straight into
    -- the drag boxes and firing it is a legitimate probe when the enumeration is the thing you
    -- distrust.
    if not S.cat and not H.unsafe() then
        H.status("REFUSED: load or scan the motion library first -- an unverified id can hard-crash")
        return false
    end
    local bank = math.floor(tonumber(C.bank) or 0)
    local id   = math.floor(tonumber(C.motion) or 0)
    local lay  = math.floor(tonumber(C.layer) or 0)

    -- Normally only ids the enumerator returned may reach changeMotion. In UNSAFE mode an
    -- off-catalogue id is allowed on purpose: the enumeration is known to UNDER-report (IrisTaming
    -- saw 0:100 play while the catalogue denied it existed), so "try an id the scan missed" is a
    -- real experiment, not a mistake.
    if not (S.cat and S.cat.by_key[MO.key(bank, id)]) then
        if not H.unsafe() then
            H.status(string.format("REFUSED %s: not in this body's catalogue. Step with +/- or rescan.",
                MO.key(bank, id)))
            return false
        end
        H.status("⛔ UNSAFE: " .. MO.key(bank, id) .. " is not in the catalogue -- firing blind")
    end
    local claim = C.guard_claimed ~= false and H.blocking_claim(S.target_go) or nil
    if claim then
        if not H.unsafe() then
            H.status("REFUSED: this body is " .. claim .. ". Two puppeteers on one body is a crash.")
            return false
        end
        H.status("⛔ UNSAFE: body is " .. claim .. " -- firing anyway")
    end

    local ch, go = S.target, S.target_go
    -- ⛔ ARM-INTEGRITY: resolve everything that can still fail BEFORE any guard consumes a one-shot
    -- arm. Otherwise ticking ⛔ ARM, then bouncing off a missing layer, silently eats the arm and
    -- the next click is refused again for no visible reason.
    local layer = H.layer_of(ch, lay)
    if not layer then H.status("no motion layer " .. lay .. " on this body"); return false end

    -- Every hazard answered independently (see MO.flags), and ⛔ NO ARM IS SPENT UNTIL THEY ALL
    -- PASS. Spending inside a gate meant a clip that is BOTH killed and unwitnessed-high ate the
    -- ☠ arm on the first gate and was then refused by the second -- so the tick silently cleared
    -- itself and the user could never get through, however many times they re-ticked it.
    local f, _, msg = MO.verdict(bank, id)
    local need = {}
    -- ☠ THE KILLED LIST SURVIVES UNSAFE MODE. Everything else here is a prediction; this is a
    -- recorded fact -- this exact clip already took the game down. Overriding it needs the ☠ ARM.
    if f.killed and C.guard_killed ~= false then
        if not S.arm_killed then H.status("REFUSED " .. MO.key(bank, id) .. ": " .. msg); return false end
        need.killed = true
    end
    if f.additive and C.guard_additive ~= false and lay == 0 then
        if not H.unsafe() then
            H.status("REFUSED " .. MO.key(bank, id) .. ": ⚠ ADDITIVE pose on layer 0 mangles the body. "
                .. "Set layer = 1 to try it as an overlay over a base loop.")
            return false
        end
        H.status("⛔ UNSAFE: " .. MO.key(bank, id) .. " is an additive pose on L0 -- firing anyway")
    end
    if f.hot and not f.witnessed and C.guard_ceiling ~= false then
        if not (S.arm_ceiling or H.unsafe()) then
            H.status("⛔ REFUSED " .. MO.key(bank, id) .. ": " .. msg .. "  (or tick the ⛔ ARM to override once)")
            return false
        end
        if S.arm_ceiling then need.ceiling = true end
    end
    -- every gate passed: spend exactly the arms that were needed
    if need.killed then S.arm_killed = false end
    if need.ceiling then
        S.arm_ceiling = false
        H.status("⛔ ARM CONSUMED -- firing unwitnessed " .. MO.key(bank, id))
    end

    -- ⛔ L4: a think-STOPPED body playing a streamed clip is a native AV. Never think-stop for a
    -- high id, whatever the checkbox says.
    -- unsafe mode honours the checkbox even for high ids (think-stop + streamed clip is the
    -- documented native AV -- which is exactly the thing being tested)
    local want_think = (C.think_stop == true)
        and (H.unsafe() or id < math.floor(tonumber(C.safe_ceiling) or 400))
    H.set_think_stop(ch, want_think)
    if want_think then H.mark_frozen("think") end

    -- ⛔ L3: think-stop alone leaves the FSM owning layer 0 and the clip never shows. Disabling
    -- via.motion.MotionFsm2 is what actually hands layer 0 to us -- and it must happen BEFORE the
    -- write, or the FSM overwrites us on the same frame.
    if C.hold_mode == true then
        -- capture what the FSM was BEFORE we touch it, so releasing restores that and not "on"
        local prev = H.fsm_enabled(go)
        -- only claim the hold if the disable actually landed, or the UI lies and the hold ceiling
        -- later "thaws" a body that was never held (stomping a think-stop we do want)
        if H.set_fsm(go, false) then
            H.mark_frozen("fsm")
            if S.froze.prev_fsm == nil then S.froze.prev_fsm = prev end
        end
    else
        -- flash mode: hand layer 0 back to the FSM -- but ONLY if we were the one holding it.
        -- Forcing set_Enabled(true) here would wake a companion that IrisTaming has parked.
        if H.holds_target() then H.unfreeze(false) end
    end

    -- ⭐ the tape: an ok=true from pcall proves nothing (L2), so the record goes to DISK first.
    H.tape_open("clip " .. MO.key(bank, id), H.chid())

    local ok = pcall(function()
        layer:call(
            "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
            bank, id, 0.0, (tonumber(C.blend_frames) or 8.0) + 0.0, 1, 1)
    end)

    S.last_play = { key = MO.key(bank, id), frame = S.frame }
    S.verify = { bank = bank, id = id, layer = lay, frames = 0, key = S.target_key }
    local e = MO.clip_at(bank, id)
    H.status(string.format("play %s  %s  L%d  %s  ok=%s", MO.key(bank, id), (e and e.name) or "?",
        lay, C.hold_mode and "HOLD" or "flash", tostring(ok)))
    return ok
end

-- Read-back: a couple of frames later, does the layer actually hold our clip? This is the honest
-- answer to "why did nothing happen", and a clip that DID land is proof its data was resident --
-- so it joins the witness ledger and is safe forever after.
function MO.verify_tick()
    local v = S.verify
    if not v then return end
    if v.key ~= S.target_key then S.verify = nil; return end
    v.frames = v.frames + 1
    if v.frames < 3 then return end

    local layer = H.layer_of(S.target, v.layer)
    local mb  = layer and H.sc(layer, "get_MotionBankID")
    local mid = layer and H.sc(layer, "get_MotionID")
    local took = (math.floor(tonumber(mb) or -1) == v.bank) and (math.floor(tonumber(mid) or -1) == v.id)

    if took then
        local chid = H.chid()
        S.witness[chid] = S.witness[chid] or {}
        if not S.witness[chid][MO.key(v.bank, v.id)] then
            S.witness[chid][MO.key(v.bank, v.id)] = true
            S.witness_dirty = true
            H.status(string.format("%s landed -- ✅ now witnessed resident on %s", MO.key(v.bank, v.id), chid))
        end
    else
        H.status(string.format("%s did not take -- L%d now reads %s:%s. In flash mode that is just "
            .. "the FSM reclaiming the layer; in HOLD mode it means the clip is not resident.",
            MO.key(v.bank, v.id), v.layer, tostring(mb), tostring(mid)))
    end
    S.verify = nil
end

-- ⭐ the ledger grows by itself: any clip genuinely RUNNING on the body proves its .mot data is
-- resident (a non-resident clip does not fail quietly -- it AVs), so it is safe to paint forever.
--
-- ⛔ This used to bail whenever the FSM was disabled, reasoning "frozen, so whatever shows is our
-- own paint". That was wrong for the creatures this tool is actually for: IRIS parks companions
-- with MotionFsm2 OFF and paints an idle on them, so a summoned bat sits there visibly running
-- 0:5000 while the ledger recorded NOTHING -- and every bank-0 clip stayed permanently "hot".
-- The real question is not "is the FSM off?" but "did WE paint this?", which the `ours` check
-- below already answers, plus the explicit "we are holding this body" case.
function MO.witness_tick()
    local ch, go = S.target, S.target_go
    if not (ch and go) then return end
    if H.holds_target() then return end               -- WE are holding it: the layer is our paint
    local chid = H.chid()
    if chid == "unknown" then return end
    for li = 0, 1 do
        local layer = H.layer_of(ch, li)
        if layer then
            local mb, mid = H.sc(layer, "get_MotionBankID"), H.sc(layer, "get_MotionID")
            local ef = tonumber(H.sc(layer, "get_EndFrame")) or 0
            -- ⛔ 0xFFFFFFFF is the layer's "no motion" sentinel (it reads as 4294967295 with
            -- frame 0/0) -- recording it would put a clip that does not exist into the safe-list.
            -- Requiring a real EndFrame is also the honest proof: a clip with frames is a clip
            -- whose data is actually loaded.
            if type(mb) == "number" and type(mid) == "number"
                and mid ~= 4294967295 and mb ~= 4294967295 and ef > 0 then
                local k = MO.key(mb, mid)
                local ours = S.last_play and S.last_play.key == k and (S.frame - S.last_play.frame) < 180
                if not ours then
                    S.witness[chid] = S.witness[chid] or {}
                    if not S.witness[chid][k] then S.witness[chid][k] = true; S.witness_dirty = true end
                end
            end
        end
    end
end

-- ============================================================================================
-- NODE SIDE
-- ============================================================================================
-- (ND declared at the top with H/MO/UI)

function ND.blocked(name)
    for pat in tostring(C.node_blocklist or ""):gmatch("[^,%s]+") do
        if tostring(name or ""):find(pat, 1, true) then return true, pat end
    end
    return false
end

function ND.family(name) return tostring(name or ""):match("^([^%.]+)") or "" end
function ND.leaf(name)   return tostring(name or ""):match("([^%.]+)$") or tostring(name or "") end

function ND.current(tree)
    local fsm = H.fsm_of(S.target_go)
    if not fsm then return nil end
    local n = H.sc(fsm, "getCurrentNodeName", math.floor(tonumber(tree) or 0))
    if n == nil then return nil end
    n = tostring(n)
    return (n ~= "") and n or nil
end

-- ── enumeration -----------------------------------------------------------------------------------
-- The exact walk the griffin probe's typo-guard uses: MotionFsm2 -> getLayer(tree) ->
-- get_tree_object() -> get_nodes() -> get_full_name(). It is NOT griffin-specific -- ANY body with a
-- via.motion.MotionFsm2 answers, which is why a summoned creature needs no "pull from an enemy"
-- fallback. (The nearest-body probe below still exists, for creatures you cannot tame yet.)
-- The griffin only ever read tree 0; we read 0-3, because setCurrentNode takes a tree index and
-- firing into the wrong family is precisely the crash we are guarding against.
function ND.enumerate(go)
    local fsm = H.fsm_of(go)
    if not fsm then return nil, "no via.motion.MotionFsm2 on that body" end
    local list, set, trees = {}, {}, {}
    for tree = 0, 3 do
        local n_this = 0
        pcall(function()
            local layer = fsm:call("getLayer", tree)
            local tobj = layer and layer:get_tree_object()
            local nodes = tobj and tobj:get_nodes()
            for i, nd in ipairs(nodes or {}) do
                if i > 3000 then break end
                local nm = nil
                pcall(function() nm = nd:get_full_name() end)
                if not nm then pcall(function() nm = nd:get_name() end) end
                nm = nm and tostring(nm) or nil
                if nm and nm ~= "" and set[nm] == nil then
                    set[nm] = tree
                    list[#list + 1] = { name = nm, tree = tree }
                    n_this = n_this + 1
                end
            end
        end)
        if n_this > 0 then trees[#trees + 1] = tree end
    end
    -- ⛔ FAIL CLOSED. The griffin's own guard returns TRUE on a zero-node read, which would wave
    -- every typo straight into setCurrentNode. A zero read here is an error, never a permit.
    if #list == 0 then return nil, "the FSM answered 0 nodes (body not streamed in yet?)" end
    table.sort(list, function(a, b) return a.name < b.name end)
    return { list = list, set = set, trees = trees }, nil
end

function ND.scan(go, source)
    go = go or S.target_go
    if not go then H.status("no body to read a node tree from"); return false end
    local cat, err = ND.enumerate(go)
    if not cat then H.status("node scan failed: " .. tostring(err)); return false end
    cat.chid    = H.go_name(go):match("ch%d+") or H.chid()
    cat.species = H.species_name(go)
    cat.body    = H.go_name(go)
    cat.source  = source or "live"
    -- ⛔⛔ OWNERSHIP STAMP. The node set is the ONLY thing the typo guard validates against, so it
    -- must carry the identity of the body it was read from. Without this, "probe NEAREST body"
    -- silently replaced the target's tree with a wild creature's, and the guard -- which only asked
    -- "is this name in the set?" -- then waved a foreign node straight into the target's
    -- setCurrentNode. That is the exact uncatchable native AV the guard exists to prevent, and the
    -- cross-tree gate could not catch it either (it compares FAMILY strings, and Locomotion.* is
    -- common to every creature). Every other cache in this file is target-keyed; this one was not.
    cat.key = (H.addr(go) ~= nil) and (tostring(H.addr(go)) .. "|" .. H.go_name(go)) or nil
    S.nodes = cat
    S.node_pick = 1
    H.status(string.format("node tree: %d nodes across tree(s) %s  (%s)",
        #cat.list, table.concat(cat.trees, ","), tostring(cat.chid)))
    return true
end

-- ── node atlas io -----------------------------------------------------------------------------------
function ND.atlas_path(chid, species)
    local sp = tostring(species or ""):gsub("[^%w]", "")
    local base = "IrisNodes_" .. tostring(chid or "unknown")
    if sp ~= "" then base = base .. "_" .. sp end
    return NODE_DIR .. "/" .. base .. ".json"
end

function ND.save_atlas()
    local cat = S.nodes
    if not (cat and cat.list and #cat.list > 0) then H.status("nothing to save -- scan a tree first"); return false end
    local path = ND.atlas_path(cat.chid, cat.species)
    local ok = pcall(function()
        json.dump_file(path, { chid = cat.chid, species = cat.species, body = cat.body,
            trees = cat.trees, count = #cat.list, nodes = cat.list })
    end)
    H.status(ok and ("node atlas saved: data/" .. path .. "  (" .. #cat.list .. " nodes)")
                or ("node atlas SAVE FAILED: " .. path))
    return ok
end

function ND.load_atlas()
    local id = H.identity()
    local chid = id and id.chid or nil
    local d, from = nil, nil
    if chid then
        for _, sp in ipairs({ (id and id.species) or "", "" }) do
            if not d then pcall(function()
                local p = ND.atlas_path(chid, sp)
                local x = json.load_file(p)
                if type(x) == "table" and type(x.nodes) == "table" and #x.nodes > 0 then d = x; from = p end
            end) end
        end
    end
    if not d then
        pcall(function()
            -- ⛔ fs.glob takes a std::regex, NOT a Lua pattern: the escape is \. and never %.
            -- ('%.json' would search for a literal percent sign and silently match nothing.)
            local paths = fs.glob(NODE_DIR .. [[[\\/].*\.json]])
            for _, p in ipairs(paths or {}) do
                local ps = tostring(p)
                if not d and ps:find("IrisNodes_", 1, true) and (not chid or ps:find(chid, 1, true)) then
                    local x = json.load_file(ps)
                    if type(x) == "table" and type(x.nodes) == "table" and #x.nodes > 0 then d = x; from = ps end
                end
            end
        end)
    end
    if not d then H.status("no node atlas for " .. tostring(chid) .. " in data/" .. NODE_DIR); return false end

    local set = {}
    for _, e in ipairs(d.nodes) do set[tostring(e.name)] = math.floor(tonumber(e.tree) or 0) end
    S.nodes = { list = d.nodes, set = set, trees = d.trees or { 0 },
                chid = d.chid, species = d.species, body = d.body, source = "atlas file" }
    S.node_pick = 1
    H.status(string.format("node atlas loaded: %d nodes from %s", #d.nodes, tostring(from)))
    return true
end

-- ⭐ the probe: point at ANY body (a wild drake, a boss you cannot tame yet), read its tree, bank it
-- to the atlas folder by ch id + species. Purely a read -- it cannot disturb the creature.
function ND.probe_nearest()
    local _, go = H.nearest_creature()
    if not go then
        H.status(S.broken_scan > 0
            and ("*** BROKEN SCAN -- " .. S.broken_scan .. " components in scene, NONE readable. Draw no conclusion.")
            or "no ch### body within 40m")
        return false
    end
    if not ND.scan(go, "probe: " .. H.go_name(go)) then return false end
    return ND.save_atlas()
end

-- ── firing --------------------------------------------------------------------------------------------
-- Is the loaded node set actually the TARGET's tree? Returns nil when it is, or a refusal string.
function ND.owns_target()
    if not (S.nodes and S.nodes.set) then
        return "REFUSED: no node tree loaded. Click 'Rescan node tree'."
    end
    -- an atlas file loaded from disk has no live key; the ch id is the only identity it carries
    if S.nodes.key ~= nil then
        if S.nodes.key ~= S.target_key then
            return "⛔ REFUSED: the loaded node tree is " .. tostring(S.nodes.body)
                .. ", NOT the target (" .. tostring(H.chid()) .. "). That is a foreign node name going "
                .. "into this body's FSM = native crash. Click 'Rescan node tree'."
        end
    elseif tostring(S.nodes.chid or "") ~= H.chid() then
        return "⛔ REFUSED: the loaded node atlas is for " .. tostring(S.nodes.chid)
            .. " but the target is " .. H.chid() .. ". Rescan the target's tree."
    end
    return nil
end

-- ⛔ ARM-INTEGRITY: this returns (refusal, arms_needed). It NEVER consumes an arm -- the caller
-- consumes them only once every gate has passed. Consuming inside a gate meant an arm ticked for
-- gate A was silently eaten when gate B refused, and the user re-ticked forever with no clue that
-- two arms were required.
function ND.guard(name, tree)
    local need = {}
    -- ⛔⛔⛔ UNSAFE MODE: everything below still WARNS (the panel keeps its ⛔ markers and the status
    -- line names the hazard), but nothing is refused except the ☠ KILLED list. Firing a foreign or
    -- unknown node name IS a legitimate experiment here -- "can a bat run a griffin's move?" is a
    -- question, and the crash tape is what answers it.
    local warn = {}

    local claim = C.guard_claimed ~= false and H.blocking_claim(S.target_go) or nil
    if claim then
        if not H.unsafe() then
            return "REFUSED: this body is " .. claim .. ". Two puppeteers on one body is a crash."
        end
        warn[#warn + 1] = "body is " .. claim
    end

    -- the tree must belong to the body we are about to fire on (see the ownership stamp)
    local foreign = ND.owns_target()
    if foreign then
        if not H.unsafe() then return foreign end
        warn[#warn + 1] = "node set is not this body's"
    end

    -- ☠ recorded fact, not a prediction: this survives unsafe mode and needs the ☠ ARM.
    if H.is_killed(H.chid(), "node " .. name) and C.guard_killed ~= false then
        if not S.arm_killed then return "☠ REFUSED: this node crashed the game before (crash tape)." end
        need.killed = true
    end

    -- L7 TYPO GUARD: an unknown name in setCurrentNode is a native crash.
    if not (S.nodes and S.nodes.set and S.nodes.set[name] ~= nil) then
        if not H.unsafe() then
            return "REFUSED: '" .. tostring(name) .. "' is not in this body's node set. Rescan the tree."
        end
        warn[#warn + 1] = "'" .. tostring(name) .. "' is not in this body's tree"
    end

    -- ⛔⛔ L8 CROSS-TREE GATE -- but it is a **setCurrentNode** concern, not a universal one.
    --
    -- requestAction/requestActionCore take only the LEAF name and a layer; there is no tree index
    -- in the call at all. They go through the action machinery the creature's own AI uses, which
    -- VALIDATES the transition and simply refuses an impossible one -- a no-op, not a crash.
    -- setCurrentNode is the raw slam: no validation, and documented to T-pose/AV on an air node.
    --
    -- And the crash tape is explicit that the door was never the differentiator: firing
    -- Fly.Hovering.* cold did NOT crash via either request door -- "the sole crash trigger is our
    -- transform MOVEMENT drive running while the node is active". This lab has no transform drive.
    --
    -- So: hard-refuse a cross-tree setCurrentNode; WARN on a cross-tree request and let it through.
    -- Refusing both made the node library unusable on a parked creature (a tamed bat sits in
    -- Locomotion.Wait, so every one of its 39 Fly.* nodes was unreachable).
    -- crosstree_blocks_requests = true restores the old strict behaviour.
    local hard = ((tostring(C.node_fire_mode or "") == "setCurrentNode")
        or (C.crosstree_blocks_requests == true)) and not H.unsafe()
    if C.guard_crosstree == true and hard then
        -- ⛔ FAIL CLOSED. This used to read `ND.current(tree) or ND.current(0)` and then only act
        -- `if have` -- so when the FSM answered nothing (a body that just streamed in, or trees 1-3,
        -- which usually have no current node) the whole gate silently evaporated and a cross-tree
        -- fire went through un-armed AND unlogged. An unreadable state is not a permit.
        -- The tree-0 fallback is gone too: comparing tree 3's target against tree 0's current node
        -- is not a cross-tree check, it is a coincidence.
        local cur = ND.current(tree)
        local want = ND.family(name)
        if cur == nil then
            if not S.arm_crosstree then
                return "⛔ REFUSED: cannot read the body's current node on tree " .. tostring(tree)
                    .. ", so a cross-tree fire cannot be ruled out -- and that shape is every logged "
                    .. "node CTD. Let the creature settle, or tick the ⛔ cross-tree ARM."
            end
            need.crosstree = true
        else
            local have = ND.family(cur)
            if want ~= "" and have ~= "" and want ~= have then
                if not S.arm_crosstree then
                    return string.format("⛔ REFUSED: cross-tree %s.* -> %s.* via %s. Every logged node "
                        .. "CTD was this exact shape. Use requestAction instead (it validates the "
                        .. "transition itself), get the body into %s.* first, or tick the ⛔ ARM.",
                        have, want, tostring(C.node_fire_mode), want)
                end
                need.crosstree = true
            end
        end
    end
    if #warn > 0 then
        H.status("⛔ UNSAFE, firing anyway -- " .. table.concat(warn, "; "))
    end
    return nil, need
end

-- ============================================================================================
-- ⭐⭐ PREP / RESTORE -- the griffin's node recipe, ported
-- ============================================================================================
-- Straight from `route3_rise_start_clip` and `griffin_node_exit_pump`. The lessons that matter:
--
--  PREP  * "an idle companion sits under pacify's FSM puppet where nothing can play" -- so
--          set_PuppetMode(false) FIRST or the node cannot run at all.
--        * a node needs a LIVE FSM and a LIVE brain: FSM enabled, think-stop off.
--        * ⛔ `IsRejectRequestOnDefault` -- "a running action refuses both new requests and being
--          aborted until this is cleared. Documented, and I ignored it."
--        * ⛔ ONE OWNER: the node owns the animation, so nothing may paint a clip over it.
--
--  FIRE  * the rise path fires the leaf on **layer 4 then layer 0**, in that order. A single
--          layer-0 request is what "does nothing" on a body whose action slots are busy.
--
--  RESTORE * one request is NOT enough -- taped proof a single requestAction bounced straight off
--          a running LoopTheLoop. Re-request EVERY tick until the FSM genuinely SHOWS the node,
--          with a ceiling so a wedged pump can never freeze the tool.
--        * ⛔ SUCCESS = the body IS in the target node, not merely "left the one we fired".
--        * then put every flag back, and never leave it accepting every default request.
function ND.prep()
    local ch, go = S.target, S.target_go
    if not (ch and go) then return nil end
    local p = { key = S.target_key, ch = ch, go = go, t = os.clock() }

    -- snapshot EVERYTHING we are about to disturb, so restore is exact and not a guess
    p.fsm_enabled = H.fsm_enabled(go)
    local f = H.fsm_of(go)
    p.puppet = H.sc(f, "get_PuppetMode")           -- nil if this build has no getter: then we skip it
    p.from = {}
    for t = 0, 3 do p.from[t] = ND.current(t) end
    local am = H.action_manager(ch)
    if am then p.reject = H.sc(am, "get_IsRejectRequestOnDefault") end

    if C.node_prep ~= false then
        H.set_puppet(go, false)          -- pacify's puppet is where nothing can play
        H.set_fsm(go, true)              -- a node needs a live FSM
        H.set_think_stop(ch, false)      -- ...and a live brain to run it
        if am and C.node_clear_reject ~= false then
            pcall(function() am:call("set_IsRejectRequestOnDefault(System.Boolean)", false) end)
        end
    end
    S.node_prep = p
    return p
end

-- Put every snapshotted flag back. Called once the exit pump finishes (or gives up).
function ND.prep_finish(note)
    local p = S.node_prep
    S.node_prep, S.node_exit = nil, nil
    if not p then return end
    pcall(function()
        local am = H.action_manager(p.ch)
        -- ⛔ never leave the body accepting every default request
        if am and p.reject ~= nil then
            am:call("set_IsRejectRequestOnDefault(System.Boolean)", p.reject == true)
        end
    end)
    pcall(function() H.set_think_stop(p.ch, false) end)
    pcall(function() if p.puppet ~= nil then H.set_puppet(p.go, p.puppet == true) end end)
    -- ⭐ the FSM goes back to how we FOUND it -- a parked companion stays parked
    pcall(function() H.set_fsm(p.go, p.fsm_enabled ~= false) end)
    S.reject = nil
    H.status("node RESTORE done -- " .. tostring(note or "flags back to their pre-fire state"))
end

-- The exit pump: request the body back into the node it was in before we touched it, re-trying
-- every tick until the FSM actually shows it, then restore the flags.
function ND.restore(reason)
    S.node_hold = nil
    local p = S.node_prep
    if not p then
        H.thaw(S.target, S.target_go)
        H.status("nothing to restore (no prep recorded) -- body handed back")
        return false
    end
    local want = p.from and p.from[0] or nil
    if not want or want == "" then
        ND.prep_finish("no pre-fire node recorded; flags restored")
        return true
    end
    S.node_exit = { key = p.key, want = want, leaf = ND.leaf(want), tries = 0,
                    until_t = os.clock() + math.max(0.3, tonumber(C.node_restore_secs) or 1.5),
                    next_t = 0.0 }
    H.status("restoring -> " .. tostring(want) .. " (" .. tostring(reason or "manual") .. ")")
    return true
end

function ND.exit_tick()
    local e = S.node_exit
    if not e then return end
    if e.key ~= S.target_key then ND.prep_finish("target changed"); return end

    local live = ND.current(0)
    -- ⛔ SUCCESS = the body IS in the wanted node, never merely "left the fired one"
    if live and e.leaf ~= "" and tostring(live):find(e.leaf, 1, true) then
        ND.prep_finish(string.format("back in %s after %d request%s",
            tostring(live), e.tries, e.tries == 1 and "" or "s"))
        return
    end
    local now = os.clock()
    if now > e.until_t then
        ND.prep_finish(string.format("gave up after %d requests -- tree 0 reads %s (wanted %s)",
            e.tries, tostring(live or "(none)"), tostring(e.want)))
        return
    end
    if now >= e.next_t then
        e.tries = e.tries + 1
        e.next_t = now + math.max(0.03, tonumber(C.node_restore_gap) or 0.10)
        pcall(function() ND.dispatch(e.want, 0, "requestAction", 0) end)
    end
end

-- The raw call, with no guards and no bookkeeping -- so the re-assert can repeat it without
-- re-running gates or re-opening the crash tape. Returns ok, how.
function ND.dispatch(name, tree, mode, layer)
    local ch = S.target
    if mode == "setCurrentNode" then
        -- ⛔ the blunt door: sets the raw FSM node, which the AI reverts -- documented to T-pose on
        -- air nodes. Never the default; exposed because it is sometimes the only thing that moves
        -- a stubborn tree.
        local fsm = H.fsm_of(S.target_go)
        if not fsm then return false, mode end
        return pcall(function()
            fsm:call("setCurrentNode(System.String, System.UInt32, via.behaviortree.SetNodeInfo)",
                name, tree, nil)
        end), mode
    end

    local am = H.action_manager(ch)
    if not am then return false, mode end

    -- ⛔ L9 THE SILENT-REJECT LAW: requests are dropped on the floor unless this is cleared.
    -- Clear -> fire -> restore a few frames later (restoring immediately is too early: the request
    -- has not been consumed yet). PANIC and script-reset both force the restore too.
    if C.node_clear_reject == true and not S.reject then
        local prev = H.sc(am, "get_IsRejectRequestOnDefault")
        if pcall(function() am:call("set_IsRejectRequestOnDefault(System.Boolean)", false) end) then
            S.reject = { ch = ch, prev = (prev == true) }
            H.defer(math.max(2, math.floor(tonumber(C.reject_restore_frames) or 12)), H.restore_reject)
        end
    end

    local leaf = ND.leaf(name)

    -- ⭐ THE GRIFFIN DOUBLE-FIRE: route3_rise_start_clip sends the leaf to layer 4 FIRST and then
    -- layer 0. A lone layer-0 request is what silently "does nothing" when the body's action slots
    -- are already occupied -- which is the normal state of a parked companion.
    local layers = { layer }
    if C.node_fire_layer4 ~= false and layer == 0 then layers = { 4, 0 } end

    if mode == "requestActionCore" then
        local any = false
        for _, L in ipairs(layers) do
            local o = pcall(function()
                am:call("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)",
                    10, leaf, L)
            end)
            any = any or o
        end
        return any, mode
    end
    -- the sanctioned door: requestAction(name, layer, force)
    local ok = false
    for _, L in ipairs(layers) do
        local o = pcall(function()
            am:call("requestAction(System.String, System.UInt32, System.Boolean)", leaf, L, true)
        end)
        ok = ok or o
    end
    if ok then return true, mode end
    -- older builds expose only the Core form; do not lose the fire over a signature
    return pcall(function()
        am:call("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)",
            10, leaf, layer)
    end), "requestActionCore (fallback)"
end

-- ⭐ DID IT TAKE? The single most useful readout this panel can give: fire a node and find out
-- whether the FSM actually moved, instead of staring at a creature and guessing. Re-asserts on the
-- LAW-14 cadence while it waits, and stops the moment it lands.
function ND.hold_tick()
    local h = S.node_hold
    if not h then return end
    if h.key ~= S.target_key then S.node_hold = nil; return end

    local cur = ND.current(h.tree)
    if cur and (cur == h.name or ND.leaf(cur) == ND.leaf(h.name)) then
        if not h.took then
            h.took = true
            H.status(string.format("✅ NODE TOOK: tree %d is now %s (after %d attempt%s)",
                h.tries and h.tree or h.tree, tostring(cur), h.tries, h.tries == 1 and "" or "s"))
        end
        -- ⭐ it landed: let it PLAY, then restore. The griffin's lockout rides the node's real
        -- length rather than a hardcoded duration, so we hold until the FSM leaves it (or the
        -- window's ceiling), then pump the body home.
        h.playing_until = h.playing_until or (os.clock()
            + math.max(0.2, tonumber(C.node_reassert_secs) or 2.0))
        if os.clock() < h.playing_until then return end
        S.node_hold = nil
        if C.node_autorestore ~= false then ND.restore("node finished") end
        return
    end
    -- it took earlier and the FSM has now left the node: that is the natural end
    if h.took then
        S.node_hold = nil
        if C.node_autorestore ~= false then ND.restore("node ended") end
        return
    end

    local now = os.clock()
    if now >= h.until_t or h.tries >= math.max(1, math.floor(tonumber(C.node_reassert_max) or 8)) then
        if C.node_autorestore ~= false then ND.restore("node never took") end
        H.status(string.format("⚠ node did NOT take after %d attempt%s -- tree %d still reads %s. "
            .. "This is NOT the lab refusing. A SUMMONED companion is owned by IRIS (FSM parked + "
            .. "its clip repainted every frame), so it stomps the node straight back. Test nodes on "
            .. "a WILD body instead: set mode = 'nearest'. Or get it into the %s.* family first.",
            h.tries, h.tries == 1 and "" or "s", h.tree, tostring(cur or "(none)"), ND.family(h.name)))
        S.node_hold = nil
        return
    end
    if now >= h.next_t then
        h.tries = h.tries + 1
        h.next_t = now + math.max(0.05, tonumber(C.node_reassert_gap) or 0.15)
        pcall(function() H.set_fsm(S.target_go, true) end)   -- it may have been re-parked
        pcall(function() ND.dispatch(h.name, h.tree, h.mode, h.layer) end)
    end
end

function ND.fire(name)
    name = tostring(name or "")
    if name == "" then H.status("no node selected"); return false end
    local tree = (S.nodes and S.nodes.set and S.nodes.set[name]) or 0

    local ch = S.target
    local mode = tostring(C.node_fire_mode or "requestAction")
    local layer = math.floor(tonumber(C.node_layer) or 0)
    local ok, how = false, mode

    -- ⛔ ARM-INTEGRITY: resolve the door FIRST, so nothing can refuse after the arms are spent
    -- below. (ND.guard itself only REPORTS which arms are needed; this function spends them, and
    -- only once every gate has passed.)
    local fsm = (mode == "setCurrentNode") and H.fsm_of(S.target_go) or nil
    local am  = (mode ~= "setCurrentNode") and H.action_manager(ch) or nil
    if mode == "setCurrentNode" and not fsm then
        H.status("no via.motion.MotionFsm2 on this body"); return false
    end
    if mode ~= "setCurrentNode" and not am then
        H.status("no app.ActionManager on this body"); return false
    end

    local refuse, need = ND.guard(name, tree)
    if refuse then H.status(refuse); return false end
    -- every gate passed: NOW spend the arms, and only the ones actually used
    need = need or {}
    if need.killed then S.arm_killed = false end
    if need.crosstree then S.arm_crosstree = false end

    -- ⛔ L5, ONE OWNER OF LAYER 0: a node and a painted clip on the same layer is the two-owner AV.
    -- Firing a node therefore RELEASES any clip we were holding -- the node becomes the sole owner.
    S.froze = nil
    S.verify = nil

    -- a previous fire's pump must not still be dragging the body backwards while we fire again
    S.node_exit = nil

    -- ⭐⭐ PREP: free the body so the node can physically run, snapshotting everything first.
    -- ⛔ ORDER MATTERS -- the griffin comment is explicit that the protection has to be in force on
    -- the very first frame the node exists: "Opening it after the request leaves exactly the
    -- one-tick gap that two-owner crashes live in."
    local was_off = (H.fsm_enabled(S.target_go) == false)
    local prep = ND.prep()

    H.tape_open("node " .. name, H.chid())

    ok, how = ND.dispatch(name, tree, mode, layer)

    -- ⭐ RE-ASSERT WINDOW. One shot at a parked companion does nothing visible: IRIS keeps its own
    -- clip on layer 0 and the FSM off, so the node is stomped within a frame. This re-fires on the
    -- LAW-14 cadence (0.15s, capped attempts) and stops the instant the FSM reports the node took.
    if C.node_reassert ~= false then
        S.node_hold = {
            name = name, tree = tree, mode = mode, layer = layer,
            until_t = os.clock() + math.max(0.2, tonumber(C.node_reassert_secs) or 2.0),
            next_t  = os.clock() + math.max(0.05, tonumber(C.node_reassert_gap) or 0.15),
            tries = 1, took = false, key = S.target_key,
            start_node = ND.current(tree) or "(none)",
        }
    end

    S.node_fired = { name = name, tree = tree, t = os.clock() }
    H.status(string.format("node fire [%s] %s  tree=%d layer=%s  ok=%s%s%s -- watching whether it TAKES",
        how, name, tree,
        (C.node_fire_layer4 ~= false and layer == 0 and mode ~= "setCurrentNode") and "4+0" or tostring(layer),
        tostring(ok),
        (prep and C.node_prep ~= false) and "  [prepped: puppet off, FSM on, reject cleared]" or "",
        was_off and "  (FSM was OFF)" or ""))
    return ok
end

-- RESET: hand the body back to its own brain. Re-enabling the FSM is what actually returns it -- a
-- fired node does NOT auto-return to neutral.
function ND.reset()
    -- ⭐ if a prep is outstanding, RESTORE is the correct reset: pump the body back into the node
    -- it was in and put every snapshotted flag back -- the mount's own exit shape.
    if S.node_prep then
        H.tape_flush(false, nil, nil)
        S.froze, S.verify = nil, nil
        return ND.restore("manual reset")
    end
    H.restore_reject()
    H.thaw(S.target, S.target_go)
    S.froze, S.verify, S.node_hold = nil, nil, nil
    H.tape_flush(false, nil, nil)

    -- ⛔ the neutral request is subject to L9 exactly like any other: it must be issued INSIDE a
    -- cleared IsRejectRequestOnDefault window. Restoring the flag first (which is what
    -- H.restore_reject above does) and then requesting made this a guaranteed silent no-op, while
    -- the status line cheerfully claimed "requested Locomotion.Wait". Clear -> request -> restore.
    -- ⛔ And only from a node set that belongs to THIS body -- a foreign leaf name is the same
    -- native crash the fire path guards against.
    local asked = nil
    if C.node_reset_neutral == true and S.nodes and S.nodes.set and not ND.owns_target() then
        for _, want in ipairs({ "Locomotion.Wait", "Locomotion.Idle", "Wait", "Idle" }) do
            if not asked and S.nodes.set[want] ~= nil then asked = want end
        end
        if not asked then
            for _, e in ipairs(S.nodes.list or {}) do
                if not asked and tostring(e.name):find("%.Wait$") then asked = e.name end
            end
        end
        if asked then
            local am = H.action_manager(S.target)
            if am then
                local prev = H.sc(am, "get_IsRejectRequestOnDefault")
                local cleared = pcall(function()
                    am:call("set_IsRejectRequestOnDefault(System.Boolean)", false)
                end)
                pcall(function()
                    am:call("requestAction(System.String, System.UInt32, System.Boolean)", ND.leaf(asked), 0, true)
                end)
                if cleared then
                    S.reject = { ch = S.target, prev = (prev == true) }
                    H.defer(math.max(2, math.floor(tonumber(C.reject_restore_frames) or 12)), H.restore_reject)
                end
            else
                asked = nil
            end
        end
    end
    H.status("RESET: FSM live, think-stop off, puppet off"
        .. (asked and (", requested " .. asked) or ", body drives itself"))
    return true
end

-- ============================================================================================
-- ⭐ THE FIRE QUEUE -- why the buttons do not fire directly
-- ============================================================================================
-- imgui callbacks run on the RENDER/PRESENT thread. The documented law in this codebase is that
-- engine work touching streaming must run on the GAME thread (re.on_frame / UpdateBehavior) --
-- doing it from on_draw_ui crashes the moment real streaming happens. RiftSpeakDevDebug and
-- IrisTaming both fire changeMotion straight from their panels and get away with it, but they are
-- playing clips they already know are resident; this lab exists precisely to poke at ones that
-- are not. So a button only ever RECORDS an intent, and the frame tick performs it.
--
-- When the game is PAUSED the frame hook sleeps, and the panel drives the tick itself (see
-- on_draw_ui) -- which drains this queue too, so pausing to study a pose still works exactly as
-- it does in the older labs.
function MO.request_play()
    S.request = { kind = "clip" }
end

function ND.request_fire(name)
    S.request = { kind = "node", name = tostring(name or "") }
end

local function drain_request()
    local r = S.request
    if not r then return end
    S.request = nil
    if r.kind == "clip" then
        MO.play()
    elseif r.kind == "node" then
        ND.fire(r.name)
    end
end

-- ============================================================================================
-- TICK
-- ============================================================================================
local function lab_tick()
    S.frame = S.frame + 1
    S.last_tick = os.clock()

    for i = #S.defer, 1, -1 do
        local d = S.defer[i]
        d.frames = d.frames - 1
        if d.frames <= 0 then table.remove(S.defer, i); pcall(d.fn) end
    end

    H.resolve_target()

    -- ⛔ the unconditional hold ceiling runs BEFORE the no-target bail and acts on the HELD handles,
    -- never on the current target. A frozen body must be reachable even after the target has moved
    -- on or vanished entirely -- that was exactly how one got stranded for a whole session.
    local ceil = tonumber(C.hold_ceiling_sec) or 0
    if ceil > 0 and H.lab_holds() and (os.clock() - (tonumber(S.froze.t) or 0)) > ceil then
        H.unfreeze(false)   -- automatic release: put the FSM back how we found it, not "on"
        H.status(string.format("hold ceiling reached (%.0fs) -- body released automatically", ceil))
    end

    if not S.target then S.request = nil; return end

    drain_request()          -- ⭐ the panel's buttons land HERE, on the game thread

    MO.scan_tick()
    MO.verify_tick()
    MO.witness_tick()
    ND.hold_tick()
    ND.exit_tick()

    if S.witness_dirty and (S.frame % 600) == 0 then H.save_witness() end
end

re.on_frame(function() pcall(lab_tick) end)

-- ⛔ L10: leaving a creature frozen through a script reset orphans it -- S is rebuilt empty and
-- nothing would ever restore its FSM. Put everything back on the way out, unconditionally.
re.on_script_reset(function()
    pcall(function()
        H.restore_reject()
        -- ⛔ a reload with a prep outstanding would strand the body accepting every default request
        -- and (if it was parked) with its FSM left on. Put the snapshot back before S is rebuilt.
        if S.node_prep then ND.prep_finish("script reset") end
        -- undo exactly our own freeze, restoring the FSM state we found (a parked companion stays
        -- parked). We never froze anything we did not record, so nothing else needs touching.
        H.unfreeze(false)
        H.tape_flush(false, nil, nil)
        if S.witness_dirty then H.save_witness() end
    end)
end)

-- ============================================================================================
-- UI
-- ============================================================================================
-- (UI declared at the top with H/MO/ND)

function UI.target()
    imgui.text("TARGET")
    local id = H.identity()
    if not id then
        imgui.text_colored("  (no creature -- summon a tamed companion, or stand within 40m of any body)", 0xFFAAAAAA)
        return
    end
    imgui.text_colored("  " .. H.label(), 0xFF80FFD0)
    imgui.text("  " .. id.raw)

    local extra = {}
    if id.vkey then extra[#extra + 1] = "variant " .. id.vkey end
    if id.record then
        if id.record.kind then extra[#extra + 1] = "kind " .. tostring(id.record.kind) end
        if id.record.gender then extra[#extra + 1] = tostring(id.record.gender) end
        if id.record.variant then extra[#extra + 1] = tostring(id.record.variant) end
    end
    extra[#extra + 1] = id.is_companion and "SUMMONED COMPANION" or "not the companion (nearest body)"
    imgui.text("  " .. table.concat(extra, " | "))

    local claims = H.claims(S.target_go)
    if #claims > 0 then
        imgui.text_colored("  claimed by: " .. table.concat(claims, ", "), 0xFF00A5FF)
    end

    local chg = false
    imgui.text("mode:")
    for _, m in ipairs({ "companion", "nearest", "pinned" }) do
        imgui.same_line()
        if imgui.button((C.target_mode == m and "[" .. m .. "]" or m) .. "##tgt" .. m) then
            C.target_mode = m
            if m == "pinned" then S.pinned = S.target end
            chg = true
        end
    end
    if imgui.button("pin this body##pin") then S.pinned = S.target; C.target_mode = "pinned"; chg = true end
    imgui.same_line()
    if imgui.button("unpin##unpin") then S.pinned = nil; C.target_mode = "companion"; chg = true end
    if chg then H.save_config() end

    -- LIVE readout. Every atlas file carries endframe = 0 (they were dumped that way) -- the live
    -- layer is the ONLY place a real clip length exists, which is exactly what this line shows.
    for li = 0, 1 do
        local l = H.layer_of(S.target, li)
        if l then
            imgui.text(string.format("  L%d  %s:%s   frame %.0f / %.0f",
                li, tostring(H.sc(l, "get_MotionBankID")), tostring(H.sc(l, "get_MotionID")),
                tonumber(H.sc(l, "get_Frame")) or 0, tonumber(H.sc(l, "get_EndFrame")) or 0))
        end
    end
    local nodes = {}
    for t = 0, 3 do
        local n = ND.current(t)
        if n then nodes[#nodes + 1] = t .. ":" .. n end
    end
    imgui.text("  FSM  " .. (#nodes > 0 and table.concat(nodes, "   ") or "(no via.motion.MotionFsm2)"))
    -- ⚠ FSM enabled = false does NOT imply the lab froze it: IRIS parks companions with MotionFsm2
    -- off and paints an idle on them. Say which it is, or a parked pet reads as our bug.
    local fe = H.fsm_enabled(S.target_go)
    imgui.text_colored("  FSM enabled: " .. tostring(fe)
        .. (H.holds_target() and "   ⛔ THE LAB IS HOLDING THIS BODY -- 'Unfreeze Creature' releases it"
            or (fe == false and "   (held by another IRIS module, not the lab)" or "")),
        H.holds_target() and 0xFF00A5FF or 0xFFAAAAAA)
    -- a body held somewhere else must stay visible, or it is the one that gets abandoned
    if H.lab_holds() and not H.holds_target() then
        imgui.text_colored("  ⛔ the lab is still holding ANOTHER body: " .. tostring(S.froze.key)
            .. "  -- PANIC or 'unfreeze' releases it", 0xFF00A5FF)
    end
end

function UI.motion()
    imgui.text("== MOTION LIBRARY ==")
    if imgui.button("Rescan banks/motions##scan") then MO.scan_start() end
    imgui.same_line()
    if imgui.button("Load atlas from file##atlas") then MO.load_atlas() end
    imgui.same_line()
    local c
    c, C.deep_bank0 = imgui.checkbox("deep-sweep bank 0##deep0", C.deep_bank0 == true)
    if c then H.save_config() end

    if S.scan then
        imgui.text(string.format("  SCANNING (%s): bank %s, idx %d, found %d",
            tostring(S.scan.phase), tostring(S.scan.banks[S.scan.bi] or "-"), S.scan.i, #S.scan.found))
        if imgui.button("cancel scan##cancelscan") then S.scan = nil; H.status("scan cancelled") end
        return
    end
    if not S.cat then
        imgui.text_colored("  no library loaded -- 'Load atlas from file' is instant (25 species are "
            .. "already catalogued); 'Rescan' reads this body live.", 0xFFAAAAAA)
        if not C.unsafe then return end
        -- ⛔ UNSAFE: raw fire with no catalogue at all -- type a bank:id and send it
        local rc
        rc, C.bank = imgui.drag_int("bank (raw)##rawb", math.floor(tonumber(C.bank) or 0), 1, 0, 999)
        if rc then H.save_config() end
        rc, C.motion = imgui.drag_int("motion (raw)##rawm", math.floor(tonumber(C.motion) or 0), 1, 0, 99999)
        if rc then H.save_config() end
        rc, C.layer = imgui.drag_int("layer##rawl", math.floor(tonumber(C.layer) or 0), 1, 0, 3)
        if rc then H.save_config() end
        rc, C.hold_mode = imgui.checkbox("HOLD the clip##rawhold", C.hold_mode == true)
        if rc then H.save_config() end
        if imgui.button("⛔ FIRE RAW " .. MO.key(C.bank, C.motion) .. "##rawfire") then MO.request_play() end
        imgui.same_line()
        if imgui.button("Unfreeze Creature##rawunfreeze") then H.unfreeze(true) end
        return
    end

    imgui.text(string.format("  %s -- %d clips in %d banks  (%s)",
        tostring(S.cat.label), #S.cat.clips, #S.cat.banks, tostring(S.cat.source)))

    local banks = S.cat.banks
    local bi, bn = MO.pos(banks, math.floor(tonumber(C.bank) or 0))

    -- every fire goes through the queue: the button records, the frame tick performs
    local function reapply() if C.auto_play == true then MO.request_play() end end

    -- ⛔ the drag widgets' `changed` flag must be HONOURED. Discarding it meant dragging the bank
    -- or motion slider neither auto-played nor persisted -- so the panel silently behaved
    -- differently from the +/- buttons, and a script reset snapped you back to the old clip.
    -- A drag fires `changed` on every frame you hold it, hence the request queue (one intent per
    -- tick, later clicks overwrite earlier ones) rather than a play per frame.
    local ch
    ch, C.bank = imgui.drag_int("bank", math.floor(tonumber(C.bank) or 0), 1, 0, 999)
    if ch then
        -- a hand-typed bank can land on one with no clips; snap the motion into the new bank
        local nl = S.cat.by_bank[math.floor(tonumber(C.bank) or 0)]
        if nl and #nl > 0 and not S.cat.by_key[MO.key(C.bank, C.motion)] then C.motion = nl[1] end
        H.save_config(); reapply()
    end

    local function bbump(d)
        C.bank = MO.step(banks, math.floor(tonumber(C.bank) or 0), d)
        local ml = S.cat.by_bank[C.bank]
        if ml and #ml > 0 then C.motion = ml[1] end
        H.save_config(); reapply()
    end
    if imgui.button("-10##b") then bbump(-10) end
    imgui.same_line(); if imgui.button("-1##b") then bbump(-1) end
    imgui.same_line(); if imgui.button("+1##b") then bbump(1) end
    imgui.same_line(); if imgui.button("+10##b") then bbump(10) end
    imgui.same_line(); imgui.text(string.format("bank = %d  (%d/%d)", math.floor(tonumber(C.bank) or 0), bi, bn))

    local ml = S.cat.by_bank[math.floor(tonumber(C.bank) or 0)] or {}
    local mi, mn = MO.pos(ml, math.floor(tonumber(C.motion) or 0))
    ch, C.motion = imgui.drag_int("motion", math.floor(tonumber(C.motion) or 0), 1, 0, 99999)
    if ch then H.save_config(); reapply() end
    local function mbump(d)
        C.motion = MO.step(ml, math.floor(tonumber(C.motion) or 0), d)
        H.save_config(); reapply()
    end
    if imgui.button("-10##m") then mbump(-10) end
    imgui.same_line(); if imgui.button("-1##m") then mbump(-1) end
    imgui.same_line(); if imgui.button("+1##m") then mbump(1) end
    imgui.same_line(); if imgui.button("+10##m") then mbump(10) end
    imgui.same_line(); imgui.text(string.format("motion = %d  (%d/%d in bank)",
        math.floor(tonumber(C.motion) or 0), mi, mn))

    local bankv, idv = math.floor(tonumber(C.bank) or 0), math.floor(tonumber(C.motion) or 0)
    local e = MO.clip_at(bankv, idv)
    imgui.text("  name: " .. ((e and e.name) or "(not in catalogue)"))
    if e and (tonumber(e.endframe) or 0) > 0 then
        imgui.same_line(); imgui.text(string.format("   (atlas endframe %d)", e.endframe))
    end
    local _, kind, msg = MO.verdict(bankv, idv)
    local col = (kind == "witnessed" and 0xFF80FF80)
        or (kind == "ok" and 0xFFAAAAAA)
        or (kind == "killed" and 0xFF0000FF)
        or (kind == "hot" and 0xFF0000FF)
        or 0xFF00A5FF
    imgui.text_colored("  " .. msg, col)

    c, C.auto_play = imgui.checkbox("Auto-play on +/- change", C.auto_play == true); if c then H.save_config() end
    c, C.layer = imgui.drag_int("layer", math.floor(tonumber(C.layer) or 0), 1, 0, 3); if c then H.save_config() end
    c, C.hold_mode = imgui.checkbox("HOLD the clip (MotionFsm2 off -- required for a clip to actually show)",
        C.hold_mode == true); if c then H.save_config() end
    c, C.think_stop = imgui.checkbox("also think-stop (⛔ ignored for ids >= the ceiling: that combo is a native AV)",
        C.think_stop == true); if c then H.save_config() end

    if imgui.button("Play on Creature (changeMotion)##play") then MO.request_play() end
    imgui.same_line()
    if imgui.button("Unfreeze Creature##unfreeze") then
        H.unfreeze(true); H.status("unfrozen -- FSM live, think-stop off")
    end

    c, C.clip_filter = imgui.input_text("find by name##clipfilter", tostring(C.clip_filter or ""))
    if c then H.save_config() end
    local f = tostring(C.clip_filter or ""):lower()
    if f ~= "" then
        local chid, shown = H.chid(), 0
        for _, cl in ipairs(S.cat.clips) do
            if shown < 14 and tostring(cl.name):lower():find(f, 1, true) then
                shown = shown + 1
                local tag = H.is_killed(chid, "clip " .. MO.key(cl.bank, cl.id)) and "☠ "
                    or (MO.witnessed(chid, cl.bank, cl.id) and "✅ " or "   ")
                if imgui.button(string.format("%s%d:%d  %s##f%d_%d", tag, cl.bank, cl.id, cl.name, cl.bank, cl.id)) then
                    C.bank = cl.bank; C.motion = cl.id; H.save_config(); MO.request_play()
                end
            end
        end
        if shown == 0 then imgui.text("  (no clip name contains that)") end
    end
end

function UI.nodes()
    imgui.text("== NODE LIBRARY ==")
    if imgui.button("Rescan node tree##nscan") then ND.scan(S.target_go, "live") end
    imgui.same_line()
    if imgui.button("Save node atlas##nsave") then ND.save_atlas() end
    imgui.same_line()
    if imgui.button("Load node atlas##nload") then ND.load_atlas() end
    if imgui.button("probe NEAREST body -> node atlas##nprobe") then ND.probe_nearest() end
    imgui.same_line()
    imgui.text_colored("(for creatures you have not tamed yet)", 0xFFAAAAAA)

    if not (S.nodes and S.nodes.list and #S.nodes.list > 0) then
        imgui.text_colored("  no node tree loaded. 'Rescan node tree' reads the LIVE body -- it works on "
            .. "any body with a via.motion.MotionFsm2, so a summoned creature never needs the probe.", 0xFFAAAAAA)
        if not C.unsafe then return end
        local rc
        rc, C.node_filter = imgui.input_text("raw node name##nrawname", tostring(C.node_filter or ""))
        if rc then H.save_config() end
        if tostring(C.node_filter or "") ~= "" and imgui.button("⛔ FIRE RAW NODE##nraw0") then
            ND.request_fire(tostring(C.node_filter))
        end
        return
    end

    imgui.text(string.format("  %s -- %d nodes, tree(s) %s  (%s)",
        tostring(S.nodes.species or S.nodes.chid), #S.nodes.list,
        table.concat(S.nodes.trees or { 0 }, ","), tostring(S.nodes.source)))

    -- ⛔⛔ the loudest warning in the panel. After a probe (or an atlas load for another species)
    -- the list on screen is NOT the target's tree, and firing from it is a native crash. ND.guard
    -- refuses it, but the user must see WHY before they click, not after.
    local foreign = ND.owns_target()
    if foreign then
        imgui.text_colored("  ⛔⛔ THIS TREE IS NOT THE TARGET'S -- "
            .. (C.unsafe and "ADVISORY ONLY, it will fire anyway." or "firing is refused."), 0xFF0000FF)
        imgui.text_colored("     " .. foreign, 0xFF0000FF)
        imgui.same_line()
        if imgui.button("rescan the target's tree##nfix") then ND.scan(S.target_go, "live") end
    end

    local c
    c, C.node_filter = imgui.input_text("filter##nfilter", tostring(C.node_filter or ""))
    if c then H.save_config() end
    local filt = tostring(C.node_filter or ""):lower()
    local shown, raw = {}, {}
    local chid = H.chid()
    for _, e in ipairs(S.nodes.list) do
        if filt == "" or tostring(e.name):lower():find(filt, 1, true) then
            raw[#raw + 1] = e
            local mark = H.is_killed(chid, "node " .. e.name) and "☠ " or (ND.blocked(e.name) and "⛔ " or "   ")
            shown[#shown + 1] = mark .. "t" .. tostring(e.tree) .. "  " .. e.name
        end
    end
    if #shown == 0 then shown[1] = "(no match)"; raw[1] = nil end
    S.node_pick = math.min(math.max(1, math.floor(tonumber(S.node_pick) or 1)), #shown)
    local nc
    nc, S.node_pick = imgui.combo(string.format("node (%d/%d)##ncombo", #shown, #S.nodes.list),
        S.node_pick, shown)
    local sel = raw[S.node_pick]
    local selname = sel and sel.name or ""

    -- the verdict is shown BEFORE you click anything
    if sel then
        local cur = ND.current(sel.tree)
        local have, want = cur and ND.family(cur) or nil, ND.family(selname)
        local hard = ((C.node_fire_mode == "setCurrentNode") or (C.crosstree_blocks_requests == true))
            and not C.unsafe
        if have and want ~= "" and have ~= want then
            if C.unsafe then
                imgui.text_colored(string.format("  ⚠ CROSS-TREE (⛔ UNSAFE: ADVISORY, it WILL fire): "
                    .. "body is in %s.* , node is %s.* .", have, want), 0xFF00A5FF)
            elseif hard then
                imgui.text_colored(string.format("  ⛔ CROSS-TREE, REFUSED: the body is in %s.* , this "
                    .. "node is %s.* . setCurrentNode slams the FSM with no validation -- that shape "
                    .. "is every logged node CTD. Switch to requestAction, or tick the ⛔ ARM.",
                    have, want), 0xFF0000FF)
            else
                imgui.text_colored(string.format("  ⚠ CROSS-TREE (allowed): the body is in %s.* , this "
                    .. "node is %s.* . requestAction validates the transition itself, so the likely "
                    .. "outcome is simply nothing happening -- get the body into %s.* for it to take.",
                    have, want, want), 0xFF00A5FF)
            end
        elseif have then
            imgui.text_colored("  same family as the body's current node (" .. have .. ".*)", 0xFF80FF80)
        else
            imgui.text_colored("  (tree " .. tostring(sel.tree) .. " reports no current node -- "
                .. (hard and "setCurrentNode is REFUSED without it" or "firing is allowed, but blind"), 0xFF00A5FF)
        end
        local b, pat = ND.blocked(selname)
        if b then imgui.text_colored("  ⛔ blocklisted (matches '" .. tostring(pat) .. "') -- advisory", 0xFF00A5FF) end
        if H.is_killed(chid, "node " .. selname) then
            imgui.text_colored("  ☠ this node crashed the game before -- refused", 0xFF0000FF)
        end
    end

    imgui.text("fire via:")
    for _, m in ipairs({ "requestAction", "requestActionCore", "setCurrentNode" }) do
        imgui.same_line()
        if imgui.button((C.node_fire_mode == m and "[" .. m .. "]" or m) .. "##nm" .. m) then
            C.node_fire_mode = m; H.save_config()
        end
    end
    if C.node_fire_mode == "setCurrentNode" then
        imgui.text_colored("  ⛔ setCurrentNode sets a RAW node the AI reverts -- documented to T-pose on "
            .. "air nodes. requestAction is the sanctioned door.", 0xFF00A5FF)
    end
    c, C.node_layer = imgui.drag_int("node layer##nlayer", math.floor(tonumber(C.node_layer) or 0), 1, 0, 4)
    if c then H.save_config() end
    c, C.node_clear_reject = imgui.checkbox("clear IsRejectRequestOnDefault around the fire (or it silently no-ops)",
        C.node_clear_reject == true); if c then H.save_config() end

    if imgui.button("PLAY NODE ON CREATURE##nfire") then ND.request_fire(selname) end
    imgui.same_line()
    if imgui.button("RESET (hand the body back)##nreset") then ND.reset() end

    -- ⛔ UNSAFE: fire whatever is typed in the filter box as a literal node name. This is the
    -- "force ANY node on ANY creature" door -- a name from another species' atlas, a name you read
    -- out of a dump, a guess. Nothing validates it; the crash tape is what tells you the answer.
    if C.unsafe then
        local typed = tostring(C.node_filter or "")
        if typed ~= "" then
            if imgui.button("⛔ FIRE THE FILTER TEXT AS A RAW NODE NAME: '" .. typed .. "'##nraw") then
                ND.request_fire(typed)
            end
        else
            imgui.text_colored("  (⛔ unsafe: type an exact node name into the filter box to fire it raw)",
                0xFF00A5FF)
        end
    end

    local rc2
    rc2, C.node_prep = imgui.checkbox("PREP before firing (puppet off, FSM on, think alive, reject cleared)",
        C.node_prep ~= false); if rc2 then H.save_config() end
    rc2, C.node_fire_layer4 = imgui.checkbox("fire on layer 4 then 0 (the griffin rise recipe)",
        C.node_fire_layer4 ~= false); if rc2 then H.save_config() end
    rc2, C.node_reassert = imgui.checkbox("re-assert the node for ~2s (a parked body stomps a single fire)",
        C.node_reassert ~= false); if rc2 then H.save_config() end
    rc2, C.node_autorestore = imgui.checkbox("auto-RESTORE afterwards (pump back to the pre-fire node)",
        C.node_autorestore ~= false); if rc2 then H.save_config() end

    if S.node_prep then
        imgui.text_colored(string.format("  PREPPED: was FSM=%s puppet=%s reject=%s, node0=%s",
            tostring(S.node_prep.fsm_enabled), tostring(S.node_prep.puppet),
            tostring(S.node_prep.reject), tostring(S.node_prep.from and S.node_prep.from[0])), 0xFF00FFFF)
    end
    if S.node_exit then
        imgui.text_colored(string.format("  ...restoring -> %s (request %d, tree 0 reads %s)",
            tostring(S.node_exit.want), S.node_exit.tries, tostring(ND.current(0) or "(none)")), 0xFF00FFFF)
    end

    if S.node_hold then
        imgui.text_colored(string.format("  ...asserting %s -- attempt %d, tree %d currently reads %s",
            tostring(S.node_hold.name), S.node_hold.tries, S.node_hold.tree,
            tostring(ND.current(S.node_hold.tree) or "(none)")), 0xFF00FFFF)
    end
    if S.node_fired then
        imgui.text(string.format("  last fired: %s (tree %d, %.1fs ago)", tostring(S.node_fired.name),
            math.floor(tonumber(S.node_fired.tree) or 0), os.clock() - (tonumber(S.node_fired.t) or os.clock())))
    end
end

function UI.safety()
    imgui.text("== SAFETY ==")
    if S.tape then
        imgui.text_colored("☠ LAST SESSION DIED FIRING  " .. tostring(S.tape.what) .. "  on "
            .. tostring(S.tape.chid) .. "  -- it is now on the KILLED list and refused.", 0xFF0000FF)
        imgui.same_line()
        if imgui.button("dismiss##dismisstape") then S.tape = nil end
    end

    local c
    c, C.unsafe = imgui.checkbox("⛔ UNSAFE MODE (master switch -- everything below becomes advisory)",
        C.unsafe == true); if c then H.save_config() end
    if C.unsafe then
        imgui.text_colored("  UNSAFE is ON -- the settings below only decide what gets a WARNING.", 0xFF00A5FF)
    end
    c, C.guard_ceiling = imgui.checkbox("residency ceiling (refuse unwitnessed high ids)",
        C.guard_ceiling == true); if c then H.save_config() end
    c, C.safe_ceiling = imgui.drag_int("safe id ceiling##ceil",
        math.floor(tonumber(C.safe_ceiling) or 400), 10, 0, 20000); if c then H.save_config() end
    c, C.ceiling_bank0_only = imgui.checkbox("...but only in BANK 0 (where the streamed families live)",
        C.ceiling_bank0_only ~= false); if c then H.save_config() end
    c, C.guard_additive = imgui.checkbox("refuse *_add_pose clips on layer 0",
        C.guard_additive == true); if c then H.save_config() end
    c, C.guard_crosstree = imgui.checkbox("cross-tree node guard (hard-refuses setCurrentNode)",
        C.guard_crosstree == true); if c then H.save_config() end
    c, C.crosstree_blocks_requests = imgui.checkbox("   ...and refuse requestAction too (strict)",
        C.crosstree_blocks_requests == true); if c then H.save_config() end
    c, C.guard_claimed = imgui.checkbox("refuse a body another IRIS module is driving (downed/mounted/ridden)",
        C.guard_claimed == true); if c then H.save_config() end
    c, C.guard_killed = imgui.checkbox("refuse anything on the ☠ KILLED list",
        C.guard_killed == true); if c then H.save_config() end
    c, C.hold_ceiling_sec = imgui.drag_int("auto-thaw a held body after N seconds (0 = never)##holdceil",
        math.floor(tonumber(C.hold_ceiling_sec) or 180), 10, 0, 1800); if c then H.save_config() end

    imgui.separator()
    imgui.text_colored("ONE-SHOT OVERRIDES -- each clears itself after a single use, and none survive a restart:",
        0xFF00A5FF)
    c, S.arm_ceiling   = imgui.checkbox("⛔ ARM: play an unwitnessed high id  (CAN HARD-CRASH)", S.arm_ceiling == true)
    c, S.arm_crosstree = imgui.checkbox("⛔ ARM: fire a node from a foreign tree family  (CAN HARD-CRASH)", S.arm_crosstree == true)
    c, S.arm_killed    = imgui.checkbox("☠ ARM: retry something on the KILLED list  (IT ALREADY CRASHED ONCE)", S.arm_killed == true)

    imgui.separator()
    if imgui.button("!!  PANIC -- restore everything  !!##panic") then H.panic() end
    imgui.same_line()
    if imgui.button("unfreeze##sf1") then H.unfreeze(true) end
    imgui.same_line()
    if imgui.button("think-stop OFF##sf2") then H.set_think_stop(S.target, false) end
    imgui.same_line()
    if imgui.button("speed 1.0##sf3") then
        pcall(function() H.motion_of(S.target):call("set_PlaySpeed", 1.0) end)
    end

    local chid = H.chid()
    local nw, nk = 0, 0
    for _ in pairs(S.witness[chid] or {}) do nw = nw + 1 end
    for _ in pairs(S.killed[chid] or {}) do nk = nk + 1 end
    imgui.text(string.format("%s:  ✅ %d proven-resident clips   ☠ %d killed entries", chid, nw, nk))
    if imgui.button("save ledgers now##wsave") then
        H.save_witness(); H.tape_flush(false, nil, nil); H.status("ledgers saved")
    end
    imgui.same_line()
    if imgui.button("forget this species' witnesses##wclear") then
        S.witness[chid] = nil; H.save_witness(); H.status("witnesses cleared for " .. chid)
    end
    imgui.same_line()
    if imgui.button("clear the ☠ KILLED list##kclear") then
        S.killed[chid] = nil; H.tape_flush(false, nil, nil); H.status("killed list cleared for " .. chid)
    end
end

re.on_draw_ui(function()
    if not imgui.tree_node("IRIS Creature Anim Lab") then return end

    -- ⭐ the panel also drives the tick: on_frame sleeps while the game is paused, and pausing is
    -- exactly when you want to study a pose. If the frame hook has gone quiet, run it from here.
    if (os.clock() - (tonumber(S.last_tick) or 0)) > 0.15 then pcall(lab_tick) end

    imgui.text("status: " .. tostring(S.status))

    -- ⛔⛔⛔ the master switch, at the top where it cannot be missed
    local uc
    uc, C.unsafe = imgui.checkbox("⛔ UNSAFE MODE -- fire ANYTHING, no refusals (this is a lab)", C.unsafe == true)
    if uc then H.save_config() end
    if C.unsafe then
        imgui.text_colored("  all guards are ADVISORY: markers still show, nothing is blocked. "
            .. "The ☠ KILLED list still refuses -- that one is recorded fact, not a guess.", 0xFF00A5FF)
    end
    imgui.separator()
    pcall(UI.target)
    imgui.separator()
    pcall(UI.motion)
    imgui.separator()
    pcall(UI.nodes)
    imgui.separator()
    pcall(UI.safety)

    imgui.tree_pop()
end)

H.status("IrisAnimLab ready -- open 'IRIS Creature Anim Lab' in the REFramework window")
