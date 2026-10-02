/**
 * FU 完成 FIFO —— 结果交付时间、写回仲裁等待与提前唤醒承诺（B33，2026-10-02 用户确认）
 *
 * 每个需要的 FU 完成端例化一份（乘法、FP 各 FU 等；ALU 现有 Result 槽另行迁移）。
 *
 * 负责：
 * - 吸收写回仲裁等待：FU 出口结果先进入本地 FIFO，头部参与目的域写回仲裁。
 * - 完成空间预留：不可停顿流水 FU 在接受请求的同一拍必须 rsv_req_i && rsv_ok_o，为该请求将来
 *   的结果预留一项；没有空间时 FU 不得接受请求（由 FU 的 req_ready_o 体现）。结果到达时一定
 *   有位置，流水线不需要停顿。被取消的请求在其结果到达（或在流水中被清除）时归还预留。
 * - 提前唤醒承诺：对结果交付时间已确定的流水 FU，提前一拍发出 wake_promise_t，让依赖指令被提前
 *   安排。承诺发出后，结果即使未赢得写口，也必须作为 FIFO 头的 bypass 源（bypass_o）对消费者
 *   持续可见，不能破坏已发出的唤醒承诺。
 * - FIFO 中尚不可交付的条目（非头部）不能提前唤醒消费者；只有成为头部、数据稳定的一拍起才
 *   可以作为 bypass 源。
 * - 可见性交接：头部赢得写口的同一拍写 PRF；消费者在“写入那拍”仍从 bypass_o 取值，下一拍起从
 *   PRF 读取。晚到消费者、PRF 写入与 bypass 退出之间不得出现数据可见性空洞（具体依赖 PRF
 *   read-during-write 行为，接入时核对）。
 * - 融合乘法（B34）：同一请求的高/低两个结果作为两项进入 FIFO，可分拍交付；按各自 fu_tag_t
 *   过滤取消与迟到结果。预留时需一次预留两项。
 * - 取消：按 resolution 的 br_mask 选择性清除年轻条目，保留老条目。
 *
 * 不负责：
 * - memory 不强求提前唤醒，访存结果不经本模块。
 * - 迭代除法不能从启动时假定固定延迟；只有在结束时间已确定（例如最后若干次迭代）时才可发出
 *   承诺，由 div_execute_unit 自身判断并通过 promise_i 送入。
 *
 * 细节待定：深度（CFG.exec.mul_result_slots / cpl_fifo_depth）、每 FU 是否需要多个出口、
 * 承诺提前量是否始终为一拍、与 PRF 读口时序的精确交接。
 *
 * 当前实现状态：空壳。只有端口与注释，没有逻辑，输出未驱动。
 *
 * 逐周期说明（目标）：
 * - 周期 N 组合：head_valid_o/head_o 为头部结果，参与写回仲裁；bypass_o 为头部 bypass 源；
 *   rsv_ok_o 反映是否还有可预留空间（考虑本拍归还）。
 * - 周期 N 上升沿：enq_valid_i 时结果写入其预留位置；head_consume_i（赢得写口或被取消）时
 *   头部出队；rsv_req_i && rsv_ok_o 时预留计数加一（融合加二）。
 * - 周期 N+1：新的头部可见；已写入 PRF 的结果不再出现在 bypass_o。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module fu_completion_fifo
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    parameter  int DEPTH                       // 由例化处从 CFG.exec.* 选取，不写默认值
) (
    input  logic                         clk,
    input  logic                         rst,

    // 完成空间预留（FU 接受请求的同拍）
    input  logic                         rsv_req_i,
    input  logic                         rsv_pair_i,   // 融合请求：一次预留两项
    output logic                         rsv_ok_o,

    // FU 出口结果写入
    input  logic                         enq_valid_i,
    input  o3_types_pkg::wb_req_t        enq_i,

    // 提前唤醒：FU 侧在交付时间确定时给出，本模块转发并负责承诺不失效
    input  o3_types_pkg::wake_promise_t  promise_i,
    output o3_types_pkg::wake_promise_t  promise_o,

    // 头部：写回仲裁候选与 bypass 源
    output logic                         head_valid_o,
    output o3_types_pkg::wb_req_t        head_o,
    input  logic                         head_consume_i,
    output o3_types_pkg::cpl_bypass_t    bypass_o,

    input  branch_resolution_t           resolution_i
);
    // 未实现：预留计数、环形存储、头部 bypass、选择性取消。
endmodule
