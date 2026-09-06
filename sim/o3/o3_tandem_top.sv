/**
 * CISLC-O3 Verilator Tandem trace top
 *
 * 当前已经实现：
 * - 实例化完整o3_core，并原样透传时钟、复位和ICache refill接口。
 * - 将core已有的packed retire_info拆成每个退休lane独立的基础类型端口，
 *   避免C++仿真器依赖SystemVerilog packed struct的位布局。
 * - 输出只描述已经从ROB队头按序退休的体系结构结果，不暴露推测状态。
 *
 * 当前没有实现：
 * - 不运行Spike或其他参考模型，不在RTL内判断执行结果是否正确。
 * - 不输出Load/Store地址、异常、CSR或特权级信息。
 * - 不输出Kanata或任何微架构阶段事件。
 *
 * 逐周期说明：
 * - 周期N组合阶段，core的ROB给出本拍可以退休的连续前缀，本模块将其展开。
 * - 周期N上升沿，ROB真正释放这些表项；外部驱动必须在上升沿前采样本拍记录。
 * - 周期N+1，输出对应新的ROB队头，旧记录不会再次出现。
 */
module o3_tandem_top
    import o3_pkg::*;
(
    input  logic clk_i,
    input  logic rst_i,
    input  logic flush_i,
    input  logic [PC_WIDTH-1:0] reset_pc_i,

    output logic [PC_WIDTH-1:0] refill_req_pc_o,
    output logic                refill_req_valid_o,
    input  logic                refill_resp_valid_i,
    input  logic [PC_WIDTH-1:0] refill_resp_pc_i,
    input  logic                refill_resp_error_i,
    input  logic [ICACHE_LINE_BYTES*8-1:0] refill_resp_data_i,

    output logic done_o,
    output logic [63:0] retired_inst_count_o,

    output logic [BACKEND_NUM_INT_ALUS-1:0] tandem_valid_o,
    output logic [BACKEND_NUM_INT_ALUS-1:0] tandem_rd_write_o,
    output logic [INST_ID_WIDTH-1:0] tandem_instruction_id_o [BACKEND_NUM_INT_ALUS-1:0],
    output logic [ROB_IDX_WIDTH-1:0] tandem_rob_idx_o [BACKEND_NUM_INT_ALUS-1:0],
    output logic [PC_WIDTH-1:0] tandem_pc_o [BACKEND_NUM_INT_ALUS-1:0],
    output logic [ILEN-1:0] tandem_instruction_o [BACKEND_NUM_INT_ALUS-1:0],
    output logic [REG_ADDR_WIDTH-1:0] tandem_rd_o [BACKEND_NUM_INT_ALUS-1:0],
    output logic [XLEN-1:0] tandem_rd_wdata_o [BACKEND_NUM_INT_ALUS-1:0]
);
    retire_info_t retire_info [BACKEND_NUM_INT_ALUS-1:0];

    o3_core u_core (
        .clk_i                (clk_i),
        .rst_i                (rst_i),
        .flush_i              (flush_i),
        .reset_pc_i           (reset_pc_i),
        .refill_req_pc_o      (refill_req_pc_o),
        .refill_req_valid_o   (refill_req_valid_o),
        .refill_resp_valid_i  (refill_resp_valid_i),
        .refill_resp_pc_i     (refill_resp_pc_i),
        .refill_resp_error_i  (refill_resp_error_i),
        .refill_resp_data_i   (refill_resp_data_i),
        .done_o               (done_o),
        .retired_inst_count_o (retired_inst_count_o),
        .retire_info_o        (retire_info)
    );

    for (genvar lane = 0; lane < BACKEND_NUM_INT_ALUS; lane++) begin : gen_tandem_retire
        assign tandem_valid_o[lane]          = retire_info[lane].valid;
        assign tandem_rd_write_o[lane]       = retire_info[lane].rd_write_en;
        assign tandem_instruction_id_o[lane] = retire_info[lane].instruction_id;
        assign tandem_rob_idx_o[lane]        = retire_info[lane].rob_idx;
        assign tandem_pc_o[lane]             = retire_info[lane].pc;
        assign tandem_instruction_o[lane]    = retire_info[lane].instruction;
        assign tandem_rd_o[lane]             = retire_info[lane].rd;
        assign tandem_rd_wdata_o[lane]       = retire_info[lane].rd_wdata;
    end
endmodule
