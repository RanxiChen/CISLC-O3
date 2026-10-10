"""Full-record list oracle, including sparse lanes and arbitrary kill holes."""
import os
import random

import cocotb
from cocotb.triggers import Timer


async def settle():
    await Timer(2, unit="ns")


async def tick(d):
    d.clk_i.value = 1
    await settle()
    d.clk_i.value = 0
    await settle()


@cocotb.test()
async def all_fields_sparse_backpressure_recovery(d):
    rng = random.Random(int(os.getenv("TEST_SEED", "1")))
    for name in ("clk_i", "rst_i", "flush_i", "enq_payload_i", "enq_valid_i",
                 "deq_ready_i", "kill_valid_i", "kill_all_i", "kill_self_i",
                 "kill_id_i", "head_id_i", "kill_slot_i"):
        getattr(d, name).value = 0
    d.rst_i.value = 1
    await tick(d)
    d.rst_i.value = 0
    await settle()
    ew = len(d.enq_valid_i)
    bits = len(d.enq_payload_i) // ew
    dw = len(d.deq_payload_o) // bits
    depth, ftq_depth, slots = (int(getattr(d, n).value)
                              for n in ("depth_o", "ftq_depth_o", "slots_o"))
    idx_bits = (ftq_depth - 1).bit_length()
    idx_mask = (1 << idx_bits) - 1
    id_mask, slot_mask = int(d.id_mask_o.value), int(d.slot_mask_o.value)
    id_shift = (id_mask & -id_mask).bit_length() - 1
    slot_shift = (slot_mask & -slot_mask).bit_length() - 1
    id_bits = len(d.kill_id_i)
    def age(ident, slot, head):
        return ((ident & idx_mask) - (head & idx_mask)) % ftq_depth * slots + slot
    queue = []
    for cycle in range(1800):
        head = rng.getrandbits(id_bits)
        ident, slot = rng.getrandbits(id_bits), rng.randrange(slots)
        if queue and cycle % 3 == 0:
            payload = rng.choice(queue)
            ident = (payload & id_mask) >> id_shift
            slot = (payload & slot_mask) >> slot_shift
            if cycle % 6 == 0:
                ident ^= 1 << idx_bits  # Same index/slot, different generation.
        kill = rng.randrange(9) == 0
        kill_all = rng.randrange(5) == 0
        kill_self = bool(rng.getrandbits(1))
        flush = cycle % 97 == 0
        take = bool(rng.getrandbits(1))
        valid = rng.getrandbits(ew)
        incoming = []
        for lane in range(ew):
            p = rng.getrandbits(bits)
            p = (p & ~id_mask) | (rng.getrandbits(id_bits) << id_shift)
            p = (p & ~slot_mask) | (rng.randrange(slots) << slot_shift)
            incoming.append(p)
        d.head_id_i.value, d.kill_id_i.value = head, ident
        d.kill_slot_i.value = slot
        d.kill_valid_i.value, d.kill_all_i.value = kill, kill_all
        d.kill_self_i.value = kill_self
        d.flush_i.value, d.deq_ready_i.value = flush, take
        d.enq_valid_i.value = valid
        d.enq_payload_i.value = sum(p << (lane * bits) for lane, p in enumerate(incoming))
        await settle()
        ready = not (flush or kill) and depth - len(queue) >= ew
        visible = queue[:dw] + [0] * max(0, dw - len(queue))
        assert int(d.deq_payload_o.value) == sum(p << (i * bits) for i, p in enumerate(visible)), cycle
        assert bool(d.enq_ready_o.value) == ready, cycle
        assert bool(d.deq_valid_o.value) == (bool(queue) and not (flush or kill)), cycle
        if flush:
            queue = []
        elif kill:
            boundary = age(ident, slot, head)
            queue = [p for p in queue if not (kill_all or
                age((p & id_mask) >> id_shift, (p & slot_mask) >> slot_shift, head) > boundary or
                (kill_self and (p & id_mask) >> id_shift == ident and
                 (p & slot_mask) >> slot_shift == slot))]
        else:
            if take:
                queue = queue[dw:]
            if ready:
                queue += [p for lane, p in enumerate(incoming) if valid >> lane & 1]
        await tick(d)
