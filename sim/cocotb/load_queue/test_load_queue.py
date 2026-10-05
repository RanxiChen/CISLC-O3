import os,random
import cocotb
from ports import INPUTS
from l3_contract import *

@cocotb.test()
async def lq_m_surviving_old_execute_request_response(d):
    """Normative spec section 7 exception: old bookkeeping must survive M recovery."""
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

@cocotb.test()
async def seeded_lq_m_old_bookkeeping_late_young_and_reused_identity(d):
    seed=int(os.getenv('TEST_SEED','1'));rng=random.Random(seed)
    await reset(d,INPUTS);w=val(d.cfg_width_o);depth=val(d.cfg_depth_o);tags=val(d.cfg_tags_o)
    head=0;gens=[0]*depth;previous={}
    for transaction in range(240):
        clear(d,INPUTS);tag=rng.randrange(tags)
        indices=[(head+n)%depth for n in range(w)]
        d.alloc_fire_i.value=1
        for lane,idx in enumerate(indices):
            d.alloc_req_i[lane].value=1;d.alloc_branch_mask_i[lane].value=(1<<tag) if lane>=2 else 0
            d.alloc_rob_idx_i[lane].value=(transaction*w+lane)%val(d.cfg_rob_o)
            previous[idx]=gens[idx]*depth+idx;gens[idx]^=1
        await tick(d);clear(d,INPUTS)
        for idx in indices:
            d.response_valid_i.value=1;d.response_tag_i.value=previous[idx]
            await settle();assert not val(d.response_live_o),(seed,transaction,idx,'previous generation')
        d.response_valid_i.value=0
        # The second old request already exists before M; its response and the
        # first old execute/request share the exact recovery edge.
        d.request_fire_i.value=1;d.request_idx_i.value=indices[1]
        await tick(d);clear(d,INPUTS)
        address=0x80010000+8*rng.randrange(64)
        d.resolution_valid_i.value=1;d.resolution_mispredict_i.value=1;d.resolution_tag_i.value=tag
        d.restore_tail_i.value=(head+2)%depth
        d.execute_valid_i.value=1;d.execute_idx_i.value=indices[0];d.execute_addr_i.value=address
        d.request_fire_i.value=1;d.request_idx_i.value=indices[0]
        d.response_valid_i.value=1;d.response_tag_i.value=gens[indices[1]]*depth+indices[1]
        await tick(d);clear(d,INPUTS)
        assert val(d.tail_o)==(head+2)%depth and val(d.free_count_o)==depth-2,(seed,transaction)
        assert val(d.addr_valid_obs_o[indices[0]])==1 and val(d.outstanding_obs_o[indices[0]])==1
        assert val(d.outstanding_obs_o[indices[1]])==0
        for idx in indices[2:]:
            d.response_valid_i.value=1;d.response_tag_i.value=gens[idx]*depth+idx
            await settle();assert not val(d.response_live_o),(seed,transaction,idx,'late cancelled young')
        d.response_valid_i.value=0
        for delay in range(rng.randrange(1,5)):
            await tick(d);assert val(d.outstanding_obs_o[indices[0]])==1
        d.response_valid_i.value=1;d.response_tag_i.value=gens[indices[0]]*depth+indices[0]
        await settle();assert val(d.response_live_o)==1
        await tick(d);clear(d,INPUTS)
        assert val(d.outstanding_obs_o[indices[0]])==0
        d.release_count_i.value=2;await tick(d);clear(d,INPUTS)
        head=(head+2)%depth
        assert val(d.free_count_o)==depth
