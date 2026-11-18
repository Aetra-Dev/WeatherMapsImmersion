"""Writes haze_vignette.tga: 256x256 white RGBA, alpha 0 in the centre ramping to 1 at the rim.
Pure standard library. Usage: python tools/make_vignette.py"""
import math, struct
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
N = 256
R0, R1 = 0.20, 0.62          # r = 1 at the edge midpoints
hdr = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, N, N, 32, 0x28)   # 32bpp, top-left origin
px = bytearray()
for y in range(N):
    for x in range(N):
        r = math.hypot((x + 0.5 - N / 2) / (N / 2), (y + 0.5 - N / 2) / (N / 2))
        t = min(1.0, max(0.0, (r - R0) / (R1 - R0)))
        px += bytes((255, 255, 255, int(round(t * t * (3 - 2 * t) * 255))))
out = ROOT / "haze_vignette.tga"
out.write_bytes(hdr + bytes(px))
print("wrote", out)
