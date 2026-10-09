#!/usr/bin/env python3
"""BIOS smoke with the board SoC wiring and a full-capacity DDR PHY model.

Mechanism reference: Breeze sim/litex/multicore_sim.py. The board constructor
is shared; only the clock, UART pins and physical DDR/SD devices are modeled.
This does not validate board DDR training or physical SD signals.
"""
import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "fpga/kcu105"))
from target import CONFIG, O3KCU105SoC
from migen import ClockSignal, Instance, ResetSignal
from litex.build.generic_platform import Pins, Subsignal
from litex.build.io import CRG
from litex.build.sim import SimPlatform
from litex.build.sim.config import SimConfig
from litex.soc.integration.builder import Builder
from litex.soc.integration.common import get_mem_data
from litedram.phy.model import SDRAMPHYModel
from o3.axi_router import check_soc_regions

MEMTEST_BYTES = 65536


class ModelPHY(SDRAMPHYModel):
    def __init__(self, module, freq):
        super().__init__(module=module, data_width=64, clk_freq=freq, verbosity=0)
        # The model has no physical delay-training CSRs. The fixed DDR PHY
        # page remains reserved inside the shared CSR bridge window.


def make_soc(rom_init=None, selftest=False):
    io = [("sys_clk", 0, Pins(1)), ("serial", 0,
        Subsignal("source_valid", Pins(1)), Subsignal("source_ready", Pins(1)),
        Subsignal("source_data", Pins(8)), Subsignal("sink_valid", Pins(1)),
        Subsignal("sink_ready", Pins(1)), Subsignal("sink_data", Pins(8)))]
    platform = SimPlatform("SIM", io)
    soc = O3KCU105SoC(platform=platform,
        crg_factory=lambda p, freq: CRG(p.request("sys_clk")),
        ddrphy_factory=ModelPHY, uart_name="sim", sdcard_emulator=True,
        integrated_rom_init=rom_init)
    for name, value in dict(MEMTEST_DATA_SIZE=MEMTEST_BYTES,
            MEMTEST_ADDR_SIZE=MEMTEST_BYTES, CONFIG_BIOS_NO_BOOT=1).items():
        soc.add_constant(name, value)
    if selftest:
        prepare = soc.cpu.prepare_software

        def prepare_sim_software(builder):
            prepare(builder)
            import litex.soc.integration.builder as upstream
            overlay = Path(builder.output_dir) / "software-source/bios"
            shutil.copytree(Path(upstream.soc_directory) / "software/bios", overlay,
                dirs_exist_ok=True)
            shutil.copy(ROOT / "sim/litex/soc_selftest.c", overlay / "soc_selftest.c")
            makefile = overlay / "Makefile"
            text = makefile.read_text()
            if text.count("OBJECTS = boot-helper.o") != 1:
                raise RuntimeError("upstream BIOS object list changed")
            makefile.write_text(text.replace("OBJECTS = boot-helper.o",
                "OBJECTS = soc_selftest.o boot-helper.o", 1))
            builder.software_packages = [(name, str(overlay) if name == "bios" else path)
                for name, path in builder.software_packages]

        soc.cpu.prepare_software = prepare_sim_software
    platform.add_source(str(ROOT / "sim/litex/o3_smoke_monitor.sv"))
    soc.specials += Instance("o3_smoke_monitor", i_clk=ClockSignal(), i_rst=ResetSignal(),
        i_fatal=soc.cpu.fatal, i_inclusion_err=soc.cpu.inclusion_err,
        i_retired=soc.cpu.retired_count, i_ar_valid=soc.cpu.memory_bus.ar.valid,
        i_ar_ready=soc.cpu.memory_bus.ar.ready, i_ar_addr=soc.cpu.memory_bus.ar.addr,
        i_aw_valid=soc.cpu.memory_bus.aw.valid, i_aw_ready=soc.cpu.memory_bus.aw.ready,
        i_aw_addr=soc.cpu.memory_bus.aw.addr,
        i_mmio_ar_valid=soc.cpu.mmio_bus.ar.valid, i_mmio_ar_addr=soc.cpu.mmio_bus.ar.addr,
        i_mmio_aw_valid=soc.cpu.mmio_bus.aw.valid, i_mmio_aw_addr=soc.cpu.mmio_bus.aw.addr,
        i_mmio_ar_ready=soc.cpu.mmio_bus.ar.ready, i_mmio_aw_ready=soc.cpu.mmio_bus.aw.ready,
        i_meip=soc.cpu.meip, i_mtip=soc.cpu.mtip,
        i_retire_valid=soc.cpu.retire_valid, i_retire_pc=soc.cpu.retire_pc,
        i_uart_rx_valid=soc.uart.sink.valid, i_uart_rx_ready=soc.uart.sink.ready,
        i_uart_rx_fifo_valid=soc.uart.rx_fifo.source.valid,
        i_uart_event_enable=soc.uart.ev.enable.storage,
        i_uart_irq=soc.uart.ev.irq,
        i_plic_pending=soc.plic.pending_bits,
        i_plic_enable=soc.plic.debug_enables[:32],
        i_plic_uart_priority=soc.plic.debug_priorities[27:30],
        i_plic_threshold=soc.plic.debug_thresholds[:3])
    return soc


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--output-dir", required=True, type=Path)
    p.add_argument("--rom-init", type=Path, help="Alan-built simulation BIOS binary")
    p.add_argument("--run", action="store_true", help="compile and run on the simulation host")
    p.add_argument("--jobs", type=int, default=4)
    p.add_argument("--selftest", action="store_true", help="include simulation-only S2 BIOS command")
    args = p.parse_args()
    if args.run and not args.rom_init:
        p.error("--run requires an Alan-built simulation BIOS via --rom-init")
    subprocess.run([sys.executable, str(ROOT / "scripts/gen_platform_pkg.py"), "--check"], check=True)
    rom_init = None if args.rom_init is None else get_mem_data(
        str(args.rom_init.resolve()), data_width=64, endianness="little")
    soc = make_soc(rom_init, selftest=args.selftest)
    config = SimConfig()
    config.add_clocker("sys_clk", freq_hz=CONFIG["systemClockHz"])
    config.add_module("serial2console", "serial")
    builder = Builder(soc, output_dir=str(args.output_dir.resolve()),
        compile_software=rom_init is None, integrated_rom_auto_size=False,
        bios_console="lite", csr_json=str(args.output_dir.resolve() / "csr.json"))
    builder.build(run=args.run, sim_config=config, interactive=False,
        trace=False, opt_level="O3", jobs=args.jobs)
    (args.output_dir / "address-map.json").write_text(json.dumps(
        check_soc_regions(soc, ROOT, require_csr=True), indent=2) + "\n")


if __name__ == "__main__":
    main()
