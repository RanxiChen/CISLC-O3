// Read-only whole-core monitor enabled by +L7_CHECK. L7 U11/U13 + L10 3.3.
// Retains all prior producer/aggregation/state assertions; extends the reference,
// rather than masking DUT flags or suppressing assertions for the new program.
// Independent state starts at reset; no producer or counter state is modified.
module l10_event_checks import o3_types_pkg::*; (
 input logic clk_i,rst_i,input fe_perf_t fe_sources_i[9],input be_perf_t be_sources_i[4],
 input fe_perf_t fe_frontend_i,fe_core_i,fe_backend_i,fe_csr_i,fe_hpm_i,
 input be_perf_t be_backend_i,be_hpm_i,
 input logic req_valid_i,trap_i,input csr_req_t req_i,
 input logic [2:0] retired_i,input logic [63:0] cycle_i,instret_i,
 input logic [63:0] counters_i[8],selectors_i[8],input logic [1:0] priv_i,
 input logic [31:0] inhibit_i,input redirect_req_t accepted_i,input logic busy_i
);
 logic [63:0] expected_cycle,expected_instret,expected[8];
 logic [63:0] selector[8];logic [31:0] inhibit;
 logic [63:0] sum_fe[PE_NUM],sum_be[BE_PERF_NUM];
 always_comb begin
  for(int e=0;e<PE_NUM;e++) begin
   sum_fe[e]=0;
   for(int p=0;p<9;p++) sum_fe[e]+=64'(fe_sources_i[p][e]);
  end
  for(int e=0;e<BE_PERF_NUM;e++) begin
   sum_be[e]=0;
   for(int p=0;p<4;p++) sum_be[e]+=64'(be_sources_i[p][e]);
  end
 end
 function automatic logic [63:0] increment(input logic [15:0] s);
  int e;e=int'(s[7:0]);
  if(s[15:8]==1 && ((e>=1&&e<=21)||(e>=32&&e<52))) return sum_fe[e];
  if(s[15:8]==2 && e>=1 && e<38) return sum_be[e];
  return 0;
 endfunction
 always @(posedge clk_i) begin : reference
  logic [63:0] old_value,new_value;
  logic [64:0] next_count;
  logic [7:0] wrapped;
  if(rst_i) begin
   expected_cycle=0;expected_instret=0;inhibit=0;
   for(int n=0;n<8;n++) begin expected[n]=0;selector[n]=0;end
  end else if($test$plusargs("L7_CHECK")) begin
   assert(fe_frontend_i==fe_core_i && fe_core_i==fe_backend_i
          && fe_backend_i==fe_csr_i && fe_csr_i==fe_hpm_i)
     else $fatal(1,"L7 FE event wire mismatch");
   assert(be_backend_i==be_hpm_i) else $fatal(1,"L7 BE event wire mismatch");
   for(int e=0;e<PE_NUM;e++) begin
    assert(sum_fe[e]<(64'd1<<PERF_INC_W)) else $fatal(1,"L7 FE increment overflow event %0d",e);
    assert(sum_fe[e]==64'(fe_frontend_i[e])) else $fatal(1,"L7 FE aggregation event %0d",e);
   end
   for(int e=0;e<BE_PERF_NUM;e++)
    assert(sum_be[e]==64'(be_backend_i[e])) else $fatal(1,"L7 BE aggregation event %0d",e);
   assert(sum_fe[PE_RECOVER_CYCLE]==64'(busy_i)) else $fatal(1,"L7 duplicated recovery cycle");
   assert(sum_fe[PE_PREDECODE_REDIRECT]==64'(accepted_i.valid && accepted_i.src==REDIR_PREDECODE));
   assert(sum_fe[PE_SLOW_OVERRIDE]==64'(accepted_i.valid && accepted_i.src==REDIR_SLOW));
   assert(sum_fe[PE_REDIRECT_EXEC]==64'(accepted_i.valid && accepted_i.src==REDIR_EXEC));
   assert(sum_fe[PE_REDIRECT_SYS]==64'(accepted_i.valid && accepted_i.src==REDIR_SYS));
   assert(sum_fe[PE_CMT_REGION]==sum_fe[PE_CMT_FAST_OK_SLOW_OK]+sum_fe[PE_CMT_FAST_OK_SLOW_BAD]
     +sum_fe[PE_CMT_FAST_BAD_SLOW_OK]+sum_fe[PE_CMT_FAST_BAD_SLOW_BAD]);
   assert(cycle_i==expected_cycle && instret_i==expected_instret && inhibit_i==inhibit)
     else $fatal(1,"L7 cycle/instret/inhibit state mismatch");
   for(int n=0;n<8;n++)
    assert(counters_i[n]==expected[n] && selectors_i[n]==selector[n])
      else $fatal(1,"L7 HPM%0d got=%0d expected=%0d",n+3,counters_i[n],expected[n]);
   // Compute RMW from pre-edge state, before accumulating this edge's events.
   old_value=0;
   case(req_i.addr)
    12'hb00:old_value=expected_cycle;
    12'hb02:old_value=expected_instret;
    12'h320:old_value=64'(inhibit);
    default: for(int n=0;n<8;n++) begin
     if(req_i.addr==12'(12'hb03+n)) old_value=expected[n];
     if(req_i.addr==12'(12'h323+n)) old_value=64'(selector[n]);
    end
   endcase
   case(req_i.op)
    CSROP_RS:new_value=old_value|req_i.wdata;
    CSROP_RC:new_value=old_value&~req_i.wdata;
    default:new_value=req_i.wdata;
   endcase
   if(!inhibit[0]) expected_cycle++;
   if(!inhibit[2]) expected_instret+=64'(retired_i);
   // L10 extends the existing independent model with privilege filtering and OF.
   wrapped=0;
   for(int n=0;n<8;n++) if(!inhibit[n+3] &&
     !((priv_i==3 && selector[n][62]) || (priv_i==1 && selector[n][61]) ||
       (priv_i==0 && selector[n][60]))) begin
    next_count={1'b0,expected[n]}+{1'b0,increment(selector[n][15:0])};
    expected[n]=next_count[63:0];
    if(next_count[64] && !(req_valid_i && !trap_i && req_i.write_en && req_i.addr==12'(12'hb03+n)))
     wrapped[n]=1;
   end
   if(req_valid_i && !trap_i && req_i.write_en) begin
    case(req_i.addr)
     12'hb00:expected_cycle=new_value;
     12'hb02:expected_instret=new_value;
     12'h320:inhibit=32'(new_value)&32'h7fd;
     default: for(int n=0;n<8;n++) begin
      if(req_i.addr==12'(12'hb03+n)) expected[n]=new_value;
      if(req_i.addr==12'(12'h323+n)) selector[n]=new_value & 64'hf00000000000ffff;
     end
    endcase
   end
   // Software supplies this edge's OF baseline; actual wrap sets it afterwards.
   for(int n=0;n<8;n++) if(wrapped[n]) selector[n][63]=1;
  end
 end
endmodule
