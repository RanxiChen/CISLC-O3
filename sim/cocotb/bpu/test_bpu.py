"""L7a public BPU timing, training, RAS/history side effects and kill tests."""
import os
import random
import cocotb
from cocotb.triggers import Timer
from bpu_model import Records, encode, decode


class Bench:
    def __init__(self, d):
        self.d = d
        self.variable_fields=False
        self.r = Records(addr=len(d.boot_pc_i), idw=len(d.alloc_ftq_id_i),
                         folds=int(d.cfg_fold_w_o.value), history=int(d.cfg_history_w_o.value))
        self.incw = int(d.cfg_perf_inc_w_o.value)
        assert len(d.pred_bits_o) == sum(w for _, w in self.r.pred)
        assert len(d.train_bits_i) == sum(w for _, w in self.r.train)

    def view(self):
        d, r = self.d, self.r
        p = decode(r.pred, int(d.pred_bits_o.value))
        slow = decode(r.pred, int(d.slow_pred_bits_o.value))
        if not self.variable_fields:
            assert p['cfi_is_rvc'] == p['is_edge'] == 0
            assert slow['cfi_is_rvc'] == slow['is_edge'] == 0
        perf = int(d.perf_bits_o.value)
        return dict(pred=p, hist=decode(r.hist, int(d.snapshot_bits_o.value)),
                    ras=decode(r.ras, int(d.ras_bits_o.value)),
                    valid=int(d.alloc_valid_o.value), ready=int(d.train_ready_o.value),
                    slow_valid=int(d.slow_valid_o.value), slow_id=int(d.slow_id_o.value),
                    loop_meta=int(d.slow_loop_bits_o.value),slow=slow, disagree=int(d.slow_override_o.value),
                    req=decode(r.req, int(d.override_bits_o.value)),
                    perf=lambda e:(perf >> (e*self.incw)) & ((1<<self.incw)-1))

    async def step(self, *, rst=False, boot=0x1000, ready=False, fid=1,
                   hold=False, busy=False, kill=False, redirect=None, train=None,
                   restore=None, inject=False, hpc=0, htgt=0, ras_restore=None,
                   ras_fix=0, ras_push=0):
        d, r = self.d, self.r
        d.clk_i.value = 0
        values = dict(rst_i=rst, boot_pc_i=boot, alloc_ready_i=ready,
            alloc_ftq_id_i=fid, hold_i=hold, recover_busy_i=busy, kill_valid_i=kill,
            arb_redirect_valid_i=redirect is not None, arb_redirect_pc_i=redirect or 0,
            train_valid_i=train is not None, train_bits_i=encode(r.train, train or {}),
            hist_restore_valid_i=restore is not None, hist_restore_bits_i=encode(r.hist, restore or {}),
            hist_restore_inject_i=inject, hist_branch_i=hpc, hist_target_i=htgt,
            ras_recover_valid_i=ras_restore is not None, ras_recover_bits_i=encode(r.ras, ras_restore or {}),
            ras_recover_id_i=fid, ras_fix_i=ras_fix, ras_push_i=ras_push)
        for name, value in values.items():getattr(d, name).value = int(value)
        await Timer(1, unit='ns')
        before = self.view()
        assert before['valid'] == (not (rst or hold or busy or kill))
        assert before['ready'] == (not rst)
        assert before['perf'](1) == (before['valid'] and ready)
        assert int(d.hist_done_o.value) == (restore is not None and not rst)
        assert int(d.ras_done_o.value) == (ras_restore is not None and not rst)
        d.clk_i.value = 1
        await Timer(1, unit='ns')
        after = self.view()
        d.clk_i.value = 0
        return before, after

    async def reset(self, pc=0x1000):
        await self.step(rst=True, boot=pc)
        await self.step()

    async def goto(self, pc):
        await self.step(kill=True, redirect=pc)

    async def train(self, base, kind, slot, target, ras=0, count=2):
        for _ in range(count):
            await self.step(train=dict(region_base=base, cfi_valid=1, cfi_type=kind,
                cfi_slot=slot, cfi_target=target, ras_action=ras,
                br_commit_mask=(1<<slot) if kind==1 else 0,
                br_taken_mask=(1<<slot) if kind==1 else 0))
        for _ in range(3): await self.step()


async def bench(d):
    d.clk_i.value = 0
    await Timer(1, unit='ns')
    return Bench(d)


@cocotb.test()
async def sequential_pipeline_and_stalls(d):
    b = await bench(d)
    await b.reset(0x1004)
    pending = []
    expected_pc = 0x1004
    rng = random.Random(int(os.environ.get('TEST_SEED','1')))
    for cycle in range(120):
        ready = rng.random()<.75
        hold = rng.random()<.12
        busy = rng.random()<.05
        kill = rng.random()<.08
        fid = cycle+32
        before, after = await b.step(ready=ready, fid=fid, hold=hold, busy=busy, kill=kill)
        assert before['pred']['region_base'] == expected_pc & ~15
        assert before['pred']['entry_slot'] == (expected_pc & 15)//2
        assert before['pred']['next_pc'] == (expected_pc & ~15)+16
        assert before['pred']['cfi_valid'] == 0
        assert before['hist']['events'] == before['hist']['folds'] == before['ras']['count'] == 0
        completion = pending.pop(0) if pending else None
        if kill:
            completion = None
            pending = []
        else:
            pending.append((fid, before['pred']) if before['valid'] and ready else None)
        assert after['slow_valid'] == (completion is not None)
        if completion:
            assert after['slow_id'] == completion[0] and after['slow'] == completion[1]
        assert after['req']['valid'] == 0
        if before['valid'] and ready:expected_pc = before['pred']['next_pc']


@cocotb.test()
async def taken_branch_history_once_and_recovery(d):
    b = await bench(d)
    await b.reset(0x4000)
    await b.train(0x4000, 1, 2, 0x5000)
    before, first = await b.step(ready=True, fid=0x41)
    assert before['pred']['cfi_valid'] and before['pred']['cfi_target']==0x5000
    assert first['slow_valid'] == 0
    def fold8(pc):
        x=pc>>1
        return (x ^ (x>>8) ^ (x>>16) ^ (x>>24) ^ (x>>32)) & 255
    event=fold8(0x4004) ^ (((fold8(0x5000)<<1) | (fold8(0x5000)>>7)) & 255)
    assert first['hist']['events'] == event
    stable = first['hist']
    _, slow = await b.step(hold=True, ready=True)
    assert slow['slow_valid'] and slow['slow_id']==0x41
    assert slow['slow']['next_pc']==0x5000 and slow['disagree']==0
    assert slow['perf'](3)==1 and slow['perf'](4)==0
    for kwargs in (dict(hold=True, ready=True), dict(ready=False), dict(busy=True, ready=True)):
        old, new = await b.step(**kwargs)
        assert old['perf'](1)==old['perf'](2)==0
        assert old['hist']==new['hist']==stable
    _, restored=await b.step(hold=True, restore={})
    assert restored['hist']=={'events':0,'folds':0}
    await b.step(hold=True, restore={}, inject=True, hpc=0x4004, htgt=0x5000)
    _, view=await b.step(hold=True)
    assert view['hist']==stable


@cocotb.test()
async def call_return_use_entry_ras_checkpoint(d):
    b=await bench(d)
    await b.reset(0x1000)
    await b.train(0x1000, 2, 2, 0x2000, ras=1)
    await b.train(0x2000, 3, 0, 0xDEAD0, ras=2)
    for kwargs in (dict(hold=True, ready=True), dict(ready=False), dict(busy=True, ready=True)):
        old,new=await b.step(**kwargs)
        assert old['ras']['count']==new['ras']['count']==0
        assert old['perf'](0x0b)==0
    old,call=await b.step(ready=True, fid=0x61)
    assert old['ras']['count']==0 and call['ras']['count']==1
    assert call['ras']['top_addr']==0x1008
    assert old['perf'](0x0b)==1
    old,ret=await b.step(ready=True, fid=0x62)
    assert old['pred']['cfi_target']==old['pred']['next_pc']==0x1008
    assert old['perf'](0x0c)==1 and ret['ras']['count']==0
    assert ret['slow_id']==0x61 and ret['slow']['next_pc']==0x2000
    _,ret_slow=await b.step(hold=True)
    assert ret_slow['slow_id']==0x62 and ret_slow['slow']['next_pc']==0x1008
    assert ret_slow['disagree']==0, 'slow return must use saved entry stack, not current empty stack'
    _,restored=await b.step(hold=True, ras_restore=dict(top_idx=0,count=1,top_addr=0xA000))
    assert restored['ras']=={'top_idx':0,'count':1,'top_addr':0xA000}


@cocotb.test()
async def eviction_slow_override_and_inflight_kill(d):
    b=await bench(d)
    await b.reset()
    for n in range(33):
        await b.train(0x1000+n*16, 2, 0, 0x8000+n*16, count=1)
    await b.goto(0x1000)
    old,one=await b.step(ready=True, fid=0x83)
    assert old['pred']['cfi_valid']==0 and old['pred']['next_pc']==0x1010
    assert old['perf'](2)==0 and one['slow_valid']==0
    _,two=await b.step(hold=True)
    assert two['slow_valid'] and two['slow_id']==0x83
    assert two['slow']['cfi_valid'] and two['slow']['next_pc']==0x8000
    assert two['disagree'] and two['perf'](3)==two['perf'](4)==1
    req=two['req']
    assert req==decode(b.r.req,encode(b.r.req,dict(valid=1,src=0,ftq_id=0x83,
        slot=0,target_pc=0x8000,hist_branch_pc=0x1000,hist_target_pc=0x8000,
        ras_push_addr=0x1004)))
    old,killed=await b.step(kill=True)
    assert old['slow_valid'] and old['req']['valid'], 'kill must not combinationally gate slow outputs'
    assert killed['slow_valid']==0 and killed['req']['valid']==0
    await b.goto(0x1100)
    await b.step(ready=True, fid=0x84)
    _,killed=await b.step(kill=True)
    assert not killed['slow_valid']
    for _ in range(3):
        _,view=await b.step(hold=True)
        assert not view['slow_valid'] and not view['req']['valid']

@cocotb.test()
async def compressed_and_edge_call_training_and_return_address(d):
    b=await bench(d);b.variable_fields=True
    for rvc,edge,slot,push in ((1,0,2,0x4006),(0,1,0,0x4002)):
        await b.reset(0x4000)
        t=dict(region_base=0x4000,cfi_valid=1,cfi_type=2,cfi_slot=slot,
               cfi_target=0x5000,ras_action=1,cfi_is_rvc=rvc,is_edge=edge)
        for _ in range(2):await b.step(train=t)
        for _ in range(3):await b.step()
        before,after=await b.step(ready=True,fid=11)
        assert before['pred']['cfi_is_rvc']==rvc and before['pred']['is_edge']==edge
        assert after['ras']['count']==1 and after['ras']['top_addr']==push
        _,slow=await b.step(hold=True)
        assert slow['slow_valid'] and slow['slow']['cfi_is_rvc']==rvc and slow['slow']['is_edge']==edge
        assert not slow['disagree']

@cocotb.test()
async def training_credit_and_t0_t1_drain(d):
 b=await bench(d);await b.reset()
 assert int(d.train_free_o.value)==4
 await b.step(train=dict(region_base=0x4000,cfi_valid=1,cfi_type=2,cfi_slot=0,cfi_target=0x5000))
 assert int(d.train_free_o.value)==3
 for _ in range(8):
  await b.step(train=dict(region_base=0x4000,cfi_valid=1,cfi_type=2,cfi_slot=0,cfi_target=0x5000))
  assert int(d.train_free_o.value)==3,'one packet accepted and one dispatched per cycle'
 await b.step();assert int(d.train_free_o.value)==4
 for _ in range(2):await b.step()
 await b.goto(0x4000);before,_=await b.step(ready=True,fid=1)
 assert before['pred']['cfi_valid'] and before['pred']['cfi_target']==0x5000

@cocotb.test()
async def slow_winner_retains_its_loop_action_on_kill(d):
 b=await bench(d);await b.reset()
 packet=dict(region_base=0x4000,br_commit_mask=4,br_taken_mask=0,tage_meta=4<<40,loop_train=0)
 await b.step(train=packet)
 packet.update(loop_train=0x108,tage_meta=4<<40)
 for loop in range(4):
  for _ in range(200):await b.step(train=dict(packet,br_taken_mask=4,cfi_valid=1,cfi_type=1,cfi_slot=2,cfi_target=0x4000))
  await b.step(train=packet)
 for _ in range(3):await b.step()
 await b.goto(0x4000);await b.step(ready=True,fid=2);await b.step()
 before,_=await b.step(kill=True)
 assert before['slow_valid'] and (before['loop_meta']>>90)&1
 assert (before['loop_meta']>>81)&1,'recovery must replay the winner action even when its speculative edge is killed'
