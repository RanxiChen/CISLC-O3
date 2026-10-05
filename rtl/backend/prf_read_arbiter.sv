/**
 * PRF 读口仲裁 —— 按 ROB 年龄原子分配共享物理寄存器读口
 *
 * 来源：2026-10-02 从 backend.sv 的组合仲裁块原样迁出，选择逻辑未改。
 *
 * 当前已经实现：
 * - Integer（每个 ALU 一个候选）、Memory、Branch 候选按相对 ROB 队头的年龄从老到年轻
 *   贪心扫描；一条 uop 所需的 1/2 个读口必须原子取得，否则留在 IQ（不握手）。
 * - 只有对应执行级可接收（alu_regread_ready / mem_accept / branch_regread_ready）才参与。
 * - 输出每个候选使用的读口编号及读地址；grant 同时作为 IQ 的 issue_ready。
 *
 * 当前缺口与需要补充的机制：
 * - issue_block_i（仅接 M）：只有误预测阻止全部
 *   候选发射，O3-T01 已解除正确解析暂停，资源竞争仍可回压。
 * - 只服务整数域。目标需要 FP 域读口（FP IQ、FSW/FSD 的 FP 数据源、FMA 三源、跨域
 *   FMV/FCVT 的整数源）；FP 读口数与 FP IQ 组织待定（B14/B15）。
 * - 新增的 M FU（MUL/DIV）、CSR、AMO 候选的读口归属未定：取决于 M FU 的 IQ 归属（B21 待定）。
 * - Memory 现状单发射；访存地址流水线条数待定（B03）。
 *
 * 逐周期说明：本模块纯组合。
 * - 周期 N 组合：给出 grant 与读地址；PRF 组合读出数据。
 * - 周期 N 上升沿：grant 候选从 IQ 删除并把读值锁存进对应 RegRead 槽（在各执行级内）。
 * - 周期 N+1：执行级可见锁存的操作数。
 *
 * 测试：sim/cocotb/prf_read_arbiter/。
 */
// 当前实现状态：闭环简化（L3）；正确解析不停顿，四宽合同。测试：sim/cocotb/prf_read_arbiter/。
module prf_read_arbiter
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    localparam int NUM_INT_ALUS    = CFG.exec.num_alu,
    localparam int PRF_READ_PORTS  = CFG.exec.int_prf_read_ports,
    localparam int NUM_ROB_ENTRIES = CFG.rob.entries,
    localparam int PORT_W          = $clog2(PRF_READ_PORTS),
    localparam int ROB_W           = $clog2(NUM_ROB_ENTRIES)
) (
    input  logic                        issue_block_i,   // 仅 M；正确解析不阻塞
    input  logic [ROB_W-1:0]            rob_head_i,

    input  renamed_uop_t [NUM_INT_ALUS-1:0] int_issue_uop_i,
    input  logic [NUM_INT_ALUS-1:0]     int_issue_valid_i,
    input  logic                        alu_regread_ready_i [NUM_INT_ALUS-1:0],
    input  renamed_uop_t                mem_issue_uop_i,
    input  logic                        mem_issue_valid_i,
    input  logic                        mem_accept_i,    // Memory 执行级可接收
    input  renamed_uop_t                br_issue_uop_i,
    input  logic                        br_issue_valid_i,
    input  logic                        branch_regread_ready_i,

    output logic [NUM_INT_ALUS-1:0]     int_read_grant_o,
    output logic                        mem_read_grant_o,
    output logic                        branch_read_grant_o,
    output logic [PORT_W-1:0]           int_src1_port_o [NUM_INT_ALUS-1:0],
    output logic [PORT_W-1:0]           int_src2_port_o [NUM_INT_ALUS-1:0],
    output logic [PORT_W-1:0]           mem_src1_port_o,
    output logic [PORT_W-1:0]           mem_src2_port_o,
    output logic [PORT_W-1:0]           branch_src1_port_o,
    output logic [PORT_W-1:0]           branch_src2_port_o,
    output logic [PREG_IDX_WIDTH-1:0]   prf_rd_addr_o [PRF_READ_PORTS-1:0]
);

    function automatic int unsigned rob_age(input logic [ROB_W-1:0] idx);
        rob_age = (int'(idx) + NUM_ROB_ENTRIES - int'(rob_head_i)) % NUM_ROB_ENTRIES;
    endfunction

    // Wakeup/select、FU空闲和PRF读口在同一个组合仲裁中联合决定。候选按ROB年龄
    // 从老到年轻贪心扫描；一条uop所需的1/2个读口必须原子取得，否则留在IQ。
    always_comb begin
        logic [NUM_INT_ALUS-1:0] considered_int;
        logic considered_mem;
        logic considered_branch;
        int unsigned read_used;

        prf_rd_addr_o = '{default: '0};
        int_read_grant_o = '0;
        mem_read_grant_o = 1'b0;
        branch_read_grant_o = 1'b0;
        int_src1_port_o = '{default: '0};
        int_src2_port_o = '{default: '0};
        mem_src1_port_o = '0;
        mem_src2_port_o = '0;
        branch_src1_port_o = '0;
        branch_src2_port_o = '0;
        considered_int = '0;
        considered_mem = 1'b0;
        considered_branch = 1'b0;
        read_used = 0;

        for (int choice = 0; choice < NUM_INT_ALUS + 2; choice++) begin
            int chosen_kind;
            int chosen_idx;
            int unsigned chosen_age;
            int unsigned read_need;
            chosen_kind = -1;
            chosen_idx = -1;
            chosen_age = NUM_ROB_ENTRIES;
            read_need = 0;

            for (int alu = 0; alu < NUM_INT_ALUS; alu++) begin
                if (!issue_block_i
                 && !considered_int[alu] && int_issue_valid_i[alu]
                 && alu_regread_ready_i[alu]
                 && (rob_age(int_issue_uop_i[alu].rob_idx) < chosen_age)) begin
                    chosen_kind = 0;
                    chosen_idx = alu;
                    chosen_age = rob_age(int_issue_uop_i[alu].rob_idx);
                end
            end
            if (!issue_block_i && !considered_mem && mem_issue_valid_i
             && mem_accept_i
             && ((chosen_kind < 0) || (rob_age(mem_issue_uop_i.rob_idx) < chosen_age))) begin
                chosen_kind = 1;
                chosen_idx = 0;
                chosen_age = rob_age(mem_issue_uop_i.rob_idx);
            end
            if (!issue_block_i && !considered_branch && br_issue_valid_i
             && branch_regread_ready_i
             && ((chosen_kind < 0) || (rob_age(br_issue_uop_i.rob_idx) < chosen_age))) begin
                chosen_kind = 2;
                chosen_idx = 0;
                chosen_age = rob_age(br_issue_uop_i.rob_idx);
            end

            if (chosen_kind == 0) begin
                considered_int[chosen_idx] = 1'b1;
                read_need = int'(int_issue_uop_i[chosen_idx].rs1_read_en)
                          + int'(int_issue_uop_i[chosen_idx].rs2_read_en
                                 && !int_issue_uop_i[chosen_idx].use_imm);
                if ((read_used + read_need) <= PRF_READ_PORTS) begin
                    int_read_grant_o[chosen_idx] = 1'b1;
                    if (int_issue_uop_i[chosen_idx].rs1_read_en) begin
                        int_src1_port_o[chosen_idx] = PORT_W'(read_used);
                        prf_rd_addr_o[read_used] = int_issue_uop_i[chosen_idx].src1_preg;
                        read_used++;
                    end
                    if (int_issue_uop_i[chosen_idx].rs2_read_en
                     && !int_issue_uop_i[chosen_idx].use_imm) begin
                        int_src2_port_o[chosen_idx] = PORT_W'(read_used);
                        prf_rd_addr_o[read_used] = int_issue_uop_i[chosen_idx].src2_preg;
                        read_used++;
                    end
                end
            end else if (chosen_kind == 1) begin
                considered_mem = 1'b1;
                read_need = int'(mem_issue_uop_i.rs1_read_en)
                          + int'(mem_issue_uop_i.rs2_read_en);
                if ((read_used + read_need) <= PRF_READ_PORTS) begin
                    mem_read_grant_o = 1'b1;
                    if (mem_issue_uop_i.rs1_read_en) begin
                        mem_src1_port_o = PORT_W'(read_used);
                        prf_rd_addr_o[read_used] = mem_issue_uop_i.src1_preg;
                        read_used++;
                    end
                    if (mem_issue_uop_i.rs2_read_en) begin
                        mem_src2_port_o = PORT_W'(read_used);
                        prf_rd_addr_o[read_used] = mem_issue_uop_i.src2_preg;
                        read_used++;
                    end
                end
            end else if (chosen_kind == 2) begin
                considered_branch = 1'b1;
                read_need = int'(br_issue_uop_i.rs1_read_en)
                          + int'(br_issue_uop_i.rs2_read_en);
                if ((read_used + read_need) <= PRF_READ_PORTS) begin
                    branch_read_grant_o = 1'b1;
                    if (br_issue_uop_i.rs1_read_en) begin
                        branch_src1_port_o = PORT_W'(read_used);
                        prf_rd_addr_o[read_used] = br_issue_uop_i.src1_preg;
                        read_used++;
                    end
                    if (br_issue_uop_i.rs2_read_en) begin
                        branch_src2_port_o = PORT_W'(read_used);
                        prf_rd_addr_o[read_used] = br_issue_uop_i.src2_preg;
                        read_used++;
                    end
                end
            end
        end
    end

endmodule
