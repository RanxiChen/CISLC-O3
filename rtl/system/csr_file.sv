// L9 RTL implemented; lint/functional validation deferred (2026-10-07).
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
 *   软件写 fflags/frm/fcsr 在 CSR 串行更新点置 Dirty。FS=Off 时 FP 指令非法由 rename 入口按 L9 合同
 *   报告。dynamic rm 读取程序顺序正确的 frm（frm 写入串行化，B15/B22）。
 *
 * 细节待定：后续特权级 CSR 集合与 WARL 细节；time 来源；CSR 内部拍数（允许拆多拍，外部串行
 * 边界不变）。
 *
 * 当前实现状态：闭环简化（L7a）：M/Bare 单 hart；中断/S/U 待后级；L9 FP CSR/退休状态已接通。
 * - B48 M-mode HPM / mcycle / minstret 由 hpm_counters 统一持有；L7a 新增行为未验证。
 *
 * 逐周期说明（目标）：
 * - 周期 N：req_valid_i 时组合给出读值与合法性；trap_update_valid_i 时组合给出入口/返回 PC。
 * - 周期 N 上升沿：合法 CSR 写入 / trap 状态更新 / fp_retire 合并（三者按 commit_ctrl 合同不同拍）。
 * - 周期 N+1：派生状态（fe_csr、dmmu_csr、pmp、frm、irq_view）反映新值。
 *
 * 测试：sim/cocotb/csr_file/。
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

    input logic [$clog2(o3_cfg_pkg::O3_CFG.core.commit_width+1)-1:0] retire_count_i,
    input  fe_perf_t        fe_perf_i,
    input  be_perf_t        be_perf_i,
    output logic [63:0] write_value_o,
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
    logic [1:0] fs_q;
    logic [2:0] frm_q;
    logic [4:0] fflags_q;
    logic mie_bit_q, mpie_q;
    logic [63:0] mie_q, mtvec_q, mscratch_q, mepc_q, mcause_q, mtval_q;
    logic [63:0] old_value, modify_value, hpm_write_value;
    logic implemented, hpm_implemented;
    csr_resp_t hpm_resp;
    localparam logic [63:0] MISA = 64'h800000000000112c; // L9 T07b RV64IMFDC, Zicsr/Zifencei have no letter bit.

    hpm_counters #(.NUM_HPM(o3_cfg_pkg::O3_CFG.core.hpm_counters)) u_hpm_counters (
        .clk_i(clk), .rst_i(rst),
        .req_valid_i(req_valid_i && !trap_update_valid_i), .req_i(req_i),
        .implemented_o(hpm_implemented), .resp_o(hpm_resp), .write_value_o(hpm_write_value),
        .retire_count_i(retire_count_i), .fe_perf_i(fe_perf_i), .be_perf_i(be_perf_i)
    );
    always_comb begin
        implemented = 1'b1;
        old_value = '0;
        case (req_i.addr)
            12'h001: begin old_value=64'(fflags_q); implemented=fs_q!=0; end
            12'h002: begin old_value=64'(frm_q); implemented=fs_q!=0; end
            12'h003: begin old_value=64'({frm_q,fflags_q}); implemented=fs_q!=0; end
            12'h300: old_value = 64'h1800 | (64'(fs_q)<<13) | (64'(fs_q==3)<<63) | (64'(mpie_q)<<7) | (64'(mie_bit_q)<<3);
            12'h301: old_value = MISA;
            12'h304: old_value = mie_q;
            12'h305: old_value = mtvec_q;
            12'h340: old_value = mscratch_q;
            12'h341: old_value = mepc_q;
            12'h342: old_value = mcause_q;
            12'h343: old_value = mtval_q;
            12'h344: old_value = '0; // no software-pending writable bits in M-only L5
            12'hf11,12'hf12,12'hf13,12'hf14: old_value = '0;
            default: begin
                implemented = hpm_implemented;
                old_value = hpm_resp.rdata;
            end
        endcase
        modify_value = req_i.wdata;
        if (req_i.op == CSROP_RS) modify_value = old_value | req_i.wdata;
        if (req_i.op == CSROP_RC) modify_value = old_value & ~req_i.wdata;
        // WARL coercion matches the M-only subset of Breeze, not speculative state.
        write_value_o = modify_value;
        case (req_i.addr)
            12'h001: write_value_o=modify_value & 64'h1f;
            12'h002: write_value_o=modify_value & 64'h7;
            12'h003: write_value_o=modify_value & 64'hff;
            12'h300: write_value_o = 64'h1800 | (modify_value & 64'h6088) | (64'(modify_value[14:13]==3)<<63);
            12'h301: write_value_o = MISA; // read-only WARL, writes ignored (Breeze semantics)
            12'h304: write_value_o = modify_value & 64'h888;
            12'h344: write_value_o = '0;
            12'h305: write_value_o = (modify_value & ~64'd3) | (modify_value[1:0]==1 ? 64'd1 : 64'd0);
            12'h341: write_value_o = modify_value & ~64'd1;
            default: if (hpm_implemented) write_value_o = hpm_write_value;
        endcase
        resp_o = '0;
        resp_o.valid = req_valid_i;
        resp_o.rdata = old_value;
        resp_o.illegal = !implemented || (req_i.addr[9:8] > 2'b11)
                      || (req_i.write_en && req_i.addr[11:10]==2'b11);
        trap_target_pc_o = trap_update_i.is_xret ? vaddr_t'(mepc_q)
                         : vaddr_t'(mtvec_q & ~64'd3);
        trap_update_done_o = trap_update_valid_i;
        fe_csr_o = '{priv:2'b11, default:'0};
        dmmu_csr_o = '{priv_eff:2'b11, default:'0};
        pmp_o = '0; priv_o = 2'b11;
        irq_view_o = '{mip:64'd0,mie:mie_q};
        irq_take_o = 1'b0; irq_cause_o = '0; // L11
        frm_o = frm_q; fs_o = fs_q;
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            fs_q<=0; frm_q<=0; fflags_q<=0;
            mie_bit_q <= 0; mpie_q <= 0; mie_q <= 0;
            mtvec_q <= 64'h200; mscratch_q <= 0; mepc_q <= 0; mcause_q <= 0; mtval_q <= 0;
        end else begin
            if (trap_update_valid_i) begin
                assert (!req_valid_i && (trap_update_i.is_xret || retire_count_i==0));
                if (trap_update_i.is_xret) begin mie_bit_q <= mpie_q; mpie_q <= 1; end
                else begin
                    mepc_q <= 64'(trap_update_i.epc) & ~64'd1;
                    mcause_q <= 64'(trap_update_i.cause) | (64'(trap_update_i.is_interrupt)<<63);
                    mtval_q <= trap_update_i.tval;
                    mpie_q <= mie_bit_q; mie_bit_q <= 0;
                end
            end else if (req_valid_i && !resp_o.illegal && req_i.write_en) begin
                case (req_i.addr)
                    12'h001: begin fflags_q<=write_value_o[4:0]; fs_q<=3; end
                    12'h002: begin frm_q<=write_value_o[2:0]; fs_q<=3; end
                    12'h003: begin frm_q<=write_value_o[7:5]; fflags_q<=write_value_o[4:0]; fs_q<=3; end
                    12'h300: begin mie_bit_q <= write_value_o[3]; mpie_q <= write_value_o[7]; fs_q<=write_value_o[14:13]; end
                    12'h304: mie_q <= write_value_o;
                    12'h305: mtvec_q <= write_value_o;
                    12'h340: mscratch_q <= write_value_o;
                    12'h341: mepc_q <= write_value_o;
                    12'h342: mcause_q <= write_value_o;
                    12'h343: mtval_q <= write_value_o;
                    default: ;
                endcase
            end
            // N edge: merge only actual retirement; N+1 software observes flags/Dirty.
            if (fp_retire_i.valid && ((|fp_retire_i.fflags) || fp_retire_i.fs_dirty)) begin
                assert (!(req_valid_i || trap_update_valid_i));
                fflags_q<=fflags_q | fp_retire_i.fflags;
                if (fp_retire_i.fs_dirty) fs_q<=3;
            end
        end
    end
endmodule
