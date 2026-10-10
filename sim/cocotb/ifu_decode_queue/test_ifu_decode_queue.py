"""Beat-list oracle: full payload ownership, throughput, selective kill, empty beats."""
import os
import random
from dataclasses import dataclass,replace
import cocotb
from cocotb.triggers import Timer

@dataclass(frozen=True)
class Beat:
    mask:int
    lanes:tuple
    brief:int
    last:bool
    edge:bool

class Bench:
    def __init__(self,d):
        self.d=d;self.queue=[];self.cycle=0
        self.rng=random.Random(int(os.getenv('TEST_SEED','1')))
        self.lanes=len(d.in_valid_i);self.bits=len(d.in_inst_bits_i)//self.lanes
        self.depth=int(d.ftq_depth_o.value);self.slots=int(d.region_slots_o.value)
        self.idbits=len(d.kill_id_i)
        self.idmask=int(d.inst_id_mask_o.value);self.slotmask=int(d.inst_slot_mask_o.value)
        self.briefmask=int(d.brief_id_mask_o.value)
        self.ids=(self.idmask&-self.idmask).bit_length()-1
        self.ss=(self.slotmask&-self.slotmask).bit_length()-1
        self.bs=(self.briefmask&-self.briefmask).bit_length()-1
    def packet(self,ident,mask=15,last=False,edge=False):
        pos=sorted(self.rng.sample(range(self.slots),self.lanes))
        words=[]
        for slot in pos:
            w=self.rng.getrandbits(self.bits)
            words.append((w&~(self.idmask|self.slotmask)) | (ident<<self.ids) | (slot<<self.ss))
        brief=(self.rng.getrandbits(len(self.d.in_brief_bits_i))&~self.briefmask)|(ident<<self.bs)
        return Beat(mask,tuple(words),brief,last,edge)
    def visible(self):
        d=self.d
        return dict(ready=bool(d.in_ready_o.value),valid=bool(d.out_beat_valid_o.value),
            beat=Beat(int(d.out_valid_o.value),tuple((int(d.out_inst_bits_o.value)>>(i*self.bits))&((1<<self.bits)-1)
                for i in range(self.lanes)),int(d.out_brief_bits_o.value),bool(d.out_last_o.value),bool(d.out_edge_pend_o.value)))
    def check(self,rst,clear,kill):
        got=self.visible();gate=not(rst or clear or kill is not None)
        assert got['ready']==(gate and len(self.queue)<2),(self.cycle,'ready')
        assert got['valid']==(gate and bool(self.queue)),(self.cycle,'valid')
        if got['valid']:assert got['beat']==self.queue[0],(self.cycle,got['beat'],self.queue[0])
        return got
    async def step(self,packet=None,ready=False,kill=None,head=0,clear=False,rst=False):
        d=self.d;zero=Beat(0,(0,)*self.lanes,0,False,False);p=packet or zero
        vals=dict(clk_i=0,rst_i=rst,clear_i=clear,in_beat_valid_i=packet is not None,out_ready_i=ready,
            in_valid_i=p.mask,in_inst_bits_i=sum(w<<(i*self.bits) for i,w in enumerate(p.lanes)),in_brief_bits_i=p.brief,
            in_last_i=p.last,in_edge_pend_i=p.edge,kill_valid_i=kill is not None,kill_all_i=(kill or {}).get('all',False),
            kill_self_i=(kill or {}).get('self',False),kill_id_i=(kill or {}).get('id',0),kill_slot_i=(kill or {}).get('slot',0),head_id_i=head)
        for n,v in vals.items():getattr(d,n).value=int(v)
        await Timer(1,unit='ns');before=self.check(rst,clear,kill)
        if rst or clear:self.queue=[]
        elif kill is not None:
            def killed(ident,slot):
                age=((ident%self.depth)-(head%self.depth))%self.depth*self.slots+slot
                boundary=((kill['id']%self.depth)-(head%self.depth))%self.depth*self.slots+kill['slot']
                return kill.get('all',False) or age>boundary or (kill.get('self',False) and ident==kill['id'] and slot==kill['slot'])
            survivors=[]
            for old in self.queue:
                mask=sum((1<<i) for i,w in enumerate(old.lanes) if old.mask>>i&1 and not killed((w&self.idmask)>>self.ids,(w&self.slotmask)>>self.ss))
                pending_killed=killed((old.brief&self.briefmask)>>self.bs,self.slots-1)
                if mask or (old.mask==0 and not pending_killed):
                    survivors.append(replace(old,mask=mask,last=old.last or mask!=old.mask,edge=old.edge and not pending_killed))
            self.queue=survivors
        else:
            if before['valid'] and ready:self.queue.pop(0)
            if packet is not None and before['ready']:self.queue.append(packet)
        d.clk_i.value=1;await Timer(1,unit='ns');after=self.check(rst,clear,kill)
        d.clk_i.value=0;await Timer(1,unit='ns');self.cycle+=1
        return before,after
    async def reset(self):await self.step(rst=True)

async def bench(d):
    d.clk_i.value=0;d.rst_i.value=1
    await Timer(1,unit='ns')
    b=Bench(d);await b.reset();return b

@cocotb.test()
async def registered_ownership_and_one_beat_per_cycle(d):
    b=await bench(d)
    a,c=b.packet(1),b.packet(2)
    old,new=await b.step(a)
    assert not old['valid'] and new['valid'],'no combinational bypass'
    await b.step(c)
    assert not b.visible()['ready'],'two occupied beats must stop input'
    for _ in range(8):await b.step(b.packet(3),ready=False)
    await b.step(ready=True);await b.step(ready=True)
    previous=None
    for n in range(64):
        p=b.packet(n%(1<<b.idbits),mask=n%16,last=n%3==0,edge=n%7==0)
        old,_=await b.step(p,ready=True)
        assert old['ready']
        if previous is not None:assert old['valid'] and old['beat']==previous
        previous=p
    old,_=await b.step(ready=True);assert old['beat']==previous
    await b.step(clear=True);assert not b.queue

@cocotb.test()
async def selective_wrap_kill_and_empty_beat_metadata(d):
    b=await bench(d)
    older=b.packet(b.depth-1,last=True)
    winner=b.packet(b.depth,last=False,edge=True)
    winner=replace(winner,lanes=tuple((w&~b.slotmask)|(slot<<b.ss)
        for w,slot in zip(winner.lanes,(0,2,4,6))))
    await b.step(older);await b.step(winner)
    await b.step(kill=dict(id=b.depth,slot=3),head=b.depth-1,ready=True)
    assert b.queue[0]==older
    assert b.queue[1].last and not b.queue[1].edge
    assert b.queue[1].mask!=winner.mask
    await b.step(ready=True);await b.step(ready=True)
    for slot,self_kill,expected in ((6,False,False),(7,False,True),(7,True,False)):
        empty=b.packet(5,mask=0,last=True,edge=True)
        await b.step(empty)
        await b.step(kill=dict(id=5,slot=slot,self=self_kill))
        assert bool(b.queue)==expected
        if expected:assert b.queue[0]==empty
        await b.step(clear=True)
    await b.step(b.packet(5));await b.step(b.packet(6))
    await b.step(kill=dict(id=0,slot=0,all=True));assert not b.queue

@cocotb.test()
async def seeded_full_payload_sparse_masks_and_kill_holes(d):
    b=await bench(d);r=b.rng
    for n in range(1200):
        head=r.getrandbits(b.idbits)
        kill=None
        if r.randrange(7)==0:kill=dict(id=r.getrandbits(b.idbits),slot=r.randrange(b.slots),self=bool(r.getrandbits(1)),all=r.randrange(5)==0)
        p=b.packet(r.getrandbits(b.idbits),r.randrange(16),bool(r.getrandbits(1)),bool(r.getrandbits(1))) if r.random()<.8 else None
        await b.step(p,ready=r.random()<.65,kill=kill,head=head,clear=n%97==0,rst=n%251==0)
    for _ in range(3):await b.step(ready=True)
    assert not b.queue
