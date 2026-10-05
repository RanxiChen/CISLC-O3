import os,random
import cocotb
from ports import INPUTS
from l3_contract import *

@cocotb.test()
async def four_wide_allocate_complete_retire_ftq_wrap(d):
    seed=int(os.getenv('TEST_SEED','1'));rng=random.Random(seed)
    await reset(d,INPUTS);w=val(d.cfg_width_o);depth=val(d.cfg_depth_o)
    q=[];head=tail=0;serial=1;wraps=0;multi_regions=0
    for cycle in range(600):
        clear(d,INPUTS)
        ret=[]
        for e in q[:w]:
            if not e['complete']:break
            ret.append(e)
        n=min(depth-len(q),w,rng.randrange(w+1)) if cycle<550 else 0
        new=[]
        for lane in range(w):
            d.alloc_req_i[lane].value=int(lane<n)
            if lane<n:
                idx=(tail+lane)%depth;ident=serial+lane
                # Adjacent lanes straddle regions, include generation wraps.
                ftq=codec(d,'ftq_id_t',idx=ident%32,gen=(ident//32)%4)
                e=dict(idx=idx,id=ident,ftq=ftq,slot=(2*ident)%8,last=int(ident%2==0),complete=False)
                new.append(e)
                d.alloc_instruction_id_i[lane].value=ident
                d.alloc_ftq_idx_i[lane].value=ftq
                d.alloc_ftq_slot_i[lane].value=e['slot']
                d.alloc_ftq_last_i[lane].value=e['last']
        d.alloc_ready_i.value=int(n>0)
        # Completion takes effect at edge; snapshot-complete prefix only retires.
        incom=[e for e in q if not e['complete']]
        rng.shuffle(incom);completed=incom[:rng.randrange(len(d.complete_valid_i)+1)]
        for p,e in enumerate(completed):
            d.complete_valid_i[p].value=1;d.complete_idx_i[p].value=e['idx']
        await settle()
        got=[val(x) for x in d.retire_valid_o]
        assert got==[int(i<len(ret)) for i in range(w)],(seed,cycle,got,ret,q)
        for lane,e in enumerate(ret):
            actual=(val(d.retire_instruction_id_o[lane]),val(d.retire_ftq_idx_o[lane]),val(d.retire_ftq_slot_o[lane]),val(d.retire_ftq_last_o[lane]))
            assert actual==(e['id'],e['ftq'],e['slot'],e['last']),(seed,cycle,actual,e)
        assert val(d.free_count_o)==depth-len(q),(seed,cycle,len(q))
        multi_regions+=len(ret)>1
        q=q[len(ret):]
        for e in completed:e['complete']=True
        q.extend(new);serial+=n;head=(head+len(ret))%depth
        wraps+=tail+n>=depth;tail=(tail+n)%depth
        await tick(d)
    assert not q and wraps>4 and multi_regions>0,(seed,q,wraps,multi_regions)
