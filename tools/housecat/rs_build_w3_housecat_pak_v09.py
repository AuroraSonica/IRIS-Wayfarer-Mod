"""Pack the v0.9 house-cat stage (v09 mesh + v07 materials + v8 W3 motlist)
into IRIS_10_housecat_v09.pak and zip the Fluffy mod.

Reuses build_iris_pak's aligned writer verbatim (the 16-byte alignment law and
the __MANIFEST round-trip check).
"""

from __future__ import annotations

import sys
import zipfile
from pathlib import Path

RS = Path(r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework\rs_tools")
sys.path.insert(0, str(RS / "iris_pak"))
import build_iris_pak as lib  # noqa: E402

STAGE = RS / "w3_housecat_pak_v09"
FLUFFY = RS / "w3_housecat_fluffy_v0.9"
PAK = FLUFFY / "IRIS_10_housecat_v09.pak"
ZIP = RS / "IRIS_HouseCat_Prototype_v0.9_FluffyMod.zip"

MODINFO = """[Mod]
name=IRIS - House Cat Prototype
version=0.9-w3-anims-v8-blend
description=V09 cat body (fixed shoulder binding, subdivided, smoothed weights) + the full 17-clip Witcher cat motion catalogue (v8 stance-blend retarget) as motlist bank 904. Retains the proven v0.7 brown-tabby material. Supersedes v0.1-v0.8.
author=Aurora and Lyra and Iris
"""

README = """IRIS House Cat Prototype v0.9
=============================
- iris_housecat.mesh: v09 Witcher cat body on the ch99_200 rabbit skeleton.
  Shoulder weights rebound to the physical front legs (the chest pinch and
  dead-shoulder defects are gone), subdivided once, weights smoothed.
- iris_housecat_full.motlist: all 17 Witcher cat clips (v8 retarget).
  Runtime bank 904 via IrisTaming > House cat > ARM W3 motion bank.
- Same v0.7 brown-tabby material chain.

Install via Fluffy Mod Manager. Then in game:
REFramework > Script Generated UI > Iris TAMING > House cat (IRIS companion):
1. ARM house-cat mesh, spawn the cat.
2. ARM W3 motion bank (v0.9 pak), then Play W3 clip to audition takes 1-17.
"""

entries = []
for path in sorted((STAGE / "natives").rglob("*")):
    if path.is_file():
        blob = path.read_bytes()
        entries.append((path.relative_to(STAGE).as_posix().lower(), blob, 0, len(blob)))
print(f"stage files: {len(entries)}")
for name, blob, _a, _r in entries:
    print(f"  {len(blob):>9,} B  {name}")

FLUFFY.mkdir(exist_ok=True)
lib.write_pak(entries, PAK)
print(f"pak: {PAK} ({PAK.stat().st_size:,} B)")

# verify every payload byte-for-byte against the stage (stale-stage law)
back = lib.read_pak(PAK)
for name, blob, _a, _r in entries:
    assert back[name] == blob, f"round-trip mismatch: {name}"
print("round-trip verified: all payloads byte-identical to stage")

(FLUFFY / "modinfo.ini").write_text(MODINFO, encoding="utf-8")
(FLUFFY / "README.txt").write_text(README, encoding="utf-8")

with zipfile.ZipFile(ZIP, "w", zipfile.ZIP_DEFLATED) as z:
    for f in sorted(FLUFFY.iterdir()):
        z.write(f, f.name)
print(f"zip: {ZIP} ({ZIP.stat().st_size:,} B)")
print("V09_PAK_OK")
