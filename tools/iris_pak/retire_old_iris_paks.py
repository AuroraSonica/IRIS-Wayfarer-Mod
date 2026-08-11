"""Retire the superseded I.R.I.S. asset paks after installing the merged one.

Order of operations:
  1. In Fluffy, UNINSTALL:  IRIS  /  IRIS - Wild Horses  /  IRIS - Wild Cats
     (and any other IRIS asset entry -- baby bundle, woodcutting, ritual music,
     farmland -- if they are Fluffy-managed).
  2. In Fluffy, INSTALL:    IRIS_Assets_v2.0_FluffyMod.zip
  3. Close DD2, then run THIS with --apply.

Step 3 exists because some IRIS paks were hand-copied straight into the game
root rather than installed through Fluffy, so Fluffy will not remove them --
and any survivor at a HIGHER patch number than the merged pak would silently
override it.

Identification is by CONTENT HASH, never by patch number: Fluffy renumbers the
patch chain whenever any mod in the list is toggled.

Dry run:  python retire_old_iris_paks.py
Apply:    python retire_old_iris_paks.py --apply
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
from datetime import date
from pathlib import Path

GAME = Path(r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2")
STASH = GAME / "reframework" / "rs_tools" / "iris_pak" / "retired"

# Every known build of an IRIS asset pak that the merged IRIS.pak replaces.
SUPERSEDED = {
    "4ECD13F8": "IRIS v1.7 (griffin egg / nest / shells)",
    "73A6F4C5": "IRIS - Wild Cats v1.0",
    "43430146": "IRIS - Wild Horses v1.0 (OLD pre-newgaits motlist)",
    "D890DF14": "iris_wild_horses_pak_v1 (dev build, hand-copied)",
    "62331671": "baby bundle + bassinet",
    "85DFC467": "woodcutting + mining tools",
    "4A1DA6D0": "ritual music banks",
    "7ED4B3A7": "farmland mesh",
}


def md5_prefix(path: Path) -> str:
    h = hashlib.md5()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest().upper()[:8]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()

    import subprocess
    running = subprocess.run(
        ["tasklist", "/FI", "IMAGENAME eq DD2.exe"],
        capture_output=True, text=True).stdout
    if "DD2.exe" in running:
        raise SystemExit("DD2 is running -- close the game first "
                         "(it holds the pak files open).")

    # A 16-byte placeholder keeps the patch chain contiguous, the convention
    # already used across this install.
    dummy = None
    for pak in sorted(GAME.glob("re_chunk_000.pak.patch_*.pak")):
        if pak.stat().st_size == 16:
            dummy = pak.read_bytes()
            break
    if dummy is None:
        raise SystemExit("no existing 16-byte placeholder to copy the format from")

    hits, merged_at = [], None
    for pak in sorted(GAME.glob("re_chunk_000.pak.patch_*.pak")):
        if pak.stat().st_size <= 16:
            continue
        prefix = md5_prefix(pak)
        if prefix in SUPERSEDED:
            hits.append((pak, prefix, SUPERSEDED[prefix]))
        # The merged pak is the only one carrying all 92 paths; spot it by size.
        if pak.stat().st_size == 65618743:
            merged_at = pak.name

    print(f"merged IRIS.pak installed as: {merged_at or 'NOT FOUND'}")
    if merged_at is None:
        print("  install IRIS_Assets_v2.0_FluffyMod.zip in Fluffy first.")

    if not hits:
        print("\nno superseded IRIS paks left installed -- nothing to do")
        return 0

    print(f"\n{len(hits)} superseded IRIS pak(s) still installed:")
    for pak, prefix, label in hits:
        print(f"  {pak.name:<32} {prefix}  {label}")

    if not args.apply:
        print("\ndry run -- re-run with --apply to retire them")
        return 0

    STASH.mkdir(parents=True, exist_ok=True)
    for pak, prefix, label in hits:
        backup = STASH / f"{pak.name}.{prefix}.{date.today():%Y%m%d}.bak"
        shutil.copy2(pak, backup)
        pak.write_bytes(dummy)
        print(f"  retired {pak.name}  ->  {backup.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
