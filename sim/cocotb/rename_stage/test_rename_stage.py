import os,random
import cocotb
from ports import INPUTS
from l3_contract import *

@cocotb.test()
async def atomic_four_lane_resource_prefix_mixed_types(d):
    seed=int(os.getenv('TEST_SEED','1'));rng=random.Random(seed)
    clear(d,INPUTS);await settle();w=val(d.cfg_width_o)
    for cycle in range(900):
        clear(d,INPUTS)
        visible=w if cycle<40 else rng.randrange(w+1)
        block=cycle%19==0
        caps=[rng.randrange(w+2) for _ in range(5)]
        if cycle<40:caps=[w]*5;caps[(cycle//w)%5]=cycle%w
        for name,v in zip(['preg','rob','lq','sq','rdq'],caps):getattr(d,name+'_free_count_i').value=v
        mask=rng.getrandbits(val(d.cfg_tags_o));d.active_branch_mask_i.value=mask
        d.visible_count_i.value=visible;d.recovery_block_i.value=block
        items=[];description=[];cp_grant=[]
        for lane in range(w):
            typ=rng.randrange(4);rd=rng.randrange(6);write=bool(rng.randrange(2));cp=typ==3
            e=dict(valid=int(lane<visible),instruction_id=cycle*w+lane,rd=rd,rd_write_en=int(write),is_load=int(typ==1),is_store=int(typ==2),needs_checkpoint=int(cp))
            description.append(e);items.append(codec(d,'decoded_uop_t',**e))
            grant=bool(rng.randrange(4));cp_grant.append(grant);d.checkpoint_grant_i[lane].value=grant;d.checkpoint_tag_i[lane].value=lane
            d.new_dst_preg_i[lane].value=32+lane;d.src1_preg_i[lane].value=lane+1
            d.src2_preg_i[lane].value=lane+2;d.rob_idx_i[lane].value=lane
        bundle(d.decoded_i,items);await settle()
        accepted=[];left=list(caps);running=mask
        for lane,e in enumerate(description):
            need=[int(e['rd_write_en'] and e['rd']!=0),1,e['is_load'],e['is_store'],1]
            can=not block and lane<visible and all(c>=n for c,n in zip(left,need)) and (not e['needs_checkpoint'] or cp_grant[lane])
            assert val(d.lane_branch_mask_o[lane])==running,(seed,cycle,lane,running)
            if can:
                accepted.append(lane);left=[c-n for c,n in zip(left,need)]
                if e['needs_checkpoint']:running|=1<<lane
            else:block=True
            assert val(d.lane_accept_o[lane])==can,(seed,cycle,lane,caps,e)
            for port,n in [('dst_alloc_req_o',need[0]),('rob_alloc_req_o',1),('lq_alloc_req_o',need[2]),('sq_alloc_req_o',need[3]),('checkpoint_create_o',e['needs_checkpoint'])]:
                assert val(getattr(d,port)[lane])==int(can and n),(seed,cycle,lane,port)
        assert val(d.accept_count_o)==len(accepted),(seed,cycle,caps,description)
        result=unbundle(d.renamed_uop_o,w)
        for lane in accepted:
            assert field(d,'renamed_uop_t',result[lane],'valid')==1
            assert field(d,'renamed_uop_t',result[lane],'instruction_id')==cycle*w+lane

@cocotb.test()
async def mixed_domains_fusion_and_visible_holes(d):
    """Independent legacy budget oracle for parallel demand comparisons."""
    seed=int(os.getenv('TEST_SEED','1'));rng=random.Random(seed)
    w=val(d.cfg_width_o)
    for cycle in range(512):
        clear(d,INPUTS)
        visible=rng.randrange(w+1);blocked=bool(cycle%23==0)
        caps=[rng.randrange(w+2) for _ in range(6)]
        for name,n in zip(('preg','fp_preg','rob','lq','sq','rdq'),caps):
            getattr(d,name+'_free_count_i').value=n
        d.visible_count_i.value=visible;d.recovery_block_i.value=int(blocked)
        active=rng.getrandbits(val(d.cfg_tags_o));d.active_branch_mask_i.value=active
        rows=[];items=[]
        for lane in range(w):
            row=dict(valid=rng.randrange(2),rd_write_en=rng.randrange(2),rd=rng.randrange(4),
                     is_load=rng.randrange(2),is_store=rng.randrange(2),needs_checkpoint=rng.randrange(2))
            row['fp']=rng.randrange(2);row['role']=rng.randrange(3);row['grant']=rng.randrange(2)
            d.checkpoint_grant_i[lane].value=row['grant'];d.checkpoint_tag_i[lane].value=lane
            rows.append(row)
            items.append(codec(d,'decoded_uop_t',**{k:row[k] for k in
                ('valid','rd_write_en','rd','is_load','is_store','needs_checkpoint')},
                **{'ext.rd_dom':2 if row['fp'] else 1,'ext.fuse_role':row['role']}))
        bundle(d.decoded_i,items);await settle()
        remaining=caps.copy();running=active;accepted=0
        for lane,row in enumerate(rows):
            need=row['valid'] and row['rd_write_en'] and(row['fp'] or row['rd']!=0)
            domain=int(row['fp'])
            take=bool(not blocked and lane<visible and row['valid'] and
                remaining[2]>0 and remaining[5]>0 and(not need or remaining[domain]>0) and
                (not(row['valid'] and row['is_load']) or remaining[3]>0) and
                (not(row['valid'] and row['is_store']) or remaining[4]>0) and
                (not(row['valid'] and row['needs_checkpoint']) or row['grant']))
            if row['role']==1:
                if lane+1==w:take=False
                else:
                    nxt=rows[lane+1]
                    take=bool(take and lane+1<visible and nxt['valid'] and nxt['role']==2 and
                        remaining[2]>=2 and remaining[5]>=2 and
                        remaining[0]>=int(need)+int(nxt['rd_write_en'] and nxt['rd']!=0))
            assert val(d.lane_branch_mask_o[lane])==running,(seed,cycle,lane,'branch prefix')
            assert val(d.lane_accept_o[lane])==take,(seed,cycle,lane,caps,rows)
            for port,required in [('dst_alloc_req_o',need),('rob_alloc_req_o',True),
                ('lq_alloc_req_o',row['valid'] and row['is_load']),
                ('sq_alloc_req_o',row['valid'] and row['is_store']),
                ('checkpoint_create_o',row['valid'] and row['needs_checkpoint'])]:
                assert val(getattr(d,port)[lane])==int(take and required),(seed,cycle,lane,port)
            if take:
                accepted+=1;remaining[2]-=1;remaining[5]-=1
                if need:remaining[domain]-=1
                remaining[3]-=int(row['is_load']);remaining[4]-=int(row['is_store'])
                if row['needs_checkpoint']:running|=1<<lane
            elif lane<visible and row['valid']:blocked=True
        assert val(d.accept_count_o)==accepted,(seed,cycle,caps,rows)
