"""Swap the v09 cat mesh into the v6 animation bench and render QA sheets."""

from pathlib import Path

import bpy
from mathutils import Vector

ROOT = Path(r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework")
RS = ROOT / "rs_tools"
BENCH = RS / "w3_housecat_rabbit_animation_retarget_v7.blend"
V09 = RS / "w3_housecat_dd2_rabbit_host_v09.blend"
QA_BLEND = RS / "w3_housecat_v7_v09_qa.blend"
OUT = RS / "housecat_qa_v7_v09"
OUT.mkdir(exist_ok=True)

MESH_NAME = "LOD0_G0_S0_W3_CAT_RABBIT_HOST"
TARGET = "ch99_200 Armature"

RENDERS = {
    "walk": ((0, 8, 16, 24, 32), ("side", "front")),
    "run": ((0, 4, 8, 12), ("side", "front")),
    "walk_left": ((8, 14, 20, 26), ("side",)),
    "taunt": ((30, 39, 50), ("side", "front")),
    "cat_hissing": ((44, 51), ("side",)),
    "eating_loop": ((34, 67, 101), ("side",)),
    "idle01": ((80,), ("side", "front")),
    "idle02": ((159, 300), ("side",)),
    "death": ((34, 54), ("side",)),
}

bpy.ops.wm.open_mainfile(filepath=str(BENCH), load_ui=False)
target = bpy.data.objects[TARGET]

# remove the old cat mesh, bring in the v09 object (drags its own armature)
old = bpy.data.objects.get(MESH_NAME)
if old:
    bpy.data.objects.remove(old, do_unlink=True)
before = set(bpy.data.objects)
with bpy.data.libraries.load(str(V09), link=False) as (avail, req):
    req.objects = [MESH_NAME]
new_objs = [o for o in bpy.data.objects if o not in before]
cat = next(o for o in new_objs if o.type == "MESH" and MESH_NAME in o.name)
bpy.context.scene.collection.objects.link(cat)
cat.name = MESH_NAME
cat.parent = target
for mod in cat.modifiers:
    if mod.type == "ARMATURE":
        mod.object = target
# drop any dragged-in duplicate armature
for obj in list(bpy.data.objects):
    if obj.type == "ARMATURE" and obj.name.startswith(TARGET) and obj is not target:
        bpy.data.objects.remove(obj, do_unlink=True)
cat.hide_render = False

rabbit = bpy.data.objects["LOD_0_Group_0_Sub_0__body_mat"]
rabbit.hide_render = True
for obj in bpy.data.objects:
    if obj.type == "MESH" and obj not in (cat,):
        obj.hide_render = True

scene = bpy.context.scene
scene.render.engine = "BLENDER_WORKBENCH"
scene.render.resolution_x = 720
scene.render.resolution_y = 560
scene.render.image_settings.file_format = "PNG"
scene.display.shading.light = "STUDIO"
scene.display.shading.studio_light = "paint.sl"
scene.display.shading.show_shadows = True
scene.display.shading.show_cavity = True
scene.display.shading.cavity_type = "BOTH"
scene.display.shading.color_type = "OBJECT"
scene.display.shading.background_type = "VIEWPORT"
scene.display.shading.background_color = (0.025, 0.03, 0.04)
cat.color = (0.42, 0.39, 0.35, 1.0)

camera_data = bpy.data.cameras.new("RS_QA_CAM")
camera = bpy.data.objects.new("RS_QA_CAM", camera_data)
scene.collection.objects.link(camera)
scene.camera = camera
camera.data.type = "ORTHO"


def frame_camera(view):
    ev = cat.evaluated_get(bpy.context.evaluated_depsgraph_get())
    pts = [ev.matrix_world @ v.co for v in ev.data.vertices]
    lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    centre = (lo + hi) * 0.5
    size = hi - lo
    if view == "side":
        camera.data.ortho_scale = max(size.y, size.z) * 1.3
        camera.location = centre + Vector((max(size.y, size.z) * 2.5, 0.0, 0.0))
    else:
        camera.data.ortho_scale = max(size.x, size.z) * 1.3
        camera.location = centre + Vector((0.0, -max(size.x, size.z) * 2.5, 0.0))
    camera.rotation_euler = (centre - camera.location).to_track_quat("-Z", "Y").to_euler()


for clip, (frames, views) in RENDERS.items():
    act = bpy.data.actions.get(f"IRIS_HOUSECAT_RABBIT_V7__{clip}")
    if act is None:
        print("SKIP", clip)
        continue
    target.animation_data.action = act
    for frame in frames:
        scene.frame_set(frame)
        bpy.context.view_layer.update()
        for view in views:
            frame_camera(view)
            scene.render.filepath = str(OUT / f"{clip}_f{frame:03d}_{view}.png")
            bpy.ops.render.render(write_still=True)
    print("RENDERED", clip)

bpy.ops.wm.save_as_mainfile(filepath=str(QA_BLEND), check_existing=False)
print("QA_BENCH_OK", QA_BLEND)
