-- ═════════════════════════════════════════════════════════════════════════════
-- IrisSpawner.lua — ONE in-house spawner for every IRIS creature.
--
-- Aurora (08-20): "can you check the spawn route for every creature we can
-- currently spawn in Iris and make sure they all use something inhouse... even
-- if we create our own IrisSpawner .lua that handles ALL spawning for current
-- and future spawns".
--
-- The audit that prompted it: EnemySpawner (Nick's) was a HARD prerequisite for
-- 7 of 8 IRIS spawn sites — griffin, drake, every stable companion, the house
-- cat, the hunt quarry, the ox-tame bait, the critter reference body and the
-- ghost/donor bodies. Worse, GriffinRideProbe captured it at LOAD time behind a
-- silent pcall, so if that mod was missing the summons died quietly for the
-- whole session (exactly how the wolf/puma outage happened).
--
-- ⭐ THE KEY INSIGHT (read out of Nick's spawner, never edited — the
-- other-mods law): it does NOT build prefab paths from strings. It asks the
-- GAME'S OWN ENEMY CATALOG for a ready-made PrefabController, keyed by
-- app.CharacterID. That is why it handles every species AND every _A_00
-- variant, while a string-built path is only proven for bare ids like
-- ch223000_00. So the catalog is our PRIMARY route.
--
-- ROUTES, in order, each demoting to the next on failure:
--   1. catalog     — GenerateManager._CatalogCtrl._EnemyCatalog (any code)
--   2. path        — string-built .pfb, BARE ids only (⛔ never guess a
--                    variant path: a wrong path into requestCreateInstance is
--                    the classic hard-crash lever)
--   3. thirdparty  — EnemySpawner's SpawnRequest, required AT JOB TIME
--
-- ⛔ LAWS honoured here:
--   • Nothing (singleton, method, require) is captured at LOAD time — a script
--     reset builds a fresh Lua state and clears package.loaded.
--   • Every sdk.create_instance object is add_ref'd AND held in the JOB TABLE,
--     never only in a closure: dropped refs are collected mid-flight and the
--     body simply never arrives.
--   • The engine-owned catalog PrefabController is READ ONLY — never set_Path
--     or mutate it. We only ever mutate objects we created.
--   • One op per frame. DD2 is CPU-bound.
-- ═════════════════════════════════════════════════════════════════════════════

local MOD = "IrisSpawner"
local S = { jobs = {}, enum = nil, enum_n = 0, fallback = nil, seq = 0,
            last = nil, dump = nil }

-- ⛔ do NOT define a local named `log` here: it shadows REFramework's global
-- logger and the body then calls itself. One logger, unambiguous name.
local function say(msg)
    pcall(function()
        _G.log.info("[" .. MOD .. "] " .. tostring(msg))
    end)
end

local REQUEST_SIG =
    "requestCreateInstance(app.PrefabController, app.GenerateInfo.GenerateInfoContainer, System.Int32, app.InstanceInfo, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>)"

-- ── app.CharacterID enum, cached; rebuilt after a reset (cache starts nil) ──
local function ensure_enum()
    if S.enum then return S.enum end
    local built, n = {}, 0
    pcall(function()
        local td = sdk.find_type_definition("app.CharacterID")
        if not td then return end
        for _, f in ipairs(td:get_fields() or {}) do
            pcall(function()
                local name = f:get_name()
                -- ⛔ value__ is the enum's storage slot, not a member
                if name and name ~= "value__" then
                    local v = f:get_data(nil)
                    if type(v) == "number" then built[name] = v; n = n + 1 end
                end
            end)
        end
    end)
    S.enum, S.enum_n = built, n
    return built
end

local function char_id(code)
    if not code then return nil end
    local e = ensure_enum()
    return e[tostring(code)]
end

-- ── the CATALOG route: a ready PrefabController for ANY CharacterID ────────
-- ⛔ resolved per call: the singleton is not available at load, and the
-- MergedCatalog can still be empty early in a boot.
local function resolve_catalog_ctrl(enum_v)
    if not enum_v then return nil end
    local ctrl = nil
    pcall(function()
        local gm = sdk.get_managed_singleton("app.GenerateManager")
        if not gm then return end
        local cat = gm._CatalogCtrl._EnemyCatalog
            :get_field("<MergedCatalog>k__BackingField")
        if not cat then return end
        local item = cat:get_Item(enum_v)
        if not item then return end
        ctrl = item:get_Item()          -- already an app.PrefabController
    end)
    return ctrl
end

-- ── the generate-info block (shared by every route) ────────────────────────
local function build_generate_info(enum_v, pos, rot, opts)
    local gi = nil
    local ok = pcall(function()
        gi = sdk.create_instance(
            "app.GenerateInfo.GenerateInfoContainer"):add_ref()
        gi._CommonInfo._InitialPosition = pos
        gi._CommonInfo._ContextPosition = pos
        gi._CommonInfo._ObjectID._SelectedCharacterID = enum_v
    end)
    if not (ok and gi) then return nil end
    -- ⭐ 08-20 (Aurora: "why does the spawner take so long? the enemy spawner
    -- one is instant"): the field writes above are not the whole story. Nick's
    -- init calls the CONTEXT METHODS, which do the real placement work -- and
    -- setContextAngle is the only place rotation was ever applied, which mine
    -- silently dropped.
    pcall(function() gi._CommonInfo:setContextPosition(pos) end)
    if rot then pcall(function() gi._CommonInfo:setContextAngle(rot) end) end
    -- ⚠ one pcall per nested backing-field write: these names are the likeliest
    -- mismatch and a throw must not take the rest of the setup with it
    pcall(function()
        gi._StatusInfo["<ScaleRate>k__BackingField"] =
            tonumber(opts and opts.scale) or 1.0
    end)
    pcall(function()
        gi._CharaInfo._IsThinkStop = (opts and opts.idle) == true
    end)
    pcall(function()
        gi["<HumanInfo>k__BackingField"]["<Job>k__BackingField"] = 1
        gi["<HumanInfo>k__BackingField"]["<HumanEnemyCombatParamId>k__BackingField"] = 1
    end)
    return gi
end

-- ⛔ BARE ids only. A variant code (ch299003_A_00) has no proven path form and
-- guessing one is the documented crash lever.
local function bare_code(code)
    return tostring(code or ""):match("^ch%d+_%d+$") ~= nil
end

-- Build a controller around an explicit .pfb path.
-- ⭐ get_Exist() is checked FIRST (borrowed from the house cat's own installer):
-- a path the game cannot serve is the documented hard-crash lever once it
-- reaches requestCreateInstance, so a path that does not exist must never
-- become a job.
local function build_path_ctrl(path)
    if not path or path == "" then return nil end
    local ctrl, made = nil, nil
    pcall(function()
        local prefab = sdk.create_instance("via.Prefab"):add_ref()
        prefab:set_Path(path)
        local exists = false
        pcall(function() exists = prefab:get_Exist() == true end)
        if not exists then
            pcall(function() prefab:release() end)
            return
        end
        local c = sdk.create_instance("app.PrefabController"):add_ref()
        c._Item = prefab
        ctrl, made = c, prefab
    end)
    return ctrl, made
end

-- the catalog's own path shape, confirmed by the in-game probe:
--   AppSystem/ch/<band5>/Prefab/<code>.pfb
local function code_path(code)
    if not bare_code(code) then return nil end
    return "AppSystem/ch/" .. tostring(code):sub(1, 5) .. "/Prefab/"
        .. tostring(code) .. ".pfb"
end

-- ═══ PUBLIC: spawn ═══════════════════════════════════════════════════════════
-- spawn(code, pos, rot, opts) -> handle {name, go, chara, stage, route}
--   opts = { idle = bool, scale = number, label = string }
-- go/chara populate over LATER frames (same contract every IRIS poller
-- already expects).
local function spawn(code, pos, rot, opts)
    opts = opts or {}
    if not (code and pos) then return nil, "need a code and a position" end
    local enum_v = char_id(code)
    if not enum_v then
        ensure_enum()
        return nil, string.format("'%s' is not in app.CharacterID (%d known)",
            tostring(code), S.enum_n or 0)
    end
    local method = nil
    pcall(function()
        method = sdk.find_type_definition("app.GenerateManager")
            :get_method(REQUEST_SIG)
    end)
    local gm = sdk.get_managed_singleton("app.GenerateManager")
    if not (gm and method) then return nil, "GenerateManager not ready" end

    local ctrl, prefab, route = nil, nil, nil
    -- ⭐ opts.prefab_path: spawn a stock body wearing a CUSTOM prefab (the
    -- house cat's W3 assets ride the rabbit chassis this way). An explicit
    -- path always wins -- the caller knows something the catalog does not.
    if opts.prefab_path then
        ctrl, prefab = build_path_ctrl(opts.prefab_path)
        if ctrl then route = "custom" end
        if not ctrl then
            return nil, "custom prefab not found: " .. tostring(opts.prefab_path)
        end
    end
    if not ctrl then
        ctrl = resolve_catalog_ctrl(enum_v)
        if ctrl then route = "catalog" end
    end
    if not ctrl then
        ctrl, prefab = build_path_ctrl(code_path(code))
        if ctrl then route = "path" end
    end
    if not ctrl then
        return nil, "no prefab controller (catalog miss, "
            .. (bare_code(code) and "path build failed" or "variant code: no path route")
            .. ")"
    end

    -- ⭐⭐ THE INSTANT-SPAWN LEVER. set_Standby(true) KICKS THE PREFAB LOAD;
    -- without it we just spin on get_Ready() until something else happens to
    -- load the asset -- which is exactly why ours felt slow and Nick's felt
    -- instant. He calls this on the very same catalog-owned controller, so it
    -- is the sanctioned call, not a mutation of engine data.
    pcall(function() ctrl:get_Item():set_Standby(true) end)
    local gi = build_generate_info(enum_v, pos, rot, opts)
    if not gi then return nil, "generate info failed to build" end
    local ii = nil
    pcall(function() ii = sdk.create_instance("app.InstanceInfo"):add_ref() end)
    if not ii then return nil, "instance info failed to build" end

    S.seq = S.seq + 1
    local handle = { name = tostring(opts.label or code), stage = "wait",
                     route = route, code = tostring(code) }
    -- ⛔ THE JOB TABLE OWNS THE REFS. Nick's spawner survives on closure
    -- upvalues; drop them here and InstanceInfo is collected mid-flight and
    -- <Chara> stays nil forever.
    S.jobs[#S.jobs + 1] = {
        id = S.seq, handle = handle, ctrl = ctrl, prefab = prefab, gi = gi,
        ii = ii, gm = gm, method = method, code = tostring(code),
        pos = pos, rot = rot, opts = opts, route = route,
        stage = "wait", deadline = os.clock() + 6.0, polls = 0,
        tried = { [route] = true }, t0 = os.clock(),
    }
    return handle
end

-- ── demote to the next route rather than failing outright: early in a boot the
-- catalog can legitimately be empty for a perfectly valid id ────────────────
local function demote(job, why)
    job.err = why
    if job.route ~= "path" and not job.tried.path and bare_code(job.code) then
        local ctrl, prefab = build_path_ctrl(code_path(job.code))
        if ctrl then
            pcall(function() ctrl:get_Item():set_Standby(true) end)
            job.ctrl, job.prefab, job.route = ctrl, prefab, "path"
            job.tried.path = true
            job.stage, job.deadline, job.polls = "wait", os.clock() + 6.0, 0
            job.handle.route = "path"
            say(job.code .. ": catalog failed (" .. tostring(why)
                .. ") -> path route")
            return true
        end
    end
    if not job.tried.thirdparty then
        job.tried.thirdparty = true
        local SR = nil
        -- ⛔ required AT JOB TIME, never at load: the load-time capture is the
        -- exact bug that stranded the wolf/puma for a whole session
        pcall(function() SR = require("EnemySpawner/spawnRequest") end)
        if SR then
            local ok = pcall(function()
                local sp = SR:new()
                sp:updateConfig({
                    spawnIdle = (job.opts.idle == true),
                    instLimit = 0,
                    spawnMultiple = { enable = false, qty = 1 },
                    ovrScale = {
                        enable = (tonumber(job.opts.scale) or 1.0) ~= 1.0,
                        scale = tonumber(job.opts.scale) or 1.0,
                        normalizeSpeed = false,
                    },
                })
                sp:requestAddInstances(job.code, job.pos, job.rot, nil, 1)
                job.fallback_sp = sp
            end)
            if ok then
                job.route, job.stage = "thirdparty", "fallback"
                job.handle.route = "thirdparty"
                job.deadline = os.clock() + 10.0
                say(job.code .. ": -> EnemySpawner fallback (" .. tostring(why) .. ")")
                return true
            end
        end
    end
    job.stage = "failed"
    job.handle.stage = "failed"
    job.handle.err = tostring(why)
    say("SPAWN FAILED " .. job.code .. ": " .. tostring(why))
    return false
end

-- ═══ the pump: one op per frame ══════════════════════════════════════════════
local function pump()
    local q = S.jobs
    if not q or #q == 0 then return end
    for i = #q, 1, -1 do
        local job = q[i]
        local drop = false
        if job.stage == "wait" then
            local ready = false
            -- the catalog's controller owns a prefab that may already be live
            pcall(function()
                local item = job.ctrl:get_Item()
                ready = (item == nil) or (item:get_Ready() == true)
            end)
            if ready then
                local fired = pcall(function()
                    job.method:call(job.gm, job.ctrl, job.gi, 0, job.ii, nil, nil)
                end)
                if fired then
                    job.stage, job.polls = "poll", 0
                    job.handle.stage = "poll"
                else
                    demote(job, "requestCreateInstance threw")
                end
            elseif os.clock() > job.deadline then
                demote(job, "prefab never became ready")
            end
        elseif job.stage == "poll" then
            job.polls = job.polls + 1
            pcall(function()
                job.handle.go = job.ii["<Instance>k__BackingField"]
                job.handle.chara = job.ii["<Chara>k__BackingField"]
            end)
            if job.handle.go and job.handle.chara then
                job.stage, job.handle.stage = "done", "done"
                S.last = string.format("%s route=%s done in %.1fs",
                    job.code, tostring(job.route), os.clock() - job.t0)
                say(S.last)
                drop = true
            elseif job.polls > 900 then
                demote(job, "body never arrived")
            end
        elseif job.stage == "fallback" then
            -- drive the third-party spawner from EXACTLY ONE place (here)
            pcall(function()
                local sp = job.fallback_sp
                if not sp then return end
                sp:updateInstanceCounts()
                sp:requestSpawnOutstanding()
                if sp:hasAnyOutstandingPostProc() then sp:processPostProc() end
                local inst = sp.instances and sp.instances[1]
                local go = inst and (inst.gameObject or inst.go) or nil
                if go then
                    job.handle.go = go
                    job.handle.chara = inst.chara or inst.character
                end
            end)
            if job.handle.go then
                job.stage, job.handle.stage = "done", "done"
                S.last = job.code .. " route=thirdparty done"
                say(S.last)
                drop = true
            elseif os.clock() > job.deadline then
                job.stage, job.handle.stage = "failed", "failed"
                job.handle.err = "fallback produced no body"
                say("SPAWN FAILED " .. job.code .. ": fallback produced no body")
                drop = true
            end
        elseif job.stage == "failed" then
            drop = true
        end
        -- ⛔ refs are only released once the job leaves the queue
        if drop then table.remove(q, i) end
    end
end

-- ═══ PUBLIC: destroy ════════════════════════════════════════════════════════
-- ⛔ Only ever destroys a body IrisSpawner itself produced, and only through
-- the sanctioned call. Bodies other systems track are NOT ours to remove.
local function destroy(handle)
    if not handle then return false end
    for i = #S.jobs, 1, -1 do
        if S.jobs[i].handle == handle then table.remove(S.jobs, i) end
    end
    local go = handle.go
    handle.go, handle.chara, handle.stage = nil, nil, "destroyed"
    if not go then return false end
    local ok = pcall(function() go:destroy(go) end)
    return ok
end

-- ═══ PUBLIC: the pre-migration VERIFIER ═════════════════════════════════════
-- The planner's own open question: is the enemy catalog really able to serve
-- rabbits/deer/oxen/cats, or only "enemies"? ⇒ answer it with data BEFORE any
-- call site is migrated. Read-only: resolves, never spawns.
local PROBE_CODES = {
    "ch253000_00",    -- griffin
    "ch257000_00",    -- drake
    "ch223000_00",    -- wolf (already proven in-house via the path route)
    "ch299003_A_00",  -- critter reference ox
    "ch299010_A_00",  -- hunt quarry deer
    "ch299210_A_00",  -- ox-tame live bait
    "ch299200_A_00",  -- house cat chassis (rabbit)
    "ch299011_A_00",  -- horse/doe chassis
}
local function probe()
    ensure_enum()
    local rows = {}
    for _, code in ipairs(PROBE_CODES) do
        local id = char_id(code)
        local ctrl = id and resolve_catalog_ctrl(id) or nil
        local path = "-"
        if ctrl then
            pcall(function() path = tostring(ctrl:get_Item():get_Path()) end)
        end
        rows[#rows + 1] = string.format("%s | id=%s | catalog=%s | %s",
            code, tostring(id), ctrl and "YES" or "no", path)
    end
    S.dump = rows
    say("=== catalog probe (" .. tostring(S.enum_n) .. " CharacterID entries) ===")
    for _, r in ipairs(rows) do say("  " .. r) end
    return rows
end

-- ═══ publish + pump registration ════════════════════════════════════════════
_G.IrisSpawner = {
    spawn = spawn,
    destroy = destroy,
    probe = probe,
    char_id = char_id,
    -- the whole byName table, for callers that need to search the enum
    -- (the stable's band-healing walks it to turn "ch299200" into
    -- "ch299200_A_00")
    names = function() return ensure_enum() end,
    stats = function()
        return { jobs = #S.jobs, enum = S.enum_n, last = S.last }
    end,
}

re.on_application_entry("UpdateBehavior", function()
    pcall(pump)
end)

re.on_draw_ui(function()
    if not imgui.tree_node("IRIS Spawner (in-house creature spawning)") then return end
    ensure_enum()
    imgui.text(string.format("app.CharacterID entries: %d | jobs in flight: %d",
        S.enum_n or 0, #S.jobs))
    imgui.text("last: " .. tostring(S.last or "-"))
    imgui.text_colored(
        "Routes: catalog (any code) -> path (bare ids only) -> EnemySpawner fallback",
        0xFF9C9C9C)
    if imgui.button("PROBE: can the catalog serve every IRIS creature?") then
        probe()
    end
    if S.dump then
        for _, r in ipairs(S.dump) do imgui.text("  " .. r) end
    end
    imgui.tree_pop()
end)

say("loaded (nothing captured at load time; routes resolve on demand)")
