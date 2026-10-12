"""Production 8-to-3 IFU integration: independent instruction stream and event oracle."""
import os
import random
import cocotb
from cocotb.triggers import Timer

BASE=0x80001000

def block(halves):return sum(w<<(16*k) for k,w in enumerate(halves))
def fields(value,width,n=4):return [(int(value)>>(width*k))&((1<<width)-1) for k in range(n)]

def region(base,ident,lengths):
    halves=[];want=[]
    for length in lengths:
        slot=len(halves)
        word=1 if length==2 else 0x00500093
        want.append((base+2*slot,0x13 if length==2 else word,False,
            slot+length//2==8,base+2*slot+length,ident,slot,word,False,0))
        halves.append(word&0xffff)
        if length==4:halves.append(word>>16)
    assert len(halves)==8
    return dict(base=base,id=ident,data=block(halves)),want


class Bench:
    def __init__(self,d):
        self.d=d;self.width=len(d.out_valid_o);assert self.width==3;self.delivered=[];self.corrections=[];self.samples=[]
        self.events=[0]*0x44;self.f0_beats=0;self.cycle=0
    async def step(self,p=None,ready=True,rst=False,clear=False,kill=None):
        d=self.d;p0=p or {};k=kill or {}
        values=dict(clk_i=0,rst_i=rst,clear_i=clear,in_valid_i=p is not None,out_ready_i=ready,
            region_base_i=p0.get('base',BASE),block_data_i=p0.get('data',0),ftq_id_i=p0.get('id',1),head_id_i=1,
            entry_slot_i=p0.get('entry',0),cfi_valid_i=p0.get('cfi',False),cfi_slot_i=p0.get('slot',0),
            predicted_target_i=p0.get('target',0x90000000),exc_i=p0.get('exc',False),cause_i=p0.get('cause',1),
            kill_valid_i=kill is not None,kill_all_i=k.get('all',False),kill_self_i=k.get('self',False),
            kill_id_i=k.get('id',0),kill_slot_i=k.get('slot',0))
        for n,v in values.items():getattr(d,n).value=int(v)
        await Timer(1,unit='ns')
        accepted=p is not None and bool(d.in_ready_o.value)
        mask=int(d.out_valid_o.value);count=mask.bit_count()
        perf=int(d.perf_o.value);incbits=len(d.perf_o)//0x44
        increments=[(perf>>(e*incbits))&((1<<incbits)-1) for e in range(0x44)]
        if not rst:
            assert increments[0x16:0x1b]==[int(ready and count==n) for n in range(5)]
            assert increments[0x32]==int(ready and count<self.width)
            assert increments[0x33]==int(bool(mask) and not ready)
            self.events=[a+b for a,b in zip(self.events,increments)]
            if int(d.f0_fire_o.value):
                assert int(d.f0_last_o.value), 'eight lanes must finish every accepted region'
                self.f0_beats+=1
            if int(d.correction_o.value):
                self.corrections.append((int(d.correction_target_o.value),int(d.correction_slot_o.value)))
                assert mask==0, 'redirect must block delivery'
            if ready:
                self.samples.append(count)
                ports=['out_pc_o','out_instruction_o','out_next_o','out_id_o','out_slot_o','out_raw_o','out_tval_o']
                widths=[64,32,64,len(d.ftq_id_i),len(d.entry_slot_i),32,64]
                vals=[fields(getattr(d,n).value,w,self.width) for n,w in zip(ports,widths)]
                for lane in range(self.width):
                    if mask>>lane&1:
                        pc,word,nextpc,ident,slot,raw,tval=[x[lane] for x in vals]
                        self.delivered.append((pc,word,bool(int(d.out_edge_o.value)>>lane&1),
                            bool(int(d.out_last_o.value)>>lane&1),nextpc,ident,slot,raw,
                            bool(int(d.out_exc_o.value)>>lane&1),tval))
        wait=bool(d.boundary_wait_o.value)
        d.clk_i.value=1;await Timer(1,unit='ns');d.clk_i.value=0;await Timer(1,unit='ns');self.cycle+=1
        return accepted,wait
    async def reset(self):await self.step(rst=True)
    async def drain(self):
        for _ in range(40):await self.step()


@cocotb.test()
async def mixed_five_instruction_regions_sustain_three_after_startup(d):
    b=Bench(d);await b.reset();want=[];sent=0
    for _ in range(600):
        p,rows=region(BASE+16*sent,sent+1,[4,4,4,2,2]) if sent<80 else (None,[])
        if (await b.step(p))[0]:want+=rows;sent+=1
        if len(b.delivered)==400:break
    assert sent==80 and b.delivered==want
    # F0 produces one beat per region, not the old 4+1 two-beat sequence.
    assert b.f0_beats==80 and b.events[0x1b]==0
    first=next(i for i,n in enumerate(b.samples) if n)
    assert b.samples[first:]==[3]*133+[1], b.samples
    assert b.events[0x19]==133 and b.events[0x17]==1 and b.events[0x1a]==0


@cocotb.test()
async def random_mixed_width_backpressure_complete_records(d):
    b=Bench(d);await b.reset();rng=random.Random(int(os.getenv('TEST_SEED','1')))
    sent=0;want=[];patterns=[[2]*8,[4]*4,[4,4,4,2,2],[2,4,2,4,2,2],[2,2,4,4,2,2]]
    p,rows=region(BASE,1,patterns[0])
    for cycle in range(5000):
        accepted,_=await b.step(p,ready=rng.random()<.6)
        if accepted:
            want+=rows;sent+=1
            p,rows=region(BASE+16*sent,sent+1,rng.choice(patterns)) if sent<360 else (None,[])
        if sent==360 and len(b.delivered)==len(want):break
    else:raise AssertionError('mixed stream did not drain')
    assert b.delivered==want and b.f0_beats==360 and b.events[0x1b]==0
    assert b.events[0x33]>0
    assert sum(b.events[0x16:0x1b])==len(b.samples)


@cocotb.test()
async def wide_predecode_cuts_tail_and_kills_queued_younger(d):
    b=Bench(d);await b.reset()
    a=dict(base=BASE,id=1,data=block([1]*6+[0x006f,0x0400]))
    young=dict(base=BASE+16,id=2,data=block([1]*8))
    assert (await b.step(a,ready=False))[0]
    assert (await b.step(young,ready=False))[0]
    await b.drain()
    assert [x[0] for x in b.delivered]==[BASE+2*k for k in range(7)]
    assert b.delivered[-1][3:5]==(True,BASE+12+64)
    assert b.corrections==[(BASE+12+64,6)]
    # Kill a retained region's suffix after it has entered the buffer.
    b=Bench(d);await b.reset()
    p,rows=region(BASE,1,[2]*8)
    assert (await b.step(p,ready=False))[0]
    await b.step(ready=False);await b.step(ready=False)
    await b.step(ready=False,kill=dict(id=1,slot=3))
    await b.drain()
    assert b.delivered==rows[:4]


@cocotb.test()
async def wide_cprime_join_exception_and_synchronization(d):
    for mode in ('join','fault','clear'):
        b=Bench(d);await b.reset()
        a=dict(base=BASE,id=1,entry=7,cfi=True,slot=7,data=block([1]*7+[0x0093]))
        assert (await b.step(a))[0]
        wrong=dict(base=0x90000000,id=2,data=block([1]*8))
        assert not (await b.step(wrong))[0]
        assert not (await b.step(wrong))[0]
        assert b.corrections==[(BASE+16,7)] and not b.delivered
        if mode=='clear':await b.step(clear=True)
        good=dict(base=BASE+16,id=3,data=block([0x0050]+[1]*7),exc=mode=='fault',cause=12)
        if mode=='clear':good['data']=block([1]*8)
        assert (await b.step(good))[0]
        await b.drain()
        if mode=='fault':
            assert len(b.delivered)==1
            assert b.delivered[0][0]==BASE+14 and b.delivered[0][2] and b.delivered[0][8:]==(True,BASE+16)
        elif mode=='join':
            assert [x[0] for x in b.delivered]==[BASE+14]+[BASE+16+2*k for k in range(1,8)]
            assert b.delivered[0][1]==0x00500093 and b.delivered[0][2] and b.delivered[-1][3]
        else:
            assert [x[0] for x in b.delivered]==[BASE+16+2*k for k in range(8)]
            assert not any(x[2] for x in b.delivered)
