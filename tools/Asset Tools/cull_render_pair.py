"""Render two FBX builds of one asset side by side with back-face culling ON,
the way Model.DrawChar draws them (GL_CULL_FACE + glCullFace after the
loader's MAKE_LEFT_HANDED mirror = ordinary back-face culling).
Columns: A front, A back, B front, B back.  Blender headless, Workbench.
usage: blender -b --python cullrender.py -- A.fbx B.fbx TEXTURE.png OUT.png [nocull]
"""
import math
import sys

import bpy
from mathutils import Vector

args = sys.argv[sys.argv.index("--") + 1:]
fbx_a, fbx_b, tex_path, out_path = args[:4]
cull = "nocull" not in args[4:]

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene


def import_meshes(path):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.fbx(filepath=path, use_anim=False)
    new = [o for o in bpy.data.objects if o not in before]
    meshes = [o for o in new if o.type == "MESH"]
    return new, meshes


image = bpy.data.images.load(tex_path)
mat = bpy.data.materials.new("skin")
mat.use_nodes = True
mat.use_backface_culling = cull
nodes = mat.node_tree.nodes
tex = nodes.new("ShaderNodeTexImage")
tex.image = image
bsdf = nodes.get("Principled BSDF")
mat.node_tree.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
nodes.active = tex

columns = []
for label, path in (("A", fbx_a), ("B", fbx_b)):
    for view, yaw in (("front", 0.0), ("back", math.pi)):
        new, meshes = import_meshes(path)
        # Parent everything under one empty so the whole hierarchy can be placed.
        root = bpy.data.objects.new("root_%s_%s" % (label, view), None)
        scene.collection.objects.link(root)
        for o in new:
            if o.parent is None:
                o.parent = root
        for m in meshes:
            m.data.materials.clear()
            m.data.materials.append(mat)
        columns.append((root, yaw, meshes))

bpy.context.view_layer.update()

# Measure one copy to size the layout.
pts = []
for m in columns[0][2]:
    for corner in m.bound_box:
        pts.append(m.matrix_world @ Vector(corner))
lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
height = hi.z - lo.z
width = max(hi.x - lo.x, hi.y - lo.y)
gap = width * 1.15
centre_z = (lo.z + hi.z) * 0.5
centre_xy = Vector(((lo.x + hi.x) * 0.5, (lo.y + hi.y) * 0.5, 0.0))

for i, (root, yaw, _m) in enumerate(columns):
    root.rotation_euler = (0.0, 0.0, yaw)
    # rotate about the model's own centre, then slide into its column
    offset = Vector((i * gap, 0.0, 0.0)) - centre_xy
    root.location = Vector((offset.x, offset.y, 0.0))
    if yaw:
        # rotating by pi moves the centre to -centre; compensate
        root.location = Vector((i * gap + centre_xy.x, centre_xy.y, 0.0))

cam_data = bpy.data.cameras.new("cam")
cam_data.type = "ORTHO"
cam_data.ortho_scale = max(gap * len(columns), height * 1.1)
cam = bpy.data.objects.new("cam", cam_data)
scene.collection.objects.link(cam)
scene.camera = cam
mid = Vector((gap * (len(columns) - 1) * 0.5, 0.0, centre_z))
cam.location = mid + Vector((0.0, -10.0, 0.0))
cam.rotation_euler = (math.pi / 2.0, 0.0, 0.0)

scene.render.engine = "BLENDER_WORKBENCH"
scene.display.shading.light = "STUDIO"
scene.display.shading.color_type = "TEXTURE"
scene.display.shading.show_backface_culling = cull
scene.display.shading.show_shadows = False
res_x = 1800
for extra in args[4:]:
    if extra.startswith("res="):
        res_x = int(extra[4:])
scene.render.resolution_x = res_x
scene.render.resolution_y = int(res_x * (height * 1.1) / (gap * len(columns))) + 1
scene.render.resolution_percentage = 100
scene.render.film_transparent = False
scene.render.image_settings.file_format = "PNG"
scene.render.filepath = out_path
bpy.ops.render.render(write_still=True)
print("CULLRENDER_OK", out_path, "cull=%s" % cull)
