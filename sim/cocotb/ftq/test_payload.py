"""Random full FTQ payloads; all public outputs checked by the RTL miter."""
import os
import random
import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def allocation_slow_metadata_reuse_and_same_edge_updates(d):
    rng = random.Random(int(os.getenv("TEST_SEED", "1")))
    inputs = ("alloc_valid_i", "alloc_pred_i", "alloc_ras_i", "slow_i", "resolve_i",
              "winner_i", "kill_i", "commit_i", "read_id_i", "demand_ready_i", "pf_ready_i")
    for name in ("clk_i", "rst_i") + inputs:
        getattr(d, name).value = 0
    async def tick():
        d.clk_i.value = 1
        await Timer(2, unit="ns")
        d.clk_i.value = 0
        await Timer(2, unit="ns")
    d.rst_i.value = 1
    await tick()
    d.rst_i.value = 0
    await Timer(2, unit="ns")
    formats = {}
    for name in ("slow", "resolve", "commit"):
        mask = int(getattr(d, name + "_id_mask_o").value)
        shift = (mask & -mask).bit_length() - 1
        valid = int(getattr(d, name + "_valid_mask_o").value)
        formats[name] = mask, shift, valid
    identities = [0]
    for cycle in range(3000):
        d.rst_i.value = cycle % 211 == 210
        ident = rng.choice(identities)
        for name in inputs:
            signal = getattr(d, name)
            signal.value = rng.getrandbits(len(signal))
        # Use both current and stale generations for slow/resolve/commit.
        for name, (mask, shift, valid) in formats.items():
            signal = getattr(d, name + "_i")
            payload = rng.getrandbits(len(signal))
            payload = (payload & ~mask) | (ident << shift)
            if rng.randrange(4) == 0:
                payload &= ~valid
            else:
                payload |= valid
            signal.value = payload
        d.read_id_i.value = ident
        # Most cycles keep the allocation pipeline live; randomized redirects
        # and resets exercise metadata invisibility and slot generation reuse.
        d.kill_i.value = rng.getrandbits(len(d.kill_i)) if cycle % 13 == 0 else 0
        d.winner_i.value = rng.getrandbits(len(d.winner_i)) if cycle % 7 == 0 else 0
        d.alloc_valid_i.value = cycle % 3 != 2
        await Timer(2, unit="ns")
        if int(d.alloc_ready_o.value) and int(d.alloc_valid_i.value) and not int(d.rst_i.value):
            identities.append(int(d.alloc_id_o.value))
            identities = identities[-64:]
        await tick()
