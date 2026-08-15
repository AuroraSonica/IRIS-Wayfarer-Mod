"""Build the ch23_001 (lioness) and ch23_002 (panther) texture sets via the SPLICE.

⛔ THE SPLICE LAW: "always SPLICE into vanilla tex twins, never generate fresh headers."
A DDSToTex-generated file has full mip chains, flags 0x0000 and unpadded scanlines;
vanilla has 5 mips / flags 0x4501 (base) and 7 mips / 0x0500 (streaming) with PADDED
scanlines on the small mips. The engine rejects the mismatch and silently serves vanilla
-- which reads as "my texture change did nothing".

⛔ AND THE LIBRARY'S OWN WRITER CANNOT DO IT: Tex.read() strips scanline padding into
textureData, but Tex.write() writes textureData RAW while re-writing the vanilla
mipOffset/scanlineLength/uncompressedSize. Round-tripping therefore corrupts every
padded mip. So this does a TRUE BYTE SPLICE: keep the vanilla bytes, overwrite only
[mipOffset, mipOffset+uncompressedSize) with our rows re-padded to scanlineLength.
Result: header-identical, size-identical, only texels differ.

⭐ THE PANTHER NOW HAS ITS OWN RESOURCE SET (ch23_002), so both variants ship at once and
neither shadows the other. Previously both paks overrode the SAME nine paths, the higher
Fluffy patch number won, and the panther's black came entirely from IrisWildCats writing
BaseColor = 0.115 at runtime -- a flat 12% multiply that crushed the coat's contrast from
std 0.128 to 0.015. The purpose-built charcoal holds std 0.049 on a 0.079 mean.

Ships per variant, at base AND streaming paths:
  body_ALBD  512/2048  fmt72 BC1_UNORM_SRGB   <- the coat (BC1 is FORCED by the splice)
  body_NRMR  512/2048  fmt98 BC7_UNORM        <- derived relief; a FLAT one reads as rubber
  body_ATOC  256/1024  fmt71 BC1_UNORM        <- neutral
  bodypattern_MSKM 256/1024 fmt71             <- BLACK, kills the UniquePattern overlay
  eye_ALBE   128/512   fmt99 BC7_UNORM_SRGB   <- her own eyes, island remapped to fill it
  eye_NRMR   128/512   fmt98 BC7_UNORM
  eye_EMMS   128/512   fmt71 BC1_UNORM        <- EMISSIVE MASK: where the eyes glow
"""
import bpy, os, sys, struct, shutil, math, json
import numpy as np

ADDON = r"C:\Users\Krist\AppData\Roaming\Blender Foundation\Blender\4.3\scripts\addons\RE-Mesh-Editor-main"
sys.path.insert(0, ADDON)
bpy.ops.preferences.addon_enable(module="RE-Mesh-Editor-main")
from modules.tex.file_re_tex import Tex
from modules.tex import re_tex_utils as U
from modules.tex import tex_math as tmath

GLB = r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework\rs_tools\New Mesh Attempts\Puma Panther\lioness_-_realistic_3d_model_demo_free.glb"
VAN_BASE = r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\DD2_EXTRACT\re_chunk_000\natives\STM\character\ch\ch23_001"
VAN_STRM = r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\DD2_EXTRACT\re_chunk_000\natives\STM\streaming\Character\ch\ch23_001"
OUT = r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework\rs_tools\lioness_build"
TMP = os.path.join(OUT, "tex_tmp")
PRV = os.path.join(OUT, "preview")
os.makedirs(TMP, exist_ok=True)
os.makedirs(PRV, exist_ok=True)
ISLAND = json.load(open(os.path.join(OUT, "eye_island.json")))
print("eye island:", ISLAND)

# ---------------------------------------------------------------- source albedo
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=GLB)
img = bpy.data.images['Image_0']
W, H = img.size
PX = np.array(img.pixels[:], dtype=np.float32).reshape(H, W, 4)   # bottom-up rows
print(f"source albedo {W}x{H} mean={PX[...,:3].mean(0).mean(0).round(4)}")

# ⛔ THE EYE MASK MUST BE THE ACTUAL UV TRIANGLES, NOT A BOUNDING RECTANGLE.
# First attempt used the island's uv bbox (u 0.4568..0.5303, v 0.2893..0.3625) and body
# geometry ALSO lands inside that rectangle -> a yellow triangle appeared on the rump.
# Rasterise the four 121-vert eye caps' own UV triangles instead.
import bmesh
from mathutils import Matrix


def eye_uv_mask():
    src = [o for o in bpy.data.objects if o.type == 'MESH'
           and len(o.data.vertices) > 1000][0]
    d = src.data.copy()
    tmp = bpy.data.objects.new("EYESPLIT", d)
    bpy.context.collection.objects.link(tmp)
    bpy.ops.object.select_all(action='DESELECT')
    tmp.select_set(True); bpy.context.view_layer.objects.active = tmp
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.mesh.remove_doubles(threshold=0.0001)
    bpy.ops.mesh.separate(type='LOOSE')
    bpy.ops.object.mode_set(mode='OBJECT')
    parts = [o for o in bpy.data.objects if o.name.startswith("EYESPLIT")]
    mask = np.zeros((H, W), bool)
    tri = 0
    for p in parts:
        if len(p.data.vertices) != 121:
            continue
        uvl = p.data.uv_layers[0].data
        for poly in p.data.polygons:
            pts = np.array([uvl[li].uv[:] for li in poly.loop_indices], np.float64)
            px = np.clip(pts[:, 0] * (W - 1), 0, W - 1)
            py = np.clip(pts[:, 1] * (H - 1), 0, H - 1)
            x0, x1 = int(px.min()), int(np.ceil(px.max()))
            y0, y1 = int(py.min()), int(np.ceil(py.max()))
            if x1 <= x0 or y1 <= y0:
                x1, y1 = x0 + 1, y0 + 1
            yy, xx = np.mgrid[y0:y1 + 1, x0:x1 + 1]
            for k in range(1, len(pts) - 1):
                ax, ay = px[0], py[0]
                bx, by = px[k], py[k]
                cx, cy = px[k + 1], py[k + 1]
                den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
                if abs(den) < 1e-12:
                    continue
                l1 = ((by - cy) * (xx - cx) + (cx - bx) * (yy - cy)) / den
                l2 = ((cy - ay) * (xx - cx) + (ax - cx) * (yy - cy)) / den
                l3 = 1 - l1 - l2
                inside = (l1 >= -0.02) & (l2 >= -0.02) & (l3 >= -0.02)
                mask[np.clip(yy[inside], 0, H - 1), np.clip(xx[inside], 0, W - 1)] = True
            tri += 1
    for p in parts:
        bpy.data.objects.remove(p, do_unlink=True)
    return mask, tri


EYE_MASK, ntri = eye_uv_mask()
print(f"eye UV mask: {EYE_MASK.sum()} texels from {ntri} eye faces "
      f"({100*EYE_MASK.sum()/(W*H):.3f}% of the atlas)")


def srgb_lum(a):
    return 0.2126 * a[..., 0] + 0.7152 * a[..., 1] + 0.0722 * a[..., 2]


def boxblur(x, r):
    """separable box blur; 3 passes ~= gaussian. numpy only (no scipy here)."""
    for _ in range(3):
        k = 2 * r + 1
        c = np.cumsum(np.pad(x, ((0, 0), (r + 1, r)), mode='edge'), axis=1)
        x = (c[:, k:] - c[:, :-k]) / k
        c = np.cumsum(np.pad(x, ((r + 1, r), (0, 0)), mode='edge'), axis=0)
        x = (c[k:, :] - c[:-k, :]) / k
    return x


LUM = srgb_lum(PX)
# ⭐ HIGH-PASS = the fur-strand detail with the BAKED LIGHTING removed. Deriving relief
# from raw albedo luminance embosses the painted shading (the rung-3 quilting lesson);
# subtracting a blur keeps only the fine strand frequencies, which is exactly what makes
# fur read. Used for BOTH the normal relief and the roughness break-up.
# ⛔ RADIUS MATTERS MORE THAN STRENGTH. At radius 4 (2048-space) the high-pass picks up
# medium-scale shading -- skin folds and muscle shading -- and turning THAT into relief
# gives pebbled leather / orange peel, not fur (Aurora, first NRMR attempt). Fur is a
# FINE frequency: radius 1 keeps only strand-scale detail.
HP = LUM - boxblur(LUM, 1)
HP /= max(float(np.abs(HP).max()), 1e-6)
print(f"albedo detail: lum std={LUM.std():.4f}  high-pass std={HP.std():.4f}")


# ================================================================ EYE ISLAND CROP
# The export remapped the eye loops as  new = M + (old - min)/span * (1 - 2M).
# Invert that to know which source texel each output texel of the eye atlas wants.
U0, V0, SPAN, MG = ISLAND["u0"], ISLAND["v0"], ISLAND["span"], ISLAND["margin"]


def sample_island(size, arr):
    """arr is (H,W,C) bottom-up; return (size,size,C) covering the eye island."""
    t = (np.arange(size) + 0.5) / size
    src = (t - MG) / (1.0 - 2 * MG) * SPAN
    su = np.clip((U0 + src) * (W - 1), 0, W - 1)
    sv = np.clip((V0 + src) * (H - 1), 0, H - 1)
    xi = np.clip(su.astype(int), 0, W - 2)
    yi = np.clip(sv.astype(int), 0, H - 2)
    fx = (su - xi)[None, :, None]
    fy = (sv - yi)[:, None, None]
    a = arr[np.ix_(yi, xi)]
    b = arr[np.ix_(yi, xi + 1)]
    c = arr[np.ix_(yi + 1, xi)]
    d = arr[np.ix_(yi + 1, xi + 1)]
    return (a * (1 - fx) * (1 - fy) + b * fx * (1 - fy)
            + c * (1 - fx) * fy + d * fx * fy)


def island_mask(size):
    t = (np.arange(size) + 0.5) / size
    src = (t - MG) / (1.0 - 2 * MG) * SPAN
    su = np.clip(((U0 + src) * (W - 1)).astype(int), 0, W - 1)
    sv = np.clip(((V0 + src) * (H - 1)).astype(int), 0, H - 1)
    return EYE_MASK[np.ix_(sv, su)]


def make_albedo(panther):
    a = PX.copy()
    if not panther:
        return a
    # ⛔ THE FIRST DYE READ AS RUBBER (Aurora). lum*0.20 crushed the albedo's std from
    # 0.128 to ~0.026 -- every painted fur strand flattened into uniform grey. A dark
    # coat needs MORE relative contrast than a light one, not less, because perception
    # compresses the dark end. So re-centre around a dark mean and KEEP the variation
    # instead of scaling toward zero.
    lum = LUM
    mean = float(lum.mean())
    DARK, GAIN = 0.075, 0.42          # target mean, contrast retained about it
    v = np.clip(DARK + (lum - mean) * GAIN, 0.006, 1.0)
    charcoal = np.stack([v * 0.98, v * 1.00, v * 1.10], axis=-1)   # faint cool cast
    # ⛔ BC1 quantises near-black gradients into stair-steps and the splice LOCKS us to
    # BC1 (fmt72) -- BC7 is not available for this slot. Dither instead.
    rng = np.random.default_rng(7)
    charcoal += (rng.random(charcoal.shape).astype(np.float32) - 0.5) * (2.0 / 255.0)
    out = a.copy()
    out[..., :3] = np.clip(charcoal, 0.0, 1.0)
    print(f"    panther coat: mean={charcoal.mean():.4f} std={charcoal.std():.4f} "
          f"(was mean~0.12 std~0.026 = the rubbery one)")
    return out


def make_eye_albe(size, panther):
    """⭐ The eyes are their own submesh on eye_mat now, so they get a dedicated atlas and
    their island fills it -- roughly 150 source px blown up to 512 rather than squeezed
    into 0.41% of the body map. The panther's iris is pushed gold IN THE TEXTURE as well
    as glowing via the emissive, so it still reads yellow in flat daylight."""
    e = sample_island(size, PX).copy()
    if not panther:
        return e
    el = srgb_lum(e)
    gold = np.stack([np.clip(el * 1.75 + 0.16, 0, 1),
                     np.clip(el * 1.40 + 0.11, 0, 1),
                     np.clip(el * 0.30, 0, 1)], axis=-1)
    dark = el < 0.12                      # pupil stays black
    e[..., :3] = np.where(dark[..., None], e[..., :3] * 0.35, gold)
    return e


def make_eye_emms(size, panther):
    """EMISSIVE MASK -- ch23_001_eye_EMMS rides the EnemyMaskMap slot (measured from the
    mdf2) and eye_mat has EnemyMaskMap_UseSecondaryUV = 0, so it samples UV0 like the
    albedo. White = glows. Restrict it to the actual eye triangles, then keep only the
    IRIS band: the sclera glowing would read as a headlamp and a glowing pupil kills the
    eye entirely."""
    e = sample_island(size, PX)
    lum = srgb_lum(e)
    geo = island_mask(size)
    iris = geo & (lum > 0.10) & (lum < 0.62)
    a = np.zeros((size, size, 4), np.float32)
    for c in range(3):
        a[..., c] = iris.astype(np.float32)
    a[..., 3] = 1.0
    print(f"    eye EMMS {size}: geometry {geo.sum()} texels, iris {iris.sum()} "
          f"({100*iris.sum()/max(geo.sum(),1):.0f}% of the eye)")
    return a


def save_png(arr, path, size):
    """arr is bottom-up RGBA float. Blender images are bottom-up too -- do NOT flip."""
    im = bpy.data.images.new("t", width=arr.shape[1], height=arr.shape[0], alpha=True)
    im.pixels = arr.reshape(-1).tolist()
    if arr.shape[0] != size:
        im.scale(size, size)
    im.filepath_raw = path
    im.file_format = 'PNG'
    im.save()
    bpy.data.images.remove(im)
    return path


def flat_png(rgba, size, path):
    a = np.zeros((size, size, 4), np.float32)
    a[..., 0], a[..., 1], a[..., 2], a[..., 3] = [c / 255.0 for c in rgba]
    return save_png(a, path, size)


def nrmr_from(h, base, swing, size, path):
    """RG = tangent-space normal from fur-strand relief, B = 255, A = ROUGHNESS.
    ⛔ A FLAT NRMR READS AS RUBBER: constant roughness over a whole pelt gives uniform
    specular, and this asset ships NO normal map, so the flat placeholder was the only
    surface information the shader had. ⛔ But a STRONG one gives pebbled leather. Fur
    lives between, much nearer flat -- the relief only breaks up specular, it never
    sculpts."""
    gy, gx = np.gradient(h)
    nx, ny = -gx * 2.0, -gy * 2.0
    nz = np.ones_like(nx)
    L = np.sqrt(nx * nx + ny * ny + nz * nz)
    a = np.zeros(h.shape + (4,), np.float32)
    a[..., 0] = np.clip(nx / L * 0.5 + 0.5, 0, 1)
    a[..., 1] = np.clip(ny / L * 0.5 + 0.5, 0, 1)
    a[..., 2] = 1.0
    a[..., 3] = np.clip(base - h * swing, 0.05, 1.0)
    return save_png(a, path, size)


# texconv.dll drives WIC, which needs COM initialised on this thread or it fails
# 80004002 / hard-exits the process. Blender does not do it for us.
import ctypes
try:
    ctypes.windll.ole32.CoInitializeEx(None, 2)
    print("CoInitializeEx ok")
except Exception as e:
    print("CoInitializeEx:", e)

TC = U.Texconv()


def to_dds(png, fmt):
    return TC.convert_to_dds(png, fmt, out=TMP, allow_slow_codec=True)


def dds_mips(ddspath):
    b = open(ddspath, 'rb').read()
    assert b[:4] == b'DDS ', "not a DDS"
    hsize = 124
    h = struct.unpack_from('<I', b, 12)[0]
    w = struct.unpack_from('<I', b, 16)[0]
    mipc = struct.unpack_from('<I', b, 28)[0] or 1
    fourcc = b[84:88]
    off = 4 + hsize + (20 if fourcc == b'DX10' else 0)
    return b, off, w, h, mipc


def splice(vanilla_path, out_path, png, fmt_name):
    raw = bytearray(open(vanilla_path, 'rb').read())
    f = open(vanilla_path, 'rb')
    tex = Tex(); tex.header.read(f); tbl = f.tell(); f.close()
    hd = tex.header
    fd = hd.formatData
    dds = to_dds(png, fmt_name)
    b, doff, dw, dh, dmipc = dds_mips(dds)
    ours, cur, mw, mh = [], doff, dw, dh
    for j in range(dmipc):
        rows = tmath.ruD(mh, fd.ty)
        line = tmath.ruD(mw, fd.tx) * fd.bytelen
        ours.append(b[cur:cur + rows * line])
        cur += rows * line
        mw = max(mw >> 1, 1); mh = max(mh >> 1, 1)
    n = 0
    for j in range(hd.mipCount):
        o = tbl + j * 16
        mipOffset = struct.unpack_from('<Q', raw, o)[0]
        scan = struct.unpack_from('<I', raw, o + 8)[0]
        usize = struct.unpack_from('<I', raw, o + 12)[0]
        mw = max(hd.width >> j, 1); mh = max(hd.height >> j, 1)
        rows = tmath.ruD(mh, fd.ty)
        line = tmath.ruD(mw, fd.tx) * fd.bytelen
        if j >= len(ours):
            continue
        src = ours[j]
        buf = bytearray()
        for r in range(rows):
            row = src[r * line:(r + 1) * line]
            if len(row) < line:
                row = row + bytes(line - len(row))
            buf += row + bytes(scan - line)
        if len(buf) != usize:
            print(f"    !! mip{j} size {len(buf)} != vanilla {usize} -- SKIPPED")
            continue
        raw[mipOffset:mipOffset + usize] = buf
        n += 1
    open(out_path, 'wb').write(raw)
    same = os.path.getsize(out_path) == os.path.getsize(vanilla_path)
    assert same, f"SPLICE CHANGED THE FILE SIZE for {os.path.basename(out_path)}"
    print(f"    {os.path.basename(out_path):<44} mips {n}/{hd.mipCount}  "
          f"fmt={hd.format} {hd.width}x{hd.height}")
    return n


SPECS = [
    ("body_ALBD.tex.760230703", "BC1_UNORM_SRGB", "albedo"),
    ("body_NRMR.tex.760230703", "BC7_UNORM", "nrmr"),
    ("body_ATOC.tex.760230703", "BC1_UNORM", "atoc"),
    ("bodypattern_MSKM.tex.760230703", "BC1_UNORM", "mskm"),
    ("eye_ALBE.tex.760230703", "BC7_UNORM_SRGB", "eye_albe"),
    ("eye_NRMR.tex.760230703", "BC7_UNORM", "eye_nrmr"),
    ("eye_EMMS.tex.760230703", "BC1_UNORM", "eye_emms"),
]

VARIANTS = [("lioness", False, "ch23_001"), ("panther", True, "ch23_002")]
for variant, panther, code in VARIANTS:
    print(f"\n================ {variant.upper()}  ->  {code} ================")
    alb = make_albedo(panther)
    stage = os.path.join(OUT, f"stage_{variant}")
    # ⛔⛔ WIPE THE STAGE. THIS SHIPPED A BLACK PUMA (Aurora, field). v1.0 wrote BOTH
    # variants to ch23_001 paths. When the panther moved to ch23_002, its old ch23_001
    # files were simply LEFT BEHIND in stage_panther -- nine of them, including the mesh.
    # build_pak then copies stage_lioness first and stage_panther second with -Force, so
    # the v1.0 charcoal albedo and the v1.0 mesh overwrote the lioness's own files under
    # the SAME names. File count never changed, so nothing looked wrong: 32 files in,
    # 32 files out. A stale artefact with the right name is invisible to a count.
    if os.path.isdir(stage):
        shutil.rmtree(stage)
    subs = (os.path.join("natives", "stm", "character", "ch", code),
            os.path.join("natives", "stm", "streaming", "character", "ch", code))
    for sub in subs:
        os.makedirs(os.path.join(stage, sub), exist_ok=True)
    for suffix, fmt, kind in SPECS:
        for tag, vdir, sub in (("base", VAN_BASE, subs[0]), ("strm", VAN_STRM, subs[1])):
            vp = os.path.join(vdir, "ch23_001_" + suffix)
            if not os.path.exists(vp):
                print(f"    MISSING vanilla {tag} {suffix}"); continue
            f = open(vp, 'rb'); t = Tex(); t.header.read(f); f.close()
            size = t.header.width
            png = os.path.join(TMP, f"{variant}_{kind}_{tag}.png")
            if kind == "albedo":
                save_png(alb, png, size)
            elif kind == "nrmr":
                nrmr_from(HP * (1.0 if panther else 0.8),
                          0.74 if panther else 0.88, 0.20 if panther else 0.14,
                          size, png)
            elif kind == "atoc":
                flat_png((255, 255, 210, 255), size, png)
            elif kind == "mskm":
                flat_png((0, 0, 0, 255), size, png)
            elif kind == "eye_albe":
                save_png(make_eye_albe(size, panther), png, size)
            elif kind == "eye_nrmr":
                eh = srgb_lum(sample_island(size, PX))
                eh = eh - boxblur(eh, 1)
                eh /= max(float(np.abs(eh).max()), 1e-6)
                nrmr_from(eh * 0.5, 0.22, 0.10, size, png)   # eyes are WET: low roughness
            else:
                save_png(make_eye_emms(size, panther), png, size)
            if tag == "strm" and kind.startswith("eye"):
                shutil.copyfile(png, os.path.join(PRV, f"{variant}_{kind}.png"))
            splice(vp, os.path.join(stage, sub, f"{code}_" + suffix), png, fmt)
    print(f"  staged -> {stage}")
print("\nDONE")
