"""L8a migration: allocation/recovery scales retained, actual saved requests tested."""
import os
import random
import cocotb
from l3_contract import *

INPUTS=['rob_head_i','dma_invalidate_i','dma_line_i','pte_a_write_i','pte_a_line_i','heu_done_i','heu_done_idx_i','clk','rst','flush_i','alloc_req_i','alloc_fire_i','alloc_rob_idx_i','alloc_branch_mask_i',
        'capture_valid_i','capture_i','update_valid_i','update_i','dc_wake_i','tlb_wake_i',
        'sq_change_i','ad_wake_i','replay_ready_i','release_count_i','resolution_valid_i',
        'resolution_mispredict_i','resolution_tag_i','restore_tail_i']
MSHR,FULL,WB,CONFLICT,SNAP,BANK,AD=4,5,6,7,8,9,10
MISS,REPLAY=1,2


def capture(d,idx,va,mask=0,rob=1,ident=42):
    return codec(d,'capture',**{'uop.lq_idx':idx,'uop.branch_mask':mask,'uop.rob_idx':rob,
                  'uop.instruction_id':ident,'uop.dst_preg':7,'uop.dst_dom':1,
                  'uop.is_load':1,'uop.mem_size':3,'va':va})


def update(d,idx,gen,status=REPLAY,reason=CONFLICT,mshr=0):
    return codec(d,'update',**{'valid':1,'status':status,'reason':reason,'mshr_id':mshr,
                             'lq_tag.idx':idx,'lq_tag.gen':gen})


async def allocate(d,masks,robs=None):
    w=val(d.cfg_width_o)
    array(d.alloc_req_i,[int(n<len(masks)) for n in range(w)])
    array(d.alloc_branch_mask_i,masks+[0]*(w-len(masks)))
    array(d.alloc_rob_idx_i,(robs or list(range(len(masks))))+[0]*(w-len(masks)))
    d.alloc_fire_i.value=1
    await settle()
    ids=[val(d.alloc_idx_o[n]) for n in range(len(masks))]
    await tick(d)
    d.alloc_fire_i.value=0;array(d.alloc_req_i,[0]*w)
    return ids


def replay_ids(d):
    return [field(d,'capture',val(d.replay_o[p]),'tag.idx') for p in range(val(d.cfg_pipes_o)) if val(d.replay_valid_o[p])]


@cocotb.test()
async def lq_m_surviving_old_execute_request_response(d):
    await reset(d,INPUTS);depth=val(d.cfg_depth_o)
    ids=await allocate(d,[0,0,1,1])
    array(d.capture_valid_i,[1,1]);array(d.capture_i,[capture(d,ids[0],0x80010000),capture(d,ids[1],0x80010008)])
    d.resolution_valid_i.value=1;d.resolution_mispredict_i.value=1;d.resolution_tag_i.value=0;d.restore_tail_i.value=2
    array(d.update_valid_i,[1,1]);array(d.update_i,[update(d,0,1,MISS,MSHR),update(d,1,1,0,0)])
    await tick(d);clear(d,INPUTS)
    assert val(d.va_obs_o[0])==0x80010000,'LQ-M lost old capture'
    assert val(d.ready_obs_o[0])==0 and val(d.executed_obs_o[1])==1,'LQ-M lost old completion'
    assert [val(d.live_obs_o[n]) for n in ids]==[1,1,0,0]
    assert val(d.free_count_o)==depth-2
    d.dc_wake_i.value=32 # install{0}
    await tick(d);d.dc_wake_i.value=0
    assert replay_ids(d)==[0]
    array(d.replay_ready_i,[1,0]);await tick(d);array(d.replay_ready_i,[0,0])
    array(d.update_valid_i,[1,0]);array(d.update_i,[update(d,2,1,MISS,MSHR),0])
    d.dc_wake_i.value=32;await tick(d)
    assert not replay_ids(d),'cancelled younger identity resurrected'


@cocotb.test()
async def lq_c_four_allocate_release_wrap_lifecycle(d):
    rng=random.Random(int(os.getenv('TEST_SEED','1')))
    await reset(d,INPUTS);w=val(d.cfg_width_o);depth=val(d.cfg_depth_o)
    q=[];tail=0;gens=[0]*depth;serial=0
    for cycle in range(500):
        clear(d,INPUTS)
        n=min(depth-len(q),w,rng.randrange(w+1));release=min(len(q),w,rng.randrange(w+1))
        c=bool(rng.randrange(2));tag=rng.randrange(val(d.cfg_tags_o))
        d.resolution_valid_i.value=c;d.resolution_tag_i.value=tag
        d.alloc_fire_i.value=n>0;d.release_count_i.value=release
        for lane in range(w):
            d.alloc_req_i[lane].value=lane<n
            d.alloc_branch_mask_i[lane].value=0xaaaa&~(1<<tag) if c else 0xaaaa
            d.alloc_rob_idx_i[lane].value=(serial+lane)%val(d.cfg_rob_o)
        old=list(q)
        if old:
            idx=rng.choice(old);d.capture_valid_i[0].value=1
            d.capture_i[0].value=capture(d,idx,0x80010000+8*idx,mask=0xaaaa&~(1<<tag) if c else 0xaaaa)
            d.update_valid_i[0].value=1;d.update_i[0].value=update(d,idx,gens[idx],MISS,MSHR)
        await settle()
        assert val(d.free_count_o)==depth-len(q),(cycle,q)
        assert [val(d.alloc_idx_o[l]) for l in range(n)]==[(tail+l)%depth for l in range(n)]
        q=q[release:]
        for lane in range(n):idx=(tail+lane)%depth;q.append(idx);gens[idx]=(gens[idx]+1)&255
        tail=(tail+n)%depth;serial+=n
        await tick(d)
        assert val(d.tail_o)==tail and val(d.free_count_o)==depth-len(q),(cycle,q,tail)
        for idx in q:
            assert val(d.live_obs_o[idx]) and val(d.gen_obs_o[idx])==gens[idx]
            if c:assert val(d.mask_obs_o[idx])&(1<<tag)==0
        for idx in old[:release]:assert not val(d.live_obs_o[idx]),(cycle,idx)


@cocotb.test()
async def seeded_lq_m_old_bookkeeping_late_young_and_reused_identity(d):
    rng=random.Random(int(os.getenv('TEST_SEED','1')))
    await reset(d,INPUTS);w=val(d.cfg_width_o);depth=val(d.cfg_depth_o);tags=val(d.cfg_tags_o)
    head=0;gens=[0]*depth
    for transaction in range(240):
        clear(d,INPUTS);tag=rng.randrange(tags)
        ids=await allocate(d,[0,0,1<<tag,1<<tag],[(transaction*w+l)%val(d.cfg_rob_o) for l in range(w)])
        assert ids==[(head+n)%depth for n in range(w)]
        for idx in ids:
            stale=gens[idx];gens[idx]=(gens[idx]+1)&255
            d.update_valid_i[0].value=1;d.update_i[0].value=update(d,idx,stale)
            await tick(d)
            assert not val(d.ready_obs_o[idx]),(transaction,idx,'stale generation')
        clear(d,INPUTS)
        addr=0x80010000+8*rng.randrange(64)
        array(d.capture_valid_i,[1,1]);array(d.capture_i,[capture(d,ids[0],addr),capture(d,ids[1],addr+8)])
        array(d.update_valid_i,[1,1]);array(d.update_i,[update(d,ids[0],gens[ids[0]],MISS,MSHR),update(d,ids[1],gens[ids[1]],0,0)])
        d.resolution_valid_i.value=1;d.resolution_mispredict_i.value=1;d.resolution_tag_i.value=tag;d.restore_tail_i.value=(head+2)%depth
        await tick(d);clear(d,INPUTS)
        assert val(d.tail_o)==(head+2)%depth and val(d.free_count_o)==depth-2
        assert val(d.va_obs_o[ids[0]])==addr and val(d.executed_obs_o[ids[1]])
        for idx in ids[2:]:
            d.update_valid_i[0].value=1;d.update_i[0].value=update(d,idx,gens[idx],MISS,MSHR)
            d.dc_wake_i.value=32;await tick(d)
            assert not val(d.live_obs_o[idx]) and not val(d.ready_obs_o[idx]),(transaction,idx)
        clear(d,INPUTS)
        # Old waiter survives cancellation and its real install makes it replayable.
        d.dc_wake_i.value=32;await tick(d);d.dc_wake_i.value=0
        assert replay_ids(d)==[ids[0]]
        assert field(d,'capture',val(d.replay_o[0]),'va')==addr
        for _ in range(rng.randrange(1,5)):
            await tick(d);assert replay_ids(d)==[ids[0]]
        d.replay_ready_i[0].value=1;await tick(d);clear(d,INPUTS)
        d.update_valid_i[0].value=1;d.update_i[0].value=update(d,ids[0],gens[ids[0]],0,0)
        await tick(d);clear(d,INPUTS)
        assert val(d.executed_obs_o[ids[0]])
        d.release_count_i.value=2;await tick(d);clear(d,INPUTS)
        head=(head+2)%depth
        assert val(d.free_count_o)==depth


async def waiter(d,reason):
    await reset(d,INPUTS);ids=await allocate(d,[0]);idx=ids[0]
    d.capture_valid_i[0].value=1;d.capture_i[0].value=capture(d,idx,0x1234567890)
    await tick(d);clear(d,INPUTS)
    d.update_valid_i[0].value=1;d.update_i[0].value=update(d,idx,1,MISS if reason==MSHR else REPLAY,reason,2)
    await tick(d);clear(d,INPUTS)
    return idx


@cocotb.test()
async def lq_each_wait_reason_and_exact_event(d):
    for reason in (MSHR,FULL,WB,CONFLICT,SNAP,BANK,3,1,2,AD):
        idx=await waiter(d,reason)
        immediate=reason in (CONFLICT,SNAP,BANK)
        assert replay_ids(d)==([idx] if immediate else [])
        if immediate:continue
        # Wrong MSHR ID and unrelated resource/completion events cannot wake.
        d.dc_wake_i.value=32|8 # install{1}, not requested install{2}
        if reason==FULL:d.dc_wake_i.value=1 # WB free only
        if reason==WB:d.dc_wake_i.value=2 # MSHR free only
        for _ in range(5):
            await tick(d);assert not replay_ids(d),(reason,'unrelated wake')
        clear(d,INPUTS)
        if reason==MSHR:d.dc_wake_i.value=32|16
        elif reason==FULL:d.dc_wake_i.value=2
        elif reason==WB:d.dc_wake_i.value=1
        elif reason==3:d.tlb_wake_i.value=1
        elif reason in (1,2):d.sq_change_i.value=1
        elif reason==AD:d.ad_wake_i.value=1
        await tick(d);clear(d,INPUTS)
        assert replay_ids(d)==[idx]
        assert field(d,'capture',val(d.replay_o[0]),'va')==0x1234567890
        assert field(d,'capture',val(d.replay_o[0]),'uop.instruction_id')==42
        for _ in range(5):await tick(d);assert replay_ids(d)==[idx]
        d.replay_ready_i[0].value=1;await tick(d);clear(d,INPUTS)
        assert not replay_ids(d)


@cocotb.test()
async def lq_same_edge_wait_wake_two_replays_and_fault_va(d):
    await reset(d,INPUTS);ids=await allocate(d,[0,0])
    array(d.capture_valid_i,[1,1]);array(d.capture_i,[capture(d,0,0x1000),capture(d,1,0x2000)])
    await tick(d);clear(d,INPUTS)
    array(d.update_valid_i,[1,1]);array(d.update_i,[update(d,0,1,MISS,MSHR,2),update(d,1,1,REPLAY,WB)])
    d.dc_wake_i.value=32|16|4|1 # install{2}.err + WB free
    await tick(d);clear(d,INPUTS)
    assert replay_ids(d)==ids
    exc=field(d,'capture',val(d.replay_o[0]),'exc')
    assert exc>>70==1 and (exc>>64)&63==5 and exc&((1<<64)-1)==0x1000
    assert not field(d,'capture',val(d.replay_o[1]),'exc')
    array(d.replay_ready_i,[1,1]);await tick(d);clear(d,INPUTS)
    assert not replay_ids(d)


@cocotb.test()
async def lq_cancelled_load_ignores_late_wake_and_update(d):
    await reset(d,INPUTS);ids=await allocate(d,[1])
    d.capture_valid_i[0].value=1;d.capture_i[0].value=capture(d,0,0x3000,mask=1)
    await tick(d);clear(d,INPUTS)
    d.update_valid_i[0].value=1;d.update_i[0].value=update(d,0,1,MISS,MSHR,2)
    await tick(d);clear(d,INPUTS)
    d.resolution_valid_i.value=1;d.resolution_mispredict_i.value=1;d.resolution_tag_i.value=0;d.restore_tail_i.value=0
    d.dc_wake_i.value=32|16;await tick(d);clear(d,INPUTS)
    assert not replay_ids(d) and not val(d.live_obs_o[0])
    for _ in range(12):
        d.dc_wake_i.value=32|16|3
        d.update_valid_i[0].value=1;d.update_i[0].value=update(d,0,1)
        await tick(d);assert not replay_ids(d)
    clear(d,INPUTS);assert await allocate(d,[0])==[0]
    assert val(d.gen_obs_o[0])==2
    d.update_valid_i[0].value=1;d.update_i[0].value=update(d,0,1)
    await tick(d);assert not replay_ids(d) and not val(d.ready_obs_o[0])
