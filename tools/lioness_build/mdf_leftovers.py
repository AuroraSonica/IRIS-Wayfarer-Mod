"""Did I miss a second copy of the material-name hash, or a leftover ch23_001 reference?

The +0x08 hash fix did not make the panther load, so either there is ANOTHER table keyed
on the old hash, or something else in the file still says ch23_001. Scan both files for:
  - every occurrence of each vanilla material-name hash (not just the entry header)
  - every remaining 'ch23_001' string in the patched file
  - a structural diff: which byte ranges did I actually change?
"""
import struct

VAN = r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\DD2_EXTRACT\re_chunk_000\natives\STM\character\ch\ch23_001\ch23_001.mdf2.40"
NEW = r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework\rs_tools\lioness_build\stage_panther\natives\stm\character\ch\ch23_002\ch23_002.mdf2.40"
a = open(VAN, "rb").read()
b = open(NEW, "rb").read()
print(f"vanilla {len(a)}  patched {len(b)}")

VAN_HASHES = {
    "ch23_001_body_mat": 0xd46abac4, "ch23_001_eye_mat": 0xd5e7e3b4,
    "ch23_001_head_mat": 0x63d256c7, "ch23_001_fur1_mat": 0x8130532e,
    "ch23_001_fur2_mat": 0x31f5e7c4,
}
print("\n=== occurrences of each VANILLA material-name hash ===")
for nm, h in VAN_HASHES.items():
    pat = struct.pack("<I", h)
    ia = [i for i in range(len(a) - 3) if a[i:i + 4] == pat]
    ib = [i for i in range(len(b) - 3) if b[i:i + 4] == pat]
    print(f"  {nm:<20} {h:08x}  vanilla@{[hex(x) for x in ia]}  "
          f"STILL IN PATCHED@{[hex(x) for x in ib]}")

print("\n=== remaining 'ch23_001' strings in the patched file ===")
needle = "ch23_001".encode("utf-16-le")
hits = []
i = 0
while True:
    i = b.find(needle, i)
    if i < 0:
        break
    hits.append(i)
    i += 2


def rstr(buf, off):
    # walk back to the start of this utf-16 string
    s = off
    while s >= 2 and buf[s - 1] == 0 and 0x20 <= buf[s - 2] < 0x7f:
        s -= 2
    out = []
    j = s
    while j + 1 < len(buf):
        c = buf[j] | (buf[j + 1] << 8)
        if c == 0:
            break
        out.append(chr(c))
        j += 2
    return "".join(out)


seen = set()
for h in hits:
    s = rstr(b, h)
    if s not in seen:
        seen.add(s)
        print(f"  0x{h:05x}  {s}")
if not hits:
    print("  none")

print("\n=== byte ranges changed vs vanilla ===")
runs = []
i = 0
n = min(len(a), len(b))
while i < n:
    if a[i] != b[i]:
        j = i
        while j < n and a[j] != b[j]:
            j += 1
        runs.append((i, j))
        i = j
    else:
        i += 1
print(f"  {len(runs)} differing runs")
for s, e in runs:
    kind = ""
    if e - s == 4:
        kind = f"  u32 {struct.unpack_from('<I', a, s)[0]:08x} -> " \
               f"{struct.unpack_from('<I', b, s)[0]:08x}"
    print(f"  0x{s:05x}..0x{e:05x} ({e-s} bytes){kind}")
