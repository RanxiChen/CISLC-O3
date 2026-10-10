"""Compare every arbiter output against frozen RTL, including invalid data."""
import os
import random

import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def full_output_equivalence(dut):
    rng = random.Random(int(os.environ.get("TEST_SEED", "1")))
    dut.clk_i.value = 0
    dut.rst_i.value = 1
    dut.stim_i.value = 0
    await Timer(2, unit="ns")
    masks = {name: int(getattr(dut, "fmt_" + name).value)
             for name in ("valid", "clear_dense", "quiet", "robs", "kill")}
    reset = int(dut.fmt_reset.value) if hasattr(dut, "fmt_reset") else 0
    dut.stim_i.value = reset
    for _ in range(3):
        dut.clk_i.value = 1
        await Timer(2, unit="ns")
        dut.clk_i.value = 0
        await Timer(2, unit="ns")
    dut.rst_i.value = 0
    for cycle in range(6000):
        stimulus = rng.getrandbits(len(dut.stim_i))
        mode = cycle % 16
        if 1 <= mode <= 12:
            stimulus &= ~(masks["quiet"] | masks["clear_dense"])
            stimulus |= masks["valid"]
        if mode == 12:
            # All sources have the same ROB age: preserve source-order ties.
            stimulus &= ~masks["robs"]
        elif mode == 13:
            stimulus |= masks["kill"]
        if reset and mode != 14:
            stimulus &= ~reset
        dut.stim_i.value = stimulus
        await Timer(2, unit="ns")
        dut.clk_i.value = 1
        await Timer(2, unit="ns")
        dut.clk_i.value = 0
    for _ in range(3):
        await Timer(2, unit="ns")
        dut.clk_i.value = 1
        await Timer(2, unit="ns")
        dut.clk_i.value = 0
