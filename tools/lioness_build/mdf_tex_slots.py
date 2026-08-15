"""Resolve ch23_001.mdf2 texture SLOT -> FILE PATH properly.

The first dump printed slot names with empty paths, so the 0x20-byte texture entry stride
guess was wrong. Do it without guessing: index every utf-16 string by offset, then for each
texture entry scan its u64 fields and report the ones that land exactly on a known string.
Needed twice over -- to know which file feeds the eye shader, and to know exactly which
path strings to redirect when building ch23_002.mdf2.
"""
import struct

P = r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\DD2_EXTRACT\re_chunk_000\natives\STM\character\ch\ch23_001\ch23_001.mdf2.40"
d = open(P, "rb").read()
n = len(d)


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


# index every plausible utf-16 string start
strs = {}
i = 0
while i + 1 < n:
    if d[i + 1] == 0 and 0x20 <= d[i] < 0x7f:
        s = rstr(i)
        if len(s) >= 3:
            strs[i] = s
            i += 2 * len(s) + 2
            continue
    i += 1
print(f"{len(strs)} strings indexed")

matCount = struct.unpack_from("<H", d, 6)[0]
STRIDE = 0x64
BASE = 0x10
for m in range(matCount):
    b = BASE + m * STRIDE
    name = strs.get(struct.unpack_from("<Q", d, b)[0], "?")
    paramCount, texCount = struct.unpack_from("<II", d, b + 0x10)
    texTbl = struct.unpack_from("<Q", d, b + 0x3c)[0]
    print(f"\n=== [{m}] {name}   tex={texCount} texTbl=0x{texTbl:x}")
    if name != "ch23_001_eye_mat" and m > 1:
        continue
    for k in range(texCount):
        e = texTbl + k * 0x20
        fields = struct.unpack_from("<4Q", d, e)
        got = [strs.get(f) for f in fields]
        slot = next((g for g in got if g), "?")
        path = next((g for f, g in zip(fields, got) if g and g != slot), "")
        print(f"   {slot:<38} -> {path}")

print("\n=== every texture path referenced anywhere in this mdf2 ===")
seen = set()
for off, s in sorted(strs.items()):
    if "/" in s and ("tex" in s.lower() or "ch23" in s.lower()):
        if s not in seen:
            seen.add(s)
            print(f"   0x{off:05x}  {s}")
