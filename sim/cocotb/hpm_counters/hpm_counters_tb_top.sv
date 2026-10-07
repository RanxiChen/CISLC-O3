// Flattens csr_req_t / csr_resp_t and the two packed perf vectors; no state.
module hpm_counters_tb_top import o3_types_pkg::*; (
    input  logic clk, rst, req_valid_i, write_i,
    input logic [1:0] priv_i,
    output logic overflow_o,
    output logic [31:0] ovf_o,
    input  logic [1:0] op_i,
    input  logic [11:0] addr_i,
    input  logic [63:0] data_i,
    input  logic [$clog2(o3_cfg_pkg::O3_CFG.core.commit_width+1)-1:0] retired_i,
    input  fe_perf_t fe_perf_i,
    input  be_perf_t be_perf_i,
    output logic [63:0] read_o, write_o,
    output logic valid_o, illegal_o, implemented_o,
    output logic [7:0] fe_w_o, be_w_o, fe_num_o, be_num_o, num_hpm_o
);
    csr_req_t req;
    csr_resp_t resp;
    always_comb req = '{op:csr_op_e'(op_i), addr:addr_i, wdata:data_i, write_en:write_i, default:'0};
    assign read_o = resp.rdata;
    assign valid_o = resp.valid;
    assign illegal_o = resp.illegal;
    assign fe_w_o = 8'(PERF_INC_W);
    assign be_w_o = 8'(BE_PERF_INC_W);
    assign fe_num_o = 8'(PE_NUM);
    assign be_num_o = 8'(BE_PERF_NUM);
    assign num_hpm_o = 8'(o3_cfg_pkg::O3_CFG.core.hpm_counters);
    hpm_counters #(.NUM_HPM(o3_cfg_pkg::O3_CFG.core.hpm_counters)) dut (
        .clk_i(clk), .rst_i(rst), .req_valid_i(req_valid_i), .req_i(req),
        .implemented_o(implemented_o), .resp_o(resp), .write_value_o(write_o),
        .retire_count_i(retired_i), .fe_perf_i(fe_perf_i), .be_perf_i(be_perf_i),.priv_i(priv_i),.overflow_o(overflow_o),.scountovf_o(ovf_o));
endmodule
