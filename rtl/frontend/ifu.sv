
/**
 * Instruction Fetch Unit (IFU)
 *
 * 当前实现内容：
 * - S0：FTQ block 拉取 + group_pc / mask 组合生成（零气泡）
 * - S1：向 icache 发请求（接收 S0、暂存、驱动 icache s0 接口）
 * - S2：双槽移位 FIFO，暂存请求上下文 + icache 返回数据
 * - S3：组合直通，16B → 4×32bit 指令拆分，mask 过滤 valid
 * - Fetch Buffer：统一环形 buffer（16 entry），4 写入按序写入，4 读出
 *
 * 当前未实现内容：
 * - flush / redirect / exception 处理
 * - 跨 16B 边界后续 group（当前 block 内已支持）
 * - 后端 decode 详细接口收敛
 *
 * 流水线结构：
 *   FTQ → S0 → S1 → icache s0 → icache s1/out → S2 → S3 → Fetch Buffer → 后端
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

    // ---- ICache S0 请求接口 ----
    output logic       icache_valid_o,
    input  logic       icache_ready_i,
    output logic [PC_WIDTH-1:0] icache_pc_o,

    // ---- ICache 返回接口 ----
    input  logic       icache_out_valid_i,
    input  logic [FTQ_FETCH_WINDOW_BYTES*8-1:0] icache_out_data_i,

    // ---- Fetch Buffer 后端读出接口 ----
    output logic [3:0]       fb_deq_valid_o,
    output logic [ILEN-1:0]  fb_deq_inst_o [4],
    output logic [PC_WIDTH-1:0] fb_deq_pc_o [4],
    output ftq_idx_t         fb_deq_ftq_idx_o,
    input  logic             fb_deq_ready_i
);

    // ========================================================================
    // 内部类型定义
    // ========================================================================
    localparam int ICACHE_DATA_WIDTH = FTQ_FETCH_WINDOW_BYTES * 8;  // 128 bit

    // S2 暂存槽位类型：请求上下文 + icache 返回数据
    typedef struct packed {
        logic [PC_WIDTH-1:0]        group_pc;
        logic [3:0]                 mask;
        ftq_idx_t                   ftq_idx;
        logic [ICACHE_DATA_WIDTH-1:0] data;
        logic                       data_valid;
    } s2_entry_t;

    // Fetch Buffer 参数
    localparam int FB_DEPTH = 16;
    localparam int FB_PTR_WIDTH = $clog2(FB_DEPTH);
    localparam int FB_PTR_MASK = FB_DEPTH - 1;

    typedef struct packed {
        logic                valid;
        logic [ILEN-1:0]     inst;
        logic [PC_WIDTH-1:0] pc;
        ftq_idx_t            ftq_idx;
    } fb_entry_t;

    // ========================================================================
    // S0 阶段：FTQ block 拉取 + group_pc / mask 生成
    // ========================================================================
    ftq_entry_t          current_block_q;
    ftq_idx_t            current_ftq_idx_q;
    logic [PC_WIDTH-1:0] fetch_ptr_q;
    logic                block_valid_q;

    logic ftq_fire;
    ftq_entry_t active_block;
    logic [PC_WIDTH-1:0] active_ptr;
    logic [PC_WIDTH-1:0] group_pc;
    logic [3:0] mask;
    logic block_done;

    assign ftq_fire    = ftq_valid_i && ftq_ready_o;
    assign active_block = ftq_fire ? ftq_entry_i : current_block_q;
    assign active_ptr   = ftq_fire ? ftq_entry_i.start_pc : fetch_ptr_q;
    assign group_pc    = {active_ptr[PC_WIDTH-1:4], 4'b0};

    assign mask[0] = (group_pc      >= active_block.start_pc) && (group_pc      < active_block.end_pc);
    assign mask[1] = (group_pc +  4 >= active_block.start_pc) && (group_pc +  4 < active_block.end_pc);
    assign mask[2] = (group_pc +  8 >= active_block.start_pc) && (group_pc +  8 < active_block.end_pc);
    assign mask[3] = (group_pc + 12 >= active_block.start_pc) && (group_pc + 12 < active_block.end_pc);

    assign block_done = (group_pc + 16 >= active_block.end_pc);

    logic s1_valid_o;
    assign s1_valid_o  = block_valid_q || ftq_fire;

    // ========================================================================
    // S1 阶段：向 icache 发请求
    // ========================================================================
    logic                s1_valid_q;
    logic [PC_WIDTH-1:0] s1_group_pc_q;
    logic [3:0]          s1_mask_q;
    ftq_idx_t            s1_ftq_idx_q;
    ftq_pc_t             s1_start_pc_q;
    ftq_pc_t             s1_end_pc_q;

    logic s1_ready_i;
    logic s0_s1_fire;
    logic s1_icache_fire;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            block_valid_q     <= 1'b0;
            current_block_q   <= '0;
            current_ftq_idx_q <= '0;
            fetch_ptr_q       <= '0;
        end else begin
            if (ftq_fire) begin
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
            s1_valid_q <= 1'b0;
        end else begin
            s1_valid_q <= s0_s1_fire || (s1_valid_q && !s1_icache_fire);

            if (s0_s1_fire) begin
                s1_group_pc_q <= group_pc;
                s1_mask_q     <= mask;
                s1_ftq_idx_q  <= ftq_fire ? ftq_idx_i : current_ftq_idx_q;
                s1_start_pc_q <= active_block.start_pc;
                s1_end_pc_q   <= active_block.end_pc;
            end
        end
    end

    assign icache_valid_o = s1_valid_q;
    assign icache_pc_o    = s1_group_pc_q;

    // ========================================================================
    // S2 阶段：双槽移位 FIFO（暂存请求上下文 + 等 icache 数据）
    // ========================================================================
    s2_entry_t s2_slot0_q;
    s2_entry_t s2_slot1_q;
    logic      s2_valid0_q;
    logic      s2_valid1_q;

    // S2 压入条件：S1 向 icache 发请求
    logic s2_push;
    assign s2_push = s1_icache_fire;

    // S2 空间状态（用于 backpressure 到 S1）
    logic s2_has_space;
    assign s2_has_space = !s2_valid1_q;

    // S1 ready 需要 S2 有空间才能压入
    // 注意：s1_ready_i 在上面定义了，但需要加上 s2_has_space 条件
    // 这里重新赋值
    assign s1_ready_i = (!s1_valid_q || icache_ready_i) && s2_has_space;

    // S2 弹出条件：头部有完整数据（上下文 + icache 数据）且下游 fetch buffer 有空间
    logic s3_ready;
    logic s2_pop;
    assign s2_pop = s2_valid0_q && s2_slot0_q.data_valid && s3_ready;

    // S2 下一状态（组合逻辑）
    s2_entry_t s2_slot0_d;
    s2_entry_t s2_slot1_d;
    logic      s2_valid0_d;
    logic      s2_valid1_d;

    always_comb begin
        s2_slot0_d  = s2_slot0_q;
        s2_slot1_d  = s2_slot1_q;
        s2_valid0_d = s2_valid0_q;
        s2_valid1_d = s2_valid1_q;

        case ({s2_push, s2_pop})
            2'b01: begin // 只弹出：slot1 → slot0
                s2_slot0_d  = s2_slot1_q;
                s2_valid0_d = s2_valid1_q;
                s2_valid1_d = 1'b0;
            end
            2'b10: begin // 只压入
                if (!s2_valid0_q) begin
                    s2_slot0_d.group_pc  = s1_group_pc_q;
                    s2_slot0_d.mask      = s1_mask_q;
                    s2_slot0_d.ftq_idx   = s1_ftq_idx_q;
                    s2_slot0_d.data      = '0;
                    s2_slot0_d.data_valid = 1'b0;
                    s2_valid0_d = 1'b1;
                end else begin
                    s2_slot1_d.group_pc  = s1_group_pc_q;
                    s2_slot1_d.mask      = s1_mask_q;
                    s2_slot1_d.ftq_idx   = s1_ftq_idx_q;
                    s2_slot1_d.data      = '0;
                    s2_slot1_d.data_valid = 1'b0;
                    s2_valid1_d = 1'b1;
                end
            end
            2'b11: begin // 同拍收发
                if (s2_valid1_q) begin
                    // slot0 弹出给 S3，slot1 → slot0，新请求进 slot1
                    s2_slot0_d  = s2_slot1_q;
                    s2_valid0_d = 1'b1;
                    s2_slot1_d.group_pc  = s1_group_pc_q;
                    s2_slot1_d.mask      = s1_mask_q;
                    s2_slot1_d.ftq_idx   = s1_ftq_idx_q;
                    s2_slot1_d.data      = '0;
                    s2_slot1_d.data_valid = 1'b0;
                    s2_valid1_d = 1'b1;
                end else begin
                    // 只有 slot0，弹出后进新数据
                    s2_slot0_d.group_pc  = s1_group_pc_q;
                    s2_slot0_d.mask      = s1_mask_q;
                    s2_slot0_d.ftq_idx   = s1_ftq_idx_q;
                    s2_slot0_d.data      = '0;
                    s2_slot0_d.data_valid = 1'b0;
                    s2_valid0_d = 1'b1;
                    s2_valid1_d = 1'b0;
                end
            end
            default: ; // 2'b00：无变化
        endcase
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            s2_valid0_q <= 1'b0;
            s2_valid1_q <= 1'b0;
        end else begin
            s2_slot0_q  <= s2_slot0_d;
            s2_slot1_q  <= s2_slot1_d;
            s2_valid0_q <= s2_valid0_d;
            s2_valid1_q <= s2_valid1_d;

            // icache 返回：给头部 slot0 写数据
            if (icache_out_valid_i && s2_valid0_q) begin
                s2_slot0_q.data       <= icache_out_data_i;
                s2_slot0_q.data_valid <= 1'b1;
            end
        end
    end

    // ========================================================================
    // S3 阶段：组合直通，指令拆分 + mask 过滤
    // ========================================================================
    logic [3:0]       s3_inst_valid;
    logic [ILEN-1:0]  s3_inst [4];
    logic [PC_WIDTH-1:0] s3_pc [4];
    ftq_idx_t         s3_ftq_idx;

    // S3 纯组合：当 S2 弹出时输出有效数据，否则全 0
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

    // ========================================================================
    // Fetch Buffer：统一环形 buffer（4 写入按序，4 读出）
    // ========================================================================
    fb_entry_t fb_entries [FB_DEPTH];
    logic [FB_PTR_WIDTH-1:0] fb_head_q;
    logic [FB_PTR_WIDTH-1:0] fb_tail_q;
    logic [FB_PTR_WIDTH:0]   fb_count_q;  // 多 1 bit 区分空满

    // 统计 S3 当前要写入的有效指令数
    logic [2:0] s3_write_count;
    assign s3_write_count = {2'b0, s3_inst_valid[0]} + {2'b0, s3_inst_valid[1]}
                          + {2'b0, s3_inst_valid[2]} + {2'b0, s3_inst_valid[3]};

    // fetch buffer 有空间：保守策略，至少能接收 4 条（因为不知道下一个 group 多少条）
    // 后续可优化为精确判断（剩余 >= s3_write_count）
    logic fb_has_space;
    assign fb_has_space = (fb_count_q <= FB_DEPTH - 4);

    // S3 ready = fetch buffer 有空间
    assign s3_ready = fb_has_space;

    // S0 ready 也需要 fetch buffer 有空间（backpressure 到 FTQ）
    assign ftq_ready_o = !block_valid_q && fb_has_space;

    // Fetch Buffer 读出数量
    logic [2:0] deq_count;
    assign deq_count = (fb_count_q >= 4) ? 3'd4 : 3'(fb_count_q);

    // Fetch Buffer 统一更新：写入 + 读出
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            fb_head_q  <= '0;
            fb_tail_q  <= '0;
            fb_count_q <= '0;
        end else begin
            if (s2_pop) begin
                int write_idx;
                write_idx = 0;
                for (int i = 0; i < 4; i++) begin
                    if (s3_inst_valid[i]) begin
                        fb_entries[(fb_tail_q + FB_PTR_WIDTH'(write_idx)) & FB_PTR_WIDTH'(FB_PTR_MASK)] <= '{
                            valid:   1'b1,
                            inst:    s3_inst[i],
                            pc:      s3_pc[i],
                            ftq_idx: s3_ftq_idx
                        };
                        write_idx = write_idx + 1;
                    end
                end
                fb_tail_q  <= fb_tail_q  + FB_PTR_WIDTH'(s3_write_count);
            end

            if (fb_deq_ready_i) begin
                fb_head_q <= fb_head_q + FB_PTR_WIDTH'(deq_count);
            end

            // count 同时加减
            fb_count_q <= fb_count_q
                        + (s2_pop        ? FB_PTR_WIDTH'(s3_write_count) : '0)
                        - (fb_deq_ready_i ? FB_PTR_WIDTH'(deq_count)      : '0);
        end
    end

    // 组合输出：后端读出
    always_comb begin
        fb_deq_valid_o = 4'b0;
        for (int i = 0; i < 4; i++) begin
            if (i < deq_count) begin
                fb_deq_inst_o[i] = fb_entries[(fb_head_q + FB_PTR_WIDTH'(i)) & FB_PTR_WIDTH'(FB_PTR_MASK)].inst;
                fb_deq_pc_o[i]   = fb_entries[(fb_head_q + FB_PTR_WIDTH'(i)) & FB_PTR_WIDTH'(FB_PTR_MASK)].pc;
                fb_deq_valid_o[i] = 1'b1;
            end else begin
                fb_deq_inst_o[i] = '0;
                fb_deq_pc_o[i]   = '0;
                fb_deq_valid_o[i] = 1'b0;
            end
        end
        fb_deq_ftq_idx_o = fb_entries[fb_head_q & FB_PTR_WIDTH'(FB_PTR_MASK)].ftq_idx;
    end

endmodule
