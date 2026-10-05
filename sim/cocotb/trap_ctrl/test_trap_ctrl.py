import os, random
import cocotb
from cocotb.triggers import Timer
async def settle(): await Timer(1,unit="ns")
async def edge(d):
    d.clk.value=0; await settle(); d.clk.value=1; await settle(); d.clk.value=0; await settle()

@cocotb.test()
async def once_and_reset(d):
    d.clk.value=0;d.valid_i.value=0;d.done_i.value=1;d.target_i.value=0;d.rst.value=1;await edge(d);d.rst.value=0
    rng=random.Random(int(os.getenv('TEST_SEED','1')))
    for cycle in range(400):
        valid=rng.random()<.25;target=rng.randrange(0x80000000,0x80010000)&~3
        d.valid_i.value=valid;d.target_i.value=target;await settle();assert int(d.update_o.value)==valid
        await edge(d);assert int(d.redirect_o.value)==valid
        if valid:assert int(d.pc_o.value)==target
    d.rst.value=1;await edge(d);assert int(d.redirect_o.value)==0
