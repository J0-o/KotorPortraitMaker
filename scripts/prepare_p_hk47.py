"""Prepare an imported P_HK47 model for portrait rendering."""

import runpy
from pathlib import Path

from io_scene_kotor.scene.material import rebuild_object_materials


# Load the shared complete-model preparation functions without running defaults.
COMMON_SCRIPT = Path(__file__).resolve().with_name("prepare_kotor_full_model.py")
common = runpy.run_path(str(COMMON_SCRIPT), run_name="kotor_full_model_common")
prepare_model = common["main"]
selected_model_root = common["selected_model_root"]
descendants = common["descendants"]
base_name = common["base_name"]

# Point KotorBlender at HK-47's appearance texture, which his MDL does not name.
TEXTURE_NAME = "p_hk47_01"
TEXTURE_DIRECTORY = Path(
    globals().get("GAME_FILES_DIRECTORY", Path(__file__).resolve().parent.parent / "game_files")
)
root = selected_model_root()
if base_name(root.name).casefold() != "p_hk47":
    raise RuntimeError(f"This script requires P_HK47; selected {root.name}")

# Replace only HK-47's empty placeholder materials with the missing texture.
textured_meshes = 0
for obj in descendants(root):
    if obj.type != "MESH" or obj.kb.meshtype == "EMITTER" or obj.kb.bitmap:
        continue
    obj.kb.bitmap = TEXTURE_NAME
    rebuild_object_materials(obj, [str(TEXTURE_DIRECTORY)], [])
    textured_meshes += 1

print(f"Assigned {TEXTURE_NAME}.tga to {textured_meshes} HK-47 meshes")

# Apply HK-47's tested transform and neck camera target.
prepare_model(
    expected_model="P_HK47",
    location=(0.0, 0.0, -1.0),
    scale=0.65,
    camera_target_name="Neck",
)
