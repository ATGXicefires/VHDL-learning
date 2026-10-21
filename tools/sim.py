"""Batch xsim runner for the HW3 VGA testbenches.

Usage (from the project root):
    python tools/sim.py timing
    python tools/sim.py frame <name> [GENERIC=value ...]
    python tools/sim.py presets [name ...]

Outputs go to sim_out/: frame captures are converted from frame.ppm to <name>.png.
"""

import subprocess
import sys
from pathlib import Path

from PIL import Image

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
    compile_sources()
    command = sys.argv[1]
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
