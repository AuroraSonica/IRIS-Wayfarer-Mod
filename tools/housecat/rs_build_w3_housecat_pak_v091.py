"""v0.9.1 house-cat pak: surgical rebuild of the PROVEN v0.8 pak.

POST-MORTEM of v0.9: build_iris_pak's write_pak emits header version 4.0.
Every working content pak in this install (Capcom patches included) is 4.1 or
4.2; 4.0 appears only on Fluffy's empty placeholder stubs.  The engine ignored
the 4.0 pak, the mesh path went unservable, and arming the mesh hit the
documented create_resource instant-CTD class.  Lyra had already hit this once
(`w3_housecat_pak.v2-wrong-header-4.0.pak` in the graveyard).

So v0.9.1 never invents a header: it copies the field-proven v0.8 pak and
only
  - replaces the mesh entry with the v09 body,
  - adds the v8 W3 motlist entry,
  - rewrites the __MANIFEST accordingly (count 7 -> 8).
Untouched entries keep their exact bytes, codec and checksum.  New/changed
entries use deflate codec 1 (v0.8's own storage form) with checksum 0 (the
storage the field-proven horse_wwise rebuilds shipped with).
"""

from __future__ import annotations

import struct
import zipfile
import zlib
from pathlib import Path

RS = Path(r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework\rs_tools")
SOURCE = RS / "w3_housecat_fluffy_v0.8" / "IRIS_10_housecat_v08.pak"
STAGE = RS / "w3_housecat_pak_v09"
FLUFFY = RS / "w3_housecat_fluffy_v0.9.1"
PAK = FLUFFY / "IRIS_10_housecat_v091.pak"
ZIP = RS / "IRIS_HouseCat_Prototype_v0.9.1_FluffyMod.zip"

MESH_NAME = "natives/stm/character/ch/iris_housecat/iris_housecat.mesh.240423143"
MOTLIST_NAME = "natives/stm/character/ch/iris_housecat/iris_housecat_full.motlist.751"
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


def inflate(blob: bytes, attrs: int, raw_size: int) -> bytes:
    codec = attrs & 0xF
    if codec == 0:
        return blob
    if codec == 1:
        return zlib.decompress(blob, -15)
    raise ValueError(f"unsupported codec {codec} for this rebuild")


def deflate(raw: bytes) -> bytes:
    co = zlib.compressobj(9, zlib.DEFLATED, -15)
    return co.compress(raw) + co.flush()


# --- read the proven source pak -----------------------------------------
src = SOURCE.read_bytes()
magic, major, minor, feature, count, fingerprint = HEADER.unpack_from(src, 0)
assert magic == PAK_MAGIC and (major, minor) == (4, 1), "v0.8 source is not the proven 4.1 pak"
toc = [ENTRY.unpack_from(src, HEADER.size + i * ENTRY.size) for i in range(count)]
by_key = {(lo, hi): (off, packed, raw, attrs, ck) for lo, hi, off, packed, raw, attrs, ck in toc}

man_key = (hash_utf16(MANIFEST_NAME.lower()), hash_utf16(MANIFEST_NAME.upper()))
off, packed, raw, attrs, _ = by_key[man_key]
names = [n for n in inflate(src[off:off + packed], attrs, raw).decode("utf-8").splitlines() if n.strip()]
print("v0.8 manifest:", names)
assert len(names) == count, "manifest/count mismatch in source"

# --- assemble v0.9.1 entries --------------------------------------------
new_entries = []  # (name, blob, attrs, raw, checksum)
kept = replaced = 0
for name in names:
    if name.upper() == MANIFEST_NAME.upper():
        continue  # rebuilt below
    key = (hash_utf16(name.lower()), hash_utf16(name.upper()))
    off, packed, raw, attrs, ck = by_key[key]
    blob = src[off:off + packed]
    if name.lower() == MESH_NAME.lower():
        raw_bytes = (STAGE / MESH_NAME).read_bytes()
        new_entries.append((name, deflate(raw_bytes), 1, len(raw_bytes), 0))
        replaced += 1
    else:
        # must also byte-match our stage (same v0.7 material chain)
        stage_file = STAGE / name
        if stage_file.exists():
            assert inflate(blob, attrs, raw) == stage_file.read_bytes(), f"stage drift on {name}"
        new_entries.append((name, blob, attrs, raw, ck))
        kept += 1

motlist_bytes = (STAGE / MOTLIST_NAME).read_bytes()
new_entries.append((MOTLIST_NAME, deflate(motlist_bytes), 1, len(motlist_bytes), 0))

manifest_text = "\n".join([n for n, *_ in new_entries] + [MANIFEST_NAME]) + "\n"
manifest_raw = manifest_text.encode("utf-8")
new_entries.append((MANIFEST_NAME, deflate(manifest_raw), 1, len(manifest_raw), 0))

# --- write with the source's exact header (only count changes) ----------
FLUFFY.mkdir(exist_ok=True)
toc_size = ENTRY.size * len(new_entries)
cursor = HEADER.size + toc_size
cursor += (-cursor) % ALIGN
out_toc = []
with PAK.open("wb") as stream:
    stream.write(HEADER.pack(magic, major, minor, feature, len(new_entries), fingerprint))
    stream.write(bytes(toc_size))
    for name, blob, attrs, raw, ck in new_entries:
        out_toc.append((hash_utf16(name.lower()), hash_utf16(name.upper()),
                        cursor, len(blob), raw, attrs, ck))
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

# --- verification: header + every payload byte-exact --------------------
out = PAK.read_bytes()
o_magic, o_maj, o_min, o_feat, o_count, o_fp = HEADER.unpack_from(out, 0)
assert (o_magic, o_maj, o_min, o_feat, o_fp) == (magic, 4, 1, feature, fingerprint)
assert o_count == len(new_entries)
o_toc = [ENTRY.unpack_from(out, HEADER.size + i * ENTRY.size) for i in range(o_count)]
o_by_key = {(lo, hi): (off, packed, raw, attrs) for lo, hi, off, packed, raw, attrs, _ in o_toc}
for name, _blob, _attrs, raw_expect, _ck in new_entries:
    key = (hash_utf16(name.lower()), hash_utf16(name.upper()))
    off, packed, raw, attrs = o_by_key[key]
    decoded = inflate(out[off:off + packed], attrs, raw)
    assert len(decoded) == raw == raw_expect, f"size mismatch {name}"
    if name.lower() == MESH_NAME.lower():
        assert decoded == (STAGE / MESH_NAME).read_bytes(), "mesh mismatch"
    elif name.lower() == MOTLIST_NAME.lower():
        assert decoded == motlist_bytes, "motlist mismatch"
print(f"pak: {PAK} ({PAK.stat().st_size:,} B) ver 4.1, {o_count} entries "
      f"({kept} kept verbatim, {replaced} replaced, 2 new incl. manifest)")

(FLUFFY / "modinfo.ini").write_text("""[Mod]
name=IRIS - House Cat Prototype
version=0.9.1-w3-anims-v8-blend
description=V09 cat body (fixed shoulder binding, subdivided, smoothed weights) + the 17-clip Witcher cat motion catalogue (v8 retarget) as motlist bank 904. Rebuilt on the proven v0.8 pak header after the v0.9 4.0-header failure. Supersedes v0.1-v0.9.
author=Aurora and Lyra and Iris
""", encoding="utf-8")
(FLUFFY / "README.txt").write_text("""IRIS House Cat Prototype v0.9.1
===============================
Surgical rebuild of the proven v0.8 pak (header 4.1 kept verbatim):
- iris_housecat.mesh: v09 Witcher cat body (fixed shoulders, subdivided).
- iris_housecat_full.motlist: 17 Witcher cat clips (v8 retarget), bank 904.
- v0.7 brown-tabby material chain unchanged, byte-for-byte.

Install via Fluffy Mod Manager (remove v0.8/v0.9 first). In game:
Iris TAMING > House cat (IRIS companion):
1. ARM house-cat mesh, spawn the cat.
2. ARM W3 motion bank (v0.9 pak), Play W3 clip: takes 1-17.
""", encoding="utf-8")
with zipfile.ZipFile(ZIP, "w", zipfile.ZIP_DEFLATED) as z:
    for f in sorted(FLUFFY.iterdir()):
        z.write(f, f.name)
print(f"zip: {ZIP} ({ZIP.stat().st_size:,} B)")
print("V091_PAK_OK")
