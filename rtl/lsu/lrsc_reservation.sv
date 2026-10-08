/** Y3/Y4: exact registered PA/size pairing, line conflicts, bounded probe window.
 * Clear has priority over LR set; the check never depends on combinational clears. */
module lrsc_reservation import o3_types_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG
)(input logic clk,rst,set_i,input paddr_t set_paddr_i,input logic [1:0] set_size_i,
  input paddr_t check_paddr_i,input logic [1:0] check_size_i,output logic check_ok_o,
  input logic clear_i,input logic conflict_i,input coh_addr_t conflict_line_i,
  output logic valid_o,window_o,output coh_addr_t line_o,output paddr_t addr_o,output logic [1:0] size_o);
    logic valid_q; paddr_t addr_q; logic [1:0] size_q; int unsigned timer_q;
    assign addr_o=addr_q;assign size_o=size_q;
    assign valid_o=valid_q; assign line_o=coh_addr_t'(addr_q>>6);
    assign window_o=valid_q && timer_q!=0;
    assign check_ok_o=valid_q && addr_q==check_paddr_i && size_q==check_size_i;
    always_ff @(posedge clk) begin
        if(rst) begin valid_q<=0;addr_q<=0;size_q<=0;timer_q<=0;end
        else begin
            if(timer_q!=0) timer_q<=timer_q-1;
            if(set_i) begin valid_q<=1;addr_q<=set_paddr_i;size_q<=set_size_i;timer_q<=CFG.dcache.rsv_window;end
            if(clear_i || (conflict_i && line_o==conflict_line_i)) begin valid_q<=0;timer_q<=0;end
        end
    end
endmodule
