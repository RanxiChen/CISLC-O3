import os,random
import cocotb
from ports import INPUTS
from l3_contract import *

@cocotb.test()
async def c_issue_enqueue_wakeup_m_kill_stall_preserves_identity(d):
    seed=int(os.getenv('TEST_SEED','1'));rng=random.Random(seed)
    await reset(d,INPUTS);w=val(d.cfg_width_o);depth=val(d.cfg_depth_o);kind=val(d.cfg_kind_o)
    issues=len(d.issue_valid_o);q=[];serial=0
    for cycle in range(650):
        clear(d,INPUTS)
        r=cycle%3==0;mis=r and cycle%15==0;t=cycle%val(d.cfg_tags_o);bit=1<<t
        allow=bool(rng.randrange(2));ready_bits=rng.randrange(1<<issues)
        ready=[bool(rng.randrange(2)) for _ in range(val(d.cfg_pregs_o))]
        array(d.preg_ready_i,list(map(int,ready)))
        waking=rng.randrange(val(d.cfg_pregs_o));d.wakeup_valid_i[0].value=1;d.wakeup_preg_i[0].value=waking
        d.allow_load_i.value=allow;d.issue_ready_i.value=ready_bits
        d.resolution_valid_i.value=r;d.resolution_mispredict_i.value=mis;d.resolution_tag_i.value=t
        n=min(w,depth-len(q),rng.randrange(w+1)) if not mis else 0
        new=[]
        for lane in range(n):
            e=dict(id=serial+lane,mask=rng.getrandbits(val(d.cfg_tags_o)),s1=rng.randrange(1,7),s2=rng.randrange(1,7),rs1=rng.randrange(2),rs2=rng.randrange(2),load=kind==1 and bool(rng.randrange(2)))
            e['a']=not e['rs1'] or ready[e['s1']] or waking==e['s1'];e['b']=not e['rs2'] or ready[e['s2']] or waking==e['s2']
            new.append(e)
        inputs=[codec(d,'renamed_uop_t',valid=1,instruction_id=e['id'],branch_mask=e['mask'],rs1_read_en=e['rs1'],rs2_read_en=e['rs2'],src1_preg=e['s1'],src2_preg=e['s2'],is_load=int(e['load']),is_store=int(kind==1 and not e['load'])) for e in new]
        bundle(d.enq_uop_i,inputs+[0]*(w-n));d.enq_fire_i.value=n>0
        chosen=[]
        if not mis:
            chosen=[i for i,e in enumerate(q) if e['a'] and e['b'] and (kind!=1 or not e['load'] or allow)][:issues]
        await settle()
        assert val(d.free_count_o)==depth-len(q),(seed,cycle,kind,q)
        assert val(d.issue_valid_o)==(1<<len(chosen))-1,(seed,cycle,chosen)
        got=unbundle(d.issue_uop_o,issues)
        for p,i in enumerate(chosen):
            e=q[i];assert field(d,'renamed_uop_t',got[p],'instruction_id')==e['id'],(seed,cycle,p,i)
            assert field(d,'renamed_uop_t',got[p],'branch_mask')==(e['mask']&~bit if r else e['mask']),(seed,cycle,p,e)
        removed={i for p,i in enumerate(chosen) if ready_bits>>p&1}
        q=[e for i,e in enumerate(q) if i not in removed and not(mis and e['mask']&bit)]
        for e in q:
            e['a']=e['a'] or ready[e['s1']] or waking==e['s1'];e['b']=e['b'] or ready[e['s2']] or waking==e['s2']
        q+=new
        if r:
            for e in q:e['mask']&=~bit
        serial+=n
        await tick(d)
