/**
 * 提交控制 —— ROB 队头之后的按序副作用、系统同步编排、trap/xRET 发起
 *
 * 主流程均已定（B22～B27、B49、B37～B40），L5 M 模式通路已实现，后续级保留目标接口。
 *
 * 按序副作用（每拍对实际退休前缀）：
 * - ftq_commit_t（region_last：区域有效指令全部提交，FTQ 交接训练后回收，前端 16.2）。
 * - SQ committed 标记（B05）；committed RAT 更新与 old preg 按目的域归还（B15）。
 * - committed_next_pc（B37）：维护“已退休前缀之后的下一架构 PC”。普通指令 = 原始 PC + 真实长度，
 *   控制流 = 真实后继 PC（rob_commit_t.succ_pc）；同拍多条取最后一条实际退休指令的 succ_pc；
 *   正式 trap/xRET 生效后更新为入口/返回目标；普通分支恢复不修改；复位初始化到启动入口。
 *   用于中断精确 EPC（尤其 ROB 为空时）；同步异常仍用故障指令 PC；不允许用推测取指 PC 代替。
 * - FP 架构状态（B40）：fflags 按实际退休项 OR 合并，一次交给 csr_file；退休写架构 FPR 或退休项
 *   带非零 fflags 时置 FS Dirty（不比较新旧数据）；错误路径与 trap 拍不更新。与 CSR 串行更新、
 *   trap 的互斥：trap 拍无正常退休（B26），CSR 串行执行期间 ROB 无其他退休项，因此同拍不会同时
 *   有 fp_retire_evt 与 CSR 写或 trap 更新；不给普通 FP 执行增加状态阶段。
 *
 * 队头串行操作编排（Decode→Rename 串行阻塞见 B22，年轻指令在其退休前不进入 Rename）：
 * - CSR（B22）：队头且更老已退休后经 csr_file 执行；写回容量在架构写入前保证；架构写入后不可取消，
 *   必须退休。改变取指/翻译状态的写入经 sys_redirect + 前端同步重取。
 * - FENCE（B23）：pred.W 且需排序时等 SQ 正常 drain 至空（DCache 写完成确认）；否则队头即完成。
 * - FENCE.I（B23/D25，本模块统一编排，2026-10-02 确认）：
 *     1) 等 SQ 中老 store 全部写入 DCache 并确认；
 *     2) dcache_clean_all：遍历 L1D tag/meta，脏行写回 L2 并逐出（干净行保留），等全部确认；
 *     3) 发 fe_sync（SYS_FENCE_I）：前端停取指/预取、隔离旧请求、ICache 全失效、清 F0/返回队列/
 *        指令 buffer；
 *     4) fe_sync_done 后该 ROB 项完成并退休，sys_redirect 从下一条重取。
 *   前端 frontend_sync_ctrl 不再自行发起 DCache clean。
 * - SFENCE.VMA（B24/D26）：先全量 SQ drain；再 sfence 送 DTLB/PTW/walk cache 并 fe_sync 送 ITLB/
 *   预取翻译记录；隔离旧 PTW；两侧完成后退休。不做 L1D 脏行扫描。首版同时清 LR/SC reservation。
 * - satp/PMP 写（D27/D28）：随 CSR 执行完成后经 fe_sync 与 sys_redirect 同步；satp 切换清 reservation。
 * - WFI（B38）：合法 WFI 正常退休后交给 wfi_ctrl 进入等待；committed_next_pc 指向后继。
 * - MRET/SRET（B27）：合法队首指令自身正常退休直接触发返回（可与退休同拍），清 reservation。
 *
 * 异常与中断（B26）：
 * - 同步异常：退休停在故障指令之前；下一拍故障指令为最老项时在无正常退休的 trap 拍接受；
 *   故障项不退休。跨 line 拆分按 B49 留 L8；既有异常身份不在 L10 改动。
 * - 中断：只在指令边界；串行 CSR 已更新架构状态时先退休再复核；不可撤销 AMO/MMIO 先到安全边界。
 *   EPC = committed_next_pc。
 * - trap 入口与合法 xRET 均清 LR/SC reservation（B35）。
 *
 * fatal（B39）：isolate_i 有效后停止后续正常退休与新串行操作，保留在途总线收尾。
 *
 * 观测（B22/B23；跨 line 旧计数保留）：csr_retired、csr_wait_empty_cycles、csr_block_younger_cycles、
 * fencei_retired、fencei_dcache_evict_cycles、misaligned_crossline_traps，经 perf_o 输出增量。
 *
 * 细节待定：各同步握手的信号编码与拍数；free list 提交态恢复记录的结构；串行项是否与 CSR 共用。
 *
 * 当前实现状态：闭环简化（L10）：M/S/U xRET/ECALL、中断边界、WFI、PMP CSR 同步。
 * SFENCE 先 SQ 写完成再 PTW idle，精确范围失效后前端同步退休；needs_D store 在队头触发 D 重遍历，期间禁止退休；L1D clean 与 fatal 待 L8/L11；FP 退休 flags/Dirty 已接通。
 * ROB 退休经本模块转成 SQ committed / FTQ commit；free list 释放仍在 backend。
 *
 * 逐周期说明（目标）：
 * - 周期 N 组合：选定实际退休前缀（或 trap，二者不同拍；合法 xRET 可与自身退休同拍）；
 *   形成 sq_commit、ftq_commit、fp_retire_evt、committed_next_pc_nxt、trap_req。
 * - 周期 N 上升沿：committed_next_pc 更新；串行编排状态推进；trap 接受时锁存请求。
 * - 周期 N+1：trap 接受后前端按入口 PC 取指（B26 目标）；committed_next_pc 为新边界。
 *
 * 测试：sim/cocotb/commit_ctrl/。
 */
module commit_ctrl
    import o3_types_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    localparam int COMMIT_WIDTH = o3_cfg_pkg::O3_CFG.core.commit_width
) (
    input  logic            clk,
    input  logic            rst,
    input  vaddr_t          boot_pc_i,           // committed_next_pc 复位值

    input  rob_commit_t     commit_i [COMMIT_WIDTH-1:0],
    input  logic            head_valid_i,
    input  rob_commit_t     head_i,
    output logic            head_serial_done_o,
    output logic            commit_block_o,      // 本拍禁止正常退休（trap 拍 / fatal / 串行等待）

    // 按序副作用
    output ftq_commit_t     ftq_commit_o [COMMIT_WIDTH],
    output logic            sq_commit_valid_o [COMMIT_WIDTH],
    output sq_idx_t         sq_commit_idx_o   [COMMIT_WIDTH],
    output fp_retire_evt_t  fp_retire_o,         // B40：fflags OR 合并 + FS Dirty
    output vaddr_t          committed_next_pc_o, // B37

    // 系统重定向与前端同步（本模块编排）
    output sys_redirect_t   sys_redirect_o,
    output logic            fe_sync_valid_o,
    input  logic            fe_sync_ready_i,
    output fe_sync_req_t    fe_sync_o,
    input  logic            fe_sync_done_i,

    // 数据侧同步
    input  logic            sq_committed_empty_i,
    output logic            dcache_clean_all_o,  // FENCE.I：L1D 脏行扫描写回逐出
    input  logic            dcache_clean_all_done_i,
    input  logic            dcache_clean_all_busy_i, // fencei_dcache_evict_cycles 口径
    output sfence_req_t     sfence_o,
    input  logic            sfence_done_i,       // DTLB + PTW/walk cache

    // 队首 store 的 D 位非推测更新（B36）
    output logic            st_d_req_valid_o,
    input  logic            st_d_req_ready_i,
    input  logic            st_d_done_i,

    // CSR 与 trap
    output logic            csr_req_valid_o,
    output csr_req_t        csr_req_o,
    input  csr_resp_t       csr_resp_i,
    input logic ptw_idle_i=1'b1,
    input logic [63:0] sfence_asid_operand_i=64'b0,
    input logic [63:0] csr_operand_i,
    input logic block_younger_cycle_i,
    input logic [1:0] priv_i,
    input logic [63:0] status_i,
    input exception_cause_t irq_cause_i,
    input  logic            irq_take_i,          // csr_file 按正式中断条件给出（含委托/全局使能）
    output trap_req_t       trap_req_o,
    input  logic            trap_redirect_valid_i,
    input  vaddr_t          trap_redirect_pc_i,

    // LR/SC reservation 清除（trap 入口 / 合法 xRET / SFENCE.VMA / satp 切换）
    output logic            rsv_clear_valid_o,
    output rsv_clear_e      rsv_clear_reason_o,

    // WFI 与 fatal
    output logic            wfi_retire_o,
    input  logic            wfi_stall_i,
    input  logic            isolate_i,

    output logic            flush_all_o,         // 提交端整体清空（异常/xRET/同步重启）
    output be_perf_t        perf_o
);
    logic d_sent_q;
    logic serial_done_q,csr_executed_q,sync_sent_q,refetch_q,sf_sent_q,sf_done_q;
    sys_redirect_kind_e refetch_kind_q,trap_kind_q;
    vaddr_t committed_next_pc_q;
    logic serial_retire,system_illegal,sync_trap,irq_accept;
    logic [63:0] csr_retired,csr_wait_empty_cycles,csr_block_younger_cycles;
    always_comb begin
        system_illegal=0;
        case(head_i.sys_op)
            SYSOP_MRET: system_illegal=priv_i!=PRIV_M;
            SYSOP_SRET: system_illegal=priv_i==PRIV_U || (priv_i==PRIV_S && status_i[22]);
            SYSOP_WFI: system_illegal=priv_i==PRIV_U || (priv_i==PRIV_S && status_i[21]);
            SYSOP_SFENCE_VMA: system_illegal=priv_i==PRIV_U || (priv_i==PRIV_S && status_i[20]);
            default: ;
        endcase
        sync_trap=head_valid_i && head_i.complete &&
            (head_i.exc.valid || system_illegal || head_i.sys_op==SYSOP_ECALL);
        // No retirement participates in this decision, so there is no ROB
        // retire -> block -> retire loop. A begun CSR/sync must first retire.
        irq_accept=irq_take_i && !sync_trap && !csr_executed_q && !serial_done_q && !sync_sent_q
            && !sf_sent_q && !d_sent_q && !(head_valid_i && head_i.needs_d) && !trap_redirect_valid_i && !isolate_i && !wfi_stall_i;
        csr_req_o='0;csr_req_o.op=head_i.ext.csr_op;csr_req_o.addr=head_i.ext.csr_addr;
        csr_req_o.wdata=head_i.ext.csr_use_imm ? 64'(head_i.rs1) : csr_operand_i;
        csr_req_o.write_en=head_i.ext.csr_op==CSROP_RW || head_i.rs1!=0;csr_req_o.rob_idx=head_i.rob_idx;
        csr_req_valid_o=head_valid_i && head_i.ext.csr_op!=CSROP_NONE && !head_i.exc.valid
            && !csr_executed_q && !serial_done_q && !isolate_i && !irq_accept && !trap_redirect_valid_i;
        head_serial_done_o=serial_done_q;
        if(head_i.ext.csr_op==CSROP_NONE) case(head_i.sys_op)
            SYSOP_FENCE: head_serial_done_o=!head_i.ext.fence_pred[0] || sq_committed_empty_i;
            SYSOP_FENCE_I: head_serial_done_o=serial_done_q;
            SYSOP_SFENCE_VMA: head_serial_done_o=serial_done_q;
            default: head_serial_done_o=!system_illegal && head_i.sys_op!=SYSOP_ECALL;
        endcase
        fe_sync_valid_o=head_valid_i && !sync_sent_q && !serial_done_q && !irq_accept && !isolate_i &&
            ((head_i.sys_op==SYSOP_FENCE_I && sq_committed_empty_i) || (head_i.sys_op==SYSOP_SFENCE_VMA && sf_done_q) || refetch_q);
        fe_sync_o='{kind:(refetch_q ? refetch_kind_q : head_i.sys_op==SYSOP_SFENCE_VMA ? SYS_SFENCE : SYS_FENCE_I),default:'0};
        fe_sync_o.sfence='{valid:1'b1,rs1_is_x0:head_i.ext.sfence_rs1_x0,rs2_is_x0:head_i.ext.sfence_rs2_x0,
            vaddr:csr_operand_i,asid:asid_t'(sfence_asid_operand_i)};
        trap_req_o='0;
        if(sync_trap && !isolate_i && !trap_redirect_valid_i) begin
            trap_req_o.valid=1;trap_req_o.epc=head_i.pc;
            trap_req_o.cause=head_i.exc.cause;trap_req_o.tval=head_i.exc.tval;
            if(!head_i.exc.valid && head_i.sys_op==SYSOP_ECALL) begin
                trap_req_o.cause=priv_i==PRIV_U ? EXCEPTION_CAUSE_ECALL_U :
                    priv_i==PRIV_S ? EXCEPTION_CAUSE_ECALL_S : EXCEPTION_CAUSE_ECALL_M;
                trap_req_o.tval=0;
            end
            if(!head_i.exc.valid && system_illegal) begin
                trap_req_o.cause=EXCEPTION_CAUSE_ILLEGAL_INSTRUCTION;trap_req_o.tval=64'(head_i.instruction);
            end
        end else if(irq_accept) begin
            trap_req_o.valid=1;trap_req_o.is_interrupt=1;trap_req_o.cause=irq_cause_i;
            trap_req_o.epc=committed_next_pc_q;
        end
        serial_retire=0;sys_redirect_o='0;fp_retire_o='0;wfi_retire_o=0;
        if(trap_redirect_valid_i) sys_redirect_o='{valid:1'b1,kind:trap_kind_q,target_pc:trap_redirect_pc_i,default:'0};
        for(int lane=0;lane<COMMIT_WIDTH;lane++) begin
            ftq_commit_o[lane]='0;ftq_commit_o[lane].valid=commit_i[lane].valid;
            ftq_commit_o[lane].ftq_id=commit_i[lane].ftq_id;ftq_commit_o[lane].slot=commit_i[lane].slot;
            ftq_commit_o[lane].region_last=commit_i[lane].region_last;
            sq_commit_valid_o[lane]=commit_i[lane].valid && commit_i[lane].is_store;
            sq_commit_idx_o[lane]=commit_i[lane].sq_idx;
            if(commit_i[lane].valid) begin
                fp_retire_o.valid=1;fp_retire_o.fflags|=commit_i[lane].fflags;
                fp_retire_o.fs_dirty|=(commit_i[lane].rd_dom==RD_FP && commit_i[lane].rd_write_en) || (|commit_i[lane].fflags);
            end
            if(commit_i[lane].valid && commit_i[lane].ext.serialize) begin
                serial_retire=1;
                if(commit_i[lane].sys_op inside {SYSOP_MRET,SYSOP_SRET}) begin
                    trap_req_o.valid=1;trap_req_o.is_xret=1;trap_req_o.is_mret=commit_i[lane].sys_op==SYSOP_MRET;
                    trap_req_o.epc=commit_i[lane].pc;
                end
                if(commit_i[lane].sys_op==SYSOP_WFI) wfi_retire_o=1;
                if(commit_i[lane].sys_op inside {SYSOP_FENCE_I,SYSOP_SFENCE_VMA} || refetch_q)
                    sys_redirect_o='{valid:1'b1,kind:(refetch_q ? refetch_kind_q : commit_i[lane].sys_op==SYSOP_SFENCE_VMA ? SYS_SFENCE : SYS_FENCE_I),
                        ftq_id:commit_i[lane].ftq_id,slot:commit_i[lane].slot,target_pc:commit_i[lane].succ_pc};
            end
        end
        commit_block_o=(head_valid_i && head_i.needs_d) || isolate_i || sync_trap || irq_accept || trap_redirect_valid_i || wfi_stall_i;
        flush_all_o=trap_req_o.valid || (sys_redirect_o.valid && sys_redirect_o.kind inside {SYS_FENCE_I,SYS_SATP,SYS_PMP,SYS_SFENCE});
        committed_next_pc_o=committed_next_pc_q;
        sfence_o=fe_sync_o.sfence;
        sfence_o.valid=head_valid_i && head_i.sys_op==SYSOP_SFENCE_VMA && !system_illegal &&
            sq_committed_empty_i && ptw_idle_i && !sf_sent_q && !irq_accept && !trap_redirect_valid_i;
        dcache_clean_all_o=head_valid_i && head_i.sys_op==SYSOP_FENCE_I && sq_committed_empty_i && !sync_sent_q && !serial_done_q; // L8a: next-cycle acknowledgment; no tag scan.
        st_d_req_valid_o=head_valid_i && head_i.is_store && head_i.complete && head_i.needs_d &&
            !head_i.exc.valid && !d_sent_q && !isolate_i && !trap_redirect_valid_i;
        rsv_clear_valid_o=sfence_o.valid || trap_req_o.valid || (sys_redirect_o.valid && sys_redirect_o.kind==SYS_SATP);
        rsv_clear_reason_o=sfence_o.valid ? RSV_CLR_SFENCE_SATP : trap_req_o.is_xret ? RSV_CLR_XRET : RSV_CLR_TRAP;
        perf_o='0;perf_o[BE_SFENCE]=BE_PERF_INC_W'(sfence_o.valid);
    end
    // N: accept one head CSR, or an interrupt with no normal retire. Edge N:
    // mark CSR irreversible / latch redirect kind. N+1: sync or retirement.
    always_ff @(posedge clk) begin
        if(rst) begin
            d_sent_q<=0;serial_done_q<=0;csr_executed_q<=0;sync_sent_q<=0;refetch_q<=0;sf_sent_q<=0;sf_done_q<=0;
            refetch_kind_q<=SYS_PMP;trap_kind_q<=SYS_EXCEPTION;committed_next_pc_q<=boot_pc_i;
            csr_retired<=0;csr_wait_empty_cycles<=0;csr_block_younger_cycles<=0;
        end else begin
            if(st_d_req_valid_o && st_d_req_ready_i) d_sent_q<=1;
            if(!head_valid_i || !head_i.needs_d) d_sent_q<=0;
            if(csr_req_valid_o && csr_resp_i.valid && !csr_resp_i.illegal) begin
                csr_executed_q<=1;refetch_q<=csr_resp_i.needs_refetch;refetch_kind_q<=csr_resp_i.refetch_kind;
                serial_done_q<=!csr_resp_i.needs_refetch;
            end
            if(sfence_o.valid) sf_sent_q<=1;
            if(sf_sent_q && sfence_done_i) sf_done_q<=1;
            if(fe_sync_valid_o && fe_sync_ready_i) sync_sent_q<=1;
            if(sync_sent_q && fe_sync_done_i) serial_done_q<=1;
            if(serial_retire || flush_all_o) begin
                d_sent_q<=0;serial_done_q<=0;csr_executed_q<=0;sync_sent_q<=0;refetch_q<=0;sf_sent_q<=0;sf_done_q<=0;
            end
            for(int lane=0;lane<COMMIT_WIDTH;lane++) if(commit_i[lane].valid) begin
                committed_next_pc_q<=commit_i[lane].succ_pc;
                if(commit_i[lane].ext.csr_op!=CSROP_NONE) csr_retired<=csr_retired+1;
            end
            if(sys_redirect_o.valid) committed_next_pc_q<=sys_redirect_o.target_pc;
            if(trap_req_o.valid) trap_kind_q<=trap_req_o.is_xret ? SYS_XRET : trap_req_o.is_interrupt ? SYS_INTERRUPT : SYS_EXCEPTION;
            if(block_younger_cycle_i) csr_block_younger_cycles<=csr_block_younger_cycles+1;
            if(block_younger_cycle_i && !(head_valid_i && head_i.ext.serialize)) csr_wait_empty_cycles<=csr_wait_empty_cycles+1;
            if(trap_req_o.valid && !trap_req_o.is_xret) begin
                for(int lane=0;lane<COMMIT_WIDTH;lane++) assert(!commit_i[lane].valid);
                if(!trap_req_o.is_interrupt) assert(head_i.pc==committed_next_pc_q);
            end
        end
    end
endmodule
