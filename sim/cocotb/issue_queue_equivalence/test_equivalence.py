"""Cycle-by-cycle public-output comparison with immutable pre-change RTL."""
import os
import random
import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def random_full_payload_dependencies_recovery(d):
    rng = random.Random(int(os.getenv("TEST_SEED", "1")))
    inputs = ["enq_uop_i", "enq_fire_i", "preg_ready_i", "fp_preg_ready_i",
              "wakeup_valid_i", "wakeup_preg_i", "fp_wakeup_valid_i",
              "fp_wakeup_preg_i", "fp_regread_ready_i", "mul_ready_i",
              "mul_pair_ready_i", "div_ready_i", "issue_ready_i",
              "resolution_valid_i", "resolution_mispredict_i", "resolution_tag_i"]
    for name in ["clk", "rst"] + inputs:
        getattr(d, name).value = 0
    async def tick():
        d.clk.value = 1
        await Timer(2, unit="ns")
        d.clk.value = 0
        await Timer(2, unit="ns")
    d.rst.value = 1
    await tick()
    d.rst.value = 0
    await Timer(2, unit="ns")
    bits = len(d.valid_mask_o)
    ew = len(d.enq_uop_i) // bits
    valid_mask = int(d.valid_mask_o.value)
    for cycle in range(2400):
        free = int(d.free_o.value)
        n = rng.randrange(min(free, ew) + 1)
        active = set(rng.sample(range(ew), n))
        for name in inputs:
            if name not in ("enq_uop_i", "enq_fire_i"):
                signal = getattr(d, name)
                signal.value = rng.getrandbits(len(signal))
        # Frequent drain phases exercise slot reuse and long queue orders.
        if cycle % 100 >= 75:
            d.preg_ready_i.value = (1 << len(d.preg_ready_i)) - 1
            d.fp_preg_ready_i.value = (1 << len(d.fp_preg_ready_i)) - 1
            d.fp_regread_ready_i.value = 31
            d.issue_ready_i.value = (1 << len(d.issue_ready_i)) - 1
            d.resolution_valid_i.value = 0
        else:
            d.resolution_valid_i.value = cycle % 9 == 0
        d.enq_fire_i.value = bool(n) and cycle % 100 < 75
        payload = [((rng.getrandbits(bits) & ~valid_mask) |
                    (valid_mask if lane in active else 0)) for lane in range(ew)]
        d.enq_uop_i.value = sum(p << (i * bits) for i, p in enumerate(payload))
        await Timer(2, unit="ns")
        assert int(d.match_o.value), f"cycle {cycle}: candidate differs from baseline"
        await tick()
