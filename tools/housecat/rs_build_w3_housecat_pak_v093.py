"""v0.9.3 DISCRIMINATOR pak: the proven v0.8 pak byte-verbatim + ONLY the
W3 motlist appended.

v0.9.1 (proven container shape, new v09 mesh) still crashed Aurora on
arm-mesh.  The only changed artifact on the arm path was the v09 mesh entry,
but offline validation cannot prove mesh content either way.  v0.9.3 keeps
EVERY v0.8 entry byte-identical -- old mesh, old checksums, old offsets
order -- and appends just the motlist (which the arm-mesh path never
touches).  Outcomes:
  - arm works  -> the v09 MESH CONTENT was the killer; anims testable tonight
                  on the old v0.8 body, mesh fixed on its own track.
  - arm crashes -> the pak is exonerated entirely; the fault is environmental
                  (mod interaction / Lua) and the hunt moves there.
"""

from __future__ import annotations

import struct
import zipfile
import zlib
from pathlib import Path

RS = Path(r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework\rs_tools")
SOURCE = RS / "w3_housecat_fluffy_v0.8" / "IRIS_10_housecat_v08.pak"
STAGE = RS / "w3_housecat_pak_v09"
FLUFFY = RS / "w3_housecat_fluffy_v0.9.3"
PAK = FLUFFY / "IRIS_10_housecat_v093.pak"
ZIP = RS / "IRIS_HouseCat_Prototype_v0.9.3_FluffyMod.zip"

MOTLIST_NAME = "natives/stm/character/ch/iris_housecat/iris_housecat_full.motlist.751"
BISECT_NAME = "natives/stm/character/ch/iris_housecat/iris_housecat_bisect3.motlist.751"
FULL_SRC = RS / "exports" / "w3_housecat_full_catalogue_v8.motlist.751"
BISECT_SRC = RS / "exports" / "w3_housecat_BISECT.motlist.751"
MANIFEST_NAME = "__MANIFEST/MANIFEST.TXT"

PAK_MAGIC = 1095454795
HEADER = struct.Struct("<IBBHII")
ENTRY = struct.Struct("<IIQQQQQ")
ALIGN = 16


def hash_utf16(text: str, seed: int = 0xFFFFFFFF) -> int:
    data = text.encode("utf-16le")
    h1 = seed
    c1, c2 = 0xCC9E2D51, 0x1B873593
    for start in range(0, len(data) // 4 * 4, 4):
        k1 = int.from_bytes(data[start:start + 4], "little")
        k1 = (k1 * c1) & 0xFFFFFFFF
        k1 = ((k1 << 15) | (k1 >> 17)) & 0xFFFFFFFF
        k1 = (k1 * c2) & 0xFFFFFFFF
        h1 ^= k1
        h1 = ((h1 << 13) | (h1 >> 19)) & 0xFFFFFFFF
        h1 = (h1 * 5 + 0xE6546B64) & 0xFFFFFFFF
    tail = data[len(data) // 4 * 4:]
    k1 = 0
    if len(tail) >= 3:
        k1 ^= tail[2] << 16
    if len(tail) >= 2:
        k1 ^= tail[1] << 8
    if len(tail) >= 1:
        k1 ^= tail[0]
    if tail:
        k1 = (k1 * c1) & 0xFFFFFFFF
        k1 = ((k1 << 15) | (k1 >> 17)) & 0xFFFFFFFF
        k1 = (k1 * c2) & 0xFFFFFFFF
        h1 ^= k1
    h1 ^= len(data)
    h1 ^= h1 >> 16
    h1 = (h1 * 0x85EBCA6B) & 0xFFFFFFFF
    h1 ^= h1 >> 13
    h1 = (h1 * 0xC2B2AE35) & 0xFFFFFFFF
    h1 ^= h1 >> 16
    return h1 & 0xFFFFFFFF


def deflate(raw: bytes) -> bytes:
    co = zlib.compressobj(9, zlib.DEFLATED, -15)
    return co.compress(raw) + co.flush()


src = SOURCE.read_bytes()
magic, major, minor, feature, count, fingerprint = HEADER.unpack_from(src, 0)
assert magic == PAK_MAGIC and (major, minor) == (4, 1)
toc = [ENTRY.unpack_from(src, HEADER.size + i * ENTRY.size) for i in range(count)]

man_key = (hash_utf16(MANIFEST_NAME.lower()), hash_utf16(MANIFEST_NAME.upper()))
entries = []  # (lower, upper, blob, raw, attrs, ck) in ORIGINAL TOC order
manifest_names = None
for lo, hi, off, packed, raw, attrs, ck in toc:
    blob = src[off:off + packed]
    if (lo, hi) == man_key:
        manifest_names = [n for n in zlib.decompress(blob, -15).decode("utf-8").splitlines() if n.strip()]
        continue  # rebuilt below, re-appended at the end like the source had it last... keep order flexible
    entries.append((lo, hi, blob, raw, attrs, ck))
assert manifest_names is not None

motlist_raw = FULL_SRC.read_bytes()
entries.append((hash_utf16(MOTLIST_NAME.lower()), hash_utf16(MOTLIST_NAME.upper()),
                deflate(motlist_raw), len(motlist_raw), 1, 0))
bisect_raw = BISECT_SRC.read_bytes()
entries.append((hash_utf16(BISECT_NAME.lower()), hash_utf16(BISECT_NAME.upper()),
                deflate(bisect_raw), len(bisect_raw), 1, 0))

new_names = [n for n in manifest_names if n.upper() != MANIFEST_NAME.upper()] + [MOTLIST_NAME, BISECT_NAME]
manifest_raw = ("\n".join(new_names + [MANIFEST_NAME]) + "\n").encode("utf-8")
entries.append((man_key[0], man_key[1], deflate(manifest_raw), len(manifest_raw), 1, 0))

FLUFFY.mkdir(exist_ok=True)
toc_size = ENTRY.size * len(entries)
cursor = HEADER.size + toc_size
cursor += (-cursor) % ALIGN
out_toc = []
with PAK.open("wb") as stream:
    stream.write(HEADER.pack(magic, major, minor, feature, len(entries), fingerprint))
    stream.write(bytes(toc_size))
    for lo, hi, blob, raw, attrs, ck in entries:
        out_toc.append((lo, hi, cursor, len(blob), raw, attrs, ck))
        stream.seek(cursor)
        stream.write(blob)
        cursor += len(blob)
        pad = (-cursor) % ALIGN
        if pad:
            stream.write(bytes(pad))
            cursor += pad
    stream.seek(HEADER.size)
    for entry in out_toc:
        stream.write(ENTRY.pack(*entry))

# verify: every original v0.8 payload byte-identical; motlist decodes exact
out = PAK.read_bytes()
o_toc = [ENTRY.unpack_from(out, HEADER.size + i * ENTRY.size) for i in range(len(entries))]
by_key = {(lo, hi): (off, packed, raw, attrs) for lo, hi, off, packed, raw, attrs, _ in o_toc}
for lo, hi, off, packed, raw, attrs, ck in toc:
    if (lo, hi) == man_key:
        continue
    o_off, o_packed, o_raw, o_attrs = by_key[(lo, hi)]
    assert out[o_off:o_off + o_packed] == src[off:off + packed], "v0.8 payload drift"
    assert (o_raw, o_attrs) == (raw, attrs)
for nm, rawb in ((MOTLIST_NAME, motlist_raw), (BISECT_NAME, bisect_raw)):
    mk = (hash_utf16(nm.lower()), hash_utf16(nm.upper()))
    o_off, o_packed, o_raw, o_attrs = by_key[mk]
    assert zlib.decompress(out[o_off:o_off + o_packed], -15) == rawb
print(f"pak: {PAK} ({PAK.stat().st_size:,} B) ver {major}.{minor}, {len(entries)} entries; "
      "all v0.8 payloads byte-verbatim, motlist decode-verified")

(FLUFFY / "modinfo.ini").write_text("""[Mod]
name=IRIS - House Cat Prototype
version=0.9.3-discriminator-old-body-plus-motlist
description=The proven v0.8 pak byte-for-byte (old v08 cat body) plus ONLY the 17-clip W3 motlist (bank 904). Diagnostic build: isolates the v09 mesh from the arm-crash. Supersedes v0.9/v0.9.1.
author=Aurora and Lyra and Iris
""", encoding="utf-8")
(FLUFFY / "README.txt").write_text("""IRIS House Cat Prototype v0.9.3 (discriminator)
===============================================
= the field-proven v0.8 pak byte-for-byte (OLD v08 cat body, old paw shape)
+ the 17-clip Witcher cat motlist (v8 retarget), bank 904.

If ARM house-cat mesh works on this build, the v09 mesh export is the
arm-crash culprit and gets fixed separately; animations are testable now.
Install via Fluffy (remove v0.9.1 first).
""", encoding="utf-8")
with zipfile.ZipFile(ZIP, "w", zipfile.ZIP_DEFLATED) as z:
    for f in sorted(FLUFFY.iterdir()):
        z.write(f, f.name)
print(f"zip: {ZIP} ({ZIP.stat().st_size:,} B)")
print("V092_PAK_OK")
