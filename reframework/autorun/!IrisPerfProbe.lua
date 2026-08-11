--[[ ===========================================================================
  !IrisPerfProbe.lua  --  per-script CPU profiler for REFramework Lua mods.

  WHY THE "!" IN THE FILENAME: this file must load BEFORE every other autorun
  script. It works by monkey-patching re.on_frame / sdk.hook / etc. so that any
  callback registered afterwards gets wrapped in a counter+timer. Anything that
  registered before us is invisible to the probe. "!" (0x21) sorts ahead of
  digits and letters, so this loads first.

  WHAT IT MEASURES
    calls/frame  -- how many times per frame a callback fires. This is the
                    decisive number and it needs no timing precision at all.
                    A hook firing 2000x/frame is a problem regardless of how
                    cheap its body is: each native->Lua transition costs
                    roughly 1-5us on its own.
    ms/frame     -- wall time spent inside the callback body.

  ABOUT THE TIMING PRECISION
    os.clock() on Windows has 1ms granularity, which is far coarser than a
    single callback. That is fine here: the quantisation error is unbiased
    relative to the 1ms tick grid, so accumulating thousands of samples
    converges on the true total. Individual rows are noisy until the frame
    count is high -- let it run for a few thousand frames before trusting the
    ms columns. The calls columns are exact immediately.

  NOT MEASURED (deliberately): native plugin DLL cost, GPU cost, and .pak asset
  cost. Those need the bisect procedure, not this probe.

  SAFETY: this touches no game objects. It only wraps callbacks, counts, and
  reads a clock. Return-value arity of pre/post hooks is preserved exactly so
  hook semantics (SKIP_ORIGINAL, retval passthrough) are unchanged.
=========================================================================== ]]

local PROBE_TAG = "IrisPerfProbe"

-- Re-entry guard. If this file were ever executed twice in the same Lua state
-- the wrappers would stack and every callback would be double-counted.
if _G.IrisPerfProbe then
    log.info("[" .. PROBE_TAG .. "] already armed in this Lua state, skipping.")
    return
end

-- os.clock on Windows/MSVC is wall-clock seconds since CRT init, 1ms tick.
local HAVE_CLOCK = (type(os) == "table" and type(os.clock) == "function")
local clock = HAVE_CLOCK and os.clock or function() return 0 end

local P = {
    enabled      = true,   -- master switch; false = stop accumulating
    time_bodies  = true,   -- false = count only, no clock() calls at all
    sort_by_time = true,   -- false = sort by calls/frame
    max_rows     = 40,

    frames  = 0,
    t_start = clock(),
    recs    = {},          -- key -> record
    order   = {},          -- array of records, for iteration
}
_G.IrisPerfProbe = P

-- ---------------------------------------------------------------------------
-- Attribution: which script registered this callback?
--
-- Tries the debug library first. REFramework does not always open sol::lib::debug,
-- so there is a fallback that uses error()'s level argument -- error() embeds
-- "chunkname:line:" in its message using the call stack, and that works with no
-- debug library present.
--
-- Rather than hardcoding a stack level (the two methods count levels
-- differently, and an extra pcall frame shifts them), we walk outward and take
-- the first frame that looks like a .lua file and is not this probe.
-- ---------------------------------------------------------------------------
local HAVE_DEBUG = (type(debug) == "table" and type(debug.getinfo) == "function")

local function basename(s)
    return (s:gsub("^.*[\\/]", ""):gsub("^@", ""))
end

-- Returns (scriptBasename, registrationLine). The line is what makes a script
-- with several on_frame callbacks actionable -- without it they all collapse
-- into one row and you cannot tell which one is expensive.
local function caller_src()
    for lvl = 2, 10 do
        local s, ln
        if HAVE_DEBUG then
            local ok, info = pcall(debug.getinfo, lvl, "Sl")
            if ok and info then
                s = info.short_src or info.source
                ln = info.currentline
            end
        else
            local ok, err = pcall(function() error("@", lvl + 1) end)
            if not ok and type(err) == "string" then
                s, ln = err:match("^(.-):(%d+):")
            end
        end
        if s and s:find("%.lua") and not s:find(PROBE_TAG, 1, true) then
            return basename(s), tonumber(ln) or 0
        end
    end
    return "?unattributed", 0
end

-- ---------------------------------------------------------------------------
-- SECTION TIMING -- attributes cost INSIDE one big callback.
--
-- A mod marks its block boundaries with a single line that adds no local
-- (important: IrisTaming.lua is near Lua's 200-local-per-function ceiling):
--
--     if IPPS then IPPS("scout") end        -- closes previous section, opens "scout"
--     if IPPS then IPPS(nil) end            -- closes the last section
--
-- Purely additive: it reads a clock and writes a counter. It changes no control
-- flow, so a block's behaviour is identical whether or not the probe is loaded.
-- ---------------------------------------------------------------------------
P.sect_recs  = {}
P.sect_order = {}
local sect_cur, sect_t0 = nil, 0

-- name = string -> close current section, open this one
-- name = nil    -> close current section (normal end of the instrumented run)
-- name = false  -> ABANDON current section without accumulating. Call this at the
--                  top of the callback: an early `return` mid-body leaves a section
--                  open, and without abandoning it the whole inter-frame gap would
--                  be charged to whichever block happened to be open.
function P.sect(name)
    if not P.enabled then return end
    if name == false then sect_cur = nil; return end
    if sect_cur then
        local r = P.sect_recs[sect_cur]
        if r then
            r.time = r.time + (clock() - sect_t0)
            r.hits = r.hits + 1
        end
    end
    sect_cur = name
    if name then
        if not P.sect_recs[name] then
            P.sect_recs[name] = { name = name, time = 0, hits = 0 }
            P.sect_order[#P.sect_order + 1] = P.sect_recs[name]
        end
        sect_t0 = clock()
    end
end
_G.IPPS = P.sect

local function rec_for(src, kind)
    local key = src .. "\1" .. kind
    local r = P.recs[key]
    if not r then
        r = { src = src, kind = kind, calls = 0, time = 0 }
        P.recs[key] = r
        P.order[#P.order + 1] = r
    end
    return r
end

-- ---------------------------------------------------------------------------
-- Callback wrappers.
--
-- The arity rules matter. A REFramework pre-hook returning nothing means
-- "CALL_ORIGINAL"; a post-hook returning nothing means "leave retval alone".
-- Returning an explicit nil is NOT the same thing, so every wrapper below
-- collapses a nil result back into a zero-value return.
-- ---------------------------------------------------------------------------

-- MUTING: r.muted skips the callback body entirely. For an on_frame callback
-- that removes essentially all of its cost. For a hook it removes the BODY
-- cost but NOT the native->Lua transition cost -- the wrapper is still the
-- registered callback, so the engine still crosses into Lua to reach it.
-- Skipping a pre-hook returns nothing, which REFramework reads as
-- CALL_ORIGINAL; skipping a post-hook returns nothing, which leaves retval
-- untouched. So muting always falls back to vanilla engine behaviour.
local function wrap_void(r, fn)
    return function(...)
        if not P.enabled then return fn(...) end
        r.calls = r.calls + 1
        if r.muted then return end
        if not P.time_bodies then return fn(...) end
        local t = clock()
        fn(...)
        r.time = r.time + (clock() - t)
    end
end

local function wrap_ret(r, fn)
    return function(...)
        if not P.enabled then return fn(...) end
        r.calls = r.calls + 1
        if r.muted then return end
        if not P.time_bodies then return fn(...) end
        local t = clock()
        local a, b = fn(...)
        r.time = r.time + (clock() - t)
        if a == nil and b == nil then return end
        return a, b
    end
end

-- ---------------------------------------------------------------------------
-- Patch re.*
-- ---------------------------------------------------------------------------
local re_on_frame    = re.on_frame
local re_on_draw_ui  = re.on_draw_ui

re.on_frame = function(fn)
    local src, ln = caller_src()
    local r = rec_for(src, "on_frame @" .. ln)
    return re_on_frame(wrap_void(r, fn))
end

if re_on_draw_ui then
    re.on_draw_ui = function(fn)
        local src, ln = caller_src()
        local r = rec_for(src, "on_draw_ui @" .. ln)
        return re_on_draw_ui(wrap_void(r, fn))
    end
end

for _, name in ipairs({ "on_pre_application_entry", "on_post_application_entry" }) do
    local orig = re[name]
    if orig then
        re[name] = function(entry, fn)
            local src, ln = caller_src()
            local r = rec_for(src, name:gsub("^on_", "") .. ":" .. tostring(entry) .. " @" .. ln)
            return orig(entry, wrap_void(r, fn))
        end
    end
end

-- ---------------------------------------------------------------------------
-- Patch sdk.hook / sdk.hook_vtable
--
-- Pre and post are counted as SEPARATE rows on purpose: a hook with both
-- costs two native->Lua transitions per invocation, and seeing them split
-- makes that obvious.
-- ---------------------------------------------------------------------------
local function method_label(method)
    local ok, s = pcall(function()
        local dt = method:get_declaring_type()
        local tn = dt and dt:get_full_name() or "?"
        return tn .. "." .. (method:get_name() or "?")
    end)
    if ok and type(s) == "string" then return s end
    return "?method"
end

local sdk_hook = sdk.hook
sdk.hook = function(method, pre, post, ...)
    local src, ln = caller_src()
    local lbl = method_label(method) .. " @" .. ln
    local wpre, wpost
    if pre  then wpre  = wrap_ret(rec_for(src, "hook.pre  " .. lbl), pre)  end
    if post then wpost = wrap_ret(rec_for(src, "hook.post " .. lbl), post) end
    return sdk_hook(method, wpre, wpost, ...)
end

if sdk.hook_vtable then
    local sdk_hook_vtable = sdk.hook_vtable
    sdk.hook_vtable = function(obj, method, pre, post, ...)
        local src, ln = caller_src()
        local lbl = "vt " .. method_label(method) .. " @" .. ln
        local wpre, wpost
        if pre  then wpre  = wrap_ret(rec_for(src, "hook.pre  " .. lbl), pre)  end
        if post then wpost = wrap_ret(rec_for(src, "hook.post " .. lbl), post) end
        return sdk_hook_vtable(obj, method, wpre, wpost, ...)
    end
end

-- ---------------------------------------------------------------------------
-- Patch d2d.register (reframework-d2d plugin). Its render callback runs every
-- frame and text/font draws there are genuinely expensive.
-- ---------------------------------------------------------------------------
if type(d2d) == "table" and type(d2d.register) == "function" then
    local d2d_register = d2d.register
    d2d.register = function(init_fn, render_fn)
        local src, ln = caller_src()
        local r = rec_for(src, "d2d.render @" .. ln)
        return d2d_register(init_fn, render_fn and wrap_void(r, render_fn) or nil)
    end
end

-- ---------------------------------------------------------------------------
-- Frame counter. Registered through the ORIGINAL re.on_frame so the probe does
-- not profile itself.
-- ---------------------------------------------------------------------------
P.fps_recent = 0
local fps_n, fps_t = 0, clock()
re_on_frame(function()
    if P.enabled then P.frames = P.frames + 1 end
    fps_n = fps_n + 1
    if fps_n >= 60 then
        local now = clock()
        local dt = now - fps_t
        if dt > 0 then P.fps_recent = fps_n / dt end
        fps_n, fps_t = 0, now
    end
end)

-- ---------------------------------------------------------------------------
-- Reporting
-- ---------------------------------------------------------------------------
function P.reset()
    P.frames = 0
    P.t_start = clock()
    for _, r in ipairs(P.order) do
        r.calls = 0
        r.time = 0
    end
    for _, r in ipairs(P.sect_order) do
        r.time = 0
        r.hits = 0
    end
end

-- A/B testing: silence one script's callbacks live, no game restart needed.
-- Workflow: mute -> press "reset counters" -> read "recent fps" for ~10s.
function P.mute_script(src, on)
    for _, r in ipairs(P.order) do
        if r.src == src then r.muted = on and true or nil end
    end
end

function P.is_script_muted(src)
    for _, r in ipairs(P.order) do
        if r.src == src and r.muted then return true end
    end
    return false
end

function P.unmute_all()
    for _, r in ipairs(P.order) do r.muted = nil end
end

-- Rolls individual callbacks up to one line per script.
function P.by_script()
    local agg, arr = {}, {}
    for _, r in ipairs(P.order) do
        local a = agg[r.src]
        if not a then
            a = { src = r.src, calls = 0, time = 0, entries = 0 }
            agg[r.src] = a
            arr[#arr + 1] = a
        end
        a.calls = a.calls + r.calls
        a.time = a.time + r.time
        a.entries = a.entries + 1
    end
    return arr
end

local function sorter(a, b)
    if P.sort_by_time and HAVE_CLOCK then
        if a.time ~= b.time then return a.time > b.time end
    end
    return a.calls > b.calls
end

function P.report()
    local f = math.max(P.frames, 1)
    local wall = clock() - P.t_start
    local out = {
        frames = P.frames,
        wall_seconds = wall,
        avg_fps = (wall > 0) and (P.frames / wall) or 0,
        clock_available = HAVE_CLOCK,
        attribution = HAVE_DEBUG and "debug.getinfo" or "error-level fallback",
        by_script = {},
        by_callback = {},
        sections = {},
    }
    local sects = {}
    for _, r in ipairs(P.sect_order) do sects[#sects + 1] = r end
    table.sort(sects, function(a, b) return a.time > b.time end)
    for _, r in ipairs(sects) do
        out.sections[#out.sections + 1] = {
            name = r.name,
            ms_per_frame = (r.time * 1000) / f,
            hits_per_frame = r.hits / f,
        }
    end
    local scripts = P.by_script()
    table.sort(scripts, sorter)
    for _, a in ipairs(scripts) do
        out.by_script[#out.by_script + 1] = {
            script = a.src,
            callbacks = a.entries,
            calls_per_frame = a.calls / f,
            ms_per_frame = (a.time * 1000) / f,
        }
    end
    local cbs = {}
    for _, r in ipairs(P.order) do cbs[#cbs + 1] = r end
    table.sort(cbs, sorter)
    for _, r in ipairs(cbs) do
        out.by_callback[#out.by_callback + 1] = {
            script = r.src,
            what = r.kind,
            calls_per_frame = r.calls / f,
            ms_per_frame = (r.time * 1000) / f,
        }
    end
    return out
end

function P.dump()
    local ok, err = pcall(function()
        json.dump_file("IrisPerfProbe_report.json", P.report())
    end)
    if ok then
        log.info("[" .. PROBE_TAG .. "] wrote reframework/data/IrisPerfProbe_report.json")
    else
        log.info("[" .. PROBE_TAG .. "] dump failed: " .. tostring(err))
    end
    return ok
end

-- ---------------------------------------------------------------------------
-- UI. Uses the ORIGINAL re.on_draw_ui so the probe's own UI is not profiled.
-- Plain text rows rather than imgui tables, so this works on every REF build.
-- ---------------------------------------------------------------------------
re_on_draw_ui(function()
    if not imgui.tree_node("Iris Perf Probe") then return end

    local f = math.max(P.frames, 1)
    local wall = clock() - P.t_start
    imgui.text(string.format("RECENT FPS: %.1f   (rolling 60-frame average)", P.fps_recent))
    imgui.text(string.format("frames sampled: %d   window: %.1fs   avg fps: %.1f",
        P.frames, wall, (wall > 0) and (P.frames / wall) or 0))
    imgui.text(string.format("clock: %s   attribution: %s   tracked callbacks: %d",
        HAVE_CLOCK and "os.clock (1ms tick)" or "UNAVAILABLE - counts only",
        HAVE_DEBUG and "debug.getinfo" or "error-level fallback",
        #P.order))

    if not HAVE_CLOCK then
        imgui.text("No clock available: trust the calls/frame column, ignore ms.")
    elseif P.frames < 2000 then
        imgui.text("ms columns are noisy below ~2000 frames. calls/frame is exact now.")
    end
    if P.time_bodies then
        imgui.text("Observer effect: timing costs ~80ns per call. If a row shows a")
        imgui.text("huge calls/frame, untick 'time bodies' - counts stay exact.")
    end

    imgui.spacing()
    local changed
    changed, P.enabled = imgui.checkbox("accumulating", P.enabled)
    imgui.same_line()
    changed, P.time_bodies = imgui.checkbox("time bodies", P.time_bodies)
    imgui.same_line()
    changed, P.sort_by_time = imgui.checkbox("sort by ms", P.sort_by_time)

    if imgui.button("reset counters") then P.reset() end
    imgui.same_line()
    if imgui.button("dump json") then P.dump() end

    imgui.spacing()

    if imgui.tree_node("By script (start here)") then
        imgui.text("Tick a box to MUTE that script's callbacks live, then hit")
        imgui.text("'reset counters' and watch 'recent fps'. Instant A/B, no restart.")
        imgui.text("Caution: muting a script mid-activity can strand its state machine")
        imgui.text("(a griffin ride, an active ritual). Unmute restores it.")
        if imgui.button("unmute all") then P.unmute_all() end
        imgui.spacing()

        local scripts = P.by_script()
        table.sort(scripts, sorter)
        imgui.text(string.format("%-4s %-30s %10s %10s", "mute", "script", "ms/frame", "calls/fr"))
        local total = 0
        for i, a in ipairs(scripts) do
            total = total + a.time
            if i <= P.max_rows then
                local was = P.is_script_muted(a.src)
                local chg, now = imgui.checkbox("##m_" .. a.src, was)
                if chg and now ~= was then P.mute_script(a.src, now) end
                imgui.same_line()
                imgui.text(string.format("%-30s %10.4f %10.1f",
                    a.src:sub(1, 30), (a.time * 1000) / f, a.calls / f))
            end
        end
        imgui.spacing()
        imgui.text(string.format("%-35s %10.4f", "TOTAL measured Lua", (total * 1000) / f))
        imgui.tree_pop()
    end

    if #P.sect_order > 0 and imgui.tree_node("Sections (inside one callback)") then
        local sects = {}
        for _, r in ipairs(P.sect_order) do sects[#sects + 1] = r end
        table.sort(sects, function(a, b) return a.time > b.time end)
        imgui.text(string.format("%-30s %10s %9s", "section", "ms/frame", "hits/fr"))
        local tot = 0
        for _, r in ipairs(sects) do
            tot = tot + r.time
            imgui.text(string.format("%-30s %10.4f %9.1f",
                r.name:sub(1, 30), (r.time * 1000) / f, r.hits / f))
        end
        imgui.text(string.format("%-30s %10.4f", "TOTAL sectioned", (tot * 1000) / f))
        imgui.tree_pop()
    end

    if imgui.tree_node("By callback (what to fix)") then
        local cbs = {}
        for _, r in ipairs(P.order) do cbs[#cbs + 1] = r end
        table.sort(cbs, sorter)
        imgui.text(string.format("%-20s %-52s %9s %9s", "script", "callback", "ms/frame", "calls/fr"))
        for i = 1, math.min(#cbs, P.max_rows) do
            local r = cbs[i]
            imgui.text(string.format("%-20s %-52s %9.4f %9.1f",
                r.src:sub(1, 20), r.kind:sub(1, 52), (r.time * 1000) / f, r.calls / f))
        end
        imgui.tree_pop()
    end

    imgui.tree_pop()
end)

re.on_script_reset(function()
    P.reset()
end)

log.info("[" .. PROBE_TAG .. "] armed. clock=" .. tostring(HAVE_CLOCK) ..
         " debug=" .. tostring(HAVE_DEBUG))
