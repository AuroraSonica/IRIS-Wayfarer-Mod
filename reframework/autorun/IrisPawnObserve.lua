-- ═════════════════════════════════════════════════════════════════════════════════════
-- IrisPawnObserve.lua — WATCH what the game does to a pawn, and crib it.
--
-- Aurora 2026-08-09: "is it worth observing what the pawn actually does when you enter places
-- like the tavern, the palace (which they're not allowed in) and other places like that? maybe
-- there's something there we can crib"
--
-- ⭐ YES, AND IT IS THE RIGHT MOVE. Three attempts at driving a pawn to a point have each found
--   a real defect and still ended with her nose against a wall. But the GAME already does what
--   we want, visibly and reliably: outside the palace a pawn refuses to follow you in, holds a
--   spot, and loiters there. Whatever issues that instruction OUTRANKS the follow AI — which is
--   precisely the authority we have been missing. Rather than guess at which system it is, watch
--   the pawn while the game does it and read the diff.
--
-- ⛔ READ-ONLY. This module calls NOTHING that mutates. It exists to answer a question, and a
--   probe that changes behaviour cannot be trusted to report it.
--
-- ⛔ IT DOES NOT GUESS METHOD NAMES. Every previous dead end today came from writing an API from
--   memory and letting pcall swallow it. So this DUMPS the real method list off the live type
--   first (the motion-tape trick from IrisHomeLife.lua:1681), then only polls getters that
--   actually exist, are zero-argument, and return something printable.
--
-- HOW TO USE:
--   1. tick "watch" in the panel, stand somewhere normal, let it settle
--   2. walk to the palace door / into the tavern / anywhere the pawn behaves differently
--   3. read IrisPawnObserve.log — it prints ONLY CHANGES, so the moment the game takes over is
--      a short readable burst rather than a wall of text
-- ═════════════════════════════════════════════════════════════════════════════════════

local M = { on = false, every = 0.4, dumped = false }
local LOG = "IrisPawnObserve.log"

local function _log(s)
    pcall(function()
        local f = io.open(LOG, "a")
        if f then f:write(os.date("[%H:%M:%S] ") .. tostring(s) .. "\n"); f:close() end
    end)
end

local S = { at = 0, last = {}, note = "idle", counts = {}, total = 0 }

local function _sc(o, m) local r; pcall(function() r = o:call(m) end); return r end
local function _sf(o, f) local r; pcall(function() r = o[f] end); return r end

local function _pawn()
    local pm = sdk.get_managed_singleton("app.PawnManager")
    if not pm then return nil end
    local v = _sc(pm, "get_MainPawn") or _sc(pm, "getMainPawn")
    if not v then return nil end
    return _sc(v, "get_CachedCharacter") or _sf(v, "<CachedCharacter>k__BackingField")
        or _sc(v, "get_Character") or v
end

-- the navigation controller, by the three routes RiftSpeakCarrySpike.lua:184-191 uses
local function _nav(ch)
    local c
    pcall(function() c = ch:get_field("<NavigationController>k__BackingField") end)
    if not c then pcall(function() c = ch:call("get_NavigationController") end) end
    if not c then
        pcall(function()
            c = ch:call("get_GameObject")
                  :call("getComponent(System.Type)", sdk.typeof("app.NPCNavigationController"))
        end)
    end
    return c
end

-- ── the self-discovering reader ──────────────────────────────────────────────────────
-- ⭐ NAME PATTERNS, NOT NAME GUESSES. We ask the type what it has and keep the getters whose
--   names look like they describe STATE. Anything that needs arguments is skipped outright —
--   calling an unknown method with the wrong signature is how you crash a game, not probe it.
local WANT = {
    "destination", "route", "path", "node", "goal", "target", "block", "stop", "arriv",
    "state", "mode", "situation", "task", "area", "region", "enter", "forbid", "restrict",
    "enable", "active", "wait", "follow", "escort", "schedule", "move", "walk", "speed",
}

-- ⛔ THE NAME FILTER WAS TOO NARROW AND THAT IS WHY IT SAW NOTHING (Aurora 08-09: "it said 5
--   changes ... ran to the palace where she no longer follows me but it still says 5 changes").
--   Five fields is not a pawn's state, it is a rounding error — the whole palace transition
--   happened and we were not reading whatever moved. The keyword list assumed I could predict
--   what the field would be CALLED, which is the same guessing that has failed all day.
--   ⇒ WIDE by default: every zero-argument getter that returns something printable. If it turns
--     out to be noisy we can narrow it AFTERWARDS, from evidence, which is the right order.
local function _interesting(n)
    local l = n:lower()
    if not (l:find("^get_") or l:find("^is") or l:find("^has")) then return false end
    if M.wide ~= false then return true end
    for _, w in ipairs(WANT) do if l:find(w, 1, true) then return true end end
    return false
end

local function _readable(v)
    local t = type(v)
    if t == "number" or t == "boolean" or t == "string" then return tostring(v) end
    if t == "userdata" then
        -- a via.Position / vec3 prints usefully; anything else is just noise
        local x = nil; pcall(function() x = v.x end)
        if type(x) == "number" then
            local y, z = 0, 0
            pcall(function() y, z = v.y, v.z end)
            return string.format("(%.1f,%.1f,%.1f)", x, y or 0, z or 0)
        end
        return nil
    end
    return nil
end

local function _dump_api(obj, label)
    if not obj then _log("API " .. label .. ": <nil>"); return end
    pcall(function()
        local td = obj:get_type_definition()
        _log("API " .. label .. " = " .. tostring(td:get_full_name()))
        local names = {}
        for _, m in ipairs(td:get_methods()) do
            local n = tostring(m:get_name())
            local argc = 0
            pcall(function() argc = #m:get_param_types() end)
            names[#names + 1] = n .. "(" .. tostring(argc) .. ")"
        end
        table.sort(names)
        _log("   " .. table.concat(names, ", "))
    end)
end

-- poll every zero-arg interesting getter and report only what CHANGED
local function _scan(obj, label, out)
    if not obj then S.counts[label] = "MISSING"; return end
    local kept = 0
    pcall(function()
        local td = obj:get_type_definition()
        for _, m in ipairs(td:get_methods()) do
            local nm = tostring(m:get_name())
            local argc = 1
            pcall(function() argc = #m:get_param_types() end)
            if argc == 0 and _interesting(nm) then
                local v
                pcall(function() v = m:call(obj) end)
                local s = _readable(v)
                if s then out[label .. "." .. nm] = s; kept = kept + 1 end
            end
        end
    end)
    -- ⭐ HOW MANY FIELDS ARE WE ACTUALLY WATCHING? Without this the panel could say "5 changes"
    --   forever and there was no way to tell "nothing changed" from "we are reading nothing".
    S.counts[label] = kept
end

local function _tick()
    if not M.on then return end
    local now = os.clock()
    if now - S.at < (M.every or 0.4) then return end
    S.at = now

    local ch = _pawn(); if not ch then S.note = "no pawn"; return end
    local nav = _nav(ch)
    local am  = _sc(ch, "get_ActionManager")
    -- ⭐⭐ THE AGENT IS A COMPONENT ON HER BODY, not something getAgent() will hand over.
    --   The component list proved it: app.AISituationAgentNPC is attached to the pawn. My
    --   earlier `AISituationManager.getAgent(app.CharacterID)` returned nil every time and the
    --   whole task system went unobserved because of it — which is why "situation" was empty.
    --   This is the system Aurora has chosen to pursue (route B), so it needs real eyes on it.
    local agent
    for _, tn in ipairs({ "app.AISituationAgentNPC", "app.AISituationAgent" }) do
        if not agent then
            pcall(function()
                agent = ch:call("get_GameObject")
                          :call("getComponent(System.Type)", sdk.typeof(tn))
            end)
        end
    end
    if not agent then
        pcall(function()
            local sm = sdk.get_managed_singleton("app.AISituationManager")
            local cid = _sc(ch, "get_CharacterID")
            if sm and cid then agent = sm:call("getAgent(app.CharacterID)", cid) end
        end)
    end

    if not M.dumped then
        M.dumped = true
        _log("──────── API DUMP (once) ────────")
        _dump_api(ch,    "Character")
        _dump_api(nav,   "NavigationController")
        _dump_api(am,    "ActionManager")
        _dump_api(agent, "AISituationAgent")
        -- ⭐ name every component on her body: this is the map of what CAN be holding the answer
        pcall(function()
            local go = ch:call("get_GameObject")
            local comps = go and go:call("get_Components")
            local names = {}
            for _, c in ipairs(comps and comps:get_elements() or {}) do
                pcall(function()
                    names[#names + 1] = tostring(c:get_type_definition():get_full_name())
                end)
            end
            table.sort(names)
            _log("COMPONENTS on the pawn (" .. #names .. "): " .. table.concat(names, ", "))
        end)
        _log("──────── watching for CHANGES ────────")
    end

    local cur = {}
    -- ⛔⛔ I DUMPED THE CHARACTER'S API AND THEN NEVER SCANNED IT. Three objects were being read
    --   and the Character — the most obvious holder of "am I allowed in here / am I following" —
    --   was not one of them. That alone could explain "15 fields, nothing changes".
    _scan(ch,    "char",      cur)
    _scan(nav,   "nav",       cur)
    _scan(agent, "situation", cur)
    _scan(am,    "action",    cur)

    -- ⭐⭐ AND EVERY COMPONENT ON HER GAMEOBJECT, DISCOVERED NOT GUESSED. Whatever tells a pawn
    --   "you are not coming into the palace" lives SOMEWHERE on that body — AI decision making,
    --   goal planning, a party/accompany controller, an area flag. Rather than keep picking
    --   candidate class names out of the air (which has failed all day), enumerate what is
    --   actually attached and read all of it. The change we are hunting cannot hide from this.
    -- ⚠ `:get_elements()` is what the shipping code uses on get_Components (EMV init.lua:3647,
    --   content_editor/ui/handlers.lua:247) — a Lua table, not an indexed array. get_size/
    --   get_element works on findComponents results but is NOT what ships for this call.
    pcall(function()
        local go = ch:call("get_GameObject")
        local comps = go and go:call("get_Components")
        local list = comps and comps:get_elements() or {}
        S.ncomp = #list
        for _, c in ipairs(list) do
            pcall(function()
                if not c then return end
                local tn = tostring(c:get_type_definition():get_name())
                -- nav/action already covered above under friendlier labels
                if tn ~= "PawnNavigationController" and tn ~= "ActionManager" then
                    _scan(c, tn, cur)
                end
            end)
        end
    end)
    -- the current action name is the single most telling line, so read it explicitly
    pcall(function()
        local a = am and am:call("get_CurrentAction")
        local nm = a and a:call("get_Name")
        if nm then cur["action.CurrentAction"] = tostring(nm) end
    end)

    -- ⭐⭐⭐ ROUTE B RECON: WHAT TASKS IS SHE ACTUALLY RUNNING?
    --   Aurora's own notes are blunt about the hard part: "you need a VALID populated task;
    --   synthesising one from scratch in Lua is impractical, so clone/re-issue an existing
    --   authored instance." So the ONLY way in is to catch a real one the game already made.
    --   This walks whatever task collection the agent exposes and logs each task BY TYPE NAME.
    --   Walk her about, let her follow you, stand at the palace — every distinct task name that
    --   appears is a candidate, and a "move/go/escort"-shaped one is the prize.
    -- ⛔ Read-only: names and counts, nothing issued, nothing cancelled.
    if agent then
        pcall(function()
            local td = agent:get_type_definition()
            for _, m in ipairs(td:get_methods()) do
                local nm = tostring(m:get_name())
                local argc = 1
                pcall(function() argc = #m:get_param_types() end)
                if argc == 0 and nm:lower():find("task") then
                    local v
                    pcall(function() v = m:call(agent) end)
                    if v then
                        -- a list of tasks?
                        local list
                        pcall(function() list = v:get_elements() end)
                        if type(list) == "table" then
                            local names = {}
                            for _, t in ipairs(list) do
                                pcall(function()
                                    names[#names + 1] = tostring(t:get_type_definition():get_name())
                                end)
                            end
                            table.sort(names)
                            cur["TASKS." .. nm] = (#names == 0) and "(none)" or table.concat(names, "+")
                        else
                            -- or a single task object
                            local one
                            pcall(function() one = tostring(v:get_type_definition():get_name()) end)
                            if one then cur["TASK." .. nm] = one end
                        end
                    end
                end
            end
        end)
    end

    local n, tot = 0, 0
    for k, v in pairs(cur) do
        tot = tot + 1
        if S.last[k] ~= v then
            _log(string.format("%-52s %s -> %s", k, tostring(S.last[k]), v))
            S.last[k] = v
            n = n + 1
        end
    end
    S.total = tot
    if n > 0 then S.note = string.format("%d change(s) at %s", n, os.date("%H:%M:%S")) end
end

re.on_application_entry("UpdateBehavior", function() pcall(_tick) end)

re.on_draw_ui(function()
    if not imgui.tree_node("IRIS PAWN OBSERVE (what does the GAME do to a pawn?)") then return end
    imgui.text("Read-only. Watch the pawn near the palace / tavern and read the log.")
    imgui.text("status: " .. tostring(S.note))
    -- ⭐ THE NUMBER THAT WAS MISSING. "5 changes" forever could mean "nothing changed" OR "we are
    --   reading almost nothing" — and it was the second. Now you can see the difference at a glance.
    imgui.text(string.format("watching %d field(s) across %d component(s)",
        S.total or 0, S.ncomp or 0))
    -- ⭐ every source and its field count, so "reading nothing" is never mistaken for
    --   "nothing changed" again. MISSING means the object itself could not be found.
    do
        local keys = {}
        for k in pairs(S.counts) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            imgui.text(string.format("    %-32s %s", k, tostring(S.counts[k])))
        end
    end
    local c
    c, M.on = imgui.checkbox("watch", M.on == true)
    imgui.same_line()
    c, M.wide = imgui.checkbox("wide (every getter, not just likely names)", M.wide ~= false)
    -- ⭐ bracket the interesting moment so the log is readable afterwards
    if imgui.button("MARK the log (press before/after the palace)") then
        _log("──────── MARK ────────")
        S.note = "marked"
    end
    c, M.every = imgui.slider_float("sample every (s)", M.every or 0.4, 0.1, 2.0)
    -- ⭐⭐⭐ DUMP ONE COMPONENT IN FULL, SETTERS INCLUDED. The scan only ever reads zero-arg
    --   GETTERS, which is why we can see `get_CurrentFormationOffset` collapse to (0,0,0) at the
    --   palace but have no idea what WRITES it. app.FormationEvaluator is the party-formation
    --   system — the thing that tells a pawn where to stand relative to the Arisen — and it is
    --   the first candidate all day that visibly OUTRANKS the follow drive rather than competing
    --   with it. Type a component name (from the COMPONENTS line in the log) to see everything
    --   it exposes, arg counts and all.
    imgui.push_item_width(220)
    local _, cn = imgui.input_text("##ipo_dump", M.dump_name or "FormationEvaluator", 32)
    imgui.pop_item_width()
    if cn and cn ~= "" then M.dump_name = cn end
    imgui.same_line()
    if imgui.button("dump this component") then
        local want = tostring(M.dump_name or ""):lower()
        local ch = _pawn()
        local found = 0
        pcall(function()
            local comps = ch:call("get_GameObject"):call("get_Components")
            for _, c in ipairs(comps and comps:get_elements() or {}) do
                pcall(function()
                    local full = tostring(c:get_type_definition():get_full_name())
                    if full:lower():find(want, 1, true) then
                        found = found + 1
                        _dump_api(c, full)
                        -- and its live values right now, so a setter can be matched to what it sets
                        local now = {}
                        _scan(c, full, now)
                        for k, v in pairs(now) do _log("   NOW " .. k .. " = " .. v) end
                    end
                end)
            end
        end)
        S.note = string.format("dumped %d component(s) matching '%s'", found, tostring(M.dump_name))
        _log("dump-by-name '" .. tostring(M.dump_name) .. "' matched " .. found)
    end
    if imgui.button("re-dump the API list") then M.dumped = false end
    imgui.same_line()
    if imgui.button("forget the baseline (log everything again)") then S.last = {} end
    imgui.text("log: reframework/data/" .. LOG)
    imgui.tree_pop()
end)

_log("IrisPawnObserve loaded (off by default)")
