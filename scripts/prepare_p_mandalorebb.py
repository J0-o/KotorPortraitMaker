"""Prepare an imported P_MandaloreBB model for portrait rendering."""

import runpy
from pathlib import Path

import bpy


# Load the shared complete-model preparation functions without running defaults.
COMMON_SCRIPT = Path(__file__).resolve().with_name("prepare_kotor_full_model.py")
common = runpy.run_path(str(COMMON_SCRIPT), run_name="kotor_full_model_common")
prepare_model = common["main"]
select_only = common["select_only"]
base_name = common["base_name"]

# Find Mandalore's static model root without requiring a current selection.
roots = [
    obj
    for obj in bpy.context.scene.objects
    if obj.type == "EMPTY"
    and obj.parent is None
    and base_name(obj.name).casefold() == "p_mandalorebb"
]
if len(roots) != 1:
    raise RuntimeError(f"Expected one P_MandaloreBB root; found {len(roots)}")
root = roots[0]

# Apply Mandalore's tested transform and head-hook camera target.
select_only(root)
prepare_model(
    expected_model="P_MandaloreBB",
    location=(0.0, 0.0, -0.9),
    scale=0.65,
    camera_target_name="headhook",
    require_animations=False,
)
