-- I.R.I.S. griffin -- the stable: companion roster, souls and taming.
--
-- The persistent side of a companion. The stable file is the roster (who you own, their species,
-- name, gender and parked spot); the 'soul' is what survives a script reset so a body can be
-- reclaimed or re-minted. Taming is here too, since it is what puts a new record in the roster.

local ctx = require("IrisGriffin.context")
local C, S = ctx.C, ctx.S
local MOD                              = ctx.MOD
local mounts                           = ctx.mounts
local char_go                          = ctx.char_go
local clear_griffin_hate               = ctx.clear_griffin_hate
local clear_griffin_targets            = ctx.clear_griffin_targets
local get_player                       = ctx.get_player
local go_name                          = ctx.go_name
local is_dead                          = ctx.is_dead
local make_vec3                        = ctx.make_vec3
local register_griffin                 = ctx.register_griffin
local set_character_transform          = ctx.set_character_transform
local set_think_stop                   = ctx.set_think_stop
local set_transform                    = ctx.set_transform
local singleton                        = ctx.singleton
local spawn_griffin                    = ctx.spawn_griffin
local status                           = ctx.status
local stop_navigation                  = ctx.stop_navigation
local transform_pos                    = ctx.transform_pos
local yaw_from_transform               = ctx.yaw_from_transform

function griffin_stable_read_live_hp(ch)
    if not ch then return nil, nil, nil end
    local hc = nil
    pcall(function()
        local addr = nil
        local go = char_go(ch)
        if go then addr = go:get_address() end
        if griffin_downed_hit_controller then
            hc = griffin_downed_hit_controller(ch, addr)
        end
        if not hc then hc = griffin_target_hit_controller(ch) end
    end)
    if not hc then return nil, nil, nil end
    local hp, maxhp = nil, nil
    pcall(function() hp = tonumber(griffin_hp_from_component(hc)) end)
    pcall(function() maxhp = tonumber(griffin_hp_max_from_component(hc)) end)
    return hp, maxhp, hc
end

function griffin_stable_bank_live_hp(comp, ch)
    comp = comp or griffin_stable_active()
    ch = ch or S.griffin
    if not (comp and ch) then return false end
    local hp, maxhp = griffin_stable_read_live_hp(ch)
    if not (hp and maxhp and maxhp > 0.0) then return false end
    comp.hp = math.max(0.0, math.min(maxhp, hp))
    comp.hp_max = maxhp
    comp.hp_saved_at = os.time()
    return true
end

function griffin_stable_begin_rest(comp)
    comp = comp or griffin_stable_active()
    if not comp then return false end
    local now = os.time()
    comp.away_since = now
    comp.hp_rest_at = now
    griffin_stable_write()
    return true
end

function griffin_stable_apply_elapsed_rest(comp)
    if not (comp and tonumber(comp.away_since)) then return false end
    local now = os.time()
    local since = tonumber(comp.hp_rest_at) or tonumber(comp.away_since) or now
    local hp, maxhp = tonumber(comp.hp), tonumber(comp.hp_max)
    if hp and maxhp and maxhp > 0.0 then
        local rate = math.max(0.0,
            tonumber(C.route3_stable_regen_hp_per_sec) or 1.0)
        hp = math.min(maxhp, math.max(0.0, hp) + math.max(0, now - since) * rate)
        comp.hp = hp
    end
    comp.hp_rest_at = now
    comp.away_since = nil
    return hp ~= nil
end

function griffin_stable_prepare_summon(ch)
    local comp = griffin_stable_active()
    if not (comp and ch) then return false end
    local was_away = tonumber(comp.away_since) ~= nil
    local full_heal = comp.full_heal_pending == true
    -- register_griffin also handles newly tamed wild bodies and diagnostic
    -- spawns. Only a record explicitly marked away by dismissal owns a saved-HP
    -- handover; otherwise we could stamp an old companion's HP onto a new tame.
    if not was_away and not full_heal then return false end
    if was_away then griffin_stable_apply_elapsed_rest(comp) end
    if full_heal then
        local _, live_max = griffin_stable_read_live_hp(ch)
        if live_max and live_max > 0.0 then
            comp.hp = live_max
            comp.hp_max = live_max
            comp.full_heal_pending = nil
        end
    end
    local want = tonumber(comp.hp)
    local maxhp = tonumber(comp.hp_max)
    if not (want and maxhp and maxhp > 0.0) then return false end
    want = math.max(1.0, math.min(maxhp, want))
    -- A freshly minted body must not inherit an address-reused hp_source entry
    -- from the destroyed body. Start with its own canonical controller.
    local hc = nil
    pcall(function() hc = griffin_target_hit_controller(ch) end)
    if hc then pcall(function() griffin_downed_set_hp(hc, want) end) end
    -- Spawned characters finish initialising over several frames and can restore
    -- their template HP during that window. Reassert only an upper bound: damage
    -- taken during construction is never healed back up by this handover.
    S.stable_hp_restore = {
        ch = ch, hc = hc, want = want,
        until_clock = os.clock() + 2.0,
    }
    griffin_stable_write()
    return true
end

function griffin_stable_hp_restore_tick()
    local q = S.stable_hp_restore
    if type(q) ~= "table" then return end
    local now = os.clock()
    if now >= (tonumber(q.until_clock) or 0.0) then
        S.stable_hp_restore = nil
        return
    end
    pcall(function()
        local hc = q.hc
        local hp = nil
        pcall(function() hp = hc and tonumber(griffin_hp_from_component(hc)) end)
        if not hc then
            local ignored = nil
            hp, ignored, hc = griffin_stable_read_live_hp(q.ch)
        end
        local want = tonumber(q.want)
        -- 08-12 (Tails summoned at 99,990/100,000): the drop-in LANDING costs a few HP
        -- inside this very construction window, and the old upper-bound-only clamp
        -- refused to heal it back. The window is 2s -- nothing legitimate hurts a
        -- fresh summon in it -- so hold the handover value from BOTH sides.
        if hc and hp and want and math.abs(hp - want) > 0.05 then
            griffin_downed_set_hp(hc, want)
        end
    end)
end

local function griffin_stable_game_minutes()
    local day, hour, minute = nil, nil, nil
    pcall(function()
        local tm = sdk.get_managed_singleton("app.TimeManager")
        if not tm then return end
        day = tonumber(tm:call("get_InGameDay"))
        hour = tonumber(tm:call("get_InGameHour"))
        minute = tonumber(tm:call("get_InGameMinute"))
    end)
    if day and hour and minute then return day * 1440.0 + hour * 60.0 + minute end
    return nil
end

local function griffin_stable_camp_active()
    local active = false
    pcall(function()
        local cm = sdk.get_managed_singleton("app.CampManager")
        active = cm and cm:call("get_IsActiveCamp") == true
    end)
    return active
end

-- A completed inn/home/camp rest is the fast recovery route. This heals the
-- entire roster, not merely the body which happens to be spawned. Records made
-- before health persistence existed may not know their species maximum yet;
-- mark those so the next minted body teaches the record its real maximum.
function griffin_stable_full_heal(reason)
    if S.route3_stable == nil then griffin_stable_load() end
    local st = S.route3_stable
    if type(st) ~= "table" then return false end

    local active = griffin_stable_active()
    if active and S.griffin then
        pcall(function() griffin_stable_bank_live_hp(active, S.griffin) end)
    end

    local now = os.time()
    local total = 0
    for _, comp in ipairs(st.companions or {}) do
        total = total + 1
        local maxhp = tonumber(comp.hp_max)
        if maxhp and maxhp > 0.0 then
            comp.hp = maxhp
            comp.full_heal_pending = nil
        else
            comp.full_heal_pending = true
        end
        comp.hp_saved_at = now
        if tonumber(comp.away_since) then comp.hp_rest_at = now end
    end

    -- The game's ordinary rest healing does not know about our grafted enemy
    -- HitController, so explicitly restore the live companion's authoritative
    -- receiver too. Keep a short reassertion lease in case its template finishes
    -- initialising during the wake transition.
    if active and S.griffin then
        pcall(function()
            local _, maxhp, hc = griffin_stable_read_live_hp(S.griffin)
            if maxhp and maxhp > 0.0 and hc then
                griffin_downed_set_hp(hc, maxhp)
                active.hp = maxhp
                active.hp_max = maxhp
                active.full_heal_pending = nil
                S.stable_hp_restore = {
                    ch = S.griffin, hc = hc, want = maxhp,
                    until_clock = os.clock() + 2.0,
                }
            end
        end)
    end

    griffin_stable_write()
    status(string.format("Pets fully rested (%d companion%s)",
        total, total == 1 and "" or "s"))
    log.info("[IrisStable] full pet heal after " .. tostring(reason or "rest"))
    return true
end

-- Camp sleep does not travel through InnFlowNode. Detect only a discontinuous
-- clock jump while an actual camp is deployed; walking around as time passes,
-- benches and oxcart travel therefore do not become free pet heals.
function griffin_stable_rest_tick()
    local game_minutes = griffin_stable_game_minutes()
    if not game_minutes then return end
    local previous = tonumber(S.stable_rest_game_minutes)
    S.stable_rest_game_minutes = game_minutes
    if not previous then return end
    local jumped = game_minutes - previous
    if jumped > 30.0 and griffin_stable_camp_active() then
        local last = tonumber(S.stable_rest_healed_game_minutes)
        if not last or math.abs(game_minutes - last) > 1.0 then
            S.stable_rest_healed_game_minutes = game_minutes
            griffin_stable_full_heal("camp rest")
        end
    end
end

function griffin_dismiss()
    -- RELIABLE crash workaround: destroy the companion body NOW, while the
    -- scene is fully live (safe + immediate — unlike the teardown race). The
    -- soul stays; the whistle re-mints her. Use before reloading if the
    -- auto-cleanup keeps losing the race.
    -- A downed companion is still in its rescue window and cannot be manually
    -- banked to evade that consequence. The timeout path calls
    -- griffin_downed_release FIRST, so its automatic trip to the stable remains
    -- legal and still starts the ordinary away-rest clock.
    local active_addr = nil
    pcall(function()
        local go = S.griffin and char_go(S.griffin)
        active_addr = go and go:get_address()
    end)
    local down = active_addr and type(S.downed) == "table"
        and S.downed[active_addr] ~= nil
    if not down and active_addr and type(_G.IrisDownedAddrs) == "table" then
        down = _G.IrisDownedAddrs[active_addr] == true
    end
    if down then
        S.route3_tame_status = tostring(C.route3_griffin_name or "Your companion")
            .. " is down -- revive them or wait for the stable recovery"
        status(S.route3_tame_status)
        return false
    end
    if S.route3_unleashed == true then pcall(function() griffin_recall() end) end
    -- Bank the authoritative HitController before destroying its body. Without
    -- this, a whistle summon is a free full heal from the spawn template.
    pcall(function()
        griffin_tamed_save()
        griffin_stable_begin_rest(griffin_stable_active())
    end)
    local destroyed = 0
    for _, key in ipairs({ "wild_spawner", "spawner", "critter_spawner", "route3_proxy_spawner" }) do
        local sp = S[key]
        if sp then pcall(function() sp:deleteAll() end) end
    end
    for _, ch in ipairs({ S.griffin, S.critter, S.route3_proxy }) do
        pcall(function()
            local go = ch and char_go(ch)
            if go then go:destroy(go); destroyed = destroyed + 1 end
        end)
    end
    pcall(function() griffin_drop_live_refs("dismissed") end)
    S.route3_tame_status = "companion dismissed (" .. tostring(destroyed) .. " body) - soul kept, whistle to recall"
    status(S.route3_tame_status)
    return true
end
function griffin_stable_write()
    pcall(function() json.dump_file(MOD .. "_stable.json", S.route3_stable or { companions = {} }) end)
end
function griffin_stable_active()
    local st = S.route3_stable
    if not st then return nil end
    for i, comp in ipairs(st.companions or {}) do
        if comp.id == st.active then return comp, i end
    end
    return nil
end
function griffin_stable_set_shim(comp)
    if comp then
        S.route3_tamed_record = { tamed = true, name = comp.name, species = comp.species, parked = comp.parked, yaw = comp.yaw, guid = comp.guid }
        if comp.name and tostring(comp.name) ~= "" then C.route3_griffin_name = tostring(comp.name) end
        S.route3_tamed_species = tostring(comp.species or "")
        pcall(function()
            if tostring(comp.species or ""):find("ch%d") then
                C.spawn_code = tostring(comp.species)
                griffin_species_profile_apply(comp.species)
            end
        end)
    else
        S.route3_tamed_record = nil
    end
end
function griffin_stable_load()
    local st = nil
    pcall(function() st = json.load_file(MOD .. "_stable.json") end)
    if not (st and type(st) == "table" and st.companions) then
        st = { active = nil, companions = {} }
        -- migrate the old single-soul file once
        local old = nil
        pcall(function() old = json.load_file(MOD .. "_tamed.json") end)
        if old and old.tamed == true then
            local rec = {
                id = "c1",
                name = tostring(old.name or "Companion"),
                species = tostring(old.species or "ch253000_00"),
                parked = old.parked,
                yaw = old.yaw,
            }
            st.companions = { rec }
            st.active = "c1"
        end
    end
    if (st.active == nil or tostring(st.active) == "") and type(st.companions) == "table" and #st.companions == 1 then
        st.active = st.companions[1].id or "c1"
        st.companions[1].id = st.active
    end
    S.route3_stable = st
    local comp = griffin_stable_active()
    griffin_stable_set_shim(comp)
    if comp then S.route3_tamed_restore_at = os.clock() + 2.0 end
    griffin_stable_write()
    return st
end
function griffin_stable_remove_active()
    local st = S.route3_stable
    if st and st.companions then
        for i, comp in ipairs(st.companions) do
            if comp.id == st.active then
                table.remove(st.companions, i)
                break
            end
        end
        st.active = nil
        griffin_stable_write()
    end
    S.route3_tamed_record = nil
    S.route3_tamed_species = nil
    pcall(function() json.dump_file(MOD .. "_tamed.json", { tamed = false }) end)
end
function griffin_tamed_save()
    local gch = S.griffin
    local go = gch and char_go(gch)
    if not go then return false end
    local comp = griffin_stable_active()
    if not comp then return false end
    local pos = transform_pos(go)
    comp.name = tostring(C.route3_griffin_name or comp.name or "Companion")
    -- ⛔⛔ 08-12 (Tails: drake -> doe -> horse, TWICE -- re-corrupted minutes after the
    -- one-shot repair): SPECIES IS IDENTITY, written once at the tame and never again.
    -- S.route3_tamed_species is GLOBAL state -- it still held the released unicorn's
    -- ch299011, and this line stamped it onto whoever was ACTIVE on every 10s parked-spot
    -- save. A save records position/hp/guid; it must never rewrite who a soul IS.
    -- Fill-if-missing only.
    comp.species = tostring(comp.species or S.route3_tamed_species or "ch253000_00")
    -- the body's instance GUID (in the GameObject name) survives script
    -- resets: reclaim can match THIS body exactly, never a same-species twin
    pcall(function()
        local full = tostring(go_name(go) or "")
        if full:find("@", 1, true) then comp.guid = full end
    end)
    if pos then comp.parked = { x = tonumber(pos.x), y = tonumber(pos.y), z = tonumber(pos.z) } end
    comp.yaw = yaw_from_transform(go) or comp.yaw or 0.0
    -- Do not sample the fresh spawn's template-full HP while the saved-health
    -- handover is still reasserting its lower value.
    if type(S.stable_hp_restore) ~= "table" then
        griffin_stable_bank_live_hp(comp, gch)
    end
    S.route3_tamed_record = { tamed = true, name = comp.name, species = comp.species, parked = comp.parked, yaw = comp.yaw, guid = comp.guid }
    griffin_stable_write()
    return true
end
function griffin_tamed_tick()
    if S.world_paused == true then return false end
    local now = os.clock()
    -- WORLD-READY GATE: on_frame keeps running during load screens, and
    -- touching the character list or spawning there crashes natively.
    -- Nothing below may act until a live, positioned player has existed
    -- for 5 continuous seconds.
    local ready_pgo = char_go(get_player())
    if not (ready_pgo and transform_pos(ready_pgo)) then
        S.route3_world_ready_since = nil
        S.route3_tamed_restore_tries = 0
        return false
    end
    if not S.route3_world_ready_since then S.route3_world_ready_since = now end
    if (now - S.route3_world_ready_since) < 5.0 then return false end
    -- the stable loads lazily on the first world-ready tick
    if S.route3_stable == nil then
        griffin_stable_load()
        S.route3_reprotect_at = now + 3.0
    end
    griffin_stable_rest_tick()
    griffin_stable_hp_restore_tick()
    -- one-shot RE-PROTECTION sweep: after a script reset, PARKED companions'
    -- bodies are unregistered and lose hook cover — find each stable species
    -- nearby and put its body back under mounts protection (without making
    -- it active). BENCHED by default: prime suspect for post-reset crashes
    -- (an automatic character-list scan right after a reset).
    if C.route3_reprotect_enabled == true
        and (tonumber(S.route3_reprotect_at) or 0.0) > 0.0 and now >= S.route3_reprotect_at
        and S.player_climb_on_character ~= true then
        S.route3_reprotect_at = 0.0
        pcall(function()
            local st = S.route3_stable
            for _, comp in ipairs((st and st.companions) or {}) do
                local prefix = tostring(comp.species or ""):match("ch%d+")
                if prefix then
                    local old_prefix = C.route3_tame_prefix
                    C.route3_tame_prefix = prefix
                    local body = griffin_find_wild(80.0)
                    C.route3_tame_prefix = old_prefix
                    if body and griffin_body_is_ours(body) then mounts[body] = true end
                end
            end
        end)
    end
    -- gradual tame-shrink: ease the body toward the target scale
    local scale_target = tonumber(S.route3_scale_target)
    if scale_target then
        local sgo = S.griffin and char_go(S.griffin) or nil
        -- ⛔⛔ 08-09 r78 -- THE HORSE VIBRATION. (Aurora: "the horse vibrates a
        -- lot sometimes, either just static while riding or not riding.")
        -- TWO OWNERS, ONE VALUE, EVERY FRAME:
        --   * this easer pulls a tamed horse toward iris_species_base_scale(),
        --     which returns 1.0 for every chassis except ch299210;
        --   * IrisWildHorses re-asserts C.horse_scale -- live value 1.6 -- on
        --     EVERY frame, writing whenever it drifts more than 0.01.
        -- So the mesh is dragged between 1.0 and 1.6 continuously. Whichever
        -- module happens to write last that frame is what you see, which is why
        -- it is intermittent, and why it happens whether or not you are riding.
        -- IrisWildHorses' own comment believed load order settled it ("this is
        -- the last writer each frame = horse_scale wins, steady") -- but this
        -- easer keeps re-targeting, so it never stops pulling.
        -- ⛔ ONE OWNER. IrisWildHorses is the horse module and owns horse size;
        -- the tame-shrink exists for the giant rideables, not for horses, so
        -- this side stands down. (Wyrm growth above 1.0 is unaffected -- it is
        -- targeted elsewhere and never routes a horse through here at <= 1.0.)
        if sgo then
            local hname = ""
            pcall(function() hname = tostring(sgo:call("get_Name") or "") end)
            -- ⛔ 08-11 (Aurora: "summoned Quoth, hit max, not changing -- flaws in the
            -- system"): this guard matched ALL of ch299 -- which is every CRITTER -- so
            -- crows/rabbits/rats/birds were silently excluded from scale application all
            -- day while the mult computed perfectly ("previewing gene 30 (mult 2.00)").
            -- The two-owner fight it guards against is the HORSE module specifically:
            -- stand down ONLY for the doe/stag chassis IrisWildHorses owns.
            if (hname:find("ch299011", 1, true) or hname:find("ch299010", 1, true))
                and (scale_target or 1.0) <= 1.05 then
                S.route3_scale_target = nil
                sgo = nil
            end
        end
        if sgo then
            pcall(function()
                -- ⭐ 08-11 SIZE GENE: stored targets stay BASE; the IV multiplies only here,
                -- at application (0.86 small .. 1.15 large, gene 15 = species-true)
                local want = scale_target
                pcall(function()
                    -- target-aware: the gene's drama depends on how big the body is meant
                    -- to be (full on critters, gentle on mounts -- 08-11 round 3)
                    if iris_iv_size_mult then want = scale_target * (tonumber(iris_iv_size_mult(scale_target)) or 1.0) end
                end)
                local tf = sgo:call("get_Transform")
                local cur = tf:call("get_LocalScale")
                local cx = tonumber(cur and cur.x) or want
                local snap_due = (tonumber(S.route3_scale_snap_at) or 0.0) > 0.0
                    and now >= (tonumber(S.route3_scale_snap_at) or 0.0)
                local nx = snap_due and want or (cx + (want - cx) * 0.02)
                if snap_due or math.abs(nx - want) < 0.005 then
                    nx = want
                    S.route3_scale_target = nil
                    S.route3_scale_snap_at = 0.0
                end
                tf:call("set_LocalScale", make_vec3(nx, nx, nx))
                -- diag (Shadow-not-growing hunt, 08-11): what the one true applier applied
                if (tonumber(S.scale_easer_dbg_at) or 0.0) < now then
                    S.scale_easer_dbg_at = now + 2.0
                    pcall(function() log.info(string.format(
                        "[GriffinScout] scale easer: base=%.2f gene=%.2f want=%.2f wrote=%.2f (was %.2f)",
                        scale_target, want / math.max(0.01, scale_target), want, nx, cx)) end)
                end
            end)
        else
            S.route3_scale_target = nil
        end
    end
    -- post-tame calm burst: re-purge grudges every half second until the
    -- combat AI has fully let go
    local calm_until = tonumber(S.route3_ally_calm_until) or 0.0
    -- ⭐⭐ 08-10 r91 -- THE CALM TICK STANDS DOWN WHILE YOU ARE MOUNTED.
    -- (Aurora: "I couldn't get any aggro at all from ANY enemy" -- not just on
    -- the horse, on HER.) This block runs every 0.5s while a companion is out
    -- and calm, and it calls clear_party_hate() -- which begins by wiping the
    -- PLAYER'S OWN hate list -- plus clear_griffin_hate and clear_griffin_targets.
    -- It exists so a peaceful pet does not drag the world into a fight, and
    -- that is right when you are walking beside it. It is exactly wrong when
    -- you are sitting on it in front of a cyclops: half a second is never
    -- enough for an engagement to establish before it is erased again.
    -- ⛔ Riding is a deliberate combat posture. While mounted, peace is off.
    local iris_mounted_now = false
    if C.route3_mounted_combat ~= false then
        pcall(function()
            local api = rawget(_G, "IrisHorseMount")
            iris_mounted_now = api and api.is_mounted
                and api.is_mounted() == true
        end)
    end
    if iris_mounted_now then
        S.route3_calm_suspended = "mounted"
    else
        S.route3_calm_suspended = nil
    end
    if not iris_mounted_now
        and calm_until > now and S.companion_order ~= "attack" and S.route3_unleashed ~= true
        and not griffin_predation_window_active(now)
        and now - (tonumber(S.route3_ally_calm_last) or 0.0) > 0.5 then
        S.route3_ally_calm_last = now
        pcall(function() clear_party_hate() end)
        pcall(function() clear_griffin_hate() end)
        pcall(function() clear_griffin_targets() end)
        -- ⛔⛔ 08-09 r69 -- THIS IS WHY THERE IS NO BOSS HEALTHBAR ON ANYTHING.
        -- (Aurora: "spawning the horse removes the boss health bar - I assume
        -- that was a counter for when you spawn the griffin and it showed its
        -- healthbar?" -- exactly right.)
        -- unregistBossGauge takes NO ARGUMENTS. It is not "drop the griffin's
        -- gauge", it is "drop THE gauge" -- global, whoever it belongs to. And
        -- this call sits in the calm tick, so while any companion is out and
        -- peaceful it fires every 0.5s, permanently destroying the cyclops's
        -- healthbar (and any other boss's) for as long as your horse exists.
        -- Now OFF by default. ⚠ The trade it was buying: a tamed griffin that
        -- gets attacked may show its own boss gauge again. If that turns up and
        -- bothers you, set route3_kill_boss_gauge = true to restore this -- but
        -- it costs every legitimate boss bar in the game to do it.
        if C.route3_kill_boss_gauge == true then
            pcall(function() singleton("app.GuiManager"):call("unregistBossGauge") end)
        end
    end
    -- Deferred spawn requests (whistle summon / soul restore / anything queued while paused).
    -- The frame loop keeps ticking through the pause menu -- the sentry gates on player validity,
    -- not on pause -- so this has to hold the request rather than drain it, or a spawn queued in
    -- the menu would fire on the very next frame while still paused.
    if S.route3_spawn_request == true and not griffin_world_paused() then
        S.route3_spawn_request = false
        spawn_griffin()
    end
    -- Legacy restore warp: parked coordinates can belong to another streamed
    -- tile or the edge of a cliff. Never trust them as a live placement.
    local wp = S.route3_restore_warp_pending
    if wp and (tonumber(S.route3_restore_warp_at) or 0.0) > 0.0 and now >= S.route3_restore_warp_at then
        S.route3_restore_warp_at = 0.0
        S.route3_restore_warp_pending = nil
        local gch = S.griffin
        local go = gch and char_go(gch)
        if go then
            local pos, rot, detail = route3_find_safe_stable_spawn(C.route3_stable_spawn_distance)
            if pos then
                pcall(function() set_transform(go, pos, rot) end)
                pcall(function() set_character_transform(gch, pos, rot) end)
                stop_navigation(gch, true)
                S.route3_stable_spawn_status = tostring(detail or "safe restore")
            else
                S.route3_stable_spawn_status = "restore warp skipped: no safe floor"
            end
        end
    end
    if S.griffin and char_go(S.griffin) then
        -- alive: keep the parked spot fresh while unmounted
        if S.mounted ~= true and now - (tonumber(S.route3_tamed_saved_at) or 0.0) > 10.0 then
            S.route3_tamed_saved_at = now
            griffin_tamed_save()
        end
        return false
    end
    -- body missing but the soul file says tamed: re-instantiate at the parked spot
    if C.route3_restore_enabled ~= true then return false end
    local rec = S.route3_tamed_record
    if not (rec and rec.tamed == true) then return false end
    if (tonumber(S.route3_tamed_restore_tries) or 0) >= 3 then return false end
    -- Wait out the pause menu before reclaiming. This path never spawns -- it re-registers a body
    -- already standing in the world -- but register_griffin still pokes components, and there are
    -- only 3 attempts. Returning BEFORE the retry timer is touched means a paused frame costs
    -- nothing; switching companions from the menu still reclaims the moment play resumes.
    if griffin_world_paused() then return false end
    if now < (tonumber(S.route3_tamed_restore_at) or 0.0) then return false end
    S.route3_tamed_restore_at = now + 10.0
    S.route3_tamed_restore_tries = (tonumber(S.route3_tamed_restore_tries) or 0) + 1
    -- RECLAIM ONLY: after a script reset the tamed body is usually still
    -- standing in the world — re-register it. NEVER auto-spawn: a duplicate
    -- body is worse than a missing one. The whistle (G) is the deliberate
    -- summon when the body is truly gone.
    local scan_info = "?"
    -- match the EXACT body by its instance guid when we have one; species
    -- prefix is the fallback (guid match can never grab a same-species twin)
    local guid_prefix = tostring(rec.guid or ""):find("@", 1, true) and tostring(rec.guid) or nil
    local prefix = guid_prefix or (tostring(rec.species or ""):match("ch%d+") or "")
    if prefix ~= "" then
        local old_prefix = C.route3_tame_prefix
        C.route3_tame_prefix = prefix
        local body, info = griffin_find_wild(60.0)
        C.route3_tame_prefix = old_prefix
        scan_info = tostring(info or "?")
        local via_guid = body ~= nil and guid_prefix ~= nil
        if not body and guid_prefix then
            -- exact body gone (despawned): fall back to species scan once
            C.route3_tame_prefix = tostring(rec.species or ""):match("ch%d+") or ""
            body, info = griffin_find_wild(60.0)
            C.route3_tame_prefix = old_prefix
            scan_info = scan_info .. " / species: " .. tostring(info or "?")
        end
        -- a species-prefix match could be a live WILD twin (a full reload
        -- rebuilds bodies with new guids): only claim a body still carrying
        -- our ally context — a wild boss is a crash + a theft, not a reunion
        if body and not via_guid and not griffin_body_is_ours(body) then
            scan_info = scan_info .. " [wild twin nearby - not ours, not claiming]"
            body = nil
        end
        if body then
            register_griffin(body)
            S.route3_tamed_species = tostring(rec.species or "")
            griffin_species_profile_apply(S.route3_tamed_species)
            status(tostring(C.route3_griffin_name or "Griffin") .. " remembers you")
            return true
        end
    end
    -- prime the species so a later whistle-summon resurrects the right creature
    pcall(function()
        local sp = tostring(rec.species or "")
        if sp:find("ch%d") then
            C.spawn_code = sp
            S.route3_tamed_species = sp
            griffin_species_profile_apply(sp)
        end
    end)
    S.route3_tame_status = string.format(
        "%s not found nearby (%s) - whistle (G) to call them",
        tostring(C.route3_griffin_name or "Griffin"), scan_info)
    return false
end
-- floating name + gender symbol over the ACTIVE companion -- the stable-driven bodies
-- (wolf/griffin/drake/ox) that never enter IrisTaming's local roster and so never got
-- its nameplate. Defers to IrisTaming for critters (has_pet) and to its single toggle.
function companion_nameplate_tick()
    if S.mounted == true then return end   -- not in the rider's face
    local gch = S.griffin
    local go = gch and char_go(gch)
    if not go or is_dead(gch) then return end
    pcall(function()
        local t = _G.IrisTaming
        if t and t.nameplates_on and t.nameplates_on() ~= true then return end
        if t and t.has_pet then
            local a = nil
            pcall(function() a = gch:get_address() end)
            if a and t.has_pet(a) then return end   -- a critter: IrisTaming's plate owns it
        end
        -- 08-11: the plate hangs over the BODY -- read the record the body belongs to,
        -- never the panel selection (griffin_stable_live_rec, species-verified)
        local comp2 = (griffin_stable_live_rec and griffin_stable_live_rec()) or griffin_stable_active()
        local nm = (comp2 and comp2.name) or C.route3_griffin_name or "Companion"
        local spec = tostring((comp2 and comp2.species) or "")
        if tostring(nm):find("^ch%d") then nm = iris_type_name(spec) end   -- a body is not a name
        local g = comp2 and comp2.gender
        local sym = (g == "female" and " \u{2640}") or (g == "male" and " \u{2642}") or ""
        local rp = go:call("get_Transform"):call("get_Position")   -- world_to_screen speaks RENDER
        rp.y = rp.y + ((spec:find("ch253", 1, true) or spec:find("ch257", 1, true)) and 2.4 or 1.5)
        local s2 = draw.world_to_screen(rp)
        if s2 then
            draw.filled_circle(s2.x, s2.y, 6, 0xFFB0FFC0, 12)
            iris_hud_text(tostring(nm) .. sym, s2.x + 10, s2.y - 8, 0xFFB0FFC0, 17)
        end
    end)
end

-- sdk hooks survive script resets, so the installed closure calls a replaceable
-- global rather than capturing this particular load of the stable module.
_G.IrisStableRestCompleted_v1 = function(reason)
    pcall(function() griffin_stable_full_heal(reason) end)
end

local function griffin_stable_install_rest_hook()
    if _G.IrisStableRestHookInstalled_v1 == true then return true end
    local installed = false
    pcall(function()
        local td = sdk.find_type_definition("app.TalkEventPlayer")
        local method = td and td:get_method("startNode")
        if not method then return end
        _G.IrisStableRestTracker_v1 = _G.IrisStableRestTracker_v1 or {}
        sdk.hook(method,
            function(args)
                pcall(function()
                    local player = sdk.to_managed_object(args[2])
                    local node = player and player._CurrentNode
                    local node_name = nil
                    pcall(function()
                        local ntd = node and node:get_type_definition()
                        node_name = ntd and ntd:get_full_name()
                    end)
                    node_name = tostring(node_name or "")
                    local tracker = _G.IrisStableRestTracker_v1
                    if node_name:find("InnFlowNode", 1, true) then
                        -- Preserve the first timestamp: the same flow can emit a
                        -- second InnFlowNode after the player chooses to sleep.
                        if not tracker.armed_game_minutes then
                            tracker.armed_game_minutes = griffin_stable_game_minutes()
                        end
                    elseif node_name:find("EndSegmentNode", 1, true)
                        and tracker.armed_game_minutes then
                        local finished = griffin_stable_game_minutes()
                        local advanced = finished
                            and (finished - tracker.armed_game_minutes) > 30.0
                        tracker.armed_game_minutes = nil
                        if advanced then
                            S.stable_rest_healed_game_minutes = finished
                            local callback = rawget(_G, "IrisStableRestCompleted_v1")
                            if callback then callback("inn/home rest") end
                        end
                    end
                end)
            end,
            function(retval) return retval end)
        installed = true
    end)
    if installed then
        _G.IrisStableRestHookInstalled_v1 = true
        log.info("[IrisStable] rest hook installed (InnFlowNode -> EndSegmentNode + camp clock)")
    end
    return installed
end

griffin_stable_install_rest_hook()
