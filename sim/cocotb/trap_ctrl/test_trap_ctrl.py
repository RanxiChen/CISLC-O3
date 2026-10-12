import os, random
import cocotb
from cocotb.triggers import Timer
async def settle(): await Timer(1,unit="ns")
async def edge(d):
    d.clk.value=0; await settle(); d.clk.value=1; await settle(); d.clk.value=0; await settle()

@cocotb.test()
async def once_and_reset(d):
    d.clk.value=0;d.valid_i.value=0;d.done_i.value=1;d.target_i.value=0;d.epc_i.value=0;d.cause_i.value=0;d.rst.value=1;await edge(d);d.rst.value=0
    rng=random.Random(int(os.getenv('TEST_SEED','1')))
    previous=(False,0,0)
    for cycle in range(400):
        valid=rng.random()<.25;target=rng.randrange(0x80000000,0x80010000)&~3
        epc=rng.randrange(0x80000000,0x80010000)&~1
        cause=rng.choice((2,3,5,7,8,9,11,12,13,15))
        d.valid_i.value=valid;d.epc_i.value=epc;d.cause_i.value=cause;d.target_i.value=target
        await settle()
        assert int(d.update_o.value)==previous[0]
        if previous[0]:
            assert int(d.update_epc_o.value)==previous[1]
            assert int(d.update_cause_o.value)==previous[2]
        await edge(d)
        assert int(d.redirect_o.value)==previous[0]
        assert int(d.update_o.value)==valid
        assert int(d.busy_o.value)==bool(valid or previous[0])
        if previous[0]:assert int(d.pc_o.value)==target
        if valid:
            assert int(d.update_epc_o.value)==epc
            assert int(d.update_cause_o.value)==cause
        previous=(valid,epc,cause)
    d.rst.value=1;await edge(d);assert int(d.redirect_o.value)==0 and int(d.update_o.value)==0 and int(d.busy_o.value)==0
