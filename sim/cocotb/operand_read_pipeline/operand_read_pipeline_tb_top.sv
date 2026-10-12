module operand_read_pipeline_tb_top import o3_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG=o3_cfg_pkg::O3_CFG.be,
    localparam int INT_SOURCES=CFG.exec.num_alu+2,
    localparam int MEM_BASE=INT_SOURCES,
    localparam int FP_BASE=MEM_BASE+CFG.lsu.agu_pipes+1,
    localparam int SOURCES=FP_BASE+5,
    localparam int INT_PORTS=CFG.exec.int_prf_read_ports,
    localparam int FP_PORTS=CFG.exec.fp_prf_read_ports
)(
    input logic clk,rst,flush_i,block_i,kill_i,correct_i,
    input logic [ROB_IDX_WIDTH-1:0] head_i,
    input logic [SOURCES-1:0] valid_i,pending_ready_i,read_ready_i,delivery_ready_i,need1_i,need2_i,need3_i,fp_int_i,store_fp_i,
    input logic [SOURCES*16-1:0] identity_i,
    input logic [SOURCES*ROB_IDX_WIDTH-1:0] rob_i,
    input logic [SOURCES*$bits(branch_mask_t)-1:0] mask_i,
    input logic [SOURCES*PREG_IDX_WIDTH-1:0] src1_i,src2_i,src3_i,
    output logic [SOURCES-1:0] take_o,grant_o,pending_valid_o,read_valid_o,
    output logic [SOURCES*16-1:0] pending_identity_o,read_identity_o,
    output logic [SOURCES*$bits(branch_mask_t)-1:0] read_mask_o,
    output logic [SOURCES*3-1:0] port1_o,port2_o,
    output logic [5*3-1:0] fp_base_o,
    output logic [INT_PORTS*PREG_IDX_WIDTH-1:0] int_addr_o,
    output logic [FP_PORTS*PREG_IDX_WIDTH-1:0] fp_addr_o,
    output logic [SOURCES-1:0] delivery_grant_o,delivery_valid_o,
    output logic [SOURCES*16-1:0] delivery_identity_o,
    output logic [SOURCES*$bits(branch_mask_t)-1:0] delivery_mask_o,
    output logic [SOURCES*XLEN-1:0] operand1_o,operand2_o,operand3_o,
    output int sources_o,rob_entries_o,preg_width_o,mask_width_o,rob_width_o,int_ports_o,mem_source_base_o,mem_sources_o,fp_source_base_o,fp_ports_o,fp_read_sets_o,fp_store_base_o,num_fma_o,request_slots_o,capture_slots_o
);
    renamed_uop_t [SOURCES-1:0] request,pending,read_uop,delivery;
    branch_resolution_t resolution;
    logic [$clog2(INT_PORTS)-1:0] port1[SOURCES],port2[SOURCES];
    logic [2:0] fp_base[5];
    logic [PREG_IDX_WIDTH-1:0] int_addr[INT_PORTS-1:0],fp_addr[FP_PORTS];
    logic [XLEN-1:0] int_data[INT_PORTS-1:0],fp_data[FP_PORTS],operand1[SOURCES],operand2[SOURCES],operand3[SOURCES];
    always_comb begin
        resolution='0;resolution.valid=kill_i || correct_i;resolution.mispredict=kill_i;
        request='0;
        for(int src=0;src<SOURCES;src++) begin
            request[src].valid=valid_i[src];request[src].instruction_id=identity_i[src*16+:16];
            request[src].rob_idx=rob_i[src*ROB_IDX_WIDTH+:ROB_IDX_WIDTH];
            request[src].branch_mask=mask_i[src*$bits(branch_mask_t)+:$bits(branch_mask_t)];
            request[src].src1_preg=src1_i[src*PREG_IDX_WIDTH+:PREG_IDX_WIDTH];
            request[src].src2_preg=src2_i[src*PREG_IDX_WIDTH+:PREG_IDX_WIDTH];
            request[src].rext.src3_preg=src3_i[src*PREG_IDX_WIDTH+:PREG_IDX_WIDTH];
            request[src].rs1_read_en=need1_i[src];request[src].rs2_read_en=need2_i[src];
            request[src].ext.rs3_read_en=need3_i[src];
            request[src].ext.rs1_dom=(src>=FP_BASE && !fp_int_i[src]) ? o3_types_pkg::RD_FP:o3_types_pkg::RD_INT;
            request[src].ext.rs2_dom=(src>=FP_BASE || store_fp_i[src]) ? o3_types_pkg::RD_FP:o3_types_pkg::RD_INT;
            pending_valid_o[src]=pending[src].valid;read_valid_o[src]=read_uop[src].valid;
            pending_identity_o[src*16+:16]=pending[src].instruction_id;
            read_identity_o[src*16+:16]=read_uop[src].instruction_id;
            read_mask_o[src*$bits(branch_mask_t)+:$bits(branch_mask_t)]=read_uop[src].branch_mask;
            port1_o[src*3+:3]=3'(port1[src]);port2_o[src*3+:3]=3'(port2[src]);
            delivery_valid_o[src]=delivery[src].valid;
            delivery_identity_o[src*16+:16]=delivery[src].instruction_id;
            delivery_mask_o[src*$bits(branch_mask_t)+:$bits(branch_mask_t)]=delivery[src].branch_mask;
            operand1_o[src*XLEN+:XLEN]=operand1[src];
            operand2_o[src*XLEN+:XLEN]=operand2[src];
            operand3_o[src*XLEN+:XLEN]=operand3[src];
        end
        for(int fu=0;fu<5;fu++) fp_base_o[fu*3+:3]=fp_base[fu];
        for(int p=0;p<INT_PORTS;p++) begin
            int_addr_o[p*PREG_IDX_WIDTH+:PREG_IDX_WIDTH]=int_addr[p];int_data[p]=64'h1000+XLEN'(int_addr[p]);
        end
        for(int p=0;p<FP_PORTS;p++) begin
            fp_addr_o[p*PREG_IDX_WIDTH+:PREG_IDX_WIDTH]=fp_addr[p];fp_data[p]=64'h2000+XLEN'(fp_addr[p]);
        end
    end
    assign sources_o=SOURCES;assign rob_entries_o=CFG.rob.entries;assign preg_width_o=PREG_IDX_WIDTH;
    assign mask_width_o=$bits(branch_mask_t);assign rob_width_o=ROB_IDX_WIDTH;assign int_ports_o=INT_PORTS;
    assign mem_source_base_o=MEM_BASE;assign mem_sources_o=CFG.lsu.agu_pipes;assign fp_source_base_o=FP_BASE;
    assign fp_ports_o=FP_PORTS;assign fp_read_sets_o=(FP_PORTS-CFG.lsu.agu_pipes)/3;
    assign fp_store_base_o=FP_PORTS-CFG.lsu.agu_pipes;assign num_fma_o=CFG.exec.num_fma;
    assign request_slots_o=u_dut.REQUEST_SLOTS;assign capture_slots_o=u_dut.CAPTURE_SLOTS;
    operand_read_pipeline #(.CFG(CFG)) u_dut(
        .clk(clk),.rst(rst),.flush_i(flush_i),.issue_block_i(block_i),.rob_head_i(head_i),.resolution_i(resolution),
        .request_uop_i(request),.request_valid_i(valid_i),.request_take_o(take_o),
        .pending_uop_o(pending),.pending_eligible_i(pending_ready_i),.read_uop_o(read_uop),
        .read_eligible_i(read_ready_i),.read_grant_o(grant_o),.src1_port_o(port1),.src2_port_o(port2),
        .fp_base_o(fp_base),.int_addr_o(int_addr),.fp_addr_o(fp_addr),.int_data_i(int_data),.fp_data_i(fp_data),
        .operand_uop_o(delivery),.operand_ready_i(delivery_ready_i),.operand_grant_o(delivery_grant_o),
        .operand_src1_o(operand1),.operand_src2_o(operand2),.operand_src3_o(operand3));
endmodule
