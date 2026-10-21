"""Generate the VHDL ROM packages used by the HW3 VGA design.

Usage (from the project root):
    python tools/gen_rom.py image     -> image_rom_pkg.vhd
    python tools/gen_rom.py rot3d     -> rot3d_rom_pkg.vhd
    python tools/gen_rom.py all

The generated .vhd files are committed so the Vivado project builds without Python.
"""

import math
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent

ANGLES = 256

# Fixed-point scales shared with ball3d.vhd / tetra3d.vhd
Q_SCALE = 2 ** 29   # silhouette quadratic coefficients; Q = 1.0 <-> 2^29 before the >> 19
Z_SCALE = 2 ** 14   # depth slopes zx, zy
N_SCALE = 2 ** 20   # view -> normalized object coords; result >> 10 gives Q.10
L_SCALE = 2 ** 10   # light direction in object space, Q.10
E_SCALE = 2 ** 14   # tetrahedron edge functions, value = signed distance in pixels

SPHERE_R = 150
RUGBY_AXES = (190, 115, 115)
TETRA_R = 175
LIGHT = (-0.45, 0.55, 0.70)

IMAGE_SRC = ROOT / "embed0008_HD.jpg"
IMAGE_SIZE = 480
IMAGE_STRIDE = 64  # words per row: 60 used, padded to 64 so the address is just row & word
PIXELS_PER_WORD = 8


def write_package(path, name, body_lines):
    header = [
        "-" * 82,
        f"-- Package Name: {name}",
        f"-- Description: 由 tools/gen_rom.py 產生, 不要手動修改",
        "-" * 82,
        "",
        "library IEEE;",
        "use IEEE.std_logic_1164.all;",
        "",
        f"package {name} is",
    ]
    path.write_text("\n".join(header + body_lines + [f"end {name};", ""]), encoding="utf-8")
    print(f"wrote {path.name}")


def gen_image():
    image = Image.open(IMAGE_SRC).convert("L").resize((IMAGE_SIZE, IMAGE_SIZE), Image.LANCZOS)
    pixels = image.load()

    words = []
    for row in range(IMAGE_SIZE):
        for word in range(IMAGE_STRIDE):
            value = 0
            for k in range(PIXELS_PER_WORD):
                col = word * PIXELS_PER_WORD + k
                level = round(pixels[col, row] * 15 / 255) if col < IMAGE_SIZE else 0
                value |= level << (4 * k)
            words.append(value)

    depth = len(words)
    body = [
        f"    -- {IMAGE_SIZE}x{IMAGE_SIZE} 4 bit 灰階, 每個 word 放同一列相鄰 8 個像素 (bit 4k+3..4k = 第 k 個)",
        f"    -- 位址 = row * {IMAGE_STRIDE} + col / 8",
        f"    constant IMAGE_DEPTH : integer := {depth};",
        "    type image_rom_type is array (0 to IMAGE_DEPTH - 1) of STD_LOGIC_VECTOR (31 downto 0);",
        "    constant IMAGE_DATA : image_rom_type := (",
    ]
    per_line = 8
    for i in range(0, depth, per_line):
        chunk = ", ".join(f'x"{w:08X}"' for w in words[i:i + per_line])
        tail = "," if i + per_line < depth else ");"
        body.append(f"        {chunk}{tail}")
    write_package(ROOT / "image_rom_pkg.vhd", "image_rom_pkg", body)


def rot_x(a):
    c, s = math.cos(a), math.sin(a)
    return [[1, 0, 0], [0, c, -s], [0, s, c]]


def rot_y(a):
    c, s = math.cos(a), math.sin(a)
    return [[c, 0, s], [0, 1, 0], [-s, 0, c]]


def rot_z(a):
    c, s = math.cos(a), math.sin(a)
    return [[c, -s, 0], [s, c, 0], [0, 0, 1]]


def matmul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]


def matvec(m, v):
    return [sum(m[i][k] * v[k] for k in range(3)) for i in range(3)]


def transpose(m):
    return [[m[j][i] for j in range(3)] for i in range(3)]


def normalize(v):
    n = math.sqrt(sum(c * c for c in v))
    return [c / n for c in v]


def cross(a, b):
    return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]


def sphere_rotation(t):
    # Tilt the spin axis toward the viewer so the pole cap and the gores both stay visible
    return matmul(rot_x(math.radians(25)), rot_y(t))


def rugby_rotation(t):
    # Spin about an axis perpendicular to the long axis: the silhouette alternates long/round
    return matmul(matmul(rot_x(math.radians(20)), rot_z(math.radians(12))), rot_y(t))


def tetra_rotation(t):
    # Pre-tilting the apex off the spin axis makes the bottom face swing into view too
    return matmul(matmul(rot_x(math.radians(30)), rot_y(t)), rot_z(math.radians(35)))


def ball_params(rotation, axes):
    """Per-frame constants for orthographic ray casting of an ellipsoid.

    View coords: X right, Y up, Z toward the viewer; p_view = R p_obj.
    The ellipsoid p^T M p <= 1 seen along Z has silhouette Q(X, Y) < 1 with
    Q = qa X^2 + qb XY + qc Y^2 (Schur complement of M), and front depth
    Z = zx X + zy Y + h sqrt(1 - Q).
    """
    d = [[1 / axes[0] ** 2, 0, 0], [0, 1 / axes[1] ** 2, 0], [0, 0, 1 / axes[2] ** 2]]
    m = matmul(matmul(rotation, d), transpose(rotation))
    qa = m[0][0] - m[0][2] ** 2 / m[2][2]
    qb = 2 * (m[0][1] - m[0][2] * m[1][2] / m[2][2])
    qc = m[1][1] - m[1][2] ** 2 / m[2][2]
    zx = -m[0][2] / m[2][2]
    zy = -m[1][2] / m[2][2]
    h = 1 / math.sqrt(m[2][2])
    inv_axes = [[1 / axes[0], 0, 0], [0, 1 / axes[1], 0], [0, 0, 1 / axes[2]]]
    n = matmul(inv_axes, transpose(rotation))
    light = matvec(transpose(rotation), normalize(LIGHT))
    return {
        "QA": round(qa * Q_SCALE),
        "QB": round(qb * Q_SCALE),
        "QC": round(qc * Q_SCALE),
        "ZX": round(zx * Z_SCALE),
        "ZY": round(zy * Z_SCALE),
        "H": round(h),
        "N": [round(n[i][j] * N_SCALE) for i in range(3) for j in range(3)],
        "L": [round(c * L_SCALE) for c in light],
    }


def tetra_params(rotation):
    k = 2 * math.sqrt(2) / 3
    verts = [[0, TETRA_R, 0]] + [
        [TETRA_R * k * math.cos(math.radians(a)), -TETRA_R / 3, TETRA_R * k * math.sin(math.radians(a))]
        for a in (90, 210, 330)
    ]
    faces = []
    for face in ((0, 1, 2), (0, 2, 3), (0, 3, 1), (1, 3, 2)):
        a, b, c = (verts[i] for i in face)
        normal = cross([b[i] - a[i] for i in range(3)], [c[i] - a[i] for i in range(3)])
        centroid = [(a[i] + b[i] + c[i]) / 3 for i in range(3)]
        faces.append(face if sum(normal[i] * centroid[i] for i in range(3)) > 0 else face[::-1])

    view = [matvec(rotation, v) for v in verts]
    light = normalize(LIGHT)
    ea, eb, ec, shade = [], [], [], []
    for face in faces:
        a, b, c = (view[i] for i in face)
        normal = normalize(cross([b[i] - a[i] for i in range(3)], [c[i] - a[i] for i in range(3)]))
        if normal[2] <= 0:
            # Back face: E = -1 everywhere, so no pixel is ever inside
            ea += [0, 0, 0]
            eb += [0, 0, 0]
            ec += [-1, -1, -1]
            shade.append(0)
            continue
        # Outward normal toward the viewer -> CCW on screen (Y up) -> inside is left of every edge
        for p, q in ((a, b), (b, c), (c, a)):
            dx, dy = q[0] - p[0], q[1] - p[1]
            length = math.hypot(dx, dy)
            ea.append(round(-dy / length * E_SCALE))
            eb.append(round(dx / length * E_SCALE))
            ec.append(round((dy * p[0] - dx * p[1]) / length * E_SCALE))
        lambert = max(0.0, sum(normal[i] * light[i] for i in range(3)))
        shade.append(min(15, round(5 + 10 * lambert)))
    return {"A": ea, "B": eb, "C": ec, "SHADE": shade}


def vhdl_int_array(name, type_name, rows):
    lines = [f"    constant {name} : {type_name} := ("]
    for i, row in enumerate(rows):
        tail = "," if i + 1 < len(rows) else ");"
        if isinstance(row, list):
            lines.append(f"        ({', '.join(str(v) for v in row)}){tail}")
        else:
            lines.append(f"        {row}{tail}")
    return lines


def gen_rot3d():
    angles = [2 * math.pi * k / ANGLES for k in range(ANGLES)]
    objects = {
        "SPH": [ball_params(sphere_rotation(t), (SPHERE_R,) * 3) for t in angles],
        "RUG": [ball_params(rugby_rotation(t), RUGBY_AXES) for t in angles],
    }
    tetra = [tetra_params(tetra_rotation(t)) for t in angles]

    body = [
        f"    -- 每個物體 {ANGLES} 個角度的每 frame 參數, 定點格式見 tools/gen_rom.py 開頭",
        "    type rom_type   is array (0 to 255) of integer;",
        "    type rom3_type  is array (0 to 255, 0 to 2) of integer;",
        "    type rom4_type  is array (0 to 255, 0 to 3) of integer;",
        "    type rom9_type  is array (0 to 255, 0 to 8) of integer;",
        "    type rom12_type is array (0 to 255, 0 to 11) of integer;",
        "    type sqrt_rom_type is array (0 to 1023) of integer;",
        "",
    ]
    for prefix, params in objects.items():
        for key in ("QA", "QB", "QC", "ZX", "ZY", "H"):
            body += vhdl_int_array(f"{prefix}_{key}", "rom_type", [p[key] for p in params])
        body += vhdl_int_array(f"{prefix}_N", "rom9_type", [p["N"] for p in params])
        body += vhdl_int_array(f"{prefix}_L", "rom3_type", [p["L"] for p in params])
    for key, type_name in (("A", "rom12_type"), ("B", "rom12_type"), ("C", "rom12_type"), ("SHADE", "rom4_type")):
        body += vhdl_int_array(f"TET_{key}", type_name, [p[key] for p in tetra])

    # Index i = 1023 - Q (Q.10); entry = sqrt(1 - Q) in Q.10
    sqrt_rows = [round(1023 * math.sqrt((i + 1) / 1024)) for i in range(1024)]
    packed = [", ".join(str(v) for v in sqrt_rows[i:i + 16]) for i in range(0, 1024, 16)]
    body.append("    constant SQRT_ROM : sqrt_rom_type := (")
    for i, line in enumerate(packed):
        body.append(f"        {line}{',' if i + 1 < len(packed) else ');'}")
    write_package(ROOT / "rot3d_rom_pkg.vhd", "rot3d_rom_pkg", body)

    for prefix, params in objects.items():
        for key in ("QA", "QB", "QC", "ZX", "ZY", "H"):
            values = [p[key] for p in params]
            print(f"  {prefix}_{key}: {min(values)} .. {max(values)}")
        flat_n = [v for p in params for v in p["N"]]
        print(f"  {prefix}_N: {min(flat_n)} .. {max(flat_n)}")
    flat_c = [v for p in tetra for v in p["C"]]
    print(f"  TET_C: {min(flat_c)} .. {max(flat_c)}")


def main():
    targets = sys.argv[1:] or ["all"]
    if "image" in targets or "all" in targets:
        gen_image()
    if "rot3d" in targets or "all" in targets:
        gen_rot3d()


if __name__ == "__main__":
    main()
