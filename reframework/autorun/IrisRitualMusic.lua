-- IrisRitualMusic -- our own music during a taming ritual, vanilla BGM muted natively.
--
-- Two halves, both proven separately before this file existed:
--
--  1. THE MUTE. app.SoundBgmManager.OverwriteBgmManager.requestPlay(group, uid) suppresses
--     vanilla BGM (field AND battle). Only 4 of 63 groups take: 23, 24, 28, 33. We use 23.
--     ⚠ requestStop LATCHES -- during the probe scan group 23 stuck on and left the world
--     permanently silent. Teardown is therefore a SWEEP over every id x uid, never a single
--     stop, and it runs on EVERY exit path.
--     ⛔ requestCreateOverwriteBgm is a WALL: its 2nd param is a real requestCallbackFunc
--     delegate and both nil and 0 throw. So vanilla tracks are NOT available to us -- the
--     overwrite system is a mute, not a jukebox. Do not re-attempt.
--
--  2. THE TRACK. Our own Wwise bank, built by rs_tools\horse_wwise\build_ritual_music_bank.py,
--     loaded through the proven ladder from IrisWildHorses/IrisWoodcutting: SoundBankListData
--     USER -> loadContainableUserData on the player's dispatcher -> post via a deserialised
--     trigger, falling back to flipping _EventId on a NATIVE trigger (the rung that actually
--     survives real sessions).
--
-- The ritual seam: IrisTaming's S.mode is local, so IrisTaming publishes it as
-- _G.IrisTamingMode and this module WATCHES it. One watcher beats patching the ten separate
-- places that reset the mode to "idle" -- and it means aborts, deaths and reloads all tear
-- down correctly without me having to find every one of them.

local C = {
    enabled = true,
    bgm_group = 23,           -- proven to mute; 24 / 28 / 33 also work
    bgm_uid = 0,
    ritual = "wolf",          -- which manifest cue set
    cue = "bond",
    start_mode = "context",   -- "context" = whole courting, "yielded" = committed beat only
    debug = true,
}

local MANIFEST_PATH = "IrisRitualMusicManifest.json"
-- How far before a segment ends we post the next one. This MUST match the crossfade baked
-- into the segments by prepare_ritual_music.py, so it is read from the manifest rather than
-- hardcoded -- if the two drift apart you get the "fades and comes back" dip and nothing
-- warns you. The fallback is only for a manifest built before the field existed.
local SEGMENT_LEAD_FALLBACK = 0.55
local LOADED_KEY = "__iris_audio_loaded_ritualmusic"

local REQUEST_SIGNATURE = table.concat({
    "createRequestInfo(soundlib.SoundTriggerInfo, via.GameObject, via.GameObject, ",
    "System.UInt32, System.Boolean, System.Boolean, System.UInt32, ",
    "via.simplewwise.CallbackType, ",
    "System.Action`1<soundlib.SoundManager.RequestInfo>, ",
    "System.Action`1<soundlib.SoundManager.RequestInfo>, ",
    "System.Action`1<soundlib.SoundManager.RequestInfo>, ",
    "System.Action`1<soundlib.SoundManager.RequestInfo>)",
})

-- Native trigger ids usable as posting templates. These live on the PLAYER's own container, so
-- they are always present -- which is the whole point of the template rung.
local NATIVE_TEMPLATE_IDS = {
    170445746, 298825713, 713062116, 1088411087, 1367979266, 1558213002,
}

local S = {
    frame = 0,
    manifest = nil,
    registration = nil,
    triggers_by_event = {},
    template = nil,
    native_template = nil,
    muted = false,
    playing = nil,          -- cue name currently posted
    play_started = 0,
    last_mode = "idle",
    status = "idle",
    log_lines = {},
}

-- Defined AFTER S so it closes over the real local (declaring it above S would silently
-- capture a nil global and always return the fallback).
local function segment_lead()
    local manifest = S.manifest
    local crossfade = manifest and tonumber(manifest.segment_crossfade)
    if not crossfade then return SEGMENT_LEAD_FALLBACK end
    return crossfade + (tonumber(manifest.segment_lead_bias) or 0.05)
end

-- NB: this shadows REFramework's global `log`, so the file logger is reached via _G.log.
local function note(fmt, ...)
    local line = string.format(fmt, ...)
    S.status = line
    table.insert(S.log_lines, 1, line)
    while #S.log_lines > 24 do table.remove(S.log_lines) end
    if C.debug then
        pcall(function() _G.log.info("[IrisRitualMusic] " .. line) end)
    end
end

local function valid(obj)
    if not obj then return false end
    local ok = pcall(function() return obj:get_address() end)
    return ok
end

local function collection_count(collection)
    if not collection then return 0 end
    local n = nil
    pcall(function() n = tonumber(collection:call("get_Count")) end)
    if not n then pcall(function() n = tonumber(collection:get_size()) end) end
    return n or 0
end

-- ---------------------------------------------------------------------------
-- Manifest + bank loading (the proven ladder)
-- ---------------------------------------------------------------------------

local function load_manifest()
    if S.manifest then return S.manifest end
    local text = nil
    pcall(function() text = json.load_file(MANIFEST_PATH) end)
    if type(text) ~= "table" then
        note("manifest %s not found -- build the bank first", MANIFEST_PATH)
        return nil
    end
    S.manifest = text
    return S.manifest
end

local function player_dispatcher()
    local character = nil
    pcall(function()
        local mgr = sdk.get_managed_singleton("app.CharacterManager")
        character = mgr and mgr:call("get_ManualPlayer")
        local inner = character and character:call("get_Character")
        character = inner or character
    end)
    if not character then return nil end
    local wwise = nil
    pcall(function() wwise = character:get_field("<WwiseContainer>k__BackingField") end)
    if not wwise then pcall(function() wwise = character:call("get_WwiseContainer") end) end
    return wwise, character
end

local function create_userdata_any(type_name, path)
    local instance = nil
    for _, candidate in ipairs({ path, path .. ".2" }) do
        pcall(function() instance = sdk.create_userdata(type_name, candidate) end)
        if instance then break end
    end
    if instance then
        pcall(function() instance = instance:add_ref() end)
        pcall(function() instance:add_ref_permanent() end)
    end
    return instance
end

local function audio_prepare()
    local manifest = load_manifest()
    if not manifest then return false end
    local dispatcher, player = player_dispatcher()
    if not dispatcher then
        S.status = "player Wwise dispatcher not ready"
        return false
    end
    local address = nil
    pcall(function() address = tostring(dispatcher:get_address()) end)
    if S.registration and S.registration.address == address then return true end

    local bank = create_userdata_any(
        "soundlib.SoundBankListData", manifest.bank_list_path)
    if not bank then
        note("bank-list USER unresolved (%s) -- is the pak installed?",
            tostring(manifest.bank_list_path))
        return false
    end
    local trigger_lists = {}
    for _, path in ipairs(manifest.trigger_list_paths or {}) do
        local instance = create_userdata_any("soundlib.SoundTriggerInfoListData", path)
        if instance then trigger_lists[#trigger_lists + 1] = instance end
    end

    -- CRASH MITIGATION (AK::WriteBytesCount watch): register with the dispatcher ONCE per
    -- game process. Re-registering the same bank ids on every script reset is the suspected
    -- Wwise bank-state rot. Same guard the horse/cat modules use, separate key.
    if rawget(_G, LOADED_KEY) ~= address then
        local ok, err = pcall(function()
            dispatcher:call(
                "loadContainableUserData(soundlib.SoundContainableUserData)", bank)
            for _, instance in ipairs(trigger_lists) do
                dispatcher:call(
                    "loadContainableUserData(soundlib.SoundContainableUserData)", instance)
            end
        end)
        if not ok then
            note("loadContainableUserData failed: %s", tostring(err))
            return false
        end
        rawset(_G, LOADED_KEY, address)
    end

    S.registration = {
        dispatcher = dispatcher,
        address = address,
        bank = bank,
        trigger_lists = trigger_lists,
        player = player,
        ready_frame = S.frame + 60,
    }
    S.triggers_by_event = {}
    note("bank loaded (%d cue(s)); settling", #(manifest.cues or {}))
    return true
end

local function audio_ready()
    return S.registration ~= nil and S.frame >= (S.registration.ready_frame or 0)
end

-- Custom trigger USER files deserialise EMPTY unreliably, so this is an optimisation only --
-- the template rung below is what actually survives.
local function resolve_triggers()
    local registration, manifest = S.registration, S.manifest
    if not (registration and manifest) then return end
    for _, cue in ipairs(manifest.cues or {}) do
        if not S.triggers_by_event[cue.event_id] then
            for _, instance in ipairs(registration.trigger_lists) do
                local triggers = nil
                pcall(function() triggers = instance._TriggerInfoList end)
                for index = 0, collection_count(triggers) - 1 do
                    local trigger = triggers[index]
                    local id = nil
                    pcall(function() id = tonumber(trigger._TriggerId) end)
                    if id == cue.event_id then
                        S.triggers_by_event[cue.event_id] = trigger
                        if not S.template then S.template = trigger end
                        break
                    end
                end
            end
        end
    end
end

local function find_native_trigger(wwise, trigger_id)
    local function scan(lists)
        for i = 0, collection_count(lists) - 1 do
            local triggers = nil
            pcall(function() triggers = lists[i]._TriggerInfoList end)
            for j = 0, collection_count(triggers) - 1 do
                local trigger = triggers[j]
                local id = nil
                pcall(function() id = tonumber(trigger._TriggerId) end)
                if id == trigger_id then return trigger end
            end
        end
        return nil
    end
    local all = nil
    pcall(function() all = wwise:call("get_AllTriggerInfoListData") end)
    local found = scan(all)
    if found then return found end
    local user_data = nil
    pcall(function() user_data = wwise._UserDataList end)
    return scan(user_data)
end

-- Last resort: ANY real deserialised trigger on the player's own container will do as a
-- posting template -- we only borrow its shape and flip _EventId. Better than depending on
-- the six hardcoded ids above actually being shared onto the player chassis.
local function is_our_event(event_id)
    for _, cue in ipairs((S.manifest or {}).cues or {}) do
        if cue.event_id == event_id then return true end
    end
    return false
end

local function any_native_trigger(wwise)
    local function first_in(lists)
        for i = 0, collection_count(lists) - 1 do
            local triggers = nil
            pcall(function() triggers = lists[i]._TriggerInfoList end)
            for j = 0, collection_count(triggers) - 1 do
                local trigger = triggers[j]
                local event_id = nil
                pcall(function() event_id = tonumber(trigger._EventId) end)
                -- Our own bank is loaded onto this dispatcher, so its triggers show up in
                -- this scan too. Skip them: a "native" template that is really ours defeats
                -- the entire point of this rung.
                if event_id and event_id ~= 0 and not is_our_event(event_id) then
                    return trigger
                end
            end
        end
        return nil
    end
    local all = nil
    pcall(function() all = wwise:call("get_AllTriggerInfoListData") end)
    local found = first_in(all)
    if found then return found end
    local user_data = nil
    pcall(function() user_data = wwise._UserDataList end)
    return first_in(user_data)
end

local function native_template()
    if valid(S.native_template) then return S.native_template end
    local dispatcher = S.registration and S.registration.dispatcher
    if not dispatcher then return nil end
    for _, id in ipairs(NATIVE_TEMPLATE_IDS) do
        local trigger = find_native_trigger(dispatcher, id)
        if trigger then
            S.native_template = trigger
            return trigger
        end
    end
    S.native_template = any_native_trigger(dispatcher)
    return S.native_template
end

local function post_event(event_id, target)
    local registration = S.registration
    if not registration then return false, "no registration" end
    local dispatcher = registration.dispatcher
    if not valid(dispatcher) then
        S.registration = nil
        return false, "dispatcher stale"
    end

    local function build_and_post(trigger, flip_to)
        local original = nil
        if flip_to then
            pcall(function() original = tonumber(trigger._EventId) end)
            if not original then return false, "template event id unreadable" end
        end
        local joint = 0
        pcall(function() joint = tonumber(trigger._OffsetJointHash) or 0 end)
        -- _OffsetJointHash names a joint of the DONOR skeleton; 0 is safe on any chassis.
        local request = nil
        local ok, err = pcall(function()
            if flip_to then trigger._EventId = flip_to end
            request = dispatcher:call(
                REQUEST_SIGNATURE, trigger, target, target, joint,
                false, false, 0, 0, nil, nil, nil, nil)
        end)
        if flip_to then
            local restored = pcall(function() trigger._EventId = original end)
            local now = nil
            pcall(function() now = tonumber(trigger._EventId) end)
            if not restored or now ~= original then
                S.native_template = nil
                S.template = nil
                return false, "template restore failed; retired"
            end
        end
        if not ok then return false, tostring(err) end
        if not request then return false, "createRequestInfo returned nil" end
        pcall(function() request = request:add_ref() end)
        local posted, perr = pcall(function()
            request["<Container>k__BackingField"] = dispatcher
            dispatcher:call("trigger(soundlib.SoundManager.RequestInfo)", request)
        end)
        if not posted then return false, tostring(perr) end
        -- Remember exactly what we posted with; stopTriggered stops by TRIGGER, and on the
        -- native-template rung the trigger's own id is NOT our event id.
        S.playing_trigger = trigger
        S.playing_request = request
        pcall(function() S.playing_trigger_id = tonumber(trigger._TriggerId) end)
        return true
    end

    -- Ladder, in the order that survives real sessions: our own resolved trigger first, then
    -- flipping _EventId on a native one. Report WHICH rung failed -- "it threw" with no rung
    -- named cost us a round already.
    -- ⭐ THE LAW (learned the hard way on the horse/cat banks): the ladder must END on a
    -- FORCED NATIVE trigger. A custom trigger can resolve perfectly and STILL make
    -- createRequestInfo return nil; a native trigger from a container the game itself
    -- populated keeps working. Three distinct rungs, and rung 3 is never a custom trigger.
    local errors = {}

    -- 1. our own resolved trigger, posted as-is
    local direct = S.triggers_by_event[event_id]
    if direct then
        local ok, err = build_and_post(direct, nil)
        if ok then return true, "direct" end
        errors[#errors + 1] = "direct: " .. tostring(err)
    else
        errors[#errors + 1] = "direct: no custom trigger resolved"
    end

    -- 2. our own trigger used as a template (flip _EventId)
    if S.template and S.template ~= direct then
        local ok, err = build_and_post(S.template, event_id)
        if ok then return true, "custom-template" end
        errors[#errors + 1] = "custom-template: " .. tostring(err)
    end

    -- 3. FORCED NATIVE template -- the rung that survives real sessions
    local native = native_template()
    if native then
        local ok, err = build_and_post(native, event_id)
        if ok then return true, "native-template" end
        errors[#errors + 1] = "native-template: " .. tostring(err)
    else
        errors[#errors + 1] = "native-template: none found on the player container"
    end

    return false, table.concat(errors, " | ")
end

local function find_cue(ritual, cue)
    local manifest = S.manifest
    if not manifest then return nil end
    for _, entry in ipairs(manifest.cues or {}) do
        if entry.ritual == ritual and entry.cue == cue then return entry end
    end
    return nil
end

-- SEGMENTED PLAYBACK. Nothing in this engine will stop a sound we posted -- stopTriggered
-- accepts every argument shape and changes nothing, and soundlib.SoundManager (which owns
-- the real stopEvent family) has no reachable instance. So we stop needing a stop: the track
-- ships as 4s segments (wolf_bond00..16) posted back to back, and "stop" means we simply do
-- not post the next one. Worst-case tail is one segment.
-- Prefix match, but the remainder must be DIGITS ONLY -- otherwise asking for "bond" would
-- also swallow the "bondout" tail and play the fade-out as part of the loop.
local function find_sequence(ritual, prefix)
    local manifest = S.manifest
    if not manifest then return {} end
    local list = {}
    for _, entry in ipairs(manifest.cues or {}) do
        if entry.ritual == ritual and entry.cue:sub(1, #prefix) == prefix
            and entry.cue:sub(#prefix + 1):match("^%d+$") then
            list[#list + 1] = entry
        end
    end
    table.sort(list, function(a, b) return a.cue < b.cue end)
    return list
end

local function cue_loops(ritual, prefix)
    local loops = (S.manifest or {}).loops
    if not loops then return false end
    return loops[ritual .. "/" .. prefix] == true
end

-- ---------------------------------------------------------------------------
-- The mute (native overwrite BGM)
-- ---------------------------------------------------------------------------

local function overwrite_manager()
    local bgm = nil
    pcall(function() bgm = sdk.get_managed_singleton("app.SoundBgmManager") end)
    if not bgm then return nil end
    local ow = nil
    pcall(function() ow = bgm:call("get_OverwriteBgm") end)
    return ow
end

local function mute_vanilla()
    if S.muted then return true end
    local ow = overwrite_manager()
    if not ow then return false end
    local ok = pcall(function() ow:call("requestPlay", C.bgm_group, C.bgm_uid) end)
    S.muted = ok
    if ok then note("vanilla BGM muted (group %d)", C.bgm_group) end
    return ok
end

-- ⚠ THE IMPORTANT ONE. A single requestStop demonstrably latches and leaves the player
-- permanently silent, so unmuting is always the full sweep -- cheap, and it cannot miss.
local function unmute_vanilla(reason)
    local ow = overwrite_manager()
    if not ow then S.muted = false return false end
    for id = 0, 63 do
        for uid = 0, 1 do
            pcall(function() ow:call("requestStop", id, uid) end)
        end
    end
    S.muted = false
    -- Reading IsOverwrite in the SAME frame as the stops reports stale true -- the manager
    -- settles in updateOverwriteBgm. Verify a few frames later so the log tells the truth,
    -- and shout if the latch genuinely survived.
    S.verify_frame = S.frame + 15
    note("vanilla BGM restored (%s); verifying...", tostring(reason))
    return true
end

-- Clearing the overwrite is only half of coming back. FieldBgmManager re-evaluates on area
-- change, so after a mute it sits there correct-but-silent until something kicks it. These
-- are the zero-arg re-evaluation entry points on app.SoundBgmManager.
local function kick_field_bgm()
    local bgm = nil
    pcall(function() bgm = sdk.get_managed_singleton("app.SoundBgmManager") end)
    if not bgm then return false end
    local done = {}
    for _, method in ipairs({ "updateArea", "restoreData" }) do
        local ok = pcall(function() bgm:call(method) end)
        done[#done + 1] = method .. "=" .. (ok and "ok" or "failed")
    end
    -- FieldBgm's own updateArea wants the current area id; feed it the one it already holds.
    pcall(function()
        local field = bgm:call("get_FieldBgm")
        if field then
            local area = field:call("get_AreaId")
            if area then field:call("updateArea", area) end
        end
    end)
    note("field BGM kicked (%s)", table.concat(done, ", "))
    return true
end

local function verify_unmute()
    if not S.verify_frame or S.frame < S.verify_frame then return end
    S.verify_frame = nil
    local ow = overwrite_manager()
    local still = nil
    pcall(function() still = ow and ow:call("get_IsOverwrite") end)
    if still == true then
        note("!! LATCH SURVIVED the sweep -- vanilla BGM may still be muted")
    else
        note("teardown verified: IsOverwrite=%s", tostring(still))
    end
    kick_field_bgm()
end

-- ---------------------------------------------------------------------------
-- Public API + the ritual watcher
-- ---------------------------------------------------------------------------

local function start_music(ritual, cue)
    if not C.enabled then return false, "disabled" end
    if not audio_prepare() then return false, S.status end
    if not audio_ready() then
        -- Do not leave a stale status on screen -- say plainly why nothing happened, and
        -- arm a retry so the first click after load still ends up playing.
        S.retry_cue = { ritual = ritual, cue = cue }
        S.status = "bank still settling -- will auto-retry in a moment"
        return false, "settling"
    end
    resolve_triggers()
    local sequence = find_sequence(ritual, cue)
    if #sequence == 0 then
        local single = find_cue(ritual, cue)
        if not single then
            return false, "no cue " .. tostring(ritual) .. "/" .. tostring(cue)
        end
        sequence = { single }
    end
    local entry = sequence[1]
    -- ⚠ createRequestInfo's 2nd/3rd params are via.GameObject. Handing it the Character
    -- (what get_Character returns) throws "Invoke threw an exception" -- the GameObject must
    -- be resolved explicitly. IrisWildHorses never hit this because its target was already
    -- the creature's GameObject.
    local character = S.registration.player
    if not valid(character) then
        local _, player = player_dispatcher()
        character = player
    end
    local target = nil
    pcall(function() target = character:call("get_GameObject") end)
    if not valid(target) then return false, "no player GameObject" end
    mute_vanilla()
    local ok, err = post_event(entry.event_id, target)
    if ok then
        S.playing = entry.name
        S.playing_event = entry.event_id
        S.playing_target = target
        S.play_started = os.clock()
        -- Arm the rest of the sequence. Post the next segment slightly EARLY so the seam
        -- closes rather than gaps -- a small overlap is inaudible on this material, a gap
        -- is not.
        S.sequence = sequence
        S.sequence_index = 1
        S.sequence_prefix = cue
        S.sequence_loops = cue_loops(ritual, cue)
        S.outro_entry = (find_sequence(ritual, cue .. "out") or {})[1]
        S.pending_stop = nil
        S.outro_until = nil
        S.sequence_next_at = os.clock() + (tonumber(entry.seconds) or 4.0) - segment_lead()
        note("playing %s [%d segment(s), event %d]", entry.name, #sequence, entry.event_id)
    else
        note("post FAILED for %s: %s", entry.name, tostring(err))
        -- Never leave the world muted because our own track failed to start.
        unmute_vanilla("post failed")
    end
    return ok, err
end

-- Stopping our OWN cue. app.WwiseContainerApp declared no stop methods, but get_methods()
-- only reports DECLARED ones -- soundlib.SoundContainer (its likely base) has stopTriggered,
-- and inherited methods are still callable. So: walk the type chain, find everything named
-- stop*, log it once, and try each with the argument shapes that fit. Self-diagnosing, so one
-- round tells us which route exists instead of me guessing blind.
local function stop_methods_on(obj)
    local found = {}
    local td = nil
    pcall(function() td = obj:get_type_definition() end)
    local seen = {}
    while td do
        local name = "?"
        pcall(function() name = tostring(td:get_full_name()) end)
        if seen[name] then break end
        seen[name] = true
        local methods = nil
        pcall(function() methods = td:get_methods() end)
        for _, m in ipairs(methods or {}) do
            local mname = nil
            pcall(function() mname = m:get_name() end)
            if mname and mname:lower():find("stop", 1, true) then
                local params = "?"
                pcall(function() params = tostring(m:get_num_params()) end)
                -- Param TYPES, not just the count -- an arg-shape guess is what failed last
                -- round, and the count alone cannot tell me the shape.
                local sig = nil
                pcall(function()
                    local types = m:get_param_types()
                    if types then
                        local parts = {}
                        for _, t in ipairs(types) do
                            parts[#parts + 1] = tostring(t:get_full_name())
                        end
                        sig = table.concat(parts, ", ")
                    end
                end)
                found[#found + 1] = {
                    name = mname, argc = tonumber(params) or -1,
                    owner = name, sig = sig or "<types unavailable>",
                }
            end
        end
        local base = nil
        pcall(function() base = td:get_parent_type() end)
        td = base
    end
    return found
end

local function stop_our_cue(event_id, target)
    local registration = S.registration
    if not registration then return false, "no registration" end
    local dispatcher = registration.dispatcher
    if not valid(dispatcher) then return false, "dispatcher stale" end

    local found = S.stop_methods
    if not found then
        found = stop_methods_on(dispatcher)
        S.stop_methods = found
        if #found == 0 then
            note("no stop* methods anywhere on the dispatcher type chain")
        end
        for _, m in ipairs(found) do
            note("stop candidate: %s(%s) on %s", m.name, m.sig, m.owner)
        end
    end
    local exists = {}
    for _, m in ipairs(found) do exists[m.name] = true end

    -- ⛔ pcall succeeding does NOT mean the method exists -- dispatcher:call on an unknown
    -- name returned "ok" last round and I reported a stop that never happened. Only attempt
    -- names that the type-chain walk actually found.
    -- REAL signature, from the type-chain walk:
    --   stopTriggered(System.UInt32, via.GameObject, System.UInt32)
    -- i.e. (id, gameObject, fadeMs). Last round I passed (gameObject, id, 0) -- REF coerced
    -- it enough not to throw, so it reported "accepted" for a call that did nothing. The
    -- UInt32 comes FIRST.
    --
    -- Which id? We posted through a native template with _EventId flipped to ours, so the
    -- running Wwise event is OUR event id, while the trigger's own id is the native one. Try
    -- the event id first, then the trigger id, and fire ALL of them rather than stopping at
    -- the first non-throw -- "did not throw" has already proved a bad success signal here.
    local trigger_id = S.playing_trigger_id
    local ids = {}
    if event_id then ids[#ids + 1] = { event_id, "event id" } end
    if trigger_id and trigger_id ~= event_id then
        ids[#ids + 1] = { trigger_id, "trigger id" }
    end
    if not exists["stopTriggered"] then
        return false, "stopTriggered not present on the type chain"
    end
    local attempted = {}
    for _, entry in ipairs(ids) do
        for _, fade in ipairs({ 0, 500 }) do
            local ok, err = pcall(function()
                dispatcher:call("stopTriggered", entry[1], target, fade)
            end)
            attempted[#attempted + 1] = string.format("%s=%d fade=%d %s",
                entry[2], entry[1], fade, ok and "ok" or "ERR")
            if not ok then S.last_stop_err = tostring(err) end
        end
    end
    note("stopTriggered tried: %s", table.concat(attempted, ", "))
    return true, "stopTriggered swept"
end

-- Drives the segment chain. Called every frame; posts the next piece just before the current
-- one runs out, and does nothing at all once the sequence is cleared -- which is exactly what
-- "stop" means here.
local function pump_sequence()
    -- The outro is playing: once it has run its length, hand the music back.
    if S.outro_until then
        if os.clock() >= S.outro_until then
            S.outro_until = nil
            S.playing = nil
            if S.muted then unmute_vanilla(S.outro_reason or "cue faded out") end
        end
        return
    end
    if not S.sequence then return end
    if os.clock() < (S.sequence_next_at or 0) then return end

    -- A stop was requested. Rather than cut, we let the current segment reach its normal
    -- crossfade point and post the OUTRO in place of the next segment -- so it fades out
    -- through exactly the same join machinery as any other transition.
    if S.pending_stop then
        local tail = S.outro_entry
        if tail then
            local target = S.playing_target
            local ok = post_event(tail.event_id, target)
            S.sequence = nil
            S.sequence_next_at = nil
            S.pending_stop = nil
            if ok then
                S.outro_until = os.clock() + (tonumber(tail.seconds) or 2.0)
                S.playing = tail.name
                note("fading out (%.1fs)", tonumber(tail.seconds) or 2.0)
                return
            end
        end
        -- No outro available: fall back to a hard stop.
        S.sequence = nil
        S.pending_stop = nil
        S.playing = nil
        if S.muted then unmute_vanilla(S.outro_reason or "stopped") end
        return
    end

    local nxt = S.sequence_index + 1
    local entry = S.sequence[nxt]
    if not entry and S.sequence_loops then
        -- Seamless wrap: segment 0 carries a fade-in over the master's tail, so going back
        -- to the top is just another crossfade.
        nxt = 1
        entry = S.sequence[1]
        note("cue looping")
    end
    if not entry then
        note("cue finished (%d segments)", S.sequence_index)
        S.sequence = nil
        S.playing = nil
        return
    end
    local target = S.playing_target
    if not valid(target) then
        local _, character = player_dispatcher()
        pcall(function() target = character and character:call("get_GameObject") end)
        S.playing_target = target
    end
    local ok, err = post_event(entry.event_id, target)
    if not ok then
        note("segment %s failed: %s -- ending cue", entry.name, tostring(err))
        S.sequence = nil
        S.playing = nil
        return
    end
    S.sequence_index = nxt
    S.playing = entry.name
    S.playing_event = entry.event_id
    S.sequence_next_at = os.clock() + (tonumber(entry.seconds) or 4.0) - segment_lead()
end

local function stop_music(reason)
    -- ⭐ THE POINT OF SEGMENTING: stopping is just not posting the next piece. No engine stop
    -- call involved, so none of the stopTriggered dead ends matter.
    if S.outro_until then return end          -- already fading; let it finish
    if S.sequence and S.outro_entry then
        -- Graceful: request the fade at the next crossfade point. Costs up to one segment of
        -- music plus the outro, and unmuting waits for the fade so vanilla BGM does not
        -- barge in underneath it.
        S.pending_stop = true
        S.outro_reason = reason
        note("stop requested -- fading at the next segment join")
        return
    end
    local was = S.sequence and S.sequence_index or nil
    S.sequence = nil
    S.sequence_next_at = nil
    S.playing = nil
    S.playing_event = nil
    if was then note("cue stopped after segment %d", was) end
    if S.muted then unmute_vanilla(reason) end
end

_G.IrisRitualMusic = {
    play = function(ritual, cue) return start_music(ritual or C.ritual, cue or C.cue) end,
    stop = function(reason) stop_music(reason or "api") end,
    is_playing = function() return S.playing ~= nil end,
    status = function() return S.status end,
}

-- IrisTaming publishes S.mode here. Watching one value beats patching the ten separate places
-- that reset it -- every abort, death and reload path tears down for free.
local function taming_mode()
    local mode = rawget(_G, "IrisTamingMode")
    if type(mode) ~= "string" then return "idle" end
    return mode
end

local function in_ritual(mode)
    if C.start_mode == "yielded" then
        return mode == "yielded" or mode == "trusting"
    end
    return mode == "context" or mode == "yielded" or mode == "trusting"
end

re.on_frame(function()
    S.frame = S.frame + 1
    verify_unmute()
    pump_sequence()
    if not C.enabled then
        if S.muted then unmute_vanilla("module disabled") end
        return
    end
    -- A click made before the bank settled should still end up playing, not silently drop.
    if S.retry_cue and audio_ready() then
        local pending = S.retry_cue
        S.retry_cue = nil
        start_music(pending.ritual, pending.cue)
    end
    local mode = taming_mode()
    local now_in, was_in = in_ritual(mode), in_ritual(S.last_mode)
    if now_in and not was_in then
        start_music(C.ritual, C.cue)
    elseif was_in and not now_in then
        stop_music("ritual ended (" .. tostring(mode) .. ")")
    end
    S.last_mode = mode
end)

re.on_script_reset(function()
    -- A reload must never strand the player in silence.
    pcall(function() unmute_vanilla("script reset") end)
end)

re.on_draw_ui(function()
    if not imgui.tree_node("Iris Ritual Music") then return end
    local chg, val = imgui.checkbox("enabled", C.enabled)
    if chg then C.enabled = val end
    imgui.text("taming mode: " .. taming_mode()
        .. (in_ritual(taming_mode()) and "   [IN RITUAL]" or ""))
    imgui.text("muted: " .. tostring(S.muted)
        .. "   playing: " .. tostring(S.playing or "-"))
    if S.playing then
        imgui.text(string.format("elapsed: %.1fs", os.clock() - S.play_started))
    end
    imgui.text("status: " .. tostring(S.status))
    imgui.text("")
    if imgui.button("TEST: play cue now") then start_music(C.ritual, C.cue) end
    imgui.same_line()
    if imgui.button("TEST: stop + restore BGM") then stop_music("manual") end
    imgui.same_line()
    if imgui.button("PANIC: restore BGM") then unmute_vanilla("panic") end
    imgui.same_line()
    if imgui.button("KICK field BGM") then kick_field_bgm() end
    local mchg, mval = imgui.checkbox("start at committed beat only (yielded)",
        C.start_mode == "yielded")
    if mchg then C.start_mode = mval and "yielded" or "context" end
    imgui.text("")
    for _, line in ipairs(S.log_lines) do imgui.text("  " .. line) end
    imgui.tree_pop()
end)

pcall(function() note("loaded") end)
