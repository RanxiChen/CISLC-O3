import random

import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def younger_load_bypasses_unready_store_but_replay_gate_keeps_stores_live(d):
    rng = random.Random(1)
    for name in ("clk", "enq_valid", "enq_store", "enq_load", "enq_wait_src",
                 "enq_rob", "allow_load", "issue_ready", "wakeup"):
        getattr(d, name).value = 0
    d.rst.value = 1

    async def tick():
        d.clk.value = 0
        await Timer(5, unit="ns")
        obs = (int(d.issue_valid.value), int(d.issue_rob.value),
               int(d.issue_store.value), int(d.issue_load.value))
        d.clk.value = 1
        await Timer(5, unit="ns")
        return obs

    await tick()
    d.rst.value = 0
    d.allow_load.value = 1
    d.enq_valid.value = 1
    d.enq_store.value = 1
    d.enq_wait_src.value = 1
    d.enq_rob.value = 1
    await tick()
    d.enq_store.value = 0
    d.enq_load.value = 1
    d.enq_wait_src.value = 0
    d.enq_rob.value = 2
    await tick()
    d.enq_valid.value = 0
    assert (await tick()) == (1, 2, 0, 1)
    for _ in range(12):
        allow = rng.randrange(2)
        d.allow_load.value = allow
        obs = await tick()
        assert obs == ((1, 2, 0, 1) if allow else (0, 0, 0, 0)), obs
    d.allow_load.value = 1
    d.issue_ready.value = 1
    await tick()  # younger load leaves IQ and enters LSU replay
    d.allow_load.value = 0
    for _ in range(10):
        assert (await tick())[0] == 0  # older store still lacks its source
    d.wakeup.value = 1
    await tick()
    d.wakeup.value = 0
    assert (await tick()) == (1, 1, 1, 0)
    await tick()
    assert (await tick())[0] == 0
