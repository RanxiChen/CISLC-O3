#!/usr/bin/env python3
"""Run one ACT4 ELF on the CISLC-O3 whole-core simulator."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path


TOHOST_ADDRESS = 0x1200_0000


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("elf")
    parser.add_argument("--sim", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--max-cycles", type=int, default=1_000_000)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.max_cycles <= 0:
        raise ValueError("--max-cycles must be greater than zero")

    elf = Path(args.elf).resolve()
    simulator = Path(args.sim).resolve()
    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    trace_path = output_dir / f"{elf.stem}.jsonl"
    log_path = output_dir / f"{elf.stem}.log"

    command = [
        str(simulator),
        "--image", str(elf),
        "--trace", str(trace_path),
        "--max-cycles", str(args.max_cycles),
        "--max-retires", str(1 << 60),
        "--tohost-address", hex(TOHOST_ADDRESS),
    ]
    completed = subprocess.run(
        command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
    )
    log_path.write_text(completed.stdout, encoding="utf-8")
    passed = completed.returncode == 0 and "[o3-tohost] value=0x1 status=PASS" in completed.stdout
    record = {
        "test": elf.name,
        "elf": str(elf),
        "trace": str(trace_path),
        "log": str(log_path),
        "returncode": completed.returncode,
        "status": "PASS" if passed else "FAIL",
    }
    print(json.dumps(record, sort_keys=True))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
