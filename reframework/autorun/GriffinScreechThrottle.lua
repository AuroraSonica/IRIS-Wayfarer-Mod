-- ============================================================================
-- GriffinScreechThrottle.lua  (Iris, for Aurora)
-- The tamed griffin (ch253) screeches constantly when idle. Its voices post through
-- soundlib.SoundContainer / app.WwiseContainerApp -> trigger(...). We hook those and
-- rate-limit the screech so it fires only every so often. Standalone: does NOT touch
-- the griffin mount code.
--
-- Two throttle modes:
--   "each"  = each chosen sound id plays at most once per interval  (screech every N secs,
--             wings/feet/breathing unaffected)  <-- what you usually want
--   "group" = ONE chosen sound total per interval (shared timer; sparsest, but the most
--             frequent sound wins the slot and can starve the screech entirely)
-- Pick the ids to throttle by LEARNING while the griffin stands still (idle = only the
-- screech/idle voices fire; wings + feet need movement so they stay out of the set).
-- ============================================================================

local C = {
    enabled = true,
    learn = false,
    throttle = true,
    mode = "each",            -- "each" | "group"
    throttle_empty_all = false, -- if the set is empty, throttle ALL griffin voice (blunt fallback)
    species = "ch253",        -- substring of the griffin's sound-object name
    min_interval = 25.0,      -- seconds: bigger = quieter (min gap between allowed screeches)
}

-- The griffin's idle-voice trigger ids (Wwise hashes = stable across sessions + every griffin),
-- captured 2026-07-08 by learning while ch253000_00 stood idle. 655309512 is the dominant screech.
-- These ship throttled by default so the feature just works -- edit the set in the UI to taste.
local DEFAULT_SCREECH = {
    655309512, 2217285698, 673994548, 3009711778, 2372138774,
    3941720137, 3618194173, 2453401260, 2247306973, 3453055456, 3328169705,
}

local S = {
    type_found = false, hooks = 0, captures = 0,
    hist = {}, names = {},
    screech = {},             -- id -> true : ids we throttle
    last_fire = {},           -- id -> os.clock (per-id timer, "each" mode)
    last_group = 0.0,         -- shared timer ("group" mode)
    blocked = 0, passed = 0, manual = 0, ri_dumped = false,
}
for _, id in ipairs(DEFAULT_SCREECH) do S.screech[id] = true end

-- should this trigger be dropped right now?
local function do_throttle(id, nm)
    if not C.throttle then return false end
    if S.riding then return false end   -- mounted/flying: let the WINGS + flight sounds play in full (Aurora)
    if C.species ~= "" and not (nm:find(C.species, 1, true) ~= nil) then return false end
    if next(S.screech) then
        if not S.screech[id] then return false end          -- a set is chosen: only throttle those ids
    elseif not C.throttle_empty_all then
        return false                                         -- empty set + not blunt-all: throttle nothing
    end
    local now = os.clock()
    local gap = tonumber(C.min_interval) or 8.0
    if C.mode == "group" then
        if now - (tonumber(S.last_group) or 0.0) < gap then S.blocked = S.blocked + 1; return true end
        S.last_group = now; S.passed = S.passed + 1; return false
    else
        if now - (tonumber(S.last_fire[id]) or 0.0) < gap then S.blocked = S.blocked + 1; return true end
        S.last_fire[id] = now; S.passed = S.passed + 1; return false
    end
end

local function active()
    return C.learn or (C.throttle and (next(S.screech) ~= nil or C.throttle_empty_all))
end

local function owner_name(args)
    local nm = "?"
    pcall(function()
        local this = sdk.to_managed_object(args[2])
        local go = this and this:call("get_GameObject")
        if go then nm = tostring(go:call("get_Name") or "?") end
    end)
    if nm == "?" then
        pcall(function()
            local g = sdk.to_managed_object(args[4])
            if g and g.call then local n = g:call("get_Name"); if n then nm = tostring(n) end end
        end)
    end
    return nm
end

local function on_trigger(args)
    if not C.enabled or not active() then return end
    local id = nil
    pcall(function() id = tonumber(sdk.to_int64(args[3])) end)
    if not id or id < 0 then return end
    local nm = owner_name(args)
    if C.learn then
        S.captures = S.captures + 1
        S.hist[id] = (S.hist[id] or 0) + 1
        S.names[id] = nm
    end
    if do_throttle(id, nm) then return sdk.PreHookResult.SKIP_ORIGINAL end
end

-- read the trigger id out of a soundlib.SoundManager.RequestInfo (character voices take THIS path)
local function ri_id(ri)
    for _, name in ipairs({ "_TriggerId", "TriggerId", "_triggerId", "triggerId" }) do
        local v = nil
        pcall(function() v = ri:get_field(name) end)
        if v ~= nil then local n = tonumber(v); if n and n > 0 then return n end end
    end
    local n2 = nil
    pcall(function()
        local ti = ri:get_field("_TriggerInfo")
        if ti then local v = ti:get_field("_TriggerId"); if v then n2 = tonumber(v) end end
    end)
    return n2
end

local function ri_owner(args, ri)
    local nm = "?"
    pcall(function()
        local cont = ri:get_field("<Container>k__BackingField")
        local go = cont and cont:call("get_GameObject")
        if go then nm = tostring(go:call("get_Name") or "?") end
    end)
    if nm == "?" then
        pcall(function()
            local this = sdk.to_managed_object(args[2])
            local go = this and this:call("get_GameObject")
            if go then nm = tostring(go:call("get_Name") or "?") end
        end)
    end
    return nm
end

local function on_trigger_ri(args)
    if not C.enabled or not active() then return end
    local ri = nil
    pcall(function() ri = sdk.to_managed_object(args[3]) end)
    if not ri then return end
    if C.learn and not S.ri_dumped then
        S.ri_dumped = true
        pcall(function()
            local td = ri:get_type_definition()
            log.info("[GriffinScreech] RequestInfo type=" .. tostring(td and td:get_full_name()))
            for _, f in ipairs((td and td:get_fields()) or {}) do
                local fn = tostring(f:get_name()); local val = "?"
                pcall(function() val = tostring(ri:get_field(fn)) end)
                log.info("[GriffinScreech]   ri." .. fn .. " = " .. val)
            end
        end)
    end
    local id = ri_id(ri)
    if not id or id < 0 then return end
    local nm = ri_owner(args, ri)
    if C.learn then
        S.captures = S.captures + 1
        S.hist[id] = (S.hist[id] or 0) + 1
        S.names[id] = nm .. " (RI)"
    end
    if do_throttle(id, nm) then return sdk.PreHookResult.SKIP_ORIGINAL end
end

local function install()
    if S.type_found then return end
    local types = { "app.WwiseContainerApp", "soundlib.SoundContainer" }
    local sigs = {
        "trigger(System.UInt32)",
        "trigger(System.UInt32, via.GameObject)",
        "trigger(System.UInt32, via.GameObject, via.GameObject)",
        "trigger(System.UInt32, via.vec3, via.GameObject)",
        "triggerLogLess(System.UInt32, via.GameObject, via.GameObject)",
        "triggerLogLess(System.UInt32, via.vec3, via.GameObject)",
    }
    local any = false
    for _, tn in ipairs(types) do
        local td = sdk.find_type_definition(tn)
        if td then
            any = true
            for _, sig in ipairs(sigs) do
                local m = nil
                pcall(function() m = td:get_method(sig) end)
                if m then
                    local ok = pcall(function() sdk.hook(m, function(a) return on_trigger(a) end, function(r) return r end) end)
                    if ok then S.hooks = S.hooks + 1 end
                end
            end
            local mri = nil
            pcall(function() mri = td:get_method("trigger(soundlib.SoundManager.RequestInfo)") end)
            if mri then
                local ok = pcall(function() sdk.hook(mri, function(a) return on_trigger_ri(a) end, function(r) return r end) end)
                if ok then S.hooks = S.hooks + 1 end
            end
        end
    end
    if not any then return end
    S.type_found = true
    pcall(function() log.info("[GriffinScreech] install done: hooks=" .. S.hooks) end)
end

install()
re.on_frame(function() install() end)

-- while the player is riding/climbing the griffin (mounting + flight), suspend the throttle so
-- wing-flap + flight sounds play in full -- the screech throttle only applies to a grounded idle
-- griffin (Aurora: throttling silenced the wings while flying).
re.on_frame(function()
    pcall(function()
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local pc = cm and cm:call("get_ManualPlayer")
        S.riding = (pc and pc:call("get_IsClimbOnCharacter") == true) or false
    end)
end)

local function top_ids(k)
    local arr = {}
    for id, c in pairs(S.hist) do arr[#arr + 1] = { id = id, c = c } end
    table.sort(arr, function(a, b) return a.c > b.c end)
    while #arr > k do arr[#arr] = nil end
    return arr
end

re.on_draw_ui(function()
    if not imgui.tree_node("Griffin Screech Throttle") then return end
    local ch
    ch, C.enabled = imgui.checkbox("enabled", C.enabled)
    ch, C.species = imgui.input_text("griffin name substring", C.species)
    imgui.text(string.format("hook: type=%s  methods=%d", tostring(S.type_found), S.hooks))
    imgui.separator()

    imgui.text("1) LEARN the screech: let the griffin STAND STILL, tick learn ~15s.")
    ch, C.learn = imgui.checkbox("learn", C.learn)
    imgui.same_line(); if imgui.button("reset") then S.hist = {}; S.names = {}; S.captures = 0 end
    imgui.text("captures: " .. S.captures)
    if imgui.button(">> throttle EVERYTHING just learned <<") then
        for id in pairs(S.hist) do S.screech[id] = true end
    end
    imgui.same_line(); if imgui.button("dump to log") then
        for _, e in ipairs(top_ids(40)) do
            pcall(function() log.info(string.format("[GriffinScreech] id=%d x%d name=%s", e.id, e.c, tostring(S.names[e.id]))) end)
        end
        for id in pairs(S.screech) do pcall(function() log.info("[GriffinScreech] SET id=" .. id) end) end
    end
    for i, e in ipairs(top_ids(12)) do
        imgui.text(string.format("id %d  x%d  [%s]%s", e.id, e.c, tostring(S.names[e.id]), S.screech[e.id] and "  <THROTTLED>" or ""))
        imgui.same_line(); if imgui.button((S.screech[e.id] and "keep##" or "throttle##") .. i) then
            if S.screech[e.id] then S.screech[e.id] = nil else S.screech[e.id] = true end
        end
    end
    imgui.separator()

    imgui.text("2) THROTTLE  (bigger seconds = quieter):")
    ch, C.throttle = imgui.checkbox("throttle on", C.throttle)
    if imgui.button("mode: " .. C.mode .. "  (click to swap each/group)") then
        C.mode = (C.mode == "each") and "group" or "each"
    end
    imgui.text(C.mode == "each" and "  each: every chosen sound plays once per interval (screech every N; keeps variety)"
        or "  group: ONE chosen sound total per interval (sparsest; can starve the screech)")
    ch, C.min_interval = imgui.drag_float("seconds", C.min_interval, 0.25, 0.5, 60.0)
    local nset = 0; for _ in pairs(S.screech) do nset = nset + 1 end
    imgui.text("screech set: " .. nset .. " ids")
    imgui.same_line(); if imgui.button("clear set") then S.screech = {}; S.last_fire = {} end
    imgui.same_line(); if imgui.button("restore defaults") then
        S.screech = {}; S.last_fire = {}
        for _, id in ipairs(DEFAULT_SCREECH) do S.screech[id] = true end
        C.min_interval = 25.0; C.mode = "each"; C.throttle = true
    end
    imgui.same_line(); ch, C.throttle_empty_all = imgui.checkbox("empty set = throttle ALL voice", C.throttle_empty_all)
    imgui.text(string.format("silenced=%d  let-through=%d", S.blocked, S.passed))
    ch, S.manual = imgui.drag_int("manual id", math.floor(S.manual or 0), 1, 0, 2000000000)
    imgui.same_line(); if imgui.button("add") and S.manual > 0 then S.screech[math.floor(S.manual)] = true end

    imgui.tree_pop()
end)
