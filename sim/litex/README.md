# CISLC-O3 LiteX AXI simulation

This project-owned target validates the standalone memory-system boundary
before an LSU or DCache is connected to `o3_core`:

```text
axi_memory_smoke_top.sv -> axi_master.sv -> LiteX AXI interconnect
    -> initialized virtual main RAM
```

The memory map is recorded in `config/o3_platform.json`. It follows the
installed LiteX Rocket layout and places the future DDR-backed `main_ram` last,
at `0x80000000`. Simulation uses LiteX internal RAM for this region and does not
instantiate LiteDRAM or a DDR controller.

The finite smoke reads the initialized first word, writes the following 64-bit
word, and reads it back. Without `--ram-init`, the first word is initialized to
`0x1122334455667788`. A raw little-endian binary can be supplied instead:

```bash
source ~/FUN/env.sh
cd ~/FUN/CISLC-O3

python sim/litex/o3_axi_sim.py --build --debug-axi
python sim/litex/o3_axi_sim.py --ram-init program.bin --build --debug-axi
```

`--debug-axi` enables a passive simulation-only monitor. It logs completed
`AW`, `W`, `B`, `AR`, and `R` handshakes and never drives the bus. The monitor
exists only in this CISLC-O3 simulation target and is not part of an FPGA build.

Current AXI scope is deliberately small: one single-beat transaction at a time,
without bursts, response reordering, or atomics. The request side of
`axi_master.sv` is reserved as the future LSU/DCache connection.
