/**
 * L9 CONV wrapper: pinned CVFPU split operation group with identity side table,
 * stable common result holding slot and same-cycle recovery filtering.
 * Uses o3_fpu_opgroup (defined in fpu_fma_fu.sv); CONV also carries raw FMV bits.
 * B33 early wakeup for FP FUs is deferred to performance work; actual PRF grant wakes.
 * 当前实现状态：闭环简化（L9）；lint/功能测试未运行。
 */
module fpu_conv_fu import o3_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG
) (
    input logic clk,rst,flush_all_i,
    input logic req_valid_i,
    output logic req_ready_o,
    input o3_types_pkg::fpu_req_t req_i,
    output logic resp_valid_o,
    input logic resp_ready_i,
    output o3_types_pkg::fpu_resp_t resp_o,
    input branch_resolution_t resolution_i,
    output logic busy_o
);
    o3_fpu_opgroup #(.CFG(CFG),.GROUP(fpnew_pkg::CONV)) u_transport (.*);
endmodule
