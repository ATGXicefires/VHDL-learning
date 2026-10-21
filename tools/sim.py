"""Batch xsim runner for the HW3 VGA testbenches.

Usage (from the project root):
    python tools/sim.py timing
    python tools/sim.py frame <name> [GENERIC=value ...]
    python tools/sim.py presets [name ...]
    python tools/sim.py sheet <name> ...

Outputs go to sim_out/: frame captures are converted from frame.ppm to <name>.png.
"""

import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

VIVADO_BIN = Path("D:/Vivado/2026.1/Vivado/bin")
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "sim_out"

# Compile order matters: packages before the entities that use them
SOURCES = [
    "vga_pkg.vhd",
    "delay_line.vhd",
    "vga_timing.vhd",
    "btn_ctrl.vhd",
    "rgb_blocks.vhd",
    "gray_bars.vhd",
    "shape2d.vhd",
    "vga_core.vhd",
    "vga_timing_tb.vhd",
    "vga_frame_tb.vhd",
]

# Button bit masks follow vga_pkg: C=1, U=2, D=4, L=8, R=16
PRESETS = {
    "blocks_solid": dict(RES=0, MODE=0, VARIANT=1),
    "blocks_hollow": dict(RES=0, MODE=0, VARIANT=0),
    "blocks_move_r_right": dict(RES=0, MODE=0, BTN=16, HOLD=20),
    "blocks_resize_g": dict(RES=0, MODE=0, C_PRESSES=3, BTN=16 | 4, HOLD=20),
    "blocks_800x600": dict(RES=1, MODE=0),
    "blocks_1024x768": dict(RES=2, MODE=0),
    "blocks_1280x1024": dict(RES=3, MODE=0),
    "bars_4bit": dict(RES=0, MODE=1, VARIANT=0, DEPTH=1),
    "bars_1bit": dict(RES=0, MODE=1, VARIANT=0, DEPTH=0),
    "bars_1024x768_4bit": dict(RES=2, MODE=1, VARIANT=0, DEPTH=1),
    "ellipse_solid": dict(RES=0, MODE=2, VARIANT=1),
    "ellipse_hollow": dict(RES=0, MODE=2, VARIANT=0),
    "circle_solid": dict(RES=0, MODE=3, VARIANT=1),
    "circle_hollow": dict(RES=0, MODE=3, VARIANT=0),
    "triangle_solid": dict(RES=0, MODE=4, VARIANT=1),
    "triangle_hollow": dict(RES=0, MODE=4, VARIANT=0),
    "ellipse_moved": dict(RES=0, MODE=2, BTN=8 | 2, HOLD=20),
    "triangle_resized_1280": dict(RES=3, MODE=4, VARIANT=0, C_PRESSES=1, BTN=16 | 4, HOLD=8),
}


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
    OUT.mkdir(exist_ok=True)
    run([tool("xvhdl"), *[f"../{s}" for s in SOURCES]])


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


def contact_sheet(names, cell=(640, 480)):
    # BOX resampling averages the dither patterns; NEAREST would alias them into false colors
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


def run_timing():
    log = elaborate_and_run("vga_timing_tb", {})
    if "vga_timing_tb PASS" not in log:
        print(log)
        sys.exit("vga_timing_tb did not pass")
    print("vga_timing_tb PASS")


def run_frame(name, generics):
    log = elaborate_and_run("vga_frame_tb", generics)
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
    if command == "timing":
        run_timing()
    elif command == "frame":
        generics = dict(arg.split("=", 1) for arg in sys.argv[3:])
        run_frame(sys.argv[2], generics)
    elif command == "presets":
        names = sys.argv[2:] or list(PRESETS)
        for name in names:
            run_frame(name, PRESETS[name])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
