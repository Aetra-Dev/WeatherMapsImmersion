"""Writes ring_mask.tga: a circle mask with a clear centre, used to keep the minimap cloud layer round
and off the player arrow. Needs pillow and numpy. Usage: python tools/make_ring_mask.py"""
from pathlib import Path
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
N = 256
yy, xx = np.mgrid[0:N, 0:N]
r = np.hypot(xx + 0.5 - N / 2, yy + 0.5 - N / 2) / (N / 2)
def sm(x): c = np.clip(x, 0, 1); return c * c * (3 - 2 * c)
a = sm((r - 0.28) / 0.42) * (1 - sm((r - 0.95) / 0.05))
o = np.zeros((N, N, 4), np.uint8); o[..., :3] = 255; o[..., 3] = (a * 255).astype(np.uint8)
Image.fromarray(o, "RGBA").save(ROOT / "ring_mask.tga")
print("wrote", ROOT / "ring_mask.tga")
