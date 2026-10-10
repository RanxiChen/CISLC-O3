import cocotb
from cocotb.triggers import Timer
async def edge(d):
 d.clk_i.value=0;await Timer(1,unit='ns');d.clk_i.value=1;await Timer(1,unit='ns');d.clk_i.value=0;await Timer(1,unit='ns')
async def init(d):
 for n in ('clk_i','alloc_valid_i','alloc_pc_i','slow_valid_i','slow_id_i','slow_pc_i','demand_ready_i','resolve_valid_i','resolve_id_i','resolve_slot_i','resolve_taken_i','resolve_wrong_i','commit_valid_i','commit_ids_i','commit_slots_i','commit_last_i','kill_valid_i','kill_all_i','kill_self_i','kill_id_i','kill_slot_i','pf_ready_i'):getattr(d,n).value=0
 d.rq_ready_i.value=1;d.train_ready_i.value=1;d.train_free_i.value=4;d.rst_i.value=1;await edge(d);d.rst_i.value=0
@cocotb.test()
async def full_ring_release_preserves_demand_cursor(d):
 await init(d);ids=[]
 # Fill and issue the whole ring before retirement, then free its first entry.
 for n in range(32):
  d.alloc_valid_i.value=1;d.alloc_pc_i.value=0x80000000+16*n
  await Timer(1,unit='ns');ids.append(int(d.alloc_id_o.value));await edge(d)
 d.alloc_valid_i.value=0;d.demand_ready_i.value=1
 for _ in range(32):
  await Timer(1,unit='ns');assert int(d.demand_valid_o.value);await edge(d)
 d.commit_valid_i.value=1;d.commit_ids_i.value=ids[0];d.commit_last_i.value=1;await edge(d)
 d.commit_valid_i.value=0;d.commit_last_i.value=0
 for _ in range(8):await edge(d)
 assert int(d.occupancy_o.value)==31
 d.demand_ready_i.value=0;d.alloc_valid_i.value=1;d.alloc_pc_i.value=0x80000200;await edge(d);d.alloc_valid_i.value=0
 await Timer(1,unit='ns')
 assert int(d.demand_valid_o.value)==1 and int(d.demand_pc_o.value)==0x80000200,'release must not skip a reused ring slot'

@cocotb.test()
async def credit_reserved_h0_h1_one_per_cycle(d):
 await init(d);ids=[];n=12
 for i in range(n):
  d.alloc_valid_i.value=1;d.alloc_pc_i.value=0x80004000+16*i
  await Timer(1,unit='ns');ids.append(int(d.alloc_id_o.value));await edge(d)
 d.alloc_valid_i.value=0;d.train_free_i.value=0
 for i in range(n):
  d.commit_valid_i.value=1;d.commit_ids_i.value=ids[i];d.commit_last_i.value=1;await edge(d)
 d.commit_valid_i.value=0
 for _ in range(5):
  await Timer(1,unit='ns');assert not int(d.train_valid_o.value);await edge(d)
 assert int(d.occupancy_o.value)==n
 d.train_free_i.value=4;seen=[]
 for i in range(n+1):
  await Timer(1,unit='ns')
  if int(d.train_valid_o.value):seen.append(int(d.train_pc_o.value))
  await edge(d)
 assert seen==[0x80004000+16*i for i in range(n)]
 assert int(d.occupancy_o.value)==0

@cocotb.test()
async def partial_kill_discards_younger_resolution(d):
 await init(d);d.train_free_i.value=0
 d.alloc_valid_i.value=1;d.alloc_pc_i.value=0x80006000
 await Timer(1,unit='ns');fid=int(d.alloc_id_o.value);await edge(d);d.alloc_valid_i.value=0
 d.resolve_valid_i.value=1;d.resolve_id_i.value=fid;d.resolve_slot_i.value=6;d.resolve_taken_i.value=1;d.resolve_wrong_i.value=1;await edge(d)
 d.resolve_valid_i.value=0;d.kill_valid_i.value=1;d.kill_id_i.value=fid;d.kill_slot_i.value=2;await edge(d);d.kill_valid_i.value=0
 d.commit_valid_i.value=1;d.commit_ids_i.value=fid;d.commit_slots_i.value=2;d.commit_last_i.value=1;await edge(d);d.commit_valid_i.value=0
 d.train_free_i.value=4;await edge(d)
 assert int(d.train_valid_o.value) and not int(d.train_cfi_valid_o.value) and not int(d.train_mask_o.value)
 await edge(d);assert int(d.occupancy_o.value)==0

@cocotb.test()
async def prefetch_waits_slow_and_catches_demand(d):
 await init(d);d.demand_ready_i.value=0;ids=[]
 for n in range(3):
  d.alloc_valid_i.value=1;d.alloc_pc_i.value=0x80008000+16*n;await Timer(1,unit='ns');ids.append(int(d.alloc_id_o.value));await edge(d)
 d.alloc_valid_i.value=0;await Timer(1,unit='ns');assert not int(d.pf_valid_o.value)
 d.slow_valid_i.value=1;d.slow_id_i.value=ids[0];d.slow_pc_i.value=0x80008000;await edge(d);d.slow_valid_i.value=0
 assert int(d.pf_valid_o.value) and int(d.pf_pc_o.value)==0x80008000
 d.demand_ready_i.value=1;await edge(d);d.demand_ready_i.value=0
 assert not int(d.pf_valid_o.value)
 d.slow_valid_i.value=1;d.slow_id_i.value=ids[1];d.slow_pc_i.value=0x80008010;await edge(d);d.slow_valid_i.value=0
 assert int(d.pf_valid_o.value) and int(d.pf_pc_o.value)==0x80008010
 d.pf_ready_i.value=1;await edge(d);d.pf_ready_i.value=0
 assert not int(d.pf_valid_o.value)

@cocotb.test()
async def age_cursor_survives_empty_retirement_and_wrap(d):
 await init(d)
 for n in range(35):
  await Timer(1,unit='ns')
  assert int(d.occupancy_o.value)==0
  assert int(d.head_id_o.value)==0,'empty entry identity keeps its public contract'
  assert int(d.age_head_idx_o.value)==n%32,'age origin follows the circular cursor even when empty'
  d.alloc_valid_i.value=1;d.alloc_pc_i.value=0x80010000+16*n
  await Timer(1,unit='ns');fid=int(d.alloc_id_o.value)
  await edge(d);d.alloc_valid_i.value=0
  await Timer(1,unit='ns')
  assert int(d.age_head_idx_o.value)==n%32
  assert int(d.head_id_o.value)==fid
  d.commit_valid_i.value=1;d.commit_ids_i.value=fid;d.commit_last_i.value=1
  await edge(d);d.commit_valid_i.value=0;d.commit_last_i.value=0
  for _ in range(8):await edge(d)
 await Timer(1,unit='ns')
 assert int(d.occupancy_o.value)==0 and int(d.age_head_idx_o.value)==3
