/**
 * Per-domain physical free-list and recovery allocation masks (B02/B15).
 * INT skips p0; FP includes p0 in allocation/count/release. Initial f0..f31 map to
 * fp0..fp31, with remaining physical registers free. Shared branch checkpoint tags
 * record all younger allocations in both domains. Global flush restores committed
 * free state including actual same-boundary retirement; mispredict returns dependent allocations.
 * 当前实现状态：闭环简化（L9）；lint/测试未运行。
 * Cached lowest candidates and exact capacity are registered with the ownership bitmap.
 * N: choose distinct free candidates for the accepted rename prefix. N edge: consume
 * allocations, return retired old mappings and record/recover checkpoint masks.
 * N+1: free count/candidate bitmap reflects the new or restored state.
 */
module free_list
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    parameter  o3_types_pkg::reg_domain_e DOMAIN,     // RD_INT / RD_FP，无默认值
    localparam int MACHINE_WIDTH = BACKEND_MACHINE_WIDTH,
    localparam int NUM_PHYS_REGS = (DOMAIN == o3_types_pkg::RD_FP) ? CFG.rename.fp_phys_regs
                                                                   : CFG.rename.int_phys_regs,
    localparam int NUM_ARCH_REGS = o3_isa_pkg::NUM_ARCH_REGS,
    localparam int RELEASE_WIDTH = o3_cfg_pkg::O3_CFG.core.commit_width,
    localparam int NUM_CHECKPOINTS = CFG.rename.checkpoints,
    // 整数域 p0 永久恒零且保留；FP 域没有恒零寄存器，f0 正常可写（B15）。
    localparam bit HAS_ZERO_REG = (DOMAIN == o3_types_pkg::RD_INT)
) (
    input logic flush_all_i,
    input  logic clk,
    input  logic rst,

    input  logic                              alloc_req_i [MACHINE_WIDTH-1:0],
    input  logic                              alloc_fire_i,
    output logic                              alloc_available_o,
    output logic [PREG_IDX_WIDTH-1:0]  alloc_preg_o [MACHINE_WIDTH-1:0],
    output logic [$clog2(NUM_PHYS_REGS+1)-1:0] free_count_o,

    input logic [PREG_IDX_WIDTH-1:0] commit_new_preg_i [RELEASE_WIDTH-1:0],
    input logic commit_write_i [RELEASE_WIDTH-1:0],
    input  logic                              release_valid_i [RELEASE_WIDTH-1:0],
    input  logic [PREG_IDX_WIDTH-1:0]  release_preg_i [RELEASE_WIDTH-1:0],

    input  logic                              checkpoint_create_i [MACHINE_WIDTH-1:0],
    input  branch_tag_t                       checkpoint_create_tag_i [MACHINE_WIDTH-1:0],
    input  branch_mask_t                      alloc_branch_mask_i [MACHINE_WIDTH-1:0],

    input  logic                              resolution_valid_i,
    input  logic                              resolution_mispredict_i,
    input  branch_tag_t                       resolution_tag_i
);

    // preg 字段宽度统一使用 o3_pkg::PREG_IDX_WIDTH（两域共用，o3_types_pkg::PREG_W）。
    localparam int COUNT_WIDTH = $clog2(NUM_PHYS_REGS + 1);

    logic [NUM_PHYS_REGS-1:0] free_bitmap_q;
    logic [NUM_PHYS_REGS-1:0] committed_free_q;
    logic [NUM_PHYS_REGS-1:0] allocation_mask_q [NUM_CHECKPOINTS-1:0];
    logic [NUM_PHYS_REGS-1:0] candidate_bitmap_after_alloc;

    // Exact registered capacity for each 64-register bitmap group. Allocation,
    // release and recovery update both representations at the same edge. The
    // rename admission view no longer starts with a bitmap population count;
    // the balanced next-state count is local to this resource owner. No new
    // admission latency, speculative/free-on-current-release credit or FSM.
    localparam int COUNT_GROUP_SIZE=64;
    localparam int COUNT_GROUPS=(NUM_PHYS_REGS+COUNT_GROUP_SIZE-1)/COUNT_GROUP_SIZE;
    localparam int COUNT_GROUP_W=$clog2(COUNT_GROUP_SIZE+1);
    logic [COUNT_GROUP_W-1:0] group_count_q[COUNT_GROUPS];

    // A balanced gather prepares the next first WIDTH free candidates at the
    // ownership edge. Current sparse requests map onto the registered view by
    // prefix rank; no encoder waits for a preceding lane's destination.
    localparam int LEAVES = 1 << $clog2(NUM_PHYS_REGS);
    localparam int RANK_WIDTH = $clog2(MACHINE_WIDTH+1);
    typedef struct packed {
        logic valid;
        logic [PREG_IDX_WIDTH-1:0] index;
    } candidate_t;
    candidate_t candidate_q[MACHINE_WIDTH];
    // Current candidates are an exact cached view of the registered bitmap,
    // prepared at the same ownership edge. Sparse request routing no longer
    // traverses the bitmap gather during the rename admission/consume cycle.
    always_comb begin
        candidate_t winner[MACHINE_WIDTH];
        logic [RANK_WIDTH-1:0] request_count;
        winner='{default:'0};
        request_count='0;
        alloc_preg_o='{default:'0};
        for(int lane=0;lane<MACHINE_WIDTH;lane++) begin
            for(int rank=0;rank<MACHINE_WIDTH;rank++)
                if(alloc_req_i[lane] && request_count==RANK_WIDTH'(rank))
                    winner[lane]=candidate_q[rank];
            if(winner[lane].valid) alloc_preg_o[lane]=winner[lane].index;
            request_count+=RANK_WIDTH'(alloc_req_i[lane]);
        end
        for(int preg=0;preg<NUM_PHYS_REGS;preg++) begin
            logic taken;
            taken=0;
            // Every sparse lane mask consumes the first N sorted identities.
            // Decode the registered identities in parallel with request counting,
            // instead of decoding request-routed destinations afterwards.
            for(int rank=0;rank<MACHINE_WIDTH;rank++)
                taken |= candidate_q[rank].valid && candidate_q[rank].index==PREG_IDX_WIDTH'(preg)
                    && request_count>RANK_WIDTH'(rank);
            candidate_bitmap_after_alloc[preg]=free_bitmap_q[preg] && !taken;
        end
        alloc_available_o=free_count_o>=COUNT_WIDTH'(request_count);
    end

    // Capacity depends only on registered ownership state. Keep its process
    // independent of request encoding so tools cannot infer a spurious
    // request -> capacity -> rename-admission -> request combinational loop.
    always_comb begin
        free_count_o='0;
        for(int group=0;group<COUNT_GROUPS;group++)
            free_count_o+=COUNT_WIDTH'(group_count_q[group]);
    end

    // Shared one-hot destination decode. Checkpoint rows reuse these wires
    // instead of repeating the preg equality comparison for every branch tag.
    logic [NUM_PHYS_REGS-1:0] alloc_dest_mask [MACHINE_WIDTH];
    always_comb begin
        for (int lane=0;lane<MACHINE_WIDTH;lane++)
            for (int preg=0;preg<NUM_PHYS_REGS;preg++)
                alloc_dest_mask[lane][preg]=alloc_req_i[lane]
                    && alloc_preg_o[lane]==PREG_IDX_WIDTH'(preg);
    end

    // One state update per checkpoint bit. Creation clears the old row before
    // dependent allocations; correct/mispredict resolution clears the row last.
    for (genvar cp=0;cp<NUM_CHECKPOINTS;cp++) begin : g_checkpoint
        logic created;
        always_comb begin
            created=0;
            for (int lane=0;lane<MACHINE_WIDTH;lane++)
                created |= checkpoint_create_i[lane] && checkpoint_create_tag_i[lane]==branch_tag_t'(cp);
        end
        for (genvar preg=0;preg<NUM_PHYS_REGS;preg++) begin : g_preg
            logic allocated;
            always_comb begin
                allocated=0;
                for (int lane=0;lane<MACHINE_WIDTH;lane++)
                    allocated |= alloc_dest_mask[lane][preg] && alloc_branch_mask_i[lane][cp];
            end
            always_ff @(posedge clk) begin
                if (rst || flush_all_i || (resolution_valid_i && resolution_tag_i==branch_tag_t'(cp)))
                    allocation_mask_q[cp][preg]<=0;
                else if (!(resolution_valid_i && resolution_mispredict_i) && alloc_fire_i) begin
                    if (allocated) allocation_mask_q[cp][preg]<=1;
                    else if (created) allocation_mask_q[cp][preg]<=0;
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            free_bitmap_q <= '0;
            for (int preg = NUM_ARCH_REGS; preg < NUM_PHYS_REGS; preg++) begin
                free_bitmap_q[preg] <= 1'b1;
            end
            for(int rank=0;rank<MACHINE_WIDTH;rank++) begin
                candidate_q[rank].valid <= NUM_ARCH_REGS+rank<NUM_PHYS_REGS;
                candidate_q[rank].index <= NUM_ARCH_REGS+rank<NUM_PHYS_REGS ?
                    PREG_IDX_WIDTH'(NUM_ARCH_REGS+rank):'0;
            end
            committed_free_q <= {NUM_PHYS_REGS{1'b1}} << NUM_ARCH_REGS;
            for(int group=0;group<COUNT_GROUPS;group++) begin
                logic [COUNT_GROUP_W-1:0] count;
                count='0;
                for(int bit_idx=0;bit_idx<COUNT_GROUP_SIZE;bit_idx++)
                    count+=COUNT_GROUP_W'(group*COUNT_GROUP_SIZE+bit_idx>=NUM_ARCH_REGS &&
                        group*COUNT_GROUP_SIZE+bit_idx<NUM_PHYS_REGS);
                group_count_q[group]<=count;
            end
        end else begin
            logic [NUM_PHYS_REGS-1:0] free_next;

            logic [NUM_PHYS_REGS-1:0] committed_next, released_bitmap;
            committed_next=committed_free_q;
            released_bitmap='0;
            // Retain the original packed-bit commit updates verbatim. These
            // inputs have shared INT/FP preg width, including out-of-range
            // encodings; the rewrite must not change their legacy behavior.
            for (int lane=0;lane<RELEASE_WIDTH;lane++) if (commit_write_i[lane]) begin
                committed_next[release_preg_i[lane]]=1;
                committed_next[commit_new_preg_i[lane]]=0;
            end
            for (int preg=0;preg<NUM_PHYS_REGS;preg++)
                for (int lane=0;lane<RELEASE_WIDTH;lane++)
                    released_bitmap[preg] |= release_valid_i[lane]
                        && (!HAS_ZERO_REG || release_preg_i[lane]!='0)
                        // The exclusive upper bound needs one more bit than
                        // an address at power-of-two depths (64 must not become 0).
                        && (int'(release_preg_i[lane])<NUM_PHYS_REGS)
                        && release_preg_i[lane]==PREG_IDX_WIDTH'(preg);
            if (HAS_ZERO_REG) committed_next[0]=0;
            committed_free_q<=committed_next;
            free_next = free_bitmap_q;
            if (resolution_valid_i && resolution_mispredict_i)
                free_next |= allocation_mask_q[resolution_tag_i];
            else if (alloc_fire_i)
                free_next = candidate_bitmap_after_alloc;
            free_next |= released_bitmap;

            if (flush_all_i) free_next=committed_next;
            free_bitmap_q <= free_next;
            // Prepare the next candidate view from the exact next bitmap,
            // including same-edge release, branch recovery and committed flush.
            // Current allocators cannot borrow any of these returns before this
            // edge. No extra public allocation cycle, capacity or FSM is added.
            begin
                logic [COUNT_WIDTH-1:0] count_tree[2*LEAVES];
                candidate_t tree[2*LEAVES][MACHINE_WIDTH];
                count_tree='{default:'0};
                tree='{default:'{default:'0}};
                for(int preg=int'(HAS_ZERO_REG);preg<NUM_PHYS_REGS;preg++) begin
                    count_tree[LEAVES+preg]=COUNT_WIDTH'(free_next[preg]);
                    tree[LEAVES+preg][0].valid=free_next[preg];
                    tree[LEAVES+preg][0].index=PREG_IDX_WIDTH'(preg);
                end
                for(int node=LEAVES-1;node>0;node--) begin
                    count_tree[node]=count_tree[2*node]+count_tree[2*node+1];
                    for(int rank=0;rank<MACHINE_WIDTH;rank++) begin
                        if(int'(count_tree[2*node])>rank)
                            tree[node][rank]=tree[2*node][rank];
                        else for(int right=0;right<=rank;right++)
                            if(int'(count_tree[2*node])==rank-right)
                                tree[node][rank]=tree[2*node+1][right];
                    end
                end
                for(int rank=0;rank<MACHINE_WIDTH;rank++)
                    candidate_q[rank]<=tree[1][rank];
            end

            for(int group=0;group<COUNT_GROUPS;group++) begin
                logic [COUNT_GROUP_W-1:0] tree[2*COUNT_GROUP_SIZE];
                tree='{default:'0};
                for(int bit_idx=0;bit_idx<COUNT_GROUP_SIZE;bit_idx++)
                    if(group*COUNT_GROUP_SIZE+bit_idx<NUM_PHYS_REGS &&
                        (!HAS_ZERO_REG || group*COUNT_GROUP_SIZE+bit_idx!=0))
                        tree[COUNT_GROUP_SIZE+bit_idx]=COUNT_GROUP_W'(free_next[group*COUNT_GROUP_SIZE+bit_idx]);
                for(int node=COUNT_GROUP_SIZE-1;node>0;node--)
                    tree[node]=tree[2*node]+tree[2*node+1];
                group_count_q[group]<=tree[1];
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) if(!rst) begin
        for(int group=0;group<COUNT_GROUPS;group++) begin
            int expected;
            expected=0;
            for(int bit_idx=0;bit_idx<COUNT_GROUP_SIZE;bit_idx++)
                if(group*COUNT_GROUP_SIZE+bit_idx<NUM_PHYS_REGS &&
                    (!HAS_ZERO_REG || group*COUNT_GROUP_SIZE+bit_idx!=0))
                    expected+=int'(free_bitmap_q[group*COUNT_GROUP_SIZE+bit_idx]);
            assert(int'(group_count_q[group])==expected)
                else $fatal(1,"free-list capacity differs from its ownership bitmap");
        end
    end
`endif

`ifndef SYNTHESIS
    always_ff @(posedge clk) if(!rst) begin
        int rank;
        rank=0;
        for(int preg=int'(HAS_ZERO_REG);preg<NUM_PHYS_REGS;preg++)
            if(free_bitmap_q[preg] && rank<MACHINE_WIDTH) begin
                assert(candidate_q[rank].valid && candidate_q[rank].index==PREG_IDX_WIDTH'(preg))
                    else $fatal(1,"free-list cached candidate differs from ownership bitmap");
                rank++;
            end
        for(int empty=0;empty<MACHINE_WIDTH;empty++)
            if(empty>=rank) assert(!candidate_q[empty].valid)
                else $fatal(1,"free-list cached candidate exceeds ownership bitmap");
    end
`endif

    initial begin
        if (NUM_PHYS_REGS <= NUM_ARCH_REGS) begin
            $error("free_list requires NUM_PHYS_REGS > NUM_ARCH_REGS");
        end
        if (NUM_CHECKPOINTS != BACKEND_NUM_BRANCH_CHECKPOINTS) begin
            $error("free_list checkpoint count must match branch_mask_t width");
        end
    end

endmodule
