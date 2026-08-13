-- !IrisAimProbe.lua - THE HOE-HOMING OBSERVER (08-13)
-- The auto-aim at homestead residents survived: damage flags + HitController off +
-- LockOnTarget off + rel-hook FRIEND answers. We are done guessing which lever the
-- swing homing reads - this dumps the actual component inventory (player + nearest
-- resident + one wild control body) filtered to targeting-flavored names, so the
-- next session can hook/disable the REAL handle by name.
-- Usage: stand next to the aim-grabbing animal, open "IRIS - Aim Probe", click DUMP.
-- Output: reframework/data/IRIS/aim_probe.txt (append) + the same in the REF log.

local OUT = "IRIS/aim_probe.txt"
local KEYS = { "target", "lockon", "lock_on", "aim", "track", "hate", "attract",
               "sensor", "focus", "homing", "orbit", "select", "combat", "enemy" }

local function interesting(tn)
    local l = tn:lower()
    for _, k in ipairs(KEYS) do
        if l:find(k, 1, true) then return true end
    end
    return false
end

local function wline(fh, s)
    fh:write(s .. "\n")
    pcall(function() log.info("[AimProbe] " .. s) end)
end

local function dump_go(fh, label, go)
    if not go then wline(fh, label .. ": <none found>"); return end
    local name = "?"
    pcall(function() name = tostring(go:call("get_Name")) end)
    wline(fh, "== " .. label .. " (" .. name .. ") ==")
    pcall(function()
        local comps = go:call("get_Components")
        for _, c in ipairs(comps and comps:get_elements() or {}) do
            pcall(function()
                local tn = c:get_type_definition():get_full_name()
                if interesting(tn) then
                    local en = "?"
                    pcall(function() en = tostring(c:call("get_Enabled")) end)
                    wline(fh, "  " .. tn .. "  enabled=" .. en)
                end
            end)
        end
    end)
end

local function player_go()
    local go
    pcall(function()
        go = sdk.get_managed_singleton("app.CharacterManager")
            :call("get_ManualPlayer"):call("get_GameObject")
    end)
    return go
end

-- nearest ch2992xx body split into resident (shielded) vs wild (control): the DIFF
-- between the two lists is the shortlist of what makes a resident aim-sticky
local function nearest_animals()
    local res_go, wild_go, res_d, wild_d = nil, nil, 1e9, 1e9
    pcall(function()
        local pgo = player_go()
        local pp = pgo:call("get_Transform"):call("get_Position")
        local ra = rawget(_G, "IrisResidentChAddrs") or {}
        local scene = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),
            sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        local comps = scene:call("findComponents(System.Type)", sdk.typeof("app.Character"))
        local n = 0
        pcall(function() n = comps:call("get_Length") or 0 end)
        if n == 0 then pcall(function() n = comps:get_size() or 0 end) end
        for i = 0, (tonumber(n) or 0) - 1 do
            pcall(function()
                local ch
                pcall(function() ch = comps:call("get_Item", i) end)
                if not ch then pcall(function() ch = comps:get_element(i) end) end
                local go = ch and ch:call("get_GameObject")
                local nm = go and tostring(go:call("get_Name") or "")
                if not nm:find("ch299", 1, true) then return end
                local p = go:call("get_Transform"):call("get_Position")
                local dx, dz = p.x - pp.x, p.z - pp.z
                local d2 = dx * dx + dz * dz
                if d2 > 40.0 * 40.0 then return end
                if ra[ch:get_address()] then
                    if d2 < res_d then res_d, res_go = d2, go end
                else
                    if d2 < wild_d then wild_d, wild_go = d2, go end
                end
            end)
        end
    end)
    return res_go, wild_go
end

-- ── PLAYER-SIDE A/B (08-13 round 9): every targeting component on the RESIDENT is
-- now provably disabled and the hoe still homes - so the handle is on the PLAYER.
-- The dump's three enabled player suspects each get a kill-toggle; re-asserted every
-- frame while checked, restored on uncheck. Swing the hoe with one on at a time -
-- whichever checkbox heals the hoe names the homing's true owner.
local AB = { list = {
    { key = "sensor", type = "via.physics.SensorTarget", on = false },
    { key = "hate",   type = "app.HateSystem",           on = false },
    { key = "aimthrow", type = "app.EPVExpertAimThrow",  on = false },
} }
re.on_frame(function()
    pcall(function()
        local go = player_go()
        if not go then return end
        for _, s in ipairs(AB.list) do
            local c = go:call("getComponent(System.Type)", sdk.typeof(s.type))
            if c then
                if s.on then
                    pcall(function() c:call("set_Enabled", false) end)
                elseif s.was_on then
                    pcall(function() c:call("set_Enabled", true) end)
                end
            end
            s.was_on = s.on
        end
    end)
end)

local last = "no dump yet"
re.on_draw_ui(function()
    if imgui.collapsing_header("IRIS - Aim Probe") then
        imgui.text("PLAYER-side suspects - tick ONE, swing the hoe, untick:")
        for _, s in ipairs(AB.list) do
            local ch, v = imgui.checkbox("kill player " .. s.type, s.on)
            if ch then s.on = v end
        end
        imgui.separator()
        if imgui.button("DUMP targeting components (player + resident + wild)") then
            local ok, err = pcall(function()
                local fh = io.open(OUT, "a")
                if not fh then error("cannot open " .. OUT) end
                wline(fh, "")
                wline(fh, "──── DUMP " .. os.date("%H:%M:%S") .. " ────")
                dump_go(fh, "PLAYER", player_go())
                local res_go, wild_go = nearest_animals()
                dump_go(fh, "RESIDENT (shielded - the aim magnet)", res_go)
                dump_go(fh, "WILD ch299 (control - aim behaves)", wild_go)
                fh:close()
            end)
            last = ok and ("dumped to " .. OUT) or ("FAILED: " .. tostring(err))
        end
        imgui.text(last)
        imgui.text("Stand near the aim-grabbing animal, DUMP, then swing the hoe")
        imgui.text("once and DUMP again - the diff names the homing's handle.")
    end
end)
