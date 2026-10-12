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


@cocotb.test()
async def client_payload_fifo_reuse_with_response_backpressure(dut):
    """Full line/identity scoreboard uses link handshakes across repeated FIFO wrap."""
    e = await env(dut, seed=105)
    rng = random.Random(105)
    for batch in range(40):
        e.response_ready[1] = 0
        transactions = []
        for tid in range(4):
            await e.until(lambda: e.present[1] is None)
            line = BASE + rng.randrange(e.sets * e.ways)
            t = e.submit(1, READ, line, tid=tid)
            transactions.append(t)
            await e.until(lambda: t.accepted)
        await e.until(lambda: int(dut.l1i_resp_valid_o.value))
        held = int(dut.l1i_resp_o.value)
        for _ in range(12 + rng.randrange(12)):
            await e.tick()
            assert int(dut.l1i_resp_valid_o.value), batch
            assert int(dut.l1i_resp_o.value) == held, batch
            assert all(t.result is None for t in transactions), batch
        e.response_ready[1] = 1
        await e.until(lambda: all(t.result is not None for t in transactions))
        for t in transactions:
            assert t.result == (READDATA, 0, e.golden(t.line)), (batch, t.line)
        # The one-entry DMA return path uses independent ownership and wrap.
        e.response_ready[2] = 0
        t = e.submit(2, READ, BASE + rng.randrange(e.sets * e.ways), tid=0)
        await e.until(lambda: int(dut.dma_resp_valid_o.value))
        held = int(dut.dma_resp_o.value)
        for _ in range(8):
            await e.tick()
            assert int(dut.dma_resp_valid_o.value) and int(dut.dma_resp_o.value) == held, batch
            assert t.result is None, batch
        e.response_ready[2] = 1
        await e.until(lambda: t.result is not None)
        assert t.result == (READDATA, 0, e.golden(t.line)), (batch, t.line)
    await e.finish()


@cocotb.test()
async def selected_slot_full_payload_reuse_with_three_clients(dut):
    # Full DMA request data, DDR refill and dirty-probe data share repeated
    # slot ownership. Exact 512-bit golden data is checked under backpressure.
    e=await env(dut,105);e.backpressure=True;e.probe_delay=3;rng=random.Random(105)
    for batch in range(64):
        line=BASE+(batch%8)*e.sets+(batch%e.sets)
        data=rng.getrandbits(512)
        await e.dma(line,write=True,mask=(1<<64)-1,data=data)
        r=await e.read(line);assert r.result[2]==data,batch
        await e.acquire(line,write=True)
        await e.until(lambda: not e.line_busy(line))
        for word in range(8):e.store(line,8*word,8,rng.getrandbits(64))
        expected=e.golden(line)
        r=await e.read(line);assert r.result[2]==expected,batch
        # A coherent DMA read after the I read also exercises the collected
        # owner path and retains all bytes through the selected replay task.
        r=await e.dma(line);assert r.result[2]==expected,batch
    await e.finish()


@cocotb.test()
async def synchronous_slot_reads_keep_owner_and_bytes_during_reuse(dut):
    # Stall DDR while different clients reserve the finite slow slots, then
    # drain with independent AXI/probe/response backpressure. Reuse the same
    # physical slots for new lines and for collected dirty-owner replay.
    e=await env(dut,305);e.backpressure=True;e.probe_delay=5
    rng=random.Random(305)
    for batch in range(48):
        a=BASE+(batch*3)*e.sets
        b=a+1
        c=a+e.sets
        e.block_r=True
        requests=[e.submit(0,GETS,a),e.submit(1,READ,b),e.submit(2,READ,c)]
        for _ in range(24):await e.tick()
        assert any(t.accepted for t in requests),(batch,'slot ownership never accepted')
        assert not all(t.result is not None for t in requests),(batch,'DDR block ignored')
        e.block_r=False
        await e.until(lambda:all(t.result is not None for t in requests))
        for t in requests:
            assert t.result[1]==0 and t.result[2]==e.golden(t.line),(batch,t.line,'read owner/data')
        await e.acquire(a,write=True)
        await e.until(lambda:not e.line_busy(a))
        for word in range(8):e.store(a,word*8,8,rng.getrandbits(64))
        expected=e.golden(a)
        r=await e.dma(a)
        assert r.result[2]==expected,(batch,'captured dirty-probe payload')
        await e.until(e.idle)
    await e.finish()


@cocotb.test()
async def plru_directory_way_selection_survives_wraps_and_reset(dut):
    # Independent tree-policy oracle checks the publicly observed installed
    # line at each physical way. I-only reads avoid sharer/probe mutations.
    e=await env(dut,405);e.backpressure=True;rng=random.Random(405)
    ways=e.ways;sets=e.sets;levels=ways.bit_length()-1
    assert ways==1<<levels
    rows=[[None]*ways for _ in range(sets)];trees=[[0]*(ways-1) for _ in range(sets)]
    for cycle in range(384):
        if cycle==192:
            e=await env(dut,405);e.backpressure=True
            rows=[[None]*ways for _ in range(sets)];trees=[[0]*(ways-1) for _ in range(sets)]
        set_idx=cycle%sets
        line=BASE+(rng.randrange(ways+5))*sets+set_idx
        if line in rows[set_idx]:chosen=rows[set_idx].index(line)
        elif None in rows[set_idx]:chosen=rows[set_idx].index(None)
        else:
            node=chosen=0
            for _ in range(levels):
                direction=trees[set_idx][node];chosen=2*chosen+direction;node=2*node+1+direction
        rows[set_idx][chosen]=line
        node=0
        for level in range(levels):
            direction=(chosen>>(levels-level-1))&1
            trees[set_idx][node]=1-direction;node=2*node+1+direction
        r=await e.read(line)
        assert r.result[1]==0 and r.result[2]==e.golden(line),(cycle,'PLRU read payload')
        await e.until(e.idle)
        valid=int(dut.mon_valid.value);addresses=int(dut.mon_addr.value)
        for set_number,row in enumerate(rows):
            for way_number,expected in enumerate(row):
                index=set_number*ways+way_number
                assert bool(valid&(1<<index))==(expected is not None),(cycle,set_number,way_number,'valid owner')
                if expected is not None:
                    actual=(addresses>>(26*index))&((1<<26)-1)
                    assert actual==expected,(cycle,set_number,way_number,actual,expected,'PLRU replacement')
    await e.finish()
