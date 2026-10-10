#!/usr/bin/env python3
"""Generate a simulation-only, all-public-output FTQ baseline comparison.

Run on the selected simulation host. Baseline and candidate RTL are recorded
by hash and never edited in place. Existing FTQ stimulus and goldens are used.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
from generate_wrappers import group


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("candidate", type=Path)
    p.add_argument("baseline", type=Path)
    p.add_argument("out", type=Path)
    args = p.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    candidate, baseline = args.candidate.read_text(), args.baseline.read_text()
    args.out.joinpath("candidate.sv").write_text(candidate.replace("module ftq\n", "module ftq_candidate\n", 1))
    baseline = baseline[baseline.index("module ftq\n"):]
    args.out.joinpath("reference.sv").write_text(baseline.replace("module ftq\n", "module ftq_reference\n", 1))
    text = re.sub(r"/\*.*?\*/|//[^\n]*", "", candidate, flags=re.S)
    text = re.sub(r"`ifdef O3_FRONTEND_DEBUG.*?`endif", "", text, flags=re.S)
    start = re.search(r"\bmodule ftq\b", text).start()
    header_end = text.index("#", start)
    params, end = group(text, text.index("(", header_end))
    ports, end = group(text, text.index("(", end))
    declarations, connections, references, checks = [], [], [], []
    for decl in ports.split(","):
        decl = decl.strip()
        name = re.search(r"(\w+)\s*(?:\[[^\]]*\]\s*)*$", decl).group(1)
        connections.append(f".{name}({name})")
        if decl.startswith("output"):
            declarations.append(re.sub(r"\boutput\s+", "", decl).replace(name, "ref_" + name) + ";")
            references.append(f".{name}(ref_{name})")
            checks.append(f'assert ({name} == ref_{name}) else $fatal(1, "FTQ equivalence: {name}");')
        else:
            references.append(f".{name}({name})")
    wrapper = text[start:header_end] + f"#({params}) ({ports});\n"
    wrapper += "\n".join(declarations) + "\n"
    wrapper += "ftq_candidate #(.CFG(CFG)) candidate (" + ",\n".join(connections) + ");\n"
    wrapper += "ftq_reference #(.CFG(CFG)) reference (" + ",\n".join(references) + ");\n"
    # Preserve the existing testbench's read-only occupancy observation.
    wrapper += "wire [$clog2(CFG.ftq.depth+1)-1:0] count_q = candidate.count_q;\n"
    wrapper += "always @(posedge clk_i) if (!rst_i) begin\n" + "\n".join(checks) + "\nend\nendmodule\n"
    args.out.joinpath("miter.sv").write_text(wrapper)
    args.out.joinpath("source.json").write_text(json.dumps(dict(
        candidate=str(args.candidate), candidate_sha256=hashlib.sha256(args.candidate.read_bytes()).hexdigest(),
        baseline=str(args.baseline), baseline_sha256=hashlib.sha256(args.baseline.read_bytes()).hexdigest(),
        output_checks=len(checks)), indent=2) + "\n")
