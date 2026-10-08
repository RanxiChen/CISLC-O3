import cocotb
from system_agents import SystemBench, Cpu, BASE


async def random_traffic(dut, seed):
    e = SystemBench(dut, seed)
    await e.reset()
    # Dense working set exceeds L1D, with repeated hot lines and same-set aliases.
    count = max(32, e.sets * e.ways * 2)
    lines = [BASE + 64 * k for k in range(count)]
    aliases = [BASE + 64 * e.l2sets * k for k in range(16)]
    def addr():
        pool = aliases if e.rng.randrange(4) == 0 else lines
        return e.rng.choice(pool) + 8 * e.rng.randrange(8)
    completed = 0
    next_i = 0
    while completed < 2000:
        while next_i < 500 and next_i * 4 <= completed:
            e.i_script.append(e.rng.choice(lines + aliases) >> 6)
            next_i += 1
        choice = e.rng.randrange(10)
        if choice < 6 and completed < 1999:
            a, b = addr(), addr()
            if e.rng.randrange(5) == 0:
                b = (a & ~63) + 8 * e.rng.randrange(8)
            await e.loads([Cpu(a, ident=1, lane=0, rob=1),
                           Cpu(b, ident=2, lane=1, rob=2, head=False)])
            completed += 2
        elif choice < 8 or completed == 1999:
            await e.sta(Cpu(addr(), sta=True, ident=3, lane=e.rng.randrange(2)))
            completed += 1
        else:
            a = addr()
            await e.sta(Cpu(a, sta=True, ident=3, lane=e.rng.randrange(2)))
            await e.store(a, e.rng.getrandbits(64), mask=e.rng.choice([255,15,240,3,192]))
            completed += 2
    assert completed == 2000 and next_i == 500
    assert e.loads_done + e.stas_done + e.stores_done == 2000
    await e.finish()
    assert e.i_done == 500
    dut._log.info('M3 completed exactly %d CPU operations and %d I Reads', completed, e.i_done)


@cocotb.test()
async def random_seed_61(dut):
    await random_traffic(dut, 61)


@cocotb.test()
async def random_seed_62(dut):
    await random_traffic(dut, 62)


@cocotb.test()
async def l3_committed_main_stores_with_reset_pmp(dut):
    """M5 L3 retired memory sequence, with reset PMP and M-mode STA authorization."""
    e = SystemBench(dut, 63)
    await e.reset()
    dut.pmp_i.value = 0
    a = 0x80010000
    original = e.initial
    image = {a >> 6: 0x8877665544332211 | (0x1122334455667788 << 128),
             (a + 64) >> 6: 0x99}
    e.initial = lambda line: image.get(line, original(line))
    await e.loads([Cpu(a)])
    await e.sta(Cpu(a + 8, sta=True))
    await e.store(a + 8, 0x8877665544332211)
    await e.loads([Cpu(a + 8)])
    for _ in range(40):
        await e.loads([Cpu(a + 16)])
        await e.sta(Cpu(a + 24, sta=True))
        await e.store(a + 24, 4)
        await e.loads([Cpu(a + 24)])
    assert e.loads_done == 82 and e.stas_done == 41 and e.stores_done == 41
    await e.finish()


@cocotb.test()
async def l10_protected_load_then_store_fault_sequence(dut):
    """M5 phase15/16: LSU's denied S-mode accesses cannot modify cache state."""
    from system_agents import ERROR
    e = SystemBench(dut, 64)
    await e.reset()
    a = 0x80100000
    before = int(dut.mon_plru.value)
    for cause, sta in ((5, False), (7, True)):
        exc = (1 << 70) | (cause << 64) | a
        r = (await e.issue(Cpu(a, size=2, sta=sta, exc=exc)))[0]
        assert r['status'] == ERROR and r['exc'] == exc
        assert int(dut.mon_ms_valid.value) == 0 and int(dut.mon_plru.value) == before
        assert not e.sent and not e.held and not e.gold
    await e.loads([Cpu(0x80004000)])
    await e.finish()


@cocotb.test()
async def l10_ad_first_writer_refresh_sequence(dut):
    """Physical cache sequence at l10_ad PC 0x80000178; translation is in M4."""
    e = SystemBench(dut,65)
    await e.reset()
    pte_addr,data_addr = 0x80102038,0x80103000
    leaf = 0x20040c07
    original = e.initial
    image = {pte_addr >> 6: leaf << (8*(pte_addr & 63)),
             data_addr >> 6: 0x11223344}
    e.initial = lambda line: image.get(line,original(line))
    await e.loads([Cpu(pte_addr)])
    for bit in (0x40,0x80):
        if bit == 0x80:
            await e.loads([Cpu(data_addr)])
            await e.loads([Cpu(pte_addr)])
            await e.sta(Cpu(data_addr,sta=True,rob=14))
        before = len(e.ad_responses)
        e.ad = (pte_addr,leaf,int(bit==0x40),int(bit==0x80),0)
        await e.until(lambda:len(e.ad_responses)>before,5000)
        assert e.ad_responses[-1][1] == 12
        leaf |= bit
        e.gold[pte_addr >> 6] = leaf << (8*(pte_addr & 63))
        e.history.setdefault(pte_addr >> 6,[]).append((e.cycle-1,e.gold[pte_addr >> 6]))
        await e.loads([Cpu(pte_addr)])
    await e.sta(Cpu(data_addr,sta=True,rob=14))
    await e.store(data_addr,0x55667788)
    await e.loads([Cpu(data_addr,rob=15),Cpu(pte_addr,rob=16,lane=1)])
    assert e.golden(data_addr) == 0x55667788 and e.golden(pte_addr) == 0x20040cc7
    await e.finish()
