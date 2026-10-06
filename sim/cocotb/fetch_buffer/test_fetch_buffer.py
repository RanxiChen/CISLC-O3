"""Transaction-list oracle for D24 selective retention and FIFO handshakes."""
import random
import cocotb
from cocotb.triggers import Timer


def pack(values, width):
    return sum(x << (n * width) for n, x in enumerate(values))


def lane(sig, n, width):
    return (int(sig.value) >> (n * width)) & ((1 << width) - 1)


class Bench:
    def __init__(self, dut):
        self.d = dut
        self.queue = []
        self.n = len(dut.enq_valid_i)
        self.m = len(dut.deq_mask_o)
        self.idw = len(dut.enq_id_i) // self.n
        self.slotw = len(dut.enq_slot_i) // self.n
        self.pcw = len(dut.enq_pc_i) // self.n
        self.depth = int(dut.depth_o.value)
        self.ftq_depth = int(dut.ftq_depth_o.value)
        self.cycle = 0

    async def step(self, entries=(), *, deq=False, rst=False, flush=False,
                   kill=False, all_=False, self_=False, boundary=(0, 0), head=0):
        d = self.d
        assert len(entries) <= self.n
        lanes = list(entries) + [None] * (self.n - len(entries))
        d.clk_i.value = 0
        d.rst_i.value = rst
        d.flush_i.value = flush
        d.enq_valid_i.value = sum((e is not None) << i for i, e in enumerate(lanes))
        for sig, index, width in ((d.enq_id_i, 0, self.idw),
                                  (d.enq_slot_i, 1, self.slotw),
                                  (d.enq_pc_i, 2, self.pcw)):
            sig.value = pack([e[index] if e else 0 for e in lanes], width)
        d.deq_ready_i.value = deq
        d.kill_valid_i.value = kill
        d.kill_all_i.value = all_
        d.kill_self_i.value = self_
        d.kill_id_i.value, d.kill_slot_i.value = boundary
        d.head_i.value = head
        await Timer(1, unit='ns')
        blocked = rst or flush or kill
        ready = not blocked and self.depth - len(self.queue) >= self.n
        valid = not blocked and bool(self.queue)
        assert int(d.enq_ready_o.value) == ready, self.cycle
        assert int(d.deq_valid_o.value) == valid, self.cycle
        if valid:
            for i in range(self.m):
                assert lane(d.deq_mask_o, i, 1) == (i < len(self.queue)), self.cycle
                if i < len(self.queue):
                    rid, slot, pc = self.queue[i]
                    assert (lane(d.deq_id_o, i, self.idw), lane(d.deq_slot_o, i, self.slotw),
                            lane(d.deq_pc_o, i, self.pcw)) == (rid, slot, pc), self.cycle
                    assert lane(d.deq_next_o, i, self.pcw) == pc + 4
                    assert lane(d.deq_inst_o, i, 32) == pc
                    assert lane(d.deq_last_o, i, 1) == (slot == 6)
                    assert lane(d.deq_taken_o, i, 1) == (slot == 2)
        if rst or flush:
            self.queue = []
        elif kill:
            mask = self.ftq_depth - 1
            def age(rid, slot):
                return (((rid & mask) - (head & mask)) % self.ftq_depth, slot)
            self.queue = [e for e in self.queue if not (all_
                or age(e[0], e[1]) > age(*boundary)
                or (self_ and e[:2] == boundary))]
        else:
            if valid and deq:
                self.queue = self.queue[self.m:]
            if ready:
                self.queue.extend(e for e in lanes if e is not None)
        d.clk_i.value = 1
        await Timer(1, unit='ns')
        d.clk_i.value = 0
        self.cycle += 1

    async def drain(self):
        while self.queue:
            await self.step(deq=True)
        await self.step(deq=True)


@cocotb.test()
async def selective_boundaries(dut):
    dut.clk_i.value = 0
    await Timer(1, unit='ns')
    b = Bench(dut)
    depth = b.ftq_depth
    for head, older, middle, younger in ((0, 2, 3, 4), (depth-2, depth-1, 0, 1)):
        # Nonzero generation distinguishes dynamic identity while age follows idx.
        older |= depth * 7
        middle |= depth * 8
        younger |= depth * 9
        for self_ in (False, True):
            for slot in (0, 2, 6):
                await b.step(rst=True)
                for rid in (older, middle, younger):
                    await b.step([(rid, s, 0x1000 + b.cycle*16 + s*2) for s in (0, 2, 4, 6)])
                await b.step([(younger, 6, 0x9990)], deq=True, kill=True,
                             self_=self_, boundary=(middle, slot), head=head)
                assert len(b.queue) == 4 + slot//2 + (not self_)
                await b.drain()
    await b.step([(0, 0, 0x1000)])
    await b.step(kill=True, all_=True, deq=True)
    await b.drain()
    await b.step([(1, 0, 0x2000)])
    await b.step(flush=True)
    await b.drain()


@cocotb.test()
async def fifo_wrap_backpressure_and_retention(dut):
    dut.clk_i.value = 0
    await Timer(1, unit='ns')
    b = Bench(dut)
    await b.step(rst=True)
    rng = random.Random(105)
    # Repeated full fills, dequeues, refill and partial kills move both ring
    # pointers past DEPTH and exercise survivor compaction over the ring end.
    for round_ in range(10):
        while b.depth - len(b.queue) >= b.n:
            await b.step([(i//4, (i%4)*2, 0x4000 + b.cycle*16 + i*4)
                          for i in range(b.n)])
        await b.step([(6, 0, 0x8000)], deq=False)  # full backpressure
        for _ in range(3):
            await b.step(deq=True)
        await b.step([(7, 0, 0x8100), None, (7, 2, 0x8108)], deq=True)
        await b.step(kill=True, boundary=(7, 0), self_=bool(round_%2))
        await b.drain()
    for _ in range(150):
        entries = [(rng.randrange(b.ftq_depth), rng.randrange(4)*2,
                    0x10000 + b.cycle*16+i*4) if rng.random() < .7 else None
                   for i in range(b.n)]
        await b.step(entries, deq=rng.random() < .6, kill=rng.random() < .15,
                     all_=rng.random() < .1, self_=rng.random() < .5,
                     boundary=(rng.randrange(b.ftq_depth), rng.randrange(8)),
                     head=rng.randrange(b.ftq_depth))
    await b.drain()
