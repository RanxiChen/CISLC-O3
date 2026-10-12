module writeback_transport_tb_top import o3_pkg::*; #(
    parameter int SOURCES=11,PORTS=2,DEPTH=3,
    localparam int SID_W=$clog2(SOURCES)>0?$clog2(SOURCES):1
)(input logic clk,rst,flush_i,
    input logic resolution_valid_i,resolution_mispredict_i,input branch_tag_t resolution_tag_i,
    input logic [SOURCES-1:0] src_valid_i,src_write_i,
    input logic [SOURCES*ROB_IDX_WIDTH-1:0] src_rob_i,
    input logic [SOURCES*PREG_IDX_WIDTH-1:0] src_preg_i,
    input logic [SOURCES*BACKEND_NUM_BRANCH_CHECKPOINTS-1:0] src_mask_i,
    input logic [SOURCES*64-1:0] src_data_i,input logic [SOURCES*5-1:0] src_flags_i,
    input logic [PORTS-1:0] write_i,port_ready_i,input logic [PORTS*SID_W-1:0] write_source_i,
    output logic admit_o,busy_o,output logic [PORTS-1:0] write_o,
    output logic [PORTS*PREG_IDX_WIDTH-1:0] addr_o,output logic [PORTS*64-1:0] data_o,
    output logic [SOURCES-1:0] complete_o,output logic [PORTS-1:0] bypass_o,
    output logic [SOURCES*ROB_IDX_WIDTH-1:0] complete_rob_o,
    output logic [SOURCES*PREG_IDX_WIDTH-1:0] complete_preg_o,
    output logic [SOURCES*BACKEND_NUM_BRANCH_CHECKPOINTS-1:0] complete_mask_o,
    output logic [SOURCES*64-1:0] complete_data_o,output logic [PORTS*64-1:0] bypass_data_o,
    output logic [SOURCES*5-1:0] complete_flags_o,
    output logic [47:0] widths_o);
    branch_resolution_t resolution;
    o3_types_pkg::wb_req_t src[SOURCES],done[SOURCES];o3_types_pkg::cpl_bypass_t bypass[PORTS];
    logic writes[PORTS],ready[PORTS],actual_writes[PORTS];logic [SID_W-1:0] owners[PORTS];
    logic [PREG_IDX_WIDTH-1:0] addresses[PORTS];logic [63:0] values[PORTS];
    always_comb begin
        resolution='0;resolution.valid=resolution_valid_i;resolution.mispredict=resolution_mispredict_i;resolution.branch_tag=resolution_tag_i;
        for(int s=0;s<SOURCES;s++) src[s]='{valid:src_valid_i[s],
            tag:'{rob_idx:src_rob_i[s*ROB_IDX_WIDTH+:ROB_IDX_WIDTH],br_mask:src_mask_i[s*BACKEND_NUM_BRANCH_CHECKPOINTS+:BACKEND_NUM_BRANCH_CHECKPOINTS],
                dst_dom:(SOURCES==1 ? o3_types_pkg::RD_FP:o3_types_pkg::RD_INT),dst_preg:src_preg_i[s*PREG_IDX_WIDTH+:PREG_IDX_WIDTH],dst_write_en:src_write_i[s]},
            data:src_data_i[s*64+:64],fflags:src_flags_i[s*5+:5]};
    end
    for(genvar p=0;p<PORTS;p++) begin
        assign writes[p]=write_i[p];assign ready[p]=port_ready_i[p];assign owners[p]=write_source_i[p*SID_W+:SID_W];
        assign write_o[p]=actual_writes[p];assign addr_o[p*PREG_IDX_WIDTH+:PREG_IDX_WIDTH]=addresses[p];assign data_o[p*64+:64]=values[p];
        assign bypass_o[p]=bypass[p].valid;assign bypass_data_o[p*64+:64]=bypass[p].data;
    end
    for(genvar s=0;s<SOURCES;s++) begin
        assign complete_o[s]=done[s].valid;
        assign complete_rob_o[s*ROB_IDX_WIDTH+:ROB_IDX_WIDTH]=done[s].tag.rob_idx;
        assign complete_preg_o[s*PREG_IDX_WIDTH+:PREG_IDX_WIDTH]=done[s].tag.dst_preg;
        assign complete_mask_o[s*BACKEND_NUM_BRANCH_CHECKPOINTS+:BACKEND_NUM_BRANCH_CHECKPOINTS]=done[s].tag.br_mask;
        assign complete_data_o[s*64+:64]=done[s].data;
        assign complete_flags_o[s*5+:5]=done[s].fflags;
    end
    assign widths_o={8'(SOURCES),8'(PORTS),8'(DEPTH),8'(ROB_IDX_WIDTH),8'(PREG_IDX_WIDTH),8'(BACKEND_NUM_BRANCH_CHECKPOINTS)};
    writeback_transport #(.SOURCES(SOURCES),.PORTS(PORTS),.DEPTH(DEPTH)) dut(
        .clk(clk),.rst(rst),.flush_i(flush_i),.resolution_i(resolution),.source_i(src),.write_i(writes),.write_source_i(owners),
        .admit_o(admit_o),.busy_o(busy_o),.port_ready_i(ready),.write_o(actual_writes),.addr_o(addresses),.data_o(values),.complete_o(done),.bypass_o(bypass));
endmodule
