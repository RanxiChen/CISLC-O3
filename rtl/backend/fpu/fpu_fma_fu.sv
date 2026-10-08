/**
 * Split CVFPU identity and result transport shared by the four L9 wrappers.
 * N: RegRead handshakes once, reserving a free identity slot. Only accepted
 * CVFPU outputs enter the common holding register; the format arbiter need not
 * lock a candidate under backpressure. N edge: capture/update slots; N+1 holds
 * the result until domain writeback accepts it. Recovery marks in-flight slots
 * killed without reusing them. A slot is freed only on final writeback/discard.
 * CVFPU and side tables share system reset; native flush is tied low.
 * FMV has a one-cycle bitwise bypass, round-robin with CVFPU at the holding slot.
 * Cancellation is checked combinationally at every delivery boundary.
 * B33 early wakeup for FP FUs is deferred to performance work.
 * 当前实现状态：闭环简化（L9）；lint/功能测试未运行。
 */
module o3_fpu_opgroup import o3_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG,
    parameter fpnew_pkg::opgroup_e GROUP,
    localparam int S=CFG.exec.fpu_inflight_slots,
    localparam int SLOT_W=(S>1 ? $clog2(S):1),
    localparam int NOP=fpnew_pkg::num_operands(GROUP)
) (
    input logic clk,rst,flush_all_i,
    input logic req_valid_i,
    output logic req_ready_o,
    input o3_types_pkg::fpu_req_t req_i,
    output logic resp_valid_o,
    input logic resp_ready_i,
    output o3_types_pkg::fpu_resp_t resp_o,
    input branch_resolution_t resolution_i,
    output logic busy_o
);
    typedef logic [SLOT_W-1:0] slot_id_t;
    o3_types_pkg::fu_tag_t tags_q [S];
    logic [S-1:0] valid_q,killed_q,release_slot;
    logic have_free;
    slot_id_t alloc_slot;
    logic hold_valid_q,hold_end,hold_available;
    slot_id_t hold_slot_q;
    logic [63:0] hold_result_q;
    logic [4:0] hold_flags_q;
    logic move_valid_q,move_killed,move_ready,is_move,prefer_move_q;
    slot_id_t move_slot_q;
    logic [63:0] move_result_q,move_result;
    logic cv_in_valid,cv_in_ready,cv_out_valid,cv_out_ready,cv_busy,cv_killed;
    logic choose_cv,choose_move,req_fire;
    slot_id_t cv_slot;
    logic [63:0] cv_result;
    fpnew_pkg::status_t cv_status;
    fpnew_pkg::operation_e operation;
    fpnew_pkg::roundmode_e roundmode;
    logic op_mod;
    logic [NOP-1:0][63:0] operands;
    logic [fpnew_pkg::NUM_FP_FORMATS-1:0][NOP-1:0] is_boxed;
    // Vivado needs an explicit assignment context for array patterns before
    // they enter a conditional expression. Preserve every format's latency.
    localparam fpnew_pkg::fmt_unsigned_t ADDMUL_REGS = '{3,4,1,1,1};
    localparam fpnew_pkg::fmt_unsigned_t DIVSQRT_REGS = '{default:2};
    localparam fpnew_pkg::fmt_unsigned_t NONCOMP_REGS = '{default:1};
    localparam fpnew_pkg::fmt_unsigned_t CONV_REGS = '{default:4};
    localparam fpnew_pkg::fmt_unsigned_t PIPE_REGS = GROUP==fpnew_pkg::ADDMUL ?
        ADDMUL_REGS : GROUP==fpnew_pkg::DIVSQRT ? DIVSQRT_REGS :
        GROUP==fpnew_pkg::NONCOMP ? NONCOMP_REGS : CONV_REGS;
    localparam fpnew_pkg::fmt_unit_types_t PARALLEL_UNITS = '{default:fpnew_pkg::PARALLEL};
    localparam fpnew_pkg::fmt_unit_types_t MERGED_UNITS = '{default:fpnew_pkg::MERGED};
    localparam fpnew_pkg::fmt_unit_types_t UNIT_TYPES =
        (GROUP==fpnew_pkg::ADDMUL || GROUP==fpnew_pkg::NONCOMP) ? PARALLEL_UNITS : MERGED_UNITS;

    function automatic logic branch_killed(input branch_mask_t mask);
        return resolution_i.valid && resolution_i.mispredict && mask[resolution_i.branch_tag];
    endfunction
    function automatic logic slot_killed(input slot_id_t slot);
        if (int'(slot)>=S) return 1;
        return killed_q[slot] || flush_all_i || branch_killed(tags_q[slot].br_mask);
    endfunction
    always_comb begin
        have_free=0; alloc_slot='0;
        for (int s=0;s<S;s++) if (!valid_q[s] && !have_free) begin
            have_free=1; alloc_slot=slot_id_t'(s);
        end
    end
    always_comb begin
        operation=fpnew_pkg::ADD;
        roundmode=fpnew_pkg::roundmode_e'(req_i.rm);
        op_mod=0; operands='0;
        for (int op=0;op<NOP;op++) begin
            if (op==0) operands[op]=req_i.src1;
            else if (op==1) operands[op]=req_i.src2;
        end
        // Third source exists only in ADDMUL, use a generate below for fixed widths.
        case (req_i.op)
            o3_types_pkg::FOP_ADD,o3_types_pkg::FOP_SUB: begin
                operation=fpnew_pkg::ADD; op_mod=req_i.op==o3_types_pkg::FOP_SUB;
            end
            o3_types_pkg::FOP_MUL: operation=fpnew_pkg::MUL;
            o3_types_pkg::FOP_MADD,o3_types_pkg::FOP_MSUB: begin
                operation=fpnew_pkg::FMADD; op_mod=req_i.op==o3_types_pkg::FOP_MSUB;
            end
            o3_types_pkg::FOP_NMSUB,o3_types_pkg::FOP_NMADD: begin
                operation=fpnew_pkg::FNMSUB; op_mod=req_i.op==o3_types_pkg::FOP_NMADD;
            end
            o3_types_pkg::FOP_DIV: operation=fpnew_pkg::DIV;
            o3_types_pkg::FOP_SQRT: operation=fpnew_pkg::SQRT;
            o3_types_pkg::FOP_SGNJ,o3_types_pkg::FOP_SGNJN,o3_types_pkg::FOP_SGNJX: operation=fpnew_pkg::SGNJ;
            o3_types_pkg::FOP_MIN,o3_types_pkg::FOP_MAX: operation=fpnew_pkg::MINMAX;
            o3_types_pkg::FOP_EQ,o3_types_pkg::FOP_LT,o3_types_pkg::FOP_LE: operation=fpnew_pkg::CMP;
            o3_types_pkg::FOP_CLASS: operation=fpnew_pkg::CLASSIFY;
            o3_types_pkg::FOP_CVT_F2F: operation=fpnew_pkg::F2F;
            o3_types_pkg::FOP_CVT_F2I: begin operation=fpnew_pkg::F2I; op_mod=req_i.op_mod; end
            o3_types_pkg::FOP_CVT_I2F: begin operation=fpnew_pkg::I2F; op_mod=req_i.op_mod; end
            default: ; // FMV uses local bitwise transport.
        endcase
    end
    // Separate operand assembly avoids out-of-range selects in single-source CONV.
    logic [NOP-1:0][63:0] cv_operands;
    if (GROUP==fpnew_pkg::ADDMUL) begin : g_fma_operands
        always_comb begin
            cv_operands=operands; cv_operands[2]=req_i.src3;
            if (req_i.op inside {o3_types_pkg::FOP_ADD,o3_types_pkg::FOP_SUB})
                cv_operands={req_i.src2,req_i.src1,64'd0};
        end
    end else begin : g_other_operands
        assign cv_operands=operands;
    end
    always_comb begin
        is_boxed='1;
        for (int op=0;op<NOP;op++) is_boxed[fpnew_pkg::FP32][op]=cv_operands[op][63:32]==32'hffffffff;
        is_move=GROUP==fpnew_pkg::CONV && (req_i.op inside {o3_types_pkg::FOP_MV_F2X,o3_types_pkg::FOP_MV_X2F});
        move_result=req_i.src1;
        if (req_i.dst_fmt==o3_types_pkg::FFMT_S) begin
            if (req_i.op==o3_types_pkg::FOP_MV_F2X) move_result={{32{req_i.src1[31]}},req_i.src1[31:0]};
            else move_result={32'hffffffff,req_i.src1[31:0]};
        end
    end
    assign cv_in_valid=req_valid_i && have_free && !is_move && !flush_all_i && !branch_killed(req_i.tag.br_mask);
    assign req_ready_o=have_free && !flush_all_i && !branch_killed(req_i.tag.br_mask) && (is_move ? move_ready : cv_in_ready);
    assign req_fire=req_valid_i && req_ready_o;
    fpnew_opgroup_block #(
        .OpGroup(GROUP),.Width(64),.EnableVectors(0),.DivSqrtSel(fpnew_pkg::THMULTI),
        .FpFmtMask(fpnew_pkg::RV64D.FpFmtMask),.IntFmtMask(fpnew_pkg::RV64D.IntFmtMask),
        .FmtPipeRegs(PIPE_REGS),.FmtUnitTypes(UNIT_TYPES),.PipeConfig(fpnew_pkg::DISTRIBUTED),.TagType(slot_id_t)
    ) u_opgroup (
        .clk_i(clk),.rst_ni(!rst),.operands_i(cv_operands),.is_boxed_i(is_boxed),
        .rnd_mode_i(roundmode),.op_i(operation),.op_mod_i(op_mod),
        .src_fmt_i(req_i.src_fmt==o3_types_pkg::FFMT_D ? fpnew_pkg::FP64:fpnew_pkg::FP32),
        .dst_fmt_i(req_i.dst_fmt==o3_types_pkg::FFMT_D ? fpnew_pkg::FP64:fpnew_pkg::FP32),
        .int_fmt_i(req_i.int_fmt==o3_types_pkg::IFMT_L ? fpnew_pkg::INT64:fpnew_pkg::INT32),
        .vectorial_op_i(1'b0),.tag_i(alloc_slot),.simd_mask_i('1),
        .in_valid_i(cv_in_valid),.in_ready_o(cv_in_ready),.flush_i(1'b0),
        .result_o(cv_result),.status_o(cv_status),.extension_bit_o(),.tag_o(cv_slot),
        .out_valid_o(cv_out_valid),.out_ready_i(cv_out_ready),.busy_o(cv_busy),.early_valid_o()
    );
    always_comb begin
        resp_o='0;
        if (hold_valid_q) begin
            resp_o.tag=tags_q[hold_slot_q];
            if (resolution_i.valid) resp_o.tag.br_mask[resolution_i.branch_tag]=0;
            resp_o.result=hold_result_q; resp_o.fflags=hold_flags_q;
            resp_o.valid=!slot_killed(hold_slot_q);
        end
        resp_valid_o=resp_o.valid;
        hold_end=hold_valid_q && (slot_killed(hold_slot_q) || resp_ready_i);
        hold_available=!hold_valid_q || hold_end;
        cv_killed=cv_out_valid && slot_killed(cv_slot);
        move_killed=move_valid_q && slot_killed(move_slot_q);
        choose_cv=0; choose_move=0;
        if (hold_available) begin
            if (cv_out_valid && !cv_killed && move_valid_q && !move_killed) begin
                choose_move=prefer_move_q; choose_cv=!prefer_move_q;
            end else begin
                choose_cv=cv_out_valid && !cv_killed;
                choose_move=move_valid_q && !move_killed;
            end
        end
        cv_out_ready=cv_killed || choose_cv;
        move_ready=!move_valid_q || move_killed || choose_move;
        release_slot='0;
        if (hold_end) release_slot[hold_slot_q]=1;
        if (cv_out_valid && cv_out_ready && cv_killed) release_slot[cv_slot]=1;
        if (move_killed) release_slot[move_slot_q]=1;
        busy_o=(|valid_q) || cv_busy;
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            valid_q<='0; killed_q<='0; tags_q<='{default:'0};
            hold_valid_q<=0; hold_slot_q<='0; hold_result_q<='0; hold_flags_q<='0;
            move_valid_q<=0; move_slot_q<='0; move_result_q<='0; prefer_move_q<=0;
        end else begin
            for (int s=0;s<S;s++) if (valid_q[s]) begin
                if (flush_all_i || branch_killed(tags_q[s].br_mask)) killed_q[s]<=1;
                if (resolution_i.valid) tags_q[s].br_mask[resolution_i.branch_tag]<=0;
                if (release_slot[s]) begin valid_q[s]<=0; killed_q[s]<=0; end
            end
            if (req_fire) begin
                valid_q[alloc_slot]<=1; killed_q[alloc_slot]<=0; tags_q[alloc_slot]<=req_i.tag;
                if (resolution_i.valid) tags_q[alloc_slot].br_mask[resolution_i.branch_tag]<=0;
            end
            if (hold_end) hold_valid_q<=0;
            if (choose_cv) begin
                hold_valid_q<=1; hold_slot_q<=cv_slot; hold_result_q<=cv_result; hold_flags_q<=cv_status;
                prefer_move_q<=1;
            end else if (choose_move) begin
                hold_valid_q<=1; hold_slot_q<=move_slot_q; hold_result_q<=move_result_q; hold_flags_q<=0;
                prefer_move_q<=0;
            end
            if (move_ready) begin
                move_valid_q<=req_fire && is_move;
                if (req_fire && is_move) begin move_slot_q<=alloc_slot; move_result_q<=move_result; end
            end
        end
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk) if (!rst) begin
        if (cv_out_valid) begin
            assert (int'(cv_slot)<S);
            assert (valid_q[cv_slot]);
        end
        if (hold_valid_q) assert (valid_q[hold_slot_q]);
        if (move_valid_q) assert (valid_q[move_slot_q]);
        if (req_fire) assert (!valid_q[alloc_slot]);
    end
`endif
    initial begin
        if (S<2) $error("L9 requires multiple in-flight FP identity slots");
    end
endmodule

/**
 * L9 ADDMUL wrapper: pinned CVFPU split operation group with identity side table,
 * stable common result holding slot and same-cycle recovery filtering.
 * Uses o3_fpu_opgroup (defined in fpu_fma_fu.sv); CONV also carries raw FMV bits.
 * B33 early wakeup for FP FUs is deferred to performance work; actual PRF grant wakes.
 * 当前实现状态：闭环简化（L9）；lint/功能测试未运行。
 */
module fpu_fma_fu import o3_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG
) (
    input logic clk,rst,flush_all_i,
    input logic req_valid_i,
    output logic req_ready_o,
    input o3_types_pkg::fpu_req_t req_i,
    output logic resp_valid_o,
    input logic resp_ready_i,
    output o3_types_pkg::fpu_resp_t resp_o,
    input branch_resolution_t resolution_i,
    output logic busy_o
);
    o3_fpu_opgroup #(.CFG(CFG),.GROUP(fpnew_pkg::ADDMUL)) u_transport (.*);
endmodule
