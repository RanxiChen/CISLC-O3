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
bytes into the SystemVerilog AXI backing RAM at `0x80000000`–`0x801fffff`.
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

Run the basic AXI-backed data gate after the same build:

```sh
make -C sim/o3 run-dcache-data
make -C sim/o3 run-dcache-replay
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
`run-dcache-replay` checks the separate single-slot conservative dependency
replay gate; it does not imply multiple outstanding loads or speculation past
an unknown-address older store.
`tests/unified_memory.hex` remains a legacy software-memory image, not this
AXI-backed data-path gate.

## O3-T02 in-process Spike lockstep

Activate `cislc-o3` before building. The fixed upstream Spike commit is
`609dbe0b9994154833039209fa37151e7c05e9d4`; use unmodified sources and default
configure/make (no commitlog patch or special configure flag):

```sh
source /home/chen/miniforge3/bin/activate cislc-o3
git clone https://github.com/riscv-software-src/riscv-isa-sim.git /tmp/cislc-o3-spike-src
git -C /tmp/cislc-o3-spike-src checkout --detach 609dbe0b9994154833039209fa37151e7c05e9d4
mkdir -p /tmp/cislc-o3-spike-build
cd /tmp/cislc-o3-spike-build
/tmp/cislc-o3-spike-src/configure --prefix="$CONDA_PREFIX"
make -j4
make install
```

The Alan build used system GCC 13.3.0 and default `-g -O2 -std=c++2a`.
Dependencies include DTC, pkg-config, Boost system/regex, pthread, and Spike's
bundled FESVR, disassembler, softfloat and FDT. `sim/o3` uses
`riscv-riscv.pc` for include, `-lriscv`, and conda-prefix rpath, with C++20.
No extra FESVR library was needed. The installed `libriscv.so` SHA256 was
`09fc861e8860bc4b8e000b422ab39312dfe082e69c4e085fb0e5dd9f6ca748e6`.
The simulator was compiled with conda GCC 16.2.0; `ldd` resolved `libriscv.so`
to `/home/chen/miniforge3/envs/cislc-o3/lib/libriscv.so`.

From the repository root:

```sh
make -C sim/o3 build
make -C sim/o3 run-spike-all
make -C verification/act4 build UPSTREAM_DIR=/path/to/pinned/riscv-arch-test
make -C sim/o3 run-spike-act4
make -C sim/o3 run-spike-random SEEDS=1-200
make -C sim/o3 run-spike-selftest
```

`BUILD_DIR`, `SPIKE_PREFIX`, `SPIKE_OUT`, `RETIRE_TARGET` and ACT4 `ELF_DIR`
can be overridden. `SEEDS` accepts ranges and comma-separated seed lists.
The five existing fixed gates retain their independent expected-record
checker. `run-spike-all` also runs the twelve-instruction `tests/branch_loop.hex`
regression with Spike through retired tohost: a younger JAL must not suppress
an older taken BNE while frontend recovery is busy (D24). Run it separately
with `make -C sim/o3 run-spike-branch-loop`. `unified_memory` is a historical pre-AXI gate, excluded by frozen Q7;
its original command/checker are retained.

The reference shares only initial loader bytes with the DUT; runtime RAM is
independent. It runs one RV64I hart in M/Bare, without DTB, PMP or triggers,
and steps once per valid lane in lane order. Address/size/writeback events
come from Spike itself. Load values are re-read from its own RAM and formatted
according to the independently fetched instruction; x0 loads compare address
and size. Stores compare truncated architectural data at retirement.

`ENABLE_RETIRE_INFO` adds a passive ROB-indexed memory side table. LSU result
metadata survives forwarding, replay and WB backpressure; no observation bit
feeds execution. JSONL retains all old fields and adds `v:2`, `mem_kind`,
`mem_addr`, byte-count `mem_size`, `mem_data`, and null FP/CSR/exception fields.
A difference prints `MISMATCH field=... retire_idx=...`, both complete records,
and at most 32 previously matched pairs, then exits 2. Core fatal is checked
first. Cycle or 10000-cycle retirement watchdog timeout exits 3. `--retire-target`
defaults to 3000 and default cycle limit is target times 50. ACT4 and random
end at retired nonzero SD tohost, comparing all younger lanes in that cycle.

The random generator reserves x1/x2/x3, uses `random.Random(seed)` and template
weights ALU/shift 45%, branch 15%, JAL 5%, load 20%, store 15%. Backward loops
use a countdown of at most 8; accesses are naturally aligned inside
`0x80100000`–`0x8010ffff`. The exact dynamic budget is 3000 before any younger
same-cycle lane after tohost. Each seed is first validated independently with
`--spike-reference-only`; failures are preserved and all seeds continue.
`O3_INJECT=<kind>:<retire_idx>` modifies only a copied C++ DUT record.
All normal Makefile gates clear it; selftest explicitly tests pc, reg, load,
store_addr and store_data and checks both field and zero-based retirement index.

ACT4 code is at `0x80000000`, data at `0x80100000` (256 KiB), and the fixed
image-resident tohost symbol at `0x801ff000`. Linker, Sail RAM and SD pass/fail
macros use this map. The upstream revision remains
`dfa582359db885ae4c6ed1fa82faef60874e212c`; all 51 RV64I ELFs were regenerated.

O3-T02 first validation found a DUT control-flow bug. Reproduce it with:

```sh
sim/o3/build/Vo3_tandem_top --spike --image sim/o3/repros/branch_loop.hex \
  --trace /tmp/branch-loop.jsonl --tohost-address 0x8010fff8 --max-retires 1000
```

The 12-word, two-iteration loop reports PC mismatch at retirement 8:
DUT `0x8000002c`, Spike `0x80000014`. The old O3-T01 binary also reproduced
this gap. The initial 200-seed result was 1 PASS / 199 PC differences,
114412 matched retirements; ACT4 was 15 PASS / 36 FAIL / 0 infrastructure errors.
These are failure evidence, not an L5/ISA-compliance claim. Full records and
final-SHA verification locations are in `doc/tasks/O3-T02-report.md`.
