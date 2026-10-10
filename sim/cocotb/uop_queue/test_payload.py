"""Independent full-packed-payload FIFO oracle; no physical-bank observations."""
import os
import random

import cocotb
from ports import INPUTS
from l3_contract import reset, val, codec, bundle, unbundle, settle, tick


@cocotb.test()
async def full_payload_wrap_backpressure_flush(d):
    rng = random.Random(int(os.getenv("TEST_SEED", "1")))
    await reset(d, INPUTS)
    width, depth = val(d.cfg_width_o), val(d.cfg_depth_o)
    bits = len(d.enq_uop_i) // width
    valid_mask = codec(d, "decoded_uop_t", valid=1)
    queue = []
    for cycle in range(1200):
        n = rng.randrange(width + 1)
        take = rng.randrange(min(width, len(queue)) + 1)
        flush = cycle % 79 == 0
        incoming = [(rng.getrandbits(bits) | valid_mask) for _ in range(n)]
        bundle(d.enq_uop_i, incoming + [0] * (width - n))
        d.enq_valid_i.value = bool(n)
        d.deq_accept_count_i.value = take
        d.flush_i.value = flush
        await settle()
        visible = min(width, len(queue))
        assert val(d.deq_count_o) == visible
        assert unbundle(d.deq_uop_o, width) == queue[:visible] + [0] * (width - visible)
        ready = depth - len(queue) >= n
        assert bool(val(d.enq_ready_o)) == ready
        queue = [] if flush else queue[take:] + (incoming if ready else [])
        await tick(d)
