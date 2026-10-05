import cocotb
from cocotb.triggers import Timer
async def settle(): await Timer(1,unit="ns")
async def edge(d):
    d.clk.value=0;await settle();d.clk.value=1;await settle();d.clk.value=0;await settle()

MASK=(1<<64)-1
def signed(x,n=64): return (x&((1<<n)-1))-(1<<n) if x&(1<<(n-1)) else x&((1<<n)-1)
def oracle(op,a,b):
    if op<5:
        aa=a if op==3 else signed(a);bb=b if op in [2,3] else signed(b)
        v=(aa*bb)>>(64 if op in [1,2,3] else 0)
        return signed(v,32)&MASK if op==4 else v&MASK
    word=op>=9;sgn=op in [5,7,9,11];rem=op in [7,8,11,12]
    n=32 if word else 64
    aa=signed(a,n) if sgn else a&((1<<n)-1);bb=signed(b,n) if sgn else b&((1<<n)-1)
    q=-1 if bb==0 else (abs(aa)//abs(bb))*(-1 if (aa<0) != (bb<0) else 1)
    r=aa if bb==0 else aa-q*bb
    v=r if rem else q
    return (signed(v,32) if word else v)&MASK

@cocotb.test()
async def directed_arithmetic_delivery_cancel(d):
    for n in ['clk','req_valid_i','resp_ready_i','op_i','a_i','b_i','rob_i','preg_i','mask_i','fuse_i','lo_rob_i','lo_preg_i','lo_mask_i','kill_valid_i','kill_mispredict_i','kill_tag_i']:getattr(d,n).value=0
    d.write_i.value=1;d.rst.value=1;await edge(d);d.rst.value=0
    async def tick():
        await settle();w=int(d.wake_valid_o.value);wp=int(d.wake_preg_o.value)
        await edge(d)
        if w: assert int(d.resp_valid_o.value) and int(d.preg_o.value)==wp,('broken wake promise',wp)
    async def request(op,a,b,rob=1,preg=33,mask=0,fuse=False,lomask=0):
        d.op_i.value=op;d.a_i.value=a&MASK;d.b_i.value=b&MASK;d.rob_i.value=rob;d.preg_i.value=preg
        d.mask_i.value=mask;d.fuse_i.value=fuse;d.lo_rob_i.value=rob+1;d.lo_preg_i.value=preg+1;d.lo_mask_i.value=lomask
        d.req_valid_i.value=1;await settle()
        for _ in range(50):
            if int(d.req_ready_o.value):break
            await tick()
        else:assert False,'request not accepted'
        await tick();d.req_valid_i.value=0
    async def result(expected,rob=1,preg=33):
        for _ in range(40):
            await settle()
            if int(d.resp_valid_o.value):break
            await tick()
        else:assert False,'completion timeout'
        assert (int(d.rob_o.value),int(d.preg_o.value),int(d.data_o.value))==(rob,preg,expected)
        assert int(d.bypass_valid_o.value) and int(d.bypass_data_o.value)==expected
        for _ in range(3):
            await tick();assert int(d.resp_valid_o.value) and int(d.data_o.value)==expected
        d.resp_ready_i.value=1;await tick();d.resp_ready_i.value=0
    div=bool(int(d.cfg_div_o.value))
    ops=range(5,13) if div else range(5)
    for op in ops:
        for a,b in [(0,0),(-1,3),(0x8000000000000000,-1),(0x80000000,-1),(37,5)]:
            await request(op,a,b);await result(oracle(op,a&MASK,b&MASK))
    # No destination still completes ROB; no bypass or wake should be advertised.
    d.write_i.value=0;await request(5 if div else 0,8,2)
    for _ in range(40):
        if int(d.resp_valid_o.value):break
        await tick()
    assert int(d.resp_valid_o.value) and not int(d.bypass_valid_o.value)
    d.resp_ready_i.value=1;await tick();d.resp_ready_i.value=0;d.write_i.value=1
    # Cancel an active young request; it must not leave a late completion/credit leak.
    await request(5 if div else 0,0x7fffffffffffffff,3,mask=1)
    d.kill_valid_i.value=1;d.kill_mispredict_i.value=1;await tick();d.kill_valid_i.value=0
    for _ in range(38):await tick();assert not int(d.resp_valid_o.value)
    assert not int(d.busy_o.value)
    # Correct resolution clears the dependency: later reuse of the tag cannot kill it.
    await request(5 if div else 0,23,3,mask=1)
    d.kill_valid_i.value=1;d.kill_mispredict_i.value=0;await tick()
    d.kill_mispredict_i.value=1;await tick();d.kill_valid_i.value=0
    await result(oracle(5 if div else 0,23,3))
    if not div:
        # Independently owned fused results, including canceling only the low member.
        await request(1,-1,2,fuse=True);await result(MASK);await result(MASK-1,2,34)
        await request(1,-1,2,fuse=True,lomask=1)
        d.kill_valid_i.value=1;d.kill_mispredict_i.value=1;await tick();d.kill_valid_i.value=0
        await result(MASK)
        for _ in range(6):await tick();assert not int(d.resp_valid_o.value)
        # Pipeline contains an old and young request: retain the old one on recovery.
        await request(0,7,9,rob=3,preg=35)
        await request(0,11,13,rob=4,preg=36,mask=1)
        d.kill_valid_i.value=1;d.kill_mispredict_i.value=1;await tick();d.kill_valid_i.value=0
        await result(63,3,35)
    # Reserve every completion slot while WB is stalled, then observe launch backpressure.
    slots=int(d.cfg_slots_o.value)
    for i in range(slots):await request(5 if div else 0,12,3,rob=i+1,preg=i+33)
    d.req_valid_i.value=1;await settle();assert not int(d.req_ready_o.value)
    d.req_valid_i.value=0
    for i in range(slots):await result(4 if div else 36,i+1,i+33)
    assert not int(d.busy_o.value)
    await request(5 if div else 0,123,7)
    d.rst.value=1;await edge(d);d.rst.value=0
    for _ in range(6):await tick();assert not int(d.resp_valid_o.value)
