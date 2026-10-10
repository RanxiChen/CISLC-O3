/**
 * TAGE —— 三阶段、每区域 REGION_SLOTS 个条件方向位。
 *
 * 首版组织：CFG.tage.base_entries 行 base，六张 2^index_bits[i] 行 tagged；
 * 每行各槽独立 ctr/useful，tag/valid 由整行共享。base 及 tagged 的计数位宽
 * 取 CFG.tage.ctr_bits。最长历史 tag 命中为 provider，次长命中或 base 为 alt。
 * provider 弱计数且 useful=0 时临时采用 alt；否则采用 provider。仅方向预测，
 * 不给目标。提交时 base 始终训练；原查询 provider 尚在表内时训练其 ctr，
 * provider 与 alt 不同时按实际结果调整 useful；该槽原最终方向错误时，
 * 在更长历史表中找无效/低 useful 行分配，全部被保护时先衰减最短候选行。
 * 所有训练使用 train_i.folds，不能使用提交时的当前推测历史。
 *
 * meta 低位按槽编码：每槽 3-bit provider（7=base），随后各一位 alt、
 * provider 与最终方向。高位清零；它属于原预测上下文，FTQ 须原样保存。
 * provider_hit_mask 表示该槽有 tagged provider，不表示最终使用了 provider。
 * 部分 tag 可以碰撞，后端纠错；没有显式失效/别名计数。首版不包含 SC、
 * ITTAGE。L7c 将查询/训练各置于一份同步 SRAM，loop 在 BPU 中独立覆盖。perf_o 暂为零：
 * 本模块不知道哪些槽实际是 BR，不能把八个方向位误算为八条条件预测。
 *
 * 周期 N：s0_valid_i 时组合算 index/tag；上升沿锁存为 S1。
 * 周期 N+1：S1 同步读 base/tagged 各行；上升沿锁存为 S2。同拍训练
 * 与 T2 同行写入碰撞时按写新值旁路；stall 关闭 BRAM 读使能以保持输出。
 * 提交训练 T0 读副本，T1/T2 各更新四槽，T2 原子写两份副本。
 * T1 地址冲突时 T0 反压；与 T2 同址读取使用写新值旁路。
 * 周期 N+2：S2 组合比较 tag、选方向并输出 resp_o；stall_i 立即抑制
 * resp_valid_o 且冻结 S1/S2，解除后重新呈现；kill_i 立即抑制 valid，
 * 并在上升沿清除在途查询。训练独立于 stall/kill。
 *
 * 单模块合同测试见 sim/cocotb/tage/，不改变本模块接口。
 */
module tage
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic                   clk_i,
    input  logic                   rst_i,

    input  logic                   s0_valid_i,
    input  vaddr_t                 s0_region_base_i,
    input  logic [HIST_FOLD_W-1:0] s0_folds_i,        // 本区域入口的折叠值 C
    input  logic                   stall_i,
    input  logic                   kill_i,

    output logic                   resp_valid_o,
    output tage_resp_t             resp_o,

    input  logic                   train_valid_i,
    output logic                   train_ready_o,
    input  bpu_train_t             train_i,

    output fe_perf_t               perf_o
);
    localparam int TABLES = o3_cfg_pkg::TAGE_TABLES;
    localparam int BASE_ENTRIES = CFG.tage.base_entries;
    localparam int CTR_BITS = CFG.tage.ctr_bits;
    localparam int USEFUL_BITS = CFG.tage.useful_bits;
    localparam int REGION_SHIFT = $clog2(CFG.fetch.region_bytes);
    localparam int BASE_IDX_BITS = $clog2(BASE_ENTRIES);
    localparam logic [META_PROVIDER_BITS-1:0] BASE_CODE = '1;

    function automatic int max_index_bits();
        int result;
        result = 1;
        for (int table_idx = 0; table_idx < TABLES; table_idx++)
            if (int'(CFG.tage.index_bits[table_idx]) > result)
                result = int'(CFG.tage.index_bits[table_idx]);
        return result;
    endfunction

    function automatic int max_tag_bits();
        int result;
        result = 1;
        for (int table_idx = 0; table_idx < TABLES; table_idx++)
            if (int'(CFG.tage.tag_bits[table_idx]) > result)
                result = int'(CFG.tage.tag_bits[table_idx]);
        return result;
    endfunction

    localparam int MAX_INDEX_BITS = max_index_bits();
    localparam int MAX_TAG_BITS = max_tag_bits();
    localparam int MAX_ENTRIES = 1 << MAX_INDEX_BITS;
    typedef logic [BASE_IDX_BITS-1:0] base_idx_t;
    typedef logic [MAX_INDEX_BITS-1:0] tagged_idx_t;
    typedef logic [MAX_TAG_BITS-1:0] tag_t;
    typedef logic [CTR_BITS-1:0] ctr_t;
    typedef logic [USEFUL_BITS-1:0] useful_t;
    typedef logic [REGION_SLOTS-1:0][CTR_BITS-1:0] base_row_t;

    typedef struct packed {
        logic valid;
        tag_t tag;
        logic [REGION_SLOTS-1:0][CTR_BITS-1:0] ctr;
        logic [REGION_SLOTS-1:0][USEFUL_BITS-1:0] useful;
    } tagged_row_t;


    base_idx_t s1_base_idx_q;
    tagged_idx_t s1_idx_q [TABLES];
    tag_t s1_tag_q [TABLES];
    logic s1_valid_q;
    base_row_t s2_base_q;
    tagged_row_t s2_row_q [TABLES];
    tag_t s2_tag_q [TABLES];
    logic s2_valid_q;

    // PC 区域号与 branch_history 的三个按表排列的 C 字段使用同一位序。
    function automatic logic [31:0] fold_pc(input vaddr_t region_base, input int width);
        logic [31:0] result;
        result = '0;
        for (int bit_idx = REGION_SHIFT; bit_idx < VADDR_W; bit_idx++)
            result[(bit_idx - REGION_SHIFT) % width] ^= region_base[bit_idx];
        return result;
    endfunction

    function automatic int fold_offset(input int table_idx);
        int result;
        result = 0;
        for (int idx = 0; idx < table_idx; idx++)
            result += int'(CFG.tage.index_bits[idx]) +
                      2 * int'(CFG.tage.tag_bits[idx]) - 1;
        return result;
    endfunction

    function automatic tagged_idx_t index_of(input vaddr_t pc,
                                              input logic [HIST_FOLD_W-1:0] folds,
                                              input int table_idx);
        logic [31:0] hist;
        int width;
        int offset;
        hist = '0;
        width = int'(CFG.tage.index_bits[table_idx]);
        offset = fold_offset(table_idx);
        for (int bit_idx = 0; bit_idx < width; bit_idx++)
            hist[bit_idx] = folds[offset + bit_idx];
        return tagged_idx_t'((fold_pc(pc, width) ^ hist) & ((32'd1 << width) - 1));
    endfunction

    function automatic tag_t tag_of(input vaddr_t pc,
                                    input logic [HIST_FOLD_W-1:0] folds,
                                    input int table_idx);
        logic [31:0] folded_tag;
        logic [31:0] folded_short;
        int width;
        int offset;
        folded_tag = '0;
        folded_short = '0;
        width = int'(CFG.tage.tag_bits[table_idx]);
        offset = fold_offset(table_idx) + int'(CFG.tage.index_bits[table_idx]);
        for (int bit_idx = 0; bit_idx < width; bit_idx++)
            folded_tag[bit_idx] = folds[offset + bit_idx];
        offset += width;
        for (int bit_idx = 0; bit_idx < width - 1; bit_idx++)
            folded_short[bit_idx] = folds[offset + bit_idx];
        return tag_t'((fold_pc(pc, width) ^ folded_tag ^ (folded_short << 1)) &
                     ((32'd1 << width) - 1));
    endfunction

    function automatic base_idx_t base_index_of(input vaddr_t pc);
        return base_idx_t'(fold_pc(pc, BASE_IDX_BITS));
    endfunction

    function automatic ctr_t train_ctr(input ctr_t previous, input logic taken);
        if (taken && previous != '1) return previous + ctr_t'(1);
        if (!taken && previous != '0) return previous - ctr_t'(1);
        return previous;
    endfunction

    function automatic useful_t train_useful(input useful_t previous, input logic up);
        if (up && previous != '1) return previous + useful_t'(1);
        if (!up && previous != '0) return previous - useful_t'(1);
        return previous;
    endfunction

    assign resp_valid_o = s2_valid_q && !stall_i && !kill_i && !rst_i;
    assign perf_o = '0;

    // All slots share the row tag. Compare each table once, then decode the
    // longest and second-longest matches into fixed one-hot read selects.
    logic [TABLES-1:0] query_hits, provider_oh, alt_oh;
    logic [META_PROVIDER_BITS-1:0] provider_code;
    for (genvar t=0; t<TABLES; t++) begin : g_query_select
        assign query_hits[t] = s2_row_q[t].valid && s2_row_q[t].tag == s2_tag_q[t];
        if (t == TABLES-1) assign provider_oh[t] = query_hits[t];
        else assign provider_oh[t] = query_hits[t] && !(|query_hits[TABLES-1:t+1]);
        if (t == TABLES-1) assign alt_oh[t] = 1'b0;
        else assign alt_oh[t] = query_hits[t] && !provider_oh[t]
            && !(|(query_hits[TABLES-1:t+1] & ~provider_oh[TABLES-1:t+1]));
    end
    always_comb begin
        provider_code = '0;
        for (int t=0; t<TABLES; t++)
            provider_code |= META_PROVIDER_BITS'(t) & {META_PROVIDER_BITS{provider_oh[t]}};
        if (!(|provider_oh)) provider_code = BASE_CODE;
    end
    for (genvar slot=0; slot<REGION_SLOTS; slot++) begin : g_direction
        ctr_t provider_ctr;
        useful_t provider_useful;
        logic alt_pred, weak_ctr, final_pred;
        always_comb begin
            provider_ctr = '0;
            provider_useful = '0;
            alt_pred = 1'b0;
            for (int t=0; t<TABLES; t++) begin
                provider_ctr |= s2_row_q[t].ctr[slot] & {CTR_BITS{provider_oh[t]}};
                provider_useful |= s2_row_q[t].useful[slot] & {USEFUL_BITS{provider_oh[t]}};
                alt_pred |= s2_row_q[t].ctr[slot][CTR_BITS-1] && alt_oh[t];
            end
            if (!(|provider_oh)) provider_ctr = s2_base_q[slot];
            if (!(|alt_oh)) alt_pred = s2_base_q[slot][CTR_BITS-1];
            weak_ctr = provider_ctr == ctr_t'((1 << (CTR_BITS-1))-1)
                    || provider_ctr == ctr_t'(1 << (CTR_BITS-1));
            final_pred = provider_ctr[CTR_BITS-1];
            if ((|provider_oh) && provider_useful == '0 && weak_ctr) final_pred = alt_pred;
        end
        assign resp_o.taken_mask[slot] = s2_valid_q && final_pred;
        assign resp_o.provider_hit_mask[slot] = s2_valid_q && (|provider_oh);
        assign resp_o.meta[slot*META_PROVIDER_BITS +: META_PROVIDER_BITS] = s2_valid_q ? provider_code : '0;
        assign resp_o.meta[META_ALT_OFFSET+slot] = s2_valid_q && alt_pred;
        assign resp_o.meta[META_PROVIDER_PRED_OFFSET+slot] = s2_valid_q && provider_ctr[CTR_BITS-1];
        assign resp_o.meta[META_FINAL_OFFSET+slot] = s2_valid_q && final_pred;
    end
    if (CFG.tage.meta_bits > META_USED_BITS) begin : g_unused_meta
        assign resp_o.meta[CFG.tage.meta_bits-1:META_USED_BITS] = '0;
    end

    // Training read replicas and write-new bypass of the atomic T2 write.
    bpu_train_t t1_packet_q;
    logic t1_valid_q, base_we, wb_base_valid_q;
    base_idx_t train_base_idx, wb_base_idx_q;
    tagged_idx_t train_idx[TABLES], wb_idx_q[TABLES];
    tag_t train_tag[TABLES];
    tagged_row_t train_old[TABLES],updated[TABLES],wb_row_q[TABLES];
    logic touched[TABLES],wb_valid_q[TABLES];
    base_row_t train_base_old,base_updated,base_qraw,base_traw,wb_base_data_q;
    logic base_wr_q[BASE_ENTRIES];
    logic tvalid_q[TABLES][MAX_ENTRIES];
    logic train_base_written_q;
    logic train_row_valid_q[TABLES];
    logic query_base_written_q,query_base_collision_q;
    base_row_t query_base_forward_q;
    function automatic base_row_t reset_base();
        base_row_t r;
        for(int slot=0;slot<REGION_SLOTS;slot++) r[slot]=ctr_t'((1<<(CTR_BITS-1))-1);
        return r;
    endfunction
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            train_base_written_q<=0;
            for(int t=0;t<TABLES;t++) train_row_valid_q[t]<=0;
        end else if (train_fire) begin
            train_base_idx <= base_index_of(train_i.region_base);
            train_base_written_q<=base_wr_q[base_index_of(train_i.region_base)];
            for (int t=0; t<TABLES; t++) begin
                train_idx[t] <= index_of(train_i.region_base,train_i.folds,t);
                train_tag[t] <= tag_of(train_i.region_base,train_i.folds,t);
                train_row_valid_q[t]<=tvalid_q[t][index_of(train_i.region_base,train_i.folds,t)];
            end
        end
    end
    assign base_we=!rst_i && t2_valid_q && |t2_packet_q.br_commit_mask;
    assign train_base_old=wb_base_valid_q && wb_base_idx_q==train_base_idx ? wb_base_data_q :
        (train_base_written_q ? base_traw : reset_base());
    assign s2_base_q=query_base_written_q ? (query_base_collision_q ? query_base_forward_q : base_qraw) : reset_base();
    o3_sram_1r1w #(.DATA_WIDTH($bits(base_row_t)),.ENTRIES(BASE_ENTRIES),.ALLOW_COLLISION(1)) u_base_query(
        .clk_i(clk_i),.read_en_i(!rst_i && !stall_i && !kill_i && s1_valid_q),.read_addr_i(s1_base_idx_q),.read_data_o(base_qraw),
        .write_en_i(base_we),.write_addr_i(t2_base_idx_q),.write_data_i(base_updated));
    o3_sram_1r1w #(.DATA_WIDTH($bits(base_row_t)),.ENTRIES(BASE_ENTRIES),.ALLOW_COLLISION(1)) u_base_train(
        .clk_i(clk_i),.read_en_i(train_fire),.read_addr_i(base_index_of(train_i.region_base)),.read_data_o(base_traw),
        .write_en_i(base_we),.write_addr_i(t2_base_idx_q),.write_data_i(base_updated));
    for(genvar t=0;t<TABLES;t++) begin : g_table
        localparam int IW=CFG.tage.index_bits[t],RW=CFG.tage.tag_bits[t]+REGION_SLOTS*(CTR_BITS+USEFUL_BITS);
        logic [RW-1:0] qraw,traw;
        logic query_collision_q,query_valid_q;
        tagged_row_t query_forward_q;
        always_comb begin
            train_old[t]=tagged_row_t'(traw);
            // Validity is sampled by T0 with the synchronous SRAM payload.
            // A same-edge T2 write is selected by the whole-row bypass below.
            train_old[t].valid=train_row_valid_q[t];
            if(wb_valid_q[t] && wb_idx_q[t]==train_idx[t]) train_old[t]=wb_row_q[t];
            s2_row_q[t]=query_collision_q ? query_forward_q : tagged_row_t'(qraw);
            s2_row_q[t].valid=query_valid_q;
        end
        o3_sram_1r1w #(.DATA_WIDTH(RW),.ENTRIES(1<<IW),.ALLOW_COLLISION(1)) u_query(
            .clk_i(clk_i),.read_en_i(!rst_i && !stall_i && !kill_i && s1_valid_q),.read_addr_i(IW'(s1_idx_q[t])),.read_data_o(qraw),
            .write_en_i(!rst_i && touched[t]),.write_addr_i(IW'(t2_idx_q[t])),.write_data_i(RW'(updated[t])));
        o3_sram_1r1w #(.DATA_WIDTH(RW),.ENTRIES(1<<IW),.ALLOW_COLLISION(1)) u_train(
            .clk_i(clk_i),.read_en_i(train_fire),.read_addr_i(IW'(index_of(train_i.region_base,train_i.folds,t))),.read_data_o(traw),
            .write_en_i(!rst_i && touched[t]),.write_addr_i(IW'(t2_idx_q[t])),.write_data_i(RW'(updated[t])));
        always_ff @(posedge clk_i) begin
            if(rst_i) begin
                query_collision_q<=0;query_valid_q<=0;query_forward_q<='0;
                wb_valid_q[t]<=0;wb_idx_q[t]<='0;wb_row_q[t]<='0;
                for(int n=0;n<(1<<IW);n++) tvalid_q[t][n]<=0;
            end else begin
                wb_valid_q[t]<=touched[t];wb_idx_q[t]<=t2_idx_q[t];wb_row_q[t]<=updated[t];
                if(touched[t]) tvalid_q[t][t2_idx_q[t]]<=updated[t].valid;
                if(!stall_i && !kill_i && s1_valid_q) begin
                    query_collision_q<=touched[t] && t2_idx_q[t]==s1_idx_q[t];
                    query_forward_q<=updated[t];
                    query_valid_q<=touched[t] && t2_idx_q[t]==s1_idx_q[t] ? updated[t].valid : tvalid_q[t][s1_idx_q[t]];
                end
            end
        end
    end
    // T1 updates slots 0..3; T2 updates slots 4..7 and atomically writes a row.
    // A T0 read may overlap the T2 write (forwarded), but not a T1 update of
    // the same row. Non-conflicting packets still enter on consecutive cycles.
    localparam int HALF=REGION_SLOTS/2;
    bpu_train_t t2_packet_q;
    logic t2_valid_q, train_fire, conflict;
    base_idx_t t2_base_idx_q;
    tagged_idx_t t2_idx_q[TABLES];
    tag_t t2_tag_q[TABLES];
    tagged_row_t first_updated[TABLES], t2_rows_q[TABLES];
    logic first_touched[TABLES], t2_touched_q[TABLES], second_touched[TABLES];
    logic [TABLES-1:0] original_match, t2_match_q;
    logic [TABLES-1:0] first_row_match, t2_row_match_q;
    base_row_t first_base_updated, t2_base_q;
    always_comb begin
        conflict=t1_valid_q && (|t1_packet_q.br_commit_mask) && (|train_i.br_commit_mask)
                 && base_index_of(train_i.region_base)==train_base_idx;
        for(int t=0;t<TABLES;t++) begin
            if(t1_valid_q && (|t1_packet_q.br_commit_mask) && (|train_i.br_commit_mask)
               && index_of(train_i.region_base,train_i.folds,t)==train_idx[t]) conflict=1'b1;
        end
    end
    assign train_ready_o=!rst_i && !conflict;
    assign train_fire=train_valid_i && train_ready_o;
    for(genvar t=0;t<TABLES;t++) begin : g_original_match
        assign original_match[t]=train_old[t].valid && train_old[t].tag==train_tag[t];
        assign touched[t]=t2_valid_q && (t2_touched_q[t] || second_touched[t]);
    end
    for(genvar slot=0;slot<REGION_SLOTS;slot++) begin : g_base_update
        assign first_base_updated[slot]=t1_valid_q && t1_packet_q.br_commit_mask[slot]
            ? train_ctr(train_base_old[slot],t1_packet_q.br_taken_mask[slot]) : train_base_old[slot];
    end
    assign base_updated=t2_base_q;
    tage_update_slice #(.CFG(CFG),.TAG_BITS(MAX_TAG_BITS),.FIRST_SLOT(0),.SLOT_COUNT(HALF)) u_train_first(
        .valid_i(t1_valid_q),.packet_i(t1_packet_q),.rows_i_bits(train_old),.tags_i(train_tag),
        .original_match_i(original_match),.row_match_i(original_match),
        .rows_o_bits(first_updated),.row_match_o(first_row_match),.touched_o(first_touched));
    tage_update_slice #(.CFG(CFG),.TAG_BITS(MAX_TAG_BITS),.FIRST_SLOT(HALF),.SLOT_COUNT(REGION_SLOTS-HALF)) u_train_second(
        .valid_i(t2_valid_q),.packet_i(t2_packet_q),.rows_i_bits(t2_rows_q),.tags_i(t2_tag_q),
        .original_match_i(t2_match_q),.row_match_i(t2_row_match_q),
        .rows_o_bits(updated),.row_match_o(),.touched_o(second_touched));
    always_ff @(posedge clk_i) begin
        if(rst_i) begin
            t2_valid_q<=0;t2_packet_q<='0;t2_match_q<='0;t2_row_match_q<='0;t2_base_q<='0;t2_base_idx_q<='0;
            for(int t=0;t<TABLES;t++) begin t2_rows_q[t]<='0;t2_tag_q[t]<='0;t2_idx_q[t]<='0;t2_touched_q[t]<=0;end
        end else begin
            t2_valid_q<=t1_valid_q;
            t2_packet_q<=t1_packet_q;t2_match_q<=original_match;
            // Allocation claims the incoming tag. Carry that ownership bit
            // across T1/T2 separately from the original provider match.
            t2_row_match_q<=first_row_match;
            t2_base_q<=first_base_updated;t2_base_idx_q<=train_base_idx;
            for(int t=0;t<TABLES;t++) begin
                t2_rows_q[t]<=first_updated[t];t2_tag_q[t]<=train_tag[t];
                t2_idx_q[t]<=train_idx[t];t2_touched_q[t]<=first_touched[t];
            end
        end
    end

`ifndef SYNTHESIS
    for (genvar t=0; t<TABLES; t++) begin : g_train_match_check
        always_ff @(posedge clk_i) begin
            if (!rst_i && t2_valid_q)
                assert (t2_row_match_q[t] ==
                    (t2_rows_q[t].valid && t2_rows_q[t].tag == t2_tag_q[t]));
        end
    end
`endif
    always_ff @(posedge clk_i) begin
        if(rst_i) begin
            s1_valid_q<=0;s2_valid_q<=0;t1_valid_q<=0;t1_packet_q<='0;
            wb_base_valid_q<=0;wb_base_idx_q<='0;wb_base_data_q<='0;
            query_base_written_q<=0;query_base_collision_q<=0;query_base_forward_q<='0;
            for(int n=0;n<BASE_ENTRIES;n++) base_wr_q[n]<=0;
        end else begin
            t1_valid_q<=train_fire;t1_packet_q<=train_i;
            wb_base_valid_q<=base_we;wb_base_idx_q<=t2_base_idx_q;wb_base_data_q<=base_updated;
            if(base_we) base_wr_q[t2_base_idx_q]<=1;
            if(kill_i) begin s1_valid_q<=0;s2_valid_q<=0;end
            else if(!stall_i) begin
                s2_valid_q<=s1_valid_q;
                if(s1_valid_q) begin
                    query_base_written_q<=base_wr_q[s1_base_idx_q] || (base_we && t2_base_idx_q==s1_base_idx_q);
                    query_base_collision_q<=base_we && t2_base_idx_q==s1_base_idx_q;
                    query_base_forward_q<=base_updated;
                    for(int t=0;t<TABLES;t++) s2_tag_q[t]<=s1_tag_q[t];
                end
                s1_valid_q<=s0_valid_i;
                if(s0_valid_i) begin
                    s1_base_idx_q<=base_index_of(s0_region_base_i);
                    for(int t=0;t<TABLES;t++) begin
                        s1_idx_q[t]<=index_of(s0_region_base_i,s0_folds_i,t);
                        s1_tag_q[t]<=tag_of(s0_region_base_i,s0_folds_i,t);
                    end
                end
            end
        end
    end

    initial begin
        assert (CFG.fetch.region_bytes == REGION_BYTES);
        assert (BASE_ENTRIES >= 2 && (BASE_ENTRIES & (BASE_ENTRIES - 1)) == 0);
        assert (TABLES <= (1 << META_PROVIDER_BITS) - 1);
        assert (CFG.tage.meta_bits >= META_USED_BITS);
        assert (CTR_BITS >= 2 && CTR_BITS <= 8);
        assert (USEFUL_BITS >= 1 && USEFUL_BITS <= 8);
        for (int table_idx = 0; table_idx < TABLES; table_idx++) begin
            assert (CFG.tage.index_bits[table_idx] >= 1);
            assert (CFG.tage.index_bits[table_idx] <= 20);
            assert (CFG.tage.tag_bits[table_idx] >= 2);
            assert (CFG.tage.tag_bits[table_idx] <= 31);
        end
    end
endmodule

// A bounded, combinational training slice. The original provider match travels
// separately from the current row ownership, so allocation by an earlier slot
// cannot turn stale prediction metadata into a valid provider update.
module tage_update_slice
    import o3_types_pkg::*;
#(parameter o3_cfg_pkg::frontend_cfg_t CFG,
  parameter int TAG_BITS=16, FIRST_SLOT=0, SLOT_COUNT=4,
  parameter int TABLES=o3_cfg_pkg::TAGE_TABLES,
  parameter int CTR_BITS=CFG.tage.ctr_bits, USEFUL_BITS=CFG.tage.useful_bits,
  parameter int ROW_BITS=1+TAG_BITS+REGION_SLOTS*(CTR_BITS+USEFUL_BITS))
(input logic valid_i,
 input bpu_train_t packet_i,
 input logic [ROW_BITS-1:0] rows_i_bits[TABLES],
 input logic [TAG_BITS-1:0] tags_i[TABLES],
 input logic [TABLES-1:0] original_match_i,
 input logic [TABLES-1:0] row_match_i,
 output logic [ROW_BITS-1:0] rows_o_bits[TABLES],
 output logic [TABLES-1:0] row_match_o,
 output logic touched_o[TABLES]);
    typedef struct packed {
        logic valid;
        logic [TAG_BITS-1:0] tag;
        logic [REGION_SLOTS-1:0][CTR_BITS-1:0] ctr;
        logic [REGION_SLOTS-1:0][USEFUL_BITS-1:0] useful;
    } row_t;
    row_t rows_i[TABLES], rows_o[TABLES];
    for(genvar t=0;t<TABLES;t++) begin : g_ports
        assign rows_i[t]=row_t'(rows_i_bits[t]);
        assign rows_o_bits[t]=rows_o[t];
    end
    typedef logic [CTR_BITS-1:0] ctr_t;
    typedef logic [USEFUL_BITS-1:0] useful_t;
    function automatic ctr_t train_ctr(input ctr_t previous, input logic taken);
        if (taken && previous != '1) return previous + ctr_t'(1);
        if (!taken && previous != '0) return previous - ctr_t'(1);
        return previous;
    endfunction
    function automatic useful_t train_useful(input useful_t previous, input logic up);
        if (up && previous != '1) return previous + useful_t'(1);
        if (!up && previous != '0) return previous - useful_t'(1);
        return previous;
    endfunction
    // Ordered allocation depends on row ownership and usefulness, never on
    // the wide ctr payload. Carry only that narrow state through this slice
    // of slot decisions. Each table/slot counter has one fixed local update.
    logic row_matches[TABLES], row_replace[TABLES];
    for (genvar slot=0; slot<SLOT_COUNT; slot++) begin : g_train_slot
        localparam int S=FIRST_SLOT+slot;
        logic active, wrong, provider_is_table;
        logic [META_PROVIDER_BITS-1:0] train_provider;
        logic [TABLES-1:0] provider_update,eligible,allocate,decay;
        assign train_provider = packet_i.tage_meta[S*META_PROVIDER_BITS +: META_PROVIDER_BITS];
        assign active = valid_i && packet_i.br_commit_mask[S];
        assign wrong = packet_i.tage_meta[META_FINAL_OFFSET+S] != packet_i.br_taken_mask[S];
        assign provider_is_table = train_provider < META_PROVIDER_BITS'(TABLES);
        for (genvar t=0; t<TABLES; t++) begin : g_table_control
            logic claimed_before, claimed_after;
            logic [REGION_SLOTS-1:0][USEFUL_BITS-1:0] useful_before, useful_after, useful_provider;
            if (slot == 0) begin : g_first
                assign claimed_before = 1'b0;
                assign useful_before = rows_i[t].useful;
            end else begin : g_previous
                assign claimed_before = g_train_slot[slot-1].g_table_control[t].claimed_after;
                assign useful_before = g_train_slot[slot-1].g_table_control[t].useful_after;
            end
            assign provider_update[t] = active && train_provider == META_PROVIDER_BITS'(t) && original_match_i[t];
            for (genvar k=0; k<REGION_SLOTS; k++) begin : g_useful_provider
                if (k == S) assign useful_provider[k] =
                    provider_update[t] && packet_i.tage_meta[META_PROVIDER_PRED_OFFSET+S] != packet_i.tage_meta[META_ALT_OFFSET+S]
                    ? train_useful(useful_before[k],packet_i.tage_meta[META_PROVIDER_PRED_OFFSET+S] == packet_i.br_taken_mask[S])
                    : useful_before[k];
                else assign useful_provider[k] = useful_before[k];
            end
            assign eligible[t] = (!provider_is_table || train_provider < META_PROVIDER_BITS'(t))
                && (!rows_i[t].valid || row_matches[t] || claimed_before || useful_provider == '0);
            if (t == 0) assign allocate[t] = active && wrong && eligible[t];
            else assign allocate[t] = active && wrong && eligible[t] && !(|eligible[t-1:0]);
            if (t == 0) assign decay[t] = active && wrong && !(|eligible) && !provider_is_table;
            else assign decay[t] = active && wrong && !(|eligible) && train_provider == META_PROVIDER_BITS'(t-1);
            assign claimed_after = claimed_before || allocate[t];
            for (genvar k=0; k<REGION_SLOTS; k++) begin : g_useful_next
                assign useful_after[k] =
                    (allocate[t] && ((!rows_i[t].valid || !row_matches[t]) && !claimed_before || k == S)) ? useful_t'('0) :
                    decay[t] ? train_useful(useful_provider[k],1'b0) : useful_provider[k];
            end
        end
    end
    for (genvar t=0; t<TABLES; t++) begin : g_train_table
        logic [REGION_SLOTS-1:0] writes;
        assign row_matches[t] = row_match_i[t];
        assign row_match_o[t] = row_matches[t] || g_train_slot[SLOT_COUNT-1].g_table_control[t].claimed_after;
        assign row_replace[t] = g_train_slot[SLOT_COUNT-1].g_table_control[t].claimed_after && !row_matches[t];
        assign rows_o[t].valid = rows_i[t].valid || g_train_slot[SLOT_COUNT-1].g_table_control[t].claimed_after;
        assign rows_o[t].tag = row_replace[t] ? tags_i[t] : rows_i[t].tag;
        assign rows_o[t].useful = g_train_slot[SLOT_COUNT-1].g_table_control[t].useful_after;
        for (genvar slot=0; slot<REGION_SLOTS; slot++) begin : g_counter
            if (slot>=FIRST_SLOT && slot<FIRST_SLOT+SLOT_COUNT) begin : g_active
                localparam int K=slot-FIRST_SLOT;
                assign writes[slot] = g_train_slot[K].provider_update[t] || g_train_slot[K].allocate[t] || g_train_slot[K].decay[t];
                assign rows_o[t].ctr[slot] = g_train_slot[K].allocate[t]
                    ? ctr_t'((1 << (CTR_BITS-1))-1 + int'(packet_i.br_taken_mask[slot]))
                    : row_replace[t] ? ctr_t'((1 << (CTR_BITS-1))-1)
                    : g_train_slot[K].provider_update[t] ? train_ctr(rows_i[t].ctr[slot],packet_i.br_taken_mask[slot])
                    : rows_i[t].ctr[slot];
            end else begin : g_keep
                assign writes[slot]=1'b0;
                assign rows_o[t].ctr[slot]=row_replace[t] ? ctr_t'((1 << (CTR_BITS-1))-1) : rows_i[t].ctr[slot];
            end
        end
        assign touched_o[t] = |writes;
    end
endmodule
