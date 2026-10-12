"""Prepare an imported P_G0T0 model for portrait rendering."""

import runpy
from pathlib import Path


# Load the shared complete-model preparation functions without running defaults.
COMMON_SCRIPT = Path(__file__).resolve().with_name("prepare_kotor_full_model.py")
prepare_model = runpy.run_path(
    str(COMMON_SCRIPT), run_name="kotor_full_model_common"
)["main"]


# Apply G0-T0's tested transform and root-dummy camera target.
prepare_model(
    expected_model="P_G0T0",
    location=(0.0, 0.0, -0.35),
    scale=0.3,
    camera_target_name="rootdummy",
)
