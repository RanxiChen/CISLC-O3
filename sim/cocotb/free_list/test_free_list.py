import os,random
import cocotb
from ports import INPUTS
from l3_contract import *

@cocotb.test()
async def four_lane_allocate_release_checkpoint_reclaim_no_release_bypass(d):
    seed=int(os.getenv('TEST_SEED','1'));rng=random.Random(seed)
    await reset(d,INPUTS);w=val(d.cfg_width_o);pregs=val(d.cfg_pregs_o)
    free=set(range(32,pregs));under=set();active=False;allocated=0
    for cycle in range(700):
        clear(d,INPUTS)
        req=[int(rng.randrange(2)) for _ in range(w)]
        if cycle<17:req=[1]*w # exhaust pool, no current release bypass
        r=active and cycle%23==0;mis=r and cycle%46==0
        releases=rng.sample(sorted(set(range(32,pregs))-free),min(w,len(set(range(32,pregs))-free),rng.randrange(w+1)))
        d.resolution_valid_i.value=r;d.resolution_mispredict_i.value=mis;d.resolution_tag_i.value=0
        array(d.alloc_req_i,req)
        for p,x in enumerate(releases):d.release_valid_i[p].value=1;d.release_preg_i[p].value=x
        await settle()
        assert val(d.free_count_o)==len(free),(seed,cycle,len(free))
        enough=sum(req)<=len(free)
        assert bool(val(d.alloc_available_o))==enough,(seed,cycle,req,len(free))
        candidates=[];available=sorted(free)
        for lane,need in enumerate(req):
            if need and available:
                x=available.pop(0);candidates.append(x)
                assert val(d.alloc_preg_o[lane])==x,(seed,cycle,lane,free)
        fire=enough and not mis and bool(rng.randrange(3))
        create=fire and not active and not r
        d.alloc_fire_i.value=fire
        if create:d.checkpoint_create_i[0].value=1;d.checkpoint_create_tag_i[0].value=0;active=True;under=set()
        masks=[1 if active and not r and not (create and lane==0) else 0 for lane in range(w)]
        array(d.alloc_branch_mask_i,masks)
        free.update(releases)
        if mis:free.update(under)
        elif fire:
            free.difference_update(candidates);free.update(releases);allocated+=len(candidates)
            for lane,need in enumerate(req):
                if need and masks[lane]:under.add(val(d.alloc_preg_o[lane]))
        if r:active=False;under=set()
        await tick(d)
        assert val(d.free_count_o)==len(free),(seed,cycle,free,candidates,releases,fire,r,mis)
    assert allocated>w*10
