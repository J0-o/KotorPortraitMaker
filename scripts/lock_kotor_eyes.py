"""Aim KotOR eyes in parallel toward the active camera on the XY plane."""

import bpy
from mathutils import Vector


EYE_NAME_PAIRS = (("eyeLA", "eyeRA"), ("eyeL", "eyeR"))
TARGET_NAMES = ("Kotor Eye Target L", "Kotor Eye Target R")
CONSTRAINT_NAME = "Track Eye Parallel"
CAMERA_CONSTRAINT_NAME = "Track Eye to Camera"
OLD_CONSTRAINT_NAME = "Lock Eye World X/Z"
ROTATION_PATHS = {"rotation_euler", "rotation_quaternion", "rotation_axis_angle"}
TARGET_DISTANCE = 1.0


def unmute_rotation_curves(eye):
    action = eye.animation_data.action if eye.animation_data else None
    curves = [
        curve for curve in action.fcurves if curve.data_path in ROTATION_PATHS
    ] if action else []
    for curve in curves:
        curve.mute = False
    return len(curves)


def find_eyes(required=True):
    eye_names = next(
        (
            names
            for names in EYE_NAME_PAIRS
            if all(bpy.data.objects.get(name) is not None for name in names)
        ),
        None,
    )
    if eye_names is None:
        if not required:
            return None
        expected = " or ".join("/".join(names) for names in EYE_NAME_PAIRS)
        raise RuntimeError(f"Missing eye objects; expected {expected}")
    return tuple(bpy.data.objects[name] for name in eye_names)


def eye_target(name, create=False):
    target = bpy.data.objects.get(name)
    if target is None and create:
        target = bpy.data.objects.new(name, None)
        bpy.context.scene.collection.objects.link(target)
        target.empty_display_type = "PLAIN_AXES"
        target.empty_display_size = 0.05
        target.hide_render = True
    if target is not None and target.type != "EMPTY":
        raise RuntimeError(f"Eye target is not an empty: {name}")
    return target


def update_parallel_eye_targets(camera=None, required=True):
    eyes = find_eyes(required=required)
    targets = tuple(eye_target(name) for name in TARGET_NAMES)
    if eyes is None or any(target is None for target in targets):
        if required:
            raise RuntimeError("Parallel eye targets have not been created")
        return False

    camera = camera or bpy.context.scene.camera
    if camera is None:
        raise RuntimeError("The scene does not have an active camera")

    bpy.context.view_layer.update()
    depsgraph = bpy.context.evaluated_depsgraph_get()
    eye_positions = [
        eye.evaluated_get(depsgraph).matrix_world.translation.copy()
        for eye in eyes
    ]
    midpoint = (eye_positions[0] + eye_positions[1]) * 0.5
    camera_position = camera.evaluated_get(depsgraph).matrix_world.translation
    gaze = Vector(
        (
            camera_position.x - midpoint.x,
            camera_position.y - midpoint.y,
            0.0,
        )
    )
    if gaze.length_squared == 0.0:
        raise RuntimeError("The camera and eye midpoint share the same XY position")
    gaze.normalize()

    for eye_position, target in zip(eye_positions, targets):
        target.location = eye_position + gaze * TARGET_DISTANCE
        target.location.z = eye_position.z
    bpy.context.view_layer.update()
    return True


def track_eye_to_target(eye, target):
    old_constraint = eye.constraints.get(OLD_CONSTRAINT_NAME)
    if old_constraint is not None:
        eye.constraints.remove(old_constraint)

    constraint = eye.constraints.get(CONSTRAINT_NAME) or eye.constraints.get(
        CAMERA_CONSTRAINT_NAME
    )
    if constraint is None:
        constraint = next(
            (item for item in eye.constraints if item.type == "DAMPED_TRACK"),
            None,
        )
    if constraint is None:
        constraint = eye.constraints.new(type="DAMPED_TRACK")
    constraint.name = CONSTRAINT_NAME
    constraint.target = target
    constraint.track_axis = "TRACK_Y"
    constraint.influence = 1.0
    return constraint


def main():
    camera = bpy.context.scene.camera
    if camera is None:
        raise RuntimeError("The scene does not have an active camera")

    eyes = find_eyes()
    targets = tuple(eye_target(name, create=True) for name in TARGET_NAMES)
    update_parallel_eye_targets(camera)

    for eye, target in zip(eyes, targets):
        curve_count = unmute_rotation_curves(eye)
        track_eye_to_target(eye, target)
        print(
            f"Aimed {eye.name} local +Y at {target.name} and unmuted "
            f"{curve_count} rotation curves"
        )


if __name__ == "__main__":
    main()
