module icache_tb_top
    import o3_types_pkg::*;
(
    input logic clk,
    input logic rst,
    input logic [1:0] priv_i,
    input logic [127:0] pmpcfg_i,
    input logic [863:0] pmpaddr_i,
    input logic pf_valid,input paddr_t pf_addr,input logic [7:0] pf_epoch,epoch_i,
    output logic pf_ready,output logic [2:0] pf_status,
    output fe_perf_t perf_o,
    input logic probe_valid,input vaddr_t probe_va,output logic probe_grant,probe_resp,probe_hit,
    input logic req_valid,
    output logic req_ready,
    input logic [VADDR_W-1:0] req_pc,
    input logic [$bits(ftq_id_t)-1:0] req_ftq_id,
    input logic [$bits(rq_idx_t)-1:0] req_rq_idx,
    output logic resp_valid,
    output logic [$bits(ftq_id_t)-1:0] resp_ftq_id,
    output logic [$bits(rq_idx_t)-1:0] resp_rq_idx,
    output logic [REGION_BYTES*8-1:0] resp_data,
    output logic resp_exc,
    output logic l2_req_valid,
    input logic l2_req_ready,
    output logic [PADDR_W-1:0] l2_req_addr,
    input logic l2_resp_valid,
    output logic l2_resp_ready,
    input logic [ICACHE_LINE_BYTES*8-1:0] l2_resp_data,
    input coh_id_t l2_resp_id,
    output coh_id_t l2_req_id,
    input logic l2_resp_error,
    input logic inv_all,
    output logic idle,
    output logic inv_done,
    output logic [7:0] cfg_banks,
    output logic [7:0] cfg_sets_per_bank,
    output logic [7:0] cfg_ways,
    output logic [7:0] cfg_region_bytes
);
    icache_req_t req;
    icache_resp_t resp;
    coh_req_t l2_req;
    coh_rsp_down_t l2_resp;
    pmp_state_t pmp;pf_resp_t pf_resp;xprobe_resp_t probe;
    always_comb begin
        pmp='0;
        for(int n=0;n<PMP_N;n++) begin
            pmp.entries[n].cfg=pmpcfg_i[n*8+:8];
            pmp.entries[n].addr=pmpaddr_i[n*54+:54];
        end
        pmp.dec=pmp_decode(pmp.entries);
    end
    assign pf_status=pf_resp.status;assign probe_resp=probe.valid;assign probe_hit=probe.hit;
    assign req = '{region_base:req_pc, ftq_id:req_ftq_id,
                   rq_idx:req_rq_idx, epoch:'0};
    assign l2_resp='{op:COH_READDATA,id:l2_resp_id,data:l2_resp_data,error:l2_resp_error,default:'0};
    assign resp_valid = resp.valid;
    assign resp_ftq_id = resp.ftq_id;
    assign resp_rq_idx = resp.rq_idx;
    assign resp_data = resp.data;
    assign resp_exc = resp.exc_valid;
    assign l2_req_addr = PADDR_W'(l2_req.addr)<<6;
    assign l2_req_id=l2_req.id;
    assign cfg_banks = 8'(o3_cfg_pkg::O3_CFG.fe.icache.banks);
    assign cfg_sets_per_bank = 8'(o3_cfg_pkg::O3_CFG.fe.icache.sets
                                   / o3_cfg_pkg::O3_CFG.fe.icache.banks);
    assign cfg_ways = 8'(o3_cfg_pkg::O3_CFG.fe.icache.ways);
    assign cfg_region_bytes = 8'(o3_cfg_pkg::O3_CFG.fe.fetch.region_bytes);

    ICache #(.CFG(o3_cfg_pkg::O3_CFG.fe)) dut (
        .clk(clk), .rst(rst),
        .flush(1'b0), .kill(1'b0), .s0_valid(1'b0),
        .s0_ready(), .s0_pc('0),
        .refill_req_valid(), .refill_req_pc(),
        .refill_resp_valid(1'b0), .refill_resp_pc('0),
        .refill_resp_error(1'b0), .refill_resp_data('0),
        .out_valid(), .out_hit(), .out_pc(), .out_data(), .out_error(),
        .req_valid_i(req_valid), .req_ready_o(req_ready), .req_i(req), .resp_o(resp),
        .pf_req_valid_i(pf_valid), .pf_req_ready_o(pf_ready), .pf_req_i('{line_vaddr:64'(pf_addr),line_paddr:pf_addr,paddr_valid:1'b1,asid:'0,epoch:xlate_epoch_t'(pf_epoch)}), .pf_resp_o(pf_resp),
        .xprobe_valid_i(probe_valid),.xprobe_vaddr_i(probe_va),.xprobe_grant_o(probe_grant),.xprobe_resp_o(probe),.xlate_fill_o(),
        .ptw_req_valid_o(), .ptw_req_ready_i(1'b0), .ptw_req_o(), .ptw_resp_i('0),
        .l2_req_valid_o(l2_req_valid), .l2_req_ready_i(l2_req_ready),
        .l2_req_o(l2_req), .l2_resp_valid_i(l2_resp_valid), .l2_resp_i(l2_resp), .l2_resp_ready_o(l2_resp_ready),
        .csr_i('{priv:priv_i,epoch:xlate_epoch_t'(epoch_i),default:'0}), .pmp_i(pmp), .pmp_update_done_o(),
        .sfence_i('0), .sfence_done_o(),
        .inv_all_i(inv_all), .inv_done_o(inv_done), .idle_o(idle),
        .perf_o(perf_o)
    );
endmodule
