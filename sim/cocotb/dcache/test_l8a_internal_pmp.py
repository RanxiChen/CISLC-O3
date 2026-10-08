"""Committed drains retain STA authorization; page-table clients still check PMP."""
import cocotb
from l8a_agents import CacheBench, Cpu, BASE, OK, ERROR


@cocotb.test()
async def committed_drain_authorized_at_sta_ptw_ad_still_check_pmp(dut):
    e = CacheBench(dut)
    await e.reset()
    dut.pmp_i.value = 0
    assert (await e.issue(Cpu(BASE + 8, sta=True)))[0]['status'] == OK
    assert (await e.store(BASE + 8, 0x8877665544332211))['status'] == OK
    assert (await e.load(BASE + 8))['data'] == 0x8877665544332211
    await e.idle()
    before = len(e.events)
    e.ptw = Cpu(BASE + 8, src=3)
    await e.until(lambda: e.ptw_responses)
    r = e.ptw_responses[-1][1]
    assert r['status'] == ERROR
    assert r['exc'] >> 70 == 1 and (r['exc'] >> 64) & 63 == 5
    assert r['exc'] & ((1 << 64) - 1) == BASE + 8
    e.ad = (BASE + 8, 0x8877665544332211, 1, 1, 0)
    await e.until(lambda: e.ad_responses)
    # valid=1, success=0, mismatch=0, error=1.
    assert e.ad_responses[-1][1] == 9
    assert len(e.events) == before
    assert (await e.load(BASE + 8))['data'] == 0x8877665544332211
    await e.idle()
