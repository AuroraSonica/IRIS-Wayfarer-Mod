"""V11 house-cat mesh bench: v10 minus the SEAM TEARS, minus the tail spears.

Aurora's v10 field notes (08-19): head marginally better, but "a ton of random
gaps/holes", "feet and chest mishappen and holey", rear spikes.  All three are
v10 regressions with one shared root: game meshes carry DUPLICATE vertices
along UV/normal seams, and v10 introduced ops that move each duplicate
independently:

1. CREASE RELAX (bmesh.ops.smooth_vert) smooths by CONNECTIVITY -- seam
   duplicates have different neighbour sets, so the copies drift apart and
   the seam tears open (the chest/leg holes).  V11 keeps the relax but
   SEAM-WELDS afterwards: verts that shared a position before the op are
   snapped back to their common average after it.
2. SUBDIV smooth=0.8 pulls the two copies of every seam edge to different
   smoothed midpoints -> more tears.  V11 reverts to smooth=0.0 (v09
   behaviour: midpoints stay ON the shared edge, no tear).
3. TAIL CURL had a hard cliff at weight 0.25 -- a face spanning a 0.26 vert
   (rotated) and a 0.24 vert (untouched) stretches into a spear (the rump
   spikes).  V11 ramps the curl in with a smoothstep over weight 0.2..0.7,
   applied to EVERY tail-weighted vert, so the bake is continuous.

Everything else (shoulder fix, paw softening 0.78/1.06, weight radius 0.014,
warp, transfers) is v10-verbatim.  The paw/weight ops are deterministic in
(position, weights) which seam duplicates share, so they never tear.
"""

from __future__ import annotations

import json
import math
import traceback
from collections import defaultdict
from pathlib import Path

import bpy
import bmesh
import numpy as np
from mathutils import Matrix, Vector


ROOT = Path(r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework")
RS = ROOT / "rs_tools"
RABBIT_BLEND = RS / "dd2_rabbit_ch99_200_source.blend"
ENTITY = (
    RS / "witcher 3 files" / "Animations" / "full animation files" / "Animals"
    / "00. models for animations" / "cat" / "t_01__cat.w2ent"
)
OUTPUT_BLEND = RS / "w3_housecat_dd2_rabbit_host_v11.blend"
OUTPUT_REPORT = RS / "w3_housecat_rabbit_host_v11_report.json"

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
    "l_ear": "Head_0",
    "r_ear": "Head_0",
    "tail1": "Tail",
    "tail2": "Tail",
    "tail3": "Tail",
    "tail4": "Tail",
    "tail5": "Tail",
    "l_shoulder": "L_FrontLeg_Upper",
    "l_bicep": "L_FrontLeg_Upper",
    "l_forearm": "L_FrontLeg_Lower",
    "l_hand": "L_FrontLeg_Ankle",
    "l_frontpaw": "L_FrontLeg_Toes",
    "r_shoulder": "R_FrontLeg_Upper",
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

WARP_DRIVER = {
    "neck1": "neck",
    "jaw": "head",
    "l_ear": "head",
    "r_ear": "head",
    "tail2": "tail1",
    "tail3": "tail1",
    "tail4": "tail1",
    "tail5": "tail1",
    "l_shoulder": "l_bicep",
    "r_shoulder": "r_bicep",
}

TRANSFERS = (
    ("L_FrontLeg_Toes", "L_FrontLeg_Ankle", 0.68),
    ("R_FrontLeg_Toes", "R_FrontLeg_Ankle", 0.68),
    ("L_FrontLeg_Ankle", "L_FrontLeg_Lower", 0.28),
    ("R_FrontLeg_Ankle", "R_FrontLeg_Lower", 0.28),
    ("L_RearLeg_Toes", "L_RearLeg_Ankle", 0.34),
    ("R_RearLeg_Toes", "R_RearLeg_Ankle", 0.34),
    ("L_RearLeg_Ankle", "L_RearLeg_Lower", 0.12),
    ("R_RearLeg_Ankle", "R_RearLeg_Lower", 0.12),
)
FRONT_TOES = ("L_FrontLeg_Toes", "R_FrontLeg_Toes")
PAW_HEIGHT_SCALE = 0.78          # v10 softened values kept
PAW_LENGTH_SCALE = 1.06
MIN_WEIGHT = 1.0e-5
MAX_INFLUENCES = 4

SMOOTH_RADIUS = 0.014
SMOOTH_FACTOR = 0.5
SMOOTH_PASSES = 2
SIDE_MARGIN = 0.004
SIDE_GROUP_PREFIXES = ("L_FrontLeg", "R_FrontLeg", "L_RearLeg", "R_RearLeg")

CREASE_SPREAD = 0.006
CREASE_SMOOTH_FACTOR = 0.5
CREASE_SMOOTH_PASSES = 2
SUBDIV_SMOOTH = 0.0              # v11: BACK to linear -- 0.8 tore every seam
SEAM_WELD_DECIMALS = 5           # v11: coincidence key for the seam weld
TAIL_CURL = math.radians(42.0)
TAIL_RAMP_LO = 0.2               # v11: smoothstep ramp replaces the 0.25 cliff
TAIL_RAMP_HI = 0.7


def enable_entity_importer():
    result = bpy.ops.preferences.addon_enable(module="bl_ext.user_default.witcher3_tools")
    if "FINISHED" not in result:
        raise RuntimeError(f"Could not enable Witcher 3 Tools: {result}")
    from bl_ext.user_default.witcher3_tools.importers.import_entity import import_direct_entity_file
    return import_direct_entity_file


def rounded(values):
    if isinstance(values, (int, float)):
        return round(float(values), 6)
    return [round(float(value), 6) for value in values]


def move_exclusively(obj, collection):
    for current in list(obj.users_collection):
        current.objects.unlink(obj)
    collection.objects.link(obj)


def read_weights(mesh):
    names = {group.index: group.name for group in mesh.vertex_groups}
    return [
        {
            names[item.group]: float(item.weight)
            for item in vertex.groups
            if item.weight > MIN_WEIGHT
        }
        for vertex in mesh.data.vertices
    ]


def write_weights(mesh, weights, group_names):
    for group in list(mesh.vertex_groups):
        mesh.vertex_groups.remove(group)
    groups = {name: mesh.vertex_groups.new(name=name) for name in group_names}
    for vertex, vertex_weights in zip(mesh.data.vertices, weights):
        for name, weight in vertex_weights.items():
            if weight > MIN_WEIGHT:
                groups[name].add([vertex.index], weight, "REPLACE")


def seam_groups(mesh):
    """Groups of vertex indices that share a (rounded) position -- the UV/normal
    seam duplicates that must move as one or the surface tears."""
    groups = defaultdict(list)
    for vertex in mesh.data.vertices:
        key = (
            round(vertex.co.x, SEAM_WELD_DECIMALS),
            round(vertex.co.y, SEAM_WELD_DECIMALS),
            round(vertex.co.z, SEAM_WELD_DECIMALS),
        )
        groups[key].append(vertex.index)
    return [idxs for idxs in groups.values() if len(idxs) > 1]


def weld_groups(mesh, groups):
    """Snap every coincidence group back to its members' average position."""
    welded = 0
    for idxs in groups:
        mean = Vector((0.0, 0.0, 0.0))
        for i in idxs:
            mean += mesh.data.vertices[i].co
        mean /= len(idxs)
        moved = any((mesh.data.vertices[i].co - mean).length > 1e-9 for i in idxs)
        for i in idxs:
            mesh.data.vertices[i].co = mean
        if moved:
            welded += 1
    mesh.data.update()
    return welded


report = {"format": "iris-w3-housecat-rabbit-host-v11", "error": None}
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

    orientation = Matrix.Rotation(math.pi, 4, "Z")
    source_rig_world = source_armature.matrix_world
    target_rig_world = target_armature.matrix_world
    source_hip = orientation @ (source_rig_world @ source_armature.data.bones["pelvis"].matrix_local).translation
    source_head = orientation @ (source_rig_world @ source_armature.data.bones["head"].matrix_local).translation
    target_hip = (target_rig_world @ target_armature.data.bones["Hip"].matrix_local).translation
    target_head = (target_rig_world @ target_armature.data.bones["Head_0"].matrix_local).translation
    scale = (target_head - target_hip).length / (source_head - source_hip).length
    translation = target_hip - source_hip * scale
    align = Matrix.Translation(translation) @ Matrix.Diagonal((scale, scale, scale, 1.0)) @ orientation

    source_bone_world = {}
    target_bone_world = {}
    for name in set(MAP) | set(WARP_DRIVER.values()):
        source_bone_world[name] = align @ source_rig_world @ source_armature.data.bones[name].matrix_local
        target_bone_world[name] = target_rig_world @ target_armature.data.bones[MAP[name]].matrix_local
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
    crease_flags = []
    for source_vertex, fit_vertex in zip(source.data.vertices, fit.data.vertices):
        aligned = align @ source.matrix_world @ source_vertex.co
        position = Vector((0.0, 0.0, 0.0))
        total = 0.0
        deltas = []
        for assignment in source_vertex.groups:
            source_name = source_group_names.get(assignment.group)
            if source_name in MAP and assignment.weight > 0.0:
                position += (aligned + joint_delta[source_name]) * assignment.weight
                total += assignment.weight
                if assignment.weight > 0.05:
                    deltas.append(joint_delta[source_name])
        fit_vertex.co = target_inverse @ (position / total if total > 1e-8 else aligned)
        spread = 0.0
        for a in range(len(deltas)):
            for b in range(a + 1, len(deltas)):
                spread = max(spread, (deltas[a] - deltas[b]).length)
        crease_flags.append(spread > CREASE_SPREAD)
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
    for obj in imported:
        if obj not in (source, source_armature):
            bpy.data.objects.remove(obj, do_unlink=True)
    bpy.data.objects.remove(source, do_unlink=True)
    bpy.data.objects.remove(source_armature, do_unlink=True)

    # ---- v11: capture seam-duplicate groups BEFORE any smoothing op --------
    seams = seam_groups(fit)

    # ---- warp-crease relax + SEAM WELD ------------------------------------
    bm = bmesh.new()
    bm.from_mesh(fit.data)
    bm.verts.ensure_lookup_table()
    crease_verts = [bm.verts[i] for i, flagged in enumerate(crease_flags) if flagged]
    for _ in range(CREASE_SMOOTH_PASSES):
        bmesh.ops.smooth_vert(
            bm, verts=crease_verts, factor=CREASE_SMOOTH_FACTOR,
            use_axis_x=True, use_axis_y=True, use_axis_z=True,
        )
    bm.to_mesh(fit.data)
    bm.free()
    fit.data.update()
    creased = sum(1 for f in crease_flags if f)
    welded = weld_groups(fit, seams)   # v11: close the tears the relax opened

    # ---- tail curl bake (v11: smoothstep ramp, no cliff) ------------------
    original = read_weights(fit)
    tail_head = (target_armature.matrix_world
                 @ target_armature.data.bones["Tail"].matrix_local).translation
    tail_local_head = fit.matrix_world.inverted() @ tail_head
    tail_pts = [
        (vertex, original[vertex.index].get("Tail", 0.0))
        for vertex in fit.data.vertices
        if original[vertex.index].get("Tail", 0.0) > 1.0e-4
    ]
    if not tail_pts:
        raise RuntimeError("No tail vertices found for the curl bake")
    offsets = [vertex.co - tail_local_head for vertex, _ in tail_pts]
    ref = [o for (v, w), o in zip(tail_pts, offsets) if w > 0.5] or offsets
    mean_y = sum(o.y for o in ref) / len(ref)
    tail_sign = -1.0 if mean_y < 0.0 else 1.0
    tail_reach = max(o.length for o in ref)
    for vertex, weight in tail_pts:
        off = vertex.co - tail_local_head
        t = min(1.0, off.length / max(tail_reach, 1e-6))
        s = max(0.0, min(1.0, (weight - TAIL_RAMP_LO) / (TAIL_RAMP_HI - TAIL_RAMP_LO)))
        blend = s * s * (3.0 - 2.0 * s)   # smoothstep: continuous across faces
        if blend <= 0.0:
            continue
        angle = tail_sign * TAIL_CURL * t * blend
        rot = Matrix.Rotation(angle, 4, "X")
        vertex.co = tail_local_head + (rot @ off)
    fit.data.update()

    # ---- paw pass (v10-softened scales, deterministic => seam-safe) -------
    modified = [dict(w) for w in original]
    paw_shape = {}
    for group_name in FRONT_TOES:
        weighted = [
            (vertex, original[vertex.index].get(group_name, 0.0))
            for vertex in fit.data.vertices
            if original[vertex.index].get(group_name, 0.0) > MIN_WEIGHT
        ]
        if not weighted:
            raise RuntimeError(f"No vertices found for {group_name}")
        weight_sum = sum(weight for _, weight in weighted)
        centre = sum((vertex.co * weight for vertex, weight in weighted), Vector()) / weight_sum
        floor_z = min(vertex.co.z for vertex, _ in weighted)
        for vertex, weight in weighted:
            strength = 0.5 + 0.5 * min(1.0, weight * 1.35)
            length_scale = 1.0 + (PAW_LENGTH_SCALE - 1.0) * strength
            height_scale = 1.0 + (PAW_HEIGHT_SCALE - 1.0) * strength
            vertex.co.y = centre.y + (vertex.co.y - centre.y) * length_scale
            vertex.co.z = floor_z + (vertex.co.z - floor_z) * height_scale
        paw_shape[group_name] = {"vertices": len(weighted), "sole_z": rounded(floor_z)}
    fit.data.update()

    for vertex_weights in modified:
        for src, dst, fraction in TRANSFERS:
            amount = vertex_weights.get(src, 0.0) * fraction
            if amount > 0.0:
                vertex_weights[src] -= amount
                vertex_weights[dst] = vertex_weights.get(dst, 0.0) + amount
    group_names = sorted({n for w in modified for n in w})
    write_weights(fit, modified, group_names)

    # ---- subdivision (v11: LINEAR again -- smoothing here tears seams) ----
    bm = bmesh.new()
    bm.from_mesh(fit.data)
    bmesh.ops.subdivide_edges(
        bm, edges=bm.edges[:], cuts=1, use_grid_fill=True, smooth=SUBDIV_SMOOTH
    )
    bm.to_mesh(fit.data)
    bm.free()
    fit.data.update()
    if fit.data.has_custom_normals:
        with bpy.context.temp_override(
            object=fit, active_object=fit, selected_objects=[fit]
        ):
            bpy.ops.mesh.customdata_custom_splitnormals_clear()
    for poly in fit.data.polygons:
        poly.use_smooth = True

    # ---- numpy spatial weight smoothing (position-keyed => seam-safe) -----
    count = len(fit.data.vertices)
    coords = np.empty(count * 3)
    fit.data.vertices.foreach_get("co", coords)
    coords = coords.reshape((count, 3))
    group_index = {g.name: i for i, g in enumerate(fit.vertex_groups)}
    names_by_index = {i: n for n, i in group_index.items()}
    weight_matrix = np.zeros((count, len(group_index)))
    for vertex in fit.data.vertices:
        for item in vertex.groups:
            weight_matrix[vertex.index, item.group] = item.weight

    cell = SMOOTH_RADIUS
    grid = defaultdict(list)
    for i, p in enumerate(coords):
        grid[tuple((p // cell).astype(int))].append(i)
    neighbours = []
    for i, p in enumerate(coords):
        key = tuple((p // cell).astype(int))
        candidates = []
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for dz in (-1, 0, 1):
                    candidates.extend(grid.get((key[0] + dx, key[1] + dy, key[2] + dz), ()))
        candidates = np.array(candidates)
        dists = np.linalg.norm(coords[candidates] - p, axis=1)
        keep = candidates[dists < SMOOTH_RADIUS]
        neighbours.append(keep)
    for _ in range(SMOOTH_PASSES):
        smoothed = weight_matrix.copy()
        for i in range(count):
            nb = neighbours[i]
            if len(nb) > 1:
                smoothed[i] = (
                    (1.0 - SMOOTH_FACTOR) * weight_matrix[i]
                    + SMOOTH_FACTOR * weight_matrix[nb].mean(axis=0)
                )
        weight_matrix = smoothed

    # ---- cross-side strip + renormalise + cap ----------------------------
    xs = coords[:, 0]
    stripped = 0
    for name, gi in group_index.items():
        if not name.startswith(SIDE_GROUP_PREFIXES):
            continue
        if name.startswith("L_"):
            bad = xs < -SIDE_MARGIN
        else:
            bad = xs > SIDE_MARGIN
        stripped += int(np.count_nonzero(weight_matrix[bad, gi] > 0.0))
        weight_matrix[bad, gi] = 0.0

    for i in range(count):
        row = weight_matrix[i]
        order = np.argsort(row)[::-1]
        row[order[MAX_INFLUENCES:]] = 0.0
        total = row.sum()
        if total <= 1e-8:
            nb = neighbours[i]
            donor_rows = weight_matrix[nb]
            sums = donor_rows.sum(axis=1)
            good = nb[sums > 1e-8]
            if len(good):
                weight_matrix[i] = weight_matrix[good[0]]
            else:
                weight_matrix[i, group_index.get("Hip", 0)] = 1.0
        else:
            weight_matrix[i] = row / total

    final_weights = []
    for i in range(count):
        row = weight_matrix[i]
        final_weights.append({
            names_by_index[j]: float(row[j])
            for j in np.nonzero(row > MIN_WEIGHT)[0]
        })
    write_weights(fit, final_weights, group_names)

    unweighted = sum(1 for v in fit.data.vertices if not v.groups)
    max_infl = max((len(v.groups) for v in fit.data.vertices), default=0)
    if unweighted or max_infl > MAX_INFLUENCES:
        raise RuntimeError(f"bad weights: unweighted={unweighted} max_infl={max_infl}")

    report.update(
        output_blend=str(OUTPUT_BLEND),
        mesh=OUTPUT_MESH,
        vertices=len(fit.data.vertices),
        polygons=len(fit.data.polygons),
        body_fit_scale=rounded(scale),
        crease_relaxed_vertices=creased,
        seam_groups=len(seams),
        seam_groups_welded=welded,
        tail_curl_deg=rounded(math.degrees(TAIL_CURL)),
        tail_sign=tail_sign,
        tail_vertices=len(tail_pts),
        tail_ramp=[TAIL_RAMP_LO, TAIL_RAMP_HI],
        subdiv_smooth=SUBDIV_SMOOTH,
        paw_shape=paw_shape,
        smoothing={"radius": SMOOTH_RADIUS, "factor": SMOOTH_FACTOR, "passes": SMOOTH_PASSES},
        cross_side_stripped=stripped,
        max_influences=max_infl,
        unweighted_vertices=unweighted,
    )
    bpy.ops.wm.save_as_mainfile(filepath=str(OUTPUT_BLEND), check_existing=False)
except Exception:
    report["error"] = traceback.format_exc()
finally:
    OUTPUT_REPORT.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps({k: v for k, v in report.items() if k != "error"}, indent=2))
    if report["error"]:
        print("V11_ERROR")
        print(report["error"])
    else:
        print("V11_OK")
