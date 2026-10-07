/** Every valid victim sends Put, including clean S/E lines. Dirty data is
 * sampled in one bank-wide read before the MSHR can send Get. */
module dcache_writeback import o3_types_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG,localparam int N=CFG.dcache.wb_buffers
)(input logic clk,rst,input logic alloc_i,input dc_wb_t alloc_wb_i,
    output logic free_o,output coh_id_t free_id_o,output logic valid_o[N],output dc_wb_t wb_o[N],
    output logic read_valid_o,output coh_id_t read_id_o,output dc_wb_t read_o,input logic read_issue_i,
    input logic read_done_i,input coh_id_t read_done_id_i,input coh_data_t read_data_i,
    output logic put_valid_o,input logic put_ready_i,output coh_rsp_up_t put_o,
    input logic ack_valid_i,input coh_rsp_down_t ack_i,output logic wb_free_o);
    typedef enum logic [2:0] {IDLE,READ,READ_WAIT,SEND,WAIT_ACK} state_t;
    state_t state_q[N];dc_wb_t wb_q[N];logic held_q;int send_q,free_idx,read_idx,send_idx;
    always_comb begin
        free_idx=-1;read_idx=-1;send_idx=-1;
        for(int n=0;n<N;n++) begin
            valid_o[n]=state_q[n]!=IDLE;wb_o[n]=wb_q[n];
            if(state_q[n]==IDLE && free_idx<0) free_idx=n;
            if(state_q[n]==READ && read_idx<0) read_idx=n;
            if(state_q[n]==SEND && send_idx<0) send_idx=n;
        end
        free_o=free_idx>=0;free_id_o=COH_ID_W'(free_idx);
        read_valid_o=read_idx>=0;read_id_o=COH_ID_W'(read_idx);read_o=read_idx>=0 ? wb_q[read_idx]:'0;
        put_valid_o=held_q;put_o='{op:COH_PUT,has_data:wb_q[send_q].has_data,
            addr:wb_q[send_q].line_addr,id:COH_ID_W'(send_q),data:wb_q[send_q].data};
        wb_free_o=ack_valid_i;
    end
    always_ff @(posedge clk) begin
        if(rst) begin state_q<='{default:IDLE};wb_q<='{default:'0};held_q<=0;send_q<=0;end
        else begin
            if(alloc_i) begin assert(free_o);wb_q[free_idx]<=alloc_wb_i;
                // Clean victims also traverse READ: finite bank ownership and
                // a uniform dependency notification to the allocating MSHR.
                state_q[free_idx]<=READ;end
            if(read_issue_i) begin assert(read_valid_o);state_q[read_id_o]<=READ_WAIT;end
            if(read_done_i) begin assert(state_q[read_done_id_i]==READ_WAIT);
                wb_q[read_done_id_i].data<=read_data_i;state_q[read_done_id_i]<=SEND;end
            if(!held_q && send_idx>=0) begin held_q<=1;send_q<=send_idx;end
            if(put_valid_o && put_ready_i) begin held_q<=0;state_q[send_q]<=WAIT_ACK;end
            if(ack_valid_i) begin assert(int'(ack_i.id)<N && state_q[ack_i.id]==WAIT_ACK);state_q[ack_i.id]<=IDLE;end
            if($past(put_valid_o && !put_ready_i && !rst)) assert(put_valid_o && $stable(put_o));
        end
    end
endmodule
