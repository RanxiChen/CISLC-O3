/** L10 X11: S2 samples range candidates; S3 picks the lowest matching entry.
 * N: match every byte against frozen CSR state. Edge N: register candidates
 * and permissions. N+1: priority/permission result; stall preserves that item.
 * Current implementation: target implementation. Tests: sim/cocotb/pmp_checker/.
 */
module pmp_checker import o3_types_pkg::*; #(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
)(input logic clk_i,rst_i,s2_valid_i, input paddr_t s2_paddr_i,
  input logic stall_i, input logic [6:0] bytes_i,
  input logic read_i,write_i,exec_i,
  output logic s3_valid_o,s3_allow_o,s3_fault_o,
  input pmp_state_t cfg_i, input logic [1:0] priv_i,
  output logic cfg_update_done_o);
    logic [PMP_N-1:0] match_q,allow_q;
    logic default_q;
    assign cfg_update_done_o=cfg_i.update;
    always_comb begin
        s3_allow_o=default_q;
        for (int n=PMP_N-1;n>=0;n--) if(match_q[n]) s3_allow_o=allow_q[n];
        s3_fault_o=s3_valid_o && !s3_allow_o;
    end
    always_ff @(posedge clk_i) begin
        if(rst_i) begin s3_valid_o<=0; match_q<=0; allow_q<=0; default_q<=0; end
        else if(!stall_i) begin
            s3_valid_o<=s2_valid_i; default_q<=priv_i==PRIV_M;
            for(int n=0;n<PMP_N;n++) begin
                match_q[n]<=cfg_i.entries[n].cfg[4:3]!=0 &&
                    {1'b0,s2_paddr_i}<pmp_upper(cfg_i,n) &&
                    ({1'b0,s2_paddr_i}+57'(bytes_i))>pmp_lower(cfg_i,n);
                allow_q[n]<={1'b0,s2_paddr_i}>=pmp_lower(cfg_i,n) &&
                    ({1'b0,s2_paddr_i}+57'(bytes_i))<=pmp_upper(cfg_i,n) &&
                    ((priv_i==PRIV_M && !cfg_i.entries[n].cfg[7]) ||
                     ((!read_i || cfg_i.entries[n].cfg[0]) &&
                      (!write_i || cfg_i.entries[n].cfg[1]) &&
                      (!exec_i || cfg_i.entries[n].cfg[2])));
            end
        end
    end
endmodule
