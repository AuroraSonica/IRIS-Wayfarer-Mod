-- Low-level keyboard/gamepad input reader for the shared I.R.I.S. mount engine.
-- Action dispatch remains in the legacy entry point during this extraction.

local M = {}

function M.new(options)
    options = options or {}
    local C = options.config or {}
    local S = options.state or {}
    local sdk = options.sdk
    local get_player = options.get_player
    local iris_kb = options.keyboard
    local function iris_input_blocked()
        return type(options.input_blocked) == "function"
            and options.input_blocked() == true
    end

    local function get_player_input()
        local input = nil
        pcall(function() input = get_player():call("get_Input") end)
        if not input then pcall(function() input = get_player():get_Input() end) end
        return input
    end

    local function get_player_input_processor()
        local player = get_player()
        local input_processor = nil
        pcall(function() input_processor = player and player:get_field("InputProcessor") end)
        if not input_processor then pcall(function() input_processor = player and player:get_field("<InputProcessor>k__BackingField") end) end
        if not input_processor then pcall(function() input_processor = player and player:call("get_InputProcessor") end) end
        if not input_processor then
            local input = get_player_input()
            pcall(function() input_processor = input and input:get_field("InputProcessor") end)
            if not input_processor then pcall(function() input_processor = input and input:get_field("<InputProcessor>k__BackingField") end) end
        end
        return input_processor
    end

    local function axis_magnitude(x, z)
        return math.abs(tonumber(x) or 0.0) + math.abs(tonumber(z) or 0.0)
    end

    local function read_keyboard_axis()
        local x, z = 0.0, 0.0
        pcall(function()
            if iris_kb(0x41) then x = x - 1.0 end -- A
            if iris_kb(0x44) then x = x + 1.0 end -- D
            if iris_kb(0x57) then z = z + 1.0 end -- W
            if iris_kb(0x53) then z = z - 1.0 end -- S
        end)
        if x ~= 0.0 and z ~= 0.0 then
            -- normalise diagonals so W+A is not ~41% faster than W
            x, z = x * 0.70710678, z * 0.70710678
        end
        return x, z
    end

    local function griffin_apply_axis_deadzone(x, z, dz)
        x, z = tonumber(x) or 0.0, tonumber(z) or 0.0
        dz = math.min(0.9, math.max(0.0, tonumber(dz) or 0.15))
        if dz <= 0.0 then return x, z end
        local mag = math.sqrt(x * x + z * z)
        if mag <= dz then return 0.0, 0.0 end
        -- rescale so output still spans 0..1 smoothly above the deadzone
        local scale = math.min(1.0, (mag - dz) / math.max(0.0001, 1.0 - dz)) / mag
        return x * scale, z * scale
    end

    local function raw_gamepad_device()
        local dev = nil
        S.last_raw_device = "(none)"
        pcall(function()
            local gp = sdk.get_native_singleton("via.hid.GamePad")
            local td = sdk.find_type_definition("via.hid.GamePad")
            if gp and td then
                pcall(function() dev = sdk.call_native_func(gp, td, "get_MergedDevice"); if dev then S.last_raw_device = "get_MergedDevice" end end)
                if not dev then pcall(function() dev = sdk.call_native_func(gp, td, "getMergedDevice(System.UInt32)", 0); if dev then S.last_raw_device = "getMergedDevice(0)" end end) end
                if not dev then pcall(function() dev = sdk.call_native_func(gp, td, "get_Device"); if dev then S.last_raw_device = "get_Device" end end) end
            end
        end)
        return dev
    end

    local gamepad_button_cache = nil
    local function gamepad_button_value(name)
        local text = tostring(name or "")
        local direct = tonumber(text)
        if direct then return direct end
        local hex = text:match("^0[xX]([0-9a-fA-F]+)$")
        if hex then return tonumber(hex, 16) or 0 end
        local alias = {
            l3 = 0x1000, leftstick = 0x1000, lstick = 0x1000, ls = 0x1000,
            r3 = 0x2000, rightstick = 0x2000, rstick = 0x2000, rs = 0x2000,
            dup = 0x1, dpadup = 0x1, up = 0x1,
            ddown = 0x2, dpaddown = 0x2, down = 0x2,
            dleft = 0x4, dpadleft = 0x4, left = 0x4,
            dright = 0x8, dpadright = 0x8, right = 0x8,
            l1 = 0x100, lb = 0x100, leftbumper = 0x100,
            l2 = 0x200, lt = 0x200, lefttrigger = 0x200,
            r1 = 0x400, rb = 0x400, rightbumper = 0x400,
            r2 = 0x800, rt = 0x800, righttrigger = 0x800,
            triangle = 0x10, y = 0x10, north = 0x10,
            circle = 0x40080, b = 0x40080, east = 0x40080,
            x = 0x20020, cross = 0x20020, south = 0x20020,
            square = 0x40, west = 0x40,
        }
        local aliased = alias[text:lower()]
        if aliased then return aliased end

        if not gamepad_button_cache then
            gamepad_button_cache = {}
            pcall(function()
                local td = sdk.find_type_definition("via.hid.GamePadButton")
                if td then
                    for _, field in ipairs(td:get_fields()) do
                        local n = field:get_name()
                        local v = tonumber(field:get_data(nil)) or 0
                        gamepad_button_cache[n:lower()] = v
                    end
                end
            end)
        end
        return gamepad_button_cache[text:lower()] or 0
    end

    local function raw_gamepad_button_down(names)
        -- 08-18 (Aurora: map open -> A still fired the loop-the-loop -> CTD on
        -- unpause): menus own the pad. The shared gate (000IrisInputGate) now
        -- also covers the game's own pausing GUIs.
        if type(iris_input_blocked) == "function" and iris_input_blocked() then
            S.last_raw_button_mask = 0
            return false
        end
        local dev = raw_gamepad_device()
        S.last_raw_button_mask = 0
        if not dev then return false end
        local mask = 0
        pcall(function() mask = tonumber(dev:call("get_Button")) or 0 end)
        mask = math.floor(tonumber(mask) or 0)
        S.last_raw_button_mask = mask
        if mask == 0 then return false end
        for raw in tostring(names or ""):gmatch("[^,%s]+") do
            local bit = math.floor(tonumber(gamepad_button_value(raw)) or 0)
            if bit ~= 0 then
                local hit = false
                pcall(function() hit = (mask & bit) ~= 0 end)
                if hit then return true end
            end
        end
        return false
    end

    local function raw_gamepad_mask_down(bind_mask)
        -- 08-18: same menu gate as raw_gamepad_button_down (this reads the
        -- cached mask, which that function zeroes while blocked -- the explicit
        -- check makes the block hold even if call order changes).
        if type(iris_input_blocked) == "function" and iris_input_blocked() then
            return false
        end
        local mask = math.floor(tonumber(S.last_raw_button_mask) or 0)
        local bind = math.floor(tonumber(bind_mask) or 0)
        if bind <= 0 or mask <= 0 then return false end
        local hit = false
        pcall(function() hit = (mask & bind) ~= 0 end)
        return hit == true
    end

    local function keyboard_shift_down()
        local down = false
        pcall(function()
            down = iris_kb(0x10) or iris_kb(0xA0) or iris_kb(0xA1)
        end)
        return down == true
    end

    local function vec_axis(v)
        if not v then return nil, nil end
        local x, y, z = nil, nil, nil
        pcall(function() x = tonumber(v.x) end)
        pcall(function() y = tonumber(v.y) end)
        pcall(function() z = tonumber(v.z) end)
        if x ~= nil and z ~= nil then return x, z end
        if x ~= nil and y ~= nil then return x, -y end
        return nil, nil
    end

    local function read_raw_gamepad_axis()
        -- 08-18: the map cursor and flight steering share the stick -- no
        -- steering input while a pausing GUI or the overlay is up.
        if type(iris_input_blocked) == "function" and iris_input_blocked() then
            S.last_raw_axis_method = "(ui blocked)"
            return nil, nil
        end
        local dev = raw_gamepad_device()
        S.last_raw_axis_method = "(none)"
        local methods = {
            "get_AxisL", "get_DirectionL", "get_AxisLeft", "get_LStick", "get_LeftStick",
            "get_LStickAxis", "get_LeftStickAxis", "get_AnalogL", "get_LeftAnalog",
            "get_AnalogStickL", "get_LeftAnalogStick", "get_StickL",
        }
        if dev then
            for _, method in ipairs(methods) do
                local v = nil
                pcall(function() v = dev:call(method) end)
                if not v then pcall(function() v = dev[method] and dev[method](dev) end) end
                local x, z = vec_axis(v)
                if x ~= nil and z ~= nil and axis_magnitude(x, z) > 0.01 then
                    S.last_raw_axis_method = method
                    return x, z
                end
            end
        end

        local gp_axis_x, gp_axis_z, gp_method = nil, nil, nil
        pcall(function()
            local gp = sdk.get_native_singleton("via.hid.GamePad")
            local td = sdk.find_type_definition("via.hid.GamePad")
            if not (gp and td) then return end
            for _, method in ipairs(methods) do
                if gp_axis_x ~= nil then break end
                local v = nil
                pcall(function() v = sdk.call_native_func(gp, td, method) end)
                local x, z = vec_axis(v)
                if x ~= nil and z ~= nil and axis_magnitude(x, z) > 0.01 then
                    gp_axis_x, gp_axis_z, gp_method = x, z, "GamePad." .. method
                end
            end
        end)
        if gp_axis_x ~= nil then
            S.last_raw_axis_method = gp_method or "GamePad"
            return gp_axis_x, gp_axis_z
        end

        if not dev then
            S.last_raw_axis_method = "(no device)"
        end
        return 0.0, 0.0
    end

    local function read_axis()
        local input = get_player_input()
        local dir = nil
        if input then
            pcall(function() dir = input:call("get_DirectionL") end)
            if not dir then pcall(function() dir = input:get_DirectionL() end) end
        end
        local char_x = dir and tonumber(dir.x) or 0.0
        local char_z = dir and tonumber(dir.z) or 0.0
        local key_x, key_z = read_keyboard_axis()
        local raw_x, raw_z = read_raw_gamepad_axis()
        raw_x, raw_z = griffin_apply_axis_deadzone(raw_x, raw_z, C.raw_axis_deadzone)

        local x, z = char_x, char_z
        S.last_axis_source = "character"
        if tostring(C.input_axis_source or "auto") == "keyboard" then
            x, z = key_x, key_z
            S.last_axis_source = "keyboard"
        elseif tostring(C.input_axis_source or "auto") == "raw" then
            x, z = raw_x, raw_z
            S.last_axis_source = "raw"
        elseif axis_magnitude(x, z) <= 0.01 and axis_magnitude(key_x, key_z) > 0.01 then
            x, z = key_x, key_z
            S.last_axis_source = "keyboard"
        elseif axis_magnitude(x, z) <= 0.01 and axis_magnitude(raw_x, raw_z) > 0.01 then
            x, z = raw_x, raw_z
            S.last_axis_source = "raw"
        end

        S.last_char_axis_x, S.last_char_axis_z = char_x, char_z
        S.last_raw_axis_x, S.last_raw_axis_z = raw_x, raw_z
        if C.invert_forward then z = -z end
        return x, z, input
    end

    local function button_on(input, flag)
        if not (input and flag) then return false end
        local down = false
        pcall(function() down = input:call("isButtonOn", flag) end)
        if not down then pcall(function() down = input:isButtonOn(flag) end) end
        return down == true
    end

    return {
        get_player_input = get_player_input,
        get_player_input_processor = get_player_input_processor,
        axis_magnitude = axis_magnitude,
        read_keyboard_axis = read_keyboard_axis,
        apply_axis_deadzone = griffin_apply_axis_deadzone,
        raw_gamepad_device = raw_gamepad_device,
        gamepad_button_value = gamepad_button_value,
        raw_gamepad_button_down = raw_gamepad_button_down,
        raw_gamepad_mask_down = raw_gamepad_mask_down,
        keyboard_shift_down = keyboard_shift_down,
        vec_axis = vec_axis,
        read_raw_gamepad_axis = read_raw_gamepad_axis,
        read_axis = read_axis,
        button_on = button_on,
    }
end

return M
