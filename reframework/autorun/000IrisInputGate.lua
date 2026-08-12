-- ═══════════════════════════════════════════════════════════════════════════
-- IRIS INPUT GATE  (2026-08-09)
--
-- Aurora: "hotkeys keep firing while I'm typing in a textbox in the REFramework
-- window -- creature customisation opens, a griffin gets summoned, etc."
--
-- REFramework does NOT stop mods reading the keyboard while its overlay is up:
-- on_message writes the raw key array before any capture check, so every
-- is_key_down() poll still sees the letters you are typing into imgui. There is
-- no engine-side lever for this -- the only fix is for each mod to ask first.
-- This file is the ONE place that answers "may a gameplay hotkey fire now?".
--
-- Loads first (000 prefix) so every IRIS module can call it at frame time.
--
-- BLOCKED WHILE:
--   * the REFramework overlay is open        -- reframework:is_drawing_ui()
--   * any RiftSpeak message box is open      -- _G.RiftSpeak_PromptOpen
--   * a cooperating mod owns the keyboard    -- _G.RiftSpeak_ExternalTyping
--   * an IRIS key-rebind capture is armed    -- _G.IrisKeyCaptureActive
--     (set that one EVERY FRAME your capture is armed -- the gate clears it at the
--      top of each frame, so an abandoned capture can never deadlock every hotkey)
--
-- ⛔ NOT blocked -- the readers that OWN the typing: rebind pickers, and a text
--    box's own Enter/Esc. Those run ONLY while the overlay is open, so gating
--    them would make rebinding and confirming impossible. They call
--    iris_kb_raw() instead. If you add a new "press a key to bind" flow, use
--    iris_kb_raw or it will never see a key.
--
-- ESCAPE HATCH: _G.IrisInputGateOff = true  (set it from Console.lua) turns the
-- whole gate off for the session if it ever blocks something it shouldn't.
-- ═══════════════════════════════════════════════════════════════════════════

-- UNGATED keyboard read. Only for rebind pickers and a text box's own keys.
function iris_kb_raw(vk)
    local down = false
    pcall(function() down = reframework:is_key_down(vk) == true end)
    return down
end

function iris_input_blocked()
    if _G.IrisInputGateOff == true then return false end
    if _G.RiftSpeak_PromptOpen == true then return true end
    if _G.RiftSpeak_ExternalTyping == true then return true end
    if _G.RiftSpeakPromptOpen == true then return true end   -- legacy spelling: three IRIS files shipped this one
    if _G.IrisKeyCaptureActive == true then return true end
    if _G.IrisTypingActive == true then return true end      -- 08-12: the IRIS naming card (d2d, not
                                                             -- the overlay) -- typing "O" must not open
                                                             -- the Stable Screen. Re-assert every frame
                                                             -- while the card is up; cleared below.
    local ui = false
    pcall(function() ui = reframework:is_drawing_ui() == true end)
    return ui
end

-- THE gated read every IRIS hotkey goes through. Defined UNCONDITIONALLY and first,
-- so iris_kb is guaranteed to exist before the first frame even if taming/griffin
-- never load -- callers rely on that and call it bare. IrisTaming redefines it later
-- with an identical body (it owns the canonical copy); either way the gate applies.
function iris_kb(vk)
    if iris_input_blocked() then return false end
    return iris_kb_raw(vk)
end

-- A rebind capture that gets abandoned (panel closed mid-pick) must not leave every
-- hotkey in the stack dead. This file loads first, so this handler runs first: the flag
-- only survives if the capture re-asserts it on the frame it is actually armed.
re.on_frame(function()
    _G.IrisKeyCaptureActive = false
    _G.IrisTypingActive = false   -- same law: only a card that is REALLY up re-asserts it
end)
