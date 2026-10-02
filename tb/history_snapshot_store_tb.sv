// history_snapshot_store 的最小周期合同：同拍写读旁路、双读口、代际过滤。
module history_snapshot_store_tb;
    import o3_cfg_pkg::*;
    import o3_types_pkg::*;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst, wr, read_recover, read_train, recover_valid, train_valid;
    ftq_id_t wr_id, recover_id, train_id;
    hist_snapshot_t wr_data, recover_data, train_data;

    history_snapshot_store #(.CFG(O3_CFG.fe)) dut (
        .clk_i(clk), .rst_i(rst),
        .wr_valid_i(wr), .wr_ftq_id_i(wr_id), .wr_snapshot_i(wr_data),
        .rd_recover_req_i(read_recover), .rd_recover_ftq_id_i(recover_id),
        .rd_recover_resp_valid_o(recover_valid), .rd_recover_snapshot_o(recover_data),
        .rd_train_req_i(read_train), .rd_train_ftq_id_i(train_id),
        .rd_train_resp_valid_o(train_valid), .rd_train_snapshot_o(train_data)
    );

    initial begin
        rst = 1;
        wr = 0;
        read_recover = 0;
        read_train = 0;
        wr_id = '0;
        recover_id = '0;
        train_id = '0;
        wr_data = '0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 0;
        wr_id = '{gen: 8'd7, idx: FTQ_IDX_W'(3)};
        recover_id = wr_id;
        train_id = wr_id;
        wr_data.events[0] = 8'h5a;
        wr_data.folds = '1;
        wr = 1;
        read_recover = 1;
        read_train = 1;
        // N 边沿同时写入、双读。N+1 两口必须各自看到新值。
        @(posedge clk);
        #1;
        if (!recover_valid || !train_valid || recover_data !== wr_data || train_data !== wr_data)
            $fatal(1, "same-cycle write/read bypass or dual read failed");

        @(negedge clk);
        wr = 0;
        read_recover = 0;
        read_train = 0;
        recover_id.gen = 8'd8;
        #1;
        if (recover_valid) $fatal(1, "retargeted recovery must reject old response");
        @(posedge clk);
        #1;
        if (train_valid) $fatal(1, "response valid must last one cycle");

        // 同一槽位的旧代际不能读到新动态 FTQ 区域的快照。
        @(negedge clk);
        wr = 1;
        wr_id.gen = 8'd8;
        wr_data.events[0] = 8'ha5;
        @(posedge clk);
        @(negedge clk);
        wr = 0;
        read_train = 1;
        train_id.gen = 8'd7;
        @(posedge clk);
        #1;
        if (train_valid) $fatal(1, "stale generation read must miss");
        @(negedge clk);
        train_id.gen = 8'd8;
        @(posedge clk);
        #1;
        if (!train_valid || train_data.events[0] !== 8'ha5)
            $fatal(1, "new generation read failed");
        $display("history_snapshot_store_tb PASS");
        $finish;
    end
endmodule
