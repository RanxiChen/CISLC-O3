// L9 RTL implemented; lint/functional validation deferred (2026-10-07).
/**
 * 本次实现（O3-T03）：L5：保存完整队头串行/异常元信息；译码异常与非 CSR 串行项分配即 complete；异常不退休。
 *
 * 【2026-10-02 框架：目标机制与缺口】
 * - 异常项到达队头后交给 commit_ctrl/trap_ctrl；本项不退休。
 * - 需要补充：
 *   1) 保存异常 cause/tval（含执行期报告）、fflags、FTQ 动态身份与槽位、寄存器域、串行化类型。
 *   2) 提交宽度 core.commit_width（待定）；输出 rob_commit_t 给 commit_ctrl，由其生成
 *      ftq_commit_t（区域有效指令全部提交后交接训练并回收，不要求整个 ROB 清空，前端 16.2）、
 *      SQ committed、committed RAT/free list 归还（按目的域）、fflags 按序并入。
 *   3) 串行化：CSR、FENCE、FENCE.I、SFENCE.VMA、AMO、MMIO、ECALL/EBREAK/xRET/WFI 在队头等待执行完成
 *      后退休；FENCE.I/SFENCE/satp/PMP 触发 sys_redirect 与前端同步（D24～D28）。
 *   4) 队头异常（B26 已定）：退休停在故障指令之前，下一拍故障项为最老时在无正常退休的 trap 拍
 *      交给 commit_ctrl/trap_ctrl，故障项不退休，整体清除年轻状态（committed 边界恢复）；
 *      合法 xRET 自身退休触发返回（B27）；中断 EPC 用 committed_next_pc（B37）。
 *   5) 每项保存 succ_pc（B37）：普通指令 pc+inst_len，控制流由 BRU 解析写入真实后继；
 *      crossline_misalign（B31）；fuse_role（B34：融合成员各自占 ROB 项、各自退休，成员由
 *      FUSE_HEAD 的同一次乘法请求的低位结果完成，不独立执行）。
 * - U3：保存动态 FTQ 身份、槽位与 ftq_last；实际退休由 backend 转为 ftq_commit_t。
 * 当前实现状态：闭环简化（L5），四宽分配/退休、队头精确 trap。
 * - L5 元信息、队头 ready、global flush 合同接入；分支 M 阻止退休，C 退休拍初正常前缀。
 * Minimal ROB
 *
 * 当前已经实现的功能：
 * - 采用参数化项数的环形队列结构，默认可配置为 64 项
 * - 在 rename 阶段按真实有效 uop 数量并行分配 ROB entry 编号
 * - 在分配成功的同拍，把每个 entry 对应的 exception 和 old_dst_preg 信息写入 ROB 存储体
 * - 支持执行写回后按 rob_idx 把对应 entry 标记为 complete
 * - 支持从 ROB 队头开始按程序顺序退休最多 4 条指令，并输出对应 old_dst_preg 供 free list 回收
 * - 对外继续提供与 MACHINE_WIDTH 一样多的 ROB entry id
 * - 在 `ENABLE_RETIRE_INFO` 下保存 ALU retire 观测所需的 pc/inst/rd/rd_wdata，并在退休口输出
 * - 每项保存branch mask、new/old preg和LQ/SQ索引；误预测时清除目标分支之后的项并恢复tail
 *
 * 当前没有实现的功能：
 * - Store在AGU写SQ后complete；ROB退休通过is_store/sq_idx让SQ entry转为committed，
 *   真正写Data SRAM和SQ释放由Store Queue负责
 * - checkpoint本体由branch_checkpoint_file管理，ROB只执行其恢复tail合同
 * - 测试：sim/cocotb/rob/，含四宽 FTQ、C/M 与固定种子合同
 *
 * 时序行为：
 * - 周期 N 组合阶段：
 *   1) 统计本拍所有 alloc_req_i 中真正有效的 uop 数量
 *   2) 若剩余 ROB 空位足够，则 alloc_valid_o=1
 *   3) 对请求为 1 的 lane，按 lane 顺序给出连续的 ROB entry 编号
 *   4) 从当前 head 开始最多检查 RETIRE_WIDTH 项，只退休从队头开始连续 complete 且无异常的前缀
 * - 周期 N 上升沿：
 *   1) 若 alloc_valid_o && alloc_ready_i，则真正消耗本拍请求数量个 entry，并把 tail_q 前移
 *   2) 若本拍有退休，则把 head_q 前移退休条数，并清掉对应 entry_valid
 *   3) 同拍把 alloc_exception_i / alloc_old_dst_preg_i / alloc_instruction_id_i 写入新分配到的 ROB entry，并清除 complete 位
 *   4) 若 complete_valid_i=1，则把对应 rob_idx 的 complete 位置 1
 *   5) free_count_q 按“退休数 - 分配数”更新
 *   6) mispredict时恢复优先：分支本身标记完成、年轻表项失效、tail回到checkpoint位置
 * - 周期 N+1：
 *   看到更新后的下一批 ROB entry 编号、剩余空位数量，以及新写入的 ROB 元信息
 */

module rob #(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    parameter  int COMPLETE_WIDTH,                   // 完成报告源数量，由 backend 按写回源数给出
    localparam int MACHINE_WIDTH = o3_pkg::BACKEND_MACHINE_WIDTH,
    localparam int NUM_ROB_ENTRIES = CFG.rob.entries,
    localparam int NUM_PHYS_REGS = o3_types_pkg::INT_PREGS > o3_types_pkg::FP_PREGS
                                 ? o3_types_pkg::INT_PREGS : o3_types_pkg::FP_PREGS,
    localparam int RETIRE_WIDTH = o3_cfg_pkg::O3_CFG.core.commit_width
) (
    input  logic clk,
    input  logic rst,
    input  logic                               alloc_req_i       [MACHINE_WIDTH-1:0],
    input  logic                               alloc_exception_i [MACHINE_WIDTH-1:0],
    input  logic [o3_pkg::PREG_IDX_WIDTH-1:0]   alloc_old_dst_preg_i [MACHINE_WIDTH-1:0],
    input  logic [o3_pkg::PREG_IDX_WIDTH-1:0]   alloc_new_dst_preg_i [MACHINE_WIDTH-1:0],
    input  logic [o3_pkg::REG_ADDR_WIDTH-1:0]  alloc_rd_i [MACHINE_WIDTH-1:0],
    input  logic                               alloc_rd_write_en_i [MACHINE_WIDTH-1:0],
    input  logic                               alloc_is_load_i [MACHINE_WIDTH-1:0],
    input  logic                               alloc_is_store_i [MACHINE_WIDTH-1:0],
    input  logic [o3_pkg::LQ_IDX_WIDTH-1:0]     alloc_lq_idx_i [MACHINE_WIDTH-1:0],
    input  logic [o3_pkg::SQ_IDX_WIDTH-1:0]     alloc_sq_idx_i [MACHINE_WIDTH-1:0],
    input  o3_pkg::branch_mask_t                alloc_branch_mask_i [MACHINE_WIDTH-1:0],
    input  o3_types_pkg::ftq_id_t                 alloc_ftq_idx_i [MACHINE_WIDTH-1:0],
    input  o3_types_pkg::fetch_slot_t            alloc_ftq_slot_i [MACHINE_WIDTH-1:0],
    input  logic                               alloc_ftq_last_i [MACHINE_WIDTH-1:0],
    input  logic [o3_pkg::INST_ID_WIDTH-1:0]   alloc_instruction_id_i [MACHINE_WIDTH-1:0],
`ifdef ENABLE_RETIRE_INFO
    input  logic [o3_pkg::PC_WIDTH-1:0]         alloc_pc_i        [MACHINE_WIDTH-1:0],
    input  logic [o3_pkg::ILEN-1:0]             alloc_instruction_i [MACHINE_WIDTH-1:0],
`endif
    input  logic                               alloc_ready_i,
    input  logic                               complete_valid_i  [COMPLETE_WIDTH-1:0],
    input  logic [$clog2(NUM_ROB_ENTRIES)-1:0] complete_idx_i    [COMPLETE_WIDTH-1:0],
    input  logic                               resolution_valid_i,
    input  logic                               resolution_mispredict_i,
    input  o3_pkg::branch_tag_t                resolution_tag_i,
    input  logic [$clog2(NUM_ROB_ENTRIES)-1:0] resolution_rob_idx_i,
    input  logic                               resolution_completes_rob_i,
    input  logic [$clog2(NUM_ROB_ENTRIES)-1:0] restore_tail_i,
`ifdef ENABLE_RETIRE_INFO
    input  logic [o3_pkg::XLEN-1:0]             complete_rd_wdata_i [COMPLETE_WIDTH-1:0],
`endif
    output logic                               alloc_valid_o,
    output logic [$clog2(NUM_ROB_ENTRIES+1)-1:0] free_count_o,
    output logic [$clog2(NUM_ROB_ENTRIES)-1:0] head_o,
    output logic [$clog2(NUM_ROB_ENTRIES)-1:0] tail_o,
    output logic [$clog2(NUM_ROB_ENTRIES)-1:0] alloc_idx_o       [MACHINE_WIDTH-1:0],
    output logic                               retire_valid_o    [RETIRE_WIDTH-1:0],
    output logic [$clog2(NUM_ROB_ENTRIES)-1:0] retire_idx_o      [RETIRE_WIDTH-1:0],
    output logic [o3_pkg::PREG_IDX_WIDTH-1:0]   retire_old_dst_preg_o [RETIRE_WIDTH-1:0],
    output logic [o3_pkg::PREG_IDX_WIDTH-1:0]   retire_new_dst_preg_o [RETIRE_WIDTH-1:0],
    output logic [o3_pkg::REG_ADDR_WIDTH-1:0]  retire_rd_o [RETIRE_WIDTH-1:0],
    output logic                               retire_rd_write_en_o [RETIRE_WIDTH-1:0],
    output logic                               retire_is_load_o [RETIRE_WIDTH-1:0],
    output logic                               retire_is_store_o [RETIRE_WIDTH-1:0],
    output logic [o3_pkg::LQ_IDX_WIDTH-1:0]     retire_lq_idx_o [RETIRE_WIDTH-1:0],
    output logic [o3_pkg::SQ_IDX_WIDTH-1:0]     retire_sq_idx_o [RETIRE_WIDTH-1:0],
    output logic [o3_pkg::INST_ID_WIDTH-1:0]   retire_instruction_id_o [RETIRE_WIDTH-1:0]
    ,output o3_types_pkg::ftq_id_t               retire_ftq_idx_o [RETIRE_WIDTH-1:0]
    ,output o3_types_pkg::fetch_slot_t          retire_ftq_slot_o [RETIRE_WIDTH-1:0]
    ,output logic                              retire_ftq_last_o [RETIRE_WIDTH-1:0]
`ifdef ENABLE_RETIRE_INFO
    ,output o3_pkg::retire_info_t              retire_info_o     [RETIRE_WIDTH-1:0]
`endif
,

    // ---------------- 目标合同（框架新增，未接入逻辑） ----------------
    // 分配时保存：异常 cause/tval、FTQ 槽位、提交时需要的串行化类型、寄存器域
    input  o3_types_pkg::exc_info_t    t_alloc_exc_i      [MACHINE_WIDTH-1:0],
    input  o3_types_pkg::uop_ext_t     t_alloc_ext_i      [MACHINE_WIDTH-1:0],
    // 执行期异常报告到原项（访存/非法 CSR 等，B06）
    input  logic                       t_exc_valid_i,
    input  logic [$clog2(NUM_ROB_ENTRIES)-1:0] t_exc_idx_i,
    input  o3_types_pkg::exc_info_t    t_exc_i,
    // FP 完成时写 fflags（B15）
    input  logic                       t_fflags_valid_i   [COMPLETE_WIDTH-1:0],
    input  logic [o3_isa_pkg::FFLAGS_W-1:0] t_fflags_i    [COMPLETE_WIDTH-1:0],
    // 队头信息：串行化指令（CSR/FENCE/FENCE.I/SFENCE/AMO/MMIO/xRET/ECALL）在队头执行
    output logic                       t_head_valid_o,
    output o3_types_pkg::rob_commit_t  t_head_o,
    input  logic                       t_head_serial_done_i,   // 队头串行操作已完成，可退休
    // 每条提交指令的完整信息，送 commit_ctrl
    output o3_types_pkg::rob_commit_t  t_commit_o         [RETIRE_WIDTH-1:0],
    // 提交端整体清空（异常/xRET/系统重定向）：使用 committed map 恢复（未设计）
    input logic t_commit_block_i,
    input logic [o3_pkg::PC_WIDTH-1:0] t_alloc_pc_i [MACHINE_WIDTH-1:0],
    input logic [2:0] t_alloc_inst_len_i [MACHINE_WIDTH-1:0],
    input logic [31:0] t_alloc_instruction_i [MACHINE_WIDTH-1:0],
    input o3_types_pkg::preg_t t_alloc_src1_i [MACHINE_WIDTH-1:0],
    input logic [4:0] t_alloc_rs1_i [MACHINE_WIDTH-1:0],
    input logic t_succ_valid_i,
    input o3_types_pkg::vaddr_t t_succ_pc_i,
    input  logic                       t_flush_all_i
);

    localparam int ROB_IDX_WIDTH = $clog2(NUM_ROB_ENTRIES);
    localparam int COUNT_WIDTH   = $clog2(NUM_ROB_ENTRIES + 1);
    localparam int INST_ID_WIDTH_LOCAL = o3_pkg::INST_ID_WIDTH;

    logic [ROB_IDX_WIDTH-1:0] head_q;
    logic [ROB_IDX_WIDTH-1:0] tail_q;
    logic [COUNT_WIDTH-1:0]   free_count_q;
    logic [COUNT_WIDTH-1:0]   alloc_req_count;
    logic [COUNT_WIDTH-1:0]   retire_count;
    logic                     alloc_fire;

    // preg 字段宽度统一使用 o3_pkg::PREG_IDX_WIDTH（两域共用，o3_types_pkg::PREG_W）。

    // 当前 ROB 存储体保存异常位、被覆盖的旧目的物理寄存器和完成位。
    logic                     entry_valid_q     [NUM_ROB_ENTRIES-1:0];
    logic                     entry_exception_q [NUM_ROB_ENTRIES-1:0];
    logic [o3_pkg::PREG_IDX_WIDTH-1:0] entry_old_dst_preg_q [NUM_ROB_ENTRIES-1:0];
    logic [o3_pkg::PREG_IDX_WIDTH-1:0] entry_new_dst_preg_q [NUM_ROB_ENTRIES-1:0];
    logic [o3_pkg::REG_ADDR_WIDTH-1:0] entry_rd_q [NUM_ROB_ENTRIES-1:0];
    logic entry_rd_write_en_q [NUM_ROB_ENTRIES-1:0];
    logic entry_is_load_q [NUM_ROB_ENTRIES-1:0];
    logic entry_is_store_q [NUM_ROB_ENTRIES-1:0];
    logic [o3_pkg::LQ_IDX_WIDTH-1:0] entry_lq_idx_q [NUM_ROB_ENTRIES-1:0];
    logic [o3_pkg::SQ_IDX_WIDTH-1:0] entry_sq_idx_q [NUM_ROB_ENTRIES-1:0];
    o3_pkg::branch_mask_t entry_branch_mask_q [NUM_ROB_ENTRIES-1:0];
    o3_types_pkg::ftq_id_t entry_ftq_idx_q [NUM_ROB_ENTRIES-1:0];
    o3_types_pkg::fetch_slot_t entry_ftq_slot_q [NUM_ROB_ENTRIES-1:0];
    logic entry_ftq_last_q [NUM_ROB_ENTRIES-1:0];
    logic                      entry_complete_q  [NUM_ROB_ENTRIES-1:0];
    logic [INST_ID_WIDTH_LOCAL-1:0]  entry_instruction_id_q [NUM_ROB_ENTRIES-1:0];
`ifdef ENABLE_RETIRE_INFO
    logic [o3_pkg::PC_WIDTH-1:0]         entry_pc_q          [NUM_ROB_ENTRIES-1:0];
    logic [o3_pkg::ILEN-1:0]             entry_instruction_q [NUM_ROB_ENTRIES-1:0];
    logic [o3_pkg::XLEN-1:0]             entry_rd_wdata_q    [NUM_ROB_ENTRIES-1:0];
`endif

    o3_types_pkg::rob_commit_t meta_q [NUM_ROB_ENTRIES];

    function automatic logic [ROB_IDX_WIDTH-1:0] wrap_idx(
        input logic [ROB_IDX_WIDTH-1:0] base,
        input int unsigned              offset
    );
        int unsigned sum;
        begin
            sum      = int'(base) + offset;
            wrap_idx = ROB_IDX_WIDTH'(sum % NUM_ROB_ENTRIES);
        end
    endfunction

    always_comb begin
        alloc_req_count = '0;
        for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
            if (alloc_req_i[lane]) begin
                alloc_req_count = alloc_req_count + COUNT_WIDTH'(1);
            end
        end
    end

    assign alloc_valid_o = (free_count_q >= alloc_req_count);
    assign alloc_fire    = alloc_valid_o && alloc_ready_i;
    assign free_count_o  = free_count_q;
    assign head_o        = head_q;
    assign tail_o        = tail_q;

    generate
        genvar idx;
        for (idx = 0; idx < MACHINE_WIDTH; idx++) begin : gen_rob_alloc
            always_comb begin
                int unsigned req_before_lane;

                alloc_idx_o[idx] = '0;
                req_before_lane  = 0;

                for (int lane = 0; lane < int'(idx); lane++) begin
                    if (alloc_req_i[lane]) begin
                        req_before_lane++;
                    end
                end

                if (alloc_valid_o && alloc_req_i[idx]) begin
                    alloc_idx_o[idx] = wrap_idx(tail_q, req_before_lane);
                end
            end
        end
    endgenerate

    generate
        genvar ridx;
        for (ridx = 0; ridx < RETIRE_WIDTH; ridx++) begin : gen_rob_retire
            logic [ROB_IDX_WIDTH-1:0] retire_idx;
            logic                     retire_prefix_valid;

            assign retire_idx = wrap_idx(head_q, ridx);
            assign retire_idx_o[ridx] = retire_idx;
            assign retire_old_dst_preg_o[ridx] = entry_old_dst_preg_q[retire_idx];
            assign retire_new_dst_preg_o[ridx] = entry_new_dst_preg_q[retire_idx];
            assign retire_rd_o[ridx] = entry_rd_q[retire_idx];
            assign retire_rd_write_en_o[ridx] = entry_rd_write_en_q[retire_idx];
            assign retire_is_load_o[ridx] = entry_is_load_q[retire_idx];
            assign retire_is_store_o[ridx] = entry_is_store_q[retire_idx];
            assign retire_lq_idx_o[ridx] = entry_lq_idx_q[retire_idx];
            assign retire_sq_idx_o[ridx] = entry_sq_idx_q[retire_idx];
            assign retire_instruction_id_o[ridx] = entry_instruction_id_q[retire_idx];
            assign retire_ftq_idx_o[ridx] = entry_ftq_idx_q[retire_idx];
            assign retire_ftq_slot_o[ridx] = entry_ftq_slot_q[retire_idx];
            assign retire_ftq_last_o[ridx] = entry_ftq_last_q[retire_idx];
`ifdef ENABLE_RETIRE_INFO
            always_comb begin
                retire_info_o[ridx] = '0;
                retire_info_o[ridx].valid          = retire_valid_o[ridx];
                retire_info_o[ridx].rob_idx        = o3_pkg::ROB_IDX_WIDTH'(retire_idx);
                retire_info_o[ridx].instruction_id = entry_instruction_id_q[retire_idx];
                retire_info_o[ridx].pc             = entry_pc_q[retire_idx];
                retire_info_o[ridx].instruction    = entry_instruction_q[retire_idx];
                retire_info_o[ridx].rd             = entry_rd_q[retire_idx];
                retire_info_o[ridx].rd_write_en    = entry_rd_write_en_q[retire_idx] && meta_q[retire_idx].rd_dom!=o3_types_pkg::RD_FP;
                retire_info_o[ridx].rd_wdata       = entry_rd_wdata_q[retire_idx];
            end
`endif

            always_comb begin
                retire_prefix_valid = 1'b1;

                // 退休必须严格按序，只允许从队头开始连续退休。
                for (int prior = 0; prior <= ridx; prior++) begin
                    logic [ROB_IDX_WIDTH-1:0] prior_idx;
                    prior_idx = wrap_idx(head_q, prior);
                    if (!(entry_valid_q[prior_idx]
                       && entry_complete_q[prior_idx]
                       && !entry_exception_q[prior_idx]
                       && (!meta_q[prior_idx].ext.serialize || (prior_idx==head_q && t_head_serial_done_i)))) begin
                        retire_prefix_valid = 1'b0;
                    end
                end

                retire_valid_o[ridx] = retire_prefix_valid && !t_commit_block_i && !(resolution_valid_i && resolution_mispredict_i);
            end
        end
    endgenerate

    always_comb begin
        retire_count = '0;
        for (int port = 0; port < RETIRE_WIDTH; port++) begin
            if (retire_valid_o[port]) begin
                retire_count = retire_count + COUNT_WIDTH'(1);
            end
        end
    end

    always_comb begin
        t_head_valid_o=entry_valid_q[head_q];
        t_head_o=meta_q[head_q];
        t_head_o.valid=t_head_valid_o;
        t_head_o.complete=entry_complete_q[head_q];
        t_head_o.exc.valid=entry_exception_q[head_q];
        for (int lane=0;lane<RETIRE_WIDTH;lane++) begin
            t_commit_o[lane]=meta_q[retire_idx_o[lane]];
            t_commit_o[lane].valid=retire_valid_o[lane];
            t_commit_o[lane].region_last=entry_ftq_last_q[retire_idx_o[lane]];
        end
    end
    always_ff @(posedge clk) begin
        if (rst) meta_q <= '{default:'0};
        else begin
            for (int port=0;port<COMPLETE_WIDTH;port++)
                if (!t_flush_all_i && complete_valid_i[port] && t_fflags_valid_i[port] && entry_valid_q[complete_idx_i[port]])
                    meta_q[complete_idx_i[port]].fflags <= t_fflags_i[port];
            if (alloc_fire) for (int lane=0;lane<MACHINE_WIDTH;lane++) if (alloc_req_i[lane]) begin
                meta_q[alloc_idx_o[lane]] <= '{valid:1'b1,rob_idx:o3_types_pkg::rob_idx_t'(alloc_idx_o[lane]),
                    pc:t_alloc_pc_i[lane],inst_len:t_alloc_inst_len_i[lane],ftq_id:alloc_ftq_idx_i[lane],slot:alloc_ftq_slot_i[lane],
                    region_last:alloc_ftq_last_i[lane],rd_dom:t_alloc_ext_i[lane].rd_dom,rd:alloc_rd_i[lane],
                    rd_write_en:alloc_rd_write_en_i[lane],new_preg:alloc_new_dst_preg_i[lane],old_preg:alloc_old_dst_preg_i[lane],
                    is_load:alloc_is_load_i[lane],is_store:alloc_is_store_i[lane],lq_idx:alloc_lq_idx_i[lane],sq_idx:alloc_sq_idx_i[lane],
                    sys_op:t_alloc_ext_i[lane].sys_op,ext:t_alloc_ext_i[lane],exc:t_alloc_exc_i[lane],
                    instruction:t_alloc_instruction_i[lane],src1_preg:t_alloc_src1_i[lane],rs1:t_alloc_rs1_i[lane],
                    succ_pc:t_alloc_pc_i[lane]+o3_types_pkg::vaddr_t'(t_alloc_inst_len_i[lane]),fuse_role:o3_types_pkg::FUSE_NONE,default:'0};
            end
            if (t_exc_valid_i) meta_q[t_exc_idx_i].exc <= t_exc_i;
            if (t_succ_valid_i) meta_q[resolution_rob_idx_i].succ_pc <= t_succ_pc_i;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            head_q       <= '0;
            tail_q       <= '0;
            free_count_q <= COUNT_WIDTH'(NUM_ROB_ENTRIES);
            for (int entry = 0; entry < NUM_ROB_ENTRIES; entry++) begin
                entry_valid_q[entry]     <= 1'b0;
                entry_exception_q[entry] <= 1'b0;
                entry_old_dst_preg_q[entry] <= '0;
                entry_new_dst_preg_q[entry] <= '0;
                entry_rd_q[entry] <= '0;
                entry_rd_write_en_q[entry] <= 1'b0;
                entry_is_load_q[entry] <= 1'b0;
                entry_is_store_q[entry] <= 1'b0;
                entry_lq_idx_q[entry] <= '0;
                entry_sq_idx_q[entry] <= '0;
                entry_branch_mask_q[entry] <= '0;
                entry_ftq_idx_q[entry] <= '0;
                entry_ftq_slot_q[entry] <= '0;
                entry_ftq_last_q[entry] <= 1'b0;
                entry_complete_q[entry]  <= 1'b0;
                entry_instruction_id_q[entry] <= '0;
`ifdef ENABLE_RETIRE_INFO
                entry_pc_q[entry]          <= '0;
                entry_instruction_q[entry] <= '0;
                entry_rd_wdata_q[entry]    <= '0;
`endif
            end
        end else if (t_flush_all_i) begin
            head_q <= '0; tail_q <= '0; free_count_q <= COUNT_WIDTH'(NUM_ROB_ENTRIES);
            entry_valid_q <= '{default:1'b0}; entry_complete_q <= '{default:1'b0};
        end else if (resolution_valid_i && resolution_mispredict_i) begin
            int unsigned kept_count;
            kept_count = 0;
            for (int entry = 0; entry < NUM_ROB_ENTRIES; entry++) begin
                if (entry_valid_q[entry] && entry_branch_mask_q[entry][resolution_tag_i]) begin
                    entry_valid_q[entry] <= 1'b0;
                end else if (entry_valid_q[entry]) begin
                    entry_branch_mask_q[entry][resolution_tag_i] <= 1'b0;
                    kept_count++;
                end
            end
            if (resolution_completes_rob_i) begin
                entry_complete_q[resolution_rob_idx_i] <= 1'b1;
            end
            // 默认not-taken可能在块中部才发现真实控制流；恢复后该分支成为此FTQ块
            // 最后一条仍存活的指令，提交时据此释放包含它的FTQ entry。
            entry_ftq_last_q[resolution_rob_idx_i] <= 1'b1;
            // Resolution与普通写回是独立网络；JAL/JALR可能在同拍取得PRF写口。
            // 恢复优先级不能吞掉该写回，否则保留下来的分支自身将永远无法提交。
            for (int c = 0; c < COMPLETE_WIDTH; c++) begin
                if (complete_valid_i[c]) begin
                    entry_complete_q[complete_idx_i[c]] <= 1'b1;
`ifdef ENABLE_RETIRE_INFO
                    entry_rd_wdata_q[complete_idx_i[c]] <= complete_rd_wdata_i[c];
`endif
                end
            end
            tail_q <= restore_tail_i;
            free_count_q <= COUNT_WIDTH'(NUM_ROB_ENTRIES - kept_count);
        end else begin
            if (resolution_valid_i) begin
                for (int entry = 0; entry < NUM_ROB_ENTRIES; entry++) begin
                    entry_branch_mask_q[entry][resolution_tag_i] <= 1'b0;
                end
                if (resolution_completes_rob_i) begin
                    entry_complete_q[resolution_rob_idx_i] <= 1'b1;
                end
            end
            for (int port = 0; port < RETIRE_WIDTH; port++) begin
                if (retire_valid_o[port]) begin
                    entry_valid_q[retire_idx_o[port]] <= 1'b0;
                end
            end

            for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
                if (alloc_fire && alloc_req_i[lane]) begin
                    entry_valid_q[alloc_idx_o[lane]]     <= 1'b1;
                    entry_exception_q[alloc_idx_o[lane]] <= alloc_exception_i[lane];
                    entry_old_dst_preg_q[alloc_idx_o[lane]] <= alloc_old_dst_preg_i[lane];
                    entry_new_dst_preg_q[alloc_idx_o[lane]] <= alloc_new_dst_preg_i[lane];
                    entry_rd_q[alloc_idx_o[lane]] <= alloc_rd_i[lane];
                    entry_rd_write_en_q[alloc_idx_o[lane]] <= alloc_rd_write_en_i[lane];
                    entry_is_load_q[alloc_idx_o[lane]] <= alloc_is_load_i[lane];
                    entry_is_store_q[alloc_idx_o[lane]] <= alloc_is_store_i[lane];
                    entry_lq_idx_q[alloc_idx_o[lane]] <= alloc_lq_idx_i[lane];
                    entry_sq_idx_q[alloc_idx_o[lane]] <= alloc_sq_idx_i[lane];
                    entry_branch_mask_q[alloc_idx_o[lane]] <= alloc_branch_mask_i[lane];
                    if (resolution_valid_i) entry_branch_mask_q[alloc_idx_o[lane]][resolution_tag_i] <= 1'b0;
                    entry_ftq_idx_q[alloc_idx_o[lane]] <= alloc_ftq_idx_i[lane];
                    entry_ftq_slot_q[alloc_idx_o[lane]] <= alloc_ftq_slot_i[lane];
                    entry_ftq_last_q[alloc_idx_o[lane]] <= alloc_ftq_last_i[lane];
                    // Decode faults and non-CSR serial operations have no execution unit.
                    // They are ready for head trap/serial control on allocation;
                    // serial readiness still prevents premature normal retirement.
                    entry_complete_q[alloc_idx_o[lane]] <= alloc_exception_i[lane]
                        || (t_alloc_ext_i[lane].serialize
                            && t_alloc_ext_i[lane].csr_op==o3_types_pkg::CSROP_NONE);
                    entry_instruction_id_q[alloc_idx_o[lane]] <= alloc_instruction_id_i[lane];
`ifdef ENABLE_RETIRE_INFO
                    entry_pc_q[alloc_idx_o[lane]]          <= alloc_pc_i[lane];
                    entry_instruction_q[alloc_idx_o[lane]] <= alloc_instruction_i[lane];
                    entry_rd_wdata_q[alloc_idx_o[lane]]    <= '0;
`endif
                end
            end

            // 写回阶段返回的执行结果在这里把 ROB 项标记为 complete。
            for (int c = 0; c < COMPLETE_WIDTH; c++) begin
                if (complete_valid_i[c]) begin
                    entry_complete_q[complete_idx_i[c]] <= 1'b1;
`ifdef ENABLE_RETIRE_INFO
                    entry_rd_wdata_q[complete_idx_i[c]] <= complete_rd_wdata_i[c];
`endif
                end
            end

            if (retire_count != '0) begin
                head_q <= wrap_idx(head_q, int'(retire_count));
            end

            if (alloc_fire) begin
                tail_q <= wrap_idx(tail_q, int'(alloc_req_count));
            end

            free_count_q <= free_count_q + retire_count - (alloc_fire ? alloc_req_count : COUNT_WIDTH'(0));
            if (t_exc_valid_i) begin
                entry_exception_q[t_exc_idx_i] <= 1'b1;
                entry_complete_q[t_exc_idx_i] <= 1'b1;
            end
        end
    end

    initial begin
        if (MACHINE_WIDTH <= 0) begin
            $error("rob requires MACHINE_WIDTH > 0");
        end

        if (NUM_ROB_ENTRIES <= 0) begin
            $error("rob requires NUM_ROB_ENTRIES > 0");
        end

        if (NUM_PHYS_REGS <= 0) begin
            $error("rob requires NUM_PHYS_REGS > 0");
        end

        if (RETIRE_WIDTH <= 0) begin
            $error("rob requires RETIRE_WIDTH > 0");
        end
    end

endmodule
