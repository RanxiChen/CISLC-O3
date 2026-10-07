/** Single-hart L2 Home. S0 meta read, S1 tag/data select, S2 effects.
 * Put > slow-slot task_kind > request, round robin within a class. Requests fire
 * only at S2; slow slots protect sets, while Put tasks can still enter them.
 * L1I is a Read client and never a directory sharer. */
module l2_home import o3_types_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG,
    localparam int ID_W=CFG.l2.axi_id_bits,DATA_W=CFG.l2.axi_data_bits,
    localparam int SETS=CFG.l2.sets,WAYS=CFG.l2.ways,N=CFG.l2.slots,
    localparam int SW=$clog2(SETS),WW=$clog2(WAYS),TW=COH_ADDR_W-SW
)(input logic clk,rst,
    input logic l1d_req_valid_i,output logic l1d_req_ready_o,input coh_req_t l1d_req_i,
    output logic l1d_resp_valid_o,input logic l1d_resp_ready_i,output coh_rsp_down_t l1d_resp_o,
    input logic l1i_req_valid_i,output logic l1i_req_ready_o,input coh_req_t l1i_req_i,
    output logic l1i_resp_valid_o,input logic l1i_resp_ready_i,output coh_rsp_down_t l1i_resp_o,
    input logic dma_req_valid_i,output logic dma_req_ready_o,input coh_req_t dma_req_i,
    output logic dma_resp_valid_o,input logic dma_resp_ready_i,output coh_rsp_down_t dma_resp_o,
    input logic rsp_up_valid_i,output logic rsp_up_ready_o,input coh_rsp_up_t rsp_up_i,
    output logic snp_valid_o,input logic snp_ready_i,output coh_snp_t snp_o,
    output fatal_evt_t fatal_o,output be_perf_t perf_o,
    output logic                  m_axi_awvalid,
    input  logic                  m_axi_awready,
    output logic [ID_W-1:0]   m_axi_awid,
    output logic [PADDR_W-1:0]    m_axi_awaddr,
    output logic [7:0]            m_axi_awlen,
    output logic [2:0]            m_axi_awsize,
    output logic [1:0]            m_axi_awburst,
    output logic                  m_axi_wvalid,
    input  logic                  m_axi_wready,
    output logic [DATA_W-1:0] m_axi_wdata,
    output logic [DATA_W/8-1:0] m_axi_wstrb,
    output logic                  m_axi_wlast,
    input  logic                  m_axi_bvalid,
    output logic                  m_axi_bready,
    input  logic [ID_W-1:0]   m_axi_bid,
    input  logic [1:0]            m_axi_bresp,
    output logic                  m_axi_arvalid,
    input  logic                  m_axi_arready,
    output logic [ID_W-1:0]   m_axi_arid,
    output logic [PADDR_W-1:0]    m_axi_araddr,
    output logic [7:0]            m_axi_arlen,
    output logic [2:0]            m_axi_arsize,
    output logic [1:0]            m_axi_arburst,
    input  logic                  m_axi_rvalid,
    output logic                  m_axi_rready,
    input  logic [ID_W-1:0]   m_axi_rid,
    input  logic [DATA_W-1:0] m_axi_rdata,
    input  logic [1:0]            m_axi_rresp,
    input  logic                  m_axi_rlast
);
    typedef struct packed {logic valid,dirty;logic [TW-1:0] tag;coh_dir_e state;logic sharer;} meta_t;
    typedef enum logic [1:0] {NEW_REQ,PUT_TASK,SLOT_TASK} kind_t;
    typedef struct packed {kind_t kind;l2_work_t work;logic [SW-1:0] set_idx;coh_rsp_up_t put;} pipe_t;
    meta_t meta_q[SETS][WAYS],meta_read_q[WAYS],s2_meta_q[WAYS];
    logic [WAYS-2:0] plru_q[SETS],plru_read_q,s2_plru_q;
    (* ram_style="block" *) coh_data_t data_q[SETS*WAYS];coh_data_t data_read_q;
    logic init_done_q;int init_set_q;
    pipe_t s0,s1_q,s2_q;logic s0_valid,s1_valid_q,s2_valid_q;
    logic s1_hit,s2_hit_q;int s1_way,s2_way_q,victim_way;
    logic in_pipe_q[3],slot_wait_q[3];int req_rr_q,put_rr_q,task_rr_q;
    logic put_valid_q[CFG.l2.put_buffers],put_pipe_q[CFG.l2.put_buffers];
    coh_rsp_up_t put_q[CFG.l2.put_buffers];
    logic answer_valid_q;coh_rsp_up_t answer_q;
    logic task_valid[N],task_grant[N],protected_set_valid[N];l2_work_t task_kind[N];logic [SW-1:0] protected_set[N];
    logic slot_free,slot_alloc,slot_done,slot_released; l2_work_t alloc_work;
    l2_done_e done_result;logic done_owner;
    logic probe_valid,probe_ready,probe_collected,probe_release,probe_active;
    l2_work_t probe_work;logic [L2_SLOT_W-1:0] collected_slot;
    logic read_valid,read_ready,read_done,read_error;logic [L2_SLOT_W-1:0] read_slot,read_done_slot;
    coh_addr_t read_addr;coh_data_t read_data;
    logic wb_free,wb_push;coh_addr_t wb_addr;coh_data_t wb_data;
    coh_req_t req[3];logic req_valid[3],req_ready[3],rsp_ready[3];
    logic rsp_valid[3];coh_rsp_down_t rsp[3];
    coh_rsp_down_t out_q[3][6];int out_head_q[3],out_tail_q[3],out_count_q[3];
    logic rsp_push;coh_rsp_down_t rsp_new;int rsp_client;
    logic meta_write,data_write,plru_write;meta_t meta_new;coh_data_t data_new;
    int write_way,plru_way;logic accept_req,reject_req;
    meta_t base;coh_data_t contents;logic finish_req,consume_answer;
    function automatic int fifo_depth(input int c);
        return c==0 ? o3_cfg_pkg::O3_CFG.be.dcache.mshrs+CFG.l2.put_buffers : c==1 ? o3_cfg_pkg::O3_CFG.fe.icache.mshrs:1;
    endfunction
    function automatic logic [WAYS-2:0] touch(input logic [WAYS-2:0] tree,input int way_idx);
        logic [WAYS-2:0] t;int node,dir;t=tree;node=0;
        for(int level=0;level<WW;level++) begin dir=(way_idx>>(WW-level-1))&1;t[node]=1'(1-dir);node=2*node+1+dir;end
        return t;
    endfunction
    function automatic int victim(input logic [WAYS-2:0] tree);
        int node,w,dir;node=0;w=0;
        for(int level=0;level<WW;level++) begin dir=int'(tree[node]);w=2*w+dir;node=2*node+1+dir;end
        return w;
    endfunction
    function automatic logic in_flight(input logic [SW-1:0] s);
        return (s1_valid_q && s1_q.set_idx==s) || (s2_valid_q && s2_q.set_idx==s);
    endfunction
    function automatic logic protected_line(input logic [SW-1:0] s);
        logic busy;busy=in_flight(s);
        for(int n=0;n<N;n++) busy|=protected_set_valid[n] && protected_set[n]==s;
        return busy;
    endfunction
    assign req='{l1d_req_i,l1i_req_i,dma_req_i};
    assign req_valid='{l1d_req_valid_i,l1i_req_valid_i,dma_req_valid_i};
    assign rsp_ready='{l1d_resp_ready_i,l1i_resp_ready_i,dma_resp_ready_i};
    assign l1d_req_ready_o=req_ready[0];assign l1i_req_ready_o=req_ready[1];assign dma_req_ready_o=req_ready[2];
    assign l1d_resp_valid_o=rsp_valid[0];assign l1d_resp_o=rsp[0];
    assign l1i_resp_valid_o=rsp_valid[1];assign l1i_resp_o=rsp[1];
    assign dma_resp_valid_o=rsp_valid[2];assign dma_resp_o=rsp[2];
    assign rsp_up_ready_o=1;
    l2_slots #(.CFG(CFG)) u_slots(.clk(clk),.rst(rst),.alloc_i(slot_alloc),.alloc_work_i(alloc_work),
        .free_o(slot_free),.task_valid_o(task_valid),.task_o(task_kind),.task_grant_i(task_grant),
        .done_i(slot_done),.done_slot_i(s2_q.work.slot),.done_result_i(done_result),.done_owner_i(done_owner),
        .protected_o(protected_set_valid),.protected_set_o(protected_set),.released_o(slot_released),
        .probe_valid_o(probe_valid),.probe_ready_i(probe_ready),.probe_o(probe_work),
        .collected_i(probe_collected),.collected_slot_i(collected_slot),
        .read_valid_o(read_valid),.read_ready_i(read_ready),.read_slot_o(read_slot),.read_addr_o(read_addr),
        .read_done_i(read_done),.read_done_slot_i(read_done_slot),.read_data_i(read_data),.read_error_i(read_error));
    l2_probe_engine #(.CFG(CFG)) u_probe(.clk(clk),.rst(rst),.job_valid_i(probe_valid),.job_ready_o(probe_ready),.job_i(probe_work),
        .snp_valid_o(snp_valid_o),.snp_ready_i(snp_ready_i),.snp_o(snp_o),
        .answer_valid_i(rsp_up_valid_i && rsp_up_i.op!=COH_PUT),.answer_i(rsp_up_i),
        .collected_o(probe_collected),.collected_slot_o(collected_slot),.release_i(probe_release),.active_o(probe_active));
    l2_mem_engine #(.CFG(CFG)) u_mem(.clk(clk),.rst(rst),
        .read_valid_i(read_valid),.read_ready_o(read_ready),.read_slot_i(read_slot),.read_addr_i(read_addr),
        .read_done_o(read_done),.read_done_slot_o(read_done_slot),.read_data_o(read_data),.read_error_o(read_error),
        .wb_push_i(wb_push),.wb_addr_i(wb_addr),.wb_data_i(wb_data),.wb_free_o(wb_free),.fatal_o(fatal_o),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_awid(m_axi_awid),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .m_axi_bid(m_axi_bid),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_arid(m_axi_arid),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .m_axi_rid(m_axi_rid),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast));
    // S0 priority classes. An in-pipe Put cannot be selected twice.
    always_comb begin
        int chosen,n,c;chosen=-1;n=0;c=0;s0='0;s0_valid=0;task_grant='{default:0};
        if(init_done_q) begin
            for(int d=0;d<CFG.l2.put_buffers;d++) begin
                n=(put_rr_q+d)%CFG.l2.put_buffers;
                if(chosen<0 && put_valid_q[n] && !put_pipe_q[n] && !in_flight(SW'(put_q[n].addr))) chosen=n;
            end
            if(chosen>=0) begin
                s0_valid=1;s0.kind=PUT_TASK;s0.put=put_q[chosen];s0.work.req.addr=put_q[chosen].addr;
                s0.work.client=0;s0.set_idx=SW'(put_q[chosen].addr);
            end else begin
                for(int d=0;d<N;d++) begin n=(task_rr_q+d)%N;
                    if(chosen<0 && task_valid[n] && !in_flight(SW'(task_kind[n].req.addr))) chosen=n;
                end
                if(chosen>=0) begin
                    s0_valid=1;s0.kind=SLOT_TASK;s0.work=task_kind[chosen];s0.set_idx=SW'(task_kind[chosen].req.addr);task_grant[chosen]=1;
                end else begin
                    for(int d=0;d<3;d++) begin c=(req_rr_q+d)%3;
                        if(chosen<0 && req_valid[c] && !in_pipe_q[c] && !slot_wait_q[c] && !protected_line(SW'(req[c].addr))) chosen=c;
                    end
                    if(chosen>=0) begin s0_valid=1;s0.kind=NEW_REQ;s0.work.client=2'(chosen);s0.work.req=req[chosen];s0.set_idx=SW'(req[chosen].addr);end
                end
            end
        end
    end
    always_comb begin
        s1_hit=0;s1_way=0;
        for(int w=0;w<WAYS;w++) if(meta_read_q[w].valid && meta_read_q[w].tag==TW'(s1_q.work.req.addr>>SW)) begin s1_hit=1;s1_way=w;end
        if(s1_q.kind==SLOT_TASK) s1_way=int'(s1_q.work.way);
    end
    // All S2 mutations share the sole meta/data write ports.
    always_comb begin
        meta_write=0;data_write=0;plru_write=0;write_way=s2_way_q;plru_way=s2_way_q;
        meta_new=s2_meta_q[s2_way_q];data_new=data_read_q;
        slot_alloc=0;alloc_work=s2_q.work;slot_done=0;done_result=L2_FINISHED;done_owner=0;
        accept_req=0;reject_req=0;rsp_push=0;rsp_new='0;rsp_client=int'(s2_q.work.client);
        wb_push=0;wb_addr=s2_q.work.victim_addr;wb_data=data_read_q;probe_release=0;
        base=s2_meta_q[s2_way_q];contents=data_read_q;finish_req=0;consume_answer=0;
        victim_way=victim(s2_plru_q);
        for(int w=WAYS-1;w>=0;w--) if(!s2_meta_q[w].valid) victim_way=w;
        if(s2_valid_q) begin
            case(s2_q.kind)
                PUT_TASK:begin
                    assert(s2_hit_q && base.sharer) else $fatal(1,"Put must hit a directory sharer");
                    meta_new.sharer=0;meta_new.state=DIR_NONE;meta_write=1;
                    if(s2_q.put.has_data) begin
                        assert(base.state==DIR_UNIQUE);data_write=1;data_new=s2_q.put.data;meta_new.dirty=1;
                    end
                    rsp_push=1;rsp_new.op=COH_PUTACK;rsp_new.id=s2_q.put.id;
                end
                NEW_REQ:begin
                    if(!s2_hit_q || (s2_q.work.req.op==COH_READ && base.state==DIR_UNIQUE) ||
                        (s2_q.work.req.op==COH_MASKWRITE && base.state!=DIR_NONE)) begin
                        if(slot_free) begin
                            slot_alloc=1;accept_req=1;alloc_work.is_probe=s2_hit_q;
                            alloc_work.way=L2_WAY_W'(s2_hit_q ? s2_way_q:victim_way);
                            alloc_work.victim_valid=!s2_hit_q && s2_meta_q[victim_way].valid;
                            alloc_work.victim_addr=coh_addr_t'({s2_meta_q[victim_way].tag,s2_q.set_idx});
                            alloc_work.probe_op=s2_q.work.req.op==COH_READ ? COH_DOWN:COH_INV;
                            alloc_work.probe_owner=base.state==DIR_UNIQUE;alloc_work.collected=0;
                        end else reject_req=1;
                    end else begin accept_req=1;finish_req=1;end
                end
                SLOT_TASK:begin
                    slot_done=1;
                    if(s2_q.work.collected) begin
                        assert(answer_valid_q);
                        if(s2_q.work.probe_op==COH_INV) begin base.sharer=0;base.state=DIR_NONE;end
                        else base.state=base.sharer ? DIR_SHARED:DIR_NONE;
                        if(answer_q.has_data) begin contents=answer_q.data;base.dirty=1;end
                    end
                    case(s2_q.work.task_kind)
                        L2_EVICT:begin
                            if(base.sharer) begin done_result=L2_NEED_PROBE;done_owner=base.state==DIR_UNIQUE;end
                            else if(base.dirty && !wb_free) done_result=L2_RETRY;
                            else begin
                                done_result=L2_EVICT_DONE;meta_write=1;meta_new='0;
                                if(base.dirty) begin wb_push=1;wb_data=contents;end
                                consume_answer=s2_q.work.collected;
                            end
                        end
                        L2_INSTALL:begin
                            if(s2_q.work.error) begin
                                rsp_push=1;rsp_new.error=1;rsp_new.id=s2_q.work.req.id;
                                rsp_new.op=s2_q.work.req.op==COH_READ ? COH_READDATA:
                                    s2_q.work.req.op==COH_MASKWRITE ? COH_WRITEACK:COH_DATAE;
                            end else begin
                                base='0;base.valid=1;base.tag=TW'(s2_q.work.req.addr>>SW);
                                contents=s2_q.work.refill;data_write=1;data_new=contents;finish_req=1;
                            end
                        end
                        L2_REPLAY:begin
                            assert(s2_hit_q);finish_req=1;consume_answer=1;
                            if(answer_q.has_data) begin data_write=1;data_new=contents;end
                        end
                        default:;
                    endcase
                end
                default:;
            endcase
        end
        if(finish_req) begin
            rsp_push=1;rsp_new.id=s2_q.work.req.id;rsp_new.data=contents;
            meta_write=1;meta_new=base;plru_write=1;
            case(s2_q.work.req.op)
                COH_GETS:begin
                    assert(base.state==DIR_NONE) else $fatal(1,"GetS from an existing sharer");
                    meta_new.state=DIR_UNIQUE;meta_new.sharer=1;rsp_new.op=COH_DATAE;
                end
                COH_GETM:begin
                    assert(base.state==DIR_NONE || base.state==DIR_SHARED) else $fatal(1,"GetM from owner");
                    meta_new.state=DIR_UNIQUE;meta_new.sharer=1;
                    rsp_new.op=base.state==DIR_SHARED ? COH_ACKE:COH_DATAE;
                end
                COH_READ:begin assert(base.state!=DIR_UNIQUE);rsp_new.op=COH_READDATA;end
                COH_MASKWRITE:begin
                    assert(base.state==DIR_NONE);data_write=1;data_new=contents;
                    for(int b=0;b<ICACHE_LINE_BYTES;b++) if(s2_q.work.req.mask[b]) data_new[b*8+:8]=s2_q.work.req.data[b*8+:8];
                    meta_new.dirty=1;rsp_new.op=COH_WRITEACK;
                end
                default:;
            endcase
        end
        probe_release=consume_answer;
        for(int c=0;c<3;c++) begin
            req_ready[c]=s2_valid_q && s2_q.kind==NEW_REQ && int'(s2_q.work.client)==c && accept_req;
            rsp_valid[c]=out_count_q[c]!=0;rsp[c]=out_q[c][out_head_q[c]];
        end
        perf_o='0;
        perf_o[BE_L2_HIT]=BE_PERF_INC_W'(s2_valid_q && s2_q.kind==NEW_REQ && accept_req && s2_hit_q);
        perf_o[BE_L2_MISS]=BE_PERF_INC_W'(s2_valid_q && s2_q.kind==NEW_REQ && accept_req && !s2_hit_q);
        perf_o[BE_L2_SLOT_FULL]=BE_PERF_INC_W'(reject_req);
        perf_o[BE_L2_PROBE]=BE_PERF_INC_W'(snp_valid_o && snp_ready_i);
        perf_o[BE_L2_WRITEBACK]=BE_PERF_INC_W'(wb_push);
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            init_done_q<=0;init_set_q<=0;s1_valid_q<=0;s2_valid_q<=0;s1_q<='0;s2_q<='0;
            meta_read_q<='{default:'0};s2_meta_q<='{default:'0};plru_read_q<=0;s2_plru_q<=0;data_read_q<=0;
            s2_hit_q<=0;s2_way_q<=0;in_pipe_q<='{default:0};slot_wait_q<='{default:0};
            req_rr_q<=0;put_rr_q<=0;task_rr_q<=0;put_valid_q<='{default:0};put_pipe_q<='{default:0};put_q<='{default:'0};
            answer_valid_q<=0;answer_q<='0;out_head_q<='{default:0};out_tail_q<='{default:0};out_count_q<='{default:0};
        end else begin
            if(!init_done_q) begin
                for(int w=0;w<WAYS;w++) meta_q[init_set_q][w]<='0;
                plru_q[init_set_q]<=0;
                if(init_set_q==SETS-1) init_done_q<=1;else init_set_q<=init_set_q+1;
            end
            s1_valid_q<=s0_valid;s1_q<=s0;
            if(s0_valid) begin
                for(int w=0;w<WAYS;w++) meta_read_q[w]<=meta_q[s0.set_idx][w];
                plru_read_q<=plru_q[s0.set_idx];
                case(s0.kind)
                    NEW_REQ:begin in_pipe_q[s0.work.client]<=1;req_rr_q<=(int'(s0.work.client)+1)%3;end
                    PUT_TASK:begin put_pipe_q[s0.put.id]<=1;put_rr_q<=(int'(s0.put.id)+1)%CFG.l2.put_buffers;end
                    SLOT_TASK:task_rr_q<=(int'(s0.work.slot)+1)%N;
                    default:;
                endcase
            end
            s2_valid_q<=s1_valid_q;s2_q<=s1_q;s2_hit_q<=s1_hit;s2_way_q<=s1_way;
            s2_meta_q<=meta_read_q;s2_plru_q<=plru_read_q;
            if(s1_valid_q && (s1_hit || s1_q.kind==SLOT_TASK)) data_read_q<=data_q[int'(s1_q.set_idx)*WAYS+s1_way];
            if(meta_write) begin
                meta_q[s2_q.set_idx][write_way]<=meta_new;
                assert((meta_new.state==DIR_NONE)==!meta_new.sharer);
            end
            if(data_write) data_q[int'(s2_q.set_idx)*WAYS+write_way]<=data_new;
            if(plru_write) plru_q[s2_q.set_idx]<=touch(s2_plru_q,plru_way);
            if(s2_valid_q && s2_q.kind==NEW_REQ) begin
                in_pipe_q[s2_q.work.client]<=0;
                if(reject_req) slot_wait_q[s2_q.work.client]<=1;
            end
            if(slot_released) slot_wait_q<='{default:0};
            if(s2_valid_q && s2_q.kind==PUT_TASK) begin put_valid_q[s2_q.put.id]<=0;put_pipe_q[s2_q.put.id]<=0;end
            if(consume_answer) answer_valid_q<=0;
            if(rsp_up_valid_i) begin
                if(rsp_up_i.op==COH_PUT) begin
                    assert(int'(rsp_up_i.id)<CFG.l2.put_buffers && !put_valid_q[rsp_up_i.id]);
                    put_valid_q[rsp_up_i.id]<=1;put_q[rsp_up_i.id]<=rsp_up_i;
                end else begin assert(!answer_valid_q);answer_valid_q<=1;answer_q<=rsp_up_i;end
            end
            for(int c=0;c<3;c++) begin
                if(rsp_valid[c] && rsp_ready[c]) out_head_q[c]<=(out_head_q[c]+1)%fifo_depth(c);
                if(rsp_push && rsp_client==c) begin
                    assert(out_count_q[c]<fifo_depth(c));out_q[c][out_tail_q[c]]<=rsp_new;
                    out_tail_q[c]<=(out_tail_q[c]+1)%fifo_depth(c);
                end
                out_count_q[c]<=out_count_q[c]+int'(rsp_push && rsp_client==c)-int'(rsp_valid[c] && rsp_ready[c]);
                if($past(req_valid[c] && !req_ready[c] && !rst)) assert(req_valid[c] && $stable(req[c]));
                if(req_valid[c]) begin
                    if(c==0) assert(req[c].op==COH_GETS || req[c].op==COH_GETM);
                    if(c==1) assert(req[c].op==COH_READ);
                end
            end
            if(s0_valid && meta_write) assert(s0.set_idx!=s2_q.set_idx);
        end
    end
    initial begin
        assert(o3_cfg_pkg::O3_CFG.core.mem_paddr_bits==32);
        assert(WAYS>=2 && (WAYS&(WAYS-1))==0 && SETS>=2 && (SETS&(SETS-1))==0);
        assert(CFG.l2.put_buffers==2 && N<=o3_cfg_pkg::O3_CFG.be.l2.slots);
    end
endmodule
