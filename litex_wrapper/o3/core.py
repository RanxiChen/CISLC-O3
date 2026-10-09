"""O3 CPU registration and stable SV pin mapping for LiteX."""
from migen import ClockSignal, Constant, Instance, ResetSignal, Signal
from litex.soc.cores.cpu import CPU, CPU_GCC_TRIPLE_RISCV64
from litex.soc.interconnect import axi, wishbone

from .axi_router import O3AxiRouter
from .mmio_bridge import O3MMIOBridge
from .platform import ROOT, load_platform, platform_regions


class O3(CPU):
    category = "softcore"
    family = "riscv"
    name = "o3"
    human_name = "CISLC O3 RV64GC"
    variants = ["standard", "debug"]
    data_width = 64
    endianness = "little"
    gcc_triple = CPU_GCC_TRIPLE_RISCV64
    linker_output_format = "elf64-littleriscv"
    nop = "nop"
    gcc_arch = "rv64imafdc_zicsr_zifencei"
    gcc_abi = "lp64d"
    privilege_profile = "linux"
    num_harts = 1

    @property
    def gcc_flags(self):
        return f"-march={self.gcc_arch} -mabi={self.gcc_abi} -mno-save-restore -mcmodel=medany -D__o3__ -D__riscv_plic__"

    def __init__(self, platform, variant="standard"):
        if variant not in self.variants:
            raise ValueError(f"unsupported O3 variant {variant}")
        self.platform, self.variant = platform, variant
        config = load_platform()
        regions = platform_regions(config=config)
        self.reset_vector = int(config["resetVector"], 0)
        self.mem_map = dict(rom=regions["linux_boot_rom"]["origin"], plic=regions["plic"]["origin"],
                            sram=regions["sram"]["origin"], main_ram=regions["main_ram"]["origin"],
                            csr=regions["litex_mmio"]["origin"])
        self.io_regions = {r["origin"]: r["size"] for r in regions.values() if r["device"]}
        self.reset = Signal()
        self.interrupt = Signal(32)  # LiteX's index map; delivery uses external PLIC below.
        self.memory_bus = axi.AXIInterface(data_width=128, address_width=32, id_width=4)
        self.mmio_bus = axi.AXILiteInterface(data_width=64, address_width=32)
        self.submodules.axi_router = O3AxiRouter(self.memory_bus, regions)
        self.memory_buses = [self.axi_router.dram]
        self.submodules.mmio_bridge = O3MMIOBridge(self.mmio_bus, regions)
        self.periph_buses = [self.axi_router.low, self.mmio_bridge.bus]
        self.ibus, self.dbus = self.memory_bus, self.mmio_bus
        self.sd_dma_bus = wishbone.Interface(data_width=64, address_width=32, addressing="word")
        # LiteX recognizes this name, creates the isolated DMA bus and omits
        # the main Wishbone bus's bypass connection to LiteDRAM.
        self.dma_bus = self.sd_dma_bus
        self.time = Signal(64)
        self.msip, self.mtip, self.meip, self.seip = (Signal() for _ in range(4))
        self.fatal, self.inclusion_err, self.dma_busy = (Signal() for _ in range(3))
        self.retired_count = Signal(64)
        self.retire_valid, self.retire_pc, self.retire_inst = Signal(4), Signal(256), Signal(128)
        self.cpu_params = dict(i_clk_i=ClockSignal("sys"), i_rst_i=ResetSignal("sys") | self.reset,
            i_reset_pc_i=Constant(self.reset_vector, 64), i_mtime_i=self.time,
            i_irq_m_soft_i=self.msip, i_irq_m_timer_i=self.mtip,
            i_irq_m_ext_i=self.meip, i_irq_s_ext_i=self.seip,
            o_fatal_o=self.fatal, o_inclusion_err_o=self.inclusion_err,
            o_retired_inst_count_o=self.retired_count, o_sd_dma_busy_o=self.dma_busy,
            o_retire_valid_o=self.retire_valid, o_retire_pc_o=self.retire_pc, o_retire_inst_o=self.retire_inst)
        for prefix, bus in (("m_axi", self.memory_bus), ("m_axil", self.mmio_bus)):
            for channel in ("ar", "aw", "w", "r", "b"):
                ep = getattr(bus, channel)
                master_out = channel in ("ar", "aw", "w")
                self.cpu_params[("o_" if master_out else "i_") + prefix + "_" + channel + "valid"] = ep.valid
                self.cpu_params[("i_" if master_out else "o_") + prefix + "_" + channel + "ready"] = ep.ready
                fields = {"ar": ("addr",), "aw": ("addr",), "w": ("data", "strb"),
                          "r": ("data", "resp"), "b": ("resp",)}[channel]
                if prefix == "m_axi":
                    fields += {"ar": ("id", "len", "size", "burst"), "aw": ("id", "len", "size", "burst"),
                               "w": ("last",), "r": ("id", "last"), "b": ("id",)}[channel]
                    if channel in ("ar", "aw"):
                        # Fixed O3 cache-line transaction attributes, absent in SV pins.
                        self.comb += [ep.lock.eq(0), ep.cache.eq(0), ep.prot.eq(0), ep.qos.eq(0)]
                elif channel in ("ar", "aw"):
                    fields += ("prot",)
                for field in fields:
                    self.cpu_params[("o_" if master_out else "i_") + prefix + "_" + channel + field] = getattr(ep, field)
        for field in ("adr", "dat_w", "sel", "cyc", "stb", "we"):
            self.cpu_params["i_sd_dma_" + field + "_i"] = getattr(self.sd_dma_bus, field)
        for field in ("dat_r", "ack", "err"):
            self.cpu_params["o_sd_dma_" + field + "_o"] = getattr(self.sd_dma_bus, field)
        self.add_sources()

    def add_sources(self):
        # Preserve the package/dependency order from the authoritative RTL manifest.
        for line in (ROOT / "rtl/rtl.f").read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("//") or line.endswith(".vlt"):
                continue
            if line.startswith("+incdir+"):
                self.platform.add_verilog_include_path(str(ROOT / line[len("+incdir+"):]))
            else:
                path = ROOT / line
                if not path.is_file():
                    raise FileNotFoundError(path)
                self.platform.add_source(str(path))
        if self.variant == "debug":
            self.platform.toolchain.pre_synthesis_commands.append(
                "set_property verilog_define ENABLE_RETIRE_INFO [current_fileset]")

    def set_reset_address(self, reset_address):
        if reset_address != self.reset_vector:
            raise ValueError("LiteX reset address differs from o3_platform.json")
        self.reset_address = reset_address

    def do_finalize(self):
        self.specials += Instance("o3_litex_top", **self.cpu_params)

    def prepare_software(self, builder):
        from .software import prepare_software
        prepare_software(builder)
