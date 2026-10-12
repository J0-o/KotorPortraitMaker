"""Prepare the K1 P_T3M3 model for portrait rendering."""

import runpy
from pathlib import Path


common = runpy.run_path(
    str(Path(__file__).resolve().with_name("prepare_kotor_full_model.py")),
    run_name="kotor_full_model_common",
)
common["main"](
    expected_model="P_T3M3",
    location=(0.0, 0.0, -0.35),
    scale=0.5,
    camera_target_name="Head",
)
