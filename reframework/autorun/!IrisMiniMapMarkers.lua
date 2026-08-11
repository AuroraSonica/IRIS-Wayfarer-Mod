-- IRIS homestead minimap markers -- dormant render-pool implementation
--
-- ui020301 owns a fixed pool of 50 MapIconRef controls. Native updateIcon()
-- populates the low slots and hides the unused remainder every refresh. We borrow
-- only controls which are still hidden AFTER that refresh. Nothing is added to
-- GuiManager, no managed icon records are allocated, and no UI reference survives
-- the hook call. This is intentionally isolated until it has survived streaming.

local TAG = "[IrisMiniMapMarkers] "
local LOG_FILE = "IRIS/minimap_marker_log.txt"
local ICON_TYPE_HOUSE = 22
local MAX_MARKERS = 8
local SIGN_TEXTURE = "iris/icons/iris_plotsign_icon.tex"

local stats = {
    calls = 0,
    shown = -1,
    last_slots = "",
    errors = 0,
}

pcall(function()
    local f = io.open(LOG_FILE, "w")
    if f then f:write(""); f:close() end
end)

local function note(message)
    message = tostring(message)
    log.info(TAG .. message)
    pcall(function()
        local f = io.open(LOG_FILE, "a")
        if f then
            f:write("[" .. os.date("%H:%M:%S") .. "] " .. message .. "\n")
            f:close()
        end
    end)
end

-- A texture resource holder is safe to retain with add_ref; unlike the map UI
-- controls, it is not owned by a streamed ui020301 instance.
local sign_resource, sign_holder = nil, nil
pcall(function()
    sign_resource = sdk.create_resource("via.render.TextureResource", SIGN_TEXTURE)
    if sign_resource then sign_resource:add_ref() end
    sign_holder = sign_resource and sign_resource:create_holder("via.render.TextureResourceHolder") or nil
    if sign_holder then sign_holder:add_ref() end
end)

-- Plain slot numbers only -- never managed UI references.
local last_custom_slots = {}

local function get_native_atlas(ui)
    local holder = nil
    pcall(function()
        local origin = ui and ui:get_field("MapIconOrigin")
        holder = origin and origin:call("getTexture") or nil
    end)
    return holder
end

local function set_icon_texture(icon, holder)
    if not (icon and holder) then return false end
    local changed = false
    pcall(function()
        local texture = icon:get_field("Tex")
        if not texture then return end
        texture:call("setTexture", holder)
        changed = true
    end)
    return changed
end

local function apply_custom_sign(icon)
    if not (icon and sign_holder) then return false end
    local changed = false
    pcall(function()
        local texture = icon:get_field("Tex")
        if not texture then return end
        texture:call("setTexture", sign_holder)
        -- The native glyph uses a small atlas window. Open that window to the
        -- whole custom 1024x1024 sign texture, exactly as the full-map marker does.
        texture:call("set_UVType", 0)
        texture:call("set_RectL", 0)
        texture:call("set_RectT", 0)
        texture:call("set_RectW", 1024)
        texture:call("set_RectH", 1024)
        texture:call("set_UVU", 0.0)
        texture:call("set_UVV", 0.0)
        texture:call("set_UVW", 1.0)
        texture:call("set_UVH", 1.0)
        changed = true
    end)
    return changed
end

local function restore_previous_custom_slots(ui)
    local slots = last_custom_slots
    last_custom_slots = {}
    if #slots == 0 or not ui then return end

    pcall(function()
        local atlas = get_native_atlas(ui)
        local list = ui:get_field("MapIconList")
        local count = list and tonumber(list:call("get_Count")) or 0
        if not (atlas and list and count > 0) then return end
        for _, slot in ipairs(slots) do
            if slot >= 0 and slot < count then
                local icon = list:call("get_Item", slot)
                if icon and set_icon_texture(icon, atlas) then
                    -- Reset the atlas window before native updateIcon decides
                    -- whether this control is hidden or assigned a real marker.
                    icon:call("set_IconType", 61)
                end
            end
        end
    end)
end

local function get_plots()
    local plots = nil
    pcall(function()
        if _G.IrisHomesteadPlots and _G.IrisHomesteadPlots.list then
            plots = _G.IrisHomesteadPlots.list()
        end
    end)
    return type(plots) == "table" and plots or {}
end

local function render_markers(ui)
    stats.calls = stats.calls + 1
    if not ui then return end

    local valid = false
    local ok_valid = pcall(function() valid = ui:get_Valid() == true end)
    if not ok_valid or not valid then return end

    local list = nil
    pcall(function() list = ui:get_field("MapIconList") end)
    if not list then return end

    local count = 0
    pcall(function() count = tonumber(list:call("get_Count")) or 0 end)
    if count < 1 then return end

    local player_pos = nil
    local out_range = 138.0
    pcall(function() player_pos = ui:get_field("PlUPos") end)
    pcall(function() out_range = tonumber(ui:get_field("MapOutRange")) or out_range end)
    if not (player_pos and player_pos.x and player_pos.z) then return end

    local candidates = {}
    for _, plot in ipairs(get_plots()) do
        local x, y, z = tonumber(plot.ux), tonumber(plot.uy), tonumber(plot.uz)
        if x and y and z then
            local dx, dz = x - player_pos.x, z - player_pos.z
            local distance_sq = dx * dx + dz * dz
            -- Match the minimap's own world range. The GUI mask handles the final
            -- circular clip, but excluding distant plots prevents edge artefacts.
            if distance_sq <= out_range * out_range then
                candidates[#candidates + 1] = {
                    x = x, y = y, z = z,
                    distance_sq = distance_sq,
                    name = tostring(plot.name or "Homestead Plot"),
                    custom_sign = plot.owned == false,
                }
            end
        end
    end
    table.sort(candidates, function(a, b) return a.distance_sq < b.distance_sq end)

    local shown, used_slots, custom_slots = 0, {}, {}
    local native_atlas = get_native_atlas(ui)
    local slot = count - 1
    for _, plot in ipairs(candidates) do
        if shown >= MAX_MARKERS then break end

        local icon = nil
        -- Search backwards for a control native updateIcon() left hidden. Never
        -- overwrite a visible native marker, regardless of how busy the area is.
        while slot >= 0 do
            local candidate = nil
            pcall(function() candidate = list:call("get_Item", slot) end)
            local visible = true
            if candidate then
                pcall(function() visible = candidate:call("get_Visible") == true end)
            end
            if candidate and not visible then
                icon = candidate
                break
            end
            slot = slot - 1
        end
        if not icon then break end

        local placed = false
        pcall(function()
            local world_pos = Vector3f.new(plot.x, plot.y, plot.z)
            local icon_pos = ui:call("getIconPos(via.vec3)", world_pos)
            if not icon_pos then icon_pos = ui:call("getIconPos", world_pos) end
            if not icon_pos then return end

            -- Always start clean: a slot may have displayed our custom sign on
            -- the preceding frame but represent an owned homestead this frame.
            set_icon_texture(icon, native_atlas)
            icon:call("set_IconType", ICON_TYPE_HOUSE)
            if plot.custom_sign and apply_custom_sign(icon) then
                custom_slots[#custom_slots + 1] = slot
            end
            icon:call("set_UseOriginScaleIcon", false)
            icon:call("set_Prio", 10)
            icon:call("set_Scale", 0.6)
            icon:call("set_Position", icon_pos)
            pcall(function() icon:call("setHitVisible", false) end)
            icon:call("set_Visible", true)
            placed = true
        end)

        if placed then
            shown = shown + 1
            used_slots[#used_slots + 1] = tostring(slot)
        end
        slot = slot - 1
    end

    last_custom_slots = custom_slots

    local slot_text = table.concat(used_slots, ",")
    if shown ~= stats.shown or slot_text ~= stats.last_slots then
        stats.shown = shown
        stats.last_slots = slot_text
        note(string.format("rendered %d nearby plot marker(s), dormant slot(s) [%s]",
            shown, slot_text ~= "" and slot_text or "none"))
    end
end

local ui_type = sdk.find_type_definition("app.ui020301")
local update_icon = ui_type and ui_type:get_method("updateIcon")
if not update_icon then
    note("not armed: app.ui020301.updateIcon was not found")
    return
end

sdk.hook(update_icon,
    function(args)
        -- Held only until this same updateIcon call returns; never retained globally.
        local ui = sdk.to_managed_object(args[2])
        -- Restore our previous custom texture before native code sees the pool.
        -- If native suddenly needs that slot, it receives an uncontaminated atlas.
        restore_previous_custom_slots(ui)
        thread.get_hook_storage().iris_minimap_ui = ui
    end,
    function(retval)
        local ui = thread.get_hook_storage().iris_minimap_ui
        local ok, err = pcall(function() render_markers(ui) end)
        thread.get_hook_storage().iris_minimap_ui = nil
        if not ok then
            stats.errors = stats.errors + 1
            if stats.errors <= 3 then note("render error: " .. tostring(err)) end
        end
        return retval
    end)

note("armed dormant-pool minimap markers (owned=house, unowned=custom sign; no manager/list writes; sign texture="
    .. tostring(sign_holder ~= nil) .. ")")
