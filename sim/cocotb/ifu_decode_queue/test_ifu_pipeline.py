"""Registered IFU integration: discard speculative beats and preserve c-prime halfword."""
import cocotb
from cocotb.triggers import Timer

BASE=0x80001000

def block(halves):return sum(w<<(16*k) for k,w in enumerate(halves))

def fields(value,width,n):return [(int(value)>>(width*k))&((1<<width)-1) for k in range(n)]

class Bench:
    def __init__(self,d):self.d=d;self.delivered=[];self.corrections=[];self.cycle=0
    async def step(self,packet=None,ready=True,rst=False,clear=False):
        d=self.d;p=packet or {}
        vals=dict(clk_i=0,rst_i=rst,clear_i=clear,in_valid_i=packet is not None,out_ready_i=ready,
            region_base_i=p.get('base',BASE),block_data_i=p.get('data',0),ftq_id_i=p.get('id',1),head_id_i=1,
            entry_slot_i=p.get('entry',0),cfi_valid_i=p.get('cfi',False),cfi_slot_i=p.get('slot',0),
            predicted_target_i=p.get('target',0x90000000))
        for n,v in vals.items():getattr(d,n).value=int(v)
        await Timer(1,unit='ns')
        accepted=packet is not None and bool(d.in_ready_o.value)
        corr=bool(d.correction_o.value)
        if not rst and corr:
            self.corrections.append((int(d.correction_target_o.value),int(d.correction_slot_o.value)))
            assert int(d.out_valid_o.value)==0,'next-cycle kill must block younger delivery'
        if not rst and not clear and ready:
            mask=int(d.out_valid_o.value);n=len(d.out_valid_o)
            pcs=fields(d.out_pc_o.value,64,n);words=fields(d.out_instruction_o.value,32,n)
            nexts=fields(d.out_next_o.value,64,n)
            for lane in range(n):
                if mask>>lane&1:self.delivered.append((pcs[lane],words[lane],bool(int(d.out_edge_o.value)>>lane&1),
                    bool(int(d.out_last_o.value)>>lane&1),nexts[lane]))
        wait=bool(d.boundary_wait_o.value)
        d.clk_i.value=1;await Timer(1,unit='ns');d.clk_i.value=0;await Timer(1,unit='ns');self.cycle+=1
        return accepted,corr,wait
    async def reset(self):await self.step(rst=True)

@cocotb.test()
async def late_predecode_discards_already_queued_younger_region(d):
    b=Bench(d);await b.reset()
    # JAL +64 in the second F0 beat. Its correction is registered while the
    # following region may already enter the new pipeline queue.
    a=dict(base=BASE,id=1,data=block([1]*6+[0x006f,0x0400]))
    younger=dict(base=BASE+16,id=2,data=block([1]*8))
    assert (await b.step(a))[0]
    accepted_young=False
    for _ in range(12):
        accepted,corr,_=await b.step(younger if not accepted_young else None)
        accepted_young |= accepted
        if corr:break
    else:raise AssertionError('JAL correction missing')
    assert accepted_young,'test must exercise an already queued younger region'
    for _ in range(8):await b.step()
    assert [x[0] for x in b.delivered]==[BASE+2*k for k in range(7)]
    assert b.delivered[-1][3] and b.delivered[-1][4]==BASE+12+64
    assert b.corrections==[(BASE+12+64,6)]

@cocotb.test()
async def cprime_empty_beat_keeps_pending_halfword_across_redirect(d):
    b=Bench(d);await b.reset()
    a=dict(base=BASE,id=1,entry=7,cfi=True,slot=7,data=block([1]*7+[0x0093]))
    wrong=dict(base=0x90000000,id=2,data=block([1]*8))
    assert (await b.step(a))[0]
    accepted,corr,wait=await b.step(wrong)
    assert wait and not accepted and not corr,'pending owner must reach F1 before consuming the next block'
    accepted,corr,_=await b.step(wrong)
    assert corr and not accepted
    assert b.corrections==[(BASE+16,7)] and not b.delivered
    good=dict(base=BASE+16,id=3,data=block([0x0050]+[1]*7))
    assert (await b.step(good))[0]
    for _ in range(8):await b.step()
    assert b.delivered[0][:3]==(BASE+14,0x00500093,True)
    assert [x[0] for x in b.delivered]==[BASE+14]+[BASE+16+2*k for k in range(1,8)]
    assert b.delivered[-1][3] and len(b.corrections)==1

@cocotb.test()
async def synchronization_clears_queued_beat_and_pending_alignment(d):
    b=Bench(d);await b.reset()
    a=dict(base=BASE,id=1,data=block([1]*7+[0x0093]))
    assert (await b.step(a,ready=False))[0]
    await b.step(ready=False)
    await b.step(clear=True,ready=False)
    for _ in range(3):await b.step()
    assert not b.delivered and not b.corrections
    good=dict(base=BASE+16,id=3,data=block([1]*8))
    assert (await b.step(good))[0]
    for _ in range(8):await b.step()
    assert [x[0] for x in b.delivered]==[BASE+16+2*k for k in range(8)]
    assert not any(x[2] for x in b.delivered)
