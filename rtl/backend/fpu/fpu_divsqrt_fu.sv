/**
 * FP-DIVSQRT FU（1 个）
 *
 * 操作：FDIV、FSQRT，S/D。保留 THMULTI 配置（2 个寄存边界不代表迭代只需两拍），格式 MERGED。
 * - 长延迟单元：忙时不能接受新请求；取消在途请求的方式待定。
 * 共同合同（已定，B14）：
 * - 复用 Breeze 为 100MHz 调整过的 CVFPU（Flow 子模块 HEAD 1b220f3，含 cdb4c70 FMA 加法前切分、
 *   1b220f3 转换舍入前切分）的内部流水，例化对应 `fpnew_opgroup_block`，替换 `fpnew_top` 的统一
 *   输入分流/输出仲裁；不能继续用 busy 把整个 FP 子系统锁成一次一条。
 * - 独立 in/out valid/ready、在途身份与结果保持，分别竞争目的寄存器域的写口。
 * - 原包装 TagType=logic 且 tag 固定 0；本包装必须携带唯一请求身份：建议请求槽号+代际关联侧表
 *   （ROB、目的域/preg、当前分支依赖），正确解析时更新侧表，误预测时标记年轻请求 killed。
 *   不能用原生 flush_i 做按年龄取消（会清掉同 FU 中仍有效的更老操作）。首版可让 killed 运算
 *   完成并在出口丢弃，槽位保留到返回终结；结果身份不能提前复用。
 * - 从顶层迁入的语义：输入 NaN-box 检查、输出扩展/boxing、分类与整数结果处理；
 *   单精度写 FPR 保持 NaN-boxing。
 * - fflags 随结果返回，存 ROB，退休时按序并入架构 fflags；rm 已在发射时解析为程序顺序正确的
 *   frm（B15）。
 *
 * 待定：FP IQ 组织、读口/写口与跨域仲裁、侧表深度（CFG.exec.fpu_inflight_slots）、
 * 是否加入内部选择性 kill。历史 Breeze 证据不代表拆分后达到 100MHz。
 *
 * 当前实现状态：空壳。只有端口与注释，没有逻辑，输出未驱动；CVFPU 源码尚未引入本仓库。
 *
 * 目标周期行为：req 握手进入 opgroup 流水并在侧表登记身份；结果出流水后进入保持槽，
 * resp_valid_o 直到 resp_ready_i（目的域写口 grant）；killed 结果在出口丢弃并释放侧表槽。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module fpu_divsqrt_fu
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    localparam int INFLIGHT = CFG.exec.fpu_inflight_slots
) (
    input  logic                       clk,
    input  logic                       rst,

    input  logic                       req_valid_i,
    output logic                       req_ready_o,
    input  o3_types_pkg::fpu_req_t     req_i,

    output logic                       resp_valid_o,
    input  logic                       resp_ready_i,
    output o3_types_pkg::fpu_resp_t    resp_o,

    input  branch_resolution_t         resolution_i,

    output logic                       busy_o
);
    // 未实现：opgroup 例化、身份侧表、结果保持、killed 丢弃。
endmodule
