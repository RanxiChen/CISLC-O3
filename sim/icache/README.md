# ICache Verilator Tests

This directory contains standalone Verilator/C++ tests for `rtl/frontend/icache.sv`.

Related documentation:

- ICache design: `../../doc/icache.md`
- Verilator ICache test plan: `../../doc/verilator_icache_test_plan.md`
- Basic refill test notes: `../../doc/icache_basic_refill_test.md`

## Tests

### 1. All-hit preinitialized cache test

- Testbench: `tb_icache.cpp`
- Makefile: `Makefile`
- Object directory: `obj_dir`
- Related doc: `../../doc/verilator_icache_test_plan.md`
- Purpose:
  - Uses the simulation hex files under `hex/`.
  - Builds with `O3_ICACHE_WAY0_VALID`, so way 0 starts valid after reset.
  - Walks all sets and banks and checks that every access hits with the expected preloaded data.

Run:

```sh
make -C sim/icache clean
make -C sim/icache run
```

### 2. Basic cold-miss refill test

- Testbench: `tb_icache_basic_refill.cpp`
- Makefile: `Makefile.basic_refill`
- Object directory: `obj_dir_basic_refill`
- Related docs:
  - `../../doc/icache_basic_refill_test.md`
  - `../../doc/verilator_icache_test_plan.md`
- Purpose:
  - Starts from an invalid cache.
  - Sends one request at `0x0`.
  - Polls `refill_req_valid`.
  - Returns a fixed refill response after 6 cycles.
  - Checks the miss completion output and then checks a second access hits.

Run:

```sh
make -C sim/icache -f Makefile.basic_refill run
```

The `run` target depends on `clean`, so it removes `obj_dir_basic_refill` before rebuilding.

### 3. Cycle-step streaming refill test

- Testbench: `tb_icache_cycle.cpp`
- Makefile: `Makefile.cycle`
- Object directory: `obj_dir_cycle`
- Related docs:
  - `../../doc/icache.md`
  - `../../doc/verilator_icache_test_plan.md`
- Purpose:
  - Adds a cycle-level test harness.
  - Each `step()` performs one complete clock cycle:
    - `clk = 1; eval();`
    - `clk = 0; eval();`
  - The input side keeps `s0_valid` asserted and advances to the next 16-byte fetch block after each `s0_valid && s0_ready` fire.
  - The first request is `0x0`; later requests are `0x10`, `0x20`, `0x30`, and so on.
  - The test records input fire count and fired PCs.
  - The test monitors `refill_req_valid/refill_req_pc`; each request is answered after 6 cycles with generated refill data.
  - The test records every `out_valid` with cycle, PC, hit/error, and data.

Run:

```sh
env CCACHE_DISABLE=1 make -C sim/icache -f Makefile.cycle run
```

The `run` target depends on `clean`, so it removes `obj_dir_cycle` before rebuilding. `CCACHE_DISABLE=1` avoids failures when the ccache directory is read-only in the sandbox.

## Notes

- The existing all-hit test uses `hex/data_way0_bank*.hex` and `hex/tag_way0.hex`.
- The cycle-step streaming test does not use the preinitialized-valid path. Its data comes from the testbench refill response generator.
- For a 64-byte cache line and 16-byte fetch width, each filled line covers four fetch blocks. In the cold-miss case this appears as one miss completion output followed by three hits in the same line.
