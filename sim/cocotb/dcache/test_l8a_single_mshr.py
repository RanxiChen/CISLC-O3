"""Supplemental MSHRS=1 coverage; existing four-MSHR cases remain unchanged."""
import cocotb
from l8a_agents import *
from test_dcache import env


@cocotb.test()
async def single_mshr_full_waits_on_mshr_free(dut):
    e = await env(dut)
    assert e.n == 1
    e.block_gets = True
    first = (await e.issue(Cpu(BASE, head=False)))[0]
    assert first['status'] == MISS and first['reason'] == MSHR
    await e.until(lambda: len(e.sent) == 1)
    blocked = (await e.issue(Cpu(BASE + 64, head=True)))[0]
    assert blocked['status'] == REPLAY and blocked['reason'] == FULL
    start = len(e.wakes)
    for _ in range(20):
        await e.tick()
    assert not any(w['free'] for _, w in e.wakes[start:])
    assert int(dut.mon_ms_valid.value) == 1
    e.block_gets = False
    await e.until(lambda: any(w['free'] for _, w in e.wakes[start:]))
    assert not any(w['wb_free'] for _, w in e.wakes[start:])
    assert (await e.load(BASE + 64))['data'] == e.golden(BASE + 64)
    await e.idle()
