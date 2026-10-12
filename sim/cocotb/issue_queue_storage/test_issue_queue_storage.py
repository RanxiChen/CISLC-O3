import os,random
import cocotb
from l3_contract import clear,reset,settle,tick,val,bundle,unbundle,codec

INPUTS=['clk','enq_uop_i','enq_fire_i','preg_ready_i','fp_preg_ready_i','fp_wakeup_valid_i','fp_wakeup_preg_i','fp_regread_ready_i','mul_ready_i','mul_pair_ready_i','div_ready_i','alu_buffer_ready_i','wakeup_valid_i','wakeup_preg_i','issue_ready_i','resolution_valid_i','resolution_mispredict_i','resolution_tag_i']

@cocotb.test()
async def full_payload_bank_reuse_and_independent_consume(d):
    seed=int(os.getenv('TEST_SEED','1'))+105;rng=random.Random(seed)
    await reset(d,INPUTS)
    width=val(d.cfg_width_o);issue=val(d.cfg_issue_o);depth=val(d.cfg_depth_o);alus=val(d.cfg_alu_o)
    bits=len(d.enq_uop_i)//width
    masks={name:val(getattr(d,'fmt_renamed_uop_t_'+name)) for name in ['valid','branch_mask','lo_mask','fuse_valid','fu_class','rs1_read_en','rs2_read_en','rs3_read_en']}
    branch_shift=(masks['branch_mask'] & -masks['branch_mask']).bit_length()-1
    lo_shift=(masks['lo_mask'] & -masks['lo_mask']).bit_length()-1
    fixed=codec(d,'renamed_uop_t',valid=1,fu_class=1)
    replace_mask=sum(masks[name] for name in ['valid','fuse_valid','fu_class','rs1_read_en','rs2_read_en','rs3_read_en'])
    q=[]
    for cycle in range(700):
        clear(d,INPUTS)
        d.alu_buffer_ready_i.value=(1<<alus)-1;d.fp_regread_ready_i.value=31
        d.mul_ready_i.value=1;d.mul_pair_ready_i.value=1;d.div_ready_i.value=1
        reset_now=cycle in [173,501]
        resolve=cycle%5==0;mis=resolve and cycle%15==0;tag=cycle%val(d.cfg_tags_o)
        incoming=0 if mis or reset_now else min(width,depth-len(q),rng.randrange(width+1))
        new=[(rng.getrandbits(bits)&~replace_mask)|fixed for _ in range(incoming)]
        bundle(d.enq_uop_i,new+[0]*(width-incoming));d.enq_fire_i.value=incoming>0
        ready=rng.getrandbits(issue);d.issue_ready_i.value=ready;d.rst.value=reset_now
        d.resolution_valid_i.value=resolve;d.resolution_mispredict_i.value=mis;d.resolution_tag_i.value=tag
        await settle()
        count=0 if mis else min(issue,alus,len(q));display=q[:count]
        clear_bits=(1<<(branch_shift+tag))|(1<<(lo_shift+tag))
        if resolve:display=[raw & ~clear_bits for raw in display]
        assert val(d.free_count_o)==depth-len(q),(seed,cycle,'free')
        assert val(d.issue_valid_o)==(1<<count)-1,(seed,cycle,'valid')
        assert unbundle(d.issue_uop_o,issue)[:count]==display,(seed,cycle,'full payload')
        if reset_now:q=[]
        elif mis:q=[raw for raw in q if not(raw&(1<<(branch_shift+tag)))]
        else:q=[raw for port,raw in enumerate(q) if port>=count or not(ready&(1<<port))]+new
        if resolve:q=[raw & ~clear_bits for raw in q]
        await tick(d)
    d.rst.value=0

@cocotb.test()
async def mixed_alu_mul_div_oldest_available_with_partial_acceptance(d):
    seed=int(os.getenv('TEST_SEED','1'))+205;rng=random.Random(seed)
    await reset(d,INPUTS)
    width=val(d.cfg_width_o);issue=val(d.cfg_issue_o);depth=val(d.cfg_depth_o);alus=val(d.cfg_alu_o)
    bits=len(d.enq_uop_i)//width
    names=['valid','branch_mask','lo_mask','fuse_valid','fu_class','rs1_read_en','rs2_read_en','rs3_read_en']
    masks={n:val(getattr(d,'fmt_renamed_uop_t_'+n)) for n in names}
    branch_shift=(masks['branch_mask'] & -masks['branch_mask']).bit_length()-1
    lo_shift=(masks['lo_mask'] & -masks['lo_mask']).bit_length()-1
    fixed_mask=sum(masks[n] for n in ['valid','fuse_valid','fu_class','rs1_read_en','rs2_read_en','rs3_read_en'])
    q=[]
    for cycle in range(900):
        clear(d,INPUTS)
        alu_ready=rng.getrandbits(alus);mul_ready=rng.randrange(2);pair_ready=rng.randrange(2);div_ready=rng.randrange(2)
        d.alu_buffer_ready_i.value=alu_ready;d.mul_ready_i.value=mul_ready
        d.mul_pair_ready_i.value=pair_ready;d.div_ready_i.value=div_ready
        reset_now=cycle in [211,707]
        resolve=cycle%7==0;mis=resolve and cycle%21==0;tag=cycle%val(d.cfg_tags_o)
        incoming=0 if mis or reset_now else min(width,depth-len(q),rng.randrange(width+1))
        new=[]
        for _ in range(incoming):
            cls=rng.choice([1,1,3,4]);fused=int(cls==3 and rng.randrange(2))
            raw=(rng.getrandbits(bits)&~fixed_mask)|codec(d,'renamed_uop_t',valid=1,fu_class=cls,fuse_valid=fused)
            new.append((raw,cls,fused))
        bundle(d.enq_uop_i,[x[0] for x in new]+[0]*(width-incoming));d.enq_fire_i.value=incoming>0
        ready=rng.getrandbits(issue);d.issue_ready_i.value=ready;d.rst.value=reset_now
        d.resolution_valid_i.value=resolve;d.resolution_mispredict_i.value=mis;d.resolution_tag_i.value=tag
        chosen=[];alu_left=alu_ready.bit_count();mul_used=div_used=False
        if not mis:
            for index,(_,cls,fused) in enumerate(q):
                if len(chosen)==issue:break
                if cls==3:
                    if mul_used or not(pair_ready if fused else mul_ready):continue
                    mul_used=True
                elif cls==4:
                    if div_used or not div_ready:continue
                    div_used=True
                else:
                    if not alu_left:continue
                    alu_left-=1
                chosen.append(index)
        clear_bits=(1<<(branch_shift+tag))|(1<<(lo_shift+tag))
        want=[q[i][0] & ~clear_bits if resolve else q[i][0] for i in chosen]
        await settle()
        assert val(d.free_count_o)==depth-len(q),(seed,cycle,'mixed free')
        assert val(d.issue_valid_o)==(1<<len(chosen))-1,(seed,cycle,'mixed valid')
        assert unbundle(d.issue_uop_o,issue)[:len(chosen)]==want,(seed,cycle,'oldest eligible whole payload')
        available_alus=[fu for fu in range(alus) if alu_ready&(1<<fu)]
        expected_routes=[]
        for index in chosen:
            cls=q[index][1]
            expected_routes.append(alus if cls==3 else alus+1 if cls==4 else available_alus.pop(0))
        assert [val(d.issue_int_fu_o[p]) for p in range(len(chosen))]==expected_routes,(seed,cycle,'oldest FU assignment')
        if reset_now:q=[]
        elif mis:q=[x for x in q if not(x[0]&(1<<(branch_shift+tag)))]
        else:
            consumed={index for port,index in enumerate(chosen) if ready&(1<<port)}
            q=[x for index,x in enumerate(q) if index not in consumed]+new
        if resolve:q=[(raw & ~clear_bits,cls,fused) for raw,cls,fused in q]
        await tick(d)
    d.rst.value=0


@cocotb.test()
async def domain_qualified_broadcasts_latch_without_same_cycle_select(d):
    from l3_contract import array
    rng=random.Random(int(os.getenv('TEST_SEED','1'))+305)
    await reset(d,INPUTS)
    width=val(d.cfg_width_o);alus=val(d.cfg_alu_o)
    def wave(force=False):
        ir=[rng.randrange(2) if force else int(rng.randrange(7)==0) for _ in d.preg_ready_i]
        fr=[rng.randrange(2) if force else int(rng.randrange(7)==0) for _ in d.fp_preg_ready_i]
        iv=[int(rng.randrange(3)==0) for _ in d.wakeup_valid_i]
        fv=[int(rng.randrange(3)==0) for _ in d.fp_wakeup_valid_i]
        ip=[rng.randrange(len(ir)) for _ in iv];fp=[rng.randrange(len(fr)) for _ in fv]
        if force:ir=[1]*len(ir);fr=[1]*len(fr)
        array(d.preg_ready_i,ir);array(d.fp_preg_ready_i,fr)
        array(d.wakeup_valid_i,iv);array(d.wakeup_preg_i,ip)
        array(d.fp_wakeup_valid_i,fv);array(d.fp_wakeup_preg_i,fp)
        def ready(domain,preg):
            if domain==0:return True
            values,valids,pregs=(ir,iv,ip) if domain==1 else (fr,fv,fp)
            return bool(values[preg] or any(v and p==preg for v,p in zip(valids,pregs)))
        return ready
    for batch in range(160):
        clear(d,INPUTS);d.alu_buffer_ready_i.value=(1<<alus)-1
        domains=[rng.randrange(3) for _ in range(3)];pregs=[rng.randrange(len(d.preg_ready_i)) for _ in range(3)]
        reads=[rng.randrange(2) for _ in range(3)]
        raw=codec(d,'renamed_uop_t',valid=1,fu_class=1,rs1_read_en=reads[0],rs2_read_en=reads[1],rs3_read_en=reads[2],
                  rs1_dom=domains[0],rs2_dom=domains[1],rs3_dom=domains[2],src1_preg=pregs[0],src2_preg=pregs[1],src3_preg=pregs[2])
        lookup=wave();cached=[not read or lookup(dom,preg) for read,dom,preg in zip(reads,domains,pregs)]
        bundle(d.enq_uop_i,[raw]+[0]*(width-1));d.enq_fire_i.value=1
        await tick(d);d.enq_fire_i.value=0
        for cycle in range(8):
            lookup=wave(cycle==6)
            await settle()
            assert val(d.issue_valid_o)==int(all(cached)),(batch,cycle,domains,pregs,cached)
            if all(cached):assert unbundle(d.issue_uop_o,val(d.cfg_issue_o))[0]==raw
            cached=[was or not read or lookup(dom,preg) for was,read,dom,preg in zip(cached,reads,domains,pregs)]
            await tick(d)
        assert all(cached)
        d.issue_ready_i.value=1;await tick(d)
        assert val(d.free_count_o)==val(d.cfg_depth_o)


@cocotb.test()
async def continuous_full_width_reclaim_and_row_reuse(d):
    """The original public FIFO oracle must hold during registered row reuse."""
    rng=random.Random(int(os.getenv('TEST_SEED','1'))+405)
    await reset(d,INPUTS)
    width=val(d.cfg_width_o);issue=val(d.cfg_issue_o);depth=val(d.cfg_depth_o)
    alus=val(d.cfg_alu_o);bits=len(d.enq_uop_i)//width
    names=['valid','branch_mask','lo_mask','fuse_valid','fu_class',
           'rs1_read_en','rs2_read_en','rs3_read_en']
    masks={n:val(getattr(d,'fmt_renamed_uop_t_'+n)) for n in names}
    fixed_mask=sum(masks.values())
    classes=[1]*alus+[3,4]
    n=min(width,issue,len(classes));q=[];full=0
    for cycle in range(196):
        clear(d,INPUTS)
        d.alu_buffer_ready_i.value=(1<<alus)-1
        d.mul_ready_i.value=1;d.mul_pair_ready_i.value=1;d.div_ready_i.value=1
        d.issue_ready_i.value=(1<<issue)-1
        new=[]
        if cycle<192:
            for cls in classes[:n]:
                raw=(rng.getrandbits(bits)&~fixed_mask)|codec(
                    d,'renamed_uop_t',valid=1,fu_class=cls)
                new.append(raw)
        bundle(d.enq_uop_i,new+[0]*(width-len(new)))
        d.enq_fire_i.value=bool(new)
        await settle()
        count=min(n,len(q))
        assert val(d.free_count_o)==depth-len(q),(cycle,'registered credit')
        assert val(d.issue_valid_o)==(1<<count)-1,(cycle,'continuous issue')
        assert unbundle(d.issue_uop_o,issue)[:count]==q[:count],(cycle,'row identity')
        if count==len(new)==n:full+=1
        q=q[count:]+new
        await tick(d)
    assert full==191 and not q
    assert val(d.free_count_o)==depth
