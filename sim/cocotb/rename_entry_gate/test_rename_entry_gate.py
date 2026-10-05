import os, random
import cocotb
from cocotb.triggers import Timer
async def settle(): await Timer(1,unit="ns")
async def edge(d):
    d.clk.value=0; await settle(); d.clk.value=1; await settle(); d.clk.value=0; await settle()

@cocotb.test()
async def prefix_and_lifecycle(d):
    for n in ['clk','retire_i','flush_i','isolate_i','wfi_i','serial_i','count_i','accepted_i']: getattr(d,n).value=0
    d.rst.value=1; await edge(d);d.rst.value=0
    rng=random.Random(int(os.getenv('TEST_SEED','1')))
    blocked=False; isolated=False
    for cycle in range(600):
        count=rng.randrange(int(d.width_o.value)+1);serial=rng.randrange(16)
        flush=rng.random()<.08;retire=rng.random()<.15;wfi=rng.random()<.05
        d.count_i.value=count;d.serial_i.value=serial;d.flush_i.value=flush;d.retire_i.value=retire;d.wfi_i.value=wfi
        expected=0
        if not (blocked or isolated or flush or wfi):
            expected=count
            for lane in range(count):
                if serial>>lane&1:expected=lane+1;break
        accepted=rng.randrange(expected+1);d.accepted_i.value=accepted;await settle()
        assert int(d.pass_o.value)==expected,(cycle,count,serial,blocked)
        assert int(d.block_o.value)==(blocked and count!=0)
        await edge(d)
        if flush or retire:blocked=False
        elif any(serial>>lane&1 for lane in range(accepted)):blocked=True
    d.count_i.value=4;d.accepted_i.value=0;d.isolate_i.value=1;await edge(d);d.isolate_i.value=0;await settle()
    assert int(d.pass_o.value)==0
    d.rst.value=1;await edge(d);d.rst.value=0;d.serial_i.value=0;d.wfi_i.value=0;d.flush_i.value=0;await settle();assert int(d.pass_o.value)==4
