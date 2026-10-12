"""Flip camera-visible mesh faces whose normals point away from the camera."""

import bpy
import bmesh
from bpy_extras.object_utils import world_to_camera_view
from mathutils import Vector


def direction_to_camera(camera, world_center):
    if camera.data.type == "ORTHO":
        return (camera.matrix_world.to_quaternion() @ Vector((0, 0, 1))).normalized()
    return (camera.matrix_world.translation - world_center).normalized()


def remove_duplicate_faces(camera, depsgraph, obj):
    mesh = obj.data
    evaluated = obj.evaluated_get(depsgraph)
    evaluated_mesh = evaluated.data
    if len(mesh.polygons) != len(evaluated_mesh.polygons):
        print(f"Skipped {obj.name}: modifiers change its face count", flush=True)
        return 0, 0

    bm = bmesh.new()
    bm.from_mesh(mesh)
    bm.faces.ensure_lookup_table()
    groups = {}
    for face in bm.faces:
        key = (tuple(sorted(vertex.index for vertex in face.verts)), face.material_index)
        groups.setdefault(key, []).append(face)

    normal_matrix = evaluated.matrix_world.to_3x3().inverted().transposed()
    duplicates = []
    flipped = 0
    for faces in groups.values():
        if len(faces) < 2:
            continue
        keep = max(
            faces,
            key=lambda face: (
                normal_matrix @ evaluated_mesh.polygons[face.index].normal
            ).normalized().dot(
                direction_to_camera(
                    camera,
                    evaluated.matrix_world
                    @ evaluated_mesh.polygons[face.index].center,
                )
            ),
        )
        evaluated_face = evaluated_mesh.polygons[keep.index]
        world_center = evaluated.matrix_world @ evaluated_face.center
        world_normal = (normal_matrix @ evaluated_face.normal).normalized()
        if world_normal.dot(direction_to_camera(camera, world_center)) < 0.0:
            keep.normal_flip()
            flipped += 1
        duplicates.extend(face for face in faces if face != keep)

    if duplicates:
        bmesh.ops.delete(bm, geom=duplicates, context="FACES")
        bm.to_mesh(mesh)
        mesh.update()
    bm.free()
    return len(duplicates), flipped


def face_is_visible(scene, depsgraph, camera, obj, face_index, world_center):
    projected = world_to_camera_view(scene, camera, world_center)
    if projected.z <= 0.0 or not (0.0 <= projected.x <= 1.0 and 0.0 <= projected.y <= 1.0):
        return False

    if camera.data.type == "ORTHO":
        toward_camera = direction_to_camera(camera, world_center)
        depth = (world_center - camera.matrix_world.translation).dot(-toward_camera)
        origin = world_center + toward_camera * (depth + camera.data.clip_start)
    else:
        origin = camera.matrix_world.translation

    ray = world_center - origin
    distance = ray.length
    if distance == 0.0:
        return False
    hit, _, _, hit_index, hit_object, _ = scene.ray_cast(
        depsgraph, origin, ray.normalized(), distance=distance + 0.001
    )
    if not hit:
        return False
    hit_object = getattr(hit_object, "original", hit_object)
    return hit_object == obj and hit_index == face_index


def flip_object_faces(scene, depsgraph, camera, obj):
    evaluated = obj.evaluated_get(depsgraph)
    source_mesh = obj.data
    evaluated_mesh = evaluated.data
    if len(source_mesh.polygons) != len(evaluated_mesh.polygons):
        print(f"Skipped {obj.name}: modifiers change its face count", flush=True)
        return 0

    normal_matrix = evaluated.matrix_world.to_3x3().inverted().transposed()
    faces_to_flip = []
    for face in evaluated_mesh.polygons:
        world_center = evaluated.matrix_world @ face.center
        world_normal = (normal_matrix @ face.normal).normalized()
        if world_normal.dot(direction_to_camera(camera, world_center)) >= 0.0:
            continue
        if face_is_visible(
            scene, depsgraph, camera, obj, face.index, world_center
        ):
            faces_to_flip.append(face.index)

    for face_index in faces_to_flip:
        source_mesh.polygons[face_index].flip()
    if faces_to_flip:
        source_mesh.update()
    return len(faces_to_flip)


def main(mesh_objects=None):
    scene = bpy.context.scene
    camera = scene.camera
    if camera is None:
        raise RuntimeError("The scene does not have an active camera")

    candidates = scene.objects if mesh_objects is None else mesh_objects
    mesh_objects = [
        obj
        for obj in candidates
        if obj.type == "MESH" and not obj.hide_render and obj.visible_get()
    ]
    for obj in mesh_objects:
        if obj.data.users > 1:
            obj.data = obj.data.copy()

    bpy.context.view_layer.update()
    depsgraph = bpy.context.evaluated_depsgraph_get()
    removed = 0
    flipped = 0
    for obj in mesh_objects:
        object_removed, object_flipped = remove_duplicate_faces(
            camera, depsgraph, obj
        )
        removed += object_removed
        flipped += object_flipped
        if object_removed:
            print(
                f"Removed {object_removed} duplicate rear face(s) on {obj.name}",
                flush=True,
            )

    bpy.context.view_layer.update()
    depsgraph = bpy.context.evaluated_depsgraph_get()
    for obj in mesh_objects:
        count = flip_object_faces(scene, depsgraph, camera, obj)
        flipped += count
        if count:
            print(f"Flipped {count} camera-visible face(s) on {obj.name}", flush=True)

    print(
        f"Camera-facing normal check complete: {removed} duplicate rear face(s) "
        f"removed, {flipped} face(s) flipped "
        f"across {len(mesh_objects)} mesh object(s)",
        flush=True,
    )
    return flipped


if __name__ == "__main__":
    main()
