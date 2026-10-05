module commit_ctrl_tb_top import o3_types_pkg::*; (
 input logic clk,rst,head_valid_i,head_exc_i,head_serial_i,head_csr_i,csr_resp_valid_i,csr_illegal_i,
 input logic [3:0] sysop_i,input logic [63:0] pc_i,target_i,input logic [3:0] commit_valid_i,
 input logic sq_empty_i,sync_ready_i,sync_done_i,trap_redirect_i,
 output logic csr_req_o,serial_done_o,trap_o,flush_o,block_o,sync_o,redirect_o,
 output logic [63:0] committed_pc_o,output logic [3:0] ftq_valid_o);
 rob_commit_t head,commits[3:0];csr_resp_t resp;ftq_commit_t ftq[4];trap_req_t trap;sys_redirect_t redir;
 always_comb begin
 head='0;head.valid=head_valid_i;head.pc=pc_i;head.complete=1;head.exc.valid=head_exc_i;
 head.exc.cause=exception_cause_t'(11);head.ext.serialize=head_serial_i;
 head.ext.csr_op=head_csr_i ? CSROP_RW : CSROP_NONE;head.sys_op=sys_op_e'(sysop_i);head.ext.fence_pred=4'h1;
 resp='0;resp.valid=csr_resp_valid_i;resp.illegal=csr_illegal_i;
 for(int i=0;i<4;i++)begin commits[i]=head;commits[i].valid=commit_valid_i[i];
 commits[i].succ_pc=vaddr_t'(pc_i+64'(4*(i+1)));commits[i].region_last=1;end
 end
 for(genvar i=0;i<4;i++) assign ftq_valid_o[i]=ftq[i].valid;
 assign trap_o=trap.valid;assign redirect_o=redir.valid;
 commit_ctrl #(.CFG(o3_cfg_pkg::O3_CFG.be)) dut(.clk(clk),.rst(rst),.boot_pc_i(64'h80000000),
 .commit_i(commits),.head_valid_i(head_valid_i),.head_i(head),.head_serial_done_o(serial_done_o),.commit_block_o(block_o),
 .ftq_commit_o(ftq),.sq_commit_valid_o(),.sq_commit_idx_o(),.fp_retire_o(),.committed_next_pc_o(committed_pc_o),
 .sys_redirect_o(redir),.fe_sync_valid_o(sync_o),.fe_sync_ready_i(sync_ready_i),.fe_sync_o(),.fe_sync_done_i(sync_done_i),
 .sq_committed_empty_i(sq_empty_i),.dcache_clean_all_o(),.dcache_clean_all_done_i(1'b0),.dcache_clean_all_busy_i(1'b0),
 .sfence_o(),.sfence_done_i(1'b0),.st_d_req_valid_o(),.st_d_req_ready_i(1'b0),.st_d_done_i(1'b0),
 .csr_req_valid_o(csr_req_o),.csr_req_o(),.csr_resp_i(resp),.csr_operand_i(64'd3),.block_younger_cycle_i(1'b0),
 .irq_take_i(1'b0),.trap_req_o(trap),.trap_redirect_valid_i(trap_redirect_i),.trap_redirect_pc_i(target_i),
 .rsv_clear_valid_o(),.rsv_clear_reason_o(),.wfi_retire_o(),.wfi_stall_i(1'b0),.isolate_i(1'b0),.flush_all_o(flush_o),.perf_o());
endmodule
