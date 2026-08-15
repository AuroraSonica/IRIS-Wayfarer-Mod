"""Re-import both exported meshes and compare them against VANILLA ch23_001.

I never re-ran this after splitting the eyes onto their own submesh, and that split
changed the mesh's whole submesh structure (2 real + 4 dummies, was 1 real + 5 dummies).
If the exporter produced something the engine cannot load, the prefab that references it
fails to instantiate -- and a character whose prefab fails does not appear AT ALL, which
is exactly the symptom.
"""
import bpy, sys, os
import numpy as np

VAN = r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\DD2_EXTRACT\re_chunk_000\natives\STM\character\ch\ch23_001\ch23_001.mesh.240423143"
OUT = r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework\rs_tools\lioness_build"
TARGETS = [("VANILLA", VAN),
           ("LIONESS ch23_001", os.path.join(OUT, "ch23_001.mesh.240423143")),
           ("PANTHER ch23_002", os.path.join(OUT, "ch23_002.mesh.240423143"))]


def v3d():
    for w in bpy.context.window_manager.windows:
        for a in w.screen.areas:
            if a.type == 'VIEW_3D':
                return {"window": w, "area": a, "region": a.regions[-1]}


for label, path in TARGETS:
    print(f"\n================ {label}")
    print(f"   file: {os.path.basename(path)}  {os.path.getsize(path)} bytes")
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.preferences.addon_enable(module="blender-dd2-tools-suite-main")
    try:
        with bpy.context.temp_override(**v3d()):
            bpy.ops.dd2_import.dd2_mesh(filepath=path, fix_rotation=True,
                                        import_material=False, all_LOD=False,
                                        connect_bones=False)
    except Exception as e:
        print(f"   !!!! IMPORT FAILED: {e}")
        continue
    meshes = [o for o in bpy.data.objects if o.type == 'MESH']
    arms = [o for o in bpy.data.objects if o.type == 'ARMATURE']
    print(f"   submeshes: {len(meshes)}   armatures: {len(arms)}")
    tot = 0
    for o in sorted(meshes, key=lambda x: x.name):
        mats = [m.name for m in o.data.materials] if o.data.materials else []
        tot += len(o.data.vertices)
        print(f"      {o.name:<34} {len(o.data.vertices):>6}v {len(o.data.polygons):>6}f "
              f"mats={mats}")
    print(f"   total verts: {tot}")
    if arms:
        print(f"   bones: {len(arms[0].data.bones)}")
    # weight sanity on the largest submesh
    big = max(meshes, key=lambda o: len(o.data.vertices))
    sums = []
    ninf = []
    for v in big.data.vertices:
        w = [g.weight for g in v.groups if g.weight > 0]
        sums.append(sum(w))
        ninf.append(len(w))
    sums = np.array(sums); ninf = np.array(ninf)
    print(f"   {big.name}: weight sums {sums.min():.4f}..{sums.max():.4f}  "
          f"max influences {ninf.max()}  zero-weight verts {int((sums<1e-6).sum())}")
print("\nDONE")
