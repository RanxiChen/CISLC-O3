#!/usr/bin/env python3
"""Sequential unlimited-duration Vivado comparisons, retaining actual exits."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import sys

from generate_wrappers import MODULES, generate


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("root", type=Path)
    p.add_argument("out", type=Path)
    p.add_argument("--modules", nargs="+", choices=MODULES, default=list(MODULES))
    args = p.parse_args()
    root, out = args.root.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    generate(root, out / "wrappers")
    manifest = {str(f.relative_to(root)): hashlib.sha256(f.read_bytes()).hexdigest()
                for f in root.rglob("*") if f.is_file() and f.suffix in {".sv", ".v", ".tcl", ".py"}
                and not any(x in f.parts for x in ("build", "sim_build", ".git", "__pycache__"))}
    (out / "source-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    results = []
    for scope in args.modules:
        case = out / scope
        case.mkdir(exist_ok=True)
        cmd = ["vivado", "-mode", "batch", "-source", "perf/resource/module_area.tcl", "-tclargs", str(case), scope]
        record = dict(scope=scope, cwd=str(root), command=shlex.join(cmd), start=utc(), host="Alan", time_limit_seconds=None)
        (case / "running.json").write_text(json.dumps(record, indent=2) + "\n")
        with (case / "run.log").open("w") as f:
            rc = subprocess.run(["bash", "-c", "source /home/chen/Tool/FPGA/Vivado/2022.2/settings64.sh && exec " + shlex.join(cmd)],
                                cwd=root, stdout=f, stderr=subprocess.STDOUT).returncode
        record.update(end=utc(), exit=rc)
        (case / "result.json").write_text(json.dumps(record, indent=2) + "\n")
        results.append(record)
        (out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        print(json.dumps(record), flush=True)
        if rc:
            sys.exit(rc)
