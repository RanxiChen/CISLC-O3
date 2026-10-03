# L2 I-side inclusive slice

Run on Alan in the `cislc-o3` environment:

```sh
make -C sim/cocotb/l2_cache SIM=verilator TEST_SEED=1
```

The test loads AXI RAM, reads five lines mapping to one L2 set, checks four
16B beats per response, holds both recall interfaces under backpressure,
returns a dirty L1D copy, and checks that L2 writes it to AXI RAM before
reusing the victim. A second test checks that an orphan L1D writeback raises
the B41 inclusion error. AXI ready stalls every third cycle and read data has
two cycles of delay. The wrapper models the still-empty L1D probe endpoint.
This does not establish DMA, multi-MSHR, timing, or the eventual live L1D
cache behavior.
