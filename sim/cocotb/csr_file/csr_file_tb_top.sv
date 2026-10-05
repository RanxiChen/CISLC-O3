module csr_file_tb_top import o3_types_pkg::*; (
 input logic clk,rst,req_valid_i,write_i,input logic [1:0] op_i,input logic [11:0] addr_i,
 input logic [63:0] data_i,input logic [2:0] retired_i,
 input logic trap_i,xret_i,input logic [5:0] cause_i,input logic [63:0] epc_i,tval_i,
 output logic [63:0] read_o,write_o,target_o,output logic valid_o,illegal_o,done_o);
 csr_req_t req;csr_resp_t resp;trap_req_t trap;
 always_comb begin req='{op:csr_op_e'(op_i),addr:addr_i,wdata:data_i,write_en:write_i,default:'0};
 trap='{valid:trap_i,is_xret:xret_i,is_mret:xret_i,cause:cause_i,epc:epc_i,tval:tval_i,default:'0};end
 assign read_o=resp.rdata;assign valid_o=resp.valid;assign illegal_o=resp.illegal;
 csr_file #(.CFG(o3_cfg_pkg::O3_CFG.be)) dut(.clk(clk),.rst(rst),.req_valid_i(req_valid_i),.req_i(req),.resp_o(resp),
 .retire_count_i(retired_i),.write_value_o(write_o),.fp_retire_i('0),.frm_o(),.fs_o(),
 .trap_update_valid_i(trap_i),.trap_update_i(trap),.trap_target_pc_o(target_o),.trap_update_done_o(done_o),
 .irq_m_ext_i(1'b0),.irq_m_timer_i(1'b0),.irq_m_soft_i(1'b0),.irq_s_ext_i(1'b0),
 .irq_view_o(),.irq_take_o(),.irq_cause_o(),.fe_csr_o(),.pmp_o(),.dmmu_csr_o(),.priv_o());
endmodule
