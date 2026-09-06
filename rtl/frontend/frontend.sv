/**
 * Frontend Top
 *
 * 当前已经实现：
 * - 实例化 BPU、FTQ、IFU、ICache 和独立 fetch_buffer。
 * - 连接 BPU -> FTQ 的 fetch block 生成链路。
 * - 连接 FTQ -> IFU 的 fetch block 消费链路。
 * - 连接 IFU -> ICache 的取指 request 和 ICache -> IFU 的返回链路。
 * - 连接 IFU -> fetch_buffer 的入队链路。
 * - 将 fetch_buffer 的出队口作为 frontend 顶层输出，暂不直连 backend。
 * - 将 ICache refill request/response 从 frontend 顶层透出。
 *
 * 当前恢复链路：
 * - branch resolution已连接BPU/FTQ/IFU/ICache请求状态和fetch buffer恢复。
 * - Commit释放计数已连接FTQ release head。
 * 当前没有实现：
 * - 本模块不直接实例化backend，真实连接位于o3_core。
 * - BPU 当前只实现顺序 not-taken block 生成，不实现 BTB/BHT/RAS。
 * - 不写测试代码和仿真代码。
 *
 * 后续扩展入口：
 * - 后续 backend 接入时，可直接消费 `fetch_valid_o/fetch_ready_i`
 *   和 `fetch_entry_o` 组成的 fetch group。
 * - 后续可在现有训练观察口后加入真实BTB/BHT/RAS。
 * - 后续 refill 端口可接 L2/总线/测试内存模型。
 *
 * 逐周期说明：
 * - 周期 N 组合阶段：
 *   1) BPU 在 FTQ 未满时向 FTQ 提供下一段顺序 fetch block。
 *   2) FTQ 向 IFU 提供下一段已分配且尚未消费的 fetch block。
 *   3) 串行IFU在REQ状态且fetch buffer有安全空位时保持16B ICache request。
 *   4) ICache 返回数据后，IFU 拆成最多 4 条 `fetch_entry_t` 并送 fetch_buffer。
 *   5) fetch_buffer 若非空，顶层 `fetch_valid_o=1`，并输出最多 4 条 entry。
 * - 周期 N 上升沿：
 *   1) BPU 入队成功则推进内部顺序 PC。
 *   2) FTQ 入队成功则推进 alloc_tail；IFU 消费成功则推进 ifu_head。
 *   3) ICache 接收 request 或处理 refill FSM。
 *   4) fetch_buffer 接收入队 entry 或按 `fetch_ready_i` 出队。
 *   5) mispredict优先清除错误路径状态并把BPU PC改为redirect_pc。
 * - 周期 N+1：
 *   1) IFU 看到 fetch_buffer 更新后的 `icache_req_allowed_o`。
 *   2) 顶层输出更新后的 fetch group。
 */
module frontend
    import o3_pkg::*;
    import ftq_pkg::*;
(
    input  logic clk_i,
    input  logic rst_i,
    input  logic flush_i,
    input  logic [PC_WIDTH-1:0] reset_pc_i,
    input  branch_resolution_t branch_resolution_i,
    input  logic [$clog2(BACKEND_MACHINE_WIDTH+1)-1:0] ftq_release_count_i,

    output logic [PC_WIDTH-1:0] refill_req_pc_o,
    output logic                refill_req_valid_o,
    input  logic                refill_resp_valid_i,
    input  logic [PC_WIDTH-1:0] refill_resp_pc_i,
    input  logic                refill_resp_error_i,
    input  logic [ICACHE_LINE_BYTES*8-1:0] refill_resp_data_i,
    input  logic                         itcm_init_valid_i,
    input  logic [PC_WIDTH-1:0]          itcm_init_addr_i,
    input  logic [63:0]                  itcm_init_data_i,
    input  logic [7:0]                   itcm_init_wmask_i,

    output fetch_entry_t fetch_entry_o [4],
    output logic         fetch_valid_o,
    output logic [3:0]   fetch_valid_mask_o,
    input  logic         fetch_ready_i

    `ifdef O3_FRONTEND_DEBUG
    ,output logic       dbg_ftq_ifu_fire_o
    ,output logic       dbg_ftq_bpu_fire_o
    ,output ftq_idx_t   dbg_ftq_alloc_tail_o
    ,output ftq_idx_t   dbg_ftq_ifu_head_o
    ,output ftq_idx_t   dbg_ftq_release_head_o
    ,output logic [$clog2(FTQ_DEPTH+1)-1:0] dbg_ftq_allocated_count_o
    `endif
);

    logic       bpu_ftq_valid;
    logic       bpu_ftq_ready;
    ftq_entry_t bpu_ftq_entry;

    logic       ftq_ifu_valid;
    logic       ftq_ifu_ready;
    ftq_entry_t ftq_ifu_entry;
    ftq_idx_t   ftq_ifu_idx;

    logic                         ifu_icache_valid;
    logic                         ifu_icache_ready;
    logic [PC_WIDTH-1:0]          ifu_icache_pc;
    logic                         icache_ifu_valid;
    logic [FTQ_FETCH_WINDOW_BYTES*8-1:0] icache_ifu_data;
    logic                         icache_ifu_error;
    logic                         icache_out_hit_unused;
    logic [PC_WIDTH-1:0]          icache_out_pc_unused;

    fetch_entry_t ifu_fetch_entry [4];
    logic [3:0]   ifu_fetch_valid;
    logic         ifu_fetch_ready;
    logic         icache_req_allowed;

    fetch_entry_t fb_deq_entry [4];
    logic         fb_deq_valid;
    logic         frontend_kill;
    logic [BACKEND_MACHINE_WIDTH-1:0] ftq_train_valid_unused;
    ftq_entry_t ftq_train_entry_unused [BACKEND_MACHINE_WIDTH-1:0];

    assign frontend_kill = flush_i
                         || (branch_resolution_i.valid && branch_resolution_i.mispredict);

    bpu u_bpu (
        .clk_i       (clk_i),
        .rst_i       (rst_i),
        .reset_pc_i  (reset_pc_i),
        .flush_i     (flush_i),
        .redirect_valid_i(branch_resolution_i.valid && branch_resolution_i.mispredict),
        .redirect_pc_i(branch_resolution_i.redirect_pc),
        .ftq_valid_o (bpu_ftq_valid),
        .ftq_ready_i (bpu_ftq_ready),
        .ftq_entry_o (bpu_ftq_entry)
    );

    ftq u_ftq (
        .clk_i         (clk_i),
        .rst_i         (rst_i),
        .flush_i       (flush_i),
        .bpu_valid_i   (bpu_ftq_valid),
        .bpu_ready_o   (bpu_ftq_ready),
        .bpu_entry_i   (bpu_ftq_entry),
        .ifu_valid_o   (ftq_ifu_valid),
        .ifu_ready_i   (ftq_ifu_ready),
        .ifu_entry_o   (ftq_ifu_entry),
        .ifu_ftq_idx_o (ftq_ifu_idx),
        .release_count_i(ftq_release_count_i),
        .resolution_i  (branch_resolution_i),
        .train_valid_o (ftq_train_valid_unused),
        .train_entry_o (ftq_train_entry_unused)

        `ifdef O3_FRONTEND_DEBUG
        ,.dbg_ifu_fire_o        (dbg_ftq_ifu_fire_o)
        ,.dbg_bpu_fire_o        (dbg_ftq_bpu_fire_o)
        ,.dbg_alloc_tail_o      (dbg_ftq_alloc_tail_o)
        ,.dbg_ifu_head_o        (dbg_ftq_ifu_head_o)
        ,.dbg_release_head_o    (dbg_ftq_release_head_o)
        ,.dbg_allocated_count_o (dbg_ftq_allocated_count_o)
        `endif
    );

    ifu u_ifu (
        .clk_i                (clk_i),
        .rst_i                (rst_i),
        .flush_i              (frontend_kill),
        .ftq_valid_i          (ftq_ifu_valid),
        .ftq_ready_o          (ftq_ifu_ready),
        .ftq_entry_i          (ftq_ifu_entry),
        .ftq_idx_i            (ftq_ifu_idx),
        .icache_valid_o       (ifu_icache_valid),
        .icache_ready_i       (ifu_icache_ready),
        .icache_pc_o          (ifu_icache_pc),
        .icache_out_valid_i   (icache_ifu_valid),
        .icache_out_data_i    (icache_ifu_data),
        .icache_out_error_i   (icache_ifu_error),
        .fetch_entry_o        (ifu_fetch_entry),
        .fetch_valid_o        (ifu_fetch_valid),
        .fetch_ready_i        (ifu_fetch_ready),
        .icache_req_allowed_i (icache_req_allowed)
    );

    ICache #(
        .ADDR_WIDTH               (PC_WIDTH),
        .ICACHE_BLOCK_SIZE_BYTES  (ICACHE_LINE_BYTES),
        .FETCH_BYTES              (FTQ_FETCH_WINDOW_BYTES)
    ) u_icache (
        .clk                 (clk_i),
        .rst                 (rst_i),
        .flush               (flush_i),
        .kill                (branch_resolution_i.valid && branch_resolution_i.mispredict),
        .s0_valid            (ifu_icache_valid),
        .s0_ready            (ifu_icache_ready),
        .s0_pc               (ifu_icache_pc),
        .refill_req_valid    (refill_req_valid_o),
        .refill_req_pc       (refill_req_pc_o),
        .refill_resp_valid   (refill_resp_valid_i),
        .refill_resp_pc      (refill_resp_pc_i),
        .refill_resp_error   (refill_resp_error_i),
        .refill_resp_data    (refill_resp_data_i),
        .itcm_init_valid_i   (itcm_init_valid_i),
        .itcm_init_addr_i    (itcm_init_addr_i),
        .itcm_init_data_i    (itcm_init_data_i),
        .itcm_init_wmask_i   (itcm_init_wmask_i),
        .out_valid           (icache_ifu_valid),
        .out_hit             (icache_out_hit_unused),
        .out_pc              (icache_out_pc_unused),
        .out_data            (icache_ifu_data),
        .out_error           (icache_ifu_error)
    );

    fetch_buffer u_fetch_buffer (
        .clk_i                (clk_i),
        .rst_i                (rst_i),
        .flush_i              (frontend_kill),
        .enq_entry_i          (ifu_fetch_entry),
        .enq_valid_i          (ifu_fetch_valid),
        .enq_ready_o          (ifu_fetch_ready),
        .deq_entry_o          (fb_deq_entry),
        .deq_valid_o          (fb_deq_valid),
        .deq_ready_i          (fetch_ready_i),
        .icache_req_allowed_o (icache_req_allowed)
    );

    always_comb begin
        for (int i = 0; i < 4; i++) begin
            fetch_entry_o[i] = fb_deq_entry[i];
            fetch_valid_mask_o[i] = fb_deq_valid && fb_deq_entry[i].valid;
        end

        fetch_valid_o = fb_deq_valid;
    end

    logic unused_icache_outputs;
    assign unused_icache_outputs = icache_out_hit_unused ^ ^icache_out_pc_unused;

endmodule
