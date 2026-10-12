"""Prepare an imported C_SenBall model for portrait rendering."""

import runpy
from pathlib import Path


# Load the shared complete-model preparation functions without running defaults.
COMMON_SCRIPT = Path(__file__).resolve().with_name("prepare_kotor_full_model.py")
prepare_model = runpy.run_path(
    str(COMMON_SCRIPT), run_name="kotor_full_model_common"
)["main"]


# Apply the sensor ball's tested transform and root-dummy camera target.
prepare_model(
    expected_model="C_SenBall",
    location=(0.0, 0.0, -1.2),
    scale=0.8,
    camera_target_name="rootdummy",
)
