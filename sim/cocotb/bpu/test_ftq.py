"""FTQ metadata and commit-event tests in the BPU closure suite."""
import cocotb
from cocotb.triggers import Timer
from bpu_model import Records, encode, decode


class Bench:
    def __init__(self,d):
        self.d=d
        self.r=Records(addr=int(d.addr_w_o.value),idw=len(d.alloc_id_o),folds=int(d.fold_w_o.value),history=int(d.history_w_o.value))
        self.incw=int(d.perf_inc_w_o.value)
        assert len(d.alloc_bits_i)==sum(w for _,w in self.r.pred)
        assert len(d.winner_bits_i)==sum(w for _,w in self.r.req)
        assert len(d.alloc_ras_bits_i)==sum(w for _,w in self.r.ras)
        assert len(d.train_bits_o)==sum(w for _,w in self.r.train)
    def events(self):
        x=int(self.d.perf_bits_o.value)
        return [(x >> (e*self.incw)) & ((1<<self.incw)-1) for e in range(0x0f,0x16)]
    async def step(self, *, rst=False, alloc=None, ckpt=None, slow=None, fid=0,
                   winner=None, kill=False, commit=False, resolve=None, ready=False,
                   all_=False,self_=False,slot=6):
        d,r=self.d,self.r
        d.clk_i.value=0
        values=dict(rst_i=rst,alloc_valid_i=alloc is not None,alloc_bits_i=encode(r.pred,alloc or {}),
            alloc_ras_bits_i=encode(r.ras,ckpt or {}),slow_valid_i=slow is not None,
            slow_id_i=fid,slow_bits_i=encode(r.pred,slow or {}),brief_id_i=fid,
            kill_valid_i=kill,kill_all_i=all_,kill_self_i=self_,kill_id_i=fid,kill_slot_i=slot,
            winner_bits_i=encode(r.req,winner or {}),resolve_bits_i=encode(r.resolve,resolve or {}),
            commit_valid_i=commit,commit_id_i=fid,commit_slot_i=slot,train_ready_i=ready)
        for n,v in values.items():getattr(d,n).value=int(v)
        await Timer(1,unit='ns')
        before=self.events()
        alloc_id=int(d.alloc_id_o.value)
        d.clk_i.value=1
        await Timer(1,unit='ns')
        d.clk_i.value=0
        return alloc_id,before


async def bench(d):
    d.clk_i.value=0
    await Timer(1,unit='ns')
    return Bench(d)


@cocotb.test()
async def brief_winner_acceptance_and_commit_classification(d):
    b=await bench(d)
    fast=dict(region_base=0x4000,cfi_valid=1,cfi_slot=6,cfi_type=2,
              raw_pred_taken=1,cfi_target=0x8000,next_pc=0x8000,jal_mask=0x40)
    ckpt=dict(top_idx=3,count=4,top_addr=0x12340)
    for slow_target,final_target,event in ((0x8000,0x8000,0x10),
            (0x9000,0x8000,0x11),(0x9000,0x9000,0x12),(0x9000,0xA000,0x13)):
        await b.step(rst=True)
        fid,_=await b.step(alloc=fast,ckpt=ckpt)
        await b.step(fid=fid,slow=dict(fast,next_pc=slow_target,cfi_target=slow_target))
        assert int(d.brief_slow_o.value)==1
        assert decode(b.r.ras,int(d.brief_ras_bits_o.value))==ckpt
        winner=dict(valid=1,src=1,ftq_id=fid,slot=6,target_pc=final_target)
        await b.step(fid=fid,winner=winner,kill=True)
        # Held winner with a deliberately different target cannot rewrite final_next_pc.
        await b.step(fid=fid,winner=dict(winner,target_pc=0xBAD0))
        await b.step(fid=fid,commit=True)
        for _ in range(4):
            _,events=await b.step(fid=fid)
            assert events[:6]==[0]*6
            if int(d.train_valid_o.value):break
        assert int(d.train_valid_o.value)==1
        for _ in range(3):
            _,events=await b.step(fid=fid)
            assert events[:6]==[0]*6, 'training backpressure must not count commits'
        _,events=await b.step(fid=fid,ready=True)
        assert events[0]==1 and sum(events[1:5])==1 and events[event-0x0f]==1
        assert events[5]==0
        _,events=await b.step(fid=fid,ready=True)
        assert events[:6]==[0]*6, 'a released region must count only once'


@cocotb.test()
async def exec_fix_mispred_event_and_full_cycle(d):
    b=await bench(d)
    fast=dict(region_base=0x4000,next_pc=0x4010)
    await b.step(rst=True)
    fid,_=await b.step(alloc=fast)
    await b.step(fid=fid,slow=fast)
    resolve=dict(valid=1,mispredict=1,ftq_id=fid,slot=2,branch_pc=0x4004,inst_len=4,
                 cfi_type=1,actual_taken=1,actual_target=0x5000,redirect_pc=0x5000)
    winner=dict(valid=1,src=2,ftq_id=fid,slot=2,target_pc=0x5000)
    await b.step(fid=fid,winner=winner,kill=True,resolve=resolve,slot=2)
    brief=decode(b.r.pred,int(d.brief_pred_bits_o.value))
    assert brief['next_pc']==brief['cfi_target']==0x5000 and brief['cfi_slot']==2
    assert brief['cfi_valid']==brief['raw_pred_taken']==1
    await b.step(fid=fid,commit=True,slot=2)
    for _ in range(4):
        await b.step(fid=fid)
        if int(d.train_valid_o.value):break
    train=decode(b.r.train,int(d.train_bits_o.value))
    assert train['br_commit_mask']==train['br_taken_mask']==4
    assert train['cfi_target']==0x5000 and train['mispredicted']==1
    assert train['cfi_is_rvc']==train['is_edge']==0
    _,events=await b.step(fid=fid,ready=True)
    assert events[:6]==[1,0,0,0,1,1]
    await b.step(rst=True)
    for _ in range(int(d.ftq_depth_o.value)):
        _,events=await b.step(alloc=fast)
        assert events[-1]==0
    _,events=await b.step()
    assert int(d.alloc_ready_o.value)==0 and events[-1]==0
    _,events=await b.step(alloc=fast)
    assert events[-1]==1, 'FTQ-full counts an actual blocked allocation attempt'
