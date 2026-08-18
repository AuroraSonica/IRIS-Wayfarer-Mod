"""Adversarial numeric gates for the v5 housecat->rabbit retarget.

Measures, per clip and per frame, on IRIS_HOUSECAT_RABBIT_V5__* actions:

1. crossed-leg gate: left/right toe + upper separation projected on the LIVE
   hip lateral axis (turn clips rotate the body, so a world-axis check lies).
2. ground behaviour: lowest foot-chain point vs the rest ground height.
3. rotation spikes: max per-frame quaternion step per baked bone.
4. retarget fidelity: angle between the source cat segment direction and the
   achieved rabbit segment direction, each expressed in its own anatomical
   body frame.  Large error = solver failure, small error = faithful transfer.
5. singularity proximity: angle between each source live segment and its rest
   direction; near-180 values are where rotation_difference has no stable axis.

Run:
  blender --background rs_tools/w3_housecat_rabbit_animation_retarget_v5.blend \
      --python rs_tools/rs_gate_w3_housecat_v5.py
"""

from __future__ import annotations

import json
import math
from pathlib import Path

import bpy
from mathutils import Matrix, Vector

import os

ROOT = Path(r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework")
VER = os.environ.get("HOUSECAT_GATE_VER", "V5").upper()
PREFIX = f"IRIS_HOUSECAT_RABBIT_{VER}__"
REPORT = ROOT / "rs_tools" / f"w3_housecat_{VER.lower()}_gate_report.json"

SOURCE_NAME = "W3_CAT__SOURCE_RIG"
TARGET_NAME = "ch99_200 Armature"

CLIPS = (
    "idle01", "idle02", "idle03", "idle04", "idle05",
    "walk", "walk_left", "walk_right", "run", "run_left", "run_right",
    "eating_start", "eating_loop", "eating_stop", "taunt", "cat_hissing", "death",
)

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

FOOT_CHAIN = (
    "L_FrontLeg_Ankle", "L_FrontLeg_Foot", "L_FrontLeg_Toes",
    "R_FrontLeg_Ankle", "R_FrontLeg_Foot", "R_FrontLeg_Toes",
    "L_RearLeg_Ankle", "L_RearLeg_Foot", "L_RearLeg_Toes",
    "R_RearLeg_Ankle", "R_RearLeg_Foot", "R_RearLeg_Toes",
)

CROSS_PAIRS = (
    ("L_FrontLeg_Upper", "R_FrontLeg_Upper"),
    ("L_FrontLeg_Toes", "R_FrontLeg_Toes"),
    ("L_RearLeg_Upper", "R_RearLeg_Upper"),
    ("L_RearLeg_Toes", "R_RearLeg_Toes"),
)
SRC_CROSS_PAIRS = (
    ("l_bicep", "r_bicep"),
    ("l_frontpaw", "r_frontpaw"),
    ("l_thigh", "r_thigh"),
    ("l_backpaw", "r_backpaw"),
)

SPIKE_BONES = tuple(dict.fromkeys(
    ["Hip"] + [seg[2] for seg in DIRECTION_SEGMENTS]
))

# v8 blend dial (must mirror rs_build_w3_housecat_rabbit_animation_retarget_v8.py)
V8_ALPHA = {
    "Spine_0": 0.85, "Spine_1": 0.85, "Spine_2": 0.85, "Spine_3": 0.85,
    "Neck_0": 0.5,
    "Head_0": 0.0, "Tail": 0.0,
    "L_FrontLeg_Upper": 0.65, "L_FrontLeg_Lower": 0.65, "L_FrontLeg_Ankle": 0.65,
    "R_FrontLeg_Upper": 0.65, "R_FrontLeg_Lower": 0.65, "R_FrontLeg_Ankle": 0.65,
    "L_RearLeg_Upper": 0.5, "L_RearLeg_Lower": 0.5, "L_RearLeg_Ankle": 0.5,
    "R_RearLeg_Upper": 0.5, "R_RearLeg_Lower": 0.5, "R_RearLeg_Ankle": 0.5,
}


def segment_basis(primary: Vector, secondary_hint: Vector) -> Matrix:
    primary = primary.normalized()
    secondary = secondary_hint - primary * primary.dot(secondary_hint)
    secondary.normalize()
    tertiary = primary.cross(secondary).normalized()
    return Matrix((primary, secondary, tertiary)).transposed()


def rest_head_world(obj, name):
    return obj.matrix_world @ obj.data.bones[name].head_local


def pose_head_world(obj, name):
    return obj.matrix_world @ obj.pose.bones[name].matrix.translation


def source_tail_world(obj, name, posed):
    bone = obj.pose.bones[name] if posed else obj.data.bones[name]
    matrix = bone.matrix if posed else bone.matrix_local
    length = bone.bone.length if posed else bone.length
    return obj.matrix_world @ (matrix @ Vector((0.0, length, 0.0)))


def source_dir(source, parent, child, posed):
    if posed:
        head = pose_head_world(source, parent)
        end = pose_head_world(source, child) if child else source_tail_world(source, parent, True)
    else:
        head = rest_head_world(source, parent)
        end = rest_head_world(source, child) if child else source_tail_world(source, parent, False)
    return (end - head).normalized()


def target_dir(target, bone, child, posed):
    if posed:
        head = pose_head_world(target, bone)
        if child:
            end = pose_head_world(target, child)
        else:
            pb = target.pose.bones[bone]
            end = target.matrix_world @ (pb.matrix @ Vector((0.0, pb.bone.length, 0.0)))
    else:
        head = rest_head_world(target, bone)
        if child:
            end = rest_head_world(target, child)
        else:
            db = target.data.bones[bone]
            end = target.matrix_world @ (db.matrix_local @ Vector((0.0, db.length, 0.0)))
    return (end - head).normalized()


def angle_deg(a: Vector, b: Vector) -> float:
    d = max(-1.0, min(1.0, a.dot(b)))
    return math.degrees(math.acos(d))


scene = bpy.context.scene
source = bpy.data.objects[SOURCE_NAME]
target = bpy.data.objects[TARGET_NAME]
source.data.pose_position = "POSE"
target.data.pose_position = "POSE"

# The v5 save purged appended W3 source actions (no fake_user); re-append them.
SOURCE_BENCH = ROOT / "rs_tools" / "w3_catdog_animation_retarget.blend"
wanted = {f"W3_CAT__{clip}" for clip in CLIPS}
missing = sorted(wanted - set(bpy.data.actions.keys()))
if missing:
    with bpy.data.libraries.load(str(SOURCE_BENCH), link=False) as (available, requested):
        requested.actions = [n for n in missing if n in available.actions]

# --- rest reference data -------------------------------------------------
source_body_rest = segment_basis(
    rest_head_world(source, "l_shoulder") - rest_head_world(source, "r_shoulder"),
    rest_head_world(source, "spine3") - rest_head_world(source, "pelvis"),
)
target_body_rest = segment_basis(
    rest_head_world(target, "L_FrontLeg_Upper") - rest_head_world(target, "R_FrontLeg_Upper"),
    rest_head_world(target, "Spine_3") - rest_head_world(target, "Hip"),
)

# up axis: hips sit ABOVE the feet in rest, hip->head does not (quadruped)
hip_r = rest_head_world(target, "Hip")
foot_mean = sum((rest_head_world(target, n) for n in FOOT_CHAIN), Vector()) / len(FOOT_CHAIN)
up_vec = hip_r - foot_mean
up_axis = max(range(3), key=lambda i: abs(up_vec[i]))
up_sign = 1.0 if up_vec[up_axis] >= 0 else -1.0
rest_hip_height = up_sign * hip_r[up_axis]

rest_ground = min(
    up_sign * rest_head_world(target, name)[up_axis] for name in FOOT_CHAIN
)

# hip-local lateral direction (rest): world lateral pulled into hip space
world_lateral_rest = (
    rest_head_world(target, "L_FrontLeg_Upper") - rest_head_world(target, "R_FrontLeg_Upper")
).normalized()
hip_rest_rot = (target.matrix_world.to_3x3().normalized()
                @ target.data.bones["Hip"].matrix_local.to_3x3().normalized())
hip_local_lateral = hip_rest_rot.inverted() @ world_lateral_rest

source_rest_dirs = {}
target_rest_dirs = {}
for sp, sc, tb, tc in DIRECTION_SEGMENTS:
    source_rest_dirs[tb] = (source_body_rest.inverted() @ source_dir(source, sp, sc, False)).normalized()
    target_rest_dirs[tb] = (target_body_rest.inverted() @ target_dir(target, tb, tc, False)).normalized()

report = {"up_axis": "XYZ"[up_axis], "rest_ground": rest_ground, "clips": {}}

for clip in CLIPS:
    s_act = bpy.data.actions.get(f"W3_CAT__{clip}")
    t_act = bpy.data.actions.get(f"{PREFIX}{clip}")
    entry = {"has_source": s_act is not None, "has_target": t_act is not None}
    report["clips"][clip] = entry
    if s_act is None or t_act is None:
        continue
    source.animation_data.action = s_act
    target.animation_data.action = t_act
    first, last = (int(round(v)) for v in s_act.frame_range)
    entry["frames"] = [first, last]

    crossed = {f"{l}|{r}": 0 for l, r in CROSS_PAIRS}
    worst_sep = {f"{l}|{r}": 1e9 for l, r in CROSS_PAIRS}
    src_crossed = {f"{l}|{r}": 0 for l, r in CROSS_PAIRS}
    src_worst_sep = {f"{l}|{r}": 1e9 for l, r in CROSS_PAIRS}
    fidelity_max = {seg[2]: 0.0 for seg in DIRECTION_SEGMENTS}
    fidelity_max_frame = {seg[2]: first for seg in DIRECTION_SEGMENTS}
    excursion_max = {seg[2]: 0.0 for seg in DIRECTION_SEGMENTS}
    ground_min, ground_max = 1e9, -1e9
    prev_quat = {}
    spike_max = {b: 0.0 for b in SPIKE_BONES}
    spike_frame = {b: first for b in SPIKE_BONES}
    hip_h_min, hip_h_max = 1e9, -1e9

    for frame in range(first, last + 1):
        scene.frame_set(frame)
        bpy.context.view_layer.update()

        source_body_live = segment_basis(
            pose_head_world(source, "l_shoulder") - pose_head_world(source, "r_shoulder"),
            pose_head_world(source, "spine3") - pose_head_world(source, "pelvis"),
        )
        target_body_live = segment_basis(
            pose_head_world(target, "L_FrontLeg_Upper") - pose_head_world(target, "R_FrontLeg_Upper"),
            pose_head_world(target, "Spine_3") - pose_head_world(target, "Hip"),
        )

        # 1. crossed-leg gate in live hip frame, with source A/B at same frame
        hip_rot = (target.matrix_world.to_3x3().normalized()
                   @ target.pose.bones["Hip"].matrix.to_3x3().normalized())
        live_lateral = (hip_rot @ hip_local_lateral).normalized()
        src_lateral = source_body_live.col[0].normalized()
        for (l, r), (sl, sr) in zip(CROSS_PAIRS, SRC_CROSS_PAIRS):
            sep = (pose_head_world(target, l) - pose_head_world(target, r)).dot(live_lateral)
            s_sep = (pose_head_world(source, sl) - pose_head_world(source, sr)).dot(src_lateral)
            key = f"{l}|{r}"
            worst_sep[key] = min(worst_sep[key], sep)
            src_worst_sep[key] = min(src_worst_sep[key], s_sep)
            if sep <= 0.0:
                crossed[key] += 1
            if s_sep <= 0.0:
                src_crossed[key] += 1

        # 2. ground
        low = min(up_sign * pose_head_world(target, n)[up_axis] for n in FOOT_CHAIN)
        ground_min = min(ground_min, low - rest_ground)
        ground_max = max(ground_max, low - rest_ground)
        hip_h = up_sign * pose_head_world(target, "Hip")[up_axis] - rest_hip_height
        hip_h_min = min(hip_h_min, hip_h)
        hip_h_max = max(hip_h_max, hip_h)
        hip_w = pose_head_world(target, "Hip")
        if frame == first:
            hip_first = hip_w.copy()
        hip_last = hip_w.copy()

        # 3. spikes
        for b in SPIKE_BONES:
            q = target.pose.bones[b].rotation_quaternion.copy()
            if b in prev_quat:
                step = math.degrees(2.0 * math.acos(min(1.0, abs(q.dot(prev_quat[b])))))
                if step > spike_max[b]:
                    spike_max[b] = step
                    spike_frame[b] = frame
            prev_quat[b] = q

        # 4 + 5. fidelity: achieved WORLD direction vs the direction the
        # builder's own frame math prescribes (kills the frame conflation
        # that inflated rear-up clips) + excursion
        builder_body_live = target_body_rest @ (source_body_rest.inverted() @ source_body_live)
        for sp, sc, tb, tc in DIRECTION_SEGMENTS:
            s_local = (source_body_live.inverted() @ source_dir(source, sp, sc, True)).normalized()
            t_world = target_dir(target, tb, tc, True)
            motion = source_rest_dirs[tb].rotation_difference(s_local)
            v6_local = (motion @ target_rest_dirs[tb]).normalized()
            if VER == "V7":
                expected_local = s_local
            elif VER >= "V8":
                alpha = V8_ALPHA[tb]
                if alpha <= 0.0:
                    expected_local = v6_local
                else:
                    swing = v6_local.rotation_difference(s_local)
                    from mathutils import Quaternion as _Q
                    expected_local = (_Q(swing.axis, swing.angle * alpha) @ v6_local).normalized()
            else:
                expected_local = v6_local
            expected_world = (builder_body_live @ expected_local).normalized()
            err = angle_deg(expected_world, t_world)
            if err > fidelity_max[tb]:
                fidelity_max[tb] = err
                fidelity_max_frame[tb] = frame
            exc = angle_deg(s_local, source_rest_dirs[tb])
            excursion_max[tb] = max(excursion_max[tb], exc)

    entry["crossed_frames"] = {k: v for k, v in crossed.items() if v}
    entry["src_crossed_frames"] = {k: v for k, v in src_crossed.items() if v}
    entry["worst_lateral_sep_m"] = {k: round(v, 4) for k, v in worst_sep.items()}
    entry["src_worst_lateral_sep_m"] = {k: round(v, 4) for k, v in src_worst_sep.items()}
    entry["ground_clearance_m"] = [round(ground_min, 4), round(ground_max, 4)]
    entry["hip_height_rel_rest_m"] = [round(hip_h_min, 4), round(hip_h_max, 4)]
    entry["hip_net_travel_m"] = [round(v, 4) for v in (hip_last - hip_first)]
    entry["worst_spikes_deg"] = {
        b: [round(spike_max[b], 1), spike_frame[b]]
        for b in sorted(SPIKE_BONES, key=lambda x: -spike_max[x])[:5]
    }
    entry["fidelity_worst_deg"] = {
        b: [round(fidelity_max[b], 1), fidelity_max_frame[b]]
        for b in sorted(fidelity_max, key=lambda x: -fidelity_max[x])[:8]
    }
    entry["source_excursion_max_deg"] = {
        b: round(v, 1)
        for b, v in sorted(excursion_max.items(), key=lambda kv: -kv[1])[:8]
    }
    print(f"GATE {clip}: crossed={sum(crossed.values())}(src={sum(src_crossed.values())}) "
          f"ground=[{ground_min:.3f},{ground_max:.3f}] "
          f"worst_fid={max(fidelity_max.values()):.1f} "
          f"worst_exc={max(excursion_max.values()):.1f}")

REPORT.write_text(json.dumps(report, indent=2), encoding="utf-8")
print("GATE_REPORT", REPORT)
