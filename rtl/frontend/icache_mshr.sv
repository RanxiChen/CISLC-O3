/** L8a four Read transactions, whole-line response, merge by physical line.
 * Accepted requests survive redirects and satp changes. FENCE.I waits idle. */
module icache_mshr import o3_types_pkg::*; #(
    parameter o3_cfg_pkg::frontend_cfg_t CFG,localparam int N=CFG.icache.mshrs
)(input logic clk_i,rst_i,input logic alloc_valid_i,output logic alloc_ready_o,
    input paddr_t alloc_line_paddr_i,input l2_req_kind_e alloc_kind_i,output logic alloc_merged_o,
    input paddr_t probe_line_paddr_i,output logic probe_inflight_o,
    output logic l2_req_valid_o,input logic l2_req_ready_i,output coh_req_t l2_req_o,
    input logic l2_resp_valid_i,input coh_rsp_down_t l2_resp_i,output logic l2_resp_ready_o,
    output logic fill_wr_valid_o,input logic fill_wr_ready_i,output paddr_t fill_wr_line_paddr_o,
    output logic [ICACHE_LINE_BYTES*8-1:0] fill_wr_data_o,output logic fill_wr_error_o,
    output logic fill_done_o,output paddr_t fill_done_line_paddr_o,
    output logic [$clog2(N+1)-1:0] free_count_o,
    output logic fill_pf_o,output logic idle_o,output fe_perf_t perf_o);
    typedef enum logic [1:0] {IDLE,SEND,WAIT,FILL} state_t;
    state_t state_q[N];paddr_t addr_q[N];coh_data_t data_q[N];logic err_q[N];
    logic pf_only_q[N];
    logic send_held_q;int send_q,free_idx,merge_idx,send_idx,fill_idx;
    always_comb begin
        free_idx=-1;merge_idx=-1;send_idx=-1;fill_idx=-1;probe_inflight_o=0;idle_o=1;free_count_o=0;
        for(int n=0;n<N;n++) begin
            if(state_q[n]==IDLE) begin free_count_o=free_count_o+1'b1;if(free_idx<0) free_idx=n;end
            if(state_q[n]!=IDLE) begin
                idle_o=0;if(addr_q[n]==alloc_line_paddr_i) merge_idx=n;
                if(addr_q[n]==probe_line_paddr_i) probe_inflight_o=1;
            end
            if(state_q[n]==SEND && send_idx<0) send_idx=n;
            if(state_q[n]==FILL && fill_idx<0) fill_idx=n;
        end
        alloc_ready_o=merge_idx>=0 || free_idx>=0;alloc_merged_o=merge_idx>=0;
        l2_req_valid_o=send_held_q;l2_req_o='0;l2_req_o.op=COH_READ;
        l2_req_o.id=COH_ID_W'(send_q);l2_req_o.addr=coh_addr_t'(addr_q[send_q]>>6);
        l2_resp_ready_o=1;fill_wr_valid_o=fill_idx>=0;
        fill_wr_line_paddr_o=fill_idx>=0 ? addr_q[fill_idx]:'0;
        fill_wr_data_o=fill_idx>=0 ? data_q[fill_idx]:'0;
        fill_wr_error_o=fill_idx>=0 && err_q[fill_idx];
        fill_done_o=fill_wr_valid_o && fill_wr_ready_i;fill_done_line_paddr_o=fill_wr_line_paddr_o;
    end
    assign fill_pf_o=fill_idx>=0 && pf_only_q[fill_idx] && !(alloc_valid_i && alloc_ready_o && alloc_merged_o && alloc_kind_i==L2_DEMAND && merge_idx==fill_idx);
    // Event accounting must not feed the allocation-ready dependency cone.
    always_comb begin
        perf_o='0;perf_o[PE_PF_LATE]=PERF_INC_W'(alloc_valid_i && alloc_ready_o && alloc_merged_o && alloc_kind_i==L2_DEMAND && pf_only_q[merge_idx]);perf_o[PE_ICACHE_MSHR_MERGE]=PERF_INC_W'(alloc_valid_i && alloc_ready_o && alloc_merged_o);
        for(int n=0;n<N;n++) if(state_q[n]==WAIT) perf_o[PE_ICACHE_REFILL_WAIT_CYCLE]=PERF_INC_W'(1);
    end
    always_ff @(posedge clk_i) begin
        if(rst_i) begin pf_only_q<='{default:0};state_q<='{default:IDLE};addr_q<='{default:'0};data_q<='{default:'0};err_q<='{default:0};send_held_q<=0;send_q<=0;end
        else begin
            if(alloc_valid_i && alloc_ready_o && !alloc_merged_o) begin
                assert((64'(alloc_line_paddr_i)>>MEM_PADDR_W)==0);
                pf_only_q[free_idx]<=alloc_kind_i==L2_PREFETCH;state_q[free_idx]<=SEND;addr_q[free_idx]<=alloc_line_paddr_i;err_q[free_idx]<=0;
            end
            if(alloc_valid_i && alloc_ready_o && alloc_merged_o && alloc_kind_i==L2_DEMAND) pf_only_q[merge_idx]<=0;
            if(!send_held_q && send_idx>=0) begin send_held_q<=1;send_q<=send_idx;end
            if(l2_req_valid_o && l2_req_ready_i) begin send_held_q<=0;state_q[send_q]<=WAIT;end
            if(l2_resp_valid_i) begin
                assert(l2_resp_i.op==COH_READDATA && int'(l2_resp_i.id)<N && state_q[l2_resp_i.id]==WAIT);
                state_q[l2_resp_i.id]<=FILL;data_q[l2_resp_i.id]<=l2_resp_i.data;err_q[l2_resp_i.id]<=l2_resp_i.error;
            end
            if(fill_done_o) state_q[fill_idx]<=IDLE;
            if($past(l2_req_valid_o && !l2_req_ready_i && !rst_i)) assert(l2_req_valid_o && $stable(l2_req_o));
        end
    end
    initial assert(N<=1<<COH_ID_W);
endmodule
