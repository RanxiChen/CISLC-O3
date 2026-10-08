import cocotb
from test_commit_ctrl import reset_l10,edge,settle

@cocotb.test()
async def irreversible_head_defers_irq_until_completion(d):
    await reset_l10(d);d.head_valid_i.value=1;d.pc_i.value=0x80000000
    d.heu_irreversible_i.value=1;d.irq_i.value=1
    for _ in range(16):
        await settle();assert not int(d.trap_o.value);await edge(d)
    d.heu_irreversible_i.value=0;await settle()
    assert int(d.trap_o.value) and int(d.trap_irq_o.value)

@cocotb.test()
async def order_flush_blocks_retirement_and_refetches_same_pc(d):
    await reset_l10(d);d.head_valid_i.value=1;d.pc_i.value=0x80000000
    d.order_flush_i.value=1;d.irq_i.value=1
    await settle();assert int(d.block_o.value) and not int(d.trap_o.value)
    d.sync_ready_i.value=1;await settle();assert int(d.sync_o.value)
    await edge(d);d.sync_done_i.value=1;await edge(d);d.sync_done_i.value=0
    await settle();assert int(d.redirect_o.value) and int(d.flush_o.value)
    assert int(d.committed_pc_o.value)==0x80000000
