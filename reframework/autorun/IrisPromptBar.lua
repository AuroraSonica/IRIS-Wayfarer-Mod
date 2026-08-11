-- ═════════════════════════════════════════════════════════════════════════════════════
-- IrisPromptBar.lua — make the GAME'S OWN button panel say what our action is.
--
-- Aurora (08-09): "it says 'B Dash' but when next to an empty farmplot it should change to
-- 'B Sow' - if next to the weapon plaque it should say 'B Mount', if next to the cook pot
-- it should say 'B Cook'... we already do this UI change for the griffin/horse controls."
--
-- Right: the recipe exists (learned by READING Nick's Puppeteer, never edited —
-- dd2-rename-button-prompts) and has only ever been used for the griffin. This makes it a
-- SHARED SERVICE so every IRIS module gets a native-looking prompt for free.
--
--   _G.IrisPrompt.set(owner, "Sow")   -- publish; highest priority wins
--   _G.IrisPrompt.clear(owner)        -- stop offering
--
-- ⛔⛔ LAWS (each one is somebody's crash or wasted evening)
--   • **RE-ASSERT EVERY FRAME.** The game rewrites these labels itself whenever its prompt
--     set changes, so a one-shot write is visibly overwritten a moment later.
--   • ⛔⛔⛔ **NEVER `set_PlayState`.** A slot the game is not offering reports
--     `get_Visible()==true` but `PlayState == "DISABLE_HIDETXT"`; harvesting a healthy
--     panel's PlayState onto it DOES relabel it and CRASHES THE GAME — two clean CTDs,
--     each within a second of the first force. Reads, `set_Message` and `set_Visible` are
--     tolerated; PlayState writes are not.
--   • Guard on `get_DrawSelf()` — the panel does not exist in every scene.
--   • ⛔ **THE gsub TRAP** (cost four rounds): `obj:call(root, path:gsub(...))` passes
--     gsub's SECOND return (the count) as an extra argument and the call silently resolves
--     nil. Always parenthesise: `(path:gsub(...))`.
--
-- ⚠ WE ONLY RELABEL A SLOT THE GAME IS ALREADY SHOWING. If DD2 is not offering B in this
--   context, the slot is withheld and no amount of writing brings it back (that is the
--   PlayState wall above). Our own world-space labels remain the fallback.
-- ═════════════════════════════════════════════════════════════════════════════════════

local M = {
    enabled = true,
    slot    = "PNL_R02",   -- B. (R01=RB, R03=A, R00=RT, L03=X, L02=Y, L01=LB, L00=LT)
    log     = true,
}

local LOG = "IrisPromptBar.log"
local function _log(s)
    if not M.log then return end
    pcall(function()
        local f = io.open(LOG, "a")
        if f then f:write(os.date("[%H:%M:%S] ") .. tostring(s) .. "\n"); f:close() end
    end)
end

-- ── the registry. Modules publish here; highest priority wins a contested frame. ──────
-- ⭐⭐ ENTRIES EXPIRE. Publishers call `set` every frame while their action is available and
--   simply STOP when it is not — no clear required. This matters because the natural place
--   to publish is inside a module's draw, and a draw that early-returns (walked away, menu
--   open, feature disabled) would never reach a `clear`, leaving the panel permanently
--   advertising an action that is not on offer. Fire-and-forget beats "remember to tidy up",
--   because the tidy-up is exactly what gets missed.
local TTL = 1.0       -- generous: the plaque only re-scans every 0.3s
local slots = {}      -- [owner] = { text = , prio = , dist = , at = }
_G.IrisPrompt = _G.IrisPrompt or {}
_G.IrisPrompt.set = function(owner, text, prio, dist)
    if not owner then return end
    if text == nil or text == "" then slots[owner] = nil; return end
    slots[owner] = { text = tostring(text), prio = tonumber(prio) or 0,
                     dist = tonumber(dist) or 1e9, at = os.clock() }
end
_G.IrisPrompt.clear = function(owner) if owner then slots[owner] = nil end end

-- ⭐⭐ ONE ACTION AT A TIME — THE NEAREST ONE (Aurora 08-09: "if I stand near the weapon
--   mount and press B, sometimes because the cookpot is quite close it'll open the cooking
--   menu, then when I leave the menu the weapon mount interaction will happen"). Every
--   module read the button independently, so overlapping reaches fired BOTH, and the queued
--   one went off after the menu closed.
--   ⇒ NEAREST WINS, priority only as a tie-break inside 0.3m (so a deliberate walk-up beats
--   an ambient bed you happen to be the same distance from). Modules must ask `owner()`
--   before acting on the press; publishing alone no longer entitles anything to fire.
_G.IrisPrompt.winner = function()
    local best, bd, bp, now = nil, 1e9, -1e9, os.clock()
    for owner, v in pairs(slots) do
        if now - (v.at or 0) > TTL then
            slots[owner] = nil                                    -- gone stale
        else
            local d = v.dist or 1e9
            if d < bd - 0.3 or (math.abs(d - bd) <= 0.3 and v.prio > bp) then
                best, bd, bp = owner, math.min(d, bd), v.prio
            end
        end
    end
    return best
end
_G.IrisPrompt.owner = _G.IrisPrompt.winner
_G.IrisPrompt.current = function()
    local w = _G.IrisPrompt.winner()
    return w and slots[w] and slots[w].text or nil
end

-- ⭐⭐ AND STAND DOWN FOR THE GAME'S OWN INTERACT (Aurora: "I tried to claim the sword from
--   the mount but sat down in a chair at the same time"). That chair is a NATIVE interact
--   from the hidden seat, on the same physical button — we cannot arbitrate inside DD2's
--   interact system (register() is a CTD, proven tonight), but we CAN ask it whether it is
--   currently offering something: `hasHighestPriorityObjectForPlayer()` is a READ, and reads
--   on InteractManager were exercised repeatedly tonight with no ill effect.
--   ⇒ if the game has its own prompt up, every IRIS action defers to it. The game's
--   interact is always the more "expected" one to the player.
local nb = { at = 0, v = false }
_G.IrisPrompt.native_busy = function()
    local now = os.clock()
    if now - nb.at < 0.15 then return nb.v end   -- cheap cache; this is read from several modules
    nb.at = now
    local v = false
    pcall(function()
        local im = sdk.get_managed_singleton("app.InteractManager")
        if im and im:call("hasHighestPriorityObjectForPlayer") == true then v = true end
    end)
    nb.v = v
    return v
end

-- ── ⭐ SHARED PAD RESOLVER. One place, logged once, so every module agrees on what "B" is.
--    ⛔ `via.hid.GamePadButton` genuinely has no field called "B" — farming's silent
--    fallback chain walked past it to RDown (Xbox A) and then advertised "B" on screen for
--    weeks. Resolve by trying real names, LOG which one won, and log the whole field list
--    once so a wrong guess is visible instead of invisible.
local padnames, padlogged = nil, false
_G.IrisPad = _G.IrisPad or {}
_G.IrisPad.bit = function(...)
    if not padnames then
        padnames = {}
        pcall(function()
            local t = sdk.find_type_definition("via.hid.GamePadButton")
            for _, f in ipairs(t:get_fields()) do
                pcall(function() padnames[f:get_name()] = f:get_data(nil) end)
            end
        end)
        if not padlogged then
            padlogged = true
            local all = {}
            for k, v in pairs(padnames) do all[#all + 1] = k .. "=" .. tostring(v) end
            table.sort(all)
            _log("via.hid.GamePadButton fields: " .. table.concat(all, ", "))
        end
    end
    for _, n in ipairs({ ... }) do
        if padnames[n] then
            _log("pad resolve: '" .. n .. "' = " .. tostring(padnames[n]))
            return padnames[n], n
        end
    end
    _log("⛔ pad resolve FAILED for: " .. table.concat({ ... }, ", ") .. " - none of those fields exist")
    return 0, nil
end
_G.IrisPad.down = function(bit)
    if not bit or bit == 0 then return false end
    local d = false
    pcall(function()
        -- ⛔ via.hid.GamePad is a NATIVE singleton. get_managed_singleton returns nil and the
        --   pcall eats it, which is exactly how the plaque's A button read false all evening.
        local pm = sdk.get_native_singleton("via.hid.GamePad")
        local dev = pm and sdk.call_native_func(pm, sdk.find_type_definition("via.hid.GamePad"),
                                                "get_MergedDevice")
        if not dev then return end
        local b = math.floor(dev:call("get_Button") or 0)
        local m = math.floor(bit)
        d = (b & m) == m
    end)
    return d
end

-- ── writing the label ────────────────────────────────────────────────────────────────
local getobj, gui = nil, { warned = false }
pcall(function()
    getobj = sdk.find_type_definition("via.gui.Control"):get_method("getObject(System.String)")
end)

local function _panel_text(txt)
    if not getobj then return false end
    local ok = false
    pcall(function()
        local scene = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),
                      sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        if not scene then return end
        local ui = scene:call("findGameObject(System.String)", "ui010201")
        if not ui then return end
        if ui:call("get_DrawSelf") ~= true then return end      -- never poke a hidden panel
        local base = ui:call("getComponent(System.Type)", sdk.typeof("app.GUIBase"))
        local root = base and base:get_field("Root")
        if not root then return end
        -- ⛔ parenthesised: an unparenthesised gsub would pass its count as an extra arg
        local path = (M.slot .. "/PNL_txt/mtx_00")
        local node = getobj:call(root, "PNL_top/" .. path)
        if not node then return end
        node:call("set_Message", txt)
        ok = true
    end)
    return ok
end

-- ⛔⛔⛔ **GAME THREAD, NOT THE RENDER THREAD.** v1 ran this from `re.on_frame` and CRASHED
--   the game while stood at farmland (Aurora 08-09). `re.on_frame` is the render/present
--   thread; walking the scene, resolving ui010201, fetching components and writing messages
--   there — every frame — is the documented way to fault (the prop-spawn lab's THREAD LAW).
--   The griffin's own relabel has always used LateUpdateBehavior
--   (`GriffinRideProbe - Iris.lua:14630` -> `griffin_ride_hud_tick` at :14652), and
--   dd2-rename-button-prompts says so in as many words: "Ours runs in the LATE hook."
--   I had read that note the same day and still used the wrong hook.
-- ⭐ LATE in the frame, every frame: the game rewrites its own labels whenever its prompt
--   set changes, so a one-shot write is visibly overwritten a moment later.
-- ⛔⛔ **DO NOT THROTTLE THIS.** I added a 0.1s throttle "for efficiency" and it FLICKERED
--   between "Dash" and "Water" (Aurora 08-09) — because the game rewrites the label back in
--   every gap we leave. That is the entire reason the law says re-assert EVERY FRAME, and I
--   optimised away the one thing making it work. LateUpdateBehavior IS the game thread, so
--   every frame is both correct and safe here; the griffin has done exactly this for months
--   ("re-assert prompt labels every frame", GriffinRideProbe - Iris.lua:14652).
--   ⭐ The general shape of the mistake: an optimisation that introduces a GAP into a
--   contested resource always loses the contest.
re.on_application_entry("LateUpdateBehavior", function()
    if M.enabled == false then return end
    -- if the GAME is offering its own interact, leave its label alone entirely
    if _G.IrisPrompt.native_busy() then return end
    local t = _G.IrisPrompt.current()
    if not t then return end
    local ok = _panel_text(t)
    if not ok and not gui.warned then
        gui.warned = true
        _log("could not write the prompt slot (panel hidden, or the game is not offering "
             .. M.slot .. " in this context - a withheld slot cannot be forced; see the "
             .. "PlayState wall). Falling back to our own world labels.")
    end
end)

re.on_script_reset(function() slots = {} end)

re.on_draw_ui(function()
    if not imgui.tree_node("IRIS PROMPT BAR (relabel the game's own button hints)") then return end
    imgui.text("Modules publish an action; the game's button panel shows it.")
    local cur = _G.IrisPrompt.current()
    imgui.text("currently offering: " .. (cur and ("'" .. cur .. "'") or "nothing"))
    local n = 0
    for owner, v in pairs(slots) do
        n = n + 1
        imgui.text(string.format("   %-18s '%s'  (prio %d)", tostring(owner), v.text, v.prio))
    end
    if n == 0 then imgui.text("   (no module is offering an action right now)") end
    local c
    c, M.enabled = imgui.checkbox("enabled", M.enabled ~= false)
    local sc, sv = imgui.input_text("panel slot (PNL_R02 = B, PNL_R03 = A)", M.slot)
    if sc and sv ~= "" then M.slot = sv end
    c, M.log = imgui.checkbox("write the log", M.log)
    imgui.tree_pop()
end)

_log("IrisPromptBar loaded - slot " .. tostring(M.slot))
