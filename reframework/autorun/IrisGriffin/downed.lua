-- I.R.I.S. griffin -- downed and revive.
--
-- When she loses her health she goes down rather than dying: a knocked-out state with its own
-- HUD, a revive the player performs, and a regeneration timer if left alone. Self-contained --
-- nothing else in the mod reads this state except the frame loop that ticks it.

local ctx = require("IrisGriffin.context")
local C, S = ctx.C, ctx.S
local MOD                              = ctx.MOD
local DEFAULT                          = ctx.DEFAULT
local char_go                          = ctx.char_go
local delete_griffin                   = ctx.delete_griffin
local get_component                    = ctx.get_component
local get_player                       = ctx.get_player
local is_dead                          = ctx.is_dead
local reacquire_griffin                = ctx.reacquire_griffin
local status                           = ctx.status
local transform_pos                    = ctx.transform_pos

-- ⭐⭐⭐ VERIFIED DOWN CLIPS (08-09). Aurora: "if a creature is downed, they play
-- their death animation but stay present". Every entry below was READ OUT of
-- reframework/Animal Atlas by NAME -- never guessed, never extrapolated from a
-- neighbouring id (dd2-creature-motion-atlas: a wrong clip id on a parked FSM
-- can hard-crash the game).
-- ⚠ AND THE CONVENTION IS NOT SAFE TO ASSUME, which is exactly why this is a
-- table and not a formula. The tempting rule "bank 10, 1320 = die / 1300 = down
-- loop" is WRONG in three places:
--   * ch253000 (griffin) 10/1300 = ch53_000_dmg_finish_reception_loop_faceD --
--     not a down loop at all; its real one is 10/1002 (dmg_down_S_loop_F).
--   * ch258000 10/1320 = ch58_000_dmg_hitback_L_G_F -- a hitback, not a death.
--   * nine of the small critters (ch2992xx/4xx) have NO 1320 entry whatsoever.
-- So: die = nil means "this body has no death clip" -- collapse straight into
-- the loop instead. Both nil means fall back to the FSM node and nothing else.
local IRIS_DOWN_CLIPS = {
    ch100000 = {bank = 10, die = 1320, loop = 1300}, -- dmg_down_die_faceD_1
    ch221002 = {bank = 10, die = 1320, loop = 1300}, -- dmgQM_down_loop_faceL
    ch223000 = {bank = 10, die = 1320, loop = 1300}, -- wolf, faceU
    ch253000 = {bank = 10, die = 1320, loop = 1002}, -- ⚠ griffin: loop is 1002
    ch254    = {bank = 10, die = 1320, loop = 1300},
    ch257000 = {bank = 10, die = 1320, loop = 1300},
    ch257001 = {bank = 10, die = 1320, loop = 1300},
    ch258000 = {bank = 10, die = nil,  loop = 1300}, -- ⚠ no death clip
    ch260000 = {bank = 10, die = 1320, loop = 1300},
    ch299003 = {bank = 10, die = 1320, loop = 1300},
    ch299010 = {bank = 10, die = 1320, loop = 1300}, -- horse
    ch299011 = {bank = 10, die = 1320, loop = 1300}, -- horse
    ch299020 = {bank = 10, die = 1320, loop = 1300},
    ch299030 = {bank = 10, die = 1320, loop = 1300},
    ch299031 = {bank = 10, die = 1320, loop = 1300},
    ch299200 = {bank = 10, die = nil,  loop = 1300}, -- critters: loop only
    ch299210 = {bank = 10, die = nil,  loop = 1300},
    ch299220 = {bank = 10, die = nil,  loop = 1300},
    ch299221 = {bank = 10, die = nil,  loop = 1300},
    ch299240 = {bank = 10, die = nil,  loop = 1300},
    ch299400 = {bank = 10, die = nil,  loop = 1300},
    ch299410 = {bank = 10, die = nil,  loop = 1300},
    ch299420 = {bank = 10, die = nil,  loop = 1300},
    ch299430 = {bank = 10, die = nil,  loop = 1300},
}
-- ⭐⭐ 08-09 r67 -- HIT REACTIONS (Aurora: "all the mounts need to have their hit
-- reactions when they get hit -- is that something we have at all in any of our
-- tamed creatures?"). Answer was no: a tamed body is think-stopped with its AI
-- off, so the damage tree that would normally pick a flinch never runs. It only
-- became visible now that the horse has a hurtbox again (r66).
-- bank 10 ids 0/10/20/30 = dmg_hitback_S_G_ F/B/L/R -- read from the atlas by
-- NAME, per chassis, and the mapping is NOT uniform:
--   * ch223000 (wolf) has 20=R and 30=L -- SWAPPED versus everything else.
--   * ch257000/1 (drake) map all four ids to the F clip -- no directional set.
--   * ch258000 (dragon) has only id 0.
--   * every small critter (ch2992xx/4xx) has NO hitback clips at all -> nil,
--     meaning "this body does not flinch", not "use id 0".
local IRIS_HITBACK = {
    ch100000 = {bank = 10, f = 0, b = 10, l = 20, r = 30},
    ch221002 = {bank = 10, f = 0, b = 10, l = 20, r = 30},
    ch223000 = {bank = 10, f = 0, b = 10, l = 30, r = 20}, -- ⚠ wolf: L/R swapped
    -- Griffin has a distinct AIR set in the same bank. 300/310/320/330 are
    -- ch53_000_dmg_hitback_S_A_F/B/L/(atlas typo: L again), all verified in
    -- Animal Atlas. Keep the grounded set for a landed griffin.
    ch253000 = {bank = 10, f = 0, b = 10, l = 20, r = 30,
        af = 300, ab = 310, al = 320, ar = 330},
    ch254    = {bank = 10, f = 0, b = 10, l = 20, r = 30},
    -- Drake owns only one small aerial hitback direction (10:300), so use it
    -- for every incoming direction rather than painting grounded 10:0 in flight.
    ch257000 = {bank = 10, f = 0, b = 0,  l = 0,  r = 0,
        af = 300, ab = 300, al = 300, ar = 300},
    ch257001 = {bank = 10, f = 0, b = 0,  l = 0,  r = 0,
        af = 300, ab = 300, al = 300, ar = 300},
    ch258000 = {bank = 10, f = 0, b = 0,  l = 0,  r = 0},
    ch260000 = {bank = 10, f = 0, b = 10, l = 20, r = 30},
    ch299003 = {bank = 10, f = 0, b = 10, l = 20, r = 30},
    ch299010 = {bank = 10, f = 0, b = 10, l = 20, r = 30},
    ch299011 = {bank = 10, f = 0, b = 10, l = 20, r = 30},
    ch299020 = {bank = 10, f = 0, b = 10, l = 20, r = 30},
    ch299030 = {bank = 10, f = 0, b = 10, l = 20, r = 30},
    ch299031 = {bank = 10, f = 0, b = 10, l = 20, r = 30},
}
-- the Arisen's own revive trio, from
-- backup/data/RiftSpeak/.../HumanOrBeastren_MotionIDs.json bank 0:
--   1000 ch00_000_com_revive_start / 1001 _loop / 1002 _end
local IRIS_PLAYER_REVIVE = {bank = 0, start_id = 1000, loop_id = 1001, end_id = 1002}

local function iris_down_clip_for(go)
    if not go then return nil end
    local name = nil
    pcall(function() name = tostring(go:call("get_Name")) end)
    if not name then return nil end
    -- longest key first so ch299011 never matches a shorter ch299 prefix
    local best, best_len = nil, -1
    for key, v in pairs(IRIS_DOWN_CLIPS) do
        if name:find(key, 1, true) and #key > best_len then
            best, best_len = v, #key
        end
    end
    return best
end

local function iris_play_clip(ch, bank, id, blend)
    if not (ch and bank and id) then return false end
    local ok = false
    pcall(function()
        local motion = ch:call("get_Motion")
        local layer = motion and motion:call("getLayer", 0)
        if not layer then return end
        layer:call(
            "changeMotion(System.UInt32, System.UInt32, System.Single, "
            .. "System.Single, via.motion.InterpolationMode, "
            .. "via.motion.InterpolationCurve)",
            bank, id, 0.0, tonumber(blend) or 0.15, 1, 1)
        ok = true
    end)
    return ok
end

function griffin_downed_probe_mark(s)
    S.downed_probe_trace = S.downed_probe_trace or {}
    S.downed_probe_trace[#S.downed_probe_trace + 1] = string.format("%.2f %s", os.clock(), tostring(s))
    while #S.downed_probe_trace > 40 do table.remove(S.downed_probe_trace, 1) end
    pcall(function() json.dump_file(MOD .. "_downed_probe.json",
        { last = tostring(s), time = os.date("%H:%M:%S"), trace = S.downed_probe_trace }) end)
end
function griffin_downed_state()
    S.downed = S.downed or {}
    return S.downed
end
function griffin_downed_protected_refresh(force)
    -- Rebuild the protected-body set WHOLESALE on a short cadence. ⛔ Keyed by GO address,
    -- and the engine REUSES addresses -- a stale entry would hand invincibility to a freshly
    -- spawned unrelated body, so we never patch this set incrementally.
    local now = os.clock()
    if force ~= true and now < (tonumber(S.downed_prot_at) or 0.0) then return S.downed_prot or {} end
    S.downed_prot_at = now + 1.0
    local set = {}
    pcall(function()
        local ch = reacquire_griffin()          -- the ACTIVE companion, whatever species
        if not ch then return end
        local go = char_go(ch)
        local addr = nil
        pcall(function() addr = go and go:get_address() end)
        if addr then set[addr] = ch end
    end)
    S.downed_prot = set
    return set
end
function griffin_downed_is_protected(addr)
    if not addr then return nil end
    return (S.downed_prot or {})[addr]
end
function griffin_downed_is_winged_fall(addr, di)
    if C.route3_griffin_fall_immunity == false or not (addr and di) then return false end
    local damage_type = nil
    pcall(function() damage_type = tonumber(di:get_field("DamageType")) end)
    -- 14/15 are DD2's two native fall-impact types (the same pair used by the mounted
    -- rider fall shield). Scope by the ACTIVE protected body and species: wild griffins,
    -- horses, wolves and creatures thrown by the griffin retain their normal fall rules.
    if damage_type ~= 14 and damage_type ~= 15 then return false end
    local ch = griffin_downed_is_protected(addr)
    if not ch then
        local active = reacquire_griffin()
        local active_addr = nil
        pcall(function() active_addr = char_go(active):get_address() end)
        if active_addr == addr then ch = active end
    end
    local species = ""
    pcall(function() species = tostring(char_go(ch):call("get_Name") or "") end)
    return species:find("ch253", 1, true) ~= nil
end

function griffin_downed_resolve_receiver(hc, go_addr)
    -- A costume/grafted body owns a separate HitController on a child GO. The
    -- companion registry is keyed by the outer character GO, so a direct GO
    -- comparison misses precisely the damage path that lethal falls use.
    local active, active_addr = reacquire_griffin(), nil
    pcall(function() active_addr = char_go(active):get_address() end)
    if go_addr and (griffin_downed_is_protected(go_addr)
        or go_addr == active_addr) then return go_addr end
    -- Costume receivers are normally descendants of the canonical character GO.
    -- Walk the actual transform ancestry before falling back to cached identity.
    local current = nil
    pcall(function() current = hc and hc:call("get_GameObject") end)
    for _ = 1, 8 do
        if not current then break end
        local ca = nil
        pcall(function() ca = current:get_address() end)
        if ca and (griffin_downed_is_protected(ca)
            or ca == active_addr) then return ca end
        local parent = nil
        pcall(function()
            local tf = current:call("get_Transform")
            local ptf = tf and tf:call("get_Parent")
            parent = ptf and ptf:call("get_GameObject")
        end)
        current = parent
    end
    local hca = nil
    pcall(function() hca = hc and hc:get_address() end)
    if hca then
        for candidate, source in pairs(S.hp_source or {}) do
            local sa = nil
            pcall(function() sa = source and source:get_address() end)
            if sa == hca and (griffin_downed_is_protected(candidate)
                or candidate == active_addr) then
                return candidate
            end
        end
        -- First hit after a summon may arrive before hp_source has been cached.
        -- Compare the receiver with every known controller on the active body.
        for candidate, ch in pairs(S.downed_prot or {}) do
            local sources = {}
            local target = griffin_target_hit_controller(ch)
            if target then sources[#sources + 1] = target end
            local direct = nil
            pcall(function() direct = ch:call("get_HitController") end)
            if direct then sources[#sources + 1] = direct end
            for _, source in ipairs(sources) do
                local sa = nil
                pcall(function() sa = source and source:get_address() end)
                if sa == hca then return candidate end
            end
        end
        -- Refresh may not yet have populated downed_prot on the first frame
        -- after summon. Compare the active body's controllers directly too.
        if active and active_addr then
            local sources = {}
            local target = griffin_target_hit_controller(active)
            if target then sources[#sources + 1] = target end
            local direct = nil
            pcall(function() direct = active:call("get_HitController") end)
            if direct then sources[#sources + 1] = direct end
            for _, source in ipairs(sources) do
                local sa = nil
                pcall(function() sa = source:get_address() end)
                if sa == hca then return active_addr end
            end
        end
    end
    return nil
end

function griffin_hit_reaction_busy()
    local r = S.hit_reaction_active
    if type(r) ~= "table" then return false end
    local now = os.clock()
    if now < (tonumber(r.min_until) or 0.0) then return true end
    if now >= (tonumber(r.hard_until) or 0.0) then return false end
    local playing = false
    pcall(function()
        local motion = r.ch and r.ch:call("get_Motion")
        local layer = motion and motion:call("getLayer", 0)
        if not layer then return end
        local bank = tonumber(layer:call("get_MotionBankID"))
        local clip = tonumber(layer:call("get_MotionID"))
        local frame = tonumber(layer:call("get_Frame")) or 0.0
        local ending = tonumber(layer:call("get_EndFrame")) or 0.0
        playing = bank == tonumber(r.bank) and clip == tonumber(r.clip)
            and (ending <= 1.0 or frame < ending - 0.5)
    end)
    return playing
end

local function iris_hit_reaction_is_airborne(ch, go, hb)
    if not (ch and go and hb and hb.af ~= nil) then return false end
    local airborne = S.airborne == true
    pcall(function()
        if ch:call("get_IsFlight") == true then airborne = true end
    end)
    -- IsFlight can briefly drop while the damage action is being selected. Height
    -- is the stable third witness and prevents that transition frame choosing a
    -- grounded pose in mid-air.
    pcall(function()
        if airborne or not route3_ground_y_robust then return end
        local pos = transform_pos(go)
        local ground = pos and route3_ground_y_robust(go, tonumber(pos.y))
        if pos and ground and ((tonumber(pos.y) or 0.0) - ground) > 1.5 then
            airborne = true
        end
    end)
    return airborne
end

function griffin_downed_special_move_busy()
    -- Any native attack/rise node owns the body. Painting a reaction over it is
    -- the intermittent T-pose/CTD path, and queueing one for afterwards steals
    -- the next input, so the caller now discards only the cosmetic reaction.
    if S.route3_dogfight or S.route3_gustair or S.route3_quick_burst
        or S.route3_gatk or S.route3_gust or S.route3_drake_attack
        or S.route3_divebomb or S.route3_swoop or S.route3_grab
        or S.route3_predation_eat or S.route3_live_window then return true end
    local owner = S.base_owner
    if type(owner) == "table" and tostring(owner.name or "") ~= "hitreact"
        and os.clock() < (tonumber(owner.until_clock) or 0.0) then return true end
    if S.route3_node_lock_at ~= nil or S.route3_node_exit_until ~= nil then return true end
    local horse_busy = false
    pcall(function()
        local api = rawget(_G, "IrisHorseMount")
        horse_busy = api and api.move_busy and api.move_busy() == true or false
    end)
    if horse_busy then return true end
    return false
end
function griffin_downed_hit_controller(ch, addr)
    -- Grafted/costume bodies can receive damage on a different HitController
    -- from Character.get_HitController. The hook gives us the authoritative
    -- receiver; keep floor, HUD and revive writes on that same HP store.
    local hc = addr and (S.hp_source or {})[addr] or nil
    local valid = false
    pcall(function() valid = hc and hc:call("get_Valid") ~= false end)
    if valid then return hc end
    return griffin_target_hit_controller(ch)
end
function griffin_downed_set_hp(hc, value)
    if not hc then return false end
    local before = nil
    pcall(function() before = tonumber(hc:call("get_Hp")) end)
    for _, attempt in ipairs({
        function() hc:call("setHp(System.Single, System.Boolean, System.Int32)", value, true, 0) end,
        function() hc:call("setHp(System.Single, System.Boolean)", value, true) end,
        function() hc:call("setHp(System.Single)", value) end,
        function() hc:call("set_Hp(System.Single)", value) end,
        function() hc:call("set_CurrentHitPoint(System.Single)", value) end,
    }) do
        if pcall(attempt) then
            local after = nil
            pcall(function() after = tonumber(hc:call("get_Hp")) end)
            if after and (math.abs(after - value) <= 0.05
                or (before and value < before and after < before)
                or (before and value > before and after > before)) then
                return true
            end
        end
    end
    return false
end
function griffin_downed_clamp(args, di, addr)
    -- ⛔ PER-FRAME BUDGET, not a per-hit clamp. Two blows landing in the same frame each read
    -- the SAME pre-damage HP; clamping each to (hp - floor) individually lets their SUM cross
    -- the floor to a true 0 -- which is UNREVIVABLE, the exact outcome the floor exists to
    -- prevent. We track how much has already been allowed this frame, per body.
    local rhc = nil
    pcall(function() rhc = sdk.to_managed_object(args[2]) end)
    -- ⭐⭐ 08-09 r83 -- THE REAL HP LIVES HERE, AND NOWHERE WE WERE LOOKING.
    -- Aurora's screenshot: Chad DOWN with a FULL health bar, and the diag agrees
    -- -- "horse hp=250 ... downed=DOWNED". So app.HitController.get_Hp on the
    -- horse's GameObject reports full health while the body is on the floor.
    -- The controller that ACTUALLY takes the damage is this one: the receiver
    -- handed to calcDamageReaction. Two different HP stores on the same body.
    -- Cache it per address so the HUD (and anything else) can read the number
    -- that is genuinely moving instead of the one that never changes.
    if rhc then
        S.hp_source = S.hp_source or {}
        S.hp_source[addr] = rhc
    end
    local curhp = nil
    if rhc then
        for _, gm in ipairs({ "get_Hp", "get_CurrentHitPoint" }) do
            local okh, v = pcall(function() return rhc:call(gm) end)
            if okh and tonumber(v) then curhp = tonumber(v); break end
        end
    end
    local dmg = nil
    pcall(function() dmg = tonumber(di:get_field("Damage")) end)
    if dmg == nil then return end
    if griffin_downed_is_winged_fall(addr, di) then
        pcall(function() di:set_field("Damage", 0.0) end)
        S.griffin_fall_ignored = (tonumber(S.griffin_fall_ignored) or 0) + 1
        S.downed_clamp_dbg = "griffin wing-glide: native fall damage ignored"
        _G.IrisClampDbg = S.downed_clamp_dbg
        return
    end
    if not curhp then
        -- ⛔ INVERTED DEFAULT for a protected body. The courtship clamp returns without
        -- clamping when HP is unreadable -- for a companion that is a pass-through killing
        -- blow. The safe failure here is zero damage, not a dead pet.
        pcall(function() di:set_field("Damage", 0.0) end)
        S.downed_clamp_dbg = "hp UNREADABLE -> damage zeroed"
        -- ⛔ r87: THIS BRANCH ZEROES THE HIT. It is the clamp's deliberate
        -- inverted default (better a pass-through blow is lost than a pet dies)
        -- -- but if HP is chronically unreadable it silently makes the body
        -- INVINCIBLE, which is exactly the symptom Aurora has been fighting.
        -- This string has been recorded since the day it was written and never
        -- once printed anywhere. Surface it.
        _G.IrisClampDbg = S.downed_clamp_dbg
        _G.IrisClampHits = (tonumber(rawget(_G, "IrisClampHits")) or 0) + 1
        return
    end
    -- ⭐⭐⭐ 08-10 r93 -- THE HORSE IS BEING ONE-SHOT, AND THAT IS THE WHOLE
    -- "the bar never moves" MYSTERY. The log finally caught a real hit:
    --     clampHits=1  clamp=dmg 249 (hp 250, budget 249)
    -- ONE blow, 249 damage, against a body with 250 HP. The cyclops takes the
    -- horse from full to the floor in a single swing -- so there is no
    -- intermediate state for a health bar to show. It reads 100%, then the
    -- creature is down. Nothing was ever wrong with the bar; there was simply
    -- never a middle. Same for the missing hit reactions: one hit, and it is
    -- already in the down clip.
    -- ⛔ 250 HP is a saddle horse's stat sheet, not a war mount's. IrisWildHorses
    -- already scales damage by 250/horse_hp for WILD horses, but a tamed
    -- companion never goes through that path. Scale it HERE, in the hook that
    -- already sees every hit on the companion.
    -- Species-aware durability. The 0.25 saddle-horse protection must never
    -- leak onto a griffin: a ch253 body retains its boss-sized native HP
    -- (105,000 on Aurora's current setup), so quartering ordinary enemy hits
    -- makes its 552px health bar appear completely static.
    --
    -- For a griffin, convert incoming damage against a practical companion
    -- pool while subtracting the converted amount from the REAL native HP.
    -- Thus HP, HUD, downing and revival all continue to share one authority;
    -- this is not a cosmetic/virtual bar.
    local species = ""
    pcall(function()
        local pch = griffin_downed_is_protected(addr)
        species = tostring(go_name(char_go(pch)) or "")
    end)
    local mscale = tonumber(C.route3_companion_damage_scale) or 1.0
    if species:find("ch299011", 1, true) then
        mscale = tonumber(C.route3_mount_damage_scale) or 0.25
    elseif species:find("ch253", 1, true) then
        local maxhp = nil
        pcall(function() maxhp = tonumber(griffin_hp_max_from_component(rhc)) end)
        local effective = math.max(1.0,
            tonumber(C.route3_griffin_effective_hp) or 7000.0)
        if maxhp and maxhp > 0.0 then
            -- Never make a low-HP griffin tougher; cap pathological stat mods
            -- so one contact cannot overflow the damage packet.
            mscale = math.max(1.0, math.min(25.0, maxhp / effective))
        else
            mscale = 1.0
        end
    end
    if mscale > 0.0 and mscale < 1.0 and dmg > 0.0 then
        dmg = dmg * mscale
        pcall(function() di:set_field("Damage", dmg) end)
    end
    local floor = tonumber(C.route3_downed_floor_hp) or 1.0
    S.downed_budget = S.downed_budget or {}
    local fr = tonumber(S.downed_frame_id) or 0
    local b = S.downed_budget[addr]
    if not b or b.frame ~= fr then b = { frame = fr, spent = 0.0, hp0 = curhp }; S.downed_budget[addr] = b end
    local allowance = math.max(0.0, (tonumber(b.hp0) or curhp) - floor - (tonumber(b.spent) or 0.0))
    if dmg > allowance then
        pcall(function() di:set_field("Damage", allowance + 0.0) end)
        dmg = allowance
    end
    b.spent = (tonumber(b.spent) or 0.0) + dmg
    S.downed_clamp_dbg = string.format("%s dmg %.0f x%.2f (hp %.0f, budget %.0f)",
        species ~= "" and species or "companion", dmg, mscale, curhp, allowance)
    _G.IrisClampDbg = S.downed_clamp_dbg
    _G.IrisClampHits = (tonumber(rawget(_G, "IrisClampHits")) or 0) + 1
    -- r90: publish the RECEIVER's live HP so the ride diag can show it beside
    -- the GameObject's HitController reading. If those two disagree we have the
    -- two-store split; if they agree and neither falls, the engine is refusing
    -- to apply a damage value it has already accepted.
    _G.IrisHpSourceHp = curhp
    -- Some grafted horse bodies complete reaction calculation but never call
    -- updateDamageHp. Queue one short verification window: if this exact HP
    -- store has not moved by then, the frame tick applies the already-computed
    -- damage itself. Positive packets in the same impact window collapse to
    -- the strongest one so multi-region overlaps do not multiply a blow.
    if C.route3_damage_fallback ~= false and dmg > 0.0 then
        local now = os.clock()
        S.damage_fallback_next = S.damage_fallback_next or {}
        if now >= (tonumber(S.damage_fallback_next[addr]) or 0.0) then
            S.damage_fallback = S.damage_fallback or {}
            local q = S.damage_fallback[addr]
            if q and now < (tonumber(q.due) or 0.0) then
                q.damage = math.max(tonumber(q.damage) or 0.0, dmg)
            else
                S.damage_fallback[addr] = {
                    hc = rhc, hp0 = curhp, damage = dmg,
                    due = now + 0.08,
                }
            end
        end
    end
    -- Entry is decided from the receiver's post-application HP in the frame
    -- tick. Predicting it here is wrong when another hook scales args[4].
end

function griffin_downed_matches_active_character(ch)
    if not ch then return false, nil end
    local active = reacquire_griffin()
    if not active then return false, nil end
    local caddr, aaddr = nil, nil
    pcall(function() caddr = char_go(ch):get_address() end)
    pcall(function() aaddr = char_go(active):get_address() end)
    return caddr ~= nil and aaddr ~= nil and caddr == aaddr, caddr
end

function griffin_downed_install_death_guards()
    -- HP-floor clamping is necessary but not sufficient for lethal falls. DD2 also runs a native
    -- death-state callback using the original impact classification; that callback killed Aurora's
    -- 1-HP griffin and paid out its boss XP even though our downed tick subsequently revived it.
    -- The active companion has its OWN incapacitation contract, so refuse the native death callback,
    -- restore the floor immediately and queue normal downed entry for the next safe frame.
    if not _G.IrisCompanionDeathGuard_v3 then
        pcall(function()
            local td = sdk.find_type_definition("app.Character")
            local die = td and td:get_method("onDieFromAttack(app.HitController.DamageInfo)")
            if not die then return end
            sdk.hook(die, function(args)
                local ch, di = nil, nil
                pcall(function() ch = sdk.to_managed_object(args[2]) end)
                pcall(function() di = sdk.to_managed_object(args[3]) end)
                local ours, addr = griffin_downed_matches_active_character(ch)
                if not ours then return end
                local hc = griffin_downed_hit_controller(ch, addr)
                local winged_fall = griffin_downed_is_winged_fall(addr, di)
                if winged_fall then
                    -- Restore the last healthy pre-impact sample, not the 1-HP
                    -- down floor. Otherwise the ordinary floor detector downs a
                    -- griffin even though this callback itself was refused.
                    local restore = tonumber((S.last_safe_hp or {})[addr])
                    if not restore or restore <= 1.0 then
                        restore = tonumber(hc and griffin_hp_max_from_component(hc))
                    end
                    griffin_downed_set_hp(hc, math.max(1.0, restore or 1.0))
                    S.downed_pending_enter = S.downed_pending_enter or {}
                    S.downed_pending_enter[addr] = nil
                else
                    griffin_downed_set_hp(hc,
                        math.max(1.0, tonumber(C.route3_downed_floor_hp) or 1.0))
                    S.downed_pending_enter = S.downed_pending_enter or {}
                    S.downed_pending_enter[addr] = true
                end
                S.native_death_refused = (tonumber(S.native_death_refused) or 0) + 1
                pcall(function()
                    log.info(winged_fall
                        and "[IrisDowned] refused native fall death for winged companion"
                        or "[IrisDowned] refused native death for active companion; queued DOWN")
                end)
                return sdk.PreHookResult.SKIP_ORIGINAL
            end, function(retval) return retval end)
            _G.IrisCompanionDeathGuard_v3 = true
        end)
    end

    -- Defence in depth: the active companion's ExpGranter must never reward the party. This is
    -- scoped by managed-object identity, not species or a timing window, so ordinary griffins and
    -- simultaneous enemy kills retain their XP. If another engine death route bypasses
    -- onDieFromAttack, this still prevents the spectacular self-pet boss payout Aurora observed.
    if not _G.IrisCompanionExpGuard_v1 then
        pcall(function()
            local td = sdk.find_type_definition("app.ExpDispenser.ExpGranter")
            local eval = td and td:get_method("evaluateExpAmount")
            if not eval then return end
            local blocked = false
            sdk.hook(eval, function(args)
                blocked = false
                local granter = nil
                pcall(function() granter = sdk.to_managed_object(args[2]) end)
                local active = reacquire_griffin()
                local active_granter = nil
                pcall(function() active_granter = active and active:call("tryGetExpGranter") end)
                local ga, aa = nil, nil
                pcall(function() ga = granter and granter:get_address() end)
                pcall(function() aa = active_granter and active_granter:get_address() end)
                if ga and aa and ga == aa then
                    blocked = true
                    S.companion_exp_refused = (tonumber(S.companion_exp_refused) or 0) + 1
                    return sdk.PreHookResult.SKIP_ORIGINAL
                end
            end, function(retval)
                if blocked then blocked = false; return sdk.to_ptr(0) end
                return retval
            end)
            _G.IrisCompanionExpGuard_v1 = true
        end)
    end

    -- evaluateExpAmount is not the award route used by a native monster death.
    -- calcExp receives the actual victim as its third managed argument (args[4]
    -- for this static method). Refuse that calculation for the active companion
    -- before a boss-sized reward can be posted to the party.
    if not _G.IrisCompanionCalcExpGuard_v2 then
        pcall(function()
            local td = sdk.find_type_definition("app.ExpDispenser")
            local calc = td and td:get_method(
                "calcExp(app.HitController.DamageInfo, app.ExpDispenser.ExpGranter, app.Character, app.Character)")
            if not calc then return end
            sdk.hook(calc, function(args)
                local victim = nil
                pcall(function() victim = sdk.to_managed_object(args[4]) end)
                local ours = griffin_downed_matches_active_character(victim)
                if ours then
                    thread.get_hook_storage().iris_companion_xp_block = true
                    S.companion_exp_refused =
                        (tonumber(S.companion_exp_refused) or 0) + 1
                    return sdk.PreHookResult.SKIP_ORIGINAL
                end
            end, function(retval)
                local hs = thread.get_hook_storage()
                if hs.iris_companion_xp_block == true then
                    hs.iris_companion_xp_block = nil
                    return sdk.to_ptr(0)
                end
                return retval
            end)
            _G.IrisCompanionCalcExpGuard_v2 = true
        end)
    end
end

-- ⭐⭐⭐ THE FRIENDLY-FIRE ATTACKER SET (2026-08-14 -- Aurora: "make the tame animals summoned
-- via the stable not take damage from the Arisen/Pawns but still take damage from enemies").
-- ⛔ REBUILT WHOLESALE ON A CADENCE, NEVER PATCHED INCREMENTALLY -- the engine REUSES GameObject
-- addresses, so a stale entry in here would silently hand some unrelated body free hits on your
-- companion. That is the same law griffin_downed_protected_refresh states for the protected set,
-- and it is the reason this is a rebuild rather than an add/remove.
function griffin_friendly_attackers_refresh(force)
    local now = os.clock()
    if force ~= true and now < (tonumber(S.friendly_atk_at) or 0.0) then
        return S.friendly_atk or {}
    end
    S.friendly_atk_at = now + 1.0
    local set = {}
    pcall(function()
        local pgo = char_go(get_player())
        local a = pgo and pgo:get_address()
        if a then set[a] = "arisen" end
    end)
    -- ⭐ The getter ladder is FIELD-PROVEN, not guessed: the unicorn blessing logs
    -- "blessing: pawn list via get_AlivePawnCharacterList (N)" on every single cast.
    -- ⛔ get_PartyPawnList returns List<app.Pawn> whose items have NO get_GameObject (dump-verified
    -- 08-12, "pawn 0 -> invalid GO"); only the CharacterList getters return real app.Character.
    pcall(function()
        local pm = sdk.get_managed_singleton("app.PawnManager")
        if not pm then return end
        for _, getter in ipairs({"get_AlivePawnCharacterList", "get_PawnCharacterList"}) do
            local list = nil
            if pcall(function() list = pm:call(getter) end) and list then
                local count = 0
                pcall(function() count = tonumber(list:call("get_Count")) end)
                for i = 0, (count or 0) - 1 do
                    pcall(function()
                        local chr = list:call("get_Item", i)
                        local go = chr and chr:call("get_GameObject")
                        local a = go and go:get_address()
                        if a then set[a] = "pawn" end
                    end)
                end
                return
            end
        end
    end)
    S.friendly_atk = set
    return set
end

-- Returns "arisen" / "pawn" when THIS damage packet was dealt by the player or one of her pawns,
-- else nil.
-- ⛔ IT FAILS OPEN BY DESIGN. Every unreadable/ambiguous case returns nil and the damage proceeds
-- normally. A shield that guesses would make a companion quietly invulnerable to something it is
-- supposed to fear, which is a far worse bug than the occasional friendly hit getting through.
function griffin_downed_friendly_attacker(di)
    if not di then return nil end
    -- ⭐ THE LADDER IS TAKEN VERBATIM FROM IrisTaming's strike hook (IrisTaming.lua:3303-3313),
    -- which is FIELD-PROVEN in this game: it is what flips a courtship into the combat tame when
    -- Aurora swings at a wolf. Every tier normalises to a GAMEOBJECT, matching the set's key class
    -- ("DamageInfo speaks GameObjects", IrisTaming.lua:3292) -- ⛔ never compare a Character addr
    -- against a GameObject addr.
    -- ⚠ DO NOT "correct" these names against a field dump: they are auto-property BACKING FIELDS
    -- and do not appear in DamageInfo's get_fields() enumeration at all. MOD_damageinfo_fields.json
    -- lists 81 fields and not one of them is an attacker -- yet this ladder demonstrably works.
    local ago = nil
    pcall(function() ago = di:get_field("<AttackOwnerObject>k__BackingField") end)
    -- A shell's AttackOwnerObject can be the detached spell/VFX GameObject.
    -- CachedShell.OwnerCharacter is the authoritative caster, so prefer it even
    -- when AttackOwnerObject was readable. This is essential for ch257 magic:
    -- otherwise her own shell reaches the companion clamp as hostile damage.
    pcall(function()
        local ahc = di:get_field("<AttackHitController>k__BackingField")
        local shell = ahc and ahc:get_field("<CachedShell>k__BackingField")
        local owner = shell and shell:get_field("<OwnerCharacter>k__BackingField")
        local owner_go = owner and owner:call("get_GameObject")
        if owner_go then ago = owner_go end
    end)
    if not ago then
        pcall(function()
            local ahc = di:get_field("<AttackHitController>k__BackingField")
            local ach = ahc and ahc:get_field("<CachedCharacter>k__BackingField")
            ago = ach and ach:call("get_GameObject")
        end)
    end
    if not ago then
        pcall(function() ago = di:get_field("<AttackGameObject>k__BackingField") end)
    end
    if not ago then return nil end
    local aaddr = nil
    pcall(function() aaddr = ago:get_address() end)
    if not aaddr then return nil end
    if aaddr == tonumber(S.route3_combat_self_addr)
        and (type(S.route3_drake_attack) == "table"
            or S.route3_drake_sprint_hit_active == true
            or os.clock() <= (tonumber(S.route3_drake_self_guard_until) or 0.0)) then
        return "mount self"
    end
    return (griffin_friendly_attackers_refresh() or {})[aaddr]
end

-- one receipt on the first block, then one every 20th -- enough to prove it is live in the log
-- without drowning it during a fight.
function griffin_downed_note_friendly_block(who, where)
    local n = (tonumber(S.friendly_blocks) or 0) + 1
    S.friendly_blocks = n
    S.friendly_last = string.format("%s (%s)", tostring(who), tostring(where))
    if n == 1 or (n % 20) == 0 then
        log.info(string.format(
            "[IrisDowned] friendly fire ignored: %s hit your companion (%s) -- %d blocked",
            tostring(who), tostring(where), n))
    end
end

function griffin_downed_install_hook()
    -- The shield lives HERE, not in IrisTaming: the roster/stable/downed machinery is all in
    -- this file, and a protection this load-bearing must not depend on the other script being
    -- loaded, load-ordered first, and error-free. IrisTaming's courtship clamp is untouched.
    -- ⛔⛔ GUARD NAME IS A VERSION NUMBER, NOT A NAME. sdk.hook installs PERSIST across
    -- script reloads -- they only die with the process -- and this _G flag stops them
    -- STACKING. The trap: the flag also pins the OLD closure, so editing the hook body
    -- and reloading changes nothing at all until the guard name changes too.
    -- _v2 = fall shield. _v3 = hit-reaction flag + field dump. _v4 (r70) = ConvertedHitBackDir capture.
    -- _v8 = active-griffin winged-fall immunity at both DamageInfo and HP-subtraction stages.
    -- _v9 = resolve grafted/child HitControllers back to the canonical companion address.
    -- _v10 (08-14) = FRIENDLY FIRE SHIELD at both the reaction and HP-subtraction stages.
    -- Bump on every behaviour
    -- change in here, or test in-game against a closure that no longer exists.
    griffin_downed_install_death_guards()
    if _G.IrisDownedHookInstalled_v10 then return true end
    local ok = pcall(function()
        local td = sdk.find_type_definition("app.HitController")
        local m = td and td:get_method("calcDamageReaction(app.HitController.DamageInfo)")
        if not m then return end
        sdk.hook(m, function(args)
            local di = nil
            pcall(function() di = sdk.to_managed_object(args[3]) end)
            if not di then return end
            -- The receiver is args[2]. DamageInfo.DamageGameObject is NOT a
            -- trustworthy victim oracle for hand-built outgoing attacks: when
            -- omitted it can resolve to the companion's attack/source object.
            -- That cached the kicked pig's HitController under the horse's GO
            -- address, so the horse HUD mirrored pig HP and could falsely down.
            local dgo, daddr = nil, nil
            pcall(function()
                local receiver = sdk.to_managed_object(args[2])
                dgo = receiver and receiver:call("get_GameObject")
                daddr = dgo and dgo:get_address()
            end)
            -- Only fall back when the receiver genuinely exposes no owner.
            if not daddr then
                pcall(function()
                    dgo = di:get_field("<DamageGameObject>k__BackingField")
                    daddr = dgo and dgo:get_address()
                end)
            end
            if not daddr then return end
            -- ⭐ 08-09 FALL SHIELD (Aurora: rode off a big drop, horse went down,
            -- she landed on a sliver of health). While you are MOUNTED the animal
            -- takes the landing -- it is the one whose legs hit the ground, and it
            -- is the one that got downed. The rider eating a near-lethal hit on top
            -- of that is double-billing the same impact.
            -- ⛔ Deliberately narrow: player only, fall damage only (types 14/15,
            -- the pair Bestiary uses for exactly this test), and only while
            -- actually mounted. Every other hit the Arisen takes is untouched.
            if C.route3_fall_shield_enabled ~= false then
                pcall(function()
                    local pgo = char_go(get_player())
                    if not (pgo and pgo:get_address() == daddr) then return end
                    local dt = tonumber(di:get_field("DamageType"))
                    if not (dt == 14 or dt == 15) then return end
                    local api = rawget(_G, "IrisHorseMount")
                    if not (api and api.is_mounted and api.is_mounted() == true) then
                        return
                    end
                    local dmg = tonumber(di:get_field("Damage")) or 0.0
                    if dmg <= 0.0 then return end
                    local frac = tonumber(C.route3_fall_shield_frac) or 0.15
                    frac = math.max(0.0, math.min(1.0, frac))
                    di:set_field("Damage", dmg * frac)
                    S.fall_shield_dbg = string.format(
                        "fall %.0f -> %.0f (mounted)", dmg, dmg * frac)
                end)
            end
            if C.route3_downed_enabled ~= true then return end
            local receiver = nil
            pcall(function() receiver = sdk.to_managed_object(args[2]) end)
            local protected_addr = griffin_downed_resolve_receiver(receiver, daddr)
            if not protected_addr then return end
            -- ⭐⭐ FRIENDLY FIRE (08-14): the Arisen and her pawns cannot hurt their own companion.
            -- Zeroing here is what suppresses the FLINCH -- this file's own rule two lines down is
            -- that a zero-damage packet "is not a hit and must not manufacture a flinch", so the
            -- animal simply ignores the blow instead of staggering for nothing. The authoritative
            -- HP subtraction is a different argument entirely and is stopped in updateDamageHp.
            local who = griffin_downed_friendly_attacker(di)
            if who and (who == "mount self" or C.route3_friendly_fire_shield ~= false) then
                pcall(function()
                    di:set_field("Damage", 0.0)
                    di:set_field("FixedDamage", 0.0)
                end)
                griffin_downed_note_friendly_block(who, "reaction")
                return
            end
            -- Scale/clamp before raising visual state. A zero-damage overlap
            -- packet is not a hit and must not manufacture a flinch.
            griffin_downed_clamp(args, di, protected_addr)
            local applied = 0.0
            pcall(function() applied = tonumber(di:get_field("Damage")) or 0.0 end)
            if applied <= 0.0 then return end
            -- ⛔ FLAG ONLY, NEVER PLAY FROM IN HERE. The file's own law two
            -- functions down: never transition from inside a native damage hook
            -- (re-entrancy). The tick picks this up next frame.
            S.hit_react_addr = protected_addr
            S.hit_react_deadline = os.clock() + 2.5
            -- ⭐ r70: DIRECTION, straight from the engine. The field dump
            -- (MOD_damageinfo_fields.json, 81 fields) turned up
            -- ConvertedHitBackDir -- DD2's OWN conversion of the incoming hit
            -- into a hitback direction, which is precisely the axis our
            -- F/B/L/R clips are indexed on. No attacker position maths needed.
            -- ⚠ The enum's values are not documented anywhere I can check, so
            -- the mapping below is a first pass AND every distinct value is
            -- logged once -- a wrong guess costs a flinch facing the wrong way,
            -- never a crash, and the log tells us how to correct it.
            pcall(function()
                local hd = di:get_field("ConvertedHitBackDir")
                if hd == nil then return end
                S.hit_react_dir = tonumber(hd)
                S.hit_dir_seen = S.hit_dir_seen or {}
                local k = tostring(hd)
                if not S.hit_dir_seen[k] then
                    S.hit_dir_seen[k] = true
                    log.info("[IrisDowned] ConvertedHitBackDir value seen: " .. k)
                end
            end)
            -- one-shot field dump so we can learn where the ATTACKER lives on
            -- DamageInfo. Until we know, the flinch defaults to the front clip.
            if S.hit_react_dumped ~= true then
                S.hit_react_dumped = true
                pcall(function()
                    local names = {}
                    for _, fl in ipairs(di:get_type_definition():get_fields() or {}) do
                        names[#names + 1] = tostring(fl:get_name())
                    end
                    json.dump_file(MOD .. "_damageinfo_fields.json",
                        { fields = names })
                    log.info("[IrisDowned] DamageInfo fields: "
                        .. table.concat(names, ", "))
                end)
            end
        end, function(r) return r end)
        -- DamageInfo.Damage is reaction input; updateDamageHp receives the
        -- authoritative HP subtraction as a separate argument. Clamp that
        -- value too, on the actual receiver, otherwise a valid hit can cross
        -- the revive floor even though calcDamageReaction was made safe.
        local mhp = td:get_method("updateDamageHp")
        if mhp then
            sdk.hook(mhp, function(args)
                pcall(function()
                    if C.route3_downed_enabled ~= true then return end
                    local hc = sdk.to_managed_object(args[2])
                    local go = hc and hc:call("get_GameObject")
                    local addr = go and go:get_address()
                    local protected_addr = griffin_downed_resolve_receiver(hc, addr)
                    if not protected_addr then return end
                    S.hp_source = S.hp_source or {}
                    S.hp_source[protected_addr] = hc
                    local di = nil
                    pcall(function() di = sdk.to_managed_object(args[3]) end)
                    if griffin_downed_is_winged_fall(protected_addr, di) then
                        args[4] = sdk.float_to_ptr(0.0)
                        S.griffin_fall_hp_ignored =
                            (tonumber(S.griffin_fall_hp_ignored) or 0) + 1
                        return
                    end
                    -- ⭐⭐ FRIENDLY FIRE, THE AUTHORITATIVE HALF. ⛔ This is the one that actually
                    -- matters: DamageInfo.Damage is only the REACTION input -- HP is subtracted from
                    -- args[4], a separate argument, which is why the block above it exists in the
                    -- same shape for winged falls. Zeroing the field without zeroing args[4] would
                    -- have looked correct and changed nothing about the HP loss.
                    local who = griffin_downed_friendly_attacker(di)
                    if who and (who == "mount self" or C.route3_friendly_fire_shield ~= false) then
                        args[4] = sdk.float_to_ptr(0.0)
                        griffin_downed_note_friendly_block(who, "hp")
                        return
                    end
                    local hp = tonumber(hc:call("get_Hp"))
                    local amount = sdk.to_float(args[4])
                    if not (hp and amount and amount > 0.0) then return end
                    local floor = tonumber(C.route3_downed_floor_hp) or 1.0
                    local allowed = math.max(0.0, hp - floor)
                    if amount > allowed then
                        amount = allowed
                        args[4] = sdk.float_to_ptr(amount)
                    end
                end)
            end, function(r) return r end)
        end
        _G.IrisDownedHookInstalled_v10 = true
    end)
    return ok and _G.IrisDownedHookInstalled_v10 == true
end
function griffin_downed_request_node(ch, node, prio)
    -- generic (not griffin-bound) requestActionCore. ⛔ Never verify the slot in this frame --
    -- the action list is not populated until a frame or two later.
    if not (ch and node and tostring(node) ~= "") then return false end
    local am = nil
    pcall(function() am = ch:call("get_ActionManager") end)
    if not am then pcall(function() am = ch:get_field("<ActionManager>k__BackingField") end) end
    if not am then return false end
    S.route3_self_action = true
    local ok = pcall(function()
        am:call("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)",
            tonumber(prio) or 0, tostring(node), 0)
    end)
    S.route3_self_action = false
    return ok
end
function griffin_downed_mark_record(flag)
    -- persist "a companion was DOWNED when we last ran" so a crash/reset can be recovered on
    -- boot. Without this the boot sweep cannot tell a legitimately think-stopped companion
    -- from an orphaned downed one, and would clobber other features' leases.
    pcall(function()
        local rec = griffin_stable_active()
        if type(rec) ~= "table" then return end
        rec.was_downed = (flag == true) or nil
        griffin_stable_write()
    end)
end

-- The downed-pawn ping is owned by GuiManager's minimap registry, not by a
-- component on the pawn. Clone a native, already-valid MapIconInfo (the game's
-- validation silently rejects hand-built ones), mint our own UniqueID, and keep
-- its position attached to the downed companion. When a real pawn goes down we
-- also learn that exact icon as the preferred template; until then any native
-- minimap icon is a safe, visible fallback.
local function griffin_downed_map_pos(go)
    local pos = nil
    pcall(function()
        pos = go:call("get_Transform"):call("get_UniversalPosition")
    end)
    return pos
end

local function griffin_downed_map_write_pos(info, pos)
    if not (info and pos) then return false end
    local ok = pcall(function()
        local v = ValueType.new(sdk.find_type_definition("via.vec3"))
        v:set_field("x", pos.x)
        v:set_field("y", pos.y)
        v:set_field("z", pos.z)
        info:set_field("Pos", v)
    end)
    if not ok then
        ok = pcall(function()
            info:set_field("Pos", Vector3f.new(pos.x, pos.y, pos.z))
        end)
    end
    return ok
end

function griffin_downed_map_learn()
    if S.downed_map_template then return end
    local now = os.clock()
    if now < (tonumber(S.downed_map_learn_at) or 0.0) then return end
    S.downed_map_learn_at = now + 1.0
    local ok, learned = pcall(function()
        local gui = sdk.get_managed_singleton("app.GuiManager")
        local icons = gui and gui:call("getMiniMapIconList")
        local count = icons and tonumber(icons:call("get_Count")) or 0
        if count <= 0 then return end

        local sm = sdk.get_native_singleton("via.SceneManager")
        local smt = sdk.find_type_definition("via.SceneManager")
        local scene = sm and sdk.call_native_func(sm, smt, "get_CurrentScene")
        local chars = scene and scene:call("findComponents(System.Type)",
            sdk.typeof("app.Character"))
        local pawn_pos = nil
        for _, ch in ipairs(chars and chars:get_elements() or {}) do
            local go = ch and ch:call("get_GameObject")
            local name = go and tostring(go:call("get_Name") or "") or ""
            if name:sub(1, 3) == "ch1" then
                local down = false
                for _, getter in ipairs({ "get_IsDown", "get_IsDead",
                    "get_IsDying" }) do
                    local gok, value = pcall(function() return ch:call(getter) end)
                    if gok and value == true then down = true; break end
                end
                if down then pawn_pos = griffin_downed_map_pos(go); break end
            end
        end
        if not pawn_pos then return end

        local best, best_d2 = nil, 64.0
        for i = 0, count - 1 do
            local info = icons:call("get_Item", i)
            local p = info and info:get_field("Pos")
            if p then
                local dx, dy, dz = p.x - pawn_pos.x,
                    p.y - pawn_pos.y, p.z - pawn_pos.z
                local d2 = dx * dx + dy * dy + dz * dz
                -- The transient down ping is normally appended after the
                -- pawn's persistent party icon at the same coordinates.
                if d2 <= best_d2 then best, best_d2 = info, d2 end
            end
        end
        if not best then return end
        local copy = sdk.create_instance("app.GuiManager.MapIconInfo"):add_ref()
        copy:call(".ctor(app.GuiManager.MapIconInfo)", best)
        S.downed_map_template = copy
        S.downed_map_template_type = tostring(best:get_field("IconType"))
        S.downed_map_template_id = tostring(best:get_field("IconId"))
        learned = true
    end)
    if ok and learned then
        log.info("[IrisDowned] learnt native pawn-down minimap icon type="
            .. tostring(S.downed_map_template_type) .. " id="
            .. tostring(S.downed_map_template_id))
        -- Upgrade a companion that went down before the template was learnt.
        for _, e in pairs(griffin_downed_state()) do
            pcall(function()
                griffin_downed_map_remove(e)
                griffin_downed_map_add(e)
            end)
        end
    end
end

function griffin_downed_map_add(e)
    if not e or e.map_uid then return true end
    local ok, err = pcall(function()
        local gui = sdk.get_managed_singleton("app.GuiManager")
        local list = gui and gui:call("getMiniMapIconList")
        local count = list and tonumber(list:call("get_Count")) or 0
        if not gui or count <= 0 then error("no native minimap template available") end
        local src = S.downed_map_template or list:call("get_Item", 0)
        if not src then error("native minimap template was nil") end
        local info = sdk.create_instance("app.GuiManager.MapIconInfo"):add_ref()
        info:call(".ctor(app.GuiManager.MapIconInfo)", src)
        local make = sdk.find_type_definition("app.UniqueID")
            :get_method("makeNewUniqueID")
        local uid = make and make:call(nil)
        if not uid then error("could not mint minimap UniqueID") end
        info:set_field("UniqId", uid)
        info:set_field("IsEnable", true)
        info:set_field("IsDispAllArea", true)
        if not griffin_downed_map_write_pos(info,
            griffin_downed_map_pos(e.go)) then
            error("could not write minimap position")
        end
        gui:call("addMapIcon(app.GuiManager.MapIconInfo)", info)
        e.map_uid, e.map_info = uid, info
        e.map_next_retry = nil
    end)
    if not ok then
        e.map_next_retry = os.clock() + 1.0
        if e.map_last_error ~= tostring(err) then
            e.map_last_error = tostring(err)
            log.info("[IrisDowned] minimap registration deferred: "
                .. tostring(err))
        end
        return false
    end
    log.info("[IrisDowned] downed-companion minimap ping registered"
        .. (S.downed_map_template and " (pawn-down glyph)" or " (native fallback glyph)"))
    return true
end

function griffin_downed_map_remove(e)
    if not (e and e.map_uid) then return end
    pcall(function()
        local gui = sdk.get_managed_singleton("app.GuiManager")
        if gui then gui:call("removeMapIcon(app.UniqueID)", e.map_uid) end
    end)
    e.map_uid, e.map_info = nil, nil
end
function griffin_downed_reassert(e)
    -- ⛔ HOLD, don't SET -- runs EVERY frame while down. A native getup/revive silently
    -- re-enables these (route3_grab_reassert_ground_components exists for the same reason).
    if not e then return end
    pcall(function() route3_grab_set_immunity(e.ch, true) end)
    for _, tn in ipairs({ "app.AIDecisionMaker", "app.NavigationAI" }) do
        local c = get_component(e.go, tn)
        if c then pcall(function() c:call("set_Enabled", false) end) end
    end
    -- ⭐ CLAIM THE BASE LAYER (this file's own designed mechanism, :3084) -- while a companion
    -- is DOWNED we own its animation, so play_griffin_motion's idle driver (:3537) can't repaint
    -- over the collapse. Refreshed every frame; the stale timeout means a leaked claim expires
    -- on its own rather than wedging the whole animation system.
    S.base_owner = { name = "downed", until_clock = os.clock() + 2.0 }
    -- HOLD the down node too. ⛔ Only re-request when we are NOT already in it -- firing it
    -- every frame would pin the clip at frame 0 (a frozen pose, not a collapse). ⛔ And never
    -- read the slot in the frame we requested: it populates a frame or two later.
    local now = os.clock()
    if now >= (tonumber(e.node_check_at) or 0.0) then
        e.node_check_at = now + 0.5
        local want = tostring(C.route3_downed_clip_node or "")
        if want ~= "" then
            local leaf = tostring(want:match("([^%.]+)$") or want)
            local slot = "?"
            pcall(function()
                local am = nil
                pcall(function() am = e.ch:call("get_ActionManager") end)
                if not am then pcall(function() am = e.ch:get_field("<ActionManager>k__BackingField") end) end
                local lst = am and am:get_field("CurrentActionList")
                local a0 = lst and lst:call("get_Item", 0)
                slot = a0 and tostring(a0:call("ToString()")) or "nil"
            end)
            e.slot = slot
            local node_took = tostring(slot):find(leaf, 1, true) ~= nil
            if not node_took then
                griffin_downed_request_node(e.ch, want, 0)
                e.node_refires = (tonumber(e.node_refires) or 0) + 1
            end
            -- ⭐ 08-09 CLIP FALLBACK. Only once the node has had its grace period
            -- AND is measurably not holding. While the node IS holding we touch
            -- nothing -- it is the proven-safe path and it wins.
            if C.route3_downed_clip_fallback ~= false and e.clip
                and not node_took
                and now >= (tonumber(e.clip_at) or math.huge) then
                local cl = e.clip
                if e.clip_stage == nil then
                    if cl.die then
                        iris_play_clip(e.ch, cl.bank, cl.die, 0.15)
                        e.clip_stage = "die"
                        -- die clips run ~1.5s; the atlas endframes are all 0 so
                        -- they cannot be read from there (see the atlas memory)
                        e.clip_loop_at = now + 1.5
                    elseif cl.loop then
                        iris_play_clip(e.ch, cl.bank, cl.loop, 0.15)
                        e.clip_stage = "loop"
                    end
                elseif e.clip_stage == "die" and cl.loop
                    and now >= (tonumber(e.clip_loop_at) or math.huge) then
                    -- settle into the hold pose; it LOOPS, so never re-fire it
                    -- (re-firing would pin it at frame 0 = a frozen statue)
                    iris_play_clip(e.ch, cl.bank, cl.loop, 0.25)
                    e.clip_stage = "loop"
                end
            end
        end
    end
    -- pin HP at the floor: damage-over-time that never passes through calcDamageReaction
    -- would otherwise grind a downed body into a true corpse under the revive prompt.
    local hc = griffin_downed_hit_controller(e.ch, e.addr)
    if not hc then return end
    local cur = nil
    pcall(function() cur = hc:call("get_Hp") end)
    local floor = tonumber(C.route3_downed_floor_hp) or 1.0
    if (not tonumber(cur)) or tonumber(cur) < floor then
        griffin_downed_set_hp(hc, floor)
    end
end
function griffin_downed_release(e, reason)
    -- ⭐ THE ONE CANONICAL UNWIND. Every exit path calls this -- revive, timeout, invalid body,
    -- feature disabled, script reset. Idempotent and safe to call twice.
    if not e then return end
    griffin_downed_map_remove(e)
    if e.addr then
        griffin_downed_state()[e.addr] = nil
        if type(_G.IrisDownedAddrs) == "table" then _G.IrisDownedAddrs[e.addr] = nil end
        -- ⛔⛔ 08-17 (Aurora: "they get back up briefly and then lie back down again") -- THE
        -- INSTANT RE-DOWN LOOP. The floor detector (~:1780) downs a body when its HP sits at the
        -- floor, gated on `seen_above` = "we witnessed this body above the floor". Its own comment
        -- states the rule as **a witnessed fall from above the floor** -- but S.last_safe_hp was
        -- written in exactly ONE place and cleared in NONE, so that witness survived for the whole
        -- session. A body released at/near the floor therefore satisfied `seen_above` on the very
        -- next frame using evidence from BEFORE the down it just finished, and went straight back
        -- down: up, then down, then up, forever.
        -- ⇒ the witness dies with the down that consumed it. A re-down now needs the body to be
        -- seen healthy AGAIN first, which is what "a witnessed fall" meant all along.
        if type(S.last_safe_hp) == "table" then S.last_safe_hp[e.addr] = nil end
    end
    pcall(function() route3_grab_set_immunity(e.ch, false) end)
    -- ⛔⛔ 08-09 r67 -- CLEAR THE DOWN ACTION *BEFORE* THE AI COMES BACK.
    -- This unwind restored AIDecisionMaker and NavigationAI but left the body
    -- parked in the damage-down action and on the down LOOP clip. So the moment
    -- the AI woke up it started issuing move commands to a body that was still
    -- lying in a Damage_Root state -- and DD2 crashed in
    -- app.actinter.cmd.move.MoveBase.updateImpl <- CommandExecutor.update
    -- <- Executor.update <- ActionInterface.update.
    -- Aurora hit it twice, and the visible tell was in the same breath: after
    -- reviving, "the horse was still lying on the ground" -- then walking it
    -- crashed ~5s later. Same root cause, one symptom you can see and one you
    -- cannot.
    -- ⛔ ORDER IS LOAD-BEARING: reset the action FIRST, re-enable the brain
    -- SECOND. The reverse just re-creates the race.
    -- r73: cut any pawn's follow reference to this body BEFORE its AI wakes up
    griffin_downed_clear_pawn_follow(e.go)
    -- resetActionAndAI rebuilds native decision/action executors. On a tamed,
    -- transform-driven body that is precisely what can issue the stale MoveBase
    -- command named by every revive CTD. Keep it as an explicit diagnostic only.
    if C.route3_downed_reset_action_on_release == true then
        griffin_downed_breadcrumb("release:reset_action (opt-in)", e)
        pcall(function() e.ch:call("resetActionAndAI") end)
    else
        griffin_downed_breadcrumb("release:reset_action SKIPPED", e)
    end
    -- Put the body back on a neutral clip when no verified get-up node owns it.
    -- bank 0 / 0 = com_idle_loop, read from the Animal Atlas by name and
    -- present on every chassis we drive.
    e.clip_stage = nil
    if tostring(C.route3_downed_getup_node or "") == "" then
        iris_play_clip(e.ch, 0, 0, 0.25)
    end
    -- ⛔⛔ 08-09 r81 -- THE REVIVE CTD IS THIS LINE, AND THE TRACE PROVES IT.
    -- Last breadcrumb before the crash: "post-revive +0.03s". The next stamp is
    -- +0.28s and never arrived -- so the game died within a couple of FRAMES of
    -- the AI being switched back on. And the player-component restore (my other
    -- suspect) happened TWELVE SECONDS earlier, so that is exonerated too.
    -- Stack is app.actinter.cmd.move.MoveBase.updateImpl every time: a MOVE
    -- COMMAND executing. The horse spent the whole downed window with its
    -- NavigationAI disabled while being knocked about by a boulder/cyclops --
    -- so its cached navigation state is stale, and re-enabling the brain in the
    -- same breath as the action reset lets a move command run against it before
    -- anything has re-established where the body actually is.
    -- ⭐ So the brain comes back LATE, on its own timer, after the reset and the
    -- idle clip have settled -- and only if the body is still valid, because
    -- other release paths (timeout -> dismiss) destroy it.
    S.downed_ai_pending = S.downed_ai_pending or {}
    S.downed_ai_pending[#S.downed_ai_pending + 1] = {
        go = e.go, ch = e.ch, name = tostring(e.name or "?"),
        at = os.clock() + (tonumber(C.route3_downed_ai_delay) or 0.6),
        wake = e.component_was_enabled,
    }
    griffin_downed_breadcrumb("release:ai_deferred", e)
    -- ⭐ r73: keep stamping for 4s AFTER the unwind. The last trace stopped dead
    -- at release:done, which told us our sequence finished but NOT how long the
    -- world survived it -- and the crash is downstream. Now the final entry
    -- says how many seconds past revive it got, which separates "died on the
    -- next frame" from "died when the AI first issued a move".
    S.rev_watch = { until_t = os.clock() + 4.0, at = 0.0,
        name = tostring(e.name or "?") }
    -- hand the base layer back so the normal idle/locomotion painters resume
    if type(S.base_owner) == "table" and S.base_owner.name == "downed" then S.base_owner = nil end
    if next(griffin_downed_state()) == nil then griffin_downed_mark_record(false) end
    log.info("[" .. MOD .. "] downed release (" .. tostring(reason or "?") .. ")")
end
function griffin_downed_release_all(reason)
    for _, e in pairs(griffin_downed_state()) do pcall(function() griffin_downed_release(e, reason) end) end
    S.downed = {}
    S.downed_pending_enter = nil
    S.downed_budget = nil
    _G.IrisDownedAddrs = {}
end
function griffin_downed_boot_sweep()
    -- ⛔ ORPHAN RECOVERY. A CTD / script reset / area change while a companion was DOWNED
    -- leaves the leases latched on the engine with no state left to unwind them. Gated on the
    -- persisted was_downed marker so we never clobber another feature's legitimate think-stop.
    S.downed = {}
    S.downed_pending_enter = nil
    S.downed_budget = nil
    _G.IrisDownedAddrs = {}
    local marked = false
    pcall(function()
        local rec = griffin_stable_active()
        marked = type(rec) == "table" and rec.was_downed == true
    end)
    if not marked then return end
    pcall(function()
        local ch = reacquire_griffin()
        if not ch then return end
        route3_grab_set_immunity(ch, false)
        -- There is no surviving record of which components were enabled before
        -- a CTD. Do not guess: tamed companions normally keep both AI systems
        -- disabled, and blindly waking them recreates the crash during recovery.
    end)
    griffin_downed_mark_record(false)
    status("recovered a companion left DOWNED by a reload -- leases cleared")
end
-- ⭐⭐ 08-09 -- DROWNING IS PERMANENT (Aurora: "it does give people more incentive
-- to go out and tame more creatures or breed them... but we need a big
-- notification if and when the creature is permanently gone").
-- ⛔⛔ THE GOVERNING RULE OF THIS WHOLE BLOCK: a FALSE POSITIVE here deletes a
-- companion forever. "We could not tell" must therefore ALWAYS resolve to "not
-- water". Every unknown, every failed call, every missing component returns
-- false. We would rather never trigger this than trigger it wrongly once.
local WATER_COMPONENTS = { "app.WaterSurfaceDetector", "app.WaterSurfaceChecker" }
-- ⚠ CANDIDATES, not confirmed API. app.WaterSurfaceDetector is real (it is in
-- rszdd2.json) but its getter names have NOT been verified in-game yet, which is
-- exactly why the probe below dumps the component's whole method list the first
-- time it ever sees one. Read that dump, then pin the real name here.
-- ⛔ Never add get_Enabled or similar to this list -- it is true whenever the
-- component exists and would drown everything.
local WATER_GETTERS = {
    "get_IsInWater", "isInWater", "get_InWater",
    "get_IsUnderWater", "get_IsUnderWaterSurface", "get_IsSubmerged",
}
function griffin_downed_in_water(go)
    if not go then return false end
    local verdict = nil
    for _, tn in ipairs(WATER_COMPONENTS) do
        local c = get_component(go, tn)
        if c then
            -- one-shot API dump so the NEXT test tells us the true getter name
            if S.downed_water_dumped ~= true then
                S.downed_water_dumped = true
                pcall(function()
                    local names = {}
                    local td = c:get_type_definition()
                    for _, m in ipairs(td:get_methods() or {}) do
                        names[#names + 1] = tostring(m:get_name())
                    end
                    log.info("[IrisDowned] " .. tn .. " methods: "
                        .. table.concat(names, ", "))
                    json.dump_file(MOD .. "_water_api.json",
                        { component = tn, methods = names })
                end)
            end
            for _, gm in ipairs(WATER_GETTERS) do
                local ok, v = pcall(function() return c:call(gm) end)
                if ok and type(v) == "boolean" then verdict = v; break end
            end
            if verdict ~= nil then break end
        end
    end
    return verdict == true
end
function griffin_downed_lost(e, reason)
    -- THE ONE PERMANENT EXIT. delete_griffin ends with
    -- griffin_stable_remove_active(), which table.remove()s the soul out of the
    -- stable for good -- the exact behaviour that used to fire by ACCIDENT on
    -- every 30s timeout and cost Aurora her horse Horz. Here it is deliberate,
    -- and here it is the point.
    if not e then return end
    local nm = tostring(e.name)
    griffin_downed_mark_record(false)
    griffin_downed_release(e, "LOST: " .. tostring(reason or "?"))
    pcall(function() delete_griffin() end)
    -- THE BIG NOTIFICATION. status() is panel-only and was invisible in play --
    -- the same complaint that put IrisTaming.prompt there in the first place.
    -- Ember red, and long enough to actually read.
    pcall(function()
        local api = rawget(_G, "IrisTaming")
        if api and api.prompt then
            api.prompt(nm .. " IS GONE",
                tostring(reason or "lost") .. " -- " .. nm
                .. " will not be coming back.",
                tonumber(C.route3_downed_lost_banner_secs) or 9.0,
                0xFFE0402A)
        end
    end)
    status(nm .. " IS GONE FOR GOOD (" .. tostring(reason or "?") .. ")")
    log.info("[IrisDowned] PERMANENT LOSS: " .. nm
        .. " (" .. tostring(reason or "?") .. ")")
end
function griffin_downed_stable_write_hp(e, hp)
    -- write-through persistence. Tolerates old records with no hp/hp_max fields.
    pcall(function()
        local rec = griffin_stable_active()
        if type(rec) ~= "table" then return end
        local mx = tonumber(rec.hp_max) or tonumber(e and e.maxhp) or 0.0
        if mx > 0 then rec.hp_max = mx end
        rec.hp = math.max(0.0, tonumber(hp) or 0.0)
        griffin_stable_write()
    end)
end
function griffin_downed_enter(addr)
    local st = griffin_downed_state()
    if st[addr] then return end                       -- edge-triggered: never re-enter
    local ch = griffin_downed_is_protected(addr)
    if not ch then return end
    local go = char_go(ch)
    if not go then return end
    local hc = griffin_downed_hit_controller(ch, addr)
    local e = {
        addr = addr, ch = ch, go = go, elapsed = 0.0, hold = 0.0,
        maxhp = tonumber(hc and griffin_hp_max_from_component(hc)) or 0.0,
        name = tostring(C.route3_griffin_name or "Your companion"),
    }
    -- Restore only components which this downed instance actually disabled.
    -- A tamed horse normally arrives with both already off; waking either one
    -- creates the stale native MoveBase executor behind the revive CTD.
    e.component_was_enabled = {}
    for _, tn in ipairs({ "app.AIDecisionMaker", "app.NavigationAI" }) do
        local c = get_component(go, tn)
        local enabled = nil
        if c then pcall(function() enabled = c:call("get_Enabled") end) end
        if enabled == true then e.component_was_enabled[tn] = true end
    end
    st[addr] = e
    -- cross-file: IrisTaming's play_motion refuses to touch layer 0 for a body in here, so its
    -- idle cycle stops stomping our collapse node.
    _G.IrisDownedAddrs = _G.IrisDownedAddrs or {}
    _G.IrisDownedAddrs[addr] = true
    griffin_downed_mark_record(true)
    -- ⭐ 08-09 -- THROW THE RIDER OFF FIRST, before anything disables components or
    -- claims the animation layer. Aurora fell down a big drop: the horse went DOWN,
    -- the bar came up, and she carried on riding it. You cannot ride a body that is
    -- playing its own death animation with its AI switched off -- and worse, the
    -- revive needs the player to be a separate actor NEXT TO it, not sat on it.
    -- ⛔ Order matters: dismount BEFORE griffin_downed_reassert, or the seat writer
    -- and the down-clip fight over the same body for a frame.
    e.clip = iris_down_clip_for(go)
    if C.route3_downed_force_dismount ~= false then
        pcall(function()
            local api = rawget(_G, "IrisHorseMount")
            if api and api.is_mounted and api.is_mounted(go) == true then
                e.was_ridden = true
                if api.dismount then api.dismount(go, "downed") end
                status(tostring(e.name) .. " went down under you")
            end
        end)
        pcall(function()
            local api = rawget(_G, "IrisGriffinBridge")
            if api and api.is_mounted and api.is_mounted(go) == true then
                e.was_ridden = true
                if api.dismount then api.dismount(go, "downed") end
                status(tostring(e.name) .. " went down under you")
            end
        end)
    end
    -- ⛔⛔⛔ 08-17 -- AND THROW THE PILOT OFF TOO. A SCOUT IS A RIDER BY ANY OTHER NAME.
    -- The block above has always thrown a rider off a downed mount for exactly the reason
    -- spelled out there: you cannot ride a body that is playing its own death animation with
    -- its AI switched off. A SCOUT DRONE is the same relationship -- the player is flying that
    -- body directly, writing its transform every frame, with the camera on it and the Arisen
    -- frozen and input-starved -- and it was never covered here. Aurora's crow dive-stole over
    -- the sea, the brine downed it mid-dive, the scout kept flying it, and the game CTD'd on
    -- two owners writing one action-claimed body.
    -- ⭐ Order matters exactly as it does for the dismount: this runs BEFORE griffin_downed_reassert
    -- and before anything disables components or claims the animation layer. IrisTaming's own
    -- watchdog catches this too, one frame later; this is the earliest frame that exists.
    -- (_G.IrisDownedAddrs[addr] is already true above, so the unwind over there correctly
    -- refuses to re-arm the shoulder perch on a downed bird.)
    pcall(function()
        local api = rawget(_G, "IrisTaming")
        if not (api and api.scout_abort) then return end
        local mine = true
        if api.is_scouting then
            local a = nil
            pcall(function() a = go:get_address() end)
            mine = (a ~= nil) and api.is_scouting(a) == true
        end
        if not mine then return end          -- a DIFFERENT companion went down: leave the flight alone
        if api.scout_abort("your companion went down") then
            e.was_scouted = true
            status(tostring(e.name) .. " went down while you were flying it")
            log.info("[IrisDowned] scout drone ENDED: the bird being flown went down")
        end
    end)
    griffin_downed_reassert(e)
    griffin_downed_map_add(e)
    -- PROVEN on the rabbit 07-21: a Damage-tree down node fires safely on a FRIENDLY body.
    pcall(function() griffin_downed_request_node(ch, C.route3_downed_clip_node, 0) end)
    -- ⭐ THE DEATH ANIMATION. The FSM node above is the primary and stays the primary
    -- -- it is the one route proven safe on a friendly body, and it is not being
    -- replaced. This is a FALLBACK for when the node does not take (reassert already
    -- measures that, in e.slot): drop to the species' own verified die clip, which
    -- then settles into its down loop. Species with no die clip go straight to the
    -- loop. If neither exists we simply keep whatever the node did.
    e.clip_at = os.clock() + 1.0
    status(string.format("%s is DOWN -- hold the revive key within %ds",
        e.name, math.floor(tonumber(C.route3_downed_window_secs) or 30.0)))
end
function griffin_downed_clear_pawn_follow(go)
    -- ⛔ 08-09 r73 -- THE REVIVE CTD NAMES A PAWN, NOT THE HORSE.
    -- Full stack: via.GameObject.getSameComponent <- app.Pawn.setFollowObject
    -- (x3) <- app.actinter.cmd.move.MoveBase.updateImpl <- CommandExecutor
    -- <- Executor <- app.ActionInterface.update.
    -- So during a move command a PAWN re-points its follow target and derefs
    -- null on that object's components. The revive breadcrumb proves our own
    -- sequence completed cleanly (enter -> reset_action -> ai_on -> done), so
    -- the crash is downstream of us: something still holds a follow reference
    -- to a body whose AI and components we have just been toggling.
    -- ⚠ This is a MITIGATION, not a confirmed cure -- I cannot see which object
    -- the engine passes. But a pawn following a body that was just downed,
    -- component-toggled and revived is a genuine hazard regardless, and cutting
    -- that reference costs nothing if it was not the cause.
    if not go then return 0 end
    local addr = nil
    pcall(function() addr = go:get_address() end)
    if not addr then return 0 end
    local n = 0
    pcall(function()
        local pm = sdk.get_managed_singleton("app.PawnManager")
        if not pm then return end
        for _, getter in ipairs({ "get_PawnCharacterList",
            "get_AlivePawnCharacterList" }) do
            local list = nil
            pcall(function() list = pm:call(getter) end)
            local cnt = 0
            pcall(function() cnt = list and list:call("get_Count") or 0 end)
            for i = 0, (tonumber(cnt) or 0) - 1 do
                pcall(function()
                    local p = list:call("get_Item", i)
                    if not p then return end
                    -- ⭐ r74 REPORT BEFORE ACTING. (Aurora: "is it definitely a
                    -- pawn thing? I'm not doing anything with the pawn.") A
                    -- fair challenge -- "app.Pawn.setFollowObject" came from
                    -- REFramework's NEAREST-ADDRESS symbolication (the outer
                    -- frames are Wwise functions, so the whole stack is a best
                    -- guess, not exact). So instead of arguing the inference,
                    -- name what every pawn is ACTUALLY following, every revive.
                    -- If nothing follows the horse, the pawn theory is dead and
                    -- we look elsewhere -- which is the useful outcome either way.
                    local fo = p:call("getFollowObject")
                    local faddr, fname = nil, "(none)"
                    pcall(function()
                        if fo then
                            faddr = fo:get_address()
                            fname = tostring(fo:call("get_Name") or "?")
                        end
                    end)
                    local pname = "?"
                    pcall(function()
                        pname = tostring(char_go(p):call("get_Name") or "?")
                    end)
                    log.info(string.format(
                        "[IrisDowned] pawn %s follows %s%s",
                        pname, fname,
                        (faddr and faddr == addr) and "  <== THE REVIVED BODY" or ""))
                    if faddr and faddr == addr then
                        p:call("setFollowObject", nil)
                        n = n + 1
                    end
                end)
            end
        end
    end)
    if n > 0 then
        log.info("[IrisDowned] cleared " .. tostring(n)
            .. " pawn follow reference(s) to the revived body")
    end
    return n
end
function griffin_downed_breadcrumb(stage, e)
    -- ⛔ THE LOG DIES ON RELAUNCH. Aurora's horse was killed by a boulder, she
    -- revived it, the game crashed -- and by the time I looked, the relaunch had
    -- already overwritten re2_framework_log.txt, so there was NOTHING to read.
    -- Revive is now the single most crash-prone path we own, so it leaves a
    -- DISK trail that survives a CTD. Ordered stages -- if the file ends at
    -- "reset_action" then resetActionAndAI is what killed it, and so on.
    pcall(function()
        S.rev_trace = S.rev_trace or {}
        S.rev_trace[#S.rev_trace + 1] = string.format("%s %s (%s)",
            os.date("%H:%M:%S"), tostring(stage),
            tostring(e and e.name or "?"))
        while #S.rev_trace > 40 do table.remove(S.rev_trace, 1) end
        json.dump_file(MOD .. "_revive_trace.json",
            { last = tostring(stage), trace = S.rev_trace })
    end)
end
function griffin_downed_revive(e)
    griffin_downed_breadcrumb("revive:enter", e)
    -- Seed HP first because a character at 0 cannot be revived, then write the
    -- requested fraction AGAIN after reviveFromFallDead: that native call heals
    -- the body to full as a side effect.
    -- ⛔ And reviveFromFallDead is ONLY for a body that is genuinely dead -- on a live one it
    -- ground-SNAPS the position (route3_grab_keep_alive learned this the hard way).
    if not e then return end
    local hc = griffin_downed_hit_controller(e.ch, e.addr)
    local maxhp = tonumber(e.maxhp)
    if (not maxhp or maxhp <= 0) and hc then maxhp = tonumber(griffin_hp_max_from_component(hc)) end
    local frac = math.max(0.01, math.min(1.0,
        tonumber(C.route3_downed_revive_frac) or 0.10))
    local want = math.max(1.0, (tonumber(maxhp) or 100.0) * frac)
    if hc then
        griffin_downed_set_hp(hc,
            math.max(1.0, tonumber(C.route3_downed_floor_hp) or 1.0))
    end
    if is_dead(e.ch) then pcall(function() e.ch:call("reviveFromFallDead(System.Boolean)", false) end) end
    if hc then griffin_downed_set_hp(hc, want) end
    -- A late native revive/get-up continuation can heal on the following frame.
    -- Hold only the upper bound briefly; damage below `want` is never undone.
    S.revive_hp_hold = {
        addr = e.addr, hc = hc, want = want, until_clock = os.clock() + 1.0,
    }
    pcall(function() griffin_downed_request_node(e.ch, C.route3_downed_getup_node, 0) end)
    -- close the Arisen's kneel out (revive_end), whatever stage it reached
    if e.rev_anim ~= nil then
        e.rev_anim = nil
        pcall(function()
            local pch = get_player()
            if pch then
                iris_play_clip(pch, IRIS_PLAYER_REVIVE.bank,
                    IRIS_PLAYER_REVIVE.end_id, 0.15)
            end
        end)
    end
    griffin_downed_stable_write_hp(e, want)
    local nm = tostring(e.name)
    griffin_downed_release(e, "revived")
    status(nm .. " is back on its feet")
end
function griffin_downed_to_stable(e)
    -- ⛔ Never destroy a body the carry code is still writing every frame -- that leaves stale
    -- managed-object calls. Defer instead; the tick retries.
    if S.route3_grab and S.route3_grab.carried == e.ch then
        e.deferred_destroy = true
        return
    end
    griffin_downed_stable_write_hp(e, tonumber(C.route3_downed_floor_hp) or 1.0)
    pcall(function()
        local rec = griffin_stable_active()
        if type(rec) == "table" then rec.downed_at = os.time(); griffin_stable_write() end
    end)
    local nm = tostring(e.name)
    griffin_downed_release(e, "timeout -> stable")
    -- ⛔⛔ 08-09 -- THIS LINE USED TO PERMANENTLY DELETE THE COMPANION.
    -- It called delete_griffin(), and delete_griffin ENDS with
    -- griffin_stable_remove_active() -- "a deliberate delete releases the
    -- active companion's soul too" -- which table.remove()s the record out of
    -- the stable and nils st.active. So a revive window simply RUNNING OUT
    -- erased the soul, while printing "carried back to the stable -- it needs
    -- time to recover". The message promised a bench; the code did an execution.
    -- Proven on Aurora's horse Horz (08-09 log): DOWN at 12:58:01.951, this
    -- branch at 12:58:31.954 -- exactly the 30.0s window -- and he was gone
    -- from _stable.json afterwards. She assumed the brine drowned him; it did
    -- not, this did.
    -- griffin_dismiss is the correct primitive and always was: it destroys the
    -- BODY and explicitly keeps the SOUL ("the whistle re-mints her"), which is
    -- precisely what the status line has been claiming all along.
    pcall(function()
        local dismiss = rawget(_G, "griffin_dismiss")
        if dismiss then dismiss() else delete_griffin() end
    end)
    -- ⛔⛔ 08-17 (Aurora: "Quoth still comes back out of the stable at max HP instantly") -- THE
    -- BENCH WAS BEING UNDONE BY THE DISMISS. Two paths both believe they own rec.hp:
    --   * THIS function writes the FLOOR (that is the whole point of a bench), then
    --   * griffin_dismiss -> griffin_tamed_save -> griffin_stable_bank_live_hp reads the LIVE
    --     HitController and writes rec.hp/rec.hp_max straight over the top of it.
    -- Last writer wins, and the receipt says the wrong one did: _stable.json had Quoth at
    -- `hp: 28.0, hp_max: 28.0` -- FULL -- immediately after a bench that had just set him to 1.
    -- (Aurora's own theory was a 1-HP native crow scaled up by the HP IV; the saved record
    -- refutes that -- his max is a perfectly ordinary 28. It was never the IV, and never the
    -- rest RATE either: no amount of rate tuning matters when the stored value is already full.)
    -- ⇒ re-assert the floor AFTER the dismiss, so the bench is the last word, and start the rest
    -- clock here rather than trusting whichever path happened to stamp it.
    pcall(function()
        local rec = griffin_stable_active()
        if type(rec) ~= "table" then return end
        local floor9 = tonumber(C.route3_downed_floor_hp) or 1.0
        local was9 = tonumber(rec.hp)
        rec.hp = floor9
        if not (tonumber(rec.hp_max) and tonumber(rec.hp_max) > 0.0) then
            rec.hp_max = tonumber(e.maxhp) or floor9
        end
        -- the bench clock: apply_elapsed_rest needs away_since or it never regenerates at all
        -- (Quoth's record had hp_rest_at but NO away_since, so he was resting at zero per second)
        local now9 = os.time()
        rec.away_since = now9
        rec.hp_rest_at = now9
        griffin_stable_write()
        log.info(string.format(
            "[IrisDowned] bench HP asserted after dismiss: %s -> %.1f / %.1f (rest clock started)",
            tostring(was9), floor9, tonumber(rec.hp_max) or -1))
    end)
    status(nm .. " was carried back to the stable -- it needs time to recover")
end
function griffin_downed_tick()
    S.downed_frame_id = (tonumber(S.downed_frame_id) or 0) + 1
    -- one-shot boot work, deferred to here so the world + stable file are actually loaded
    if S.downed_boot_done ~= true then
        S.downed_boot_done = true
        pcall(griffin_downed_install_hook)
        pcall(griffin_downed_boot_sweep)
    end
    if C.route3_downed_enabled ~= true then
        if next(griffin_downed_state()) ~= nil then griffin_downed_release_all("feature disabled") end
        return
    end
    -- ⛔ 08-11 (Aurora: CTD while PAUSED mid-revive): pause-frame body work is the
    -- pause-spawn crash class -- writes land on a world whose systems are stopped and
    -- the next frame that touches the half-updated body is a native crash pcall cannot
    -- catch. The whole downed machine (revive writes, clips, AI wake-ups, releases)
    -- stands down on paused frames and resumes exactly where it was. os.clock deadlines
    -- that lapse during the pause simply fire on the first LIVE frame after it.
    if griffin_world_paused and griffin_world_paused() then return end
    -- r73 post-revive watchdog: stamp the disk trail every 0.25s for 4s so a
    -- CTD after the unwind still records how far past the revive it got.
    if type(S.rev_watch) == "table" then
        local nw = os.clock()
        if nw >= S.rev_watch.until_t then
            S.rev_watch = nil
        elseif nw >= (tonumber(S.rev_watch.at) or 0.0) then
            S.rev_watch.at = nw + 0.25
            local left = S.rev_watch.until_t - nw
            griffin_downed_breadcrumb(string.format(
                "post-revive +%.2fs", 4.0 - left),
                { name = S.rev_watch.name })
        end
    end
    -- r81: deferred AI wake-up. ⛔ Validity re-checked at fire time -- a timeout
    -- release destroys the body, and enabling components on a dead one is its
    -- own crash.
    if type(S.downed_ai_pending) == "table" and #S.downed_ai_pending > 0 then
        local nowa = os.clock()
        for i = #S.downed_ai_pending, 1, -1 do
            local q = S.downed_ai_pending[i]
            if nowa >= (tonumber(q.at) or 0.0) then
                table.remove(S.downed_ai_pending, i)
                local ok = false
                pcall(function() ok = q.ch and q.ch:call("get_Valid") == true end)
                if ok then
                    -- ⛔⛔ 08-09 r83 -- NAVIGATIONAI IS THE KILLER, AND THE TRACE
                    -- SAYS SO OUTRIGHT. Deferring by 0.6s did not help, it just
                    -- moved the crash: the trail now ends exactly on
                    -- "ai_on (deferred)" after surviving +0.05, +0.31 and +0.58.
                    -- So the body is fine right up to the moment the brain comes
                    -- back, and the stack has always been a MOVE command.
                    -- ⭐ We do not need native navigation on a companion anyway:
                    -- tamed monsters' decision trees never commit (proven over
                    -- six rounds -- "So we drive"), so the follow is a transform
                    -- stepper and NavigationAI contributes nothing but this
                    -- crash. Bring the decision maker back; leave nav asleep.
                    -- route3_downed_wake_nav = true restores the old behaviour.
                    -- ⛔⛔ 08-10 r93 -- IT IS THE DECISION MAKER, NOT NAV.
                    -- I removed NavigationAI last round and the trace ends on
                    -- exactly the same line: +0.03, +0.30, +0.58, then
                    -- "ai_on (deferred)" and nothing. So the survivor --
                    -- app.AIDecisionMaker -- is what kills it. The stack has
                    -- always been a MOVE COMMAND, and the decision maker is what
                    -- issues those.
                    -- ⭐ We do not need either component: a tamed companion's
                    -- decision tree never commits (six rounds proved it -- "so we
                    -- drive"), and following is a transform stepper we run
                    -- ourselves. The downed system disabled them; nothing says it
                    -- has to be the thing that turns them back on.
                    -- Both are now opt-in. If the companion stops behaving after
                    -- a revive, route3_downed_wake_ai = true is the first dial.
                    local wake = {}
                    for tn, was_enabled in pairs(q.wake or {}) do
                        if was_enabled == true then wake[#wake + 1] = tn end
                    end
                    -- These remain probe overrides; ordinary revive restores
                    -- only what this exact downed instance disabled.
                    if C.route3_downed_wake_ai == true then wake[#wake + 1] = "app.AIDecisionMaker" end
                    if C.route3_downed_wake_nav == true then wake[#wake + 1] = "app.NavigationAI" end
                    for _, tn in ipairs(wake) do
                        local c = get_component(q.go, tn)
                        if c then
                            pcall(function() c:call("set_Enabled", true) end)
                        end
                    end
                    griffin_downed_breadcrumb("ai_on (deferred)",
                        { name = q.name })
                else
                    griffin_downed_breadcrumb("ai_on SKIPPED (body gone)",
                        { name = q.name })
                end
            end
        end
    end
    griffin_downed_protected_refresh(false)
    if type(S.revive_hp_hold) == "table" then
        local q = S.revive_hp_hold
        if os.clock() >= (tonumber(q.until_clock) or 0.0) then
            S.revive_hp_hold = nil
        else
            pcall(function()
                local hc = q.hc or griffin_downed_hit_controller(
                    griffin_downed_is_protected(q.addr), q.addr)
                local hp = hc and tonumber(hc:call("get_Hp")) or nil
                local want = tonumber(q.want)
                if hp and want and hp > want + 0.05 then
                    griffin_downed_set_hp(hc, want)
                end
            end)
        end
    end
    -- Verify queued positive reactions after native damage had time to apply.
    -- Never double-charge: any HP movement from the captured value proves the
    -- native path won and the fallback stands down.
    if type(S.damage_fallback) == "table" then
        local nowd = os.clock()
        for addr, q in pairs(S.damage_fallback) do
            if nowd >= (tonumber(q.due) or math.huge) then
                S.damage_fallback[addr] = nil
                S.damage_fallback_next = S.damage_fallback_next or {}
                S.damage_fallback_next[addr] = nowd + 0.25
                pcall(function()
                    local hc = q.hc or griffin_downed_hit_controller(
                        griffin_downed_is_protected(addr), addr)
                    local hp = hc and tonumber(hc:call("get_Hp")) or nil
                    local hp0 = tonumber(q.hp0)
                    local damage = tonumber(q.damage) or 0.0
                    if not (hp and hp0 and damage > 0.0) then return end
                    if hp >= hp0 - 0.01 then
                        local floor = tonumber(C.route3_downed_floor_hp) or 1.0
                        local after = math.max(floor, hp - damage)
                        local applied = griffin_downed_set_hp(hc, after)
                        if not applied then
                            local ch = griffin_downed_is_protected(addr)
                            local alt = griffin_target_hit_controller(ch)
                            if alt and alt ~= hc
                                and griffin_downed_set_hp(alt, after) then
                                hc = alt
                                S.hp_source = S.hp_source or {}
                                S.hp_source[addr] = alt
                                applied = true
                            end
                        end
                        if applied then
                            _G.IrisFallbackDamageHits =
                                (tonumber(rawget(_G, "IrisFallbackDamageHits")) or 0) + 1
                            _G.IrisFallbackDamageLast = string.format(
                                "%.0f -> %.0f (-%.0f)", hp, after, damage)
                            _G.IrisHpSourceHp = after
                        end
                    end
                end)
            end
        end
    end
    -- Read the HP after every damage hook and the native subtraction have run.
    -- This is the only trustworthy down edge because updateDamageHp's separate
    -- amount may be scaled by the horse durability hook after reaction maths.
    local floor_now = tonumber(C.route3_downed_floor_hp) or 1.0
    S.last_safe_hp = S.last_safe_hp or {}
    for addr, ch in pairs(S.downed_prot or {}) do
        if not griffin_downed_state()[addr] then
            local hp_now = nil
            local hc9 = nil
            pcall(function()
                hc9 = griffin_downed_hit_controller(ch, addr)
                hp_now = hc9 and tonumber(hc9:call("get_Hp")) or nil
            end)
            if hp_now and hp_now > floor_now + 0.001 then
                S.last_safe_hp[addr] = hp_now
            elseif hp_now and hp_now <= floor_now + 0.001 then
                -- ⛔ 08-11 (Aurora: 1/1-hp Ratina lived permanently "DOWN"): a creature
                -- whose whole life fits under the floor can never go down -- the floor IS
                -- its full health. Down only on a witnessed fall from above the floor,
                -- and never when max HP itself sits at/under the floor. (A NATIVE death
                -- still downs it via the death guard -- real kills are unaffected.)
                local seen_above = (tonumber(S.last_safe_hp[addr]) or 0.0) > floor_now + 0.001
                local tiny_max = false
                pcall(function()
                    if griffin_hp_max_from_component then
                        local mx = tonumber(griffin_hp_max_from_component(hc9))
                        tiny_max = (mx ~= nil) and (mx <= floor_now + 1.0)
                    end
                end)
                if seen_above and not tiny_max then
                    S.downed_pending_enter = S.downed_pending_enter or {}
                    S.downed_pending_enter[addr] = true
                end
            end
        end
    end
    -- Retire the exact reaction clip before another node can claim the body.
    -- The clip's live frame/end-frame is authoritative; hard_until is only a
    -- failsafe for malformed motion metadata.
    if S.hit_reaction_active and not griffin_hit_reaction_busy() then
        local was_air = S.hit_reaction_active.airborne == true
        S.hit_reaction_active = nil
        if type(S.base_owner) == "table" and S.base_owner.name == "hitreact" then
            S.base_owner = nil
        end
        if was_air and S.mounted == true then
            pcall(function()
                local ch = reacquire_griffin()
                local still_air = S.airborne == true
                pcall(function()
                    if ch and ch:call("get_IsFlight") == true then still_air = true end
                end)
                if still_air and route3_restore_flight_base then
                    route3_restore_flight_base()
                end
            end)
        end
    end
    -- HIT REACTION, played from the tick (never re-entrantly from the damage
    -- hook). Damage remains authoritative during an owned move, but its cosmetic
    -- flinch must be discarded: retaining it to play after the move steals the
    -- next action and can strand a mount inside the reaction/node lockout.
    if S.hit_react_addr and C.route3_attack_reaction_guard ~= false
        and griffin_downed_special_move_busy() then
        S.hit_react_guard_blocks = (tonumber(S.hit_react_guard_blocks) or 0) + 1
        S.hit_react_guard_status = string.format(
            "move poise: reaction discarded; damage retained (%d)",
            tonumber(S.hit_react_guard_blocks) or 0)
        S.hit_react_addr = nil
        S.hit_react_dir = nil
        S.hit_react_deadline = nil
    end
    if S.hit_react_addr then
        local addr = S.hit_react_addr
        local nowh = os.clock()
        if tonumber(S.hit_react_deadline) == nil then
            S.hit_react_deadline = nowh + 2.5
        end
        if nowh >= tonumber(S.hit_react_deadline) then
            S.hit_react_addr = nil
            S.hit_react_dir = nil
            S.hit_react_deadline = nil
        elseif nowh >= (tonumber(S.hit_react_at) or 0.0)
            and not (griffin_downed_state()[addr])
            and C.route3_hit_reactions ~= false
            and not griffin_downed_special_move_busy()
            and not griffin_hit_reaction_busy() then
            pcall(function()
                local ch = griffin_downed_is_protected(addr)
                local go = ch and char_go(ch)
                if not go then return end
                local horse_ridden, griffin_ridden = false, false
                pcall(function()
                    local api = rawget(_G, "IrisHorseMount")
                    horse_ridden = api and api.is_mounted
                        and api.is_mounted(go) == true
                end)
                pcall(function()
                    local api = rawget(_G, "IrisGriffinBridge")
                    griffin_ridden = api and api.is_mounted
                        and api.is_mounted(go) == true
                end)
                local nm = tostring(go:call("get_Name") or "")
                local hb, blen = nil, -1
                for key, v in pairs(IRIS_HITBACK) do
                    if nm:find(key, 1, true) and #key > blen then
                        hb, blen = v, #key
                    end
                end
                if not hb then return end   -- this body does not flinch
                -- r70: pick the clip from ConvertedHitBackDir. ⛔ Unknown or
                -- unreadable ALWAYS falls back to the front clip -- a flinch is
                -- the point; getting the facing exactly right is the polish.
                local dmap = { [0] = hb.f, [1] = hb.b, [2] = hb.l, [3] = hb.r }
                local airborne = iris_hit_reaction_is_airborne(ch, go, hb)
                if airborne and hb.af ~= nil then
                    dmap = { [0] = hb.af, [1] = hb.ab,
                        [2] = hb.al, [3] = hb.ar }
                end
                local clip = dmap[tonumber(S.hit_react_dir) or -1] or hb.f
                S.hit_react_dir = nil
                if horse_ridden then
                    local api = rawget(_G, "IrisHorseMount")
                    if not (api and api.begin_hit_reaction
                        and api.begin_hit_reaction(go,
                            tonumber(C.route3_hit_react_cooldown) or 0.9) == true) then
                        return
                    end
                end
                S.hit_react_at = nowh
                    + (tonumber(C.route3_hit_react_cooldown) or 0.9)
                if iris_play_clip(ch, hb.bank, clip, 0.10) then
                    S.hit_react_addr = nil
                    S.hit_react_deadline = nil
                    S.hit_reaction_active = {
                        ch = ch, bank = hb.bank, clip = clip,
                        airborne = airborne,
                        -- Air hitback clips can naturally feed the native damage
                        -- tree into its long fall/dive follow-up. We only want the
                        -- readable flinch, then an explicit hand-back to flight.
                        min_until = nowh + (airborne and 0.12 or 0.18),
                        hard_until = nowh + (airborne and 0.70 or 1.25),
                    }
                    if griffin_ridden then
                        S.base_owner = {name = "hitreact", until_clock = nowh + 1.25}
                    end
                end
            end)
        elseif C.route3_hit_reactions == false
            or griffin_downed_state()[addr] then
            S.hit_react_addr = nil
            S.hit_react_dir = nil
            S.hit_react_deadline = nil
        end
    end
    if S.downed_pending_enter then
        for addr, _ in pairs(S.downed_pending_enter) do pcall(function() griffin_downed_enter(addr) end) end
        S.downed_pending_enter = nil
    end
    griffin_downed_map_learn()
    local st = griffin_downed_state()
    local now = os.clock()
    if next(st) == nil then S.downed_last_clock = now; return end
    -- ⭐ 08-09 (Aurora: "the revive bar went down while the game was paused,
    -- which it shouldn't do"). The window is measured in os.clock(), which is
    -- REAL time and keeps running through the pause menu, the map and photo
    -- mode. The dt clamp above only stops one huge jump -- it does not stop the
    -- clock. Freeze outright, and re-seed last_clock so unpausing does not then
    -- bill the whole paused stretch in a single tick.
    -- Same oracle the HUD uses: PauseManager for the real pause, GuiManager for
    -- menus/photo mode (DD2's menus do NOT pause the world -- see mountcam).
    local paused = false
    pcall(function()
        local pm = sdk.get_managed_singleton("app.PauseManager")
        if pm and pm:call("isPausedAny") == true then paused = true end
    end)
    if not paused then
        pcall(function()
            local gm = sdk.get_managed_singleton("app.GuiManager")
            if gm and (gm:call("isPausedGUI") == true
                or gm:call("get_IsDispPhotoModeAll") == true) then
                paused = true
            end
        end)
    end
    if paused then S.downed_last_clock = now; return end
    -- ⛔ dt is CLAMPED: a pause / photo mode / cutscene produces one enormous real-time delta
    -- that would burn the whole window while the player physically cannot reach the body.
    local dt = math.min(0.25, math.max(0.0, now - (tonumber(S.downed_last_clock) or now)))
    S.downed_last_clock = now
    local window = tonumber(C.route3_downed_window_secs) or 30.0
    local reach = tonumber(C.route3_downed_revive_range) or 2.5
    local ppos = nil
    pcall(function() local p = get_player(); ppos = p and transform_pos(char_go(p)) end)
    for _, e in pairs(st) do
        local valid = false
        pcall(function() valid = e.ch and e.ch:call("get_Valid") == true end)
        if not valid then
            -- body vanished under us (scene change, engine despawn): bank it rather than leak it
            pcall(function() griffin_downed_stable_write_hp(e, tonumber(C.route3_downed_floor_hp) or 1.0) end)
            griffin_downed_release(e, "body invalid")
        else
            griffin_downed_reassert(e)
            if e.map_info then
                griffin_downed_map_write_pos(e.map_info,
                    griffin_downed_map_pos(e.go))
            elseif now >= (tonumber(e.map_next_retry) or 0.0) then
                griffin_downed_map_add(e)
            end
            e.elapsed = (tonumber(e.elapsed) or 0.0) + dt
            local near = false
            local gp = transform_pos(e.go)
            if ppos and gp then
                local dx, dy, dz = (gp.x - ppos.x), (gp.y - ppos.y), (gp.z - ppos.z)
                near = (dx * dx + dy * dy + dz * dz) <= (reach * reach)
            end
            e.near = near
            -- ⭐ 08-09 (Aurora: "I couldn't actually figure out how to revive
            -- him... it'd need to be B on the gamepad"). The revive was
            -- KEYBOARD ONLY -- reframework:is_key_down never sees a controller
            -- -- so on a pad the feature was unreachable by design. B/Circle is
            -- mask 0x40080, the same constant the rodeo uses for gallop.
            local held = false
            pcall(function() held = iris_kb(tonumber(C.route3_downed_revive_key) or 0x52) == true end)
            if not held then
                pcall(function()
                    local hid = sdk.get_native_singleton("via.hid.GamePad")
                    local td = sdk.find_type_definition("via.hid.GamePad")
                    local dev = sdk.call_native_func(hid, td, "get_MergedDevice")
                    -- ⛔ get_Button (HELD state), not get_ButtonDown (edge).
                    -- This is a hold-to-fill, so we need "is it down right
                    -- now"; get_Button is also the call proven in the rodeo's
                    -- gallop/jump/kick reads, which is the only version of this
                    -- known to work in this codebase.
                    local mask = tonumber(dev and dev:call("get_Button")) or 0
                    if (mask & (tonumber(C.route3_downed_revive_pad_mask)
                        or 0x40080)) ~= 0 then
                        held = true
                    end
                end)
            end
            if near and held then
                e.hold = (tonumber(e.hold) or 0.0) + dt
                -- ⭐ 08-09 THE ARISEN KNEELS. bank 0 / 1000 revive_start ->
                -- 1001 revive_loop, the game's own pawn-revive motion (verified
                -- in HumanOrBeastren_MotionIDs.json, not guessed). Fired on the
                -- EDGE only; the loop is left alone once running so it does not
                -- pin at frame 0 every tick.
                if C.route3_downed_player_revive_anim ~= false
                    and e.rev_anim == nil then
                    local pch = nil
                    pcall(function() pch = get_player() end)
                    if pch then
                        e.rev_anim = "start"
                        e.rev_anim_at = now + 0.6
                        iris_play_clip(pch, IRIS_PLAYER_REVIVE.bank,
                            IRIS_PLAYER_REVIVE.start_id, 0.12)
                    end
                elseif e.rev_anim == "start"
                    and now >= (tonumber(e.rev_anim_at) or math.huge) then
                    e.rev_anim = "loop"
                    pcall(function()
                        local pch = get_player()
                        if pch then
                            iris_play_clip(pch, IRIS_PLAYER_REVIVE.bank,
                                IRIS_PLAYER_REVIVE.loop_id, 0.15)
                        end
                    end)
                end
            else
                e.hold = math.max(0.0, (tonumber(e.hold) or 0.0) - dt * 2.0)
                -- let go early: close the kneel out so she is not stuck in it
                if e.rev_anim ~= nil then
                    e.rev_anim = nil
                    pcall(function()
                        local pch = get_player()
                        if pch then
                            iris_play_clip(pch, IRIS_PLAYER_REVIVE.bank,
                                IRIS_PLAYER_REVIVE.end_id, 0.15)
                        end
                    end)
                end
            end
            -- ⭐ 08-09 DROWNING. Checked on a 0.5s cadence (a component fetch
            -- every frame for 30s is pure waste), and it ACCUMULATES -- a single
            -- stray true can never sink a companion, it has to stay wet.
            -- ⛔ The timer DECAYS when out of water, so a body that gets washed
            -- clear recovers rather than carrying a death sentence around.
            if C.route3_downed_drown_permanent ~= false then
                if now >= (tonumber(e.water_at) or 0.0) then
                    e.water_at = now + 0.5
                    e.in_water = griffin_downed_in_water(e.go)
                end
                if e.in_water == true then
                    e.drown = (tonumber(e.drown) or 0.0) + dt
                else
                    e.drown = math.max(0.0, (tonumber(e.drown) or 0.0) - dt)
                end
            end
            local drown_need = math.max(1.0,
                tonumber(C.route3_downed_drown_secs) or 10.0)
            local need = math.max(0.2, tonumber(C.route3_downed_revive_hold_secs) or 2.0)
            if e.hold >= need then
                griffin_downed_revive(e)
            elseif (tonumber(e.drown) or 0.0) >= drown_need then
                griffin_downed_lost(e, "drowned")
            elseif e.elapsed >= window then
                griffin_downed_to_stable(e)
            end
        end
    end
end
function griffin_downed_regen_tick()
    -- Retired. Stable recovery is timestamped at dismissal and calculated once
    -- on summon (route3_stable_regen_hp_per_sec). The old five-second polling
    -- loop regenerated 10% of max HP/minute even when the body was live; on a
    -- boss-sized griffin that was both an exploit and needless disk churn.
end
function griffin_downed_hud()
    -- on-screen prompt + timer bar while a companion is down
    local st = S.downed
    if type(st) ~= "table" or next(st) == nil then return end
    if not draw then return end
    local e = nil
    for _, v in pairs(st) do e = v; break end
    if not e then return end
    -- ⭐ 08-09 (Aurora: "can we have the revive bars use the same bar style we
    -- do for taming, building the house, etc"). They now DO -- by handing the
    -- values to the universal gauge instead of drawing rectangles here.
    -- _G.IrisProgressHUD = {active, t, bars = {{frac,label},...}} is the same
    -- push-API the palm, the pact and the construction site use, so this gets
    -- the antique-gold border, leather trough, top sheen, quarter ticks and
    -- parchment serif label for free -- and its fade envelope, and its
    -- pause/photo-mode suppression, which the raw draw.filled_rect version
    -- never had.
    -- ⛔ Re-stamped EVERY frame: the gauge treats anything older than 1s as
    -- finished and fades it out, which is exactly the behaviour we want when
    -- the body is revived or benched.
    pcall(function()
        local window = math.max(0.1, tonumber(C.route3_downed_window_secs) or 30.0)
        local left = math.max(0.0, window - (tonumber(e.elapsed) or 0.0))
        -- DROWNING takes over the top bar: it is the shorter fuse AND the
        -- permanent one, so it must be the number on screen, not the 30s one.
        local drowning = (tonumber(e.drown) or 0.0) > 0.25
        local bars
        if drowning then
            local dneed = math.max(1.0,
                tonumber(C.route3_downed_drown_secs) or 10.0)
            local dleft = math.max(0.0, dneed - (tonumber(e.drown) or 0.0))
            bars = { {
                frac = math.max(0.0, math.min(1.0, dleft / dneed)),
                label = string.format("%s IS DROWNING  --  %.0fs  (LOST FOR GOOD)",
                    tostring(e.name), dleft),
            } }
        else
            bars = { {
                frac = math.max(0.0, math.min(1.0, left / window)),
                label = string.format("%s is DOWN  --  %.0fs",
                    tostring(e.name), left),
            } }
        end
        if e.near == true then
            local need = math.max(0.2,
                tonumber(C.route3_downed_revive_hold_secs) or 2.0)
            bars[#bars + 1] = {
                frac = math.max(0.0, math.min(1.0,
                    (tonumber(e.hold) or 0.0) / need)),
                -- THE PROMPT. Aurora could not find the revive at all because
                -- it was keyboard-only and unlabelled. Name both inputs.
                label = "Hold  B / R  to revive",
            }
        else
            bars[#bars + 1] = { frac = 0.0, label = "Get closer to revive" }
        end
        _G.IrisProgressHUD = { active = true, t = os.clock(), bars = bars }
    end)
end
