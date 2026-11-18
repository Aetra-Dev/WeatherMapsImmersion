"""Writes haze_tile.tga: a seamless 256x256 cloud noise tile. White RGB, the pattern is in the alpha channel.
Tileable because it is built from periodic FFT noise. Needs pillow and numpy.
Usage: python tools/make_haze_tile.py"""
from pathlib import Path
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
N = 256
rng = np.random.default_rng(7)
def smooth(x): x = np.clip(x, 0, 1); return x * x * (3 - 2 * x)
fx = np.fft.fftfreq(N)[:, None]; fy = np.fft.fftfreq(N)[None, :]
f = np.hypot(fx, fy); f[0, 0] = 1
def noise(beta):
    ph = np.exp(2j * np.pi * rng.random((N, N)))
    n = np.fft.ifft2(ph * f ** (-beta / 2) * (f > 0)).real
    return (n - n.mean()) / n.std()
base = noise(4.2) * 0.8 + noise(3.4) * 0.4          # large masses plus mid wisps
wisp = 1 - np.abs(noise(3.6)); wisp = (wisp - wisp.mean()) / wisp.std()   # ridged filaments
s = base + 0.18 * wisp
lo, hi = np.percentile(s, [22, 97])
al = smooth((s - lo) / (hi - lo)) * 0.85
out = np.zeros((N, N, 4), np.uint8); out[..., :3] = 255; out[..., 3] = (al * 255).astype(np.uint8)
Image.fromarray(out, "RGBA").save(ROOT / "haze_tile.tga")
print("wrote", ROOT / "haze_tile.tga")
