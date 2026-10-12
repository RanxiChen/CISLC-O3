import os, random
import cocotb
from cocotb.triggers import Timer

@cocotb.test()
async def stationary_slots_preserve_fifo_payload_and_cancellation(d):
    seed=int(os.environ.get('TEST_SEED','105'));rng=random.Random(seed);queue=[]
    d.clk.value=0;d.rst.value=1
    for n in ['flush_i','enq_valid_i','deq_ready_i','enq_uop_i','resolve_i','mispredict_i','tag_i']:
        getattr(d,n).value=0
    await Timer(1,unit='ns');d.clk.value=1;await Timer(1,unit='ns')
    valid=int(d.fmt_valid_o.value);mask=int(d.fmt_mask_o.value);lo=int(d.fmt_lo_mask_o.value)
    shift=(mask & -mask).bit_length()-1;ls=(lo & -lo).bit_length()-1
    tags=mask.bit_count();bits=len(d.enq_uop_i)
    for cycle in range(1000):
        d.clk.value=0
        rst=cycle in [271,709];flush=cycle%59==11
        resolve=rng.randrange(4)==0;mis=resolve and rng.randrange(3)==0
        tag=rng.randrange(tags);bit=1<<(shift+tag);lbit=1<<(ls+tag)
        raw=rng.getrandbits(bits);enq=rng.randrange(2);take=rng.randrange(2)
        for name,value in dict(rst=rst,flush_i=flush,resolve_i=resolve,mispredict_i=mis,
                               tag_i=tag,enq_uop_i=raw,enq_valid_i=enq,deq_ready_i=take).items():
            getattr(d,name).value=value
        await Timer(2,unit='ns')
        active=not(rst or flush);ready=active and len(queue)<2
        live=active and bool(queue) and not(mis and queue[0]&bit)
        context=(seed,cycle,queue,rst,flush,resolve,mis,tag)
        assert int(d.enq_ready_o.value)==ready,context
        assert int(d.deq_valid_o.value)==live,context
        if live:
            expected=queue[0]
            if resolve:expected &= ~(bit|lbit)
            assert int(d.deq_uop_o.value)==expected,context
        if not active:queue=[]
        else:
            queue=[item for i,item in enumerate(queue) if not(mis and item&bit) and not(i==0 and live and take)]
            if enq and ready and not(mis and raw&bit):queue.append(raw|valid)
            if resolve:queue=[item & ~(bit|lbit) for item in queue]
        d.clk.value=1;await Timer(2,unit='ns')
