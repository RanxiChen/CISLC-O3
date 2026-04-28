#!/usr/bin/env python3

import math
import os
import re
import subprocess
import sys
from pathlib import Path

os.environ.setdefault("MPLCONFIGDIR", "/tmp/matplotlib-lfsr")

import matplotlib.pyplot as plt


SIM_DIR = Path(__file__).resolve().parent
ROOT_DIR = SIM_DIR.parent.parent
BIN_PATH = SIM_DIR / "obj_dir" / "Vlfsr"
OUTPUT_PATH = SIM_DIR / "variance_curve.png"
START_UPDATES = 100
END_UPDATES = 65535
NUM_SAMPLES = 600
Y_SCALE = 10000.0
VARIANCE_PATTERN = re.compile(r"variance_like=([0-9.+\-eE]+)")


def ensure_sim_binary() -> None:
    if BIN_PATH.exists():
        return

    env = os.environ.copy()
    env["CCACHE_DISABLE"] = "1"
    subprocess.run(
        ["make", "-C", str(SIM_DIR)],
        cwd=ROOT_DIR,
        env=env,
        check=True,
    )


def sample_points() -> list[int]:
    if NUM_SAMPLES < 2:
        return [START_UPDATES, END_UPDATES]

    step = (END_UPDATES - START_UPDATES) / (NUM_SAMPLES - 1)
    points = [int(round(START_UPDATES + index * step)) for index in range(NUM_SAMPLES)]
    points[0] = START_UPDATES
    points[-1] = END_UPDATES

    deduped_points = []
    seen = set()
    for point in points:
        if point not in seen:
            deduped_points.append(point)
            seen.add(point)
    return deduped_points


def run_sim(total_updates: int) -> float:
    completed = subprocess.run(
        [str(BIN_PATH), str(total_updates)],
        cwd=SIM_DIR,
        capture_output=True,
        text=True,
        check=True,
    )

    match = VARIANCE_PATTERN.search(completed.stdout)
    if match is None:
        raise RuntimeError(
            f"Failed to parse variance_like from simulator output for total_updates={total_updates}"
        )
    return float(match.group(1))


def main() -> int:
    ensure_sim_binary()

    x_values = sample_points()
    y_values = []

    for total_updates in x_values:
        variance_like = run_sim(total_updates)
        scaled_variance = variance_like * Y_SCALE
        y_values.append(scaled_variance)
        print(
            f"sample total_updates={total_updates} "
            f"variance_like={variance_like:.8f} scaled_y={scaled_variance:.8f}"
        )

    plt.figure(figsize=(10, 6))
    plt.plot(x_values, y_values, linewidth=1.5)
    plt.xlabel("total_updates")
    plt.ylabel("variance_like * 10000")
    plt.title("LFSR low-bit distribution variance over update count")
    plt.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(OUTPUT_PATH, dpi=160)
    print(f"saved plot to {OUTPUT_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
