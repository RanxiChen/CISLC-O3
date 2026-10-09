#!/usr/bin/env python3
"""Complete O3 KCU105 SoC: DDR4, CLINT/PLIC/UART and coherent SD DMA.

Source template: Breeze fpga/kcu105/target.py @
ec899c7c4367cfab56b9a6206d82066bc79f8a8b. All imports are O3 or upstream IP.
Running this script builds files; it never programs a board or an SD card.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "litex_wrapper"))

from migen import Constant
from litex.soc.cores.cpu import CPUS
from litex.soc.integration.builder import Builder
from litex.soc.integration import export
from litex.soc.integration.soc import SoCRegion
from litex.soc.integration.soc_core import SoCCore
from litex_boards.platforms import xilinx_kcu105
from crg import O3CRG
from litedram.modules import EDY4016A
from litedram.phy import usddrphy

from o3.core import O3
from o3.clint_verilog import O3Clint
from o3.plic_verilog import O3Plic
from o3.axi_router import add_inactive_boot_rom, check_soc_regions
from o3.platform import load_platform, platform_regions, csr_address_width, csr_map, irq_map

CONFIG = load_platform()
REGIONS = platform_regions(config=CONFIG)
CPUS["o3"] = O3


class O3KCU105SoC(SoCCore):
    csr_map = csr_map(CONFIG)
    interrupt_map = irq_map(CONFIG)

    def __init__(self, debug=False, *, platform=None, crg_factory=None,
                 ddrphy_factory=None, uart_name="serial", sdcard_emulator=False,
                 integrated_rom_init=None):
        freq = CONFIG["systemClockHz"]
        platform = xilinx_kcu105.Platform() if platform is None else platform
        self.crg = (crg_factory or O3CRG)(platform, freq)
        super().__init__(platform, clk_freq=freq,
            ident="CISLC O3 RV64GC DDR4 + SD SoC on KCU105",
            cpu_type="o3", cpu_variant="debug" if debug else "standard",
            cpu_reset_address=int(CONFIG["resetVector"], 0),
            bus_standard="wishbone", bus_data_width=64, bus_address_width=32,
            bus_bursting=False, bus_interconnect="shared", bus_timeout=None,
            integrated_rom_size=REGIONS["linux_boot_rom"]["size"],
            integrated_rom_init=integrated_rom_init,
            integrated_sram_size=REGIONS["sram"]["size"], integrated_main_ram_size=0,
            csr_data_width=32, csr_address_width=csr_address_width(CONFIG), csr_paging=0x1000,
            with_ctrl=True, with_uart=True, uart_name=uart_name, uart_baudrate=115200,
            with_timer=True)
        module = EDY4016A(freq, "1:4")
        self.ddrphy = (ddrphy_factory(module, freq) if ddrphy_factory else
            usddrphy.USDDRPHY(platform.request("ddram"), memtype="DDR4",
                sys_clk_freq=freq, iodelay_clk_freq=200e6))
        geometry = module.geom_settings
        self.ddr_capacity_bytes = (2**(geometry.bankbits + geometry.rowbits + geometry.colbits)
            * self.ddrphy.settings.nranks * self.ddrphy.settings.databits // 8)
        if self.ddr_capacity_bytes != REGIONS["main_ram"]["size"]:
            raise ValueError(f"DDR geometry/PMA capacity mismatch: hardware={self.ddr_capacity_bytes:#x}, "
                             f"PMA={REGIONS['main_ram']['size']:#x}")
        self.add_sdram(name="sdram", phy=self.ddrphy, module=module,
            size=REGIONS["main_ram"]["size"], l2_cache_size=0)
        add_inactive_boot_rom(self, ROOT)
        timer = CONFIG["machineTimer"]
        r = REGIONS["machine_timer"]
        self.clint = O3Clint(platform=platform, sys_clk_freq=freq,
            timebase_freq=timer["mtimeFrequencyHz"], num_harts=1, region_size=r["size"],
            msip_offset=int(timer["msipOffset"], 0),
            mtimecmp_offset=int(timer["mtimecmpOffset"], 0), mtime_offset=int(timer["mtimeOffset"], 0))
        self.bus.add_slave(name="clint", slave=self.clint.bus,
            region=SoCRegion(origin=r["origin"], size=r["size"], cached=False))
        self.comb += [self.cpu.msip.eq(self.clint.msip), self.cpu.mtip.eq(self.clint.mtip),
                      self.cpu.time.eq(self.clint.mtime)]
        r = REGIONS["plic"]
        self.plic = O3Plic(platform, num_harts=1, num_sources=CONFIG["externalInterrupts"]["numSources"])
        self.bus.add_slave(name="plic", slave=self.plic.bus,
            region=SoCRegion(origin=r["origin"], size=r["size"], cached=False))

        # LiteX sees cpu.dma_bus and has already built an isolated DMA fabric.
        # add_sdcard registers both DMA masters there, never on the main bus.
        self.add_sdcard(mode=CONFIG["sdcard"]["mode"], use_emulator=sdcard_emulator)
        irq_sources = {"uart": self.uart.ev.irq, "sdcard": self.sdcard.ev.irq,
                       "timer0": self.timer0.ev.irq}
        ids = {s["plicId"]: s["name"] for s in CONFIG["externalInterrupts"]["sources"]}
        for source in range(1, CONFIG["externalInterrupts"]["numSources"] + 1):
            self.comb += self.plic.sources[source-1].eq(irq_sources[ids[source]] if source in ids else Constant(0))
        self.comb += [self.cpu.meip.eq(self.plic.meip), self.cpu.seip.eq(self.plic.seip)]

        mask = sum(1 << s["plicId"] for s in CONFIG["externalInterrupts"]["sources"])
        constants = dict(O3_NUM_HARTS=1, O3_PLIC_BASE=r["origin"], O3_PLIC_MASK=mask,
            O3_PLIC_NUM_SOURCES=CONFIG["externalInterrupts"]["numSources"],
            O3_MTIME_FREQUENCY=timer["mtimeFrequencyHz"],
            O3_SD_SCRATCH_BASE=int(CONFIG["sdcard"]["biosScratchOrigin"], 0),
            SDCARD_CLK_FREQ_INIT=400000, SDCARD_CLK_FREQ=5000000)
        for name, value in constants.items():
            self.add_constant(name, value)
        check_soc_regions(self, ROOT)
        self.check_memory_paths()
        if debug:
            from o3.ila import O3DebugILA
            self.debug_ila = O3DebugILA(self.cpu, platform)
            self.comb += platform.request("user_led", 0).eq(self.cpu.fatal)

    def check_memory_paths(self):
        if "main_ram" in self.bus.slaves:
            raise ValueError("main LiteX bus must not bypass O3 coherence to access DDR")
        if set(self.bus.masters) != {"cpu_bus0", "cpu_bus1"}:
            raise ValueError(f"unexpected main-bus masters: {list(self.bus.masters)}")
        if set(self.dma_bus.masters) != {"sdcard_block2mem", "sdcard_mem2block"}:
            raise ValueError("both SD directions must use the isolated coherent DMA bus")
        if self.dma_bus.slaves["dma"] is not self.cpu.dma_bus:
            raise ValueError("DMA fabric does not terminate at the O3 coherent port")
        if self.csr.address_width != csr_address_width(CONFIG):
            raise ValueError("CSR address width differs from platform JSON")
        expected_irqs = irq_map(CONFIG)
        if self.irq.locs != expected_irqs:
            raise ValueError(f"LiteX IRQ allocation/PIC wiring mismatch: {self.irq.locs} != {expected_irqs}")
        for name, index in expected_irqs.items():
            constant = self.constants.get(name.upper() + "_INTERRUPT")
            # Constants are materialized only during finalization.
            value = getattr(constant, "value", constant)
            if constant is not None and value != index:
                raise ValueError(f"BIOS IRQ constant differs from platform JSON: {name}={value}")
        return dict(ddr_master="cpu.axi_router.dram", main_bus_masters=list(self.bus.masters),
                    coherent_dma_masters=list(self.dma_bus.masters), direct_main_bus_ddr=False,
                    ddr_capacity_bytes=self.ddr_capacity_bytes, csr_address_width=self.csr.address_width)

    def add_csr_bridge(self, *args, **kwargs):
        super().add_csr_bridge(*args, **kwargs)
        # The real CSR slave must cover exactly the PMA window. Check before
        # LiteX finalizes the decoder or the builder invokes any backend.
        check_soc_regions(self, ROOT, require_csr=True)
        self.check_memory_paths()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--debug", action="store_true")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "build/fpga/kcu105-o3-sd")
    parser.add_argument("--build", action="store_true", help="invoke Vivado (Alan only)")
    parser.add_argument("--no-compile-software", action="store_true", help="generate hardware with empty BIOS ROM")
    args = parser.parse_args()
    if args.build and args.no_compile_software:
        parser.error("--build requires a compiled BIOS; empty ROM is only for code generation")
    subprocess.run([sys.executable, str(ROOT / "scripts/gen_platform_pkg.py"), "--check"], check=True)
    soc = O3KCU105SoC(debug=args.debug)
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    builder = Builder(soc, output_dir=str(output), compile_software=not args.no_compile_software,
        csr_csv=str(output / "csr.csv"), csr_json=str(output / "csr.json"),
        integrated_rom_auto_size=False, bios_console="lite")
    soc.platform.toolchain.additional_commands += [
        "report_timing_summary -file soc-timing-summary.rpt",
        "report_timing -max_paths 10 -path_type full -file soc-worst-10.rpt",
        "report_utilization -file soc-utilization.rpt"]
    if args.no_compile_software:
        # Hardware-only generation needs no compiler/picolibc source package.
        # Emit the same SoC and map, with an explicitly empty BIOS ROM.
        soc.finalize()
        soc.cpu.prepare_software(builder)
        (output / "csr.json").write_text(export.get_csr_json(
            csr_regions=soc.csr_regions, constants=soc.constants, mem_regions=soc.mem_regions))
        (output / "csr.csv").write_text(export.get_csr_csv(
            csr_regions=soc.csr_regions, constants=soc.constants, mem_regions=soc.mem_regions))
        soc.platform.build(soc, build_dir=str(output / "gateware"), run=False)
    else:
        builder.build(run=args.build)
    # Verify the finalized decoder as well as the pre-build object graph.
    paths = soc.check_memory_paths()
    address_map = check_soc_regions(soc, ROOT, require_csr=True)
    expected = {p["name"]: int(p["origin"], 0) for p in CONFIG["mmioPages"]}
    actual = {name: region.origin for name, region in soc.csr_regions.items()}
    if actual != expected:
        raise ValueError(f"CSR map differs from platform JSON: {actual}")
    (output / "memory-paths.json").write_text(json.dumps(paths, indent=2) + "\n")
    (output / "address-map.json").write_text(json.dumps(address_map, indent=2) + "\n")
    (output / "platform.json").write_text(json.dumps(CONFIG, indent=2) + "\n")
    if args.debug:
        soc.debug_ila.write_probe_map(output / "ila-probes.json")


if __name__ == "__main__":
    main()
