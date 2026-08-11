-- Shared handles for the I.R.I.S. griffin modules.
--
-- The main script fills this in once, before it requires any feature module. A module then
-- binds what it needs as locals at the top:
--
--     local ctx = require("IrisGriffin.context")
--     local C, S = ctx.C, ctx.S
--     local status, play_griffin_motion = ctx.status, ctx.play_griffin_motion
--
-- which keeps the thousands of existing C./S./helper call sites working verbatim, and makes a
-- module's dependencies readable at a glance instead of implied by a 28,000-line scope.
--
-- ⛔ C AND S ARE OWNED HERE, and the main script refills them in place rather than replacing
-- them. require() caches modules in package.loaded, and a REFramework script reset does not
-- reliably clear that -- so a module that bound `local C = ctx.C` on a previous load would keep
-- pointing at the abandoned table while the main script talked to a fresh one. Everything would
-- appear to work while silently reading dead config. Keeping the table identity stable across
-- reloads is what makes the whole arrangement safe.
--
-- Cross-file function calls mostly need nothing: this file's 500-odd top-level functions are
-- already globals, because a single chunk cannot hold more than 200 locals. Only the handful
-- that are still file-local have to be published through here.

return {
    C = {},     -- live config (DEFAULT merged with the saved json)
    S = {},     -- runtime state
    MOD = "GriffinRideProbe (IRIS)",
}
