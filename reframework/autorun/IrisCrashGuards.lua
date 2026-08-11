-- IrisCrashGuards.lua -- airbags for known NATIVE crash paths (not our code: the game's own AI
-- dereferencing bad pointers). Each guard is tiny, targeted at a crash we hold a dump for, and
-- does nothing at all on the healthy path.
--
-- GUARD 1 (2026-08-06, hit twice): app.Ch251.update -> Ch251CheckGender.onUpdateCheckGender ->
-- setNextTarget -> app.Human.get_IsFemaleLooks = ACCESS VIOLATION. The ogre picks victims by
-- gender and calls get_IsFemaleLooks on a candidate whose Human is null/gone (first occurrence:
-- a destroy()'d evictee's dangling target-list entry; second: mid-flight roaming, vector unknown
-- -- a non-Human candidate in a modded scene). A null `this` at the gate = skip the call and
-- answer false ("not female"); the ogre just picks someone else.

-- GUARD 2 (2026-08-07, one dump): app.DecisionEvaluationModuleLateUpdator.lateUpdate =
-- ACCESS VIOLATION (null in RDX) mid-pounce-skid -- the AI decision-evaluation pipeline
-- evaluated a null/dead module (either the griffin's window-disabled AIDecisionMaker or the
-- goblin dying from the strike in the same frame; same family as Guard 1's dying-target AV).
-- Null `this` at the gate -> skip that late-update tick; the evaluator resumes next frame.

local guard_hits = 0

pcall(function()
    local td = sdk.find_type_definition("app.Human")
    local m = td and td:get_method("get_IsFemaleLooks")
    if not m then return end
    local skipped = false
    sdk.hook(m,
        function(args)
            skipped = false
            -- raw-pointer null test (the guard law -- see Guard 2's comment)
            local ok, p = pcall(sdk.to_int64, args[2])
            if ok and p == 0 then
                skipped = true
                guard_hits = guard_hits + 1
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
        end,
        function(retval)
            if skipped then return sdk.to_ptr(0) end   -- "not female looks"
            return retval
        end)
end)

-- ⛔⛔ GUARD 2 REMOVED PERMANENTLY (2026-08-07 20:23: with the hook armed the game HARD-DIED
-- ~10s after mount -- log stops mid-line, NO exception, NO dump: REFramework's handler never
-- ran. The 20:05 stack shows DecisionEvaluationModuleLateUpdator.lateUpdate executing on a
-- THREAD-POOL thread (BaseThreadInitThunk root) -- a Lua hook on a job-thread method is a
-- known process-killer (Lua state is not thread-safe). LAW: NEVER sdk.hook a method whose
-- crash stack roots in a worker thread; airbags are for MAIN-THREAD methods only (Guard 1's
-- Ch251.update stack is main-loop -- that one stays).

re.on_draw_ui(function()
    if imgui.tree_node("Iris Crash Guards") then
        imgui.text("get_IsFemaleLooks null-this airbag: " ..
            (guard_hits > 0 and (tostring(guard_hits) .. " crash(es) prevented") or "armed, no hits"))
        imgui.text("DecisionEvaluation airbag: REMOVED (job-thread hook = process killer)")
        imgui.tree_pop()
    end
end)
