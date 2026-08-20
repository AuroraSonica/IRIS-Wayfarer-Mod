"""V13 house-cat mesh bench: BIND THE BONES THAT WERE ALREADY ANIMATING.

The v12 field verdict (Aurora, 08-19) was: dent under the head, tail "mixed
shapes as it goes down", and a "strange arch on the front legs only" in the
walk.  Headless forensics changed the diagnosis on all three:

* POSED QA RENDERS.  The rest pose neck is CLEAN; pitching Neck_0/Head_0 up
  22 degrees reproduces Aurora's dent exactly.  So the dent is a SKINNING
  defect, not a rest-shape one -- every position-smoothing attempt from v10
  through v12 was aimed at the wrong thing.  (A trial delta-field warp smooth
  made it worse: the skull sank into the neck.  Abandoned.)

* THE SKELETON AUDIT.  ch99_200 has FIFTY-EIGHT bones; the bind map used
  twenty-three.  Motlist forensics (track table inline at mot+0x80, bone
  hashes = murmur3 seed 0xFFFFFFFF over UTF-16LE) show ALL 58 bones carry a
  translation AND rotation key on EVERY frame of every clip.  So the rig was
  animating bones the mesh had no weights on:
    - L/R_Shoulder_Clavicle (the scapula, parent of FrontLeg_Upper) -- the W3
      cat's shoulder was bound to the HUMERUS instead, so the whole shoulder
      mass swung with the upper leg and the scapula's own motion was thrown
      away.  That is the front-leg "arch"/strut.
    - L/R_Ear_0 -- the cat's ears were welded to the skull, so a rig that
      animates ears every frame moved nothing.

V13 therefore:
  1. binds l_shoulder/r_shoulder to the CLAVICLES and l_ear/r_ear to the EAR
     bones (warp still driven by head for the ears, so ear geometry stays
     where the cat's skull puts it -- only the deform bone changes),
  2. widens the Head_0/Neck_0/Spine_3 weight blend (radius 0.03, 3 passes) so
     a big neck pitch no longer collapses the throat -- the standard fix for
     linear-blend-skinning pinch, and the only one available since the rig has
     a single Neck_0 where the W3 cat had neck + neck1,
  3. deletes the v12 neck-ring Laplacian (Laplacian smoothing loses volume, so
     it was feeding the dent it was meant to cure),
  4. scales the tail curl by the AXIAL distance along the tail instead of the
     radial 3D distance -- the radial form gave two verts on opposite walls of
     the tube different angles, shearing every cross-section into a wedge
     ("mixed shapes as it goes down"),
  5. rounds the tail tube with a position-keyed numpy TAUBIN pass (+0.5/-0.52,
     radius 0.009 < tube radius) to kill the linear-subdivision faceting
     without thinning it.

Seam law throughout: connectivity ops weld afterwards; the new passes are all
position-keyed, so seam duplicates move identically and need no weld.
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
OUTPUT_BLEND = RS / "w3_housecat_dd2_rabbit_host_v13.blend"
OUTPUT_REPORT = RS / "w3_housecat_rabbit_host_v13_report.json"

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
    "l_ear": "L_Ear_0",        # v13: the rig has real ear bones and animates
    "r_ear": "R_Ear_0",        # them every frame -- ears were stuck to the skull
    "tail1": "Tail",
    "tail2": "Tail",
    "tail3": "Tail",
    "tail4": "Tail",
    "tail5": "Tail",
    "l_shoulder": "L_Shoulder_Clavicle",   # v13: was welded to the humerus
    "l_bicep": "L_FrontLeg_Upper",
    "l_forearm": "L_FrontLeg_Lower",
    "l_hand": "L_FrontLeg_Ankle",
    "l_frontpaw": "L_FrontLeg_Toes",
    "r_shoulder": "R_Shoulder_Clavicle",   # v13: was welded to the humerus
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
    # v13: l_shoulder/r_shoulder now have a true counterpart (the clavicles),
    # so they warp on their own delta.  The ears keep warping on the head so
    # their GEOMETRY stays where the cat's skull puts it; only the deform bone
    # moved to L/R_Ear_0.
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
SIDE_GROUP_PREFIXES = ("L_FrontLeg", "R_FrontLeg", "L_RearLeg", "R_RearLeg",
                       "L_Shoulder", "R_Shoulder", "L_Ear", "R_Ear")

CREASE_SPREAD = 0.006
CREASE_SMOOTH_FACTOR = 0.5
CREASE_SMOOTH_PASSES = 2
# v13: neck WEIGHT blend widening -- the dent is a skinning collapse under
# pitch (reproduced headless), not a rest-shape crease.
NECK_BLEND_RADIUS = 0.024
NECK_BLEND_PASSES = 2
NECK_BLEND_FACTOR = 0.65
NECK_BLEND_MIN_W = 0.05
NECK_BLEND_GROUPS = ("Head_0", "Neck_0")   # NOT Spine_3: it spans the whole
NECK_BLEND_HEAD_CAP = 0.85                 # chest and would smear leg weights
                                           # onto the torso (the v09 dents).
                                           # Deep-skull verts stay rigid.
# v13: tail tube rounding (linear subdivision leaves it faceted)
TAIL_ROUND_RADIUS = 0.009        # < tube radius; >= diameter collapses the tube
TAIL_TAUBIN_LAMBDA = 0.5
TAIL_TAUBIN_MU = -0.52
TAIL_TAUBIN_ROUNDS = 2
SUBDIV_SMOOTH = 0.0              # v13: BACK to linear -- 0.8 tore every seam
SEAM_WELD_DECIMALS = 5           # v13: coincidence key for the seam weld
TAIL_CURL = math.radians(42.0)
TAIL_RAMP_LO = 0.2               # v13: smoothstep ramp replaces the 0.25 cliff
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


def radius_neighbours(points, radius):
    """Index lists of every point within `radius`, via a spatial hash grid."""
    grid = defaultdict(list)
    for i, p in enumerate(points):
        grid[tuple((p // radius).astype(int))].append(i)
    out = []
    for i, p in enumerate(points):
        key = tuple((p // radius).astype(int))
        cand = []
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for dz in (-1, 0, 1):
                    cand.extend(grid.get((key[0] + dx, key[1] + dy, key[2] + dz), ()))
        cand = np.array(cand, dtype=int)
        d = np.linalg.norm(points[cand] - p, axis=1)
        out.append(cand[d < radius])
    return out


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


report = {"format": "iris-w3-housecat-rabbit-host-v13", "error": None}
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

    # ---- v13: capture seam-duplicate groups BEFORE any smoothing op --------
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
    welded = weld_groups(fit, seams)   # v13: close the tears the relax opened

    # ---- v13: the v12 neck-ring Laplacian is GONE -------------------------
    # Laplacian smoothing loses volume, so relaxing a neck ring PINCHES it --
    # the "fix" was feeding the dent.  The dent is a skinning collapse and is
    # now treated in weight space (NECK_BLEND_* below).

    # ---- tail curl bake (v13: smoothstep ramp, no cliff) ------------------
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
    # AXIAL, not radial: scaling the curl by the full 3D distance gives two
    # verts on opposite tube walls at one station different angles, shearing
    # every ring into a wedge.  Axis measured PRE-curl (post-curl biases it).
    tail_axis = Vector((0.0, 0.0, 0.0))
    for o in ref:
        tail_axis += o
    if tail_axis.length < 1e-6:
        raise RuntimeError("Tail axis degenerate -- cannot bake the curl")
    tail_axis.normalize()
    tail_reach = max(max(o.dot(tail_axis) for o in ref), 1e-6)
    for vertex, weight in tail_pts:
        off = vertex.co - tail_local_head
        t = min(1.0, max(0.0, off.dot(tail_axis)) / tail_reach)
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

    # ---- subdivision (v13: LINEAR again -- smoothing here tears seams) ----
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

    # ---- v13: tail tube rounding, position-keyed Taubin (seam-safe) ------
    # Taubin (+lambda then -mu) rather than a plain Laplacian so the tube is
    # rounded without being thinned; numpy rather than bmesh.smooth_vert
    # because pre-subdivision seam groups cannot cover verts that subdivision
    # created, and a position-keyed pass needs no weld at all.
    tail_after = read_weights(fit)
    tail_idx = np.array(
        [v.index for v in fit.data.vertices
         if tail_after[v.index].get("Tail", 0.0) > 1.0e-4], dtype=int)
    tail_rounded = 0
    if len(tail_idx) > 3:
        pts = np.empty(len(fit.data.vertices) * 3)
        fit.data.vertices.foreach_get("co", pts)
        pts = pts.reshape((-1, 3))
        sub_pts = pts[tail_idx]
        nb_local = radius_neighbours(sub_pts, TAIL_ROUND_RADIUS)
        for factor in (TAIL_TAUBIN_LAMBDA, TAIL_TAUBIN_MU) * TAIL_TAUBIN_ROUNDS:
            moved = sub_pts.copy()
            for j in range(len(sub_pts)):
                nb = nb_local[j]
                if len(nb) > 2:
                    moved[j] = sub_pts[j] + factor * (sub_pts[nb].mean(axis=0) - sub_pts[j])
            sub_pts = moved
        pts[tail_idx] = sub_pts
        fit.data.vertices.foreach_set("co", pts.ravel())
        fit.data.update()
        tail_rounded = int(len(tail_idx))

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

    # ---- v13: NECK BLEND WIDENING (the posed dent) -----------------------
    # A 22-degree Neck_0 pitch collapsed the throat in the headless pose test.
    # The rig has ONE neck bone where the W3 cat had neck + neck1, so the
    # Head_0 -> Neck_0 -> Spine_3 transition is a step; widening it spreads the
    # linear-blend pinch over a longer span instead of concentrating it.
    neck_cols = [group_index[n] for n in NECK_BLEND_GROUPS if n in group_index]
    neck_blended = 0
    if neck_cols:
        sel = weight_matrix[:, neck_cols].sum(axis=1) > NECK_BLEND_MIN_W
        head_col = group_index.get("Head_0")
        if head_col is not None:
            sel = sel & (weight_matrix[:, head_col] < NECK_BLEND_HEAD_CAP)
        neck_sel = np.nonzero(sel)[0]
        if len(neck_sel):
            neck_nb = radius_neighbours(coords, NECK_BLEND_RADIUS)
            for _ in range(NECK_BLEND_PASSES):
                widened = weight_matrix.copy()
                for i in neck_sel:
                    nb = neck_nb[i]
                    if len(nb) > 1:
                        widened[i] = (
                            (1.0 - NECK_BLEND_FACTOR) * weight_matrix[i]
                            + NECK_BLEND_FACTOR * weight_matrix[nb].mean(axis=0)
                        )
                weight_matrix = widened
            neck_blended = int(len(neck_sel))

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
        bind_groups=sorted(set(MAP.values())),
        neck_blend={"radius": NECK_BLEND_RADIUS, "passes": NECK_BLEND_PASSES,
                    "factor": NECK_BLEND_FACTOR, "vertices": neck_blended},
        tail_axis=rounded([tail_axis.x, tail_axis.y, tail_axis.z]),
        tail_axial_reach=rounded(tail_reach),
        tail_rounded_vertices=tail_rounded,
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
        print("v13_ERROR")
        print(report["error"])
    else:
        print("v13_OK")
