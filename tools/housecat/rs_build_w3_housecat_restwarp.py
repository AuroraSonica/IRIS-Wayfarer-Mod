"""Build a Witcher house cat fitted to the DD2 Redwolf rest skeleton.

The first prototype retained Witcher anatomical weights but only applied a
single whole-body fit.  Its vertices therefore orbited around distant Redwolf
joint pivots.  The second prototype transferred weights from the donor surface
without first matching anatomical joints, assigning several cat regions to the
wrong part of the host.

This build performs a joint-position rest-pose transfer. For every weighted
source bone, the Witcher vertex receives the offset between that bone's aligned
rest position and the mapped Redwolf joint position. The same normalised source
weights are then bound to the mapped DD2 bones. We deliberately transfer joint
positions rather than complete bone frames: Witcher and RE Engine use different
bone-axis/roll conventions, and blending their raw bases flattens the mesh.
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
SOURCE_BLEND = RS / "all animal work.blend"
ENTITY = (
    RS / "witcher 3 files" / "Animations" / "full animation files" / "Animals"
    / "00. models for animations" / "cat" / "t_01__cat.w2ent"
)
BONE_MAP = RS / "rs_w3_catdog_bone_map.json"
OUTPUT_BLEND = RS / "w3_housecat_dd2_restwarp_v3.blend"
OUTPUT_REPORT = RS / "w3_housecat_dd2_restwarp_v3_report.json"

TARGET_ARMATURE = "Armature_ch23_001.mesh.240423143"
TARGET_DONOR = "LOD0_G0_S1_ch23_001"
OUTPUT_MESH = "LOD0_G0_S1_W3_CAT_RESTWARP"
COLLECTION = "W3_HOUSECAT_DD2_RESTWARP_V3"


def enable_entity_importer():
    result = bpy.ops.preferences.addon_enable(module="bl_ext.user_default.witcher3_tools")
    if "FINISHED" not in result:
        raise RuntimeError(f"Could not enable Witcher 3 Tools: {result}")
    from bl_ext.user_default.witcher3_tools.importers.import_entity import import_direct_entity_file
    return import_direct_entity_file


def bounds(points):
    lo = Vector((min(p.x for p in points), min(p.y for p in points), min(p.z for p in points)))
    hi = Vector((max(p.x for p in points), max(p.y for p in points), max(p.z for p in points)))
    return lo, hi


def rounded(values):
    return [round(float(value), 6) for value in values]


def clear_except(keep):
    for obj in list(bpy.data.objects):
        if obj not in keep:
            bpy.data.objects.remove(obj, do_unlink=True)
    for collection in list(bpy.data.collections):
        if collection.users == 0:
            bpy.data.collections.remove(collection)


def move_exclusively(obj, collection):
    for current in list(obj.users_collection):
        current.objects.unlink(obj)
    collection.objects.link(obj)


report = {"format": "iris-w3-housecat-dd2-restwarp-v3", "error": None}
try:
    bpy.ops.wm.open_mainfile(filepath=str(SOURCE_BLEND), load_ui=False)
    target_armature = bpy.data.objects.get(TARGET_ARMATURE)
    donor = bpy.data.objects.get(TARGET_DONOR)
    if not target_armature or target_armature.type != "ARMATURE":
        raise RuntimeError(f"Missing target armature {TARGET_ARMATURE}")
    if not donor or donor.type != "MESH":
        raise RuntimeError(f"Missing target donor {TARGET_DONOR}")
    clear_except({target_armature, donor})

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
    source_meshes = [
        obj for obj in imported
        if obj.type == "MESH" and "lod0" in obj.name.lower()
    ]
    if len(source_meshes) != 1:
        raise RuntimeError(f"Expected one Witcher LOD0 mesh, got {len(source_meshes)}")
    source = source_meshes[0]
    if not source_armature or source_armature.type != "ARMATURE":
        raise RuntimeError("Witcher entity importer returned no armature")

    mapping = json.loads(BONE_MAP.read_text(encoding="utf-8"))["cat"]
    source_group_names = {group.index: group.name for group in source.vertex_groups}
    missing_source = sorted(name for name in mapping if name not in source_armature.data.bones)
    missing_target = sorted(name for name in mapping.values() if name not in target_armature.data.bones)
    if missing_source or missing_target:
        raise RuntimeError(
            f"Bone map incomplete: missing source={missing_source}, target={missing_target}"
        )

    # Match the overall source contract to the donor before the per-joint warp.
    orientation = Matrix.Rotation(math.pi, 4, "Z")
    source_world = [source.matrix_world @ vertex.co for vertex in source.data.vertices]
    oriented = [orientation @ point for point in source_world]
    target_world = [donor.matrix_world @ vertex.co for vertex in donor.data.vertices]
    source_lo, source_hi = bounds(oriented)
    target_lo, target_hi = bounds(target_world)
    scale = (target_hi.y - target_lo.y) / (source_hi.y - source_lo.y)
    source_centre = (source_lo + source_hi) * 0.5
    target_centre = (target_lo + target_hi) * 0.5
    translation = Vector((
        target_centre.x - source_centre.x * scale,
        target_centre.y - source_centre.y * scale,
        target_lo.z - source_lo.z * scale,
    ))
    align = Matrix.Translation(translation) @ Matrix.Diagonal((scale, scale, scale, 1.0)) @ orientation

    source_bone_world = {
        name: align @ source_armature.matrix_world @ source_armature.data.bones[name].matrix_local
        for name in mapping
    }
    target_bone_world = {
        name: target_armature.matrix_world @ target_armature.data.bones[target].matrix_local
        for name, target in mapping.items()
    }
    joint_delta = {
        name: target_bone_world[name].translation - source_bone_world[name].translation
        for name in mapping
    }

    fit = source.copy()
    fit.data = source.data.copy()
    fit.name = OUTPUT_MESH
    fit.data.name = OUTPUT_MESH
    bpy.context.scene.collection.objects.link(fit)

    # Apply a blended joint-position warp in world space. This uses the Witcher
    # skin's anatomical segmentation, not nearest surface proximity, while
    # preserving its own cross-section orientation and volume.
    target_inverse = donor.matrix_world.inverted()
    ignored_weight = 0.0
    max_source_influences = 0
    for source_vertex, fit_vertex in zip(source.data.vertices, fit.data.vertices):
        aligned_position = align @ source.matrix_world @ source_vertex.co
        accumulated = Vector((0.0, 0.0, 0.0))
        total = 0.0
        max_source_influences = max(max_source_influences, len(source_vertex.groups))
        for assignment in source_vertex.groups:
            source_name = source_group_names.get(assignment.group)
            if source_name not in mapping or assignment.weight <= 0.0:
                ignored_weight += max(0.0, float(assignment.weight))
                continue
            accumulated += (aligned_position + joint_delta[source_name]) * assignment.weight
            total += assignment.weight
        if total <= 1e-8:
            accumulated = aligned_position
            total = 1.0
        fit_vertex.co = target_inverse @ (accumulated / total)
    fit.data.update()

    # Retain the same source weights, renamed to their DD2 counterparts.  Merge
    # safely in case future maps intentionally converge multiple source bones.
    for group in list(fit.vertex_groups):
        fit.vertex_groups.remove(group)
    target_groups = {}
    for source_vertex in source.data.vertices:
        merged = {}
        for assignment in source_vertex.groups:
            source_name = source_group_names.get(assignment.group)
            target_name = mapping.get(source_name)
            if target_name and assignment.weight > 0.0:
                merged[target_name] = merged.get(target_name, 0.0) + assignment.weight
        total = sum(merged.values())
        if total <= 1e-8:
            merged = {"Hip": 1.0}
            total = 1.0
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
    modifier = fit.modifiers.new("DD2 Redwolf Armature", "ARMATURE")
    modifier.object = target_armature

    collection = bpy.data.collections.new(COLLECTION)
    bpy.context.scene.collection.children.link(collection)
    for obj in (target_armature, donor, fit):
        move_exclusively(obj, collection)
    donor.hide_render = True
    donor.hide_set(True)
    fit.hide_render = False
    fit.hide_set(False)
    target_armature.show_in_front = True
    for obj in imported:
        if obj not in (source, source_armature):
            bpy.data.objects.remove(obj, do_unlink=True)
    if source in bpy.data.objects.values():
        bpy.data.objects.remove(source, do_unlink=True)
    if source_armature in bpy.data.objects.values():
        bpy.data.objects.remove(source_armature, do_unlink=True)

    vertices_world = [fit.matrix_world @ vertex.co for vertex in fit.data.vertices]
    out_lo, out_hi = bounds(vertices_world)
    report.update(
        source_entity=str(ENTITY),
        output_blend=str(OUTPUT_BLEND),
        mesh=fit.name,
        vertices=len(fit.data.vertices),
        polygons=len(fit.data.polygons),
        source_groups=len(source_group_names),
        target_groups=len(target_groups),
        max_source_influences=max_source_influences,
        global_fit_scale=scale,
        recommended_instance_scale=1.0 / scale,
        global_translation=rounded(translation),
        output_bounds={"min": rounded(out_lo), "max": rounded(out_hi), "size": rounded(out_hi - out_lo)},
        ignored_unmapped_weight_total=ignored_weight,
        method="mapped-joint position warp plus original anatomical weights",
    )
    bpy.ops.wm.save_as_mainfile(filepath=str(OUTPUT_BLEND), check_existing=False)
except Exception:
    report["error"] = traceback.format_exc()
finally:
    OUTPUT_REPORT.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))
