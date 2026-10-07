/**
 * CSR 文件 —— 架构 CSR 唯一状态所有者与派生状态
 *
 * 目标范围：RV64GC/Linux，M/S/U 三级；特权语义（pending/enable/delegation、trap entry/return、
 * 软件 STIP 与 Sstc）按冻结 L10 spec 修正 Breeze RegFile.scala 语义；
 * 平台中断和 mtime 由核端口输入，CLINT/PLIC 接入属于 L11。
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
 * M/S/U CSR、WLRL cause、PMP 锁定与 counteren 以冻结 L10 spec 为准。
 *
 * 当前实现状态：闭环简化（L10）：M/S/U、CSR、中断/Sstc/PMP 已实现；satp 接受 Bare/Sv39；SFENCE 和 satp/ADUE 写推进 epoch。
 * - B48 M-mode HPM / mcycle / minstret 由 hpm_counters 统一持有；L10 扩展特权过滤和溢出；门禁见 O3-T08-report.md。
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
    input logic sfence_epoch_i=1'b0,
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
    input logic [63:0] mtime_i,
    output logic [63:0] status_o,
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
    localparam logic [63:0] STATUS_MASK=64'h00000000007e79aa;
    localparam logic [63:0] SSTATUS_MASK=64'h80000003000c6122;
    localparam logic [63:0] DELEG_MASK=64'hb1ff;
    localparam logic [63:0] IRQ_MASK=64'h2aaa;
    localparam logic [63:0] MISA=64'h800000000014112c;
    logic [1:0] priv_q;
    logic [63:0] status_q,mie_q,mip_sw_q,medeleg_q,mideleg_q;
    logic [63:0] mtvec_q,stvec_q,mepc_q,sepc_q,mcause_q,scause_q,mtval_q,stval_q,mscratch_q,sscratch_q;
    logic [63:0] satp_q,menvcfg_q,stimecmp_q;
    logic [31:0] mcounteren_q,scounteren_q;
    logic [2:0] frm_q;
    logic [4:0] fflags_q;
    pmp_entry_t [PMP_N-1:0] pmp_q,pmp_next;
    xlate_epoch_t epoch_q;
    logic [63:0] old_value,modify_value,status_value,mip_value,rmw_value;
    logic implemented,access_illegal,hpm_implemented,overflow;
    logic [63:0] hpm_write;
    logic [31:0] scountovf;
    csr_resp_t hpm_resp;
    logic csr_write,pmp_change,satp_write,adue_change,delegated;
    logic [63:0] trap_vector;
    int counter_index,pmp_index;
    function automatic logic cause_legal(input logic [63:0] value);
        if(value[62:6]!=0) return 0;
        if(value[63]) return value[5:0] inside {6'd1,6'd3,6'd5,6'd7,6'd9,6'd11,6'd13};
        return value[5:0] inside {6'd0,6'd1,6'd2,6'd3,6'd4,6'd5,6'd6,6'd7,6'd8,6'd9,6'd11,6'd12,6'd13,6'd15};
    endfunction
    hpm_counters #(.NUM_HPM(o3_cfg_pkg::O3_CFG.core.hpm_counters)) u_hpm_counters(
        .clk_i(clk),.rst_i(rst),.req_valid_i(req_valid_i && !trap_update_valid_i && !access_illegal),.req_i(req_i),
        .implemented_o(hpm_implemented),.resp_o(hpm_resp),.write_value_o(hpm_write),
        .retire_count_i(retire_count_i),.fe_perf_i(fe_perf_i),.be_perf_i(be_perf_i),
        .priv_i(priv_q),.overflow_o(overflow),.scountovf_o(scountovf));
    always_comb begin
        status_value=status_q | 64'h0000000a00000000 | (64'(status_q[14:13]==3)<<63);
        mip_value=mip_sw_q;
        mip_value[3]=irq_m_soft_i; mip_value[7]=irq_m_timer_i; mip_value[11]=irq_m_ext_i;
        mip_value[9]=mip_sw_q[9] | irq_s_ext_i;
        if(menvcfg_q[63]) mip_value[5]=mtime_i>=stimecmp_q;
        implemented=1;old_value=0;
        case(req_i.addr)
            12'h001: old_value=64'(fflags_q);
            12'h002: old_value=64'(frm_q);
            12'h003: old_value=64'({frm_q,fflags_q});
            12'h100: old_value=status_value & SSTATUS_MASK;
            12'h104: old_value=mie_q & mideleg_q;
            12'h105: old_value=stvec_q;
            12'h106: old_value=64'(scounteren_q);
            12'h10a: old_value=0; // senvcfg: implemented zero; writes have no effect.
            12'h140: old_value=sscratch_q;
            12'h141: old_value=sepc_q;
            12'h142: old_value=scause_q;
            12'h143: old_value=stval_q;
            12'h144: old_value=mip_value & mideleg_q;
            12'h14d: old_value=stimecmp_q;
            12'h180: old_value=satp_q;
            12'h300: old_value=status_value;
            12'h301: old_value=MISA;
            12'h302: old_value=medeleg_q;
            12'h303: old_value=mideleg_q;
            12'h304: old_value=mie_q;
            12'h305: old_value=mtvec_q;
            12'h306: old_value=64'(mcounteren_q);
            12'h30a: old_value=menvcfg_q;
            12'h340: old_value=mscratch_q;
            12'h341: old_value=mepc_q;
            12'h342: old_value=mcause_q;
            12'h343: old_value=mtval_q;
            12'h344: old_value=mip_value;
            12'h3a0: for(int n=0;n<8;n++) old_value[n*8+:8]=pmp_q[n].cfg;
            12'h3a2: for(int n=0;n<8;n++) old_value[n*8+:8]=pmp_q[n+8].cfg;
            12'hc01: old_value=mtime_i;
            12'hda0: old_value=64'(priv_q==PRIV_S ? scountovf & mcounteren_q : scountovf);
            12'hf11,12'hf12,12'hf13,12'hf14: old_value=0;
            default: begin
                implemented=hpm_implemented;old_value=hpm_resp.rdata;
                for(int n=0;n<PMP_N;n++) if(req_i.addr==12'(12'h3b0+n)) begin
                    implemented=1; old_value=64'(pmp_addr_read(pmp_q[n]));
                end
            end
        endcase
        access_illegal=priv_q<req_i.addr[9:8] || (req_i.write_en && req_i.addr[11:10]==3);
        if(req_i.addr inside {12'h001,12'h002,12'h003} && status_q[14:13]==0) access_illegal=1;
        if(req_i.addr==12'h180 && priv_q==PRIV_S && status_q[20]) access_illegal=1;
        if(req_i.addr==12'h14d && priv_q==PRIV_S && (!menvcfg_q[63] || !mcounteren_q[1])) access_illegal=1;
        counter_index=int'(req_i.addr[4:0]);
        if(req_i.addr>=12'hc00 && req_i.addr<=12'hc1f) begin
            if(priv_q!=PRIV_M && !mcounteren_q[counter_index]) access_illegal=1;
            if(priv_q==PRIV_U && !scounteren_q[counter_index]) access_illegal=1;
        end
        rmw_value=old_value;
        if(req_i.addr==12'h344) rmw_value[9]=mip_sw_q[9]; // external SEIP is read-only, never latched by RMW.
        modify_value=req_i.wdata;
        if(req_i.op==CSROP_RS) modify_value=rmw_value | req_i.wdata;
        if(req_i.op==CSROP_RC) modify_value=rmw_value & ~req_i.wdata;
        write_value_o=modify_value;
        case(req_i.addr)
            12'h001: write_value_o=modify_value & 64'h1f;
            12'h002: write_value_o=modify_value & 64'h7;
            12'h003: write_value_o=modify_value & 64'hff;
            12'h100: write_value_o=(modify_value & SSTATUS_MASK & STATUS_MASK) | 64'h200000000;
            12'h300: begin
                write_value_o=(modify_value & STATUS_MASK) | 64'ha00000000;
                if(modify_value[12:11]==2) write_value_o[12:11]=0;
                write_value_o[63]=modify_value[14:13]==3;
            end
            12'h301: write_value_o=MISA;
            12'h302: write_value_o=modify_value & DELEG_MASK;
            12'h303: write_value_o=modify_value & 64'h2222;
            12'h304: write_value_o=modify_value & IRQ_MASK;
            12'h104: write_value_o=modify_value & mideleg_q;
            12'h344: write_value_o=modify_value & (menvcfg_q[63] ? 64'h2202 : 64'h2222);
            12'h144: write_value_o=modify_value & mideleg_q & 64'h2002;
            12'h105,12'h305: write_value_o=(modify_value & ~64'd3) | (modify_value[1:0]==1 ? 64'd1 : 64'd0);
            12'h141,12'h341: write_value_o=modify_value & ~64'd1;
            12'h142,12'h342: if(!cause_legal(modify_value)) write_value_o=old_value;
            12'h106,12'h306: write_value_o=modify_value & 64'hffffffff;
            12'h10a: write_value_o=0;
            12'h30a: write_value_o=modify_value & 64'ha000000000000000;
            12'h180: if(!(modify_value[63:60] inside {0,8})) write_value_o=satp_q; // Sv39 and Bare are the supported WARL modes.
            default: if(hpm_implemented) write_value_o=hpm_write;
        endcase
        csr_write=req_valid_i && implemented && !access_illegal && req_i.write_en && !trap_update_valid_i;
        pmp_next=pmp_q;
        if(csr_write) begin
            for(int n=0;n<PMP_N;n++) begin
                if((req_i.addr==12'h3a0 && n<8) || (req_i.addr==12'h3a2 && n>=8))
                    if(!pmp_q[n].cfg[7]) begin
                        pmp_next[n].cfg=modify_value[(n%8)*8+:8] & 8'h9f;
                        if(pmp_next[n].cfg[4:3]==2'b10) pmp_next[n].cfg[4:3]=pmp_q[n].cfg[4:3]; // G=2 excludes NA4.
                        if(!pmp_next[n].cfg[0]) pmp_next[n].cfg[1]=0;
                    end
                if(req_i.addr==12'(12'h3b0+n) && !pmp_q[n].cfg[7]) begin
                    if(n==PMP_N-1) pmp_next[n].addr=modify_value[53:0];
                    else if(!(pmp_q[n+1].cfg[7] && pmp_q[n+1].cfg[4:3]==1)) pmp_next[n].addr=modify_value[53:0];
                end
            end
        end
        pmp_change=pmp_next!=pmp_q;
        if(req_i.addr inside {12'h3a0,12'h3a2}) begin
            write_value_o=0;
            for(int n=0;n<8;n++) write_value_o[n*8+:8]=pmp_next[n+(req_i.addr==12'h3a2 ? 8 : 0)].cfg;
        end
        for(int n=0;n<PMP_N;n++) if(req_i.addr==12'(12'h3b0+n)) write_value_o=64'(pmp_addr_read(pmp_next[n]));
        satp_write=csr_write && req_i.addr==12'h180 && (modify_value[63:60] inside {0,8});
        adue_change=csr_write && req_i.addr==12'h30a && write_value_o[61]!=menvcfg_q[61];
        resp_o='0;resp_o.valid=req_valid_i;resp_o.rdata=old_value;
        resp_o.illegal=!implemented || access_illegal;
        resp_o.needs_refetch=pmp_change || satp_write || adue_change;
        resp_o.refetch_kind=pmp_change ? SYS_PMP : SYS_SATP;
        fe_csr_o='{priv:priv_q,adue:menvcfg_q[61],satp_mode:satp_q[63:60],satp_asid:satp_q[59:44],satp_ppn:satp_q[43:0],epoch:epoch_q};
        dmmu_csr_o='{priv_eff:(priv_q==PRIV_M && status_q[17] ? status_q[12:11] : priv_q),priv:priv_q,
            mprv:status_q[17],mpp:status_q[12:11],sum:status_q[18],mxr:status_q[19],adue:menvcfg_q[61],
            satp_mode:satp_q[63:60],satp_asid:satp_q[59:44],satp_ppn:satp_q[43:0],epoch:epoch_q};
        pmp_o='{update:pmp_change,entries:pmp_q};priv_o=priv_q;status_o=status_value;
        fs_o=status_q[14:13];frm_o=frm_q;
        irq_view_o='{mip:mip_value,mie:mie_q}; irq_take_o=0;irq_cause_o=0;
        // Reverse loop implements the frozen total priority, not Breeze's destination grouping.
        for(int priority_idx=6;priority_idx>=0;priority_idx--) begin
            case(priority_idx)
                0: counter_index=11; 1: counter_index=3; 2: counter_index=7;
                3: counter_index=9; 4: counter_index=1; 5: counter_index=5;
                default: counter_index=13;
            endcase
            if(mie_q[counter_index] && mip_value[counter_index] &&
                (mideleg_q[counter_index] ? (priv_q==PRIV_U || (priv_q==PRIV_S && status_q[1])) :
                    (priv_q!=PRIV_M || status_q[3]))) begin
                irq_take_o=1;irq_cause_o=exception_cause_t'(counter_index);
            end
        end
        delegated=priv_q!=PRIV_M && (trap_update_i.is_interrupt ? mideleg_q[trap_update_i.cause] : medeleg_q[trap_update_i.cause]);
        trap_vector=delegated ? stvec_q : mtvec_q;
        trap_target_pc_o=vaddr_t'(trap_vector & ~64'd3);
        if(trap_update_i.is_interrupt && trap_vector[1:0]==1) trap_target_pc_o+=64'(trap_update_i.cause)<<2;
        if(trap_update_i.is_xret) trap_target_pc_o=trap_update_i.is_mret ? mepc_q : sepc_q;
        trap_update_done_o=trap_update_valid_i;
    end
    // N reads old state; N edge executes one accepted side effect. N+1 all
    // permission/interrupt views expose it. Trap and xRET flush speculative work.
    always_ff @(posedge clk) begin
        if(rst) begin
            priv_q<=PRIV_M;status_q<=64'h1800;mie_q<=0;mip_sw_q<=0;medeleg_q<=0;mideleg_q<=0;
            mtvec_q<=64'h200;stvec_q<=0;mepc_q<=0;sepc_q<=0;mcause_q<=0;scause_q<=0;
            mtval_q<=0;stval_q<=0;mscratch_q<=0;sscratch_q<=0;
            satp_q<=0;menvcfg_q<=64'h2000000000000000;stimecmp_q<='1;
            mcounteren_q<=0;scounteren_q<=0;frm_q<=0;fflags_q<=0;pmp_q<=0;epoch_q<=0;
        end else begin
            if(sfence_epoch_i) epoch_q<=epoch_q+1'b1;
            pmp_q<=pmp_next;
            if(trap_update_valid_i) begin
                assert(!req_valid_i && (trap_update_i.is_xret || retire_count_i==0));
                if(trap_update_i.is_xret) begin
                    if(trap_update_i.is_mret) begin
                        status_q[3]<=status_q[7];status_q[7]<=1;priv_q<=status_q[12:11];status_q[12:11]<=PRIV_U;
                        if(status_q[12:11]!=PRIV_M) status_q[17]<=0;
                    end else begin
                        status_q[1]<=status_q[5];status_q[5]<=1;priv_q<=status_q[8] ? PRIV_S : PRIV_U;
                        status_q[8]<=0;status_q[17]<=0;
                    end
                end else if(delegated) begin
                    sepc_q<=trap_update_i.epc & ~64'd1;
                    scause_q<=64'(trap_update_i.cause) | (64'(trap_update_i.is_interrupt)<<63);
                    stval_q<=trap_update_i.is_interrupt ? 0 : trap_update_i.tval;
                    status_q[5]<=status_q[1];status_q[1]<=0;status_q[8]<=priv_q==PRIV_S;priv_q<=PRIV_S;
                end else begin
                    mepc_q<=trap_update_i.epc & ~64'd1;
                    mcause_q<=64'(trap_update_i.cause) | (64'(trap_update_i.is_interrupt)<<63);
                    mtval_q<=trap_update_i.is_interrupt ? 0 : trap_update_i.tval;
                    status_q[7]<=status_q[3];status_q[3]<=0;status_q[12:11]<=priv_q;priv_q<=PRIV_M;
                end
            end else if(csr_write) case(req_i.addr)
                12'h001: begin fflags_q<=write_value_o[4:0];status_q[14:13]<=3;end
                12'h002: begin frm_q<=write_value_o[2:0];status_q[14:13]<=3;end
                12'h003: begin frm_q<=write_value_o[7:5];fflags_q<=write_value_o[4:0];status_q[14:13]<=3;end
                12'h100: status_q<=(status_q & ~(SSTATUS_MASK & STATUS_MASK)) | (write_value_o & STATUS_MASK);
                12'h300: status_q<=write_value_o & STATUS_MASK;
                12'h302: medeleg_q<=write_value_o;
                12'h303: mideleg_q<=write_value_o;
                12'h304: mie_q<=write_value_o;
                12'h104: mie_q<=(mie_q & ~mideleg_q) | write_value_o;
                12'h105: stvec_q<=write_value_o;
                12'h305: mtvec_q<=write_value_o;
                12'h106: scounteren_q<=write_value_o[31:0];
                12'h306: mcounteren_q<=write_value_o[31:0];
                12'h30a: begin menvcfg_q<=write_value_o;if(adue_change) epoch_q<=epoch_q+1'b1;end
                12'h140: sscratch_q<=write_value_o;
                12'h340: mscratch_q<=write_value_o;
                12'h141: sepc_q<=write_value_o;
                12'h341: mepc_q<=write_value_o;
                12'h142: scause_q<=write_value_o;
                12'h342: mcause_q<=write_value_o;
                12'h143: stval_q<=write_value_o;
                12'h343: mtval_q<=write_value_o;
                12'h14d: stimecmp_q<=write_value_o;
                12'h344: begin
                    mip_sw_q[1]<=modify_value[1];mip_sw_q[9]<=modify_value[9];mip_sw_q[13]<=modify_value[13];
                    if(!menvcfg_q[63]) mip_sw_q[5]<=modify_value[5];
                end
                12'h144: begin
                    if(mideleg_q[1]) mip_sw_q[1]<=modify_value[1];
                    if(mideleg_q[13]) mip_sw_q[13]<=modify_value[13];
                end
                12'h180: if(satp_write) begin satp_q<=write_value_o;epoch_q<=epoch_q+1'b1;end
                default: ;
            endcase
            if(overflow) mip_sw_q[13]<=1; // real overflow dominates a concurrent software clear.
            if(fp_retire_i.valid && ((|fp_retire_i.fflags) || fp_retire_i.fs_dirty)) begin
                assert(!(req_valid_i || trap_update_valid_i));
                fflags_q<=fflags_q | fp_retire_i.fflags;
                if(fp_retire_i.fs_dirty) status_q[14:13]<=3;
            end
        end
    end
endmodule
