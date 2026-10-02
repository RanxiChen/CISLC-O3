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
 * 细节待定：
 * - 存储组织（寄存器/LUTRAM/BRAM）、读口数量与读出延迟、恢复带宽。
 * - 训练读口与恢复读口是否共用；冲突时的优先级（恢复优先为建议，未定）。
 *
 * 当前实现状态：空壳。只有端口与注释，没有任何逻辑，输出未驱动。
 *
 * 目标周期行为：
 * - 周期 N 上升沿：wr_valid_i 时写入 wr_ftq_id_i 对应项。
 * - 读：rd_*_req_i 后若干拍（延迟待定）给出 rd_*_resp_valid_o 与快照。
 *
 * 本阶段不写测试代码和仿真代码。
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
    output hist_snapshot_t rd_train_snapshot_o
);
    // 未实现：快照阵列与读写端口。
endmodule
