#!/usr/bin/env python3
"""Project-owned LiteX simulation for the CISLC-O3 AXI memory boundary."""

import argparse
import json
import os

from migen import ClockSignal, Display, Finish, If, Instance, Module, ResetSignal, Signal

from litex.build.generic_platform import Pins
from litex.build.io import CRG
from litex.build.sim import SimPlatform
from litex.build.sim.config import SimConfig
from litex.soc.integration.builder import Builder
from litex.soc.integration.common import get_mem_data
from litex.soc.integration.soc_core import SoCMini
from litex.soc.interconnect import axi


REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PLATFORM_CONFIG_PATH = os.path.join(REPO_ROOT, "config", "o3_platform.json")

DATA_WIDTH = 64
AXI_ID_WIDTH = 4
DEFAULT_INITIAL_VALUE = 0x1122_3344_5566_7788
SMOKE_WRITE_VALUE = 0x0123_4567_89AB_CDEF


def platform_int(value):
    return value if isinstance(value, int) else int(value, 0)


with open(PLATFORM_CONFIG_PATH, encoding="utf-8") as platform_config_file:
    PLATFORM_CONFIG = json.load(platform_config_file)

MAIN_RAM_REGION = next(
    region for region in PLATFORM_CONFIG["regions"] if region["name"] == "main_ram"
)
LITEX_MMIO_REGION = next(
    region for region in PLATFORM_CONFIG["regions"] if region["name"] == "litex_mmio"
)
MAIN_RAM_ORIGIN = platform_int(MAIN_RAM_REGION["origin"])
MAIN_RAM_SIZE = platform_int(MAIN_RAM_REGION["size"])
LITEX_MMIO_ORIGIN = platform_int(LITEX_MMIO_REGION["origin"])
ADDRESS_WIDTH = platform_int(PLATFORM_CONFIG["addressWidth"])


_IO = [("sys_clk", 0, Pins(1))]


class Platform(SimPlatform):
    def __init__(self):
        super().__init__("SIM", _IO)


class AXITransactionMonitor(Module):
    """Passive simulation-only logger for completed AXI handshakes."""

    def __init__(self, bus, log_limit=64):
        cycle = Signal(64)
        event_count = Signal(32)
        aw_fire = bus.aw.valid & bus.aw.ready
        w_fire = bus.w.valid & bus.w.ready
        b_fire = bus.b.valid & bus.b.ready
        ar_fire = bus.ar.valid & bus.ar.ready
        r_fire = bus.r.valid & bus.r.ready
        event_increment = Signal(3)

        self.comb += event_increment.eq(aw_fire + w_fire + b_fire + ar_fire + r_fire)
        self.sync += [
            cycle.eq(cycle + 1),
            event_count.eq(event_count + event_increment),
            If((event_count < log_limit) & aw_fire,
                Display(
                    "[AXI-AW] cycle=%d id=%d addr=0x%x len=%d size=%d burst=%d",
                    cycle, bus.aw.id, bus.aw.addr, bus.aw.len,
                    bus.aw.size, bus.aw.burst,
                )
            ),
            If((event_count < log_limit) & w_fire,
                Display(
                    "[AXI-W] cycle=%d data=0x%x strb=0x%x last=%d",
                    cycle, bus.w.data, bus.w.strb, bus.w.last,
                )
            ),
            If((event_count < log_limit) & b_fire,
                Display("[AXI-B] cycle=%d id=%d resp=%d", cycle, bus.b.id, bus.b.resp)
            ),
            If((event_count < log_limit) & ar_fire,
                Display(
                    "[AXI-AR] cycle=%d id=%d addr=0x%x len=%d size=%d burst=%d",
                    cycle, bus.ar.id, bus.ar.addr, bus.ar.len,
                    bus.ar.size, bus.ar.burst,
                )
            ),
            If((event_count < log_limit) & r_fire,
                Display(
                    "[AXI-R] cycle=%d id=%d data=0x%x resp=%d last=%d",
                    cycle, bus.r.id, bus.r.data, bus.r.resp, bus.r.last,
                )
            ),
        ]


class SmokeCompletionMonitor(Module):
    """Ends the finite smoke simulation and reports its architectural result."""

    def __init__(self, done, passed, error, timeout_cycles=1000):
        cycle = Signal(32)
        self.sync += [
            cycle.eq(cycle + 1),
            If(done,
                If(passed,
                    Display("[AXI-SMOKE-PASS] initialized read and write/readback completed"),
                    Finish(),
                ).Else(
                    Display("[AXI-SMOKE-FAIL] error=%d", error),
                    Finish(),
                )
            ),
            If(cycle >= (timeout_cycles - 1),
                Display("[AXI-SMOKE-TIMEOUT] cycle=%d", cycle),
                Finish(),
            ),
        ]


class O3AXISimSoC(SoCMini):
    mem_map = {"csr": LITEX_MMIO_ORIGIN}

    def __init__(self, ram_init, expected_initial_value, debug_axi=False,
                 axi_log_limit=64, timeout_cycles=1000):
        platform = Platform()
        self.submodules.crg = CRG(platform.request("sys_clk"))

        super().__init__(
            platform,
            clk_freq=int(1e6),
            ident="",
            bus_standard="axi",
            bus_data_width=DATA_WIDTH,
            bus_address_width=ADDRESS_WIDTH,
            bus_bursting=False,
            bus_interconnect="shared",
            # Keep one small CSR slave so LiteX does not construct an empty CSR
            # interconnect. The bridge is placed in the approved MMIO window.
            with_ctrl=True,
        )

        memory_axi = axi.AXIInterface(
            data_width=DATA_WIDTH,
            address_width=ADDRESS_WIDTH,
            id_width=AXI_ID_WIDTH,
        )
        self.bus.add_master(name="o3_axi", master=memory_axi)
        self.add_ram(
            name="main_ram",
            origin=MAIN_RAM_ORIGIN,
            size=MAIN_RAM_SIZE,
            contents=ram_init,
        )

        smoke_done = Signal()
        smoke_pass = Signal()
        smoke_error = Signal(4)

        platform.add_source(os.path.join(REPO_ROOT, "rtl", "memory", "axi_master.sv"))
        platform.add_source(os.path.join(
            REPO_ROOT, "rtl", "memory", "axi_memory_smoke_top.sv"
        ))

        self.specials += Instance(
            "axi_memory_smoke_top",
            p_ADDR_WIDTH=ADDRESS_WIDTH,
            p_DATA_WIDTH=DATA_WIDTH,
            p_ID_WIDTH=AXI_ID_WIDTH,
            p_MAIN_RAM_BASE=MAIN_RAM_ORIGIN,
            p_EXPECTED_INIT_DATA=expected_initial_value,
            p_WRITE_DATA=SMOKE_WRITE_VALUE,
            i_clk_i=ClockSignal("sys"),
            i_rst_i=ResetSignal("sys"),
            o_smoke_done_o=smoke_done,
            o_smoke_pass_o=smoke_pass,
            o_smoke_error_o=smoke_error,
            o_m_axi_awid_o=memory_axi.aw.id,
            o_m_axi_awaddr_o=memory_axi.aw.addr,
            o_m_axi_awlen_o=memory_axi.aw.len,
            o_m_axi_awsize_o=memory_axi.aw.size,
            o_m_axi_awburst_o=memory_axi.aw.burst,
            o_m_axi_awlock_o=memory_axi.aw.lock,
            o_m_axi_awcache_o=memory_axi.aw.cache,
            o_m_axi_awprot_o=memory_axi.aw.prot,
            o_m_axi_awqos_o=memory_axi.aw.qos,
            o_m_axi_awregion_o=memory_axi.aw.region,
            o_m_axi_awvalid_o=memory_axi.aw.valid,
            i_m_axi_awready_i=memory_axi.aw.ready,
            o_m_axi_wdata_o=memory_axi.w.data,
            o_m_axi_wstrb_o=memory_axi.w.strb,
            o_m_axi_wlast_o=memory_axi.w.last,
            o_m_axi_wvalid_o=memory_axi.w.valid,
            i_m_axi_wready_i=memory_axi.w.ready,
            i_m_axi_bid_i=memory_axi.b.id,
            i_m_axi_bresp_i=memory_axi.b.resp,
            i_m_axi_bvalid_i=memory_axi.b.valid,
            o_m_axi_bready_o=memory_axi.b.ready,
            o_m_axi_arid_o=memory_axi.ar.id,
            o_m_axi_araddr_o=memory_axi.ar.addr,
            o_m_axi_arlen_o=memory_axi.ar.len,
            o_m_axi_arsize_o=memory_axi.ar.size,
            o_m_axi_arburst_o=memory_axi.ar.burst,
            o_m_axi_arlock_o=memory_axi.ar.lock,
            o_m_axi_arcache_o=memory_axi.ar.cache,
            o_m_axi_arprot_o=memory_axi.ar.prot,
            o_m_axi_arqos_o=memory_axi.ar.qos,
            o_m_axi_arregion_o=memory_axi.ar.region,
            o_m_axi_arvalid_o=memory_axi.ar.valid,
            i_m_axi_arready_i=memory_axi.ar.ready,
            i_m_axi_rid_i=memory_axi.r.id,
            i_m_axi_rdata_i=memory_axi.r.data,
            i_m_axi_rresp_i=memory_axi.r.resp,
            i_m_axi_rlast_i=memory_axi.r.last,
            i_m_axi_rvalid_i=memory_axi.r.valid,
            o_m_axi_rready_o=memory_axi.r.ready,
        )

        if debug_axi:
            self.submodules.axi_monitor = AXITransactionMonitor(
                memory_axi, log_limit=axi_log_limit
            )
        self.submodules.completion_monitor = SmokeCompletionMonitor(
            smoke_done,
            smoke_pass,
            smoke_error,
            timeout_cycles=timeout_cycles,
        )


def main():
    parser = argparse.ArgumentParser(
        description="Build or run the standalone CISLC-O3 AXI memory smoke."
    )
    parser.add_argument("--build", action="store_true", help="Compile and run Verilator.")
    parser.add_argument("--trace", action="store_true", help="Enable waveform tracing.")
    parser.add_argument("--debug-axi", action="store_true",
        help="Print passive AXI channel handshake logs.")
    parser.add_argument("--axi-log-limit", type=int, default=64,
        help="Maximum approximate AXI handshake log count (default: 64).")
    parser.add_argument("--ram-init", help="Raw binary loaded at main-RAM base.")
    parser.add_argument("--timeout", type=int, default=1000,
        help="Simulation timeout in cycles (default: 1000).")
    parser.add_argument("--output-dir", default="build/litex-axi-sim",
        help="LiteX output directory (default: build/litex-axi-sim).")
    args = parser.parse_args()

    if args.timeout <= 0:
        parser.error("--timeout must be greater than zero")
    if args.axi_log_limit <= 0:
        parser.error("--axi-log-limit must be greater than zero")

    if args.ram_init:
        ram_init = get_mem_data(
            args.ram_init,
            data_width=DATA_WIDTH,
            endianness="little",
            mem_size=MAIN_RAM_SIZE,
        )
        if not ram_init:
            parser.error("--ram-init produced no initialization words")
        expected_initial_value = ram_init[0]
    else:
        ram_init = [DEFAULT_INITIAL_VALUE, 0]
        expected_initial_value = DEFAULT_INITIAL_VALUE

    soc = O3AXISimSoC(
        ram_init=ram_init,
        expected_initial_value=expected_initial_value,
        debug_axi=args.debug_axi,
        axi_log_limit=args.axi_log_limit,
        timeout_cycles=args.timeout,
    )
    sim_config = SimConfig()
    sim_config.add_clocker("sys_clk", freq_hz=int(1e6))
    builder = Builder(soc, output_dir=args.output_dir, compile_software=False)
    builder.build(
        run=args.build,
        sim_config=sim_config,
        trace=args.trace,
        interactive=False,
    )


if __name__ == "__main__":
    main()
