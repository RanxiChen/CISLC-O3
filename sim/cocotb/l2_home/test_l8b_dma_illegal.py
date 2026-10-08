"""Negative assertion probe; run separately and require the named RTL fatal."""
import cocotb
from mem_agents import Bench, GETS
from test_l2_home import BASE


@cocotb.test()
async def illegal_dma_gets_triggers_port_op_assertion(d):
    e = Bench(d)
    await e.reset()
    e.submit(2, GETS, BASE, tid=0)
    for _ in range(20):
        await e.tick()
    assert False, 'DMA opcode assertion failed to fire'
