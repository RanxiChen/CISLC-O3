/**
 * Shared INT PRF read-port allocation by ROB age (B14/B15).
 * INT/MEM/BR and one single-source FP candidate compete atomically for available ports.
 * Only an eligible request can participate. The caller retains ownership on denial;
 * backend keeps denied heads in the registered per-FU A0 request stage.
 * FP store data uses dedicated configured FP read ports, so FSW/FSD requests only INT rs1 here.
 * FP lane read ports are fixed separately in backend; this module grants only its INT source.
 * 当前实现状态：闭环简化（L9）；lint/测试未运行。
 * 2026-10-11: parallel bounded-age rank plus narrow greedy port allocation.
 * Backend places this combinational helper between two real arbitration registers.
 * Standalone callers retain the same combinational interface and tie-breaking rules.
 */
module prf_read_arbiter
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    parameter int NUM_INT_CANDIDATES = CFG.exec.num_alu,
    localparam int PRF_READ_PORTS  = CFG.exec.int_prf_read_ports,
    localparam int NUM_ROB_ENTRIES = CFG.rob.entries,
    localparam int PORT_W          = $clog2(PRF_READ_PORTS),
    localparam int P=CFG.lsu.agu_pipes,
    localparam int ROB_W           = $clog2(NUM_ROB_ENTRIES)
) (
    input  logic                        issue_block_i,   // 仅 M；正确解析不阻塞
    input  logic [ROB_W-1:0]            rob_head_i,

    input  renamed_uop_t [NUM_INT_CANDIDATES-1:0] int_issue_uop_i,
    input  logic [NUM_INT_CANDIDATES-1:0] int_issue_valid_i,
    input  logic alu_regread_ready_i [NUM_INT_CANDIDATES-1:0],
    input  renamed_uop_t [P-1:0] mem_issue_uop_i,
    input  logic [P-1:0] mem_issue_valid_i,
    input  logic mem_accept_i[P],    // Memory 执行级可接收
    input  renamed_uop_t                br_issue_uop_i,
    input  logic                        br_issue_valid_i,
    input  logic                        branch_regread_ready_i,

    input renamed_uop_t fp_issue_uop_i,
    input logic fp_issue_valid_i,
    input logic fp_regread_ready_i,
    output logic fp_read_grant_o,
    output logic [PORT_W-1:0] fp_src1_port_o,

    output logic [NUM_INT_CANDIDATES-1:0] int_read_grant_o,
    output logic [P-1:0] mem_read_grant_o,
    output logic                        branch_read_grant_o,
    output logic [PORT_W-1:0] int_src1_port_o [NUM_INT_CANDIDATES-1:0],
    output logic [PORT_W-1:0] int_src2_port_o [NUM_INT_CANDIDATES-1:0],
    output logic [PORT_W-1:0]           mem_src1_port_o[P],
    output logic [PORT_W-1:0]           mem_src2_port_o[P],
    output logic [PORT_W-1:0]           branch_src1_port_o,
    output logic [PORT_W-1:0]           branch_src2_port_o,
    output logic [PREG_IDX_WIDTH-1:0]   prf_rd_addr_o [PRF_READ_PORTS-1:0]
);

    localparam int SOURCES = NUM_INT_CANDIDATES + P + 2;
    localparam int LEAVES = 1 << $clog2(SOURCES);
    localparam int RANK_W = $clog2(SOURCES+1);
    localparam int USED_W = $clog2(PRF_READ_PORTS+1);
    typedef logic [ROB_W-1:0] age_t;
    typedef logic [USED_W:0] count_t;
    logic [SOURCES-1:0] eligible, granted;
    renamed_uop_t candidate [SOURCES];
    logic need1 [SOURCES], need2 [SOURCES];
    logic [RANK_W-1:0] ranks [SOURCES];
    logic [PORT_W-1:0] source_port1 [SOURCES], source_port2 [SOURCES];

    function automatic age_t rob_age(input logic [ROB_W-1:0] idx);
        logic [ROB_W:0] distance;
        // Circular age is bounded by ROB depth; avoid signed 32-bit remainder.
        distance = {1'b0,idx} >= {1'b0,rob_head_i}
                 ? {1'b0,idx} - {1'b0,rob_head_i}
                 : {1'b0,idx} + (ROB_W+1)'(NUM_ROB_ENTRIES) - {1'b0,rob_head_i};
        return age_t'(distance);
    endfunction

    always_comb begin
        eligible='0; candidate='{default:'0};
        need1='{default:0}; need2='{default:0};
        for (int src=0;src<NUM_INT_CANDIDATES;src++) begin
            candidate[src]=int_issue_uop_i[src];
            eligible[src]=int_issue_valid_i[src] && alu_regread_ready_i[src] && !issue_block_i;
            need1[src]=candidate[src].rs1_read_en;
            need2[src]=candidate[src].rs2_read_en && !candidate[src].use_imm;
        end
        for (int p=0;p<P;p++) begin
            candidate[NUM_INT_CANDIDATES+p]=mem_issue_uop_i[p];
            eligible[NUM_INT_CANDIDATES+p]=mem_issue_valid_i[p] && mem_accept_i[p] && !issue_block_i;
            need1[NUM_INT_CANDIDATES+p]=mem_issue_uop_i[p].rs1_read_en;
            need2[NUM_INT_CANDIDATES+p]=mem_issue_uop_i[p].rs2_read_en &&
                mem_issue_uop_i[p].ext.rs2_dom!=o3_types_pkg::RD_FP;
        end
        candidate[SOURCES-2]=br_issue_uop_i;
        eligible[SOURCES-2]=br_issue_valid_i && branch_regread_ready_i && !issue_block_i;
        need1[SOURCES-2]=br_issue_uop_i.rs1_read_en;
        need2[SOURCES-2]=br_issue_uop_i.rs2_read_en;
        candidate[SOURCES-1]=fp_issue_uop_i;
        eligible[SOURCES-1]=fp_issue_valid_i && fp_regread_ready_i && !issue_block_i;
        need1[SOURCES-1]=1'b1; // Only an INT-source FP operation uses this candidate.
    end

    // Rank eligible candidates in parallel; ties retain the original source order.
    always_comb begin
        age_t ages [SOURCES];
        logic [RANK_W-1:0] tree [SOURCES][2*LEAVES];
        tree='{default:'{default:'0}};
        for (int src=0;src<SOURCES;src++) ages[src]=rob_age(candidate[src].rob_idx);
        for (int src=0;src<SOURCES;src++) begin
            for (int other=0;other<SOURCES;other++)
                tree[src][LEAVES+other]=RANK_W'(eligible[other] &&
                    (ages[other]<ages[src] || (ages[other]==ages[src] && other<src)));
            for (int node=LEAVES-1;node>0;node--)
                tree[src][node]=tree[src][2*node]+tree[src][2*node+1];
            ranks[src]=tree[src][1];
        end
    end

    // Only bounded port occupancy depends on the preceding age rank. No rank
    // repeats a full oldest-candidate scan or transports a wide uop through it.
    // Keep skip-and-continue semantics when an older two-source request cannot fit.
    always_comb begin
        count_t used;
        used='0; granted='0; prf_rd_addr_o='{default:'0};
        source_port1='{default:'0}; source_port2='{default:'0};
        for (int rank=0;rank<SOURCES;rank++) begin
            logic [SOURCES-1:0] at_rank;
            logic first,second;
            logic [PREG_IDX_WIDTH-1:0] addr1,addr2;
            count_t demand;
            at_rank='0; first=0; second=0; addr1='0; addr2='0;
            for (int src=0;src<SOURCES;src++) begin
                at_rank[src]=eligible[src] && ranks[src]==RANK_W'(rank);
                first |= at_rank[src] && need1[src];
                second |= at_rank[src] && need2[src];
                addr1 |= candidate[src].src1_preg & {PREG_IDX_WIDTH{at_rank[src]}};
                addr2 |= candidate[src].src2_preg & {PREG_IDX_WIDTH{at_rank[src]}};
            end
            demand=count_t'(first)+count_t'(second);
            if ((used+demand)<=count_t'(PRF_READ_PORTS)) begin
                granted |= at_rank;
                for (int src=0;src<SOURCES;src++) if(at_rank[src]) begin
                    if(first) source_port1[src]=PORT_W'(used);
                    if(second) source_port2[src]=PORT_W'(used+count_t'(first));
                end
                if(first) prf_rd_addr_o[used]=addr1;
                if(second) prf_rd_addr_o[used+count_t'(first)]=addr2;
                used+=demand;
            end
        end
        int_read_grant_o='0; mem_read_grant_o='0;
        int_src1_port_o='{default:'0}; int_src2_port_o='{default:'0};
        mem_src1_port_o='{default:'0}; mem_src2_port_o='{default:'0};
        for(int src=0;src<NUM_INT_CANDIDATES;src++) begin
            int_read_grant_o[src]=granted[src];
            int_src1_port_o[src]=source_port1[src]; int_src2_port_o[src]=source_port2[src];
        end
        for(int p=0;p<P;p++) begin
            mem_read_grant_o[p]=granted[NUM_INT_CANDIDATES+p];
            mem_src1_port_o[p]=source_port1[NUM_INT_CANDIDATES+p];
            mem_src2_port_o[p]=source_port2[NUM_INT_CANDIDATES+p];
        end
        branch_read_grant_o=granted[SOURCES-2]; fp_read_grant_o=granted[SOURCES-1];
        branch_src1_port_o=source_port1[SOURCES-2]; branch_src2_port_o=source_port2[SOURCES-2];
        fp_src1_port_o=source_port1[SOURCES-1];
    end
endmodule
