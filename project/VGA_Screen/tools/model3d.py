"""Bit-accurate Python model of ball3d.vhd / tetra3d.vhd for checking the math.

Usage (from the project root):
    python tools/model3d.py [angle ...]   -> sim_out/model_<obj>_<angle>.png

Mirrors the hardware integer pipeline (same ROM values, shifts and thresholds),
so a mismatch with the xsim frame points at the VHDL, not the geometry.
"""

import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_rom  # noqa: E402

OUT = Path(__file__).resolve().parent.parent / "sim_out"
W, H = 640, 480

# Thresholds in Q.10, must match ball3d.vhd
LINE_T = 28
LAT_T = 20
RIM_Q = 1024 - 40
CAP_V = 940
STRIPE_LO, STRIPE_HI = 600, 700
LACE_U, LACE_W, STITCH_W = 380, 30, 90
EDGE_T = 3 * gen_rom.E_SCALE

GORE_COLORS = {0b011: (15, 0, 0), 0b001: (15, 15, 0), 0b000: (0, 15, 0),
               0b100: (0, 15, 15), 0b110: (0, 0, 15), 0b111: (15, 0, 15)}
FACE_COLORS = [(15, 0, 0), (0, 15, 0), (0, 0, 15), (15, 15, 0)]
SQRT = [round(1023 * (((i + 1) / 1024) ** 0.5)) for i in range(1024)]


def shade_color(color, shade):
    return tuple((c * (shade + 1)) >> 4 for c in color)


def ball_pixel(p, sphere, solid, X, Y):
    qsum = p["QA"] * X * X + p["QB"] * X * Y + p["QC"] * Y * Y
    if not 0 <= qsum < 2 ** 29:
        return (0, 0, 0)
    qf = qsum >> 19
    s = SQRT[1023 - qf]
    z = ((p["ZX"] * X + p["ZY"] * Y) >> 14) + ((p["H"] * s) >> 10)
    n = p["N"]
    u = (n[0] * X + n[1] * Y + n[2] * z) >> 10
    v = (n[3] * X + n[4] * Y + n[5] * z) >> 10
    w = (n[6] * X + n[7] * Y + n[8] * z) >> 10
    dot = (u * p["L"][0] + v * p["L"][1] + w * p["L"][2]) >> 10
    shade = min(15, 4 + ((max(dot, 0) * 11) >> 10))

    # Sphere spins about v, rugby ball's long axis is u: meridians live in the other two coords
    axis, pa, qa = (v, u, w) if sphere else (u, v, w)
    d0 = qa
    d60 = (qa >> 1) - ((pa * 887) >> 10)
    d120 = -(qa >> 1) - ((pa * 887) >> 10)

    if not solid:
        on_line = (abs(d0) < LINE_T or abs(d60) < LINE_T or abs(d120) < LINE_T
                   or abs(axis) < LAT_T or abs(abs(axis) - 512) < LAT_T or qf >= RIM_Q)
        return (15, 15, 15) if on_line else (0, 0, 0)

    if sphere:
        if abs(v) > CAP_V:
            base = (15, 15, 15)
        else:
            code = (d0 < 0) << 2 | (d60 < 0) << 1 | (d120 < 0)
            base = GORE_COLORS.get(code, (15, 15, 15))
    else:
        au = abs(u)
        lace = v > 0 and au < LACE_U and (abs(w) < LACE_W or (abs(w) < STITCH_W and (u & 127) < 32))
        if STRIPE_LO <= au < STRIPE_HI or lace:
            base = (15, 15, 15)
        else:
            base = (10, 5, 2)
    return shade_color(base, shade)


def tetra_pixel(p, solid, X, Y):
    for f in range(4):
        e = [p["A"][3 * f + i] * X + p["B"][3 * f + i] * Y + p["C"][3 * f + i] for i in range(3)]
        if min(e) >= 0:
            if not solid:
                return (15, 15, 15) if min(e) < EDGE_T else (0, 0, 0)
            return shade_color(FACE_COLORS[f], p["SHADE"][f])
    return (0, 0, 0)


def render(name, fn):
    image = Image.new("RGB", (W, H))
    px = image.load()
    for y in range(H):
        for x in range(W):
            px[x, y] = tuple(c * 17 for c in fn(x - W // 2, H // 2 - y))
    image.save(OUT / f"model_{name}.png")
    print(f"model_{name}.png")


def main():
    angles = [int(a) for a in sys.argv[1:]] or [0, 40]
    OUT.mkdir(exist_ok=True)
    for k in angles:
        t = 2 * gen_rom.math.pi * k / gen_rom.ANGLES
        sph = gen_rom.ball_params(gen_rom.sphere_rotation(t), (gen_rom.SPHERE_R,) * 3)
        rug = gen_rom.ball_params(gen_rom.rugby_rotation(t), gen_rom.RUGBY_AXES)
        tet = gen_rom.tetra_params(gen_rom.tetra_rotation(t))
        for solid in (True, False):
            tag = f"{k}_{'solid' if solid else 'wire'}"
            render(f"sphere_{tag}", lambda X, Y: ball_pixel(sph, True, solid, X, Y))
            render(f"rugby_{tag}", lambda X, Y: ball_pixel(rug, False, solid, X, Y))
            render(f"tetra_{tag}", lambda X, Y: tetra_pixel(tet, solid, X, Y))


if __name__ == "__main__":
    main()
