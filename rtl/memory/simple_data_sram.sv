/**
 * Simple byte-addressable backend data SRAM
 *
 * 已实现：单请求端口、最多8字节写掩码、Load固定一拍响应以及响应反压。
 * Store在请求握手的上升沿修改字节数组；Load在请求握手的上升沿锁存读值，
 * 周期N+1通过rsp_valid_o返回。地址超出DEPTH_BYTES时Load返回0、Store忽略。
 *
 * 未实现：Cache、MSHR、PMA/MMU、ECC、初始化镜像、访问异常和真实宏单元时序。
 * 本模块只服务当前后端Load/Store闭环，不连接Frontend或ICache。
 */
module simple_data_sram
    import o3_pkg::*;
#(
    parameter int DEPTH_BYTES = 64 * 1024,
    parameter int TAG_WIDTH = LQ_IDX_WIDTH
) (
    input  logic                  clk,
    input  logic                  rst,
    input  logic                  req_valid_i,
    output logic                  req_ready_o,
    input  logic                  req_write_i,
    input  logic [XLEN-1:0]       req_addr_i,
    input  logic [XLEN-1:0]       req_wdata_i,
    input  logic [7:0]            req_wmask_i,
    input  logic [TAG_WIDTH-1:0]  req_tag_i,
    output logic                  rsp_valid_o,
    input  logic                  rsp_ready_i,
    output logic [XLEN-1:0]       rsp_rdata_o,
    output logic [TAG_WIDTH-1:0]  rsp_tag_o
);
    logic [7:0] mem_q [0:DEPTH_BYTES-1];
    logic rsp_valid_q;
    logic [XLEN-1:0] rsp_rdata_q;
    logic [TAG_WIDTH-1:0] rsp_tag_q;

    // Store没有返回包；Load只有在旧返回能够保留或同拍被消费时才可进入。
    assign req_ready_o = req_write_i || !rsp_valid_q || rsp_ready_i;
    assign rsp_valid_o = rsp_valid_q;
    assign rsp_rdata_o = rsp_rdata_q;
    assign rsp_tag_o = rsp_tag_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            rsp_valid_q <= 1'b0;
            rsp_rdata_q <= '0;
            rsp_tag_q <= '0;
        end else begin
            if (rsp_valid_q && rsp_ready_i) begin
                rsp_valid_q <= 1'b0;
            end

            if (req_valid_i && req_ready_o) begin
                if (req_write_i) begin
                    for (int byte_idx = 0; byte_idx < 8; byte_idx++) begin
                        if (req_wmask_i[byte_idx]
                         && ((req_addr_i + XLEN'(byte_idx)) < XLEN'(DEPTH_BYTES))) begin
                            mem_q[$clog2(DEPTH_BYTES)'(req_addr_i + XLEN'(byte_idx))]
                                <= req_wdata_i[(8*byte_idx) +: 8];
                        end
                    end
                end else begin
                    rsp_rdata_q <= '0;
                    for (int byte_idx = 0; byte_idx < 8; byte_idx++) begin
                        if ((req_addr_i + XLEN'(byte_idx)) < XLEN'(DEPTH_BYTES)) begin
                            rsp_rdata_q[(8*byte_idx) +: 8]
                                <= mem_q[$clog2(DEPTH_BYTES)'(req_addr_i + XLEN'(byte_idx))];
                        end
                    end
                    rsp_tag_q <= req_tag_i;
                    rsp_valid_q <= 1'b1;
                end
            end
        end
    end

    initial begin
        if (DEPTH_BYTES <= 0) $error("simple_data_sram requires DEPTH_BYTES > 0");
    end
endmodule
