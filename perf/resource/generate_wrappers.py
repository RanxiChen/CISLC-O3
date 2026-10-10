#!/usr/bin/env python3
"""Expose every DUT port for reproducible, untrimmed module area comparisons.

Run on the configured hardware host. These wrappers do not add registers,
tie off data inputs, change DUT parameters, or replace the RTL manifest.
"""
import argparse
from pathlib import Path
import re

MODULES = {
    "uop_queue": ("rtl/backend/uop_queue.sv", "be", "clk"),
    "rename_dispatch_queue": ("rtl/backend/rename_dispatch_queue.sv", "be", "clk"),
    "store_queue": ("rtl/backend/store_queue.sv", "be", "clk"),
    "fetch_buffer": ("rtl/frontend/fetch_buffer.sv", "fe", "clk_i"),
    "ftq": ("rtl/frontend/ftq.sv", "fe", "clk_i"),
    "backend_issue_queue": ("rtl/backend/backend_issue_queue.sv", "be", "clk"),
    "writeback_arbiter": ("rtl/backend/writeback_arbiter.sv", "be", None),
    "fp_writeback_arbiter": ("rtl/backend/fp_writeback_arbiter.sv", "be", None),
    "rob": ("rtl/backend/rob.sv", "be", "clk"),
    "load_queue": ("rtl/backend/load_queue.sv", "be", "clk"),
    "free_list": ("rtl/backend/free_list.sv", "be", "clk"),
    "free_list_FP": ("rtl/backend/free_list.sv", "be", "clk"),
    "rename_map_table": ("rtl/backend/rename_map_table.sv", "be", "clk"),
    "rename_map_table_FP": ("rtl/backend/rename_map_table.sv", "be", "clk"),
    "preg_ready_table": ("rtl/backend/preg_ready_table.sv", "be", "clk"),
    "preg_ready_table_FP": ("rtl/backend/preg_ready_table.sv", "be", "clk"),
}


def group(text, start):
    assert text[start] == "("
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if not depth:
                return text[start + 1:i], i + 1
    raise ValueError("Unbalanced module header")


def generate(root, out):
    out.mkdir(parents=True, exist_ok=True)
    for name, (path, cfg, clock) in MODULES.items():
        dut_name = Path(path).stem
        text = (root / path).read_text()
        text = re.sub(r"/\*.*?\*/|//[^\n]*", "", text, flags=re.S)
        text = re.sub(r"`ifdef O3_FRONTEND_DEBUG.*?`endif", "", text, flags=re.S)
        if name == "rob":
            # Production FPGA defines do not expose optional retirement trace ports.
            text = re.sub(r"`ifdef ENABLE_RETIRE_INFO.*?`endif", "", text, flags=re.S)
        match = re.search(r"\bmodule\s+" + dut_name + r"\b", text)
        start = text.index("#", match.end())
        imports = text[match.end():start]
        params, end = group(text, text.index("(", start))
        params = re.sub(r"(parameter\s+o3_cfg_pkg::\w+\s+CFG)(?=\s*[,\n])",
                        r"\1 = o3_cfg_pkg::O3_CFG." + cfg, params)
        if dut_name in {"free_list", "rename_map_table", "preg_ready_table"}:
            domain = "RD_FP" if name.endswith("_FP") else "RD_INT"
            params = re.sub(r"(parameter\s+o3_types_pkg::reg_domain_e\s+DOMAIN)(?=\s*[,\n])",
                            r"\1 = o3_types_pkg::" + domain, params)
        if name == "backend_issue_queue":
            params = re.sub(r"(parameter\s+o3_types_pkg::iq_kind_e\s+KIND)(?=\s*[,\n])",
                            r"\1 = o3_types_pkg::IQ_INT", params)
        elif name == "rob":
            params = re.sub(r"(parameter\s+int\s+COMPLETE_WIDTH)(?=\s*[,\n])",
                            r"\1 = CFG.exec.num_alu + 2*CFG.lsu.mem_pipes + 10", params)
        ports, end = group(text, text.index("(", end))
        ports = re.sub(r"=\s*[^,\n]+", "", ports)
        connections = []
        for decl in ports.split(","):
            match = re.search(r"(\w+)\s*(?:\[[^\]]*\]\s*)*$", decl.strip())
            if not match:
                raise ValueError(f"Cannot read {name} port: {decl!r}")
            port = match.group(1)
            connections.append(f"    .{port}({port})")
        overrides = ".CFG(CFG)"
        if name == "store_queue":
            overrides += ", .DCACHE_DRAIN(1'b1)"
        elif name == "backend_issue_queue":
            overrides += ", .KIND(KIND)"
        elif name == "fp_writeback_arbiter":
            overrides += ", .NUM_SRC(NUM_SRC)"
        elif name == "rob":
            overrides += ", .COMPLETE_WIDTH(COMPLETE_WIDTH)"
        if dut_name in {"free_list", "rename_map_table", "preg_ready_table"}:
            overrides += ", .DOMAIN(DOMAIN)"
        wrapper = (f"module {name}_area_top\n{imports}#({params}) ({ports});\n"
                   f"{dut_name} #({overrides}) dut (\n" + ",\n".join(connections) + "\n);\nendmodule\n")
        (out / f"{name}_area_top.sv").write_text(wrapper)


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("root", type=Path)
    p.add_argument("out", type=Path)
    args = p.parse_args()
    generate(args.root.resolve(), args.out.resolve())
