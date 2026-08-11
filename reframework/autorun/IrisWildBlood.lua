-- I.R.I.S. -- WILD BLOOD (2026-08-11, v1)
-- Every wild creature of a tameable kind carries its genes BEFORE the tame (Aurora:
-- "I want to start running around and seeing creatures of varying sizes"). A throttled
-- sweep rolls IVs per wild INDIVIDUAL at first sight, applies the SIZE gene to the body
-- through the ONE genetics calculator (iris_size_mult_for -- shared with the companion
-- easer, so wild and tamed sizes can never disagree), and keeps re-asserting it gently
-- (some species' ScaleMediator stomps one-shot writes). When IrisTaming seals a bond,
-- GriffinRideProbe's tame_creature TAKES the wild roll -- the big one you scouted stays
-- the big one you tamed.
--
-- ⛔ RESPECT THE NEIGHBOURS:
--  * bodies whose current scale is far from 1.0 are NOT ours (Bestiary/Apex variants,
--    IrisWildHorses' 1.6 horses, wyrm-grown companions) -- skipped entirely;
--  * the ACTIVE companion body is the stable machinery's (is_companion_body);
--  * dead bodies are never rolled (corpse-scaling is nobody's fantasy).

local CFG = "IrisWildBlood.json"
local C = {
    enabled = true,
    radius = 150.0,        -- roll/apply within this range of the player
    sweep_secs = 2.0,      -- scene sweep throttle
    max_tracked = 128,     -- safety cap on the ledger
}
pcall(function()
    local d = json.load_file(CFG)
    if type(d) == "table" then for k, v in pairs(d) do if C[k] ~= nil then C[k] = v end end end
end)
local function save_cfg() pcall(function() json.dump_file(CFG, C) end) end

-- geneable wild bands (grow this list as new tames arrive)
local BANDS = {
    ch299200 = true, ch299210 = true,               -- rabbit, rat
    ch299400 = true, ch299410 = true, ch299430 = true, -- bat, crow, bird
    ch299220 = true, ch299221 = true,               -- fowl
    ch223000 = true, ch223001 = true,               -- wolf, puma/panther
    ch253000 = true,                                 -- griffin
    ch257000 = true, ch257001 = true,               -- drakes
    ch254000 = true, ch258000 = true,               -- chimera, wyvern band
    ch260000 = true,                                 -- garm
}

-- the ledger: GO addr -> { iv, base, want, name, at } -- session-only by design (wild
-- bodies do not persist; the roll that matters long-term rides the tame into the stable)
local W = _G.IrisWildBlood or {}
_G.IrisWildBlood = W
W.led = W.led or {}
W.count = W.count or 0

-- the tame carry: GriffinRideProbe calls take(go_addr) at the pact; returns the iv and
-- retires the entry so this module stops touching a body the stable now owns
W.take = function(addr)
    local e = addr and W.led[addr]
    if not e then return nil end
    W.led[addr] = nil
    pcall(function() log.info("[IrisWildBlood] genes carried into the tame: " .. tostring(e.name)) end)
    return e.iv
end

local function roll_iv()
    local iv = {}
    for _, k in ipairs({ "hp", "atk", "def", "spd", "size", "luck" }) do
        iv[k] = math.random(1, 30)
    end
    return iv
end

local function player_pos()
    local p = nil
    pcall(function()
        local pl = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
        local go = pl and pl:call("get_GameObject")
        p = go and go:call("get_Transform"):call("get_Position")
    end)
    return p
end

local sweep_at = 0.0
re.on_frame(function()
    if C.enabled == false then return end
    local now = os.clock()
    if now < sweep_at then return end
    sweep_at = now + math.max(0.5, tonumber(C.sweep_secs) or 2.0)
    pcall(function()
        local pp = player_pos()
        if not pp then return end
        local b = rawget(_G, "IrisGriffinBridge")
        local smgr = sdk.get_native_singleton("via.SceneManager")
        local scene = smgr and sdk.call_native_func(smgr, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        if not scene then return end
        local comps = scene:call("findComponents(System.Type)", sdk.typeof("app.Character"))
        local n = comps and (comps.get_size and comps:get_size() or #comps) or 0
        local seen = {}
        for i = 0, n - 1 do
            pcall(function()
                local ch = comps.get_element and comps:get_element(i) or comps[i]
                local go = ch and ch:call("get_GameObject")
                if not go then return end
                local nm = tostring(go:call("get_Name") or "")
                local band = nm:match("ch%d+")
                if not (band and BANDS[band]) then return end
                local tr = go:call("get_Transform")
                local p = tr:call("get_Position")
                local dx, dy, dz = p.x - pp.x, p.y - pp.y, p.z - pp.z
                if dx * dx + dy * dy + dz * dz > (C.radius or 150.0) ^ 2 then return end
                local addr = go:get_address()
                seen[addr] = true
                local e = W.led[addr]
                if not e then
                    -- new blood: never a corpse, never the stable's own body, never a
                    -- body some other system already scaled away from ~1.0
                    local dead = false
                    pcall(function() dead = ch:call("get_IsDead") == true end)
                    if dead then return end
                    if b and b.is_companion_body and b.is_companion_body(go) == true then return end
                    local cur = tr:call("get_LocalScale")
                    local cx = tonumber(cur and cur.x) or 1.0
                    if cx < 0.85 or cx > 1.15 then return end
                    if W.count >= (C.max_tracked or 128) then return end
                    local iv = roll_iv()
                    e = { iv = iv, base = cx, name = nm,
                        want = cx * (iris_size_mult_for and iris_size_mult_for(nm, iv.size, cx) or 1.0),
                        at = now }
                    W.led[addr] = e
                    W.count = W.count + 1
                    if math.abs(e.want - cx) > 0.1 then
                        pcall(function() log.info(string.format(
                            "[IrisWildBlood] %s rolled size %d -> x%.2f", nm, iv.size, e.want / e.base)) end)
                    end
                end
                -- gentle re-assert (ScaleMediator stomps one-shots on some species);
                -- the companion check repeats here so a mid-session tame stops us
                if b and b.is_companion_body and b.is_companion_body(go) == true then
                    W.led[addr] = nil
                    W.count = math.max(0, W.count - 1)
                    return
                end
                local cur = tr:call("get_LocalScale")
                local cx = tonumber(cur and cur.x) or e.want
                if math.abs(cx - e.want) > 0.02 then
                    tr:call("set_LocalScale", Vector3f.new(e.want, e.want, e.want))
                end
            end)
        end
        -- retire ledger entries whose bodies are gone/out of range (they re-roll only if
        -- truly a NEW body -- same body re-entering range keeps its entry until despawn)
        for addr, e in pairs(W.led) do
            if not seen[addr] and now - (tonumber(e.at) or 0.0) > 60.0 then
                W.led[addr] = nil
                W.count = math.max(0, W.count - 1)
            end
        end
    end)
end)

re.on_draw_ui(function()
    if imgui.tree_node("IRIS Wild Blood (wild creatures carry IVs)") then
        local ch, v
        ch, v = imgui.checkbox("enabled", C.enabled ~= false)
        if ch then C.enabled = v; save_cfg() end
        ch, v = imgui.slider_float("roll/apply radius (m)", tonumber(C.radius) or 150.0, 40.0, 300.0)
        if ch then C.radius = v; save_cfg() end
        imgui.text(string.format("wild creatures carrying genes: %d", tonumber(W.count) or 0))
        imgui.tree_pop()
    end
end)
