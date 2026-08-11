"""Wrap the consolidated IRIS.pak into a Fluffy-installable zip.

Fluffy reads modinfo.ini at the zip root and installs the .pak alongside it as
a single re_chunk_000.pak.patch_NNN.pak.  ONE mod entry, ONE patch number --
which is the whole point of consolidating.

The zip carries the pak ONLY.  The REFramework Lua and its data/*.json are
deliberately left out of this bundle: Aurora edits those live in
reframework/autorun/ and a Fluffy-managed copy would fight her working tree.
The public release zips keep shipping their own lua as they do today.

Run:  .venv-puma-tools\\Scripts\\python.exe package_iris_pak.py
"""

from __future__ import annotations

import zipfile
from pathlib import Path

HERE = Path(__file__).parent
PAK = HERE / "IRIS.pak"
OUT = HERE / "IRIS_Assets_v2.3_FluffyMod.zip"

MODINFO = """[Mod]
name=IRIS - Assets
version=2.3
description=Every I.R.I.S. custom asset in one pak: wild horse (mesh, walk/trot/gallop motlist, full sound set), puma and panther (mesh, textures, 21 cat vocals), griffin egg / nest / shells, baby bundle and bassinet, woodcutting and mining tools with icons, ritual music banks, and the farmland mesh. Replaces the separate IRIS, IRIS - Wild Horses and IRIS - Wild Cats asset paks -- uninstall those first. No native meshes or sounds are replaced. Requires REFramework and the I.R.I.S. scripts.
author=Aurora, Lyra and Iris
"""


def main() -> int:
    if not PAK.exists():
        raise SystemExit(f"missing {PAK} -- run build_iris_pak.py first")

    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
        zf.writestr("modinfo.ini", MODINFO)
        zf.write(PAK, "IRIS.pak")
        shot = HERE / "showcase.jpg"
        if shot.exists():
            zf.write(shot, "showcase.jpg")

    print(f"built {OUT}")
    print(f"  pak {PAK.stat().st_size:,} B -> zip {OUT.stat().st_size:,} B")
    with zipfile.ZipFile(OUT) as zf:
        for info in zf.infolist():
            print(f"  {info.file_size:>12,}  {info.filename}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
