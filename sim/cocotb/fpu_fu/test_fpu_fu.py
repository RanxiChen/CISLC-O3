"""Small independent bit-pattern oracle; no comprehensive IEEE-754 claim."""
import os
import random
import struct
import cocotb
from cocotb.triggers import Timer

def bits(x):return struct.unpack('>Q',struct.pack('>d',x))[0]
async def settle():await Timer(1,unit='ns')
async def edge(d):
    d.clk.value=0;await settle();d.clk.value=1;await settle();d.clk.value=0;await settle()
async def reset(d):
    for n in ('clk','flush_i','req_valid_i','resp_ready_i','unit_i','op_i','src_fmt_i','dst_fmt_i','int_fmt_i','op_mod_i','rm_i','a_i','b_i','c_i','id_i','mask_i','resolve_i','mispredict_i','branch_i'):
        getattr(d,n).value=0
    d.rst.value=1;await edge(d);d.rst.value=0;await settle()
    assert int(d.resp_valid_o.value)==0 and int(d.busy_o.value)==0
async def send(d,unit,op,a,b=0,c=0,ident=1,mask=0,fmt=1,rm=0):
    for n,v in dict(unit_i=unit,op_i=op,a_i=a,b_i=b,c_i=c,id_i=ident,mask_i=mask,src_fmt_i=fmt,dst_fmt_i=fmt,rm_i=rm).items():getattr(d,n).value=v
    d.req_valid_i.value=1
    for _ in range(200):
        await settle()
        if int(d.req_ready_o.value):
            await edge(d);d.req_valid_i.value=0;return
        await edge(d)
    assert False,'request acceptance timeout'
async def result(d,expected,flags=0,ident=1,mask=0):
    for _ in range(300):
        await settle()
        if int(d.resp_valid_o.value):break
        await edge(d)
    else:assert False,'result timeout'
    observed=lambda:tuple(int(getattr(d,n).value) for n in ('result_o','flags_o','id_o','mask_o'))
    want=(expected,flags,ident,mask)
    assert observed()==want,(observed(),want)
    for _ in range(5):
        await edge(d)
        assert int(d.resp_valid_o.value)==1 and observed()==want,'unstable backpressured result'
    d.resp_ready_i.value=1;await edge(d);d.resp_ready_i.value=0

@cocotb.test()
async def arithmetic_moves_conversion_and_backpressure(d):
    await reset(d)
    # All four split groups; exact arithmetic avoids host rounding dependence.
    vectors=[(0,0,bits(2),bits(3),0,bits(5),0),
             (0,1,bits(7),bits(2),0,bits(5),0),
             (0,2,bits(2),bits(3),0,bits(6),0),
             (0,3,bits(2),bits(3),bits(4),bits(10),0),
             (1,7,bits(6),bits(2),0,bits(3),0),
             (1,8,bits(9),0,0,bits(3),0),
             (1,7,bits(1),bits(0),0,bits(float('inf')),8),
             (2,14,0x7ff0000000000001,bits(1),0,0,16),
             (2,12,bits(3),bits(2),0,bits(2),0),
             (3,20,3,0,0,bits(3),0),
             (3,19,bits(3),0,0,3,0),
             (3,22,0x7ff0000000000001,0,0,0x7ff0000000000001,0)]
    for ident,(unit,op,a,b,c,want,flags) in enumerate(vectors,1):
        await send(d,unit,op,a,b,c,ident);await result(d,want,flags,ident)
    await send(d,3,22,0x80000001,fmt=0);await result(d,0xffffffff80000001)
    await send(d,3,21,0xffffffff80000001,fmt=0);await result(d,0xffffffff80000001)
    seed=int(os.getenv('TEST_SEED','1'));rng=random.Random(seed)
    for ident in range(32):
        a,b=rng.randrange(-32,33),rng.randrange(-32,33)
        await send(d,0,0,bits(a),bits(b),ident=ident)
        await result(d,bits(a+b),ident=ident)

@cocotb.test()
async def branch_and_global_flush_drop_late_results(d):
    await reset(d)
    for global_flush in (False,True):
        await send(d,1,7,bits(7),bits(3),ident=7,mask=2)
        d.flush_i.value=int(global_flush);d.resolve_i.value=int(not global_flush)
        d.mispredict_i.value=1;d.branch_i.value=1
        await settle();assert int(d.resp_valid_o.value)==0
        await edge(d);d.flush_i.value=0;d.resolve_i.value=0;d.mispredict_i.value=0
        for cycle in range(300):
            assert int(d.resp_valid_o.value)==0,('cancelled result escaped',cycle)
            await edge(d)
            if not int(d.busy_o.value):break
        else:assert False,'cancelled identity never drained'
        await send(d,1,7,bits(6),bits(2),ident=7)
        await result(d,bits(3),ident=7)  # slot/ROB identity reuse after drain
    await send(d,3,22,bits(4),ident=8,mask=2)
    for _ in range(20):
        if int(d.resp_valid_o.value):break
        await edge(d)
    assert int(d.resp_valid_o.value)==1
    d.resolve_i.value=1;d.mispredict_i.value=1;d.branch_i.value=1;d.resp_ready_i.value=1
    await settle();assert int(d.resp_valid_o.value)==0  # cancellation wins over WB
    await edge(d);d.resolve_i.value=0;d.mispredict_i.value=0;d.resp_ready_i.value=0
    await edge(d);assert int(d.busy_o.value)==0
