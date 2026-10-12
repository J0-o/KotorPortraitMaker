# Animate a selected KotOR head, then import and align its matching body.
# Run this in Blender after importing and selecting a head such as P_AttonH.

import re
import runpy
from pathlib import Path

import bpy


# Resolve direct-execution defaults from this application instead of a development drive.
SCRIPT_DIRECTORY = Path(__file__).resolve().parent
MODEL_DIR = SCRIPT_DIRECTORY.parent / "game_files"
LOCK_EYES_SCRIPT = SCRIPT_DIRECTORY / "lock_kotor_eyes.py"
ANIMATION_MODEL = "S_Female03"
BLENDER_SUFFIX = re.compile(r"\.\d{3}$")


# Remove Blender's numeric suffix from an object or model name.
def base_name(name):
    return BLENDER_SUFFIX.sub("", name)


# Yield a root object and every object below it in the hierarchy.
def descendants(root):
    pending = [root]
    while pending:
        obj = pending.pop()
        yield obj
        pending.extend(obj.children)


# Resolve the selected object to its imported KotOR MDL root.
def selected_model_root(files):
    def find_in_parents(obj):
        while obj:
            name = base_name(obj.name)
            if obj.type == "EMPTY" and name.casefold() in files:
                return obj
            obj = obj.parent
        return None

    for obj in [bpy.context.active_object, *bpy.context.selected_objects]:
        root = find_in_parents(obj)
        if root:
            return root

    candidates = [
        obj
        for obj in bpy.context.scene.objects
        if obj.type == "EMPTY" and base_name(obj.name).casefold() in files
    ]
    if len(candidates) == 1:
        return candidates[0]

    names = ", ".join(obj.name for obj in candidates) or "none"
    raise RuntimeError(
        "Select the imported MDL root or one of its children. "
        f"Scene candidates: {names}"
    )


# Index available MDL files by case-insensitive model name.
def mdl_files(model_dir):
    paths = [
        *model_dir.glob("*.mdl"),
        *(model_dir / "player_heads").glob("*.mdl"),
    ]
    return {path.stem.casefold(): path for path in paths}


# Derive the matching body model name from a supported head model name.
def body_model_name(model_name):
    folded = model_name.casefold()
    if folded.startswith("pmh"):
        return "N_CommM"
    if folded.startswith("pfh"):
        return "N_CommF"
    if folded.endswith("h"):
        return model_name[:-1] + "BB"
    return None


# Require both the MDL and its companion MDX file.
def require_mdl(files, name):
    path = files.get(name.casefold())
    if path is None:
        raise RuntimeError(f"Missing model: {name}.mdl")
    if not path.with_suffix(".mdx").exists():
        raise RuntimeError(f"Missing companion file: {path.with_suffix('.mdx').name}")
    return path


# Make one object visible, selected, and active.
def select_only(obj):
    bpy.ops.object.select_all(action="DESELECT")
    obj.hide_set(False)
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj


# Import only animation data from a KotOR model.
def import_animations(path):
    result = bpy.ops.kb.mdlimport(
        filepath=str(path),
        import_geometry=False,
        import_animations=True,
        import_walkmeshes=False,
        build_materials=False,
        build_armature=False,
    )
    if result != {"FINISHED"}:
        raise RuntimeError(f"KotorBlender failed to import {path.name}: {result}")


# Import body geometry and materials without body animations.
def import_body(path):
    result = bpy.ops.kb.mdlimport(
        filepath=str(path),
        import_geometry=True,
        import_animations=False,
        import_walkmeshes=False,
        build_materials=True,
        build_armature=False,
    )
    if result != {"FINISHED"}:
        raise RuntimeError(f"KotorBlender failed to import {path.name}: {result}")


# Build an armature and transfer the imported object animation onto it.
def rebuild_animated_armature(mdl_root):
    select_only(mdl_root)
    if bpy.ops.kb.rebuild_armature() != {"FINISHED"}:
        raise RuntimeError(f"KotorBlender could not build an armature for {mdl_root.name}")

    armature = bpy.data.objects.get("Armature_" + mdl_root.name)
    if armature is None:
        raise RuntimeError(f"Could not find the armature built for {mdl_root.name}")

    select_only(mdl_root)
    if bpy.ops.kb.armature_apply_keyframes() != {"FINISHED"}:
        raise RuntimeError(
            f"KotorBlender could not apply object keyframes to {armature.name}"
        )
    return armature


# Find the expected model root among objects created by the latest import.
def find_new_root(objects_before, expected_name):
    matches = [
        obj
        for obj in set(bpy.data.objects) - objects_before
        if base_name(obj.name).casefold() == expected_name.casefold()
    ]
    if len(matches) != 1:
        raise RuntimeError(
            f"Could not identify imported root {expected_name}; "
            f"found {len(matches)} matches"
        )
    return matches[0]


# Attach the visible head mesh directly to the animated head root.
def fix_head_geo(head_root):
    preferred_names = {
        "head_geo",
        "head",
        "headnew_geo",
        "head01",
        "head02",
        "head2",
    }
    matches = [
        obj
        for obj in descendants(head_root)
        if obj.type == "MESH"
        and base_name(obj.name).casefold() in preferred_names
    ]
    if not matches:
        fallback = [
            obj
            for obj in head_root.children
            if obj.type == "MESH"
            and not base_name(obj.name).casefold().endswith("_g")
        ]
        if fallback:
            largest_size = max(len(obj.data.polygons) for obj in fallback)
            matches = [obj for obj in fallback if len(obj.data.polygons) == largest_size]
    if len(matches) != 1:
        raise RuntimeError(
            f"Expected one supported head mesh below {head_root.name}; "
            f"found {len(matches)}"
        )

    head_geo = matches[0]
    if head_geo.parent != head_root:
        world = head_geo.matrix_world.copy()
        head_geo.parent = head_root
        head_geo.matrix_world = world
    return head_geo


# Attach supported hair-flap meshes directly to the animated head root.
def fix_hair_flaps(head_root):
    matches = [
        obj
        for obj in descendants(head_root)
        if obj.type == "MESH"
        and base_name(obj.name).casefold() in {"hairflaps", "hairflaps02"}
    ]
    for hair_flaps in matches:
        if hair_flaps.parent != head_root:
            world = hair_flaps.matrix_world.copy()
            hair_flaps.parent = head_root
            hair_flaps.matrix_world = world
    return matches


# Hide Mira's duplicate secondary hair flaps from the viewport and renders.
def hide_mira_duplicate_hair_flaps(head_root):
    if base_name(head_root.name).casefold() != "p_mirah":
        return None

    duplicate = find_descendant(head_root, "hairFlaps02")
    if duplicate.type != "MESH":
        raise RuntimeError(f"{duplicate.name} is not a mesh")
    duplicate.hide_set(True)
    duplicate.hide_viewport = True
    duplicate.hide_render = True
    return duplicate


# Aim the camera at the jaw and both portrait lights at the camera hook.
def track_camera_and_lights(camera_target, camerahook):
    camera = bpy.context.scene.camera
    if camera is None:
        raise RuntimeError("The scene does not have an active camera")

    lights = [obj for obj in bpy.context.scene.objects if obj.type == "LIGHT"]
    if len(lights) != 2:
        names = ", ".join(light.name for light in lights) or "none"
        raise RuntimeError(f"Expected two scene lights; found: {names}")

    for obj, target, constraint_name in [
        (camera, camera_target, "KotOR Jaw Track"),
        *((light, camerahook, "KotOR CameraHook Track") for light in lights),
    ]:
        constraints = [
            item for item in obj.constraints if item.type == "DAMPED_TRACK"
        ]
        if not constraints:
            constraints.append(obj.constraints.new(type="DAMPED_TRACK"))
        constraint = next(
            (
                item
                for item in constraints
                if item.name in {"KotOR CameraHook Track", "KotOR Jaw Track"}
            ),
            constraints[0],
        )
        for duplicate in constraints:
            if duplicate != constraint:
                obj.constraints.remove(duplicate)
        constraint.name = constraint_name
        constraint.target = target
        constraint.track_axis = "TRACK_NEGATIVE_Z"
    return camera, lights


# Find exactly one named object below a model root.
def find_descendant(root, name):
    matches = [
        obj
        for obj in descendants(root)
        if base_name(obj.name).casefold() == name.casefold()
    ]
    if len(matches) != 1:
        raise RuntimeError(
            f"Expected one {name} below {root.name}; found {len(matches)}"
        )
    return matches[0]


# Move the body so its head hook aligns with the imported head root.
def align_body_headhook(body_root, headhook, head_root):
    body_world = body_root.matrix_world.copy()
    hook_world = headhook.matrix_world.copy()
    body_root.matrix_world = head_root.matrix_world @ hook_world.inverted() @ body_world
    bpy.context.view_layer.update()


# Change an object's parent without moving it in world space.
def reparent_preserve_world(obj, parent):
    world = obj.matrix_world.copy()
    obj.parent = parent
    obj.matrix_world = world


# Correct Handmaiden's lower teeth and tongue attachments.
def fix_handmaiden_attachments(head_root, body_root):
    if base_name(head_root.name).casefold() != "p_handmaidenh":
        return None, None

    lower_teeth = find_descendant(body_root, "teethLWR")
    animated_jaw = find_descendant(head_root, "f_jaw_g")
    tongue = find_descendant(head_root, "tongue")

    reparent_preserve_world(lower_teeth, animated_jaw)
    reparent_preserve_world(tongue, head_root)
    bpy.context.view_layer.update()
    return lower_teeth, tongue


# Keep a hood's base on the body while its upper vertices follow the head.
def deform_body_hood(head_root, body_root):
    hoods = [
        obj
        for obj in descendants(body_root)
        if obj.type == "MESH"
        and base_name(obj.name).casefold() in {"hood", "hood_geo"}
    ]
    if len(hoods) > 1:
        names = ", ".join(obj.name for obj in hoods)
        raise RuntimeError(f"Expected at most one body hood mesh; found {names}")
    if not hoods:
        return None

    hood = hoods[0]
    animated_head = find_descendant(head_root, "head_g")
    if not hood.data.vertices:
        raise RuntimeError(f"{hood.name} is not a usable hood mesh")

    world_z = [(hood.matrix_world @ vertex.co).z for vertex in hood.data.vertices]
    bottom = min(world_z)
    height = max(world_z) - bottom
    if height <= 0.0:
        raise RuntimeError(f"{hood.name} has no vertical height")

    fixed_limit = bottom + height * 0.30
    follow_limit = bottom + height * 0.70
    group = hood.vertex_groups.new(name="KotOR Hood Head Follow")
    for vertex, z_value in zip(hood.data.vertices, world_z):
        blend = max(
            0.0,
            min(1.0, (z_value - fixed_limit) / (follow_limit - fixed_limit)),
        )
        weight = blend * blend * (3.0 - 2.0 * blend)
        if weight > 0.0:
            group.add([vertex.index], weight, "REPLACE")

    modifier = hood.modifiers.new(name="KotOR Hood Head Follow", type="HOOK")
    modifier.object = animated_head
    modifier.vertex_group = group.name
    modifier.strength = 1.0
    modifier.falloff_type = "NONE"
    modifier.matrix_inverse = animated_head.matrix_world.inverted() @ hood.matrix_world
    bpy.context.view_layer.update()
    return hood


# Hide imported helper meshes whose names end in _g.
def hide_bone_meshes(root):
    hidden = 0
    for obj in descendants(root):
        if obj.type == "MESH" and base_name(obj.name).casefold().endswith("_g"):
            obj.hide_set(True)
            obj.hide_viewport = True
            obj.hide_render = True
            hidden += 1
    return hidden


# Hide every imported KotOR emitter mesh in the scene.
def hide_emitters():
    hidden = 0
    for obj in bpy.context.scene.objects:
        if obj.type != "MESH" or obj.kb.meshtype != "EMITTER":
            continue
        obj.hide_set(True)
        obj.hide_viewport = True
        obj.hide_render = True
        hidden += 1
    return hidden


# Hide placeholder head geometry included with the body model.
def hide_body_head_meshes(body_root):
    hidden = 0
    for obj in descendants(body_root):
        if obj.type == "MESH" and base_name(obj.name).casefold() in {
            "head",
            "head_geo",
        }:
            obj.hide_set(True)
            obj.hide_viewport = True
            obj.hide_render = True
            hidden += 1
    return hidden


# Hide duplicate imported objects carrying Blender's .001 suffix.
def hide_duplicate_objects():
    hidden = 0
    for obj in bpy.context.scene.objects:
        if obj.name.endswith(".001"):
            obj.hide_set(True)
            obj.hide_viewport = True
            obj.hide_render = True
            hidden += 1
    return hidden


# Hide tongue geometry because its animation is unreliable and portraits do not need it.
def hide_tongues():
    hidden = 0
    for obj in bpy.context.scene.objects:
        if obj.type != "MESH" or base_name(obj.name).casefold() not in {
            "tongue",
            "tongie",
        }:
            continue
        obj.hide_set(True)
        obj.hide_viewport = True
        obj.hide_render = True
        hidden += 1
    return hidden


# Enable smooth shading on every visible render mesh.
def shade_smooth_visible_meshes():
    selected_objects = list(bpy.context.selected_objects)
    active_object = bpy.context.view_layer.objects.active
    smoothed = 0
    bpy.ops.object.select_all(action="DESELECT")
    for obj in bpy.context.scene.objects:
        if obj.type != "MESH" or obj.hide_render or not obj.visible_get():
            continue
        obj.select_set(True)
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.shade_smooth()
        obj.select_set(False)
        smoothed += 1

    for obj in selected_objects:
        if obj.name in bpy.context.view_layer.objects:
            obj.select_set(True)
    if active_object and active_object.name in bpy.context.view_layer.objects:
        bpy.context.view_layer.objects.active = active_object
    return smoothed


# Mix a small texture-colored fill into the eyes to soften deep shadows.
def soften_eye_shadows(head_root):
    eyes = [
        obj
        for obj in descendants(head_root)
        if obj.type == "MESH"
        and base_name(obj.name).casefold() in {"eyela", "eyera", "eyel", "eyer"}
    ]
    for eye in eyes:
        for slot in eye.material_slots:
            material = slot.material
            if material is None:
                continue
            if material.users > 1:
                material = material.copy()
                material.name = eye.name + " Soft Shadows"
                slot.material = material

            material.use_nodes = True
            nodes = material.node_tree.nodes
            links = material.node_tree.links
            texture = next(
                (
                    node
                    for node in nodes
                    if node.bl_idname == "ShaderNodeTexImage"
                    and node.image is not None
                ),
                None,
            )
            output = next(
                (
                    node
                    for node in nodes
                    if node.bl_idname == "ShaderNodeOutputMaterial"
                    and node.is_active_output
                ),
                None,
            )
            surface_links = list(output.inputs["Surface"].links) if output else []
            if texture is None or output is None or len(surface_links) != 1:
                raise RuntimeError(f"Could not soften {eye.name} shadows")

            original_shader = surface_links[0].from_socket
            shadow_fill = nodes.new(type="ShaderNodeEmission")
            shadow_fill.name = "KotOR Eye Shadow Fill"
            shadow_fill.inputs["Strength"].default_value = 1.0
            shadow_mix = nodes.new(type="ShaderNodeMixShader")
            shadow_mix.name = "KotOR Eye Shadow Mix"
            shadow_mix.inputs[0].default_value = 0.025

            links.remove(surface_links[0])
            links.new(texture.outputs["Color"], shadow_fill.inputs["Color"])
            links.new(original_shader, shadow_mix.inputs[1])
            links.new(shadow_fill.outputs["Emission"], shadow_mix.inputs[2])
            links.new(shadow_mix.outputs["Shader"], output.inputs["Surface"])
    return eyes


# Prepare the selected head, import its body, and configure the portrait scene.
def main(model_dir=MODEL_DIR, body_model=None, animation_model=ANIMATION_MODEL):
    # Validate the model library and resolve the selected head and body files.
    model_dir = Path(model_dir)
    if not model_dir.is_dir():
        raise RuntimeError(f"Model directory does not exist: {model_dir}")

    files = mdl_files(model_dir)
    head_root = selected_model_root(files)
    head_name = base_name(head_root.name)
    body_name = body_model or body_model_name(head_name)
    if body_name is None:
        raise RuntimeError(
            f"{head_root.name} is not a head model with a matching body"
        )
    body_path = require_mdl(files, body_name)

    if any(
        base_name(obj.name).casefold() == body_name.casefold()
        for obj in bpy.data.objects
    ):
        raise RuntimeError(
            f"{body_name} is already imported; start with a clean head-only scene"
        )

    # Evaluate setup operations at the first animation frame.
    original_frame = bpy.context.scene.frame_current
    bpy.context.scene.frame_set(0)

    # Correct head mesh parenting before building its animated armature.
    head_geo = fix_head_geo(head_root)
    hair_flaps = fix_hair_flaps(head_root)

    # K2 heads use an external pose library. K1 heads can render statically.
    if animation_model.casefold() == "none":
        animation_status = "using the static K1 head pose"
    else:
        animation_path = require_mdl(files, animation_model)
        select_only(head_root)
        import_animations(animation_path)
        animation_count = len(head_root.kb.anim_list)
        if animation_count == 0:
            raise RuntimeError(f"No animations were imported onto {head_root.name}")

        armature = rebuild_animated_armature(head_root)
        action = armature.animation_data.action if armature.animation_data else None
        keyframe_count = (
            sum(len(curve.keyframe_points) for curve in action.fcurves)
            if action
            else 0
        )
        if keyframe_count == 0:
            raise RuntimeError(
                f"{armature.name} was built, but its action contains no keyframes"
            )
        animation_status = (
            f"imported {animation_count} animations from {animation_path.name}, "
            f"built {armature.name} with {keyframe_count} keyframes"
        )

    # Import and align the body beneath the animated head.
    hidden = hide_bone_meshes(head_root)
    hidden_mira_hair = hide_mira_duplicate_hair_flaps(head_root)
    objects_before = set(bpy.data.objects)
    try:
        import_body(body_path)
    except RuntimeError as error:
        raise RuntimeError(
            f"KotorBlender could not import body model {body_path.name}; "
            "choose a different body or supply a KotorBlender-compatible model"
        ) from error
    body_root = find_new_root(objects_before, body_name)
    headhook = find_descendant(body_root, "headhook")
    camerahook = find_descendant(body_root, "camerahook")
    align_body_headhook(body_root, headhook, head_root)
    fixed_lower_teeth, fixed_tongue = fix_handmaiden_attachments(head_root, body_root)
    deformed_hood = deform_body_hood(head_root, body_root)
    hidden += hide_bone_meshes(body_root)
    hidden_body_heads = hide_body_head_meshes(body_root)
    model_status = (
        f"imported {body_path.name}, aligned {headhook.name} to "
        f"{head_root.name}"
    )

    # Hide import helpers and duplicates before adjusting visible materials.
    hidden_duplicates = hide_duplicate_objects()
    hidden_emitters = hide_emitters()
    hidden_tongues = hide_tongues()
    smoothed = shade_smooth_visible_meshes()
    softened_eyes = soften_eye_shadows(head_root)

    # Aim the portrait camera and lights at their animation-aware targets.
    jaw = find_descendant(head_root, "f_jaw_g")
    camera, lights = track_camera_and_lights(jaw, camerahook)
    bpy.context.scene.frame_set(original_frame)
    select_only(head_root)

    # Keep both eyes aimed at the camera when the model supplies eye meshes.
    descendant_names = {
        base_name(obj.name).casefold() for obj in descendants(head_root)
    }
    if (
        {"eyela", "eyera"}.issubset(descendant_names)
        or {"eyel", "eyer"}.issubset(descendant_names)
    ):
        if not LOCK_EYES_SCRIPT.is_file():
            raise RuntimeError(f"Eye-lock helper not found: {LOCK_EYES_SCRIPT}")
        runpy.run_path(str(LOCK_EYES_SCRIPT), run_name="__main__")

    # Build a readable summary of optional model-specific corrections.
    hair_names = ", ".join(obj.name for obj in hair_flaps)
    hair_status = f", fixed {hair_names}" if hair_names else ""
    mira_hair_status = (
        f", hid duplicate {hidden_mira_hair.name}"
        if hidden_mira_hair
        else ""
    )
    teeth_status = (
        f", attached {fixed_lower_teeth.name} to animated f_jaw_g"
        if fixed_lower_teeth
        else ""
    )
    tongue_status = (
        f", removed double jaw motion from {fixed_tongue.name}"
        if fixed_tongue
        else ""
    )
    hood_status = (
        f", weighted {deformed_hood.name} between body and animated head_g"
        if deformed_hood
        else ""
    )

    head_status = f"Fixed {head_geo.name}"

    # Report the completed scene preparation in Blender's console.
    print(
        f"{head_status}{hair_status}{mira_hair_status}"
        f"{teeth_status}{tongue_status}"
        f"{hood_status}, "
        f"{animation_status}, {model_status}, hid {hidden} _g meshes, "
        f"hid {hidden_body_heads} "
        f"duplicate body head meshes, hid {hidden_duplicates} .001 objects, "
        f"hid {hidden_emitters} emitters, hid {hidden_tongues} tongue meshes, "
        f"shade-smoothed {smoothed} visible meshes, softened shadows on "
        f"{len(softened_eyes)} eyes, aimed {camera.name} at {jaw.name}, "
        f"and aimed {', '.join(light.name for light in lights)} at "
        f"{camerahook.name}"
    )
    return head_root, body_root


# Execute when Blender runs this text block or script file.
if __name__ == "__main__":
    main()
