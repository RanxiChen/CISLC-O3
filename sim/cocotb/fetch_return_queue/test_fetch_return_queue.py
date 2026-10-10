"""RQ L1 order, identity, completion, and second-request backpressure."""
import os
import random

import cocotb
from cocotb.triggers import ReadOnly, Timer
from fetch_return_queue_model import Inputs, ReturnModel


def val(signal):
    return int(signal.value)


class Bench:
    def __init__(self, dut, seed):
        self.dut = dut
        self.seed = seed
        self.cycle = 0
        self.model = ReturnModel(val(dut.cfg_ftq_depth_o))

    def drive(self, i):
        d = self.dut
        d.clk_i.value = 0
        d.rst_i.value = int(i.rst)
        d.rsv_fire_i.value = int(i.reserve)
        d.rsv_idx_i.value = self.model.free if i.reserve_idx is None else i.reserve_idx
        d.rsv_ftq_id_i.value = i.reserve_id
        d.rsv_region_base_i.value = i.reserve_pc
        d.resp_valid_i.value = int(i.response)
        d.resp_rq_idx_i.value = i.response_idx
        d.resp_ftq_id_i.value = i.response_id
        d.resp_data_i.value = i.response_data
        d.brief_slow_done_i.value = int(i.brief_done)
        d.brief_ftq_id_i.value = i.brief_id
        d.brief_slow_valid_i.value=int(i.slow_update)
        d.brief_slow_id_i.value=i.slow_id
        d.brief_resolve_valid_i.value=int(i.resolve_update)
        d.brief_resolve_id_i.value=i.resolve_id
        d.deq_ready_i.value = int(i.deq_ready)
        d.kill_valid_i.value = int(i.kill)
        d.kill_all_i.value = int(i.kill_all)
        d.kill_self_i.value = int(i.kill_self)
        d.kill_ftq_id_i.value = i.kill_id
        d.kill_slot_i.value = i.kill_slot
        d.ftq_head_i.value = i.head

    def check(self, i, phase):
        if self.cycle == 0 and i.rst and phase == "before":
            return
        d = self.dut
        ready, brief_read, deq, entry = self.model.visible(i)
        context = f"seed={self.seed} cycle={self.cycle} {phase} inputs={i}"
        assert val(d.rsv_ready_o) == ready and val(d.rsv_idx_o) == self.model.free, context
        assert val(d.brief_rd_valid_o) == brief_read, context
        assert val(d.deq_valid_o) == deq, context
        if brief_read:
            assert val(d.brief_rd_id_o) == self.model.brief_entry.ftq_id, context
        if deq:
            assert val(d.deq_ftq_id_o) == entry.ftq_id, context
            assert val(d.deq_region_base_o) == entry.pc, context
            assert val(d.deq_data_o) == entry.data, context
            assert val(d.deq_brief_id_o) == entry.ftq_id, context

    async def step(self, i):
        self.drive(i)
        await Timer(1, unit="ns")
        await ReadOnly()
        self.check(i, "before")
        await Timer(1, unit="ns")
        self.dut.clk_i.value = 1
        self.model.tick(i)
        await Timer(1, unit="ns")
        await ReadOnly()
        self.check(i, "after")
        await Timer(1, unit="ns")
        self.dut.clk_i.value = 0
        self.cycle += 1


@cocotb.test()
async def directed_contract(dut):
 b=Bench(dut,0);await b.step(Inputs(rst=True))
 # Eight accepted demands; delayed slow completion and descending responses.
 for n in range(8):await b.step(Inputs(reserve=True,reserve_id=n+1,reserve_pc=0x1000+16*n))
 assert val(dut.rsv_ready_o)==0
 for n in reversed(range(8)):
  await b.step(Inputs(response=True,response_idx=n,response_id=n+1,response_data=0x100+n))
 await b.step(Inputs(brief_id=1,brief_done=False,deq_ready=True))
 await b.step(Inputs(brief_id=2,brief_done=True,deq_ready=True))
 for n in range(8):await b.step(Inputs(brief_id=n+1,brief_done=True,deq_ready=True))
 await b.step(Inputs(deq_ready=True))
 assert val(dut.rsv_ready_o)==1
 # The reserved index may differ from the currently lowest FREE (demand_hold).
 await b.step(Inputs(reserve=True,reserve_idx=5,reserve_id=20,reserve_pc=0x5000))
 await b.step(Inputs(response=True,response_idx=5,response_id=20,response_data=0x555))
 await b.step(Inputs(brief_done=True,brief_id=20,deq_ready=True))
 await b.step(Inputs(deq_ready=True))
 # Immediate completion at reservation edge.
 await b.step(Inputs(reserve=True,reserve_id=21,response=True,response_idx=0,response_id=21,response_data=99))
 await b.step(Inputs(brief_done=True,brief_id=21,deq_ready=True))
 await b.step(Inputs(deq_ready=True))
 await b.step(Inputs(rst=True))

@cocotb.test()
async def seeded_transactions(dut):
 seed=int(os.environ.get('TEST_SEED','1'),0);rng=random.Random(seed);b=Bench(dut,seed)
 await b.step(Inputs(rst=True));next_id=1
 for cycle in range(200):
  live=[s for s,e in enumerate(b.model.slots) if e is not None and e.data is None]
  response=bool(live) and rng.random()<0.5;s=rng.choice(live) if response else 0
  e=b.model.slots[s] if response else None
  head=b.model.brief_entry;reserve=any(e is None for e in b.model.slots) and rng.random()<0.6
  kill=bool(b.model.order) and rng.random()<0.12
  rid=next_id
  if reserve and not kill:next_id+=1
  await b.step(Inputs(reserve=reserve and not kill,reserve_id=rid,reserve_pc=0x10000000+16*cycle,
   response=response,response_idx=s,response_id=e.ftq_id if e else 0,response_data=rng.getrandbits(128),
   brief_done=rng.random()<0.7,brief_id=head.ftq_id if head and rng.random()<0.8 else 0,
   deq_ready=rng.random()<0.7,kill=kill,kill_all=True))

@cocotb.test()
async def selective_kill_and_response(dut):
 b=Bench(dut,0);depth=b.model.depth
 for head,older,boundary,younger in ((0,2,3,4),(depth-2,depth-1,0,1)):
  for rid,self_kill,slot,cleared in ((older,False,0,False),(boundary,False,0,False),
    (boundary,True,0,True),(boundary,True,2,False),(younger,False,0,True)):
   for ready in (False,True):
    await b.step(Inputs(rst=True));await b.step(Inputs(reserve=True,reserve_id=rid,reserve_pc=0x1000))
    if ready:await b.step(Inputs(response=True,response_id=rid,response_data=55))
    await b.step(Inputs(kill=True,kill_id=boundary,kill_self=self_kill,kill_slot=slot,head=head,
      deq_ready=True,brief_done=True,brief_id=rid,response=not ready,response_id=rid,response_data=77))
    await b.step(Inputs(brief_done=True,brief_id=rid))
    assert val(dut.deq_valid_o)==(not cleared)
    if not cleared:
     assert val(dut.deq_data_o)==(55 if ready else 77)
     await b.step(Inputs(brief_done=True,brief_id=rid,deq_ready=True))
 # Zombies consume capacity but never appear in program order.
 await b.step(Inputs(rst=True))
 for n in range(4):await b.step(Inputs(reserve=True,reserve_id=n+1))
 await b.step(Inputs(kill=True,kill_all=True))
 await b.step(Inputs(reserve=True,reserve_id=10))
 await b.step(Inputs(response=True,response_idx=4,response_id=10,response_data=44))
 await b.step(Inputs(brief_done=True,brief_id=10,deq_ready=True))
 await b.step(Inputs(deq_ready=True))
 for n in range(4):await b.step(Inputs(response=True,response_idx=n,response_id=n+1))
 assert val(dut.rsv_ready_o)==1 and val(dut.brief_rd_valid_o)==0
 await b.step(Inputs(reserve=True,reserve_id=12))
 await b.step(Inputs(kill=True,kill_all=True,response=True,response_id=12))
 await b.step(Inputs())
 assert val(dut.rsv_ready_o)==1


@cocotb.test()
async def held_snapshot_refresh_and_consecutive_delivery(dut):
 b=Bench(dut,0);await b.step(Inputs(rst=True))
 for n in range(3):
  await b.step(Inputs(reserve=True,reserve_id=n+1,response=True,
   response_idx=n,response_id=n+1,response_data=0x100+n))
 await b.step(Inputs(brief_done=True,brief_id=1))
 assert val(dut.deq_valid_o) and val(dut.deq_ftq_id_o)==1
 # The output snapshot is stable even while the next brief port is blocked.
 await b.step(Inputs(brief_done=False,brief_id=2))
 assert val(dut.deq_valid_o) and val(dut.deq_ftq_id_o)==1
 # Both update sources suppress delivery and re-read the surviving owner.
 for source in ('slow','resolve'):
  await b.step(Inputs(deq_ready=True,**{source+'_update':True,source+'_id':1}))
  assert not val(dut.deq_valid_o)
  await b.step(Inputs(brief_done=True,brief_id=1))
  assert val(dut.deq_valid_o) and val(dut.deq_ftq_id_o)==1
 # Next-region pre-read permits one dequeue per cycle after initial fill.
 await b.step(Inputs(brief_done=True,brief_id=2,deq_ready=True))
 assert val(dut.deq_valid_o) and val(dut.deq_ftq_id_o)==2
 await b.step(Inputs(brief_done=True,brief_id=3,deq_ready=True))
 assert val(dut.deq_valid_o) and val(dut.deq_ftq_id_o)==3
 await b.step(Inputs(deq_ready=True));assert not val(dut.deq_valid_o)
