-- IrisFlightRecorder.lua - black-box crash observer for the homestead stack (2026-07-21).
--
-- Lua cannot catch a native CTD, but it CAN leave a black box: every second this writes a snapshot
-- of everything in flight (forge build state, collision rigs queued, recent breadcrumbs) to
-- IRIS/flight_state.txt. After a crash, that file holds the last-known state - i.e. WHAT the mod was
-- doing when the game died. On the next script load, the previous snapshot is archived to
-- IRIS/crash_history.txt and, if it shows ops in flight, flagged loudly in the panel.
--
-- Other modules drop breadcrumbs via _G.IrisFlight.note("...") (homestead + collision _log mirror in).
-- ⚠ a snapshot showing IDLE just means our stack wasn't mid-op (game may have closed normally OR
-- crashed for unrelated reasons). The gold is an ACTIVE snapshot: it names the killer op.

local M = {}

local STATE_FILE = "IRIS/flight_state.txt"
local HISTORY_FILE = "IRIS/crash_history.txt"

local crumbs = {}          -- ring buffer of last 12 breadcrumbs
local CRUMB_MAX = 12
M.prev_report = nil        -- previous session's final snapshot (shown in the panel)
M.prev_active = false      -- did the previous snapshot show ops in flight?
local hb_f = 0

local function _note(s)
    crumbs[#crumbs + 1] = "[" .. os.date("%H:%M:%S") .. "] " .. tostring(s)
    while #crumbs > CRUMB_MAX do table.remove(crumbs, 1) end
end

_G.IrisFlight = { note = _note }

-- ── on load: archive the previous session's final snapshot ──────────────────────────────
do
    local prev
    pcall(function()
        local f = io.open(STATE_FILE, "r")
        if f then prev = f:read("*a"); f:close() end
    end)
    if prev and #prev > 0 then
        M.prev_report = prev
        M.prev_active = prev:find("ACTIVE", 1, true) ~= nil
        pcall(function()
            local h = io.open(HISTORY_FILE, "a")
            if h then
                h:write("\n===== previous session final state (archived " .. os.date("%Y-%m-%d %H:%M:%S")
                    .. (M.prev_active and ") - OPS WERE IN FLIGHT =====\n" or ") - idle =====\n"))
                h:write(prev)
                h:close()
            end
        end)
    end
    _note("flight recorder started")
end

-- ── the heartbeat snapshot ──────────────────────────────────────────────────────────────
local function _snapshot()
    local lines = {}
    local active = {}
    lines[#lines + 1] = "snapshot " .. os.date("%Y-%m-%d %H:%M:%S")
    pcall(function()
        if _G.IrisForge and _G.IrisForge.status then
            local st = _G.IrisForge.status()
            if st then
                lines[#lines + 1] = string.format("forge: instances=%d building=%s last=%s",
                    st.instances or 0, tostring(st.building), tostring(st.last))
                if st.building then active[#active + 1] = "FORGE BUILDING" end
            end
        else
            lines[#lines + 1] = "forge: (not loaded)"
        end
    end)
    pcall(function()
        if _G.IrisCollision and _G.IrisCollision.count then
            local busy = _G.IrisCollision.busy and _G.IrisCollision.busy()
            lines[#lines + 1] = string.format("collision: rigs=%d busy=%s",
                _G.IrisCollision.count() or 0, tostring(busy))
            if busy then active[#active + 1] = "COLLISION RIGS SPAWNING" end
        else
            lines[#lines + 1] = "collision: (not loaded)"
        end
    end)
    pcall(function()
        if _G.IrisHomestead and _G.IrisHomestead.inflight then
            local infl = _G.IrisHomestead.inflight()
            lines[#lines + 1] = "homestead inflight: " .. tostring(infl or "none")
            if infl then active[#active + 1] = "HOMESTEAD " .. infl end
        end
    end)
    pcall(function()
        if _G.IrisPlot then
            lines[#lines + 1] = string.format("plot bridge: live=%s", tostring(_G.IrisPlot.live))
        end
    end)
    lines[#lines + 1] = (#active > 0) and ("state: ACTIVE - " .. table.concat(active, " + "))
        or "state: idle"
    lines[#lines + 1] = "-- breadcrumbs (newest last) --"
    for _, c in ipairs(crumbs) do lines[#lines + 1] = c end
    pcall(function()
        local f = io.open(STATE_FILE, "w")   -- overwrite: this file IS the black box
        if f then f:write(table.concat(lines, "\n") .. "\n"); f:close() end
    end)
end

re.on_application_entry("UpdateBehavior", function()
    hb_f = hb_f + 1
    if hb_f >= 60 then hb_f = 0; _snapshot() end   -- ~1/s
end)

re.on_draw_ui(function()
    if not imgui.tree_node("IRIS FLIGHT RECORDER (crash black box)") then return end
    if M.prev_active then
        imgui.text("!! PREVIOUS SESSION ENDED WITH OPS IN FLIGHT !!")
        imgui.text("(that snapshot names what was running when the game died)")
    else
        imgui.text("previous session ended idle (or no prior snapshot)")
    end
    imgui.text("black box: data/" .. STATE_FILE .. "  |  archive: data/" .. HISTORY_FILE)
    if M.prev_report and imgui.tree_node("previous session's final snapshot##ifr") then
        for line in M.prev_report:gmatch("[^\n]+") do imgui.text(line) end
        imgui.tree_pop()
    end
    imgui.tree_pop()
end)

re.on_script_reset(function()
    -- mark clean resets so a reset-then-crash isn't misread (file gets overwritten by the next
    -- session's heartbeat anyway; this is just a truthful last word if the reset itself CTDs)
    _note("script reset (clean)")
    _snapshot()
end)

return M
