"""Bind the Witcher house cat to DD2's native rabbit skeleton.

The rabbit is the correct behavioural chassis for a domestic cat: small,
passive/fleeing and already supported by Capcom's pickup/carry motions.  This
bench preserves the Witcher mesh's anatomical weights while aligning its joints
to the native ch99_200 rabbit rest skeleton.  Several cat-only chains converge
where the rabbit has fewer bones (notably the tail); those weights are merged.
"""

from __future__ import annotations

import json
import math
import traceback
from pathlib import Path

import bpy
from mathutils import Matrix, Vector


ROOT = Path(r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework")
RS = ROOT / "rs_tools"
RABBIT_BLEND = RS / "dd2_rabbit_ch99_200_source.blend"
ENTITY = (
    RS / "witcher 3 files" / "Animations" / "full animation files" / "Animals"
    / "00. models for animations" / "cat" / "t_01__cat.w2ent"
)
OUTPUT_BLEND = RS / "w3_housecat_dd2_rabbit_host.blend"
OUTPUT_REPORT = RS / "w3_housecat_dd2_rabbit_host_report.json"

TARGET_ARMATURE = "ch99_200 Armature"
TARGET_DONOR = "LOD_0_Group_0_Sub_0__body_mat"
OUTPUT_MESH = "LOD0_G0_S0_W3_CAT_RABBIT_HOST"
COLLECTION = "W3_HOUSECAT_DD2_RABBIT_HOST"

MAP = {
    "pelvis": "Hip",
    "spine1": "Spine_0",
    "spine2": "Spine_2",
    "spine3": "Spine_3",
    "neck": "Neck_0",
    "neck1": "Neck_0",
    "head": "Head_0",
    "jaw": "Head_0",
    # Rabbit ears are extremely long and independently animated. Cat ears stay
    # rigid to the head until we have the custom Witcher cat motion set live.
    "l_ear": "Head_0",
    "r_ear": "Head_0",
    "tail1": "Tail",
    "tail2": "Tail",
    "tail3": "Tail",
    "tail4": "Tail",
    "tail5": "Tail",
    "l_shoulder": "L_Shoulder_Clavicle",
    "l_bicep": "L_FrontLeg_Upper",
    "l_forearm": "L_FrontLeg_Lower",
    "l_hand": "L_FrontLeg_Ankle",
    "l_frontpaw": "L_FrontLeg_Toes",
    "r_shoulder": "R_Shoulder_Clavicle",
    "r_bicep": "R_FrontLeg_Upper",
    "r_forearm": "R_FrontLeg_Lower",
    "r_hand": "R_FrontLeg_Ankle",
    "r_frontpaw": "R_FrontLeg_Toes",
    "l_thigh": "L_RearLeg_Upper",
    "l_shin": "L_RearLeg_Lower",
    "l_foot": "L_RearLeg_Ankle",
    "l_backpaw": "L_RearLeg_Toes",
    "r_thigh": "R_RearLeg_Upper",
    "r_shin": "R_RearLeg_Lower",
    "r_foot": "R_RearLeg_Ankle",
    "r_backpaw": "R_RearLeg_Toes",
}

# Converging several source bones onto one target joint must not also converge
# their geometry onto that one point. Reuse the proximal joint delta so the
# original cat neck and tail retain their authored shapes as rigid chains.
WARP_DRIVER = {
    "neck1": "neck",
    "jaw": "head",
    "l_ear": "head",
    "r_ear": "head",
    "tail2": "tail1",
    "tail3": "tail1",
    "tail4": "tail1",
    "tail5": "tail1",
}


def enable_entity_importer():
    result = bpy.ops.preferences.addon_enable(module="bl_ext.user_default.witcher3_tools")
    if "FINISHED" not in result:
        raise RuntimeError(f"Could not enable Witcher 3 Tools: {result}")
    from bl_ext.user_default.witcher3_tools.importers.import_entity import import_direct_entity_file
    return import_direct_entity_file


def rounded(values):
    return [round(float(value), 6) for value in values]


def bounds(points):
    lo = Vector((min(p.x for p in points), min(p.y for p in points), min(p.z for p in points)))
    hi = Vector((max(p.x for p in points), max(p.y for p in points), max(p.z for p in points)))
    return lo, hi


def move_exclusively(obj, collection):
    for current in list(obj.users_collection):
        current.objects.unlink(obj)
    collection.objects.link(obj)


report = {"format": "iris-w3-housecat-dd2-rabbit-host-v1", "error": None}
try:
    bpy.ops.wm.open_mainfile(filepath=str(RABBIT_BLEND), load_ui=False)
    target_armature = bpy.data.objects.get(TARGET_ARMATURE)
    donor = bpy.data.objects.get(TARGET_DONOR)
    if not target_armature or target_armature.type != "ARMATURE":
        raise RuntimeError(f"Missing rabbit armature {TARGET_ARMATURE}")
    if not donor or donor.type != "MESH":
        raise RuntimeError(f"Missing rabbit donor {TARGET_DONOR}")
    for obj in list(bpy.data.objects):
        if obj not in (target_armature, donor):
            bpy.data.objects.remove(obj, do_unlink=True)
    target_armature.data.pose_position = "REST"
    if target_armature.animation_data:
        target_armature.animation_data.action = None
    for pose_bone in target_armature.pose.bones:
        pose_bone.matrix_basis.identity()
    bpy.context.view_layer.update()

    import_entity = enable_entity_importer()
    before = set(bpy.data.objects)
    source_armature = import_entity(str(ENTITY))
    imported = list(set(bpy.data.objects) - before)
    source_meshes = [obj for obj in imported if obj.type == "MESH" and "lod0" in obj.name.lower()]
    if len(source_meshes) != 1:
        raise RuntimeError(f"Expected one Witcher cat LOD0, got {len(source_meshes)}")
    source = source_meshes[0]
    if not source_armature or source_armature.type != "ARMATURE":
        raise RuntimeError("Witcher cat entity returned no armature")
    missing_source = sorted(name for name in MAP if name not in source_armature.data.bones)
    missing_target = sorted(set(MAP.values()) - set(target_armature.data.bones.keys()))
    if missing_source or missing_target:
        raise RuntimeError(f"Bone-map mismatch source={missing_source}, target={missing_target}")

    # Use hip-to-head joint distance rather than total mesh bounds. The cat's
    # long tail and the rabbit's short tail would otherwise shrink the body.
    orientation = Matrix.Rotation(math.pi, 4, "Z")
    source_rig_world = source_armature.matrix_world
    target_rig_world = target_armature.matrix_world
    source_hip = orientation @ (source_rig_world @ source_armature.data.bones["pelvis"].matrix_local).translation
    source_head = orientation @ (source_rig_world @ source_armature.data.bones["head"].matrix_local).translation
    target_hip = (target_rig_world @ target_armature.data.bones["Hip"].matrix_local).translation
    target_head = (target_rig_world @ target_armature.data.bones["Head_0"].matrix_local).translation
    source_body = (source_head - source_hip).length
    target_body = (target_head - target_hip).length
    scale = target_body / source_body
    translation = target_hip - source_hip * scale
    align = Matrix.Translation(translation) @ Matrix.Diagonal((scale, scale, scale, 1.0)) @ orientation

    source_bone_world = {
        name: align @ source_rig_world @ source_armature.data.bones[name].matrix_local
        for name in MAP
    }
    target_bone_world = {
        name: target_rig_world @ target_armature.data.bones[target].matrix_local
        for name, target in MAP.items()
    }
    joint_delta = {}
    for name in MAP:
        driver = WARP_DRIVER.get(name, name)
        joint_delta[name] = (
            target_bone_world[driver].translation - source_bone_world[driver].translation
        )

    fit = source.copy()
    fit.data = source.data.copy()
    fit.name = OUTPUT_MESH
    fit.data.name = OUTPUT_MESH
    bpy.context.scene.collection.objects.link(fit)
    source_group_names = {group.index: group.name for group in source.vertex_groups}
    target_inverse = donor.matrix_world.inverted()
    for source_vertex, fit_vertex in zip(source.data.vertices, fit.data.vertices):
        aligned = align @ source.matrix_world @ source_vertex.co
        position = Vector((0.0, 0.0, 0.0))
        total = 0.0
        for assignment in source_vertex.groups:
            source_name = source_group_names.get(assignment.group)
            if source_name in MAP and assignment.weight > 0.0:
                position += (aligned + joint_delta[source_name]) * assignment.weight
                total += assignment.weight
        fit_vertex.co = target_inverse @ (position / total if total > 1e-8 else aligned)
    fit.data.update()

    for group in list(fit.vertex_groups):
        fit.vertex_groups.remove(group)
    target_groups = {}
    for source_vertex in source.data.vertices:
        merged = {}
        for assignment in source_vertex.groups:
            target_name = MAP.get(source_group_names.get(assignment.group))
            if target_name and assignment.weight > 0.0:
                merged[target_name] = merged.get(target_name, 0.0) + assignment.weight
        total = sum(merged.values())
        if total <= 1e-8:
            merged, total = {"Hip": 1.0}, 1.0
        for target_name, weight in merged.items():
            group = target_groups.get(target_name)
            if group is None:
                group = fit.vertex_groups.new(name=target_name)
                target_groups[target_name] = group
            group.add([source_vertex.index], weight / total, "REPLACE")

    for modifier in list(fit.modifiers):
        fit.modifiers.remove(modifier)
    fit.parent = target_armature
    fit.matrix_parent_inverse = donor.matrix_parent_inverse.copy()
    fit.matrix_basis = donor.matrix_basis.copy()
    modifier = fit.modifiers.new("DD2 Rabbit Armature", "ARMATURE")
    modifier.object = target_armature

    collection = bpy.data.collections.new(COLLECTION)
    bpy.context.scene.collection.children.link(collection)
    for obj in (target_armature, donor, fit):
        move_exclusively(obj, collection)
    donor.hide_render = True
    donor.hide_set(True)
    fit.hide_render = False
    fit.hide_set(False)
    for obj in imported:
        if obj not in (source, source_armature):
            bpy.data.objects.remove(obj, do_unlink=True)
    bpy.data.objects.remove(source, do_unlink=True)
    bpy.data.objects.remove(source_armature, do_unlink=True)

    world_points = [fit.matrix_world @ vertex.co for vertex in fit.data.vertices]
    lo, hi = bounds(world_points)
    report.update(
        source_entity=str(ENTITY),
        rabbit_source=str(RABBIT_BLEND),
        output_blend=str(OUTPUT_BLEND),
        mesh=fit.name,
        vertices=len(fit.data.vertices),
        polygons=len(fit.data.polygons),
        rabbit_bones=len(target_armature.data.bones),
        source_groups=len(source_group_names),
        target_groups=len(target_groups),
        max_influences=max((len(v.groups) for v in fit.data.vertices), default=0),
        body_fit_scale=scale,
        recommended_instance_scale=1.0,
        translation=rounded(translation),
        output_bounds={"min": rounded(lo), "max": rounded(hi), "size": rounded(hi - lo)},
        method="native rabbit host; joint-position warp; merged Witcher anatomical weights",
        limitation="Rabbit has one tail bone; cat tail is rigid until a custom skeleton route exists.",
    )
    bpy.ops.wm.save_as_mainfile(filepath=str(OUTPUT_BLEND), check_existing=False)
except Exception:
    report["error"] = traceback.format_exc()
finally:
    OUTPUT_REPORT.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))
