"""Render her tail under the vanilla idle, and profile how far off the bone line it sits.

The weight fix cannot be judged from vertex counts -- dominance counts say nothing about
whether the deformation is smooth. Render it, and separately profile the radial offset
ALONG the tail so we know whether the remaining 0.128 m mean offset is harmless rump
verts at the base or a genuinely displaced tube.
"""
import bpy, sys, os
import numpy as np
from collections import defaultdict

BLEND = r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework\rs_tools\lioness_build\lioness_rig.blend"
MOTDIR = r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\DD2_EXTRACT\re_chunk_000\natives\STM\animation\ch\ch23\motlist"
ADDON = r"C:\Users\Krist\AppData\Roaming\Blender Foundation\Blender\4.3\scripts\addons\blender-dd2-tools-suite-main"
OUT = r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework\rs_tools\lioness_build\tail"
os.makedirs(OUT, exist_ok=True)

bpy.ops.wm.open_mainfile(filepath=BLEND)
bpy.ops.preferences.addon_enable(module="blender-dd2-tools-suite-main")
lion = bpy.data.objects["LIONESS"]
warm = bpy.data.objects["WOLF_ARM"]

chain = []
b = warm.data.bones.get("Tail_0")
while b is not None:
    chain.append(b)
    nxt = [c for c in b.children if "Tail" in c.name]
    b = nxt[0] if nxt else None
pts = [np.array((warm.matrix_world @ bb.head_local)[:]) for bb in chain]
pts.append(np.array((warm.matrix_world @ chain[-1].tail_local)[:]))
pts = np.array(pts)
seg = np.diff(pts, axis=0)
seglen = np.linalg.norm(seg, axis=1)
cum = np.concatenate([[0.0], np.cumsum(seglen)])

gi = {g.index: g.name for g in lion.vertex_groups}
N = len(lion.data.vertices)
W = [dict() for _ in range(N)]
for v in lion.data.vertices:
    for ge in v.groups:
        if ge.weight > 0:
            W[v.index][gi[ge.group]] = ge.weight
dom = [max(w.items(), key=lambda kv: kv[1])[0] if w else "?" for w in W]
co = np.array([(lion.matrix_world @ v.co)[:] for v in lion.data.vertices])
names = {bb.name for bb in chain}
tv = [i for i in range(N) if dom[i] in names]


def arclen(p):
    best, bestd = 0.0, 1e9
    for k in range(len(seg)):
        a, d = pts[k], seg[k]
        L2 = float(d @ d)
        t = 0.0 if L2 < 1e-12 else float(np.clip((p - a) @ d / L2, 0.0, 1.0))
        q = a + t * d
        dist = float(np.linalg.norm(p - q))
        if dist < bestd:
            bestd, best = dist, cum[k] + t * seglen[k]
    return best, bestd


s = np.array([arclen(co[i]) for i in tv])
pos, off = s[:, 0], s[:, 1]
print("=== radial offset PROFILE along the tail (is the tube on the bone line?) ===")
EDGES = np.linspace(0, cum[-1], 9)
for k in range(len(EDGES) - 1):
    m = (pos >= EDGES[k]) & (pos < EDGES[k] + (EDGES[1] - EDGES[0]) + 1e-9)
    if not m.any():
        continue
    print(f"   arc {EDGES[k]:.3f}-{EDGES[k+1]:.3f} m  n={int(m.sum()):>4}  "
          f"offset mean={off[m].mean():.4f} max={off[m].max():.4f}")

# how many influences do the tip verts actually have? a rigid club = 1 influence
tip = [i for k, i in enumerate(tv) if pos[k] > cum[-1] - 0.25]
ninf = [len(W[i]) for i in tip]
tail5only = sum(1 for i in tip if len(W[i]) == 1)
print(f"\n   distal 0.25 m: {len(tip)} verts, mean influences {np.mean(ninf):.2f}, "
      f"single-bone (rigid) {tail5only}")

# ---------------------------------------------------------------- render
sys.path.insert(0, ADDON)
from mot import mot_loader
for f in sorted(os.listdir(MOTDIR)):
    try:
        mot_loader.load_motlist(os.path.join(MOTDIR, f), warm.data)
    except Exception:
        pass
if not warm.animation_data:
    warm.animation_data_create()

for o in bpy.data.objects:
    if o.type == 'MESH' and o is not lion:
        o.hide_render = True
sc = bpy.context.scene
sc.render.engine = 'BLENDER_EEVEE_NEXT'
sc.render.resolution_x, sc.render.resolution_y = 1100, 800
sc.render.film_transparent = False
w = bpy.data.worlds.new("W")
w.use_nodes = True
w.node_tree.nodes["Background"].inputs[0].default_value = (0.05, 0.05, 0.06, 1)
sc.world = w
lampd = bpy.data.lights.new("L", 'SUN')
lampd.energy = 4.0
lamp = bpy.data.objects.new("L", lampd)
sc.collection.objects.link(lamp)
lamp.rotation_euler = (0.9, 0.2, 1.2)
camd = bpy.data.cameras.new("C")
cam = bpy.data.objects.new("C", camd)
sc.collection.objects.link(cam)
sc.camera = cam

act = bpy.data.actions.get("ch23_000_com_idle_loop")
names_l = list(names)


def shot(frame, path):
    warm.animation_data.action = act
    sc.frame_set(frame)
    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    ev = lion.evaluated_get(dg)
    me = ev.to_mesh()
    P = np.array([(lion.matrix_world @ v.co)[:] for v in me.vertices])
    ev.to_mesh_clear()
    T = P[tv]                                   # frame on the TAIL only
    c = T.mean(0)
    r = float(np.linalg.norm(T - c, axis=1).max())
    camd.type = 'ORTHO'
    camd.ortho_scale = r * 2.6
    cam.location = (c[0] + 4.0, c[1] - 2.2, c[2] + 1.1)
    d = c - np.array(cam.location[:])
    import mathutils
    cam.rotation_euler = mathutils.Vector(d).to_track_quat('-Z', 'Y').to_euler()
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)
    print("   wrote", path)


# ⭐ THE REST POSE IS WHAT AURORA IS JUDGING. Every earlier render was of the idle
# animation, which RAISES the tail by design -- so it curved no matter how straight the
# rest shape was, and told us nothing about the thing she was pointing at.
act_rest = warm.animation_data.action
warm.animation_data.action = None
for pb in warm.pose.bones:
    pb.location = (0, 0, 0)
    pb.rotation_quaternion = (1, 0, 0, 0)
    pb.rotation_euler = (0, 0, 0)
    pb.scale = (1, 1, 1)
sc.frame_set(0)
bpy.context.view_layer.update()
dg = bpy.context.evaluated_depsgraph_get()
evm = lion.evaluated_get(dg)
mm = evm.to_mesh()
P = np.array([(lion.matrix_world @ v.co)[:] for v in mm.vertices])
evm.to_mesh_clear()
T = P[tv]
resid = np.array([arclen(p)[1] for p in T])
print(f"   REST POSE: tail offset from the bone chain "
      f"mean {resid.mean():.4f} max {resid.max():.4f} m")
camd.type = 'ORTHO'
c = T.mean(0)
camd.ortho_scale = float(np.linalg.norm(T - c, axis=1).max()) * 2.6
cam.location = (c[0] + 4.0, c[1] - 2.2, c[2] + 1.1)
import mathutils
cam.rotation_euler = mathutils.Vector(c - np.array(cam.location[:])).to_track_quat(
    '-Z', 'Y').to_euler()
sc.render.filepath = os.path.join(OUT, "tail_REST.png")
bpy.ops.render.render(write_still=True)
print("   wrote", sc.render.filepath)
warm.animation_data.action = act_rest

if act:
    for fr in (1, 40, 80):
        shot(fr, os.path.join(OUT, f"tail_idle_f{fr:03d}.png"))
else:
    print("   !! idle action missing")
print("DONE")
