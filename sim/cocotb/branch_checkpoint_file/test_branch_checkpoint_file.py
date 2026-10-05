import os,random
import cocotb
from ports import INPUTS
from l3_contract import *

@cocotb.test()
async def correct_release_create_no_same_tag_reuse_and_m_tree(d):
    seed=int(os.getenv('TEST_SEED','1'));rng=random.Random(seed)
    await reset(d,INPUTS);w=val(d.cfg_width_o);tags=val(d.cfg_tags_o)
    q={};created=released=merged=full=0
    for cycle in range(700):
        clear(d,INPUTS)
        r=bool(q) and cycle>=5 and bool(rng.randrange(3)!=0)
        t=rng.choice(list(q)) if r else 0
        mis=r and bool(rng.randrange(4)==0)
        d.resolution_valid_i.value=r;d.resolution_mispredict_i.value=mis;d.resolution_tag_i.value=t
        requests=rng.randrange(w+1) if cycle>4 else w
        array(d.alloc_req_i,[int(l<requests) for l in range(w)])
        await settle()
        old_active=sum(1<<x for x in q)
        # Rename mask excludes the resolving tag; candidate pool must retain it.
        assert val(d.active_mask_o)==(old_active&~(1<<t) if r else old_active),(seed,cycle,q,r,t)
        grant=[l for l in range(w) if val(d.alloc_grant_o[l])]
        candidate=[val(d.alloc_tag_o[l]) for l in grant]
        assert len(candidate)==len(set(candidate))
        assert all(x not in q for x in candidate),(seed,cycle,q,candidate)
        if len(q)==tags:assert not grant;full+=1
        if r:
            assert val(d.restore_rob_tail_o)==q[t][1]
            assert val(d.restore_lq_tail_o)==q[t][2]
            assert val(d.restore_sq_tail_o)==q[t][3]
        new={};running=old_active&~(1<<t) if r else old_active
        for l in grant:
            x=val(d.alloc_tag_o[l]);create=not mis and (cycle<4 or rng.randrange(3)!=0)
            d.create_i[l].value=create
            rt=(cycle*w+l)%val(d.cfg_rob_o);lt=(cycle+l)%val(d.cfg_lq_o);st=(cycle*2+l)%val(d.cfg_sq_o)
            d.create_parent_mask_i[l].value=running;d.create_rob_tail_i[l].value=rt
            d.create_lq_tail_i[l].value=lt;d.create_sq_tail_i[l].value=st
            if create:new[x]=(running,rt,lt,st);running|=1<<x
        if r:
            removed=[x for x,e in q.items() if x==t or (mis and e[0]&(1<<t))]
            released+=len(removed);q={x:(e[0]&~(1<<t),*e[1:]) for x,e in q.items() if x not in removed}
        merged+=r and not mis and bool(new);created+=len(new);q.update(new)
        await tick(d)
        d.resolution_valid_i.value=0;await settle()
        assert val(d.active_mask_o)==sum(1<<x for x in q),(seed,cycle,q,new)
        for x,e in q.items():assert val(d.parent_obs_o[x])==e[0],(seed,cycle,x,e)
    assert full>0 and merged>0 and created>tags*2 and released>tags*2
