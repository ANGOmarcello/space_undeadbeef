# Title scenery extension

`title-sky.png` is new scenery derived with image editing from the supplied
original title artwork. It is intentionally simple: the original muted peach
sky continues to the right, finishing the existing cloud without adding a new
cloud bank. It is not a recovered historical asset.

The renderer keeps the original title, ship and logo in their original 480×320
composition. It matches the added scenery to that image's edge colours. A baked
one-pixel dark border is normalized in the rendering copy, and edge texels are
extruded into texture padding to prevent a dark sampling seam. Prepared originals
under `Resources/Original` remain unchanged.
