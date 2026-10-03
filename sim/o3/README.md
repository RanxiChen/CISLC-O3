# Whole-core ICache → inclusive L2 → AXI retirement simulation

## Alan test environment

The persistent Alan environment is `/home/chen/miniforge3/envs/cislc-o3`.
Recreate it from the repository if necessary:

```sh
/home/chen/miniforge3/bin/conda env create -f sim/alan-env.yml
source /home/chen/miniforge3/etc/profile.d/conda.sh
conda activate cislc-o3
python3 --version
cocotb-config --version
verilator --version
```

The specification installs cocotb from pip. On Alan, the conda-forge package
labelled 2.1.0 reported version 0.0.0 after installation; the pip wheel
reports 2.1.0 and passed the tests below. The installed environment uses
Python 3.12.14, cocotb 2.1.0, and Verilator 5.050. With the environment
active, run the component tests and then the cache gate below:

```sh
for module in bpu fetch_return_queue ifu_f0 ifu_f1 icache l2_cache dcache o3_sram_1r1w backend; do
    make -C sim/cocotb/$module SIM=verilator TEST_SEED=1 || break
done
```

The environment is independent of Alan's existing `flow` environment.

This harness builds the current `o3_core` from the single RTL file list,
`rtl/rtl.f`. The C++ loader accepts little-endian ELF64 `PT_LOAD` segments
and word-oriented hex. Hex words load at `0x80000000` by default; `@ADDRESS`
changes the byte address. While reset is asserted, the harness writes image
bytes into the SystemVerilog AXI backing RAM at `0x80000000`–`0x800fffff`.
DTCM initialization remains available for later data-path tests. ITCM was
removed from RTL and from the loader.

Run the cache gate:

```sh
make -C sim/o3 build
make -C sim/o3 run-smoke
```

Run the direct-control recovery gate after the same build:

```sh
make -C sim/cocotb/branch_recovery SIM=verilator TEST_SEED=1
make -C sim/o3 run-rv64i-instructions
```

The branch image starts at `0x80000000`, retires a taken BEQ and a direct JAL,
and requires both skipped wrong-path `addi` instructions to be absent from the
retirement trace. This L2 closure retains the sequential predictor and the
existing conservative one-cycle pause on every resolution. JALR/RVC and
predecode/slow/system redirect arbitration remain outside the gate.

`run-smoke` loads `tests/smoke.hex`, retires four independent `addi`
instructions, writes `sim/o3/icache_smoke.jsonl`, and compares its architectural
fields with `tests/icache_smoke.expected.json`. The required PCs are
`0x80000000/04/08/0c`; writes to `x1..x4` must be `1/2/3/4`.
The runner also requires at least one accepted ICache line refill.
The runner fails on timeout or a core fatal signal. Set `--max-cycles` when
invoking the binary directly to adjust the timeout.

Each JSONL retirement record keeps the v1 schema used by the existing
`check_trace.py` and `*.expected.json`: `cycle`, `order`, `slot`,
`instruction_id`, `rob_idx`, `pc`, `instruction`, `rd`, `rd_write`,
and `rd_wdata`. Only actual ROB retirements are recorded.

The AXI4 slave is written in SystemVerilog in `o3_tandem_top.sv`. It has
one outstanding read and one outstanding write, byte strobes, bursts,
parameterized read latency, and valid/ready backpressure. The smoke fetches
through ICache, the RTL L2, and this AXI RAM.

The ICache now has a two-bank, four-stage lookup and a single demand MSHR.
`sim/cocotb/icache/` tests hits, four-beat refill, and inclusive recall.
`sim/cocotb/l2_cache/` tests L2 read hits, AXI misses, capacity recall of
both L1s, dirty data handoff, and writeback before replacement. The current
L2 handles one ordinary transaction at a time; DMA, multiple MSHRs, and
independent hits during a miss remain to be implemented. The current L1D has
four 16-byte word banks, one line miss transaction, resident-line hit-under-miss,
dirty victim writeback and inclusive probe handoff.
Pass `+L1_DEBUG` to the simulation binary for a bounded frontend/backend
handshake trace.

A passing smoke run proves only that the straight-line image crosses ICache,
L2, AXI RAM and reaches ordered retirement. The separate
`run-rv64i-instructions` gate adds taken BEQ/direct-JAL execution recovery and
wrong-path retirement exclusion. Neither gate proves JALR, RVC, exceptions,
DMA, concurrent L2 misses, synthesis timing, or general ISA compliance.
`run-dcache-data` separately checks one AXI-backed data line's load/store
retirement through SQ, DCache and L2. It does not establish LQ replay,
cross-line exceptions, FENCE.I, or multi-MSHR behavior.
`tests/unified_memory.hex` remains a legacy software-memory image, not this
AXI-backed data-path gate.
