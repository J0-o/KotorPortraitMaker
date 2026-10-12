"""Import and render one player head inside an isolated Blender process."""

import argparse
import re
import runpy
import sys
from pathlib import Path

import bpy


BLENDER_SUFFIX = re.compile(r"\.\d{3}$")


# Read arguments placed after Blender's double-dash separator.
def parse_arguments():
    arguments = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--game-files", required=True)
    parser.add_argument("--render-dir", required=True)
    parser.add_argument("--pose-data", required=True)
    parser.add_argument("--pose", required=True)
    parser.add_argument("--frame", type=int)
    parser.add_argument("--camera-x", required=True, type=float)
    parser.add_argument("--camera-roll-degrees", required=True, type=float)
    parser.add_argument("--lens-shift-y", required=True, type=float)
    parser.add_argument("--orthographic-scale", required=True, type=float)
    parser.add_argument("--front-light-power", default=10.0, type=float)
    parser.add_argument("--world-color")
    parser.add_argument("--size", required=True, type=int, choices=(128, 256, 512))
    parser.add_argument(
        "--output-mode",
        required=True,
        choices=("single", "alignment_set", "alignment_five", "alignment_k1"),
    )
    parser.add_argument("--stage-plan", required=True)
    parser.add_argument("--body-model")
    parser.add_argument("--body-texture")
    parser.add_argument("--body-brightness", default=0.5, type=float)
    parser.add_argument("--magick")
    parser.add_argument(
        "--regenerate-intermediate-textures-only", action="store_true"
    )
    parser.add_argument("--animation-model", default="S_Female03")
    parser.add_argument("--import-script", required=True)
    parser.add_argument("--render-script", required=True)
    return parser.parse_args(arguments)


# Remove a numeric suffix Blender may add to an imported object name.
def base_name(name):
    return BLENDER_SUFFIX.sub("", name)


# Import one head model and select its newly created MDL root.
def import_and_select_head(model_path):
    objects_before = set(bpy.data.objects)
    result = bpy.ops.kb.mdlimport(
        filepath=str(model_path),
        import_geometry=True,
        import_animations=False,
        import_walkmeshes=False,
        build_materials=True,
        build_armature=False,
    )
    if result != {"FINISHED"}:
        raise RuntimeError(f"KotorBlender failed to import {model_path.name}: {result}")

    matches = [
        obj
        for obj in set(bpy.data.objects) - objects_before
        if obj.type == "EMPTY"
        and base_name(obj.name).casefold() == model_path.stem.casefold()
    ]
    if len(matches) != 1:
        names = ", ".join(obj.name for obj in matches) or "none"
        raise RuntimeError(
            f"Could not identify the imported root for {model_path.name}; "
            f"matches: {names}"
        )

    bpy.ops.object.select_all(action="DESELECT")
    root = matches[0]
    root.hide_set(False)
    root.select_set(True)
    bpy.context.view_layer.objects.active = root
    return root


# Run the existing preparation and render scripts for one player head.
def main():
    args = parse_arguments()
    model_path = Path(args.model).resolve()
    game_files = Path(args.game_files).resolve()
    render_dir = Path(args.render_dir).resolve()
    pose_data = Path(args.pose_data).resolve()
    import_script = Path(args.import_script).resolve()
    render_script = Path(args.render_script).resolve()
    stage_plan = Path(args.stage_plan).resolve()

    for path in (model_path, pose_data, import_script, render_script, stage_plan):
        if not path.is_file():
            raise RuntimeError(f"Required file does not exist: {path}")
    if not game_files.is_dir():
        raise RuntimeError(f"Game-files directory does not exist: {game_files}")
    if not render_dir.is_dir():
        raise RuntimeError(f"Render directory does not exist: {render_dir}")
    if not model_path.with_suffix(".mdx").is_file():
        raise RuntimeError(f"Companion MDX does not exist for {model_path.name}")
    folded_name = model_path.stem.casefold()
    if not (folded_name.startswith(("pf", "pm")) or folded_name.endswith("h")):
        raise RuntimeError(f"Not a supported player or companion head: {model_path.name}")

    root = import_and_select_head(model_path)
    print(f"Imported {root.name}; preparing portrait scene", flush=True)
    importer = runpy.run_path(str(import_script), run_name="kotor_head_import")
    model_roots = importer["main"](
        model_dir=game_files,
        body_model=args.body_model,
        animation_model=args.animation_model,
    )
    print(f"Prepared {root.name}; rendering portraits", flush=True)
    renderer = runpy.run_path(str(render_script), run_name="portrait_renderer")
    if args.body_texture:
        renderer["apply_model_texture"](
            model_roots[1], game_files, args.body_texture
        )
    renderer["main"](
        model_roots=model_roots,
        model_path=model_path,
        game_files=game_files,
        render_dir=render_dir,
        pose_data=pose_data,
        pose=args.pose,
        requested_frame=args.frame,
        camera_x=args.camera_x,
        camera_roll_degrees=args.camera_roll_degrees,
        lens_shift_y=args.lens_shift_y,
        orthographic_scale=args.orthographic_scale,
        front_light_power=args.front_light_power,
        world_color=args.world_color,
        size=args.size,
        output_mode=args.output_mode,
        stage_plan=stage_plan,
        body_root=model_roots[1],
        body_brightness=args.body_brightness,
        magick=args.magick,
        regenerate_intermediate_textures_only=args.regenerate_intermediate_textures_only,
    )
    print(f"Completed {root.name}", flush=True)


if __name__ == "__main__":
    main()
