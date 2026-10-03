import os
import random

import cocotb
from cocotb.triggers import Timer

from l2_cache_model import beat_value, line_bytes, same_set_lines


class Harness:
    def __init__(self, dut, seed):
        self.d = dut
        self.rng = random.Random(seed)
        self.seed = seed
        self.cycle = 0
        dut.clk.value = 0
        dut.rst.value = 1
        dut.init_valid.value = 0
        dut.init_addr.value = 0
        dut.init_data.value = 0
        dut.init_wmask.value = 0
        dut.req_valid.value = 0
        dut.req_addr.value = 0
        dut.req_id.value = 0
        dut.wb_valid.value = 0
        dut.wb_addr.value = 0
        dut.wb_data.value = 0
        dut.resp_ready.value = 1
        dut.recall_allow.value = 1
        dut.probe_allow.value = 1
        dut.probe_dirty.value = 0
        dut.probe_dirty_data.value = 0

    async def tick(self):
        self.d.clk.value = 0
        await Timer(5, unit="ns")
        d = self.d
        obs = {
            "req_ready": int(d.req_ready.value),
            "resp_valid": int(d.resp_valid.value),
            "resp_data": int(d.resp_data.value),
            "resp_last": int(d.resp_last.value),
            "resp_error": int(d.resp_error.value),
            "resp_id": int(d.resp_id.value),
            "recall_valid": int(d.recall_valid.value),
            "recall_addr": int(d.recall_addr.value),
            "probe_valid": int(d.probe_valid.value),
        }
        assert int(d.fatal.value) == 0, f"seed={self.seed} cycle={self.cycle} fatal"
        assert int(d.inclusion_error.value) == 0, (
            f"seed={self.seed} cycle={self.cycle} inclusion error"
        )
        d.clk.value = 1
        await Timer(5, unit="ns")
        self.cycle += 1
        return obs

    async def init_line(self, addr, data):
        for beat in range(4):
            self.d.init_valid.value = 1
            self.d.init_addr.value = addr + beat * 16
            self.d.init_data.value = beat_value(data, beat)
            self.d.init_wmask.value = 0xffff
            await self.tick()
        self.d.init_valid.value = 0

    async def send(self, addr, txn_id):
        self.d.req_valid.value = 1
        self.d.req_addr.value = addr
        self.d.req_id.value = txn_id
        for _ in range(100):
            obs = await self.tick()
            if obs["req_ready"]:
                self.d.req_valid.value = 0
                return
        assert False, f"seed={self.seed} cycle={self.cycle} req timeout addr={addr:#x}"

    async def collect(self, txn_id):
        beats = []
        for _ in range(200):
            self.d.resp_ready.value = int(self.rng.randrange(4) != 0)
            obs = await self.tick()
            if obs["resp_valid"] and int(self.d.resp_ready.value):
                assert obs["resp_id"] == txn_id
                assert obs["resp_error"] == 0
                assert obs["resp_last"] == (len(beats) == 3)
                beats.append(obs["resp_data"])
                if len(beats) == 4:
                    self.d.resp_ready.value = 1
                    return b"".join(word.to_bytes(16, "little") for word in beats)
        assert False, f"seed={self.seed} cycle={self.cycle} response timeout id={txn_id}"

    async def read(self, addr, txn_id):
        await self.send(addr, txn_id)
        return await self.collect(txn_id)


@cocotb.test()
async def inclusive_eviction_dirty_handoff_and_axi_refill(dut):
    seed = int(os.environ.get("TEST_SEED", "1"))
    h = Harness(dut, seed)
    await h.tick()
    assert int(dut.cfg_ways.value) == 4
    addresses = same_set_lines(0x80000000, 5, int(dut.cfg_sets.value))
    contents = [line_bytes(index + 1) for index in range(5)]
    for addr, data in zip(addresses, contents):
        await h.init_line(addr, data)
    dut.rst.value = 0
    await h.tick()

    assert await h.read(addresses[0], 1) == contents[0]
    assert int(dut.ar_count.value) == 1
    assert await h.read(addresses[0], 2) == contents[0]
    assert int(dut.ar_count.value) == 1, "resident L2 hit issued an AXI read"
    for index in range(1, 4):
        assert await h.read(addresses[index], index + 2) == contents[index]
    assert int(dut.ar_count.value) == 4

    # The fifth congruent line must first recall the PLRU victim from both L1s.
    dirty = line_bytes(99)
    dut.probe_dirty.value = 1
    dut.probe_dirty_data.value = int.from_bytes(dirty, "little")
    dut.recall_allow.value = 0
    dut.probe_allow.value = 0
    await h.send(addresses[4], 6)
    for _ in range(3):
        obs = await h.tick()
        assert obs["recall_valid"] and obs["probe_valid"]
        assert obs["recall_addr"] == addresses[0]
        assert int(dut.aw_count.value) == 0
    dut.recall_allow.value = 1
    dut.probe_allow.value = 1
    assert await h.collect(6) == contents[4]
    assert int(dut.recall_count.value) == 1
    assert int(dut.aw_count.value) == 1, "dirty L1D copy was not written to AXI"
    assert int(dut.ar_count.value) == 5

    dut.probe_dirty.value = 0
    assert await h.read(addresses[0], 7) == dirty
    assert int(dut.ar_count.value) == 6, "evicted line was not reloaded from AXI"


@cocotb.test()
async def orphan_l1d_writeback_raises_inclusion_error(dut):
    h = Harness(dut, int(os.environ.get("TEST_SEED", "1")))
    await h.tick()
    dut.rst.value = 0
    dut.wb_valid.value = 1
    dut.wb_addr.value = 0x80000000
    dut.wb_data.value = int.from_bytes(line_bytes(123), "little")
    dut.clk.value = 0
    await Timer(5, unit="ns")
    assert int(dut.wb_ready.value) == 1
    assert int(dut.wb_error.value) == 1
    dut.clk.value = 1
    await Timer(5, unit="ns")
    dut.wb_valid.value = 0
    assert int(dut.inclusion_error.value) == 1
    assert int(dut.ar_count.value) == 0
