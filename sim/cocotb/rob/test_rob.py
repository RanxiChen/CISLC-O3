import os,random
import cocotb
from ports import INPUTS
from l3_contract import *

async def run_four_wide_model(d, correct=False):
    seed=int(os.getenv('TEST_SEED','1'));rng=random.Random(seed)
    await reset(d,INPUTS);w=val(d.cfg_width_o);depth=val(d.cfg_depth_o)
    q=[];head=tail=0;serial=1;wraps=0;multi_regions=0
    for cycle in range(600):
        clear(d,INPUTS)
        d.resolution_valid_i.value=correct and cycle%3==0
        d.resolution_tag_i.value=cycle%val(d.cfg_tags_o)
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
                ftq=codec(d,'ftq_id_t',idx=ident%val(d.cfg_ftq_o),gen=(ident//val(d.cfg_ftq_o))%val(d.cfg_ftq_gens_o))
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
        got=[val(d.retire_valid_o[lane]) for lane in range(w)]
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


@cocotb.test()
async def four_wide_allocate_complete_retire_ftq_wrap(d):
    await run_four_wide_model(d)

@cocotb.test()
async def rob_c_retire_allocate_complete_are_independent(d):
    await run_four_wide_model(d, correct=True)

@cocotb.test()
async def rob_full_exception_prefix_and_m_jal_completion_cancel_ftq(d):
    await reset(d,INPUTS);w=val(d.cfg_width_o);depth=val(d.cfg_depth_o)
    # Full means no allocation even if a request arrives, and no uncompleted retirement.
    for start in range(0,depth,w):
        clear(d,INPUTS);d.alloc_ready_i.value=1
        for lane in range(min(w,depth-start)):
            d.alloc_req_i[lane].value=1;d.alloc_instruction_id_i[lane].value=start+lane+1
        await tick(d)
    clear(d,INPUTS);d.alloc_req_i[0].value=1;await settle()
    assert val(d.free_count_o)==0 and val(d.alloc_valid_o)==0
    assert not any(val(d.retire_valid_o[n]) for n in range(w))
    await reset(d,INPUTS)
    # Old ALU + JAL + cancelled young items. JAL gets ordinary WB on M itself.
    for start in range(0,4,w):
        clear(d,INPUTS);d.alloc_ready_i.value=1
        for lane in range(min(w,4-start)):
            n=start+lane;d.alloc_req_i[lane].value=1;d.alloc_instruction_id_i[lane].value=n+1
            d.alloc_branch_mask_i[lane].value=1 if n>=2 else 0
            d.alloc_new_dst_preg_i[lane].value=32+n;d.alloc_rd_write_en_i[lane].value=1
            d.alloc_ftq_slot_i[lane].value=n
        await tick(d)
    clear(d,INPUTS)
    d.resolution_valid_i.value=1;d.resolution_mispredict_i.value=1
    d.resolution_tag_i.value=0;d.resolution_rob_idx_i.value=1;d.restore_tail_i.value=2
    d.complete_valid_i[0].value=1;d.complete_idx_i[0].value=0
    d.complete_valid_i[1].value=1;d.complete_idx_i[1].value=1
    await settle();assert not any(val(d.retire_valid_o[n]) for n in range(w))
    await tick(d);clear(d,INPUTS);await settle()
    assert val(d.tail_o)==2 and val(d.free_count_o)==depth-2
    assert [val(d.retire_valid_o[n]) for n in range(w)]==[1,1]+[0]*(w-2)
    assert [val(d.retire_instruction_id_o[n]) for n in range(2)]==[1,2]
    assert val(d.retire_new_dst_preg_o[1])==33 and val(d.retire_ftq_last_o[1])==1
    assert not any(val(d.mask_obs_o[n])&1 for n in range(2))
    await tick(d);await settle()
    assert not any(val(d.retire_valid_o[n]) for n in range(w)),'cancelled young FTQ notification'
    await reset(d,INPUTS)
    for start in range(0,4,w):
        clear(d,INPUTS);d.alloc_ready_i.value=1
        for lane in range(min(w,4-start)):
            n=start+lane;d.alloc_req_i[lane].value=1;d.alloc_exception_i[lane].value=n==2
        await tick(d)
    clear(d,INPUTS)
    for n in range(4):d.complete_valid_i[n].value=1;d.complete_idx_i[n].value=n
    await tick(d);clear(d,INPUTS);await settle()
    assert [val(d.retire_valid_o[n]) for n in range(w)]==[1,1]+[0]*(w-2)
    await tick(d);await settle();assert not any(val(d.retire_valid_o[n]) for n in range(w))


@cocotb.test()
async def complete_dirty_store_blocks_retirement_prefix_until_final_probe(d):
    await reset(d,INPUTS);w=val(d.cfg_width_o);d.alloc_ready_i.value=1
    for n in range(3): d.alloc_req_i[n].value=1
    d.alloc_is_store_i[1].value=1
    await tick(d);clear(d,INPUTS)
    for n in range(3):d.complete_valid_i[n].value=1;d.complete_idx_i[n].value=n
    d.d_mark_i.value=1;d.d_idx_i.value=1
    await tick(d);clear(d,INPUTS);await settle()
    assert [val(d.retire_valid_o[n]) for n in range(w)]==[1]+[0]*(w-1)
    await tick(d);await settle()
    assert not any(val(d.retire_valid_o[n]) for n in range(w))
    d.d_clear_i.value=1;d.d_idx_i.value=1;await tick(d);clear(d,INPUTS);await settle()
    assert [val(d.retire_valid_o[n]) for n in range(w)]==[1,1]+[0]*(w-2)


@cocotb.test()
async def allocation_and_late_exception_successor_priority_and_reuse(d):
    seed=int(os.getenv('TEST_SEED','1'))+105;rng=random.Random(seed)
    await reset(d,INPUTS);w=val(d.cfg_width_o)
    def exc(valid):
        return codec(d,'exc_info_t',valid=valid,cause=rng.randrange(18),tval=rng.getrandbits(64))
    async def observe(pcs,succs,exceptions):
        await settle()
        assert [val(d.meta_pc_o[p]) for p in range(w)]==pcs
        assert [val(d.meta_succ_o[p]) for p in range(w)]==succs
        assert [val(d.meta_exc_o[p]) for p in range(w)]==exceptions
    # Flush reuses old physical rows without resetting data. Initial state and
    # allocation vs simultaneous late updates must keep the original priority.
    for batch in range(80):
        clear(d,INPUTS);d.commit_block_i.value=1
        if batch%17==0:
            d.rst.value=1;await tick(d);d.rst.value=0
            await observe([0]*w,[0]*w,[0]*w)
        else:d.t_flush_all_i.value=1;await tick(d);d.t_flush_all_i.value=0
        pcs=[rng.getrandbits(64) for _ in range(w)];lengths=[rng.choice([2,4]) for _ in range(w)]
        successors=[(pc+length)&((1<<64)-1) for pc,length in zip(pcs,lengths)]
        exceptions=[exc(int(batch%3==0 and p==0)) for p in range(w)]
        d.meta_mode_i.value=1;array(d.meta_alloc_pc_i,pcs);array(d.meta_alloc_len_i,lengths)
        array(d.t_alloc_exc_i,exceptions);array(d.alloc_exception_i,[field(d,'exc_info_t',x,'valid') for x in exceptions])
        array(d.alloc_req_i,[1]*w);d.alloc_ready_i.value=1
        idx=batch%w;other=(idx+1)%w
        if batch%2==0:
            exceptions[idx]=exc(1);successors[other]=rng.getrandbits(64)
            d.t_exc_valid_i.value=1;d.t_exc_idx_i.value=idx;d.t_exc_i.value=exceptions[idx]
            d.succ_valid_i.value=1;d.resolution_rob_idx_i.value=other;d.succ_pc_i.value=successors[other]
        await tick(d);clear(d,INPUTS);d.meta_mode_i.value=1;d.commit_block_i.value=1
        await tick(d)  # R3 publishes the accepted allocation payload.
        await observe(pcs,successors,exceptions)
        for delay in range(3):
            idx=(batch+delay)%w;exceptions[idx]=exc(1);successors[idx]=rng.getrandbits(64)
            d.t_exc_valid_i.value=1;d.t_exc_idx_i.value=idx;d.t_exc_i.value=exceptions[idx]
            d.succ_valid_i.value=1;d.resolution_rob_idx_i.value=idx;d.succ_pc_i.value=successors[idx]
            await tick(d);d.t_exc_valid_i.value=0;d.succ_valid_i.value=0
            await observe(pcs,successors,exceptions)
    # Complete/retire real consecutive groups through many physical wraps;
    # each new allocation must discard the prior row's late successor selector.
    clear(d,INPUTS);d.t_flush_all_i.value=1;await tick(d)
    for batch in range(80):
        clear(d,INPUTS);d.meta_mode_i.value=1;d.commit_block_i.value=1
        pcs=[rng.getrandbits(64) for _ in range(w)];lengths=[rng.choice([2,4]) for _ in range(w)]
        successors=[(pc+length)&((1<<64)-1) for pc,length in zip(pcs,lengths)];exceptions=[exc(0) for _ in range(w)]
        array(d.meta_alloc_pc_i,pcs);array(d.meta_alloc_len_i,lengths);array(d.t_alloc_exc_i,exceptions)
        array(d.alloc_req_i,[1]*w);d.alloc_ready_i.value=1;await settle()
        ids=[val(d.alloc_idx_o[p]) for p in range(w)]
        await tick(d);clear(d,INPUTS);d.meta_mode_i.value=1;d.commit_block_i.value=1
        await tick(d)  # R3 publishes the accepted allocation payload.
        await observe(pcs,successors,exceptions)
        selected=batch%w;successors[selected]=rng.getrandbits(64)
        d.succ_valid_i.value=1;d.resolution_rob_idx_i.value=ids[selected];d.succ_pc_i.value=successors[selected]
        for p,idx in enumerate(ids):d.complete_valid_i[p].value=1;d.complete_idx_i[p].value=idx
        await tick(d);clear(d,INPUTS);d.commit_block_i.value=0
        await observe(pcs,successors,exceptions)
        assert [val(d.retire_valid_o[p]) for p in range(w)]==[1]*w
        await tick(d);assert val(d.free_count_o)==val(d.cfg_depth_o)


@cocotb.test()
async def narrow_head_serial_predecode_tracks_reuse_and_retirement(d):
    rng=random.Random(int(os.getenv('TEST_SEED','1'))+107)
    await reset(d,INPUTS);w=val(d.cfg_width_o)
    # Independent expected predicates, not a copy of the storage selection.
    # One retirement at a time exercises each physical row/head bank.
    for batch in range(160):
        clear(d,INPUTS);d.commit_block_i.value=1
        if batch%23==0:
            d.rst.value=1;await tick(d);d.rst.value=0
        elif batch%11==0:
            d.t_flush_all_i.value=1;await tick(d);d.t_flush_all_i.value=0
        ops=[rng.randrange(4) for _ in range(w)]
        systems=[rng.choice([0,6,7,8]) for _ in range(w)]
        array(d.t_alloc_ext_i,[codec(d,'uop_ext_t',csr_op=c,sys_op=s) for c,s in zip(ops,systems)])
        array(d.alloc_req_i,[1]*w);d.alloc_ready_i.value=1
        await settle();ids=[val(d.alloc_idx_o[p]) for p in range(w)]
        await tick(d);clear(d,INPUTS);d.commit_block_i.value=1
        await settle();assert val(d.t_head_valid_o)==0,'R2 metadata not yet published'
        await tick(d)
        for lane in range(w):
            await settle()
            assert val(d.t_head_valid_o)==1
            assert val(d.t_head_csr_o)==int(ops[lane]!=0),(batch,lane,ops)
            assert val(d.t_head_sfence_o)==int(systems[lane]==8),(batch,lane,systems)
            d.complete_valid_i[0].value=1;d.complete_idx_i[0].value=ids[lane]
            await tick(d);clear(d,INPUTS);await settle()
            assert val(d.retire_valid_o[0])==1
            assert not any(val(d.retire_valid_o[p]) for p in range(1,w))
            await tick(d);clear(d,INPUTS);d.commit_block_i.value=1
        assert val(d.free_count_o)==val(d.cfg_depth_o)


@cocotb.test()
async def publication_overlaps_full_width_and_cancels_without_reused_payload(d):
    await reset(d,INPUTS);w=val(d.cfg_width_o);depth=val(d.cfg_depth_o)
    q=[];tail=0;serial=1;full_steady=0
    for cycle in range(260):
        clear(d,INPUTS)
        ready=[]
        for entry in q[:w]:
            if cycle<entry['born']+2:break
            ready.append(entry)
        n=w if cycle<96 else (cycle% (w+1) if cycle<240 else 0)
        n=min(n,depth-len(q))
        d.alloc_ready_i.value=n>0
        for lane in range(n):
            d.alloc_req_i[lane].value=1;d.alloc_instruction_id_i[lane].value=serial+lane
            d.alloc_old_dst_preg_i[lane].value=(serial+lane)%64
        await settle()
        ids=[val(d.alloc_idx_o[lane]) for lane in range(n)]
        for lane,idx in enumerate(ids):
            d.complete_valid_i[lane].value=1;d.complete_idx_i[lane].value=idx
        await settle()
        assert [val(d.retire_valid_o[lane]) for lane in range(w)]==[int(lane<len(ready)) for lane in range(w)],cycle
        for lane,entry in enumerate(ready):
            assert val(d.retire_instruction_id_o[lane])==entry['id'],(cycle,lane,'publication owner')
            assert val(d.retire_old_dst_preg_o[lane])==entry['id']%64,(cycle,lane,'publication preg')
        assert val(d.free_count_o)==depth-len(q),cycle
        if 2<=cycle<96:
            assert n==w and len(ready)==w,(cycle,'publication throughput')
            full_steady+=1
        q=q[len(ready):]+[dict(id=serial+lane,born=cycle,idx=idx) for lane,idx in enumerate(ids)]
        serial+=n;tail=(tail+n)%depth
        await tick(d)
    assert full_steady==94 and not q
    # A pending publication is killed on its write edge. Its RAM contents may
    # change, but its ownership never becomes visible to head/retirement.
    for kill_global in (False,True):
        await reset(d,INPUTS);d.commit_block_i.value=1
        d.alloc_ready_i.value=1
        for lane in range(w):
            d.alloc_req_i[lane].value=1;d.alloc_instruction_id_i[lane].value=900+lane
            d.alloc_branch_mask_i[lane].value=int(lane>0)
        await tick(d);clear(d,INPUTS);d.commit_block_i.value=1
        await settle();assert val(d.t_head_valid_o)==0
        if kill_global:d.t_flush_all_i.value=1
        else:
            d.resolution_valid_i.value=1;d.resolution_mispredict_i.value=1
            d.resolution_tag_i.value=0;d.resolution_rob_idx_i.value=0;d.restore_tail_i.value=1
            d.complete_valid_i[0].value=1;d.complete_idx_i[0].value=0
        await tick(d);clear(d,INPUTS);d.commit_block_i.value=1;await settle()
        if kill_global:
            assert val(d.t_head_valid_o)==0 and val(d.free_count_o)==depth
        else:
            assert val(d.t_head_valid_o)==1 and val(d.free_count_o)==depth-1
            assert val(d.retire_instruction_id_o[0])==900
            d.commit_block_i.value=0;await tick(d);clear(d,INPUTS);d.commit_block_i.value=1
        d.alloc_ready_i.value=1;d.alloc_req_i[0].value=1
        d.alloc_instruction_id_i[0].value=12345;d.alloc_old_dst_preg_i[0].value=63
        await tick(d);clear(d,INPUTS);d.commit_block_i.value=1;await settle()
        assert val(d.t_head_valid_o)==0,'reused row exposed old metadata before publication'
        await tick(d);await settle()
        assert val(d.t_head_valid_o)==1 and val(d.retire_instruction_id_o[0])==12345
        assert val(d.retire_old_dst_preg_o[0])==63
