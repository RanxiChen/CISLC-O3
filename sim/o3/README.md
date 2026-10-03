# L1 whole-core retirement simulation

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
active, run the component tests and then the L1 gate below:

```sh
for module in bpu fetch_return_queue ifu_f0 ifu_f1 icache o3_sram_1r1w backend; do
    make -C sim/cocotb/$module SIM=verilator TEST_SEED=1 || break
done
```

The environment is independent of Alan's existing `flow` environment.

This harness builds the current `o3_core` from the single RTL file list,
`rtl/rtl.f`. The C++ loader accepts little-endian ELF64 `PT_LOAD` segments
and word-oriented hex. Hex words load at `0x10000000` by default; `@ADDRESS`
changes the byte address. While reset is asserted, the harness writes image
bytes into ITCM/DTCM through their initialization ports and into the
SystemVerilog AXI backing RAM at `0x80000000`–`0x800fffff`.

Run the L1 gate:

```sh
make -C sim/o3 build
make -C sim/o3 run-smoke
```

`run-smoke` loads `tests/smoke.hex`, retires four independent `addi`
instructions, writes `sim/o3/tandem.jsonl`, and compares its architectural
fields with `tests/smoke.expected.json`. The required PCs are
`0x10000000/04/08/0c`; writes to `x1..x4` must be `1/2/3/4`.
The runner fails on timeout or a core fatal signal. Set `--max-cycles` when
invoking the binary directly to adjust the timeout.

Each JSONL retirement record keeps the v1 schema used by the existing
`check_trace.py` and `*.expected.json`: `cycle`, `order`, `slot`,
`instruction_id`, `rob_idx`, `pc`, `instruction`, `rd`, `rd_write`,
and `rd_wdata`. Only actual ROB retirements are recorded.

The AXI4 slave is written in SystemVerilog in `o3_tandem_top.sv`. It has
one outstanding read and one outstanding write, byte strobes, bursts,
parameterized read latency, and valid/ready backpressure. L1 smoke should
hit ITCM and therefore does not validate the L2/AXI miss path.

The ICache now has a two-bank, four-stage lookup and a single demand MSHR.
`sim/cocotb/icache/` tests real cache hits and four-beat refill with a
synthetic L2 responder. The current `l2_cache.sv` is still a shell, so an
external-memory instruction fetch cannot yet complete through `o3_core`.
Pass `+L1_DEBUG` to the simulation binary for a bounded frontend/backend
handshake trace.

A passing smoke run proves only that the current straight-line ITCM
instruction path reaches ordered retirement for these four instructions.
It does not prove branch recovery, RVC, exceptions, DTCM or external memory,
cache misses, or general ISA compliance. The old
`tests/rv64i_instructions.hex`, `tests/unified_memory.hex`, expected JSON,
and `check_trace.py` remain available for later L2/L3 migration; their
Makefile targets are not L1 acceptance gates.
