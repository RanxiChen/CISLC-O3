/**
 *
 * 【2026-10-02 框架：目标机制与缺口】
 * - 需要补充：replay 等待原因（bank 冲突、DMA 行保护、SQ 数据未就绪、MSHR 满、TLB miss）与唤醒，
 *   避免每拍盲目重试；重放不重新 rename、不重新分配 ROB/LQ、不要求退回 IQ（B04）。
 * - 事务身份：现有 1 位 generation 不能作为多事务在途的安全保证，改为 lq_tag_t（代际宽度待定）。
 * - 未知地址旧 store（B32，2026-10-02 已定）：load 等待相关依赖条件解除（等待原因 LDW_OLDER_STORE_ADDR，
 *   由该 store 地址写入 SQ 或被取消的事件唤醒）；不能实现成固定拍数超时后无条件越过；首版不加入
 *   推测越过与违例恢复机制。
 * - A/D 排序（B36）：更老 store 的 needs_D 慢路径未完成前，年轻访存不得越过（LDW_AD_ORDER）；已经执行
 *   的年轻访问纳入重放/排序处理。
 * - ROB 按序退休释放 LQ（保持）。目标端口（t_*）未接入。
 * Load Queue
 *
 * Rename按程序顺序分配entry；AGU按lq_idx补写有效地址，LSU发出SRAM请求时
 * 记录outstanding。每次重新分配都会翻转generation，SRAM返回携带
 * {generation,lq_idx}，从而能够丢弃flush后迟到或entry复用后的旧响应。
 * Load只在ROB顺序退休时从队头释放。
 *
 * 周期N组合阶段给出分配索引、容量、当前执行entry的generation以及响应是否仍存活；
 * 周期N上升沿原子执行allocate/AGU/request/response/commit，mispredict恢复优先；
 * 周期N+1可见更新后的entry状态。本阶段不实现Load replay或异常。
 */
// 当前实现状态：闭环简化（L3）；四宽分配/退休释放，M 拍保留老 load execute/request/response。
// 测试：sim/cocotb/load_queue/；多事务代际/异常待 L8/L5。
module load_queue
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    localparam int RENAME_WIDTH = BACKEND_MACHINE_WIDTH,
    localparam int DEPTH = CFG.lsu.lq_depth,
    localparam int NUM_ROB_ENTRIES = CFG.rob.entries
) (
    input logic clk,
    input logic rst,
    input logic alloc_req_i [RENAME_WIDTH-1:0],
    input logic alloc_fire_i,
    input logic [$clog2(NUM_ROB_ENTRIES)-1:0] alloc_rob_idx_i [RENAME_WIDTH-1:0],
    input branch_mask_t alloc_branch_mask_i [RENAME_WIDTH-1:0],
    output logic [$clog2(DEPTH)-1:0] alloc_idx_o [RENAME_WIDTH-1:0],
    output logic [$clog2(DEPTH+1)-1:0] free_count_o,
    output logic [$clog2(DEPTH)-1:0] tail_o,

    input logic execute_valid_i,
    input logic [$clog2(DEPTH)-1:0] execute_idx_i,
    input logic [XLEN-1:0] execute_addr_i,
    output logic execute_generation_o,
    input logic request_fire_i,
    input logic [$clog2(DEPTH)-1:0] request_idx_i,
    input logic response_valid_i,
    input logic [$clog2(DEPTH):0] response_tag_i,
    output logic response_live_o,

    input logic [$clog2(RENAME_WIDTH+1)-1:0] release_count_i,
    input logic resolution_valid_i,
    input logic resolution_mispredict_i,
    input branch_tag_t resolution_tag_i,
    input logic [$clog2(DEPTH)-1:0] restore_tail_i
,

    // ---------------- 目标合同（框架新增，未接入逻辑） ----------------
    // replay 等待记录（B04 6.2）：等待原因与唤醒；记录放 LQ 内还是独立队列未冻结
    input  logic                       t_wait_set_valid_i,
    input  logic [$clog2(DEPTH)-1:0]   t_wait_set_idx_i,
    input  o3_types_pkg::dc_status_e   t_wait_reason_i,
    input  o3_types_pkg::dc_wake_t     t_dc_wake_i,
    input  logic                       t_tlb_wake_i,
    output logic                       t_replay_valid_o,
    output logic [$clog2(DEPTH)-1:0]   t_replay_idx_o,
    input  logic                       t_replay_ready_i,
    // 多事务身份：idx + 多位代际（现有 1 位不足，B04）
    output o3_types_pkg::lq_tag_t      t_exec_tag_o,
    // 访存违例检测（未知地址旧 store 的推测策略待定，B04）
    input  logic                       t_store_addr_valid_i,
    input  logic [XLEN-1:0]            t_store_addr_i,
    input  logic [ROB_IDX_WIDTH-1:0]   t_store_rob_idx_i,
    output logic                       t_violation_o
);
    localparam int IDX_WIDTH = $clog2(DEPTH);
    localparam int COUNT_WIDTH = $clog2(DEPTH + 1);
    logic [IDX_WIDTH-1:0] head_q, tail_q;
    logic [COUNT_WIDTH-1:0] count_q;
    logic valid_q [DEPTH-1:0];
    logic generation_q [DEPTH-1:0];
    logic addr_valid_q [DEPTH-1:0];
    logic outstanding_q [DEPTH-1:0];
    logic [XLEN-1:0] addr_q [DEPTH-1:0];
    logic [$clog2(NUM_ROB_ENTRIES)-1:0] rob_idx_q [DEPTH-1:0];
    branch_mask_t branch_mask_q [DEPTH-1:0];

    function automatic logic [IDX_WIDTH-1:0] add_idx(
        input logic [IDX_WIDTH-1:0] base, input int unsigned offset
    );
        add_idx = IDX_WIDTH'((int'(base) + offset) % DEPTH);
    endfunction

    assign free_count_o = COUNT_WIDTH'(DEPTH) - count_q;
    assign tail_o = tail_q;
    assign execute_generation_o = generation_q[execute_idx_i];
    assign response_live_o = response_valid_i
                           && valid_q[response_tag_i[IDX_WIDTH-1:0]]
                           && generation_q[response_tag_i[IDX_WIDTH-1:0]]
                              == response_tag_i[IDX_WIDTH];

    always_comb begin
        for (int lane = 0; lane < RENAME_WIDTH; lane++) begin
            int unsigned req_before_lane;
            req_before_lane = 0;
            for (int older = 0; older < lane; older++) begin
                if (alloc_req_i[older]) req_before_lane++;
            end
            alloc_idx_o[lane] = add_idx(tail_q, req_before_lane);
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            head_q <= '0;
            tail_q <= '0;
            count_q <= '0;
            valid_q <= '{default: 1'b0};
            generation_q <= '{default: 1'b0};
            addr_valid_q <= '{default: 1'b0};
            outstanding_q <= '{default: 1'b0};
            addr_q <= '{default: '0};
            rob_idx_q <= '{default: '0};
            branch_mask_q <= '{default: '0};
        end else if (resolution_valid_i && resolution_mispredict_i) begin
            int unsigned kept;
            kept = 0;
            for (int entry = 0; entry < DEPTH; entry++) begin
                if (valid_q[entry] && branch_mask_q[entry][resolution_tag_i]) begin
                    valid_q[entry] <= 1'b0;
                    addr_valid_q[entry] <= 1'b0;
                    outstanding_q[entry] <= 1'b0;
                end else if (valid_q[entry]) begin
                    kept++;
                    // U7/LQ-M：恢复只取消年轻项，老 load 的正常生命周期照常更新。
                    // 用拍初 mask 判存活，再清解析位；请求/响应不因 M 吞掉。
                    branch_mask_q[entry][resolution_tag_i] <= 1'b0;
                    if (execute_valid_i && execute_idx_i == IDX_WIDTH'(entry)) begin
                        addr_q[entry] <= execute_addr_i;
                        addr_valid_q[entry] <= 1'b1;
                    end
                    if (request_fire_i && request_idx_i == IDX_WIDTH'(entry))
                        outstanding_q[entry] <= 1'b1;
                    if (response_live_o && response_tag_i[IDX_WIDTH-1:0] == IDX_WIDTH'(entry))
                        outstanding_q[entry] <= 1'b0;
                end
            end
            for (int released = 0; released < RENAME_WIDTH; released++) begin
                if (released < int'(release_count_i)) begin
                    valid_q[add_idx(head_q, released)] <= 1'b0;
                    addr_valid_q[add_idx(head_q, released)] <= 1'b0;
                    outstanding_q[add_idx(head_q, released)] <= 1'b0;
                end
            end
            head_q <= add_idx(head_q, int'(release_count_i));
            tail_q <= restore_tail_i;
            count_q <= COUNT_WIDTH'(kept) - COUNT_WIDTH'(release_count_i);
        end else begin
            int unsigned alloc_count;
            alloc_count = 0;

            for (int released = 0; released < RENAME_WIDTH; released++) begin
                if (released < int'(release_count_i)) begin
                    valid_q[add_idx(head_q, released)] <= 1'b0;
                    addr_valid_q[add_idx(head_q, released)] <= 1'b0;
                    outstanding_q[add_idx(head_q, released)] <= 1'b0;
                end
            end
            if (release_count_i != '0) head_q <= add_idx(head_q, int'(release_count_i));

            for (int entry = 0; entry < DEPTH; entry++) begin
                if (resolution_valid_i) branch_mask_q[entry][resolution_tag_i] <= 1'b0;
            end

            if (alloc_fire_i) begin
                for (int lane = 0; lane < RENAME_WIDTH; lane++) begin
                    if (alloc_req_i[lane]) begin
                        valid_q[alloc_idx_o[lane]] <= 1'b1;
                        generation_q[alloc_idx_o[lane]] <= ~generation_q[alloc_idx_o[lane]];
                        addr_valid_q[alloc_idx_o[lane]] <= 1'b0;
                        outstanding_q[alloc_idx_o[lane]] <= 1'b0;
                        addr_q[alloc_idx_o[lane]] <= '0;
                        rob_idx_q[alloc_idx_o[lane]] <= alloc_rob_idx_i[lane];
                        branch_mask_q[alloc_idx_o[lane]] <= alloc_branch_mask_i[lane];
                        alloc_count++;
                    end
                end
                tail_q <= add_idx(tail_q, alloc_count);
            end

            if (execute_valid_i && valid_q[execute_idx_i]) begin
                addr_q[execute_idx_i] <= execute_addr_i;
                addr_valid_q[execute_idx_i] <= 1'b1;
            end
            if (request_fire_i && valid_q[request_idx_i]) begin
                outstanding_q[request_idx_i] <= 1'b1;
            end
            if (response_live_o) begin
                outstanding_q[response_tag_i[IDX_WIDTH-1:0]] <= 1'b0;
            end

            count_q <= count_q + COUNT_WIDTH'(alloc_count) - COUNT_WIDTH'(release_count_i);
        end
    end

    initial if (DEPTH <= 0) $error("load_queue requires DEPTH > 0");
endmodule
