# L8a M3

Run on the host selected by rereading and preflighting simulation-host.md.
The functional wrapper connects the production L1D to L2 Home and exports
read-only observation points. Python supplies randomized AXI RAM, two CPU
lanes and an independent L1I Read client. DMA stays tied off.

Run combinations in this order: MSHRS 1 then 4; within each, GEOMETRY pressure
then default; within each geometry, RFO 0 then 1. Each make executes seeds
61 and 62, each with exactly 2000 load/STA/drain operations and 500 I Reads.
The standalone pressure geometry uses 2 sets / 2 ways / 1 WB and L2 2 sets /
2 ways / 2 slots. MSHRS is independently swept as requested in spec 12.

Every load is compared against architectural golden memory. Store completion
updates this golden independently of AXI backing RAM. Replay waits for the
specified install/mshr_free/wb_free event; immediate reasons retry. Monitors
check handshakes, permissions, dirty payloads, credits, stable packets,
directory state and duplicate tags; after quiescence exact directory/physical
copy correspondence is checked and every modified line is read back.
