import random

import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def younger_load_bypasses_unready_store_but_replay_gate_keeps_stores_live(d):
    rng = random.Random(1)
    for name in ("clk", "enq_valid", "enq_store", "enq_load", "enq_wait_src",
                 "enq_rob", "allow_load", "issue_ready", "wakeup", "issue1_ready"):
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
        assert obs == (1, 2, 0, 1), obs # frozen 7.1: no single-slot replay gate
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


@cocotb.test()
async def loads_issue_in_order_while_store_bypasses_unready_load(d):
    rng = random.Random(1)

    async def tick():
        d.clk.value = 0
        await Timer(5, unit="ns")
        obs = (int(d.issue_valid.value), int(d.issue_rob.value),
               int(d.issue_store.value), int(d.issue_load.value))
        d.clk.value = 1
        await Timer(5, unit="ns")
        return obs

    # Include a live ROB-index wrap: old=max-1, young=0, store=1.
    for old, young, store in ((1, 2, 3), ((1 << len(d.enq_rob)) - 2, 0, 1)):
        for name in ("clk", "enq_valid", "enq_store", "enq_load", "enq_wait_src",
                     "enq_rob", "allow_load", "issue_ready", "wakeup", "issue1_ready"):
            getattr(d, name).value = 0
        d.rst.value = 1
        await tick()
        d.rst.value = 0
        d.allow_load.value = 1
        d.enq_valid.value = 1
        d.enq_load.value = 1
        d.enq_wait_src.value = 1
        d.enq_rob.value = old
        await tick()
        d.enq_wait_src.value = 0
        d.enq_rob.value = young
        await tick()
        d.enq_valid.value = 0
        for _ in range(12):
            d.allow_load.value = rng.randrange(2)
            assert (await tick()) == (1, young, 0, 1), (old, young) # oldest READY bypass

        # A ready store may pass both loads, including with replay occupied.
        d.allow_load.value = 0
        d.enq_valid.value = 1
        d.enq_load.value = 0
        d.enq_store.value = 1
        d.enq_rob.value = store
        await tick()
        d.enq_valid.value = 0
        d.issue_ready.value = 1
        assert (await tick()) == (1, young, 0, 1)
        assert (await tick()) == (1, store, 1, 0)
        assert (await tick()) == (0, 0, 0, 0)

        d.issue_ready.value = 0
        d.wakeup.value = 1
        await tick()
        d.wakeup.value = 0
        assert (await tick()) == (1, old, 0, 1) # no replay gate
        d.allow_load.value = 1
        for _ in range(5):
            assert (await tick()) == (1, old, 0, 1)  # denied handshake keeps young blocked
        d.issue_ready.value = 1
        assert (await tick()) == (1, old, 0, 1)
        assert (await tick()) == (0, 0, 0, 0)


@cocotb.test()
async def dual_oldest_ready_issue_and_independent_handshakes(d):
    for old,young in ((1,2),((1<<len(d.enq_rob))-1,0)):
        for name in ("clk","enq_valid","enq_store","enq_load","enq_wait_src","enq_rob","allow_load","issue_ready","issue1_ready","wakeup"):
            getattr(d,name).value=0
        async def edge():
            d.clk.value=0;await Timer(5,unit='ns');d.clk.value=1;await Timer(5,unit='ns')
        d.rst.value=1;await edge();d.rst.value=0
        for rob in (old,young):
            d.enq_valid.value=1;d.enq_load.value=1;d.enq_rob.value=rob;await edge()
        d.enq_valid.value=0
        await Timer(1,unit='ns')
        assert int(d.issue_valid.value) and int(d.issue1_valid.value)
        assert (int(d.issue_rob.value),int(d.issue1_rob.value))==(old,young)
        for _ in range(12):
            await edge();assert (int(d.issue_rob.value),int(d.issue1_rob.value))==(old,young)
        d.issue1_ready.value=1;await edge();d.issue1_ready.value=0
        assert int(d.issue_valid.value) and int(d.issue_rob.value)==old
        assert not int(d.issue1_valid.value)
        d.issue_ready.value=1;await edge()
        assert not int(d.issue_valid.value) and not int(d.issue1_valid.value)
