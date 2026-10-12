module recovery_boundary_tb_top import o3_types_pkg::*; (
    input logic clk,rst,cancel_i,redirect_valid_i,
    input logic [$bits(sys_redirect_t)-2:0] redirect_payload_i,
    output logic cancel_o,pending_o,redirect_valid_o,
    output logic [$bits(sys_redirect_t)-2:0] redirect_payload_o,
    input logic trap_valid_i,trap_done_i,
    input logic [63:0] trap_epc_i,trap_target_i,
    input logic [5:0] trap_cause_i,
    output logic trap_update_o,transport_busy_o,transport_cancel_o,transport_redirect_o,
    output logic [63:0] transport_pc_o,trap_update_epc_o,
    output logic [5:0] trap_update_cause_o
);
    sys_redirect_t req,resp;
    assign req=sys_redirect_t'({redirect_valid_i,redirect_payload_i});
    assign redirect_valid_o=resp.valid;
    assign redirect_payload_o=($bits(sys_redirect_t)-1)'(resp);
    recovery_boundary dut(.clk(clk),.rst(rst),.cancel_request_i(cancel_i),
        .redirect_request_i(req),
        .cancel_o(cancel_o),.pending_o(pending_o),.redirect_o(resp));

    // A second, real trap transport checks that the precise boundary remains
    // held continuously while cancellation, CSR update and target dispatch move.
    trap_req_t trap_req,trap_update;
    sys_redirect_t target_packet,transport_packet;
    logic target_valid,trap_busy,transport_pending;
    vaddr_t target_pc;
    always_comb begin
        trap_req='0;trap_req.valid=trap_valid_i;
        trap_req.epc=trap_epc_i;trap_req.cause=exception_cause_t'(trap_cause_i);
        target_packet='{valid:target_valid,kind:SYS_INTERRUPT,target_pc:target_pc,default:'0};
    end
    trap_ctrl #(.CFG(o3_cfg_pkg::O3_CFG.be)) transport(
        .clk(clk),.rst(rst),.req_i(trap_req),.csr_update_valid_o(trap_update_o),
        .csr_update_o(trap_update),.csr_target_pc_i(trap_target_i),.csr_update_done_i(trap_done_i),
        .redirect_valid_o(target_valid),.redirect_pc_o(target_pc),.busy_o(trap_busy));
    recovery_boundary dispatcher(.clk(clk),.rst(rst),.cancel_request_i(trap_req.valid),
        .redirect_request_i(target_packet),.cancel_o(transport_cancel_o),
        .pending_o(transport_pending),.redirect_o(transport_packet));
    assign transport_busy_o=trap_busy || transport_pending;
    assign transport_redirect_o=transport_packet.valid;
    assign transport_pc_o=transport_packet.target_pc;
    assign trap_update_epc_o=trap_update.epc;
    assign trap_update_cause_o=trap_update.cause;
endmodule
