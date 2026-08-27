-- ═══════════════════════════════════════════════════════════════════════════════════════
-- INTERACTABLES — make Dragon's Dogma 2's authored world interactions available to the player.
--
-- Walk up to any chair, stool or tavern bench in the world and the GAME offers its own native
-- "Sit" prompt, with its own sit-down animation and its own "Get Up".
--
-- ⭐ WHY THIS IS NEEDED AT ALL: DD2's ~24 seat prefabs carry an interact point whose
-- CharacterType is 8 — **Human only**. Player = bit 0, and it is clear. That is why you watch
-- villagers sit in a tavern all day and cannot join them: the chairs are not missing an
-- animation, the player is authored OUT of them. (Confirmed by reading
-- app.InteractiveObjectData.CharacterTypeEnum off the live game: Player 1, PlayerGroupPawn 2,
-- OtherPawn 4, Human 8, Monster 16.)
--
-- ⭐ HOW: we spawn `gm80_257` — Capcom's own MESHLESS campsite seat, CharacterType 11
-- (Player + PlayerGroupPawn + Human) — at each authored seat position. The game sees a real
-- seat it is allowed to offer you, and runs the whole interaction itself. Your pawns can use
-- them too, because the donor includes the pawn bit.
--
-- ⛔⛔⛔ THE LAW THIS MOD IS BUILT AROUND: WE NEVER TOUCH THE PLAYER'S FSM. Earlier attempts
-- drove the player directly via app.AdjustJack; a refused jack
-- ATTACHES and disables the player FSM *before* deciding it cannot play, which freezes you out
-- of your own character. The stable seat route remains spawn-and-let-go. Experimental props
-- alter only their live eligibility/prompt data. One passive InteractManager.cancelInteract hook
-- prevents a same-frame double cancel; exits themselves use the manager's normal chair route.
--
-- See INTERACTABLES_HANDOVER.md for the earlier research record. Its donor and direct-jack
-- failures remain useful evidence, but its claim that NPC-only props require a hot hook was not
-- tested: the live CharacterType field itself is the narrower lever explored below.
--
--   data/Interactables.json           settings
--   data/Interactables.log            log (OFF by default)
--   data/Interactables/catalog.json   703 gimmick prefabs, parsed offline from the paks
-- ═══════════════════════════════════════════════════════════════════════════════════════

local M = {
    enabled       = true,

    -- ⛔ range/max are the values that ran in the field without complaint. A review once
    -- suggested 6m/4; that regresses the pop-in the many-seats design exists to remove, and an
    -- inn common room has more than four seats.
    range         = 12.0,
    y_window      = 2.5,   -- ⭐ vertical half-height. Without it a scan in a two-storey inn
                           -- spends its whole budget and seat allowance on the floor above.
    max_seats     = 8,
    hysteresis    = 1.25,  -- retire only past range*this, so a seat cannot flicker while you
                           -- shift your weight on the boundary
    donor         = "gm80_257",
    seat_y        = 0.0,
    dedup_radius  = 0.5,

    -- ⭐ a bench has TWO authored seats, a chair one. We plant a donor at each, using the
    -- game's own getInteractPointPosition rather than the object origin.
    per_point     = true,
    max_points    = 4,

    -- ⛔ gm80_257 references an .mcol/.clsp, so it IS solid — but it lands exactly inside the
    -- host's own collider and so adds no obstruction the chair does not already impose. Left
    -- off; flip it if you ever get wedged on thin air.
    neuter_collision = false,

    scan_secs     = 0.5,
    list_secs     = 5.0,
    list_move     = 10.0,  -- ...or re-list early once you have moved this far
    budget        = 64,    -- prefabs classified per pass

    log           = false,

    -- ⭐ EXPERIMENTAL NATIVE UNLOCKS. The authored interaction data uses a character bitmask:
    -- Player=1, PlayerGroupPawn=2, OtherPawn=4, Human=8. Villager chores and ordinary beds
    -- are authored for Human only. We add the Player bit to the LIVE Search point and leave
    -- the rest of the interaction pipeline alone: registration, range, angle, input, owner
    -- callbacks, prop borrowing, motion and release all remain Capcom's code.
    --
    -- Kept opt-in until each owner class has been field-tested. This is materially safer than
    -- a jack (it never disables the player FSM) and narrower than a canPlayerInteract hook.
    native_chores = false,
    native_beds   = false,
    -- Session-only discovery surface. Exposes Human-only Search points broadly so every world
    -- prop can be approached and classified, but still hard-blocks owners already proved to
    -- crash on Player (dough and drum). It is never saved and resets off on process/script load.
    native_discovery = false,
    -- Broad NPC workstations are NOT equivalent to harmless props. gm50_022 proved that its
    -- Player entry works but its NPC-authored EndAction crashes inside manager cancellation.
    -- Keep stations and manager-driven exit dark until each owner family has a proved lifecycle.
    native_workstations = false,
    native_manager_exit = false,
    -- Closed research gate. Both cancelInteract and direct endInteract have now crashed inside
    -- gm50_022. Kept only so stale configs cannot accidentally re-enable the retired lab.
    dough_end_lab = false,
    unlock_secs   = 1.0,
    -- Physical form of DD2's interaction button. The prop's own checkInput becomes false once
    -- many Human-only chores are occupied, so exit detection must not ask the prop itself.
    exit_bind     = "F, circle",

    -- ⭐⭐ STATIONS (Engine C) — every looping Human-only workstation, played with the OWNER's
    -- own authored clips on the player's motion layer. No jack, no InteractManager: the four
    -- crash-proven native exits are never reachable from this engine. Field-proven shape
    -- (gm50_022 dough, 2026-08-12): start -> loop -> AUTHORED end, movement escape and weapon
    -- sheathing both healthy.
    stations       = true,
    st_off         = {},    -- key -> true = this station disabled in the panel

    -- Station camera: CONFIGURE the native camera, never write its transform (the camera
    -- law). Distance via CameraManager DistanceOffset, orbit via synthetic right-stick
    -- injection — both leave DD2's own collision/occlusion correction fully in charge,
    -- which is what keeps this safe in prop-crowded workshops.
    st_cam            = true,
    st_cam_dist       = -1.2,  -- offset while working; drag the other way if the sign is off
    -- (cinematic orbit CUT 2026-08-27: synthetic stick injection ran but the engine
    -- discards it, and mouse axes are getter-only — no honest lever exists.)

    -- anvil workpiece experiment: EquipItemID conjured into the free hand at the smithy
    -- (the anvil is the id-identification lab — 4 = medusa head). 0 = off.
    anvil_id = 0,

    -- ⛔ default MUST sit below every migration: a saved config that predates the key
    -- loads as this default, and a default equal to the latest rev silently skips every
    -- migration (field-proven 2026-08-27: rev-2 default sealed neuter_collision=false in).
    cfg_rev = 0,
}

local CFG  = "Interactables.json"
local CATP = "Interactables/catalog.json"

local function _log(s)
    if not M.log then return end
    pcall(function()
        local f = io.open("Interactables.log", "a")
        if f then f:write(os.date("[%H:%M:%S] ") .. tostring(s) .. "\n"); f:close() end
    end)
end
local function _logf(...) _log(string.format(...)) end

local function _load_cfg()
    pcall(function()
        local t = json.load_file(CFG)
        if type(t) == "table" then for k, v in pairs(t) do if M[k] ~= nil then M[k] = v end end end
    end)
end
local function _save_cfg()
    pcall(function()
        local out = {}
        for k, v in pairs(M) do out[k] = v end
        -- Crash/reload is the lab's dead-man switch. No unrelated settings save may defeat it.
        out.dough_end_lab = false
        out.native_workstations = false
        out.native_manager_exit = false
        out.native_discovery = false
        out.native_lethal = false
        json.dump_file(CFG, out)
    end)
end
_load_cfg()
-- Saved config beats defaults, so improved defaults need a revision bump (the config-rev
-- law). rev 2 (2026-08-27): donor seat colliders neutered by default — the collider fight
-- between the hidden donor and the host chair is the prime suspect for seat shake and
-- fall-through, and the donor sits inside the host's own collider so neutering loses
-- nothing.
if (tonumber(M.cfg_rev) or 0) < 3 then
    -- rev 3 (2026-08-27): rev 2 never actually applied — the default cfg_rev was 2, so
    -- configs saved before the key existed skipped the migration and re-saved
    -- neuter_collision=false. Force it once more at rev 3.
    M.neuter_collision = true
    M.cfg_rev = 3
end
if (tonumber(M.cfg_rev) or 0) < 4 then
    -- rev 4 (2026-08-27 evening): NEUTER OVERTURNED IN FIELD. A collider-less seat loses
    -- its sit prompt entirely — the serve chain ground-checks under the interact point and
    -- the seat's own collider IS that ground. Sit prompts never once coexisted with the
    -- neuter actually running. Shake is the lesser evil; force off, wake pass repairs.
    M.neuter_collision = false
    M.cfg_rev = 4
end
-- Also reject stale/manual true values at startup. Research gates are armed only from this
-- process's UI and always return dark after a restart or script reset.
M.dough_end_lab = false
M.native_workstations = false
M.native_manager_exit = false
M.native_discovery = false
-- The two prefabs with a PROVEN hard CTD (gm50_022 dough, gm10_030 drum). Separate switch so
-- a crash is always attributable to the experiment that caused it. Session-only, like
-- native_discovery: cleared on load and never saved.
M.native_lethal = false
_G.Interactables_dough_hybrid_lab = false

-- ═══════════════════════════════════════════════════════════════════════════════════════
-- THE CATALOG — every gimmick prefab in the game, parsed offline from re_chunk_000.pak.
-- Per prefab:  pc = does it offer the PLAYER any interact point (CharacterType bit 0 set on
-- ANY of its points) · v = all authored verbs · n = interact point count · p = prefab path.
-- ═══════════════════════════════════════════════════════════════════════════════════════
local CAT, cat_n = {}, 0
pcall(function()
    local t = json.load_file(CATP)
    if type(t) == "table" then CAT = t; for _ in pairs(t) do cat_n = cat_n + 1 end end
end)

-- Forward declaration: the Engine C station table lives further down but the native-unlock
-- gate must consult it (stations the safe engine serves are never unlocked natively).
local STATIONS

-- ── helpers ────────────────────────────────────────────────────────────────────────────
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

local function _upos(go)
    local p = nil
    pcall(function() p = go:call("get_Transform"):call("get_UniversalPosition") end)
    return p
end

-- findComponents hands back a System.Array. get_Count/get_Item are LIST methods — they work
-- here by accident and silently truncate if get_Item throws mid-walk. get_elements is correct.
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

local function _addr(o)
    local a = nil
    pcall(function() a = o:get_address() end)
    return a and tostring(a) or nil
end

local function _loading()
    local l = false
    pcall(function()
        local g = sdk.get_managed_singleton("app.GuiManager")
        l = g and g:call("get_IsLoadGui") == true
    end)
    return l
end

-- ⛔ PauseManager is the wrong oracle — DD2's menus do not pause the world. isPausedGUI is the
-- community-proven check.
local function _menu_open()
    local m = false
    pcall(function()
        local gui = sdk.get_managed_singleton("app.GuiManager")
        m = gui and gui:call("isPausedGUI") == true
    end)
    return m
end

-- Raw interaction-button reader. This deliberately mirrors the proven input path in
-- InteractButton.lua and remains local so Interactables does not depend on another autorun file's
-- load order. `circle` is Xbox B / PlayStation Circle; keyboard letters are ordinary VK names.
local PAD_ALIAS = {
    circle = 0x40080, east = 0x40080,
    cross = 0x20020, south = 0x20020,
    square = 0x40, west = 0x40,
    triangle = 0x10, north = 0x10,
    l1 = 0x100, lb = 0x100, l2 = 0x200, lt = 0x200,
    r1 = 0x400, rb = 0x400, r2 = 0x800, rt = 0x800,
    l3 = 0x1000, r3 = 0x2000,
}
local VK_ALIAS = {
    space = 0x20, enter = 0x0D, tab = 0x09, esc = 0x1B, escape = 0x1B,
    shift = 0x10, ctrl = 0x11, alt = 0x12,
}
for i = 0, 25 do VK_ALIAS[string.char(97 + i)] = 0x41 + i end
for i = 0, 9 do VK_ALIAS[tostring(i)] = 0x30 + i end
for i = 1, 12 do VK_ALIAS["f" .. i] = 0x6F + i end

local function _pad_button_mask()
    local mask = 0
    pcall(function()
        local gp = sdk.get_native_singleton("via.hid.GamePad")
        local td = sdk.find_type_definition("via.hid.GamePad")
        local dev = gp and td and sdk.call_native_func(gp, td, "get_MergedDevice")
        if not dev and gp and td then
            dev = sdk.call_native_func(gp, td, "getMergedDevice(System.UInt32)", 0)
        end
        -- Third fallback from the field-proven InteractButton reader: some builds only
        -- answer on get_Device.
        if not dev and gp and td then
            dev = sdk.call_native_func(gp, td, "get_Device")
        end
        if dev then mask = math.floor(tonumber(dev:call("get_Button")) or 0) end
    end)
    return mask
end

local function _binding_down(text)
    text = tostring(text or "")
    local padmask = nil
    for raw in text:gmatch("[^,]+") do
        local token = raw:gsub("^%s+", ""):gsub("%s+$", ""):lower()
        local pbit = PAD_ALIAS[token]
        if pbit then
            padmask = padmask or _pad_button_mask()
            local hit = false
            pcall(function() hit = (padmask & pbit) ~= 0 end)
            if hit then return true end
        else
            local vk = VK_ALIAS[token] or tonumber(token)
            if not vk and token:match("^0x[0-9a-f]+$") then vk = tonumber(token:sub(3), 16) end
            local down = false
            if vk then
                pcall(function() down = reframework:is_key_down(math.floor(vk)) == true end)
            end
            if down then return true end
        end
    end
    return false
end

local function _exit_binding_down()
    return _binding_down(M.exit_bind or "F, circle")
end

-- ⛔ InteractiveObject is a PROPERTY on the gimmick component, not a getComponent target.
-- Never call InteractManager register/unregister: those mutations are proven CTDs. The opt-in
-- session path later uses getActiveInteract and the same high-level cancelInteract route that a
-- healthy native chair uses. It never calls an InteractiveObject release directly.
local function _io_of(go)
    local io = nil
    pcall(function()
        for _, c in ipairs(_arr(go:call("get_Components"))) do
            local v = nil
            pcall(function() v = c.InteractiveObject end)
            if v then io = v; return end
        end
    end)
    return io
end

-- ═══════════════════════════════════════════════════════════════════════════════════════
-- ELIGIBILITY — one data lookup, no heuristics
--
-- IF THE GAME ALREADY OFFERS THE PLAYER ANYTHING ON THIS OBJECT, WE DO NOT TOUCH IT.
-- Two prompts on one object is unreadable, and PriorityForPlayer is Normal on 405 of 409
-- interact points game-wide (Highest on none), so a second prompt could never out-rank the
-- first anyway. The catalog answers it directly:
--     gm05_044 / gm51_071 / gm51_558 ...  pc=0, Sit @ CharacterType 8 → NPC-only → PLANT
--     gm51_603_01                          pc=1, Bed @ CharacterType 1 → player    → STAND OFF
--     gm80_062 / gm80_256                  pc=1, Cook @ CharacterType 1 → player   → STAND OFF
-- ⭐ It also drops beds for free: their authored verb is `Search`, not `Sit`.
-- ═══════════════════════════════════════════════════════════════════════════════════════
local PLANT_KINDS = { CHAIR = true }

-- These are the nine prefab families whose Search points are owned by app.Gm51_115. This is
-- deliberately an owner-proven whitelist, not every gm51 object which happens to say Search.
local BED_KEYS = {
    -- gm51_092 (the BASE prefab): field-identified 2026-08-27 by ENGINESCAN — Aurora's
    -- Vernworth test bed, 0.9m, one Search point ct=8. Same Gm51_115 family as its _02.
    gm51_092 = true,
    -- ⚠ gm51_074: ENGINESCAN candidate for the DOUBLE bed (2026-08-27, Common Quarter):
    -- TWO Human-only points (two sleepers), icon off. Experimental — if it proves to be
    -- something else, remove this line; BEDFEED logs every unlock it performs.
    gm51_074 = true,
    gm51_092_02 = true, gm51_100 = true, gm51_115_01 = true,
    gm51_393 = true, gm51_396 = true, gm51_409 = true,
    gm51_460 = true, gm51_603 = true, gm51_742 = true,
}

-- ⛔ BY NAME, NEVER BY FSM: gm80_054_interact_fsm is shared with innocent gimmicks, so banning
-- the FSM bans the wrong things. ⚠ These are SUBSTRING matches — check any addition for prefix
-- collisions (a bare "gm51_10" would swallow gm51_100 through gm51_109).
local BAN = {
    "gm80_054", "gm81_032",              -- Godsbane doors: endgame / Unmoored critical path
    "gm05_046", "gm80_021", "gm80_022",  -- doors and locks: content gates, and they MOVE
    "gm80_042", "gm80_052",              -- oxcarts: they drive away with you welded on
    "gm80_046", "gm80_048",              -- ballistae
    "gm81_031",                          -- wedge
    "gm80_105", "gm80_148", "gm80_195",  -- Godsbane elevators / lift
    "gm02_003", "gm80_205",              -- portcrystals
    "gm04_013", "gm81_045", "gm80_053",  -- riftstones
    "gm81_108", "gm81_042",              -- Sphinx: one-shot and missable
    "gm81_117", "gm81_118", "gm81_119", "gm81_120", "gm81_126",  -- Medusa statues
}

-- ⭐ A SPAWNED gm80_257 REPORTS ITS GAMEOBJECT NAME AS "gmSeat", after the shared
-- gmSeat_fsm/gmSeat_skeleton rig — NOT as its prefab id. Missing this broke the de-dup entirely.
-- Never identify a spawned gimmick by prefab id at runtime.
local DONOR_NAMES = { "gm80_065", "gm80_066", "gm80_067", "gm80_068", "gm80_069",
                      "gm80_257", "gm80_166", "gmcamp", "gmseat" }

-- shared rig / base-class objects that carry components but are not placeable prefabs
local GENERIC_RIG = { "gmaiinteract", "gminteractbase", "gmseat", "gmcamp" }

-- Scene GameObject names carry instance decoration; strip it down to a catalog key.
local function _norm(name)
    local n = tostring(name or ""):lower()
    if n == "" then return nil end
    n = n:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s*%(%d+%)$", ""):gsub("_?clone$", "")
    if CAT[n] then return n end
    local base = n
    for _ = 1, 3 do
        base = base:gsub("_%d+$", "")
        if base == "" then break end
        if CAT[base] then return base end
    end
    local head = n:match("^(gm%d+_%d+)")
    if head and CAT[head] then return head end
    return nil
end

local function _banned(name)
    local n = tostring(name or ""):lower()
    if n == "" then return "no name" end
    for _, b in ipairs(BAN) do if n:find(b, 1, true) then return b end end
    for _, d in ipairs(DONOR_NAMES) do if n:find(d, 1, true) then return "is itself a seat" end end
    return nil
end

local function _eligible(name)
    local ban = _banned(name)
    if ban then return false, "banned: " .. ban end
    local key = _norm(name)
    if not key then
        local n = tostring(name or ""):lower()
        for _, g in ipairs(GENERIC_RIG) do
            if n:find(g, 1, true) then return false, "shared rig" end
        end
        return false, "not in catalog"
    end
    if CAT[key].pc == 1 then
        return false, "the game already offers the player: " .. table.concat(CAT[key].pv or {}, "/")
    end
    return true, nil, key
end

-- ═══════════════════════════════════════════════════════════════════════════════════════
-- SPAWNING
-- ⛔ NO INSTANCE CACHING across spawns. requestCreateInstance is ASYNC and a job is abandoned
-- on timeout, so the engine may still complete an old request against objects the next spawn
-- has re-pointed at a different position. ⛔ And never prefab:release() — a recorded CTD.
-- ═══════════════════════════════════════════════════════════════════════════════════════
local job, job_seq = nil, 0

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
        -- ⛔ setInitialAngle ONLY. Context/raw-field angle writes poison the spawn.
        pcall(function()
            local rqt = ValueType.new(sdk.find_type_definition("via.Quaternion"))
            rqt.x, rqt.y, rqt.z, rqt.w = rq.x, rq.y, rq.z, rq.w
            container._CommonInfo:setInitialAngle(rqt)
        end)
        pcall(function() container._StatusInfo["<ScaleRate>k__BackingField"] = 1.0 end)
        job = { stage = "wait", f = 0, prefab = prefab, ctrl = ctrl, inst = inst,
                container = container }
    end)
    if not ok then job = nil; _log("spawn: build failed for " .. tostring(name)) end
    return job ~= nil
end

local function _spawn_pump()
    if not job then return nil end
    job.f = (job.f or 0) + 1
    if job.stage == "wait" then
        local ready = false
        pcall(function() ready = job.prefab:get_Ready() == true end)
        if ready then
            job_seq = job_seq + 1
            local okr = pcall(function()
                local gen = sdk.get_managed_singleton("app.GenerateManager")
                gen:call("requestCreateInstance(app.PrefabController, app.GenerateInfo.GenerateInfoContainer, System.Int32, app.InstanceInfo, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>)",
                    job.ctrl, job.container, 751000 + job_seq, job.inst, nil, nil)
            end)
            if okr then job.stage, job.f = "poll", 0 else job = nil; _log("spawn: create refused") end
        elseif job.f > 600 then job = nil; _log("spawn: prefab never became ready") end
        return nil
    end
    if job.stage == "poll" then
        local go
        pcall(function() go = job.inst:get_Instance() end)
        if go then
            pcall(function() go:add_ref() end)
            job = nil
            return go
        end
        if job.f > 600 then job = nil; _log("spawn: instance never arrived") end
    end
    return nil
end

-- ⛔ via.physics.Colliders has NO set_Enabled — that guess fails SILENTLY inside a pcall.
-- disable() is the real call, and it must recurse: colliders commonly live on child objects.
local function _kill_colliders(go, depth, count)
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
            if cgo then _kill_colliders(cgo, (depth or 0) + 1, count) end
            child = child:call("get_Next")
        end
    end)
    return count.n
end

-- The undo — enable() mirrors disable(), same recursion. Exists for the 2026-08-27
-- friendly-fire repair: the adopted-neuter pass briefly disabled colliders on REAL
-- placed furniture (vanilla gm80_257 benches etc.), which kills the ground surface
-- their sit points' serve-check rays need — vanilla B prompts vanished.
local function _wake_colliders(go, depth, count)
    count = count or { n = 0 }
    if not go or (depth or 0) > 6 then return count.n end
    pcall(function()
        local pc = go:call("getComponent(System.Type)", sdk.typeof("via.physics.Colliders"))
        if pc then pc:call("enable"); count.n = count.n + 1 end
    end)
    pcall(function()
        local tf = go:call("get_Transform"); local child = tf and tf:call("get_Child")
        while child do
            local cgo = child:call("get_GameObject")
            if cgo then _wake_colliders(cgo, (depth or 0) + 1, count) end
            child = child:call("get_Next")
        end
    end)
    return count.n
end

-- ═══════════════════════════════════════════════════════════════════════════════════════
-- THE ENGINE
-- ═══════════════════════════════════════════════════════════════════════════════════════
local sc = { list_at = 0, at = 0, list = {}, complete = false, last_p = nil, ms = 0 }
local seats = {}          -- ["<host address>:<point>"] = { go, host, addr, point, foreign }
local pending = nil
local stats = { placed = 0, retired = 0, dedup = 0, failed = 0,
                unlocked = 0, restored = 0, unlock_failed = 0 }

-- [address of app.InteractiveObjectData] = { point, old, old_icon, kind, host, source,
--                                            io, io_addr, index, owner, prop_key }
-- Holding the managed point itself lets a checkbox restore the exact value it changed. On a
-- script reset the new instance re-scans live objects; no cached request or engine-owned pooled
-- object is ever retained or mutated.
local unlocks = {}
local unlock_at = 0
local native_session = { key = nil }
local native_last = "none yet"

-- Forward declarations: the cancelInteract hook below closes over these, but their bodies
-- live further down. Without the forward locals the closure would silently capture nil
-- globals and the interceptor would be dead armor. ST is created here (and populated in
-- the stations section) so the hook can see the pending-abort state.
local _active_native, _st_release, _is_station_active, _st_log
local ST = {}

-- The same-input notification lets the game see the second authored button, but different prop
-- owners do not all route that press consistently. Observe the manager's real cancel call so our
-- delayed fallback never sends a second one. This hook changes no arguments or return values.
do
    local ok, err = pcall(function()
        local td = sdk.find_type_definition("app.InteractManager")
        local method = td and td:get_method("cancelInteract")
        if not method then error("app.InteractManager.cancelInteract not found") end
        sdk.hook(method, function(args)
            local result = nil
            pcall(function()
                local chara = sdk.to_managed_object(args[3])
                -- ⛔⛔ ENGINE N ARMOR: for a natively-unlocked STATION owner, the manager
                -- cancel path is 4-for-4 fatal (it requests the NPC-authored EndAction jack).
                -- If the game — or anything else — routes the player into it while one of OUR
                -- stations is active, swallow the call and run the proven jack-level release
                -- instead. Chairs, bells, pickables and beds pass through untouched.
                -- ⚠ While OUR abort is pending, stand down entirely: the manager's own
                -- teardown may route through here and must not be swallowed.
                if M.stations ~= false and chara and _active_native and not ST.pending then
                    local player = _player()
                    if player and chara:get_address() == player:get_address() then
                        local a = _active_native()
                        if _is_station_active and _is_station_active(a) and _st_release then
                            _st_release("cancelInteract intercepted")
                            result = sdk.PreHookResult.SKIP_ORIGINAL
                            return
                        end
                    end
                end
                if not (M.enabled and (M.native_chores or M.native_beds)
                        and native_session and native_session.key) then return end
                local tracked = native_session.player
                if not (chara and tracked) then return end
                local same = chara:get_address() == tracked:get_address()
                if not same then return end
                native_session.cancel_requested = true
                native_session.cancel_at = os.clock()
                native_last = string.format("manager exit observed: %s",
                    tostring(native_session.host))
                pcall(function() log.info(string.format(
                    "[Interactables] native manager cancel observed for %s",
                    tostring(native_session.host))) end)
            end)
            return result
        end, function(retval) return retval end)
    end)
    if not ok then
        pcall(function() log.error("[Interactables] cancel observer FAILED: " .. tostring(err)) end)
    end
end

local function _unlock_count(kind)
    local n = 0
    for _, r in pairs(unlocks) do if not kind or r.kind == kind then n = n + 1 end end
    return n
end

local function _restore_unlocks(kind)
    for k, r in pairs(unlocks) do
        if not kind or r.kind == kind then
            local ok = pcall(function()
                r.point:set_field("CharacterType", r.old)
                if r.old_icon ~= nil then r.point:set_field("IconType", r.old_icon) end
            end)
            if ok then stats.restored = stats.restored + 1 end
            unlocks[k] = nil
        end
    end
end

local function _unlock_kind(key)
    if not key then return nil end
    -- The gm50 interact family is DD2's ordinary life-prop set: cups, plates, brooms, buckets,
    -- axe/log stations, hoe/pitchfork/mattock, bellows, anvil, notepad and oxcart bells.
    -- gm10_030 is deliberately excluded for now. Its entry works, but both its performance
    -- selectors and its cancel callback issued overlapping AdjustJack requests and produced
    -- access violations on Player. Re-enable only after the passive NPC trace proves ordering.
    -- Confirmed lethal on Player: entry reaches the dough loop, but cancelInteract enters this
    -- owner's EndAction and the process dies before the manager call returns (2026-08-10 trace).
    -- ⚠⚠ AURORA'S CALL, 2026-08-13, after I raised the crash history and she reaffirmed:
    -- "I don't care if they're crash proven - unlock them so we can try and fix them."
    -- These two are the ONLY prefabs in the game with a proven hard CTD on Player, and the
    -- crash is always on EXIT (InteractManager.cancelInteract / endInteract), never on
    -- ENTRY. So they are reachable now, behind their OWN switch, so that if the process
    -- dies we know without ambiguity which experiment killed it.
    -- ⛔ THE ONLY SAFE WAY OUT OF THESE IS THE JACK-LEVEL RELEASE -- rejectSelf plus the
    -- restartOwnerProcess(true)/enableOwnerFSM() restore pair. NEVER a manager call. The
    -- manager route is 4-for-4 fatal and unlocking entry does not change that one bit.
    if key == "gm10_030" and M.native_lethal ~= true then
        return nil
    end
    if key == "gm50_022" and M.native_lethal ~= true and not
            (M.stations ~= false and STATIONS and STATIONS[key]) then
        return nil
    end
    -- ⭐ ENGINE N (2026-08-27, Aurora: "they are all just fake animations"): stations unlock
    -- NATIVELY so the GAME runs the real interaction — its own prompt, approach, prop borrow
    -- and station state. Entry has never been the crash; every proven CTD was the MANAGER
    -- EXIT, which the station exit watch + the cancelInteract interceptor make unreachable.
    -- (The drum is filtered above: its AVs were entry-side, a different failure class.)
    if M.stations ~= false and STATIONS and STATIONS[key]
            and not (M.st_off or {})[key] then
        return "station"
    end
    if M.native_discovery then
        local row = CAT[key]
        local search = false
        for _, verb in ipairs((row and row.v) or {}) do
            if tostring(verb) == "Search" then search = true break end
        end
        if search and tonumber(row.pc) == 0 and not _banned(key) then
            return BED_KEYS[key] and "bed" or "chore"
        end
    end
    if M.native_chores and key:match("^gm50_") then return "chore" end
    if M.native_beds and BED_KEYS[key] then return "bed" end
    return nil
end

local function _owner_is(owner, wanted)
    local matched = false
    pcall(function()
        local td = owner and owner:get_type_definition()
        for _ = 1, 16 do
            if not td then break end
            if tostring(td:get_full_name()) == wanted then matched = true; break end
            td = td:get_parent_type()
        end
    end)
    return matched
end

local function _safe_chore_owner(owner, prop_key)
    if (prop_key == "gm50_022" or prop_key == "gm10_030") and M.native_lethal ~= true then
        return false
    end
    -- Oxcart bell: field-tested one-shot; it rings and releases itself.
    if prop_key and prop_key:match("^gm50_036") then return true end
    -- Loose broom/pitchfork/etc: field-tested borrow/drop behaviour, not an endless workstation.
    if _owner_is(owner, "app.GmInteractPickableBase") then return true end
    -- Internal research gate only. Do not expose this as an innocent general-purpose checkbox.
    return M.native_workstations == true or M.native_discovery == true
end

local function _patch_search_point(point, kind, host, source, index, io, owner, prop_key)
    if not point then return false end
    if kind == "chore" and not _safe_chore_owner(owner, prop_key) then return false end
    local key = _addr(point)
    if not key then return false end
    -- Authored and runtime lists often contain the exact same managed data object. The authored
    -- pass discovers it first; enrich that record when the runtime pass supplies the actual
    -- InteractiveObject needed for a clean second-press exit.
    if unlocks[key] then
        local r = unlocks[key]
        if io then
            r.io, r.io_addr, r.index, r.owner = io, _addr(io), index, owner
            r.prop_key = prop_key or r.prop_key
        end
        return false
    end

    local icon, ct = nil, nil
    pcall(function() icon = tonumber(point:get_field("IconType")) end)
    pcall(function() ct = tonumber(point:get_field("CharacterType")) end)
    -- Search is IconType 0. Never broaden a ride, door, quest, camp, shop or talk point merely
    -- because it shares a GameObject with a bell or another harmless prop.
    local has_human = ct and (math.floor(ct / 8) % 2) == 1
    -- A bed point may already read Sleep/Bed if its authored twin was changed before the
    -- runtime copy was inspected. No other non-Search verb is broadened.
    if (icon ~= 0 and not (kind == "bed" and (icon == 30 or icon == 22)))
        or not ct or not has_human or (ct % 2) == 1 then return false end

    local new_ct = ct + 1
    local wrote = pcall(function() point:set_field("CharacterType", new_ct) end)
    local readback = nil
    if wrote then pcall(function() readback = tonumber(point:get_field("CharacterType")) end) end
    if readback ~= new_ct then
        stats.unlock_failed = stats.unlock_failed + 1
        _logf("unlock FAILED: %s %s[%d] CharacterType %s -> %s (read %s)",
            tostring(host), tostring(source), tonumber(index) or -1,
            tostring(ct), tostring(new_ct), tostring(readback))
        return false
    end

    -- ⭐ 2026-08-27 disassembly: IconType 30 (Sleep) has a jump-table entry but is used by
    -- ZERO shipped interact points — its message GUID may resolve to nothing, drawing an
    -- INVISIBLE prompt (bed hypothesis H2). The shipped PLAYER beds (gm51_409_01 et al) use
    -- IconType 22 (Bed) — patch to 22 so our point is byte-identical to a bed that serves.
    -- 1 is the real Pickup label for loose GmInteractPickableBase tools.
    local old_icon = nil
    local new_icon = nil
    if kind == "bed" and icon == 0 then
        new_icon = 22
    elseif kind == "chore" and icon == 0
            and _owner_is(owner, "app.GmInteractPickableBase") then
        new_icon = 1
    end
    if new_icon ~= nil then
        local icon_ok = pcall(function() point:set_field("IconType", new_icon) end)
        local icon_read = nil
        if icon_ok then pcall(function() icon_read = tonumber(point:get_field("IconType")) end) end
        if icon_read == new_icon then old_icon = icon end
    end

    unlocks[key] = { point = point, old = ct, old_icon = old_icon,
                     kind = kind, host = host, source = source,
                     io = io, io_addr = _addr(io), index = index, owner = owner,
                     prop_key = prop_key }
    stats.unlocked = stats.unlocked + 1
    _logf("native %s unlocked: %s %s[%d] CharacterType %d -> %d",
        kind, tostring(host), tostring(source), tonumber(index) or -1, ct, new_ct)
    -- Bed/station unlocks go to the always-on log: "the checkbox does nothing" and "no
    -- prompt appeared" are told apart by whether this line ever printed.
    if (kind == "bed" or kind == "station") and _st_log then
        _st_log(string.format("unlocked %s point on %s", kind, tostring(host)))
    end
    return true
end

local function _patch_data_list(list, kind, host, source, io, owner, prop_key)
    if not list then return end
    for i, point in ipairs(_arr(list)) do
        _patch_search_point(point, kind, host, source, i - 1, io, owner, prop_key)
    end
end

local function _unlock_go(e)
    local key = _norm(e and e.name)
    local kind = _unlock_kind(key)
    if not kind or not (e and e.go and _valid(e.go)) then return end

    -- A GameObject can own several GimmickBase components and therefore several independent
    -- InteractiveObjects (the oxcart bell family does). Walk every component; patching only the
    -- first property would silently miss the bell or broaden the cart's unrelated action.
    for _, comp in ipairs(_arr(e.go:call("get_Components"))) do
        local allow = kind == "chore" or kind == "station"
        if kind == "bed" then
            local tn = ""
            pcall(function() tn = tostring(comp:get_type_definition():get_full_name()) end)
            allow = tn == "app.Gm51_115"
        end
        if allow then
            local authored, io = nil, nil
            pcall(function() authored = comp:get_field("InteractiveObjectDataList") end)
            pcall(function() io = comp.InteractiveObject end)
            if not io then pcall(function() io = comp:get_field("InteractiveObject") end) end

            -- Depending on setup timing DataList may contain the same point objects or runtime
            -- copies. Patch both and de-duplicate by managed address.
            _patch_data_list(authored, kind, e.name, "authored", nil, comp, key)
            if io then
                local runtime = nil
                pcall(function() runtime = io:get_field("DataList") end)
                _patch_data_list(runtime, kind, e.name, "runtime", io, comp, key)
            end
        end
    end
end

local function _record_for_active(io, point_no)
    local ia = _addr(io)
    if not ia then return nil end
    for _, r in pairs(unlocks) do
        if r.io_addr == ia and tonumber(r.index) == tonumber(point_no) then return r end
    end
    -- Index equality proved too strict in the field (chop block: session invisible, exits
    -- dead). Same InteractiveObject = same station; the io pointer alone is identity enough.
    for _, r in pairs(unlocks) do
        if r.io_addr == ia then return r end
    end
    return nil
end

function _active_native()   -- assigns the forward local declared above the cancel hook
    local out = nil
    pcall(function()
        local player = _player()
        local mgr = player and sdk.get_managed_singleton("app.InteractManager")
        if not mgr then return end
        local active = mgr:call("getActiveInteract(app.Character)", player)
        local point = active and active:get_field("Point")
        local io = point and point:get_field("Object")
        local no = point and tonumber(point:get_field("PointNo"))
        if not io then return end
        local rec = _record_for_active(io, no)
        -- ⭐ 2026-08-27 (Aurora mashing B at the chop block, nothing): record matching by
        -- managed pointer + point index is FRAGILE — an authored-only record never got its
        -- runtime io enrichment and the session went invisible. Classify by the owner
        -- GameObject's NAME as well; the record stays along for the ride (dough reset).
        -- app.InteractiveObject is NOT a component — its gimmick GameObject is the
        -- `Owner` property (read off the full type dump; get_GameObject does not exist).
        local key = nil
        pcall(function()
            local go = io:call("get_Owner")
            if not go then go = io:get_field("<Owner>k__BackingField") end
            if go then key = _norm(go:call("get_Name")) end
        end)
        out = { player = player, mgr = mgr, active = active,
                io = io, point_no = no, rec = rec, key = key }
    end)
    return out
end

-- One question, asked everywhere the same way: is this active thing ours to exit?
function _is_station_active(a)   -- assigns the forward local (the cancel hook closes over it)
    if not a then return false end
    if a.rec and a.rec.kind == "station" then return true end
    -- Beds (2026-08-27, Aurora: "lie down and sleep for real"): the native bed interaction
    -- is the genuine lie-down; what it never had was a proven player exit. The IsNeedAbort
    -- teardown is that exit, so bed sessions now get the same Stop machinery.
    if a.rec and a.rec.kind == "bed" then return true end
    if a.key and STATIONS and STATIONS[a.key] and not (M.st_off or {})[a.key] then return true end
    return false
end

-- NPC chores generally never enable the interaction button a second time: their AI decides when
-- to leave. A clean native chair control trace proved the full player route:
--   second press -> InteractManager.cancelInteract -> owner EndAction -> continueInteract
--   -> InteractManager.endInteract -> InteractiveObject end -> endJack -> reset.
-- Calling InteractiveObject.cancelInteractForSystem directly skipped that manager lifecycle and
-- corrupted the prompt/equipment state. Detect the physical interaction binding ourselves and
-- enter only the
-- proven manager route once. A passive manager hook suppresses our delayed fallback if the native
-- same-input path gets there first.
local function _native_session_tick()
    -- `cancelInteract` is the correct PLAYER-chair route, but it is not universally valid for
    -- NPC-authored owners. gm50_022 crashed synchronously after requesting EndAction. Until a
    -- workstation-specific exit is proved, never drive manager cancellation from this mod.
    if M.native_manager_exit ~= true then
        native_session = { key = nil }
        return
    end
    if not M.enabled or (not M.native_chores and not M.native_beds) or _menu_open() then
        native_session = { key = nil }
        return
    end

    -- _active_native now also returns record-less (name-classified) sessions for the
    -- stations engine; this legacy chore/bed tracker only ever handled RECORDED ones.
    local a = _active_native()
    if not a or not a.rec then
        native_session = { key = nil }
        return
    end
    local skey = tostring(a.rec.io_addr) .. ":" .. tostring(a.point_no)
    local now = os.clock()
    if native_session.key ~= skey then
        native_session = { key = skey, began = now, released = false,
                           notified = false, cancel_requested = false,
                           exit_press_at = nil, force_end_requested = false,
                           io = a.io, point_no = a.point_no, player = a.player,
                           prop_key = a.rec.prop_key, host = a.rec.host }
        native_last = string.format("active %s: %s", tostring(a.rec.kind), tostring(a.rec.host))
        _logf("active native %s: %s point %d",
            tostring(a.rec.kind), tostring(a.rec.host), tonumber(a.point_no) or -1)
    end

    if now - native_session.began < 0.65 then return end

    -- Do not use InteractiveObject.checkInput here. Human-only chore owners commonly disable
    -- their point's input while occupied, so it correctly reported false for every attempted
    -- exit from gm50_022 (dough rolling). Read the user's physical binding instead.
    local down = _exit_binding_down()
    if not native_session.released then
        -- The initiating press must come fully up before it can ever be treated as an exit.
        if not down then
            native_session.released = true
            native_last = string.format("exit armed: %s", tostring(a.rec.host))
        end
        return
    end

    if not native_session.notified then
        local ok = pcall(function()
            a.mgr:call("notifyEnableInputAssginedToSameInputOfInteractOnInteracting")
        end)
        native_session.notified = true
        native_last = string.format("exit input %s: %s", tostring(a.rec.host),
            ok and "enabled" or "failed")
        pcall(function() log.info(string.format(
            "[Interactables] same-input exit enabled for %s: %s",
            tostring(a.rec.host), tostring(ok))) end)
    end

    if down and not native_session.cancel_requested and not native_session.exit_press_at then
        -- Give the native same-input path several frames to call cancelInteract first. A quick
        -- tap is remembered even after the physical button comes back up.
        native_session.exit_press_at = now
        pcall(function() log.info(string.format(
            "[Interactables] exit button detected for %s", tostring(a.rec.host))) end)
    end

    if native_session.exit_press_at and not native_session.cancel_requested
            and now - native_session.exit_press_at >= 0.12 then
        -- Set the sentinel before invoking: cancelInteract synchronously enters the owner's
        -- EndAction callback and can re-enter the observer above in the same frame.
        native_session.cancel_requested = true
        native_session.cancel_at = now
        local ok, err = pcall(function()
            a.mgr:call("cancelInteract(app.Character)", a.player)
        end)
        native_last = string.format("manager exit %s: %s", tostring(a.rec.host),
            ok and "requested" or "failed")
        pcall(function() log.info(string.format(
            "[Interactables] manager cancelInteract for %s point %d: %s%s",
            tostring(a.rec.host), tonumber(a.point_no) or -1, tostring(ok),
            ok and "" or (" / " .. tostring(err)))) end)
    end

    -- Some Human-only owners can request EndAction on Player but never report that mismatched
    -- action complete. The manager's own finaliser is still the correct cleanup boundary; use it
    -- only after a generous wait, never as the first-stage exit.
    if native_session.cancel_requested and native_session.cancel_at
            and not native_session.force_end_requested
            and now - native_session.cancel_at >= 6.0 then
        native_session.force_end_requested = true
        local ok, err = pcall(function()
            a.mgr:call("endInteract(app.Character)", a.player)
        end)
        native_last = string.format("manager finalise %s: %s", tostring(a.rec.host),
            ok and "requested" or "failed")
        pcall(function() log.info(string.format(
            "[Interactables] manager endInteract watchdog for %s point %d: %s%s",
            tostring(a.rec.host), tonumber(a.point_no) or -1, tostring(ok),
            ok and "" or (" / " .. tostring(err)))) end)
    end
end

local function _unlock_tick()
    local stations_on = M.stations ~= false
    if not M.enabled and not stations_on then
        if next(unlocks) then _restore_unlocks() end
        return
    end
    if not M.enabled and next(unlocks) then
        _restore_unlocks("chore"); _restore_unlocks("bed")
    end
    if not stations_on and _unlock_count("station") > 0 then _restore_unlocks("station") end
    if M.enabled then
        if not M.native_chores and not M.native_discovery
                and _unlock_count("chore") > 0 then _restore_unlocks("chore") end
        if not M.native_beds and not M.native_discovery
                and _unlock_count("bed") > 0 then _restore_unlocks("bed") end
    end
    local want_native = M.enabled
        and (M.native_chores or M.native_beds or M.native_discovery)
    if not want_native and not stations_on then return end
    if _loading() or _menu_open() then return end

    local now = os.clock()
    if now - unlock_at < (M.unlock_secs or 1.0) then return end
    unlock_at = now
    -- Stations must keep discovering even when the seat engine (which normally refreshes
    -- sc.list) is switched off. Same throttle fields, so the two never double-refresh.
    if (not M.enabled or #sc.list == 0)
            and now - (tonumber(sc.list_at) or 0) > (M.list_secs or 5.0) then
        sc.list_at = now
        sc.complete = _refresh_list()
    end
    for _, e in ipairs(sc.list) do pcall(_unlock_go, e) end
end

local function _seat_count()
    local n = 0
    for _ in pairs(seats) do n = n + 1 end
    return n
end

local function _kill_seat(rec)
    if not (rec and rec.go) then return end
    pcall(function()
        if rec.go:call("get_Valid") == true then rec.go:call("destroy(via.GameObject)", rec.go) end
    end)
    pcall(function() rec.go:release() end)
end

local function _drop_all(destroy)
    for k, rec in pairs(seats) do
        if destroy then _kill_seat(rec) else pcall(function() rec.go:release() end) end
        seats[k] = nil
    end
    pending = nil
end

-- ⛔ DISCOVER VIA app.GimmickBase, NOT via.motion.MotionJackFsm2. A tavern bench (gm51_074) has
-- 24 components and NO MotionJackFsm2 at all, so an FSM-based scan cannot see benches however
-- good the rest of the logic is.
-- ⛔ BUILD INTO A LOCAL AND PUBLISH ONLY ON SUCCESS. Assigning unconditionally means any throw
-- publishes a partial list, and the retire pass reads that as "every chair vanished".
local function _refresh_list()
    local built, ok = {}, false
    pcall(function()
        local scene = sdk.call_native_func(
            sdk.get_native_singleton("via.SceneManager"),
            sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        if not scene then return end
        local t = sdk.typeof("app.GimmickBase")
        if not t then return end
        for _, comp in ipairs(_arr(scene:call("findComponents(System.Type)", t))) do
            local go = nil
            pcall(function() go = comp:call("get_GameObject") end)
            if go and _valid(go) then
                local nm = nil
                pcall(function() nm = tostring(go:call("get_Name")) end)
                built[#built + 1] = { go = go, name = nm or "?" }
            end
        end
        ok = #built > 0
    end)
    if ok then sc.list = built end
    return ok
end

-- ⭐ Shape comes from the catalog's authored verbs, not an FSM state set — the only thing that
-- CAN classify FSM-less furniture like benches.
local function _resolve(e)
    if e.done then return e end
    e.done = true
    e.ok, e.why, e.key = _eligible(e.name)
    if e.ok then
        local sit = false
        for _, v in ipairs((CAT[e.key] or {}).v or {}) do if v == "Sit" then sit = true break end end
        if sit then e.kind = "CHAIR" else e.ok, e.why = false, "no Sit interact authored" end
    end
    return e
end

-- ⭐ Is a donor already parked here? This is what makes leftovers harmless: a seat that survived
-- a reload, or one IrisHomeLife planted, is simply found and left alone. No destructive sweep,
-- no ownership protocol, and no way to delete Capcom's real campsite seats.
local function _donor_near(p, radius)
    local r2 = (radius or 0.5) * (radius or 0.5)
    for _, e in ipairs(sc.list) do
        local nm = tostring(e.name or ""):lower()
        for _, d in ipairs(DONOR_NAMES) do
            if nm:find(d, 1, true) and _valid(e.go) then
                local q = _upos(e.go)
                if q then
                    local dx, dy, dz = q.x - p.x, q.y - p.y, q.z - p.z
                    if (dx * dx + dy * dy + dz * dz) < r2 then return true end
                end
                break
            end
        end
    end
    return false
end

local function _tick()
    if not M.enabled then if _seat_count() > 0 then _drop_all(true) end return end
    if _loading() or _menu_open() then return end
    local now = os.clock()

    -- collect an in-flight spawn (ONE at a time — a volley of gimmick spawns is a known hazard)
    if pending then
        local go = _spawn_pump()
        if go then
            if M.neuter_collision then _kill_colliders(go) end
            seats[pending.key] = { go = go, host = pending.host,
                                   addr = pending.addr, point = pending.point }
            stats.placed = stats.placed + 1
            _logf("seat placed in %s (%d live)", tostring(pending.host), _seat_count())
            pending = nil
        elseif job == nil then
            stats.failed = stats.failed + 1
            pending = nil
        end
        return
    end
    if job then return end

    local pgo = _char_go(_player())
    local pp = pgo and _pos(pgo)
    if not pp then return end

    -- re-list on a timer OR as soon as you have travelled far enough to have new furniture
    local moved = 1e9
    if sc.last_p then
        local dx, dy, dz = pp.x - sc.last_p.x, pp.y - sc.last_p.y, pp.z - sc.last_p.z
        moved = math.sqrt(dx * dx + dy * dy + dz * dz)
    end
    if now - sc.list_at > (M.list_secs or 5.0) or moved > (M.list_move or 10.0) then
        sc.list_at = now
        sc.last_p = { x = pp.x, y = pp.y, z = pp.z }
        local t0 = os.clock()
        sc.complete = _refresh_list()
        sc.ms = (os.clock() - t0) * 1000.0
        -- ⭐ ADOPTED donors too (2026-08-27, "chairs are still shaking"): seats surviving a
        -- reload are found and left alone by design, which meant the collider fix only ever
        -- reached NEW spawns. Neuter every donor-named gimmick in the fresh list; the call
        -- is idempotent and the list holds only a handful of donors.
        do
            -- ⛔ COLLIDER LESSONS (field, 2026-08-27): (1) DONOR_NAMES prefab ids also name
            -- REAL placed furniture — never neuter by prefab id. (2) NEUTER ITSELF KILLS
            -- SIT PROMPTS: the serve chain ground-checks under the point; the seat's own
            -- collider is that ground. So with neuter OFF (the rev-4 default) this pass
            -- becomes a REPAIR: wake (once per object) every collider the earlier passes
            -- cut — our donors and any wrongly-hit world furniture alike.
            -- ⛔ TOGGLE-SAFE (field 2026-08-27: a heal-ONCE latch left seats collider-less
            -- forever after the checkbox was ticked then unticked — sit prompts gone both
            -- ways). Track the last ACTION per object; heal fires on every killed→healed
            -- transition, not once per lifetime.
            sc.colstate = sc.colstate or {}
            local nd, healed = 0, 0
            for _, e in ipairs(sc.list) do
                if _valid(e.go) then
                    local nm = tostring(e.name or ""):lower()
                    local rig = nm:find("gmseat", 1, true) or nm:find("gmcamp", 1, true)
                    local donorish = rig
                    if not donorish then
                        for _, d in ipairs(DONOR_NAMES) do
                            if nm:find(d, 1, true) then donorish = true break end
                        end
                    end
                    if donorish then
                        local a = _addr(e.go)
                        if M.neuter_collision and rig then
                            if a then sc.colstate[a] = "killed" end
                            _kill_colliders(e.go); nd = nd + 1
                        elseif a and sc.colstate[a] ~= "healed" then
                            sc.colstate[a] = "healed"
                            healed = healed + _wake_colliders(e.go)
                        end
                    end
                end
            end
            if nd ~= (sc.neutered or -1) or healed > 0 then
                sc.neutered = nd
                _st_log("collider pass: " .. nd .. " rig seats neutered"
                    .. (healed > 0 and (", " .. healed .. " colliders re-enabled") or ""))
            end
        end
    end
    if now - sc.at < (M.scan_secs or 0.5) then return end
    sc.at = now

    -- ── 1. what is in range ───────────────────────────────────────────────────────────
    local want, inrange = {}, {}
    local range, yw = (M.range or 12.0), (M.y_window or 2.5)
    -- ⛔ Collect out to `far`, plant only inside `range`. Collecting only to `range` makes the
    -- retire hysteresis dead code — a host that just slipped past the boundary would not be in
    -- the list at all, so the "still within range*1.25?" test could never find it.
    local far = range * (M.hysteresis or 1.25)
    local budget, truncated = (M.budget or 64), false
    for _, e in ipairs(sc.list) do
        if budget <= 0 then truncated = true; break end
        if _valid(e.go) then
            local gp = _pos(e.go)
            if gp and math.abs(gp.y - pp.y) <= yw then
                local dx, dz = gp.x - pp.x, gp.z - pp.z
                local d = math.sqrt(dx * dx + dz * dz)
                if d < far then
                    if not e.done then budget = budget - 1 end
                    _resolve(e)
                    local k = nil
                    pcall(function() k = e.go:get_address() end)
                    if k then
                        e._addr, e._d = k, d
                        inrange[#inrange + 1] = e
                    end
                end
            end
        end
    end

    -- ⭐ ONE ENTRY PER AUTHORED SEAT, not per object. A bench has n=2 and a single donor at the
    -- object origin serves neither seat.
    for _, e in ipairs(inrange) do
        if e.ok and (e._d or 1e9) < range and PLANT_KINDS[e.kind or ""] then
            local np = tonumber((CAT[e.key] or {}).n) or 1
            np = math.max(1, math.min(np, M.max_points or 4))
            for p = 0, np - 1 do want[e._addr .. ":" .. p] = { e = e, point = p } end
        end
    end

    -- ── 2. retire ─────────────────────────────────────────────────────────────────────
    -- ⛔ ONLY on a tick with a COMPLETE picture. Retiring against a partial list means reading
    -- "chair gone" from a list that never finished, and killing a seat out from under someone.
    if sc.complete and not truncated then
        for k, rec in pairs(seats) do
            local keep = want[k] ~= nil
            -- a de-duped entry owns no GameObject of ours; validity-checking a nil `go` would
            -- retire and re-de-dup it every single tick forever
            if rec.foreign then
                if not keep then seats[k] = nil end
                goto continue
            end
            if not keep then
                for _, e in ipairs(inrange) do
                    if e._addr == rec.addr and (e._d or 1e9) < far then keep = true; break end
                end
            end
            if not keep or not (rec.go and _valid(rec.go)) then
                _kill_seat(rec)
                seats[k] = nil
                stats.retired = stats.retired + 1
            end
            ::continue::
        end
    end

    -- ── 3. fill ONE gap per tick, nearest host first ──────────────────────────────────
    if _seat_count() >= (M.max_seats or 8) then return end
    local pick, pd = nil, 1e9
    for k, w in pairs(want) do
        if not seats[k] then
            local gp = _pos(w.e.go)
            if gp then
                local dx, dz = gp.x - pp.x, gp.z - pp.z
                local d = dx * dx + dz * dz
                if d < pd then pick, pd = { key = k, e = w.e, point = w.point }, d end
            end
        end
    end
    if not pick then return end

    pcall(function()
        local tf = pick.e.go:call("get_Transform")
        local up, rq = tf:call("get_UniversalPosition"), tf:call("get_Rotation")
        local p = ValueType.new(sdk.find_type_definition("via.Position"))
        p.x, p.y, p.z = up.x, up.y + (M.seat_y or 0.0), up.z

        -- ⭐ Use the game's own seat coordinate when it offers one. Measured on a tavern bench:
        -- two points 0.80m apart, which is where the seats actually are; the object origin is
        -- neither of them.
        -- ⛔ SPACE GUARD: getInteractPointPosition's coordinate space is undocumented and our
        -- spawn takes UNIVERSAL. If it lands near the host's universal position it is the same
        -- space; if it is wildly off, fall back rather than fling a seat across the map.
        if M.per_point ~= false then
            local io = _io_of(pick.e.go)
            if io then
                local pt = nil
                pcall(function() pt = io:call("getInteractPointPosition", pick.point or 0) end)
                if pt then
                    local dx, dy, dz = pt.x - up.x, pt.y - up.y, pt.z - up.z
                    if math.sqrt(dx * dx + dy * dy + dz * dz) < 8.0 then
                        p.x, p.y, p.z = pt.x, pt.y + (M.seat_y or 0.0), pt.z
                    end
                end
            end
        end

        if _donor_near(p, M.dedup_radius or 0.5) then
            stats.dedup = stats.dedup + 1
            seats[pick.key] = { go = nil, host = pick.e.name, foreign = true,
                                addr = pick.e._addr, point = pick.point }
            return
        end

        local nm = M.donor or "gm80_257"
        local dp = (CAT[nm] and CAT[nm].p) or ("AppSystem/gimmick/prefab/camp/" .. nm .. ".pfb")
        if _gimmick_job(nm, dp, p, rq) then
            pending = { key = pick.key, host = pick.e.name,
                        addr = pick.e._addr, point = pick.point }
        end
    end)
end

-- ═══════════════════════════════════════════════════════════════════════════════════════
-- COEXISTENCE — IrisHomeLife plants the identical donor in the identical place, so it needs to
-- know we are here. Belt and braces: even with no handshake, the de-dup above means the worst
-- case is two mods politely finding each other's seat.
-- ⚠ The timestamp matters: a stale claim from an UNINSTALLED mod must not disable the other one
-- forever, so consumers ignore a heartbeat older than ~2 seconds.
-- ═══════════════════════════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════════════════════════
-- STATIONS — ENGINE N. Every looping Human-only workstation, run by the GAME itself.
--
-- ⭐ 2026-08-27 (Aurora: "they are all just fake animations, not actually doing the
-- things"): playing the owner's clips on the player (the old Engine C) can never borrow
-- the prop or advance the station — only the game's own interact flow does that. So the
-- stations are unlocked NATIVELY (Player bit on the live Search point, the exact same
-- lever as the chore/bed unlocks above) and the GAME runs the whole interaction: its own
-- prompt, its own approach walk, the real axe/bellows/dough, the real station state.
--
-- ⛔ THE ONE THING THE GAME CANNOT DO on these owners is END the interaction for a player:
-- they are NPC-authored loops, and every manager exit is 4-for-4 fatal
-- (InteractManager.cancelInteract / endInteract / abortInteractForSystem / suppressed
-- EndAction — settled, do not re-litigate). The proven safe exit is the JACK-LEVEL
-- release: rejectSelf + restartOwnerProcess(true) + enableOwnerFSM (the engine's own
-- MotionJackBase.endJack calls AdjustJack.reject — we call exactly what Capcom calls),
-- then the FSM/ActionManager/controller re-asserts, then the prop-borrow return, and the
-- neutral motion write LAST. Unjacking has never crashed here. The cancelInteract
-- interceptor above turns even a native attempt at the fatal route into this release.
--
-- The bank/path data below is RETAINED VERIFIED REFERENCE (read out of Capcom's own
-- .motbank files — never reconstruct such a path from an id: loading a nonexistent native
-- path crashes the engine). It is no longer loaded at runtime; it is the map for a future
-- authored-finish polish pass. gm10_030 (drum) is deliberately absent: its crashes were
-- ENTRY-side AdjustJack AVs, a different failure class from the manager-exit ones.
-- ═══════════════════════════════════════════════════════════════════════════════════════
STATIONS = {
    -- key = catalog prefab key (what _norm returns for the world GameObject's name)
    gm50_022    = { bank = 8504, path = "appsystem/gimmick/gm50_027/gm50_022_interact_motlist.motlist", label = "Knead dough" },
    gm50_005    = { bank = 8507, path = "appsystem/gimmick/gminteract/gm50_005/gm50_005_interact_motlist.motlist", label = "Drink" },
    gm50_007_01 = { bank = 8509, path = "appsystem/gimmick/gm50_007/gm50_007_01_interact_motlist.motlist", label = "Sweep" },
    gm50_010_01 = { bank = 8510, path = "appsystem/gimmick/gm50_010/gm50_010_interact_motlist.motlist", label = "Work" },
    -- ⭐ 2026-08-27 pak forensics: the cook_chop triad is authored under the BOARD MESH's
    -- name (gm50_016_01) but the interact OWNER is gm50_132_01 ("cutting board" in Capcom's
    -- own job files; class Gm50_132_01 lends its KnifeObj natively — no conjure needed).
    gm50_132_01 = { bank = 8516, path = "appsystem/gimmick/gm50_016/gm50_016_01_interact_motlist.motlist", label = "Chop food" },
    gm50_011_01 = { bank = 8511, path = "appsystem/gimmick/gm50_011/gm50_011_interact_motlist.motlist", label = "Chop wood" },
    gm50_013    = { bank = 8512, path = "appsystem/gimmick/gm50_013/gm50_013_interact_motlist.motlist", label = "Draw water" },
    gm50_013_01 = { bank = 8513, path = "appsystem/gimmick/gm50_013/gm50_013_01_interact_motlist.motlist", label = "Wipe clean" },
    gm50_013_02 = { bank = 8514, path = "appsystem/gimmick/gm50_013/gm50_013_02_interact_motlist.motlist", label = "Wipe the table" },
    gm50_014_01 = { bank = 8515, path = "appsystem/gimmick/gm50_014/gm50_014_01_interact_motlist.motlist", label = "Wash at the table" },
    -- gm50_016_01 is the board MESH child only (no interact point) — row kept as the
    -- verified bank/path reference; the live owner is gm50_132_01 above.
    gm50_016_01 = { bank = 8516, path = "appsystem/gimmick/gm50_016/gm50_016_01_interact_motlist.motlist", label = "Chop food" },
    gm50_020    = { bank = 8517, path = "appsystem/gimmick/gm50_020/gm50_020_interact_motlist.motlist", label = "Tend the pot" },
    gm50_025    = { bank = 8518, path = "appsystem/gimmick/gminteract/gm50_025/gm50_025_interact_motlist.motlist", label = "Eat" },
    gm50_031    = { bank = 8519, path = "appsystem/gimmick/gm50_031/gm50_031_interact_motlist.motlist", label = "Till the soil" },
    gm50_031_01 = { bank = 8519, path = "appsystem/gimmick/gm50_031/gm50_031_interact_motlist.motlist", label = "Till the soil" },
    gm50_041_01 = { bank = 8521, path = "appsystem/gimmick/gm50_041/gm50_041_01_interact_motlist.motlist", label = "Tend the kiln" },
    gm50_052_1  = { bank = 8522, path = "appsystem/gimmick/gm50_052/gm50_052_1_interact_motlist.motlist", label = "Dye cloth" },
    gm50_053    = { bank = 8523, path = "appsystem/gimmick/gminteract/gm50_053/gm50_053_interact_motlist.motlist", label = "Take notes" },
    -- conjure = app.EquipItemID to place in the hands when the station lends no tool
    -- (the worker brings the tool; 41 = it50_096_00, the pitchfork)
    gm50_096    = { bank = 8524, path = "appsystem/gimmick/gm50_096/gm50_096_interact_motlist.motlist", label = "Pitch hay", conjure = 41 },
    gm50_096_01 = { bank = 8524, path = "appsystem/gimmick/gm50_096/gm50_096_interact_motlist.motlist", label = "Pitch hay", conjure = 41 },
    gm50_097    = { bank = 8525, path = "appsystem/gimmick/gm50_097/gm50_097_interact_motlist.motlist", label = "Work the hay", conjure = 41 },
    gm50_298    = { bank = 8526, path = "appsystem/gimmick/gm50_298/gm50_298_interact_motlist.motlist", label = "Dig" },
    gm50_298_01 = { bank = 8526, path = "appsystem/gimmick/gm50_298/gm50_298_interact_motlist.motlist", label = "Dig" },
    gm51_041_00 = { bank = 8527, path = "appsystem/gimmick/gm51_041/gm51_041_interact_motlist.motlist", label = "Tend the fire" },
    gm51_045    = { bank = 8528, path = "appsystem/gimmick/gm51_045/gm51_045_interact_motlist.motlist", label = "Polish" },
    gm51_046    = { bank = 8529, path = "appsystem/gimmick/gm51_046/gm51_046_interact_motlist.motlist", label = "Split timber" },
    gm51_132    = { bank = 8530, path = "appsystem/gimmick/gm51_132/gm51_132_interact_motlist.motlist", label = "Weave" },
    gm51_133    = { bank = 8531, path = "appsystem/gimmick/gm51_133/gm51_133_interact_motlist.motlist", label = "Weave" },
    gm51_188_00 = { bank = 8532, path = "appsystem/gimmick/gm51_188/gm51_188_00_interact_motlist.motlist", label = "Work the forge" },
    gm82_053    = { bank = 8540, path = "appsystem/gimmick/gm82_053/gm82_053_interact_motlist.motlist", label = "Smith" },
    gm82_053_01 = { bank = 8541, path = "appsystem/gimmick/gm82_053/gm82_053_01_interact_motlist.motlist", label = "Smith" },
    -- conjure_cfg: the anvil is our EquipItemID identification LAB — the conjure
    -- mechanism WORKS here (no equip-track stomp; id 4 = a medusa head, gloriously).
    -- The id comes live from the research slider so Aurora can flip through the block
    -- and find a blade. 0 = off.
    gm50_045_00 = { label = "Smithy station", conjure_cfg = true },
    -- pak forensics: Gm51_653 is Capcom's "washing table" (ClothObj/LaundryBoardObj);
    -- borrows gm50_014_01's wash_tap triad.
    gm51_653    = { label = "Wash clothes" },
    -- ⭐ Convicted by the freeze-marker log 2026-08-27 03:22: THE woodcutting block. Its
    -- owner is PICKABLE-classed (you genuinely take the axe — that is why the old "safe
    -- villager props" unlock served it), but the pickup chains into a work LOOP the
    -- walk-away exit never covers. As a station it gets the Stop prompt + B exit + armor.
    gm50_259_01 = { label = "Chop wood" },
}

-- ST itself is forward-declared above the cancelInteract hook; populate it here.
ST.prev, ST.kill_prev, ST.session, ST.pending, ST.at = false, false, nil, nil, 0
ST.status = "idle — the game offers its own prompt at each unlocked station"

-- ⭐ Freeze-pinning markers (the dumpless-hang law): log.info reaches DISK IMMEDIATELY and
-- survives a hard hang, unlike the mod's optional file log. Every stage of the exit gets a
-- marker; after a freeze, the LAST line in reframework's log names the guilty statement —
-- and if the final "END" marker printed, our code completed and the hang is the game
-- processing what we requested.
function _st_log(s)   -- assigns the forward local so the unlock engine can reach it too
    pcall(function() log.info("[Interactables:ST] " .. tostring(s)) end)
    _logf("ST %s", tostring(s))
end

local function _st_motion()
    local go = _char_go(_player())
    local m = nil
    pcall(function() m = go:call("getComponent(System.Type)", sdk.typeof("via.motion.Motion")) end)
    return m
end

-- HARD fallback exit: the jack-level trio + hand restores, in the load-bearing order.
-- Field round 2026-08-27 proved this alone leaves a GHOST after a NATIVE interaction —
-- the InteractManager session stays open (no B prompts, no jump/dash/sheathe) and the
-- station's own prop is never put back. It is kept ONLY as the escalation when the
-- native abort below does not land.
local function _st_release_hard(reason, rec)
    local ch = _player()
    if not ch then return end
    _st_log("hard: BEGIN (" .. tostring(reason) .. ")")
    local go = _char_go(ch)
    local aj = nil
    pcall(function() aj = go and go:call("getComponent(System.Type)", sdk.typeof("app.AdjustJack")) end)

    -- ⚠ CAPTURE EACH CALL SEPARATELY: one pcall around all three would hide which failed.
    local r_rej, r_restart, r_efsm = "no-aj", "no-aj", "no-aj"
    if aj then
        r_rej     = tostring(pcall(function() aj:call("rejectSelf") end))
        r_restart = tostring(pcall(function() aj:call("restartOwnerProcess", true) end))
        r_efsm    = tostring(pcall(function() aj:call("enableOwnerFSM") end))
    end
    _st_log("hard: trio done")

    -- Belt-and-braces re-asserts; none of these enters the interact framework.
    pcall(function()
        local human = ch:call("get_Human")
        local fsm = human and human.Fsm
        if fsm then fsm:set_Enabled(true) end
        local am = ch:call("get_ActionManager")
        if am then
            am:call("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)",
                0, "Wait", 0)
        end
    end)
    -- never leave a no-clip body behind
    pcall(function() ch:call("setCharacterControllerEnable", true) end)
    _st_log("hard: restores done")

    -- The prop borrow return. ⚠ ARITY TRAP: forceReturnEquipItem's bool is Optional and
    -- REFramework does not fill C# defaults — ALWAYS pass it. FALSE = put it back via the
    -- recorded BollowedGimmickPosition, which always has data. ⭐ ORDER: return BEFORE
    -- notifyEndInteract (the notify clears PickableObject); context cleared LAST.
    pcall(function()
        local human = ch:call("get_Human")
        local holder = human and human:call("get_GimmickHolder")
        if not holder then return end
        local lent = holder:get_field("PickableObject")
        local eqit = holder:get_field("EquipItem")
        if lent or eqit then
            pcall(function() holder:call("forceReturnEquipItem(System.Boolean)", false) end)
            pcall(function() holder:call("notifyEndInteract") end)
            pcall(function()
                local ctx = holder:get_field("Context")
                if ctx and ctx:call("get_HasEquipItem") then ctx:call("removeEquipItem") end
            end)
        end
    end)

    -- Neutral motion LAST — only after the body is live again.
    pcall(function()
        local motion = _st_motion()
        local layer = motion and motion:call("getLayer", 0)
        if layer then
            layer:call("changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                0, 0, 0.0, 6.0, 1, 1)
        end
    end)

    -- Owner-side prop reset for stations that OWN their prop (gm50_022's _Dough): when the
    -- native teardown never ran, nobody put the dough back — Aurora's floating ghost loaf.
    pcall(function()
        local owner = rec and rec.owner
        if not owner then return end
        local dough = owner:get_field("_Dough")
        local tf = dough and dough:call("get_Transform")
        local sp, sr = owner:get_field("_StartPos"), owner:get_field("_StartRot")
        if tf and sp then tf:call("set_Position", sp) end
        if tf and sr then tf:call("set_Rotation", sr) end
    end)

    _st_log("hard: prop return + owner reset done")
    ST.session = nil
    -- Post-release truth, READ ONLY (reads on InteractManager are safe; mutation is the
    -- fatal class). An open manager session is what suppresses jump/dash/B afterwards.
    local interacting = nil
    pcall(function()
        local mgr = sdk.get_managed_singleton("app.InteractManager")
        if mgr then interacting = mgr:call("isInteracting(app.Character)", ch) end
    end)
    ST.status = string.format("HARD released (%s) aj=[rej=%s restart=%s efsm=%s]%s",
        tostring(reason or "manual"), r_rej, r_restart, r_efsm,
        interacting == true and "  ⚠ MANAGER SESSION STILL OPEN — reload the save; tell Iris" or "")
    _st_log("hard: END — " .. ST.status)
end

-- ⭐⭐ THE EXIT (2026-08-27, read off the full app.InteractManager dump): the manager's
-- session record — app.InteractManager.ActiveInteract — carries a plain writable
-- `IsNeedAbort : System.Boolean`, and the manager's own update pump (updateActiveInteracts'
-- remove-predicate + processAbortedInteracts + the AbortedIntearacts list, Capcom's typo)
-- implements the game's FORCED teardown: the same path that rips a player out of a chair
-- when a monster grabs them, which demonstrably restores everything — jack, props, FSM,
-- actions, collision, session — without a crash. So the exit is ONE DATA WRITE: flag the
-- session and let Capcom's own machinery do the entire teardown. No manager method is ever
-- called (mutating CALLS are the 4-for-4 fatal class; field writes are our proven lever).
-- A watchdog in _st_frame confirms the session actually closed and escalates to the hard
-- release if the flag is ignored.
function _st_release(reason)
    local ch = _player()
    if not ch then return end
    local rec = nil
    pcall(function()
        local a = _active_native()
        rec = a and a.rec
    end)
    local flagged = false
    _st_log("release: requesting native abort (" .. tostring(reason) .. ") on "
        .. tostring(rec and rec.host or (ST.session and ST.session.host) or "?"))
    pcall(function()
        local mgr = sdk.get_managed_singleton("app.InteractManager")
        local a = mgr and mgr:call("getActiveInteract(app.Character)", ch)
        if a then
            a:set_field("IsNeedAbort", true)
            flagged = a:get_field("IsNeedAbort") == true
        end
    end)
    _st_log("release: flag write done (flagged=" .. tostring(flagged)
        .. ") — anything after this line is the GAME's abort processing")
    if flagged then
        ST.pending = { at = os.clock(), reason = tostring(reason or "manual"), rec = rec }
        ST.session = nil
        pcall(function()
            local IP = _G.IrisPrompt
            if IP and type(IP.clear) == "function" then IP.clear("interactables_station") end
        end)
        ST.status = string.format("native abort requested (%s)...", tostring(reason or "manual"))
        _logf("station %s", ST.status)
        return
    end
    -- no live manager session to flag — fall straight through to the hand release
    _st_release_hard(reason, rec)
end

-- ═══════════════════════════════════════════════════════════════════════════════════════
-- HELD-TOOL DRIVES — Engine C reborn, with a reason to exist.
-- ⭐ Field-proven 2026-08-27 (Aurora, InteractButton lab): THE NATIVE BORROW SURVIVES
-- Human.Fsm OFF — she swept with the real borrowed broom in hand. So a held loose tool
-- plus the owner's own authored clips is a REAL interaction (the prop is genuinely in the
-- hands), not the empty mime that retired Engine C for stations. Pick the tool up with the
-- game's own B (native borrow), then a second B starts using it.
-- IrisPromptBar renders the prompt; bar-less installs skip this extra for now.
-- ═══════════════════════════════════════════════════════════════════════════════════════
-- The game's own live interact always outranks a tool verb on the same button.
local function _st_native_busy_read()
    local IP = _G.IrisPrompt
    if IP and type(IP.native_busy) == "function" then
        local b = false
        pcall(function() b = IP.native_busy() == true end)
        return b
    end
    local b = false
    pcall(function()
        local mgr = sdk.get_managed_singleton("app.InteractManager")
        b = mgr and mgr:call("hasHighestPriorityObjectForPlayer") == true
    end)
    return b
end

local TOOLS = {
    gm50_007 = { verb = "Sweep", finish_verb = "Finish sweeping",
        cands = { { bank = 8509, path = "appsystem/gimmick/gm50_007/gm50_007_01_interact_motlist.motlist" },
                  { bank = 8508, path = "appsystem/gimmick/gm50_007/gm50_007_interact_motlist.motlist" } },
        names = { start  = "ch00_000_rol_sweep_idle_start",
                  loop   = "ch00_000_rol_sweep_idle_loop",
                  finish = "ch00_000_rol_sweep_idle_end" } },
}
local TL = { at = 0, key = nil, act = nil, prev = false, raw = nil,
             mounted = {}, holders = {}, clips = {}, res = {}, probed = {}, rtry = {} }
-- app.EquipItemID, baked verbatim from il2cpp_dump 2026-08-27. While any borrow is live,
-- GimmickHolderContext.EquipItemID carries the held tool's identity as this enum — DATA,
-- not an object walk. (The it10_xxx block is the instruments: fiddle it10_003 + bow
-- it10_004, drum2 it10_030 — the same table serves a future band feature.)
TL.eqid = {
    [1]="it02_000", [2]="it02_002", [3]="it02_005", [44]="it02_008",
    [4]="it03_000", [5]="it03_004", [6]="it03_005", [7]="it03_006", [8]="it03_007",
    [9]="it09_001", [10]="it10_001", [11]="it10_002", [12]="it10_003", [13]="it10_004",
    [14]="it10_005", [15]="it10_006", [16]="it10_007", [49]="it10_008", [17]="it10_011",
    [18]="it10_030", [19]="it10_031", [20]="it10_032", [21]="it10_033",
    [22]="it50_005", [46]="it50_007", [50]="it50_010_01", [47]="it50_013",
    [23]="it50_029", [45]="it50_031", [24]="it50_032", [25]="it50_033",
    [52]="it50_035_00", [48]="it50_042_01", [26]="it50_044", [27]="it50_055",
    [41]="it50_096_00", [43]="it50_298", [42]="it51_046", [28]="it51_367",
    [29]="it80_161", [30]="it80_162", [31]="it80_163", [55]="it81_010",
    [32]="it81_012", [33]="it81_028", [34]="it81_029", [35]="it81_031",
    [36]="it81_148", [51]="it81_157_00", [53]="it81_178_00", [54]="it81_178_01",
    [37]="it82_052", [38]="it99_002", [39]="it99_003", [40]="it99_600",
}

local function _tl_mount(bank, path)
    if TL.mounted[bank] == path then return true end
    local motion = _st_motion()
    if not motion then return false end
    local holder = nil
    pcall(function()
        local res = sdk.create_resource("via.motion.MotionListResource", path)
        if res then
            res = res:add_ref()
            holder = res:create_holder("via.motion.MotionListResourceHolder"):add_ref()
        end
    end)
    if not holder then return false end
    local ok = pcall(function()
        local n = motion:call("getDynamicMotionBankCount")
        local newBank, idx = nil, n
        for i = 0, n - 1 do
            local b = motion:call("getDynamicMotionBank", i)
            if b and b:call("get_BankID") == bank then newBank, idx = b, i break end
        end
        if not newBank then
            motion:call("setDynamicMotionBankCount", n + 1)
            newBank = sdk.create_instance("via.motion.DynamicMotionBank"):add_ref()
        end
        newBank:call("set_MotionList", holder)
        newBank:call("set_OverwriteBankID", true)
        newBank:call("set_BankID", bank)
        motion:call("setDynamicMotionBank", idx, newBank)
    end)
    if not ok then return false end
    TL.holders[bank], TL.mounted[bank] = holder, path
    _st_log("tool bank " .. bank .. " mounted")
    return true
end

local function _tl_clips(bank)
    if TL.clips[bank] then return TL.clips[bank] end
    local motion = _st_motion()
    if not motion then return nil end
    local map, n = {}, 0
    pcall(function()
        local count = tonumber(motion:call("getMotionCount", bank)) or 0
        for i = 0, count - 1 do
            local info = sdk.create_instance("via.motion.MotionInfo", true)
            if info then
                local got = motion:call(
                    "getMotionInfoByIndex(System.UInt32, System.UInt32, via.motion.MotionInfo)",
                    bank, i, info)
                if got ~= false then
                    local nm = tostring(info:call("get_MotionName") or "")
                    if nm ~= "" then map[nm] = tonumber(info:call("get_MotionID")); n = n + 1 end
                end
            end
        end
    end)
    if n == 0 then return nil end
    TL.clips[bank] = map
    return map
end

-- ⛔ per-motlist id law: resolve the triad BY NAME from the live bank, never a bare id.
-- ⚠ STREAMING LAW (field round 11): a freshly mounted motlist takes real time to load —
-- reading it in the mount frame returns ZERO clips. (The lab only ever worked because
-- mount and enumerate were two separate human button presses.) Resolution therefore
-- RETRIES on a 0.5s cadence for up to 8s, and fails permanently only once clips ARE
-- readable but the names mismatch — logging every name in the bank so the TOOLS row can
-- be corrected straight from the log.
local function _tl_resolve(key)
    local cur = TL.res[key]
    if cur then return cur end
    if cur == false then return nil end
    local now = os.clock()
    local rt = TL.rtry[key]
    if rt and now - (rt.last or 0) < 0.5 then return nil end
    if not rt then rt = { first = now }; TL.rtry[key] = rt end
    rt.last = now
    local row = TOOLS[key]
    local readable, total = 0, 0
    for _, c in ipairs(row.cands or {}) do
        total = total + 1
        if _tl_mount(c.bank, c.path) then
            local map = _tl_clips(c.bank)
            if map then
                readable = readable + 1
                local ids = { start = map[row.names.start], loop = map[row.names.loop],
                              finish = map[row.names.finish] }
                if ids.start and ids.loop and ids.finish then
                    TL.res[key] = { bank = c.bank, ids = ids }
                    TL.rtry[key] = nil
                    _st_log(string.format("tool %s resolved: bank %d %d/%d/%d",
                        key, c.bank, ids.start, ids.loop, ids.finish))
                    return TL.res[key]
                end
            end
        end
    end
    if total > 0 and readable >= total then
        -- every candidate bank is streamed and readable: the row's names are simply
        -- wrong. Harvest the truth and stop retrying.
        TL.res[key] = false
        for _, c in ipairs(row.cands or {}) do
            local map = TL.clips[c.bank]
            if map then
                local names = {}
                for nm in pairs(map) do names[#names + 1] = nm end
                table.sort(names)
                _st_log("tool " .. key .. " bank " .. c.bank .. " actual clips: "
                    .. table.concat(names, " | "))
            end
        end
        _st_log("tool " .. key .. " UNRESOLVED — the names above are the truth, fix the row")
    elseif now - (rt.first or now) > 8.0 then
        TL.res[key] = false
        _st_log("tool " .. key .. " UNRESOLVED — clips never streamed in 8s")
    end
    return nil
end

-- When a held tool has no TOOLS row yet, mount its VERIFIED motlist (the STATIONS table
-- is the map — those paths were read out of Capcom's own files, never reconstructed) and
-- write every clip name to the log ONCE. Each new tool Aurora picks up hands us the exact
-- names for its future TOOLS row. Zero motion is played — mount and read only.
local function _tl_probe_names(key)
    if not key or TL.probed[key] then return end
    local st = STATIONS[key]
    if not (st and st.bank and st.path) then
        local base = key:match("^(gm%d+_%d+)")
        st = base and STATIONS[base] or nil
    end
    if not (st and st.bank and st.path) then
        TL.probed[key] = true
        _st_log("probe " .. key .. ": no verified motlist on record — nothing mounted")
        return
    end
    if not _tl_mount(st.bank, st.path) then
        TL.probed[key] = true
        _st_log("probe " .. key .. ": motlist mount failed")
        return
    end
    -- STREAMING LAW: clips are never readable in the mount frame — the pump retries.
    TL.probed[key] = { bank = st.bank, first = os.clock(), last = 0 }
end

local function _tl_probe_pump()
    for key, p in pairs(TL.probed) do
        if type(p) == "table" then
            local now = os.clock()
            if now - (p.last or 0) >= 0.5 then
                p.last = now
                local map = _tl_clips(p.bank)
                if map then
                    local names = {}
                    for nm in pairs(map) do names[#names + 1] = nm end
                    table.sort(names)
                    _st_log("probe " .. key .. " clip names: " .. table.concat(names, " | "))
                    TL.probed[key] = true
                elseif now - (p.first or now) > 8.0 then
                    _st_log("probe " .. key .. ": clips never streamed in 8s")
                    TL.probed[key] = true
                end
            end
        end
    end
end

local function _tl_held_key()
    local key, raw = nil, nil
    pcall(function()
        local ch = _player()
        local human = ch and ch:call("get_Human")
        local holder = human and human:call("get_GimmickHolder")
        if not holder then return end
        -- Round 4 (the one that reads DATA): the borrow records its identity in
        -- GimmickHolderContext.EquipItemID. Field-proven that the object-graph routes all
        -- go nil mid-carry (getValidHoldingObject included), but the context enum is
        -- written by setEquipItem at borrow time and cleared by removeEquipItem.
        local ctx = holder:get_field("Context")
        if ctx then
            local v = ctx:get_field("EquipItemID")
            local id = tonumber(v)
            if not id and v ~= nil then
                pcall(function() id = tonumber(v:get_field("value__")) end)
            end
            if id and id ~= 0 then raw = TL.eqid[id] or ("eqid:" .. tostring(id)) end
        end
        -- Constraint carries (jars, crates) never set EquipItemID — walk the hold list.
        if not raw then
            local lst = holder:get_field("HoldObjects")
            local n = lst and tonumber(lst:call("get_Count")) or 0
            for i = 0, n - 1 do
                local ok = pcall(function()
                    local info = lst:call("get_Item", i)
                    local gib = info and info:get_field("Object")
                    local nm = gib and tostring(gib:call("get_GameObject"):call("get_Name"))
                    if nm and nm ~= "" and nm ~= "nil" then raw = nm end
                end)
                if ok and raw then break end
            end
        end
        -- Loose pickable pre-borrow state, the original working path.
        if not raw then
            local gib = holder:get_field("PickableObject")
            if gib then
                pcall(function() raw = tostring(gib:call("get_GameObject"):call("get_Name")) end)
                if raw == "nil" or raw == "" then raw = nil end
            end
        end
        if raw then
            local twin = raw:lower():match("^i?t(%d+_%d+.*)$")
            key = twin and _norm("gm" .. twin) or _norm(raw)
        end
    end)
    if raw ~= TL.raw then
        TL.raw = raw
        if raw then
            _st_log("holding: " .. tostring(raw) .. " -> " .. tostring(key or "?")
                .. ((key and TOOLS[key]) and "" or " (no tool row)"))
            if key and not TOOLS[key] then _tl_probe_names(key) end
        end
    end
    return key and TOOLS[key] and key or nil
end

local function _tl_stop(reason)
    local act = TL.act
    TL.act = nil
    pcall(function()
        local IP = _G.IrisPrompt
        if IP and type(IP.clear) == "function" then IP.clear("interactables_tool") end
    end)
    if not act then return end
    -- proven restore order: FSM live FIRST, action stack re-seeded, motion write LAST.
    pcall(function()
        local ch = _player()
        local human = ch and ch:call("get_Human")
        local fsm = human and human.Fsm
        if fsm then fsm:set_Enabled(true) end
        local am = ch and ch:call("get_ActionManager")
        if am then
            am:call("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)",
                0, "Wait", 0)
        end
    end)
    pcall(function()
        local motion = _st_motion()
        local layer = motion and motion:call("getLayer", 0)
        if layer then
            layer:call("changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                0, 0, 0.0, 6.0, 1, 1)
        end
    end)
    _st_log("tool drive stopped (" .. tostring(reason) .. ")")
end

local function _tl_play(phase)
    local act = TL.act
    if not act then return false end
    local ok = pcall(function()
        local motion = _st_motion()
        local layer = motion and motion:call("getLayer", 0)
        if not layer then error("no layer 0") end
        layer:call("changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
            act.res.bank, act.res.ids[phase], 0.0, 6.0, 1, 1)
    end)
    if ok then act.phase, act.started = phase, os.clock() end
    return ok
end

local function _tl_move_mag()
    local m = 0.0
    pcall(function()
        if reframework:is_key_down(0x57) or reframework:is_key_down(0x41)
            or reframework:is_key_down(0x53) or reframework:is_key_down(0x44) then m = 1.0 end
    end)
    if m < 0.3 then
        pcall(function()
            local gp = sdk.get_native_singleton("via.hid.GamePad")
            local td = sdk.find_type_definition("via.hid.GamePad")
            local dev = gp and td and sdk.call_native_func(gp, td, "get_MergedDevice")
            if not dev then return end
            local v = dev:call("get_AxisL")
            if v then
                local x, y = tonumber(v.x) or 0, tonumber(v.y) or 0
                m = math.sqrt(x * x + y * y)
            end
        end)
    end
    return m
end

local function _tl_frame()
    if M.stations == false then if TL.act then _tl_stop("disabled") end return end
    _tl_probe_pump()

    local down = _exit_binding_down()
    local edge = down and not TL.prev
    TL.prev = down

    local act = TL.act
    if act then
        if _loading() or _menu_open() then return _tl_stop(_loading() and "loading" or "menu") end
        local kill = false
        pcall(function() kill = reframework:is_key_down(0x08) == true end)
        if kill then return _tl_stop("backspace") end
        if _tl_move_mag() > 0.3 or _binding_down("space, cross") then
            return _tl_stop("movement")
        end
        if edge and act.phase ~= "finish" then
            if not _tl_play("finish") then return _tl_stop("finish clip failed") end
        elseif edge then
            return _tl_stop("second press during finish")
        end
        -- frame cursor: Fsm off stops the layer clock, so we advance it (the dough shape)
        pcall(function()
            local motion = _st_motion()
            local layer = motion and motion:call("getLayer", 0)
            if not layer then return end
            local elapsed = math.max(0.0, os.clock() - (tonumber(act.started) or 0))
            local ef = tonumber(layer:call("get_EndFrame")) or 0.0
            local raw = elapsed * 60.0
            if act.phase ~= "loop" and ef > 1.0 and raw >= ef - 1.0 then
                if act.phase == "start" then
                    if not _tl_play("loop") then _tl_stop("loop clip failed") end
                else
                    _tl_stop("finished")
                end
                return
            end
            local frame = raw
            if act.phase == "loop" and ef > 1.0 then frame = frame % ef
            elseif ef > 1.0 then frame = math.min(frame, ef - 1.0) end
            layer:call("set_Frame", frame)
        end)
        pcall(function()
            local IP = _G.IrisPrompt
            if IP and type(IP.set) == "function" and TL.act then
                local row = TOOLS[TL.act.key] or {}
                local pgo = _char_go(_player())
                IP.set("interactables_tool",
                    TL.act.phase == "finish" and "Stopping"
                        or (row.finish_verb or "Finish"), 5, 0.05,
                    pgo and _pos(pgo), pgo)
            end
        end)
        return
    end

    -- idle: offer the verb while a known tool is genuinely in hand
    local now = os.clock()
    if now - (tonumber(TL.at) or 0) < 0.25 then return end
    TL.at = now
    if _loading() or _menu_open() or ST.session or ST.pending then TL.key = nil; return end
    local jacked = false
    pcall(function()
        local ch = _player()
        jacked = ch and ch:call("get_IsJacked") == true
    end)
    if jacked then TL.key = nil; return end
    TL.key = _tl_held_key()
    if not TL.key then
        pcall(function()
            local IP = _G.IrisPrompt
            if IP and type(IP.clear) == "function" then IP.clear("interactables_tool") end
        end)
        return
    end
    local IP = _G.IrisPrompt
    if not (IP and type(IP.set) == "function") then return end
    local row = TOOLS[TL.key]
    -- STREAMING LAW: warm the resolution while the tool is merely in hand, and offer the
    -- verb only once the triad is playable — a B press on a visible prompt then always works.
    if not _tl_resolve(TL.key) then
        pcall(function()
            if type(IP.clear) == "function" then IP.clear("interactables_tool") end
        end)
        return
    end
    local pgo = _char_go(_player())
    pcall(function()
        IP.set("interactables_tool", tostring(row.verb), 1, 0.4, pgo and _pos(pgo), pgo)
    end)
    if edge then
        local w = nil
        pcall(function() w = IP.winner() end)
        if w ~= "interactables_tool" then return end
        local busy = _st_native_busy_read()
        if busy then return end
        local res = _tl_resolve(TL.key)
        if not res then return end
        local ok = pcall(function()
            local ch = _player()
            local human = ch:call("get_Human")
            local fsm = human and human.Fsm
            if not fsm then error("no Human.Fsm") end
            fsm:set_Enabled(false)
        end)
        if not ok then return end
        TL.act = { key = TL.key, res = res }
        if not _tl_play("start") then _tl_stop("start clip failed") end
        _st_log("tool drive started: " .. TL.key .. " (" .. tostring(row.verb) .. ")")
    end
end

-- The worker brings the tool (field-proven on the hay, 2026-08-27: pitchfork in hand +
-- native station = the real composed animation; empty hands = a mime). When a station
-- lends nothing, conjure the eqit prop into the hands through the player's own equip
-- machinery — app.EquipItemController.requestExternal, reached via get_EquipItemCtrl
-- (⛔ NOT get_component — it is not a component). draw=true attaches, draw=false stows.
-- No gimmick, no jack, no InteractManager anywhere near this call.
local function _st_conjure(id, draw, quiet)
    local ok = false
    -- requestExternal has exactly ONE overload — call by bare name so REFramework does
    -- the resolution (dump-verified accessor: app.Human.get_EquipItemCtrl, a property,
    -- not a component). Error text is logged verbatim: a FAILED here must convict itself.
    local ran, err = pcall(function()
        local ch = _player()
        local human = ch and ch:call("get_Human")
        local ctrl = human and human:call("get_EquipItemCtrl")
        if not ctrl then error("EquipItemCtrl is nil") end
        -- Field round: bare nil for the two Nullable<> params makes the invoker throw
        -- ("Invoke threw an exception"). Pass ZEROED Nullable structs — HasValue=false
        -- is a genuine null argument the invoker accepts.
        local nv = ValueType.new(sdk.find_type_definition("System.Nullable`1<via.vec3>"))
        local nq = ValueType.new(sdk.find_type_definition("System.Nullable`1<via.Quaternion>"))
        if not (nv and nq) then error("Nullable struct creation failed") end
        ctrl:call("requestExternal", id, draw and true or false, "R_PropA", nv, nq)
        ok = true
    end)
    if not quiet then
        _st_log(string.format("prop %s: eq id %d (%s)",
            draw and "conjure" or "return", tonumber(id) or -1,
            ok and "requested" or ("FAILED: " .. tostring(err or "?"))))
    end
    return ok
end

-- P1 BED PROBE (read-only, 2026-08-27 disassembly round). While standing at an unlocked
-- bed, dump the live Work state that decides serving. Reading key:
--   _IsInteractEnable=false            → sheet/class gate (Gm51_115 same-sheet / timer / broken)
--   enable=true, canPlayer=false       → coordinate gate (distance/angle/terrain-ray/camera)
--   BOTH true                          → the point IS being served; only the glyph was invisible
--   patched=false                      → we patched a different data object than the live one
local BP = { at = 0 }
local function _bed_probe_tick()
    local now = os.clock()
    if now - (tonumber(BP.at) or 0) < 5.0 then return end
    BP.at = now
    local pgo = _char_go(_player())
    -- ⛔ SPACE LAW (field 2026-08-27): getInteractPointPosition returns UNIVERSAL-space
    -- positions. Comparing them against transform _pos produced a constant ~1km phantom
    -- offset ("nearest bed 890m" while standing ON one) — every proximity verdict before
    -- this line was comparing across coordinate spaces. _upos or nothing.
    local pp = pgo and _upos(pgo)
    if not pp then return end
    local seen = {}
    local nrec, nio, best = 0, 0, nil
    for _, r in pairs(unlocks) do
        -- Bed unlocks come from the AUTHORED pass and rarely carry a runtime io — but the
        -- owner gimmick always does: GimmickBase.InteractiveObject (dump-verified field).
        local rio = r.io
        if r.kind == "bed" and not rio and r.owner then
            pcall(function() rio = r.owner:get_field("InteractiveObject") end)
        end
        if r.kind == "bed" then
            nrec = nrec + 1
            if rio then nio = nio + 1 end
        end
        local rio_addr = r.io_addr or (rio and _addr(rio)) or 0
        if r.kind == "bed" and rio and not seen[rio_addr] then
            seen[rio_addr] = true
            pcall(function()
                local io = rio
                local n = tonumber(io:call("getNumInteractPoint")) or 0
                local near = false
                for i = 0, n - 1 do
                    local q = io:call("getInteractPointPosition", i)
                    if q then
                        local dx, dy, dz = q.x - pp.x, q.y - pp.y, q.z - pp.z
                        local d2 = dx * dx + dy * dy + dz * dz
                        if not best or d2 < best then best = d2 end
                        if d2 < 16.0 then near = true break end
                    end
                end
                if not near then return end
                BP.hit = true
                local works = io:get_field("Works")
                for i = 0, n - 1 do
                    local w = works and works:call("get_Item", i)
                    if w then
                        local en, ia, cp, da = "?", "?", "?", nil
                        pcall(function() en = tostring(w:get_field("_IsInteractEnable")) end)
                        pcall(function() ia = tostring(w:get_field("_IsInteracted")) end)
                        pcall(function() cp = tostring(w:get_field("_canPlayerInteract")) end)
                        pcall(function() da = _addr(w:get_field("_Data")) end)
                        local icon = "?"
                        pcall(function() icon = tostring(io:call("hasIcon", i)) end)
                        _st_log(string.format(
                            "BEDPROBE %s[%d] enable=%s interacted=%s canPlayer=%s hasIcon=%s patched=%s",
                            tostring(r.host), i, en, ia, cp, icon,
                            tostring(da ~= nil and da == _addr(r.point))))
                    end
                end
                pcall(function()
                    local mgr = sdk.get_managed_singleton("app.InteractManager")
                    if mgr then
                        _st_log("BEDPROBE manager hasHighest="
                            .. tostring(mgr:call("hasHighestPriorityObjectForPlayer")))
                    end
                end)
            end)
        end
    end
    -- Silence is not data — when no bed dumped, report the coverage so a quiet log still
    -- names the reason (no records at all / records but no io / just too far away).
    if not BP.hit then
        if now - (tonumber(BP.idle_at) or 0) > 15.0 then
            BP.idle_at = now
            if nrec == 0 then
                _st_log("BEDPROBE: zero bed unlock records exist right now")
            else
                _st_log(string.format("BEDPROBE idle: %d bed records (%d with io), nearest point %s",
                    nrec, nio, best and string.format("%.1fm", math.sqrt(best)) or "unknown"))
            end
            -- ENGINE-REGISTRY sweep (2026-08-27: her Battahl bed is invisible to OUR scan —
            -- so ask the ENGINE. InteractManager's updaters hold every registered
            -- InteractiveObject in the world; reads on the manager are proven safe.)
            pcall(function()
                local mgr = sdk.get_managed_singleton("app.InteractManager")
                local ups = mgr and mgr:get_field("InteractiveObjectUpdaters")
                if not ups then _st_log("ENGINESCAN: no updaters array") return end
                local found = 0
                local nu = tonumber(ups:call("get_Length")) or 0
                for u = 0, nu - 1 do
                    local lst = nil
                    pcall(function()
                        local upd = ups:get_element(u)
                        lst = upd and upd:get_field("InteractiveObjectList")
                    end)
                    local n = lst and tonumber(lst:call("get_Count")) or 0
                    for i = 0, n - 1 do
                        pcall(function()
                            local io = lst:call("get_Item", i)
                            if not io then return end
                            local np = tonumber(io:call("getNumInteractPoint")) or 0
                            local bd, bi = nil, nil
                            for p = 0, np - 1 do
                                local q = io:call("getInteractPointPosition", p)
                                if q then
                                    local dx, dy, dz = q.x - pp.x, q.y - pp.y, q.z - pp.z
                                    local d2 = dx * dx + dy * dy + dz * dz
                                    if not bd or d2 < bd then bd, bi = d2, p end
                                end
                            end
                            if bd and bd < 36.0 then
                                found = found + 1
                                local nm = "?"
                                pcall(function()
                                    local og = io:call("get_Owner")
                                    nm = tostring(og:call("get_Name"))
                                end)
                                local ct, icon = "?", "?"
                                pcall(function() ct = tostring(io:call("getTargetCharacterType", bi)) end)
                                pcall(function() icon = tostring(io:call("hasIcon", bi)) end)
                                _st_log(string.format("ENGINESCAN %.1fm %s pts=%d ct[%d]=%s icon=%s",
                                    math.sqrt(bd), nm, np, bi, ct, icon))
                                -- (bed feeding moved to _registry_tick — the probe-tied
                                -- version made bed prompts take ~15s to appear)
                            end
                        end)
                    end
                end
                _st_log("ENGINESCAN done: " .. found .. " registered interactables within 6m")
            end)
        end
    end
    BP.hit = nil
end

-- ═══════════════════════════════════════════════════════════════════════════════════════
-- MINI COOK (release 2026-08-27). Native cooking at TOWN pots. The real cook GUI is
-- camp-only (2 crash-proven routes — see memory); this is the SAME MECHANICS with our
-- list: the 8 real camp meats, real consumption (deleteItem — IrisFarming's field-proven
-- overload), the real party buffs (SpecialBuffManager.startBuff — disassembly-proven
-- camp-free), served through the native 4-slot dialog (IrisDeedSign machinery:
-- reqDisp/getDialogState, RetVal Sel0..3 = 1..4, Cancel = 5).
local MEATS = {
    { id = 25,  buff = 3, name = "Scrag of Beast",
      toast = "You grilled a Scrag of Beast — a hearty meal! Party Strength, Defense & Stamina up." },
    { id = 26,  buff = 5, name = "Sour Scrag of Beast",
      toast = "You grilled a Sour Scrag — pungent, but it fills bellies. Party buffed." },
    { id = 27,  buff = 0, name = "Rotten Scrag of Beast",
      toast = "You grilled a Rotten Scrag... a dubious meal. The party may regret this." },
    { id = 28,  buff = 4, name = "Beast Steak",
      toast = "You grilled a Beast Steak — a fine meal! Party Strength, Defense & Stamina up." },
    { id = 29,  buff = 6, name = "Sour Beast Steak",
      toast = "You grilled a Sour Steak — sharp on the tongue. Party buffed." },
    { id = 30,  buff = 1, name = "Rotten Beast Steak",
      toast = "You grilled a Rotten Steak... a dubious meal. The party may regret this." },
    { id = 41,  buff = 2, name = "Dried Steak",
      toast = "You grilled a Dried Steak — travel fare done right. Party buffed." },
    { id = 114, buff = 7, name = "Exquisite Dried Meat",
      toast = "You grilled Exquisite Dried Meat — a feast! The party eats like royalty." },
}
-- the "you cooked a thing" announcement (RiftSpeak-style): IrisFont parchment line,
-- bottom-left, fade in/hold/out. Silently absent without the d2d plugin.
local TOAST = { txt = nil, at = 0 }
local function _mc_toast(s) TOAST.txt, TOAST.at = s, os.clock() end
pcall(function()
    d2d.register(function() end, function()
        if not TOAST.txt then return end
        local age = os.clock() - TOAST.at
        if age > 5.0 then TOAST.txt = nil return end
        local a = 1.0
        if age < 0.25 then a = age / 0.25
        elseif age > 4.0 then a = 1.0 - (age - 4.0) end
        local sh = 1080
        pcall(function()
            local ok, _, h = pcall(d2d.surface_size)
            if ok and h and h > 0 then sh = h end
        end)
        local alpha = math.floor(255 * math.max(0, math.min(1, a)))
        local F = _G.IrisFont
        local col = alpha * 0x1000000 + 0xEAD8B0
        if not (F and F.text and F.text(TOAST.txt, 84, sh - 176, col, 30)) then
            pcall(function() draw.text(TOAST.txt, 84, sh - 176, alpha * 0x1000000 + 0xB0D8EA) end)
        end
    end)
end)
-- All NINE prefabs carrying the game's own Cook verb (IrisFarming's field-built list):
-- the hanging cauldron, the three campfire pots, the five camp stew pots. Matched by
-- BASE id — variants carry _NN suffixes the bases do not.
local MC_POTS = {
    gm80_256 = true, gm51_381 = true, gm51_382 = true, gm51_383 = true,
    gm80_060 = true, gm80_061 = true, gm80_062 = true, gm80_063 = true, gm80_064 = true,
}
local MC = { at = 0, near = nil, prev = false, open = false, baseline = nil,
             opened_at = 0, closed_at = 0, opts = nil, more = false, page = 1,
             stir_until = nil }

local function _mc_party()
    local out = {}
    local ch = _player()
    if ch then out[#out + 1] = ch end
    pcall(function()
        local pm = sdk.get_managed_singleton("app.PawnManager")
        local lst = pm and pm:call("get_PawnCharacterList")
        local n = lst and tonumber(lst:call("get_Count")) or 0
        for i = 0, n - 1 do
            -- ⚠ app.Pawn is NOT app.Character — unwrap via get_CachedCharacter
            local pawn = lst:call("get_Item", i)
            local c = pawn and pawn:call("get_CachedCharacter")
            if c then out[#out + 1] = c end
        end
    end)
    return out
end

local function _mc_avail()
    local t, party = {}, _mc_party()
    local im = sdk.get_managed_singleton("app.ItemManager")
    if not im then return t end
    for _, m in ipairs(MEATS) do
        local total, holder = 0, nil
        for _, ch in ipairs(party) do
            local n = 0
            pcall(function()
                n = tonumber(im:call("getHaveNum(System.Int32, app.Character)", m.id, ch)) or 0
            end)
            if n > 0 and not holder then holder = ch end
            total = total + n
        end
        if total > 0 then t[#t + 1] = { m = m, count = total, holder = holder } end
    end
    return t
end

local function _mc_pick()
    local p
    pcall(function()
        local gm = sdk.get_managed_singleton("app.GuiManager")
        local rv = gm and gm:call("getDialogState")
        if rv == nil then return end
        if type(rv) == "number" then p = rv
        else pcall(function() p = sdk.to_int64(rv) & 0xFFFFFFFF end) end
    end)
    return p
end

local function _mc_show(prompt, l1, l2, l3, l4)
    local ok = pcall(function()
        local gm = sdk.get_managed_singleton("app.GuiManager")
        local dialog = gm and gm:get_field("Dialog")
        if not dialog then error("no Dialog") end
        gm:call("requestGuiType", 14)
        dialog:call("reqDisp", prompt, l1 or "", l2 or "", l3 or "", l4 or "",
            true, 0, true, 58, 0, -1, nil,
            false, false, false, false, false, false, true, 0.0)
        MC.open, MC.opened_at, MC.baseline = true, os.clock(), _mc_pick()
    end)
    if not ok then _st_log("cook dialog reqDisp FAILED") end
end

local function _mc_close()
    pcall(function()
        local gm = sdk.get_managed_singleton("app.GuiManager")
        local dialog = gm and gm:get_field("Dialog")
        if dialog then dialog:call("reqClose") end
        gm:call("requestHideGuiType", 14)
    end)
    MC.open = false
    MC.closed_at = os.clock()   -- grace: the picking press must not instantly re-open
end

local function _mc_menu(page)
    local avail = _mc_avail()
    if #avail == 0 then
        MC.opts, MC.more = {}, false
        _mc_show("Nothing to cook - the pot wants meat.", "Ah well.")
        return
    end
    -- every page keeps a visible Cancel (the IrisFarming pagination lesson)
    local per = (#avail > 3) and 2 or 3
    local start = (page - 1) * per
    local opts, labels = {}, {}
    for i = 1, per do
        local it = avail[start + i]
        if it then
            opts[#opts + 1] = it
            labels[#labels + 1] = string.format("Grill %s (%d)", it.m.name, it.count)
        end
    end
    MC.more = (start + per) < #avail
    if MC.more then labels[#labels + 1] = "More..." end
    labels[#labels + 1] = "Cancel"
    MC.opts, MC.page = opts, page
    _mc_show("Cook what?", labels[1], labels[2], labels[3], labels[4])
end

local function _mc_stop_stir()
    if not MC.stir_until then return end
    MC.stir_until = nil
    -- proven restore order: FSM live FIRST, action re-seed, neutral motion LAST
    pcall(function()
        local ch = _player()
        local human = ch and ch:call("get_Human")
        if human and human.Fsm then human.Fsm:set_Enabled(true) end
        local am = ch and ch:call("get_ActionManager")
        if am then
            am:call("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)",
                0, "Wait", 0)
        end
        local motion = _st_motion()
        local layer = motion and motion:call("getLayer", 0)
        if layer then
            layer:call("changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                0, 0, 0.0, 6.0, 1, 1)
        end
    end)
end

local function _mc_cook(entry)
    local ok = false
    pcall(function()
        sdk.get_managed_singleton("app.ItemManager"):call(
            "deleteItem(System.Int32, System.Int32, app.Character)",
            entry.m.id, 1, entry.holder)
        ok = true
    end)
    if not ok then _st_log("cook: deleteItem failed — nothing consumed, no buff") return end
    local fed = 0
    for _, ch in ipairs(_mc_party()) do
        pcall(function()
            local human = ch:call("get_Human")
            local sb = human and human:call("get_SpecialBuffManager")
            if sb then sb:call("startBuff", entry.m.buff); fed = fed + 1 end
        end)
    end
    _st_log(string.format("cooked %s — party buff on %d member(s)", entry.m.name, fed))
    _mc_toast(entry.m.toast or ("You cooked a " .. entry.m.name .. "."))
    -- the stir: brief held-FSM native clip (bank 60 ships with the player, no mount)
    pcall(function()
        local ch = _player()
        local human = ch and ch:call("get_Human")
        if human and human.Fsm then human.Fsm:set_Enabled(false) end
        local motion = _st_motion()
        local layer = motion and motion:call("getLayer", 0)
        if layer then
            layer:call("changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                60, 1104, 0.0, 6.0, 1, 1)
            MC.stir_until = os.clock() + 5.0
        end
    end)
end

local function _mc_frame()
    if M.stations == false then return end
    local now = os.clock()

    if MC.stir_until and (now >= MC.stir_until or _tl_move_mag() > 0.3) then
        _mc_stop_stir()
    end

    -- dialog result pump
    if MC.open then
        local p = _mc_pick()
        if p and p ~= 0 and p ~= (MC.baseline or 0) and now - MC.opened_at > 0.3 then
            local opts, more, page = MC.opts or {}, MC.more, MC.page or 1
            _mc_close()
            local sel = tonumber(p) or 0
            if sel == 5 then return end
            if sel >= 1 and sel <= #opts then
                _mc_cook(opts[sel])
            elseif more and sel == #opts + 1 then
                _mc_menu(page + 1)
            end
        end
        return
    end

    -- pot proximity comes from the ENGINE-REGISTRY sweep (_registry_tick) — the catalog
    -- scan list excludes player-capable pots. The stored POSITION is re-checked every
    -- frame (field: the sweep timestamp alone let the prompt follow her as she ran off).
    local near = false
    if MC.near and now - (tonumber(MC.near) or 0) < 6.0 and MC.near_pos then
        local pgo2 = _char_go(_player())
        local pu = pgo2 and _upos(pgo2)
        if pu then
            local dx = MC.near_pos.x - pu.x
            local dy = MC.near_pos.y - pu.y
            local dz = MC.near_pos.z - pu.z
            near = dx * dx + dy * dy + dz * dz < 6.76
        end
    end
    if near and (ST.session or ST.pending or TL.act) then near = false end

    local down = _exit_binding_down()
    local edge = down and not MC.prev
    MC.prev = down
    if now - (tonumber(MC.closed_at) or 0) < 0.4 then return end
    if not near or MC.stir_until then
        pcall(function()
            local IP = _G.IrisPrompt
            if IP and type(IP.clear) == "function" then IP.clear("interactables_cook") end
        end)
        return
    end
    pcall(function()
        local IP = _G.IrisPrompt
        if IP and type(IP.set) == "function" then
            local pgo = _char_go(_player())
            IP.set("interactables_cook", "Cook", 1, 0.4, pgo and _pos(pgo), pgo)
        end
    end)
    if edge then
        local w
        pcall(function() w = _G.IrisPrompt and _G.IrisPrompt.winner() end)
        if w ~= "interactables_cook" then return end
        if _st_native_busy_read() then return end
        _mc_menu(1)
    end
end

-- ⛔⛔ WIRETAP HOOKS REMOVED 2026-08-27 16:20 — CRASH-PROVEN. Log-only sdk.hooks on
-- GuiManager.setLoadGuiType + EquipItemController.setInfoToController CTD'd vanilla camp
-- cooking on their first firing (dump: AV read at -1 in the il2cpp dispatch-stub zone,
-- 0x1459d9a03 — above the managed ceiling, the hook-machinery signature). The same
-- answers come crash-free from STATIC disassembly of the call sites (capstone is on
-- disk: diagnostics/disasm_va.ps1). Never re-add runtime hooks for this.

-- COOK PROBE (2026-08-27 research): proves the native "Cook what?" menu end-to-end with
-- zero item loss. `GuiManager:requestCampMeatSelect()` is a zero-arg opener disassembly-
-- proven byte-identical to the campfire pot's own SelectMeat call. ⛔ GUI requests are
-- legal ONLY on the UpdateBehavior application entry (guimanager-menu-openers law).
-- ⛔ setupBuff landmine: null CampManager.CampBuffDefineUserData = native AV on first
-- list selection — the probe refuses to open in that case.
local CK = { req = false, open = false }
re.on_application_entry("UpdateBehavior", function()
    if CK.inst_req then
        CK.inst_req = false
        -- ⛔⛔ ROUTE DEAD — crash-proven 2026-08-27 18:18 (dump: towncook_crash.dmp), the
        -- SAME faulting instruction as the first cook crash: PrefabController.get_Ready
        -- on an invalid controller. requestInstantiate does not CREATE PrefabControllers;
        -- they are born when a GUI SCENE loads. The next lever is
        -- GuiManager.requestLoadScene(List<GUISceneType>) with ui041901's scene — decode
        -- the GuiType→GUISceneType mapping STATICALLY before any live attempt.
        _st_log("COOKPROBE: town route disabled — requestInstantiate is crash-proven; "
            .. "waiting on the requestLoadScene decode")
    elseif CK.inst_wait then
        pcall(function()
            local gm = sdk.get_managed_singleton("app.GuiManager")
            if gm and gm:call("IsLoadGuiType", 45) then
                CK.inst_wait = false
                _st_log("COOKPROBE: cook GUI registered — opening the native menu")
                CK.req = true
            elseif os.clock() - (tonumber(CK.inst_at) or 0) > 6.0 then
                CK.inst_wait = false
                _st_log("COOKPROBE: instantiate never registered (6s) — parent/folder needs decoding")
            end
        end)
    elseif CK.req then
        CK.req = false
        pcall(function()
            local gm = sdk.get_managed_singleton("app.GuiManager")
            local cm = sdk.get_managed_singleton("app.CampManager")
            local dm = sdk.get_managed_singleton("app.DemoMediator")
            if not gm then _st_log("COOKPROBE: no GuiManager") return end
            local loaded, prefab, buffdef, allowed = "?", "?", "?", "?"
            pcall(function() loaded = tostring(gm:call("IsLoadGuiType", 45)) end)
            pcall(function() prefab = tostring(gm:call("getPrefab", 45) ~= nil) end)
            pcall(function() buffdef = tostring(cm ~= nil
                and cm:get_field("CampBuffDefineUserData") ~= nil) end)
            pcall(function() allowed = tostring(dm and dm:call("get_IsRequestAllowed")) end)
            _st_log(string.format(
                "COOKPROBE preflight: gui45loaded=%s prefab=%s buffdef=%s demoAllowed=%s",
                loaded, prefab, buffdef, allowed))
            -- instantiate-pump state (read-only): town-vs-camp comparison data for the
            -- unexplained crash-1 residue. CtrlList entries persist per prefab.
            pcall(function()
                local ic = gm:get_field("InstCtrl")
                local cl = ic and ic:get_field("CtrlList")
                local il = ic and ic:get_field("InstList")
                _st_log(string.format("COOKPROBE instctrl: ctrls=%s pending=%s",
                    tostring(cl and cl:call("get_Count")), tostring(il and il:call("get_Count"))))
            end)
            if buffdef ~= "true" then
                _st_log("COOKPROBE refused: CampBuffDefineUserData nil — opening would AV")
                return
            end
            -- ⛔ CRASH-PROVEN 2026-08-27 14:53 (dump read: null-this AV in
            -- app.PrefabController.get_Ready @0x14028b4b0): when IsLoadGuiType(45) is
            -- false the menu's PrefabController does not exist and the open request
            -- dereferences it. The load route is setLoadGuiType(45, bool, bool) — bools
            -- undecoded, do NOT cold-call; research first.
            if loaded ~= "true" then
                _st_log("COOKPROBE refused: GuiType 45 not loaded here (camp-only so far) — "
                    .. "opening would crash. Needs the setLoadGuiType route decoded first.")
                return
            end
            gm:call("requestCampMeatSelect")
            CK.open = true
            _st_log("COOKPROBE: native meat-select requested — choose or cancel; nothing is consumed")
        end)
    elseif CK.open then
        pcall(function()
            local gm = sdk.get_managed_singleton("app.GuiManager")
            if gm and gm:call("isEndMenuUI") then
                CK.open = false
                local r = nil
                pcall(function() r = tonumber(gm:call("get_MenuUIResult")) end)
                _st_log("COOKPROBE result: " .. tostring(r)
                    .. " (-1 = cancelled; 25-30/41/114 = chosen meat ItemID — not consumed)")
            end
        end)
    end
end)

-- FIRST-CLASS REGISTRY TICK (release round). One fast sweep of the engine's own
-- InteractiveObject registry serving two consumers:
--   (a) BED FEEDING — unlocks catalog-invisible beds (gm51_092 law: raw-name match, never
--       _norm) within 10m, on a 2.5s cadence instead of the probe's 15s;
--   (b) COOK POT detection for the mini cook prompt (the catalog scan list excludes
--       player-capable pots entirely).
local BF = { at = 0, log = {} }
local function _registry_tick()
    if M.stations == false then return end
    local now = os.clock()
    if now - (tonumber(BF.at) or 0) < 2.5 then return end
    BF.at = now
    local pgo = _char_go(_player())
    local pp = pgo and _upos(pgo)
    if not pp then return end
    pcall(function()
        local mgr = sdk.get_managed_singleton("app.InteractManager")
        local ups = mgr and mgr:get_field("InteractiveObjectUpdaters")
        if not ups then return end
        local nu = tonumber(ups:call("get_Length")) or 0
        for u = 0, nu - 1 do
            local lst
            pcall(function()
                local upd = ups:get_element(u)
                lst = upd and upd:get_field("InteractiveObjectList")
            end)
            local n = lst and tonumber(lst:call("get_Count")) or 0
            for i = 0, n - 1 do
                pcall(function()
                    local io = lst:call("get_Item", i)
                    if not io then return end
                    local nm
                    pcall(function() nm = tostring(io:call("get_Owner"):call("get_Name")) end)
                    if not nm then return end
                    local low = nm:lower()
                    local base = low:match("^(gm%d+_%d+)") or low
                    local isbed = M.native_beds ~= false
                        and (BED_KEYS[low] or BED_KEYS[base])
                        and not (M.st_off or {})[BED_KEYS[low] and low or base]
                    local ispot = MC_POTS[base] == true
                    if not (isbed or ispot) then return end
                    local np = tonumber(io:call("getNumInteractPoint")) or 0
                    local bd, bq = nil, nil
                    for p = 0, np - 1 do
                        local q = io:call("getInteractPointPosition", p)
                        if q then
                            local dx, dy, dz = q.x - pp.x, q.y - pp.y, q.z - pp.z
                            local d2 = dx * dx + dy * dy + dz * dz
                            if not bd or d2 < bd then bd, bq = d2, q end
                        end
                    end
                    if not bd then return end
                    if ispot and bd < 5.29 then
                        MC.near = now
                        MC.near_pos = { x = bq.x, y = bq.y, z = bq.z }
                    end
                    if isbed and bd < 100.0 then
                        local key = BED_KEYS[low] and low or base
                        local dl = io:get_field("DataList")
                        local ndl = dl and tonumber(dl:call("get_Count")) or 0
                        for d = 0, ndl - 1 do
                            local pt = dl:call("get_Item", d)
                            if pt then
                                local okp = _patch_search_point(pt, "bed", nm,
                                    "bedfeed", d, io, nil, key)
                                if okp then
                                    _st_log("BEDFEED unlocked " .. key .. "[" .. d .. "]")
                                end
                            end
                        end
                    end
                end)
            end
        end
    end)
end

-- Station camera. ⛔ THE CAMERA LAW: never write the camera transform — configure the
-- native camera. DistanceOffset pulls the frame in close while working (DD2's own
-- collision/occlusion correction stays in charge, which is what keeps this safe inside
-- prop-crowded workshops); the optional orbit feeds the game's OWN right-stick input and
-- yields the instant the player touches the stick.
local function _st_cam_tick()
    local want = M.st_cam ~= false and M.stations ~= false
        and (ST.session ~= nil or ST.pending ~= nil or (TL and TL.act ~= nil))
    local cm = sdk.get_managed_singleton("app.CameraManager")
    if not cm then return end
    local now = os.clock()
    local dt = math.min(0.1, now - (tonumber(ST.cam_t) or now))
    ST.cam_t = now
    if want then
        if ST.cam_base == nil then
            local b = nil
            pcall(function() b = tonumber(cm:call("get_DistanceOffset")) end)
            ST.cam_base = b or 0.0
            _st_log(string.format("camera engaged (base offset %.2f, target %+.2f)",
                ST.cam_base, tonumber(M.st_cam_dist) or -1.2))
        end
        local target = (ST.cam_base or 0.0) + (tonumber(M.st_cam_dist) or -1.2)
        pcall(function()
            local cur = tonumber(cm:call("get_DistanceOffset")) or 0.0
            cm:call("set_DistanceOffset", cur + (target - cur) * math.min(1.0, dt * 3.0))
        end)
    elseif ST.cam_base ~= nil then
        local done = false
        pcall(function()
            local cur = tonumber(cm:call("get_DistanceOffset")) or 0.0
            local target = ST.cam_base or 0.0
            if math.abs(target - cur) < 0.02 then
                cm:call("set_DistanceOffset", target)
                done = true
            else
                cm:call("set_DistanceOffset", cur + (target - cur) * math.min(1.0, dt * 3.0))
            end
        end)
        if done then
            ST.cam_base = nil
            _st_log("camera restored")
        end
    end
end

-- The exit watch: while the game has the player inside one of OUR station interactions,
-- B/F (settled past the entry press) or BACKSPACE runs the safe release. Movement cannot
-- escape a native jack (the game owns the body), so the button ladder is the whole exit.
local function _st_frame()
    pcall(_st_cam_tick)   -- runs first: it must keep restoring even when stations turn off
    if M.stations == false then ST.session, ST.pending = nil, nil; return end
    local now = os.clock()

    -- Edges are read EVERY frame — including outside a session — so the entry press can
    -- never replay as an instant exit, and a held button never fires twice.
    local down = _exit_binding_down()
    local kill = false
    pcall(function() kill = reframework:is_key_down(0x08) == true end)
    local edge_btn  = down and not ST.prev
    local edge_kill = kill and not ST.kill_prev
    ST.prev, ST.kill_prev = down, kill

    -- Abort watchdog: confirm the manager actually reaped the flagged session, escalate
    -- to the hard release if the flag was ignored.
    local pend = ST.pending
    if pend then
        local age = now - (tonumber(pend.at) or 0)
        if age >= 0.3 then
            local open = nil
            pcall(function()
                local ch = _player()
                local mgr = sdk.get_managed_singleton("app.InteractManager")
                if ch and mgr then open = mgr:call("isInteracting(app.Character)", ch) end
            end)
            if open == false then
                ST.pending = nil
                local jacked = false
                pcall(function()
                    local ch = _player()
                    jacked = ch and ch:call("get_IsJacked") == true
                end)
                if jacked then
                    _st_release_hard(pend.reason .. " (jack survived the abort)", pend.rec)
                else
                    ST.status = string.format("released natively (%s) — session closed clean",
                        tostring(pend.reason))
                    _st_log(ST.status)
                end
            elseif age > 3.0 then
                -- ⛔ NO auto-escalation (2026-08-27, the woodcut backspace HANG): running the
                -- jack trio while the manager's abort is still in flight is a prime hang
                -- suspect. Report and stand still; the panel's manual button remains for a
                -- deliberate human choice.
                ST.pending = nil
                ST.status = "⚠ native abort IGNORED — do not retry; use the panel or reload the save"
                _st_log("abort ignored after " .. string.format("%.1f", age)
                    .. "s — NOT escalating (hang guard); manual button only")
            end
        end
        return
    end

    if now - (tonumber(ST.at) or 0) >= 0.25 then
        ST.at = now
        local a = _active_native()
        if _is_station_active(a) then
            local id = _addr(a.io) or tostring(a.key)
            if not ST.session or ST.session.id ~= id then
                ST.session = { id = id, rec = a.rec, key = a.key,
                               host = tostring((a.rec and a.rec.host) or a.key or "?"),
                               since = now }
                ST.status = string.format("WORKING: %s — press B/F (or BACKSPACE) to stop",
                    ST.session.host)
                _logf("station native session begun: %s", ST.session.host)
                -- the worker brings the tool: hand prop expected but nothing borrowed →
                -- conjure it. Never when a real borrow is live (she brought her own).
                local strow = a.key and STATIONS[a.key]
                local cid = strow and strow.conjure or nil
                if strow and strow.conjure_cfg then
                    cid = tonumber(M.anvil_id) or 0
                    if cid <= 0 then cid = nil end
                end
                if strow then strow = { conjure = cid, label = strow.label } end
                if strow and strow.conjure and not ST.conjured then
                    local heldid = 0
                    pcall(function()
                        local ch = _player()
                        local human = ch and ch:call("get_Human")
                        local holder = human and human:call("get_GimmickHolder")
                        local ctx = holder and holder:get_field("Context")
                        heldid = (ctx and tonumber(ctx:get_field("EquipItemID"))) or 0
                    end)
                    if heldid == 0 and _st_conjure(strow.conjure, true) then
                        ST.conjured = strow.conjure
                        ST.conj_at, ST.conj_probed = now, false
                    end
                end
            end
        else
            ST.session = nil
        end
    end

    -- conjured prop return: the moment neither the session nor its wind-down remains.
    -- (round-17 decode: draw=false is an engine no-op — the slot dies on its own when the
    -- re-stage below stops; this call is kept as documentation of intent.)
    if ST.conjured and not ST.session and not ST.pending then
        _st_conjure(ST.conjured, false, true)
        ST.conjured, ST.conj_at, ST.conj_probed, ST.conj_restage = nil, nil, nil, nil
    end

    -- ⭐ round-17 decode: our staging lands and some stations' authored tracks wipe the
    -- slot each frame — so re-stage on a 0.25s cadence. ⚠ BUT ONLY WHEN THE SLOT IS
    -- EMPTY (field 2026-08-27, the anvil: re-staging a HELD slot tears down and respawns
    -- the prop every tick — visible flashing). Check first, fight only when losing.
    if ST.conjured and ST.session
        and os.clock() - (tonumber(ST.conj_restage) or 0) > 0.25 then
        ST.conj_restage = os.clock()
        local held = false
        pcall(function()
            local ch = _player()
            local human = ch and ch:call("get_Human")
            local ctrl = human and human:call("get_EquipItemCtrl")
            local arr = ctrl and ctrl:get_field("Controllers")
            local n = arr and tonumber(arr:call("get_Length")) or 0
            for i = 0, n - 1 do
                local c
                pcall(function() c = arr:get_element(i) end)
                if c and tonumber(c:get_field("<ItemID>k__BackingField")) == ST.conjured then
                    held = true
                    break
                end
            end
        end)
        if not held then _st_conjure(ST.conjured, true, true) end
    end

    -- CONJPROBE: 1.5s after a conjure request, dump the six controller slots — did the
    -- request land in a slot, did the item spawn, or is the clip's authored equip-track
    -- overwriting it each frame? (Field: "requested" logs but no visible prop.)
    if ST.conjured and ST.session and ST.conj_at and not ST.conj_probed
        and os.clock() - ST.conj_at > 1.5 then
        ST.conj_probed = true
        pcall(function()
            local ch = _player()
            local human = ch and ch:call("get_Human")
            local ctrl = human and human:call("get_EquipItemCtrl")
            if not ctrl then _st_log("CONJPROBE: no EquipItemCtrl") return end
            local en = "?"
            pcall(function() en = tostring(ctrl:call("get_IsEnable")) end)
            local arr = ctrl:get_field("Controllers")
            local n = 0
            pcall(function() n = tonumber(arr:call("get_Length")) or 0 end)
            if n == 0 then pcall(function() n = tonumber(arr:get_size()) or 0 end) end
            local hits, readable = 0, 0
            for i = 0, n - 1 do
                local c = nil
                pcall(function() c = arr:get_element(i) end)
                if c then
                    readable = readable + 1
                    local act, item, joint, draw, created = "?", -1, "?", "?", "?"
                    pcall(function() act = tostring(c:call("get_IsActive")) end)
                    pcall(function() item = tonumber(c:get_field("<ItemID>k__BackingField")) or -1 end)
                    pcall(function() joint = tostring(c:get_field("ParentJoint")) end)
                    pcall(function() draw = tostring(c:get_field("IsDraw")) end)
                    pcall(function() created = tostring(c:get_field("IsItemCreated")) end)
                    -- Item = the actual spawned prop GameObject: nil means the async
                    -- creation never completed (missing catalog prefab?) even when the
                    -- request flag reads true.
                    local igo = "nil"
                    pcall(function()
                        local g = c:get_field("Item")
                        if g then igo = tostring(g:call("get_Name")) end
                    end)
                    if act == "true" or (item and item > 0) then
                        hits = hits + 1
                        _st_log(string.format(
                            "CONJPROBE slot %d: active=%s item=%d joint=%s draw=%s created=%s itemGO=%s",
                            i, act, item, joint, draw, created, igo))
                    end
                end
            end
            -- readable distinguishes "slots empty" from "probe cannot read slots at all"
            _st_log(string.format("CONJPROBE done: enable=%s slots=%d readable=%d active/holding=%d",
                en, n, readable, hits))
        end)
    end

    local sess = ST.session
    if not sess then
        -- BACKSPACE dead-man works even when classification fails: if the manager says the
        -- player is interacting in ANYTHING, flag its abort. (B stays station-only — chairs
        -- and doors use it natively.)
        if edge_kill then
            local open = false
            pcall(function()
                local ch = _player()
                local mgr = sdk.get_managed_singleton("app.InteractManager")
                open = ch and mgr and mgr:call("isInteracting(app.Character)", ch) == true
            end)
            if open then _st_release("backspace (unclassified interaction)") end
        end
        return
    end

    -- On-screen cue while working (Aurora: "have the UI say Stop on B"). The bar renders
    -- it when installed; a standalone native key-guide label is release polish.
    pcall(function()
        local IP = _G.IrisPrompt
        if not (IP and type(IP.set) == "function") then return end
        local pgo = _char_go(_player())
        local p = pgo and _pos(pgo)
        IP.set("interactables_station",
            sess.wind_down and "Finishing... (B = stop now)" or "Stop",
            5, 0.05, p, pgo)
    end)

    if edge_kill then return _st_release("backspace") end

    -- Wind-down: the first B press does not abort mid-rep — it waits for the current loop
    -- clip to reach its boundary, so the prop stays in hand to the end of the motion and
    -- the teardown lands on a natural pose. (The TRUE authored EndAction is only reachable
    -- through the fatal manager cancel path — research item, never a cold call.) A second
    -- B press aborts immediately; a stuck clip aborts after 6s regardless.
    if sess.wind_down then
        if edge_btn then return _st_release("button (right now)") end
        local at_boundary = false
        pcall(function()
            local motion = _st_motion()
            local layer = motion and motion:call("getLayer", 0)
            if not layer then at_boundary = true; return end
            local f  = tonumber(layer:call("get_Frame")) or 0
            local ef = tonumber(layer:call("get_EndFrame")) or 0
            local last = tonumber(sess.last_frame) or -1
            sess.last_frame = f
            -- near the clip end, or the loop just wrapped past it
            if ef > 1.0 and (f >= ef - 3.0 or (last >= 0 and f < last - 10.0)) then
                at_boundary = true
            end
        end)
        if at_boundary or now - (tonumber(sess.wind_at) or 0) > 6.0 then
            return _st_release("clip boundary")
        end
        return
    end

    if edge_btn and now - (tonumber(sess.since) or 0) > 1.2 then
        -- Beds skip the wind-down (field 2026-08-27: the sleep idle is a LONG loop, so
        -- waiting for its boundary reads as "Stop does nothing for ages"). A sleeper
        -- just gets up; there is no mid-rep pose to protect.
        if sess.rec and sess.rec.kind == "bed" then
            return _st_release("button (bed — immediate)")
        end
        sess.wind_down = true
        sess.wind_at = now
        sess.last_frame = -1
        ST.status = string.format("finishing the motion at %s — press B again to stop right now",
            tostring(sess.host))
        return
    end
end

-- (The cinematic-orbit UpdateHID injection was CUT 2026-08-27: the log proved the
-- set_AxisR writes ran and the engine discarded them, and via.hid.MouseDevice's axes are
-- getter-only, so no input-side lever exists for either device. The close-up
-- DistanceOffset camera is the surviving, field-confirmed half.)

local function _publish()
    _G.Interactables_dough_hybrid_lab = false
    -- ⛔⛔ REMOVED 2026-08-13: `M.native_discovery = false` used to run HERE, every frame,
    -- before _unlock_tick. The header's stated intent is "never saved, resets off on
    -- process/script load" -- which the load-time clear (:132) and the save clear (:121)
    -- already do on their own. Clearing it every FRAME meant the UI checkbox could never
    -- latch for even one tick, so the entire discovery branch was UNREACHABLE: the feature
    -- read as opt-in but was actually inert, and nobody could tell the difference from the
    -- panel. This was Aurora's "I thought all interactables were turned on".
    _G.DD2NativeSeats = { owner = "Interactables", version = 1,
                          prefab = M.donor or "gm80_257",
                          chores = M.native_chores == true,
                          beds = M.native_beds == true,
                          t = os.clock() }
    -- The stations engine owns the looping workstations while live; InteractButton's old
    -- single-station dough lab reads this and stands down so gm50_022 has ONE owner.
    _G.Interactables_stations_live = M.stations ~= false
end

re.on_frame(function()
    _publish()
    pcall(_tick)
    pcall(_unlock_tick)
    pcall(_native_session_tick)
    pcall(_st_frame)
    pcall(_tl_frame)
    pcall(_bed_probe_tick)
    pcall(_registry_tick)
    pcall(_mc_frame)
end)

re.on_script_reset(function()
    _G.Interactables_dough_hybrid_lab = false
    -- ⛔ FIRST: a tool drive left running through a reset would strand a disabled Human.Fsm.
    pcall(function() _tl_stop("script reset") end)
    pcall(function() _mc_stop_stir() end)
    pcall(function() if MC.open then _mc_close() end end)
    pcall(function()
        if ST.conjured then _st_conjure(ST.conjured, false); ST.conjured = nil end
    end)
    -- Engine N owns no player state at reset: the body is in a NATIVE interaction (or none),
    -- and _restore_unlocks below reverts the CharacterType points. The one thing to unwind
    -- is the camera distance offset, if a station session was framing.
    pcall(function()
        if ST.cam_base ~= nil then
            local cm = sdk.get_managed_singleton("app.CameraManager")
            if cm then cm:call("set_DistanceOffset", ST.cam_base) end
            ST.cam_base = nil
        end
    end)
    -- ⛔ DROP REFS, DO NOT DESTROY. This codebase has a documented destroy-on-reset CTD, and
    -- destroying is unnecessary anyway: a leftover donor is simply a working seat, and the
    -- de-dup adopts it on the next pass rather than duplicating it.
    pcall(function() _drop_all(false) end)
    -- Restoring scalar interaction data is safe and prevents a disabled/reloaded copy of the
    -- mod inheriting our live bitmask edits. The callback deliberately does not destroy objects.
    pcall(function() _restore_unlocks() end)
    pcall(_save_cfg)
end)

re.on_draw_ui(function()
    if not imgui.tree_node("Interactables") then return end
    local c

    -- ── the whole mod, four switches ───────────────────────────────────────────────────
    c, M.enabled = imgui.checkbox("Sit anywhere — chairs, stools and benches", M.enabled)
    if c then _save_cfg(); if not M.enabled then _drop_all(true) end end

    c, M.stations = imgui.checkbox("Work anywhere — knead, smith, sweep, weave and more",
        M.stations ~= false)
    if c then
        _save_cfg()
        if not M.stations then _restore_unlocks("station") end
    end
    imgui.text("      press B again (or BACKSPACE) to stop working")

    c, M.st_cam = imgui.checkbox("Close-up camera while working", M.st_cam ~= false)
    if c then _save_cfg() end

    c, M.native_beds = imgui.checkbox("Sleep in beds — really lie down (experimental)",
        M.native_beds)
    if c then
        if not M.native_beds then _restore_unlocks("bed") end
        _save_cfg()
    end
    if M.native_beds then
        imgui.text("      B (or BACKSPACE) gets you back up")
    end

    -- ── status + rescue, only when something is happening ──────────────────────────────
    if ST.session then
        imgui.text(tostring(ST.status or ""))
        if imgui.button("Release NOW") then _st_release("panel") end
    elseif ST.pending then
        imgui.text("stopping...")
        imgui.same_line()
        if imgui.button("force it") then
            local p = ST.pending; ST.pending = nil
            _st_release_hard("panel escalation", p and p.rec)
        end
    end
    if cat_n == 0 then
        imgui.text("⛔ catalog MISSING — data/Interactables/catalog.json did not load")
    end

    -- ── everything else lives here ─────────────────────────────────────────────────────
    if imgui.tree_node("Advanced") then
        imgui.text("Camera")
        c, M.st_cam_dist = imgui.slider_float("close-up amount (drag the other way if inverted)",
            M.st_cam_dist or -1.2, -3.0, 3.0)
        if c then _save_cfg() end

        imgui.text("Seats")
        c, M.range     = imgui.slider_float("seat range (m)", M.range or 12.0, 2.0, 30.0)
        c, M.y_window  = imgui.slider_float("vertical window (m)", M.y_window or 2.5, 0.5, 8.0)
        c, M.max_seats = imgui.slider_int("max seats at once", M.max_seats or 8, 1, 16)
        c, M.seat_y    = imgui.slider_float("seat height offset (m)", M.seat_y or 0.0, -0.8, 0.8)
        c, M.neuter_collision = imgui.checkbox(
            "disable hidden seat colliders (only if you get wedged on thin air)",
            M.neuter_collision)
        if imgui.button("Save settings") then _save_cfg() end
        imgui.same_line()
        if imgui.button("Remove every hidden seat now") then _drop_all(true) end

        imgui.text(string.format("Stations — %d point(s) unlocked · last: %s",
            _unlock_count("station"), tostring(ST.status or "idle")))
        if imgui.tree_node("Station list (untick to relock one)") then
            local keys = {}
            for k in pairs(STATIONS) do keys[#keys + 1] = k end
            table.sort(keys)
            for _, k in ipairs(keys) do
                local on = not (M.st_off or {})[k]
                c, on = imgui.checkbox(string.format("%s — %s", k, tostring(STATIONS[k].label)), on)
                if c then
                    M.st_off = M.st_off or {}
                    M.st_off[k] = (not on) and true or nil
                    if not on then
                        for addr, r in pairs(unlocks) do
                            if r.kind == "station" and r.prop_key == k then
                                pcall(function()
                                    r.point:set_field("CharacterType", r.old)
                                    if r.old_icon ~= nil then r.point:set_field("IconType", r.old_icon) end
                                end)
                                unlocks[addr] = nil
                            end
                        end
                    end
                    _save_cfg()
                end
            end
            imgui.tree_pop()
        end

        c, M.log = imgui.checkbox("write Interactables.log", M.log)
        if c then _save_cfg() end

        if imgui.tree_node("Research (dev only)") then
            imgui.text("Native CharacterType unlocks outside the station set. Session-only")
            imgui.text("switches are never saved. ⛔ NPC work loops entered through DISCOVERY")
            imgui.text("have NO safe native exit — BACKSPACE / FORCE UNJACK only.")
            if imgui.button("Probe native cook menu (safe: nothing is consumed)") then
                CK.req = true
            end
            imgui.text("  opens DD2's own 'Cook what?' list; pick anything or cancel —")
            imgui.text("  the choice is only logged. ⚠ don't ride/whistle while it's open.")
            imgui.text("TOWN cook menu: DISABLED — two crash-proven routes; the scene-load")
            imgui.text("  decode happens offline before this button ever comes back.")
            local ca
            ca, M.anvil_id = imgui.slider_int(
                "anvil workpiece id (0=off; 4=medusa head!)", tonumber(M.anvil_id) or 0, 0, 55)
            if ca then _save_cfg() end
            imgui.text("  conjured into the free hand at the smithy — change it, work the")
            imgui.text("  anvil, see what appears. Hunting a blade for the video.")
            c, M.native_chores = imgui.checkbox(
                "Safe villager props — loose tools and oxcart bells", M.native_chores)
            if c then
                if not M.native_chores then _restore_unlocks("chore") end
                _save_cfg()
            end
            c, M.native_discovery = imgui.checkbox(
                "SESSION ONLY: discover ALL Human-only world props", M.native_discovery)
            if c and not M.native_discovery then
                _restore_unlocks("chore")
                if not M.native_beds then _restore_unlocks("bed") end
            end
            c, M.native_lethal = imgui.checkbox(
                "SESSION ONLY: ALSO the proven-crash drum (gm10_030)", M.native_lethal)
            if c and not M.native_lethal then _restore_unlocks("chore") end
            imgui.text("Last native event: " .. tostring(native_last))
            imgui.text(string.format("%d chore + %d bed point(s) changed live · %d failed writes",
                _unlock_count("chore"), _unlock_count("bed"), stats.unlock_failed or 0))
            imgui.tree_pop()
        end
        imgui.tree_pop()
    end

    imgui.tree_pop()
end)
