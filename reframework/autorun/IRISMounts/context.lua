-- Shared process-lifetime handles for the I.R.I.S. Mount Engine.
--
-- C and S must retain their table identity across REFramework script resets.
-- Feature modules bind these tables as locals, while package.loaded is not
-- reliably cleared by Reset Scripts. Replacing either table therefore creates
-- two contradictory runtimes: the entry point writes one and cached modules
-- continue reading the other.
--
-- During the namespace migration, a cached IrisGriffin.context may already own
-- the live tables. Reuse it rather than creating a second context. On a clean
-- game launch this module creates the tables and the legacy path aliases them.

local legacy = package.loaded["IrisGriffin.context"]
if type(legacy) == "table"
    and type(legacy.C) == "table"
    and type(legacy.S) == "table" then
    return legacy
end

return {
    C = {},
    S = {},

    -- Persistence filenames remain unchanged until the modular engine has
    -- reached feature parity. Renaming this now would silently discard Aurora's
    -- tuned config, species profiles and stable records.
    MOD = "GriffinRideProbe (IRIS)",
}
