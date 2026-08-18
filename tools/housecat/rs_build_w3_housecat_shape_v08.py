"""Build the v0.8 house-cat mesh deformation bench.

The imported Witcher mesh already has a good cat body silhouette.  The field
failure is concentrated in the distal legs: DD2 rabbit ankle/toe rotations are
much stronger than the corresponding Witcher cat joints.  This pass therefore
keeps the body untouched, flattens the front paw volume conservatively, and
redistributes (rather than deletes) distal weights towards their parents.

Keeping some ankle/toe influence is intentional.  A completely rigid paw would
look calmer under the rabbit controller but could not use the native Witcher
cat motion bank that this mesh is being prepared for.
"""

from __future__ import annotations

from collections import defaultdict
from pathlib import Path
import json

import bpy
from mathutils import Vector


ROOT = Path(r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework")
RS = ROOT / "rs_tools"
SOURCE = RS / "w3_housecat_dd2_rabbit_host.blend"
OUTPUT = RS / "w3_housecat_dd2_rabbit_host_v08.blend"
REPORT = RS / "w3_housecat_shape_v08_report.json"

MESH_NAME = "LOD0_G0_S0_W3_CAT_RABBIT_HOST"
ARMATURE_NAME = "ch99_200 Armature"

# Fractions of each source group moved to its proximal parent.  Front paws get
# the larger correction because that is where both the ground and carry field
# tests exposed the rabbit joint mismatch.
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
PAW_HEIGHT_SCALE = 0.68
PAW_LENGTH_SCALE = 1.12
MIN_WEIGHT = 1.0e-5
MAX_INFLUENCES = 4


def rounded(value):
    if isinstance(value, Vector):
        return [round(float(v), 7) for v in value]
    return round(float(value), 7)


def read_weights(mesh):
    names = {group.index: group.name for group in mesh.vertex_groups}
    result = []
    for vertex in mesh.data.vertices:
        result.append({
            names[item.group]: float(item.weight)
            for item in vertex.groups
            if item.weight > MIN_WEIGHT
        })
    return result


def group_sums(weights):
    sums = defaultdict(float)
    for vertex_weights in weights:
        for name, weight in vertex_weights.items():
            sums[name] += weight
    return {name: round(value, 7) for name, value in sorted(sums.items())}


def transfer_weights(weights):
    for vertex_weights in weights:
        for source, target, fraction in TRANSFERS:
            amount = vertex_weights.get(source, 0.0) * fraction
            if amount <= 0.0:
                continue
            vertex_weights[source] -= amount
            vertex_weights[target] = vertex_weights.get(target, 0.0) + amount

        kept = sorted(
            ((name, weight) for name, weight in vertex_weights.items() if weight > MIN_WEIGHT),
            key=lambda item: item[1],
            reverse=True,
        )[:MAX_INFLUENCES]
        total = sum(weight for _, weight in kept)
        vertex_weights.clear()
        vertex_weights.update((name, weight / total) for name, weight in kept)


def reshape_front_paws(mesh, original_weights):
    details = {}
    for group_name in FRONT_TOES:
        weighted = [
            (vertex, original_weights[vertex.index].get(group_name, 0.0))
            for vertex in mesh.data.vertices
            if original_weights[vertex.index].get(group_name, 0.0) > MIN_WEIGHT
        ]
        if not weighted:
            raise RuntimeError(f"No vertices found for {group_name}")

        weight_sum = sum(weight for _, weight in weighted)
        centre = sum((vertex.co * weight for vertex, weight in weighted), Vector()) / weight_sum
        floor_z = min(vertex.co.z for vertex, _ in weighted)
        before_min = Vector((
            min(vertex.co.x for vertex, _ in weighted),
            min(vertex.co.y for vertex, _ in weighted),
            min(vertex.co.z for vertex, _ in weighted),
        ))
        before_max = Vector((
            max(vertex.co.x for vertex, _ in weighted),
            max(vertex.co.y for vertex, _ in weighted),
            max(vertex.co.z for vertex, _ in weighted),
        ))

        for vertex, weight in weighted:
            # Every vertex admitted to the toe region receives a visible but
            # conservative correction.  Toe-weight strength then biases the
            # core more strongly than the ankle transition.
            strength = 0.5 + 0.5 * min(1.0, weight * 1.35)
            length_scale = 1.0 + (PAW_LENGTH_SCALE - 1.0) * strength
            height_scale = 1.0 + (PAW_HEIGHT_SCALE - 1.0) * strength
            vertex.co.y = centre.y + (vertex.co.y - centre.y) * length_scale
            # Preserve the sole plane while reducing the rabbit-like club height.
            vertex.co.z = floor_z + (vertex.co.z - floor_z) * height_scale

        after_min = Vector((
            min(vertex.co.x for vertex, _ in weighted),
            min(vertex.co.y for vertex, _ in weighted),
            min(vertex.co.z for vertex, _ in weighted),
        ))
        after_max = Vector((
            max(vertex.co.x for vertex, _ in weighted),
            max(vertex.co.y for vertex, _ in weighted),
            max(vertex.co.z for vertex, _ in weighted),
        ))
        details[group_name] = {
            "vertices": len(weighted),
            "before_size": rounded(before_max - before_min),
            "after_size": rounded(after_max - after_min),
            "sole_z_preserved": rounded(floor_z),
        }
    mesh.data.update()
    return details


def write_weights(mesh, weights):
    names = [group.name for group in mesh.vertex_groups]
    for group in list(mesh.vertex_groups):
        mesh.vertex_groups.remove(group)
    groups = {name: mesh.vertex_groups.new(name=name) for name in names}
    for vertex, vertex_weights in zip(mesh.data.vertices, weights):
        for name, weight in vertex_weights.items():
            groups[name].add([vertex.index], weight, "REPLACE")


bpy.ops.wm.open_mainfile(filepath=str(SOURCE), load_ui=False)
mesh = bpy.data.objects.get(MESH_NAME)
armature = bpy.data.objects.get(ARMATURE_NAME)
if not mesh or mesh.type != "MESH":
    raise RuntimeError(f"Missing cat mesh {MESH_NAME}")
if not armature or armature.type != "ARMATURE":
    raise RuntimeError(f"Missing rabbit armature {ARMATURE_NAME}")

original = read_weights(mesh)
modified = [dict(vertex_weights) for vertex_weights in original]
shape = reshape_front_paws(mesh, original)
transfer_weights(modified)
write_weights(mesh, modified)

unweighted = sum(1 for vertex in mesh.data.vertices if not vertex.groups)
max_influences = max((len(vertex.groups) for vertex in mesh.data.vertices), default=0)
if unweighted or max_influences > MAX_INFLUENCES:
    raise RuntimeError(
        f"Invalid v0.8 weights: unweighted={unweighted}, max_influences={max_influences}"
    )

report = {
    "format": "iris-w3-housecat-shape-v08",
    "source": str(SOURCE),
    "output": str(OUTPUT),
    "mesh": MESH_NAME,
    "vertices": len(mesh.data.vertices),
    "polygons": len(mesh.data.polygons),
    "transfers": [
        {"source": source, "target": target, "fraction": fraction}
        for source, target, fraction in TRANSFERS
    ],
    "front_paw_shape": shape,
    "group_sums_before": group_sums(original),
    "group_sums_after": group_sums(modified),
    "unweighted_vertices": unweighted,
    "max_influences": max_influences,
    "intent": (
        "Preserve Witcher cat body; reduce rabbit distal-joint leverage while "
        "retaining enough ankle/toe articulation for the Witcher cat motion bank."
    ),
}
REPORT.write_text(json.dumps(report, indent=2), encoding="utf-8")
bpy.ops.wm.save_as_mainfile(filepath=str(OUTPUT), check_existing=False)
print("W3_HOUSECAT_SHAPE_V08_OK", OUTPUT)
