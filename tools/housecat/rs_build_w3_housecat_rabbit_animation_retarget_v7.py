"""V7 housecat->rabbit retarget: ABSOLUTE anatomical direction transfer.

Field evidence (CE preview 2026-08-18): the cat rest spine holds 16 deg of
curl, the rabbit rest spine 44 deg.  V5/V6's rest-relative transfer therefore
over-folds every pose by the stance difference ("full body bend" on hissing/
taunt/idle02) and keeps the rabbit's wide front-leg base under the cat's
narrow authored gait ("front paws off" in the walk).

The shipping mesh is the WITCHER CAT warped onto this skeleton, so its
natural pose manifold is cat poses.  V7 therefore sets each driven segment to
the source's ABSOLUTE direction expressed in the anatomical body frame; the
rabbit contributes bone lengths only.  This also deletes the near-180-degree
rotation_difference singularity outright (no rest->live delta exists), so the
V6 one-shot incremental path is no longer needed.

Kept from V6: hemisphere-consistent quaternion keys, straight-line horizontal
Hip drift removal on looping clips.

New: per-clip constant GROUND PIN (horse law: measure the lowest foot-chain
point across the clip, apply ONE constant Hip height offset - never per-frame,
that flattens the bob).  Cat-absolute leg directions with rabbit segment
lengths change total leg reach, so the v1 Hip height is re-grounded.
"""

from __future__ import annotations

from pathlib import Path
import json
import math

import bpy
from mathutils import Matrix, Quaternion, Vector


ROOT = Path(r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework")
RS = ROOT / "rs_tools"
INPUT = RS / "w3_housecat_rabbit_animation_retarget.blend"
SOURCE_BENCH = RS / "w3_catdog_animation_retarget.blend"
OUTPUT = RS / "w3_housecat_rabbit_animation_retarget_v7.blend"
REPORT = RS / "w3_housecat_rabbit_animation_retarget_v7_report.json"
SOURCE_NAME = "W3_CAT__SOURCE_RIG"
TARGET_NAME = "ch99_200 Armature"

LOOP_CLIPS = (
    "idle01", "idle02", "idle03", "idle04", "idle05",
    "walk", "walk_left", "walk_right", "run", "run_left", "run_right",
    "eating_loop",
)
ONESHOT_CLIPS = ("eating_start", "eating_stop", "taunt", "cat_hissing", "death")
CLIPS = LOOP_CLIPS[:5] + LOOP_CLIPS[5:11] + ("eating_start", "eating_loop",
                                             "eating_stop", "taunt",
                                             "cat_hissing", "death")

DIRECTION_SEGMENTS = (
    ("pelvis", "spine1", "Spine_0", "Spine_1"),
    ("spine1", "spine2", "Spine_1", "Spine_2"),
    ("spine2", "spine3", "Spine_2", "Spine_3"),
    ("spine3", "neck", "Spine_3", "Neck_0"),
    ("neck", "head", "Neck_0", "Head_0"),
    ("head", None, "Head_0", None),
    ("tail1", "tail2", "Tail", None),
    ("l_bicep", "l_forearm", "L_FrontLeg_Upper", "L_FrontLeg_Lower"),
    ("l_forearm", "l_hand", "L_FrontLeg_Lower", "L_FrontLeg_Ankle"),
    ("l_hand", "l_frontpaw", "L_FrontLeg_Ankle", "L_FrontLeg_Foot"),
    ("r_bicep", "r_forearm", "R_FrontLeg_Upper", "R_FrontLeg_Lower"),
    ("r_forearm", "r_hand", "R_FrontLeg_Lower", "R_FrontLeg_Ankle"),
    ("r_hand", "r_frontpaw", "R_FrontLeg_Ankle", "R_FrontLeg_Foot"),
    ("l_thigh", "l_shin", "L_RearLeg_Upper", "L_RearLeg_Lower"),
    ("l_shin", "l_foot", "L_RearLeg_Lower", "L_RearLeg_Ankle"),
    ("l_foot", "l_backpaw", "L_RearLeg_Ankle", "L_RearLeg_Foot"),
    ("r_thigh", "r_shin", "R_RearLeg_Upper", "R_RearLeg_Lower"),
    ("r_shin", "r_foot", "R_RearLeg_Lower", "R_RearLeg_Ankle"),
    ("r_foot", "r_backpaw", "R_RearLeg_Ankle", "R_RearLeg_Foot"),
)

NEUTRAL_BONES = (
    "L_Shoulder_Clavicle", "R_Shoulder_Clavicle",
    "L_FrontLeg_Foot", "R_FrontLeg_Foot",
    "L_RearLeg_Foot", "R_RearLeg_Foot",
    "L_FrontLeg_Toes", "R_FrontLeg_Toes",
    "L_RearLeg_Toes", "R_RearLeg_Toes",
)
SOLVED_BONES = tuple(dict.fromkeys(segment[2] for segment in DIRECTION_SEGMENTS))
BAKED_BONES = ("Hip",) + SOLVED_BONES + NEUTRAL_BONES

UP_INDEX = 2  # world Z carries height in this bench (death drop confirms)

FOOT_CHAIN = (
    "L_FrontLeg_Ankle", "L_FrontLeg_Foot", "L_FrontLeg_Toes",
    "R_FrontLeg_Ankle", "R_FrontLeg_Foot", "R_FrontLeg_Toes",
    "L_RearLeg_Ankle", "L_RearLeg_Foot", "L_RearLeg_Toes",
    "R_RearLeg_Ankle", "R_RearLeg_Foot", "R_RearLeg_Toes",
)


def segment_basis(primary: Vector, secondary_hint: Vector) -> Matrix:
    primary = primary.normalized()
    secondary = secondary_hint - primary * primary.dot(secondary_hint)
    if secondary.length < 1.0e-8:
        raise RuntimeError("degenerate quadruped body basis")
    secondary.normalize()
    tertiary = primary.cross(secondary).normalized()
    return Matrix((primary, secondary, tertiary)).transposed()


def rest_head_world(obj, bone_name: str) -> Vector:
    return obj.matrix_world @ obj.data.bones[bone_name].head_local


def pose_head_world(obj, bone_name: str) -> Vector:
    return obj.matrix_world @ obj.pose.bones[bone_name].matrix.translation


def source_tail_world(obj, bone_name: str, posed: bool) -> Vector:
    bone = obj.pose.bones[bone_name] if posed else obj.data.bones[bone_name]
    matrix = bone.matrix if posed else bone.matrix_local
    length = bone.bone.length if posed else bone.length
    return obj.matrix_world @ (matrix @ Vector((0.0, length, 0.0)))


def remove_rotation_curves(action, bone_names):
    prefixes = tuple(f'pose.bones["{name}"].rotation_' for name in bone_names)
    for curve in list(action.fcurves):
        if curve.data_path.startswith(prefixes):
            action.fcurves.remove(curve)


def source_segment_direction(source, parent_name, child_name, posed):
    if posed:
        head = pose_head_world(source, parent_name)
        end = (
            pose_head_world(source, child_name)
            if child_name is not None
            else source_tail_world(source, parent_name, True)
        )
    else:
        head = rest_head_world(source, parent_name)
        end = (
            rest_head_world(source, child_name)
            if child_name is not None
            else source_tail_world(source, parent_name, False)
        )
    direction = end - head
    if direction.length < 1.0e-8:
        raise RuntimeError(f"zero source segment: {parent_name} -> {child_name}")
    return direction.normalized()


bpy.ops.wm.open_mainfile(filepath=str(INPUT), load_ui=False)
scene = bpy.context.scene
source = bpy.data.objects.get(SOURCE_NAME)
target = bpy.data.objects.get(TARGET_NAME)
if source is None or target is None:
    raise RuntimeError(f"missing source/target rigs: {source!r}, {target!r}")
source.data.pose_position = "POSE"
target.data.pose_position = "POSE"
source.animation_data_create()
target.animation_data_create()

wanted_source_actions = {f"W3_CAT__{clip}" for clip in CLIPS}
missing_source_actions = sorted(wanted_source_actions - set(bpy.data.actions.keys()))
if missing_source_actions:
    with bpy.data.libraries.load(str(SOURCE_BENCH), link=False) as (available, requested):
        unavailable = sorted(set(missing_source_actions) - set(available.actions))
        if unavailable:
            raise RuntimeError(f"source bench is missing actions: {unavailable}")
        requested.actions = missing_source_actions
for clip in CLIPS:
    src_action = bpy.data.actions.get(f"W3_CAT__{clip}")
    if src_action is not None:
        src_action.use_fake_user = True  # keep sources in the saved bench

source_body_rest = segment_basis(
    rest_head_world(source, "l_shoulder") - rest_head_world(source, "r_shoulder"),
    rest_head_world(source, "spine3") - rest_head_world(source, "pelvis"),
)
target_body_rest = segment_basis(
    rest_head_world(target, "L_FrontLeg_Upper")
    - rest_head_world(target, "R_FrontLeg_Upper"),
    rest_head_world(target, "Spine_3") - rest_head_world(target, "Hip"),
)
target_world_rotation = target.matrix_world.to_3x3().normalized()
target_world_inverse = target_world_rotation.inverted()

source_rest_local = {}
target_rest_local = {}
target_child_by_bone = {}
for source_parent, source_child, target_bone, target_child in DIRECTION_SEGMENTS:
    source_rest_local[target_bone] = (
        source_body_rest.inverted()
        @ source_segment_direction(source, source_parent, source_child, False)
    ).normalized()
    if target_child is None:
        target_rest_bone = target.data.bones[target_bone]
        target_direction = (
            target.matrix_world
            @ (target_rest_bone.matrix_local @ Vector((0.0, target_rest_bone.length, 0.0)))
            - rest_head_world(target, target_bone)
        ).normalized()
    else:
        target_direction = (
            rest_head_world(target, target_child) - rest_head_world(target, target_bone)
        ).normalized()
    target_rest_local[target_bone] = (
        target_body_rest.inverted() @ target_direction
    ).normalized()
    target_child_by_bone[target_bone] = target_child

rest_ground = min(rest_head_world(target, name)[UP_INDEX] for name in FOOT_CHAIN)

hierarchy = sorted(target.data.bones, key=lambda bone: len(bone.parent_recursive))
report = {
    "format": "iris-w3-housecat-rabbit-retarget-v7",
    "source": str(INPUT),
    "output": str(OUTPUT),
    "method": (
        "v5 anatomical direction solver + hemisphere-consistent quaternions; "
        "path-following incremental solve on one-shot clips; "
        "straight-line horizontal Hip drift removed from looping clips"
    ),
    "solved_bones": list(SOLVED_BONES),
    "neutral_bones": list(NEUTRAL_BONES),
    "clips": [],
}

for clip in CLIPS:
    source_action = bpy.data.actions.get(f"W3_CAT__{clip}")
    base_action = bpy.data.actions.get(f"IRIS_HOUSECAT_RABBIT__{clip}")
    if source_action is None or base_action is None:
        raise RuntimeError(f"missing action pair for {clip}")
    old = bpy.data.actions.get(f"IRIS_HOUSECAT_RABBIT_V7__{clip}")
    if old:
        bpy.data.actions.remove(old)
    action = base_action.copy()
    action.name = f"IRIS_HOUSECAT_RABBIT_V7__{clip}"
    action.use_fake_user = True
    action["iris_retarget_version"] = 7
    action["iris_limb_solver"] = "absolute anatomical direction solver"
    remove_rotation_curves(action, BAKED_BONES)
    source.animation_data.action = source_action
    target.animation_data.action = action

    first, last = (int(round(value)) for value in source_action.frame_range)

    prev_keyed_quat = {}
    # Head_0/Tail have no child joint: their correction base can flip twist
    # branch on large excursions, so their rotation is continued from the
    # previous frame's achieved orientation instead of re-derived.
    handle_prev_rot = {}
    handle_first_rot = {}

    for frame in range(first, last + 1):
        scene.frame_set(frame)
        bpy.context.view_layer.update()

        source_body_live = segment_basis(
            pose_head_world(source, "l_shoulder") - pose_head_world(source, "r_shoulder"),
            pose_head_world(source, "spine3") - pose_head_world(source, "pelvis"),
        )
        body_relative = source_body_rest.inverted() @ source_body_live
        target_body_live = target_body_rest @ body_relative
        body_world_delta = target_body_live @ target_body_rest.inverted()

        desired_direction = {}
        for source_parent, source_child, target_bone, _target_child in DIRECTION_SEGMENTS:
            source_live_local = (
                source_body_live.inverted()
                @ source_segment_direction(source, source_parent, source_child, True)
            ).normalized()
            # V7: the target segment adopts the source's absolute anatomical
            # direction; rabbit rest orientation no longer biases the pose.
            desired_world = (target_body_live @ source_live_local).normalized()
            desired_direction[target_bone] = (
                target_world_inverse @ desired_world
            ).normalized()

        desired_matrices = {}
        desired_bases = {}
        for bone in hierarchy:
            pose_bone = target.pose.bones[bone.name]
            if bone.parent:
                parent_matrix = desired_matrices[bone.parent.name]
                rest_relative = bone.parent.matrix_local.inverted() @ bone.matrix_local
                if bone.name in BAKED_BONES:
                    if bone.name == "Hip":
                        basis = Matrix.Translation(pose_bone.matrix_basis.translation)
                    else:
                        basis = Matrix.Identity(4)
                else:
                    basis = pose_bone.matrix_basis.copy()
                base_matrix = parent_matrix @ rest_relative @ basis
            else:
                basis = pose_bone.matrix_basis.copy()
                base_matrix = bone.matrix_local @ basis

            desired = base_matrix
            if bone.name == "Hip":
                rest_rotation_world = (
                    target_world_rotation @ bone.matrix_local.to_3x3().normalized()
                )
                desired_rotation = target_world_inverse @ (
                    body_world_delta @ rest_rotation_world
                )
                desired = Matrix.LocRotScale(
                    base_matrix.translation,
                    desired_rotation.to_quaternion(),
                    Vector((1.0, 1.0, 1.0)),
                )
            elif bone.name in desired_direction:
                child_name = target_child_by_bone[bone.name]
                if child_name is None:
                    child_head_local = Vector((0.0, bone.length, 0.0))
                else:
                    child_head_local = (
                        bone.matrix_local.inverted()
                        @ target.data.bones[child_name].head_local
                    )
                # temporal continuity only where no loop seam exists: on loop
                # clips the accumulated twist fails to close (tail wrapped 233
                # degrees on run_right when tried) — loops keep the
                # deterministic base-derived solve instead.
                if (clip in ONESHOT_CLIPS and child_name is None
                        and bone.name in handle_prev_rot):
                    prev_rot = handle_prev_rot[bone.name]
                    prev_direction = (prev_rot @ child_head_local).normalized()
                    correction = prev_direction.rotation_difference(
                        desired_direction[bone.name]
                    )
                    rotation = correction.to_matrix() @ prev_rot
                else:
                    current_direction = (
                        base_matrix.to_3x3().normalized() @ child_head_local
                    ).normalized()
                    correction = current_direction.rotation_difference(
                        desired_direction[bone.name]
                    )
                    rotation = correction.to_matrix() @ base_matrix.to_3x3().normalized()
                if child_name is None:
                    handle_prev_rot[bone.name] = rotation.copy()
                    handle_first_rot.setdefault(bone.name, rotation.copy())
                desired = Matrix.LocRotScale(
                    base_matrix.translation, rotation.to_quaternion(), Vector((1.0, 1.0, 1.0))
                )

            desired_matrices[bone.name] = desired
            if bone.name in BAKED_BONES:
                parent_base = (
                    desired_matrices[bone.parent.name]
                    @ (bone.parent.matrix_local.inverted() @ bone.matrix_local)
                )
                desired_bases[bone.name] = (
                    parent_base.inverted() @ desired
                ).to_quaternion()

        for bone_name in BAKED_BONES:
            quat = desired_bases[bone_name]
            prev = prev_keyed_quat.get(bone_name)
            if prev is not None and quat.dot(prev) < 0.0:
                quat = Quaternion((-quat.w, -quat.x, -quat.y, -quat.z))
            prev_keyed_quat[bone_name] = quat.copy()
            pose_bone = target.pose.bones[bone_name]
            pose_bone.rotation_mode = "QUATERNION"
            pose_bone.rotation_quaternion = quat
            pose_bone.keyframe_insert(
                data_path="rotation_quaternion", frame=frame, group=bone_name
            )

    for curve in action.fcurves:
        if any(f'pose.bones["{name}"]' in curve.data_path for name in BAKED_BONES):
            for point in curve.keyframe_points:
                point.interpolation = "LINEAR"

    # --- in-place fix: subtract straight-line horizontal Hip drift ----------
    drift_removed = [0.0, 0.0, 0.0]
    if clip in LOOP_CLIPS and last > first:
        scene.frame_set(first)
        bpy.context.view_layer.update()
        hip_pb = target.pose.bones["Hip"]
        hip_start = pose_head_world(target, "Hip")
        frame_to_local = (
            (target.matrix_world @ hip_pb.matrix)
            @ hip_pb.matrix_basis.inverted()
        ).to_3x3().inverted()
        scene.frame_set(last)
        bpy.context.view_layer.update()
        hip_end = pose_head_world(target, "Hip")
        drift = hip_end - hip_start
        drift[UP_INDEX] = 0.0
        drift_removed = list(drift)
        if drift.length > 1.0e-6:
            hip_curves = [
                c for c in action.fcurves
                if c.data_path == 'pose.bones["Hip"].location'
            ]
            for curve in hip_curves:
                for point in curve.keyframe_points:
                    t = (point.co[0] - first) / (last - first)
                    local_delta = frame_to_local @ (drift * -t)
                    point.co[1] += local_delta[curve.array_index]
                curve.update()

    # loop-wrap twist check for the continuity-solved handle bones
    for bone_name, first_rot in handle_first_rot.items():
        wrap = math.degrees(
            first_rot.to_quaternion().rotation_difference(
                handle_prev_rot[bone_name].to_quaternion()
            ).angle
        )
        if clip in LOOP_CLIPS and wrap > 25.0:
            print(f"V7_WRAP_WARN {clip} {bone_name} {wrap:.0f}deg")

    # --- per-clip constant ground pin (horse law: never per-frame) ---------
    clearance_min = 1.0e9
    for frame in range(first, last + 1):
        scene.frame_set(frame)
        bpy.context.view_layer.update()
        low = min(pose_head_world(target, n)[UP_INDEX] for n in FOOT_CHAIN)
        clearance_min = min(clearance_min, low - rest_ground)
    ground_shift = 0.0
    if abs(clearance_min) > 1.0e-4:
        ground_shift = -clearance_min
        scene.frame_set(first)
        bpy.context.view_layer.update()
        hip_pb = target.pose.bones["Hip"]
        pin_to_local = (
            (target.matrix_world @ hip_pb.matrix) @ hip_pb.matrix_basis.inverted()
        ).to_3x3().inverted()
        delta_world = Vector((0.0, 0.0, 0.0))
        delta_world[UP_INDEX] = ground_shift
        local_delta = pin_to_local @ delta_world
        for curve in action.fcurves:
            if curve.data_path == 'pose.bones["Hip"].location':
                for point in curve.keyframe_points:
                    point.co[1] += local_delta[curve.array_index]
                curve.update()

    report["clips"].append({
        "name": clip,
        "frames": [first, last],
        "solver": "absolute-anatomical-direction",
        "horizontal_drift_removed_m": [round(v, 4) for v in drift_removed],
        "ground_shift_m": round(ground_shift, 4),
        "action": action.name,
    })
    print("V7_CLIP", clip,
          "drift", [round(v, 3) for v in drift_removed],
          "ground_shift", round(ground_shift, 4))

target.animation_data.action = bpy.data.actions["IRIS_HOUSECAT_RABBIT_V7__walk"]
source.animation_data.action = bpy.data.actions["W3_CAT__walk"]
scene.frame_start = 0
scene.frame_end = 160
scene.frame_set(0)
REPORT.write_text(json.dumps(report, indent=2), encoding="utf-8")
bpy.ops.wm.save_as_mainfile(filepath=str(OUTPUT))
print("HOUSECAT_RETARGET_V7_OK", OUTPUT)
print("HOUSECAT_RETARGET_V7_REPORT", REPORT)
