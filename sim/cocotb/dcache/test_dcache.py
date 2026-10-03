import os
import random

import cocotb
from cocotb.triggers import Timer

from dcache_model import empty_probe_response


@cocotb.test()
async def empty_line_recall_pipeline(dut):
    seed = int(os.environ.get("TEST_SEED", "1"))
    rng = random.Random(seed)
    dut.clk.value = 0
    dut.rst.value = 1
    dut.probe_valid.value = 0
    dut.probe_addr.value = 0
    dut.probe_id.value = 0

    async def tick():
        dut.clk.value = 0
        await Timer(5, unit="ns")
        obs = (
            int(dut.probe_ready.value), int(dut.resp_valid.value),
            int(dut.resp_id.value), int(dut.resp_had_dirty.value),
            int(dut.resp_dirty_data.value),
        )
        dut.clk.value = 1
        await Timer(5, unit="ns")
        return obs

    assert (await tick())[1] == 0
    dut.rst.value = 0
    expected = []
    for cycle in range(24):
        valid = rng.randrange(3) != 0
        recall_id = rng.randrange(1 << len(dut.probe_id))
        dut.probe_valid.value = int(valid)
        dut.probe_addr.value = 0x80000000 + 64 * cycle
        dut.probe_id.value = recall_id
        ready, resp_valid, resp_id, had_dirty, dirty_data = await tick()
        assert ready == 1, f"seed={seed} cycle={cycle} probe blocked"
        if expected:
            assert resp_valid == 1
            assert (resp_id, had_dirty, dirty_data) == expected.pop(0)
        else:
            assert resp_valid == 0
        if valid:
            _, ident, dirty, data = empty_probe_response(1, recall_id)
            expected.append((ident, dirty, data))
    dut.probe_valid.value = 0
    _, resp_valid, resp_id, had_dirty, dirty_data = await tick()
    if expected:
        assert resp_valid == 1
        assert (resp_id, had_dirty, dirty_data) == expected.pop(0)
    assert not expected
