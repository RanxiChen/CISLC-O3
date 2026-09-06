# CISLC-O3 ACT4 RV64I regression

This directory binds the whole-core simulator to the upstream RISC-V
Architectural Compatibility Test framework (ACT4). The upstream checkout is
pinned by `ACT4_REV`; generated sources, ELFs, traces, and logs stay in ignored
working directories.

The current target runs the unprivileged `I` test set. It is a whole-core test:
ACT4 code is fetched and retired through the normal frontend/backend, and the
test reports its result by writing the external software-memory `tohost`
mailbox. It does not require a SoC, boot ROM, operating system, or interrupt
controller.

## Address map

| Region | Address | Use |
|---|---:|---|
| ITCM window | `0x10000000..0x1000ffff` | First 64 KiB of test code |
| External instruction memory | from `0x10010000` | Remaining ACT4 code through ICache refill |
| DTCM | `0x11000000..0x1103ffff` | Test data, signature, and stack |
| External software memory | `0x12000000` | `tohost`/`fromhost` mailbox |

The linker gives code a 16 MiB region starting at `0x10000000`; addresses beyond
the physical ITCM window therefore exercise the normal external refill path.
Data is bounded to the 256 KiB DTCM. A nonzero 64-bit value observed at
`0x12000000` ends simulation: `1` is pass and any other value is fail.

## Run

ACT4 currently requires RISC-V GCC 15 or newer, Sail 0.13.1, and `mise`. The
defaults point at the shared installations under `/home/chen`; override
`ACT4_TOOLCHAIN_ROOT`, `ACT4_SAIL_ROOT`, and `ACT4_MISE_ROOT` when needed.

```bash
cd verification/act4
make fetch
make build EXTENSIONS=I
make sim
make run EXTENSIONS=I
```

`make run` writes one JSONL retirement trace and one log per ELF under `out/`,
plus `out/summary.json`. Use `MATCH='I-addi*.elf'` for a selected test or set
`MAX_CYCLES` to change the timeout.

Passing this target establishes the generated ACT4 RV64I-I cases under the
current physical-address and single-request memory model. Privileged ISA,
interrupts, access-fault behavior, multiple outstanding memory requests, and
Spike differential comparison remain outside this target.
