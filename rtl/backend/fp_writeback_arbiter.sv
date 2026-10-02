/**
 * FP 写回仲裁 —— 浮点物理寄存器域的写口分配
 *
 * 作用（B14/B15）：
 * - 候选：两个 FMA、DIVSQRT、MISC（FSGNJ/FMIN/FMAX）、CONV（I2F/F2F/FMV.F）、FLW/FLD 返回。
 * - 结果仍有效且取得 FP 写口时，写 FP PRF、置 FP ready、唤醒、报告 ROB 完成，并把 fflags
 *   随该指令写入 ROB。未取得写口的结果留在各 FU 保持槽（consume_o=0）。
 * - 被误预测取消的结果直接消费且不写；迟到结果不得覆盖复用后的寄存器。
 *
 * 待定：FP 写口数（CFG.exec.fp_prf_write_ports）；同拍竞争的选择规则（年龄优先为建议）；
 * 与整数写回仲裁共享 ROB complete 端口的方式。
 *
 * 当前实现状态：空壳。只有端口与注释，没有逻辑，输出未驱动。
 *
 * 逐周期说明（目标）：本模块纯组合。周期 N 选出 grant；上升沿写 FP PRF、更新 ready 与 ROB。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module fp_writeback_arbiter
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    localparam int WRITE_PORTS = CFG.exec.fp_prf_write_ports,
    localparam int NUM_SRC     = CFG.exec.num_fma + CFG.exec.num_fdivsqrt
                               + CFG.exec.num_fmisc + CFG.exec.num_fconv + 1  // +1：FP load 返回
) (
    input  o3_types_pkg::wb_req_t      src_i [NUM_SRC],
    output logic                       consume_o [NUM_SRC],
    input  logic [ROB_IDX_WIDTH-1:0]   rob_head_i,
    input  branch_resolution_t         resolution_i,

    output logic                       prf_wr_en_o   [WRITE_PORTS],
    output logic [PREG_IDX_WIDTH-1:0]  prf_wr_addr_o [WRITE_PORTS],
    output logic [XLEN-1:0]            prf_wr_data_o [WRITE_PORTS],

    output logic                       complete_valid_o  [NUM_SRC],
    output logic [ROB_IDX_WIDTH-1:0]   complete_idx_o    [NUM_SRC],
    output logic [o3_isa_pkg::FFLAGS_W-1:0] complete_fflags_o [NUM_SRC]
);
    // 未实现：年龄选择与写口分配。
endmodule
