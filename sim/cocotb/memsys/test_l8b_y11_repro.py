"""Characterize Y11's observed physical order; the original VM check stays failing.

The cache cannot retroactively replace a response delivered before the A CAS.
This diagnostic distinguishes that ordering gap from an omitted PTE write.
"""
import cocotb
from system_agents import SystemBench, Cpu, OK


@cocotb.test()
async def y11_early_pte_read_then_a_cas_then_translated_data_read(d):
    e = SystemBench(d, 66)
    await e.reset()
    d.cur_epoch_i.value = 2
    pte_addr, data_addr, old = 0x80102038, 0x80103000, 0x20040c07
    offset = (pte_addr & 63) * 8
    image = {pte_addr >> 6: old << offset, data_addr >> 6: 0x11223344}
    initial = e.initial
    e.initial = lambda line: image.get(line, initial(line))
    await e.loads([Cpu(pte_addr)])
    e.ptw = Cpu(pte_addr, src=3)
    await e.until(lambda: bool(e.ptw_responses), 5000)
    assert e.ptw_responses[-1][1]['status'] == OK
    assert e.ptw_responses[-1][1]['data'] == old

    # Actual core order: walker read c16661, younger CPU read c16663,
    # A CAS request c16664/write c16669, translated older data read c16676.
    young = (await e.issue(Cpu(pte_addr, rob=4)))[0]
    assert young['status'] == OK and young['data'] == old
    early_cycle = e.responses[-1][0]
    e.ad = (pte_addr, old, 1, 0, 2)
    await e.until(lambda: bool(e.ad_responses), 5000)
    cas_cycle, answer = e.ad_responses[-1]
    assert answer == 12
    e.gold[pte_addr >> 6] = (old | 0x40) << offset
    e.history.setdefault(pte_addr >> 6, []).append((cas_cycle, e.gold[pte_addr >> 6]))
    await e.loads([Cpu(data_addr, va=0x7000, rob=1)])
    data_cycle = e.responses[-1][0]
    await e.loads([Cpu(pte_addr, rob=4)])
    assert e.responses[-1][2]['data'] == old | 0x40
    assert early_cycle < cas_cycle < data_cycle
    d._log.info('Y11 physical order: early_PTE=%d value=%#x CAS=%d new_PTE=%#x data=%d; original VM requires replay of the early response',
                early_cycle, young['data'], cas_cycle, old | 0x40, data_cycle)
    await e.finish()
