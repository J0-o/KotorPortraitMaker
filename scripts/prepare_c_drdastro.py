"""Prepare the C_DrdAstro protocol-droid model for portrait rendering."""

import runpy
from pathlib import Path


# Load the shared complete-model preparation functions without running defaults.
COMMON_SCRIPT = Path(__file__).resolve().with_name("prepare_kotor_full_model.py")
prepare_model = runpy.run_path(
    str(COMMON_SCRIPT), run_name="kotor_full_model_common"
)["main"]

# Apply the same transform and camera target used by T3-M4.
prepare_model(
    expected_model="C_DrdAstro",
    location=(0.0, 0.0, -0.35),
    scale=0.5,
    camera_target_name="Head",
)
