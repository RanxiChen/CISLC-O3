#!/usr/bin/env python3
"""Re-synthesize the same generated SoC, ROM and XDC with replacement core RTL.

Run only on Alan. No SoC parameters, constraints, synthesis directives or ROM
contents change. Stop after synthesis reports; this is not FPGA timing closure.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import sys


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("source", type=Path)
    p.add_argument("baseline_run", type=Path)
    p.add_argument("out", type=Path)
    args = p.parse_args()
    source, baseline, out = (v.resolve() for v in (args.source, args.baseline_run, args.out))
    gateware = baseline / "build/standard/gateware"
    out.mkdir(parents=True, exist_ok=False)
    manifest = {}
    for f in gateware.iterdir():
        if f.suffix in {".v", ".xdc", ".init"}:
            shutil.copy2(f, out / f.name)
            manifest[f.name] = hashlib.sha256(f.read_bytes()).hexdigest()
    text = (gateware / "xilinx_kcu105.tcl").read_text()
    text = text[:text.index("# Optimize design")]
    text = text.replace(str(baseline / "source"), str(source)).replace(str(gateware), str(out))
    text += "\nreport_timing -max_paths 10 -path_type full -file soc-worst-10-synth.rpt\nquit\n"
    (out / "soc_area.tcl").write_text(text)
    source_manifest = {str(f.relative_to(source)): hashlib.sha256(f.read_bytes()).hexdigest()
                       for folder in ("rtl", "third_party", "perf/resource")
                       for f in (source / folder).rglob("*")
                       if f.is_file() and f.suffix in {".sv", ".v", ".f", ".vlt", ".svh", ".tcl", ".py"}
                       and not any(x in f.parts for x in ("build", "sim_build", ".git", "__pycache__"))}
    (out / "source-manifest.json").write_text(json.dumps(source_manifest, indent=2) + "\n")
    (out / "generated-inputs.json").write_text(json.dumps(dict(
        baseline_run=str(baseline), input_sha256=manifest,
        baseline_tcl_sha256=hashlib.sha256((gateware / "xilinx_kcu105.tcl").read_bytes()).hexdigest(),
        replacement_tcl_sha256=hashlib.sha256(text.encode()).hexdigest(),
        allowed_changes=["source paths", "output paths", "stop after synthesis", "extra timing report"]), indent=2) + "\n")
    cmd = ["vivado", "-mode", "batch", "-source", "soc_area.tcl"]
    record = dict(host="Alan", source=str(source), cwd=str(out), command=shlex.join(cmd),
                  start=utc(), time_limit_seconds=None, stage="synthesis_only_unplaced")
    (out / "running.json").write_text(json.dumps(record, indent=2) + "\n")
    with (out / "run.log").open("w") as log:
        rc = subprocess.run(["bash", "-c", "source /home/chen/Tool/FPGA/Vivado/2022.2/settings64.sh && exec " + shlex.join(cmd)],
                            cwd=out, stdout=log, stderr=subprocess.STDOUT).returncode
    record.update(end=utc(), exit=rc)
    (out / "result.json").write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps(record), flush=True)
    sys.exit(rc)
