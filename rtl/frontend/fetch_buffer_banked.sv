/** Ordered instruction FIFO: consecutive enqueue/dequeue positions are
 * interleaved across ENQ_WIDTH banks. Each bank has one asynchronous read
 * and one write; wide payload is never moved on dequeue or recovery.
 * Recovery must retain a program-order prefix, checked independently below.
 */
module fetch_buffer_banked import o3_types_pkg::*; #(
    parameter o3_cfg_pkg::frontend_cfg_t CFG,
    localparam int BANKS=CFG.fetch.f1_width,
    localparam int DEQ_WIDTH=CFG.fetch.deliver_width,
    localparam int DEPTH=CFG.fetch.ibuf_depth,
    localparam int ROWS=DEPTH/BANKS,
    localparam int PW=(DEPTH>1) ? $clog2(DEPTH):1,
    localparam int BW=(BANKS>1) ? $clog2(BANKS):1,
    localparam int RW=(ROWS>1) ? $clog2(ROWS):1,
    localparam int CW=$clog2(DEPTH+1)
)(
    input logic clk_i,rst_i,flush_i,
    input fetch_entry_t enq_entry_i[BANKS],
    input logic [BANKS-1:0] enq_valid_i,
    output logic enq_ready_o,
    output fetch_entry_t deq_entry_o[DEQ_WIDTH],
    output logic deq_valid_o,input logic deq_ready_i,
    output logic icache_req_allowed_o,
    input fe_kill_t kill_i,input ftq_id_t ftq_head_i,
    output fe_perf_t perf_o
);
    typedef logic [PW-1:0] ptr_t;
    typedef logic [CW-1:0] count_t;
    ptr_t head_q,tail_q,head_d,tail_d;
    count_t count_q,count_d,free_count,deq_count,enq_count,incoming,kept_count;
    logic pop;
    logic [BANKS-1:0] last_valid;
    logic [DEPTH-1:0] occupied,keep;
    ptr_t position[DEPTH];
    ftq_id_t identity_q[DEPTH];
    fetch_slot_t slot_q[DEPTH];
    fetch_entry_t bank_read[BANKS];
    assign free_count=count_t'(DEPTH)-count_q;
    assign enq_ready_o=!rst_i && !flush_i && !kill_i.valid && free_count>=count_t'(BANKS);
    assign deq_valid_o=!rst_i && !flush_i && !kill_i.valid && count_q!=0;
    assign deq_count=count_q>=count_t'(DEQ_WIDTH) ? count_t'(DEQ_WIDTH):count_q;
    assign icache_req_allowed_o=free_count>=count_t'(CFG.fetch.ibuf_req_free_threshold);
    assign pop=deq_valid_o && deq_ready_i;
    assign incoming=enq_ready_o ? enq_count:count_t'(0);
    assign perf_o='0;

    for(genvar lane=0;lane<BANKS;lane++) begin : g_prefix_count
        if(lane==BANKS-1) assign last_valid[lane]=enq_valid_i[lane];
        else assign last_valid[lane]=enq_valid_i[lane] && !enq_valid_i[lane+1];
    end
    always_comb begin
        enq_count='0;
        for(int lane=0;lane<BANKS;lane++)
            enq_count |= count_t'(lane+1) & {CW{last_valid[lane]}};
    end

    for(genvar bank=0;bank<BANKS;bank++) begin : g_bank
        logic [BW-1:0] write_lane,read_offset;
        ptr_t write_slot,read_slot;
        logic [RW-1:0] write_row,read_row;
        logic write_enable;
        (* ram_style="distributed" *) logic [$bits(fetch_entry_t)-1:0] mem[ROWS];
        if(BANKS==1) begin
            assign write_lane='0;assign read_offset='0;
        end else begin
            assign write_lane=BW'(bank)-BW'(tail_q);
            assign read_offset=BW'(bank)-BW'(head_q);
        end
        assign write_slot=tail_q+ptr_t'(write_lane);
        assign read_slot=head_q+ptr_t'(read_offset);
        assign write_row=RW'(write_slot >> $clog2(BANKS));
        assign read_row=RW'(read_slot >> $clog2(BANKS));
        assign write_enable=enq_ready_o && enq_valid_i[write_lane];
        always_ff @(posedge clk_i)
            if(write_enable) mem[write_row]<=enq_entry_i[write_lane];
        assign bank_read[bank]=fetch_entry_t'(mem[read_row]);
        // Recovery scans only these narrow identities; payload RAM has one
        // read address, rather than acquiring DEPTH associative read taps.
        for(genvar row=0;row<ROWS;row++) begin : g_identity
            localparam int SLOT=row*BANKS+bank;
            always_ff @(posedge clk_i)
                if(write_enable && write_row==RW'(row)) begin
                    identity_q[SLOT]<=enq_entry_i[write_lane].ftq_id;
                    slot_q[SLOT]<=enq_entry_i[write_lane].slot;
                end
        end
    end
    for(genvar lane=0;lane<DEQ_WIDTH;lane++) begin : g_dequeue
        logic [BW-1:0] bank;
        if(BANKS==1) assign bank='0;
        else assign bank=BW'(head_q)+BW'(lane);
        assign deq_entry_o[lane]=count_t'(lane)<deq_count ? bank_read[bank]:fetch_entry_t'(0);
    end
    for(genvar row=0;row<DEPTH;row++) begin : g_recovery
        assign position[row]=ptr_t'(row)-head_q;
        assign occupied[row]=count_t'(position[row])<count_q;
        assign keep[row]=occupied[row] && !fe_killed_by(kill_i,identity_q[row],slot_q[row],ftq_head_i);
    end
    // Balanced reduction; no serial priority/rank chain on the kill path.
    for(genvar level=0;level<=$clog2(DEPTH);level++) begin : g_keep_count
        count_t sum[DEPTH >> level];
        for(genvar node=0;node<(DEPTH >> level);node++) begin : g_node
            if(level==0) assign sum[node]=count_t'(keep[node]);
            else assign sum[node]=g_keep_count[level-1].sum[2*node]+g_keep_count[level-1].sum[2*node+1];
        end
    end
    assign kept_count=g_keep_count[$clog2(DEPTH)].sum[0];
    always_comb begin
        head_d=head_q+ptr_t'(pop ? deq_count:count_t'(0));
        tail_d=tail_q+ptr_t'(incoming);
        count_d=count_q+incoming-(pop ? deq_count:count_t'(0));
        if(kill_i.valid) begin
            head_d=head_q;count_d=kept_count;tail_d=head_q+ptr_t'(kept_count);
        end
        if(DEPTH==1) begin head_d=0;tail_d=0;end
        if(rst_i || flush_i) begin head_d=0;tail_d=0;count_d=0;end
    end
    always_ff @(posedge clk_i) begin
        head_q<=head_d;tail_q<=tail_d;count_q<=count_d;
        if(!rst_i) begin
            assert(count_q<=count_t'(DEPTH) && tail_q==(DEPTH==1 ? ptr_t'(0):head_q+ptr_t'(count_q)));
            if(enq_ready_o)
                for(int lane=1;lane<BANKS;lane++) assert(!enq_valid_i[lane] || enq_valid_i[lane-1]);
            if(kill_i.valid && !flush_i)
                for(int row=0;row<DEPTH;row++)
                    if(occupied[row]) assert(keep[row]==(count_t'(position[row])<kept_count))
                        else $fatal(1,"ordered instruction FIFO recovery must retain a prefix");
        end
    end
    initial begin
        assert(BANKS>0 && (BANKS & (BANKS-1))==0);
        assert(DEPTH>=BANKS && (DEPTH & (DEPTH-1))==0 && DEPTH%BANKS==0);
        assert(DEQ_WIDTH>0 && DEQ_WIDTH<=BANKS);
    end
endmodule
