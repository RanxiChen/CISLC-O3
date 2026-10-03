"""RQ L1 order, identity, completion, and second-request backpressure."""
import os
import random

import cocotb
from cocotb.triggers import ReadOnly, Timer
from fetch_return_queue_model import Inputs, ReturnModel


def val(signal):
    return int(signal.value)


class Bench:
    def __init__(self, dut, seed):
        self.dut = dut
        self.seed = seed
        self.cycle = 0
        self.model = ReturnModel()

    def drive(self, i):
        d = self.dut
        d.clk_i.value = 0
        d.rst_i.value = int(i.rst)
        d.rsv_fire_i.value = int(i.reserve)
        d.rsv_ftq_id_i.value = i.reserve_id
        d.rsv_region_base_i.value = i.reserve_pc
        d.resp_valid_i.value = int(i.response)
        d.resp_rq_idx_i.value = i.response_idx
        d.resp_ftq_id_i.value = i.response_id
        d.resp_data_i.value = i.response_data
        d.brief_slow_done_i.value = int(i.brief_done)
        d.brief_ftq_id_i.value = i.brief_id
        d.deq_ready_i.value = int(i.deq_ready)
        d.kill_valid_i.value = int(i.kill)

    def check(self, i, phase):
        if self.cycle == 0 and i.rst and phase == "before":
            return
        d = self.dut
        ready, brief_read, deq, entry = self.model.visible(i)
        context = f"seed={self.seed} cycle={self.cycle} {phase} inputs={i}"
        assert val(d.rsv_ready_o) == ready and val(d.rsv_idx_o) == 0, context
        assert val(d.brief_rd_valid_o) == brief_read, context
        assert val(d.deq_valid_o) == deq, context
        if entry is not None:
            assert val(d.brief_rd_id_o) == entry.ftq_id, context
        if deq:
            assert val(d.deq_ftq_id_o) == entry.ftq_id, context
            assert val(d.deq_region_base_o) == entry.pc, context
            assert val(d.deq_data_o) == entry.data, context
            assert val(d.deq_brief_id_o) == entry.ftq_id, context

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
    b = Bench(dut, 0)
    await b.step(Inputs(rst=True))
    assert val(dut.cfg_region_bytes_o) == 16
    await b.step(Inputs(reserve=True, reserve_id=3, reserve_pc=0x10000000))
    # An early second request cannot overwrite the first identity.
    await b.step(Inputs(reserve=True, reserve_id=4, reserve_pc=0x10000010))
    await b.step(Inputs(response=True, response_id=3,
                        response_data=0x00400213003001930020011300100093,
                        brief_id=3, brief_done=False))
    await b.step(Inputs(brief_id=3, brief_done=False, deq_ready=True))
    await b.step(Inputs(brief_id=4, brief_done=True, deq_ready=True))
    await b.step(Inputs(brief_id=3, brief_done=True, deq_ready=False))
    await b.step(Inputs(brief_id=3, brief_done=True, deq_ready=True))
    await b.step(Inputs(reserve=True, reserve_id=4, reserve_pc=0x10000010))
    await b.step(Inputs(response=True, response_id=3, response_data=99,
                        brief_id=4, brief_done=True))
    await b.step(Inputs(response=True, response_id=4, response_data=77,
                        brief_id=4, brief_done=True))
    await b.step(Inputs(brief_id=4, brief_done=True, deq_ready=True))
    await b.step(Inputs(rst=True))


@cocotb.test()
async def seeded_transactions(dut):
    seed = int(os.environ.get("TEST_SEED", "1"), 0)
    rng = random.Random(seed)
    b = Bench(dut, seed)
    await b.step(Inputs(rst=True))
    for cycle in range(200):
        entry = b.model.entry
        rid = entry.ftq_id if entry else 0
        await b.step(Inputs(
            reserve=rng.random() < 0.6,
            reserve_id=(cycle + 1) & ((1 << len(dut.rsv_ftq_id_i)) - 1),
            reserve_pc=0x10000000 + 16 * cycle,
            response=rng.random() < 0.5,
            response_id=rid if rng.random() < 0.8 else rid + 1,
            response_idx=0 if rng.random() < 0.9 else 1,
            response_data=rng.getrandbits(8 * val(dut.cfg_region_bytes_o)),
            brief_done=rng.random() < 0.7,
            brief_id=rid if rng.random() < 0.8 else rid + 1,
            deq_ready=rng.random() < 0.7,
            kill=rng.random() < 0.02,
        ))
