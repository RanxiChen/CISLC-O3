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

    always_comb begin
        logic [NUM_PHYS_REGS-1:0] candidate_bitmap;
        int unsigned request_count;
        int unsigned selected_count;

        candidate_bitmap = free_bitmap_q;
        request_count = 0;
        selected_count = 0;
        alloc_preg_o = '{default: '0};

        for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
            int chosen_preg;
            chosen_preg = -1;
            if (alloc_req_i[lane]) begin
                request_count++;
                for (int preg = int'(HAS_ZERO_REG); preg < NUM_PHYS_REGS; preg++) begin
                    if ((chosen_preg < 0) && candidate_bitmap[preg]) begin
                        chosen_preg = preg;
                    end
                end
                if (chosen_preg >= 0) begin
                    alloc_preg_o[lane] = PREG_IDX_WIDTH'(chosen_preg);
                    candidate_bitmap[chosen_preg] = 1'b0;
                    selected_count++;
                end
            end
        end

        candidate_bitmap_after_alloc = candidate_bitmap;
        alloc_available_o = (selected_count == request_count);

        free_count_o = '0;
        for (int preg = int'(HAS_ZERO_REG); preg < NUM_PHYS_REGS; preg++) begin
            if (free_bitmap_q[preg]) begin
                free_count_o = free_count_o + COUNT_WIDTH'(1);
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            free_bitmap_q <= '0;
            for (int preg = NUM_ARCH_REGS; preg < NUM_PHYS_REGS; preg++) begin
                free_bitmap_q[preg] <= 1'b1;
            end
            allocation_mask_q <= '{default: '0};
            committed_free_q <= {NUM_PHYS_REGS{1'b1}} << NUM_ARCH_REGS;
        end else begin
            logic [NUM_PHYS_REGS-1:0] free_next;
            logic [NUM_PHYS_REGS-1:0] allocation_next [NUM_CHECKPOINTS-1:0];

            logic [NUM_PHYS_REGS-1:0] committed_next;
            committed_next=committed_free_q;
            for (int lane=0;lane<RELEASE_WIDTH;lane++) if (commit_write_i[lane]) begin
                committed_next[release_preg_i[lane]]=1;
                committed_next[commit_new_preg_i[lane]]=0;
            end
            if (HAS_ZERO_REG) committed_next[0]=0;
            committed_free_q<=committed_next;
            free_next = free_bitmap_q;
            allocation_next = allocation_mask_q;

            for (int port = 0; port < RELEASE_WIDTH; port++) begin
                if (release_valid_i[port]
                 && (!HAS_ZERO_REG || release_preg_i[port] != '0)
                 && (release_preg_i[port] < PREG_IDX_WIDTH'(NUM_PHYS_REGS))) begin
                    free_next[release_preg_i[port]] = 1'b1;
                end
            end

            if (resolution_valid_i && resolution_mispredict_i) begin
                free_next |= allocation_mask_q[resolution_tag_i];
            end else if (alloc_fire_i) begin
                free_next = candidate_bitmap_after_alloc;

                // 候选位图从拍初状态产生，因此需要重新合入本拍commit释放。
                for (int port = 0; port < RELEASE_WIDTH; port++) begin
                    if (release_valid_i[port]
                     && (!HAS_ZERO_REG || release_preg_i[port] != '0)
                     && (release_preg_i[port] < PREG_IDX_WIDTH'(NUM_PHYS_REGS))) begin
                        free_next[release_preg_i[port]] = 1'b1;
                    end
                end

                for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
                    if (checkpoint_create_i[lane]) begin
                        allocation_next[checkpoint_create_tag_i[lane]] = '0;
                    end
                end

                for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
                    if (alloc_req_i[lane]) begin
                        for (int cp = 0; cp < NUM_CHECKPOINTS; cp++) begin
                            if (alloc_branch_mask_i[lane][cp]) begin
                                allocation_next[cp][alloc_preg_o[lane]] = 1'b1;
                            end
                        end
                    end
                end
            end

            if (resolution_valid_i) begin
                allocation_next[resolution_tag_i] = '0;
            end

            if (flush_all_i) begin free_next=committed_next; allocation_next='{default:'0}; end
            free_bitmap_q <= free_next;
            allocation_mask_q <= allocation_next;
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
