"""Prepare one selected, fully assembled KotOR model for portrait rendering."""

import re
import runpy
from pathlib import Path

import bpy


# Define the optional neighboring eye-tracking script and supported eye names.
LOCK_EYES_SCRIPT = Path(__file__).resolve().with_name("lock_kotor_eyes.py")
EYE_NAME_PAIRS = ({"eyela", "eyera"}, {"eyel", "eyer"})
BLENDER_SUFFIX = re.compile(r"\.\d{3}$")


# Remove Blender's numeric suffix from an imported object name.
def base_name(name):
    return BLENDER_SUFFIX.sub("", name)


# Yield a model root and every object parented below it.
def descendants(root):
    pending = [root]
    while pending:
        obj = pending.pop()
        yield obj
        pending.extend(obj.children)


# Resolve the selection or automatically find the only animated model root.
def selected_model_root():
    roots = set()
    for selected in bpy.context.selected_objects:
        root = selected
        while root.parent is not None:
            root = root.parent
        if root.type == "EMPTY":
            roots.add(root)

    if not roots:
        roots.update(
            obj
            for obj in bpy.context.scene.objects
            if obj.type == "EMPTY"
            and obj.parent is None
            and len(obj.kb.anim_list) > 0
        )

    if len(roots) != 1:
        names = ", ".join(sorted(root.name for root in roots)) or "none"
        raise RuntimeError(
            "Could not identify one imported animated model; select its root "
            f"or one of its children. Candidates: {names}"
        )
    return roots.pop()


# Find one named object below the model root, optionally allowing no match.
def find_descendant(root, name, required=True):
    matches = [
        obj
        for obj in descendants(root)
        if base_name(obj.name).casefold() == name.casefold()
    ]
    if not matches and not required:
        return None
    if len(matches) != 1:
        raise RuntimeError(
            f"Expected one {name} below {root.name}; found {len(matches)}"
        )
    return matches[0]


# Apply a specified transform or use camera-hook alignment as the default.
def align_model(root, camerahook, location=None, scale=0.5):
    root.scale = (scale, scale, scale)
    if location is not None:
        root.location = location
        bpy.context.view_layer.update()
        return f"location {tuple(location)} and scale {scale:g}"

    bpy.context.view_layer.update()
    world = root.matrix_world.copy()
    world.translation -= camerahook.matrix_world.translation
    root.matrix_world = world
    bpy.context.view_layer.update()
    return f"scale {scale:g} and {camerahook.name} at the portrait origin"


# Hide imported facial-bone helper meshes whose names end in _g.
def hide_bone_meshes(root):
    hidden = 0
    for obj in descendants(root):
        if obj.type != "MESH" or not base_name(obj.name).casefold().endswith("_g"):
            continue
        obj.hide_set(True)
        obj.hide_viewport = True
        obj.hide_render = True
        hidden += 1
    return hidden


# Hide every emitter mesh contained within the selected model.
def hide_emitters(root):
    hidden = 0
    for obj in descendants(root):
        if obj.type != "MESH" or obj.kb.meshtype != "EMITTER":
            continue
        obj.hide_set(True)
        obj.hide_viewport = True
        obj.hide_render = True
        hidden += 1
    return hidden


# Enable smooth shading on each visible render mesh in the selected model.
def shade_smooth_visible_meshes(root):
    smoothed = 0
    for obj in descendants(root):
        if obj.type != "MESH" or obj.hide_render or not obj.visible_get():
            continue
        for polygon in obj.data.polygons:
            polygon.use_smooth = True
        smoothed += 1
    return smoothed


# Aim the camera at the jaw and both portrait lights at the camera hook.
def track_camera_and_lights(camera_target, camerahook):
    camera = bpy.context.scene.camera
    if camera is None:
        raise RuntimeError("The scene does not have an active camera")

    lights = [
        bpy.context.scene.objects.get(name)
        for name in ("light_front", "light_back")
    ]
    lights = [light for light in lights if light is not None and light.type == "LIGHT"]
    if len(lights) != 2:
        names = ", ".join(light.name for light in lights) or "none"
        raise RuntimeError(f"Could not find both portrait lights; found: {names}")

    for obj, target, constraint_name in [
        (camera, camera_target, "KotOR Jaw Track"),
        *((light, camerahook, "KotOR CameraHook Track") for light in lights),
    ]:
        constraints = [
            item for item in obj.constraints if item.type == "DAMPED_TRACK"
        ]
        if not constraints:
            constraints.append(obj.constraints.new(type="DAMPED_TRACK"))
        constraint = constraints[0]
        for duplicate in constraints[1:]:
            obj.constraints.remove(duplicate)
        constraint.name = constraint_name
        constraint.target = target
        constraint.track_axis = "TRACK_NEGATIVE_Z"
    return camera, lights


# Leave the prepared complete-model root selected for the next script or operation.
def select_only(root):
    bpy.ops.object.select_all(action="DESELECT")
    root.hide_set(False)
    root.select_set(True)
    bpy.context.view_layer.objects.active = root


# Prepare one selected model using optional model-specific portrait settings.
def main(
    expected_model=None,
    location=None,
    scale=0.5,
    camera_target_name=None,
    require_animations=True,
):
    root = selected_model_root()
    if expected_model and base_name(root.name).casefold() != expected_model.casefold():
        raise RuntimeError(
            f"This script requires {expected_model}; selected {root.name}"
        )
    animation_count = len(root.kb.anim_list)
    if require_animations and animation_count == 0:
        raise RuntimeError(
            f"{root.name} has no imported animations; re-import it with animations enabled"
        )

    camerahook = find_descendant(root, "camerahook")
    if camera_target_name:
        camera_target = find_descendant(root, camera_target_name)
    else:
        camera_target = find_descendant(root, "f_jaw_g", required=False) or camerahook
    transform_status = align_model(root, camerahook, location, scale)
    hidden_bones = hide_bone_meshes(root)
    hidden_emitters = hide_emitters(root)
    smoothed = shade_smooth_visible_meshes(root)
    camera, lights = track_camera_and_lights(camera_target, camerahook)

    descendant_names = {
        base_name(obj.name).casefold() for obj in descendants(root)
    }
    tracked_eyes = any(pair.issubset(descendant_names) for pair in EYE_NAME_PAIRS)
    if tracked_eyes:
        if not LOCK_EYES_SCRIPT.is_file():
            raise RuntimeError(f"Eye-lock helper not found: {LOCK_EYES_SCRIPT}")
        runpy.run_path(str(LOCK_EYES_SCRIPT), run_name="__main__")

    select_only(root)
    print(
        f"Prepared complete model {root.name} with {animation_count} existing "
        f"animations, {transform_status}, "
        f"hid {hidden_bones} _g meshes and {hidden_emitters} emitters, "
        f"shade-smoothed {smoothed} visible meshes, "
        f"{'tracked its eyes, ' if tracked_eyes else ''}aimed {camera.name} at "
        f"{camera_target.name}, and aimed "
        f"{', '.join(light.name for light in lights)} at {camerahook.name}"
    )


# Execute when Blender runs this text block or script file.
if __name__ == "__main__":
    main()
