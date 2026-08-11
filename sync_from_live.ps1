# sync_from_live.ps1 — copy the LIVE IRIS mod files into this repo.
# Run this, review `git status`, stage the files you mean to commit, commit AFTER
# in-game verification, push. Never edit files in this repo directly — the live
# game folder is the source of truth; this repo is its version control.
#
# ⛔ The live reframework folder must NEVER be git-inited (other mods + real API
#    keys live there). All git work happens HERE, on C:.

$live = "D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework"
$repo = $PSScriptRoot

function Copy-Into($src, $destDir) {
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force $destDir | Out-Null }
    Copy-Item $src -Destination $destDir -Force -ErrorAction SilentlyContinue
}

# ── 1. THE MOD CODE (every IRIS-family Lua, mirrored at install paths) ──────────
$auto = Join-Path $repo "reframework\autorun"
Copy-Into "$live\autorun\*Iris*.lua"            $auto      # IrisTaming, IrisFarming, !IrisPerfProbe, 000IrisInputGate...
Copy-Into "$live\autorun\Griffin*.lua"          $auto      # GriffinRideProbe - Iris, GriffinScreechThrottle
Copy-Into "$live\autorun\ReyDauGriffinPort.lua" $auto
Copy-Into "$live\autorun\IrisGriffin\*.lua"     (Join-Path $auto "IrisGriffin")

# ── 2. RUNTIME-REQUIRED DATA (shipped blueprints the code loads at runtime) ─────
$dat = Join-Path $repo "reframework\data\IRIS"
Copy-Into "$live\data\IRIS\forge_house_*.json"    $dat     # house kit blueprints (IrisWalk/IrisHomestead load these)
Copy-Into "$live\data\IRIS\house_exclusions.json" $dat     # IrisHouseForge

# ── 3. RELEASE PACKAGES (latest Fluffy zips only — paks travel inside the zips) ─
$pkg = Join-Path $repo "packages"
Copy-Into "$live\rs_tools\iris_pak\IRIS_Assets_v3.4_MultiPak_FluffyMod.zip" $pkg
Copy-Into "$live\rs_tools\iris_pak\IRIS_HorseJumpPack_FluffyMod.zip"        $pkg
Copy-Into "$live\rs_tools\iris_pak\IRIS_HorseRitualPack_FluffyMod.zip"      $pkg
Copy-Into "$live\rs_tools\unicorn_pak\IRIS_Unicorn_v1.3_FluffyMod.zip"      $pkg
Copy-Into "$live\rs_tools\pegasus_pak\IRIS_Pegasus_v0.1_FluffyMod.zip"      $pkg

# ── 4. BUILD TOOLING + REFERENCE DATA ───────────────────────────────────────────
Copy-Into "$live\rs_tools\iris_pak\*.py"  (Join-Path $repo "tools\iris_pak")
Copy-Into "$live\rs_tools\iris_pak\*.ps1" (Join-Path $repo "tools\iris_pak")
Copy-Into "$live\Animal Atlas\*.json"     (Join-Path $repo "tools\AnimalAtlas")   # creature motion atlases — NEVER guess a clip id

# ── 5. PROFILE BACKUP (Aurora's save-state: the stable = the SOULS, the home) ───
$prof = Join-Path $repo "profile-backup"
# ⛔ no wildcard here — the live data folder holds ~30 probe-dump jsons under the
#    same prefix (diagnostic artifacts, not profile). These four are the profile:
Copy-Into "$live\data\GriffinRideProbe (IRIS).json"                  $prof   # main config
Copy-Into "$live\data\GriffinRideProbe (IRIS)_species_profiles.json" $prof
Copy-Into "$live\data\GriffinRideProbe (IRIS)_stable.json"           $prof   # THE STABLE = the souls
Copy-Into "$live\data\GriffinRideProbe (IRIS)_tamed.json"            $prof
Copy-Into "$live\data\IRIS\iris_furniture.json"        $prof
Copy-Into "$live\data\IRIS\iris_plots.json"            $prof
Copy-Into "$live\data\IRIS\garden.json"                $prof
Copy-Into "$live\data\IRIS\weapon_mounts.json"         $prof
Copy-Into "$live\data\IRIS\weapon_mount_cfg.json"      $prof
Copy-Into "$live\data\IRIS\animal_produce.json"        $prof
Copy-Into "$live\data\IrisTaming_state.json"           $prof
Copy-Into "$live\data\IrisWildCats.json"               $prof
Copy-Into "$live\data\IrisWildHorses.json"             $prof

Write-Output "Sync complete. Review with: git -C `"$repo`" status"
