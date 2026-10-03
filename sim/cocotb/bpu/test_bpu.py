"""BPU L1 PC, allocation, and no-history/RAS contract."""
import os
import random

import cocotb
from cocotb.triggers import ReadOnly, Timer
from bpu_model import BpuModel, Inputs


def val(signal):
    return int(signal.value)


class Bench:
    def __init__(self, dut, seed):
        self.dut = dut
        self.seed = seed
        self.cycle = 0
        self.model = BpuModel(val(dut.cfg_region_bytes_o), len(dut.boot_pc_i))

    def drive(self, i):
        d = self.dut
        d.clk_i.value = 0
        d.rst_i.value = int(i.rst)
        d.boot_pc_i.value = i.boot_pc
        d.alloc_ready_i.value = int(i.ready)
        d.alloc_ftq_id_i.value = i.ftq_id
        d.hold_i.value = int(i.hold)
        d.recover_busy_i.value = int(i.recover)
        d.kill_valid_i.value = int(i.kill)
        d.train_valid_i.value = int(i.train)

    def check(self, i, phase):
        if self.cycle == 0 and i.rst and phase == "before":
            # cocotb runs both tests in one simulation; reset has not yet
            # sampled the new boot PC at this first edge.
            return
        d = self.dut
        e = self.model.visible(i)
        context = f"seed={self.seed} cycle={self.cycle} {phase} inputs={i}"
        assert val(d.alloc_valid_o) == e["valid"], context
        assert val(d.region_base_o) == e["base"], context
        assert val(d.entry_slot_o) == e["slot"], context
        assert val(d.next_pc_o) == e["next"], context
        actual_completion = (
            val(d.slow_ftq_id_o), val(d.slow_region_base_o), val(d.slow_next_pc_o)
        ) if val(d.slow_valid_o) else None
        assert actual_completion == e["completion"], context
        # These fields enforce the L1 boundary even under repeated allocations.
        assert val(d.cfi_valid_o) == 0 and val(d.ras_action_o) == 0, context
        assert val(d.snapshot_o) == 0 and val(d.ras_ckpt_o) == 0, context
        assert val(d.override_valid_o) == 0 and val(d.train_ready_o) == 1, context

    async def step(self, i):
        self.drive(i)
        await Timer(1, unit="ns")
        await ReadOnly()
        self.check(i, "before")
        await Timer(1, unit="ns")
        self.dut.clk_i.value = 1
        self.model.tick(i)
        await Timer(1, unit="ns")
        await ReadOnly()
        self.check(i, "after")
        await Timer(1, unit="ns")
        self.dut.clk_i.value = 0
        self.cycle += 1


@cocotb.test()
async def directed_contract(dut):
    bench = Bench(dut, 0)
    await bench.step(Inputs(rst=True, boot_pc=0x10000004))
    await bench.step(Inputs(ready=False, ftq_id=3))
    await bench.step(Inputs(ready=True, ftq_id=3))
    await bench.step(Inputs(ready=True, ftq_id=4, hold=True))
    await bench.step(Inputs(ready=True, ftq_id=4))
    await bench.step(Inputs(ready=True, ftq_id=5, recover=True))
    await bench.step(Inputs(ready=True, ftq_id=5, kill=True))
    await bench.step(Inputs(ready=True, ftq_id=5, train=True))
    await bench.step(Inputs(rst=True, boot_pc=0x10000000))


@cocotb.test()
async def seeded_transactions(dut):
    seed = int(os.environ.get("TEST_SEED", "1"), 0)
    rng = random.Random(seed)
    bench = Bench(dut, seed)
    await bench.step(Inputs(rst=True, boot_pc=0x10000000))
    for cycle in range(200):
        await bench.step(Inputs(
            ready=rng.random() < 0.75,
            ftq_id=cycle & ((1 << len(dut.alloc_ftq_id_i)) - 1),
            hold=rng.random() < 0.1,
            recover=rng.random() < 0.05,
            kill=rng.random() < 0.05,
            train=rng.random() < 0.4,
        ))
