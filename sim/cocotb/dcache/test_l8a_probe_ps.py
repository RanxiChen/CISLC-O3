"""PS-side probe hold coverage supplements the existing MSHR WAIT case."""
import cocotb
from l8a_agents import *
from test_dcache import env


@cocotb.test()
async def probe_waits_for_ps_write(dut):
    e = await env(dut)
    await e.load(BASE)
    value = 0x9abcdef012345678
    e.st = Cpu(BASE, write=True, src=1, data=value)
    await e.until(lambda: int(dut.mon_ps_alloc.value))
    e.snp = (0, 1, BASE >> 6)
    await e.tick()
    assert e.snp_sent and int(dut.mon_ps_valid.value)
    assert int(dut.mon_probe_hold.value) and not int(dut.mon_probe_read.value)
    assert int(dut.mon_ps_write.value)
    ps_cycle = e.cycle
    await e.tick()
    assert e.st_responses[-1][1]['status'] == OK
    e.gold[BASE >> 6] = (e.initial(BASE >> 6) & ~((1 << 64) - 1)) | value
    await e.until(lambda: e.snp is None)
    q = e.up[-1][1]
    assert e.up[-1][0] > ps_cycle
    assert q['op'] == 1 and q['dirty'] == 1 and q['data'] == e.gold[BASE >> 6]
    assert e.state(BASE) == 0
    assert (await e.load(BASE))['data'] == value
    await e.idle()
