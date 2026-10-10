"""L7b F0 public-port directed contracts and 120 seeded RV64I transactions."""
import os,random
import cocotb
from cocotb.triggers import Timer
from ifu_f0_model import rv64i_slots

BASE=0x10000000
NOP=0x13
CNOP=1

def block(halves): return sum(x<<(16*n) for n,x in enumerate(halves))
def field(d,name,lane,bits):return (int(getattr(d,name).value)>>(lane*bits))&((1<<bits)-1)

class Bench:
    def __init__(self,d):self.d=d
    async def step(self,valid=False,data=0,base=BASE,fid=1,entry=0,ready=True,
                   cfi=False,slot=0,cfi_edge=False,exc=False,cause=1,kill=False,sync=False,
                   trunc=False,trunc_slot=0,rst=False):
        d=self.d;d.clk_i.value=0
        for name,value in dict(rst_i=rst,in_valid_i=valid,block_data_i=data,
            region_base_i=base,ftq_id_i=fid,entry_slot_i=entry,out_ready_i=ready,
            cfi_valid_i=cfi,cfi_slot_i=slot,cfi_edge_i=cfi_edge,exc_valid_i=exc,
            exc_cause_i=cause,kill_valid_i=kill,sync_clear_i=sync,
            trunc_i=trunc,trunc_slot_i=trunc_slot).items():getattr(d,name).value=int(value)
        await Timer(1,unit='ns')
        v=lambda name:int(getattr(d,name).value)
        rows=[]
        for lane in range(len(d.out_valid_o)):
            if v('out_valid_o')>>lane&1:
                rows.append(dict(pc=field(d,'out_pc_flat_o',lane,len(d.region_base_i)),
                    word=field(d,'out_inst_flat_o',lane,32),raw=field(d,'out_raw_flat_o',lane,32),
                    length=field(d,'out_len_flat_o',lane,3),slot=field(d,'out_slot_flat_o',lane,len(d.entry_slot_i)),
                    fid=field(d,'out_id_flat_o',lane,len(d.ftq_id_i)),edge=bool(v('out_edge_o')>>lane&1),
                    exc=bool(v('out_exc_o')>>lane&1),cause=field(d,'out_cause_flat_o',lane,6),
                    tval=field(d,'out_tval_flat_o',lane,64)))
        result=dict(rows=rows,ready=v('in_ready_o'),beat=v('out_beat_valid_o'),
                    last=v('out_last_o'),pending=v('out_edge_pend_o'))
        d.clk_i.value=1;await Timer(1,unit='ns');d.clk_i.value=0
        return result
    async def reset(self):await self.step(rst=True)

@cocotb.test()
async def directed_contract(d):
    b=Bench(d);await b.reset()
    data=block([0x0093,0x0010,0x0113,0x0020,0x0193,0x0030,0x0213,0x0040])
    for ready in (False,True):
        r=await b.step(valid=True,data=data,ready=ready,fid=7)
        assert r['ready']==ready and r['beat'] and r['last']
        assert [x['slot'] for x in r['rows']]==[0,2,4,6]
        assert [x['pc'] for x in r['rows']]==[BASE+4*n for n in range(4)]
    r=await b.step(valid=True,data=data,entry=2);assert [x['slot'] for x in r['rows']]==[2,4,6]
    r=await b.step(valid=True,data=data,cfi=True,slot=2);assert [x['slot'] for x in r['rows']]==[0,2]
    # A legal compressed NOP and reserved encoding now take their real lengths.
    r=await b.step(valid=True,data=block([CNOP]*8));assert len(r['rows'])==4 and not r['last']
    await b.step(kill=True)
    r=await b.step(valid=True,data=0);assert len(r['rows'])==1 and r['rows'][0]['exc'] and r['rows'][0]['tval']==0
    r=await b.step(valid=True,data=data,exc=True);assert len(r['rows'])==1 and r['rows'][0]['length']==0 and r['rows'][0]['tval']==BASE
    for kw in (dict(kill=True),dict(sync=True)):
        r=await b.step(valid=True,data=data,**kw);assert not r['beat'] and not r['ready'] and not r['rows']

@cocotb.test()
async def seeded_transactions(d):
    rng=random.Random(int(os.getenv('TEST_SEED','1'),0));b=Bench(d);await b.reset()
    for cycle in range(120):
        words=[rng.getrandbits(30)<<2|3 for _ in range(4)]
        data=sum(w<<(32*n) for n,w in enumerate(words));entry=2*rng.randrange(4)
        valid=rng.random()<.85;ready=rng.random()<.65;kill=rng.random()<.02;sync=rng.random()<.02;exc=rng.random()<.1
        base=BASE+cycle*16;fid=cycle% (1<<len(d.ftq_id_i))
        r=await b.step(valid,data,base,fid,entry,ready,exc=exc,kill=kill,sync=sync)
        active=valid and not (kill or sync)
        assert r['ready']==(ready and not(kill or sync))
        assert r['beat']==active
        expected=rv64i_slots(entry,fault=exc) if active else []
        assert [x['slot'] for x in r['rows']]==expected
        for x in r['rows']:
            assert x['pc']==base+2*x['slot'] and x['fid']==fid
            assert x['word']==(0 if exc else words[x['slot']//2])
            assert x['length']==(0 if exc else 4) and x['exc']==exc
            if exc:assert x['cause']==1 and x['tval']==x['pc']

@cocotb.test()
async def two_beats_first_consumption_backpressure_and_truncation(d):
    b=Bench(d);await b.reset();data=block([CNOP]*8)
    a=await b.step(True,data,fid=2);assert a['ready'] and not a['last']
    assert [x['slot'] for x in a['rows']]==[0,1,2,3]
    for _ in range(3):
        a=await b.step(True,0,base=BASE+16,fid=3,ready=False)
        assert not a['ready'] and a['last'] and [x['slot'] for x in a['rows']]==[4,5,6,7]
        assert all(x['fid']==2 for x in a['rows'])
    a=await b.step();assert a['last'] and not a['ready']
    assert not (await b.step())['beat']
    await b.step(True,data,fid=2,trunc=True,trunc_slot=0)
    assert not (await b.step())['beat']
    await b.step(True,data,fid=2);await b.step(kill=True)
    assert not (await b.step())['beat']

@cocotb.test()
async def edge_join_empty_beat_and_cprime_preservation(d):
    b=Bench(d);await b.reset()
    r=await b.step(True,block([CNOP]*7+[0x0093]),entry=7,fid=3,trunc=True,trunc_slot=7)
    assert r['ready'] and r['beat'] and r['last'] and r['pending'] and not r['rows']
    r=await b.step(True,block([0x0050]+[CNOP]*7),base=BASE+16,fid=4)
    x=r['rows'][0];assert x['pc']==BASE+14 and x['slot']==0 and x['edge'] and x['fid']==4
    assert x['word']==0x00500093 and x['length']==4
    await b.step(kill=True)
    # A cut before slot 7 discards a halfword created on the same edge.
    await b.step(True,block([CNOP]*7+[0x0093]),entry=7,trunc=True,trunc_slot=0)
    r=await b.step(True,block([CNOP]*8),base=BASE+16)
    assert not r['rows'][0]['edge'] and r['rows'][0]['pc']==BASE+16

@cocotb.test()
async def pending_nonsequential_fault_and_sync(d):
    b=Bench(d)
    for mode in ('nonsequential','exception','kill','sync'):
        await b.reset()
        await b.step(True,block([CNOP]*7+[0x0093]),entry=7)
        if mode in ('kill','sync'):await b.step(**{mode:True})
        base=BASE+32 if mode=='nonsequential' else BASE+16
        r=await b.step(True,block([CNOP]*8),base=base,exc=mode=='exception',cause=12)
        x=r['rows'][0]
        if mode=='exception':
            assert len(r['rows'])==1 and x['pc']==BASE+14 and x['edge'] and x['tval']==BASE+16 and x['cause']==12 and x['length']==0
        else:assert not x['edge'] and x['pc']==base

@cocotb.test()
async def mixed_lengths_and_last_half_after_full_beat(d):
    b=Bench(d);await b.reset()
    # 16/32/16/32 fills all four lanes, then a final compressed lane.
    r=await b.step(True,block([CNOP,0x0093,0x0050,CNOP,0x0113,0x0060,CNOP,CNOP]))
    assert [x['slot'] for x in r['rows']]==[0,1,3,4]
    assert [x['length'] for x in r['rows']]==[2,4,2,4] and not r['last']
    r=await b.step();assert [x['slot'] for x in r['rows']]==[6,7] and r['last']
    # Four instructions consume slots 0..6; save slot 7 without a fifth lane.
    await b.reset()
    r=await b.step(True,block([0x0013,0,0x0013,0,0x0013,0,CNOP,0x0093]))
    assert len(r['rows'])==4 and r['last'] and r['pending']
    assert not (await b.step())['beat']


@cocotb.test()
async def structural_reference_mixed_stream(d):
    """The frozen RTL reference checks every public output on each edge."""
    seed=int(os.getenv('TEST_SEED','1'),0)
    rng=random.Random(seed);b=Bench(d);await b.reset()
    for cycle in range(10000):
        halves=[rng.choice([CNOP,0x0093,rng.getrandbits(16)]) for _ in range(8)]
        await b.step(valid=rng.random()<.85,data=block(halves),
            base=BASE+16*cycle,fid=cycle % (1<<len(d.ftq_id_i)),
            entry=rng.randrange(8),ready=rng.random()<.7,
            cfi=rng.random()<.4,slot=rng.randrange(8),cfi_edge=rng.random()<.05,
            exc=rng.random()<.05,kill=rng.random()<.04,sync=rng.random()<.02,
            trunc=rng.random()<.1,trunc_slot=rng.randrange(8))
