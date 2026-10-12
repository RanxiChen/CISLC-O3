/** L8a four Read transactions, whole-line response, merge by physical line.
 * Accepted requests survive redirects and satp changes. FENCE.I waits idle.
 * Payload has one response writer and one fill reader in fixed-slot RAM. Per-
 * transaction SEND/WAIT/FILL states track external ownership; all N owners may
 * progress independently, with no whole-cache serial FSM. */
module icache_mshr import o3_types_pkg::*; #(
    parameter o3_cfg_pkg::frontend_cfg_t CFG,localparam int N=CFG.icache.mshrs
)(input logic clk_i,rst_i,input logic alloc_valid_i,output logic alloc_ready_o,
    input paddr_t alloc_line_paddr_i,input l2_req_kind_e alloc_kind_i,output logic alloc_merged_o,
    // Demand matching starts in ICache S2. S3 carries a narrow match vector;
    // a previous-edge allocation bypass and live-state mask repair it.
    input paddr_t demand_probe_line_i,output logic [N-1:0] demand_probe_match_o,
    input logic demand_select_i,input paddr_t demand_line_i,
    input logic [N-1:0] demand_match_i,
    input paddr_t probe_line_paddr_i,output logic probe_inflight_o,
    output logic l2_req_valid_o,input logic l2_req_ready_i,output coh_req_t l2_req_o,
    input logic l2_resp_valid_i,input coh_rsp_down_t l2_resp_i,output logic l2_resp_ready_o,
    output logic fill_wr_valid_o,input logic fill_wr_ready_i,output paddr_t fill_wr_line_paddr_o,
    output logic [ICACHE_LINE_BYTES*8-1:0] fill_wr_data_o,output logic fill_wr_error_o,
    output logic fill_done_o,output paddr_t fill_done_line_paddr_o,
    output logic [$clog2(N+1)-1:0] free_count_o,
    output logic fill_pf_o,output logic idle_o,output fe_perf_t perf_o);
    typedef enum logic [1:0] {IDLE,SEND,WAIT,FILL} state_t;
    state_t state_q[N];paddr_t addr_q[N];logic err_q[N];
    // The external response is the sole payload writer. Only FILL owners may
    // expose RAM data; state and error remain resettable metadata.
    (* ram_style="distributed" *) logic [$bits(coh_data_t)-1:0] response_mem[N];
    always_ff @(posedge clk_i)
        if (!rst_i && l2_resp_valid_i) response_mem[l2_resp_i.id]<=l2_resp_i.data;
    logic pf_only_q[N];
    logic send_held_q;int send_q,free_idx,merge_idx,send_idx,fill_idx;
    logic last_alloc_q;logic [N-1:0] last_alloc_oh_q;
    paddr_t last_alloc_line_q,selected_line;
    logic [N-1:0] demand_match,pf_match;
    assign selected_line=demand_select_i ? demand_line_i:alloc_line_paddr_i;
    for(genvar n=0;n<N;n++) begin : g_demand_match
        assign demand_probe_match_o[n]=state_q[n]!=IDLE && addr_q[n]==demand_probe_line_i;
        assign demand_match[n]=state_q[n]!=IDLE &&
            (demand_match_i[n] || (last_alloc_q && last_alloc_oh_q[n] && last_alloc_line_q==demand_line_i));
        assign pf_match[n]=state_q[n]!=IDLE && addr_q[n]==alloc_line_paddr_i;
    end
    always_comb begin
        free_idx=-1;merge_idx=-1;send_idx=-1;fill_idx=-1;probe_inflight_o=0;idle_o=1;free_count_o=0;
        for(int n=0;n<N;n++) begin
            if(state_q[n]==IDLE) begin free_count_o=free_count_o+1'b1;if(free_idx<0) free_idx=n;end
            if(state_q[n]!=IDLE) begin
                idle_o=0;if(demand_select_i ? demand_match[n]:pf_match[n]) merge_idx=n;
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
        fill_wr_data_o=fill_idx>=0 ? response_mem[fill_idx]:'0;
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
        if(rst_i) begin pf_only_q<='{default:0};state_q<='{default:IDLE};addr_q<='{default:'0};err_q<='{default:0};send_held_q<=0;send_q<=0;last_alloc_q<=0;last_alloc_oh_q<='0;last_alloc_line_q<='0;end
        else begin
            last_alloc_q<=alloc_valid_i && alloc_ready_o && !alloc_merged_o;
            last_alloc_oh_q<='0;
            if(alloc_valid_i && alloc_ready_o && !alloc_merged_o) begin
                assert((64'(selected_line)>>MEM_PADDR_W)==0);
                last_alloc_oh_q[free_idx]<=1;last_alloc_line_q<=selected_line;
                pf_only_q[free_idx]<=alloc_kind_i==L2_PREFETCH;state_q[free_idx]<=SEND;addr_q[free_idx]<=selected_line;err_q[free_idx]<=0;
            end
            if(alloc_valid_i && alloc_ready_o && alloc_merged_o && alloc_kind_i==L2_DEMAND) pf_only_q[merge_idx]<=0;
            if(!send_held_q && send_idx>=0) begin send_held_q<=1;send_q<=send_idx;end
            if(l2_req_valid_o && l2_req_ready_i) begin send_held_q<=0;state_q[send_q]<=WAIT;end
            if(l2_resp_valid_i) begin
                assert(l2_resp_i.op==COH_READDATA && int'(l2_resp_i.id)<N && state_q[l2_resp_i.id]==WAIT);
                state_q[l2_resp_i.id]<=FILL;err_q[l2_resp_i.id]<=l2_resp_i.error;
            end
            if(fill_done_o) state_q[fill_idx]<=IDLE;
            if($past(l2_req_valid_o && !l2_req_ready_i && !rst_i)) assert(l2_req_valid_o && $stable(l2_req_o));
            `ifndef SYNTHESIS
            if(demand_select_i)
                for(int n=0;n<N;n++)
                    assert(demand_match[n]==(state_q[n]!=IDLE && addr_q[n]==demand_line_i))
                        else $fatal(1,"S2 demand MSHR match/bypass differs from live address comparison");
            `endif
        end
    end
    initial assert(N<=1<<COH_ID_W);
endmodule
