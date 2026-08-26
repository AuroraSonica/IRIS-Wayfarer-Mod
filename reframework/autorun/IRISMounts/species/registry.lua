-- Neutral species registry for the I.R.I.S. mount engine.
--
-- This module is deliberately stateless: REFramework may retain package.loaded
-- across Reset Scripts, so no live GameObject, C or S reference belongs here.

local M = {}
local by_id = {}
local ordered = {}

local function rebuild_order()
    ordered = {}
    for _, adapter in pairs(by_id) do ordered[#ordered + 1] = adapter end
    table.sort(ordered, function(a, b)
        local al = #(tostring((a.chassis or {})[1] or ""))
        local bl = #(tostring((b.chassis or {})[1] or ""))
        if al ~= bl then return al > bl end
        return tostring(a.id) < tostring(b.id)
    end)
end

function M.register(adapter)
    assert(type(adapter) == "table", "mount species adapter must be a table")
    local id = tostring(adapter.id or "")
    assert(id ~= "", "mount species adapter requires an id")
    assert(type(adapter.chassis) == "table" and #adapter.chassis > 0,
        "mount species adapter requires at least one chassis prefix")
    by_id[id] = adapter
    rebuild_order()
    return adapter
end

function M.get(id)
    return by_id[tostring(id or "")]
end

function M.resolve(identity)
    local raw = tostring(identity or "")
    if raw == "" then return nil end
    for _, adapter in ipairs(ordered) do
        if type(adapter.matches) == "function" then
            local ok, matched = pcall(adapter.matches, raw)
            if ok and matched == true then return adapter end
        end
        for _, prefix in ipairs(adapter.chassis or {}) do
            if raw:find(tostring(prefix), 1, true) ~= nil then return adapter end
        end
    end
    return nil
end

function M.is(identity, id)
    local adapter = M.resolve(identity)
    return adapter ~= nil and adapter.id == tostring(id or "")
end

function M.has(identity, capability)
    local adapter = M.resolve(identity)
    return adapter ~= nil
        and type(adapter.capabilities) == "table"
        and adapter.capabilities[tostring(capability or "")] == true
end

function M.display_name(identity)
    local adapter = M.resolve(identity)
    if adapter == nil then return nil end
    return tostring(adapter.display_name or adapter.id or "")
end

function M.list()
    local out = {}
    for i, adapter in ipairs(ordered) do out[i] = adapter end
    return out
end

M.register(require("IRISMounts.species.griffin"))
M.register(require("IRISMounts.species.drake"))

return M
