import os
import random

import cocotb
from cocotb.triggers import Timer

from icache_model import CacheModel


class Harness:
    def __init__(self, dut):
        self.d = dut
        self.cycle = 0
        self.responses = []
        self.accepted = []
        dut.clk.value = 0
        dut.rst.value = 1
        dut.req_valid.value = 0
        dut.req_pc.value = 0
        dut.req_ftq_id.value = 0
        dut.req_rq_idx.value = 0
        dut.l2_req_ready.value = 0
        dut.l2_resp_valid.value = 0
        dut.l2_resp_data.value = 0
        dut.l2_resp_last.value = 0
        dut.l2_resp_error.value = 0
        dut.itcm_init_valid.value = 0
        dut.itcm_init_addr.value = 0
        dut.itcm_init_data.value = 0
        dut.itcm_init_wmask.value = 0
        dut.inv_all.value = 0

    async def tick(self):
        self.d.clk.value = 0
        await Timer(5, unit="ns")
        d = self.d
        obs = {
            "req_ready": int(d.req_ready.value),
            "resp_valid": int(d.resp_valid.value),
            "l2_req_valid": int(d.l2_req_valid.value),
            "l2_req_addr": int(d.l2_req_addr.value),
            "l2_resp_ready": int(d.l2_resp_ready.value),
            "idle": int(d.idle.value),
        }
        if obs["resp_valid"]:
            self.responses.append((
                self.cycle,
                int(d.resp_ftq_id.value),
                int(d.resp_rq_idx.value),
                int(d.resp_data.value),
                int(d.resp_exc.value),
            ))
        d.clk.value = 1
        await Timer(5, unit="ns")
        self.cycle += 1
        return obs

    async def reset(self):
        await self.tick()
        await self.tick()
        self.d.rst.value = 0
        await self.tick()
        assert int(self.d.idle.value) == 1

    async def request(self, pc, ftq_id, rq_idx):
        d = self.d
        d.req_pc.value = pc
        d.req_ftq_id.value = ftq_id
        d.req_rq_idx.value = rq_idx
        d.req_valid.value = 1
        for stalls in range(50):
            obs = await self.tick()
            if obs["req_ready"]:
                self.accepted.append((self.cycle - 1, pc, ftq_id, rq_idx))
                d.req_valid.value = 0
                return stalls
        assert False, f"request timeout: pc={pc:#x} ftq_id={ftq_id} cycle={self.cycle}"

    async def expect_count(self, count):
        for _ in range(80):
            if len(self.responses) >= count:
                return
            await self.tick()
        assert False, f"response timeout: got={self.responses} want={count}"

    async def accept_l2_request(self, expected_line):
        for _ in range(30):
            obs = await self.tick()
            if obs["l2_req_valid"]:
                assert obs["l2_req_addr"] == expected_line, (
                    f"cycle={self.cycle} got={obs['l2_req_addr']:#x} "
                    f"want={expected_line:#x}"
                )
                break
        else:
            assert False, f"L2 request timeout line={expected_line:#x}"
        self.d.l2_req_ready.value = 1
        obs = await self.tick()
        assert obs["l2_req_valid"]
        self.d.l2_req_ready.value = 0
        obs = await self.tick()
        assert obs["l2_resp_ready"]

    async def refill(self, data, error_last=False):
        assert len(data) == 64
        d = self.d
        for beat in range(4):
            d.l2_resp_valid.value = 1
            d.l2_resp_data.value = int.from_bytes(data[beat*16:(beat+1)*16], "little")
            d.l2_resp_last.value = int(beat == 3)
            d.l2_resp_error.value = int(error_last and beat == 3)
            obs = await self.tick()
            assert obs["l2_resp_ready"], f"beat={beat} cycle={self.cycle}"
        d.l2_resp_valid.value = 0
        d.l2_resp_last.value = 0
        d.l2_resp_error.value = 0


@cocotb.test()
async def itcm_four_stage_pipeline(dut):
    h = Harness(dut)
    await h.reset()
    assert int(dut.cfg_banks.value) == 2
    assert int(dut.cfg_region_bytes.value) == 16
    base = 0x10000000
    words = [
        bytes(((0x20 * idx + byte) & 0xff) for byte in range(16))
        for idx in range(4)
    ]
    for idx, word in enumerate(words):
        for half in range(2):
            dut.itcm_init_valid.value = 1
            dut.itcm_init_addr.value = base + idx*16 + half*8
            dut.itcm_init_data.value = int.from_bytes(word[half*8:(half+1)*8], "little")
            dut.itcm_init_wmask.value = 0xff
            await h.tick()
    dut.itcm_init_valid.value = 0
    for idx in range(4):
        stalls = await h.request(base + idx*16, idx + 1, idx)
        assert stalls == 0, f"ITCM request {idx} stalled for {stalls} cycles"
    await h.expect_count(4)
    assert [(ftq, rq, data, exc) for _, ftq, rq, data, exc in h.responses] == [
        (idx + 1, idx, int.from_bytes(words[idx], "little"), 0)
        for idx in range(4)
    ], f"responses={h.responses}"
    assert [row[0] for row in h.responses] == list(range(h.responses[0][0], h.responses[0][0]+4))
    assert [resp[0] - accept[0] for resp, accept in zip(h.responses, h.accepted)] == [3]*4


@cocotb.test()
async def banked_refill_hit_under_miss_and_random_hits(dut):
    seed = int(os.environ.get("TEST_SEED", "1"))
    rng = random.Random(seed)
    h = Harness(dut)
    await h.reset()
    model = CacheModel(region_bytes=int(dut.cfg_region_bytes.value))
    bank_count = int(dut.cfg_banks.value)
    assert int(dut.cfg_sets_per_bank.value) * bank_count == 64
    base0, base1 = 0x80000080, 0x80000040
    assert model.bank(base0, bank_count) != model.bank(base1, bank_count)
    data0 = bytes((i*3 + 7) & 0xff for i in range(64))
    data1 = bytes((i*5 + 11) & 0xff for i in range(64))
    model.install(base0, data0)
    model.install(base1, data1)

    await h.request(base1, 1, 1)
    await h.accept_l2_request(base1)
    await h.refill(data1)
    await h.expect_count(1)
    assert h.responses[0][1:] == (1, 1, model.region(base1), 0)

    await h.request(base0, 2, 2)
    await h.accept_l2_request(base0)
    assert await h.request(base1 + 16, 3, 3) == 0
    await h.expect_count(2)
    assert h.responses[1][1:] == (3, 3, model.region(base1 + 16), 0), (
        f"hit under miss: seed={seed} responses={h.responses}"
    )

    await h.refill(data0)
    # Installation is active immediately after the final refill beat.
    dut.req_valid.value = 1
    dut.req_pc.value = base0 + 16
    dut.req_ftq_id.value = 4
    dut.req_rq_idx.value = 4
    obs = await h.tick()
    assert obs["req_ready"] == 0, f"same-bank refill was not backpressured: {obs}"
    dut.req_pc.value = base1 + 32
    obs = await h.tick()
    assert obs["req_ready"] == 1, f"other bank did not progress: {obs}"
    dut.req_valid.value = 0
    await h.expect_count(4)
    by_id = {row[1]: row for row in h.responses}
    assert by_id[2][2:] == (2, model.region(base0), 0)
    assert by_id[3][2:] == (3, model.region(base1 + 16), 0)
    assert by_id[4][2:] == (4, model.region(base1 + 32), 0)

    start = len(h.responses)
    for idx in range(4):
        assert await h.request(base0 + 16*idx, 30 + idx, idx) == 0
    await h.expect_count(start + 4)
    same_bank = h.responses[start:start+4]
    assert [row[0] for row in same_bank] == list(range(same_bank[0][0], same_bank[0][0]+4))
    assert [row[3] for row in same_bank] == [model.region(base0 + 16*idx) for idx in range(4)]
    assert [resp[0] - accept[0] for resp, accept in zip(same_bank, h.accepted[-4:])] == [3]*4

    start = len(h.responses)
    expected = {}
    for idx in range(12):
        pc = rng.choice([base0, base1]) + 16*rng.randrange(4)
        ftq_id = 10 + idx
        rq_idx = idx % (1 << len(dut.req_rq_idx))
        stalls = await h.request(pc, ftq_id, rq_idx)
        assert stalls == 0, f"seed={seed} idx={idx} pc={pc:#x} stalls={stalls}"
        expected[ftq_id] = (rq_idx, model.region(pc), 0)
    await h.expect_count(start + 12)
    actual = {ftq: (rq, data, exc) for _, ftq, rq, data, exc in h.responses[start:]}
    assert actual == expected, f"seed={seed} expected={expected} actual={actual}"


@cocotb.test()
async def failed_refill_does_not_install_and_invalidation_clears_valid(dut):
    h = Harness(dut)
    await h.reset()
    line = 0x80000100
    data = bytes((i + 19) & 0xff for i in range(64))
    await h.request(line, 1, 1)
    await h.accept_l2_request(line)
    dut.req_valid.value = 1
    dut.req_pc.value = line + 16
    obs = await h.tick()
    assert obs["req_ready"] == 0, f"same-line miss must wait: {obs}"
    dut.req_valid.value = 0
    await h.refill(data, error_last=True)
    await h.expect_count(1)
    assert h.responses[0][1] == 1 and h.responses[0][4] == 1

    await h.request(line, 2, 2)
    await h.accept_l2_request(line)
    await h.refill(data)
    await h.expect_count(2)
    assert h.responses[1][1:] == (2, 2, int.from_bytes(data[:16], "little"), 0)
    assert int(dut.idle.value) == 1

    dut.inv_all.value = 1
    dut.req_valid.value = 1
    dut.req_pc.value = line
    obs = await h.tick()
    assert obs["req_ready"] == 0
    dut.req_valid.value = 0
    dut.inv_all.value = 0
    assert int(dut.inv_done.value) == 1
    await h.tick()
    assert int(dut.inv_done.value) == 0
    await h.request(line, 3, 3)
    await h.accept_l2_request(line)
