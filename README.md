# KOTOR Portrait Maker

## Requirements

- [Blender 3.3 LTS](https://www.blender.org/download/releases/3-3/)
- [KotorBlender add-on](https://deadlystream.com/files/file/1853-kotorblender-for-blender-36-and-42/)

## Usage

- Download Blender 3.3 LTS and install the KotorBlender add-on.
- Place your model and texture files in `game_files/`.
- Run `Run-Portrait-Maker.bat`.
- Select the location of your Blender executable.
- Choose a head model from the list, then generate the portraits.

## Game files

Place all required resources directly in `game_files/`:

- The selected `.mdl` and its same-name `.mdx`
- Every referenced `.tga` texture and any optional `.txi` files
- For PF/PM player heads, an MDL/MDX body such as the default `N_CommM` or `N_CommF`, or a user-selected alternative
- For companion heads ending in `H`, the matching `BB` body—for example, `P_HandmaidenH` uses `P_HandmaidenBB`
