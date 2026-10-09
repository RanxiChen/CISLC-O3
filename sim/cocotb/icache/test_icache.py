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
        for n in ('pf_valid','pf_addr','pf_epoch','epoch_i','probe_valid','probe_va'):getattr(dut,n).value=0
        self.events=[0]*0x44
        dut.clk.value = 0
        dut.rst.value = 1
        dut.priv_i.value = 3
        dut.pmpcfg_i.value = 0
        dut.pmpaddr_i.value = 0
        dut.req_valid.value = 0
        dut.req_pc.value = 0
        dut.req_ftq_id.value = 0
        dut.req_rq_idx.value = 0
        dut.l2_req_ready.value = 0
        dut.l2_resp_valid.value = 0
        dut.l2_resp_data.value = 0
        dut.l2_resp_id.value = 0
        dut.l2_resp_error.value = 0
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
            "l2_req_id": int(d.l2_req_id.value),
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
        perf=int(d.perf_o.value)
        for e in range(0x44):self.events[e]+=(perf>>(e*(len(d.perf_o)//0x44)))&((1<<(len(d.perf_o)//0x44))-1)
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
        self.pending_id=obs["l2_req_id"]
        self.d.l2_req_ready.value = 1
        obs = await self.tick()
        assert obs["l2_req_valid"]
        self.d.l2_req_ready.value = 0
        obs = await self.tick()
        assert obs["l2_resp_ready"]

    async def refill(self, data, error_last=False):
        assert len(data) == 64
        d = self.d
        d.l2_resp_valid.value=1
        d.l2_resp_id.value=self.pending_id
        d.l2_resp_data.value=int.from_bytes(data,'little')
        d.l2_resp_error.value=int(error_last)
        obs=await self.tick()
        assert obs['l2_resp_ready']
        d.l2_resp_valid.value=0;d.l2_resp_error.value=0


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
    assert obs["req_ready"] == 1, f"same-line miss must merge: {obs}"
    dut.req_valid.value = 0
    # Whole-line response has no four-beat latency. Let the accepted request
    # reach S3 and merge into the existing physical-line MSHR before return.
    for _ in range(4):
        obs=await h.tick();assert not obs['l2_req_valid']
    await h.refill(data, error_last=True)
    await h.expect_count(2)
    assert h.responses[0][1] == 1 and h.responses[0][4] == 1
    assert h.responses[1][4] == 1

    await h.request(line, 2, 2)
    await h.accept_l2_request(line)
    await h.refill(data)
    await h.expect_count(3)
    assert h.responses[2][1:] == (2, 2, int.from_bytes(data[:16], "little"), 0)
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


@cocotb.test()
async def l8a_no_recall_copy_survives_until_explicit_invalidation(dut):
    h = Harness(dut)
    await h.reset()
    line = 0x80000200
    data = bytes((index * 7 + 3) & 0xff for index in range(64))
    await h.request(line, 1, 1)
    await h.accept_l2_request(line)
    await h.refill(data)
    await h.expect_count(1)
    await h.request(line + 16, 2, 2)
    await h.expect_count(2)
    assert h.responses[-1][3] == int.from_bytes(data[16:32], "little")

    # Frozen section 8: L1I has no directory/recall interface. Its copy remains
    # usable without an L2 transaction until explicit FENCE.I invalidation.
    await h.request(line + 32,3,3)
    for _ in range(20):
        obs=await h.tick();assert not obs['l2_req_valid']
    await h.expect_count(3)
    assert h.responses[-1][1:]==(3,3,int.from_bytes(data[32:48],'little'),0)
    dut.inv_all.value=1;await h.tick();dut.inv_all.value=0
    assert int(dut.inv_done.value)==1
    await h.request(line+32,4,4);await h.accept_l2_request(line);await h.refill(data)
    await h.expect_count(4)
    assert h.responses[-1][1:]==(4,4,int.from_bytes(data[32:48],'little'),0)

@cocotb.test()
async def l10_recheck_cached_line_pmp_and_pma_without_refill(d):
    h=Harness(d);await h.reset()
    pc=0x80000400
    payload=bytes(range(64))
    await h.request(pc,1,1)
    await h.accept_l2_request(pc)
    await h.refill(payload)
    await h.expect_count(1)
    assert h.responses[-1][4]==0
    # S loses execute on an already cached line; then locked PMP constrains M.
    for priv,cfg in ((1,0x0b),(3,0x88)):
        d.priv_i.value=priv;d.pmpcfg_i.value=cfg;d.pmpaddr_i.value=0x40000000
        target=len(h.responses)+1
        await h.request(pc,2,2)
        for _ in range(10):
            obs=await h.tick();assert not obs['l2_req_valid']
            if len(h.responses)==target:break
        assert len(h.responses)==target and h.responses[-1][4]==1,(priv,cfg,h.responses)
    # M no-match is allowed by PMP; PMA rejects the SRAM-end hole and high Bare VA.
    d.priv_i.value=3;d.pmpcfg_i.value=0
    for bad_pc in (0x11010000,0x100000000,0x180000000,0xffffffffffffff00):
        target=len(h.responses)+1
        await h.request(bad_pc,3,3)
        for _ in range(10):
            obs=await h.tick();assert not obs['l2_req_valid']
            if len(h.responses)==target:break
        assert len(h.responses)==target and h.responses[-1][4]==1,(hex(bad_pc),h.responses)

@cocotb.test()
async def platform_sram_fetch_refill_and_cached_hit(d):
    h=Harness(d);await h.reset()
    pc=0x11000000
    payload=bytes((i*17+9)&255 for i in range(64))
    await h.request(pc,1,1)
    await h.accept_l2_request(pc)
    await h.refill(payload)
    await h.expect_count(1)
    assert h.responses[-1][1:]==(1,1,int.from_bytes(payload[:16],'little'),0)
    await h.request(pc+16,2,2)
    for _ in range(10):
        obs=await h.tick();assert not obs['l2_req_valid']
        if len(h.responses)==2:break
    assert len(h.responses)==2
    assert h.responses[-1][1:]==(2,2,int.from_bytes(payload[16:32],'little'),0)

@cocotb.test()
async def prefetch_permission_reserve_and_provenance(dut):
 h=Harness(dut);await h.reset();base=0x80008000;data=bytes(range(64))
 async def pf(addr,epoch=0):
  dut.pf_addr.value=addr;dut.pf_epoch.value=epoch;dut.pf_valid.value=1
  await Timer(1,unit='ns');ready=int(dut.pf_ready.value);status=int(dut.pf_status.value)
  await h.tick();dut.pf_valid.value=0
  return ready,status
 # Epoch/PMA/PMP failure consumes even if allocation would be blocked.
 assert await pf(base,1)==(1,3)
 assert await pf(0x02000000)==(1,3)
 dut.priv_i.value=1
 assert await pf(base)==(1,3)
 dut.priv_i.value=3
 assert await pf(base)==(1,0)
 await h.accept_l2_request(base);await h.refill(data)
 for _ in range(3):await h.tick()
 assert not h.responses,'prefetch never creates demand responses'
 await h.request(base,1,1);await h.expect_count(1)
 assert h.responses[0][3]==int.from_bytes(data[:16],'little') and h.events[0x3f]==1
 await h.request(base+16,2,2);await h.expect_count(2);assert h.events[0x3f]==1
 # A demand joins a pending PF exactly once, making the install non-PF.
 assert await pf(base+64)==(1,0)
 await h.accept_l2_request(base+64);await h.request(base+64,3,3)
 for _ in range(5):await h.tick()
 assert h.events[0x40]==1
 await h.refill(data);await h.expect_count(3)
 await h.request(base+80,4,4);await h.expect_count(4);assert h.events[0x3f]==1
 # Fill five PF lines in one set: the first unused PF is evicted.
 for n in range(5):
  a=0x80010000+n*8192
  assert await pf(a)==(1,0)
  await h.accept_l2_request(a);await h.refill(data)
  for _ in range(3):await h.tick()
 assert h.events[0x41]>=1
 # Three PF MSHRs leave the fourth reserved for demand.
 for n in range(3):
  a=base+0x400+64*n
  assert await pf(a)==(1,0)
  await h.accept_l2_request(a)
 assert await pf(base+0x600)==(0,0)
 assert h.events[0x2d]>=1
 assert await pf(base+0x600,1)==(1,3)

@cocotb.test()
async def demand_has_priority_over_idle_port_probe(dut):
 h=Harness(dut);await h.reset()
 dut.probe_valid.value=1;dut.probe_va.value=0x80004000
 await Timer(1,unit='ns');assert int(dut.probe_grant.value)
 await h.tick();assert int(dut.probe_resp.value) and int(dut.probe_hit.value)
 dut.req_valid.value=1;dut.req_pc.value=0x80000000
 await Timer(1,unit='ns');assert not int(dut.probe_grant.value)
 await h.tick();dut.req_valid.value=0;dut.probe_valid.value=0
