-- ═════════════════════════════════════════════════════════════════════════════════════
-- IrisHomeLife.lua — the house comes alive.
--
-- Walk up to a usable furnishing and the native world guide says "B Sit". Press it and you sit
-- in it properly. Beds, benches, camp seats, bells, work stations — all the same code.
--
-- ⭐ WHY THIS IS CHEAP, AND WHY THE TAVERN SCENE WAS NOT:
--   RiftSpeak's seated tavern scene failed because it played a chair-height clip on a
--   body standing on grass and tried to fake the seat by SINKING the root — which the
--   player's character controller depenetrates, launching the Arisen into the sky
--   (riftspeak-tavern-drink-scene). Here there IS a real chair: IrisFurnish spawns REAL
--   gimmick prefabs, each carrying its own via.motion.MotionJackFsm2. A JACK attaches
--   the body to the object and plays the object's OWN state, so the seat height, the
--   hip anchor and the approach direction are all correct BY CONSTRUCTION. There is no
--   Y hack to tune. That is the entire reason this feature is assembly and not research.
--
-- ⛔ JACK = MOTION ONLY. It never attaches a prop (dd2-jack-eqit-prop-system, settled in
--   the field: Aurora's spade jack mimed empty-handed). Nothing here promises a prop.
--
-- ⛔ LAWS OBSERVED
--   • NEVER trap the player. Every escape path is unconditional: movement releases,
--     a deadline releases, script reset releases, and a release with no tracked session
--     still detaches and re-asserts the body. Being stuck in a chair is the worst
--     possible failure of this feature, so the escape does not depend on bookkeeping.
--   • BLACKLIST BY GIMMICK ID, NEVER BY FSM. The Godsbane doors share their FSM with
--     innocent gimmicks, so an FSM-level ban would blacklist the wrong things and a
--     name-level ban is the only safe one. Doors/locks/oxcarts/ballistae are never
--     offered — doors are quest-state hazards and moving owners break jacked bodies.
--   • WORLD-SETTLE GATE. No world-space label may draw while the game is loading; the
--     homestead load-stuck rounds (iris-farming) were caused by our own code acting
--     during app.GuiManager:get_IsLoadGui(). We only DRAW, never destroy, but the gate
--     is free and the law is the law.
--   • GIMMICK ORIGINS HANG HIGH — an ox-cart bell's origin sat above head height and v2
--     of InteractButton had to stop measuring from the feet. Reach is measured from
--     MID-BODY with separate up/down windows.
--   • TERMINAL NAMES MATCH LOWERCASED. gm05_046_lock_motfsm spells it "finish"; a
--     case-sensitive check hangs the player on a door forever.
--   • EndAction ≠ ActionEnd. EndAction is the stand-up ANIMATION you must play to get
--     out; ActionEnd is the terminal marker meaning the graph is over. Drive the exit,
--     THEN detach at the terminal — releasing at EndAction cuts the stand-up in half.
--
-- Slice 1 (this file): the PLAYER interacts with furniture. The actor is already
-- parameterised, so pawn idles (Aurora's second ask) hang off the same jack.
-- ═════════════════════════════════════════════════════════════════════════════════════

local M = {
    -- ⛔⛔⛔ OFF BY DEFAULT (2026-08-08). Aurora has been locked out of her own character
    -- repeatedly by this feature, and the last time it cost her a save reload. I do not yet
    -- understand how to return a jacked body to a clean state — eight rounds of fixes have not
    -- got there — and shipping an on-by-default feature that can only be escaped by reloading
    -- is indefensible. It stays off until the release path is PROVEN, not theorised.
    -- Turn it on deliberately in the IRIS HOME LIFE panel when you want to test.
    -- ⚠ The cookpot's cooking animation is a SEPARATE switch (IrisFarming M.cook_jack) and is
    -- still on, which makes the two an A/B: if the weapon lock happens with this off, the
    -- cookpot jack is the culprit; if it stops entirely, this was.
    enabled       = false,
    key           = 0x45,        -- E, matching IrisFarming's tend key
    pad_a         = true,        -- legacy setting name; now means native interact B / circle
    -- ⛔ OFF 08-09 (Aurora: "disable the jump suppression on all the interactables now that we
    --   use B instead of A"). This module's own key is E/pad-A, but the whole suite moved to B,
    --   so suppressing jump here just costs the player a control for nothing.
    block_jump    = false,

    reach         = 1.9,         -- flat distance to the gimmick origin
    reach_up      = 2.6,         -- origins hang HIGH: generous upward window
    reach_down    = 2.0,
    cone          = 80.0,        -- degrees off the facing direction

    prompt        = true,
    prompt_height = 1.0,         -- metres above the gimmick origin
    hold_secs     = 0.0,         -- 0 = hold the pose until you move
    exit_grace    = 2.0,         -- backstop only: the clip-end watch normally beats it
    seat_snap     = true,        -- settle onto the seat once the entry clip has played
    seat_flip     = false,       -- flip if she sits facing the wrong way
    seat_settle   = 1.1,         -- let the walk-in animation finish before we settle her
    seat_back     = 0.10,        -- push this far deeper into the chair
    cam_pull      = 2.0,         -- metres to pull the camera back while posed (0 = leave it)
    -- ⭐ record how the GAME enters and leaves a jack. ON while we are diagnosing; it only
    -- writes when the PLAYER is the one being jacked, so it is not noisy.
    -- ⛔ OFF. This instrument crashed the game (see the hook comment below): it has already
    -- told us what we needed — the release method list and that the engine self-teardowns via
    -- stopOwnerProcess — so it earns nothing further by staying armed.
    tape          = false,
    -- log the player's layer-0 bank/clip whenever it changes: this is how we learn the real
    -- cooking animation ids so farming can play them directly instead of jacking the pot.
    -- ⛔ OFF (2026-08-10). This is a DIAGNOSTIC: it writes a line every time the player's layer-0
    --   clip changes, which is constantly. It alone made IrisHomeLife.log 1.2 MB / 21k lines and
    --   it has already told us what it was built to tell us. Switch it on ONLY while hunting a
    --   specific clip id (e.g. the lie-down capture), then switch it back off.
    motion_tape   = false,
    -- ⭐⭐ NATIVE SEATS — on by default, unlike the jack. This path never touches the player's
    -- FSM: it spawns a meshless seat gimmick and lets the GAME do the sitting, so it carries
    -- none of the risk that got the jack disabled.
    native_seat       = true,
    native_seat_prefab = "gm80_257",   -- field-proven; gm80_065 also works
    native_seat_range = 12.0,          -- every seat within this radius gets its hidden seat,
                                       -- so pawns/NPCs can use chairs you are nowhere near
    native_seat_max   = 8,             -- ceiling, so a furnished room can't spawn a swarm
    native_seat_y     = 0.0,           -- raise/lower the seat if the pose sits high or low
    -- ⛔⛔ THE DEAD-MAN'S SWITCH. A loop pose held "until you move", and movement was the
    -- ONLY way out — so when the gamepad stick read failed, Aurora was stuck in a chair with
    -- no escape at all. I wrote the law ("never trap the player") and then shipped a pose with
    -- a single conditional exit. NOTHING may hold the body without a timer that cannot fail.
    max_pose      = 25.0,        -- absolute: release no matter what, no conditions
    panic_key     = 0x77,        -- F8 — always releases, even with no tracked session
    instant_cancel = true,       -- moving snaps you out now, no stand-up wait
    retry_secs    = 1.2,         -- keep offering a refused jack for this long
    retry_interval = 0.15,       -- ...but SPACED. Never hammer an FSM every frame (crash law)
    proxy_seat    = true,        -- chairs: jack a spawned gm80_166 instead (it has a skeleton)
    move_release  = true,        -- walking releases the pose
    grab_shield   = true,        -- E is also GRAB: suppress it while a prompt is up

    scan_secs     = 0.4,         -- how often we re-pick the nearest target
    list_secs     = 3.0,         -- how often we re-enumerate scene FSMs (they stream)
    log           = true,
}

local LOG = "IrisHomeLife.log"
local function _log(s)
    if not M.log then return end
    pcall(function()
        local f = io.open(LOG, "a")
        if f then f:write(os.date("[%H:%M:%S] ") .. tostring(s) .. "\n"); f:close() end
    end)
end

-- ── tiny helpers ─────────────────────────────────────────────────────────────────────
local function _comp(go, tn)
    local c = nil
    pcall(function() c = go:call("getComponent(System.Type)", sdk.typeof(tn)) end)
    return c
end

local function _valid(go)
    local v = false
    pcall(function() v = go:call("get_Valid") == true end)
    return v
end

local function _player()
    local ch = nil
    pcall(function()
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        ch = cm and cm:call("get_ManualPlayer")
    end)
    return ch
end

local function _char_go(ch)
    local go = nil
    pcall(function() go = ch:call("get_GameObject") end)
    return go
end

local function _pos(go)
    local p = nil
    pcall(function() p = go:call("get_Transform"):call("get_Position") end)
    return p
end

local function _yaw(go)
    local y = nil
    pcall(function()
        local q = go:call("get_Transform"):call("get_Rotation")
        y = math.atan(2.0 * (q.w * q.y + q.x * q.z), 1.0 - 2.0 * (q.y * q.y + q.x * q.x))
    end)
    return y
end

local function _wrap(a)
    while a > math.pi do a = a - math.pi * 2 end
    while a < -math.pi do a = a + math.pi * 2 end
    return a
end

-- findComponents hands back a System.Array. get_Count/get_Item are LIST methods — using
-- them here works by accident and silently truncates if get_Item throws mid-walk
-- (dd2-jack-eqit-prop-system hazard note). get_elements is the correct call.
local function _arr(a)
    local out = {}
    if not a then return out end
    local ok = pcall(function()
        for _, v in ipairs(a:get_elements()) do out[#out + 1] = v end
    end)
    if not ok or #out == 0 then
        pcall(function()
            local n = a:call("get_Count")
            for i = 0, (tonumber(n) or 0) - 1 do out[#out + 1] = a:call("get_Item", i) end
        end)
    end
    return out
end

-- world is still assembling? (the settle gate — never draw over a loading screen)
local function _loading()
    local l = false
    pcall(function()
        local g = sdk.get_managed_singleton("app.GuiManager")
        l = g and g:call("get_IsLoadGui") == true
    end)
    return l
end

-- ⛔⛔ GIVING CONTROL BACK — defined up here because BOTH the release path and the
-- failed-jack path need it, and a local defined below its callers is nil when they run.
-- A jack disables the player's FSM; rejectSelf detaches the jack but does NOT re-enable it,
-- so without this the body sits in its last clip and ignores every input — no movement, no
-- sheathing, no weapon swap (exactly Aurora's report). This is IrisFurnish's locked-controls
-- law: never leave the player FSM-disabled on ANY exit path, including error paths.
-- ⛔⛔ INSTRUMENTED, because I ASSUMED this worked and Aurora is still losing her weapon
-- controls after a pose. It is copied from IrisFurnish, but a silent pcall proves nothing:
-- if `h.Fsm` is nil in this context the whole restore is a no-op and we would never know.
-- Same trap that hid the dead detach. Every step now reports what it actually found.
local fsm_diag = 0
local function _fsm_on()
    local hum, had_fsm, was, now_on, thinkstop = false, false, "?", "?", "?"
    pcall(function()
        local h = sdk.get_managed_singleton("app.CharacterManager")
            :call("get_ManualPlayer"):call("get_Human")
        hum = h ~= nil
        if not h then return end
        local f = h.Fsm
        had_fsm = f ~= nil
        if not f then return end
        pcall(function() was = tostring(f:get_Enabled()) end)
        f:set_Enabled(true)
        pcall(function() now_on = tostring(f:get_Enabled()) end)
    end)
    pcall(function()
        local ch = _player()
        if ch then ch:call("set_IsThinkStop", false); thinkstop = "cleared" end
    end)
    -- log the first few restores in full; after that only if something looks wrong
    fsm_diag = fsm_diag + 1
    if fsm_diag <= 6 or not (hum and had_fsm) then
        _log(string.format("  fsm restore: human=%s fsm=%s enabled %s -> %s  thinkstop=%s",
            tostring(hum), tostring(had_fsm), was, now_on, thinkstop))
    end
end

-- ⛔⛔ IS A MENU / DIALOGUE UP? (Aurora 2026-08-08: "if I press B on the bed to get the rest
-- options and press A on cancel, the A counts as the interact and locks me standing".)
-- ⛔ PauseManager is the WRONG ORACLE — DD2's menus do not pause the world; IrisHorseRodeo
-- learned this the hard way (MENU GUARD v2, 07-23). The community-proven check that Nick's
-- core and Bestiary both use is app.GuiManager:isPausedGUI().
-- ⭐ AND THE SUBTLETY THAT ACTUALLY FIXES HER BUG: while a menu is up we still READ the
-- input edges and throw them away. Skipping the read would leave the held-A state stale, so
-- the very press that dismissed the menu would look like a fresh press the next frame — the
-- exact bug, just moved one frame later.
local function _menu_open()
    local m = false
    pcall(function()
        local gui = sdk.get_managed_singleton("app.GuiManager")
        m = gui and gui:call("isPausedGUI") == true
    end)
    return m
end

-- ⛔⛔ DETACHING PROPERLY. rejectSelf alone demonstrably does NOT give control back — Aurora
-- kept ending up unable to move, sheathe or swap weapons even after a "successful" release.
-- InteractButton suspected the same ("rejectSelf is the wrong lever") but never resolved it.
-- So: try EVERY release-ish method app.AdjustJack actually declares, in order, and log which
-- one existed and what it returned. This is self-diagnosing — the log names the real lever.
local RELEASE_LADDER = {
    "rejectSelf", "reject", "rejectAll", "requestReject", "cancelJack", "cancel",
    "unjack", "requestUnjack", "releaseJack", "release", "exitJack", "stopJack", "stop",
}
-- ⭐ MEASURED 2026-08-08, not guessed. app.AdjustJack declares exactly THREE release-ish
-- methods: `reject`, `rejectSelf`, `stopOwnerProcess`. We were only ever calling rejectSelf,
-- which detaches the jack but demonstrably leaves the body without a controller.
-- ⭐ `stopOwnerProcess` is the interesting one — the jack plays the OWNER's FSM, so the
-- owner-side process is precisely the thing that keeps running after rejectSelf and keeps
-- the clip on the body ("rejectSelf on its own only detaches the jack: the clip keeps
-- playing"). Stopping it is the missing half of the release.
-- ⛔ EVERY CALL GETS ITS OWN pcall. v1 wrapped the whole routine in one, so the first throw
-- aborted the rest silently — which is exactly why the log shows the method dump and then
-- NOT A SINGLE detach line. One failure must never cancel the others.
-- declared up here (not with the hooks below) so _detach can flag its own calls: the tape has
-- to distinguish OUR tear-down from the game's, which is the entire point of taking it.
local tape = { ours = false, n = 0 }

local aj_dumped = false
local function _detach(owner)
    tape.ours = true
    pcall(function()
        if aj_dumped then return end
        aj_dumped = true
        local td = sdk.find_type_definition("app.AdjustJack")
        if not td then return end
        local names = {}
        for _, m in ipairs(td:get_methods()) do
            local l = tostring(m:get_name()):lower()
            -- ⛔ THIS FILTER USED TO END AT "stop", AND THAT IS EXACTLY WHY THE RESTORE HALF
            -- OF THE JACK LIFECYCLE WENT UNFOUND FOR MONTHS: `restartOwnerProcess` and
            -- `enableOwnerFSM` contain none of those words, so the dump confidently reported
            -- "exactly three release-ish methods" and everyone believed it.
            -- ⭐ LAW: a FILTERED method dump is not an API inventory. Widen it, or dump it all.
            if l:find("reject") or l:find("cancel") or l:find("unjack") or l:find("release")
               or l:find("detach") or l:find("exit") or l:find("stop") or l:find("restart")
               or l:find("enable") or l:find("owner") or l:find("jack") then
                names[#names + 1] = tostring(m:get_name())
            end
        end
        _log("AdjustJack release-ish methods: " .. table.concat(names, ", "))
    end)

    local aj = nil
    pcall(function()
        local pgo = _char_go(_player())
        aj = pgo and pgo:call("getComponent(System.Type)", sdk.typeof("app.AdjustJack"))
    end)
    if not aj then return end

    -- ⛔⛔ CORRECTED 2026-08-13 from il2cpp_dump.json (authoritative signatures).
    -- The comment that used to live here was wrong on BOTH counts:
    --   • `stopOwnerProcess` is NOT parameterless — it is
    --     stopOwnerProcess(System.Boolean isJackBaseLayer) — AND it is the ENTRY-side
    --     teardown. Calling it on release re-stops the very thing we want restarted,
    --     with whatever undefined bool happened to be in the register.
    --   • `reject` is reject(via.GameObject RequestOwner, System.Boolean isRequestIdle)
    --     — TWO args. The old caution was right; the guessed SHAPE was wrong.
    -- app.AdjustJack has a SYMMETRIC lifecycle:
    --   ENTRY  doJack -> disableOwnerFSM(bool) + stopOwnerProcess(bool)
    --                  + clearMotionsWithoutBaseLayer() + clearActionManager()
    --   EXIT   enableOwnerFSM()  +  restartOwnerProcess(bool isRequestIdle)
    -- "Owner" = the JACKED BODY, not the gimmick (AdjustJack.OwnerFSM IS app.Human.Fsm).
    -- Detaching WITHOUT the exit half is what left Aurora a GHOST: no collision, and no
    -- weapon draw — sheathe/draw is an ACTION, so a cleared-and-never-restarted
    -- ActionManager silently eats the request.
    -- This exact sequence already ships at GriffinRideProbe - Iris.lua:25129-25131.
    local r1, r2, r3
    pcall(function() r1 = aj:call("rejectSelf") end)
    pcall(function() r2 = aj:call("restartOwnerProcess", true) end)
    pcall(function() r3 = aj:call("enableOwnerFSM") end)
    _log(string.format("  detach: rejectSelf=%s restartOwnerProcess=%s enableOwnerFSM=%s",
        tostring(r1), tostring(r2), tostring(r3)))
    tape.ours = false
end

-- ── FSM introspection ────────────────────────────────────────────────────────────────
-- EMV Engine's proven chain: getTreeCount → get_Layer() CoreHandles → get_tree_object()
-- → get_nodes() → get_full_name(). get_Layer() FIRST, get_trees() only as fallback.
local function _tree_count(fsm)
    local n = nil
    pcall(function() n = fsm:call("getTreeCount") end)
    return tonumber(n) or 0
end

local function _handles(fsm)
    local h = nil
    pcall(function() h = _arr(fsm:call("get_Layer()")) end)
    if h and #h > 0 then return h end
    pcall(function() h = fsm:get_trees() end)
    return type(h) == "table" and h or {}
end

-- returns { real-cased names }, { lowercase → real-cased }
local function _states(fsm)
    local names, set = {}, {}
    if not fsm or _tree_count(fsm) <= 0 then return names, set end
    pcall(function()
        for _, ch in ipairs(_handles(fsm)) do
            local tree = nil
            pcall(function() tree = ch.get_tree_object and ch:get_tree_object() end)
            if tree then
                local nodes = nil
                pcall(function() nodes = tree:get_nodes() end)
                for _, node in ipairs(nodes or {}) do
                    local fn = nil
                    pcall(function() fn = node:get_full_name() end)
                    -- dotted names are node PATHS, not states
                    if fn and fn ~= "" and not tostring(fn):find("%.") then
                        local k = tostring(fn):lower()
                        if not set[k] then set[k] = tostring(fn); names[#names + 1] = tostring(fn) end
                    end
                end
            end
        end
    end)
    return names, set
end

local function _cur_node(fsm)
    local n = nil
    pcall(function() n = fsm:call("getCurrentNodeName", 0) end)
    return n and tostring(n) or nil
end

local function _pick(set, ...)
    if not set then return nil end
    for _, cand in ipairs({ ... }) do
        local hit = set[tostring(cand):lower()]
        if hit then return hit end
    end
    return nil
end

-- ── the terminal / exit vocabulary ───────────────────────────────────────────────────
-- ⛔ 'root' is NOT terminal — it's the behaviour tree's root node, and listing it made
-- an earlier watch tick "release" the instant it read the tree at rest.
local TERMINAL = { actionend = true, finish = true }

local EXIT_LADDER = {
    "EndAction", "EndAction1", "EndActionMale", "EndActionFemale",
    "StandEnd", "Stand", "ActEnd", "EndA", "End1", "End",
    "Awake", "SleepToSit", "ReleaseA", "DigEndA",
}

-- ── classify: the STATE SET is the fingerprint ───────────────────────────────────────
-- No baked table needed when enumeration works. Returns verb, entry state, mode, kind.
-- mode: "loop" = hold the pose until released · "oneshot" = plays out and lets go.
local function _classify(set, name)
    local n = tostring(name or ""):lower()

    -- BELL first: app.Gm50_036_Bell is a dedicated bell class, and the ox-cart bell is
    -- Aurora-confirmed to actually RING when jacked (its sound node lives in the FSM's
    -- binary node data, invisible to a string dump). So a bell has a real chance of
    -- being audible — unlike the drum, which was field-tested SILENT. Test by EAR.
    if n:find("gm50_036") then
        return "Ring", _pick(set, "StartAction", "ActStart", "Start"), "oneshot", "BELL"
    end

    -- ⛔ I REORDERED THIS (BED above CHAIR) ON 08-09 AND IT WAS WRONG — REVERTED, DO NOT REDO.
    --   The theory was that beds classify as CHAIR and so get a hidden seat planted in them.
    --   The log says otherwise, flatly: seats were placed in gm51_071 / gm51_237 / gm51_457 /
    --   gm51_603_01 / gm05_044_01 and NEVER in gm51_115 (the bed), which was already resolving
    --   as "jack BED 'gm51_115_sheet_00'". The bed was never mis-classified, so the reorder
    --   fixed nothing and risked a real regression: any genuine chair that also owns
    --   Sleep/SleepLoop would have become a BED and LOST its native seat.
    if _pick(set, "SitDown") and _pick(set, "SitLoop") then
        -- ⚠ gm05_045_interact_motlist has only TWO clips for these FOUR states
        -- (sit_chair01_loop, end_front) and the FSM lacks the start-node type hash, so
        -- SitDown may play NOTHING. The 33-chair family is the single most likely thing
        -- to misbehave here, which is why the entry is a LADDER and the log names which
        -- rung took. If sitting does nothing in-game, read that line.
        return "Sit", _pick(set, "SitDown", "SitLoop"), "loop", "CHAIR"
    end
    -- ⛔ RESTORED: my revert above accidentally deleted this branch outright, which would have
    --   silently reclassified every campsite/bedroll as BED (or nothing) — a regression in the
    --   act of undoing one. CAMP must stay between CHAIR and BED, exactly where it was.
    if _pick(set, "SitToSleep") then
        return "Rest", _pick(set, "StartAction"), "loop", "CAMP"
    end
    if _pick(set, "Sleep") and _pick(set, "SleepLoop") then
        -- ⚠ this is a POSE, not the game's rest system: no time passes, nothing heals.
        -- ⛔ `Sleep` is present in the graph but is NOT a legal jack entry. Calling
        -- requestJackAndPlayMotion with it hard-CTDs inside the native call. The same sheet has
        -- repeatedly accepted StartAction, so retain only that proven entry. Reaching the later
        -- sleep loop must happen through the owner's native flow, not by entering a mid-graph
        -- state directly. Interactables' native bed unlock is the current route for that.
        return "Lie down", _pick(set, "StartAction"), "loop", "BED"
    end
    if _pick(set, "ActStart") and _pick(set, "ActLoop") then
        return "Sit", _pick(set, "ActStart"), "loop", "SEAT"
    end
    if _pick(set, "Eat") or _pick(set, "Drink") then
        return "Lean", _pick(set, "StartAction"), "loop", "COUNTER"
    end
    if _pick(set, "PickA") and _pick(set, "ReleaseA") then
        return "Use", _pick(set, "PickA"), "loop", "TOOL"
    end
    if _pick(set, "DigStartA") then
        return "Dig", _pick(set, "DigStartA"), "loop", "DIG"
    end
    if _pick(set, "MusicSelect") or _pick(set, "RitualStart") then
        return "Play", _pick(set, "StartAction"), "loop", "MUSIC"
    end

    -- generic: anything with a Loop* state holds, everything else plays out
    local looping = false
    for k, _ in pairs(set) do if k:find("loop") then looping = true break end end
    local entry = _pick(set, "StartAction", "StartAction1", "StartAction2", "StartA",
                             "Start", "ActStart")
    if entry then
        return "Use", entry, (looping and "loop" or "oneshot"), (looping and "WORK" or "ACTION")
    end
    return nil, nil, nil, nil
end

-- How specific is each verdict? Used ONLY to break ties between two FSM components living
-- on the SAME GameObject — a bed's real sleep brain must beat the vestigial chair brain it
-- also carries. Higher = more specific = wins.
local RANK = {
    BED = 6, BELL = 6, CAMP = 5, SEAT = 4, MUSIC = 4,
    COUNTER = 3, CHAIR = 2, TOOL = 2, DIG = 2, WORK = 1, ACTION = 1,
}

-- ⛔⛔ MOVED UP 2026-08-09 — it used to be declared at :1005, BELOW its first use at :597.
-- Lua resolves an undeclared name to a GLOBAL, so `NATIVE_SEAT_KINDS[e.kind]` at :597 was
-- indexing nil and throwing every frame. It never showed because M.enabled defaults false and
-- short-circuits above the _scan() call — which also means it would have detonated silently,
-- inside a pcall, the first time anyone ticked the jack checkbox, making the jack impossible
-- to debug. Declaration order is not a style question in Lua.
-- The reasoning (unchanged): anything that classified as SEAT or COUNTER did so BECAUSE it
-- already owns a working seat/lean FSM. It does not need ours, and ours can only shadow what
-- the real object wanted to offer — cooking, in the campfire's case. CHAIR is the one family
-- that genuinely cannot seat you on its own (no sit-down clip in its bank), which is the
-- entire reason this feature exists.
local NATIVE_SEAT_KINDS = { CHAIR = true }

-- ── the blacklist ────────────────────────────────────────────────────────────────────
-- ⛔ BY NAME, NEVER BY FSM. gm80_054_interact_fsm (a Godsbane door) is ALSO used by
-- innocent gm80_105/gm80_148, so banning the FSM bans the wrong things.
--   • gm80_054 / gm81_032 — Godsbane doors. Endgame/Unmoored critical path, and their
--     entry state is the very common "StartAction" = trivially easy to fire by accident.
--   • gm05_046 + any door/lock — 6 of 11 door prefabs are content gates, whether a jack
--     fires the unlock LOGIC is unproven, and doors MOVE (a jacked body on a
--     big-displacement owner is the griffin node-anim failure class).
--   • gm80_042 / gm80_052 — oxcarts. They drive away with you welded on.
--   • gm80_046 / gm80_048 — ballistae. Siege weapons, not furniture.
local BAN_NAME = {
    "gm80_054", "gm81_032", "gm05_046", "gm80_042", "gm80_052",
    "gm80_046", "gm80_048", "gm81_031",
    -- ⭐ gm80_256 = the COOKING POT. It classifies as a chair (and Aurora confirmed you can
    -- genuinely sit on it), but IrisFarming already owns this gimmick and shows its own
    -- "Cook" prompt — two mods offering different verbs on one object is just confusing.
    -- Farming wins; we stand off.
    "gm80_256",
    -- ⭐⭐ 2026-08-12: farming's cook set GREW (Aurora: "get this prompt on every cookpot/stove/
    -- campfire you can spawn in IRIS furnish"), so the stand-off has to grow with it or the seat
    -- planter starts offering Sit on her campfire cauldron while farming offers Cook on the same
    -- object. This is not hypothetical: the field log caught this filter planting hidden seats in
    -- gm80_062 — a COOK donor — three times, because it has no rank term.
    -- ⚠ `_banned` is a SUBSTRING match, so each entry also covers its _00/_01 variants. Keep this
    -- list in step with `cookpot.gids` in IrisFarming.lua.
    "gm51_381", "gm51_382", "gm51_383",
    "gm80_060", "gm80_061", "gm80_062", "gm80_063", "gm80_064",
}
local BAN_STATE = { "StartUnlockAction", "DoorboltAction_L", "DoorboltAction_R",
                    "Ride_L", "Ride_R", "DriveStart", "DrawAction", "ShootAction" }

local function _banned(name, set)
    local n = tostring(name or ""):lower()
    if n == "" then return "no name" end
    for _, b in ipairs(BAN_NAME) do if n:find(b, 1, true) then return b end end
    local s = _pick(set, table.unpack(BAN_STATE))
    if s then return "state " .. tostring(s) end
    return nil
end

-- ── scan ─────────────────────────────────────────────────────────────────────────────
-- Two throttles, because the two halves cost very different amounts: enumerating every
-- MotionJackFsm2 in the scene is the expensive part and gimmicks do not move, so that
-- list is cached for M.list_secs and only re-derived when things stream. Picking the
-- nearest one in front of you is cheap and runs at M.scan_secs.
local sc = { list_at = 0, at = 0, fsms = {}, near = nil }

local function _refresh_list()
    local out = {}
    pcall(function()
        local scene = sdk.call_native_func(
            sdk.get_native_singleton("via.SceneManager"),
            sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        if not scene then return end
        local found = scene:call("findComponents(System.Type)",
            sdk.typeof("via.motion.MotionJackFsm2"))
        for _, fsm in ipairs(_arr(found)) do
            local go = nil
            pcall(function() go = fsm:call("get_GameObject") end)
            if go and _valid(go) then
                local nm = nil
                pcall(function() nm = tostring(go:call("get_Name")) end)
                out[#out + 1] = { go = go, fsm = fsm, name = nm or "?" }
            end
        end
    end)
    sc.fsms = out
end

-- resolve (and cache) what a target IS. Enumeration is not free, so each entry keeps
-- its verdict for the life of the list.
local function _resolve(e)
    if e.done then return e end
    e.done = true
    local names, set = _states(e.fsm)
    e.set = set
    e.nstates = #names
    local ban = _banned(e.name, set)
    if ban then
        e.ban = ban
        return e
    end
    e.verb, e.entry, e.mode, e.kind = _classify(set, e.name)
    if not e.entry then e.ban = "no entry state" end
    return e
end

local function _scan()
    local now = os.clock()
    if now - sc.list_at > (M.list_secs or 3.0) then
        sc.list_at = now
        _refresh_list()
    end
    if now - sc.at < (M.scan_secs or 0.4) then return end
    sc.at = now
    sc.near = nil

    local pgo = _char_go(_player())
    if not pgo then return end
    local pp, py = _pos(pgo), _yaw(pgo)
    if not (pp and py) then return end
    -- ⛔ measure from MID-BODY, not the feet: gimmick origins hang high (Aurora had to
    -- JUMP to reach an ox-cart bell with a feet-relative window).
    local eye = pp.y + 0.9
    local best, bd, brank = nil, 1e9, -1

    for _, e in ipairs(sc.fsms) do
        if _valid(e.go) then
            local gp = _pos(e.go)
            if gp then
                local dx, dz = gp.x - pp.x, gp.z - pp.z
                local flat = math.sqrt(dx * dx + dz * dz)
                local dy = gp.y - eye
                if flat <= (M.reach or 1.9)
                   and dy <= (M.reach_up or 2.6) and dy >= -(M.reach_down or 2.0) then
                    -- in front of me?
                    local ang = math.abs(_wrap(math.atan(dx, dz) - py))
                    if ang <= math.rad((M.cone or 80.0) * 0.5) then
                        _resolve(e)
                        -- ⛔⛔ ONE GAMEOBJECT CAN CARRY SEVERAL MotionJackFsm2 COMPONENTS —
                        -- ~21% of jackable prefabs do, and crucially ALL 14 BEDS also carry
                        -- the chair FSM (gm05_045_interact_fsm). Distance alone cannot choose
                        -- between two FSMs at the SAME position, so v1 picked arbitrarily and
                        -- Aurora's bed offered "Sit" and then did nothing — it had answered
                        -- with the bed's vestigial chair brain. Rank breaks the tie: the more
                        -- specific behaviour wins, so a bed is a bed.
                        -- ⛔ RANK BEATS DISTANCE OUTRIGHT; distance only breaks ties within a
                        -- rank. A bed is TWO objects (gm51_115_sheet_00 and _01) plus the
                        -- frame, and whichever happened to be nearer used to win — which is
                        -- why Aurora got "Sit" from one side of the bed and "Lie down" from
                        -- the other. The most specific behaviour in reach should always win,
                        -- no matter which part of the furniture you happen to be closest to.
                        -- ⛔ a chair with a hidden native seat inside it must NOT also carry
                        -- our own prompt: the game is already showing "B Sit", and two
                        -- competing labels on one object is exactly what made the bed
                        -- unreadable. The native path wins wherever it applies.
                        local native = (M.native_seat ~= false)
                            and NATIVE_SEAT_KINDS[e.kind or ""] or false
                        -- If Interactables is exposing this object's own native Search point,
                        -- its B prompt and owner-managed flow win over this hand-written E/jack
                        -- path. The heartbeat guard prevents a stale _G after script reset from
                        -- suppressing IRIS forever.
                        local claim = _G.DD2NativeSeats
                        if type(claim) == "table" and claim.owner ~= "IrisHomeLife"
                           and (os.clock() - (tonumber(claim.t) or 0)) < 2.0 then
                            local ln = tostring(e.name or ""):lower()
                            if claim.beds and e.kind == "BED" then native = true end
                            if claim.chores and (ln:find("gm50_", 1, true)
                                                or ln:find("gm10_030", 1, true)) then
                                native = true
                            end
                        end
                        local rank = RANK[e.kind or ""] or 0
                        if not e.ban and not native
                           and (rank > brank or (rank == brank and flat < bd)) then
                            best, bd, brank = e, flat, rank
                        end
                    end
                end
            end
        end
    end
    sc.near = best
end

-- ── the jack (the proven recipe, InteractButton.lua:780) ─────────────────────────────
-- ⛔ ALWAYS build FRESH request instances. v1 of InteractButton reused objects captured
-- from a live game call — those are POOLED, and overwriting Owner/StateName/motionJackFsm
-- on them corrupts engine state. Never mutate a captured request.
local function _req(tn)
    local inst = nil
    pcall(function() inst = sdk.create_instance(tn) end)
    if inst == nil then pcall(function() inst = sdk.create_instance(tn, true) end) end
    if inst ~= nil then pcall(function() inst:add_ref() end) end
    return inst
end

-- turn the body to face the object before jacking, so the pose does not start sideways.
-- ⛔ the yaw delta is COMPOSED onto the LIVE body quat — never invent a player quat
-- (the griffin round-20 law: an invented quat inverts the rendered body).
local function _face(pgo, ch, tgo)
    pcall(function()
        local pp, tp = _pos(pgo), _pos(tgo)
        if not (pp and tp) then return end
        local dy = _wrap(math.atan(tp.x - pp.x, tp.z - pp.z) - (_yaw(pgo) or 0))
        local tf = pgo:call("get_Transform")
        local q0 = tf and tf:call("get_Rotation")
        if not q0 then return end
        local s, c = math.sin(dy * 0.5), math.cos(dy * 0.5)
        local x, y, z, w = q0.x, q0.y, q0.z, q0.w
        -- dq * q0, with dq = (0, s, 0, c)
        local nx = c * x + s * z
        local ny = c * y + s * w
        local nz = c * z - s * x
        local nw = c * w - s * y
        q0.x, q0.y, q0.z, q0.w = nx, ny, nz, nw
        pcall(function() ch:call("set_Rotation", q0) end)
        pcall(function() tf:call("set_Rotation", q0) end)
    end)
end

-- ⛔⛔ THE ANCHORING CORRECTION (Aurora 2026-08-08, screenshots): I claimed a jack always
-- anchors the body to the object, so seat position was free. That is TRUE for the bench /
-- bonfire / oxcart family (gm80_079 ActStart worked first time) and FALSE for the 33-chair
-- family — those prefabs have NO authored sit-down clip in their own bank (only
-- sit_chair01_loop + end_front), and it is the ENTRY clip that carries the movement onto
-- the seat. Jack succeeds, pose plays, body never travels ⇒ she sat down beside her chair.
-- ⇒ SO WE DELIVER HER TO THE SEAT OURSELVES, then jack. Because the jack does not move the
-- body, whatever position we set is where the pose happens. This is NOT the sink hack that
-- launched the Arisen in the tavern scene: that drove the root DOWN into terrain and fed the
-- controller's depenetration. Here we only slide her horizontally onto the seat and leave Y
-- exactly as the ground gave it, so there is nothing for the controller to fight.
local function _seat_snap(e)
    if M.seat_snap == false then return end
    -- only the families that need it; the bench family anchors correctly on its own and
    -- moving her would fight a jack that already works.
    if not (e.kind == "CHAIR" or e.kind == "BED") then return end
    pcall(function()
        local ch = _player()
        local pgo = _char_go(ch)
        local pp, gp = _pos(pgo), _pos(e.go)
        if not (pp and gp) then return end
        local tf = e.go:call("get_Transform")
        local az = tf and tf:call("get_AxisZ")
        -- face along the seat's own forward axis (flip if the chair's Z points backwards —
        -- there is no way to know per-prefab, so it is a config toggle, not a guess in code)
        if az then
            local s = (M.seat_flip == true) and -1.0 or 1.0
            local yaw = math.atan(az.x * s, az.z * s)
            local q = pgo:call("get_Transform"):call("get_Rotation")
            if q then
                q.x = 0.0; q.y = math.sin(yaw * 0.5); q.z = 0.0; q.w = math.cos(yaw * 0.5)
                pcall(function() ch:call("set_Rotation", q) end)
                pcall(function() pgo:call("get_Transform"):call("set_Rotation", q) end)
            end
        end
    end)
    -- ⛔⛔ WHY THE POSITION WRITE IS *NOT* DONE HERE (Aurora, 2nd attempt: "the rotation is
    -- right but missed the chair"). Rotation stuck and position did not, because before the
    -- jack the character controller is still live and depenetrates/re-asserts the body
    -- within the same frame — the same class of fight that launched the Arisen in the tavern
    -- scene. AFTER the jack the FSM is off and nothing is arguing, so the write holds.
    -- ⇒ hand the seat point back and let the caller apply it post-jack, re-asserted for a
    -- few frames while the pose settles.
    local gp = _pos(e.go)
    return gp and { x = gp.x, z = gp.z } or nil
end

-- ⭐⭐ WHY THE SIT LANDED DIFFERENTLY EVERY TIME (Aurora 2026-08-08: "it changes the sit
-- position based on where you press the button"). The entry clip carries the body from
-- WHEREVER IT STARTED — its root motion is a relative journey, not a destination — so a
-- different approach angle means a different finish. We cannot normalise the start (pre-jack
-- position writes get reverted by the live character controller), but we do not need to:
-- once jacked the FSM is off and nothing contests a position write. So let the entry clip
-- play out, THEN settle her onto the seat and hold her there. Same landing every time,
-- from any angle, with the walk-in animation intact.
-- ⛔ X/Z ONLY. Y belongs to the pose and the floor; driving Y is what threw the Arisen into
-- the sky in the tavern scene and it has no business here.
local function _seat_info(go)
    local s = nil
    pcall(function()
        local tf = go:call("get_Transform")
        local p = tf:call("get_Position")
        local az = tf:call("get_AxisZ")
        if not p then return end
        s = { x = p.x, z = p.z, fx = (az and az.x) or 0.0, fz = (az and az.z) or 0.0 }
    end)
    return s
end

-- ⭐ PULL THE CAMERA BACK WHILE SEATED (Aurora: sitting framed her from about 30cm away, and
-- against a wall it is worse because the camera pushes in). app.CameraManager.set_DistanceOffset
-- is the writable lever the griffin mount work already proved, and it resets cleanly to 0.
-- ⛔ SAME LAW AS THE FSM: this MUST return to 0 on every exit path, including script reset.
-- A mod that leaves the player's camera permanently shoved out is a mod that broke their game.
local function _cam_pull(on)
    pcall(function()
        local mgr = sdk.get_managed_singleton("app.CameraManager")
        if mgr then mgr:call("set_DistanceOffset", on and (tonumber(M.cam_pull) or 2.0) or 0.0) end
    end)
end

local function _hold_seat(seat)
    if not seat then return end
    pcall(function()
        local pgo = _char_go(_player())
        local tf = pgo and pgo:call("get_Transform")
        local pp = tf and tf:call("get_Position")
        if not pp then return end
        -- seat_back pushes her deeper into the chair, along the seat's own backward axis
        -- (Aurora: "it might need to go back a bit further in the chair").
        local b = tonumber(M.seat_back) or 0.0
        pp.x = seat.x - (seat.fx or 0) * b
        pp.z = seat.z - (seat.fz or 0) * b
        tf:call("set_Position", pp)
    end)
end

-- Is the layer-0 clip finished? A jacked stand-up does NOT always reach a terminal FSM node
-- (the chair family never does), so waiting for one meant sitting through the whole 4s
-- deadline before control came back — Aurora: "it takes like ~3-5 seconds". The proven tell
-- is the clip's own frame STALLING at EndFrame (InteractButton measured ~0.35s of stall).
local function _l0_done(prev)
    local f, ef = nil, nil
    pcall(function()
        local pgo = _char_go(_player())
        local motion = pgo and _comp(pgo, "via.motion.Motion")
        local layer = motion and motion:call("getLayer", 0)
        if layer then
            f = tonumber(layer:call("get_Frame"))
            ef = tonumber(layer:call("get_EndFrame"))
        end
    end)
    if not f then return false, nil end
    if ef and ef > 0.0 and f >= ef - 0.75 then return true, f end
    -- frame stopped advancing = the clip is parked on its last pose
    if prev and math.abs(f - prev) < 0.01 then return true, f end
    return false, f
end

local sess = nil   -- { e, state, mode, at, exiting, exit_at, l0 }
local pend = nil   -- { e, until_at } — an interact request still trying to take

-- retrying = this is one of many attempts in a burst; stay quiet and skip the per-attempt
-- cleanup (the give-up path does it once). Without this the retry loop would fire a full
-- detach + FSM restore every frame for 1.2s and bury the log in a hundred identical lines.
local function _jack(e, state, is_exit, retrying)
    if not (e and e.go and e.fsm and state) then return false end
    if not _valid(e.go) then return false end
    local ch = _player()
    local pgo = ch and _char_go(ch)
    local aj = pgo and _comp(pgo, "app.AdjustJack")
    if not aj then _log("no AdjustJack on the player"); return false end

    local jr, pmr = _req("app.AdjustJack.JackRequest"), _req("app.AdjustJack.PlayMotionRequest")
    if not (jr and pmr) then _log("jack request objects unavailable"); return false end

    if not is_exit then _face(pgo, ch, e.go) end

    pcall(function() jr:set_field("<Owner>k__BackingField", e.go) end)
    pcall(function() jr:set_field("<Priority>k__BackingField", 4) end)
    pcall(function() pmr:set_field("<Owner>k__BackingField", e.go) end)
    pcall(function() pmr:set_field("<StateName>k__BackingField", state) end)
    pcall(function() pmr:set_field("<IsFullNameState>k__BackingField", false) end)
    pcall(function() pmr:set_field("<motionJackFsm>k__BackingField", e.fsm) end)
    pcall(function() pmr:set_field("<LayerNo>k__BackingField", 0) end)
    pcall(function() pmr:set_field("<StartFrame>k__BackingField", 0.0) end)
    pcall(function() pmr:set_field("<InterpolationFrame>k__BackingField", 30.0) end)
    pcall(function() pmr:set_field("<InterpolationMode>k__BackingField", 1) end)
    pcall(function() pmr:set_field("<InterpolationCurve>k__BackingField", 3) end)

    -- ⛔⛔ FLUSHED, UNBUFFERED, IMMEDIATELY BEFORE THE NATIVE CALL. Three theories about the
    -- cookpot crash have now been wrong (recipe / jacking at all / retry frequency), and the
    -- reason I keep guessing is that a CTD leaves no trace: the last thing in the log is from
    -- long before the fatal call. This line is written and closed BEFORE the call, so if the
    -- game dies inside requestJackAndPlayMotion the log ends on "ABOUT TO JACK" and names the
    -- exact target and state. If the log continues past it, the jack is innocent and the
    -- crash is downstream. One test now distinguishes what argument could not.
    _log(string.format("ABOUT TO JACK: %s state='%s' fsm=%s owner_valid=%s",
        tostring(e.name), tostring(state), tostring(e.fsm ~= nil), tostring(_valid(e.go))))
    local ok = nil
    pcall(function()
        ok = aj:call("requestJackAndPlayMotion(app.AdjustJack.JackRequest, app.AdjustJack.PlayMotionRequest)",
            jr, pmr)
    end)
    _log("  ...survived the jack call, returned " .. tostring(ok))
    if not (retrying and ok ~= true) then
        _log(string.format("jack %s '%s' state=%s -> %s", tostring(e.kind), tostring(e.name),
            tostring(state), tostring(ok)))
    end

    -- ⛔⛔⛔ A REFUSED JACK IS NOT A NO-OP — THIS WAS THE FREEZE (Aurora 2026-08-08, log
    -- 13:36:06: SitDown -> nil, SitLoop -> nil, then she could not move or use any control
    -- until a script reset). requestJackAndPlayMotion evidently ATTACHES and disables the
    -- player FSM before it decides it cannot play the requested state, so a "false" return
    -- leaves the body parked with no controller AND no session on our side — meaning none of
    -- the safety nets (move-release, the dead-man's timer) were even watching, because they
    -- all hang off a session that was never created.
    -- ⇒ FAILURE MUST CLEAN UP AFTER ITSELF. Never return from here having left the player
    -- without a controller. Same law as the release path: the FSM goes back on, always.
    if ok ~= true then
        _detach()
        _fsm_on()
        if not retrying then
            _log("  ^ refused: detached + FSM restored (a refusal used to freeze the controls)")
        end
    end
    return ok == true
end

-- ── release ──────────────────────────────────────────────────────────────────────────
-- HARD: detach and snap the body to a neutral clip. Abrupt but always works.
-- ⛔ this must NOT depend on there being a session — the body can still be playing a
-- jack clip after the session died, and that exact case is what "I couldn't get out of
-- it" was in InteractButton. A hard release always detaches and re-asserts.
-- ⛔⛔ THE FREEZE FIX (Aurora 2026-08-08: "tried to enter my house but now I can't move").
-- A chair's StandEnd never reached a terminal node, the 4s deadline fired, we hard-released
-- — and she was left unable to move. rejectSelf DETACHES the jack but does not hand control
-- back: the jack parks the player's FSM, so with the FSM still disabled the body sits in
-- whatever clip was last written and ignores input forever. InteractButton half-knew this
-- ("rejectSelf on its own only detaches the jack; the clip keeps playing").
-- ⇒ RESTORING THE FSM IS THE RELEASE. The motion write is only cosmetic tidying, and it
-- MUST come after the FSM is live or it is the very thing she's frozen inside.
-- This is IrisFurnish's locked-controls law: never leave the player FSM-disabled, on ANY
-- exit path, including ones we reached by timeout or by error.
-- If the FSM restore IS firing and the weapon controls are still dead, then the body is not
-- the problem — the ACTION is. A jack runs the player through app.ActionManager, and an action
-- left current after the jack detaches would keep sheathing and equipping locked out exactly
-- as described. This reports what she's parked in after a release, and dumps the manager's own
-- "current"-shaped methods once so the real reader is named rather than guessed at.
local act_dumped = false
local function _action_diag(tag)
    pcall(function()
        local pl = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
        local am = pl and pl:call("get_ActionManager")
        if not am then _log("  action diag: no ActionManager"); return end
        if not act_dumped then
            act_dumped = true
            local names = {}
            for _, m in ipairs(am:get_type_definition():get_methods()) do
                local n = tostring(m:get_name())
                if n:lower():find("current") or n:lower():find("cancel") then names[#names + 1] = n end
            end
            _log("  ActionManager current/cancel methods: " .. table.concat(names, ", "))
        end
        for _, g in ipairs({ "get_CurrentActionName", "getCurrentActionName",
                             "get_CurrentActionID", "get_CurrentAction" }) do
            pcall(function()
                local v = am:call(g)
                if v ~= nil then
                    _log(string.format("  action after %s: %s = %s", tostring(tag), g, tostring(v)))
                end
            end)
        end
    end)
end

-- ⛔⛔ THE RECOVERY OF LAST RESORT. "No way to fix without restarting the save" is the worst
-- sentence in Aurora's report, so this exists to make that untrue. It fires EVERY
-- parameterless cancel/reset-shaped method the player's ActionManager declares, and logs each
-- one — the same shotgun-then-read-the-log method that found stopOwnerProcess when reasoning
-- had failed three times. Deliberately NOT part of the normal release: this is blunt, and it
-- only runs when the player explicitly presses the panic key, by which point they are already
-- stuck and a blunt instrument beats reloading.
local function _action_reset()
    pcall(function()
        local pl = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
        local am = pl and pl:call("get_ActionManager")
        if not am then _log("recovery: no ActionManager"); return end
        local td = am:get_type_definition()
        local fired = {}
        for _, m in ipairs(td:get_methods()) do
            local n = tostring(m:get_name())
            local l = n:lower()
            if (l:find("cancel") or l:find("reset") or l:find("clear") or l:find("interrupt"))
               and (tonumber(m:get_num_params() or 1) or 1) == 0 then
                local r = nil
                if pcall(function() r = am:call(n) end) then
                    fired[#fired + 1] = n .. "=" .. tostring(r)
                end
            end
        end
        _log("recovery: fired " .. (#fired > 0 and table.concat(fired, ", ") or "NOTHING (no zero-arg cancel methods)"))
    end)
    -- and re-assert the body itself: neutral clip on layer 0, FSM live, no think-stop
    pcall(function()
        local pgo = _char_go(_player())
        local motion = pgo and _comp(pgo, "via.motion.Motion")
        if motion then
            motion:call("getLayer", 0):call(
                "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                0, 0, 0.0, 4.0, 1, 1)
        end
    end)
end

local function _hard(reason)
    -- pass the owner so `reject(owner)` can fire too; clear any in-flight request first, or
    -- a retry armed a moment ago would cheerfully re-seat her the frame after a release.
    -- despawn any invisible seat this session owned, or the world quietly fills with seats
    -- you cannot see and can never find again.
    local owned = (sess and sess.owned) or (pend and pend.owned) or nil
    -- ⛔ THE DEFERRED-GRANT CONTRACT (same law as milking/egg gathering): on_done fires
    -- EXACTLY ONCE, on EVERY exit path — finished, interrupted, timed out, panic key. The
    -- caller has already paid its cost up front, so a path that forgets to call this is a
    -- path that silently eats the player's ingredients.
    local done = sess and sess.on_done or nil
    if sess then sess.on_done = nil end
    pend = nil
    _detach(sess and sess.e and sess.e.go or nil)
    _fsm_on()                                   -- ⛔ then hand the controller back.
    _cam_pull(false)                            -- ⛔ and always give the camera back too
    if owned then
        pcall(function() if owned:call("get_Valid") == true then
            owned:call("destroy(via.GameObject)", owned) end end)
        pcall(function() owned:release() end)
    end
    pcall(function()
        local pgo = _char_go(_player())
        local motion = pgo and _comp(pgo, "via.motion.Motion")
        if motion then
            local layer = motion:call("getLayer", 0)
            layer:call("changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                0, 0, 0.0, 6.0, 1, 1)
        end
    end)
    sess = nil
    _log("released HARD (" .. tostring(reason) .. ") + FSM restored")
    if fsm_diag <= 6 then _action_diag(reason) end
    if done then pcall(done, reason) end
end

-- GRACEFUL: play the FSM's own stand-up, then detach when the graph hits its terminal.
local function _release(reason, force)
    if not sess then return _hard(reason or "no session") end
    if force then return _hard(reason) end
    local exit = _pick(sess.e.set, table.unpack(EXIT_LADDER))
    if not exit or sess.exiting then return _hard(reason) end
    sess.exiting = true
    sess.exit_at = os.clock() + (M.exit_grace or 4.0)
    if not _jack(sess.e, exit, true) then return _hard(reason) end
    _log("exiting via '" .. tostring(exit) .. "' (" .. tostring(reason) .. ")")
end

-- ═════════════════════════════════════════════════════════════════════════════════════
-- ⭐⭐⭐ THE INVISIBLE SEAT (gm80_166) — why the chair pose kept missing the chair
--
-- Three field results together explain it. The bonfire/bench family (gm80_079, gm80_065…)
-- seats the body correctly. The 33-chair family never does, no matter where we put her
-- first. And pre-jack position writes get reverted while post-jack ones do not.
-- ⇒ **A JACK ANCHORS THE BODY TO THE OWNER'S SKELETON — AND CHAIRS HAVE NO SKELETON.**
-- The bench family ships `gm80_079/gm80_065.skeleton`; the chair prefabs are static meshes
-- with an FSM and nothing to anchor to, so their pose simply plays wherever the body stands.
-- No amount of positioning code can fix that: there is no anchor to position *to*.
--
-- ⭐ Capcom's own answer is `gm80_166` — a seat made of nothing but a skeleton and an
-- animation FSM: no mesh, no collider, 2 joints (`root` + **`sit`**), and the REAL authored
-- `sit_chair01_start_front` clip that the 33 chairs are missing from their own bank.
-- ⇒ spawn one at the chair, jack THAT, and the chair becomes scenery. Anchored by design.
--
-- ⚠ `gmSeat_motbank` has NO female variant, so a female Arisen plays the male clips here.
--   Worth an eye check — if it reads wrong, the alternative is gmaiinteract_03 (ground sit),
--   which does ship a `_female_motlist`.
-- ⛔ Universal coords for the spawn (`_InitialPosition` is via.Position doubles). We read the
--   chair's own get_UniversalPosition, so there is no delta arithmetic to get wrong.
-- ⛔ One proxy at a time, owned by the session, destroyed on release — an orphaned invisible
--   seat is invisible furniture you can never find again.
-- ═════════════════════════════════════════════════════════════════════════════════════
local PROXY_KINDS = { CHAIR = true }
local SNAP_KINDS  = { CHAIR = true, SEAT = true }   -- things with an actual seat point
-- what gets an invisible native seat tucked into it. Beds are deliberately absent: the game
-- already puts its own "Sleep" prompt on them, and competing with that is what produced two
-- contradictory labels on the same bed.
-- ⛔⛔ CHAIRS ONLY — and this is a RULE, not a blacklist (Aurora 2026-08-08: "the campfire
-- isn't a chair though, it still says sit and you can sit in the fire"). I first excluded the
-- camp family by NAME, which was whack-a-mole: her campfire is gm51_381, not gm80_079.
-- NATIVE_SEAT_KINDS was declared HERE until 2026-08-09. It is now up beside RANK, because its
-- first use is at :597 and a local declared after its use site is a nil global. See the comment
-- at the declaration.

-- ⛔⛔ NEVER HIDE A SEAT INSIDE SOMETHING THAT IS ALREADY ONE (Aurora 2026-08-08: the campfire
-- started offering "F Sit" instead of letting her cook). The camp family — gm80_079 campsites,
-- gm80_065..069, gm80_257, gmcamp_* — ARE the very prefabs we spawn as hidden seats. They
-- already carry a working native interact, so adding another does nothing but shadow whatever
-- the real object wanted to offer you. A campfire's job is cooking, and we were sitting on it.
local function _already_a_seat(name)
    local n = tostring(name or ""):lower()
    if n == "" then return false end
    if n:find("gmcamp", 1, true) then return true end
    for _, b in ipairs({ "gm80_079", "gm80_257", "gm80_065", "gm80_066",
                         "gm80_067", "gm80_068", "gm80_069", "gm80_166" }) do
        if n:find(b, 1, true) then return true end
    end
    return false
end
local PROXY = {
    name  = "gm80_166",
    path  = "AppSystem/gimmick/prefab/invisibleinteract/gm80_166.pfb",
    entry = "StartAction",
}
local job = nil   -- { stage, f, prefab, ctrl, inst, container }
local proxy_seq = 0
-- the native-prompt experiment: spawn a candidate in front of you and just LOOK at it. If the
-- game puts its own "B Sit" up, we have our answer and most of this module can be deleted.
local test = { go = nil, pick = 1, pending = false }

-- ⭐ THE NATIVE-SEAT CANDIDATES. `gm80_079_interact_pl` is the standout: the campsite family
-- ships SEPARATE _pl (player), _npc and _bonfire interact prefabs, and a prefab that exists
-- specifically for the player is the obvious source of a native "B Sit" prompt.
-- `gmcamp_00` is the other strong one — its graph is StartAction → Loop → SitToSleep →
-- SleepStart → SleepLoop → SleepToSit, i.e. sit / doze off / get up, exactly the option list
-- in Aurora's screenshot — and it is meshless AND collisionless, so it hides inside a chair
-- with nothing to clip against.
local SEAT_CANDIDATES = {
    { name = "gm80_079_interact_pl", path = "AppSystem/gimmick/prefab/camp/gm80_079_interact_pl.pfb" },
    { name = "gmcamp_00",            path = "AppSystem/gimmick/prefab/camp/gmcamp_00.pfb" },
    { name = "gm80_257",             path = "AppSystem/gimmick/prefab/camp/gm80_257.pfb" },   -- ✅ WORKS
    { name = "gm80_065",             path = "AppSystem/gimmick/prefab/camp/gm80_065.pfb" },   -- ✅ WORKS
    -- the NPC-flavoured interact. It gave no PLAYER prompt, which is exactly what you'd expect
    -- if it is the AI's seat rather than ours — worth spawning and watching whether pawns or
    -- NPCs help themselves to it unprompted.
    { name = "gm80_079_interact_npc", path = "AppSystem/gimmick/prefab/camp/gm80_079_interact_npc.pfb" },
    -- ⭐ THE BROOM PROBE. gm50_007 carries the broom mesh as a CHILD of its own prefab
    -- ("Mesh_Broom") and its motlist has ConstraintGimmickTrack + SyncHandIKControlTrack —
    -- the two tracks whose whole job is binding the gimmick's own prop into the hand. The
    -- famous "empty spade" result may have been the wrong gimmick entirely (there is no spade
    -- gimmick; gm50_096 is the hoe station). Spawn it, jack the PAWN to it, look at the hands.
    -- If the broom binds, ~30 ConstraintGimmick props unlock at once (bucket, axe, hoe, wood).
    { name = "gm50_007", path = "AppSystem/gimmick/prefab/interact/gm50_007.pfb" },
    { name = "gm50_013", path = "AppSystem/gimmick/prefab/interact/gm50_013.pfb" },   -- bucket
    { name = "gm80_166",             path = "AppSystem/gimmick/prefab/invisibleinteract/gm80_166.pfb" },
}

-- general spawner: any prefab, at any universal position + rotation. Both the chair proxy and
-- the native-prompt experiment go through this, so there is one spawn path to get right.
local function _gimmick_job(name, path, up, rq)
    job = nil
    local ok = pcall(function()
        local gid
        local fld = sdk.find_type_definition("app.GimmickID"):get_field((name:gsub("^gm", "Gm")))
        if fld then gid = fld:get_data() end
        if not gid then _log("spawn: no app.GimmickID enum for " .. name); return end
        if not (up and rq) then return end

        local prefab = sdk.create_instance("via.Prefab"):add_ref()
        prefab:set_Path(path)
        pcall(function() prefab:set_Standby(true) end)
        local ctrl = sdk.create_instance("app.PrefabController"):add_ref()
        ctrl._Item = prefab
        pcall(function() ctrl:get_Item():set_Standby(true) end)
        local inst = sdk.create_instance("app.InstanceInfo"):add_ref()
        local container
        pcall(function() container = inst:get_Container() end)
        if not container then
            container = sdk.create_instance("app.GenerateInfo.GenerateInfoContainer"):add_ref()
        end
        local pos = ValueType.new(sdk.find_type_definition("via.Position"))
        pos.x, pos.y, pos.z = up.x, up.y, up.z
        local cat = 5
        pcall(function()
            local f2 = sdk.find_type_definition("app.GeneratorCategory"):get_field("Gimmick")
            if f2 then cat = f2:get_data() end
        end)
        pcall(function() container._CommonInfo._Category = cat end)
        pcall(function() container._CommonInfo._ObjectID._SelectedGimmickID = gid end)
        pcall(function() container._CommonInfo._InitialPosition = pos end)
        pcall(function() container._CommonInfo._ContextPosition = pos end)
        pcall(function() container._CommonInfo:setContextPosition(pos) end)
        -- setInitialAngle ONLY — context/raw-field angle writes poison the spawn (the
        -- invisible-sign bisect). We copy the CHAIR's own rotation, so the seat faces
        -- exactly where the chair faces and there is no yaw guess to get wrong.
        pcall(function()
            local rqt = ValueType.new(sdk.find_type_definition("via.Quaternion"))
            rqt.x, rqt.y, rqt.z, rqt.w = rq.x, rq.y, rq.z, rq.w
            container._CommonInfo:setInitialAngle(rqt)
        end)
        pcall(function() container._StatusInfo["<ScaleRate>k__BackingField"] = 1.0 end)
        job = { stage = "wait", f = 0, prefab = prefab, ctrl = ctrl,
                inst = inst, container = container }
    end)
    if not ok then job = nil; _log("spawn: build failed for " .. tostring(name)) end
    return job ~= nil
end

local function _proxy_request(e)
    local tf = e.go:call("get_Transform")
    return _gimmick_job(PROXY.name, PROXY.path,
        tf and tf:call("get_UniversalPosition"), tf and tf:call("get_Rotation"))
end

-- returns the spawned GameObject once it exists, or nil while still working / on failure
local function _proxy_pump()
    if not job then return nil end
    job.f = (job.f or 0) + 1
    if job.stage == "wait" then
        local ready = false
        pcall(function() ready = job.prefab:get_Ready() == true end)
        if ready then
            proxy_seq = proxy_seq + 1
            local okr = pcall(function()
                local gen = sdk.get_managed_singleton("app.GenerateManager")
                gen:call("requestCreateInstance(app.PrefabController, app.GenerateInfo.GenerateInfoContainer, System.Int32, app.InstanceInfo, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>)",
                    job.ctrl, job.container, 744000 + proxy_seq, job.inst, nil, nil)
            end)
            if okr then job.stage, job.f = "poll", 0 else job = nil; _log("proxy: create refused") end
        elseif job.f > 600 then job = nil; _log("proxy: prefab never became ready") end
        return nil
    end
    if job.stage == "poll" then
        local go
        pcall(function() go = job.inst:get_Instance() end)
        if go then
            pcall(function() go:add_ref() end)
            job = nil
            _log("proxy: invisible seat spawned")
            return go
        end
        if job.f > 600 then job = nil; _log("proxy: instance never arrived") end
    end
    return nil
end

-- wrap a freshly spawned proxy seat as a jack target. It reports kind SEAT so the rest of
-- the system treats it like the bench family — which is exactly what it is: a skeleton the
-- jack can anchor to, and therefore nothing for _seat_snap to correct.
local function _proxy_seat_target(go)
    local fsm = nil
    pcall(function()
        fsm = go:call("getComponent(System.Type)", sdk.typeof("via.motion.MotionJackFsm2"))
    end)
    if not fsm then return nil end
    local _, set = _states(fsm)
    local entry = _pick(set, PROXY.entry, "StartAction", "ActStart") or PROXY.entry
    return { go = go, fsm = fsm, set = set, name = PROXY.name .. " (invisible seat)",
             kind = "SEAT", verb = "Sit", entry = entry, mode = "loop" }
end

-- ═════════════════════════════════════════════════════════════════════════════════════
-- ⭐⭐⭐ NATIVE SEATS — the route that finally works, and it needs no jack at all
--
-- PROVEN IN THE FIELD 2026-08-08 (Aurora): spawning `gm80_257` or `gm80_065` gives a genuine
-- **"B Sit"** prompt and a genuine **"A Get Up"** — the GAME runs the whole thing. And her
-- screenshot shows no object at all, because those prefabs are MESHLESS. So an invisible seat
-- tucked inside a chair reads, to the player, as simply "this chair is sittable".
--
-- ⭐ WHY THIS BEATS EVERYTHING ABOVE: the game owns the EXIT. Every broken-controls report
-- this session came from our hand-rolled tear-down. Native exit, no tear-down, no bug.
-- ⛔ AND WHY A PROXY IS UNAVOIDABLE (the thing to stop re-litigating): `gm80_065` ships its
-- own SKELETON and the sit pose is anchored to it. You cannot move the interact onto a chair,
-- because the animation is not a permission the chair lacks — it is data the chair does not
-- have. This is exactly how the custom crops already work: a growing crop IS a real gather
-- node, scaled down; the native prompt appears because it genuinely is one.
--
-- Lifecycle: ONE seat at a time, parked in whichever chair you are nearest, moved when you
-- approach a different one, removed when you walk away. Independent of M.enabled, because
-- this path never touches the player's FSM and so carries none of the jack's risk.
-- ⭐⭐ MANY SEATS, NOT ONE (Aurora: "can pawns use it naturally too?"). v1 kept a single seat
-- parked in whichever chair the PLAYER was nearest — which a pawn can never use, because the
-- chair only becomes sittable while you personally stand beside it. Every chair in the room
-- now gets its own hidden seat, which also removes the pop-in when you walk between them.
-- Keyed by the chair's GameObject address so a chair is never double-seated.
local nseat = { at = 0, list_at = 0, seats = {}, pending = nil }

local function _nseat_kill(rec)
    if not (rec and rec.go) then return end
    pcall(function()
        if rec.go:call("get_Valid") == true then rec.go:call("destroy(via.GameObject)", rec.go) end
    end)
    pcall(function() rec.go:release() end)
end

local function _nseat_drop()
    for k, rec in pairs(nseat.seats) do _nseat_kill(rec); nseat.seats[k] = nil end
    nseat.pending = nil
end

local function _nseat_count()
    local n = 0
    for _ in pairs(nseat.seats) do n = n + 1 end
    return n
end

local function _nseat_tick()
    if M.native_seat == false then _nseat_drop(); return end

    -- ⭐ STAND DOWN FOR A DEDICATED SEAT MOD (Interactables). It plants the identical donor at
    -- the identical transform, and two donors in one chair means two native prompts — the exact
    -- thing that made the bed unreadable. One owner only.
    -- ⛔ THE TIMESTAMP IS LOAD-BEARING, NOT DECORATION. Whether _G survives a REFramework script
    -- reset is unverified, so a claim left behind by a mod that has since been UNINSTALLED must
    -- not silently disable IRIS's seats forever. A heartbeat older than 2s is treated as gone.
    local claim = _G.DD2NativeSeats
    if type(claim) == "table" and claim.owner ~= "IrisHomeLife"
       and (os.clock() - (tonumber(claim.t) or 0)) < 2.0 then
        if next(nseat.seats) ~= nil or nseat.pending then _nseat_drop() end
        return
    end
    if _loading() or _menu_open() then return end
    local now = os.clock()

    -- collect the spawned object once it arrives (ONE spawn in flight at a time — the job
    -- slot is single, and a volley of gimmick spawns is the sequencing hazard IrisFurnish
    -- already learned to respect)
    if nseat.pending then
        local go = _proxy_pump()
        if go then
            nseat.seats[nseat.pending.key] = { go = go, name = nseat.pending.name }
            _log("native seat: placed in " .. tostring(nseat.pending.name)
                .. " (" .. _nseat_count() .. " live)")
            nseat.pending = nil
        elseif job == nil then
            _log("native seat: spawn failed for " .. tostring(nseat.pending.name))
            nseat.pending = nil
        end
        return
    end
    if job then return end                      -- someone else is using the spawn slot

    if now - nseat.list_at > 3.0 then nseat.list_at = now; _refresh_list() end
    if now - nseat.at < 0.5 then return end
    nseat.at = now

    local pgo = _char_go(_player())
    local pp = pgo and _pos(pgo)
    if not pp then return end

    -- 1. every seat-shaped thing in range, keyed by its own address
    -- ⛔⛔⛔ RANK FIRST, THEN FILTER (fixed 2026-08-09). A bed is TWO MotionJackFsm2 components
    -- on ONE GameObject — its real Sleep brain PLUS a vestigial copy of the chair FSM — so
    -- _refresh_list emits two entries at the same address and the CHAIR one used to sail
    -- straight through this filter. Aurora's own log: 142 hidden sit-stools planted into
    -- gm51_603_01 (119), gm51_396 (18), gm51_409/_01 (4), gm51_460 (1) — every one a BED that
    -- already shows the game's own Sleep prompt, which ours then shadowed.
    -- ⛔ The in-code rebuttal that used to sit at :398 checked gm51_115 — the SHEET, not the
    -- hosts that were actually being seated. _scan has always done this properly (RANK beats
    -- distance, :596-602); the native-seat path never did. Now it does: an entry only counts
    -- if it is the most specific verdict at its own address.
    local want, range = {}, (M.native_seat_range or 12.0)
    local inrange, top = {}, {}
    for _, e in ipairs(sc.fsms) do
        if _valid(e.go) then
            local gp = _pos(e.go)
            if gp then
                local dx, dz = gp.x - pp.x, gp.z - pp.z
                if math.sqrt(dx * dx + dz * dz) < range then
                    _resolve(e)
                    local k = nil
                    pcall(function() k = e.go:get_address() end)
                    if k then
                        e._addr = k
                        inrange[#inrange + 1] = e
                        -- a banned entry contributes rank 0: it must not be able to veto a
                        -- legitimate CHAIR sharing its GameObject
                        local r = (not e.ban) and (RANK[e.kind or ""] or 0) or 0
                        if r > (top[k] or -1) then top[k] = r end
                    end
                end
            end
        end
    end
    for _, e in ipairs(inrange) do
        local k = e._addr
        if not e.ban and NATIVE_SEAT_KINDS[e.kind or ""]
           and not _already_a_seat(e.name)
           and (RANK[e.kind or ""] or 0) >= (top[k] or 0) then
            want[k] = e
        end
    end

    -- 2. retire seats whose chair has gone out of range, streamed out, or died
    for k, rec in pairs(nseat.seats) do
        if not want[k] or not (rec.go and _valid(rec.go)) then
            _nseat_kill(rec)
            nseat.seats[k] = nil
        end
    end

    -- 3. fill ONE gap per tick, nearest chair first so the one you are walking toward wins
    if _nseat_count() >= (M.native_seat_max or 8) then return end
    local pick, pd = nil, 1e9
    for k, e in pairs(want) do
        if not nseat.seats[k] then
            local gp = _pos(e.go)
            local dx, dz = gp.x - pp.x, gp.z - pp.z
            local d = dx * dx + dz * dz
            if d < pd then pick, pd = { key = k, e = e }, d end
        end
    end
    if not pick then return end

    pcall(function()
        local tf = pick.e.go:call("get_Transform")
        local up, rq = tf:call("get_UniversalPosition"), tf:call("get_Rotation")
        local p = ValueType.new(sdk.find_type_definition("via.Position"))
        p.x, p.y, p.z = up.x, up.y + (M.native_seat_y or 0.0), up.z
        local nm = M.native_seat_prefab or "gm80_257"
        if _gimmick_job(nm, "AppSystem/gimmick/prefab/camp/" .. nm .. ".pfb", p, rq) then
            nseat.pending = { key = pick.key, name = pick.e.name }
        end
    end)
end

-- ⭐⭐ THE JACK IS FLAKY ON THE FIRST ATTEMPT — RETRY IT (Aurora 2026-08-08: "the first time
-- my character just turned around and did nothing"). The log proves the shape: at 13:25:05
-- SitDown and SitLoop were BOTH refused, then the very same state on the very same chair
-- took one second later. One press was therefore a coin flip. The engine appears to refuse a
-- jack while the body is still settling out of locomotion, so the fix is not a different
-- state — it is patience.
-- ⛔ And the turn now happens only AFTER the jack takes. Rotating her up front is what made
-- a failure look like "spun round and did nothing"; a refused interact should leave no trace.
local function _try_pending()
    if not pend then return end
    local now = os.clock()
    if sess then pend = nil; return end
    if not _valid(pend.e.go) then pend = nil; return end

    -- ⛔⛔⛔ THROTTLE THE RETRIES — THIS IS WHAT WAS CRASHING THE COOKPOT (Aurora 2026-08-08:
    -- "it must be something you're doing to initiate it that's different than before").
    -- When the pot jack worked, one press meant ONE or TWO attempts. Then I added the retry
    -- loop to stop a Loop state stealing the entry — and it fires EVERY FRAME for 1.2s, i.e.
    -- ~100 jack requests hammering a gimmick FSM with a state it may not accept. Repeatedly
    -- forcing a state onto a parked FSM is the known hard-crash class in this codebase.
    -- Patience was the right idea; a hundred attempts a second was never what it needed.
    -- ~8 spaced attempts get the same benefit with none of the pounding. Every refusal now
    -- detaches and restores the player FSM before the next attempt; keeping a refused attachment
    -- alive across the retry window was the unsafe state the refusal cleanup was meant to end.
    if now < (pend.next_at or 0) then return end
    pend.next_at = now + (M.retry_interval or 0.15)

    -- ⭐ CHAIR → swap the target for an invisible seat we spawn and own. The chair itself is
    -- never jacked; it just tells us where and which way to face. If anything in the spawn
    -- path fails we fall through to jacking the chair directly, which at least still sits.
    if PROXY_KINDS[pend.e.kind] and M.proxy_seat ~= false and not pend.proxy_done then
        if not pend.asked then
            pend.asked = true
            pend.until_at = now + (M.retry_secs or 1.2) + 4.0   -- spawning needs longer
            if not _proxy_request(pend.e) then pend.proxy_done = true end
            return
        end
        local go = _proxy_pump()
        if go then
            local t = _proxy_seat_target(go)
            if t then
                pend.e, pend.owned = t, go
                _log("proxy: seat ready, jacking it instead of the chair")
            else
                pcall(function() go:call("destroy(via.GameObject)", go) end)
                pcall(function() go:release() end)
                _log("proxy: spawned seat had no MotionJackFsm2 — using the chair")
            end
            pend.proxy_done = true
        elseif job == nil then
            pend.proxy_done = true      -- spawn failed outright; fall back to the chair
        end
        return
    end

    local e = pend.e
    local state = e.entry
    local ok = _jack(e, state, false, true)

    -- ⛔ Never turn a refused entry into a request for SitLoop/ActLoop/Loop. Those are mid-graph
    -- states, not proven entry nodes. Apart from placing the pose where the body already stands,
    -- the bed's fatal `Sleep` call proved that "the state exists" is not enough to make a direct
    -- jack safe. A legal entry may be retried after cleanup; a loop state is never substituted.
    if ok then
        local owned, hold, done = pend.owned, pend.hold, pend.on_done
        pend = nil
        -- a proxy seat is anchored by its own skeleton, so it needs no snapping at all —
        -- _seat_snap only answers for CHAIR/BED and the proxy reports as SEAT.
        _seat_snap(e)                       -- facing (chairs/beds only; a proxy handles its own)
        -- the seat point comes from whatever we actually jacked — proxy or chair, both sit
        -- at the chair's own transform, so this is the same answer either way.
        sess = { e = e, state = state, mode = e.mode, at = now, owned = owned,
                 seat = _seat_info(e.go),
                 -- a TIMED pose (the cookpot): runs for a fixed span and ignores movement,
                 -- because "stir for ten seconds" is a task, not a seat you lounge in.
                 timed = hold ~= nil, hold_until = hold and (now + hold) or nil,
                 on_done = done }
        if (tonumber(M.cam_pull) or 0) > 0 then _cam_pull(true) end
        _log(string.format("  jack TOOK with '%s'", tostring(state)))
        return
    end
    if now >= (pend.until_at or 0) then
        _log(string.format("gave up on %s (entry '%s') after retries",
            tostring(e.name), tostring(e.entry)))
        local owned, done = pend.owned, pend.on_done
        pend = nil
        _detach(e.go)                        -- the one cleanup for the whole burst
        _fsm_on()                            -- never end a failed attempt without control
        -- ⛔ and STILL honour the contract: a caller that paid up front (ingredients already
        -- consumed) must get its callback even when the animation never played at all.
        if done then pcall(done, "jack never took") end
        if owned then                        -- and never orphan a seat we spawned
            pcall(function() if owned:call("get_Valid") == true then
                owned:call("destroy(via.GameObject)", owned) end end)
            pcall(function() owned:release() end)
        end
    end
end

-- ── input ────────────────────────────────────────────────────────────────────────────
local kb = { down = {} }
local function _key_edge(vk)
    local now = false
    pcall(function()
        local hid = sdk.get_native_singleton("via.hid.Keyboard")
        local kbd = hid and sdk.call_native_func(hid,
            sdk.find_type_definition("via.hid.Keyboard"), "get_Device")
        now = kbd and kbd:call("getDown", vk) == true
    end)
    local was = kb.down[vk] == true
    kb.down[vk] = now
    return now and not was
end

local pad = { prev = 0, bit = nil }

-- ⛔ math.floor, NOT tonumber: get_Button can hand back a FLOAT, and Lua 5.4's `&`
-- raises "number has no integer representation" on one. Inside a pcall that failure is
-- silent — the pad would simply never register. IrisFarming's _pad_raw floors it too.
local function _pad_bits()
    local b = 0
    pcall(function()
        local pm = sdk.get_native_singleton("via.hid.GamePad")
        local dev = pm and sdk.call_native_func(pm,
            sdk.find_type_definition("via.hid.GamePad"), "get_MergedDevice")
        if dev then b = math.floor(dev:call("get_Button") or 0) end
    end)
    return b
end

-- Resolve the native interact B / circle bit from the type's own static fields once. The
-- GamePadButton values are not safe to hardcode, and `sdk.enum` is not a REFramework
-- API — td:get_fields() + f:get_data(nil) is the route this codebase already uses.
local function _pad_a_bit()
    if pad.bit ~= nil then return pad.bit end
    pad.bit = 0
    pcall(function()
        local td = sdk.find_type_definition("via.hid.GamePadButton")
        for _, f in ipairs(td:get_fields()) do
            if (f:get_name() == "Cancel" or f:get_name() == "RRight") and f:is_static() then
                pad.bit = math.floor(tonumber(f:get_data(nil)) or 0)
            end
        end
    end)
    _log(string.format("pad B (Cancel/RRight) bit = 0x%X%s", pad.bit,
        (pad.bit == 0) and "  <- NOT RESOLVED, pad input is dead" or ""))
    return pad.bit
end

local function _pad_edge()
    if not M.pad_a then return false end
    local bit = _pad_a_bit()
    if bit == 0 then return false end
    local cur = _pad_bits()
    local hit = (cur & bit) == bit and (pad.prev & bit) ~= bit
    pad.prev = cur
    return hit
end

local function _moving()
    local m = false
    pcall(function()
        local hid = sdk.get_native_singleton("via.hid.Keyboard")
        local kbd = hid and sdk.call_native_func(hid,
            sdk.find_type_definition("via.hid.Keyboard"), "get_Device")
        if kbd then
            for _, vk in ipairs({ 0x57, 0x41, 0x53, 0x44 }) do   -- W A S D
                if kbd:call("getDown", vk) == true then m = true end
            end
        end
    end)
    if m then return true end
    pcall(function()
        local hid = sdk.get_native_singleton("via.hid.GamePad")
        local dev = hid and sdk.call_native_func(hid,
            sdk.find_type_definition("via.hid.GamePad"), "get_MergedDevice")
        local ax = dev and dev:call("get_AxisL")
        if ax and (math.abs(ax.x) > 0.35 or math.abs(ax.y) > 0.35) then m = true end
    end)
    return m
end

-- ── jump suppression ─────────────────────────────────────────────────────────────────
-- ⛔⛔ THE INPUT-PROCESSOR ROUTE IS WRONG AND GAME-BREAKING. IrisFarming v1 hooked
-- app.PlayerInputProcessor and SKIP_ORIGINAL'd a guessed method — those are stages of
-- the input pipeline that LOCOMOTION also runs through, so it froze the whole character
-- ("it stops ALL movement controls and not just jump"). ⭐ THE RIGHT LEVEL IS THE
-- ACTION: hook app.ActionManager.requestActionCore, match the action BY NAME, block only
-- that name. Nothing else in the pipeline is touched.
local jump_block = { on = false, seen = {} }
pcall(function()
    local m = sdk.find_type_definition("app.ActionManager")
        :get_method("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)")
    if not m then _log("jump block: requestActionCore not found"); return end
    sdk.hook(m, function(args)
        if not jump_block.on then return end
        local block = false
        pcall(function()
            -- the PLAYER's ActionManager only — pawns and enemies request through this too
            local cm = sdk.get_managed_singleton("app.CharacterManager")
            local pl = cm and cm:call("get_ManualPlayer")
            local pam = pl and pl:call("get_ActionManager")
            local am = sdk.to_managed_object(args[2])
            if not (am and pam and am:get_address() == pam:get_address()) then return end
            local nm = sdk.to_managed_object(args[4])
            local s = nm and tostring(nm:call("ToString()")) or ""
            if s:find("Jump") then
                if not jump_block.seen[s] then
                    jump_block.seen[s] = true
                    _log("jump block: blocking action '" .. s .. "' at furniture")
                end
                block = true
            end
        end)
        -- ⛔ the pcall above CANNOT return SKIP_ORIGINAL — it would escape the closure,
        -- not the hook. Set `block` in there and act on it out here.
        if block then return sdk.PreHookResult.SKIP_ORIGINAL end
    end, function(r) return r end)
    _log("jump block: hooked requestActionCore (action-level, input pipeline untouched)")
end)

-- ── grab shield ──────────────────────────────────────────────────────────────────────
-- E is also the native GRAB. On a chicken that meant a blood-spattered pickup instead of
-- an egg; on an ox it meant climbing the animal. Same lesson here: while a furniture
-- prompt is up, the PLAYER's grab is skipped whole. Pawns keep their hands.
pcall(function()
    local m = sdk.find_type_definition("app.Human")
        :get_method("requestTryCatch(app.Human.TryCatchType, System.Boolean, System.Boolean, System.Boolean)")
    if not m then _log("grab shield: requestTryCatch not found"); return end
    sdk.hook(m, function(args)
        if not (M.grab_shield and sc.near) then return end
        local block = false
        pcall(function()
            local cm = sdk.get_managed_singleton("app.CharacterManager")
            local pl = cm and cm:call("get_ManualPlayer")
            local this = sdk.to_managed_object(args[2])
            if pl and this and this:get_address() == pl:get_address() then block = true end
        end)
        if block then return sdk.PreHookResult.SKIP_ORIGINAL end
    end, function(r) return r end)
    _log("grab shield: hooked requestTryCatch (player only)")
end)

-- ⛔⛔ THE PANIC KEY LIVES IN ITS OWN TICK, ON ITS OWN, ALWAYS RUNNING. It must work when the
-- feature is DISABLED, when a session was never tracked, and when the main tick has bailed
-- out — because being stuck is precisely the moment you would have switched the feature off,
-- and a rescue you cannot reach is not a rescue. F8, no conditions, no state required.
re.on_frame(function()
    -- the test spawn is pumped HERE, not in the main tick, because the feature ships DISABLED
    -- and the main tick bails out early — the experiment has to run without it.
    -- native seats run here, NOT in the main tick: they must work with the jack disabled,
    -- because they are the safe path and the jack is the one on probation.
    pcall(_nseat_tick)
    pcall(function()
        if test.pending then
            local go = _proxy_pump()
            if go then
                test.go, test.pending = go, false
                _log("TEST SEAT spawned — walk up to it and look for a NATIVE prompt")
            elseif job == nil then
                test.pending = false
                _log("TEST SEAT spawn failed (see lines above)")
            end
        end
    end)
    pcall(function()
        if not _key_edge(M.panic_key or 0x77) then return end
        _log("PANIC KEY pressed — attempting full recovery")
        _hard("panic key")
        _action_reset()
        _log("  ^ recovery done (detach + FSM + action reset + neutral pose)")
    end)
end)

-- ═════════════════════════════════════════════════════════════════════════════════════
-- ⭐⭐⭐ THE EXIT TAPE — watch how the GAME ends a jack, then copy it (Aurora's idea)
--
-- Every failure this session has come from me inventing a tear-down instead of observing the
-- real one. InteractButton hooks the jack ENTRY (requestJack / requestJackAndPlayMotion) and
-- dumps the request fields — but NOTHING has ever hooked the EXIT, so we have never once seen
-- what the game does when you stand up off a real chair. That is the whole missing fact.
--
-- HOW TO USE IT: with this loaded, sit on a VANILLA chair using the game's own prompt and
-- stand up normally. The log then contains the true sequence — which release methods fire, in
-- what order, with what arguments, and what happens to the player's FSM around them. Then we
-- replicate exactly that, instead of guessing at rejectSelf again.
--
-- It also tapes the GAME's own entry parameters, so we can diff them against ours. If the game
-- jacks with a different Priority or LayerNo than our hardcoded 4/0, that alone could be why
-- our jacks tear down badly — and we would never have found it by reading our own code.
-- ⚠ `tape.ours` marks OUR calls so the log can tell our tear-down from the game's.
local function _fsm_state()
    local s = "?"
    pcall(function()
        local h = sdk.get_managed_singleton("app.CharacterManager")
            :call("get_ManualPlayer"):call("get_Human")
        if h and h.Fsm then s = tostring(h.Fsm:get_Enabled()) end
    end)
    return s
end

local function _is_player_jack(args)
    local yes = false
    pcall(function()
        local this = sdk.to_managed_object(args[2])
        local go = this and this:call("get_GameObject")
        local nm = tostring(go and go:call("get_Name") or "")
        yes = nm:find("ch000", 1, true) == 1
    end)
    return yes
end

pcall(function()
    local td = sdk.find_type_definition("app.AdjustJack")
    if not td then _log("exit tape: no app.AdjustJack"); return end

    for _, mn in ipairs({ "reject", "rejectSelf", "stopOwnerProcess" }) do
        local m = td:get_method(mn)
        if m then
            sdk.hook(m,
                -- ⛔⛔⛔ THE TAPE ITSELF WAS THE CRASH (proven by its own log, 2026-08-08).
                -- The engine calls stopOwnerProcess FROM INSIDE requestJackAndPlayMotion to
                -- tear down the previous jack. v1's hook then walked
                -- CharacterManager -> ManualPlayer -> Human -> Fsm to read Enabled — managed
                -- work, re-entrantly, on the exact object the engine was mid-way through
                -- mutating. That is a textbook CTD, and it is why cooking started crashing in
                -- a round where I never touched cooking.
                -- ⇒ A HOOK MUST DO ALMOST NOTHING. Record a number, return. No property
                -- walks, no singleton lookups, no logging (io inside a native call is its own
                -- hazard). The frame tick below drains it where it is safe to do so.
                function(args)
                    tape.n = tape.n + 1
                    tape.pending = mn
                end,
                function(retval) return retval end)
        else
            _log("exit tape: app.AdjustJack has no " .. mn)
        end
    end

    -- the game's OWN entry parameters, to diff against the ones we hardcode
    local rm = td:get_method("requestJackAndPlayMotion")
    if rm then
        sdk.hook(rm, function(args)
            pcall(function()
                if not (M.tape and not tape.ours) then return end
                if not _is_player_jack(args) then return end
                local pmr = sdk.to_managed_object(args[4])
                local jr  = sdk.to_managed_object(args[3])
                local function f(o, n)
                    local v = "?"
                    pcall(function() v = tostring(o:get_field("<" .. n .. ">k__BackingField")) end)
                    return v
                end
                tape.n = tape.n + 1
                _log(string.format(
                    "TAPE %03d  THE GAME JACKED THE PLAYER  state=%s fullname=%s layer=%s "
                    -- ⛔ NO _fsm_state() here either: walking to the player's FSM from inside
                    -- a jack hook is what crashed us. Reading the request's own fields is
                    -- comparatively safe; touching the character the engine is mutating is not.
                    .. "interp=%s mode=%s curve=%s priority=%s",
                    tape.n, f(pmr, "StateName"), f(pmr, "IsFullNameState"), f(pmr, "LayerNo"),
                    f(pmr, "InterpolationFrame"), f(pmr, "InterpolationMode"),
                    f(pmr, "InterpolationCurve"), f(jr, "Priority")))
            end)
        end, function(r) return r end)
    end
    _log("exit tape: installed on reject / rejectSelf / stopOwnerProcess / requestJackAndPlayMotion")
end)

-- ⭐⭐ THE MOTION TAPE (Aurora: "figure out what bank/motion is being played when using the
-- cookpot jack so we can steal that"). Exactly right, and far safer than jacking: once we know
-- the bank+clip, IrisFarming can play it with plain changeMotion — the same mechanism the
-- watering and chore animations already use — with no FSM to drive into a crash.
-- ⛔ You do NOT need the risky cookpot jack to capture it. ANY time the game plays a cooking
-- animation on you (a real campfire cook), this reports the ids. The method names are dumped
-- once rather than guessed, because guessing a method name is what produced a dead detach.
local mtape = { at = 0, last = "", dumped = false }
re.on_frame(function()
    if M.motion_tape == false then return end
    if os.clock() - mtape.at < 0.2 then return end
    mtape.at = os.clock()
    pcall(function()
        local pgo = _char_go(_player())
        local motion = pgo and _comp(pgo, "via.motion.Motion")
        local layer = motion and motion:call("getLayer", 0)
        if not layer then return end

        if not mtape.dumped then
            mtape.dumped = true
            local names = {}
            for _, m in ipairs(layer:get_type_definition():get_methods()) do
                local n = tostring(m:get_name())
                if n:lower():find("motion") or n:lower():find("bank") then names[#names + 1] = n end
            end
            _log("motion layer getters: " .. table.concat(names, ", "))
        end

        local bank, id, nm
        pcall(function() bank = layer:call("get_MotionBankID") end)
        if bank == nil then pcall(function() bank = layer:call("get_BankID") end) end
        pcall(function() id = layer:call("get_MotionID") end)
        pcall(function() nm = layer:call("get_MotionName") end)
        local line = string.format("bank=%s id=%s name=%s", tostring(bank), tostring(id), tostring(nm))
        if line ~= mtape.last then
            mtape.last = line
            _log("MOTION: " .. line)
        end
    end)
end)

-- ── the tick ─────────────────────────────────────────────────────────────────────────
-- ⛔⛔ M.enabled GATES THE PROMPT, **NOT** THE POSE LIFECYCLE (regression 2026-08-08: cooking
-- consumed the eggs, played nothing and granted nothing). `jack_for` arms a pending jack for
-- IrisFarming, but this tick used to bail out at the very first line when the module was
-- disabled — so the pending jack was never attempted and its on_done never fired. A caller
-- that has ALREADY PAID must always get its lifecycle run, whatever our prompt setting is.
-- Worse, a live session's watchdogs (the dead-man's timer, the release) also lived past that
-- early return: disabling the module could have stranded her in a pose with nothing watching.
re.on_frame(function()
    if _loading() then jump_block.on = false; sc.near = nil; return end

    pcall(function()
        -- ⛔ READ BOTH EDGES ONCE, UNCONDITIONALLY, BEFORE ANY BRANCH. Edge detectors are
        -- stateful: if a `return` skips the read, the held-down state goes stale and the
        -- next read reports a fresh press that never happened. Concretely — hold E during
        -- the stand-up, and the frame after the detach would re-jack the chair you just
        -- left, forever. `or` short-circuiting caused the same staleness on the pad.
        local act = _key_edge(M.key)
        if _pad_edge() then act = true end

        -- ⛔ THE PANIC KEY, checked before anything else and independent of every other
        -- piece of state. If our tracking is wrong, if the pose is orphaned, if a hook
        -- threw — this still frees her. It does not care whether we think she is jacked.

        -- ⛔ A MENU OR DIALOGUE IS UP: the edges above were still READ (so nothing goes
        -- stale and the press that dismisses the menu cannot resurface as a fresh press
        -- next frame) — we simply refuse to act on them. The session watchdogs below keep
        -- running, so opening a menu can never strand her in a pose.
        local menu = _menu_open()
        if menu or not M.enabled then act = false end   -- no prompt-driven interaction

        -- an active session: watch for the way out
        if sess then
            sc.near = nil
            jump_block.on = false
            local now = os.clock()

            -- ⛔ THE DEAD-MAN'S SWITCH, ahead of EVERY other check — including the exit
            -- watch, so that even a wedged stand-up cannot hold her. No conditions, no
            -- input required, no dependence on the FSM telling us anything.
            if now > (sess.at or 0) + (M.max_pose or 25.0) then
                return _hard("max pose time")
            end

            -- ⭐ settle her onto the seat AFTER the entry clip has walked her in, then keep
            -- holding for as long as she sits. Held continuously rather than for a fixed
            -- window, because a one-shot correction would drift again the moment the loop
            -- clip's own root motion nudged her.
            -- ⚠ CHAIRS AND PROXY SEATS ONLY. Applying this to a BED made it worse, not better:
            -- a bed's transform origin is the middle of the mattress, not a seat, so settling
            -- her onto it parked her cross-legged in the centre of the bed when perching on
            -- the edge had already looked right. A seat point is only meaningful on a seat.
            if M.seat_snap ~= false and sess.seat and SNAP_KINDS[sess.e.kind or ""]
               and now > (sess.at or 0) + (M.seat_settle or 1.1) then
                _hold_seat(sess.seat)
            end

            if sess.exiting then
                -- the stand-up is playing. Detach when the graph reaches its TERMINAL
                -- (not when EndAction begins — that IS the stand-up), OR when the clip
                -- itself finishes, OR at the deadline. The chair family never reaches a
                -- terminal node, so terminal-only meant eating the whole deadline.
                local cn = _cur_node(sess.e.fsm)
                local fin, fr = _l0_done(sess.l0)
                sess.l0 = fr
                if (cn and TERMINAL[tostring(cn):lower()]) or fin or now > (sess.exit_at or 0) then
                    _hard("exit complete")
                end
                return
            end
            if not _valid(sess.e.go) then return _hard("target streamed out") end
            -- "when you move to cancel it cancels straight away" (Aurora). A graceful exit
            -- means playing the stand-up first, and on the chair family that graph never
            -- terminates — so it always felt laggy. Movement now HARD-releases: instant,
            -- predictable, and it is the same code path that has to be reliable anyway.
            -- a TIMED pose runs to its clock and ignores movement entirely
            if sess.hold_until and now > sess.hold_until then
                return _hard("timed pose complete")
            end
            if M.move_release and not sess.timed
               and now > (sess.at or 0) + 0.25 and _moving() then
                if M.instant_cancel ~= false then return _hard("moved") end
                return _release("moved")
            end
            if sess.mode == "oneshot" then
                local cn = _cur_node(sess.e.fsm)
                if cn and TERMINAL[tostring(cn):lower()] then return _hard("one-shot done") end
                if now > (sess.at or 0) + 12.0 then return _hard("one-shot timeout") end
            elseif (M.hold_secs or 0) > 0 and now > (sess.at or 0) + M.hold_secs then
                return _release("hold elapsed")
            end
            -- pressing the key again gets you out too
            if act then return _release("pressed") end
            return
        end

        -- idle: find what's in front of us. ⛔ Stand fully down behind a menu — no prompt,
        -- and crucially NO jump block, because leaving an action-level block armed while
        -- the player is in menus is exactly how you wedge an action graph.
        -- ⛔ ALWAYS: a pending jack belongs to whoever armed it (the cookpot arms one through
        -- the bridge), and it must be attempted regardless of our prompt setting. Also before
        -- the menu/enabled gates, so turning slightly or opening a menu cannot abandon a
        -- request that is still mid-retry.
        _try_pending()

        if not M.enabled then jump_block.on = false; sc.near = nil; return end
        if menu then jump_block.on = false; sc.near = nil; return end
        _scan()
        local e = sc.near
        jump_block.on = (M.block_jump == true) and (e ~= nil)
        if not e then return end

        local mine = true
        if _G.IrisPrompt then
            if _G.IrisPrompt.native_busy() then mine = false
            else
                local w = _G.IrisPrompt.winner()
                if w and w ~= "home_life" then mine = false end
            end
        end

        -- one press arms a request; _try_pending keeps offering it for a beat (see above)
        if act and mine then pend = { e = e, until_at = os.clock() + (M.retry_secs or 1.2) } end
    end)
end)

-- ── the label (the crop/animal prompt idiom, so it looks like the rest of IRIS) ───────
-- ⛔ draw.* takes ABGR (0xAABBGGRR); IrisFont takes ARGB. Positions here are RENDER
-- space straight off the transform, so no universal delta subtraction.
re.on_frame(function()
    if not (M.enabled and M.prompt) then return end
    if _loading() then return end              -- no labels on loading screens
    if _menu_open() then return end            -- nor behind the pause/rest menus
    pcall(function()
        local txt, gp, col
        -- ⛔ a TIMED pose has no "move to get up" — it runs its clock and lets go by itself.
        -- Telling the player to move when moving does nothing is worse than saying nothing.
        if sess and sess.timed then
            return
        elseif sess and not sess.exiting and sess.mode == "loop" then
            gp = _valid(sess.e.go) and _pos(sess.e.go) or nil
            txt = "Move to get up"
            col = 0xFFB8B8B8                    -- quiet grey: informational
        else
            local e = sc.near
            if not (e and e.verb) then return end
            gp = _pos(e.go)
            local kn = (M.key == 0x45) and "E" or string.format("key %X", M.key or 0)
            txt = string.format("[%s / B]  %s", kn, e.verb)
            col = 0xFFF0D8A0                    -- the warm IRIS prompt gold
            if gp and _G.IrisPrompt then
                local pp = _pos(_char_go(_player()))
                local dd = pp and math.sqrt((gp.x - pp.x) ^ 2 + (gp.z - pp.z) ^ 2) or 1e9
                local hp = Vector3f.new(gp.x, gp.y + (M.prompt_height or 1.0), gp.z)
                _G.IrisPrompt.set("home_life", e.verb, 16, dd, hp, e.go)
            end
            return -- ui020701 is the sole action prompt; do not resurrect the gold fallback
        end
        if not gp then return end
        if _G.IrisPrompt and _G.IrisPrompt.native_world_ready
            and _G.IrisPrompt.native_world_ready("home_life") then return end
        local sp = draw.world_to_screen(
            Vector3f.new(gp.x, gp.y + (M.prompt_height or 1.0), gp.z))
        if not sp then return end
        local F = _G.IrisFont
        if not (F and F.text and F.text(txt, sp.x - #txt * 3.5, sp.y, col, 19)) then
            draw.text(txt, sp.x - #txt * 3.5, sp.y, 0xFFA0D8F0)
        end
    end)
end)

-- ⛔ a script reset must NEVER leave the player welded to a chair with no code left to
-- free her. Detach unconditionally; the furniture itself is untouched (refs only —
-- the destroy-on-reset CTD law).
-- ⛔⛔ UNCONDITIONAL. This used to only act when a session was tracked — which is exactly
-- backwards: the frozen-in-my-own-house case had ALREADY hard-released, so `sess` was nil
-- and a script reset did nothing to free her. A reset must always detach and always hand
-- control back, session or no session. "Reset Scripts" is the player's panic button and it
-- has to work when our bookkeeping is the thing that's wrong.
re.on_script_reset(function()
    jump_block.on = false
    _detach()
    _fsm_on()
    _cam_pull(false)
    -- ⛔ DROP the ref, do NOT destroy: killing a spawned gimmick during a script reset is the
    -- destroy-on-reset CTD law. An orphaned gm80_166 is invisible AND collisionless, so the
    -- worst case is a harmless ghost seat until the area streams out.
    for _, s in ipairs({ sess, pend }) do
        if s and s.owned then pcall(function() s.owned:release() end) end
    end
    sess = nil
    pend = nil
    sc.fsms = {}
    sc.near = nil
    -- the hidden seat is OURS and invisible: leave one behind and it is unfindable furniture
    -- that still offers a prompt in mid-air. Destroy it on reset.
    pcall(_nseat_drop)
    if test.go then pcall(function() test.go:release() end); test.go = nil end
end)

-- ── its own panel ────────────────────────────────────────────────────────────────────
-- Aurora went looking for "Iris HomeLife" in the script list and it wasn't there: the
-- controls only existed nested inside IRIS HOMESTEAD. A module with its own log and its own
-- failure modes deserves its own entry — you should never have to know which OTHER panel a
-- feature was filed under.
local UI = { dump = nil }
re.on_draw_ui(function()
    if not imgui.tree_node("IRIS HOME LIFE (sit / lie / ring the furniture you place)") then return end
    -- ⛔ the ENTIRE body is guarded so that tree_pop() below always runs. One throw inside a
    -- tree escapes every enclosing tree too — which is why a single bad widget produced TWO
    -- "Missing TreePop()" errors and started corrupting the whole overlay.
    pcall(function()
    local c
    -- the SAFE path, on by default: the game does the sitting
    c, M.native_seat = imgui.checkbox("NATIVE SEATS: hide a real seat in chairs (recommended)", M.native_seat ~= false)
    c, M.native_seat_range = imgui.slider_float("  native seat range (m)", M.native_seat_range or 12.0, 2.0, 30.0)
    c, M.native_seat_max   = imgui.slider_int("  max seats at once", M.native_seat_max or 8, 1, 24)
    c, M.native_seat_y     = imgui.slider_float("  native seat height offset (m)", M.native_seat_y or 0.0, -0.8, 0.8)
    imgui.text(string.format("  %d seat(s) live", _nseat_count()))
    -- ⭐ NAME ALONE IS NOT ENOUGH TO FIND ONE (Aurora 08-09: "there's an invisible chair in the
    --   beds"). The log proves no seat was ever placed in gm51_115, so whatever she is standing
    --   next to is one of these hosts sitting NEAR the bed, not in it. Distance turns that from
    --   an argument into a reading: walk to the thing, see which line goes to ~0m.
    do
        local pgo = _char_go(_player())
        local pp = pgo and _pos(pgo)
        for _, rec in pairs(nseat.seats) do
            local d
            pcall(function()
                local sp = rec.go and _pos(rec.go)
                if sp and pp then
                    d = math.sqrt((sp.x - pp.x) ^ 2 + (sp.y - pp.y) ^ 2 + (sp.z - pp.z) ^ 2)
                end
            end)
            imgui.text(string.format("    in %-22s %s", tostring(rec.name),
                d and string.format("%.1fm away", d) or "(no position)"))
        end
    end
    -- ⛔ a way OUT that does not need a game restart: a spawned seat is a live gimmick, so
    --   turning the feature off is the only thing that removes one you do not want.
    if imgui.button("  remove every hidden seat now") then
        for k, rec in pairs(nseat.seats) do _nseat_kill(rec); nseat.seats[k] = nil end
        _log("all hidden seats removed by hand")
    end
    imgui.text("")
    -- the RISKY path, off by default
    c, M.enabled = imgui.checkbox("JACK path (experimental - can lock your controls)", M.enabled ~= false)
    c, M.prompt  = imgui.checkbox("show the native B prompt", M.prompt ~= false)
    c, M.proxy_seat = imgui.checkbox("chairs: jack a spawned gm80_166 invisible seat", M.proxy_seat ~= false)
    c, M.seat_flip  = imgui.checkbox("flip seat facing", M.seat_flip == true)
    c, M.block_jump = imgui.checkbox("suppress jump while a prompt is up", M.block_jump ~= false)
    c, M.reach   = imgui.slider_float("reach (m)", M.reach or 1.9, 0.8, 4.0)
    -- tune the landing yourself rather than waiting on me to guess a number
    c, M.seat_back   = imgui.slider_float("sit deeper into the seat (m)", M.seat_back or 0.10, -0.3, 0.6)
    c, M.seat_settle = imgui.slider_float("settle delay (let the walk-in finish)", M.seat_settle or 1.1, 0.2, 3.0)
    c, M.cam_pull    = imgui.slider_float("pull camera back while posed (m)", M.cam_pull or 2.0, 0.0, 6.0)
    c, M.tape        = imgui.checkbox("EXIT TAPE: log how the GAME enters/leaves a jack", M.tape ~= false)
    imgui.text("   (sit on a VANILLA chair with the game's own prompt, stand up, send the log)")
    c, M.max_pose = imgui.slider_float("max pose seconds (dead-man's switch)", M.max_pose or 25.0, 5.0, 120.0)
    imgui.text("panic key: F8 (works even when disabled)    log: data/IrisHomeLife.log")
    if imgui.button("FULL RECOVERY - unstick me (same as F8)") then
        _hard("panel recovery"); _action_reset()
    end

    local nr = sc.near
    imgui.text(nr and string.format("in front of you: %s -> %s (%s, entry '%s', %d states)",
            tostring(nr.name), tostring(nr.verb), tostring(nr.kind), tostring(nr.entry), nr.nstates or 0)
        or "in front of you: nothing usable")
    if sess then
        imgui.text(string.format("POSE ACTIVE on %s via '%s'%s",
            tostring(sess.e and sess.e.name), tostring(sess.state),
            sess.owned and "  [owns an invisible seat]" or ""))
        if imgui.button("FORCE RELEASE") then _hard("panel") end
    end

    -- ── THE EXPERIMENT THAT DECIDES THE WHOLE DESIGN ────────────────────────────────
    -- If a SPAWNED rest gimmick carries its own native prompt, then chairs can be made
    -- natively sittable by hiding one inside them — native prompt, native Doze Off, native
    -- Get Up, and the game does its own tear-down, which is the exact thing our hand-rolled
    -- release has never managed. Spawn one, walk up, and see if the game speaks first.
    -- ⛔ NO imgui.radio_button — it is not in this REFramework build and threw, which skipped
    -- the tree_pop() below and produced "Missing TreePop()". Only use widgets we already use
    -- elsewhere in IRIS: button, checkbox, slider_float, text, same_line, tree_node.
    if imgui.tree_node("NATIVE SEAT EXPERIMENT##ihl_exp") then
        pcall(function()
        imgui.text("candidate: " .. tostring((SEAT_CANDIDATES[test.pick or 1] or {}).name))
        for i, cnd in ipairs(SEAT_CANDIDATES) do
            if imgui.button(((test.pick == i) and "> " or "  ") .. cnd.name .. "##ihl_cand" .. i) then
                test.pick = i
            end
        end
        if imgui.button("SPAWN IT 1.5m IN FRONT OF ME") then
            local cnd = SEAT_CANDIDATES[test.pick or 1]
            local okp = pcall(function()
                local tf = _char_go(_player()):call("get_Transform")
                local up, rq = tf:call("get_UniversalPosition"), tf:call("get_Rotation")
                local yaw = math.atan(2.0 * (rq.w * rq.y + rq.x * rq.z),
                                      1.0 - 2.0 * (rq.y * rq.y + rq.x * rq.x))
                local p = ValueType.new(sdk.find_type_definition("via.Position"))
                p.x = up.x + math.sin(yaw) * 1.5
                p.y = up.y
                p.z = up.z + math.cos(yaw) * 1.5
                test.pending = _gimmick_job(cnd.name, cnd.path, p, rq)
            end)
            _log(string.format("TEST SEAT: requested %s (%s)", cnd.name, tostring(okp)))
        end
        imgui.same_line()
        if imgui.button("DESPAWN IT") then
            if test.go then
                pcall(function()
                    if test.go:call("get_Valid") == true then
                        test.go:call("destroy(via.GameObject)", test.go)
                    end
                end)
                pcall(function() test.go:release() end)
                test.go = nil
                _log("TEST SEAT despawned")
            end
        end
        imgui.text(test.go and "   a test seat is standing - walk into it and look for a prompt"
                            or "   nothing spawned")

        -- ⭐ THE BROOM TEST. Jacks the PAWN, never the player: a wedged pawn looks silly, a
        -- wedged Arisen is a lockout. The entry state is READ off the spawned object's own FSM
        -- — never a generic ladder guess, which is exactly what hard-crashed on the cookpot.
        if test.go and imgui.button("JACK THE PAWN TO IT (broom/prop test)##ihl_pj") then
            pcall(function()
                -- ⛔ `:call("get_MainPawn")` THREW, which aborted the whole pcall and made the
                -- button do nothing at all — silently, with no log line, because the logging
                -- came after it. AffinityBar uses PROPERTY access (`pawnMgr:get_MainPawn()`),
                -- so use that, try the alternatives independently, and say what happened.
                local pm = sdk.get_managed_singleton("app.PawnManager")
                local pawn = nil
                pcall(function() pawn = pm:get_MainPawn() end)
                if not pawn then pcall(function() pawn = pm:call("get_MainPawn") end) end
                if not pawn then
                    _log("pawn jack: could not resolve the main pawn from app.PawnManager")
                    return
                end
                -- ⭐ `get_MainPawn` returns an **app.Pawn** — a DATA record (affinity,
                -- inclinations, contexts), NOT a body. It has no GameObject, which is why every
                -- route off it failed. RiftSpeak's `_unwrap_character` knows the way through:
                -- **get_CachedCharacter** is the pawn's live Character, and the GameObject
                -- hangs off that. Field spellings kept as fallbacks, same as RiftSpeak's.
                local chara = nil
                pcall(function() chara = pawn:call("get_CachedCharacter") end)
                if not chara then pcall(function() chara = pawn:get_field("<CachedCharacter>k__BackingField") end) end
                if not chara then pcall(function() chara = pawn:call("get_Character") end) end
                if not chara then chara = pawn end
                local pgo2 = nil
                pcall(function() pgo2 = chara:call("get_GameObject") end)
                if not pgo2 then
                    _log("pawn jack: main pawn found (" .. tostring(pawn:get_type_definition():get_full_name())
                        .. ") but no GameObject route worked")
                    return
                end
                local aj = pgo2:call("getComponent(System.Type)", sdk.typeof("app.AdjustJack"))
                local fsm = test.go:call("getComponent(System.Type)",
                    sdk.typeof("via.motion.MotionJackFsm2"))
                if not (aj and fsm) then
                    _log(string.format("pawn jack: aj=%s fsm=%s - cannot proceed",
                        tostring(aj ~= nil), tostring(fsm ~= nil)))
                    return
                end
                local names, set = _states(fsm)
                local entry = _pick(set, "StartAction", "ActStart", "StartA", "PickA", "Start")
                if not entry then
                    _log("pawn jack: no entry state. FSM declares: " .. table.concat(names, ", "))
                    return
                end
                local jr, pmr = _req("app.AdjustJack.JackRequest"), _req("app.AdjustJack.PlayMotionRequest")
                if not (jr and pmr) then return end
                pcall(function() jr:set_field("<Owner>k__BackingField", test.go) end)
                pcall(function() jr:set_field("<Priority>k__BackingField", 4) end)
                pcall(function() pmr:set_field("<Owner>k__BackingField", test.go) end)
                pcall(function() pmr:set_field("<StateName>k__BackingField", entry) end)
                pcall(function() pmr:set_field("<IsFullNameState>k__BackingField", false) end)
                pcall(function() pmr:set_field("<motionJackFsm>k__BackingField", fsm) end)
                pcall(function() pmr:set_field("<LayerNo>k__BackingField", 0) end)
                pcall(function() pmr:set_field("<StartFrame>k__BackingField", 0.0) end)
                pcall(function() pmr:set_field("<InterpolationFrame>k__BackingField", 30.0) end)
                pcall(function() pmr:set_field("<InterpolationMode>k__BackingField", 1) end)
                pcall(function() pmr:set_field("<InterpolationCurve>k__BackingField", 3) end)
                _log("PAWN JACK: state '" .. entry .. "'  (states: " .. table.concat(names, ", ") .. ")")
                local ok
                pcall(function()
                    ok = aj:call("requestJackAndPlayMotion(app.AdjustJack.JackRequest, app.AdjustJack.PlayMotionRequest)", jr, pmr)
                end)
                _log("  ...survived, returned " .. tostring(ok))
            end)
        end
        if test.go and imgui.button("RELEASE THE PAWN##ihl_pj") then
            pcall(function()
                -- ⛔ `:call("get_MainPawn")` THREW, which aborted the whole pcall and made the
                -- button do nothing at all — silently, with no log line, because the logging
                -- came after it. AffinityBar uses PROPERTY access (`pawnMgr:get_MainPawn()`),
                -- so use that, try the alternatives independently, and say what happened.
                local pm = sdk.get_managed_singleton("app.PawnManager")
                local pawn = nil
                pcall(function() pawn = pm:get_MainPawn() end)
                if not pawn then pcall(function() pawn = pm:call("get_MainPawn") end) end
                if not pawn then
                    _log("pawn jack: could not resolve the main pawn from app.PawnManager")
                    return
                end
                local aj = pawn and pawn:call("get_GameObject")
                    :call("getComponent(System.Type)", sdk.typeof("app.AdjustJack"))
                if aj then
                    -- the EXIT half of the jack lifecycle, never the entry-side teardown:
                    -- stopOwnerProcess(bool) re-stops what we are trying to restart.
                    pcall(function() aj:call("rejectSelf") end)
                    pcall(function() aj:call("restartOwnerProcess", true) end)
                    pcall(function() aj:call("enableOwnerFSM") end)
                    _log("pawn released")
                end
            end)
        end
        end)
        -- ⛔ OUTSIDE the pcall: tree_pop MUST run even if the body throws, or imgui's stack
        -- is left unbalanced and the whole overlay starts erroring.
        imgui.tree_pop()
    end

    if imgui.button("WHAT'S AROUND ME? (12m)") then
        _refresh_list()
        local pgo = _char_go(_player())
        local pp = pgo and _pos(pgo)
        local out = {}
        for _, e in ipairs(sc.fsms) do
            local gp = _valid(e.go) and _pos(e.go) or nil
            if pp and gp then
                local dx, dy, dz = gp.x - pp.x, gp.y - pp.y, gp.z - pp.z
                local d = math.sqrt(dx * dx + dz * dz)
                if d <= 12.0 then
                    _resolve(e)
                    out[#out + 1] = { name = e.name, dist = d, dy = dy, kind = e.kind,
                                      verb = e.verb, entry = e.entry, mode = e.mode,
                                      states = e.nstates, ban = e.ban }
                end
            end
        end
        table.sort(out, function(a, b) return a.dist < b.dist end)
        UI.dump = out
    end
    for _, r in ipairs(UI.dump or {}) do
        imgui.text(string.format("  %5.1fm %+5.1fy  %-24s %s", r.dist, r.dy, tostring(r.name),
            r.ban and ("REFUSED: " .. tostring(r.ban))
                  or string.format("%s / %s / %s / entry '%s' (%d states)", tostring(r.verb),
                        tostring(r.kind), tostring(r.mode), tostring(r.entry), r.states or 0)))
    end
    end)
    imgui.tree_pop()
end)

-- ── bridge: slice 2 (pawn idles) and the homestead panel drive this ───────────────────
_G.IrisHomeLife = {
    -- what am I stood in front of, and what would E do? (nil if nothing)
    near = function()
        local e = sc.near
        if not e then return nil end
        return { name = e.name, kind = e.kind, verb = e.verb, entry = e.entry, mode = e.mode }
    end,
    busy = function() return sess ~= nil end,
    -- ⭐ Drive ANY gimmick's own animation for a fixed span, then hand control back and call
    -- on_done. IrisFarming uses this for the cookpot's real stirring animation instead of a
    -- mimed one. Everything this module learned the hard way comes free: the entry state gets
    -- the full retry window (never let a Loop state steal it), the release fires rejectSelf +
    -- stopOwnerProcess + FSM restore, and on_done is guaranteed exactly once on every path.
    -- `prefer` is an ordered list of state names to try before the generic entry ladder.
    jack_for = function(go, secs, prefer, on_done)
        if sess or pend then return false end
        if not (go and _valid(go)) then return false end
        local fsm = nil
        pcall(function()
            fsm = go:call("getComponent(System.Type)", sdk.typeof("via.motion.MotionJackFsm2"))
        end)
        if not fsm then _log("jack_for: no MotionJackFsm2 on that object"); return false end
        local names, set = _states(fsm)
        local entry = (prefer and _pick(set, table.unpack(prefer)))
            or _pick(set, "StartAction", "ActStart", "Start", "StartA")
        if not entry then
            _log("jack_for: no usable entry state; saw: " .. table.concat(names, ", "))
            return false
        end
        local nm = "?"
        pcall(function() nm = tostring(go:call("get_Name")) end)
        pend = {
            e = { go = go, fsm = fsm, set = set, name = nm, kind = "WORK",
                  verb = "Use", entry = entry, mode = "loop" },
            until_at = os.clock() + (M.retry_secs or 1.2),
            hold = tonumber(secs) or 8.0,
            on_done = on_done,
        }
        _log(string.format("jack_for: %s entry '%s' for %.1fs", nm, entry, tonumber(secs) or 8.0))
        return true
    end,
    release = function(reason) _release(reason or "bridge", true) end,
    -- the scan list, for the panel's diagnostics: everything jackable within reach,
    -- including the things we REFUSE and why (the blacklist should be auditable).
    dump = function(radius)
        _refresh_list()
        local pgo = _char_go(_player())
        local pp = pgo and _pos(pgo)
        local out = {}
        for _, e in ipairs(sc.fsms) do
            local gp = _valid(e.go) and _pos(e.go) or nil
            if pp and gp then
                local dx, dy, dz = gp.x - pp.x, gp.y - pp.y, gp.z - pp.z
                local d = math.sqrt(dx * dx + dz * dz)
                if d <= (radius or 12.0) then
                    _resolve(e)
                    out[#out + 1] = { name = e.name, dist = d, dy = dy, kind = e.kind,
                                      verb = e.verb, entry = e.entry, mode = e.mode,
                                      states = e.nstates, ban = e.ban }
                end
            end
        end
        table.sort(out, function(a, b) return a.dist < b.dist end)
        return out
    end,
    cfg = M,
}

_log("IrisHomeLife loaded (jack-driven furniture interaction)")
