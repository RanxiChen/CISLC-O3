/**
 *
 * 【2026-10-02 框架：目标机制与缺口】
 * - 保留：首版 SQ 兼任 committed store buffer，按序 drain；已提交项不被年轻恢复取消；等待 drain 的
 *   store（含已提交）仍可转发；单 store 完整覆盖转发，部分覆盖/未知保守等待（B05/B04 6.1）。
 * - 需要补充：drain 改接 DCache（t_dc_*）：请求接受与写完成分开，命中写完确认后释放；
 *   miss/冲突/DMA 行保护时保留项、等事件重试，不重复发送在途请求；store 等 miss 不占 bank 流水级。
 * - t_committed_empty_o：FENCE、AMO 较强排序、FENCE.I、DMA 交接所需的“先前 store 已到可见点”判断（B09/D25）。
 * - needs_D（B36）：store 地址翻译命中但 D=0 时，该 SQ 项标记 needs_D（不报异常，PTW 槽位已释放）；
 *   到 ROB 队首后由 commit_ctrl 发起 pte_ad_updater 的非推测 D 更新，完成（或错误归属本指令）后才可
 *   提交。needs_D 未完成期间年轻访存不得越过。首版不保存完整 PTE 快照，慢路径重新遍历。
 * - 地址未知（B32）：年轻 load 等本项地址写入/本项被取消后再判定，不以超时越过。
 *   已实现保守依赖查询：按 SQ 年龄选择最近的完整覆盖旧 store；较年轻的完整覆盖
 *   可覆盖较老的部分写入，地址未知的旧 store 仍阻塞。测试：sim/cocotb/store_queue/。
 * - 现有 drain 是 store 队头排出，不等于已完成 FENCE/FENCE.I 系统同步。目标端口未接入。
 * Store Queue and committed Store Buffer
 *
 * Rename分配entry，AGU补写地址/数据/byte mask，ROB退休只把对应entry标记committed；
 * 只有队头committed Store被Data SRAM接受后才真正释放。Load查询会保守阻塞在
 * 地址/数据未知的更老Store或部分重叠上，并可从最年轻的完整覆盖Store转发。
 *
 * 周期N组合阶段给出Load依赖结果和最老committed drain请求；周期N上升沿更新
 * allocate/execute/commit/drain状态；周期N+1可见。错误分支只删除未提交年轻项，
 * committed entry不受flush影响；恢复同拍的存活老Store execute/commit/drain仍生效。
 * 本阶段不合并多个Store完成一次Load转发，未来可在Load replay和多Store字节合并处扩展。
 */
module store_queue
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    localparam int RENAME_WIDTH = BACKEND_MACHINE_WIDTH,
    localparam int COMMIT_WIDTH = o3_cfg_pkg::O3_CFG.core.commit_width,
    localparam int DEPTH = CFG.lsu.sq_depth,
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
    input logic [XLEN-1:0] execute_data_i,
    input logic [7:0] execute_mask_i,

    input logic commit_valid_i [COMMIT_WIDTH-1:0],
    input logic [$clog2(DEPTH)-1:0] commit_idx_i [COMMIT_WIDTH-1:0],

    input logic query_valid_i,
    input logic [$clog2(NUM_ROB_ENTRIES)-1:0] query_rob_idx_i,
    input logic [$clog2(NUM_ROB_ENTRIES)-1:0] rob_head_i,
    input logic [XLEN-1:0] query_addr_i,
    input logic [7:0] query_mask_i,
    output logic query_block_o,
    output logic query_forward_valid_o,
    output logic [XLEN-1:0] query_forward_data_o,

    output logic drain_valid_o,
    input logic drain_ready_i,
    output logic [XLEN-1:0] drain_addr_o,
    output logic [XLEN-1:0] drain_data_o,
    output logic [7:0] drain_mask_o,

    input logic resolution_valid_i,
    input logic resolution_mispredict_i,
    input branch_tag_t resolution_tag_i,
    input logic [$clog2(DEPTH)-1:0] restore_tail_i
,

    // ---------------- 目标合同（框架新增，未接入逻辑） ----------------
    // drain 到 DCache：请求接受与写完成分开（B05）
    output logic                       t_dc_req_valid_o,
    input  logic                       t_dc_req_ready_i,
    output o3_types_pkg::dcache_req_t  t_dc_req_o,
    input  o3_types_pkg::dcache_resp_t t_dc_resp_i,
    // FENCE / AMO / FENCE.I / DMA 交接：已提交 store 是否全部 drain
    output logic                       t_committed_empty_o
);
    localparam int IDX_WIDTH = $clog2(DEPTH);
    localparam int COUNT_WIDTH = $clog2(DEPTH + 1);
    localparam int ROB_IDX_WIDTH_LOCAL = $clog2(NUM_ROB_ENTRIES);
    logic [IDX_WIDTH-1:0] head_q, tail_q;
    logic [COUNT_WIDTH-1:0] count_q;
    logic valid_q [DEPTH-1:0];
    logic addr_valid_q [DEPTH-1:0];
    logic data_valid_q [DEPTH-1:0];
    logic committed_q [DEPTH-1:0];
    logic [XLEN-1:0] addr_q [DEPTH-1:0];
    logic [XLEN-1:0] data_q [DEPTH-1:0];
    logic [7:0] mask_q [DEPTH-1:0];
    logic [ROB_IDX_WIDTH_LOCAL-1:0] rob_idx_q [DEPTH-1:0];
    branch_mask_t branch_mask_q [DEPTH-1:0];

    function automatic logic [IDX_WIDTH-1:0] add_idx(
        input logic [IDX_WIDTH-1:0] base, input int unsigned offset
    );
        add_idx = IDX_WIDTH'((int'(base) + offset) % DEPTH);
    endfunction

    function automatic int unsigned rob_distance(
        input logic [ROB_IDX_WIDTH_LOCAL-1:0] idx,
        input logic [ROB_IDX_WIDTH_LOCAL-1:0] head
    );
        rob_distance = (int'(idx) + NUM_ROB_ENTRIES - int'(head)) % NUM_ROB_ENTRIES;
    endfunction

    assign free_count_o = COUNT_WIDTH'(DEPTH) - count_q;
    assign tail_o = tail_q;
    assign drain_valid_o = valid_q[head_q] && committed_q[head_q]
                         && addr_valid_q[head_q] && data_valid_q[head_q];
    assign drain_addr_o = addr_q[head_q];
    assign drain_data_o = data_q[head_q];
    assign drain_mask_o = mask_q[head_q];

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

    // 按 SQ 程序顺序从老到年轻扫描。更年轻的完整覆盖写会取代先前的
    // 部分覆盖或数据未就绪项；地址未知的旧写入按 B32 始终阻塞。
    // 周期 N 组合阶段只产生查询结果，SQ 状态不变；load 在握手后使用
    // 同一拍的判定，周期 N+1 可重新查询刚在上升沿写入的 store 地址。
    always_comb begin
        logic unknown_addr_block;
        logic covered_data_block;
        query_block_o = 1'b0;
        query_forward_valid_o = 1'b0;
        query_forward_data_o = '0;
        unknown_addr_block = 1'b0;
        covered_data_block = 1'b0;
        for (int offset = 0; offset < DEPTH; offset++) begin
            logic [IDX_WIDTH-1:0] idx;
            logic older;
            logic overlap;
            logic full_cover;
            logic [7:0] covered_bytes;
            int unsigned shift_bytes;
            idx = add_idx(head_q, offset);
            older = committed_q[idx]
                 || (rob_distance(rob_idx_q[idx], rob_head_i)
                     < rob_distance(query_rob_idx_i, rob_head_i));
            covered_bytes = '0;
            shift_bytes = 0;
            for (int load_byte = 0; load_byte < 8; load_byte++) begin
                for (int store_byte = 0; store_byte < 8; store_byte++) begin
                    if (mask_q[idx][store_byte]
                     && (addr_q[idx] + XLEN'(store_byte)
                         == query_addr_i + XLEN'(load_byte))) begin
                        covered_bytes[load_byte] = 1'b1;
                    end
                end
            end
            overlap = |(covered_bytes & query_mask_i);
            full_cover = ((covered_bytes & query_mask_i) == query_mask_i);

            if (query_valid_i && valid_q[idx] && older) begin
                if (!addr_valid_q[idx]) begin
                    unknown_addr_block = 1'b1;
                end else if (overlap) begin
                    // A later full-cover store supplies every byte and makes
                    // older known-address overlap irrelevant. A partial
                    // overlap cannot be assembled from multiple SQ entries
                    // in this first version.
                    if (full_cover && data_valid_q[idx]) begin
                        shift_bytes = int'(query_addr_i - addr_q[idx]);
                        query_forward_valid_o = 1'b1;
                        query_forward_data_o = data_q[idx] >> (8 * shift_bytes);
                        covered_data_block = 1'b0;
                    end else begin
                        query_forward_valid_o = 1'b0;
                        covered_data_block = 1'b1;
                    end
                end
            end
        end
        query_block_o = unknown_addr_block || covered_data_block;
        if (query_block_o) query_forward_valid_o = 1'b0;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            head_q <= '0;
            tail_q <= '0;
            count_q <= '0;
            valid_q <= '{default: 1'b0};
            addr_valid_q <= '{default: 1'b0};
            data_valid_q <= '{default: 1'b0};
            committed_q <= '{default: 1'b0};
            addr_q <= '{default: '0};
            data_q <= '{default: '0};
            mask_q <= '{default: '0};
            rob_idx_q <= '{default: '0};
            branch_mask_q <= '{default: '0};
        end else if (resolution_valid_i && resolution_mispredict_i) begin
            int unsigned kept;
            logic drain_fire;
            kept = 0;
            drain_fire = drain_valid_o && drain_ready_i;
            for (int entry = 0; entry < DEPTH; entry++) begin
                if (valid_q[entry] && !committed_q[entry]
                 && branch_mask_q[entry][resolution_tag_i]) begin
                    valid_q[entry] <= 1'b0;
                    addr_valid_q[entry] <= 1'b0;
                    data_valid_q[entry] <= 1'b0;
                end else if (valid_q[entry]) begin
                    kept++;
                    branch_mask_q[entry][resolution_tag_i] <= 1'b0;
                end
            end

            // 恢复优先级只负责删除错误路径，不能吞掉同拍已经握手的老Store事件。
            // 否则ROB会看到Store complete，而SQ对应entry仍没有地址/数据，队头
            // 将永久无法drain。老Store不携带本次解析tag，因此可在恢复拍继续写入。
            if (execute_valid_i && valid_q[execute_idx_i]
             && !branch_mask_q[execute_idx_i][resolution_tag_i]) begin
                addr_q[execute_idx_i] <= execute_addr_i;
                data_q[execute_idx_i] <= execute_data_i;
                mask_q[execute_idx_i] <= execute_mask_i;
                addr_valid_q[execute_idx_i] <= 1'b1;
                data_valid_q[execute_idx_i] <= 1'b1;
            end
            for (int port = 0; port < COMMIT_WIDTH; port++) begin
                if (commit_valid_i[port] && valid_q[commit_idx_i[port]]
                 && !branch_mask_q[commit_idx_i[port]][resolution_tag_i]) begin
                    committed_q[commit_idx_i[port]] <= 1'b1;
                end
            end
            if (drain_fire) begin
                valid_q[head_q] <= 1'b0;
                addr_valid_q[head_q] <= 1'b0;
                data_valid_q[head_q] <= 1'b0;
                committed_q[head_q] <= 1'b0;
                head_q <= add_idx(head_q, 1);
            end
            tail_q <= restore_tail_i;
            count_q <= COUNT_WIDTH'(kept) - COUNT_WIDTH'(drain_fire);
        end else begin
            int unsigned alloc_count;
            logic drain_fire;
            alloc_count = 0;
            drain_fire = drain_valid_o && drain_ready_i;

            if (drain_fire) begin
                valid_q[head_q] <= 1'b0;
                addr_valid_q[head_q] <= 1'b0;
                data_valid_q[head_q] <= 1'b0;
                committed_q[head_q] <= 1'b0;
                head_q <= add_idx(head_q, 1);
            end

            for (int entry = 0; entry < DEPTH; entry++) begin
                if (resolution_valid_i) branch_mask_q[entry][resolution_tag_i] <= 1'b0;
            end

            if (alloc_fire_i) begin
                for (int lane = 0; lane < RENAME_WIDTH; lane++) begin
                    if (alloc_req_i[lane]) begin
                        valid_q[alloc_idx_o[lane]] <= 1'b1;
                        addr_valid_q[alloc_idx_o[lane]] <= 1'b0;
                        data_valid_q[alloc_idx_o[lane]] <= 1'b0;
                        committed_q[alloc_idx_o[lane]] <= 1'b0;
                        addr_q[alloc_idx_o[lane]] <= '0;
                        data_q[alloc_idx_o[lane]] <= '0;
                        mask_q[alloc_idx_o[lane]] <= '0;
                        rob_idx_q[alloc_idx_o[lane]] <= alloc_rob_idx_i[lane];
                        branch_mask_q[alloc_idx_o[lane]] <= alloc_branch_mask_i[lane];
                        alloc_count++;
                    end
                end
                tail_q <= add_idx(tail_q, alloc_count);
            end

            if (execute_valid_i && valid_q[execute_idx_i]) begin
                addr_q[execute_idx_i] <= execute_addr_i;
                data_q[execute_idx_i] <= execute_data_i;
                mask_q[execute_idx_i] <= execute_mask_i;
                addr_valid_q[execute_idx_i] <= 1'b1;
                data_valid_q[execute_idx_i] <= 1'b1;
            end
            for (int port = 0; port < COMMIT_WIDTH; port++) begin
                if (commit_valid_i[port] && valid_q[commit_idx_i[port]]) begin
                    committed_q[commit_idx_i[port]] <= 1'b1;
                end
            end

            count_q <= count_q + COUNT_WIDTH'(alloc_count) - COUNT_WIDTH'(drain_fire);
        end
    end

    initial if (DEPTH <= 0) $error("store_queue requires DEPTH > 0");
endmodule
