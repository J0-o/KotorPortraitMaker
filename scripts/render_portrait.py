"""Render one, three, or five staged portraits in Blender."""

import csv
import json
import math
import runpy
import subprocess
from pathlib import Path

import bpy
from mathutils import Quaternion
from io_scene_kotor.scene.material import rebuild_object_materials


def descendants(root):
    pending = [root]
    while pending:
        obj = pending.pop()
        yield obj
        pending.extend(obj.children)


def mute_rotation_curves(animated_object, data_path):
    action = (
        animated_object.animation_data.action
        if animated_object.animation_data
        else None
    )
    if action is None:
        return
    for curve in action.fcurves:
        if curve.data_path == data_path:
            curve.mute = True


def close_head_mouth():
    for obj in bpy.context.scene.objects:
        if obj.type != "ARMATURE":
            continue
        jaw = obj.pose.bones.get("f_jaw_g")
        if jaw is not None:
            mute_rotation_curves(
                obj, jaw.path_from_id("rotation_quaternion")
            )
            jaw.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
            return

    for obj in bpy.context.scene.objects:
        if obj.name.casefold() == "f_jaw_g":
            mute_rotation_curves(obj, "rotation_quaternion")
            obj.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)


def set_world_color(scene, hex_color):
    if hex_color is None:
        return
    if len(hex_color) != 7 or hex_color[0] != "#":
        raise RuntimeError(f"World color must use #RRGGBB format: {hex_color}")
    try:
        srgb = tuple(int(hex_color[index:index + 2], 16) / 255.0 for index in (1, 3, 5))
    except ValueError as error:
        raise RuntimeError(f"World color must use #RRGGBB format: {hex_color}") from error

    def to_linear(channel):
        if channel <= 0.04045:
            return channel / 12.92
        return ((channel + 0.055) / 1.055) ** 2.4

    color = tuple(to_linear(channel) for channel in srgb)
    if scene.world is None:
        scene.world = bpy.data.worlds.new("Portrait World")
    scene.world.color = color
    if scene.world.use_nodes and scene.world.node_tree is not None:
        for node in scene.world.node_tree.nodes:
            if node.type == "BACKGROUND":
                node.inputs["Color"].default_value = (*color, 1.0)
    print(f"World color: {hex_color.upper()}", flush=True)


def timeline_frame(pose_data, pose, requested_frame=None):
    if requested_frame is not None:
        if requested_frame < 0:
            raise RuntimeError(f"Frame cannot be negative: {requested_frame}")
        return requested_frame
    if pose == "no_animation":
        return 0

    with Path(pose_data).open(newline="", encoding="utf-8-sig") as stream:
        for row in csv.DictReader(stream):
            if row["review_rank"] == str(pose):
                return int(row["timeline_frame"])
    raise RuntimeError(f"Pose {pose!r} was not found in {pose_data}")


def texture_files(game_files):
    files = {}
    for path in Path(game_files).iterdir():
        if path.is_file() and path.suffix.casefold() in {".tga", ".png"}:
            key = path.stem.casefold()
            if key in files:
                raise RuntimeError(
                    f"Case-insensitive texture collision: {files[key].name}, {path.name}"
                )
            files[key] = path
    return files


def capture_bitmaps(model_roots):
    bitmaps = {}
    for root in model_roots:
        root_bitmaps = {
            obj: obj.kb.bitmap
            for obj in descendants(root)
            if obj.type == "MESH" and getattr(obj.kb, "bitmap", "")
        }
        bitmaps.update(root_bitmaps)
        print(
            f"Texture root {root.name}: {len(root_bitmaps)} textured meshes, "
            f"{len(set(root_bitmaps.values()))} bitmap(s)",
            flush=True,
        )
    return bitmaps


def apply_model_texture(model_root, game_files, texture_name):
    available = texture_files(game_files)
    texture_path = available.get(texture_name.casefold())
    if texture_path is None:
        raise RuntimeError(f"Body texture does not exist: {texture_name}")

    changed = 0
    originals = set()
    for obj in descendants(model_root):
        original = getattr(obj.kb, "bitmap", "") if obj.type == "MESH" else ""
        if not original:
            continue
        originals.add(original)
        obj.kb.bitmap = texture_path.stem
        rebuild_object_materials(obj, [str(game_files)], [])
        changed += 1
    if changed == 0:
        raise RuntimeError(f"{model_root.name} has no textured meshes to override")
    print(
        f"Body texture override: {', '.join(sorted(originals))}"
        f"->{texture_path.stem} on {changed} mesh(es)",
        flush=True,
    )


def apply_model_brightness(model_root, factor):
    if factor == 1.0:
        return 0
    adjusted = 0
    for obj in descendants(model_root):
        if obj.type != "MESH" or not getattr(obj.kb, "bitmap", ""):
            continue
        for slot in obj.material_slots:
            material = slot.material
            if material is None or not material.use_nodes:
                continue
            if material.users > 1:
                material = material.copy()
                slot.material = material
            nodes = material.node_tree.nodes
            links = material.node_tree.links
            texture = nodes.get("diffuse_tex")
            if texture is None:
                continue
            multiplier = nodes.get("portrait_body_brightness")
            if multiplier is None:
                multiplier = nodes.new(type="ShaderNodeMixRGB")
                multiplier.name = "portrait_body_brightness"
                multiplier.label = "Portrait body brightness"
                multiplier.blend_type = "MULTIPLY"
                multiplier.inputs[0].default_value = 1.0
                outgoing = list(texture.outputs["Color"].links)
                for link in outgoing:
                    destination = link.to_socket
                    links.remove(link)
                    links.new(multiplier.outputs["Color"], destination)
                links.new(texture.outputs["Color"], multiplier.inputs[1])
            multiplier.inputs[2].default_value = (factor, factor, factor, 1.0)
            adjusted += 1
    if adjusted == 0:
        raise RuntimeError(f"{model_root.name} has no body materials to adjust")
    return adjusted


def apply_texture_stage(
    bitmaps,
    game_files,
    available,
    stage,
    texture_suffixes=(),
    texture_overrides=None,
    require_change=True,
):
    changed = 0
    replacements = {}
    overrides = {
        str(source).casefold(): str(target)
        for source, target in (texture_overrides or {}).items()
    }
    for obj, original in bitmaps.items():
        target = original
        if stage != "normal":
            override = overrides.get(original.casefold())
            if override:
                candidate = available.get(override.casefold())
                if candidate is None:
                    raise RuntimeError(
                        f"Configured {stage.upper()} texture does not exist: {override}"
                    )
            else:
                candidate = next(
                    (
                        available[name.casefold()]
                        for name in (original + suffix for suffix in texture_suffixes)
                        if name.casefold() in available
                    ),
                    None,
                )
            if candidate:
                target = candidate.stem
                changed += 1
                replacements[original] = target
        if obj.kb.bitmap != target:
            obj.kb.bitmap = target
            rebuild_object_materials(obj, [str(game_files)], [])
    if stage != "normal" and changed == 0 and require_change:
        raise RuntimeError(
            f"No {stage.upper()} texture was found for the selected model in {game_files}"
        )
    if replacements:
        print(
            f"{stage.upper()} texture mappings: "
            + ", ".join(
                f"{source}->{target}" for source, target in sorted(replacements.items())
            ),
            flush=True,
        )
    return changed


def texture_for_stage(original, available, stage, recipe, strict=True):
    overrides = {
        str(source).casefold(): str(target)
        for source, target in recipe.get("texture_overrides", {}).items()
    }
    override = overrides.get(original.casefold())
    if override:
        candidate = available.get(override.casefold())
        if candidate is None:
            if not strict:
                return None
            raise RuntimeError(
                f"Configured {stage.upper()} texture does not exist: {override}"
            )
        return candidate
    return next(
        (
            available[name.casefold()]
            for name in (
                original + suffix
                for suffix in recipe.get("texture_suffixes", [stage])
            )
            if name.casefold() in available
        ),
        None,
    )


def generate_intermediate_textures(
    bitmaps,
    game_files,
    render_dir,
    available,
    recipes,
    magick,
    force=False,
    skip_missing=False,
):
    magick = Path(magick) if magick else None
    if magick is None or not magick.is_file():
        raise RuntimeError("Five-portrait mode requires the bundled ImageMagick executable")
    recipe_by_stage = {recipe["stage"]: recipe for recipe in recipes}
    staging = Path(render_dir) / "generated-textures"
    generated = {"d0": 0, "d3": 0}
    replaced = {"d0": 0, "d3": 0}
    usable = {"d0": 0, "d3": 0}

    transitions = []
    for original in sorted(set(bitmaps.values()), key=str.casefold):
        normal = available.get(original.casefold())
        d1 = texture_for_stage(
            original, available, "d1", recipe_by_stage["d1"], strict=not skip_missing
        )
        d2 = texture_for_stage(
            original, available, "d2", recipe_by_stage["d2"], strict=not skip_missing
        )
        if normal is not None and d1 is not None and d2 is not None:
            transitions.append((original, normal, d1, d2))

    if not transitions:
        if skip_missing:
            print("Skipped D0/D3: no complete normal/D1/D2 texture chain", flush=True)
            return False
        raise RuntimeError("Could not find a complete normal/D1/D2 head texture chain")

    for original, normal, d1, d2 in transitions:
        for stage, left, right in (("d0", normal, d1), ("d3", d1, d2)):
            target_key = (original + stage).casefold()
            existing = available.get(target_key)
            if existing is not None and not force:
                usable[stage] += 1
                continue

            staging.mkdir(parents=True, exist_ok=True)
            target = existing or Path(game_files) / f"{original}{stage.upper()}.tga"
            staged = staging / target.name
            size = subprocess.run(
                [str(magick), "identify", "-format", "%wx%h", str(right)],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            if "x" not in size:
                raise RuntimeError(f"Could not read texture dimensions from {right}")
            command = [
                str(magick),
                str(left),
                "-resize",
                f"{size}!",
                str(right),
                "-define",
                "compose:args=50,50",
                "-compose",
                "blend",
                "-composite",
                "-compress",
                "None",
            ]
            if target.suffix.casefold() == ".tga":
                command += ["-define", "tga:bits-per-pixel=32"]
            command.append(str(staged))
            subprocess.run(command, check=True)
            staged.replace(target)
            available[target_key] = target
            if existing is None:
                generated[stage] += 1
            else:
                replaced[stage] += 1
            usable[stage] += 1
            print(
                f"{'Replaced' if existing else 'Generated'} {stage.upper()} head texture: "
                f"{left.name} + {right.name} -> {target.name}",
                flush=True,
            )

    for stage in ("d0", "d3"):
        if usable[stage] == 0:
            raise RuntimeError(
                f"Could not generate or find a {stage.upper()} head texture"
            )
    print(
        "Intermediate head textures ready: "
        f"D0={usable['d0']} ({generated['d0']} generated, {replaced['d0']} replaced), "
        f"D3={usable['d3']} ({generated['d3']} generated, {replaced['d3']} replaced)",
        flush=True,
    )
    return True


def main(
    model_roots,
    model_path,
    game_files,
    render_dir,
    pose_data,
    pose,
    requested_frame,
    camera_x,
    camera_roll_degrees,
    lens_shift_y,
    orthographic_scale,
    front_light_power,
    world_color,
    size,
    output_mode,
    stage_plan,
    body_root=None,
    body_brightness=0.5,
    magick=None,
    regenerate_intermediate_textures_only=False,
):
    game_files = Path(game_files)
    render_dir = Path(render_dir)
    scene = bpy.context.scene
    if scene.camera is None:
        raise RuntimeError("The portrait scene has no active camera")
    if not -180.0 <= camera_roll_degrees <= 180.0:
        raise RuntimeError(
            "Camera roll must be from -180 through 180 degrees: "
            f"{camera_roll_degrees}"
        )
    if not -10.0 <= lens_shift_y <= 10.0:
        raise RuntimeError(
            f"Lens shift Y must be from -10.0 through 10.0: {lens_shift_y}"
        )
    if not 0.0 < orthographic_scale <= 1000.0:
        raise RuntimeError(
            "Orthographic scale must be greater than 0 and no more than 1000: "
            f"{orthographic_scale}"
        )
    if scene.camera.data.type != "ORTHO":
        raise RuntimeError("The portrait camera must be orthographic")
    original_camera_rotation = scene.camera.rotation_euler.to_quaternion()
    eye_helper = runpy.run_path(
        str(Path(__file__).with_name("lock_kotor_eyes.py")),
        run_name="portrait_eye_helper",
    )
    if not 0.0 <= front_light_power <= 10000.0:
        raise RuntimeError(
            f"Front light power must be from 0 through 10000: {front_light_power}"
        )
    front_light = scene.objects.get("light_front")
    if front_light is None or front_light.type != "LIGHT":
        raise RuntimeError("The portrait scene has no light_front light")
    front_light.data.energy = front_light_power
    print(f"Default front light power: {front_light_power:g}", flush=True)
    set_world_color(scene, world_color)

    meshes = [obj for obj in bpy.data.objects if obj.type == "MESH"]
    for obj in meshes:
        obj.cycles.shadow_terminator_geometry_offset = 1.0
        obj.cycles.shadow_terminator_offset = 0.10
    print(
        f"Shadow terminator offsets: geometry=1.0, shading=0.10 "
        f"on {len(meshes)} meshes",
        flush=True,
    )

    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.film_transparent = True
    scene.render.resolution_x = size
    scene.render.resolution_y = size
    scene.render.resolution_percentage = 100

    expected_stages = {
        "single": ("normal",),
        "alignment_set": ("normal", "d1", "d2"),
        "alignment_five": ("normal", "d0", "d1", "d3", "d2"),
        "alignment_k1": ("normal", "d1", "d2", "d3", "d"),
    }[output_mode]
    with Path(stage_plan).open(encoding="utf-8-sig") as stream:
        recipes = json.load(stream)
    if not isinstance(recipes, list):
        raise RuntimeError("Stage plan must be a JSON array")
    received_stages = [recipe.get("stage") for recipe in recipes]
    if received_stages != list(expected_stages):
        raise RuntimeError(
            f"Stage plan must contain {expected_stages}; received {received_stages}"
        )
    available = texture_files(game_files)
    if body_root is None:
        head_bitmaps = capture_bitmaps(model_roots)
        body_bitmaps = {}
    else:
        head_bitmaps = capture_bitmaps((model_roots[0],))
        body_bitmaps = capture_bitmaps((body_root,))
    if not head_bitmaps:
        raise RuntimeError(f"{model_path.name} has no textured render meshes")
    if output_mode == "alignment_five":
        generated_transitions = generate_intermediate_textures(
            head_bitmaps,
            game_files,
            render_dir,
            available,
            recipes,
            magick,
            force=regenerate_intermediate_textures_only,
            skip_missing=regenerate_intermediate_textures_only,
        )
        if regenerate_intermediate_textures_only:
            return generated_transitions

    for stage_index, recipe in enumerate(recipes):
        stage = recipe["stage"]
        stage_pose = recipe.get("pose", pose)
        stage_frame = timeline_frame(
            pose_data, stage_pose, recipe.get("frame", requested_frame)
        )
        stage_camera_x = float(recipe.get("camera_x", camera_x))
        stage_camera_roll_degrees = float(
            recipe.get("camera_roll_degrees", camera_roll_degrees)
        )
        stage_lens_shift_y = float(recipe.get("lens_shift_y", lens_shift_y))
        stage_orthographic_scale = float(
            recipe.get("orthographic_scale", orthographic_scale)
        )
        stage_body_brightness_factor = float(
            recipe.get("body_brightness_factor", 1.0)
        )
        stage_model_brightness_factor = float(
            recipe.get("model_brightness_factor", 1.0)
        )
        stage_front_light_power = float(
            recipe.get("front_light_power", front_light_power)
        )
        if not -10.0 <= stage_lens_shift_y <= 10.0:
            raise RuntimeError(
                f"Lens shift Y must be from -10.0 through 10.0: "
                f"{stage_lens_shift_y}"
            )
        if not -180.0 <= stage_camera_roll_degrees <= 180.0:
            raise RuntimeError(
                "Camera roll must be from -180 through 180 degrees: "
                f"{stage_camera_roll_degrees}"
            )
        if not 0.0 < stage_orthographic_scale <= 1000.0:
            raise RuntimeError(
                "Orthographic scale must be greater than 0 and no more than 1000: "
                f"{stage_orthographic_scale}"
            )
        if not 0.0 < stage_body_brightness_factor <= 1.0:
            raise RuntimeError(
                "Body brightness factor must be greater than 0 and no more than 1: "
                f"{stage_body_brightness_factor}"
            )
        if not 0.0 < stage_model_brightness_factor <= 1.0:
            raise RuntimeError(
                "Model brightness factor must be greater than 0 and no more than 1: "
                f"{stage_model_brightness_factor}"
            )
        if not 0.0 <= stage_front_light_power <= 10000.0:
            raise RuntimeError(
                "Front light power must be from 0 through 10000: "
                f"{stage_front_light_power}"
            )
        texture_suffixes = recipe.get("texture_suffixes", [stage])
        texture_overrides = recipe.get("texture_overrides", {})
        scene.frame_set(stage_frame)
        close_head_mouth()
        scene.camera.location.x = stage_camera_x
        camera_tracks = [
            constraint
            for constraint in scene.camera.constraints
            if constraint.type == "DAMPED_TRACK" and constraint.target is not None
        ]
        if len(camera_tracks) != 1:
            raise RuntimeError(
                f"Expected one tracked portrait camera constraint; found {len(camera_tracks)}"
            )
        camera_track = camera_tracks[0]
        scene.camera.rotation_mode = "QUATERNION"
        scene.camera.rotation_quaternion = original_camera_rotation
        camera_track.influence = 1.0
        bpy.context.view_layer.update()
        tracked_rotation = scene.camera.evaluated_get(
            bpy.context.evaluated_depsgraph_get()
        ).matrix_world.to_quaternion()
        camera_track.influence = 0.0
        scene.camera.rotation_mode = "QUATERNION"
        scene.camera.rotation_quaternion = tracked_rotation @ Quaternion(
            (0.0, 0.0, 1.0), math.radians(-stage_camera_roll_degrees)
        )
        eye_helper["update_parallel_eye_targets"](
            scene.camera, required=False
        )
        scene.camera.data.shift_y = stage_lens_shift_y
        scene.camera.data.ortho_scale = stage_orthographic_scale
        front_light.data.energy = stage_front_light_power
        front_light.location.x = (
            stage_camera_x - 0.50 if stage_camera_x > 0.0 else stage_camera_x + 0.50
        )
        if stage_index == 0 and body_root is not None:
            face_fixer_path = Path(__file__).with_name(
                "flip_faces_toward_camera.py"
            )
            if not face_fixer_path.is_file():
                raise RuntimeError(f"Face fixer does not exist: {face_fixer_path}")
            face_fixer = runpy.run_path(
                str(face_fixer_path), run_name="portrait_face_fixer"
            )
            head_meshes = [
                obj for obj in descendants(model_roots[0]) if obj.type == "MESH"
            ]
            face_fixer["main"](mesh_objects=head_meshes)
        changed = apply_texture_stage(
            head_bitmaps,
            game_files,
            available,
            stage,
            texture_suffixes,
            texture_overrides,
        )
        if body_bitmaps:
            changed += apply_texture_stage(
                body_bitmaps,
                game_files,
                available,
                recipe.get("body_texture_stage", stage),
                recipe.get("body_texture_suffixes", texture_suffixes),
                recipe.get("body_texture_overrides", texture_overrides),
                require_change=False,
            )
        adjusted_materials = 0
        effective_body_brightness = body_brightness * stage_body_brightness_factor
        if body_root is not None:
            adjusted_materials = apply_model_brightness(
                body_root, effective_body_brightness
            )
        adjusted_model_materials = apply_model_brightness(
            model_roots[0], stage_model_brightness_factor
        )
        output_path = render_dir / f"{stage}.png"
        scene.render.filepath = str(output_path)
        bpy.ops.render.render(write_still=True)
        if not output_path.is_file():
            raise RuntimeError(f"Blender did not create {output_path}")
        print(
            f"Rendered {stage}: pose={stage_pose}, frame={stage_frame}, "
            f"camera_x={stage_camera_x}, camera_roll_degrees={stage_camera_roll_degrees}, "
            f"front_light_power={stage_front_light_power}, "
            f"front_light_x={front_light.location.x}, "
            f"lens_shift_y={stage_lens_shift_y}, "
            f"orthographic_scale={stage_orthographic_scale}, "
            f"size={size}x{size}, "
            f"texture_swaps={changed}, body_brightness={effective_body_brightness}, "
            f"body_materials_dimmed={adjusted_materials}, "
            f"model_brightness={stage_model_brightness_factor}, "
            f"model_materials_dimmed={adjusted_model_materials}, "
            f"output={output_path}",
            flush=True,
        )

    apply_texture_stage(head_bitmaps, game_files, available, "normal")
    if body_bitmaps:
        apply_texture_stage(body_bitmaps, game_files, available, "normal")
