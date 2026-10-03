import os
import random

import cocotb
from cocotb.triggers import Timer

from dcache_model import empty_probe_response


@cocotb.test()
async def empty_line_recall_pipeline(dut):
    seed = int(os.environ.get("TEST_SEED", "1"))
    rng = random.Random(seed)
    dut.clk.value = 0
    dut.rst.value = 1
    dut.probe_valid.value = 0
    dut.probe_addr.value = 0
    dut.probe_id.value = 0
    dut.ld_valid.value = 0
    dut.ld_addr.value = 0
    dut.ld_idx.value = 0
    dut.st_valid.value = 0
    dut.st_addr.value = 0
    dut.st_data.value = 0
    dut.st_mask.value = 0
    dut.st_idx.value = 0
    dut.l2_req_ready.value = 0
    dut.l2_resp_valid.value = 0
    dut.l2_resp_data.value = 0
    dut.l2_resp_last.value = 0
    dut.l2_resp_error.value = 0
    dut.wb_ready.value = 0
    dut.wb_error.value = 0

    async def tick():
        dut.clk.value = 0
        await Timer(5, unit="ns")
        obs = (
            int(dut.probe_ready.value), int(dut.resp_valid.value),
            int(dut.resp_id.value), int(dut.resp_had_dirty.value),
            int(dut.resp_dirty_data.value),
        )
        dut.clk.value = 1
        await Timer(5, unit="ns")
        return obs

    assert (await tick())[1] == 0
    dut.rst.value = 0
    expected = []
    for cycle in range(24):
        valid = rng.randrange(3) != 0
        recall_id = rng.randrange(1 << len(dut.probe_id))
        dut.probe_valid.value = int(valid)
        dut.probe_addr.value = 0x80000000 + 64 * cycle
        dut.probe_id.value = recall_id
        ready, resp_valid, resp_id, had_dirty, dirty_data = await tick()
        assert ready == 1, f"seed={seed} cycle={cycle} probe blocked"
        if expected:
            assert resp_valid == 1
            assert (resp_id, had_dirty, dirty_data) == expected.pop(0)
        else:
            assert resp_valid == 0
        if valid:
            _, ident, dirty, data = empty_probe_response(1, recall_id)
            expected.append((ident, dirty, data))
    dut.probe_valid.value = 0
    _, resp_valid, resp_id, had_dirty, dirty_data = await tick()
    if expected:
        assert resp_valid == 1
        assert (resp_id, had_dirty, dirty_data) == expected.pop(0)
    assert not expected


@cocotb.test()
async def word_banks_refill_store_probe_and_hit_under_miss(dut):
    """A 64B line spans four 16B banks; dirty data reaches L2 recall."""
    d = dut
    d.clk.value = 0
    d.rst.value = 1
    for name in ("probe_valid", "probe_addr", "probe_id", "ld_valid", "ld_addr",
                 "ld_idx", "st_valid", "st_addr", "st_data", "st_mask",
                 "st_idx", "l2_req_ready", "l2_resp_valid", "l2_resp_data",
                 "l2_resp_last", "l2_resp_error", "wb_ready", "wb_error"):
        getattr(d, name).value = 0

    cycle = 0

    async def tick():
        nonlocal cycle
        d.clk.value = 0
        await Timer(5, unit="ns")
        obs = {name: int(getattr(d, name).value) for name in (
            "ld_ready", "ld_resp_valid", "ld_resp_data", "ld_resp_status",
            "st_ready", "st_resp_valid", "st_resp_idx", "l2_req_valid",
            "l2_req_addr", "l2_resp_ready", "wb_valid", "wb_addr", "wb_data",
            "probe_ready", "resp_valid", "resp_had_dirty", "resp_dirty_data")}
        d.clk.value = 1
        await Timer(5, unit="ns")
        cycle += 1
        return obs

    async def load(addr, ident):
        d.ld_addr.value = addr
        d.ld_idx.value = ident
        d.ld_valid.value = 1
        for _ in range(40):
            if (await tick())["ld_ready"]:
                d.ld_valid.value = 0
                return
        assert False, f"cycle={cycle}: load admission timeout {addr:#x}"

    async def store(addr, data, ident):
        d.st_addr.value = addr
        d.st_data.value = data
        d.st_mask.value = 0xFF
        d.st_idx.value = ident
        d.st_valid.value = 1
        for _ in range(40):
            if (await tick())["st_ready"]:
                d.st_valid.value = 0
                return
        assert False, f"cycle={cycle}: store admission timeout {addr:#x}"

    async def accept_l2(addr):
        for _ in range(40):
            obs = await tick()
            if obs["l2_req_valid"]:
                assert obs["l2_req_addr"] == addr, f"cycle={cycle}: {obs}"
                d.l2_req_ready.value = 1
                assert (await tick())["l2_req_valid"]
                d.l2_req_ready.value = 0
                return
        assert False, f"cycle={cycle}: L2 request timeout {addr:#x}"

    async def refill(data):
        assert len(data) == 64
        for beat in range(4):
            d.l2_resp_valid.value = 1
            d.l2_resp_data.value = int.from_bytes(data[beat*16:(beat+1)*16], "little")
            d.l2_resp_last.value = int(beat == 3)
            assert (await tick())["l2_resp_ready"] == 1
        d.l2_resp_valid.value = 0
        d.l2_resp_last.value = 0

    async def expect_load(expected):
        for _ in range(40):
            obs = await tick()
            if obs["ld_resp_valid"]:
                assert obs["ld_resp_status"] == 0, f"cycle={cycle}: {obs}"
                assert obs["ld_resp_data"] == expected, f"cycle={cycle}: {obs}"
                return
        assert False, f"cycle={cycle}: load response timeout"

    async def expect_store(ident):
        for _ in range(40):
            obs = await tick()
            if obs["st_resp_valid"]:
                assert obs["st_resp_idx"] == ident, f"cycle={cycle}: {obs}"
                return
        assert False, f"cycle={cycle}: store response timeout"

    await tick()
    await tick()
    d.rst.value = 0
    line0 = 0x80000100
    line1 = 0x80000140
    data0 = bytes(range(64))
    data1 = bytes((i * 3 + 7) & 0xFF for i in range(64))

    await load(line0 + 16, 1)
    await accept_l2(line0)
    await refill(data0)
    await expect_load(int.from_bytes(data0[16:24], "little"))

    await load(line1, 2)
    await accept_l2(line1)
    # L2 still owes line1. The resident line0 hit must pass it.
    await load(line0 + 32, 3)
    await expect_load(int.from_bytes(data0[32:40], "little"))
    await refill(data1)
    await expect_load(int.from_bytes(data1[:8], "little"))

    replacement = 0x8877665544332211
    await store(line0 + 15, replacement, 5)
    await expect_store(5)
    await load(line0 + 15, 4)
    await expect_load(replacement)
    d.probe_valid.value = 1
    d.probe_addr.value = line0
    d.probe_id.value = 1
    for _ in range(20):
        if (await tick())["probe_ready"]:
            d.probe_valid.value = 0
            break
    else:
        assert False, f"cycle={cycle}: probe admission timeout"
    obs = await tick()
    expected_line = bytearray(data0)
    expected_line[15:23] = replacement.to_bytes(8, "little")
    assert obs["resp_valid"] == 1 and obs["resp_had_dirty"] == 1, obs
    assert obs["resp_dirty_data"] == int.from_bytes(expected_line, "little"), obs
    await load(line0, 6)
    await accept_l2(line0)
    await refill(bytes(expected_line))
    await expect_load(int.from_bytes(expected_line[:8], "little"))


@cocotb.test()
async def dirty_capacity_victim_is_written_back_before_refill(dut):
    """Five same-set lines force the first dirty way to hand its full line to L2."""
    d = dut
    d.clk.value = 0
    d.rst.value = 1
    for name in ("probe_valid", "probe_addr", "probe_id", "ld_valid", "ld_addr",
                 "ld_idx", "st_valid", "st_addr", "st_data", "st_mask",
                 "st_idx", "l2_req_ready", "l2_resp_valid", "l2_resp_data",
                 "l2_resp_last", "l2_resp_error", "wb_ready", "wb_error"):
        getattr(d, name).value = 0

    async def tick():
        d.clk.value = 0
        await Timer(5, unit="ns")
        obs = {name: int(getattr(d, name).value) for name in (
            "ld_ready", "ld_resp_valid", "ld_resp_data", "st_ready",
            "st_resp_valid", "l2_req_valid", "l2_req_addr", "l2_resp_ready",
            "wb_valid", "wb_addr", "wb_data")}
        d.clk.value = 1
        await Timer(5, unit="ns")
        return obs

    async def send_req(store, addr):
        d.st_valid.value = int(store)
        d.ld_valid.value = int(not store)
        d.st_addr.value = addr
        d.ld_addr.value = addr
        d.st_data.value = 0x1122334455667788
        d.st_mask.value = 0xff
        for _ in range(20):
            obs = await tick()
            if obs["st_ready" if store else "ld_ready"]:
                d.st_valid.value = 0
                d.ld_valid.value = 0
                return
        assert False, f"request not accepted {addr:#x}"

    async def accept_refill(addr, data):
        for _ in range(20):
            obs = await tick()
            if obs["l2_req_valid"]:
                assert obs["l2_req_addr"] == addr, obs
                d.l2_req_ready.value = 1
                assert (await tick())["l2_req_valid"]
                d.l2_req_ready.value = 0
                break
        else:
            assert False, f"L2 request missing {addr:#x}"
        for beat in range(4):
            d.l2_resp_valid.value = 1
            d.l2_resp_data.value = int.from_bytes(data[beat*16:(beat+1)*16], "little")
            d.l2_resp_last.value = int(beat == 3)
            assert (await tick())["l2_resp_ready"]
        d.l2_resp_valid.value = 0
        d.l2_resp_last.value = 0
        for _ in range(20):
            obs = await tick()
            if obs["st_resp_valid" if addr == base else "ld_resp_valid"]:
                return
        assert False, "refill completion missing"

    await tick()
    await tick()
    d.rst.value = 0
    base = 0x80000100
    blank = bytes(64)
    await send_req(True, base + 8)
    await accept_refill(base, blank)
    for way in range(1, 4):
        addr = base + way * 0x1000
        await send_req(False, addr)
        await accept_refill(addr, blank)

    fifth = base + 4 * 0x1000
    await send_req(False, fifth)
    for _ in range(20):
        obs = await tick()
        if obs["wb_valid"]:
            assert obs["wb_addr"] == base, obs
            expected = bytearray(blank)
            expected[8:16] = (0x1122334455667788).to_bytes(8, "little")
            assert obs["wb_data"] == int.from_bytes(expected, "little"), obs
            d.wb_ready.value = 1
            assert (await tick())["wb_valid"]
            d.wb_ready.value = 0
            break
    else:
        assert False, "dirty victim writeback missing"
    await accept_refill(fifth, blank)
