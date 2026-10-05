import os, random
import cocotb
from ports import INPUTS
from l3_contract import *

@cocotb.test()
async def fifo_four_wide_wrap_full_partial_flush(d):
    seed=int(os.getenv('TEST_SEED','1'));rng=random.Random(seed)
    await reset(d,INPUTS)
    w=val(d.cfg_width_o);depth=val(d.cfg_depth_o)
    assert w==4 and depth==16
    fifo=[];serial=1;seen_offsets=set();head=tail=0
    for cycle in range(900):
        # First fill/hold/drain directed, then mix random prefixes and flush.
        n=w if cycle<5 else (0 if cycle<16 else rng.randrange(w+1))
        take=0 if cycle<10 else min(len(fifo),w,rng.randrange(w+1))
        flush=cycle in (24,25,899) or (cycle>30 and rng.randrange(80)==0)
        items=[codec(d,'decoded_uop_t',valid=1,instruction_id=serial+j) if j<n else 0 for j in range(w)]
        bundle(d.enq_uop_i,items);d.enq_valid_i.value=int(n>0)
        d.deq_accept_count_i.value=take;d.flush_i.value=int(flush)
        await settle()
        count=min(w,len(fifo));assert val(d.deq_count_o)==count,(seed,cycle,fifo)
        got=unbundle(d.deq_uop_o,w)
        assert [field(d,'decoded_uop_t',x,'instruction_id') for x in got[:count]]==fifo[:count],(seed,cycle,fifo,got)
        ready=depth-len(fifo)>=n
        assert bool(val(d.enq_ready_o))==ready,(seed,cycle,n,len(fifo))
        old=list(fifo)
        if flush:fifo=[];head=tail=0
        else:
            fifo=fifo[take:];head=(head+take)%depth
            if n and ready:fifo.extend(range(serial,serial+n));tail=(tail+n)%depth
        seen_offsets.add((head%w,tail%w));serial+=n
        await tick(d)
    assert {h for h,t in seen_offsets}==set(range(w))
    assert {t for h,t in seen_offsets}==set(range(w))
    assert val(d.deq_count_o)==0
