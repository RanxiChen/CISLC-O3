/** L7b F1: predecode expanded instructions with actual lengths and edge position.
 * The first a-f correction or exception truncates delivery. c-prime also works
 * on an empty beat. trunc_o clears F0's unsent state on the handshake edge;
 * the correction request is registered and never combinationally gated by kill.
 * RAS corrections use the region-entry checkpoint. Winner events belong to
 * redirect_arbiter; this module's performance increments remain zero.
 * Tests: sim/cocotb/ifu_f1 and sim/cocotb/l7_recovery.
 */
module ifu_f1
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic            clk_i,
    input  logic            rst_i,

    input  logic [F0_SLOTS-1:0] in_valid_i,
    input  logic in_beat_valid_i, in_last_i, in_edge_pend_i,
    output logic            in_ready_o,
    input  f0_inst_t        in_i [F0_SLOTS],
    input  ftq_pred_brief_t in_brief_i,

    output fetch_entry_t    out_o [F1_W],
    output logic [F1_W-1:0] out_valid_o,
    input  logic            out_ready_i,

    output redirect_req_t   predecode_o,
    output logic trunc_o,
    output fetch_slot_t trunc_slot_o,

    input  fe_kill_t        kill_i,

    output fe_perf_t        perf_o
);
    typedef struct packed {
        cfi_type_e type_id;
        ras_action_e ras_action;
        vaddr_t direct_target;
    } decoded_cfi_t;

    redirect_req_t pd_req, pd_req_q;

    // Decode the same legal BR/JAL/JALR encodings and x1/x5 hints as the
    // backend. Direct immediates are sign-extended to the configured PC width.
    function automatic decoded_cfi_t decode_cfi(input f0_inst_t inst);
        decoded_cfi_t decoded;
        logic rd_link, rs1_link;
        decoded = '0;
        rd_link = inst.instruction[11:7] inside {5'd1, 5'd5};
        rs1_link = inst.instruction[19:15] inside {5'd1, 5'd5};
        case (inst.instruction[6:0])
            7'b1100011: if (inst.instruction[14:12] inside
                           {3'b000, 3'b001, 3'b100, 3'b101, 3'b110, 3'b111}) begin
                decoded.type_id = CFI_BR;
                decoded.direct_target = inst.pc + vaddr_t'($signed({
                    inst.instruction[31], inst.instruction[7],
                    inst.instruction[30:25], inst.instruction[11:8], 1'b0}));
            end
            7'b1101111: begin
                decoded.type_id = CFI_JAL;
                decoded.ras_action = rd_link ? RAS_PUSH : RAS_NONE;
                decoded.direct_target = inst.pc + vaddr_t'($signed({
                    inst.instruction[31], inst.instruction[19:12],
                    inst.instruction[20], inst.instruction[30:21], 1'b0}));
            end
            7'b1100111: if (inst.instruction[14:12] == 3'b000) begin
                decoded.type_id = CFI_JALR;
                if (rs1_link)
                    decoded.ras_action = rd_link
                        ? (inst.instruction[11:7] == inst.instruction[19:15]
                           ? RAS_PUSH : RAS_POP_PUSH)
                        : RAS_POP;
                else decoded.ras_action = rd_link ? RAS_PUSH : RAS_NONE;
            end
            default: ;
        endcase
        return decoded;
    endfunction

    // Each lane decodes opcode/immediate/target independently. The ordered
    // scan below only selects the first correction and its surviving prefix.
    decoded_cfi_t decoded_at[F0_SLOTS];
    for(genvar lane=0;lane<F0_SLOTS;lane++) begin : g_cfi_decode
        assign decoded_at[lane]=decode_cfi(in_i[lane]);
    end

    assign in_ready_o = !rst_i && !kill_i.valid && out_ready_i;
    // Do not gate this registered request with kill_i: it is an arbiter input,
    // and that arbiter produces kill_i combinationally (spec 2.5).
    assign predecode_o = pd_req_q;
    assign trunc_o = in_ready_o && in_beat_valid_i && pd_req.valid;
    assign trunc_slot_o = pd_req.slot;
    // PE_PREDECODE_REDIRECT belongs to the arbiter's accept edge (U13).
    assign perf_o = '0;

    fetch_entry_t lane_data[F0_SLOTS];
    redirect_req_t lane_req[F0_SLOTS];
    logic [F0_SLOTS-1:0] lane_stop, emitted, exception_emitted;
    logic [$clog2(F0_SLOTS+1)-1:0] lane_rank[F0_SLOTS];
    for (genvar lane=0; lane<F0_SLOTS; lane++) begin : g_predecode_lane
        always_comb begin
            logic [3:0] start_pos, end_pos, exit_pos;
            decoded_cfi_t decoded;
            logic is_exit, covers_exit, earlier, return_target_valid;
            logic actual_target_valid, fix_valid, fix_taken, fix_hist;
            vaddr_t actual_target, fix_target;
            ras_action_e fix_ras;
            decoded='0; start_pos=0; end_pos=0;
            // Position 0 denotes the edge halfword; physical slot k is k+1.
            exit_pos=in_brief_i.pred.is_edge ? 4'd0:4'(in_brief_i.pred.cfi_slot)+4'd1;
            is_exit=0; covers_exit=0; earlier=0; return_target_valid=0;
            actual_target_valid=0; actual_target='0;
            fix_valid=0; fix_taken=0; fix_hist=0; fix_target='0; fix_ras=RAS_NONE;
            lane_data[lane]='0; lane_req[lane]='0; lane_stop[lane]=0;
            if (!rst_i && !kill_i.valid && in_beat_valid_i && in_valid_i[lane]) begin
                decoded = decoded_at[lane];
                start_pos=in_i[lane].is_edge ? 4'd0:4'(in_i[lane].slot)+4'd1;
                end_pos=start_pos+4'(in_i[lane].inst_len==4);
                is_exit = in_brief_i.pred.cfi_valid && start_pos==exit_pos;
                covers_exit = in_brief_i.pred.cfi_valid && end_pos>=exit_pos;
                earlier = !in_brief_i.pred.cfi_valid || start_pos<exit_pos;
                return_target_valid = decoded.type_id == CFI_JALR
                    && decoded.ras_action inside {RAS_POP, RAS_POP_PUSH}
                    && in_brief_i.ras_ckpt.count != '0;
                actual_target_valid = decoded.type_id == CFI_JAL || return_target_valid;
                actual_target = return_target_valid ? in_brief_i.ras_ckpt.top_addr
                                                    : decoded.direct_target;
                fix_valid = 1'b0;
                fix_taken = 1'b0;
                fix_hist = 1'b0;
                fix_target = in_i[lane].pc + vaddr_t'(in_i[lane].inst_len);
                fix_ras = RAS_NONE;

                // Ordered a/b > c > d > e > f (U19). No rule examines an
                // exception item, or an item following it (U10/U20).
                if (!in_i[lane].exc_valid) begin
                    if (earlier && actual_target_valid) begin // a / b
                        fix_valid = 1'b1;
                        fix_taken = 1'b1;
                        fix_target = actual_target;
                        fix_ras = decoded.ras_action;
                    end else if (covers_exit && (!is_exit || decoded.type_id == CFI_NONE)) begin // c
                        fix_valid = 1'b1;
                    end else if (is_exit && decoded.type_id != in_brief_i.pred.cfi_type) begin // d
                        fix_valid = 1'b1;
                        // A(i) is recomputed without a/b's position condition.
                        if (actual_target_valid) begin
                            fix_taken = 1'b1;
                            fix_target = actual_target;
                            fix_ras = decoded.ras_action;
                        end
                    end else if (is_exit && decoded.type_id inside {CFI_BR, CFI_JAL}
                        && (in_brief_i.pred.cfi_target != decoded.direct_target
                            || (decoded.type_id == CFI_JAL
                                && (in_brief_i.pred.ras_action != decoded.ras_action
                                    || (decoded.ras_action inside {RAS_PUSH,RAS_POP_PUSH}
                                        && in_brief_i.pred.cfi_is_rvc != in_i[lane].is_rvc))))) begin // e
                        fix_valid = 1'b1;
                        fix_taken = 1'b1;
                        fix_target = decoded.direct_target;
                        fix_ras = decoded.ras_action;
                        fix_hist = decoded.type_id == CFI_BR;
                    end else if (is_exit && decoded.type_id == CFI_JALR
                        && (in_brief_i.pred.ras_action != decoded.ras_action
                            || (decoded.ras_action inside {RAS_PUSH,RAS_POP_PUSH}
                                && in_brief_i.pred.cfi_is_rvc != in_i[lane].is_rvc))) begin // f
                        fix_valid = 1'b1;
                        fix_taken = 1'b1;
                        fix_target = return_target_valid ? actual_target : in_brief_i.pred.next_pc;
                        fix_ras = decoded.ras_action;
                    end
                end

                lane_data[lane].valid = 1'b1;
                lane_data[lane].pc = in_i[lane].pc;
                lane_data[lane].raw_instruction = in_i[lane].raw_instruction;
                lane_data[lane].instruction = in_i[lane].instruction;
                lane_data[lane].inst_len = in_i[lane].inst_len;
                lane_data[lane].is_rvc = in_i[lane].is_rvc;
                lane_data[lane].is_edge = in_i[lane].is_edge;
                lane_data[lane].exception_valid = in_i[lane].exc_valid;
                lane_data[lane].exception_cause = in_i[lane].exc_cause;
                lane_data[lane].exception_tval = in_i[lane].exc_tval;
                lane_data[lane].ftq_id = in_i[lane].ftq_id;
                lane_data[lane].slot = in_i[lane].slot;
                lane_data[lane].pred_taken = fix_valid ? fix_taken : is_exit;
                lane_data[lane].predicted_next_pc = fix_valid ? fix_target
                    : (is_exit ? in_brief_i.pred.next_pc : in_i[lane].pc + vaddr_t'(in_i[lane].inst_len));
                if (fix_valid) begin
                    lane_req[lane].valid = 1'b1;
                    lane_req[lane].src = REDIR_PREDECODE;
                    lane_req[lane].ftq_id = in_i[lane].ftq_id;
                    lane_req[lane].slot = in_i[lane].slot;
                    lane_req[lane].kill_self = 1'b0;
                    lane_req[lane].target_pc = fix_target;
                    lane_req[lane].hist_inject = fix_hist;
                    lane_req[lane].hist_branch_pc = in_i[lane].pc;
                    lane_req[lane].hist_target_pc = fix_target;
                    lane_req[lane].ras_fix = fix_ras;
                    lane_req[lane].ras_push_addr = in_i[lane].pc + vaddr_t'(in_i[lane].inst_len);
                end
                lane_stop[lane] = fix_valid || in_i[lane].exc_valid || covers_exit;
            end
        end
        always_comb begin
            lane_rank[lane]='0;
            for (int k=0; k<lane; k++) lane_rank[lane] += $clog2(F0_SLOTS+1)'(in_valid_i[k]);
        end
        if (lane == 0) assign emitted[lane] = in_valid_i[lane] && !rst_i && !kill_i.valid && in_beat_valid_i;
        else assign emitted[lane] = in_valid_i[lane] && !(|lane_stop[lane-1:0])
            && int'(lane_rank[lane]) < F1_W && !rst_i && !kill_i.valid && in_beat_valid_i;
        assign exception_emitted[lane] = emitted[lane] && in_i[lane].exc_valid;
    end
    // Fixed one-hot compaction; no dynamic writes to a wide output array.
    for (genvar out_lane=0; out_lane<F1_W; out_lane++) begin : g_output_lane
        logic last_lane;
        logic [F0_SLOTS-1:0] picks;
        for (genvar lane=0; lane<F0_SLOTS; lane++)
            assign picks[lane]=emitted[lane] && int'(lane_rank[lane]) == out_lane;
        assign out_valid_o[out_lane]=|picks;
        if (out_lane == F1_W-1) assign last_lane = 1'b1;
        else assign last_lane = !(|out_valid_o[F1_W-1:out_lane+1]);
        always_comb begin
            out_o[out_lane]='0;
            for (int lane=0; lane<F0_SLOTS; lane++) begin
                out_o[out_lane] |= lane_data[lane] & {$bits(fetch_entry_t){picks[lane]}};
            end
            out_o[out_lane].ftq_last = out_valid_o[out_lane] && last_lane && (in_last_i || pd_req.valid);
        end
    end
    always_comb begin
        pd_req='0;
        for (int lane=0; lane<F0_SLOTS; lane++)
            pd_req |= lane_req[lane] & {$bits(redirect_req_t){emitted[lane]}};
        // c-prime applies even to an empty beat, unless an exception terminated it.
        if (!rst_i && !kill_i.valid && in_beat_valid_i && !pd_req.valid
            && in_last_i && in_edge_pend_i && in_brief_i.pred.cfi_valid
            && !in_brief_i.pred.is_edge && in_brief_i.pred.cfi_slot==fetch_slot_t'(REGION_SLOTS-1)
            && !(|exception_emitted)) begin
            pd_req.valid=1; pd_req.src=REDIR_PREDECODE;
            pd_req.ftq_id=in_brief_i.ftq_id; pd_req.slot=fetch_slot_t'(REGION_SLOTS-1);
            pd_req.target_pc=in_brief_i.pred.region_base+vaddr_t'(REGION_BYTES);
        end
    end

    // N+1 requests are consumed once, independently of the next block's
    // backpressure. A killed block cannot handshake or create a request.
    always_ff @(posedge clk_i) begin
        if (rst_i) pd_req_q <= '0;
        else begin
            pd_req_q <= '0;
            if (in_ready_o && in_beat_valid_i && pd_req.valid) pd_req_q <= pd_req;
        end
    end
endmodule
