"""Prepare an imported C_DrdProt model for portrait rendering."""

import runpy
from pathlib import Path


# Load the shared complete-model preparation functions without running defaults.
COMMON_SCRIPT = Path(__file__).resolve().with_name("prepare_kotor_full_model.py")
prepare_model = runpy.run_path(
    str(COMMON_SCRIPT), run_name="kotor_full_model_common"
)["main"]


# Apply the protocol droid's tested transform and head camera target.
prepare_model(
    expected_model="C_DrdProt",
    location=(0.0, 0.0, -1.1),
    scale=0.7,
    camera_target_name="Head",
)
