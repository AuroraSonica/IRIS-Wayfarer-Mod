-- IrisBossSpawnObserver.lua
-- TEMPORARY DIAGNOSTIC -- delete when the boss-spawn question is answered.
--
-- WHY: big bosses (griffin/ogre/drake/cyclops) sometimes materialise on top of the player
-- while walking, twice in a row on the last occurrence. This answers ONE question with
-- evidence: did a Lua mod ask for that spawn, or did the game's own native code?
--
-- HOW: pre-hook BOTH app.GenerateManager.requestCreateInstance overloads, and on a BOSS
-- spawn only, capture debug.traceback(). All REFramework autorun scripts share one
-- lua_State, so when a Lua mod calls requestCreateInstance its frame is STILL on the Lua
-- stack when our hook runs -- the traceback names the calling file and line. A spawn from
-- native/vanilla code has no foreign .lua frame at all. That is the whole attribution lever.
--
-- ⛔ READ-ONLY. Never returns SKIP_ORIGINAL, never writes an engine field. A diagnostic
--    that changes spawns destroys its own evidence.
--
-- LAWS OBEYED HERE:
--  * REFramework has NO unhook -- a script reset ORPHANS the old hook with its captured
--    locals live. So ALL mutable state lives in _G.IrisBSO, which every generation shares,
--    and sdk.hook is guarded so only the FIRST generation ever installs.
--  * Lua-wrapper use-after-free is a hard CTD here: nothing taken from hook args is ever
--    retained past the hook body. Plain numbers/strings are extracted inside the pcall.
--  * Hot path: this fires on EVERY monster spawn all game long. Non-boss spawns cost one
--    table lookup and return -- no traceback, no allocation, no position reads.
--  * on_frame does draw.text ONLY (proven safe: Daily_Quests / Brinebound / AffinityBar).
--    It never walks the scene from there -- that is the documented farmland-crash shape.

local S = _G.IrisBSO
if type(S) ~= "table" then
    S = {
        hooked   = false,   -- set once, by the first generation that installs the hooks
        ring     = {},      -- last N boss-spawn records (plain values only)
        n        = 0,       -- total boss spawns seen this session
        draw     = true,    -- on-screen readout
        verbose  = false,   -- also log NON-boss monster spawns (noisy; off by default)
        enum     = nil,     -- charID value -> "chAAABBB"
        armed_at = os.clock(),
    }
    _G.IrisBSO = S
end

local RING_MAX   = 30      -- records kept
local DRAW_MAX   = 6       -- lines drawn on screen
local DRAW_SECS  = 12.0    -- how long a line stays up
local SELF_FILE  = "IrisBossSpawnObserver"

---------------------------------------------------------------------------
-- BOSS ROSTER
---------------------------------------------------------------------------
-- Sourced from RiftSpeak/spawn_rate.lua's SPECIES table (its `big = true` rows) -- an
-- in-repo, already-live roster, NOT guessed prefixes. Whole families are matched by their
-- 3-digit prefix so armoured/veteran/elite variants (ch250000_12, ch252000_02, ...) are
-- caught too; the four boss-tier undead that live inside otherwise-small families are
-- listed exactly.
local BOSS_FAMILY = {
    ["250"] = "Cyclops",
    ["251"] = "Ogre",
    ["252"] = "Golem",
    ["253"] = "Griffin",
    ["254"] = "Chimera",
    ["255"] = "Medusa",
    ["256"] = "Minotaur",
    ["257"] = "Drake",
    ["258"] = "Wyvern",
    ["259"] = "Talos",
    ["260"] = "Garm/Warg",
}
local BOSS_EXACT = {
    ch226003 = "Skeleton Lord",
    ch227000 = "Lich",
    ch227001 = "Wight",
    ch229000 = "Dullahan",
}

-- code -> display name, or nil if this is not a boss
local function boss_name(code)
    if not code then return nil end
    local exact = BOSS_EXACT[code]
    if exact then return exact end
    return BOSS_FAMILY[code:sub(3, 5)]
end

---------------------------------------------------------------------------
-- CharacterID enum: raw value -> "chAAABBB"
---------------------------------------------------------------------------
-- Rebuilt on every load (cheap, once) so a hot-reload picks up a corrected table even
-- though the live hook closure belongs to an older generation -- it reads S.enum, not a local.
local function build_enum()
    local idx, n = {}, 0
    pcall(function()
        local td = sdk.find_type_definition("app.CharacterID")
        if not td then return end
        for _, f in ipairs(td:get_fields()) do
            if f:is_static() then
                local v = f:get_data()          -- proven enum read: NO argument
                local nm = f:get_name()
                if v ~= nil and nm then
                    local a, b = nm:match("[Cc]h(%d%d%d)_?(%d%d%d)")
                    if a and idx[v] == nil then
                        idx[v] = "ch" .. a .. b
                        n = n + 1
                    end
                end
            end
        end
    end)
    S.enum = idx
    return n
end

local enum_count = build_enum()

---------------------------------------------------------------------------
-- ATTRIBUTION
---------------------------------------------------------------------------
-- Scan the Lua traceback for the first frame belonging to a .lua file that is NOT this
-- observer. Found -> a Lua mod is on the stack and therefore requested this spawn.
-- Not found -> no foreign Lua frame, so the call came from native/vanilla code.
-- (Per the plan's own note: absence of a FOREIGN frame is the test, not an empty trace --
-- our own hook frames are always present.)
local function attribute(tb)
    if type(tb) ~= "string" then return "NATIVE", nil end
    for line in tb:gmatch("[^\r\n]+") do
        local file, ln = line:match("([%w_%-%.%\\/ ]+%.lua):(%d+)")
        if file and not file:find(SELF_FILE, 1, true) then
            local short = file:match("([^\\/]+[\\/][^\\/]+)$") or file:match("([^\\/]+)$") or file
            return "SCRIPT", short .. ":" .. ln
        end
    end
    return "NATIVE", nil
end

---------------------------------------------------------------------------
-- PLAYER POSITION (universal space -- same space as _ContextPosition)
---------------------------------------------------------------------------
-- ⛔ get_LastGroundPosition, NOT Transform:get_Position. The container's _ContextPosition
--    is universal space; the transform is render space. Different origins -- subtracting
--    across them yields garbage.
local function player_upos()
    local x, y, z
    pcall(function()
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local pl = cm and cm:call("get_ManualPlayer")
        local p  = pl and pl:call("get_LastGroundPosition")
        if p then x, y, z = p.x, p.y, p.z end
    end)
    return x, y, z
end

---------------------------------------------------------------------------
-- THE HANDLER
---------------------------------------------------------------------------
-- container_ptr: the GenerateInfoContainer arg (index differs per overload -- see hooks).
-- source: which door it came through, for the log line.
local function handle_spawn(container_ptr, source)
    -- 1. char id, as a PLAIN NUMBER, wrapper dropped inside the pcall (UAF law)
    local cid
    pcall(function()
        local container = sdk.to_managed_object(container_ptr)
        local cinfo     = container and container:get_field("_CommonInfo")
        local objid     = cinfo and cinfo:get_field("_ObjectID")
        cid             = objid and objid:get_field("_SelectedCharacterID")
    end)
    if cid == nil then return end

    local enum = S.enum
    local code = enum and enum[cid] or nil
    local name = boss_name(code)

    -- 2. HOT PATH BAIL. Everything below this line only ever runs for a boss.
    if not name then
        if S.verbose and code then
            log.info(string.format("[IrisBSO] (non-boss) %s via %s", code, source))
        end
        return
    end

    -- 3. attribution -- the point of the whole script. Captured ONCE and reused below;
    --    a traceback is the most expensive thing here, so it never happens twice.
    local tb = debug.traceback("", 2)
    local verdict, where = attribute(tb)

    -- 4. distance. _ContextPosition is the requested spawn point in universal space
    --    (verified: EnemySpawner.lua:685 reads this exact field back the same way).
    local sx, sy, sz
    pcall(function()
        local container = sdk.to_managed_object(container_ptr)
        local cinfo     = container and container:get_field("_CommonInfo")
        local cp        = cinfo and cinfo:get_field("_ContextPosition")
        if cp then sx, sy, sz = cp.x, cp.y, cp.z end
    end)

    local dist
    local px, py, pz = player_upos()
    if sx and px then
        local dx, dy, dz = sx - px, sy - py, sz - pz
        dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    end

    -- 5. record (plain values only -- no engine wrappers retained)
    S.n = S.n + 1
    local rec = {
        t       = os.clock(),
        species = name,
        code    = code or "?",
        dist    = dist,
        verdict = verdict,
        where   = where,
        source  = source,
        trace   = verdict == "SCRIPT" and tb or nil,
    }
    S.ring[#S.ring + 1] = rec
    while #S.ring > RING_MAX do table.remove(S.ring, 1) end

    local dtxt = dist and string.format("%.1fm", dist) or "?m"
    log.info(string.format("[IrisBSO] #%d BOSS %s (%s) at %s -- %s%s  [door:%s]",
        S.n, name, rec.code, dtxt, verdict,
        where and (" " .. where) or "", source))

    -- full stack for script-attributed spawns: this is the actual proof, keep all of it
    if verdict == "SCRIPT" and rec.trace then
        for line in rec.trace:gmatch("[^\r\n]+") do
            log.info("[IrisBSO]    " .. line)
        end
    end

    -- 6. persist. Boss spawns are rare, so a dump per event is cheap -- never per frame.
    pcall(function()
        local out = {}
        for i, r in ipairs(S.ring) do
            out[i] = { species = r.species, code = r.code,
                       dist = r.dist and string.format("%.1f", r.dist) or "unknown",
                       verdict = r.verdict, where = r.where, door = r.source,
                       trace = r.trace }
        end
        json.dump_file("IrisBossSpawnObserver.json", { total = S.n, events = out })
    end)
end

---------------------------------------------------------------------------
-- HOOKS -- installed ONCE, ever (the no-unhook law)
---------------------------------------------------------------------------
-- Two overloads exist and BOTH must be watched:
--   A) WITH category  -- vanilla world spawns. spawn_rate.lua hooks this one.
--   B) NO category    -- what encounters.lua (the prime suspect), guild_contracts.lua and
--                        EnemySpawner all use. Watching only A would clear the suspect falsely.
-- ⚠ The container sits at a DIFFERENT index per overload: args[5] on A, args[4] on B.
--   Swap them and every read silently nils out and the observer reports nothing.
if not S.hooked then
    local MONSTER = 3   -- app.GeneratorCategory.Monster

    local ok_a = pcall(function()
        local td = sdk.find_type_definition("app.GenerateManager")
        local m = td and td:get_method(
            "requestCreateInstance(app.GeneratorCategory, app.PrefabController, "
            .. "app.GenerateInfo.GenerateInfoContainer, System.Int32, "
            .. "System.Action`2<app.PrefabInstantiateResults,app.DummyArg>, "
            .. "System.Action`2<app.PrefabInstantiateResults,app.DummyArg>)")
        if not m then error("overload A not found", 0) end
        sdk.hook(m,
            function(args)
                -- cheapest possible filter first: category, then the id lookup
                local ok, cat = pcall(sdk.to_int64, args[3])
                if not ok or cat ~= MONSTER then return end
                pcall(handle_spawn, args[5], "cat")
                -- ⛔ no return value: never SKIP_ORIGINAL
            end,
            function(retval) return retval end)
    end)

    local ok_b = pcall(function()
        local td = sdk.find_type_definition("app.GenerateManager")
        local m = td and td:get_method(
            "requestCreateInstance(app.PrefabController, "
            .. "app.GenerateInfo.GenerateInfoContainer, System.Int32, app.InstanceInfo, "
            .. "System.Action`2<app.PrefabInstantiateResults,app.DummyArg>, "
            .. "System.Action`2<app.PrefabInstantiateResults,app.DummyArg>)")
        if not m then error("overload B not found", 0) end
        sdk.hook(m,
            function(args)
                -- no category argument here, so the boss-id lookup IS the filter
                pcall(handle_spawn, args[4], "nocat")
            end,
            function(retval) return retval end)
    end)

    S.hooked = ok_a and ok_b
    log.info(string.format(
        "[IrisBSO] armed -- enum:%d ids, hook(cat):%s hook(nocat):%s",
        enum_count, tostring(ok_a), tostring(ok_b)))
    if not (ok_a and ok_b) then
        log.info("[IrisBSO] ⛔ a hook FAILED to install -- attribution will be incomplete")
    end
else
    log.info(string.format("[IrisBSO] reloaded -- hooks already live, %d ids, %d seen so far",
        enum_count, S.n))
end

---------------------------------------------------------------------------
-- ON-SCREEN READOUT (draw.text only -- never touch the scene from on_frame)
---------------------------------------------------------------------------
re.on_frame(function()
    if not S.draw then return end
    local now = os.clock()
    local x, y = 20, 140

    draw.text(string.format("IrisBSO armed  (%d boss spawns seen)", S.n), x, y, 0xFF80D0FF)
    y = y + 20

    local shown = 0
    for i = #S.ring, 1, -1 do
        local r = S.ring[i]
        if now - r.t > DRAW_SECS or shown >= DRAW_MAX then break end
        local colour = r.verdict == "SCRIPT" and 0xFF4040FF or 0xFF40FF40  -- red=script, green=native
        draw.text(string.format("%s  %s  %s%s",
            r.species,
            r.dist and string.format("%.0fm", r.dist) or "?m",
            r.verdict,
            r.where and (" " .. r.where) or ""), x, y, colour)
        y = y + 18
        shown = shown + 1
    end
end)

---------------------------------------------------------------------------
-- PANEL
---------------------------------------------------------------------------
re.on_draw_ui(function()
    if not imgui.tree_node("Iris Boss Spawn Observer") then return end

    imgui.text(string.format("Boss spawns this session: %d", S.n))
    imgui.text(string.format("Hooks live: %s   CharacterID entries: %d",
        tostring(S.hooked), enum_count))
    imgui.text("RED = a Lua script asked for it.  GREEN = the game did it.")

    local c, v = imgui.checkbox("On-screen readout", S.draw)
    if c then S.draw = v end
    c, v = imgui.checkbox("Also log NON-boss monster spawns (noisy)", S.verbose)
    if c then S.verbose = v end

    if imgui.button("Clear list") then S.ring = {}; S.n = 0 end

    imgui.text("")
    for i = #S.ring, 1, -1 do
        local r = S.ring[i]
        imgui.text(string.format("%s (%s)  %s  %s%s  [%s]",
            r.species, r.code,
            r.dist and string.format("%.1fm", r.dist) or "?m",
            r.verdict, r.where and (" " .. r.where) or "", r.source))
    end

    imgui.tree_pop()
end)
