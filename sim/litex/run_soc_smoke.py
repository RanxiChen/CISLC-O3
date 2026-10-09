#!/usr/bin/env python3
"""Bound S1 build/run to 30 minutes and preserve UART/assertion evidence."""
import argparse
import hashlib
import json
import os
import re
import selectors
import shlex
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--bios", required=True, type=Path)
    p.add_argument("--evidence-dir", required=True, type=Path)
    p.add_argument("--selftest", action="store_true", help="run S2 after the S1 console")
    args = p.parse_args()
    root = Path(__file__).resolve().parents[2]
    evidence = args.evidence_dir.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    bios = args.bios.resolve()
    command = [sys.executable, "-u", str(root / "sim/litex/o3_sim.py"),
        "--output-dir", str(evidence / "build"), "--rom-init", str(bios), "--run"]
    if args.selftest:
        command.append("--selftest")
    real = shutil.which("verilator")
    if real is None:
        raise RuntimeError("Verilator is required")
    shim_dir = evidence / "tools"
    shim_dir.mkdir(exist_ok=True)
    shim = shim_dir / "verilator"
    shim.write_text("#!/bin/sh\nexec " + shlex.quote(real) + " --assert -DENABLE_RETIRE_INFO " +
        shlex.quote(str(root / "scripts/cvfpu.vlt")) + ' "$@"\n')
    shim.chmod(0o755)
    env = dict(os.environ)
    env["PATH"] = str(shim_dir) + os.pathsep + env.get("PATH", "")
    start_utc = datetime.now(timezone.utc).isoformat()
    start = time.monotonic()
    child = subprocess.Popen(command, cwd=root, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, start_new_session=True)
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ)
    captured = ""
    result = "FAIL"
    sent_selftest = False
    errors = r"%Error|Assertion failed|assertion failed|Memory initialization failed|Memtest KO|\[O3-S2\] FAIL"
    with (evidence / "uart-build.log").open("wb") as log:
        while time.monotonic() - start < 1800:
            for key, _ in selector.select(timeout=1):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                log.write(chunk)
                log.flush()
                captured += chunk.decode("utf-8", errors="replace")
            if re.search(errors, captured):
                break
            plain = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", captured)
            if all(marker in plain for marker in ("Build your hardware, easily!", "Memtest OK", "litex>")):
                if "[O3-SMOKE] first_fetch=10010000" in captured and re.search(r"sram_reads=[1-9][0-9]*", captured):
                    if args.selftest and not sent_selftest:
                        child.stdin.write(b"soc_selftest\n")
                        child.stdin.flush()
                        sent_selftest = True
                    if not args.selftest or "[O3-S2] ALL PASS" in captured:
                        result = "PASS"
                        break
            if child.poll() is not None and not selector.get_map():
                break
        else:
            result = "TIMEOUT"
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
        tail = child.stdout.read()
        log.write(tail)
        captured += tail.decode("utf-8", errors="replace")
    if re.search(errors, captured):
        result = "FAIL"
    metadata = dict(cwd=str(root), command=command, start_utc=start_utc,
        end_utc=datetime.now(timezone.utc).isoformat(), elapsed_seconds=time.monotonic()-start,
        wall_limit_seconds=1800, bios_sha256=hashlib.sha256(bios.read_bytes()).hexdigest(),
        assertions_enabled=True, memtest_bytes=65536, result=result, child_exit=child.returncode,
        selftest_requested=args.selftest, selftest_command_sent=sent_selftest,
        runner_exit=0 if result == "PASS" else 1)
    (evidence / "result.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps(metadata, indent=2), flush=True)
    return metadata["runner_exit"]


if __name__ == "__main__":
    sys.exit(main())
