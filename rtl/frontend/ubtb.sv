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
 * 周期 N 上升沿：仅有效训练更新一个表项；BPU 可在同一边沿采样边沿前的
 * 组合预测。训练与查询没有端口冲突，边沿前看到旧表，边沿后看到新表。
 * 周期 N+1：下一查询使用更新后的表；stall 本身不保持内部查询寄存器，
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
        vaddr_t      target;
        logic [1:0]  br_ctr;
        logic        cfi_is_rvc; // L7b actual instruction length/edge
        logic        is_edge;       // L7b actual instruction length/edge
    } ubtb_entry_t;

    ubtb_entry_t entry_q [ENTRIES];
    logic [ENTRIES-1:0] valid_q;
    ptr_t replace_q;

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

    // 组合快路径：从实际入口槽向后才允许采用所存的单个目标。
    always_comb begin : lookup
        vaddr_t region_base;
        fetch_slot_t entry_slot;
        tag_t lookup_tag;
        ubtb_entry_t selected;
        logic selected_valid;
        logic take_owner;

        region_base = (lookup_pc_i >> REGION_SHIFT) << REGION_SHIFT;
        entry_slot = fetch_slot_t'(lookup_pc_i[REGION_SHIFT-1:1]);
        lookup_tag = tag_of(region_base);
        selected = '0;
        selected_valid = 1'b0;
        take_owner = 1'b0;
        hit_o = 1'b0;
        pred_o = '0;
        perf_o = '0;

        if (lookup_valid_i && !stall_i && !rst_i) begin
            pred_o.region_base = region_base;
            pred_o.entry_slot = entry_slot;
            pred_o.next_pc = region_base + vaddr_t'(CFG.fetch.region_bytes);
            perf_o[PE_UBTB_LOOKUP] = 1;

            for (int idx = 0; idx < ENTRIES; idx++) begin
                if (!selected_valid && valid_q[idx] && entry_q[idx].tag == lookup_tag) begin
                    selected = entry_q[idx];
                    selected_valid = 1'b1;
                end
            end
            hit_o = selected_valid;
            if (selected_valid) begin
                perf_o[PE_UBTB_HIT] = 1;
                pred_o.br_mask = selected.br_mask;
                pred_o.jal_mask = selected.jal_mask;
                take_owner = selected.owner_valid && selected.cfi_slot >= entry_slot &&
                             ((selected.cfi_type == CFI_JAL) ||
                              (selected.cfi_type == CFI_JALR) ||
                              ((selected.cfi_type == CFI_BR) && selected.br_ctr[1]));
                if (take_owner) begin
                    pred_o.cfi_valid = 1'b1;
                    pred_o.cfi_slot = selected.cfi_slot;
                    pred_o.cfi_type = selected.cfi_type;
                    pred_o.ras_action = selected.ras_action;
                    pred_o.raw_pred_taken = 1'b1;
                    pred_o.cfi_is_rvc = selected.cfi_is_rvc;
                    pred_o.is_edge = selected.is_edge;
                    pred_o.cfi_target = selected.target;
                    pred_o.next_pc = selected.target;
                end
            end
        end
    end

    // 只有提交训练可写表；同拍查表在边沿前使用旧状态，下一拍使用新状态。
    always_ff @(posedge clk_i) begin : update_table
        tag_t train_tag;
        int selected_idx;
        logic matched;
        logic found_empty;
        ubtb_entry_t updated;

        if (rst_i) begin
            valid_q <= '0;
            replace_q <= '0;
        end else if (train_valid_i && train_ready_o &&
                     ((|train_i.br_commit_mask) ||
                      (train_i.cfi_valid && train_i.cfi_type != CFI_NONE))) begin
            train_tag = tag_of(train_i.region_base);
            selected_idx = int'(replace_q);
            matched = 1'b0;
            found_empty = 1'b0;
            for (int idx = 0; idx < ENTRIES; idx++) begin
                if (!matched && valid_q[idx] && entry_q[idx].tag == train_tag) begin
                    selected_idx = idx;
                    matched = 1'b1;
                end
            end
            if (!matched) begin
                for (int idx = 0; idx < ENTRIES; idx++) begin
                    if (!found_empty && !valid_q[idx]) begin
                        selected_idx = idx;
                        found_empty = 1'b1;
                    end
                end
            end

            updated = '0;
            if (matched) updated = entry_q[selected_idx];
            updated.cfi_is_rvc = train_i.cfi_is_rvc;
            updated.is_edge = train_i.is_edge;
            updated.tag = train_tag;
            updated.br_mask |= train_i.br_commit_mask;
            if (train_i.cfi_valid && train_i.cfi_type != CFI_NONE) begin
                // 新 owner 替换目标；同一 BR owner 才累积方向信心。
                if (train_i.cfi_type == CFI_BR) begin
                    updated.br_mask[train_i.cfi_slot] = 1'b1;
                    if (matched && updated.owner_valid &&
                        updated.cfi_type == CFI_BR && updated.cfi_slot == train_i.cfi_slot)
                        updated.br_ctr = ctr_inc(updated.br_ctr);
                    else
                        updated.br_ctr = 2'b10;
                end else begin
                    updated.br_ctr = '0;
                end
                if (train_i.cfi_type == CFI_JAL)
                    updated.jal_mask[train_i.cfi_slot] = 1'b1;
                updated.owner_valid = 1'b1;
                updated.cfi_slot = train_i.cfi_slot;
                updated.cfi_type = train_i.cfi_type;
                updated.ras_action = train_i.ras_action;
                updated.target = train_i.cfi_target;
            end else if (matched && updated.owner_valid && updated.cfi_type == CFI_BR &&
                         train_i.br_commit_mask[updated.cfi_slot]) begin
                // 没有 taken CFI 但 owner BR 确实提交，才让该方向计数器退一步。
                updated.br_ctr = ctr_dec(updated.br_ctr);
            end
            if (matched || (train_i.cfi_valid && train_i.cfi_type != CFI_NONE)) begin
                entry_q[selected_idx] <= updated;
                valid_q[selected_idx] <= 1'b1;
                if (!matched && !found_empty)
                    replace_q <= ptr_t'((selected_idx + 1) % ENTRIES);
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
