/**
 * 主 BTB —— 两拍查询，每个区域 entry 只存一个跳转目标
 *
 * 作用：
 * - 给出区域内预测的条件分支/JAL 位置 mask、唯一目标归属槽位、类型与目标，
 *   与 TAGE 方向结果在慢预测出口联合选择下一 PC（D02、D05，第 4.2 节）。
 *
 * 目标机制：
 * - 已定：一个区域 entry 一个目标（D05）。mask 知道多个分支位置，不代表拥有它们
 *   的全部目标；所选 taken 分支只有在 cfi_slot 匹配时才能使用 target。
 * - 已定：无可用目标时继续顺序取指，后续修正（D06）；保留 raw_pred_taken 与
 *   target_missing 统计口径（第 4.3 节），由 bpu_slow_check 生成。
 * - 已定：目标更新为该区域最近一次提交的 taken CFI；无 taken 时保留旧目标（D07）。
 * - 已定：提交时训练（D08）。
 * - 已定：“单目标”与“组相联”是独立维度。
 *
 * 首版组织（容量来自 O3_CFG，仍须测量资源和预测率）：
 * - 组相联；set 取 16B 区域号低位，剩余地址位 XOR 折叠成局部部分 tag。
 *   tag 碰撞可能形成错误预测，需由下游恢复；不把部分 tag 当作地址权限检查。
 * - 命中先更新原项；未命中先用空路；满组按每组 round-robin 选 victim。
 * - 没有已提交条件分支、也没有 taken CFI 的区域不占表项。其余训练把本次已
 *   提交条件分支位置并入 br_mask；提交的 taken BR/JAL 也并入
 *   相应 mask。最近一次提交的 taken CFI 独占 cfi_slot/type/action/target；
 *   无 taken 时旧目标不变。JALR 没有独立 mask，只能由 target owner 描述。
 * - RAS action 使用 bpu_train_t 的既有编码；长度并未出现在当前 BTB 合同中。
 *
 * 当前实现状态：表存储、各路查询寄存、匹配、替换与提交训练已实现。
 * 未实现：预测表显式失效/别名统计，及整体前端慢预测对齐。
 *
 * 目标周期行为（第 4.1 节）：
 * - 周期 N 组合：s0_valid_i 且 !stall_i/kill_i 时选中 set；先前查询的
 *   resp_o/resp_valid_o 可被下游消费。
 * - 周期 N 上升沿：锁存该 set 的所有 way、请求 tag 和有效位；同时可以提交训练。
 *   同 set 同拍读写按旧值读，训练的新值从下次查询开始可见。
 * - 周期 N+1：组合 tag 比较给出该查询的 resp_o；stall_i 时寄存结果保持且
 *   resp_valid_o 暂不输出，解除 stall 后重现一次；kill_i 立即压低 valid，
 *   并在上升沿清除在途查询。训练不受查询 stall/kill 影响。
 *
 * 单模块时序/功能测试见 sim/cocotb/main_btb/；本模块不嵌入仿真专用逻辑。
 */
module main_btb
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic       clk_i,
    input  logic       rst_i,

    input  logic       s0_valid_i,
    input  vaddr_t     s0_region_base_i,
    input  logic       stall_i,
    input  logic       kill_i,

    output logic       resp_valid_o,
    output btb_resp_t  resp_o,

    input  logic       train_valid_i,
    output logic       train_ready_o,
    input  bpu_train_t train_i,

    output fe_perf_t   perf_o
);
    localparam int SETS = CFG.btb.sets;
    localparam int WAYS = CFG.btb.ways;
    localparam int TAG_BITS = CFG.btb.tag_bits;
    localparam int REGION_SHIFT = $clog2(CFG.fetch.region_bytes);
    localparam int SET_BITS = $clog2(SETS);
    localparam int WAY_BITS = $clog2(WAYS);

    typedef logic [SET_BITS-1:0] set_t;
    typedef logic [TAG_BITS-1:0] tag_t;
    typedef logic [WAY_BITS-1:0] way_t;

    typedef struct packed {
        tag_t        tag;
        slot_mask_t  br_mask;
        slot_mask_t  jal_mask;
        fetch_slot_t cfi_slot;
        cfi_type_e   cfi_type;
        ras_action_e ras_action;
        vaddr_t      target;
        logic        cfi_is_rvc; // L7b actual instruction length/edge
        logic        is_edge;       // L7b actual instruction length/edge
    } btb_entry_t;

    btb_entry_t entry_q [SETS][WAYS];
    logic [WAYS-1:0] valid_q [SETS];
    way_t replace_q [SETS];

    // 查询读口在边沿锁存整组各路；有效位单独复位，以免清零数据阵列妨碍映射。
    btb_entry_t s1_entry_q [WAYS];
    logic [WAYS-1:0] s1_way_valid_q;
    tag_t s1_tag_q;
    logic s1_valid_q;

    function automatic set_t set_of(input vaddr_t region_base);
        return set_t'(region_base >> REGION_SHIFT);
    endfunction

    // 部分 tag 包含所有高地址位的折叠贡献；同 set 的 hash 冲突仍允许。
    function automatic tag_t tag_of(input vaddr_t region_base);
        tag_t result;
        result = '0;
        for (int bit_idx = REGION_SHIFT + SET_BITS; bit_idx < VADDR_W; bit_idx++) begin
            result[(bit_idx - REGION_SHIFT - SET_BITS) % TAG_BITS] ^= region_base[bit_idx];
        end
        return result;
    endfunction

    // 输出只有一次有效窗口；stall 不消费在途读，kill 优先于 stall 即时压制旧结果。
    assign resp_valid_o = s1_valid_q && !stall_i && !kill_i && !rst_i;
    assign train_ready_o = !rst_i;
    assign perf_o = '0;  // 当前 fe_perf_t 没有主 BTB 独立事件编号。

    always_comb begin
        resp_o = '0;
        if (s1_valid_q) begin
            for (int way = 0; way < WAYS; way++) begin
                if (!resp_o.hit && s1_way_valid_q[way] &&
                    (s1_entry_q[way].tag == s1_tag_q)) begin
                    resp_o.hit = 1'b1;
                    resp_o.br_mask = s1_entry_q[way].br_mask;
                    resp_o.jal_mask = s1_entry_q[way].jal_mask;
                    resp_o.cfi_slot = s1_entry_q[way].cfi_slot;
                    resp_o.cfi_type = s1_entry_q[way].cfi_type;
                    resp_o.ras_action = s1_entry_q[way].ras_action;
                    resp_o.cfi_is_rvc = s1_entry_q[way].cfi_is_rvc;
                    resp_o.is_edge = s1_entry_q[way].is_edge;
                    resp_o.target = s1_entry_q[way].target;
                end
            end
        end
    end

    always_ff @(posedge clk_i) begin : state_update
        set_t train_set;
        tag_t train_tag;
        int selected_way;
        logic matched;
        logic found_empty;
        btb_entry_t updated;

        if (rst_i) begin
            s1_valid_q <= 1'b0;
            s1_way_valid_q <= '0;
            s1_tag_q <= '0;
            for (int set_idx = 0; set_idx < SETS; set_idx++) begin
                valid_q[set_idx] <= '0;
                replace_q[set_idx] <= '0;
            end
        end else begin
            if (kill_i) begin
                s1_valid_q <= 1'b0;
            end else if (!stall_i) begin
                s1_valid_q <= s0_valid_i;
                if (s0_valid_i) begin
                    s1_tag_q <= tag_of(s0_region_base_i);
                    s1_way_valid_q <= valid_q[set_of(s0_region_base_i)];
                    for (int way = 0; way < WAYS; way++) begin
                        s1_entry_q[way] <= entry_q[set_of(s0_region_base_i)][way];
                    end
                end
            end

            // 提交路径与查询流水独立。NBA 使同拍读写碰撞明确为 read-old。
            if (train_valid_i && train_ready_o &&
                ((|train_i.br_commit_mask) ||
                 (train_i.cfi_valid && (train_i.cfi_type != CFI_NONE)))) begin
                train_set = set_of(train_i.region_base);
                train_tag = tag_of(train_i.region_base);
                selected_way = int'(replace_q[train_set]);
                matched = 1'b0;
                found_empty = 1'b0;
                for (int way = 0; way < WAYS; way++) begin
                    if (!matched && valid_q[train_set][way] &&
                        (entry_q[train_set][way].tag == train_tag)) begin
                        selected_way = way;
                        matched = 1'b1;
                    end
                end
                if (!matched) begin
                    for (int way = 0; way < WAYS; way++) begin
                        if (!found_empty && !valid_q[train_set][way]) begin
                            selected_way = way;
                            found_empty = 1'b1;
                        end
                    end
                end

                updated = '0;
                if (matched) updated = entry_q[train_set][selected_way];
                updated.cfi_is_rvc = train_i.cfi_is_rvc;
                updated.is_edge = train_i.is_edge;
                updated.tag = train_tag;
                updated.br_mask |= train_i.br_commit_mask;
                if (train_i.cfi_valid && (train_i.cfi_type != CFI_NONE)) begin
                    case (train_i.cfi_type)
                        CFI_BR: updated.br_mask[train_i.cfi_slot] = 1'b1;
                        CFI_JAL: updated.jal_mask[train_i.cfi_slot] = 1'b1;
                        default: ; // JALR 仅靠唯一目标归属表示。
                    endcase
                    updated.cfi_slot = train_i.cfi_slot;
                    updated.cfi_type = train_i.cfi_type;
                    updated.ras_action = train_i.ras_action;
                    updated.target = train_i.cfi_target;
                end
                entry_q[train_set][selected_way] <= updated;
                valid_q[train_set][selected_way] <= 1'b1;
                if (!matched && !found_empty) begin
                    replace_q[train_set] <= way_t'((selected_way + 1) % WAYS);
                end
            end
        end
    end

    initial begin
        assert (CFG.fetch.region_bytes > 0);
        assert ((CFG.fetch.region_bytes & (CFG.fetch.region_bytes - 1)) == 0);
        assert (SETS >= 2 && (SETS & (SETS - 1)) == 0);
        assert (WAYS >= 2 && (WAYS & (WAYS - 1)) == 0);
        assert (TAG_BITS >= 1);
    end
endmodule
