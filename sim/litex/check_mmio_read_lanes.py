#!/usr/bin/env python3
"""Exercise upstream AXI-Lite + real wide Wishbone/CSRBank read/write data."""
import argparse
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "litex_wrapper"))
from migen import Module
from migen.sim import run_simulation
from litex.soc.integration.soc import SoCBusHandler, SoCRegion, SoCIORegion
from litex.soc.interconnect import axi, wishbone, csr_bus
from litex.soc.interconnect.csr import CSRStorage
from o3.mmio_bridge import O3MMIOBridge
from o3.platform import platform_regions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", action="store_true", help="reproduce the original full-select read")
    args = parser.parse_args()
    top = Module()
    regions = platform_regions()
    master = axi.AXILiteInterface(data_width=64, address_width=32)
    if args.baseline:
        port = wishbone.Interface(data_width=64, address_width=32, addressing="word")
        top.submodules.mmio = axi.AXILite2Wishbone(master, port)
    else:
        top.submodules.mmio = mmio = O3MMIOBridge(master, regions)
        port = mmio.bus
    top.submodules.bus = bus = SoCBusHandler(standard="wishbone", data_width=64,
        address_width=32, timeout=None, bursting=False, interconnect="shared")
    for name in ("litex_mmio", "plic", "machine_timer"):
        region = regions[name]
        bus.add_region(name+"_io", SoCIORegion(origin=region["origin"], size=region["size"], cached=False))
    bus.add_master(name="cpu", master=port)
    csr_port = csr_bus.Interface(data_width=32, address_width=18, alignment=32)
    top.submodules.csr_bridge = bridge = wishbone.Wishbone2CSR(
        wishbone.Interface(data_width=64, address_width=32, addressing="word"), csr_port, register=True)
    bus.add_slave(name="csr", slave=bridge.wishbone,
        region=SoCRegion(origin=0x12000000, size=0x100000, cached=False))
    regs = [CSRStorage(32, reset=0x13579bdf, name="lower"),
        CSRStorage(32, reset=0x2468ace0, name="upper")]
    top.submodules.bank = csr_bus.CSRBank(regs, address=1, bus=csr_port, paging=0x1000)
    plic = wishbone.Interface(data_width=64, address_width=32, addressing="word")
    clint = wishbone.Interface(data_width=64, address_width=32, addressing="word")
    for name, slave, pma in (("plic", plic, "plic"), ("clint", clint, "machine_timer")):
        region = regions[pma]
        bus.add_slave(name=name, slave=slave, region=SoCRegion(
            origin=region["origin"], size=region["size"], cached=False))
        top.sync += slave.ack.eq(slave.cyc & slave.stb)
    # Independent register values. A threshold read must not select claim.
    top.comb += [plic.dat_r.eq(0x0000000a00000003), clint.dat_r.eq(0x8877665544332211)]

    def read(addr, expected, expected_sel, delay=0):
        yield master.ar.addr.eq(addr)
        yield master.ar.valid.eq(1)
        yield master.r.ready.eq(0)
        for _ in range(50):
            yield
            if (yield port.cyc) and (yield port.stb):
                assert (yield port.sel) == expected_sel, (hex(addr), (yield port.sel))
            if (yield master.ar.ready):
                break
        else:
            raise AssertionError("read address handshake timeout")
        yield master.ar.valid.eq(0)
        for _ in range(50):
            yield
            if (yield master.r.valid):
                break
        else:
            raise AssertionError("read response timeout")
        data = (yield master.r.data)
        assert (yield master.r.resp) == 0
        assert (data >> (8*(addr & 7))) == expected, (hex(addr), hex(data), hex(expected))
        for _ in range(delay):
            yield
            assert (yield master.r.valid) and (yield master.r.data) == data
        yield master.r.ready.eq(1)
        yield
        yield master.r.ready.eq(0)
        for _ in range(3):
            yield

    def write(addr, value, mask):
        yield master.aw.addr.eq(addr)
        yield master.aw.valid.eq(1)
        yield master.w.data.eq(value << (8*(addr & 7)))
        yield master.w.strb.eq(mask)
        yield master.w.valid.eq(1)
        yield master.b.ready.eq(0)
        for _ in range(50):
            yield
            if (yield port.cyc) and (yield port.stb):
                assert (yield port.sel) == mask
            if (yield master.aw.ready) and (yield master.w.ready):
                break
        else:
            raise AssertionError("write handshake timeout")
        yield master.aw.valid.eq(0)
        yield master.w.valid.eq(0)
        for _ in range(50):
            yield
            if (yield master.b.valid):
                break
        else:
            raise AssertionError("write response timeout")
        assert (yield master.b.resp) == 0
        for _ in range(4):
            yield
            assert (yield master.b.valid)
        yield master.b.ready.eq(1)
        yield
        yield master.b.ready.eq(0)
        for _ in range(3):
            yield

    def stimulus():
        yield from read(0x12001000, 0x13579bdf, 0x0f, 4)
        yield from read(0x12001004, 0x2468ace0, 0xf0, 5)
        yield from write(0x12001004, 0xdeadbeef, 0xf0)
        yield from write(0x12001000, 0x89abcdef, 0x0f)
        yield from read(0x12001000, 0x89abcdef, 0x0f)
        yield from read(0x12001004, 0xdeadbeef, 0xf0)
        # Mock PLIC data is a full word; use masks to prove no adjacent claim
        # side effect, and extract the proper 32-bit half for each address.
        yield from read(0x0c200000, 0x0000000a00000003, 0x0f, 3)
        yield from read(0x0c200004, 10, 0xf0, 3)
        yield from read(0x0200bff8, 0x8877665544332211, 0xff, 3)
    run_simulation(top, stimulus())
    print("PASS: real 64-bit Wishbone/32-bit CSRBank lower/upper data, writes, stalled R/B; PLIC read selects and full-width CLINT")


if __name__ == "__main__":
    main()
