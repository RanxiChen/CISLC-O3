"""N3 independent atomic/DMA byte oracle, real L1D/L2 and AXI RAM."""
import random
import cocotb
from system_agents import SystemBench, Cpu, BASE
from mem_agents import req, response, READ, MASKWRITE, READDATA, WRITEACK
from test_l8b_dcache import atomic, LR, SC, SWAP, ADD, XOR, AND, OR, MIN, MAX, MINU, MAXU, MASK64


class AtomicDmaBench(SystemBench):
    def __init__(self, d, seed):
        super().__init__(d, seed)
        self.dma_rng = random.Random(seed ^ 0xABC)
        self.dma_pending = None
        self.dma_inflight = None
        self.dma_result = None
        self.dma_hold = None
        self.dma_done = self.amo_done = self.lr_done = self.sc_done = 0
        self.a_writes = []

    def drive_extra(self):
        d = self.d
        d.dma_req_valid_i.value = self.dma_pending is not None
        d.dma_req_i.value = req(*self.dma_pending) if self.dma_pending else 0
        d.dma_resp_ready_i.value = self.dma_rng.randrange(4) != 0
        active = self.dma_pending or self.dma_inflight
        if active and active[0] == MASKWRITE and self.ipresent and self.ipresent[1] == active[1]:
            d.l1i_req_valid_i.value = 0

    def sample_extra(self):
        d = self.d
        if int(d.pte_a_write_o.value):
            self.a_writes.append((self.cycle, int(d.pte_a_line_o.value)))
        if self.dma_pending and int(d.dma_req_ready_o.value):
            self.check(self.dma_inflight is None, 'DMA credit')
            self.dma_inflight = self.dma_pending
            self.dma_pending = None
        valid = int(d.dma_resp_valid_o.value)
        bits = int(d.dma_resp_o.value)
        if self.dma_hold is not None:
            self.check(valid and bits == self.dma_hold, 'DMA response changed under backpressure')
        self.dma_hold = bits if valid and not int(d.dma_resp_ready_i.value) else None
        if valid and int(d.dma_resp_ready_i.value):
            self.check(self.dma_inflight is not None, 'DMA response without credit')
            op, line, tid, mask, data = self.dma_inflight
            rop, rid, error, actual = response(bits)
            self.check(rid == tid and not error and rop == (READDATA if op == READ else WRITEACK), 'DMA response shape')
            if op == READ:
                self.check(actual == self.golden_line(line), 'DMA Read golden bytes')
            else:
                original = self.golden_line(line)
                for byte in range(64):
                    if mask >> byte & 1:
                        original = (original & ~(255 << (8 * byte))) | (data & (255 << (8 * byte)))
                self.gold[line] = original
                self.history.setdefault(line, []).append((self.cycle, original))
            self.dma_result = (rop, actual)
            self.dma_inflight = None
            self.dma_done += 1

    async def dma(self, op, line, mask=0, data=0):
        self.check(self.dma_pending is self.dma_inflight is None, 'DMA one at a time')
        # Serialize this line with explicit CPU writes; I reads keep running and
        # check their independent history across Down/Inv and DMA WriteAck.
        if op == MASKWRITE:
            await self.until(lambda: all(t[0] != line for t in self.iout.values()) and
                             (self.ipresent is None or self.ipresent[1] != line), 5000)
        self.dma_result = None
        self.dma_pending = (op, line, 0, mask, data)
        await self.until(lambda: self.dma_result is not None, 5000)
        return self.dma_result


async def traffic(d, seed):
    e = AtomicDmaBench(d, seed)
    await e.reset()
    count = max(32, e.sets * e.ways * 2)
    lines = [BASE + 64 * k for k in range(count)]
    aliases = [BASE + 64 * e.l2sets * k for k in range(16)]
    def addr():
        return e.rng.choice(aliases if e.rng.randrange(4) == 0 else lines) + 8 * e.rng.randrange(8)
    completed = next_i = 0
    while completed < 2000:
        while next_i < 500 and next_i * 4 <= completed:
            e.i_script.append(e.rng.choice(lines + aliases) >> 6)
            next_i += 1
        a = addr()
        choice = e.rng.randrange(10)
        if choice < 4:
            await e.loads([Cpu(a, ident=1, lane=0, rob=1)])
        elif choice == 4:
            await e.sta(Cpu(a, sta=True, ident=3, lane=e.rng.randrange(2)))
        elif choice == 5:
            await e.store(a, e.rng.getrandbits(64), e.rng.choice([255,15,240,3,192]))
        elif choice < 8:
            op = e.rng.choice([SWAP, ADD, XOR, AND, OR, MIN, MAX, MINU, MAXU])
            old = e.golden(a)
            r = await atomic(e, a, op, e.rng.getrandbits(64), size=e.rng.choice([2,3]))
            assert r['status'] == 0
            e.history.setdefault(a >> 6, []).append((e.cycle - 1, e.golden_line(a >> 6)))
            e.amo_done += 1
        elif choice == 8:
            assert (await atomic(e, a, LR))['status'] == 0
            e.lr_done += 1
        else:
            r = await atomic(e, a, SC, e.rng.getrandbits(64))
            assert r['status'] == 0
            e.history.setdefault(a >> 6, []).append((e.cycle - 1, e.golden_line(a >> 6)))
            e.sc_done += 1
        completed += 1
        # Every CPU operation has a DMA read or byte-masked write; cold/hot
        # line selection is independent. Real DMA probes run against L1D.
        dma_addr = addr() & ~63
        if completed & 1:
            await e.dma(READ, dma_addr >> 6)
        else:
            await e.dma(MASKWRITE, dma_addr >> 6, e.dma_rng.getrandbits(64), e.dma_rng.getrandbits(512))
    assert completed == 2000 and next_i == 500 and e.dma_done == 2000
    assert all(n > 0 for n in (e.amo_done, e.lr_done, e.sc_done))
    # Explicit LR -> DMA Inv -> failed SC, plus successful LR/SC pair.
    a = lines[0]
    assert (await atomic(e, a, LR))['status'] == 0
    await e.dma(MASKWRITE, a >> 6, 255, 0x1122334455667788)
    assert (await atomic(e, a, SC, 0xAA))['sc_fail']
    assert (await atomic(e, a, LR))['status'] == 0
    assert not (await atomic(e, a, SC, 0xBB))['sc_fail']
    e.history.setdefault(a >> 6, []).append((e.cycle - 1, e.golden_line(a >> 6)))
    await e.finish()
    assert e.i_done == 500
    d._log.info('N3 seed=%d CPU=%d DMA_random=2000 DMA_total=%d I=%d AMO=%d LR=%d SC=%d cycles=%d', seed, completed, e.dma_done, e.i_done, e.amo_done, e.lr_done, e.sc_done, e.cycle)


@cocotb.test()
async def atomic_dma_seed_71(d):
    await traffic(d, 71)


@cocotb.test()
async def atomic_dma_seed_72(d):
    await traffic(d, 72)
