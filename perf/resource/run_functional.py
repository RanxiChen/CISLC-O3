#!/usr/bin/env python3
"""Run unchanged module goldens with original seeds in a private source tree."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("root", type=Path)
    p.add_argument("out", type=Path)
    p.add_argument("--modules", nargs="+", default=["uop_queue", "rename_dispatch_queue"])
    args = p.parse_args()
    root, out = args.root.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    manifest = {str(f.relative_to(root)): hashlib.sha256(f.read_bytes()).hexdigest()
                for folder in ("rtl", "sim", "perf/resource") for f in (root / folder).rglob("*")
                if f.is_file() and f.suffix in {".sv", ".py"} and "sim_build" not in f.parts and "build" not in f.parts}
    (out / "source-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    results = []
    for module in args.modules:
        for seed in (1, 7, 29):
            label = f"{module}-{seed}"
            cmd = ["make", "-C", str(root / "sim/cocotb" / module), "sim", f"TEST_SEED={seed}",
                   f"COCOTB_RESULTS_FILE={out / (label + '.xml')}", f"SIM_BUILD={out / ('build-' + module)}"]
            if module == "fetch_buffer_payload":
                cmd[2] = str(root / "sim/cocotb/fetch_buffer")
                cmd += ["-f", "Makefile.payload"]
            elif module == "ftq_metadata":
                cmd[2] = str(root / "sim/cocotb/bpu")
                cmd += ["COCOTB_TOPLEVEL=ftq_training_tb_top", "COCOTB_TEST_MODULES=test_ftq"]
            elif module.startswith("issue_queue_equivalence"):
                kind = int(module[-1])
                cmd[2] = str(root / "sim/cocotb/issue_queue_equivalence")
                cmd += ["-f", "Makefile.equivalence", f"KIND={kind}",
                        f"REFERENCE_SOURCE={out / 'backend_issue_queue_reference.sv'}"]
            elif module in {"ftq_equivalence", "ftq_metadata_equivalence", "ftq_payload_equivalence"}:
                folder = "bpu" if module == "ftq_metadata_equivalence" else "ftq"
                testdir = root / "sim/cocotb" / folder
                cmd[2] = str(testdir)
                makefile = "Makefile.payload" if module == "ftq_payload_equivalence" else "Makefile"
                if makefile == "Makefile.payload":
                    cmd += ["-f", makefile]
                text = (testdir / makefile).read_text()
                lines = text[text.index("VERILOG_SOURCES :="):]
                lines = lines.split("SIM_BUILD :=")[0].split("EXTRA_ARGS +=")[0]
                sources = re.findall(r"(?:\$\(REPO_ROOT\)|\$\(CURDIR\))[^\s\\]+\.sv", lines)
                sources = [s.replace("$(REPO_ROOT)", str(root)).replace("$(CURDIR)", str(testdir)) for s in sources]
                i = sources.index(str(root / "rtl/frontend/ftq.sv"))
                sources[i:i+1] = [str(out / "ftq-miter" / f) for f in ("candidate.sv", "reference.sv", "miter.sv")]
                cmd += ["VERILOG_SOURCES=" + " ".join(sources)]
                if folder == "bpu":
                    cmd += ["COCOTB_TOPLEVEL=ftq_training_tb_top", "COCOTB_TEST_MODULES=test_ftq"]
            if module == "uop_queue":
                cmd += ["COCOTB_TEST_MODULES=test_uop_queue,test_payload"]
            elif module == "rename_dispatch_queue":
                cmd += ["COCOTB_TEST_MODULES=test_rename_dispatch_queue,test_payload"]
            elif module == "store_queue":
                cmd += ["COCOTB_TEST_MODULES=test_store_queue,test_l8b_store_queue,test_byte_oracle"]
            record = dict(label=label, cwd=str(root), command=shlex.join(cmd), start=utc(), host="cloud_chen")
            with (out / f"{label}.log").open("w") as log:
                rc = subprocess.run(["bash", "-c", "source /home/cloud_chen/setup/activate-o3.sh && exec " + shlex.join(cmd)],
                                    cwd=root, stdout=log, stderr=subprocess.STDOUT).returncode
            record.update(end=utc(), exit=rc)
            results.append(record)
            (out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
            print(json.dumps(record), flush=True)
            if rc:
                sys.exit(rc)
