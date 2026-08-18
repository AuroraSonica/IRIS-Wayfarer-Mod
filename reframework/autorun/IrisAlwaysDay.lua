-- IrisAlwaysDay.lua — freeze the in-game clock at a chosen hour (dev/testing lighting tool).
--
-- WHY THIS EXISTS: RiftSpeakDevDebug's "Pause in-game time" only ever called
-- app.TimeManager:setTimeScale(0). Two problems with that:
--   1) DD2 runs TWO clocks. _TimeData drives gameplay hour/minute; _TimeDataLook (a TimeData
--      subclass) drives the SUN TIMELINE — i.e. the actual sky/lighting you're testing against.
--      setTimeScale may only reach one of them; there are separate setTimeScaleInside /
--      setTimeScaleLook entry points for exactly that reason.
--   2) Nothing stops the game re-writing the scale (area transitions, TimeSkip, quests all
--      touch it), so a one-shot scale write silently lapses.
--
-- WHAT WE DO INSTEAD — layered, from gentlest to hardest, each independently toggleable so the
-- readout tells us which one actually holds:
--   L1 _IsTimeLock = true      -- the game's OWN time lock (the flag setTimeWeather(...,isLock)
--                                 sets and releaseTimeLock() clears). Native, quest-grade.
--   L2 setTimeScale/Inside/Look(0)  -- belt and braces on both clocks.
--   L3 PIN                     -- if the clock drifts off target at all, snap it back with the
--                                 game's own setTime + setTimeLook. This is the guarantee: even
--                                 if every lock above fails, you never leave the target hour.
--   L4 _IsTimeUpdate = false   -- opt-in. Private gate flag; may or may not be the real switch.
--   L5 hook update() -> SKIP   -- opt-in nuclear. Also stops TimeManager's detection/quest-timer
--                                 pumping, so it's off by default.
--
-- The panel shows a live "moving" readout per clock, sampled BEFORE the pin corrects, so you can
-- see whether the underlying freeze is real or whether only the pin is holding the line.
--
-- ⚠ setTime's real signature is setTime(hour, minute, day, isUpdateWeather) — verified against
-- il2cpp_dump.json. RiftSpeakDevDebug was passing (day, 8, 0, false), i.e. hour=day. Fixed there.

local MOD = "[IrisAlwaysDay]"
local CFG = "Iris/alwaysday.json"

-- ---- typedef handles (resolved once) -----------------------------------------
local TD_TM          = sdk.find_type_definition("app.TimeManager")
local F_IsTimeLock   = TD_TM and TD_TM:get_field("_IsTimeLock")
local F_IsTimeUpdate = TD_TM and TD_TM:get_field("_IsTimeUpdate")
local M_update       = TD_TM and TD_TM:get_method("update")

local S = {
    on        = false,
    hour      = 12, minute = 0,     -- target clock (noon = flattest, brightest light)
    use_lock  = true,               -- L1 _IsTimeLock
    use_scale = true,               -- L2 the three scale setters
    pin       = true,               -- L3 snap-back corrector
    use_flag  = false,              -- L4 _IsTimeUpdate = false
    use_hook  = false,              -- L5 skip TimeManager.update()

    saved_scale = nil, saved_look_scale = nil,
    hook_installed = false,
    corrections = 0,                -- how many times the pin had to snap us back
    drift_inside = 0.0,             -- in-game seconds the gameplay clock moved between samples
    drift_look   = 0.0,             -- ...and the sun/look clock
    sample_t = 0, last_elapsed = nil, last_elapsed_look = nil,
    status = "loaded",
}

local function tlog(m) m = tostring(m); S.status = m; log.info(MOD .. " " .. m) end

-- ---- safe reflection ---------------------------------------------------------
local function TM() return sdk.get_managed_singleton("app.TimeManager") end

local function sc(obj, method, ...)
    if not obj then return nil end
    local a = { ... }
    local ok, r = pcall(function() return obj:call(method, table.unpack(a)) end)
    if ok then return r end
    return nil
end

-- field write with a fallback for ExposeMember fields (set_data first, then the [] accessor)
local function setf(fld, obj, name, v)
    if not (obj) then return false end
    if fld then
        local ok = pcall(function() fld:set_data(obj, v) end)
        if ok then return true end
    end
    local ok2 = pcall(function() obj[name] = v end)
    return ok2 == true
end
local function getf(fld, obj, name)
    if not obj then return nil end
    if fld then
        local ok, r = pcall(function() return fld:get_data(obj) end)
        if ok then return r end
    end
    local ok2, r2 = pcall(function() return obj[name] end)
    if ok2 then return r2 end
    return nil
end

-- WeatherEnum.Sunny, resolved by name (enum statics read with get_data() and NO argument —
-- the proven read in world_tools.lua)
local SUNNY = nil
pcall(function()
    local td = sdk.find_type_definition("app.WeatherManager.WeatherEnum")
    if not td then return end
    for _, f in ipairs(td:get_fields()) do
        if f:is_static() and f:get_name() == "Sunny" then SUNNY = f:get_data() end
    end
end)

-- ---- clock reads -------------------------------------------------------------
local function read_clock()
    local tm = TM()
    if not tm then return nil end
    return {
        hr      = sc(tm, "get_InGameHour"),
        mn      = sc(tm, "get_InGameMinute"),
        day     = sc(tm, "get_InGameDay"),
        elapsed = sc(tm, "get_InGameElapsedDaySeconds"),
        hr_look = sc(tm, "get_InGameHourLook"),
        el_look = sc(tm, "get_InGameElapsedDaySecondsLook"),
        scale   = sc(tm, "get_TimeScale"),
        scale_l = sc(tm, "getLookTimeScale"),
        lock    = getf(F_IsTimeLock, tm, "_IsTimeLock"),
        upd     = getf(F_IsTimeUpdate, tm, "_IsTimeUpdate"),
        stop    = sc(tm, "get_IsTimeStop"),
        zone    = sc(tm, "get_NowTimeZoneType"),
        night   = sc(tm, "isNight"),
    }
end

-- ---- the hard freeze hook (installed lazily, gated on the flag) ---------------
local function ensure_hook()
    if S.hook_installed then return true end
    if not M_update then tlog("hook: no app.TimeManager.update method"); return false end
    local ok = pcall(function()
        sdk.hook(M_update,
            function(args)
                if S.on and S.use_hook then return sdk.PreHookResult.SKIP_ORIGINAL end
                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(retval) return retval end)
    end)
    S.hook_installed = ok
    tlog("hook install ok=" .. tostring(ok) .. " (cannot be removed — gated on the checkbox)")
    return ok
end

-- ---- enable / disable --------------------------------------------------------

-- jump the clock to the target hour right now (both clocks), no freeze implied
local function set_clock_to_target()
    local tm = TM()
    if not tm then tlog("set: TimeManager not ready"); return false end
    local day = sc(tm, "get_InGameDay") or 1
    -- ⚠ signature is (hour, minute, day, isUpdateWeather)
    local a = pcall(function() tm:call("setTime", S.hour, S.minute, day, false) end)
    local b = pcall(function() tm:call("setTimeLook", S.hour, S.minute, day, false) end)
    tlog(string.format("set clock -> %02d:%02d day %d  setTime=%s setTimeLook=%s",
        S.hour, S.minute, day, tostring(a), tostring(b)))
    return a or b
end

local function freeze_on()
    local tm = TM()
    if not tm then tlog("freeze: TimeManager not ready"); return end

    -- remember the real scales once, so unfreezing restores rather than guesses
    if S.saved_scale == nil then
        local r = sc(tm, "get_TimeScale")
        S.saved_scale = (type(r) == "number" and r > 0) and r or 1.0
    end
    if S.saved_look_scale == nil then
        local r = sc(tm, "getLookTimeScale")
        S.saved_look_scale = (type(r) == "number" and r > 0) and r or 1.0
    end

    set_clock_to_target()

    if S.use_lock then setf(F_IsTimeLock, tm, "_IsTimeLock", true) end
    if S.use_flag then setf(F_IsTimeUpdate, tm, "_IsTimeUpdate", false) end
    if S.use_scale then
        pcall(function() tm:call("setTimeScale", 0.0) end)
        pcall(function() tm:call("setTimeScaleInside", 0.0) end)
        pcall(function() tm:call("setTimeScaleLook", 0.0) end)
    end
    if S.use_hook then ensure_hook() end

    S.corrections = 0
    S.last_elapsed, S.last_elapsed_look = nil, nil
    tlog(string.format("FROZEN at %02d:%02d (lock=%s scale=%s pin=%s flag=%s hook=%s saved %.3f/%.3f)",
        S.hour, S.minute, tostring(S.use_lock), tostring(S.use_scale), tostring(S.pin),
        tostring(S.use_flag), tostring(S.use_hook), S.saved_scale or -1, S.saved_look_scale or -1))
end

local function freeze_off()
    local tm = TM()
    if not tm then tlog("thaw: TimeManager not ready"); return end
    -- releaseTimeLock(isSetTime, hour, minute) — false = just unlock, leave the clock where it is
    pcall(function() tm:call("releaseTimeLock", false, 0, 0) end)
    setf(F_IsTimeLock, tm, "_IsTimeLock", false)
    setf(F_IsTimeUpdate, tm, "_IsTimeUpdate", true)
    local s  = S.saved_scale or 1.0
    local sl = S.saved_look_scale or 1.0
    pcall(function() tm:call("setTimeScale", s) end)
    pcall(function() tm:call("setTimeScaleInside", s) end)
    pcall(function() tm:call("setTimeScaleLook", sl) end)
    S.saved_scale, S.saved_look_scale = nil, nil
    tlog(string.format("thawed (scale -> %.3f / look %.3f)", s, sl))
end

local function set_enabled(on)
    on = (on == true)
    if on == S.on then return end
    S.on = on
    if on then freeze_on() else freeze_off() end
    pcall(function()
        json.dump_file(CFG, { on = S.on, hour = S.hour, minute = S.minute,
            use_lock = S.use_lock, use_scale = S.use_scale, pin = S.pin,
            use_flag = S.use_flag, use_hook = S.use_hook })
    end)
end

-- one native combo shot: the game's own "set the time, lock it, and force the weather" call.
-- If this alone holds, it's the cleanest possible answer and we can drop the other layers.
local function native_lock_sunny()
    local tm = TM()
    if not tm then tlog("native: TimeManager not ready"); return end
    local w = SUNNY or 0
    local ok = pcall(function() tm:call("setTimeWeather", S.hour, S.minute, true, w, true) end)
    tlog(string.format("setTimeWeather(%d,%d,lock=true,weather=%s,force=true) ok=%s",
        S.hour, S.minute, tostring(w), tostring(ok)))
end

-- restore persisted settings (freeze itself is re-applied on the first in-game frame)
do
    local ok, saved = pcall(json.load_file, CFG)
    if ok and type(saved) == "table" then
        if type(saved.hour)   == "number" then S.hour   = math.floor(saved.hour) % 24 end
        if type(saved.minute) == "number" then S.minute = math.floor(saved.minute) % 60 end
        if saved.use_lock  ~= nil then S.use_lock  = saved.use_lock  == true end
        if saved.use_scale ~= nil then S.use_scale = saved.use_scale == true end
        if saved.pin       ~= nil then S.pin       = saved.pin       == true end
        S.use_flag = saved.use_flag == true
        S.use_hook = saved.use_hook == true
        S.want_on  = saved.on == true
    end
end

-- ---- per-frame: sample drift, then pin -------------------------------------
local applied_boot = false

re.on_frame(function()
    local tm = TM()
    if not tm then return end

    -- re-apply a persisted freeze once TimeManager is actually live
    if not applied_boot then
        local hr = sc(tm, "get_InGameHour")
        if type(hr) == "number" then
            applied_boot = true
            if S.want_on then S.on = true; freeze_on() end
        end
        return
    end

    if not S.on then return end

    local now = os.clock()
    if now < (S.sample_t or 0) then S.sample_t = 0 end
    if now - (S.sample_t or 0) < 0.25 then return end
    S.sample_t = now

    -- MEASURE FIRST (before the pin corrects) so the readout shows the true state of the freeze
    local el   = sc(tm, "get_InGameElapsedDaySeconds")
    local ell  = sc(tm, "get_InGameElapsedDaySecondsLook")
    if type(el) == "number" and type(S.last_elapsed) == "number" then
        local d = el - S.last_elapsed
        if d < 0 then d = d + 86400 end          -- rolled midnight
        S.drift_inside = d
    end
    if type(ell) == "number" and type(S.last_elapsed_look) == "number" then
        local d = ell - S.last_elapsed_look
        if d < 0 then d = d + 86400 end
        S.drift_look = d
    end

    -- keep the locks pressed (area loads / TimeSkip / quests all re-write these)
    if S.use_lock  then setf(F_IsTimeLock,   tm, "_IsTimeLock",   true)  end
    if S.use_flag  then setf(F_IsTimeUpdate, tm, "_IsTimeUpdate", false) end
    if S.use_scale then
        local cur = sc(tm, "get_TimeScale")
        if type(cur) ~= "number" or cur ~= 0.0 then
            pcall(function() tm:call("setTimeScale", 0.0) end)
            pcall(function() tm:call("setTimeScaleInside", 0.0) end)
            pcall(function() tm:call("setTimeScaleLook", 0.0) end)
        end
    end

    -- PIN: snap back if either clock left the target minute
    if S.pin then
        local hr, mn = sc(tm, "get_InGameHour"), sc(tm, "get_InGameMinute")
        local hl     = sc(tm, "get_InGameHourLook")
        local off  = (hr ~= S.hour) or (mn ~= S.minute)
        local offl = (type(hl) == "number") and (hl ~= S.hour)
        if off or offl then
            S.corrections = S.corrections + 1
            set_clock_to_target()
        end
    end

    S.last_elapsed      = sc(tm, "get_InGameElapsedDaySeconds")
    S.last_elapsed_look = sc(tm, "get_InGameElapsedDaySecondsLook")
end)

-- ---- UI ----------------------------------------------------------------------
-- resolve TimeZoneType names by value rather than guessing the order (same enum read as SUNNY)
local ZONES = {}
pcall(function()
    local td = sdk.find_type_definition("app.TimeManager.TimeZoneType")
    if not td then return end
    for _, f in ipairs(td:get_fields()) do
        if f:is_static() then
            local v = f:get_data()
            if type(v) == "number" then ZONES[v] = f:get_name() end
        end
    end
end)

local function save_cfg()
    pcall(function()
        json.dump_file(CFG, { on = S.on, hour = S.hour, minute = S.minute,
            use_lock = S.use_lock, use_scale = S.use_scale, pin = S.pin,
            use_flag = S.use_flag, use_hook = S.use_hook })
    end)
end

re.on_draw_ui(function()
    if not imgui.tree_node("Iris: Always Day (freeze the clock)") then return end

    local ch
    ch, S.on = imgui.checkbox("FREEZE TIME at the target hour", S.on)
    if ch then
        local want = S.on
        S.on = not want          -- set_enabled does the transition itself
        set_enabled(want)
    end

    ch, S.hour = imgui.slider_int("Target hour", S.hour, 0, 23)
    if ch then save_cfg(); if S.on then set_clock_to_target() end end
    imgui.same_line()
    if imgui.button("Noon##ad") then S.hour, S.minute = 12, 0; save_cfg(); set_clock_to_target() end
    imgui.same_line()
    if imgui.button("Set clock now##ad") then set_clock_to_target() end

    imgui.separator()
    imgui.text("Layers (leave the defaults unless you're diagnosing):")
    local dirty = false
    ch, S.use_lock  = imgui.checkbox("L1  _IsTimeLock (the game's own lock)", S.use_lock)          ; dirty = dirty or ch
    ch, S.use_scale = imgui.checkbox("L2  setTimeScale / Inside / Look = 0", S.use_scale)          ; dirty = dirty or ch
    ch, S.pin       = imgui.checkbox("L3  PIN — snap back if it drifts (the guarantee)", S.pin)     ; dirty = dirty or ch
    ch, S.use_flag  = imgui.checkbox("L4  _IsTimeUpdate = false (opt-in, unproven)", S.use_flag)   ; dirty = dirty or ch
    local hch
    hch, S.use_hook = imgui.checkbox("L5  skip TimeManager.update() — HARD, also halts quest timers", S.use_hook)
    if hch then
        dirty = true
        if S.use_hook then ensure_hook() end
    end
    -- turning a layer OFF mid-freeze should actually let go of it, not just stop re-pressing
    if dirty then
        save_cfg()
        if S.on then
            local tm = TM()
            if tm then
                if not S.use_lock then
                    pcall(function() tm:call("releaseTimeLock", false, 0, 0) end)
                    setf(F_IsTimeLock, tm, "_IsTimeLock", false)
                end
                if not S.use_flag then setf(F_IsTimeUpdate, tm, "_IsTimeUpdate", true) end
                if not S.use_scale then
                    local s, sl = S.saved_scale or 1.0, S.saved_look_scale or 1.0
                    pcall(function() tm:call("setTimeScale", s) end)
                    pcall(function() tm:call("setTimeScaleInside", s) end)
                    pcall(function() tm:call("setTimeScaleLook", sl) end)
                end
            end
        end
    end

    imgui.separator()
    local c = read_clock()
    if not c then
        imgui.text("TimeManager not ready (title screen / loading?)")
    else
        imgui.text(string.format("clock : %02d:%02d  day %s   elapsed %.1f",
            tonumber(c.hr) or -1, tonumber(c.mn) or -1, tostring(c.day), tonumber(c.elapsed) or -1))
        imgui.text(string.format("look  : hour %s   elapsed %.1f   zone %s%s",
            tostring(c.hr_look), tonumber(c.el_look) or -1,
            ZONES[tonumber(c.zone) or -1] or tostring(c.zone),
            (c.night == true) and "   *** NIGHT ***" or ""))
        imgui.text(string.format("scale : inside %.3f   look %.3f",
            tonumber(c.scale) or -1, tonumber(c.scale_l) or -1))
        imgui.text(string.format("flags : _IsTimeLock=%s  _IsTimeUpdate=%s  IsTimeStop=%s",
            tostring(c.lock), tostring(c.upd), tostring(c.stop)))
        if S.on then
            imgui.text(string.format("MOVING: gameplay %+.2f s/sample   sun %+.2f s/sample   (0.00 = truly frozen)",
                S.drift_inside, S.drift_look))
            imgui.text("pin corrections: " .. tostring(S.corrections)
                .. (S.corrections > 0 and "   <- a lock is leaking; the pin is holding it" or ""))
        end
    end

    imgui.separator()
    if imgui.button("Native combo: setTimeWeather(target, lock=true, Sunny, force)") then native_lock_sunny() end
    imgui.same_line(); imgui.text(SUNNY and ("Sunny=" .. tostring(SUNNY)) or "Sunny enum UNRESOLVED")

    imgui.text("status: " .. tostring(S.status))
    imgui.tree_pop()
end)

-- exported so RiftSpeakDevDebug's old checkbox can drive this instead of its dead setTimeScale
_G.IrisAlwaysDay = {
    set   = function(on) set_enabled(on == true) end,
    is_on = function() return S.on end,
    set_hour = function(h)
        if type(h) == "number" then
            S.hour = math.floor(h) % 24
            if S.on then set_clock_to_target() end
        end
    end,
}

tlog("loaded (TimeManager typedef=" .. tostring(TD_TM ~= nil)
    .. " _IsTimeLock=" .. tostring(F_IsTimeLock ~= nil)
    .. " _IsTimeUpdate=" .. tostring(F_IsTimeUpdate ~= nil)
    .. " update()=" .. tostring(M_update ~= nil) .. ")")
