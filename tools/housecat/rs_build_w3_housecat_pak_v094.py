"""v0.9.4 pak: the proven v0.8 pak byte-verbatim + the POLISH W3 motlist
(axis-fixed + clavicle-pinned + paw-pinned) at the canonical pak path.

Aurora's call (08-18 evening): pak over loose -- easier to distribute and
Fluffy-toggleable, and it sidesteps the loose-file io weirdness entirely.
Ships ONE motlist: iris_housecat_full.motlist (polish content), replacing the
v0.9.3 pair (whose 'full' was the crashing pre-axis-fix CE original).

Surgical rebuild law (dd2-pak-header-40-law): header copied verbatim from the
field-proven v0.8 (4.1), untouched entries byte-for-byte, new entry deflate
codec 1 checksum 0, 16-byte alignment, full decode verification.
"""
from __future__ import annotations

import struct
import zipfile
import zlib
from pathlib import Path

RS = Path(r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework\rs_tools")
SOURCE = RS / "w3_housecat_fluffy_v0.8" / "IRIS_10_housecat_v08.pak"
MOTLIST_SRC = RS / "exports" / "w3_housecat_full_POLISH.motlist.751"
FLUFFY = RS / "w3_housecat_fluffy_v0.9.4"
PAK = FLUFFY / "IRIS_10_housecat_v094.pak"
ZIP = RS / "IRIS_HouseCat_Prototype_v0.9.4_FluffyMod.zip"

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


def deflate(raw: bytes) -> bytes:
    co = zlib.compressobj(9, zlib.DEFLATED, -15)
    return co.compress(raw) + co.flush()


src = SOURCE.read_bytes()
magic, major, minor, feature, count, fingerprint = HEADER.unpack_from(src, 0)
assert magic == PAK_MAGIC and (major, minor) == (4, 1)
toc = [ENTRY.unpack_from(src, HEADER.size + i * ENTRY.size) for i in range(count)]

man_key = (hash_utf16(MANIFEST_NAME.lower()), hash_utf16(MANIFEST_NAME.upper()))
entries = []
manifest_names = None
for lo, hi, off, packed, raw, attrs, ck in toc:
    blob = src[off:off + packed]
    if (lo, hi) == man_key:
        manifest_names = [n for n in zlib.decompress(blob, -15).decode("utf-8").splitlines() if n.strip()]
        continue
    entries.append((lo, hi, blob, raw, attrs, ck))
assert manifest_names is not None

motlist_raw = MOTLIST_SRC.read_bytes()
assert struct.unpack_from("<I", motlist_raw, 0)[0] == 751
entries.append((hash_utf16(MOTLIST_NAME.lower()), hash_utf16(MOTLIST_NAME.upper()),
                deflate(motlist_raw), len(motlist_raw), 1, 0))

new_names = [n for n in manifest_names if n.upper() != MANIFEST_NAME.upper()
             and n != MOTLIST_NAME] + [MOTLIST_NAME]
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

out = PAK.read_bytes()
o_toc = [ENTRY.unpack_from(out, HEADER.size + i * ENTRY.size) for i in range(len(entries))]
by_key = {(lo, hi): (off, packed, raw, attrs) for lo, hi, off, packed, raw, attrs, _ in o_toc}
for lo, hi, off, packed, raw, attrs, ck in toc:
    if (lo, hi) == man_key:
        continue
    o_off, o_packed, o_raw, o_attrs = by_key[(lo, hi)]
    assert out[o_off:o_off + o_packed] == src[off:off + packed], "v0.8 payload drift"
    assert (o_raw, o_attrs) == (raw, attrs)
mk = (hash_utf16(MOTLIST_NAME.lower()), hash_utf16(MOTLIST_NAME.upper()))
o_off, o_packed, o_raw, o_attrs = by_key[mk]
assert zlib.decompress(out[o_off:o_off + o_packed], -15) == motlist_raw
print(f"pak: {PAK} ({PAK.stat().st_size:,} B) ver {major}.{minor}, {len(entries)} entries; "
      "all v0.8 payloads byte-verbatim, polish motlist decode-verified")

(FLUFFY / "modinfo.ini").write_text("""[Mod]
name=IRIS - House Cat Prototype
version=0.9.4-polish-pak
description=W3 house cat: proven v0.8 body + the POLISH Witcher-3 motion catalogue (axis-fixed, clavicle-pinned, paw-pinned; bank 904, 17 clips). Supersedes every earlier version.
author=Aurora and Lyra and Iris
""", encoding="utf-8")
(FLUFFY / "README.txt").write_text("""IRIS House Cat Prototype v0.9.4 (polish pak)
============================================
= the field-proven v0.8 pak byte-for-byte (v08 cat body)
+ the 17-clip Witcher cat motion catalogue as iris_housecat_full.motlist
  (axis pair normalized, clavicle tracks pinned to rest, paw ground pins
  FK-verified), bank 904.

Install via Fluffy. REMOVE v0.9.3 first, and delete any leftover loose files
under <game>\\natives\\stm\\character\\ch\\iris_housecat\\ -- everything now
ships in this pak. PRIVATE USE ONLY (CDPR-ripped animation content).
""", encoding="utf-8")
with zipfile.ZipFile(ZIP, "w", zipfile.ZIP_DEFLATED) as z:
    for f in sorted(FLUFFY.iterdir()):
        z.write(f, f.name)
print(f"zip: {ZIP} ({ZIP.stat().st_size:,} B)")
print("V094_PAK_OK")
