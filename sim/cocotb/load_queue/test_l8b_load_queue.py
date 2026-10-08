import cocotb
from test_load_queue import INPUTS,allocate,capture,update,replay_ids
from l3_contract import *

@cocotb.test()
async def head_wait_is_only_owned_by_matching_rob_head(d):
    await reset(d,INPUTS);await allocate(d,[0],[5])
    d.capture_valid_i[0].value=1
    d.capture_i[0].value=capture(d,0,0x02000100,rob=5)|codec(d,'capture',**{'uop.valid':1})
    await tick(d);clear(d,INPUTS)
    d.update_valid_i[0].value=1;d.update_i[0].value=update(d,0,1,2,11)
    await tick(d);clear(d,INPUTS)
    for _ in range(8):
        d.dc_wake_i.value=63;d.tlb_wake_i.value=1;d.sq_change_i.value=1
        await tick(d);assert not replay_ids(d) and not val(d.heu_valid_o)
    d.rob_head_i.value=5;await settle()
    assert val(d.heu_valid_o) and not replay_ids(d)
    assert field(d,'capture',val(d.heu_entry_o),'va')==0x02000100
    d.heu_done_i.value=1;d.heu_done_idx_i.value=5;await tick(d)
    assert not val(d.heu_valid_o) and val(d.executed_obs_o[0])

@cocotb.test()
async def dma_marks_executed_same_line_not_unexecuted_cancelled_or_other_line(d):
    await reset(d,INPUTS);await allocate(d,[0,0,0,1],[1,2,3,4])
    for idx in range(4):
        d.capture_valid_i[0].value=1;d.capture_i[0].value=capture(d,idx,0x80001000+idx*8,rob=idx+1,mask=int(idx==3))
        await tick(d)
    clear(d,INPUTS)
    for idx,pa in ((0,0x80001008),(2,0x80001040),(3,0x80001010)):
        d.update_valid_i[0].value=1
        d.update_i[0].value=update(d,idx,1,0,0)|codec(d,'update',paddr=pa)
        await tick(d)
    clear(d,INPUTS);d.dma_invalidate_i.value=1;d.dma_line_i.value=0x80001000>>6
    d.resolution_valid_i.value=1;d.resolution_mispredict_i.value=1;d.resolution_tag_i.value=0;d.restore_tail_i.value=3
    await tick(d);clear(d,INPUTS)
    assert [val(d.order_obs_o[n]) for n in range(3)]==[1,0,0]
    assert not val(d.live_obs_o[3]) and val(d.rob_order_flush_o)==2
    d.rob_head_i.value=1;await settle();assert val(d.order_flush_o)
    d.dma_invalidate_i.value=1;await tick(d);assert not val(d.live_obs_o[3])

@cocotb.test()
async def simultaneous_pte_and_dma_mark_both_lines_including_completion_edge(d):
    await reset(d,INPUTS);await allocate(d,[0,0],[1,2])
    for n in (0,1):
        d.capture_valid_i[0].value=1;d.capture_i[0].value=capture(d,n,0x80002000+n*64,rob=n+1)
        await tick(d)
    clear(d,INPUTS);d.update_valid_i[0].value=1
    d.update_i[0].value=update(d,0,1,0,0)|codec(d,'update',paddr=0x80002000)
    await tick(d);clear(d,INPUTS)
    d.update_valid_i[1].value=1;d.update_i[1].value=update(d,1,1,0,0)|codec(d,'update',paddr=0x80002040)
    d.dma_invalidate_i.value=1;d.dma_line_i.value=0x80002000>>6
    d.pte_a_write_i.value=1;d.pte_a_line_i.value=0x80002040>>6
    await tick(d);clear(d,INPUTS)
    assert val(d.order_obs_o[0]) and val(d.order_obs_o[1])
    assert val(d.rob_order_flush_o)==6
