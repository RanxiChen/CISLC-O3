"""Eight-lane public-port oracle, exhaustive 16B tilings and random recovery.

The original four-lane suite and serial RTL reference remain in use.
"""
import random
import os
import cocotb
from test_ifu_f0 import Bench, block, BASE, CNOP


def tilings(remaining=8):
    if not remaining:
        yield []
    else:
        for tail in tilings(remaining-1):
            yield [(2, CNOP)] + tail
        if remaining >= 2:
            for tail in tilings(remaining-2):
                yield [(4, 0x00500093)] + tail


@cocotb.test()
async def all_region_tilings_entries_cfi_and_stalls(d):
    b=Bench(d)
    assert len(d.out_valid_o)==8
    for instructions in tilings():
        halves=[];expected=[]
        for length,word in instructions:
            expected.append((len(halves),length,0x13 if length==2 else word))
            halves.append(word & 0xffff)
            if length==4:halves.append(word>>16)
        for entry,_,_ in expected:
            for end in [None]+[s for s,_,_ in expected if s>=entry]:
                await b.reset()
                want=[x for x in expected if x[0]>=entry and (end is None or x[0]<=end)]
                for ready in (False,False,True):
                    r=await b.step(True,block(halves),entry=entry,fid=9,ready=ready,
                        cfi=end is not None,slot=end or 0)
                    assert r['ready']==ready and r['last'] and not r['pending']
                    assert [(x['slot'],x['length'],x['word']) for x in r['rows']]==want
                    assert all(x['pc']==BASE+2*x['slot'] and x['fid']==9 and not x['exc'] for x in r['rows'])
                assert not (await b.step())['beat'], 'an entire region must finish in one accepted beat'


@cocotb.test()
async def eight_lane_pending_join_fault_and_cut(d):
    b=Bench(d);await b.reset()
    r=await b.step(True,block([CNOP]*7+[0x0093]),fid=1)
    assert len(r['rows'])==7 and r['last'] and r['pending']
    for ready in (False,True):
        r=await b.step(True,block([0x0050]+[CNOP]*7),base=BASE+16,fid=2,ready=ready)
        assert len(r['rows'])==8 and r['last']
        assert r['rows'][0]['edge'] and r['rows'][0]['word']==0x00500093
        assert [x['pc'] for x in r['rows']]==[BASE+14]+[BASE+16+2*k for k in range(1,8)]
    assert not (await b.step())['beat']
    for cut in (0,7):
        await b.reset()
        await b.step(True,block([CNOP]*7+[0x0093]),fid=1,trunc=True,trunc_slot=cut)
        r=await b.step(True,block([0x0050]+[CNOP]*7),base=BASE+16,fid=2,exc=True,cause=12)
        assert len(r['rows'])==1 and r['rows'][0]['exc'] and r['rows'][0]['cause']==12
        assert r['rows'][0]['edge']==(cut==7)
        assert r['rows'][0]['tval']==BASE+16
    # Preserve pending-half precedence even for an inconsistent prediction
    # before the entry point: no earlier instruction exists to truncate it.
    for exit_slot in range(8):
        for edge_exit in (False,True):
            await b.reset()
            r=await b.step(True,block([CNOP]*7+[0x0093]),entry=7,
                cfi=True,slot=exit_slot,cfi_edge=edge_exit)
            assert r['pending'] and r['last'] and not r['rows']


@cocotb.test()
async def serial_reference_wide_mixed_recovery(d):
    # Width-only parameterization of the preserved serial implementation.
    b=Bench(d);await b.reset();rng=random.Random(int(os.getenv('TEST_SEED','1'),0))
    for cycle in range(10000):
        await b.step(valid=rng.random()<.85,
            data=block([rng.choice([CNOP,0x0093,rng.getrandbits(16)]) for _ in range(8)]),
            base=BASE+16*cycle,fid=cycle%(1<<len(d.ftq_id_i)),entry=rng.randrange(8),
            ready=rng.random()<.7,cfi=rng.random()<.4,slot=rng.randrange(8),
            cfi_edge=rng.random()<.05,exc=rng.random()<.05,kill=rng.random()<.04,
            sync=rng.random()<.02,trunc=rng.random()<.1,trunc_slot=rng.randrange(8))
