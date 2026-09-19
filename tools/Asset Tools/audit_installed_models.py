"""Audit the INSTALLED biped+core FBX pairs for the three rendering artifacts
reported 2026-09-06: outline, out-of-place assets, translucent head.

Preserved from the F26 investigation and corrected the same day. It runs
against what is INSTALLED under Contents/.../models_X/Skinned/Clothes, not
against a build directory, because two of the shipped cores had no surviving
build directory at all.

  "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" -b \\
      --python tools/audit_installed_models.py -- BIPED.fbx CORE.fbx OUT.json

THE METRIC IS PER FACE, NOT "CONSISTENT WITH ITS NEIGHBOURS". The first version
counted faces that disagreed with bmesh's recalc_face_normals, and that number
was meaningless on the mesh it mattered most for: the EMP outer is a
non-orientable surface (garment layers joined so no global orientation
exists), recalc moves 1,100-1,500 faces on every pass, and "45% flipped" was a
measurement of the reference. The renderer's rule is local and orientation-free
- the game culls back faces on every character draw (F9), so the question per
face is whether a viewer who can see it sees its front. Two rays from just off
each face, along its normal and against it: back escapes and front does not is
INWARD-VISIBLE, and that is the count that matters. Cast on a triangulated copy
so a non-planar quad cannot hit itself.

This mirrors blender/winding.py in the PZ-Art-Pipeline repository, which is
the authoritative copy and the one the pipeline gates on; this file is a
diagnostic for the lab and deliberately has no cross-repository import.

Reports, per pair: inward-visible faces of outer and core attributed to their
dominant Bip01 vertex group and height decile; core loose parts classified as
isolated vertices, shards (<= 8 verts) and larger fragments with height bands.
"""

import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

import bmesh
import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree

args = sys.argv[sys.argv.index("--") + 1:]
biped_path, core_path, out_path = map(Path, args[:3])


def import_fbx(path):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.fbx(filepath=str(path), use_anim=False)
    return [o for o in bpy.data.objects if o not in before and o.type == "MESH"]


def world_bmesh(obj):
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.transform(obj.matrix_world)
    bm.verts.ensure_lookup_table()
    bm.faces.ensure_lookup_table()
    bm.edges.ensure_lookup_table()
    return bm


def extent(bm):
    lo = Vector((min(v.co.x for v in bm.verts), min(v.co.y for v in bm.verts), min(v.co.z for v in bm.verts)))
    hi = Vector((max(v.co.x for v in bm.verts), max(v.co.y for v in bm.verts), max(v.co.z for v in bm.verts)))
    return lo, hi, (hi - lo).length


def classify_faces(bm):
    """Mirror of winding.classify_faces: outward_visible / inward_visible /
    occluded / two_sided by the two-ray test on a triangulated copy."""
    bm.faces.ensure_lookup_table()
    bm.normal_update()
    _lo, _hi, diagonal = extent(bm)
    classes = {"outward_visible": [], "inward_visible": [], "occluded": [], "two_sided": []}
    if diagonal <= 0.0:
        return classes
    tri = bm.copy()
    tri.faces.ensure_lookup_table()
    face_map = bmesh.ops.triangulate(tri, faces=tri.faces)["face_map"]
    tri.faces.ensure_lookup_table()
    tri.normal_update()
    tree = BVHTree.FromBMesh(tri)
    epsilon = diagonal * 1.0e-3
    reach = diagonal * 4.0
    votes = {}
    for triangle in tri.faces:
        index = face_map.get(triangle, triangle).index
        normal = triangle.normal
        entry = votes.setdefault(index, [0, 0, 0])
        if normal.length_squared == 0.0:
            entry[2] += 1
            continue
        centre = triangle.calc_center_median()
        entry[0] += tree.ray_cast(centre + normal * epsilon, normal, reach)[0] is None
        entry[1] += tree.ray_cast(centre - normal * epsilon, -normal, reach)[0] is None
        entry[2] += 1
    tri.free()
    for face in bm.faces:
        front_open, back_open, count = votes.get(face.index, (0, 0, 0))
        if count == 0 or (not front_open and not back_open):
            classes["occluded"].append(face.index)
        elif front_open and not back_open:
            classes["outward_visible"].append(face.index)
        elif back_open and not front_open:
            classes["inward_visible"].append(face.index)
        else:
            classes["two_sided"].append(face.index)
    return classes


def group_weights(obj):
    names = {g.index: g.name for g in obj.vertex_groups}
    out = defaultdict(dict)
    for v in obj.data.vertices:
        for g in v.groups:
            out[v.index][names[g.group]] = g.weight
    return out


def inward_report(obj, bm):
    classes = classify_faces(bm)
    weights = group_weights(obj)
    zs = [v.co.z for v in bm.verts]
    floor, height = min(zs), max(zs) - min(zs)
    by_group = Counter()
    by_decile = Counter()
    for fi in classes["inward_visible"]:
        face = bm.faces[fi]
        acc = Counter()
        for v in face.verts:
            for name, w in weights.get(v.index, {}).items():
                acc[name] += w
        by_group[acc.most_common(1)[0][0] if acc else "(none)"] += 1
        if height > 0:
            by_decile["%d0s%%" % int(10 * (face.calc_center_median().z - floor) / height)] += 1
    return {
        "faces": len(bm.faces),
        "inward_visible": len(classes["inward_visible"]),
        "outward_visible": len(classes["outward_visible"]),
        "occluded": len(classes["occluded"]),
        "two_sided": len(classes["two_sided"]),
        "inward_by_group": [{"group": g, "faces": n} for g, n in by_group.most_common(10)],
        "inward_by_height_decile": dict(sorted(by_decile.items())),
    }


def loose_parts(bm, height):
    seen = set()
    parts = []
    for v in bm.verts:
        if v.index in seen:
            continue
        stack = [v]; part = []; seen.add(v.index)
        while stack:
            cur = stack.pop(); part.append(cur)
            for e in cur.link_edges:
                o = e.other_vert(cur)
                if o.index not in seen:
                    seen.add(o.index); stack.append(o)
        parts.append(part)
    parts.sort(key=len, reverse=True)
    isolated = shards = 0
    larger = []
    bands = Counter()
    for p in parts[1:]:
        zs = [q.co.z for q in p]
        band = "%.0f-%.0f%%" % (100 * min(zs) / height, 100 * max(zs) / height) if height else "?"
        if len(p) == 1:
            isolated += 1
        elif len(p) <= 8:
            shards += 1
            bands[band] += 1
        else:
            larger.append({"vertices": len(p), "height_band": band})
    return {"parts": len(parts), "isolated_vertices": isolated, "shards_le8": shards,
            "shard_bands": bands.most_common(6), "larger_stray_parts": larger[:8]}


bpy.ops.wm.read_factory_settings(use_empty=True)
biped = max(import_fbx(biped_path), key=lambda o: len(o.data.vertices))
core = max(import_fbx(core_path), key=lambda o: len(o.data.vertices))
bb = world_bmesh(biped)
cb = world_bmesh(core)
zs = [v.co.z for v in bb.verts]
height = max(zs) - min(zs)
report = {
    "biped": biped_path.name, "core": core_path.name, "height": round(height, 5),
    "biped_winding": inward_report(biped, bb),
    "core_winding": inward_report(core, cb),
    "core_parts": loose_parts(cb, height),
}
bb.free(); cb.free()
out_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
print("AUDIT_OK " + str(out_path))
