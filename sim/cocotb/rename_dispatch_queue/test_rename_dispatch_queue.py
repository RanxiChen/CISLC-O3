import os,random
import cocotb
from ports import INPUTS
from l3_contract import *

@cocotb.test()
async def four_wide_fifo_c_append_m_cancel_masks(d):
    seed=int(os.getenv('TEST_SEED','1'));rng=random.Random(seed)
    await reset(d,INPUTS);w=val(d.cfg_width_o);depth=val(d.cfg_depth_o)
    q=[];serial=0
    for cycle in range(600):
        clear(d,INPUTS)
        r=cycle%3==0;mis=r and cycle%9==0;t=cycle%val(d.cfg_tags_o)
        n=min(w,depth-len(q),rng.randrange(w+1)) if not mis else 0
        take=min(w,len(q),rng.randrange(w+1)) if not mis else 0
        new=[(serial+i,rng.getrandbits(val(d.cfg_tags_o))) for i in range(n)]
        bundle(d.enq_uop_i,[codec(d,'renamed_uop_t',valid=1,instruction_id=ident,branch_mask=mask) for ident,mask in new]+[0]*(w-n))
        d.enq_count_i.value=n;d.enq_fire_i.value=n>0;d.deq_accept_count_i.value=take
        d.resolution_valid_i.value=r;d.resolution_mispredict_i.value=mis;d.resolution_tag_i.value=t
        await settle()
        assert val(d.free_count_o)==depth-len(q),(seed,cycle,q)
        out=unbundle(d.deq_uop_o,w)
        count=min(w,len(q));assert val(d.deq_count_o)==count
        assert [(field(d,'renamed_uop_t',e,'instruction_id'),field(d,'renamed_uop_t',e,'branch_mask')) for e in out[:count]]==q[:count],(seed,cycle,q)
        q=([e for e in q if not(e[1]>>t&1)] if mis else q[take:]+new)
        if r:q=[(ident,mask&~(1<<t)) for ident,mask in q]
        serial+=n
        await tick(d)
