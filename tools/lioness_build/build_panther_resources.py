"""Build ch23_002.mdf2 and the redirected ch223001_01.pfb -- BYTE PATCHES ONLY.

⛔ NEVER RE-SERIALISE AN MDF2 (the law from the horse/material work). Both files here are
offset-table driven: every string is referenced by an absolute u64 offset stored elsewhere
in the file, so changing ANY string's length shifts the whole table and corrupts it. Every
edit below is therefore a SAME-LENGTH overwrite, which moves nothing:
    ch23_001  ->  ch23_002        (8 chars -> 8 chars)
Float params are overwritten in place in the value buffer, also same-length.

⛔ THE PATH APPEARS TWICE IN THE PREFAB. ch223001_01.pfb stores the mesh path at 0x640
AND again near 0x63f2 (a second resource table). Patching only the first occurrence would
half-redirect the panther and it would silently load the vanilla lioness mesh. Replace
every occurrence of the FULL path string -- but leave 13_ch23_001_Ref.pfb alone, that is
an unrelated VFX prefab which must keep pointing at the real thing.

⛔ AND DO NOT BLANKET-REPLACE ch23_001 IN THE MDF2. Only the seven textures we actually
ship exist under ch23_002; head/fur/angryhead/EMFX must keep resolving to the vanilla
ch23_001 files or the panther loses them entirely.
"""
import os
import struct
import shutil

VAN_MDF = r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\DD2_EXTRACT\re_chunk_000\natives\STM\character\ch\ch23_001\ch23_001.mdf2.40"
PFB_IN = (r"C:\Users\Krist\AppData\Local\Temp\claude"
          r"\D--SteamLibrary-steamapps-common-Dragons-Dogma-2-reframework"
          r"\5d0d2e8d-554c-45d9-a32f-5e5e2c7f9be9\scratchpad\catx\re_chunk_000"
          r"\natives\stm\appsystem\ch\ch223\prefab\ch223001_01.pfb.17")
OUT = r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework\rs_tools\lioness_build"
STAGE = os.path.join(OUT, "stage_panther")

# ⭐ AURORA ASKED FOR YELLOW. Vanilla eye_mat is Emissive_Color1 (1.0, 0.4, 0.0) -- that
# is ORANGE, and so was the old Lua override (5.0, 2.2, 0.04) whose hue normalises to
# G/R = 0.44. A convincing yellow needs G/R near 0.8. Emissive_Intensity is already 8.2.
YELLOW1 = (2.20, 1.70, 0.08, 1.0)
YELLOW2 = (2.00, 1.45, 0.05, 1.0)

# the seven textures the panther actually ships
REDIRECT_TEX = ["body_ALBD", "body_NRMR", "body_ATOC", "bodypattern_MSKM",
                "eye_ALBE", "eye_NRMR", "eye_EMMS"]

# ⛔⛔ DO NOT RENAME THE MATERIALS. MINIMISE THE DIFF UNTIL THE PANTHER LOADS AT ALL.
# The panther chassis has never once reached get_Ready since its prefab was redirected,
# and three things changed at the same time: the prefab paths, the mdf2 material NAMES
# (with their +0x08 murmur3 hashes), and the mesh's embedded material names. Fixing the
# hashes did not help, so keeping three novel things in play is just guessing faster.
#
# Materials resolve by hash, so renaming buys us NOTHING now that IrisWildCats'
# recolour is gated off (recolour_panther_material = false) -- the only reason to rename
# was to stop that table matching. Keep the vanilla names, and the panther's mesh becomes
# a byte-identical copy of the lioness's. Then the ONLY difference between a working puma
# and a broken panther is the redirected prefab and the texture paths, which is a diff
# small enough to reason about.
MAT_NAMES = []            # <- deliberately empty; see above
EYE_MAT = "ch23_001_eye_mat"


def u16(s):
    return s.encode("utf-16-le")


def patch_all(raw, old, new, label, expect=None):
    a, b = u16(old), u16(new)
    assert len(a) == len(b), f"LENGTH CHANGE for {label}: {old!r} -> {new!r}"
    n = raw.count(a)
    if expect is not None and n != expect:
        print(f"   !! {label}: found {n} occurrences, expected {expect}")
    raw[:] = bytearray(bytes(raw).replace(a, b))
    print(f"   {label:<52} x{n}")
    return n


# ============================================================ ch23_002.mdf2
d = bytearray(open(VAN_MDF, "rb").read())
orig_len = len(d)
print("=== ch23_002.mdf2 ===")
for t in REDIRECT_TEX:
    patch_all(d, f"Character/ch/ch23_001/ch23_001_{t}.tex",
              f"Character/ch/ch23_002/ch23_002_{t}.tex", f"tex {t}", expect=1)
for m in MAT_NAMES:
    patch_all(d, f"ch23_001_{m}", f"ch23_002_{m}", f"material {m}", expect=1)
assert len(d) == orig_len, "mdf2 changed size -- offsets are now wrong"


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
    for j, bb in enumerate(data[ln:]):
        k |= bb << (8 * j)
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


# ---- eye_mat emissive colours, overwritten in place in the value buffer ----
n = len(d)


def rstr(buf, off):
    out = []
    i = off
    while i + 1 < len(buf):
        c = buf[i] | (buf[i + 1] << 8)
        if c == 0:
            break
        out.append(chr(c))
        i += 2
    return "".join(out)


matCount = struct.unpack_from("<H", d, 6)[0]

# ⛔⛔⛔ RENAMING A MATERIAL IN AN MDF2 MEANS REWRITING ITS HASH. THIS COST A FIELD ROUND
# TRIP. Each material entry stores murmur3_32(name.encode('utf-16-le')) at entry+0x08,
# and the ENGINE RESOLVES MATERIALS BY THAT HASH, not by the string. Renaming only the
# string pool left all six materials unresolvable, so ch23_002.mdf2 failed to load, so the
# panther prefab never reached get_Ready -- and IrisWildCats reported exactly that:
# "Resources: puma true | panther false", with force-PANTHER falling through to a vanilla
# wolf. Verified against vanilla: ch23_001_body_mat -> d46abac4 sits at +0x08.
# (Texture SLOT names are hashed the same way inside their entry, but texture PATHS are a
# bare offset with no hash -- u64[3] is 0 -- which is why the path redirects worked.)
for m in range(matCount):
    b = 0x10 + m * 0x64
    nm = rstr(d, struct.unpack_from("<Q", d, b)[0])
    old = struct.unpack_from("<I", d, b + 0x08)[0]
    new = murmur3_32(nm.encode("utf-16-le"))
    if old != new:
        struct.pack_into("<I", d, b + 0x08, new)
        print(f"   name hash {nm:<22} {old:08x} -> {new:08x}")
    else:
        print(f"   name hash {nm:<22} {old:08x} (unchanged)")

done = 0
for m in range(matCount):
    b = 0x10 + m * 0x64
    name = rstr(d, struct.unpack_from("<Q", d, b)[0])
    if name != EYE_MAT:
        continue
    paramCount = struct.unpack_from("<I", d, b + 0x10)[0]
    paramTbl = struct.unpack_from("<Q", d, b + 0x34)[0]
    valBuf = struct.unpack_from("<Q", d, b + 0x4c)[0]
    for i in range(paramCount):
        e = paramTbl + i * 24
        pn = rstr(d, struct.unpack_from("<Q", d, e)[0])
        voff, comp = struct.unpack_from("<II", d, e + 16)
        # ⛔ KILL THE PERMANENT GLOW (Aurora: "the panther's eyes are glowing brightly
        # yellow, I don't think they should be glowing"). Vanilla ships eye_mat with
        # Emissive_Enable 1.0 / Intensity 8.2, but on a normal cat app.EyeGlowController
        # MODULATES that -- it is what makes monster eyes light up only at night/aggro.
        # Our runtime set_Material has to latch that controller off (its cached material
        # accessors dangle across the swap and its next onUpdate is a c0000005), so nothing
        # is left to turn the emissive down and it burns at full strength forever.
        # The iris is PAINTED gold in ch23_002_eye_ALBE, so the colour survives without it.
        if pn == "Emissive_Enable" and comp == 1:
            was = struct.unpack_from("<f", d, valBuf + voff)[0]
            struct.pack_into("<f", d, valBuf + voff, 0.0)
            print(f"   Emissive_Enable {was} -> 0.0  (no permanent glow)")
            done += 1
        elif pn == "Emissive_Color1" and comp == 4:
            was = struct.unpack_from("<4f", d, valBuf + voff)
            struct.pack_into("<4f", d, valBuf + voff, *YELLOW1)
            print(f"   Emissive_Color1 {tuple(round(x,3) for x in was)} -> {YELLOW1}")
            done += 1
        elif pn == "Emissive_Color2" and comp == 4:
            was = struct.unpack_from("<4f", d, valBuf + voff)
            struct.pack_into("<4f", d, valBuf + voff, *YELLOW2)
            print(f"   Emissive_Color2 {tuple(round(x,3) for x in was)} -> {YELLOW2}")
            done += 1
assert done == 3, f"patched {done} emissive fields, expected 3"
assert len(d) == orig_len

mdf_dir = os.path.join(STAGE, "natives", "stm", "character", "ch", "ch23_002")
os.makedirs(mdf_dir, exist_ok=True)
mdf_out = os.path.join(mdf_dir, "ch23_002.mdf2.40")
open(mdf_out, "wb").write(d)
print(f"   wrote {mdf_out} ({len(d)} bytes, vanilla {orig_len})")

# ============================================================ ch223001_01.pfb
# ⛔⛔ THE PREFAB IS NO LONGER PATCHED OR SHIPPED. Redirecting ch223001_01 to ch23_002 was
# my own invention and the prefab never reached get_Ready across four builds. The proven
# route on this install is the unicorn's: ship the asset and swap it onto the LIVE body at
# runtime. IrisWildCats now does exactly that (load_panther_mdf + apply_panther_mdf), and
# because puma and panther share identical geometry it only needs set_Material -- no mesh,
# no prefab, no ch23_002.mesh at all. Kept below purely so the diff is recoverable.
SHIP_PREFAB = False
if SHIP_PREFAB:
    p = bytearray(open(PFB_IN, "rb").read())
    orig_len = len(p)
    print("\n=== ch223001_01.pfb (Panther prefab) ===")
    nm = patch_all(p, "Character/ch/ch23_001/ch23_001.mesh",
                   "Character/ch/ch23_002/ch23_002.mesh", "mesh path", expect=2)
    nd = patch_all(p, "Character/ch/ch23_001/ch23_001.mdf2",
                   "Character/ch/ch23_002/ch23_002.mdf2", "mdf2 path", expect=2)
    assert nm >= 1 and nd >= 1, "prefab redirect did not match"
    assert len(p) == orig_len, "pfb changed size -- offsets are now wrong"
    left = bytes(p).count(u16("ch23_001"))
    print(f"   remaining 'ch23_001' occurrences (should be the VFX ref only): {left}")

    pfb_dir = os.path.join(STAGE, "natives", "stm", "appsystem", "ch", "ch223", "prefab")
    os.makedirs(pfb_dir, exist_ok=True)
    pfb_out = os.path.join(pfb_dir, "ch223001_01.pfb.17")
    open(pfb_out, "wb").write(p)
    print(f"   wrote {pfb_out} ({len(p)} bytes, vanilla {orig_len})")

# ============================================================ meshes into place
# ⭐ ONE MESH, TWO PATHS. With the materials no longer renamed, the panther's mesh is
# byte-identical to the lioness's -- so ship the SAME file at the ch23_002 path instead of
# exporting a second one. Fewer moving parts, and it guarantees the two chassis differ
# only by their textures.
# only the lioness mesh ships now; the panther wears the same geometry.
src = os.path.join(OUT, "ch23_001.mesh.240423143")
for code, stage in (("ch23_001", "stage_lioness"),):
    dst_dir = os.path.join(OUT, stage, "natives", "stm", "character", "ch", code)
    os.makedirs(dst_dir, exist_ok=True)
    shutil.copyfile(src, os.path.join(dst_dir, f"{code}.mesh.240423143"))
    print(f"staged {code}.mesh (from ch23_001.mesh) -> {dst_dir}")
print("DONE")
