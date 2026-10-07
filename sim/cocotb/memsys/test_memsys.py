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
