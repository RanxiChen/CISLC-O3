"""Use upstream AXI-Lite/Wishbone handshakes with 32-bit register read lanes.

AXI-Lite has no ARSIZE/RSTRB. O3 retains the byte address until the response;
CSR and PLIC registers occupy 32-bit slots, while CLINT reads remain 64-bit.
This adapter does not add error propagation to the upstream bridge.
"""
from migen import Constant, Module, Mux
from litex.soc.interconnect import axi, wishbone


class O3MMIOBridge(Module):
    def __init__(self, master, regions):
        if master.data_width != 64:
            raise ValueError("O3 MMIO requires the frozen 64-bit AXI-Lite interface")
        raw = wishbone.Interface(data_width=64, address_width=32, addressing="word")
        self.bus = wishbone.Interface(data_width=64, address_width=32, addressing="word")
        self.submodules.bridge = axi.AXILite2Wishbone(master, raw)
        narrow = Constant(0)
        for name in ("plic", "litex_mmio"):
            region = regions[name]
            narrow = narrow | ((master.ar.addr >= region["origin"]) &
                (master.ar.addr < region["origin"] + region["size"]))
        self.comb += raw.connect(self.bus, omit={"sel"})
        self.comb += self.bus.sel.eq(Mux(raw.we, raw.sel,
            Mux(narrow, Mux(master.ar.addr[2], 0xf0, 0x0f), 0xff)))
