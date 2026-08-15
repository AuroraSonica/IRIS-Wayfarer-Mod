"""EXPORT ch23_001.mesh -- material table, REAL eye submesh, dummies, UV2, pre-flight.

⛔ THE FALLBACK-MATERIAL LAW: the mesh's material table must reproduce ALL of the
vanilla mdf2's entries, not just the ones that are used. A 1-entry table loaded fine but
the GPU could not resolve the draw and fell back to a tan stand-in -- that cost two days
on the panther. Vanilla ch23_001 = 6 entries, MEASURED from its own mdf2:
    ch23_001_body_mat, ch23_001_eye_mat, ch23_001_head_mat,
    ch23_001_fur1_mat, ch23_001_fur2_mat, vfx_mat
Materials resolve by NAME, not by slot order, which the shipped v1.0 build proved.

⛔⛔ THE EYES MUST BE A REAL eye_mat SUBMESH (Aurora, field: "the panther eyes aren't
yellow"). v1.0 routed every real vertex to body_mat and left eye_mat as a 1 mm dummy
triangle parked at the Hip. The yellow eyes were never a texture -- they come from a
runtime write of Emissive_Color1/2 onto eye_mat, and the vanilla material is fully wired
for it (Emissive_Enable 1.0, Emissive_Intensity 8.2, Emissive_Color1 (1.0,0.4,0.0)). With
no real geometry on that material the write painted an invisible speck. Worse, the eyes
that DID render sat on body_mat, which the panther recolour multiplies to 12% brightness
-- and you cannot make yellow through a 0.12 multiplier at all.

⭐ AND REMAP THEIR UVs TO FILL THE EYE ATLAS. Her eye caps' island occupies just 0.41% of
the body atlas (u 0.457-0.530, v 0.289-0.363 ~ 150 px). eye_ALBE is its own 512 px
texture used by nothing else, so an affine remap of the island onto 0..1 gives the eyes
MORE resolution than they had, not less, and lets the emissive mask be authored per-iris.

⛔ UV2: the GLB's second layer was junk (u -2.87..16.70, v -81.5..41.47) and 73% of it
landed inside 0..1, sampling live UniquePattern / EnemyMask / Occlusion texels at random
-- that is the Akamaru rust-patch overlay, which no mdf2 edit can undo. body_mat samples
FIVE maps through UV2. We ship a black MSKM and a neutral ATOC to kill two of them, and
SHRINK the UV2 layout onto a single texel so the rest read one constant instead of a
scatter. ⭐ Shrink, never collapse: a degenerate UV2 gives invalid tangents.

⛔ PRE-FLIGHT: RE/DD2 exporters write the EVALUATED mesh. A leftover pose bakes the
animation into the geometry (the horse shipped walk-frame-20 once). Clear the action AND
every pose bone, then assert evaluated == rest before writing.
"""
import bpy, sys, os, math, json
import numpy as np
from mathutils import Vector
from mathutils.kdtree import KDTree

BLEND = r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework\rs_tools\lioness_build\lioness_rig.blend"
OUT = r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework\rs_tools\lioness_build"

# ⭐ CODE picks which resource set this mesh belongs to. ch23_001 = the lioness (Puma
# slot, vanilla paths). ch23_002 = the panther, which now owns its own mesh, mdf2 and
# textures so both variants can be installed at once instead of shadowing each other.
# Material names must carry the code because the mdf2 resolves materials BY NAME -- that
# is also what stops IrisWildCats' PANTHER_MATERIALS table from matching and re-tinting
# a coat that is already charcoal in the texture.
CODE = "ch23_001"
if "--" in sys.argv:
    CODE = sys.argv[sys.argv.index("--") + 1]
MESH_OUT = os.path.join(OUT, f"{CODE}.mesh.240423143")
EYE_JSON = os.path.join(OUT, "eye_island.json")
print(f"===== exporting for {CODE} -> {MESH_OUT}")

# vanilla mdf2 order, measured: body, eye, head, fur1, fur2, vfx
MATS = [f"{CODE}_body_mat", f"{CODE}_eye_mat", f"{CODE}_head_mat",
        f"{CODE}_fur1_mat", f"{CODE}_fur2_mat", "vfx_mat"]
BODY_MAT, EYE_MAT = MATS[0], MATS[1]

bpy.ops.wm.open_mainfile(filepath=BLEND)
bpy.ops.preferences.addon_enable(module="blender-dd2-tools-suite-main")
lion = bpy.data.objects["LIONESS"]
warm = bpy.data.objects["WOLF_ARM"]

# ---------------- clear pose (evaluated-mesh trap) ----------------
if warm.animation_data:
    warm.animation_data.action = None
for pb in warm.pose.bones:
    pb.location = (0, 0, 0)
    pb.rotation_quaternion = (1, 0, 0, 0)
    pb.rotation_euler = (0, 0, 0)
    pb.scale = (1, 1, 1)
bpy.context.scene.frame_set(0)
bpy.context.view_layer.update()

dg = bpy.context.evaluated_depsgraph_get()
ev = lion.evaluated_get(dg); me = ev.to_mesh()
evc = np.array([v.co[:] for v in me.vertices])
ev.to_mesh_clear()
rest = np.array([v.co[:] for v in lion.data.vertices])
d = float(np.abs(evc - rest).max())
print(f"evaluated-vs-rest displacement: {d:.8f}")
assert d < 1e-5, "POSED GEOMETRY would be baked into the export"


# ---------------- find the eye caps ----------------
def eye_vertex_indices(ob):
    """The four eye caps are 121-vert loose shells once duplicate verts are welded.
    Weld on a THROWAWAY copy (never the export mesh -- welding would fuse UV seams),
    separate by loose part, then map the survivors back to real indices by position."""
    dat = ob.data.copy()
    tmp = bpy.data.objects.new("EYESPLIT", dat)
    bpy.context.collection.objects.link(tmp)
    tmp.matrix_world = ob.matrix_world.copy()
    bpy.ops.object.select_all(action='DESELECT')
    tmp.select_set(True)
    bpy.context.view_layer.objects.active = tmp
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.mesh.remove_doubles(threshold=0.0001)
    bpy.ops.mesh.separate(type='LOOSE')
    bpy.ops.object.mode_set(mode='OBJECT')
    parts = [o for o in bpy.data.objects if o.name.startswith("EYESPLIT")]
    pts = []
    for p in parts:
        if len(p.data.vertices) != 121:
            continue
        pts += [(p.matrix_world @ v.co) for v in p.data.vertices]
    for p in parts:
        bpy.data.objects.remove(p, do_unlink=True)
    kd = KDTree(len(ob.data.vertices))
    for i, v in enumerate(ob.data.vertices):
        kd.insert(ob.matrix_world @ v.co, i)
    kd.balance()
    idx = set()
    for pt in pts:
        _, i, dd = kd.find(pt)
        if dd is not None and dd < 1e-4:
            idx.add(i)
    return idx


EYES = eye_vertex_indices(lion)
print(f"eye caps: {len(EYES)} vertices matched back to the export mesh")
assert 400 < len(EYES) < 600, f"eye cap detection returned {len(EYES)} verts -- expected ~484"

eye_faces = [p.index for p in lion.data.polygons
             if all(v in EYES for v in p.vertices)]
print(f"eye faces: {len(eye_faces)}")
assert eye_faces, "no faces are wholly inside the eye caps"

# ---------------- UV2 -> shrink onto one texel (built from the ORIGINAL UV0) ----------
uv0 = lion.data.uv_layers[0]
uv2 = lion.data.uv_layers[1] if len(lion.data.uv_layers) > 1 else \
    lion.data.uv_layers.new(name="UV2")
a = np.array([d_.uv[:] for d_ in uv0.data])
CT, SC = 0.5, 0.0020           # centre texel, shrink factor (structure preserved)
b = (a - a.mean(0)) * SC + CT
for i, d_ in enumerate(uv2.data):
    d_.uv = b[i]
print(f"UV2 shrunk onto one texel: u {b[:,0].min():.5f}..{b[:,0].max():.5f} "
      f"v {b[:,1].min():.5f}..{b[:,1].max():.5f}")

# ---------------- remap the eye island onto its own 0..1 atlas ----------------
eye_loops = [li for f in eye_faces for li in lion.data.polygons[f].loop_indices]
E = np.array([uv0.data[li].uv[:] for li in eye_loops])
u0min, v0min = E.min(0)
u0max, v0max = E.max(0)
MARGIN = 0.06        # keep the island off the texture edge so BC blocks cannot bleed
span = max(u0max - u0min, v0max - v0min)
print(f"eye island in the body atlas: u {u0min:.4f}..{u0max:.4f} "
      f"v {v0min:.4f}..{v0max:.4f}  (span {span:.4f})")
for li in eye_loops:
    u, v = uv0.data[li].uv
    uv0.data[li].uv = (MARGIN + (u - u0min) / span * (1 - 2 * MARGIN),
                       MARGIN + (v - v0min) / span * (1 - 2 * MARGIN))
json.dump({"u0": float(u0min), "v0": float(v0min), "span": float(span),
           "margin": MARGIN, "n_eye_verts": len(EYES), "n_eye_faces": len(eye_faces)},
          open(EYE_JSON, "w"), indent=1)
print(f"wrote {EYE_JSON}")

# ---------------- split body / eye by material ----------------
lion.data.materials.clear()
for mn in (BODY_MAT, EYE_MAT):
    m = bpy.data.materials.get(mn) or bpy.data.materials.new(mn)
    m.name = mn
    lion.data.materials.append(m)
for p in lion.data.polygons:
    p.material_index = 0
for f in eye_faces:
    lion.data.polygons[f].material_index = 1

bpy.ops.object.select_all(action='DESELECT')
lion.select_set(True)
bpy.context.view_layer.objects.active = lion
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.select_all(action='SELECT')
bpy.ops.mesh.quads_convert_to_tris(quad_method='BEAUTY', ngon_method='BEAUTY')
bpy.ops.object.mode_set(mode='OBJECT')
before = set(bpy.data.objects)
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.separate(type='MATERIAL')
bpy.ops.object.mode_set(mode='OBJECT')
spawned = [o for o in bpy.data.objects if o not in before]
print(f"separate by material -> {len(spawned)} new object(s)")


def only_material(ob, name):
    """One material per object: the exporter reads a submesh's material from slot 0."""
    ob.data.materials.clear()
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.name = name
    ob.data.materials.append(m)
    for p in ob.data.polygons:
        p.material_index = 0


parts = [lion] + spawned
body = max(parts, key=lambda o: len(o.data.vertices))
eye = [o for o in parts if o is not body]
assert len(eye) == 1, f"expected exactly one eye object, got {len(eye)}"
eye = eye[0]
only_material(body, BODY_MAT)
only_material(eye, EYE_MAT)
body.name = f"LOD0_G0_S0_{CODE}"
eye.name = "LOD0_G0_S1_eye"
print(f"  body {len(body.data.vertices)}v {len(body.data.polygons)}f -> {BODY_MAT}")
print(f"  eye  {len(eye.data.vertices)}v {len(eye.data.polygons)}f -> {EYE_MAT}")
assert len(eye.data.vertices) == len(EYES), \
    f"eye submesh has {len(eye.data.vertices)} verts, expected {len(EYES)}"

# ---------------- dummy submeshes for the remaining slots ----------------
hip = warm.matrix_world @ warm.data.bones["Hip"].head_local
dummies = []
for k, mn in enumerate(MATS[2:], start=2):
    mesh = bpy.data.meshes.new(f"DUMMY_{mn}")
    s = 0.001
    mesh.from_pydata([(0, 0, 0), (s, 0, 0), (0, 0, s)], [], [(0, 1, 2)])
    mesh.update()
    ob = bpy.data.objects.new(f"LOD0_G0_S{k}_dummy", mesh)
    bpy.context.collection.objects.link(ob)
    ob.location = hip
    mat = bpy.data.materials.get(mn) or bpy.data.materials.new(mn)
    mat.name = mn
    mesh.materials.append(mat)
    vg = ob.vertex_groups.new(name="Hip")
    vg.add([0, 1, 2], 1.0, 'REPLACE')
    ob.parent = warm
    ob.matrix_parent_inverse = warm.matrix_world.inverted()
    ob.modifiers.new(name="Armature", type='ARMATURE').object = warm
    for nm in ("UVMap", "UV2"):
        uvl = mesh.uv_layers.new(name=nm)
        for dd in uvl.data:
            dd.uv = (CT, CT)
    dummies.append(ob)
print(f"created {len(dummies)} dummy submeshes: {[o.name for o in dummies]}")

# ---------------- export ----------------
for o in bpy.data.objects:
    o.hide_viewport = False
    o.hide_set(False)
bpy.ops.object.select_all(action='DESELECT')
for o in [body, eye] + dummies + [warm]:
    o.select_set(True)
bpy.context.view_layer.objects.active = body
print(f"selected for export: {sorted(o.name for o in bpy.context.selected_objects)}")


def v3d():
    for w in bpy.context.window_manager.windows:
        for ar in w.screen.areas:
            if ar.type == 'VIEW_3D':
                return {"window": w, "area": ar, "region": ar.regions[-1]}


with bpy.context.temp_override(**v3d()):
    bpy.ops.dd2_export.dd2_mesh(filepath=MESH_OUT, skip_uv_islands=True)
print("exported ->", MESH_OUT,
      os.path.getsize(MESH_OUT) if os.path.exists(MESH_OUT) else "MISSING")

bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, "lioness_export.blend"))
print("DONE")
