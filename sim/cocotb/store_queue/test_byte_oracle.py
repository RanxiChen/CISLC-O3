"""Byte-address oracle for both SQ query ports, including XLEN wrap.

This deliberately computes byte sets, not the RTL displacement/shift formula.
It retains the existing single-store forwarding and partial-overlap blocking.
"""
import os
import random

import cocotb
from cocotb.triggers import Timer

MASK64 = (1 << 64) - 1


def oracle(stores, addr, mask):
    requested = {(addr + n) & MASK64 for n in range(8) if mask >> n & 1}
    forward, blocked, data = 0, 0, 0
    for sa, sm, sd in stores:
        available = {(sa + n) & MASK64 for n in range(8) if sm >> n & 1}
        if requested & available:
            if requested <= available:
                forward, blocked = 1, 0
                # Match the retained 32-bit unsigned shift expression,
                # including negative displacements and the 64-bit wrap.
                shift = (8 * ((addr - sa) & 0xffffffff)) & 0xffffffff
                data = sd >> shift if shift < 64 else 0
            else:
                forward, blocked = 0, 1
    return blocked, forward if not blocked else 0, data


@cocotb.test()
async def dual_query_unaligned_mask_and_address_wrap(d):
    rng = random.Random(int(os.getenv("TEST_SEED", "1")))
    names = "clk rst flush_all_i kind_i heu_done_i heu_done_idx_i rob_head_i alloc_valid alloc_rob execute_valid execute_idx execute_addr execute_data execute_mask query_valid query_rob query_addr query_mask commit_valid commit_idx dc_req_ready dc_resp_valid dc_resp_idx local_drain_ready multi_mode_i multi_alloc_count_i multi_commit_count_i resolution_valid_i resolution_mispredict_i resolution_tag_i restore_tail_i execute1_valid execute1_idx execute1_addr execute1_data execute1_mask query1_valid query1_rob query1_addr query1_mask dc_retry dc_reason dc_wake_i".split()

    async def tick():
        d.clk.value = 0
        await Timer(5, unit="ns")
        d.clk.value = 1
        await Timer(5, unit="ns")
        d.clk.value = 0

    for base in (0x80000100, 0x800001f8, 0, MASK64 - 7):
        for name in names:
            getattr(d, name).value = 0
        for name in ("multi_rob_i", "multi_mask_i", "multi_commit_idx_i"):
            for lane in getattr(d, name):
                lane.value = 0
        d.rst.value = 1
        await tick()
        d.rst.value = 0
        stores = []
        depth = int(d.cfg_depth_o.value)
        for n in range(depth):
            d.alloc_valid.value = 1
            d.alloc_rob.value = n + 1
            await Timer(1, unit="ns")
            idx = int(d.alloc_idx.value)
            await tick()
            d.alloc_valid.value = 0
            addr, mask, data = (base + rng.randrange(-7, 16)) & MASK64, rng.randrange(256), rng.getrandbits(64)
            d.execute_valid.value = 1
            d.execute_idx.value = idx
            d.execute_addr.value = addr
            d.execute_mask.value = mask
            d.execute_data.value = data
            await tick()
            d.execute_valid.value = 0
            stores.append((addr, mask, data))
        for n in range(512):
            cases = []
            for prefix in ("query", "query1"):
                addr = (base + rng.randrange(-14, 24)) & MASK64
                mask = (n & 255) if prefix == "query" else rng.randrange(256)
                getattr(d, prefix + "_valid").value = 1
                getattr(d, prefix + "_rob").value = 30
                getattr(d, prefix + "_addr").value = addr
                getattr(d, prefix + "_mask").value = mask
                cases.append((prefix, addr, mask))
            await Timer(1, unit="ns")
            for prefix, addr, mask in cases:
                got = tuple(int(getattr(d, prefix + suffix).value) for suffix in ("_block", "_forward_valid", "_forward_data"))
                assert got == oracle(stores, addr, mask), (base, n, prefix, addr, mask, got, oracle(stores, addr, mask))
