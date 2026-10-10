"""Full-width transaction-list oracle for stationary payload and index recovery."""
import os
import random

import cocotb
from ports import INPUTS
from l3_contract import reset, val, codec, field, bundle, unbundle, settle, tick


@cocotb.test()
async def full_payload_arbitrary_kill_holes_and_slot_reuse(d):
    rng = random.Random(int(os.getenv("TEST_SEED", "1")))
    await reset(d, INPUTS)
    width, depth = val(d.cfg_width_o), val(d.cfg_depth_o)
    bits = len(d.enq_uop_i) // width
    valid = codec(d, "renamed_uop_t", valid=1)
    queue = []
    for cycle in range(1200):
        resolution = cycle % 3 == 0
        mispredict = resolution and cycle % 9 == 0
        tag = rng.randrange(val(d.cfg_tags_o))
        n = min(width, depth - len(queue), rng.randrange(width + 1))
        take = min(width, len(queue), rng.randrange(width + 1))
        incoming = [rng.getrandbits(bits) | valid for _ in range(n)]
        bundle(d.enq_uop_i, incoming + [0] * (width - n))
        d.enq_count_i.value = n
        d.enq_fire_i.value = bool(n)
        d.deq_accept_count_i.value = take
        d.resolution_valid_i.value = resolution
        d.resolution_mispredict_i.value = mispredict
        d.resolution_tag_i.value = tag
        await settle()
        visible = min(width, len(queue))
        assert val(d.free_count_o) == depth - len(queue)
        assert val(d.deq_count_o) == visible
        assert unbundle(d.deq_uop_o, width) == queue[:visible] + [0] * (width - visible)
        if mispredict:
            queue = [x for x in queue if not (field(d, "renamed_uop_t", x, "branch_mask") >> tag & 1)]
        else:
            queue = queue[take:] + incoming
        if resolution:
            clear_mask = codec(d, "renamed_uop_t", branch_mask=1 << tag)
            queue = [x & ~clear_mask for x in queue]
        await tick(d)
