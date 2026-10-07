/**
 * L7a/L10 performance counters (B48, spec 6.3).
 *
 * 当前实现状态：闭环简化（L10 T08a）。
 * - Sole owner of mcycle/minstret, mhpmcounter3..10, mhpmevent3..10 and
 *   mcountinhibit. CSR indices 11..31 read zero and ignore writes (U21).
 * - FE source 1 / BE source 2 select per-cycle increments, not Boolean pulses.
 * - Read-only user aliases are readable in M mode; writes are illegal.
 * - L10: privilege inhibition, sticky OF and an LCOFIP pulse; CSR owner gates S/U reads.
 *
 * Cycle N: CSR reads and RMW use old register values; events use old selectors
 * and inhibit bits. At edge N a counter write replaces only that counter's
 * increment (U11). Configuration writes become visible in N+1, while other
 * counters still accumulate their N increments. Counters wrap at 64 bits.
 * Tests: sim/cocotb/hpm_counters/; evidence in O3-T08-report.md.
 */
module hpm_counters
    import o3_types_pkg::*;
#(
    parameter int unsigned NUM_HPM
) (
    input  logic clk_i,
    input  logic rst_i,
    input  logic req_valid_i,
    input  csr_req_t req_i,
    output logic implemented_o,
    output csr_resp_t resp_o,
    output logic [63:0] write_value_o,
    input  logic [$clog2(o3_cfg_pkg::O3_CFG.core.commit_width+1)-1:0] retire_count_i,
    input  fe_perf_t fe_perf_i,
    input  be_perf_t be_perf_i,
    input logic [1:0] priv_i,
    output logic overflow_o,
    output logic [31:0] scountovf_o
);
    localparam int FIRST_HPM = 3;
    localparam logic [63:0] INHIBIT_MASK = 64'h5
        | (((64'h1 << NUM_HPM) - 64'h1) << FIRST_HPM);

    logic [63:0] mcycle_q, minstret_q;
    logic [63:0] counter_q [NUM_HPM];
    logic [63:0] event_q [NUM_HPM];
    logic [64:0] sums [NUM_HPM];
    logic [NUM_HPM-1:0] count_enable, overflow_set;
    logic of_base;
    logic [31:0] inhibit_q;
    logic [63:0] old_value, modify_value;
    logic counter_addr, event_addr, write_fire;

    initial assert (NUM_HPM > 0 && NUM_HPM <= 29);

    // Event zero and the FE numbering holes are not events. Range checks occur
    // before dynamic indexing; unsupported sources/numbers always increment 0.
    function automatic logic [63:0] event_increment(input logic [15:0] selector);
        logic [63:0] increment;
        increment = '0;
        case (selector[15:8])
            8'h01: if ((int'(selector[7:0]) >= int'(PE_UBTB_LOOKUP)
                       && int'(selector[7:0]) <= int'(PE_FTQ_FULL_CYCLE))
                      || (int'(selector[7:0]) >= int'(PE_TAGE_COND_PRED)
                          && int'(selector[7:0]) < int'(PE_NUM)))
                increment = 64'(fe_perf_i[selector[7:0]]);
            8'h02: if (int'(selector[7:0]) >= int'(BE_RENAME_STALL_PREG)
                       && int'(selector[7:0]) < int'(BE_PERF_NUM))
                increment = 64'(be_perf_i[selector[7:0]]);
            default: ;
        endcase
        return increment;
    endfunction

    // HPM handles its CSR subset directly from the original request, including
    // RMW and WARL masking. No input depends on csr_file's read/write outputs.
    always_comb begin
        counter_addr = (req_i.addr >= 12'hb03 && req_i.addr <= 12'hb1f)
                    || (req_i.addr >= 12'hc03 && req_i.addr <= 12'hc1f);
        event_addr = req_i.addr >= 12'h323 && req_i.addr <= 12'h33f;
        implemented_o = counter_addr || event_addr;
        old_value = '0;
        case (req_i.addr)
            12'hb00, 12'hc00: begin implemented_o = 1'b1; old_value = mcycle_q; end
            12'hb02, 12'hc02: begin implemented_o = 1'b1; old_value = minstret_q; end
            12'h320: begin implemented_o = 1'b1; old_value = 64'(inhibit_q); end
            default: ;
        endcase
        for (int i = 0; i < NUM_HPM; i++) begin
            if (int'(req_i.addr[4:0]) == FIRST_HPM + i) begin
                if (counter_addr) old_value = counter_q[i];
                if (event_addr) old_value = 64'(event_q[i]);
            end
        end

        modify_value = req_i.wdata;
        if (req_i.op == CSROP_RS) modify_value = old_value | req_i.wdata;
        if (req_i.op == CSROP_RC) modify_value = old_value & ~req_i.wdata;
        write_value_o = modify_value;
        if (req_i.addr == 12'h320) write_value_o = modify_value & INHIBIT_MASK;
        // Unimplemented HPM entries have a hardwired zero value, even on writes.
        if (counter_addr || event_addr) begin
            write_value_o = '0;
            for (int i = 0; i < NUM_HPM; i++)
                if (int'(req_i.addr[4:0]) == FIRST_HPM + i)
                    write_value_o = event_addr ? (modify_value & 64'hf00000000000ffff) : modify_value;
        end
        resp_o = '0;
        resp_o.valid = req_valid_i;
        resp_o.rdata = old_value;
        resp_o.illegal = !implemented_o || (req_i.write_en && req_i.addr[11:10] == 2'b11);
    end

    // Old selector and old privilege gate this edge's increment; a selector
    // write takes effect next cycle. Overflow is sticky until software clears OF.
    always_comb begin
        scountovf_o=0; overflow_o=0;
        for(int i=0;i<NUM_HPM;i++) begin
            count_enable[i]=!inhibit_q[FIRST_HPM+i] &&
                !((priv_i==PRIV_M && event_q[i][62]) ||
                  (priv_i==PRIV_S && event_q[i][61]) ||
                  (priv_i==PRIV_U && event_q[i][60]));
            sums[i]={1'b0,counter_q[i]}+{1'b0,event_increment(event_q[i][15:0])};
            scountovf_o[FIRST_HPM+i]=event_q[i][63];
            of_base=(write_fire && req_i.addr==12'(12'h323+i)) ? write_value_o[63] : event_q[i][63];
            overflow_set[i]=count_enable[i] && sums[i][64] && !of_base &&
                !(write_fire && req_i.addr==12'(12'hb03+i));
            overflow_o|=overflow_set[i];
        end
    end
    assign write_fire = req_valid_i && !resp_o.illegal && req_i.write_en;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            mcycle_q <= '0;
            minstret_q <= '0;
            inhibit_q <= '0;
            for (int i = 0; i < NUM_HPM; i++) begin
                counter_q[i] <= '0;
                event_q[i] <= '0;
            end
        end else begin
            if (!inhibit_q[0]) mcycle_q <= mcycle_q + 64'd1;
            if (!inhibit_q[2]) minstret_q <= minstret_q + 64'(retire_count_i);
            for (int i = 0; i < NUM_HPM; i++)
                if (count_enable[i]) begin
                    counter_q[i] <= sums[i][63:0];
                end

            // Only the written counter loses its increment on this edge.
            // Nonblocking config updates leave this edge's increments unchanged.
            if (write_fire) begin
                case (req_i.addr)
                    12'hb00: mcycle_q <= write_value_o;
                    12'hb02: minstret_q <= write_value_o;
                    12'h320: inhibit_q <= write_value_o[31:0];
                    default: ;
                endcase
                for (int i = 0; i < NUM_HPM; i++) begin
                    if (req_i.addr == 12'(12'hb03 + i)) counter_q[i] <= write_value_o;
                    if (req_i.addr == 12'(12'h323 + i)) event_q[i] <= write_value_o;
                end
            end
            // Q5: use the software OF baseline, then hardware set wins this edge.
            for (int i=0;i<NUM_HPM;i++) if(overflow_set[i]) event_q[i][63]<=1;
        end
    end
endmodule
