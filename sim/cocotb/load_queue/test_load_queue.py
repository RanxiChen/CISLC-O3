import os,random
import cocotb
from ports import INPUTS
from l3_contract import *

@cocotb.test()
async def lq_m_surviving_old_execute_request_response(d):
    """Normative U7 exception: old bookkeeping must survive M recovery."""
    await reset(d,INPUTS);w=val(d.cfg_width_o);depth=val(d.cfg_depth_o)
    array(d.alloc_req_i,[1]*w);array(d.alloc_rob_idx_i,list(range(w)))
    array(d.alloc_branch_mask_i,[0,0,1,1]);d.alloc_fire_i.value=1
    await tick(d);d.alloc_fire_i.value=0;array(d.alloc_req_i,[0]*w)
    # Old #0 executes and sends request on the mispredict edge; young #2/3 die.
    d.resolution_valid_i.value=1;d.resolution_mispredict_i.value=1
    d.resolution_tag_i.value=0;d.restore_tail_i.value=2
    d.execute_valid_i.value=1;d.execute_idx_i.value=0;d.execute_addr_i.value=0x80010000
    d.request_fire_i.value=1;d.request_idx_i.value=0
    await tick(d)
    assert val(d.addr_valid_obs_o[0])==1,'LQ-M lost old execute'
    assert val(d.outstanding_obs_o[0])==1,'LQ-M lost old request'
    assert [val(d.live_obs_o[n]) for n in range(w)]==[1,1,0,0]
    assert val(d.free_count_o)==depth-2
    # Old request response on another M edge must clear outstanding once.
    d.execute_valid_i.value=0;d.request_fire_i.value=0
    d.response_valid_i.value=1;d.response_tag_i.value=depth # generation=1,index=0
    await settle();assert val(d.response_live_o)==1
    await tick(d)
    assert val(d.outstanding_obs_o[0])==0,'LQ-M lost old response'
    d.resolution_valid_i.value=0;d.response_tag_i.value=depth+2
    await settle();assert val(d.response_live_o)==0,'cancelled younger response accepted'

@cocotb.test()
async def lq_c_four_allocate_release_wrap_lifecycle(d):
    seed=int(os.getenv('TEST_SEED','1'));rng=random.Random(seed)
    await reset(d,INPUTS);w=val(d.cfg_width_o);depth=val(d.cfg_depth_o)
    q=[];tail=0;gens=[0]*depth;serial=0
    for cycle in range(500):
        clear(d,INPUTS)
        n=min(depth-len(q),w,rng.randrange(w+1))
        release=min(len(q),w,rng.randrange(w+1))
        c=bool(rng.randrange(2));tag=rng.randrange(val(d.cfg_tags_o))
        d.resolution_valid_i.value=c;d.resolution_tag_i.value=tag
        d.alloc_fire_i.value=n>0;d.release_count_i.value=release
        for lane in range(w):
            d.alloc_req_i[lane].value=lane<n
            d.alloc_branch_mask_i[lane].value=0xaaaa & ~(1<<tag) if c else 0xaaaa
            d.alloc_rob_idx_i[lane].value=(serial+lane)%val(d.cfg_rob_o)
        old=list(q)
        if old:
            e=rng.choice(old);d.execute_valid_i.value=1;d.execute_idx_i.value=e;d.execute_addr_i.value=0x80010000+8*e
            d.request_fire_i.value=1;d.request_idx_i.value=e
        await settle()
        assert val(d.free_count_o)==depth-len(q),(seed,cycle,q)
        assert [val(d.alloc_idx_o[l]) for l in range(n)]==[(tail+l)%depth for l in range(n)]
        q=q[release:]
        for lane in range(n):idx=(tail+lane)%depth;q.append(idx);gens[idx]^=1
        tail=(tail+n)%depth;serial+=n
        await tick(d)
        assert val(d.tail_o)==tail,(seed,cycle,tail)
        assert val(d.free_count_o)==depth-len(q),(seed,cycle,q)
        for idx in q:
            assert val(d.live_obs_o[idx])==1
            if c:assert val(d.mask_obs_o[idx])&(1<<tag)==0
        # Released identity must not remain live (unless allocated, which cannot
        # occur because candidates use pre-edge free slots).
        for idx in old[:release]:assert val(d.live_obs_o[idx])==0,(seed,cycle,idx)
