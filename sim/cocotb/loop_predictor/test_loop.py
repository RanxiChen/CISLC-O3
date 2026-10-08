import cocotb
from cocotb.triggers import Timer
async def settle():await Timer(1,unit='ns')
def v(d,n):return int(getattr(d,n).value)
async def edge(d):
 d.clk_i.value=0;await settle();d.clk_i.value=1;await settle();d.clk_i.value=0;await settle()
async def reset(d):
 for n in ('clk_i','rst_i','lookup_pc_i','pc_i','query_hit_i','query_idx_i','entry_slot_i','br_mask_i','disable_i','spec_i','spec_taken_i','recover_i','recover_ckpt_i','recover_idx_i','recover_slot_i','winner_slot_i','recover_upd_i','recover_taken_i','kill_self_i','exec_valid_i','exec_taken_i','source_i','train_i','train_pc_i','train_hit_i','train_idx_i','train_slot_i','train_use_i','train_pred_i','commit_i','taken_i','tage_meta_i'):getattr(d,n).value=0
 d.rst_i.value=1;await edge(d);d.rst_i.value=0
 d.pc_i.value=0x4000;d.lookup_pc_i.value=0x4000;d.query_hit_i.value=1;d.br_mask_i.value=4;d.train_pc_i.value=0x4000;d.train_slot_i.value=2;d.commit_i.value=4
async def allocate(d,pc=0x4000):
 d.train_pc_i.value=pc;d.train_i.value=1;d.train_hit_i.value=0;d.taken_i.value=0;d.tage_meta_i.value=4<<40;await edge(d);d.train_i.value=0;d.train_hit_i.value=1;d.tage_meta_i.value=0
@cocotb.test()
async def long_loop_confidence_exit_disable_and_bad_use(d):
 await reset(d);await allocate(d)
 for loop in range(4):
  for i in range(200):
   d.train_i.value=1;d.taken_i.value=4;await edge(d)
  d.taken_i.value=0;await edge(d)
 d.train_i.value=0
 assert v(d,'mon_past_o')&1023==200 and v(d,'mon_conf_o')&3==3 and v(d,'use_o')
 for i in range(200):
  assert v(d,'pred_o')==1
  d.spec_i.value=1;d.spec_taken_i.value=1;await edge(d)
 assert v(d,'pred_o')==0,'confident loop predicts its exit'
 d.spec_taken_i.value=0;await edge(d);d.spec_i.value=0;assert v(d,'ckpt_o')&1023==0
 d.disable_i.value=1;await settle();assert v(d,'applicable_o') and not v(d,'use_o')
 d.disable_i.value=0;d.train_i.value=1;d.train_use_i.value=1;d.train_pred_i.value=1;d.taken_i.value=0;await edge(d)
 assert v(d,'mon_conf_o')&3==0 and v(d,'mon_age_o')&7==3
@cocotb.test()
async def restore_entire_checkpoint_and_winner_rules(d):
 await reset(d);await allocate(d)
 ckpt=sum((10+n)<<(10*n) for n in range(8))
 for slot,winner,src,kill,execvalid,taken,expected in ((1,2,0,0,0,1,11),(2,2,0,0,0,1,11),(2,2,2,0,1,0,0),(2,2,2,0,1,1,11),(3,2,0,0,0,1,10),(2,2,0,1,0,1,10),(2,2,2,0,0,1,10)):
  d.recover_i.value=1;d.recover_ckpt_i.value=ckpt;d.recover_upd_i.value=1;d.recover_slot_i.value=slot;d.winner_slot_i.value=winner;d.source_i.value=src;d.kill_self_i.value=kill;d.exec_valid_i.value=execvalid;d.exec_taken_i.value=taken;d.recover_taken_i.value=taken
  await edge(d);assert v(d,'ckpt_o')==(ckpt&~1023)|expected
 d.recover_i.value=0
 # New allocation and recovery collide: new entry counter must start at zero.
 d.train_pc_i.value=0x5000;d.train_hit_i.value=0;d.train_i.value=1;d.tage_meta_i.value=4<<40;d.taken_i.value=0
 d.recover_i.value=1;await edge(d)
 assert (v(d,'ckpt_o')>>10)&1023==0
@cocotb.test()
async def overflow_invalidation_and_replacement_age_decay(d):
 await reset(d);await allocate(d);d.train_i.value=1;d.taken_i.value=4
 for _ in range(1024):await edge(d)
 assert not (v(d,'mon_valid_o')&1)
 await reset(d)
 for i in range(8):await allocate(d,0x4000+16*i)
 assert v(d,'mon_valid_o')==255
 d.train_hit_i.value=0;d.train_pc_i.value=0x6000;d.train_i.value=1;d.tage_meta_i.value=4<<40;d.taken_i.value=0
 for _ in range(24):await edge(d)
 assert v(d,'mon_age_o')==sum(1<<(3*n) for n in range(8)),'protected victims age one at a time'
 await edge(d);assert (v(d,'mon_age_o')&7)==0
 d.spec_i.value=1;d.spec_taken_i.value=1;await edge(d);assert (v(d,'ckpt_o')&1023)==0,'allocation wins a simultaneous speculative increment'
 d.spec_i.value=0;d.train_i.value=0;d.lookup_pc_i.value=0x6000;await settle()
 assert v(d,'hit_o') and v(d,'idx_o')==0
@cocotb.test()
async def slot_and_tag_revalidation(d):
 await reset(d);await allocate(d)
 assert v(d,'applicable_o')
 d.entry_slot_i.value=3;await settle();assert not v(d,'applicable_o')
 d.entry_slot_i.value=0;d.br_mask_i.value=0;await settle();assert not v(d,'applicable_o')
 d.br_mask_i.value=4;d.pc_i.value=0x5000;await settle();assert not v(d,'applicable_o')

@cocotb.test()
async def degenerate_wrong_orientation_relearns(d):
 await reset(d)
 # Initial taken misprediction allocates dir=NT. Repeated T exits yield
 # a confident zero-length pattern, which cannot identify the later NT exit.
 d.train_i.value=1;d.train_hit_i.value=0;d.taken_i.value=4;await edge(d)
 d.train_hit_i.value=1
 for _ in range(4):await edge(d)
 assert v(d,'mon_conf_o')&3==3
 d.train_use_i.value=1;d.train_pred_i.value=1;d.taken_i.value=0;await edge(d)
 assert not (v(d,'mon_valid_o')&1)
 d.train_hit_i.value=0;d.tage_meta_i.value=4<<40;await edge(d);d.train_i.value=0
 assert (v(d,'mon_valid_o')&1) and (v(d,'mon_conf_o')&3)==0
 # New orientation is T and can count real iterations.
 d.train_hit_i.value=1;d.train_i.value=1;d.taken_i.value=4
 for _ in range(200):await edge(d)
 assert v(d,'mon_commit_o')&1023==200
