"""Batch xsim runner for Pong_HDMI.

Usage (from the project root):
    python tools/sim.py compile
    python tools/sim.py game
    python tools/sim.py frame <name> [GENERIC=value ...]
    python tools/sim.py presets [name ...]
    python tools/sim.py sheet <name> ...

Outputs go to sim_out/:
  `game`   runs the self-checking pong_game_tb (2D and 3D rules) and turns its logs into
           pong2d_play.gif and pong3d_play.gif.
  `frame`  captures one full 1024x768 frame of pong_core into <name>.png.
  `presets` captures the named frame presets below (all of them by default).
The video timing and HDMI modules are reused from ../VGA_Screen, which was
verified on the board; this script compiles them from there.
"""

import os
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

VIVADO_BIN = Path("D:/Vivado/2026.1/Vivado/bin")
ROOT = Path(__file__).resolve().parent.parent
VGA = ROOT.parent / "VGA_Screen"
OUT = ROOT / "sim_out" / os.environ.get("SIM_OUT", "")

# Compile order matters: packages before the entities that use them
SOURCES = [
    VGA / "vga_pkg.vhd",
    VGA / "delay_line.vhd",
    VGA / "vga_timing.vhd",
    ROOT / "pong_pkg.vhd",
    ROOT / "pong2d_ctrl.vhd",
    ROOT / "pong2d_draw.vhd",
    ROOT / "pong3d_ctrl.vhd",
    ROOT / "pong3d_draw.vhd",
    ROOT / "pong_core.vhd",
    ROOT / "pong_frame_tb.vhd",
    ROOT / "pong_game_tb.vhd",
]

# Control bits follow pong_pkg: C=1, UP=2, DN=4, LT=8, RT=16, P2UP=32, P2DN=64.
# SW bits: 1 = 3D, 2 = two players, 4 = hard CPU. TICKS = game steps per captured frame.
PRESETS = {
    "2d_serve": dict(SW=0),
    "2d_rally": dict(SW=0, C_PRESSES=1, TICKS=40, SKIP=2),
    "2d_two_players": dict(SW=2, C_PRESSES=1, BTN=2 | 64, HOLD=2, TICKS=20, SKIP=1),
    "3d_serve": dict(SW=1),
    "3d_paddle_moved": dict(SW=1, BTN=2 | 8, HOLD=2, TICKS=10, SKIP=1),
    "3d_over_net": dict(SW=1, C_PRESSES=1, TICKS=8, SKIP=1),
    "3d_bounce": dict(SW=1, C_PRESSES=1, TICKS=12, SKIP=1),
    "3d_cpu_return": dict(SW=5, C_PRESSES=1, TICKS=30, SKIP=1),
}

GIF_SCALE = 4         # 1024x768 drawn at 256x192
GIF_STEP = 3          # every 3rd game frame at 50 ms = real-time playback of a 60 Hz game


def tool(name):
    return str(VIVADO_BIN / f"{name}.bat")


def run(cmd):
    # xsim only reports VHDL assertion errors in its log, not via the exit code
    result = subprocess.run(cmd, cwd=OUT, capture_output=True, text=True)
    log = result.stdout + result.stderr
    if result.returncode != 0 or "ERROR:" in log:
        print(log)
        sys.exit(f"command failed: {cmd if isinstance(cmd, str) else ' '.join(cmd)}")
    return log


def compile_sources():
    OUT.mkdir(parents=True, exist_ok=True)
    # Relative paths: xvhdl.bat breaks on the spaces in the absolute project path
    run([tool("xvhdl"), *[os.path.relpath(s, OUT) for s in SOURCES]])


def elaborate_and_run(top, generics):
    # xelab.bat splits unquoted KEY=VALUE at '=', so the command line is built by hand
    cmd = f'"{tool("xelab")}" -debug off {top} -s {top}_snap'
    for key, value in generics.items():
        cmd += f' -generic_top "{key}={value}"'
    run(cmd)
    return run([tool("xsim"), f"{top}_snap", "-R"])


def ppm_to_png(ppm_path, png_path):
    tokens = ppm_path.read_text().split()
    width, height, maxval = int(tokens[1]), int(tokens[2]), int(tokens[3])
    scale = 255 // maxval
    pixels = bytes(int(v) * scale for v in tokens[4:4 + width * height * 3])
    Image.frombytes("RGB", (width, height), pixels).save(png_path)


def contact_sheet(names, cell=(512, 384)):
    cols = 2
    rows = (len(names) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * (cell[0] + 10), rows * (cell[1] + 20)), (60, 60, 60))
    draw = ImageDraw.Draw(sheet)
    for i, name in enumerate(names):
        x, y = (i % cols) * (cell[0] + 10), (i // cols) * (cell[1] + 20)
        image = Image.open(OUT / f"{name}.png").resize(cell, Image.BOX)
        sheet.paste(image, (x, y + 20))
        draw.text((x + 4, y + 4), name, fill=(255, 255, 0))
    sheet.save(OUT / "sheet.png")
    print(f"sheet.png: {', '.join(names)}")


def read_log(name):
    lines = (OUT / name).read_text().split("\n")
    cols = lines[0].split()
    return [dict(zip(cols, map(int, line.split()))) for line in lines[1:] if line.strip()]


def gif_2d(rows):
    # Same geometry as pong_pkg (2D section)
    s = GIF_SCALE
    frames = []
    for r in rows[::GIF_STEP]:
        image = Image.new("RGB", (1024 // s, 768 // s), (0, 17, 51))
        draw = ImageDraw.Draw(image)
        draw.rectangle((0, 96 // s, 1024 // s, 104 // s), fill=(153, 170, 187))
        draw.rectangle((0, 744 // s, 1024 // s, 752 // s), fill=(153, 170, 187))
        draw.rectangle((48 // s, r["pl"] // s, 64 // s, (r["pl"] + 96) // s), fill=(255, 119, 51))
        draw.rectangle((960 // s, r["pr"] // s, 976 // s, (r["pr"] + 96) // s), fill=(51, 204, 255))
        if r["on"]:
            draw.ellipse((r["bx"] // s, r["by"] // s, (r["bx"] + 16) // s, (r["by"] + 16) // s), fill=(255, 255, 255))
        draw.text((100, 4), f"{r['sl']} : {r['sr']}", fill=(255, 255, 0))
        draw.text((4, 768 // s - 14), f"frame {r['frame']}", fill=(255, 255, 0))
        frames.append(image)
    save_gif(frames, "pong2d_play.gif")


# 3D table geometry, same as pong_pkg (3D section)
D, HZ_Y, TBL_Y, TW = 768, -64, 768, 240
Z_T0, Z_T1, Z_NET, NET_H, Z_FAR = 96, 924, 510, 48, 1020
RB, PAD_R = 20, 72


def gif_3d(rows):
    # Same projection as pong3d_draw: screen = (512 + X s, HZ_Y + Y s), s = D / (D + z)
    s = GIF_SCALE

    def proj(wx, wy, z):
        k = D / (D + z)
        return (512 + wx * k) / s, (HZ_Y + wy * k) / s

    def circle(draw, wx, wy, z, r, **kw):
        (cx, cy), k = proj(wx, wy, z), D / (D + z)
        rad = r * k / s
        draw.ellipse((cx - rad, cy - rad, cx + rad, cy + rad), **kw)

    frames = []
    for r in rows[::GIF_STEP]:
        image = Image.new("RGB", (1024 // s, 768 // s), (17, 34, 68))
        draw = ImageDraw.Draw(image)
        draw.rectangle((0, 232 // s, 1024 // s, 768 // s), fill=(85, 60, 40))
        table = [proj(-TW, TBL_Y, Z_T0), proj(TW, TBL_Y, Z_T0), proj(TW, TBL_Y, Z_T1), proj(-TW, TBL_Y, Z_T1)]
        draw.polygon(table, fill=(17, 85, 170), outline=(238, 238, 255))
        draw.line((proj(0, TBL_Y, Z_T0), proj(0, TBL_Y, Z_T1)), fill=(238, 238, 255))
        circle(draw, r["cx"], r["cy"], Z_FAR, PAD_R, fill=(221, 34, 34), outline=(255, 170, 85))
        if r["on"] and r["bz"] >= Z_NET:
            circle(draw, r["bx"], r["by"], r["bz"], RB, fill=(255, 238, 170))
        net = (*proj(-TW - 16, TBL_Y - NET_H, Z_NET), *proj(TW + 16, TBL_Y, Z_NET))
        draw.rectangle(net, outline=(255, 255, 255))
        if r["on"]:
            if abs(r["bx"]) <= TW and Z_T0 <= r["bz"] <= Z_T1:
                circle(draw, r["bx"], TBL_Y, r["bz"], RB, fill=(0, 34, 68))
            if r["bz"] < Z_NET:
                circle(draw, r["bx"], r["by"], r["bz"], RB, fill=(255, 238, 170))
        circle(draw, r["px"], r["py"], 0, PAD_R, outline=(255, 170, 85), width=2)
        draw.text((100, 4), f"{r['sp']} : {r['sc']}", fill=(255, 255, 0))
        draw.text((4, 768 // s - 14), f"frame {r['frame']}", fill=(255, 255, 0))
        frames.append(image)
    save_gif(frames, "pong3d_play.gif")


def save_gif(frames, name):
    frames[0].save(OUT / name, save_all=True, append_images=frames[1:], duration=50, loop=0)
    print(f"{name}: {len(frames)} frames")


def run_game(generics):
    log = elaborate_and_run("pong_game_tb", generics)
    for line in log.splitlines():
        if "Note:" in line or "Error:" in line or "Failure:" in line:
            print(line.strip())
    if "pong_game_tb PASS" not in log or "Error:" in log:
        print(log)
        sys.exit("pong_game_tb did not pass")
    gif_2d(read_log("pong2d_log.txt")[-1500:])
    gif_3d(read_log("pong3d_log.txt")[-1500:])


def run_frame(name, generics):
    log = elaborate_and_run("pong_frame_tb", generics)
    status = [line for line in log.splitlines() if "frame captured" in line]
    png = OUT / f"{name}.png"
    ppm_to_png(OUT / "frame.ppm", png)
    print(f"{png.name}: {status[0].strip() if status else ''}")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    command = sys.argv[1]
    if command == "sheet":
        contact_sheet(sys.argv[2:])
        return
    compile_sources()
    if command == "compile":
        print("compiled")
    elif command == "game":
        run_game(dict(arg.split("=", 1) for arg in sys.argv[2:]))
    elif command == "frame":
        generics = dict(PRESETS.get(sys.argv[2], {}))
        generics.update(arg.split("=", 1) for arg in sys.argv[3:])
        run_frame(sys.argv[2], generics)
    elif command == "presets":
        for name in sys.argv[2:] or list(PRESETS):
            run_frame(name, PRESETS[name])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
