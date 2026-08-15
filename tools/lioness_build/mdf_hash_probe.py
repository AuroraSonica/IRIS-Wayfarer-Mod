"""Does an mdf2 material entry store a HASH of its own name / its texture paths?

If it does, my byte patch renamed the STRINGS and left the hashes pointing at the old
names -- the material would then be unresolvable, the mdf2 would fail to load, the panther
prefab would never reach get_Ready, and IrisWildCats would report exactly what Aurora
sees: "Resources: puma true | panther false".

Test it against VANILLA: compute murmur3 of each known material name / texture path in
several encodings and look for those values in the material entry's header words.
"""
import struct

P = r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\DD2_EXTRACT\re_chunk_000\natives\STM\character\ch\ch23_001\ch23_001.mdf2.40"
d = open(P, "rb").read()
n = len(d)


def murmur3_32(data, seed=0xFFFFFFFF):
    c1, c2 = 0xcc9e2d51, 0x1b873593
    h = seed & 0xFFFFFFFF
    ln = len(data) // 4 * 4
    for i in range(0, ln, 4):
        k = struct.unpack_from("<I", data, i)[0]
        k = (k * c1) & 0xFFFFFFFF
        k = ((k << 15) | (k >> 17)) & 0xFFFFFFFF
        k = (k * c2) & 0xFFFFFFFF
        h ^= k
        h = ((h << 13) | (h >> 19)) & 0xFFFFFFFF
        h = (h * 5 + 0xe6546b64) & 0xFFFFFFFF
    k = 0
    for j, b in enumerate(data[ln:]):
        k |= b << (8 * j)
    if data[ln:]:
        k = (k * c1) & 0xFFFFFFFF
        k = ((k << 15) | (k >> 17)) & 0xFFFFFFFF
        k = (k * c2) & 0xFFFFFFFF
        h ^= k
    h ^= len(data)
    h ^= h >> 16
    h = (h * 0x85ebca6b) & 0xFFFFFFFF
    h ^= h >> 13
    h = (h * 0xc2b2ae35) & 0xFFFFFFFF
    h ^= h >> 16
    return h


def variants(s):
    return {
        "utf16le": murmur3_32(s.encode("utf-16-le")),
        "utf16le_lower": murmur3_32(s.lower().encode("utf-16-le")),
        "ascii": murmur3_32(s.encode()),
        "ascii_lower": murmur3_32(s.lower().encode()),
    }


def rstr(off):
    out = []
    i = off
    while i + 1 < n:
        c = d[i] | (d[i + 1] << 8)
        if c == 0:
            break
        out.append(chr(c))
        i += 2
    return "".join(out)


matCount = struct.unpack_from("<H", d, 6)[0]
STRIDE, BASE = 0x64, 0x10
print(f"matCount={matCount}\n")
for m in range(matCount):
    b = BASE + m * STRIDE
    name = rstr(struct.unpack_from("<Q", d, b)[0])
    words = struct.unpack_from("<13I", d, b)      # first 0x34 bytes as u32s
    print(f"=== [{m}] {name}")
    print("    header u32s: " + " ".join(f"{w:08x}" for w in words))
    v = variants(name)
    for k, h in v.items():
        hits = [i for i, w in enumerate(words) if w == h]
        if hits:
            print(f"    *** MATCH {k} = {h:08x} at u32 index {hits} "
                  f"(offset b+0x{hits[0]*4:02x})")
    if not any(w in v.values() for w in words):
        print(f"    (no name hash in the entry header; candidates were "
              + ", ".join(f"{k}={h:08x}" for k, h in v.items()) + ")")

# and the texture entries
print("\n=== texture entry words vs path hashes (material 0) ===")
b = BASE
texCount = struct.unpack_from("<I", d, b + 0x14)[0]
texTbl = struct.unpack_from("<Q", d, b + 0x3c)[0]
for k in range(min(texCount, 3)):
    e = texTbl + k * 0x20
    f4 = struct.unpack_from("<4Q", d, e)
    slot = rstr(f4[0]) if 0 < f4[0] < n else "?"
    path = rstr(f4[1]) if 0 < f4[1] < n else "?"
    print(f"  slot={slot} path={path}")
    print(f"    raw u64s: " + " ".join(f"{x:016x}" for x in f4))
    for label, s in (("slot", slot), ("path", path)):
        for kk, hh in variants(s).items():
            for idx, x in enumerate(f4):
                lo, hi = x & 0xFFFFFFFF, x >> 32
                if lo == hh or hi == hh:
                    print(f"    *** {label} hash {kk}={hh:08x} found in u64[{idx}]")
