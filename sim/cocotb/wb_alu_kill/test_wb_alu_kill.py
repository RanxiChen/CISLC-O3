import os,random
import cocotb
from l3_contract import *

@cocotb.test()
async def actual_shared_arbiter_holds_old_result_and_kills_young_regread(d):
    seed=int(os.getenv('TEST_SEED','1'));rng=random.Random(seed)
    names=['clk','grant_i','rob0_i','rob1_i','mask0_i','mask1_i','branch_send_i','resolution_i','tag_i']
    await reset(d,names);tags=val(d.cfg_tags_o)
    for case in range(tags*4):
        await reset(d,names);tag=case%tags
        # Two real ALUs issue old results in parallel.
        d.grant_i.value=3;d.rob0_i.value=3;d.rob1_i.value=1
        await tick(d)
        # Both Result slots appear with a valid young RegRead behind ALU0.
        d.grant_i.value=1;d.rob0_i.value=4;d.mask0_i.value=1<<tag;d.branch_send_i.value=1
        await tick(d)
        d.grant_i.value=0;d.branch_send_i.value=0
        await settle()
        assert val(d.result_valid_o)==1 and val(d.result_rob_o)==3
        assert val(d.rr_valid_o)==1 and val(d.old_consume_o)==0,(seed,case,'real WB backpressure missing')
        d.resolution_i.value=1;d.tag_i.value=tag
        await settle()
        assert all(not val(d.complete_valid_o[n]) or val(d.complete_idx_o[n])!=4 for n in range(4))
        await tick(d)
        assert val(d.rr_valid_o)==0
        assert val(d.result_valid_o)==1 and val(d.result_rob_o)==3,(seed,case,'old result lost')
        d.resolution_i.value=0
        for delay in range(rng.randrange(2,6)):
            await settle()
            assert all(not val(d.complete_valid_o[n]) or val(d.complete_idx_o[n])!=4 for n in range(4)),(seed,case,delay,'young completion escaped')
            await tick(d)
        assert val(d.result_valid_o)==0
