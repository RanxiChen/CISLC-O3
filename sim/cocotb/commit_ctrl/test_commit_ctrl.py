import os, random
import cocotb
from cocotb.triggers import Timer
async def settle(): await Timer(1,unit="ns")
async def edge(d):
    d.clk.value=0; await settle(); d.clk.value=1; await settle(); d.clk.value=0; await settle()

@cocotb.test()
async def prefix_trap_serial_and_refetch(d):
    for n in ['clk','head_valid_i','head_exc_i','head_serial_i','head_csr_i','csr_resp_valid_i','csr_illegal_i','sysop_i','pc_i','target_i','commit_valid_i','sq_empty_i','sync_ready_i','sync_done_i','trap_redirect_i']:getattr(d,n).value=0
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
