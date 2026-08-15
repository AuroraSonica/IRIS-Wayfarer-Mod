"""Dump every UTF-16 string in the two cat prefabs + the mibasecolor user file.

The decisive question for 'can the panther have its OWN mesh': does ch223001_01.pfb
reference ch23_001.mesh/mdf2 by path (in which case a same-length path patch redirects
it), or does it inherit them from somewhere else entirely?
"""
import os
import re
import struct

BASE = (r"C:\Users\Krist\AppData\Local\Temp\claude"
        r"\D--SteamLibrary-steamapps-common-Dragons-Dogma-2-reframework"
        r"\5d0d2e8d-554c-45d9-a32f-5e5e2c7f9be9\scratchpad\catx\re_chunk_000"
        r"\natives\stm\appsystem\ch\ch223")

FILES = [
    os.path.join(BASE, "prefab", "ch223001_00.pfb.17"),
    os.path.join(BASE, "prefab", "ch223001_01.pfb.17"),
    os.path.join(BASE, "001", "userdata", "ch223001_mibasecolor.user.2"),
]


def utf16_strings(d, minlen=4):
    out = []
    i = 0
    n = len(d)
    while i + 1 < n:
        if d[i + 1] == 0 and 0x20 <= d[i] < 0x7f:
            j = i
            chars = []
            while j + 1 < n and d[j + 1] == 0 and 0x20 <= d[j] < 0x7f:
                chars.append(chr(d[j]))
                j += 2
            if len(chars) >= minlen:
                out.append((i, "".join(chars)))
            i = j + 2
        else:
            i += 1
    return out


for p in FILES:
    d = open(p, "rb").read()
    print(f"\n================ {os.path.basename(p)}  ({len(d)} bytes)")
    ss = utf16_strings(d)
    print(f"  {len(ss)} utf-16 strings")
    for off, s in ss:
        low = s.lower()
        if any(k in low for k in ("mesh", "mdf2", "tex", "ch23_", "ch223", ".pfb",
                                 "material", "user", "motlist", "motbank")):
            print(f"   0x{off:06x}  {s}")

# the mibasecolor file is small -- also dump its float payload
p = FILES[2]
d = open(p, "rb").read()
print(f"\n=== {os.path.basename(p)} float scan (plausible colour values) ===")
for off in range(0, len(d) - 16, 4):
    v = struct.unpack_from("<4f", d, off)
    if all(0.0 <= x <= 4.0 for x in v) and any(x > 0.01 for x in v[:3]):
        print(f"   0x{off:04x}  {tuple(round(x,4) for x in v)}")
