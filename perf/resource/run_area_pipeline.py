#!/usr/bin/env python3
"""Wait for owned jobs to finish, then run module and whole-SoC synthesis.

No duration limit and no forced termination. Waiting time is recorded
separately from synthesis start/end. Run only on Alan after host preflight.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("source", type=Path)
    p.add_argument("baseline_run", type=Path)
    p.add_argument("out", type=Path)
    p.add_argument("--wait-for", type=Path, nargs="*", default=[])
    p.add_argument("--soc-wait-for", type=Path, nargs="*", default=[])
    p.add_argument("--min-free-gib", type=int, default=32)
    p.add_argument("--modules", nargs="+", default=["store_queue", "ftq"])
    args = p.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    status = dict(host="Alan", source=str(args.source), start=utc(), time_limit_seconds=None,
                  state="waiting_for_owned_jobs_and_ram", dependencies=[str(p) for p in args.wait_for],
                  soc_dependencies=[str(p) for p in args.soc_wait_for],
                  controller_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    (args.out / "pipeline.json").write_text(json.dumps(status, indent=2) + "\n")
    while True:
        missing = [p for p in args.wait_for if not p.exists()]
        if not missing:
            for path in args.wait_for:
                result = json.loads(path.read_text())
                if result["exit"] != 0:
                    status.update(state="dependency_failed", dependency=str(path), exit=result["exit"], end=utc())
                    (args.out / "pipeline.json").write_text(json.dumps(status, indent=2) + "\n")
                    sys.exit(result["exit"])
            mem = dict(line.split(":", 1) for line in Path("/proc/meminfo").read_text().splitlines())
            available = int(mem["MemAvailable"].split()[0]) / (1024 * 1024)
            if available >= args.min_free_gib:
                break
        time.sleep(10)
    status.update(state="running_module_synthesis", synthesis_start=utc(), available_gib=available)
    (args.out / "pipeline.json").write_text(json.dumps(status, indent=2) + "\n")
    cmd = [sys.executable, str(args.source / "perf/resource/run_modules.py"),
           str(args.source), str(args.out / "modules"), "--modules"] + args.modules
    rc = subprocess.call(cmd)
    if rc == 0:
        status.update(state="waiting_for_soc_dependencies_and_ram")
        (args.out / "pipeline.json").write_text(json.dumps(status, indent=2) + "\n")
        while True:
            if all(p.exists() for p in args.soc_wait_for):
                results = [json.loads(p.read_text()) for p in args.soc_wait_for]
                if any(r["exit"] != 0 for r in results):
                    rc = next(r["exit"] for r in results if r["exit"] != 0)
                    break
                mem = dict(line.split(":", 1) for line in Path("/proc/meminfo").read_text().splitlines())
                if int(mem["MemAvailable"].split()[0]) >= args.min_free_gib * 1024 * 1024:
                    break
            time.sleep(10)
    if rc == 0:
        status.update(state="running_soc_synthesis")
        (args.out / "pipeline.json").write_text(json.dumps(status, indent=2) + "\n")
        rc = subprocess.call([sys.executable, str(args.source / "perf/resource/run_soc_area.py"),
                              str(args.source), str(args.baseline_run), str(args.out / "soc")])
    status.update(state="complete" if rc == 0 else "failed", exit=rc, end=utc())
    (args.out / "pipeline.json").write_text(json.dumps(status, indent=2) + "\n")
    print(json.dumps(status), flush=True)
    sys.exit(rc)
