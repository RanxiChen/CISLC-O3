#!/usr/bin/env python3
"""Check the LiteX 64-bit bus/32-bit CSR path across the PMA window.

Execute on the selected simulation host. The CSR data source is zero, so
this proves bridge completion/addressing, not any peripheral's behavior.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "litex_wrapper"))

from migen import Module, Signal
from migen.sim import run_simulation
from litex.soc.integration.soc import SoCBusHandler, SoCRegion, SoCIORegion
from litex.soc.interconnect import csr_bus, wishbone
from o3.platform import load_platform, platform_regions, csr_address_width


def main():
    config = load_platform()
    region = platform_regions(config=config)["litex_mmio"]
    # Independent constants from the reviewed CSR revision.
    assert (region["origin"], region["size"], csr_address_width(config)) == (0x12000000, 0x100000, 18)
    top = Module()
    top.submodules.bus = bus = SoCBusHandler(standard="wishbone", data_width=64,
        address_width=32, timeout=None, bursting=False, interconnect="shared")
    bus.add_region("io", SoCIORegion(origin=region["origin"], size=region["size"], cached=False))
    master = wishbone.Interface(data_width=64, address_width=32, addressing="word")
    top.submodules.bridge = bridge = wishbone.Wishbone2CSR(
        bus_wishbone=wishbone.Interface(data_width=64, address_width=32, addressing="word"),
        bus_csr=csr_bus.Interface(data_width=32, address_width=csr_address_width(config)), register=True)
    decoded = SoCRegion(origin=region["origin"], size=region["size"], cached=False)
    bus.add_master(name="cpu", master=master)
    bus.add_slave(name="csr", slave=bridge.wishbone, region=decoded)
    selected = Signal()
    top.comb += [bridge.csr.dat_r.eq(0), selected.eq(decoded.decoder(bus)(master.adr))]

    def stimulus():
        # Every page, including unallocated pages above the old 64KiB limit.
        addresses = [0x12000000 + page * 0x1000 for page in range(256)]
        addresses += [0x120FFFF8, 0x120FFFFC]
        for write in (0, 1):
            for addr in addresses:
                yield master.adr.eq(addr >> 3)
                yield master.sel.eq(0xF0 if addr & 4 else 0x0F)
                yield master.dat_w.eq(0x1234567812345678)
                yield master.we.eq(write)
                yield master.cyc.eq(1)
                yield master.stb.eq(1)
                seen = []
                for _ in range(30):
                    yield
                    assert (yield selected) == 1, hex(addr)
                    assert (yield master.err) == 0, hex(addr)
                    if (yield bridge.csr.we) or (yield bridge.csr.re):
                        seen.append((yield bridge.csr.adr))
                    if (yield master.ack):
                        break
                else:
                    raise AssertionError(f"CSR request did not ACK: {addr:#x}, write={write}")
                assert seen == [(addr - 0x12000000) >> 2], (hex(addr), seen)
                yield master.cyc.eq(0)
                yield master.stb.eq(0)
                for _ in range(4):
                    yield
        # These probes intentionally bypass PMA only to check the decoder.
        # No timeout is installed: outside the window must never select CSR.
        for addr in (0x11FFFFF8, 0x12100000, 0x12FFFFF8, 0x13000000):
            yield master.adr.eq(addr >> 3)
            yield master.cyc.eq(1)
            yield master.stb.eq(1)
            for _ in range(10):
                yield
                assert (yield selected) == 0, hex(addr)
                assert (yield master.ack) == 0, hex(addr)
                assert (yield bridge.csr.re) == 0 and (yield bridge.csr.we) == 0, hex(addr)
            yield master.cyc.eq(0)
            yield master.stb.eq(0)
            yield

    run_simulation(top, stimulus())
    print("PASS: 516 CSR read/write requests ACK with full address; 4 outside-window probes never select CSR")


if __name__ == "__main__":
    main()
