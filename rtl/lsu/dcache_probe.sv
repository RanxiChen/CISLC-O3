/** One receive slot; only line transactions/PS can delay service. LQ/SQ
 * waiters never participate in the SNP ready dependency. */
module dcache_probe import o3_types_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG
)(input logic clk,rst,init_done_i,input logic snp_valid_i,output logic snp_ready_o,input coh_snp_t snp_i,
    input logic hold_i,output logic pending_o,output coh_snp_t pending_snp_o,
    output logic read_valid_o,input logic read_issue_i,
    input logic read_done_i,input coh_data_t read_data_i,input coh_state_e read_state_i,
    output logic ack_valid_o,input logic ack_ready_i,output coh_rsp_up_t ack_o);
    typedef enum logic [1:0] {IDLE,PENDING,READ_WAIT,ANSWER} state_t;
    state_t state_q;coh_snp_t snp_q;coh_rsp_up_t ack_q;
    assign snp_ready_o=init_done_i && state_q==IDLE;
    assign pending_o=state_q!=IDLE;assign pending_snp_o=snp_q;
    assign read_valid_o=state_q==PENDING && !hold_i;
    assign ack_valid_o=state_q==ANSWER;assign ack_o=ack_q;
    always_ff @(posedge clk) begin
        if(rst) begin state_q<=IDLE;snp_q<='0;ack_q<='0;end
        else begin
            if(snp_valid_i && snp_ready_o) begin snp_q<=snp_i;state_q<=PENDING;end
            if(read_issue_i) begin assert(read_valid_o);state_q<=READ_WAIT;end
            if(read_done_i) begin
                assert(state_q==READ_WAIT);state_q<=ANSWER;
                ack_q<='{op:(snp_q.op==COH_INV ? COH_INVACK:COH_DOWNACK),has_data:(read_state_i==COH_M),
                    addr:snp_q.addr,id:'0,data:read_data_i};
            end
            if(ack_valid_o && ack_ready_i) state_q<=IDLE;
        end
    end
endmodule
