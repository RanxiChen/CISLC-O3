#!/usr/bin/env python3
"""Generate a packed-stimulus, all-output comparison for a writeback arbiter.

Run on the configured simulation host. Keep the frozen reference unchanged.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
from generate_wrappers import group


def packed_decl(datatype, name, suffix):
    dimensions = re.findall(r"\[([^]]+)\]", suffix)
    dimensions = [d if ":" in d else f"{d}-1:0" for d in dimensions]
    match = re.match(r"(\w+(?:::\w+)*)(.*)", datatype.strip())
    assert match, datatype
    return match[1] + " " + "".join(f"[{d}]" for d in dimensions) + match[2] + f" {name};"


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("candidate", type=Path)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("out", type=Path)
    parser.add_argument("--domain", choices=["INT", "FP"], default="INT")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    candidate = args.candidate.read_text()
    scope = re.search(r"\bmodule\s+(\w+)", re.sub(r"/\*.*?\*/", "", candidate, flags=re.S))[1]
    assert scope in {"writeback_arbiter", "fp_writeback_arbiter", "rob", "load_queue",
                     "free_list", "rename_map_table", "preg_ready_table"}
    reference = args.baseline.read_text()
    (args.out / "reference.sv").write_text(re.sub(r"\bmodule\s+" + scope + r"\b",
                                                "module " + scope + "_reference", reference, count=1))
    text = re.sub(r"/\*.*?\*/|//[^\n]*", "", candidate, flags=re.S)
    if scope == "rob":
        text = re.sub(r"`ifdef ENABLE_RETIRE_INFO.*?`endif", "", text, flags=re.S)
    start = text.index("#", re.search(r"\bmodule\s+" + scope, text).end())
    params, end = group(text, text.index("(", start))
    params = re.sub(r"parameter\s+o3_cfg_pkg::backend_cfg_t\s+CFG\s*,",
                    "localparam o3_cfg_pkg::backend_cfg_t CFG = o3_cfg_pkg::O3_CFG.be,", params)
    params = params.replace("parameter ", "localparam ")
    domain_scope = scope in {"free_list", "rename_map_table", "preg_ready_table"}
    if domain_scope:
        params = re.sub(r"(localparam\s+o3_types_pkg::reg_domain_e\s+DOMAIN)(?=\s*[,\n])",
                        r"\1 = o3_types_pkg::RD_" + args.domain, params)
    if scope == "rob":
        params = re.sub(r"(localparam\s+int\s+COMPLETE_WIDTH)(?=\s*[,\n])",
                        r"\1 = CFG.exec.num_alu + 2*CFG.lsu.mem_pipes + 10", params)
    ports, _ = group(text, text.index("(", end))
    ports = re.sub(r"=\s*[^,\n]+", "", ports)
    declarations, fields = [], {"input": [], "output": []}
    connections, ref_connections, input_assigns, output_assigns = [], [], [], []
    previous_type, direction = None, None
    for declaration in ports.split(","):
        declaration = declaration.strip()
        token = declaration.split(None, 1)
        if token[0] in {"input", "output"}:
            direction, rest = token
        else:
            assert direction is not None
            rest = declaration
        if re.fullmatch(r"\w+\s*(?:\[[^]]+\]\s*)*", rest.strip()):
            assert previous_type is not None
            rest = previous_type + " " + rest
        match = re.fullmatch(r"(.+?)\s+(\w+)\s*((?:\[[^]]+\]\s*)*)", rest.strip())
        assert match, declaration
        datatype, name, suffix = match.groups()
        previous_type = datatype
        if (scope in {"rob", "load_queue"} or domain_scope) and name == "clk":
            connections.append(".clk(clk_i)")
            ref_connections.append(".clk(clk_i)")
            continue
        declarations.append(f"{datatype} {name} {suffix};")
        fields[direction].append(packed_decl(datatype, name, suffix))
        connections.append(f".{name}({name})")
        if direction == "output":
            declarations.append(f"{datatype} ref_{name} {suffix};")
            ref_connections.append(f".{name}(ref_{name})")
        else:
            ref_connections.append(f".{name}({name})")
        dimensions = re.findall(r"\[([^]]+)\]", suffix)
        assert len(dimensions) <= 1
        if dimensions:
            d = dimensions[0]
            count = d.split(":")[0] + "+1" if ":" in d else d
            if direction == "input":
                input_assigns.append(f"for (genvar n=0;n<{count};n++) assign {name}[n]=stim_i.{name}[n];")
            else:
                output_assigns.append(f"for (genvar n=0;n<{count};n++) begin\n"
                                      f"assign observed.{name}[n]={name}[n];\n"
                                      f"assign expected.{name}[n]=ref_{name}[n];\nend")
        elif direction == "input":
            input_assigns.append(f"assign {name}=stim_i.{name};")
        else:
            output_assigns.append(f"assign observed.{name}={name};\nassign expected.{name}=ref_{name};")
    package = scope + "_equivalence_pkg"
    parameter_declarations = []
    previous_parameter_type = None
    for declaration in params.split(","):
        declaration = declaration.strip()
        match = re.match(r"^(?:localparam|parameter)\s+(.+?)\s+\w+\s*=", declaration)
        if match:
            previous_parameter_type = "localparam " + match[1]
        else:
            assert previous_parameter_type is not None, declaration
            declaration = previous_parameter_type + " " + declaration
        parameter_declarations.append(declaration + ";")
    header = (f"package {package};\nimport o3_pkg::*;\n" + "\n".join(parameter_declarations) + "\n"
              + "typedef struct packed {\n" + "\n".join(fields["input"]) + "\n} stim_t;\n"
              + "typedef struct packed {\n" + "\n".join(fields["output"]) + "\n} result_t;\nendpackage\n")
    overrides = ".CFG(CFG)" + (",.NUM_SRC(NUM_SRC)" if scope == "fp_writeback_arbiter" else "")
    if scope == "rob":
        overrides += ",.COMPLETE_WIDTH(COMPLETE_WIDTH)"
    if domain_scope:
        overrides += ",.DOMAIN(DOMAIN)"
    top = (f"module wb_equivalence_tb_top import {package}::*; (\n"
           "input logic clk_i,rst_i,input stim_t stim_i,output result_t result_o,\n"
           "output stim_t fmt_valid,fmt_clear_dense,fmt_quiet,fmt_robs,fmt_kill,fmt_reset);\n"
           "import o3_pkg::*;\n" + "\n".join(declarations) + "\nresult_t observed,expected;\n"
           + "\n".join(input_assigns + output_assigns) + "\n"
           + f"{scope} #({overrides}) candidate (" + ",".join(connections) + ");\n"
           + f"{scope}_reference #({overrides}) reference (" + ",".join(ref_connections) + ");\n"
           + "assign result_o=observed;\n"
           + "always @(posedge clk_i) if (!rst_i) assert(observed==expected)\n"
           + ' else begin $display("observed=%h expected=%h stimulus=%h",observed,expected,stim_i);\n'
           + ('$display("free=%h ref_free=%h committed=%h ref_committed=%h",candidate.free_bitmap_q,reference.free_bitmap_q,candidate.committed_free_q,reference.committed_free_q);\n'
              if scope == "free_list" else "")
           + f' $fatal(1,"{scope} all-output equivalence"); end\n'
           + "always_comb begin\nfmt_valid='0;fmt_clear_dense='0;fmt_quiet='0;fmt_robs='0;fmt_kill='0;fmt_reset='0;\n")
    if scope == "writeback_arbiter":
        top += """
fmt_quiet.flush_all_i=1;fmt_quiet.resolution_valid_i=1;fmt_quiet.resolution_mispredict_i=1;
fmt_kill.flush_all_i=1;
for(int n=0;n<NUM_ALUS;n++) begin
 fmt_valid.alu_result_i[n].valid=1;fmt_valid.alu_result_i[n].dst_write_en=1;
 fmt_robs.alu_result_i[n].rob_idx='1;
end
for(int n=0;n<P;n++) begin fmt_valid.load_result_i[n].valid=1;fmt_robs.load_result_i[n].rob_idx='1;end
fmt_valid.branch_result_i.valid=1;fmt_valid.branch_result_i.dst_write_en=1;
fmt_clear_dense.branch_result_i.exc.valid=1;fmt_robs.branch_result_i.rob_idx='1;
for(int n=0;n<NUM_EXTRA_SRC;n++) begin
 fmt_valid.extra_src_i[n].valid=1;fmt_valid.extra_src_i[n].tag.dst_write_en=1;
 fmt_robs.extra_src_i[n].tag.rob_idx='1;
end
"""
    elif scope == "fp_writeback_arbiter":
        top += """
fmt_quiet.flush_all_i=1;fmt_quiet.resolution_i.valid=1;fmt_quiet.resolution_i.mispredict=1;
fmt_kill.flush_all_i=1;
for(int n=0;n<NUM_SRC;n++) begin
 fmt_valid.src_i[n].valid=1;fmt_valid.src_i[n].tag.dst_dom=o3_types_pkg::RD_FP;
 fmt_clear_dense.src_i[n].tag.dst_dom=o3_types_pkg::reg_domain_e'('1);
 fmt_robs.src_i[n].tag.rob_idx='1;
end
"""
    elif scope == "rob":
        top += """
fmt_reset.rst=1;
fmt_quiet.rst=1;fmt_quiet.t_flush_all_i=1;fmt_quiet.resolution_valid_i=1;fmt_quiet.resolution_mispredict_i=1;
fmt_kill.t_flush_all_i=1;fmt_valid.alloc_ready_i=1;
for(int n=0;n<MACHINE_WIDTH;n++) fmt_valid.alloc_req_i[n]=1;
for(int n=0;n<COMPLETE_WIDTH;n++) fmt_robs.complete_idx_i[n]='1;
fmt_robs.t_exc_idx_i='1;fmt_robs.t_d_idx_i='1;fmt_robs.resolution_rob_idx_i='1;
"""
    elif scope == "load_queue":
        top = top.replace("fmt_reset);", "fmt_reset,fmt_release,fmt_alloc_one);")
        top += """
fmt_release='0;fmt_alloc_one='0;
fmt_release.release_count_i=1;fmt_alloc_one.alloc_fire_i=1;fmt_alloc_one.alloc_req_i[0]=1;
fmt_reset.rst=1;
fmt_quiet.rst=1;fmt_quiet.flush_i=1;fmt_quiet.alloc_fire_i=1;fmt_quiet.release_count_i='1;
fmt_quiet.resolution_valid_i=1;fmt_quiet.resolution_mispredict_i=1;
fmt_kill.flush_i=1;fmt_valid.alloc_fire_i=1;
fmt_robs.resolution_valid_i=1;fmt_robs.resolution_mispredict_i=1;
for(int n=0;n<RENAME_WIDTH;n++) begin
 fmt_quiet.alloc_req_i[n]=1;fmt_valid.alloc_req_i[n]=1;
 fmt_quiet.alloc_branch_mask_i[n]='1;
end
for(int n=0;n<P;n++) fmt_clear_dense.capture_i[n].uop.branch_mask='1;
"""
    elif scope == "free_list":
        top += """
fmt_reset.rst=1;fmt_quiet.rst=1;
fmt_quiet.flush_all_i=1;fmt_quiet.resolution_valid_i=1;fmt_quiet.resolution_mispredict_i=1;
fmt_kill.flush_all_i=1;fmt_valid.alloc_fire_i=1;
for(int n=0;n<MACHINE_WIDTH;n++) fmt_valid.alloc_req_i[n]=1;
"""
    elif scope == "rename_map_table":
        top += """
fmt_reset.rst=1;fmt_quiet.rst=1;
fmt_quiet.flush_all_i=1;fmt_quiet.resolution_valid_i=1;fmt_quiet.resolution_mispredict_i=1;
fmt_kill.flush_all_i=1;fmt_valid.rename_fire_i=1;
for(int n=0;n<MACHINE_WIDTH;n++) begin
 fmt_valid.lane_valid_i[n]=1;fmt_valid.rd_write_en_i[n]=1;
 fmt_valid.rs1_read_en_i[n]=1;fmt_valid.rs2_read_en_i[n]=1;fmt_valid.rs3_read_en_i[n]=1;
 fmt_robs.rd_addr_i[n]='1;fmt_robs.rs1_addr_i[n]='1;fmt_robs.rs2_addr_i[n]='1;fmt_robs.rs3_addr_i[n]='1;
end
"""
    else:
        top += """
fmt_reset.rst=1;fmt_quiet.rst=1;
for(int n=0;n<ALLOC_WIDTH;n++) begin fmt_valid.alloc_valid_i[n]=1;fmt_robs.alloc_preg_i[n]='1;end
for(int n=0;n<WRITE_PORTS;n++) begin fmt_valid.wr_en_i[n]=1;fmt_robs.wr_addr_i[n]='1;end
"""
    top += "end\nendmodule\n"
    (args.out / "tb.sv").write_text(header + top)
    record = dict(scope=scope, candidate=str(args.candidate), baseline=str(args.baseline),
                  domain=args.domain if domain_scope else None,
                  candidate_sha256=hashlib.sha256(args.candidate.read_bytes()).hexdigest(),
                  baseline_sha256=hashlib.sha256(args.baseline.read_bytes()).hexdigest(),
                  compared_output_ports=len(fields["output"]),
                  generator_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    (args.out / "source.json").write_text(json.dumps(record, indent=2) + "\n")
