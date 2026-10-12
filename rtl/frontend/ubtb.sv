/**
 * uBTB —— 同周期组合快预测，每拍可给出下一区域入口。
 *
 * 首版实现：CFG.ubtb.entries 项全相联、CFG.ubtb.tag_bits 位折叠部分 tag；
 * 每项累积已提交 BR/JAL mask，并只保存最近一次提交 taken CFI 的目标。
 * 条件分支的目标所有者另有 2-bit 饱和方向计数器：首次 taken 安装为弱 taken，
 * 此后 owner 再 taken 加一、owner 已提交但未 taken 减一。JAL/JALR 恒预测 taken。
 * 新区域只为 taken CFI 分配；已命中项仍累积 not-taken BR 训练。
 * 空项优先、满表按全局 round-robin 替换；stall 不影响独立的提交训练。
 *
 * 不实现：多目标、历史相关快方向、显式表失效、完整地址 tag 和别名检测。
 * 部分 tag 别名可能给出错误快预测，须由后续慢预测/执行恢复。单目标 owner
 * 位于入口槽之前或 BR 计数器为 not-taken 时，只沿顺序路径走。RAS 返回目标
 * 尚不由本模块改写；JALR 暂用最近一次提交的实际目标，依赖后续修正。
 * 扩展入口是表项组织、替换策略和方向状态；不改变 BPU/FTQ 合同。
 *
 * 周期 N 组合：有效且未 stall 的 lookup_pc_i 在全表比较；pred_o 同拍给出
 * 区域、入口槽、mask、被选择的 CFI 和 next_pc。hit_o 表示 tag 命中，
 * 不表示一定选择 taken。复位/stall/无查询时输出无效结果；train_ready_o
 * 只在复位时为 0。PE_UBTB_LOOKUP/HIT 对有效查询给出当拍增量。
 * 周期 N 上升沿：T0选行并捕获训练包/旧值，T1更新一个表项；BPU 查询仍是组合且与训练无端口冲突。
 * 同址相邻训练通过pending CAM计划与完整旧值旁路保持II1。目标存于query/train两份单写RAM，元数据独立。
 * 周期 N+2：查询使用更新后的表；stall 本身不保持内部查询寄存器，
 * 预测 PC 的保持由 BPU/FTQ 分配握手负责。
 *
 * 单模块时序/功能测试见 sim/cocotb/ubtb/；本模块无仿真专用逻辑。
 */
module ubtb
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic       clk_i,
    input  logic       rst_i,

    input  logic       lookup_valid_i,
    input  vaddr_t     lookup_pc_i,
    input  logic       stall_i,
    output logic       hit_o,
    output bpu_pred_t  pred_o,

    input  logic       train_valid_i,
    output logic       train_ready_o,
    input  bpu_train_t train_i,

    output fe_perf_t   perf_o
);
    localparam int ENTRIES = CFG.ubtb.entries;
    localparam int TAG_BITS = CFG.ubtb.tag_bits;
    localparam int REGION_SHIFT = $clog2(CFG.fetch.region_bytes);
    localparam int PTR_BITS = (ENTRIES > 1) ? $clog2(ENTRIES) : 1;

    typedef logic [TAG_BITS-1:0] tag_t;
    typedef logic [PTR_BITS-1:0] ptr_t;

    typedef struct packed {
        tag_t        tag;
        slot_mask_t  br_mask;
        slot_mask_t  jal_mask;
        logic        owner_valid;
        fetch_slot_t cfi_slot;
        cfi_type_e   cfi_type;
        ras_action_e ras_action;
        logic [1:0]  br_ctr;
        logic        cfi_is_rvc; // L7b actual instruction length/edge
        logic        is_edge;       // L7b actual instruction length/edge
    } ubtb_meta_t;

    ubtb_meta_t entry_q [ENTRIES];
    logic [ENTRIES-1:0] valid_q;
    ptr_t replace_q;
    // T0 chooses a stationary CAM row and snapshots its old payload. T1
    // updates confidence/owner/masks and writes it. Pending T0 tag/valid/RR
    // forwarding and previous T1 data forwarding permit one training per cycle.
    bpu_train_t t1_packet_q;
    tag_t t1_tag_q;
    ptr_t t1_row_q,wb_row_q;
    logic t1_valid_q,t1_matched_q,t1_replace_q,wb_valid_q;
    ubtb_meta_t t1_old_q,wb_meta_q,write_meta;
    vaddr_t t1_target_q,wb_target_q,write_target,query_target;
    ptr_t train_row,query_row;
    logic train_matched,train_replace,train_write,write_valid;
    tag_t incoming_tag;
    (* ram_style="distributed" *) logic [VADDR_W-1:0] query_target_mem[ENTRIES];
    (* ram_style="distributed" *) logic [VADDR_W-1:0] train_target_mem[ENTRIES];
    assign query_target=query_target_mem[query_row];
    assign write_valid=!rst_i && t1_valid_q;
    always_ff @(posedge clk_i) if(write_valid) begin
        query_target_mem[t1_row_q]<=write_target;
        train_target_mem[t1_row_q]<=write_target;
    end

    // 全部区域号位参与折叠；tag 比完整地址短，碰撞是明确的首版取舍。
    function automatic tag_t tag_of(input vaddr_t region_base);
        tag_t result;
        result = '0;
        for (int bit_idx = REGION_SHIFT; bit_idx < VADDR_W; bit_idx++) begin
            result[(bit_idx - REGION_SHIFT) % TAG_BITS] ^= region_base[bit_idx];
        end
        return result;
    endfunction

    function automatic logic [1:0] ctr_inc(input logic [1:0] ctr);
        return (ctr == 2'b11) ? ctr : ctr + 2'd1;
    endfunction

    function automatic logic [1:0] ctr_dec(input logic [1:0] ctr);
        return (ctr == 2'b00) ? ctr : ctr - 2'd1;
    endfunction

    assign train_ready_o = !rst_i;

    // Fully associative tag comparators with a fixed first-hit one-hot select.
    // Owner eligibility is computed per row before the late tag result arrives.
    vaddr_t lookup_region;
    fetch_slot_t lookup_entry;
    tag_t lookup_tag;
    logic [ENTRIES-1:0] lookup_hits,lookup_pick,owner_pick;
    bpu_pred_t owner_payload[ENTRIES],owner_prediction;
    assign lookup_region=(lookup_pc_i >> REGION_SHIFT) << REGION_SHIFT;
    assign lookup_entry=fetch_slot_t'(lookup_pc_i[REGION_SHIFT-1:1]);
    assign lookup_tag=tag_of(lookup_region);
    for(genvar idx=0;idx<ENTRIES;idx++) begin : g_fast_row
        assign lookup_hits[idx]=valid_q[idx] && entry_q[idx].tag==lookup_tag;
        if(idx==0) assign lookup_pick[idx]=lookup_hits[idx];
        else assign lookup_pick[idx]=lookup_hits[idx] && !(|lookup_hits[idx-1:0]);
        assign owner_pick[idx]=lookup_pick[idx] && entry_q[idx].owner_valid
            && entry_q[idx].cfi_slot>=lookup_entry
            && (entry_q[idx].cfi_type==CFI_JAL || entry_q[idx].cfi_type==CFI_JALR
                || (entry_q[idx].cfi_type==CFI_BR && entry_q[idx].br_ctr[1]));
        always_comb begin
            owner_payload[idx]='0;
            owner_payload[idx].cfi_valid=1;
            owner_payload[idx].cfi_slot=entry_q[idx].cfi_slot;
            owner_payload[idx].cfi_type=entry_q[idx].cfi_type;
            owner_payload[idx].ras_action=entry_q[idx].ras_action;
            owner_payload[idx].raw_pred_taken=1;
            owner_payload[idx].cfi_is_rvc=entry_q[idx].cfi_is_rvc;
            owner_payload[idx].is_edge=entry_q[idx].is_edge;

        end
    end
    always_comb begin : lookup
        owner_prediction='0;pred_o='0;perf_o='0;hit_o=0;query_row='0;
        for(int idx=0;idx<ENTRIES;idx++) query_row|=ptr_t'(idx) & {PTR_BITS{lookup_pick[idx]}};
        for(int idx=0;idx<ENTRIES;idx++)
            owner_prediction |= owner_payload[idx] & {$bits(bpu_pred_t){owner_pick[idx]}};
        if(lookup_valid_i && !stall_i && !rst_i) begin
            pred_o=owner_prediction;
            if(owner_prediction.cfi_valid) begin pred_o.cfi_target=query_target;pred_o.next_pc=query_target;end
            pred_o.region_base=lookup_region;
            pred_o.entry_slot=lookup_entry;
            if(!owner_prediction.cfi_valid) pred_o.next_pc=lookup_region+vaddr_t'(CFG.fetch.region_bytes);
            for(int idx=0;idx<ENTRIES;idx++) begin
                pred_o.br_mask |= entry_q[idx].br_mask & {REGION_SLOTS{lookup_pick[idx]}};
                pred_o.jal_mask |= entry_q[idx].jal_mask & {REGION_SLOTS{lookup_pick[idx]}};
            end
            hit_o=|lookup_hits;
            perf_o[PE_UBTB_LOOKUP]=1;
            perf_o[PE_UBTB_HIT]=PERF_INC_W'(hit_o);
        end
    end

    // T0 CAM selection includes the row that T1 will write on this edge.
    // Only its narrow tag/valid/replacement plan feeds this decision; numerical
    // target and confidence updates do not feed the CAM priority chain.
    assign incoming_tag=tag_of(train_i.region_base);
    function automatic logic [ENTRIES-1:0] first_onehot(input logic [ENTRIES-1:0] hits);
        logic [ENTRIES-1:0] pick;
        for(int n=0;n<ENTRIES;n++) pick[n]=hits[n] && !(|(hits & ((ENTRIES'(1)<<n)-ENTRIES'(1))));
        return pick;
    endfunction
    always_comb begin
        logic [ENTRIES-1:0] hits,empty,hit_pick,empty_pick,chosen;
        logic virtual_valid;
        tag_t virtual_tag;
        ptr_t replacement;
        for(int idx=0;idx<ENTRIES;idx++) begin
            virtual_valid=valid_q[idx] || (t1_valid_q && t1_row_q==ptr_t'(idx));
            virtual_tag=t1_valid_q && t1_row_q==ptr_t'(idx) ? t1_tag_q:entry_q[idx].tag;
            hits[idx]=virtual_valid && virtual_tag==incoming_tag;
            empty[idx]=!virtual_valid;
        end
        hit_pick=first_onehot(hits);empty_pick=first_onehot(empty);
        train_matched=|hits;
        replacement=t1_valid_q && t1_replace_q ? ptr_t'((int'(t1_row_q)+1)%ENTRIES):replace_q;
        chosen=train_matched ? hit_pick:empty_pick;
        train_row=|chosen ? '0:replacement;
        for(int idx=0;idx<ENTRIES;idx++) train_row|=ptr_t'(idx) & {PTR_BITS{chosen[idx]}};
        train_write=train_valid_i && train_ready_o &&
            ((|train_i.br_commit_mask) || (train_i.cfi_valid && train_i.cfi_type!=CFI_NONE)) &&
            (train_matched || (train_i.cfi_valid && train_i.cfi_type!=CFI_NONE));
        train_replace=!train_matched && !(|empty);
    end

    // T1 RAW forwarding covers consecutive training of the same row. T0's
    // snapshot precedes the older write; a matching previous write supplies
    // the complete old confidence/masks/owner/target image to this update.
    always_comb begin
        ubtb_meta_t old;
        vaddr_t old_target;
        old=wb_valid_q && wb_row_q==t1_row_q ? wb_meta_q:t1_old_q;
        old_target=wb_valid_q && wb_row_q==t1_row_q ? wb_target_q:t1_target_q;
        write_meta='0;write_target='0;
        if(t1_matched_q) begin write_meta=old;write_target=old_target;end
        write_meta.cfi_is_rvc=t1_packet_q.cfi_is_rvc;
        write_meta.is_edge=t1_packet_q.is_edge;
        write_meta.tag=t1_tag_q;
        write_meta.br_mask|=t1_packet_q.br_commit_mask;
        if(t1_packet_q.cfi_valid && t1_packet_q.cfi_type!=CFI_NONE) begin
            if(t1_packet_q.cfi_type==CFI_BR) begin
                write_meta.br_mask[t1_packet_q.cfi_slot]=1'b1;
                if(t1_matched_q && write_meta.owner_valid && write_meta.cfi_type==CFI_BR &&
                    write_meta.cfi_slot==t1_packet_q.cfi_slot) write_meta.br_ctr=ctr_inc(write_meta.br_ctr);
                else write_meta.br_ctr=2'b10;
            end else write_meta.br_ctr='0;
            if(t1_packet_q.cfi_type==CFI_JAL) write_meta.jal_mask[t1_packet_q.cfi_slot]=1'b1;
            write_meta.owner_valid=1'b1;write_meta.cfi_slot=t1_packet_q.cfi_slot;
            write_meta.cfi_type=t1_packet_q.cfi_type;write_meta.ras_action=t1_packet_q.ras_action;
            write_target=t1_packet_q.cfi_target;
        end else if(t1_matched_q && write_meta.owner_valid && write_meta.cfi_type==CFI_BR &&
                     t1_packet_q.br_commit_mask[write_meta.cfi_slot]) write_meta.br_ctr=ctr_dec(write_meta.br_ctr);
    end
    always_ff @(posedge clk_i) begin
        if(rst_i) begin
            valid_q<='0;replace_q<='0;t1_valid_q<=0;wb_valid_q<=0;
            t1_packet_q<='0;t1_tag_q<='0;t1_row_q<='0;t1_matched_q<=0;t1_replace_q<=0;
            t1_old_q<='0;t1_target_q<='0;wb_row_q<='0;wb_meta_q<='0;wb_target_q<='0;
        end else begin
            t1_valid_q<=train_write;t1_packet_q<=train_i;t1_tag_q<=incoming_tag;
            t1_row_q<=train_row;t1_matched_q<=train_matched;t1_replace_q<=train_replace;
            t1_old_q<=entry_q[train_row];t1_target_q<=train_target_mem[train_row];
            wb_valid_q<=write_valid;wb_row_q<=t1_row_q;wb_meta_q<=write_meta;wb_target_q<=write_target;
            if(write_valid) begin
                entry_q[t1_row_q]<=write_meta;valid_q[t1_row_q]<=1'b1;
                if(t1_replace_q) replace_q<=ptr_t'((int'(t1_row_q)+1)%ENTRIES);
            end
        end
    end

    initial begin
        assert (CFG.fetch.region_bytes >= 2);
        assert ((CFG.fetch.region_bytes & (CFG.fetch.region_bytes - 1)) == 0);
        assert (CFG.fetch.region_bytes / 2 == REGION_SLOTS);
        assert (ENTRIES >= 2);
        assert (TAG_BITS >= 1);
    end
endmodule
