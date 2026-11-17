"""Batch xsim runner for the HW3 VGA testbenches.

Usage (from the project root):
    python tools/sim.py timing
    python tools/sim.py game [GENERIC=value ...]
    python tools/sim.py frame <name> [GENERIC=value ...]
    python tools/sim.py presets [name ...]
    python tools/sim.py sheet <name> ...
    python tools/sim.py hdmi
    python tools/sim.py hdmi_frame <name> [GENERIC=value ...]

Outputs go to sim_out/: frame captures are converted from frame.ppm to <name>.png;
`game` runs game_tb and turns game_log.txt into cd_motion.gif and hockey_play.gif.
`hdmi` runs the HDMI self-checking testbenches; `hdmi_frame` decodes the ADV7511 bus into
<name>_hdmi.png (generics default to the preset of the same name).
"""

import os
import re
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

VIVADO_BIN = Path("D:/Vivado/2026.1/Vivado/bin")
ROOT = Path(__file__).resolve().parent.parent
# SIM_OUT lets two simulations run side by side without sharing xsim.dir
OUT = ROOT / "sim_out" / os.environ.get("SIM_OUT", "")

# Compile order matters: packages before the entities that use them
SOURCES = [
    "vga_pkg.vhd",
    "image_rom_pkg.vhd",
    "rot3d_rom_pkg.vhd",
    "game_rom_pkg.vhd",
    "delay_line.vhd",
    "vga_timing.vhd",
    "btn_ctrl.vhd",
    "rgb_blocks.vhd",
    "gray_bars.vhd",
    "shape2d.vhd",
    "image_rom.vhd",
    "ball3d.vhd",
    "tetra3d.vhd",
    "cd_ctrl.vhd",
    "cd_draw.vhd",
    "puck_hit.vhd",
    "hockey_ctrl.vhd",
    "hockey_draw.vhd",
    "vga_core.vhd",
    "hdmi/adv7511_pkg.vhd",
    "hdmi/adv7511_cfg.vhd",
    "hdmi/hdmi_422.vhd",
    "vga_timing_tb.vhd",
    "vga_frame_tb.vhd",
    "game_tb.vhd",
    "hdmi/adv7511_cfg_tb.vhd",
    "hdmi/hdmi_422_tb.vhd",
    "hdmi/hdmi_frame_tb.vhd",
]

# Button bit masks follow vga_pkg: C=1, U=2, D=4, L=8, R=16.
# Mode 5 is the 3D mode: BTNR (16) steps rugby -> sphere, BTNL (8) wraps rugby -> tetrahedron.
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
    "image_4bit": dict(RES=0, MODE=1, VARIANT=1, DEPTH=1),
    "image_1bit": dict(RES=0, MODE=1, VARIANT=1, DEPTH=0),
    "image_800x600": dict(RES=1, MODE=1, VARIANT=1, DEPTH=1),
    "rugby_solid": dict(RES=0, MODE=5, VARIANT=1, DEPTH=1),
    "rugby_wire": dict(RES=0, MODE=5, VARIANT=0, DEPTH=1),
    "sphere_solid": dict(RES=0, MODE=5, VARIANT=1, DEPTH=1, BTN=16, HOLD=2),
    "sphere_wire": dict(RES=0, MODE=5, VARIANT=0, DEPTH=1, BTN=16, HOLD=2),
    "tetra_solid": dict(RES=0, MODE=5, VARIANT=1, DEPTH=1, BTN=8, HOLD=2),
    "tetra_wire": dict(RES=0, MODE=5, VARIANT=0, DEPTH=1, BTN=8, HOLD=2),
    "sphere_1bit": dict(RES=0, MODE=5, VARIANT=1, DEPTH=0, BTN=16, HOLD=2),
    "rugby_1024x768": dict(RES=2, MODE=5, VARIANT=1, DEPTH=1, SKIP=12),
    "triangle_resized_1280": dict(RES=3, MODE=4, VARIANT=0, C_PRESSES=1, BTN=16 | 4, HOLD=8),
    "cd_rainbow": dict(RES=0, MODE=6, VARIANT=1, DEPTH=1),
    "cd_flat": dict(RES=0, MODE=6, VARIANT=0, DEPTH=1),
    "cd_1bit": dict(RES=0, MODE=6, VARIANT=1, DEPTH=0),
    "cd_1024x768": dict(RES=2, MODE=6, VARIANT=1, DEPTH=1),
    "hockey_start": dict(RES=0, MODE=7, VARIANT=1, DEPTH=1),
    "hockey_1bit": dict(RES=0, MODE=7, VARIANT=1, DEPTH=0),
    "hockey_800x600": dict(RES=1, MODE=7, VARIANT=1, DEPTH=1),
    "hockey_1280x1024": dict(RES=3, MODE=7, VARIANT=1, DEPTH=1),
    "hockey_moved": dict(RES=0, MODE=7, VARIANT=1, DEPTH=1, BTN=16 | 2, HOLD=12),
}

# Columns of game_log.txt, written by game_tb.vhd
GAME_COLUMNS = ("frame w h cd_x cd_y cd_tint cd_flash cd_paused puck_x puck_y pm_x pm_y cm_x cm_y "
                "score_p score_c puck_show goal_l goal_r win_p win_c hit hk_paused").split()
# Same 4-bit colors as cd_draw.vhd (TINT_COLOR) and hockey_draw.vhd
CD_TINTS = [0xF33, 0xF93, 0xFF3, 0x3F5, 0x3FF, 0x45F, 0xF4F, 0xFFF]
GIF_SCALE = 2         # draw at half size to keep the GIFs small
GIF_STEP = 3          # every 3rd frame at 50 ms = real-time playback of a 60 Hz game


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
    run([tool("xvhdl"), *[os.path.relpath(ROOT / s, OUT) for s in SOURCES]])


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


def rgb12(c):
    return ((c >> 8) & 15) * 17, ((c >> 4) & 15) * 17, (c & 15) * 17


def circle(draw, x, y, r, color):
    s = GIF_SCALE
    draw.ellipse(((x - r) / s, (y - r) / s, (x + r) / s, (y + r) / s), fill=color)


def save_gif(frames, name):
    frames[0].save(OUT / name, save_all=True, append_images=frames[1:], duration=50, loop=0)
    print(f"{name}: {len(frames)} frames")


def cd_gif(rows, last=1200):
    frames = []
    for row in rows[:last:GIF_STEP]:
        r = dict(zip(GAME_COLUMNS, row))
        bg = (51, 51, 51) if r["cd_flash"] else (0, 0, 0)
        image = Image.new("RGB", (r["w"] // GIF_SCALE, r["h"] // GIF_SCALE), bg)
        draw = ImageDraw.Draw(image)
        circle(draw, r["cd_x"], r["cd_y"], 64, rgb12(CD_TINTS[r["cd_tint"]]))
        circle(draw, r["cd_x"], r["cd_y"], 22, rgb12(0x556))
        circle(draw, r["cd_x"], r["cd_y"], 8, bg)
        draw.text((4, 4), f"frame {r['frame']}", fill=(255, 255, 0))
        frames.append(image)
    save_gif(frames, "cd_motion.gif")


def hockey_gif(rows, last=1800):
    frames = []
    for row in rows[:last:GIF_STEP]:
        r = dict(zip(GAME_COLUMNS, row))
        w, h, s = r["w"], r["h"], GIF_SCALE
        image = Image.new("RGB", (w // s, h // s), rgb12(0x124))
        draw = ImageDraw.Draw(image)
        draw.rectangle((0, 0, w // s - 1, h // s - 1), outline=rgb12(0xBBB), width=8 // s)
        for x0, flash in ((0, r["goal_l"]), (w - 8, r["goal_r"])):
            color = (255, 255, 255) if flash and (r["frame"] // 8) % 2 else (0, 0, 0)
            draw.rectangle((x0 // s, (h // 2 - 80) // s, (x0 + 8) // s - 1, (h // 2 + 80) // s), fill=color)
        draw.line((w // 2 // s, 8 // s, w // 2 // s, (h - 8) // s), fill=rgb12(0xC33), width=2)
        circle(draw, r["pm_x"], r["pm_y"], 20, rgb12(0xE33))
        circle(draw, r["cm_x"], r["cm_y"], 20, rgb12(0x36E))
        if r["puck_show"]:
            circle(draw, r["puck_x"], r["puck_y"], 12, rgb12(0xFD2))
        draw.text((w // 2 // s - 30, 8), f"{r['score_p']} : {r['score_c']}", fill=(255, 255, 255))
        draw.text((4, h // s - 14), f"frame {r['frame']}", fill=(255, 255, 0))
        frames.append(image)
    save_gif(frames, "hockey_play.gif")


def run_game(generics):
    log = elaborate_and_run("game_tb", generics)
    notes = [line.strip() for line in log.splitlines() if "game over" in line or "bounces" in line]
    print("\n".join(notes))
    if "game_tb PASS" not in log:
        print(log)
        sys.exit("game_tb did not pass")
    print("game_tb PASS")
    rows = [list(map(int, line.split())) for line in (OUT / "game_log.txt").read_text().splitlines()
            if line.strip() and not line.startswith("#")]
    cd_gif(rows)
    hockey_gif(rows)


def run_frame(name, generics):
    log = elaborate_and_run("vga_frame_tb", generics)
    status = [line for line in log.splitlines() if "frame captured" in line]
    png = OUT / f"{name}.png"
    ppm_to_png(OUT / "frame.ppm", png)
    print(f"{png.name}: {status[0].strip() if status else ''}")


def run_hdmi():
    for top, generics in (("adv7511_cfg_tb", {}), ("adv7511_cfg_tb", {"NACK": 1}), ("hdmi_422_tb", {})):
        label = " ".join([top, *(f"{k}={v}" for k, v in generics.items())])
        log = elaborate_and_run(top, generics)
        if f"{top} PASS" not in log:
            print(log)
            sys.exit(f"{label} did not pass")
        worst = re.search(r"worst channel error = \d+", log)
        print(f"{label} PASS" + (f" ({worst.group(0)})" if worst else ""))


def csc_coefs():
    # Parsed from the package the ADV7511 is programmed from, so the decoder cannot drift from the hardware
    text = re.sub(r"--.*", "", (ROOT / "hdmi" / "adv7511_pkg.vhd").read_text(encoding="utf-8"))
    body = re.search(r"CSC_COEF\s*:\s*csc_type\s*:=\s*\((.*?)\);", text, re.S).group(1)
    return [int(v) for v in re.findall(r"-?\d+", body)]


def decode_422(txt_path, png_path):
    tokens = txt_path.read_text().split()
    width, height = int(tokens[0]), int(tokens[1])
    words = [int(v) for v in tokens[2:2 + width * height]]
    coefs = csc_coefs()
    rows = [coefs[i:i + 4] for i in (0, 4, 8)]
    pixels = bytearray()
    for i, word in enumerate(words):
        # Lines have an even width and start with Cb, so pairs line up with the global index;
        # both pixels of a pair share its Cb/Cr like the ADV7511 does without 4:2:2 interpolation
        first = i - i % 2
        cb, cr, y = words[first] >> 8, words[first + 1] >> 8, word & 255
        for a1, a2, a3, a4 in rows:
            pixels.append(max(0, min(255, (a1 * cr + a2 * y + a3 * cb + 256 * a4 + 512) // 1024)))
    Image.frombytes("RGB", (width, height), bytes(pixels)).save(png_path)


def run_hdmi_frame(name, generics):
    log = elaborate_and_run("hdmi_frame_tb", generics)
    status = [line for line in log.splitlines() if "frame captured" in line]
    png = OUT / f"{name}_hdmi.png"
    decode_422(OUT / "hdmi_frame.txt", png)
    print(f"{png.name}: {status[0].strip() if status else ''}")
    vga = OUT / f"{name}.png"
    if vga.exists():
        a, b = Image.open(vga).convert("RGB"), Image.open(png)
        if a.size == b.size:
            diffs = [abs(p - q) for p, q in zip(a.tobytes(), b.tobytes())]
            # Half a 4-bit step: anything larger comes from the halved chroma at color edges
            far = sum(max(diffs[k:k + 3]) > 8 for k in range(0, len(diffs), 3))
            print(f"  vs {vga.name}: mean |diff| = {sum(diffs) / len(diffs):.2f}, "
                  f"pixels off by > 8: {100 * far / (len(diffs) // 3):.2f}%")


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
    elif command == "game":
        run_game(dict(arg.split("=", 1) for arg in sys.argv[2:]))
    elif command == "frame":
        generics = dict(arg.split("=", 1) for arg in sys.argv[3:])
        run_frame(sys.argv[2], generics)
    elif command == "presets":
        names = sys.argv[2:] or list(PRESETS)
        for name in names:
            run_frame(name, PRESETS[name])
    elif command == "hdmi":
        run_hdmi()
    elif command == "hdmi_frame":
        generics = dict(PRESETS.get(sys.argv[2], {}))
        generics.update(arg.split("=", 1) for arg in sys.argv[3:])
        run_hdmi_frame(sys.argv[2], generics)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
