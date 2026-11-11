"""Batch xsim run of led_pingpong_tb.

Usage (from the project root): python tools/sim.py
Outputs go to sim_out/.
"""

import os
import subprocess
import sys
from pathlib import Path

VIVADO_BIN = Path("D:/Vivado/2026.1/Vivado/bin")
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "sim_out"
SOURCES = ["led_pingpong.vhd", "led_pingpong_tb.vhd"]
TOP = "led_pingpong_tb"


def run(cmd):
    # xsim only reports VHDL assertion errors in its log, not via the exit code
    result = subprocess.run(cmd, cwd=OUT, capture_output=True, text=True)
    log = result.stdout + result.stderr
    if result.returncode != 0 or "ERROR:" in log:
        print(log)
        sys.exit(f"command failed: {cmd if isinstance(cmd, str) else ' '.join(cmd)}")
    return log


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    # Relative paths: xvhdl.bat breaks on the spaces in the absolute project path
    run([str(VIVADO_BIN / "xvhdl.bat"), *[os.path.relpath(ROOT / s, OUT) for s in SOURCES]])
    run([str(VIVADO_BIN / "xelab.bat"), "-debug", "off", TOP, "-s", f"{TOP}_snap"])
    log = run([str(VIVADO_BIN / "xsim.bat"), f"{TOP}_snap", "-R"])
    notes = [line.strip() for line in log.splitlines() if "step up" in line or "PASS" in line or "Error" in line]
    print("\n".join(notes))
    if f"{TOP} PASS" not in log:
        print(log)
        sys.exit(f"{TOP} did not pass")


if __name__ == "__main__":
    main()
