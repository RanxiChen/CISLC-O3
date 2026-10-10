/**
 * Per-domain physical free-list and recovery allocation masks (B02/B15).
 * INT skips p0; FP includes p0 in allocation/count/release. Initial f0..f31 map to
 * fp0..fp31, with remaining physical registers free. Shared branch checkpoint tags
 * record all younger allocations in both domains. Global flush restores committed
 * free state including actual same-boundary retirement; mispredict returns dependent allocations.
 * 当前实现状态：闭环简化（L9）；lint/测试未运行。
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

    // Balanced encoders choose the lowest free index. Each lane excludes
    // only earlier accepted candidates; sparse requests keep their lane order.
    // Counting is a separate balanced reduction instead of a serial accumulator.
    localparam int LEAVES = 1 << $clog2(NUM_PHYS_REGS);
    localparam int RANK_WIDTH = $clog2(MACHINE_WIDTH+1);
    typedef struct packed {
        logic valid;
        logic [PREG_IDX_WIDTH-1:0] index;
    } candidate_t;
    always_comb begin
        logic [COUNT_WIDTH-1:0] count_tree [2*LEAVES];
        candidate_t tree [MACHINE_WIDTH][2*LEAVES];
        candidate_t winner [MACHINE_WIDTH];
        logic [RANK_WIDTH-1:0] request_count;
        count_tree = '{default:'0};
        tree = '{default:'{default:'0}};
        winner = '{default:'0};
        request_count = '0;
        alloc_preg_o = '{default:'0};
        for (int preg = int'(HAS_ZERO_REG); preg < NUM_PHYS_REGS; preg++)
            count_tree[LEAVES+preg] = COUNT_WIDTH'(free_bitmap_q[preg]);
        for (int node = LEAVES-1; node > 0; node--)
            count_tree[node] = count_tree[2*node] + count_tree[2*node+1];
        for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
            for (int preg = int'(HAS_ZERO_REG); preg < NUM_PHYS_REGS; preg++) begin
                tree[lane][LEAVES+preg].valid = free_bitmap_q[preg];
                tree[lane][LEAVES+preg].index = PREG_IDX_WIDTH'(preg);
                for (int prior = 0; prior < lane; prior++)
                    if (winner[prior].valid && winner[prior].index == PREG_IDX_WIDTH'(preg))
                        tree[lane][LEAVES+preg].valid = 0;
            end
            for (int node = LEAVES-1; node > 0; node--)
                tree[lane][node] = tree[lane][2*node].valid ? tree[lane][2*node] : tree[lane][2*node+1];
            winner[lane] = tree[lane][1];
            winner[lane].valid &= alloc_req_i[lane];
            if (winner[lane].valid) alloc_preg_o[lane] = winner[lane].index;
            request_count += RANK_WIDTH'(alloc_req_i[lane]);
        end
        for (int preg = 0; preg < NUM_PHYS_REGS; preg++) begin
            logic taken;
            taken = 0;
            for (int lane = 0; lane < MACHINE_WIDTH; lane++)
                taken |= winner[lane].valid && winner[lane].index == PREG_IDX_WIDTH'(preg);
            candidate_bitmap_after_alloc[preg] = free_bitmap_q[preg] && !taken;
        end
        alloc_available_o = count_tree[1] >= COUNT_WIDTH'(request_count);
        free_count_o = count_tree[1];
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
            committed_free_q <= {NUM_PHYS_REGS{1'b1}} << NUM_ARCH_REGS;
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
                        && (release_preg_i[lane]<PREG_IDX_WIDTH'(NUM_PHYS_REGS))
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
        end
    end

    initial begin
        if (NUM_PHYS_REGS <= NUM_ARCH_REGS) begin
            $error("free_list requires NUM_PHYS_REGS > NUM_ARCH_REGS");
        end
        if (NUM_CHECKPOINTS != BACKEND_NUM_BRANCH_CHECKPOINTS) begin
            $error("free_list checkpoint count must match branch_mask_t width");
        end
    end

endmodule
