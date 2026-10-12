"""Prepare an imported P_Hanharr model for portrait rendering."""

import runpy
from pathlib import Path


# Load the shared complete-model preparation functions without running defaults.
COMMON_SCRIPT = Path(__file__).resolve().with_name("prepare_kotor_full_model.py")
prepare_model = runpy.run_path(
    str(COMMON_SCRIPT), run_name="kotor_full_model_common"
)["main"]


# Apply Hanharr's tested transform and camera target.
prepare_model(
    expected_model="P_Hanharr",
    location=(0.0, 0.0, -1.6),
    scale=0.8,
    camera_target_name="f_jaw_g",
)
