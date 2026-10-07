/** DTLB: L10 Sv39. N lookup, N+1 result; one miss slot, hits continue.
 * Effective MPRV is supplied by CSR (only active in M). Each translation is
 * a request; the L8 split-access caller may issue a second page independently.
 * L10 single AGU; no speculative D writes. Tests: sim/cocotb/mmu/.
 */
module dtlb import o3_types_pkg::*; #(parameter o3_cfg_pkg::backend_cfg_t CFG,
    localparam int PORTS=CFG.lsu.agu_pipes)(
    input logic clk,rst,kill_i=1'b0,
    input logic lookup_valid_i[PORTS],input vaddr_t lookup_vaddr_i[PORTS],input logic lookup_is_store_i[PORTS],
    output logic resp_valid_o[PORTS],output tlb_resp_t resp_o[PORTS],
    output logic ptw_req_valid_o,input logic ptw_req_ready_i,output ptw_req_t ptw_req_o,input ptw_resp_t ptw_resp_i,
    input dmmu_csr_t csr_i,input sfence_req_t sfence_i,output logic sfence_done_o,output be_perf_t perf_o
);
    initial assert(CFG.mmu.dtlb_entries==32 && CFG.mmu.dtlb_ways==4) else $fatal(1,"L10 DTLB organization must match X4");
    // Current LSU uses port zero; extra AGUs are reserved for L8.
    for(genvar p=1;p<PORTS;p++) begin assign resp_valid_o[p]=0;assign resp_o[p]='0;end
    sv39_tlb u_tlb(.clk(clk),.rst(rst),.kill_i(kill_i),
        .lookup_valid_i(lookup_valid_i[0]),.lookup_vaddr_i(lookup_vaddr_i[0]),.lookup_store_i(lookup_is_store_i[0]),
        .priv_i(csr_i.priv_eff),.sum_i(csr_i.sum),.mxr_i(csr_i.mxr),.adue_i(csr_i.adue),
        .mode_i(csr_i.satp_mode),.asid_i(csr_i.satp_asid),.root_i(csr_i.satp_ppn),.epoch_i(csr_i.epoch),
        .resp_valid_o(resp_valid_o[0]),.resp_o(resp_o[0]),.ptw_req_valid_o(ptw_req_valid_o),.ptw_req_ready_i(ptw_req_ready_i),
        .ptw_req_o(ptw_req_o),.ptw_resp_i(ptw_resp_i),.sfence_i(sfence_i),.sfence_done_o(sfence_done_o));
    always_comb begin perf_o='0;perf_o[BE_DTLB_MISS]=BE_PERF_INC_W'(resp_valid_o[0] && resp_o[0].miss);end
endmodule
