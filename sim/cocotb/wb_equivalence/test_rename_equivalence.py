"""Stateful, all-public-output comparison against unchanged rename RTL."""
import os
import random

import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def stateful_rename_equivalence(dut):
    rng = random.Random(int(os.environ.get("TEST_SEED", "1")))
    dut.clk_i.value = 0
    dut.rst_i.value = 1
    dut.stim_i.value = 0
    await Timer(2, unit="ns")
    masks = {name: int(getattr(dut, "fmt_" + name).value)
             for name in ("valid", "quiet", "robs", "kill", "reset")}
    dut.stim_i.value = masks["reset"]
    for _ in range(3):
        dut.clk_i.value = 1
        await Timer(2, unit="ns")
        dut.clk_i.value = 0
        await Timer(2, unit="ns")
    dut.rst_i.value = 0
    for cycle in range(12000):
        stimulus = rng.getrandbits(len(dut.stim_i)) & ~masks["reset"]
        phase = cycle % 257
        if phase < 220:
            # Long epochs fill/reuse the free bitmap and checkpoint state.
            # Alternate dense and sparse requests; retain random commit,
            # release, snapshot identities and branch dependencies.
            stimulus &= ~masks["quiet"]
            if phase % 4 < 2:
                stimulus |= masks["valid"]
            if phase % 16 == 0:
                stimulus &= ~masks["robs"]
            elif phase % 16 == 1:
                stimulus |= masks["robs"]
        elif phase == 255:
            stimulus |= masks["kill"]
        elif phase == 256:
            stimulus = masks["reset"]
        dut.stim_i.value = stimulus
        await Timer(2, unit="ns")
        dut.clk_i.value = 1
        await Timer(2, unit="ns")
        dut.clk_i.value = 0
    dut.stim_i.value = 0
    for _ in range(3):
        await Timer(2, unit="ns")
        dut.clk_i.value = 1
        await Timer(2, unit="ns")
        dut.clk_i.value = 0
