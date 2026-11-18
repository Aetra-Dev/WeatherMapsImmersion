"""Builds puff.tga (128x128, white with soft alpha) from art/puff_source.png: cleans the edge, forces
white RGB so the addon can tint it, and fades it out before the border. Needs pillow and numpy.
Usage: python tools/make_puff.py"""
from pathlib import Path
import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
def smooth(x): x = np.clip(x, 0, 1); return x * x * (3 - 2 * x)
a = np.array(Image.open(ROOT / "art" / "puff_source.png").convert("RGBA")).astype(np.float32) / 255
alpha = a[..., 3]; lum = a[..., :3].mean(-1)
body = alpha * (0.6 + 0.4 * lum / max(lum[alpha > 0.5].max(), 1e-6))
body = np.array(Image.fromarray((body * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(14)), dtype=np.float32) / 255
N = body.shape[0]; yy, xx = np.mgrid[0:N, 0:N]; r = np.hypot(xx - N / 2, yy - N / 2) / (N / 2)
body *= 1 - smooth((r - 0.55) / 0.35)
body = body / body.max() * 0.8
out = np.zeros((N, N, 4), np.uint8); out[..., :3] = 255; out[..., 3] = (body * 255).astype(np.uint8)
Image.fromarray(out, "RGBA").resize((128, 128), Image.LANCZOS).save(ROOT / "puff.tga")
print("wrote", ROOT / "puff.tga")
