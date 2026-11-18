# Art tools

Scripts that regenerate the texture files in the addon folder. You only need these to change the art;
the finished `.tga` files are already in the repo. Run from the repository root.

| Script | Writes | Needs |
|---|---|---|
| `make_vignette.py` | `haze_vignette.tga` (minimap haze, clear centre) | Python 3 only |
| `make_ring_mask.py` | `ring_mask.tga` (keeps the minimap cloud layer round) | pillow, numpy |
| `make_haze_tile.py` | `haze_tile.tga` (seamless cloud tile, pattern in alpha) | pillow, numpy |
| `make_puff.py` | `puff.tga` (soft puff sprite) from `art/puff_source.png` | pillow, numpy |

```
pip install pillow numpy
python tools/make_haze_tile.py
```

Texture files must be white RGBA with the shape in the alpha channel, because the addon tints them per
weather type. New or changed textures need a full game restart; `/reload` does not pick them up.
