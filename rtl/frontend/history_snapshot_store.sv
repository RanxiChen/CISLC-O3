/**
 * 历史快照存储 —— 每个 FTQ 区域的入口 E/C 完整快照
 *
 * 作用：
 * - 为每个成功分配的 FTQ 区域保存本区域更新之前的历史快照（D23）。
 * - 供恢复读取（装载出错区域入口历史）和提交训练读取（原查询上下文）。
 *
 * 目标机制：
 * - 已定（D23）：完整快照方案①；与动态 FTQ 身份绑定，生命周期不早于慢预测、恢复
 *   及训练上下文读取完成。可直接存在 FTQ，也可独立存储由 FTQ 引用；本框架按独立
 *   存储、以 ftq_id.idx 寻址组织，读出时用代际校验。
 * - 资源公式：每项 HIST_WINDOW*HIST_EVENT_W + HIST_FOLD_W bit，另计端口。
 * - 仅当完整快照资源不足时，再评估只存 E（方案②）或撤销记录 + C 快照（方案③），
 *   不作为并行实现模式。
 *
 * 本版存储组织：每个 FTQ 槽一份寄存器快照，恢复与训练各有独立同步读口，
 * 因而同拍两种读取不会互相丢请求。综合后的实际存储映射仍待测量。
 *
 * 当前实现状态：完整快照存储、代际校验、双读口和同拍写读旁路已实现。
 *
 * 目标周期行为：
 * - 周期 N 上升沿：wr_valid_i 时写入 wr_ftq_id_i 对应项。
 * - 周期 N 上升沿：两个读请求分别取快照；与同身份写入同拍时读新快照。
 * - 周期 N+1：相应响应有效一拍。请求端须保持 rd_*_ftq_id_i 为当前等待身份，
 *   旧身份的迟到响应会被输出端身份门控抑制。
 *
 * 对应的 SV 时序测试放在 tb/frontend；静态检查不等于功能验证。
 */
module history_snapshot_store
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic           clk_i,
    input  logic           rst_i,

    // 分配时写入
    input  logic           wr_valid_i,
    input  ftq_id_t        wr_ftq_id_i,
    input  hist_snapshot_t wr_snapshot_i,

    // 恢复读口
    input  logic           rd_recover_req_i,
    input  ftq_id_t        rd_recover_ftq_id_i,
    output logic           rd_recover_resp_valid_o,
    output hist_snapshot_t rd_recover_snapshot_o,

    // 训练读口
    input  logic           rd_train_req_i,
    input  ftq_id_t        rd_train_ftq_id_i,
    output logic           rd_train_resp_valid_o,
    output ftq_id_t rd_train_resp_id_o,
    output hist_snapshot_t rd_train_snapshot_o
);
    hist_snapshot_t snapshot_q [FTQ_DEPTH];
    ftq_id_t        owner_q    [FTQ_DEPTH];
    logic [FTQ_DEPTH-1:0] valid_q;

    hist_snapshot_t recover_data_q, train_data_q;
    ftq_id_t recover_id_q, train_id_q;
    logic recover_valid_q, train_valid_q;

    // 响应只交给仍在等待同一动态 FTQ 身份的请求者。恢复被更老请求替换时，
    // 旧响应即使已经进入输出寄存器，也不会作为新请求的快照生效。
    assign rd_recover_resp_valid_o = recover_valid_q &&
                                     (recover_id_q == rd_recover_ftq_id_i);
    assign rd_recover_snapshot_o = recover_data_q;
    assign rd_train_resp_valid_o = train_valid_q;
    assign rd_train_resp_id_o = train_id_q;
    assign rd_train_snapshot_o = train_data_q;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            valid_q <= '0;
            recover_valid_q <= 1'b0;
            train_valid_q <= 1'b0;
            recover_id_q <= '0;
            train_id_q <= '0;
            recover_data_q <= '0;
            train_data_q <= '0;
        end else begin
            recover_valid_q <= 1'b0;
            train_valid_q <= 1'b0;

            if (wr_valid_i && (int'(wr_ftq_id_i.idx) < FTQ_DEPTH)) begin
                snapshot_q[wr_ftq_id_i.idx] <= wr_snapshot_i;
                owner_q[wr_ftq_id_i.idx] <= wr_ftq_id_i;
                valid_q[wr_ftq_id_i.idx] <= 1'b1;
            end

            if (rd_recover_req_i && (int'(rd_recover_ftq_id_i.idx) < FTQ_DEPTH)) begin
                recover_id_q <= rd_recover_ftq_id_i;
                if (wr_valid_i && (wr_ftq_id_i == rd_recover_ftq_id_i)) begin
                    recover_data_q <= wr_snapshot_i;
                    recover_valid_q <= 1'b1;
                end else if (valid_q[rd_recover_ftq_id_i.idx] &&
                             (owner_q[rd_recover_ftq_id_i.idx] == rd_recover_ftq_id_i)) begin
                    recover_data_q <= snapshot_q[rd_recover_ftq_id_i.idx];
                    recover_valid_q <= 1'b1;
                end
            end

            if (rd_train_req_i && (int'(rd_train_ftq_id_i.idx) < FTQ_DEPTH)) begin
                train_id_q <= rd_train_ftq_id_i;
                if (wr_valid_i && (wr_ftq_id_i == rd_train_ftq_id_i)) begin
                    train_data_q <= wr_snapshot_i;
                    train_valid_q <= 1'b1;
                end else if (valid_q[rd_train_ftq_id_i.idx] &&
                             (owner_q[rd_train_ftq_id_i.idx] == rd_train_ftq_id_i)) begin
                    train_data_q <= snapshot_q[rd_train_ftq_id_i.idx];
                    train_valid_q <= 1'b1;
                end
            end
        end
    end
endmodule
