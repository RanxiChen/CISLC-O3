module register_storage_tb_top import o3_pkg::*; #(
    parameter int IR=o3_cfg_pkg::O3_CFG.be.exec.int_prf_read_ports,
    localparam int FR=o3_cfg_pkg::O3_CFG.be.exec.fp_prf_read_ports,
    parameter int IW=o3_cfg_pkg::O3_CFG.be.exec.int_prf_write_ports,
    localparam int FW=o3_cfg_pkg::O3_CFG.be.exec.fp_prf_write_ports,
    localparam int AW=BACKEND_MACHINE_WIDTH,
    localparam int NI=o3_cfg_pkg::O3_CFG.be.rename.int_phys_regs,
    localparam int NF=o3_cfg_pkg::O3_CFG.be.rename.fp_phys_regs
)(input logic clk,rst,
 input logic [IR-1:0][PREG_IDX_WIDTH-1:0] int_rd_addr_i,
 input logic [FR-1:0][PREG_IDX_WIDTH-1:0] fp_rd_addr_i,
 output logic [IR-1:0][XLEN-1:0] int_rd_data_o,
 output logic [FR-1:0][XLEN-1:0] fp_rd_data_o,
 input logic [IW-1:0] int_wr_en_i,input logic [FW-1:0] fp_wr_en_i,
 input logic [IW-1:0][PREG_IDX_WIDTH-1:0] int_wr_addr_i,
 input logic [FW-1:0][PREG_IDX_WIDTH-1:0] fp_wr_addr_i,
 input logic [IW-1:0][XLEN-1:0] int_wr_data_i,
 input logic [FW-1:0][XLEN-1:0] fp_wr_data_i,
 input logic [AW-1:0] int_alloc_valid_i,fp_alloc_valid_i,
 input logic [AW-1:0][PREG_IDX_WIDTH-1:0] int_alloc_preg_i,fp_alloc_preg_i,
 output logic [NI-1:0] int_ready_o,output logic [NF-1:0] fp_ready_o,
 output logic [7:0] ir_o,fr_o,iw_o,fw_o,aw_o,ni_o,nf_o,preg_w_o);
 function automatic o3_cfg_pkg::backend_cfg_t storage_cfg();
    o3_cfg_pkg::backend_cfg_t result;
    result=o3_cfg_pkg::O3_CFG.be;
    result.exec.int_prf_read_ports=IR;result.exec.int_prf_write_ports=IW;
    return result;
 endfunction
 localparam o3_cfg_pkg::backend_cfg_t STORAGE_CFG=storage_cfg();
 logic [PREG_IDX_WIDTH-1:0] ir[IR],fr[FR],ia[IW],fa[FW],iap[AW-1:0],fap[AW-1:0];
 logic [PREG_IDX_WIDTH-1:0] irta[IW-1:0],frta[FW-1:0];
 logic [XLEN-1:0] id[IR],fd[FR],iwdata[IW],fwdata[FW];
 logic iwe[IW],fwe[FW],irte[IW-1:0],frte[FW-1:0],iav[AW-1:0],fav[AW-1:0];
 logic iready[NI-1:0],fready[NF-1:0];
 for(genvar n=0;n<IR;n++) begin assign ir[n]=int_rd_addr_i[n];assign int_rd_data_o[n]=id[n];end
 for(genvar n=0;n<FR;n++) begin assign fr[n]=fp_rd_addr_i[n];assign fp_rd_data_o[n]=fd[n];end
 for(genvar n=0;n<IW;n++) begin assign ia[n]=int_wr_addr_i[n];assign iwdata[n]=int_wr_data_i[n];assign iwe[n]=int_wr_en_i[n];assign irte[n]=int_wr_en_i[n];assign irta[n]=int_wr_addr_i[n];end
 for(genvar n=0;n<FW;n++) begin assign fa[n]=fp_wr_addr_i[n];assign fwdata[n]=fp_wr_data_i[n];assign fwe[n]=fp_wr_en_i[n];assign frte[n]=fp_wr_en_i[n];assign frta[n]=fp_wr_addr_i[n];end
 for(genvar n=0;n<AW;n++) begin assign iap[n]=int_alloc_preg_i[n];assign fap[n]=fp_alloc_preg_i[n];assign iav[n]=int_alloc_valid_i[n];assign fav[n]=fp_alloc_valid_i[n];end
 for(genvar n=0;n<NI;n++) assign int_ready_o[n]=iready[n];
 for(genvar n=0;n<NF;n++) assign fp_ready_o[n]=fready[n];
 physical_regfile #(.CFG(STORAGE_CFG),.DOMAIN(o3_types_pkg::RD_INT)) ip(.clk(clk),.rst(rst),.rd_addr_i(ir),.rd_data_o(id),.wr_en_i(iwe),.wr_addr_i(ia),.wr_data_i(iwdata));
 physical_regfile #(.CFG(STORAGE_CFG),.DOMAIN(o3_types_pkg::RD_FP)) fp(.clk(clk),.rst(rst),.rd_addr_i(fr),.rd_data_o(fd),.wr_en_i(fwe),.wr_addr_i(fa),.wr_data_i(fwdata));
 preg_ready_table #(.CFG(STORAGE_CFG),.DOMAIN(o3_types_pkg::RD_INT)) it(.clk(clk),.rst(rst),.alloc_valid_i(iav),.alloc_preg_i(iap),.wr_en_i(irte),.wr_addr_i(irta),.ready_o(iready));
 preg_ready_table #(.CFG(STORAGE_CFG),.DOMAIN(o3_types_pkg::RD_FP)) ft(.clk(clk),.rst(rst),.alloc_valid_i(fav),.alloc_preg_i(fap),.wr_en_i(frte),.wr_addr_i(frta),.ready_o(fready));
 assign ir_o=8'(IR);assign fr_o=8'(FR);assign iw_o=8'(IW);assign fw_o=8'(FW);
 assign aw_o=8'(AW);assign ni_o=8'(NI);assign nf_o=8'(NF);assign preg_w_o=8'(PREG_IDX_WIDTH);
endmodule
