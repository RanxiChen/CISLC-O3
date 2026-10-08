/** L8a slow slots: own a set until INSTALL/REPLAY responds. Tasks capture all
 * payload at S0. Put tasks may enter the protected set. No instruction waiters. */
module l2_slots import o3_types_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG, localparam int N=CFG.l2.slots,
    localparam int SET_W=$clog2(CFG.l2.sets)
)(input logic clk,rst,input logic alloc_i,input l2_work_t alloc_work_i,
    output logic free_o,output logic task_valid_o[N],output l2_work_t task_o[N],
    input logic task_grant_i[N],input logic done_i,input logic [L2_SLOT_W-1:0] done_slot_i,
    input l2_done_e done_result_i,input logic done_owner_i,
    output logic protected_o[N],output logic [SET_W-1:0] protected_set_o[N],output logic released_o,
    output logic probe_valid_o,input logic probe_ready_i,output l2_work_t probe_o,
    input logic collected_i,input logic [L2_SLOT_W-1:0] collected_slot_i,
    output logic read_valid_o,input logic read_ready_i,output logic [L2_SLOT_W-1:0] read_slot_o,
    output coh_addr_t read_addr_o,input logic read_done_i,input logic [L2_SLOT_W-1:0] read_done_slot_i,
    input coh_data_t read_data_i,input logic read_error_i);
    typedef enum logic [3:0] {IDLE,EVICT,IN_PIPE,PROBE_WAIT,MEM_READ,READ_WAIT,INSTALL,REPLAY} state_t;
    state_t state_q[N];l2_work_t work_q[N];logic served_q[N];
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
            task_o[n]=work_q[n];task_o[n].slot=L2_SLOT_W'(n);
            task_o[n].task_kind=state_q[n]==INSTALL ? L2_INSTALL : state_q[n]==REPLAY ? L2_REPLAY:L2_EVICT;
            protected_o[n]=state_q[n]!=IDLE;protected_set_o[n]=SET_W'(work_q[n].req.addr);
        end
        probe_valid_o=probe_hold_q;probe_o=work_q[probe_sel_q];probe_o.slot=L2_SLOT_W'(probe_sel_q);
        read_valid_o=read_hold_q;read_slot_o=L2_SLOT_W'(read_sel_q);read_addr_o=work_q[read_sel_q].req.addr;
        released_o=done_i && done_result_i==L2_FINISHED;
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            state_q<='{default:IDLE};work_q<='{default:'0};served_q<='{default:0};
            read_hold_q<=0;probe_hold_q<=0;read_sel_q<=0;probe_sel_q<=0;read_rr_q<=0;probe_rr_q<=0;
        end else begin
            if(alloc_i) begin
                assert(free_o) else $fatal(1,"L2 slots full on allocation");
                for(int n=0;n<N;n++) if(free_idx==n) work_q[n]<=alloc_work_i;
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
                            work_q[n].probe_op<=COH_INV;work_q[n].probe_owner<=done_owner_i;
                        end
                    end
                    L2_EVICT_DONE:state_q[done_slot_i]<=MEM_READ;
                    L2_RETRY:state_q[done_slot_i]<=EVICT;
                    L2_FINISHED:state_q[done_slot_i]<=IDLE;
                    default:;
                endcase
                if(done_result_i!=L2_RETRY) for(int n=0;n<N;n++)
                    if(int'(done_slot_i)==n) work_q[n].collected<=0;
            end
            if(!probe_hold_q && probe_idx>=0) begin probe_hold_q<=1;probe_sel_q<=probe_idx;end
            if(probe_valid_o && probe_ready_i) begin
                probe_hold_q<=0;served_q[probe_sel_q]<=1;probe_rr_q<=(probe_sel_q+1)%N;
            end
            if(collected_i) begin
                state_q[collected_slot_i]<=work_q[collected_slot_i].is_probe ? REPLAY:EVICT;
                for(int n=0;n<N;n++) if(int'(collected_slot_i)==n) work_q[n].collected<=1;
            end
            if(!read_hold_q && read_idx>=0) begin read_hold_q<=1;read_sel_q<=read_idx;end
            if(read_valid_o && read_ready_i) begin
                read_hold_q<=0;state_q[read_sel_q]<=READ_WAIT;read_rr_q<=(read_sel_q+1)%N;
            end
            if(read_done_i) begin
                assert(state_q[read_done_slot_i]==READ_WAIT);
                for(int n=0;n<N;n++) if(int'(read_done_slot_i)==n) begin
                    work_q[n].refill<=read_data_i;work_q[n].error<=read_error_i;
                end
                state_q[read_done_slot_i]<=INSTALL;
            end
        end
    end
endmodule
