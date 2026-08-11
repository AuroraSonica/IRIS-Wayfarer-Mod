-- IrisSurgeTape.lua -- ⏱ TEMPORARY PROBE (2026-08-07, Aurora: "put a
-- probe on my warrior surging strike and copy the physics from that
-- hit"). Tapes the FULL DamageInfo + AttackUserData of every REAL hit
-- the PLAYER lands (calcDamageReaction, the function every genuine
-- knockback flows through -- Bestiary/DamageTracer's proven hook
-- point). The blow parameters live in app.AttackUserData on the
-- attacking collider/shell (DamageTypeBlown, _BlowValue, HitBackDir,
-- ForceType/Factor, RagdollFactor -- the 07-10 Fable trace), which is
-- exactly what the horse kick needs to replicate.
-- ⛔ DELETE THIS FILE once the kick ships. Grep the log for [SurgeTape].

-- ⛔ DISABLED 2026-08-09. The kick HAS shipped, so per this file's own header this probe
-- should already be gone. Left in place (not deleted) only because it is trivially
-- re-armable if the blow parameters are ever needed again -- flip this to true.
-- WHY OFF NOW, beyond the header: it hooks calcDamageReaction and reflection-walks ~138
-- fields off a LIVE DamageInfo per hit, dereferencing userdata as it goes. Those objects
-- are transient/pooled, so a full field walk inside the reaction hook is a real AV
-- surface -- and it logged in the frames immediately before both 08-09 mount crashes.
-- It also writes ~138 log lines per landed hit, which is not free during combat.
local ENABLED = false

local function tape_log(msg)
    pcall(function() log.info("[SurgeTape] " .. tostring(msg)) end)
end

-- one compact block per hit, throttled so a flurry doesn't flood
local last_tape = 0.0

local function dump_fields(obj, label, lines, deep_names)
    local ok = pcall(function()
        local td = obj:get_type_definition()
        local count = 0
        while td and count < 120 do
            for _, f in ipairs(td:get_fields()) do
                count = count + 1
                local name = f:get_name()
                local okv, v = pcall(function()
                    return obj:get_field(name)
                end)
                if okv and v ~= nil then
                    local tv = type(v)
                    if tv == "number" or tv == "boolean"
                        or tv == "string" then
                        lines[#lines + 1] = string.format(
                            "%s.%s = %s", label, name, tostring(v))
                    elseif tv == "userdata" then
                        -- vector-ish?
                        local okx, x = pcall(function() return v.x end)
                        if okx and type(x) == "number" then
                            local y2, z2 = 0.0, 0.0
                            pcall(function()
                                y2 = tonumber(v.y) or 0.0
                                z2 = tonumber(v.z) or 0.0
                            end)
                            lines[#lines + 1] = string.format(
                                "%s.%s = (%.3f, %.3f, %.3f)",
                                label, name, x, y2, z2)
                        elseif deep_names and deep_names[name] then
                            -- one recursion level for the attack data
                            dump_fields(v, label .. "." .. name,
                                lines, nil)
                        end
                    end
                end
            end
            td = td:get_parent_type()
        end
    end)
    if not ok then
        lines[#lines + 1] = label .. " = <dump failed>"
    end
end

pcall(function()
    local m = sdk.find_type_definition("app.HitController")
        :get_method("calcDamageReaction(app.HitController.DamageInfo)")
    if not m then
        tape_log("calcDamageReaction method NOT FOUND -- tape dead")
        return
    end
    sdk.hook(m, function(args)
        if not ENABLED then return end
        pcall(function()
            local now = os.clock()
            if now - last_tape < 0.30 then return end
            local di = sdk.to_managed_object(args[3])
            if not di then return end
            local ahc = di["<AttackHitController>k__BackingField"]
            if not ahc then return end
            local attacker = nil
            local shell = nil
            pcall(function()
                shell = ahc["<CachedShell>k__BackingField"]
            end)
            if shell then
                pcall(function()
                    attacker = shell["<OwnerCharacter>k__BackingField"]
                end)
            end
            if not attacker then
                pcall(function()
                    attacker = ahc["<CachedCharacter>k__BackingField"]
                end)
            end
            if not attacker then return end
            local aid = ""
            pcall(function()
                aid = tostring(attacker:call("get_CharaIDString"))
            end)
            -- PLAYER hits only (ch0xx = Arisen; pawns are ch1xx)
            if not aid:match("^ch0") then return end
            last_tape = now
            local victim_name = "?"
            pcall(function()
                local dhc = di["<DamageHitController>k__BackingField"]
                local vch = dhc
                    and dhc["<CachedCharacter>k__BackingField"]
                victim_name = tostring(
                    vch:call("get_CharaIDString"))
            end)
            local lines = {}
            lines[#lines + 1] = string.format(
                "==== PLAYER HIT (%s -> %s, shell=%s) ====",
                aid, victim_name, tostring(shell ~= nil))
            -- the DamageInfo itself, one level deep into the attack data
            dump_fields(di, "DI", lines, {
                ["<AttackUserData>k__BackingField"] = true,
                ["AttackUserData"] = true,
                ["<AttackData>k__BackingField"] = true,
                ["_AttackUserData"] = true,
            })
            -- the AttackUserData may hang off the attack HitController
            -- rather than the info -- try there too
            pcall(function()
                local aud = ahc["<AttackUserData>k__BackingField"]
                if aud then
                    dump_fields(aud, "AHC.AttackUserData", lines, nil)
                end
            end)
            for _, l in ipairs(lines) do tape_log(l) end
            tape_log(string.format("==== END (%d fields) ====", #lines))
        end)
    end, function(retval) return retval end)
    tape_log("armed -- land a Surging Strike and grep [SurgeTape]")
end)
