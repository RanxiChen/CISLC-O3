import random
import cocotb
from mem_agents import Bench, GETS, GETM, READ, DATAE, ACKE, READDATA

BASE = 0x80000000 >> 6


async def env(dut, seed=1):
    e = Bench(dut, seed)
    await e.reset()
    return e


@cocotb.test()
async def gets_miss_and_none_hit(dut):
    e = await env(dut)
    t = await e.acquire(BASE)
    assert t.result == (DATAE, 0, e.golden(BASE))
    e.evict(BASE)
    await e.until(e.idle)
    before = len(e.reads)
    t = await e.acquire(BASE)
    assert t.result == (DATAE, 0, e.golden(BASE))
    assert len(e.reads) == before
    await e.finish()


@cocotb.test()
async def getm_miss_and_none_hit(dut):
    e = await env(dut)
    t = await e.acquire(BASE, write=True)
    assert t.result[0] == DATAE
    e.evict(BASE)
    await e.until(e.idle)
    before = len(e.reads)
    t = await e.acquire(BASE, write=True)
    assert t.result[0] == DATAE and len(e.reads) == before
    await e.finish()


@cocotb.test()
async def shared_upgrade_acke(dut):
    e = await env(dut)
    await e.acquire(BASE)
    await e.read(BASE)
    assert e.copies[BASE][0] == 'S'
    t = await e.acquire(BASE, write=True)
    assert t.result[0] == ACKE and len(e.reads) == 1
    await e.finish()


@cocotb.test()
async def clean_put(dut):
    e = await env(dut)
    await e.acquire(BASE)
    e.evict(BASE, tid=1)
    await e.until(e.idle)
    assert any(x[1:] == ('up', 0, BASE, False) for x in e.events)
    t = await e.read(BASE)
    assert t.result == (READDATA, 0, e.golden(BASE))
    await e.finish()


@cocotb.test()
async def dirty_put(dut):
    e = await env(dut)
    await e.acquire(BASE, write=True)
    e.store(BASE, 8, 8, 0xfeed1234abcdef01)
    e.evict(BASE)
    await e.until(e.idle)
    t = await e.read(BASE)
    assert t.result[2] == e.golden(BASE)
    assert any(x[1:] == ('up', 0, BASE, True) for x in e.events)
    await e.finish()


@cocotb.test()
async def read_miss_and_hit(dut):
    e = await env(dut)
    for _ in range(2):
        t = await e.read(BASE)
        assert t.result == (READDATA, 0, e.golden(BASE))
    assert e.reads == [BASE]
    assert not e.held
    await e.finish()


@cocotb.test()
async def read_unique_down_latest(dut):
    e = await env(dut)
    await e.acquire(BASE, write=True)
    e.store(BASE, 0, 8, 0x123456789abcdef0)
    e.probe_delay = 7
    t = await e.read(BASE)
    assert t.result[2] == e.golden(BASE)
    assert e.copies[BASE][0] == 'S'
    assert any(x[1:] == ('probe', 1, 1, BASE) for x in e.events)
    assert any(x[1:] == ('up', 2, BASE, True) for x in e.events)
    await e.finish()


@cocotb.test()
async def replacement_unique_inv_dirty_axi(dut):
    e = await env(dut)
    e.backpressure = True
    for k in range(e.ways + 2):
        line = BASE + k * e.sets
        await e.acquire(line, write=True)
        e.store(line, 16, 8, 0x10101010101 * (k + 1))
    await e.until(e.idle)
    assert any(x[1] == 'probe' and x[2] == 0 and x[3] == 1 for x in e.events)
    assert e.writes
    for line, data in e.writes:
        assert data == e.golden(line)
    await e.finish()


@cocotb.test()
async def same_set_serialization(dut):
    e = await env(dut)
    e.block_r = True
    a = e.submit(0, GETS, BASE)
    await e.until(lambda: a.accepted)
    b = e.submit(1, READ, BASE + e.sets)
    for _ in range(30):
        await e.tick()
        assert not b.accepted
    e.block_r = False
    await e.until(lambda: a.result is not None and b.result is not None)
    await e.finish()


@cocotb.test()
async def axi_read_error_not_installed(dut):
    e = await env(dut)
    for c in (0, 1):
        line = BASE + c
        e.errors.add(line)
        t = await (e.acquire(line, error=True) if c == 0 else e.read(line, error=True))
        assert t.result[1] == 1
        e.errors.remove(line)
        before = len(e.reads)
        t = await (e.acquire(line) if c == 0 else e.read(line))
        assert t.result[1] == 0 and len(e.reads) == before + 1
    await e.finish()


@cocotb.test()
async def slot_full_backpressure_and_resume(dut):
    e = await env(dut)
    # Run this test with SETS=4,Ways=2,SLOTS=2, allowing a third set.
    assert e.sets > e.slots
    e.block_r = True
    a = e.submit(0, GETS, BASE, tid=0)
    await e.until(lambda: a.accepted)
    b = e.submit(1, READ, BASE + 1, tid=0)
    await e.until(lambda: b.accepted)
    c = e.submit(0, GETS, BASE + 2, tid=1)
    await e.until(lambda: e.slot_full > 0)
    for _ in range(30):
        await e.tick()
        assert not c.accepted
    e.block_r = False
    await e.until(lambda: all(t.result is not None for t in (a, b, c)))
    await e.finish()


async def random_traffic(dut, seed):
    e = await env(dut, seed)
    assert (e.sets, e.ways, e.slots) == (2, 2, 2)
    e.backpressure = True
    e.probe_delay = 3
    rng = random.Random(seed)
    lines = [BASE + k for k in range(16)]
    # At least 2000 accepted D Get/Put transactions plus 500 concurrent I Reads.
    e.i_script.extend(rng.choice(lines) for _ in range(500))
    n = 0
    def d_transactions():
        return sum(x[1] == "req" and x[2] == 0 or x[1] == "up" and x[2] == 0 for x in e.events)
    while d_transactions() < 2000:
        line = rng.choice(lines)
        action = rng.randrange(10)
        if action < 4:
            await e.acquire(line)
        elif action < 8:
            await e.acquire(line, write=True)
            await e.until(lambda: not e.line_busy(line))
            # A replacement from concurrent I traffic may have invalidated it.
            while e.copies.get(line, ('I', 0))[0] not in ('E', 'M'):
                await e.acquire(line, write=True)
                await e.until(lambda: not e.line_busy(line))
            size = 1 << rng.randrange(4)
            offset = rng.randrange(64 // size) * size
            e.store(line, offset, size, rng.getrandbits(size * 8))
        else:
            await e.until(lambda: not e.line_busy(line))
            if line in e.copies:
                e.evict(line, tid=n % 2)
                await e.until(lambda: not e.puts)
        await e.tick()
        n += 1
    await e.until(e.idle)
    assert e.i_done == 500
    assert e.writes, 'random traffic did not exercise dirty AXI writeback'
    await e.finish()
    assert d_transactions() >= 2000
    dut._log.info('seed=%d accepted_D_Get_Put=%d D_actions=%d concurrent_I_reads=500', seed, d_transactions(), n)


@cocotb.test()
async def random_seed_51(dut):
    await random_traffic(dut, 51)


@cocotb.test()
async def random_seed_52(dut):
    await random_traffic(dut, 52)
