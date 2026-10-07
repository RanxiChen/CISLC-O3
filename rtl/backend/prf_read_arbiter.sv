/**
 * Shared INT PRF read-port allocation by ROB age (B14/B15).
 * INT/MEM/BR and one single-source FP candidate compete atomically for available ports.
 * Only an available execution/RegRead slot can participate; denied candidates remain in IQ.
 * FP store data uses dedicated FP read port 6, so FSW/FSD requests only INT rs1 here.
 * FP lane read ports are fixed separately in backend; this module grants only its INT source.
 * 当前实现状态：闭环简化（L9）；lint/测试未运行。
 * N: order candidates and allocate complete source read sets. N edge: granted entries
 * leave IQ and latch PRF read values in RegRead. N+1: execution sees captured operands.
 */
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

    input renamed_uop_t fp_issue_uop_i,
    input logic fp_issue_valid_i,
    input logic fp_regread_ready_i,
    output logic fp_read_grant_o,
    output logic [PORT_W-1:0] fp_src1_port_o,

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
        logic considered_branch, considered_fp;
        int unsigned read_used;

        prf_rd_addr_o = '{default: '0};
        int_read_grant_o = '0;
        mem_read_grant_o = 1'b0;
        branch_read_grant_o = 1'b0;
        fp_read_grant_o=0; fp_src1_port_o='0;
        int_src1_port_o = '{default: '0};
        int_src2_port_o = '{default: '0};
        mem_src1_port_o = '0;
        mem_src2_port_o = '0;
        branch_src1_port_o = '0;
        branch_src2_port_o = '0;
        considered_int = '0;
        considered_mem = 1'b0;
        considered_branch = 1'b0; considered_fp=0;
        read_used = 0;

        for (int choice = 0; choice < NUM_INT_ALUS + 3; choice++) begin
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

            if (!issue_block_i && !considered_fp && fp_issue_valid_i && fp_regread_ready_i
                && ((chosen_kind<0) || rob_age(fp_issue_uop_i.rob_idx)<chosen_age)) begin
                chosen_kind=3; chosen_idx=0; chosen_age=rob_age(fp_issue_uop_i.rob_idx);
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
                          + int'(mem_issue_uop_i.rs2_read_en && mem_issue_uop_i.ext.rs2_dom!=o3_types_pkg::RD_FP);
                if ((read_used + read_need) <= PRF_READ_PORTS) begin
                    mem_read_grant_o = 1'b1;
                    if (mem_issue_uop_i.rs1_read_en) begin
                        mem_src1_port_o = PORT_W'(read_used);
                        prf_rd_addr_o[read_used] = mem_issue_uop_i.src1_preg;
                        read_used++;
                    end
                    if (mem_issue_uop_i.rs2_read_en && mem_issue_uop_i.ext.rs2_dom!=o3_types_pkg::RD_FP) begin
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
            end else if (chosen_kind==3) begin
                considered_fp=1;
                if (read_used<PRF_READ_PORTS) begin
                    fp_read_grant_o=1; fp_src1_port_o=PORT_W'(read_used);
                    prf_rd_addr_o[read_used]=fp_issue_uop_i.src1_preg;
                    read_used++;
                end
            end
        end
    end

endmodule
