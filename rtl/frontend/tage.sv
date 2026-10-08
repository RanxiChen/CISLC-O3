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
 * loop、ITTAGE，也未优化 FPGA SRAM 映射或读口物理时序。perf_o 暂为零：
 * 本模块不知道哪些槽实际是 BR，不能把八个方向位误算为八条条件预测。
 *
 * 周期 N：s0_valid_i 时组合算 index/tag；上升沿锁存为 S1。
 * 周期 N+1：S1 同步读 base/tagged 各行；上升沿锁存为 S2。同拍训练
 * 同行时读旧值，训练新值从后续读口可见。
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
    assign train_ready_o = !rst_i;
    assign perf_o = '0;

    // S2 选最长匹配 tagged 行；弱且无用时用 alt，但保留 provider 元数据供训练。
    always_comb begin : select_direction
        logic provider_pred;
        logic alt_pred;
        logic final_pred;
        logic [META_PROVIDER_BITS-1:0] provider_code;
        useful_t provider_useful;
        ctr_t provider_ctr;
        logic weak_ctr;

        provider_code = BASE_CODE;
        provider_pred = 1'b0;
        alt_pred = 1'b0;
        final_pred = 1'b0;
        provider_useful = '0;
        provider_ctr = '0;
        weak_ctr = 1'b0;
        resp_o = '0;
        if (s2_valid_q) begin
            for (int slot = 0; slot < REGION_SLOTS; slot++) begin
                provider_code = BASE_CODE;
                provider_pred = s2_base_q[slot][CTR_BITS-1];
                alt_pred = provider_pred;
                provider_useful = '0;
                provider_ctr = s2_base_q[slot];
                for (int table_idx = 0; table_idx < TABLES; table_idx++) begin
                    if (s2_row_q[table_idx].valid &&
                        s2_row_q[table_idx].tag == s2_tag_q[table_idx]) begin
                        alt_pred = provider_pred;
                        provider_pred = s2_row_q[table_idx].ctr[slot][CTR_BITS-1];
                        provider_ctr = s2_row_q[table_idx].ctr[slot];
                        provider_useful = s2_row_q[table_idx].useful[slot];
                        provider_code = META_PROVIDER_BITS'(table_idx);
                    end
                end
                weak_ctr = (provider_ctr == ctr_t'((1 << (CTR_BITS-1)) - 1)) ||
                           (provider_ctr == ctr_t'(1 << (CTR_BITS-1)));
                final_pred = provider_pred;
                if (provider_code != BASE_CODE && provider_useful == '0 && weak_ctr)
                    final_pred = alt_pred;
                resp_o.taken_mask[slot] = final_pred;
                resp_o.provider_hit_mask[slot] = (provider_code != BASE_CODE);
                resp_o.meta[slot*META_PROVIDER_BITS +: META_PROVIDER_BITS] = provider_code;
                resp_o.meta[META_ALT_OFFSET + slot] = alt_pred;
                resp_o.meta[META_PROVIDER_PRED_OFFSET + slot] = provider_pred;
                resp_o.meta[META_FINAL_OFFSET + slot] = final_pred;
            end
        end
    end

    // T0 reads the training replicas and captures the packet. T1 computes
    // the legacy update and writes both replicas, forwarding the previous
    // T1 write across a read-during-write collision.
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
    logic query_base_written_q,query_base_collision_q;
    base_row_t query_base_forward_q;
    function automatic base_row_t reset_base();
        base_row_t r;
        for(int slot=0;slot<REGION_SLOTS;slot++) r[slot]=ctr_t'((1<<(CTR_BITS-1))-1);
        return r;
    endfunction
    assign train_base_idx=base_index_of(t1_packet_q.region_base);
    assign base_we=!rst_i && t1_valid_q && |t1_packet_q.br_commit_mask;
    assign train_base_old=wb_base_valid_q && wb_base_idx_q==train_base_idx ? wb_base_data_q :
        (base_wr_q[train_base_idx] ? base_traw : reset_base());
    assign s2_base_q=query_base_written_q ? (query_base_collision_q ? query_base_forward_q : base_qraw) : reset_base();
    o3_sram_1r1w #(.DATA_WIDTH($bits(base_row_t)),.ENTRIES(BASE_ENTRIES),.ALLOW_COLLISION(1)) u_base_query(
        .clk_i(clk_i),.read_en_i(!rst_i && !stall_i && !kill_i && s1_valid_q),.read_addr_i(s1_base_idx_q),.read_data_o(base_qraw),
        .write_en_i(base_we),.write_addr_i(train_base_idx),.write_data_i(base_updated));
    o3_sram_1r1w #(.DATA_WIDTH($bits(base_row_t)),.ENTRIES(BASE_ENTRIES),.ALLOW_COLLISION(1)) u_base_train(
        .clk_i(clk_i),.read_en_i(train_valid_i && !rst_i),.read_addr_i(base_index_of(train_i.region_base)),.read_data_o(base_traw),
        .write_en_i(base_we),.write_addr_i(train_base_idx),.write_data_i(base_updated));
    for(genvar t=0;t<TABLES;t++) begin : g_table
        localparam int IW=CFG.tage.index_bits[t],RW=CFG.tage.tag_bits[t]+REGION_SLOTS*(CTR_BITS+USEFUL_BITS);
        logic [RW-1:0] qraw,traw;
        logic query_collision_q,query_valid_q;
        tagged_row_t query_forward_q;
        assign train_idx[t]=index_of(t1_packet_q.region_base,t1_packet_q.folds,t);
        assign train_tag[t]=tag_of(t1_packet_q.region_base,t1_packet_q.folds,t);
        always_comb begin
            train_old[t]=tagged_row_t'(traw);
            train_old[t].valid=tvalid_q[t][train_idx[t]];
            if(wb_valid_q[t] && wb_idx_q[t]==train_idx[t]) train_old[t]=wb_row_q[t];
            s2_row_q[t]=query_collision_q ? query_forward_q : tagged_row_t'(qraw);
            s2_row_q[t].valid=query_valid_q;
        end
        o3_sram_1r1w #(.DATA_WIDTH(RW),.ENTRIES(1<<IW),.ALLOW_COLLISION(1)) u_query(
            .clk_i(clk_i),.read_en_i(!rst_i && !stall_i && !kill_i && s1_valid_q),.read_addr_i(IW'(s1_idx_q[t])),.read_data_o(qraw),
            .write_en_i(!rst_i && touched[t]),.write_addr_i(IW'(train_idx[t])),.write_data_i(RW'(updated[t])));
        o3_sram_1r1w #(.DATA_WIDTH(RW),.ENTRIES(1<<IW),.ALLOW_COLLISION(1)) u_train(
            .clk_i(clk_i),.read_en_i(train_valid_i && !rst_i),.read_addr_i(IW'(index_of(train_i.region_base,train_i.folds,t))),.read_data_o(traw),
            .write_en_i(!rst_i && touched[t]),.write_addr_i(IW'(train_idx[t])),.write_data_i(RW'(updated[t])));
        always_ff @(posedge clk_i) begin
            if(rst_i) begin
                query_collision_q<=0;query_valid_q<=0;query_forward_q<='0;
                wb_valid_q[t]<=0;wb_idx_q[t]<='0;wb_row_q[t]<='0;
                for(int n=0;n<(1<<IW);n++) tvalid_q[t][n]<=0;
            end else begin
                wb_valid_q[t]<=touched[t];wb_idx_q[t]<=train_idx[t];wb_row_q[t]<=updated[t];
                if(touched[t]) tvalid_q[t][train_idx[t]]<=updated[t].valid;
                if(!stall_i && !kill_i && s1_valid_q) begin
                    query_collision_q<=touched[t] && train_idx[t]==s1_idx_q[t];
                    query_forward_q<=updated[t];
                    query_valid_q<=touched[t] && train_idx[t]==s1_idx_q[t] ? updated[t].valid : tvalid_q[t][s1_idx_q[t]];
                end
            end
        end
    end
    always_comb begin : legacy_training_update
        int provider_idx,first_longer;
        logic provider_still_matches,allocated,actual_taken,meta_provider_pred,meta_alt_pred,meta_final_pred;
        provider_idx=0;first_longer=0;provider_still_matches=0;allocated=0;actual_taken=0;
        meta_provider_pred=0;meta_alt_pred=0;meta_final_pred=0;
        base_updated=train_base_old;
        for(int t=0;t<TABLES;t++) begin updated[t]=train_old[t];touched[t]=0;end
        if(base_we) begin
                for (int slot = 0; slot < REGION_SLOTS; slot++) begin
                    if (t1_packet_q.br_commit_mask[slot]) begin
                        actual_taken = t1_packet_q.br_taken_mask[slot];
                        base_updated[slot] =
                            train_ctr(train_base_old[slot], actual_taken);
                        provider_idx = int'(t1_packet_q.tage_meta[
                            slot*META_PROVIDER_BITS +: META_PROVIDER_BITS]);
                        meta_alt_pred = t1_packet_q.tage_meta[META_ALT_OFFSET + slot];
                        meta_provider_pred =
                            t1_packet_q.tage_meta[META_PROVIDER_PRED_OFFSET + slot];
                        meta_final_pred = t1_packet_q.tage_meta[META_FINAL_OFFSET + slot];
                        provider_still_matches = 1'b0;
                        if (provider_idx < TABLES)
                            provider_still_matches =
                                train_old[provider_idx].valid &&
                                train_old[provider_idx].tag ==
                                train_tag[provider_idx];
                        if (provider_still_matches) begin
                            updated[provider_idx].ctr[slot] =
                                train_ctr(updated[provider_idx].ctr[slot], actual_taken);
                            if (meta_provider_pred != meta_alt_pred)
                                updated[provider_idx].useful[slot] = train_useful(
                                    updated[provider_idx].useful[slot],
                                    meta_provider_pred == actual_taken);
                            touched[provider_idx] = 1'b1;
                        end

                        if (meta_final_pred != actual_taken) begin
                            first_longer = (provider_idx < TABLES) ? provider_idx + 1 : 0;
                            allocated = 1'b0;
                            for (int table_idx = 0; table_idx < TABLES;
                                 table_idx++) begin
                                if (table_idx >= first_longer && !allocated && (!updated[table_idx].valid ||
                                    updated[table_idx].tag == train_tag[table_idx] ||
                                    updated[table_idx].useful == '0)) begin
                                    if (!updated[table_idx].valid ||
                                        updated[table_idx].tag != train_tag[table_idx]) begin
                                        updated[table_idx] = '0;
                                        updated[table_idx].valid = 1'b1;
                                        updated[table_idx].tag = train_tag[table_idx];
                                        for (int other_slot = 0; other_slot < REGION_SLOTS;
                                             other_slot++)
                                            updated[table_idx].ctr[other_slot] =
                                                ctr_t'((1 << (CTR_BITS-1)) - 1);
                                    end
                                    updated[table_idx].ctr[slot] =
                                        ctr_t'((1 << (CTR_BITS-1)) - 1 + int'(actual_taken));
                                    updated[table_idx].useful[slot] = '0;
                                    touched[table_idx] = 1'b1;
                                    allocated = 1'b1;
                                end
                            end
                            if (!allocated && first_longer < TABLES) begin
                                // 所有候选都仍有 useful：衰减最短候选，下次可分配。
                                for (int other_slot = 0; other_slot < REGION_SLOTS;
                                     other_slot++)
                                    updated[first_longer].useful[other_slot] =
                                        train_useful(updated[first_longer].useful[other_slot],
                                                     1'b0);
                                touched[first_longer] = 1'b1;
                            end
                        end
                    end
                end
        end
    end
    always_ff @(posedge clk_i) begin
        if(rst_i) begin
            s1_valid_q<=0;s2_valid_q<=0;t1_valid_q<=0;t1_packet_q<='0;
            wb_base_valid_q<=0;wb_base_idx_q<='0;wb_base_data_q<='0;
            query_base_written_q<=0;query_base_collision_q<=0;query_base_forward_q<='0;
            for(int n=0;n<BASE_ENTRIES;n++) base_wr_q[n]<=0;
        end else begin
            t1_valid_q<=train_valid_i;t1_packet_q<=train_i;
            wb_base_valid_q<=base_we;wb_base_idx_q<=train_base_idx;wb_base_data_q<=base_updated;
            if(base_we) base_wr_q[train_base_idx]<=1;
            if(kill_i) begin s1_valid_q<=0;s2_valid_q<=0;end
            else if(!stall_i) begin
                s2_valid_q<=s1_valid_q;
                if(s1_valid_q) begin
                    query_base_written_q<=base_wr_q[s1_base_idx_q] || (base_we && train_base_idx==s1_base_idx_q);
                    query_base_collision_q<=base_we && train_base_idx==s1_base_idx_q;
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
