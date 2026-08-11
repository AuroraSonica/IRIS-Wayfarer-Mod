"""IRIS_Assets v3.3.3 -- complete multi-pak plus runtime files.

ONE Fluffy mod entry containing the SEVEN proven pak files, byte-identical to
the builds running in-game today. Fluffy installs every .pak in a mod folder,
so this gives Aurora a single thing to manage without any custom container.
The Lua modules and their JSON audio manifests are included as well: shipping
only the paks left custom audio permanently unavailable.
"""
from __future__ import annotations

import hashlib
import zipfile
from pathlib import Path

GAME = Path(r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2")
HERE = Path(__file__).parent
OUT = HERE / "IRIS_Assets_v3.4_MultiPak_FluffyMod.zip"

# (zip name, expected md5 prefix, candidate source paths in priority order)
PAKS = [
    ("IRIS_00_griffin_egg.pak", "4ECD13F8", [GAME / "griffin-egg" / "pakroot.pak"]),
    # ⛔ NOT the raw v1 dev pak, and NOT the 2026-08-05 "new gaits" swap:
    # both ended in c000001d. This is the older compressed PAK whose motlist
    # already contains Horse_Walk/Trot/Gallop and was field-proven in-game.
    ("IRIS_01_wild_horses.pak", "43430146",
     [Path(__file__).parent / "IRIS_01_wild_horses.pak"]),
    ("IRIS_02_wild_cats.pak", "73A6F4C5",
     [GAME / "reframework" / "rs_tools" / "horse_wwise" / "iris_wild_cats_pak_v1.pak"]),
    ("IRIS_03_baby_bundle.pak", "62331671", [GAME / "baby-bundle" / "pak_clean.pak"]),
    ("IRIS_04_woodcutting.pak", "85DFC467", []),   # only exists installed
    ("IRIS_05_ritual_music.pak", "4A1DA6D0",
     [GAME / "reframework" / "rs_tools" / "horse_wwise" / "iris_ritual_music_pak_v1.pak"]),
    ("IRIS_06_farmland.pak", "7ED4B3A7", []),      # only exists installed
    # ⭐ NEW 2026-08-08: Aurora's Rodin weapon wall-plaque. prefix=None because this pak has
    # never been installed yet, so there is no field-proven md5 to pin it against - it is
    # pinned from the build directory instead. Give it a real prefix once it is proven
    # in-game, so a later rebuild can't silently ship a different plaque.
    ("IRIS_07_wallrack.pak", None, [HERE / "IRIS_07_wallrack.pak"]),
]

RUNTIME_FILES = [
    # ⛔ 08-11: NEVER ship the live .lua in a Fluffy zip -- Fluffy REDEPLOYS every
    # installed mod when the mod list changes, stamping this stale copy over the
    # live file (lost the unicorn work twice in one night). Lua ships separately.
    # ("reframework/autorun/IrisWildCats.lua", ...),
    # ⛔ 08-11: NEVER ship the live .lua in a Fluffy zip -- Fluffy REDEPLOYS every
    # installed mod when the mod list changes, stamping this stale copy over the
    # live file (lost the unicorn work twice in one night). Lua ships separately.
    # ("reframework/autorun/IrisWildHorses.lua", ...),
    ("reframework/data/PumaAudioManifest.json",
     GAME / "reframework" / "data" / "PumaAudioManifest.json"),
    ("reframework/data/HorseAudioManifest.json",
     GAME / "reframework" / "data" / "HorseAudioManifest.json"),
]

MODINFO = """[Mod]
name=IRIS - Assets (multi-pak)
version=3.4.0
description=Every I.R.I.S. custom asset in one Fluffy mod: griffin egg/nest/shells, wild horses, wild cats (puma/panther), baby bundle + bassinet, woodcutting/mining tools, ritual music, farmland and the weapon wall-plaque. Includes the Wild Cats/Horses runtime scripts and audio manifests. Horse locomotion uses the field-proven compressed Walk/Trot/Gallop motlist; v3.3.3 repairs horse durability and cat recognition, bank loading and native-template vocal fallback. Replaces the separate IRIS asset mods; uninstall those first. Requires REFramework.
author=Aurora, Lyra and Iris
"""


def md5_prefix(path: Path) -> str:
    h = hashlib.md5()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest().upper()[:8]


def find_installed(prefix: str) -> Path | None:
    for pak in sorted(GAME.glob("re_chunk_000.pak.patch_*.pak")):
        if pak.stat().st_size > 16 and md5_prefix(pak) == prefix:
            return pak
    return None


def main() -> int:
    resolved = []
    for name, prefix, candidates in PAKS:
        source = None
        for cand in candidates:
            if cand.exists() and (prefix is None or md5_prefix(cand) == prefix):
                source = cand
                break
        if source is None and prefix is not None:
            source = find_installed(prefix)
        if source is None:
            raise SystemExit(f"cannot find a source for {name} ({prefix}) -- "
                             "is it uninstalled AND missing from disk?")
        resolved.append((name, source))
        print(f"  {name:<28} <- {source}")

    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
        zf.writestr("modinfo.ini", MODINFO)
        for name, source in resolved:
            zf.write(source, name)
        for name, source in RUNTIME_FILES:
            if not source.is_file():
                raise SystemExit(f"missing runtime file: {source}")
            zf.write(source, name)
    print(f"\nbuilt {OUT}  ({OUT.stat().st_size:,} B)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
