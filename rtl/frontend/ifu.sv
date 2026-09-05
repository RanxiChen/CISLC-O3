/**
 * Serial Instruction Fetch Unit
 *
 * 已实现：一次持有一个FTQ预测块，一次只允许一个ICache请求在飞；返回数据被
 * 保持到Fetch Buffer接受。每条输出携带ftq_idx、ftq_last和predicted_next_pc。
 * redirect/flush会清除当前块、请求和返回状态，迟到的旧ICache返回被忽略。
 *
 * 未实现：并发请求、RVC解压、跨页取指、TLB/PMP和多请求epoch。本阶段不新增测试。
 *
 * 周期N组合阶段根据状态产生FTQ ready、ICache request或Fetch Buffer输出；周期N
 * 上升沿只在对应ready/valid握手后推进状态；周期N+1可见锁存的块、返回或下一窗口。
 */
module ifu
    import ftq_pkg::*;
    import o3_pkg::*;
(
    input  logic       clk_i,
    input  logic       rst_i,
    input  logic       flush_i,
    input  logic       ftq_valid_i,
    output logic       ftq_ready_o,
    input  ftq_entry_t ftq_entry_i,
    input  ftq_idx_t   ftq_idx_i,
    output logic       icache_valid_o,
    input  logic       icache_ready_i,
    output logic [PC_WIDTH-1:0] icache_pc_o,
    input  logic       icache_out_valid_i,
    input  logic [FTQ_FETCH_WINDOW_BYTES*8-1:0] icache_out_data_i,
    input  logic       icache_out_error_i,
    output fetch_entry_t fetch_entry_o [4],
    output logic [3:0]   fetch_valid_o,
    input  logic         fetch_ready_i,
    input  logic         icache_req_allowed_i
);
    typedef enum logic [1:0] {IFU_IDLE, IFU_REQ, IFU_WAIT, IFU_OUT} ifu_state_e;

    ifu_state_e          state_q;
    ftq_entry_t          block_q;
    ftq_idx_t            ftq_idx_q;
    logic [PC_WIDTH-1:0] fetch_ptr_q;
    logic [PC_WIDTH-1:0] response_pc_q;
    logic [3:0]          response_mask_q;
    logic [FTQ_FETCH_WINDOW_BYTES*8-1:0] response_data_q;
    logic                response_error_q;
    logic                response_misaligned_q;
    logic [PC_WIDTH-1:0] request_pc;
    logic [3:0]          request_mask;
    logic                request_is_last;
    logic                ftq_fire, request_fire, output_fire;
    logic [PC_WIDTH-1:0] output_lane_pc [4];

    assign request_pc = {fetch_ptr_q[PC_WIDTH-1:4], 4'b0};
    assign request_mask[0] = (request_pc      >= block_q.start_pc) && (request_pc      < block_q.end_pc);
    assign request_mask[1] = (request_pc +  4 >= block_q.start_pc) && (request_pc +  4 < block_q.end_pc);
    assign request_mask[2] = (request_pc +  8 >= block_q.start_pc) && (request_pc +  8 < block_q.end_pc);
    assign request_mask[3] = (request_pc + 12 >= block_q.start_pc) && (request_pc + 12 < block_q.end_pc);
    assign request_is_last = (request_pc + PC_WIDTH'(FTQ_FETCH_WINDOW_BYTES) >= block_q.end_pc);

    always_comb begin
        for (int lane = 0; lane < 4; lane++) begin
            output_lane_pc[lane] = response_pc_q + PC_WIDTH'(4 * lane);
        end
    end

    assign ftq_ready_o    = (state_q == IFU_IDLE);
    assign ftq_fire       = ftq_valid_i && ftq_ready_o;
    assign icache_valid_o = (state_q == IFU_REQ) && icache_req_allowed_i;
    assign icache_pc_o    = request_pc;
    assign request_fire   = icache_valid_o && icache_ready_i;
    assign output_fire    = (state_q == IFU_OUT) && fetch_ready_i;

    always_comb begin
        fetch_valid_o = '0;
        fetch_entry_o = '{default: '0};
        if (state_q == IFU_OUT) begin
            if (response_misaligned_q) begin
                fetch_valid_o[0] = 1'b1;
                fetch_entry_o[0].valid = 1'b1;
                fetch_entry_o[0].pc = block_q.start_pc;
                fetch_entry_o[0].exception_valid = 1'b1;
                fetch_entry_o[0].exception_cause = EXCEPTION_CAUSE_INST_ADDR_MISALIGNED;
                fetch_entry_o[0].exception_tval = XLEN'(block_q.start_pc);
                fetch_entry_o[0].ftq_idx = ftq_idx_q;
                fetch_entry_o[0].ftq_last = 1'b1;
                fetch_entry_o[0].predicted_next_pc = block_q.next_pc;
            end else begin
                for (int lane = 0; lane < 4; lane++) begin
                    fetch_valid_o[lane] = response_mask_q[lane];
                    fetch_entry_o[lane].valid = response_mask_q[lane];
                    fetch_entry_o[lane].pc = output_lane_pc[lane];
                    fetch_entry_o[lane].raw_instruction = response_data_q[lane*ILEN +: ILEN];
                    fetch_entry_o[lane].instruction = response_data_q[lane*ILEN +: ILEN];
                    fetch_entry_o[lane].inst_len = 3'd4;
                    fetch_entry_o[lane].is_rvc = 1'b0;
                    fetch_entry_o[lane].exception_valid = response_mask_q[lane] && response_error_q;
                    fetch_entry_o[lane].exception_cause = response_error_q ? EXCEPTION_CAUSE_INST_ACCESS_FAULT : '0;
                    fetch_entry_o[lane].exception_tval = response_error_q ? XLEN'(output_lane_pc[lane]) : '0;
                    fetch_entry_o[lane].ftq_idx = ftq_idx_q;
                    fetch_entry_o[lane].ftq_last = response_mask_q[lane]
                                                && (output_lane_pc[lane] + PC_WIDTH'(4) >= block_q.end_pc);
                    fetch_entry_o[lane].predicted_next_pc = block_q.has_branch
                                                          && (output_lane_pc[lane] == block_q.branch_pc)
                                                          ? block_q.next_pc
                                                          : output_lane_pc[lane] + PC_WIDTH'(4);
                end
            end
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i || flush_i) begin
            state_q               <= IFU_IDLE;
            block_q               <= '0;
            ftq_idx_q             <= '0;
            fetch_ptr_q           <= '0;
            response_pc_q         <= '0;
            response_mask_q       <= '0;
            response_data_q       <= '0;
            response_error_q      <= 1'b0;
            response_misaligned_q <= 1'b0;
        end else begin
            unique case (state_q)
                IFU_IDLE: begin
                    if (ftq_fire) begin
                        block_q     <= ftq_entry_i;
                        ftq_idx_q   <= ftq_idx_i;
                        fetch_ptr_q <= ftq_entry_i.start_pc;
                        response_misaligned_q <= (ftq_entry_i.start_pc[1:0] != 2'b00);
                        state_q <= (ftq_entry_i.start_pc[1:0] != 2'b00) ? IFU_OUT : IFU_REQ;
                    end
                end
                IFU_REQ: begin
                    if (request_fire) begin
                        response_pc_q   <= request_pc;
                        response_mask_q <= request_mask;
                        state_q         <= IFU_WAIT;
                    end
                end
                IFU_WAIT: begin
                    if (icache_out_valid_i) begin
                        response_data_q  <= icache_out_data_i;
                        response_error_q <= icache_out_error_i;
                        state_q          <= IFU_OUT;
                    end
                end
                IFU_OUT: begin
                    if (output_fire) begin
                        if (response_misaligned_q || request_is_last) begin
                            state_q <= IFU_IDLE;
                        end else begin
                            fetch_ptr_q <= request_pc + PC_WIDTH'(FTQ_FETCH_WINDOW_BYTES);
                            state_q <= IFU_REQ;
                        end
                    end
                end
                default: state_q <= IFU_IDLE;
            endcase
        end
    end
endmodule
