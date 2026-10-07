/**
 * Per-domain physical-register readiness (B02/B15/B33).
 * Reset marks initial architectural mappings ready in either domain. FP p0 is not
 * special. Accepted allocations clear readiness; only actual PRF grants set readiness.
 * Recovery needs no eager ready reset: reallocation clears returned registers.
 * B33 early wakeup for FP FUs is deferred to performance work; INT M promises remain.
 * 当前实现状态：闭环简化（L9）；lint/测试未运行。
 * N: expose current ready array. N edge: clear accepted destinations, then set granted
 * writes (distinct live identities). N+1: consumers observe updated readiness.
 */
module preg_ready_table
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    parameter  o3_types_pkg::reg_domain_e DOMAIN,           // RD_INT / RD_FP，无默认值
    localparam int ALLOC_WIDTH   = BACKEND_MACHINE_WIDTH,
    localparam int NUM_PHYS_REGS = (DOMAIN == o3_types_pkg::RD_FP) ? CFG.rename.fp_phys_regs
                                                                   : CFG.rename.int_phys_regs,
    localparam int WRITE_PORTS   = (DOMAIN == o3_types_pkg::RD_FP) ? CFG.exec.fp_prf_write_ports
                                                                   : CFG.exec.int_prf_write_ports
) (
    input  logic clk,
    input  logic rst,

    input  logic                      alloc_valid_i [ALLOC_WIDTH-1:0],
    input  logic [PREG_IDX_WIDTH-1:0] alloc_preg_i  [ALLOC_WIDTH-1:0],
    input  logic                      wr_en_i       [WRITE_PORTS-1:0],
    input  logic [PREG_IDX_WIDTH-1:0] wr_addr_i     [WRITE_PORTS-1:0],

    output logic                      ready_o [NUM_PHYS_REGS-1:0]
);

    logic preg_ready_q [NUM_PHYS_REGS-1:0];
    assign ready_o = preg_ready_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int preg = 0; preg < NUM_PHYS_REGS; preg++) begin
                preg_ready_q[preg] <= (preg < NUM_ARCH_REGS);
            end
        end else begin
            // rename 成功时，新分配的真实目的 preg 要先标记为 not-ready；
            // 写回阶段再把它置回 ready。这样 issue queue 才会等到真实结果返回再唤醒。
            for (int lane = 0; lane < ALLOC_WIDTH; lane++) begin
                if (alloc_valid_i[lane]) begin
                    preg_ready_q[alloc_preg_i[lane]] <= 1'b0;
                end
            end

            // 只有真正获得共享PRF写口的结果才变为全局ready并形成wakeup广播。
            for (int port = 0; port < WRITE_PORTS; port++) begin
                if (wr_en_i[port]) begin
                    preg_ready_q[wr_addr_i[port]] <= 1'b1;
                end
            end
        end
    end

endmodule
