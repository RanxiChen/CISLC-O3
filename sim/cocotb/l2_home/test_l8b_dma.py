import random
import cocotb
from mem_agents import Bench, READ, MASKWRITE, READDATA, WRITEACK
from test_l2_home import BASE


async def env(d, seed=1):
    e = Bench(d, seed)
    await e.reset()
    return e


@cocotb.test()
async def dma_maskwrite_unique_dirty_inv_merges_latest_bytes(d):
    e = await env(d)
    await e.acquire(BASE, write=True)
    e.store(BASE, 8, 8, 0xfedcba9876543210)
    old = e.golden(BASE)
    pattern = int.from_bytes(bytes((i + 93) & 255 for i in range(64)), 'little')
    mask = 0x80000000000f0003
    t = await e.dma(BASE, write=True, mask=mask, data=pattern)
    assert t.result[:2] == (WRITEACK, 0)
    assert any(x[1:] == ('dma-flag', 0, 1, BASE, 1) for x in e.events)
    assert any(x[1:] == ('up', 1, BASE, True) for x in e.events)
    expected = bytearray(old.to_bytes(64, 'little'))
    for i in range(64):
        if mask >> i & 1:
            expected[i] = (pattern >> (8 * i)) & 255
    assert e.golden(BASE) == int.from_bytes(expected, 'little')
    assert (await e.read(BASE)).result[2] == int.from_bytes(expected, 'little')
    await e.finish()


@cocotb.test()
async def dma_maskwrite_miss_reads_and_shared_inv_has_dma_bit(d):
    e = await env(d)
    t = await e.dma(BASE, write=True, mask=0x4000000000000010, data=(1 << 511) - 1)
    assert t.result[:2] == (WRITEACK, 0) and e.reads == [BASE]
    await e.acquire(BASE)
    await e.read(BASE)
    assert e.copies[BASE][0] == 'S'
    t = await e.dma(BASE, write=True, mask=0xffff, data=0x8877665544332211)
    assert t.result[:2] == (WRITEACK, 0)
    assert any(x[1:] == ('dma-flag', 0, 0, BASE, 1) for x in e.events)
    assert BASE not in e.copies
    assert (await e.read(BASE)).result[2] == e.golden(BASE)
    await e.finish()


@cocotb.test()
async def dma_read_unique_down_returns_dirty_data_without_dma_bit(d):
    e = await env(d)
    await e.acquire(BASE, write=True)
    e.store(BASE, 56, 8, 0x123456789abcdef0)
    t = await e.dma(BASE)
    assert t.result == (READDATA, 0, e.golden(BASE))
    assert e.copies[BASE][0] == 'S'
    assert any(x[1:] == ('dma-flag', 1, 1, BASE, 0) for x in e.events)
    await e.finish()


@cocotb.test()
async def dma_maskwrite_read_error_returns_writeack_without_install(d):
    e = await env(d)
    e.errors.add(BASE)
    old = e.golden(BASE)
    t = await e.dma(BASE, write=True, mask=(1 << 64) - 1, data=0, error=True)
    assert t.result[:2] == (WRITEACK, 1) and e.golden(BASE) == old
    e.errors.remove(BASE)
    before = len(e.reads)
    assert (await e.dma(BASE)).result == (READDATA, 0, old)
    assert len(e.reads) == before + 1
    await e.finish()


async def random_dma(d, seed):
    e = await env(d, seed)
    e.backpressure = e.dma_enabled = True
    e.probe_delay = 3
    rng = random.Random(seed)
    lines = [BASE + i for i in range(16)]
    e.i_script.extend(rng.choice(lines) for _ in range(500))
    for i in range(2000):
        write = i % 2
        mask = rng.getrandbits(64) if i % 31 else (0 if i % 62 else (1 << 64) - 1)
        e.dma_script.append((MASKWRITE if write else READ, rng.choice(lines), mask, rng.getrandbits(512)))
    def cpu_transactions():
        return sum(x[1] == 'req' and x[2] == 0 or x[1] == 'up' and x[2] == 0 for x in e.events)
    while cpu_transactions() < 2000:
        line = rng.choice(lines)
        if rng.randrange(5) < 4:
            write = bool(rng.randrange(2))
            await e.acquire(line, write=write)
            await e.until(lambda: not e.line_busy(line))
            if write:
                while e.copies.get(line, ('I', 0))[0] not in ('E', 'M'):
                    await e.acquire(line, write=True)
                    await e.until(lambda: not e.line_busy(line))
                size = 1 << rng.randrange(4)
                e.store(line, rng.randrange(64 // size) * size, size, rng.getrandbits(8 * size))
        else:
            await e.until(lambda: not e.line_busy(line))
            if line in e.copies:
                e.evict(line)
                await e.until(lambda: not e.puts)
        await e.tick()
    await e.until(e.idle, limit=200000)
    assert e.dma_done == 2000 and e.i_done == 500 and cpu_transactions() >= 2000
    assert sum(x[1] == 'req' and x[2] == 2 and x[3] == READ for x in e.events) == 1000
    assert sum(x[1] == 'req' and x[2] == 2 and x[3] == MASKWRITE for x in e.events) == 1000
    await e.finish()
    d._log.info('N1 seed=%d DMA=2000 CPU_Get_Put=%d I_Read=500 cycles=%d', seed, cpu_transactions(), e.cycle)


@cocotb.test()
async def random_dma_seed_51(d):
    await random_dma(d, 51)


@cocotb.test()
async def random_dma_seed_52(d):
    await random_dma(d, 52)
