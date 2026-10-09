# Adapted from litex_boards.targets.xilinx_kcu105._CRG.
# Copyright (c) 2018-2020 Florent Kermarrec <florent@enjoy-digital.fr>
# SPDX-License-Identifier: BSD-2-Clause
"""KCU105 clock/reset generator without unrelated PCIe/Ethernet imports."""
from migen import ClockDomain, Instance, Signal
from litex.gen import LiteXModule
from litex.soc.cores.clock import USMMCM, USIDELAYCTRL


class O3CRG(LiteXModule):
    def __init__(self, platform, sys_clk_freq):
        self.rst = Signal()
        self.cd_sys = ClockDomain()
        self.cd_sys4x = ClockDomain()
        self.cd_pll4x = ClockDomain()
        self.cd_idelay = ClockDomain()
        self.pll = pll = USMMCM(speedgrade=-2)
        self.comb += pll.reset.eq(platform.request("cpu_reset") | self.rst)
        pll.register_clkin(platform.request("clk125"), 125e6)
        pll.create_clkout(self.cd_pll4x, sys_clk_freq*4, buf=None, with_reset=False)
        pll.create_clkout(self.cd_idelay, 200e6)
        platform.add_false_path_constraints(self.cd_sys.clk, pll.clkin)
        self.specials += [
            Instance("BUFGCE_DIV", p_BUFGCE_DIVIDE=4,
                     i_CE=1, i_I=self.cd_pll4x.clk, o_O=self.cd_sys.clk),
            Instance("BUFGCE", i_CE=1, i_I=self.cd_pll4x.clk, o_O=self.cd_sys4x.clk)]
        self.idelayctrl = USIDELAYCTRL(cd_ref=self.cd_idelay, cd_sys=self.cd_sys)
