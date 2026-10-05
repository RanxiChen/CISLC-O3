// Scalar/vector observation wrapper; never changes DUT state.
module uop_queue_tb_top import o3_pkg::*; #(

    parameter  o3_cfg_pkg::backend_cfg_t CFG = o3_cfg_pkg::O3_CFG.be,
    localparam int ENQ_WIDTH = CFG.decode.width,          // 前端每拍最多交付 4 条
    localparam int DEQ_WIDTH = BACKEND_MACHINE_WIDTH,     // 现有 rename 前缀宽度；目标为 R1 宽度 CFG.rename.width
    localparam int DEPTH = CFG.decode.queue_depth,
    // 存储 bank 数取两侧宽度较大者，使任一侧连续 lane 落在不同 bank。
    localparam int NUM_BANKS = (ENQ_WIDTH > DEQ_WIDTH) ? ENQ_WIDTH : DEQ_WIDTH
) (
    input  logic                              clk,
    input  logic                              rst,
    input  logic                              flush_i,

    input  decoded_uop_t [ENQ_WIDTH-1:0]      enq_uop_i,
    input  logic                              enq_valid_i,
    output logic                              enq_ready_o,

    output decoded_uop_t [DEQ_WIDTH-1:0]      deq_uop_o,
    output logic [$clog2(DEQ_WIDTH+1)-1:0]    deq_count_o,
    input  logic [$clog2(DEQ_WIDTH+1)-1:0]    deq_accept_count_i
,
output logic [$bits(decoded_uop_t)-1:0] fmt_decoded_uop_t_valid,
output logic [$bits(decoded_uop_t)-1:0] fmt_decoded_uop_t_instruction_id,
output logic [$bits(decoded_uop_t)-1:0] fmt_decoded_uop_t_rd,
output logic [$bits(decoded_uop_t)-1:0] fmt_decoded_uop_t_rd_write_en,
output logic [$bits(decoded_uop_t)-1:0] fmt_decoded_uop_t_is_load,
output logic [$bits(decoded_uop_t)-1:0] fmt_decoded_uop_t_is_store,
output logic [$bits(decoded_uop_t)-1:0] fmt_decoded_uop_t_needs_checkpoint,
output logic [$bits(decoded_uop_t)-1:0] fmt_decoded_uop_t_ftq_id,
output logic [$bits(decoded_uop_t)-1:0] fmt_decoded_uop_t_ftq_last,
output logic [$bits(decoded_uop_t)-1:0] fmt_decoded_uop_t_ext_ftq_slot,
output logic [31:0] cfg_width_o, cfg_depth_o, cfg_rob_o, cfg_pregs_o, cfg_read_ports_o, cfg_tags_o
);
uop_queue #(.CFG(CFG)) dut (
.clk(clk),
.rst(rst),
.flush_i(flush_i),
.enq_uop_i(enq_uop_i),
.enq_valid_i(enq_valid_i),
.enq_ready_o(enq_ready_o),
.deq_uop_o(deq_uop_o),
.deq_count_o(deq_count_o),
.deq_accept_count_i(deq_accept_count_i)
);
always_comb begin decoded_uop_t v; v='0; v.valid='1; fmt_decoded_uop_t_valid=v; end
always_comb begin decoded_uop_t v; v='0; v.instruction_id='1; fmt_decoded_uop_t_instruction_id=v; end
always_comb begin decoded_uop_t v; v='0; v.rd='1; fmt_decoded_uop_t_rd=v; end
always_comb begin decoded_uop_t v; v='0; v.rd_write_en='1; fmt_decoded_uop_t_rd_write_en=v; end
always_comb begin decoded_uop_t v; v='0; v.is_load='1; fmt_decoded_uop_t_is_load=v; end
always_comb begin decoded_uop_t v; v='0; v.is_store='1; fmt_decoded_uop_t_is_store=v; end
always_comb begin decoded_uop_t v; v='0; v.needs_checkpoint='1; fmt_decoded_uop_t_needs_checkpoint=v; end
always_comb begin decoded_uop_t v; v='0; v.ftq_id='1; fmt_decoded_uop_t_ftq_id=v; end
always_comb begin decoded_uop_t v; v='0; v.ftq_last='1; fmt_decoded_uop_t_ftq_last=v; end
always_comb begin decoded_uop_t v; v='0; v.ext.ftq_slot='1; fmt_decoded_uop_t_ext_ftq_slot=v; end
assign cfg_width_o=BACKEND_MACHINE_WIDTH;
assign cfg_depth_o=CFG.decode.queue_depth;
assign cfg_rob_o=CFG.rob.entries;
assign cfg_pregs_o=CFG.rename.int_phys_regs;
assign cfg_read_ports_o=CFG.exec.int_prf_read_ports;
assign cfg_tags_o=CFG.rename.checkpoints;
endmodule
