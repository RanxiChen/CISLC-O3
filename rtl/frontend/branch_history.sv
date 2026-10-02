/**
 * 分支历史 —— 推测路径的 taken 条件分支事件序列 E 与折叠值 C
 *
 * 作用：
 * - 维护沿实际采用预测路径推进的推测历史：最近 HIST_WINDOW 个 8 位事件 E，以及
 *   每张 TAGE 表的三个折叠值 C(L_i,n_i)、C(L_i,t_i)、C(L_i,t_i-1)。
 * - 为每个新分配区域给出入口快照 cur_o（写入 history_snapshot_store）。
 * - 恢复时装载出错区域的入口快照，再按正确结果注入事件。
 *
 * 目标机制：
 * - 已定（D09）：只有被实际选为 taken 且具有可用目标的条件分支推进历史；NT、JAL、
 *   JALR、call/return 不推进，NT 不插 0。预测、慢覆盖、预解码/执行恢复、提交参考
 *   历史使用同一资格规则。
 * - 暂定（D22）：e = fold_8(branch_PC >> 1) XOR rol_8(fold_8(target_PC >> 1), 1)；
 *   E_next[0] = e，E_next[a] = E[a-1]；
 *   C_next = rol_w(C, 2) XOR fold_w(e) XOR rol_w(fold_w(e_out), 2*L)，
 *   e_out = 更新前 E[L-1]，必须在写入覆盖前取得。多表同时更新只追加一次事件。
 * - 已定（D23）：恢复 E 的实际内容和 C，不能只恢复环形指针；恢复后 E 与 C 一致。
 * - 已定（D24）：恢复期间停止新预测；恢复可以多拍，用 restore_done_o 握手；
 *   恢复期间被更老请求替换时，旧恢复不得在随后覆盖新状态。
 * - 目标缺失而沿顺序路径时不更新历史（第 4.3 节）。
 *
 * 细节待定：
 * - E 用寄存器阵列、多读 mux 还是复制存储；每次更新取六个窗口边界事件的端口方案
 *   （第 5.4 节）。
 * - 恢复带宽与拍数。
 *
 * 当前实现状态：E 使用可并行读取窗口边界的寄存器移位阵列；C 按 D22 增量更新。
 * 恢复优先于普通推进，在同一上升沿装载完整 E/C 并可注入一条修正事件。
 *
 * 目标周期行为：
 * - 周期 N 组合：cur_o 给出当前推测历史（即下一个被分配区域的入口历史）。
 * - 周期 N 上升沿：push_valid_i 时追加一次事件并增量更新全部 C；
 *   restore_valid_i 时装载快照（优先于 push），restore_inject_i 时随后注入一次修正事件。
 * - 周期 N 组合：restore_done_o 随有效恢复请求给出，表示本拍上升沿可完成恢复。
 * - 周期 N+1：cur_o 反映更新或恢复后的历史，可用于新区域预测。
 *
 * 对应的 SV 时序测试放在 tb/frontend；静态检查不等于功能验证。
 */
module branch_history
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic           clk_i,
    input  logic           rst_i,

    // 推测推进：每拍至多一个 taken 条件分支事件（区域在 taken CFI 处结束）
    input  logic           push_valid_i,
    input  vaddr_t         push_branch_pc_i,
    input  vaddr_t         push_target_pc_i,

    // 当前推测历史：分配新区域时写入快照存储，TAGE 查询使用其 folds
    output hist_snapshot_t cur_o,

    // 恢复：装载出错区域入口快照，再按正确结果注入（D23）
    input  logic           restore_valid_i,
    input  hist_snapshot_t restore_snapshot_i,
    input  logic           restore_inject_i,
    input  vaddr_t         restore_branch_pc_i,
    input  vaddr_t         restore_target_pc_i,
    output logic           restore_done_o
);
    hist_snapshot_t history_q;

    // 按无符号 PC[...:1] 分段异或，RVC 的地址 bit1 不丢弃。
    function automatic hist_event_t encode_event(input vaddr_t branch_pc,
                                                 input vaddr_t target_pc);
        hist_event_t branch_fold;
        hist_event_t target_fold;
        hist_event_t target_rot;
        branch_fold = '0;
        target_fold = '0;
        target_rot = '0;
        for (int bit_idx = 1; bit_idx < VADDR_W; bit_idx++) begin
            branch_fold[(bit_idx - 1) % HIST_EVENT_W] ^= branch_pc[bit_idx];
            target_fold[(bit_idx - 1) % HIST_EVENT_W] ^= target_pc[bit_idx];
        end
        for (int bit_idx = 0; bit_idx < HIST_EVENT_W; bit_idx++) begin
            target_rot[(bit_idx + 1) % HIST_EVENT_W] = target_fold[bit_idx];
        end
        return branch_fold ^ target_rot;
    endfunction

    // 返回值以低 width 位保存折叠结果；其余位为零。
    function automatic logic [HIST_FOLD_W-1:0] fold_event(input hist_event_t event_bits,
                                                           input int width);
        logic [HIST_FOLD_W-1:0] folded;
        folded = '0;
        for (int bit_idx = 0; bit_idx < HIST_EVENT_W; bit_idx++) begin
            folded[bit_idx % width] ^= event_bits[bit_idx];
        end
        return folded;
    endfunction

    function automatic logic [HIST_FOLD_W-1:0] rotate_fold(
        input logic [HIST_FOLD_W-1:0] value, input int width, input int shift);
        logic [HIST_FOLD_W-1:0] rotated;
        rotated = '0;
        for (int bit_idx = 0; bit_idx < width; bit_idx++) begin
            rotated[(bit_idx + shift) % width] = value[bit_idx];
        end
        return rotated;
    endfunction

    // 所有窗口从同一个旧快照读取出窗事件；先算 C，再移动唯一的 E 序列。
    function automatic hist_snapshot_t append_event(input hist_snapshot_t previous,
                                                     input hist_event_t incoming);
        hist_snapshot_t updated;
        logic [HIST_FOLD_W-1:0] old_fold;
        logic [HIST_FOLD_W-1:0] new_fold;
        int offset;
        int width;
        int history_len;
        updated = previous;
        offset = 0;
        for (int table_idx = 0; table_idx < o3_cfg_pkg::TAGE_TABLES; table_idx++) begin
            history_len = int'(CFG.tage.hist_len[table_idx]);
            for (int fold_kind = 0; fold_kind < 3; fold_kind++) begin
                case (fold_kind)
                    0: width = int'(CFG.tage.index_bits[table_idx]);
                    1: width = int'(CFG.tage.tag_bits[table_idx]);
                    default: width = int'(CFG.tage.tag_bits[table_idx]) - 1;
                endcase
                old_fold = '0;
                for (int bit_idx = 0; bit_idx < width; bit_idx++) begin
                    old_fold[bit_idx] = previous.folds[offset + bit_idx];
                end
                new_fold = rotate_fold(old_fold, width, CFG.tage.fold_shift)
                         ^ fold_event(incoming, width)
                         ^ rotate_fold(fold_event(previous.events[history_len-1], width),
                                       width, CFG.tage.fold_shift * history_len);
                for (int bit_idx = 0; bit_idx < width; bit_idx++) begin
                    updated.folds[offset + bit_idx] = new_fold[bit_idx];
                end
                offset += width;
            end
        end
        for (int age = HIST_WINDOW - 1; age > 0; age--) begin
            updated.events[age] = previous.events[age-1];
        end
        updated.events[0] = incoming;
        return updated;
    endfunction

    assign cur_o = history_q;
    assign restore_done_o = restore_valid_i && !rst_i;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            history_q <= '0;
        end else if (restore_valid_i) begin
            if (restore_inject_i) begin
                history_q <= append_event(
                    restore_snapshot_i,
                    encode_event(restore_branch_pc_i, restore_target_pc_i));
            end else begin
                history_q <= restore_snapshot_i;
            end
        end else if (push_valid_i) begin
            history_q <= append_event(history_q,
                                      encode_event(push_branch_pc_i, push_target_pc_i));
        end
    end

    initial begin
        assert (CFG.tage.event_bits == 8);
        assert (CFG.tage.event_window >= 1);
        for (int table_idx = 0; table_idx < o3_cfg_pkg::TAGE_TABLES; table_idx++) begin
            assert (CFG.tage.hist_len[table_idx] >= 1);
            assert (CFG.tage.hist_len[table_idx] <= CFG.tage.event_window);
            assert (CFG.tage.index_bits[table_idx] >= 1);
            assert (CFG.tage.tag_bits[table_idx] >= 2);
        end
    end
endmodule
