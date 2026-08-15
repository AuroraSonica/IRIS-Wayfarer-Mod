"""How much longer is her tail than the wolf's tail bone chain?

The first probe compared bone head_local against mesh-object coords -- different spaces,
so the projection numbers were nonsense. Do it properly: put BOTH in world space, walk
the chain as a polyline, and measure each tail vertex's arc-length position along it.
"""
import bpy
import numpy as np
from collections import defaultdict

BLEND = r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework\rs_tools\lioness_build\lioness_rig.blend"
bpy.ops.wm.open_mainfile(filepath=BLEND)
lion = bpy.data.objects["LIONESS"]
warm = bpy.data.objects["WOLF_ARM"]

# chain in graph order, WORLD space
chain = []
b = warm.data.bones.get("Tail_0")
while b is not None:
    chain.append(b)
    nxt = [c for c in b.children if "Tail" in c.name]
    b = nxt[0] if nxt else None
pts = [np.array((warm.matrix_world @ b.head_local)[:]) for b in chain]
pts.append(np.array((warm.matrix_world @ chain[-1].tail_local)[:]))
pts = np.array(pts)
seg = np.diff(pts, axis=0)
seglen = np.linalg.norm(seg, axis=1)
cum = np.concatenate([[0.0], np.cumsum(seglen)])
print(f"chain: {[b.name for b in chain]}")
print(f"  segment lengths: " + " ".join(f"{x:.4f}" for x in seglen))
print(f"  TOTAL CHAIN LENGTH = {cum[-1]:.4f} m")

gi = {g.index: g.name for g in lion.vertex_groups}
N = len(lion.data.vertices)
W = [dict() for _ in range(N)]
for v in lion.data.vertices:
    for ge in v.groups:
        if ge.weight > 0:
            W[v.index][gi[ge.group]] = ge.weight
dom = [max(w.items(), key=lambda kv: kv[1])[0] if w else "?" for w in W]
co = np.array([(lion.matrix_world @ v.co)[:] for v in lion.data.vertices])
names = {b.name for b in chain}
tv = [i for i in range(N) if dom[i] in names]


def arclen(p):
    """arc-length position of p projected onto the chain polyline (clamped per segment)"""
    best, bestd = 0.0, 1e9
    for k in range(len(seg)):
        a = pts[k]
        d = seg[k]
        L2 = float(d @ d)
        t = 0.0 if L2 < 1e-12 else float(np.clip((p - a) @ d / L2, 0.0, 1.0))
        q = a + t * d
        dist = float(np.linalg.norm(p - q))
        if dist < bestd:
            bestd, best = dist, cum[k] + t * seglen[k]
    return best, bestd


s = np.array([arclen(co[i]) for i in tv])
pos, off = s[:, 0], s[:, 1]
print(f"\nher tail: {len(tv)} verts")
print(f"  arc-length position along the chain: {pos.min():.4f} .. {pos.max():.4f} m")
print(f"  radial offset from the chain: mean {off.mean():.4f} max {off.max():.4f} m")
at_end = pos > cum[-1] - 1e-4
print(f"  verts PINNED at the chain end (arc-length saturated): {int(at_end.sum())} "
      f"({100*at_end.sum()/len(tv):.1f}%)")
if at_end.sum():
    print(f"    their radial offset: mean {off[at_end].mean():.4f} "
          f"max {off[at_end].max():.4f} m  <-- how far the club sticks out past the bone")

# where does her tail geometry actually END, measured along the chain direction?
axis = pts[-1] - pts[0]
axis = axis / np.linalg.norm(axis)
proj = (co[tv] - pts[0]) @ axis
print(f"\n  along the root->tip axis: her tail spans {proj.min():+.4f} .. {proj.max():+.4f} m")
print(f"  the bone chain spans      0.0000 .. {float((pts[-1]-pts[0]) @ axis):.4f} m")
print(f"  OVERHANG past the last bone tip = "
      f"{proj.max() - float((pts[-1]-pts[0]) @ axis):+.4f} m")

# per-bone share, plus how much of HER tail length each bone covers
per = defaultdict(list)
for k, i in enumerate(tv):
    per[dom[i]].append(pos[k])
print("\n  per-bone arc-length coverage of her tail:")
for b in chain:
    v = per.get(b.name, [])
    if not v:
        print(f"    {b.name:<10}    0 verts")
        continue
    v = np.array(v)
    print(f"    {b.name:<10} {len(v):>4} verts  arc {v.min():.3f}..{v.max():.3f} m "
          f"(span {v.max()-v.min():.3f})")
print("DONE")
