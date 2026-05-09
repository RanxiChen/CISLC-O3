/**
 * Instruction Fetch Unit (IFU)
 *
 * 当前实现内容：
 * - S0：从 FTQ 消费 fetch block，生成 16B 对齐的 ICache request PC 和 lane mask。
 * - S0 misaligned bypass：若当前真实 fetch PC 不满足 32-bit 指令对齐，
 *   不访问 ICache，直接向外部 fetch buffer 产生一个取指地址未对齐 entry。
 * - S1：暂存 S0 产生的 ICache request，并在外部 fetch buffer 允许继续发请求时
 *   与 ICache s0 端口握手。
 * - S2：双槽 FIFO，保存已发给 ICache 的 request 上下文，并等待 ICache 返回数据。
 * - S3：组合直通，将 ICache 返回的 16B 数据拆成最多 4 条 `fetch_entry_t`。
 *
 * 当前没有实现：
 * - 不内置 Fetch Buffer；外部 `fetch_buffer` 负责前后端交界缓存。
 * - 不实现按 branch age 保留部分在飞请求；redirect 先采用“清空全部 transient IFU 状态”的最小策略。
 * - 不实现分支预测、BTB/BHT/RAS。
 * - 不实现跨页、TLB、PMP 或更细的异常 cause 编码。
 *
 * 后续扩展入口：
 * - `icache_req_allowed_i` 可由外部 fetch buffer 的安全空位阈值驱动，
 *   当前用于提前阻塞 S1 -> ICache request。
 * - `icache_out_error_i` 已接入 `fetch_access_fault`，后续可扩展为更完整异常 cause。
 * - 当前已支持 redirect 驱动的 IFU 精确清除：redirect 当拍 suppress 输出，并在上升沿清空当前 block/S1/S2。
 * - 后续若要保留 older-than-branch 的在飞请求，需要引入更细的 age/filter 机制。
 *
 * 当前阶段说明：
 * - 当前阶段只搭 RTL 功能链路，不写测试代码，不写仿真代码。
 *
 * 逐周期说明：
 * - 周期 N 组合阶段：
 *   1) 若没有当前 block，且 FTQ 有新 entry，S0 组合观察 FTQ entry。
 *   2) 若真实 fetch PC 未对齐，且 IFU 内没有更老待落地请求、fetch buffer ready，
 *      IFU 直接输出一个异常 `fetch_entry_t`，不进入 S1/S2。
 *   3) 正常路径下，S0 在 S1 ready 时把 group_pc/mask/ftq_idx 送入 S1。
 *   4) S1 只有在 ICache ready、S2 有空间、且 `icache_req_allowed_i=1` 时才发请求。
 *   5) S2 头部数据完整且外部 fetch buffer ready 时，S3 组合输出最多 4 条 entry。
 * - 周期 N 上升沿：
 *   1) misaligned bypass fire 时，FTQ entry 被消费，IFU 不保留该 block。
 *   2) S0->S1 fire 时，S1 锁存 request 上下文；block 内 fetch_ptr 视 block 边界推进。
 *   3) S1->ICache fire 时，请求上下文压入 S2。
 *   4) ICache 返回时，数据和 error 位写入 S2 头部 entry。
 *   5) S2->S3 fire 时，S2 头部弹出，必要时 slot1 前移。
 * - 周期 N+1：
 *   1) FTQ 看到 IFU 对上一 entry 的消费。
 *   2) ICache 看到 S1 发出的新 request。
 *   3) 外部 fetch buffer 看到 IFU 新输出的正常或异常 fetch entry。
 */

module ifu
    import ftq_pkg::*;
    import o3_pkg::*;
(
    input  logic       clk_i,
    input  logic       rst_i,

    // ---- FTQ 消费接口 ----
    input  logic       ftq_valid_i,
    output logic       ftq_ready_o,
    input  ftq_entry_t ftq_entry_i,
    input  ftq_idx_t   ftq_idx_i,
    input  logic       redirect_valid_i,

    // ---- ICache S0 请求接口 ----
    output logic       icache_valid_o,
    input  logic       icache_ready_i,
    output logic [PC_WIDTH-1:0] icache_pc_o,

    // ---- ICache 返回接口 ----
    input  logic       icache_out_valid_i,
    input  logic [FTQ_FETCH_WINDOW_BYTES*8-1:0] icache_out_data_i,
    input  logic       icache_out_error_i,

    // ---- 外部 Fetch Buffer 入队接口 ----
    output fetch_entry_t fetch_entry_o [4],
    output logic [3:0]   fetch_valid_o,
    input  logic         fetch_ready_i,

    // ---- 外部 Fetch Buffer 空间余量接口 ----
    input  logic         icache_req_allowed_i
);

    localparam int ICACHE_DATA_WIDTH = FTQ_FETCH_WINDOW_BYTES * 8;

    typedef struct packed {
        logic [PC_WIDTH-1:0]          group_pc;
        logic [3:0]                  mask;
        ftq_idx_t                    ftq_idx;
        logic [ICACHE_DATA_WIDTH-1:0] data;
        logic                        data_valid;
        logic                        fetch_access_fault;
    } s2_entry_t;

    // ========================================================================
    // S0：FTQ block 拉取 + ICache group 生成 + misaligned bypass
    // ========================================================================
    ftq_entry_t          current_block_q;
    ftq_idx_t            current_ftq_idx_q;
    logic [PC_WIDTH-1:0] fetch_ptr_q;
    logic                block_valid_q;

    logic                ftq_fire;
    ftq_entry_t          active_block;
    ftq_idx_t            active_ftq_idx;
    logic [PC_WIDTH-1:0] active_ptr;
    logic [PC_WIDTH-1:0] group_pc;
    logic [3:0]          mask;
    logic                block_done;
    logic                active_misaligned;
    logic                older_empty;
    logic                misalign_fire;
    logic                s0_valid;
    logic                s0_to_s1_valid;

    assign active_block   = ftq_fire ? ftq_entry_i : current_block_q;
    assign active_ftq_idx = ftq_fire ? ftq_idx_i   : current_ftq_idx_q;
    assign active_ptr     = ftq_fire ? ftq_entry_i.start_pc : fetch_ptr_q;
    assign group_pc       = {active_ptr[PC_WIDTH-1:4], 4'b0};

    assign mask[0] = (group_pc      >= active_block.start_pc) && (group_pc      < active_block.end_pc);
    assign mask[1] = (group_pc +  4 >= active_block.start_pc) && (group_pc +  4 < active_block.end_pc);
    assign mask[2] = (group_pc +  8 >= active_block.start_pc) && (group_pc +  8 < active_block.end_pc);
    assign mask[3] = (group_pc + 12 >= active_block.start_pc) && (group_pc + 12 < active_block.end_pc);

    assign block_done = (group_pc + 16 >= active_block.end_pc);
    assign active_misaligned = active_ptr[1:0] != 2'b00;

    // ========================================================================
    // S1：向 ICache 发请求
    // ========================================================================
    logic                s1_valid_q;
    logic [PC_WIDTH-1:0] s1_group_pc_q;
    logic [3:0]          s1_mask_q;
    ftq_idx_t            s1_ftq_idx_q;

    logic                s1_ready_i;
    logic                s0_s1_fire;
    logic                s1_icache_fire;

    // ========================================================================
    // S2：双槽请求上下文 FIFO
    // ========================================================================
    s2_entry_t s2_slot0_q;
    s2_entry_t s2_slot1_q;
    logic      s2_valid0_q;
    logic      s2_valid1_q;

    logic      s2_push;
    logic      s2_has_space;
    logic      s3_ready;
    logic      s2_pop;

    assign older_empty = !s1_valid_q && !s2_valid0_q && !s2_valid1_q;

    assign misalign_fire = !redirect_valid_i
                         && ftq_valid_i
                         && !block_valid_q
                         && (ftq_entry_i.start_pc[1:0] != 2'b00)
                         && older_empty
                         && fetch_ready_i;

    assign ftq_ready_o = !redirect_valid_i
                       && !block_valid_q
                       && (ftq_entry_i.start_pc[1:0] != 2'b00
                           ? (older_empty && fetch_ready_i)
                           : s1_ready_i);

    assign ftq_fire = ftq_valid_i && ftq_ready_o;
    assign s0_valid = !redirect_valid_i && (block_valid_q || (ftq_fire && !active_misaligned));
    assign s0_to_s1_valid = s0_valid && !active_misaligned;
    assign s0_s1_fire = s0_to_s1_valid && s1_ready_i;

    assign s2_has_space = !s2_valid1_q;
    assign icache_valid_o = !redirect_valid_i && s1_valid_q && s2_has_space && icache_req_allowed_i;
    assign icache_pc_o    = s1_group_pc_q;
    assign s1_icache_fire = icache_valid_o && icache_ready_i;
    assign s1_ready_i = !s1_valid_q || s1_icache_fire;

    assign s2_push = s1_icache_fire;
    assign s3_ready = fetch_ready_i;
    assign s2_pop = !redirect_valid_i && s2_valid0_q && s2_slot0_q.data_valid && s3_ready;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            block_valid_q     <= 1'b0;
            current_block_q   <= '0;
            current_ftq_idx_q <= '0;
            fetch_ptr_q       <= '0;
        end else if (redirect_valid_i) begin
            current_block_q   <= '0;
            current_ftq_idx_q <= '0;
            fetch_ptr_q       <= '0;
            block_valid_q     <= 1'b0;
        end else begin
            if (misalign_fire) begin
                current_block_q   <= '0;
                current_ftq_idx_q <= '0;
                fetch_ptr_q       <= '0;
                block_valid_q     <= 1'b0;
            end else if (ftq_fire && !active_misaligned) begin
                current_block_q   <= ftq_entry_i;
                current_ftq_idx_q <= ftq_idx_i;
                fetch_ptr_q       <= group_pc + 16;
                block_valid_q     <= !block_done;
            end else if (s0_s1_fire) begin
                if (block_done) begin
                    block_valid_q <= 1'b0;
                end else begin
                    fetch_ptr_q <= group_pc + 16;
                end
            end
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            s1_valid_q    <= 1'b0;
            s1_group_pc_q <= '0;
            s1_mask_q     <= '0;
            s1_ftq_idx_q  <= '0;
        end else if (redirect_valid_i) begin
            s1_valid_q    <= 1'b0;
            s1_group_pc_q <= '0;
            s1_mask_q     <= '0;
            s1_ftq_idx_q  <= '0;
        end else begin
            s1_valid_q <= s0_s1_fire || (s1_valid_q && !s1_icache_fire);

            if (s0_s1_fire) begin
                s1_group_pc_q <= group_pc;
                s1_mask_q     <= mask;
                s1_ftq_idx_q  <= active_ftq_idx;
            end
        end
    end

    // ========================================================================
    // S2 FIFO 状态更新
    // ========================================================================
    s2_entry_t s2_slot0_d;
    s2_entry_t s2_slot1_d;
    logic      s2_valid0_d;
    logic      s2_valid1_d;

    function automatic s2_entry_t make_s2_push_entry(
        input logic [PC_WIDTH-1:0] group_pc_i,
        input logic [3:0]          mask_i,
        input ftq_idx_t            ftq_idx_i
    );
        begin
            make_s2_push_entry = '{
                group_pc: group_pc_i,
                mask: mask_i,
                ftq_idx: ftq_idx_i,
                data: '0,
                data_valid: 1'b0,
                fetch_access_fault: 1'b0
            };
        end
    endfunction

    always_comb begin
        s2_slot0_d  = s2_slot0_q;
        s2_slot1_d  = s2_slot1_q;
        s2_valid0_d = s2_valid0_q;
        s2_valid1_d = s2_valid1_q;

        unique case ({s2_push, s2_pop})
            2'b01: begin
                s2_slot0_d  = s2_slot1_q;
                s2_valid0_d = s2_valid1_q;
                s2_slot1_d  = '0;
                s2_valid1_d = 1'b0;
            end
            2'b10: begin
                if (!s2_valid0_q) begin
                    s2_slot0_d  = make_s2_push_entry(s1_group_pc_q, s1_mask_q, s1_ftq_idx_q);
                    s2_valid0_d = 1'b1;
                end else begin
                    s2_slot1_d  = make_s2_push_entry(s1_group_pc_q, s1_mask_q, s1_ftq_idx_q);
                    s2_valid1_d = 1'b1;
                end
            end
            2'b11: begin
                if (s2_valid1_q) begin
                    s2_slot0_d  = s2_slot1_q;
                    s2_valid0_d = 1'b1;
                    s2_slot1_d  = make_s2_push_entry(s1_group_pc_q, s1_mask_q, s1_ftq_idx_q);
                    s2_valid1_d = 1'b1;
                end else begin
                    s2_slot0_d  = make_s2_push_entry(s1_group_pc_q, s1_mask_q, s1_ftq_idx_q);
                    s2_valid0_d = 1'b1;
                    s2_slot1_d  = '0;
                    s2_valid1_d = 1'b0;
                end
            end
            default: begin
            end
        endcase
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            s2_slot0_q  <= '0;
            s2_slot1_q  <= '0;
            s2_valid0_q <= 1'b0;
            s2_valid1_q <= 1'b0;
        end else if (redirect_valid_i) begin
            s2_slot0_q  <= '0;
            s2_slot1_q  <= '0;
            s2_valid0_q <= 1'b0;
            s2_valid1_q <= 1'b0;
        end else begin
            s2_slot0_q  <= s2_slot0_d;
            s2_slot1_q  <= s2_slot1_d;
            s2_valid0_q <= s2_valid0_d;
            s2_valid1_q <= s2_valid1_d;

            if (icache_out_valid_i && s2_valid0_d) begin
                s2_slot0_q.data               <= icache_out_data_i;
                s2_slot0_q.data_valid         <= 1'b1;
                s2_slot0_q.fetch_access_fault <= icache_out_error_i;
            end
        end
    end

    // ========================================================================
    // S3 / misaligned bypass：输出给外部 fetch buffer
    // ========================================================================
    logic [3:0]          s3_inst_valid;
    logic [ILEN-1:0]     s3_inst [4];
    logic [PC_WIDTH-1:0] s3_pc [4];
    ftq_idx_t            s3_ftq_idx;

    assign s3_inst[0] = s2_pop ? s2_slot0_q.data[31:0]    : '0;
    assign s3_inst[1] = s2_pop ? s2_slot0_q.data[63:32]   : '0;
    assign s3_inst[2] = s2_pop ? s2_slot0_q.data[95:64]   : '0;
    assign s3_inst[3] = s2_pop ? s2_slot0_q.data[127:96]  : '0;

    assign s3_pc[0] = s2_pop ? (s2_slot0_q.group_pc + 0)  : '0;
    assign s3_pc[1] = s2_pop ? (s2_slot0_q.group_pc + 4)  : '0;
    assign s3_pc[2] = s2_pop ? (s2_slot0_q.group_pc + 8)  : '0;
    assign s3_pc[3] = s2_pop ? (s2_slot0_q.group_pc + 12) : '0;

    assign s3_inst_valid[0] = s2_pop ? s2_slot0_q.mask[0] : 1'b0;
    assign s3_inst_valid[1] = s2_pop ? s2_slot0_q.mask[1] : 1'b0;
    assign s3_inst_valid[2] = s2_pop ? s2_slot0_q.mask[2] : 1'b0;
    assign s3_inst_valid[3] = s2_pop ? s2_slot0_q.mask[3] : 1'b0;
    assign s3_ftq_idx = s2_pop ? s2_slot0_q.ftq_idx : '0;

    always_comb begin
        fetch_valid_o = 4'b0;
        for (int lane = 0; lane < 4; lane++) begin
            fetch_entry_o[lane] = '0;
        end

        if (redirect_valid_i) begin
            // Redirect is a correctness event: do not emit any stale IFU output
            // in the same cycle we are clearing internal transient state.
        end else if (misalign_fire) begin
            fetch_valid_o[0] = 1'b1;
            fetch_entry_o[0].valid = 1'b1;
            fetch_entry_o[0].pc = ftq_entry_i.start_pc;
            fetch_entry_o[0].instruction = '0;
            fetch_entry_o[0].fetch_addr_misaligned = 1'b1;
            fetch_entry_o[0].fetch_access_fault = 1'b0;
            fetch_entry_o[0].ftq_idx = ftq_idx_i;
        end else begin
            for (int lane = 0; lane < 4; lane++) begin
                fetch_valid_o[lane] = s3_inst_valid[lane];
                fetch_entry_o[lane].valid = s3_inst_valid[lane];
                fetch_entry_o[lane].pc = s3_pc[lane];
                fetch_entry_o[lane].instruction = s3_inst[lane];
                fetch_entry_o[lane].fetch_addr_misaligned = 1'b0;
                fetch_entry_o[lane].fetch_access_fault = s3_inst_valid[lane]
                                                       && s2_slot0_q.fetch_access_fault;
                fetch_entry_o[lane].ftq_idx = s3_ftq_idx;
            end
        end
    end

endmodule
