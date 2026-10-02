/**
 * CSR 文件 —— 架构 CSR 唯一状态所有者与派生状态
 *
 * 目标范围：RV64GC/Linux，M/S/U 三级；特权语义（pending/enable/delegation、trap entry/return、
 * 软件 STIP、传统 CLINT/PLIC + OpenSBI 定时器路线）按 B29 复用 Breeze RegFile.scala 经验，迁移
 * 语义而不照抄包装；首版不依赖 Sstc。
 *
 * 已定合同：
 * - B22：CSR 指令经 commit_ctrl 在 ROB 队头串行执行；按操作码处理读/写抑制（CSRRW/RWI rd=x0 不读；
 *   CSRRS/RC rs1=x0、立即数 zimm=0 不写但仍读）；非法访问只报 illegal，不更新 CSR。
 * - B26/B27：trap 入口与 xRET 由专用硬件更新（不经普通 Zicsr 读改写通路），与 committed 状态恢复
 *   并行；给出入口/返回 PC。trap_ctrl 不另存架构 CSR 副本。
 * - D27/D28：satp 有效写入推进 epoch；PMP 有效修改输出 update 脉冲。
 * - B38：输出单项 mip/mie 视图（irq_view_o）给 wfi_ctrl 作为唤醒条件；正式中断条件（全局使能、
 *   特权级、委托）单独形成 irq_take_o。两者不能共用。
 * - B40：fp_retire_i 每拍一次：fflags OR 进架构 fflags；fs_dirty 置 mstatus.FS=Dirty（及 SD）。
 *   软件写 fflags/frm/fcsr 在 CSR 串行更新点置 Dirty。FS=Off 时 FP 指令非法由译码/执行按既有规则
 *   报告。dynamic rm 读取程序顺序正确的 frm（frm 写入串行化，B15/B22）。
 *
 * 细节待定：实现的 CSR 集合与 WARL 细节；计数器与 time 来源；CSR 内部拍数（允许拆多拍，外部串行
 * 边界不变）。
 *
 * 当前实现状态：空壳。只有端口与注释，没有逻辑，输出未驱动。
 *
 * 逐周期说明（目标）：
 * - 周期 N：req_valid_i 时组合给出读值与合法性；trap_update_valid_i 时组合给出入口/返回 PC。
 * - 周期 N 上升沿：合法 CSR 写入 / trap 状态更新 / fp_retire 合并（三者按 commit_ctrl 合同不同拍）。
 * - 周期 N+1：派生状态（fe_csr、dmmu_csr、pmp、frm、irq_view）反映新值。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module csr_file
    import o3_types_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG
) (
    input  logic            clk,
    input  logic            rst,

    input  logic            req_valid_i,
    input  csr_req_t        req_i,
    output csr_resp_t       resp_o,

    input  fp_retire_evt_t  fp_retire_i,         // B40
    output logic [o3_isa_pkg::FRM_W-1:0]    frm_o,
    output logic [1:0]      fs_o,

    // trap 入口 / xRET 专用更新（B26/B27）
    input  logic            trap_update_valid_i,
    input  trap_req_t       trap_update_i,
    output vaddr_t          trap_target_pc_o,    // 入口（xtvec）或返回（xepc）
    output logic            trap_update_done_o,

    // 中断：平台输入、WFI 唤醒视图与正式中断条件（B29/B38）
    input  logic            irq_m_ext_i,
    input  logic            irq_m_timer_i,
    input  logic            irq_m_soft_i,
    input  logic            irq_s_ext_i,
    output irq_view_t       irq_view_o,
    output logic            irq_take_o,
    output exception_cause_t irq_cause_o,

    // 派生状态
    output fe_csr_t         fe_csr_o,
    output pmp_state_t      pmp_o,
    output dmmu_csr_t       dmmu_csr_o,
    output logic [1:0]      priv_o
);
    // 未实现。
endmodule
