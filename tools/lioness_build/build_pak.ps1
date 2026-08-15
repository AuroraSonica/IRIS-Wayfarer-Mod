# Merge both variants into ONE pak and wrap it as a Fluffy mod.
#
# The v1.0 build shipped TWO paks overriding the SAME nine paths, so installing both meant
# the higher Fluffy patch number silently shadowed the other -- which is exactly what
# Aurora hit (patch_062 panther + patch_063 lioness, and 063 won, so BOTH cats wore the
# tawny coat and the panther's black came only from the runtime Lua tint). The panther now
# owns ch23_002.*, so one pak carries both and nothing shadows anything.
$ErrorActionPreference = "Stop"

# ⭐ VERSION AND BUILD STAMP (Aurora: "make sure to increment version numbers so I know
# which is the most recent file"). Two overwritten builds shared a filename earlier today
# and there was no way to tell them apart from Fluffy's list -- which mattered, because one
# of them was shipping stale content. BUMP $VER for every build that changes content; the
# stamp and pak hash are printed and written into the zip so the deployed patch pak can
# always be matched back to a build.
$VER = "3.2"
$STAMP = Get-Date -Format "yyyyMMdd-HHmm"

$OUT   = "D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework\rs_tools\lioness_build"
$STAGE = Join-Path $OUT "stage_all"
$RET   = "D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework\rs_tools\RETool\bin\REtool.exe"

if (Test-Path $STAGE) { Remove-Item -Recurse -Force $STAGE }
New-Item -ItemType Directory -Force $STAGE | Out-Null

# ⛔⛔ EACH STAGE MUST CONTAIN ONLY ITS OWN VARIANT'S CODE. stage_lioness owns ch23_001,
# stage_panther owns ch23_002. When the panther moved from ch23_001 to ch23_002 its old
# ch23_001 files stayed behind, and because this loop copies lioness FIRST and panther
# SECOND with -Force, those leftovers silently overwrote the lioness's mesh and textures
# under identical names -- shipping a black puma running the previous build's mesh. The
# file COUNT was unchanged, so nothing downstream could notice. Fail loudly instead.
# ⛔⛔ ch23_002 IS NO LONGER SHIPPED (2026-08-15, v3.0). Giving the panther its own mesh,
# mdf2 and textures behind a redirected ch223001_01.pfb was the right design and it never
# worked: through four builds the panther prefab never reached get_Ready, so force-PANTHER
# always fell through to a vanilla wolf. The in-game probe cleared the pak completely --
# `ch23_002.mesh=OK`, staging error "none" -- so the paths, hashes and pak were fine; the
# prefab simply refuses to ready with a redirected material. Not worth more of Aurora's
# field time. The panther goes back to the proven route: ONE shared mesh, recoloured at
# runtime by IrisWildCats (recolour_panther_material = true).
#
# ⛔ AND THE PATCHED PREFAB MUST NOT SHIP EITHER. Leaving it in would keep pointing
# ch223001_01 at a ch23_002 set that is no longer in the pak -- strictly worse than the
# bug it was meant to fix.
# ⭐ v3.1: ch23_002 IS BACK, but as a MATERIAL ONLY -- ch23_002.mdf2 plus its charcoal
# textures, no mesh and no prefab. IrisWildCats swaps it onto the live panther at runtime
# (the unicorn's proven route). Puma and panther share geometry, so set_Material alone is
# the entire mechanism.
$owns = @{ "stage_lioness" = "ch23_002"; "stage_panther" = "ch23_001" }   # each may NOT contain the other's code
foreach ($v in @("stage_lioness", "stage_panther")) {
    $mine = $owns[$v]
    $other = $owns[$v]       # the code this stage must NOT contain
    $strays = Get-ChildItem (Join-Path $OUT "$v\natives") -Recurse -File |
        Where-Object { $_.FullName -match [regex]::Escape($other) }
    if ($strays) {
        $strays | ForEach-Object { Write-Host "   STRAY: $($_.FullName)" }
        throw "$v contains $($strays.Count) file(s) belonging to $other - stale stage, rebuild textures"
    }
    Copy-Item -Recurse -Force (Join-Path $OUT "$v\natives") $STAGE
}
$files = Get-ChildItem $STAGE -Recurse -File
Write-Host "staged $($files.Count) files:"
$files | ForEach-Object { Write-Host ("   " + $_.FullName.Replace("$STAGE\", "")) }

Push-Location (Split-Path $RET)
& $RET -version 4 1 -c $STAGE
Pop-Location

$pak = Join-Path $OUT "stage_all.pak"
if (-not (Test-Path $pak)) { throw "REtool did not produce $pak" }
Write-Host "pak: $((Get-Item $pak).Length) bytes"

# ---- Fluffy wrapper ----
$ZD = Join-Path $OUT "zip_all"
if (Test-Path $ZD) { Remove-Item -Recurse -Force $ZD }
New-Item -ItemType Directory -Force $ZD | Out-Null
Copy-Item $pak (Join-Path $ZD "IRIS_10_ch23_lioness_panther.pak") -Force

@"
[modinfo]
name=IRIS - Lioness and Panther
version=$VER build $STAMP
description=Replaces the Puma and Panther bodies with a re-rigged lioness mesh (ch23_001). Real eye submesh with a painted gold iris and a working emissive glow. Tail rebound 1:1 to the wolf tail chain. The Panther is recoloured at runtime by IrisWildCats.lua - the mod's Lua half must be installed for panthers to be black. Supersedes ALL earlier IRIS_Lioness builds; uninstall them.
author=Aurora + Iris
screenshot=
"@ | Set-Content -Encoding UTF8 (Join-Path $ZD "modinfo.ini")

@"
IRIS - Lioness and Panther  v$VER  (build $STAMP)
================================================

Replaces BOTH wild cat variants on the redwolf chassis (ch223001_00 Puma /
ch223001_01 Panther) with a re-rigged lioness mesh.

WHAT IS IN THE PAK
  natives/stm/character/ch/ch23_001/     lioness mesh + 7 textures  (both cats)
  natives/stm/character/ch/ch23_002/     ch23_002.mdf2 + 7 charcoal textures (Panther)
  natives/stm/streaming/... /ch23_001/   streaming twins
  natives/stm/streaming/... /ch23_002/   streaming twins

HOW THE PANTHER GETS ITS OWN LOOK
  Both cats share one MESH (identical geometry), so the Panther only needs its own
  MATERIAL. IrisWildCats.lua pins ch23_002.mdf2 at arm, waits out a 15 s stream gate,
  builds a holder and calls set_Material on each live panther - the same runtime-swap
  route IrisWildHorses uses for the unicorn. That gives the Panther a real charcoal coat
  (relative contrast 0.61 vs the 0.21 a BaseColor tint can reach), its own eye atlas with
  a painted gold iris, and Emissive_Color1/2 baked yellow in the mdf2 itself.
  If the pak or the resource is missing it falls back to the old BaseColor tint, so a
  missing pak degrades the look rather than producing a tawny panther.

  ⛔ NOT DONE BY PATCHING ch223001_01.pfb. v2.x redirected that prefab at ch23_002 and it
  never reached get_Ready across four builds - an in-game probe proved the pak was fine
  (ch23_002.mesh=OK, no staging error), the prefab itself simply refused. Nothing in this
  install has ever shipped a patched prefab; the runtime swap is the proven mechanism.

UNINSTALL FIRST
  ALL earlier IRIS_Lioness / IRIS_LionessPanther builds are superseded.
  Fluffy can leave orphaned patch paks behind on uncheck - if the cat looks wrong,
  hash the deployed re_chunk_000.pak.patch_0XX.pak against the md5 in BUILD.txt.

CREDIT (REQUIRED - the source model is CC-BY)
  "Lioness - realistic 3D model demo", Sketchfab.

KNOWN LIMITS
  - Ears are damped to 45%: her ears sit 0.33 m behind the wolf's ear bones, so an
    undamped flick spiked to 4.8x edge stretch.
  - head/fur/angryhead materials are 1 mm dummy submeshes; those slots exist only to
    satisfy the fallback-material law and still point at vanilla textures.
  - Fur is derived from the albedo's high-pass; the source ships no normal map.
"@ | Set-Content -Encoding UTF8 (Join-Path $ZD "README.txt")

$hash = (Get-FileHash $pak -Algorithm MD5).Hash.ToLower()
@"
IRIS - Lioness and Panther
version : $VER
built   : $STAMP
pak md5 : $hash

To confirm which build is LIVE, hash the deployed patch pak and compare:
    (Get-FileHash "D:\SteamLibrary\steamapps\common\Dragons Dogma 2\re_chunk_000.pak.patch_0XX.pak" -Algorithm MD5).Hash
"@ | Set-Content -Encoding UTF8 (Join-Path $ZD "BUILD.txt")

$zip = Join-Path $OUT "IRIS_LionessPanther_v${VER}_$STAMP`_FluffyMod.zip"
Get-ChildItem $OUT -Filter "IRIS_LionessPanther_*_FluffyMod.zip" | Remove-Item -Force
Compress-Archive -Path (Join-Path $ZD "*") -DestinationPath $zip
Write-Host ""
Write-Host "==============================================================="
Write-Host " VERSION : $VER      BUILT: $STAMP"
Write-Host " PAK MD5 : $hash"
Write-Host " ZIP     : $zip"
Write-Host "==============================================================="
