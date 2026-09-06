/**
 * Single-issue Load/Store execution unit with DTCM and external memory
 *
 * 输入已经完成PRF读取；组合AGU产生字节地址。Store把地址/数据/mask写入SQ并
 * 立即向ROB报告执行完成。Load先查询更老Store：完整覆盖则转发，未知或部分
 * 重叠则保持输入，其他情况在committed Store优先的单端口上按地址选择DTCM或
 * 外部memory。DTCM固定一拍返回；外部口允许可变延迟，但仍只允许一个Load在飞。
 * 两类响应都进入可保持的load_result_q，获得共享PRF写口后离开。
 *
 * 周期N组合阶段完成AGU、依赖判断和memory仲裁；上升沿锁存pending/load result；
 * 周期N+1可看到DTCM响应；外部响应在任意后续周期握手。错误路径pending响应会由
 * LQ generation和branch mask共同丢弃。本阶段没有MSHR/PMA/MMU/精确访问异常。
 */
module load_store_unit
    import o3_pkg::*;
#(
    parameter int DATA_SRAM_BYTES = DTCM_SIZE_BYTES,
    parameter logic [XLEN-1:0] DATA_SRAM_BASE = DTCM_BASE_ADDR
) (
    input logic clk,
    input logic rst,
    input mem_execute_uop_t mem_uop_i,
    output logic mem_ready_o,

    output logic lq_execute_valid_o,
    output logic [LQ_IDX_WIDTH-1:0] lq_execute_idx_o,
    output logic [XLEN-1:0] lq_execute_addr_o,
    input logic lq_execute_generation_i,
    output logic lq_request_fire_o,
    output logic [LQ_IDX_WIDTH-1:0] lq_request_idx_o,
    output logic lq_response_valid_o,
    output logic [LQ_IDX_WIDTH:0] lq_response_tag_o,
    input logic lq_response_live_i,

    output logic sq_execute_valid_o,
    output logic [SQ_IDX_WIDTH-1:0] sq_execute_idx_o,
    output logic [XLEN-1:0] sq_execute_addr_o,
    output logic [XLEN-1:0] sq_execute_data_o,
    output logic [7:0] sq_execute_mask_o,
    output logic sq_query_valid_o,
    output logic [ROB_IDX_WIDTH-1:0] sq_query_rob_idx_o,
    output logic [XLEN-1:0] sq_query_addr_o,
    output logic [7:0] sq_query_mask_o,
    input logic sq_query_block_i,
    input logic sq_query_forward_valid_i,
    input logic [XLEN-1:0] sq_query_forward_data_i,
    input logic sq_drain_valid_i,
    output logic sq_drain_ready_o,
    input logic [XLEN-1:0] sq_drain_addr_i,
    input logic [XLEN-1:0] sq_drain_data_i,
    input logic [7:0] sq_drain_mask_i,

    output logic store_complete_valid_o,
    output logic [ROB_IDX_WIDTH-1:0] store_complete_rob_idx_o,
    output load_result_t load_result_o,
    input logic load_result_ready_i,

    input logic resolution_valid_i,
    input logic resolution_mispredict_i,
    input branch_tag_t resolution_tag_i,

    input logic dtcm_init_valid_i,
    input logic [XLEN-1:0] dtcm_init_addr_i,
    input logic [XLEN-1:0] dtcm_init_wdata_i,
    input logic [7:0] dtcm_init_wmask_i,

    output logic ext_req_valid_o,
    input logic ext_req_ready_i,
    output logic ext_req_write_o,
    output logic [XLEN-1:0] ext_req_addr_o,
    output logic [XLEN-1:0] ext_req_wdata_o,
    output logic [7:0] ext_req_wmask_o,
    input logic ext_rsp_valid_i,
    output logic ext_rsp_ready_o,
    input logic [XLEN-1:0] ext_rsp_rdata_i,
    input logic ext_rsp_error_i
);
    localparam int SRAM_TAG_WIDTH = LQ_IDX_WIDTH + 1;
    logic [XLEN-1:0] effective_addr;
    logic [7:0] access_mask;
    logic load_can_forward, load_can_request;
    logic load_forward_fire, load_request_fire;
    logic sram_req_valid, sram_req_ready, sram_req_write;
    logic [XLEN-1:0] sram_req_addr, sram_req_wdata;
    logic [7:0] sram_req_wmask;
    logic [SRAM_TAG_WIDTH-1:0] sram_req_tag;
    logic sram_rsp_valid, sram_rsp_ready;
    logic [XLEN-1:0] sram_rsp_rdata;
    logic memory_req_valid, memory_req_write, memory_req_targets_dtcm;
    logic memory_req_ready;
    logic memory_rsp_valid, memory_rsp_ready, memory_rsp_error;
    logic [XLEN-1:0] memory_rsp_rdata;

    logic pending_valid_q;
    logic [INST_ID_WIDTH-1:0] pending_instruction_id_q;
`ifdef O3_SIM
    logic [63:0] pending_kanata_id_q;
`endif
    logic [ROB_IDX_WIDTH-1:0] pending_rob_idx_q;
    logic [LQ_IDX_WIDTH-1:0] pending_lq_idx_q;
    logic [PREG_IDX_WIDTH-1:0] pending_dst_preg_q;
    mem_size_t pending_mem_size_q;
    logic pending_mem_unsigned_q;
    branch_mask_t pending_branch_mask_q;
    logic pending_external_q;
    logic [SRAM_TAG_WIDTH-1:0] pending_response_tag_q;
    load_result_t load_result_q;

    function automatic logic access_in_dtcm(
        input logic [XLEN-1:0] addr,
        input logic [7:0] mask
    );
        logic all_bytes_local;
        begin
            all_bytes_local = 1'b1;
            for (int byte_idx = 0; byte_idx < 8; byte_idx++) begin
                if (mask[byte_idx]
                 && !(((addr + XLEN'(byte_idx)) >= DATA_SRAM_BASE)
                   && ((addr + XLEN'(byte_idx))
                       < (DATA_SRAM_BASE + XLEN'(DATA_SRAM_BYTES))))) begin
                    all_bytes_local = 1'b0;
                end
            end
            access_in_dtcm = all_bytes_local;
        end
    endfunction

    function automatic logic [7:0] size_mask(input mem_size_t size);
        case (size)
            MEM_SIZE_1B: size_mask = 8'b0000_0001;
            MEM_SIZE_2B: size_mask = 8'b0000_0011;
            MEM_SIZE_4B: size_mask = 8'b0000_1111;
            default:     size_mask = 8'b1111_1111;
        endcase
    endfunction

    function automatic logic [XLEN-1:0] format_load(
        input logic [XLEN-1:0] raw,
        input mem_size_t size,
        input logic is_unsigned
    );
        case (size)
            MEM_SIZE_1B: format_load = is_unsigned
                                     ? XLEN'(raw[7:0])
                                     : XLEN'($signed(raw[7:0]));
            MEM_SIZE_2B: format_load = is_unsigned
                                     ? XLEN'(raw[15:0])
                                     : XLEN'($signed(raw[15:0]));
            MEM_SIZE_4B: format_load = is_unsigned
                                     ? XLEN'(raw[31:0])
                                     : XLEN'($signed(raw[31:0]));
            default:     format_load = raw;
        endcase
    endfunction

    function automatic logic killed(input branch_mask_t mask);
        killed = resolution_valid_i && resolution_mispredict_i
              && mask[resolution_tag_i];
    endfunction

    function automatic branch_mask_t resolved_mask(input branch_mask_t mask);
        branch_mask_t result;
        begin
            result = mask;
            if (resolution_valid_i) result[resolution_tag_i] = 1'b0;
            resolved_mask = result;
        end
    endfunction

    assign effective_addr = mem_uop_i.base_value + mem_uop_i.imm_value;
    assign access_mask = size_mask(mem_uop_i.mem_size);
    assign load_result_o = load_result_q;

    assign lq_execute_valid_o = mem_uop_i.valid && mem_uop_i.is_load
                              && !killed(mem_uop_i.branch_mask);
    assign lq_execute_idx_o = mem_uop_i.lq_idx;
    assign lq_execute_addr_o = effective_addr;
    assign sq_query_valid_o = lq_execute_valid_o;
    assign sq_query_rob_idx_o = mem_uop_i.rob_idx;
    assign sq_query_addr_o = effective_addr;
    assign sq_query_mask_o = access_mask;

    assign load_can_forward = lq_execute_valid_o && !sq_query_block_i
                            && sq_query_forward_valid_i
                            && (!load_result_q.valid || load_result_ready_i);
    assign load_can_request = lq_execute_valid_o && !sq_query_block_i
                            && !sq_query_forward_valid_i && !pending_valid_q;
    assign load_forward_fire = load_can_forward;

    // committed Store永远优先占用本拍统一请求口；完整落在DTCM窗口内才访问本地
    // SRAM，否则整笔事务交给外部memory，跨边界请求不会拆成两笔。
    assign memory_req_valid = sq_drain_valid_i || load_can_request;
    assign memory_req_write = sq_drain_valid_i;
    assign sram_req_addr = sq_drain_valid_i ? sq_drain_addr_i : effective_addr;
    assign sram_req_wdata = sq_drain_valid_i ? sq_drain_data_i : '0;
    assign sram_req_wmask = sq_drain_valid_i ? sq_drain_mask_i : access_mask;
    assign sram_req_tag = {lq_execute_generation_i, mem_uop_i.lq_idx};
    assign memory_req_targets_dtcm = access_in_dtcm(sram_req_addr, sram_req_wmask);
    assign sram_req_valid = memory_req_valid && memory_req_targets_dtcm;
    assign sram_req_write = memory_req_write;
    assign ext_req_valid_o = memory_req_valid && !memory_req_targets_dtcm;
    assign ext_req_write_o = memory_req_write;
    assign ext_req_addr_o = sram_req_addr;
    assign ext_req_wdata_o = sram_req_wdata;
    assign ext_req_wmask_o = sram_req_wmask;
    assign memory_req_ready = memory_req_targets_dtcm ? sram_req_ready : ext_req_ready_i;
    assign sq_drain_ready_o = sq_drain_valid_i && memory_req_ready;
    assign load_request_fire = load_can_request && !sq_drain_valid_i && memory_req_ready;
    assign lq_request_fire_o = load_request_fire;
    assign lq_request_idx_o = mem_uop_i.lq_idx;

    // Store在SQ成功接收AGU结果后即可离开；Load在转发或目标memory请求握手后离开。
    assign mem_ready_o = !mem_uop_i.valid
                       || (mem_uop_i.is_store && !killed(mem_uop_i.branch_mask))
                       || load_forward_fire || load_request_fire
                       || killed(mem_uop_i.branch_mask);
    assign sq_execute_valid_o = mem_uop_i.valid && mem_uop_i.is_store
                              && mem_ready_o && !killed(mem_uop_i.branch_mask);
    assign sq_execute_idx_o = mem_uop_i.sq_idx;
    assign sq_execute_addr_o = effective_addr;
    assign sq_execute_data_o = mem_uop_i.store_value;
    assign sq_execute_mask_o = access_mask;
    assign store_complete_valid_o = sq_execute_valid_o;
    assign store_complete_rob_idx_o = mem_uop_i.rob_idx;

    assign memory_rsp_valid = pending_external_q ? ext_rsp_valid_i : sram_rsp_valid;
    assign memory_rsp_rdata = pending_external_q ? ext_rsp_rdata_i : sram_rsp_rdata;
    assign memory_rsp_error = pending_external_q && ext_rsp_error_i;
    assign memory_rsp_ready = !memory_rsp_valid || !lq_response_live_i
                            || killed(pending_branch_mask_q)
                            || !load_result_q.valid || load_result_ready_i;
    assign sram_rsp_ready = !pending_external_q && memory_rsp_ready;
    assign ext_rsp_ready_o = pending_external_q && memory_rsp_ready;
    assign lq_response_valid_o = memory_rsp_valid;
    assign lq_response_tag_o = pending_response_tag_q;

    simple_data_sram #(
        .DEPTH_BYTES(DATA_SRAM_BYTES),
        .BASE_ADDR(DATA_SRAM_BASE),
        .TAG_WIDTH(SRAM_TAG_WIDTH)
    ) u_data_sram (
        .clk(clk), .rst(rst),
        .req_valid_i(sram_req_valid), .req_ready_o(sram_req_ready),
        .req_write_i(sram_req_write), .req_addr_i(sram_req_addr),
        .req_wdata_i(sram_req_wdata), .req_wmask_i(sram_req_wmask),
        .req_tag_i(sram_req_tag),
        .init_valid_i(dtcm_init_valid_i), .init_addr_i(dtcm_init_addr_i),
        .init_wdata_i(dtcm_init_wdata_i), .init_wmask_i(dtcm_init_wmask_i),
        .rsp_valid_o(sram_rsp_valid), .rsp_ready_i(sram_rsp_ready),
        .rsp_rdata_o(sram_rsp_rdata), .rsp_tag_o()
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            pending_valid_q <= 1'b0;
            pending_instruction_id_q <= '0;
`ifdef O3_SIM
            pending_kanata_id_q <= '0;
`endif
            pending_rob_idx_q <= '0;
            pending_lq_idx_q <= '0;
            pending_dst_preg_q <= '0;
            pending_mem_size_q <= MEM_SIZE_1B;
            pending_mem_unsigned_q <= 1'b0;
            pending_branch_mask_q <= '0;
            pending_external_q <= 1'b0;
            pending_response_tag_q <= '0;
            load_result_q <= '0;
        end else begin
            if (load_result_q.valid && load_result_ready_i) begin
                load_result_q.valid <= 1'b0;
            end
            if (resolution_valid_i) begin
                load_result_q.branch_mask[resolution_tag_i] <= 1'b0;
                pending_branch_mask_q[resolution_tag_i] <= 1'b0;
                if (resolution_mispredict_i
                 && load_result_q.branch_mask[resolution_tag_i]) begin
                    load_result_q.valid <= 1'b0;
                end
            end

            if (load_request_fire) begin
                pending_valid_q <= 1'b1;
                pending_instruction_id_q <= mem_uop_i.instruction_id;
`ifdef O3_SIM
                pending_kanata_id_q <= mem_uop_i.kanata_id;
`endif
                pending_rob_idx_q <= mem_uop_i.rob_idx;
                pending_lq_idx_q <= mem_uop_i.lq_idx;
                pending_dst_preg_q <= mem_uop_i.dst_preg;
                pending_mem_size_q <= mem_uop_i.mem_size;
                pending_mem_unsigned_q <= mem_uop_i.mem_unsigned;
                pending_branch_mask_q <= resolved_mask(mem_uop_i.branch_mask);
                pending_external_q <= !memory_req_targets_dtcm;
                pending_response_tag_q <= sram_req_tag;
            end

            if (memory_rsp_valid && memory_rsp_ready) begin
                pending_valid_q <= 1'b0;
                if (pending_valid_q && lq_response_live_i
                 && !killed(pending_branch_mask_q)) begin
                    load_result_q.valid <= 1'b1;
                    load_result_q.instruction_id <= pending_instruction_id_q;
`ifdef O3_SIM
                    load_result_q.kanata_id <= pending_kanata_id_q;
`endif
                    load_result_q.rob_idx <= pending_rob_idx_q;
                    load_result_q.lq_idx <= pending_lq_idx_q;
                    load_result_q.dst_preg <= pending_dst_preg_q;
                    load_result_q.result <= format_load(
                        memory_rsp_error ? '0 : memory_rsp_rdata,
                        pending_mem_size_q, pending_mem_unsigned_q);
                    load_result_q.branch_mask <= resolved_mask(pending_branch_mask_q);
                end
            end

            if (load_forward_fire) begin
                load_result_q.valid <= 1'b1;
                load_result_q.instruction_id <= mem_uop_i.instruction_id;
`ifdef O3_SIM
                load_result_q.kanata_id <= mem_uop_i.kanata_id;
`endif
                load_result_q.rob_idx <= mem_uop_i.rob_idx;
                load_result_q.lq_idx <= mem_uop_i.lq_idx;
                load_result_q.dst_preg <= mem_uop_i.dst_preg;
                load_result_q.result <= format_load(
                    sq_query_forward_data_i, mem_uop_i.mem_size, mem_uop_i.mem_unsigned);
                load_result_q.branch_mask <= resolved_mask(mem_uop_i.branch_mask);
            end
        end
    end
endmodule
