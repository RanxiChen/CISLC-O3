/** Elastic, overlapped operand scheduling; no serial controller.
 * A0: independent four-slot reservations; admission uses registered occupancy.
 * A1: ranked candidates; one packet advances every cycle, denied owners retry A0.
 * A2: two granted address packets; the oldest packet drives the PRF and RegRead.
 * N: each stage operates on its own registered head and may accept a new item
 * while its current head advances. N edge transfers ownership, never duplicates it.
 * N+1: the next head advances independently. An uncongested lane sustains one/cycle.
 * Neither A2 drain nor allocation grants propagate combinationally to FU-buffer
 * dequeue: upstream admission uses only local registered reservation occupancy.
 * Each FU has three operand-capture slots reserved before port allocation. Slow
 * FUs cannot hold shared read addresses. Partial unread packets retain mappings;
 * cancellation applies to every slot. Wake notices do not replace the final real-data readiness check.
 * 当前实现状态：目标实现；功能/连续吞吐验证待后端重构后进行。
 */
module operand_read_pipeline import o3_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG,
    parameter int INT_SOURCES=CFG.exec.num_alu+2,
    parameter int FP_SOURCES=5,
    localparam int P=CFG.lsu.agu_pipes,
    localparam int MEM_BASE=INT_SOURCES,
    localparam int BR_SLOT=MEM_BASE+P,
    localparam int FP_BASE=BR_SLOT+1,
    localparam int SOURCES=FP_BASE+FP_SOURCES,
    localparam int INT_PORTS=CFG.exec.int_prf_read_ports,
    localparam int PORT_W=$clog2(INT_PORTS),
    localparam int FP_PORTS=CFG.exec.fp_prf_read_ports,
    localparam int FP_READ_SETS=(FP_PORTS-P)/3,
    localparam int FP_STORE_BASE=3*FP_READ_SETS,
    localparam int ROB_W=$clog2(CFG.rob.entries),
    localparam int RANK_W=$clog2(SOURCES+1),
    localparam int LEAVES=1<<$clog2(SOURCES),
    localparam int COUNT_W=$clog2(INT_PORTS+1)+1,
    localparam int REQUEST_SLOTS=4,
    localparam int CAPTURE_SLOTS=3,
    localparam int SLOT_W=$clog2(REQUEST_SLOTS),
    localparam int FP_BUDGETS=FP_READ_SETS+1,
    localparam int BUDGETS=(INT_PORTS+1)*FP_BUDGETS,
    localparam int BUDGET_W=$clog2(BUDGETS)
)(
    input logic clk,rst,flush_i,issue_block_i,
    input logic [ROB_W-1:0] rob_head_i,
    input branch_resolution_t resolution_i,
    input renamed_uop_t [SOURCES-1:0] request_uop_i,
    input logic [SOURCES-1:0] request_valid_i,
    output logic [SOURCES-1:0] request_take_o,
    output renamed_uop_t [SOURCES-1:0] pending_uop_o,
    input logic [SOURCES-1:0] pending_eligible_i,
    output renamed_uop_t [SOURCES-1:0] read_uop_o,
    input logic [SOURCES-1:0] read_eligible_i,
    output logic [SOURCES-1:0] read_grant_o,
    output logic [PORT_W-1:0] src1_port_o[SOURCES],src2_port_o[SOURCES],
    output logic [2:0] fp_base_o[FP_SOURCES],
    output logic [PREG_IDX_WIDTH-1:0] int_addr_o[INT_PORTS-1:0],fp_addr_o[FP_PORTS],
    input logic [XLEN-1:0] int_data_i[INT_PORTS-1:0],fp_data_i[FP_PORTS],
    output renamed_uop_t [SOURCES-1:0] operand_uop_o,
    input logic [SOURCES-1:0] operand_ready_i,
    output logic [SOURCES-1:0] operand_grant_o,
    output logic [XLEN-1:0] operand_src1_o[SOURCES],operand_src2_o[SOURCES],operand_src3_o[SOURCES]
);
    // Stage-local fields: immutable instruction payload stays in the A0 RAM.
    // No stage needs a second full renamed_uop_t as its mutable owner record.
    typedef struct packed {
        logic valid;
        logic [INST_ID_WIDTH-1:0] instruction_id;
        logic [ROB_IDX_WIDTH-1:0] rob_idx;
        branch_mask_t branch_mask,lo_mask;
    } request_owner_t;
    typedef struct packed {
        logic valid;
        logic [INST_ID_WIDTH-1:0] instruction_id;
        branch_mask_t branch_mask;
        logic rs1_read_en,rs2_read_en,use_imm;
        logic [PREG_IDX_WIDTH-1:0] src1_preg,src2_preg,src3_preg;
        o3_types_pkg::reg_domain_e rs1_dom,rs2_dom;
    } rank_descriptor_t;
    typedef struct packed {
        logic valid;
        logic [INST_ID_WIDTH-1:0] instruction_id;
        branch_mask_t branch_mask;
    } read_owner_t;
    typedef struct packed {
        logic valid;
        branch_mask_t branch_mask,lo_mask;
    } capture_owner_t;
    typedef struct packed {
        rank_descriptor_t [SOURCES-1:0] uop;
        logic [SOURCES-1:0][RANK_W-1:0] rank;
        logic [SOURCES-1:0][SLOT_W-1:0] slot;
    } ranked_packet_t;
    typedef struct packed {
        read_owner_t [SOURCES-1:0] uop;
        logic [SOURCES-1:0][SLOT_W-1:0] slot;
        logic [SOURCES-1:0][PORT_W-1:0] port1,port2;
        logic [FP_SOURCES-1:0][2:0] fp_base;
        logic [INT_PORTS-1:0][PREG_IDX_WIDTH-1:0] int_addr;
        logic [FP_PORTS-1:0][PREG_IDX_WIDTH-1:0] fp_addr;
    } read_packet_t;
    typedef struct packed {
        renamed_uop_t uop;
        logic [XLEN-1:0] src1,src2,src3;
    } operand_t;
    typedef struct packed { capture_owner_t uop; } capture_metadata_t;
    request_owner_t request_q[SOURCES][REQUEST_SLOTS],request_d[SOURCES][REQUEST_SLOTS];
    logic inflight_q[SOURCES][REQUEST_SLOTS],inflight_d[SOURCES][REQUEST_SLOTS];
    logic [SLOT_W-1:0] candidate_slot[SOURCES],free_slot[SOURCES];
    capture_metadata_t operand_q[SOURCES][CAPTURE_SLOTS],operand_d[SOURCES][CAPTURE_SLOTS];
    localparam int CAP_SLOT_W=$clog2(CAPTURE_SLOTS);
    localparam int CAP_COUNT_W=$clog2(CAPTURE_SLOTS+1);
    logic [CAP_SLOT_W-1:0] capture_order_q[SOURCES][CAPTURE_SLOTS],capture_order_d[SOURCES][CAPTURE_SLOTS];
    logic [CAP_COUNT_W-1:0] capture_count_q[SOURCES],capture_count_d[SOURCES];
    logic [SOURCES-1:0] capture_credit;
    ranked_packet_t rank_q[2],rank_d[2],rank_live[2],rank_offer;
    read_packet_t read_q[2],read_d[2],read_live[2],allocation;
    logic [SOURCES-1:0] request_ready,rank_take,eligible,selected;
    logic read_space,read_push,rank_ack;
    renamed_uop_t candidate_payload[SOURCES],read_payload[SOURCES];
    operand_t captured_payload[SOURCES],capture_write[SOURCES];
    logic [CAP_SLOT_W-1:0] capture_write_slot[SOURCES];
    // Mutable ownership/branch metadata stays in FFs. Wide immutable payload
    // has one writer per FU source and dedicated candidate/read or head reads.
    for(genvar src=0;src<SOURCES;src++) begin : g_payload_ram
        (* ram_style="distributed" *) logic [$bits(renamed_uop_t)-1:0] request_mem[REQUEST_SLOTS];
        (* ram_style="distributed" *) logic [$bits(operand_t)-1:0] capture_mem[CAPTURE_SLOTS];
        always_ff @(posedge clk) begin
            if(!rst && !flush_i) begin
                if(request_take_o[src]) request_mem[free_slot[src]]<=request_uop_i[src];
                if(read_grant_o[src]) capture_mem[capture_write_slot[src]]<=capture_write[src];
            end
        end
        assign candidate_payload[src]=request_mem[candidate_slot[src]];
        assign read_payload[src]=request_mem[read_q[0].slot[src]];
        assign captured_payload[src]=capture_mem[capture_order_q[src][0]];
    end

    initial begin
        if(FP_READ_SETS<1 || FP_READ_SETS>2 || FP_PORTS!=FP_STORE_BASE+P)
            $error("operand_read_pipeline requires one/two FP read sets and independent MEM store ports");
    end
    function automatic request_owner_t request_owner(input renamed_uop_t u);
        request_owner_t result;
        result.valid=u.valid;result.instruction_id=u.instruction_id;result.rob_idx=u.rob_idx;
        result.branch_mask=u.branch_mask;result.lo_mask=u.mdu_fuse.lo_tag.br_mask;
        return result;
    endfunction
    function automatic capture_owner_t capture_owner(input renamed_uop_t u);
        capture_owner_t result;
        result.valid=u.valid;result.branch_mask=u.branch_mask;
        result.lo_mask=u.mdu_fuse.lo_tag.br_mask;
        return result;
    endfunction
    function automatic rank_descriptor_t descriptor(input renamed_uop_t u);
        rank_descriptor_t result;
        result.valid=u.valid;result.instruction_id=u.instruction_id;result.branch_mask=u.branch_mask;
        result.rs1_read_en=u.rs1_read_en;result.rs2_read_en=u.rs2_read_en;
        result.use_imm=u.use_imm;result.src1_preg=u.src1_preg;result.src2_preg=u.src2_preg;
        result.rs1_dom=u.ext.rs1_dom;result.rs2_dom=u.ext.rs2_dom;result.src3_preg=u.rext.src3_preg;
        return result;
    endfunction
    function automatic request_owner_t resolved_request(input request_owner_t u);
        request_owner_t result;
        result=u;result.branch_mask=br_resolved_mask(u.branch_mask,resolution_i);
        result.lo_mask=br_resolved_mask(u.lo_mask,resolution_i);
        result.valid=u.valid && !br_killed(u.branch_mask,resolution_i);
        return result;
    endfunction
    function automatic rank_descriptor_t resolved_rank(input rank_descriptor_t u);
        rank_descriptor_t result;
        result=u;result.branch_mask=br_resolved_mask(u.branch_mask,resolution_i);
        result.valid=u.valid && !br_killed(u.branch_mask,resolution_i);
        return result;
    endfunction
    function automatic read_owner_t resolved_read(input read_owner_t u);
        read_owner_t result;
        result=u;result.branch_mask=br_resolved_mask(u.branch_mask,resolution_i);
        result.valid=u.valid && !br_killed(u.branch_mask,resolution_i);
        return result;
    endfunction
    function automatic capture_owner_t resolved_capture(input capture_owner_t u);
        capture_owner_t result;
        result=u;result.branch_mask=br_resolved_mask(u.branch_mask,resolution_i);
        result.lo_mask=br_resolved_mask(u.lo_mask,resolution_i);
        result.valid=u.valid && !br_killed(u.branch_mask,resolution_i);
        return result;
    endfunction
    function automatic logic any_live(input read_owner_t [SOURCES-1:0] u);
        logic live;
        live=0;
        for(int src=0;src<SOURCES;src++) live|=u[src].valid;
        return live;
    endfunction
    function automatic logic [ROB_W-1:0] age(input logic [ROB_W-1:0] idx);
        logic [ROB_W:0] distance;
        distance=idx>=rob_head_i ? {1'b0,idx}-{1'b0,rob_head_i} :
            {1'b0,idx}+(ROB_W+1)'(CFG.rob.entries)-{1'b0,rob_head_i};
        return ROB_W'(distance);
    endfunction

    // Registered local tails isolate both feedback paths. No downstream grant,
    // readiness, ordering-event or kill-derived fast credit feeds these capacities.
    assign rank_ack=!rst && !flush_i && !issue_block_i;
    assign read_space=!any_live(read_q[1].uop);
    for(genvar src=0;src<SOURCES;src++) begin : g_request
        // Stable slot identities survive two scheduling stages. Denied candidates
        // clear only their in-flight bit; no candidate packet blocks another FU.
        always_comb begin
            logic found_free,found_candidate;
            logic [ROB_W-1:0] oldest;
            found_free=0;found_candidate=0;oldest='1;
            free_slot[src]='0;candidate_slot[src]='0;
            for(int slot=0;slot<REQUEST_SLOTS;slot++) begin
                request_owner_t u;
                u=resolved_request(request_q[src][slot]);
                if(!found_free && !request_q[src][slot].valid) begin
                    found_free=1;free_slot[src]=SLOT_W'(slot);
                end
                if(u.valid && !inflight_q[src][slot] && (!found_candidate || age(u.rob_idx)<oldest)) begin
                    found_candidate=1;candidate_slot[src]=SLOT_W'(slot);
                    oldest=age(u.rob_idx);
                end
            end
            request_ready[src]=found_free && !rst && !flush_i;
        end
        // Keep physical index selection independent of the RAM payload return.
        // The memory output cannot feed its own address process in event-driven
        // elaboration; this split adds no register or changes any handshake.
        always_comb begin
            pending_uop_o[src]=candidate_payload[src];
            pending_uop_o[src].valid=request_q[src][candidate_slot[src]].valid &&
                !inflight_q[src][candidate_slot[src]] &&
                !br_killed(request_q[src][candidate_slot[src]].branch_mask,resolution_i);
            pending_uop_o[src].branch_mask=br_resolved_mask(request_q[src][candidate_slot[src]].branch_mask,resolution_i);
            pending_uop_o[src].mdu_fuse.lo_tag.br_mask=br_resolved_mask(request_q[src][candidate_slot[src]].lo_mask,resolution_i);
        end
        assign request_take_o[src]=request_valid_i[src] && request_ready[src] && !issue_block_i;
        assign eligible[src]=pending_uop_o[src].valid && pending_eligible_i[src] &&
            !rst && !flush_i && !issue_block_i;
        assign rank_take[src]=eligible[src];
        always_comb begin
            read_uop_o[src]=read_payload[src];
            read_uop_o[src].branch_mask=br_resolved_mask(request_q[src][read_q[0].slot[src]].branch_mask,resolution_i);
            read_uop_o[src].mdu_fuse.lo_tag.br_mask=br_resolved_mask(request_q[src][read_q[0].slot[src]].lo_mask,resolution_i);
            read_uop_o[src].valid=read_live[0].uop[src].valid && request_q[src][read_q[0].slot[src]].valid &&
                !br_killed(request_q[src][read_q[0].slot[src]].branch_mask,resolution_i);
        end
        assign read_grant_o[src]=read_uop_o[src].valid && read_eligible_i[src] &&
            capture_count_q[src]<CAP_COUNT_W'(CAPTURE_SLOTS) && !rst && !flush_i && !issue_block_i;
        assign src1_port_o[src]=read_q[0].port1[src];
        assign src2_port_o[src]=read_q[0].port2[src];
        always_comb begin
            operand_uop_o[src]=captured_payload[src].uop;
            operand_uop_o[src].valid=operand_q[src][capture_order_q[src][0]].uop.valid &&
                !br_killed(operand_q[src][capture_order_q[src][0]].uop.branch_mask,resolution_i);
            operand_uop_o[src].branch_mask=br_resolved_mask(operand_q[src][capture_order_q[src][0]].uop.branch_mask,resolution_i);
            operand_uop_o[src].mdu_fuse.lo_tag.br_mask=br_resolved_mask(operand_q[src][capture_order_q[src][0]].uop.lo_mask,resolution_i);
        end
        assign operand_grant_o[src]=capture_count_q[src]!=0 && operand_uop_o[src].valid && operand_ready_i[src] &&
            !rst && !flush_i && !issue_block_i;
        assign operand_src1_o[src]=captured_payload[src].src1;
        assign operand_src2_o[src]=captured_payload[src].src2;
        assign operand_src3_o[src]=captured_payload[src].src3;
        always_comb begin
            logic [2:0] free_count,reserved_count;
            free_count='0;reserved_count='0;
            for(int slot=0;slot<CAPTURE_SLOTS;slot++) free_count+=3'(!operand_q[src][slot].uop.valid);
            for(int slot=0;slot<2;slot++) reserved_count+=3'(read_q[slot].uop[src].valid);
            capture_credit[src]=free_count>reserved_count;
        end
    end
    for(genvar fu=0;fu<FP_SOURCES;fu++) assign fp_base_o[fu]=read_q[0].fp_base[fu];
    for(genvar port=0;port<INT_PORTS;port++) assign int_addr_o[port]=read_q[0].int_addr[port];
    for(genvar port=0;port<FP_PORTS;port++) assign fp_addr_o[port]=read_q[0].fp_addr[port];

    // A0 -> A1: parallel age comparison and balanced rank counting, independent
    // of read-port budgeting. Snapshot ranks remain valid relative to survivors.
    always_comb begin
        logic [ROB_W-1:0] ages[SOURCES];
        logic [RANK_W-1:0] tree[SOURCES][2*LEAVES];
        rank_offer='0;tree='{default:'{default:'0}};
        for(int src=0;src<SOURCES;src++) ages[src]=age(pending_uop_o[src].rob_idx);
        for(int src=0;src<SOURCES;src++) begin
            if(eligible[src]) rank_offer.uop[src]=descriptor(pending_uop_o[src]);
            rank_offer.slot[src]=candidate_slot[src];
            for(int other=0;other<SOURCES;other++)
                tree[src][LEAVES+other]=RANK_W'(eligible[other] &&
                    (ages[other]<ages[src] || (ages[other]==ages[src] && other<src)));
            for(int node=LEAVES-1;node>0;node--)
                tree[src][node]=tree[src][2*node]+tree[src][2*node+1];
            rank_offer.rank[src]=tree[src][1];
        end
    end

    // A1 -> A2: compose bounded resource-budget functions in a balanced tree.
    // This is a combinational parallel prefix, not a sequential state machine.
    // It implements oldest-first atomic skip-and-continue without a serial chain
    // across every candidate. No actual-data/FU readiness enters allocation.
    always_comb begin
        logic [SOURCES-1:0] at_rank[SOURCES];
        logic first[SOURCES],second[SOURCES],native_fp[SOURCES];
        logic [1:0] demand[SOURCES];
        logic [PREG_IDX_WIDTH-1:0] addr1[SOURCES],addr2[SOURCES],addr3[SOURCES];
        logic [BUDGET_W-1:0] prefix_map[2*LEAVES][BUDGETS];
        logic [BUDGET_W-1:0] prefix_in[2*LEAVES];
        at_rank='{default:'0};first='{default:0};second='{default:0};native_fp='{default:0};
        demand='{default:'0};addr1='{default:'0};addr2='{default:'0};addr3='{default:'0};
        prefix_map='{default:'{default:'0}};prefix_in='{default:'0};
        selected='0;allocation='0;
        for(int rank=0;rank<SOURCES;rank++) begin
            for(int src=0;src<SOURCES;src++) begin
                logic need1,need2;
                at_rank[rank][src]=rank_live[0].uop[src].valid && capture_credit[src] &&
                    rank_q[0].rank[src]==RANK_W'(rank);
                need1=rank_live[0].uop[src].rs1_read_en;
                need2=rank_live[0].uop[src].rs2_read_en;
                if(src<INT_SOURCES) need2 &= !rank_live[0].uop[src].use_imm;
                else if(src<BR_SLOT) need2 &= rank_live[0].uop[src].rs2_dom!=o3_types_pkg::RD_FP;
                else if(src>=FP_BASE) begin
                    need1 &= rank_live[0].uop[src].rs1_dom==o3_types_pkg::RD_INT;
                    need2=0;
                end
                first[rank]|=at_rank[rank][src] && need1;
                second[rank]|=at_rank[rank][src] && need2;
                native_fp[rank]|=at_rank[rank][src] && src>=FP_BASE;
                addr1[rank]|=rank_live[0].uop[src].src1_preg & {PREG_IDX_WIDTH{at_rank[rank][src]}};
                addr2[rank]|=rank_live[0].uop[src].src2_preg & {PREG_IDX_WIDTH{at_rank[rank][src]}};
                addr3[rank]|=rank_live[0].uop[src].src3_preg & {PREG_IDX_WIDTH{at_rank[rank][src]}};
            end
            demand[rank]=2'(first[rank])+2'(second[rank]);
        end
        // Each leaf maps every possible bounded occupancy to its next occupancy.
        for(int leaf=0;leaf<LEAVES;leaf++) for(int budget=0;budget<BUDGETS;budget++) begin
            prefix_map[LEAVES+leaf][budget]=BUDGET_W'(budget);
            if(leaf<SOURCES) begin
                if((budget/FP_BUDGETS)+int'(demand[leaf])<=INT_PORTS &&
                   (budget%FP_BUDGETS)+int'(native_fp[leaf])<=FP_READ_SETS)
                    prefix_map[LEAVES+leaf][budget]=BUDGET_W'(budget+
                        int'(demand[leaf])*FP_BUDGETS+int'(native_fp[leaf]));
            end
        end
        for(int node=LEAVES-1;node>0;node--) for(int budget=0;budget<BUDGETS;budget++)
            prefix_map[node][budget]=prefix_map[2*node+1][prefix_map[2*node][budget]];
        for(int node=1;node<LEAVES;node++) begin
            prefix_in[2*node]=prefix_in[node];
            prefix_in[2*node+1]=prefix_map[2*node][prefix_in[node]];
        end
        for(int rank=0;rank<SOURCES;rank++) begin
            logic [COUNT_W-1:0] int_used;
            logic [1:0] fp_used;
            int_used=COUNT_W'(int'(prefix_in[LEAVES+rank])/FP_BUDGETS);
            fp_used=2'(int'(prefix_in[LEAVES+rank])%FP_BUDGETS);
            if(read_space && !rst && !flush_i && !issue_block_i &&
               int_used+COUNT_W'(demand[rank])<=COUNT_W'(INT_PORTS) &&
               (!native_fp[rank] || fp_used<2'(FP_READ_SETS))) begin
                selected|=at_rank[rank];
                for(int src=0;src<SOURCES;src++) if(at_rank[rank][src]) begin
                    allocation.uop[src].valid=rank_live[0].uop[src].valid;
                    allocation.uop[src].instruction_id=rank_live[0].uop[src].instruction_id;
                    allocation.uop[src].branch_mask=rank_live[0].uop[src].branch_mask;
                    allocation.slot[src]=rank_q[0].slot[src];
                    if(first[rank]) allocation.port1[src]=PORT_W'(int_used);
                    if(second[rank]) allocation.port2[src]=PORT_W'(int_used+COUNT_W'(first[rank]));
                    if(src>=FP_BASE) allocation.fp_base[src-FP_BASE]=3'(fp_used*3);
                end
                if(first[rank]) allocation.int_addr[int_used]=addr1[rank];
                if(second[rank]) allocation.int_addr[int_used+COUNT_W'(first[rank])]=addr2[rank];
                if(native_fp[rank]) begin
                    allocation.fp_addr[fp_used*3]=addr1[rank];
                    allocation.fp_addr[fp_used*3+1]=addr2[rank];
                    allocation.fp_addr[fp_used*3+2]=addr3[rank];
                end
            end
        end
        for(int p=0;p<P;p++) if(selected[MEM_BASE+p])
            allocation.fp_addr[FP_STORE_BASE+p]=rank_live[0].uop[MEM_BASE+p].src2_preg;
        read_push=|selected;
    end

    // Cancellation touches every in-flight owner. It never grants a writeback or
    // marks a ROB entry complete; those events remain in the actual WB path.
    always_comb begin
        for(int slot=0;slot<2;slot++) begin
            rank_live[slot]=rank_q[slot];read_live[slot]=read_q[slot];
            for(int src=0;src<SOURCES;src++) begin
                rank_live[slot].uop[src]=resolved_rank(rank_q[slot].uop[src]);
                read_live[slot].uop[src]=resolved_read(read_q[slot].uop[src]);
            end
        end
    end
    always_comb begin
        rank_d=rank_live;read_d=read_live;
        for(int src=0;src<SOURCES;src++) begin
            if(read_grant_o[src]) read_d[0].uop[src].valid=0;
        end
        if(!any_live(read_d[0].uop)) begin read_d[0]=read_d[1];read_d[1]='0;end
        // Every examined owner is acknowledged, even if it has no read credit.
        // Denial leaves its A0 reservation live for a later scheduling attempt.
        if(rank_ack) begin rank_d[0]=rank_offer;rank_d[1]='0;end
        if(read_push) begin
            if(any_live(read_d[0].uop)) read_d[1]=allocation;
            else read_d[0]=allocation;
        end
    end
    always_comb begin
        for(int src=0;src<SOURCES;src++) begin
            for(int slot=0;slot<REQUEST_SLOTS;slot++) begin
                request_d[src][slot]=resolved_request(request_q[src][slot]);
                inflight_d[src][slot]=inflight_q[src][slot];
            end
            if(rank_ack && rank_live[0].uop[src].valid) begin
                if(!selected[src]) inflight_d[src][rank_q[0].slot[src]]=0;
            end
            if(read_grant_o[src]) begin
                request_d[src][read_q[0].slot[src]].valid=0;
                inflight_d[src][read_q[0].slot[src]]=0;
            end
            if(rank_take[src]) inflight_d[src][candidate_slot[src]]=1;
            if(request_take_o[src]) begin
                request_d[src][free_slot[src]]=resolved_request(request_owner(request_uop_i[src]));
                request_d[src][free_slot[src]].lo_mask=br_resolved_mask(request_uop_i[src].mdu_fuse.lo_tag.br_mask,resolution_i);
                request_d[src][free_slot[src]].valid=request_uop_i[src].valid &&
                    !br_killed(request_uop_i[src].branch_mask,resolution_i);
                inflight_d[src][free_slot[src]]=0;
            end
        end
    end
    // Capture payloads remain in physical slots. Only three narrow order indices
    // compact on delivery/cancellation; FU backpressure cannot move wide data.
    always_comb begin
        for(int src=0;src<SOURCES;src++) begin
            int kept,append_slot;
            logic found_free;
            kept=0;append_slot=0;found_free=0;operand_d[src]=operand_q[src];
            capture_write[src]='0;capture_write_slot[src]='0;
            capture_order_d[src]='{default:'0};
            for(int slot=0;slot<CAPTURE_SLOTS;slot++) begin
                operand_d[src][slot].uop=resolved_capture(operand_q[src][slot].uop);
                if(!operand_q[src][slot].uop.valid && !found_free) begin
                    found_free=1;append_slot=slot;
                end
            end
            for(int pos=0;pos<CAPTURE_SLOTS;pos++) begin
                int slot;
                slot=int'(capture_order_q[src][pos]);
                if(pos<int'(capture_count_q[src])) begin
                    if(operand_q[src][slot].uop.valid &&
                       !br_killed(operand_q[src][slot].uop.branch_mask,resolution_i) &&
                       !(pos==0 && operand_grant_o[src])) begin
                        capture_order_d[src][kept]=CAP_SLOT_W'(slot);kept++;
                    end else operand_d[src][slot].uop.valid=0;
                end
            end
            if(read_grant_o[src]) begin
                capture_order_d[src][kept]=CAP_SLOT_W'(append_slot);kept++;
                capture_write_slot[src]=CAP_SLOT_W'(append_slot);
                capture_write[src].uop=read_uop_o[src];
                operand_d[src][append_slot].uop=capture_owner(read_uop_o[src]);
                operand_d[src][append_slot].uop.lo_mask=read_uop_o[src].mdu_fuse.lo_tag.br_mask;
                capture_write[src].src1=read_uop_o[src].rs1_read_en ?
                    int_data_i[src1_port_o[src]]:'0;
                capture_write[src].src2=read_uop_o[src].rs2_read_en ?
                    int_data_i[src2_port_o[src]]:'0;
                capture_write[src].src3='0;
                if(src>=MEM_BASE && src<BR_SLOT && read_uop_o[src].ext.rs2_dom==o3_types_pkg::RD_FP)
                    capture_write[src].src2=read_uop_o[src].rs2_read_en ?
                        fp_data_i[FP_STORE_BASE+src-MEM_BASE]:'0;
                if(src>=FP_BASE) begin
                    if(read_uop_o[src].ext.rs1_dom!=o3_types_pkg::RD_INT)
                        capture_write[src].src1=read_uop_o[src].rs1_read_en ?
                            fp_data_i[read_q[0].fp_base[src-FP_BASE]]:'0;
                    capture_write[src].src2=read_uop_o[src].rs2_read_en ?
                        fp_data_i[read_q[0].fp_base[src-FP_BASE]+1]:'0;
                    capture_write[src].src3=read_uop_o[src].ext.rs3_read_en ?
                        fp_data_i[read_q[0].fp_base[src-FP_BASE]+2]:'0;
                end
            end
            capture_count_d[src]=CAP_COUNT_W'(kept);
        end
    end
    always_ff @(posedge clk) begin
        if(rst || flush_i) begin
            // Invalid payloads need no reset; only live-owner bits are cleared.
            for(int slot=0;slot<2;slot++) for(int src=0;src<SOURCES;src++) begin
                rank_q[slot].uop[src].valid<=0;read_q[slot].uop[src].valid<=0;
            end
            for(int src=0;src<SOURCES;src++) begin
                for(int slot=0;slot<REQUEST_SLOTS;slot++) begin
                    request_q[src][slot].valid<=0;inflight_q[src][slot]<=0;
                end
                for(int slot=0;slot<CAPTURE_SLOTS;slot++) operand_q[src][slot].uop.valid<=0;
                capture_count_q[src]<=0;capture_order_q[src]<='{default:'0};
            end
        end else begin
            rank_q<=rank_d;read_q<=read_d;request_q<=request_d;inflight_q<=inflight_d;operand_q<=operand_d;
            capture_count_q<=capture_count_d;capture_order_q<=capture_order_d;
            for(int src=0;src<SOURCES;src++) begin
                int occupied,captured;
                occupied=0;captured=0;
                for(int slot=0;slot<CAPTURE_SLOTS;slot++) captured+=int'(operand_q[src][slot].uop.valid);
                occupied=captured;
                for(int slot=0;slot<2;slot++) occupied+=int'(read_q[slot].uop[src].valid);
                assert(captured==int'(capture_count_q[src])) else $fatal(1,"operand capture ownership/count mismatch");
                assert(int'(capture_count_q[src])<=CAPTURE_SLOTS) else $fatal(1,"operand capture count overflow");
                assert(occupied<=CAPTURE_SLOTS) else $fatal(1,"operand capture credit overcommit");
                if(read_live[0].uop[src].valid)
                    assert(request_q[src][read_q[0].slot[src]].valid && inflight_q[src][read_q[0].slot[src]] &&
                           request_q[src][read_q[0].slot[src]].instruction_id==read_q[0].uop[src].instruction_id)
                        else $fatal(1,"operand read lost its metadata owner");
                if(rank_ack && rank_live[0].uop[src].valid)
                    assert(request_q[src][rank_q[0].slot[src]].valid && inflight_q[src][rank_q[0].slot[src]] &&
                           request_q[src][rank_q[0].slot[src]].instruction_id==rank_q[0].uop[src].instruction_id)
                        else $fatal(1,"operand scheduler lost candidate reservation");
            end
        end
    end
endmodule
