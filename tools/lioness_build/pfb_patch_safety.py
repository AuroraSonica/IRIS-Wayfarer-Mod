"""Is a same-length path swap in ch223001_01.pfb actually safe?

Two things can bite:
  (1) the path is stored MORE THAN ONCE (miss one and the engine loads vanilla)
  (2) a murmur3 hash of the path is stored next to it -- then the string is decorative
      and the engine resolves by hash, so patching the text changes nothing (or worse,
      desyncs). RE Engine RSZ resource tables normally store offsets, not hashes, but
      "normally" is not evidence.

Also diff the two prefabs so we can see exactly how Capcom itself varies _00 from _01.
"""
import os
import struct

BASE = (r"C:\Users\Krist\AppData\Local\Temp\claude"
        r"\D--SteamLibrary-steamapps-common-Dragons-Dogma-2-reframework"
        r"\5d0d2e8d-554c-45d9-a32f-5e5e2c7f9be9\scratchpad\catx\re_chunk_000"
        r"\natives\stm\appsystem\ch\ch223\prefab")
A = open(os.path.join(BASE, "ch223001_00.pfb.17"), "rb").read()
B = open(os.path.join(BASE, "ch223001_01.pfb.17"), "rb").read()

NEEDLE = "ch23_001".encode("utf-16-le")
for tag, d in (("_00", A), ("_01", B)):
    hits = []
    i = 0
    while True:
        i = d.find(NEEDLE, i)
        if i < 0:
            break
        hits.append(i)
        i += 2
    print(f"{tag}: 'ch23_001' appears {len(hits)} times at "
          + ", ".join(hex(h) for h in hits))

print("\n--- 64 bytes before the mesh path (0x640) in _01 ---")
for r in range(0x610, 0x648, 16):
    chunk = B[r:r + 16]
    print(f"  0x{r:04x}  " + " ".join(f"{c:02x}" for c in chunk)
          + "   " + "".join(chr(c) if 32 <= c < 127 else "." for c in chunk))

# a murmur3-32 of the ascii/utf16 path would show up as a 4-byte value somewhere; look for
# any u32 in the whole file equal to the common RE hashes of the path
def murmur3_32(data, seed=0xFFFFFFFF):
    c1, c2 = 0xcc9e2d51, 0x1b873593
    h = seed & 0xFFFFFFFF
    n = len(data) // 4 * 4
    for i in range(0, n, 4):
        k = struct.unpack_from("<I", data, i)[0]
        k = (k * c1) & 0xFFFFFFFF
        k = ((k << 15) | (k >> 17)) & 0xFFFFFFFF
        k = (k * c2) & 0xFFFFFFFF
        h ^= k
        h = ((h << 13) | (h >> 19)) & 0xFFFFFFFF
        h = (h * 5 + 0xe6546b64) & 0xFFFFFFFF
    k = 0
    tail = data[n:]
    for j, b in enumerate(tail):
        k |= b << (8 * j)
    if tail:
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


path = "Character/ch/ch23_001/ch23_001.mesh"
cands = {
    "utf16 lower": murmur3_32(path.lower().encode("utf-16-le")),
    "utf16 as-is": murmur3_32(path.encode("utf-16-le")),
    "ascii lower": murmur3_32(path.lower().encode()),
    "ascii as-is": murmur3_32(path.encode()),
}
allu32 = set()
for i in range(0, len(B) - 4):
    allu32.add(struct.unpack_from("<I", B, i)[0])
print("\n--- is a murmur3 of the mesh path stored anywhere in _01? ---")
for k, v in cands.items():
    print(f"   {k:<12} 0x{v:08x}  present_in_file={v in allu32}")

print("\n--- byte diff _00 vs _01 ---")
n = min(len(A), len(B))
runs = []
i = 0
while i < n:
    if A[i] != B[i]:
        j = i
        while j < n and A[j] != B[j]:
            j += 1
        runs.append((i, j))
        i = j
    else:
        i += 1
print(f"   sizes {len(A)} vs {len(B)} (delta {len(B)-len(A)}), {len(runs)} differing runs")
for a, b in runs[:12]:
    sa = A[a:b].decode("utf-16-le", "replace").replace("\x00", "")
    sb = B[a:b].decode("utf-16-le", "replace").replace("\x00", "")
    printable = all(32 <= c < 127 or c == 0 for c in A[a:b] + B[a:b])
    if printable and b - a > 4:
        print(f"   0x{a:06x}..0x{b:06x}  '{sa[:60]}' -> '{sb[:60]}'")
    else:
        print(f"   0x{a:06x}..0x{b:06x}  {A[a:b][:16].hex()} -> {B[a:b][:16].hex()}")
if len(runs) > 12:
    print(f"   ... {len(runs)-12} more")
