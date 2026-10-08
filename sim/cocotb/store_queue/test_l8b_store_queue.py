import cocotb
from l3_contract import tick,settle,val,clear

@cocotb.test()
async def special_entries_block_then_wake_and_release_without_drain(d):
    inputs=['clk','flush_all_i','kind_i','heu_done_i','heu_done_idx_i','rob_head_i','alloc_valid','alloc_rob','execute_valid','execute_idx','execute_addr','execute_data','execute_mask','query_valid','query_rob','query_addr','query_mask','commit_valid','commit_idx','dc_req_ready','dc_resp_valid','dc_resp_idx','local_drain_ready','multi_mode_i','multi_alloc_count_i','multi_commit_count_i','resolution_valid_i','resolution_mispredict_i','resolution_tag_i','restore_tail_i','execute1_valid','query1_valid','dc_retry','dc_reason','dc_wake_i']
    for kind in (1,2,3):
        clear(d,inputs);d.rst.value=1;await tick(d);d.rst.value=0
        depth=val(d.free_count_o);d.kind_i.value=kind;d.alloc_valid.value=1;d.alloc_rob.value=1
        await settle();idx=val(d.alloc_idx);await tick(d);d.alloc_valid.value=0
        d.execute_valid.value=1;d.execute_idx.value=idx;d.execute_addr.value=0x02000100 if kind==2 else 0x8000013f
        d.execute_data.value=0x8877665544332211;d.execute_mask.value=255
        await tick(d);d.execute_valid.value=0
        d.query_valid.value=1;d.query_rob.value=2;d.query_addr.value=0x80000400;d.query_mask.value=255
        await settle()
        assert val(d.query_block)==int(kind!=2),(kind,'spec 3/6.2/7 younger load')
        assert not val(d.query_forward_valid) and not val(d.dc_req_valid)
        for _ in range(5):await tick(d);assert not val(d.dc_req_valid)
        d.heu_done_i.value=1;d.heu_done_idx_i.value=1;await tick(d);d.heu_done_i.value=0
        await settle();assert not val(d.query_block),(kind,'HEU completion must wake younger load')
        d.commit_valid.value=1;d.commit_idx.value=idx;await tick(d);d.commit_valid.value=0
        assert val(d.free_count_o)==depth and val(d.committed_empty)
        for _ in range(8):await tick(d);assert not val(d.dc_req_valid) and not val(d.local_drain_valid)
