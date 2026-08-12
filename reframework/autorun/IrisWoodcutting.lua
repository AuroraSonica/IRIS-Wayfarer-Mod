-- IrisWoodcutting.lua - axe + tree chopping for the IRIS homestead (started 2026-07-21).
--
-- DESIGN (agreed w/ Aurora): choppable trees = the game's OWN destructible tree gimmicks (the ones
-- griffins/cyclopes smash - gm80_002/109/110 family). Same rule the world already teaches: if a
-- monster could break it, your axe can. Pure-scenery speedtrees stay standing (their collision is
-- the scene-side merged blob = the wall we detoured around for the house; consistent world rule).
--
-- v0 = TREE AIM PROBE: look at a destructible tree, press the button -> dumps the hit GameObject's
-- full identity (name chain, every component, and the HP/damage/break API of anything gimmick-ish)
-- to data/IRIS/woodcut_probe.txt. That file decides the chop mechanism:
--   native damage pipeline (tree HP + fall anim for free)  vs  direct break/destroy request call.
-- Later slices: axe prop in hand (RiftSpeak holder recipe), swing motion, hit -> +wood item.

local M = {}
M.last = "(idle) - stand in a forest, LOOK AT a destructible tree, press TREE AIM PROBE"

local ray = {}

local function _log(s)
    pcall(function()
        local f = io.open("IRIS/woodcut_log.txt", "a")
        if f then f:write("[" .. os.date("%H:%M:%S") .. "] " .. tostring(s) .. "\n"); f:close() end
    end)
end
local function _vec3(x, y, z)
    local v = ValueType.new(sdk.find_type_definition("via.vec3")); v.x, v.y, v.z = x or 0, y or 0, z or 0; return v
end

-- ⛔ SHARED CONSTANTS LIVE AT THE TOP (3rd nil-scope strike: the chop finder indexed these while
-- they were still declared further down = every component silently skipped inside its pcall)
local TREE_SET = { ["app.Gm80_002"] = true, ["app.Gm80_109"] = true, ["app.Gm80_110"] = true }
local ROCK_SET = {
    ["app.Gm80_009"] = true, ["app.Gm80_010"] = true, ["app.Gm80_140"] = true,
    ["app.Gm81_059"] = true, ["app.Gm81_064"] = true, ["app.Gm81_143"] = true,
    ["app.Gm81_145"] = true, ["app.Gm81_146"] = true,
}

local function _ensure_ray()
    if ray.ready then return true end
    local ok = pcall(function()
        ray.system = sdk.get_native_singleton("via.physics.System")
        ray.method = sdk.find_type_definition("via.physics.System")
            :get_method("castRay(via.physics.CastRayQuery, via.physics.CastRayResult)")
        ray.contact_td = sdk.find_type_definition("via.physics.ContactPoint")
        ray.query = sdk.create_instance("via.physics.CastRayQuery"):add_ref()
        ray.result = sdk.create_instance("via.physics.CastRayResult"):add_ref()
        ray.query:clearOptions()
        ray.query:enableAllHits()
        ray.query:enableNearSort()
        ray.filter = ray.query:get_FilterInfo()
    end)
    ray.ready = ok and ray.system ~= nil and ray.query ~= nil and ray.result ~= nil and ray.filter ~= nil
    return ray.ready == true
end

-- does this type look like it could hold the chop levers? (dump its full API if so)
local function _interesting(tn)
    local l = tn:lower()
    return l:find("gimmick") or l:find("gm%d") or l:find("break") or l:find("damage")
        or l:find("hp") or l:find("tree") or l:find("destruct") or l:find("generate")
end

local function _dump_component(f, comp, indent)
    local tn = "?"
    pcall(function() tn = comp:get_type_definition():get_full_name() end)
    f:write(indent .. "component: " .. tn .. "\n")
    if not _interesting(tn) then return end
    -- interesting -> dump its methods (walking base types too) + try common HP getters live
    pcall(function()
        local td = comp:get_type_definition()
        local depth = 0
        while td and depth < 4 do
            for _, m in ipairs(td:get_methods()) do
                local mn = m:get_name()
                local ml = mn:lower()
                if ml:find("hp") or ml:find("damage") or ml:find("break") or ml:find("destr")
                    or ml:find("dead") or ml:find("fall") or ml:find("drop") or ml:find("item")
                    or ml:find("hit") or ml:find("request") then
                    local ps = {}
                    for _, p in ipairs(m:get_param_types()) do ps[#ps + 1] = p:get_full_name() end
                    f:write(indent .. "  ." .. mn .. "(" .. table.concat(ps, ", ") .. ")\n")
                end
            end
            td = td:get_parent_type(); depth = depth + 1
        end
    end)
    for _, g in ipairs({ "get_Hp", "get_MaxHp", "get_HP", "get_Health", "get_IsBroken", "get_Enabled" }) do
        pcall(function()
            local v = comp:call(g)
            if v ~= nil then f:write(indent .. "  " .. g .. "() = " .. tostring(v) .. "\n") end
        end)
    end
end

local function _dump_go_tree(f, go, indent, depth)
    if not go or depth > 4 then return end
    local name = "?"
    pcall(function() name = go:call("get_Name") end)
    f:write(indent .. "GameObject: " .. tostring(name) .. "\n")
    -- enumerate components (first probe printed NONE - getComponentCount doesn't exist on this
    -- build and the pcall ate it silently; get_Components -> array is the way)
    local comps = {}
    pcall(function()
        local arr = go:call("get_Components")
        if arr then
            local ok = pcall(function()
                for _, c in ipairs(arr:get_elements()) do comps[#comps + 1] = c end
            end)
            if not ok then
                local n = arr:get_size()
                for i = 0, (tonumber(n) or 0) - 1 do comps[#comps + 1] = arr:get_element(i) end
            end
        end
    end)
    if #comps == 0 then f:write(indent .. "  (component enumeration failed on this GO)\n") end
    for _, c in ipairs(comps) do _dump_component(f, c, indent .. "  ") end
    -- climb children one level (leaf/trunk parts often sit under the root)
    pcall(function()
        local tf = go:call("get_Transform"); local child = tf and tf:call("get_Child")
        while child do
            local cgo = child:call("get_GameObject")
            if cgo then _dump_go_tree(f, cgo, indent .. "  ", depth + 1) end
            child = child:call("get_Next")
        end
    end)
end

-- ── CHOP TEST (probe-proven API, gm80_109): find the aimed gm-tree, chip its HP, fell it ────────
-- app.Gm80_109 (and siblings) expose getHp/getMaxHp/setHp/setDeadHp + executeBreak(bool) + native
-- break FX/SE + a pre-authored "Broken" debris child + setupItemDropInfo. We just pull the levers.
M.chop_pct = 34.0        -- damage per chop, % of max HP (3 chops fells a fresh tree)
M.chop_range = 6.0       -- max distance to the tree (m) - axe reach, roughly
M.instant = false        -- true = one press fells it (executeBreak directly)

local function _tree_comp(go)
    -- the gimmick brain: an app.Gm##_### component with the HP API
    local found
    pcall(function()
        local arr = go:call("get_Components")
        if not arr then return end
        local n = arr:get_size()
        for i = 0, (tonumber(n) or 0) - 1 do
            local c = arr:get_element(i)
            if c then
                local tn = ""
                pcall(function() tn = c:get_type_definition():get_full_name() end)
                if tn:find("^app%.Gm%d") then
                    local okhp = pcall(function() return c:call("getHp") end)
                    if okhp then found = c; return end
                end
            end
        end
    end)
    return found
end

local function _find_aim_tree()
    if not _ensure_ray() then return nil, "ray not ready" end
    local ox, oy, oz, fx, fy, fz
    pcall(function()
        local cam = sdk.get_primary_camera()
        local ctf = cam and cam:call("get_GameObject"):call("get_Transform")
        local p = ctf and ctf:call("get_Position")
        local fwd = ctf and ctf:call("get_AxisZ")
        if p and fwd then ox, oy, oz = p.x, p.y, p.z; fx, fy, fz = fwd.x, fwd.y, fwd.z end
    end)
    if not ox then return nil, "no camera" end
    local fl = math.sqrt(fx * fx + fy * fy + fz * fz)
    if fl < 0.001 then return nil, "bad forward" end
    fx, fy, fz = fx / fl, fy / fl, fz / fl
    local best, bestd
    for _, dir in ipairs({ -1, 1 }) do   -- camera AxisZ sign varies; probe showed -1 = look dir
        local dx, dy, dz = fx * dir, fy * dir, fz * dir
        pcall(function()
            ray.filter:set_Group(0); ray.filter:set_Layer(2); ray.filter:set_MaskBits(0)
            ray.result:clear()
            ray.query:call("setRay(via.vec3, via.vec3)",
                _vec3(ox, oy, oz), _vec3(ox + dx * (M.chop_range + 2.0), oy + dy * (M.chop_range + 2.0), oz + dz * (M.chop_range + 2.0)))
            ray.method:call(ray.system, ray.query, ray.result)
            local nhit = ray.result:get_NumContactPoints() or 0
            for i = 0, math.min(nhit, 4) - 1 do
                local cp = ray.result:call("getContactPoint(System.UInt32)", i)
                local pos = cp and sdk.get_native_field(cp, ray.contact_td, "Position")
                local col = ray.result:call("getContactCollidable(System.UInt32)", i)
                local go; pcall(function() go = col and col:call("get_GameObject") end)
                if go and pos then
                    local d = math.sqrt((pos.x - ox) ^ 2 + (pos.y - oy) ^ 2 + (pos.z - oz) ^ 2)
                    -- the brain sits on the hit GO or its root
                    local comp = _tree_comp(go)
                    if not comp then
                        pcall(function()
                            local ptf = go:call("get_Transform"):call("get_Parent")
                            local pgo = ptf and ptf:call("get_GameObject")
                            if pgo then comp = _tree_comp(pgo); go = pgo end
                        end)
                    end
                    if comp and d <= M.chop_range + 2.0 and (not bestd or d < bestd) then
                        best = { comp = comp, go = go, d = d }; bestd = d
                    end
                end
            end
        end)
    end
    if not best then return nil, "no breakable tree in aim (get closer / aim at the trunk)" end
    return best
end

-- NEAREST harvestable within reach (proximity, NOT the camera ray - the ray missed a boulder at
-- 2m; you're standing at the thing you're chopping, so nearest-in-reach IS the intent)
local function _find_nearest_harvest(kind_filter, cone_deg)   -- kind_filter: nil=any, "TREE"/"STONE";
    -- cone_deg: only accept targets within this half-angle of the player's facing (aim assist)
    local pp, fwd
    pcall(function()
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local tf = cm:call("get_ManualPlayer"):call("get_GameObject"):call("get_Transform")
        pp = tf:call("get_Position")
        if cone_deg then fwd = tf:call("get_AxisZ") end
    end)
    if not pp then return nil, "no player" end
    local cone_cos = cone_deg and fwd and math.cos(math.rad(cone_deg)) or nil
    local best, bestd
    local any, anyd   -- nearest HP-bearing gimmick of ANY class (15m) - the "why not?" diagnostic
    pcall(function()
        local sm = sdk.get_native_singleton("via.SceneManager")
        local smt = sdk.find_type_definition("via.SceneManager")
        local scene = sm and sdk.call_native_func(sm, smt, "get_CurrentScene")
        local comps = scene and scene:call("findComponents(System.Type)", sdk.typeof("app.GimmickBase"))
        local n = 0
        pcall(function() n = comps:call("get_Length") or 0 end)
        if n == 0 then pcall(function() n = comps:get_size() or 0 end) end
        for i = 0, (tonumber(n) or 0) - 1 do
            pcall(function()
                local c
                pcall(function() c = comps:call("get_Item", i) end)
                if not c then pcall(function() c = comps:get_element(i) end) end
                if not c then return end
                local tn = c:get_type_definition():get_full_name()
                local kind = TREE_SET[tn] and "TREE" or (ROCK_SET[tn] and "STONE" or nil)
                if kind and kind_filter and kind ~= kind_filter then kind = nil end
                local go = c:call("get_GameObject")
                local rp = go and go:call("get_Transform"):call("get_Position")
                if not rp then return end
                local dx, dy, dz = rp.x - pp.x, rp.y - pp.y, rp.z - pp.z
                local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                if not kind then
                    -- diagnostic candidate: ANY gimmick with the HP API near us, even maxhp 0/0 -
                    -- those are BREAK-ON-HIT objects (Aurora sword-smashed a "scenery" verdict rock:
                    -- the maxhp>0 filter was wrongly excluding the poolless breakables)
                    if d <= 15.0 and (not anyd or d < anyd) then
                        local okhp, mx = pcall(function() return tonumber(c:call("getMaxHp")) or 0 end)
                        if okhp then
                            local nm = "?"; pcall(function() nm = go:call("get_Name") end)
                            any = { tn = tn, nm = nm, d = d, mx = mx or 0 }; anyd = d
                        end
                    end
                    return
                end
                if d <= M.chop_range and (not bestd or d < bestd) then
                    if cone_cos and d > 3.5 then   -- pick reach is ~3m: anything closer counts regardless of facing
                        -- aim assist: horizontal angle between facing and target must be inside the cone
                        -- (point-blank targets always count - you're standing on them)
                        local hx, hz = dx, dz
                        local hl = math.sqrt(hx * hx + hz * hz)
                        if hl > 0.001 then
                            local dot = (hx / hl) * fwd.x + (hz / hl) * fwd.z
                            if dot < cone_cos then return end
                        end
                    end
                    best = { comp = c, go = go, kind = kind, d = d }; bestd = d
                end
            end)
        end
    end)
    if not best then
        local why
        if any then
            why = string.format("nothing in the harvest sets within %.0fm - but %s '%s' (%.1fm, maxhp %.0f%s) is breakable: add its class?",
                M.chop_range, any.tn, tostring(any.nm), any.d, any.mx,
                any.mx <= 0 and " = break-on-hit" or "")
        else
            why = "nothing harvestable within " .. M.chop_range .. "m (no HP-bearing gimmick within 15m either - that boulder is SCENERY)"
        end
        _log("CHOP miss: " .. why)
        return nil, why
    end
    return best
end

-- material yields (IRIS - Materials bundle): Stone 34710, Timber 34711
local STONE_ITEM, TIMBER_ITEM = 34710, 34711
local function _do_grant(kind, n)
    local id = kind == "STONE" and STONE_ITEM or TIMBER_ITEM
    local ok = pcall(function()
        local im = sdk.get_managed_singleton("app.ItemManager")
        local gm = sdk.find_type_definition("app.ItemManager"):get_method(
            "getItem(System.Int32, System.Int32, app.Character, System.Boolean, System.Boolean, System.Boolean, app.ItemManager.GetItemEventType, System.Boolean, System.Boolean)")
        local chara = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
        gm:call(im, id, n, chara, true, false, false, nil, true, false)
    end)
    return ok and n or 0
end

local function _grant_yield(kind)
    local n = kind == "STONE" and math.random(3, 5) or math.random(2, 4)
    if M.auto_gather then
        -- the item lands DURING the gather bow (Aurora's polish: you collect it, not auto-pocket)
        M.pending_yield = { kind = kind, n = n }
        return n
    end
    return _do_grant(kind, n)
end

-- chip-impact effect: path is CONFIG (M.chip_efx) + panel test buttons - the gmdy efx spawned
-- "OK" but rendered nothing (params-dependent controller efx?), so the lane is self-serve testable
-- the chip-effect CATALOG (harvested from the gimmick VFX containers 2026-07-22)
local CHIP_FX_OPTIONS = {
    { label = "tree burst SMALL (gm80_109)", path = "VFX/Effects/Gimmic/gm80/109/13_gm80_109_000_01.efx" },
    { label = "tree burst BIG (gm80_110)",   path = "VFX/Effects/Gimmic/gm80/110/13_gm80_110_000_01.efx" },
    { label = "stone debris (rock family)",  path = "VFX/Effects/Gimmic/gmdy/010/13_gmdy_010_03.efx" },
    { label = "dust + tiny leaves (common)", path = "VFX/Effects/Gimmic/gmcm/005/13_gmcm_005_00.efx" },
    { label = "grass flutter 1",             path = "VFX/Effects/Gimmic/gmdy/000/13_gmdy_000_01.efx" },
    { label = "grass flutter 2",             path = "VFX/Effects/Gimmic/gmdy/000/13_gmdy_000_02.efx" },
    { label = "gmdy 000_03 (untried)",       path = "VFX/Effects/Gimmic/gmdy/000/13_gmdy_000_03.efx" },
}
M.chip_fx_idx = 1
M.chip_efx_tree = CHIP_FX_OPTIONS[1].path    -- what tree chips fire
M.chip_efx_stone = CHIP_FX_OPTIONS[4].path   -- what stone chips fire: dust cloud (gmcm_005).
-- ⛔ NOT option 3 (gmdy_010_03): freestanding it renders a LAVA SPLOOSH (params-dependent
-- controller efx - it needed its parent gimmick's parameters; Aurora 07-23)
M.chip_efx = M.chip_efx_tree                 -- lab test slot
M.chip_scale = 0.5
function _spawn_chip_fx(x, y, z, override_path)
    local ok, err = pcall(function()
        local res = sdk.create_resource("via.effect.EffectResource", override_path or M.chip_efx)
        assert(res, "efx resource nil")
        res = res:add_ref()
        local holdr = res:create_holder("via.effect.EffectResourceHolder"):add_ref()
        assert(holdr, "holder nil")
        local ego = sdk.find_type_definition("via.GameObject"):get_method("create(System.String)"):call(nil, "IrisChipFx")
        assert(ego, "fx GO nil")
        ego = ego:add_ref()
        ego:call("get_Transform"):call("set_Position", Vector3f.new(x, y, z))
        local cs = M.chip_scale or 1.0
        if cs ~= 1.0 then pcall(function() ego:call("get_Transform"):call("set_LocalScale", Vector3f.new(cs, cs, cs)) end) end
        local ep = ego:call("createComponent(System.Type)", sdk.typeof("via.effect.EffectPlayer"))
        assert(ep, "EffectPlayer nil")
        ep:call("set_Resource", holdr)
        ep:call("set_AutoStart", true)
        chip_fx_live = chip_fx_live or {}   -- _G on purpose (200-local cap)
        chip_fx_live[#chip_fx_live + 1] = { go = ego, held = { res, holdr }, at = os.clock() + 3.0 }
    end)
    _log("chip fx spawn (" .. tostring(override_path or M.chip_efx) .. "): " .. (ok and "OK" or ("FAILED - " .. tostring(err))))
    return ok
end

-- ── CHOP SOUND (native WOOD_DMG triggers posted through the player's Wwise container - the
-- horse template-posting recipe, but with the game's OWN wood-damage bank)
local sound_lab = { triggers = nil, idx = 0, chop_trigger = nil }
local SND_REQUEST_SIG = "createRequestInfo(soundlib.SoundTriggerInfo, via.GameObject, via.GameObject, "
    .. "System.UInt32, System.Boolean, System.Boolean, System.UInt32, via.simplewwise.CallbackType, "
    .. "System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>, "
    .. "System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>)"

local function _snd_dispatcher()
    local ch
    pcall(function()
        ch = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
        local inner = ch and ch:call("get_Character")
        ch = inner or ch
    end)
    if not ch then return nil end
    local w
    pcall(function() w = ch:get_field("<WwiseContainer>k__BackingField") end)
    if not w then pcall(function() w = ch:call("get_WwiseContainer") end) end
    return w
end

local function _snd_load_triggers()
    if sound_lab.triggers and #sound_lab.triggers > 0 then return true end
    sound_lab.triggers = nil
    local ok = pcall(function()
        local ld
        for _, p in ipairs({ "Sound/Resource/DAMAGE/WOOD_DMG/WOOD_DMG_ContainerListData.user",
                             "Sound/Resource/DAMAGE/WOOD_DMG/WOOD_DMG_ContainerListData.user.2" }) do
            pcall(function() ld = sdk.create_userdata("soundlib.SoundTriggerInfoListData", p) end)
            if ld then break end
        end
        if not ld then return end
        ld = ld:add_ref()
        pcall(function() ld:add_ref_permanent() end)
        -- register with the player's dispatcher once (native bank likely resident; harmless if so)
        pcall(function()
            local d = _snd_dispatcher()
            if d then d:call("loadContainableUserData(soundlib.SoundContainableUserData)", ld) end
        end)
        local list = ld._TriggerInfoList
        local n = 0
        pcall(function() n = tonumber(list:call("get_Count")) or 0 end)
        if n == 0 then pcall(function() n = tonumber(list:call("get_Length")) or 0 end) end
        if n == 0 then pcall(function() n = tonumber(list:get_size()) or 0 end) end
        sound_lab.triggers = {}
        for i = 0, (tonumber(n) or 0) - 1 do
            pcall(function()
                local tr
                pcall(function() tr = list:call("get_Item", i) end)
                if not tr then pcall(function() tr = list:get_element(i) end) end
                if not tr then tr = list[i] end
                if tr then sound_lab.triggers[#sound_lab.triggers + 1] = { obj = tr, id = tonumber(tr._TriggerId) or -1 } end
            end)
        end
        _log("SOUND LAB: WOOD_DMG list count=" .. tostring(n) .. " captured=" .. #sound_lab.triggers)
        sound_lab.holder = ld
    end)
    return ok and sound_lab.triggers and #sound_lab.triggers > 0
end

local function _snd_post(trigger, target_go)
    local ok2 = false
    pcall(function()
        local d = _snd_dispatcher()
        if not (d and trigger) then return end
        local jh = 0
        pcall(function() jh = tonumber(trigger.obj._OffsetJointHash) or 0 end)
        local req = d:call(SND_REQUEST_SIG, trigger.obj, target_go, target_go, jh, false, false, 0, 0, nil, nil, nil, nil)
        if req then
            req = req:add_ref()
            req["<Container>k__BackingField"] = d
            d:call("trigger(soundlib.SoundManager.RequestInfo)", req)
            ok2 = true
        end
    end)
    return ok2
end

-- ── SOUND SNIFFER: passive Wwise capture (the AnimalWwiseRecorder surfaces, unfiltered) - arm a
-- 10s window, whack a wooden thing, every trigger that FIRES gets listed with a REPLAY button.
-- The raw overloads take PLAIN uint ids: container:trigger(id, GO) - capture once, replay forever.
local sniffer = { events = {}, until_t = 0 }

local function _sniff_capture(container, trigger_id, target_name)
    if os.clock() >= sniffer.until_t then return end
    local id = tonumber(trigger_id) or 0
    if id == 0 then return end
    -- ONE row per unique id for the whole session (Aurora: repeats pushed everything away);
    -- rows keep first-seen order so the list never jumps under the cursor
    for _, e in ipairs(sniffer.events) do
        if e.id == id then e.n = (e.n or 1) + 1; return end
    end
    if #sniffer.events >= 20 then return end   -- full: keep what we have, stay stable
    pcall(function() container = container:add_ref() end)
    sniffer.events[#sniffer.events + 1] = { id = id, cont = container, tgt = tostring(target_name or "?"), n = 1 }
end

-- ⛔⛔ LAZY-INSTALLED, NOT AT BOOT (2026-08-04, the load-in AV). These six hooks used to install at
-- script load and run Lua on EVERY Wwise trigger in the game, every boot, armed or not - the exact
-- AnimalWwiseRecorder pattern whose removal fixed the morning's griffin crash, and Aurora's load-in
-- crash stack was full of AK:: (Wwise) frames. A save-load fires hundreds of triggers while the
-- world streams; a Lua callback on the audio path during that window is a standing AV risk. The
-- game can't unhook, but it can NOT-hook: these now install the FIRST time the sniffer is armed,
-- so a boot that never arms it carries zero audio-thread Lua.
local function _install_sniffer_hooks()
    if sniffer.hooked then return end
    sniffer.hooked = true
    pcall(function()
    local surfaces = {
        { "app.WwiseContainerApp", "trigger(soundlib.SoundManager.RequestInfo)", "request" },
        { "app.WwiseContainerApp", "trigger(System.UInt32)", "raw" },
        { "app.WwiseContainerApp", "trigger(System.UInt32, via.GameObject)", "raw" },
        { "app.WwiseContainerApp", "trigger(System.UInt32, via.GameObject, via.GameObject)", "raw" },
        { "app.WwiseContainerApp", "trigger(System.UInt32, via.vec3, via.GameObject)", "raw" },
        { "app.WwiseContainerApp", "triggerLogLess(System.UInt32, via.GameObject, via.GameObject)", "raw" },
    }
    for _, sfc in ipairs(surfaces) do
        pcall(function()
            local m = sdk.find_type_definition(sfc[1]):get_method(sfc[2])
            if not m then return end
            local mode = sfc[3]
            sdk.hook(m, function(args)
                if os.clock() >= sniffer.until_t then return end
                pcall(function()
                    local cont = sdk.to_managed_object(args[2])
                    if not cont then return end
                    local id, tgt
                    if mode == "request" then
                        local req = sdk.to_managed_object(args[3])
                        id = req and req:call("get_TriggerId")
                    else
                        id = sdk.to_int64(args[3]) & 0xffffffff
                        local tg = sdk.to_managed_object(args[5]) or sdk.to_managed_object(args[4])
                        pcall(function() tgt = tg and tg:call("get_Name") end)
                    end
                    if not tgt then
                        pcall(function() tgt = cont:call("get_GameObject"):call("get_Name") end)
                    end
                    _sniff_capture(cont, id, tgt)
                end)
            end, function(r) return r end)
        end)
    end
    end)
    _log("sound sniffer hooks installed (on demand)")
end

-- arm the chop sound from its home files (Aurora's browser find): CH_COMMON container list +
-- liv_and_rol trigger sub-list, both loaded into the player's dispatcher, trigger found by id
function _arm_chop_sound()
    if sound_lab.chop_trigger or not M.chop_raw_id then return end
    pcall(function()
        local d = _snd_dispatcher()
        if not d then return end
        if not sound_lab.ch_common then
            local cont = sdk.create_userdata("soundlib.SoundContainerListData",
                "Sound/Resource/COMMON/CH_COMMON_SoundContainerListData.user")
            if cont then
                cont = cont:add_ref()
                pcall(function() cont:add_ref_permanent() end)
                pcall(function() d:call("loadContainableUserData(soundlib.SoundContainableUserData)", cont) end)
                sound_lab.ch_common = cont
            end
        end
        if not sound_lab.liv_list then
            local tl = sdk.create_userdata("soundlib.SoundTriggerInfoListData",
                "Sound/Resource/HM/NPC/NPC_COMMON/liv_and_rol/ch00_000_liv_TriggerInfoListData.user")
            if tl then
                tl = tl:add_ref()
                pcall(function() tl:add_ref_permanent() end)
                pcall(function() d:call("loadContainableUserData(soundlib.SoundContainableUserData)", tl) end)
                sound_lab.liv_list = tl
            end
        end
        local list = sound_lab.liv_list and sound_lab.liv_list._TriggerInfoList
        if not list then _log("chop sound: liv trigger list unreadable"); return end
        local n = 0
        pcall(function() n = tonumber(list:call("get_Count")) or 0 end)
        if n == 0 then pcall(function() n = tonumber(list:call("get_Length")) or 0 end) end
        for i = 0, n - 1 do
            local tr
            pcall(function() tr = list:call("get_Item", i) end)
            if not tr then pcall(function() tr = list:get_element(i) end) end
            if tr and tonumber(tr._TriggerId) == M.chop_raw_id then
                sound_lab.chop_trigger = { obj = tr, id = M.chop_raw_id }
                break
            end
        end
        _log("chop sound armed: id " .. tostring(M.chop_raw_id) .. " found=" .. tostring(sound_lab.chop_trigger ~= nil) .. " (list n=" .. n .. ")")
    end)
end

-- arm the FELL sound from the TREE family's home files (2026-07-23 offline byte-scan: trigger
-- 380082715 lives in gm_tree_TriggerInfoListData - shared across ~74 gimmick families, but the
-- tree list is its natural home). Loading bank+containers+triggers into the player's dispatcher
-- makes it host-independent: no live gimmick tree needed as the speaker (Aurora's report: wild
-- fells go silent when no gimmick tree is in the scene to borrow).
function _arm_fell_sound()
    if sound_lab.fell_trigger or not M.fell_raw_id then return end
    pcall(function()
        local d = _snd_dispatcher()
        if not d then return end
        if not sound_lab.tree_bank then
            -- bank first so the samples are resident; class name probed (chop never needed this
            -- because CH_COMMON's bank is always resident)
            for _, tn in ipairs({ "soundlib.SoundBankListData", "soundlib.BankListData" }) do
                local bk
                pcall(function() bk = sdk.create_userdata(tn, "Sound/Resource/GM/gmtree/gm_tree_BankListData.user") end)
                if bk then
                    bk = bk:add_ref()
                    pcall(function() bk:add_ref_permanent() end)
                    pcall(function() d:call("loadContainableUserData(soundlib.SoundContainableUserData)", bk) end)
                    sound_lab.tree_bank = bk
                    _log("fell sound: tree bank loaded as " .. tn)
                    break
                end
            end
        end
        if not sound_lab.tree_cont then
            local cont = sdk.create_userdata("soundlib.SoundContainerListData",
                "Sound/Resource/GM/gmtree/gm_tree_ContainerListData.user")
            if cont then
                cont = cont:add_ref()
                pcall(function() cont:add_ref_permanent() end)
                pcall(function() d:call("loadContainableUserData(soundlib.SoundContainableUserData)", cont) end)
                sound_lab.tree_cont = cont
            end
        end
        if not sound_lab.tree_trig then
            local tl = sdk.create_userdata("soundlib.SoundTriggerInfoListData",
                "Sound/Resource/GM/gmtree/gm_tree_TriggerInfoListData.user")
            if tl then
                tl = tl:add_ref()
                pcall(function() tl:add_ref_permanent() end)
                pcall(function() d:call("loadContainableUserData(soundlib.SoundContainableUserData)", tl) end)
                sound_lab.tree_trig = tl
            end
        end
        local list = sound_lab.tree_trig and sound_lab.tree_trig._TriggerInfoList
        if not list then _log("fell sound: gm_tree trigger list unreadable"); return end
        local n = 0
        pcall(function() n = tonumber(list:call("get_Count")) or 0 end)
        if n == 0 then pcall(function() n = tonumber(list:call("get_Length")) or 0 end) end
        for i = 0, n - 1 do
            local tr
            pcall(function() tr = list:call("get_Item", i) end)
            if not tr then pcall(function() tr = list:get_element(i) end) end
            if tr and tonumber(tr._TriggerId) == M.fell_raw_id then
                sound_lab.fell_trigger = { obj = tr, id = M.fell_raw_id }
                break
            end
        end
        _log("fell sound armed: id " .. tostring(M.fell_raw_id) .. " found=" .. tostring(sound_lab.fell_trigger ~= nil) .. " (gm_tree list n=" .. n .. ")")
    end)
end

local function _sniff_replay(ev, target_go)
    -- shotgun replay: every trigger overload, preferring the container's OWN GameObject as the
    -- stage (many triggers only voice on their host), falling back to the supplied target
    local hosts = {}
    pcall(function()
        local hg = ev.cont:call("get_GameObject")
        if hg then hosts[#hosts + 1] = hg end
    end)
    if target_go then hosts[#hosts + 1] = target_go end
    local report = {}
    for _, host in ipairs(hosts) do
        for _, sig in ipairs({
            "trigger(System.UInt32, via.GameObject, via.GameObject)",
            "trigger(System.UInt32, via.GameObject)",
            "triggerLogLess(System.UInt32, via.GameObject, via.GameObject)",
            "trigger(System.UInt32)",
        }) do
            local ok = pcall(function()
                if sig == "trigger(System.UInt32)" then
                    ev.cont:call(sig, ev.id)
                elseif sig:find("GameObject, via.GameObject") then
                    ev.cont:call(sig, ev.id, host, host)
                else
                    ev.cont:call(sig, ev.id, host)
                end
            end)
            report[#report + 1] = (ok and "ok" or "X")
        end
    end
    local hits = 0
    for _, r in ipairs(report) do if r == "ok" then hits = hits + 1 end end
    return hits > 0, hits .. " routes fired (" .. table.concat(report, ",") .. ")"
end

-- ── WILD TREES: the whole forest answers the axe. Scenery trees = via.landscape.Foliage
-- SpeedTree INSTANCES (proven by the homestead site-scout); 3 chops -> setVisibility(i,false)
-- (the grass-clear recipe) + the big fell-burst + timber. They regrow on area reload.
local wild = { hp = {}, cache = nil, felled = {} }
-- ghost-tree guard (Aurora 07-23: a felled tree kept giving full break cycles + timber). The
-- getVisibility readback is fail-open (pcall + default true) and evidently does NOT reflect
-- setVisibility - so we keep our OWN felled ledger by position key. TTL matches regrowth:
-- trees come back on area reload, so after 10 min the spot is choppable again.
local WILD_FELLED_TTL = 600.0
local function _wild_is_felled(key)
    local t = wild.felled[key]
    if not t then return false end
    if os.clock() - t > WILD_FELLED_TTL then wild.felled[key] = nil; return false end
    return true
end
M.wild_trees = true
M.wild_hits = 3

-- ── felled-tree HIDE (Aurora 07-24: "some trees don't disappear though they do the whole
-- knock>break>timber cycle"). SpeedTree per-instance setVisibility is FLAKY: getVisibility
-- doesn't even reflect it, streaming/LOD can pop a hidden instance back, and some trees are
-- two co-located instances (hiding just the one the ray hit leaves a twin). So we (1) hide the
-- whole cluster at the felled spot and (2) re-assert the hide on a timer until regrowth TTL. ──
M.wild_fell_radius = 1.0    -- hide every foliage instance within this many metres of the fell spot
wild.hide_watch = wild.hide_watch or {}

local function _set_foliage_visibility(comp, index, visible)
    if not comp or not sdk.is_managed_object(comp) then return false end
    index = tonumber(index)
    if not index or index < 0 then return false end
    local count = nil
    pcall(function() count = tonumber(comp:call("get_InstanceCount")) end)
    if not count or index >= count then return false end
    return pcall(function()
        comp:call("setVisibility(System.UInt32, System.Boolean)", index, visible)
    end)
end

local function _hide_foliage_cluster(comp, cx, cz, radius)
    local hidden = {}
    if not comp then return hidden end
    local r2 = (radius or 1.0) ^ 2
    pcall(function()
        local cnt = tonumber(comp:call("get_InstanceCount")) or 0
        local budget = 0
        for k = 0, cnt - 1 do
            budget = budget + 1
            if budget > 40000 then break end            -- freeze law
            local wp
            pcall(function() wp = comp:call("getWorldPosition", k) end)
            if wp then
                local dx, dz = wp.x - cx, wp.z - cz
                if dx * dx + dz * dz <= r2 then
                    if _set_foliage_visibility(comp, k, false) then
                        hidden[#hidden + 1] = k
                    end
                end
            end
        end
    end)
    return hidden
end
local _reassert_at = 0.0
local function _reassert_felled_hide()
    local now = os.clock()
    if now - _reassert_at < 1.2 then return end          -- gentle: ~once a second
    _reassert_at = now
    for ei = #wild.hide_watch, 1, -1 do
        local e = wild.hide_watch[ei]
        if not e or (now - (e.at or 0)) > WILD_FELLED_TTL then
            table.remove(wild.hide_watch, ei)             -- expired -> the spot may regrow
        else
            pcall(function()
                for _, k in ipairs(e.idxs or {}) do
                    -- confirm index k is STILL our felled instance (guards streaming reshuffle),
                    -- then blindly re-hide it (getVisibility is unreliable, so don't trust a read)
                    local wp = e.comp:call("getWorldPosition", k)
                    if wp then
                        local dx, dz = wp.x - e.x, wp.z - e.z
                        if dx * dx + dz * dz <= 1.5 then
                            _set_foliage_visibility(e.comp, k, false)
                        end
                    end
                end
            end)
        end
    end
end
re.on_frame(function() pcall(_reassert_felled_hide) end)

local function _wild_tree_strike(pp, fwd, cone_cos)
    local reach = math.min(M.chop_range or 6.0, 4.5)   -- wild trees want CLOSE work (the
    -- accidental-timber bug: a 6m range paid out a tree behind a stray click)
    local best, bestd
    if wild.cache then
        local c = wild.cache
        if os.clock() - (c.at or 0) < 12.0 then   -- stale targets expire
            local dx, dz = c.pos.x - pp.x, c.pos.z - pp.z
            local d = math.sqrt(dx * dx + dz * dz)
            local vis = true
            pcall(function() vis = c.comp:call("getVisibility", c.i) ~= false end)
            local in_cone = true
            if cone_cos and d > 2.5 and d > 0.001 then   -- the cache must respect the aim too
                in_cone = ((dx / d) * fwd.x + (dz / d) * fwd.z) >= cone_cos
            end
            local ckey = string.format("%.1f_%.1f", c.pos.x, c.pos.z)
            if vis and in_cone and d <= reach + 0.5 and not _wild_is_felled(ckey) then best = c; bestd = d end
        end
    end
    if not best then
        pcall(function()
            local smgr = sdk.get_native_singleton("via.SceneManager")
            local scene = smgr and sdk.call_native_func(smgr, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
            local arr = scene and scene:call("findComponents(System.Type)", sdk.typeof("via.landscape.Foliage"))
            local n = arr and arr:get_size() or 0
            local budget = 0
            for i = 0, n - 1 do
                local c = arr:get_element(i)
                local speed = false
                pcall(function() speed = c and c:call("isSpeedTreeMesh", 0) == true end)
                local comp_addr = tostring(c)
                if speed then
                    local cnt = 0
                    pcall(function() cnt = tonumber(c:call("get_InstanceCount")) or 0 end)
                    for k = 0, cnt - 1 do
                        budget = budget + 1
                        if budget > 60000 then return end   -- freeze law
                        local wp2
                        pcall(function() wp2 = c:call("getWorldPosition", k) end)
                        if wp2 then
                            local dx, dz = wp2.x - pp.x, wp2.z - pp.z
                            local d2 = dx * dx + dz * dz
                            if d2 <= reach ^ 2 and (not bestd or d2 < bestd * bestd)
                                and not _wild_is_felled(string.format("%.1f_%.1f", wp2.x, wp2.z)) then
                                local vis = true
                                pcall(function() vis = c:call("getVisibility", k) ~= false end)
                                if vis then
                                    local d = math.sqrt(d2)
                                    local in_cone = true
                                    if cone_cos and d > 2.5 and d > 0.001 then
                                        in_cone = ((dx / d) * fwd.x + (dz / d) * fwd.z) >= cone_cos
                                    end
                                    if in_cone then
                                        -- TREES HAVE TRUNKS (Aurora deforested a wheatfield: the
                                        -- mesh path is unreadable, so classify by ANATOMY - real
                                        -- trees carry layer-2 trunk collision, wheat/grass don't)
                                        wild.kinds = wild.kinds or {}
                                        local kindok = wild.kinds[comp_addr]
                                        if kindok == nil then
                                            kindok = false
                                            pcall(function()
                                                if not _ensure_ray() then kindok = true; return end   -- no ray = fail open
                                                local hits = 0
                                                for _, axis in ipairs({ { 1.5, 0 }, { 0, 1.5 } }) do
                                                    ray.filter:set_Group(0); ray.filter:set_Layer(2); ray.filter:set_MaskBits(0)
                                                    ray.result:clear()
                                                    ray.query:call("setRay(via.vec3, via.vec3)",
                                                        _vec3(wp2.x - axis[1], wp2.y + 1.0, wp2.z - axis[2]),
                                                        _vec3(wp2.x + axis[1], wp2.y + 1.0, wp2.z + axis[2]))
                                                    ray.method:call(ray.system, ray.query, ray.result)
                                                    hits = hits + (ray.result:get_NumContactPoints() or 0)
                                                end
                                                kindok = hits > 0
                                            end)
                                            wild.kinds[comp_addr] = kindok
                                            _log(string.format("wild trunk-test @(%.1f,%.1f): %s", wp2.x, wp2.z, kindok and "TREE" or "no trunk (wheat/grass/bush)"))
                                        end
                                        if kindok then
                                            best = { comp = c, i = k, pos = { x = wp2.x, y = wp2.y, z = wp2.z }, at = os.clock() }
                                            bestd = d
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end)
    end
    if not best then wild.cache = nil; return false end
    wild.cache = best
    local pos = best.pos
    local key = string.format("%.1f_%.1f", pos.x, pos.z)
    wild.hp[key] = (wild.hp[key] or 0) + 1
    _spawn_chip_fx(pos.x, pos.y + 1.2, pos.z, M.chip_efx_tree)
    _arm_chop_sound()
    _arm_fell_sound()   -- arm DURING the chops: at fell time the bank was still async-loading
                        -- (Aurora 07-23: first fell silent, second sounded)
    if sound_lab.chop_trigger then
        pcall(function()
            local pgo = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer"):call("get_GameObject")
            _snd_post(sound_lab.chop_trigger, pgo)
        end)
    end
    if wild.hp[key] >= (M.wild_hits or 3) then
        wild.hp[key] = nil
        wild.cache = nil
        wild.felled[key] = os.clock()   -- the ledger, not the API, decides "already felled"
        -- hide the WHOLE cluster at the spot (co-located twin instances included), remember the
        -- indices, and keep re-asserting: setVisibility alone is flaky + streaming re-shows it (Aurora 07-24)
        local idxs = _hide_foliage_cluster(best.comp, pos.x, pos.z, M.wild_fell_radius or 1.0)
        if #idxs == 0 and _set_foliage_visibility(best.comp, best.i, false) then
            idxs = { best.i }
        end
        wild.hide_watch[#wild.hide_watch + 1] = { comp = best.comp, idxs = idxs, x = pos.x, z = pos.z, at = os.clock() }
        _log(string.format("wild fell hide: %d instance(s) at (%.1f,%.1f)", #idxs, pos.x, pos.z))
        -- the fell spectacle: the PROVEN small burst, doubled and scaled (the 110 big burst
        -- rendered nothing in Aurora's test) + the captured fall sound if one is set
        local keep = M.chip_scale
        M.chip_scale = 1.7
        _spawn_chip_fx(pos.x, pos.y + 1.0, pos.z, M.chip_efx_tree)
        _spawn_chip_fx(pos.x, pos.y + 2.6, pos.z, M.chip_efx_tree)
        M.chip_scale = keep
        -- FELL SOUND (Aurora's capture: 380082715 = gm80_110's fall): FIRST the host-independent
        -- gm_tree home-file route (armed like the chop sound - works with zero gimmick trees in
        -- the scene), THEN borrow any live gimmick tree's container, THEN the captured ev.
        if M.fell_raw_id then
            local played = false
            _arm_fell_sound()
            if sound_lab.fell_trigger then
                pcall(function()
                    local pgo = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer"):call("get_GameObject")
                    played = _snd_post(sound_lab.fell_trigger, pgo)
                end)
            end
            if not played then pcall(function()
                local pgo = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer"):call("get_GameObject")
                local sm = sdk.get_native_singleton("via.SceneManager")
                local scene = sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
                local comps = scene:call("findComponents(System.Type)", sdk.typeof("app.GimmickBase"))
                local n = 0
                pcall(function() n = comps:call("get_Length") or 0 end)
                if n == 0 then pcall(function() n = comps:get_size() or 0 end) end
                for ci = 0, (tonumber(n) or 0) - 1 do
                    local c
                    pcall(function() c = comps:call("get_Item", ci) end)
                    if not c then pcall(function() c = comps:get_element(ci) end) end
                    if c and TREE_SET[c:get_type_definition():get_full_name()] then
                        local wc = c:call("get_GameObject"):call("getComponent(System.Type)", sdk.typeof("app.WwiseContainerApp"))
                        if wc then
                            played = _sniff_replay({ cont = wc, id = M.fell_raw_id }, pgo)
                            if played then return end
                        end
                    end
                end
            end) end
            if not played and sound_lab.fell_raw then
                pcall(function()
                    local pgo = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer"):call("get_GameObject")
                    _sniff_replay(sound_lab.fell_raw, pgo)
                end)
            end
        end
        local got = _grant_yield("TREE")
        if got > 0 then M.gather_at = os.clock() + 0.9 end
        M.last = string.format("wild tree FELLED! +%d Timber", got)
        _log(M.last .. " @" .. key)
    else
        M.last = string.format("wild tree: chop %d/%d", wild.hp[key], M.wild_hits or 3)
        _log(M.last)
    end
    return true
end

-- ── WILD ROCKS (2026-07-23, Aurora: "rocky scenery... raycast like the trees to mine those"):
-- static scenery rocks (the sm1x families the composite dumps taught us: sm10-13 boulders/
-- cliffs) become minable VEINS. Unlike trees they never disappear - N strikes pays Stone,
-- then the spot is spent for WILD_FELLED_TTL (the "R" ledger prefix keeps rocks and trees
-- from colliding in wild.hp/felled). Detection = via.render.Mesh sweep, AABB-center cull
-- first (cheap) then resource-path check (environment + /sm1x/) for the near ones only.
M.wild_rocks = true
M.rock_hits = 4
M.rock_spend_radius = 6.0
-- rock veins spend by AREA, not point (Aurora 07-23: outcrops are CLUSTERS of stacked sm1x
-- instances - spending one still left 7 neighbors in arm's reach = infinite stone). A payout
-- marks the whole neighborhood spent for WILD_FELLED_TTL.
wild.rspent = wild.rspent or {}
local function _rock_spent(x, z)
    for i = #wild.rspent, 1, -1 do
        local s = wild.rspent[i]
        if os.clock() - s.t > WILD_FELLED_TTL then
            table.remove(wild.rspent, i)
        else
            local dx, dz = x - s.x, z - s.z
            if dx * dx + dz * dz < (M.rock_spend_radius or 6.0) ^ 2 then return true end
        end
    end
    return false
end
-- collect minable rock positions near pp: standalone sm1x prop meshes AND composite
-- instances (Aurora 07-23: the big outcrops she was swinging at live inside
-- via.render.CompositeMesh blobs - the same discovery as the annex shed; the instance
-- walk is today's proven extractor API: getInstanceGroup -> get_Mesh/getTransform)
local function _sweep_rocks(pp, radius, cap)
    local out = {}
    local r2 = radius * radius
    pcall(function()
        local smgr = sdk.get_native_singleton("via.SceneManager")
        local scene = smgr and sdk.call_native_func(smgr, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        local arr = scene and scene:call("findComponents(System.Type)", sdk.typeof("via.render.Mesh"))
        local n = arr and arr:get_size() or 0
        for i = 0, math.min(n, 9000) - 1 do
            if #out >= cap then break end
            pcall(function()
                local c = arr:get_element(i)
                local ab = c:call("get_WorldAABB")
                if not ab then return end
                local a, b = ab:get_field("minpos"), ab:get_field("maxpos")
                local cx, cy, cz = (a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2
                local dx, dz = cx - pp.x, cz - pp.z
                if dx * dx + dz * dz > r2 then return end
                local lp
                pcall(function() lp = c:call("getMesh"):call("get_ResourcePath"):lower() end)
                if not (lp and lp:find("environment/", 1, true) and lp:find("/sm1x/", 1, true)) then return end
                out[#out + 1] = { x = cx, y = math.max(cy, a.y + 1.0), z = cz }
            end)
        end
        local carr = scene and scene:call("findComponents(System.Type)", sdk.typeof("via.render.CompositeMesh"))
        local cn = carr and carr:get_size() or 0
        for i = 0, (tonumber(cn) or 0) - 1 do
            if #out >= cap then break end
            pcall(function()
                local mc = carr:get_element(i)
                local ab = mc:call("get_WorldAABB")
                if not ab then return end
                local a, b = ab:get_field("minpos"), ab:get_field("maxpos")
                -- box-vs-circle: composite boxes are HUGE, cull on overlap not center distance
                if pp.x < a.x - radius or pp.x > b.x + radius
                    or pp.z < a.z - radius or pp.z > b.z + radius then return end
                local gc = tonumber(mc:call("getInstanceGroupCount")) or 0
                for g = 0, gc - 1 do
                    if #out >= cap then break end
                    pcall(function()
                        local grp = mc:call("getInstanceGroup(System.UInt64)", g)
                        local mp
                        pcall(function() mp = tostring(grp:call("get_Mesh"):call("ToString()")):lower() end)
                        if not (mp and mp:find("/sm1x/", 1, true)) then return end
                        local tc = tonumber(grp:call("getTransformCount")) or 0
                        for k = 0, math.min(tc, 64) - 1 do
                            if #out >= cap then break end
                            pcall(function()
                                local t = grp:call("getTransform(System.UInt64)", k)
                                local p = t and t:call("get_Position")
                                if not p then return end
                                local dx, dz = p.x - pp.x, p.z - pp.z
                                if dx * dx + dz * dz > r2 then return end
                                out[#out + 1] = { x = p.x, y = p.y + 1.0, z = p.z }
                            end)
                        end
                    end)
                end
            end)
        end
    end)
    return out
end
local function _wild_rock_strike(pp, fwd, cone_cos)
    local reach = math.min(M.chop_range or 6.0, 4.5)
    local best, bestd
    if wild.rcache then
        local c = wild.rcache
        if os.clock() - (c.at or 0) < 12.0 then
            local dx, dz = c.pos.x - pp.x, c.pos.z - pp.z
            local d = math.sqrt(dx * dx + dz * dz)
            local in_cone = true
            if cone_cos and d > 2.0 and d > 0.001 then
                in_cone = ((dx / d) * fwd.x + (dz / d) * fwd.z) >= cone_cos
            end
            if in_cone and d <= reach + 1.5
                and not _rock_spent(c.pos.x, c.pos.z) then
                best = c; bestd = d
            end
        end
    end
    if not best then
        -- boulders are BIG: pivots/centers sit past arm's reach, so hunt reach+4
        for _, r in ipairs(_sweep_rocks(pp, reach + 4.0, 40)) do
            local dx, dz = r.x - pp.x, r.z - pp.z
            local d = math.sqrt(dx * dx + dz * dz)
            if not bestd or d < bestd then
                local in_cone = true
                if cone_cos and d > 2.0 and d > 0.001 then
                    in_cone = ((dx / d) * fwd.x + (dz / d) * fwd.z) >= cone_cos
                end
                if in_cone and not _rock_spent(r.x, r.z) then
                    best = { pos = { x = r.x, y = pp.y, z = r.z }, at = os.clock() }
                    bestd = d
                end
            end
        end
    end
    if not best then wild.rcache = nil; return false end
    wild.rcache = best
    local pos = best.pos
    local key = "R" .. string.format("%.1f_%.1f", pos.x, pos.z)
    wild.hp[key] = (wild.hp[key] or 0) + 1
    _spawn_chip_fx(pos.x, pos.y + 1.0, pos.z, M.chip_efx_stone)
    _arm_chop_sound()
    if sound_lab.chop_trigger then
        pcall(function()
            local pgo = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer"):call("get_GameObject")
            _snd_post(sound_lab.chop_trigger, pgo)
        end)
    end
    if wild.hp[key] >= (M.rock_hits or 4) then
        wild.hp[key] = nil
        wild.rcache = nil
        wild.rspent[#wild.rspent + 1] = { x = pos.x, z = pos.z, t = os.clock() }   -- the whole
        -- NEIGHBORHOOD spends (cluster law); the rock itself STAYS (it's scenery)
        local keep = M.chip_scale
        M.chip_scale = 1.4
        _spawn_chip_fx(pos.x, pos.y + 1.0, pos.z, M.chip_efx_stone)
        M.chip_scale = keep
        local got = _grant_yield("STONE")
        if got > 0 then M.gather_at = os.clock() + 0.9 end
        M.last = string.format("stone hewn from the rock! +%d Stone", got)
        _log(M.last .. " @" .. key)
    else
        M.last = string.format("wild rock: strike %d/%d", wild.hp[key], M.rock_hits or 4)
    end
    return true
end

local granted_breaks = {}   -- go addresses already paid out (native break beats our 0.45s strike)
local function _chop(kind_filter, cone_deg, payout_only)
    -- payout_only: the post-strike RECHECK - may collect from a freshly-broken rock, but must
    -- NEVER deal damage (the strike already did; double-chipping = double damage per swing)
    local t, err = _find_nearest_harvest(kind_filter, cone_deg)
    if not t then
        -- no gimmick tree took the swing: offer it to the WILD FOREST (axe swings only)
        if not payout_only and kind_filter == "TREE" and cone_deg and M.wild_trees then
            local hit = false
            pcall(function()
                local tf = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer"):call("get_GameObject"):call("get_Transform")
                local pp = tf:call("get_Position")
                local fwd = tf:call("get_AxisZ")
                -- wild trees use their own NARROW cone (Aurora: 75 deg picked up bystander trees)
                hit = _wild_tree_strike(pp, fwd, math.cos(math.rad(M.wild_cone or 35.0)))
            end)
            if hit then return end
        end
        -- ...or to the WILD ROCKS (pickaxe swings only)
        if not payout_only and kind_filter == "STONE" and cone_deg and M.wild_rocks then
            local hit = false
            pcall(function()
                local tf = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer"):call("get_GameObject"):call("get_Transform")
                local pp = tf:call("get_Position")
                local fwd = tf:call("get_AxisZ")
                hit = _wild_rock_strike(pp, fwd, math.cos(math.rad(M.wild_cone or 35.0)))
            end)
            if hit then return end
        end
        if not payout_only then M.last = err end
        return
    end
    local name = "?"
    pcall(function() name = t.go:call("get_Name") end)
    local broken = false
    pcall(function() broken = t.comp:call("get_IsBroken") == true end)
    if broken then
        -- NATIVE-BREAK PAYOUT (Aurora's find: her real pick impact broke a poolless rock before
        -- the scheduled strike arrived -> "broke but no stone"). Swing strikes (cone_deg set) pay
        -- out on a freshly-shattered rock exactly once per rock.
        local addr = tostring(t.go)
        if (cone_deg or payout_only) and not granted_breaks[addr] then
            granted_breaks[addr] = true
            local count = 0
            for _ in pairs(granted_breaks) do count = count + 1 end
            if count > 64 then granted_breaks = { [addr] = true } end
            local got = _grant_yield(t.kind)
            if got > 0 then M.gather_at = os.clock() + 0.9 end
            M.last = string.format("%s shattered by the blow! +%d %s", tostring(name),
                got, t.kind == "STONE" and "Stone" or "Timber")
            _log(M.last)
        elseif not payout_only then
            M.last = tostring(name) .. " is already felled"
        end
        return
    end
    if payout_only then return end   -- unbroken rock: the recheck never chips
    local hp, maxhp = 0, 0
    pcall(function() hp = tonumber(t.comp:call("getHp")) or 0 end)
    pcall(function() maxhp = tonumber(t.comp:call("getMaxHp")) or 0 end)
    if M.instant then
        pcall(function() t.comp:call("setDeadHp") end)
        local ok = pcall(function() t.comp:call("executeBreak(System.Boolean)", true) end)
        M.last = string.format("FELLED %s (executeBreak ok=%s)", tostring(name), tostring(ok))
        _log(M.last)
        return
    end
    if maxhp <= 0 then
        -- poolless break-on-hit object: no HP math, just fell/crumble it directly
        pcall(function() t.comp:call("setDeadHp") end)
        local ok = pcall(function() t.comp:call("executeBreak(System.Boolean)", true) end)
        granted_breaks[tostring(t.go)] = true   -- paid HERE: the broken-path must never pay again (double-dip bug 16:07)
        local got = _grant_yield(t.kind)
        if got > 0 then M.gather_at = os.clock() + 0.9 end   -- bow-and-collect after the debris settles
        M.last = string.format("CHOP -> %s %s! +%d %s",
            tostring(name), t.kind == "STONE" and "CRUMBLES" or "FALLS",
            got, t.kind == "STONE" and "Stone" or "Timber")
        _log(M.last)
        return
    end
    local dmg = maxhp * (M.chop_pct / 100.0)
    local newhp = hp - dmg
    if newhp <= 0 then
        pcall(function() t.comp:call("setDeadHp") end)
        local ok = pcall(function() t.comp:call("executeBreak(System.Boolean)", true) end)
        granted_breaks[tostring(t.go)] = true   -- paid HERE: no broken-path second helping
        local got = _grant_yield(t.kind)
        if got > 0 then M.gather_at = os.clock() + 0.9 end   -- bow-and-collect after the debris settles
        M.last = string.format("CHOP -> %s %s! +%d %s",
            tostring(name), t.kind == "STONE" and "CRUMBLES" or "FALLS",
            got, t.kind == "STONE" and "Stone" or "Timber")
    else
        pcall(function() t.comp:call("setHp", newhp) end)
        -- IMPACT FEEDBACK on non-breaking chips: the tree pfb carries a native "nonbreak" hit VFX
        -- (13_gmdy_nonbreak_Ref.pfb) + WOOD_DMG sounds. Doorways (probe-dumped): the gimmick's
        -- requestEffectHit, WwiseDamageController.onDamageHit (sound) and the EPV trigger unit's
        -- callbackHit (chips) - ALL take app.HitController.DamageInfo (the PROVEN synthetic type;
        -- "app.DamageInfo" doesn't exist, which is why v1 was silent).
        pcall(function() t.comp:call("requestEffectShake") end)
        pcall(function()
            local di
            pcall(function() di = sdk.create_instance("app.HitController.DamageInfo") end)
            if not di then pcall(function() di = sdk.create_instance("app.HitController.DamageInfo", true) end) end
            if not di then return end
            di = di:add_ref()
            pcall(function() di:set_field("Damage", dmg) end)
            pcall(function() di:set_field("DamageRate", 1.0) end)
            pcall(function() di:set_field("IsDirectDamage", true) end)
            pcall(function()
                local pgo = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer"):call("get_GameObject")
                di:set_field("<AttackGameObject>k__BackingField", pgo)
                di:set_field("<AttackOwnerObject>k__BackingField", pgo)
            end)
            pcall(function() t.comp:call("requestEffectHit(app.HitController.DamageInfo)", di) end)
            -- knock on the sound + VFX handlers on the tree's own GO
            pcall(function()
                local arr = t.go:call("get_Components")
                local nn = 0
                pcall(function() nn = arr:get_size() or 0 end)
                for ci = 0, (tonumber(nn) or 0) - 1 do
                    pcall(function()
                        local comp = arr:get_element(ci)
                        local tnm = comp:get_type_definition():get_full_name()
                        if tnm:find("WwiseDamageController") then
                            comp:call("onDamageHit(app.HitController.DamageInfo)", di)
                        elseif tnm:find("DamageTriggerUnit") then
                            comp:call("callbackHit(app.HitController.DamageInfo)", di)
                        end
                    end)
                end
            end)
        end)
        -- DIRECT LANE v2 (the Ref.pfb was a DEFINITIONS container, not an emitter): play the RAW
        -- .efx inside it on our own GO - the sand-lab law, griffin-thunder recipe verbatim
        pcall(function()
            local rp = t.go:call("get_Transform"):call("get_Position")
            _spawn_chip_fx(rp.x, rp.y + 1.1, rp.z, t.kind == "STONE" and M.chip_efx_stone or M.chip_efx_tree)
        end)
        -- CHOP SOUND v3 (Aurora's sound-browser screenshots = the answer key): trigger 522710159
        -- lives in CH_COMMON container list + the liv_and_rol trigger SUB-list. Load BOTH into the
        -- player's dispatcher (the horse recipe), find the SoundTriggerInfo by id, post properly.
        _arm_chop_sound()
        if sound_lab.chop_trigger then
            pcall(function() _snd_post(sound_lab.chop_trigger, t.go) end)
        elseif sound_lab.chop_raw then
            pcall(function() _sniff_replay(sound_lab.chop_raw, t.go) end)
        end
        M.last = string.format("CHOP %s: hp %.0f -> %.0f (max %.0f, %.1fm)", tostring(name), hp, newhp, maxhp, t.d)
    end
    _log(M.last)
end

-- ── TREE HP WATCH: live HP readout over the nearest tree - whack it with your WEAPON and see if
-- native combat damage registers (the census saw collision rigs combat-damaged, so it should).
-- If yes: woodcutting = REAL swings (Aurora's design) + an axe damage-bonus + drops. No jack.
M.hp_watch = false
local watch = nil
local watch_f = 0
-- (TREE_SET/ROCK_SET now declared ONCE at the top of the file - the nil-scope lesson)

re.on_application_entry("UpdateBehavior", function()
    if not M.hp_watch then watch = nil; return end
    watch_f = watch_f + 1
    if watch_f < 30 then return end
    watch_f = 0
    pcall(function()
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local pl = cm and cm:call("get_ManualPlayer")
        local pp = pl and pl:call("get_GameObject"):call("get_Transform"):call("get_Position")
        if not pp then watch = nil; return end
        local sm = sdk.get_native_singleton("via.SceneManager")
        local smt = sdk.find_type_definition("via.SceneManager")
        local scene = sm and sdk.call_native_func(sm, smt, "get_CurrentScene")
        local comps = scene and scene:call("findComponents(System.Type)", sdk.typeof("app.GimmickBase"))
        local n = 0
        pcall(function() n = comps:call("get_Length") or 0 end)
        if n == 0 then pcall(function() n = comps:get_size() or 0 end) end
        local best, bestd
        for i = 0, (tonumber(n) or 0) - 1 do
            pcall(function()
                local c
                pcall(function() c = comps:call("get_Item", i) end)
                if not c then pcall(function() c = comps:get_element(i) end) end
                if not c then return end
                local tn = c:get_type_definition():get_full_name()
                local kind = TREE_SET[tn] and "TREE" or (ROCK_SET[tn] and "STONE" or nil)
                if not kind then return end
                local go = c:call("get_GameObject")
                local rp = go and go:call("get_Transform"):call("get_Position")
                if not rp then return end
                local dx, dz = rp.x - pp.x, rp.z - pp.z
                local d = math.sqrt(dx * dx + dz * dz)
                if d < 25.0 and (not bestd or d < bestd) then best = { comp = c, go = go, kind = kind }; bestd = d end
            end)
        end
        watch = best
    end)
end)

re.on_frame(function()
    if not (M.hp_watch and watch) then return end
    pcall(function()
        local hp = tonumber(watch.comp:call("getHp")) or -1
        local maxhp = tonumber(watch.comp:call("getMaxHp")) or -1
        local broken = false; pcall(function() broken = watch.comp:call("get_IsBroken") == true end)
        local rp = watch.go:call("get_Transform"):call("get_Position")
        rp.y = rp.y + 2.5
        local sp = draw.world_to_screen(rp)
        if sp then
            local txt = broken and (watch.kind == "STONE" and "SMASHED" or "FELLED")
                or string.format("%s HP %.0f / %.0f", watch.kind or "TREE", hp, maxhp)
            local col = broken and 0xFF6060FF or 0xFF60FF80
            -- global face (IrisFont law): queue on the shared d2d layer, draw.text as fallback
            if not (_G.IrisFont and _G.IrisFont.text and _G.IrisFont.text(txt, sp.x, sp.y, col, 19)) then
                draw.text(txt, sp.x, sp.y, col)
            end
        end
    end)
end)

-- ── TOOL AUDITION v2: cycle the eqit PREFABS (not raw meshes - create_resource can't cold-fetch,
-- the mcol lesson again; pfb loading CAN, the forge proved it). 53 held-tool pfbs from the filelist.
local EQIT_IDS = {
    "eqit02_000", "eqit02_002", "eqit02_005", "eqit02_008", "eqit03_000", "eqit03_004",
    "eqit09_001", "eqit10_001", "eqit10_002", "eqit10_003", "eqit10_004", "eqit10_005",
    "eqit10_006", "eqit10_007", "eqit10_008", "eqit10_011", "eqit10_030", "eqit10_031",
    "eqit10_032", "eqit10_033", "eqit50_005", "eqit50_007", "eqit50_010_01", "eqit50_013",
    "eqit50_029", "eqit50_031", "eqit50_032", "eqit50_033", "eqit50_035_00", "eqit50_042_01",
    "eqit50_044", "eqit50_055", "eqit50_096_00", "eqit50_298", "eqit51_046", "eqit51_367",
    "eqit80_161", "eqit80_162", "eqit80_163", "eqit81_010", "eqit81_012", "eqit81_028",
    "eqit81_029", "eqit81_031", "eqit81_148", "eqit81_157_00", "eqit81_178_00", "eqit81_178_01",
    "eqit82_052", "eqit99_600", "it03_005", "it03_006", "it03_007",
}
M.preview_idx = 1
local preview = nil        -- { go, id }
local preview_pfbs = {}    -- [id] = via.Prefab (permanent refs - survive reset, reused on revisit)
local pv_job = nil

-- Aurora's eqit CATALOGUE: label what each tool is as she walks the list; persists for every
-- future feature that needs a held prop (gardening hoe, stable pitchfork, ...). Seeded with the
-- 2026-07-22 audition finds.
local LABELS_FILE = "IRIS/eqit_labels.json"
local eqit_labels = json.load_file(LABELS_FILE) or {}
for id, lbl in pairs({ eqit02_005 = "pickaxe", eqit50_031 = "hoe (gardening)",
                       eqit50_096_00 = "pitchfork", eqit50_010_01 = "hatchet/axe (small)" }) do
    if not eqit_labels[id] then eqit_labels[id] = lbl end
end
M.label_buf = ""
local function _save_labels() pcall(function() json.dump_file(LABELS_FILE, eqit_labels) end) end
_save_labels()

local function _preview_despawn()
    if preview and preview.go then pcall(function() preview.go:call("destroy", preview.go) end) end
    preview = nil
end

local function _preview_spawn(path_override, label_override)
    _preview_despawn()
    local id = label_override or EQIT_IDS[M.preview_idx]
    if not id then M.last = "no such index"; return end
    local px, fwd
    pcall(function()
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local tf = cm:call("get_ManualPlayer"):call("get_GameObject"):call("get_Transform")
        px = tf:call("get_Position"); fwd = tf:call("get_AxisZ")
    end)
    if not px then M.last = "no player"; return end
    local pfb = (not path_override) and preview_pfbs[id] or nil   -- never reuse failed test prefabs
    if not pfb then
        local ok = pcall(function()
            pfb = sdk.create_instance("via.Prefab"):add_ref()
            pcall(function() pfb:add_ref_permanent() end)
            -- the forge's LOOSE-pfb recipe needs .ctor + Standby before the path (pak-served eqit
            -- files tolerated skipping these; loose files apparently don't)
            pcall(function() pfb:call(".ctor()") end)
            pfb:call("set_Path", path_override or ("AppSystem/Equipment/eqit/" .. id .. ".pfb"))
            pcall(function() pfb:call("set_Standby", true) end)
        end)
        if not (ok and pfb) then M.last = "prefab create failed for " .. id; return end
        if not path_override then preview_pfbs[id] = pfb end
    end
    pv_job = { pfb = pfb, id = id, f = 0,
               x = px.x + (fwd and fwd.x or 0) * 1.8, y = px.y + 1.2, z = px.z + (fwd and fwd.z or 1) * 1.8 }
    M.last = "loading " .. id .. " (" .. M.preview_idx .. "/" .. #EQIT_IDS .. ")..."
end

re.on_application_entry("UpdateBehavior", function()
    if not pv_job then return end
    local q = pv_job
    local ok, err = pcall(function()
        q.f = q.f + 1
        if q.pfb:call("get_Ready") == true then
            local inst
            local iok = pcall(function() inst = q.pfb:call("instantiate(via.vec3)", _vec3(q.x, q.y, q.z)) end)
            if (not iok) or not inst then pcall(function() inst = q.pfb:call("instantiate", _vec3(q.x, q.y, q.z)) end) end
            if inst then
                pcall(function() inst = inst:add_ref() end)
                preview = { go = inst, id = q.id }
                M.last = "previewing " .. q.id .. " (" .. M.preview_idx .. "/" .. #EQIT_IDS .. ") - is it a tool?"
                _log("TOOL PREVIEW: " .. q.id)
            else
                M.last = q.id .. " instantiate failed - NEXT past it"
            end
            pv_job = nil
        elseif q.f > 300 then
            M.last = q.id .. " never loaded (~5s) - NEXT past it"
            pv_job = nil
        end
    end)
    if not ok then _log("preview ERROR: " .. tostring(err)); pv_job = nil end
end)

re.on_frame(function()
    if not (preview and preview.go) then return end
    -- ⛔ the RESKIN DONOR is not an audition: it's an invisible prop kept alive only because it
    -- owns the mesh holders we stole. Labelling it put a floating "skin_donor (1/53)" in the world
    -- next to the player whenever a tool was in hand (Aurora 07-25).
    if preview.id == "skin_donor" then return end
    pcall(function()
        local rp = preview.go:call("get_Transform"):call("get_Position")
        local sp = draw.world_to_screen(Vector3f.new(rp.x, rp.y + 0.5, rp.z))
        if sp then
            local s = preview.id .. "  (" .. M.preview_idx .. "/" .. #EQIT_IDS .. ")"
            local lbl = eqit_labels[preview.id]
            if lbl and lbl ~= "" then s = s .. "  =  " .. lbl end
            if not (_G.IrisFont and _G.IrisFont.text and _G.IrisFont.text(s, sp.x, sp.y, 0xFFFFD060, 20)) then
                draw.text(s, sp.x, sp.y, 0xFFFFD060)
            end
        end
    end)
end)

-- ── PICKAXE IN HAND (v0.9, tonight's road): reskin the EQUIPPED weapon's mesh to the pickaxe.
-- No CE, no items, no save risk - pure runtime visual (the WildHorses setMesh trick) on your real
-- drawn weapon. Mesh holders are STOLEN from a live eqit02_005 instance (the mcol-heist pattern -
-- create_resource can't cold-fetch, a spawned donor's holders are guaranteed loaded).
local skin = { pending = false, applied = false }

-- ⛔⛔ THIS IS WHY THE HOE LOADED AS A HATCHET AND THE *LIFETAKER* CAME OUT AS A HOE
-- (Aurora 07-26, the decisive clue). This used to take the FIRST `wp` child carrying a mesh, with
-- NO weapon-ID check - while _pickaxe_wp_go() separately identifies the child whose app.Weapon.ID
-- is one of OUR tools. With two weapons equipped the two disagree, so the tool mesh got painted
-- onto whichever wp child happened to come first: the sword. Prefer the IDENTIFIED tool object.
-- (`skin` is the carrier because `mine` is declared ~100 lines BELOW this function - referencing
--  it here would silently resolve to a nil global.)
local function _find_wp_mesh()
    local mc, go
    -- the tool the pump actually identified, when it has one
    pcall(function()
        if skin.target_go then
            local m = skin.target_go:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
            if m then mc, go = m, skin.target_go end
        end
    end)
    if mc then return mc, go end
    pcall(function()
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local tf = cm:call("get_ManualPlayer"):call("get_GameObject"):call("get_Transform")
        local child = tf:call("get_Child")
        while child do
            local cgo = child:call("get_GameObject")
            local nm = tostring(cgo and cgo:call("get_Name") or "")
            if nm:find("^wp") then
                local m = cgo:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
                if m then mc, go = m, cgo; break end
            end
            child = child:call("get_Next")
        end
    end)
    return mc, go
end

local function _apply_skin()
    if not (preview and preview.go) then M.last = "skin: donor missing"; return end
    local wmc, wgo = _find_wp_mesh()
    if not wmc then M.last = "skin: no equipped weapon found (equip + draw first)"; return end
    local dmc
    pcall(function() dmc = preview.go:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh")) end)
    if not dmc then
        -- donor mesh may sit on a child
        pcall(function()
            local tf = preview.go:call("get_Transform"); local ch = tf and tf:call("get_Child")
            while ch and not dmc do
                local cgo = ch:call("get_GameObject")
                if cgo then dmc = cgo:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh")) end
                ch = ch:call("get_Next")
            end
        end)
    end
    if not dmc then M.last = "skin: donor has no mesh comp"; return end
    local dm, dmat
    pcall(function() dm = dmc:call("getMesh") end)
    if not dm then pcall(function() dm = dmc:call("get_Mesh") end) end
    pcall(function() dmat = dmc:call("getMaterial") end)
    if not dmat then pcall(function() dmat = dmc:call("get_Material") end) end
    if not dm then M.last = "skin: couldn't read donor mesh holder"; return end
    pcall(function() dm = dm:add_ref(); dm:add_ref_permanent() end)
    pcall(function() if dmat then dmat = dmat:add_ref(); dmat:add_ref_permanent() end end)
    -- remember the weapon's originals for restore
    pcall(function() skin.orig_mesh = wmc:call("getMesh") end)
    pcall(function() skin.orig_mat = wmc:call("getMaterial") end)
    pcall(function() if skin.orig_mesh then skin.orig_mesh = skin.orig_mesh:add_ref() end end)
    pcall(function() if skin.orig_mat then skin.orig_mat = skin.orig_mat:add_ref() end end)
    local ok = pcall(function()
        if not pcall(function() wmc:call("setMesh", dm) end) then wmc:call("set_Mesh", dm) end
        if dmat then
            if not pcall(function() wmc:call("set_Material", dmat) end) then pcall(function() wmc:call("setMaterial", dmat) end) end
        end
    end)
    -- hide the donor prop (keep it alive - it OWNS the resident resources)
    pcall(function() preview.go:call("set_DrawSelf", false) end)
    skin.applied = ok
    skin.wmc = wmc
    skin.wgo = wgo
    pcall(function() if _G.IrisFlight then _G.IrisFlight.note("woodcut: skin applied=" .. tostring(ok)) end end)
    M.last = ok and "PICKAXE IN HAND - your weapon wears the pickaxe (toggle to restore)"
        or "skin: setMesh failed - see log"
    _log("PICKAXE SKIN: applied=" .. tostring(ok) .. " on " .. tostring(wgo and wgo:call("get_Name")))
end

local function _restore_skin()
    if skin.applied and skin.wmc then
        pcall(function()
            if skin.orig_mesh then
                if not pcall(function() skin.wmc:call("setMesh", skin.orig_mesh) end) then skin.wmc:call("set_Mesh", skin.orig_mesh) end
            end
            if skin.orig_mat then
                if not pcall(function() skin.wmc:call("set_Material", skin.orig_mat) end) then pcall(function() skin.wmc:call("setMaterial", skin.orig_mat) end) end
            end
        end)
    end
    skin.applied = false
    _preview_despawn()
    M.last = "weapon restored"
end

-- waits for the donor prop to land, then applies (own pump = no upvalue reach into the audition pump)
re.on_application_entry("UpdateBehavior", function()
    if skin.pending and preview and preview.go and preview.id == "skin_donor" then
        skin.pending = false
        local ok, err = pcall(_apply_skin)
        if not ok then M.last = "skin ERROR: " .. tostring(err); _log(M.last) end
    end
end)

-- ── CE PICKAXE (weapon 47200 / item 34700): auto-skin + hold tuner + MINING SWING GATE.
-- The CE weapon spawns from iris/tools/iris_pickaxe.pfb (a wp02_000 clone with app.Weapon->ID
-- hex-patched to 47200 - CE's own law: pfb ID must match the entity id or the game crashes on
-- unpause; that WAS last night's equip crash). The pfb still references the greatsword mesh
-- (re-pointing the path in-binary would shift every RSZ offset after it), so the proven runtime
-- reskin dresses it as the pickaxe automatically whenever weapon 47200 is in hand.
local PICKAXE_WEAPON_ID = 47200
-- the tool family: weapon id -> what it harvests + how it looks (rescue-reskin donor + mesh tag)
local TOOL_IDS = {
    [47200] = { kind = "STONE", mesh = "it02_005", donor = "appsystem/equipment/eqit/eqit02_005.pfb", name = "pickaxe" },
    [47210] = { kind = "TREE",  mesh = "it50_010", donor = "appsystem/equipment/eqit/eqit50_010_01.pfb", name = "woodaxe" },
    -- the gardener's hoe (IrisFarming's tool; its CE weapon ships in "IRIS Tools - Hoe").
    -- It lives here ONLY to inherit the auto-reskin + per-tool hold: its wp pfb pointed at a mesh
    -- path that doesn't resolve, so it wore the pickaxe until the donor dressed it (Aurora 07-25).
    -- ⛔ kind "SOIL" is deliberately NOT "TREE"/"STONE": _find_nearest_harvest nils any gimmick
    -- whose kind mismatches the filter, and _chop gates the wild tree/rock sweeps on TREE/STONE -
    -- so a hoe swing can never fell a tree or pay out Timber. Farming owns what it DOES.
    [47220] = { kind = "SOIL",  mesh = "it50_031", donor = "appsystem/equipment/eqit/eqit50_031.pfb", name = "hoe" },
}
local SWINGS_FILE = "IRIS/mine_swings.json"
local mine = {
    gate = true,            -- armed, but does nothing until swings are captured below
    ids = {},               -- whitelist ["bank:id"]=true - the warrior-Y slam clips, captured live
    impact_delay = 0.45,    -- seconds from swing start to pick-bites-stone
    strike_at = nil,
    last_key = nil,
    recent = {},            -- rolling motion-change history (newest first) for the GATE THIS buttons
    fired_key = nil,        -- this swing already consumed; refire only after the clip changes
    probe_t = 0,
    pick_go = nil,
    pick_held = false,
}
-- PER-TOOL hold: each tool gets its own rot/grip/scale (the hatchet needs a flip + upsizing that
-- would wreck the pickaxe's dialed pose)
skin.per = {
    pickaxe = { rot = { x = 0, y = 0, z = 0 }, pos = { x = 0, y = 0, z = 0 }, scale = 1.0 },
    woodaxe = { rot = { x = 0, y = 0, z = 180.0 }, pos = { x = 0, y = 0, z = 0 }, scale = 1.6 },  -- seed: flip + grow the hatchet
    hoe     = { rot = { x = 0, y = 0, z = 0 }, pos = { x = 0, y = 0, z = 0 }, scale = 1.0 },      -- seed: the pickaxe's pose (long haft, same grip); tune in the panel
}
skin.auto = true
local function _active_hold()
    return skin.per[(mine.tool and mine.tool.name) or "pickaxe"] or skin.per.pickaxe
end

do
    local saved = json.load_file(SWINGS_FILE)
    if saved then
        if saved.ids then mine.ids = saved.ids end
        if saved.swing_speed then mine.swing_speed = saved.swing_speed end
        if saved.pin_swing ~= nil then mine.pin_swing = saved.pin_swing end
        if saved.per then
            for k, v in pairs(saved.per) do skin.per[k] = v end
        elseif saved.rot then
            -- migrate the old single-tool file: those values were the pickaxe's
            skin.per.pickaxe = { rot = saved.rot, pos = saved.pos or { x = 0, y = 0, z = 0 }, scale = 1.0 }
        end
        for _, h in pairs(skin.per) do h.scale = h.scale or 1.0; h.pos = h.pos or { x = 0, y = 0, z = 0 } end
        if saved.impact_delay then mine.impact_delay = saved.impact_delay end
        if saved.impact_axe then mine.impact_axe = saved.impact_axe end
        if saved.chop_se_id then M.chop_se_id = saved.chop_se_id end
        if saved.chop_raw_id then M.chop_raw_id = saved.chop_raw_id end
        if saved.fell_raw_id then M.fell_raw_id = saved.fell_raw_id end
        -- (v3: base is NOT persisted - it's re-captured fresh on every draw; a saved base was the
        -- sheathe-pose trap. last_paint IS kept so a reset can recognize its own stale paint.)
        if saved.last_paint then skin.last_paint = saved.last_paint end
    end
    -- ⭐ 2.2 IS THE DEFAULT (Aurora 08-04, field-tuned: "2.2 seems to be the best for me - make
    -- sure it's the default"). Set AFTER the load so a fresh install starts at her number while a
    -- saved slider value still wins.
    if mine.swing_speed == nil then mine.swing_speed = 2.2 end
end
local function _save_swings()
    pcall(function() json.dump_file(SWINGS_FILE, {
        ids = mine.ids, per = skin.per, impact_delay = mine.impact_delay, impact_axe = mine.impact_axe,
        chop_se_id = M.chop_se_id, chop_raw_id = M.chop_raw_id, fell_raw_id = M.fell_raw_id, last_paint = skin.last_paint,
        swing_speed = mine.swing_speed, pin_swing = mine.pin_swing,
    }) end)
end

-- the equipped wp child whose app.Weapon ID is one of OUR tools (nil if no tool in hand)
local function _pickaxe_wp_go()
    local found, tool
    pcall(function()
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local tf = cm:call("get_ManualPlayer"):call("get_GameObject"):call("get_Transform")
        local child = tf:call("get_Child")
        while child do
            local cgo = child:call("get_GameObject")
            local nm = tostring(cgo and cgo:call("get_Name") or "")
            if nm:find("^wp") then
                local w = cgo:call("getComponent(System.Type)", sdk.typeof("app.Weapon"))
                if w then
                    local id
                    pcall(function() id = w:get_field("ID") end)
                    if id == nil then pcall(function() id = w:get_field("<ID>k__BackingField") end) end
                    if id == nil then pcall(function() id = w:call("get_ID") end) end
                    local t = TOOL_IDS[tonumber(id) or -1]
                    if t then found = cgo; tool = t end
                end
            end
            if found then break end
            child = child:call("get_Next")
        end
    end)
    return found, tool
end

-- ── ROCK SENSE (2026-07-23, Aurora: "rock scenery is more sparse - add it to wayfarer
-- vision"): with the PICKAXE in hand, minable scenery rocks within 45m wear a floating
-- "Stone" marker (spent veins skipped; refreshed every 3s; markers via the shared face).
-- (lives BELOW _pickaxe_wp_go on purpose - the local-scope ordering law, once more)
-- ⛔ PARKED OFF by default (Aurora 07-23, seeing the markers float over the river: composite
-- instance PIVOTS sit meters from the visual rock mass - "so out of place we may as well
-- just say hit stone and see what you get"). The checkbox revives it; a real fix would
-- project markers onto per-instance mesh AABB centers, someday.
M.rock_sense = false
local rocksense = { list = {}, at = 0 }
re.on_application_entry("UpdateBehavior", function()
    if not (M.rock_sense and M.wild_rocks) then return end
    if os.clock() - rocksense.at < 3.0 then return end
    rocksense.at = os.clock()
    local go2, tool = _pickaxe_wp_go()
    if not (tool and tool.kind == "STONE") then rocksense.list = {}; return end   -- pickaxe in hand only
    rocksense.list = {}
    pcall(function()
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local pp = cm:call("get_ManualPlayer"):call("get_GameObject"):call("get_Transform"):call("get_Position")
        -- gather WIDE then keep the nearest 10: the sweep returns engine order, and a cap
        -- hit mid-sweep dropped the rock right in front of Aurora while marking far ones
        local found = {}
        for _, r in ipairs(_sweep_rocks(pp, 45.0, 64)) do
            local dx, dz = r.x - pp.x, r.z - pp.z
            local d2 = dx * dx + dz * dz
            if d2 >= 4.0 and not _rock_spent(r.x, r.z) then
                r.d2 = d2
                found[#found + 1] = r
            end
        end
        table.sort(found, function(a, b) return a.d2 < b.d2 end)
        for i = 1, math.min(#found, 10) do rocksense.list[i] = found[i] end
    end)
end)
re.on_frame(function()
    if not (M.rock_sense and #rocksense.list > 0) then return end
    for _, r in ipairs(rocksense.list) do
        pcall(function()
            local sp = draw.world_to_screen(Vector3f.new(r.x, r.y, r.z))
            if sp then
                -- native-sense styling (Aurora: match the game's own gatherable look):
                -- soft grey, named like the gimmick rocks
                if not (_G.IrisFont and _G.IrisFont.text and _G.IrisFont.text("Minable Stone", sp.x, sp.y, 0xFFC9C9C4, 16)) then
                    draw.text("Minable Stone", sp.x, sp.y, 0xFFC9C9C4)
                end
            end
        end)
    end
end)

local function _player_motion_key()
    local key
    pcall(function()
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local pgo = cm:call("get_ManualPlayer"):call("get_GameObject")
        local mo = pgo:call("getComponent(System.Type)", sdk.typeof("via.motion.Motion"))
        local layer = mo and mo:call("getLayer", 0)
        if layer then
            local bank = tonumber(layer:call("get_MotionBankID")) or -1
            local mid = tonumber(layer:call("get_MotionID")) or -1
            key = bank .. ":" .. mid
        end
    end)
    return key
end

-- ⛔ STREAM-SAFETY (2026-07-22, two load-in crashes with the pickaxe equipped): (1) WARM the
-- pickaxe's custom mesh/mdf2 at boot (the proven Baby warmer recipe) so the equipped weapon never
-- cold-streams alongside heavy area streaming; (2) the watcher does NOTHING until 25s after the
-- player first exists in a session (donor spawns mid-stream = the known CTD class).
local wc_load_t = os.clock()
local wc_warm, wc_warmed = {}, false
local wc_player_seen_at = nil

re.on_application_entry("UpdateBehavior", function()
    local now = os.clock()
    if not wc_warmed and (now - wc_load_t) > 5.0 then
        wc_warmed = true
        pcall(function()
            local r = sdk.create_resource("via.render.MeshResource", "Character/it/it02/005/it02_005.mesh")
            if r then wc_warm[#wc_warm + 1] = r:add_ref() end
        end)
        pcall(function()
            local m = sdk.create_resource("via.render.MeshMaterialResource", "Character/it/it02/005/it02_005.mdf2")
            if m then wc_warm[#wc_warm + 1] = m:add_ref() end
        end)
        -- ⛔ EFFECT-CRASH FIX (crash-dump-diagnosed 13:52: AV in EffectManager.doUpdate mid-forge-
        -- stream with the pickaxe equipped): keep the weapon pfb AND its resident VFX container
        -- permanently hot so the effect system never ticks a half-resident entry.
        for _, path in ipairs({
            "AppSystem/equipment/wp/wp02/prefab/wp02_000_98.pfb",
            "AppSystem/equipment/wp/wp02/prefab/wp02_000_97.pfb",
            "VFX/Effects/Weapon/wp02/13_wp02_Ref.pfb",
        }) do
            pcall(function()
                local pfb = sdk.create_instance("via.Prefab"):add_ref()
                pcall(function() pfb:add_ref_permanent() end)
                pfb:call("set_Path", path)
                pcall(function() pfb:call("get_Ready") end)   -- kicks the async load
                wc_warm[#wc_warm + 1] = pfb
            end)
        end
        -- chip-impact efx: warmed HERE because a cold create_resource at chip time plays nothing
        -- (create + AutoStart + reap all before the async load lands = the silent chips)
        for _, path in ipairs({
            "VFX/Effects/Gimmic/gm80/109/13_gm80_109_000_01.efx",
            "VFX/Effects/Gimmic/gm80/110/13_gm80_110_000_01.efx",
            "VFX/Effects/Gimmic/gmdy/010/13_gmdy_010_03.efx",
            "VFX/Effects/Gimmic/gmcm/005/13_gmcm_005_00.efx",
            "VFX/Effects/Gimmic/gmdy/000/13_gmdy_000_01.efx",
            "VFX/Effects/Gimmic/gmdy/000/13_gmdy_000_02.efx",
            "VFX/Effects/Gimmic/gmdy/000/13_gmdy_000_03.efx",
        }) do
            pcall(function()
                local r = sdk.create_resource("via.effect.EffectResource", path)
                if r then wc_warm[#wc_warm + 1] = r:add_ref() end
            end)
        end
        _log("warmed tool resources: " .. #wc_warm .. " resolved")
    end
    -- a scheduled strike lands (timed to the pick's impact frame, not the button press)
    if mine.strike_at and now >= mine.strike_at then
        mine.strike_at = nil
        -- aim assist: swing strikes only the TOOL'S material within ~75 deg (manual CHOP stays 360)
        local target = (mine.tool and mine.tool.kind) or "STONE"
        if target == "SOIL" then
            -- ⭐ THE HOE (Aurora 07-25: "it needs to use the hoe to till the soil"). Its swing
            -- breaks ground instead of harvesting: the strike is handed to IrisFarming, which owns
            -- the bed. No _chop, and no payout rechecks - there is nothing here to collect.
            local ok, err = pcall(function()
                if _G.IrisFarming and _G.IrisFarming.till then _G.IrisFarming.till("swing") end
            end)
            if not ok then M.last = "till ERROR: " .. tostring(err); _log(M.last) end
        else
            local ok, err = pcall(_chop, target, mine.aim_cone or 75.0)
            if not ok then M.last = "mine ERROR: " .. tostring(err); _log(M.last) end
            -- payout rechecks: the NATIVE pick impact can land after our strike and break the rock we
            -- just chipped - sweep twice more, collect-only (one rock still slipped the single 0.7s net)
            mine.recheck_at = now + 0.7
            mine.recheck2_at = now + 1.6
        end
    end
    -- payout sweeps: CONELESS and ALL-ROCKS (outcrop lesson: the dead rock's unbroken neighbour is
    -- often NEARER, so a nearest-only recheck inspected the wrong rock and the kill went unpaid).
    -- The BASELINE keeps it honest: only rocks that became rubble SINCE the swing get paid.
    local function _scan_broken(fn)
        pcall(function()
            local cm = sdk.get_managed_singleton("app.CharacterManager")
            local pp = cm:call("get_ManualPlayer"):call("get_GameObject"):call("get_Transform"):call("get_Position")
            local sm = sdk.get_native_singleton("via.SceneManager")
            local smt = sdk.find_type_definition("via.SceneManager")
            local scene = sm and sdk.call_native_func(sm, smt, "get_CurrentScene")
            local comps = scene and scene:call("findComponents(System.Type)", sdk.typeof("app.GimmickBase"))
            local n = 0
            pcall(function() n = comps:call("get_Length") or 0 end)
            if n == 0 then pcall(function() n = comps:get_size() or 0 end) end
            for i = 0, (tonumber(n) or 0) - 1 do
                pcall(function()
                    local c
                    pcall(function() c = comps:call("get_Item", i) end)
                    if not c then pcall(function() c = comps:get_element(i) end) end
                    if not c then return end
                    local tn = c:get_type_definition():get_full_name()
                    local kind = TREE_SET[tn] and "TREE" or (ROCK_SET[tn] and "STONE" or nil)
                    if not kind then return end
                    local go = c:call("get_GameObject")
                    local rp = go and go:call("get_Transform"):call("get_Position")
                    if not rp then return end
                    local dx, dy, dz = rp.x - pp.x, rp.y - pp.y, rp.z - pp.z
                    if dx * dx + dy * dy + dz * dz > (M.chop_range + 1.0) ^ 2 then return end
                    if c:call("get_IsBroken") ~= true then return end
                    fn(tostring(go), kind, go)
                end)
            end
        end)
    end
    if mine.snap_req then
        mine.snap_req = nil
        mine.baseline = {}
        _scan_broken(function(addr) mine.baseline[addr] = true end)
    end
    local function _payout_sweep()
        _scan_broken(function(addr, kind, go)
            if granted_breaks[addr] then return end
            if mine.baseline and mine.baseline[addr] then return end   -- was already rubble before the swing
            granted_breaks[addr] = true
            local nm = "?"; pcall(function() nm = go:call("get_Name") end)
            local got = _grant_yield(kind)
            if got > 0 then M.gather_at = os.clock() + 0.9 end
            M.last = string.format("%s shattered by the blow! +%d %s", tostring(nm),
                got, kind == "STONE" and "Stone" or "Timber")
            _log(M.last)
        end)
    end
    if mine.recheck_at and now >= mine.recheck_at then
        mine.recheck_at = nil
        _payout_sweep()
    end
    if mine.recheck2_at and now >= mine.recheck2_at then
        mine.recheck2_at = nil
        _payout_sweep()
    end
    -- shared motion-takeover plumbing (gather bow + axe chops): one freeze, one release timer
    local function _player_ch()
        local ch
        pcall(function() ch = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer") end)
        return ch
    end
    local function _fsm(enabled)
        pcall(function()
            local h = _player_ch():call("get_Human")
            if h and h.Fsm then h.Fsm:set_Enabled(enabled) end
        end)
    end
    local function _layer0()
        local l
        pcall(function() l = _player_ch():call("get_Motion"):call("getLayer", 0) end)
        return l
    end
    local function _play_clip(bank, clip, start_frame)
        local ok = pcall(function()
            _layer0():call(
                "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                bank, clip, tonumber(start_frame) or 0.0, 6.0, 1, 1)
        end)
        return ok
    end
    local function _layer_speed(s)
        pcall(function() _layer0():call("set_Speed", s) end)
    end

    -- ⭐ SWING SPEED (Aurora 08-04: "are we able to speed it up? potentially with a slider?").
    -- Applied one tick after the swing request, restored the moment the window lapses or the FSM
    -- leaves the swing. The layer accepts fractional speeds fine - the charge freeze already
    -- drives it to 0.
    if mine.speed_req then
        mine.speed_req = nil
        if (mine.swing_speed or 1.0) ~= 1.0 then
            _layer_speed(mine.swing_speed or 1.0)
            mine.speed_on = true
        end
    end
    if mine.speed_on and (not mine.swing_until or now > mine.swing_until) then
        _layer_speed(1.0)
        mine.speed_on = false
    end

    -- AXE CHOP OVERRIDE: paint Aurora's woodcutter swing (bank 150: 0 -> 10 -> 23 cycle) over the
    -- running heavy action - no FSM freeze, native action lifecycle underneath
    if mine.axe_motion_at and now >= mine.axe_motion_at then
        mine.axe_motion_at = nil
        local clips = { 0, 10, 23 }
        mine.chop_i = ((mine.chop_i or 0) % #clips) + 1
        -- release any charge-freeze - to the SWING speed, not 1.0, or the paint undoes the slider
        _layer_speed(mine.speed_on and (mine.swing_speed or 1.0) or 1.0)
        if _play_clip(150, clips[mine.chop_i]) then
            -- the heavy action OUTLIVES the painted clip and resumes its vertical tail (freeze
            -- experiments failed twice) - so CANCEL the action at the source: once the chop
            -- completes, request NormalLocomotion ourselves and the tail never exists.
            mine.chop_end_at = now + (M.chop_cancel or 1.45) / (mine.swing_speed or 1.0)   -- faster chop = earlier cancel
            _log("AXE chop clip 150:" .. clips[mine.chop_i] .. " painted over the heavy")
        end
    end
    if mine.chop_end_at and now >= mine.chop_end_at then
        mine.chop_end_at = nil
        if mine.player_am then
            local okc = pcall(function()
                mine.player_am:call("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)",
                    10, "NormalLocomotion", 0)
            end)
            _log("chop cancel -> NormalLocomotion (" .. tostring(okc) .. ")")
        end
    end
    -- AXE CHARGE-HOLD: freeze her chop clip at the ready pose while the heavy charges; the
    -- release unfreezes into the full swing (kills the stray vertical windup)
    if mine.axe_unfreeze then mine.axe_unfreeze = nil; _layer_speed(mine.speed_on and (mine.swing_speed or 1.0) or 1.0) end
    if mine.axe_charge_at and now >= mine.axe_charge_at then
        mine.axe_charge_at = nil
        if mine.axe_charging then
            local clips = { 0, 10, 23 }
            local clip = clips[((mine.chop_i or 0) % #clips) + 1]
            if _play_clip(150, clip, 14.0) then _layer_speed(0.0) end
        end
    end
    if mine.axe_charging then
        -- the charge loop may stomp the frozen pose; re-freeze if the clip got replaced (~0.2s)
        mine.charge_guard_f = (mine.charge_guard_f or 0) + 1
        if mine.charge_guard_f >= 12 then
            mine.charge_guard_f = 0
            local bank
            pcall(function() bank = tonumber(_layer0():call("get_MotionBankID")) end)
            if bank ~= 150 then mine.axe_charge_at = now end
        end
        if not mine.pick_held then mine.axe_charging = false; _layer_speed(1.0) end
    elseif mine.charge_guard_f then
        mine.charge_guard_f = nil
    end

    -- AUTO-GATHER (Aurora's find: bank 60 clip 6001 = the collect bow): after the debris settles,
    -- freeze the player's FSM, play the gather motion, release ~2s later (the scenes.lua recipe)
    if M.auto_gather == nil then M.auto_gather = true end
    if M.gather_at and now >= M.gather_at then
        M.gather_at = nil
        if M.auto_gather then
            _fsm(false)
            if _play_clip(60, 6001) then
                mine.fsm_release_at = math.max(mine.fsm_release_at or 0, now + 2.1)
                mine.yield_at = now + 0.8   -- the hand reaches the rubble: the stone lands NOW
            else
                _fsm(true)
            end
        end
        if M.pending_yield and not mine.yield_at then
            -- gather disabled or the bow failed to play: never lose the payout
            local y = M.pending_yield; M.pending_yield = nil
            local got = _do_grant(y.kind, y.n)
            M.last = string.format("+%d %s", got, y.kind == "STONE" and "Stone" or "Timber")
        end
    end
    if mine.yield_at and now >= mine.yield_at then
        mine.yield_at = nil
        if M.pending_yield then
            local y = M.pending_yield; M.pending_yield = nil
            local got = _do_grant(y.kind, y.n)
            M.last = string.format("gathered +%d %s", got, y.kind == "STONE" and "Stone" or "Timber")
            _log(M.last)
        end
    end
    if mine.fsm_release_at and now >= mine.fsm_release_at then
        mine.fsm_release_at = nil
        _fsm(true)
    end
    -- reap spent chip-effect spawns
    if chip_fx_live then
        for i = #chip_fx_live, 1, -1 do
            if now >= chip_fx_live[i].at then
                pcall(function() chip_fx_live[i].go:call("destroy", chip_fx_live[i].go) end)
                table.remove(chip_fx_live, i)
            end
        end
    end
    if now < mine.probe_t then return end
    mine.probe_t = now + 0.15
    -- session settle gate: no weapon-GO walks / donor spawns until the world has been standing a
    -- while. Player already present when the script loads = mid-session Reset Scripts -> only 5s
    -- (Aurora saw her saved hold "vanish" for the full 25s gate); fresh appearance = load-in -> 25s.
    if not wc_player_seen_at then
        local seen = false
        pcall(function()
            local cm = sdk.get_managed_singleton("app.CharacterManager")
            seen = cm and cm:call("get_ManualPlayer") ~= nil
        end)
        if seen then
            wc_player_seen_at = now
            wc_settle = (now - wc_load_t) < 3.0 and 5.0 or 25.0   -- _G on purpose (200-local cap)
        end
        return
    end
    -- ⛔ THIS SETTLE IS WHY THE HOE LOADS AS A HATCHET (Aurora 07-26, third report). The whole pump
    -- returned for 25s after a load, so tool detection and the reskin couldn't run and you saw the
    -- raw pfb mesh until you unequipped. The settle exists to keep heavy MINING work off the
    -- load-in frames - a mesh swap isn't that. So: detection + skin get a short settle, the strike
    -- machinery keeps the long one.
    local settling = now < wc_player_seen_at + (wc_settle or 25.0)
    if settling and now < wc_player_seen_at + (mine.skin_settle or 5.0) then return end
    mine.pick_go, mine.tool = _pickaxe_wp_go()
    local was_held = mine.pick_held
    mine.pick_held = mine.pick_go ~= nil
    -- stamp the moment the tool arrives in hand: the new skill catch-all and the HUD relabel wait
    -- out this settle, so neither can touch the FSM or the GUI during a save-load's init window
    if mine.pick_held and not was_held then mine.held_at = os.clock() end
    -- hand the IDENTIFIED tool object to the skinner; without this it paints the first wp child
    -- it finds, which with two weapons equipped is often the sword (Aurora: "switch to the
    -- Lifetaker and it becomes a hoe")
    skin.target_go = mine.pick_go
    if mine.pick_held and not mine.player_am_addr then
        pcall(function()
            local cm = sdk.get_managed_singleton("app.CharacterManager")
            local am = cm:call("get_ManualPlayer"):call("get_ActionManager")
            mine.player_am_addr = am and am:get_address() or nil
            mine.player_am = am
        end)
    elseif not mine.pick_held then
        mine.player_am_addr = nil   -- re-derive on next equip (save loads move the address)
        mine.player_am = nil
    end
    -- auto-skin RESCUE: the forged pfbs carry their tool meshes natively; only if the equipped
    -- tool is readably wearing something ELSE does its reskin donor get spawned
    -- ⭐ SELF-VERIFYING: also re-check while APPLIED (throttled), because the skin can be silently
    -- lost - a save load rebuilds the weapon object, and an address compare isn't always enough.
    -- The mesh readback below is the real proof; if the tool isn't wearing its own mesh, re-dress
    -- it whatever the cause. Throttled so an unreadable path can't spawn donors every frame.
    local skin_recheck = false
    if skin.auto and mine.pick_held and mine.tool and skin.applied and not skin.pending then
        if now - (skin.verify_at or 0) > 2.0 then skin.verify_at = now; skin_recheck = true end
    end
    if skin.auto and mine.pick_held and mine.tool and (not skin.applied or skin_recheck) and not skin.pending then
        local path
        pcall(function()
            local mc = mine.pick_go:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
            local mr = mc and mc:call("getMesh")
            if mr then
                if not pcall(function() path = tostring(mr:call("get_ResourcePath")) end) then
                    path = tostring(mr)
                end
            end
        end)
        -- ⭐ 07-25 (the hoe stayed a pickaxe): fire when the path is UNREADABLE as well. The hoe's
        -- wp pfb points at it50_031, which isn't in the base game, so get_ResourcePath came back
        -- nil and the old `path and ...` guard silently SKIPPED the rescue. A nil path means "we
        -- can't prove it's already right", which is exactly when the donor should dress it.
        if (not path) or (not path:find(mine.tool.mesh)) then
            skin.pending = true
            _log(string.format("auto-skin: %s is wearing '%s' (wants %s) -> spawning donor %s",
                tostring(mine.tool.name), tostring(path), tostring(mine.tool.mesh), tostring(mine.tool.donor)))
            pcall(function() if _G.IrisFlight then _G.IrisFlight.note("woodcut: auto-skin donor spawning (wp mesh=" .. tostring(path) .. ")") end end)
            _preview_spawn(mine.tool.donor, "skin_donor")
        end
    end
    if not mine.pick_held and skin.applied and skin.auto_owned then
        -- weapon GO despawned with the unequip; nothing left to restore onto
        skin.applied = false; skin.auto_owned = nil
        _preview_despawn()
    elseif mine.pick_held and skin.applied then
        -- ⭐ THE WEAPON OBJECT CAN BE REBUILT UNDER US (Aurora 07-26: "loaded in with the hoe
        -- equipped and my character was holding an upside down hatchet - had to unequip/requip").
        -- On a save load the wp GameObject is recreated while `pick_held` never goes false, so the
        -- stale applied-flag blocked a re-skin and you saw the RAW pfb mesh (it50_010, the hatchet,
        -- upside down because the hoe's hold pose isn't the woodaxe's flip). Compare the object we
        -- skinned against the one that's live now; if it changed, the skin died with the old one.
        -- ⛔ compare ADDRESSES, not the userdata handles: `skin.wgo ~= mine.pick_go` on two
        -- REManagedObject wrappers does NOT reliably mean "different object", so the rebuild went
        -- undetected and the hoe kept loading as the raw hatchet (Aurora 07-26, second report).
        local a1, a2
        pcall(function() a1 = skin.wgo and skin.wgo:get_address() end)
        pcall(function() a2 = mine.pick_go and mine.pick_go:get_address() end)
        if a1 and a2 and a1 ~= a2 then
            _log(string.format("weapon object rebuilt (%s -> %s) - re-applying the tool skin",
                tostring(a1), tostring(a2)))
            skin.applied = false; skin.auto_owned = nil
            skin.wmc, skin.wgo = nil, nil
            _preview_despawn()
        else
            skin.auto_owned = true
        end
    end
    -- everything past here is the STRIKE machinery, which keeps the full load-in settle
    if settling then return end
    -- swing watch (while the pickaxe is held, or any manual reskin is on)
    if not (mine.pick_held or skin.applied) then mine.last_key = nil; return end
    local key = _player_motion_key()
    if key and key ~= mine.last_key then
        mine.last_key = key
        table.insert(mine.recent, 1, key)
        while #mine.recent > 6 do table.remove(mine.recent) end
        if mine.fired_key and mine.fired_key ~= key then mine.fired_key = nil end
        if mine.gate and mine.ids[key] and mine.fired_key ~= key then
            local t = _find_nearest_harvest("STONE")
            if t then
                mine.strike_at = now + mine.impact_delay
                mine.fired_key = key
                if mine.tool and mine.tool.kind == "SOIL" then
                    pcall(function() if _G.IrisFarming and _G.IrisFarming.aim then _G.IrisFarming.aim() end end)
                end
                _log("MINE swing " .. key .. " -> strike in " .. string.format("%.2f", mine.impact_delay) .. "s")
            end
        end
    end
end)

-- ── TOOL, NOT A WEAPON OF WAR (v2, log-taught 2026-07-22): the warrior Y-slam's action node is
-- **Job05_ShortRangeHeavyAttack** (Aurora's field session, 4x repeated). While the pickaxe is
-- drawn: that swing IS the mining trigger (strike scheduled at impact_delay - no motion capture
-- needed); every OTHER attack (name contains "Attack") and every skill (_CS node) is blocked.
-- Locomotion/dodge/sheathe/defaults pass. Unknown attack names self-report via the log.
-- the Y family (log-taught 14:07-14:23, THREE rounds of whack-a-mole -> structural rule): every
-- node in the warrior Y chain carries "Range" (PrepareShortRange, ChargeShortRange, ShortRange-
-- HeavyAttack, LongRange...). Blocking ANY link wedges the action graph (one-swing lock, stuck
-- charge pose), so the whole family passes by pattern; only the Heavy releases strike stone.
local function _y_family(s)
    return s:find("^Job05_") ~= nil and s:find("Range") ~= nil
end
-- X-combo verdict (2026-07-22, after the feint experiment backfired into a rogue charge): partial
-- blocks inside the native combo tree make the FSM grab weird fallback branches - so X swings
-- NATIVELY and stays harmless through the numbers instead (atk 8, and only Y mines). Skills stay blocked.
local MINE_SWING_ACTIONS = {   -- the heavy RELEASES strike stone
    ["Job05_ShortRangeHeavyAttack"] = true,
    ["Job05_LongRangeHeavyAttack"] = true,
}
-- X -> Y SUBSTITUTION (Aurora: "X should do the same as Y"): blocking X wedges the FSM, but the
-- X and Y chains share their windups - so when the X release is requested we SKIP it and request
-- the Y heavy release at the same graph point instead. X literally becomes the slam.
local X_TO_Y = {
    ["Job05_ShortRangeAttack"] = "Job05_ShortRangeHeavyAttack",
    ["Job05_LongRangeAttack"] = "Job05_LongRangeHeavyAttack",
}
mine.block_skills = true
pcall(function()
    local m = sdk.find_type_definition("app.ActionManager")
        :get_method("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)")
    if not m then return end
    sdk.hook(m, function(args)
        if not (mine.pick_held and mine.player_am_addr) then return end
        local block = false
        pcall(function()
            local am = sdk.to_managed_object(args[2])
            if not (am and am:get_address() == mine.player_am_addr) then return end
            local name = sdk.to_managed_object(args[4])
            local s = name and tostring(name:call("ToString()")) or ""
            if s ~= mine.last_logged_action then   -- charge loops re-request every frame; log edges only
                mine.last_logged_action = s
                _log("ACTION while pickaxe held: " .. s)
            end
            local axe_held = mine.tool and mine.tool.kind == "TREE"
            -- ⛔⛔⛔ THE "NO MOVING ATTACKS" BLOCK IS GONE (2026-08-12). It was eating EVERY SWING.
            -- Aurora 08-12: "now I can't swing the Axe, Pickaxe or Hoe with the regular X/Y". The log
            -- named it outright — 37 consecutive presses at a farm plot, every one of them
            -- `Job05_PrepareLongRangeAttack` -> `Job05_LongRangeHeavyAttack`, not a single ShortRange
            -- in the run, and this filter refused all of them before X_TO_Y or MINE_SWING_ACTIONS
            -- could see them.
            -- ⭐ THE FALSE PREMISE (07-26): "the LongRange variants are the lunging ones", i.e.
            -- LongRange == you were moving. It does not. Short/Long is the variant DD2 picks by
            -- DISTANCE TO TARGET, so standing perfectly still with no enemy to lock — a farm plot, a
            -- quiet forest, exactly where tools get used — yields LongRange on every press. The
            -- filter demanded a state the game will not produce while you are farming.
            -- ⛔ AND IT BROKE THIS FILE'S OWN LAW: `Job05_PrepareLongRangeAttack` is a WINDUP inside
            -- the Range family. `_y_family` passes that whole family by PATTERN precisely because
            -- blocking any single link wedges the action graph (one-swing lock, stuck charge pose —
            -- three rounds of whack-a-mole taught that). This block was a partial block of the
            -- family, so even when it "worked" it was wedging the FSM.
            -- ⭐ WHAT SHE ACTUALLY ASKED FOR IS ALREADY BUILT, AND BETTER: `mine.pin_swing` (08-04)
            -- snapshots XZ at the swing request and re-asserts it every LateUpdate for the swing's
            -- duration, so the animation's root motion cannot carry her forward AT ALL. That is
            -- "stop it moving the character" delivered without touching the FSM — it made this block
            -- redundant eight days ago and nobody came back to remove it.
            -- ⇒ the LongRange heavy is a first-class swing now: MINE_SWING_ACTIONS already lists it,
            -- the strike scheduler already gives it its charged +0.35s, and X_TO_Y already maps its
            -- X-release twin. All three were dead code behind this `return`.
            if (mine.axe_charging or mine.chop_hold) and not s:find("^Job05_Charge") and not MINE_SWING_ACTIONS[s] then
                -- the FSM moved on (locomotion/dodge/sheathe): release any freeze/hold
                mine.axe_charging = false
                mine.chop_hold = false
                mine.axe_unfreeze = true
            end
            -- the Wilds paint dies with the action - in TWO PHASES:
            --   mid-clip: only a REAL state change (dodge/sheathe/jump) stops it, because
            --   locomotion-family requests can arrive while an action runs and must not kill a
            --   swing in progress;
            --   HOLDING the last frame: ANY request stops it - the native heavy has ended, and
            --   the very next request (locomotion, default, anything) is the FSM moving on. That
            --   includes the requests the mid-clip phase deliberately ignores.
            if not MINE_SWING_ACTIONS[s] and not s:find("^Job05_Charge") then
                local real_change = not s:find("^Job05_")
                    and s ~= "NormalLocomotion" and s ~= "UpperBodyDefault" and s ~= "Strafe"
                pcall(function()
                    local NB = _G.NB_Pose
                    if not (NB and NB.is_playing and NB.is_playing()) then return end
                    local holding = NB.is_holding and NB.is_holding()
                    if holding or real_change then NB.stop() end
                end)
                -- native-mode releases ride the same signal: a dodge/sheathe mid-swing frees the
                -- position pin and queues the layer speed back to 1.0
                if real_change then
                    mine.pin_pos = nil
                    mine.swing_until = 0
                end
            end
            if axe_held and s:find("^Job05_Charge") then
                -- CHARGE STOMP (the stray vertical smash): holding the button buffers the heavy
                -- into its charge loop, which re-asserts the vertical windup every frame over our
                -- paint. Freeze HER clip at a ready pose instead; the release unfreezes the swing.
                if not mine.axe_charging then
                    mine.axe_charging = true
                    mine.axe_charge_at = os.clock() + 0.05
                end
            elseif mine.block_skills and X_TO_Y[s] and not mine.substituting then
                -- BOTH TOOLS: swap the X release for the Y heavy - a REAL action with a real
                -- lifecycle (block-and-takeover looped forever: the FSM re-requests a release that
                -- never plays). For the AXE, the pump then paints Aurora's bank-150 chop clip OVER
                -- the running heavy ~0.1s in: her swing visuals, native action underneath.
                block = true
                mine.substituting = true
                pcall(function() am:call("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)",
                    sdk.to_int64(args[3]) & 0xffffffff, X_TO_Y[s], 0) end)
                mine.substituting = false
            elseif _y_family(s) then
                mine.chop_end_at = nil   -- fresh swing activity: never cancel into a live windup
                -- ⭐⭐ THE WILDS SWING (Aurora 08-04, after tuning it in the anim lab: "the animation
                -- is good now, we just need to make sure it's used for the pickaxe and hoe").
                -- Same shape as the axe's bank-150 paint one branch down: the NATIVE heavy still
                -- runs (it owns the FSM lifecycle, root motion, strike timing and the chop sound),
                -- and the retargeted MH Wilds clip is painted over it through the anim lab's
                -- proven _G.NB_Pose bridge - euler writes at PrepareRendering land after animation,
                -- so her pose is the Wilds swing while the machinery underneath stays native.
                -- keep_fsm=true is the whole trick: suppressing the FSM here would kill the very
                -- action that pays out. TREE keeps its own bank-150 chop; this is pickaxe + hoe.
                -- ⚠ OPT-IN since 08-04 late (Aurora changed her mind: "revert back to the standard
                -- animation... but speed it up, and stop it moving the character forward"). The
                -- paint machinery stays for the checkbox; the NATIVE swing + tweaks is the default.
                if MINE_SWING_ACTIONS[s] and not axe_held and mine.wilds_swing == true then
                    pcall(function()
                        if _G.NB_Pose then
                            if _G.NB_Pose.set_ground then _G.NB_Pose.set_ground(mine.wilds_ground or 0.7) end
                            _G.NB_Pose.play(mine.wilds_clip or "rs_wilds_pickaxe_swing", "Arisen", "Full",
                                false, mine.wilds_speed or 1.0, true, true)
                        end
                    end)
                end
                -- ⭐⭐ NATIVE SWING TWEAKS (the default): speed the swing up via layer-0 set_Speed
                -- (the axe charge-freeze machinery already proves the layer accepts it) and PIN the
                -- character's XZ for the swing's duration so the animation's root motion can't
                -- carry her forward (Aurora: "stop moving the character forward - probably harder
                -- but more important"). Y stays free - slopes and gravity keep working. The pin is
                -- re-asserted in LateUpdateBehavior, the only phase where position writes stick
                -- (the couples law).
                -- (Aurora 08-04: "2.2 seems best - can we do the same for the woodcutter axe?")
                -- speed + pin now cover ALL tools; the axe's painted bank-150 chop plays on the
                -- same layer, so one set_Speed accelerates it identically.
                if MINE_SWING_ACTIONS[s] and (axe_held or mine.wilds_swing ~= true) then
                    mine.speed_req = true
                    mine.swing_until = os.clock() + 2.8 / (mine.swing_speed or 1.0)
                    if mine.pin_swing ~= false then
                        pcall(function()
                            local cm = sdk.get_managed_singleton("app.CharacterManager")
                            local tf = cm:call("get_ManualPlayer"):call("get_GameObject"):call("get_Transform")
                            local p = tf:call("get_Position")
                            mine.pin_pos = { x = p.x, y = p.y, z = p.z }
                        end)
                    end
                end
                -- the world is provably ALIVE the moment a swing request arrives - a player just
                -- pressed attack in running gameplay. This is the HUD relabel's safety gate (the
                -- griffin session's S.mounted gate, translated: never true during a save-load).
                if MINE_SWING_ACTIONS[s] then mine.world_live = true end
                if MINE_SWING_ACTIONS[s] and axe_held then
                    -- AXE: no vertical ground-slams, ever (Aurora's call - the inverse of the
                    -- pickaxe). EVERY heavy release - Y, charged Y, substituted X - wears her
                    -- bank-150 horizontal chop instead.
                    mine.axe_charging = false
                    mine.axe_motion_at = os.clock() + 0.12 / (mine.swing_speed or 1.0)
                end
                if mine.gate and MINE_SWING_ACTIONS[s] then
                    local delay
                    if axe_held then
                        -- the painted bank-150 chop makes CONTACT late in the clip (0.45 crumbled
                        -- the tree while the axe was still winding up - Aurora's report).
                        -- a sped-up layer reaches that contact frame proportionally sooner
                        delay = (mine.impact_axe or 0.9) / (mine.swing_speed or 1.0)
                    elseif mine.wilds_swing == true then
                        -- the painted Wilds clip strikes at frame 41 of 52 (measured in Blender:
                        -- the R_Hand's lowest point) - the native windup timings no longer apply
                        delay = mine.impact_wilds or 0.68
                    else
                        local charged = s == "Job05_LongRangeHeavyAttack"
                        -- a sped-up swing lands early in exact proportion
                        delay = (mine.impact_delay + (charged and 0.35 or 0.0)) / (mine.swing_speed or 1.0)
                    end
                    mine.strike_at = os.clock() + delay
                    mine.snap_req = true   -- pump snapshots pre-swing rubble (payout baseline)
                    -- FARM AIM LATCH: freeze the hoe's target NOW. The swing animation drives the
                    -- player forward, so resolving at the impact frame moved the bed off the spot
                    -- the crosshair showed (Aurora 07-26: it destroyed the adjacent bed instead).
                    if mine.tool and mine.tool.kind == "SOIL" then
                        pcall(function() if _G.IrisFarming and _G.IrisFarming.aim then _G.IrisFarming.aim() end end)
                    end
                end
            elseif mine.block_skills and (s:find("_CS") or s:find("Attack")
                -- ⛔ THE LB HOLE (Aurora 08-04: "if you hold LB and press a face button it does a
                -- skill"). The old net was "_CS" (custom-skill nodes) + "Attack" - but the native
                -- warrior weapon skills carry NEITHER string: the field log shows
                -- Job05_CrescentSlash / Job05_HorizonalSlash / Job05_IndomitableLash / Job05_Tackle
                -- sailing straight through. Structural fix, not whack-a-mole: by this point in the
                -- chain every LEGITIMATE Job05_ node is already handled (the Range family passed
                -- above, Attack names caught here) - so any OTHER Job05_ request while a tool is
                -- held IS a weapon skill, including ones we've never seen. Job05_ExceptIdle is the
                -- one known FSM housekeeping node; it alone passes.
                    -- the settle guard: never SKIP unfamiliar FSM nodes during a save-load's init
                    -- (the load-in AV hardening) - the catch-all only bites once the tool has been
                    -- in hand a few seconds, i.e. real gameplay
                    or (s:find("^Job05_") and s ~= "Job05_ExceptIdle"
                        and mine.held_at and os.clock() - mine.held_at > 5.0)) then
                block = true
                M.last = "tool in hand: blocked (" .. s .. ")"
            end
        end)
        if block then return sdk.PreHookResult.SKIP_ORIGINAL end
    end)
    _log("pickaxe swing hook installed (Y-slam mines, other attacks blocked)")
end)

-- ── ⭐⭐ SWING POSITION PIN (Aurora 08-04: "is it possible for it to stop moving the character
-- forward at all? probably harder but more important"). The native heavy's root motion lunges her
-- forward; the aim latch already compensates for WHERE the bed lands, but the body still travels.
-- Pin = snapshot XZ at the swing request, re-assert every LateUpdateBehavior until the window
-- lapses or the FSM leaves the swing (the couples law: position writes only stick in LateUpdate).
-- Y is left native so slopes, gravity and the landing all keep working.
re.on_application_entry("LateUpdateBehavior", function()
    if not mine.pin_pos then return end
    if not mine.swing_until or os.clock() > mine.swing_until then mine.pin_pos = nil; return end
    pcall(function()
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local tf = cm:call("get_ManualPlayer"):call("get_GameObject"):call("get_Transform")
        local p = tf:call("get_Position")
        tf:call("set_Position", Vector3f.new(mine.pin_pos.x, p.y, mine.pin_pos.z))
    end)
end)

-- ── ⭐ HUD KEY-GUIDE RELABEL — REVIVED 2026-08-12 THROUGH IrisPromptBar.
--
-- Aurora (08-12): "when the hoe, axe and pickaxe are equipped, suppress the LB Switch Weapon Skill
-- and change it in the UI to ' '. Make X and Y say Chop / Dig / Hoe."
--
-- ⭐⭐⭐ THE 08-04 DIAGNOSIS BELOW WAS WRONG, AND THAT COST THIS FEATURE EIGHT DAYS. It blamed a
-- race against the on-foot panel's own rebuild and concluded "no gate fixes a race". The actual
-- fault was the HOOK: `re.on_frame` is the RENDER/PRESENT thread, and walking the scene + resolving
-- ui010201 + writing set_Message there is the prop-spawn lab's THREAD LAW playing out. IrisPromptBar
-- (08-09) does the byte-identical write EVERY frame from `LateUpdateBehavior` — the game thread —
-- for farm beds, cookpots and weapon plaques, and has never crashed. So no SkillCreator post-hook
-- rebuild was ever needed; the write just had to happen on the right thread.
-- ⇒ we no longer touch the GUI from this file at all. We PUBLISH three labels and the prompt bar
--   (one owner for that panel, so nothing fights over a slot) writes them at its safe point.
-- ⭐ The world_live gate is retired with the on_frame hook it was compensating for: it made labels
--   appear only from the session's FIRST SWING, which is exactly when you least need to be told
--   what the buttons do. The tool having been IN HAND for a second is the honest liveness proof —
--   the panel exists and a player is standing in running gameplay holding it.
local HUD_VERB = { TREE = "Chop", STONE = "Dig", SOIL = "Hoe" }   -- Aurora's words, 08-12
local hud_pub = false
re.on_application_entry("UpdateBehavior", function()
    local live = mine.pick_held and mine.hud_labels ~= false
        and mine.held_at and os.clock() - mine.held_at > 1.0
        and _G.IrisPrompt and _G.IrisPrompt.set_slot
    if not live then
        -- ⛔ CLEAR ON THE EDGE, don't wait for the TTL. Publications survive a second by design
        -- (so a throttled publisher can't flicker), which on unequip would leave X reading "Chop"
        -- for a second after the axe is gone — advertising an action that no longer exists.
        if hud_pub and _G.IrisPrompt and _G.IrisPrompt.clear_slot then
            _G.IrisPrompt.clear_slot("iris_tool")
        end
        hud_pub = false
        return
    end
    hud_pub = true
    local verb = HUD_VERB[mine.tool and mine.tool.kind] or "Swing"
    -- X and Y BOTH carry the tool verb, and that is not cosmetic: X_TO_Y above skips the X release
    -- and requests the Y heavy at the same graph point, so X literally IS the slam.
    _G.IrisPrompt.set_slot("iris_tool", "PNL_L03", verb)    -- X
    _G.IrisPrompt.set_slot("iris_tool", "PNL_L02", verb)    -- Y
    -- LB: the whole skill row is dead while a tool is held (the requestActionCore catch-all refuses
    -- every Job05_ skill node), so the button says nothing rather than lying. " " and never "" —
    -- an empty string into a live via.gui.Text is not a risk worth taking for zero benefit.
    _G.IrisPrompt.set_slot("iris_tool", "PNL_L01", " ")
end)

-- the retired on_frame implementation. Left in place, still hard-returning, as the evidence for the
-- comment above; delete it once the LateUpdate route has a few sessions behind it.
local hud_lbl = { at = 0 }
local gui_get = nil
pcall(function() gui_get = sdk.find_type_definition("via.gui.Control"):get_method("getObject(System.String)") end)
re.on_frame(function()
    -- ⛔⛔ THE WORLD-LIVE GATE (2026-08-04). This feature crashed a save-load: "Exception thrown in
    -- REMethodDefinition::invoke for via.gui.Text.set_Message" + c0000005 4ms later - set_Message
    -- hit a text object whose GameObject existed (DrawSelf even read true) mid-load. A time-based
    -- settle can never fix that (loads run 100s+). The cure is the pattern BOTH working
    -- implementations share - Nick's puppeteer relabels only inside an active puppet session, the
    -- griffin HUD (proven in the other Iris session) only while S.mounted - a state that is
    -- REACHABLE ONLY BY PLAYER INPUT IN RUNNING GAMEPLAY. Ours: mine.world_live, set the moment a
    -- swing request arrives. A player mid-swing proves the world, the FSM and the GUI are alive.
    -- Labels therefore appear from the first swing of the session onward.
    -- ⛔⛔⛔ HARD-DISABLED (2026-08-04, THIRD set_Message crash - this one MID-GAMEPLAY behind the
    -- world_live gate, at the exact moment the hoe hit the ground: two set_Message invoke
    -- exceptions 2ms apart, then the c0000005). ROOT CAUSE, finally understood: the griffin HUD
    -- works because MOUNTED prompts are a stable set; the ON-FOOT panel rebuilds itself constantly
    -- (context prompts, and precisely at tool impacts) - so any per-frame write from on_frame
    -- races a rebuild and eventually lands on a dead text object. No gate fixes a race.
    -- ⭐ THE WAY BACK, if ever wanted: SkillCreator/UIHandler/TextHooks.lua does it crash-free by
    -- sdk.hook-ing the GUI's OWN update methods and rewriting labels INSIDE the post-hook - the
    -- write happens at the panel's own safe point instead of racing it. That is a rebuild, not a
    -- toggle; until then this stays off no matter what mine.hud_labels says.
    if true then return end
    if not (mine.pick_held and mine.hud_labels ~= false and mine.world_live and gui_get) then return end
    if os.clock() - hud_lbl.at < 0.3 then return end
    hud_lbl.at = os.clock()
    pcall(function()
        local smgr = sdk.get_native_singleton("via.SceneManager")
        local scene = smgr and sdk.call_native_func(smgr, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        local go = scene and scene:call("findGameObject(System.String)", "ui010201")
        if not (go and go:call("get_DrawSelf")) then return end
        local base = go:call("getComponent(System.Type)", sdk.typeof("app.GUIBase"))
        local root = base and base.Root
        if not root then return end
        local verb = HUD_VERB[mine.tool and mine.tool.kind] or "Swing"
        -- X and Y both carry the tool verb (X substitutes into the Y heavy anyway); LB's skill
        -- row says plainly why nothing fires there
        for path, txt in pairs({
            ["PNL_top/PNL_L03/PNL_txt/mtx_00"] = verb,            -- X
            ["PNL_top/PNL_L02/PNL_txt/mtx_00"] = verb,            -- Y
            ["PNL_top/PNL_L01/PNL_txt/mtx_00"] = "Tool held",     -- LB (skills blocked)
        }) do
            local o = gui_get:call(root, path)
            -- method-call syntax exactly as Nick's working code does it, each write in its own
            -- pcall so one dead text object can't poison the rest
            if o then pcall(function() o:set_Message(txt) end) end
        end
    end)
end)

-- ── HOLD TUNER: the pickaxe head must point DOWN. Extra local rotation painted onto the held
-- weapon AFTER animation writes the frame (the pregnancy/FACE re-assert law); dial it live with
-- the sliders, then SAVE bakes it to mine_swings.json and it re-applies every session.
local function _quat_mul(a, b)
    return {
        w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
        x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
    }
end
local function _euler_quat(xd, yd, zd)
    local rx, ry, rz = math.rad(xd) / 2, math.rad(yd) / 2, math.rad(zd) / 2
    local qx = { w = math.cos(rx), x = math.sin(rx), y = 0, z = 0 }
    local qy = { w = math.cos(ry), x = 0, y = math.sin(ry), z = 0 }
    local qz = { w = math.cos(rz), x = 0, y = 0, z = math.sin(rz) }
    return _quat_mul(_quat_mul(qy, qx), qz)
end
local quat_td = sdk.find_type_definition("via.Quaternion")
-- BASE-CAPTURE law (v2 - v1 SPUN): the wp GO's local transform is NOT rewritten by animation each
-- frame, so composing onto the CURRENT rotation accumulated = helicopter. Capture the native local
-- pose ONCE per parent joint (drawn/sheathed have different parents), then write base*delta
-- absolutely. Delta back to zero -> write the captured base back once and go hands-off.
re.on_application_entry("PrepareRendering", function()
    if not (wc_player_seen_at and os.clock() >= wc_player_seen_at + (wc_settle or 25.0)) then return end
    local wgo = mine.pick_go or (skin.applied and skin.wgo) or nil
    if not wgo then skin.base = nil; return end
    local hold = _active_hold()
    local zero = hold.rot.x == 0 and hold.rot.y == 0 and hold.rot.z == 0
        and hold.pos.x == 0 and hold.pos.y == 0 and hold.pos.z == 0
        and (hold.scale or 1.0) == 1.0
    if zero and not skin.tuner_dirty then return end
    pcall(function()
        local tf = wgo:call("get_Transform")
        local cr = tf:call("get_LocalRotation")
        local cp = tf:call("get_LocalPosition")
        -- ⛔ v3 SELF-HEALING (the saved-base file confessed: the captured "base" was the SHEATHE
        -- pose - pos y 0.46 / x-flip quat, the bundle's own SheatheSetting; drawn and sheathed have
        -- DIFFERENT engine-seated locals and the engine re-writes them on every state change).
        -- New law: the sheathe pose is sacred (never painted, never captured); any pose that isn't
        -- the sheathe and isn't our own paint = a fresh engine seat -> capture as base right then.
        if math.abs(cr.x) > 0.9 and math.abs(cp.y - 0.46) < 0.15 then
            skin.base = nil   -- on the back: pose is sacred; next draw recaptures fresh
            -- ...but SIZE carries over (the engine resets scale on re-seat = shrinking axe xD)
            local s = hold.scale or 1.0
            if s ~= 1.0 then pcall(function() tf:call("set_LocalScale", _vec3(s, s, s)) end) end
            return
        end
        local lp = skin.last_paint
        local ours = false
        if lp then
            local qd = math.abs(cr.x * lp.rot.x + cr.y * lp.rot.y + cr.z * lp.rot.z + cr.w * lp.rot.w)
            local px, py, pz = cp.x - lp.pos.x, cp.y - lp.pos.y, cp.z - lp.pos.z
            ours = qd > 0.9995 and (px * px + py * py + pz * pz) < 0.0004
        end
        if not ours or not skin.base then
            if ours then return end   -- our stale paint with no base (post-reset): wait for a re-draw to re-seat
            skin.base = {
                rot = { x = cr.x, y = cr.y, z = cr.z, w = cr.w },
                pos = { x = cp.x, y = cp.y, z = cp.z } }
        end
        if zero then
            -- restore the native pose once, then stop touching the transform
            local nq = ValueType.new(quat_td)
            nq.x, nq.y, nq.z, nq.w = skin.base.rot.x, skin.base.rot.y, skin.base.rot.z, skin.base.rot.w
            tf:call("set_LocalRotation", nq)
            tf:call("set_LocalPosition", _vec3(skin.base.pos.x, skin.base.pos.y, skin.base.pos.z))
            pcall(function() tf:call("set_LocalScale", _vec3(1.0, 1.0, 1.0)) end)
            skin.tuner_dirty = false
            skin.last_paint = nil
            return
        end
        skin.tuner_dirty = true
        local q = _quat_mul(skin.base.rot, _euler_quat(hold.rot.x, hold.rot.y, hold.rot.z))
        local nq = ValueType.new(quat_td)
        nq.x, nq.y, nq.z, nq.w = q.x, q.y, q.z, q.w
        tf:call("set_LocalRotation", nq)
        local wx = skin.base.pos.x + hold.pos.x
        local wy = skin.base.pos.y + hold.pos.y
        local wz = skin.base.pos.z + hold.pos.z
        tf:call("set_LocalPosition", _vec3(wx, wy, wz))
        local s = hold.scale or 1.0
        pcall(function() tf:call("set_LocalScale", _vec3(s, s, s)) end)
        skin.last_paint = { rot = { x = q.x, y = q.y, z = q.z, w = q.w }, pos = { x = wx, y = wy, z = wz } }
    end)
end)

-- ── WEAPON ID PROBE: name the EQUIPPED weapon's wp GameObject + mesh path. The pickaxe/axe become
-- real items by MESH-OVERRIDING a donor two-hander (Aurora picks a cheap one she'll sacrifice
-- globally); this probe reads the donor's exact asset path off her equipped weapon.
local function _weapon_probe()
    local lines = {}
    pcall(function()
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local pgo = cm:call("get_ManualPlayer"):call("get_GameObject")
        local tf = pgo:call("get_Transform")
        local child = tf:call("get_Child")
        while child do
            local cgo = child:call("get_GameObject")
            local nm = cgo and cgo:call("get_Name") or ""
            if tostring(nm):find("^wp") then
                local entry = "weapon GO: " .. tostring(nm)
                pcall(function()
                    local mc = cgo:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
                    local mp = mc and mc:call("getMesh")
                    local s = tostring(mp)
                    pcall(function() s = tostring(mp:call("ToString()")) end)
                    entry = entry .. "  mesh=" .. (s:match("%[@?(.-)%]") or s)
                end)
                lines[#lines + 1] = entry
            end
            child = child:call("get_Next")
        end
    end)
    if #lines == 0 then
        M.last = "no wp* child found - is a weapon equipped (try drawn)?"
    else
        for _, l in ipairs(lines) do _log("WEAPON PROBE: " .. l) end
        M.last = lines[1] .. (#lines > 1 and ("  (+" .. (#lines - 1) .. " more in log)") or "")
    end
end

-- ── BREAKABLE CENSUS: sweep the area for EVERY gimmick with an HP/break API ─────────────────────
-- Answers "which trees (and what else) around here are choppable" without guessing type names:
-- tree brains derive from app.GimmickBase (probe: requestEffect takes app.GimmickBase.RequestEffectData).
M.census_range = 60.0

local function _census()
    local f = io.open("IRIS/woodcut_census.txt", "w")
    if not f then M.last = "cannot open woodcut_census.txt"; return end
    f:write("BREAKABLE CENSUS " .. os.date("%Y-%m-%d %H:%M:%S") .. "  range " .. M.census_range .. "m\n")
    local pp
    pcall(function()
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local pl = cm and cm:call("get_ManualPlayer")
        pp = pl and pl:call("get_GameObject"):call("get_Transform"):call("get_UniversalPosition")
    end)
    if not pp then f:write("no player\n"); f:close(); M.last = "no player"; return end
    local rows, counts, total = {}, {}, 0
    pcall(function()
        local sm = sdk.get_native_singleton("via.SceneManager")
        local smt = sdk.find_type_definition("via.SceneManager")
        local scene = sm and sdk.call_native_func(sm, smt, "get_CurrentScene")
        local comps = scene and scene:call("findComponents(System.Type)", sdk.typeof("app.GimmickBase"))
        local n = 0
        pcall(function() n = comps:call("get_Length") or 0 end)
        if n == 0 then pcall(function() n = comps:get_size() or 0 end) end
        f:write("GimmickBase components in scene: " .. tostring(n) .. "\n")
        for i = 0, (tonumber(n) or 0) - 1 do
            pcall(function()
                local c
                pcall(function() c = comps:call("get_Item", i) end)
                if not c then pcall(function() c = comps:get_element(i) end) end
                if not c then return end
                total = total + 1
                local tn = "?"; pcall(function() tn = c:get_type_definition():get_full_name() end)
                local go = c:call("get_GameObject")
                local up = go and go:call("get_Transform"):call("get_UniversalPosition")
                if not up then return end
                local dx, dy, dz = up.x - pp.x, up.y - pp.y, up.z - pp.z
                local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                if d > M.census_range then return end
                local hp, maxhp, broken, unbreak
                pcall(function() hp = tonumber(c:call("getHp")) end)
                pcall(function() maxhp = tonumber(c:call("getMaxHp")) end)
                pcall(function() broken = c:call("get_IsBroken") end)
                pcall(function() unbreak = c:call("get_IsUnbreakable") end)
                local nm = "?"; pcall(function() nm = go:call("get_Name") end)
                if hp ~= nil then   -- has the HP API = chop-able family
                    counts[tn] = (counts[tn] or 0) + 1
                    rows[#rows + 1] = { d = d, tn = tn, poolless = (tonumber(maxhp) or 0) <= 0,
                        s = string.format("%5.1fm  %-22s %-18s hp %s/%s%s%s",
                        d, tn, tostring(nm), tostring(hp), tostring(maxhp),
                        broken and "  BROKEN" or "", unbreak and "  UNBREAKABLE" or "") }
                end
            end)
        end
    end)
    table.sort(rows, function(a, b) return a.d < b.d end)
    f:write("\n-- HP-bearing breakables within range (nearest first) --\n")
    for _, r in ipairs(rows) do f:write(r.s .. "\n") end
    f:write("\n-- counts by type --\n")
    for tn, ct in pairs(counts) do f:write(string.format("  %-24s x%d\n", tn, ct)) end
    -- ⭐ HARVEST CANDIDATES: breakable classes NOT yet in our tree/rock sets - run this in forests
    -- and rocky ground; anything tree-ish or stone-ish here is a set-addition waiting to happen
    f:write("\n-- CANDIDATES (breakable, NOT in TREE_SET/ROCK_SET - poolless marked) --\n")
    for _, r in ipairs(rows) do
        if r.tn and not TREE_SET[r.tn] and not ROCK_SET[r.tn] then
            f:write("  " .. r.s .. (r.poolless and "   << break-on-hit" or "") .. "\n")
        end
    end
    f:write("\n(total GimmickBase walked: " .. total .. ")\n")
    f:close()
    M.last = "CENSUS -> data/IRIS/woodcut_census.txt (" .. #rows .. " breakables in " .. M.census_range .. "m)"
    _log(M.last)
end

local function _probe()
    if not _ensure_ray() then M.last = "ray not ready"; return end
    local ox, oy, oz, fx, fy, fz
    pcall(function()
        local cam = sdk.get_primary_camera()
        local cgo = cam and cam:call("get_GameObject")
        local ctf = cgo and cgo:call("get_Transform")
        local p = ctf and ctf:call("get_Position")
        local fwd = ctf and ctf:call("get_AxisZ")
        if p and fwd then ox, oy, oz = p.x, p.y, p.z; fx, fy, fz = fwd.x, fwd.y, fwd.z end
    end)
    if not ox then M.last = "no camera to aim from"; return end
    local fl = math.sqrt(fx * fx + fy * fy + fz * fz)
    if fl < 0.001 then M.last = "bad forward vector"; return end
    fx, fy, fz = fx / fl, fy / fl, fz / fl

    local f = io.open("IRIS/woodcut_probe.txt", "w")
    if not f then M.last = "cannot open woodcut_probe.txt"; return end
    f:write("WOODCUT TREE AIM PROBE " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
    f:write("aim at a DESTRUCTIBLE tree (the kind big monsters smash)\n")
    local seen = {}   -- owner GO addresses already dumped (skip terrain re-dumps across layers)
    for _, dir in ipairs({ 1, -1 }) do
        local dx, dy, dz = fx * dir, fy * dir, fz * dir
        for layer = 0, 15 do
            local nhit = 0
            pcall(function()
                ray.filter:set_Group(0); ray.filter:set_Layer(layer); ray.filter:set_MaskBits(0)
                ray.result:clear()
                ray.query:call("setRay(via.vec3, via.vec3)", _vec3(ox, oy, oz), _vec3(ox + dx * 30, oy + dy * 30, oz + dz * 30))
                ray.method:call(ray.system, ray.query, ray.result)
                nhit = ray.result:get_NumContactPoints() or 0
            end)
            if nhit > 0 then
                for i = 0, math.min(nhit, 2) - 1 do
                    pcall(function()
                        local cp = ray.result:call("getContactPoint(System.UInt32)", i)
                        local pos = cp and sdk.get_native_field(cp, ray.contact_td, "Position")
                        local col = ray.result:call("getContactCollidable(System.UInt32)", i)
                        local go; pcall(function() go = col and col:call("get_GameObject") end)
                        if go then
                            -- climb to the ROOT owner (the gimmick core usually sits at the top)
                            local root, guard = go, 0
                            while guard < 6 do
                                local par
                                pcall(function()
                                    local tf = root:call("get_Transform")
                                    local ptf = tf and tf:call("get_Parent")
                                    par = ptf and ptf:call("get_GameObject")
                                end)
                                if par then root = par; guard = guard + 1 else break end
                            end
                            local addr = tostring(root)
                            if not seen[addr] then
                                seen[addr] = true
                                local d = pos and math.sqrt((pos.x - ox) ^ 2 + (pos.y - oy) ^ 2 + (pos.z - oz) ^ 2) or -1
                                f:write(string.format("\n=== dir %+d LAYER %d hit dist %.1fm ===\n", dir, layer, d))
                                _dump_go_tree(f, root, "", 0)
                            end
                        end
                    end)
                end
            end
        end
    end
    f:close()
    M.last = "TREE PROBE -> data/IRIS/woodcut_probe.txt"
    _log(M.last)
end

-- ── THE QUARRY: real gm80_009 minable rocks spawned in a ring around a homestead plot, so every
-- deed comes with stone in reach. Spawn recipe = the griffin-egg machine (IrisTaming, PROVEN):
-- via.Prefab + PrefabController pair -> GenerateInfoContainer (universal coords, Gimmick category,
-- GimmickID enum) -> GenerateManager.requestCreateInstance -> poll InstanceInfo.
local quarry = { jobs = {}, rocks = {}, seq = 0 }
M.quarry_count = 4
M.quarry_radius = 9.0
M.quarry_cluster = true    -- Aurora's pick: one rocky OUTCROP (tight group), not a scattered ring

local function _quarry_despawn()
    for _, go in ipairs(quarry.rocks) do pcall(function() go:call("destroy", go) end) end
    quarry.rocks, quarry.jobs = {}, {}
    quarry.anchor = nil
end

local function _game_day()
    local d
    pcall(function() d = tonumber(sdk.get_managed_singleton("app.TimeManager"):call("get_InGameDay")) end)
    return d
end

-- ── ⭐⭐⭐ GROUND SNAP v2 — 2026-08-12. Aurora: "are we able to make sure the quarries that spawn by
-- homestead plots don't let the boulders spawn in midair?" (screenshot: a boulder hanging ~2m up
-- against a cliff face at her plot's edge).
--
-- v1 had FIVE independent defects and ANY ONE of them puts a rock in the air. Worth listing, because
-- four of them are mistakes this repo has already paid for somewhere else:
--   1. ⛔⛔ IT FAILED OPEN TO THE ANCHOR. The call site read `y = (gy or uy) + 0.1` — so a MISSED
--      cast parked the rock at the HOUSE FLOOR's height (`rec.uy`, the build site's ground + lift).
--      The outcrop sits 9m out where, as v1's own comment said, "the terrain drops". A failed
--      measurement silently became a placement. That is the floating rock.
--   2. ⛔ THE CAST WINDOW WAS PINNED TO THE HOUSE FLOOR, not to the ground it was hunting:
--      start = anchor+4, end = anchor−20. At the foot of a cliff the real ground 9m out can be well
--      over 20m below (window too short → miss) or ABOVE anchor+4, in which case the ray STARTS
--      UNDERGROUND and finds nothing at all. Both ends were too tight.
--   3. ⛔ IT CAST LAYERS {0,1,2} AND KEPT THE HIGHEST HIT (`pos.y > best`). Every other ground ray in
--      this repo casts LAYER 2 ONLY — this file's own tree/rock finders (:175, :801),
--      IrisHomestead's `_ground_at` (:154), the griffin's cast — because 2 is terrain/static.
--      Layers 0/1 are not ground, and "keep the highest" is exactly the rule that lets an invisible
--      trigger volume hovering above the terrain WIN the vote.
--   4. ⛔ IT READ CONTACT INDEX 0 AND NOTHING ELSE. `IrisHomestead._ground_at` walks every contact
--      and takes the one NEAREST the reference height — which is what dodges the "a candidate over a
--      ledge returns a floor three storeys down" trap the taming ground probe already paid for.
--   5. ⛔ IT NEVER READ THE SURFACE NORMAL, so a downcast grazing the near-vertical face of that big
--      rock seats a boulder ON A WALL. IrisHomestead has read `Normal` and rejected `ny < cliff_ny`
--      since the plot scout shipped; the quarry simply never did.
M.quarry_ny_min   = 0.55   -- flatter than ~57° off vertical is ground; steeper is a wall
M.quarry_drop_max = 10.0   -- how far BELOW the plot anchor a rock may legitimately sit
M.quarry_rise_max = 6.0    -- ...and how far above (a roof or a boulder-top hit reads as a big rise)
M.quarry_over_max = 2.5    -- geometry standing ON the spot (that cliff): don't bury a rock inside it

-- ONE downcast. Returns universal y, the surface normal's y, and how much geometry stands ABOVE the
-- chosen floor here. On any failure: nil + a reason string — and a failure is never allowed to
-- become a Y.
local function _quarry_ground(x_u, y_u, z_u)
    if not _ensure_ray() then return nil, "raycast unavailable" end
    -- ⛔ THE OFFSET READ IS LOAD-BEARING, AND v1 SWALLOWED IT. v1 initialised (0,0,0) and did the
    -- read inside a pcall, so on any frame where get_ManualPlayer was unreadable the "render-space"
    -- cast was fired at UNIVERSAL coordinates — two spaces that diverge by up to a session-dependent
    -- 128m tile offset — which misses everything and dropped straight into defect 1. The woodcut log
    -- shows the daily renew firing with `get_InGameDay` reading 0 in a day-307 save, i.e. exactly
    -- such a degenerate moment. A read we cannot do is an ABORT, not a cast into the void.
    local got, ox, oy, oz = false, 0, 0, 0
    pcall(function()
        local tf = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
            :call("get_GameObject"):call("get_Transform")
        local rp, up = tf:call("get_Position"), tf:call("get_UniversalPosition")
        ox, oy, oz = up.x - rp.x, up.y - rp.y, up.z - rp.z
        got = true
    end)
    if not got then return nil, "player offset unreadable" end
    local rx, ry, rz = x_u - ox, y_u - oy, z_u - oz
    local gy, gny, topy = nil, 1.0, -1e18
    pcall(function()
        ray.filter:set_Group(0); ray.filter:set_Layer(2); ray.filter:set_MaskBits(0)
        ray.result:clear()
        -- 40m up / 60m down: IrisHomestead._ground_at's proven window, wide enough that a plot on a
        -- slope still finds its own ground out at the outcrop.
        ray.query:call("setRay(via.vec3, via.vec3)", _vec3(rx, ry + 40.0, rz), _vec3(rx, ry - 60.0, rz))
        ray.method:call(ray.system, ray.query, ray.result)
        local n = tonumber(ray.result:get_NumContactPoints() or 0) or 0
        local bestd, ys = 1e18, {}
        for k = 0, n - 1 do
            local cp = ray.result:call("getContactPoint(System.UInt32)", k)
            local pos = cp and sdk.get_native_field(cp, ray.contact_td, "Position")
            if pos then
                ys[#ys + 1] = pos.y
                local d = math.abs(pos.y - ry)        -- NEAREST the reference height, not the highest
                if d < bestd then
                    bestd = d; gy = pos.y
                    local nm = sdk.get_native_field(cp, ray.contact_td, "Normal")
                    gny = (nm and nm.y) or 1.0
                end
            end
        end
        -- ⭐ "IS SOMETHING STANDING IN THIS ROCK'S SPACE" — measured only in the BAND just above the
        -- chosen floor, NOT as (highest contact − floor). IrisHomestead's plot scout uses the whole
        -- window for that reading, but it is looking for scenery over a 13m house footprint; here the
        -- question is whether a boulder fits, and taking the global top would let ANY overhead
        -- geometry within the 40m up-reach (her own roof, an arch, the cliff overhanging from above)
        -- veto every candidate — turning "floating rocks" into "no quarry at all", which would be a
        -- worse regression than the bug.
        for _, y in ipairs(ys) do
            if gy and y > gy + 0.05 and y <= gy + 4.0 and y > topy then topy = y end
        end
    end)
    if not gy then return nil, "no layer-2 contact" end
    return gy + oy, gny, (topy > gy) and (topy - gy) or 0.0
end

-- ⭐⭐ REJECT AND RELOCATE — NEVER FAIL OPEN. The same policy IrisHomesteadBox landed for this exact
-- class of bug ("Mootilda in the stream below the cliff edge"): a spot whose ground we cannot trust
-- is not a spot, so go and find another one. Returns a seatable universal Y, or nil + why.
local function _quarry_seat(x, uy, z)
    local gy, ny, over = _quarry_ground(x, uy, z)   -- on failure the 2nd return is the reason
    if not gy then return nil, tostring(ny) end
    if ny < (M.quarry_ny_min or 0.55) then
        return nil, string.format("wall / steep face (ny=%.2f)", ny)
    end
    if (uy - gy) > (M.quarry_drop_max or 10.0) then
        return nil, string.format("floor %.1fm BELOW the plot - a ledge, not this ground", uy - gy)
    end
    if (gy - uy) > (M.quarry_rise_max or 6.0) then
        return nil, string.format("floor %.1fm ABOVE the plot - a roof or a boulder top", gy - uy)
    end
    if over > (M.quarry_over_max or 2.5) then
        return nil, string.format("%.1fm of geometry already stands here", over)
    end
    return gy
end

local function _quarry_spawn(ux, uy, uz)
    _quarry_despawn()
    local gid
    pcall(function()
        local f = sdk.find_type_definition("app.GimmickID"):get_field("Gm80_009")
        if f then gid = f:get_data() end
    end)
    if not gid then _log("QUARRY: GimmickID Gm80_009 unresolved"); return end
    local n = math.max(1, math.floor(M.quarry_count))
    local placed, skipped = 0, 0
    local cx, cz, lastwhy
    if M.quarry_cluster then
        -- ⭐ FIND A BEARING THAT ACTUALLY HAS GROUND — ONCE, FOR THE WHOLE OUTCROP. v1 used a FIXED
        -- world bearing of 0.6 rad: never rotated by plot yaw and never checked, so at Aurora's plot
        -- it aimed the outcrop straight into a cliff. Golden-angle retries spread candidates right
        -- around the plot instead of creeping along one arc.
        for try = 0, 9 do
            local ca = 0.6 + 2.399963 * try
            local tx = ux + math.cos(ca) * M.quarry_radius
            local tz = uz + math.sin(ca) * M.quarry_radius
            local gy, why = _quarry_seat(tx, uy, tz)
            if gy then cx, cz = tx, tz; break end
            lastwhy = why
            _log(string.format("QUARRY: bearing %.2f rad rejected - %s", ca, tostring(why)))
        end
        if not cx then
            -- ⛔ AND IF NOWHERE WORKS, SPAWN NOTHING. A quarry that is absent is a cosmetic
            -- shortfall; a boulder hanging in the air is the bug report. The anchor is still stored
            -- so the daily renew can try again once the world has streamed in properly.
            quarry.anchor = { x = ux, y = uy, z = uz }
            quarry.day = _game_day()
            _log(string.format("QUARRY: no seatable ground within %.1fm of the plot (last: %s) - "
                .. "spawned NOTHING rather than floating rocks", M.quarry_radius, tostring(lastwhy)))
            return
        end
    end
    for i = 1, n do
        local x, z
        if M.quarry_cluster then
            local sub = (i - 1) * (2 * math.pi / math.max(n, 3))
            x, z = cx + math.cos(sub) * 1.9, cz + math.sin(sub) * 1.9
        else
            local ang = (i - 0.5) * (2 * math.pi / n) + 0.6
            x = ux + math.cos(ang) * M.quarry_radius
            z = uz + math.sin(ang) * M.quarry_radius
        end
        local gy, why = _quarry_seat(x, uy, z)
        if not gy and M.quarry_cluster then
            -- one nudge back toward the validated centre before giving up on this rock
            x, z = cx + (x - cx) * 0.45, cz + (z - cz) * 0.45
            gy, why = _quarry_seat(x, uy, z)
        end
        if gy then
            placed = placed + 1
            quarry.jobs[#quarry.jobs + 1] = { x = x, y = gy + 0.1, z = z, gid = gid, stage = "prefab", f = 0 }
        else
            skipped = skipped + 1
            _log(string.format("QUARRY: rock %d skipped - %s", i, tostring(why)))
        end
    end
    quarry.anchor = { x = ux, y = uy, z = uz }
    quarry.day = _game_day()
    _log(string.format("QUARRY: %d rock(s) seated, %d skipped (%s) at (%.1f,%.1f,%.1f)",
        placed, skipped, M.quarry_cluster and "outcrop" or "ring", ux, uy, uz))
end

-- ⛔⛔ PAUSE GUARD (added 08-12 alongside the snap fix). The pump below calls
-- GenerateManager.requestCreateInstance, and "NOTHING spawns while the world is paused" is a
-- documented CTD law here — IrisHomestead's pump has guarded on exactly this since the
-- frame-gen-toggle-while-spawning crash, and IRIS has already eaten one pause-menu spawn crash.
-- This pump had NO pause check, NO player-presence check and NO distance check, and the daily renew
-- fires on a frame counter, so it could spawn four rocks while she sits in a menu or in photo mode.
local function _quarry_paused()
    local p = false
    pcall(function()
        local pm = sdk.get_managed_singleton("app.PauseManager")
        if pm and pm:call("isPausedAny") == true then p = true end
    end)
    if not p then
        pcall(function()
            local gm = sdk.get_managed_singleton("app.GuiManager")
            if gm and (gm:call("get_IsDispPhotoModeAll") == true
                or gm:call("get_IsDispPhotoMode") == true
                or gm:call("isPausedGUI") == true) then p = true end
        end)
    end
    return p
end

re.on_application_entry("UpdateBehavior", function()
    -- paused = slide everything forward, plus a 3s grace after unpausing (a frame-gen toggle resets
    -- the device, and streaming needs a moment before a spawn is safe)
    if _quarry_paused() then quarry.pause_grace = os.clock() + 3.0; return end
    if os.clock() < (quarry.pause_grace or 0) then return end
    -- THE VEIN RENEWS AT DAWN: once all quarry rocks are smashed, a new in-game day respawns the
    -- outcrop (checked ~5s; "mined a few times before timing out for the day" - Aurora's spec)
    if #quarry.jobs == 0 and quarry.anchor then
        quarry.renew_f = (quarry.renew_f or 0) + 1
        if quarry.renew_f > 300 then
            quarry.renew_f = 0
            local today = _game_day()
            if today and quarry.day and today ~= quarry.day then
                local a = quarry.anchor
                _log("QUARRY: a new day (" .. today .. ") - the vein renews")
                _quarry_spawn(a.x, a.y, a.z)
                return
            end
        end
    end
    if #quarry.jobs == 0 then return end
    for i = #quarry.jobs, 1, -1 do
        local q = quarry.jobs[i]
        local drop = false
        if q.stage == "prefab" then
            local ok = pcall(function()
                local prefab = sdk.create_instance("via.Prefab"):add_ref()
                prefab:set_Path(q.path_override or "AppSystem/gimmick/prefab/gm80_009.pfb")
                pcall(function() prefab:set_Standby(true) end)
                local ctrl = sdk.create_instance("app.PrefabController"):add_ref()
                ctrl._Item = prefab
                pcall(function() ctrl:get_Item():set_Standby(true) end)
                local inst = sdk.create_instance("app.InstanceInfo"):add_ref()
                local container
                pcall(function() container = inst:get_Container() end)
                if not container then container = sdk.create_instance("app.GenerateInfo.GenerateInfoContainer"):add_ref() end
                local pos = ValueType.new(sdk.find_type_definition("via.Position"))
                pos.x, pos.y, pos.z = q.x, q.y, q.z
                local cat = 5
                pcall(function()
                    local f2 = sdk.find_type_definition("app.GeneratorCategory"):get_field("Gimmick")
                    if f2 then cat = f2:get_data() end
                end)
                pcall(function() container._CommonInfo._Category = cat end)
                pcall(function() container._CommonInfo._ObjectID._SelectedGimmickID = q.gid end)
                pcall(function() container._CommonInfo._InitialPosition = pos end)
                pcall(function() container._CommonInfo._ContextPosition = pos end)
                pcall(function() container._CommonInfo:setContextPosition(pos) end)
                pcall(function() container._StatusInfo["<ScaleRate>k__BackingField"] = 1.0 end)
                q.prefab, q.ctrl, q.inst, q.container = prefab, ctrl, inst, container
            end)
            if ok and q.prefab then q.stage = "wait"; q.f = 0 else drop = true end
        elseif q.stage == "wait" then
            q.f = q.f + 1
            local ready = false
            pcall(function() ready = q.prefab:get_Ready() == true end)
            if ready then
                quarry.seq = quarry.seq + 1
                local okr = pcall(function()
                    local gen = sdk.get_managed_singleton("app.GenerateManager")
                    gen:call("requestCreateInstance(app.PrefabController, app.GenerateInfo.GenerateInfoContainer, System.Int32, app.InstanceInfo, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>)",
                        q.ctrl, q.container, 740000 + quarry.seq, q.inst, nil, nil)
                end)
                if okr then q.stage = "poll"; q.f = 0 else drop = true end
            elseif q.f > 1500 then drop = true end
        elseif q.stage == "poll" then
            q.f = q.f + 1
            local go
            pcall(function() go = q.inst:get_Instance() end)
            if not go then pcall(function() go = q.inst["<Instance>k__BackingField"] end) end
            if go then
                pcall(function() go = go:add_ref() end)
                quarry.rocks[#quarry.rocks + 1] = go
                _log("QUARRY: rock up (" .. #quarry.rocks .. ")")
                drop = true   -- job complete
            elseif q.f > 1500 then drop = true end
        end
        if drop then table.remove(quarry.jobs, i) end
    end
end)

_G.IrisQuarry = {
    spawn = _quarry_spawn,
    despawn = _quarry_despawn,
    count = function() return #quarry.rocks end,
}

-- never leave the player FSM frozen across a reset (mid-gather Reset Scripts = locked controls)
re.on_script_reset(function()
    pcall(function()
        local ch = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
        local h = ch and ch:call("get_Human")
        if h and h.Fsm then h.Fsm:set_Enabled(true) end
    end)
end)

re.on_draw_ui(function()
    if not imgui.tree_node("IRIS WOODCUTTING (axe & trees)") then return end
    imgui.text(M.last)
    imgui.text("CHOP TEST (probe-proven on gm80_109): aim at a breakable tree's TRUNK, get close,")
    imgui.text("press CHOP. HP chips down; at 0 the tree falls via its own native break.")
    local c
    c, M.chop_pct = imgui.slider_float("damage per chop (% of max HP)##iwc", M.chop_pct, 5.0, 100.0)
    c, M.chop_range = imgui.slider_float("axe reach (m)##iwc", M.chop_range, 2.0, 12.0)
    c, M.instant = imgui.checkbox("instant fell (one press)##iwc", M.instant)
    c, M.hp_watch = imgui.checkbox("TREE HP WATCH (whack the nearest tree with your WEAPON - does hp drop?)##iwc", M.hp_watch)
    -- dresses WHICHEVER tool is in hand (was hardcoded to the pickaxe donor, so it could never
    -- fix the hoe); falls back to the pickaxe when nothing recognised is equipped
    local _dress_lbl = skin.applied and "RESTORE WEAPON##iwc_skin"
        or ("DRESS THE TOOL IN HAND: " .. ((mine.tool and mine.tool.name) or "pickaxe"):upper() .. "##iwc_skin")
    if imgui.button(_dress_lbl) then
        if skin.applied then
            _restore_skin()
        else
            -- equip + DRAW your weapon first; donor eqit prop spawns, holders get stolen, weapon reskins
            skin.pending = true
            _preview_spawn((mine.tool and mine.tool.donor) or "appsystem/equipment/eqit/eqit02_005.pfb", "skin_donor")
        end
    end
    if imgui.button("CHOP##iwc") then
        local ok, err = pcall(_chop)
        if not ok then M.last = "chop ERROR: " .. tostring(err); _log(M.last) end
    end
    imgui.same_line()
    if imgui.button("TREE AIM PROBE##iwc") then
        local ok, err = pcall(_probe)
        if not ok then M.last = "probe ERROR: " .. tostring(err); _log(M.last) end
    end
    imgui.same_line()
    if imgui.button("BREAKABLE CENSUS (60m sweep)##iwc") then
        local ok, err = pcall(_census)
        if not ok then M.last = "census ERROR: " .. tostring(err); _log(M.last) end
    end
    imgui.same_line()
    if imgui.button("WEAPON ID PROBE (equip the donor first)##iwc") then
        local ok, err = pcall(_weapon_probe)
        if not ok then M.last = "weapon probe ERROR: " .. tostring(err); _log(M.last) end
    end
    imgui.text("")
    imgui.text("-- CE TOOLS: pickaxe (47200) mines stone, woodaxe (47210) fells trees, hoe (47220) tills soil --")
    imgui.text(mine.pick_held and ("TOOL IN HAND: " .. ((mine.tool and mine.tool.name) or "?"):upper()) or "no tool equipped (or not drawn)")
    if imgui.button("GIVE HOE (item 34713)##iwc_giveh") then
        local ok, err = pcall(function()
            local im = sdk.get_managed_singleton("app.ItemManager")
            local gm = sdk.find_type_definition("app.ItemManager"):get_method(
                "getItem(System.Int32, System.Int32, app.Character, System.Boolean, System.Boolean, System.Boolean, app.ItemManager.GetItemEventType, System.Boolean, System.Boolean)")
            local chara = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
            gm:call(im, 34713, 1, chara, true, false, false, nil, true, false)
        end)
        M.last = ok and "hoe granted - equip AND DRAW it, then check TOOL IN HAND says HOE" or ("give ERROR: " .. tostring(err))
        _log(M.last)
    end
    if imgui.button("GIVE WOODAXE (item 34712)##iwc_givea") then
        local ok, err = pcall(function()
            local im = sdk.get_managed_singleton("app.ItemManager")
            local gm = sdk.find_type_definition("app.ItemManager"):get_method(
                "getItem(System.Int32, System.Int32, app.Character, System.Boolean, System.Boolean, System.Boolean, app.ItemManager.GetItemEventType, System.Boolean, System.Boolean)")
            local chara = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
            gm:call(im, 34712, 1, chara, true, false, false, nil, true, false)
        end)
        M.last = ok and "woodaxe granted - check your inventory" or ("give ERROR: " .. tostring(err))
        _log(M.last)
    end
    imgui.same_line()
    if imgui.button("GIVE PICKAXE (item 34700)##iwc_give") then
        -- shop-ledger rescue: the sold-out copy was silently stripped from the save back when the
        -- bundle was parked (undefined items get culled on load). Nick's proven getItem call.
        local ok, err = pcall(function()
            local im = sdk.get_managed_singleton("app.ItemManager")
            local gm = sdk.find_type_definition("app.ItemManager"):get_method(
                "getItem(System.Int32, System.Int32, app.Character, System.Boolean, System.Boolean, System.Boolean, app.ItemManager.GetItemEventType, System.Boolean, System.Boolean)")
            local chara = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
            gm:call(im, 34700, 1, chara, true, false, false, nil, true, false)
        end)
        M.last = ok and "pickaxe granted - check your inventory" or ("give ERROR: " .. tostring(err))
        _log(M.last)
    end
    local mc
    mc, skin.auto = imgui.checkbox("auto-reskin the CE pickaxe##iwc_mine", skin.auto)
    mc, mine.block_skills = imgui.checkbox("tool, not a weapon: only the Y-slam works (other attacks + skills blocked)##iwc_mine", mine.block_skills)
    -- ⛔ the "no MOVING attacks" checkbox is RETIRED (08-12) - it blocked the LongRange family,
    -- which is every stationary swing when there is no enemy to range against, AND partially
    -- blocked the Range windups (the FSM-wedging law). `swing stays PLANTED` below is the real
    -- answer to "don't let it carry me forward" and does it without touching the action graph.
    -- ── the MH Wilds swing paint (pickaxe + hoe; the axe keeps its bank-150 chop) ──
    -- ── the NATIVE swing, tuned (the default since 08-04 late) ──
    mc, mine.swing_speed = imgui.slider_float("swing speed (all tools)##iwc_ss", mine.swing_speed or 2.2, 0.5, 2.5)
    mc, mine.pin_swing = imgui.checkbox("swing stays PLANTED (no forward lunge)##iwc_pin", mine.pin_swing ~= false)
    -- the Wilds paint survives as an opt-in curiosity
    mc, mine.wilds_swing = imgui.checkbox("MH Wilds swing animation instead (opt-in)##iwc_mine", mine.wilds_swing == true)
    if mine.wilds_swing == true then
        mc, mine.wilds_ground = imgui.slider_float("  hip drop scale##iwc_wg", mine.wilds_ground or 0.7, 0.0, 1.2)
        mc, mine.impact_wilds = imgui.slider_float("  impact timing (s after swing starts)##iwc_wi", mine.impact_wilds or 0.68, 0.3, 1.5)
    end
    mc, mine.hud_labels = imgui.checkbox("relabel the button guide (X/Y = Chop/Dig/Hoe, LB blanked)##iwc_hud", mine.hud_labels ~= false)
    imgui.text("   (published to IrisPromptBar and written on LateUpdate - the 08-04 crashes were")
    imgui.text("    re.on_frame, i.e. the render thread, not a race with the panel's rebuild)")
    mc, mine.gate = imgui.checkbox("MINING GATE (Y-slam strikes nearby stone)##iwc_mine", mine.gate)
    if M.auto_gather == nil then M.auto_gather = true end
    mc, M.auto_gather = imgui.checkbox("auto-gather bow after a rock breaks (60:6001)##iwc_mine", M.auto_gather)
    mc, M.wild_trees = imgui.checkbox("WILD TREES: the whole forest is choppable (scenery trees, 3 hits)##iwc_mine", M.wild_trees)
    mc, M.wild_hits = imgui.slider_int("wild tree chops to fell##iwc_mine", M.wild_hits or 3, 1, 6)
    mc, M.wild_rocks = imgui.checkbox("WILD ROCKS: rocky scenery is minable veins (sm1x boulders; the rock stays)##iwc_mine", M.wild_rocks)
    mc, M.rock_hits = imgui.slider_int("wild rock strikes per vein##iwc_mine", M.rock_hits or 4, 1, 8)
    mc, M.rock_sense = imgui.checkbox("ROCK SENSE: pickaxe in hand marks nearby veins ('Stone' floaters, 45m)##iwc_mine", M.rock_sense)
    mc, mine.impact_delay = imgui.slider_float("pickaxe impact delay (s: swing start -> pick bites; chips fired early per Aurora)##iwc_mine", mine.impact_delay, 0.2, 2.0)
    if mc then _save_swings() end
    if M.wild_cone == nil then M.wild_cone = 35.0 end
    mc, M.wild_cone = imgui.slider_float("wild aim cone (deg)##iwc_mine", M.wild_cone, 10.0, 75.0)
    mc, mine.impact_delay = imgui.slider_float("pickaxe impact delay##iwc_mine", mine.impact_delay, 0.1, 1.5)
    if mc then _save_swings() end
    if mine.impact_axe == nil then mine.impact_axe = 0.9 end
    mc, mine.impact_axe = imgui.slider_float("axe impact delay (chop contact)##iwc_mine", mine.impact_axe, 0.2, 2.0)
    if mc then _save_swings() end
    if M.chop_cancel == nil then M.chop_cancel = 1.45 end
    mc, M.chop_cancel = imgui.slider_float("axe chop end (cancel to idle)##iwc_mine", M.chop_cancel, 0.8, 3.0)
    local hold = _active_hold()
    imgui.text("hold tuner [" .. ((mine.tool and mine.tool.name) or "pickaxe") .. "]: rot / grip / size - per tool, ctrl+click to type")
    local rc
    rc, hold.rot.x = imgui.slider_float("rot X##iwc_rot", hold.rot.x, -180.0, 180.0)
    rc, hold.rot.y = imgui.slider_float("rot Y##iwc_rot", hold.rot.y, -180.0, 180.0)
    rc, hold.rot.z = imgui.slider_float("rot Z##iwc_rot", hold.rot.z, -180.0, 180.0)
    rc, hold.pos.x = imgui.slider_float("grip X (m)##iwc_pos", hold.pos.x, -0.8, 0.8)
    rc, hold.pos.y = imgui.slider_float("grip Y (m)##iwc_pos", hold.pos.y, -0.8, 0.8)
    rc, hold.pos.z = imgui.slider_float("grip Z (m)##iwc_pos", hold.pos.z, -0.8, 0.8)
    rc, hold.scale = imgui.slider_float("size x##iwc_scl", hold.scale or 1.0, 0.5, 2.5)
    if imgui.button("SAVE HOLD##iwc_rot") then
        _save_swings()
        M.last = string.format("hold saved [%s]: rot %.0f/%.0f/%.0f grip %.2f/%.2f/%.2f size %.2f",
            (mine.tool and mine.tool.name) or "pickaxe",
            hold.rot.x, hold.rot.y, hold.rot.z, hold.pos.x, hold.pos.y, hold.pos.z, hold.scale or 1.0)
    end
    imgui.same_line()
    if imgui.button("RESET HOLD##iwc_rot") then
        hold.rot.x, hold.rot.y, hold.rot.z = 0, 0, 0
        hold.pos.x, hold.pos.y, hold.pos.z = 0, 0, 0
        hold.scale = 1.0
        _save_swings()
    end
    imgui.text("recent motions (fallback lane - the Y-slam already mines via its action node;")
    imgui.text("this stays for gating other vocations' swings later):")
    for i, key in ipairs(mine.recent) do
        imgui.text("  " .. key .. (mine.ids[key] and "  [GATED]" or ""))
        imgui.same_line()
        if mine.ids[key] then
            if imgui.button("UNGATE##iwc_sw" .. i) then mine.ids[key] = nil; _save_swings() end
        else
            if imgui.button("GATE THIS##iwc_sw" .. i) then mine.ids[key] = true; _save_swings(); M.last = "gated swing " .. key end
        end
    end
    if next(mine.ids) then
        local gated = {}
        for k in pairs(mine.ids) do gated[#gated + 1] = k end
        imgui.text("gated swings: " .. table.concat(gated, ", "))
    else
        imgui.text("no swings gated yet - the gate is dormant until you capture one")
    end
    imgui.text("")
    imgui.text("-- CHIP EFFECT LAB: pick, scale, TEST at your feet, then assign per material --")
    local labels = {}
    for _, o in ipairs(CHIP_FX_OPTIONS) do labels[#labels + 1] = o.label end
    local ec
    ec, M.chip_fx_idx = imgui.combo("effect##iwc_fx", M.chip_fx_idx, labels)
    ec, M.chip_scale = imgui.slider_float("chip fx scale##iwc_fx", M.chip_scale or 1.0, 0.1, 3.0)
    local sel = CHIP_FX_OPTIONS[M.chip_fx_idx] or CHIP_FX_OPTIONS[1]
    if imgui.button("TEST AT MY FEET##iwc_fx") then
        pcall(function()
            local rp = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer"):call("get_GameObject"):call("get_Transform"):call("get_Position")
            _spawn_chip_fx(rp.x, rp.y + 1.0, rp.z, sel.path)
        end)
    end
    imgui.same_line()
    if imgui.button("SET FOR TREES##iwc_fx") then M.chip_efx_tree = sel.path; M.last = "tree chips = " .. sel.label end
    imgui.same_line()
    if imgui.button("SET FOR STONE##iwc_fx") then M.chip_efx_stone = sel.path; M.last = "stone chips = " .. sel.label end
    local function _fx_label(path)
        for _, o in ipairs(CHIP_FX_OPTIONS) do if o.path == path then return o.label end end
        return "?"
    end
    imgui.text("trees: " .. _fx_label(M.chip_efx_tree) .. "   stone: " .. _fx_label(M.chip_efx_stone))
    imgui.text("")
    imgui.text("-- SOUND SNIFFER: arm, whack a wooden barrel/crate, REPLAY what fired, SET the winner --")
    local sniffing = os.clock() < sniffer.until_t
    if imgui.button(sniffing and ("SNIFFING... " .. math.ceil(sniffer.until_t - os.clock()) .. "s##iwc_snf") or "ARM SNIFFER (10s)##iwc_snf") then
        _install_sniffer_hooks()   -- hooks exist only from the first arm onward (the load-in AV law)
        sniffer.until_t = os.clock() + 10.0
        sniffer.events = {}
    end
    imgui.same_line()
    if sniffing and imgui.button("STOP##iwc_snf") then sniffer.until_t = 0 end
    if not sniffing then imgui.same_line(); if imgui.button("CLEAR LIST##iwc_snf") then sniffer.events = {} end end
    for i, ev in ipairs(sniffer.events) do
        imgui.text(string.format("  %d  x%d  (%s)", ev.id, ev.n or 1, ev.tgt))
        imgui.same_line()
        if imgui.button("REPLAY##iwc_snf" .. i) then
            local pgo
            pcall(function() pgo = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer"):call("get_GameObject") end)
            local ok, detail = _sniff_replay(ev, pgo)
            M.last = "replay " .. ev.id .. ": " .. tostring(detail)
        end
        imgui.same_line()
        if imgui.button("SET AS CHOP##iwc_snfs" .. i) then
            M.chop_raw_id = ev.id
            sound_lab.chop_raw = ev
            _save_swings()
            M.last = "chop sound = raw trigger " .. ev.id
        end
        imgui.same_line()
        if imgui.button("SET AS FELL##iwc_snff" .. i) then
            sound_lab.fell_raw = ev
            M.fell_raw_id = ev.id
            _save_swings()
            M.last = "wild-fell sound = trigger " .. ev.id .. " (persistent)"
        end
    end
    imgui.text("chop sound id: " .. tostring(M.chop_raw_id or "(none)"))
    imgui.same_line()
    if imgui.button("TEST CHOP SOUND##iwc_snd2") then
        _arm_chop_sound()
        if sound_lab.chop_trigger then
            local pgo
            pcall(function() pgo = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer"):call("get_GameObject") end)
            M.last = "chop sound posted: " .. tostring(_snd_post(sound_lab.chop_trigger, pgo))
        else
            M.last = "chop sound NOT armed - see woodcut_log"
        end
    end
    imgui.text("-- SOUND LAB (older lane): step the WOOD_DMG bank triggers --")
    if imgui.button("TEST NEXT WOOD SOUND##iwc_snd") then
        if _snd_load_triggers() then
            sound_lab.idx = (sound_lab.idx % #sound_lab.triggers) + 1
            local tr = sound_lab.triggers[sound_lab.idx]
            local pgo
            pcall(function() pgo = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer"):call("get_GameObject") end)
            local posted = _snd_post(tr, pgo)
            M.last = string.format("wood sound %d/%d (id %s) posted=%s", sound_lab.idx, #sound_lab.triggers, tostring(tr.id), tostring(posted))
        else
            M.last = "WOOD_DMG trigger list failed to load"
        end
    end
    imgui.same_line()
    if imgui.button("SET AS CHOP SOUND##iwc_snd") and sound_lab.triggers and sound_lab.idx > 0 then
        sound_lab.chop_trigger = sound_lab.triggers[sound_lab.idx]
        M.chop_se_id = sound_lab.chop_trigger.id
        _save_swings()
        M.last = "chop sound = trigger " .. tostring(M.chop_se_id)
    end
    imgui.text("chop sound: " .. (sound_lab.chop_trigger and tostring(sound_lab.chop_trigger.id) or (M.chop_se_id and ("saved id " .. tostring(M.chop_se_id) .. " (re-arms on first chip)") or "(none yet)")))
    imgui.text("")
    imgui.text("-- ICON LAB: preview vanilla icon numbers on OUR items (check inventory after apply) --")
    if M.icon_probe == nil then M.icon_probe = 0 end
    local ic
    ic, M.icon_probe = imgui.drag_int("icon no##iwc_icon", M.icon_probe, 1, 0, 65535)
    for _, step in ipairs({ 1, 10, 100 }) do
        if imgui.button("-" .. step .. "##iwc_icn") then M.icon_probe = math.max(0, M.icon_probe - step) end
        imgui.same_line()
        if imgui.button("+" .. step .. "##iwc_icp") then M.icon_probe = M.icon_probe + step end
        imgui.same_line()
    end
    imgui.text("")
    for _, it in ipairs({ { id = 34710, nm = "Stone" }, { id = 34711, nm = "Timber" }, { id = 34700, nm = "Pickaxe" }, { id = 34712, nm = "Woodaxe" } }) do
        if imgui.button("APPLY to " .. it.nm .. "##iwc_icon" .. it.id) then
            local okI = pcall(function()
                local im = sdk.get_managed_singleton("app.ItemManager")
                local p
                pcall(function() p = im:call("getItemData(System.Int32)", it.id) end)
                if not p then p = im:call("getItemParam(System.Int32)", it.id) end
                p:set_field("_IconNo", M.icon_probe)
            end)
            M.last = okI and (it.nm .. " icon -> " .. M.icon_probe .. " (open inventory to see)") or (it.nm .. ": icon apply failed")
        end
        imgui.same_line()
    end
    imgui.text("")
    imgui.text("")
    imgui.text("-- QUARRY: minable rocks ring the homestead plot (auto with the house) --")
    local qc
    qc, M.quarry_count = imgui.slider_int("rocks##iwc_q", M.quarry_count, 1, 8)
    qc, M.quarry_radius = imgui.slider_float("distance from plot (m)##iwc_q", M.quarry_radius, 4.0, 20.0)
    qc, M.quarry_cluster = imgui.checkbox("outcrop (tight group) instead of a ring##iwc_q", M.quarry_cluster)
    imgui.text("smashed rocks renew at the next in-game day (the vein rests)")
    if imgui.button("SPAWN TEST QUARRY (around you)##iwc_q") then
        pcall(function()
            local tf = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer"):call("get_GameObject"):call("get_Transform")
            local up
            pcall(function() up = tf:call("get_UniversalPosition") end)
            if not up then up = tf:call("get_Position") end
            _quarry_spawn(up.x, up.y, up.z)
            M.last = "quarry ring requested - rocks land in a few seconds"
        end)
    end
    imgui.same_line()
    if imgui.button("DESPAWN QUARRY##iwc_q") then _quarry_despawn(); M.last = "quarry cleared" end
    imgui.same_line()
    imgui.text("standing: " .. tostring(#quarry.rocks))
    -- generic gimmick tester (the annex-shed hunt: is the real shed gimmick gm04_013?)
    if M.test_gimmick == nil then M.test_gimmick = "Gm04_013" end
    local gc, gv = imgui.input_text("test gimmick id##iwc_tg", M.test_gimmick)
    if gc then M.test_gimmick = gv end
    imgui.same_line()
    if imgui.button("SPAWN 6m AHEAD##iwc_tg") then
        pcall(function()
            local tf = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer"):call("get_GameObject"):call("get_Transform")
            local up
            pcall(function() up = tf:call("get_UniversalPosition") end)
            if not up then up = tf:call("get_Position") end
            local f = tf:call("get_AxisZ")
            local gid
            pcall(function()
                local fld = sdk.find_type_definition("app.GimmickID"):get_field(M.test_gimmick)
                if fld then gid = fld:get_data() end
            end)
            if not gid then M.last = "GimmickID '" .. M.test_gimmick .. "' not in the enum"; return end
            quarry.jobs[#quarry.jobs + 1] = {
                x = up.x + f.x * 6.0, y = up.y, z = up.z + f.z * 6.0,
                gid = gid, stage = "prefab", f = 0,
                path_override = "AppSystem/gimmick/prefab/" .. M.test_gimmick:lower() .. ".pfb",
            }
            M.last = "test gimmick " .. M.test_gimmick .. " requested 6m ahead"
        end)
    end
    imgui.text("")
    imgui.text("-- TOOL MESH AUDITION: find the game's real axe + pickaxe (screenshot the winners) --")
    if imgui.button("< PREV##iwc_tm") then
        M.preview_idx = M.preview_idx > 1 and (M.preview_idx - 1) or #EQIT_IDS; _preview_spawn()
    end
    imgui.same_line()
    if imgui.button("NEXT >##iwc_tm") then
        M.preview_idx = M.preview_idx < #EQIT_IDS and (M.preview_idx + 1) or 1; _preview_spawn()
    end
    imgui.same_line()
    if imgui.button("SHOW##iwc_tm") then _preview_spawn() end
    imgui.same_line()
    if imgui.button("DESPAWN##iwc_tm") then _preview_despawn(); M.last = "preview despawned" end
    imgui.same_line()
    if imgui.button("TEST IRIS PICKAXE PFB##iwc_tm") then
        -- decides pak-side vs CE-side: floats our forged pickaxe if patch_045 mounted + pfb loads
        _preview_spawn("iris/tools/iris_pickaxe.pfb", "iris_pickaxe")
    end
    -- pfb load BISECT ladder: control (house pfb, loads every session) -> untouched copy at our
    -- path (is the LOCATION the problem?) -> mesh-only swap (is the custom MDF2 path the poison?)
    if imgui.button("TEST: house pfb (control)##iwc_tm") then
        _preview_spawn("iris/homestead/iris_house_sm62_033_00.pfb", "house_control")
    end
    imgui.same_line()
    if imgui.button("TEST: untouched sword copy##iwc_tm") then
        _preview_spawn("iris/tools/iris_sword_copy.pfb", "sword_copy")
    end
    imgui.same_line()
    if imgui.button("TEST: mesh-only variant##iwc_tm") then
        _preview_spawn("iris/tools/iris_pickaxe_a.pfb", "pickaxe_a")
    end
    imgui.same_line()
    if imgui.button("TEST: VANILLA wp02 at home path##iwc_tm") then
        -- calibrates the harness itself: if even the vanilla greatsword at its REAL pak path fails,
        -- weapon pfbs just can't load through this lane (their clsp/sound/VFX refs need the equip
        -- machinery) and the button says nothing about CE's ability to equip them
        _preview_spawn("appsystem/equipment/wp/wp02/prefab/wp02_000_00.pfb", "vanilla_wp02")
    end
    -- label the current item (persists to IRIS/eqit_labels.json - Aurora's tool catalogue)
    local cur = EQIT_IDS[M.preview_idx] or "?"
    imgui.text("current: " .. cur .. "  =  " .. (eqit_labels[cur] or "(unlabeled)"))
    local lc, lv = imgui.input_text("label##iwc_lbl", M.label_buf)
    if lc then M.label_buf = lv end
    imgui.same_line()
    if imgui.button("SAVE LABEL##iwc_lbl") and M.label_buf ~= "" then
        eqit_labels[cur] = M.label_buf
        _save_labels()
        M.last = "labeled " .. cur .. " = " .. M.label_buf
        M.label_buf = ""
    end
    if imgui.tree_node("labeled so far##iwc_lbls") then
        for _, id in ipairs(EQIT_IDS) do
            if eqit_labels[id] then imgui.text("  " .. id .. "  =  " .. eqit_labels[id]) end
        end
        imgui.tree_pop()
    end
    imgui.tree_pop()
end)

return M
