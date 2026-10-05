import os,random
import cocotb
from ports import INPUTS
from l3_contract import *

@cocotb.test()
async def four_lane_raw_waw_x0_self_snapshot_restore(d):
    seed=int(os.getenv('TEST_SEED','1'));rng=random.Random(seed)
    await reset(d,INPUTS);w=val(d.cfg_width_o);pregs=val(d.cfg_pregs_o);tags=val(d.cfg_tags_o)
    mapping=list(range(32));snap={}
    for cycle in range(650):
        clear(d,INPUTS)
        m=bool(snap) and cycle%17==0;t=rng.choice(list(snap)) if m else cycle%tags
        c=cycle%7==0 and not m
        d.resolution_valid_i.value=m or c;d.resolution_mispredict_i.value=m;d.resolution_tag_i.value=t
        n=0 if m else rng.randrange(w+1)
        d.rename_fire_i.value=n>0
        trial=list(mapping);expected=[];new_snaps={}
        for lane in range(w):
            rd=rng.randrange(7) if cycle>=4 else 1 # directed multi WAW chain
            rs1=1 if cycle<4 else rng.randrange(7);rs2=rng.randrange(7)
            write=bool(rng.randrange(3));src1=bool(rng.randrange(3));src2=bool(rng.randrange(3));valid=lane<n
            preg=32+(cycle*w+lane)%(pregs-32)
            for port,v in [('lane_valid_i',valid),('rs1_addr_i',rs1),('rs2_addr_i',rs2),('rd_addr_i',rd),('rd_write_en_i',write),('rs1_read_en_i',src1),('rs2_read_en_i',src2),('new_dst_preg_i',preg)]:getattr(d,port)[lane].value=v
            expected.append((trial[rs1] if valid and src1 and rs1 else 0,trial[rs2] if valid and src2 and rs2 else 0,trial[rd] if valid and write and rd else 0))
            if valid and write and rd:trial[rd]=preg
            create=valid and lane==cycle%w
            cp=(cycle+lane)%tags
            if c and cp==t:create=False # U2 prohibits same-tag create/release.
            d.checkpoint_create_i[lane].value=create;d.checkpoint_create_tag_i[lane].value=cp
            if create:new_snaps[cp]=list(trial)
        await settle()
        for lane,want in enumerate(expected):
            got=tuple(val(getattr(d,p)[lane]) for p in ['src1_preg_o','src2_preg_o','old_dst_preg_o'])
            assert got==want,(seed,cycle,lane,mapping,want,got)
        if m:mapping=list(snap[t])
        elif n:mapping=trial;snap.update(new_snaps)
        await tick(d)
        assert mapping[0]==0
