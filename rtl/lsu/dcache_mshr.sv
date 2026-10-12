/** Line-only MSHRs. No CPU request or replay state is stored here. SEND
 * selection is latched and remains stable through REQ backpressure. Per-slot
 * observers expose metadata; a single dynamic INSTALL reader gets response RAM.
 * No payload is read before the corresponding response was accepted. */
module dcache_mshr import o3_types_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG,localparam int N=CFG.dcache.mshrs
)(input logic clk,rst,input logic alloc_i,input dc_line_txn_t alloc_txn_i,
    output logic free_o,output coh_id_t free_id_o,output logic [$clog2(N+1)-1:0] free_count_o,
    output dc_mshr_state_e state_o[N],output dc_line_meta_t txn_o[N],
    input logic wb_read_done_i,input coh_id_t wb_read_id_i,
    output logic req_valid_o,input logic req_ready_i,output coh_req_t req_o,
    input logic rsp_valid_i,input coh_rsp_down_t rsp_i,
    output logic install_valid_o,output coh_id_t install_id_o,output dc_line_txn_t install_o,
    input logic install_issue_i,input logic install_done_i,input coh_id_t install_done_id_i,
    output logic mshr_free_o);
    dc_mshr_state_e state_q[N];dc_line_meta_t txn_q[N];logic issued_q[N];
    (* ram_style="distributed" *) logic [$bits(coh_data_t)-1:0] response_mem[N];
    always_ff @(posedge clk) if(!rst && rsp_valid_i) response_mem[rsp_i.id]<=rsp_i.data;
    logic send_hold_q;int send_id_q,send_rr_q;int free_idx,send_idx,install_idx;
    // Relative allocation order among active owners, bounded by N. Removing
    // any owner closes its rank hole; allocation appends after the survivors.
    // Unlike a global 32-bit timestamp this cannot wrap and reverse SEND order.
    localparam int AGE_W=N>1?$clog2(N):1;
    logic [AGE_W-1:0] age_q[N],oldest;
    logic [$clog2(N+1)-1:0] active_count;
    always_comb begin
        free_idx=-1;send_idx=-1;install_idx=-1;free_count_o='0;oldest='1;active_count='0;
        for(int n=0;n<N;n++) begin
            state_o[n]=state_q[n];txn_o[n]=txn_q[n];
            active_count+=$clog2(N+1)'(state_q[n]!=DM_IDLE);
            if(state_q[n]==DM_IDLE) begin free_count_o=free_count_o+1'b1;if(free_idx<0) free_idx=n;end
            if(state_q[n]==DM_SEND && (send_idx<0 || age_q[n]<oldest)) begin send_idx=n;oldest=age_q[n];end
            if(state_q[n]==DM_INSTALL && !issued_q[n] && install_idx<0) install_idx=n;
        end
        free_o=free_idx>=0;free_id_o=COH_ID_W'(free_idx);
        req_valid_o=send_hold_q;req_o='0;
        req_o.op=txn_q[send_id_q].is_getm ? COH_GETM:COH_GETS;
        req_o.addr=txn_q[send_id_q].line_addr;req_o.id=COH_ID_W'(send_id_q);
        install_valid_o=install_idx>=0;install_id_o=COH_ID_W'(install_idx);
        install_o='0;
        if(install_idx>=0) begin
            install_o='{line_addr:txn_q[install_idx].line_addr,is_getm:txn_q[install_idx].is_getm,
                upgrade:txn_q[install_idx].upgrade,atomic:txn_q[install_idx].atomic,way:txn_q[install_idx].way,
                wb_wait:txn_q[install_idx].wb_wait,wb_id:txn_q[install_idx].wb_id,
                refill:response_mem[install_idx],err:txn_q[install_idx].err,
                grant_e:txn_q[install_idx].grant_e,ack_e:txn_q[install_idx].ack_e};
        end
        mshr_free_o=install_done_i;
    end
    always_ff @(posedge clk) begin
        if(rst) begin state_q<='{default:DM_IDLE};txn_q<='{default:'0};issued_q<='{default:0};
            send_hold_q<=0;send_id_q<=0;send_rr_q<=0;age_q<='{default:0};end
        else begin
            for(int n=0;n<N;n++) if(state_q[n]!=DM_IDLE) begin
                assert(int'(age_q[n])<int'(active_count));
                for(int m=n+1;m<N;m++) if(state_q[m]!=DM_IDLE) assert(age_q[n]!=age_q[m]);
            end
            if(install_done_i) for(int n=0;n<N;n++)
                if(state_q[n]!=DM_IDLE && age_q[n]>age_q[install_done_id_i]) age_q[n]<=age_q[n]-1'b1;
            if(alloc_i) begin
                assert(free_o);txn_q[free_idx]<='{line_addr:alloc_txn_i.line_addr,is_getm:alloc_txn_i.is_getm,
                    upgrade:alloc_txn_i.upgrade,atomic:alloc_txn_i.atomic,way:alloc_txn_i.way,
                    wb_wait:alloc_txn_i.wb_wait,wb_id:alloc_txn_i.wb_id,err:alloc_txn_i.err,
                    grant_e:alloc_txn_i.grant_e,ack_e:alloc_txn_i.ack_e};issued_q[free_idx]<=0;
                state_q[free_idx]<=alloc_txn_i.wb_wait ? DM_WB_READ:DM_SEND;
                age_q[free_idx]<=AGE_W'(int'(active_count)-int'(install_done_i));
                for(int n=0;n<N;n++) if(state_q[n]!=DM_IDLE) assert(txn_q[n].line_addr!=alloc_txn_i.line_addr);
            end
            if(wb_read_done_i) for(int n=0;n<N;n++)
                if(state_q[n]==DM_WB_READ && txn_q[n].wb_id==wb_read_id_i) state_q[n]<=DM_SEND;
            if(!send_hold_q && send_idx>=0) begin send_hold_q<=1;send_id_q<=send_idx;end
            if(req_valid_o && req_ready_i) begin state_q[send_id_q]<=DM_WAIT;send_hold_q<=0;send_rr_q<=(send_id_q+1)%N;end
            if(rsp_valid_i) begin
                assert(int'(rsp_i.id)<N && state_q[rsp_i.id]==DM_WAIT);
                assert(rsp_i.op==COH_DATAS || rsp_i.op==COH_DATAE || rsp_i.op==COH_ACKE);
                assert(rsp_i.op!=COH_ACKE || txn_q[rsp_i.id].upgrade);
                assert(rsp_i.op!=COH_DATAS || !txn_q[rsp_i.id].is_getm);
                txn_q[rsp_i.id].err<=rsp_i.error;
                txn_q[rsp_i.id].grant_e<=rsp_i.op!=COH_DATAS;txn_q[rsp_i.id].ack_e<=rsp_i.op==COH_ACKE;
                state_q[rsp_i.id]<=DM_INSTALL;
            end
            if(install_issue_i) begin assert(install_valid_o);issued_q[install_id_o]<=1;end
            if(install_done_i) begin assert(state_q[install_done_id_i]==DM_INSTALL);state_q[install_done_id_i]<=DM_IDLE;end
            if($past(req_valid_o && !req_ready_i && !rst)) assert(req_valid_o && $stable(req_o));
        end
    end
endmodule
