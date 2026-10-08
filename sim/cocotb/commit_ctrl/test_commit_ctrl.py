import os, random
import cocotb
from cocotb.triggers import Timer
async def settle(): await Timer(1,unit="ns")
async def edge(d):
    d.clk.value=0; await settle(); d.clk.value=1; await settle(); d.clk.value=0; await settle()

@cocotb.test()
async def prefix_trap_serial_and_refetch(d):
    for n in ['clk','head_valid_i','head_exc_i','head_serial_i','head_csr_i','csr_resp_valid_i','csr_illegal_i','sysop_i','pc_i','target_i','commit_valid_i','sq_empty_i','sync_ready_i','sync_done_i','trap_redirect_i']:getattr(d,n).value=0
    d.head_needs_d_i.value=0;d.d_ready_i.value=0;d.d_done_i.value=0
    d.ptw_idle_i.value=1;d.sf_ack_i.value=0
    d.priv_i.value=3;d.status_i.value=0;d.irq_i.value=0;d.refetch_i.value=0;d.refetch_kind_i.value=6;d.wfi_stall_i.value=0
    d.rst.value=1;await edge(d);d.rst.value=0
    pc=0x80000000;rng=random.Random(int(os.getenv('TEST_SEED','1')))
    for cycle in range(300):
        count=rng.randrange(5);d.pc_i.value=pc;d.commit_valid_i.value=(1<<count)-1;await settle()
        assert int(d.ftq_valid_o.value)==(1<<count)-1
        await edge(d);pc+=count*4;assert int(d.committed_pc_o.value)==pc
    d.commit_valid_i.value=0;d.head_valid_i.value=1;d.head_exc_i.value=1;d.pc_i.value=pc;await settle()
    assert int(d.trap_o.value)==1 and int(d.block_o.value)==1 and int(d.flush_o.value)==1
    await edge(d);d.head_exc_i.value=0;d.trap_redirect_i.value=1;d.target_i.value=0x80004000;await edge(d);d.trap_redirect_i.value=0
    assert int(d.committed_pc_o.value)==0x80004000
    d.head_serial_i.value=1;d.head_csr_i.value=1;d.csr_resp_valid_i.value=1;await settle();assert int(d.csr_req_o.value)==1
    await edge(d);await settle();assert int(d.csr_req_o.value)==0 and int(d.serial_done_o.value)==1
    d.commit_valid_i.value=1;await edge(d);d.commit_valid_i.value=0;d.head_csr_i.value=0;d.sysop_i.value=6;d.sq_empty_i.value=0;await settle();assert int(d.serial_done_o.value)==0
    d.sq_empty_i.value=1;await settle();assert int(d.serial_done_o.value)==1
    d.sysop_i.value=7;d.sync_ready_i.value=1;await settle();assert int(d.sync_o.value)==1
    await edge(d);d.sync_done_i.value=1;await edge(d);d.sync_done_i.value=0;await settle();assert int(d.serial_done_o.value)==1
    d.commit_valid_i.value=1;await settle();assert int(d.redirect_o.value)==1 and int(d.flush_o.value)==1

async def reset_l10(d):
    for n in ('clk','head_valid_i','head_exc_i','head_serial_i','head_csr_i','csr_resp_valid_i','csr_illegal_i','sysop_i','pc_i','target_i','commit_valid_i','sq_empty_i','sync_ready_i','sync_done_i','trap_redirect_i','status_i','irq_i','refetch_i','wfi_stall_i'):
        getattr(d,n).value=0
    d.head_needs_d_i.value=0;d.d_ready_i.value=0;d.d_done_i.value=0
    d.ptw_idle_i.value=1;d.sf_ack_i.value=0
    d.priv_i.value=3;d.refetch_kind_i.value=6
    d.rst.value=1;await edge(d);d.rst.value=0;await settle()

@cocotb.test()
async def l10_interrupt_boundary_and_irreversible_csr(d):
    await reset_l10(d)
    d.pc_i.value=0x80000000;d.commit_valid_i.value=3;await edge(d);d.commit_valid_i.value=0
    d.irq_i.value=1;await settle()
    assert int(d.block_o.value)==1 and int(d.trap_irq_o.value)==1
    assert int(d.trap_epc_o.value)==0x80000008 # ROB-empty boundary uses committed PC
    await edge(d);d.irq_i.value=0;d.trap_redirect_i.value=1;d.target_i.value=0x80001000
    await settle();assert int(d.redirect_kind_o.value)==2
    await edge(d);d.trap_redirect_i.value=0
    d.head_valid_i.value=1;d.head_serial_i.value=1;d.head_csr_i.value=1;d.csr_resp_valid_i.value=1
    await edge(d);d.irq_i.value=1;await settle()
    assert int(d.trap_o.value)==0 and int(d.serial_done_o.value)==1 # CSR must retire first
    d.commit_valid_i.value=1;await edge(d);d.commit_valid_i.value=0;d.head_valid_i.value=0
    await settle();assert int(d.trap_irq_o.value)==1

@cocotb.test()
async def l10_xret_legality_wfi_and_refetch(d):
    for op,priv,status,illegal in ((3,3,0,False),(3,1,0,True),(4,1,0,False),(4,1,1<<22,True),
                                   (4,0,0,True),(5,0,0,True),(5,1,1<<21,True),(8,1,1<<20,True)):
        await reset_l10(d);d.head_valid_i.value=1;d.head_serial_i.value=1
        d.sysop_i.value=op;d.priv_i.value=priv;d.status_i.value=status;await settle()
        assert bool(int(d.trap_o.value))==illegal
        assert bool(int(d.block_o.value))==illegal
        if not illegal and op in (3,4):
            d.commit_valid_i.value=1;await settle();assert int(d.trap_xret_o.value)==1
            await edge(d);d.commit_valid_i.value=0;d.head_valid_i.value=0;d.trap_redirect_i.value=1
            await settle();assert int(d.redirect_kind_o.value)==1
    await reset_l10(d);d.head_valid_i.value=1;d.head_serial_i.value=1;d.sysop_i.value=5
    d.commit_valid_i.value=1;await settle();assert int(d.wfi_retire_o.value)==1
    for kind in (5,6):
        await reset_l10(d);d.head_valid_i.value=1;d.head_serial_i.value=1;d.head_csr_i.value=1
        d.csr_resp_valid_i.value=1;d.refetch_i.value=1;d.refetch_kind_i.value=kind
        await edge(d);d.sync_ready_i.value=1;await settle()
        assert int(d.sync_o.value)==1 and int(d.serial_done_o.value)==0
        await edge(d);d.sync_done_i.value=1;await edge(d);d.sync_done_i.value=0
        assert int(d.serial_done_o.value)==1
        d.commit_valid_i.value=1;await settle()
        assert int(d.redirect_o.value)==1 and int(d.redirect_kind_o.value)==kind and int(d.flush_o.value)==1

@cocotb.test()
async def sfence_waits_for_store_completion_ptw_and_both_sides(d):
    await reset_l10(d);d.head_valid_i.value=1;d.head_serial_i.value=1;d.sysop_i.value=8
    d.sq_empty_i.value=0;d.ptw_idle_i.value=0;await settle()
    assert int(d.sf_valid_o.value)==0 and int(d.sync_o.value)==0
    d.sq_empty_i.value=1;await settle();assert int(d.sf_valid_o.value)==0
    d.head_needs_d_i.value=0;d.d_ready_i.value=0;d.d_done_i.value=0
    d.ptw_idle_i.value=1;await settle();assert int(d.sf_valid_o.value)==1
    await edge(d);assert int(d.sf_valid_o.value)==0 and int(d.sync_o.value)==0
    d.sf_ack_i.value=1;await edge(d);d.sf_ack_i.value=0;d.sync_ready_i.value=1
    await settle();assert int(d.sync_o.value)==1 and int(d.serial_done_o.value)==0
    await edge(d);d.sync_done_i.value=1;await edge(d);d.sync_done_i.value=0
    assert int(d.serial_done_o.value)==1
    d.pc_i.value=0x80000000;d.commit_valid_i.value=1;await settle()
    assert int(d.redirect_kind_o.value)==4 and int(d.flush_o.value)==1

@cocotb.test()
async def dirty_store_is_non_speculative_and_waits_for_final_probe(d):
    await reset_l10(d);d.head_needs_d_i.value=1
    await settle();assert int(d.d_req_o.value)==0 # no head, no D write
    d.head_valid_i.value=1;await settle()
    assert int(d.d_req_o.value)==1 and int(d.block_o.value)==1
    d.d_ready_i.value=1;await edge(d);assert int(d.d_req_o.value)==0
    for _ in range(7): await edge(d);assert int(d.block_o.value)==1
    d.d_done_i.value=1;await edge(d);d.d_done_i.value=0
    assert int(d.block_o.value)==1 and int(d.d_req_o.value)==0 # retranslation/final target probe still owns head
    d.head_needs_d_i.value=0;await edge(d);assert int(d.block_o.value)==0


@cocotb.test()
async def fence_i_waits_for_sq_and_frontend_sync(d):
    await reset_l10(d);d.head_valid_i.value=1;d.head_serial_i.value=1;d.sysop_i.value=7
    for _ in range(12):
        await edge(d);assert not int(d.sync_o.value)
        assert not int(d.serial_done_o.value)
    d.sq_empty_i.value=1;await settle();assert not int(d.serial_done_o.value)
    await edge(d);assert not int(d.serial_done_o.value)
    d.sync_ready_i.value=1;await settle();assert int(d.sync_o.value)
    await edge(d);d.sync_done_i.value=1;await edge(d);d.sync_done_i.value=0
    assert int(d.serial_done_o.value)
    d.commit_valid_i.value=1;await settle();assert int(d.redirect_o.value) and int(d.flush_o.value)
