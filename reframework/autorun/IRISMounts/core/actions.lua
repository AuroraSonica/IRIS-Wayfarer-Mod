-- Declarative mounted-action resolver for I.R.I.S. species adapters.
--
-- This layer decides what each input means, what the HUD should call it and
-- which registered handler owns a pressed slot. The proven implementations
-- remain in the legacy entry point while they cross this boundary incrementally.

local M = {}

M.buttons = { "Y", "X", "A", "B", "L1", "L2", "R1", "R2" }

-- Species adapters own their physical bindings, but the state machine which
-- consumes an input continues to own its edge/hold state.  This distinction is
-- deliberate: Griffin actions share buttons across ground/flight and several
-- readers must continue sampling while their action is not currently eligible.
function M.binding(adapter, action_id)
    local bindings = adapter and adapter.bindings or nil
    local binding = type(bindings) == "table" and bindings[tostring(action_id or "")] or nil
    return type(binding) == "table" and binding or nil
end

-- Resolve one adapter binding through caller-supplied readers.  Input policy
-- (mounted, airborne, cooldowns, edge detection and action lockouts) stays with
-- the proven caller; this helper only translates metadata into a held state.
function M.binding_down(adapter, C, action_id, readers)
    C = type(C) == "table" and C or {}
    readers = type(readers) == "table" and readers or {}
    local binding = M.binding(adapter, action_id)
    if not binding then return false, nil end

    local names = binding.buttons
    if binding.buttons_key then names = C[binding.buttons_key] end
    local compact = tostring(names or ""):gsub("%s+", "")
    if compact == "" and binding.blank_buttons ~= nil then
        names = binding.blank_buttons
        compact = tostring(names or ""):gsub("%s+", "")
    end

    local down = false
    if compact ~= "" and type(readers.gamepad) == "function" then
        local value = binding.compact_buttons == true and compact or names
        local ok, result = pcall(readers.gamepad, value)
        down = ok and result == true
    end

    if not down and type(readers.keyboard) == "function" then
        local raw_key = binding.key
        if binding.key_key then raw_key = C[binding.key_key] end
        if raw_key == nil then raw_key = binding.default_key end
        local key = math.floor(tonumber(raw_key) or 0)
        if key > 0 then
            local ok, result = pcall(readers.keyboard, key)
            down = ok and result == true
        end
    end

    return down, binding
end

local function resolve_value(value, C, S)
    if type(value) == "function" then return value(C, S) end
    return value
end

local function resolve_label(descriptor, C, S)
    if type(descriptor) ~= "table" then return nil end
    local label = resolve_value(descriptor.label, C, S)
    if descriptor.label_key then return C[descriptor.label_key] end
    return label
end

function M.descriptor(adapter, airborne, button)
    local actions = adapter and adapter.actions or {}
    local action_set = airborne == true and actions.air or actions.ground
    return type(action_set) == "table" and action_set[tostring(button or "")] or nil
end

function M.action_id(adapter, S, C, airborne, button)
    local descriptor = M.descriptor(adapter, airborne, button)
    if type(descriptor) ~= "table" then return nil, descriptor end
    local action_id = resolve_value(descriptor.id, C or {}, S or {})
    if action_id == nil or tostring(action_id) == "" then return nil, descriptor end
    return tostring(action_id), descriptor
end

-- Dispatches the first pressed button in an explicit priority order. Input
-- sampling and edge ownership stay with the caller: this layer only translates
-- a physical slot through the active species adapter and invokes the matching
-- proven handler.
function M.dispatch(adapter, S, C, airborne, pressed, handlers, order, context)
    pressed = type(pressed) == "table" and pressed or {}
    handlers = type(handlers) == "table" and handlers or {}
    for _, button in ipairs(order or M.buttons) do
        if pressed[button] == true then
            local action_id, descriptor = M.action_id(adapter, S, C, airborne, button)
            local handler = action_id and handlers[action_id] or nil
            if type(handler) == "function" then
                return true, handler(context or {}, descriptor, button), action_id, button
            end
            return false, nil, action_id, button
        end
    end
    return false, nil, nil, nil
end

function M.resolve(adapter, S, C, airborne)
    S, C = S or {}, C or {}
    airborne = airborne == true
    local actions = adapter and adapter.actions or {}
    local labels = {}

    for _, button in ipairs(M.buttons) do
        local descriptor = M.descriptor(adapter, airborne, button)
        labels[button] = resolve_label(descriptor, C, S)
        if labels[button] == nil then
            labels[button] = C[(airborne and "route3_hud_" or "route3_hudg_") .. button]
        end
    end

    local charge_ready = not airborne and actions.charge_override == true
        and C.route3_charge_enabled ~= false
        and S.last_character_root_move_run == true
        and (tonumber(S.last_character_root_forward) or 0.0) > 0.25
    if charge_ready then labels.Y = tostring(C.route3_hudg_Y_charge or "Charge") end

    local carrying = (type(S.route3_grab) == "table" and S.route3_grab.carried ~= nil)
        or S.route3_predation_carry_active == true
    if carrying and actions.carrying_override ~= false then
        if tostring(C.route3_hud_Y_carrying or "") ~= "" then labels.Y = C.route3_hud_Y_carrying end
        if tostring(C.route3_hud_X_carrying or "") ~= "" then labels.X = C.route3_hud_X_carrying end
    end

    if not airborne and actions.ground_eat_override == true then
        if S.route3_ground_eat then labels.R2 = "Eating"
        elseif S.route3_ground_eat_ready then labels.R2 = "Eat" end
    end

    return labels, {
        charge_ready = charge_ready,
        carrying = carrying,
    }
end

return M
