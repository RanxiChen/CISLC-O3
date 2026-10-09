// Passive observation of the real core's cache-line AXI port. No handshake changes.
module o3_smoke_monitor (
    input logic clk, rst, fatal, inclusion_err,
    input logic [63:0] retired,
    input logic ar_valid, ar_ready,
    input logic [31:0] ar_addr,
    input logic aw_valid, aw_ready,
    input logic [31:0] aw_addr,
    input logic mmio_ar_valid, mmio_aw_valid,
    input logic [31:0] mmio_ar_addr, mmio_aw_addr,
    input logic mmio_ar_ready, mmio_aw_ready, meip, mtip,
    input logic [3:0] retire_valid,
    input logic [255:0] retire_pc,
    input logic uart_rx_valid, uart_rx_ready, uart_rx_fifo_valid, uart_irq,
    input logic [1:0] uart_event_enable,
    input logic [31:0] plic_pending, plic_enable,
    input logic [2:0] plic_uart_priority, plic_threshold
);
    longint unsigned cycles, rom_reads, sram_reads, ddr_reads, ddr_writes;
    logic seen_first;
    logic [63:0] last_pc;
    longint unsigned received;
    always_ff @(posedge clk) begin
        if (rst) begin
            cycles <= 0; rom_reads <= 0; sram_reads <= 0;
            ddr_reads <= 0; ddr_writes <= 0; seen_first <= 0; last_pc <= 0; received <= 0;
        end else begin
            cycles <= cycles + 1;
            if (uart_rx_valid && uart_rx_ready) received <= received + 1;
            for (int i=0; i<4; i++)
                if (retire_valid[i]) last_pc <= retire_pc[i*64+:64];
            assert (!fatal && !inclusion_err)
                else $fatal(1, "O3 BIOS smoke: fatal/inclusion error");
            assert (!(mmio_ar_valid && mmio_ar_addr == 32'h12100000) &&
                    !(mmio_aw_valid && mmio_aw_addr == 32'h12100000))
                else $fatal(1, "O3 S2 hole access escaped PMA onto MMIO bus");
            if (ar_valid && ar_ready) begin
                if (!seen_first) begin
                    assert (ar_addr == 32'h10010000)
                        else $fatal(1, "O3 BIOS smoke: first fetch at %h", ar_addr);
                    seen_first <= 1;
                    $display("[O3-SMOKE] first_fetch=%h", ar_addr);
                end
                if (ar_addr >= 32'h10010000 && ar_addr < 32'h10020000)
                    rom_reads <= rom_reads + 1;
                if (ar_addr >= 32'h11000000 && ar_addr < 32'h11010000)
                    sram_reads <= sram_reads + 1;
                if (ar_addr >= 32'h80000000) ddr_reads <= ddr_reads + 1;
            end
            if (aw_valid && aw_ready && aw_addr >= 32'h80000000)
                ddr_writes <= ddr_writes + 1;
            if (cycles % 1000000 == 0) begin
                $display("[O3-SMOKE] cycles=%0d retired=%0d rom_reads=%0d sram_reads=%0d ddr_reads=%0d ddr_writes=%0d",
                    cycles, retired, rom_reads, sram_reads, ddr_reads, ddr_writes);
                $display("[O3-SMOKE] last_pc=%h meip=%b mtip=%b mmio_ar=%b/%b@%h mmio_aw=%b/%b@%h",
                    last_pc, meip, mtip, mmio_ar_valid, mmio_ar_ready, mmio_ar_addr,
                    mmio_aw_valid, mmio_aw_ready, mmio_aw_addr);
                $display("[O3-IRQ] rx_count=%0d rx_fifo=%b uart_enable=%h irq=%b plic_pending=%h enable=%h priority10=%0d threshold=%0d",
                    received, uart_rx_fifo_valid, uart_event_enable, uart_irq,
                    plic_pending, plic_enable, plic_uart_priority, plic_threshold);
                $fflush();
            end
        end
    end
endmodule
