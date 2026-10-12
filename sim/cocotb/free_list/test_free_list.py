import os,random
import cocotb
from ports import INPUTS
from l3_contract import *

@cocotb.test()
async def exhausted_pool_accepts_highest_index_release_next_cycle(d):
    await reset(d,INPUTS)
    width,pregs=val(d.cfg_width_o),val(d.cfg_pregs_o)
    remaining=pregs-32
    while remaining:
        clear(d,INPUTS)
        count=min(width,remaining)
        array(d.alloc_req_i,[int(lane<count) for lane in range(width)])
        d.alloc_fire_i.value=1
        await settle();assert val(d.alloc_available_o)
        await tick(d);remaining-=count
    clear(d,INPUTS);await settle();assert val(d.free_count_o)==0
    d.alloc_req_i[0].value=1
    d.release_valid_i[0].value=1;d.release_preg_i[0].value=pregs-1
    await settle()
    assert val(d.free_count_o)==0 and not val(d.alloc_available_o)
    await tick(d);d.release_valid_i[0].value=0;await settle()
    assert val(d.free_count_o)==1 and val(d.alloc_available_o)
    assert val(d.alloc_preg_o[0])==pregs-1

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

@cocotb.test()
async def global_free_bitmap_excludes_committed_destinations(d):
    await reset(d,INPUTS);pregs=val(d.cfg_pregs_o);mapping=list(range(32))
    rng=random.Random(int(os.getenv('TEST_SEED','1')))
    for cycle in range(120):
        clear(d,INPUTS);d.alloc_req_i[0].value=1;await settle();new=val(d.alloc_preg_o[0]);d.alloc_fire_i.value=1;await tick(d)
        clear(d,INPUTS);rd=rng.randrange(1,32);commit=bool(rng.randrange(2));d.flush_all_i.value=1
        if commit:
            d.commit_write_i[0].value=1;d.commit_new_preg_i[0].value=new;d.release_valid_i[0].value=1;d.release_preg_i[0].value=mapping[rd];mapping[rd]=new
        await tick(d);clear(d,INPUTS);await settle();assert val(d.free_count_o)==pregs-32
        d.alloc_req_i[0].value=1;await settle();assert val(d.alloc_preg_o[0]) not in mapping,(cycle,mapping)


@cocotb.test()
async def sparse_requests_keep_lowest_order_in_both_domains(d):
    """Exhaust initial pool, return holes, check every sparse request pattern.

    Expected choices come from a sorted set of free identities, independent of
    the gather topology. FP p0 participates; INT p0 remains reserved.
    """
    rng=random.Random(105)
    await reset(d,INPUTS)
    w=val(d.cfg_width_o);pregs=val(d.cfg_pregs_o);fp=bool(val(d.cfg_fp_o))
    for scenario in range(32):
        for pattern in range(1<<w):
            await reset(d,INPUTS)
            remaining=pregs-32
            while remaining:
                clear(d,INPUTS);n=min(w,remaining)
                array(d.alloc_req_i,[int(lane<n) for lane in range(w)])
                d.alloc_fire_i.value=1;await tick(d);remaining-=n
            assert val(d.free_count_o)==0
            pool={0 if fp else 1,pregs-1}
            pool.update(rng.sample(range(2,pregs-1),w-2))
            clear(d,INPUTS)
            for lane,preg in enumerate(sorted(pool)):
                d.release_valid_i[lane].value=1;d.release_preg_i[lane].value=preg
            await tick(d);clear(d,INPUTS)
            req=[(pattern>>lane)&1 for lane in range(w)]
            array(d.alloc_req_i,req);await settle()
            assert val(d.free_count_o)==len(pool) and val(d.alloc_available_o)
            expected=sorted(pool);taken=[]
            for lane,need in enumerate(req):
                if need:
                    preg=expected.pop(0);taken.append(preg)
                    assert val(d.alloc_preg_o[lane])==preg,(scenario,pattern,lane,pool)
            d.alloc_fire_i.value=1;await tick(d)
            assert val(d.free_count_o)==len(pool)-len(taken)


@cocotb.test()
async def continuous_full_bundles_refresh_candidates_and_count_unique_returns(d):
    """Each edge publishes one coherent ownership/capacity/candidate view."""
    await reset(d,INPUTS)
    w,pregs=val(d.cfg_width_o),val(d.cfg_pregs_o)
    free=set(range(32,pregs));previous=[]
    for cycle in range(256):
        clear(d,INPUTS)
        array(d.alloc_req_i,[1]*w);d.alloc_fire_i.value=1
        for lane,preg in enumerate(previous):
            d.release_valid_i[lane].value=1;d.release_preg_i[lane].value=preg
        await settle()
        # Current returns remain unavailable until the ownership edge.
        expected=sorted(free)[:w]
        assert len(expected)==w and val(d.alloc_available_o),(cycle,'full bundle must sustain II1')
        assert val(d.free_count_o)==len(free)
        assert [val(d.alloc_preg_o[lane]) for lane in range(w)]==expected,(cycle,'cached candidates')
        free.difference_update(expected);free.update(previous)
        await tick(d)
        assert val(d.free_count_o)==len(free),(cycle,'coherent count after edge')
        previous=expected
    # A repeated already-free identity is returned only once, even when that
    # same identity is consumed at this edge. The sorted-set oracle is independent
    # of candidate encoding and count-update implementation.
    for mode in ('already_free','same_boundary','duplicate'):
        clear(d,INPUTS)
        expected=sorted(free)[:w]
        requests=[0]*w if mode=='already_free' else [1]*w
        array(d.alloc_req_i,requests);d.alloc_fire_i.value=1
        returned=[expected[0]]*w if mode=='duplicate' else expected
        for lane,preg in enumerate(returned):
            d.release_valid_i[lane].value=1;d.release_preg_i[lane].value=preg
        await settle()
        assert val(d.free_count_o)==len(free) and val(d.alloc_available_o)
        if mode!='already_free':
            assert [val(d.alloc_preg_o[lane]) for lane in range(w)]==expected
            free.difference_update(expected)
        free.update(returned)
        await tick(d)
        clear(d,INPUTS);array(d.alloc_req_i,[1]*w);await settle()
        assert val(d.free_count_o)==len(free),(mode,'unique return count')
        assert [val(d.alloc_preg_o[lane]) for lane in range(w)]==sorted(free)[:w],(mode,'next candidates')
