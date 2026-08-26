-- Compatibility path for modules extracted before the mount-engine rename.
-- Do not create state here: IRISMounts.context is the sole C/S owner.
return require("IRISMounts.context")
