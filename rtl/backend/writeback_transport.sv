/** Selected-result transport; W0 captures ownership, W1 writes PRF and ROB.
 * Three stationary packets cover registered admission without borrowing a
 * same-edge freed slot. Normal traffic advances one packet every cycle. A
 * reserved write port holds only its source; nonwriting completions and other
 * writes in the head packet may finish independently. No serial FSM.
 * Wide immutable results use single-write RAM. Mutable branch/valid metadata
 * cancels every packet and protects reused ROB/preg identities. Live head data
 * remains available for operand forwarding while a write port is reserved.
 * Functional validation is deferred until the backend refactor is complete.
 */
module writeback_transport import o3_pkg::*; #(
    parameter int SOURCES=11,PORTS=2,DEPTH=3,
    localparam int SOURCE_W=$clog2(SOURCES)>0?$clog2(SOURCES):1,
    localparam int PTR_W=$clog2(DEPTH)>0?$clog2(DEPTH):1,
    localparam int COUNT_W=$clog2(DEPTH+1)
)(
    input logic clk,rst,flush_i,input branch_resolution_t resolution_i,
    input o3_types_pkg::wb_req_t source_i[SOURCES],
    input logic write_i[PORTS],input logic [SOURCE_W-1:0] write_source_i[PORTS],
    output logic admit_o,busy_o,input logic port_ready_i[PORTS],
    output logic write_o[PORTS],output logic [PREG_IDX_WIDTH-1:0] addr_o[PORTS],output logic [63:0] data_o[PORTS],
    output o3_types_pkg::wb_req_t complete_o[SOURCES],output o3_types_pkg::cpl_bypass_t bypass_o[PORTS]
);
    typedef struct packed {
        o3_types_pkg::wb_req_t [SOURCES-1:0] source;
        logic [PORTS-1:0] write;
        logic [PORTS-1:0][SOURCE_W-1:0] write_source;
    } packet_t;
    (* ram_style="distributed" *) logic [$bits(packet_t)-1:0] packet_mem[DEPTH];
    logic [SOURCES-1:0] valid_q[DEPTH];branch_mask_t mask_q[DEPTH][SOURCES];
    logic [PTR_W-1:0] head_q,tail_q;logic [COUNT_W-1:0] count_q;
    packet_t incoming,head;logic push,pop;logic [SOURCES-1:0] live,remaining;
    assign admit_o=!rst && !flush_i && count_q<COUNT_W'(DEPTH);
    assign busy_o=count_q!=0;
    assign head=packet_t'(packet_mem[head_q]);
    always_comb begin
        incoming='0;push=0;
        for(int s=0;s<SOURCES;s++) begin
            incoming.source[s]=source_i[s];
            incoming.source[s].tag.br_mask=br_resolved_mask(source_i[s].tag.br_mask,resolution_i);
            push|=source_i[s].valid && !br_killed(source_i[s].tag.br_mask,resolution_i);
        end
        for(int p=0;p<PORTS;p++) begin incoming.write[p]=write_i[p];incoming.write_source[p]=write_source_i[p];end
        push&=admit_o;
        live='0;remaining='0;
        for(int s=0;s<SOURCES;s++) begin
            logic permitted;
            live[s]=count_q!=0 && valid_q[head_q][s] && !flush_i && !rst && !br_killed(mask_q[head_q][s],resolution_i);
            permitted=1;
            for(int p=0;p<PORTS;p++)
                if(head.write[p] && head.write_source[p]==SOURCE_W'(s)) permitted&=port_ready_i[p];
            complete_o[s]=head.source[s];complete_o[s].valid=live[s] && permitted;
            complete_o[s].tag.br_mask=br_resolved_mask(mask_q[head_q][s],resolution_i);
            remaining[s]=live[s] && !complete_o[s].valid;
        end
        for(int p=0;p<PORTS;p++) begin
            write_o[p]=count_q!=0 && head.write[p] && live[head.write_source[p]] && port_ready_i[p];
            addr_o[p]=head.source[head.write_source[p]].tag.dst_preg;
            data_o[p]=head.source[head.write_source[p]].data;
            bypass_o[p]='{valid:(count_q!=0 && head.write[p] && live[head.write_source[p]]),
                dom:head.source[head.write_source[p]].tag.dst_dom,
                preg:head.source[head.write_source[p]].tag.dst_preg,
                data:head.source[head.write_source[p]].data};
        end
        pop=count_q!=0 && !(|remaining);
    end
    always_ff @(posedge clk) if(push) packet_mem[tail_q]<=incoming;
    always_ff @(posedge clk) begin
        if(rst || flush_i) begin
            valid_q<='{default:'0};mask_q<='{default:'{default:'0}};
            head_q<='0;tail_q<='0;count_q<='0;
        end else begin
            for(int row=0;row<DEPTH;row++) for(int s=0;s<SOURCES;s++) begin
                if(br_killed(mask_q[row][s],resolution_i)) valid_q[row][s]<=0;
                mask_q[row][s]<=br_resolved_mask(mask_q[row][s],resolution_i);
                if(count_q!=0 && head_q==PTR_W'(row) && complete_o[s].valid) valid_q[row][s]<=0;
            end
            if(push) begin
                assert(admit_o);
                for(int s=0;s<SOURCES;s++) begin
                    valid_q[tail_q][s]<=source_i[s].valid && !br_killed(source_i[s].tag.br_mask,resolution_i);
                    mask_q[tail_q][s]<=br_resolved_mask(source_i[s].tag.br_mask,resolution_i);
                end
                tail_q<=PTR_W'((int'(tail_q)+1)%DEPTH);
            end
            if(pop) head_q<=PTR_W'((int'(head_q)+1)%DEPTH);
            count_q<=COUNT_W'(int'(count_q)+int'(push)-int'(pop));
            for(int p=0;p<PORTS;p++) if(write_o[p]) begin
                assert(complete_o[head.write_source[p]].valid);
                assert(head.source[head.write_source[p]].tag.dst_write_en);
            end
        end
    end
    initial assert(SOURCES>=1 && PORTS>=1 && DEPTH>=3);
endmodule
