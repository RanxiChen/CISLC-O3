/** L8a slow slots: own a set until INSTALL/REPLAY responds. Task ownership is captured at S0;
 * the registered payload RAM read is aligned with the existing S1 directory read. Put tasks may enter the protected set. No instruction waiters. */
module l2_slots import o3_types_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG, localparam int N=CFG.l2.slots,
    localparam int SET_W=$clog2(CFG.l2.sets)
)(input logic clk,rst,input logic alloc_i,input l2_work_t alloc_work_i,
    output logic free_o,output logic task_valid_o[N],
    input logic [L2_SLOT_W-1:0] task_select_i,output l2_work_t task_o,
    input logic task_grant_i[N],input logic done_i,input logic [L2_SLOT_W-1:0] done_slot_i,
    input l2_done_e done_result_i,input logic done_owner_i,
    output logic protected_o[N],output logic [SET_W-1:0] protected_set_o[N],output logic released_o,
    output logic probe_valid_o,input logic probe_ready_i,output l2_work_t probe_o,
    input logic collected_i,input logic [L2_SLOT_W-1:0] collected_slot_i,
    output logic read_valid_o,input logic read_ready_i,output logic [L2_SLOT_W-1:0] read_slot_o,
    output coh_addr_t read_addr_o,input logic read_done_i,input logic [L2_SLOT_W-1:0] read_done_slot_i,
    input coh_data_t read_data_i,input logic read_error_i);
    typedef enum logic [3:0] {IDLE,EVICT,IN_PIPE,PROBE_WAIT,MEM_READ,READ_WAIT,INSTALL,REPLAY} state_t;
    state_t state_q[N];logic served_q[N];
    coh_addr_t req_addr_q[N];logic is_probe_q[N];
    coh_snp_op_e probe_op_q[N];logic probe_owner_q[N],collected_q[N],error_q[N];
    logic payload_valid_q[N],refill_written_q[N];
    l2_work_t task_payload,probe_payload;
    logic [$bits(l2_work_t)-1:0] task_word_q,probe_word_q;
    coh_data_t task_refill_q,probe_refill_q;
    logic task_payload_valid_q,probe_payload_valid_q;
    logic task_refill_valid_q,probe_refill_valid_q;
    logic [L2_SLOT_W-1:0] task_slot_q;
    l2_task_e task_kind_q;
    coh_snp_op_e task_probe_op_q,probe_probe_op_q;
    logic task_probe_owner_q,probe_probe_owner_q,task_collected_q,probe_collected_q;
    logic task_error_q,probe_error_q;
    logic task_read_enable;
    always_comb begin
        task_read_enable=0;
        for(int n=0;n<N;n++) task_read_enable|=task_grant_i[n];
    end
    // The scheduler sees only state/set metadata until it selects a slot.
    // Task and probe are the two dynamic payload readers of single-write RAM.
    (* ram_style="block" *) logic [$bits(l2_work_t)-1:0] task_mem[N],probe_mem[N];
    (* ram_style="block" *) logic [$bits(coh_data_t)-1:0] task_refill_mem[N],probe_refill_mem[N];
    always_ff @(posedge clk) if(!rst) begin
        if(alloc_i) begin task_mem[free_idx]<=alloc_work_i;probe_mem[free_idx]<=alloc_work_i;end
        if(read_done_i) begin
            task_refill_mem[read_done_slot_i]<=read_data_i;
            probe_refill_mem[read_done_slot_i]<=read_data_i;
        end
    end
    // Both payload readers use the ownership acceptance edge as their
    // synchronous RAM-read boundary. Mutable control is snapshotted on the
    // same edge, before state changes, and is not read back from a reused slot.
    always_ff @(posedge clk) begin
        if(!rst && task_read_enable) begin
            task_word_q<=task_mem[task_select_i];
            task_refill_q<=task_refill_mem[task_select_i];
        end
        if(!rst && !probe_hold_q && probe_idx>=0) begin
            probe_word_q<=probe_mem[probe_idx];
            probe_refill_q<=probe_refill_mem[probe_idx];
        end
        if(rst) begin
            task_payload_valid_q<=0;probe_payload_valid_q<=0;
            task_refill_valid_q<=0;probe_refill_valid_q<=0;
            task_slot_q<='0;task_kind_q<=L2_EVICT;
            task_probe_op_q<=coh_snp_op_e'(0);probe_probe_op_q<=coh_snp_op_e'(0);
            task_probe_owner_q<=0;probe_probe_owner_q<=0;
            task_collected_q<=0;probe_collected_q<=0;task_error_q<=0;probe_error_q<=0;
        end else begin
            if(task_read_enable) begin
                task_payload_valid_q<=payload_valid_q[task_select_i];
                task_refill_valid_q<=refill_written_q[task_select_i];
                task_slot_q<=task_select_i;
                task_kind_q<=state_q[task_select_i]==INSTALL ? L2_INSTALL :
                    state_q[task_select_i]==REPLAY ? L2_REPLAY:L2_EVICT;
                task_probe_op_q<=probe_op_q[task_select_i];
                task_probe_owner_q<=probe_owner_q[task_select_i];
                task_collected_q<=collected_q[task_select_i];task_error_q<=error_q[task_select_i];
            end
            if(!probe_hold_q && probe_idx>=0) begin
                probe_payload_valid_q<=payload_valid_q[probe_idx];
                probe_refill_valid_q<=refill_written_q[probe_idx];
                probe_probe_op_q<=probe_op_q[probe_idx];probe_probe_owner_q<=probe_owner_q[probe_idx];
                probe_collected_q<=collected_q[probe_idx];probe_error_q<=error_q[probe_idx];
            end
        end
    end
    always_comb begin
        task_payload=task_payload_valid_q ? l2_work_t'(task_word_q):'0;
        probe_payload=probe_payload_valid_q ? l2_work_t'(probe_word_q):'0;
        task_payload.probe_op=task_probe_op_q;task_payload.probe_owner=task_probe_owner_q;
        task_payload.collected=task_collected_q;task_payload.error=task_error_q;
        probe_payload.probe_op=probe_probe_op_q;probe_payload.probe_owner=probe_probe_owner_q;
        probe_payload.collected=probe_collected_q;probe_payload.error=probe_error_q;
        if(task_refill_valid_q) task_payload.refill=task_refill_q;
        if(probe_refill_valid_q) probe_payload.refill=probe_refill_q;
    end
    int free_idx,probe_idx,read_idx;int probe_rr_q,read_rr_q;
    logic read_hold_q,probe_hold_q;int read_sel_q,probe_sel_q;
    always_comb begin
        free_idx=-1;probe_idx=-1;read_idx=-1;
        for(int n=N-1;n>=0;n--) if(state_q[n]==IDLE) free_idx=n;
        for(int d=0;d<N;d++) begin
            int p,r;p=(probe_rr_q+d)%N;r=(read_rr_q+d)%N;
            if(probe_idx<0 && state_q[p]==PROBE_WAIT && !served_q[p]) probe_idx=p;
            if(read_idx<0 && state_q[r]==MEM_READ) read_idx=r;
        end
        free_o=free_idx>=0;
        for(int n=0;n<N;n++) begin
            task_valid_o[n]=state_q[n]==EVICT || state_q[n]==INSTALL || state_q[n]==REPLAY;
            protected_o[n]=state_q[n]!=IDLE;protected_set_o[n]=SET_W'(req_addr_q[n]);
        end
        task_o=task_payload;task_o.slot=task_slot_q;task_o.task_kind=task_kind_q;
        probe_valid_o=probe_hold_q;probe_o=probe_payload;probe_o.slot=L2_SLOT_W'(probe_sel_q);
        read_valid_o=read_hold_q;read_slot_o=L2_SLOT_W'(read_sel_q);read_addr_o=req_addr_q[read_sel_q];
        released_o=done_i && done_result_i==L2_FINISHED;
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            state_q<='{default:IDLE};req_addr_q<='{default:'0};is_probe_q<='{default:0};probe_op_q<='{default:coh_snp_op_e'(0)};probe_owner_q<='{default:0};collected_q<='{default:0};error_q<='{default:0};payload_valid_q<='{default:0};refill_written_q<='{default:0};served_q<='{default:0};
            read_hold_q<=0;probe_hold_q<=0;read_sel_q<=0;probe_sel_q<=0;read_rr_q<=0;probe_rr_q<=0;
        end else begin
            if(alloc_i) begin
                assert(free_o) else $fatal(1,"L2 slots full on allocation");
                req_addr_q[free_idx]<=alloc_work_i.req.addr;is_probe_q[free_idx]<=alloc_work_i.is_probe;
                probe_op_q[free_idx]<=alloc_work_i.probe_op;probe_owner_q[free_idx]<=alloc_work_i.probe_owner;
                collected_q[free_idx]<=alloc_work_i.collected;error_q[free_idx]<=alloc_work_i.error;
                payload_valid_q[free_idx]<=1;refill_written_q[free_idx]<=0;
                served_q[free_idx]<=0;
                state_q[free_idx]<=alloc_work_i.is_probe ? PROBE_WAIT : alloc_work_i.victim_valid ? EVICT:MEM_READ;
            end
            for(int n=0;n<N;n++) if(task_grant_i[n]) begin
                assert(task_valid_o[n]);state_q[n]<=IN_PIPE;
            end
            if(done_i) begin
                case(done_result_i)
                    L2_NEED_PROBE:begin state_q[done_slot_i]<=PROBE_WAIT;served_q[done_slot_i]<=0;
                        for(int n=0;n<N;n++) if(int'(done_slot_i)==n) begin
                            probe_op_q[n]<=COH_INV;probe_owner_q[n]<=done_owner_i;
                        end
                    end
                    L2_EVICT_DONE:state_q[done_slot_i]<=MEM_READ;
                    L2_RETRY:state_q[done_slot_i]<=EVICT;
                    L2_FINISHED:state_q[done_slot_i]<=IDLE;
                    default:;
                endcase
                if(done_result_i!=L2_RETRY) for(int n=0;n<N;n++)
                    if(int'(done_slot_i)==n) collected_q[n]<=0;
            end
            if(!probe_hold_q && probe_idx>=0) begin probe_hold_q<=1;probe_sel_q<=probe_idx;end
            if(probe_valid_o && probe_ready_i) begin
                probe_hold_q<=0;served_q[probe_sel_q]<=1;probe_rr_q<=(probe_sel_q+1)%N;
            end
            if(collected_i) begin
                state_q[collected_slot_i]<=is_probe_q[collected_slot_i] ? REPLAY:EVICT;
                for(int n=0;n<N;n++) if(int'(collected_slot_i)==n) collected_q[n]<=1;
            end
            if(!read_hold_q && read_idx>=0) begin read_hold_q<=1;read_sel_q<=read_idx;end
            if(read_valid_o && read_ready_i) begin
                read_hold_q<=0;state_q[read_sel_q]<=READ_WAIT;read_rr_q<=(read_sel_q+1)%N;
            end
            if(read_done_i) begin
                assert(state_q[read_done_slot_i]==READ_WAIT);
                for(int n=0;n<N;n++) if(int'(read_done_slot_i)==n) begin
                    refill_written_q[n]<=1;error_q[n]<=read_error_i;
                end
                state_q[read_done_slot_i]<=INSTALL;
            end
        end
    end
endmodule
