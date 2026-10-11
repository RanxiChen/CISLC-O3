"""Ordered FIFO oracle: full records, bank rotations, wrap, recovery and stalls."""
import os
import random
import cocotb
from test_payload import settle, tick


class FIFO:
    def __init__(self, d):
        self.d = d
        self.rng = random.Random(int(os.getenv("TEST_SEED", "1")))
        self.queue = []
        self.ew = len(d.enq_valid_i)
        self.bits = len(d.enq_payload_i) // self.ew
        self.dw = len(d.deq_payload_o) // self.bits
        self.depth = int(d.depth_o.value)
        self.ftq_depth = int(d.ftq_depth_o.value)
        self.slots = int(d.slots_o.value)
        self.idmask, self.slotmask = int(d.id_mask_o.value), int(d.slot_mask_o.value)
        self.ids = (self.idmask & -self.idmask).bit_length() - 1
        self.ss = (self.slotmask & -self.slotmask).bit_length() - 1
        self.idx_bits = (self.ftq_depth - 1).bit_length()
        self.idx_mask = self.ftq_depth - 1
        self.gen_mask = (1 << (len(d.kill_id_i) - self.idx_bits)) - 1
        self.generations = [0] * self.ftq_depth
        self.accepted = self.delivered = self.simultaneous = self.generation_wraps = 0
        self.cycle = 0

    def identity(self, word):
        return (word & self.idmask) >> self.ids

    def slot(self, word):
        return (word & self.slotmask) >> self.ss

    def boundary(self, position, self_kill=False):
        word = self.queue[position]
        return dict(id=self.identity(word), slot=self.slot(word), self=self_kill)

    async def step(self, count=0, take=False, kill=None, flush=False):
        d = self.d
        idx = ((self.identity(self.queue[-1]) + 1) & self.idx_mask) if self.queue else 0
        generation = (self.generations[idx] + 1) & self.gen_mask
        ident = (generation << self.idx_bits) | idx
        head = self.identity(self.queue[0]) if self.queue else idx
        words = []
        for lane in range(self.ew):
            word = self.rng.getrandbits(self.bits)
            word = (word & ~(self.idmask | self.slotmask)) | (ident << self.ids) | (lane << self.ss)
            words.append(word)
        vals = dict(clk_i=0, flush_i=flush, enq_valid_i=(1 << count)-1,
                    enq_payload_i=sum(w << (i*self.bits) for i, w in enumerate(words)),
                    deq_ready_i=take, kill_valid_i=kill is not None,
                    kill_all_i=(kill or {}).get('all', False),
                    kill_self_i=(kill or {}).get('self', False),
                    kill_id_i=(kill or {}).get('id', 0),
                    kill_slot_i=(kill or {}).get('slot', 0), head_id_i=head)
        for name, value in vals.items():
            getattr(d, name).value = int(value)
        await settle()
        ready = not (flush or kill is not None) and self.depth-len(self.queue) >= self.ew
        valid = bool(self.queue) and not (flush or kill is not None)
        visible = self.queue[:self.dw] + [0]*max(0, self.dw-len(self.queue))
        assert int(d.deq_payload_o.value) == sum(w << (i*self.bits) for i, w in enumerate(visible)), self.cycle
        assert bool(d.enq_ready_o.value) == ready, self.cycle
        assert bool(d.deq_valid_o.value) == valid, self.cycle
        if flush:
            self.queue = []
        elif kill is not None:
            def age(ident, slot):
                return ((ident & self.idx_mask)-(head & self.idx_mask)) % self.ftq_depth*self.slots+slot
            boundary = age(kill.get('id', 0), kill.get('slot', 0))
            survivors = [w for w in self.queue if not (kill.get('all', False) or
                         age(self.identity(w), self.slot(w)) > boundary or
                         (kill.get('self', False) and self.identity(w) == kill['id'] and self.slot(w) == kill['slot']))]
            assert survivors == self.queue[:len(survivors)], 'stimulus must retain a program-order prefix'
            self.queue = survivors
        else:
            popped = min(self.dw, len(self.queue)) if take and valid else 0
            self.queue = self.queue[popped:]
            self.delivered += popped
            if ready and count:
                self.generation_wraps += int(generation == 0)
                self.generations[idx] = generation
                self.queue += words[:count]
                self.accepted += count
                self.simultaneous += int(popped != 0)
        await tick(d)
        self.cycle += 1
        return ready


@cocotb.test()
async def full_records_banked_wrap_prefix_kill_and_backpressure(d):
    for name in ('clk_i', 'rst_i', 'flush_i', 'enq_payload_i', 'enq_valid_i',
                 'deq_ready_i', 'kill_valid_i', 'kill_all_i', 'kill_self_i',
                 'kill_id_i', 'head_id_i', 'kill_slot_i'):
        getattr(d, name).value = 0
    d.rst_i.value = 1
    await tick(d)
    d.rst_i.value = 0
    await settle()
    b = FIFO(d)
    assert b.ew == 8 and b.dw == 4 and b.depth == 32
    for _ in range(4):
        assert await b.step(8)
    assert not await b.step(8)
    assert not await b.step(8, take=True)  # No combinational dequeue credit.
    await b.step(kill=b.boundary(10, True))
    await b.step(7, take=True)
    await b.step(flush=True)
    # Force generation wrap and repeated physical-slot overwrite explicitly.
    for _ in range(b.gen_mask+2):
        await b.step(1)
        await b.step(kill=dict(all=True))
    for cycle in range(1800):
        kill = None
        if b.queue and b.rng.randrange(8) == 0:
            kill = b.boundary(b.rng.randrange(len(b.queue)), bool(b.rng.getrandbits(1)))
            kill['all'] = b.rng.randrange(7) == 0
        await b.step(b.rng.randrange(9), b.rng.random() < .55, kill, cycle % 97 == 0)
    while b.queue:
        await b.step(take=True)
    await b.step()
    assert b.accepted > 4*b.depth and b.delivered > 4*b.depth
    assert b.simultaneous > 20 and b.generation_wraps > 0
