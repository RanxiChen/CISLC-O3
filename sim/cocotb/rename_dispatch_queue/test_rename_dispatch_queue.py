import os,random
import cocotb
from ports import INPUTS
from l3_contract import *

@cocotb.test()
async def four_wide_fifo_c_append_m_cancel_masks(d):
    seed=int(os.getenv('TEST_SEED','1'));rng=random.Random(seed)
    await reset(d,INPUTS);w=val(d.cfg_width_o);depth=val(d.cfg_depth_o)
    q=[];serial=0
    for cycle in range(600):
        clear(d,INPUTS)
        r=cycle%3==0;mis=r and cycle%9==0;t=cycle%val(d.cfg_tags_o)
        n=min(w,depth-len(q),rng.randrange(w+1)) if not mis else 0
        take=min(w,len(q),rng.randrange(w+1)) if not mis else 0
        new=[(serial+i,rng.getrandbits(val(d.cfg_tags_o))) for i in range(n)]
        bundle(d.enq_uop_i,[codec(d,'renamed_uop_t',valid=1,instruction_id=ident,branch_mask=mask) for ident,mask in new]+[0]*(w-n))
        d.enq_count_i.value=n;d.enq_fire_i.value=n>0;d.deq_accept_count_i.value=take
        d.resolution_valid_i.value=r;d.resolution_mispredict_i.value=mis;d.resolution_tag_i.value=t
        await settle()
        assert val(d.free_count_o)==depth-len(q),(seed,cycle,q)
        out=unbundle(d.deq_uop_o,w)
        count=min(w,len(q));assert val(d.deq_count_o)==count
        assert [(field(d,'renamed_uop_t',e,'instruction_id'),field(d,'renamed_uop_t',e,'branch_mask')) for e in out[:count]]==q[:count],(seed,cycle,q)
        q=([e for e in q if not(e[1]>>t&1)] if mis else q[take:]+new)
        if r:q=[(ident,mask&~(1<<t)) for ident,mask in q]
        serial+=n
        await tick(d)


@cocotb.test()
async def full_payload_reuse_with_multiple_writers_and_readers(d):
    seed=int(os.getenv('TEST_SEED','1'))+105;rng=random.Random(seed)
    await reset(d,INPUTS);w=val(d.cfg_width_o);depth=val(d.cfg_depth_o)
    bits=len(d.enq_uop_i)//w
    valid_mask=val(d.fmt_renamed_uop_t_valid);branch_mask=val(d.fmt_renamed_uop_t_branch_mask)
    shift=(branch_mask & -branch_mask).bit_length()-1
    q=[]
    for cycle in range(700):
        clear(d,INPUTS);reset_now=cycle in [181,503]
        resolve=cycle%4==0;mis=resolve and cycle%12==0;tag=cycle%val(d.cfg_tags_o)
        n=0 if mis or reset_now else min(w,depth-len(q),rng.randrange(w+1))
        take=0 if mis or reset_now else min(w,len(q),rng.randrange(w+1))
        new=[rng.getrandbits(bits)|valid_mask for _ in range(n)]
        bundle(d.enq_uop_i,new+[0]*(w-n))
        d.rst.value=reset_now;d.enq_count_i.value=n;d.enq_fire_i.value=n>0;d.deq_accept_count_i.value=take
        d.resolution_valid_i.value=resolve;d.resolution_mispredict_i.value=mis;d.resolution_tag_i.value=tag
        await settle()
        count=min(w,len(q))
        assert val(d.free_count_o)==depth-len(q),(seed,cycle,'free')
        assert val(d.deq_count_o)==count,(seed,cycle,'count')
        assert unbundle(d.deq_uop_o,w)[:count]==q[:count],(seed,cycle,'full payload')
        if reset_now:q=[]
        else:
            q=[raw for raw in q if not(raw & (1<<(shift+tag)))] if mis else q[take:]+new
            if resolve:q=[raw & ~(1<<(shift+tag)) for raw in q]
        await tick(d)
    d.rst.value=0


@cocotb.test()
async def full_width_head_publication_keeps_each_edge_and_survivor_payload(d):
    """Continuous full bundles, then mixed survivor/new heads and writer reuse."""
    rng=random.Random(405)
    await reset(d,INPUTS)
    w,depth=val(d.cfg_width_o),val(d.cfg_depth_o)
    bits=len(d.enq_uop_i)//w;valid_mask=val(d.fmt_renamed_uop_t_valid)
    q=[]
    async def edge(n,take):
        nonlocal q
        clear(d,INPUTS)
        assert n<=depth-len(q) and take<=min(w,len(q))
        new=[rng.getrandbits(bits)|valid_mask for _ in range(n)]
        bundle(d.enq_uop_i,new+[0]*(w-n))
        d.enq_count_i.value=n;d.enq_fire_i.value=n>0;d.deq_accept_count_i.value=take
        await settle()
        assert val(d.free_count_o)==depth-len(q)
        assert val(d.deq_count_o)==min(w,len(q))
        assert unbundle(d.deq_uop_o,w)[:min(w,len(q))]==q[:w]
        q=q[take:]+new
        await tick(d);await settle()
        assert val(d.deq_count_o)==min(w,len(q)), 'new head must be public at this edge'
        assert unbundle(d.deq_uop_o,w)[:min(w,len(q))]==q[:w], 'write/read collision or survivor payload'
    await edge(w,0)
    for _ in range(256):
        await edge(w,w)
        assert val(d.deq_count_o)==w, 'continuous full bundles must retain II1'
    for _ in range(10):await edge(0,0)
    if w>1:
        await edge(w-1,1)  # old survivors plus new heads across writer replicas
        await edge(min(w,depth-len(q)),w)
    while q:await edge(0,min(w,len(q)))
