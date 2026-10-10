/** L7c: eight-slot pool with program-order delivery. Killed pending requests
 * remain zombies until their response; zombies never block the new path.
 * Reserve -> response -> kill -> dequeue defines same-edge priority.
 * Tests: sim/cocotb/fetch_return_queue/. */
module fetch_return_queue
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic            clk_i,
    input  logic            rst_i,

    // 预留：与 FTQ→ICache demand 握手同拍确认
    output logic            rsv_ready_o,
    output rq_idx_t         rsv_idx_o,
    input  logic            rsv_fire_i,
    input  icache_req_t     rsv_req_i,

    // ICache 响应（乱序）
    input  icache_resp_t    resp_i,

    // 出队时读取 FTQ 最终预测摘要
    output logic            ftq_brief_rd_valid_o,
    output ftq_id_t         ftq_brief_rd_id_o,
    input  ftq_pred_brief_t ftq_brief_i,
    // A write to the currently read FTQ row invalidates the output snapshot.
    // The row remains in this queue until the consumer handshake.
    input  logic brief_slow_valid_i = 1'b0,
    input  ftq_id_t brief_slow_id_i = '0,
    input  logic brief_resolve_valid_i = 1'b0,
    input  ftq_id_t brief_resolve_id_i = '0,

    // 出队给 F0
    output logic            deq_valid_o,
    input  logic            deq_ready_i,
    output rq_out_t         deq_o,
    output ftq_pred_brief_t deq_brief_o,

    input  fe_kill_t        kill_i,
    input  ftq_id_t         ftq_head_i,

    output fe_perf_t        perf_o
);
    localparam int DEPTH=CFG.fetch.return_queue_depth;
    localparam int CW=$clog2(DEPTH+1);
    typedef enum logic [1:0] {FREE,PEND,READY,ZOMBIE} state_t;
    typedef struct packed {state_t state; rq_out_t item;} slot_t;
    slot_t slots_q[DEPTH],slots_d[DEPTH];
    rq_idx_t ord_q[DEPTH],ord_d[DEPTH];
    logic [CW-1:0] count_q,count_d;
    int free_idx;
    rq_idx_t head_slot, snapshot_slot;
    logic deq_fire, reservation_bad, response_bad, suffix_bad;
    logic output_valid_q, head_ready, head_refresh, snapshot_refresh;
    rq_out_t output_data_q;
    ftq_pred_brief_t output_brief_q;
    always_comb begin
        free_idx=-1;
        for(int n=0;n<DEPTH;n++) if(free_idx<0 && slots_q[n].state==FREE) free_idx=n;
        rsv_ready_o=!rst_i && !kill_i.valid && free_idx>=0;
        rsv_idx_o=free_idx<0 ? '0 : rq_idx_t'(free_idx);
        head_slot=ord_q[0];
        // While the current output is held, pre-read the following region.
        // Its snapshot can replace a consumed output on the very same edge.
        snapshot_slot=output_valid_q && count_q>1 ? ord_q[1]:head_slot;
        ftq_brief_rd_valid_o=count_q>CW'(output_valid_q);
        ftq_brief_rd_id_o=ftq_brief_rd_valid_o ? slots_q[snapshot_slot].item.ftq_id:'0;
        head_refresh=(brief_slow_valid_i && brief_slow_id_i==output_data_q.ftq_id) ||
            (brief_resolve_valid_i && brief_resolve_id_i==output_data_q.ftq_id);
        snapshot_refresh=(brief_slow_valid_i && brief_slow_id_i==ftq_brief_rd_id_o) ||
            (brief_resolve_valid_i && brief_resolve_id_i==ftq_brief_rd_id_o);
        head_ready=ftq_brief_rd_valid_o && slots_q[snapshot_slot].state==READY &&
            ftq_brief_i.slow_done && ftq_brief_i.ftq_id==slots_q[snapshot_slot].item.ftq_id;
        deq_valid_o=!rst_i && !kill_i.valid && !head_refresh && output_valid_q;
        deq_o=output_valid_q ? output_data_q:'0;
        deq_brief_o=output_valid_q ? output_brief_q:'0;
        perf_o='0;
        if(!rst_i) begin
            perf_o[PE_RQ_HEAD_WAIT_DATA_CYCLE]=PERF_INC_W'(count_q!=0 && slots_q[head_slot].state==PEND);
            perf_o[PE_RQ_HEAD_WAIT_SLOW_CYCLE]=PERF_INC_W'(!output_valid_q && count_q!=0 && slots_q[head_slot].state==READY && !ftq_brief_i.slow_done);
            for(int n=0;n<DEPTH;n++) if(slots_q[n].state==ZOMBIE)
                perf_o[PE_RQ_ZOMBIE]+=PERF_INC_W'(1);
        end
    end
    assign deq_fire=deq_valid_o && deq_ready_i;
    // Head ownership stays with the queue until dequeue. A boundary kill or
    // prediction update discards only this snapshot; a surviving head is read
    // again after the FTQ write, so no stale alloc/slow/fix merge is delivered.
    always_ff @(posedge clk_i) begin : output_snapshot
        if(rst_i) begin
            output_valid_q<=0;output_data_q<='0;output_brief_q<='0;
        end else if(kill_i.valid || (output_valid_q && head_refresh)) output_valid_q<=0;
        else if((!output_valid_q || deq_fire) && head_ready && !snapshot_refresh) begin
            output_valid_q<=1;
            output_data_q<=slots_q[snapshot_slot].item;
            output_brief_q<=ftq_brief_i;
        end else if(deq_fire) output_valid_q<=0;
    end
    always_comb begin : next_state
        int s, keep;
        logic suffix;
        for(int n=0;n<DEPTH;n++) begin slots_d[n]=slots_q[n];ord_d[n]=ord_q[n];end
        count_d=count_q;s=0;keep=0;suffix=0;
        reservation_bad=0;response_bad=0;suffix_bad=0;
        if(!rst_i) begin
            if(rsv_fire_i) begin
                s=int'(rsv_req_i.rq_idx);
                reservation_bad=!(rsv_ready_o && s<DEPTH && slots_d[s].state==FREE);
                slots_d[s]='{state:PEND,item:'{ftq_id:rsv_req_i.ftq_id,region_base:rsv_req_i.region_base,default:'0}};
                ord_d[rq_idx_t'(count_d)]=rq_idx_t'(s);count_d=count_d+1'b1;
            end
            if(resp_i.valid) begin
                s=int'(resp_i.rq_idx);
                response_bad=!(s<DEPTH && (slots_d[s].state==PEND || slots_d[s].state==ZOMBIE) && slots_d[s].item.ftq_id==resp_i.ftq_id);
                if(slots_d[s].state==ZOMBIE) slots_d[s].state=FREE;
                else begin
                    slots_d[s].state=READY;slots_d[s].item.data=resp_i.data;
                    slots_d[s].item.exc_valid=resp_i.exc_valid;slots_d[s].item.exc_cause=resp_i.exc_cause;
                end
            end
            if(kill_i.valid) begin
                for(int n=0;n<DEPTH;n++) if(n<int'(count_d)) begin
                    s=int'(ord_d[n]);
                    if(fe_killed_by(kill_i,slots_d[s].item.ftq_id,fetch_slot_t'(0),ftq_head_i)) begin
                        suffix=1;
                        slots_d[s].state=slots_d[s].state==PEND ? ZOMBIE : FREE;
                    end else begin
                        suffix_bad|=suffix;
                        keep++;
                    end
                end
                count_d=CW'(keep);
            end
            if(deq_fire) begin
                slots_d[ord_d[0]].state=FREE;
                for(int n=0;n<DEPTH-1;n++) ord_d[n]=ord_d[n+1];
                ord_d[DEPTH-1]='0;count_d=count_d-1'b1;
            end
        end
    end
    always_ff @(posedge clk_i) begin : state_update
        int pending,ordered;
        if(rst_i) begin
            count_q<=0;
            for(int n=0;n<DEPTH;n++) begin slots_q[n]<='0;ord_q[n]<='0;end
        end else begin
            assert(!output_valid_q || (count_q!=0 && output_data_q.ftq_id==slots_q[head_slot].item.ftq_id))
                else $fatal(1,"RQ output snapshot lost head ownership");
            assert(!reservation_bad) else $fatal(1,"RQ reservation is not FREE");
            assert(!response_bad) else $fatal(1,"RQ response identity/state mismatch");
            assert(!suffix_bad) else $fatal(1,"RQ kill must be a suffix");
            count_q<=count_d;pending=0;ordered=0;
            for(int n=0;n<DEPTH;n++) begin
                slots_q[n]<=slots_d[n];ord_q[n]<=ord_d[n];
                if(slots_d[n].state==PEND || slots_d[n].state==ZOMBIE) pending++;
                if(slots_d[n].state==PEND || slots_d[n].state==READY) ordered++;
            end
            assert(pending<=DEPTH && ordered==int'(count_d)) else $fatal(1,"RQ occupancy invariant");
        end
    end
endmodule
