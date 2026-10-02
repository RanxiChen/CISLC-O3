// branch_history 的最小周期合同：驱动在下降沿，检查在上升沿之后。
// 运行者可用 Verilator --binary --timing --top-module branch_history_tb 构建。
module branch_history_tb;
    import o3_cfg_pkg::*;
    import o3_types_pkg::*;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst, push, restore, inject, done;
    vaddr_t push_pc, push_target, restore_pc, restore_target;
    hist_snapshot_t snapshot, current, saved;

    branch_history #(.CFG(O3_CFG.fe)) dut (
        .clk_i(clk), .rst_i(rst),
        .push_valid_i(push), .push_branch_pc_i(push_pc),
        .push_target_pc_i(push_target), .cur_o(current),
        .restore_valid_i(restore), .restore_snapshot_i(snapshot),
        .restore_inject_i(inject), .restore_branch_pc_i(restore_pc),
        .restore_target_pc_i(restore_target), .restore_done_o(done)
    );

    function automatic hist_event_t event_of(vaddr_t branch_pc, vaddr_t target_pc);
        hist_event_t a, b, rotated;
        a = '0;
        b = '0;
        rotated = '0;
        for (int bit_idx = 1; bit_idx < VADDR_W; bit_idx++) begin
            a[(bit_idx-1) % HIST_EVENT_W] ^= branch_pc[bit_idx];
            b[(bit_idx-1) % HIST_EVENT_W] ^= target_pc[bit_idx];
        end
        for (int bit_idx = 0; bit_idx < HIST_EVENT_W; bit_idx++)
            rotated[(bit_idx+1) % HIST_EVENT_W] = b[bit_idx];
        return a ^ rotated;
    endfunction

    function automatic logic [HIST_FOLD_W-1:0] first_event_folds(hist_event_t e);
        logic [HIST_FOLD_W-1:0] result;
        int offset, width;
        result = '0;
        offset = 0;
        for (int table_idx = 0; table_idx < TAGE_TABLES; table_idx++) begin
            for (int kind = 0; kind < 3; kind++) begin
                case (kind)
                    0: width = int'(O3_CFG.fe.tage.index_bits[table_idx]);
                    1: width = int'(O3_CFG.fe.tage.tag_bits[table_idx]);
                    default: width = int'(O3_CFG.fe.tage.tag_bits[table_idx]) - 1;
                endcase
                for (int bit_idx = 0; bit_idx < HIST_EVENT_W; bit_idx++)
                    result[offset + bit_idx % width] ^= e[bit_idx];
                offset += width;
            end
        end
        return result;
    endfunction

    initial begin
        rst = 1;
        push = 0;
        restore = 0;
        inject = 0;
        push_pc = '0;
        push_target = '0;
        restore_pc = '0;
        restore_target = '0;
        snapshot = '0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 0;
        if (current !== '0) $fatal(1, "reset did not clear history");

        // N: 一次 taken 条件分支进入历史；N+1: 事件和六组三折叠可见。
        push = 1;
        push_pc = 64'h1002;
        push_target = 64'h2006;
        @(posedge clk);
        #1;
        if (current.events[0] !== event_of(push_pc, push_target))
            $fatal(1, "event encoding/shift mismatch");
        if (current.folds !== first_event_folds(event_of(push_pc, push_target)))
            $fatal(1, "first-event folded histories mismatch");
        saved = current;
        @(negedge clk);
        push = 0;
        @(posedge clk);
        #1;
        if (current !== saved) $fatal(1, "no event must preserve history");

        // 恢复优先于同时到达的普通 push；同一边沿在入口快照后注入修正事件。
        @(negedge clk);
        push = 1;
        push_pc = 64'hdead;
        push_target = 64'hbeef;
        restore = 1;
        snapshot = saved;
        inject = 1;
        restore_pc = 64'h3002;
        restore_target = 64'h4006;
        #1;
        if (!done) $fatal(1, "restore must acknowledge the accepting edge");
        @(posedge clk);
        #1;
        if (current.events[0] !== event_of(restore_pc, restore_target) ||
            current.events[1] !== saved.events[0])
            $fatal(1, "restore/inject priority or ordering mismatch");
        @(negedge clk);
        push = 0;
        restore = 0;
        inject = 0;
        #1;
        if (done) $fatal(1, "restore acknowledge must not persist");
        $display("branch_history_tb PASS");
        $finish;
    end
endmodule
