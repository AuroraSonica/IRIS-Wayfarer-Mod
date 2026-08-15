"""Find the verts that SHRED during walk and name the bone driving them.

Eyeballing a render tells you there is a blade; it does not tell you which bone.
Metric = per-vertex EDGE STRETCH vs the rest pose (max ratio over incident edges).
A vertex bound to a bone its neighbours do not share stretches its edges hugely --
that is exactly what a blade/shard is.
"""
import bpy, sys, os, math
import numpy as np
from collections import Counter, defaultdict

BLEND = r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework\rs_tools\lioness_build\lioness_rig.blend"
MOTDIR = r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\DD2_EXTRACT\re_chunk_000\natives\STM\animation\ch\ch23\motlist"
ADDON = r"C:\Users\Krist\AppData\Roaming\Blender Foundation\Blender\4.3\scripts\addons\blender-dd2-tools-suite-main"

bpy.ops.wm.open_mainfile(filepath=BLEND)
bpy.ops.preferences.addon_enable(module="blender-dd2-tools-suite-main")
lion = bpy.data.objects["LIONESS"]; warm = bpy.data.objects["WOLF_ARM"]
sys.path.insert(0, ADDON)
from mot import mot_loader
for f in sorted(os.listdir(MOTDIR)):
    try:
        mot_loader.load_motlist(os.path.join(MOTDIR, f), warm.data)
    except Exception:
        pass
if not warm.animation_data:
    warm.animation_data_create()

gi = {g.index: g.name for g in lion.vertex_groups}
N = len(lion.data.vertices)
Wt = [dict() for _ in range(N)]
for v in lion.data.vertices:
    for ge in v.groups:
        if ge.weight > 0:
            Wt[v.index][gi[ge.group]] = ge.weight
dom = [max(w.items(), key=lambda kv: kv[1])[0] if w else "?" for w in Wt]
edges = [tuple(e.vertices) for e in lion.data.edges]
inc = defaultdict(list)
for a, b in edges:
    inc[a].append(b); inc[b].append(a)


def ev():
    dg = bpy.context.evaluated_depsgraph_get()
    e = lion.evaluated_get(dg); me = e.to_mesh()
    a = np.array([(lion.matrix_world @ v.co)[:] for v in me.vertices])
    e.to_mesh_clear()
    return a


warm.animation_data.action = None
bpy.context.scene.frame_set(0); bpy.context.view_layer.update()
rest = ev()
rest_len = {}
for a, b in edges:
    rest_len[(a, b)] = float(np.linalg.norm(rest[a] - rest[b]))

worst = np.zeros(N)
for cn, frames in (("ch23_000_comWA_walk_loop", [116, 232, 349, 465]),
                   ("ch23_000_com_idle_loop", [62, 124]),
                   ("ch23_000_comBM_idle_threat_01", [62, 124])):
    if cn not in bpy.data.actions:
        continue
    warm.animation_data.action = bpy.data.actions[cn]
    for f in frames:
        bpy.context.scene.frame_set(f); bpy.context.view_layer.update()
        cur = ev()
        for (a, b), r0 in rest_len.items():
            if r0 < 1e-5:
                continue
            ratio = float(np.linalg.norm(cur[a] - cur[b])) / r0
            if ratio > worst[a]:
                worst[a] = ratio
            if ratio > worst[b]:
                worst[b] = ratio

print(f"edge-stretch across walk/idle/threat: median {np.median(worst):.3f} "
      f"p99 {np.percentile(worst,99):.3f} max {worst.max():.3f}")
for thr in (2.0, 3.0, 5.0):
    bad = np.nonzero(worst > thr)[0]
    print(f"\n--- verts stretching > {thr}x : {len(bad)} ---")
    if len(bad) == 0:
        continue
    c = Counter(dom[i] for i in bad)
    for n, k in c.most_common(12):
        idx = [i for i in bad if dom[i] == n]
        p = rest[idx]
        print(f"   {n:<26} {k:>5}  rest centroid "
              f"x={p[:,0].mean():+.3f} y={p[:,1].mean():+.3f} z={p[:,2].mean():+.3f}")

bad = np.nonzero(worst > 3.0)[0]
if len(bad):
    print("\nsample of the worst 12 verts:")
    order = np.argsort(-worst)[:12]
    for i in order:
        ws = sorted(Wt[i].items(), key=lambda kv: -kv[1])
        print(f"   v{i:<6} stretch={worst[i]:6.2f} rest=({rest[i][0]:+.3f},"
              f"{rest[i][1]:+.3f},{rest[i][2]:+.3f})  weights="
              + ", ".join(f"{k}:{v:.2f}" for k, v in ws))
print("DONE")
