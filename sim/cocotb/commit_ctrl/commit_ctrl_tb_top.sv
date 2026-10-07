module commit_ctrl_tb_top import o3_types_pkg::*; (
 output logic clean_req_o,clean_ack_o,
 input logic head_needs_d_i,d_ready_i,d_done_i,output logic d_req_o,
 input logic ptw_idle_i,sf_ack_i,
 output logic sf_valid_o,
 input logic [1:0] priv_i,
 input logic [63:0] status_i,
 input logic irq_i,refetch_i,wfi_stall_i,
 input logic [2:0] refetch_kind_i,
 output logic [2:0] redirect_kind_o,
 output logic [63:0] trap_epc_o,
 output logic trap_irq_o,trap_xret_o,wfi_retire_o,
 input logic clk,rst,head_valid_i,head_exc_i,head_serial_i,head_csr_i,csr_resp_valid_i,csr_illegal_i,
 input logic [3:0] sysop_i,input logic [63:0] pc_i,target_i,input logic [3:0] commit_valid_i,
 input logic sq_empty_i,sync_ready_i,sync_done_i,trap_redirect_i,
 output logic csr_req_o,serial_done_o,trap_o,flush_o,block_o,sync_o,redirect_o,
 output logic [63:0] committed_pc_o,output logic [3:0] ftq_valid_o);
 // Public L1D clean compatibility handshake: next-cycle ack, no scan.
 always_ff @(posedge clk) if(rst) clean_ack_o<=0;else clean_ack_o<=clean_req_o;
 sfence_req_t sf;
 assign sf_valid_o=sf.valid;
 rob_commit_t head,commits[3:0];csr_resp_t resp;ftq_commit_t ftq[4];trap_req_t trap;sys_redirect_t redir;
 always_comb begin
 head='0;head.needs_d=head_needs_d_i;head.is_store=head_needs_d_i;head.valid=head_valid_i;head.pc=pc_i;head.complete=1;head.exc.valid=head_exc_i;
 head.exc.cause=exception_cause_t'(11);head.ext.serialize=head_serial_i;
 head.ext.csr_op=head_csr_i ? CSROP_RW : CSROP_NONE;head.sys_op=sys_op_e'(sysop_i);head.ext.fence_pred=4'h1;
 resp='0;resp.valid=csr_resp_valid_i;resp.illegal=csr_illegal_i;resp.needs_refetch=refetch_i;resp.refetch_kind=sys_redirect_kind_e'(refetch_kind_i);
 for(int i=0;i<4;i++)begin commits[i]=head;commits[i].valid=commit_valid_i[i];
 commits[i].succ_pc=vaddr_t'(pc_i+64'(4*(i+1)));commits[i].region_last=1;end
 end
 for(genvar i=0;i<4;i++) assign ftq_valid_o[i]=ftq[i].valid;
 assign redirect_kind_o=redir.kind;assign trap_epc_o=trap.epc;assign trap_irq_o=trap.is_interrupt;assign trap_xret_o=trap.is_xret;
 assign trap_o=trap.valid;assign redirect_o=redir.valid;
 commit_ctrl #(.CFG(o3_cfg_pkg::O3_CFG.be)) dut(.clk(clk),.rst(rst),.boot_pc_i(64'h80000000),
 .commit_i(commits),.head_valid_i(head_valid_i),.head_i(head),.head_serial_done_o(serial_done_o),.commit_block_o(block_o),
 .ftq_commit_o(ftq),.sq_commit_valid_o(),.sq_commit_idx_o(),.fp_retire_o(),.committed_next_pc_o(committed_pc_o),
 .sys_redirect_o(redir),.fe_sync_valid_o(sync_o),.fe_sync_ready_i(sync_ready_i),.fe_sync_o(),.fe_sync_done_i(sync_done_i),
 .sq_committed_empty_i(sq_empty_i),.dcache_clean_all_o(clean_req_o),.dcache_clean_all_done_i(clean_ack_o),.dcache_clean_all_busy_i(1'b0),
 .sfence_o(sf),.sfence_done_i(sf_ack_i),.ptw_idle_i(ptw_idle_i),.st_d_req_valid_o(d_req_o),.st_d_req_ready_i(d_ready_i),.st_d_done_i(d_done_i),
 .csr_req_valid_o(csr_req_o),.csr_req_o(),.csr_resp_i(resp),.csr_operand_i(64'd3),.block_younger_cycle_i(1'b0),
 .priv_i(priv_i),.status_i(status_i),.irq_cause_i(IRQ_MSI),.irq_take_i(irq_i),.trap_req_o(trap),.trap_redirect_valid_i(trap_redirect_i),.trap_redirect_pc_i(target_i),
 .rsv_clear_valid_o(),.rsv_clear_reason_o(),.wfi_retire_o(wfi_retire_o),.wfi_stall_i(wfi_stall_i),.isolate_i(1'b0),.flush_all_o(flush_o),.perf_o());
endmodule
