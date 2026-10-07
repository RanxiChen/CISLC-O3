import os,random
import cocotb
from cocotb.triggers import Timer
async def settle():await Timer(1,unit='ns')
async def edge(d):
 d.clk.value=0;await settle();d.clk.value=1;await settle();d.clk.value=0;await settle()
@cocotb.test()
async def fencei_waits_for_old_reads_and_invalidate_ack(d):
 rng=random.Random(int(os.getenv('TEST_SEED','1')))
 for transaction in range(200):
  for n in ['clk','valid_i','idle_i','inv_done_i']:getattr(d,n).value=0
  d.sf_ack_i.value=0;d.kind_i.value=3
  d.rst.value=1;await edge(d);d.rst.value=0;await settle()
  assert int(d.ready_o.value)==1 and int(d.hold_o.value)==0
  d.valid_i.value=1;await edge(d);d.valid_i.value=0
  for _ in range(rng.randrange(1,9)):
   assert int(d.hold_o.value)==1 and int(d.inv_o.value)==0 and int(d.done_o.value)==0
   await edge(d)
  if transaction%11==0:
   d.rst.value=1;await edge(d);assert int(d.ready_o.value)==1;continue
  d.idle_i.value=1;await settle();assert int(d.inv_o.value)==1
  await edge(d);assert int(d.inv_o.value)==0
  for _ in range(rng.randrange(1,9)):
   assert int(d.hold_o.value)==1 and int(d.done_o.value)==0
   await edge(d)
  d.inv_done_i.value=1;await edge(d);d.inv_done_i.value=0
  assert int(d.done_o.value)==1 and int(d.clear_o.value)==1
  await edge(d);assert int(d.done_o.value)==0 and int(d.ready_o.value)==1

@cocotb.test()
async def pmp_preserves_cache_and_clears_frontend(d):
 for n in ('clk','valid_i','idle_i','inv_done_i'):getattr(d,n).value=0
 d.sf_ack_i.value=0;d.kind_i.value=6;d.rst.value=1;await edge(d);d.rst.value=0
 d.valid_i.value=1;await edge(d);d.valid_i.value=0
 for _ in range(4):
  assert int(d.hold_o.value)==1 and int(d.inv_o.value)==0 and int(d.done_o.value)==0
  await edge(d)
 d.idle_i.value=1;await edge(d)
 assert int(d.inv_o.value)==0 and int(d.done_o.value)==1 and int(d.clear_o.value)==1
 await edge(d);assert int(d.ready_o.value)==1

@cocotb.test()
async def sfence_preserves_icache_and_waits_for_tlb_ack(d):
 for n in ('clk','valid_i','idle_i','inv_done_i','sf_ack_i'):getattr(d,n).value=0
 d.kind_i.value=4;d.rst.value=1;await edge(d);d.rst.value=0
 d.valid_i.value=1;await edge(d);d.valid_i.value=0
 assert int(d.sf_valid_o.value)==0 and int(d.inv_o.value)==0
 d.idle_i.value=1;await settle();assert int(d.sf_valid_o.value)==1
 await edge(d)
 for _ in range(4):
  assert int(d.inv_o.value)==0 and int(d.done_o.value)==0
  await edge(d)
 d.sf_ack_i.value=1;await edge(d);assert int(d.done_o.value)==1
