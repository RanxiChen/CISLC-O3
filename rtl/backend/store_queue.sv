/** L8a SQ: two STA writes and two forwarding queries. Committed stores
 * retain their entry until PS st_done. Retry records the cache wait reason;
 * install/free and translation/A-D events enable reissue. Branch recovery
 * preserves the committed prefix and cancels younger speculative entries. */
module store_queue
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    // Legacy direct-drain test interface; the core enables the cache handshake.
    parameter bit DCACHE_DRAIN = 1'b0,
    localparam int RENAME_WIDTH = BACKEND_MACHINE_WIDTH,
    localparam int COMMIT_WIDTH = o3_cfg_pkg::O3_CFG.core.commit_width,
    localparam int DEPTH = CFG.lsu.sq_depth,
    localparam int P=CFG.lsu.agu_pipes,
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

    input logic execute_valid_i [P],
    input logic [$clog2(DEPTH)-1:0] execute_idx_i [P],
    input logic [XLEN-1:0] execute_addr_i [P],
    input logic [XLEN-1:0] execute_data_i [P],
    input logic [7:0] execute_mask_i [P],

    input logic commit_valid_i [COMMIT_WIDTH-1:0],
    input logic [$clog2(DEPTH)-1:0] commit_idx_i [COMMIT_WIDTH-1:0],

    input logic query_valid_i [P],
    input logic [$clog2(NUM_ROB_ENTRIES)-1:0] query_rob_idx_i [P],
    input logic [$clog2(NUM_ROB_ENTRIES)-1:0] rob_head_i,
    input logic [XLEN-1:0] query_addr_i [P],
    input logic [7:0] query_mask_i [P],
    output logic query_block_o [P],
    output logic query_forward_valid_o [P],
    output logic [XLEN-1:0] query_forward_data_o [P],

    output logic drain_valid_o,
    input logic drain_ready_i,
    output logic [XLEN-1:0] drain_addr_o,
    output logic [XLEN-1:0] drain_data_o,
    output logic [7:0] drain_mask_o,

    input logic flush_all_i,
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
    input o3_types_pkg::dc_wake_t dc_wake_i,
    input logic capture_valid_i[P],input lq_replay_t capture_i[P],
    input logic update_valid_i[P],input o3_types_pkg::dcache_resp_t update_i[P],
    input logic tlb_wake_i,ad_wake_i,
    output logic replay_valid_o[P],output lq_replay_t replay_o[P],input logic replay_ready_i[P],
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
    logic dc_inflight_q;
    logic dc_wait_q;
    o3_types_pkg::ld_wait_e dc_reason_q;
    o3_types_pkg::coh_id_t dc_mshr_q;
    logic dc_drain_fire;
    logic dc_resp_match;
    assign dc_resp_match=dc_inflight_q && t_dc_resp_i.valid &&
        t_dc_resp_i.src==o3_types_pkg::DC_SRC_STORE_DRAIN &&
        t_dc_resp_i.sq_idx==o3_types_pkg::sq_idx_t'(head_q);
    logic head_dtcm;
    logic head_ready;

    lq_replay_t sta_q[DEPTH];logic sta_ready_q[DEPTH],sta_wait_q[DEPTH];
    int replay_idx[P];
    always_comb begin
        replay_valid_o='{default:0};replay_o='{default:'0};replay_idx='{default:-1};
        for(int d=0;d<DEPTH;d++) begin
            int n,pick;n=(int'(head_q)+d)%DEPTH;pick=-1;
            for(int p=0;p<P;p++) if(p<CFG.lsu.mem_pipes && pick<0 && replay_idx[p]<0) pick=p;
            if(pick>=0 && valid_q[n] && sta_ready_q[n] && !committed_q[n] && !flush_all_i &&
                !(resolution_valid_i && resolution_mispredict_i && branch_mask_q[n][resolution_tag_i])) begin
                replay_idx[pick]=n;replay_valid_o[pick]=1;replay_o[pick]=sta_q[n];
                replay_o[pick].uop.branch_mask=branch_mask_q[n];
            end
        end
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            sta_q<='{default:'0};sta_ready_q<='{default:0};sta_wait_q<='{default:0};
            dc_wait_q<=0;dc_reason_q<=o3_types_pkg::LDW_NONE;dc_mshr_q<=0;
        end else begin
            if(dc_resp_match && t_dc_resp_i.status!=o3_types_pkg::DC_OK) begin
                dc_wait_q<=1;dc_reason_q<=t_dc_resp_i.reason;dc_mshr_q<=t_dc_resp_i.mshr_id;
                assert(t_dc_resp_i.status!=o3_types_pkg::DC_ERROR) else $fatal(1,"committed drain access fault");
            end
            if(dc_wait_q) case(dc_reason_q)
                o3_types_pkg::LDW_MSHR:if(dc_wake_i.valid && dc_wake_i.mshr_id==dc_mshr_q) begin
                    assert(!dc_wake_i.err) else $fatal(1,"committed store GetM failed");dc_wait_q<=0;
                end
                o3_types_pkg::LDW_MSHR_FULL:if(dc_wake_i.mshr_free) dc_wait_q<=0;
                o3_types_pkg::LDW_WB_LINE:if(dc_wake_i.wb_free) dc_wait_q<=0;
                default:dc_wait_q<=0;
            endcase
            for(int n=0;n<DEPTH;n++) begin
                if(flush_all_i || (resolution_valid_i && resolution_mispredict_i && branch_mask_q[n][resolution_tag_i])) begin
                    sta_ready_q[n]<=0;sta_wait_q[n]<=0;
                end else begin
                    if(sta_wait_q[n]) case(sta_q[n].wait_reason)
                        o3_types_pkg::LDW_TLB_MISS:if(tlb_wake_i) sta_ready_q[n]<=1;
                        o3_types_pkg::LDW_AD_ORDER:if(ad_wake_i) sta_ready_q[n]<=1;
                        default:sta_ready_q[n]<=1;
                    endcase
                    for(int p=0;p<P;p++) begin
                        if(replay_valid_o[p] && replay_ready_i[p] && replay_idx[p]==n) begin sta_ready_q[n]<=0;sta_wait_q[n]<=0;end
                        if(capture_valid_i[p] && capture_i[p].uop.sq_idx==n) sta_q[n]<=capture_i[p];
                        if(update_valid_i[p] && update_i[p].sq_idx==n) begin
                            sta_q[n].wait_reason<=update_i[p].reason;
                            sta_wait_q[n]<=update_i[p].status==o3_types_pkg::DC_REPLAY;
                            sta_ready_q[n]<=update_i[p].status==o3_types_pkg::DC_REPLAY &&
                                !(update_i[p].reason inside {o3_types_pkg::LDW_TLB_MISS,o3_types_pkg::LDW_AD_ORDER});
                            if(update_i[p].reason==o3_types_pkg::LDW_TLB_MISS && tlb_wake_i) sta_ready_q[n]<=1;
                            if(update_i[p].reason==o3_types_pkg::LDW_AD_ORDER && ad_wake_i) sta_ready_q[n]<=1;
                        end
                    end
                end
            end
            // A resource wake on the st_retry edge is not lost.
            if(dc_resp_match && t_dc_resp_i.status!=o3_types_pkg::DC_OK) begin
                if(t_dc_resp_i.reason==o3_types_pkg::LDW_MSHR && dc_wake_i.valid && dc_wake_i.mshr_id==t_dc_resp_i.mshr_id) dc_wait_q<=0;
                if(t_dc_resp_i.reason==o3_types_pkg::LDW_MSHR_FULL && dc_wake_i.mshr_free) dc_wait_q<=0;
                if(t_dc_resp_i.reason==o3_types_pkg::LDW_WB_LINE && dc_wake_i.wb_free) dc_wait_q<=0;
            end
            if(alloc_fire_i) for(int l=0;l<RENAME_WIDTH;l++) if(alloc_req_i[l]) begin
                sta_ready_q[alloc_idx_o[l]]<=0;sta_wait_q[alloc_idx_o[l]]<=0;
            end
        end
    end

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
    assign head_ready = valid_q[head_q] && committed_q[head_q]
                     && addr_valid_q[head_q] && data_valid_q[head_q];
    assign head_dtcm = 1'b0;
    assign drain_valid_o = head_ready && (!DCACHE_DRAIN || head_dtcm);
    assign drain_addr_o = addr_q[head_q];
    assign drain_data_o = data_q[head_q];
    assign drain_mask_o = mask_q[head_q];
    assign t_dc_req_valid_o = DCACHE_DRAIN && head_ready && !head_dtcm
                           && !dc_inflight_q && !dc_wait_q;
    always_comb begin
        t_dc_req_o = '0;
        t_dc_req_o.src = o3_types_pkg::DC_SRC_STORE_DRAIN;
        t_dc_req_o.paddr = o3_types_pkg::paddr_t'(addr_q[head_q]);
        t_dc_req_o.vaddr=addr_q[head_q];
        t_dc_req_o.size = (mask_q[head_q] == 8'hff) ? 2'd3
                        : (mask_q[head_q][3:0] == 4'hf) ? 2'd2
                        : (mask_q[head_q][1:0] == 2'b11) ? 2'd1 : 2'd0;
        t_dc_req_o.write = 1'b1;
        t_dc_req_o.wdata = data_q[head_q];
        t_dc_req_o.wmask = mask_q[head_q];
        t_dc_req_o.sq_idx = o3_types_pkg::sq_idx_t'(head_q);
    end
    assign dc_drain_fire = DCACHE_DRAIN && dc_inflight_q
                         && t_dc_resp_i.valid
                         && t_dc_resp_i.src == o3_types_pkg::DC_SRC_STORE_DRAIN
                         && t_dc_resp_i.sq_idx == o3_types_pkg::sq_idx_t'(head_q)
                         && t_dc_resp_i.status == o3_types_pkg::DC_OK;
    always_comb begin
        t_committed_empty_o = 1'b1;
        for (int entry = 0; entry < DEPTH; entry++)
            if (valid_q[entry] && committed_q[entry]) t_committed_empty_o = 1'b0;
    end

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
        for(int p=0;p<P;p++) begin
        logic unknown_addr_block;
        logic covered_data_block;
        query_block_o[p] = 1'b0;
        query_forward_valid_o[p] = 1'b0;
        query_forward_data_o[p] = '0;
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
                     < rob_distance(query_rob_idx_i[p], rob_head_i));
            covered_bytes = '0;
            shift_bytes = 0;
            for (int load_byte = 0; load_byte < 8; load_byte++) begin
                for (int store_byte = 0; store_byte < 8; store_byte++) begin
                    if (mask_q[idx][store_byte]
                     && (addr_q[idx] + XLEN'(store_byte)
                         == query_addr_i[p] + XLEN'(load_byte))) begin
                        covered_bytes[load_byte] = 1'b1;
                    end
                end
            end
            overlap = |(covered_bytes & query_mask_i[p]);
            full_cover = ((covered_bytes & query_mask_i[p]) == query_mask_i[p]);

            if (query_valid_i[p] && valid_q[idx] && older) begin
                if (!addr_valid_q[idx]) begin
                    unknown_addr_block = 1'b1;
                end else if (overlap) begin
                    // A later full-cover store supplies every byte and makes
                    // older known-address overlap irrelevant. A partial
                    // overlap cannot be assembled from multiple SQ entries
                    // in this first version.
                    if (full_cover && data_valid_q[idx]) begin
                        shift_bytes = int'(query_addr_i[p] - addr_q[idx]);
                        query_forward_valid_o[p] = 1'b1;
                        query_forward_data_o[p] = data_q[idx] >> (8 * shift_bytes);
                        covered_data_block = 1'b0;
                    end else begin
                        query_forward_valid_o[p] = 1'b0;
                        covered_data_block = 1'b1;
                    end
                end
            end
        end
        query_block_o[p] = unknown_addr_block || covered_data_block;
        if (query_block_o[p]) query_forward_valid_o[p] = 1'b0;
        end
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
            dc_inflight_q <= 1'b0;
        end else if (flush_all_i) begin
            int unsigned kept;
            logic drain_fire;
            kept=0; drain_fire=dc_drain_fire || (drain_valid_o && drain_ready_i);
            if (DCACHE_DRAIN && t_dc_req_valid_o && t_dc_req_ready_i) dc_inflight_q<=1;
            if (dc_resp_match) dc_inflight_q<=0;
            for (int entry=0;entry<DEPTH;entry++) begin
                if (valid_q[entry] && committed_q[entry]) kept++;
                else begin valid_q[entry]<=0; addr_valid_q[entry]<=0; data_valid_q[entry]<=0; end
                branch_mask_q[entry]<='0;
            end
            tail_q<=add_idx(head_q,kept);
            if (drain_fire) begin
                valid_q[head_q]<=0; committed_q[head_q]<=0;
                head_q<=add_idx(head_q,1);
            end
            count_q<=COUNT_WIDTH'(kept)-COUNT_WIDTH'(drain_fire);
        end else if (resolution_valid_i && resolution_mispredict_i) begin
            int unsigned kept;
            logic drain_fire;
            kept = 0;
            drain_fire = dc_drain_fire || (drain_valid_o && drain_ready_i);
            if (DCACHE_DRAIN && t_dc_req_valid_o && t_dc_req_ready_i)
                dc_inflight_q <= 1'b1;
            if (dc_resp_match) dc_inflight_q <= 1'b0;
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
            for(int p=0;p<P;p++) begin
            if (execute_valid_i[p] && valid_q[execute_idx_i[p]]
             && !branch_mask_q[execute_idx_i[p]][resolution_tag_i]) begin
                addr_q[execute_idx_i[p]] <= execute_addr_i[p];
                data_q[execute_idx_i[p]] <= execute_data_i[p];
                mask_q[execute_idx_i[p]] <= execute_mask_i[p];
                addr_valid_q[execute_idx_i[p]] <= 1'b1;
                data_valid_q[execute_idx_i[p]] <= 1'b1;
            end
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
            drain_fire = dc_drain_fire || (drain_valid_o && drain_ready_i);
            if (DCACHE_DRAIN && t_dc_req_valid_o && t_dc_req_ready_i)
                dc_inflight_q <= 1'b1;
            if (dc_resp_match) dc_inflight_q <= 1'b0;

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

            for(int p=0;p<P;p++) begin
            if (execute_valid_i[p] && valid_q[execute_idx_i[p]]) begin
                addr_q[execute_idx_i[p]] <= execute_addr_i[p];
                data_q[execute_idx_i[p]] <= execute_data_i[p];
                mask_q[execute_idx_i[p]] <= execute_mask_i[p];
                addr_valid_q[execute_idx_i[p]] <= 1'b1;
                data_valid_q[execute_idx_i[p]] <= 1'b1;
            end
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
