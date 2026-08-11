"""Build the FIXED wild-horses pak: the proven 'clean' pak verbatim, with ONLY
the motlist entry replaced by the new Rigify-gaits build.

WHY: 2026-08-05 forensics — `sdk.create_resource("via.render.MeshMaterialResource",
"character/ch/ch99_011/horse.mdf2")` kills the engine (c000001d, 3 ms) whenever
horse.mdf2 is served RAW from a hand-built pak; served zstd-COMPRESSED (as the
old Fluffy-era pak did) it worked for weeks. The engine parses a raw mdf2 in
place from the mapped pak; a compressed one is inflated into a fresh heap
buffer first. So: keep every entry of the WORKING pak byte-for-byte (payloads,
attrs, checksums — the toolchain that wrote those checksums is newer than the
one on disk, so we clone rather than rebuild), and swap only the motlist,
stored raw (raw+checksum0 is field-proven for non-mdf classes).

Output: IRIS_01_wild_horses.pak next to this script, ready for the multipak.
"""
from __future__ import annotations

import struct
import zlib
from pathlib import Path

GAME = Path(r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2")
CLEAN = GAME / "reframework" / "rs_tools" / "horse_wwise" / "iris_wild_horses_pak_clean.pak"
NEW_MOTLIST = GAME / "reframework" / "rs_tools" / "exports" / "horse_doe_locomotion.motlist.751"
MOTLIST_PATH = "natives/stm/character/ch/ch99_011/horse_locomotion.motlist.751"
OUT = Path(__file__).parent / "IRIS_01_wild_horses.pak"

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


def inflate(blob: bytes, attrs: int, raw: int) -> bytes:
    codec = attrs & 0xF
    if codec == 0:
        return blob
    if codec == 1:
        return zlib.decompress(blob, -15)
    if codec == 2:
        import zstandard
        return zstandard.ZstdDecompressor().decompress(
            blob, max_output_size=max(raw, 1 << 22))
    raise RuntimeError(f"unknown codec {codec}")


def main() -> int:
    new_motlist = NEW_MOTLIST.read_bytes()
    assert len(new_motlist) == 250856, f"unexpected motlist size {len(new_motlist)}"

    with CLEAN.open("rb") as fh:
        magic, major, minor, feature, count, fp = HEADER.unpack(fh.read(HEADER.size))
        assert magic == PAK_MAGIC
        toc = [ENTRY.unpack(fh.read(ENTRY.size)) for _ in range(count)]
        by_key = {}
        payloads = {}
        for lower, upper, off, packed, raw, attrs, checksum in toc:
            fh.seek(off)
            by_key[(lower, upper)] = (packed, raw, attrs, checksum)
            payloads[(lower, upper)] = fh.read(packed)

    # recover paths via the manifest
    mkey = (hash_utf16("__manifest/manifest.txt"), hash_utf16("__MANIFEST/MANIFEST.TXT"))
    packed, raw, attrs, _cs = by_key[mkey]
    names = [n for n in inflate(payloads[mkey], attrs, raw).decode("utf-8").splitlines()
             if n.strip() and not n.startswith("__MANIFEST")]
    assert len(names) == count - 1, f"{len(names)} names vs {count} entries"

    mot_key = (hash_utf16(MOTLIST_PATH.lower()), hash_utf16(MOTLIST_PATH.upper()))
    assert mot_key in by_key, "motlist entry not found in the clean pak"

    entries = []
    for name in sorted(names):
        key = (hash_utf16(name.lower()), hash_utf16(name.upper()))
        packed, raw, attrs, checksum = by_key[key]
        if key == mot_key:
            # The ONE change: new motlist. ⛔ NOT raw — raw-served .motlist
            # crashed on first horse conversion (2026-08-05, ox fields), same
            # in-place-parse law as the mdf2. zstd like its neighbours;
            # checksum 0 (algorithm unknown; two community packers ship 0 and
            # the soft failure mode is a nil resource, not a crash).
            import zstandard
            packed_motlist = zstandard.ZstdCompressor().compress(new_motlist)
            entries.append((name, packed_motlist, 2, len(new_motlist), 0,
                            "REPLACED (new gaits, zstd, cs=0)"))
        else:
            entries.append((name, payloads[key], attrs, raw, checksum, "verbatim"))

    manifest = ("\n".join([e[0] for e in entries] + ["__MANIFEST/MANIFEST.TXT"]) + "\n").encode()
    entries.append(("__MANIFEST/MANIFEST.TXT", manifest, 0, len(manifest), 0, "manifest"))

    toc_size = ENTRY.size * len(entries)
    cursor = HEADER.size + toc_size
    cursor += (-cursor) % ALIGN
    out_toc = []
    with OUT.open("wb") as fh:
        fh.write(HEADER.pack(PAK_MAGIC, 4, 0, 0, len(entries), 0))
        fh.write(bytes(toc_size))
        for name, payload, attrs, raw, checksum, note in entries:
            out_toc.append((hash_utf16(name.lower()), hash_utf16(name.upper()),
                            cursor, len(payload), raw, attrs, checksum))
            fh.seek(cursor)
            fh.write(payload)
            cursor += len(payload)
            pad = (-cursor) % ALIGN
            if pad:
                fh.write(bytes(pad))
                cursor += pad
            print(f"  {name:<70} attrs={attrs:#x} cs={'set' if checksum else '0'}  {note}")
        fh.seek(HEADER.size)
        for entry in out_toc:
            fh.write(ENTRY.pack(*entry))

    # verify: every verbatim entry inflates to its declared size
    with OUT.open("rb") as fh:
        _, _, _, _, n, _ = HEADER.unpack(fh.read(HEADER.size))
        vtoc = [ENTRY.unpack(fh.read(ENTRY.size)) for _ in range(n)]
        for lower, upper, off, packed, raw, attrs, checksum in vtoc:
            fh.seek(off)
            blob = inflate(fh.read(packed), attrs, raw)
            assert len(blob) == raw, f"entry {lower:#x} inflates to {len(blob)} != {raw}"
            assert off % ALIGN == 0

    print(f"\nbuilt {OUT}  ({OUT.stat().st_size:,} B, {len(entries)} entries)")
    print("mdf2 served exactly as the proven pak served it (zstd + original checksum)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
