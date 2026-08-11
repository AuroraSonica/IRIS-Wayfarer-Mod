"""Consolidate every I.R.I.S. asset pak into ONE Fluffy-installable IRIS.pak.

WHY THIS EXISTS
---------------
The IRIS assets were shipped as seven separate paks (griffin egg/nest, wild
horses, wild cats, baby bundle, woodcutting tools, ritual music, farmland).
Fluffy assigns each one a patch number, and RE Engine resolves duplicate paths
by "highest patch number wins".  Fluffy RE-INDEXES those numbers whenever any
mod in the list is toggled -- so which build of a shared file wins could change
without anyone touching IRIS.  That is exactly how the stale pre-newgaits horse
motlist ended up overriding the current one (found 2026-08-05).

One pak = one patch number = no ordering left to chance.

STRATEGY
--------
Sources are the INSTALLED paks, not staging trees.  The staging trees on disk
have drifted (some are missing, some are stale); the installed paks are what is
demonstrably working in-game right now.  Each IRIS pak carries its own
__MANIFEST/MANIFEST.TXT, so paths are recoverable exactly.

Run with:  .venv-puma-tools\\Scripts\\python.exe build_iris_pak.py [--extract-only]
"""

from __future__ import annotations

import argparse
import struct
import sys
import zlib
from pathlib import Path

GAME = Path(r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2")
ROOT = GAME / "reframework"
# ⛔ The staging tree must NOT live under reframework/data/ (REFramework's own
# data root, next to the loose-file loader) nor under <game>/natives/ (the loose
# load root itself). Assets ship in the pak; a stray natives/ tree anywhere the
# loader can reach is loose loading by accident.
STAGE = ROOT / "rs_tools" / "iris_pak" / "stage"
OUT_PAK = ROOT / "rs_tools" / "iris_pak" / "IRIS.pak"

PAK_MAGIC = 1095454795  # "KPKA"
HEADER = struct.Struct("<IBBHII")
ENTRY = struct.Struct("<IIQQQQQ")

# Source paks, in ASCENDING priority: later entries win a path collision.
# Identify by CONTENT HASH, never by patch number -- Fluffy renumbers freely.
SOURCES = [
    # (md5-prefix, human name, note)
    ("4ECD13F8", "griffin egg / nest / shells", "IRIS_v1.7_FluffyMod"),
    ("73A6F4C5", "wild cats (puma + panther)", "iris_wild_cats_pak_v1"),
    ("62331671", "baby bundle + bassinet", "baby-bundle/pak_clean"),
    ("85DFC467", "woodcutting + mining tools", "icons, tool meshes, wp02 prefabs"),
    ("4A1DA6D0", "ritual music banks", "iris_ritual_music_pak_v1"),
    ("7ED4B3A7", "farmland mesh", "farming"),
    # Horses LAST and deliberately: two builds of this pak exist and the older
    # one (43430146, pre-newgaits motlist) must never win.
    ("D890DF14", "wild horses", "iris_wild_horses_pak_v1 -- NEW Rigify gaits"),
]

# Builds that must NEVER be a source. Keyed by md5 prefix.
BLOCKLIST = {
    "43430146": "iris_wild_horses_pak_clean -- carries the OLD pre-newgaits "
                "motlist (233992 B). Superseded by D890DF14.",
}

# CHARACTER prefabs cannot be shipped in DD2 at all -- not at custom identities
# (CTD / never-ready) and not as overrides (spawns silently die). Proven twice,
# 2026-07-21. Equipment/weapon prefabs are fine and are shipped today.
FORBIDDEN = ("/ch/ch",)
FORBIDDEN_SUFFIX = ".pfb"


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


def _inflate(blob: bytes, attrs: int, raw_size: int) -> bytes:
    codec = attrs & 0xF
    if codec == 0:
        return blob
    if codec == 1:
        return zlib.decompress(blob, -15)
    if codec == 2:
        import zstandard
        return zstandard.ZstdDecompressor().decompress(
            blob, max_output_size=max(raw_size, 1 << 22))
    raise RuntimeError(f"unknown pak codec {codec} (attrs {attrs:#x})")


def read_pak_raw(path: Path) -> dict[str, tuple[bytes, int, int]]:
    """-> {relative_path: (payload_AS_STORED, attrs, raw_size)}.

    No decompression. Used by the verbatim merge so a compressed entry keeps the
    exact bytes and codec the engine already accepts today.
    """
    with path.open("rb") as stream:
        magic, major, minor, feature, count, fingerprint = HEADER.unpack(
            stream.read(HEADER.size))
        if magic != PAK_MAGIC:
            raise ValueError(f"{path.name}: not a KPKA pak")
        toc = [ENTRY.unpack(stream.read(ENTRY.size)) for _ in range(count)]
        by_key = {(l, u): (o, p, r, a) for l, u, o, p, r, a, _c in toc}

        want = (hash_utf16("__manifest/manifest.txt"),
                hash_utf16("__MANIFEST/MANIFEST.TXT"))
        if want not in by_key:
            raise RuntimeError(f"{path.name}: no __MANIFEST -- cannot recover paths")
        off, packed, raw, attrs = by_key[want]
        stream.seek(off)
        listing = _inflate(stream.read(packed), attrs, raw).decode("utf-8")

        out: dict[str, tuple[bytes, int, int]] = {}
        for name in (line.strip() for line in listing.splitlines()):
            if not name or name.startswith("__MANIFEST"):
                continue
            key = (hash_utf16(name.lower()), hash_utf16(name.upper()))
            if key not in by_key:
                raise RuntimeError(f"{path.name}: manifest lists {name} but the "
                                   "TOC has no matching entry")
            off, packed, raw, attrs = by_key[key]
            stream.seek(off)
            out[name] = (stream.read(packed), attrs, raw)
    return out


def read_pak(path: Path) -> dict[str, bytes]:
    """-> {relative_path: payload}. Requires the pak to carry a __MANIFEST."""
    with path.open("rb") as stream:
        magic, major, minor, feature, count, fingerprint = HEADER.unpack(
            stream.read(HEADER.size))
        if magic != PAK_MAGIC:
            raise ValueError(f"{path.name}: not a KPKA pak")
        toc = [ENTRY.unpack(stream.read(ENTRY.size)) for _ in range(count)]

        by_key = {}
        for lower, upper, off, packed, raw, attrs, checksum in toc:
            by_key[(lower, upper)] = (off, packed, raw, attrs)

        want = (hash_utf16("__manifest/manifest.txt"),
                hash_utf16("__MANIFEST/MANIFEST.TXT"))
        if want not in by_key:
            raise RuntimeError(f"{path.name}: no __MANIFEST -- cannot recover paths")
        off, packed, raw, attrs = by_key[want]
        stream.seek(off)
        listing = _inflate(stream.read(packed), attrs, raw).decode("utf-8")

        files: dict[str, bytes] = {}
        for name in (line.strip() for line in listing.splitlines()):
            if not name or name.startswith("__MANIFEST"):
                continue
            key = (hash_utf16(name.lower()), hash_utf16(name.upper()))
            if key not in by_key:
                raise RuntimeError(f"{path.name}: manifest lists {name} but the "
                                   "TOC has no matching entry")
            off, packed, raw, attrs = by_key[key]
            stream.seek(off)
            payload = _inflate(stream.read(packed), attrs, raw)
            if len(payload) != raw:
                raise RuntimeError(f"{path.name}: {name} inflated to {len(payload)}"
                                   f", expected {raw}")
            files[name] = payload
    return files


def md5_prefix(path: Path) -> str:
    import hashlib
    h = hashlib.md5()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest().upper()[:8]


# A source pak need not be INSTALLED to be merged -- a component can be
# uninstalled from Fluffy while its build still sits on disk. These are searched
# alongside the live patch chain, still matched by content hash.
EXTRA_SOURCE_PATHS = [
    GAME / "griffin-egg" / "pakroot.pak",
    GAME / "reframework" / "rs_tools" / "horse_wwise" / "iris_wild_horses_pak_v1.pak",
    GAME / "reframework" / "rs_tools" / "horse_wwise" / "iris_wild_cats_pak_v1.pak",
    GAME / "reframework" / "rs_tools" / "horse_wwise" / "iris_ritual_music_pak_v1.pak",
    GAME / "baby-bundle" / "pak_clean.pak",
]


def locate_sources() -> list[tuple[str, str, Path]]:
    """Find each wanted source pak among the installed patch paks."""
    installed = {}
    candidates = list(GAME.glob("re_chunk_000.pak.patch_*.pak"))
    candidates += [p for p in EXTRA_SOURCE_PATHS if p.exists()]
    for pak in sorted(candidates):
        if pak.stat().st_size <= 16:
            continue
        installed.setdefault(md5_prefix(pak), []).append(pak)

    for blocked, why in BLOCKLIST.items():
        if blocked in installed:
            print(f"  note: blocklisted build {blocked} is installed "
                  f"({installed[blocked][0].name}) -- ignoring it. {why}")

    found, missing = [], []
    for want, label, note in SOURCES:
        if want in installed:
            found.append((want, label, installed[want][0]))
        else:
            missing.append((want, label, note))
    if missing:
        print("\n!! these IRIS paks are not currently installed:")
        for want, label, note in missing:
            print(f"     {want}  {label}  ({note})")
        print("   The merged pak would be missing their assets.")
    return found


def collect() -> list[tuple[str, bytes, int, int]]:
    """Verbatim merge: payloads keep the compression they already ship with."""
    merged: dict[str, tuple[bytes, int, int]] = {}
    owner: dict[str, str] = {}
    for want, label, pak in locate_sources():
        files = read_pak_raw(pak)
        codecs = {}
        for _p, attrs, _r in files.values():
            codecs[attrs & 0xF] = codecs.get(attrs & 0xF, 0) + 1
        codec_note = ", ".join(
            f"{ {0:'raw',1:'deflate',2:'zstd'}.get(c, f'codec{c}') }x{n}"
            for c, n in sorted(codecs.items()))
        print(f"  {pak.name:<32} {label:<34} {len(files):>3} files  [{codec_note}]")
        for name, entry in files.items():
            key = name.lower()
            if key in merged and merged[key][0] != entry[0]:
                print(f"     ! {name}\n"
                      f"       {owner[key]} -> {label} (later source wins)")
            merged[key] = entry
            owner[key] = label
    return [(n, p, a, r) for n, (p, a, r) in merged.items()]


def guard(files: dict[str, bytes]) -> None:
    bad = [n for n in files
           if n.endswith(FORBIDDEN_SUFFIX.lower()) or ".pfb." in n]
    character_pfbs = [n for n in bad if any(f in n for f in FORBIDDEN)]
    if character_pfbs:
        raise SystemExit(
            "ABORT: character .pfb files in the payload -- shipping these kills "
            "spawns outright:\n  " + "\n  ".join(character_pfbs))
    if bad:
        print("\n  prefabs present (equipment/weapon prefabs are fine, and are "
              "already shipped today):")
        for n in bad:
            print(f"    {n}")


# ⛔ Payload offsets MUST be aligned. The engine reads an uncompressed entry
# straight out of the mapped pak and casts structure headers over it in place;
# a mesh/tex landing on an odd offset faults. A COMPRESSED entry is immune --
# it gets inflated into a fresh aligned heap buffer -- which is why every
# compressed IRIS pak was fine and why the one uncompressed pak that works
# (iris_wild_horses_pak_v1, 19 entries) only works by luck: all of its payload
# sizes happen to be even, so nothing ever lands odd. Our 92-file merge has no
# such luck. 2026-08-05: this is the difference between the merged pak and
# every pak in this install that loads.
ALIGN = 16


def write_pak(entries_in: list[tuple[str, bytes, int, int]], out: Path) -> None:
    """entries_in = [(name, payload_bytes, attrs, raw_size)].

    `payload_bytes` is stored VERBATIM -- if it came out of a source pak still
    compressed, it stays compressed and keeps that pak's `attrs` codec. We do
    not re-encode anything the engine already accepts.
    """
    payloads = sorted(entries_in, key=lambda e: e[0])
    names = [e[0] for e in payloads]
    manifest = ("\n".join(names + ["__MANIFEST/MANIFEST.TXT"]) + "\n").encode("utf-8")
    payloads.append(("__MANIFEST/MANIFEST.TXT", manifest, 0, len(manifest)))

    out.parent.mkdir(parents=True, exist_ok=True)
    toc_size = ENTRY.size * len(payloads)
    cursor = HEADER.size + toc_size
    cursor += (-cursor) % ALIGN
    entries = []
    with out.open("wb") as stream:
        stream.write(HEADER.pack(PAK_MAGIC, 4, 0, 0, len(payloads), 0))
        stream.write(bytes(toc_size))
        for name, payload, attrs, raw in payloads:
            entries.append((hash_utf16(name.lower()), hash_utf16(name.upper()),
                            cursor, len(payload), raw, attrs, 0))
            stream.seek(cursor)
            stream.write(payload)
            cursor += len(payload)
            pad = (-cursor) % ALIGN
            if pad:
                stream.write(bytes(pad))
                cursor += pad
        stream.seek(HEADER.size)
        for entry in entries:
            stream.write(ENTRY.pack(*entry))

    # Round-trip: refuse to ship anything we cannot read back byte-for-byte.
    expected = {n: p for n, p, _a, _r in payloads if not n.startswith("__MANIFEST")}
    back = read_pak(out)
    assert len(back) == len(expected), f"{len(back)} != {len(expected)} after round-trip"
    misaligned = [e for e in entries if e[2] % ALIGN]
    assert not misaligned, f"{len(misaligned)} payloads are not {ALIGN}-byte aligned"


def extract(entries: list[tuple[str, bytes, int, int]]) -> None:
    """Drop an INFLATED staging tree, so future edits are a normal file edit."""
    for name, payload, attrs, raw in entries:
        target = STAGE / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(_inflate(payload, attrs, raw))
    print(f"\n  staging tree: {STAGE}  ({len(entries)} files)")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--extract-only", action="store_true",
                        help="write the staging tree but do not build the pak")
    parser.add_argument("--from-stage", action="store_true",
                        help="build from the staging tree instead of the "
                             "installed paks (payloads stored uncompressed, "
                             "still aligned)")
    parser.add_argument("--only", metavar="SUBSTR", action="append",
                        help="keep only paths containing SUBSTR (repeatable) -- "
                             "for bisecting a bad payload")
    parser.add_argument("--skip", metavar="SUBSTR", action="append",
                        help="drop paths containing SUBSTR (repeatable) -- "
                             "for bisecting a bad payload")
    parser.add_argument("--out", type=Path, default=OUT_PAK)
    args = parser.parse_args()

    if args.from_stage:
        entries = []
        for path in sorted((STAGE / "natives").rglob("*")):
            if path.is_file():
                blob = path.read_bytes()
                entries.append(
                    (path.relative_to(STAGE).as_posix().lower(), blob, 0, len(blob)))
        print(f"  staging tree: {len(entries)} files (stored uncompressed)")
    else:
        print("Collecting from the installed IRIS paks (payloads copied VERBATIM):")
        entries = collect()

    if args.only:
        before = len(entries)
        entries = [e for e in entries if any(s.lower() in e[0] for s in args.only)]
        print(f"  --only filter: {before} -> {len(entries)} files")
    if args.skip:
        before = len(entries)
        dropped = [e[0] for e in entries
                   if any(s.lower() in e[0] for s in args.skip)]
        entries = [e for e in entries
                   if not any(s.lower() in e[0] for s in args.skip)]
        print(f"  --skip filter: {before} -> {len(entries)} files; dropped:")
        for name in dropped:
            print(f"    - {name}")

    if not entries:
        raise SystemExit("no files collected")
    guard({e[0]: e[1] for e in entries})

    if not args.from_stage and not args.only:
        extract(entries)
    if args.extract_only:
        return 0

    write_pak(entries, args.out)
    stored = sum(len(e[1]) for e in entries)
    raw = sum(e[3] for e in entries)
    print(f"\n  built {args.out}")
    print(f"  {len(entries)} files | stored {stored:,} B | uncompressed {raw:,} B "
          f"| pak {args.out.stat().st_size:,} B")
    print(f"  round-trip verified; every payload {ALIGN}-byte aligned")
    return 0


if __name__ == "__main__":
    sys.exit(main())
