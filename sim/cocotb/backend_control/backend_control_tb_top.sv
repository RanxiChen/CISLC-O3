// Scalar fetch stimulus and passive observers around the real backend. No forced state.
module backend_control_tb_top import o3_types_pkg::*; import o3_pkg::*; (
 input logic clk,rst,fetch_valid_i,
 input logic [ILEN-1:0] instruction_i [o3_cfg_pkg::O3_CFG.be.decode.width],
 input logic [PC_WIDTH-1:0] pc_i [o3_cfg_pkg::O3_CFG.be.decode.width],
 output logic fetch_ready_o,correct_o,mispredict_o,
 output logic [3:0] progress_o,
 output logic [31:0] cfg_width_o,
 output logic [o3_cfg_pkg::O3_CFG.core.commit_width-1:0] retire_valid_o,retire_write_o,commit_valid_o,
 output logic [PC_WIDTH-1:0] retire_pc_o [o3_cfg_pkg::O3_CFG.core.commit_width],
 output logic [XLEN-1:0] retire_data_o [o3_cfg_pkg::O3_CFG.core.commit_width],
 output logic [REG_ADDR_WIDTH-1:0] retire_rd_o [o3_cfg_pkg::O3_CFG.core.commit_width]
);
 localparam int W=o3_cfg_pkg::O3_CFG.be.decode.width;
 fetch_entry_t [W-1:0] entries;
 retire_info_t retire [o3_cfg_pkg::O3_CFG.core.commit_width-1:0];
 ftq_commit_t commit [o3_cfg_pkg::O3_CFG.core.commit_width];
 assign cfg_width_o=W;
 for(genvar i=0;i<W;i++) begin
  always_comb begin
   entries[i]='0;entries[i].valid=fetch_valid_i;
   entries[i].pc=pc_i[i];entries[i].instruction=instruction_i[i];
   entries[i].raw_instruction=instruction_i[i];entries[i].inst_len=4;
   entries[i].predicted_next_pc=pc_i[i]+4;
   entries[i].slot=fetch_slot_t'(i);entries[i].ftq_last=(i==W-1);
   entries[i].ftq_id.idx=FTQ_IDX_W'(pc_i[i]>>4);
  end
 end
 backend #(.CFG(o3_cfg_pkg::O3_CFG.be)) dut (
 .clk(clk),
 .rst(rst),
 .boot_pc_i(40'h80000000),
 .fetch_entry_i(entries),
 .fetch_valid_i(fetch_valid_i),
 .fe_redirect_i('0),
 .fe_sync_ready_i(1'b1),
 .fe_sync_done_i(1'b1),
 .itlb_ptw_req_valid_i('0),
 .itlb_ptw_req_i('0),
 .l2_req_ready_i(1'b1),
 .l2_resp_i('0),
 .l2_wb_ready_i(1'b1),
 .l2_wb_error_i('0),
 .l1d_probe_valid_i('0),
 .l1d_probe_i('0),
 .mtime_i(64'd0),.irq_m_ext_i('0),
 .irq_m_timer_i('0),
 .irq_m_soft_i('0),
 .irq_s_ext_i('0),
 .l2_fatal_i('0),
 .dtcm_init_valid_i('0),
 .dtcm_init_addr_i('0),
 .dtcm_init_wdata_i('0),
 .dtcm_init_wmask_i('0),
 .perf_rd_valid_i('0),
 .perf_rd_idx_i('0),
 .perf_clear_i('0),
 .perf_snapshot_i('0),
 .fetch_ready_o(fetch_ready_o),
 .retire_info_o(retire),
 .ftq_commit_o(commit)
 );
 assign correct_o=dut.exec_resolve_o.valid&&!dut.exec_resolve_o.mispredict;
 assign mispredict_o=dut.exec_resolve_o.valid&&dut.exec_resolve_o.mispredict;
 assign progress_o={dut.rename_accept_count!='0,dut.dispatch_accept_count!='0,
                    (|dut.int_read_grant)||dut.mem_read_grant||dut.branch_read_grant,
                    retire_valid_o!='0};
 for(genvar i=0;i<o3_cfg_pkg::O3_CFG.core.commit_width;i++) begin
  assign retire_valid_o[i]=retire[i].valid;assign retire_write_o[i]=retire[i].rd_write_en;
  assign retire_pc_o[i]=retire[i].pc;assign retire_data_o[i]=retire[i].rd_wdata;
  assign retire_rd_o[i]=retire[i].rd;assign commit_valid_o[i]=commit[i].valid;
 end
endmodule
