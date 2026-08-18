"""Retarget the Witcher cat animation set onto the working DD2 rabbit host.

This produces an authoring/QA Blender file. It deliberately suppresses root
travel so IRIS Taming can remain the movement owner. DD2 MOT export is a later
step after deformation review.
"""

from __future__ import annotations

from pathlib import Path
import json
import math

import bpy
from mathutils import Matrix, Vector


ROOT = Path(r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework")
RS = ROOT / "rs_tools"
W3 = RS / "witcher 3 files"
INPUT_BLEND = RS / "w3_housecat_dd2_rabbit_host_v08.blend"
SOURCE_BENCH = RS / "w3_catdog_animation_retarget.blend"
OUTPUT_BLEND = RS / "w3_housecat_rabbit_animation_retarget_v2.blend"
OUTPUT_REPORT = RS / "w3_housecat_rabbit_animation_retarget_v2_report.json"
RIG = W3 / "Direct Extract" / "characters" / "base_entities" / "cat_base" / "cat_base.w2rig"
ANIMSET = W3 / "Animations" / "full animation files" / "Animals" / "cat" / "cat_animation.w2anims"
TARGET = "ch99_200 Armature"
FIT_SCALE = 0.7160095412678015

BONE_ORDER = """Root Trajectory pelvis spine1 spine2 spine3 neck neck1 head
    l_ear r_ear jaw l_shoulder l_bicep l_forearm l_hand l_frontpaw
    r_shoulder r_bicep r_forearm r_hand r_frontpaw l_thigh l_shin
    l_foot l_backpaw r_thigh r_shin r_foot r_backpaw tail1 tail2
    tail3 tail4 tail5""".split()

# One source driver per rabbit joint. Cat-only ear/tail-chain detail cannot be
# represented by the stock rabbit skeleton, but every body and limb joint can.
MAP = {
    "pelvis": "Hip",
    "spine1": "Spine_0",
    "spine2": "Spine_2",
    "spine3": "Spine_3",
    "neck": "Neck_0",
    "head": "Head_0",
    "tail1": "Tail",
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

# Anatomical source segment -> target bone and its target child joint.  The
# target child is used only to establish the DD2 rest direction.  This avoids
# copying Witcher rotations between incompatible bind rolls.
SEGMENTS = (
    ("pelvis", "spine1", "Hip", "Spine_0"),
    ("spine1", "spine2", "Spine_0", "Spine_2"),
    ("spine2", "spine3", "Spine_2", "Spine_3"),
    ("spine3", "neck", "Spine_3", "Neck_0"),
    ("neck", "head", "Neck_0", "Head_0"),
    ("l_shoulder", "l_bicep", "L_Shoulder_Clavicle", "L_FrontLeg_Upper"),
    ("l_bicep", "l_forearm", "L_FrontLeg_Upper", "L_FrontLeg_Lower"),
    ("l_forearm", "l_hand", "L_FrontLeg_Lower", "L_FrontLeg_Ankle"),
    ("l_hand", "l_frontpaw", "L_FrontLeg_Ankle", "L_FrontLeg_Toes"),
    ("r_shoulder", "r_bicep", "R_Shoulder_Clavicle", "R_FrontLeg_Upper"),
    ("r_bicep", "r_forearm", "R_FrontLeg_Upper", "R_FrontLeg_Lower"),
    ("r_forearm", "r_hand", "R_FrontLeg_Lower", "R_FrontLeg_Ankle"),
    ("r_hand", "r_frontpaw", "R_FrontLeg_Ankle", "R_FrontLeg_Toes"),
    ("l_thigh", "l_shin", "L_RearLeg_Upper", "L_RearLeg_Lower"),
    ("l_shin", "l_foot", "L_RearLeg_Lower", "L_RearLeg_Ankle"),
    ("l_foot", "l_backpaw", "L_RearLeg_Ankle", "L_RearLeg_Toes"),
    ("r_thigh", "r_shin", "R_RearLeg_Upper", "R_RearLeg_Lower"),
    ("r_shin", "r_foot", "R_RearLeg_Lower", "R_RearLeg_Ankle"),
    ("r_foot", "r_backpaw", "R_RearLeg_Ankle", "R_RearLeg_Toes"),
)

CLIPS = [
    "idle01", "idle02", "idle03", "idle04", "idle05",
    "walk", "walk_left", "walk_right",
    "run", "run_left", "run_right", "eating_start", "eating_loop", "eating_stop",
    "taunt", "cat_hissing", "death",
]


def enable_tools():
    try:
        result = bpy.ops.preferences.addon_enable(module="bl_ext.user_default.witcher3_tools")
        if "FINISHED" not in result:
            raise RuntimeError(result)
        from bl_ext.user_default.witcher3_tools.CR2W.dc_anims import load_bin_anims_single
        from bl_ext.user_default.witcher3_tools.CR2W.dc_skeleton import load_bin_skeleton
        from bl_ext.user_default.witcher3_tools.importers.import_anims import import_anim
        from bl_ext.user_default.witcher3_tools.importers.import_rig import create_armature
    except (ImportError, RuntimeError):
        result = bpy.ops.preferences.addon_enable(module="witcher3_tools")
        if "FINISHED" not in result:
            raise RuntimeError(f"Could not enable Witcher 3 Tools: {result}")
        from witcher3_tools.CR2W.dc_anims import load_bin_anims_single
        from witcher3_tools.CR2W.dc_skeleton import load_bin_skeleton
        from witcher3_tools.importers.import_anims import import_anim
        from witcher3_tools.importers.import_rig import create_armature
    return load_bin_anims_single, load_bin_skeleton, import_anim, create_armature


def patch_buffer_names(buffer):
    parts = getattr(buffer, "parts", None)
    if parts:
        for part in parts:
            patch_buffer_names(part)
        return
    bones = list(getattr(buffer, "bones", []) or [])
    if len(bones) != len(BONE_ORDER):
        raise RuntimeError(f"animation has {len(bones)} tracks; rig has {len(BONE_ORDER)}")
    for bone, name in zip(bones, BONE_ORDER):
        bone.BoneName = name


def make_source_rig(load_skeleton, create_armature):
    skeleton = load_skeleton(str(RIG))
    if len(skeleton.bones) != len(BONE_ORDER):
        raise RuntimeError("decoded cat rig has the wrong bone count")
    for bone, name in zip(skeleton.bones, BONE_ORDER):
        bone.name = name
    source = create_armature(
        skeleton, "W3_CAT_RABBIT_RETARGET_SOURCE", 1.0, False,
        bpy.context, fileName=str(RIG),
    )
    source.name = "W3_CAT__SOURCE_RIG"
    source.rotation_euler.z = math.pi
    source.show_in_front = True
    source.hide_render = True
    settings = source.data.witcherui_RigSettings
    settings.main_entity_skeleton = str(RIG)
    settings.bone_order_list.clear()
    for name in BONE_ORDER:
        item = settings.bone_order_list.add()
        item.name = name
    return source


def decode_action(load_anim, import_anim, source, clip):
    result = load_anim(str(ANIMSET), clip, rigPath=str(RIG))
    if not result or not result.animations:
        raise RuntimeError(f"missing Witcher cat clip: {clip}")
    entry = result.animations[0]
    buffer = entry.animation.animBuffer
    patch_buffer_names(buffer)
    import_anim(
        bpy.context, str(ANIMSET), entry, use_NLA=False,
        override_select=source, update_scene_settings=False,
    )
    action = source.animation_data.action
    if not action:
        raise RuntimeError(f"importer created no action for {clip}")
    action.name = f"W3_CAT__{clip}"
    action.use_fake_user = True
    frames = int(getattr(buffer, "numFrames", 0) or 0)
    if frames <= 0 and getattr(buffer, "parts", None):
        frames = max(
            int(first) + int(getattr(part, "numFrames", 0) or 0)
            for first, part in zip(buffer.firstFrames, buffer.parts)
        )
    return action, frames


def clear_pose(armature):
    for bone in armature.pose.bones:
        bone.location = (0.0, 0.0, 0.0)
        bone.rotation_mode = "QUATERNION"
        bone.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
        bone.scale = (1.0, 1.0, 1.0)


def segment_basis(primary, secondary_hint):
    """Return an orthonormal matrix whose columns are anatomical axes."""
    primary = primary.normalized()
    secondary = secondary_hint - primary * primary.dot(secondary_hint)
    if secondary.length < 1.0e-8:
        raise RuntimeError("Degenerate quadruped body basis")
    secondary.normalize()
    tertiary = primary.cross(secondary).normalized()
    return Matrix((primary, secondary, tertiary)).transposed()


def bone_head_world(armature, bone, posed):
    matrix = bone.matrix if posed else bone.matrix_local
    return armature.matrix_world @ matrix.translation


def bone_tail_world(armature, bone, posed):
    matrix = bone.matrix if posed else bone.matrix_local
    return armature.matrix_world @ (matrix @ Vector((0.0, bone.length, 0.0)))


def load_predecoded_cat_source():
    """Append the already-decoded W3 cat rig/actions from the earlier bench.

    The Witcher extension is not currently registered in Aurora's Blender
    profiles, but this blend contains the extension's lossless decoded result.
    Reusing it avoids treating an environment/profile problem as asset loss.
    """
    wanted_actions = {f"W3_CAT__{clip}" for clip in CLIPS}
    with bpy.data.libraries.load(str(SOURCE_BENCH), link=False) as (available, requested):
        if "W3_CAT__SOURCE_RIG" not in available.objects:
            raise RuntimeError("source bench has no decoded W3 cat rig")
        missing = sorted(wanted_actions - set(available.actions))
        if missing:
            raise RuntimeError(f"source bench is missing decoded actions: {missing}")
        requested.objects = ["W3_CAT__SOURCE_RIG"]
        requested.actions = sorted(wanted_actions)
    source = bpy.data.objects.get("W3_CAT__SOURCE_RIG")
    if not source:
        raise RuntimeError("decoded W3 cat rig did not append")
    if not source.users_collection:
        bpy.context.scene.collection.objects.link(source)
    source.location = (0.0, 0.0, 0.0)
    source.rotation_euler.z = math.pi
    source.hide_render = True
    return source


def retarget(source, target, source_action, clip, frame_count):
    source.animation_data.action = source_action
    clear_pose(target)
    target.animation_data_create()
    action = bpy.data.actions.new(f"IRIS_HOUSECAT_RABBIT__{clip}")
    action.use_fake_user = True
    action["iris_source_clip"] = clip
    action["iris_in_place"] = True
    action["iris_target_host"] = "ch99_200 rabbit"
    target.animation_data.action = action

    source_rest = {
        name: bone_head_world(source, source.data.bones[name], False)
        for name in BONE_ORDER
    }
    target_rest = {
        name: bone_head_world(target, target.data.bones[name], False)
        for name in target.data.bones.keys()
    }
    source_body_rest = segment_basis(
        source_rest["l_shoulder"] - source_rest["r_shoulder"],
        source_rest["spine3"] - source_rest["pelvis"],
    )
    target_body_rest = segment_basis(
        target_rest["L_Shoulder_Clavicle"] - target_rest["R_Shoulder_Clavicle"],
        target_rest["Spine_3"] - target_rest["Hip"],
    )
    target_world_rotation = target.matrix_world.to_3x3().normalized()
    target_world_rotation_inverse = target_world_rotation.inverted()
    target_rest_rotation_world = {
        name: target_world_rotation @ bone.matrix_local.to_3x3().normalized()
        for name, bone in target.data.bones.items()
    }
    hierarchy = sorted(target.data.bones, key=lambda bone: len(bone.parent_recursive))
    keyed = {target_name for _, _, target_name, _ in SEGMENTS} | {"Head_0", "Tail"}

    for frame in range(frame_count):
        bpy.context.scene.frame_set(frame)
        bpy.context.view_layer.update()
        source_live = {
            name: bone_head_world(source, source.pose.bones[name], True)
            for name in BONE_ORDER
        }
        source_body_live = segment_basis(
            source_live["l_shoulder"] - source_live["r_shoulder"],
            source_live["spine3"] - source_live["pelvis"],
        )
        body_relative = source_body_rest.inverted() @ source_body_live
        target_body_live = target_body_rest @ body_relative

        desired_rotations = {}
        for source_parent, source_child, target_name, target_child in SEGMENTS:
            source_rest_direction = (
                source_rest[source_child] - source_rest[source_parent]
            ).normalized()
            source_live_direction = (
                source_live[source_child] - source_live[source_parent]
            ).normalized()
            source_rest_anatomical = source_body_rest.inverted() @ source_rest_direction
            source_live_anatomical = source_body_live.inverted() @ source_live_direction
            segment_delta = source_rest_anatomical.rotation_difference(source_live_anatomical)
            target_rest_direction = (target_rest[target_child] - target_rest[target_name]).normalized()
            target_rest_anatomical = target_body_rest.inverted() @ target_rest_direction
            desired_anatomical = segment_delta @ target_rest_anatomical
            desired_direction = (target_body_live @ desired_anatomical).normalized()
            direction_delta = target_rest_direction.rotation_difference(desired_direction)
            desired_rotations[target_name] = (
                direction_delta.to_matrix() @ target_rest_rotation_world[target_name]
            )

        # Terminal head and the rabbit's one-bone tail use their authored bone
        # endpoints because there is no mapped target child joint.
        for source_name, target_name in (("head", "Head_0"), ("tail1", "Tail")):
            source_bone = source.pose.bones[source_name]
            source_rest_bone = source.data.bones[source_name]
            source_rest_direction = (
                bone_tail_world(source, source_rest_bone, False)
                - bone_head_world(source, source_rest_bone, False)
            ).normalized()
            source_live_direction = (
                bone_tail_world(source, source_bone, True)
                - bone_head_world(source, source_bone, True)
            ).normalized()
            source_rest_anatomical = source_body_rest.inverted() @ source_rest_direction
            source_live_anatomical = source_body_live.inverted() @ source_live_direction
            segment_delta = source_rest_anatomical.rotation_difference(source_live_anatomical)
            target_bone = target.data.bones[target_name]
            target_rest_direction = (
                bone_tail_world(target, target_bone, False)
                - bone_head_world(target, target_bone, False)
            ).normalized()
            target_rest_anatomical = target_body_rest.inverted() @ target_rest_direction
            desired_anatomical = segment_delta @ target_rest_anatomical
            desired_direction = (target_body_live @ desired_anatomical).normalized()
            direction_delta = target_rest_direction.rotation_difference(desired_direction)
            desired_rotations[target_name] = (
                direction_delta.to_matrix() @ target_rest_rotation_world[target_name]
            )

        desired_armature_rotations = {
            name: target_world_rotation_inverse @ rotation
            for name, rotation in desired_rotations.items()
        }
        source_move = source_live["pelvis"] - source_rest["pelvis"]
        anatomical_move = source_body_rest.inverted() @ source_move
        target_move_world = target_body_rest @ anatomical_move * FIT_SCALE
        target_move = target_world_rotation_inverse @ target_move_world

        desired_matrices = {}
        for bone in hierarchy:
            if bone.parent:
                rest_relative = bone.parent.matrix_local.inverted() @ bone.matrix_local
                base = desired_matrices[bone.parent.name] @ rest_relative
            else:
                base = bone.matrix_local.copy()
            location = base.translation.copy()
            if bone.name == "Hip":
                location += target_move
            rotation = desired_armature_rotations.get(bone.name, base.to_3x3().normalized())
            desired_matrices[bone.name] = Matrix.LocRotScale(
                location, rotation.to_quaternion(), Vector((1.0, 1.0, 1.0))
            )

        for bone in hierarchy:
            if bone.name not in keyed:
                continue
            pose_bone = target.pose.bones[bone.name]
            pose_bone.matrix = desired_matrices[bone.name]
            pose_bone.keyframe_insert(
                data_path="rotation_quaternion", frame=frame, group=bone.name,
            )
            if bone.name == "Hip":
                pose_bone.keyframe_insert(data_path="location", frame=frame, group=bone.name)

    action["iris_mapped_bones"] = len(keyed)
    action["iris_retarget_method"] = "anatomical segment directions; target rest roll preserved"
    return action


bpy.ops.wm.open_mainfile(filepath=str(INPUT_BLEND), load_ui=False)
target = bpy.data.objects.get(TARGET)
if not target or target.type != "ARMATURE":
    raise RuntimeError(f"missing rabbit target armature: {TARGET}")
target.data.pose_position = "POSE"
source = load_predecoded_cat_source()

report = {
    "format": "iris-w3-housecat-rabbit-retarget-v2-anatomical",
    "source_animset": str(ANIMSET),
    "target": TARGET,
    "mapped_bones": len({target_name for _, _, target_name, _ in SEGMENTS} | {"Head_0", "Tail"}),
    "fit_scale": FIT_SCALE,
    "root_motion": "source trajectory suppressed; anatomical pelvis pose offset retained",
    "method": "live Witcher segment directions reconstructed in DD2 body frame; DD2 rest roll preserved",
    "clips": [],
}
actions = {}
for clip in CLIPS:
    source_action = bpy.data.actions.get(f"W3_CAT__{clip}")
    if not source_action:
        raise RuntimeError(f"decoded source action missing after append: {clip}")
    frames = int(source_action.get("iris_frame_count", 0) or 0)
    if frames <= 0:
        frames = int(source_action.frame_range[1] - source_action.frame_range[0] + 1)
    target_action = retarget(source, target, source_action, clip, frames)
    actions[clip] = target_action
    report["clips"].append(
        {"name": clip, "frames": frames, "action": target_action.name}
    )

target.animation_data.action = actions["idle01"]
bpy.context.scene.frame_start = 0
bpy.context.scene.frame_end = 160
bpy.context.scene.frame_set(80)
bpy.context.view_layer.update()
OUTPUT_REPORT.write_text(json.dumps(report, indent=2), encoding="utf-8")
bpy.ops.wm.save_as_mainfile(filepath=str(OUTPUT_BLEND), check_existing=False)
print("W3_HOUSECAT_RABBIT_RETARGET_OK", OUTPUT_BLEND)
