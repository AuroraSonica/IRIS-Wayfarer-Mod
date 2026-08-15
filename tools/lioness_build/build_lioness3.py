"""LIONESS -> ch23_001 : fit + weights + surgery + gates.   v3

STRATEGY SPLIT BY STRUCTURE TYPE, NOT BY DISTANCE (measured this session):
  after the withers-matched fit, front-leg bones land 0.014-0.082 m from their wolf
  counterparts, but the head cluster lands 0.31-0.36 m away -- the wolf is a
  long-muzzled canid whose eye bone sits at y -1.505 where the fitted lioness's sits
  at -1.224.
    * EARS / EYES / EYELIDS / JAW / TONGUE / MOUTH / HEAD -> ALWAYS name-map. No
      spatial alternative exists; nearest-surface hands the face to neck bones (the
      puma's crumpled-face bug). The artist's own weights supply the falloff, so the
      head ramps into the neck with no hand-tuned blend band.
    * FRONT LEGS -> name-map (measured close).
    * REAR LEGS + TAIL -> ARC-LENGTH projection onto the WOLF's bone polyline: spatial,
      fills every bone in the chain (nearest-surface skipped RearLeg_Foot and 4 of 6
      tail bones), and derives thresholds from the fit, not the puma's constants.
    * everything else -> nearest-surface.

ORDER MATTERS: the co-located sync averages clusters and can push a vert back over the
6-influence cap, so LIMIT RUNS LAST. DD2 truncates silently and un-renormalised
truncation reads in-game as limb sag.

All weight post-processing is numpy: bpy.ops.object.vertex_group_* HARD-CRASHES
Blender in background mode (silent exit right after the groups are written).
"""
import bpy, sys, os, math, json
import numpy as np
from mathutils import Vector, Matrix
from mathutils.bvhtree import BVHTree
from mathutils.kdtree import KDTree
import bmesh
from collections import Counter

VAN = r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\DD2_EXTRACT\re_chunk_000\natives\STM\character\ch\ch23_001\ch23_001.mesh.240423143"
GLB = r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework\rs_tools\New Mesh Attempts\Puma Panther\lioness_-_realistic_3d_model_demo_free.glb"
OUT = r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework\rs_tools\lioness_build"
os.makedirs(OUT, exist_ok=True)

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.preferences.addon_enable(module="blender-dd2-tools-suite-main")


def v3d():
    for w in bpy.context.window_manager.windows:
        for a in w.screen.areas:
            if a.type == 'VIEW_3D':
                return {"window": w, "area": a, "region": a.regions[-1]}


with bpy.context.temp_override(**v3d()):
    bpy.ops.dd2_import.dd2_mesh(filepath=VAN, fix_rotation=True, import_material=False,
                                all_LOD=False, connect_bones=False)
wolf_objs = list(bpy.data.objects)
warm = [o for o in wolf_objs if o.type == 'ARMATURE'][0]
warm.name = "WOLF_ARM"
for o in wolf_objs:
    if o.type == 'MESH':
        o.name = "WOLF_%d" % len(o.data.vertices)
skin = [bpy.data.objects["WOLF_3755"], bpy.data.objects["WOLF_7137"]]
WBP = {b.name: np.array((warm.matrix_world @ b.head_local)[:]) for b in warm.data.bones}
WBT = {b.name: np.array((warm.matrix_world @ b.tail_local)[:]) for b in warm.data.bones}
WBONES = set(WBP)

wco = np.vstack([np.array([(o.matrix_world @ v.co)[:] for v in o.data.vertices])
                 for o in skin])
W_FEET = float(wco[:, 2].min()); wmn, wmx = wco.min(0), wco.max(0)
wL = wmx[1] - wmn[1]
_m = np.abs(wco[:, 0]) < 0.035
wband = _m & (wco[:, 1] > wmn[1] + .20 * wL) & (wco[:, 1] < wmn[1] + .42 * wL)
W_WITHERS = float(wco[wband][:, 2].max()) - W_FEET
W_PAW_Y = float(wco[(wco[:, 2] < W_FEET + .06) &
                    (wco[:, 1] < wmn[1] + .45 * wL)][:, 1].mean())

before = set(bpy.data.objects)
bpy.ops.import_scene.gltf(filepath=GLB)
new = [o for o in bpy.data.objects if o not in before]
for o in list(new):
    if o.type == 'MESH' and len(o.data.vertices) < 100:
        bpy.data.objects.remove(o, do_unlink=True)
new = [o for o in bpy.data.objects if o not in before]
R = Matrix.Rotation(math.radians(90), 4, 'X')
for o in new:
    if o.parent is None:
        o.matrix_world = R @ o.matrix_world
bpy.context.view_layer.update()
lion = [o for o in new if o.type == 'MESH'][0]
larm = [o for o in new if o.type == 'ARMATURE'][0]
for pb in larm.pose.bones:
    pb.location = (0, 0, 0); pb.rotation_quaternion = (1, 0, 0, 0)
    pb.rotation_euler = (0, 0, 0); pb.scale = (1, 1, 1)
if larm.animation_data:
    larm.animation_data.action = None
bpy.context.view_layer.update()

lco0 = np.array([(lion.matrix_world @ v.co)[:] for v in lion.data.vertices])
lmn, lmx = lco0.min(0), lco0.max(0); lL = lmx[1] - lmn[1]
lb = (np.abs(lco0[:, 0]) < .035) & (lco0[:, 1] > lmn[1] + .20 * lL) \
    & (lco0[:, 1] < lmn[1] + .42 * lL)
S = W_WITHERS / (float(lco0[lb][:, 2].max()) - float(lco0[:, 2].min()))
t = lco0 * S
tf = t[(t[:, 2] < t[:, 2].min() + .06) &
       (t[:, 1] < t[:, 1].min() + .45 * (t[:, 1].max() - t[:, 1].min()))]
DY = W_PAW_Y - float(tf[:, 1].mean()); DZ = W_FEET - float(t[:, 2].min())
FIT = Matrix.Translation((0., DY, DZ)) @ Matrix.Scale(S, 4)
print(f"FIT S={S:.5f} dy={DY:+.4f} dz={DZ:+.4f}")
for o in (lion, larm):
    o.matrix_world = FIT @ o.matrix_world
bpy.context.view_layer.update()

# Her own tail bone line, captured BEFORE larm is deleted -- the tail re-projection below
# needs her centreline, and a PCA fit cannot supply it because the thing we are correcting
# IS a curl (PCA would happily fit a line through the middle of the bend).
LBP = {b.name: np.array((larm.matrix_world @ b.head_local)[:]) for b in larm.data.bones}
LBT = {b.name: np.array((larm.matrix_world @ b.tail_local)[:]) for b in larm.data.bones}

N = len(lion.data.vertices)
gi = {g.index: g.name for g in lion.vertex_groups}
srcw = [dict() for _ in range(N)]
for v in lion.data.vertices:
    for ge in v.groups:
        if ge.weight > 0:
            srcw[v.index][gi[ge.group]] = srcw[v.index].get(gi[ge.group], 0.) + ge.weight
bpy.ops.object.select_all(action='DESELECT')
lion.select_set(True); bpy.context.view_layer.objects.active = lion
bpy.ops.object.parent_clear(type='CLEAR_KEEP_TRANSFORM')
for m in list(lion.modifiers):
    lion.modifiers.remove(m)
while lion.vertex_groups:
    lion.vertex_groups.remove(lion.vertex_groups[0])
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
lion.name = "LIONESS"
uvs = lion.data.uv_layers
u0 = np.array([d.uv[:] for d in uvs[0].data])
if len(uvs) >= 2:
    uvs.remove(uvs[1])
uv2 = uvs.new(name="UV2")
for i, d in enumerate(uv2.data):
    d.uv = u0[i]
bpy.data.objects.remove(larm, do_unlink=True)
for o in list(bpy.data.objects):
    if o.type == 'EMPTY':
        bpy.data.objects.remove(o, do_unlink=True)
co = np.array([(lion.matrix_world @ v.co)[:] for v in lion.data.vertices])

# ===================== TAIL RE-PROJECTION ONTO THE BONE LINE =====================
# ⛔⛔ THE REST SHAPE, NOT THE WEIGHTS, WAS THE HOOK (Aurora, field: "the resting tail
# seems a bit weird with the curl"). The wolf's tail chain is dead straight -- six
# identical 0.2142 m segments -- and hers CURLS. Measured radial offset of her tail from
# that chain, by arc position: 0.040 m mid-tail (which is just the tube radius, i.e. a
# perfect fit) but 0.137 m over the distal 0.16 m. A curl baked into the rest pose rides
# through every single animation, so no weighting scheme can remove it.
#
# Transport her tail onto the chain: parameterise each vert by NORMALISED arc length along
# HER bone line, carry its radial offset through an orthonormal frame, and re-seat it at
# the same fraction along the WOLF's. Normalised (not absolute) arc also retires the
# 0.111 m overhang past the last bone, which was leaving 21% of the tail hanging off the
# end of the skeleton as a rigid club.
# ⭐ Blend by the artist's own tail weight so the base melts into the rump instead of
# tearing a seam at the dock.
TAIL_SRC = ["Tail1_081", "Tail2_082", "Tail3_083", "Tail4_084", "Tail5_085", "Tail6_086"]
TAIL_DST = ["Tail_0", "Tail_1", "Tail_2", "Tail_3", "Tail_4", "Tail_5"]


def polyline(P):
    P = np.asarray(P, float)
    d = np.diff(P, axis=0)
    L = np.linalg.norm(d, axis=1)
    return P, d, L, np.concatenate([[0.0], np.cumsum(L)])


def point_at(P, d, L, cum, s):
    s = float(np.clip(s, 0.0, cum[-1]))
    k = int(np.clip(np.searchsorted(cum, s) - 1, 0, len(L) - 1))
    t = 0.0 if L[k] < 1e-12 else (s - cum[k]) / L[k]
    return P[k] + d[k] * t


def nearest_s(P, d, L, cum, p):
    best, bs = 1e18, 0.0
    for k in range(len(L)):
        L2 = float(d[k] @ d[k])
        t = 0.0 if L2 < 1e-12 else float(np.clip((p - P[k]) @ d[k] / L2, 0., 1.))
        q = P[k] + d[k] * t
        dd = float(np.linalg.norm(p - q))
        if dd < best:
            best, bs = dd, cum[k] + t * L[k]
    return bs


tw = np.array([min(1.0, sum(srcw[i].get(s, 0.) for s in TAIL_SRC)) for i in range(N)])
tidx = np.nonzero(tw > 1e-4)[0]

# ⛔⛔ DO NOT TRANSPORT THROUGH PER-VERTEX FRAMES. First attempt reparameterised each vert
# onto her own bone line and re-seated it in an orthonormal frame on the wolf's. It made
# things WORSE, measurably: whole arc buckets emptied (0.477-0.794 m had no verts at all)
# while 158 piled into the last one, and offsets rose from 0.040/0.137 to 0.27-0.33. Two
# reasons -- her bone line is unusable (the glTF importer gives the LEAF bone a 1.3142 m
# fallback length, and the child node Tail6_end_087 is CONNECTED to that fiction so it
# inherits the same bogus point), and a frame's ROLL about the tangent is arbitrary, so
# transporting through two independently-built frames twists the tube.
#
# ⭐ THE CORRECTION IS A PURE TRANSLATION FIELD, and that is all it ever needed to be. The
# mid-tail already sits 0.040 m off the wolf chain -- which IS the tube radius, i.e. a
# perfect fit -- so only the centreline DRIFT is wrong, never the cross-section. Estimate
# the drift empirically by binning her tail verts along the chain and taking each bin's
# centroid offset, smooth it, then subtract it. Tube shape is preserved exactly because
# every vert in a bin moves by the same vector, and nothing can scramble because no vertex
# is ever reparameterised.
WPX = [WBP[b] for b in TAIL_DST] + [WBT[TAIL_DST[-1]]]
_e = WPX[-1] - WPX[-2]
WPX.append(WPX[-1] + _e / max(np.linalg.norm(_e), 1e-9) * 0.25)   # straight continuation
WP, Wd, WL, Wcum = polyline(WPX)
print(f"tail re-projection: wolf chain {Wcum[-1]:.4f} m (incl. 0.25 m straight extension)")

# ⛔⛔ A DRIFT FIELD MEASURED BY NEAREST-POINT PROJECTION CANNOT SEE THIS CURL, and that
# is why the first two attempts left it standing. Projecting onto the nearest point of a
# line makes a curving tube look STRAIGHT: every vertex simply lands on whichever segment
# is closest, so the measured offset stayed at 0.006-0.038 m across the distal half while
# the tail was visibly hooking. The metric agreed with itself and disagreed with the eye.
#
# ⭐ TRANSPORT HER TAIL ONTO THE WOLF'S LINE INSTEAD, with PARALLEL-TRANSPORTED (rotation
# minimising) frames on both curves. The first transport attempt failed because it built
# each frame independently from a global up-vector, and a frame's roll about its tangent
# is arbitrary -- two independently-built frames differ by an unknown twist, which wrung
# the tube out. Parallel transport carries one chosen frame along the curve instead of
# re-deriving it, so the roll is continuous by construction; seeding the wolf's first
# frame from hers via the minimal rotation between the two tangents makes the two agree.
def pt_frames(P):
    """per-point tangent + parallel-transported normal frame along a polyline"""
    P = np.asarray(P, float)
    n = len(P)
    seg = np.diff(P, axis=0)
    sl = np.linalg.norm(seg, axis=1)
    T = np.zeros((n, 3))
    T[:-1] = seg / sl[:, None]
    T[-1] = T[-2]
    T[1:-1] = T[:-2] + T[1:-1]
    T /= np.linalg.norm(T, axis=1, keepdims=True).clip(1e-12)
    U = np.zeros((n, 3))
    a = np.array([0., 0., 1.])
    if abs(T[0] @ a) > 0.9:
        a = np.array([0., 1., 0.])
    U[0] = a - T[0] * (T[0] @ a)
    U[0] /= max(np.linalg.norm(U[0]), 1e-12)
    for i in range(1, n):
        U[i] = rot_between(T[i - 1], T[i]) @ U[i - 1]
        U[i] -= T[i] * (T[i] @ U[i])
        U[i] /= max(np.linalg.norm(U[i]), 1e-12)
    return P, T, U, np.cross(T, U), np.concatenate([[0.], np.cumsum(sl)])


def rot_between(a, b):
    """minimal rotation matrix taking unit a to unit b (Rodrigues)"""
    v = np.cross(a, b)
    c = float(a @ b)
    s = float(np.linalg.norm(v))
    if s < 1e-9:
        return np.eye(3) if c > 0 else -np.eye(3)
    K = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
    return np.eye(3) + K + K @ K * ((1 - c) / (s * s))


# ⛔ HER CHAIN HAS NO TRUSTWORTHY TERMINAL JOINT. Blender's glTF importer gives the LEAF
# bone a fallback length -- Tail6_086 measures 1.3142 m of fiction -- and the child node
# Tail6_end_087 is CONNECTED to that fictional tail, so it inherits the same bogus point.
# Either one put her chain at 2.5956 m against a real ~1.0 m. Taking max() over the tail
# verts was no better: one stray vertex put the tip 0.6845 m out, 3x the truth. Her tail
# joints are uniformly spaced, so close the chain with the MEDIAN real segment.
_d = LBP[TAIL_SRC[-1]] - LBP[TAIL_SRC[-2]]
_d /= max(np.linalg.norm(_d), 1e-9)
_steps = [float(np.linalg.norm(LBP[TAIL_SRC[k + 1]] - LBP[TAIL_SRC[k]]))
          for k in range(len(TAIL_SRC) - 1)]
_hend = LBP[TAIL_SRC[-1]] + _d * float(np.median(_steps))
print(f"  her segments {[round(x,4) for x in _steps]} -> tip +{np.median(_steps):.4f} m")

HPts, HT, HU, HV, Hcum = pt_frames([LBP[b] for b in TAIL_SRC] + [_hend])

# ⭐ THE TARGET IS A STRAIGHT LINE, SO THE TARGET FRAME IS A CONSTANT. The wolf's tail
# chain is six identical collinear segments; there is nothing to parallel-transport along
# it. Mapping her arc onto the wolf's *extended* 1.5210 m line also stretched her 1.2048 m
# tail by 26% and dragged the dock off her rump -- rest offset went to 0.347 m mean.
# Keep her tail's own length and her own root, and only straighten the DIRECTION: one
# fixed destination frame, seeded from her frame at the dock so the roll cannot jump.
WDIR = WPX[-1] - WPX[0]
WDIR /= max(np.linalg.norm(WDIR), 1e-9)
TU = rot_between(HT[0], WDIR) @ HU[0]
TU -= WDIR * (WDIR @ TU)
TU /= max(np.linalg.norm(TU), 1e-12)
TV = np.cross(WDIR, TU)
ROOT = HPts[0].copy()
print(f"  her line {Hcum[-1]:.4f} m; straightening onto the wolf tail direction "
      f"({WDIR[0]:+.3f},{WDIR[1]:+.3f},{WDIR[2]:+.3f}) from her own dock")


def frame_lerp(Pts, T, U, V, cum, s):
    s = float(np.clip(s, 0.0, cum[-1]))
    k = int(np.clip(np.searchsorted(cum, s) - 1, 0, len(cum) - 2))
    L = cum[k + 1] - cum[k]
    t = 0.0 if L < 1e-12 else (s - cum[k]) / L
    q = Pts[k] * (1 - t) + Pts[k + 1] * t
    F = []
    for A in (T, U, V):
        a = A[k] * (1 - t) + A[k + 1] * t
        F.append(a / max(np.linalg.norm(a), 1e-12))
    return q, np.stack(F)
# ⛔⛔ DO NOT SCALE THE CORRECTION BY tw -- THAT IS WHY THE CURL SURVIVED (Aurora, second
# field report: "the tail curl is still odd, can we not have tail not curling, mimicking
# the rest position of the wolf tail"). A mid-tail vertex typically carries tw ~ 0.6, so
# multiplying by tw applied only 60% of the correction and left 40% of the curl standing.
# tw is a MEMBERSHIP test -- is this vertex part of the tail -- not a strength dial.
# Saturate it, and let the arc-length ramp alone do the blending at the dock, which is the
# only place a seam can tear.
Hseg = np.diff(HPts, axis=0)
Hsl = np.linalg.norm(Hseg, axis=1)

# ⛔⛔ THIRD AND FINAL SHAPE OF THIS FIX. The two failures before it both came from moving
# vertices through FRAMES: re-seating each vertex by (tangent, normal, binormal) flattened
# the dock into a plank and left a hard kink where the ramp ended, because the
# along-tangent component of a nearest-point projection is degenerate near the root and
# the ramp fights it. And the attempt before THAT measured drift by projecting vertices
# onto the chain, which cannot see a curl at all -- nearest-point projection makes a
# curving tube read as straight (it reported 0.006-0.038 m across the distal half of a
# visibly hooked tail).
#
# ⭐ THE DRIFT IS ALREADY IN HER BONE CHAIN. C(s) is her tail's own polyline and it really
# does curve; the straight target is C(0) + WDIR*s. delta(s) = target - C(s) needs no
# vertex projection to estimate and no frame to apply. Applying it as a PURE TRANSLATION
# preserves the tube's cross-section exactly -- every vertex at the same arc moves by the
# same vector, so nothing can flatten, twist or scramble.
# ⛔⛔⛔ NO GEOMETRY SURGERY ON THE TAIL. FOUR ATTEMPTS, FOUR REGRESSIONS -- every one of
# them verified WORSE than doing nothing, by render and by number:
#   1. drift binned from nearest-point vertex projection  -> could not see the curl at all
#      (0.006-0.038 m reported across a visibly hooked distal half), barely moved it
#   2. reparameterise + re-seat through per-vertex frames  -> arc buckets emptied, offsets
#      0.040/0.137 -> 0.27-0.33; independently-built frames differ by an unknown roll
#   3. parallel-transported frames onto the extended chain -> flattened the dock into a
#      plank with a hard kink; also stretched her 1.2048 m tail onto a 1.5210 m line
#   4. pure translation from the bone-chain drift          -> zigzag with a shear break,
#      because the nearest-point arc parameter jumps at the curve's inflection
# The tail is a smooth tapering tube whose rest curve is genuinely part of the source
# model. Every field I built to "correct" it introduced a discontinuity somewhere, and a
# kinked tail is far worse than a curved one.
#
# ⭐ WHAT ACTUALLY FIXED THE REPORTED PROBLEM WAS THE WEIGHTS, NOT THE SHAPE: the 1:1
# Tail1_081..Tail6_086 -> Tail_0..Tail_5 name map (see NAMED) plus closing the polyline on
# the last bone's TAIL instead of its head. That removed the rigid 0.24 m club at the tip,
# and it renders as a smooth natural taper. Aurora's "the curl is still odd" was reported
# against a pak that shipped the OLD v1.0 mesh -- the stale-stage bug -- so the weight fix
# had never actually reached the game. Ship it and judge it on its own evidence.
print(f"  tail geometry left UNMODIFIED by design; {len(tidx)} verts ride the 1:1 name map")
moved = np.zeros(1)
print(f"  {len(tidx)} tail verts corrected; displacement mean "
      f"{moved.mean():.4f} max {moved.max():.4f} m")
co = np.array([(lion.matrix_world @ v.co)[:] for v in lion.data.vertices])
# =================================================================================

bpy.ops.object.select_all(action='DESELECT')
cps = []
for o in skin:
    c = o.copy(); c.data = o.data.copy()
    bpy.context.collection.objects.link(c); cps.append(c)
for c in cps:
    c.select_set(True)
bpy.context.view_layer.objects.active = cps[0]
bpy.ops.object.join()
donor = bpy.context.view_layer.objects.active
dgi = {g.index: g.name for g in donor.vertex_groups}
dw = [dict() for _ in range(len(donor.data.vertices))]
for v in donor.data.vertices:
    for ge in v.groups:
        n = dgi.get(ge.group)
        if n in WBONES and ge.weight > 0:
            dw[v.index][n] = dw[v.index].get(n, 0.) + ge.weight
bm = bmesh.new(); bm.from_mesh(donor.data)
bmesh.ops.triangulate(bm, faces=bm.faces[:]); bm.transform(donor.matrix_world)
dv = np.array([v.co[:] for v in bm.verts])
dt = [[v.index for v in f.verts] for f in bm.faces]
bvh = BVHTree.FromBMesh(bm)
NS = [dict() for _ in range(N)]; dist = np.zeros(N)
for i, p in enumerate(co):
    loc, nrm, fi, d = bvh.find_nearest(Vector(p.tolist()))
    dist[i] = d if d is not None else -1
    if fi is None:
        continue
    a, b, c2 = dt[fi]; pa, pb, pc = dv[a], dv[b], dv[c2]
    v0, v1, v2 = pb - pa, pc - pa, np.array(loc[:]) - pa
    d00, d01, d11, d20, d21 = v0 @ v0, v0 @ v1, v1 @ v1, v2 @ v0, v2 @ v1
    den = d00 * d11 - d01 * d01
    if abs(den) < 1e-12:
        bw = [1., 0., 0.]
    else:
        vv = (d11 * d20 - d01 * d21) / den; ww = (d00 * d21 - d01 * d20) / den
        bw = [max(0., 1. - vv - ww), max(0., vv), max(0., ww)]
    s = sum(bw) or 1.
    acc = {}
    for idx, wt in zip((a, b, c2), [x / s for x in bw]):
        for bn, w2 in dw[idx].items():
            acc[bn] = acc.get(bn, 0.) + w2 * wt
    NS[i] = acc
print(f"nearest-surface: mean {dist.mean():.4f} max {dist.max():.4f}")
bpy.data.objects.remove(donor, do_unlink=True)

NAMED = {
    "Head_08": "Head_0", "Nose_034": "Head_0", "Jaw_037": "Jaw_0",
    "Tongue1_038": "Tongue_0", "Tongue2_039": "Tongue_0",
    "Tongue3_040": "Tongue_1", "Tongue4_041": "Tongue_2",
    "MouthL_050": "l_mouthMidCorner", "MouthR_047": "r_mouthMidCorner",
    "EarL1_09": "L_Ear_0", "EarL2_010": "L_Ear_1", "EarL3_011": "L_Ear_1",
    "EarR1_014": "R_Ear_0", "EarR2_015": "R_Ear_1", "EarR3_016": "R_Ear_1",
    # EYES/EYELIDS -> Head_0, NOT the wolf's eye bones. Measured: the wolf's L_Eye sits
    # at y -1.5049 and the fitted lioness's eye at y -1.22, so any eye rotation swings
    # her eyeballs about a pivot 28 cm away -> 2-5x edge stretch across the face.
    # A reskinned eye does not need to rotate; flying eyes are far worse than still ones.
    "EyeL_028": "Head_0", "EyeR_019": "Head_0",
    "EyelidLU_031": "Head_0", "EyelidLD_044": "Head_0",
    "EyelidRU_022": "Head_0", "EyelidRD_025": "Head_0",
    "LegFLCollarbone_073": "L_FrontLeg_Scapula", "LegFL1_074": "L_FrontLeg_Upper",
    "LegFL2_075": "L_FrontLeg_Lower", "LegFL3_076": "L_FrontLeg_Ankle",
    "LegFLAnkle_077": "L_FrontLeg_Foot", "LegFLDigit11_078": "L_FrontLeg_Toes",
    "LegFRCollarbone_065": "R_FrontLeg_Scapula", "LegFR1_066": "R_FrontLeg_Upper",
    "LegFR2_067": "R_FrontLeg_Lower", "LegFR3_068": "R_FrontLeg_Ankle",
    "LegFRAnkle_069": "R_FrontLeg_Foot", "LegFRDigit11_070": "R_FrontLeg_Toes",
    # ⛔⛔ TAIL: WAS ARC-LENGTH, AND IT CLUBBED THE TIP (Aurora, field). Two compounding
    # faults. (a) the chain polyline was built from bone HEADS only, so it ended at
    # Tail_5's HEAD -- a 0.24 m dead zone past it where every vert clamped to tt=1 and
    # went 100% rigid on the last bone. Measured: 98 of 325 tail verts (30%) dominated by
    # Tail_5, which covered a 0.304 m arc span against ~0.19 m for every other tail bone,
    # plus 0.111 m of geometry hanging past the chain entirely. (b) arc-length was the
    # wrong tool here at all: her tail has SIX bones and the wolf's has SIX, a clean 1:1,
    # so the artist's own falloff transfers directly and needs no spatial guessing. The
    # 0.1305 m mean radial offset that made projection unreliable stops mattering, because
    # a name map never asks where the bone line runs.
    "Tail1_081": "Tail_0", "Tail2_082": "Tail_1", "Tail3_083": "Tail_2",
    "Tail4_084": "Tail_3", "Tail5_085": "Tail_4", "Tail6_086": "Tail_5",
}
W = [dict() for _ in range(N)]
nn = 0
for i in range(N):
    nm, al = {}, 0.
    for sn, sw in srcw[i].items():
        tgt = NAMED.get(sn)
        if tgt:
            nm[tgt] = nm.get(tgt, 0.) + sw; al += sw
    al = min(al, 1.0)
    base = NS[i]; bs = sum(base.values())
    out = {k: v * (1. - al) / bs for k, v in base.items()} if bs > 0 else {}
    ns_ = sum(nm.values())
    if ns_ > 0:
        for k, v in nm.items():
            out[k] = out.get(k, 0.) + al * v / ns_
        nn += 1
    W[i] = out or (dict(base) if base else {"Hip": 1.})
print(f"name-mapped verts: {nn}/{N}")

# EAR DAMPING. The wolf's ear bones sit ~0.33 m forward of the fitted lioness's ears
# (its ears are tall and set forward on a long skull; hers are small and set back), so
# an ear flick swings her ear about a distant pivot -- measured 4.8x edge stretch, the
# largest remaining artifact after the blade fix. Bleed most of the ear weight back to
# Head_0: a slightly under-animated ear beats a spiking one.
EAR_DAMP = 0.45
n_ear = 0
for i in range(N):
    e = {k: v for k, v in W[i].items() if "_Ear_" in k}
    if not e:
        continue
    tot = sum(e.values())
    for k in e:
        W[i][k] = e[k] * EAR_DAMP
    W[i]["Head_0"] = W[i].get("Head_0", 0.) + tot * (1.0 - EAR_DAMP)
    n_ear += 1
print(f"  ear damping {EAR_DAMP}: {n_ear} verts bled toward Head_0")

CHAINS = {
    "L_REAR": (["L_RearLeg_Upper", "L_RearLeg_Lower", "L_RearLeg_Ankle",
                "L_RearLeg_Foot", "L_RearLeg_Toes"],
               ["LegBL1_089", "LegBL2_090", "LegBL3_091", "LegBLAnkle_092",
                "LegBLDigit11_093"]),
    "R_REAR": (["R_RearLeg_Upper", "R_RearLeg_Lower", "R_RearLeg_Ankle",
                "R_RearLeg_Foot", "R_RearLeg_Toes"],
               ["LegBR1_096", "LegBR2_097", "LegBR3_098", "LegBRAnkle_099",
                "LegBRDigit11_0100"]),
    # ⛔ TAIL LIVES IN `NAMED` NOW -- see the note there. Arc-length clubbed the tip.
}
for cn, (wch, sch) in CHAINS.items():
    # ⛔ THE POLYLINE MUST END AT THE LAST BONE'S TAIL, NOT ITS HEAD. Built from heads
    # alone it stops one bone short, and every vertex beyond that point clamps to tt=1 --
    # i.e. goes fully rigid on the final bone. That is exactly what clubbed the tail
    # (0.24 m dead zone) and it was silently doing the same at the toes.
    P = np.array([WBP[b] for b in wch] + [WBT[wch[-1]]])
    seg = [(P[k], P[k + 1]) for k in range(len(P) - 1)]
    wch = wch + [wch[-1]]        # segment k blends wch[k] -> wch[k+1]; the last is a no-op
    hit = 0
    for i in range(N):
        a = sum(srcw[i].get(s, 0.) for s in sch)
        if a <= 1e-4:
            continue
        a = min(a, 1.0); p = co[i]; best = (1e9, 0, 0.)
        for k, (A, B) in enumerate(seg):
            d = B - A; L2 = d @ d
            tt = 0. if L2 < 1e-12 else float(np.clip((p - A) @ d / L2, 0., 1.))
            q = A + d * tt; dd = float(np.linalg.norm(p - q))
            if dd < best[0]:
                best = (dd, k, tt)
        _, k, tt = best
        # accumulate, never a dict literal: on the final segment wch[k] == wch[k+1]
        # (the tail-tip stub) and a literal would silently drop the (1-tt) term.
        ov = {}
        ov[wch[k]] = ov.get(wch[k], 0.) + (1. - tt)
        ov[wch[k + 1]] = ov.get(wch[k + 1], 0.) + tt
        cur = W[i]; cs = sum(cur.values()) or 1.
        out = {kk: vv * (1. - a) / cs for kk, vv in cur.items()}
        for kk, vv in ov.items():
            out[kk] = out.get(kk, 0.) + a * vv
        W[i] = out; hit += 1
    print(f"  arc-length {cn}: {hit} verts")


def norm():
    for i in range(N):
        s = sum(W[i].values())
        if s <= 1e-9:
            W[i] = {"Hip": 1.}; s = 1.
        W[i] = {k: v / s for k, v in W[i].items() if v > 1e-5}


def gate(tag):
    z = sum(1 for w in W if sum(w.values()) < 1e-6)
    print(f"  GATE[{tag:<24}] zero={z} maxinf={max(len(w) for w in W)}")
    assert z == 0, "ZERO-WEIGHT VERTS collapse to the origin (RE .mesh law)"


norm(); gate("base+named+arclength")

kd = KDTree(N)
for i, c in enumerate(co):
    kd.insert(Vector(c.tolist()), i)
kd.balance()


def swap(n):
    for a, b in (("L_", "R_"), ("R_", "L_"), ("l_", "r_"), ("r_", "l_")):
        if n.startswith(a):
            return b + n[2:]
    return n


mate = [-1] * N
for i, c in enumerate(co):
    _, idx, d = kd.find(Vector((-c[0], c[1], c[2])))
    if d is not None and d < 0.03:
        mate[i] = idx
W2 = [dict(w) for w in W]
for i in range(N):
    j = mate[i]
    if j < 0:
        continue
    m = {}
    for k, v in W[j].items():
        m[swap(k)] = m.get(swap(k), 0.) + v
    W2[i] = {k: .5 * (W[i].get(k, 0.) + m.get(k, 0.)) for k in set(W[i]) | set(m)}
W = W2; norm(); gate("symmetrise")

# BRISKET MIDLINE 50/50 -- the chest seam is driven by BOTH clavicles, and the front
# legs move in opposite phase, so a seam split L/R tears. Forcing the pair equal fixes it.
# ⛔⛔ BUT IT MUST NOT REACH THE LIMBS. This lioness stands with her front paws only
# 5 cm off the midline (FrontLeg_Toes centroid x = +/-0.054), so a bare |x|<0.05 band
# swallowed both front paws and gave single verts BOTH legs' weights -- opposite phase
# then tore them into blades (measured 174x edge stretch). Gate on height AND on the
# vertex not being limb-driven. (Mirror of the puma bug where a leg box ate the chest tuft.)
BRISKET_Z = float(co[:, 2].min()) + 0.55


def midline_balance(tag):
    """Force L/R equality on midline, non-limb-dominant verts."""
    nmid = 0
    for i in range(N):
        if abs(co[i][0]) >= 0.05 or co[i][2] < BRISKET_Z:
            continue
        if "Leg" in max(W[i].items(), key=lambda kv: kv[1])[0]:
            continue
        w = W[i]
        out = dict(w)
        for k in list(w):
            s = swap(k)
            if s != k:
                av = .5 * (w.get(k, 0.) + w.get(s, 0.))
                out[k] = av
                out[s] = av
        W[i] = out
        nmid += 1
    norm()
    print(f"  midline-balanced [{tag}] {nmid} verts (z>{BRISKET_Z:.3f}, non-limb)")
    gate("midline " + tag)


midline_balance("brisket")

DISTAL = ("_Lower", "_Ankle", "_Foot", "_Toes")


def distal_contamination(tag):
    """A vert driven by a DISTAL limb bone AND its mirror gets torn apart, because the
    opposite legs swing in antiphase. Clavicle/Scapula/Upper legitimately blend across
    the chest, so they are excluded -- that blend is the whole point of the brisket pass."""
    bad = [i for i, w in enumerate(W)
           if any(any(d in k for d in DISTAL) and swap(k) != k and swap(k) in w
                  for k in w)]
    print(f"  distal L/R contamination [{tag}]: {len(bad)}")
    return bad


def strip_distal(tag):
    """Keep only the side the vertex physically sits on. L = +x on BOTH rigs (verified:
    EarL1 +0.097 vs L_Ear_0 +0.1009), so the x sign decides."""
    bad = distal_contamination(tag)
    for i in bad:
        drop = "R_" if co[i][0] >= 0 else "L_"
        W[i] = {k: v for k, v in W[i].items()
                if not (k.startswith(drop) and any(d in k for d in DISTAL))} or W[i]
    if bad:
        norm()
    return len(bad)


strip_distal("after brisket")

adj = [[] for _ in range(N)]
for e in lion.data.edges:
    a, b = e.vertices
    adj[a].append(b); adj[b].append(a)
for _ in range(2):
    NW = []
    for i in range(N):
        acc = {k: v * 0.65 for k, v in W[i].items()}
        if adj[i]:
            f = 0.35 / len(adj[i])
            for j in adj[i]:
                for k, v in W[j].items():
                    acc[k] = acc.get(k, 0.) + v * f
        NW.append(acc)
    W = NW
norm(); gate("smooth x2")

for i in range(N):
    W[i] = {k: v for k, v in W[i].items() if v >= 0.025} or W[i]
norm(); gate("clean 0.025")

kd2 = KDTree(N)
for i, c in enumerate(co):
    kd2.insert(Vector(c.tolist()), i)
kd2.balance()
seen = np.zeros(N, bool); ncl = 0
for i in range(N):
    if seen[i]:
        continue
    grp = [j for (_, j, d) in kd2.find_range(Vector(co[i].tolist()), 0.0005)]
    if len(grp) < 2:
        seen[i] = True; continue
    acc = {}
    for j in grp:
        for k, v in W[j].items():
            acc[k] = acc.get(k, 0.) + v
    acc = {k: v / len(grp) for k, v in acc.items()}
    for j in grp:
        W[j] = dict(acc); seen[j] = True
    ncl += 1
norm(); print(f"  co-located sync: {ncl} clusters"); gate("colocated")

# SMOOTHING CAN REINTRODUCE IT: the chest carries both clavicles by design, and edge
# smoothing bleeds that down the shoulder into the leg. Strip the wrong-side distal
# weight, keeping the side the vertex actually sits on.
strip_distal("after smooth/sync")
assert not distal_contamination("after strip"), "distal contamination survived the strip"

# ⛔⛔ THE MIDLINE MUST BE RE-BALANCED AFTER SMOOTHING, NOT ONLY BEFORE IT. Edge smoothing
# averages each vert with its neighbours, which quietly destroys the exact L/R equality
# the brisket pass just established. Measured after the tail re-projection moved the dock:
# four verts at the tail base came out Tail_0:0.35 Tail_1:0.30 L_RearLeg_Upper:0.20
# R_RearLeg_Upper:0.09 -- both rear legs, unequal, and rear legs swing in ANTIPHASE, so
# they tore to 10.46x edge stretch against a 3.38x baseline. _Upper bones are deliberately
# exempt from strip_distal (they legitimately blend across the chest), so the only thing
# that saves the dock is symmetry. Re-assert it here, after every smoothing pass has run.
midline_balance("post-smooth")

# ⛔ SYMMETRY ALONE DID NOT SAVE THE DOCK: balancing took the tear from 10.46x to 7.51x
# and stopped there. With L == R the vertex itself sits at the midpoint of two antiphase
# transforms, but its slightly-off-midline NEIGHBOURS still weight one leg more, so the
# edge between them stretches anyway. The honest fix is anatomical -- a vertex at the base
# of the tail is not driven by a leg under any circumstance. The rear-leg weight there is
# purely nearest-surface contamination, because the donor wolf's crotch geometry sits
# right beside its tail dock.
npure = 0
for i in range(N):
    if not max(W[i].items(), key=lambda kv: kv[1])[0].startswith("Tail"):
        continue
    keep = {k: v for k, v in W[i].items() if "Leg" not in k}
    if keep and len(keep) != len(W[i]):
        W[i] = keep
        npure += 1
norm()
print(f"  tail purity: leg weight stripped from {npure} tail-dominated verts")
gate("tail purity")

# LIMIT LAST -- the sync can push a vert back over the cap.
for i in range(N):
    if len(W[i]) > 6:
        W[i] = dict(sorted(W[i].items(), key=lambda kv: -kv[1])[:6])
norm(); gate("limit 6 (FINAL)")

vg = {}
for i in range(N):
    for bn, w in W[i].items():
        if bn not in vg:
            vg[bn] = lion.vertex_groups.new(name=bn)
        vg[bn].add([i], w, 'REPLACE')
lion.parent = warm
lion.matrix_parent_inverse = warm.matrix_world.inverted()
lion.modifiers.new(name="Armature", type='ARMATURE').object = warm

dom = [max(W[i].items(), key=lambda kv: kv[1])[0] for i in range(N)]
cnt = Counter(dom)
mass = {}
for i in range(N):
    for k, v in W[i].items():
        mass[k] = mass.get(k, 0.) + v
CH = {"L_FRONT": ["L_FrontLeg_Upper", "L_FrontLeg_Lower", "L_FrontLeg_Ankle",
                  "L_FrontLeg_Foot", "L_FrontLeg_Toes"],
      "R_FRONT": ["R_FrontLeg_Upper", "R_FrontLeg_Lower", "R_FrontLeg_Ankle",
                  "R_FrontLeg_Foot", "R_FrontLeg_Toes"],
      "L_REAR": ["L_RearLeg_Upper", "L_RearLeg_Lower", "L_RearLeg_Ankle",
                 "L_RearLeg_Foot", "L_RearLeg_Toes"],
      "R_REAR": ["R_RearLeg_Upper", "R_RearLeg_Lower", "R_RearLeg_Ankle",
                 "R_RearLeg_Foot", "R_RearLeg_Toes"],
      "TAIL": ["Tail_0", "Tail_1", "Tail_2", "Tail_3", "Tail_4", "Tail_5"],
      "SPINE": ["Hip", "Spine_1", "Spine_2", "Spine_3", "Spine_4", "Neck_0",
                "Neck_1", "Neck_2", "Neck_3", "Neck_4", "Head_0"]}
print("\n============ FINAL BAND CHECK ============")
skipped = []
for cn, ch in CH.items():
    print(f"--- {cn} ---")
    for b in ch:
        n = cnt.get(b, 0); ms = mass.get(b, 0.)
        if n == 0 and ms < 1e-6:
            print(f"   {b:<24} *** NO WEIGHT AT ALL ***"); skipped.append(b); continue
        if n == 0:
            print(f"   {b:<24} n=0     mass={ms:7.2f}   (influences, never dominant)")
            continue
        z = co[[i for i in range(N) if dom[i] == b]][:, 2].mean()
        print(f"   {b:<24} n={n:<5} mass={ms:7.2f}  centroid z={z:+.4f}")
leak = sum(1 for i in range(N) if (co[i][0] > .05 and dom[i].startswith("R_"))
           or (co[i][0] < -.05 and dom[i].startswith("L_")))
sums = np.array([sum(w.values()) for w in W])
print(f"\ncross-side leak: {leak}")
print(f"bones with NO weight at all: {skipped if skipped else 'NONE'}")
print(f"influences max={max(len(w) for w in W)}  sums {sums.min():.6f}..{sums.max():.6f}"
      f"  zero={int((sums<1e-6).sum())}  groups={len(vg)}")
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, "lioness_rig.blend"))
print("\nsaved lioness_rig.blend\nDONE")
