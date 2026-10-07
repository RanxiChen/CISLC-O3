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
    for group in range(depth//w):
        clear(d,INPUTS);d.alloc_ready_i.value=1
        for lane in range(w):
            d.alloc_req_i[lane].value=1;d.alloc_instruction_id_i[lane].value=group*w+lane+1
        await tick(d)
    clear(d,INPUTS);d.alloc_req_i[0].value=1;await settle()
    assert val(d.free_count_o)==0 and val(d.alloc_valid_o)==0
    assert not any(val(d.retire_valid_o[n]) for n in range(w))
    await reset(d,INPUTS)
    # Old ALU + JAL + cancelled young items. JAL gets ordinary WB on M itself.
    d.alloc_ready_i.value=1
    for n in range(w):
        d.alloc_req_i[n].value=1;d.alloc_instruction_id_i[n].value=n+1
        d.alloc_branch_mask_i[n].value=1 if n>=2 else 0
        d.alloc_new_dst_preg_i[n].value=32+n;d.alloc_rd_write_en_i[n].value=1
        d.alloc_ftq_slot_i[n].value=n
    await tick(d);clear(d,INPUTS)
    d.resolution_valid_i.value=1;d.resolution_mispredict_i.value=1
    d.resolution_tag_i.value=0;d.resolution_rob_idx_i.value=1;d.restore_tail_i.value=2
    d.complete_valid_i[0].value=1;d.complete_idx_i[0].value=0
    d.complete_valid_i[1].value=1;d.complete_idx_i[1].value=1
    await settle();assert not any(val(d.retire_valid_o[n]) for n in range(w))
    await tick(d);clear(d,INPUTS);await settle()
    assert val(d.tail_o)==2 and val(d.free_count_o)==depth-2
    assert [val(d.retire_valid_o[n]) for n in range(w)]==[1,1,0,0]
    assert [val(d.retire_instruction_id_o[n]) for n in range(2)]==[1,2]
    assert val(d.retire_new_dst_preg_o[1])==33 and val(d.retire_ftq_last_o[1])==1
    assert not any(val(d.mask_obs_o[n])&1 for n in range(2))
    await tick(d);await settle()
    assert not any(val(d.retire_valid_o[n]) for n in range(w)),'cancelled young FTQ notification'
    await reset(d,INPUTS);d.alloc_ready_i.value=1
    for n in range(w):
        d.alloc_req_i[n].value=1;d.alloc_exception_i[n].value=n==2
    await tick(d);clear(d,INPUTS)
    for n in range(w):d.complete_valid_i[n].value=1;d.complete_idx_i[n].value=n
    await tick(d);clear(d,INPUTS);await settle()
    assert [val(d.retire_valid_o[n]) for n in range(w)]==[1,1,0,0]
    await tick(d);await settle();assert not any(val(d.retire_valid_o[n]) for n in range(w))


@cocotb.test()
async def complete_dirty_store_blocks_retirement_prefix_until_final_probe(d):
    await reset(d,INPUTS);d.alloc_ready_i.value=1
    for n in range(3): d.alloc_req_i[n].value=1
    d.alloc_is_store_i[1].value=1
    await tick(d);clear(d,INPUTS)
    for n in range(3):d.complete_valid_i[n].value=1;d.complete_idx_i[n].value=n
    d.d_mark_i.value=1;d.d_idx_i.value=1
    await tick(d);clear(d,INPUTS);await settle()
    assert [val(d.retire_valid_o[n]) for n in range(4)]==[1,0,0,0]
    await tick(d);await settle()
    assert not any(val(d.retire_valid_o[n]) for n in range(4))
    d.d_clear_i.value=1;d.d_idx_i.value=1;await tick(d);clear(d,INPUTS);await settle()
    assert [val(d.retire_valid_o[n]) for n in range(4)]==[1,1,0,0]
